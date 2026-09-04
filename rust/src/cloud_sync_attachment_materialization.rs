//! Native-only attachment body materialization for Cloud Sync V2.
//!
//! This module accepts a durable protected raw-record capability plus the
//! journal hashes which originally bound it.  Apple record IDs, MMCS asset
//! descriptors, PCS material, temporary paths, and final cache paths never
//! cross Flutter Rust Bridge. The existing private application-support root is
//! accepted to reopen the account-bound protected store, while the private app
//! documents root is accepted only as the already-established destination used
//! by the Flutter attachment model. The only CloudKit operation used here is a
//! fetch of the already-bound attachment record followed by its MMCS GET.

use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

use futures::FutureExt as _;
use prost::Message as _;
use rustpush::{
    cloud_messages::CloudMessagesClient,
    cloudkit::{classify_cloudkit_failure, CloudKitFailureClass},
    cloudkit_operation_gate::CloudKitReadAuthenticationPermit,
    cloudkit_proto::Record,
    DefaultAnisetteProvider, PushError,
};
use sha2::{Digest as _, Sha256};

use crate::{
    cloud_sync_canonical_dto::{
        CloudCanonicalEntityKind, CloudCanonicalHash, CloudCanonicalMutation,
        CloudCanonicalMutationKind, CloudCanonicalPayload, CloudCanonicalProtectedReference,
    },
    cloud_sync_native_fetch::{
        cloud_sync_unprotect_raw_envelope, CloudNativeProtectionScope, CloudNativeStream,
    },
    cloud_sync_protector,
    cloud_sync_transient_bridge::{
        bind_envelope, cloud_sync_decode_transient_record_cached_only, CloudTransientBridgeFailure,
        CloudTransientDecodeOutcome, CloudTransientDecodeRequest, CloudTransientExpectedChangeKind,
    },
};

const MAX_ATTACHMENT_BYTES: u64 = 512 * 1024 * 1024;
const ATTACHMENT_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const ATTACHMENT_DIRECTORY_NAME: &str = ".attachment-materialization";
const NATIVE_STORE_DIRECTORY_NAME: &str = "cloud_sync_v2_native_store";
const CACHE_MANIFEST_VERSION: &str = "obcs2-attachment-cache-v1";
const MAX_CACHE_MANIFEST_BYTES: u64 = 512;
const MAX_STALE_PARTIAL_SCAN: usize = 256;
const STALE_PARTIAL_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const APP_ATTACHMENT_DIRECTORY_NAME: &str = "attachments";
const MAX_APP_ATTACHMENT_COMPONENT_BYTES: usize = 255;

static ATTACHMENT_CACHE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct AttachmentCacheFileLock {
    file: File,
}

impl AttachmentCacheFileLock {
    fn acquire(root: &Path) -> Result<Self, CloudNativeAttachmentMaterializationFailure> {
        let lock_path = root.join(".cache.lock");
        if let Ok(metadata) = fs::symlink_metadata(&lock_path) {
            if !metadata.file_type().is_file() {
                return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage);
            }
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(lock_path)
            .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
        fs2::FileExt::lock_exclusive(&file)
            .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
        Ok(Self { file })
    }
}

impl Drop for AttachmentCacheFileLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.file);
    }
}

/// Inputs are all opaque journal values or fixed metadata.  In particular,
/// this deliberately has no CloudKit asset, MMCS authorization, or path field.
pub(crate) struct CloudNativeAttachmentMaterializationRequest {
    pub(crate) storage_directory: PathBuf,
    pub(crate) application_documents_directory: PathBuf,
    pub(crate) expected_account_fingerprint: String,
    pub(crate) expected_protected_store_identity: String,
    pub(crate) generation: u64,
    pub(crate) expected_change_id: String,
    pub(crate) expected_record_id_hash: String,
    pub(crate) expected_etag_hash: String,
    pub(crate) expected_payload_sha256: String,
    pub(crate) expected_server_modified_at_millis: Option<i64>,
    pub(crate) protected_raw_envelope_reference: String,
    pub(crate) logical_entity_key_hash: String,
    pub(crate) expected_canonical_guid_sha256: String,
    pub(crate) expected_bytes: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudNativeAttachmentMaterializationFailure {
    InvalidRequest,
    ReadAuthenticationScope,
    ActiveAccountMismatch,
    StoreIdentityMismatch,
    ProtectedReferenceMismatch,
    SourceUnusable,
    PcsUnavailable,
    RetryableUpstream,
    LocalStorage,
    SizeMismatch,
    IntegrityMismatch,
    DecoderFailure,
}

pub(crate) type CloudNativeAttachmentMaterializationResult =
    Result<u64, CloudNativeAttachmentMaterializationFailure>;

#[derive(Clone)]
struct SharedFileWriter {
    state: Arc<Mutex<SharedFileWriterState>>,
}

struct SharedFileWriterState {
    file: File,
    remaining_bytes: u64,
}

impl SharedFileWriter {
    fn new(file: File, maximum_bytes: u64) -> Self {
        Self {
            state: Arc::new(Mutex::new(SharedFileWriterState {
                file,
                remaining_bytes: maximum_bytes,
            })),
        }
    }

    fn sync_all(&self) -> io::Result<()> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("attachment_writer_lock"))?
            .file
            .sync_all()
    }
}

impl Write for SharedFileWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| io::Error::other("attachment_writer_lock"))?;
        let requested = u64::try_from(buffer.len())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "attachment_size_limit"))?;
        if requested > state.remaining_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "attachment_size_limit",
            ));
        }
        let written = state.file.write(buffer)?;
        state.remaining_bytes = state
            .remaining_bytes
            .checked_sub(written as u64)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "attachment_size_limit"))?;
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("attachment_writer_lock"))?
            .file
            .flush()
    }
}

/// Deletes only the uniquely-created temporary file when a transfer fails or
/// panics before the atomic rename.  It never touches a pre-existing final
/// file.
struct TemporaryAttachmentFile {
    path: PathBuf,
    committed: bool,
}

impl TemporaryAttachmentFile {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            committed: false,
        }
    }

    fn commit(&mut self) {
        self.committed = true;
    }
}

impl Drop for TemporaryAttachmentFile {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn attachment_root(
    storage_directory: &Path,
) -> Result<PathBuf, CloudNativeAttachmentMaterializationFailure> {
    let storage_metadata = fs::symlink_metadata(storage_directory)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    if !storage_metadata.file_type().is_dir() {
        return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage);
    }
    let canonical_storage = fs::canonicalize(storage_directory)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    let native_store = canonical_storage.join(NATIVE_STORE_DIRECTORY_NAME);
    ensure_direct_child_directory(&canonical_storage, &native_store)?;
    let root = native_store.join(ATTACHMENT_DIRECTORY_NAME);
    ensure_direct_child_directory(&native_store, &root)?;
    sync_directory(&root)?;
    Ok(root)
}

fn ensure_direct_child_directory(
    canonical_parent: &Path,
    child: &Path,
) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    match fs::symlink_metadata(child) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(child)
            .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?,
        Err(_) => return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage),
    }
    let canonical_child = fs::canonicalize(child)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    if canonical_child.parent() != Some(canonical_parent) {
        return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage);
    }
    sync_directory(canonical_parent)?;
    Ok(())
}

