//! Closed native composer for the first safe MessageEncryptedV3 mutation slice.
//! Plaintext remains inside Rust. Unknown protobuf fields are retained by the
//! lossless patcher; unsupported body shapes fail closed instead of flattening.
#![cfg_attr(not(test), allow(dead_code))]

use crate::{
    cloud_sync_message_proto_patch::{patch_message_proto, ProtoPatchError},
    cloud_sync_message_summary_patch::{
        patch_message_summary, resolve_edit_basis, SummaryChange, SummaryPatchError, SummaryRange,
    },
};
use prost::Message as _;
use rustpush::{
    cloud_messages::{cloudmessagesp::MessageProto, CloudMessageUpdatePredecessorView},
    coder_encode_flattened, Message, MessageInst, MessagePart, NSNumber, NSString,
    StCollapsedValue, TextFormat,
};

const MAX_TEXT_BYTES: usize = 256 * 1024;
const APPLE_EPOCH_OFFSET_MILLIS: f64 = 978_307_200_000.0;
const MAX_APPLE_SECONDS: f64 = (253_402_300_799_999i64 - 978_307_200_000i64) as f64 / 1000.0;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MessageUpdateComposeError {
    UnsupportedMessage,
    MalformedMessage,
    OversizedMessage,
    SourceMismatch,
    TimestampConflict,
}

pub(crate) fn compose_message_update(
    predecessor: CloudMessageUpdatePredecessorView<'_>,
    mutation: &MessageInst,
    prepared_sent_timestamp_ms: u64,
) -> Result<Vec<u8>, MessageUpdateComposeError> {
    if !matches!(predecessor.outer_type, 0..=2) {
        return Err(MessageUpdateComposeError::UnsupportedMessage);
    }
    let target_part = match &mutation.message {
        Message::Edit(edit) => edit.edit_part,
        Message::Unsend(unsend) => unsend.edit_part,
        _ => return Err(MessageUpdateComposeError::UnsupportedMessage),
    };
    if target_part != 0 {
        return Err(MessageUpdateComposeError::UnsupportedMessage);
    }
    let part =
        u32::try_from(target_part).map_err(|_| MessageUpdateComposeError::UnsupportedMessage)?;
    let proto = MessageProto::decode(predecessor.msg_proto)
        .map_err(|_| MessageUpdateComposeError::MalformedMessage)?;
    if proto.balloon_bundle_id.is_some()
        || proto.payload_data.is_some()
        || proto.effect.is_some()
        || proto.associated_message_type.is_some()
        || proto.associated_message_guid.is_some()
        || proto.associated_message_range_location.is_some()
        || proto.associated_message_range_length.is_some()
    {
        return Err(MessageUpdateComposeError::UnsupportedMessage);
    }

    match &mutation.message {
        Message::Unsend(_) => {
            let summary = patch_message_summary(
                proto.message_summary_info.as_deref(),
                SummaryChange::Unsend { part },
            )
            .map_err(map_summary_error)?;
            patch_message_proto(predecessor.msg_proto, None, None, &summary)
                .map_err(map_proto_error)
        }
        Message::Edit(edit) => {
            let current_text = proto
                .text
                .as_deref()
                .filter(|text| !text.is_empty())
                .ok_or(MessageUpdateComposeError::UnsupportedMessage)?;
            let current_body = proto
                .attributed_body
                .as_deref()
                .filter(|body| !body.is_empty())
                .ok_or(MessageUpdateComposeError::UnsupportedMessage)?;
            crate::cloud_sync_canonical_converter::validate_single_text_attributed_body(
                current_body,
                current_text,
                part,
            )
            .map_err(|_| MessageUpdateComposeError::UnsupportedMessage)?;

            let (replacement_text, replacement_body) =
                encode_replacement_attributed_body(&edit.new_parts.0, part)?;
            let current_length = u32::try_from(current_text.encode_utf16().count())
                .map_err(|_| MessageUpdateComposeError::OversizedMessage)?;
            let original_timestamp = predecessor.message_time_apple_nanos as f64 / 1_000_000_000.0;
            if !valid_apple_seconds(original_timestamp) {
                return Err(MessageUpdateComposeError::MalformedMessage);
            }
            let replacement_timestamp =
                prepared_timestamp_apple_seconds(prepared_sent_timestamp_ms)?;
            let basis = resolve_edit_basis(
                proto.message_summary_info.as_deref(),
                part,
                current_body,
                original_timestamp,
                SummaryRange {
                    lo: 0,
                    le: current_length,
                },
            )
            .map_err(map_summary_error)?;
            if basis.body != current_body {
                return Err(MessageUpdateComposeError::SourceMismatch);
            }
            let summary = patch_message_summary(
                proto.message_summary_info.as_deref(),
                SummaryChange::Edit {
                    part,
                    original_body: &basis.body,
                    original_timestamp: basis.timestamp,
                    original_range: basis.range,
                    replacement_body: &replacement_body,
                    replacement_timestamp,
                },
            )
            .map_err(map_summary_error)?;
            patch_message_proto(
                predecessor.msg_proto,
                Some(&replacement_text),
                Some(&replacement_body),
                &summary,
            )
            .map_err(map_proto_error)
        }
        _ => Err(MessageUpdateComposeError::UnsupportedMessage),
    }
}

