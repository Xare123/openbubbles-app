//! Historical create-envelope codec, separate from live-send/receive proof.
//! Native create/readback APIs bind this envelope to absence, parent and auth
//! proof. Durable historical journal admission must still be integrated before
//! the app can use the single-use writer. HistoricalSent is not an IDS receipt.

use super::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage};
use crate::cloud_sync_canonical_dto::{CloudCanonicalChatPayload, CloudCanonicalEntityKind};
use crate::cloud_sync_historical_projection::{
    project_historical_media, project_historical_plain_text,
};
use crate::cloud_sync_historical_source::HistoricalArchiveSource;
use crate::cloud_sync_native_fetch::cloud_sync_open_protected_outbound_message;
use crate::cloud_sync_received_raw_match::{
    compare_historical_group_raw, compare_historical_raw_unknown_endpoint, compare_received_raw,
    verify_historical_media_raw, ReceivedRawProtos,
};
use crate::cloud_sync_received_record_match::ReceivedRecordMatchVerdict;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rustpush::cloud_messages::{CloudMessage, CloudMessageRecordInspection};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAGIC: &[u8] = b"OBCHST1\0";
const MAX_BYTES: usize = 2 * 1024 * 1024;

fn require_source_store(
    source: &HistoricalArchiveSource,
    directory: &std::path::Path,
    account: &str,
) -> Result<(), Failure> {
    let identity = crate::cloud_sync_protector::protected_store_identity(
        directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    source.require_account_store(account, &identity)
}

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

pub(crate) struct NativeOpenedHistoricalMessage {
    message: CloudMessage,
    server_record_name: String,
    payload_sha256: String,
}
impl NativeOpenedHistoricalMessage {
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
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
    server_record_name: &str,
) -> Result<Vec<u8>, Failure> {
    encode_with_children(
        source,
        chat,
        parent_binding_sha256,
        server_record_name,
        None,
    )
}

fn encode_with_children(
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
    server_record_name: &str,
    attachment_readback_binding_sha256: Option<&str>,
) -> Result<Vec<u8>, Failure> {
    if !valid_digest(parent_binding_sha256)
        || attachment_readback_binding_sha256.is_some_and(|value| !valid_digest(value))
    {
        return Err(Failure::BindingMismatch);
    }
    let message = match attachment_readback_binding_sha256 {
        None => project_historical_plain_text(source, chat)?,
        Some(_) => project_historical_media(source, chat)?,
    };
    let bytes = super::encode_message_fields(message, server_record_name)?;
    let envelope = Envelope {
        version: if attachment_readback_binding_sha256.is_some() {
            2
        } else {
            1
        },
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
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
) -> Result<NativeOpenedHistoricalMessage, Failure> {
    decode_with_children(encoded, source, chat, parent_binding_sha256, None)
}

fn decode_with_children(
    encoded: &[u8],
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
    attachment_readback_binding_sha256: Option<&str>,
) -> Result<NativeOpenedHistoricalMessage, Failure> {
    if encoded.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let json = encoded
        .strip_prefix(MAGIC)
        .ok_or(Failure::MalformedMessage)?;
    let envelope: Envelope = serde_json::from_slice(json).map_err(|_| Failure::MalformedMessage)?;
    if envelope.version
        != if attachment_readback_binding_sha256.is_some() {
            2
        } else {
            1
        }
        || !valid_digest(parent_binding_sha256)
        || attachment_readback_binding_sha256.is_some_and(|value| !valid_digest(value))
        || envelope.attachment_readback_binding_sha256.as_deref()
            != attachment_readback_binding_sha256
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
    let (message, server_record_name) = super::decode_message_fields(&bytes)?;
    let expected = match attachment_readback_binding_sha256 {
        None => project_historical_plain_text(source, chat)?,
        Some(_) => {
            let projection = source
                .media()
                .ok_or(Failure::UnsupportedMessage)?
                .project_attributed_body(source.guid(), source.text())?;
            projection.validate_encoded_body(
                message
                    .msg_proto
                    .0
                    .attributed_body
                    .as_deref()
                    .ok_or(Failure::MalformedMessage)?,
            )?;
            let mut expected = project_historical_media(source, chat)?;
            // NSDictionary order is not stable between projections. Keep the
            // original bytes after bounded semantic verification, never restage.
            expected.msg_proto.0.attributed_body = message.msg_proto.0.attributed_body.clone();
            expected
        }
    };
    if super::encode_message_fields(expected, &server_record_name)? != bytes {
        return Err(Failure::BindingMismatch);
    }
    Ok(NativeOpenedHistoricalMessage {
        message,
        server_record_name,
        payload_sha256: super::sha256_hex(encoded),
    })
}

pub(crate) fn stage_historical_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    container_scoped_user_id: &str,
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
) -> Result<NativeProtectedOutboundStage, Failure> {
    require_source_store(source, &storage_directory, &account_fingerprint)?;
    let record = super::deterministic_message_record_name(source.guid(), container_scoped_user_id)?;
    let encoded = encode(source, chat, parent_binding_sha256, &record)?;
    super::stage_encoded_message(
        storage_directory,
        account_fingerprint,
        CloudCanonicalEntityKind::Message,
        source.guid(),
        &record,
        encoded,
    )
}

/// The durable journal must supply and recheck the exact all-children readback
/// binding. This function stages local bytes only; the digest is not by itself
/// authority to create a record. Plaintext/IDS entry points cannot open it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn stage_historical_media_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    container_scoped_user_id: &str,
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
    attachment_readback_binding_sha256: &str,
) -> Result<NativeProtectedOutboundStage, Failure> {
    require_source_store(source, &storage_directory, &account_fingerprint)?;
    let record = super::deterministic_message_record_name(source.guid(), container_scoped_user_id)?;
    let encoded = encode_with_children(
        source,
        chat,
        parent_binding_sha256,
        &record,
        Some(attachment_readback_binding_sha256),
    )?;
    super::stage_encoded_message(
        storage_directory,
        account_fingerprint,
        CloudCanonicalEntityKind::Message,
        source.guid(),
        &record,
        encoded,
    )
}

