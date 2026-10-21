//! Source-bound received create envelope. This child module uses serialization
//! helpers, not the ordinary outgoing validator. Its magic cannot parse as an
//! ordinary protobuf, including when an own-device mirror has IS_FROM_ME set.
//! Staging is local only. Native absence/parent/auth proof and the journal own
//! admission; the existing single-use writer owns any remote submission.

use super::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage};
use crate::cloud_sync_canonical_dto::{CloudCanonicalChatPayload, CloudCanonicalEntityKind};
use crate::cloud_sync_native_fetch::cloud_sync_open_protected_outbound_message;
use crate::cloud_sync_received_projection::{project_received_archive_plain_text, project_received_media};
use crate::cloud_sync_received_raw_match::{
    compare_received_group_raw, compare_received_raw, ReceivedRawProtos,
};
use crate::cloud_sync_received_record_match::ReceivedRecordMatchVerdict;
use crate::cloud_sync_received_source::ReceivedArchiveSource;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rustpush::cloud_messages::{CloudMessage, CloudMessageRecordInspection};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAGIC: &[u8] = b"OBCRCV1\0";
const MAX_BYTES: usize = 2 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    guid_hash: String,
    source_sha256: String,
    parent_binding_sha256: String,
    message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    attachment_readback_binding_sha256: Option<String>,
}

pub(crate) struct NativeOpenedReceivedMessage {
    message: CloudMessage,
    server_record_name: String,
    payload_sha256: String,
    media_projection: Option<crate::cloud_sync_attachment_parent::ParentAttributedProjection>,
}
impl NativeOpenedReceivedMessage {
    pub(crate) fn message(&self) -> &CloudMessage {
        &self.message
    }
    pub(crate) fn server_record_name(&self) -> &str {
        &self.server_record_name
    }
}

fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
}

fn encode(
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
    server_record_name: &str,
) -> Result<Vec<u8>, Failure> {
    encode_bound(source, chat, parent_binding_sha256, server_record_name, None)
}

fn encode_bound(
    source: &ReceivedArchiveSource, chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str, server_record_name: &str,
    attachment_readback_binding_sha256: Option<&str>,
) -> Result<Vec<u8>, Failure> {
    if !valid_digest(parent_binding_sha256) {
        return Err(Failure::BindingMismatch);
    }
    if source.has_media() != attachment_readback_binding_sha256.is_some()
        || attachment_readback_binding_sha256.is_some_and(|value| !valid_digest(value)) {
        return Err(Failure::BindingMismatch);
    }
    let message = if source.has_media() { project_received_media(source, chat)?.0 }
        else { project_received_archive_plain_text(source, chat)? };
    let bytes = super::encode_message_fields(message, server_record_name)?;
    let envelope = Envelope {
        version: if source.has_media() { 2 } else { 1 },
        guid_hash: source.guid_hash()?,
        source_sha256: source.source_sha256()?,
        parent_binding_sha256: parent_binding_sha256.into(),
        message: URL_SAFE_NO_PAD.encode(bytes),
        attachment_readback_binding_sha256: attachment_readback_binding_sha256.map(str::to_owned),
    };
    let mut encoded = MAGIC.to_vec();
    encoded.extend(serde_json::to_vec(&envelope).map_err(|_| Failure::MalformedMessage)?);
    if encoded.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(encoded)
}

fn decode(
    encoded: &[u8],
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
) -> Result<NativeOpenedReceivedMessage, Failure> {
    decode_bound(encoded, source, chat, parent_binding_sha256, None)
}

