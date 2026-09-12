// Pinned-source parent projection sidecar.
// Projects an already-decoded protected IDS attachment source
// (DecodedIdsAttachmentSource) into the initial reflected NSAttributedString
// body, mirroring indexedPartsToAttributedBodyDyn with existingBody=null as
// called by reflectMessageDyn, and the Rust mirror
// initial_reflected_attachment_guid in cloud_sync_ids_attachment_source.rs.
// Step-for-step parity with that helper is intentional: the per-attachment
// decoded_attachment_upload_material derives metadata.guid from the same
// field-index walk. Tests check their parity per link (meta.guid == apple_guid).
//
// Scope: deterministic projection and strict source-bound body comparison.
// The caller keeps all lease, account, store, auth checks and supplies a source
// opened after its own committed-lease verification (same contract as
// restore_ids_attachment_message). The bounded reader below admits only the
// projected initial-body grammar, never generic attributed content. The
// outbound module owns protected staging and repeats the source GUID binding.
//
// Determinism is semantic, not byte-level: run order, UTF-16 lengths, and
// GUID mapping are fixed, but NSDictionaryTypedCoder iterates a HashMap, so
// dict key order may vary. Stage the bytes once and compare via decode.
// Eviction is fail-closed at full-projection scope: a pushed attachment run
// later removed by a first-use field fails the whole projection with
// UnsupportedMessage, even though the per-guid helper could still project a
// surviving sibling. No silent partial correspondence is ever returned.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_canonical_dto::{
    parse_owned_attachment_guid, CloudCanonicalAttributedBody, CloudCanonicalTextRun,
};
use crate::cloud_sync_ids_attachment_source::{DecodedIdsAttachmentSource, DecodedPart};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use rustpush::{
    coder_encode_flattened, NSAttributedString, NSDictionaryTypedCoder, NSNumber, NSString,
    StCollapsedValue,
};
use std::collections::{HashMap, HashSet};

const MSG_PART_KEY: &str = "__kIMMessagePartAttributeName";
const ATTACH_GUID_KEY: &str = "__kIMFileTransferGUIDAttributeName";
const BOLD_KEY: &str = "__kIMTextBoldAttributeName";
const ITALIC_KEY: &str = "__kIMTextItalicAttributeName";
const STRIKE_KEY: &str = "__kIMTextStrikethroughAttributeName";
const UNDERLINE_KEY: &str = "__kIMTextUnderlineAttributeName";
const SMIL_MIME: &str = "application/smil";
const ATTACHMENT_PLACEHOLDER: char = ' ';

/// Ordered correspondence row for one reflected attachment.
///
/// original_guid is the opaque source GUID from the decoded envelope (never
/// placed on the wire). apple_guid is the wire reference
/// (at_<field>_<message>). local_guid is the reflected local form
/// (<message>_<field>), which equals the canonical GUID the converter
/// derives from the wire reference. field_idx/start/length pin the run in
/// UTF-16 units. The parent source-inventory API matches these rows against
/// the persisted upload plan before allocating any randomness, which is what
/// survives a local-echo attachment GUID rename.
pub(crate) struct ParentAttachmentLink {
    pub original_guid: String,
    pub apple_guid: String,
    pub local_guid: String,
    pub canonical_guid: String,
    pub field_idx: u32,
    pub start_utf16: u32,
    pub length_utf16: u32,
}

/// Deterministic projection of a decoded pinned source.
///
/// text is the reflected body string (text tokens in part order, one ASCII
/// space per reflected attachment). encoded_body is the flattened coder
/// encoding of the single NSAttributedString. links is in reflected-body
/// order and covers only attachments with a surviving final body reference.
pub(crate) struct ParentAttributedProjection {
    pub text: String,
    pub utf16_length: u32,
    pub encoded_body: Vec<u8>,
    pub links: Vec<ParentAttachmentLink>,
    body: StCollapsedValue,
}

impl ParentAttributedProjection {
    /// Dictionary order may differ across projections. Every class, field,
    /// attribute, value and UTF-16 range must otherwise match the source.
    pub(crate) fn validate_encoded_body(&self, encoded: &[u8]) -> Result<(), Failure> {
        crate::cloud_sync_canonical_converter::validate_source_projected_attributed_body(
            encoded, &self.body,
        )
        .map_err(|_| Failure::BindingMismatch)
    }
}

