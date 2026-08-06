//! Native-only semantic identity projection for Cloud Sync V2.
//!
//! This module deliberately stops before Dart/ObjectBox mutation. It accepts
//! decrypted CloudKit records only inside Rust, emits keyed identifiers and a
//! protected raw-envelope reference, and never formats raw record names,
//! Apple GUIDs, handles, or plaintext in diagnostics.

use std::{collections::HashMap, panic::AssertUnwindSafe};

use rustpush::{
    cloud_messages::{AttachmentMeta, CloudAttachment, CloudChat, CloudMessage},
    cloudkit_proto::{CloudKitRecord, Record},
    pcs::PCSEncryptor,
    PushError,
};
use thiserror::Error;

use crate::cloud_sync_canonical_dto::{CloudCanonicalEntityKind, CloudCanonicalHash};

// The keyed hasher and the two types it reports through live in a
// dependency-light module so the native protector and its standalone harness
// can link them without this module's Apple record parsing stack.
pub use crate::cloud_sync_semantic_identity::{
    CloudSemanticDecodeFailure, CloudSemanticEntityKind, CloudSemanticIdentifierHasher,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum CloudSemanticStream {
    Chats,
    Messages,
    Attachments,
}

impl CloudSemanticStream {
    fn record_type(self) -> &'static str {
        match self {
            Self::Chats => "chatEncryptedv2",
            Self::Messages => "MessageEncryptedV3",
            Self::Attachments => "attachment",
        }
    }

    fn entity_kind(self) -> CloudSemanticEntityKind {
        match self {
            Self::Chats => CloudSemanticEntityKind::Chat,
            Self::Messages => CloudSemanticEntityKind::Message,
            Self::Attachments => CloudSemanticEntityKind::Attachment,
        }
    }
}


/// A transport-validated change shape. Apple may omit `RecordChange.type`, so
/// the semantic boundary must not require the numeric value after the
/// transport has proven whether the change carries a record or a tombstone.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum CloudSemanticChangeKind {
    Upsert,
    Tombstone,
}

/// One preflighted server envelope. The raw record name remains native-only.
/// `protected_raw_envelope_reference` must refer to the lossless ciphertext
/// journal entry, never to decoded plaintext.
pub struct CloudSemanticEnvelope<'a> {
    pub stream: CloudSemanticStream,
    pub record_name: &'a str,
    pub record_type: Option<&'a str>,
    pub change_kind: CloudSemanticChangeKind,
    pub protected_raw_envelope_reference: &'a str,
    pub server_modified_at: Option<f64>,
}

/// A content-free identity projection. It is safe to persist as Cloud Sync
/// metadata but its `Debug` implementation intentionally omits all values.
#[derive(Clone, Eq, PartialEq)]
pub struct CloudSemanticProjection {
    pub entity_kind: CloudSemanticEntityKind,
    pub server_record_id_hash: String,
    pub logical_entity_key_hash: String,
    pub protected_raw_envelope_reference: String,
    pub server_modified_at_millis: Option<i64>,
}

impl std::fmt::Debug for CloudSemanticProjection {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CloudSemanticProjection(redacted)")
    }
}

/// The only metadata necessary to resolve a later server tombstone. Raw server
/// identifiers are intentionally not retained here.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CloudSemanticRecordMapEntry {
    pub entity_kind: CloudSemanticEntityKind,
    pub server_record_id_hash: String,
    pub logical_entity_key_hash: String,
}

#[derive(Clone, Eq, PartialEq)]
pub struct CloudSemanticTombstone {
    pub entity_kind: CloudSemanticEntityKind,
    pub server_record_id_hash: String,
    pub logical_entity_key_hash: String,
    pub protected_raw_envelope_reference: String,
    pub deleted_at_millis: Option<i64>,
    pub server_confirmed: bool,
}

impl std::fmt::Debug for CloudSemanticTombstone {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CloudSemanticTombstone(redacted)")
    }
}


