//! Exact pre-send intent for an edit or unsend, separate from initial creates.
//! This codec is native-only. Its output contains message content and must be
//! protected before persistence. It neither stages data nor grants permission
//! to send/save. The durable journal and positive IDS receipt remain required.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use rustpush::{
    ConversationData, EditMessage, IndexedMessagePart, Message, MessageInst, MessagePart,
    MessageParts, TextFlags, TextFormat, UnsendMessage,
};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const DOMAIN: &str = "cloud-sync-ids-mutation-source";
const VERSION: u32 = 1;
const MAX_BYTES: usize = 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_PARTS: usize = 128;
const MAX_PARTICIPANTS: usize = 64;

// Deliberately no Debug: these values include private handles and message text.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Intent {
    domain: String,
    version: u32,
    mutation_guid: String,
    target_guid: String,
    target_part: u64,
    sender: String,
    participants: Vec<String>,
    conversation_name: Option<String>,
    sender_guid: Option<String>,
    after_guid: Option<String>,
    sent_timestamp: u64,
    send_delivered: bool,
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

pub(crate) struct OpenedMutationSource(Intent);

impl OpenedMutationSource {
    pub(crate) fn mutation_guid(&self) -> &str {
        &self.0.mutation_guid
    }
    pub(crate) fn target_guid(&self) -> &str {
        &self.0.target_guid
    }
    pub(crate) fn target_part(&self) -> u64 {
        self.0.target_part
    }

    /// Reconstruct the original request, not a request from the current chat.
    /// This is also not authorization to repeat an unknown-outcome IDS send.
    pub(crate) fn message(&self) -> Result<MessageInst, Failure> {
        let intent = &self.0;
        let message = match &intent.change {
            Change::Unsend => Message::Unsend(UnsendMessage {
                tuuid: intent.target_guid.clone(),
                edit_part: intent.target_part,
            }),
            Change::Edit { parts } => {
                let parts = parts
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
                    .collect::<Result<Vec<_>, Failure>>()?;
                Message::Edit(EditMessage {
                    tuuid: intent.target_guid.clone(),
                    edit_part: intent.target_part,
                    new_parts: MessageParts(parts),
                })
            }
        };
        Ok(MessageInst {
            id: intent.mutation_guid.clone(),
            sender: Some(intent.sender.clone()),
            conversation: Some(ConversationData {
                participants: intent.participants.clone(),
                cv_name: intent.conversation_name.clone(),
                sender_guid: intent.sender_guid.clone(),
                after_guid: intent.after_guid.clone(),
            }),
            message,
            sent_timestamp: intent.sent_timestamp,
            send_delivered: intent.send_delivered,
            target: None,
            verification_failed: false,
            certified_context: None,
        })
    }
}

pub(crate) fn encode_mutation_source(message: &MessageInst) -> Result<Vec<u8>, Failure> {
    let intent = intent_from_message(message)?;
    let bytes = serde_json::to_vec(&intent).map_err(|_| Failure::MalformedMessage)?;
    if bytes.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(bytes)
}

pub(crate) fn open_mutation_source(bytes: &[u8]) -> Result<OpenedMutationSource, Failure> {
    if bytes.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    if bytes.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let intent: Intent = serde_json::from_slice(bytes).map_err(|_| Failure::MalformedMessage)?;
    if intent.domain != DOMAIN || intent.version != VERSION {
        return Err(Failure::UnsupportedMessage);
    }
    let opened = OpenedMutationSource(intent);
    // Reapply all source bounds after deserialization and require one stable
    // representation. Duplicate/unknown fields and alternate JSON cannot be
    // adopted as a different source with the same decoded body.
    if encode_mutation_source(&opened.message()?)? != bytes {
        return Err(Failure::BindingMismatch);
    }
    Ok(opened)
}

pub(crate) fn validate_mutation_source(bytes: &[u8], message: &MessageInst) -> Result<(), Failure> {
    let original = open_mutation_source(bytes)?;
    if original.0 != intent_from_message(message)? {
        return Err(Failure::BindingMismatch);
    }
    Ok(())
}

