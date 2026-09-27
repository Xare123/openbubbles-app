//! Historical create-envelope codec, separate from live-send/receive proof.
//! Native create/readback APIs bind this envelope to absence, parent and auth
//! proof. Durable historical journal admission must still be integrated before
//! the app can use the single-use writer. HistoricalSent is not an IDS receipt.

use super::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage};
use crate::cloud_sync_canonical_dto::{CloudCanonicalChatPayload, CloudCanonicalEntityKind};
use crate::cloud_sync_historical_projection::project_historical_plain_text;
use crate::cloud_sync_historical_source::HistoricalArchiveSource;
use crate::cloud_sync_native_fetch::cloud_sync_open_protected_outbound_message;
use crate::cloud_sync_received_raw_match::{compare_received_raw, ReceivedRawProtos};
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
    if !valid_digest(parent_binding_sha256) {
        return Err(Failure::BindingMismatch);
    }
    let message = project_historical_plain_text(source, chat)?;
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
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
) -> Result<NativeOpenedHistoricalMessage, Failure> {
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
    let (message, server_record_name) = super::decode_message_fields(&bytes)?;
    let expected = project_historical_plain_text(source, chat)?;
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

pub(crate) fn open_staged_historical_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
    source: &HistoricalArchiveSource,
    chat: &CloudCanonicalChatPayload,
    parent_binding_sha256: &str,
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
    decode(&bytes, source, chat, parent_binding_sha256)
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
    fn missing_incoming_endpoint_never_creates_an_envelope() {
        assert!(encode(
            &historical_source(false, "Incoming", &"a".repeat(64)),
            &parent(),
            &"b".repeat(64),
            "record"
        )
        .is_err());
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
