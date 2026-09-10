//! Exact pre-upload recovery material for CloudKit attachment writes.
//!
//! File upload and record create are separate durable steps. The original
//! randomized MMCS preparation, record identity, metadata, and local parent
//! must survive a restart together. This module stages that protected plan
//! and validates its completed upload, but never grants network permission.
//! The coordinator must persist upload-attempt ownership before network I/O;
//! reopening a plan or observing a missing record is NOT upload-retry authority.
#![cfg_attr(not(test), allow(dead_code))]

use std::{
    io::{self, Cursor, Read, Seek, SeekFrom},
    path::PathBuf,
    time::Duration,
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message;
use rustpush::{
    cloud_messages::{
        AttachmentMeta, CloudAttachment, CloudAttachmentNativeUploadInput, CloudMessagesClient,
        CloudMessagesPreparedUploadSubmission, CloudMessagesWriterPreparationBinding, GZipWrapper,
    },
    cloudkit::CloudKitRequestIdentity,
    cloudkit_proto::{Asset, RecordIdentifier},
    mmcs::PreparedPut,
    DefaultAnisetteProvider,
};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    cloud_sync_canonical_dto::CloudCanonicalEntityKind,
    cloud_sync_native_fetch::{
        cloud_sync_open_protected_attachment_upload,
        cloud_sync_stage_protected_attachment_upload_envelope,
        cloud_sync_verify_committed_lease_exact,
    },
    cloud_sync_outbound::{CloudSyncOutboundFailure as Failure, NativeProtectedOutboundStage},
    cloud_sync_outbound_attachment::{encode_attachment, validate_record_binding},
};

mod wire {
    include!(concat!(
        env!("OUT_DIR"),
        "/openbubbles.cloudsync.outbound.rs"
    ));
}

const VERSION: u32 = 2;
const MAX_PLAN_BYTES: usize = 2 * 1024 * 1024;
const MAX_METADATA_BYTES: usize = 1024 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 4096;

/// Hash precisely the bytes used for randomized preparation in the same pass.
/// A second read of an editable path would not establish this relationship.
struct PreparationSource<R> {
    reader: R,
    hash: Sha256,
    count: u64,
    expected_length: u64,
}

impl<R: Read> Read for PreparationSource<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = self.reader.read(buffer)?;
        self.count = self
            .count
            .checked_add(count as u64)
            .filter(|count| *count <= self.expected_length)
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "attachment length changed")
            })?;
        self.hash.update(&buffer[..count]);
        Ok(count)
    }
}

/// Local file preparation only, using existing boundary-key material. Caller
/// must first validate the live account/container and pin the actual IDS source.
/// This neither uploads bytes nor provisions missing keychain/CloudKit state.
pub(crate) async fn prepare_attachment_upload_plan<R: Read + Send + Sync>(
    client: &CloudMessagesClient<DefaultAnisetteProvider>,
    parent_message_guid: String,
    parent_source_sha256: String,
    record_identifier: RecordIdentifier,
    metadata: AttachmentMeta,
    source: R,
) -> Result<AttachmentUploadPlan, AttachmentUploadPreparationFailure> {
    let expected_length =
        u32::try_from(metadata.total_bytes).map_err(|_| Failure::OversizedMessage)? as u64;
    let mut source = PreparationSource {
        reader: source,
        hash: Sha256::new(),
        count: 0,
        expected_length,
    };
    let prepared = client
        .prepare_file_lookup_only(&mut source)
        .await
        .map_err(|_| AttachmentUploadPreparationFailure::PreparationUnavailable)?;
    if source.count != expected_length {
        return Err(Failure::BindingMismatch.into());
    }
    Ok(AttachmentUploadPlan::new(
        parent_message_guid,
        parent_source_sha256,
        record_identifier,
        metadata,
        prepared,
        format!("{:x}", source.hash.finalize()),
    )?)
}

/// Connect the pinned IDS descriptor, initial reflected metadata and immutable
/// plaintext snapshot to one V2 preparation. The source path is opened by the
/// caller; mutable bytes never enter V2 preparation before original IDS proof.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn prepare_verified_ids_upload_plan<R: Read + Send>(
    client: &CloudMessagesClient<DefaultAnisetteProvider>,
    decoded: &crate::cloud_sync_ids_attachment_source::DecodedIdsAttachmentSource,
    parent_source_sha256: String,
    original_attachment_guid: &str,
    times: &crate::cloud_sync_ids_attachment_source::NativeAttachmentMetaTimes,
    record_identifier: RecordIdentifier,
    source: &mut R,
    private_directory: &std::path::Path,
) -> Result<AttachmentUploadPlan, AttachmentUploadPreparationFailure> {
    let material = crate::cloud_sync_ids_attachment_source::decoded_attachment_upload_material(
        decoded,
        original_attachment_guid,
        times,
    )?;
    let snapshot = crate::cloud_sync_attachment_source_file::snapshot_verified_source(
        source,
        &material.file,
        private_directory,
    )
    .await
    .map_err(|_| AttachmentUploadPreparationFailure::SourceUnavailable)?;
    prepare_attachment_upload_plan(
        client,
        decoded.message_guid.clone(),
        parent_source_sha256,
        record_identifier,
        material.meta,
        snapshot,
    )
    .await
}

