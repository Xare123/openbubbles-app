//! Private, default-off Cloud Sync V2 raw-presence conversion gate.
//!
//! `CloudKitRecord` derives populate missing fields through `Default`. This
//! gate therefore captures field presence from the raw protobuf before typed
//! decoding and captures nested plist keys immediately after decryption but
//! before serde. It refuses to infer absence or an explicit clear from a
//! defaulted typed value.

#![allow(dead_code)]

use std::{
    collections::{HashMap, HashSet},
    fmt::{self, Debug, Formatter},
    io::Cursor,
};

use plist::Value as PlistValue;
use rustpush::{
    cloud_messages::{
        cloudmessagesp::{MessageProto, MessageProto2, MessageProto4},
        AttachmentMeta, CloudChat, CloudMessage, MMCSAttachmentMeta, MessageFlags,
        MessageSummaryInfo,
    },
    cloudkit_proto::{record::field::value::Type as CloudKitFieldType, Record},
};
use sha2::{Digest, Sha256};

use crate::{
    cloud_sync_canonical_dto::{
        parse_associated_parent, parse_owned_attachment_guid, parse_reply_parent,
        CloudCanonicalAlias, CloudCanonicalAliasKind,
        CloudCanonicalAttachmentMaterializationCapability, CloudCanonicalAttachmentPayload,
        CloudCanonicalAttachmentReference, CloudCanonicalAttributedBody, CloudCanonicalChatPayload,
        CloudCanonicalChatStyle, CloudCanonicalDigest, CloudCanonicalEditPartSnapshot,
        CloudCanonicalEntityKind, CloudCanonicalEnvelope, CloudCanonicalField, CloudCanonicalHash,
        CloudCanonicalKnownMessageFlags, CloudCanonicalMessageAssociation,
        CloudCanonicalMessageEdit, CloudCanonicalMessagePayload, CloudCanonicalMutation,
        CloudCanonicalMutationKind, CloudCanonicalParentReference, CloudCanonicalPayload,
        CloudCanonicalProtectedReference, CloudCanonicalReactionKind, CloudCanonicalReplyReference,
        CloudCanonicalService, CloudCanonicalSnapshot, CloudCanonicalTextRun,
        CloudCanonicalTombstone, CloudCanonicalValidationFailure,
        CLOUD_CANONICAL_MESSAGE_CHAT_ALIAS_KINDS, CLOUD_CANONICAL_SCHEMA_VERSION,
    },
    cloud_sync_semantic_decoder::CloudSemanticIdentifierHasher,
};

const MAX_RAW_FIELDS: usize = 4_096;
const MAX_FIELD_NAME_BYTES: usize = 256;
const MAX_NESTED_PLIST_BYTES: usize = 16 * 1024 * 1024;
const MAX_ATTRIBUTED_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_MESSAGE_SUMMARY_BYTES: usize = 16 * 1024 * 1024;
const MAX_TYPED_STREAM_OBJECTS: usize = 131_072;
const MAX_TYPED_STREAM_FIELDS: usize = 131_072;
const MAX_TYPED_STREAM_EXPANDED_BYTES: usize = 32 * 1024 * 1024;
const MAX_TYPED_STREAM_DEPTH: usize = 64;
const MAX_ATTRIBUTED_BODIES: usize = 4_096;
const MAX_RUNS_PER_BODY: usize = 65_536;
const MAX_ATTRIBUTES_PER_RUN: usize = 256;
const MAX_MESSAGE_EDITS: usize = 65_536;
const MAX_RETRACTED_PARTS: usize = 65_536;
const MAX_CANONICAL_TIMESTAMP_MILLIS: i64 = 253_402_300_799_999;
const APPLE_EPOCH_OFFSET_MILLIS: i64 = 978_307_200_000;
const URL_BALLOON_PROVIDER: &str = "com.apple.messages.URLBalloonProvider";

const TYPED_STREAM_TAG_START: u8 = 0x84;
const TYPED_STREAM_TAG_EMPTY: u8 = 0x85;
const TYPED_STREAM_FIELDS_END: u8 = 0x86;
const TYPED_STREAM_REF_START: usize = 0x92;

#[derive(Clone)]
enum BoundedStreamValue {
    Object(Option<usize>),
    String(String),
    Bool(bool),
    Byte(u8),
    Int(u32, bool),
    Float(f32),
    Double(f64),
    Array(Vec<u8>),
}

enum BoundedStreamObject {
    Class {
        parent: Option<usize>,
        name: String,
    },
    Object {
        class: usize,
        fields: Vec<Vec<BoundedStreamValue>>,
    },
    CString(String),
    Placeholder,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BoundedStreamFailure {
    Malformed,
    Oversized,
}

struct BoundedTypedStreamDecoder<'a> {
    input: &'a [u8],
    offset: usize,
    string_cache: Vec<String>,
    objects: Vec<BoundedStreamObject>,
    field_count: usize,
    expanded_bytes: usize,
}

impl<'a> BoundedTypedStreamDecoder<'a> {
    fn new(input: &'a [u8]) -> Result<Self, BoundedStreamFailure> {
        if input.len() > MAX_ATTRIBUTED_BODY_BYTES {
            return Err(BoundedStreamFailure::Oversized);
        }
        Ok(Self {
            input,
            offset: 0,
            string_cache: Vec::new(),
            objects: Vec::new(),
            field_count: 0,
            expanded_bytes: 0,
        })
    }

    fn charge_bytes(&mut self, count: usize) -> Result<(), BoundedStreamFailure> {
        self.expanded_bytes = self
            .expanded_bytes
            .checked_add(count)
            .ok_or(BoundedStreamFailure::Oversized)?;
        if self.expanded_bytes > MAX_TYPED_STREAM_EXPANDED_BYTES {
            return Err(BoundedStreamFailure::Oversized);
        }
        Ok(())
    }

    fn charge_fields(&mut self, count: usize) -> Result<(), BoundedStreamFailure> {
        self.field_count = self
            .field_count
            .checked_add(count)
            .ok_or(BoundedStreamFailure::Oversized)?;
        if self.field_count > MAX_TYPED_STREAM_FIELDS {
            return Err(BoundedStreamFailure::Oversized);
        }
        Ok(())
    }

    fn reserve_object(&mut self) -> Result<usize, BoundedStreamFailure> {
        if self.objects.len() >= MAX_TYPED_STREAM_OBJECTS {
            return Err(BoundedStreamFailure::Oversized);
        }
        let index = self.objects.len();
        self.objects.push(BoundedStreamObject::Placeholder);
        Ok(index)
    }

    fn read_u8(&mut self) -> Result<u8, BoundedStreamFailure> {
        let value = *self
            .input
            .get(self.offset)
            .ok_or(BoundedStreamFailure::Malformed)?;
        self.offset += 1;
        Ok(value)
    }

    fn read_exact(&mut self, count: usize) -> Result<&'a [u8], BoundedStreamFailure> {
        let end = self
            .offset
            .checked_add(count)
            .ok_or(BoundedStreamFailure::Oversized)?;
        let bytes = self
            .input
            .get(self.offset..end)
            .ok_or(BoundedStreamFailure::Malformed)?;
        self.offset = end;
        Ok(bytes)
    }

    fn read_number(&mut self, tag: Option<u8>) -> Result<u32, BoundedStreamFailure> {
        let tag = tag.map_or_else(|| self.read_u8(), Ok)?;
        match tag {
            0x81 => {
                let bytes: [u8; 2] = self
                    .read_exact(2)?
                    .try_into()
                    .map_err(|_| BoundedStreamFailure::Malformed)?;
                Ok(u16::from_le_bytes(bytes) as u32)
            }
            0x82 => {
                let bytes: [u8; 4] = self
                    .read_exact(4)?
                    .try_into()
                    .map_err(|_| BoundedStreamFailure::Malformed)?;
                Ok(u32::from_le_bytes(bytes))
            }
            0x80..=0x91 => Err(BoundedStreamFailure::Malformed),
            value => Ok(value as u32),
        }
    }

    fn read_float(&mut self) -> Result<f32, BoundedStreamFailure> {
        let tag = self.read_u8()?;
        if tag == 0x83 {
            let bytes: [u8; 4] = self
                .read_exact(4)?
                .try_into()
                .map_err(|_| BoundedStreamFailure::Malformed)?;
            Ok(f32::from_le_bytes(bytes))
        } else {
            self.read_number(Some(tag)).map(|value| value as f32)
        }
    }

    fn read_double(&mut self) -> Result<f64, BoundedStreamFailure> {
        let tag = self.read_u8()?;
        if tag == 0x83 {
            let bytes: [u8; 8] = self
                .read_exact(8)?
                .try_into()
                .map_err(|_| BoundedStreamFailure::Malformed)?;
            Ok(f64::from_le_bytes(bytes))
        } else {
            self.read_number(Some(tag)).map(|value| value as f64)
        }
    }

    fn read_string_raw(&mut self) -> Result<String, BoundedStreamFailure> {
        let length = usize::try_from(self.read_number(None)?)
            .map_err(|_| BoundedStreamFailure::Oversized)?;
        if length > MAX_ATTRIBUTED_BODY_BYTES {
            return Err(BoundedStreamFailure::Oversized);
        }
        self.charge_bytes(length)?;
        String::from_utf8(self.read_exact(length)?.to_vec())
            .map_err(|_| BoundedStreamFailure::Malformed)
    }

    fn read_reference_index(&mut self, tag: u8) -> Result<usize, BoundedStreamFailure> {
        let encoded = usize::try_from(self.read_number(Some(tag))?)
            .map_err(|_| BoundedStreamFailure::Oversized)?;
        encoded
            .checked_sub(TYPED_STREAM_REF_START)
            .ok_or(BoundedStreamFailure::Malformed)
    }

    fn read_string(&mut self, tag: Option<u8>) -> Result<Option<String>, BoundedStreamFailure> {
        let tag = tag.map_or_else(|| self.read_u8(), Ok)?;
        match tag {
            TYPED_STREAM_TAG_START => {
                let string = self.read_string_raw()?;
                if self.string_cache.len() >= MAX_TYPED_STREAM_OBJECTS {
                    return Err(BoundedStreamFailure::Oversized);
                }
                self.string_cache.push(string.clone());
                Ok(Some(string))
            }
            TYPED_STREAM_TAG_EMPTY => Ok(None),
            tag => {
                let index = self.read_reference_index(tag)?;
                let value = self
                    .string_cache
                    .get(index)
                    .ok_or(BoundedStreamFailure::Malformed)?
                    .clone();
                self.charge_bytes(value.len())?;
                Ok(Some(value))
            }
        }
    }

    fn decode_class_list(&mut self, depth: usize) -> Result<Option<usize>, BoundedStreamFailure> {
        if depth > MAX_TYPED_STREAM_DEPTH {
            return Err(BoundedStreamFailure::Oversized);
        }
        match self.read_u8()? {
            TYPED_STREAM_TAG_START => {
                let index = self.reserve_object()?;
                let name = self
                    .read_string(None)?
                    .ok_or(BoundedStreamFailure::Malformed)?;
                if name.is_empty() || name.len() > MAX_FIELD_NAME_BYTES {
                    return Err(BoundedStreamFailure::Malformed);
                }
                let _version = self.read_number(None)?;
                let parent = self.decode_class_list(depth + 1)?;
                self.objects[index] = BoundedStreamObject::Class { parent, name };
                Ok(Some(index))
            }
            TYPED_STREAM_TAG_EMPTY => Ok(None),
            tag => {
                let index = self.read_reference_index(tag)?;
                if !matches!(
                    self.objects.get(index),
                    Some(BoundedStreamObject::Class { .. })
                ) {
                    return Err(BoundedStreamFailure::Malformed);
                }
                Ok(Some(index))
            }
        }
    }

    fn decode_c_string(&mut self) -> Result<Option<usize>, BoundedStreamFailure> {
        match self.read_u8()? {
            TYPED_STREAM_TAG_START => {
                let index = self.reserve_object()?;
                let value = self
                    .read_string(None)?
                    .ok_or(BoundedStreamFailure::Malformed)?;
                self.objects[index] = BoundedStreamObject::CString(value);
                Ok(Some(index))
            }
            TYPED_STREAM_TAG_EMPTY => Ok(None),
            tag => {
                let index = self.read_reference_index(tag)?;
                if !matches!(
                    self.objects.get(index),
                    Some(BoundedStreamObject::CString(_))
                ) {
                    return Err(BoundedStreamFailure::Malformed);
                }
                Ok(Some(index))
            }
        }
    }

    fn decode_object(&mut self, depth: usize) -> Result<Option<usize>, BoundedStreamFailure> {
        if depth > MAX_TYPED_STREAM_DEPTH {
            return Err(BoundedStreamFailure::Oversized);
        }
        match self.read_u8()? {
            TYPED_STREAM_TAG_START => {
                let index = self.reserve_object()?;
                let class = self
                    .decode_class_list(depth + 1)?
                    .ok_or(BoundedStreamFailure::Malformed)?;
                let mut fields = Vec::new();
                loop {
                    let tag = self.read_u8()?;
                    if tag == TYPED_STREAM_FIELDS_END {
                        break;
                    }
                    self.charge_fields(1)?;
                    fields.push(self.decode_type(Some(tag), depth + 1)?);
                }
                self.objects[index] = BoundedStreamObject::Object { class, fields };
                Ok(Some(index))
            }
            TYPED_STREAM_TAG_EMPTY => Ok(None),
            tag => {
                let index = self.read_reference_index(tag)?;
                if !matches!(
                    self.objects.get(index),
                    Some(BoundedStreamObject::Object { .. })
                ) {
                    return Err(BoundedStreamFailure::Malformed);
                }
                Ok(Some(index))
            }
        }
    }

    fn decode_type(
        &mut self,
        tag: Option<u8>,
        depth: usize,
    ) -> Result<Vec<BoundedStreamValue>, BoundedStreamFailure> {
        if depth > MAX_TYPED_STREAM_DEPTH {
            return Err(BoundedStreamFailure::Oversized);
        }
        let type_string = self
            .read_string(tag)?
            .ok_or(BoundedStreamFailure::Malformed)?;
        if type_string.starts_with('[') && type_string.ends_with("c]") {
            let count = type_string[1..type_string.len() - 2]
                .parse::<usize>()
                .map_err(|_| BoundedStreamFailure::Malformed)?;
            if count > MAX_ATTRIBUTED_BODY_BYTES {
                return Err(BoundedStreamFailure::Oversized);
            }
            self.charge_bytes(count)?;
            return Ok(vec![BoundedStreamValue::Array(
                self.read_exact(count)?.to_vec(),
            )]);
        }
        if type_string.len() > MAX_FIELD_NAME_BYTES {
            return Err(BoundedStreamFailure::Oversized);
        }
        self.charge_fields(type_string.len())?;
        let mut values = Vec::with_capacity(type_string.len());
        for kind in type_string.bytes() {
            let value = match kind {
                b'@' => BoundedStreamValue::Object(self.decode_object(depth + 1)?),
                b'+' => BoundedStreamValue::String(self.read_string_raw()?),
                b'*' => BoundedStreamValue::Object(self.decode_c_string()?),
                b'B' => BoundedStreamValue::Bool(match self.read_u8()? {
                    0 => false,
                    1 => true,
                    _ => return Err(BoundedStreamFailure::Malformed),
                }),
                b'C' | b'c' => BoundedStreamValue::Byte(self.read_u8()?),
                b's' | b'i' | b'l' | b'q' | b'S' | b'I' | b'L' | b'Q' => BoundedStreamValue::Int(
                    self.read_number(None)?,
                    matches!(kind, b's' | b'i' | b'l' | b'q'),
                ),
                b'f' => BoundedStreamValue::Float(self.read_float()?),
                b'd' => BoundedStreamValue::Double(self.read_double()?),
                _ => return Err(BoundedStreamFailure::Malformed),
            };
            values.push(value);
        }
        Ok(values)
    }

    fn decode(mut self) -> Result<(Self, Vec<BoundedStreamValue>), BoundedStreamFailure> {
        if self.read_u8()? != 0x04
            || self.read_string_raw()? != "streamtyped"
            || self.read_number(None)? != 1000
        {
            return Err(BoundedStreamFailure::Malformed);
        }
        let values = self.decode_type(None, 0)?;
        if self.offset != self.input.len() {
            return Err(BoundedStreamFailure::Malformed);
        }
        Ok((self, values))
    }

    fn class_name(&self, class: usize) -> Result<&str, BoundedStreamFailure> {
        match self.objects.get(class) {
            Some(BoundedStreamObject::Class { parent, name }) => {
                if let Some(parent) = parent {
                    if !matches!(
                        self.objects.get(*parent),
                        Some(BoundedStreamObject::Class { .. })
                    ) {
                        return Err(BoundedStreamFailure::Malformed);
                    }
                }
                Ok(name)
            }
            _ => Err(BoundedStreamFailure::Malformed),
        }
    }

    fn object_fields(
        &self,
        object: usize,
        accepted_classes: &[&str],
    ) -> Result<&[Vec<BoundedStreamValue>], BoundedStreamFailure> {
        let (class, fields) = match self.objects.get(object) {
            Some(BoundedStreamObject::Object { class, fields }) => (*class, fields),
            _ => return Err(BoundedStreamFailure::Malformed),
        };
        let class_name = self.class_name(class)?;
        if !accepted_classes.contains(&class_name) {
            return Err(BoundedStreamFailure::Malformed);
        }
        Ok(fields)
    }

    fn string_object(&self, value: &BoundedStreamValue) -> Result<String, BoundedStreamFailure> {
        let BoundedStreamValue::Object(Some(object)) = value else {
            return Err(BoundedStreamFailure::Malformed);
        };
        let fields = self.object_fields(*object, &["NSString", "NSMutableString"])?;
        match fields.first().and_then(|field| field.first()) {
            Some(BoundedStreamValue::String(value)) => Ok(value.clone()),
            _ => Err(BoundedStreamFailure::Malformed),
        }
    }

    fn number_object(&self, value: &BoundedStreamValue) -> Result<u32, BoundedStreamFailure> {
        let BoundedStreamValue::Object(Some(object)) = value else {
            return Err(BoundedStreamFailure::Malformed);
        };
        let fields = self.object_fields(*object, &["NSNumber"])?;
        match fields.get(1).and_then(|field| field.first()) {
            Some(BoundedStreamValue::Int(value, _)) => Ok(*value),
            _ => Err(BoundedStreamFailure::Malformed),
        }
    }
}

#[derive(Clone, Default)]
struct DecodedRunAttributes {
    message_part: Option<u32>,
    attachment_guid: Option<String>,
    mention: Option<String>,
    audio_transcript: Option<String>,
    text_effect: Option<i64>,
    bold: Option<bool>,
    italic: Option<bool>,
    strikethrough: Option<bool>,
    underline: Option<bool>,
}

struct DecodedAttributedContent {
    field: CloudCanonicalField<Vec<CloudCanonicalAttributedBody>>,
    maximum_utf16_length: Option<u32>,
}

struct DecodedMessageSummary {
    edits: CloudCanonicalField<Vec<CloudCanonicalMessageEdit>>,
    retracted_parts: CloudCanonicalField<Vec<u32>>,
    edit_snapshots: Vec<CloudCanonicalEditPartSnapshot>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudRawFieldPresence {
    Absent,
    PresentWithoutValue,
    PresentWithValue,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudRawPresenceFailure {
    TooManyFields,
    MalformedFieldIdentifier,
    DuplicateFieldIdentifier,
    FieldNotPresent,
    NestedPayloadTooLarge,
    MalformedNestedPlist,
    NestedPlistIsNotDictionary,
    ExplicitClearWithoutPresence,
}

impl fmt::Display for CloudRawPresenceFailure {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::TooManyFields => "Cloud Sync raw record contains too many fields",
            Self::MalformedFieldIdentifier => "Cloud Sync raw field identifier is malformed",
            Self::DuplicateFieldIdentifier => "Cloud Sync raw field identifier is duplicated",
            Self::FieldNotPresent => "Cloud Sync nested presence source field is absent",
            Self::NestedPayloadTooLarge => "Cloud Sync nested presence payload exceeds its bound",
            Self::MalformedNestedPlist => "Cloud Sync nested presence plist is malformed",
            Self::NestedPlistIsNotDictionary => {
                "Cloud Sync nested presence plist is not a dictionary"
            }
            Self::ExplicitClearWithoutPresence => {
                "Cloud Sync explicit-clear evidence has no matching present field"
            }
        })
    }
}

impl CloudRawPresenceFailure {
    /// Stable, content-free label for canary diagnostics.
    pub(crate) fn diagnostic_code(self) -> &'static str {
        match self {
            Self::TooManyFields => "too_many_fields",
            Self::MalformedFieldIdentifier => "malformed_field_identifier",
            Self::DuplicateFieldIdentifier => "duplicate_field_identifier",
            Self::FieldNotPresent => "field_not_present",
            Self::NestedPayloadTooLarge => "nested_payload_too_large",
            Self::MalformedNestedPlist => "malformed_nested_plist",
            Self::NestedPlistIsNotDictionary => "nested_plist_not_dictionary",
            Self::ExplicitClearWithoutPresence => "explicit_clear_without_presence",
        }
    }
}

impl std::error::Error for CloudRawPresenceFailure {}

