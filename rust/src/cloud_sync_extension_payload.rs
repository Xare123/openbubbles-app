//! Native-only, bounded extension metadata decoder for canonical projection.
//!
//! Integration contract: pass the already-decompressed msgProto.payloadData and
//! its validated balloon bundle ID. Do NOT gzip it for the legacy from_bp API.
//! Success supplies only the fields consumed by rustpush_service.appToData;
//! it is not a record-admission decision or proof of complete message restoration.
//! The parent must bind identity/presence, retain the original protected record,
//! project this metadata atomically with the message, and defer on every error.
//! No raw archive, live-layout blob, class metadata, or authentication material
//! is returned. Strings (including app URLs) are untrusted display data: never
//! log them, execute them, or treat them as fetch/authentication instructions.
//!
//! Supported: binary NSKeyedArchiver NSDictionary/NSMutableDictionary balloons,
//! optional MSMessageTemplateLayout, NSURL, NSUUID, NSData/NSMutableData.
//! Ordinary unknown metadata fields are budgeted and omitted from the output,
//! not removed from protected source. Required layouts/classes stay fail-closed.
//! Live-layout bytes only determine is_live, matching the existing renderer;
//! this does not implement an extension's interactive/live behavior.
//!
//! Limits are per call, not empirically qualified against the seven retained
//! records: 1 MiB primary; 4,096 archive objects; 16,384 visits and 4 MiB of
//! logical scalar/key bytes per preflight; depth < 32; 16 KiB/string;
//! 1 KiB bundle ID; 256 KiB compressed / 1 MiB decompressed icon; 64 KiB live
//! marker. The graph budget also charges unreachable objects and repeated UID
//! occurrences. These are work/expansion bounds, not an exact heap/RSS cap.
//! JSON v1 is a closed, fully populated schema (nullable fields are explicit),
//! with snake_case names, icon as a u8 JSON array, and app_id <= i64::MAX.
//! Only serialize_generated_metadata_json / parse_generated_metadata_json are
//! validated bridge boundaries; deriving Deserialize alone does not validate.

use std::{
    collections::BTreeSet,
    fmt,
    io::{Cursor, Read},
};

use flate2::bufread::GzDecoder;
use plist::{
    stream::{Event, Reader},
    Dictionary, Value,
};
use rustpush::{BalloonLayout, KeyedArchive, NSURL};
use serde::{de, Deserialize, Deserializer, Serialize};

pub const MAX_PAYLOAD_BYTES: usize = 1024 * 1024;
pub const MAX_ARCHIVE_OBJECTS: usize = 4096;
pub const MAX_VISITED_NODES: usize = 16_384;
pub const MAX_DEPTH: usize = 32;
pub const MAX_EXPANDED_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_STRING_BYTES: usize = 16 * 1024;
pub const MAX_BUNDLE_ID_BYTES: usize = 1024;
pub const MAX_COMPRESSED_ICON_BYTES: usize = 256 * 1024;
pub const MAX_ICON_BYTES: usize = 1024 * 1024;
pub const MAX_LIVE_LAYOUT_BYTES: usize = 64 * 1024;
pub const MAX_JSON_BYTES: usize = 8 * 1024 * 1024;

/// Fixed, content-free failures. Callers must retain/defer, not discard content.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExtensionPayloadFailure {
    Malformed,
    UnsupportedEncoding,
    UnsupportedContent,
    LimitExceeded,
    CyclicArchive,
    InvalidIcon,
}

type Failure = ExtensionPayloadFailure;
type Result<T> = std::result::Result<T, Failure>;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExtensionPayloadMetadata {
    pub name: String,
    #[serde(deserialize_with = "required_option")]
    pub app_id: Option<u64>,
    pub bundle_id: String,
    pub balloon: ExtensionBalloonMetadata,
}