/// Fixed native-only diagnostics; key lookup failure is not falsely labeled
/// protected-store corruption and carries no raw keychain/auth error outward.
#[derive(Clone, Copy, Debug, thiserror::Error, Eq, PartialEq)]
pub(crate) enum AttachmentUploadPreparationFailure {
    #[error("attachment source preparation unavailable")]
    PreparationUnavailable,
    #[error("attachment source unavailable or does not match original IDS bytes")]
    SourceUnavailable,
    #[error("attachment upload source invalid")]
    InvalidSource(#[from] Failure),
}

/// No Debug/Serialize implementation: the preparation contains file keys.
pub(crate) struct AttachmentUploadPlan {
    parent_message_guid: String,
    parent_source_sha256: String,
    record_identifier: RecordIdentifier,
    metadata: AttachmentMeta,
    prepared: PreparedPut,
    source_file_sha256: String,
    // None only for a retained version-1 plan. Its original preparation stays
    // readable, but lack of an original request identity cannot permit upload.
    upload_identity: Option<CloudKitRequestIdentity>,
}

impl AttachmentUploadPlan {
    /// Caller supplies the original allocated record identifier obtained from
    /// the exact authenticated container. No fresh allocation occurs on reopen.
    pub(crate) fn new(
        parent_message_guid: String,
        parent_source_sha256: String,
        record_identifier: RecordIdentifier,
        metadata: AttachmentMeta,
        prepared: PreparedPut,
        source_file_sha256: String,
    ) -> Result<Self, Failure> {
        let plan = Self {
            parent_message_guid,
            parent_source_sha256,
            record_identifier,
            metadata,
            prepared,
            source_file_sha256,
            upload_identity: Some(
                CloudKitRequestIdentity::new(
                    Uuid::new_v4().to_string().to_uppercase(),
                    vec![Uuid::new_v4().to_string().to_uppercase()],
                )
                .map_err(|_| Failure::MalformedMessage)?,
            ),
        };
        plan.validated_preparation_snapshot()?;
        Ok(plan)
    }

    fn validated_preparation_snapshot(&self) -> Result<Vec<u8>, Failure> {
        if let Some(identity) = &self.upload_identity {
            validate_upload_identity(identity)?;
        }
        if !Uuid::parse_str(&self.parent_message_guid)
            .is_ok_and(|id| id.get_version() == Some(uuid::Version::Random))
            || !is_sha256(&self.parent_source_sha256)
            || !is_sha256(&self.source_file_sha256)
            || self.metadata.guid.is_empty()
            || self.metadata.guid.len() > MAX_IDENTIFIER_BYTES
            || self.metadata.guid.chars().any(char::is_control)
            || !self.metadata.is_outgoing
            || self.metadata.version != 1
            || self.metadata.total_bytes < 0
            || self.metadata.total_bytes as u64 != self.prepared.total_len as u64
            || self.prepared.total_len as u64 > u32::MAX as u64
        {
            return Err(Failure::MalformedMessage);
        }
        let name = self.record_name()?;
        if !Uuid::parse_str(name).is_ok_and(|id| id.get_version() == Some(uuid::Version::Random)) {
            return Err(Failure::MalformedMessage);
        }
        validate_record_binding(Some(&self.record_identifier), name)?;
        // Includes all chunk keys/signatures and the encrypted FORD descriptor.
        self.prepared
            .encode_v2_upload_snapshot()
            .map_err(|_| Failure::MalformedMessage)
    }

    pub(crate) fn record_name(&self) -> Result<&str, Failure> {
        self.record_identifier
            .value
            .as_ref()
            .and_then(|id| id.name.as_deref())
            .ok_or(Failure::MalformedMessage)
    }

    /// Content-free correlation returned to the durable upload journal. The
    /// HTTP identity remains native inside this same protected plan.
    pub(crate) fn upload_attempt_id(&self) -> Result<&str, Failure> {
        let identity = self
            .upload_identity
            .as_ref()
            .ok_or(Failure::BindingMismatch)?;
        validate_upload_identity(identity)?;
        Ok(&identity.operation_uuids()[0])
    }

