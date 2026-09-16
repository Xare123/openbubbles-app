//! Immutable plain-text receive source. No network, persistence, IDS send or
//! CloudKit authority. Raw content stays native and must be protected by the
//! separate staging wrapper before retention. No Debug implementations.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
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
        let mut text = String::new();
        for indexed in &normal.parts.0 {
            if indexed.ext.is_some() || indexed.idx.is_some_and(|v| v != 0) {
                return Err(Failure::UnsupportedMessage);
            }
            let MessagePart::Text(value, TextFormat::Flags(flags)) = &indexed.part else {
                return Err(Failure::UnsupportedMessage);
            };
            if flags.bold || flags.italic || flags.underline || flags.strikethrough {
                return Err(Failure::UnsupportedMessage);
            }
            if text
                .len()
                .checked_add(value.len())
                .is_none_or(|n| n > MAX_TEXT_BYTES)
            {
                return Err(Failure::OversizedMessage);
            }
            text.push_str(value);
        }
        if text.trim_matches(dart_whitespace).is_empty() {
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
        if counterparts.len() != 1 {
            return Err(Failure::UnsupportedMessage);
        }
        let peer = *counterparts
            .iter()
            .next()
            .ok_or(Failure::MalformedMessage)?;
        if origin == ReceivedArchiveOrigin::Incoming && bare(sender) != peer {
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
            version: 1,
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
        if source.domain != DOMAIN || source.version != 1 {
            return Err(Failure::UnsupportedMessage);
        }
        // Reconstruct only privately to reapply bounds. No caller receives a
        // sendable MessageInst, a delivery receipt, or reply-device token.
        let wire = MessageInst {
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
    pub(crate) fn text(&self) -> &str {
        &self.0.text
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
    /// Exact v1 digest contract shared with CloudSyncReceivedArchiveIdentity.
    pub(crate) fn source_sha256(&self) -> Result<String, Failure> {
        let s = &self.0;
        digest(&serde_json::json!([
            "cloud-sync-received-archive-source-v1",
            s.guid,
            s.text,
            s.peer,
            s.sender,
            s.received_on_handle,
            s.sent_timestamp,
            s.origin.label(),
            s.sender_guid.as_deref().unwrap_or(""),
            s.participants,
            s.conversation_name.as_deref().unwrap_or(""),
            s.after_guid.as_deref().unwrap_or("")
        ]))
    }
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