fn decode_bound(
    encoded: &[u8], source: &ReceivedArchiveSource, chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str, attachment_readback_binding_sha256: Option<&str>,
) -> Result<NativeOpenedReceivedMessage, Failure> {
    if encoded.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let json = encoded
        .strip_prefix(MAGIC)
        .ok_or(Failure::MalformedMessage)?;
    let envelope: Envelope = serde_json::from_slice(json).map_err(|_| Failure::MalformedMessage)?;
    if envelope.version != if source.has_media() { 2 } else { 1 }
        || source.has_media() != attachment_readback_binding_sha256.is_some()
        || attachment_readback_binding_sha256.is_some_and(|value| !valid_digest(value))
        || envelope.attachment_readback_binding_sha256.as_deref() != attachment_readback_binding_sha256
        || !valid_digest(parent_binding_sha256)
        || envelope.guid_hash != source.guid_hash()?
        || envelope.source_sha256 != source.source_sha256()?
        || envelope.parent_binding_sha256 != parent_binding_sha256
        || serde_json::to_vec(&envelope).map_err(|_| Failure::MalformedMessage)? != json
    {
        return Err(Failure::BindingMismatch);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(&envelope.message)
        .map_err(|_| Failure::MalformedMessage)?;
    if URL_SAFE_NO_PAD.encode(&bytes) != envelope.message {
        return Err(Failure::MalformedMessage);
    }
    let (message, record_name) = super::decode_message_fields(&bytes)?;
    // Compare to the original protected source projection, not mutable UI or
    // a forgiving re-encoding of an arbitrary remote message. This also rejects
    // unknown/duplicate/noncanonical nested fields in this locally-owned format.
    let (mut expected, media_projection) = if source.has_media() {
        let (message, projection) = project_received_media(source, chat)?;
        (message, Some(projection))
    } else { (project_received_archive_plain_text(source, chat)?, None) };
    if let Some(projection) = &media_projection {
        let body = message.msg_proto.0.attributed_body.as_deref().ok_or(Failure::MalformedMessage)?;
        projection.validate_encoded_body(body)?;
        expected.msg_proto.0.attributed_body = Some(body.to_vec());
    }
    if super::encode_message_fields(expected, &record_name)? != bytes {
        return Err(Failure::BindingMismatch);
    }
    Ok(NativeOpenedReceivedMessage {
        message,
        server_record_name: record_name,
        payload_sha256: super::sha256_hex(encoded),
        media_projection,
    })
}

pub(crate) fn stage_received_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    container_scoped_user_id: &str,
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
) -> Result<NativeProtectedOutboundStage, Failure> {
    stage_received_message_bound(storage_directory, account_fingerprint, container_scoped_user_id,
        source, chat, parent_binding_sha256, None)
}

pub(crate) fn stage_received_message_bound(
    storage_directory: PathBuf, account_fingerprint: String, container_scoped_user_id: &str,
    source: &ReceivedArchiveSource, chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str, attachment_readback_binding_sha256: Option<&str>,
) -> Result<NativeProtectedOutboundStage, Failure> {
    let record_name =
        super::deterministic_message_record_name(source.guid(), container_scoped_user_id)?;
    let encoded = encode_bound(source, chat, parent_binding_sha256, &record_name, attachment_readback_binding_sha256)?;
    super::stage_encoded_message(
        storage_directory,
        account_fingerprint,
        CloudCanonicalEntityKind::Message,
        source.guid(),
        &record_name,
        encoded,
    )
}

pub(crate) fn open_staged_received_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
    source: &ReceivedArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
) -> Result<NativeOpenedReceivedMessage, Failure> {
    open_staged_received_message_bound(storage_directory, account_fingerprint, protected_payload_reference,
        expected_payload_sha256, source, chat, parent_binding_sha256, None)
}

