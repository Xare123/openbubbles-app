//! Frozen historical body/attachment correspondence. This is source evidence,
//! not an IDS receipt, file-availability claim, or permission to upload.
//! Keep raw text, attributed text and descriptor metadata independently: the
//! display text is not sufficient to reconstruct an attachment-bearing body.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_canonical_dto::parse_owned_attachment_guid;
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use rustpush::{
    coder_encode_flattened, NSAttributedString, NSDictionaryTypedCoder, NSNumber, NSString,
    StCollapsedValue,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

const MAX_BYTES: usize = 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
#[cfg(test)]
const GUID: &str = "__kIMFileTransferGUIDAttributeName";

/// Matches CloudSyncHistoricalMediaSource.toWire. Descriptor XML remains an
/// opaque string inside the inventory's metadata JSON; no lossy re-encoding.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct HistoricalMedia(
    pub(crate) u8,
    pub(crate) u64,
    pub(crate) Option<String>,
    pub(crate) String,
    pub(crate) HistoricalAttachmentInventory,
);

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct HistoricalAttachmentInventory(
    pub(crate) u8,
    pub(crate) Vec<HistoricalAttachmentState>,
);

/// The existing 16-field persisted inventory, not derived file metadata.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct HistoricalAttachmentState(
    pub(crate) u8,             // version
    pub(crate) Option<u64>,    // ObjectBox attachment id
    pub(crate) Option<i64>,    // originalROWID, not owner authority
    pub(crate) Option<String>, // original GUID
    pub(crate) u64,            // ObjectBox message backlink
    pub(crate) Option<String>, // UTI
    pub(crate) Option<String>, // MIME
    pub(crate) Option<bool>,   // stored outgoing flag
    pub(crate) Option<String>, // transfer name
    pub(crate) Option<i64>,    // advertised bytes, not verified length
    pub(crate) Option<i64>,    // height
    pub(crate) Option<i64>,    // width
    pub(crate) Option<String>, // web URL
    pub(crate) bool,           // live photo
    pub(crate) Option<String>, // CloudKit record id
    pub(crate) Option<String>, // canonical metadata JSON containing XML
);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Body {
    string: String,
    runs: Vec<Run>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Run {
    range: (u32, u32),
    attributes: Attributes,
}

/// The plain attributes emitted by AttributedBody.toMap. Unknown or duplicate
/// keys fail rather than disappearing during a lossy map conversion.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Attributes {
    #[serde(rename = "__kIMMessagePartAttributeName")]
    part: u32,
    #[serde(default, rename = "__kIMFileTransferGUIDAttributeName")]
    attachment: Option<String>,
}

impl HistoricalMedia {
    pub(crate) fn validate(&self, message_guid: &str, text: &str) -> Result<(), Failure> {
        self.validated_bodies(message_guid, text).map(|_| ())
    }