fn validate_attachment_directory_component(
    value: &str,
) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.len() > MAX_APP_ATTACHMENT_COMPONENT_BYTES
        || value.contains(['/', '\\', '\0'])
    {
        return Err(CloudNativeAttachmentMaterializationFailure::SourceUnusable);
    }
    Ok(())
}

fn app_attachment_file_name(
    transfer_name: &str,
) -> Result<String, CloudNativeAttachmentMaterializationFailure> {
    if transfer_name.is_empty() || transfer_name.contains('\0') {
        return Err(CloudNativeAttachmentMaterializationFailure::SourceUnusable);
    }
    let sanitized = transfer_name
        .chars()
        .map(|character| {
            let invalid = character == '/'
                || (cfg!(windows)
                    && matches!(character, '<' | '>' | ':' | '"' | '\\' | '|' | '?' | '*'));
            if invalid {
                '_'
            } else {
                character
            }
        })
        .collect::<String>();
    if sanitized.is_empty()
        || sanitized == "."
        || sanitized == ".."
        || sanitized.len() > MAX_APP_ATTACHMENT_COMPONENT_BYTES
    {
        return Err(CloudNativeAttachmentMaterializationFailure::SourceUnusable);
    }
    Ok(sanitized)
}

fn ensure_app_attachment_file(
    application_documents_directory: &Path,
    canonical_guid: &str,
    transfer_name: &str,
    verified_cache_body: &Path,
    expected_bytes: u64,
) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    validate_attachment_directory_component(canonical_guid)?;
    let file_name = app_attachment_file_name(transfer_name)?;
    let canonical_documents = canonical_existing_directory(application_documents_directory)?;
    let attachments_root = canonical_documents.join(APP_ATTACHMENT_DIRECTORY_NAME);
    ensure_direct_child_directory(&canonical_documents, &attachments_root)?;
    let attachment_directory = attachments_root.join(canonical_guid);
    ensure_direct_child_directory(&attachments_root, &attachment_directory)?;
    let destination = attachment_directory.join(file_name);
    let verified_sha256 = sha256_file(verified_cache_body)?;
    if let Some(metadata) = regular_cache_file_metadata(&destination)? {
        if metadata.len() != expected_bytes || sha256_file(&destination)? != verified_sha256 {
            return Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch);
        }
        return Ok(());
    }

    let created_destination = match fs::hard_link(verified_cache_body, &destination) {
        Ok(()) => true,
        Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
            copy_app_attachment_file_without_overwrite(
                verified_cache_body,
                &destination,
                &attachment_directory,
                expected_bytes,
                &verified_sha256,
            )?
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => false,
        Err(_) => return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage),
    };
    sync_directory(&attachment_directory)?;
    let verified = regular_cache_file_metadata(&destination)?
        .is_some_and(|metadata| metadata.len() == expected_bytes)
        && sha256_file(&destination)? == verified_sha256;
    if !verified {
        // Remove only a destination this invocation proved it created. A
        // pre-existing or concurrently-created application file is never
        // overwritten or deleted.
        if created_destination {
            let _ = fs::remove_file(&destination);
            let _ = sync_directory(&attachment_directory);
        }
        return Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch);
    }
    Ok(())
}

fn copy_app_attachment_file_without_overwrite(
    verified_cache_body: &Path,
    destination: &Path,
    attachment_directory: &Path,
    expected_bytes: u64,
    verified_sha256: &str,
) -> Result<bool, CloudNativeAttachmentMaterializationFailure> {
    let temporary = attachment_directory.join(format!(
        ".obcs2-copy-{}.partial",
        verified_sha256
            .get(..32)
            .ok_or(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)?
    ));
    reclaim_source_partials(&[&temporary])?;
    let mut temporary_guard = TemporaryAttachmentFile::new(temporary.clone());
    let source = File::open(verified_cache_body)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    // The cache file was verified before this copy, but bound the copy itself
    // as well so a raced or externally-corrupted source cannot consume
    // unbounded app storage before the post-copy integrity check rejects it.
    let copy_limit = expected_bytes
        .checked_add(1)
        .ok_or(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)?;
    let mut bounded_source = source.take(copy_limit);
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    let copied = io::copy(&mut bounded_source, &mut output)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    output
        .sync_all()
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    drop(output);
    if copied != expected_bytes
        || regular_cache_file_metadata(&temporary)?
            .is_none_or(|metadata| metadata.len() != expected_bytes)
        || sha256_file(&temporary)? != verified_sha256
    {
        return Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch);
    }

    let created_destination = match fs::hard_link(&temporary, destination) {
        Ok(()) => true,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => false,
        Err(_) => return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage),
    };
    fs::remove_file(&temporary)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    temporary_guard.commit();
    sync_directory(attachment_directory)?;
    Ok(created_destination)
}

fn canonical_existing_directory(
    directory: &Path,
) -> Result<PathBuf, CloudNativeAttachmentMaterializationFailure> {
    let metadata = fs::symlink_metadata(directory)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    if !metadata.file_type().is_dir() {
        return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage);
    }
    fs::canonicalize(directory)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)
}

fn validate_request(
    request: &CloudNativeAttachmentMaterializationRequest,
) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    if request.generation == 0
        || request.expected_bytes == 0
        || request.expected_bytes > MAX_ATTACHMENT_BYTES
        || CloudCanonicalHash::new(request.logical_entity_key_hash.clone()).is_err()
        || !is_lower_hex_sha256(&request.expected_canonical_guid_sha256)
        || CloudCanonicalHash::new(request.expected_etag_hash.clone()).is_err()
        || CloudCanonicalProtectedReference::new(request.protected_raw_envelope_reference.clone())
            .is_err()
    {
        return Err(CloudNativeAttachmentMaterializationFailure::InvalidRequest);
    }
    Ok(())
}

fn map_decode_failure(
    failure: CloudTransientBridgeFailure,
) -> CloudNativeAttachmentMaterializationFailure {
    match failure {
        CloudTransientBridgeFailure::InvalidRequest
        | CloudTransientBridgeFailure::ScopeMismatch
        | CloudTransientBridgeFailure::GenerationMismatch => {
            CloudNativeAttachmentMaterializationFailure::InvalidRequest
        }
        CloudTransientBridgeFailure::ActiveAccountMismatch => {
            CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch
        }
        CloudTransientBridgeFailure::StoreIdentityMismatch => {
            CloudNativeAttachmentMaterializationFailure::StoreIdentityMismatch
        }
        CloudTransientBridgeFailure::ProtectedReferenceMismatch => {
            CloudNativeAttachmentMaterializationFailure::ProtectedReferenceMismatch
        }
        CloudTransientBridgeFailure::PcsUnavailable => {
            CloudNativeAttachmentMaterializationFailure::PcsUnavailable
        }
        CloudTransientBridgeFailure::RetryableUpstream
        | CloudTransientBridgeFailure::WarmAuthenticationRequired => {
            CloudNativeAttachmentMaterializationFailure::RetryableUpstream
        }
        CloudTransientBridgeFailure::MalformedRecord
        | CloudTransientBridgeFailure::OversizedRecord => {
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        }
        CloudTransientBridgeFailure::DecoderFailure => {
            CloudNativeAttachmentMaterializationFailure::DecoderFailure
        }
    }
}

