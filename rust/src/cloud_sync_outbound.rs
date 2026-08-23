//! Native-only protected outbound message boundary for Cloud Sync V2.
//!
//! Dart may supply a transient `CloudMessage`, but the durable representation
//! is a versioned protobuf protected under the `outboundMessage` purpose. Raw
//! message content and CloudKit record names never cross the bridge again.

use std::{path::PathBuf, time::UNIX_EPOCH};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message;
use rustpush::{
    cloud_messages::{
        cloudmessagesp::{MessageProto, MessageProto2, MessageProto3, MessageProto4},
        CloudMessage, GZipWrapper, MessageFlags,
    },
    cloudkit::allocate_or_reuse_record_name,
};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::cloud_sync_native_fetch::{
    cloud_sync_open_protected_outbound_message, cloud_sync_stage_protected_outbound_envelope,
};

mod wire {
    include!(concat!(
        env!("OUT_DIR"),
        "/openbubbles.cloudsync.outbound.rs"
    ));
}

use wire::CloudSyncOutboundMessageV1;

const OUTBOUND_SCHEMA_VERSION: u32 = 1;
const MAX_OUTBOUND_ENVELOPE_BYTES: usize = 2 * 1024 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 4 * 1024;
const MAX_PROTO_BYTES: usize = 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_ATTRIBUTED_BODY_BYTES: usize = 1024 * 1024;
const CLOUD_SYNC_SCOPE_SEPARATOR: char = '\u{001f}';

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub(crate) enum CloudSyncOutboundFailure {
    #[error("outbound message is unsupported")]
    UnsupportedMessage,
    #[error("outbound message is malformed")]
    MalformedMessage,
    #[error("outbound message is oversized")]
    OversizedMessage,
    #[error("outbound protected storage failed")]
    ProtectedStorage,
    #[error("outbound protected binding failed")]
    BindingMismatch,
}

/// Dart-safe stage metadata. Every reference is an opaque protected-store
/// capability; both hashes are keyed/content-only diagnostics.
pub(crate) struct NativeProtectedOutboundStage {
    pub(crate) logical_entity_key_hash: String,
    pub(crate) protected_payload_reference: String,
    pub(crate) payload_sha256: String,
    pub(crate) payload_length: u64,
    pub(crate) protected_server_record_reference: String,
    pub(crate) server_record_id_hash: String,
    pub(crate) lease_reference: String,
}