    /// Reopen the original plan against the pinned IDS source. Copy and verify
    /// the current file once, then retain that immutable handle for consumption.
    /// No new preparation, file keys, record name, or request UUID is allocated.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn prepare_verified_submission<R: Read + Send>(
        &self,
        client: &CloudMessagesClient<DefaultAnisetteProvider>,
        writer_binding: &CloudMessagesWriterPreparationBinding<DefaultAnisetteProvider>,
        decoded: &crate::cloud_sync_ids_attachment_source::DecodedIdsAttachmentSource,
        parent_source_sha256: &str,
        original_attachment_guid: &str,
        record_identifier: &RecordIdentifier,
        local_operation_id: String,
        source: &mut R,
        private_directory: &std::path::Path,
        timeout: Duration,
    ) -> Result<
        CloudMessagesPreparedUploadSubmission<
            DefaultAnisetteProvider,
            crate::cloud_sync_attachment_source_file::OwnedAttachmentSource,
        >,
        AttachmentUploadPreparationFailure,
    > {
        self.validate_origin(
            &decoded.message_guid,
            parent_source_sha256,
            record_identifier,
        )?;
        let material = crate::cloud_sync_ids_attachment_source::decoded_attachment_upload_material(
            decoded,
            original_attachment_guid,
            &crate::cloud_sync_ids_attachment_source::NativeAttachmentMetaTimes {
                start_date_ns: self.metadata.start_date,
                created_date_ns: self.metadata.created_date,
            },
        )?;
        // The complete canonical metadata must still be the initial projection
        // of the same original IDS body, including its attachment GUID.
        let mut expected = Vec::new();
        let mut actual = Vec::new();
        plist::to_writer_binary(&mut expected, &self.metadata)
            .map_err(|_| Failure::MalformedMessage)?;
        plist::to_writer_binary(&mut actual, &material.meta)
            .map_err(|_| Failure::MalformedMessage)?;
        if expected != actual {
            return Err(Failure::BindingMismatch.into());
        }
        let snapshot = crate::cloud_sync_attachment_source_file::snapshot_verified_source(
            source,
            &material.file,
            private_directory,
        )
        .await
        .map_err(|_| AttachmentUploadPreparationFailure::SourceUnavailable)?;
        self.prepare_native_submission(
            client,
            writer_binding,
            &decoded.message_guid,
            parent_source_sha256,
            record_identifier,
            local_operation_id,
            snapshot,
            timeout,
        )
        .await
    }

    /// The receipt must contain the original metadata and the exact asset
    /// validated by this plan, not merely another completed attachment.
    pub(crate) fn validate_completed_envelope(
        &self,
        encoded: &[u8],
    ) -> Result<CloudAttachment, Failure> {
        let (attachment, record_name) =
            crate::cloud_sync_outbound_attachment::decode_attachment_envelope(encoded)?;
        if record_name != self.record_name()? {
            return Err(Failure::BindingMismatch);
        }
        let validated = self.complete(attachment.lqa)?;
        if encode_attachment(&validated, self.record_name()?)? != encoded {
            return Err(Failure::BindingMismatch);
        }
        Ok(validated)
    }

    /// Require the same immutable local origin AND exact container-issued
    /// record identifier immediately before using this plan. A matching file
    /// alone cannot transfer it to another message, recipient, or account.
    pub(crate) fn validate_origin(
        &self,
        parent_message_guid: &str,
        parent_source_sha256: &str,
        record_identifier: &RecordIdentifier,
    ) -> Result<(), Failure> {
        if self.parent_message_guid != parent_message_guid
            || self.parent_source_sha256 != parent_source_sha256
            || self.record_identifier != *record_identifier
        {
            return Err(Failure::BindingMismatch);
        }
        Ok(())
    }

    pub(crate) fn validate_parent_source(&self, guid: &str, sha256: &str) -> Result<(), Failure> {
        self.validate_origin(guid, sha256, &self.record_identifier)
    }