/// Classifies one envelope before any PCS decryption. This is intentionally
/// strict: an unexpected type, missing raw-reference, or contradictory change
/// shape cannot fall through into the semantic applier.
pub fn classify_envelope(
    envelope: &CloudSemanticEnvelope<'_>,
) -> Result<CloudSemanticEntityKind, CloudSemanticDecodeFailure> {
    if envelope.record_name.is_empty() || envelope.protected_raw_envelope_reference.is_empty() {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }

    match envelope.change_kind {
        // Server-confirmed delete. The enclosing stream supplies the entity
        // class because a CloudKit tombstone may omit its record type.
        CloudSemanticChangeKind::Tombstone => {
            if envelope
                .record_type
                .is_some_and(|record_type| record_type != envelope.stream.record_type())
            {
                return Err(CloudSemanticDecodeFailure::UnsupportedRecordType);
            }
            Ok(envelope.stream.entity_kind())
        }
        // Upsert must name the exact schema expected for the stream.
        CloudSemanticChangeKind::Upsert => match envelope.record_type {
            Some(record_type) if record_type == envelope.stream.record_type() => {
                Ok(envelope.stream.entity_kind())
            }
            Some(_) => Err(CloudSemanticDecodeFailure::UnsupportedRecordType),
            None => Err(CloudSemanticDecodeFailure::MalformedRecord),
        },
    }
}

/// Converts Apple's optional numeric change type plus the already-observed
/// payload shape into the closed semantic contract. A missing type is valid:
/// rustpush has historically classified those changes by record presence.
pub fn validated_change_kind(
    change_type: Option<i32>,
    has_record: bool,
) -> Result<CloudSemanticChangeKind, CloudSemanticDecodeFailure> {
    match (change_type, has_record) {
        (Some(1) | None, true) => Ok(CloudSemanticChangeKind::Upsert),
        (Some(2) | None, false) => Ok(CloudSemanticChangeKind::Tombstone),
        _ => Err(CloudSemanticDecodeFailure::MalformedRecord),
    }
}

