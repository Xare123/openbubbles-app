//! Bounded raw MessageProto 1/2/3/4 supported-field checker for received-record equivalence.
//!
//! Pure sidecar to crate::cloud_sync_received_record_match. The typed comparator alone is
//! insufficient because prost drops unknown protobuf fields at decode time. This checker binds
//! the exact raw decompressed protobuf bytes to the provided typed found CloudMessage, then
//! delegates to compare_received_record. Only raw-clean plus typed-Equivalent yields Equivalent.
//! It never grants adoption or remote write. Every verdict still precludes a duplicate create
//! through the delegated verdict type.
//!
//! Required inputs (parent API responsibility, no live proof here):
//! - expected: locally constructed direct plain-text expectation.
//! - found: prost-decoded typed CloudMessage from the exact raw bytes below.
//! - raw: exact decrypted plus decompressed protobuf bytes for each CloudKit msgProto field:
//!   msg_proto is required bytes, msg_proto_2 or 3 or 4 is None for truly absent CloudKit
//!   field and Some(bytes) for present (even when present-empty, Some(&[]) decodes to a
//!   default message). Parent must extract the outer CloudKit record identity and raw fields;
//!   that binding stays parent-owned and is not proved here.
//! - No CloudKit calls, no I/O, no account data, no content logging. Synthetic tests only.
//!   Live CloudKit proof was not run from this sidecar.
//!
//! Semantics:
//! - Truly absent versus empty is enforced: None requires zero wire occurrences, Some
//!   requires exactly one occurrence even for empty string or bytes and zero varint.
//!   Non-optional MessageProto.unk1 is the only exception: absent is accepted only when the
//!   typed value is zero, explicit zero is also accepted. Anything else mismatches.
//! - No decode or reencode equality shortcut: any field order is accepted, non-minimal but
//!   valid varints are accepted when the value matches. Canonical bytes are never required.
//! - Unknown field numbers, duplicate or repeated singular fields, wrong wire types,
//!   overflow, truncated varints or lengths, and oversized inputs can never yield Equivalent.
//!   Unsupported forms are rejected without modifying the input bytes.
//! - Existing raw helpers in cloud_sync_message_proto_patch are private and cannot be reused
//!   without touching source seed code, so only a minimal local bounded scanner lives here.
//!   It is not a large general parser: fixed32 or fixed64 and groups are rejected outright
//!   because this schema uses only varint and length-delimited fields.
//!
//! Bounds and limits:
//! - MAX_RAW_BYTES 4 MiB per proto buffer, MAX_FIELDS 16384 field keys per buffer.
//! - Varint at most 10 bytes, tenth byte at most 1, field number 1..=0x1fffffff.
//! - Length-delimited length must fit inside the buffer. Uint32 fields must fit u32.
//! - Distinct supported fields per message are at most 17, tracked on a fixed stack array.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_received_record_match::{
    compare_received_record, ReceivedRecordMatchVerdict,
};
use rustpush::cloud_messages::{
    cloudmessagesp::{MessageProto, MessageProto2, MessageProto3, MessageProto4},
    CloudMessage,
};

const MAX_RAW_BYTES: usize = 4 * 1024 * 1024;
const MAX_FIELDS: usize = 16 * 1024;
const MAX_FIELD_NUMBER: u64 = 0x1fff_ffff;

/// Fixed raw-binding failures. No content, no handles, no write permission.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReceivedRawMatchFailure {
    Oversized,
    Malformed,
    UnsupportedWireType,
    UnknownField,
    DuplicateField,
    ValueMismatch,
}

/// Exact decompressed protobuf bytes for the found record.
pub struct ReceivedRawProtos<'a> {
    pub msg_proto: &'a [u8],
    pub msg_proto_2: Option<&'a [u8]>,
    pub msg_proto_3: Option<&'a [u8]>,
    pub msg_proto_4: Option<&'a [u8]>,
}