/// Content-free presence evidence. Values and decrypted plist payloads are
/// discarded after their field names are captured.
#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudRawRecordPresence {
    fields: HashMap<String, CloudRawFieldPresence>,
    nested_plist_keys: HashMap<String, HashSet<String>>,
    explicit_top_level_clears: HashSet<String>,
    explicit_nested_clears: HashSet<(String, String)>,
    /// Field names CloudKit sent with wire type `EMPTY_LIST`.
    ///
    /// The wire format distinguishes "present but empty" from a field being
    /// absent, and the merge contract depends on that distinction. It was
    /// previously discarded at this boundary, so no live fetch could report
    /// whether Apple emits it at all.
    ///
    /// Recorded as evidence only. No decision reads it, because whether an
    /// empty list means "clear" is precisely the question a live run has to
    /// answer, and inferring a meaning here would repeat the mistake of
    /// inferring one from an empty summary dictionary.
    empty_list_fields: HashSet<String>,
}

impl CloudRawRecordPresence {
    pub(crate) fn extract(record: &Record) -> Result<Self, CloudRawPresenceFailure> {
        if record.record_field.len() > MAX_RAW_FIELDS {
            return Err(CloudRawPresenceFailure::TooManyFields);
        }
        let mut fields = HashMap::with_capacity(record.record_field.len());
        let mut empty_list_fields = HashSet::new();
        for field in &record.record_field {
            let name = field
                .identifier
                .as_ref()
                .and_then(|identifier| identifier.name.as_deref())
                .filter(|name| {
                    !name.is_empty()
                        && name.len() <= MAX_FIELD_NAME_BYTES
                        && !name.chars().any(char::is_control)
                })
                .ok_or(CloudRawPresenceFailure::MalformedFieldIdentifier)?;
            let state = if field.value.is_some() {
                CloudRawFieldPresence::PresentWithValue
            } else {
                CloudRawFieldPresence::PresentWithoutValue
            };
            if field
                .value
                .as_ref()
                .and_then(|value| value.r#type)
                .is_some_and(|kind| kind == CloudKitFieldType::EmptyList as i32)
            {
                empty_list_fields.insert(name.to_owned());
            }
            if fields.insert(name.to_owned(), state).is_some() {
                return Err(CloudRawPresenceFailure::DuplicateFieldIdentifier);
            }
        }
        Ok(Self {
            fields,
            nested_plist_keys: HashMap::new(),
            explicit_top_level_clears: HashSet::new(),
            explicit_nested_clears: HashSet::new(),
            empty_list_fields,
        })
    }

    /// Captures keys from a decrypted, already-decompressed plist dictionary.
    /// Callers handling `cm` must decompress its gzip wrapper before this
    /// boundary. This method retains neither values nor the supplied bytes.
    pub(crate) fn capture_decrypted_plist_dictionary(
        &mut self,
        outer_field: &str,
        decrypted_plist: &[u8],
    ) -> Result<(), CloudRawPresenceFailure> {
        if self.field(outer_field) == CloudRawFieldPresence::Absent {
            return Err(CloudRawPresenceFailure::FieldNotPresent);
        }
        if decrypted_plist.len() > MAX_NESTED_PLIST_BYTES {
            return Err(CloudRawPresenceFailure::NestedPayloadTooLarge);
        }
        let value = PlistValue::from_reader(Cursor::new(decrypted_plist))
            .map_err(|_| CloudRawPresenceFailure::MalformedNestedPlist)?;
        let dictionary = value
            .into_dictionary()
            .ok_or(CloudRawPresenceFailure::NestedPlistIsNotDictionary)?;
        if dictionary.len() > MAX_RAW_FIELDS {
            return Err(CloudRawPresenceFailure::TooManyFields);
        }
        let mut keys = HashSet::with_capacity(dictionary.len());
        for (key, _) in dictionary.into_iter() {
            if key.is_empty()
                || key.len() > MAX_FIELD_NAME_BYTES
                || key.chars().any(char::is_control)
            {
                return Err(CloudRawPresenceFailure::MalformedFieldIdentifier);
            }
            keys.insert(key);
        }
        self.nested_plist_keys.insert(outer_field.to_owned(), keys);
        Ok(())
    }

    pub(crate) fn field(&self, name: &str) -> CloudRawFieldPresence {
        self.fields
            .get(name)
            .copied()
            .unwrap_or(CloudRawFieldPresence::Absent)
    }

    /// Whether CloudKit sent this field as wire type `EMPTY_LIST`.
    ///
    /// Deliberately unused outside tests for now. Surfacing it means adding a
    /// field to the transient DTO, and that DTO must be widened once and
    /// deliberately rather than regenerated for a single diagnostic. It is
    /// recorded as a required item for that widening.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn was_sent_as_empty_list(&self, name: &str) -> bool {
        self.empty_list_fields.contains(name)
    }

    /// Field names sent as `EMPTY_LIST`, sorted, for redacted diagnostics.
    ///
    /// Sorted because the backing set has no stable iteration order and this
    /// is destined for a report that should not vary between runs.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn empty_list_field_names(&self) -> Vec<&str> {
        let mut names: Vec<&str> = self.empty_list_fields.iter().map(String::as_str).collect();
        names.sort_unstable();
        names
    }

    /// Records an authoritative clear marker supplied by a pre-typed decoder.
    /// Raw presence by itself is deliberately insufficient evidence.
    pub(crate) fn mark_top_level_explicit_clear(
        &mut self,
        field: &str,
    ) -> Result<(), CloudRawPresenceFailure> {
        if self.field(field) != CloudRawFieldPresence::PresentWithValue {
            return Err(CloudRawPresenceFailure::ExplicitClearWithoutPresence);
        }
        self.explicit_top_level_clears.insert(field.to_owned());
        Ok(())
    }

    /// Records an authoritative nested clear marker before serde defaults can
    /// erase the distinction.
    pub(crate) fn mark_nested_explicit_clear(
        &mut self,
        outer_field: &str,
        nested_field: &str,
    ) -> Result<(), CloudRawPresenceFailure> {
        if self.nested_field(outer_field, nested_field) != CloudNestedPresence::Present {
            return Err(CloudRawPresenceFailure::ExplicitClearWithoutPresence);
        }
        self.explicit_nested_clears
            .insert((outer_field.to_owned(), nested_field.to_owned()));
        Ok(())
    }

    fn is_top_level_explicit_clear(&self, field: &str) -> bool {
        self.explicit_top_level_clears.contains(field)
    }

    fn is_nested_explicit_clear(&self, outer_field: &str, nested_field: &str) -> bool {
        self.explicit_nested_clears
            .contains(&(outer_field.to_owned(), nested_field.to_owned()))
    }

    fn nested_field(&self, outer_field: &str, nested_field: &str) -> CloudNestedPresence {
        match self.field(outer_field) {
            CloudRawFieldPresence::Absent => CloudNestedPresence::OuterAbsent,
            CloudRawFieldPresence::PresentWithoutValue => CloudNestedPresence::OuterWithoutValue,
            CloudRawFieldPresence::PresentWithValue => self
                .nested_plist_keys
                .get(outer_field)
                .map(|keys| {
                    if keys.contains(nested_field) {
                        CloudNestedPresence::Present
                    } else {
                        CloudNestedPresence::Absent
                    }
                })
                .unwrap_or(CloudNestedPresence::Unavailable),
        }
    }
}

impl Debug for CloudRawRecordPresence {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudRawRecordPresence")
            .field("field_count", &self.fields.len())
            .field("nested_dictionary_count", &self.nested_plist_keys.len())
            .field(
                "explicit_clear_count",
                &(self.explicit_top_level_clears.len() + self.explicit_nested_clears.len()),
            )
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloudNestedPresence {
    OuterAbsent,
    OuterWithoutValue,
    Unavailable,
    Absent,
    Present,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudCanonicalDeferredReason {
    NestedPresenceUnavailable,
    UnprovenEditTimestamp,
    UnsupportedExtensionPayload,
    UnsupportedMediaCredentials,
    UnsupportedGroupPhoto,
    UnsupportedSticker,
    UnsupportedScheduling,
    UnsupportedOffGridMetadata,
    UnsupportedNegativeAttachmentSize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudCanonicalQuarantineReason {
    MalformedRequiredIdentity,
    FieldPresenceMismatch,
    UnsupportedService,
    UnsupportedChatStyle,
    UnsupportedMessageType,
    UnsupportedAssociationType,
    MalformedParent,
    AmbiguousReply,
    MalformedAttributedBody,
    MalformedMessageSummary,
    ConflictingEditAndRetraction,
    OversizedContent,
    InvalidCanonicalPayload,
    MalformedRecord,
}

/// Exact service families intentionally outside the iMessage projection
/// contract. These values are content-free and are emitted only after raw
/// service presence and any nested service assertion agree exactly.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudCanonicalOutOfScopeService {
    SmsFamily,
    Rcs,
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) enum CloudCanonicalConversionOutcome {
    Ready(Box<CloudCanonicalMutation>),
    OutOfScopeService(CloudCanonicalOutOfScopeService),
    Deferred(CloudCanonicalDeferredReason),
    Quarantined(CloudCanonicalQuarantineReason),
}

/// Exact converter branch reached by a retained chat. Every variant is a
/// closed, content-free label; no record value or identifier can enter logs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudChatDiagnosticCode {
    MissingRequiredField,
    MissingGuidField,
    MissingChatIdentifierField,
    MissingGroupIdentifierField,
    MissingOriginalGroupIdentifierField,
    MissingServiceField,
    MissingStyleField,
    MissingParticipantsField,
    UnsupportedService,
    UnsupportedChatStyle,
    EmptyRequiredIdentity,
    EmptyGuid,
    EmptyChatIdentifier,
    EmptyGroupIdentifier,
    EmptyOriginalGroupIdentifier,
    GroupPhotoMissingStableGuid,
    DirectChatGroupPhotoAsset,
    GroupPhotoPresentWithoutValue,
    GroupPhotoPresenceMismatch,
    DisplayNameField,
    LastAddressedHandleField,
    LastAddressedHandleIgnoredUnproven,
    GroupVersionField,
    LastSeenMessageField,
    GroupPhotoGuidField,
    DirectChatGroupPhotoGuid,
    EmptyLegacyGroupIdentifier,
    LogicalIdentityHash,
    AliasHash,
    CanonicalPayload,
    CanonicalBuild,
}

impl CloudChatDiagnosticCode {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::MissingRequiredField => "missing_required_field",
            Self::MissingGuidField => "missing_guid_field",
            Self::MissingChatIdentifierField => "missing_chat_identifier_field",
            Self::MissingGroupIdentifierField => "missing_group_identifier_field",
            Self::MissingOriginalGroupIdentifierField => "missing_original_group_identifier_field",
            Self::MissingServiceField => "missing_service_field",
            Self::MissingStyleField => "missing_style_field",
            Self::MissingParticipantsField => "missing_participants_field",
            Self::UnsupportedService => "unsupported_service",
            Self::UnsupportedChatStyle => "unsupported_chat_style",
            Self::EmptyRequiredIdentity => "empty_required_identity",
            Self::EmptyGuid => "empty_guid",
            Self::EmptyChatIdentifier => "empty_chat_identifier",
            Self::EmptyGroupIdentifier => "empty_group_identifier",
            Self::EmptyOriginalGroupIdentifier => "empty_original_group_identifier",
            Self::GroupPhotoMissingStableGuid => "group_photo_missing_stable_guid",
            Self::DirectChatGroupPhotoAsset => "direct_chat_group_photo_asset",
            Self::GroupPhotoPresentWithoutValue => "group_photo_present_without_value",
            Self::GroupPhotoPresenceMismatch => "group_photo_presence_mismatch",
            Self::DisplayNameField => "display_name_field",
            Self::LastAddressedHandleField => "last_addressed_handle_field",
            Self::LastAddressedHandleIgnoredUnproven => "last_addressed_handle_ignored_unproven",
            Self::GroupVersionField => "group_version_field",
            Self::LastSeenMessageField => "last_seen_message_field",
            Self::GroupPhotoGuidField => "group_photo_guid_field",
            Self::DirectChatGroupPhotoGuid => "direct_chat_group_photo_guid",
            Self::EmptyLegacyGroupIdentifier => "empty_legacy_group_identifier",
            Self::LogicalIdentityHash => "logical_identity_hash",
            Self::AliasHash => "alias_hash",
            Self::CanonicalPayload => "canonical_payload",
            Self::CanonicalBuild => "canonical_build",
        }
    }
}

impl Debug for CloudCanonicalConversionOutcome {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ready(_) => {
                formatter.write_str("CloudCanonicalConversionOutcome::Ready(redacted)")
            }
            Self::OutOfScopeService(service) => formatter
                .debug_tuple("CloudCanonicalConversionOutcome::OutOfScopeService")
                .field(service)
                .finish(),
            Self::Deferred(reason) => formatter
                .debug_tuple("CloudCanonicalConversionOutcome::Deferred")
                .field(reason)
                .finish(),
            Self::Quarantined(reason) => formatter
                .debug_tuple("CloudCanonicalConversionOutcome::Quarantined")
                .field(reason)
                .finish(),
        }
    }
}

pub(crate) struct CloudCanonicalConversionContext<'a> {
    hasher: &'a CloudSemanticIdentifierHasher,
    scope_fingerprint: CloudCanonicalHash,
    zone_fingerprint: CloudCanonicalHash,
    generation: u64,
    change_id: CloudCanonicalHash,
    record_name: &'a str,
    etag: Option<&'a str>,
    server_created_at_millis: Option<i64>,
    server_modified_at_millis: Option<i64>,
    protected_raw_envelope_reference: &'a str,
}

impl<'a> CloudCanonicalConversionContext<'a> {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        hasher: &'a CloudSemanticIdentifierHasher,
        scope_fingerprint: CloudCanonicalHash,
        zone_fingerprint: CloudCanonicalHash,
        generation: u64,
        change_id: CloudCanonicalHash,
        record_name: &'a str,
        etag: Option<&'a str>,
        server_created_at_millis: Option<i64>,
        server_modified_at_millis: Option<i64>,
        protected_raw_envelope_reference: &'a str,
    ) -> Self {
        Self {
            hasher,
            scope_fingerprint,
            zone_fingerprint,
            generation,
            change_id,
            record_name,
            etag,
            server_created_at_millis,
            server_modified_at_millis,
            protected_raw_envelope_reference,
        }
    }
}

impl Debug for CloudCanonicalConversionContext<'_> {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalConversionContext(redacted)")
    }
}

fn require_present(
    presence: &CloudRawRecordPresence,
    fields: &[&str],
) -> Result<(), CloudCanonicalQuarantineReason> {
    if fields
        .iter()
        .all(|field| presence.field(field) == CloudRawFieldPresence::PresentWithValue)
    {
        Ok(())
    } else {
        Err(CloudCanonicalQuarantineReason::MalformedRequiredIdentity)
    }
}

fn top_optional_string(
    presence: &CloudRawRecordPresence,
    field: &str,
    value: &Option<String>,
) -> Result<CloudCanonicalField<String>, CloudCanonicalQuarantineReason> {
    match (presence.field(field), value) {
        (CloudRawFieldPresence::Absent, None) => Ok(CloudCanonicalField::Absent),
        (CloudRawFieldPresence::PresentWithValue, Some(value)) => {
            Ok(CloudCanonicalField::Value(value.clone()))
        }
        (CloudRawFieldPresence::PresentWithValue, None)
            if presence.is_top_level_explicit_clear(field) =>
        {
            Ok(CloudCanonicalField::ExplicitClear)
        }
        (CloudRawFieldPresence::PresentWithValue, None) => {
            Err(CloudCanonicalQuarantineReason::FieldPresenceMismatch)
        }
        (CloudRawFieldPresence::PresentWithoutValue, _) => {
            Err(CloudCanonicalQuarantineReason::MalformedRecord)
        }
        _ => Err(CloudCanonicalQuarantineReason::FieldPresenceMismatch),
    }
}

fn top_default_string(
    presence: &CloudRawRecordPresence,
    field: &str,
    value: &str,
) -> Result<CloudCanonicalField<String>, CloudCanonicalQuarantineReason> {
    match presence.field(field) {
        CloudRawFieldPresence::Absent if value.is_empty() => Ok(CloudCanonicalField::Absent),
        CloudRawFieldPresence::Absent => Err(CloudCanonicalQuarantineReason::FieldPresenceMismatch),
        CloudRawFieldPresence::PresentWithoutValue => {
            Err(CloudCanonicalQuarantineReason::MalformedRecord)
        }
        CloudRawFieldPresence::PresentWithValue
            if value.is_empty() && presence.is_top_level_explicit_clear(field) =>
        {
            Ok(CloudCanonicalField::ExplicitClear)
        }
        CloudRawFieldPresence::PresentWithValue if value.is_empty() => {
            Err(CloudCanonicalQuarantineReason::FieldPresenceMismatch)
        }
        CloudRawFieldPresence::PresentWithValue => Ok(CloudCanonicalField::Value(value.to_owned())),
    }
}

fn nested_optional<T: Clone>(
    presence: &CloudRawRecordPresence,
    outer: &str,
    nested: &str,
    typed_outer_present: bool,
    value: &Option<T>,
) -> Result<CloudCanonicalField<T>, CloudCanonicalConversionOutcome> {
    match presence.nested_field(outer, nested) {
        CloudNestedPresence::OuterAbsent if !typed_outer_present && value.is_none() => {
            Ok(CloudCanonicalField::Absent)
        }
        CloudNestedPresence::OuterAbsent => Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::FieldPresenceMismatch,
        )),
        CloudNestedPresence::OuterWithoutValue => {
            Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord,
            ))
        }
        CloudNestedPresence::Unavailable => Err(CloudCanonicalConversionOutcome::Deferred(
            CloudCanonicalDeferredReason::NestedPresenceUnavailable,
        )),
        CloudNestedPresence::Absent if value.is_none() => Ok(CloudCanonicalField::Absent),
        CloudNestedPresence::Absent => Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::FieldPresenceMismatch,
        )),
        CloudNestedPresence::Present => match value {
            Some(value) => Ok(CloudCanonicalField::Value(value.clone())),
            None if presence.is_nested_explicit_clear(outer, nested) => {
                Ok(CloudCanonicalField::ExplicitClear)
            }
            None => Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::FieldPresenceMismatch,
            )),
        },
    }
}

fn bounded_stream_failure_outcome(
    failure: BoundedStreamFailure,
) -> CloudCanonicalConversionOutcome {
    CloudCanonicalConversionOutcome::Quarantined(match failure {
        BoundedStreamFailure::Malformed => CloudCanonicalQuarantineReason::MalformedAttributedBody,
        BoundedStreamFailure::Oversized => CloudCanonicalQuarantineReason::OversizedContent,
    })
}

fn decode_attribute_dictionary(
    decoder: &BoundedTypedStreamDecoder<'_>,
    value: &BoundedStreamValue,
) -> Result<DecodedRunAttributes, BoundedStreamFailure> {
    let BoundedStreamValue::Object(Some(object)) = value else {
        return Err(BoundedStreamFailure::Malformed);
    };
    let fields = decoder.object_fields(*object, &["NSDictionary", "NSMutableDictionary"])?;
    let count = match fields.first().and_then(|field| field.first()) {
        Some(BoundedStreamValue::Int(value, _)) => {
            usize::try_from(*value).map_err(|_| BoundedStreamFailure::Oversized)?
        }
        _ => return Err(BoundedStreamFailure::Malformed),
    };
    if count > MAX_ATTRIBUTES_PER_RUN
        || fields.len()
            != count
                .checked_mul(2)
                .and_then(|value| value.checked_add(1))
                .ok_or(BoundedStreamFailure::Oversized)?
    {
        return Err(if count > MAX_ATTRIBUTES_PER_RUN {
            BoundedStreamFailure::Oversized
        } else {
            BoundedStreamFailure::Malformed
        });
    }

    let mut decoded = DecodedRunAttributes::default();
    for pair in fields[1..].chunks_exact(2) {
        let key = pair
            .first()
            .and_then(|field| field.first())
            .ok_or(BoundedStreamFailure::Malformed)
            .and_then(|value| decoder.string_object(value))?;
        let value = pair
            .get(1)
            .and_then(|field| field.first())
            .ok_or(BoundedStreamFailure::Malformed)?;
        match key.as_str() {
            "__kIMMessagePartAttributeName" => {
                decoded.message_part = Some(decoder.number_object(value)?);
            }
            "__kIMFileTransferGUIDAttributeName" => {
                decoded.attachment_guid = Some(decoder.string_object(value)?);
            }
            "__kIMMentionConfirmedMention" => {
                decoded.mention = Some(decoder.string_object(value)?);
            }
            "IMAudioTranscription" => {
                decoded.audio_transcript = Some(decoder.string_object(value)?);
            }
            "__kIMTextEffectAttributeName" => {
                decoded.text_effect = Some(i64::from(decoder.number_object(value)?));
            }
            "__kIMTextBoldAttributeName" => {
                decoded.bold = Some(decode_boolean_number(decoder, value)?);
            }
            "__kIMTextItalicAttributeName" => {
                decoded.italic = Some(decode_boolean_number(decoder, value)?);
            }
            "__kIMTextStrikethroughAttributeName" => {
                decoded.strikethrough = Some(decode_boolean_number(decoder, value)?);
            }
            "__kIMTextUnderlineAttributeName" => {
                decoded.underline = Some(decode_boolean_number(decoder, value)?);
            }
            // Unknown attributed-string keys remain available through the
            // protected raw envelope. Projecting known text and runs does not
            // authorize logging or discarding that protected source.
            _ => {}
        }
    }
    Ok(decoded)
}

