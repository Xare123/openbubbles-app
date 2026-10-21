//! Immutable received source. No network, persistence, IDS send or
//! CloudKit authority. Raw content stays native and must be protected by the
//! separate staging wrapper before retention. No Debug implementations.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_ids_attachment_source::{
    decode_ids_attachment_source, encode_received_attachment_body,
    message_inst_from_decoded_source, DecodedIdsAttachmentSource, DecodedPart,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rustpush::{Message, MessageInst, MessagePart, MessageTarget, MessageType, TextFormat};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

const DOMAIN: &str = "cloud-sync-ids-received-source";
const MAX_BYTES: usize = 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 4096;
const MAX_HANDLES: usize = 64;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ReceivedArchiveOrigin {
    Incoming,
    Mirrored,
}

impl ReceivedArchiveOrigin {
    fn label(self) -> &'static str {
        match self {
            Self::Incoming => "incoming",
            Self::Mirrored => "mirrored",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Source {
    domain: String,
    version: u32,
    guid: String,
    sender: String,
    received_on_handle: String,
    origin: ReceivedArchiveOrigin,
    peer: String,
    sent_timestamp: u64,
    text: String,
    participants: Vec<String>,
    self_handles: Vec<String>,
    sender_guid: Option<String>,
    conversation_name: Option<String>,
    after_guid: Option<String>,
    // Trailing and omitted for V1 keeps every existing direct-source byte
    // unchanged. A V2 group has no direct peer; exact discovery uses its GUID.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    group_id: Option<String>,
    // V3 retains the complete bounded native body codec. Older source bytes
    // and their direct/group digest contracts remain byte-for-byte unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    attachment_body: Option<String>,
}

pub(crate) struct ReceivedArchiveSource(Source);

impl ReceivedArchiveSource {
    /// Caller must obtain local_handles from the same observed native identity,
    /// not chat preferences. This codec validates shape, not that provenance.
    pub(crate) fn capture(
        message: &MessageInst,
        local_handles: &[String],
    ) -> Result<Self, Failure> {
        identifier(&message.id)?;
        if message.id.starts_with("temp")
            || message.id.starts_with("error")
            || message.verification_failed
        {
            return Err(Failure::UnsupportedMessage);
        }
        handles(local_handles)?;
        let sender = message.sender.as_deref().ok_or(Failure::MalformedMessage)?;
        let recipient = message
            .received_on_handle
            .as_deref()
            .ok_or(Failure::BindingMismatch)?;
        handle(sender)?;
        handle(recipient)?;
        if !local_handles.iter().any(|h| h == recipient) {
            return Err(Failure::BindingMismatch);
        }
        if message.sent_timestamp == 0 || message.sent_timestamp > i64::MAX as u64 {
            return Err(Failure::MalformedMessage);
        }
        let origin = if local_handles.iter().any(|h| h == sender) {
            ReceivedArchiveOrigin::Mirrored
        } else {
            ReceivedArchiveOrigin::Incoming
        };
        if let Some(targets) = &message.target {
            if !targets.is_empty()
                && !matches!(targets.as_slice(), [MessageTarget::Token(token)] if token.len() == 32)
            {
                return Err(Failure::UnsupportedMessage);
            }
        }
        if let Some(certified) = &message.certified_context {
            if certified.sender != sender || certified.target != recipient {
                return Err(Failure::BindingMismatch);
            }
        }
        let Message::Message(normal) = &message.message else {
            return Err(Failure::UnsupportedMessage);
        };
        if !matches!(normal.service, MessageType::IMessage)
            || normal.voice
            || normal.scheduled.is_some()
            || normal.reply_guid.is_some()
            || normal.reply_part.is_some()
            || normal.effect.is_some()
            || normal.subject.as_ref().is_some_and(|v| !v.is_empty())
            || normal.app.is_some()
            || normal.link_meta.is_some()
            || normal.embedded_profile.is_some()
            || normal.parts.0.is_empty()
            || normal.parts.0.len() > 128
        {
            return Err(Failure::UnsupportedMessage);
        }
        let has_media = normal
            .parts
            .0
            .iter()
            .any(|p| matches!(&p.part, MessagePart::Attachment(_)));
        let mut text = String::new();
        for indexed in &normal.parts.0 {
            if indexed.ext.is_some()
                || if has_media {
                    indexed.idx.is_some_and(|v| v > i64::MAX as usize)
                } else {
                    indexed.idx.is_some_and(|v| v != 0)
                }
            {
                return Err(Failure::UnsupportedMessage);
            }
            let value = match &indexed.part {
                MessagePart::Text(value, TextFormat::Flags(flags)) => {
                    if flags.bold || flags.italic || flags.underline || flags.strikethrough {
                        return Err(Failure::UnsupportedMessage);
                    }
                    value.as_str()
                }
                MessagePart::Attachment(attachment)
                    if has_media && attachment.part <= i64::MAX as u64 =>
                {
                    " "
                }
                _ => return Err(Failure::UnsupportedMessage),
            };
            if text
                .len()
                .checked_add(value.len())
                .is_none_or(|n| n > MAX_TEXT_BYTES)
            {
                return Err(Failure::OversizedMessage);
            }
            text.push_str(value);
        }
        if !has_media && text.trim_matches(dart_whitespace).is_empty() {
            return Err(Failure::MalformedMessage);
        }
        let conversation = message
            .conversation
            .as_ref()
            .ok_or(Failure::MalformedMessage)?;
        handles(&conversation.participants)?;
        optional_identifier(&conversation.sender_guid)?;
        optional_identifier(&conversation.after_guid)?;
        if conversation
            .cv_name
            .as_ref()
            .is_some_and(|v| v.len() > MAX_IDENTIFIER_BYTES)
        {
            return Err(Failure::OversizedMessage);
        }
        let counterparts = conversation
            .participants
            .iter()
            .filter(|h| !local_handles.contains(h))
            .map(|h| bare(h))
            .collect::<HashSet<_>>();
        if counterparts.is_empty() {
            return Err(Failure::UnsupportedMessage);
        }
        let group_id = if counterparts.len() > 1 {
            // Direct sends also carry sender_guid, so UUID alone is not a
            // group discriminator. Preserve the exact multi-party wire ID;
            // no title/member hash/alias is promoted to parent or create proof.
            let group = conversation
                .sender_guid
                .as_deref()
                .filter(|value| group_uuid(value))
                .ok_or(Failure::UnsupportedMessage)?;
            if origin == ReceivedArchiveOrigin::Incoming
                && !conversation
                    .participants
                    .iter()
                    .any(|value| value == sender)
            {
                return Err(Failure::BindingMismatch);
            }
            Some(group.to_owned())
        } else {
            None
        };
        let peer = if group_id.is_none() {
            *counterparts
                .iter()
                .next()
                .ok_or(Failure::MalformedMessage)?
        } else {
            ""
        };
        if origin == ReceivedArchiveOrigin::Incoming && !counterparts.contains(bare(sender)) {
            return Err(Failure::BindingMismatch);
        }
        let mut participants = conversation.participants.clone();
        // Dart String.compareTo orders UTF-16 code units, not UTF-8/codepoints.
        participants.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
        let mut self_handles = local_handles
            .iter()
            .filter(|h| {
                h.as_str() == recipient
                    || h.as_str() == sender
                    || conversation.participants.contains(h)
            })
            .cloned()
            .collect::<Vec<_>>();
        self_handles.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
        self_handles.dedup();
        let source = Source {
            domain: DOMAIN.into(),
            version: if has_media {
                3
            } else if group_id.is_some() {
                2
            } else {
                1
            },
            guid: message.id.clone(),
            sender: sender.into(),
            received_on_handle: recipient.into(),
            origin,
            peer: peer.into(),
            sent_timestamp: message.sent_timestamp,
            text,
            participants,
            self_handles,
            sender_guid: conversation.sender_guid.clone(),
            conversation_name: conversation.cv_name.clone(),
            after_guid: conversation.after_guid.clone(),
            group_id,
            attachment_body: if has_media {
                Some(URL_SAFE_NO_PAD.encode(encode_received_attachment_body(message)?))
            } else {
                None
            },
        };
        let received = Self(source);
        received.encode()?;
        Ok(received)
    }

    pub(crate) fn encode(&self) -> Result<Vec<u8>, Failure> {
        let bytes = serde_json::to_vec(&self.0).map_err(|_| Failure::MalformedMessage)?;
        if bytes.len() > MAX_BYTES {
            return Err(Failure::OversizedMessage);
        }
        Ok(bytes)
    }

    pub(crate) fn decode(bytes: &[u8]) -> Result<Self, Failure> {
        if bytes.is_empty() || bytes.len() > MAX_BYTES {
            return Err(Failure::OversizedMessage);
        }
        let source: Source =
            serde_json::from_slice(bytes).map_err(|_| Failure::MalformedMessage)?;
        if source.domain != DOMAIN || !matches!(source.version, 1 | 2 | 3) {
            return Err(Failure::UnsupportedMessage);
        }
        if (source.version == 1 && source.group_id.is_some())
            || (source.version == 2 && source.group_id.is_none())
            || (source.group_id.is_some()
                && (!source.peer.is_empty()
                    || !source.group_id.as_deref().is_some_and(group_uuid)
                    || source.group_id != source.sender_guid))
            || ((source.version == 3) != source.attachment_body.is_some())
        {
            return Err(Failure::BindingMismatch);
        }
        // Reconstruct only privately to reapply bounds. No caller receives a
        // sendable MessageInst, a delivery receipt, or reply-device token.
        let mut wire = MessageInst {
            id: source.guid.clone(),
            sender: Some(source.sender.clone()),
            received_on_handle: Some(source.received_on_handle.clone()),
            conversation: Some(rustpush::ConversationData {
                participants: source.participants.clone(),
                cv_name: source.conversation_name.clone(),
                sender_guid: source.sender_guid.clone(),
                after_guid: source.after_guid.clone(),
            }),
            message: Message::Message(rustpush::NormalMessage::new(
                source.text.clone(),
                MessageType::IMessage,
            )),
            sent_timestamp: source.sent_timestamp,
            target: None,
            send_delivered: false,
            verification_failed: false,
            certified_context: None,
        };
        if let Some(body) = &source.attachment_body {
            let decoded = decode_media_body(body)?;
            let (mut restored, _) = message_inst_from_decoded_source(&decoded)?;
            restored.received_on_handle = Some(source.received_on_handle.clone());
            wire = restored;
        }
        let canonical = Self::capture(&wire, &source.self_handles)?;
        if canonical.0 != source || canonical.encode()? != bytes {
            return Err(Failure::BindingMismatch);
        }
        Ok(canonical)
    }

    pub(crate) fn guid(&self) -> &str {
        &self.0.guid
    }
    pub(crate) fn sender(&self) -> &str {
        &self.0.sender
    }
    pub(crate) fn recipient(&self) -> &str {
        &self.0.received_on_handle
    }
    pub(crate) fn peer(&self) -> &str {
        &self.0.peer
    }
    pub(crate) fn group_id(&self) -> Option<&str> {
        self.0.group_id.as_deref()
    }
    pub(crate) fn text(&self) -> &str {
        &self.0.text
    }
    pub(crate) fn has_media(&self) -> bool {
        self.0.attachment_body.is_some()
    }
    /// Raw native body only. The surrounding received envelope supplies origin
    /// proof; this return value is neither an outgoing receipt nor child proof.
    pub(crate) fn media_body(&self) -> Result<DecodedIdsAttachmentSource, Failure> {
        decode_media_body(
            self.0
                .attachment_body
                .as_deref()
                .ok_or(Failure::UnsupportedMessage)?,
        )
    }
    /// Reuse the descriptor-to-metadata codec, with direction and fixed times
    /// supplied by this authenticated receive source rather than UI state.
    /// A matching plaintext snapshot, child upload and exact record readback
    /// are still required; this is not an upload receipt or retry grant.
    pub(crate) fn media_upload_material(
        &self,
        original_attachment_guid: &str,
    ) -> Result<crate::cloud_sync_ids_attachment_source::DecodedAttachmentUploadMaterial, Failure>
    {
        let time = i64::try_from(self.sent_timestamp())
            .ok()
            .and_then(|time| time.checked_sub(978_307_200_000))
            .and_then(|time| time.checked_mul(1_000_000))
            .filter(|time| *time > 0)
            .ok_or(Failure::MalformedMessage)?;
        let mut material =
            crate::cloud_sync_ids_attachment_source::decoded_attachment_upload_material(
                &self.media_body()?,
                original_attachment_guid,
                &crate::cloud_sync_ids_attachment_source::NativeAttachmentMetaTimes {
                    start_date_ns: time,
                    created_date_ns: time,
                },
            )?;
        material.meta.is_outgoing = self.origin() == ReceivedArchiveOrigin::Mirrored;
        Ok(material)
    }
    pub(crate) fn origin(&self) -> ReceivedArchiveOrigin {
        self.0.origin
    }
    pub(crate) fn sent_timestamp(&self) -> u64 {
        self.0.sent_timestamp
    }
    pub(crate) fn guid_hash(&self) -> Result<String, Failure> {
        digest(&serde_json::json!([
            "cloud-sync-received-archive-guid-v1",
            self.0.guid
        ]))
    }
    /// Direct V1 and group V2 digest contracts shared with Dart. The group
    /// identity replaces only the route field; it never becomes a direct peer.
    pub(crate) fn source_sha256(&self) -> Result<String, Failure> {
        let s = &self.0;
        let mut fields = serde_json::json!([
            if self.has_media() {
                "cloud-sync-received-archive-source-v3"
            } else if s.group_id.is_some() {
                "cloud-sync-received-archive-source-v2"
            } else {
                "cloud-sync-received-archive-source-v1"
            },
            s.guid,
            s.text,
            s.group_id.as_deref().unwrap_or(&s.peer),
            s.sender,
            s.received_on_handle,
            s.sent_timestamp,
            s.origin.label(),
            s.sender_guid.as_deref().unwrap_or(""),
            s.participants,
            s.conversation_name.as_deref().unwrap_or(""),
            s.after_guid.as_deref().unwrap_or("")
        ]);
        if self.has_media() {
            fields
                .as_array_mut()
                .ok_or(Failure::MalformedMessage)?
                .push(media_manifest(&self.media_body()?));
        }
        digest(&fields)
    }
}

fn decode_media_body(encoded: &str) -> Result<DecodedIdsAttachmentSource, Failure> {
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| Failure::MalformedMessage)?;
    decode_ids_attachment_source(&bytes)
}

fn media_manifest(body: &DecodedIdsAttachmentSource) -> serde_json::Value {
    serde_json::Value::Array(
        body.parts
            .iter()
            .map(|part| match part {
                DecodedPart::Text { text, idx } => serde_json::json!([0, text, idx]),
                DecodedPart::Attachment(a) => serde_json::json!([
                    1,
                    a.part,
                    a.uti_type,
                    a.mime,
                    a.name,
                    a.iris,
                    [a.key, a.signature, a.object, a.url, a.size],
                    a.idx
                ]),
            })
            .collect(),
    )
}

fn dart_whitespace(c: char) -> bool {
    c.is_whitespace() || c == '\u{feff}'
}
fn bare(value: &str) -> &str {
    value
        .strip_prefix("mailto:")
        .or_else(|| value.strip_prefix("tel:"))
        .unwrap_or(value)
}
fn group_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}
fn identifier(value: &str) -> Result<(), Failure> {
    if value.is_empty() || value.trim_matches(dart_whitespace) != value || value.contains('\0') {
        return Err(Failure::MalformedMessage);
    }
    if value.len() > MAX_IDENTIFIER_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}