/// Mirror only MessageInst::prepare_send's three documented mutations. Body,
/// target GUID, target part, operation UUID, sender and route remain exact.
/// A match is NOT positive IDS confirmation or proof of a CloudKit update.
pub(crate) fn validate_prepared_mutation_source(
    bytes: &[u8],
    message: &MessageInst,
    send_started_ms: u64,
    send_finished_ms: u64,
) -> Result<(), Failure> {
    let mut expected = open_mutation_source(bytes)?.0;
    let actual = intent_from_message(message)?;
    if send_started_ms > send_finished_ms
        || !(send_started_ms..=send_finished_ms).contains(&actual.sent_timestamp)
    {
        return Err(Failure::BindingMismatch);
    }
    expected.sent_timestamp = actual.sent_timestamp;
    if expected.sender_guid.is_none() {
        let generated = actual
            .sender_guid
            .as_ref()
            .ok_or(Failure::BindingMismatch)?;
        let uuid = uuid::Uuid::parse_str(generated).map_err(|_| Failure::BindingMismatch)?;
        if uuid.get_version_num() != 4 || uuid.to_string() != *generated {
            return Err(Failure::BindingMismatch);
        }
        expected.sender_guid = Some(generated.clone());
    }
    if !expected.participants.contains(&expected.sender) {
        expected.participants.push(expected.sender.clone());
    }
    if expected != actual {
        return Err(Failure::BindingMismatch);
    }
    Ok(())
}

fn intent_from_message(message: &MessageInst) -> Result<Intent, Failure> {
    if message.target.is_some()
        || message.certified_context.is_some()
        || message.verification_failed
    {
        return Err(Failure::UnsupportedMessage);
    }
    let (target, part, change) = match &message.message {
        Message::Unsend(change) => (&change.tuuid, change.edit_part, Change::Unsend),
        Message::Edit(change) => {
            if change.new_parts.0.is_empty() || change.new_parts.0.len() > MAX_PARTS {
                return Err(Failure::MalformedMessage);
            }
            let mut total_text = 0usize;
            let mut parts = Vec::with_capacity(change.new_parts.0.len());
            for indexed in &change.new_parts.0 {
                if indexed.ext.is_some() {
                    return Err(Failure::UnsupportedMessage);
                }
                let MessagePart::Text(text, TextFormat::Flags(flags)) = &indexed.part else {
                    // Preserve unsupported edits as pending work in the caller;
                    // never flatten mentions, effects or attachment replacements.
                    return Err(Failure::UnsupportedMessage);
                };
                total_text = total_text
                    .checked_add(text.len())
                    .ok_or(Failure::OversizedMessage)?;
                if total_text > MAX_TEXT_BYTES {
                    return Err(Failure::OversizedMessage);
                }
                parts.push(TextPart {
                    text: text.clone(),
                    index: indexed.idx.map(|i| i as u64),
                    bold: flags.bold,
                    italic: flags.italic,
                    underline: flags.underline,
                    strikethrough: flags.strikethrough,
                });
            }
            (&change.tuuid, change.edit_part, Change::Edit { parts })
        }
        _ => return Err(Failure::UnsupportedMessage),
    };
    let mutation_id = uuid::Uuid::parse_str(&message.id).map_err(|_| Failure::MalformedMessage)?;
    let target_id = uuid::Uuid::parse_str(target).map_err(|_| Failure::MalformedMessage)?;
    if mutation_id.is_nil() || target_id.is_nil() || mutation_id == target_id {
        return Err(Failure::BindingMismatch);
    }
    let sender = message.sender.as_ref().ok_or(Failure::MalformedMessage)?;
    validate_handle(sender)?;
    let conversation = message
        .conversation
        .as_ref()
        .ok_or(Failure::MalformedMessage)?;
    if conversation.participants.is_empty()
        || conversation.participants.len() > MAX_PARTICIPANTS
        || conversation
            .participants
            .iter()
            .collect::<HashSet<_>>()
            .len()
            != conversation.participants.len()
    {
        return Err(Failure::MalformedMessage);
    }
    for handle in &conversation.participants {
        validate_handle(handle)?;
    }
    for value in [
        &conversation.cv_name,
        &conversation.sender_guid,
        &conversation.after_guid,
    ]
    .into_iter()
    .flatten()
    {
        if value.len() > 4096 || value.chars().any(char::is_control) {
            return Err(Failure::MalformedMessage);
        }
    }
    Ok(Intent {
        domain: DOMAIN.to_owned(),
        version: VERSION,
        mutation_guid: message.id.clone(),
        target_guid: target.clone(),
        target_part: part,
        sender: sender.clone(),
        participants: conversation.participants.clone(),
        conversation_name: conversation.cv_name.clone(),
        sender_guid: conversation.sender_guid.clone(),
        after_guid: conversation.after_guid.clone(),
        sent_timestamp: message.sent_timestamp,
        send_delivered: message.send_delivered,
        change,
    })
}