fn require_attachment_mutation(
    outcome: CloudTransientDecodeOutcome,
) -> Result<Box<CloudCanonicalMutation>, CloudNativeAttachmentMaterializationFailure> {
    match outcome {
        CloudTransientDecodeOutcome::Ready(mutation) => Ok(mutation),
        CloudTransientDecodeOutcome::Failure(failure) => Err(map_decode_failure(failure)),
        // SMS/RCS projections, deferred records, and quarantined records are
        // never attachment capabilities. Keep every one outside the MMCS path.
        CloudTransientDecodeOutcome::OutOfScopeService(_)
        | CloudTransientDecodeOutcome::Deferred(_)
        | CloudTransientDecodeOutcome::Quarantined(_)
        | CloudTransientDecodeOutcome::QuarantinedWithDiagnostic(_, _) => {
            Err(CloudNativeAttachmentMaterializationFailure::SourceUnusable)
        }
    }
}

fn map_download_failure(error: &PushError) -> CloudNativeAttachmentMaterializationFailure {
    match error {
        PushError::UnauthorizedAccountError => {
            CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch
        }
        PushError::PCSRecordKeyMissing
        | PushError::PCSKeyIdMismatch
        | PushError::PCSDecryptionFailed
        | PushError::CloudKitWarmAuthenticationRequired
        | PushError::MasterKeyNotFound
        | PushError::NotInClique
        | PushError::ShareKeyNotFound(_)
        | PushError::NoRoutingKey => CloudNativeAttachmentMaterializationFailure::PcsUnavailable,
        PushError::RequestError(error) if error.is_timeout() || error.is_connect() => {
            CloudNativeAttachmentMaterializationFailure::RetryableUpstream
        }
        PushError::StatusError(status)
            if status.is_server_error() || status.as_u16() == 408 || status.as_u16() == 429 =>
        {
            CloudNativeAttachmentMaterializationFailure::RetryableUpstream
        }
        PushError::StatusError(status) if status.as_u16() == 401 || status.as_u16() == 403 => {
            CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch
        }
        PushError::StatusError(status) if status.is_client_error() => {
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        }
        PushError::CloudKitHttpError { status, .. }
            if *status >= 500 || *status == 408 || *status == 429 =>
        {
            CloudNativeAttachmentMaterializationFailure::RetryableUpstream
        }
        PushError::CloudKitHttpError { status, .. } if *status == 401 || *status == 403 => {
            CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch
        }
        PushError::CloudKitHttpError { status, .. } if (400..500).contains(status) => {
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        }
        PushError::CloudKitError(result) => match classify_cloudkit_failure(result) {
            CloudKitFailureClass::Throttled | CloudKitFailureClass::TransientServer => {
                CloudNativeAttachmentMaterializationFailure::RetryableUpstream
            }
            CloudKitFailureClass::Authentication => {
                CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch
            }
            CloudKitFailureClass::Conflict
            | CloudKitFailureClass::ResetRequired
            | CloudKitFailureClass::Permanent => {
                CloudNativeAttachmentMaterializationFailure::SourceUnusable
            }
            CloudKitFailureClass::Unknown => {
                CloudNativeAttachmentMaterializationFailure::DecoderFailure
            }
        },
        PushError::CloudKitChangeTokenExpired => {
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        }
        PushError::ResourceTimeout
        | PushError::ResourceGenTimeout
        | PushError::ResourceStalled
        | PushError::NotConnected
        | PushError::TooManyRequests => {
            CloudNativeAttachmentMaterializationFailure::RetryableUpstream
        }
        // The closed CloudKit/MMCS reader reports malformed or incomplete
        // server-described asset metadata as InvalidData/InvalidInput. That is
        // an unusable protected source, not a local-disk failure and must not
        // spin as though freeing local storage could repair it.
        PushError::IoError(error)
            if matches!(
                error.kind(),
                io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput
            ) =>
        {
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        }
        PushError::IoError(_) => CloudNativeAttachmentMaterializationFailure::LocalStorage,
        // A fetched attachment whose current record etag differs from the
        // protected source is intentionally terminal for this source.  A later
        // journal row may retry with the new protected record.
        PushError::VerificationFailed => {
            CloudNativeAttachmentMaterializationFailure::IntegrityMismatch
        }
        PushError::DoNotRetry(inner) => map_download_failure(inner),
        PushError::BatchError(inner) => map_download_failure(inner),
        _ => CloudNativeAttachmentMaterializationFailure::DecoderFailure,
    }
}

fn is_lower_hex_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn destination_canonical_guid_sha256(canonical_guid: &str) -> String {
    let canonical_guid_bytes = canonical_guid.as_bytes();
    let mut hasher = Sha256::new();
    hasher.update(b"cloud-attachment-canonical-guid-v1\x1f");
    hasher.update(canonical_guid_bytes.len().to_string().as_bytes());
    hasher.update(b":");
    hasher.update(canonical_guid_bytes);
    format!("{:x}", hasher.finalize())
}

fn sha256_hex_reader(mut reader: impl Read) -> Result<String, io::Error> {
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn sha256_file(path: &Path) -> Result<String, CloudNativeAttachmentMaterializationFailure> {
    let file =
        File::open(path).map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    sha256_hex_reader(file).map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)
}

fn source_version_hash(request: &CloudNativeAttachmentMaterializationRequest) -> String {
    let mut hasher = Sha256::new();
    let generation = request.generation.to_string();
    let server_modified_at = request
        .expected_server_modified_at_millis
        .map_or_else(String::new, |value| value.to_string());
    let expected_bytes = request.expected_bytes.to_string();
    for value in [
        request.expected_account_fingerprint.as_str(),
        request.expected_protected_store_identity.as_str(),
        generation.as_str(),
        request.expected_change_id.as_str(),
        request.expected_record_id_hash.as_str(),
        request.expected_etag_hash.as_str(),
        request.expected_payload_sha256.as_str(),
        server_modified_at.as_str(),
        request.protected_raw_envelope_reference.as_str(),
        request.logical_entity_key_hash.as_str(),
        request.expected_canonical_guid_sha256.as_str(),
        expected_bytes.as_str(),
    ] {
        hasher.update((value.len() as u64).to_be_bytes());
        hasher.update(value.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

fn cache_manifest(source_version_hash: &str, body_sha256: &str, expected_bytes: u64) -> String {
    format!("{CACHE_MANIFEST_VERSION}\n{source_version_hash}\n{body_sha256}\n{expected_bytes}\n")
}

fn verify_cached_body(
    body_path: &Path,
    manifest_path: &Path,
    source_version_hash: &str,
    expected_bytes: u64,
) -> Result<Option<u64>, CloudNativeAttachmentMaterializationFailure> {
    let body_metadata = regular_cache_file_metadata(body_path)?;
    let manifest_metadata = regular_cache_file_metadata(manifest_path)?;
    let (Some(body_metadata), Some(manifest_metadata)) = (body_metadata, manifest_metadata) else {
        // A process can stop between the two durable links.  An incomplete
        // pair is not reusable, but it is recoverable after a fresh MMCS body
        // has passed its chunk and size checks.
        return Ok(None);
    };
    if body_metadata.len() != expected_bytes || manifest_metadata.len() > MAX_CACHE_MANIFEST_BYTES {
        return Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch);
    }
    let manifest = fs::read_to_string(manifest_path)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)?;
    let body_sha256 = sha256_file(body_path)?;
    if manifest != cache_manifest(source_version_hash, &body_sha256, expected_bytes) {
        return Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch);
    }
    Ok(Some(expected_bytes))
}