// Deliberately no derived Debug on content-bearing metadata or nested structs.
impl fmt::Debug for ExtensionPayloadMetadata {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ExtensionPayloadMetadata([redacted])")
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExtensionBalloonMetadata {
    pub url: String,
    #[serde(deserialize_with = "required_option")]
    pub session: Option<String>,
    #[serde(deserialize_with = "required_option")]
    pub ld_text: Option<String>,
    pub is_live: bool,
    /// Bounded decompressed bytes, not a decoded raster or remote reference.
    #[serde(deserialize_with = "json_icon")]
    pub icon: Option<Vec<u8>>,
    #[serde(deserialize_with = "required_option")]
    pub layout: Option<ExtensionTemplateMetadata>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExtensionTemplateMetadata {
    pub image_subtitle: String,
    pub image_title: String,
    pub caption: String,
    pub secondary_subcaption: String,
    pub tertiary_subcaption: String,
    pub subcaption: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MetadataEnvelope<T> {
    version: u8,
    metadata: T,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ExtensionSessionRole {
    Base,
    Update,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExtensionSessionContext {
    pub role: ExtensionSessionRole,
    pub session_guid: String,
    pub session_logical_key_hash: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionMetadataEnvelope<T, C> {
    version: u8,
    metadata: T,
    context: C,
}

pub(crate) fn validate_session_context(context: &ExtensionSessionContext) -> Result<()> {
    let guid = &context.session_guid;
    if guid.is_empty()
        || guid.len() > MAX_STRING_BYTES
        || guid.chars().any(|c| c.is_control() || c == ':' || c == '/')
        || context.session_logical_key_hash.len() != 43
        || !context
            .session_logical_key_hash
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(Failure::Malformed);
    }
    Ok(())
}

pub(crate) fn serialize_session_metadata_json(
    metadata: &ExtensionPayloadMetadata,
    context: &ExtensionSessionContext,
) -> Result<Vec<u8>> {
    validate_metadata(metadata)?;
    validate_session_context(context)?;
    let bytes = serde_json::to_vec(&SessionMetadataEnvelope {
        version: 2,
        metadata,
        context,
    })
    .map_err(|_| Failure::Malformed)?;
    if bytes.len() > MAX_JSON_BYTES {
        return Err(Failure::LimitExceeded);
    }
    Ok(bytes)
}

/// Both schemas are closed; a v1 payload cannot smuggle a context, including null.
pub(crate) fn parse_projection_metadata_json(
    bytes: &[u8],
) -> Result<(ExtensionPayloadMetadata, Option<ExtensionSessionContext>)> {
    if bytes.len() > MAX_JSON_BYTES {
        return Err(Failure::LimitExceeded);
    }
    if let Ok(envelope) =
        serde_json::from_slice::<MetadataEnvelope<ExtensionPayloadMetadata>>(bytes)
    {
        if envelope.version != 1 {
            return Err(Failure::UnsupportedEncoding);
        }
        validate_metadata(&envelope.metadata)?;
        return Ok((envelope.metadata, None));
    }
    let envelope: SessionMetadataEnvelope<ExtensionPayloadMetadata, ExtensionSessionContext> =
        serde_json::from_slice(bytes).map_err(|_| Failure::Malformed)?;
    if envelope.version != 2 {
        return Err(Failure::UnsupportedEncoding);
    }
    validate_metadata(&envelope.metadata)?;
    validate_session_context(&envelope.context)?;
    Ok((envelope.metadata, Some(envelope.context)))
}

// deserialize_with deliberately makes absent Option fields errors, not nulls.
fn required_option<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    d: D,
) -> std::result::Result<Option<T>, D::Error> {
    Option::<T>::deserialize(d)
}

fn json_icon<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Option<Vec<u8>>, D::Error> {
    struct Icon(Vec<u8>);
    impl<'de> Deserialize<'de> for Icon {
        fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
            struct Visitor;
            impl<'de> de::Visitor<'de> for Visitor {
                type Value = Icon;
                fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    f.write_str("bounded icon byte array")
                }
                fn visit_seq<A: de::SeqAccess<'de>>(
                    self,
                    mut a: A,
                ) -> std::result::Result<Icon, A::Error> {
                    let mut bytes = Vec::new();
                    while let Some(byte) = a.next_element::<u8>()? {
                        if bytes.len() == MAX_ICON_BYTES {
                            return Err(de::Error::custom("icon limit"));
                        }
                        bytes.push(byte);
                    }
                    Ok(Icon(bytes))
                }
            }
            d.deserialize_seq(Visitor)
        }
    }
    Ok(Option::<Icon>::deserialize(d)?.map(|icon| icon.0))
}

fn validate_metadata(metadata: &ExtensionPayloadMetadata) -> Result<()> {
    let balloon = &metadata.balloon;
    validate_bundle_id(&metadata.bundle_id)?;
    if metadata.app_id.is_some_and(|id| id > i64::MAX as u64)
        || balloon
            .icon
            .as_ref()
            .is_some_and(|icon| icon.len() > MAX_ICON_BYTES)
    {
        return Err(Failure::LimitExceeded);
    }
    let mut strings = vec![metadata.name.as_str(), balloon.url.as_str()];
    strings.extend(balloon.ld_text.as_deref());
    if let Some(layout) = &balloon.layout {
        strings.extend([
            layout.image_subtitle.as_str(),
            &layout.image_title,
            &layout.caption,
            &layout.secondary_subcaption,
            &layout.tertiary_subcaption,
            &layout.subcaption,
        ]);
    }
    if strings.iter().any(|s| s.len() > MAX_STRING_BYTES) {
        return Err(Failure::LimitExceeded);
    }
    if let Some(session) = &balloon.session {
        if session.len() != 36 || uuid::Uuid::parse_str(session).is_err() {
            return Err(Failure::Malformed);
        }
    }
    Ok(())
}

/// Deterministic compact JSON, declaration-order keys, explicit nulls. No raw
/// archive fields. Per-field validation bounds serialization before allocation.
pub fn serialize_generated_metadata_json(metadata: &ExtensionPayloadMetadata) -> Result<Vec<u8>> {
    validate_metadata(metadata)?;
    let bytes = serde_json::to_vec(&MetadataEnvelope {
        version: 1,
        metadata,
    })
    .map_err(|_| Failure::Malformed)?;
    if bytes.len() > MAX_JSON_BYTES {
        return Err(Failure::LimitExceeded);
    }
    Ok(bytes)
}

/// Validates the closed v1 schema, duplicate/missing fields, types and limits.
/// Accepts JSON whitespace/key ordering. Preserve the validated input bytes
/// for the cross-boundary content digest; do not parse and reserialize there.
pub fn parse_generated_metadata_json(bytes: &[u8]) -> Result<ExtensionPayloadMetadata> {
    if bytes.len() > MAX_JSON_BYTES {
        return Err(Failure::LimitExceeded);
    }
    let envelope: MetadataEnvelope<ExtensionPayloadMetadata> =
        serde_json::from_slice(bytes).map_err(|_| Failure::Malformed)?;
    if envelope.version != 1 {
        return Err(Failure::UnsupportedEncoding);
    }
    validate_metadata(&envelope.metadata)?;
    Ok(envelope.metadata)
}

fn validate_bundle_id(bundle_id: &str) -> Result<()> {
    if bundle_id.len() > MAX_BUNDLE_ID_BYTES {
        return Err(Failure::LimitExceeded);
    }
    if bundle_id.is_empty() || bundle_id.chars().any(char::is_control) {
        return Err(Failure::Malformed);
    }
    Ok(())
}

/// Pure in-memory decoding. No IO except bounded reads from the supplied bytes.
pub fn decode_extension_payload(
    payload: &[u8],
    bundle_id: &str,
) -> Result<ExtensionPayloadMetadata> {
    let result = decode_extension_payload_inner(payload, bundle_id);
    if let Err(failure) = &result {
        log::debug!(target: "rust_lib_bluebubbles::cloud_sync_transient_bridge",
            "CloudKit V2 extension metadata decode failed reason={failure:?}");
    }
    result
}

fn decode_extension_payload_inner(
    payload: &[u8],
    bundle_id: &str,
) -> Result<ExtensionPayloadMetadata> {
    validate_bundle_id(bundle_id)?;
    validate_binary(payload)?;
    let archive = Value::from_reader(Cursor::new(payload)).map_err(|_| Failure::Malformed)?;
    validate_archive(&archive)?;
    // Use expand, not expand_root's missing-root unwrap. The preflight covers
    // expand_key's indexes, recursive clones, and expand_dict's length expect.
    let mut expanded = KeyedArchive::expand(payload).map_err(|_| Failure::Malformed)?;
    let root = expanded.remove("root").ok_or(Failure::Malformed)?;
    let metadata = project(&root, bundle_id)?;
    validate_metadata(&metadata)?;
    Ok(metadata)
}

fn dictionary(value: &Value) -> Result<&Dictionary> {
    value.as_dictionary().ok_or(Failure::Malformed)
}

fn required<'a>(dict: &'a Dictionary, key: &str) -> Result<&'a Value> {
    dict.get(key).ok_or(Failure::Malformed)
}

fn text(value: &Value) -> Result<&str> {
    let text = value.as_string().ok_or(Failure::Malformed)?;
    if text.len() > MAX_STRING_BYTES {
        return Err(Failure::LimitExceeded);
    }
    Ok(text)
}

fn fields(dict: &Dictionary, allowed: &[&str]) -> Result<()> {
    if dict.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(Failure::UnsupportedContent);
    }
    Ok(())
}

fn class_is(dict: &Dictionary, allowed: &[&str]) -> Result<()> {
    if !allowed.contains(&text(required(dict, "$class")?)?) {
        return Err(Failure::UnsupportedContent);
    }
    Ok(())
}

fn data(value: &Value) -> Result<&[u8]> {
    let dict = dictionary(value)?;
    fields(dict, &["$class", "NS.data"])?;
    class_is(dict, &["NSData", "NSMutableData"])?;
    required(dict, "NS.data")?
        .as_data()
        .ok_or(Failure::Malformed)
}