/// Bind raw bytes to the typed found message, then delegate to the typed comparator.
/// Raw-clean plus typed-Equivalent is the only Equivalent path. Never authorizes a write.
pub fn compare_received_raw(
    expected: &CloudMessage,
    found: &CloudMessage,
    raw: &ReceivedRawProtos<'_>,
) -> Result<ReceivedRecordMatchVerdict, ReceivedRawMatchFailure> {
    use ReceivedRawMatchFailure as Failure;
    verify_msg_proto(raw.msg_proto, &found.msg_proto.0)?;
    match (raw.msg_proto_2, found.msg_proto_2.as_ref()) {
        (None, None) => {}
        (Some(bytes), Some(wrapper)) => verify_msg_proto2(bytes, &wrapper.0)?,
        _ => return Err(Failure::ValueMismatch),
    }
    match (raw.msg_proto_3, found.msg_proto_3.as_ref()) {
        (None, None) => {}
        (Some(bytes), Some(wrapper)) => verify_msg_proto3(bytes, &wrapper.0)?,
        _ => return Err(Failure::ValueMismatch),
    }
    match (raw.msg_proto_4, found.msg_proto_4.as_ref()) {
        (None, None) => {}
        (Some(bytes), Some(wrapper)) => verify_msg_proto4(bytes, &wrapper.0)?,
        _ => return Err(Failure::ValueMismatch),
    }
    Ok(compare_received_record(expected, found))
}

fn read_varint(input: &[u8], position: &mut usize) -> Result<u64, ReceivedRawMatchFailure> {
    use ReceivedRawMatchFailure as Failure;
    let mut value = 0u64;
    for index in 0..10 {
        let byte = *input.get(*position).ok_or(Failure::Malformed)?;
        *position += 1;
        if index == 9 && byte > 1 {
            return Err(Failure::Malformed);
        }
        value |= u64::from(byte & 0x7f) << (index * 7);
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(Failure::Malformed)
}

fn read_len<'a>(
    input: &'a [u8],
    position: &mut usize,
) -> Result<&'a [u8], ReceivedRawMatchFailure> {
    use ReceivedRawMatchFailure as Failure;
    let length = read_varint(input, position)?;
    let length = usize::try_from(length).map_err(|_| Failure::Malformed)?;
    let end = position.checked_add(length).ok_or(Failure::Malformed)?;
    if end > input.len() {
        return Err(Failure::Malformed);
    }
    let begin = *position;
    *position = end;
    Ok(&input[begin..end])
}

fn is_supported(
    number: u64,
    lens: &[(u64, Option<&[u8]>)],
    vars: &[(u64, Option<u64>, bool)],
    non_opt: Option<(u64, u32)>,
) -> bool {
    if non_opt.is_some_and(|(field, _)| field == number) {
        return true;
    }
    if lens.iter().any(|(field, _)| *field == number) {
        return true;
    }
    vars.iter().any(|(field, _, _)| *field == number)
}

fn verify_raw(
    raw: &[u8],
    lens: &[(u64, Option<&[u8]>)],
    vars: &[(u64, Option<u64>, bool)],
    non_opt: Option<(u64, u32)>,
) -> Result<(), ReceivedRawMatchFailure> {
    use ReceivedRawMatchFailure as Failure;
    if raw.len() > MAX_RAW_BYTES {
        return Err(Failure::Oversized);
    }
    let mut seen: [u64; 24] = [0; 24];
    let mut seen_len: usize = 0;
    let mut position: usize = 0;
    let mut fields: usize = 0;
    while position < raw.len() {
        fields += 1;
        if fields > MAX_FIELDS {
            return Err(Failure::Oversized);
        }
        let key = read_varint(raw, &mut position)?;
        let number = key >> 3;
        let wire = (key & 7) as u8;
        if number == 0 || number > MAX_FIELD_NUMBER {
            return Err(Failure::Malformed);
        }
        if wire == 3 || wire == 4 || wire == 6 || wire == 7 {
            return Err(Failure::UnsupportedWireType);
        }
        if wire == 1 || wire == 5 {
            let need = if wire == 1 { 8 } else { 4 };
            if position.checked_add(need).is_none_or(|end| end > raw.len()) {
                return Err(Failure::Malformed);
            }
            if is_supported(number, lens, vars, non_opt) {
                return Err(Failure::UnsupportedWireType);
            }
            return Err(Failure::UnknownField);
        }
        if let Some((_, expected)) = lens.iter().find(|(field, _)| *field == number) {
            if wire != 2 {
                return Err(Failure::UnsupportedWireType);
            }
            if seen[..seen_len].contains(&number) {
                return Err(Failure::DuplicateField);
            }
            let payload = read_len(raw, &mut position)?;
            match expected {
                None => return Err(Failure::ValueMismatch),
                Some(want) if payload != *want => return Err(Failure::ValueMismatch),
                _ => {}
            }
            if seen_len >= seen.len() {
                return Err(Failure::Oversized);
            }
            seen[seen_len] = number;
            seen_len += 1;
            continue;
        }
        if let Some((_, expected, is_u32)) = vars.iter().find(|(field, _, _)| *field == number) {
            if wire != 0 {
                return Err(Failure::UnsupportedWireType);
            }
            if seen[..seen_len].contains(&number) {
                return Err(Failure::DuplicateField);
            }
            let value = read_varint(raw, &mut position)?;
            if *is_u32 && value > u32::MAX as u64 {
                return Err(Failure::Malformed);
            }
            match expected {
                None => return Err(Failure::ValueMismatch),
                Some(want) if value != *want => return Err(Failure::ValueMismatch),
                _ => {}
            }
            if seen_len >= seen.len() {
                return Err(Failure::Oversized);
            }
            seen[seen_len] = number;
            seen_len += 1;
            continue;
        }
        if let Some((field, want)) = non_opt {
            if field == number {
                if wire != 0 {
                    return Err(Failure::UnsupportedWireType);
                }
                if seen[..seen_len].contains(&number) {
                    return Err(Failure::DuplicateField);
                }
                let value = read_varint(raw, &mut position)?;
                if value > u32::MAX as u64 || value as u32 != want {
                    if value > u32::MAX as u64 {
                        return Err(Failure::Malformed);
                    }
                    return Err(Failure::ValueMismatch);
                }
                if seen_len >= seen.len() {
                    return Err(Failure::Oversized);
                }
                seen[seen_len] = number;
                seen_len += 1;
                continue;
            }
        }
        return Err(Failure::UnknownField);
    }
    for (field, expected) in lens {
        if expected.is_some() && !seen[..seen_len].contains(field) {
            return Err(Failure::ValueMismatch);
        }
    }
    for (field, expected, _) in vars {
        if expected.is_some() && !seen[..seen_len].contains(field) {
            return Err(Failure::ValueMismatch);
        }
    }
    if let Some((field, want)) = non_opt {
        if want != 0 && !seen[..seen_len].contains(&field) {
            return Err(Failure::ValueMismatch);
        }
    }
    Ok(())
}

