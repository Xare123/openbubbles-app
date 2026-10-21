//! Immutable live received edit/unsend source, never an outgoing send receipt.
//! Content remains native and must be encrypted before crossing the bridge.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use crate::cloud_sync_received_source::{hex_digest, ReceivedArchiveOrigin};
use rustpush::{
    ConversationData, EditMessage, IndexedMessagePart, Message, MessageInst, MessagePart,
    MessageParts, MessageTarget, TextFlags, TextFormat, UnsendMessage,
};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const DOMAIN: &str = "cloud-sync-ids-received-mutation-source";
const MAX_BYTES: usize = 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_LABEL_BYTES: usize = 4096;

// No Debug implementations: these structures contain private message data.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Source {
    domain: String,
    version: u32,
    guid: String,
    target_guid: String,
    target_part: u64,
    sender: String,
    received_on_handle: String,
    sent_timestamp: u64,
    origin: ReceivedArchiveOrigin,
    participants: Vec<String>,
    self_handles: Vec<String>,
    conversation_name: Option<String>,
    sender_guid: Option<String>,
    after_guid: Option<String>,
    change: Change,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", deny_unknown_fields)]
enum Change {
    Edit { parts: Vec<TextPart> },
    Unsend,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct TextPart {
    text: String,
    index: Option<u64>,
    bold: bool,
    italic: bool,
    underline: bool,
    strikethrough: bool,
}

pub(crate) struct ReceivedMutationSource(Source);

impl ReceivedMutationSource {
    /// Shape and observed receive binding only. Retention grants no update,
    /// parent selection, message-author proof, or permission to send via IDS.
    pub(crate) fn capture(
        message: &MessageInst,
        local_handles: &[String],
    ) -> Result<Self, Failure> {
        let event_id = uuid(&message.id)?;
        if message.verification_failed {
            return Err(Failure::UnsupportedMessage);
        }
        validate_handles(local_handles, false)?;
        let sender = message.sender.as_deref().ok_or(Failure::MalformedMessage)?;
        let recipient = message
            .received_on_handle
            .as_deref()
            .ok_or(Failure::BindingMismatch)?;
        handle(sender)?;
        handle(recipient)?;
        if !local_handles.iter().any(|value| value == recipient) {
            return Err(Failure::BindingMismatch);
        }
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
        if message.sent_timestamp == 0 || message.sent_timestamp > i64::MAX as u64 {
            return Err(Failure::MalformedMessage);
        }
        let (target_guid, target_part, change) = match &message.message {
            Message::Unsend(value) => (&value.tuuid, value.edit_part, Change::Unsend),
            Message::Edit(value) => {
                if value.new_parts.0.is_empty() || value.new_parts.0.len() > 128 {
                    return Err(Failure::MalformedMessage);
                }
                let mut size = 0usize;
                let mut parts = Vec::with_capacity(value.new_parts.0.len());
                for indexed in &value.new_parts.0 {
                    if indexed.ext.is_some()
                        || indexed.idx.is_some_and(|index| index > i64::MAX as usize)
                    {
                        return Err(Failure::UnsupportedMessage);
                    }
                    let MessagePart::Text(text, TextFormat::Flags(flags)) = &indexed.part else {
                        return Err(Failure::UnsupportedMessage);
                    };
                    size = size
                        .checked_add(text.len())
                        .ok_or(Failure::OversizedMessage)?;
                    if size > MAX_TEXT_BYTES {
                        return Err(Failure::OversizedMessage);
                    }
                    parts.push(TextPart {
                        text: text.clone(),
                        index: indexed.idx.map(|index| index as u64),
                        bold: flags.bold,
                        italic: flags.italic,
                        underline: flags.underline,
                        strikethrough: flags.strikethrough,
                    });
                }
                (&value.tuuid, value.edit_part, Change::Edit { parts })
            }
            _ => return Err(Failure::UnsupportedMessage),
        };
        if uuid(target_guid)? == event_id || target_part > i64::MAX as u64 {
            return Err(Failure::BindingMismatch);
        }
        let conversation = message
            .conversation
            .as_ref()
            .ok_or(Failure::MalformedMessage)?;
        validate_handles(&conversation.participants, true)?;
        for value in [
            &conversation.cv_name,
            &conversation.sender_guid,
            &conversation.after_guid,
        ] {
            if let Some(value) = value {
                label(value)?;
            }
        }
        let origin = if local_handles.iter().any(|value| value == sender) {
            ReceivedArchiveOrigin::Mirrored
        } else {
            ReceivedArchiveOrigin::Incoming
        };
        let external = conversation
            .participants
            .iter()
            .filter(|value| !local_handles.contains(value))
            .map(String::as_str)
            .collect::<HashSet<_>>();
        if external.is_empty() {
            return Err(Failure::UnsupportedMessage);
        }
        if origin == ReceivedArchiveOrigin::Incoming
            && (!conversation
                .participants
                .iter()
                .any(|value| value == sender)
                || !external.contains(sender))
        {
            return Err(Failure::BindingMismatch);
        }
        if external.len() > 1 {
            uuid(
                conversation
                    .sender_guid
                    .as_deref()
                    .ok_or(Failure::BindingMismatch)?,
            )?;
        }
        let mut participants = conversation.participants.clone();
        participants.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
        let mut self_handles = local_handles
            .iter()
            .filter(|value| {
                value.as_str() == recipient
                    || value.as_str() == sender
                    || conversation.participants.contains(value)
            })
            .cloned()
            .collect::<Vec<_>>();
        self_handles.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
        self_handles.dedup();
        let source = Self(Source {
            domain: DOMAIN.into(),
            version: 1,
            guid: message.id.clone(),
            target_guid: target_guid.clone(),
            target_part,
            sender: sender.into(),
            received_on_handle: recipient.into(),
            sent_timestamp: message.sent_timestamp,
            origin,
            participants,
            self_handles,
            conversation_name: conversation.cv_name.clone(),
            sender_guid: conversation.sender_guid.clone(),
            after_guid: conversation.after_guid.clone(),
            change,
        });
        source.encode()?;
        Ok(source)
    }