fn encode_replacement_attributed_body(
    parts: &[rustpush::IndexedMessagePart],
    expected_part: u32,
) -> Result<(String, Vec<u8>), MessageUpdateComposeError> {
    if parts.is_empty() {
        return Err(MessageUpdateComposeError::MalformedMessage);
    }
    let mut text = String::new();
    let mut ranges = Vec::with_capacity(parts.len());
    let mut total_bytes = 0usize;
    for indexed in parts {
        if indexed.ext.is_some()
            || indexed
                .idx
                .is_some_and(|index| index != expected_part as usize)
        {
            return Err(MessageUpdateComposeError::UnsupportedMessage);
        }
        let MessagePart::Text(value, TextFormat::Flags(flags)) = &indexed.part else {
            return Err(MessageUpdateComposeError::UnsupportedMessage);
        };
        if value.is_empty() {
            return Err(MessageUpdateComposeError::MalformedMessage);
        }
        total_bytes = total_bytes
            .checked_add(value.len())
            .ok_or(MessageUpdateComposeError::OversizedMessage)?;
        if total_bytes > MAX_TEXT_BYTES {
            return Err(MessageUpdateComposeError::OversizedMessage);
        }
        let length = u32::try_from(value.encode_utf16().count())
            .map_err(|_| MessageUpdateComposeError::OversizedMessage)?;
        if length == 0 {
            return Err(MessageUpdateComposeError::MalformedMessage);
        }
        text.push_str(value);
        ranges.push((length, *flags));
    }
    let body = attributed_body_value(&text, &ranges, expected_part)?;
    let encoded = coder_encode_flattened(&[body]);
    if encoded.is_empty() || encoded.len() > MAX_TEXT_BYTES * 4 {
        return Err(MessageUpdateComposeError::OversizedMessage);
    }
    Ok((text, encoded))
}

fn attributed_body_value(
    text: &str,
    ranges: &[(u32, rustpush::TextFlags)],
    part: u32,
) -> Result<StCollapsedValue, MessageUpdateComposeError> {
    let mut fields = vec![vec![NSString(text.to_owned()).encode()]];
    for (index, (length, flags)) in ranges.iter().enumerate() {
        let range_id =
            u32::try_from(index + 1).map_err(|_| MessageUpdateComposeError::OversizedMessage)?;
        fields.push(vec![
            StCollapsedValue::Int(range_id, true),
            StCollapsedValue::Int(*length, false),
        ]);
        let mut attributes = vec![("__kIMMessagePartAttributeName", part)];
        if flags.bold {
            attributes.push(("__kIMTextBoldAttributeName", 1));
        }
        if flags.italic {
            attributes.push(("__kIMTextItalicAttributeName", 1));
        }
        if flags.strikethrough {
            attributes.push(("__kIMTextStrikethroughAttributeName", 1));
        }
        if flags.underline {
            attributes.push(("__kIMTextUnderlineAttributeName", 1));
        }
        attributes.sort_unstable_by_key(|(key, _)| *key);
        let mut dictionary = vec![vec![StCollapsedValue::Int(
            u32::try_from(attributes.len())
                .map_err(|_| MessageUpdateComposeError::OversizedMessage)?,
            true,
        )]];
        for (key, value) in attributes {
            dictionary.push(vec![NSString(key.to_owned()).encode()]);
            dictionary.push(vec![NSNumber(value).encode()]);
        }
        fields.push(vec![StCollapsedValue::Object {
            class: "NSDictionary".to_owned(),
            fields: dictionary,
        }]);
    }
    Ok(StCollapsedValue::Object {
        class: "NSAttributedString".to_owned(),
        fields,
    })
}