fn verify_msg_proto(raw: &[u8], typed: &MessageProto) -> Result<(), ReceivedRawMatchFailure> {
    let lens: [(u64, Option<&[u8]>); 8] = [
        (2, typed.subject.as_deref().map(|value| value.as_bytes())),
        (3, typed.text.as_deref().map(|value| value.as_bytes())),
        (4, typed.attributed_body.as_deref()),
        (
            5,
            typed
                .balloon_bundle_id
                .as_deref()
                .map(|value| value.as_bytes()),
        ),
        (6, typed.payload_data.as_deref()),
        (7, typed.message_summary_info.as_deref()),
        (8, typed.effect.as_deref().map(|value| value.as_bytes())),
        (
            16,
            typed
                .associated_message_guid
                .as_deref()
                .map(|value| value.as_bytes()),
        ),
    ];
    let vars: [(u64, Option<u64>, bool); 8] = [
        (9, typed.date_read, false),
        (10, typed.unk10.map(|value| value as u64), true),
        (11, typed.unk11.map(|value| value as u64), true),
        (13, typed.date_delivered, false),
        (14, typed.unk14.map(|value| value as u64), true),
        (
            15,
            typed.associated_message_type.map(|value| value as u64),
            true,
        ),
        (
            17,
            typed
                .associated_message_range_location
                .map(|value| value as u64),
            true,
        ),
        (
            18,
            typed
                .associated_message_range_length
                .map(|value| value as u64),
            true,
        ),
    ];
    verify_raw(raw, &lens, &vars, Some((1, typed.unk1)))
}

fn verify_msg_proto2(raw: &[u8], typed: &MessageProto2) -> Result<(), ReceivedRawMatchFailure> {
    let lens: [(u64, Option<&[u8]>); 1] =
        [(2, typed.reply.as_deref().map(|value| value.as_bytes()))];
    let vars: [(u64, Option<u64>, bool); 0] = [];
    verify_raw(raw, &lens, &vars, None)
}

fn verify_msg_proto3(raw: &[u8], typed: &MessageProto3) -> Result<(), ReceivedRawMatchFailure> {
    let lens: [(u64, Option<&[u8]>); 0] = [];
    let vars: [(u64, Option<u64>, bool); 2] = [
        (2, typed.unk2.map(|value| value as u64), true),
        (3, typed.unk3.map(|value| value as u64), true),
    ];
    verify_raw(raw, &lens, &vars, None)
}

