//! Source-bound received create envelope. This child module uses serialization
//! helpers, not the ordinary outgoing validator. Its magic cannot parse as an
//! ordinary protobuf, including when an own-device mirror has IS_FROM_ME set.
//! Staging is local only. Native absence/parent/auth proof and the journal own
//! admission; the existing single-use writer owns any remote submission.

use super::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage};
use crate::cloud_sync_canonical_dto::{CloudCanonicalChatPayload, CloudCanonicalEntityKind};
use crate::cloud_sync_native_fetch::cloud_sync_open_protected_outbound_message;
use crate::cloud_sync_received_projection::project_received_plain_text;
use crate::cloud_sync_received_raw_match::{compare_received_raw, ReceivedRawProtos};
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
}

pub(crate) struct NativeOpenedReceivedMessage {
    message: CloudMessage,
    server_record_name: String,
    payload_sha256: String,
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
    if !valid_digest(parent_binding_sha256) {
        return Err(Failure::BindingMismatch);
    }
    let message = project_received_plain_text(source, chat)?;
    let bytes = super::encode_message_fields(message, server_record_name)?;
    let envelope = Envelope {
        version: 1,
        guid_hash: source.guid_hash()?,
        source_sha256: source.source_sha256()?,
        parent_binding_sha256: parent_binding_sha256.into(),
        message: URL_SAFE_NO_PAD.encode(bytes),
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
    if encoded.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let json = encoded
        .strip_prefix(MAGIC)
        .ok_or(Failure::MalformedMessage)?;
    let envelope: Envelope = serde_json::from_slice(json).map_err(|_| Failure::MalformedMessage)?;
    if envelope.version != 1
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
    let expected = project_received_plain_text(source, chat)?;
    if super::encode_message_fields(expected, &record_name)? != bytes {
        return Err(Failure::BindingMismatch);
    }
    Ok(NativeOpenedReceivedMessage {
        message,
        server_record_name: record_name,
        payload_sha256: super::sha256_hex(encoded),
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
    let record_name =
        super::deterministic_message_record_name(source.guid(), container_scoped_user_id)?;
    let encoded = encode(source, chat, parent_binding_sha256, &record_name)?;
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
    decode(&bytes, source, chat, parent_binding_sha256)
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
    if compare_received_raw(&opened.message, &actual.message, &raw)
        != Ok(ReceivedRecordMatchVerdict::EquivalentSupportedPlainText)
    {
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
}