fn regular_cache_file_metadata(
    path: &Path,
) -> Result<Option<fs::Metadata>, CloudNativeAttachmentMaterializationFailure> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => Ok(Some(metadata)),
        Ok(_) => Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(CloudNativeAttachmentMaterializationFailure::LocalStorage),
    }
}

fn remove_incomplete_cache_file(
    path: &Path,
) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    if regular_cache_file_metadata(path)?.is_some() {
        fs::remove_file(path)
            .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    }
    Ok(())
}

fn remove_completed_cache_pair(
    body: &Path,
    manifest: &Path,
) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    remove_incomplete_cache_file(body)?;
    remove_incomplete_cache_file(manifest)?;
    sync_directory(
        body.parent()
            .ok_or(CloudNativeAttachmentMaterializationFailure::LocalStorage)?,
    )
}

fn reuse_or_recover_cached_body(
    body: &Path,
    manifest: &Path,
    source_version_hash: &str,
    expected_bytes: u64,
    application_documents_directory: &Path,
    canonical_guid: &str,
    transfer_name: &str,
) -> Result<Option<u64>, CloudNativeAttachmentMaterializationFailure> {
    match verify_cached_body(body, manifest, source_version_hash, expected_bytes) {
        Ok(Some(bytes)) => {
            let placement = ensure_app_attachment_file(
                application_documents_directory,
                canonical_guid,
                transfer_name,
                body,
                expected_bytes,
            );
            let cleanup = remove_completed_cache_pair(body, manifest);
            placement?;
            cleanup?;
            Ok(Some(bytes))
        }
        Ok(None) => Ok(None),
        Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch) => {
            // This helper is called only while both native attachment-cache
            // locks are held. These paths are derived inside the confined
            // native cache root; the app attachment destination is deliberately
            // not accepted by the cleanup operation.
            remove_completed_cache_pair(body, manifest)?;
            Ok(None)
        }
        Err(failure) => Err(failure),
    }
}

fn cleanup_stale_partials(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.take(MAX_STALE_PARTIAL_SCAN).flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if !name.starts_with('.') || !name.ends_with(".partial") {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let is_stale = metadata
            .modified()
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age >= STALE_PARTIAL_AGE);
        if metadata.is_file() && is_stale {
            let _ = fs::remove_file(entry.path());
        }
    }
}

/// Completed native bodies are only a crash-recovery staging cache. The app
/// attachment path is the durable copy/link consumed by Flutter, so old cache
/// pairs must not accumulate indefinitely after interrupted invocations.
fn cleanup_stale_completed_cache(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.take(MAX_STALE_PARTIAL_SCAN).flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if name.starts_with('.') || !(name.ends_with(".body") || name.ends_with(".manifest")) {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let is_stale = metadata
            .modified()
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age >= STALE_PARTIAL_AGE);
        if metadata.is_file() && is_stale {
            let _ = fs::remove_file(entry.path());
        }
    }
}

fn reclaim_source_partials(
    paths: &[&Path],
) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    for path in paths {
        if path.exists() {
            let metadata = fs::symlink_metadata(path)
                .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
            if !metadata.file_type().is_file() {
                return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage);
            }
            fs::remove_file(path)
                .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
        }
    }
    Ok(())
}

fn verify_or_place_temp(
    temporary: &Path,
    temporary_manifest: &Path,
    final_body: &Path,
    final_manifest: &Path,
    source_version_hash: &str,
    expected_bytes: u64,
) -> Result<u64, CloudNativeAttachmentMaterializationFailure> {
    let temporary_bytes = fs::metadata(temporary)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?
        .len();
    if temporary_bytes != expected_bytes {
        return Err(CloudNativeAttachmentMaterializationFailure::SizeMismatch);
    }
    let body_sha256 = sha256_file(temporary)?;
    let manifest = cache_manifest(source_version_hash, &body_sha256, expected_bytes);
    let mut manifest_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temporary_manifest)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    manifest_file
        .write_all(manifest.as_bytes())
        .and_then(|()| manifest_file.sync_all())
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    drop(manifest_file);

    let final_body_metadata = regular_cache_file_metadata(final_body)?;
    let final_manifest_metadata = regular_cache_file_metadata(final_manifest)?;
    match (final_body_metadata, final_manifest_metadata) {
        (Some(_), Some(_)) => {
            return verify_cached_body(
                final_body,
                final_manifest,
                source_version_hash,
                expected_bytes,
            )?
            .ok_or(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)
        }
        (Some(metadata), None) => {
            // Crash recovery: the body link was made only after MMCS integrity
            // checks and fsync.  Bind it to this source only if a newly fetched
            // body is byte-for-byte identical; otherwise replace this owned,
            // uncommitted cache file.
            let matches_fresh_body =
                metadata.len() == expected_bytes && sha256_file(final_body)? == body_sha256;
            if matches_fresh_body {
                fs::hard_link(temporary_manifest, final_manifest)
                    .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
                fs::remove_file(temporary)
                    .and_then(|()| fs::remove_file(temporary_manifest))
                    .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
                sync_directory(
                    final_body
                        .parent()
                        .ok_or(CloudNativeAttachmentMaterializationFailure::LocalStorage)?,
                )?;
                return verify_cached_body(
                    final_body,
                    final_manifest,
                    source_version_hash,
                    expected_bytes,
                )?
                .ok_or(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch);
            }
            remove_incomplete_cache_file(final_body)?;
        }
        (None, Some(_)) => remove_incomplete_cache_file(final_manifest)?,
        (None, None) => {}
    }
    // `rename` replaces an existing target on Unix. A second materializer
    // could create the final file after the check above, so use a hard link in
    // the same native directory instead: it makes the completed body visible
    // atomically and never overwrites another materializer's final file.
    match fs::hard_link(temporary, final_body) {
        Ok(()) => {}
        Err(_) if final_body.exists() => {
            return verify_cached_body(
                final_body,
                final_manifest,
                source_version_hash,
                expected_bytes,
            )?
            .ok_or(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)
        }
        Err(_) => return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage),
    }
    if fs::hard_link(temporary_manifest, final_manifest).is_err() {
        let _ = fs::remove_file(final_body);
        return Err(CloudNativeAttachmentMaterializationFailure::LocalStorage);
    }
    fs::remove_file(temporary)
        .and_then(|()| fs::remove_file(temporary_manifest))
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    let parent = final_body
        .parent()
        .ok_or(CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    sync_directory(parent)?;
    verify_cached_body(
        final_body,
        final_manifest,
        source_version_hash,
        expected_bytes,
    )?
    .ok_or(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)
}

