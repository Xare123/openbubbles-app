// Native-only exact IDS attachment source capture.
// Supports plain text plus attachments over iMessage, direct or group.
// Rejects voice, effects, apps, replies, scheduled, mentions, objects,
// SMS, reactions, receipts, extensions, inline attachments, targets,
// certified contexts and verification failures as unsupported.
// embedded_profile is preserved as an opaque bounded blob.
// Pre-send capture, not wire proof: this envelope pins the exact MessageInst
// value handed to encode, byte for byte. IMClient.send runs prepare_send,
// which mutates sent_timestamp and may add sender_guid plus the self
// participant, so this capture alone does not prove the encrypted wire.
// The prepared validator permits only those routing deltas and a timestamp
// inside the native send interval, keeping body and descriptors exact. It is
// not a delivery receipt. Tests prove capture exactness, not remote delivery.
#![cfg_attr(not(test), allow(dead_code))]
use crate::cloud_sync_native_fetch::{
    cloud_sync_open_protected_ids_attachment_source,
    cloud_sync_stage_protected_ids_attachment_source, cloud_sync_verify_committed_lease_exact,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message as ProstMessage;
use rustpush::{AttachmentType, Message, MessageInst, MessagePart, MessageType};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io::Cursor;
use std::path::PathBuf;
mod wire {
    include!(concat!(
        env!("OUT_DIR"),
        "/openbubbles.cloudsync.outbound.rs"
    ));
}
use wire::{CloudSyncIdsAttachmentSourceStageV1, CloudSyncIdsAttachmentSourceV1};
const SOURCE_VERSION: u32 = 1;
const WRAPPER_VERSION: u32 = 1;
const MAX_ENVELOPE_BYTES: usize = 1024 * 1024;
const MAX_PLIST_BYTES: usize = 1024 * 1024;
const MAX_WRAPPER_BYTES: usize = 1024 * 1024;
const MAX_ATTACHMENTS: usize = 64;
const MAX_PARTS: usize = 128;
const MAX_PARTICIPANTS: usize = 64;
const MAX_ID_BYTES: usize = 4 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_URL_BYTES: usize = 8 * 1024;
const MAX_OBJECT_BYTES: usize = 8 * 1024;
const MAX_META_BYTES: usize = 4 * 1024;
const MAX_PROFILE_BYTES: usize = 256 * 1024;
const MAX_PROFILE_RECORD_BYTES: usize = 4 * 1024;
const MAX_PROFILE_KEY_BYTES: usize = 16 * 1024;
const MAX_REF_BYTES: usize = 32 * 1024;
const MAX_CONTENT_BYTES: u64 = 8 * 1024 * 1024 * 1024;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct SourceDto {
    v: u32,
    message_guid: String,
    sender: String,
    sent_timestamp: u64,
    send_delivered: bool,
    conversation: ConversationDto,
    parts: Vec<PartDto>,
    attachment_guids: Vec<String>,
    embedded_profile: Option<ProfileDto>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ConversationDto {
    participants: Vec<String>,
    cv_name: Option<String>,
    sender_guid: Option<String>,
    after_guid: Option<String>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PartDto {
    k: String,
    text: Option<String>,
    attachment: Option<AttachmentDto>,
    idx: Option<u64>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct AttachmentDto {
    guid: String,
    part: u64,
    uti_type: String,
    mime: String,
    name: String,
    iris: bool,
    key: Vec<u8>,
    signature: Vec<u8>,
    object: String,
    url: String,
    size: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ProfileDto {
    record_key: String,
    decryption_key: Vec<u8>,
    poster: Option<PosterDto>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PosterDto {
    low_res: Vec<u8>,
    wallpaper: Vec<u8>,
    message: Vec<u8>,
}
pub(crate) struct DecodedAttachment {
    pub(crate) guid: String,
    pub(crate) part: u64,
    pub(crate) uti_type: String,
    pub(crate) mime: String,
    pub(crate) name: String,
    pub(crate) iris: bool,
    pub(crate) key: Vec<u8>,
    pub(crate) signature: Vec<u8>,
    pub(crate) object: String,
    pub(crate) url: String,
    pub(crate) size: u64,
    pub(crate) idx: Option<u64>,
}
pub(crate) enum DecodedPart {
    Text { text: String, idx: Option<u64> },
    Attachment(DecodedAttachment),
}
pub(crate) struct DecodedPoster {
    pub(crate) low_res: Vec<u8>,
    pub(crate) wallpaper: Vec<u8>,
    pub(crate) message: Vec<u8>,
}
pub(crate) struct DecodedProfile {
    pub(crate) record_key: String,
    pub(crate) decryption_key: Vec<u8>,
    pub(crate) poster: Option<DecodedPoster>,
}
pub(crate) struct DecodedIdsAttachmentSource {
    pub(crate) message_guid: String,
    pub(crate) sender: String,
    pub(crate) sent_timestamp: u64,
    pub(crate) send_delivered: bool,
    pub(crate) participants: Vec<String>,
    pub(crate) cv_name: Option<String>,
    pub(crate) sender_guid: Option<String>,
    pub(crate) after_guid: Option<String>,
    pub(crate) parts: Vec<DecodedPart>,
    pub(crate) attachment_guids: Vec<String>,
    pub(crate) embedded_profile: Option<DecodedProfile>,
}
impl DecodedIdsAttachmentSource {
    pub(crate) fn attachments(&self) -> Vec<&DecodedAttachment> {
        self.parts
            .iter()
            .filter_map(|p| match p {
                DecodedPart::Attachment(d) => Some(d),
                _ => None,
            })
            .collect()
    }
}
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct NativeIdsAttachmentSourceStage {
    pub(crate) protected_reference: String,
    pub(crate) lease_reference: String,
    pub(crate) payload_sha256: String,
    pub(crate) payload_length: u64,
}
pub(crate) fn encode_ids_attachment_source(
    msg: &MessageInst,
    attachment_guids: &[String],
) -> Result<Vec<u8>, Failure> {
    // Pre-send capture: pins the exact value passed, not wire proof.
    let dto = build_dto(msg, attachment_guids)?;
    let mut plist_bytes = Vec::new();
    plist::to_writer_binary(&mut plist_bytes, &dto).map_err(|_| Failure::MalformedMessage)?;
    if plist_bytes.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    if plist_bytes.len() > MAX_PLIST_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let envelope = CloudSyncIdsAttachmentSourceV1 {
        schema_version: SOURCE_VERSION,
        source_plist: plist_bytes,
    };
    if envelope.encoded_len() > MAX_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(envelope.encode_to_vec())
}
pub(crate) fn validate_ids_attachment_source(
    encoded: &[u8],
    msg: &MessageInst,
    guids: &[String],
) -> Result<(), Failure> {
    let expected = build_dto(msg, guids)?;
    let actual = decode_envelope(encoded)?;
    if expected != actual {
        return Err(Failure::BindingMismatch);
    }
    Ok(())
}

/// Compare the stored pre-send value with the actual MessageInst after send.
/// The caller must supply its own native wall-clock bounds and separately
/// require a positive IDS result. Neither this function nor a staged source
/// creates delivery authority. This mirrors MessageInst::prepare_send only.
pub(crate) fn validate_prepared_ids_attachment_source(
    encoded: &[u8],
    prepared: &MessageInst,
    guids: &[String],
    send_started_ms: u64,
    send_finished_ms: u64,
) -> Result<(), Failure> {
    let mut expected = decode_envelope(encoded)?;
    let actual = build_dto(prepared, guids)?;
    if send_started_ms > send_finished_ms
        || !(send_started_ms..=send_finished_ms).contains(&actual.sent_timestamp)
    {
        return Err(Failure::BindingMismatch);
    }
    expected.sent_timestamp = actual.sent_timestamp;
    if expected.conversation.sender_guid.is_none() {
        let generated = actual
            .conversation
            .sender_guid
            .as_ref()
            .ok_or(Failure::BindingMismatch)?;
        let uuid = uuid::Uuid::parse_str(generated).map_err(|_| Failure::BindingMismatch)?;
        if uuid.get_version_num() != 4 || uuid.to_string() != *generated {
            return Err(Failure::BindingMismatch);
        }
        expected.conversation.sender_guid = Some(generated.clone());
    }
    if !expected
        .conversation
        .participants
        .contains(&expected.sender)
    {
        expected
            .conversation
            .participants
            .push(expected.sender.clone());
    }
    if expected != actual {
        return Err(Failure::BindingMismatch);
    }
    Ok(())
}
pub(crate) fn decode_ids_attachment_source(
    encoded: &[u8],
) -> Result<DecodedIdsAttachmentSource, Failure> {
    decoded_from_dto(decode_envelope(encoded)?)
}
pub(crate) fn stage_ids_attachment_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    msg: &MessageInst,
    attachment_guids: &[String],
) -> Result<NativeIdsAttachmentSourceStage, Failure> {
    validate_source_sha(local_source_sha256)?;
    let source = encode_ids_attachment_source(msg, attachment_guids)?;
    let wrapper = CloudSyncIdsAttachmentSourceStageV1 {
        schema_version: WRAPPER_VERSION,
        local_source_sha256: local_source_sha256.to_owned(),
        source_envelope: source,
    };
    if wrapper.encoded_len() > MAX_WRAPPER_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let wrapper_bytes = wrapper.encode_to_vec();
    if wrapper_bytes.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    let payload_sha256 = sha256_hex(&wrapper_bytes);
    let payload_length =
        u64::try_from(wrapper_bytes.len()).map_err(|_| Failure::OversizedMessage)?;
    let staged = cloud_sync_stage_protected_ids_attachment_source(
        storage_directory,
        account_fingerprint,
        URL_SAFE_NO_PAD.encode(&wrapper_bytes),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if staged.protected_envelope_reference.is_empty() || staged.lease_reference.is_empty() {
        return Err(Failure::ProtectedStorage);
    }
    Ok(NativeIdsAttachmentSourceStage {
        protected_reference: staged.protected_envelope_reference,
        lease_reference: staged.lease_reference,
        payload_sha256,
        payload_length,
    })
}
pub(crate) fn open_staged_ids_attachment_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    stage: &NativeIdsAttachmentSourceStage,
) -> Result<DecodedIdsAttachmentSource, Failure> {
    let envelope = open_staged_source_envelope(
        storage_directory,
        account_fingerprint,
        local_source_sha256,
        stage,
    )?;
    decode_ids_attachment_source(&envelope)
}
pub(crate) fn verify_staged_ids_attachment_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    msg: &MessageInst,
    attachment_guids: &[String],
    stage: &NativeIdsAttachmentSourceStage,
) -> Result<DecodedIdsAttachmentSource, Failure> {
    let envelope = open_staged_source_envelope(
        storage_directory,
        account_fingerprint,
        local_source_sha256,
        stage,
    )?;
    validate_ids_attachment_source(&envelope, msg, attachment_guids)?;
    decode_ids_attachment_source(&envelope)
}
fn open_staged_source_envelope(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    stage: &NativeIdsAttachmentSourceStage,
) -> Result<Vec<u8>, Failure> {
    validate_source_sha(local_source_sha256)?;
    validate_stage(stage)?;
    cloud_sync_verify_committed_lease_exact(
        storage_directory.clone(),
        &stage.lease_reference,
        std::slice::from_ref(&stage.protected_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let value = cloud_sync_open_protected_ids_attachment_source(
        storage_directory,
        account_fingerprint,
        &stage.protected_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if value.len() > MAX_WRAPPER_BYTES.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let wrapper_bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| Failure::MalformedMessage)?;
    if wrapper_bytes.len() > MAX_WRAPPER_BYTES
        || sha256_hex(&wrapper_bytes) != stage.payload_sha256
        || wrapper_bytes.len() as u64 != stage.payload_length
    {
        return Err(Failure::BindingMismatch);
    }
    let wrapper = CloudSyncIdsAttachmentSourceStageV1::decode(wrapper_bytes.as_slice())
        .map_err(|_| Failure::MalformedMessage)?;
    if wrapper.schema_version != WRAPPER_VERSION || wrapper.encode_to_vec() != wrapper_bytes {
        return Err(Failure::MalformedMessage);
    }
    if wrapper.local_source_sha256 != local_source_sha256 {
        return Err(Failure::BindingMismatch);
    }
    Ok(wrapper.source_envelope)
}
fn decode_raw_envelope(encoded: &[u8]) -> Result<CloudSyncIdsAttachmentSourceV1, Failure> {
    if encoded.is_empty() || encoded.len() > MAX_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let envelope =
        CloudSyncIdsAttachmentSourceV1::decode(encoded).map_err(|_| Failure::MalformedMessage)?;
    if envelope.schema_version != SOURCE_VERSION
        || envelope.source_plist.is_empty()
        || envelope.source_plist.len() > MAX_PLIST_BYTES
        || envelope.encode_to_vec() != encoded
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(envelope)
}
fn decode_envelope(encoded: &[u8]) -> Result<SourceDto, Failure> {
    let envelope = decode_raw_envelope(encoded)?;
    let dto: SourceDto = plist::from_reader(Cursor::new(&envelope.source_plist))
        .map_err(|_| Failure::MalformedMessage)?;
    validate_dto(&dto)?;
    let mut canonical = Vec::new();
    plist::to_writer_binary(&mut canonical, &dto).map_err(|_| Failure::MalformedMessage)?;
    if canonical != envelope.source_plist {
        return Err(Failure::MalformedMessage);
    }
    Ok(dto)
}
fn decoded_from_dto(dto: SourceDto) -> Result<DecodedIdsAttachmentSource, Failure> {
    let mut parts = Vec::with_capacity(dto.parts.len());
    for part in dto.parts {
        if part.k == "text" {
            if part.attachment.is_some() {
                return Err(Failure::MalformedMessage);
            }
            let text = part.text.ok_or(Failure::MalformedMessage)?;
            parts.push(DecodedPart::Text {
                text,
                idx: part.idx,
            });
        } else if part.k == "attachment" {
            if part.text.is_some() {
                return Err(Failure::MalformedMessage);
            }
            let d = part.attachment.ok_or(Failure::MalformedMessage)?;
            parts.push(DecodedPart::Attachment(DecodedAttachment {
                guid: d.guid,
                part: d.part,
                uti_type: d.uti_type,
                mime: d.mime,
                name: d.name,
                iris: d.iris,
                key: d.key,
                signature: d.signature,
                object: d.object,
                url: d.url,
                size: d.size,
                idx: part.idx,
            }));
        } else {
            return Err(Failure::MalformedMessage);
        }
    }
    Ok(DecodedIdsAttachmentSource {
        message_guid: dto.message_guid,
        sender: dto.sender,
        sent_timestamp: dto.sent_timestamp,
        send_delivered: dto.send_delivered,
        participants: dto.conversation.participants,
        cv_name: dto.conversation.cv_name,
        sender_guid: dto.conversation.sender_guid,
        after_guid: dto.conversation.after_guid,
        parts,
        attachment_guids: dto.attachment_guids,
        embedded_profile: dto.embedded_profile.map(|p| DecodedProfile {
            record_key: p.record_key,
            decryption_key: p.decryption_key,
            poster: p.poster.map(|q| DecodedPoster {
                low_res: q.low_res,
                wallpaper: q.wallpaper,
                message: q.message,
            }),
        }),
    })
}
fn build_dto(msg: &MessageInst, attachment_guids: &[String]) -> Result<SourceDto, Failure> {
    validate_identifier(&msg.id)?;
    let sender = msg.sender.as_ref().ok_or(Failure::MalformedMessage)?;
    validate_identifier(sender)?;
    let conversation = msg.conversation.as_ref().ok_or(Failure::MalformedMessage)?;
    validate_participants(&conversation.participants)?;
    validate_optional_identifier(&conversation.cv_name)?;
    validate_optional_identifier(&conversation.sender_guid)?;
    validate_optional_identifier(&conversation.after_guid)?;
    if msg.target.is_some() {
        return Err(Failure::UnsupportedMessage);
    }
    if msg.certified_context.is_some() {
        return Err(Failure::UnsupportedMessage);
    }
    if msg.verification_failed {
        return Err(Failure::UnsupportedMessage);
    }
    let Message::Message(normal) = &msg.message else {
        return Err(Failure::UnsupportedMessage);
    };
    if !matches!(normal.service, MessageType::IMessage) {
        return Err(Failure::UnsupportedMessage);
    }
    if normal.voice
        || normal.effect.is_some()
        || normal.reply_guid.is_some()
        || normal.reply_part.is_some()
        || normal.subject.is_some()
        || normal.app.is_some()
        || normal.link_meta.is_some()
        || normal.scheduled.is_some()
    {
        return Err(Failure::UnsupportedMessage);
    }
    let embedded_profile = match &normal.embedded_profile {
        None => None,
        Some(profile) => Some(profile_dto(profile)?),
    };
    if normal.parts.0.is_empty() || normal.parts.0.len() > MAX_PARTS {
        return Err(if normal.parts.0.len() > MAX_PARTS {
            Failure::OversizedMessage
        } else {
            Failure::MalformedMessage
        });
    }
    if attachment_guids.len() > MAX_ATTACHMENTS {
        return Err(Failure::OversizedMessage);
    }
    for guid in attachment_guids {
        validate_identifier(guid)?;
    }
    if attachment_guids.iter().collect::<HashSet<_>>().len() != attachment_guids.len() {
        return Err(Failure::MalformedMessage);
    }
    let slot_count = normal
        .parts
        .0
        .iter()
        .filter(|indexed| matches!(&indexed.part, MessagePart::Attachment(_)))
        .count();
    if slot_count == 0 || attachment_guids.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    if slot_count != attachment_guids.len() {
        return Err(Failure::BindingMismatch);
    }
    let mut parts = Vec::with_capacity(normal.parts.0.len());
    let mut cursor = 0;
    for indexed in &normal.parts.0 {
        if indexed.ext.is_some() {
            return Err(Failure::UnsupportedMessage);
        }
        let idx = indexed.idx.map(|v| v as u64);
        match &indexed.part {
            MessagePart::Text(text, format) => {
                if !is_plain_format(format) {
                    return Err(Failure::UnsupportedMessage);
                }
                validate_text(text)?;
                parts.push(PartDto {
                    k: "text".to_owned(),
                    text: Some(text.clone()),
                    attachment: None,
                    idx,
                });
            }
            MessagePart::Attachment(attachment) => {
                let guid = attachment_guids[cursor].clone();
                cursor += 1;
                parts.push(PartDto {
                    k: "attachment".to_owned(),
                    text: None,
                    attachment: Some(attachment_dto(&guid, attachment)?),
                    idx,
                });
            }
            MessagePart::Mention(..) | MessagePart::Object(..) => {
                return Err(Failure::UnsupportedMessage);
            }
        }
    }
    Ok(SourceDto {
        v: SOURCE_VERSION,
        message_guid: msg.id.clone(),
        sender: sender.clone(),
        sent_timestamp: msg.sent_timestamp,
        send_delivered: msg.send_delivered,
        conversation: ConversationDto {
            participants: conversation.participants.clone(),
            cv_name: conversation.cv_name.clone(),
            sender_guid: conversation.sender_guid.clone(),
            after_guid: conversation.after_guid.clone(),
        },
        parts,
        attachment_guids: attachment_guids.to_vec(),
        embedded_profile,
    })
}
fn validate_dto(dto: &SourceDto) -> Result<(), Failure> {
    if dto.v != SOURCE_VERSION {
        return Err(Failure::MalformedMessage);
    }
    validate_identifier(&dto.message_guid)?;
    validate_identifier(&dto.sender)?;
    validate_participants(&dto.conversation.participants)?;
    validate_optional_identifier(&dto.conversation.cv_name)?;
    validate_optional_identifier(&dto.conversation.sender_guid)?;
    validate_optional_identifier(&dto.conversation.after_guid)?;
    if dto.parts.is_empty() || dto.parts.len() > MAX_PARTS {
        return Err(if dto.parts.len() > MAX_PARTS {
            Failure::OversizedMessage
        } else {
            Failure::MalformedMessage
        });
    }
    if dto.attachment_guids.is_empty() || dto.attachment_guids.len() > MAX_ATTACHMENTS {
        return Err(if dto.attachment_guids.len() > MAX_ATTACHMENTS {
            Failure::OversizedMessage
        } else {
            Failure::MalformedMessage
        });
    }
    for guid in &dto.attachment_guids {
        validate_identifier(guid)?;
    }
    if dto.attachment_guids.iter().collect::<HashSet<_>>().len() != dto.attachment_guids.len() {
        return Err(Failure::MalformedMessage);
    }
    if let Some(profile) = &dto.embedded_profile {
        validate_profile_dto(profile)?;
    }
    let mut ordered = Vec::new();
    for part in &dto.parts {
        if part.k == "text" {
            let text = part.text.as_ref().ok_or(Failure::MalformedMessage)?;
            if part.attachment.is_some() {
                return Err(Failure::MalformedMessage);
            }
            validate_text(text)?;
        } else if part.k == "attachment" {
            let attachment = part.attachment.as_ref().ok_or(Failure::MalformedMessage)?;
            if part.text.is_some() {
                return Err(Failure::MalformedMessage);
            }
            validate_attachment_dto(attachment)?;
            ordered.push(attachment.guid.clone());
        } else {
            return Err(Failure::MalformedMessage);
        }
    }
    if ordered.is_empty() || ordered != dto.attachment_guids {
        return Err(Failure::BindingMismatch);
    }
    Ok(())
}
fn attachment_dto(guid: &str, attachment: &rustpush::Attachment) -> Result<AttachmentDto, Failure> {
    let rustpush::Attachment {
        a_type,
        part,
        uti_type,
        mime,
        name,
        iris,
    } = attachment;
    let descriptor = match a_type {
        AttachmentType::MMCS(mmcs) => mmcs,
        AttachmentType::Inline(..) => return Err(Failure::UnsupportedMessage),
    };
    validate_meta_string(uti_type)?;
    validate_meta_string(mime)?;
    if name.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    validate_meta_string(name)?;
    if descriptor.key.len() != 32 || descriptor.signature.len() != 21 {
        return Err(Failure::MalformedMessage);
    }
    if descriptor.object.is_empty()
        || descriptor.object.len() > MAX_OBJECT_BYTES
        || descriptor.object.chars().any(char::is_control)
    {
        return Err(Failure::MalformedMessage);
    }
    if descriptor.url.is_empty()
        || descriptor.url.len() > MAX_URL_BYTES
        || descriptor.url.chars().any(char::is_control)
    {
        return Err(Failure::MalformedMessage);
    }
    let size = u64::try_from(descriptor.size).map_err(|_| Failure::OversizedMessage)?;
    if size > MAX_CONTENT_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(AttachmentDto {
        guid: guid.to_owned(),
        part: *part,
        uti_type: uti_type.clone(),
        mime: mime.clone(),
        name: name.clone(),
        iris: *iris,
        key: descriptor.key.clone(),
        signature: descriptor.signature.clone(),
        object: descriptor.object.clone(),
        url: descriptor.url.clone(),
        size,
    })
}
fn validate_attachment_dto(attachment: &AttachmentDto) -> Result<(), Failure> {
    validate_identifier(&attachment.guid)?;
    validate_meta_string(&attachment.uti_type)?;
    validate_meta_string(&attachment.mime)?;
    if attachment.name.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    validate_meta_string(&attachment.name)?;
    if attachment.key.len() != 32 || attachment.signature.len() != 21 {
        return Err(Failure::MalformedMessage);
    }
    if attachment.object.is_empty()
        || attachment.object.len() > MAX_OBJECT_BYTES
        || attachment.object.chars().any(char::is_control)
    {
        return Err(Failure::MalformedMessage);
    }
    if attachment.url.is_empty()
        || attachment.url.len() > MAX_URL_BYTES
        || attachment.url.chars().any(char::is_control)
    {
        return Err(Failure::MalformedMessage);
    }
    if attachment.size > MAX_CONTENT_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}
fn profile_dto(profile: &rustpush::ShareProfileMessage) -> Result<ProfileDto, Failure> {
    if profile.cloud_kit_record_key.is_empty()
        || profile.cloud_kit_record_key.len() > MAX_PROFILE_RECORD_BYTES
        || profile.cloud_kit_record_key.chars().any(char::is_control)
    {
        return Err(Failure::MalformedMessage);
    }
    if profile.cloud_kit_decryption_record_key.is_empty()
        || profile.cloud_kit_decryption_record_key.len() > MAX_PROFILE_KEY_BYTES
    {
        return Err(Failure::MalformedMessage);
    }
    let poster = match &profile.poster {
        None => None,
        Some(poster) => {
            for tag in [
                &poster.low_res_wallpaper_tag,
                &poster.wallpaper_tag,
                &poster.message_tag,
            ] {
                if tag.is_empty() || tag.len() > MAX_PROFILE_BYTES {
                    return Err(if tag.len() > MAX_PROFILE_BYTES {
                        Failure::OversizedMessage
                    } else {
                        Failure::MalformedMessage
                    });
                }
            }
            Some(PosterDto {
                low_res: poster.low_res_wallpaper_tag.clone(),
                wallpaper: poster.wallpaper_tag.clone(),
                message: poster.message_tag.clone(),
            })
        }
    };
    Ok(ProfileDto {
        record_key: profile.cloud_kit_record_key.clone(),
        decryption_key: profile.cloud_kit_decryption_record_key.clone(),
        poster,
    })
}
fn validate_profile_dto(profile: &ProfileDto) -> Result<(), Failure> {
    if profile.record_key.is_empty()
        || profile.record_key.len() > MAX_PROFILE_RECORD_BYTES
        || profile.record_key.chars().any(char::is_control)
    {
        return Err(Failure::MalformedMessage);
    }
    if profile.decryption_key.is_empty() || profile.decryption_key.len() > MAX_PROFILE_KEY_BYTES {
        return Err(Failure::MalformedMessage);
    }
    if let Some(poster) = &profile.poster {
        for tag in [&poster.low_res, &poster.wallpaper, &poster.message] {
            if tag.is_empty() || tag.len() > MAX_PROFILE_BYTES {
                return Err(if tag.len() > MAX_PROFILE_BYTES {
                    Failure::OversizedMessage
                } else {
                    Failure::MalformedMessage
                });
            }
        }
    }
    Ok(())
}
fn is_plain_format(format: &rustpush::TextFormat) -> bool {
    match format {
        rustpush::TextFormat::Flags(flags) => {
            !flags.bold && !flags.italic && !flags.underline && !flags.strikethrough
        }
        rustpush::TextFormat::Effect(..) => false,
    }
}
fn validate_identifier(value: &str) -> Result<(), Failure> {
    if value.is_empty() || value.len() > MAX_ID_BYTES || value.chars().any(char::is_control) {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn validate_optional_identifier(value: &Option<String>) -> Result<(), Failure> {
    if let Some(value) = value {
        if value.len() > MAX_ID_BYTES || value.chars().any(char::is_control) {
            return Err(Failure::MalformedMessage);
        }
    }
    Ok(())
}
fn validate_meta_string(value: &str) -> Result<(), Failure> {
    if value.is_empty() || value.len() > MAX_META_BYTES || value.chars().any(char::is_control) {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn validate_text(value: &str) -> Result<(), Failure> {
    if value.len() > MAX_TEXT_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}
fn validate_participants(participants: &[String]) -> Result<(), Failure> {
    if participants.is_empty() || participants.len() > MAX_PARTICIPANTS {
        return Err(if participants.len() > MAX_PARTICIPANTS {
            Failure::OversizedMessage
        } else {
            Failure::MalformedMessage
        });
    }
    for participant in participants {
        validate_identifier(participant)?;
    }
    if participants.iter().collect::<HashSet<_>>().len() != participants.len() {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn validate_source_sha(value: &str) -> Result<(), Failure> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn validate_stage(stage: &NativeIdsAttachmentSourceStage) -> Result<(), Failure> {
    if stage.protected_reference.is_empty()
        || stage.protected_reference.len() > MAX_REF_BYTES
        || stage.lease_reference.is_empty()
        || stage.lease_reference.len() > MAX_REF_BYTES
    {
        return Err(Failure::MalformedMessage);
    }
    validate_source_sha(&stage.payload_sha256)?;
    if stage.payload_length == 0 || stage.payload_length > MAX_WRAPPER_BYTES as u64 {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}
fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message as ProstMsg;
    use rustpush::{
        Attachment, ConversationData, IndexedMessagePart, MessageParts, MessageType, NormalMessage,
    };
    fn mmcs(tag: u8) -> rustpush::MMCSFile {
        rustpush::MMCSFile {
            signature: vec![tag; 21],
            object: format!("object-{tag}"),
            url: format!("https://example.invalid/mmcs/object-{tag}"),
            key: vec![tag + 1; 32],
            size: 1024 + tag as usize,
        }
    }
    fn attachment(tag: u8, part: u64) -> Attachment {
        Attachment {
            a_type: AttachmentType::MMCS(mmcs(tag)),
            part,
            uti_type: "public.jpeg".to_owned(),
            mime: "image/jpeg".to_owned(),
            name: format!("photo-{tag}.jpg"),
            iris: false,
        }
    }
    fn conversation() -> ConversationData {
        ConversationData {
            participants: vec![
                "sender@example.invalid".to_owned(),
                "peer@example.invalid".to_owned(),
            ],
            cv_name: None,
            sender_guid: Some("11111111-1111-4111-8111-111111111111".to_owned()),
            after_guid: None,
        }
    }
    fn normal(parts: Vec<IndexedMessagePart>) -> NormalMessage {
        NormalMessage {
            parts: MessageParts(parts),
            effect: None,
            reply_guid: None,
            reply_part: None,
            service: MessageType::IMessage,
            subject: None,
            app: None,
            link_meta: None,
            voice: false,
            scheduled: None,
            embedded_profile: None,
        }
    }
    fn text_part(text: &str) -> IndexedMessagePart {
        IndexedMessagePart {
            part: MessagePart::Text(text.to_owned(), Default::default()),
            idx: None,
            ext: None,
        }
    }
    fn attachment_part(tag: u8, part: u64, idx: Option<usize>) -> IndexedMessagePart {
        IndexedMessagePart {
            part: MessagePart::Attachment(attachment(tag, part)),
            idx,
            ext: None,
        }
    }
    fn fixture() -> (MessageInst, Vec<String>) {
        let msg = MessageInst {
            id: "MSG-GUID-0001".to_owned(),
            sender: Some("sender@example.invalid".to_owned()),
            conversation: Some(conversation()),
            message: Message::Message(normal(vec![
                text_part("hello"),
                attachment_part(7, 0, Some(1)),
            ])),
            sent_timestamp: 1720000000000,
            target: None,
            send_delivered: true,
            verification_failed: false,
            certified_context: None,
        };
        (msg, vec!["ATTACH-GUID-0001".to_owned()])
    }
    fn fixture_two() -> (MessageInst, Vec<String>) {
        let msg = MessageInst {
            id: "MSG-GUID-0002".to_owned(),
            sender: Some("sender@example.invalid".to_owned()),
            conversation: Some(conversation()),
            message: Message::Message(normal(vec![
                text_part("two"),
                attachment_part(7, 0, Some(1)),
                attachment_part(9, 1, Some(2)),
            ])),
            sent_timestamp: 1720000000001,
            target: None,
            send_delivered: false,
            verification_failed: false,
            certified_context: None,
        };
        (
            msg,
            vec!["ATTACH-GUID-0001".to_owned(), "ATTACH-GUID-0002".to_owned()],
        )
    }
    #[test]
    fn roundtrip_is_exact_and_stable() {
        let (msg, guids) = fixture();
        let encoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        assert!(encoded.len() <= MAX_ENVELOPE_BYTES);
        validate_ids_attachment_source(&encoded, &msg, &guids).unwrap();
        let decoded = decode_ids_attachment_source(&encoded).unwrap();
        assert!(decoded.message_guid == msg.id);
        assert!(decoded.sender == "sender@example.invalid");
        assert!(decoded.sent_timestamp == 1720000000000);
        assert!(decoded.send_delivered);
        assert!(decoded.participants.len() == 2);
        assert!(decoded.attachment_guids == guids);
        assert!(decoded.attachments().len() == 1);
        let pin = decoded.attachments()[0];
        assert!(pin.guid == guids[0]);
        assert!(pin.key == vec![8u8; 32]);
        assert!(pin.signature == vec![7u8; 21]);
        assert!(pin.object == "object-7");
        assert!(pin.size == 1031);
        assert!(pin.part == 0);
        assert!(pin.idx == Some(1));
        assert!(pin.iris == false);
        let reencoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        assert!(reencoded == encoded);
    }
    #[test]
    fn every_descriptor_mutation_breaks_binding() {
        let (msg, guids) = fixture();
        let encoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        let mut bad = msg.clone();
        bad.sender = Some("other@example.invalid".to_owned());
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        bad.id = "MSG-GUID-9999".to_owned();
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        bad.sent_timestamp += 1;
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        bad.send_delivered = !bad.send_delivered;
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                if let AttachmentType::MMCS(mmcs) = &mut a.a_type {
                    mmcs.key[0] ^= 0xFF;
                }
            }
        }
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                if let AttachmentType::MMCS(mmcs) = &mut a.a_type {
                    mmcs.signature[0] ^= 0xFF;
                }
            }
        }
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                a.mime = "image/png".to_owned();
            }
        }
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                a.part = 5;
            }
        }
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.parts.0[1].idx = Some(9);
        }
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &bad, &guids),
            Err(Failure::BindingMismatch)
        ));
        let mut swapped_guids = guids.clone();
        swapped_guids[0] = "ATTACH-GUID-OTHER".to_owned();
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &msg, &swapped_guids),
            Err(Failure::BindingMismatch)
        ));
    }
    #[test]
    fn swapping_parts_or_guid_order_breaks_binding() {
        let (msg, guids) = fixture_two();
        let encoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        validate_ids_attachment_source(&encoded, &msg, &guids).unwrap();
        let swapped_guids = vec![guids[1].clone(), guids[0].clone()];
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &msg, &swapped_guids),
            Err(Failure::BindingMismatch)
        ));
        let mut swapped_msg = msg.clone();
        if let Message::Message(normal) = &mut swapped_msg.message {
            normal.parts.0.swap(1, 2);
        }
        assert!(matches!(
            validate_ids_attachment_source(&encoded, &swapped_msg, &guids),
            Err(Failure::BindingMismatch)
        ));
    }
    #[test]
    fn rejects_unsupported_shapes() {
        let (msg, guids) = fixture();
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.voice = true;
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.effect = Some("effect".to_owned());
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.reply_guid = Some("r".to_owned());
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.scheduled = Some(rustpush::ScheduleMode {
                ms: 1,
                schedule: true,
            });
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.subject = Some("s".to_owned());
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.app = Some(rustpush::ExtensionApp {
                name: "x".to_owned(),
                app_id: None,
                bundle_id: "com.example.x".to_owned(),
                balloon: None,
            });
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.service = MessageType::SMS {
                is_phone: true,
                using_number: "tel:+15550001111".to_owned(),
                from_handle: None,
            };
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        bad.message = Message::RenameMessage(rustpush::RenameMessage {
            new_name: "x".to_owned(),
        });
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        bad.message = Message::Delivered;
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.parts.0.push(IndexedMessagePart {
                part: MessagePart::Mention("u".to_owned(), "t".to_owned()),
                idx: None,
                ext: None,
            });
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.parts.0.push(IndexedMessagePart {
                part: MessagePart::Object("c".to_owned()),
                idx: None,
                ext: None,
            });
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.parts.0[0] = IndexedMessagePart {
                part: MessagePart::Text(
                    "hi".to_owned(),
                    rustpush::TextFormat::Flags(rustpush::TextFlags {
                        bold: true,
                        italic: false,
                        underline: false,
                        strikethrough: false,
                    }),
                ),
                idx: None,
                ext: None,
            };
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.parts.0[0] = IndexedMessagePart {
                part: MessagePart::Text(
                    "hi".to_owned(),
                    rustpush::TextFormat::Effect(rustpush::TextEffect::Big),
                ),
                idx: None,
                ext: None,
            };
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                a.a_type = AttachmentType::Inline(vec![1, 2, 3]);
            }
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            normal.parts.0[1].ext = Some(rustpush::PartExtension::Sticker {
                msg_width: 1.0,
                rotation: 0.0,
                sai: 0,
                scale: 1.0,
                update: None,
                sli: 0,
                normalized_x: 0.0,
                normalized_y: 0.0,
                version: 1,
                hash: "h".to_owned(),
                safi: 0,
                effect_type: 0,
                sticker_id: "s".to_owned(),
            });
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        bad.target = Some(vec![rustpush::MessageTarget::Uuid("x".to_owned())]);
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        bad.verification_failed = true;
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
        let mut bad = msg.clone();
        bad.certified_context = Some(rustpush::CertifiedContext {
            version: 1,
            receipt: vec![1],
            sender: "s".to_owned(),
            target: "t".to_owned(),
            uuid: vec![2],
            token: vec![3],
        });
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::UnsupportedMessage)
        ));
    }
    #[test]
    fn rejects_malformed_and_mismatched_guids() {
        let (msg, guids) = fixture();
        assert!(matches!(
            encode_ids_attachment_source(&msg, &[]),
            Err(Failure::MalformedMessage)
        ));
        let dup = vec![guids[0].clone(), guids[0].clone()];
        assert!(matches!(
            encode_ids_attachment_source(&msg, &[guids[0].clone(), "EXTRA-GUID".to_owned()]),
            Err(Failure::BindingMismatch)
        ));
        assert!(matches!(
            encode_ids_attachment_source(&msg, &dup),
            Err(Failure::MalformedMessage)
        ));
        assert!(matches!(
            encode_ids_attachment_source(&msg, &["".to_owned()]),
            Err(Failure::MalformedMessage)
        ));
        let mut bad = msg.clone();
        bad.sender = None;
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::MalformedMessage)
        ));
        let mut bad = msg.clone();
        bad.conversation = None;
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::MalformedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                if let AttachmentType::MMCS(mmcs) = &mut a.a_type {
                    mmcs.key.truncate(31);
                }
            }
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::MalformedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                if let AttachmentType::MMCS(mmcs) = &mut a.a_type {
                    mmcs.signature.truncate(20);
                }
            }
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::MalformedMessage)
        ));
        let mut bad = msg.clone();
        if let Message::Message(normal) = &mut bad.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                if let AttachmentType::MMCS(mmcs) = &mut a.a_type {
                    mmcs.object.clear();
                }
            }
        }
        assert!(matches!(
            encode_ids_attachment_source(&bad, &guids),
            Err(Failure::MalformedMessage)
        ));
        assert!(decode_ids_attachment_source(&[]).is_err());
        let (msg2, guids2) = fixture_two();
        let dup2 = vec![guids2[0].clone(), guids2[0].clone()];
        assert!(matches!(
            encode_ids_attachment_source(&msg2, &dup2),
            Err(Failure::MalformedMessage)
        ));
    }
    #[test]
    fn rejects_future_truncated_and_oversized() {
        let (msg, guids) = fixture();
        let encoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        let mut envelope = CloudSyncIdsAttachmentSourceV1::decode(encoded.as_slice()).unwrap();
        envelope.schema_version += 1;
        assert!(decode_ids_attachment_source(&envelope.encode_to_vec()).is_err());
        assert!(decode_ids_attachment_source(&encoded[..encoded.len() - 10]).is_err());
        assert!(decode_ids_attachment_source(&vec![0u8; MAX_ENVELOPE_BYTES + 1]).is_err());
        let mut many_parts = vec![text_part("bulk")];
        let mut many_guids = Vec::new();
        for i in 0..65u8 {
            many_parts.push(attachment_part(i % 250, i as u64, None));
            many_guids.push(format!("G-{i}"));
        }
        let mut bulk = msg.clone();
        if let Message::Message(normal) = &mut bulk.message {
            normal.parts = MessageParts(many_parts);
        }
        assert!(matches!(
            encode_ids_attachment_source(&bulk, &many_guids),
            Err(Failure::OversizedMessage)
        ));
        let mut big = msg.clone();
        if let Message::Message(normal) = &mut big.message {
            normal.parts.0[0] = text_part(&"x".repeat(2 * 1024 * 1024));
        }
        assert!(matches!(
            encode_ids_attachment_source(&big, &guids),
            Err(Failure::OversizedMessage)
        ));
    }
    #[test]
    fn preserves_empty_file_and_empty_group_name() {
        let (mut msg, guids) = fixture();
        if let Message::Message(normal) = &mut msg.message {
            if let MessagePart::Attachment(a) = &mut normal.parts.0[1].part {
                if let AttachmentType::MMCS(mmcs) = &mut a.a_type {
                    mmcs.size = 0;
                }
            }
        }
        let encoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        validate_ids_attachment_source(&encoded, &msg, &guids).unwrap();
        let decoded = decode_ids_attachment_source(&encoded).unwrap();
        assert!(decoded.attachments()[0].size == 0);
        let (mut msg2, guids2) = fixture();
        if let Some(conversation) = msg2.conversation.as_mut() {
            conversation.cv_name = Some("".to_owned());
        }
        let encoded2 = encode_ids_attachment_source(&msg2, &guids2).unwrap();
        validate_ids_attachment_source(&encoded2, &msg2, &guids2).unwrap();
        let decoded2 = decode_ids_attachment_source(&encoded2).unwrap();
        assert!(decoded2.cv_name == Some("".to_owned()));
    }
    #[test]
    fn group_profile_and_all_descriptor_fields_survive_capture() {
        let (mut msg, guids) = fixture_two();
        let conversation = msg.conversation.as_mut().unwrap();
        conversation
            .participants
            .push("third@example.invalid".to_owned());
        conversation.cv_name = Some("Synthetic group".to_owned());
        conversation.after_guid = Some("prior-message".to_owned());
        if let Message::Message(normal) = &mut msg.message {
            normal.embedded_profile = Some(rustpush::ShareProfileMessage {
                cloud_kit_record_key: "synthetic-profile".to_owned(),
                cloud_kit_decryption_record_key: vec![3; 32],
                poster: Some(rustpush::SharedPoster {
                    low_res_wallpaper_tag: vec![1, 2],
                    wallpaper_tag: vec![3, 4],
                    message_tag: vec![5, 6],
                }),
            });
        }
        let encoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        validate_ids_attachment_source(&encoded, &msg, &guids).unwrap();
        let decoded = decode_ids_attachment_source(&encoded).unwrap();
        assert_eq!(decoded.participants.len(), 3);
        assert_eq!(decoded.cv_name.as_deref(), Some("Synthetic group"));
        assert_eq!(decoded.after_guid.as_deref(), Some("prior-message"));
        let attachment = decoded.attachments()[1];
        assert_eq!(attachment.url, "https://example.invalid/mmcs/object-9");
        assert_eq!(attachment.name, "photo-9.jpg");
        assert_eq!(attachment.uti_type, "public.jpeg");
        assert_eq!(attachment.mime, "image/jpeg");
        let profile = decoded.embedded_profile.as_ref().unwrap();
        assert_eq!(profile.record_key, "synthetic-profile");
        assert_eq!(profile.decryption_key, vec![3; 32]);
        let poster = profile.poster.as_ref().unwrap();
        assert_eq!(poster.low_res, vec![1, 2]);
        assert_eq!(poster.wallpaper, vec![3, 4]);
        assert_eq!(poster.message, vec![5, 6]);
    }

    #[test]
    fn prepared_validation_accepts_real_prepare_send_without_weakening_body_binding() {
        let (mut original, guids) = fixture();
        let conversation = original.conversation.as_mut().unwrap();
        conversation.sender_guid = None;
        conversation.participants.remove(0);
        let source = encode_ids_attachment_source(&original, &guids).unwrap();
        let now = || {
            u64::try_from(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_millis(),
            )
            .unwrap()
        };
        let start = now();
        let mut prepared = original.clone();
        prepared.prepare_send(&[original.sender.clone().unwrap()]);
        let end = now();
        validate_prepared_ids_attachment_source(&source, &prepared, &guids, start, end).unwrap();
        assert!(validate_ids_attachment_source(&source, &prepared, &guids).is_err());
        assert!(validate_prepared_ids_attachment_source(&source, &prepared, &guids, 0, 1).is_err());
        assert!(validate_prepared_ids_attachment_source(
            &source,
            &prepared,
            &guids,
            end + 1,
            start
        )
        .is_err());
        let mutations: &[fn(&mut MessageInst)] = &[
            |m| {
                m.conversation
                    .as_mut()
                    .unwrap()
                    .participants
                    .push("other@example.invalid".to_owned())
            },
            |m| {
                m.conversation.as_mut().unwrap().participants.remove(0);
            },
            |m| {
                m.conversation.as_mut().unwrap().sender_guid =
                    Some("not-a-generated-uuid".to_owned())
            },
            |m| m.conversation.as_mut().unwrap().cv_name = Some("changed".to_owned()),
            |m| m.sender = Some("changed@example.invalid".to_owned()),
            |m| {
                if let Message::Message(n) = &mut m.message {
                    n.parts.0[0] = text_part("changed");
                }
            },
            |m| {
                if let Message::Message(n) = &mut m.message {
                    if let MessagePart::Attachment(a) = &mut n.parts.0[1].part {
                        if let AttachmentType::MMCS(mmcs) = &mut a.a_type {
                            mmcs.object.push('x');
                        }
                    }
                }
            },
        ];
        for mutate in mutations {
            let mut changed = prepared.clone();
            mutate(&mut changed);
            assert!(
                validate_prepared_ids_attachment_source(&source, &changed, &guids, start, end)
                    .is_err()
            );
        }
        // Existing sender GUIDs must remain exact, not just any valid UUID.
        let (original, guids) = fixture();
        let source = encode_ids_attachment_source(&original, &guids).unwrap();
        let mut changed = original;
        changed.sent_timestamp = start;
        changed.conversation.as_mut().unwrap().sender_guid = Some(uuid::Uuid::new_v4().to_string());
        assert!(
            validate_prepared_ids_attachment_source(&source, &changed, &guids, start, end).is_err()
        );
    }

    #[test]
    fn recovery_rejects_unknown_protobuf_and_plist_fields() {
        let (msg, guids) = fixture();
        let encoded = encode_ids_attachment_source(&msg, &guids).unwrap();
        let mut extended = encoded.clone();
        extended.extend_from_slice(&[0x78, 0x01]); // Unknown protobuf field 15.
        assert!(decode_ids_attachment_source(&extended).is_err());
        let mut envelope = CloudSyncIdsAttachmentSourceV1::decode(encoded.as_slice()).unwrap();
        let mut plist: plist::Value =
            plist::from_reader(Cursor::new(&envelope.source_plist)).unwrap();
        plist
            .as_dictionary_mut()
            .unwrap()
            .insert("future_flag".to_owned(), true.into());
        envelope.source_plist.clear();
        plist::to_writer_binary(&mut envelope.source_plist, &plist).unwrap();
        assert!(decode_ids_attachment_source(&envelope.encode_to_vec()).is_err());
    }

    #[test]
    fn stage_shape_and_uncommitted_lease_gate() {
        let (msg, guids) = fixture();
        let directory = tempfile::tempdir().unwrap();
        let account = "A".repeat(43);
        let sha = "a".repeat(64);
        let stage = stage_ids_attachment_source(
            directory.path().to_path_buf(),
            account.clone(),
            &sha,
            &msg,
            &guids,
        )
        .unwrap();
        assert!(stage.payload_sha256.len() == 64);
        assert!(stage.payload_length > 0);
        assert!(verify_staged_ids_attachment_source(
            directory.path().to_path_buf(),
            account.clone(),
            &sha,
            &msg,
            &guids,
            &stage
        )
        .is_err());
        assert!(open_staged_ids_attachment_source(
            directory.path().to_path_buf(),
            account.clone(),
            &sha,
            &stage
        )
        .is_err());
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
        let recovered = verify_staged_ids_attachment_source(
            directory.path().to_path_buf(),
            account.clone(),
            &sha,
            &msg,
            &guids,
            &stage,
        )
        .unwrap();
        assert_eq!(recovered.message_guid, msg.id);
        assert_eq!(recovered.attachments()[0].key, vec![8; 32]);
        assert!(open_staged_ids_attachment_source(
            directory.path().to_path_buf(),
            "B".repeat(43),
            &sha,
            &stage,
        )
        .is_err());
        assert!(open_staged_ids_attachment_source(
            directory.path().to_path_buf(),
            account.clone(),
            &"b".repeat(64),
            &stage,
        )
        .is_err());
        let mut changed_stage = stage.clone();
        changed_stage.payload_sha256 = "f".repeat(64);
        assert!(open_staged_ids_attachment_source(
            directory.path().to_path_buf(),
            account.clone(),
            &sha,
            &changed_stage,
        )
        .is_err());
        let bad_stage = NativeIdsAttachmentSourceStage {
            protected_reference: "".to_owned(),
            lease_reference: stage.lease_reference.clone(),
            payload_sha256: stage.payload_sha256.clone(),
            payload_length: stage.payload_length,
        };
        assert!(matches!(
            open_staged_ids_attachment_source(
                directory.path().to_path_buf(),
                account,
                &sha,
                &bad_stage
            ),
            Err(Failure::MalformedMessage)
        ));
    }
}