pub(crate) fn stage_outbound_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    message: CloudMessage,
) -> Result<NativeProtectedOutboundStage, CloudSyncOutboundFailure> {
    let logical_message_guid = message.guid.clone();
    let allocation = allocate_or_reuse_record_name(None)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    let record_name = allocation.record_name().to_owned();
    let encoded = encode_outbound_message(message, &record_name)?;
    let payload_sha256 = sha256_hex(&encoded);
    let payload_length =
        u64::try_from(encoded.len()).map_err(|_| CloudSyncOutboundFailure::OversizedMessage)?;
    let protected_envelope = URL_SAFE_NO_PAD.encode(&encoded);
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    let logical_entity_key_hash = hasher
        .canonical_entity_key_hash(
            crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Message,
            &logical_message_guid,
        )
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?
        .value()
        .to_owned();
    let server_record_id_hash = hasher.server_record_id_hash(&record_name);

    let staged = cloud_sync_stage_protected_outbound_envelope(
        storage_directory,
        account_fingerprint,
        protected_envelope,
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;

    Ok(NativeProtectedOutboundStage {
        logical_entity_key_hash,
        protected_payload_reference: staged.protected_envelope_reference.clone(),
        payload_sha256,
        payload_length,
        protected_server_record_reference: staged.protected_envelope_reference,
        server_record_id_hash,
        lease_reference: staged.lease_reference,
    })
}

pub(crate) fn open_staged_outbound_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
) -> Result<CloudMessage, CloudSyncOutboundFailure> {
    let protected_payload = cloud_sync_open_protected_outbound_message(
        storage_directory,
        account_fingerprint,
        protected_payload_reference,
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    let encoded = URL_SAFE_NO_PAD
        .decode(protected_payload)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    if encoded.len() > MAX_OUTBOUND_ENVELOPE_BYTES
        || sha256_hex(&encoded) != expected_payload_sha256
    {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    decode_outbound_envelope(&encoded).map(|(message, _)| message)
}

pub(crate) fn open_staged_server_record_name(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_server_record_reference: &str,
    expected_server_record_id_hash: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    let protected_envelope = cloud_sync_open_protected_outbound_message(
        storage_directory.clone(),
        account_fingerprint,
        protected_server_record_reference,
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    let encoded = URL_SAFE_NO_PAD
        .decode(protected_envelope)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    let (_, record_name) = decode_outbound_envelope(&encoded)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    if hasher.server_record_id_hash(&record_name) != expected_server_record_id_hash {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    Ok(record_name)
}

/// Re-encodes a fetched message with the stable record name so ambiguous-write
/// reconciliation can compare it with the exact protected envelope staged
/// before submission. Any CloudKit normalization becomes an explicit
/// divergence rather than an unsafe automatic replay.
pub(crate) fn outbound_message_payload_sha256(
    message: CloudMessage,
    server_record_name: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    encode_outbound_message(message, server_record_name).map(|encoded| sha256_hex(&encoded))
}

/// Recomputes the Dart `CloudOperationIdentity.forInitialCreate` value for
/// the one currently supported outbound scope. Keeping this check native
/// prevents a well-formed but unrelated local ID from being paired with a
/// protected envelope at prepare or reconciliation time.
pub(crate) fn initial_message_create_operation_id(
    account_fingerprint: &str,
    logical_entity_key_hash: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    if account_fingerprint.len() != 43
        || logical_entity_key_hash.len() != 43
        || !account_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        || !logical_entity_key_hash
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    let storage_key = [
        account_fingerprint,
        "com.apple.messages.cloud",
        "private",
        "messageManateeZone",
        "messages",
        "2",
    ]
    .join(&CLOUD_SYNC_SCOPE_SEPARATOR.to_string());
    let canonical = [
        "cloud-sync-initial-create-v1",
        storage_key.as_str(),
        logical_entity_key_hash,
        "save",
        "1",
    ]
    .join(&CLOUD_SYNC_SCOPE_SEPARATOR.to_string());
    Ok(format!("op1:{}", sha256_hex(canonical.as_bytes())))
}

fn encode_outbound_message(
    message: CloudMessage,
    server_record_name: &str,
) -> Result<Vec<u8>, CloudSyncOutboundFailure> {
    validate_cloud_message(&message)?;
    validate_identifier(server_record_name)?;
    let (has_utm, utm_seconds, utm_nanos) = match message.utm {
        Some(value) => {
            let duration = value
                .duration_since(UNIX_EPOCH)
                .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
            (
                true,
                i64::try_from(duration.as_secs())
                    .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?,
                duration.subsec_nanos(),
            )
        }
        None => (false, 0, 0),
    };
    let envelope = CloudSyncOutboundMessageV1 {
        schema_version: OUTBOUND_SCHEMA_VERSION,
        has_utm,
        utm_seconds,
        utm_nanos,
        message_type: message.r#type,
        error: message.error,
        chat_id: message.chat_id,
        sender: message.sender,
        time: message.time,
        msg_proto_2: message.msg_proto_2.map(|value| value.0.encode_to_vec()),
        destination_caller_id: message.destination_caller_id,
        msg_proto: message.msg_proto.0.encode_to_vec(),
        flags: message.flags.bits(),
        guid: message.guid,
        msg_proto_3: message.msg_proto_3.map(|value| value.0.encode_to_vec()),
        service: message.service,
        msg_proto_4: message.msg_proto_4.map(|value| value.0.encode_to_vec()),
        server_record_name: server_record_name.to_owned(),
    };
    let encoded_len = envelope.encoded_len();
    if encoded_len == 0 || encoded_len > MAX_OUTBOUND_ENVELOPE_BYTES {
        return Err(CloudSyncOutboundFailure::OversizedMessage);
    }
    let encoded = envelope.encode_to_vec();
    Ok(encoded)
}

fn decode_outbound_envelope(
    encoded: &[u8],
) -> Result<(CloudMessage, String), CloudSyncOutboundFailure> {
    if encoded.is_empty() || encoded.len() > MAX_OUTBOUND_ENVELOPE_BYTES {
        return Err(CloudSyncOutboundFailure::OversizedMessage);
    }
    let envelope = CloudSyncOutboundMessageV1::decode(encoded)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    if envelope.schema_version != OUTBOUND_SCHEMA_VERSION || envelope.utm_nanos >= 1_000_000_000 {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    let utm = if envelope.has_utm {
        if envelope.utm_seconds < 0 {
            return Err(CloudSyncOutboundFailure::MalformedMessage);
        }
        Some(UNIX_EPOCH + std::time::Duration::new(envelope.utm_seconds as u64, envelope.utm_nanos))
    } else {
        if envelope.utm_seconds != 0 || envelope.utm_nanos != 0 {
            return Err(CloudSyncOutboundFailure::MalformedMessage);
        }
        None
    };
    validate_identifier(&envelope.server_record_name)?;
    let server_record_name = envelope.server_record_name.clone();
    let message = CloudMessage {
        utm,
        r#type: envelope.message_type,
        error: envelope.error,
        chat_id: envelope.chat_id,
        sender: envelope.sender,
        time: envelope.time,
        msg_proto_2: decode_optional_proto::<MessageProto2>(envelope.msg_proto_2)?.map(GZipWrapper),
        destination_caller_id: envelope.destination_caller_id,
        msg_proto: GZipWrapper(decode_required_proto::<MessageProto>(envelope.msg_proto)?),
        flags: MessageFlags::from_bits_retain(envelope.flags),
        guid: envelope.guid,
        msg_proto_3: decode_optional_proto::<MessageProto3>(envelope.msg_proto_3)?.map(GZipWrapper),
        service: envelope.service,
        msg_proto_4: decode_optional_proto::<MessageProto4>(envelope.msg_proto_4)?.map(GZipWrapper),
    };
    validate_cloud_message(&message)?;
    Ok((message, server_record_name))
}

fn validate_identifier(value: &str) -> Result<(), CloudSyncOutboundFailure> {
    if value.is_empty() || value.len() > MAX_IDENTIFIER_BYTES || value.contains('\0') {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    Ok(())
}

fn decode_required_proto<T: Message + Default>(
    encoded: Vec<u8>,
) -> Result<T, CloudSyncOutboundFailure> {
    if encoded.is_empty() || encoded.len() > MAX_PROTO_BYTES {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    T::decode(encoded.as_slice()).map_err(|_| CloudSyncOutboundFailure::MalformedMessage)
}

fn decode_optional_proto<T: Message + Default>(
    encoded: Option<Vec<u8>>,
) -> Result<Option<T>, CloudSyncOutboundFailure> {
    encoded
        .map(|encoded| {
            if encoded.len() > MAX_PROTO_BYTES {
                return Err(CloudSyncOutboundFailure::OversizedMessage);
            }
            T::decode(encoded.as_slice()).map_err(|_| CloudSyncOutboundFailure::MalformedMessage)
        })
        .transpose()
}

fn validate_cloud_message(message: &CloudMessage) -> Result<(), CloudSyncOutboundFailure> {
    // The first production gate is intentionally one ordinary, outgoing
    // iMessage text record. Reactions, edits, app balloons, attachments, SMS,
    // and scheduled messages remain disabled until their own fixtures pass.
    if message.r#type != 1 || message.service != "iMessage" {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    if message.chat_id.is_empty()
        || message.destination_caller_id.is_empty()
        || message.guid.is_empty()
        || message.time <= 0
        || !message.sender.is_empty()
        || !message.flags.contains(MessageFlags::IS_FROM_ME)
        || !message.flags.contains(MessageFlags::IS_SENT)
        || message.error != 0
    {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    for value in [
        message.chat_id.as_str(),
        message.destination_caller_id.as_str(),
        message.guid.as_str(),
        message.service.as_str(),
    ] {
        if value.len() > MAX_IDENTIFIER_BYTES || value.contains('\0') {
            return Err(CloudSyncOutboundFailure::OversizedMessage);
        }
    }
    let proto = &message.msg_proto.0;
    if proto.encoded_len() > MAX_PROTO_BYTES
        || message
            .msg_proto_2
            .as_ref()
            .is_some_and(|value| value.0.encoded_len() > MAX_PROTO_BYTES)
        || message
            .msg_proto_3
            .as_ref()
            .is_some_and(|value| value.0.encoded_len() > MAX_PROTO_BYTES)
        || message
            .msg_proto_4
            .as_ref()
            .is_some_and(|value| value.0.encoded_len() > MAX_PROTO_BYTES)
        || proto
            .text
            .as_ref()
            .is_some_and(|value| value.len() > MAX_TEXT_BYTES)
        || proto
            .attributed_body
            .as_ref()
            .is_some_and(|value| value.len() > MAX_ATTRIBUTED_BODY_BYTES)
    {
        return Err(CloudSyncOutboundFailure::OversizedMessage);
    }
    if proto.unk1 != 1
        || proto.unk10.is_some_and(|value| value != 0)
        || proto.unk11.is_some_and(|value| value != 0)
        || proto.unk14.is_some_and(|value| value != 0)
        || proto.subject.is_some()
        || proto.effect.is_some()
        || proto.balloon_bundle_id.is_some()
        || proto.payload_data.is_some()
        || proto.message_summary_info.is_some()
        || proto.associated_message_type.is_some()
        || proto.associated_message_guid.is_some()
        || proto.associated_message_range_location.is_some()
        || proto.associated_message_range_length.is_some()
        || (proto.text.as_deref().unwrap_or_default().is_empty()
            && proto
                .attributed_body
                .as_deref()
                .unwrap_or_default()
                .is_empty())
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    if message
        .msg_proto_2
        .as_ref()
        .is_some_and(|value| value.0.reply.is_some())
        || message.msg_proto_3.as_ref().is_some_and(|value| {
            value.0.unk2.is_some_and(|field| field != 0)
                || value.0.unk3.is_some_and(|field| field != 0)
        })
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    if let Some(proto4) = message.msg_proto_4.as_ref().map(|value| &value.0) {
        if proto4.associated_message_emoji.is_some()
            || proto4.schedule_type.is_some_and(|value| value != 0)
            || proto4.schedule_state.is_some_and(|value| value != 0)
            || proto4
                .sent_or_received_off_grid
                .is_some_and(|value| value != 0)
            || proto4
                .service
                .as_deref()
                .is_some_and(|value| value != "iMessage")
        {
            return Err(CloudSyncOutboundFailure::UnsupportedMessage);
        }
        if let Some(group_id) = proto4.group_id.as_deref() {
            validate_identifier(group_id)?;
        }
    }
    Ok(())
}

fn sha256_hex(value: &[u8]) -> String {
    Sha256::digest(value)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> CloudMessage {
        CloudMessage {
            utm: Some(UNIX_EPOCH + std::time::Duration::new(1_700_000_000, 123)),
            r#type: 1,
            error: 0,
            chat_id: "iMessage;-;fixture@example.com".to_owned(),
            sender: String::new(),
            time: 123_456_789,
            msg_proto_2: None,
            destination_caller_id: "sender@example.com".to_owned(),
            msg_proto: GZipWrapper(MessageProto {
                unk1: 1,
                text: Some("fixture".to_owned()),
                ..Default::default()
            }),
            flags: MessageFlags::IS_FROM_ME | MessageFlags::IS_SENT,
            guid: "fixture-guid".to_owned(),
            msg_proto_3: Some(GZipWrapper(MessageProto3::default())),
            service: "iMessage".to_owned(),
            msg_proto_4: Some(GZipWrapper(MessageProto4 {
                service: Some("iMessage".to_owned()),
                ..Default::default()
            })),
        }
    }

    #[test]
    fn outbound_envelope_round_trips_without_losing_presence_or_flags() {
        let original = fixture();
        let encoded = encode_outbound_message(original, "SERVER-RECORD").expect("encode");
        let (decoded, record_name) = decode_outbound_envelope(&encoded).expect("decode");
        assert_eq!(decoded.chat_id, "iMessage;-;fixture@example.com");
        assert_eq!(decoded.msg_proto.text.as_deref(), Some("fixture"));
        assert!(decoded.msg_proto_2.is_none());
        assert!(decoded.msg_proto_3.is_some());
        assert!(decoded.flags.contains(MessageFlags::IS_FROM_ME));
        assert!(decoded.flags.contains(MessageFlags::IS_SENT));
        assert_eq!(record_name, "SERVER-RECORD");
    }

    #[test]
    fn reconciliation_digest_binds_message_and_stable_record_name() {
        let expected = outbound_message_payload_sha256(fixture(), "SERVER-RECORD").unwrap();
        assert_eq!(
            outbound_message_payload_sha256(fixture(), "SERVER-RECORD").unwrap(),
            expected
        );
        assert_ne!(
            outbound_message_payload_sha256(fixture(), "OTHER-RECORD").unwrap(),
            expected
        );
        let mut changed = fixture();
        changed.msg_proto.0.text = Some("different".to_owned());
        assert_ne!(
            outbound_message_payload_sha256(changed, "SERVER-RECORD").unwrap(),
            expected
        );
    }

    #[test]
    fn initial_create_operation_identity_matches_the_dart_cross_language_fixture() {
        assert_eq!(
            initial_message_create_operation_id(&"A".repeat(43), &"L".repeat(43)).unwrap(),
            "op1:516a95310adb6de12787de0e51d654e05f40f2289991f76dcd8e1dac2bd865cb"
        );
        assert_ne!(
            initial_message_create_operation_id(&"B".repeat(43), &"L".repeat(43)).unwrap(),
            initial_message_create_operation_id(&"A".repeat(43), &"L".repeat(43)).unwrap()
        );
        assert_ne!(
            initial_message_create_operation_id(&"A".repeat(43), &"M".repeat(43)).unwrap(),
            initial_message_create_operation_id(&"A".repeat(43), &"L".repeat(43)).unwrap()
        );
    }

    #[test]
    fn initial_create_operation_identity_rejects_noncanonical_hash_inputs() {
        for invalid in ["short".to_owned(), "!".repeat(43), "A".repeat(44)] {
            assert_eq!(
                initial_message_create_operation_id(&invalid, &"L".repeat(43)).unwrap_err(),
                CloudSyncOutboundFailure::BindingMismatch
            );
            assert_eq!(
                initial_message_create_operation_id(&"A".repeat(43), &invalid).unwrap_err(),
                CloudSyncOutboundFailure::BindingMismatch
            );
        }
    }

    #[test]
    fn outbound_gate_rejects_reactions_extensions_and_sms() {
        let mut reaction = fixture();
        reaction.r#type = 2;
        assert_eq!(
            encode_outbound_message(reaction, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );

        let mut extension = fixture();
        extension.msg_proto.0.payload_data = Some(vec![1]);
        assert_eq!(
            encode_outbound_message(extension, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );

        let mut sms = fixture();
        sms.service = "SMS".to_owned();
        assert_eq!(
            encode_outbound_message(sms, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );
    }

    #[test]
    fn envelope_rejects_version_and_digest_tampering() {
        let encoded = encode_outbound_message(fixture(), "SERVER-RECORD").expect("encode");
        let mut envelope = CloudSyncOutboundMessageV1::decode(encoded.as_slice()).unwrap();
        envelope.schema_version += 1;
        assert_eq!(
            decode_outbound_envelope(&envelope.encode_to_vec()).unwrap_err(),
            CloudSyncOutboundFailure::MalformedMessage
        );
    }

    #[test]
    fn outbound_gate_rejects_reply_and_scheduled_metadata() {
        let mut reply = fixture();
        reply.msg_proto_2 = Some(GZipWrapper(MessageProto2 {
            reply: Some("reply-guid".to_owned()),
        }));
        assert_eq!(
            encode_outbound_message(reply, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );

        let mut scheduled = fixture();
        scheduled.msg_proto_4.as_mut().unwrap().0.schedule_type = Some(1);
        assert_eq!(
            encode_outbound_message(scheduled, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );
    }

    #[test]
    fn outbound_gate_rejects_oversized_text_before_envelope_encoding() {
        let mut oversized = fixture();
        oversized.msg_proto.0.text = Some("x".repeat(MAX_TEXT_BYTES + 1));
        assert_eq!(
            encode_outbound_message(oversized, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::OversizedMessage
        );
    }
}