fn decode_boolean_number(
    decoder: &BoundedTypedStreamDecoder<'_>,
    value: &BoundedStreamValue,
) -> Result<bool, BoundedStreamFailure> {
    match decoder.number_object(value)? {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(BoundedStreamFailure::Malformed),
    }
}

fn attachment_reference_for_run(
    context: &CloudCanonicalConversionContext<'_>,
    message_guid: &str,
    wire_guid: &str,
) -> Result<CloudCanonicalAttachmentReference, CloudCanonicalConversionOutcome> {
    let (canonical_guid, logical_identifier) = match parse_owned_attachment_guid(wire_guid) {
        Ok(owned) => {
            if owned.message_guid() != message_guid {
                return Err(CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedParent,
                ));
            }
            (
                owned.canonical_guid().to_owned(),
                format!("{}\0{}", owned.message_guid(), owned.part()),
            )
        }
        Err(_) if wire_guid.starts_with("at_") => {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedParent,
            ))
        }
        Err(_) => (wire_guid.to_owned(), wire_guid.to_owned()),
    };
    let logical_key_hash = context
        .hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Attachment, &logical_identifier)
        .map_err(validation_quarantine)?;
    CloudCanonicalAttachmentReference::new(canonical_guid, logical_key_hash)
        .map_err(validation_quarantine)
}

fn decode_attributed_body_object(
    context: &CloudCanonicalConversionContext<'_>,
    message_guid: &str,
    decoder: &BoundedTypedStreamDecoder<'_>,
    object: usize,
) -> Result<(CloudCanonicalAttributedBody, u32), CloudCanonicalConversionOutcome> {
    let fields = decoder
        .object_fields(object, &["NSAttributedString", "NSMutableAttributedString"])
        .map_err(bounded_stream_failure_outcome)?;
    let text = fields
        .first()
        .and_then(|field| field.first())
        .ok_or_else(|| bounded_stream_failure_outcome(BoundedStreamFailure::Malformed))
        .and_then(|value| {
            decoder
                .string_object(value)
                .map_err(bounded_stream_failure_outcome)
        })?;
    let utf16_length = u32::try_from(text.encode_utf16().count()).map_err(|_| {
        CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::OversizedContent,
        )
    })?;

    let mut ranges = HashMap::<u32, DecodedRunAttributes>::new();
    let mut runs = Vec::new();
    let mut field_index = 1usize;
    let mut start_utf16 = 0u32;
    while field_index < fields.len() {
        if runs.len() >= MAX_RUNS_PER_BODY {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::OversizedContent,
            ));
        }
        let range_field = fields
            .get(field_index)
            .ok_or_else(|| bounded_stream_failure_outcome(BoundedStreamFailure::Malformed))?;
        let range_id = match range_field.first() {
            Some(BoundedStreamValue::Int(value, _)) => *value,
            _ => {
                return Err(bounded_stream_failure_outcome(
                    BoundedStreamFailure::Malformed,
                ))
            }
        };
        let length_utf16 = match range_field.get(1) {
            Some(BoundedStreamValue::Int(value, _)) => *value,
            _ => {
                return Err(bounded_stream_failure_outcome(
                    BoundedStreamFailure::Malformed,
                ))
            }
        };
        field_index += 1;
        let attributes = if let Some(cached) = ranges.get(&range_id) {
            cached.clone()
        } else {
            let dictionary = fields
                .get(field_index)
                .and_then(|field| field.first())
                .ok_or_else(|| bounded_stream_failure_outcome(BoundedStreamFailure::Malformed))?;
            field_index += 1;
            let decoded = decode_attribute_dictionary(decoder, dictionary)
                .map_err(bounded_stream_failure_outcome)?;
            ranges.insert(range_id, decoded.clone());
            decoded
        };
        let attachment = match attributes.attachment_guid.as_deref() {
            Some(guid) => Some(attachment_reference_for_run(context, message_guid, guid)?),
            None => None,
        };
        let run = CloudCanonicalTextRun::new(
            start_utf16,
            length_utf16,
            attributes.message_part,
            attachment,
            attributes.mention,
            attributes.audio_transcript,
            attributes.text_effect,
            attributes.bold,
            attributes.italic,
            attributes.strikethrough,
            attributes.underline,
        )
        .map_err(validation_quarantine)?;
        start_utf16 = start_utf16.checked_add(length_utf16).ok_or({
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedAttributedBody,
            )
        })?;
        runs.push(run);
    }
    let body = CloudCanonicalAttributedBody::new(text, runs).map_err(validation_quarantine)?;
    Ok((body, utf16_length))
}

fn decode_attributed_content(
    context: &CloudCanonicalConversionContext<'_>,
    message_guid: &str,
    raw: Option<&[u8]>,
) -> Result<DecodedAttributedContent, CloudCanonicalConversionOutcome> {
    let Some(raw) = raw else {
        return Ok(DecodedAttributedContent {
            field: CloudCanonicalField::Absent,
            maximum_utf16_length: None,
        });
    };
    if raw.is_empty() {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedAttributedBody,
        ));
    }
    let (decoder, values) = BoundedTypedStreamDecoder::new(raw)
        .and_then(BoundedTypedStreamDecoder::decode)
        .map_err(bounded_stream_failure_outcome)?;
    if values.len() > MAX_ATTRIBUTED_BODIES {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::OversizedContent,
        ));
    }
    if values.is_empty() {
        return Ok(DecodedAttributedContent {
            field: CloudCanonicalField::ExplicitClear,
            maximum_utf16_length: Some(0),
        });
    }
    let mut bodies = Vec::with_capacity(values.len());
    let mut maximum_utf16_length = 0u32;
    for value in values {
        let BoundedStreamValue::Object(Some(object)) = value else {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedAttributedBody,
            ));
        };
        let (body, utf16_length) =
            decode_attributed_body_object(context, message_guid, &decoder, object)?;
        maximum_utf16_length = maximum_utf16_length.max(utf16_length);
        bodies.push(body);
    }
    Ok(DecodedAttributedContent {
        field: CloudCanonicalField::Value(bodies),
        maximum_utf16_length: Some(maximum_utf16_length),
    })
}

fn parse_decimal_part(value: &str) -> Option<u32> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        return None;
    }
    let part = value.parse::<u32>().ok()?;
    (part.to_string() == value).then_some(part)
}

fn validated_edit_timestamp(value: f64) -> Result<i64, CloudCanonicalConversionOutcome> {
    if !value.is_finite() || value < 0.0 || value > MAX_CANONICAL_TIMESTAMP_MILLIS as f64 {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        ));
    }
    if value.fract() != 0.0 || value < APPLE_EPOCH_OFFSET_MILLIS as f64 {
        return Err(CloudCanonicalConversionOutcome::Deferred(
            CloudCanonicalDeferredReason::UnprovenEditTimestamp,
        ));
    }
    Ok(value as i64)
}

fn decode_message_summary(
    context: &CloudCanonicalConversionContext<'_>,
    message_guid: &str,
    raw: Option<&[u8]>,
    original_maximum_utf16_length: Option<u32>,
) -> Result<DecodedMessageSummary, CloudCanonicalConversionOutcome> {
    let Some(raw) = raw else {
        return Ok(DecodedMessageSummary {
            edits: CloudCanonicalField::Absent,
            retracted_parts: CloudCanonicalField::Absent,
            edit_snapshots: Vec::new(),
        });
    };
    if raw.is_empty() {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        ));
    }
    if raw.len() > MAX_MESSAGE_SUMMARY_BYTES {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::OversizedContent,
        ));
    }
    let raw_value = PlistValue::from_reader(Cursor::new(raw)).map_err(|_| {
        CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        )
    })?;
    let raw_dictionary =
        raw_value
            .as_dictionary()
            .ok_or(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedMessageSummary,
            ))?;
    if raw_dictionary.len() > MAX_RAW_FIELDS {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::OversizedContent,
        ));
    }
    let edit_state_present = ["ec", "ep", "otr"]
        .iter()
        .any(|key| raw_dictionary.contains_key(key));
    let retraction_state_present = raw_dictionary.contains_key("rp");
    let summary: MessageSummaryInfo = plist::from_bytes(raw).map_err(|_| {
        CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        )
    })?;
    // This projection owns only edit history, original edit ranges, and
    // retractions. Other summary keys (including associated-message and
    // extension metadata) and each edit's `bcg` remain losslessly reachable
    // through the protected raw envelope reference for a later schema.
    if summary.ec.len() > MAX_MESSAGE_EDITS
        || summary.ep.len() > MAX_MESSAGE_EDITS
        || summary.otr.len() > MAX_MESSAGE_EDITS
        || summary.rp.len() > MAX_RETRACTED_PARTS
    {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::OversizedContent,
        ));
    }

    let mut declared_edit_parts = summary.ep;
    declared_edit_parts.sort_unstable();
    declared_edit_parts.dedup();
    let declared_edit_parts = declared_edit_parts.into_iter().collect::<HashSet<_>>();

    let mut encoded_parts = Vec::with_capacity(summary.ec.len());
    for (wire_part, wire_edits) in summary.ec {
        let part =
            parse_decimal_part(&wire_part).ok_or(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedMessageSummary,
            ))?;
        if wire_edits.is_empty() || wire_edits.len() > MAX_MESSAGE_EDITS {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedMessageSummary,
            ));
        }
        encoded_parts.push((part, wire_edits));
    }
    encoded_parts.sort_unstable_by_key(|(part, _)| *part);
    if encoded_parts
        .windows(2)
        .any(|window| window[0].0 == window[1].0)
    {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        ));
    }
    let encoded_part_set = encoded_parts
        .iter()
        .map(|(part, _)| *part)
        .collect::<HashSet<_>>();
    if encoded_part_set != declared_edit_parts {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        ));
    }

    let mut original_ranges = HashMap::with_capacity(summary.otr.len());
    for (wire_part, range) in summary.otr {
        let part =
            parse_decimal_part(&wire_part).ok_or(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedMessageSummary,
            ))?;
        if !declared_edit_parts.contains(&part)
            || range.lo.checked_add(range.le).is_none()
            || original_maximum_utf16_length.is_some_and(|maximum| {
                range
                    .lo
                    .checked_add(range.le)
                    .is_none_or(|end| end > maximum)
            })
            || original_ranges.insert(part, (range.lo, range.le)).is_some()
        {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedMessageSummary,
            ));
        }
    }

    let mut retracted_parts = summary.rp;
    retracted_parts.sort_unstable();
    retracted_parts.dedup();
    if retracted_parts
        .iter()
        .any(|part| declared_edit_parts.contains(part))
    {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::ConflictingEditAndRetraction,
        ));
    }

    struct PreparedEdit {
        bodies: Vec<CloudCanonicalAttributedBody>,
        modified_at_millis: i64,
        content_digest: CloudCanonicalDigest,
    }

    let mut canonical_edits = Vec::new();
    let mut edit_snapshots = Vec::new();
    for (part, wire_edits) in encoded_parts {
        let part_key_hash = context
            .hasher
            .canonical_entity_key_hash(
                CloudCanonicalEntityKind::Message,
                &format!("{message_guid}\0{part}"),
            )
            .map_err(validation_quarantine)?;
        let mut prepared = Vec::with_capacity(wire_edits.len());
        for wire_edit in wire_edits {
            let modified_at_millis = validated_edit_timestamp(wire_edit.d)?;
            let content_digest = sha256_digest(&[&wire_edit.t]).map_err(validation_quarantine)?;
            let decoded =
                decode_attributed_content(context, message_guid, Some(wire_edit.t.as_slice()))?;
            let bodies = match decoded.field {
                CloudCanonicalField::Value(bodies) if !bodies.is_empty() => bodies,
                CloudCanonicalField::Absent
                | CloudCanonicalField::ExplicitClear
                | CloudCanonicalField::Value(_) => {
                    return Err(CloudCanonicalConversionOutcome::Quarantined(
                        CloudCanonicalQuarantineReason::MalformedMessageSummary,
                    ))
                }
            };
            prepared.push(PreparedEdit {
                bodies,
                modified_at_millis,
                content_digest,
            });
        }
        prepared.sort_by(|left, right| {
            left.modified_at_millis
                .cmp(&right.modified_at_millis)
                .then_with(|| {
                    left.content_digest
                        .value()
                        .cmp(right.content_digest.value())
                })
        });
        prepared.dedup_by(|left, right| {
            left.modified_at_millis == right.modified_at_millis
                && left.content_digest == right.content_digest
        });
        for (revision_index, edit) in prepared.into_iter().enumerate() {
            let revision = u32::try_from(revision_index).map_err(|_| {
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::OversizedContent,
                )
            })?;
            edit_snapshots.push(CloudCanonicalEditPartSnapshot::new(
                part_key_hash.clone(),
                revision,
                edit.content_digest.clone(),
                edit.modified_at_millis,
            ));
            canonical_edits.push(
                CloudCanonicalMessageEdit::new(
                    part,
                    revision,
                    edit.bodies,
                    edit.modified_at_millis,
                    original_ranges.get(&part).copied(),
                )
                .map_err(validation_quarantine)?,
            );
        }
    }
    if canonical_edits.len() > MAX_MESSAGE_EDITS || edit_snapshots.len() > MAX_MESSAGE_EDITS {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::OversizedContent,
        ));
    }

    // A present-but-empty edit collection is not a clear instruction. Apple's
    // summary plist omits empty collections rather than sending them, so this
    // shape carries no meaning we can act on, and treating it as "clear every
    // edit" would wipe local edit history on a guess.
    //
    // This also brings the summary path in line with the record-level rule in
    // this same file, where a clear requires an authoritative marker from a
    // pre-typed decoder and raw presence alone is deliberately insufficient.
    let edits = if edit_state_present {
        if canonical_edits.is_empty() {
            CloudCanonicalField::Absent
        } else {
            CloudCanonicalField::Value(canonical_edits)
        }
    } else if canonical_edits.is_empty() {
        CloudCanonicalField::Absent
    } else {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        ));
    };
    // Same reasoning as the edit collection above: an empty retraction list is
    // not an instruction to un-retract every part.
    let retracted_parts = if retraction_state_present {
        if retracted_parts.is_empty() {
            CloudCanonicalField::Absent
        } else {
            CloudCanonicalField::Value(retracted_parts)
        }
    } else if retracted_parts.is_empty() {
        CloudCanonicalField::Absent
    } else {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedMessageSummary,
        ));
    };
    Ok(DecodedMessageSummary {
        edits,
        retracted_parts,
        edit_snapshots,
    })
}

fn sha256_digest(parts: &[&[u8]]) -> Result<CloudCanonicalDigest, CloudCanonicalValidationFailure> {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update((part.len() as u64).to_be_bytes());
        hasher.update(part);
    }
    let hex = hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    CloudCanonicalDigest::new(hex)
}

fn etag_hash(
    hasher: &CloudSemanticIdentifierHasher,
    etag: Option<&str>,
) -> Result<Option<CloudCanonicalHash>, CloudCanonicalValidationFailure> {
    etag.map(|value| hasher.canonical_etag_hash(value))
        .transpose()
}

fn protected_reference(
    context: &CloudCanonicalConversionContext<'_>,
) -> Result<CloudCanonicalProtectedReference, CloudCanonicalQuarantineReason> {
    CloudCanonicalProtectedReference::new(context.protected_raw_envelope_reference)
        .map_err(|_| CloudCanonicalQuarantineReason::MalformedRecord)
}

fn validation_quarantine(_: CloudCanonicalValidationFailure) -> CloudCanonicalConversionOutcome {
    CloudCanonicalConversionOutcome::Quarantined(
        CloudCanonicalQuarantineReason::InvalidCanonicalPayload,
    )
}