fn validate_handle(value: &str) -> Result<(), Failure> {
    let suffix = value
        .strip_prefix("mailto:")
        .or_else(|| value.strip_prefix("tel:"))
        .ok_or(Failure::MalformedMessage)?;
    if suffix.is_empty()
        || value.len() > 4096
        || value.chars().any(char::is_whitespace)
        || value.chars().any(char::is_control)
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn original(unsend: bool) -> MessageInst {
        let target = "5BC3779B-7898-4A15-A768-2EA04D3ABAA0".to_owned();
        MessageInst {
            id: "2C174D2E-BAA7-4435-A8D5-88BF2C969A44".to_owned(),
            sender: Some("mailto:sender@example.test".to_owned()),
            conversation: Some(ConversationData {
                participants: vec!["mailto:peer@example.test".to_owned()],
                cv_name: None,
                sender_guid: None,
                after_guid: None,
            }),
            message: if unsend {
                Message::Unsend(UnsendMessage {
                    tuuid: target,
                    edit_part: 2,
                })
            } else {
                Message::Edit(EditMessage {
                    tuuid: target,
                    edit_part: 2,
                    new_parts: MessageParts(vec![IndexedMessagePart {
                        part: MessagePart::Text(
                            "Edited 😀\nmessage".to_owned(),
                            TextFormat::Flags(TextFlags {
                                bold: true,
                                italic: false,
                                underline: true,
                                strikethrough: false,
                            }),
                        ),
                        idx: Some(2),
                        ext: None,
                    }]),
                })
            },
            sent_timestamp: 0,
            send_delivered: false,
            target: None,
            verification_failed: false,
            certified_context: None,
        }
    }

    #[test]
    fn edit_and_unsend_roundtrip_keep_distinct_operation_and_target() {
        for unsend in [false, true] {
            let message = original(unsend);
            let encoded = encode_mutation_source(&message).unwrap();
            let opened = open_mutation_source(&encoded).unwrap();
            assert_eq!(opened.mutation_guid(), message.id);
            assert_ne!(opened.mutation_guid(), opened.target_guid());
            assert_eq!(opened.target_part(), 2);
            assert_eq!(
                encode_mutation_source(&opened.message().unwrap()).unwrap(),
                encoded
            );
            assert!(validate_mutation_source(&encoded, &message).is_ok());
        }
    }

    #[test]
    fn prepared_source_accepts_actual_prepare_send_for_direct_and_group() {
        for unsend in [false, true] {
            for group in [false, true] {
                let mut message = original(unsend);
                if group {
                    let conversation = message.conversation.as_mut().unwrap();
                    conversation
                        .participants
                        .push("tel:+15555550123".to_owned());
                    conversation
                        .participants
                        .push(message.sender.clone().unwrap());
                    conversation.sender_guid = Some("existing-exact-group".to_owned());
                }
                let bytes = encode_mutation_source(&message).unwrap();
                message.prepare_send(&[message.sender.clone().unwrap()]);
                let timestamp = message.sent_timestamp;
                assert!(
                    validate_prepared_mutation_source(&bytes, &message, timestamp, timestamp)
                        .is_ok()
                );
                assert!(validate_mutation_source(&bytes, &message).is_err());
                assert!(validate_prepared_mutation_source(
                    &bytes,
                    &message,
                    timestamp + 1,
                    timestamp
                )
                .is_err());
                assert!(
                    validate_prepared_mutation_source(&bytes, &message, 0, timestamp - 1).is_err()
                );
            }
        }
    }

    #[test]
    fn exact_source_rejects_changed_target_body_part_kind_uuid_and_route() {
        let message = original(false);
        let encoded = encode_mutation_source(&message).unwrap();
        for mutation in 0..10 {
            let mut changed = message.clone();
            match mutation {
                0 => changed.id = uuid::Uuid::new_v4().to_string(),
                1 => {
                    if let Message::Edit(edit) = &mut changed.message {
                        edit.tuuid = uuid::Uuid::new_v4().to_string();
                    }
                }
                2 => {
                    if let Message::Edit(edit) = &mut changed.message {
                        edit.edit_part += 1;
                    }
                }
                3 => {
                    if let Message::Edit(edit) = &mut changed.message {
                        edit.new_parts.0[0].part =
                            MessagePart::Text("other".to_owned(), Default::default());
                    }
                }
                4 => changed.message = original(true).message,
                5 => changed.sender = Some("mailto:other@example.test".to_owned()),
                6 => changed
                    .conversation
                    .as_mut()
                    .unwrap()
                    .participants
                    .push("mailto:other@example.test".to_owned()),
                7 => {
                    changed.conversation.as_mut().unwrap().sender_guid =
                        Some("different-group".to_owned())
                }
                8 => changed.send_delivered = true,
                9 => changed.conversation.as_mut().unwrap().after_guid = Some("changed".to_owned()),
                _ => unreachable!(),
            }
            assert!(
                validate_mutation_source(&encoded, &changed).is_err(),
                "mutation {mutation}"
            );
            changed.prepare_send(&[changed.sender.clone().unwrap()]);
            let time = changed.sent_timestamp;
            assert!(
                validate_prepared_mutation_source(&encoded, &changed, time, time).is_err(),
                "prepared {mutation}"
            );
        }
    }

    #[test]
    fn replay_cannot_be_confused_with_initial_send_or_same_guid_mutation() {
        let mut message = original(true);
        message.message = Message::Read;
        assert!(encode_mutation_source(&message).is_err());
        let mut message = original(true);
        if let Message::Unsend(change) = &mut message.message {
            change.tuuid = message.id.to_lowercase();
        }
        assert!(encode_mutation_source(&message).is_err());
        message.id = uuid::Uuid::nil().to_string();
        assert!(encode_mutation_source(&message).is_err());
    }

    #[test]
    fn malformed_noncanonical_and_unknown_source_data_are_rejected() {
        let bytes = encode_mutation_source(&original(false)).unwrap();
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        for field in ["version", "domain", "extra"] {
            let mut changed = value.clone();
            changed[field] = serde_json::json!(99);
            assert!(open_mutation_source(&serde_json::to_vec(&changed).unwrap()).is_err());
        }
        value["change"]["parts"][0]["extra"] = serde_json::json!(true);
        assert!(open_mutation_source(&serde_json::to_vec(&value).unwrap()).is_err());
        let mut padded = bytes.clone();
        padded.push(b' ');
        assert!(open_mutation_source(&padded).is_err());
        assert!(open_mutation_source(&bytes[..bytes.len() - 1]).is_err());
        assert!(open_mutation_source(&vec![b'x'; MAX_BYTES + 1]).is_err());
    }

    #[test]
    fn unsupported_or_oversized_edits_never_flatten_into_plaintext() {
        for bad in 0..5 {
            let mut message = original(false);
            match bad {
                0 => message.verification_failed = true,
                1 => message.target = Some(Vec::new()),
                2 => {
                    if let Message::Edit(edit) = &mut message.message {
                        edit.new_parts.0.clear();
                    }
                }
                3 => {
                    if let Message::Edit(edit) = &mut message.message {
                        edit.new_parts.0[0].part =
                            MessagePart::Mention("person".to_owned(), "id".to_owned());
                    }
                }
                4 => {
                    if let Message::Edit(edit) = &mut message.message {
                        edit.new_parts.0[0].part =
                            MessagePart::Text("a".repeat(MAX_TEXT_BYTES + 1), Default::default());
                    }
                }
                _ => unreachable!(),
            }
            assert!(encode_mutation_source(&message).is_err());
        }
    }
}