fn project(root: &Value, bundle_id: &str) -> Result<ExtensionPayloadMetadata> {
    let dict = dictionary(root)?;
    class_is(dict, &["NSDictionary", "NSMutableDictionary"])?;
    // Ordinary extra app/userInfo fields are ignored like legacy serde. The
    // graph preflight budgets them and protected source remains untouched.
    let name = text(required(dict, "an")?)?.to_owned();
    let app_id = dict
        .get("appid")
        .map(|v| v.as_unsigned_integer().ok_or(Failure::Malformed))
        .transpose()?;
    let raw_url = required(dict, "URL")?;
    let url_dict = dictionary(raw_url)?;
    fields(url_dict, &["$class", "NS.base", "NS.relative"])?;
    class_is(url_dict, &["NSURL"])?;
    text(required(url_dict, "NS.base")?)?;
    text(required(url_dict, "NS.relative")?)?;
    let url: NSURL = plist::from_value(raw_url).map_err(|_| Failure::Malformed)?;
    let url: String = url.into();
    if url.len() > MAX_STRING_BYTES {
        return Err(Failure::LimitExceeded);
    }
    let session = dict
        .get("sessionIdentifier")
        .map(|v| -> Result<String> {
            let d = dictionary(v)?;
            fields(d, &["$class", "NS.uuidbytes"])?;
            class_is(d, &["NSUUID"])?;
            let bytes = required(d, "NS.uuidbytes")?
                .as_data()
                .ok_or(Failure::Malformed)?;
            // NSUUID::into uses try_into().unwrap(); use the fallible UUID API.
            Ok(uuid::Uuid::from_slice(bytes)
                .map_err(|_| Failure::Malformed)?
                .to_string())
        })
        .transpose()?;
    let ld_text = dict
        .get("ldtext")
        .map(|v| text(v).map(str::to_owned))
        .transpose()?;
    let is_live = if let Some(live) = dict.get("liveLayoutInfo") {
        if data(live)?.len() > MAX_LIVE_LAYOUT_BYTES {
            return Err(Failure::LimitExceeded);
        }
        true
    } else {
        false
    };
    let icon = dict.get("ai").map(|v| decode_icon(data(v)?)).transpose()?;
    let layout = match (dict.get("layoutClass"), dict.get("userInfo")) {
        (None, None) => None,
        (Some(kind), Some(info)) => {
            if text(kind)? != "MSMessageTemplateLayout" {
                return Err(Failure::UnsupportedContent);
            }
            let info = dictionary(info)?;
            class_is(info, &["NSDictionary", "NSMutableDictionary"])?;
            // Reuse the exact existing serde layout field contract.
            let layout: BalloonLayout = plist::from_value(root).map_err(|_| Failure::Malformed)?;
            let BalloonLayout::TemplateLayout {
                image_subtitle,
                image_title,
                caption,
                secondary_subcaption,
                tertiary_subcaption,
                subcaption,
                ..
            } = layout;
            Some(ExtensionTemplateMetadata {
                image_subtitle,
                image_title,
                caption,
                secondary_subcaption,
                tertiary_subcaption,
                subcaption,
            })
        }
        (Some(kind), None) if text(kind)? != "MSMessageTemplateLayout" => {
            return Err(Failure::UnsupportedContent)
        }
        _ => return Err(Failure::Malformed),
    };
    Ok(ExtensionPayloadMetadata {
        name,
        app_id,
        bundle_id: bundle_id.to_owned(),
        balloon: ExtensionBalloonMetadata {
            url,
            session,
            ld_text,
            is_live,
            icon,
            layout,
        },
    })
}

fn decode_icon(bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() > MAX_COMPRESSED_ICON_BYTES {
        return Err(Failure::LimitExceeded);
    }
    // bufread avoids read-ahead hiding trailing bytes or concatenated members.
    let mut decoder = GzDecoder::new(bytes);
    let mut output = Vec::new();
    decoder
        .by_ref()
        .take((MAX_ICON_BYTES + 1) as u64)
        .read_to_end(&mut output)
        .map_err(|_| Failure::InvalidIcon)?;
    if output.len() > MAX_ICON_BYTES {
        return Err(Failure::LimitExceeded);
    }
    if !decoder.into_inner().is_empty() {
        return Err(Failure::InvalidIcon);
    }
    Ok(output)
}

#[derive(Default)]
struct Budget {
    nodes: usize,
    bytes: usize,
}

impl Budget {
    fn charge(&mut self, depth: usize, bytes: usize) -> Result<()> {
        self.nodes = self.nodes.checked_add(1).ok_or(Failure::LimitExceeded)?;
        self.bytes = self
            .bytes
            .checked_add(bytes)
            .ok_or(Failure::LimitExceeded)?;
        if depth >= MAX_DEPTH || self.nodes > MAX_VISITED_NODES || self.bytes > MAX_EXPANDED_BYTES {
            return Err(Failure::LimitExceeded);
        }
        Ok(())
    }
}

fn validate_archive(value: &Value) -> Result<()> {
    let dict = dictionary(value)?;
    fields(dict, &["$archiver", "$version", "$top", "$objects"])?;
    if text(required(dict, "$archiver")?)? != "NSKeyedArchiver"
        || required(dict, "$version")?.as_unsigned_integer() != Some(100_000)
    {
        return Err(Failure::UnsupportedEncoding);
    }
    let objects = required(dict, "$objects")?
        .as_array()
        .ok_or(Failure::Malformed)?;
    if objects.is_empty() || objects[0].as_string() != Some("$null") {
        return Err(Failure::Malformed);
    }
    if objects.len() > MAX_ARCHIVE_OBJECTS {
        return Err(Failure::LimitExceeded);
    }
    let top = dictionary(required(dict, "$top")?)?;
    fields(top, &["root"])?;
    let root = required(top, "root")?;
    if root.as_uid().is_none() {
        return Err(Failure::Malformed);
    }
    let mut budget = Budget::default();
    let mut active = vec![false; objects.len()];
    visit(root, objects, &mut active, 0, &mut budget)?;
    // Include unreachable objects too. Repeated references are charged on EVERY
    // traversal, not just once per UID, bounding KeyedArchive's clone expansion.
    for object in objects {
        visit(object, objects, &mut active, 0, &mut budget)?;
    }
    Ok(())
}

fn resolve<'a>(mut value: &'a Value, objects: &'a [Value]) -> Result<&'a Value> {
    for _ in 0..MAX_DEPTH {
        match value.as_uid() {
            Some(uid) => {
                value = objects
                    .get(usize::try_from(uid.get()).map_err(|_| Failure::Malformed)?)
                    .ok_or(Failure::Malformed)?
            }
            None => return Ok(value),
        }
    }
    Err(Failure::CyclicArchive)
}

