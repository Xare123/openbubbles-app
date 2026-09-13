//! Shared bounded extension metadata contract, independent of archive decoding.
//! The protector harness and application use these same validation functions.

use serde::{de, Deserialize, Deserializer, Serialize};
use std::fmt;

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

pub(crate) fn validate_metadata(metadata: &ExtensionPayloadMetadata) -> Result<()> {
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

pub(crate) fn validate_bundle_id(bundle_id: &str) -> Result<()> {
    if bundle_id.len() > MAX_BUNDLE_ID_BYTES {
        return Err(Failure::LimitExceeded);
    }
    if bundle_id.is_empty() || bundle_id.chars().any(char::is_control) {
        return Err(Failure::Malformed);
    }
    Ok(())
}