fn optional_identifier(value: &Option<String>) -> Result<(), Failure> {
    if let Some(value) = value {
        identifier(value)?;
    }
    Ok(())
}
fn handle(value: &str) -> Result<(), Failure> {
    identifier(value)?;
    if bare(value) == value || bare(value).is_empty() {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn handles(values: &[String]) -> Result<(), Failure> {
    if values.is_empty() || values.len() > MAX_HANDLES {
        return Err(Failure::OversizedMessage);
    }
    for value in values {
        handle(value)?;
    }
    Ok(())
}
fn digest(value: &serde_json::Value) -> Result<String, Failure> {
    let bytes = serde_json::to_vec(value).map_err(|_| Failure::MalformedMessage)?;
    Ok(hex_digest(&bytes))
}
pub(crate) fn hex_digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use rustpush::{ConversationData, NormalMessage};

    pub(crate) fn fixture(mirrored: bool, text: &str) -> (MessageInst, Vec<String>) {
        let owner = "mailto:owner@example.com";
        (
            MessageInst {
                id: "11111111-2222-4333-8444-555555555555".into(),
                sender: Some(
                    if mirrored {
                        owner
                    } else {
                        "mailto:remote@example.com"
                    }
                    .into(),
                ),
                received_on_handle: Some(owner.into()),
                conversation: Some(ConversationData {
                    participants: vec![owner.into(), "mailto:remote@example.com".into()],
                    sender_guid: Some("iMessage;-;remote@example.com".into()),
                    cv_name: None,
                    after_guid: None,
                }),
                message: Message::Message(NormalMessage::new(text.into(), MessageType::IMessage)),
                sent_timestamp: 1_700_000_000_000,
                target: Some(vec![MessageTarget::Token(vec![0; 32])]),
                send_delivered: true,
                verification_failed: false,
                certified_context: None,
            },
            vec![owner.into()],
        )
    }

    #[test]
    fn both_origins_round_trip_without_reply_tokens_or_send_authority() {
        for mirrored in [false, true] {
            let (message, handles) = fixture(mirrored, "Plain 😀 text\nsecond line");
            let source = ReceivedArchiveSource::capture(&message, &handles).unwrap();
            let bytes = source.encode().unwrap();
            let decoded = ReceivedArchiveSource::decode(&bytes).unwrap();
            assert_eq!(decoded.encode().unwrap(), bytes);
            assert_eq!(decoded.guid(), message.id);
            assert_eq!(decoded.text(), "Plain 😀 text\nsecond line");
            assert_eq!(decoded.sender(), message.sender.as_deref().unwrap());
            assert_eq!(decoded.recipient(), "mailto:owner@example.com");
            assert_eq!(decoded.peer(), "remote@example.com");
            assert_eq!(decoded.sent_timestamp(), message.sent_timestamp);
            assert!(
                decoded.origin()
                    == if mirrored {
                        ReceivedArchiveOrigin::Mirrored
                    } else {
                        ReceivedArchiveOrigin::Incoming
                    }
            );
            let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert!(value.get("target").is_none());
            assert!(value.get("certified_context").is_none());
        }
    }

    #[test]
    fn source_digests_match_frozen_dart_contract() {
        for (mirrored, text, expected) in [
            (
                false,
                "ordinary text",
                "fdde0b390b27b7ed2f8c60d5a31f9db00bd9ccd729afb2c888f98ff7393f2ef7",
            ),
            (
                true,
                "ordinary text",
                "2b7a5f9b720ef09df984f991abbe4bcb68efa22ea068b99ff9a976d1aa7b6bbf",
            ),
            (
                false,
                "line 1\n\"quoted\" \\ \t\u{2028}\u{2029} 😀",
                "30b46daaa0f3829424ee39d78a59e17390c75f0ee6beb6a587b0dadb44436fc4",
            ),
        ] {
            let (message, handles) = fixture(mirrored, text);
            let source = ReceivedArchiveSource::capture(&message, &handles).unwrap();
            assert_eq!(
                source.guid_hash().unwrap(),
                "cd7c99cec32925c682dd556e85b3f86856765d9dadc8c3b5796f8f5f4deccf57"
            );
            assert_eq!(source.source_sha256().unwrap(), expected);
        }
    }

    const GROUP_ID: &str = "77777777-8888-4999-aaaa-bbbbbbbbbbbb";
    pub(crate) fn media_fixture(mirrored: bool, group: bool) -> (MessageInst, Vec<String>) {
        let (mut wire, handles) = fixture(mirrored, "caption");
        if group {
            let conversation = wire.conversation.as_mut().unwrap();
            conversation.sender_guid = Some(GROUP_ID.into());
            conversation.participants.push("tel:+15550000002".into());
        }
        let Message::Message(normal) = &mut wire.message else {
            unreachable!()
        };
        normal.parts.0[0].idx = Some(0);
        normal.parts.0.push(rustpush::IndexedMessagePart {
            part: MessagePart::Attachment(rustpush::Attachment {
                a_type: rustpush::AttachmentType::MMCS(rustpush::MMCSFile {
                    key: vec![7; 32],
                    signature: vec![9; 21],
                    object: "object-media".into(),
                    url: "https://example.invalid/mmcs/media".into(),
                    size: 1234,
                }),
                part: 2,
                uti_type: "public.heic".into(),
                mime: "image/heic".into(),
                name: "photo.heic".into(),
                iris: false,
            }),
            idx: Some(7),
            ext: None,
        });
        (wire, handles)
    }

    #[test]
    fn received_media_v3_round_trip_preserves_full_body_and_both_routes_origins() {
        for mirrored in [false, true] {
            for group in [false, true] {
                let (wire, handles) = media_fixture(mirrored, group);
                let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
                let bytes = source.encode().unwrap();
                let restored = ReceivedArchiveSource::decode(&bytes).unwrap();
                assert_eq!(restored.encode().unwrap(), bytes);
                assert_eq!(
                    restored.source_sha256().unwrap(),
                    source.source_sha256().unwrap()
                );
                assert!(restored.has_media());
                assert_eq!(restored.text(), "caption ");
                assert_eq!(
                    restored.group_id(),
                    if group { Some(GROUP_ID) } else { None }
                );
                let body = restored.media_body().unwrap();
                assert_eq!(body.message_guid, wire.id);
                assert_eq!(body.sender, wire.sender.as_deref().unwrap());
                assert_eq!(body.attachments()[0].key, vec![7; 32]);
                assert_eq!(body.attachments()[0].signature, vec![9; 21]);
                assert_eq!(body.attachments()[0].idx, Some(7));
                assert_eq!(body.attachments()[0].part, 2);
                // The original outgoing entry point still refuses receive
                // contexts, regardless of the shared body representation.
                assert!(
                    crate::cloud_sync_ids_attachment_source::encode_ids_attachment_source(
                        &wire,
                        &["received:0".into()]
                    )
                    .is_err()
                );
            }
        }
    }

    #[test]
    fn received_media_v3_descriptor_and_body_drift_changes_source_identity() {
        let (wire, handles) = media_fixture(false, false);
        let baseline = ReceivedArchiveSource::capture(&wire, &handles)
            .unwrap()
            .source_sha256()
            .unwrap();
        for mutate in [
            (|a: &mut rustpush::Attachment| a.name = "other.heic".into())
                as fn(&mut rustpush::Attachment),
            |a| a.mime = "video/quicktime".into(),
            |a| a.uti_type = "com.apple.quicktime-movie".into(),
            |a| a.iris = true,
            |a| a.part = 3,
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.key[0] ^= 1;
                }
            },
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.signature[0] ^= 1;
                }
            },
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.object.push('x');
                }
            },
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.url.push('x');
                }
            },
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.size += 1;
                }
            },
        ] {
            let mut changed = wire.clone();
            let Message::Message(normal) = &mut changed.message else {
                unreachable!()
            };
            let MessagePart::Attachment(attachment) = &mut normal.parts.0[1].part else {
                unreachable!()
            };
            mutate(attachment);
            assert_ne!(
                ReceivedArchiveSource::capture(&changed, &handles)
                    .unwrap()
                    .source_sha256()
                    .unwrap(),
                baseline
            );
        }
        for change_index in [false, true] {
            let mut changed = wire.clone();
            let Message::Message(normal) = &mut changed.message else {
                unreachable!()
            };
            if change_index {
                normal.parts.0[1].idx = Some(8);
            } else {
                normal.parts.0[0].part =
                    MessagePart::Text("other caption".into(), Default::default());
            }
            assert_ne!(
                ReceivedArchiveSource::capture(&changed, &handles)
                    .unwrap()
                    .source_sha256()
                    .unwrap(),
                baseline
            );
        }
    }

    #[test]
    fn received_media_v3_digest_matches_the_cross_language_manifest_vector() {
        let (wire, handles) = media_fixture(false, false);
        let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert_eq!(
            source.source_sha256().unwrap(),
            "052435798c9b6bd01034da39c11740f3fb69c3b3aeccb90e5bc2d6f8967357da"
        );
        // Appending the body manifest must not alter the stable GUID domain.
        assert_eq!(
            source.guid_hash().unwrap(),
            "cd7c99cec32925c682dd556e85b3f86856765d9dadc8c3b5796f8f5f4deccf57"
        );
    }

    #[test]
    fn received_media_upload_material_keeps_immutable_direction_times_and_exact_descriptor() {
        for mirrored in [false, true] {
            let (wire, handles) = media_fixture(mirrored, false);
            let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
            let material = source.media_upload_material("received:0").unwrap();
            assert_eq!(material.meta.is_outgoing, mirrored);
            assert_eq!(material.meta.start_date, 721_692_800_000_000_000);
            assert_eq!(material.meta.guid, format!("at_7_{}", wire.id));
            assert_eq!(material.meta.total_bytes, 1234);
            assert_eq!(material.file.key, vec![7; 32]);
            assert_eq!(material.file.signature, vec![9; 21]);
            assert!(source.media_upload_material("unrelated-local-id").is_err());
        }
    }

    #[test]
    fn received_media_v3_refuses_wrong_context_and_unsupported_or_unbounded_descriptors() {
        let (wire, handles) = media_fixture(false, false);
        for mutate in [
            (|m: &mut MessageInst| m.received_on_handle = None) as fn(&mut MessageInst),
            |m| m.received_on_handle = Some("mailto:wrong@example.com".into()),
            |m| m.verification_failed = true,
            |m| m.target = Some(vec![MessageTarget::Uuid("outbound".into())]),
        ] {
            let mut changed = wire.clone();
            mutate(&mut changed);
            assert!(ReceivedArchiveSource::capture(&changed, &handles).is_err());
        }
        for mutate in [
            (|a: &mut rustpush::Attachment| a.a_type = rustpush::AttachmentType::Inline(vec![1]))
                as fn(&mut rustpush::Attachment),
            |a| a.name.clear(),
            |a| a.part = u64::MAX,
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.key.pop();
                }
            },
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.signature.pop();
                }
            },
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.object = "bad\nobject".into();
                }
            },
            |a| {
                if let rustpush::AttachmentType::MMCS(d) = &mut a.a_type {
                    d.size = 8 * 1024 * 1024 * 1024 + 1;
                }
            },
        ] {
            let mut changed = wire.clone();
            let Message::Message(normal) = &mut changed.message else {
                unreachable!()
            };
            let MessagePart::Attachment(a) = &mut normal.parts.0[1].part else {
                unreachable!()
            };
            mutate(a);
            assert!(ReceivedArchiveSource::capture(&changed, &handles).is_err());
        }
    }

    #[test]
    fn received_media_v3_cannot_be_downgraded_or_rebound_to_a_different_outer_source() {
        let (wire, handles) = media_fixture(false, false);
        let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        for mutate in [
            (|s: &mut Source| s.version = 1) as fn(&mut Source),
            |s| s.attachment_body = None,
            |s| s.text = "caption only".into(),
            |s| s.sender = "mailto:impostor@example.com".into(),
            |s| s.guid = "other-guid".into(),
            |s| s.sent_timestamp += 1,
            |s| s.attachment_body = Some("not-a-body".into()),
        ] {
            let mut changed: Source = serde_json::from_slice(&source.encode().unwrap()).unwrap();
            mutate(&mut changed);
            assert!(ReceivedArchiveSource::decode(&serde_json::to_vec(&changed).unwrap()).is_err());
        }
    }

    #[test]
    fn received_media_v3_supports_media_only_and_opaque_auxiliary_parts_without_stripping() {
        let (mut wire, handles) = media_fixture(false, false);
        let Message::Message(normal) = &mut wire.message else {
            unreachable!()
        };
        normal.parts.0.remove(0);
        let MessagePart::Attachment(a) = &mut normal.parts.0[0].part else {
            unreachable!()
        };
        a.iris = true;
        let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert_eq!(source.text(), " ");
        let restored = ReceivedArchiveSource::decode(&source.encode().unwrap()).unwrap();
        assert!(restored.media_body().unwrap().attachments()[0].iris);
    }

    fn group_fixture(mirrored: bool) -> (MessageInst, Vec<String>) {
        let (mut wire, handles) = fixture(mirrored, "ordinary group text");
        let conversation = wire.conversation.as_mut().unwrap();
        conversation.sender_guid = Some(GROUP_ID.into());
        conversation.participants.push("tel:+15550000002".into());
        (wire, handles)
    }

    #[test]
    fn group_sources_round_trip_and_match_the_dart_v2_digest_contract() {
        for (mirrored, expected) in [
            (
                false,
                "ad58c48da78fecb8240d09454d1832d036e37cd46501a999167630a214fc9cff",
            ),
            (
                true,
                "da8ccfb5bff11ece54778b8ca7a68470fefc190c23c75e9f2a75cf8d89ff206b",
            ),
        ] {
            let (mut wire, handles) = group_fixture(mirrored);
            let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
            let bytes = source.encode().unwrap();
            let decoded = ReceivedArchiveSource::decode(&bytes).unwrap();
            assert_eq!(decoded.encode().unwrap(), bytes);
            assert_eq!(decoded.group_id(), Some(GROUP_ID));
            assert_eq!(decoded.peer(), "");
            assert_eq!(decoded.sender(), wire.sender.as_deref().unwrap());
            assert_eq!(decoded.recipient(), "mailto:owner@example.com");
            assert_eq!(decoded.source_sha256().unwrap(), expected);
            assert_eq!(
                decoded.guid_hash().unwrap(),
                "cd7c99cec32925c682dd556e85b3f86856765d9dadc8c3b5796f8f5f4deccf57"
            );
            wire.conversation.as_mut().unwrap().participants.reverse();
            assert_eq!(
                ReceivedArchiveSource::capture(&wire, &handles)
                    .unwrap()
                    .encode()
                    .unwrap(),
                bytes
            );
        }
    }

    #[test]
    fn direct_v1_bytes_and_uuid_sender_guid_remain_direct() {
        let (mut wire, handles) = fixture(false, "ordinary text");
        let source = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert_eq!(
            std::str::from_utf8(&source.encode().unwrap()).unwrap(),
            concat!(
                r#"{"domain":"cloud-sync-ids-received-source","version":1,"guid":"11111111-2222-4333-8444-555555555555","sender":"mailto:remote@example.com","received_on_handle":"mailto:owner@example.com","origin":"incoming","peer":"remote@example.com","sent_timestamp":1700000000000,"text":"ordinary text","participants":["mailto:owner@example.com","mailto:remote@example.com"],"self_handles":["mailto:owner@example.com"],"sender_guid":"iMessage;-;remote@example.com","conversation_name":null,"after_guid":null}"#,
            )
        );
        wire.conversation.as_mut().unwrap().sender_guid = Some(GROUP_ID.into());
        let with_uuid = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        assert_eq!(with_uuid.group_id(), None);
        assert_eq!(with_uuid.peer(), "remote@example.com");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&with_uuid.encode().unwrap()).unwrap()
                ["version"],
            serde_json::json!(1)
        );
    }

    #[test]
    fn group_sources_refuse_unproven_ids_sender_endpoints_and_rich_content() {
        let (wire, handles) = group_fixture(false);
        for mutate in [
            (|m: &mut MessageInst| m.conversation.as_mut().unwrap().sender_guid = None)
                as fn(&mut MessageInst),
            |m| m.conversation.as_mut().unwrap().sender_guid = Some("group title".into()),
            |m| {
                m.conversation.as_mut().unwrap().sender_guid =
                    Some(format!("iMessage;+;{GROUP_ID}"))
            },
            |m| m.sender = Some("mailto:stranger@example.com".into()),
            |m| m.sender = Some("tel:remote@example.com".into()),
            |m| m.received_on_handle = Some("mailto:other-account@example.com".into()),
            |m| m.received_on_handle = None,
            |m| m.verification_failed = true,
            |m| {
                if let Message::Message(normal) = &mut m.message {
                    normal.voice = true;
                }
            },
            |m| {
                if let Message::Message(normal) = &mut m.message {
                    normal.reply_guid = Some("reply".into());
                }
            },
            |m| {
                if let Message::Message(normal) = &mut m.message {
                    normal.subject = Some("subject".into());
                }
            },
        ] {
            let mut altered = wire.clone();
            mutate(&mut altered);
            assert!(ReceivedArchiveSource::capture(&altered, &handles).is_err());
        }
        let mut alternate_spelling = wire.clone();
        alternate_spelling
            .conversation
            .as_mut()
            .unwrap()
            .sender_guid = Some(GROUP_ID.to_uppercase());
        let upper = ReceivedArchiveSource::capture(&alternate_spelling, &handles).unwrap();
        assert_eq!(upper.group_id(), Some(GROUP_ID.to_uppercase().as_str()));
        assert_ne!(
            upper.source_sha256().unwrap(),
            ReceivedArchiveSource::capture(&wire, &handles)
                .unwrap()
                .source_sha256()
                .unwrap()
        );
    }

    #[test]
    fn group_source_versions_and_direct_group_relabeling_are_not_interchangeable() {
        let (wire, handles) = group_fixture(false);
        let group = ReceivedArchiveSource::capture(&wire, &handles).unwrap();
        let bytes = group.encode().unwrap();
        // Keep Source field order, rather than failing on Value map ordering
        // before reaching the intended version/shape validation.
        for mutate in [
            (|v: &mut Source| v.version = 1) as fn(&mut Source),
            |v| v.version = 3,
            |v| v.group_id = None,
            |v| v.peer = "remote@example.com".into(),
            |v| v.group_id = Some("77777777-8888-4999-aaaa-cccccccccccc".into()),
        ] {
            let mut altered: Source = serde_json::from_slice(&bytes).unwrap();
            mutate(&mut altered);
            assert!(ReceivedArchiveSource::decode(&serde_json::to_vec(&altered).unwrap()).is_err());
        }
        let mut extra_field: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        extra_field["unexpected"] = serde_json::json!(true);
        assert!(ReceivedArchiveSource::decode(&serde_json::to_vec(&extra_field).unwrap()).is_err());
        let (wire, handles) = fixture(false, "direct");
        let direct = ReceivedArchiveSource::capture(&wire, &handles)
            .unwrap()
            .encode()
            .unwrap();
        let mut altered: Source = serde_json::from_slice(&direct).unwrap();
        altered.version = 2;
        assert!(ReceivedArchiveSource::decode(&serde_json::to_vec(&altered).unwrap()).is_err());
        altered.group_id = Some(GROUP_ID.into());
        assert!(ReceivedArchiveSource::decode(&serde_json::to_vec(&altered).unwrap()).is_err());
    }

    #[test]
    fn sorting_and_unused_account_aliases_do_not_change_the_source() {
        let (mut message, mut handles) = fixture(false, "text");
        let source = ReceivedArchiveSource::capture(&message, &handles)
            .unwrap()
            .encode()
            .unwrap();
        message
            .conversation
            .as_mut()
            .unwrap()
            .participants
            .reverse();
        handles.push("tel:+15550000009".into());
        message.target = None;
        message.send_delivered = false;
        assert_eq!(
            ReceivedArchiveSource::capture(&message, &handles)
                .unwrap()
                .encode()
                .unwrap(),
            source
        );
    }

    #[test]
    fn malformed_or_wrong_lane_receives_never_become_sources() {
        let (baseline, handles) = fixture(false, "text");
        for mutate in [
            (|m: &mut MessageInst| m.received_on_handle = None) as fn(&mut MessageInst),
            |m| m.received_on_handle = Some("mailto:someone-else@example.com".into()),
            |m| m.sender = Some("mailto:someone-else@example.com".into()),
            |m| m.verification_failed = true,
            |m| m.target = Some(vec![MessageTarget::Uuid("outbound".into())]),
            |m| m.sent_timestamp = 0,
            |m| m.conversation = None,
            |m| {
                m.conversation
                    .as_mut()
                    .unwrap()
                    .participants
                    .push("mailto:third@example.com".into())
            },
            |m| m.message = Message::Delivered,
            |m| {
                if let Message::Message(n) = &mut m.message {
                    n.voice = true;
                }
            },
            |m| {
                if let Message::Message(n) = &mut m.message {
                    n.reply_guid = Some("reply".into());
                }
            },
            |m| {
                if let Message::Message(n) = &mut m.message {
                    n.parts.0[0].idx = Some(1);
                }
            },
        ] {
            let mut message = baseline.clone();
            mutate(&mut message);
            assert!(ReceivedArchiveSource::capture(&message, &handles).is_err());
        }
        let (message, _) = fixture(false, "\u{feff}\u{85} \n");
        assert!(ReceivedArchiveSource::capture(&message, &handles).is_err());
        let (message, _) = fixture(false, &"x".repeat(MAX_TEXT_BYTES + 1));
        assert!(matches!(
            ReceivedArchiveSource::capture(&message, &handles),
            Err(Failure::OversizedMessage)
        ));
    }

    #[test]
    fn noncanonical_unknown_or_tampered_source_is_not_adopted() {
        let (message, handles) = fixture(false, "text");
        let bytes = ReceivedArchiveSource::capture(&message, &handles)
            .unwrap()
            .encode()
            .unwrap();
        let mut padded = bytes.clone();
        padded.push(b' ');
        assert!(ReceivedArchiveSource::decode(&padded).is_err());
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["peer"] = serde_json::json!("wrong@example.com");
        assert!(ReceivedArchiveSource::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["unexpected"] = serde_json::json!(true);
        assert!(ReceivedArchiveSource::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        assert!(ReceivedArchiveSource::decode(&vec![b'x'; MAX_BYTES + 1]).is_err());
    }
}