fn visit(
    value: &Value,
    objects: &[Value],
    active: &mut [bool],
    depth: usize,
    budget: &mut Budget,
) -> Result<()> {
    budget.charge(
        depth,
        match value {
            Value::String(s) => s.len(),
            Value::Data(d) => d.len(),
            _ => 0,
        },
    )?;
    match value {
        Value::Uid(uid) => {
            let index = usize::try_from(uid.get()).map_err(|_| Failure::Malformed)?;
            let child = objects.get(index).ok_or(Failure::Malformed)?;
            if active[index] {
                return Err(Failure::CyclicArchive);
            }
            active[index] = true;
            visit(child, objects, active, depth + 1, budget)?;
            active[index] = false;
        }
        Value::Array(items) => {
            for item in items {
                visit(item, objects, active, depth + 1, budget)?;
            }
        }
        Value::Dictionary(dict) => {
            if let Some(class) = dict.get("$class") {
                // The library only recognizes a literal UID here, not a UID chain.
                let uid = class.as_uid().ok_or(Failure::Malformed)?;
                let desc = dictionary(
                    objects
                        .get(usize::try_from(uid.get()).map_err(|_| Failure::Malformed)?)
                        .ok_or(Failure::Malformed)?,
                )?;
                fields(desc, &["$classname", "$classes", "$classhints"])?;
                let name = text(required(desc, "$classname")?)?;
                match name {
                    "NSDictionary" | "NSMutableDictionary" => {
                        fields(dict, &["$class", "NS.keys", "NS.objects"])?;
                        let keys = resolve(required(dict, "NS.keys")?, objects)?
                            .as_array()
                            .ok_or(Failure::Malformed)?;
                        let values = resolve(required(dict, "NS.objects")?, objects)?
                            .as_array()
                            .ok_or(Failure::Malformed)?;
                        if keys.len() != values.len() {
                            return Err(Failure::Malformed);
                        }
                        let mut seen = BTreeSet::new();
                        for key in keys {
                            let key = text(resolve(key, objects)?)?;
                            if key == "$class" || !seen.insert(key) {
                                return Err(Failure::Malformed);
                            }
                        }
                    }
                    // KeyedArchive only substitutes other class names; it does
                    // not instantiate/execute them. Budget their complete graph.
                    // Projection validates the classes of fields it consumes.
                    _ => {}
                }
            }
            for (key, child) in dict {
                budget.charge(depth, key.len())?;
                visit(child, objects, active, depth + 1, budget)?;
            }
        }
        Value::String(_) => {
            text(value)?;
        }
        _ => {}
    }
    Ok(())
}

// Allocation audit, exact plist 1.7.0 stream/binary_reader.rs:
// allocate_vec bounds wire length by the input trailer even though PosReader's
// cached position advances only on seek. With <=1 MiB input, offsets are <=128
// KiB after our count check; a scalar's source buffer is <=1 MiB (UTF16 -> UTF8
// <=1.5 MiB). The worst pre-yield dictionary has key/value/combined u64 vectors
// totaling <=16 MiB. This is a finite input-derived ceiling, NOT the 4 MiB quota.
// Accepted collection slots sum to <=16,384, so retained reader reference
// vectors total <=128 KiB before the next event. Depth/events bound repeated
// work. Keys retained for duplicate detection total <=4 MiB. No Value is built
// until the complete event preflight succeeds. Keep the dependency exact-pinned.
// Only header/trailer framing remains here; the library owns object decoding.
fn be(bytes: &[u8]) -> Result<usize> {
    usize::try_from(bytes.iter().fold(0u64, |n, b| (n << 8) | u64::from(*b)))
        .map_err(|_| Failure::LimitExceeded)
}

fn validate_binary_header(bytes: &[u8]) -> Result<()> {
    if bytes.len() > MAX_PAYLOAD_BYTES {
        return Err(Failure::LimitExceeded);
    }
    if bytes.is_empty() {
        return Err(Failure::Malformed);
    }
    if !bytes.starts_with(b"bplist00") {
        return Err(Failure::UnsupportedEncoding);
    }
    if bytes.len() < 41 {
        return Err(Failure::Malformed);
    }
    let trailer = &bytes[bytes.len() - 32..];
    let width = usize::from(trailer[6]);
    if trailer[..6] != [0; 6]
        || ![1, 2, 4, 8].contains(&width)
        || ![1, 2, 4, 8].contains(&trailer[7])
    {
        return Err(Failure::Malformed);
    }
    let count = be(&trailer[8..16])?;
    let root = be(&trailer[16..24])?;
    let table = be(&trailer[24..32])?;
    if count > MAX_VISITED_NODES {
        return Err(Failure::LimitExceeded);
    }
    if count == 0
        || root >= count
        || table < 8
        || table.checked_add(count * width) != Some(bytes.len() - 32)
    {
        return Err(Failure::Malformed);
    }
    Ok(())
}

#[derive(Default)]
struct EventFrame {
    // None = array; Some = dictionary, tracking keys before Value loses duplicates.
    keys: Option<BTreeSet<String>>,
    wants_key: bool,
}

