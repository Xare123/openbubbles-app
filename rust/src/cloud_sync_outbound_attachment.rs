//! Native-only attachment initial-create envelope and readback witness.
//! Persists the full completed upload for recovery; remote readback checks
//! record identity and stable content, not temporary download credentials.
//! Completed upload material uses its own protected purpose and attachment
//! zone. Transport, admission and parent linkage must still be integrated.
//! This module alone cannot upload or authorize a remote write.
#![cfg_attr(not(test), allow(dead_code))]

use std::{io::Cursor, path::PathBuf};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message;
use rustpush::cloud_messages::{AttachmentMeta, CloudAttachment, GZipWrapper};
use rustpush::cloudkit_proto::{Asset, RecordIdentifier};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    cloud_sync_canonical_dto::CloudCanonicalEntityKind,
    cloud_sync_native_fetch::{
        cloud_sync_open_protected_outbound_attachment,
        cloud_sync_stage_protected_outbound_attachment_envelope,
    },
    cloud_sync_outbound::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage},
};

mod wire {
    include!(concat!(
        env!("OUT_DIR"),
        "/openbubbles.cloudsync.outbound.rs"
    ));
}

use wire::CloudSyncOutboundAttachmentV1;

/// Envelope version. Any other version on decode is rejected, never migrated.
const ATTACHMENT_PAYLOAD_VERSION: u32 = 1;
/// Upper bound for the encoded envelope. Mirrors the attachment metadata
/// bound used by the legacy create path so readback stays bounded.
const MAX_ATTACHMENT_ENVELOPE_BYTES: usize = 2 * 1024 * 1024;
/// Upper bound for raw metadata/asset payloads. Mirrors the legacy create
/// metadata bound.
const MAX_ATTACHMENT_METADATA_BYTES: usize = 2 * 1024 * 1024;
/// Upper bound for identifier strings (record name, metadata guid).
const MAX_IDENTIFIER_BYTES: usize = 4 * 1024;
/// CloudKit zone bound by transport at create time. Mirrors the private
/// ATTACHMENT_CREATE_ZONE in attachment_create.
const ATTACHMENT_CREATE_ZONE: &str = "attachmentManateeZone";

