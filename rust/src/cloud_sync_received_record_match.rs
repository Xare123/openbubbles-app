//! Bounded read-only native comparator for Apple-first received-message archival.
//!
//! Compares an explicitly expected direct plain-text CloudMessage against an
//! already-found decrypted CloudMessage and returns a pure fixed verdict.
//! Read-only: no I/O, no CloudKit calls, no staging, and no content logging.
//!
//! Verdict meaning:
//! - EquivalentSupportedPlainText: every required identity field and the
//!   plain-text body match. Only proved non-content status differences
//!   (delivery/read flags, delivery/read timestamps, utm) are ignored. The
//!   found record already carries the message.
//! - NeedsProjectionOrUnsupported: a record was found, but equivalence as
//!   supported plain text is not proven (rich, ambiguous, edited, reacted,
//!   replied, media, subject, app, scheduling, off-grid, group, malformed, or
//!   otherwise unknown semantics). Retain the record; never overwrite it.
//! - ConflictingCoreIdentity: core identity (GUID, service, chat route,
//!   direction, sender, destination endpoint, time, record type, error code)
//!   diverges. The found record is a different logical message. Retain it;
//!   never overwrite it.
//!
//! Every verdict precludes a duplicate create: a found record, whatever the
//! verdict, is never permission to issue a new create, overwrite, delete, or
//! adoption. Adoption stays a separate parent-owned decision; this comparator
//! is not a full remote duplicate or adoption proof.
//!
//! Limitations, stated honestly:
//! - Scope is direct single-part plain text only. Group routes, replies
//!   (msgProto2), reaction or association fields, edit or retract summaries,
//!   subjects, effects, app balloons and payloads, scheduling, and off-grid
//!   markers all need projection, even when both sides carry identical values.
//!   A redundant proto4.groupId that exactly repeats the outer direct chat ID
//!   is accepted as structural metadata (the current writer always emits it);
//!   any other group value projects. A plain URL balloon is therefore also
//!   projection: link metadata is rich content outside this proof.
//! - msgProto3 must be identical; its semantics are unknown, so any
//!   difference projects rather than being flattened.
//! - date_read, date_delivered, delivery and read flags, and utm are the
//!   only ignored differences. Any other flag divergence projects; a direction
//!   (IS_FROM_ME) divergence conflicts.
//! - Time follows an explicit millisecond-precision contract: the received wire
//!   retains only milliseconds while CloudMessage.time carries Apple-epoch
//!   nanoseconds. Exact equality always matches; otherwise the found stamp must
//!   fall inside the same millisecond as a millisecond-aligned expected stamp.
//!   No larger tolerance is granted.
//! - A text-only record (protobuf text with no attributed body) is in scope:
//!   our own writer emits this shape. Present but malformed body bytes still
//!   refuse.
//! - The expectation itself must be a supported direct plain-text shape
//!   (iMessage service, type 1, error 0, positive time, non-empty GUID, chat,
//!   sender, and destination, canonical direct route, redundant-or-absent
//!   groupId, known flags only). Anything else projects, even when both sides
//!   match it exactly.
//! - Typed structs cannot prove unknown protobuf fields absent. An Equivalent
//!   verdict alone does not authorize adoption: the caller must still validate
//!   the raw record and unknown protobuf fields against the exact original
//!   bytes (presence proof and readback binding). That caller requirement is
//!   currently unmet by this comparator and is owned by the caller.
//! - Both sides are already-decoded structs, so protobuf wire-level unknown
//!   fields dropped at decode time sit outside this comparison. Exact-byte
//!   binding stays the parent-owned readback job.
//! - Dictionary order is immaterial: attributed bodies are compared through
//!   the existing bounded decoder, never byte-wise.

#![allow(dead_code)]

use rustpush::cloud_messages::{
    cloudmessagesp::{MessageProto3, MessageProto4},
    CloudMessage, MessageFlags,
};

use crate::cloud_sync_canonical_converter::validate_single_plain_text_attributed_body;