fn validate_binary(bytes: &[u8]) -> Result<()> {
    validate_binary_header(bytes)?;
    let mut frames: Vec<EventFrame> = Vec::new();
    let mut budget = Budget::default();
    let mut slots = 0usize;
    let mut roots = 0usize;
    for event in Reader::new(Cursor::new(bytes)) {
        let event = event.map_err(|_| Failure::Malformed)?;
        if matches!(event, Event::EndCollection) {
            budget.charge(frames.len().saturating_sub(1), 0)?;
            let frame = frames.pop().ok_or(Failure::Malformed)?;
            if frame.keys.is_some() && !frame.wants_key {
                return Err(Failure::Malformed);
            }
            continue;
        }
        let size = match &event {
            Event::String(s) => {
                if s.len() > MAX_STRING_BYTES {
                    return Err(Failure::LimitExceeded);
                }
                s.len()
            }
            Event::Data(d) => d.len(),
            _ => 0,
        };
        budget.charge(frames.len(), size)?;
        if let Some(frame) = frames.last_mut() {
            if let Some(keys) = &mut frame.keys {
                if frame.wants_key {
                    let Event::String(key) = &event else {
                        return Err(Failure::Malformed);
                    };
                    if !keys.insert(key.to_string()) {
                        return Err(Failure::Malformed);
                    }
                }
                frame.wants_key = !frame.wants_key;
            }
        } else {
            roots += 1;
            if roots != 1 || !matches!(event, Event::StartDictionary(_)) {
                return Err(Failure::Malformed);
            }
        }
        let (length, is_dict) = match event {
            Event::StartDictionary(Some(n)) => (n, true),
            Event::StartArray(Some(n)) => (n, false),
            Event::StartDictionary(None) | Event::StartArray(None) => {
                return Err(Failure::Malformed)
            }
            _ => continue,
        };
        let length = usize::try_from(length).map_err(|_| Failure::LimitExceeded)?;
        slots = slots
            .checked_add(
                length
                    .checked_mul(if is_dict { 2 } else { 1 })
                    .ok_or(Failure::LimitExceeded)?,
            )
            .ok_or(Failure::LimitExceeded)?;
        if slots > MAX_VISITED_NODES {
            return Err(Failure::LimitExceeded);
        }
        frames.push(EventFrame {
            keys: is_dict.then(BTreeSet::new),
            wants_key: is_dict,
        });
    }
    if roots != 1 || !frames.is_empty() {
        return Err(Failure::Malformed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{write::GzEncoder, Compression};
    use plist::Uid;
    use std::io::Write;

    fn dict(entries: &[(&str, Value)]) -> Value {
        Value::Dictionary(
            entries
                .iter()
                .map(|(k, v)| ((*k).to_owned(), v.clone()))
                .collect(),
        )
    }
    fn s(value: &str) -> Value {
        Value::String(value.to_owned())
    }
    fn uid(value: u64) -> Value {
        Value::Uid(Uid::new(value))
    }
    fn encode(value: &Value) -> Vec<u8> {
        let mut bytes = Vec::new();
        value.to_writer_binary(&mut bytes).unwrap();
        bytes
    }
    fn gzip(bytes: &[u8]) -> Vec<u8> {
        let mut writer = GzEncoder::new(Vec::new(), Compression::default());
        writer.write_all(bytes).unwrap();
        writer.finish().unwrap()
    }
    fn blob(bytes: Vec<u8>) -> Value {
        dict(&[
            ("$class", s("NSMutableData")),
            ("NS.data", Value::Data(bytes)),
        ])
    }
    fn balloon() -> Value {
        dict(&[
            ("$class", s("NSMutableDictionary")),
            ("an", s("Synthetic App")),
            (
                "URL",
                dict(&[
                    ("$class", s("NSURL")),
                    ("NS.base", s("$null")),
                    ("NS.relative", s("app:synthetic")),
                ]),
            ),
        ])
    }
    fn archived(value: Value) -> Value {
        KeyedArchive::archive_item(value).unwrap()
    }
    fn decode(value: Value) -> Result<ExtensionPayloadMetadata> {
        decode_extension_payload(&encode(&archived(value)), "com.example.synthetic")
    }
    fn objects(archive: &mut Value) -> &mut Vec<Value> {
        archive
            .as_dictionary_mut()
            .unwrap()
            .get_mut("$objects")
            .unwrap()
            .as_array_mut()
            .unwrap()
    }
    fn archive_result(archive: &Value) -> Result<ExtensionPayloadMetadata> {
        decode_extension_payload(&encode(archive), "com.example.synthetic")
    }

    #[test]
    fn session_metadata_has_closed_versions_and_separate_wire_identity() {
        let metadata = decode(balloon()).unwrap();
        for role in [ExtensionSessionRole::Base, ExtensionSessionRole::Update] {
            let context = ExtensionSessionContext {
                role,
                session_guid: "wire-base-guid".into(),
                session_logical_key_hash: "A".repeat(43),
            };
            let bytes = serialize_session_metadata_json(&metadata, &context).unwrap();
            let (parsed, session) = parse_projection_metadata_json(&bytes).unwrap();
            assert_eq!(parsed, metadata);
            assert!(session.as_ref() == Some(&context));
            assert!(parsed.balloon.session.is_none());
            assert!(parse_generated_metadata_json(&bytes).is_err());
            let mut raw: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            raw["version"] = serde_json::json!(1);
            assert!(parse_projection_metadata_json(&serde_json::to_vec(&raw).unwrap()).is_err());
            raw["version"] = serde_json::json!(2);
            for field in ["role", "session_guid", "session_logical_key_hash"] {
                let mut missing = raw.clone();
                missing["context"].as_object_mut().unwrap().remove(field);
                assert!(
                    parse_projection_metadata_json(&serde_json::to_vec(&missing).unwrap()).is_err()
                );
            }
            for bad in [
                serde_json::Value::Null,
                serde_json::json!({}),
                serde_json::json!("opaque"),
            ] {
                let mut invalid = raw.clone();
                invalid["context"] = bad;
                assert!(
                    parse_projection_metadata_json(&serde_json::to_vec(&invalid).unwrap()).is_err()
                );
            }
        }
        let v1 = serialize_generated_metadata_json(&metadata).unwrap();
        assert!(parse_projection_metadata_json(&v1).unwrap().1.is_none());
    }

    #[test]
    fn session_context_rejects_invalid_wire_identity_and_digest() {
        let mut context = ExtensionSessionContext {
            role: ExtensionSessionRole::Update,
            session_guid: "base-guid".into(),
            session_logical_key_hash: "A".repeat(43),
        };
        for guid in ["", "p:0/base", "bp:base", "base\n", "base\u{85}"] {
            context.session_guid = guid.into();
            assert!(validate_session_context(&context).is_err());
        }
        context.session_guid = "base-guid".into();
        for hash in ["A".repeat(42), "A".repeat(44), "!".repeat(43)] {
            context.session_logical_key_hash = hash;
            assert!(validate_session_context(&context).is_err());
        }
    }

    #[test]
    fn minimum_balloon_is_metadata_not_base_only_success() {
        let metadata = decode(balloon()).unwrap();
        assert_eq!(metadata.name, "Synthetic App");
        assert_eq!(metadata.bundle_id, "com.example.synthetic");
        assert_eq!(metadata.app_id, None);
        assert_eq!(metadata.balloon.url, "app:synthetic");
        assert!(!metadata.balloon.is_live);
        assert!(metadata.balloon.icon.is_none());
        assert!(metadata.balloon.layout.is_none());
        assert_eq!(
            format!("{metadata:?}"),
            "ExtensionPayloadMetadata([redacted])"
        );
    }

    #[test]
    fn renderer_fields_survive_including_template_icon_session_and_live_marker() {
        let mut root = balloon();
        let d = root.as_dictionary_mut().unwrap();
        d.insert("appid".into(), Value::Integer(1234u64.into()));
        d.insert("ldtext".into(), s("Synthetic description"));
        d.insert("ai".into(), blob(gzip(b"synthetic icon bytes")));
        d.insert("liveLayoutInfo".into(), blob(vec![1, 2, 3]));
        d.insert(
            "sessionIdentifier".into(),
            dict(&[
                ("$class", s("NSUUID")),
                ("NS.uuidbytes", Value::Data(vec![1; 16])),
            ]),
        );
        d.insert("layoutClass".into(), s("MSMessageTemplateLayout"));
        d.insert(
            "userInfo".into(),
            dict(&[
                ("$class", s("NSDictionary")),
                ("image-subtitle", s("is")),
                ("image-title", s("it")),
                ("caption", s("c")),
                ("secondary-subcaption", s("ss")),
                ("tertiary-subcaption", s("ts")),
                ("subcaption", s("s")),
            ]),
        );
        d.get_mut("userInfo")
            .unwrap()
            .as_dictionary_mut()
            .unwrap()
            .insert("future-caption-hint".into(), s("budgeted, not returned"));
        let result = decode(root).unwrap();
        assert_eq!(result.app_id, Some(1234));
        assert_eq!(
            result.balloon.ld_text.as_deref(),
            Some("Synthetic description")
        );
        assert!(result.balloon.is_live);
        assert_eq!(
            result.balloon.session.as_deref(),
            Some("01010101-0101-0101-0101-010101010101")
        );
        assert_eq!(
            result.balloon.icon.as_deref(),
            Some(&b"synthetic icon bytes"[..])
        );
        assert_eq!(
            parse_generated_metadata_json(&serialize_generated_metadata_json(&result).unwrap())
                .unwrap(),
            result
        );
        let layout = result.balloon.layout.unwrap();
        assert_eq!(
            (
                layout.image_subtitle,
                layout.image_title,
                layout.caption,
                layout.secondary_subcaption,
                layout.tertiary_subcaption,
                layout.subcaption
            ),
            (
                "is".into(),
                "it".into(),
                "c".into(),
                "ss".into(),
                "ts".into(),
                "s".into()
            )
        );
    }

    #[test]
    fn primary_requires_decompressed_bounded_binary() {
        let bytes = encode(&archived(balloon()));
        assert_eq!(
            decode_extension_payload(&gzip(&bytes), "test").unwrap_err(),
            Failure::UnsupportedEncoding
        );
        assert_eq!(
            decode_extension_payload(b"<?xml version='1.0'?>", "test").unwrap_err(),
            Failure::UnsupportedEncoding
        );
        assert_eq!(
            decode_extension_payload(&vec![0; MAX_PAYLOAD_BYTES + 1], "test").unwrap_err(),
            Failure::LimitExceeded
        );
        for end in 0..bytes.len() {
            assert!(decode_extension_payload(&bytes[..end], "test").is_err());
        }
    }

    #[test]
    fn invalid_bundle_and_trailing_primary_bytes_fail() {
        let mut bytes = encode(&archived(balloon()));
        for bundle in ["", "bad\nidentifier"] {
            assert!(decode_extension_payload(&bytes, bundle).is_err());
        }
        assert_eq!(
            decode_extension_payload(&bytes, &"b".repeat(MAX_BUNDLE_ID_BYTES + 1)).unwrap_err(),
            Failure::LimitExceeded
        );
        bytes.push(0);
        assert!(decode_extension_payload(&bytes, "test").is_err());
    }

    #[test]
    fn missing_root_and_out_of_range_uid_fail_without_legacy_panics() {
        let mut a = archived(balloon());
        a.as_dictionary_mut()
            .unwrap()
            .insert("$top".into(), dict(&[]));
        assert_eq!(archive_result(&a).unwrap_err(), Failure::Malformed);
        a.as_dictionary_mut()
            .unwrap()
            .insert("$top".into(), dict(&[("root", uid(u64::MAX))]));
        assert_eq!(archive_result(&a).unwrap_err(), Failure::Malformed);
    }

    #[test]
    fn cycles_and_uid_depth_are_bounded_before_expansion() {
        let mut a = archived(balloon());
        let n = objects(&mut a).len() as u64;
        objects(&mut a).push(uid(n));
        assert_eq!(archive_result(&a).unwrap_err(), Failure::CyclicArchive);
        objects(&mut a).pop();
        for i in 0..MAX_DEPTH + 1 {
            objects(&mut a).push(uid(n + i as u64 + 1));
        }
        objects(&mut a).push(s("end"));
        assert_eq!(archive_result(&a).unwrap_err(), Failure::LimitExceeded);
    }

    #[test]
    fn keyed_dictionary_mismatches_and_duplicate_keys_are_rejected() {
        for duplicate in [false, true] {
            let mut a = archived(balloon());
            let d = objects(&mut a)
                .iter_mut()
                .filter_map(Value::as_dictionary_mut)
                .find(|d| d.contains_key("NS.keys"))
                .unwrap();
            if duplicate {
                let keys = d.get_mut("NS.keys").unwrap().as_array_mut().unwrap();
                keys[1] = keys[0].clone();
            } else {
                d.get_mut("NS.objects")
                    .unwrap()
                    .as_array_mut()
                    .unwrap()
                    .pop();
            }
            assert_eq!(archive_result(&a).unwrap_err(), Failure::Malformed);
        }
    }

    #[test]
    fn repeated_uid_nodes_and_bytes_are_charged_per_occurrence() {
        for large in [false, true] {
            let mut a = archived(balloon());
            let n = objects(&mut a).len() as u64;
            objects(&mut a).push(if large {
                Value::Data(vec![0; MAX_PAYLOAD_BYTES / 2])
            } else {
                Value::Array(vec![s("x"); 128])
            });
            objects(&mut a).push(Value::Array(vec![uid(n); if large { 10 } else { 128 }]));
            assert_eq!(archive_result(&a).unwrap_err(), Failure::LimitExceeded);
        }
    }

    #[test]
    fn malformed_required_fields_and_layouts_fail_closed() {
        for (key, value) in [
            ("layoutClass", s("FutureLayout")),
            ("appid", s("not an integer")),
            (
                "sessionIdentifier",
                dict(&[
                    ("$class", s("NSUUID")),
                    ("NS.uuidbytes", Value::Data(vec![0; 15])),
                ]),
            ),
        ] {
            let mut root = balloon();
            root.as_dictionary_mut().unwrap().insert(key.into(), value);
            assert!(decode(root).is_err());
        }
        let mut a = archived(balloon());
        let root = a.as_dictionary().unwrap()["$top"].as_dictionary().unwrap()["root"]
            .as_uid()
            .unwrap()
            .get() as usize;
        let class = objects(&mut a)[root].as_dictionary().unwrap()["$class"]
            .as_uid()
            .unwrap()
            .get() as usize;
        objects(&mut a)[class]
            .as_dictionary_mut()
            .unwrap()
            .insert("$classname".into(), s("FutureClass"));
        assert_eq!(archive_result(&a).unwrap_err(), Failure::UnsupportedContent);
    }

    #[test]
    fn icon_cap_crc_truncation_suffix_and_extra_member() {
        let exact = gzip(&vec![1; MAX_ICON_BYTES]);
        assert_eq!(decode_icon(&exact).unwrap().len(), MAX_ICON_BYTES);
        assert_eq!(
            decode_icon(&gzip(&vec![1; MAX_ICON_BYTES + 1])).unwrap_err(),
            Failure::LimitExceeded
        );
        assert_eq!(
            decode_icon(&vec![0; MAX_COMPRESSED_ICON_BYTES + 1]).unwrap_err(),
            Failure::LimitExceeded
        );
        let valid = gzip(b"icon");
        let mut crc = valid.clone();
        let n = crc.len();
        crc[n - 8] ^= 1;
        let mut suffix = valid.clone();
        suffix.push(0);
        let mut extra = valid.clone();
        extra.extend_from_slice(&valid);
        for invalid in [
            b"not gzip".to_vec(),
            valid[..valid.len() - 1].to_vec(),
            crc,
            suffix,
            extra,
        ] {
            assert_eq!(decode_icon(&invalid).unwrap_err(), Failure::InvalidIcon);
            let mut root = balloon();
            root.as_dictionary_mut()
                .unwrap()
                .insert("ai".into(), blob(invalid));
            assert_eq!(decode(root).unwrap_err(), Failure::InvalidIcon);
        }
    }

    #[test]
    fn metadata_strings_objects_and_live_blob_have_limits() {
        let mut root = balloon();
        root.as_dictionary_mut()
            .unwrap()
            .insert("an".into(), s(&"x".repeat(MAX_STRING_BYTES + 1)));
        assert_eq!(decode(root).unwrap_err(), Failure::LimitExceeded);
        let mut root = balloon();
        root.as_dictionary_mut().unwrap().insert(
            "liveLayoutInfo".into(),
            blob(vec![0; MAX_LIVE_LAYOUT_BYTES + 1]),
        );
        assert_eq!(decode(root).unwrap_err(), Failure::LimitExceeded);
        let mut a = archived(balloon());
        objects(&mut a).resize(MAX_ARCHIVE_OBJECTS + 1, s("x"));
        assert_eq!(archive_result(&a).unwrap_err(), Failure::LimitExceeded);
    }

    // Independent framing fixtures: no plist serializer normalizing away
    // duplicate dictionary keys, cyclic references, or compact reference DAGs.
    fn binary_fixture(objects: &[Vec<u8>]) -> Vec<u8> {
        let mut bytes = b"bplist00".to_vec();
        let mut offsets = Vec::new();
        for object in objects {
            offsets.push(bytes.len() as u8);
            bytes.extend_from_slice(object);
        }
        assert!(bytes.len() < 256 && objects.len() < 256);
        let table = bytes.len() as u64;
        bytes.extend_from_slice(&offsets);
        bytes.extend_from_slice(&[0, 0, 0, 0, 0, 0, 1, 1]);
        bytes.extend_from_slice(&(objects.len() as u64).to_be_bytes());
        bytes.extend_from_slice(&0u64.to_be_bytes());
        bytes.extend_from_slice(&table.to_be_bytes());
        bytes
    }

    #[test]
    fn binary_duplicate_keys_and_bad_references_fail_before_value_parser() {
        let duplicate = binary_fixture(&[vec![0xd2, 1, 1, 2, 2], vec![0x51, b'x'], vec![0x09]]);
        assert_eq!(validate_binary(&duplicate), Err(Failure::Malformed));
        let bad_ref = binary_fixture(&[vec![0xd1, 1, 255], vec![0x51, b'x']]);
        assert_eq!(validate_binary(&bad_ref), Err(Failure::Malformed));
    }

    #[test]
    fn binary_cycle_and_compact_dag_have_preparse_depth_and_node_limits() {
        let cyclic = binary_fixture(&[vec![0xd1, 1, 2], vec![0x51, b'x'], vec![0xa1, 2]]);
        assert_eq!(validate_binary(&cyclic), Err(Failure::Malformed));
        let mut objects = vec![vec![0xd1, 1, 2], vec![0x51, b'x']];
        for i in 2..17u8 {
            objects.push(vec![0xa2, i + 1, i + 1]);
        }
        objects.push(vec![0x09]);
        assert_eq!(
            validate_binary(&binary_fixture(&objects)),
            Err(Failure::LimitExceeded)
        );
    }

    #[test]
    fn invalid_class_uid_and_hidden_dictionary_fields_do_not_reach_legacy_expand() {
        for invalid_uid in [true, false] {
            let mut a = archived(balloon());
            let d = objects(&mut a)
                .iter_mut()
                .filter_map(Value::as_dictionary_mut)
                .find(|d| d.contains_key("NS.keys"))
                .unwrap();
            if invalid_uid {
                d.insert("$class".into(), uid(u64::MAX));
            } else {
                d.insert("ignored-by-legacy".into(), s("opaque"));
            }
            assert_eq!(
                archive_result(&a).unwrap_err(),
                if invalid_uid {
                    Failure::Malformed
                } else {
                    Failure::UnsupportedContent
                }
            );
        }
    }

    #[test]
    fn unknown_or_incomplete_template_cannot_be_silently_erased() {
        for kind in ["FutureLayout", "MSMessageTemplateLayout"] {
            let mut root = balloon();
            let d = root.as_dictionary_mut().unwrap();
            d.insert("layoutClass".into(), s(kind));
            d.insert(
                "userInfo".into(),
                dict(&[
                    ("$class", s("NSDictionary")),
                    ("caption", s("only one caption")),
                ]),
            );
            assert_eq!(
                decode(root).unwrap_err(),
                if kind == "FutureLayout" {
                    Failure::UnsupportedContent
                } else {
                    Failure::Malformed
                }
            );
        }
    }

    #[test]
    fn harmless_future_app_fields_are_budgeted_ignored_and_not_exported() {
        let mut root = balloon();
        root.as_dictionary_mut()
            .unwrap()
            .insert("futureField".into(), s("not exported"));
        // A future opaque class is inert under KeyedArchive::expand. Change its
        // descriptor AFTER archiving because the legacy writer has a class list.
        root.as_dictionary_mut()
            .unwrap()
            .insert("futureObject".into(), blob(vec![1, 2]));
        let mut a = archived(root);
        let class = objects(&mut a)
            .iter_mut()
            .filter_map(Value::as_dictionary_mut)
            .find(|d| d.get("$classname").and_then(Value::as_string) == Some("NSMutableData"))
            .unwrap();
        class.insert("$classname".into(), s("FutureOpaqueClass"));
        let before = a.clone();
        let result = archive_result(&a).unwrap();
        assert_eq!(result, decode(balloon()).unwrap());
        assert_eq!(a, before);
        let json = serialize_generated_metadata_json(&result).unwrap();
        assert!(!String::from_utf8(json).unwrap().contains("future"));
    }

    #[test]
    fn generated_json_has_exact_version_one_wire_contract_and_roundtrips() {
        let metadata = decode(balloon()).unwrap();
        let json = serialize_generated_metadata_json(&metadata).unwrap();
        assert_eq!(
            std::str::from_utf8(&json).unwrap(),
            r#"{"version":1,"metadata":{"name":"Synthetic App","app_id":null,"bundle_id":"com.example.synthetic","balloon":{"url":"app:synthetic","session":null,"ld_text":null,"is_live":false,"icon":null,"layout":null}}}"#
        );
        assert_eq!(parse_generated_metadata_json(&json).unwrap(), metadata);
        assert_eq!(
            serialize_generated_metadata_json(&parse_generated_metadata_json(&json).unwrap())
                .unwrap(),
            json
        );
        assert!(parse_generated_metadata_json(&encode(&archived(balloon()))).is_err());
    }

    fn json_value() -> serde_json::Value {
        serde_json::from_slice(
            &serialize_generated_metadata_json(&decode(balloon()).unwrap()).unwrap(),
        )
        .unwrap()
    }
    fn parse_json_value(value: &serde_json::Value) -> Result<ExtensionPayloadMetadata> {
        parse_generated_metadata_json(&serde_json::to_vec(value).unwrap())
    }

    #[test]
    fn generated_json_rejects_missing_unknown_duplicate_fields_and_bad_versions() {
        let baseline = json_value();
        for path in ["", "/metadata", "/metadata/balloon"] {
            for key in baseline.pointer(path).unwrap().as_object().unwrap().keys() {
                let mut value = baseline.clone();
                value
                    .pointer_mut(path)
                    .unwrap()
                    .as_object_mut()
                    .unwrap()
                    .remove(key);
                assert!(parse_json_value(&value).is_err(), "missing {path}/{key}");
            }
            let mut value = baseline.clone();
            value
                .pointer_mut(path)
                .unwrap()
                .as_object_mut()
                .unwrap()
                .insert("extra".into(), serde_json::json!(true));
            assert!(parse_json_value(&value).is_err());
        }
        for version in [
            serde_json::json!(0),
            serde_json::json!(2),
            serde_json::json!(1.0),
            serde_json::json!("1"),
        ] {
            let mut value = baseline.clone();
            value["version"] = version;
            assert!(parse_json_value(&value).is_err());
        }
        let json = String::from_utf8(
            serialize_generated_metadata_json(&decode(balloon()).unwrap()).unwrap(),
        )
        .unwrap();
        for (from, to) in [
            ("\"version\":1", "\"version\":1,\"version\":1"),
            ("\"app_id\":null", "\"app_id\":null,\"app_id\":null"),
            ("\"icon\":null", "\"icon\":null,\"icon\":null"),
        ] {
            assert!(parse_generated_metadata_json(json.replace(from, to).as_bytes()).is_err());
        }
        assert!(parse_generated_metadata_json(format!("{json}{{}}").as_bytes()).is_err());
    }

    #[test]
    fn json_and_archive_app_ids_are_signed_64_bit_bounded() {
        for id in [0, i64::MAX as u64, i64::MAX as u64 + 1, u64::MAX] {
            let mut root = balloon();
            root.as_dictionary_mut()
                .unwrap()
                .insert("appid".into(), Value::Integer(id.into()));
            let mut value = json_value();
            value["metadata"]["app_id"] = serde_json::json!(id);
            assert_eq!(decode(root).is_ok(), id <= i64::MAX as u64);
            assert_eq!(parse_json_value(&value).is_ok(), id <= i64::MAX as u64);
        }
        for id in [
            serde_json::json!(-1),
            serde_json::json!(1.5),
            serde_json::json!("123"),
        ] {
            let mut value = json_value();
            value["metadata"]["app_id"] = id;
            assert!(parse_json_value(&value).is_err());
        }
    }

    #[test]
    fn json_strings_sessions_icons_and_total_bytes_are_validated() {
        for path in [
            "/metadata/name",
            "/metadata/balloon/url",
            "/metadata/balloon/ld_text",
        ] {
            let mut value = json_value();
            *value.pointer_mut(path).unwrap() = serde_json::json!("x".repeat(MAX_STRING_BYTES));
            assert!(parse_json_value(&value).is_ok());
            *value.pointer_mut(path).unwrap() = serde_json::json!("x".repeat(MAX_STRING_BYTES + 1));
            assert!(parse_json_value(&value).is_err());
        }
        for session in ["bad", "01010101010101010101010101010101"] {
            let mut value = json_value();
            value["metadata"]["balloon"]["session"] = serde_json::json!(session);
            assert!(parse_json_value(&value).is_err());
        }
        let mut upper_session = json_value();
        upper_session["metadata"]["balloon"]["session"] =
            serde_json::json!("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");
        assert_eq!(
            parse_json_value(&upper_session)
                .unwrap()
                .balloon
                .session
                .as_deref(),
            Some("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        );
        for icon in [
            serde_json::json!([256]),
            serde_json::json!([-1]),
            serde_json::json!([1.5]),
            serde_json::json!("base64"),
        ] {
            let mut value = json_value();
            value["metadata"]["balloon"]["icon"] = icon;
            assert!(parse_json_value(&value).is_err());
        }
        let mut value = json_value();
        value["metadata"]["balloon"]["icon"] = serde_json::json!(vec![0u8; MAX_ICON_BYTES + 1]);
        assert!(parse_json_value(&value).is_err());
        assert_eq!(
            parse_generated_metadata_json(&vec![b' '; MAX_JSON_BYTES + 1]).unwrap_err(),
            Failure::LimitExceeded
        );
        let mut metadata = decode(balloon()).unwrap();
        metadata.balloon.icon = Some(vec![255; MAX_ICON_BYTES]);
        metadata.balloon.session = Some("01010101-0101-0101-0101-010101010101".into());
        let json = serialize_generated_metadata_json(&metadata).unwrap();
        assert!(json.len() < MAX_JSON_BYTES);
        assert_eq!(parse_generated_metadata_json(&json).unwrap(), metadata);
        metadata.balloon.icon.as_mut().unwrap().push(0);
        assert_eq!(
            serialize_generated_metadata_json(&metadata).unwrap_err(),
            Failure::LimitExceeded
        );
    }

    #[test]
    fn json_template_schema_is_closed_and_captions_are_bounded() {
        let mut value = json_value();
        value["metadata"]["balloon"]["layout"] = serde_json::json!({"image_subtitle":"is", "image_title":"it",
            "caption":"c", "secondary_subcaption":"ss", "tertiary_subcaption":"ts", "subcaption":"s"});
        let metadata = parse_json_value(&value).unwrap();
        assert_eq!(
            parse_generated_metadata_json(&serialize_generated_metadata_json(&metadata).unwrap())
                .unwrap(),
            metadata
        );
        for key in [
            "image_subtitle",
            "image_title",
            "caption",
            "secondary_subcaption",
            "tertiary_subcaption",
            "subcaption",
        ] {
            let mut bad = value.clone();
            bad["metadata"]["balloon"]["layout"]
                .as_object_mut()
                .unwrap()
                .remove(key);
            assert!(parse_json_value(&bad).is_err());
            let mut bad = value.clone();
            bad["metadata"]["balloon"]["layout"][key] =
                serde_json::json!("x".repeat(MAX_STRING_BYTES + 1));
            assert!(parse_json_value(&bad).is_err());
        }
        value["metadata"]["balloon"]["layout"]["future"] =
            serde_json::json!("ignored in raw app only");
        assert!(parse_json_value(&value).is_err());
    }

    #[test]
    fn header_count_and_pre_event_allocations_have_input_derived_bounds() {
        let mut bytes = binary_fixture(&[vec![0xd0]]);
        let n = bytes.len();
        bytes[n - 24..n - 16].copy_from_slice(&((MAX_VISITED_NODES + 1) as u64).to_be_bytes());
        assert_eq!(validate_binary(&bytes), Err(Failure::LimitExceeded));
        // Huge claimed array length is rejected by the library before allocation.
        let bytes = binary_fixture(&[
            vec![0xd1, 1, 2],
            vec![0x51, b'x'],
            vec![0xaf, 0x13, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        ]);
        assert_eq!(validate_binary(&bytes), Err(Failure::Malformed));
    }
}