    pub(crate) fn encode(&self) -> Result<Vec<u8>, Failure> {
        let bytes = serde_json::to_vec(&self.0).map_err(|_| Failure::MalformedMessage)?;
        if bytes.is_empty() || bytes.len() > MAX_BYTES {
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
        if source.domain != DOMAIN || source.version != 1 {
            return Err(Failure::UnsupportedMessage);
        }
        let opened = Self(source);
        let canonical = Self::capture(&opened.message()?, &opened.0.self_handles)?;
        if canonical.0 != opened.0 || canonical.encode()? != bytes {
            return Err(Failure::BindingMismatch);
        }
        Ok(canonical)
    }

    /// Received provenance stays present. Feeding this to the outgoing source
    /// encoder is rejected; this private value is for the conditional composer.
    pub(crate) fn message(&self) -> Result<MessageInst, Failure> {
        let s = &self.0;
        let message = match &s.change {
            Change::Unsend => Message::Unsend(UnsendMessage {
                tuuid: s.target_guid.clone(),
                edit_part: s.target_part,
            }),
            Change::Edit { parts } => Message::Edit(EditMessage {
                tuuid: s.target_guid.clone(),
                edit_part: s.target_part,
                new_parts: MessageParts(
                    parts
                        .iter()
                        .map(|part| {
                            Ok(IndexedMessagePart {
                                part: MessagePart::Text(
                                    part.text.clone(),
                                    TextFormat::Flags(TextFlags {
                                        bold: part.bold,
                                        italic: part.italic,
                                        underline: part.underline,
                                        strikethrough: part.strikethrough,
                                    }),
                                ),
                                idx: part
                                    .index
                                    .map(usize::try_from)
                                    .transpose()
                                    .map_err(|_| Failure::MalformedMessage)?,
                                ext: None,
                            })
                        })
                        .collect::<Result<Vec<_>, Failure>>()?,
                ),
            }),
        };
        Ok(MessageInst {
            id: s.guid.clone(),
            sender: Some(s.sender.clone()),
            conversation: Some(ConversationData {
                participants: s.participants.clone(),
                cv_name: s.conversation_name.clone(),
                sender_guid: s.sender_guid.clone(),
                after_guid: s.after_guid.clone(),
            }),
            message,
            sent_timestamp: s.sent_timestamp,
            send_delivered: false,
            target: None,
            verification_failed: false,
            certified_context: None,
            received_on_handle: Some(s.received_on_handle.clone()),
        })
    }

    pub(crate) fn guid(&self) -> &str {
        &self.0.guid
    }
    pub(crate) fn target_guid(&self) -> &str {
        &self.0.target_guid
    }
    pub(crate) fn target_part(&self) -> u64 {
        self.0.target_part
    }
    pub(crate) fn sender(&self) -> &str {
        &self.0.sender
    }
    pub(crate) fn recipient(&self) -> &str {
        &self.0.received_on_handle
    }
    pub(crate) fn self_handles(&self) -> &[String] {
        &self.0.self_handles
    }
    pub(crate) fn participants(&self) -> &[String] {
        &self.0.participants
    }
    pub(crate) fn sender_guid(&self) -> Option<&str> {
        self.0.sender_guid.as_deref()
    }
    pub(crate) fn origin(&self) -> ReceivedArchiveOrigin {
        self.0.origin
    }
    pub(crate) fn sent_timestamp(&self) -> u64 {
        self.0.sent_timestamp
    }
    pub(crate) fn kind(&self) -> &'static str {
        match &self.0.change {
            Change::Edit { .. } => "edit",
            Change::Unsend => "unsend",
        }
    }
    pub(crate) fn guid_hash(&self) -> Result<String, Failure> {
        digest(&serde_json::json!([
            "cloud-sync-received-mutation-guid-v1",
            self.0.guid
        ]))
    }
    pub(crate) fn target_guid_hash(&self) -> Result<String, Failure> {
        digest(&serde_json::json!([
            "cloud-sync-received-archive-guid-v1",
            self.0.target_guid
        ]))
    }
    pub(crate) fn source_sha256(&self) -> Result<String, Failure> {
        let s = &self.0;
        let parts = match &s.change {
            Change::Unsend => serde_json::Value::Null,
            Change::Edit { parts } => serde_json::json!(parts
                .iter()
                .map(|p| serde_json::json!([
                    p.text,
                    p.index,
                    p.bold,
                    p.italic,
                    p.underline,
                    p.strikethrough,
                ]))
                .collect::<Vec<_>>()),
        };
        digest(&serde_json::json!([
            "cloud-sync-received-mutation-source-v1",
            s.guid,
            s.target_guid,
            s.target_part,
            s.sender,
            s.received_on_handle,
            s.sent_timestamp,
            match s.origin {
                ReceivedArchiveOrigin::Incoming => "incoming",
                ReceivedArchiveOrigin::Mirrored => "mirrored",
            },
            s.participants,
            s.conversation_name,
            s.sender_guid,
            s.after_guid,
            self.kind(),
            parts,
            s.self_handles
        ]))
    }
}

fn uuid(value: &str) -> Result<uuid::Uuid, Failure> {
    if value.len() != 36
        || !value.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
    {
        return Err(Failure::MalformedMessage);
    }
    let parsed = uuid::Uuid::parse_str(value).map_err(|_| Failure::MalformedMessage)?;
    if parsed.is_nil() {
        return Err(Failure::MalformedMessage);
    }
    Ok(parsed)
}
fn bare(value: &str) -> &str {
    value
        .strip_prefix("mailto:")
        .or_else(|| value.strip_prefix("tel:"))
        .unwrap_or(value)
}
fn label(value: &str) -> Result<(), Failure> {
    if value.len() > MAX_LABEL_BYTES {
        return Err(Failure::OversizedMessage);
    }
    if value.chars().any(char::is_control) {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn handle(value: &str) -> Result<(), Failure> {
    label(value)?;
    if bare(value) == value || bare(value).is_empty() || value.chars().any(char::is_whitespace) {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn validate_handles(values: &[String], unique: bool) -> Result<(), Failure> {
    if values.is_empty() || values.len() > 64 {
        return Err(Failure::OversizedMessage);
    }
    for value in values {
        handle(value)?;
    }
    if unique && values.iter().collect::<HashSet<_>>().len() != values.len() {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
fn digest(value: &serde_json::Value) -> Result<String, Failure> {
    Ok(hex_digest(
        &serde_json::to_vec(value).map_err(|_| Failure::MalformedMessage)?,
    ))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn fixture(mirrored: bool, unsend: bool) -> (MessageInst, Vec<String>) {
        let (mut message, handles) =
            crate::cloud_sync_received_source::tests::fixture(mirrored, "unused");
        message.message = if unsend {
            Message::Unsend(UnsendMessage {
                tuuid: "99999999-8888-4777-8666-555555555555".into(),
                edit_part: 0,
            })
        } else {
            Message::Edit(EditMessage {
                tuuid: "99999999-8888-4777-8666-555555555555".into(),
                edit_part: 0,
                new_parts: MessageParts(vec![IndexedMessagePart {
                    part: MessagePart::Text(
                        "Edited 😀".into(),
                        TextFormat::Flags(TextFlags {
                            bold: true,
                            italic: false,
                            underline: false,
                            strikethrough: false,
                        }),
                    ),
                    idx: Some(0),
                    ext: None,
                }]),
            })
        };
        (message, handles)
    }

    #[test]
    fn received_events_round_trip_without_becoming_local_sends_or_original_creates() {
        for mirrored in [false, true] {
            for unsend in [false, true] {
                let (wire, handles) = fixture(mirrored, unsend);
                let source = ReceivedMutationSource::capture(&wire, &handles).unwrap();
                let bytes = source.encode().unwrap();
                let decoded = ReceivedMutationSource::decode(&bytes).unwrap();
                assert_eq!(decoded.encode().unwrap(), bytes);
                assert_eq!(decoded.guid(), wire.id);
                assert_eq!(
                    decoded.target_guid(),
                    "99999999-8888-4777-8666-555555555555"
                );
                assert!(
                    crate::cloud_sync_ids_mutation_source::encode_mutation_source(
                        &decoded.message().unwrap()
                    )
                    .is_err()
                );
                assert!(
                    crate::cloud_sync_received_source::ReceivedArchiveSource::decode(&bytes)
                        .is_err()
                );
                let mut metadata_only_change = wire.clone();
                metadata_only_change.target = None;
                metadata_only_change.send_delivered = !wire.send_delivered;
                let equivalent =
                    ReceivedMutationSource::capture(&metadata_only_change, &handles).unwrap();
                assert_eq!(
                    equivalent.source_sha256().unwrap(),
                    source.source_sha256().unwrap()
                );
            }
        }
    }

    #[test]
    fn received_mutation_digests_match_literal_dart_vectors() {
        let (mut wire, _) = fixture(false, false);
        let handles = vec!["mailto:owner@example.test".to_string()];
        wire.id = "2C174D2E-BAA7-4435-A8D5-88BF2C969A44".into();
        wire.sender = Some("mailto:sender@example.test".into());
        wire.received_on_handle = Some(handles[0].clone());
        wire.sent_timestamp = 1_700_000_000_000;
        wire.conversation = Some(ConversationData {
            participants: vec![handles[0].clone(), "mailto:sender@example.test".into()],
            cv_name: None,
            sender_guid: Some("direct-route".into()),
            after_guid: Some("".into()),
        });
        let target = "5BC3779B-7898-4A15-A768-2EA04D3ABAA0";
        wire.message = Message::Edit(EditMessage {
            tuuid: target.into(),
            edit_part: 2,
            new_parts: MessageParts(vec![
                IndexedMessagePart {
                    part: MessagePart::Text(
                        "Edited message".into(),
                        TextFormat::Flags(TextFlags {
                            bold: true,
                            italic: false,
                            underline: true,
                            strikethrough: false,
                        }),
                    ),
                    idx: Some(2),
                    ext: None,
                },
                IndexedMessagePart {
                    part: MessagePart::Text(
                        "".into(),
                        TextFormat::Flags(TextFlags {
                            bold: false,
                            italic: true,
                            underline: false,
                            strikethrough: true,
                        }),
                    ),
                    idx: None,
                    ext: None,
                },
            ]),
        });
        let edit = ReceivedMutationSource::capture(&wire, &handles).unwrap();
        assert_eq!(
            edit.guid_hash().unwrap(),
            "e68c641bfd4822dd10a95017fdc5b4a7f13e2e991ddd57050a24776ec53d25da"
        );
        assert_eq!(
            edit.target_guid_hash().unwrap(),
            "48e756afd7472c07393dfd698d00dd9395797eda745478908538fcf95d4a2432"
        );
        assert_eq!(
            edit.source_sha256().unwrap(),
            "cc2c80f32a45c86c0146e00653996b2e35df9e12171e61c86ea81f5b50eaa96f"
        );
        wire.message = Message::Unsend(UnsendMessage {
            tuuid: target.into(),
            edit_part: 2,
        });
        assert_eq!(
            ReceivedMutationSource::capture(&wire, &handles)
                .unwrap()
                .source_sha256()
                .unwrap(),
            "c9fa3e68d92535c0eb4c176e08e2ad7c8d01dca7c43fca171abf26b88de74aa4"
        );
        // Two exact external endpoints cannot bypass group routing by sharing
        // the same bare suffix under distinct address schemes.
        let conversation = wire.conversation.as_mut().unwrap();
        conversation.participants = vec![
            handles[0].clone(),
            "mailto:sender@example.test".into(),
            "tel:sender@example.test".into(),
        ];
        conversation.sender_guid = Some("direct-route".into());
        assert!(ReceivedMutationSource::capture(&wire, &handles).is_err());
        wire.conversation.as_mut().unwrap().sender_guid =
            Some("77777777-8888-4999-aaaa-bbbbbbbbbbbb".into());
        assert!(ReceivedMutationSource::capture(&wire, &handles).is_ok());
    }

    #[test]
    fn captured_event_identity_rejects_foreign_endpoint_bad_sender_and_noncanonical_bytes() {
        let (wire, handles) = fixture(false, false);
        let source = ReceivedMutationSource::capture(&wire, &handles).unwrap();
        let mut changed = wire.clone();
        changed.received_on_handle = Some("mailto:other@example.com".into());
        assert!(ReceivedMutationSource::capture(&changed, &handles).is_err());
        let mut changed = wire.clone();
        changed.verification_failed = true;
        assert!(ReceivedMutationSource::capture(&changed, &handles).is_err());
        let mut changed = wire.clone();
        changed.sender = Some("mailto:other@example.com".into());
        assert!(ReceivedMutationSource::capture(&changed, &handles).is_err());
        let bytes = source.encode().unwrap();
        let mut trailing = bytes.clone();
        trailing.push(b' ');
        assert!(ReceivedMutationSource::decode(&trailing).is_err());
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["unknown"] = serde_json::json!(true);
        assert!(ReceivedMutationSource::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}
