//! Private, dormant canonical DTO contract for Cloud Sync V2.
//!
//! These types separate content-free replay metadata from transient canonical
//! payloads. They are intentionally not exposed through Flutter Rust Bridge
//! and are not connected to the semantic decoder or local database.

#![allow(dead_code)]

use std::{
    collections::HashSet,
    fmt::{self, Debug, Formatter},
    hash::Hash,
};

pub(crate) const CLOUD_CANONICAL_SCHEMA_VERSION: u16 = 1;

const HASH_BYTES: usize = 43;
const MAX_IDENTIFIER_BYTES: usize = 16 * 1024;
const MAX_TEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_BINARY_PAYLOAD_BYTES: usize = 16 * 1024 * 1024;
const MAX_PROTECTED_REFERENCE_BYTES: usize = 32 * 1024;
const MAX_PARTICIPANTS: usize = 4_096;
const MAX_ATTRIBUTED_BODIES: usize = 4_096;
const MAX_RUNS_PER_BODY: usize = 65_536;
const MAX_EDITS: usize = 65_536;
const MAX_RETRACTED_PARTS: usize = 65_536;
const MAX_ALIASES: usize = 4_096;
const MAX_TRANSIENT_AGGREGATE_BYTES: usize = 32 * 1024 * 1024;
const MAX_TRANSIENT_COLLECTION_ELEMENTS: usize = 131_072;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudCanonicalEntityKind {
    Chat,
    Message,
    Reaction,
    Attachment,
    GroupPhoto,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudCanonicalMutationKind {
    Upsert,
    Tombstone,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudCanonicalAliasKind {
    ChatGroupId,
    ChatOriginalGroupId,
    ChatServiceIdentifier,
    ChatLegacyGroupIdentifier,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudCanonicalService {
    IMessage,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudCanonicalChatStyle {
    Direct,
    Group,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudCanonicalReactionKind {
    Heart,
    Like,
    Dislike,
    Laugh,
    Emphasize,
    Question,
    Emoji,
    StickerBack,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudCanonicalFieldState {
    Absent,
    Value,
    ExplicitClear,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudCanonicalValidationFailure {
    UnsupportedSchema,
    InvalidHash,
    InvalidProtectedReference,
    InvalidIdentifier,
    InvalidText,
    CollectionLimit,
    InvalidRange,
    InvalidPayload,
    InvalidEnvelope,
    InvalidSnapshot,
    InvalidTombstone,
    ScopeMismatch,
    MalformedAssociatedParent,
    MalformedAttachmentOwner,
    MalformedReplyParent,
    AmbiguousReplyParent,
}

impl fmt::Display for CloudCanonicalValidationFailure {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::UnsupportedSchema => "Cloud Sync canonical schema is unsupported",
            Self::InvalidHash => "Cloud Sync canonical hash is invalid",
            Self::InvalidProtectedReference => {
                "Cloud Sync canonical protected reference is invalid"
            }
            Self::InvalidIdentifier => "Cloud Sync canonical identifier is invalid",
            Self::InvalidText => "Cloud Sync canonical text is invalid",
            Self::CollectionLimit => "Cloud Sync canonical collection exceeds its bound",
            Self::InvalidRange => "Cloud Sync canonical attributed range is invalid",
            Self::InvalidPayload => "Cloud Sync canonical payload invariant failed",
            Self::InvalidEnvelope => "Cloud Sync canonical envelope invariant failed",
            Self::InvalidSnapshot => "Cloud Sync canonical snapshot invariant failed",
            Self::InvalidTombstone => "Cloud Sync canonical tombstone invariant failed",
            Self::ScopeMismatch => "Cloud Sync canonical active scope does not match",
            Self::MalformedAssociatedParent => "Cloud Sync associated-message parent is malformed",
            Self::MalformedAttachmentOwner => "Cloud Sync attachment owner is malformed",
            Self::MalformedReplyParent => "Cloud Sync reply parent is malformed",
            Self::AmbiguousReplyParent => "Cloud Sync reply parent grammar is ambiguous",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for CloudCanonicalValidationFailure {}

#[derive(Clone, Eq, Hash, PartialEq)]
pub(crate) struct CloudCanonicalHash(String);

impl CloudCanonicalHash {
    pub(crate) fn new(value: impl Into<String>) -> Result<Self, CloudCanonicalValidationFailure> {
        let value = value.into();
        if value.len() != HASH_BYTES
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        {
            return Err(CloudCanonicalValidationFailure::InvalidHash);
        }
        Ok(Self(value))
    }

    pub(crate) fn value(&self) -> &str {
        &self.0
    }
}

impl Debug for CloudCanonicalHash {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalHash(redacted)")
    }
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub(crate) struct CloudCanonicalDigest(String);

impl CloudCanonicalDigest {
    pub(crate) fn new(value: impl Into<String>) -> Result<Self, CloudCanonicalValidationFailure> {
        let value = value.into();
        let is_base64url = value.len() == HASH_BYTES
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'));
        let is_hex = value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit());
        if !is_base64url && !is_hex {
            return Err(CloudCanonicalValidationFailure::InvalidHash);
        }
        Ok(Self(value))
    }

    pub(crate) fn value(&self) -> &str {
        &self.0
    }
}

impl Debug for CloudCanonicalDigest {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalDigest(redacted)")
    }
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub(crate) struct CloudCanonicalProtectedReference(String);

impl CloudCanonicalProtectedReference {
    pub(crate) fn new(value: impl Into<String>) -> Result<Self, CloudCanonicalValidationFailure> {
        let value = value.into();
        if value.len() > MAX_PROTECTED_REFERENCE_BYTES
            || !value.starts_with("obcs2.")
            || !value.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':')
            })
        {
            return Err(CloudCanonicalValidationFailure::InvalidProtectedReference);
        }
        Ok(Self(value))
    }

    pub(crate) fn value(&self) -> &str {
        &self.0
    }
}

impl Debug for CloudCanonicalProtectedReference {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalProtectedReference(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) enum CloudCanonicalField<T> {
    Absent,
    Value(T),
    ExplicitClear,
}

impl<T> CloudCanonicalField<T> {
    pub(crate) fn state(&self) -> CloudCanonicalFieldState {
        match self {
            Self::Absent => CloudCanonicalFieldState::Absent,
            Self::Value(_) => CloudCanonicalFieldState::Value,
            Self::ExplicitClear => CloudCanonicalFieldState::ExplicitClear,
        }
    }

    pub(crate) fn value(&self) -> Option<&T> {
        match self {
            Self::Value(value) => Some(value),
            Self::Absent | Self::ExplicitClear => None,
        }
    }
}

impl<T> Debug for CloudCanonicalField<T> {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        let state = match self {
            Self::Absent => "absent",
            Self::Value(_) => "value-redacted",
            Self::ExplicitClear => "explicit-clear",
        };
        formatter
            .debug_tuple("CloudCanonicalField")
            .field(&state)
            .finish()
    }
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub(crate) struct CloudCanonicalAlias {
    kind: CloudCanonicalAliasKind,
    key_hash: CloudCanonicalHash,
}

impl CloudCanonicalAlias {
    pub(crate) fn new(kind: CloudCanonicalAliasKind, key_hash: CloudCanonicalHash) -> Self {
        Self { kind, key_hash }
    }
}

impl Debug for CloudCanonicalAlias {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalAlias(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalEnvelope {
    scope_fingerprint: CloudCanonicalHash,
    zone_fingerprint: CloudCanonicalHash,
    generation: u64,
    schema_version: u16,
    change_id: CloudCanonicalHash,
    entity_kind: CloudCanonicalEntityKind,
    mutation_kind: CloudCanonicalMutationKind,
    server_record_id_hash: CloudCanonicalHash,
    logical_entity_key_hash: CloudCanonicalHash,
    parent_logical_key_hash: Option<CloudCanonicalHash>,
    aliases: Vec<CloudCanonicalAlias>,
    etag_hash: Option<CloudCanonicalHash>,
    server_created_at_millis: Option<i64>,
    server_modified_at_millis: Option<i64>,
    protected_raw_envelope_reference: CloudCanonicalProtectedReference,
}

impl CloudCanonicalEnvelope {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        scope_fingerprint: CloudCanonicalHash,
        zone_fingerprint: CloudCanonicalHash,
        generation: u64,
        schema_version: u16,
        change_id: CloudCanonicalHash,
        entity_kind: CloudCanonicalEntityKind,
        mutation_kind: CloudCanonicalMutationKind,
        server_record_id_hash: CloudCanonicalHash,
        logical_entity_key_hash: CloudCanonicalHash,
        parent_logical_key_hash: Option<CloudCanonicalHash>,
        aliases: Vec<CloudCanonicalAlias>,
        etag_hash: Option<CloudCanonicalHash>,
        server_created_at_millis: Option<i64>,
        server_modified_at_millis: Option<i64>,
        protected_raw_envelope_reference: CloudCanonicalProtectedReference,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        if schema_version != CLOUD_CANONICAL_SCHEMA_VERSION
            || aliases.len() > MAX_ALIASES
            || parent_logical_key_hash
                .as_ref()
                .is_some_and(|parent| parent == &logical_entity_key_hash)
        {
            return Err(if schema_version != CLOUD_CANONICAL_SCHEMA_VERSION {
                CloudCanonicalValidationFailure::UnsupportedSchema
            } else {
                CloudCanonicalValidationFailure::InvalidEnvelope
            });
        }

        if entity_kind != CloudCanonicalEntityKind::Chat && !aliases.is_empty() {
            return Err(CloudCanonicalValidationFailure::InvalidEnvelope);
        }
        match entity_kind {
            CloudCanonicalEntityKind::Chat if parent_logical_key_hash.is_some() => {
                return Err(CloudCanonicalValidationFailure::InvalidEnvelope);
            }
            CloudCanonicalEntityKind::Reaction | CloudCanonicalEntityKind::GroupPhoto
                if parent_logical_key_hash.is_none() =>
            {
                return Err(CloudCanonicalValidationFailure::InvalidEnvelope);
            }
            _ => {}
        }

        let mut alias_keys = HashSet::with_capacity(aliases.len());
        for alias in &aliases {
            if !alias_keys.insert((alias.kind, alias.key_hash.value())) {
                return Err(CloudCanonicalValidationFailure::InvalidEnvelope);
            }
        }

        Ok(Self {
            scope_fingerprint,
            zone_fingerprint,
            generation,
            schema_version,
            change_id,
            entity_kind,
            mutation_kind,
            server_record_id_hash,
            logical_entity_key_hash,
            parent_logical_key_hash,
            aliases,
            etag_hash,
            server_created_at_millis,
            server_modified_at_millis,
            protected_raw_envelope_reference,
        })
    }

    pub(crate) fn validate_active_context(
        &self,
        expected_scope_fingerprint: &CloudCanonicalHash,
        expected_zone_fingerprint: &CloudCanonicalHash,
        expected_generation: u64,
    ) -> Result<(), CloudCanonicalValidationFailure> {
        if &self.scope_fingerprint != expected_scope_fingerprint
            || &self.zone_fingerprint != expected_zone_fingerprint
            || self.generation != expected_generation
        {
            return Err(CloudCanonicalValidationFailure::ScopeMismatch);
        }
        Ok(())
    }

    pub(crate) fn entity_kind(&self) -> CloudCanonicalEntityKind {
        self.entity_kind
    }

    pub(crate) fn generation(&self) -> u64 {
        self.generation
    }

    pub(crate) fn change_id(&self) -> &CloudCanonicalHash {
        &self.change_id
    }

    pub(crate) fn mutation_kind(&self) -> CloudCanonicalMutationKind {
        self.mutation_kind
    }

    pub(crate) fn logical_entity_key_hash(&self) -> &CloudCanonicalHash {
        &self.logical_entity_key_hash
    }

    pub(crate) fn etag_hash(&self) -> Option<&CloudCanonicalHash> {
        self.etag_hash.as_ref()
    }

    pub(crate) fn parent_logical_key_hash(&self) -> Option<&CloudCanonicalHash> {
        self.parent_logical_key_hash.as_ref()
    }

    pub(crate) fn protected_raw_envelope_reference(&self) -> &CloudCanonicalProtectedReference {
        &self.protected_raw_envelope_reference
    }
}

impl Debug for CloudCanonicalEnvelope {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalEnvelope(redacted)")
    }
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub(crate) struct CloudCanonicalEditPartSnapshot {
    part_key_hash: CloudCanonicalHash,
    revision: u32,
    content_digest: CloudCanonicalDigest,
    modified_at_millis: i64,
}

impl CloudCanonicalEditPartSnapshot {
    pub(crate) fn new(
        part_key_hash: CloudCanonicalHash,
        revision: u32,
        content_digest: CloudCanonicalDigest,
        modified_at_millis: i64,
    ) -> Self {
        Self {
            part_key_hash,
            revision,
            content_digest,
            modified_at_millis,
        }
    }

    pub(crate) fn revision(&self) -> u32 {
        self.revision
    }

    pub(crate) fn part_key_hash(&self) -> &CloudCanonicalHash {
        &self.part_key_hash
    }

    pub(crate) fn content_digest(&self) -> &CloudCanonicalDigest {
        &self.content_digest
    }

    pub(crate) fn modified_at_millis(&self) -> i64 {
        self.modified_at_millis
    }
}

impl Debug for CloudCanonicalEditPartSnapshot {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalEditPartSnapshot(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalSnapshot {
    entity_kind: CloudCanonicalEntityKind,
    logical_entity_key_hash: CloudCanonicalHash,
    parent_logical_key_hash: Option<CloudCanonicalHash>,
    immutable_content_digest: Option<CloudCanonicalDigest>,
    created_at_millis: Option<i64>,
    read_at_millis: Option<i64>,
    delivered_at_millis: Option<i64>,
    edit_parts: Vec<CloudCanonicalEditPartSnapshot>,
    retracted_at_millis: Option<i64>,
    group_version: Option<u32>,
    group_metadata_digest: Option<CloudCanonicalDigest>,
    etag_hash: Option<CloudCanonicalHash>,
    protected_raw_envelope_reference: CloudCanonicalProtectedReference,
}

impl CloudCanonicalSnapshot {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        entity_kind: CloudCanonicalEntityKind,
        logical_entity_key_hash: CloudCanonicalHash,
        parent_logical_key_hash: Option<CloudCanonicalHash>,
        immutable_content_digest: Option<CloudCanonicalDigest>,
        created_at_millis: Option<i64>,
        read_at_millis: Option<i64>,
        delivered_at_millis: Option<i64>,
        edit_parts: Vec<CloudCanonicalEditPartSnapshot>,
        retracted_at_millis: Option<i64>,
        group_version: Option<u32>,
        group_metadata_digest: Option<CloudCanonicalDigest>,
        etag_hash: Option<CloudCanonicalHash>,
        protected_raw_envelope_reference: CloudCanonicalProtectedReference,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        if edit_parts.len() > MAX_EDITS
            || (entity_kind != CloudCanonicalEntityKind::Message
                && (!edit_parts.is_empty()
                    || read_at_millis.is_some()
                    || delivered_at_millis.is_some()
                    || retracted_at_millis.is_some()))
            || (entity_kind != CloudCanonicalEntityKind::Chat
                && (group_version.is_some() || group_metadata_digest.is_some()))
        {
            return Err(CloudCanonicalValidationFailure::InvalidSnapshot);
        }

        match entity_kind {
            CloudCanonicalEntityKind::Chat if parent_logical_key_hash.is_some() => {
                return Err(CloudCanonicalValidationFailure::InvalidSnapshot);
            }
            CloudCanonicalEntityKind::Reaction | CloudCanonicalEntityKind::GroupPhoto
                if parent_logical_key_hash.is_none() =>
            {
                return Err(CloudCanonicalValidationFailure::InvalidSnapshot);
            }
            _ => {}
        }

        let mut edit_keys = HashSet::with_capacity(edit_parts.len());
        for edit in &edit_parts {
            if !edit_keys.insert((edit.part_key_hash.value(), edit.revision)) {
                return Err(CloudCanonicalValidationFailure::InvalidSnapshot);
            }
        }

        Ok(Self {
            entity_kind,
            logical_entity_key_hash,
            parent_logical_key_hash,
            immutable_content_digest,
            created_at_millis,
            read_at_millis,
            delivered_at_millis,
            edit_parts,
            retracted_at_millis,
            group_version,
            group_metadata_digest,
            etag_hash,
            protected_raw_envelope_reference,
        })
    }

    fn validate_for_envelope(
        &self,
        envelope: &CloudCanonicalEnvelope,
    ) -> Result<(), CloudCanonicalValidationFailure> {
        if self.entity_kind != envelope.entity_kind
            || self.logical_entity_key_hash != envelope.logical_entity_key_hash
            || self.parent_logical_key_hash != envelope.parent_logical_key_hash
            || self.protected_raw_envelope_reference != envelope.protected_raw_envelope_reference
            || self.etag_hash != envelope.etag_hash
        {
            return Err(CloudCanonicalValidationFailure::InvalidSnapshot);
        }
        Ok(())
    }

    pub(crate) fn edit_parts(&self) -> &[CloudCanonicalEditPartSnapshot] {
        &self.edit_parts
    }

    pub(crate) fn entity_kind(&self) -> CloudCanonicalEntityKind {
        self.entity_kind
    }

    pub(crate) fn logical_entity_key_hash(&self) -> &CloudCanonicalHash {
        &self.logical_entity_key_hash
    }

    pub(crate) fn parent_logical_key_hash(&self) -> Option<&CloudCanonicalHash> {
        self.parent_logical_key_hash.as_ref()
    }

    pub(crate) fn immutable_content_digest(&self) -> Option<&CloudCanonicalDigest> {
        self.immutable_content_digest.as_ref()
    }

    pub(crate) fn created_at_millis(&self) -> Option<i64> {
        self.created_at_millis
    }

    pub(crate) fn read_at_millis(&self) -> Option<i64> {
        self.read_at_millis
    }

    pub(crate) fn delivered_at_millis(&self) -> Option<i64> {
        self.delivered_at_millis
    }

    pub(crate) fn retracted_at_millis(&self) -> Option<i64> {
        self.retracted_at_millis
    }

    pub(crate) fn group_version(&self) -> Option<u32> {
        self.group_version
    }

    pub(crate) fn group_metadata_digest(&self) -> Option<&CloudCanonicalDigest> {
        self.group_metadata_digest.as_ref()
    }

    pub(crate) fn etag_hash(&self) -> Option<&CloudCanonicalHash> {
        self.etag_hash.as_ref()
    }

    pub(crate) fn protected_raw_envelope_reference(&self) -> &CloudCanonicalProtectedReference {
        &self.protected_raw_envelope_reference
    }
}

impl Debug for CloudCanonicalSnapshot {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalSnapshot(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalTombstone {
    entity_kind: CloudCanonicalEntityKind,
    server_record_id_hash: CloudCanonicalHash,
    logical_entity_key_hash: CloudCanonicalHash,
    protected_raw_envelope_reference: CloudCanonicalProtectedReference,
    deleted_at_millis: Option<i64>,
    server_confirmed: bool,
}

impl CloudCanonicalTombstone {
    pub(crate) fn new(
        entity_kind: CloudCanonicalEntityKind,
        server_record_id_hash: CloudCanonicalHash,
        logical_entity_key_hash: CloudCanonicalHash,
        protected_raw_envelope_reference: CloudCanonicalProtectedReference,
        deleted_at_millis: Option<i64>,
        server_confirmed: bool,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        if !server_confirmed {
            return Err(CloudCanonicalValidationFailure::InvalidTombstone);
        }
        Ok(Self {
            entity_kind,
            server_record_id_hash,
            logical_entity_key_hash,
            protected_raw_envelope_reference,
            deleted_at_millis,
            server_confirmed,
        })
    }

    fn validate_for_envelope(
        &self,
        envelope: &CloudCanonicalEnvelope,
    ) -> Result<(), CloudCanonicalValidationFailure> {
        if self.entity_kind != envelope.entity_kind
            || self.server_record_id_hash != envelope.server_record_id_hash
            || self.logical_entity_key_hash != envelope.logical_entity_key_hash
            || self.protected_raw_envelope_reference != envelope.protected_raw_envelope_reference
            || self.deleted_at_millis != envelope.server_modified_at_millis
            || !self.server_confirmed
        {
            return Err(CloudCanonicalValidationFailure::InvalidTombstone);
        }
        Ok(())
    }

    pub(crate) fn deleted_at_millis(&self) -> Option<i64> {
        self.deleted_at_millis
    }

    pub(crate) fn entity_kind(&self) -> CloudCanonicalEntityKind {
        self.entity_kind
    }

    pub(crate) fn logical_entity_key_hash(&self) -> &CloudCanonicalHash {
        &self.logical_entity_key_hash
    }

    pub(crate) fn server_confirmed(&self) -> bool {
        self.server_confirmed
    }
}

impl Debug for CloudCanonicalTombstone {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalTombstone(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalChatPayload {
    guid: String,
    chat_identifier: String,
    group_id: String,
    original_group_id: String,
    service: CloudCanonicalService,
    style: CloudCanonicalChatStyle,
    participant_handles: Vec<String>,
    display_name: CloudCanonicalField<String>,
    last_addressed_handle: CloudCanonicalField<String>,
    group_version: CloudCanonicalField<u32>,
    last_seen_message_guid: CloudCanonicalField<String>,
    group_photo_guid: CloudCanonicalField<String>,
}

impl CloudCanonicalChatPayload {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        guid: String,
        chat_identifier: String,
        group_id: String,
        original_group_id: String,
        service: CloudCanonicalService,
        style: CloudCanonicalChatStyle,
        participant_handles: Vec<String>,
        display_name: CloudCanonicalField<String>,
        last_addressed_handle: CloudCanonicalField<String>,
        group_version: CloudCanonicalField<u32>,
        last_seen_message_guid: CloudCanonicalField<String>,
        group_photo_guid: CloudCanonicalField<String>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        for value in [&guid, &chat_identifier, &group_id, &original_group_id] {
            validate_identifier(value)?;
        }
        if participant_handles.len() > MAX_PARTICIPANTS {
            return Err(CloudCanonicalValidationFailure::CollectionLimit);
        }
        for handle in &participant_handles {
            validate_identifier(handle)?;
        }
        validate_optional_text(&display_name)?;
        validate_optional_identifier(&last_addressed_handle)?;
        validate_optional_identifier(&last_seen_message_guid)?;
        validate_optional_identifier(&group_photo_guid)?;
        let mut aggregate_bytes = guid
            .len()
            .checked_add(chat_identifier.len())
            .and_then(|size| size.checked_add(group_id.len()))
            .and_then(|size| size.checked_add(original_group_id.len()))
            .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
        for participant in &participant_handles {
            aggregate_bytes = aggregate_bytes
                .checked_add(participant.len())
                .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
        }
        for field in [
            &display_name,
            &last_addressed_handle,
            &last_seen_message_guid,
            &group_photo_guid,
        ] {
            aggregate_bytes = aggregate_bytes
                .checked_add(field.value().map_or(0, String::len))
                .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
        }
        if aggregate_bytes > MAX_TRANSIENT_AGGREGATE_BYTES {
            return Err(CloudCanonicalValidationFailure::CollectionLimit);
        }

        Ok(Self {
            guid,
            chat_identifier,
            group_id,
            original_group_id,
            service,
            style,
            participant_handles,
            display_name,
            last_addressed_handle,
            group_version,
            last_seen_message_guid,
            group_photo_guid,
        })
    }

    pub(crate) fn display_name_state(&self) -> CloudCanonicalFieldState {
        self.display_name.state()
    }

    pub(crate) fn group_version_state(&self) -> CloudCanonicalFieldState {
        self.group_version.state()
    }

    pub(crate) fn group_photo_guid_state(&self) -> CloudCanonicalFieldState {
        self.group_photo_guid.state()
    }

    pub(crate) fn participant_handles(&self) -> &[String] {
        &self.participant_handles
    }

    pub(crate) fn display_name(&self) -> &CloudCanonicalField<String> {
        &self.display_name
    }
}

impl Debug for CloudCanonicalChatPayload {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalChatPayload(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalAttachmentReference {
    canonical_guid: String,
    logical_key_hash: CloudCanonicalHash,
}

impl CloudCanonicalAttachmentReference {
    pub(crate) fn new(
        canonical_guid: String,
        logical_key_hash: CloudCanonicalHash,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        validate_identifier(&canonical_guid)?;
        Ok(Self {
            canonical_guid,
            logical_key_hash,
        })
    }
}

impl Debug for CloudCanonicalAttachmentReference {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalAttachmentReference(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalTextRun {
    start_utf16: u32,
    length_utf16: u32,
    message_part: Option<u32>,
    attachment: Option<CloudCanonicalAttachmentReference>,
    mention: Option<String>,
    audio_transcript: Option<String>,
    text_effect: Option<i64>,
    bold: Option<bool>,
    italic: Option<bool>,
    strikethrough: Option<bool>,
    underline: Option<bool>,
}

impl CloudCanonicalTextRun {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        start_utf16: u32,
        length_utf16: u32,
        message_part: Option<u32>,
        attachment: Option<CloudCanonicalAttachmentReference>,
        mention: Option<String>,
        audio_transcript: Option<String>,
        text_effect: Option<i64>,
        bold: Option<bool>,
        italic: Option<bool>,
        strikethrough: Option<bool>,
        underline: Option<bool>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        if start_utf16.checked_add(length_utf16).is_none() {
            return Err(CloudCanonicalValidationFailure::InvalidRange);
        }
        if let Some(mention) = &mention {
            validate_identifier(mention)?;
        }
        if let Some(transcript) = &audio_transcript {
            validate_text(transcript)?;
        }
        Ok(Self {
            start_utf16,
            length_utf16,
            message_part,
            attachment,
            mention,
            audio_transcript,
            text_effect,
            bold,
            italic,
            strikethrough,
            underline,
        })
    }

    fn transient_size(&self) -> Option<(usize, usize)> {
        let bytes = self
            .mention
            .as_ref()
            .map_or(0, String::len)
            .checked_add(self.audio_transcript.as_ref().map_or(0, String::len))?;
        Some((bytes, 1))
    }

    pub(crate) fn message_part(&self) -> Option<u32> {
        self.message_part
    }

    pub(crate) fn has_attachment(&self) -> bool {
        self.attachment.is_some()
    }
}

impl Debug for CloudCanonicalTextRun {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalTextRun(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalAttributedBody {
    text: String,
    runs: Vec<CloudCanonicalTextRun>,
}

impl CloudCanonicalAttributedBody {
    pub(crate) fn new(
        text: String,
        runs: Vec<CloudCanonicalTextRun>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        validate_text(&text)?;
        if runs.len() > MAX_RUNS_PER_BODY {
            return Err(CloudCanonicalValidationFailure::CollectionLimit);
        }
        let utf16_length = text.encode_utf16().count();
        for run in &runs {
            let end = run
                .start_utf16
                .checked_add(run.length_utf16)
                .ok_or(CloudCanonicalValidationFailure::InvalidRange)?;
            if end as usize > utf16_length {
                return Err(CloudCanonicalValidationFailure::InvalidRange);
            }
        }
        Ok(Self { text, runs })
    }

    fn transient_size(&self) -> Option<(usize, usize)> {
        let mut bytes = self.text.len();
        let mut elements = 1usize;
        for run in &self.runs {
            let (run_bytes, run_elements) = run.transient_size()?;
            bytes = bytes.checked_add(run_bytes)?;
            elements = elements.checked_add(run_elements)?;
        }
        Some((bytes, elements))
    }

    pub(crate) fn text_utf16_length(&self) -> usize {
        self.text.encode_utf16().count()
    }

    pub(crate) fn runs(&self) -> &[CloudCanonicalTextRun] {
        &self.runs
    }
}

impl Debug for CloudCanonicalAttributedBody {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalAttributedBody(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalParentReference {
    parent_guid: String,
    parent_part: u32,
    parent_logical_key_hash: CloudCanonicalHash,
    range_location: Option<u32>,
    range_length: Option<u32>,
}

impl CloudCanonicalParentReference {
    pub(crate) fn new(
        parent_guid: String,
        parent_part: u32,
        parent_logical_key_hash: CloudCanonicalHash,
        range_location: Option<u32>,
        range_length: Option<u32>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        validate_identifier(&parent_guid)?;
        if range_location.is_some() != range_length.is_some()
            || range_location
                .zip(range_length)
                .is_some_and(|(start, length)| start.checked_add(length).is_none())
        {
            return Err(CloudCanonicalValidationFailure::InvalidRange);
        }
        Ok(Self {
            parent_guid,
            parent_part,
            parent_logical_key_hash,
            range_location,
            range_length,
        })
    }
}

impl Debug for CloudCanonicalParentReference {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalParentReference(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalReplyReference {
    parent_guid: String,
    parent_part: String,
    parent_logical_key_hash: CloudCanonicalHash,
}

impl CloudCanonicalReplyReference {
    pub(crate) fn new(
        parent_guid: String,
        parent_part: String,
        parent_logical_key_hash: CloudCanonicalHash,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        validate_identifier(&parent_guid)?;
        validate_identifier(&parent_part)?;
        if parent_guid.contains(':') || parent_part.contains(':') {
            return Err(CloudCanonicalValidationFailure::AmbiguousReplyParent);
        }
        Ok(Self {
            parent_guid,
            parent_part,
            parent_logical_key_hash,
        })
    }

    pub(crate) fn parent_hash(&self) -> &CloudCanonicalHash {
        &self.parent_logical_key_hash
    }
}

impl Debug for CloudCanonicalReplyReference {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalReplyReference(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) enum CloudCanonicalMessageAssociation {
    None,
    Sticker(CloudCanonicalParentReference),
    ReactionAdd {
        kind: CloudCanonicalReactionKind,
        parent: CloudCanonicalParentReference,
    },
    ReactionRemove {
        kind: CloudCanonicalReactionKind,
        parent: CloudCanonicalParentReference,
    },
}

impl CloudCanonicalMessageAssociation {
    fn entity_kind(&self) -> CloudCanonicalEntityKind {
        match self {
            Self::ReactionAdd { .. } | Self::ReactionRemove { .. } => {
                CloudCanonicalEntityKind::Reaction
            }
            Self::None | Self::Sticker(_) => CloudCanonicalEntityKind::Message,
        }
    }

    fn parent_hash(&self) -> Option<&CloudCanonicalHash> {
        match self {
            Self::None => None,
            Self::Sticker(parent)
            | Self::ReactionAdd { parent, .. }
            | Self::ReactionRemove { parent, .. } => Some(&parent.parent_logical_key_hash),
        }
    }

    pub(crate) fn is_reaction(&self) -> bool {
        matches!(self, Self::ReactionAdd { .. } | Self::ReactionRemove { .. })
    }

    pub(crate) fn reaction(
        &self,
    ) -> Option<(CloudCanonicalReactionKind, &CloudCanonicalHash, bool)> {
        match self {
            Self::ReactionAdd { kind, parent } => {
                Some((*kind, &parent.parent_logical_key_hash, false))
            }
            Self::ReactionRemove { kind, parent } => {
                Some((*kind, &parent.parent_logical_key_hash, true))
            }
            Self::None | Self::Sticker(_) => None,
        }
    }

    pub(crate) fn is_sticker(&self) -> bool {
        matches!(self, Self::Sticker(_))
    }
}

impl Debug for CloudCanonicalMessageAssociation {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::None => "none",
            Self::Sticker(_) => "sticker-redacted",
            Self::ReactionAdd { .. } => "reaction-add-redacted",
            Self::ReactionRemove { .. } => "reaction-remove-redacted",
        };
        formatter
            .debug_tuple("CloudCanonicalMessageAssociation")
            .field(&label)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct CloudCanonicalKnownMessageFlags {
    pub(crate) from_me: bool,
    pub(crate) delivered: bool,
    pub(crate) read: bool,
    pub(crate) has_data_detector_results: bool,
    pub(crate) delivered_quietly: bool,
    pub(crate) did_notify_recipient: bool,
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalMessageEdit {
    part: u32,
    revision: u32,
    bodies: Vec<CloudCanonicalAttributedBody>,
    modified_at_millis: i64,
    original_range: Option<(u32, u32)>,
}

impl CloudCanonicalMessageEdit {
    pub(crate) fn new(
        part: u32,
        revision: u32,
        bodies: Vec<CloudCanonicalAttributedBody>,
        modified_at_millis: i64,
        original_range: Option<(u32, u32)>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        if bodies.is_empty() || bodies.len() > MAX_ATTRIBUTED_BODIES {
            return Err(CloudCanonicalValidationFailure::InvalidPayload);
        }
        if original_range.is_some_and(|(start, length)| start.checked_add(length).is_none()) {
            return Err(CloudCanonicalValidationFailure::InvalidRange);
        }
        Ok(Self {
            part,
            revision,
            bodies,
            modified_at_millis,
            original_range,
        })
    }

    fn transient_size(&self) -> Option<(usize, usize)> {
        let mut bytes = 0usize;
        let mut elements = 1usize;
        for body in &self.bodies {
            let (body_bytes, body_elements) = body.transient_size()?;
            bytes = bytes.checked_add(body_bytes)?;
            elements = elements.checked_add(body_elements)?;
        }
        Some((bytes, elements))
    }

    pub(crate) fn part(&self) -> u32 {
        self.part
    }

    pub(crate) fn revision(&self) -> u32 {
        self.revision
    }

    pub(crate) fn modified_at_millis(&self) -> i64 {
        self.modified_at_millis
    }
}

impl Debug for CloudCanonicalMessageEdit {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalMessageEdit(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalMessagePayload {
    guid: String,
    chat_alias_key_hash: CloudCanonicalHash,
    sender_handle: String,
    created_at_millis: i64,
    error: i64,
    service: CloudCanonicalService,
    subject: CloudCanonicalField<String>,
    text: CloudCanonicalField<String>,
    attributed_bodies: CloudCanonicalField<Vec<CloudCanonicalAttributedBody>>,
    balloon_bundle_id: CloudCanonicalField<String>,
    decoded_extension_payload: CloudCanonicalField<Vec<u8>>,
    effect: CloudCanonicalField<String>,
    read_at_millis: CloudCanonicalField<i64>,
    delivered_at_millis: CloudCanonicalField<i64>,
    flags: CloudCanonicalKnownMessageFlags,
    association: CloudCanonicalMessageAssociation,
    reply: Option<CloudCanonicalReplyReference>,
    edits: CloudCanonicalField<Vec<CloudCanonicalMessageEdit>>,
    retracted_parts: CloudCanonicalField<Vec<u32>>,
    associated_emoji: CloudCanonicalField<String>,
}

impl CloudCanonicalMessagePayload {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        guid: String,
        chat_alias_key_hash: CloudCanonicalHash,
        sender_handle: String,
        created_at_millis: i64,
        error: i64,
        service: CloudCanonicalService,
        subject: CloudCanonicalField<String>,
        text: CloudCanonicalField<String>,
        attributed_bodies: CloudCanonicalField<Vec<CloudCanonicalAttributedBody>>,
        balloon_bundle_id: CloudCanonicalField<String>,
        decoded_extension_payload: CloudCanonicalField<Vec<u8>>,
        effect: CloudCanonicalField<String>,
        read_at_millis: CloudCanonicalField<i64>,
        delivered_at_millis: CloudCanonicalField<i64>,
        flags: CloudCanonicalKnownMessageFlags,
        association: CloudCanonicalMessageAssociation,
        reply: Option<CloudCanonicalReplyReference>,
        edits: CloudCanonicalField<Vec<CloudCanonicalMessageEdit>>,
        retracted_parts: CloudCanonicalField<Vec<u32>>,
        associated_emoji: CloudCanonicalField<String>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        validate_identifier(&guid)?;
        if !sender_handle.is_empty() {
            validate_identifier(&sender_handle)?;
        }
        validate_optional_text(&subject)?;
        validate_optional_text(&text)?;
        validate_optional_identifier(&balloon_bundle_id)?;
        validate_optional_identifier(&effect)?;
        validate_optional_text(&associated_emoji)?;
        if decoded_extension_payload
            .value()
            .is_some_and(|payload| payload.len() > MAX_BINARY_PAYLOAD_BYTES)
            || attributed_bodies
                .value()
                .is_some_and(|bodies| bodies.len() > MAX_ATTRIBUTED_BODIES)
            || edits.value().is_some_and(|edits| edits.len() > MAX_EDITS)
            || retracted_parts
                .value()
                .is_some_and(|parts| parts.len() > MAX_RETRACTED_PARTS)
        {
            return Err(CloudCanonicalValidationFailure::CollectionLimit);
        }
        if let Some(edits) = edits.value() {
            let mut edit_keys = HashSet::with_capacity(edits.len());
            for edit in edits {
                if !edit_keys.insert((edit.part, edit.revision)) {
                    return Err(CloudCanonicalValidationFailure::InvalidPayload);
                }
            }
        }
        if let Some(retracted_parts) = retracted_parts.value() {
            let mut retracted = HashSet::with_capacity(retracted_parts.len());
            if retracted_parts.iter().any(|part| !retracted.insert(*part)) {
                return Err(CloudCanonicalValidationFailure::InvalidPayload);
            }
        }
        if (!matches!(&association, CloudCanonicalMessageAssociation::None) && reply.is_some())
            || (association.is_reaction()
                && (!matches!(&edits, CloudCanonicalField::Absent)
                    || !matches!(&retracted_parts, CloudCanonicalField::Absent)))
        {
            return Err(CloudCanonicalValidationFailure::InvalidPayload);
        }
        let emoji_association = matches!(
            association,
            CloudCanonicalMessageAssociation::ReactionAdd {
                kind: CloudCanonicalReactionKind::Emoji,
                ..
            } | CloudCanonicalMessageAssociation::ReactionRemove {
                kind: CloudCanonicalReactionKind::Emoji,
                ..
            }
        );
        if emoji_association
            != matches!(
                associated_emoji,
                CloudCanonicalField::Value(ref value) if !value.is_empty()
            )
        {
            return Err(CloudCanonicalValidationFailure::InvalidPayload);
        }

        let mut aggregate_bytes = guid
            .len()
            .checked_add(sender_handle.len())
            .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
        for field in [
            &subject,
            &text,
            &balloon_bundle_id,
            &effect,
            &associated_emoji,
        ] {
            aggregate_bytes = aggregate_bytes
                .checked_add(field.value().map_or(0, String::len))
                .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
        }
        aggregate_bytes = aggregate_bytes
            .checked_add(decoded_extension_payload.value().map_or(0, Vec::len))
            .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
        let mut aggregate_elements = retracted_parts.value().map_or(0, Vec::len);
        if let Some(bodies) = attributed_bodies.value() {
            for body in bodies {
                let (bytes, elements) = body
                    .transient_size()
                    .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
                aggregate_bytes = aggregate_bytes
                    .checked_add(bytes)
                    .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
                aggregate_elements = aggregate_elements
                    .checked_add(elements)
                    .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
            }
        }
        if let Some(edits) = edits.value() {
            for edit in edits {
                let (bytes, elements) = edit
                    .transient_size()
                    .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
                aggregate_bytes = aggregate_bytes
                    .checked_add(bytes)
                    .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
                aggregate_elements = aggregate_elements
                    .checked_add(elements)
                    .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
            }
        }
        if aggregate_bytes > MAX_TRANSIENT_AGGREGATE_BYTES
            || aggregate_elements > MAX_TRANSIENT_COLLECTION_ELEMENTS
        {
            return Err(CloudCanonicalValidationFailure::CollectionLimit);
        }

        Ok(Self {
            guid,
            chat_alias_key_hash,
            sender_handle,
            created_at_millis,
            error,
            service,
            subject,
            text,
            attributed_bodies,
            balloon_bundle_id,
            decoded_extension_payload,
            effect,
            read_at_millis,
            delivered_at_millis,
            flags,
            association,
            reply,
            edits,
            retracted_parts,
            associated_emoji,
        })
    }

    fn entity_kind(&self) -> CloudCanonicalEntityKind {
        self.association.entity_kind()
    }

    fn parent_hash(&self) -> Option<&CloudCanonicalHash> {
        self.association.parent_hash().or_else(|| {
            self.reply
                .as_ref()
                .map(CloudCanonicalReplyReference::parent_hash)
        })
    }

    pub(crate) fn text_state(&self) -> CloudCanonicalFieldState {
        self.text.state()
    }

    pub(crate) fn association(&self) -> &CloudCanonicalMessageAssociation {
        &self.association
    }

    pub(crate) fn attributed_bodies_state(&self) -> CloudCanonicalFieldState {
        self.attributed_bodies.state()
    }

    pub(crate) fn edits_state(&self) -> CloudCanonicalFieldState {
        self.edits.state()
    }

    pub(crate) fn edit_count(&self) -> usize {
        self.edits.value().map_or(0, Vec::len)
    }

    pub(crate) fn attributed_bodies(&self) -> &[CloudCanonicalAttributedBody] {
        self.attributed_bodies
            .value()
            .map(Vec::as_slice)
            .unwrap_or_default()
    }

    pub(crate) fn edits(&self) -> &[CloudCanonicalMessageEdit] {
        self.edits.value().map(Vec::as_slice).unwrap_or_default()
    }

    pub(crate) fn retracted_parts_state(&self) -> CloudCanonicalFieldState {
        self.retracted_parts.state()
    }

    pub(crate) fn retracted_parts(&self) -> &[u32] {
        self.retracted_parts
            .value()
            .map(Vec::as_slice)
            .unwrap_or_default()
    }

    pub(crate) fn chat_alias_key_hash(&self) -> &CloudCanonicalHash {
        &self.chat_alias_key_hash
    }

    pub(crate) fn sender_handle(&self) -> &str {
        &self.sender_handle
    }

    pub(crate) fn text(&self) -> &CloudCanonicalField<String> {
        &self.text
    }

    pub(crate) fn associated_emoji(&self) -> &CloudCanonicalField<String> {
        &self.associated_emoji
    }
}

impl Debug for CloudCanonicalMessagePayload {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalMessagePayload(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalAttachmentPayload {
    canonical_guid: String,
    owner_message_key_hash: Option<CloudCanonicalHash>,
    owner_part: Option<u32>,
    uti: CloudCanonicalField<String>,
    mime_type: CloudCanonicalField<String>,
    transfer_name: CloudCanonicalField<String>,
    total_bytes: CloudCanonicalField<u64>,
    is_outgoing: CloudCanonicalField<bool>,
    verified_local_file_reference: CloudCanonicalField<CloudCanonicalProtectedReference>,
}

impl CloudCanonicalAttachmentPayload {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        canonical_guid: String,
        owner_message_key_hash: Option<CloudCanonicalHash>,
        owner_part: Option<u32>,
        uti: CloudCanonicalField<String>,
        mime_type: CloudCanonicalField<String>,
        transfer_name: CloudCanonicalField<String>,
        total_bytes: CloudCanonicalField<u64>,
        is_outgoing: CloudCanonicalField<bool>,
        verified_local_file_reference: CloudCanonicalField<CloudCanonicalProtectedReference>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        validate_identifier(&canonical_guid)?;
        if owner_message_key_hash.is_some() != owner_part.is_some() {
            return Err(CloudCanonicalValidationFailure::InvalidPayload);
        }
        validate_optional_identifier(&uti)?;
        validate_optional_identifier(&mime_type)?;
        validate_optional_text(&transfer_name)?;
        let aggregate_bytes = canonical_guid
            .len()
            .checked_add(uti.value().map_or(0, String::len))
            .and_then(|size| size.checked_add(mime_type.value().map_or(0, String::len)))
            .and_then(|size| size.checked_add(transfer_name.value().map_or(0, String::len)))
            .ok_or(CloudCanonicalValidationFailure::CollectionLimit)?;
        if aggregate_bytes > MAX_TRANSIENT_AGGREGATE_BYTES {
            return Err(CloudCanonicalValidationFailure::CollectionLimit);
        }
        Ok(Self {
            canonical_guid,
            owner_message_key_hash,
            owner_part,
            uti,
            mime_type,
            transfer_name,
            total_bytes,
            is_outgoing,
            verified_local_file_reference,
        })
    }

    fn parent_hash(&self) -> Option<&CloudCanonicalHash> {
        self.owner_message_key_hash.as_ref()
    }

    pub(crate) fn canonical_guid(&self) -> &str {
        &self.canonical_guid
    }

    pub(crate) fn owner_part(&self) -> Option<u32> {
        self.owner_part
    }

    pub(crate) fn owner_message_key_hash(&self) -> Option<&CloudCanonicalHash> {
        self.owner_message_key_hash.as_ref()
    }

    pub(crate) fn mime_type(&self) -> &CloudCanonicalField<String> {
        &self.mime_type
    }

    pub(crate) fn transfer_name(&self) -> &CloudCanonicalField<String> {
        &self.transfer_name
    }

    pub(crate) fn verified_local_file_reference(
        &self,
    ) -> &CloudCanonicalField<CloudCanonicalProtectedReference> {
        &self.verified_local_file_reference
    }
}

impl Debug for CloudCanonicalAttachmentPayload {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalAttachmentPayload(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalGroupPhotoPayload {
    chat_key_hash: CloudCanonicalHash,
    photo_key_hash: CloudCanonicalHash,
    photo_guid: String,
    verified_local_file_reference: CloudCanonicalProtectedReference,
}

impl CloudCanonicalGroupPhotoPayload {
    pub(crate) fn new(
        chat_key_hash: CloudCanonicalHash,
        photo_key_hash: CloudCanonicalHash,
        photo_guid: String,
        verified_local_file_reference: CloudCanonicalProtectedReference,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        validate_identifier(&photo_guid)?;
        if chat_key_hash == photo_key_hash {
            return Err(CloudCanonicalValidationFailure::InvalidPayload);
        }
        Ok(Self {
            chat_key_hash,
            photo_key_hash,
            photo_guid,
            verified_local_file_reference,
        })
    }

    fn parent_hash(&self) -> &CloudCanonicalHash {
        &self.chat_key_hash
    }

    pub(crate) fn chat_key_hash(&self) -> &CloudCanonicalHash {
        &self.chat_key_hash
    }

    pub(crate) fn verified_local_file_reference(&self) -> &CloudCanonicalProtectedReference {
        &self.verified_local_file_reference
    }
}

impl Debug for CloudCanonicalGroupPhotoPayload {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalGroupPhotoPayload(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) enum CloudCanonicalPayload {
    Chat(Box<CloudCanonicalChatPayload>),
    Message(Box<CloudCanonicalMessagePayload>),
    Attachment(Box<CloudCanonicalAttachmentPayload>),
    GroupPhoto(Box<CloudCanonicalGroupPhotoPayload>),
}

impl CloudCanonicalPayload {
    fn entity_kind(&self) -> CloudCanonicalEntityKind {
        match self {
            Self::Chat(_) => CloudCanonicalEntityKind::Chat,
            Self::Message(payload) => payload.entity_kind(),
            Self::Attachment(_) => CloudCanonicalEntityKind::Attachment,
            Self::GroupPhoto(_) => CloudCanonicalEntityKind::GroupPhoto,
        }
    }

    fn parent_hash(&self) -> Option<&CloudCanonicalHash> {
        match self {
            Self::Chat(_) => None,
            Self::Message(payload) => payload.parent_hash(),
            Self::Attachment(payload) => payload.parent_hash(),
            Self::GroupPhoto(payload) => Some(payload.parent_hash()),
        }
    }
}

impl Debug for CloudCanonicalPayload {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Chat(_) => "chat-redacted",
            Self::Message(_) => "message-redacted",
            Self::Attachment(_) => "attachment-redacted",
            Self::GroupPhoto(_) => "group-photo-redacted",
        };
        formatter
            .debug_tuple("CloudCanonicalPayload")
            .field(&label)
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudCanonicalMutation {
    envelope: CloudCanonicalEnvelope,
    snapshot: Option<CloudCanonicalSnapshot>,
    payload: Option<CloudCanonicalPayload>,
    tombstone: Option<CloudCanonicalTombstone>,
}

impl CloudCanonicalMutation {
    pub(crate) fn new(
        envelope: CloudCanonicalEnvelope,
        snapshot: Option<CloudCanonicalSnapshot>,
        payload: Option<CloudCanonicalPayload>,
        tombstone: Option<CloudCanonicalTombstone>,
    ) -> Result<Self, CloudCanonicalValidationFailure> {
        match envelope.mutation_kind {
            CloudCanonicalMutationKind::Upsert => {
                let snapshot = snapshot
                    .as_ref()
                    .ok_or(CloudCanonicalValidationFailure::InvalidEnvelope)?;
                let payload = payload
                    .as_ref()
                    .ok_or(CloudCanonicalValidationFailure::InvalidEnvelope)?;
                if tombstone.is_some()
                    || payload.entity_kind() != envelope.entity_kind
                    || payload.parent_hash() != envelope.parent_logical_key_hash.as_ref()
                {
                    return Err(CloudCanonicalValidationFailure::InvalidPayload);
                }
                snapshot.validate_for_envelope(&envelope)?;
            }
            CloudCanonicalMutationKind::Tombstone => {
                let tombstone = tombstone
                    .as_ref()
                    .ok_or(CloudCanonicalValidationFailure::InvalidTombstone)?;
                if snapshot.is_some() || payload.is_some() {
                    return Err(CloudCanonicalValidationFailure::InvalidTombstone);
                }
                tombstone.validate_for_envelope(&envelope)?;
            }
        }
        Ok(Self {
            envelope,
            snapshot,
            payload,
            tombstone,
        })
    }

    pub(crate) fn validate_active_context(
        &self,
        expected_scope_fingerprint: &CloudCanonicalHash,
        expected_zone_fingerprint: &CloudCanonicalHash,
        expected_generation: u64,
    ) -> Result<(), CloudCanonicalValidationFailure> {
        self.envelope.validate_active_context(
            expected_scope_fingerprint,
            expected_zone_fingerprint,
            expected_generation,
        )
    }

    pub(crate) fn envelope(&self) -> &CloudCanonicalEnvelope {
        &self.envelope
    }

    pub(crate) fn payload(&self) -> Option<&CloudCanonicalPayload> {
        self.payload.as_ref()
    }

    pub(crate) fn snapshot(&self) -> Option<&CloudCanonicalSnapshot> {
        self.snapshot.as_ref()
    }

    pub(crate) fn tombstone(&self) -> Option<&CloudCanonicalTombstone> {
        self.tombstone.as_ref()
    }
}

impl Debug for CloudCanonicalMutation {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudCanonicalMutation(redacted)")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct ParsedOwnedAttachment {
    message_guid: String,
    part: u32,
    canonical_guid: String,
}

impl Debug for ParsedOwnedAttachment {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("ParsedOwnedAttachment(redacted)")
    }
}

pub(crate) fn parse_owned_attachment_guid(
    value: &str,
) -> Result<ParsedOwnedAttachment, CloudCanonicalValidationFailure> {
    let body = value
        .strip_prefix("at_")
        .ok_or(CloudCanonicalValidationFailure::MalformedAttachmentOwner)?;
    let (part, message_guid) = body
        .split_once('_')
        .ok_or(CloudCanonicalValidationFailure::MalformedAttachmentOwner)?;
    if part.is_empty()
        || !part.bytes().all(|byte| byte.is_ascii_digit())
        || (part.len() > 1 && part.starts_with('0'))
        || message_guid.is_empty()
        || message_guid.contains('/')
    {
        return Err(CloudCanonicalValidationFailure::MalformedAttachmentOwner);
    }
    let part = part
        .parse::<u32>()
        .map_err(|_| CloudCanonicalValidationFailure::MalformedAttachmentOwner)?;
    validate_identifier(message_guid)
        .map_err(|_| CloudCanonicalValidationFailure::MalformedAttachmentOwner)?;
    Ok(ParsedOwnedAttachment {
        message_guid: message_guid.to_owned(),
        part,
        canonical_guid: format!("{message_guid}_{part}"),
    })
}

impl ParsedOwnedAttachment {
    pub(crate) fn message_guid(&self) -> &str {
        &self.message_guid
    }

    pub(crate) fn part(&self) -> u32 {
        self.part
    }

    pub(crate) fn canonical_guid(&self) -> &str {
        &self.canonical_guid
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct ParsedAssociatedParent {
    parent_guid: String,
    parent_part: u32,
}

impl Debug for ParsedAssociatedParent {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("ParsedAssociatedParent(redacted)")
    }
}

pub(crate) fn parse_associated_parent(
    value: &str,
) -> Result<ParsedAssociatedParent, CloudCanonicalValidationFailure> {
    let body = value
        .strip_prefix("p:")
        .ok_or(CloudCanonicalValidationFailure::MalformedAssociatedParent)?;
    let (part, parent_guid) = body
        .split_once('/')
        .ok_or(CloudCanonicalValidationFailure::MalformedAssociatedParent)?;
    if part.is_empty()
        || !part.bytes().all(|byte| byte.is_ascii_digit())
        || (part.len() > 1 && part.starts_with('0'))
        || parent_guid.is_empty()
        || parent_guid.contains('/')
    {
        return Err(CloudCanonicalValidationFailure::MalformedAssociatedParent);
    }
    let parent_part = part
        .parse::<u32>()
        .map_err(|_| CloudCanonicalValidationFailure::MalformedAssociatedParent)?;
    validate_identifier(parent_guid)
        .map_err(|_| CloudCanonicalValidationFailure::MalformedAssociatedParent)?;
    Ok(ParsedAssociatedParent {
        parent_guid: parent_guid.to_owned(),
        parent_part,
    })
}

impl ParsedAssociatedParent {
    pub(crate) fn parent_guid(&self) -> &str {
        &self.parent_guid
    }

    pub(crate) fn parent_part(&self) -> u32 {
        self.parent_part
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct ParsedReplyParent {
    parent_guid: String,
    parent_part: String,
}

impl Debug for ParsedReplyParent {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("ParsedReplyParent(redacted)")
    }
}

pub(crate) fn parse_reply_parent(
    value: &str,
) -> Result<ParsedReplyParent, CloudCanonicalValidationFailure> {
    let body = value
        .strip_prefix("r:")
        .ok_or(CloudCanonicalValidationFailure::MalformedReplyParent)?;
    let mut parts = body.split(':');
    let parent_part = parts
        .next()
        .ok_or(CloudCanonicalValidationFailure::MalformedReplyParent)?;
    let parent_guid = parts
        .next()
        .ok_or(CloudCanonicalValidationFailure::MalformedReplyParent)?;
    if parts.next().is_some() {
        return Err(CloudCanonicalValidationFailure::AmbiguousReplyParent);
    }
    if parent_part.is_empty()
        || !parent_part.bytes().all(|byte| byte.is_ascii_digit())
        || (parent_part.len() > 1 && parent_part.starts_with('0'))
        || parent_guid.is_empty()
    {
        return Err(CloudCanonicalValidationFailure::MalformedReplyParent);
    }
    validate_identifier(parent_part)
        .map_err(|_| CloudCanonicalValidationFailure::MalformedReplyParent)?;
    validate_identifier(parent_guid)
        .map_err(|_| CloudCanonicalValidationFailure::MalformedReplyParent)?;
    Ok(ParsedReplyParent {
        parent_guid: parent_guid.to_owned(),
        parent_part: parent_part.to_owned(),
    })
}

impl ParsedReplyParent {
    pub(crate) fn parent_guid(&self) -> &str {
        &self.parent_guid
    }

    pub(crate) fn parent_part(&self) -> &str {
        &self.parent_part
    }
}

fn validate_identifier(value: &str) -> Result<(), CloudCanonicalValidationFailure> {
    if value.is_empty() || value.len() > MAX_IDENTIFIER_BYTES || value.contains('\0') {
        return Err(CloudCanonicalValidationFailure::InvalidIdentifier);
    }
    Ok(())
}

fn validate_text(value: &str) -> Result<(), CloudCanonicalValidationFailure> {
    if value.len() > MAX_TEXT_BYTES || value.contains('\0') {
        return Err(CloudCanonicalValidationFailure::InvalidText);
    }
    Ok(())
}

fn validate_optional_identifier(
    value: &CloudCanonicalField<String>,
) -> Result<(), CloudCanonicalValidationFailure> {
    if let Some(value) = value.value() {
        validate_identifier(value)?;
    }
    Ok(())
}

fn validate_optional_text(
    value: &CloudCanonicalField<String>,
) -> Result<(), CloudCanonicalValidationFailure> {
    if let Some(value) = value.value() {
        validate_text(value)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SENTINEL: &str = "SENSITIVE-FIXTURE-DO-NOT-LOG";

    fn hash(byte: char) -> CloudCanonicalHash {
        CloudCanonicalHash::new(byte.to_string().repeat(HASH_BYTES)).expect("fixture hash")
    }

    fn digest(byte: char) -> CloudCanonicalDigest {
        CloudCanonicalDigest::new(byte.to_string().repeat(HASH_BYTES)).expect("fixture digest")
    }

    fn protected() -> CloudCanonicalProtectedReference {
        CloudCanonicalProtectedReference::new("obcs2.test.fixture").expect("fixture reference")
    }

    fn chat_payload() -> CloudCanonicalChatPayload {
        CloudCanonicalChatPayload::new(
            format!("chat-{SENTINEL}"),
            "direct-chat".to_owned(),
            "group-id".to_owned(),
            "original-group-id".to_owned(),
            CloudCanonicalService::IMessage,
            CloudCanonicalChatStyle::Direct,
            vec!["mailto:synthetic@example.invalid".to_owned()],
            CloudCanonicalField::Value(format!("Display {SENTINEL}")),
            CloudCanonicalField::Value("mailto:sender@example.invalid".to_owned()),
            CloudCanonicalField::Value(1),
            CloudCanonicalField::Absent,
            CloudCanonicalField::ExplicitClear,
        )
        .expect("chat payload")
    }

    fn envelope(
        entity_kind: CloudCanonicalEntityKind,
        mutation_kind: CloudCanonicalMutationKind,
        logical_hash: CloudCanonicalHash,
        parent_hash: Option<CloudCanonicalHash>,
    ) -> CloudCanonicalEnvelope {
        let aliases = if entity_kind == CloudCanonicalEntityKind::Chat {
            vec![CloudCanonicalAlias::new(
                CloudCanonicalAliasKind::ChatGroupId,
                hash('G'),
            )]
        } else {
            Vec::new()
        };
        CloudCanonicalEnvelope::new(
            hash('S'),
            hash('Z'),
            7,
            CLOUD_CANONICAL_SCHEMA_VERSION,
            hash('C'),
            entity_kind,
            mutation_kind,
            hash('R'),
            logical_hash,
            parent_hash,
            aliases,
            Some(hash('E')),
            Some(10),
            Some(20),
            protected(),
        )
        .expect("envelope")
    }

    fn snapshot(
        entity_kind: CloudCanonicalEntityKind,
        logical_hash: CloudCanonicalHash,
        parent_hash: Option<CloudCanonicalHash>,
    ) -> CloudCanonicalSnapshot {
        CloudCanonicalSnapshot::new(
            entity_kind,
            logical_hash,
            parent_hash,
            Some(digest('I')),
            Some(1),
            if entity_kind == CloudCanonicalEntityKind::Message {
                Some(2)
            } else {
                None
            },
            if entity_kind == CloudCanonicalEntityKind::Message {
                Some(3)
            } else {
                None
            },
            Vec::new(),
            None,
            if entity_kind == CloudCanonicalEntityKind::Chat {
                Some(1)
            } else {
                None
            },
            if entity_kind == CloudCanonicalEntityKind::Chat {
                Some(digest('M'))
            } else {
                None
            },
            Some(hash('E')),
            protected(),
        )
        .expect("snapshot")
    }

    fn plain_body(value: &str) -> CloudCanonicalAttributedBody {
        let length = value.encode_utf16().count() as u32;
        CloudCanonicalAttributedBody::new(
            value.to_owned(),
            vec![CloudCanonicalTextRun::new(
                0,
                length,
                Some(0),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .expect("run")],
        )
        .expect("body")
    }

    fn message_payload(
        association: CloudCanonicalMessageAssociation,
    ) -> CloudCanonicalMessagePayload {
        CloudCanonicalMessagePayload::new(
            format!("message-{SENTINEL}"),
            hash('A'),
            "mailto:synthetic@example.invalid".to_owned(),
            123,
            0,
            CloudCanonicalService::IMessage,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value(SENTINEL.to_owned()),
            CloudCanonicalField::Value(vec![plain_body(SENTINEL)]),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalKnownMessageFlags::default(),
            association,
            None,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .expect("message payload")
    }

    #[test]
    fn presence_states_remain_distinct_and_redacted() {
        let absent = CloudCanonicalField::<String>::Absent;
        let value = CloudCanonicalField::Value(SENTINEL.to_owned());
        let clear = CloudCanonicalField::<String>::ExplicitClear;

        assert_eq!(absent.state(), CloudCanonicalFieldState::Absent);
        assert_eq!(value.state(), CloudCanonicalFieldState::Value);
        assert_eq!(clear.state(), CloudCanonicalFieldState::ExplicitClear);
        assert!(!format!("{value:?}").contains(SENTINEL));
    }

    #[test]
    fn aggregate_transient_payload_bytes_are_bounded() {
        let maximum_single_field = "x".repeat(MAX_TEXT_BYTES);
        let result = CloudCanonicalMessagePayload::new(
            "message-guid".to_owned(),
            hash('A'),
            "mailto:synthetic@example.invalid".to_owned(),
            1,
            0,
            CloudCanonicalService::IMessage,
            CloudCanonicalField::Value(maximum_single_field.clone()),
            CloudCanonicalField::Value(maximum_single_field),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalKnownMessageFlags::default(),
            CloudCanonicalMessageAssociation::None,
            None,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        );
        assert_eq!(
            result,
            Err(CloudCanonicalValidationFailure::CollectionLimit)
        );
    }

    #[test]
    fn valid_chat_upsert_enforces_internal_and_active_scope() {
        let logical = hash('L');
        let envelope = envelope(
            CloudCanonicalEntityKind::Chat,
            CloudCanonicalMutationKind::Upsert,
            logical.clone(),
            None,
        );
        let mutation = CloudCanonicalMutation::new(
            envelope,
            Some(snapshot(CloudCanonicalEntityKind::Chat, logical, None)),
            Some(CloudCanonicalPayload::Chat(Box::new(chat_payload()))),
            None,
        )
        .expect("valid upsert");

        assert_eq!(
            mutation.validate_active_context(&hash('S'), &hash('Z'), 7),
            Ok(())
        );
        assert_eq!(
            mutation.validate_active_context(&hash('X'), &hash('Z'), 7),
            Err(CloudCanonicalValidationFailure::ScopeMismatch)
        );
        assert_eq!(
            mutation.validate_active_context(&hash('S'), &hash('Z'), 8),
            Err(CloudCanonicalValidationFailure::ScopeMismatch)
        );
    }

    #[test]
    fn envelope_rejects_schema_alias_and_parent_invariant_violations() {
        let unsupported = CloudCanonicalEnvelope::new(
            hash('S'),
            hash('Z'),
            0,
            CLOUD_CANONICAL_SCHEMA_VERSION + 1,
            hash('C'),
            CloudCanonicalEntityKind::Chat,
            CloudCanonicalMutationKind::Upsert,
            hash('R'),
            hash('L'),
            None,
            Vec::new(),
            None,
            None,
            None,
            protected(),
        );
        assert_eq!(
            unsupported,
            Err(CloudCanonicalValidationFailure::UnsupportedSchema)
        );

        let aliases_on_message = CloudCanonicalEnvelope::new(
            hash('S'),
            hash('Z'),
            0,
            CLOUD_CANONICAL_SCHEMA_VERSION,
            hash('C'),
            CloudCanonicalEntityKind::Message,
            CloudCanonicalMutationKind::Upsert,
            hash('R'),
            hash('L'),
            None,
            vec![CloudCanonicalAlias::new(
                CloudCanonicalAliasKind::ChatGroupId,
                hash('G'),
            )],
            None,
            None,
            None,
            protected(),
        );
        assert_eq!(
            aliases_on_message,
            Err(CloudCanonicalValidationFailure::InvalidEnvelope)
        );

        let group_photo_without_parent = CloudCanonicalEnvelope::new(
            hash('S'),
            hash('Z'),
            0,
            CLOUD_CANONICAL_SCHEMA_VERSION,
            hash('C'),
            CloudCanonicalEntityKind::GroupPhoto,
            CloudCanonicalMutationKind::Upsert,
            hash('R'),
            hash('L'),
            None,
            Vec::new(),
            None,
            None,
            None,
            protected(),
        );
        assert_eq!(
            group_photo_without_parent,
            Err(CloudCanonicalValidationFailure::InvalidEnvelope)
        );
    }

    #[test]
    fn mutation_rejects_payload_kind_and_parent_mismatch() {
        let logical = hash('L');
        let chat_envelope = envelope(
            CloudCanonicalEntityKind::Chat,
            CloudCanonicalMutationKind::Upsert,
            logical.clone(),
            None,
        );
        assert_eq!(
            CloudCanonicalMutation::new(
                chat_envelope,
                Some(snapshot(CloudCanonicalEntityKind::Chat, logical, None)),
                Some(CloudCanonicalPayload::Message(Box::new(message_payload(
                    CloudCanonicalMessageAssociation::None,
                )))),
                None,
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );

        let parent = CloudCanonicalParentReference::new(
            "parent-guid".to_owned(),
            0,
            hash('P'),
            Some(0),
            Some(4),
        )
        .expect("parent");
        let reaction = message_payload(CloudCanonicalMessageAssociation::ReactionAdd {
            kind: CloudCanonicalReactionKind::Like,
            parent,
        });
        let reaction_envelope = envelope(
            CloudCanonicalEntityKind::Reaction,
            CloudCanonicalMutationKind::Upsert,
            hash('L'),
            Some(hash('Q')),
        );
        assert_eq!(
            CloudCanonicalMutation::new(
                reaction_envelope,
                Some(
                    CloudCanonicalSnapshot::new(
                        CloudCanonicalEntityKind::Reaction,
                        hash('L'),
                        Some(hash('Q')),
                        Some(digest('I')),
                        Some(1),
                        None,
                        None,
                        Vec::new(),
                        None,
                        None,
                        None,
                        Some(hash('E')),
                        protected(),
                    )
                    .expect("reaction snapshot")
                ),
                Some(CloudCanonicalPayload::Message(Box::new(reaction))),
                None,
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );
    }

    #[test]
    fn tombstone_accepts_missing_server_time_without_inventing_one() {
        let logical = hash('L');
        let mut envelope = envelope(
            CloudCanonicalEntityKind::Message,
            CloudCanonicalMutationKind::Tombstone,
            logical.clone(),
            None,
        );
        envelope.server_modified_at_millis = None;
        let tombstone = CloudCanonicalTombstone::new(
            CloudCanonicalEntityKind::Message,
            hash('R'),
            logical,
            protected(),
            None,
            true,
        )
        .expect("tombstone");
        let mutation = CloudCanonicalMutation::new(envelope, None, None, Some(tombstone))
            .expect("valid tombstone");
        assert!(mutation.tombstone.unwrap().deleted_at_millis.is_none());
    }

    #[test]
    fn tombstone_requires_server_confirmation_and_exact_mapping() {
        assert_eq!(
            CloudCanonicalTombstone::new(
                CloudCanonicalEntityKind::Message,
                hash('R'),
                hash('L'),
                protected(),
                Some(20),
                false,
            ),
            Err(CloudCanonicalValidationFailure::InvalidTombstone)
        );

        let envelope = envelope(
            CloudCanonicalEntityKind::Message,
            CloudCanonicalMutationKind::Tombstone,
            hash('L'),
            None,
        );
        let wrong_mapping = CloudCanonicalTombstone::new(
            CloudCanonicalEntityKind::Message,
            hash('X'),
            hash('L'),
            protected(),
            Some(20),
            true,
        )
        .expect("mapped tombstone");
        assert_eq!(
            CloudCanonicalMutation::new(envelope, None, None, Some(wrong_mapping)),
            Err(CloudCanonicalValidationFailure::InvalidTombstone)
        );
    }

    #[test]
    fn owned_attachment_parser_preserves_the_entire_guid_suffix() {
        let parsed =
            parse_owned_attachment_guid("at_12_GUID_WITH_UNDERSCORES").expect("owned attachment");
        assert_eq!(parsed.part, 12);
        assert_eq!(parsed.message_guid, "GUID_WITH_UNDERSCORES");
        assert_eq!(parsed.canonical_guid, "GUID_WITH_UNDERSCORES_12");
        assert!(!format!("{parsed:?}").contains("GUID_WITH_UNDERSCORES"));
    }

    #[test]
    fn owned_attachment_parser_rejects_non_exact_or_overflowing_shapes() {
        for malformed in [
            "at",
            "at_",
            "at__guid",
            "at_-1_guid",
            "at_01_guid",
            "at_x_guid",
            "at_4294967296_guid",
            "at_0_bad/guid",
            "other_0_guid",
        ] {
            assert_eq!(
                parse_owned_attachment_guid(malformed),
                Err(CloudCanonicalValidationFailure::MalformedAttachmentOwner),
                "{malformed}"
            );
        }
    }

    #[test]
    fn associated_parent_parser_requires_exact_unambiguous_prefix_part_and_guid() {
        let parsed = parse_associated_parent("p:7/PARENT-GUID").expect("associated parent");
        assert_eq!(parsed.parent_part, 7);
        assert_eq!(parsed.parent_guid, "PARENT-GUID");
        assert!(!format!("{parsed:?}").contains("PARENT"));

        for malformed in [
            "bp:7/guid",
            "p:/guid",
            "p:x/guid",
            "p:07/guid",
            "p:7/",
            "p:7",
            "p:7/PARENT/GUID",
        ] {
            assert_eq!(
                parse_associated_parent(malformed),
                Err(CloudCanonicalValidationFailure::MalformedAssociatedParent),
                "{malformed}"
            );
        }
    }

    #[test]
    fn reply_parser_accepts_only_the_established_unambiguous_shape() {
        let parsed = parse_reply_parent("r:0:PARENT-GUID").expect("reply parent");
        assert_eq!(parsed.parent_part, "0");
        assert_eq!(parsed.parent_guid, "PARENT-GUID");
        assert!(!format!("{parsed:?}").contains("PARENT-GUID"));

        assert_eq!(
            parse_reply_parent("r:part:with-colon:PARENT-GUID"),
            Err(CloudCanonicalValidationFailure::AmbiguousReplyParent)
        );
        assert_eq!(
            parse_reply_parent("r:0:PARENT:GUID"),
            Err(CloudCanonicalValidationFailure::AmbiguousReplyParent)
        );
        for malformed in ["r:", "r:0", "r::guid", "r:00:guid", "r:0:", "p:0/guid"] {
            assert_eq!(
                parse_reply_parent(malformed),
                Err(CloudCanonicalValidationFailure::MalformedReplyParent),
                "{malformed}"
            );
        }
    }

    #[test]
    fn attributed_ranges_use_utf16_boundaries_and_reject_overflow() {
        let emoji = "A😀B";
        assert_eq!(emoji.encode_utf16().count(), 4);
        assert!(CloudCanonicalAttributedBody::new(
            emoji.to_owned(),
            vec![CloudCanonicalTextRun::new(
                1,
                2,
                Some(0),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .expect("emoji run")],
        )
        .is_ok());
        assert_eq!(
            CloudCanonicalAttributedBody::new(
                emoji.to_owned(),
                vec![CloudCanonicalTextRun::new(
                    3,
                    2,
                    Some(0),
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                )
                .expect("out of bounds run")],
            ),
            Err(CloudCanonicalValidationFailure::InvalidRange)
        );
    }

    #[test]
    fn attachment_owner_hash_and_part_are_atomic() {
        assert_eq!(
            CloudCanonicalAttachmentPayload::new(
                "attachment-guid".to_owned(),
                Some(hash('P')),
                None,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::ExplicitClear,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );
        assert!(CloudCanonicalAttachmentPayload::new(
            "attachment-guid".to_owned(),
            Some(hash('P')),
            Some(0),
            CloudCanonicalField::Value("public.png".to_owned()),
            CloudCanonicalField::Value("image/png".to_owned()),
            CloudCanonicalField::Value(SENTINEL.to_owned()),
            CloudCanonicalField::Value(42),
            CloudCanonicalField::Value(false),
            CloudCanonicalField::Value(protected()),
        )
        .is_ok());
    }

    #[test]
    fn emoji_reaction_requires_transient_emoji_content() {
        let parent = || {
            CloudCanonicalParentReference::new("parent".to_owned(), 0, hash('P'), None, None)
                .expect("parent")
        };
        let result = CloudCanonicalMessagePayload::new(
            "reaction-guid".to_owned(),
            hash('A'),
            "mailto:synthetic@example.invalid".to_owned(),
            1,
            0,
            CloudCanonicalService::IMessage,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalKnownMessageFlags::default(),
            CloudCanonicalMessageAssociation::ReactionAdd {
                kind: CloudCanonicalReactionKind::Emoji,
                parent: parent(),
            },
            None,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        );
        assert_eq!(result, Err(CloudCanonicalValidationFailure::InvalidPayload));
    }

    #[test]
    fn duplicate_aliases_edits_and_retracted_parts_are_rejected() {
        let duplicate_alias = CloudCanonicalEnvelope::new(
            hash('S'),
            hash('Z'),
            0,
            CLOUD_CANONICAL_SCHEMA_VERSION,
            hash('C'),
            CloudCanonicalEntityKind::Chat,
            CloudCanonicalMutationKind::Upsert,
            hash('R'),
            hash('L'),
            None,
            vec![
                CloudCanonicalAlias::new(CloudCanonicalAliasKind::ChatGroupId, hash('G')),
                CloudCanonicalAlias::new(CloudCanonicalAliasKind::ChatGroupId, hash('G')),
            ],
            None,
            None,
            None,
            protected(),
        );
        assert_eq!(
            duplicate_alias,
            Err(CloudCanonicalValidationFailure::InvalidEnvelope)
        );

        let edit = || {
            CloudCanonicalMessageEdit::new(0, 1, vec![plain_body("edit")], 10, Some((0, 4)))
                .expect("edit")
        };
        let result = CloudCanonicalMessagePayload::new(
            "message-guid".to_owned(),
            hash('A'),
            String::new(),
            1,
            0,
            CloudCanonicalService::IMessage,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalKnownMessageFlags::default(),
            CloudCanonicalMessageAssociation::None,
            None,
            CloudCanonicalField::Value(vec![edit(), edit()]),
            CloudCanonicalField::Value(vec![2, 2]),
            CloudCanonicalField::Absent,
        );
        assert_eq!(result, Err(CloudCanonicalValidationFailure::InvalidPayload));
    }

    #[test]
    fn every_payload_and_metadata_debug_path_is_redacted() {
        let chat = chat_payload();
        let message = message_payload(CloudCanonicalMessageAssociation::None);
        let attachment = CloudCanonicalAttachmentPayload::new(
            format!("attachment-{SENTINEL}"),
            None,
            None,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value(SENTINEL.to_owned()),
            CloudCanonicalField::ExplicitClear,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .expect("attachment");
        let photo = CloudCanonicalGroupPhotoPayload::new(
            hash('P'),
            hash('F'),
            format!("photo-{SENTINEL}"),
            protected(),
        )
        .expect("photo");

        for rendered in [
            format!("{chat:?}"),
            format!("{message:?}"),
            format!("{attachment:?}"),
            format!("{photo:?}"),
            format!("{:?}", CloudCanonicalPayload::Chat(Box::new(chat))),
            format!("{:?}", CloudCanonicalPayload::Message(Box::new(message))),
        ] {
            assert!(!rendered.contains(SENTINEL), "{rendered}");
            assert!(rendered.contains("redacted"), "{rendered}");
        }

        let logical = hash('L');
        let mutation = CloudCanonicalMutation::new(
            envelope(
                CloudCanonicalEntityKind::Chat,
                CloudCanonicalMutationKind::Upsert,
                logical.clone(),
                None,
            ),
            Some(snapshot(CloudCanonicalEntityKind::Chat, logical, None)),
            Some(CloudCanonicalPayload::Chat(Box::new(chat_payload()))),
            None,
        )
        .expect("mutation");
        assert_eq!(format!("{mutation:?}"), "CloudCanonicalMutation(redacted)");
    }

    #[test]
    fn source_has_no_bridge_serialization_or_secret_transport_types() {
        let source = include_str!("cloud_sync_canonical_dto.rs");
        let forbidden = [
            concat!("flutter_", "rust_bridge"),
            concat!("#[", "frb"),
            concat!("ser", "de::"),
            concat!("derive(", "Serialize"),
            concat!("derive(", "Deserialize"),
            concat!("PCSEn", "cryptor"),
            concat!("MMCS", "AttachmentMeta"),
            concat!("decryption", "_key"),
            concat!("raw_account", "_id"),
            concat!("raw_record", "_id"),
            concat!("impl std::fmt::", "Display"),
        ];
        for token in forbidden {
            assert!(!source.contains(token), "forbidden source token: {token}");
        }
    }
}