enum RunDraft {
    Text {
        message_part: u32,
        start_utf16: u32,
        length_utf16: u32,
    },
    Attachment {
        run_message_part: u32,
        field_idx: u32,
        original_guid: String,
        apple_guid: String,
        local_guid: String,
        canonical_guid: String,
        start_utf16: u32,
    },
}

fn is_valid_id(value: &str) -> bool {
    !value.is_empty() && !value.chars().any(char::is_control)
}

fn text_dict(message_part: u32) -> NSDictionaryTypedCoder {
    NSDictionaryTypedCoder(HashMap::from_iter([
        (MSG_PART_KEY.to_owned(), NSNumber(message_part).encode()),
        (BOLD_KEY.to_owned(), NSNumber(0).encode()),
        (ITALIC_KEY.to_owned(), NSNumber(0).encode()),
        (STRIKE_KEY.to_owned(), NSNumber(0).encode()),
        (UNDERLINE_KEY.to_owned(), NSNumber(0).encode()),
    ]))
}

fn attachment_dict(message_part: u32, apple_guid: &str) -> NSDictionaryTypedCoder {
    NSDictionaryTypedCoder(HashMap::from_iter([
        (MSG_PART_KEY.to_owned(), NSNumber(message_part).encode()),
        (
            ATTACH_GUID_KEY.to_owned(),
            NSString(apple_guid.to_owned()).encode(),
        ),
    ]))
}

/// The wire stores lengths, not starts. Require complete contiguous coverage
/// rather than silently shifting a link or inventing attributes for a gap.
fn contiguous_ranges(
    spans: Vec<(u32, u32, NSDictionaryTypedCoder)>,
    utf16_length: u32,
) -> Result<Vec<(u32, NSDictionaryTypedCoder)>, Failure> {
    let mut out = Vec::with_capacity(spans.len());
    let mut expected: u32 = 0;
    for (start, len, dict) in spans {
        if start != expected {
            return Err(Failure::MalformedMessage);
        }
        out.push((len, dict));
        expected = expected.checked_add(len).ok_or(Failure::OversizedMessage)?;
    }
    if expected != utf16_length {
        return Err(Failure::MalformedMessage);
    }
    Ok(out)
}