fn prepared_timestamp_apple_seconds(
    prepared_sent_timestamp_ms: u64,
) -> Result<f64, MessageUpdateComposeError> {
    if prepared_sent_timestamp_ms == 0 || prepared_sent_timestamp_ms > i64::MAX as u64 {
        return Err(MessageUpdateComposeError::MalformedMessage);
    }
    let seconds = prepared_sent_timestamp_ms as f64 / 1000.0 - APPLE_EPOCH_OFFSET_MILLIS / 1000.0;
    if !valid_apple_seconds(seconds) {
        return Err(MessageUpdateComposeError::MalformedMessage);
    }
    Ok(seconds)
}

fn valid_apple_seconds(value: f64) -> bool {
    value.is_finite() && value > 0.0 && value <= MAX_APPLE_SECONDS
}

fn map_summary_error(error: SummaryPatchError) -> MessageUpdateComposeError {
    match error {
        SummaryPatchError::Oversized => MessageUpdateComposeError::OversizedMessage,
        SummaryPatchError::UnsupportedEncoding => MessageUpdateComposeError::UnsupportedMessage,
        SummaryPatchError::SourceMismatch => MessageUpdateComposeError::SourceMismatch,
        SummaryPatchError::TimestampConflict => MessageUpdateComposeError::TimestampConflict,
        SummaryPatchError::Malformed
        | SummaryPatchError::InvalidPatch
        | SummaryPatchError::InconsistentHistory
        | SummaryPatchError::RetractedPart => MessageUpdateComposeError::MalformedMessage,
    }
}