/// Projects a decrypted chat/message/attachment into durable, content-free
/// metadata. `record` must be the original CloudKit `Record` decoded from the
/// protected raw envelope; it is revalidated before decrypting fields.
pub fn decode_encrypted_upsert(
    envelope: &CloudSemanticEnvelope<'_>,
    record: &Record,
    pcs_encryptor: Option<&PCSEncryptor>,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure> {
    let entity_kind = classify_envelope(envelope)?;
    if envelope.change_kind != CloudSemanticChangeKind::Upsert
        || !record_matches_envelope(record, envelope)
        || !fields_are_well_formed(record)
    {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }
    let pcs_encryptor = pcs_encryptor.ok_or(CloudSemanticDecodeFailure::PcsUnavailable)?;

    let logical_identifier = match entity_kind {
        CloudSemanticEntityKind::Chat => std::panic::catch_unwind(AssertUnwindSafe(|| {
            CloudChat::from_record_encrypted(&record.record_field, Some(pcs_encryptor)).guid
        }))
        .map_err(|_| CloudSemanticDecodeFailure::MalformedRecord)?,
        CloudSemanticEntityKind::Message => std::panic::catch_unwind(AssertUnwindSafe(|| {
            CloudMessage::from_record_encrypted(&record.record_field, Some(pcs_encryptor)).guid
        }))
        .map_err(|_| CloudSemanticDecodeFailure::MalformedRecord)?,
        CloudSemanticEntityKind::Attachment => std::panic::catch_unwind(AssertUnwindSafe(|| {
            let attachment =
                CloudAttachment::from_record_encrypted(&record.record_field, Some(pcs_encryptor));
            attachment.cm.guid.clone()
        }))
        .map_err(|_| CloudSemanticDecodeFailure::MalformedRecord)?,
    };

    project_logical_identifier(envelope, entity_kind, &logical_identifier, hasher)
}

/// Adapter for the existing `pcs_keys_for_record` call. A PCS lookup failure
/// stays typed at the semantic boundary instead of becoming a generic decode
/// or local-storage error.
pub fn decode_encrypted_upsert_with_pcs_result(
    envelope: &CloudSemanticEnvelope<'_>,
    record: &Record,
    pcs_encryptor: Result<&PCSEncryptor, &PushError>,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure> {
    let pcs_encryptor = pcs_encryptor.map_err(classify_pcs_failure)?;
    decode_encrypted_upsert(envelope, record, Some(pcs_encryptor), hasher)
}

/// Runs a future adapter's PCS lookup inside the same failure boundary as
/// semantic decoding. The existing rustpush lookup still contains legacy
/// panics for incomplete server metadata; those must remain retryable and must
/// never terminate an FFI caller or be reclassified as discardable corruption.
pub fn decode_encrypted_upsert_with_pcs_lookup<F>(
    envelope: &CloudSemanticEnvelope<'_>,
    record: &Record,
    pcs_lookup: F,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure>
where
    F: FnOnce() -> Result<PCSEncryptor, PushError>,
{
    let entity_kind = classify_envelope(envelope)?;
    if envelope.change_kind != CloudSemanticChangeKind::Upsert
        || !record_matches_envelope(record, envelope)
        || !fields_are_well_formed(record)
    {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }

    let pcs_encryptor = std::panic::catch_unwind(AssertUnwindSafe(pcs_lookup))
        .map_err(|_| CloudSemanticDecodeFailure::RetryableUpstreamFailure)?
        .map_err(|error| classify_pcs_failure(&error))?;

    // Keep the preflight result live so future schema extensions cannot
    // accidentally remove the exact stream/entity check above.
    debug_assert_eq!(entity_kind, envelope.stream.entity_kind());
    decode_encrypted_upsert(envelope, record, Some(&pcs_encryptor), hasher)
}

/// Projects already-decoded values for deterministic unit testing and for a
/// future client adapter that has performed PCS lookup. This deliberately does
/// not expose the decoded value in its return type.
pub fn project_chat(
    envelope: &CloudSemanticEnvelope<'_>,
    chat: &CloudChat,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure> {
    project_known_entity(envelope, CloudSemanticEntityKind::Chat, &chat.guid, hasher)
}

pub fn project_message(
    envelope: &CloudSemanticEnvelope<'_>,
    message: &CloudMessage,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure> {
    project_known_entity(
        envelope,
        CloudSemanticEntityKind::Message,
        &message.guid,
        hasher,
    )
}

pub fn project_attachment(
    envelope: &CloudSemanticEnvelope<'_>,
    attachment: &AttachmentMeta,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure> {
    // AttachmentMeta dates and byte counts are documented by the existing
    // schema as potentially negative. They are intentionally not rejected or
    // normalized here; attachment identity is the only safe Phase 2 output.
    project_known_entity(
        envelope,
        CloudSemanticEntityKind::Attachment,
        &attachment.guid,
        hasher,
    )
}

/// Resolves a server tombstone through the prior server-record mapping. A
/// tombstone never guesses a logical entity from its opaque server record name.
pub fn reverse_tombstone(
    envelope: &CloudSemanticEnvelope<'_>,
    mappings: &HashMap<String, CloudSemanticRecordMapEntry>,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticTombstone, CloudSemanticDecodeFailure> {
    let expected_kind = classify_envelope(envelope)?;
    if envelope.change_kind != CloudSemanticChangeKind::Tombstone {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }
    // CloudKit tombstones commonly omit the embedded Record, which is where
    // rustpush obtains server timestamps. Preserve the absence rather than
    // fabricating local wall time or rejecting a valid server deletion.
    let deleted_at_millis = timestamp_millis(envelope.server_modified_at)?;
    let server_record_id_hash = hasher.server_record_id_hash(envelope.record_name);
    let mapping = mappings
        .get(&server_record_id_hash)
        .ok_or(CloudSemanticDecodeFailure::TombstoneMappingMissing)?;
    if mapping.entity_kind != expected_kind
        || mapping.server_record_id_hash != server_record_id_hash
    {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }

    Ok(CloudSemanticTombstone {
        entity_kind: mapping.entity_kind,
        server_record_id_hash,
        logical_entity_key_hash: mapping.logical_entity_key_hash.clone(),
        protected_raw_envelope_reference: envelope.protected_raw_envelope_reference.to_owned(),
        deleted_at_millis,
        server_confirmed: true,
    })
}

/// Converts Rustpush transport errors into the narrow semantic error contract.
/// The original error may contain protocol detail and is never propagated to
/// durable diagnostics by this module.
pub fn classify_pcs_failure(error: &PushError) -> CloudSemanticDecodeFailure {
    match error {
        PushError::PCSRecordKeyMissing
        | PushError::MasterKeyNotFound
        | PushError::NotInClique
        | PushError::ShareKeyNotFound(_)
        | PushError::NoRoutingKey => CloudSemanticDecodeFailure::PcsUnavailable,
        _ => CloudSemanticDecodeFailure::RetryableUpstreamFailure,
    }
}

fn project_known_entity(
    envelope: &CloudSemanticEnvelope<'_>,
    expected_kind: CloudSemanticEntityKind,
    logical_identifier: &str,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure> {
    if envelope.change_kind != CloudSemanticChangeKind::Upsert
        || classify_envelope(envelope)? != expected_kind
    {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }
    project_logical_identifier(envelope, expected_kind, logical_identifier, hasher)
}

fn project_logical_identifier(
    envelope: &CloudSemanticEnvelope<'_>,
    entity_kind: CloudSemanticEntityKind,
    logical_identifier: &str,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<CloudSemanticProjection, CloudSemanticDecodeFailure> {
    if logical_identifier.is_empty() {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }
    Ok(CloudSemanticProjection {
        entity_kind,
        server_record_id_hash: hasher.server_record_id_hash(envelope.record_name),
        logical_entity_key_hash: hasher.logical_entity_key_hash(entity_kind, logical_identifier),
        protected_raw_envelope_reference: envelope.protected_raw_envelope_reference.to_owned(),
        server_modified_at_millis: timestamp_millis(envelope.server_modified_at)?,
    })
}

fn record_matches_envelope(record: &Record, envelope: &CloudSemanticEnvelope<'_>) -> bool {
    let record_name = record
        .record_identifier
        .as_ref()
        .and_then(|identifier| identifier.value.as_ref())
        .and_then(|identifier| identifier.name.as_deref())
        .filter(|name| !name.is_empty());
    let record_type = record
        .r#type
        .as_ref()
        .and_then(|record_type| record_type.name.as_deref())
        .filter(|record_type| !record_type.is_empty());
    record_name == Some(envelope.record_name) && record_type == envelope.record_type
}

fn fields_are_well_formed(record: &Record) -> bool {
    record.record_field.iter().all(|field| {
        field
            .identifier
            .as_ref()
            .and_then(|identifier| identifier.name.as_deref())
            .is_some_and(|name| !name.is_empty())
    })
}

fn timestamp_millis(seconds: Option<f64>) -> Result<Option<i64>, CloudSemanticDecodeFailure> {
    let Some(seconds) = seconds else {
        return Ok(None);
    };
    if !seconds.is_finite() {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }
    let millis = seconds * 1_000.0;
    if millis < i64::MIN as f64 || millis > i64::MAX as f64 {
        return Err(CloudSemanticDecodeFailure::MalformedRecord);
    }
    Ok(Some(millis.round() as i64))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_KEY: &[u8] = b"native-semantic-decoder-fixture-key";

    fn hasher() -> CloudSemanticIdentifierHasher {
        CloudSemanticIdentifierHasher::new(TEST_KEY).expect("fixture hasher")
    }

    fn envelope(
        stream: CloudSemanticStream,
        record_name: &'static str,
        record_type: Option<&'static str>,
        change_kind: CloudSemanticChangeKind,
        modified_at: Option<f64>,
    ) -> CloudSemanticEnvelope<'static> {
        CloudSemanticEnvelope {
            stream,
            record_name,
            record_type,
            change_kind,
            protected_raw_envelope_reference: "obcs2.protected.fixture",
            server_modified_at: modified_at,
        }
    }

    fn matching_message_record() -> Record {
        Record {
            record_identifier: Some(rustpush::cloudkit_proto::RecordIdentifier {
                value: Some(rustpush::cloudkit_proto::Identifier {
                    name: Some("server-message".to_owned()),
                    r#type: Some(rustpush::cloudkit_proto::identifier::Type::Record as i32),
                }),
                zone_identifier: None,
            }),
            r#type: Some(rustpush::cloudkit_proto::record::Type {
                name: Some("MessageEncryptedV3".to_owned()),
            }),
            ..Default::default()
        }
    }

    #[test]
    fn mixed_page_classification_is_lossless_and_ordered() {
        let page = [
            envelope(
                CloudSemanticStream::Chats,
                "server-chat",
                Some("chatEncryptedv2"),
                CloudSemanticChangeKind::Upsert,
                None,
            ),
            envelope(
                CloudSemanticStream::Messages,
                "server-message",
                Some("MessageEncryptedV3"),
                CloudSemanticChangeKind::Upsert,
                None,
            ),
            envelope(
                CloudSemanticStream::Attachments,
                "server-attachment",
                Some("attachment"),
                CloudSemanticChangeKind::Upsert,
                None,
            ),
            envelope(
                CloudSemanticStream::Messages,
                "server-delete",
                None,
                CloudSemanticChangeKind::Tombstone,
                Some(2.5),
            ),
        ];

        let classified = page
            .iter()
            .map(classify_envelope)
            .collect::<Result<Vec<_>, _>>()
            .expect("all fixture envelopes classify");
        assert_eq!(
            classified,
            vec![
                CloudSemanticEntityKind::Chat,
                CloudSemanticEntityKind::Message,
                CloudSemanticEntityKind::Attachment,
                CloudSemanticEntityKind::Message,
            ]
        );
    }

    #[test]
    fn malformed_fields_and_unknown_record_types_fail_closed() {
        let malformed = envelope(
            CloudSemanticStream::Messages,
            "",
            Some("MessageEncryptedV3"),
            CloudSemanticChangeKind::Upsert,
            None,
        );
        assert_eq!(
            classify_envelope(&malformed),
            Err(CloudSemanticDecodeFailure::MalformedRecord)
        );

        let unknown = envelope(
            CloudSemanticStream::Messages,
            "server-future",
            Some("FutureMessageV4"),
            CloudSemanticChangeKind::Upsert,
            None,
        );
        assert_eq!(
            classify_envelope(&unknown),
            Err(CloudSemanticDecodeFailure::UnsupportedRecordType)
        );

        assert_eq!(
            validated_change_kind(Some(7), true),
            Err(CloudSemanticDecodeFailure::MalformedRecord)
        );

        let source = envelope(
            CloudSemanticStream::Messages,
            "server-message",
            Some("MessageEncryptedV3"),
            CloudSemanticChangeKind::Upsert,
            None,
        );
        let mut malformed_record = matching_message_record();
        malformed_record
            .record_field
            .push(rustpush::cloudkit_proto::record::Field {
                identifier: None,
                value: None,
            });
        assert_eq!(
            decode_encrypted_upsert(&source, &malformed_record, None, &hasher()),
            Err(CloudSemanticDecodeFailure::MalformedRecord)
        );
    }

    #[test]
    fn omitted_change_type_uses_the_validated_record_shape() {
        assert_eq!(
            validated_change_kind(None, true),
            Ok(CloudSemanticChangeKind::Upsert)
        );
        assert_eq!(
            validated_change_kind(None, false),
            Ok(CloudSemanticChangeKind::Tombstone)
        );
        assert_eq!(
            validated_change_kind(Some(1), false),
            Err(CloudSemanticDecodeFailure::MalformedRecord)
        );
        assert_eq!(
            validated_change_kind(Some(2), true),
            Err(CloudSemanticDecodeFailure::MalformedRecord)
        );
    }

    #[test]
    fn known_entities_map_server_identity_without_exposing_plaintext() {
        let hasher = hasher();
        let chat_source = envelope(
            CloudSemanticStream::Chats,
            "server-chat",
            Some("chatEncryptedv2"),
            CloudSemanticChangeKind::Upsert,
            None,
        );
        let message_source = envelope(
            CloudSemanticStream::Messages,
            "server-message",
            Some("MessageEncryptedV3"),
            CloudSemanticChangeKind::Upsert,
            None,
        );
        let chat = CloudChat {
            guid: "chat-logical-id".to_owned(),
            ..Default::default()
        };
        let message = CloudMessage {
            guid: "message-logical-id".to_owned(),
            ..Default::default()
        };

        let chat_projection = project_chat(&chat_source, &chat, &hasher).expect("chat projection");
        let message_projection =
            project_message(&message_source, &message, &hasher).expect("message projection");
        assert_eq!(chat_projection.entity_kind, CloudSemanticEntityKind::Chat);
        assert_eq!(
            message_projection.entity_kind,
            CloudSemanticEntityKind::Message
        );
        assert_ne!(chat_projection.server_record_id_hash, "server-chat");
        assert_ne!(
            message_projection.logical_entity_key_hash,
            "message-logical-id"
        );
        assert_ne!(
            chat_projection.logical_entity_key_hash, message_projection.logical_entity_key_hash,
            "the entity type is part of the keyed logical identity domain"
        );
    }

    #[test]
    fn negative_attachment_dates_remain_valid_and_identifiers_are_redacted() {
        let source = envelope(
            CloudSemanticStream::Attachments,
            "server-attachment-id",
            Some("attachment"),
            CloudSemanticChangeKind::Upsert,
            Some(-1.25),
        );
        let attachment = AttachmentMeta {
            guid: "attachment-logical-id".to_owned(),
            start_date: -9_999,
            created_date: -4_000,
            total_bytes: -1,
            ..Default::default()
        };

        let projection =
            project_attachment(&source, &attachment, &hasher()).expect("negative dates are valid");
        assert_eq!(projection.server_modified_at_millis, Some(-1_250));
        assert_ne!(projection.server_record_id_hash, "server-attachment-id");
        assert_ne!(projection.logical_entity_key_hash, "attachment-logical-id");
        assert_eq!(
            format!("{projection:?}"),
            "CloudSemanticProjection(redacted)"
        );
    }

    #[test]
    fn pcs_blocked_records_return_a_typed_failure() {
        let source = envelope(
            CloudSemanticStream::Messages,
            "server-message",
            Some("MessageEncryptedV3"),
            CloudSemanticChangeKind::Upsert,
            None,
        );
        let record = matching_message_record();
        assert_eq!(
            decode_encrypted_upsert(&source, &record, None, &hasher()),
            Err(CloudSemanticDecodeFailure::PcsUnavailable)
        );
        assert_eq!(
            classify_pcs_failure(&PushError::PCSRecordKeyMissing),
            CloudSemanticDecodeFailure::PcsUnavailable
        );
        let pcs_error = PushError::PCSRecordKeyMissing;
        assert_eq!(
            decode_encrypted_upsert_with_pcs_result(&source, &record, Err(&pcs_error), &hasher()),
            Err(CloudSemanticDecodeFailure::PcsUnavailable)
        );
        assert_eq!(
            classify_pcs_failure(&PushError::NotConnected),
            CloudSemanticDecodeFailure::RetryableUpstreamFailure,
            "unknown upstream failures must remain retryable, not look like corrupt data"
        );
        assert_eq!(
            decode_encrypted_upsert_with_pcs_lookup(
                &source,
                &record,
                || -> Result<PCSEncryptor, PushError> { Err(PushError::NotConnected) },
                &hasher(),
            ),
            Err(CloudSemanticDecodeFailure::RetryableUpstreamFailure)
        );
        assert_eq!(
            decode_encrypted_upsert_with_pcs_lookup(
                &source,
                &record,
                || -> Result<PCSEncryptor, PushError> { panic!("legacy PCS lookup panic fixture") },
                &hasher(),
            ),
            Err(CloudSemanticDecodeFailure::RetryableUpstreamFailure)
        );
    }

    #[test]
    fn reverse_tombstone_requires_prior_identity_mapping() {
        let source = envelope(
            CloudSemanticStream::Messages,
            "server-message",
            None,
            CloudSemanticChangeKind::Tombstone,
            Some(-2.0),
        );
        let hasher = hasher();
        let server_hash = hasher.server_record_id_hash(source.record_name);
        let logical_hash =
            hasher.logical_entity_key_hash(CloudSemanticEntityKind::Message, "logical-message");
        let mut mappings = HashMap::new();
        mappings.insert(
            server_hash.clone(),
            CloudSemanticRecordMapEntry {
                entity_kind: CloudSemanticEntityKind::Message,
                server_record_id_hash: server_hash.clone(),
                logical_entity_key_hash: logical_hash.clone(),
            },
        );

        let tombstone = reverse_tombstone(&source, &mappings, &hasher).expect("mapped tombstone");
        assert_eq!(tombstone.server_record_id_hash, server_hash);
        assert_eq!(tombstone.logical_entity_key_hash, logical_hash);
        assert_eq!(tombstone.deleted_at_millis, Some(-2_000));
        assert!(tombstone.server_confirmed);
        assert_eq!(format!("{tombstone:?}"), "CloudSemanticTombstone(redacted)");

        assert_eq!(
            reverse_tombstone(&source, &HashMap::new(), &hasher),
            Err(CloudSemanticDecodeFailure::TombstoneMappingMissing)
        );

        let source_without_server_time = envelope(
            CloudSemanticStream::Messages,
            "server-message",
            None,
            CloudSemanticChangeKind::Tombstone,
            None,
        );
        let tombstone_without_server_time =
            reverse_tombstone(&source_without_server_time, &mappings, &hasher)
                .expect("mapped tombstone may omit server time");
        assert_eq!(tombstone_without_server_time.deleted_at_millis, None);
    }
}