#[allow(clippy::too_many_arguments)]
fn build_upsert(
    context: &CloudCanonicalConversionContext<'_>,
    entity_kind: CloudCanonicalEntityKind,
    logical_entity_key_hash: CloudCanonicalHash,
    parent_logical_key_hash: Option<CloudCanonicalHash>,
    aliases: Vec<CloudCanonicalAlias>,
    payload: CloudCanonicalPayload,
    immutable_content_digest: Option<CloudCanonicalDigest>,
    created_at_millis: Option<i64>,
    read_at_millis: Option<i64>,
    delivered_at_millis: Option<i64>,
    edit_parts: Vec<CloudCanonicalEditPartSnapshot>,
    group_version: Option<u32>,
) -> CloudCanonicalConversionOutcome {
    let protected = match protected_reference(context) {
        Ok(value) => value,
        Err(reason) => return CloudCanonicalConversionOutcome::Quarantined(reason),
    };
    let server_record_id_hash = match context
        .hasher
        .canonical_server_record_id_hash(context.record_name)
    {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let etag_hash = match etag_hash(context.hasher, context.etag) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let envelope = match CloudCanonicalEnvelope::new(
        context.scope_fingerprint.clone(),
        context.zone_fingerprint.clone(),
        context.generation,
        CLOUD_CANONICAL_SCHEMA_VERSION,
        context.change_id.clone(),
        entity_kind,
        CloudCanonicalMutationKind::Upsert,
        server_record_id_hash,
        logical_entity_key_hash.clone(),
        parent_logical_key_hash.clone(),
        aliases,
        etag_hash.clone(),
        context.server_created_at_millis,
        context.server_modified_at_millis,
        protected.clone(),
    ) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let snapshot = match CloudCanonicalSnapshot::new(
        entity_kind,
        logical_entity_key_hash,
        parent_logical_key_hash,
        immutable_content_digest,
        created_at_millis,
        read_at_millis,
        delivered_at_millis,
        edit_parts,
        None,
        group_version,
        None,
        etag_hash,
        protected,
    ) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    CloudCanonicalMutation::new(envelope, Some(snapshot), Some(payload), None)
        .map(Box::new)
        .map(CloudCanonicalConversionOutcome::Ready)
        .unwrap_or_else(validation_quarantine)
}

pub(crate) fn convert_chat(
    context: &CloudCanonicalConversionContext<'_>,
    presence: &CloudRawRecordPresence,
    chat: &CloudChat,
) -> CloudCanonicalConversionOutcome {
    let mut diagnostic = None;
    convert_chat_internal(context, presence, chat, &mut diagnostic)
}

pub(crate) fn convert_chat_with_diagnostic(
    context: &CloudCanonicalConversionContext<'_>,
    presence: &CloudRawRecordPresence,
    chat: &CloudChat,
) -> (
    CloudCanonicalConversionOutcome,
    Option<CloudChatDiagnosticCode>,
) {
    let mut diagnostic = None;
    let outcome = convert_chat_internal(context, presence, chat, &mut diagnostic);
    (outcome, diagnostic)
}

fn chat_diagnostic(
    diagnostic: &mut Option<CloudChatDiagnosticCode>,
    code: CloudChatDiagnosticCode,
    outcome: CloudCanonicalConversionOutcome,
) -> CloudCanonicalConversionOutcome {
    *diagnostic = Some(code);
    outcome
}

fn missing_chat_required_field(
    presence: &CloudRawRecordPresence,
) -> Option<CloudChatDiagnosticCode> {
    [
        ("guid", CloudChatDiagnosticCode::MissingGuidField),
        ("cid", CloudChatDiagnosticCode::MissingChatIdentifierField),
        ("gid", CloudChatDiagnosticCode::MissingGroupIdentifierField),
        (
            "ogid",
            CloudChatDiagnosticCode::MissingOriginalGroupIdentifierField,
        ),
        ("svc", CloudChatDiagnosticCode::MissingServiceField),
        ("stl", CloudChatDiagnosticCode::MissingStyleField),
        ("ptcpts", CloudChatDiagnosticCode::MissingParticipantsField),
    ]
    .into_iter()
    .find_map(|(field, code)| {
        (presence.field(field) != CloudRawFieldPresence::PresentWithValue).then_some(code)
    })
}

fn empty_chat_required_identity(chat: &CloudChat) -> Option<CloudChatDiagnosticCode> {
    [
        (&chat.guid, CloudChatDiagnosticCode::EmptyGuid),
        (
            &chat.chat_identifier,
            CloudChatDiagnosticCode::EmptyChatIdentifier,
        ),
        (
            &chat.group_id,
            CloudChatDiagnosticCode::EmptyGroupIdentifier,
        ),
        (
            &chat.original_group_id,
            CloudChatDiagnosticCode::EmptyOriginalGroupIdentifier,
        ),
    ]
    .into_iter()
    .find_map(|(value, code)| value.is_empty().then_some(code))
}

fn convert_chat_internal(
    context: &CloudCanonicalConversionContext<'_>,
    presence: &CloudRawRecordPresence,
    chat: &CloudChat,
    diagnostic: &mut Option<CloudChatDiagnosticCode>,
) -> CloudCanonicalConversionOutcome {
    if let Some(code) = missing_chat_required_field(presence) {
        return chat_diagnostic(
            diagnostic,
            code,
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
            ),
        );
    }
    let service = match chat.service_name.as_str() {
        "iMessage" => CloudCanonicalService::IMessage,
        // Messages retain the service used when sent, but CloudChat reflects
        // the conversation's current route. Keep SMS chat metadata so a
        // historical iMessage can resolve its authenticated group container;
        // SMS message bodies remain explicitly outside this projection.
        "SMS" => CloudCanonicalService::Sms,
        "RCS" => {
            if let Some(code) = empty_chat_required_identity(chat) {
                return chat_diagnostic(
                    diagnostic,
                    code,
                    CloudCanonicalConversionOutcome::Quarantined(
                        CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
                    ),
                );
            }
            return CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::Rcs,
            );
        }
        _ => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::UnsupportedService,
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedService,
                ),
            )
        }
    };
    let style = match chat.style {
        45 => CloudCanonicalChatStyle::Direct,
        43 => CloudCanonicalChatStyle::Group,
        _ => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::UnsupportedChatStyle,
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedChatStyle,
                ),
            )
        }
    };
    if let Some(code) = empty_chat_required_identity(chat) {
        return chat_diagnostic(
            diagnostic,
            code,
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
            ),
        );
    }
    match (presence.field("gp"), chat.group_photo.is_some()) {
        (CloudRawFieldPresence::Absent, false) => {}
        (CloudRawFieldPresence::PresentWithValue, true)
            if style == CloudCanonicalChatStyle::Group
                && chat
                    .group_photo_guid
                    .as_deref()
                    .is_some_and(|guid| !guid.is_empty()) =>
        {
            // The asset remains N0 behind the protected envelope reference.
            // Only its independently supplied stable GUID is projected.
        }
        (CloudRawFieldPresence::PresentWithValue, true) => {
            let code = if style == CloudCanonicalChatStyle::Direct {
                CloudChatDiagnosticCode::DirectChatGroupPhotoAsset
            } else {
                CloudChatDiagnosticCode::GroupPhotoMissingStableGuid
            };
            return chat_diagnostic(
                diagnostic,
                code,
                CloudCanonicalConversionOutcome::Deferred(
                    CloudCanonicalDeferredReason::UnsupportedGroupPhoto,
                ),
            );
        }
        (CloudRawFieldPresence::PresentWithValue, false)
            if presence.is_top_level_explicit_clear("gp") => {}
        (CloudRawFieldPresence::PresentWithoutValue, _) => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::GroupPhotoPresentWithoutValue,
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedRecord,
                ),
            )
        }
        _ => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::GroupPhotoPresenceMismatch,
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::FieldPresenceMismatch,
                ),
            )
        }
    }

    let display_name = match top_optional_string(presence, "name", &chat.display_name) {
        Ok(value) => value,
        Err(reason) => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::DisplayNameField,
                CloudCanonicalConversionOutcome::Quarantined(reason),
            )
        }
    };
    let last_addressed_handle =
        match top_default_string(presence, "lah", &chat.last_addressed_handle) {
            Ok(value) => value,
            // `lah` is optional routing metadata, not chat identity. The wire
            // decoder supplies a default string, so a raw/typed disagreement
            // cannot prove a value or a clear. Preserve the chat and its
            // aliases while discarding only this unproven field.
            Err(CloudCanonicalQuarantineReason::FieldPresenceMismatch) => {
                *diagnostic = Some(CloudChatDiagnosticCode::LastAddressedHandleIgnoredUnproven);
                CloudCanonicalField::Absent
            }
            Err(reason) => {
                return chat_diagnostic(
                    diagnostic,
                    CloudChatDiagnosticCode::LastAddressedHandleField,
                    CloudCanonicalConversionOutcome::Quarantined(reason),
                )
            }
        };
    let typed_properties_present = chat.properties.is_some();
    let properties = chat.properties.as_ref();
    let group_version = match nested_optional(
        presence,
        "prop",
        "pv",
        typed_properties_present,
        &properties.and_then(|value| value.pv),
    ) {
        Ok(value) => value,
        Err(outcome) => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::GroupVersionField,
                outcome,
            )
        }
    };
    let last_seen_message_guid = match nested_optional(
        presence,
        "prop",
        "lastSeenMessageGuid",
        typed_properties_present,
        &properties.and_then(|value| value.last_seen_message_guid.clone()),
    ) {
        Ok(value) => value,
        Err(outcome) => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::LastSeenMessageField,
                outcome,
            )
        }
    };
    let group_photo_guid = match top_optional_string(presence, "gpid", &chat.group_photo_guid) {
        Ok(value) => value,
        Err(reason) => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::GroupPhotoGuidField,
                CloudCanonicalConversionOutcome::Quarantined(reason),
            )
        }
    };
    if style == CloudCanonicalChatStyle::Direct
        && !matches!(group_photo_guid, CloudCanonicalField::Absent)
    {
        return chat_diagnostic(
            diagnostic,
            CloudChatDiagnosticCode::DirectChatGroupPhotoGuid,
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord,
            ),
        );
    }

    let logical_hash = match context
        .hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, &chat.guid)
    {
        Ok(value) => value,
        Err(error) => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::LogicalIdentityHash,
                validation_quarantine(error),
            )
        }
    };
    let mut aliases = Vec::new();
    let mut alias_keys = HashSet::new();
    let mut add_alias = |kind: CloudCanonicalAliasKind,
                         value: &str|
     -> Result<(), CloudCanonicalValidationFailure> {
        let hash = context.hasher.canonical_alias_key_hash(kind, value)?;
        if alias_keys.insert((kind, hash.value().to_owned())) {
            aliases.push(CloudCanonicalAlias::new(kind, hash));
        }
        Ok(())
    };
    for (kind, value) in [
        (CloudCanonicalAliasKind::ChatGroupId, chat.group_id.as_str()),
        (
            CloudCanonicalAliasKind::ChatOriginalGroupId,
            chat.original_group_id.as_str(),
        ),
        (
            CloudCanonicalAliasKind::ChatServiceIdentifier,
            chat.chat_identifier.as_str(),
        ),
    ] {
        if let Err(error) = add_alias(kind, value) {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::AliasHash,
                validation_quarantine(error),
            );
        }
    }
    if let Some(properties) = properties {
        for legacy in &properties.legacy_group_identifiers {
            if legacy.is_empty() {
                return chat_diagnostic(
                    diagnostic,
                    CloudChatDiagnosticCode::EmptyLegacyGroupIdentifier,
                    CloudCanonicalConversionOutcome::Quarantined(
                        CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
                    ),
                );
            }
            if let Err(error) =
                add_alias(CloudCanonicalAliasKind::ChatLegacyGroupIdentifier, legacy)
            {
                return chat_diagnostic(
                    diagnostic,
                    CloudChatDiagnosticCode::AliasHash,
                    validation_quarantine(error),
                );
            }
        }
    }

    let group_version_snapshot = match &group_version {
        CloudCanonicalField::Value(value) => Some(*value),
        CloudCanonicalField::Absent | CloudCanonicalField::ExplicitClear => None,
    };
    let payload = match CloudCanonicalChatPayload::new(
        chat.guid.clone(),
        chat.chat_identifier.clone(),
        chat.group_id.clone(),
        chat.original_group_id.clone(),
        service,
        style,
        chat.participants
            .iter()
            .map(|participant| participant.uri.clone())
            .collect(),
        display_name,
        last_addressed_handle,
        group_version,
        last_seen_message_guid,
        group_photo_guid,
    ) {
        Ok(value) => value,
        Err(error) => {
            return chat_diagnostic(
                diagnostic,
                CloudChatDiagnosticCode::CanonicalPayload,
                validation_quarantine(error),
            )
        }
    };
    let outcome = build_upsert(
        context,
        CloudCanonicalEntityKind::Chat,
        logical_hash,
        None,
        aliases,
        CloudCanonicalPayload::Chat(Box::new(payload)),
        None,
        None,
        None,
        None,
        vec![],
        group_version_snapshot,
    );
    if matches!(&outcome, CloudCanonicalConversionOutcome::Ready(_)) {
        outcome
    } else {
        chat_diagnostic(diagnostic, CloudChatDiagnosticCode::CanonicalBuild, outcome)
    }
}

fn apple_nanos_to_unix_millis(value: u64) -> Option<i64> {
    let millis = i64::try_from(value / 1_000_000).ok()?;
    APPLE_EPOCH_OFFSET_MILLIS.checked_add(millis)
}

fn proto_string(value: &Option<String>) -> CloudCanonicalField<String> {
    value
        .clone()
        .map(CloudCanonicalField::Value)
        .unwrap_or(CloudCanonicalField::Absent)
}

fn proto_timestamp(
    value: Option<u64>,
) -> Result<CloudCanonicalField<i64>, CloudCanonicalQuarantineReason> {
    match value {
        None => Ok(CloudCanonicalField::Absent),
        Some(0) => Ok(CloudCanonicalField::ExplicitClear),
        Some(value) => apple_nanos_to_unix_millis(value)
            .map(CloudCanonicalField::Value)
            .ok_or(CloudCanonicalQuarantineReason::MalformedRecord),
    }
}

fn reaction_kind(index: u32) -> Option<CloudCanonicalReactionKind> {
    match index {
        0 => Some(CloudCanonicalReactionKind::Heart),
        1 => Some(CloudCanonicalReactionKind::Like),
        2 => Some(CloudCanonicalReactionKind::Dislike),
        3 => Some(CloudCanonicalReactionKind::Laugh),
        4 => Some(CloudCanonicalReactionKind::Emphasize),
        5 => Some(CloudCanonicalReactionKind::Question),
        6 => Some(CloudCanonicalReactionKind::Emoji),
        7 => Some(CloudCanonicalReactionKind::StickerBack),
        _ => None,
    }
}

fn build_association(
    context: &CloudCanonicalConversionContext<'_>,
    message_type: i64,
    proto: &MessageProto,
) -> Result<
    (
        CloudCanonicalMessageAssociation,
        CloudCanonicalEntityKind,
        Option<CloudCanonicalHash>,
    ),
    CloudCanonicalConversionOutcome,
> {
    // MessageEncryptedV3.msgType selects the outer record class. Live Apple
    // records and the native decoder both treat 0, 1, and 2 as members of the
    // same message family. Association semantics are carried independently by
    // MessageProto.associated_message_type, so requiring msgType == 2 here
    // orphaned valid reactions whose outer class was 0 or 1.
    if !matches!(message_type, 0..=2) {
        return Err(CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::UnsupportedMessageType,
        ));
    }

    let Some(associated_type) = proto.associated_message_type else {
        if proto.associated_message_guid.is_some()
            || proto.associated_message_range_location.is_some()
            || proto.associated_message_range_length.is_some()
        {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedParent,
            ));
        }
        return Ok((
            CloudCanonicalMessageAssociation::None,
            CloudCanonicalEntityKind::Message,
            None,
        ));
    };
    if associated_type == 0 {
        // Treat explicit zero as the standalone-message sentinel only in the
        // unambiguous shape observed on normal messages. A parent or any
        // non-zero/partial range remains malformed.
        let range_is_standalone = matches!(
            (
                proto.associated_message_range_location,
                proto.associated_message_range_length,
            ),
            (None, None) | (Some(0), Some(0))
        );
        if proto.associated_message_guid.is_some() || !range_is_standalone {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedParent,
            ));
        }
        return Ok((
            CloudCanonicalMessageAssociation::None,
            CloudCanonicalEntityKind::Message,
            None,
        ));
    }
    if associated_type == 2 {
        return Err(CloudCanonicalConversionOutcome::Deferred(
            CloudCanonicalDeferredReason::UnsupportedSticker,
        ));
    }

    let (remove, index) = match associated_type {
        2000..=2007 => (false, associated_type - 2000),
        3000..=3007 => (true, associated_type - 3000),
        _ => {
            return Err(CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::UnsupportedAssociationType,
            ))
        }
    };
    let kind = reaction_kind(index).ok_or(CloudCanonicalConversionOutcome::Quarantined(
        CloudCanonicalQuarantineReason::UnsupportedAssociationType,
    ))?;
    if kind == CloudCanonicalReactionKind::StickerBack {
        return Err(CloudCanonicalConversionOutcome::Deferred(
            CloudCanonicalDeferredReason::UnsupportedSticker,
        ));
    }
    let parent_wire = proto.associated_message_guid.as_deref().ok_or(
        CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedParent,
        ),
    )?;
    let parsed = parse_associated_parent(parent_wire).map_err(|_| {
        CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedParent,
        )
    })?;
    let parent_hash = context
        .hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, parsed.parent_guid())
        .map_err(validation_quarantine)?;
    let parent = CloudCanonicalParentReference::new(
        parsed.parent_guid().to_owned(),
        parsed.parent_part(),
        parent_hash.clone(),
        proto.associated_message_range_location,
        proto.associated_message_range_length,
    )
    .map_err(validation_quarantine)?;
    let association = if remove {
        CloudCanonicalMessageAssociation::ReactionRemove { kind, parent }
    } else {
        CloudCanonicalMessageAssociation::ReactionAdd { kind, parent }
    };
    Ok((
        association,
        CloudCanonicalEntityKind::Reaction,
        Some(parent_hash),
    ))
}

fn build_reply(
    context: &CloudCanonicalConversionContext<'_>,
    proto_2: Option<&MessageProto2>,
) -> Result<Option<CloudCanonicalReplyReference>, CloudCanonicalConversionOutcome> {
    let Some(reply) = proto_2.and_then(|value| value.reply.as_deref()) else {
        return Ok(None);
    };
    let parsed = parse_reply_parent(reply).map_err(|error| {
        CloudCanonicalConversionOutcome::Quarantined(match error {
            CloudCanonicalValidationFailure::AmbiguousReplyParent => {
                CloudCanonicalQuarantineReason::AmbiguousReply
            }
            _ => CloudCanonicalQuarantineReason::MalformedParent,
        })
    })?;
    let parent_hash = context
        .hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, parsed.parent_guid())
        .map_err(validation_quarantine)?;
    CloudCanonicalReplyReference::new(
        parsed.parent_guid().to_owned(),
        parsed.parent_part().to_owned(),
        parent_hash,
    )
    .map(Some)
    .map_err(validation_quarantine)
}

fn reject_unsupported_message_content(
    proto: &MessageProto,
    proto_4: Option<&MessageProto4>,
    service: CloudCanonicalService,
) -> Option<CloudCanonicalConversionOutcome> {
    // A URL balloon's ordinary text is independently usable even though V2
    // does not yet decode Apple's embedded RichLink payload. Keep the bytes in
    // the protected source envelope, project only the base message, and leave
    // every other extension fail-closed.
    let has_base_message_content = proto.text.as_deref().is_some_and(|value| !value.is_empty())
        || proto
            .attributed_body
            .as_deref()
            .is_some_and(|value| !value.is_empty());
    let can_project_url_balloon_base = proto.balloon_bundle_id.as_deref()
        == Some(URL_BALLOON_PROVIDER)
        && (service == CloudCanonicalService::IMessage || has_base_message_content);
    if proto.payload_data.is_some() && !can_project_url_balloon_base {
        return Some(CloudCanonicalConversionOutcome::Deferred(
            CloudCanonicalDeferredReason::UnsupportedExtensionPayload,
        ));
    }
    if let Some(proto_4) = proto_4 {
        if proto_4.schedule_type.unwrap_or_default() != 0
            || proto_4.schedule_state.unwrap_or_default() != 0
        {
            return Some(CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnsupportedScheduling,
            ));
        }
        if proto_4.sent_or_received_off_grid.unwrap_or_default() != 0 {
            return Some(CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnsupportedOffGridMetadata,
            ));
        }
        if let Some(proto_4_service) = proto_4.service.as_deref() {
            let expected = match service {
                CloudCanonicalService::IMessage => "iMessage",
                CloudCanonicalService::Sms => "SMS",
            };
            if proto_4_service != expected {
                return Some(CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedService,
                ));
            }
        }
    }
    None
}