fn verify_msg_proto4(raw: &[u8], typed: &MessageProto4) -> Result<(), ReceivedRawMatchFailure> {
    let lens: [(u64, Option<&[u8]>); 3] = [
        (
            2,
            typed
                .associated_message_emoji
                .as_deref()
                .map(|value| value.as_bytes()),
        ),
        (4, typed.service.as_deref().map(|value| value.as_bytes())),
        (7, typed.group_id.as_deref().map(|value| value.as_bytes())),
    ];
    let vars: [(u64, Option<u64>, bool); 3] = [
        (5, typed.schedule_type.map(|value| value as u64), true),
        (6, typed.schedule_state.map(|value| value as u64), true),
        (
            8,
            typed.sent_or_received_off_grid.map(|value| value as u64),
            true,
        ),
    ];
    verify_raw(raw, &lens, &vars, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message as _;
    use rustpush::cloud_messages::cloudmessagesp::{MessageProto2, MessageProto3, MessageProto4};
    use rustpush::cloud_messages::GZipWrapper;
    use rustpush::cloud_messages::MessageFlags;

    fn encode_varint(mut value: u64, out: &mut Vec<u8>) {
        loop {
            let byte = (value & 0x7f) as u8;
            value >>= 7;
            if value == 0 {
                out.push(byte);
                return;
            }
            out.push(byte | 0x80);
        }
    }

    fn len_field(number: u64, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        encode_varint((number << 3) | 2, &mut out);
        encode_varint(payload.len() as u64, &mut out);
        out.extend_from_slice(payload);
        out
    }

    fn var_field(number: u64, value: u64) -> Vec<u8> {
        let mut out = Vec::new();
        encode_varint(number << 3, &mut out);
        encode_varint(value, &mut out);
        out
    }

    fn text_only_message(text: &str) -> CloudMessage {
        CloudMessage {
            r#type: 1,
            chat_id: "iMessage;-;+15555550100".to_owned(),
            sender: "tel:+15555550100".to_owned(),
            destination_caller_id: "tel:+15555550200".to_owned(),
            time: 123_000_000,
            msg_proto: GZipWrapper(MessageProto {
                text: Some(text.to_owned()),
                ..Default::default()
            }),
            guid: "expected-guid".to_owned(),
            service: "iMessage".to_owned(),
            ..Default::default()
        }
    }

    fn raw_protos<'a>(
        msg_proto: &'a [u8],
        msg_proto_2: Option<&'a [u8]>,
        msg_proto_3: Option<&'a [u8]>,
        msg_proto_4: Option<&'a [u8]>,
    ) -> ReceivedRawProtos<'a> {
        ReceivedRawProtos {
            msg_proto,
            msg_proto_2,
            msg_proto_3,
            msg_proto_4,
        }
    }

    #[test]
    fn clean_single_field_binds() {
        let typed = MessageProto {
            text: Some("hello".to_owned()),
            ..Default::default()
        };
        let raw = typed.encode_to_vec();
        assert!(verify_msg_proto(&raw, &typed).is_ok());
    }

    #[test]
    fn unknown_field_rejected_despite_prost_drop() {
        let typed = MessageProto {
            text: Some("hello".to_owned()),
            ..Default::default()
        };
        let mut raw = typed.encode_to_vec();
        raw.extend_from_slice(&var_field(99, 1));
        let decoded = MessageProto::decode(raw.as_slice()).unwrap();
        assert_eq!(decoded, typed);
        assert_eq!(
            verify_msg_proto(&raw, &typed),
            Err(ReceivedRawMatchFailure::UnknownField)
        );
    }

    #[test]
    fn duplicate_singular_rejected() {
        let typed = MessageProto {
            text: Some("hello".to_owned()),
            ..Default::default()
        };
        let raw = [len_field(3, b"hello"), len_field(3, b"hello")].concat();
        let decoded = MessageProto::decode(raw.as_slice()).unwrap();
        assert_eq!(decoded.text.as_deref(), Some("hello"));
        assert_eq!(
            verify_msg_proto(&raw, &typed),
            Err(ReceivedRawMatchFailure::DuplicateField)
        );
    }

    #[test]
    fn wrong_wire_rejected() {
        let typed = MessageProto {
            text: Some("hello".to_owned()),
            ..Default::default()
        };
        let raw = var_field(3, 1);
        assert_eq!(
            verify_msg_proto(&raw, &typed),
            Err(ReceivedRawMatchFailure::UnsupportedWireType)
        );
    }

    #[test]
    fn truncated_and_overflow_rejected() {
        let typed = MessageProto {
            text: Some("hello".to_owned()),
            ..Default::default()
        };
        assert_eq!(
            verify_msg_proto(&[0x1a], &typed),
            Err(ReceivedRawMatchFailure::Malformed)
        );
        assert_eq!(
            verify_msg_proto(&[0x1a, 5, b'a'], &typed),
            Err(ReceivedRawMatchFailure::Malformed)
        );
        assert_eq!(
            verify_msg_proto(&[0x80], &typed),
            Err(ReceivedRawMatchFailure::Malformed)
        );
        assert_eq!(
            verify_msg_proto(&[0xff; 11], &typed),
            Err(ReceivedRawMatchFailure::Malformed)
        );
        assert_eq!(
            verify_msg_proto(&[0x00], &typed),
            Err(ReceivedRawMatchFailure::Malformed)
        );
        assert_eq!(
            verify_msg_proto(&[0xa1, 6, 0, 1, 2], &typed),
            Err(ReceivedRawMatchFailure::Malformed)
        );
    }

    #[test]
    fn absent_vs_empty_distinguished() {
        let absent = MessageProto::default();
        assert!(verify_msg_proto(&[], &absent).is_ok());
        let empty_text = MessageProto {
            text: Some(String::new()),
            ..Default::default()
        };
        assert_eq!(
            verify_msg_proto(&[], &empty_text),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
        assert_eq!(
            verify_msg_proto(&len_field(3, b""), &absent),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
        let zero_opt = MessageProto3 {
            unk2: Some(0),
            ..Default::default()
        };
        assert_eq!(
            verify_msg_proto3(&[], &zero_opt),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
        let zero_non_opt = MessageProto {
            unk1: 0,
            ..Default::default()
        };
        assert!(verify_msg_proto(&[], &zero_non_opt).is_ok());
        let one_non_opt = MessageProto {
            unk1: 1,
            ..Default::default()
        };
        assert_eq!(
            verify_msg_proto(&[], &one_non_opt),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
    }

    #[test]
    fn field_order_accepted() {
        let typed = MessageProto {
            subject: Some("s".to_owned()),
            text: Some("hello".to_owned()),
            ..Default::default()
        };
        let forward = [len_field(2, b"s"), len_field(3, b"hello")].concat();
        let backward = [len_field(3, b"hello"), len_field(2, b"s")].concat();
        assert!(verify_msg_proto(&forward, &typed).is_ok());
        assert!(verify_msg_proto(&backward, &typed).is_ok());
        assert_ne!(forward, backward);
    }

    #[test]
    fn value_mismatch_rejected() {
        let typed = MessageProto {
            text: Some("hello!".to_owned()),
            ..Default::default()
        };
        let raw = len_field(3, b"hello");
        assert_eq!(
            verify_msg_proto(&raw, &typed),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
    }

    #[test]
    fn proto3_all_supported_fields_roundtrip() {
        let typed = MessageProto3 {
            unk2: Some(7),
            unk3: Some(0),
            ..Default::default()
        };
        let raw = typed.encode_to_vec();
        assert!(verify_msg_proto3(&raw, &typed).is_ok());
        let swapped = [var_field(3, 0), var_field(2, 7)].concat();
        assert!(verify_msg_proto3(&swapped, &typed).is_ok());
    }

    #[test]
    fn proto4_all_supported_fields_roundtrip() {
        let typed = MessageProto4 {
            associated_message_emoji: Some("emoji".to_owned()),
            service: Some("iMessage".to_owned()),
            schedule_type: Some(0),
            schedule_state: Some(2),
            group_id: Some("iMessage;-;+15555550100".to_owned()),
            sent_or_received_off_grid: Some(0),
            ..Default::default()
        };
        let raw = typed.encode_to_vec();
        assert!(verify_msg_proto4(&raw, &typed).is_ok());
    }

    #[test]
    fn unknown_in_each_optional_proto_rejected() {
        let t2 = MessageProto2 {
            reply: Some("p:0/parent".to_owned()),
            ..Default::default()
        };
        let mut r2 = t2.encode_to_vec();
        r2.extend_from_slice(&var_field(99, 1));
        assert_eq!(MessageProto2::decode(r2.as_slice()).unwrap(), t2);
        assert_eq!(
            verify_msg_proto2(&r2, &t2),
            Err(ReceivedRawMatchFailure::UnknownField)
        );
        let t3 = MessageProto3 {
            unk2: Some(1),
            ..Default::default()
        };
        let mut r3 = t3.encode_to_vec();
        r3.extend_from_slice(&var_field(99, 1));
        assert_eq!(MessageProto3::decode(r3.as_slice()).unwrap(), t3);
        assert_eq!(
            verify_msg_proto3(&r3, &t3),
            Err(ReceivedRawMatchFailure::UnknownField)
        );
        let t4 = MessageProto4 {
            service: Some("iMessage".to_owned()),
            ..Default::default()
        };
        let mut r4 = t4.encode_to_vec();
        r4.extend_from_slice(&var_field(99, 1));
        assert_eq!(MessageProto4::decode(r4.as_slice()).unwrap(), t4);
        assert_eq!(
            verify_msg_proto4(&r4, &t4),
            Err(ReceivedRawMatchFailure::UnknownField)
        );
    }

    #[test]
    fn u32_overflow_rejected() {
        let clean3 = MessageProto3::default();
        assert_eq!(
            verify_msg_proto3(&var_field(2, u32::MAX as u64 + 1), &clean3),
            Err(ReceivedRawMatchFailure::Malformed)
        );
        let clean4 = MessageProto4::default();
        assert_eq!(
            verify_msg_proto4(&var_field(5, u32::MAX as u64 + 1), &clean4),
            Err(ReceivedRawMatchFailure::Malformed)
        );
        let clean1 = MessageProto::default();
        assert_eq!(
            verify_msg_proto(&var_field(10, u32::MAX as u64 + 1), &clean1),
            Err(ReceivedRawMatchFailure::Malformed)
        );
    }

    #[test]
    fn explicit_zero_option_requires_presence() {
        let t3 = MessageProto3 {
            unk3: Some(0),
            ..Default::default()
        };
        assert!(verify_msg_proto3(&var_field(3, 0), &t3).is_ok());
        assert_eq!(
            verify_msg_proto3(&[], &t3),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
        let t4 = MessageProto4 {
            schedule_state: Some(0),
            ..Default::default()
        };
        assert!(verify_msg_proto4(&var_field(6, 0), &t4).is_ok());
        assert_eq!(
            verify_msg_proto4(&[], &t4),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
        let t2 = MessageProto2 {
            reply: Some(String::new()),
            ..Default::default()
        };
        assert!(verify_msg_proto2(&len_field(2, b""), &t2).is_ok());
        assert_eq!(
            verify_msg_proto2(&[], &t2),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
    }

    #[test]
    fn outer_absence_binding() {
        let mut found = text_only_message("hello");
        let clean = found.msg_proto.0.encode_to_vec();
        let raw = raw_protos(&clean, None, None, None);
        assert!(compare_received_raw(&found.clone(), &found, &raw).is_ok());
        let raw_present = raw_protos(&clean, Some(&[]), None, None);
        assert_eq!(
            compare_received_raw(&found.clone(), &found, &raw_present),
            Err(ReceivedRawMatchFailure::ValueMismatch)
        );
        found.msg_proto_2 = Some(GZipWrapper(MessageProto2::default()));
        let raw_empty = raw_protos(&clean, Some(&[]), None, None);
        assert!(compare_received_raw(&found.clone(), &found, &raw_empty).is_ok());
    }

    #[test]
    fn delegation_requires_both_raw_clean_and_typed_equivalent() {
        use crate::cloud_sync_received_record_match::ReceivedRecordMatchVerdict as Verdict;
        let expected = text_only_message("hello");
        let found = expected.clone();
        let clean = found.msg_proto.0.encode_to_vec();
        let raw = raw_protos(&clean, None, None, None);
        let verdict = compare_received_raw(&expected, &found, &raw).unwrap();
        assert_eq!(verdict, Verdict::EquivalentSupportedPlainText);
        assert!(verdict.precludes_duplicate_create());
        assert!(!verdict.authorizes_remote_write());
        let mut dirty = clean.clone();
        dirty.extend_from_slice(&var_field(99, 1));
        let raw_dirty = raw_protos(&dirty, None, None, None);
        assert_eq!(
            compare_received_raw(&expected, &found, &raw_dirty),
            Err(ReceivedRawMatchFailure::UnknownField)
        );
        let mut projected = expected.clone();
        projected.msg_proto.0.subject = Some("synthetic-subject".to_owned());
        let projected_raw = projected.msg_proto.0.encode_to_vec();
        let raw_projected = raw_protos(&projected_raw, None, None, None);
        let verdict = compare_received_raw(&projected.clone(), &projected, &raw_projected).unwrap();
        assert_eq!(verdict, Verdict::NeedsProjectionOrUnsupported);
        assert!(!verdict.authorizes_remote_write());
    }
}