    /// Bounded-memory validation of the retained plaintext file. This does not
    /// replace MMCS's per-chunk integrity check during upload. Callers must hold
    /// an immutable source while uploading, rather than reopening a mutable path.
    pub(crate) fn validate_source(&self, mut source: impl Read) -> Result<(), Failure> {
        let mut hash = Sha256::new();
        let mut total = 0u64;
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let count = source
                .read(&mut buffer)
                .map_err(|_| Failure::ProtectedStorage)?;
            if count == 0 {
                break;
            }
            total = total
                .checked_add(count as u64)
                .ok_or(Failure::OversizedMessage)?;
            if total > self.prepared.total_len as u64 {
                return Err(Failure::BindingMismatch);
            }
            hash.update(&buffer[..count]);
        }
        if total != self.prepared.total_len as u64
            || format!("{:x}", hash.finalize()) != self.source_file_sha256
        {
            return Err(Failure::BindingMismatch);
        }
        Ok(())
    }

    /// Connect the recovered plan to the native one-attempt uploader, without
    /// re-preparing bytes or generating new file keys. A seekable, retained
    /// source is validated and rewound on the SAME handle. Caller must still
    /// persist an attempt before consuming the returned native owner; this
    /// method is local preparation and grants no network/retry authority.
    pub(crate) fn native_upload_input<R: Read + Seek + Send + Sync>(
        &self,
        parent_message_guid: &str,
        parent_source_sha256: &str,
        record_identifier: &RecordIdentifier,
        local_operation_id: String,
        apple_operation_uuid: String,
        mut source: R,
    ) -> Result<CloudAttachmentNativeUploadInput<R>, Failure> {
        self.validate_origin(parent_message_guid, parent_source_sha256, record_identifier)?;
        if self.upload_attempt_id()? != apple_operation_uuid {
            return Err(Failure::BindingMismatch);
        }
        let snapshot = self.validated_preparation_snapshot()?;
        source
            .seek(SeekFrom::Start(0))
            .map_err(|_| Failure::ProtectedStorage)?;
        self.validate_source(&mut source)?;
        source
            .seek(SeekFrom::Start(0))
            .map_err(|_| Failure::ProtectedStorage)?;
        Ok(CloudAttachmentNativeUploadInput {
            local_operation_id,
            server_record_name: self.record_name()?.to_owned(),
            apple_operation_uuid,
            prepared: PreparedPut::from_v2_upload_snapshot(&snapshot)
                .map_err(|_| Failure::MalformedMessage)?,
            reader: source,
        })
    }

    /// Binds the actual native owner to the request already sealed in the
    /// plan. Reopening must never allocate a replacement request identity.
    /// Caller must durably begin this attempt before consuming the owner.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn prepare_native_submission<R: Read + Seek + Send + Sync>(
        &self,
        client: &CloudMessagesClient<DefaultAnisetteProvider>,
        writer_binding: &CloudMessagesWriterPreparationBinding<DefaultAnisetteProvider>,
        parent_message_guid: &str,
        parent_source_sha256: &str,
        record_identifier: &RecordIdentifier,
        local_operation_id: String,
        source: R,
        timeout: Duration,
    ) -> Result<
        CloudMessagesPreparedUploadSubmission<DefaultAnisetteProvider, R>,
        AttachmentUploadPreparationFailure,
    > {
        let identity = self
            .upload_identity
            .as_ref()
            .ok_or(Failure::BindingMismatch)?;
        let input = self.native_upload_input(
            parent_message_guid,
            parent_source_sha256,
            record_identifier,
            local_operation_id,
            self.upload_attempt_id()?.to_owned(),
            source,
        )?;
        client
            .prepare_attachment_native_upload_submission(
                writer_binding,
                input,
                identity.clone(),
                timeout,
            )
            .await
            .map_err(|_| AttachmentUploadPreparationFailure::PreparationUnavailable)
    }

    fn encode(&self) -> Result<Vec<u8>, Failure> {
        let prepared_put_snapshot = self.validated_preparation_snapshot()?;
        let mut metadata = Vec::new();
        plist::to_writer_binary(&mut metadata, &self.metadata)
            .map_err(|_| Failure::MalformedMessage)?;
        if metadata.len() > MAX_METADATA_BYTES
            || self.record_identifier.encoded_len() > MAX_IDENTIFIER_BYTES
        {
            return Err(Failure::OversizedMessage);
        }
        let wire = wire::CloudSyncAttachmentUploadV1 {
            schema_version: if self.upload_identity.is_some() {
                VERSION
            } else {
                1
            },
            parent_message_guid: self.parent_message_guid.clone(),
            parent_source_sha256: self.parent_source_sha256.clone(),
            record_identifier_proto: self.record_identifier.encode_to_vec(),
            attachment_meta_plist: metadata,
            prepared_put_snapshot,
            source_file_sha256: self.source_file_sha256.clone(),
            upload_request_uuid: self
                .upload_identity
                .as_ref()
                .map(|identity| identity.http_request_uuid().to_owned())
                .unwrap_or_default(),
            upload_operation_uuid: self
                .upload_identity
                .as_ref()
                .map(|identity| identity.operation_uuids()[0].clone())
                .unwrap_or_default(),
        };
        if wire.encoded_len() > MAX_PLAN_BYTES {
            return Err(Failure::OversizedMessage);
        }
        Ok(wire.encode_to_vec())
    }

    fn decode(bytes: &[u8]) -> Result<Self, Failure> {
        if bytes.is_empty() || bytes.len() > MAX_PLAN_BYTES {
            return Err(Failure::OversizedMessage);
        }
        let wire = wire::CloudSyncAttachmentUploadV1::decode(bytes)
            .map_err(|_| Failure::MalformedMessage)?;
        if !matches!(wire.schema_version, 1 | VERSION)
            || wire.attachment_meta_plist.len() > MAX_METADATA_BYTES
            || wire.record_identifier_proto.len() > MAX_IDENTIFIER_BYTES
        {
            return Err(Failure::MalformedMessage);
        }
        let upload_identity = match wire.schema_version {
            1 if wire.upload_request_uuid.is_empty() && wire.upload_operation_uuid.is_empty() => {
                None
            }
            VERSION => Some(
                CloudKitRequestIdentity::new(
                    wire.upload_request_uuid,
                    vec![wire.upload_operation_uuid],
                )
                .map_err(|_| Failure::MalformedMessage)?,
            ),
            _ => return Err(Failure::MalformedMessage),
        };
        let plan = Self {
            parent_message_guid: wire.parent_message_guid,
            parent_source_sha256: wire.parent_source_sha256,
            record_identifier: RecordIdentifier::decode(wire.record_identifier_proto.as_slice())
                .map_err(|_| Failure::MalformedMessage)?,
            metadata: plist::from_reader(Cursor::new(wire.attachment_meta_plist))
                .map_err(|_| Failure::MalformedMessage)?,
            prepared: PreparedPut::from_v2_upload_snapshot(&wire.prepared_put_snapshot)
                .map_err(|_| Failure::MalformedMessage)?,
            source_file_sha256: wire.source_file_sha256,
            upload_identity,
        };
        plan.validated_preparation_snapshot()?;
        Ok(plan)
    }

    /// Bind the byte-upload result to the exact persisted preparation. This
    /// produces record-create material, NOT a CloudKit record-save receipt.
    /// The returned envelope must be protected and adopted before record create.
    pub(crate) fn complete(&self, asset: Asset) -> Result<CloudAttachment, Failure> {
        if asset.record_id.as_ref() != Some(&self.record_identifier)
            || asset.signature.as_ref() != Some(&self.prepared.total_sig)
            || asset.size != Some(self.prepared.total_len as u64)
            || asset.reference_signature.as_deref()
                != self.prepared.ford.as_ref().map(|ford| ford.0.as_slice())
            || asset
                .protection_info
                .as_ref()
                .and_then(|info| info.protection_info.as_deref())
                != self.prepared.ford_key.as_ref().map(|key| key.as_slice())
            || asset
                .upload_receipt
                .as_ref()
                .is_none_or(|receipt| receipt.is_empty())
        {
            return Err(Failure::BindingMismatch);
        }
        let attachment = CloudAttachment {
            cm: GZipWrapper(self.metadata.clone()),
            lqa: asset,
        };
        encode_attachment(&attachment, self.record_name()?)?;
        Ok(attachment)
    }
}