pub(crate) fn convert_message(
    context: &CloudCanonicalConversionContext<'_>,
    presence: &CloudRawRecordPresence,
    message: &CloudMessage,
) -> CloudCanonicalConversionOutcome {
    if let Err(reason) = require_present(
        presence,
        &[
            "msgType", "eCode", "chatID", "sender", "time", "msgProto", "flags", "guid", "svc",
        ],
    ) {
        return CloudCanonicalConversionOutcome::Quarantined(reason);
    }
    let service = match message.service.as_str() {
        "iMessage" => CloudCanonicalService::IMessage,
        "SMS" | "RCS" => {
            if message.guid.is_empty() || message.chat_id.is_empty() {
                return CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
                );
            }
            let expected_service = message.service.as_str();
            if let Some(nested_service) = message
                .msg_proto_4
                .as_ref()
                .and_then(|value| value.0.service.as_deref())
            {
                // Apple retains carrier-message records while a conversation
                // transitions between SMS and RCS. The top-level service can
                // therefore differ from msgProto4.service even though both
                // routes remain deliberately outside the iMessage projection.
                // Preserve strict quarantine for every non-carrier mismatch.
                if !matches!(nested_service, "SMS" | "RCS") {
                    return CloudCanonicalConversionOutcome::Quarantined(
                        CloudCanonicalQuarantineReason::UnsupportedService,
                    );
                }
            }
            return CloudCanonicalConversionOutcome::OutOfScopeService(
                if expected_service == "SMS" {
                    CloudCanonicalOutOfScopeService::SmsFamily
                } else {
                    CloudCanonicalOutOfScopeService::Rcs
                },
            );
        }
        _ => {
            return CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::UnsupportedService,
            )
        }
    };
    if message.guid.is_empty() || message.chat_id.is_empty() {
        return CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
        );
    }
    let proto = &message.msg_proto.0;
    let proto_2 = message.msg_proto_2.as_ref().map(|value| &value.0);
    let proto_4 = message.msg_proto_4.as_ref().map(|value| &value.0);
    if let Some(outcome) = reject_unsupported_message_content(proto, proto_4, service) {
        return outcome;
    }
    let (association, entity_kind, association_parent_hash) =
        match build_association(context, message.r#type, proto) {
            Ok(value) => value,
            Err(outcome) => return outcome,
        };
    let reply = match build_reply(context, proto_2) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    if association.is_reaction() && reply.is_some() {
        return CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::AmbiguousReply,
        );
    }
    let parent_hash =
        association_parent_hash.or_else(|| reply.as_ref().map(|value| value.parent_hash().clone()));

    let created_at_millis = match u64::try_from(message.time)
        .ok()
        .and_then(apple_nanos_to_unix_millis)
    {
        Some(value) => value,
        None => {
            return CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord,
            )
        }
    };
    let read_at_millis = match proto_timestamp(proto.date_read) {
        Ok(value) => value,
        Err(reason) => return CloudCanonicalConversionOutcome::Quarantined(reason),
    };
    let delivered_at_millis = match proto_timestamp(proto.date_delivered) {
        Ok(value) => value,
        Err(reason) => return CloudCanonicalConversionOutcome::Quarantined(reason),
    };
    let read_snapshot = match &read_at_millis {
        CloudCanonicalField::Value(value) => Some(*value),
        CloudCanonicalField::Absent | CloudCanonicalField::ExplicitClear => None,
    };
    let delivered_snapshot = match &delivered_at_millis {
        CloudCanonicalField::Value(value) => Some(*value),
        CloudCanonicalField::Absent | CloudCanonicalField::ExplicitClear => None,
    };
    let associated_emoji = proto_4
        .and_then(|value| value.associated_message_emoji.clone())
        .map(CloudCanonicalField::Value)
        .unwrap_or(CloudCanonicalField::Absent);
    let flags = CloudCanonicalKnownMessageFlags {
        from_me: message.flags.contains(MessageFlags::IS_FROM_ME),
        delivered: message.flags.contains(MessageFlags::IS_DELIVERED),
        read: message.flags.contains(MessageFlags::IS_READ),
        has_data_detector_results: message.flags.contains(MessageFlags::HAS_DD_RESULTS),
        delivered_quietly: message.flags.contains(MessageFlags::WAS_DELIVERED_QUIETLY),
        did_notify_recipient: message.flags.contains(MessageFlags::DID_NOTIFY_RECIPIENT),
    };
    let chat_alias_hash = match context.hasher.canonical_alias_key_hash(
        CloudCanonicalAliasKind::ChatServiceIdentifier,
        &message.chat_id,
    ) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let chat_id_exact_guid_logical_key_hash = match context
        .hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, &message.chat_id)
    {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let chat_id_bare_direct_service_identifier_alias_key_hash =
        if service == CloudCanonicalService::IMessage && !message.chat_id.contains(';') {
            let qualified_direct_identifier = format!("iMessage;-;{}", message.chat_id);
            match context.hasher.canonical_alias_key_hash(
                CloudCanonicalAliasKind::ChatServiceIdentifier,
                &qualified_direct_identifier,
            ) {
                Ok(value) => Some(value),
                Err(error) => return validation_quarantine(error),
            }
        } else {
            None
        };
    let mut chat_id_alias_candidates =
        Vec::with_capacity(CLOUD_CANONICAL_MESSAGE_CHAT_ALIAS_KINDS.len());
    for kind in CLOUD_CANONICAL_MESSAGE_CHAT_ALIAS_KINDS {
        let key_hash = match context
            .hasher
            .canonical_alias_key_hash(kind, &message.chat_id)
        {
            Ok(value) => value,
            Err(error) => return validation_quarantine(error),
        };
        chat_id_alias_candidates.push(CloudCanonicalAlias::new(kind, key_hash));
    }
    let msg_proto_4_group_id = proto_4.and_then(|value| value.group_id.clone());
    let msg_proto_4_group_id_alias_key_hash = match msg_proto_4_group_id.as_deref() {
        Some(group_id) => match context
            .hasher
            .canonical_alias_key_hash(CloudCanonicalAliasKind::ChatGroupId, group_id)
        {
            Ok(value) => Some(value),
            Err(error) => return validation_quarantine(error),
        },
        None => None,
    };
    let logical_hash_result = match association.reaction() {
        Some((_, parent, _)) => context.hasher.canonical_reaction_key_hash(
            &message.guid,
            parent.parent_guid(),
            parent.parent_part(),
        ),
        None => context
            .hasher
            .canonical_entity_key_hash(entity_kind, &message.guid),
    };
    let logical_hash = match logical_hash_result {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let subject = proto_string(&proto.subject);
    let text = proto_string(&proto.text);
    let attributed_content =
        match decode_attributed_content(context, &message.guid, proto.attributed_body.as_deref()) {
            Ok(value) => value,
            Err(outcome) => return outcome,
        };
    let original_maximum_utf16_length = attributed_content.maximum_utf16_length.or_else(|| {
        proto
            .text
            .as_ref()
            .and_then(|value| u32::try_from(value.encode_utf16().count()).ok())
    });
    let message_summary = match decode_message_summary(
        context,
        &message.guid,
        proto.message_summary_info.as_deref(),
        original_maximum_utf16_length,
    ) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let immutable_digest = match sha256_digest(&[
        message.guid.as_bytes(),
        message.chat_id.as_bytes(),
        message.sender.as_bytes(),
        proto.subject.as_deref().unwrap_or_default().as_bytes(),
        proto.text.as_deref().unwrap_or_default().as_bytes(),
        proto.attributed_body.as_deref().unwrap_or_default(),
        &message.r#type.to_be_bytes(),
    ]) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let payload = match CloudCanonicalMessagePayload::new(
        message.guid.clone(),
        message.chat_id.clone(),
        chat_alias_hash,
        chat_id_exact_guid_logical_key_hash,
        chat_id_bare_direct_service_identifier_alias_key_hash,
        chat_id_alias_candidates,
        msg_proto_4_group_id,
        msg_proto_4_group_id_alias_key_hash,
        message.sender.clone(),
        created_at_millis,
        message.error,
        service,
        subject,
        text,
        attributed_content.field,
        proto_string(&proto.balloon_bundle_id),
        CloudCanonicalField::Absent,
        proto_string(&proto.effect),
        read_at_millis,
        delivered_at_millis,
        flags,
        association,
        reply,
        message_summary.edits,
        message_summary.retracted_parts,
        associated_emoji,
    ) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    build_upsert(
        context,
        entity_kind,
        logical_hash,
        parent_hash,
        vec![],
        CloudCanonicalPayload::Message(Box::new(payload)),
        Some(immutable_digest),
        Some(created_at_millis),
        read_snapshot,
        delivered_snapshot,
        message_summary.edit_snapshots,
        None,
    )
}

fn nested_attachment_string(
    presence: &CloudRawRecordPresence,
    field: &str,
    value: &Option<String>,
) -> Result<CloudCanonicalField<String>, CloudCanonicalConversionOutcome> {
    nested_optional(presence, "cm", field, true, value)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloudAttachmentUserInfoKind {
    Inline,
    Mmcs,
}

fn validate_attachment_user_info(
    user_info: &MMCSAttachmentMeta,
) -> Result<CloudAttachmentUserInfoKind, CloudCanonicalQuarantineReason> {
    fn non_empty(value: Option<&str>) -> bool {
        value.is_some_and(|value| !value.is_empty() && !value.chars().any(char::is_control))
    }

    fn hex(value: Option<&str>) -> bool {
        value.is_some_and(|value| {
            !value.is_empty()
                && value.len() % 2 == 0
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f' | b'A'..=b'F'))
        })
    }

    let has_inline_metadata =
        user_info.inline_attachment.is_some() || user_info.message_part.is_some();
    let has_mmcs_metadata = user_info.mmcs_signature_hex.is_some()
        || user_info.mmcs_owner.is_some()
        || user_info.mmcs_url.is_some()
        || user_info.decryption_key.is_some();

    match (has_inline_metadata, has_mmcs_metadata) {
        (true, false)
            if matches!(
                user_info.inline_attachment.as_deref(),
                Some("ia-0" | "ia-1")
            ) && user_info
                .message_part
                .as_deref()
                .is_some_and(|value| value.parse::<u32>().is_ok()) =>
        {
            Ok(CloudAttachmentUserInfoKind::Inline)
        }
        (false, true)
            if hex(user_info.mmcs_signature_hex.as_deref())
                && non_empty(user_info.mmcs_owner.as_deref())
                && user_info.mmcs_url.as_deref().is_some_and(|value| {
                    value.starts_with("https://") && non_empty(Some(value))
                })
                && hex(user_info.decryption_key.as_deref()) =>
        {
            Ok(CloudAttachmentUserInfoKind::Mmcs)
        }
        _ => Err(CloudCanonicalQuarantineReason::MalformedRecord),
    }
}

pub(crate) fn convert_attachment(
    context: &CloudCanonicalConversionContext<'_>,
    presence: &CloudRawRecordPresence,
    attachment: &AttachmentMeta,
) -> CloudCanonicalConversionOutcome {
    if let Err(reason) = require_present(presence, &["cm"]) {
        return CloudCanonicalConversionOutcome::Quarantined(reason);
    }
    match presence.nested_field("cm", "aguid") {
        CloudNestedPresence::Present => {}
        CloudNestedPresence::Unavailable => {
            return CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::NestedPresenceUnavailable,
            )
        }
        _ => {
            return CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
            )
        }
    }
    if attachment.guid.is_empty() {
        return CloudCanonicalConversionOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedRequiredIdentity,
        );
    }
    // Semantic change pages intentionally request `NO_ASSETS`. The absence
    // (or valueless presence) of `lqa` on this cached page therefore says
    // nothing about whether the current record can supply a body. The native
    // materializer re-fetches this exact record with `ALL_ASSETS`, validates
    // its etag, account, and read permit, and fails closed if that authoritative
    // response has no usable asset.
    let mut materialization_capability =
        CloudCanonicalAttachmentMaterializationCapability::Materializable;
    if let Some(user_info) = attachment.user_info.as_ref() {
        match validate_attachment_user_info(user_info) {
            Ok(CloudAttachmentUserInfoKind::Mmcs) => {}
            // The native materializer currently reopens the protected record
            // and downloads its CloudKit/MMCS asset. It has no proven inline
            // body path. Preserve the canonical metadata while making that
            // body limitation explicit and content-free.
            Ok(CloudAttachmentUserInfoKind::Inline) => {
                materialization_capability = CloudCanonicalAttachmentMaterializationCapability::
                    MetadataOnlyUnsupportedMediaCredentials;
            }
            Err(reason) => {
                return CloudCanonicalConversionOutcome::Quarantined(reason);
            }
        }
    }
    if attachment.is_sticker {
        return CloudCanonicalConversionOutcome::Deferred(
            CloudCanonicalDeferredReason::UnsupportedSticker,
        );
    }
    let (canonical_guid, logical_hash, owner_guid, owner_hash, owner_part) =
        match parse_owned_attachment_guid(&attachment.guid) {
            Ok(owned) => {
                let owner_hash = match context.hasher.canonical_entity_key_hash(
                    CloudCanonicalEntityKind::Message,
                    owned.message_guid(),
                ) {
                    Ok(value) => value,
                    Err(error) => return validation_quarantine(error),
                };
                let logical_hash = match context
                    .hasher
                    .canonical_owned_attachment_key_hash(owned.message_guid(), owned.part())
                {
                    Ok(value) => value,
                    Err(error) => return validation_quarantine(error),
                };
                (
                    owned.canonical_guid().to_owned(),
                    logical_hash,
                    Some(owned.message_guid().to_owned()),
                    Some(owner_hash),
                    Some(owned.part()),
                )
            }
            Err(_) if attachment.guid.starts_with("at_") => {
                return CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedParent,
                )
            }
            Err(_) => {
                let logical_hash = match context.hasher.canonical_entity_key_hash(
                    CloudCanonicalEntityKind::Attachment,
                    &attachment.guid,
                ) {
                    Ok(value) => value,
                    Err(error) => return validation_quarantine(error),
                };
                (attachment.guid.clone(), logical_hash, None, None, None)
            }
        };
    let uti = match nested_attachment_string(presence, "t", &attachment.uti) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let mime_type = match nested_attachment_string(presence, "mimet", &attachment.mime_type) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let transfer_name = match nested_attachment_string(presence, "tn", &attachment.transfer_name) {
        Ok(value) => value,
        Err(outcome) => return outcome,
    };
    let total_bytes = match presence.nested_field("cm", "tb") {
        CloudNestedPresence::Present if attachment.total_bytes < 0 => {
            return CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnsupportedNegativeAttachmentSize,
            )
        }
        CloudNestedPresence::Present if attachment.total_bytes == 0 => {
            // The native MMCS materializer deliberately rejects zero-byte
            // requests. Keep the observed zero without promoting this body to
            // a materializable state.
            materialization_capability = CloudCanonicalAttachmentMaterializationCapability::
                MetadataOnlyUnsupportedMediaCredentials;
            CloudCanonicalField::Value(0)
        }
        CloudNestedPresence::Present => CloudCanonicalField::Value(attachment.total_bytes as u64),
        CloudNestedPresence::Unavailable => {
            return CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::NestedPresenceUnavailable,
            )
        }
        CloudNestedPresence::Absent => {
            // Size is materialization metadata. Do not fabricate serde's
            // numeric default when Apple omitted it, but retain the remaining
            // canonical metadata.
            materialization_capability = CloudCanonicalAttachmentMaterializationCapability::
                MetadataOnlyUnsupportedMediaCredentials;
            CloudCanonicalField::Absent
        }
        CloudNestedPresence::OuterAbsent | CloudNestedPresence::OuterWithoutValue => {
            return CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord,
            )
        }
    };
    let is_outgoing = match presence.nested_field("cm", "ig") {
        CloudNestedPresence::Present => CloudCanonicalField::Value(attachment.is_outgoing),
        CloudNestedPresence::Absent => CloudCanonicalField::Absent,
        CloudNestedPresence::Unavailable => {
            return CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::NestedPresenceUnavailable,
            )
        }
        CloudNestedPresence::OuterAbsent | CloudNestedPresence::OuterWithoutValue => {
            return CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord,
            )
        }
    };
    let payload = match CloudCanonicalAttachmentPayload::new_with_materialization_capability(
        canonical_guid,
        owner_guid,
        owner_hash.clone(),
        owner_part,
        uti,
        mime_type,
        transfer_name,
        total_bytes,
        is_outgoing,
        materialization_capability,
        CloudCanonicalField::Absent,
    ) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    build_upsert(
        context,
        CloudCanonicalEntityKind::Attachment,
        logical_hash,
        owner_hash,
        vec![],
        CloudCanonicalPayload::Attachment(Box::new(payload)),
        None,
        Some(attachment.created_date),
        None,
        None,
        vec![],
        None,
    )
}