/// Fixed verdict of compare_received_record. Pure data: no handles, no
/// permissions, no content.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReceivedRecordMatchVerdict {
    /// Required identity and the supported plain-text body all match.
    EquivalentSupportedPlainText,
    /// A record exists but plain-text equivalence is not proven. Retain it.
    NeedsProjectionOrUnsupported,
    /// Core identity diverges. The found record is a different message.
    ConflictingCoreIdentity,
}

impl ReceivedRecordMatchVerdict {
    /// A found record always precludes a duplicate create, whatever the verdict.
    pub fn precludes_duplicate_create(self) -> bool {
        true
    }

    /// The comparator never authorizes a remote write, overwrite, delete, or adoption.
    pub fn authorizes_remote_write(self) -> bool {
        false
    }
}

/// Delivery and read status flags: the only flag differences this comparator ignores.
fn status_flags() -> MessageFlags {
    MessageFlags::IS_DELIVERED
        | MessageFlags::IS_READ
        | MessageFlags::WAS_DELIVERED_QUIETLY
        | MessageFlags::DID_NOTIFY_RECIPIENT
}

fn proto3_of(message: &CloudMessage) -> Option<&MessageProto3> {
    message.msg_proto_3.as_ref().map(|wrapper| &wrapper.0)
}

fn proto4_of(message: &CloudMessage) -> Option<&MessageProto4> {
    message.msg_proto_4.as_ref().map(|wrapper| &wrapper.0)
}

/// True when nested proto-4 schedule or off-grid markers carry a nonzero value.
fn proto4_schedule_or_offgrid_set(proto: &MessageProto4) -> bool {
    proto.schedule_type.is_some_and(|value| value != 0)
        || proto.schedule_state.is_some_and(|value| value != 0)
        || proto
            .sent_or_received_off_grid
            .is_some_and(|value| value != 0)
}

/// True when nested proto-4 carries reaction, schedule, or off-grid semantics.
/// Group values are checked separately: only an exactly redundant groupId is
/// structural metadata.
fn proto4_needs_projection(proto: &MessageProto4) -> bool {
    proto.associated_message_emoji.is_some() || proto4_schedule_or_offgrid_set(proto)
}

/// Redundant-group check: proto4.groupId repeats the outer direct chat ID on
/// writer-shaped direct messages. Any other value is an unknown alias or
/// group route.
fn proto4_group_unsupported(nested: Option<&MessageProto4>, chat_id: &str) -> bool {
    nested
        .and_then(|proto| proto.group_id.as_deref())
        .is_some_and(|group| group != chat_id)
}

/// Supported-expectation gate for a direct incoming plain-text message.
/// Mirrors the current writer ordinary direct shape (iMessage service, type
/// 1, error 0, canonical direct route, redundant-or-absent groupId, known
/// flags) with received identities and positive time. Anything else is not
/// provable here, even when both sides match it exactly.
fn expected_shape_supported(expected: &CloudMessage) -> bool {
    if expected.service != "iMessage"
        || expected.r#type != 1
        || expected.error != 0
        || expected.time <= 0
        || expected.guid.is_empty()
        || expected.chat_id.is_empty()
        || (expected.flags.contains(MessageFlags::IS_FROM_ME) != expected.sender.is_empty())
        || expected.destination_caller_id.is_empty()
        || !expected.chat_id.starts_with("iMessage;-;")
        || expected.chat_id == "iMessage;-;"
    {
        return false;
    }
    if proto4_group_unsupported(proto4_of(expected), &expected.chat_id) {
        return false;
    }
    let known = status_flags()
        | MessageFlags::IS_FROM_ME
        | MessageFlags::IS_FINISHED
        | MessageFlags::IS_SENT
        | MessageFlags::HAS_DD_RESULTS;
    let known = known | MessageFlags::WAS_DATA_DETECTED;
    expected.flags.difference(known).bits() == 0
}