pub(crate) fn open_staged_historical_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
) -> Result<NativeOpenedHistoricalMessage, Failure> {
    open_staged_with_children(
        storage_directory,
        account_fingerprint,
        protected_payload_reference,
        expected_payload_sha256,
        source,
        chat,
        parent_binding_sha256,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn open_staged_historical_media_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
    attachment_readback_binding_sha256: &str,
) -> Result<NativeOpenedHistoricalMessage, Failure> {
    open_staged_with_children(
        storage_directory,
        account_fingerprint,
        protected_payload_reference,
        expected_payload_sha256,
        source,
        chat,
        parent_binding_sha256,
        Some(attachment_readback_binding_sha256),
    )
}

#[allow(clippy::too_many_arguments)]
fn open_staged_with_children(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
    attachment_readback_binding_sha256: Option<&str>,
) -> Result<NativeOpenedHistoricalMessage, Failure> {
    require_source_store(source, &storage_directory, &account_fingerprint)?;
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
    decode_with_children(
        &bytes,
        source,
        chat,
        parent_binding_sha256,
        attachment_readback_binding_sha256,
    )
}

/// The caller must bind exact server record identity, ETag and original outer
/// wire first. Reuse the raw/typed field validator, not received provenance.
pub(crate) fn verify_historical_readback(
    opened: &NativeOpenedHistoricalMessage,
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
    if opened.message.msg_proto.0.attributed_body.is_some() {
        verify_historical_media_raw(&opened.message, &actual.message, &raw)
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
        compare_historical_group_raw(&opened.message, &actual.message, &raw)
    } else if opened.message.destination_caller_id.is_empty() {
        compare_historical_raw_unknown_endpoint(&opened.message, &actual.message, &raw)
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
    use crate::cloud_sync_canonical_dto::CloudCanonicalChatStyle;
    use crate::cloud_sync_historical_projection::tests::{chat, source as historical_source};
    use prost::Message;
    use rustpush::cloud_messages::MessageFlags;

    fn parent() -> CloudCanonicalChatPayload {
        chat("peer@example.invalid", CloudCanonicalChatStyle::Direct)
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

    fn media_fixture(
        sent: bool,
        group: bool,
        account: &str,
        store: &str,
    ) -> (HistoricalArchiveSource, CloudCanonicalChatPayload) {
        use crate::cloud_sync_historical_attachment_source::tests as attachment;
        use crate::cloud_sync_historical_source::{
            HistoricalBinding, HistoricalGroupMetadata, HistoricalRow,
        };
        let original = attachment::source_with(&attachment::descriptor(), sent, |_| {});
        let parent = if group {
            crate::cloud_sync_outbound::attachment_parent_test_support::group()
        } else {
            chat("friend@example.com", CloudCanonicalChatStyle::Direct)
        };
        let group_metadata = group.then(|| {
            HistoricalGroupMetadata(
                1,
                Some(parent.group_id().to_owned()),
                vec![
                    ("friend@example.com".into(), "iMessage".into()),
                    ("+15555550100".into(), "iMessage".into()),
                ],
            )
        });
        let source = HistoricalArchiveSource::capture_with_media(
            &HistoricalRow {
                guid: original.guid(),
                text: original.text(),
                sender: original.sender(),
                peer: original.peer(),
                chat_guid: parent.guid(),
                date_created_ms: original.sent_timestamp(),
                is_from_me: sent,
            },
            &HistoricalBinding {
                snapshot_sha256: &"ab".repeat(32),
                account_fingerprint: account,
                protected_store_identity: store,
            },
            sent,
            group_metadata,
            None,
            original.media().cloned(),
        )
        .unwrap();
        (source, parent)
    }

    #[test]
    fn historical_media_envelope_requires_exact_child_source_parent_and_explicit_lane() {
        for sent in [false, true] {
            for group in [false, true] {
                let (source, chat) =
                    media_fixture(sent, group, "synthetic-account", "synthetic-store");
                let parent = "b".repeat(64);
                let children = "c".repeat(64);
                assert!(encode(&source, &chat, &parent, "record").is_err());
                let encoded =
                    encode_with_children(&source, &chat, &parent, "record", Some(&children))
                        .unwrap();
                assert!(decode(&encoded, &source, &chat, &parent).is_err());
                assert!(super::super::decode_outbound_envelope(&encoded).is_err());
                let opened =
                    decode_with_children(&encoded, &source, &chat, &parent, Some(&children))
                        .unwrap();
                assert_eq!(opened.message.msg_proto.0.text.as_deref(), Some(" "));
                assert!(opened.message.msg_proto.0.attributed_body.is_some());
                assert_eq!(
                    opened.message.flags.contains(MessageFlags::IS_FROM_ME),
                    sent
                );
                assert_eq!(opened.payload_sha256, super::super::sha256_hex(&encoded));
                for wrong in ["", "bad", &"d".repeat(64)] {
                    assert!(
                        decode_with_children(&encoded, &source, &chat, &parent, Some(wrong))
                            .is_err()
                    );
                }
                assert!(decode_with_children(
                    &encoded,
                    &source,
                    &chat,
                    &"d".repeat(64),
                    Some(&children)
                )
                .is_err());
                let (other, _) =
                    media_fixture(!sent, group, "synthetic-account", "synthetic-store");
                assert!(
                    decode_with_children(&encoded, &other, &chat, &parent, Some(&children))
                        .is_err()
                );
                let mut envelope: Envelope =
                    serde_json::from_slice(&encoded[MAGIC.len()..]).unwrap();
                envelope.version = 1;
                let downgraded =
                    [MAGIC, serde_json::to_vec(&envelope).unwrap().as_slice()].concat();
                assert!(decode_with_children(
                    &downgraded,
                    &source,
                    &chat,
                    &parent,
                    Some(&children)
                )
                .is_err());
            }
        }
        let text = historical_source(true, "Only text", &"a".repeat(64));
        assert!(encode_with_children(
            &text,
            &parent(),
            &"b".repeat(64),
            "record",
            Some(&"c".repeat(64))
        )
        .is_err());
    }

    #[test]
    fn historical_media_readback_preserves_body_raw_fields_and_all_content_identity() {
        for sent in [false, true] {
            for group in [false, true] {
                let (source, chat) =
                    media_fixture(sent, group, "synthetic-account", "synthetic-store");
                let parent = "b".repeat(64);
                let children = "c".repeat(64);
                let encoded =
                    encode_with_children(&source, &chat, &parent, "record", Some(&children))
                        .unwrap();
                let opened =
                    decode_with_children(&encoded, &source, &chat, &parent, Some(&children))
                        .unwrap();
                let mut status = opened.message.clone();
                status.flags |= MessageFlags::IS_DELIVERED | MessageFlags::IS_READ;
                status.msg_proto.0.date_delivered = Some(900);
                status.msg_proto.0.date_read = Some(1000);
                status.utm = Some(std::time::SystemTime::UNIX_EPOCH);
                assert!(verify_historical_readback(
                    &opened,
                    &inspection(status),
                    &opened.payload_sha256
                )
                .is_ok());
                for change in 0..9 {
                    let mut actual = opened.message.clone();
                    match change {
                        0 => actual.msg_proto.0.attributed_body = None,
                        1 => actual.msg_proto.0.attributed_body.as_mut().unwrap().push(0),
                        2 => actual.msg_proto.0.text = Some("changed".into()),
                        3 => actual.msg_proto.0.message_summary_info = Some(vec![1]),
                        4 => actual.chat_id = "another-chat".into(),
                        5 => {
                            actual.msg_proto_4.as_mut().unwrap().0.group_id =
                                Some("iMessage;+;another".into())
                        }
                        6 => actual.destination_caller_id = "another@example.invalid".into(),
                        7 => actual.flags.toggle(MessageFlags::IS_FROM_ME),
                        _ => actual.time += 1_000_000,
                    }
                    assert!(verify_historical_readback(
                        &opened,
                        &inspection(actual),
                        &opened.payload_sha256
                    )
                    .is_err());
                }
                let mut raw = inspection(opened.message.clone());
                raw.msg_proto.extend([0xf8, 0x07, 0x01]);
                assert!(verify_historical_readback(&opened, &raw, &opened.payload_sha256).is_err());
                let mut duplicate = inspection(opened.message.clone());
                duplicate.msg_proto.extend([0x1a, 1, b' ']);
                assert!(
                    verify_historical_readback(&opened, &duplicate, &opened.payload_sha256)
                        .is_err()
                );
                assert!(verify_historical_readback(
                    &opened,
                    &inspection(opened.message.clone()),
                    &"a".repeat(64)
                )
                .is_err());
            }
        }
    }

    #[test]
    fn historical_plain_envelope_encoding_is_unchanged() {
        #[derive(Serialize)]
        struct OriginalEnvelope {
            version: u32,
            guid_hash: String,
            source_sha256: String,
            parent_binding_sha256: String,
            message: String,
        }
        let source = historical_source(true, "Original history", &"a".repeat(64));
        let parent_hash = "b".repeat(64);
        let encoded = encode(&source, &parent(), &parent_hash, "record").unwrap();
        let old = OriginalEnvelope {
            version: 1,
            guid_hash: source.guid_hash().unwrap(),
            source_sha256: source.source_sha256().unwrap(),
            parent_binding_sha256: parent_hash,
            message: URL_SAFE_NO_PAD.encode(
                super::super::encode_message_fields(
                    project_historical_plain_text(&source, &parent()).unwrap(),
                    "record",
                )
                .unwrap(),
            ),
        };
        assert_eq!(
            encoded,
            [MAGIC, serde_json::to_vec(&old).unwrap().as_slice()].concat()
        );
    }

    #[test]
    fn historical_media_committed_stage_reopens_only_with_same_child_binding() {
        use crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease;
        let directory = tempfile::tempdir().unwrap();
        let store = crate::cloud_sync_protector::protected_store_identity(
            directory.path().to_string_lossy().into_owned(),
        )
        .unwrap();
        let account = "A".repeat(43);
        let (source, chat) = media_fixture(false, true, &account, &store);
        let parent = "b".repeat(64);
        let children = "c".repeat(64);
        let stage = stage_historical_media_message(
            directory.path().to_path_buf(),
            account.clone(),
            "container-user",
            &source,
            &chat,
            &parent,
            &children,
        )
        .unwrap();
        cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_payload_reference),
        )
        .unwrap();
        let open = |account: String, digest: &str, children: &str| {
            open_staged_historical_media_message(
                directory.path().to_path_buf(),
                account,
                &stage.protected_payload_reference,
                digest,
                &source,
                &chat,
                &parent,
                children,
            )
        };
        let opened = open(account.clone(), &stage.payload_sha256, &children).unwrap();
        assert_eq!(
            opened.server_record_name(),
            super::super::deterministic_message_record_name(source.guid(), "container-user")
                .unwrap()
        );
        assert!(open(account.clone(), &stage.payload_sha256, &"d".repeat(64)).is_err());
        assert!(open(account, &"d".repeat(64), &children).is_err());
        assert!(open("B".repeat(43), &stage.payload_sha256, &children).is_err());
        assert!(open_staged_historical_message(
            directory.path().to_path_buf(),
            "A".repeat(43),
            &stage.protected_payload_reference,
            &stage.payload_sha256,
            &source,
            &chat,
            &parent
        )
        .is_err());
    }

    #[test]
    fn historical_envelope_roundtrips_without_becoming_ordinary_send_proof() {
        let source = historical_source(true, "Original history", &"a".repeat(64));
        let bytes = encode(&source, &parent(), &"b".repeat(64), "record").unwrap();
        assert!(super::super::decode_outbound_envelope(&bytes).is_err());
        let opened = decode(&bytes, &source, &parent(), &"b".repeat(64)).unwrap();
        assert_eq!(opened.server_record_name(), "record");
        assert_eq!(
            opened.message().destination_caller_id,
            "original@example.invalid"
        );
        assert_eq!(
            opened.message().msg_proto.0.text.as_deref(),
            Some("Original history")
        );
    }

    #[test]
    fn historical_group_readback_checks_raw_fields_without_relaxing_direct_comparison() {
        let parent = crate::cloud_sync_outbound::attachment_parent_test_support::group();
        for sent in [false, true] {
            let source = crate::cloud_sync_historical_projection::tests::group_source(
                sent,
                parent.guid(),
                Some(parent.group_id()),
            );
            let bytes = encode(&source, &parent, &"b".repeat(64), "record").unwrap();
            let opened = decode(&bytes, &source, &parent, &"b".repeat(64)).unwrap();
            let actual = inspection(opened.message().clone());
            assert!(verify_historical_readback(&opened, &actual, &opened.payload_sha256).is_ok());
            assert_ne!(
                crate::cloud_sync_received_record_match::compare_received_record(
                    opened.message(),
                    &actual.message
                ),
                ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
            );
            let mut status = opened.message().clone();
            status.flags |= MessageFlags::IS_READ;
            status.msg_proto.0.date_read = Some(99);
            assert!(verify_historical_readback(
                &opened,
                &inspection(status),
                &opened.payload_sha256
            )
            .is_ok());
            for field in 0..5 {
                let mut changed = inspection(opened.message().clone());
                match field {
                    0 => changed.msg_proto.extend([0xf8, 0x07, 0x01]),
                    1 => changed
                        .msg_proto_4
                        .as_mut()
                        .unwrap()
                        .extend([0xf8, 0x07, 0x01]),
                    // Existing service field with the wrong wire type.
                    2 => changed.msg_proto_4.as_mut().unwrap().extend([0x20, 0x00]),
                    // Same service value duplicated with its correct wire type.
                    3 => changed
                        .msg_proto_4
                        .as_mut()
                        .unwrap()
                        .extend(b"\x22\x08iMessage"),
                    _ => changed.message.chat_id = "different-group".into(),
                }
                assert!(
                    verify_historical_readback(&opened, &changed, &opened.payload_sha256).is_err()
                );
            }
        }
    }

    #[test]
    fn snapshot_source_parent_origin_and_nested_payload_drift_reject() {
        let source = historical_source(true, "Original", &"a".repeat(64));
        let bytes = encode(&source, &parent(), &"b".repeat(64), "record").unwrap();
        for changed in [
            historical_source(true, "Changed", &"a".repeat(64)),
            historical_source(true, "Original", &"c".repeat(64)),
            historical_source(false, "Original", &"a".repeat(64)),
        ] {
            assert!(decode(&bytes, &changed, &parent(), &"b".repeat(64)).is_err());
        }
        assert!(decode(&bytes, &source, &parent(), &"c".repeat(64)).is_err());
        let mut envelope: Envelope = serde_json::from_slice(&bytes[MAGIC.len()..]).unwrap();
        let (mut message, record) = super::super::decode_message_fields(
            &URL_SAFE_NO_PAD.decode(&envelope.message).unwrap(),
        )
        .unwrap();
        message.msg_proto.0.text = Some("Changed".into());
        envelope.message =
            URL_SAFE_NO_PAD.encode(super::super::encode_message_fields(message, &record).unwrap());
        let mut changed = MAGIC.to_vec();
        changed.extend(serde_json::to_vec(&envelope).unwrap());
        assert!(decode(&changed, &source, &parent(), &"b".repeat(64)).is_err());
        let mut live_origin = b"OBCRCV1\0".to_vec();
        live_origin.extend(&bytes[MAGIC.len()..]);
        assert!(decode(&live_origin, &source, &parent(), &"b".repeat(64)).is_err());
    }

    #[test]
    fn exact_readback_allows_status_only_but_rejects_text_endpoint_and_unknown_wire() {
        let source = historical_source(true, "History", &"a".repeat(64));
        let bytes = encode(&source, &parent(), &"b".repeat(64), "record").unwrap();
        let opened = decode(&bytes, &source, &parent(), &"b".repeat(64)).unwrap();
        let mut status = opened.message().clone();
        status.flags |= MessageFlags::IS_DELIVERED | MessageFlags::IS_READ;
        status.msg_proto.0.date_delivered = Some(1);
        assert!(
            verify_historical_readback(&opened, &inspection(status), &opened.payload_sha256)
                .is_ok()
        );
        for field in 0..3 {
            let mut altered = opened.message().clone();
            match field {
                0 => altered.msg_proto.0.text = Some("New".into()),
                1 => altered.destination_caller_id = "other@example.invalid".into(),
                _ => altered.flags.remove(MessageFlags::IS_FROM_ME),
            }
            assert!(verify_historical_readback(
                &opened,
                &inspection(altered),
                &opened.payload_sha256
            )
            .is_err());
        }
        let mut unknown = inspection(opened.message().clone());
        unknown.msg_proto.extend([0xf8, 0x07, 0x01]);
        assert!(verify_historical_readback(&opened, &unknown, &opened.payload_sha256).is_err());
        assert!(verify_historical_readback(
            &opened,
            &inspection(opened.message().clone()),
            &"c".repeat(64)
        )
        .is_err());
    }

    #[test]
    fn historical_unknown_endpoint_roundtrip_does_not_become_live_received_proof() {
        let source = historical_source(false, "Incoming", &"a".repeat(64));
        let bytes = encode(&source, &parent(), &"b".repeat(64), "record").unwrap();
        let opened = decode(&bytes, &source, &parent(), &"b".repeat(64)).unwrap();
        assert_eq!(opened.message().destination_caller_id, "");
        assert_eq!(opened.message().sender, "peer@example.invalid");
        assert!(!opened.message().flags.contains(MessageFlags::IS_FROM_ME));
        assert!(super::super::decode_outbound_envelope(&bytes).is_err());
        let actual = inspection(opened.message().clone());
        let raw = ReceivedRawProtos {
            msg_proto: &actual.msg_proto,
            msg_proto_2: actual.msg_proto_2.as_deref(),
            msg_proto_3: actual.msg_proto_3.as_deref(),
            msg_proto_4: actual.msg_proto_4.as_deref(),
        };
        // The ordinary live-received validator still requires a known endpoint.
        assert_eq!(
            compare_received_raw(opened.message(), &actual.message, &raw),
            Ok(ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported),
        );
        assert!(verify_historical_readback(&opened, &actual, &opened.payload_sha256).is_ok());
        let mut known = opened.message().clone();
        known.destination_caller_id = "owner@example.invalid".into();
        let mut outgoing = opened.message().clone();
        outgoing.flags.insert(MessageFlags::IS_FROM_ME);
        outgoing.sender.clear();
        for unsupported in [known, outgoing] {
            assert_eq!(
                crate::cloud_sync_received_record_match::compare_historical_record_unknown_endpoint(
                    &unsupported,
                    &unsupported,
                ),
                ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported,
            );
        }
    }

    #[test]
    fn unknown_endpoint_readback_cannot_guess_identity_or_ignore_wire_changes() {
        let source = historical_source(false, "Incoming", &"a".repeat(64));
        let bytes = encode(&source, &parent(), &"b".repeat(64), "record").unwrap();
        let opened = decode(&bytes, &source, &parent(), &"b".repeat(64)).unwrap();
        for field in 0..6 {
            let mut changed = opened.message().clone();
            match field {
                0 => changed.destination_caller_id = "new-preference@example.invalid".into(),
                1 => changed.sender = "other@example.invalid".into(),
                2 => changed.flags.insert(MessageFlags::IS_FROM_ME),
                3 => changed.chat_id = "iMessage;-;other@example.invalid".into(),
                4 => changed.msg_proto.0.text = Some("Changed".into()),
                _ => changed.time += 1_000_000,
            }
            assert!(verify_historical_readback(
                &opened,
                &inspection(changed),
                &opened.payload_sha256,
            )
            .is_err());
        }
        let mut unknown = inspection(opened.message().clone());
        unknown.msg_proto.extend([0xf8, 0x07, 0x01]);
        assert!(verify_historical_readback(&opened, &unknown, &opened.payload_sha256).is_err());
        let mut duplicate = inspection(opened.message().clone());
        // Duplicate text is rejected even when it repeats the expected value.
        duplicate.msg_proto.extend([0x1a, 0x08]);
        duplicate.msg_proto.extend(b"Incoming");
        assert!(verify_historical_readback(&opened, &duplicate, &opened.payload_sha256).is_err());
    }

    #[test]
    fn encrypted_roundtrip_requires_exact_account_store_payload_and_parent() {
        use crate::cloud_sync_historical_source::{HistoricalBinding, HistoricalRow};
        use crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease;
        let directory = tempfile::tempdir().unwrap();
        let foreign = tempfile::tempdir().unwrap();
        let store = crate::cloud_sync_protector::protected_store_identity(
            directory.path().to_string_lossy().into_owned(),
        )
        .unwrap();
        let account = "A".repeat(43);
        let source = HistoricalArchiveSource::capture(
            &HistoricalRow {
                guid: "protected-history-guid",
                text: "Synthetic encrypted history",
                sender: "original@example.invalid",
                peer: "peer@example.invalid",
                chat_guid: "iMessage;-;peer@example.invalid",
                date_created_ms: 1_700_000_000_123,
                is_from_me: true,
            },
            &HistoricalBinding {
                snapshot_sha256: &"a".repeat(64),
                account_fingerprint: &account,
                protected_store_identity: &store,
            },
            true,
        )
        .unwrap();
        let stage = stage_historical_message(
            directory.path().to_path_buf(),
            account.clone(),
            "container-user",
            &source,
            &parent(),
            &"b".repeat(64),
        )
        .unwrap();
        assert_eq!(
            stage.protected_payload_reference,
            stage.protected_server_record_reference
        );
        cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_payload_reference),
        )
        .unwrap();
        let opened = open_staged_historical_message(
            directory.path().to_path_buf(),
            account.clone(),
            &stage.protected_payload_reference,
            &stage.payload_sha256,
            &source,
            &parent(),
            &"b".repeat(64),
        )
        .unwrap();
        assert_eq!(
            opened.server_record_name(),
            super::super::deterministic_message_record_name(source.guid(), "container-user")
                .unwrap()
        );
        assert_eq!(
            opened.message().msg_proto.0.text.as_deref(),
            Some("Synthetic encrypted history")
        );
        for (path, account, digest, parent_hash) in [
            (
                directory.path(),
                "B".repeat(43),
                stage.payload_sha256.clone(),
                "b".repeat(64),
            ),
            (
                foreign.path(),
                account.clone(),
                stage.payload_sha256.clone(),
                "b".repeat(64),
            ),
            (
                directory.path(),
                account.clone(),
                "c".repeat(64),
                "b".repeat(64),
            ),
            (
                directory.path(),
                account.clone(),
                stage.payload_sha256.clone(),
                "c".repeat(64),
            ),
        ] {
            assert!(open_staged_historical_message(
                path.to_path_buf(),
                account,
                &stage.protected_payload_reference,
                &digest,
                &source,
                &parent(),
                &parent_hash
            )
            .is_err());
        }
        assert!(stage_historical_message(
            directory.path().to_path_buf(),
            "B".repeat(43),
            "container-user",
            &source,
            &parent(),
            &"b".repeat(64)
        )
        .is_err());
        assert!(stage_historical_message(
            foreign.path().to_path_buf(),
            account,
            "container-user",
            &source,
            &parent(),
            &"b".repeat(64)
        )
        .is_err());
    }
}
