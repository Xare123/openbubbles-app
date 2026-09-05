//! Protected direct-chat create payload. No bridge or runtime admission is
//! enabled yet; the coordinator must retain the original stage before submit.
//! This separate purpose/zone cannot be replayed through the message writer.
#![cfg_attr(not(test), allow(dead_code))]

use std::{io::Cursor, path::PathBuf};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message;
use rustpush::cloud_messages::{validate_direct_chat_create, CloudChat};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    cloud_sync_canonical_dto::CloudCanonicalEntityKind,
    cloud_sync_native_fetch::{
        cloud_sync_open_protected_outbound_chat, cloud_sync_stage_protected_outbound_chat_envelope,
    },
    cloud_sync_outbound::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage},
};

mod wire {
    include!(concat!(
        env!("OUT_DIR"),
        "/openbubbles.cloudsync.outbound.rs"
    ));
}

const CHAT_PAYLOAD_VERSION: u32 = 1;
const MAX_CHAT_ENVELOPE_BYTES: usize = 256 * 1024;

/// One random server name is generated at staging, before durable admission.
/// After adoption, recovery opens this exact envelope; it must not stage again.
pub(crate) fn stage_outbound_chat(
    storage_directory: PathBuf,
    account_fingerprint: String,
    chat: CloudChat,
) -> Result<NativeProtectedOutboundStage, Failure> {
    let record_name = Uuid::new_v4().to_string().to_uppercase();
    let encoded = encode_chat(&chat, &record_name)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let logical_entity_key_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, &chat.guid)
        .map_err(|_| Failure::MalformedMessage)?
        .value()
        .to_owned();
    let stage = cloud_sync_stage_protected_outbound_chat_envelope(
        storage_directory,
        account_fingerprint,
        URL_SAFE_NO_PAD.encode(&encoded),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    Ok(NativeProtectedOutboundStage {
        logical_entity_key_hash,
        protected_payload_reference: stage.protected_envelope_reference.clone(),
        payload_sha256: digest(&encoded),
        payload_length: encoded.len() as u64,
        protected_server_record_reference: stage.protected_envelope_reference,
        server_record_id_hash: hasher.server_record_id_hash(&record_name),
        lease_reference: stage.lease_reference,
    })
}

/// Open and check both identities together. The payload hash and keyed record
/// hash must match the same protected value, not two independently supplied
/// references. The plaintext tuple remains native-only.
pub(crate) fn open_staged_outbound_chat(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
    expected_payload_sha256: &str,
    expected_record_id_hash: &str,
) -> Result<(CloudChat, String), Failure> {
    let value = cloud_sync_open_protected_outbound_chat(
        storage_directory.clone(),
        account_fingerprint,
        protected_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if value.len() > MAX_CHAT_ENVELOPE_BYTES.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let encoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| Failure::MalformedMessage)?;
    if digest(&encoded) != expected_payload_sha256 {
        return Err(Failure::BindingMismatch);
    }
    let (chat, record_name) = decode_chat(&encoded)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if hasher.server_record_id_hash(&record_name) != expected_record_id_hash {
        return Err(Failure::BindingMismatch);
    }
    Ok((chat, record_name))
}

pub(crate) fn outbound_chat_payload_sha256(
    chat: &CloudChat,
    server_record_name: &str,
) -> Result<String, Failure> {
    encode_chat(chat, server_record_name).map(|bytes| digest(&bytes))
}