pub(crate) fn convert_tombstone(
    context: &CloudCanonicalConversionContext<'_>,
    entity_kind: CloudCanonicalEntityKind,
    mapped_logical_entity_key_hash: CloudCanonicalHash,
) -> CloudCanonicalConversionOutcome {
    let protected = match protected_reference(context) {
        Ok(value) => value,
        Err(reason) => return CloudCanonicalConversionOutcome::Quarantined(reason),
    };
    let server_record_id_hash = match context
        .hasher
        .canonical_server_record_id_hash(context.record_name)
    {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let envelope = match CloudCanonicalEnvelope::new(
        context.scope_fingerprint.clone(),
        context.zone_fingerprint.clone(),
        context.generation,
        CLOUD_CANONICAL_SCHEMA_VERSION,
        context.change_id.clone(),
        entity_kind,
        CloudCanonicalMutationKind::Tombstone,
        server_record_id_hash.clone(),
        mapped_logical_entity_key_hash.clone(),
        None,
        vec![],
        match etag_hash(context.hasher, context.etag) {
            Ok(value) => value,
            Err(error) => return validation_quarantine(error),
        },
        context.server_created_at_millis,
        context.server_modified_at_millis,
        protected.clone(),
    ) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    let tombstone = match CloudCanonicalTombstone::new(
        entity_kind,
        server_record_id_hash,
        mapped_logical_entity_key_hash,
        protected,
        context.server_modified_at_millis,
        true,
    ) {
        Ok(value) => value,
        Err(error) => return validation_quarantine(error),
    };
    CloudCanonicalMutation::new(envelope, None, None, Some(tombstone))
        .map(Box::new)
        .map(CloudCanonicalConversionOutcome::Ready)
        .unwrap_or_else(validation_quarantine)
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message as _;
    use rustpush::{
        cloud_messages::{
            CloudParticipant, CloudProp, GZipWrapper, MessageEdit as WireMessageEdit,
            MessageEditRange,
        },
        cloudkit_proto::{
            record::{field, Field},
            Asset, Record,
        },
        coder_encode_flattened, NSAttributedString, NSDictionaryTypedCoder, NSNumber, NSString,
        StCollapsedValue,
    };

    const SECRET: &str = "private-body-secret-should-never-be-logged";

    fn hash(character: char) -> CloudCanonicalHash {
        CloudCanonicalHash::new(character.to_string().repeat(43)).expect("fixture hash")
    }

    fn context<'a>(
        hasher: &'a CloudSemanticIdentifierHasher,
        record_name: &'a str,
        modified_at: Option<i64>,
    ) -> CloudCanonicalConversionContext<'a> {
        CloudCanonicalConversionContext::new(
            hasher,
            hash('a'),
            hash('b'),
            7,
            hash('c'),
            record_name,
            Some("private-etag"),
            Some(1_720_000_000_000),
            modified_at,
            "obcs2.fixture.protected",
        )
    }

    fn raw_presence(fields: &[&str]) -> CloudRawRecordPresence {
        let record = Record {
            record_field: fields
                .iter()
                .map(|name| Field {
                    identifier: Some(field::Identifier {
                        name: Some((*name).to_owned()),
                    }),
                    value: Some(field::Value::default()),
                })
                .collect(),
            ..Default::default()
        };
        CloudRawRecordPresence::extract(&record).expect("fixture presence")
    }

    fn capture_keys(presence: &mut CloudRawRecordPresence, outer: &str, keys: &[&str]) {
        let mut dictionary = plist::Dictionary::new();
        for key in keys {
            dictionary.insert((*key).to_owned(), PlistValue::String("fixture".to_owned()));
        }
        let mut bytes = Vec::new();
        plist::to_writer_binary(&mut bytes, &PlistValue::Dictionary(dictionary))
            .expect("fixture plist");
        presence
            .capture_decrypted_plist_dictionary(outer, &bytes)
            .expect("capture fixture keys");
    }

    fn direct_chat() -> CloudChat {
        CloudChat {
            style: 45,
            chat_identifier: "iMessage;-;+15555550100".to_owned(),
            group_id: "chat-direct".to_owned(),
            service_name: "iMessage".to_owned(),
            original_group_id: "chat-direct-original".to_owned(),
            participants: vec![CloudParticipant {
                uri: "tel:+15555550100".to_owned(),
            }],
            guid: "chat-guid-direct".to_owned(),
            ..Default::default()
        }
    }

    fn group_chat() -> CloudChat {
        CloudChat {
            style: 43,
            chat_identifier: "iMessage;+;group".to_owned(),
            group_id: "chat-group".to_owned(),
            service_name: "iMessage".to_owned(),
            original_group_id: "chat-group-original".to_owned(),
            properties: Some(CloudProp {
                pv: Some(9),
                ..Default::default()
            }),
            participants: vec![
                CloudParticipant {
                    uri: "tel:+15555550100".to_owned(),
                },
                CloudParticipant {
                    uri: "tel:+15555550101".to_owned(),
                },
            ],
            guid: "chat-guid-group".to_owned(),
            ..Default::default()
        }
    }

    fn chat_required_presence(with_prop: bool) -> CloudRawRecordPresence {
        let mut fields = vec!["guid", "cid", "gid", "ogid", "svc", "stl", "ptcpts"];
        if with_prop {
            fields.push("prop");
        }
        raw_presence(&fields)
    }

    fn message_presence() -> CloudRawRecordPresence {
        raw_presence(&[
            "msgType", "eCode", "chatID", "sender", "time", "msgProto", "flags", "guid", "svc",
        ])
    }

    fn normal_message(text: Option<&str>) -> CloudMessage {
        CloudMessage {
            r#type: 1,
            chat_id: "iMessage;-;+15555550100".to_owned(),
            sender: "tel:+15555550100".to_owned(),
            time: 123_000_000,
            msg_proto: GZipWrapper(MessageProto {
                unk1: 1,
                text: text.map(ToOwned::to_owned),
                ..Default::default()
            }),
            guid: "message-guid-normal".to_owned(),
            service: "iMessage".to_owned(),
            ..Default::default()
        }
    }

    fn reaction_message() -> CloudMessage {
        CloudMessage {
            r#type: 2,
            chat_id: "iMessage;-;+15555550100".to_owned(),
            sender: "tel:+15555550100".to_owned(),
            time: 124_000_000,
            msg_proto: GZipWrapper(MessageProto {
                unk1: 1,
                associated_message_type: Some(2000),
                associated_message_guid: Some("p:0/parent-guid-not-loaded".to_owned()),
                associated_message_range_location: Some(0),
                associated_message_range_length: Some(4),
                ..Default::default()
            }),
            guid: "reaction-guid".to_owned(),
            service: "iMessage".to_owned(),
            ..Default::default()
        }
    }

    fn attachment_presence() -> CloudRawRecordPresence {
        attachment_presence_with(&["aguid", "tb", "ig"], true)
    }

    fn attachment_presence_with(
        nested_fields: &[&str],
        include_asset: bool,
    ) -> CloudRawRecordPresence {
        let top_level_fields = if include_asset {
            &["cm", "lqa"][..]
        } else {
            &["cm"][..]
        };
        let mut presence = raw_presence(top_level_fields);
        capture_keys(&mut presence, "cm", nested_fields);
        presence
    }

    fn ready_attachment_payload(
        outcome: CloudCanonicalConversionOutcome,
    ) -> CloudCanonicalAttachmentPayload {
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("attachment should convert to a ready mutation");
        };
        let Some(CloudCanonicalPayload::Attachment(payload)) = mutation.payload() else {
            panic!("attachment payload expected");
        };
        payload.as_ref().clone()
    }

    fn attribute_dictionary(
        entries: impl IntoIterator<Item = (&'static str, StCollapsedValue)>,
    ) -> NSDictionaryTypedCoder {
        NSDictionaryTypedCoder(
            entries
                .into_iter()
                .map(|(key, value)| (key.to_owned(), value))
                .collect(),
        )
    }

    fn encoded_attributed_body(text: &str, ranges: Vec<(u32, NSDictionaryTypedCoder)>) -> Vec<u8> {
        coder_encode_flattened(&[NSAttributedString {
            text: text.to_owned(),
            ranges,
        }
        .encode()])
    }

    fn plain_encoded_attributed_body(text: &str) -> Vec<u8> {
        encoded_attributed_body(
            text,
            vec![(text.encode_utf16().count() as u32, attribute_dictionary([]))],
        )
    }

    fn encoded_message_summary(summary: &MessageSummaryInfo) -> Vec<u8> {
        let mut encoded = Vec::new();
        plist::to_writer_binary(&mut encoded, summary).expect("fixture message summary");
        encoded
    }

    fn encoded_explicit_clear_message_summary() -> Vec<u8> {
        let mut summary = plist::Dictionary::new();
        summary.insert("ec".to_owned(), PlistValue::Dictionary(Default::default()));
        summary.insert("ep".to_owned(), PlistValue::Array(Vec::new()));
        summary.insert("otr".to_owned(), PlistValue::Dictionary(Default::default()));
        summary.insert("rp".to_owned(), PlistValue::Array(Vec::new()));
        let mut encoded = Vec::new();
        plist::to_writer_binary(&mut encoded, &PlistValue::Dictionary(summary))
            .expect("explicit-clear summary");
        encoded
    }

    fn message_payload(outcome: &CloudCanonicalConversionOutcome) -> &CloudCanonicalMessagePayload {
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("message fixture should convert");
        };
        let Some(CloudCanonicalPayload::Message(payload)) = mutation.payload() else {
            panic!("message payload expected");
        };
        payload
    }

    #[test]
    fn canary_diagnostic_codes_are_closed_and_content_free() {
        let chat_codes = [
            (
                CloudChatDiagnosticCode::MissingRequiredField,
                "missing_required_field",
            ),
            (
                CloudChatDiagnosticCode::MissingGuidField,
                "missing_guid_field",
            ),
            (
                CloudChatDiagnosticCode::MissingChatIdentifierField,
                "missing_chat_identifier_field",
            ),
            (
                CloudChatDiagnosticCode::MissingGroupIdentifierField,
                "missing_group_identifier_field",
            ),
            (
                CloudChatDiagnosticCode::MissingOriginalGroupIdentifierField,
                "missing_original_group_identifier_field",
            ),
            (
                CloudChatDiagnosticCode::MissingServiceField,
                "missing_service_field",
            ),
            (
                CloudChatDiagnosticCode::MissingStyleField,
                "missing_style_field",
            ),
            (
                CloudChatDiagnosticCode::MissingParticipantsField,
                "missing_participants_field",
            ),
            (
                CloudChatDiagnosticCode::UnsupportedService,
                "unsupported_service",
            ),
            (
                CloudChatDiagnosticCode::UnsupportedChatStyle,
                "unsupported_chat_style",
            ),
            (
                CloudChatDiagnosticCode::EmptyRequiredIdentity,
                "empty_required_identity",
            ),
            (CloudChatDiagnosticCode::EmptyGuid, "empty_guid"),
            (
                CloudChatDiagnosticCode::EmptyChatIdentifier,
                "empty_chat_identifier",
            ),
            (
                CloudChatDiagnosticCode::EmptyGroupIdentifier,
                "empty_group_identifier",
            ),
            (
                CloudChatDiagnosticCode::EmptyOriginalGroupIdentifier,
                "empty_original_group_identifier",
            ),
            (
                CloudChatDiagnosticCode::GroupPhotoMissingStableGuid,
                "group_photo_missing_stable_guid",
            ),
            (
                CloudChatDiagnosticCode::DirectChatGroupPhotoAsset,
                "direct_chat_group_photo_asset",
            ),
            (
                CloudChatDiagnosticCode::GroupPhotoPresentWithoutValue,
                "group_photo_present_without_value",
            ),
            (
                CloudChatDiagnosticCode::GroupPhotoPresenceMismatch,
                "group_photo_presence_mismatch",
            ),
            (
                CloudChatDiagnosticCode::DisplayNameField,
                "display_name_field",
            ),
            (
                CloudChatDiagnosticCode::LastAddressedHandleField,
                "last_addressed_handle_field",
            ),
            (
                CloudChatDiagnosticCode::LastAddressedHandleIgnoredUnproven,
                "last_addressed_handle_ignored_unproven",
            ),
            (
                CloudChatDiagnosticCode::GroupVersionField,
                "group_version_field",
            ),
            (
                CloudChatDiagnosticCode::LastSeenMessageField,
                "last_seen_message_field",
            ),
            (
                CloudChatDiagnosticCode::GroupPhotoGuidField,
                "group_photo_guid_field",
            ),
            (
                CloudChatDiagnosticCode::DirectChatGroupPhotoGuid,
                "direct_chat_group_photo_guid",
            ),
            (
                CloudChatDiagnosticCode::EmptyLegacyGroupIdentifier,
                "empty_legacy_group_identifier",
            ),
            (
                CloudChatDiagnosticCode::LogicalIdentityHash,
                "logical_identity_hash",
            ),
            (CloudChatDiagnosticCode::AliasHash, "alias_hash"),
            (
                CloudChatDiagnosticCode::CanonicalPayload,
                "canonical_payload",
            ),
            (CloudChatDiagnosticCode::CanonicalBuild, "canonical_build"),
        ];
        for (code, expected) in chat_codes {
            assert_eq!(code.as_str(), expected);
            assert!(expected
                .chars()
                .all(|value| value.is_ascii_lowercase() || value == '_'));
        }

        let raw_codes = [
            (CloudRawPresenceFailure::TooManyFields, "too_many_fields"),
            (
                CloudRawPresenceFailure::MalformedFieldIdentifier,
                "malformed_field_identifier",
            ),
            (
                CloudRawPresenceFailure::DuplicateFieldIdentifier,
                "duplicate_field_identifier",
            ),
            (
                CloudRawPresenceFailure::FieldNotPresent,
                "field_not_present",
            ),
            (
                CloudRawPresenceFailure::NestedPayloadTooLarge,
                "nested_payload_too_large",
            ),
            (
                CloudRawPresenceFailure::MalformedNestedPlist,
                "malformed_nested_plist",
            ),
            (
                CloudRawPresenceFailure::NestedPlistIsNotDictionary,
                "nested_plist_not_dictionary",
            ),
            (
                CloudRawPresenceFailure::ExplicitClearWithoutPresence,
                "explicit_clear_without_presence",
            ),
        ];
        for (failure, expected) in raw_codes {
            assert_eq!(failure.diagnostic_code(), expected);
        }
    }

    #[test]
    fn chat_diagnostics_preserve_conversion_outcomes() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let ready_chat = direct_chat();
        let ready_presence = chat_required_presence(false);
        let ready_context = context(&hasher, "server-chat-diagnostic-ready", None);
        let expected = convert_chat(&ready_context, &ready_presence, &ready_chat);
        let (instrumented, diagnostic) =
            convert_chat_with_diagnostic(&ready_context, &ready_presence, &ready_chat);
        assert_eq!(instrumented, expected);
        assert_eq!(diagnostic, None);

        let mut unsupported_chat = direct_chat();
        unsupported_chat.service_name = "FaceTime".to_owned();
        let unsupported_context = context(&hasher, "server-chat-diagnostic-service", None);
        let expected = convert_chat(&unsupported_context, &ready_presence, &unsupported_chat);
        let (instrumented, diagnostic) =
            convert_chat_with_diagnostic(&unsupported_context, &ready_presence, &unsupported_chat);
        assert_eq!(instrumented, expected);
        assert_eq!(
            diagnostic,
            Some(CloudChatDiagnosticCode::UnsupportedService)
        );

        let missing_presence = raw_presence(&["guid", "cid", "gid", "ogid", "stl", "ptcpts"]);
        let missing_context = context(&hasher, "server-chat-diagnostic-required", None);
        let expected = convert_chat(&missing_context, &missing_presence, &ready_chat);
        let (instrumented, diagnostic) =
            convert_chat_with_diagnostic(&missing_context, &missing_presence, &ready_chat);
        assert_eq!(instrumented, expected);
        assert_eq!(
            diagnostic,
            Some(CloudChatDiagnosticCode::MissingServiceField)
        );
    }

    #[test]
    fn direct_chat_fixture_converts_without_default_inference() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let outcome = convert_chat(
            &context(&hasher, "server-chat-direct", Some(1_720_000_000_001)),
            &chat_required_presence(false),
            &direct_chat(),
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("direct chat should convert");
        };
        assert_eq!(
            mutation.envelope().entity_kind(),
            CloudCanonicalEntityKind::Chat
        );
        let service_aliases: Vec<_> = mutation
            .envelope()
            .aliases()
            .iter()
            .filter(|alias| alias.kind() == CloudCanonicalAliasKind::ChatServiceIdentifier)
            .collect();
        assert_eq!(service_aliases.len(), 1);
        assert_eq!(
            service_aliases[0].key_hash(),
            &hasher
                .canonical_alias_key_hash(
                    CloudCanonicalAliasKind::ChatServiceIdentifier,
                    "iMessage;-;+15555550100",
                )
                .expect("service alias hash")
        );
        for (kind, wire_identity) in [
            (CloudCanonicalAliasKind::ChatGroupId, "chat-direct"),
            (
                CloudCanonicalAliasKind::ChatOriginalGroupId,
                "chat-direct-original",
            ),
        ] {
            let expected = hasher
                .canonical_alias_key_hash(kind, wire_identity)
                .expect("typed alias hash");
            assert!(mutation
                .envelope()
                .aliases()
                .iter()
                .any(|alias| alias.kind() == kind && alias.key_hash() == &expected));
        }
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.display_name_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
        assert_eq!(
            payload.group_version_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
    }

    #[test]
    fn chat_conversion_keeps_legacy_lineage_out_of_service_identifier_domain() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut chat = group_chat();
        chat.properties
            .as_mut()
            .expect("group properties")
            .legacy_group_identifiers = vec!["legacy-group".to_owned()];
        let mut presence = chat_required_presence(true);
        capture_keys(&mut presence, "prop", &["pv"]);
        let outcome = convert_chat(
            &context(&hasher, "server-chat-typed-lineage", None),
            &presence,
            &chat,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("chat with typed legacy lineage should convert");
        };
        let service_aliases: Vec<_> = mutation
            .envelope()
            .aliases()
            .iter()
            .filter(|alias| alias.kind() == CloudCanonicalAliasKind::ChatServiceIdentifier)
            .collect();
        assert_eq!(service_aliases.len(), 1);
        assert_eq!(
            service_aliases[0].key_hash(),
            &hasher
                .canonical_alias_key_hash(
                    CloudCanonicalAliasKind::ChatServiceIdentifier,
                    &chat.chat_identifier,
                )
                .unwrap()
        );
        let legacy_hash = hasher
            .canonical_alias_key_hash(
                CloudCanonicalAliasKind::ChatLegacyGroupIdentifier,
                "legacy-group",
            )
            .unwrap();
        assert!(mutation.envelope().aliases().iter().any(|alias| {
            alias.kind() == CloudCanonicalAliasKind::ChatLegacyGroupIdentifier
                && alias.key_hash() == &legacy_hash
        }));
    }

    #[test]
    fn group_chat_fixture_preserves_nested_pv_presence() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut presence = chat_required_presence(true);
        capture_keys(&mut presence, "prop", &["pv"]);
        let outcome = convert_chat(
            &context(&hasher, "server-chat-group", Some(1_720_000_000_001)),
            &presence,
            &group_chat(),
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("group chat should convert");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.group_version_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Value
        );
    }

    #[test]
    fn nested_presence_is_deferred_instead_of_guessed() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let (outcome, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-group", None),
            &chat_required_presence(true),
            &group_chat(),
        );
        assert_eq!(
            outcome,
            CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::NestedPresenceUnavailable
            )
        );
        assert_eq!(diagnostic, Some(CloudChatDiagnosticCode::GroupVersionField));
    }

    #[test]
    fn normal_text_preserves_omitted_vs_explicit_empty() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let omitted = convert_message(
            &context(&hasher, "server-message-omitted", None),
            &message_presence(),
            &normal_message(None),
        );
        let empty = convert_message(
            &context(&hasher, "server-message-empty", None),
            &message_presence(),
            &normal_message(Some("")),
        );
        let CloudCanonicalConversionOutcome::Ready(omitted) = omitted else {
            panic!("omitted fixture should convert");
        };
        let CloudCanonicalConversionOutcome::Ready(empty) = empty else {
            panic!("empty fixture should convert");
        };
        let Some(CloudCanonicalPayload::Message(omitted)) = omitted.payload() else {
            panic!("message payload expected");
        };
        let Some(CloudCanonicalPayload::Message(empty)) = empty.payload() else {
            panic!("message payload expected");
        };
        assert_eq!(
            omitted.text_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
        assert_eq!(
            empty.text_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Value
        );
    }

    #[test]
    fn attributed_body_projects_utf16_runs_known_attributes_and_attachment_reference() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attributes = attribute_dictionary([
            ("__kIMMessagePartAttributeName", NSNumber(0).encode()),
            (
                "__kIMFileTransferGUIDAttributeName",
                NSString("at_0_message-guid-normal".to_owned()).encode(),
            ),
            (
                "__kIMMentionConfirmedMention",
                NSString("mailto:synthetic@example.invalid".to_owned()).encode(),
            ),
            (
                "IMAudioTranscription",
                NSString("transcript".to_owned()).encode(),
            ),
            ("__kIMTextEffectAttributeName", NSNumber(3).encode()),
            ("__kIMTextBoldAttributeName", NSNumber(1).encode()),
            ("__kIMTextItalicAttributeName", NSNumber(0).encode()),
            (
                "__kIMUnknownFutureAttribute",
                NSString(SECRET.to_owned()).encode(),
            ),
        ]);
        let mut message = normal_message(Some("A😀B"));
        message.msg_proto.0.attributed_body =
            Some(encoded_attributed_body("A😀B", vec![(4, attributes)]));

        let outcome = convert_message(
            &context(&hasher, "server-message-attributed", None),
            &message_presence(),
            &message,
        );
        let payload = message_payload(&outcome);
        assert_eq!(
            payload.attributed_bodies_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Value
        );
        assert_eq!(payload.attributed_bodies().len(), 1);
        assert_eq!(payload.attributed_bodies()[0].text_utf16_length(), 4);
        assert_eq!(payload.attributed_bodies()[0].runs().len(), 1);
        assert_eq!(
            payload.attributed_bodies()[0].runs()[0].message_part(),
            Some(0)
        );
        assert!(payload.attributed_bodies()[0].runs()[0].has_attachment());
        assert!(!format!("{outcome:?}").contains(SECRET));
    }

    #[test]
    fn attributed_attachment_owner_must_match_the_message() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attributes = attribute_dictionary([(
            "__kIMFileTransferGUIDAttributeName",
            NSString("at_0_another-message-guid".to_owned()).encode(),
        )]);
        let mut message = normal_message(Some("attachment"));
        message.msg_proto.0.attributed_body = Some(encoded_attributed_body(
            "attachment",
            vec![(10, attributes)],
        ));

        assert_eq!(
            convert_message(
                &context(&hasher, "server-message-owner-mismatch", None),
                &message_presence(),
                &message,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedParent
            )
        );
    }

    #[test]
    fn message_summary_edits_are_sorted_deduplicated_and_snapshotted() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let older_body = plain_encoded_attributed_body("older");
        let newer_body = plain_encoded_attributed_body("newer");
        let mut summary = MessageSummaryInfo {
            ep: vec![2, 1],
            rp: vec![7, 3, 7],
            ..Default::default()
        };
        summary.ec.insert(
            "1".to_owned(),
            vec![WireMessageEdit {
                t: plain_encoded_attributed_body("other part"),
                d: 1_720_000_000_300.0,
                bcg: None,
            }],
        );
        summary.ec.insert(
            "2".to_owned(),
            vec![
                WireMessageEdit {
                    t: newer_body,
                    d: 1_720_000_000_200.0,
                    bcg: None,
                },
                WireMessageEdit {
                    t: older_body.clone(),
                    d: 1_720_000_000_100.0,
                    bcg: None,
                },
                WireMessageEdit {
                    t: older_body,
                    d: 1_720_000_000_100.0,
                    bcg: None,
                },
            ],
        );
        summary
            .otr
            .insert("2".to_owned(), MessageEditRange { lo: 0, le: 4 });
        summary
            .otr
            .insert("1".to_owned(), MessageEditRange { lo: 0, le: 4 });

        let mut message = normal_message(Some("base"));
        message.msg_proto.0.attributed_body = Some(plain_encoded_attributed_body("base"));
        message.msg_proto.0.message_summary_info = Some(encoded_message_summary(&summary));
        let outcome = convert_message(
            &context(&hasher, "server-message-edits", None),
            &message_presence(),
            &message,
        );
        let payload = message_payload(&outcome);
        assert_eq!(
            payload.edits_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Value
        );
        assert_eq!(payload.edit_count(), 3);
        assert_eq!(
            payload
                .edits()
                .iter()
                .map(CloudCanonicalMessageEdit::part)
                .collect::<Vec<_>>(),
            vec![1, 2, 2]
        );
        assert_eq!(
            payload
                .edits()
                .iter()
                .map(CloudCanonicalMessageEdit::revision)
                .collect::<Vec<_>>(),
            vec![0, 0, 1]
        );
        assert_eq!(
            payload
                .edits()
                .iter()
                .map(CloudCanonicalMessageEdit::modified_at_millis)
                .collect::<Vec<_>>(),
            vec![1_720_000_000_300, 1_720_000_000_100, 1_720_000_000_200]
        );
        assert_eq!(payload.retracted_parts(), &[3, 7]);

        let CloudCanonicalConversionOutcome::Ready(mutation) = &outcome else {
            unreachable!("payload helper already proved ready");
        };
        let snapshot = mutation.snapshot().expect("edit snapshot");
        assert_eq!(snapshot.edit_parts().len(), 3);
        assert_eq!(
            snapshot
                .edit_parts()
                .iter()
                .map(CloudCanonicalEditPartSnapshot::revision)
                .collect::<Vec<_>>(),
            vec![0, 0, 1]
        );
        assert_eq!(
            snapshot
                .edit_parts()
                .iter()
                .map(CloudCanonicalEditPartSnapshot::modified_at_millis)
                .collect::<Vec<_>>(),
            vec![1_720_000_000_300, 1_720_000_000_100, 1_720_000_000_200]
        );
    }

    #[test]
    fn empty_summary_collections_do_not_become_a_clear_instruction() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message = normal_message(Some(""));
        message.msg_proto.0.attributed_body = Some(coder_encode_flattened(&[]));
        message.msg_proto.0.message_summary_info = Some(encoded_explicit_clear_message_summary());
        let outcome = convert_message(
            &context(&hasher, "server-message-explicit-clears", None),
            &message_presence(),
            &message,
        );
        let payload = message_payload(&outcome);
        assert_eq!(
            payload.attributed_bodies_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::ExplicitClear
        );
        // attributedBody is protobuf `optional bytes`, where present-and-empty
        // is genuinely distinguishable from absent, so a clear is well founded
        // there.
        //
        // The summary collections are not. Apple omits an empty collection
        // rather than sending one, so an empty `ec`/`rp` carries no instruction
        // and must not wipe local edit or retraction state.
        assert_eq!(
            payload.edits_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
        assert_eq!(
            payload.retracted_parts_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
    }

    #[test]
    fn malformed_and_oversized_attributed_content_fail_closed() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut malformed = normal_message(Some("body"));
        malformed.msg_proto.0.attributed_body = Some(vec![1, 2, 3]);
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message-malformed-body", None),
                &message_presence(),
                &malformed,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedAttributedBody
            )
        );

        let oversized = vec![0_u8; MAX_ATTRIBUTED_BODY_BYTES + 1];
        assert!(matches!(
            BoundedTypedStreamDecoder::new(&oversized),
            Err(BoundedStreamFailure::Oversized)
        ));

        let mut declared_oversized = vec![0x04, 11];
        declared_oversized.extend_from_slice(b"streamtyped");
        declared_oversized.extend_from_slice(&[0x81, 0xe8, 0x03, TYPED_STREAM_TAG_START, 13]);
        declared_oversized.extend_from_slice(b"[4294967295c]");
        assert!(matches!(
            BoundedTypedStreamDecoder::new(&declared_oversized)
                .and_then(BoundedTypedStreamDecoder::decode),
            Err(BoundedStreamFailure::Oversized)
        ));
    }

    #[test]
    fn every_truncated_typedstream_prefix_returns_without_panicking() {
        let encoded = plain_encoded_attributed_body("A😀B");
        for length in 0..encoded.len() {
            let prefix = &encoded[..length];
            let result = std::panic::catch_unwind(|| {
                BoundedTypedStreamDecoder::new(prefix).and_then(BoundedTypedStreamDecoder::decode)
            });
            assert!(result.is_ok(), "decoder panicked at prefix length {length}");
            assert!(
                result.expect("checked above").is_err(),
                "truncated prefix unexpectedly decoded at length {length}"
            );
        }

        let mut trailing = encoded;
        trailing.push(0);
        assert!(matches!(
            BoundedTypedStreamDecoder::new(&trailing).and_then(BoundedTypedStreamDecoder::decode),
            Err(BoundedStreamFailure::Malformed)
        ));
    }

    #[test]
    fn unproven_edit_time_and_edit_retraction_conflict_do_not_apply() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        assert_eq!(
            validated_edit_timestamp(0.0),
            Err(CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnprovenEditTimestamp
            ))
        );
        let mut fractional = MessageSummaryInfo {
            ep: vec![0],
            ..Default::default()
        };
        fractional.ec.insert(
            "0".to_owned(),
            vec![WireMessageEdit {
                t: plain_encoded_attributed_body("edit"),
                d: 1_720_000_000_100.5,
                bcg: None,
            }],
        );
        let mut message = normal_message(Some("base"));
        message.msg_proto.0.message_summary_info = Some(encoded_message_summary(&fractional));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message-fractional-time", None),
                &message_presence(),
                &message,
            ),
            CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnprovenEditTimestamp
            )
        );

        let mut conflicting = fractional;
        conflicting.ec.get_mut("0").expect("edit")[0].d = 1_720_000_000_100.0;
        conflicting.rp = vec![0];
        message.msg_proto.0.message_summary_info = Some(encoded_message_summary(&conflicting));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message-conflict", None),
                &message_presence(),
                &message,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::ConflictingEditAndRetraction
            )
        );
    }

    #[test]
    fn reply_parent_sets_envelope_parent_and_malformed_parts_are_rejected() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut reply = normal_message(Some("reply"));
        reply.msg_proto_2 = Some(GZipWrapper(MessageProto2 {
            reply: Some("r:0:parent-guid".to_owned()),
        }));
        let outcome = convert_message(
            &context(&hasher, "server-message-valid-reply", None),
            &message_presence(),
            &reply,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("valid reply should convert");
        };
        assert!(mutation.envelope().parent_logical_key_hash().is_some());

        for malformed in ["r:x:parent-guid", "r:01:parent-guid"] {
            reply.msg_proto_2 = Some(GZipWrapper(MessageProto2 {
                reply: Some(malformed.to_owned()),
            }));
            assert_eq!(
                convert_message(
                    &context(&hasher, "server-message-malformed-reply", None),
                    &message_presence(),
                    &reply,
                ),
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedParent
                ),
                "{malformed}"
            );
        }
    }

    #[test]
    fn safe_group_photo_guid_is_projected_while_asset_stays_protected() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut chat = group_chat();
        chat.properties = None;
        chat.group_photo_guid = Some("group-photo-guid".to_owned());
        chat.group_photo = Some(Asset::default());
        let presence = raw_presence(&[
            "guid", "cid", "gid", "ogid", "svc", "stl", "ptcpts", "gpid", "gp",
        ]);
        let outcome = convert_chat(
            &context(&hasher, "server-chat-group-photo", None),
            &presence,
            &chat,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("group photo metadata should convert");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.group_photo_guid_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Value
        );
        assert_eq!(
            mutation
                .envelope()
                .protected_raw_envelope_reference()
                .value(),
            "obcs2.fixture.protected"
        );

        chat.group_photo_guid = None;
        let (outcome, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-unbound-group-photo", None),
            &raw_presence(&["guid", "cid", "gid", "ogid", "svc", "stl", "ptcpts", "gp"]),
            &chat,
        );
        assert_eq!(
            outcome,
            CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnsupportedGroupPhoto
            )
        );
        assert_eq!(
            diagnostic,
            Some(CloudChatDiagnosticCode::GroupPhotoMissingStableGuid)
        );
    }

    #[test]
    fn unknown_protobuf_fields_preserve_the_protected_source_reference() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut encoded = MessageProto {
            unk1: 1,
            text: Some("known text".to_owned()),
            ..Default::default()
        }
        .encode_to_vec();
        // Unknown field 99, varint wire type, value 1. Prost safely ignores
        // the projection, while the protected raw envelope retains it.
        encoded.extend_from_slice(&[0x98, 0x06, 0x01]);
        let decoded = MessageProto::decode(encoded.as_slice()).expect("protobuf fixture");
        let mut message = normal_message(None);
        message.msg_proto = GZipWrapper(decoded);
        let outcome = convert_message(
            &context(&hasher, "server-message-unknown-proto", None),
            &message_presence(),
            &message,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("unknown protobuf fields should not block known projection");
        };
        assert_eq!(
            mutation
                .envelope()
                .protected_raw_envelope_reference()
                .value(),
            "obcs2.fixture.protected"
        );
    }

    #[test]
    fn url_balloon_projects_base_message_without_decoding_protected_payload() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message = normal_message(Some("https://example.com/path"));
        message.msg_proto.0.balloon_bundle_id = Some(URL_BALLOON_PROVIDER.to_owned());
        message.msg_proto.0.payload_data = Some(vec![0x01, 0x02, 0x03]);

        let outcome = convert_message(
            &context(&hasher, "server-url-balloon", None),
            &message_presence(),
            &message,
        );
        let payload = message_payload(&outcome);
        assert_eq!(
            payload.text(),
            &CloudCanonicalField::Value("https://example.com/path".to_owned())
        );
        assert_eq!(
            payload.balloon_bundle_id(),
            &CloudCanonicalField::Value(URL_BALLOON_PROVIDER.to_owned())
        );
        assert_eq!(
            payload.decoded_extension_payload(),
            &CloudCanonicalField::Absent
        );
    }

    #[test]
    fn sms_url_balloon_is_classified_outside_imessage_projection() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message = normal_message(Some("https://example.com/sms-path"));
        message.service = "SMS".to_owned();
        message.msg_proto.0.balloon_bundle_id = Some(URL_BALLOON_PROVIDER.to_owned());
        message.msg_proto.0.payload_data = Some(vec![0x01, 0x02, 0x03]);

        assert_eq!(
            convert_message(
                &context(&hasher, "server-sms-url-balloon", None),
                &message_presence(),
                &message,
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::SmsFamily
            )
        );
    }

    #[test]
    fn unknown_imessage_extension_payloads_remain_deferred() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        for balloon_bundle_id in [None, Some("com.example.UnknownBalloon")] {
            let mut message = normal_message(Some("base text"));
            message.msg_proto.0.balloon_bundle_id = balloon_bundle_id.map(str::to_owned);
            message.msg_proto.0.payload_data = Some(vec![0x01]);

            assert_eq!(
                convert_message(
                    &context(&hasher, "server-unsupported-extension", None),
                    &message_presence(),
                    &message,
                ),
                CloudCanonicalConversionOutcome::Deferred(
                    CloudCanonicalDeferredReason::UnsupportedExtensionPayload
                ),
                "balloon_bundle_id={balloon_bundle_id:?}"
            );
        }
    }

    #[test]
    fn explicit_clear_requires_authoritative_pre_typed_evidence() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut presence = chat_required_presence(false);
        presence
            .fields
            .insert("name".to_owned(), CloudRawFieldPresence::PresentWithValue);
        let (unsafe_guess, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-clear-unproven", None),
            &presence,
            &direct_chat(),
        );
        assert_eq!(
            unsafe_guess,
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::FieldPresenceMismatch
            )
        );
        assert_eq!(diagnostic, Some(CloudChatDiagnosticCode::DisplayNameField));

        presence
            .mark_top_level_explicit_clear("name")
            .expect("fixture carries authoritative clear evidence");
        let proven_clear = convert_chat(
            &context(&hasher, "server-chat-clear-proven", None),
            &presence,
            &direct_chat(),
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = proven_clear else {
            panic!("authoritative clear marker should convert");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.display_name_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::ExplicitClear
        );
    }

    #[test]
    fn chat_last_addressed_handle_mismatch_is_ignored_without_losing_identity() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();

        let absent_empty = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-lah-absent-empty", None),
            &chat_required_presence(false),
            &direct_chat(),
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = absent_empty.0 else {
            panic!("absent optional metadata should convert");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.last_addressed_handle_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
        assert_eq!(absent_empty.1, None);

        let mut absent_nonempty_chat = direct_chat();
        absent_nonempty_chat.last_addressed_handle = "tel:+15555550100".to_owned();
        let (absent_nonempty, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-lah-absent-nonempty", None),
            &chat_required_presence(false),
            &absent_nonempty_chat,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = absent_nonempty else {
            panic!("unproven optional metadata must not discard chat identity");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.last_addressed_handle_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
        assert!(!mutation.envelope().aliases().is_empty());
        assert_eq!(
            diagnostic,
            Some(CloudChatDiagnosticCode::LastAddressedHandleIgnoredUnproven)
        );

        let mut present_empty = chat_required_presence(false);
        present_empty
            .fields
            .insert("lah".to_owned(), CloudRawFieldPresence::PresentWithValue);
        let (present_empty_outcome, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-lah-present-empty", None),
            &present_empty,
            &direct_chat(),
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = present_empty_outcome else {
            panic!("unproven empty optional metadata must not discard chat identity");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.last_addressed_handle_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::Absent
        );
        assert_eq!(
            diagnostic,
            Some(CloudChatDiagnosticCode::LastAddressedHandleIgnoredUnproven)
        );

        let mut authoritative_clear = chat_required_presence(false);
        authoritative_clear
            .fields
            .insert("lah".to_owned(), CloudRawFieldPresence::PresentWithValue);
        authoritative_clear
            .mark_top_level_explicit_clear("lah")
            .expect("fixture carries authoritative clear evidence");
        let (authoritative_clear_outcome, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-lah-authoritative-clear", None),
            &authoritative_clear,
            &direct_chat(),
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = authoritative_clear_outcome else {
            panic!("authoritative optional clear should convert");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert_eq!(
            payload.last_addressed_handle_state(),
            crate::cloud_sync_canonical_dto::CloudCanonicalFieldState::ExplicitClear
        );
        assert_eq!(diagnostic, None);

        let mut missing_required_chat = direct_chat();
        missing_required_chat.last_addressed_handle = "tel:+15555550100".to_owned();
        let missing_required_presence = raw_presence(&["guid", "cid", "gid", "ogid", "svc", "stl"]);
        let (missing_required_outcome, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-lah-missing-required", None),
            &missing_required_presence,
            &missing_required_chat,
        );
        assert_eq!(
            missing_required_outcome,
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRequiredIdentity
            )
        );
        assert_eq!(
            diagnostic,
            Some(CloudChatDiagnosticCode::MissingParticipantsField)
        );

        let mut present_nonempty_chat = direct_chat();
        present_nonempty_chat.last_addressed_handle = "tel:+15555550100".to_owned();
        let mut present_nonempty = chat_required_presence(false);
        present_nonempty
            .fields
            .insert("lah".to_owned(), CloudRawFieldPresence::PresentWithValue);
        let (present_nonempty_outcome, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-lah-present-nonempty", None),
            &present_nonempty,
            &present_nonempty_chat,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = present_nonempty_outcome else {
            panic!("proven optional metadata should convert");
        };
        let Some(CloudCanonicalPayload::Chat(payload)) = mutation.payload() else {
            panic!("chat payload expected");
        };
        assert!(matches!(
            payload.last_addressed_handle(),
            CloudCanonicalField::Value(value) if value == "tel:+15555550100"
        ));
        assert_eq!(diagnostic, None);

        let mut present_without_value = chat_required_presence(false);
        present_without_value
            .fields
            .insert("lah".to_owned(), CloudRawFieldPresence::PresentWithoutValue);
        let (malformed, diagnostic) = convert_chat_with_diagnostic(
            &context(&hasher, "server-chat-lah-malformed", None),
            &present_without_value,
            &direct_chat(),
        );
        assert_eq!(
            malformed,
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord
            )
        );
        assert_eq!(
            diagnostic,
            Some(CloudChatDiagnosticCode::LastAddressedHandleField)
        );
    }

    #[test]
    fn reaction_fixture_carries_parent_metadata_before_parent_exists() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let outcome = convert_message(
            &context(&hasher, "server-reaction", None),
            &message_presence(),
            &reaction_message(),
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("reaction should convert without requiring parent storage");
        };
        assert_eq!(
            mutation.envelope().entity_kind(),
            CloudCanonicalEntityKind::Reaction
        );
        assert!(mutation.envelope().parent_logical_key_hash().is_some());
        let Some(CloudCanonicalPayload::Message(payload)) = mutation.payload() else {
            panic!("reaction message payload expected");
        };
        assert!(payload.association().is_reaction());
    }

    #[test]
    fn message_family_types_zero_one_and_two_accept_plain_messages() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        for message_type in 0..=2 {
            let mut message = normal_message(Some("hello"));
            message.r#type = message_type;
            assert!(
                matches!(
                    convert_message(
                        &context(
                            &hasher,
                            &format!("server-plain-message-type-{message_type}"),
                            None,
                        ),
                        &message_presence(),
                        &message,
                    ),
                    CloudCanonicalConversionOutcome::Ready(_)
                ),
                "msgType={message_type}",
            );
        }
    }

    #[test]
    fn message_chat_references_are_domain_separated_and_proto4_group_is_typed() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message = normal_message(Some("hello"));
        message.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            group_id: Some("corroborating-group".to_owned()),
            ..Default::default()
        }));
        let outcome = convert_message(
            &context(&hasher, "server-message-chat-references", None),
            &message_presence(),
            &message,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("message chat references should convert");
        };
        let Some(CloudCanonicalPayload::Message(payload)) = mutation.payload() else {
            panic!("message payload expected");
        };
        assert_eq!(
            payload.chat_id_exact_guid_logical_key_hash(),
            &hasher
                .canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, &message.chat_id)
                .unwrap()
        );
        assert_eq!(
            payload.chat_id_bare_direct_service_identifier_alias_key_hash(),
            None
        );
        assert_eq!(payload.chat_id_alias_candidates().len(), 4);
        for (candidate, expected_kind) in payload
            .chat_id_alias_candidates()
            .iter()
            .zip(CLOUD_CANONICAL_MESSAGE_CHAT_ALIAS_KINDS)
        {
            assert_eq!(candidate.kind(), expected_kind);
            assert_eq!(
                candidate.key_hash(),
                &hasher
                    .canonical_alias_key_hash(expected_kind, &message.chat_id)
                    .unwrap()
            );
        }
        assert_eq!(
            payload.msg_proto_4_group_id_alias_key_hash(),
            Some(
                &hasher
                    .canonical_alias_key_hash(
                        CloudCanonicalAliasKind::ChatGroupId,
                        "corroborating-group",
                    )
                    .unwrap()
            )
        );
    }

    #[test]
    fn bare_message_chat_id_exposes_only_a_qualified_direct_diagnostic_hash() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message = normal_message(Some("hello"));
        message.chat_id = "bare-direct-cid".to_owned();
        let outcome = convert_message(
            &context(&hasher, "server-message-bare-direct-candidate", None),
            &message_presence(),
            &message,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("bare message chat reference should convert");
        };
        let Some(CloudCanonicalPayload::Message(payload)) = mutation.payload() else {
            panic!("message payload expected");
        };
        assert_eq!(
            payload.chat_id_bare_direct_service_identifier_alias_key_hash(),
            Some(
                &hasher
                    .canonical_alias_key_hash(
                        CloudCanonicalAliasKind::ChatServiceIdentifier,
                        "iMessage;-;bare-direct-cid",
                    )
                    .unwrap()
            )
        );
        assert_eq!(
            payload
                .chat_id_alias_candidates()
                .first()
                .map(CloudCanonicalAlias::key_hash),
            Some(
                &hasher
                    .canonical_alias_key_hash(
                        CloudCanonicalAliasKind::ChatServiceIdentifier,
                        "bare-direct-cid",
                    )
                    .unwrap()
            )
        );

        let mut sms = normal_message(Some("hello"));
        sms.service = "SMS".to_owned();
        sms.chat_id = "bare-sms-cid".to_owned();
        let sms_outcome = convert_message(
            &context(&hasher, "server-message-bare-sms", None),
            &message_presence(),
            &sms,
        );
        assert_eq!(
            sms_outcome,
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::SmsFamily
            )
        );
    }

    #[test]
    fn explicit_zero_association_sentinel_accepts_only_standalone_shape() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut standalone = normal_message(Some("hello"));
        standalone.msg_proto.0.associated_message_type = Some(0);
        standalone.msg_proto.0.associated_message_range_location = Some(0);
        standalone.msg_proto.0.associated_message_range_length = Some(0);
        assert!(matches!(
            convert_message(
                &context(&hasher, "server-zero-association", None),
                &message_presence(),
                &standalone,
            ),
            CloudCanonicalConversionOutcome::Ready(_)
        ));

        let mut parented = standalone.clone();
        parented.msg_proto.0.associated_message_guid = Some("p:0/parent-guid".to_owned());
        assert_eq!(
            convert_message(
                &context(&hasher, "server-zero-association-parented", None),
                &message_presence(),
                &parented,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedParent
            )
        );

        let mut nonzero_range = standalone;
        nonzero_range.msg_proto.0.associated_message_range_length = Some(1);
        assert_eq!(
            convert_message(
                &context(&hasher, "server-zero-association-nonzero-range", None),
                &message_presence(),
                &nonzero_range,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedParent
            )
        );
    }

    #[test]
    fn association_subtype_not_outer_message_type_selects_reaction_semantics() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        for message_type in 0..=2 {
            for associated_type in [2000, 3000] {
                let mut reaction = reaction_message();
                reaction.r#type = message_type;
                reaction.msg_proto.0.associated_message_type = Some(associated_type);
                let outcome = convert_message(
                    &context(
                        &hasher,
                        &format!(
                            "server-reaction-message-type-{message_type}-association-{associated_type}"
                        ),
                        None,
                    ),
                    &message_presence(),
                    &reaction,
                );
                let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
                    panic!(
                        "msgType={message_type} associatedMessageType={associated_type} should convert"
                    );
                };
                assert_eq!(
                    mutation.envelope().entity_kind(),
                    CloudCanonicalEntityKind::Reaction
                );
                let Some(CloudCanonicalPayload::Message(payload)) = mutation.payload() else {
                    panic!("reaction message payload expected");
                };
                let Some((_, _, remove)) = payload.association().reaction() else {
                    panic!("reaction association expected");
                };
                assert_eq!(remove, associated_type == 3000);
            }
        }
    }

    #[test]
    fn special_outer_classes_remain_quarantined_with_or_without_association() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        for message_type in 3..=7 {
            let mut plain = normal_message(Some("hello"));
            plain.r#type = message_type;
            assert_eq!(
                convert_message(
                    &context(
                        &hasher,
                        &format!("server-special-plain-type-{message_type}"),
                        None,
                    ),
                    &message_presence(),
                    &plain,
                ),
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedMessageType
                ),
            );

            let mut associated = reaction_message();
            associated.r#type = message_type;
            assert_eq!(
                convert_message(
                    &context(
                        &hasher,
                        &format!("server-special-associated-type-{message_type}"),
                        None,
                    ),
                    &message_presence(),
                    &associated,
                ),
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedMessageType
                ),
            );
        }
    }

    #[test]
    fn reaction_identity_normalizes_p_and_bp_but_preserves_partless_semantics() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut reaction = reaction_message();

        reaction.msg_proto.0.associated_message_guid = Some("p:0/parent-guid".to_owned());
        let p = convert_message(
            &context(&hasher, "server-reaction-p", None),
            &message_presence(),
            &reaction,
        );
        reaction.msg_proto.0.associated_message_guid = Some("bp:0/parent-guid".to_owned());
        let bp = convert_message(
            &context(&hasher, "server-reaction-bp", None),
            &message_presence(),
            &reaction,
        );
        reaction.msg_proto.0.associated_message_guid = Some("parent-guid".to_owned());
        let partless = convert_message(
            &context(&hasher, "server-reaction-partless", None),
            &message_presence(),
            &reaction,
        );

        let CloudCanonicalConversionOutcome::Ready(p) = p else {
            panic!("p reaction should convert");
        };
        let CloudCanonicalConversionOutcome::Ready(bp) = bp else {
            panic!("bp reaction should convert");
        };
        let CloudCanonicalConversionOutcome::Ready(partless) = partless else {
            panic!("partless reaction should convert");
        };
        assert_eq!(
            p.envelope().logical_entity_key_hash(),
            bp.envelope().logical_entity_key_hash()
        );
        assert_eq!(
            p.envelope().parent_logical_key_hash(),
            bp.envelope().parent_logical_key_hash()
        );
        assert_eq!(
            p.envelope().parent_logical_key_hash(),
            partless.envelope().parent_logical_key_hash()
        );
        assert_ne!(
            p.envelope().logical_entity_key_hash(),
            partless.envelope().logical_entity_key_hash()
        );
    }

    #[test]
    fn emoji_reaction_content_is_required_only_for_the_emoji_reaction_kind() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut emoji = reaction_message();
        emoji.msg_proto.0.associated_message_type = Some(2006);
        assert_eq!(
            convert_message(
                &context(&hasher, "server-emoji-missing-content", None),
                &message_presence(),
                &emoji,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::InvalidCanonicalPayload
            )
        );

        emoji.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            associated_message_emoji: Some("😀".to_owned()),
            ..Default::default()
        }));
        assert!(matches!(
            convert_message(
                &context(&hasher, "server-emoji-reaction", None),
                &message_presence(),
                &emoji,
            ),
            CloudCanonicalConversionOutcome::Ready(_)
        ));

        let mut ordinary = reaction_message();
        ordinary.msg_proto_4 = emoji.msg_proto_4;
        assert_eq!(
            convert_message(
                &context(&hasher, "server-ordinary-with-emoji", None),
                &message_presence(),
                &ordinary,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::InvalidCanonicalPayload
            )
        );
    }

    #[test]
    fn reaction_parent_rejects_noncanonical_part_or_nested_guid_separator() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut reaction = reaction_message();
        for malformed in ["p:00/parent-guid", "p:0/parent/guid"] {
            reaction.msg_proto.0.associated_message_guid = Some(malformed.to_owned());
            assert_eq!(
                convert_message(
                    &context(&hasher, "server-malformed-reaction-parent", None),
                    &message_presence(),
                    &reaction,
                ),
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedParent
                ),
                "{malformed}"
            );
        }
    }

    #[test]
    fn reaction_cannot_smuggle_edit_or_retraction_state() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut reaction = reaction_message();
        // Carry real edit and retraction content. This previously used the
        // all-empty summary and passed only because empty collections were
        // being turned into a clear instruction, so the test was exercising
        // that fabricated state rather than actual smuggled state.
        let mut summary = MessageSummaryInfo {
            ep: vec![0],
            ..Default::default()
        };
        summary.ec.insert(
            "0".to_owned(),
            vec![WireMessageEdit {
                t: plain_encoded_attributed_body("smuggled edit"),
                d: 1_720_000_000_400.0,
                bcg: None,
            }],
        );
        reaction.msg_proto.0.message_summary_info = Some(encoded_message_summary(&summary));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-reaction-with-summary", None),
                &message_presence(),
                &reaction,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::InvalidCanonicalPayload
            )
        );
    }

    #[test]
    fn ambiguous_reply_is_quarantined_instead_of_guessed() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message = normal_message(Some("reply"));
        message.msg_proto_2 = Some(GZipWrapper(MessageProto2 {
            reply: Some("r:0:parent:ambiguous".to_owned()),
        }));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message-reply", None),
                &message_presence(),
                &message,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::AmbiguousReply
            )
        );
    }

    #[test]
    fn owned_attachment_keeps_entire_guid_suffix_and_owner_part() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attachment = AttachmentMeta {
            guid: "at_0_parent_guid_with_underscore".to_owned(),
            total_bytes: 42,
            is_outgoing: true,
            ..Default::default()
        };
        let outcome = convert_attachment(
            &context(&hasher, "server-attachment-owned", None),
            &attachment_presence(),
            &attachment,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("owned attachment should convert");
        };
        let Some(CloudCanonicalPayload::Attachment(payload)) = mutation.payload() else {
            panic!("attachment payload expected");
        };
        assert_eq!(payload.canonical_guid(), "parent_guid_with_underscore_0");
        assert_eq!(payload.owner_part(), Some(0));
        assert!(mutation.envelope().parent_logical_key_hash().is_some());
        assert_eq!(
            mutation.envelope().logical_entity_key_hash(),
            &hasher
                .canonical_owned_attachment_key_hash("parent_guid_with_underscore", 0)
                .unwrap()
        );
    }

    #[test]
    fn standalone_attachment_has_no_invented_owner() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attachment = AttachmentMeta {
            guid: "standalone-attachment-guid".to_owned(),
            total_bytes: 42,
            ..Default::default()
        };
        let outcome = convert_attachment(
            &context(&hasher, "server-attachment-standalone", None),
            &attachment_presence(),
            &attachment,
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("standalone attachment should convert");
        };
        let Some(CloudCanonicalPayload::Attachment(payload)) = mutation.payload() else {
            panic!("attachment payload expected");
        };
        assert_eq!(payload.canonical_guid(), "standalone-attachment-guid");
        assert_eq!(payload.owner_part(), None);
        assert!(mutation.envelope().parent_logical_key_hash().is_none());
    }

    #[test]
    fn malformed_required_identity_is_quarantined() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut presence = message_presence();
        presence.fields.remove("guid");
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message", None),
                &presence,
                &normal_message(Some("hello")),
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRequiredIdentity
            )
        );
    }

    #[test]
    fn sms_chat_metadata_remains_available_without_importing_sms_or_rcs_messages() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut sms_chat = direct_chat();
        sms_chat.service_name = "SMS".to_owned();
        let CloudCanonicalConversionOutcome::Ready(chat_mutation) = convert_chat(
            &context(&hasher, "server-sms-routing-chat", None),
            &chat_required_presence(false),
            &sms_chat,
        ) else {
            panic!("SMS chat metadata should remain a projection dependency");
        };
        let Some(CloudCanonicalPayload::Chat(chat_payload)) = chat_mutation.payload() else {
            panic!("SMS chat payload expected");
        };
        assert_eq!(chat_payload.service(), CloudCanonicalService::Sms);

        for (service_name, expected) in [
            ("SMS", CloudCanonicalOutOfScopeService::SmsFamily),
            ("RCS", CloudCanonicalOutOfScopeService::Rcs),
        ] {
            let mut message = normal_message(Some("hello"));
            message.service = service_name.to_owned();
            assert_eq!(
                convert_message(
                    &context(&hasher, "server-out-of-scope-message", None),
                    &message_presence(),
                    &message,
                ),
                CloudCanonicalConversionOutcome::OutOfScopeService(expected)
            );
        }

        let mut rcs_chat = direct_chat();
        rcs_chat.service_name = "RCS".to_owned();
        assert_eq!(
            convert_chat(
                &context(&hasher, "server-rcs-out-of-scope-chat", None),
                &chat_required_presence(false),
                &rcs_chat,
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::Rcs
            )
        );
    }

    #[test]
    fn unknown_facetime_and_case_variant_services_remain_typed_quarantines() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        for service_name in ["FaceTime", "carrier-extension", "sms", "rcs", ""] {
            let mut chat = direct_chat();
            chat.service_name = service_name.to_owned();
            assert_eq!(
                convert_chat(
                    &context(&hasher, "server-unsupported-chat", None),
                    &chat_required_presence(false),
                    &chat,
                ),
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedService
                ),
                "chat service={service_name}"
            );

            let mut message = normal_message(Some("hello"));
            message.service = service_name.to_owned();
            assert_eq!(
                convert_message(
                    &context(&hasher, "server-unsupported-message", None),
                    &message_presence(),
                    &message,
                ),
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedService
                ),
                "message service={service_name}"
            );
        }
    }

    #[test]
    fn carrier_service_transitions_remain_out_of_scope_while_imessage_is_strict() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut sms = normal_message(Some("hello"));
        sms.service = "SMS".to_owned();
        sms.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("SMS".to_owned()),
            ..Default::default()
        }));
        assert!(matches!(
            convert_message(
                &context(&hasher, "server-sms-matching-proto4", None),
                &message_presence(),
                &sms,
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::SmsFamily
            )
        ));

        sms.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("RCS".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-sms-conflicting-proto4", None),
                &message_presence(),
                &sms,
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::SmsFamily
            )
        );

        sms.msg_proto.0.associated_message_type = Some(2000);
        assert_eq!(
            convert_message(
                &context(&hasher, "server-sms-reaction-transition", None),
                &message_presence(),
                &sms,
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::SmsFamily
            )
        );

        sms.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("iMessage".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-sms-non-carrier-proto4", None),
                &message_presence(),
                &sms,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::UnsupportedService
            )
        );

        let mut rcs = normal_message(Some("hello"));
        rcs.service = "RCS".to_owned();
        rcs.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("RCS".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-rcs-matching-proto4", None),
                &message_presence(),
                &rcs,
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::Rcs
            )
        );

        rcs.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("SMS".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-rcs-conflicting-proto4", None),
                &message_presence(),
                &rcs,
            ),
            CloudCanonicalConversionOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::Rcs
            )
        );

        let mut imessage = normal_message(Some("hello"));
        imessage.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            service: Some("SMS".to_owned()),
            ..Default::default()
        }));
        assert_eq!(
            convert_message(
                &context(&hasher, "server-imessage-conflicting-proto4", None),
                &message_presence(),
                &imessage,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::UnsupportedService
            )
        );
    }

    #[test]
    fn unsupported_message_type_remains_a_typed_quarantine() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message_type = normal_message(Some("hello"));
        message_type.r#type = 99;
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message", None),
                &message_presence(),
                &message_type,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::UnsupportedMessageType
            )
        );
    }

    #[test]
    fn malformed_edits_are_quarantined() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut message = normal_message(Some("hello"));
        message.msg_proto.0.message_summary_info = Some(vec![1, 2, 3]);
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message", None),
                &message_presence(),
                &message,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedMessageSummary
            )
        );
        message.msg_proto.0.message_summary_info = Some(vec![0; MAX_MESSAGE_SUMMARY_BYTES + 1]);
        assert_eq!(
            convert_message(
                &context(&hasher, "server-message-oversized-summary", None),
                &message_presence(),
                &message,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::OversizedContent
            )
        );
    }

    #[test]
    fn valid_mmcs_metadata_converts_without_leaking_native_credentials() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let secret = "credential-secret";
        let mut attachment = AttachmentMeta {
            guid: "standalone-attachment-guid".to_owned(),
            total_bytes: 42,
            ..Default::default()
        };
        attachment.user_info = Some(MMCSAttachmentMeta {
            mmcs_signature_hex: Some("aa".repeat(32)),
            mmcs_owner: Some(format!("owner-{secret}")),
            mmcs_url: Some(format!("https://cvws.icloud-content.com/{secret}")),
            decryption_key: Some("bb".repeat(33)),
            file_size: Some(rustpush::cloud_messages::NumOrString::Num(42)),
            uti_type: Some("public.data".to_owned()),
            mime_type: Some("application/octet-stream".to_owned()),
            name: Some("file.bin".to_owned()),
            ..Default::default()
        });
        let outcome = convert_attachment(
            &context(&hasher, "server-attachment", None),
            &attachment_presence(),
            &attachment,
        );
        assert!(matches!(
            &outcome,
            CloudCanonicalConversionOutcome::Ready(_)
        ));
        assert!(!format!("{outcome:?}").contains(secret));
        assert_eq!(
            ready_attachment_payload(outcome).materialization_capability(),
            CloudCanonicalAttachmentMaterializationCapability::Materializable
        );
    }

    #[test]
    fn zero_byte_mmcs_attachment_projects_metadata_only_without_fabricating_size() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut attachment = AttachmentMeta {
            guid: "standalone-zero-byte-guid".to_owned(),
            total_bytes: 0,
            ..Default::default()
        };
        attachment.user_info = Some(MMCSAttachmentMeta {
            mmcs_signature_hex: Some("aa".repeat(32)),
            mmcs_owner: Some("owner".to_owned()),
            mmcs_url: Some("https://cvws.icloud-content.com/object".to_owned()),
            decryption_key: Some("bb".repeat(33)),
            file_size: Some(rustpush::cloud_messages::NumOrString::Num(0)),
            uti_type: Some("public.data".to_owned()),
            mime_type: Some("application/octet-stream".to_owned()),
            name: Some("empty.bin".to_owned()),
            ..Default::default()
        });

        let payload = ready_attachment_payload(convert_attachment(
            &context(&hasher, "server-zero-byte-attachment", None),
            &attachment_presence(),
            &attachment,
        ));
        assert_eq!(payload.total_bytes(), &CloudCanonicalField::Value(0));
        assert_eq!(
            payload.materialization_capability(),
            CloudCanonicalAttachmentMaterializationCapability::MetadataOnlyUnsupportedMediaCredentials
        );
    }

    #[test]
    fn missing_or_empty_attachment_guid_stays_quarantined() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attachment = AttachmentMeta {
            guid: "standalone-attachment-guid".to_owned(),
            total_bytes: 42,
            ..Default::default()
        };
        assert_eq!(
            convert_attachment(
                &context(&hasher, "server-missing-attachment-guid", None),
                &attachment_presence_with(&["tb", "ig"], true),
                &attachment,
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRequiredIdentity
            )
        );

        assert_eq!(
            convert_attachment(
                &context(&hasher, "server-empty-attachment-guid", None),
                &attachment_presence(),
                &AttachmentMeta {
                    guid: String::new(),
                    total_bytes: 42,
                    ..Default::default()
                },
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRequiredIdentity
            )
        );

        assert_eq!(
            convert_attachment(
                &context(&hasher, "server-malformed-owned-attachment-guid", None),
                &attachment_presence_with(&["aguid", "tb", "ig"], false),
                &AttachmentMeta {
                    guid: "at_malformed".to_owned(),
                    total_bytes: 42,
                    ..Default::default()
                },
            ),
            CloudCanonicalConversionOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedParent
            )
        );
    }

    #[test]
    fn missing_attachment_size_projects_metadata_only_without_fabrication() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attachment = AttachmentMeta {
            guid: "standalone-attachment-guid".to_owned(),
            total_bytes: 42,
            ..Default::default()
        };
        let payload = ready_attachment_payload(convert_attachment(
            &context(&hasher, "server-missing-attachment-size", None),
            &attachment_presence_with(&["aguid", "ig"], true),
            &attachment,
        ));
        assert_eq!(payload.total_bytes(), &CloudCanonicalField::Absent);
        assert_eq!(
            payload.materialization_capability(),
            CloudCanonicalAttachmentMaterializationCapability::MetadataOnlyUnsupportedMediaCredentials
        );
    }

    #[test]
    fn negative_attachment_size_remains_fail_closed() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        assert_eq!(
            convert_attachment(
                &context(&hasher, "server-negative-attachment-size", None),
                &attachment_presence_with(&["aguid", "tb", "ig"], false),
                &AttachmentMeta {
                    guid: "standalone-negative-size-guid".to_owned(),
                    total_bytes: -1,
                    ..Default::default()
                },
            ),
            CloudCanonicalConversionOutcome::Deferred(
                CloudCanonicalDeferredReason::UnsupportedNegativeAttachmentSize
            )
        );
    }

    #[test]
    fn missing_outgoing_flag_is_preserved_as_absent() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let outcome = convert_attachment(
            &context(&hasher, "server-missing-outgoing-flag", None),
            &attachment_presence_with(&["aguid", "tb"], true),
            &AttachmentMeta {
                guid: "standalone-attachment-guid".to_owned(),
                total_bytes: 42,
                is_outgoing: false,
                ..Default::default()
            },
        );
        let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
            panic!("attachment without ig should convert");
        };
        let Some(CloudCanonicalPayload::Attachment(payload)) = mutation.payload() else {
            panic!("attachment payload expected");
        };
        assert_eq!(payload.is_outgoing(), &CloudCanonicalField::Absent);
    }

    #[test]
    fn no_assets_change_page_remains_exact_fetch_eligible() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attachment = AttachmentMeta {
            guid: "standalone-attachment-guid".to_owned(),
            total_bytes: 42,
            ..Default::default()
        };
        let missing = attachment_presence_with(&["aguid", "tb", "ig"], false);
        let missing_payload = ready_attachment_payload(convert_attachment(
            &context(&hasher, "server-missing-asset", None),
            &missing,
            &attachment,
        ));
        assert_eq!(
            missing_payload.materialization_capability(),
            CloudCanonicalAttachmentMaterializationCapability::Materializable
        );

        let mut valueless = attachment_presence();
        valueless
            .fields
            .insert("lqa".to_owned(), CloudRawFieldPresence::PresentWithoutValue);
        let valueless_payload = ready_attachment_payload(convert_attachment(
            &context(&hasher, "server-valueless-asset", None),
            &valueless,
            &attachment,
        ));
        assert_eq!(
            valueless_payload.materialization_capability(),
            CloudCanonicalAttachmentMaterializationCapability::Materializable
        );
    }

    #[test]
    fn valid_inline_metadata_projects_without_a_native_inline_body_path() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let mut attachment = AttachmentMeta {
            guid: "standalone-inline-guid".to_owned(),
            total_bytes: 42,
            ..Default::default()
        };
        attachment.user_info = Some(MMCSAttachmentMeta {
            inline_attachment: Some("ia-0".to_owned()),
            message_part: Some("0".to_owned()),
            ..Default::default()
        });
        let payload = ready_attachment_payload(convert_attachment(
            &context(&hasher, "server-inline-attachment", None),
            &attachment_presence(),
            &attachment,
        ));
        assert_eq!(payload.total_bytes(), &CloudCanonicalField::Value(42));
        assert_eq!(
            payload.materialization_capability(),
            CloudCanonicalAttachmentMaterializationCapability::MetadataOnlyUnsupportedMediaCredentials
        );
    }

    #[test]
    fn valid_inline_metadata_without_asset_projects_metadata_only() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let attachment = AttachmentMeta {
            guid: "standalone-inline-guid".to_owned(),
            total_bytes: 42,
            user_info: Some(MMCSAttachmentMeta {
                inline_attachment: Some("ia-0".to_owned()),
                message_part: Some("0".to_owned()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let payload = ready_attachment_payload(convert_attachment(
            &context(&hasher, "server-inline-without-asset", None),
            &attachment_presence_with(&["aguid", "tb", "ig"], false),
            &attachment,
        ));
        assert_eq!(
            payload.materialization_capability(),
            CloudCanonicalAttachmentMaterializationCapability::MetadataOnlyUnsupportedMediaCredentials
        );
    }

    #[test]
    fn incomplete_or_mixed_media_metadata_is_quarantined() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let base = AttachmentMeta {
            guid: "standalone-attachment-guid".to_owned(),
            total_bytes: 42,
            ..Default::default()
        };
        let cases = [
            MMCSAttachmentMeta::default(),
            MMCSAttachmentMeta {
                mmcs_signature_hex: Some("aa".repeat(32)),
                mmcs_owner: Some("owner".to_owned()),
                mmcs_url: Some("https://cvws.icloud-content.com/object".to_owned()),
                ..Default::default()
            },
            MMCSAttachmentMeta {
                inline_attachment: Some("ia-0".to_owned()),
                message_part: Some("0".to_owned()),
                mmcs_signature_hex: Some("aa".repeat(32)),
                ..Default::default()
            },
            MMCSAttachmentMeta {
                inline_attachment: Some("ia-2".to_owned()),
                message_part: Some("0".to_owned()),
                ..Default::default()
            },
            MMCSAttachmentMeta {
                mmcs_signature_hex: Some("not-hex".to_owned()),
                mmcs_owner: Some("owner".to_owned()),
                mmcs_url: Some("https://cvws.icloud-content.com/object".to_owned()),
                decryption_key: Some("bb".repeat(33)),
                ..Default::default()
            },
            MMCSAttachmentMeta {
                mmcs_signature_hex: Some("aa".repeat(32)),
                mmcs_owner: Some("owner".to_owned()),
                mmcs_url: Some("http://cvws.icloud-content.com/object".to_owned()),
                decryption_key: Some("bb".repeat(33)),
                ..Default::default()
            },
        ];
        for user_info in cases {
            let mut attachment = base.clone();
            attachment.user_info = Some(user_info);
            assert_eq!(
                convert_attachment(
                    &context(&hasher, "server-attachment-malformed-ui", None),
                    &attachment_presence(),
                    &attachment,
                ),
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedRecord
                )
            );
        }
    }

    #[test]
    fn tombstone_supports_present_or_missing_server_time() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        for expected in [Some(1_720_000_000_999), None] {
            let outcome = convert_tombstone(
                &context(&hasher, "server-message-tombstone", expected),
                CloudCanonicalEntityKind::Message,
                hash('d'),
            );
            let CloudCanonicalConversionOutcome::Ready(mutation) = outcome else {
                panic!("server-confirmed tombstone should convert");
            };
            assert_eq!(
                mutation
                    .tombstone()
                    .expect("tombstone payload")
                    .deleted_at_millis(),
                expected
            );
        }
    }

    #[test]
    fn debug_and_errors_never_expose_secret_material() {
        let hasher = CloudSemanticIdentifierHasher::new(SECRET.as_bytes()).unwrap();
        let mut message = normal_message(Some(SECRET));
        message.guid = format!("message-{SECRET}");
        let outcome = convert_message(
            &context(&hasher, SECRET, None),
            &message_presence(),
            &message,
        );
        let rendered = format!(
            "{outcome:?} {:?} {}",
            message_presence(),
            CloudRawPresenceFailure::MalformedNestedPlist
        );
        assert!(!rendered.contains(SECRET));
        assert!(!format!("{:?}", context(&hasher, SECRET, None)).contains(SECRET));
    }

    #[test]
    fn presence_extractor_rejects_duplicate_or_value_less_fields() {
        let duplicate = Record {
            record_field: vec![
                Field {
                    identifier: Some(field::Identifier {
                        name: Some("guid".to_owned()),
                    }),
                    value: Some(field::Value::default()),
                },
                Field {
                    identifier: Some(field::Identifier {
                        name: Some("guid".to_owned()),
                    }),
                    value: None,
                },
            ],
            ..Default::default()
        };
        assert_eq!(
            CloudRawRecordPresence::extract(&duplicate),
            Err(CloudRawPresenceFailure::DuplicateFieldIdentifier)
        );

        let value_less = Record {
            record_field: vec![Field {
                identifier: Some(field::Identifier {
                    name: Some("guid".to_owned()),
                }),
                value: None,
            }],
            ..Default::default()
        };
        let presence = CloudRawRecordPresence::extract(&value_less).unwrap();
        assert_eq!(
            presence.field("guid"),
            CloudRawFieldPresence::PresentWithoutValue
        );
    }

    #[test]
    fn presence_extractor_preserves_the_empty_list_wire_type() {
        // CloudKit distinguishes "present but empty" from absent with its own
        // wire type. Discarding the tag here left a live fetch unable to report
        // whether Apple emits it, which is the evidence the merge contract
        // depends on.
        let record = Record {
            record_field: vec![
                Field {
                    identifier: Some(field::Identifier {
                        name: Some("empty".to_owned()),
                    }),
                    value: Some(field::Value {
                        r#type: Some(CloudKitFieldType::EmptyList as i32),
                        ..Default::default()
                    }),
                },
                Field {
                    identifier: Some(field::Identifier {
                        name: Some("populated".to_owned()),
                    }),
                    value: Some(field::Value {
                        r#type: Some(CloudKitFieldType::StringType as i32),
                        string_value: Some("value".to_owned()),
                        ..Default::default()
                    }),
                },
                Field {
                    identifier: Some(field::Identifier {
                        name: Some("untyped".to_owned()),
                    }),
                    value: Some(field::Value::default()),
                },
            ],
            ..Default::default()
        };

        let presence = CloudRawRecordPresence::extract(&record).unwrap();

        assert!(presence.was_sent_as_empty_list("empty"));
        assert!(!presence.was_sent_as_empty_list("populated"));
        assert!(!presence.was_sent_as_empty_list("untyped"));
        assert!(!presence.was_sent_as_empty_list("absent"));
        assert_eq!(presence.empty_list_field_names(), vec!["empty"]);

        // Recording the observation must not move any conversion decision.
        // Whether an empty list means "clear" is unanswered, so it still reads
        // as an ordinary valued field until a live run settles the question.
        assert_eq!(
            presence.field("empty"),
            CloudRawFieldPresence::PresentWithValue
        );
    }

    #[test]
    fn source_remains_private_and_unwired() {
        let source = concat!(
            include_str!("cloud_sync_canonical_converter.rs"),
            include_str!("cloud_sync_canonical_dto.rs")
        );
        for forbidden in [
            concat!("flutter_", "rust_bridge::frb"),
            concat!("#[", "frb"),
            concat!("ser", "de::Serialize"),
            concat!("object", "box"),
            concat!("apply", "FromCloud"),
            concat!("print", "ln!"),
            concat!("eprint", "ln!"),
            concat!("db", "g!"),
            concat!("log", "::"),
            concat!("tracing", "::"),
        ] {
            assert!(
                !source.contains(forbidden),
                "private converter must not contain {forbidden}"
            );
        }
    }
}