fn validate_upload_identity(identity: &CloudKitRequestIdentity) -> Result<(), Failure> {
    let valid = |value: &str| {
        Uuid::parse_str(value).is_ok_and(|id| {
            id.get_version() == Some(uuid::Version::Random)
                && id.to_string().to_uppercase() == value
        })
    };
    if identity.operation_uuids().len() != 1
        || !valid(identity.http_request_uuid())
        || !valid(&identity.operation_uuids()[0])
        || identity.http_request_uuid() == identity.operation_uuids()[0]
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

pub(crate) fn stage_attachment_upload(
    storage_directory: PathBuf,
    account_fingerprint: String,
    plan: &AttachmentUploadPlan,
) -> Result<NativeProtectedOutboundStage, Failure> {
    let encoded = plan.encode()?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let logical = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Attachment, &plan.metadata.guid)
        .map_err(|_| Failure::MalformedMessage)?;
    let stage = cloud_sync_stage_protected_attachment_upload_envelope(
        storage_directory,
        account_fingerprint,
        URL_SAFE_NO_PAD.encode(&encoded),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    Ok(NativeProtectedOutboundStage {
        logical_entity_key_hash: logical.value().to_owned(),
        payload_sha256: digest(&encoded),
        payload_length: encoded.len() as u64,
        server_record_id_hash: hasher.server_record_id_hash(plan.record_name()?),
        protected_server_record_reference: stage.protected_envelope_reference.clone(),
        protected_payload_reference: stage.protected_envelope_reference,
        lease_reference: stage.lease_reference,
    })
}

pub(crate) fn open_attachment_upload(
    storage_directory: PathBuf,
    account_fingerprint: String,
    stage: &NativeProtectedOutboundStage,
) -> Result<AttachmentUploadPlan, Failure> {
    if stage.protected_payload_reference != stage.protected_server_record_reference {
        return Err(Failure::BindingMismatch);
    }
    open_attachment_upload_bound(
        storage_directory,
        account_fingerprint,
        stage,
        Some(stage.payload_length),
    )
}

/// The durable Dart journal stores references/hashes, not an envelope length.
/// Hash verification and the native byte limit still cover the full envelope.
/// A missing advisory length must not prevent recovery of a committed plan.
pub(crate) fn open_journaled_attachment_upload(
    storage_directory: PathBuf,
    account_fingerprint: String,
    logical_entity_key_hash: &str,
    protected_reference: &str,
    payload_sha256: &str,
    server_record_id_hash: &str,
    lease_reference: &str,
) -> Result<AttachmentUploadPlan, Failure> {
    let stage = NativeProtectedOutboundStage {
        logical_entity_key_hash: logical_entity_key_hash.to_owned(),
        protected_payload_reference: protected_reference.to_owned(),
        payload_sha256: payload_sha256.to_owned(),
        payload_length: 0, // Not consulted: the persisted journal has no length.
        protected_server_record_reference: protected_reference.to_owned(),
        server_record_id_hash: server_record_id_hash.to_owned(),
        lease_reference: lease_reference.to_owned(),
    };
    open_attachment_upload_bound(storage_directory, account_fingerprint, &stage, None)
}

fn open_attachment_upload_bound(
    storage_directory: PathBuf,
    account_fingerprint: String,
    stage: &NativeProtectedOutboundStage,
    expected_length: Option<u64>,
) -> Result<AttachmentUploadPlan, Failure> {
    cloud_sync_verify_committed_lease_exact(
        storage_directory.clone(),
        &stage.lease_reference,
        std::slice::from_ref(&stage.protected_payload_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let value = cloud_sync_open_protected_attachment_upload(
        storage_directory.clone(),
        account_fingerprint,
        &stage.protected_payload_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if value.len() > MAX_PLAN_BYTES.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| Failure::MalformedMessage)?;
    if digest(&bytes) != stage.payload_sha256
        || expected_length.is_some_and(|length| bytes.len() as u64 != length)
    {
        return Err(Failure::BindingMismatch);
    }
    let plan = AttachmentUploadPlan::decode(&bytes)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let logical = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Attachment, &plan.metadata.guid)
        .map_err(|_| Failure::MalformedMessage)?;
    if hasher.server_record_id_hash(plan.record_name()?) != stage.server_record_id_hash
        || logical.value() != stage.logical_entity_key_hash
    {
        return Err(Failure::BindingMismatch);
    }
    Ok(plan)
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustpush::{
        cloudkit_proto::{identifier::Type, Identifier, ProtectionInfo, RecordZoneIdentifier},
        mmcs::{prepare_put_v2, FileContainer},
    };

    const PARENT: &str = "11111111-2222-4333-8444-555555555555";
    const RECORD: &str = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";
    const CONTENT: &[u8] = b"synthetic attachment fixture, no account data";

    fn record() -> RecordIdentifier {
        RecordIdentifier {
            value: Some(Identifier {
                name: Some(RECORD.to_owned()),
                r#type: Some(Type::Record as i32),
            }),
            zone_identifier: Some(RecordZoneIdentifier {
                value: Some(Identifier {
                    name: Some("attachmentManateeZone".to_owned()),
                    r#type: Some(Type::RecordZone as i32),
                }),
                owner_identifier: Some(Identifier {
                    name: Some("fixture-owner".to_owned()),
                    r#type: Some(Type::User as i32),
                }),
                ..Default::default()
            }),
        }
    }

    async fn plan() -> AttachmentUploadPlan {
        let prepared = prepare_put_v2(
            FileContainer::new(Cursor::new(CONTENT.to_vec())),
            &[0x42; 32],
        )
        .await
        .unwrap();
        AttachmentUploadPlan::new(
            PARENT.to_owned(),
            "a".repeat(64),
            record(),
            AttachmentMeta {
                guid: "fixture-attachment-guid".to_owned(),
                is_outgoing: true,
                version: 1,
                total_bytes: CONTENT.len() as i64,
                mime_type: Some("application/pdf".to_owned()),
                ..Default::default()
            },
            prepared,
            digest(CONTENT),
        )
        .unwrap()
    }

    fn asset(plan: &AttachmentUploadPlan) -> Asset {
        Asset {
            signature: Some(plan.prepared.total_sig.clone()),
            size: Some(plan.prepared.total_len as u64),
            record_id: Some(plan.record_identifier.clone()),
            upload_receipt: Some("synthetic-upload-receipt".to_owned()),
            reference_signature: plan.prepared.ford.as_ref().map(|ford| ford.0.to_vec()),
            protection_info: Some(ProtectionInfo {
                protection_info: plan.prepared.ford_key.map(|key| key.to_vec()),
                protection_info_tag: None,
            }),
            ..Default::default()
        }
    }

    #[test]
    fn preparation_source_hashes_only_consumed_bytes_and_rejects_growth() {
        let mut source = PreparationSource {
            reader: Cursor::new(CONTENT),
            hash: Sha256::new(),
            count: 0,
            expected_length: CONTENT.len() as u64,
        };
        let mut read_back = Vec::new();
        source.read_to_end(&mut read_back).unwrap();
        assert_eq!(read_back, CONTENT);
        assert_eq!(source.count, CONTENT.len() as u64);
        assert_eq!(format!("{:x}", source.hash.finalize()), digest(CONTENT));
        let mut growing = PreparationSource {
            reader: Cursor::new(CONTENT),
            hash: Sha256::new(),
            count: 0,
            expected_length: CONTENT.len() as u64 - 1,
        };
        assert!(growing.read_to_end(&mut Vec::new()).is_err());
    }

    #[tokio::test]
    async fn completed_receipt_recovery_rejects_other_plan_metadata_and_asset() {
        let original = plan().await;
        let completed = original.complete(asset(&original)).unwrap();
        let encoded = encode_attachment(&completed, RECORD).unwrap();
        original.validate_completed_envelope(&encoded).unwrap();
        original
            .validate_parent_source(PARENT, &"a".repeat(64))
            .unwrap();
        assert!(original
            .validate_parent_source(PARENT, &"b".repeat(64))
            .is_err());
        let mut changed = completed.clone();
        changed.cm.0.guid = "other-guid".to_owned();
        assert!(original
            .validate_completed_envelope(&encode_attachment(&changed, RECORD).unwrap())
            .is_err());
        let independently_prepared = plan().await;
        let other = independently_prepared
            .complete(asset(&independently_prepared))
            .unwrap();
        assert!(original
            .validate_completed_envelope(&encode_attachment(&other, RECORD).unwrap())
            .is_err());
        assert!(original
            .validate_completed_envelope(b"not a receipt")
            .is_err());
    }

    #[tokio::test]
    async fn upload_plan_restores_exact_randomized_preparation_and_original_identity() {
        let original = plan().await;
        let encoded = original.encode().unwrap();
        let recovered = AttachmentUploadPlan::decode(&encoded).unwrap();
        assert_eq!(encoded, recovered.encode().unwrap());
        assert!(
            original.prepared.encode_v2_upload_snapshot().unwrap()
                == recovered.prepared.encode_v2_upload_snapshot().unwrap()
        );
        recovered
            .validate_origin(PARENT, &"a".repeat(64), &record())
            .unwrap();
        recovered.validate_source(Cursor::new(CONTENT)).unwrap();
        assert_eq!(recovered.record_name().unwrap(), RECORD);
        // A new preparation is NOT a valid recovery of the first upload.
        let independently_prepared = plan().await;
        assert!(original.prepared.ford_key != independently_prepared.prepared.ford_key);
        assert!(recovered.complete(asset(&independently_prepared)).is_err());
    }

    #[tokio::test]
    async fn journal_reference_reopens_committed_plan_without_discarded_length() {
        let directory = tempfile::tempdir().unwrap();
        let account = "A".repeat(43);
        let original = plan().await;
        let mut stage =
            stage_attachment_upload(directory.path().into(), account.clone(), &original).unwrap();
        let reopen = |stage: &NativeProtectedOutboundStage| {
            open_journaled_attachment_upload(
                directory.path().into(),
                account.clone(),
                &stage.logical_entity_key_hash,
                &stage.protected_payload_reference,
                &stage.payload_sha256,
                &stage.server_record_id_hash,
                &stage.lease_reference,
            )
        };
        assert!(reopen(&stage).is_err()); // Stage not durably adopted yet.
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            directory.path().into(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_payload_reference),
        )
        .unwrap();
        stage.payload_length = 0; // This field is absent from the Dart journal.
        let recovered = reopen(&stage).unwrap();
        assert_eq!(
            recovered.upload_attempt_id().unwrap(),
            original.upload_attempt_id().unwrap()
        );
        assert_eq!(recovered.encode().unwrap(), original.encode().unwrap());
        // The length-strict native stage API retains its original contract.
        assert!(open_attachment_upload(directory.path().into(), account.clone(), &stage).is_err());
        stage.payload_sha256 = "e".repeat(64);
        assert!(reopen(&stage).is_err());
    }

    #[tokio::test]
    async fn recovered_plan_feeds_exact_preparation_and_rewound_bytes_to_native_upload() {
        let original = plan().await;
        let recovered = AttachmentUploadPlan::decode(&original.encode().unwrap()).unwrap();
        let mut consumed_source = Cursor::new(CONTENT.to_vec());
        consumed_source.set_position(CONTENT.len() as u64);
        let mut input = recovered
            .native_upload_input(
                PARENT,
                &"a".repeat(64),
                &record(),
                "local-upload".to_owned(),
                recovered.upload_attempt_id().unwrap().to_owned(),
                consumed_source,
            )
            .unwrap();
        assert_eq!(input.server_record_name, RECORD);
        assert_eq!(input.reader.position(), 0);
        assert_eq!(
            input.prepared.encode_v2_upload_snapshot().unwrap(),
            original.prepared.encode_v2_upload_snapshot().unwrap()
        );
        let mut bytes = Vec::new();
        input.reader.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, CONTENT);
        assert!(recovered
            .native_upload_input(
                PARENT,
                &"a".repeat(64),
                &record(),
                "local-upload".to_owned(),
                recovered.upload_attempt_id().unwrap().to_owned(),
                Cursor::new(vec![0; CONTENT.len()]),
            )
            .is_err());
        assert!(recovered
            .native_upload_input(
                PARENT,
                &"b".repeat(64),
                &record(),
                "local-upload".to_owned(),
                recovered.upload_attempt_id().unwrap().to_owned(),
                Cursor::new(CONTENT.to_vec()),
            )
            .is_err());
    }

    #[tokio::test]
    async fn upload_plan_rejects_changed_origin_and_zone_owner() {
        let original = plan().await;
        assert!(original
            .validate_origin(RECORD, &"a".repeat(64), &record())
            .is_err());
        assert!(original
            .validate_origin(PARENT, &"b".repeat(64), &record())
            .is_err());
        let mut other = record();
        other
            .zone_identifier
            .as_mut()
            .unwrap()
            .owner_identifier
            .as_mut()
            .unwrap()
            .name = Some("another-owner".to_owned());
        assert!(original
            .validate_origin(PARENT, &"a".repeat(64), &other)
            .is_err());
        let mut wrong_zone = record();
        wrong_zone
            .zone_identifier
            .as_mut()
            .unwrap()
            .value
            .as_mut()
            .unwrap()
            .name = Some("messageManateeZone".to_owned());
        assert!(original
            .validate_origin(PARENT, &"a".repeat(64), &wrong_zone)
            .is_err());
    }

    #[tokio::test]
    async fn upload_plan_requires_exact_source_not_same_length_or_prefix() {
        let original = plan().await;
        assert!(original
            .validate_source(Cursor::new(&CONTENT[..CONTENT.len() - 1]))
            .is_err());
        assert!(original
            .validate_source(Cursor::new([CONTENT, b"x"].concat()))
            .is_err());
        assert!(original
            .validate_source(Cursor::new(vec![b'x'; CONTENT.len()]))
            .is_err());
        original.validate_source(Cursor::new(CONTENT)).unwrap();
    }

    #[tokio::test]
    async fn completed_upload_is_exact_original_material_not_record_save_proof() {
        let original = plan().await;
        let completed = original.complete(asset(&original)).unwrap();
        let bytes = encode_attachment(&completed, RECORD).unwrap();
        let (recovered, name) =
            crate::cloud_sync_outbound_attachment::decode_attachment_envelope(&bytes).unwrap();
        assert_eq!(name, RECORD);
        assert_eq!(
            recovered.lqa.upload_receipt.as_deref(),
            Some("synthetic-upload-receipt")
        );
        assert!(recovered.lqa == completed.lqa);
        assert_eq!(recovered.cm.0.guid, original.metadata.guid);
        // The pre-upload plan cannot be decoded as a completed attachment.
        assert!(
            crate::cloud_sync_outbound_attachment::decode_attachment_envelope(
                &original.encode().unwrap()
            )
            .is_err()
        );
        assert!(AttachmentUploadPlan::decode(&bytes).is_err());
    }

    #[tokio::test]
    async fn upload_result_must_bind_receipt_signature_keys_size_and_full_record_id() {
        let original = plan().await;
        let mutations: &[fn(&mut Asset)] = &[
            |a| a.upload_receipt = None,
            |a| a.upload_receipt = Some(String::new()),
            |a| a.signature.as_mut().unwrap()[1] ^= 1,
            |a| a.size = Some(0),
            |a| a.reference_signature.as_mut().unwrap()[1] ^= 1,
            |a| {
                a.protection_info
                    .as_mut()
                    .unwrap()
                    .protection_info
                    .as_mut()
                    .unwrap()[0] ^= 1
            },
            |a| a.record_id = None,
            |a| {
                a.record_id.as_mut().unwrap().value.as_mut().unwrap().name = Some(PARENT.to_owned())
            },
            |a| {
                a.record_id
                    .as_mut()
                    .unwrap()
                    .zone_identifier
                    .as_mut()
                    .unwrap()
                    .owner_identifier
                    .as_mut()
                    .unwrap()
                    .name = Some("other-owner".to_owned())
            },
        ];
        for mutate in mutations {
            let mut result = asset(&original);
            mutate(&mut result);
            assert!(original.complete(result).is_err());
        }
    }

    #[tokio::test]
    async fn upload_plan_rejects_malformed_future_and_oversized_recovery_bytes() {
        let original = plan().await;
        let encoded = original.encode().unwrap();
        let mut wire = wire::CloudSyncAttachmentUploadV1::decode(encoded.as_slice()).unwrap();
        wire.schema_version = VERSION + 1;
        assert!(AttachmentUploadPlan::decode(&wire.encode_to_vec()).is_err());
        wire.schema_version = VERSION;
        wire.prepared_put_snapshot.truncate(3);
        assert!(AttachmentUploadPlan::decode(&wire.encode_to_vec()).is_err());
        assert!(AttachmentUploadPlan::decode(&encoded[..encoded.len() - 1]).is_err());
        assert!(AttachmentUploadPlan::decode(&vec![0; MAX_PLAN_BYTES + 1]).is_err());
        let mut changed = plan().await;
        changed.metadata.total_bytes += 1;
        assert!(changed.encode().is_err());
        changed.metadata.total_bytes -= 1;
        changed.metadata.filename = Some("x".repeat(MAX_METADATA_BYTES + 1));
        assert!(changed.encode().is_err());
    }

    #[tokio::test]
    async fn upload_plan_persists_request_identity_and_rejects_replacement_attempt() {
        let original = plan().await;
        let recovered = AttachmentUploadPlan::decode(&original.encode().unwrap()).unwrap();
        assert_eq!(original.upload_identity, recovered.upload_identity);
        assert_eq!(
            original.upload_attempt_id().unwrap(),
            recovered.upload_attempt_id().unwrap()
        );
        let independent = plan().await;
        assert_ne!(original.upload_identity, independent.upload_identity);
        assert!(recovered
            .native_upload_input(
                PARENT,
                &"a".repeat(64),
                &record(),
                "local-upload".to_owned(),
                independent.upload_attempt_id().unwrap().to_owned(),
                Cursor::new(CONTENT),
            )
            .is_err());
        let bytes = original.encode().unwrap();
        let mutations: &[fn(&mut wire::CloudSyncAttachmentUploadV1)] = &[
            |wire| wire.upload_request_uuid.clear(),
            |wire| wire.upload_operation_uuid.clear(),
            |wire| wire.upload_operation_uuid = wire.upload_request_uuid.clone(),
            |wire| wire.upload_operation_uuid = "aaaaaaaa-bbbb-4ccc-8ddd-000000000001".to_owned(),
            |wire| wire.upload_request_uuid = Uuid::nil().to_string().to_uppercase(),
            |wire| wire.schema_version = 1,
        ];
        for mutate in mutations {
            let mut wire = wire::CloudSyncAttachmentUploadV1::decode(bytes.as_slice()).unwrap();
            mutate(&mut wire);
            assert!(AttachmentUploadPlan::decode(&wire.encode_to_vec()).is_err());
        }
    }

    #[tokio::test]
    async fn old_upload_plan_keeps_original_material_without_inventing_request_authority() {
        let original = plan().await;
        let mut wire =
            wire::CloudSyncAttachmentUploadV1::decode(original.encode().unwrap().as_slice())
                .unwrap();
        wire.schema_version = 1;
        wire.upload_request_uuid.clear();
        wire.upload_operation_uuid.clear();
        let bytes = wire.encode_to_vec();
        let recovered = AttachmentUploadPlan::decode(&bytes).unwrap();
        assert_eq!(recovered.encode().unwrap(), bytes);
        assert!(recovered.upload_identity.is_none());
        assert!(recovered.upload_attempt_id().is_err());
        assert!(recovered
            .native_upload_input(
                PARENT,
                &"a".repeat(64),
                &record(),
                "local-upload".to_owned(),
                original.upload_attempt_id().unwrap().to_owned(),
                Cursor::new(CONTENT),
            )
            .is_err());
        // A previously obtained matching result can still be validated and
        // recovered. Reading old state neither drops keys nor creates an upload.
        recovered.validate_source(Cursor::new(CONTENT)).unwrap();
        assert!(recovered.complete(asset(&original)).is_ok());
    }
}