pub(crate) fn open_staged_received_message_bound(
    storage_directory: PathBuf, account_fingerprint: String, protected_payload_reference: &str,
    expected_payload_sha256: &str, source: &ReceivedArchiveSource, chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str, attachment_readback_binding_sha256: Option<&str>,
) -> Result<NativeOpenedReceivedMessage, Failure> {
    let protected = cloud_sync_open_protected_outbound_message(
        storage_directory,
        account_fingerprint,
        protected_payload_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let bytes = URL_SAFE_NO_PAD
        .decode(&protected)
        .map_err(|_| Failure::MalformedMessage)?;
    if !valid_digest(expected_payload_sha256)
        || bytes.len() > MAX_BYTES
        || URL_SAFE_NO_PAD.encode(&bytes) != protected
        || super::sha256_hex(&bytes) != expected_payload_sha256
    {
        return Err(Failure::BindingMismatch);
    }
    decode_bound(&bytes, source, chat, parent_binding_sha256, attachment_readback_binding_sha256)
}

/// Caller must first verify exact server record identity, ETag and original
/// outer wire through InspectReceivedRecordOperation. Raw protobuf inspection
/// here is necessary but does not itself authorize a write or record adoption.
pub(crate) fn verify_received_readback(
    opened: &NativeOpenedReceivedMessage,
    actual: &CloudMessageRecordInspection,
    expected_payload_sha256: &str,
) -> Result<String, Failure> {
    if opened.payload_sha256 != expected_payload_sha256 {
        return Err(Failure::BindingMismatch);
    }
    let raw = ReceivedRawProtos {
        msg_proto: &actual.msg_proto,
        msg_proto_2: actual.msg_proto_2.as_deref(),
        msg_proto_3: actual.msg_proto_3.as_deref(),
        msg_proto_4: actual.msg_proto_4.as_deref(),
    };
    if let Some(projection) = &opened.media_projection {
        crate::cloud_sync_received_raw_match::verify_received_media_raw(&opened.message, &actual.message, &raw, projection)
            .map_err(|_| Failure::BindingMismatch)?;
        return Ok(opened.payload_sha256.clone());
    }
    let is_group = opened
        .message
        .msg_proto_4
        .as_ref()
        .and_then(|proto| proto.0.group_id.as_deref())
        .is_some_and(|route| route.starts_with("iMessage;+;"));
    let comparison = if is_group {
        compare_received_group_raw(&opened.message, &actual.message, &raw)
    } else {
        compare_received_raw(&opened.message, &actual.message, &raw)
    };
    if comparison != Ok(ReceivedRecordMatchVerdict::EquivalentSupportedPlainText) {
        return Err(Failure::BindingMismatch);
    }
    Ok(opened.payload_sha256.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_canonical_dto::{
        CloudCanonicalChatStyle, CloudCanonicalField, CloudCanonicalService,
    };
    use crate::cloud_sync_received_source::tests::fixture;
    use prost::Message;
    use rustpush::cloud_messages::MessageFlags;

    fn chat() -> CloudCanonicalChatPayload {
        CloudCanonicalChatPayload::new(
            "iMessage;-;remote@example.com".into(),
            "remote@example.com".into(),
            "group-alias".into(),
            "original-alias".into(),
            CloudCanonicalService::IMessage,
            CloudCanonicalChatStyle::Direct,
            vec!["mailto:remote@example.com".into()],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value("mailto:changed-preference@example.com".into()),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap()
    }
    fn source(mirrored: bool, text: &str) -> ReceivedArchiveSource {
        let (wire, handles) = fixture(mirrored, text);
        ReceivedArchiveSource::capture(&wire, &handles).unwrap()
    }
    fn inspection(message: CloudMessage) -> CloudMessageRecordInspection {
        CloudMessageRecordInspection {
            msg_proto: message.msg_proto.0.encode_to_vec(),
            msg_proto_2: message.msg_proto_2.as_ref().map(|v| v.0.encode_to_vec()),
            msg_proto_3: message.msg_proto_3.as_ref().map(|v| v.0.encode_to_vec()),
            msg_proto_4: message.msg_proto_4.as_ref().map(|v| v.0.encode_to_vec()),
            message,
        }
    }

    #[test]
    fn received_and_mirrored_envelopes_preserve_original_and_cannot_open_as_ordinary() {
        for mirrored in [false, true] {
            let source = source(mirrored, "Original text 😀");
            let bytes = encode(&source, &chat(), &"a".repeat(64), "record").unwrap();
            assert!(super::super::decode_outbound_envelope(&bytes).is_err());
            let opened = decode(&bytes, &source, &chat(), &"a".repeat(64)).unwrap();
            assert_eq!(opened.message.guid, source.guid());
            assert_eq!(
                opened.message.msg_proto.0.text.as_deref(),
                Some("Original text 😀")
            );
            assert_eq!(
                opened.message.sender,
                if mirrored { "" } else { "remote@example.com" }
            );
            assert_eq!(opened.message.destination_caller_id, "owner@example.com");
            assert_eq!(opened.message.time, 721_692_800_000_000_000);
            assert_eq!(
                opened.message.flags.contains(MessageFlags::IS_FROM_ME),
                mirrored
            );
        }
    }

    #[test]
    fn changed_source_parent_and_nested_payload_are_rejected() {
        let original = source(false, "Original");
        let bytes = encode(&original, &chat(), &"a".repeat(64), "record").unwrap();
        assert!(decode(&bytes, &source(false, "Changed"), &chat(), &"a".repeat(64)).is_err());
        assert!(decode(&bytes, &source(true, "Original"), &chat(), &"a".repeat(64)).is_err());
        assert!(decode(&bytes, &original, &chat(), &"b".repeat(64)).is_err());
        let mut envelope: Envelope = serde_json::from_slice(&bytes[MAGIC.len()..]).unwrap();
        let nested = URL_SAFE_NO_PAD.decode(&envelope.message).unwrap();
        let (mut message, record) = super::super::decode_message_fields(&nested).unwrap();
        message.msg_proto.0.text = Some("Changed".into());
        envelope.message =
            URL_SAFE_NO_PAD.encode(super::super::encode_message_fields(message, &record).unwrap());
        let mut changed = MAGIC.to_vec();
        changed.extend(serde_json::to_vec(&envelope).unwrap());
        assert!(decode(&changed, &original, &chat(), &"a".repeat(64)).is_err());
    }

    #[test]
    fn unknown_duplicate_noncanonical_and_oversized_wrappers_fail_closed() {
        let original = source(false, "Original");
        let bytes = encode(&original, &chat(), &"a".repeat(64), "record").unwrap();
        let json = std::str::from_utf8(&bytes[MAGIC.len()..]).unwrap();
        for changed in [
            format!("{}{}", &json[..json.len() - 1], ",\"extra\":1}"),
            json.replacen("{", "{\"version\":1,", 1),
            format!(" {json}"),
        ] {
            let mut value = MAGIC.to_vec();
            value.extend(changed.as_bytes());
            assert!(decode(&value, &original, &chat(), &"a".repeat(64)).is_err());
        }
        assert!(decode(
            &vec![b'A'; MAX_BYTES + 1],
            &original,
            &chat(),
            &"a".repeat(64)
        )
        .is_err());
    }

    #[test]
    fn protected_roundtrip_binds_original_source_and_exact_digest() {
        let dir = tempfile::tempdir().unwrap();
        let original = source(false, "Original");
        let stage = stage_received_message(
            dir.path().into(),
            "A".repeat(43),
            "container-user",
            &original,
            &chat(),
            &"a".repeat(64),
        )
        .unwrap();
        let opened = open_staged_received_message(
            dir.path().into(),
            "A".repeat(43),
            &stage.protected_payload_reference,
            &stage.payload_sha256,
            &original,
            &chat(),
            &"a".repeat(64),
        )
        .unwrap();
        assert_eq!(
            opened.server_record_name(),
            super::super::deterministic_message_record_name(original.guid(), "container-user")
                .unwrap()
        );
        assert!(open_staged_received_message(
            dir.path().into(),
            "A".repeat(43),
            &stage.protected_payload_reference,
            &"0".repeat(64),
            &original,
            &chat(),
            &"a".repeat(64)
        )
        .is_err());
        assert!(super::super::open_staged_outbound_message(
            dir.path().into(),
            "A".repeat(43),
            &stage.protected_payload_reference,
            &stage.payload_sha256
        )
        .is_err());
    }

    #[test]
    fn readback_binds_raw_protos_and_original_envelope_digest() {
        let original = source(false, "Original");
        let bytes = encode(&original, &chat(), &"a".repeat(64), "record").unwrap();
        let opened = decode(&bytes, &original, &chat(), &"a".repeat(64)).unwrap();
        let good = inspection(opened.message.clone());
        assert_eq!(
            verify_received_readback(&opened, &good, &opened.payload_sha256).unwrap(),
            opened.payload_sha256
        );
        assert!(verify_received_readback(&opened, &good, &"b".repeat(64)).is_err());
        let mut changed = opened.message.clone();
        changed.msg_proto.0.text = Some("Changed".into());
        assert!(
            verify_received_readback(&opened, &inspection(changed), &opened.payload_sha256)
                .is_err()
        );
        let mut unknown = inspection(opened.message.clone());
        unknown.msg_proto.extend([0xf8, 0x07, 0x01]); // unknown proto field127
        assert!(verify_received_readback(&opened, &unknown, &opened.payload_sha256).is_err());
    }

    #[test]
    fn received_media_parent_requires_child_digest_and_preserves_both_origins_routes() {
        use crate::cloud_sync_received_projection::tests::group_parent;
        use crate::cloud_sync_received_source::tests::media_fixture;
        for mirrored in [false, true] {
            for group in [false, true] {
                let (wire, handles) = media_fixture(mirrored, group);
                let original = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
                let parent = if group { group_parent(0, true) } else { chat() };
                let parent_digest = "a".repeat(64);
                let child_digest = "b".repeat(64);
                assert!(encode(&original, &parent, &parent_digest, "record").is_err());
                let bytes = encode_bound(&original, &parent, &parent_digest, "record", Some(&child_digest)).unwrap();
                let opened = decode_bound(&bytes, &original, &parent, &parent_digest, Some(&child_digest)).unwrap();
                assert_eq!(opened.message.flags.contains(MessageFlags::IS_FROM_ME), mirrored);
                assert_eq!(opened.message.destination_caller_id, "owner@example.com");
                assert_eq!(opened.message.sender, if mirrored { "" } else { "remote@example.com" });
                assert_eq!(verify_received_readback(&opened, &inspection(opened.message.clone()),
                    &opened.payload_sha256).unwrap(), opened.payload_sha256);
                // Another projection may encode dictionaries in a different
                // order. All body semantics, not incidental bytes, must match.
                let mut reencoded = opened.message.clone();
                reencoded.msg_proto.0.attributed_body = Some(project_received_media(&original, &parent).unwrap().1.encoded_body);
                reencoded.flags |= MessageFlags::IS_READ;
                assert!(verify_received_readback(&opened, &inspection(reencoded), &opened.payload_sha256).is_ok());
                assert!(decode(&bytes, &original, &parent, &parent_digest).is_err());
                assert!(decode_bound(&bytes, &original, &parent, &parent_digest, Some(&"c".repeat(64))).is_err());
                assert!(decode_bound(&bytes, &original, &parent, &"c".repeat(64), Some(&child_digest)).is_err());
                let mut envelope: Envelope = serde_json::from_slice(&bytes[MAGIC.len()..]).unwrap();
                envelope.version = 1;
                let mut downgraded = MAGIC.to_vec();
                downgraded.extend(serde_json::to_vec(&envelope).unwrap());
                assert!(decode_bound(&downgraded, &original, &parent, &parent_digest, Some(&child_digest)).is_err());
                let mut unknown = inspection(opened.message.clone());
                unknown.msg_proto.extend([0xf8, 0x07, 0x01]);
                assert!(verify_received_readback(&opened, &unknown, &opened.payload_sha256).is_err());
                for change in 0..3 {
                    let mut changed = opened.message.clone();
                    match change {
                        0 => changed.destination_caller_id.clear(),
                        1 => changed.msg_proto.0.text = Some("changed caption".into()),
                        _ => changed.msg_proto.0.attributed_body = None,
                    }
                    assert!(verify_received_readback(&opened, &inspection(changed), &opened.payload_sha256).is_err());
                }
            }
        }
    }

    #[test]
    fn received_media_parent_protected_reopen_binds_child_proof_and_does_not_downgrade() {
        let (wire, handles) = crate::cloud_sync_received_source::tests::media_fixture(false, false);
        let original = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let parent = "a".repeat(64);
        let children = "b".repeat(64);
        let stage = stage_received_message_bound(dir.path().into(), "A".repeat(43), "owner",
            &original, &chat(), &parent, Some(&children)).unwrap();
        let opened = open_staged_received_message_bound(dir.path().into(), "A".repeat(43),
            &stage.protected_payload_reference, &stage.payload_sha256, &original, &chat(),
            &parent, Some(&children)).unwrap();
        assert!(verify_received_readback(&opened, &inspection(opened.message.clone()), &stage.payload_sha256).is_ok());
        assert!(open_staged_received_message(dir.path().into(), "A".repeat(43),
            &stage.protected_payload_reference, &stage.payload_sha256, &original, &chat(), &parent).is_err());
        assert!(super::super::open_staged_outbound_message(dir.path().into(), "A".repeat(43),
            &stage.protected_payload_reference, &stage.payload_sha256).is_err());
    }

    #[test]
    fn plain_received_envelope_serialization_is_unchanged_without_media_proof() {
        #[derive(Serialize)]
        struct LegacyEnvelope { version: u32, guid_hash: String, source_sha256: String,
            parent_binding_sha256: String, message: String }
        let original = source(false, "Original");
        let bytes = encode(&original, &chat(), &"a".repeat(64), "record").unwrap();
        let envelope: Envelope = serde_json::from_slice(&bytes[MAGIC.len()..]).unwrap();
        assert!(envelope.attachment_readback_binding_sha256.is_none());
        let expected = LegacyEnvelope { version: envelope.version, guid_hash: envelope.guid_hash,
            source_sha256: envelope.source_sha256, parent_binding_sha256: envelope.parent_binding_sha256,
            message: envelope.message };
        assert_eq!(&bytes[MAGIC.len()..], serde_json::to_vec(&expected).unwrap());
        assert!(encode_bound(&original, &chat(), &"a".repeat(64), "record", Some(&"b".repeat(64))).is_err());
    }

    #[test]
    fn protected_group_roundtrip_preserves_endpoint_and_rejects_changed_parent() {
        use crate::cloud_sync_received_projection::tests::{group_parent, group_source};
        for mirrored in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let original = group_source(mirrored);
            let parent = group_parent(1, true);
            let stage = stage_received_message(
                dir.path().into(),
                "A".repeat(43),
                "container-user",
                &original,
                &parent,
                &"a".repeat(64),
            )
            .unwrap();
            let opened = open_staged_received_message(
                dir.path().into(),
                "A".repeat(43),
                &stage.protected_payload_reference,
                &stage.payload_sha256,
                &original,
                &parent,
                &"a".repeat(64),
            )
            .unwrap();
            assert_eq!(opened.message.chat_id, parent.group_id());
            assert_eq!(opened.message.destination_caller_id, "owner@example.com");
            assert_eq!(
                opened.message.flags.contains(MessageFlags::IS_FROM_ME),
                mirrored
            );
            assert_eq!(
                opened.message.sender,
                if mirrored { "" } else { "remote@example.com" }
            );
            assert_eq!(
                verify_received_readback(
                    &opened,
                    &inspection(opened.message.clone()),
                    &stage.payload_sha256
                )
                .unwrap(),
                stage.payload_sha256
            );
            // Even another exact source alias cannot substitute a new canonical
            // parent for the parent pinned when this envelope was staged.
            assert!(open_staged_received_message(
                dir.path().into(),
                "A".repeat(43),
                &stage.protected_payload_reference,
                &stage.payload_sha256,
                &original,
                &group_parent(2, true),
                &"a".repeat(64),
            )
            .is_err());
            assert!(super::super::open_staged_outbound_message(
                dir.path().into(),
                "A".repeat(43),
                &stage.protected_payload_reference,
                &stage.payload_sha256,
            )
            .is_err());
            for field in 0..3 {
                let mut changed = opened.message.clone();
                match field {
                    0 => changed.destination_caller_id.clear(),
                    1 => changed.chat_id = parent.guid().to_owned(),
                    _ => {
                        changed.msg_proto_4.as_mut().unwrap().0.group_id =
                            Some(parent.group_id().into())
                    }
                }
                assert!(verify_received_readback(
                    &opened,
                    &inspection(changed),
                    &stage.payload_sha256
                )
                .is_err());
            }
            let mut unknown = inspection(opened.message.clone());
            unknown.msg_proto.extend([0xf8, 0x07, 0x01]);
            assert!(verify_received_readback(&opened, &unknown, &stage.payload_sha256).is_err());
        }
    }
}