/// Millisecond-precision time contract: the received wire retains only
/// milliseconds while CloudMessage.time carries Apple-epoch nanoseconds, so
/// exact ns equality can falsely conflict. Exact equality always matches;
/// otherwise the found stamp must fall inside the same millisecond as a
/// millisecond-aligned expected stamp. No larger tolerance is granted.
/// Subtraction is checked so nonpositive or extreme stamps fail closed.
fn times_match(expected_ns: i64, found_ns: i64) -> bool {
    if expected_ns == found_ns {
        return true;
    }
    const NS_PER_MS: i64 = 1_000_000;
    if expected_ns <= 0 || expected_ns % NS_PER_MS != 0 || found_ns < expected_ns {
        return false;
    }
    match found_ns.checked_sub(expected_ns) {
        Some(remainder) => remainder < NS_PER_MS,
        None => false,
    }
}
/// Compare an explicitly expected direct plain-text message against an
/// already-found decrypted record. Fixed evaluation order: core identity
/// first, then content. Never grants any write or adoption permission; every
/// verdict still precludes a duplicate create.
pub fn compare_received_record(
    expected: &CloudMessage,
    found: &CloudMessage,
) -> ReceivedRecordMatchVerdict {
    use ReceivedRecordMatchVerdict as Verdict;

    // Validate the expectation first: unsupported expected shapes project even
    // when both sides carry the identical shape.
    if !expected_shape_supported(expected) {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    // Core identity: exact, no normalization, no alias guessing, no UUID folding.
    if expected.guid != found.guid
        || expected.service != found.service
        || expected.chat_id != found.chat_id
        || expected.sender != found.sender
        || expected.destination_caller_id != found.destination_caller_id
        || !times_match(expected.time, found.time)
        || expected.r#type != found.r#type
        || expected.error != found.error
        || expected.flags.contains(MessageFlags::IS_FROM_ME)
            != found.flags.contains(MessageFlags::IS_FROM_ME)
    {
        return Verdict::ConflictingCoreIdentity;
    }
    // Only proved non-content status may differ: delivery and read flags.
    // (date_read, date_delivered, and utm are likewise ignored by never
    // being read.)
    if expected.flags.difference(status_flags()).bits()
        != found.flags.difference(status_flags()).bits()
    {
        return Verdict::NeedsProjectionOrUnsupported;
    }

    let expected_proto = &expected.msg_proto.0;
    let found_proto = &found.msg_proto.0;

    // The expectation must carry explicit plain text.
    let expected_text = match expected_proto.text.as_deref() {
        Some(text) if !text.is_empty() => text,
        _ => return Verdict::NeedsProjectionOrUnsupported,
    };

    // Plain scalar wire fields: identical or project. Unknown semantics are
    // never flattened.
    if expected_proto.unk1 != found_proto.unk1
        || expected_proto.unk10 != found_proto.unk10
        || expected_proto.unk11 != found_proto.unk11
        || expected_proto.unk14 != found_proto.unk14
    {
        return Verdict::NeedsProjectionOrUnsupported;
    }

    // Subject, app or rich payloads, effects, edits or retracts, replies, and
    // reaction associations need projection when present on either side.
    if expected_proto.subject.is_some() || found_proto.subject.is_some() {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if expected_proto.balloon_bundle_id.is_some() || found_proto.balloon_bundle_id.is_some() {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if expected_proto.payload_data.is_some() || found_proto.payload_data.is_some() {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if expected_proto.message_summary_info.is_some() || found_proto.message_summary_info.is_some() {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if expected_proto.effect.is_some() || found_proto.effect.is_some() {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if expected_proto.associated_message_type.is_some()
        || found_proto.associated_message_type.is_some()
        || expected_proto.associated_message_guid.is_some()
        || found_proto.associated_message_guid.is_some()
        || expected_proto.associated_message_range_location.is_some()
        || found_proto.associated_message_range_location.is_some()
        || expected_proto.associated_message_range_length.is_some()
        || found_proto.associated_message_range_length.is_some()
    {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if expected.msg_proto_2.is_some() || found.msg_proto_2.is_some() {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    // Unknown carrier: identical or project, never flattened.
    if proto3_of(expected) != proto3_of(found) {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    // Nested proto-4: reaction, schedule, and off-grid semantics need
    // projection; the nested service label must match exactly. A redundant
    // groupId is accepted separately below.
    let expected_nested = proto4_of(expected);
    let found_nested = proto4_of(found);
    if expected_nested.is_some_and(proto4_needs_projection)
        || found_nested.is_some_and(proto4_needs_projection)
    {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if proto4_group_unsupported(expected_nested, &expected.chat_id)
        || proto4_group_unsupported(found_nested, &found.chat_id)
    {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if expected_nested.and_then(|proto| proto.service.as_deref())
        != found_nested.and_then(|proto| proto.service.as_deref())
    {
        return Verdict::NeedsProjectionOrUnsupported;
    }

    // Body consistency: exact text plus strict plain attributed bodies decoded
    // through the existing bounded decoder.
    if found_proto.text.as_deref() != Some(expected_text) {
        return Verdict::NeedsProjectionOrUnsupported;
    }
    if let Some(raw) = expected_proto.attributed_body.as_deref() {
        if validate_single_plain_text_attributed_body(raw, expected_text).is_err() {
            return Verdict::NeedsProjectionOrUnsupported;
        }
    }
    // A text-only record is in scope: our writer emits protobuf text without an
    // attributed body. Present bytes must still prove plain.
    if let Some(raw) = found_proto.attributed_body.as_deref() {
        if validate_single_plain_text_attributed_body(raw, expected_text).is_err() {
            return Verdict::NeedsProjectionOrUnsupported;
        }
    }
    Verdict::EquivalentSupportedPlainText
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustpush::cloud_messages::cloudmessagesp::{
        MessageProto, MessageProto2, MessageProto3, MessageProto4,
    };
    use rustpush::cloud_messages::GZipWrapper;
    use rustpush::{
        coder_encode_flattened, NSAttributedString, NSDictionaryTypedCoder, NSNumber, NSString,
        StCollapsedValue,
    };
    use std::collections::HashMap;
    use std::time::SystemTime;

    fn plain_body(text: &str) -> Vec<u8> {
        coder_encode_flattened(&[NSAttributedString {
            text: text.to_owned(),
            ranges: vec![(
                text.encode_utf16().count() as u32,
                NSDictionaryTypedCoder(HashMap::new()),
            )],
        }
        .encode()])
    }

    fn dict_body(text: &str, key: &'static str, value: StCollapsedValue) -> Vec<u8> {
        coder_encode_flattened(&[NSAttributedString {
            text: text.to_owned(),
            ranges: vec![(
                text.encode_utf16().count() as u32,
                NSDictionaryTypedCoder(HashMap::from([(key.to_owned(), value)])),
            )],
        }
        .encode()])
    }

    fn direct_plain(text: &str) -> CloudMessage {
        CloudMessage {
            r#type: 1,
            chat_id: "iMessage;-;+15555550100".to_owned(),
            sender: "tel:+15555550100".to_owned(),
            destination_caller_id: "tel:+15555550200".to_owned(),
            time: 123_000_000,
            msg_proto: GZipWrapper(MessageProto {
                text: Some(text.to_owned()),
                attributed_body: Some(plain_body(text)),
                ..Default::default()
            }),
            guid: "expected-guid".to_owned(),
            service: "iMessage".to_owned(),
            ..Default::default()
        }
    }

    fn verdict_of(expected: &CloudMessage, found: &CloudMessage) -> ReceivedRecordMatchVerdict {
        compare_received_record(expected, found)
    }

    #[test]
    fn mirrored_own_plaintext_uses_empty_sender_and_real_writer_data_flag() {
        let mut expected = direct_plain("mirrored text");
        expected.sender.clear();
        expected.flags = MessageFlags::IS_FROM_ME
            | MessageFlags::IS_FINISHED
            | MessageFlags::IS_SENT
            | MessageFlags::WAS_DATA_DETECTED;
        expected.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("iMessage".into()),
            group_id: Some(expected.chat_id.clone()),
            schedule_type: Some(0),
            schedule_state: Some(0),
            sent_or_received_off_grid: Some(0),
            ..Default::default()
        }));
        let mut found = expected.clone();
        found.flags |= MessageFlags::IS_READ;
        assert_eq!(
            verdict_of(&expected, &found),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
        expected.sender = "unexpected-sender".into();
        assert_eq!(
            verdict_of(&expected, &expected),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn ordinary_apple_encoding_matches_despite_status_variation() {
        let expected = direct_plain("hello");
        let mut found = expected.clone();
        found.flags = MessageFlags::IS_DELIVERED
            | MessageFlags::IS_READ
            | MessageFlags::WAS_DELIVERED_QUIETLY
            | MessageFlags::DID_NOTIFY_RECIPIENT;
        found.msg_proto.0.date_read = Some(779_000_100);
        found.msg_proto.0.date_delivered = Some(779_000_050);
        found.utm = Some(SystemTime::UNIX_EPOCH);
        assert_eq!(
            verdict_of(&expected, &found),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
    }

    #[test]
    fn plain_body_shape_variants_still_match() {
        // Semantic equivalence is decoder-proven, not byte-wise: a two-run
        // plain encoding of the same text matches a single-run expectation.
        let expected = direct_plain("hello world");
        let mut found = expected.clone();
        found.msg_proto.0.attributed_body = Some(coder_encode_flattened(&[NSAttributedString {
            text: "hello world".to_owned(),
            ranges: vec![
                (6, NSDictionaryTypedCoder(HashMap::new())),
                (5, NSDictionaryTypedCoder(HashMap::new())),
            ],
        }
        .encode()]));
        assert_eq!(
            verdict_of(&expected, &found),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
    }

    #[test]
    fn identity_divergence_conflicts() {
        let expected = direct_plain("hello");
        let mut variant = expected.clone();
        variant.guid = "other-guid".to_owned();
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut variant = expected.clone();
        variant.sender = "tel:+15555550999".to_owned();
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut variant = expected.clone();
        variant.time = 124_000_000;
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut variant = expected.clone();
        variant.destination_caller_id = "tel:+15555550300".to_owned();
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut variant = expected.clone();
        variant.service = "SMS".to_owned();
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut variant = expected.clone();
        variant.chat_id = "iMessage;-;+15555550999".to_owned();
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut variant = expected.clone();
        variant.flags = MessageFlags::IS_FROM_ME;
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut variant = expected.clone();
        variant.r#type = 2;
        assert_eq!(
            verdict_of(&expected, &variant),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
    }

    #[test]
    fn changed_text_needs_projection() {
        let expected = direct_plain("hello");
        let mut changed = expected.clone();
        changed.msg_proto.0.text = Some("hello!".to_owned());
        changed.msg_proto.0.attributed_body = Some(plain_body("hello!"));
        assert_eq!(
            verdict_of(&expected, &changed),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let missing_text = CloudMessage {
            msg_proto: GZipWrapper(MessageProto::default()),
            ..direct_plain("hello")
        };
        assert_eq!(
            verdict_of(&missing_text, &expected),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn text_only_found_record_matches_when_plain() {
        let expected = direct_plain("hello");
        let mut text_only = expected.clone();
        text_only.msg_proto.0.attributed_body = None;
        assert_eq!(
            verdict_of(&expected, &text_only),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
        // Present malformed bytes still refuse.
        let mut malformed = expected.clone();
        malformed.msg_proto.0.attributed_body = Some(vec![1_u8, 2, 3]);
        assert_eq!(
            verdict_of(&expected, &malformed),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn standard_structural_metadata_stays_plain() {
        let expected = direct_plain("hello");
        let mut part = expected.clone();
        part.msg_proto.0.attributed_body = Some(dict_body(
            "hello",
            "__kIMMessagePartAttributeName",
            NSNumber(0).encode(),
        ));
        assert_eq!(
            verdict_of(&expected, &part),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
        let mut unbold = expected.clone();
        unbold.msg_proto.0.attributed_body = Some(dict_body(
            "hello",
            "__kIMTextBoldAttributeName",
            NSNumber(0).encode(),
        ));
        assert_eq!(
            verdict_of(&expected, &unbold),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
    }

    #[test]
    fn millisecond_precision_time_contract() {
        let expected = direct_plain("hello");
        // Exact equality always matches, even off millisecond alignment.
        let same = CloudMessage {
            time: 123_000_001,
            ..direct_plain("hello")
        };
        assert_eq!(
            verdict_of(&same, &same.clone()),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
        // An unaligned expectation tolerates no drift.
        let mut drifted = same.clone();
        drifted.time = 123_000_002;
        assert_eq!(
            verdict_of(&same, &drifted),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        // A millisecond-aligned expectation tolerates only the same-millisecond
        // remainder.
        let mut sub_ms = expected.clone();
        sub_ms.time = 123_999_999;
        assert_eq!(
            verdict_of(&expected, &sub_ms),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
        let mut next_ms = expected.clone();
        next_ms.time = 124_000_000;
        assert_eq!(
            verdict_of(&expected, &next_ms),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
        let mut prev_ns = expected.clone();
        prev_ns.time = 122_999_999;
        assert_eq!(
            verdict_of(&expected, &prev_ns),
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity
        );
    }

    #[test]
    fn rich_or_ambiguous_bytes_need_projection() {
        let expected = direct_plain("hello");
        // Formatting is tolerated elsewhere but is not plain equivalence.
        let mut bold = expected.clone();
        bold.msg_proto.0.attributed_body = Some(dict_body(
            "hello",
            "__kIMTextBoldAttributeName",
            NSNumber(1).encode(),
        ));
        assert_eq!(
            verdict_of(&expected, &bold),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        // An incoherent expectation cannot prove equivalence either.
        assert_eq!(
            verdict_of(&bold, &expected),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut unknown = expected.clone();
        unknown.msg_proto.0.attributed_body = Some(dict_body(
            "hello",
            "__kIMUnknownFutureAttribute",
            NSNumber(9).encode(),
        ));
        assert_eq!(
            verdict_of(&expected, &unknown),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut attachment = expected.clone();
        attachment.msg_proto.0.attributed_body = Some(dict_body(
            "hello",
            "__kIMFileTransferGUIDAttributeName",
            NSString("at_0_expected-guid".to_owned()).encode(),
        ));
        assert_eq!(
            verdict_of(&expected, &attachment),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn malformed_bounds_need_projection() {
        let expected = direct_plain("hello");
        for raw in [Vec::new(), vec![1_u8, 2, 3]] {
            let mut malformed = expected.clone();
            malformed.msg_proto.0.attributed_body = Some(raw);
            assert_eq!(
                verdict_of(&expected, &malformed),
                ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
            );
        }
        let full = plain_body("hello");
        let mut truncated = expected.clone();
        truncated.msg_proto.0.attributed_body = Some(full[..full.len() - 4].to_vec());
        assert_eq!(
            verdict_of(&expected, &truncated),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn non_status_flags_and_unsupported_shapes_need_projection() {
        let expected = direct_plain("hello");
        let mut derived = expected.clone();
        derived.flags = MessageFlags::HAS_DD_RESULTS;
        assert_eq!(
            verdict_of(&expected, &derived),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut subject = expected.clone();
        subject.msg_proto.0.subject = Some("synthetic-subject".to_owned());
        assert_eq!(
            verdict_of(&expected, &subject),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut reaction = expected.clone();
        reaction.msg_proto.0.associated_message_type = Some(2000);
        reaction.msg_proto.0.associated_message_guid = Some("p:0/parent".to_owned());
        reaction.msg_proto.0.associated_message_range_location = Some(0);
        reaction.msg_proto.0.associated_message_range_length = Some(4);
        assert_eq!(
            verdict_of(&expected, &reaction),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut reply = expected.clone();
        reply.msg_proto_2 = Some(GZipWrapper(MessageProto2 {
            reply: Some("p:0/parent".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            verdict_of(&expected, &reply),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut summary = expected.clone();
        summary.msg_proto.0.message_summary_info = Some(vec![0]);
        assert_eq!(
            verdict_of(&expected, &summary),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut balloon = expected.clone();
        balloon.msg_proto.0.balloon_bundle_id =
            Some("com.apple.messages.URLBalloonProvider".to_owned());
        balloon.msg_proto.0.payload_data = Some(vec![1]);
        assert_eq!(
            verdict_of(&expected, &balloon),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut effect = expected.clone();
        effect.msg_proto.0.effect = Some("synthetic-effect".to_owned());
        assert_eq!(
            verdict_of(&expected, &effect),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut nested = expected.clone();
        nested.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            associated_message_emoji: Some("synthetic-emoji".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            verdict_of(&expected, &nested),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
        let mut proto3 = expected.clone();
        proto3.msg_proto_3 = Some(GZipWrapper(MessageProto3 {
            unk2: Some(7),
            ..Default::default()
        }));
        assert_eq!(
            verdict_of(&expected, &proto3),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn current_writer_direct_shape_matches() {
        // Structural metadata the current writer always emits on direct sends
        // (redundant groupId, zeroed proto3, ordinary content flags), paired
        // here with received identities.
        let mut expected = direct_plain("hello");
        expected.flags =
            MessageFlags::IS_FINISHED | MessageFlags::IS_SENT | MessageFlags::HAS_DD_RESULTS;
        expected.msg_proto_3 = Some(GZipWrapper(MessageProto3 {
            unk2: Some(0),
            unk3: Some(0),
            ..Default::default()
        }));
        expected.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("iMessage".to_owned()),
            schedule_type: Some(0),
            schedule_state: Some(0),
            group_id: Some("iMessage;-;+15555550100".to_owned()),
            sent_or_received_off_grid: Some(0),
            ..Default::default()
        }));
        assert_eq!(
            verdict_of(&expected, &expected.clone()),
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText
        );
        // An unknown alias or group ID still projects.
        let mut aliased = expected.clone();
        aliased.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            group_id: Some("other-group".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            verdict_of(&expected, &aliased),
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn unsupported_expectations_never_match_even_when_equal() {
        use ReceivedRecordMatchVerdict as Verdict;
        let sms = CloudMessage {
            service: "SMS".to_owned(),
            ..direct_plain("hello")
        };
        assert_eq!(
            verdict_of(&sms, &sms.clone()),
            Verdict::NeedsProjectionOrUnsupported
        );
        let mut reaction = direct_plain("hello");
        reaction.r#type = 2;
        assert_eq!(
            verdict_of(&reaction, &reaction.clone()),
            Verdict::NeedsProjectionOrUnsupported
        );
        let mut errored = direct_plain("hello");
        errored.error = 1;
        assert_eq!(
            verdict_of(&errored, &errored.clone()),
            Verdict::NeedsProjectionOrUnsupported
        );
        for time in [0, -5] {
            let mut stale = direct_plain("hello");
            stale.time = time;
            assert_eq!(
                verdict_of(&stale, &stale.clone()),
                Verdict::NeedsProjectionOrUnsupported
            );
        }
        let mut empty = direct_plain("hello");
        empty.guid = String::new();
        assert_eq!(
            verdict_of(&empty, &empty.clone()),
            Verdict::NeedsProjectionOrUnsupported
        );
        let mut odd = direct_plain("hello");
        odd.flags = MessageFlags::IS_SYSTEM_MESSAGE;
        assert_eq!(
            verdict_of(&odd, &odd.clone()),
            Verdict::NeedsProjectionOrUnsupported
        );
        let mut grouped = direct_plain("hello");
        grouped.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            group_id: Some("group-opaque".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            verdict_of(&grouped, &grouped.clone()),
            Verdict::NeedsProjectionOrUnsupported
        );
    }

    #[test]
    fn every_verdict_precludes_create_and_authorizes_no_write() {
        for verdict in [
            ReceivedRecordMatchVerdict::EquivalentSupportedPlainText,
            ReceivedRecordMatchVerdict::NeedsProjectionOrUnsupported,
            ReceivedRecordMatchVerdict::ConflictingCoreIdentity,
        ] {
            assert!(verdict.precludes_duplicate_create());
            assert!(!verdict.authorizes_remote_write());
        }
    }
}