    fn validated_bodies(&self, message_guid: &str, text: &str) -> Result<Vec<Body>, Failure> {
        if self.0 != 1 || self.1 == 0 || self.4 .0 != 1 {
            return Err(Failure::MalformedMessage);
        }
        if self.2.as_deref().unwrap_or("") != text {
            return Err(Failure::BindingMismatch);
        }
        if text.contains('\0') || text.len() > MAX_TEXT_BYTES {
            return Err(Failure::MalformedMessage);
        }
        if self.3.len() > MAX_BYTES
            || serde_json::to_vec(self)
                .map_err(|_| Failure::MalformedMessage)?
                .len()
                > MAX_BYTES
        {
            return Err(Failure::OversizedMessage);
        }
        let entries = &self.4 .1;
        if entries.is_empty() || entries.len() > 64 {
            return Err(Failure::MalformedMessage);
        }
        let mut ids = HashSet::new();
        let mut inventory_guids = HashSet::new();
        for entry in entries {
            if entry.0 != 1
                || entry.1.is_none_or(|id| id == 0 || !ids.insert(id))
                || entry.4 != self.1
            {
                return Err(Failure::BindingMismatch);
            }
            let guid = entry.3.as_deref().ok_or(Failure::MalformedMessage)?;
            if !inventory_guids.insert(apple_guid(guid, message_guid)?) {
                return Err(Failure::BindingMismatch);
            }
            if let Some(metadata) = &entry.15 {
                let parsed: serde_json::Value =
                    serde_json::from_str(metadata).map_err(|_| Failure::MalformedMessage)?;
                if !parsed.is_object() {
                    return Err(Failure::MalformedMessage);
                }
            }
        }
        let bodies: Vec<Body> =
            serde_json::from_str(&self.3).map_err(|_| Failure::MalformedMessage)?;
        if bodies.is_empty() || bodies.len() > 16 {
            return Err(Failure::MalformedMessage);
        }
        let mut linked = HashSet::new();
        let mut run_count = 0;
        for body in &bodies {
            if body.string.is_empty()
                || body.string.contains('\0')
                || body.string.len() > MAX_TEXT_BYTES
                || body.runs.is_empty()
            {
                return Err(Failure::MalformedMessage);
            }
            let utf16: Vec<u16> = body.string.encode_utf16().collect();
            let mut offset = 0usize;
            for run in &body.runs {
                run_count += 1;
                if run_count > 128 {
                    return Err(Failure::OversizedMessage);
                }
                let (start, length) = (run.range.0 as usize, run.range.1 as usize);
                let end = start.checked_add(length).ok_or(Failure::MalformedMessage)?;
                if start != offset
                    || length == 0
                    || end > utf16.len()
                    || !utf16_boundary(&utf16, start)
                    || !utf16_boundary(&utf16, end)
                {
                    return Err(Failure::MalformedMessage);
                }
                offset = end;
                if let Some(reference) = run.attributes.attachment.as_deref() {
                    if length != 1 || !matches!(utf16[start], 0x20 | 0xfffc) {
                        return Err(Failure::MalformedMessage);
                    }
                    let canonical = apple_guid(reference, message_guid)?;
                    // Reflected GUID suffix and run messagePart can differ.
                    // The exact backlink/reference pair proves correspondence.
                    if !inventory_guids.contains(&canonical) || !linked.insert(canonical) {
                        return Err(Failure::BindingMismatch);
                    }
                } else if utf16[start..end].contains(&0xfffc) {
                    return Err(Failure::BindingMismatch);
                }
            }
            if offset != utf16.len() {
                return Err(Failure::MalformedMessage);
            }
        }
        if linked != inventory_guids {
            return Err(Failure::BindingMismatch);
        }
        Ok(bodies)
    }

    /// Match legacy encodeAttributedBody's list/range grammar using only the
    /// frozen supported attributes. No current-row lookup, new part indexes,
    /// missing formatting defaults, IDS reflection, or attachment reminting.
    pub(crate) fn project_attributed_body(
        &self,
        message_guid: &str,
        text: &str,
    ) -> Result<HistoricalAttributedProjection, Failure> {
        let bodies = self.validated_bodies(message_guid, text)?;
        let text = bodies[0].string.clone();
        let mut values = Vec::with_capacity(bodies.len());
        let mut attachment_guids = Vec::with_capacity(self.4 .1.len());
        for body in bodies {
            let mut ranges = Vec::with_capacity(body.runs.len());
            for run in body.runs {
                let mut attributes = HashMap::from_iter([(
                    "__kIMMessagePartAttributeName".to_owned(),
                    NSNumber(run.attributes.part).encode(),
                )]);
                if let Some(guid) = run.attributes.attachment {
                    let canonical = apple_guid(&guid, message_guid)?;
                    attributes.insert(
                        "__kIMFileTransferGUIDAttributeName".to_owned(),
                        NSString(canonical.clone()).encode(),
                    );
                    attachment_guids.push(canonical);
                }
                ranges.push((run.range.1, NSDictionaryTypedCoder(attributes)));
            }
            values.push(
                NSAttributedString {
                    text: body.string,
                    ranges,
                }
                .encode(),
            );
        }
        let encoded_body = coder_encode_flattened(&values);
        if encoded_body.is_empty() || encoded_body.len() > MAX_BYTES {
            return Err(Failure::OversizedMessage);
        }
        Ok(HistoricalAttributedProjection {
            text,
            encoded_body,
            attachment_guids,
            values,
        })
    }
}