/// Same initial-create identity as Dart, with an Attachment-only scope.
/// A syntactically valid Message/Chat/mutation ID is not interchangeable.
pub(crate) fn initial_attachment_create_operation_id(
    account_fingerprint: &str,
    logical_entity_key_hash: &str,
) -> Result<String, Failure> {
    if [account_fingerprint, logical_entity_key_hash].iter().any(|value| {
        value.len() != 43 || !value.bytes().all(|byte|
            byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    }) {
        return Err(Failure::BindingMismatch);
    }
    let canonical = [
        "cloud-sync-initial-create-v1", account_fingerprint,
        "com.apple.messages.cloud", "private", ATTACHMENT_CREATE_ZONE,
        "messages", "2", "semantic", logical_entity_key_hash, "save", "1",
    ].join("\u{001f}");
    Ok(format!("op1:{}", digest(canonical.as_bytes())))
}

/// Serialize a completed attachment with its allocated record name.
///
/// Requires the completed-asset shape: outgoing metadata version 1, matching
/// non-negative total bytes, 21-byte asset signatures with the exact leading
/// bytes, a 32-byte protection key, a metadata plist within headroom, a
/// non-empty upload receipt, and a random v4 record name.
pub(crate) fn encode_attachment(
    attachment: &CloudAttachment,
    server_record_name: &str,
) -> Result<Vec<u8>, Failure> {
    validate(attachment, server_record_name)?;
    let mut attachment_meta_plist = Vec::new();
    plist::to_writer_binary(&mut attachment_meta_plist, &attachment.cm.0)
        .map_err(|_| Failure::MalformedMessage)?;
    if attachment_meta_plist.len() > MAX_ATTACHMENT_METADATA_BYTES / 2 {
        return Err(Failure::OversizedMessage);
    }
    if attachment.lqa.encoded_len() > MAX_ATTACHMENT_METADATA_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let asset_proto = attachment.lqa.encode_to_vec();
    let envelope = CloudSyncOutboundAttachmentV1 {
        schema_version: ATTACHMENT_PAYLOAD_VERSION,
        server_record_name: server_record_name.to_owned(),
        attachment_meta_plist,
        asset_proto,
    };
    if envelope.encoded_len() > MAX_ATTACHMENT_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(envelope.encode_to_vec())
}

/// Decode and re-validate an envelope. Returns the attachment plus the exact
/// record name it was encoded with. Omitted or corrupt fields fail; nothing
/// is defaulted.
pub(crate) fn decode_attachment_envelope(
    encoded: &[u8],
) -> Result<(CloudAttachment, String), Failure> {
    if encoded.is_empty() || encoded.len() > MAX_ATTACHMENT_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let envelope =
        CloudSyncOutboundAttachmentV1::decode(encoded).map_err(|_| Failure::MalformedMessage)?;
    if envelope.schema_version != ATTACHMENT_PAYLOAD_VERSION
        || envelope.attachment_meta_plist.is_empty()
        || envelope.attachment_meta_plist.len() > MAX_ATTACHMENT_METADATA_BYTES / 2
        || envelope.asset_proto.is_empty()
        || envelope.asset_proto.len() > MAX_ATTACHMENT_METADATA_BYTES
    {
        return Err(Failure::MalformedMessage);
    }
    let metadata: AttachmentMeta = plist::from_reader(Cursor::new(envelope.attachment_meta_plist))
        .map_err(|_| Failure::MalformedMessage)?;
    let asset =
        Asset::decode(envelope.asset_proto.as_slice()).map_err(|_| Failure::MalformedMessage)?;
    let attachment = CloudAttachment {
        cm: GZipWrapper(metadata),
        lqa: asset,
    };
    validate(&attachment, &envelope.server_record_name)?;
    Ok((attachment, envelope.server_record_name))
}

/// Stable digest of the exact envelope bytes for one attachment/record pair.
/// Recovery compares this, never a re-staged replacement.
pub(crate) fn outbound_attachment_payload_sha256(
    attachment: &CloudAttachment,
    server_record_name: &str,
) -> Result<String, Failure> {
    encode_attachment(attachment, server_record_name).map(|encoded| digest(&encoded))
}

/// Semantic readback verification against the persisted ORIGINAL envelope.
///
/// Two separate comparisons, never one confused hash:
/// - The persisted envelope digest binds the original: the expected
///   attachment must re-encode to expected_payload_sha256 under the original
///   record name. This is the submit/recovery identity.
/// - The fetched attachment is compared by stable content only: full
///   metadata plist bytes plus asset size, signature, reference signature,
///   and protection key. Transport lifecycle metadata (download
///   token and request, base URLs, expirations, upload receipt) is excluded
///   by design, so receipt equality and the full envelope hash are never
///   remote content proof. The stable witness is exactly signatures plus key
///   plus size plus metadata, not all Asset bytes: remaining fields (owner,
///   header, inline data and the rest) are outside the witness, neither
///   compared nor claimed transient.
///
/// Record identity is enforced separately: receipt_record_name must equal
/// original_record_name, the staged record_id must bind name plus
/// attachmentManateeZone, and a present fetched record_id must satisfy the
/// same binding. An omitted fetched record_id rests on the authenticated
/// outer exact-name receipt premise per the native decoder.
pub(crate) fn verify_attachment_readback(
    expected: &CloudAttachment,
    actual: &CloudAttachment,
    receipt_record_name: &str,
    original_record_name: &str,
    expected_payload_sha256: &str,
) -> Result<String, Failure> {
    if receipt_record_name != original_record_name {
        return Err(Failure::BindingMismatch);
    }
    let expected_digest = outbound_attachment_payload_sha256(expected, original_record_name)?;
    if expected_digest != expected_payload_sha256 {
        return Err(Failure::BindingMismatch);
    }
    verify_stable_attachment_content(expected, actual, original_record_name)?;
    Ok(expected_digest)
}

/// Retains the original allocated name from the completed upload. A fresh
/// UUID here would detach the create from the uploaded Asset's record binding.
pub(crate) fn stage_outbound_attachment(
    storage_directory: PathBuf,
    account_fingerprint: String,
    attachment: CloudAttachment,
    server_record_name: &str,
) -> Result<NativeProtectedOutboundStage, Failure> {
    let encoded = encode_attachment(&attachment, server_record_name)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let logical_entity_key_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Attachment, &attachment.cm.0.guid)
        .map_err(|_| Failure::MalformedMessage)?
        .value()
        .to_owned();
    let stage = cloud_sync_stage_protected_outbound_attachment_envelope(
        storage_directory,
        account_fingerprint,
        URL_SAFE_NO_PAD.encode(&encoded),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    Ok(NativeProtectedOutboundStage {
        logical_entity_key_hash,
        protected_payload_reference: stage.protected_envelope_reference.clone(),
        payload_sha256: digest(&encoded),
        payload_length: encoded.len() as u64,
        protected_server_record_reference: stage.protected_envelope_reference,
        server_record_id_hash: hasher.server_record_id_hash(server_record_name),
        lease_reference: stage.lease_reference,
    })
}

/// Caller verifies the committed lease before this open, as in chat create.
pub(crate) fn open_staged_outbound_attachment(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
    expected_payload_sha256: &str,
    expected_record_id_hash: &str,
) -> Result<(CloudAttachment, String), Failure> {
    let value = cloud_sync_open_protected_outbound_attachment(
        storage_directory.clone(),
        account_fingerprint,
        protected_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if value.len() > MAX_ATTACHMENT_ENVELOPE_BYTES.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let encoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| Failure::MalformedMessage)?;
    if digest(&encoded) != expected_payload_sha256 {
        return Err(Failure::BindingMismatch);
    }
    let (attachment, record_name) = decode_attachment_envelope(&encoded)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if hasher.server_record_id_hash(&record_name) != expected_record_id_hash {
        return Err(Failure::BindingMismatch);
    }
    Ok((attachment, record_name))
}

/// Stable content equivalence between the persisted original and a fetched
/// readback. Metadata compares as full plist bytes; the asset compares by
/// size, signature, reference signature, and protection key, plus the
/// record_id binding rule for staged and present fetched identifiers.
fn verify_stable_attachment_content(
    expected: &CloudAttachment,
    actual: &CloudAttachment,
    record_name: &str,
) -> Result<(), Failure> {
    let mut expected_meta = Vec::new();
    plist::to_writer_binary(&mut expected_meta, &expected.cm.0)
        .map_err(|_| Failure::BindingMismatch)?;
    let mut actual_meta = Vec::new();
    plist::to_writer_binary(&mut actual_meta, &actual.cm.0)
        .map_err(|_| Failure::BindingMismatch)?;
    if expected_meta != actual_meta {
        return Err(Failure::BindingMismatch);
    }
    let (expected_asset, actual_asset) = (&expected.lqa, &actual.lqa);
    if expected_asset.size != actual_asset.size
        || expected_asset.signature != actual_asset.signature
        || expected_asset.reference_signature != actual_asset.reference_signature
        || expected_asset
            .protection_info
            .as_ref()
            .and_then(|info| info.protection_info.as_ref())
            != actual_asset
                .protection_info
                .as_ref()
                .and_then(|info| info.protection_info.as_ref())
    {
        return Err(Failure::BindingMismatch);
    }
    // The fetched content must still be well-formed completed-asset shape; a
    // record that lost its content identity is divergence, not a transient.
    // The upload receipt is deliberately not required here: the fetch
    // decoder does not require one.
    validate_completed_attachment_shape(actual).map_err(|_| Failure::BindingMismatch)?;
    // Record identity: the expected envelope always carries the staged binding
    // (encode requires it). A present fetched record_id must satisfy the same
    // binding; an omitted one rests on the authenticated outer exact-name
    // receipt premise per the native decoder.
    validate_record_binding(expected.lqa.record_id.as_ref(), record_name)
        .map_err(|_| Failure::BindingMismatch)?;
    if let Some(actual_id) = actual.lqa.record_id.as_ref() {
        validate_record_binding(Some(actual_id), record_name)
            .map_err(|_| Failure::BindingMismatch)?;
        if Some(actual_id) != expected.lqa.record_id.as_ref() {
            return Err(Failure::BindingMismatch);
        }
    }
    Ok(())
}

fn validate(attachment: &CloudAttachment, record_name: &str) -> Result<(), Failure> {
    if record_name.is_empty()
        || record_name.len() > MAX_IDENTIFIER_BYTES
        || !Uuid::parse_str(record_name)
            .is_ok_and(|uuid| uuid.get_version() == Some(uuid::Version::Random))
    {
        return Err(Failure::MalformedMessage);
    }
    validate_completed_attachment_shape(attachment)?;
    validate_record_binding(attachment.lqa.record_id.as_ref(), record_name)?;
    // Completed upload shape only: a staged-but-never-uploaded asset has no
    // receipt and must not enter the initial-create envelope.
    if !attachment
        .lqa
        .upload_receipt
        .as_ref()
        .is_some_and(|receipt| !receipt.is_empty())
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

/// Exact shape from the legacy attachment_create validator (validate_attachment),
/// mapped onto the shared failure type. The zone/record_id create-only binding
/// is left to transport on purpose.
///
/// NOTE: these checks duplicate that private validator because the agreed scope
/// covers only this file, lib.rs, and the proto. If the source validator is ever
/// exposed, delete this copy and call it instead (pending refactor, not new logic).
fn validate_completed_attachment_shape(attachment: &CloudAttachment) -> Result<(), Failure> {
    let metadata = &attachment.cm.0;
    let asset = &attachment.lqa;
    if metadata.guid.is_empty()
        || metadata.guid.len() > MAX_IDENTIFIER_BYTES
        || metadata.guid.chars().any(char::is_control)
        || !metadata.is_outgoing
        || metadata.version != 1
        || metadata.total_bytes < 0
        || asset.size != Some(metadata.total_bytes as u64)
        || asset.size.is_none_or(|size| size > u32::MAX as u64)
        || !asset
            .signature
            .as_ref()
            .is_some_and(|signature| signature.len() == 21 && signature[0] == 4)
        || !asset
            .reference_signature
            .as_ref()
            .is_some_and(|signature| signature.len() == 21 && signature[0] == 1)
        || !asset
            .protection_info
            .as_ref()
            .and_then(|info| info.protection_info.as_ref())
            .is_some_and(|key| key.len() == 32)
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}
/// Record identity binding using the actual RecordIdentifier schema: the
/// staged asset must carry a record_id whose record name is the allocated
/// name and whose zone is attachmentManateeZone. This mirrors the record_id
/// check in build_create_operation, except the zone owner: that identifier
/// is account material stamped by the authenticated container at transport
/// time, so this codec checks name plus zone and leaves the owner to
/// transport and auth.
pub(crate) fn validate_record_binding(
    record_id: Option<&RecordIdentifier>,
    record_name: &str,
) -> Result<(), Failure> {
    let identifier = record_id.ok_or(Failure::MalformedMessage)?;
    let name = identifier
        .value
        .as_ref()
        .and_then(|value| value.name.as_deref());
    let identifier_type = identifier.value.as_ref().and_then(|value| value.r#type);
    let zone_name = identifier
        .zone_identifier
        .as_ref()
        .and_then(|zone| zone.value.as_ref())
        .and_then(|value| value.name.as_deref());
    let zone_type = identifier
        .zone_identifier
        .as_ref()
        .and_then(|zone| zone.value.as_ref())
        .and_then(|value| value.r#type);
    if name != Some(record_name)
        || zone_name != Some(ATTACHMENT_CREATE_ZONE)
        || zone_type != Some(rustpush::cloudkit_proto::identifier::Type::RecordZone.into())
        || identifier_type != Some(rustpush::cloudkit_proto::identifier::Type::Record.into())
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const RECORD: &str = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD";
    const OTHER_RECORD: &str = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE";

    #[test]
    fn attachment_initial_operation_matches_fixed_dart_domain_vector() {
        assert_eq!(
            initial_attachment_create_operation_id(&"A".repeat(43), &"L".repeat(43)).unwrap(),
            "op1:7b2b89e41a267f080a5bdc0e27e83abbbfaa0cd14d1c7e0cbadccbd52ff5a04c"
        );
        for invalid in [String::new(), "A".repeat(42), "A".repeat(44), "!".repeat(43)] {
            assert!(initial_attachment_create_operation_id(&invalid, &"L".repeat(43)).is_err());
            assert!(initial_attachment_create_operation_id(&"A".repeat(43), &invalid).is_err());
        }
    }

    fn attachment_zone() -> rustpush::cloudkit_proto::RecordZoneIdentifier {
        rustpush::cloudkit_proto::RecordZoneIdentifier {
            value: Some(rustpush::cloudkit_proto::Identifier {
                name: Some("attachmentManateeZone".to_owned()),
                r#type: Some(rustpush::cloudkit_proto::identifier::Type::RecordZone.into()),
            }),
            owner_identifier: None,
            environment: None,
        }
    }

    fn fixture() -> CloudAttachment {
        CloudAttachment {
            cm: GZipWrapper(AttachmentMeta {
                guid: "attachment-fixture-guid".to_owned(),
                is_outgoing: true,
                version: 1,
                total_bytes: 3,
                mime_type: Some("application/pdf".to_owned()),
                ..Default::default()
            }),
            lqa: Asset {
                size: Some(3),
                signature: Some(vec![4; 21]),
                reference_signature: Some(vec![1; 21]),
                record_id: Some(rustpush::cloudkit_proto::RecordIdentifier {
                    value: Some(rustpush::cloudkit_proto::Identifier {
                        name: Some(RECORD.to_owned()),
                        r#type: Some(rustpush::cloudkit_proto::identifier::Type::Record.into()),
                    }),
                    zone_identifier: Some(attachment_zone()),
                }),
                upload_receipt: Some("fixture-receipt".to_owned()),
                protection_info: Some(rustpush::cloudkit_proto::ProtectionInfo {
                    protection_info: Some(vec![7; 32]),
                    protection_info_tag: None,
                }),
                ..Default::default()
            },
        }
    }

    #[test]
    fn attachment_round_trip_keeps_record_and_payload_identity() {
        let source = fixture();
        let encoded = encode_attachment(&source, RECORD).unwrap();
        let (restored, record) = decode_attachment_envelope(&encoded).unwrap();
        assert_eq!(record, RECORD);
        assert_eq!(restored.cm.0.guid, source.cm.0.guid);
        assert_eq!(restored.cm.0.total_bytes, source.cm.0.total_bytes);
        assert_eq!(restored.lqa.size, source.lqa.size);
        assert_eq!(restored.lqa.signature, source.lqa.signature);
        assert_eq!(
            restored.lqa.reference_signature,
            source.lqa.reference_signature
        );
        assert_eq!(
            verify_attachment_readback(&source, &restored, RECORD, RECORD, &digest(&encoded))
                .unwrap(),
            digest(&encoded)
        );
        assert_eq!(encode_attachment(&restored, &record).unwrap(), encoded);
        assert_eq!(
            outbound_attachment_payload_sha256(&restored, &record).unwrap(),
            digest(&encoded)
        );
    }

    #[test]
    fn attachment_payload_hash_binds_record_name_and_bytes() {
        let original = outbound_attachment_payload_sha256(&fixture(), RECORD).unwrap();
        let mut renamed = fixture();
        renamed
            .lqa
            .record_id
            .as_mut()
            .unwrap()
            .value
            .as_mut()
            .unwrap()
            .name = Some(OTHER_RECORD.to_owned());
        assert_ne!(
            original,
            outbound_attachment_payload_sha256(&renamed, OTHER_RECORD).unwrap()
        );
        let mut other = fixture();
        other.cm.0.guid = "other-guid".to_owned();
        assert_ne!(
            original,
            outbound_attachment_payload_sha256(&other, RECORD).unwrap()
        );
        let mut resized = fixture();
        resized.cm.0.total_bytes = 4;
        resized.lqa.size = Some(4);
        assert_ne!(
            original,
            outbound_attachment_payload_sha256(&resized, RECORD).unwrap()
        );
    }

    #[test]
    fn attachment_envelope_rejects_wrong_record_metadata_and_asset() {
        assert!(encode_attachment(&fixture(), "").is_err());
        assert!(encode_attachment(&fixture(), "not-a-uuid").is_err());
        // Nil UUID is well-formed but not a random allocation.
        assert!(encode_attachment(&fixture(), "00000000-0000-0000-0000-000000000000").is_err());
        let changes: &[fn(&mut CloudAttachment)] = &[
            |a| a.cm.0.guid.clear(),
            |a| a.cm.0.is_outgoing = false,
            |a| a.cm.0.version = 0,
            |a| a.cm.0.total_bytes = -1,
            |a| a.lqa.size = Some(4),
            |a| a.lqa.size = Some(u32::MAX as u64 + 1),
            |a| a.lqa.signature = None,
            |a| a.lqa.signature = Some(vec![1; 21]),
            |a| a.lqa.reference_signature = None,
            |a| a.lqa.protection_info = None,
            |a| {
                a.lqa
                    .protection_info
                    .as_mut()
                    .and_then(|info| info.protection_info.as_mut())
                    .unwrap()
                    .truncate(16);
            },
            |a| a.lqa.upload_receipt = None,
            |a| a.lqa.record_id = None,
            |a| a.lqa.upload_receipt = Some(String::new()),
        ];
        for change in changes {
            let mut broken = fixture();
            change(&mut broken);
            assert!(encode_attachment(&broken, RECORD).is_err());
        }
        // A renamed envelope must agree with its embedded asset record ID.
        let encoded = encode_attachment(&fixture(), RECORD).unwrap();
        let mut envelope = CloudSyncOutboundAttachmentV1::decode(encoded.as_slice()).unwrap();
        envelope.server_record_name = OTHER_RECORD.to_owned();
        let renamed = envelope.encode_to_vec();
        assert!(decode_attachment_envelope(&renamed).is_err());
        // Truncated asset bytes fail decode.
        let mut truncated = CloudSyncOutboundAttachmentV1::decode(encoded.as_slice()).unwrap();
        truncated
            .asset_proto
            .truncate(truncated.asset_proto.len() - 1);
        assert!(decode_attachment_envelope(&truncated.encode_to_vec()).is_err());
        // A plist of the wrong shape fails decode even with a valid asset.
        let mut wrong_plist = Vec::new();
        plist::to_writer_binary(&mut wrong_plist, &"not-attachment-meta").unwrap();
        let mut swapped = CloudSyncOutboundAttachmentV1::decode(encoded.as_slice()).unwrap();
        swapped.attachment_meta_plist = wrong_plist;
        assert!(decode_attachment_envelope(&swapped.encode_to_vec()).is_err());
    }

    #[test]
    fn attachment_envelope_rejects_malformed_oversized_and_future_version() {
        assert!(decode_attachment_envelope(&[]).is_err());
        assert!(decode_attachment_envelope(&[0, 1, 2, 3]).is_err());
        assert!(decode_attachment_envelope(&vec![0; MAX_ATTACHMENT_ENVELOPE_BYTES + 1]).is_err());
        let encoded = encode_attachment(&fixture(), RECORD).unwrap();
        assert!(decode_attachment_envelope(&encoded[..encoded.len() - 1]).is_err());
        let mut envelope = CloudSyncOutboundAttachmentV1::decode(encoded.as_slice()).unwrap();
        envelope.schema_version += 1;
        assert!(decode_attachment_envelope(&envelope.encode_to_vec()).is_err());
        // Metadata beyond the headroom bound is oversized, not merely malformed.
        let mut huge = fixture();
        huge.cm.0.mime_type = Some("x".repeat(MAX_ATTACHMENT_METADATA_BYTES));
        assert_eq!(
            encode_attachment(&huge, RECORD),
            Err(Failure::OversizedMessage)
        );
    }

    #[test]
    fn exact_attachment_readback_binds_original_name_and_stable_content() {
        let source = fixture();
        let expected = outbound_attachment_payload_sha256(&source, RECORD).unwrap();
        let (restored, original_name) =
            decode_attachment_envelope(&encode_attachment(&source, RECORD).unwrap()).unwrap();
        assert_eq!(original_name, RECORD);
        assert_eq!(
            verify_attachment_readback(&source, &restored, RECORD, &original_name, &expected)
                .unwrap(),
            expected
        );
        assert!(
            verify_attachment_readback(&source, &restored, RECORD, RECORD, &"f".repeat(64))
                .is_err()
        );
        assert!(
            verify_attachment_readback(&source, &restored, OTHER_RECORD, RECORD, &expected)
                .is_err()
        );
        // A separately staged replacement name is not proof of the original.
        assert!(
            verify_attachment_readback(&source, &restored, RECORD, OTHER_RECORD, &expected)
                .is_err()
        );
        // Altered stable content fails even with the right names and digest.
        let mut resized = restored.clone();
        resized.cm.0.total_bytes = 4;
        resized.lqa.size = Some(4);
        assert!(verify_attachment_readback(&source, &resized, RECORD, RECORD, &expected).is_err());
        let mut rekeyed = restored.clone();
        rekeyed
            .lqa
            .protection_info
            .as_mut()
            .unwrap()
            .protection_info = Some(vec![9; 32]);
        assert!(verify_attachment_readback(&source, &rekeyed, RECORD, RECORD, &expected).is_err());
        let mut resign = restored.clone();
        resign.lqa.signature = Some(vec![4; 20]);
        assert!(verify_attachment_readback(&source, &resign, RECORD, RECORD, &expected).is_err());
        let mut reguid = restored.clone();
        reguid.cm.0.guid = "other-guid".to_owned();
        assert!(verify_attachment_readback(&source, &reguid, RECORD, RECORD, &expected).is_err());
    }

    #[test]
    fn attachment_readback_ignores_only_documented_transients() {
        let source = fixture();
        let expected = outbound_attachment_payload_sha256(&source, RECORD).unwrap();
        // A fetched record legitimately lacks the upload receipt and carries
        // delivery/auth material that was never part of the content.
        let mut fetched = source.clone();
        fetched.lqa.upload_receipt = None;
        fetched.lqa.download_token = Some("transient-token".to_owned());
        fetched.lqa.download_request = Some(vec![1, 2, 3]);
        fetched.lqa.content_base_url = Some("https://transient.invalid".to_owned());
        fetched.lqa.download_base_url = Some("https://transient.invalid/dl".to_owned());
        fetched.lqa.download_url_expiration = Some(1700000000);
        assert_eq!(
            verify_attachment_readback(&source, &fetched, RECORD, RECORD, &expected).unwrap(),
            expected
        );
    }

    #[test]
    fn outbound_attachment_payload_cannot_decode_as_message_envelope() {
        let encoded = encode_attachment(&fixture(), RECORD).unwrap();
        // The attachment record name uses wire field 2 as a string; messages
        // use a boolean there. Chat/message separation also exists in the
        // protection scope, same as the chat envelope.
        assert!(wire::CloudSyncOutboundMessageV1::decode(encoded.as_slice()).is_err());
    }

    #[test]
    fn attachment_envelope_rejects_record_binding_mismatch() {
        let mut wrong_name = fixture();
        wrong_name
            .lqa
            .record_id
            .as_mut()
            .unwrap()
            .value
            .as_mut()
            .unwrap()
            .name = Some(OTHER_RECORD.to_owned());
        assert!(encode_attachment(&wrong_name, RECORD).is_err());
        let mut wrong_zone = fixture();
        wrong_zone
            .lqa
            .record_id
            .as_mut()
            .unwrap()
            .zone_identifier
            .as_mut()
            .unwrap()
            .value
            .as_mut()
            .unwrap()
            .name = Some("messageManateeZone".to_owned());
        assert!(encode_attachment(&wrong_zone, RECORD).is_err());
    }

    #[test]
    fn attachment_readback_record_id_present_must_bind_omitted_relies_on_receipt() {
        let source = fixture();
        let expected = outbound_attachment_payload_sha256(&source, RECORD).unwrap();
        // Omitted fetched record_id passes on the authenticated outer
        // exact-name receipt premise.
        let mut omitted = source.clone();
        omitted.lqa.record_id = None;
        assert!(verify_attachment_readback(&source, &omitted, RECORD, RECORD, &expected).is_ok());
        // Present but mismatching record_id fails.
        let mut rebound = source.clone();
        rebound
            .lqa
            .record_id
            .as_mut()
            .unwrap()
            .value
            .as_mut()
            .unwrap()
            .name = Some(OTHER_RECORD.to_owned());
        assert!(verify_attachment_readback(&source, &rebound, RECORD, RECORD, &expected).is_err());
        let mut rezoned = source.clone();
        rezoned
            .lqa
            .record_id
            .as_mut()
            .unwrap()
            .zone_identifier
            .as_mut()
            .unwrap()
            .value
            .as_mut()
            .unwrap()
            .name = Some("messageManateeZone".to_owned());
        assert!(verify_attachment_readback(&source, &rezoned, RECORD, RECORD, &expected).is_err());
        let mut reowned = source.clone();
        reowned
            .lqa
            .record_id
            .as_mut()
            .unwrap()
            .zone_identifier
            .as_mut()
            .unwrap()
            .owner_identifier = Some(rustpush::cloudkit_proto::Identifier {
            name: Some("different-owner".to_owned()),
            r#type: Some(rustpush::cloudkit_proto::identifier::Type::User.into()),
        });
        assert!(verify_attachment_readback(&source, &reowned, RECORD, RECORD, &expected).is_err());
    }
}