fn sync_directory(path: &Path) -> Result<(), CloudNativeAttachmentMaterializationFailure> {
    #[cfg(unix)]
    {
        File::open(path)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Materializes one attachment body.  It never calls a save, delete, zone,
/// subscription, or keychain-reset operation.
pub(crate) async fn cloud_sync_materialize_attachment_body(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    read_authentication_permit: &CloudKitReadAuthenticationPermit<'_>,
    request: CloudNativeAttachmentMaterializationRequest,
) -> CloudNativeAttachmentMaterializationResult {
    match tokio::time::timeout(
        ATTACHMENT_DOWNLOAD_TIMEOUT,
        cloud_sync_materialize_attachment_body_inner(
            cloud_messages_client,
            read_authentication_permit,
            request,
        ),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => Err(CloudNativeAttachmentMaterializationFailure::RetryableUpstream),
    }
}

async fn cloud_sync_materialize_attachment_body_inner(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    read_authentication_permit: &CloudKitReadAuthenticationPermit<'_>,
    request: CloudNativeAttachmentMaterializationRequest,
) -> CloudNativeAttachmentMaterializationResult {
    validate_request(&request)?;
    // Reject an unavailable or redirected app-documents root before any
    // CloudKit or MMCS request can start.
    let application_documents_directory =
        canonical_existing_directory(&request.application_documents_directory)?;

    let decode_request = CloudTransientDecodeRequest::new(
        request.storage_directory.clone(),
        request.expected_account_fingerprint.clone(),
        request.expected_protected_store_identity.clone(),
        "com.apple.messages.cloud".to_owned(),
        "private".to_owned(),
        "attachmentManateeZone".to_owned(),
        "messages".to_owned(),
        2,
        CloudNativeStream::Attachments,
        request.generation,
        CloudTransientExpectedChangeKind::Save,
        request.expected_change_id.clone(),
        request.expected_record_id_hash.clone(),
        Some(request.expected_etag_hash.clone()),
        request.expected_payload_sha256.clone(),
        None,
        request.expected_server_modified_at_millis,
        request.protected_raw_envelope_reference.clone(),
        None,
    )
    .map_err(map_decode_failure)?;

    let mutation = require_attachment_mutation(
        cloud_sync_decode_transient_record_cached_only(
            cloud_messages_client,
            read_authentication_permit,
            decode_request.clone(),
        )
        .await,
    )?;
    let envelope = mutation.envelope();
    if envelope.entity_kind() != CloudCanonicalEntityKind::Attachment
        || envelope.mutation_kind() != CloudCanonicalMutationKind::Upsert
        || envelope.logical_entity_key_hash().value() != request.logical_entity_key_hash
    {
        return Err(CloudNativeAttachmentMaterializationFailure::ProtectedReferenceMismatch);
    }
    // The transfer size is not Dart-authoritative. Require it to be present
    // and exactly equal in the authenticated canonical attachment projection
    // before opening a native temporary file.
    let (canonical_bytes, canonical_guid, transfer_name) = match mutation.payload() {
        Some(CloudCanonicalPayload::Attachment(payload)) => (
            payload.total_bytes().value().copied(),
            payload.canonical_guid().to_owned(),
            payload.transfer_name().value().cloned(),
        ),
        _ => (None, String::new(), None),
    };
    let canonical_bytes =
        canonical_bytes.ok_or(CloudNativeAttachmentMaterializationFailure::SourceUnusable)?;
    let transfer_name = transfer_name
        .filter(|value| !value.is_empty())
        .ok_or(CloudNativeAttachmentMaterializationFailure::SourceUnusable)?;
    if canonical_bytes != request.expected_bytes {
        return Err(CloudNativeAttachmentMaterializationFailure::SourceUnusable);
    }
    if destination_canonical_guid_sha256(&canonical_guid) != request.expected_canonical_guid_sha256
    {
        return Err(CloudNativeAttachmentMaterializationFailure::ProtectedReferenceMismatch);
    }

    // The decoder above authenticated the active account and verified every
    // journal hash.  Re-open the same protected capability only to obtain the
    // record name and source-record etag inside Rust for the MMCS fetch fence.
    let scope = CloudNativeProtectionScope::new(
        request.expected_account_fingerprint.clone(),
        CloudNativeStream::Attachments,
    )
    .map_err(|_| CloudNativeAttachmentMaterializationFailure::InvalidRequest)?;
    let source = cloud_sync_unprotect_raw_envelope(
        request.storage_directory.clone(),
        &scope,
        CloudNativeStream::Attachments,
        request.generation,
        &request.protected_raw_envelope_reference,
    )
    .map_err(|_| CloudNativeAttachmentMaterializationFailure::ProtectedReferenceMismatch)?;
    let hasher = cloud_sync_protector::semantic_identifier_hasher(
        request.storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| CloudNativeAttachmentMaterializationFailure::ProtectedReferenceMismatch)?;
    bind_envelope(&decode_request, &source, &hasher)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::ProtectedReferenceMismatch)?;
    let record_name = source
        .record_name()
        .filter(|value| !value.is_empty())
        .ok_or(CloudNativeAttachmentMaterializationFailure::SourceUnusable)?
        .to_owned();
    let source_record = Record::decode(
        source
            .raw()
            .ok_or(CloudNativeAttachmentMaterializationFailure::SourceUnusable)?,
    )
    .map_err(|_| CloudNativeAttachmentMaterializationFailure::SourceUnusable)?;
    let expected_record_etag = source_record
        .etag
        .filter(|etag| !etag.is_empty())
        .ok_or(CloudNativeAttachmentMaterializationFailure::SourceUnusable)?;

    // The transient decoder checked the fingerprint before opening the
    // protected record. Revalidate it immediately before the remote path and
    // pass the raw account identifier only between native Rust layers.
    let expected_native_account_identifier = cloud_messages_client
        .validated_native_account_identifier()
        .await
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch)?;
    let current_account_fingerprint = cloud_sync_protector::fingerprint_account(
        request.storage_directory.to_string_lossy().into_owned(),
        expected_native_account_identifier.clone(),
    )
    .map_err(|_| CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch)?;
    if current_account_fingerprint != request.expected_account_fingerprint {
        return Err(CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch);
    }

    let _cache_guard = ATTACHMENT_CACHE_LOCK.lock().await;
    let root = attachment_root(&request.storage_directory)?;
    let lock_root = root.clone();
    let _file_guard =
        tokio::task::spawn_blocking(move || AttachmentCacheFileLock::acquire(&lock_root))
            .await
            .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)??;
    cleanup_stale_partials(&root);
    cleanup_stale_completed_cache(&root);
    let source_version_hash = source_version_hash(&request);
    let cache_stem = format!(
        "{}.{}",
        request.logical_entity_key_hash, source_version_hash
    );
    let final_path = root.join(format!("{cache_stem}.body"));
    let final_manifest_path = root.join(format!("{cache_stem}.manifest"));
    if let Some(bytes) = reuse_or_recover_cached_body(
        &final_path,
        &final_manifest_path,
        &source_version_hash,
        request.expected_bytes,
        &application_documents_directory,
        &canonical_guid,
        &transfer_name,
    )? {
        return Ok(bytes);
    }

    // A single deterministic partial pair per protected source version avoids
    // accumulation after process death. The process and filesystem locks prove
    // no live materializer owns these paths when they are reclaimed.
    let temporary_path = root.join(format!(".{cache_stem}.body.partial"));
    let temporary_manifest_path = root.join(format!(".{cache_stem}.manifest.partial"));
    reclaim_source_partials(&[&temporary_path, &temporary_manifest_path])?;
    let temporary_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary_path)
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    let mut temporary_guard = TemporaryAttachmentFile::new(temporary_path.clone());
    let mut temporary_manifest_guard =
        TemporaryAttachmentFile::new(temporary_manifest_path.clone());
    // Even if malformed MMCS metadata evades an upstream size check, the
    // native destination refuses the first byte that would exceed the size
    // authenticated by the canonical attachment projection.
    let writer = SharedFileWriter::new(temporary_file, request.expected_bytes);

    // MMCS verifies every encrypted chunk before writing it. Some old MMCS
    // helpers assert on malformed transfer metadata, so contain an unexpected
    // assertion at this native boundary. The Drop guard still removes the
    // unique partial file while unwinding; Dart receives only an opaque
    // decoder failure rather than a process-level failure. This remains
    // distinct from a regular MMCS verification failure so diagnostics do not
    // mislabel an internal panic as evidence that downloaded bytes mismatched.
    let transfer = std::panic::AssertUnwindSafe(
        cloud_messages_client.download_attachment_checked_lookup_only(
            read_authentication_permit,
            &expected_native_account_identifier,
            record_name,
            expected_record_etag,
            writer.clone(),
        ),
    )
    .catch_unwind();
    match transfer.await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => return Err(map_download_failure(&error)),
        Err(_) => {
            log::warn!("Closed CloudKit attachment lookup panicked before completion");
            log::logger().flush();
            return Err(CloudNativeAttachmentMaterializationFailure::DecoderFailure);
        }
    }
    writer
        .sync_all()
        .map_err(|_| CloudNativeAttachmentMaterializationFailure::LocalStorage)?;
    drop(writer);

    let bytes = verify_or_place_temp(
        &temporary_path,
        &temporary_manifest_path,
        &final_path,
        &final_manifest_path,
        &source_version_hash,
        request.expected_bytes,
    )?;
    temporary_guard.commit();
    temporary_manifest_guard.commit();
    let placement = ensure_app_attachment_file(
        &application_documents_directory,
        &canonical_guid,
        &transfer_name,
        &final_path,
        request.expected_bytes,
    );
    let cleanup = remove_completed_cache_pair(&final_path, &final_manifest_path);
    placement?;
    cleanup?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn cloudkit_server_failure(
        code: rustpush::cloudkit_proto::response_operation::result::error::server::Code,
    ) -> PushError {
        PushError::CloudKitError(rustpush::cloudkit_proto::response_operation::Result {
            error: Some(
                rustpush::cloudkit_proto::response_operation::result::Error {
                    server_error: Some(
                        rustpush::cloudkit_proto::response_operation::result::error::Server {
                            r#type: Some(code as i32),
                        },
                    ),
                    ..Default::default()
                },
            ),
            ..Default::default()
        })
    }

    fn cloudkit_client_failure(
        code: rustpush::cloudkit_proto::response_operation::result::error::client::Code,
    ) -> PushError {
        PushError::CloudKitError(rustpush::cloudkit_proto::response_operation::Result {
            error: Some(
                rustpush::cloudkit_proto::response_operation::result::Error {
                    client_error: Some(
                        rustpush::cloudkit_proto::response_operation::result::error::Client {
                            r#type: Some(code as i32),
                        },
                    ),
                    ..Default::default()
                },
            ),
            ..Default::default()
        })
    }

    #[test]
    fn cloudkit_download_failures_keep_retry_and_auth_categories() {
        use rustpush::cloudkit_proto::response_operation::result::error::{client, server};

        assert_eq!(
            map_download_failure(&cloudkit_server_failure(server::Code::Overloaded)),
            CloudNativeAttachmentMaterializationFailure::RetryableUpstream
        );
        assert_eq!(
            map_download_failure(&cloudkit_client_failure(client::Code::NeedsAuthentication)),
            CloudNativeAttachmentMaterializationFailure::ActiveAccountMismatch
        );
        assert_eq!(
            map_download_failure(&cloudkit_server_failure(server::Code::NotFound)),
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        );
        assert_eq!(
            map_download_failure(&PushError::CloudKitError(Default::default())),
            CloudNativeAttachmentMaterializationFailure::DecoderFailure
        );
        assert_eq!(
            map_download_failure(&PushError::IoError(io::Error::new(
                io::ErrorKind::InvalidData,
                "redacted malformed asset fixture",
            ))),
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        );
        assert_eq!(
            map_download_failure(&PushError::IoError(io::Error::new(
                io::ErrorKind::InvalidInput,
                "redacted invalid asset fixture",
            ))),
            CloudNativeAttachmentMaterializationFailure::SourceUnusable
        );
        assert_eq!(
            map_download_failure(&PushError::IoError(io::Error::new(
                io::ErrorKind::WriteZero,
                "redacted local storage fixture",
            ))),
            CloudNativeAttachmentMaterializationFailure::LocalStorage
        );
    }

    #[test]
    fn out_of_scope_services_cannot_enter_attachment_materialization() {
        use crate::cloud_sync_canonical_converter::CloudCanonicalOutOfScopeService;

        assert!(matches!(
            require_attachment_mutation(CloudTransientDecodeOutcome::OutOfScopeService(
                CloudCanonicalOutOfScopeService::SmsFamily,
            )),
            Err(CloudNativeAttachmentMaterializationFailure::SourceUnusable)
        ));
    }

    #[test]
    fn request_validation_rejects_zero_byte_attachments() {
        let request = CloudNativeAttachmentMaterializationRequest {
            storage_directory: PathBuf::from("private-storage"),
            application_documents_directory: PathBuf::from("app-documents"),
            expected_account_fingerprint: "A".repeat(43),
            expected_protected_store_identity: "B".repeat(43),
            generation: 1,
            expected_change_id: "C".repeat(43),
            expected_record_id_hash: "D".repeat(43),
            expected_etag_hash: "E".repeat(43),
            expected_payload_sha256: "f".repeat(64),
            expected_server_modified_at_millis: None,
            protected_raw_envelope_reference: format!("obcs2.ref.{}", "G".repeat(43)),
            logical_entity_key_hash: "H".repeat(43),
            expected_canonical_guid_sha256: "a".repeat(64),
            expected_bytes: 0,
        };

        assert_eq!(
            validate_request(&request),
            Err(CloudNativeAttachmentMaterializationFailure::InvalidRequest)
        );
    }

    #[test]
    fn destination_guid_digest_is_domain_separated_and_utf8_length_prefixed() {
        assert_eq!(
            destination_canonical_guid_sha256("attachment-guid"),
            "6c3649d22f60dc030886b73028b97cc737a563388c2b0eb7b2c916d3ebb3235f"
        );
        assert_ne!(
            destination_canonical_guid_sha256("attachment-guid"),
            format!("{:x}", Sha256::digest(b"attachment-guid"))
        );
    }

    #[test]
    fn exact_temp_file_is_atomically_placed() {
        let directory = tempdir().unwrap();
        let temporary = directory.path().join("incoming.partial");
        let temporary_manifest = directory.path().join("incoming.manifest.partial");
        let final_path = directory.path().join("final.body");
        let final_manifest = directory.path().join("final.manifest");
        fs::write(&temporary, [1_u8, 2, 3, 4]).unwrap();

        assert_eq!(
            verify_or_place_temp(
                &temporary,
                &temporary_manifest,
                &final_path,
                &final_manifest,
                "source-version",
                4,
            ),
            Ok(4)
        );
        assert!(!temporary.exists());
        assert!(!temporary_manifest.exists());
        assert_eq!(fs::read(&final_path).unwrap(), vec![1, 2, 3, 4]);
        assert_eq!(
            verify_cached_body(&final_path, &final_manifest, "source-version", 4),
            Ok(Some(4))
        );
    }

    #[test]
    fn size_mismatch_never_creates_a_final_file() {
        let directory = tempdir().unwrap();
        let temporary = directory.path().join("incoming.partial");
        let temporary_manifest = directory.path().join("incoming.manifest.partial");
        let final_path = directory.path().join("final.body");
        let final_manifest = directory.path().join("final.manifest");
        fs::write(&temporary, [1_u8, 2, 3]).unwrap();

        assert_eq!(
            verify_or_place_temp(
                &temporary,
                &temporary_manifest,
                &final_path,
                &final_manifest,
                "source-version",
                4,
            ),
            Err(CloudNativeAttachmentMaterializationFailure::SizeMismatch)
        );
        assert!(temporary.exists());
        assert!(!final_path.exists());
    }

    #[test]
    fn crash_orphaned_body_is_rebound_only_after_a_matching_fresh_download() {
        let directory = tempdir().unwrap();
        let temporary = directory.path().join("incoming.partial");
        let temporary_manifest = directory.path().join("incoming.manifest.partial");
        let final_path = directory.path().join("final.body");
        let final_manifest = directory.path().join("final.manifest");
        fs::write(&temporary, [1_u8, 2, 3, 4]).unwrap();
        fs::write(&final_path, [1_u8, 2, 3, 4]).unwrap();

        assert_eq!(
            verify_or_place_temp(
                &temporary,
                &temporary_manifest,
                &final_path,
                &final_manifest,
                "source-version",
                4,
            ),
            Ok(4)
        );
        assert!(!temporary.exists());
        assert!(!temporary_manifest.exists());
        assert_eq!(fs::read(&final_path).unwrap(), vec![1, 2, 3, 4]);
        assert!(final_manifest.exists());
    }

    #[test]
    fn corrupt_orphaned_body_is_replaced_by_the_verified_download() {
        let directory = tempdir().unwrap();
        let temporary = directory.path().join("incoming.partial");
        let temporary_manifest = directory.path().join("incoming.manifest.partial");
        let final_path = directory.path().join("final.body");
        let final_manifest = directory.path().join("final.manifest");
        fs::write(&temporary, [1_u8, 2, 3, 4]).unwrap();
        fs::write(&final_path, [9_u8, 8, 7, 6]).unwrap();

        assert_eq!(
            verify_or_place_temp(
                &temporary,
                &temporary_manifest,
                &final_path,
                &final_manifest,
                "source-version",
                4,
            ),
            Ok(4)
        );
        assert_eq!(fs::read(&final_path).unwrap(), vec![1, 2, 3, 4]);
        assert!(final_manifest.exists());
    }

    #[test]
    fn same_sized_corrupt_body_is_rejected_by_sha256_manifest() {
        let directory = tempdir().unwrap();
        let body = directory.path().join("final.body");
        let manifest = directory.path().join("final.manifest");
        fs::write(&body, [9_u8, 8, 7, 6]).unwrap();
        fs::write(
            &manifest,
            cache_manifest(
                "source-version",
                &sha256_hex_reader([1_u8, 2, 3, 4].as_slice()).unwrap(),
                4,
            ),
        )
        .unwrap();

        assert_eq!(
            verify_cached_body(&body, &manifest, "source-version", 4),
            Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)
        );
    }

    #[test]
    fn production_cache_entry_recovers_corruption_and_accepts_a_fresh_bounded_download() {
        let directory = tempdir().unwrap();
        let body = directory.path().join("final.body");
        let manifest = directory.path().join("final.manifest");
        let temporary = directory.path().join("incoming.body.partial");
        let temporary_manifest = directory.path().join("incoming.manifest.partial");
        let documents = directory.path().join("app_flutter");
        fs::create_dir(&documents).unwrap();
        fs::write(&body, [9_u8, 8, 7, 6]).unwrap();
        fs::write(
            &manifest,
            cache_manifest(
                "source-version",
                &sha256_hex_reader([1_u8, 2, 3, 4].as_slice()).unwrap(),
                4,
            ),
        )
        .unwrap();

        assert_eq!(
            reuse_or_recover_cached_body(
                &body,
                &manifest,
                "source-version",
                4,
                &documents,
                "attachment-guid",
                "photo.jpg",
            ),
            Ok(None)
        );
        assert!(!body.exists());
        assert!(!manifest.exists());

        let temporary_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .unwrap();
        let mut writer = SharedFileWriter::new(temporary_file, 4);
        writer.write_all(&[1_u8, 2, 3, 4]).unwrap();
        writer.sync_all().unwrap();
        drop(writer);
        assert_eq!(
            verify_or_place_temp(
                &temporary,
                &temporary_manifest,
                &body,
                &manifest,
                "source-version",
                4,
            ),
            Ok(4)
        );
        ensure_app_attachment_file(&documents, "attachment-guid", "photo.jpg", &body, 4).unwrap();
        remove_completed_cache_pair(&body, &manifest).unwrap();

        let app_file = documents
            .join("attachments")
            .join("attachment-guid")
            .join("photo.jpg");
        assert_eq!(fs::read(app_file).unwrap(), vec![1, 2, 3, 4]);
        assert!(!body.exists());
        assert!(!manifest.exists());
    }

    #[test]
    fn production_cache_recovery_preserves_an_existing_app_final_target() {
        let directory = tempdir().unwrap();
        let body = directory.path().join("final.body");
        let manifest = directory.path().join("final.manifest");
        let documents = directory.path().join("app_flutter");
        let app_directory = documents.join("attachments").join("attachment-guid");
        let app_file = app_directory.join("photo.jpg");
        fs::create_dir_all(&app_directory).unwrap();
        fs::write(&app_file, [5_u8, 5, 5, 5]).unwrap();
        fs::write(&body, [9_u8, 8, 7, 6]).unwrap();
        fs::write(&manifest, b"corrupt-manifest").unwrap();

        assert_eq!(
            reuse_or_recover_cached_body(
                &body,
                &manifest,
                "source-version",
                4,
                &documents,
                "attachment-guid",
                "photo.jpg",
            ),
            Ok(None)
        );

        assert!(!body.exists());
        assert!(!manifest.exists());
        assert_eq!(fs::read(app_file).unwrap(), vec![5, 5, 5, 5]);
    }

    #[test]
    fn deterministic_source_partials_are_reclaimed_without_touching_other_files() {
        let directory = tempdir().unwrap();
        let body_partial = directory.path().join(".source.body.partial");
        let manifest_partial = directory.path().join(".source.manifest.partial");
        let unrelated = directory.path().join("message.body");
        fs::write(&body_partial, [1_u8]).unwrap();
        fs::write(&manifest_partial, [2_u8]).unwrap();
        fs::write(&unrelated, [3_u8]).unwrap();

        reclaim_source_partials(&[&body_partial, &manifest_partial]).unwrap();

        assert!(!body_partial.exists());
        assert!(!manifest_partial.exists());
        assert!(unrelated.exists());
    }

    #[test]
    fn verified_cache_body_is_linked_into_the_existing_app_attachment_path() {
        let directory = tempdir().unwrap();
        let cache_body = directory.path().join("verified.body");
        fs::write(&cache_body, [1_u8, 2, 3, 4]).unwrap();

        let documents = directory.path().join("app_flutter");
        fs::create_dir(&documents).unwrap();
        ensure_app_attachment_file(
            &documents,
            "attachment-guid",
            "folder/photo.jpg",
            &cache_body,
            4,
        )
        .unwrap();

        let app_file = documents
            .join("attachments")
            .join("attachment-guid")
            .join("folder_photo.jpg");
        assert_eq!(fs::read(app_file).unwrap(), vec![1, 2, 3, 4]);
        assert_eq!(fs::read(cache_body).unwrap(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn native_writer_refuses_the_first_byte_past_the_authenticated_size() {
        let directory = tempdir().unwrap();
        let body = directory.path().join("bounded.body");
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&body)
            .unwrap();
        let mut writer = SharedFileWriter::new(file, 3);

        writer.write_all(&[1_u8, 2, 3]).unwrap();
        assert!(writer.write_all(&[4_u8]).is_err());
        writer.sync_all().unwrap();
        drop(writer);

        assert_eq!(fs::read(body).unwrap(), vec![1, 2, 3]);
    }

    #[test]
    fn verified_copy_fallback_is_exclusive_and_preserves_existing_files() {
        let directory = tempdir().unwrap();
        let cache_body = directory.path().join("verified.body");
        fs::write(&cache_body, [1_u8, 2, 3, 4]).unwrap();
        let verified_sha256 = sha256_file(&cache_body).unwrap();
        let attachment_directory = directory.path().join("attachment-guid");
        fs::create_dir(&attachment_directory).unwrap();
        let destination = attachment_directory.join("photo.jpg");

        assert_eq!(
            copy_app_attachment_file_without_overwrite(
                &cache_body,
                &destination,
                &attachment_directory,
                4,
                &verified_sha256,
            ),
            Ok(true)
        );
        assert_eq!(fs::read(&destination).unwrap(), vec![1, 2, 3, 4]);
        assert_eq!(
            copy_app_attachment_file_without_overwrite(
                &cache_body,
                &destination,
                &attachment_directory,
                4,
                &verified_sha256,
            ),
            Ok(false)
        );
        assert_eq!(fs::read(destination).unwrap(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn verified_copy_fallback_rejects_an_oversized_raced_source() {
        let directory = tempdir().unwrap();
        let cache_body = directory.path().join("raced.body");
        fs::write(&cache_body, [1_u8, 2, 3, 4, 5, 6]).unwrap();
        let verified_sha256 = sha256_file(&cache_body).unwrap();
        let attachment_directory = directory.path().join("attachment-guid");
        fs::create_dir(&attachment_directory).unwrap();
        let destination = attachment_directory.join("photo.jpg");

        assert_eq!(
            copy_app_attachment_file_without_overwrite(
                &cache_body,
                &destination,
                &attachment_directory,
                4,
                &verified_sha256,
            ),
            Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)
        );
        assert!(!destination.exists());
        assert!(fs::read_dir(&attachment_directory)
            .unwrap()
            .next()
            .is_none());
    }

    #[test]
    fn completed_native_cache_is_removed_without_removing_the_app_link() {
        let directory = tempdir().unwrap();
        let cache_body = directory.path().join("cached.body");
        let cache_manifest = directory.path().join("cached.manifest");
        let app_body = directory.path().join("app-photo.jpg");
        fs::write(&cache_body, [1_u8, 2, 3, 4]).unwrap();
        fs::write(&cache_manifest, b"manifest").unwrap();
        fs::hard_link(&cache_body, &app_body).unwrap();

        remove_completed_cache_pair(&cache_body, &cache_manifest).unwrap();

        assert!(!cache_body.exists());
        assert!(!cache_manifest.exists());
        assert_eq!(fs::read(app_body).unwrap(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn app_attachment_path_rejects_traversal_and_preserves_existing_mismatch() {
        let directory = tempdir().unwrap();
        let documents = directory.path().join("app_flutter");
        fs::create_dir(&documents).unwrap();
        let cache_body = directory.path().join("verified.body");
        fs::write(&cache_body, [1_u8, 2, 3, 4]).unwrap();
        assert_eq!(
            ensure_app_attachment_file(&documents, "../outside", "photo.jpg", &cache_body, 4,),
            Err(CloudNativeAttachmentMaterializationFailure::SourceUnusable)
        );

        let attachment_directory = documents.join("attachments").join("attachment-guid");
        fs::create_dir_all(&attachment_directory).unwrap();
        let existing = attachment_directory.join("photo.jpg");
        fs::write(&existing, [9_u8, 8, 7, 6]).unwrap();
        assert_eq!(
            ensure_app_attachment_file(&documents, "attachment-guid", "photo.jpg", &cache_body, 4,),
            Err(CloudNativeAttachmentMaterializationFailure::IntegrityMismatch)
        );
        assert_eq!(fs::read(existing).unwrap(), vec![9, 8, 7, 6]);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_storage_root_is_rejected() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        let real = directory.path().join("real");
        let linked = directory.path().join("linked");
        fs::create_dir(&real).unwrap();
        symlink(&real, &linked).unwrap();

        assert_eq!(
            attachment_root(&linked),
            Err(CloudNativeAttachmentMaterializationFailure::LocalStorage)
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_app_documents_root_is_rejected() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        let real = directory.path().join("real-documents");
        let linked = directory.path().join("linked-documents");
        let cache_body = directory.path().join("verified.body");
        fs::create_dir(&real).unwrap();
        symlink(&real, &linked).unwrap();
        fs::write(&cache_body, [1_u8, 2, 3, 4]).unwrap();

        assert_eq!(
            ensure_app_attachment_file(&linked, "attachment-guid", "photo.jpg", &cache_body, 4,),
            Err(CloudNativeAttachmentMaterializationFailure::LocalStorage)
        );
    }
}