/// Project a decoded pinned source to its initial reflected attributed body.
///
/// Mirrors the field-index walk of initial_reflected_attachment_guid and
/// indexedPartsToAttributedBodyDyn(existingBody=null): explicit per-part
/// idx wins, otherwise the field defaults to the count of attachment runs
/// already in the body; the first use of an index evicts prior runs with
/// that messagePart (body string itself stays monotonic, so UTF-16 starts
/// are stable); iris and application/smil attachments are skipped after the
/// eviction step; a reused owned index is BindingMismatch. Text tokens keep
/// exact order and plain formatting (the source validator admits only
/// plain text, so runs carry explicit false flags, matching reflection).
/// A pushed attachment run later evicted by another part, or zero surviving
/// attachment runs, is UnsupportedMessage, matching the per-guid helper.
pub(crate) fn project_parent_attributed_body(
    decoded: &DecodedIdsAttachmentSource,
) -> Result<ParentAttributedProjection, Failure> {
    if !is_valid_id(&decoded.message_guid) {
        return Err(Failure::MalformedMessage);
    }
    if decoded.attachment_guids.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    for guid in &decoded.attachment_guids {
        if !is_valid_id(guid) {
            return Err(Failure::MalformedMessage);
        }
    }
    if decoded
        .attachment_guids
        .iter()
        .collect::<HashSet<_>>()
        .len()
        != decoded.attachment_guids.len()
    {
        return Err(Failure::MalformedMessage);
    }
    let mut ordered = Vec::with_capacity(decoded.attachment_guids.len());
    for part in &decoded.parts {
        if let DecodedPart::Attachment(a) = part {
            ordered.push(a.guid.clone());
        }
    }
    if ordered.is_empty() || ordered != decoded.attachment_guids {
        return Err(Failure::BindingMismatch);
    }

    let mut body_text = String::new();
    let mut cursor: u32 = 0;
    let mut runs: Vec<RunDraft> = Vec::with_capacity(decoded.parts.len());
    let mut added: HashSet<u64> = HashSet::new();
    let mut owned: HashSet<u64> = HashSet::new();

    for part in &decoded.parts {
        match part {
            DecodedPart::Text { text, idx } => {
                let field_u64 = idx.unwrap_or_else(|| {
                    runs.iter()
                        .filter(|r| matches!(r, RunDraft::Attachment { .. }))
                        .count() as u64
                });
                let field = u32::try_from(field_u64).map_err(|_| Failure::OversizedMessage)?;
                if added.insert(field_u64) {
                    runs.retain(|r| match r {
                        RunDraft::Text { message_part, .. } => *message_part != field,
                        RunDraft::Attachment {
                            run_message_part, ..
                        } => *run_message_part != field,
                    });
                }
                let len = u32::try_from(text.encode_utf16().count())
                    .map_err(|_| Failure::OversizedMessage)?;
                let start = cursor;
                cursor = cursor.checked_add(len).ok_or(Failure::OversizedMessage)?;
                body_text.push_str(text);
                runs.push(RunDraft::Text {
                    message_part: field,
                    start_utf16: start,
                    length_utf16: len,
                });
            }
            DecodedPart::Attachment(a) => {
                let field_u64 = a.idx.unwrap_or_else(|| {
                    runs.iter()
                        .filter(|r| matches!(r, RunDraft::Attachment { .. }))
                        .count() as u64
                });
                let field = u32::try_from(field_u64).map_err(|_| Failure::OversizedMessage)?;
                if added.insert(field_u64) {
                    runs.retain(|r| match r {
                        RunDraft::Text { message_part, .. } => *message_part != field,
                        RunDraft::Attachment {
                            run_message_part, ..
                        } => *run_message_part != field,
                    });
                }
                if a.iris || a.mime == SMIL_MIME {
                    continue;
                }
                if !owned.insert(field_u64) {
                    return Err(Failure::BindingMismatch);
                }
                if !is_valid_id(&a.guid) {
                    return Err(Failure::MalformedMessage);
                }
                let apple_guid = format!("at_{field}_{}", decoded.message_guid);
                let parsed = parse_owned_attachment_guid(&apple_guid)
                    .map_err(|_| Failure::MalformedMessage)?;
                if parsed.message_guid() != decoded.message_guid {
                    return Err(Failure::BindingMismatch);
                }
                let canonical_guid = parsed.canonical_guid().to_owned();
                let local_guid = format!("{}_{field}", decoded.message_guid);
                if canonical_guid != local_guid {
                    return Err(Failure::BindingMismatch);
                }
                let run_mp =
                    u32::try_from(runs.len() as u64).map_err(|_| Failure::OversizedMessage)?;
                let start = cursor;
                cursor = cursor.checked_add(1).ok_or(Failure::OversizedMessage)?;
                body_text.push(ATTACHMENT_PLACEHOLDER);
                runs.push(RunDraft::Attachment {
                    run_message_part: run_mp,
                    field_idx: field,
                    original_guid: a.guid.clone(),
                    apple_guid,
                    local_guid,
                    canonical_guid,
                    start_utf16: start,
                });
            }
        }
    }

    let mut spans: Vec<(u32, u32, NSDictionaryTypedCoder)> = Vec::with_capacity(runs.len());
    let mut links: Vec<ParentAttachmentLink> = Vec::new();
    let mut canonical_runs = Vec::with_capacity(runs.len());
    for run in &runs {
        match run {
            RunDraft::Text {
                message_part,
                start_utf16,
                length_utf16,
            } => {
                spans.push((*start_utf16, *length_utf16, text_dict(*message_part)));
                canonical_runs.push(
                    CloudCanonicalTextRun::new(
                        *start_utf16,
                        *length_utf16,
                        Some(*message_part),
                        None,
                        None,
                        None,
                        None,
                        Some(false),
                        Some(false),
                        Some(false),
                        Some(false),
                    )
                    .map_err(|_| Failure::MalformedMessage)?,
                );
            }
            RunDraft::Attachment {
                run_message_part,
                field_idx,
                original_guid,
                apple_guid,
                local_guid,
                canonical_guid,
                start_utf16,
            } => {
                let parsed = parse_owned_attachment_guid(apple_guid)
                    .map_err(|_| Failure::MalformedMessage)?;
                if parsed.message_guid() != decoded.message_guid
                    || parsed.canonical_guid() != canonical_guid
                    || *parsed.canonical_guid() != *local_guid
                {
                    return Err(Failure::BindingMismatch);
                }
                spans.push((
                    *start_utf16,
                    1,
                    attachment_dict(*run_message_part, apple_guid),
                ));
                canonical_runs.push(
                    CloudCanonicalTextRun::new(
                        *start_utf16,
                        1,
                        Some(*run_message_part),
                        None,
                        None,
                        None,
                        None,
                        None,
                        None,
                        None,
                        None,
                    )
                    .map_err(|_| Failure::MalformedMessage)?,
                );
                links.push(ParentAttachmentLink {
                    original_guid: original_guid.clone(),
                    apple_guid: apple_guid.clone(),
                    local_guid: local_guid.clone(),
                    canonical_guid: canonical_guid.clone(),
                    field_idx: *field_idx,
                    start_utf16: *start_utf16,
                    length_utf16: 1,
                });
            }
        }
    }
    if links.is_empty() || links.len() != owned.len() {
        return Err(Failure::UnsupportedMessage);
    }
    // Fail closed with the converter's own range validator before handing
    // the bytes to future guarded staging. Keyed logical-hash binding stays
    // converter-owned at staging time and is deliberately not replicated here.
    let _accepted = CloudCanonicalAttributedBody::new(body_text.clone(), canonical_runs)
        .map_err(|_| Failure::MalformedMessage)?;

    // Reachable projections never gap (text runs always carry their used
    // field, so first-use eviction can only remove attachment runs, and any
    // evicted attachment run fails closed above). Assert complete coverage
    // before encoding so future changes cannot silently shift link offsets.
    let ranges = contiguous_ranges(spans, cursor)?;

    let collapsed = NSAttributedString {
        text: body_text.clone(),
        ranges,
    }
    .encode();
    let encoded_body = coder_encode_flattened(std::slice::from_ref(&collapsed));
    if encoded_body.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    Ok(ParentAttributedProjection {
        text: body_text,
        utf16_length: cursor,
        encoded_body,
        links,
        body: collapsed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_ids_attachment_source::{
        decoded_attachment_upload_material, DecodedAttachment, NativeAttachmentMetaTimes,
    };
    use rustpush::{coder_decode_flattened, NSNumber, NSString};

    const TIMES: NativeAttachmentMetaTimes = NativeAttachmentMetaTimes {
        start_date_ns: 1,
        created_date_ns: 2,
    };

    #[test]
    fn strict_source_comparison_accepts_dictionary_order_not_semantic_changes() {
        let source = crate::cloud_sync_outbound::attachment_parent_test_support::source();
        let projection = project_parent_attributed_body(&source).unwrap();
        assert_eq!(projection.utf16_length, 6);
        assert_eq!(projection.links[0].start_utf16, 3);
        assert_eq!(projection.links[1].start_utf16, 5);
        assert_eq!(projection.links[0].apple_guid, "at_1_parent-fixture-guid");
        assert_eq!(projection.links[1].apple_guid, "at_7_parent-fixture-guid");
        projection
            .validate_encoded_body(&projection.encoded_body)
            .unwrap();
        let mut reordered = projection.body.clone();
        if let StCollapsedValue::Object { fields, .. } = &mut reordered {
            for field in fields.iter_mut().skip(1) {
                if let [StCollapsedValue::Object { class, fields }] = field.as_mut_slice() {
                    if class == "NSDictionary" {
                        let mut entries: Vec<_> = fields[1..]
                            .chunks_exact(2)
                            .map(|pair| pair.to_vec())
                            .collect();
                        entries.reverse();
                        fields.truncate(1);
                        fields.extend(entries.into_iter().flatten());
                    }
                }
            }
        }
        let reordered_bytes = coder_encode_flattened(&[reordered]);
        assert_ne!(reordered_bytes, projection.encoded_body);
        projection.validate_encoded_body(&reordered_bytes).unwrap();

        let mut changed = decode_wire(&projection);
        changed.text = "Z😀 B ".to_owned();
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&[changed.encode()]))
            .is_err());
        let mut changed = decode_wire(&projection);
        changed.ranges[0].0 -= 1; // splitting the source's surrogate pair
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&[changed.encode()]))
            .is_err());
        let mut changed = decode_wire(&projection);
        changed.ranges[1].1 .0.insert(
            ATTACH_GUID_KEY.to_owned(),
            NSString("at_1_other-parent".to_owned()).encode(),
        );
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&[changed.encode()]))
            .is_err());
        let mut changed = decode_wire(&projection);
        changed.ranges[0]
            .1
             .0
            .insert(BOLD_KEY.to_owned(), NSNumber(1).encode());
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&[changed.encode()]))
            .is_err());
        let mut changed = decode_wire(&projection);
        changed.ranges[0]
            .1
             .0
            .insert("unknown-attribute".to_owned(), NSNumber(0).encode());
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&[changed.encode()]))
            .is_err());
    }

    #[test]
    fn strict_source_comparison_rejects_duplicate_keys_and_hidden_key_fields() {
        let source = crate::cloud_sync_outbound::attachment_parent_test_support::source();
        let projection = project_parent_attributed_body(&source).unwrap();
        for duplicate in [false, true] {
            let mut body = projection.body.clone();
            let StCollapsedValue::Object { fields, .. } = &mut body else {
                panic!("fixture body")
            };
            let StCollapsedValue::Object {
                fields: dictionary, ..
            } = &mut fields[2][0]
            else {
                panic!("fixture dictionary")
            };
            if duplicate {
                dictionary[3] = dictionary[1].clone();
            } else {
                let StCollapsedValue::Object { fields, .. } = &mut dictionary[1][0] else {
                    panic!("fixture key")
                };
                fields.push(vec![StCollapsedValue::String("hidden-field".to_owned())]);
            }
            assert!(projection
                .validate_encoded_body(&coder_encode_flattened(&[body]))
                .is_err());
        }
    }

    #[test]
    fn strict_source_comparison_rejects_truncated_trailing_and_oversized_archives() {
        let source = crate::cloud_sync_outbound::attachment_parent_test_support::source();
        let projection = project_parent_attributed_body(&source).unwrap();
        for end in 0..projection.encoded_body.len() {
            assert!(projection
                .validate_encoded_body(&projection.encoded_body[..end])
                .is_err());
        }
        let mut trailing = projection.encoded_body.clone();
        trailing.push(0);
        assert!(projection.validate_encoded_body(&trailing).is_err());
        assert!(projection
            .validate_encoded_body(&vec![0; 1024 * 1024 + 1])
            .is_err());
        assert!(projection.validate_encoded_body(&[0x80, 0x01]).is_err());
    }

    fn decoded_fixture(
        message_guid: &str,
        parts: Vec<DecodedPart>,
        attachment_guids: Vec<String>,
    ) -> DecodedIdsAttachmentSource {
        DecodedIdsAttachmentSource {
            message_guid: message_guid.to_owned(),
            sender: "sender@example.invalid".to_owned(),
            sent_timestamp: 1720000000000,
            send_delivered: true,
            participants: vec![
                "sender@example.invalid".to_owned(),
                "peer@example.invalid".to_owned(),
            ],
            cv_name: None,
            sender_guid: None,
            after_guid: None,
            parts,
            attachment_guids,
            embedded_profile: None,
        }
    }

    fn text_part(text: &str, idx: Option<u64>) -> DecodedPart {
        DecodedPart::Text {
            text: text.to_owned(),
            idx,
        }
    }

    fn attachment_part(
        guid: &str,
        part: u64,
        idx: Option<u64>,
        iris: bool,
        mime: &str,
    ) -> DecodedPart {
        DecodedPart::Attachment(DecodedAttachment {
            guid: guid.to_owned(),
            part,
            uti_type: "public.jpeg".to_owned(),
            mime: mime.to_owned(),
            name: "photo.jpg".to_owned(),
            iris,
            key: vec![7u8; 32],
            signature: vec![9u8; 21],
            object: "object-1".to_owned(),
            url: "https://example.invalid/mmcs/object-1".to_owned(),
            size: 1024,
            idx,
        })
    }

    fn decode_wire(projection: &ParentAttributedProjection) -> NSAttributedString {
        let values = coder_decode_flattened(&projection.encoded_body);
        assert_eq!(values.len(), 1);
        NSAttributedString::decode(&values[0])
    }

    fn message_part_of(dict: &NSDictionaryTypedCoder) -> u32 {
        let raw = dict.0.get(MSG_PART_KEY).expect("messagePart key");
        NSNumber::decode(raw).0
    }

    fn attachment_guid_of(dict: &NSDictionaryTypedCoder) -> String {
        let raw = dict.0.get(ATTACH_GUID_KEY).expect("attachment key");
        NSString::decode(raw).0
    }

    fn assert_cumulative_starts(body: &NSAttributedString, expected: &[u32]) {
        let mut start = 0u32;
        assert_eq!(body.ranges.len(), expected.len());
        for (range, want) in body.ranges.iter().zip(expected) {
            assert_eq!(start, *want);
            start += range.0;
        }
        assert_eq!(start as usize, body.text.encode_utf16().count());
    }

    fn assert_material_parity(decoded: &DecodedIdsAttachmentSource, link: &ParentAttachmentLink) {
        let material = decoded_attachment_upload_material(decoded, &link.original_guid, &TIMES)
            .expect("material helper");
        assert_eq!(material.meta.guid, link.apple_guid);
        assert_eq!(link.canonical_guid, link.local_guid);
        let parsed = parse_owned_attachment_guid(&link.apple_guid).expect("canonical parse");
        assert_eq!(parsed.canonical_guid(), link.canonical_guid.as_str());
        assert_eq!(parsed.message_guid(), decoded.message_guid.as_str());
    }

    #[test]
    fn plain_text_plus_attachment_projects_exact_order_and_links() {
        let decoded = decoded_fixture(
            "MSG-GUID-0001",
            vec![
                text_part("hello", None),
                attachment_part("ATTACH-GUID-0001", 0, Some(1), false, "image/jpeg"),
            ],
            vec!["ATTACH-GUID-0001".to_owned()],
        );
        let projection = project_parent_attributed_body(&decoded).unwrap();
        assert_eq!(projection.text, "hello ");
        assert_eq!(projection.utf16_length, 6);
        assert_eq!(projection.links.len(), 1);
        let link = &projection.links[0];
        assert_eq!(link.original_guid, "ATTACH-GUID-0001");
        assert_eq!(link.apple_guid, "at_1_MSG-GUID-0001");
        assert_eq!(link.local_guid, "MSG-GUID-0001_1");
        assert_eq!(link.canonical_guid, "MSG-GUID-0001_1");
        assert_eq!(link.field_idx, 1);
        assert_eq!((link.start_utf16, link.length_utf16), (5, 1));
        assert_material_parity(&decoded, link);

        let wire = decode_wire(&projection);
        assert_eq!(wire.text, "hello ");
        assert_eq!(wire.ranges.len(), 2);
        assert_eq!(wire.ranges[0].0, 5);
        assert_eq!(wire.ranges[1].0, 1);
        assert_eq!(message_part_of(&wire.ranges[0].1), 0);
        assert_eq!(message_part_of(&wire.ranges[1].1), 1);
        assert_eq!(attachment_guid_of(&wire.ranges[1].1), "at_1_MSG-GUID-0001");
        for key in [BOLD_KEY, ITALIC_KEY, STRIKE_KEY, UNDERLINE_KEY] {
            let raw = wire.ranges[0].1 .0.get(key).expect("flag key");
            assert_eq!(NSNumber::decode(raw).0, 0);
        }
        assert_cumulative_starts(&wire, &[0, 5]);
    }

    #[test]
    fn emoji_mixed_body_preserves_utf16_positions() {
        // Explicit indexes throughout: a trailing default index would
        // first-use field 1 and evict the attachment run (messagePart 1);
        // that counterexample has its own test below.
        let decoded = decoded_fixture(
            "MSG-EMOJI-1",
            vec![
                text_part("A\u{1F600}B", Some(0)),
                attachment_part("ATTACH-EMOJI-1", 0, Some(2), false, "image/jpeg"),
                text_part("tail", Some(3)),
            ],
            vec!["ATTACH-EMOJI-1".to_owned()],
        );
        let projection = project_parent_attributed_body(&decoded).unwrap();
        assert_eq!(projection.text, "A\u{1F600}B tail");
        // "A B" is 4 UTF-16 units, plus 1 placeholder, plus "tail" 4 = 9.
        assert_eq!(projection.utf16_length, 9);
        assert_eq!(projection.links.len(), 1);
        let link = &projection.links[0];
        assert_eq!((link.start_utf16, link.length_utf16), (4, 1));
        assert_eq!(link.apple_guid, "at_2_MSG-EMOJI-1");
        assert_eq!(link.canonical_guid, "MSG-EMOJI-1_2");
        assert_material_parity(&decoded, link);

        let wire = decode_wire(&projection);
        assert_eq!(wire.text, projection.text);
        assert_eq!(wire.ranges.len(), 3);
        assert_eq!(wire.ranges[0].0, 4);
        assert_eq!(wire.ranges[1].0, 1);
        assert_eq!(wire.ranges[2].0, 4);
        assert_eq!(message_part_of(&wire.ranges[0].1), 0);
        assert_eq!(message_part_of(&wire.ranges[2].1), 3);
        assert_eq!(attachment_guid_of(&wire.ranges[1].1), "at_2_MSG-EMOJI-1");
        // Roundtrip derives starts cumulatively: 0, 4, 5.
        assert_cumulative_starts(&wire, &[0, 4, 5]);
    }

    #[test]
    fn trailing_default_text_evicts_attachment_counterexample() {
        // The trailing default field counts one attachment run, first-uses
        // field 1, and evicts the attachment run (messagePart 1).
        let decoded = decoded_fixture(
            "MSG-EMOJI-1",
            vec![
                text_part("A\u{1F600}B", None),
                attachment_part("ATTACH-EMOJI-1", 0, Some(2), false, "image/jpeg"),
                text_part("tail", None),
            ],
            vec!["ATTACH-EMOJI-1".to_owned()],
        );
        assert!(matches!(
            project_parent_attributed_body(&decoded),
            Err(Failure::UnsupportedMessage)
        ));
    }

    #[test]
    fn explicit_and_default_indexes_without_eviction() {
        // Attachment A runs first (run messagePart 0); the middle default
        // text first-uses field 1 where no run sits, and the trailing
        // default attachment reuses field 1 with no eviction.
        let decoded = decoded_fixture(
            "MSG-IDX-1",
            vec![
                attachment_part("ATTACH-A", 0, Some(5), false, "image/jpeg"),
                text_part("n", None),
                attachment_part("ATTACH-B", 1, None, false, "image/png"),
            ],
            vec!["ATTACH-A".to_owned(), "ATTACH-B".to_owned()],
        );
        let projection = project_parent_attributed_body(&decoded).unwrap();
        assert_eq!(projection.text, " n ");
        assert_eq!(projection.utf16_length, 3);
        assert_eq!(projection.links.len(), 2);
        assert_eq!(projection.links[0].original_guid, "ATTACH-A");
        assert_eq!(projection.links[0].apple_guid, "at_5_MSG-IDX-1");
        assert_eq!(projection.links[0].start_utf16, 0);
        assert_eq!(projection.links[1].original_guid, "ATTACH-B");
        assert_eq!(projection.links[1].apple_guid, "at_1_MSG-IDX-1");
        assert_eq!(projection.links[1].canonical_guid, "MSG-IDX-1_1");
        assert_eq!(projection.links[1].start_utf16, 2);
        assert_material_parity(&decoded, &projection.links[0]);
        assert_material_parity(&decoded, &projection.links[1]);

        let wire = decode_wire(&projection);
        assert_eq!(wire.ranges.len(), 3);
        assert_eq!(message_part_of(&wire.ranges[0].1), 0);
        assert_eq!(message_part_of(&wire.ranges[1].1), 1);
        assert_eq!(message_part_of(&wire.ranges[2].1), 2);
        assert_eq!(attachment_guid_of(&wire.ranges[0].1), "at_5_MSG-IDX-1");
        assert_eq!(attachment_guid_of(&wire.ranges[2].1), "at_1_MSG-IDX-1");
        assert_cumulative_starts(&wire, &[0, 1, 2]);
    }

    #[test]
    fn default_second_attachment_evicts_first_counterexample() {
        // The second attachment defaults to field 1, first-uses it, and
        // evicts attachment A's run (messagePart 1).
        let decoded = decoded_fixture(
            "MSG-IDX-1",
            vec![
                text_part("x", Some(3)),
                attachment_part("ATTACH-A", 0, Some(5), false, "image/jpeg"),
                attachment_part("ATTACH-B", 1, None, false, "image/png"),
            ],
            vec!["ATTACH-A".to_owned(), "ATTACH-B".to_owned()],
        );
        assert!(matches!(
            project_parent_attributed_body(&decoded),
            Err(Failure::UnsupportedMessage)
        ));
    }

    #[test]
    fn rejects_ambiguous_duplicate_field_index() {
        let decoded = decoded_fixture(
            "MSG-DUP-1",
            vec![
                attachment_part("ATTACH-A", 0, Some(1), false, "image/jpeg"),
                attachment_part("ATTACH-B", 1, Some(1), false, "image/jpeg"),
            ],
            vec!["ATTACH-A".to_owned(), "ATTACH-B".to_owned()],
        );
        assert!(matches!(
            project_parent_attributed_body(&decoded),
            Err(Failure::BindingMismatch)
        ));
    }

    #[test]
    fn rejects_body_with_no_surviving_attachment_reference() {
        let decoded = decoded_fixture(
            "MSG-IRIS-1",
            vec![attachment_part(
                "ATTACH-IRIS",
                0,
                Some(0),
                true,
                "image/jpeg",
            )],
            vec!["ATTACH-IRIS".to_owned()],
        );
        assert!(matches!(
            project_parent_attributed_body(&decoded),
            Err(Failure::UnsupportedMessage)
        ));
    }

    #[test]
    fn rejects_truly_evicted_attachment_run() {
        // Attachment A owns field 7 but runs at messagePart 0; the later
        // first-use of field 0 evicts its run. A same-valued text index
        // would not evict, because the field is already in the used set.
        let decoded = decoded_fixture(
            "MSG-EVICT-1",
            vec![
                attachment_part("ATTACH-A", 0, Some(7), false, "image/jpeg"),
                text_part("x", Some(0)),
            ],
            vec!["ATTACH-A".to_owned()],
        );
        assert!(matches!(
            project_parent_attributed_body(&decoded),
            Err(Failure::UnsupportedMessage)
        ));
    }

    #[test]
    fn rejects_guid_order_mismatch() {
        let decoded = decoded_fixture(
            "MSG-ORDER-1",
            vec![
                attachment_part("ATTACH-A", 0, Some(1), false, "image/jpeg"),
                attachment_part("ATTACH-B", 1, Some(2), false, "image/jpeg"),
            ],
            vec!["ATTACH-B".to_owned(), "ATTACH-A".to_owned()],
        );
        assert!(matches!(
            project_parent_attributed_body(&decoded),
            Err(Failure::BindingMismatch)
        ));
    }

    #[test]
    fn rejects_oversized_field_index() {
        let decoded = decoded_fixture(
            "MSG-BIG-1",
            vec![
                text_part("hi", None),
                attachment_part(
                    "ATTACH-BIG",
                    0,
                    Some(u32::MAX as u64 + 1),
                    false,
                    "image/jpeg",
                ),
            ],
            vec!["ATTACH-BIG".to_owned()],
        );
        assert!(matches!(
            project_parent_attributed_body(&decoded),
            Err(Failure::OversizedMessage)
        ));
    }

    #[test]
    fn missing_or_overlapping_spans_cannot_shift_wire_offsets() {
        let spans = vec![
            (5u32, 2u32, text_dict(1)),
            (7u32, 1u32, attachment_dict(2, "at_2_MSG-GAP-1")),
        ];
        assert!(matches!(
            contiguous_ranges(spans, 8),
            Err(Failure::MalformedMessage)
        ));
        assert!(matches!(
            contiguous_ranges(vec![(0, 2, text_dict(0)), (1, 1, text_dict(1))], 3),
            Err(Failure::MalformedMessage)
        ));
        assert!(matches!(
            contiguous_ranges(vec![(0, 2, text_dict(0))], 3),
            Err(Failure::MalformedMessage)
        ));
    }

    #[test]
    fn projection_is_semantically_deterministic() {
        // Mapping determinism is semantic: project twice and compare via
        // decode, never raw bytes, since dict key order may vary.
        let decoded = decoded_fixture(
            "MSG-GUID-0001",
            vec![
                text_part("hello", None),
                attachment_part("ATTACH-GUID-0001", 0, Some(1), false, "image/jpeg"),
            ],
            vec!["ATTACH-GUID-0001".to_owned()],
        );
        let first = decode_wire(&project_parent_attributed_body(&decoded).unwrap());
        let second = decode_wire(&project_parent_attributed_body(&decoded).unwrap());
        assert_eq!(first.text, second.text);
        assert_eq!(first.ranges.len(), second.ranges.len());
        for (a, b) in first.ranges.iter().zip(&second.ranges) {
            assert_eq!(a.0, b.0);
            assert_eq!(message_part_of(&a.1), message_part_of(&b.1));
        }
        assert_eq!(
            attachment_guid_of(&first.ranges[1].1),
            attachment_guid_of(&second.ranges[1].1)
        );
    }
}