/// Material only. The parent must still wait for every exact child readback
/// and retain the original staged bytes. Dictionary ordering may vary between
/// equivalent projections, so reopening compares through the bounded AST.
pub(crate) struct HistoricalAttributedProjection {
    pub(crate) text: String,
    pub(crate) encoded_body: Vec<u8>,
    pub(crate) attachment_guids: Vec<String>,
    values: Vec<StCollapsedValue>,
}

impl HistoricalAttributedProjection {
    pub(crate) fn validate_encoded_body(&self, encoded: &[u8]) -> Result<(), Failure> {
        crate::cloud_sync_canonical_converter::validate_source_projected_attributed_bodies(
            encoded,
            &self.values,
        )
        .map_err(|_| Failure::BindingMismatch)
    }
}

fn utf16_boundary(units: &[u16], index: usize) -> bool {
    index == 0
        || index == units.len()
        || !((0xd800..=0xdbff).contains(&units[index - 1])
            && (0xdc00..=0xdfff).contains(&units[index]))
}

/// Preserve standalone GUIDs. Validate embedded owners without inventing one.
pub(crate) fn apple_guid(guid: &str, message_guid: &str) -> Result<String, Failure> {
    if guid.is_empty() || guid.len() > 4096 || guid.chars().any(char::is_control) {
        return Err(Failure::MalformedMessage);
    }
    let canonical = if guid.starts_with("at_") {
        guid.to_owned()
    } else if let Some((owner, part)) = guid.rsplit_once('_').filter(|(_, part)| {
        !part.is_empty()
            && part.bytes().all(|byte| byte.is_ascii_digit())
            && (*part == "0" || !part.starts_with('0'))
    }) {
        format!("at_{part}_{owner}")
    } else {
        return Ok(guid.to_owned());
    };
    let parsed = parse_owned_attachment_guid(&canonical).map_err(|_| Failure::MalformedMessage)?;
    if parsed.message_guid() != message_guid {
        return Err(Failure::BindingMismatch);
    }
    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_historical_source::{HistoricalArchiveSource, HistoricalBinding};

    fn fixture(index: usize) -> (serde_json::Value, HistoricalMedia) {
        let vectors: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/cloud_sync/historical_source_v4.json"
        ))
        .unwrap();
        let payload: serde_json::Value =
            serde_json::from_str(vectors[index]["canonicalPayload"].as_str().unwrap()).unwrap();
        let media = serde_json::from_value(payload["media"].clone()).unwrap();
        (payload, media)
    }

    fn check(payload: &serde_json::Value, media: &HistoricalMedia) -> Result<(), Failure> {
        media.validate(
            payload["guid"].as_str().unwrap(),
            payload["text"].as_str().unwrap(),
        )
    }

    fn project(
        payload: &serde_json::Value,
        media: &HistoricalMedia,
    ) -> HistoricalAttributedProjection {
        media
            .project_attributed_body(
                payload["guid"].as_str().unwrap(),
                payload["text"].as_str().unwrap(),
            )
            .unwrap()
    }

    #[test]
    fn projection_preserves_original_text_utf16_parts_and_reference_order() {
        for index in [0, 1] {
            let (payload, media) = fixture(index);
            let projection = project(&payload, &media);
            let decoded = rustpush::coder_decode_flattened(&projection.encoded_body);
            assert_eq!(decoded.len(), 1);
            let body = NSAttributedString::decode(&decoded[0]);
            let original: serde_json::Value = serde_json::from_str(&media.3).unwrap();
            assert_eq!(body.text, original[0]["string"].as_str().unwrap());
            assert_eq!(projection.text, body.text);
            assert_eq!(
                body.ranges.iter().map(|value| value.0).sum::<u32>(),
                body.text.encode_utf16().count() as u32
            );
            for (range, expected) in body
                .ranges
                .iter()
                .zip(original[0]["runs"].as_array().unwrap())
            {
                assert_eq!(range.0, expected["range"][1].as_u64().unwrap() as u32);
                assert_eq!(
                    NSNumber::decode(&range.1 .0["__kIMMessagePartAttributeName"]).0,
                    expected["attributes"]["__kIMMessagePartAttributeName"]
                        .as_u64()
                        .unwrap() as u32
                );
                assert_eq!(
                    range.1 .0.len(),
                    expected["attributes"].as_object().unwrap().len()
                );
            }
            projection
                .validate_encoded_body(&projection.encoded_body)
                .unwrap();
            let suffixes = if index == 0 { vec![2] } else { vec![1, 5] };
            assert_eq!(
                projection.attachment_guids,
                suffixes
                    .into_iter()
                    .map(|part| format!("at_{part}_{}", payload["guid"].as_str().unwrap()))
                    .collect::<Vec<_>>()
            );
            if index == 0 {
                assert_eq!(media.2, None);
                assert_eq!(projection.text, " ");
            } else {
                assert_ne!(projection.text, media.2.clone().unwrap());
                assert_eq!(body.ranges[0].0, 11); // emoji takes two UTF-16 units
            }
        }
    }

    #[test]
    fn separate_bodies_are_not_flattened_or_partly_validated() {
        let (payload, mut media) = fixture(1);
        let owner = payload["guid"].as_str().unwrap();
        media.3 = serde_json::json!([
            {"string":"Caption 😀", "runs":[{"range":[0,10],
                "attributes":{"__kIMMessagePartAttributeName":0}}]},
            {"string":" ", "runs":[{"range":[0,1],"attributes":{
                "__kIMMessagePartAttributeName":4,"__kIMFileTransferGUIDAttributeName":format!("{owner}_1")}}]},
            {"string":"\u{fffc}", "runs":[{"range":[0,1],"attributes":{
                "__kIMMessagePartAttributeName":7,"__kIMFileTransferGUIDAttributeName":format!("{owner}_5")}}]}
        ]).to_string();
        let projection = project(&payload, &media);
        assert_eq!(projection.text, "Caption 😀");
        let decoded = rustpush::coder_decode_flattened(&projection.encoded_body);
        assert_eq!(decoded.len(), 3);
        assert_eq!(NSAttributedString::decode(&decoded[1]).text, " ");
        assert_eq!(NSAttributedString::decode(&decoded[2]).text, "\u{fffc}");
        projection
            .validate_encoded_body(&projection.encoded_body)
            .unwrap();
        let mut reversed = projection.values.clone();
        reversed.swap(1, 2);
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&reversed))
            .is_err());
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&projection.values[..1]))
            .is_err());
        let mut changed = NSAttributedString::decode(&projection.values[2]);
        changed.ranges[0]
            .1
             .0
            .insert("__kIMMessagePartAttributeName".into(), NSNumber(8).encode());
        let mut wrong_part = projection.values.clone();
        wrong_part[2] = changed.encode();
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&wrong_part))
            .is_err());
    }

    #[test]
    fn projection_reopen_accepts_dictionary_order_but_rejects_extra_or_malformed_content() {
        let (payload, media) = fixture(1);
        let projection = project(&payload, &media);
        // Independent projection may have a different HashMap serialization order.
        projection
            .validate_encoded_body(&project(&payload, &media).encoded_body)
            .unwrap();
        for raw in [
            &[][..],
            &[1, 2, 3][..],
            &projection.encoded_body[..projection.encoded_body.len() - 1],
        ] {
            assert!(projection.validate_encoded_body(raw).is_err());
        }
        let mut body = NSAttributedString::decode(&projection.values[0]);
        body.ranges[0]
            .1
             .0
            .insert("__kIMTextBoldAttributeName".into(), NSNumber(1).encode());
        assert!(projection
            .validate_encoded_body(&coder_encode_flattened(&[body.encode()]))
            .is_err());
        assert!(projection
            .validate_encoded_body(&vec![0; MAX_BYTES + 1])
            .is_err());
    }

    #[test]
    fn null_text_and_unicode_multipart_layout_validate_without_reconstructing_captions() {
        for index in [0, 1] {
            let (payload, media) = fixture(index);
            assert!(check(&payload, &media).is_ok());
        }
    }

    #[test]
    fn incorrect_backlink_and_duplicate_inventory_identity_reject() {
        let (payload, media) = fixture(1);
        let mut wrong = media.clone();
        wrong.4 .1[0].4 += 1;
        assert!(check(&payload, &wrong).is_err());
        let mut duplicate = media.clone();
        duplicate.4 .1[1].1 = duplicate.4 .1[0].1;
        assert!(check(&payload, &duplicate).is_err());
        let mut duplicate = media;
        duplicate.4 .1[1].3 = duplicate.4 .1[0].3.clone();
        assert!(check(&payload, &duplicate).is_err());
    }

    #[test]
    fn ranges_must_cover_utf16_without_splitting_a_surrogate_pair() {
        let (payload, media) = fixture(1);
        for range in [
            serde_json::json!([1, 10]),
            serde_json::json!([0, 9]),
            serde_json::json!([0, 0]),
            serde_json::json!([0, 100]),
            serde_json::json!([0, -1]),
        ] {
            let mut wrong = media.clone();
            let mut bodies: serde_json::Value = serde_json::from_str(&wrong.3).unwrap();
            bodies[0]["runs"][0]["range"] = range;
            wrong.3 = serde_json::to_string(&bodies).unwrap();
            assert!(check(&payload, &wrong).is_err());
        }
    }

    #[test]
    fn each_media_reference_requires_one_exact_owned_inventory_entry() {
        let (payload, media) = fixture(1);
        for reference in [
            "at_1_wrong-owner",
            "missing-standalone",
            "at_01_invalid",
            "at_5_A1B2C3D4-E5F6-4A7B-8C9D-E0F1A2B3C4D5",
        ] {
            let mut wrong = media.clone();
            let mut bodies: serde_json::Value = serde_json::from_str(&wrong.3).unwrap();
            bodies[0]["runs"][1]["attributes"][GUID] = serde_json::json!(reference);
            wrong.3 = serde_json::to_string(&bodies).unwrap();
            assert!(check(&payload, &wrong).is_err());
        }
        let mut wrong = media;
        wrong.4 .1.pop();
        assert!(check(&payload, &wrong).is_err());
    }

    #[test]
    fn text_drift_rich_attributes_and_unmarked_placeholders_reject() {
        let (payload, media) = fixture(1);
        let mut wrong = media.clone();
        wrong.2 = Some("changed text".into());
        assert!(check(&payload, &wrong).is_err());
        for (key, value) in [
            ("sticker", serde_json::json!({})),
            ("__kIMTextBoldAttributeName", serde_json::json!(1)),
            ("__kIMMentionConfirmedMention", serde_json::json!("someone")),
        ] {
            let mut wrong = media.clone();
            let mut bodies: serde_json::Value = serde_json::from_str(&wrong.3).unwrap();
            bodies[0]["runs"][0]["attributes"][key] = value;
            wrong.3 = serde_json::to_string(&bodies).unwrap();
            assert!(check(&payload, &wrong).is_err());
        }
        let mut wrong = media;
        let mut bodies: serde_json::Value = serde_json::from_str(&wrong.3).unwrap();
        bodies[0]["runs"][1]["attributes"]
            .as_object_mut()
            .unwrap()
            .remove(GUID);
        wrong.3 = serde_json::to_string(&bodies).unwrap();
        assert!(check(&payload, &wrong).is_err());
    }

    #[test]
    fn guid_aliases_preserve_underscores_and_never_invent_standalone_owners() {
        assert_eq!(
            apple_guid("owner_with_parts_2", "owner_with_parts").unwrap(),
            "at_2_owner_with_parts"
        );
        assert_eq!(
            apple_guid("at_2_owner_with_parts", "owner_with_parts").unwrap(),
            "at_2_owner_with_parts"
        );
        assert_eq!(
            apple_guid("standalone-guid", "owner").unwrap(),
            "standalone-guid"
        );
        assert!(apple_guid("other_owner_2", "owner").is_err());
    }

    #[test]
    fn altered_media_descriptor_cannot_reopen_under_the_original_source_digest() {
        let vectors: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/cloud_sync/historical_source_v4.json"
        ))
        .unwrap();
        let bytes = vectors[0]["canonicalPayload"].as_str().unwrap().as_bytes();
        let binding = HistoricalBinding {
            snapshot_sha256: "ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34",
            account_fingerprint: "account-fp-xyz789",
            protected_store_identity: "store-1",
        };
        let expected = vectors[0]["sourceSha256"].as_str().unwrap();
        assert!(HistoricalArchiveSource::decode(bytes, &binding, expected).is_ok());
        // Use a valid canonical source with different retained metadata, rather
        // than merely producing malformed bytes that would fail before hashing.
        let (payload, mut media) = fixture(0);
        media.4 .1[0].8 = Some("different-photo.jpg".into());
        let changed = HistoricalArchiveSource::capture_with_media(
            &crate::cloud_sync_historical_source::HistoricalRow {
                guid: payload["guid"].as_str().unwrap(),
                text: "",
                sender: "friend@example.com",
                peer: "friend@example.com",
                chat_guid: "iMessage;-;friend@example.com",
                date_created_ms: 1_699_000_000_000,
                is_from_me: false,
            },
            &binding,
            false,
            None,
            None,
            Some(media),
        )
        .unwrap();
        assert_ne!(changed.source_sha256().unwrap(), expected);
        assert!(
            HistoricalArchiveSource::decode(&changed.encode().unwrap(), &binding, expected)
                .is_err()
        );
    }

    #[test]
    fn duplicated_body_attribute_is_not_silently_overwritten() {
        let (payload, mut media) = fixture(0);
        media.3 = media.3.replace(
            "\"__kIMMessagePartAttributeName\":7",
            "\"__kIMMessagePartAttributeName\":6,\"__kIMMessagePartAttributeName\":7",
        );
        assert!(check(&payload, &media).is_err());
    }

    #[test]
    fn media_source_cannot_fall_through_to_plain_text_parent_creation() {
        let vectors: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/cloud_sync/historical_source_v4.json"
        ))
        .unwrap();
        for vector in vectors {
            let source = HistoricalArchiveSource::decode(
                vector["canonicalPayload"].as_str().unwrap().as_bytes(),
                &HistoricalBinding {
                    snapshot_sha256:
                        "ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34",
                    account_fingerprint: "account-fp-xyz789",
                    protected_store_identity: "store-1",
                },
                vector["sourceSha256"].as_str().unwrap(),
            )
            .unwrap();
            let parent = crate::cloud_sync_historical_projection::tests::chat(
                "friend@example.com",
                crate::cloud_sync_canonical_dto::CloudCanonicalChatStyle::Direct,
            );
            assert!(matches!(
                crate::cloud_sync_historical_projection::project_historical_plain_text(
                    &source, &parent
                ),
                Err(Failure::UnsupportedMessage)
            ));
        }
    }
}