fn validate(chat: &CloudChat, record_name: &str) -> Result<(), Failure> {
    validate_direct_chat_create(chat).map_err(|_| Failure::UnsupportedMessage)?;
    if !Uuid::parse_str(record_name)
        .is_ok_and(|uuid| uuid.get_version() == Some(uuid::Version::Random))
    {
        return Err(Failure::MalformedMessage);
    }
    // The only free string not already bounded by direct-chat validation.
    if chat
        .properties
        .as_ref()
        .and_then(|p| p.last_seen_message_guid.as_ref())
        .is_some_and(|guid| guid.len() > 4096 || guid.chars().any(char::is_control))
    {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}

fn encode_chat(chat: &CloudChat, record_name: &str) -> Result<Vec<u8>, Failure> {
    validate(chat, record_name)?;
    let mut chat_plist = Vec::new();
    plist::to_writer_binary(&mut chat_plist, chat).map_err(|_| Failure::MalformedMessage)?;
    let envelope = wire::CloudSyncOutboundChatV1 {
        schema_version: CHAT_PAYLOAD_VERSION,
        server_record_name: record_name.to_owned(),
        chat_plist,
    };
    if envelope.encoded_len() > MAX_CHAT_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(envelope.encode_to_vec())
}

fn decode_chat(encoded: &[u8]) -> Result<(CloudChat, String), Failure> {
    if encoded.is_empty() || encoded.len() > MAX_CHAT_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let envelope =
        wire::CloudSyncOutboundChatV1::decode(encoded).map_err(|_| Failure::MalformedMessage)?;
    if envelope.schema_version != CHAT_PAYLOAD_VERSION || envelope.chat_plist.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    let chat: CloudChat = plist::from_reader(Cursor::new(envelope.chat_plist))
        .map_err(|_| Failure::MalformedMessage)?;
    validate(&chat, &envelope.server_record_name)?;
    Ok((chat, envelope.server_record_name))
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustpush::cloud_messages::{
        cloudmessagesp::ChatProto, CloudParticipant, CloudProp, GZipWrapper,
    };

    const RECORD: &str = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC";
    fn fixture() -> CloudChat {
        CloudChat {
            style: 45,
            state: 3,
            successful_query: 1,
            chat_identifier: "recipient@example.invalid".to_owned(),
            guid: "iMessage;-;recipient@example.invalid".to_owned(),
            group_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".to_owned(),
            original_group_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".to_owned(),
            service_name: "iMessage".to_owned(),
            participants: vec![CloudParticipant {
                uri: "recipient@example.invalid".to_owned(),
            }],
            last_addressed_handle: "sender@example.invalid".to_owned(),
            properties: Some(CloudProp {
                pv: Some(1),
                should_force_to_sms: Some(false),
                ..Default::default()
            }),
            proto001: Some(GZipWrapper(ChatProto { unk1: Some(0) })),
            ..Default::default()
        }
    }

    #[test]
    fn protected_chat_round_trip_keeps_original_record_and_payload_identity() {
        let source = fixture();
        let encoded = encode_chat(&source, RECORD).unwrap();
        let (restored, record) = decode_chat(&encoded).unwrap();
        assert_eq!(record, RECORD);
        assert_eq!(restored.guid, source.guid);
        assert_eq!(restored.group_id, source.group_id);
        assert_eq!(restored.original_group_id, source.original_group_id);
        assert_eq!(restored.participants[0].uri, source.participants[0].uri);
        assert_eq!(restored.properties.as_ref().unwrap().pv, Some(1));
        assert_eq!(restored.proto001.as_ref().unwrap().unk1, Some(0));
        assert_eq!(encode_chat(&restored, &record).unwrap(), encoded);
        assert_eq!(
            outbound_chat_payload_sha256(&restored, &record).unwrap(),
            digest(&encoded)
        );
    }

    #[test]
    fn chat_payload_hash_binds_server_record_name_and_participant() {
        let original = outbound_chat_payload_sha256(&fixture(), RECORD).unwrap();
        assert_ne!(
            original,
            outbound_chat_payload_sha256(&fixture(), "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")
                .unwrap()
        );
        let mut other = fixture();
        other.chat_identifier = "other@example.invalid".to_owned();
        other.guid = "iMessage;-;other@example.invalid".to_owned();
        other.participants[0].uri = other.chat_identifier.clone();
        assert_ne!(
            original,
            outbound_chat_payload_sha256(&other, RECORD).unwrap()
        );
    }

    #[test]
    fn chat_envelope_rejects_version_size_and_identity_tampering() {
        let encoded = encode_chat(&fixture(), RECORD).unwrap();
        let mut envelope = wire::CloudSyncOutboundChatV1::decode(encoded.as_slice()).unwrap();
        envelope.schema_version += 1;
        assert!(decode_chat(&envelope.encode_to_vec()).is_err());
        assert!(decode_chat(&[]).is_err());
        assert!(decode_chat(&vec![0; MAX_CHAT_ENVELOPE_BYTES + 1]).is_err());
        assert!(encode_chat(&fixture(), "00000000-0000-0000-0000-000000000000").is_err());
        let mut changed = fixture();
        changed.guid = RECORD.to_owned();
        assert!(encode_chat(&changed, RECORD).is_err());
        changed = fixture();
        changed.properties.as_mut().unwrap().last_seen_message_guid = Some("x".repeat(4097));
        assert!(encode_chat(&changed, RECORD).is_err());
    }

    #[test]
    fn outbound_chat_payload_cannot_decode_as_a_message_envelope() {
        let encoded = encode_chat(&fixture(), RECORD).unwrap();
        // The chat record name uses wire field 2 as a string; messages use a
        // boolean there. Domain separation also exists in protection scope.
        assert!(wire::CloudSyncOutboundMessageV1::decode(encoded.as_slice()).is_err());
    }

    #[test]
    fn native_chat_envelope_has_no_logging_or_remote_write_calls() {
        let production = include_str!("cloud_sync_outbound_chat.rs")
            .split("#[cfg(test)]")
            .next()
            .unwrap();
        for forbidden in [
            "log::",
            "tracing::",
            "println!",
            "dbg!",
            "save_chats(",
            "save_records(",
            "consume_once(",
        ] {
            assert!(
                !production.contains(forbidden),
                "unexpected protected-chat surface: {forbidden}"
            );
        }
    }
}