fn map_proto_error(error: ProtoPatchError) -> MessageUpdateComposeError {
    match error {
        ProtoPatchError::Oversized => MessageUpdateComposeError::OversizedMessage,
        ProtoPatchError::UnsupportedWireType => MessageUpdateComposeError::UnsupportedMessage,
        ProtoPatchError::InvalidPatch
        | ProtoPatchError::Malformed
        | ProtoPatchError::AmbiguousField => MessageUpdateComposeError::MalformedMessage,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use plist::Value;
    use rustpush::{
        ConversationData, EditMessage, IndexedMessagePart, MessageParts, TextFlags, UnsendMessage,
    };
    use std::io::Cursor;

    const ORIGINAL_APPLE_NANOS: i64 = 800_000_000_000_000_000;
    const PREPARED_UNIX_MILLIS: u64 = 1_800_000_000_000;

    fn encoded_body(text: &str) -> Vec<u8> {
        coder_encode_flattened(&[attributed_body_value(
            text,
            &[(text.encode_utf16().count() as u32, TextFlags::default())],
            0,
        )
        .unwrap()])
    }

    fn predecessor(text: &str, summary: Option<Vec<u8>>) -> Vec<u8> {
        MessageProto {
            unk1: 1,
            text: Some(text.to_owned()),
            attributed_body: Some(encoded_body(text)),
            message_summary_info: summary,
            ..Default::default()
        }
        .encode_to_vec()
    }

    fn mutation(message: Message) -> MessageInst {
        MessageInst {
            id: "2C174D2E-BAA7-4435-A8D5-88BF2C969A44".to_owned(),
            sender: Some("mailto:sender@example.test".to_owned()),
            conversation: Some(ConversationData {
                participants: vec!["mailto:peer@example.test".to_owned()],
                cv_name: None,
                sender_guid: None,
                after_guid: None,
            }),
            message,
            sent_timestamp: PREPARED_UNIX_MILLIS,
            send_delivered: false,
            target: None,
            verification_failed: false,
            certified_context: None,
        }
    }

    fn view(bytes: &[u8]) -> CloudMessageUpdatePredecessorView<'_> {
        CloudMessageUpdatePredecessorView {
            msg_proto: bytes,
            message_time_apple_nanos: ORIGINAL_APPLE_NANOS,
            outer_type: 0,
        }
    }

    #[test]
    fn edit_updates_text_body_and_summary_while_preserving_unknown_proto_fields() {
        let mut original = predecessor("before", None);
        // Unknown protobuf field 99, varint value 7. The lossless patcher must
        // retain it even though the generated MessageProto cannot represent it.
        let unknown = [0x98, 0x06, 0x07];
        original.extend_from_slice(&unknown);
        let request = mutation(Message::Edit(EditMessage {
            tuuid: "5BC3779B-7898-4A15-A768-2EA04D3ABAA0".to_owned(),
            edit_part: 0,
            new_parts: MessageParts(vec![
                IndexedMessagePart {
                    part: MessagePart::Text(
                        "after ".to_owned(),
                        TextFormat::Flags(TextFlags::default()),
                    ),
                    idx: Some(0),
                    ext: None,
                },
                IndexedMessagePart {
                    part: MessagePart::Text(
                        "😀".to_owned(),
                        TextFormat::Flags(TextFlags {
                            bold: true,
                            ..Default::default()
                        }),
                    ),
                    idx: Some(0),
                    ext: None,
                },
            ]),
        }));
        let updated = compose_message_update(view(&original), &request, PREPARED_UNIX_MILLIS)
            .expect("safe edit composes");
        assert!(updated
            .windows(unknown.len())
            .any(|window| window == unknown));
        let decoded = MessageProto::decode(updated.as_slice()).unwrap();
        assert_eq!(decoded.text.as_deref(), Some("after 😀"));
        let body = decoded.attributed_body.as_deref().unwrap();
        crate::cloud_sync_canonical_converter::validate_single_text_attributed_body(
            body,
            "after 😀",
            0,
        )
        .unwrap();
        let summary = Value::from_reader(Cursor::new(
            decoded.message_summary_info.as_deref().unwrap(),
        ))
        .unwrap();
        let root = summary.as_dictionary().unwrap();
        assert_eq!(root.get("ep").unwrap().as_array().unwrap().len(), 1);
        assert_eq!(
            root.get("ec")
                .unwrap()
                .as_dictionary()
                .unwrap()
                .get("0")
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn unsend_retains_text_and_body_and_adds_retracted_part() {
        let original = predecessor("retain me", None);
        let original_proto = MessageProto::decode(original.as_slice()).unwrap();
        let request = mutation(Message::Unsend(UnsendMessage {
            tuuid: "5BC3779B-7898-4A15-A768-2EA04D3ABAA0".to_owned(),
            edit_part: 0,
        }));
        let updated = compose_message_update(view(&original), &request, PREPARED_UNIX_MILLIS)
            .expect("safe unsend composes");
        let decoded = MessageProto::decode(updated.as_slice()).unwrap();
        assert_eq!(decoded.text, original_proto.text);
        assert_eq!(decoded.attributed_body, original_proto.attributed_body);
        let summary = Value::from_reader(Cursor::new(
            decoded.message_summary_info.as_deref().unwrap(),
        ))
        .unwrap();
        assert_eq!(
            summary
                .as_dictionary()
                .unwrap()
                .get("rp")
                .unwrap()
                .as_array()
                .unwrap()
                .first()
                .unwrap()
                .as_unsigned_integer(),
            Some(0)
        );
    }

    #[test]
    fn edit_rejects_nonzero_part_and_timestamp_that_does_not_follow_predecessor() {
        let original = predecessor("before", None);
        let mut request = mutation(Message::Edit(EditMessage {
            tuuid: "5BC3779B-7898-4A15-A768-2EA04D3ABAA0".to_owned(),
            edit_part: 1,
            new_parts: MessageParts(vec![IndexedMessagePart {
                part: MessagePart::Text(
                    "after".to_owned(),
                    TextFormat::Flags(TextFlags::default()),
                ),
                idx: Some(1),
                ext: None,
            }]),
        }));
        assert_eq!(
            compose_message_update(view(&original), &request, PREPARED_UNIX_MILLIS),
            Err(MessageUpdateComposeError::UnsupportedMessage)
        );
        if let Message::Edit(edit) = &mut request.message {
            edit.edit_part = 0;
            edit.new_parts.0[0].idx = Some(0);
        }
        let too_early = ((ORIGINAL_APPLE_NANOS as f64 / 1_000_000_000.0
            + APPLE_EPOCH_OFFSET_MILLIS / 1000.0)
            * 1000.0) as u64;
        assert_eq!(
            compose_message_update(view(&original), &request, too_early),
            Err(MessageUpdateComposeError::TimestampConflict)
        );
    }
}
