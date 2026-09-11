//! Private, default-off native fetch and protection seam for Cloud Sync V2.
//!
//! Raw types from this module are intentionally absent from Flutter Rust
//! Bridge. A narrow wrapper in `api::api` exposes only content-free keyed
//! hashes, bounded lengths, fixed enums, and opaque references to
//! platform-protected local values. Raw CloudKit record names, etags, encrypted
//! records, tombstones, and continuation tokens remain native-only.

#![allow(dead_code)]

use std::{
    collections::{BTreeSet, HashSet},
    fmt::{self, Debug, Formatter},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rustpush::{
    cloud_messages::{
        CloudMessageRecordKind, CloudMessageRecordPage, CloudMessageRecordPageChange,
        CloudMessageRecordSystemFields, CloudMessagesClient,
    },
    cloudkit::{classify_cloudkit_failure, CloudKitFailureClass},
    cloudkit_operation_gate::CloudKitReadAuthenticationPermit,
    CloudKitProtocolError, DefaultAnisetteProvider, PushError,
};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    cloud_sync_canonical_dto::{
        CloudCanonicalDigest, CloudCanonicalHash, CloudCanonicalProtectedReference,
    },
    cloud_sync_protector::{self, CloudSyncProtectionError},
    cloud_sync_semantic_decoder::CloudSemanticIdentifierHasher,
};

const FETCH_DEADLINE: Duration = Duration::from_secs(40);
const MAX_CHANGES_PER_PAGE: usize = 200;
pub(crate) const MAX_RAW_RECORD_BYTES: usize = 8 * 1024 * 1024;
const MAX_RAW_PAGE_BYTES: usize = 24 * 1024 * 1024;
const MAX_CONTINUATION_TOKEN_BYTES: usize = 64 * 1024;
const MAX_METADATA_BYTES: usize = 16 * 1024;
const MAX_PROTECTED_FILE_BYTES: usize = 18 * 1024 * 1024;
const MAX_PROTECTED_PLAINTEXT_BATCH_BYTES: usize = 36 * 1024 * 1024;
const MAX_PROTECTED_CIPHERTEXT_BATCH_BYTES: usize = 48 * 1024 * 1024;
const MAX_LEASE_FILES: usize = MAX_CHANGES_PER_PAGE * 2 + 1;
const MAX_LEASE_MANIFEST_BYTES: usize = 128 * 1024;
const MAX_RECOVERY_MANIFESTS_PER_PASS: usize = 64;
const MAX_RECOVERY_TEMPORARY_FILES_PER_PASS: usize = 64;
const MAX_ADOPTED_LEASES_PER_RECOVERY: usize = 4_096;
const MAX_LIVE_REFERENCES_PER_MAINTENANCE: usize = 131_072;
const MAX_RETIRE_REFERENCES_PER_CALL: usize = 64;
const MAX_GC_REFERENCES_PER_PASS: usize = 64;
const MAX_GC_ACTIVE_MANIFESTS: usize = 4_096;
const GC_GRACE_PERIOD: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_RETRY_AFTER_SECONDS: u64 = 7 * 24 * 60 * 60;
const STORE_DIRECTORY_NAME: &str = "cloud_sync_v2_native_store";
const LEASE_DIRECTORY_NAME: &str = ".leases";
const COMMITTED_LEASE_DIRECTORY_NAME: &str = ".committed-leases";
const TEMPORARY_DIRECTORY_NAME: &str = ".temporary";
const GC_DIRECTORY_NAME: &str = ".gc";
const IDS_SEND_RECEIPT_DIRECTORY_NAME: &str = ".ids-send-receipts";
const IDS_SEND_RECEIPT_PREFIX: &str = "obcs2.ids.";
const IDS_SEND_RECEIPT_SUFFIX: &str = ".receipt";
const MAX_IDS_SEND_RECEIPTS_PER_REPLAY: usize = 64;
const MAX_IDS_SEND_RECEIPT_BYTES: u64 = 64 * 1024;
const MAX_IDS_SEND_SOURCE_PAYLOAD_BYTES: u64 = 1024 * 1024;
const IDS_SEND_RECEIPT_ID_DOMAIN: &[u8] =
    b"OpenBubbles Cloud Sync V2 IDS send receipt identity v2\0";
const GC_CURSOR_FILE_NAME: &str = ".cursor";
const RAW_ENVELOPE_MAGIC: &[u8] = b"OBCS2-NATIVE-RAW";
const CHECKPOINT_MAGIC: &[u8] = b"OBCS2-NATIVE-CHECKPOINT";
const RECORD_IDENTITY_MAGIC: &[u8] = b"OBCS2-NATIVE-RECORD-ID";
const RESET_PROOF_MAGIC: &[u8] = b"OBCS2-NATIVE-RESET-PROOF";
const FORMAT_VERSION: u16 = 1;

static PROTECTED_STORE_OPERATION_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum CloudNativeStream {
    Chats,
    Messages,
    Attachments,
    MessageUpdate,
    RecoverableMessageDelete,
    ScheduledMessage,
    Chat1,
}

impl CloudNativeStream {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "chats" => Some(Self::Chats),
            "messages" => Some(Self::Messages),
            "attachments" => Some(Self::Attachments),
            "messageUpdateZone" => Some(Self::MessageUpdate),
            "recoverableMessageDeleteZone" => Some(Self::RecoverableMessageDelete),
            "scheduledMessageZone" => Some(Self::ScheduledMessage),
            "chat1ManateeZone" => Some(Self::Chat1),
            _ => None,
        }
    }

    pub(crate) fn zone(self) -> &'static str {
        match self {
            Self::Chats => "chatManateeZone",
            Self::Messages => "messageManateeZone",
            Self::Attachments => "attachmentManateeZone",
            Self::MessageUpdate => "messageUpdateZone",
            Self::RecoverableMessageDelete => "recoverableMessageDeleteZone",
            Self::ScheduledMessage => "scheduledMessageZone",
            Self::Chat1 => "chat1ManateeZone",
        }
    }

    fn tag(self) -> u8 {
        match self {
            Self::Chats => 1,
            Self::Messages => 2,
            Self::Attachments => 3,
            Self::MessageUpdate => 4,
            Self::RecoverableMessageDelete => 5,
            Self::ScheduledMessage => 6,
            Self::Chat1 => 7,
        }
    }

    fn from_tag(value: u8) -> Option<Self> {
        match value {
            1 => Some(Self::Chats),
            2 => Some(Self::Messages),
            3 => Some(Self::Attachments),
            4 => Some(Self::MessageUpdate),
            5 => Some(Self::RecoverableMessageDelete),
            6 => Some(Self::ScheduledMessage),
            7 => Some(Self::Chat1),
            _ => None,
        }
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudNativeProtectionScope {
    account_fingerprint: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
}

impl CloudNativeProtectionScope {
    pub(crate) fn new(
        account_fingerprint: String,
        stream: CloudNativeStream,
    ) -> Result<Self, CloudNativeFetchFailure> {
        if !is_bare_digest(&account_fingerprint) {
            return Err(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::InvalidScope,
                None,
            ));
        }
        Ok(Self {
            account_fingerprint,
            container: "com.apple.messages.cloud".to_owned(),
            database: "private".to_owned(),
            zone: stream.zone().to_owned(),
            stream_kind: "messages".to_owned(),
            schema_version: 2,
        })
    }

    fn validate_for_stream(
        &self,
        stream: CloudNativeStream,
    ) -> Result<(), CloudNativeFetchFailure> {
        if !is_bare_digest(&self.account_fingerprint)
            || self.container != "com.apple.messages.cloud"
            || self.database != "private"
            || self.zone != stream.zone()
            || self.stream_kind != "messages"
            || self.schema_version != 2
        {
            return Err(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::InvalidScope,
                None,
            ));
        }
        Ok(())
    }

    pub(crate) fn binding(&self) -> String {
        [
            self.account_fingerprint.as_str(),
            self.container.as_str(),
            self.database.as_str(),
            self.zone.as_str(),
            self.stream_kind.as_str(),
            &self.schema_version.to_string(),
        ]
        .join("\u{1f}")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudNativeRawEnvelopeKind {
    EncryptedUpsert,
    Tombstone,
    UnsupportedRecordType,
    MalformedMetadata,
}

/// Native-only unprotected record envelope.
///
/// This type deliberately has no `Debug`, serde, or Flutter Rust Bridge
/// surface. It can contain raw CloudKit identifiers and encrypted record bytes
/// and must remain inside the transient native conversion boundary.
pub(crate) struct CloudNativeRawEnvelope {
    generation: u64,
    stream: CloudNativeStream,
    kind: CloudNativeRawEnvelopeKind,
    record_name: Option<String>,
    record_type: Option<String>,
    change_type: Option<i32>,
    etag: Option<String>,
    server_created_at_millis: Option<i64>,
    server_modified_at_millis: Option<i64>,
    permission: Option<u32>,
    raw_length: u64,
    raw_digest_hex: String,
    raw: Option<Vec<u8>>,
}

impl CloudNativeRawEnvelope {
    pub(crate) fn generation(&self) -> u64 {
        self.generation
    }

    pub(crate) fn stream(&self) -> CloudNativeStream {
        self.stream
    }

    pub(crate) fn kind(&self) -> CloudNativeRawEnvelopeKind {
        self.kind
    }

    pub(crate) fn record_name(&self) -> Option<&str> {
        self.record_name.as_deref()
    }

    pub(crate) fn record_type(&self) -> Option<&str> {
        self.record_type.as_deref()
    }

    pub(crate) fn change_type(&self) -> Option<i32> {
        self.change_type
    }

    pub(crate) fn etag(&self) -> Option<&str> {
        self.etag.as_deref()
    }

    pub(crate) fn server_created_at_millis(&self) -> Option<i64> {
        self.server_created_at_millis
    }

    pub(crate) fn server_modified_at_millis(&self) -> Option<i64> {
        self.server_modified_at_millis
    }

    pub(crate) fn permission(&self) -> Option<u32> {
        self.permission
    }

    pub(crate) fn raw_digest_hex(&self) -> &str {
        &self.raw_digest_hex
    }

    pub(crate) fn raw_length(&self) -> u64 {
        self.raw_length
    }

    pub(crate) fn raw(&self) -> Option<&[u8]> {
        self.raw.as_deref()
    }
}

impl Debug for CloudNativeProtectionScope {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudNativeProtectionScope(redacted)")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloudNativeProtectionPurpose {
    CheckpointToken,
    ResetProof,
    ServerRecordId,
    OutboundMessage,
    OutboundChat,
    OutboundAttachment,
    OutboundAttachmentUpload,
    IdsAttachmentSource,
    IdsMutationSource,
    IdsSendReceipt,
    RawRecord,
}

impl CloudNativeProtectionPurpose {
    fn value(self) -> &'static str {
        match self {
            Self::CheckpointToken => "checkpointToken",
            Self::ResetProof => "resetProof",
            Self::ServerRecordId => "serverRecordId",
            Self::OutboundMessage => "outboundMessage",
            Self::OutboundChat => "outboundChat",
            Self::OutboundAttachment => "outboundAttachment",
            Self::OutboundAttachmentUpload => "outboundAttachmentUpload",
            Self::IdsAttachmentSource => "idsAttachmentSource",
            Self::IdsMutationSource => "idsMutationSource",
            Self::IdsSendReceipt => "idsSendReceipt",
            Self::RawRecord => "rawRecord",
        }
    }
}

struct CloudNativePlaintext {
    purpose: CloudNativeProtectionPurpose,
    value: String,
}

impl Debug for CloudNativePlaintext {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudNativePlaintext")
            .field("purpose", &self.purpose)
            .field("length", &self.value.len())
            .finish()
    }
}

trait CloudNativeProtectedStore: Send + Sync {
    fn protect_batch(
        &self,
        scope: &CloudNativeProtectionScope,
        values: &[CloudNativePlaintext],
    ) -> Result<CloudNativeProtectedBatch, CloudNativeStoreFailure>;

    fn unprotect(
        &self,
        scope: &CloudNativeProtectionScope,
        purpose: CloudNativeProtectionPurpose,
        reference: &CloudCanonicalProtectedReference,
    ) -> Result<String, CloudNativeStoreFailure>;

    fn commit_lease(
        &self,
        lease: &CloudNativePageLease,
        retained_references: &HashSet<String>,
    ) -> Result<(), CloudNativeStoreFailure>;

    fn acknowledge_committed_lease(
        &self,
        lease: &CloudNativePageLease,
    ) -> Result<(), CloudNativeStoreFailure>;

    fn rollback_lease(&self, lease: &CloudNativePageLease) -> Result<(), CloudNativeStoreFailure>;

    fn recover_abandoned_leases(
        &self,
        adopted_lease_references: &HashSet<String>,
        live_references: &HashSet<String>,
        live_reference_enumeration_complete: bool,
    ) -> Result<CloudNativeRecoverySummary, CloudNativeStoreFailure>;

    fn retire_references(
        &self,
        references: &HashSet<String>,
    ) -> Result<usize, CloudNativeStoreFailure>;

    fn collect_garbage(
        &self,
        live_references: &HashSet<String>,
        live_reference_enumeration_complete: bool,
    ) -> Result<CloudNativeGarbageCollectionSummary, CloudNativeStoreFailure>;
}

#[derive(Clone, Eq, PartialEq)]
struct CloudNativePageLease {
    reference: CloudCanonicalProtectedReference,
}

impl Debug for CloudNativePageLease {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str("CloudNativePageLease(redacted)")
    }
}

impl CloudNativePageLease {
    fn value(&self) -> &str {
        self.reference.value()
    }

    fn parse(reference: &str) -> Result<Self, CloudNativeFetchFailure> {
        let token = reference
            .strip_prefix("obcs2.lease.")
            .filter(|token| is_lease_token(token))
            .ok_or_else(|| {
                CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::LocalStorage,
                    CloudNativeSafeCode::InvalidRequest,
                    None,
                )
            })?;
        Ok(Self {
            reference: CloudCanonicalProtectedReference::new(format!("obcs2.lease.{token}"))
                .map_err(|_| {
                    CloudNativeFetchFailure::new(
                        CloudNativeFailureCategory::LocalStorage,
                        CloudNativeSafeCode::InvalidRequest,
                        None,
                    )
                })?,
        })
    }
}

struct CloudNativeProtectedBatch {
    references: Vec<CloudCanonicalProtectedReference>,
    lease: CloudNativePageLease,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct CloudNativeRecoverySummary {
    finalized_adopted_lease_references: Vec<CloudCanonicalProtectedReference>,
    absent_adopted_lease_references: Vec<CloudCanonicalProtectedReference>,
    rolled_back: usize,
    removed_temporary_files: usize,
    has_more: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct CloudNativeGarbageCollectionSummary {
    scanned: usize,
    first_observed: usize,
    deleted: usize,
    preserved_live: usize,
    preserved_active_lease: usize,
    has_more: bool,
}

impl CloudNativeGarbageCollectionSummary {
    pub(crate) fn scanned_count(&self) -> usize {
        self.scanned
    }

    pub(crate) fn first_observed_count(&self) -> usize {
        self.first_observed
    }

    pub(crate) fn deleted_count(&self) -> usize {
        self.deleted
    }

    pub(crate) fn preserved_live_count(&self) -> usize {
        self.preserved_live
    }

    pub(crate) fn preserved_active_lease_count(&self) -> usize {
        self.preserved_active_lease
    }

    pub(crate) fn has_more(&self) -> bool {
        self.has_more
    }
}

#[derive(Clone)]
struct CloudNativeLeaseManifestEntry {
    reference: CloudCanonicalProtectedReference,
    expected_digest: String,
}

impl CloudNativeRecoverySummary {
    pub(crate) fn finalized_adopted_lease_references(&self) -> Vec<&str> {
        self.finalized_adopted_lease_references
            .iter()
            .map(CloudCanonicalProtectedReference::value)
            .collect()
    }

    pub(crate) fn has_more(&self) -> bool {
        self.has_more
    }

    pub(crate) fn rolled_back_count(&self) -> usize {
        self.rolled_back
    }

    pub(crate) fn removed_temporary_file_count(&self) -> usize {
        self.removed_temporary_files
    }

    pub(crate) fn absent_adopted_lease_references(&self) -> Vec<&str> {
        self.absent_adopted_lease_references
            .iter()
            .map(CloudCanonicalProtectedReference::value)
            .collect()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloudNativeStoreFailure {
    InvalidStorage,
    ProtectionUnavailable,
    InvalidReference,
    ContextMismatch,
    Io,
}

struct PlatformCloudNativeProtectedStore {
    storage_directory: PathBuf,
}

impl PlatformCloudNativeProtectedStore {
    pub(crate) fn new(storage_directory: PathBuf) -> Self {
        Self { storage_directory }
    }

    fn store_directory(&self) -> Result<PathBuf, CloudNativeStoreFailure> {
        if !self.storage_directory.is_dir() {
            return Err(CloudNativeStoreFailure::InvalidStorage);
        }
        Ok(self.storage_directory.join(STORE_DIRECTORY_NAME))
    }

    fn reference_path(
        &self,
        reference: &CloudCanonicalProtectedReference,
    ) -> Result<PathBuf, CloudNativeStoreFailure> {
        let token = reference
            .value()
            .strip_prefix("obcs2.ref.")
            .filter(|token| is_bare_digest(token))
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        Ok(self.store_directory()?.join(format!("{token}.protected")))
    }

    fn lease_path(&self, lease: &CloudNativePageLease) -> Result<PathBuf, CloudNativeStoreFailure> {
        let token = lease
            .reference
            .value()
            .strip_prefix("obcs2.lease.")
            .filter(|token| is_lease_token(token))
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        Ok(self
            .lease_directory()?
            .join(format!(".lease-{token}.manifest")))
    }

    fn lease_directory(&self) -> Result<PathBuf, CloudNativeStoreFailure> {
        Ok(self.store_directory()?.join(LEASE_DIRECTORY_NAME))
    }

    fn temporary_directory(&self) -> Result<PathBuf, CloudNativeStoreFailure> {
        Ok(self.store_directory()?.join(TEMPORARY_DIRECTORY_NAME))
    }

    fn committed_lease_directory(&self) -> Result<PathBuf, CloudNativeStoreFailure> {
        Ok(self.store_directory()?.join(COMMITTED_LEASE_DIRECTORY_NAME))
    }

    fn committed_lease_path(
        &self,
        lease: &CloudNativePageLease,
    ) -> Result<PathBuf, CloudNativeStoreFailure> {
        let token = lease
            .reference
            .value()
            .strip_prefix("obcs2.lease.")
            .filter(|token| is_lease_token(token))
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        Ok(self
            .committed_lease_directory()?
            .join(format!(".lease-{token}.receipt")))
    }

    fn gc_directory(&self) -> Result<PathBuf, CloudNativeStoreFailure> {
        Ok(self.store_directory()?.join(GC_DIRECTORY_NAME))
    }

    fn ids_send_receipt_directory(&self) -> Result<PathBuf, CloudNativeStoreFailure> {
        Ok(self
            .store_directory()?
            .join(IDS_SEND_RECEIPT_DIRECTORY_NAME))
    }

    fn ids_send_receipt_path(&self, receipt_id: &str) -> Result<PathBuf, CloudNativeStoreFailure> {
        let token = receipt_id
            .strip_prefix(IDS_SEND_RECEIPT_PREFIX)
            .filter(|token| is_bare_digest(token))
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        Ok(self
            .ids_send_receipt_directory()?
            .join(format!("{token}{IDS_SEND_RECEIPT_SUFFIX}")))
    }

    fn gc_candidate_path(&self, token: &str) -> Result<PathBuf, CloudNativeStoreFailure> {
        if !is_bare_digest(token) {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        Ok(self
            .gc_directory()?
            .join(format!(".candidate-{token}.mark")))
    }

    fn operation_guard() -> Result<MutexGuard<'static, ()>, CloudNativeStoreFailure> {
        PROTECTED_STORE_OPERATION_LOCK
            .lock()
            .map_err(|_| CloudNativeStoreFailure::Io)
    }

    fn lease_from_path(path: &Path) -> Result<CloudNativePageLease, CloudNativeStoreFailure> {
        let token = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix(".lease-"))
            .and_then(|name| name.strip_suffix(".manifest"))
            .filter(|token| is_lease_token(token))
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        Ok(CloudNativePageLease {
            reference: CloudCanonicalProtectedReference::new(format!("obcs2.lease.{token}"))
                .map_err(|_| CloudNativeStoreFailure::InvalidReference)?,
        })
    }

    fn committed_lease_from_path(
        path: &Path,
    ) -> Result<CloudNativePageLease, CloudNativeStoreFailure> {
        let token = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix(".lease-"))
            .and_then(|name| name.strip_suffix(".receipt"))
            .filter(|token| is_lease_token(token))
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        Ok(CloudNativePageLease {
            reference: CloudCanonicalProtectedReference::new(format!("obcs2.lease.{token}"))
                .map_err(|_| CloudNativeStoreFailure::InvalidReference)?,
        })
    }

    #[cfg(unix)]
    fn sync_directory(path: &Path) -> Result<(), CloudNativeStoreFailure> {
        File::open(path)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| CloudNativeStoreFailure::Io)
    }

    /// Windows exposes no directory-sync primitive.
    ///
    /// This previously opened the directory read-only with backup semantics and
    /// called `sync_all`, which issues `FlushFileBuffers`. That call needs write
    /// access and is not supported on a directory handle, so it always failed
    /// and took every enclosing store operation down with it. Eighteen lease and
    /// recovery tests failed on Windows for this reason alone, each reporting an
    /// opaque `Io` because the underlying error is discarded.
    ///
    /// Established practice is a no-op here rather than pretending to a
    /// guarantee the platform does not provide. Durability of a rename on
    /// Windows therefore rests on startup reconciliation, which treats the
    /// database as authoritative and repairs the staging directory against it.
    #[cfg(windows)]
    fn sync_directory(_path: &Path) -> Result<(), CloudNativeStoreFailure> {
        Ok(())
    }

    #[cfg(not(any(unix, windows)))]
    fn sync_directory(_path: &Path) -> Result<(), CloudNativeStoreFailure> {
        Err(CloudNativeStoreFailure::ProtectionUnavailable)
    }

    fn map_protection_error(error: CloudSyncProtectionError) -> CloudNativeStoreFailure {
        match error {
            CloudSyncProtectionError::ContextMismatch
            | CloudSyncProtectionError::PlatformMismatch => {
                CloudNativeStoreFailure::ContextMismatch
            }
            CloudSyncProtectionError::InvalidProtectedValue
            | CloudSyncProtectionError::UnsupportedFormat => {
                CloudNativeStoreFailure::InvalidReference
            }
            CloudSyncProtectionError::InvalidStorageDirectory
            | CloudSyncProtectionError::InvalidSecretStorage
            | CloudSyncProtectionError::MissingSecretStorage
            | CloudSyncProtectionError::SecretStorage => CloudNativeStoreFailure::InvalidStorage,
            CloudSyncProtectionError::UnsupportedPlatform
            | CloudSyncProtectionError::InvalidContext
            | CloudSyncProtectionError::KeyUnavailable => {
                CloudNativeStoreFailure::ProtectionUnavailable
            }
        }
    }

    fn protect_one(
        &self,
        scope: &CloudNativeProtectionScope,
        value: &CloudNativePlaintext,
    ) -> Result<String, CloudNativeStoreFailure> {
        cloud_sync_protector::protect(
            self.storage_directory.to_string_lossy().into_owned(),
            scope.account_fingerprint.clone(),
            scope.container.clone(),
            scope.database.clone(),
            scope.zone.clone(),
            scope.stream_kind.clone(),
            scope.schema_version,
            value.purpose.value().to_owned(),
            value.value.clone(),
        )
        .map_err(Self::map_protection_error)
    }

    fn persist_batch(
        &self,
        protected: &[String],
    ) -> Result<CloudNativeProtectedBatch, CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        if protected.is_empty() || protected.len() > MAX_LEASE_FILES {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let protected_batch_bytes = protected
            .iter()
            .try_fold(0usize, |total, value| total.checked_add(value.len()));
        if protected_batch_bytes.is_none_or(|total| total > MAX_PROTECTED_CIPHERTEXT_BATCH_BYTES) {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let store_directory = self.store_directory()?;
        let store_directory_existed = store_directory.is_dir();
        fs::create_dir_all(&store_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        if !store_directory_existed {
            Self::sync_directory(&self.storage_directory)?;
        }
        let lease_directory = self.lease_directory()?;
        let temporary_directory = self.temporary_directory()?;
        fs::create_dir_all(&lease_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        fs::create_dir_all(&temporary_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&store_directory)?;

        let lease_token = Uuid::new_v4().simple().to_string();
        let lease = CloudNativePageLease {
            reference: CloudCanonicalProtectedReference::new(format!("obcs2.lease.{lease_token}"))
                .map_err(|_| CloudNativeStoreFailure::InvalidReference)?,
        };
        let lease_path = self.lease_path(&lease)?;
        let mut prepared = Vec::with_capacity(protected.len());
        for ciphertext in protected {
            let stored = format!("OBCS2-LEASE:{lease_token}\n{ciphertext}").into_bytes();
            if ciphertext.is_empty() || stored.len() > MAX_PROTECTED_FILE_BYTES {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            // A lease-specific token prevents one unadopted page from owning
            // or deleting a blob already referenced by another page.
            let token = URL_SAFE_NO_PAD.encode(Sha256::digest(
                [lease_token.as_bytes(), b"\x1f", stored.as_slice()].concat(),
            ));
            let reference = CloudCanonicalProtectedReference::new(format!("obcs2.ref.{token}"))
                .map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
            let destination = store_directory.join(format!("{token}.protected"));
            let ciphertext_digest = sha256_hex(&stored);
            prepared.push((reference, destination, stored, ciphertext_digest));
        }

        let manifest = prepared
            .iter()
            .map(|(reference, _, _, digest)| {
                format!(
                    "{}|{}\n",
                    reference.value().trim_start_matches("obcs2.ref."),
                    digest
                )
            })
            .collect::<String>();
        if manifest.len() > MAX_LEASE_MANIFEST_BYTES {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let temporary_manifest =
            temporary_directory.join(format!(".tmp-lease-{lease_token}.manifest"));
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary_manifest)
            .and_then(|mut file| {
                file.write_all(manifest.as_bytes())?;
                file.sync_all()
            })
            .map_err(|_| CloudNativeStoreFailure::Io)?;
        fs::rename(&temporary_manifest, &lease_path).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&temporary_directory)?;
        Self::sync_directory(&lease_directory)?;

        let mut created_destinations = Vec::new();
        let mut temporary_paths = Vec::new();
        let result = (|| {
            for (_, destination, stored, _) in &prepared {
                if destination
                    .try_exists()
                    .map_err(|_| CloudNativeStoreFailure::Io)?
                {
                    // Tokens are lease-specific. Treat any existing path as a
                    // collision and never claim or remove it.
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }

                let temporary =
                    temporary_directory.join(format!(".tmp-{}.protected", Uuid::new_v4()));
                temporary_paths.push(temporary.clone());
                let mut file = OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&temporary)
                    .map_err(|_| CloudNativeStoreFailure::Io)?;
                file.write_all(stored)
                    .and_then(|_| file.sync_all())
                    .map_err(|_| CloudNativeStoreFailure::Io)?;
                fs::rename(&temporary, destination).map_err(|_| CloudNativeStoreFailure::Io)?;
                temporary_paths.retain(|path| path != &temporary);
                created_destinations.push(destination.clone());
                Self::sync_directory(&temporary_directory)?;
                Self::sync_directory(&store_directory)?;
            }
            Ok(prepared
                .iter()
                .map(|(reference, _, _, _)| reference.clone())
                .collect())
        })();

        if result.is_err() {
            for path in temporary_paths {
                let _ = fs::remove_file(path);
            }
            for path in created_destinations {
                let _ = fs::remove_file(path);
            }
            let _ = fs::remove_file(&temporary_manifest);
            let _ = fs::remove_file(&lease_path);
            let _ = Self::sync_directory(&temporary_directory);
            let _ = Self::sync_directory(&lease_directory);
            let _ = Self::sync_directory(&store_directory);
        }
        result.map(|references| CloudNativeProtectedBatch { references, lease })
    }

    fn read_lease_entries(
        &self,
        lease_path: &Path,
    ) -> Result<Vec<CloudNativeLeaseManifestEntry>, CloudNativeStoreFailure> {
        let metadata =
            fs::metadata(lease_path).map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        if metadata.len() == 0 || metadata.len() > MAX_LEASE_MANIFEST_BYTES as u64 {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let manifest = fs::read_to_string(lease_path).map_err(|_| CloudNativeStoreFailure::Io)?;
        let entries = manifest.lines().collect::<Vec<_>>();
        if entries.is_empty() || entries.len() > MAX_LEASE_FILES {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let mut parsed = Vec::with_capacity(entries.len());
        let mut unique = HashSet::with_capacity(entries.len());
        for entry in entries {
            let Some((token, expected_digest)) = entry.split_once('|') else {
                return Err(CloudNativeStoreFailure::InvalidReference);
            };
            if !is_bare_digest(token)
                || expected_digest.len() != 64
                || !expected_digest
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                || !unique.insert(token.to_owned())
            {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            parsed.push(CloudNativeLeaseManifestEntry {
                reference: CloudCanonicalProtectedReference::new(format!("obcs2.ref.{token}"))
                    .map_err(|_| CloudNativeStoreFailure::InvalidReference)?,
                expected_digest: expected_digest.to_owned(),
            });
        }
        Ok(parsed)
    }

    fn read_committed_receipt(
        &self,
        receipt_path: &Path,
    ) -> Result<Vec<CloudNativeLeaseManifestEntry>, CloudNativeStoreFailure> {
        let metadata =
            fs::metadata(receipt_path).map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        if metadata.len() == 0 || metadata.len() > MAX_LEASE_MANIFEST_BYTES as u64 {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let receipt = fs::read_to_string(receipt_path).map_err(|_| CloudNativeStoreFailure::Io)?;
        let mut lines = receipt.lines();
        if lines.next() != Some("OBCS2-COMMITTED-LEASE|1") {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let remaining = lines.collect::<Vec<_>>();
        if remaining.len() > MAX_LEASE_FILES {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let mut parsed = Vec::with_capacity(remaining.len());
        let mut unique = HashSet::with_capacity(remaining.len());
        for entry in remaining {
            let Some((token, expected_digest)) = entry.split_once('|') else {
                return Err(CloudNativeStoreFailure::InvalidReference);
            };
            if !is_bare_digest(token)
                || expected_digest.len() != 64
                || !expected_digest
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                || !unique.insert(token.to_owned())
            {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            parsed.push(CloudNativeLeaseManifestEntry {
                reference: CloudCanonicalProtectedReference::new(format!("obcs2.ref.{token}"))
                    .map_err(|_| CloudNativeStoreFailure::InvalidReference)?,
                expected_digest: expected_digest.to_owned(),
            });
        }
        Ok(parsed)
    }

    fn remove_manifest_entry_if_owned(
        &self,
        entry: &CloudNativeLeaseManifestEntry,
    ) -> Result<bool, CloudNativeStoreFailure> {
        let path = self.reference_path(&entry.reference)?;
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(_) => return Err(CloudNativeStoreFailure::Io),
        };
        // Never delete a pre-existing or replaced file. Only the exact
        // ciphertext recorded by this lease is eligible for rollback or
        // duplicate-page retirement.
        if sha256_hex(&bytes) != entry.expected_digest {
            return Ok(false);
        }
        fs::remove_file(path).map_err(|_| CloudNativeStoreFailure::Io)?;
        Ok(true)
    }

    fn cleanup_lease_manifest(&self, lease_path: &Path) -> Result<(), CloudNativeStoreFailure> {
        let entries = self.read_lease_entries(lease_path)?;
        for entry in &entries {
            self.remove_manifest_entry_if_owned(entry)?;
        }
        let store_directory = self.store_directory()?;
        fs::remove_file(lease_path).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&store_directory)?;
        Self::sync_directory(&self.lease_directory()?)
    }

    fn validate_reference_set(
        references: &HashSet<String>,
        maximum: usize,
    ) -> Result<(), CloudNativeStoreFailure> {
        if references.len() > maximum
            || references.iter().any(|reference| {
                reference
                    .strip_prefix("obcs2.ref.")
                    .is_none_or(|token| !is_bare_digest(token))
            })
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        Ok(())
    }

    fn verify_retained_entry(
        &self,
        entry: &CloudNativeLeaseManifestEntry,
    ) -> Result<(), CloudNativeStoreFailure> {
        let bytes = fs::read(self.reference_path(&entry.reference)?)
            .map_err(|_| CloudNativeStoreFailure::Io)?;
        if sha256_hex(&bytes) != entry.expected_digest {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        Ok(())
    }

    fn write_committed_receipt(
        &self,
        lease: &CloudNativePageLease,
        retained_entries: &[CloudNativeLeaseManifestEntry],
    ) -> Result<(), CloudNativeStoreFailure> {
        let committed_directory = self.committed_lease_directory()?;
        let temporary_directory = self.temporary_directory()?;
        fs::create_dir_all(&committed_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        fs::create_dir_all(&temporary_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        let receipt_path = self.committed_lease_path(lease)?;
        let mut body = String::from("OBCS2-COMMITTED-LEASE|1\n");
        for entry in retained_entries {
            body.push_str(entry.reference.value().trim_start_matches("obcs2.ref."));
            body.push('|');
            body.push_str(&entry.expected_digest);
            body.push('\n');
        }
        if body.len() > MAX_LEASE_MANIFEST_BYTES {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        if receipt_path
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            let existing = self.read_committed_receipt(&receipt_path)?;
            if !same_manifest_entries(&existing, retained_entries) {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            return Ok(());
        }
        let temporary = temporary_directory.join(format!(".tmp-commit-{}.receipt", Uuid::new_v4()));
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .and_then(|mut file| {
                file.write_all(body.as_bytes())?;
                file.sync_all()
            })
            .map_err(|_| CloudNativeStoreFailure::Io)?;
        fs::rename(&temporary, &receipt_path).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&temporary_directory)?;
        Self::sync_directory(&committed_directory)
    }

    fn commit_lease_unlocked(
        &self,
        lease: &CloudNativePageLease,
        retained_references: &HashSet<String>,
    ) -> Result<(), CloudNativeStoreFailure> {
        Self::validate_reference_set(retained_references, MAX_LEASE_FILES)?;
        let lease_path = self.lease_path(lease)?;
        let receipt_path = self.committed_lease_path(lease)?;
        if !lease_path
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            if !receipt_path
                .try_exists()
                .map_err(|_| CloudNativeStoreFailure::Io)?
            {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            let receipt = self.read_committed_receipt(&receipt_path)?;
            let receipt_references = receipt
                .iter()
                .map(|entry| entry.reference.value().to_owned())
                .collect::<HashSet<_>>();
            if &receipt_references != retained_references {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            for entry in &receipt {
                self.verify_retained_entry(entry)?;
            }
            return Ok(());
        }

        let entries = self.read_lease_entries(&lease_path)?;
        let manifest_references = entries
            .iter()
            .map(|entry| entry.reference.value().to_owned())
            .collect::<HashSet<_>>();
        if !manifest_references.is_superset(retained_references) {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let retained_entries = entries
            .iter()
            .filter(|entry| retained_references.contains(entry.reference.value()))
            .cloned()
            .collect::<Vec<_>>();
        for entry in &retained_entries {
            self.verify_retained_entry(entry)?;
        }
        for entry in entries
            .iter()
            .filter(|entry| !retained_references.contains(entry.reference.value()))
        {
            self.remove_manifest_entry_if_owned(entry)?;
        }
        self.write_committed_receipt(lease, &retained_entries)?;
        fs::remove_file(&lease_path).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&self.store_directory()?)?;
        Self::sync_directory(&self.lease_directory()?)
    }

    fn acknowledge_committed_lease_unlocked(
        &self,
        lease: &CloudNativePageLease,
    ) -> Result<(), CloudNativeStoreFailure> {
        let path = self.committed_lease_path(lease)?;
        match fs::remove_file(&path) {
            Ok(()) => Self::sync_directory(&self.committed_lease_directory()?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(CloudNativeStoreFailure::Io),
        }
    }

    fn verify_committed_lease_exact_unlocked(
        &self,
        lease: &CloudNativePageLease,
        retained_references: &HashSet<String>,
    ) -> Result<(), CloudNativeStoreFailure> {
        Self::validate_reference_set(retained_references, MAX_LEASE_FILES)?;
        if retained_references.is_empty() {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        // A receipt written before the active manifest is retired represents
        // an interrupted commit, not a lease that is safe to submit. Recovery
        // or an idempotent commit must finish that transition first.
        if self
            .lease_path(lease)?
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let receipt_path = self.committed_lease_path(lease)?;
        if !receipt_path
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let receipt = self.read_committed_receipt(&receipt_path)?;
        let receipt_references = receipt
            .iter()
            .map(|entry| entry.reference.value().to_owned())
            .collect::<HashSet<_>>();
        if &receipt_references != retained_references {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        for entry in &receipt {
            self.verify_retained_entry(entry)?;
        }
        Ok(())
    }

    fn verify_committed_lease_exact(
        &self,
        lease: &CloudNativePageLease,
        retained_references: &HashSet<String>,
    ) -> Result<(), CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        self.verify_committed_lease_exact_unlocked(lease, retained_references)
    }

    fn reference_file_matches(reference: &CloudCanonicalProtectedReference, bytes: &[u8]) -> bool {
        let Some(token) = reference.value().strip_prefix("obcs2.ref.") else {
            return false;
        };
        let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') else {
            return false;
        };
        let Ok(owner) = std::str::from_utf8(&bytes[..newline]) else {
            return false;
        };
        let Some(lease_token) = owner.strip_prefix("OBCS2-LEASE:") else {
            return false;
        };
        if !is_lease_token(lease_token) {
            return false;
        }
        URL_SAFE_NO_PAD.encode(Sha256::digest(
            [lease_token.as_bytes(), b"\x1f", bytes].concat(),
        )) == token
    }

    fn retire_references_unlocked(
        &self,
        references: &HashSet<String>,
    ) -> Result<usize, CloudNativeStoreFailure> {
        Self::validate_reference_set(references, MAX_RETIRE_REFERENCES_PER_CALL)?;
        let mut removed = 0;
        for value in references {
            let reference = CloudCanonicalProtectedReference::new(value.clone())
                .map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
            let path = self.reference_path(&reference)?;
            let bytes = match fs::read(&path) {
                Ok(bytes) => bytes,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => return Err(CloudNativeStoreFailure::Io),
            };
            if !Self::reference_file_matches(&reference, &bytes) {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            fs::remove_file(path).map_err(|_| CloudNativeStoreFailure::Io)?;
            removed += 1;
        }
        if removed > 0 {
            Self::sync_directory(&self.store_directory()?)?;
        }
        Ok(removed)
    }

    fn active_manifest_references_unlocked(
        &self,
    ) -> Result<HashSet<String>, CloudNativeStoreFailure> {
        let directory = self.lease_directory()?;
        if !directory
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            return Ok(HashSet::new());
        }
        let mut paths = Vec::new();
        for entry in fs::read_dir(&directory).map_err(|_| CloudNativeStoreFailure::Io)? {
            let path = entry.map_err(|_| CloudNativeStoreFailure::Io)?.path();
            if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(".lease-") && name.ends_with(".manifest"))
            {
                paths.push(path);
                if paths.len() > MAX_GC_ACTIVE_MANIFESTS {
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }
            }
        }
        let mut references = HashSet::new();
        for path in paths {
            for entry in self.read_lease_entries(&path)? {
                references.insert(entry.reference.value().to_owned());
                if references.len() > MAX_LIVE_REFERENCES_PER_MAINTENANCE {
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }
            }
        }
        Ok(references)
    }

    fn read_gc_cursor(&self) -> Result<Option<String>, CloudNativeStoreFailure> {
        let path = self.gc_directory()?.join(GC_CURSOR_FILE_NAME);
        let value = match fs::read_to_string(path) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(CloudNativeStoreFailure::Io),
        };
        let token = value.trim();
        if token.is_empty() {
            Ok(None)
        } else if is_bare_digest(token) {
            Ok(Some(token.to_owned()))
        } else {
            Err(CloudNativeStoreFailure::InvalidReference)
        }
    }

    fn write_gc_cursor(&self, cursor: Option<&str>) -> Result<(), CloudNativeStoreFailure> {
        let directory = self.gc_directory()?;
        let temporary_directory = self.temporary_directory()?;
        fs::create_dir_all(&directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        fs::create_dir_all(&temporary_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        let destination = directory.join(GC_CURSOR_FILE_NAME);
        let temporary = temporary_directory.join(format!(".tmp-gc-cursor-{}", Uuid::new_v4()));
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .and_then(|mut file| {
                if let Some(cursor) = cursor {
                    file.write_all(cursor.as_bytes())?;
                }
                file.write_all(b"\n")?;
                file.sync_all()
            })
            .map_err(|_| CloudNativeStoreFailure::Io)?;
        match fs::remove_file(&destination) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(CloudNativeStoreFailure::Io),
        }
        fs::rename(&temporary, &destination).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&temporary_directory)?;
        Self::sync_directory(&directory)
    }

    fn read_gc_first_seen(&self, token: &str) -> Result<Option<u64>, CloudNativeStoreFailure> {
        let path = self.gc_candidate_path(token)?;
        let value = match fs::read_to_string(path) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(CloudNativeStoreFailure::Io),
        };
        let first_seen = value
            .trim()
            .parse::<u64>()
            .map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        Ok(Some(first_seen))
    }

    fn write_gc_first_seen(
        &self,
        token: &str,
        now_seconds: u64,
    ) -> Result<(), CloudNativeStoreFailure> {
        let directory = self.gc_directory()?;
        fs::create_dir_all(&directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        let path = self.gc_candidate_path(token)?;
        match OpenOptions::new().create_new(true).write(true).open(path) {
            Ok(mut file) => {
                writeln!(file, "{now_seconds}").map_err(|_| CloudNativeStoreFailure::Io)?;
                file.sync_all().map_err(|_| CloudNativeStoreFailure::Io)?;
                Self::sync_directory(&directory)
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(_) => Err(CloudNativeStoreFailure::Io),
        }
    }

    fn clear_gc_candidate(&self, token: &str) -> Result<(), CloudNativeStoreFailure> {
        match fs::remove_file(self.gc_candidate_path(token)?) {
            Ok(()) => Self::sync_directory(&self.gc_directory()?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(CloudNativeStoreFailure::Io),
        }
    }

    fn collect_garbage_unlocked_at(
        &self,
        live_references: &HashSet<String>,
        live_reference_enumeration_complete: bool,
        now_seconds: u64,
    ) -> Result<CloudNativeGarbageCollectionSummary, CloudNativeStoreFailure> {
        if !live_reference_enumeration_complete {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        Self::validate_reference_set(live_references, MAX_LIVE_REFERENCES_PER_MAINTENANCE)?;
        let store_directory = self.store_directory()?;
        if !store_directory
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            return Ok(CloudNativeGarbageCollectionSummary::default());
        }
        let active_references = self.active_manifest_references_unlocked()?;
        let cursor = self.read_gc_cursor()?;
        // Keep only the lexicographically earliest page plus one look-ahead
        // token. Directory traversal may visit every filename, but resident
        // candidate memory and every content/delete operation stay bounded.
        let mut tokens = BTreeSet::new();
        for entry in fs::read_dir(&store_directory).map_err(|_| CloudNativeStoreFailure::Io)? {
            let path = entry.map_err(|_| CloudNativeStoreFailure::Io)?.path();
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                return Err(CloudNativeStoreFailure::InvalidReference);
            };
            let Some(token) = name.strip_suffix(".protected") else {
                continue;
            };
            if !is_bare_digest(token) {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            if cursor
                .as_ref()
                .is_some_and(|cursor| token <= cursor.as_str())
            {
                continue;
            }
            tokens.insert(token.to_owned());
            if tokens.len() > MAX_GC_REFERENCES_PER_PASS + 1 {
                let largest = tokens
                    .iter()
                    .next_back()
                    .expect("bounded token set is non-empty")
                    .clone();
                tokens.remove(&largest);
            }
        }
        let remaining = tokens
            .iter()
            .take(MAX_GC_REFERENCES_PER_PASS + 1)
            .cloned()
            .collect::<Vec<_>>();
        let has_more = remaining.len() > MAX_GC_REFERENCES_PER_PASS;
        let selected = remaining
            .into_iter()
            .take(MAX_GC_REFERENCES_PER_PASS)
            .collect::<Vec<_>>();
        let mut summary = CloudNativeGarbageCollectionSummary {
            scanned: selected.len(),
            has_more,
            ..CloudNativeGarbageCollectionSummary::default()
        };
        for token in &selected {
            let reference_value = format!("obcs2.ref.{token}");
            if live_references.contains(&reference_value) {
                self.clear_gc_candidate(token)?;
                summary.preserved_live += 1;
                continue;
            }
            if active_references.contains(&reference_value) {
                self.clear_gc_candidate(token)?;
                summary.preserved_active_lease += 1;
                continue;
            }
            let first_seen = self.read_gc_first_seen(token)?;
            if first_seen.is_none() {
                self.write_gc_first_seen(token, now_seconds)?;
                summary.first_observed += 1;
                continue;
            }
            if now_seconds.saturating_sub(first_seen.expect("checked")) < GC_GRACE_PERIOD.as_secs()
            {
                continue;
            }
            let reference = CloudCanonicalProtectedReference::new(reference_value)
                .map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
            let bytes = fs::read(self.reference_path(&reference)?)
                .map_err(|_| CloudNativeStoreFailure::Io)?;
            if !Self::reference_file_matches(&reference, &bytes) {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            // Clear the mark first. A crash before deletion then leaks the
            // blob and requires two fresh scans; deleting first could leave
            // unbounded orphan marker files after repeated crashes.
            self.clear_gc_candidate(token)?;
            fs::remove_file(self.reference_path(&reference)?)
                .map_err(|_| CloudNativeStoreFailure::Io)?;
            summary.deleted += 1;
        }
        let next_cursor = if has_more {
            selected.last().map(String::as_str)
        } else {
            None
        };
        self.write_gc_cursor(next_cursor)?;
        if summary.deleted > 0 {
            Self::sync_directory(&store_directory)?;
        }
        Ok(summary)
    }

    fn persist_ids_send_receipt(
        &self,
        receipt: &CloudNativeIdsSendReceipt,
    ) -> Result<String, CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        receipt.validate()?;
        let actual_store_identity = cloud_sync_protector::protected_store_identity(
            self.storage_directory.to_string_lossy().into_owned(),
        )
        .map_err(Self::map_protection_error)?;
        if actual_store_identity != receipt.protected_store_identity {
            return Err(CloudNativeStoreFailure::ContextMismatch);
        }
        let scope = CloudNativeProtectionScope::new(
            receipt.account_fingerprint.clone(),
            CloudNativeStream::Messages,
        )
        .map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        let protected = self.protect_one(
            &scope,
            &CloudNativePlaintext {
                purpose: CloudNativeProtectionPurpose::IdsSendReceipt,
                value: receipt.encode()?,
            },
        )?;
        if protected.is_empty() || protected.len() as u64 > MAX_IDS_SEND_RECEIPT_BYTES {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }

        let store_directory = self.store_directory()?;
        fs::create_dir_all(&store_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        // A receipt may be the first durable V2 artifact. Retry the parent
        // barrier unconditionally so an earlier create-plus-sync failure is
        // repaired before this send is reported durable.
        Self::sync_directory(&self.storage_directory)?;
        let receipt_directory = self.ids_send_receipt_directory()?;
        let temporary_directory = self.temporary_directory()?;
        fs::create_dir_all(&receipt_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        fs::create_dir_all(&temporary_directory).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&store_directory)?;

        let receipt_identity = [
            receipt.guid_hash.as_str(),
            receipt.account_fingerprint.as_str(),
            receipt.protected_store_identity.as_str(),
            receipt.native_session_id.as_str(),
        ]
        .join("\u{1f}");
        let token = cloud_sync_protector::semantic_identifier_hasher(
            self.storage_directory.to_string_lossy().into_owned(),
        )
        .map_err(Self::map_protection_error)?
        .digest(IDS_SEND_RECEIPT_ID_DOMAIN, &receipt_identity);
        let receipt_id = format!("{IDS_SEND_RECEIPT_PREFIX}{token}");
        let destination = self.ids_send_receipt_path(&receipt_id)?;
        if destination.exists() {
            let metadata = fs::metadata(&destination).map_err(|_| CloudNativeStoreFailure::Io)?;
            if metadata.len() == 0 || metadata.len() > MAX_IDS_SEND_RECEIPT_BYTES {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            let ciphertext =
                fs::read_to_string(&destination).map_err(|_| CloudNativeStoreFailure::Io)?;
            let plaintext = cloud_sync_protector::unprotect(
                self.storage_directory.to_string_lossy().into_owned(),
                scope.account_fingerprint.clone(),
                scope.container.clone(),
                scope.database.clone(),
                scope.zone.clone(),
                scope.stream_kind.clone(),
                scope.schema_version,
                CloudNativeProtectionPurpose::IdsSendReceipt
                    .value()
                    .to_owned(),
                ciphertext,
            )
            .map_err(Self::map_protection_error)?;
            let existing = CloudNativeIdsSendReceipt::decode(&plaintext)?;
            if existing.guid_hash != receipt.guid_hash
                || existing.account_fingerprint != receipt.account_fingerprint
                || existing.protected_store_identity != receipt.protected_store_identity
                || existing.native_session_id != receipt.native_session_id
                || existing.source_binding != receipt.source_binding
            {
                return Err(CloudNativeStoreFailure::ContextMismatch);
            }
            // A prior attempt may have completed the rename but failed the
            // directory barrier. Retry it before reporting idempotent success.
            Self::sync_directory(&receipt_directory)?;
            return Ok(receipt_id);
        }
        let temporary =
            temporary_directory.join(format!(".tmp-ids-send-{}.receipt", Uuid::new_v4().simple()));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|_| CloudNativeStoreFailure::Io)?;
        file.write_all(protected.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|_| CloudNativeStoreFailure::Io)?;
        fs::rename(&temporary, &destination).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&temporary_directory)?;
        Self::sync_directory(&receipt_directory)?;
        Ok(receipt_id)
    }

    fn replay_ids_send_receipts(
        &self,
        expected_account_fingerprint: &str,
        expected_protected_store_identity: &str,
        after_receipt_id: Option<&str>,
    ) -> Result<CloudNativeIdsSendReceiptReplayPage, CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        if !is_bare_digest(expected_account_fingerprint)
            || !is_protected_store_identity(expected_protected_store_identity)
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let actual_store_identity = cloud_sync_protector::protected_store_identity(
            self.storage_directory.to_string_lossy().into_owned(),
        )
        .map_err(Self::map_protection_error)?;
        if actual_store_identity != expected_protected_store_identity {
            return Ok(CloudNativeIdsSendReceiptReplayPage::empty());
        }
        let directory = self.ids_send_receipt_directory()?;
        let entries = match fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(CloudNativeIdsSendReceiptReplayPage::empty())
            }
            Err(_) => return Err(CloudNativeStoreFailure::Io),
        };
        let scope = CloudNativeProtectionScope::new(
            expected_account_fingerprint.to_owned(),
            CloudNativeStream::Messages,
        )
        .map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        let after_token = match after_receipt_id {
            Some(receipt_id) => Some(
                receipt_id
                    .strip_prefix(IDS_SEND_RECEIPT_PREFIX)
                    .filter(|token| is_bare_digest(token))
                    .ok_or(CloudNativeStoreFailure::InvalidReference)?,
            ),
            None => None,
        };
        // Enumeration is off the Flutter UI isolate. Keep its memory bounded
        // to the earliest page plus one look-ahead candidate, and keep costly
        // receipt reads/decryption bounded to one page. Invalid filenames do
        // not permanently strand later valid receipts.
        let mut paths = Vec::with_capacity(MAX_IDS_SEND_RECEIPTS_PER_REPLAY + 1);
        for entry in entries {
            let Ok(entry) = entry else { continue };
            let path = entry.path();
            let token = path
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(IDS_SEND_RECEIPT_SUFFIX));
            if !token.is_some_and(is_bare_digest)
                || after_token.is_some_and(|after| token.is_some_and(|value| value <= after))
            {
                continue;
            }
            paths.push(path);
            paths.sort();
            if paths.len() > MAX_IDS_SEND_RECEIPTS_PER_REPLAY + 1 {
                paths.pop();
            }
        }
        let has_more = paths.len() > MAX_IDS_SEND_RECEIPTS_PER_REPLAY;
        paths.truncate(MAX_IDS_SEND_RECEIPTS_PER_REPLAY);
        let next_cursor = if has_more {
            paths.last().and_then(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .and_then(|name| name.strip_suffix(IDS_SEND_RECEIPT_SUFFIX))
                    .map(|token| format!("{IDS_SEND_RECEIPT_PREFIX}{token}"))
            })
        } else {
            None
        };
        let mut receipts = Vec::new();
        for path in &paths {
            let token = path
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(IDS_SEND_RECEIPT_SUFFIX))
                .ok_or(CloudNativeStoreFailure::InvalidReference)?;
            let metadata = fs::metadata(&path).map_err(|_| CloudNativeStoreFailure::Io)?;
            if metadata.len() == 0 || metadata.len() > MAX_IDS_SEND_RECEIPT_BYTES {
                continue;
            }
            let ciphertext = match fs::read_to_string(&path) {
                Ok(value) => value,
                Err(_) => continue,
            };
            let plaintext = match cloud_sync_protector::unprotect(
                self.storage_directory.to_string_lossy().into_owned(),
                scope.account_fingerprint.clone(),
                scope.container.clone(),
                scope.database.clone(),
                scope.zone.clone(),
                scope.stream_kind.clone(),
                scope.schema_version,
                CloudNativeProtectionPurpose::IdsSendReceipt
                    .value()
                    .to_owned(),
                ciphertext,
            ) {
                Ok(value) => value,
                Err(CloudSyncProtectionError::ContextMismatch) => continue,
                Err(error) => {
                    let mapped = Self::map_protection_error(error);
                    if mapped == CloudNativeStoreFailure::InvalidReference {
                        continue;
                    }
                    return Err(mapped);
                }
            };
            let receipt = match CloudNativeIdsSendReceipt::decode(&plaintext) {
                Ok(receipt) => receipt,
                Err(_) => continue,
            };
            if receipt.account_fingerprint != expected_account_fingerprint
                || receipt.protected_store_identity != expected_protected_store_identity
            {
                continue;
            }
            receipts.push(CloudNativeIdsSendReceiptReplay {
                receipt_id: format!("{IDS_SEND_RECEIPT_PREFIX}{token}"),
                guid_hash: receipt.guid_hash,
                native_session_id: receipt.native_session_id,
                source_binding: receipt.source_binding,
            });
        }
        Ok(CloudNativeIdsSendReceiptReplayPage {
            receipts,
            next_cursor,
        })
    }

    fn acknowledge_ids_send_receipt(
        &self,
        expected: &CloudNativeIdsSendReceiptReplay,
        expected_account_fingerprint: &str,
        expected_protected_store_identity: &str,
    ) -> Result<(), CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        expected.validate()?;
        if !is_bare_digest(expected_account_fingerprint)
            || !is_protected_store_identity(expected_protected_store_identity)
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let path = self.ids_send_receipt_path(&expected.receipt_id)?;
        if !path.exists() {
            return Ok(());
        }
        let actual_store_identity = cloud_sync_protector::protected_store_identity(
            self.storage_directory.to_string_lossy().into_owned(),
        )
        .map_err(Self::map_protection_error)?;
        if actual_store_identity != expected_protected_store_identity {
            return Err(CloudNativeStoreFailure::ContextMismatch);
        }
        let metadata = fs::metadata(&path).map_err(|_| CloudNativeStoreFailure::Io)?;
        if metadata.len() == 0 || metadata.len() > MAX_IDS_SEND_RECEIPT_BYTES {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let ciphertext = fs::read_to_string(&path).map_err(|_| CloudNativeStoreFailure::Io)?;
        let scope = CloudNativeProtectionScope::new(
            expected_account_fingerprint.to_owned(),
            CloudNativeStream::Messages,
        )
        .map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        let plaintext = cloud_sync_protector::unprotect(
            self.storage_directory.to_string_lossy().into_owned(),
            scope.account_fingerprint.clone(),
            scope.container.clone(),
            scope.database.clone(),
            scope.zone.clone(),
            scope.stream_kind.clone(),
            scope.schema_version,
            CloudNativeProtectionPurpose::IdsSendReceipt
                .value()
                .to_owned(),
            ciphertext,
        )
        .map_err(Self::map_protection_error)?;
        let receipt = CloudNativeIdsSendReceipt::decode(&plaintext)?;
        if receipt.account_fingerprint != expected_account_fingerprint
            || receipt.protected_store_identity != expected_protected_store_identity
            || receipt.guid_hash != expected.guid_hash
            || receipt.native_session_id != expected.native_session_id
            || receipt.source_binding != expected.source_binding
        {
            return Err(CloudNativeStoreFailure::ContextMismatch);
        }
        fs::remove_file(&path).map_err(|_| CloudNativeStoreFailure::Io)?;
        Self::sync_directory(&self.ids_send_receipt_directory()?)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CloudNativeIdsSendSourceBinding {
    pub(crate) source_sha256: String,
    pub(crate) protected_reference: String,
    pub(crate) lease_reference: String,
    pub(crate) payload_sha256: String,
    pub(crate) payload_length: u64,
}

impl CloudNativeIdsSendSourceBinding {
    // Keep the native seam's DTOs non-serializable. Only these content-free
    // receipt fields have an explicit, versioned persistence representation.
    fn receipt_value(&self) -> serde_json::Value {
        serde_json::json!({
            "source_sha256": self.source_sha256,
            "protected_reference": self.protected_reference,
            "lease_reference": self.lease_reference,
            "payload_sha256": self.payload_sha256,
            "payload_length": self.payload_length,
        })
    }

    fn from_receipt_value(value: &serde_json::Value) -> Result<Self, CloudNativeStoreFailure> {
        let object = value.as_object().filter(|object| object.len() == 5)
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        let string = |key: &str| object.get(key).and_then(serde_json::Value::as_str)
            .map(str::to_owned).ok_or(CloudNativeStoreFailure::InvalidReference);
        let binding = Self {
            source_sha256: string("source_sha256")?,
            protected_reference: string("protected_reference")?,
            lease_reference: string("lease_reference")?,
            payload_sha256: string("payload_sha256")?,
            payload_length: object.get("payload_length").and_then(serde_json::Value::as_u64)
                .ok_or(CloudNativeStoreFailure::InvalidReference)?,
        };
        binding.validate()?;
        Ok(binding)
    }

    fn validate(&self) -> Result<(), CloudNativeStoreFailure> {
        if !is_hex_digest(&self.source_sha256)
            || !is_hex_digest(&self.payload_sha256)
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let protected_token = self
            .protected_reference
            .strip_prefix("obcs2.ref.")
            .filter(|token| is_bare_digest(token));
        if protected_token.is_none() {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let lease_token = self
            .lease_reference
            .strip_prefix("obcs2.lease.")
            .filter(|token| is_lease_token(token));
        if lease_token.is_none() {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        if self.payload_length == 0
            || self.payload_length > MAX_IDS_SEND_SOURCE_PAYLOAD_BYTES
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        Ok(())
    }
}

pub(crate) struct CloudNativeIdsSendReceipt {
    pub(crate) guid_hash: String,
    pub(crate) account_fingerprint: String,
    pub(crate) protected_store_identity: String,
    pub(crate) native_session_id: String,
    pub(crate) source_binding: Option<CloudNativeIdsSendSourceBinding>,
}

impl CloudNativeIdsSendReceipt {
    fn validate(&self) -> Result<(), CloudNativeStoreFailure> {
        if !is_hex_digest(&self.guid_hash)
            || !is_bare_digest(&self.account_fingerprint)
            || !is_protected_store_identity(&self.protected_store_identity)
            || !is_bare_digest(&self.native_session_id)
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        if let Some(binding) = &self.source_binding {
            binding.validate()?;
        }
        Ok(())
    }

    fn encode(&self) -> Result<String, CloudNativeStoreFailure> {
        self.validate()?;
        if let Some(binding) = &self.source_binding {
            Ok(serde_json::json!({
                "version": 3,
                "guidHash": self.guid_hash,
                "accountFingerprint": self.account_fingerprint,
                "protectedStoreIdentity": self.protected_store_identity,
                "nativeSessionId": self.native_session_id,
                "sourceBinding": binding.receipt_value(),
            })
            .to_string())
        } else {
            Ok(serde_json::json!({
                "version": 2,
                "guidHash": self.guid_hash,
                "accountFingerprint": self.account_fingerprint,
                "protectedStoreIdentity": self.protected_store_identity,
                "nativeSessionId": self.native_session_id,
            })
            .to_string())
        }
    }

    fn decode(value: &str) -> Result<Self, CloudNativeStoreFailure> {
        let value: serde_json::Value =
            serde_json::from_str(value).map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        let object = value
            .as_object()
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        // Version 1 certified SendJob completion, which also included no-op
        // sends and failed recipient progress. Retain it as legacy evidence,
        // but do not replay it as positive participant acceptance.
        match object.get("version").and_then(serde_json::Value::as_u64) {
            Some(2) => {
                if object.len() != 5 || object.contains_key("sourceBinding") {
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }
                let receipt = Self {
                    guid_hash: object
                        .get("guidHash")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    account_fingerprint: object
                        .get("accountFingerprint")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    protected_store_identity: object
                        .get("protectedStoreIdentity")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    native_session_id: object
                        .get("nativeSessionId")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    source_binding: None,
                };
                receipt.validate()?;
                Ok(receipt)
            }
            Some(3) => {
                if object.len() != 6 {
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }
                let binding_value = object
                    .get("sourceBinding")
                    .ok_or(CloudNativeStoreFailure::InvalidReference)?;
                let source_binding = CloudNativeIdsSendSourceBinding::from_receipt_value(binding_value)?;
                let receipt = Self {
                    guid_hash: object
                        .get("guidHash")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    account_fingerprint: object
                        .get("accountFingerprint")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    protected_store_identity: object
                        .get("protectedStoreIdentity")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    native_session_id: object
                        .get("nativeSessionId")
                        .and_then(serde_json::Value::as_str)
                        .ok_or(CloudNativeStoreFailure::InvalidReference)?
                        .to_owned(),
                    source_binding: Some(source_binding),
                };
                receipt.validate()?;
                Ok(receipt)
            }
            _ => Err(CloudNativeStoreFailure::InvalidReference),
        }
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudNativeIdsSendReceiptReplay {
    pub(crate) receipt_id: String,
    pub(crate) guid_hash: String,
    pub(crate) native_session_id: String,
    pub(crate) source_binding: Option<CloudNativeIdsSendSourceBinding>,
}

pub(crate) struct CloudNativeIdsSendReceiptReplayPage {
    pub(crate) receipts: Vec<CloudNativeIdsSendReceiptReplay>,
    pub(crate) next_cursor: Option<String>,
}

impl CloudNativeIdsSendReceiptReplayPage {
    fn empty() -> Self {
        Self {
            receipts: Vec::new(),
            next_cursor: None,
        }
    }
}

impl CloudNativeIdsSendReceiptReplay {
    fn validate(&self) -> Result<(), CloudNativeStoreFailure> {
        let token = self
            .receipt_id
            .strip_prefix(IDS_SEND_RECEIPT_PREFIX)
            .filter(|token| is_bare_digest(token));
        if token.is_none()
            || !is_hex_digest(&self.guid_hash)
            || !is_bare_digest(&self.native_session_id)
        {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        if let Some(binding) = &self.source_binding {
            binding.validate()?;
        }
        Ok(())
    }
}

fn same_manifest_entries(
    left: &[CloudNativeLeaseManifestEntry],
    right: &[CloudNativeLeaseManifestEntry],
) -> bool {
    let to_set = |entries: &[CloudNativeLeaseManifestEntry]| {
        entries
            .iter()
            .map(|entry| {
                (
                    entry.reference.value().to_owned(),
                    entry.expected_digest.clone(),
                )
            })
            .collect::<HashSet<_>>()
    };
    to_set(left) == to_set(right)
}

impl CloudNativeProtectedStore for PlatformCloudNativeProtectedStore {
    fn protect_batch(
        &self,
        scope: &CloudNativeProtectionScope,
        values: &[CloudNativePlaintext],
    ) -> Result<CloudNativeProtectedBatch, CloudNativeStoreFailure> {
        // Platform protection is completed for the entire page before the
        // first durable reference is made visible.
        let protected = values
            .iter()
            .map(|value| self.protect_one(scope, value))
            .collect::<Result<Vec<_>, _>>()?;
        self.persist_batch(&protected)
    }

    fn unprotect(
        &self,
        scope: &CloudNativeProtectionScope,
        purpose: CloudNativeProtectionPurpose,
        reference: &CloudCanonicalProtectedReference,
    ) -> Result<String, CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        let path = self.reference_path(reference)?;
        let metadata =
            fs::metadata(&path).map_err(|_| CloudNativeStoreFailure::InvalidReference)?;
        if metadata.len() == 0 || metadata.len() > MAX_PROTECTED_FILE_BYTES as u64 {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        let mut ciphertext = String::new();
        File::open(path)
            .and_then(|mut file| file.read_to_string(&mut ciphertext))
            .map_err(|_| CloudNativeStoreFailure::Io)?;
        let ciphertext = ciphertext
            .split_once('\n')
            .filter(|(owner, ciphertext)| {
                owner
                    .strip_prefix("OBCS2-LEASE:")
                    .is_some_and(|token| is_lease_token(token))
                    && !ciphertext.is_empty()
            })
            .map(|(_, ciphertext)| ciphertext.to_owned())
            .ok_or(CloudNativeStoreFailure::InvalidReference)?;
        cloud_sync_protector::unprotect(
            self.storage_directory.to_string_lossy().into_owned(),
            scope.account_fingerprint.clone(),
            scope.container.clone(),
            scope.database.clone(),
            scope.zone.clone(),
            scope.stream_kind.clone(),
            scope.schema_version,
            purpose.value().to_owned(),
            ciphertext,
        )
        .map_err(Self::map_protection_error)
    }

    fn commit_lease(
        &self,
        lease: &CloudNativePageLease,
        retained_references: &HashSet<String>,
    ) -> Result<(), CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        self.commit_lease_unlocked(lease, retained_references)
    }

    fn acknowledge_committed_lease(
        &self,
        lease: &CloudNativePageLease,
    ) -> Result<(), CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        self.acknowledge_committed_lease_unlocked(lease)
    }

    fn rollback_lease(&self, lease: &CloudNativePageLease) -> Result<(), CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        let lease_path = self.lease_path(lease)?;
        if !lease_path
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            return Ok(());
        }
        self.cleanup_lease_manifest(&lease_path)
    }

    fn recover_abandoned_leases(
        &self,
        adopted_lease_references: &HashSet<String>,
        live_references: &HashSet<String>,
        live_reference_enumeration_complete: bool,
    ) -> Result<CloudNativeRecoverySummary, CloudNativeStoreFailure> {
        if !live_reference_enumeration_complete {
            return Err(CloudNativeStoreFailure::InvalidReference);
        }
        Self::validate_reference_set(live_references, MAX_LIVE_REFERENCES_PER_MAINTENANCE)?;
        let _guard = Self::operation_guard()?;
        let store_directory = self.store_directory()?;
        if !store_directory
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            return Ok(CloudNativeRecoverySummary {
                absent_adopted_lease_references: adopted_lease_references
                    .iter()
                    .map(|reference| {
                        CloudCanonicalProtectedReference::new(reference.clone())
                            .map_err(|_| CloudNativeStoreFailure::InvalidReference)
                    })
                    .collect::<Result<Vec<_>, _>>()?,
                ..CloudNativeRecoverySummary::default()
            });
        }
        let lease_directory = self.lease_directory()?;
        let temporary_directory = self.temporary_directory()?;
        let mut lease_paths = Vec::with_capacity(MAX_RECOVERY_MANIFESTS_PER_PASS + 1);
        if lease_directory
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            for entry in fs::read_dir(&lease_directory).map_err(|_| CloudNativeStoreFailure::Io)? {
                let path = entry.map_err(|_| CloudNativeStoreFailure::Io)?.path();
                if path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".lease-") && name.ends_with(".manifest"))
                {
                    lease_paths.push(path);
                    if lease_paths.len() > MAX_RECOVERY_MANIFESTS_PER_PASS {
                        break;
                    }
                }
            }
        }
        lease_paths.sort();
        let has_more_manifests = lease_paths.len() > MAX_RECOVERY_MANIFESTS_PER_PASS;
        lease_paths.truncate(MAX_RECOVERY_MANIFESTS_PER_PASS);
        let mut temporary_paths = Vec::with_capacity(MAX_RECOVERY_TEMPORARY_FILES_PER_PASS + 1);
        if temporary_directory
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            for entry in
                fs::read_dir(&temporary_directory).map_err(|_| CloudNativeStoreFailure::Io)?
            {
                let path = entry.map_err(|_| CloudNativeStoreFailure::Io)?.path();
                if path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".tmp-"))
                {
                    temporary_paths.push(path);
                    if temporary_paths.len() > MAX_RECOVERY_TEMPORARY_FILES_PER_PASS {
                        break;
                    }
                }
            }
        }
        temporary_paths.sort();
        let has_more_temporary = temporary_paths.len() > MAX_RECOVERY_TEMPORARY_FILES_PER_PASS;
        temporary_paths.truncate(MAX_RECOVERY_TEMPORARY_FILES_PER_PASS);
        for path in &temporary_paths {
            fs::remove_file(path).map_err(|_| CloudNativeStoreFailure::Io)?;
        }
        if !temporary_paths.is_empty() {
            Self::sync_directory(&temporary_directory)?;
        }
        let committed_directory = self.committed_lease_directory()?;
        let mut receipt_paths = Vec::with_capacity(MAX_RECOVERY_MANIFESTS_PER_PASS + 1);
        if committed_directory
            .try_exists()
            .map_err(|_| CloudNativeStoreFailure::Io)?
        {
            let remaining_capacity =
                MAX_RECOVERY_MANIFESTS_PER_PASS.saturating_sub(lease_paths.len());
            for entry in
                fs::read_dir(&committed_directory).map_err(|_| CloudNativeStoreFailure::Io)?
            {
                let path = entry.map_err(|_| CloudNativeStoreFailure::Io)?.path();
                if path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".lease-") && name.ends_with(".receipt"))
                {
                    receipt_paths.push(path);
                    if receipt_paths.len() > remaining_capacity {
                        break;
                    }
                }
            }
        }
        receipt_paths.sort();
        let has_more_receipts =
            lease_paths.len() + receipt_paths.len() > MAX_RECOVERY_MANIFESTS_PER_PASS;
        receipt_paths.truncate(MAX_RECOVERY_MANIFESTS_PER_PASS.saturating_sub(lease_paths.len()));
        let has_more = has_more_manifests || has_more_temporary || has_more_receipts;
        let manifest_lease_references = lease_paths
            .iter()
            .map(|path| Self::lease_from_path(path))
            .collect::<Result<Vec<_>, _>>()?;
        let receipt_lease_references = receipt_paths
            .iter()
            .map(|path| Self::committed_lease_from_path(path))
            .collect::<Result<Vec<_>, _>>()?;
        let mut summary = CloudNativeRecoverySummary {
            has_more,
            removed_temporary_files: temporary_paths.len(),
            ..CloudNativeRecoverySummary::default()
        };
        for (path, lease) in lease_paths
            .into_iter()
            .zip(manifest_lease_references.iter().cloned())
        {
            if adopted_lease_references.contains(lease.reference.value()) {
                let retained = self
                    .read_lease_entries(&path)?
                    .into_iter()
                    .map(|entry| entry.reference.value().to_owned())
                    .filter(|reference| live_references.contains(reference))
                    .collect::<HashSet<_>>();
                self.commit_lease_unlocked(&lease, &retained)?;
                summary
                    .finalized_adopted_lease_references
                    .push(lease.reference);
            } else {
                if self
                    .read_lease_entries(&path)?
                    .iter()
                    .any(|entry| live_references.contains(entry.reference.value()))
                {
                    // ObjectBox journal rows and their adoption marker are one
                    // transaction. A live reference without that marker
                    // violates the contract; fail closed instead of rolling
                    // back data that ObjectBox still names.
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }
                self.cleanup_lease_manifest(&path)?;
                summary.rolled_back += 1;
            }
        }
        for (path, lease) in receipt_paths
            .into_iter()
            .zip(receipt_lease_references.iter().cloned())
        {
            if adopted_lease_references.contains(lease.reference.value()) {
                // A crash after the durable receipt rename but before active
                // manifest removal can leave both files. The manifest branch
                // above finishes that commit; do not report the same lease
                // twice through the safe bridge result.
                if summary
                    .finalized_adopted_lease_references
                    .iter()
                    .any(|reference| reference.value() == lease.reference.value())
                {
                    continue;
                }
                let receipt = self.read_committed_receipt(&path)?;
                let retained = receipt
                    .iter()
                    .map(|entry| entry.reference.value().to_owned())
                    .collect::<HashSet<_>>();
                if !live_references.is_superset(&retained) {
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }
                self.commit_lease_unlocked(&lease, &retained)?;
                summary
                    .finalized_adopted_lease_references
                    .push(lease.reference);
            } else {
                fs::remove_file(&path).map_err(|_| CloudNativeStoreFailure::Io)?;
                Self::sync_directory(&committed_directory)?;
            }
        }
        if !has_more {
            let present = manifest_lease_references
                .iter()
                .chain(receipt_lease_references.iter())
                .map(|lease| lease.reference.value())
                .collect::<HashSet<_>>();
            summary.absent_adopted_lease_references = adopted_lease_references
                .iter()
                .filter(|reference| !present.contains(reference.as_str()))
                .map(|reference| {
                    CloudCanonicalProtectedReference::new(reference.clone())
                        .map_err(|_| CloudNativeStoreFailure::InvalidReference)
                })
                .collect::<Result<Vec<_>, _>>()?;
            summary
                .absent_adopted_lease_references
                .sort_by(|left, right| left.value().cmp(right.value()));
        }
        Ok(summary)
    }

    fn retire_references(
        &self,
        references: &HashSet<String>,
    ) -> Result<usize, CloudNativeStoreFailure> {
        let _guard = Self::operation_guard()?;
        self.retire_references_unlocked(references)
    }

    fn collect_garbage(
        &self,
        live_references: &HashSet<String>,
        live_reference_enumeration_complete: bool,
    ) -> Result<CloudNativeGarbageCollectionSummary, CloudNativeStoreFailure> {
        let now_seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| CloudNativeStoreFailure::Io)?
            .as_secs();
        let _guard = Self::operation_guard()?;
        self.collect_garbage_unlocked_at(
            live_references,
            live_reference_enumeration_complete,
            now_seconds,
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudNativeChangeKind {
    Save,
    Delete,
    Quarantined,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudNativePreflightCode {
    UnsupportedRecordType,
    MalformedMetadata,
    OversizedRecord,
    InvalidChangeShape,
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudNativeProtectedChange {
    change_id: CloudCanonicalHash,
    record_id_hash: CloudCanonicalHash,
    etag_hash: Option<CloudCanonicalHash>,
    kind: CloudNativeChangeKind,
    payload_digest: CloudCanonicalDigest,
    payload_length: u64,
    protected_record_identity_reference: CloudCanonicalProtectedReference,
    protected_raw_envelope_reference: CloudCanonicalProtectedReference,
    server_modified_at_millis: Option<i64>,
    preflight_code: Option<CloudNativePreflightCode>,
    is_tombstone: bool,
}

impl Debug for CloudNativeProtectedChange {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudNativeProtectedChange")
            .field("kind", &self.kind)
            .field("payload_length", &self.payload_length)
            .field("preflight_code", &self.preflight_code)
            .finish_non_exhaustive()
    }
}

impl CloudNativeProtectedChange {
    pub(crate) fn change_id(&self) -> &str {
        self.change_id.value()
    }

    pub(crate) fn record_id_hash(&self) -> &str {
        self.record_id_hash.value()
    }

    pub(crate) fn etag_hash(&self) -> Option<&str> {
        self.etag_hash.as_ref().map(CloudCanonicalHash::value)
    }

    pub(crate) fn protected_record_identity_reference(&self) -> &str {
        self.protected_record_identity_reference.value()
    }

    pub(crate) fn protected_raw_envelope_reference(&self) -> &str {
        self.protected_raw_envelope_reference.value()
    }

    pub(crate) fn kind(&self) -> CloudNativeChangeKind {
        self.kind
    }

    pub(crate) fn payload_digest(&self) -> &str {
        self.payload_digest.value()
    }

    pub(crate) fn payload_length(&self) -> u64 {
        self.payload_length
    }

    pub(crate) fn server_modified_at_millis(&self) -> Option<i64> {
        self.server_modified_at_millis
    }

    pub(crate) fn preflight_code(&self) -> Option<CloudNativePreflightCode> {
        self.preflight_code
    }

    pub(crate) fn is_tombstone(&self) -> bool {
        self.is_tombstone
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudNativeProtectedPage {
    changes: Vec<CloudNativeProtectedChange>,
    batch_id: CloudCanonicalHash,
    generation: u64,
    page_lease: CloudNativePageLease,
    protected_next_checkpoint_reference: Option<CloudCanonicalProtectedReference>,
    status: i32,
    complete: bool,
    admitted_raw_bytes: u64,
}

impl Debug for CloudNativeProtectedPage {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudNativeProtectedPage")
            .field("change_count", &self.changes.len())
            .field("generation", &self.generation)
            .field("has_page_lease", &true)
            .field("status", &self.status)
            .field("complete", &self.complete)
            .field("admitted_raw_bytes", &self.admitted_raw_bytes)
            .finish()
    }
}

impl CloudNativeProtectedPage {
    pub(crate) fn page_lease_reference(&self) -> &str {
        self.page_lease.value()
    }

    pub(crate) fn changes(&self) -> &[CloudNativeProtectedChange] {
        &self.changes
    }

    pub(crate) fn batch_id(&self) -> &str {
        self.batch_id.value()
    }

    pub(crate) fn generation(&self) -> u64 {
        self.generation
    }

    pub(crate) fn protected_next_checkpoint_reference(&self) -> Option<&str> {
        self.protected_next_checkpoint_reference
            .as_ref()
            .map(CloudCanonicalProtectedReference::value)
    }

    pub(crate) fn status(&self) -> i32 {
        self.status
    }

    pub(crate) fn complete(&self) -> bool {
        self.complete
    }

    pub(crate) fn admitted_raw_bytes(&self) -> u64 {
        self.admitted_raw_bytes
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudNativeFailureCategory {
    Network,
    Throttled,
    Server,
    Authorization,
    PcsUnavailable,
    MalformedRecord,
    Conflict,
    LocalStorage,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudNativeSafeCode {
    InvalidScope,
    InvalidRequest,
    InvalidCheckpoint,
    CheckpointContextMismatch,
    OversizedPage,
    OversizedRecord,
    ProtectionFailed,
    LocalStoreFailed,
    FetchDeadline,
    Network,
    CloudKitThrottled,
    CloudKitServer,
    CloudKitAuthorization,
    CloudKitConflict,
    CloudKitResetRequired,
    CloudKitPermanent,
    CloudKitUnknown,
    HttpAuthorization,
    HttpTimeout,
    HttpThrottled,
    HttpServer,
    HttpUnknown,
    PcsUnavailable,
    MalformedResponse,
    ContinuationNoProgress,
    ReadAuthenticationScope,
    NativeAuthUnavailable,
    Unknown,
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CloudNativeFetchFailure {
    category: CloudNativeFailureCategory,
    safe_code: CloudNativeSafeCode,
    retry_after_seconds: Option<u64>,
    protected_reset_proof_reference: Option<CloudCanonicalProtectedReference>,
}

impl CloudNativeFetchFailure {
    fn new(
        category: CloudNativeFailureCategory,
        safe_code: CloudNativeSafeCode,
        retry_after_seconds: Option<u64>,
    ) -> Self {
        Self {
            category,
            safe_code,
            retry_after_seconds,
            protected_reset_proof_reference: None,
        }
    }

    pub(crate) fn category(&self) -> CloudNativeFailureCategory {
        self.category
    }

    pub(crate) fn safe_code(&self) -> CloudNativeSafeCode {
        self.safe_code
    }

    pub(crate) fn retry_after_seconds(&self) -> Option<u64> {
        self.retry_after_seconds
    }

    pub(crate) fn protected_reset_proof_reference(&self) -> Option<&str> {
        self.protected_reset_proof_reference
            .as_ref()
            .map(CloudCanonicalProtectedReference::value)
    }
}

impl Debug for CloudNativeFetchFailure {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudNativeFetchFailure")
            .field("category", &self.category)
            .field("safe_code", &self.safe_code)
            .field("retry_after_seconds", &self.retry_after_seconds)
            .field(
                "has_protected_reset_proof",
                &self.protected_reset_proof_reference.is_some(),
            )
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) enum CloudNativeProtectedFetchOutcome {
    Page(CloudNativeProtectedPage),
    Failure(CloudNativeFetchFailure),
}

impl Debug for CloudNativeProtectedFetchOutcome {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Self::Page(page) => page.fmt(formatter),
            Self::Failure(failure) => failure.fmt(formatter),
        }
    }
}

pub(crate) struct CloudNativeFetchRequest<'a> {
    stream: CloudNativeStream,
    scope: &'a CloudNativeProtectionScope,
    generation: u64,
    previous_checkpoint_reference: Option<&'a str>,
    maximum_changes: u32,
}

impl<'a> CloudNativeFetchRequest<'a> {
    pub(crate) fn new(
        stream: CloudNativeStream,
        scope: &'a CloudNativeProtectionScope,
        generation: u64,
        previous_checkpoint_reference: Option<&'a str>,
        maximum_changes: u32,
    ) -> Self {
        Self {
            stream,
            scope,
            generation,
            previous_checkpoint_reference,
            maximum_changes,
        }
    }
}

impl Debug for CloudNativeFetchRequest<'_> {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudNativeFetchRequest")
            .field("stream", &self.stream)
            .field("generation", &self.generation)
            .field("maximum_changes", &self.maximum_changes)
            .field(
                "has_previous_checkpoint",
                &self.previous_checkpoint_reference.is_some(),
            )
            .finish()
    }
}

fn is_bare_digest(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn is_hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_protected_store_identity(value: &str) -> bool {
    value
        .strip_prefix("obcs2.store.")
        .is_some_and(is_bare_digest)
}

fn is_lease_token(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn append_bytes(target: &mut Vec<u8>, value: &[u8]) -> Result<(), CloudNativeFetchFailure> {
    let length = u32::try_from(value.len()).map_err(|_| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::OversizedRecord,
            None,
        )
    })?;
    target.extend_from_slice(&length.to_be_bytes());
    target.extend_from_slice(value);
    Ok(())
}

fn append_optional_bytes(
    target: &mut Vec<u8>,
    value: Option<&[u8]>,
) -> Result<(), CloudNativeFetchFailure> {
    match value {
        Some(value) => {
            target.push(1);
            append_bytes(target, value)
        }
        None => {
            target.push(0);
            Ok(())
        }
    }
}

fn append_optional_string(
    target: &mut Vec<u8>,
    value: Option<&str>,
) -> Result<(), CloudNativeFetchFailure> {
    append_optional_bytes(target, value.map(str::as_bytes))
}

fn append_optional_i32(target: &mut Vec<u8>, value: Option<i32>) {
    match value {
        Some(value) => {
            target.push(1);
            target.extend_from_slice(&value.to_be_bytes());
        }
        None => target.push(0),
    }
}

fn append_optional_u32(target: &mut Vec<u8>, value: Option<u32>) {
    match value {
        Some(value) => {
            target.push(1);
            target.extend_from_slice(&value.to_be_bytes());
        }
        None => target.push(0),
    }
}

fn append_optional_f64(target: &mut Vec<u8>, value: Option<f64>) {
    match value {
        Some(value) => {
            target.push(1);
            target.extend_from_slice(&value.to_bits().to_be_bytes());
        }
        None => target.push(0),
    }
}

fn encode_record_identity(
    generation: u64,
    stream: CloudNativeStream,
    record_name: Option<&str>,
) -> Result<String, CloudNativeFetchFailure> {
    let mut encoded = Vec::with_capacity(128 + record_name.map_or(0, str::len));
    encoded.extend_from_slice(RECORD_IDENTITY_MAGIC);
    encoded.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    encoded.extend_from_slice(&generation.to_be_bytes());
    encoded.push(stream.tag());
    append_optional_string(&mut encoded, record_name)?;
    Ok(URL_SAFE_NO_PAD.encode(encoded))
}

fn encode_raw_envelope(
    generation: u64,
    stream: CloudNativeStream,
    change: &CloudMessageRecordPageChange,
    raw: &[u8],
    preserve_raw: bool,
) -> Result<String, CloudNativeFetchFailure> {
    let system = change.system_fields.as_ref();
    let mut encoded = Vec::with_capacity(
        256 + change.record_name.as_ref().map_or(0, String::len)
            + change.record_type.as_ref().map_or(0, String::len)
            + system
                .and_then(|fields| fields.etag.as_ref())
                .map_or(0, String::len)
            + if preserve_raw { raw.len() } else { 0 },
    );
    encoded.extend_from_slice(RAW_ENVELOPE_MAGIC);
    encoded.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    encoded.extend_from_slice(&generation.to_be_bytes());
    encoded.push(stream.tag());
    encoded.push(match change.kind {
        CloudMessageRecordKind::EncryptedUpsert => 1,
        CloudMessageRecordKind::Tombstone => 2,
        CloudMessageRecordKind::UnsupportedRecordType => 3,
        CloudMessageRecordKind::MalformedMetadata => 4,
    });
    append_optional_string(&mut encoded, change.record_name.as_deref())?;
    append_optional_string(&mut encoded, change.record_type.as_deref())?;
    append_optional_i32(&mut encoded, change.change_type);
    append_optional_string(
        &mut encoded,
        system.and_then(|fields| fields.etag.as_deref()),
    )?;
    append_optional_f64(&mut encoded, system.and_then(|fields| fields.created_at));
    append_optional_f64(&mut encoded, system.and_then(|fields| fields.modified_at));
    append_optional_u32(&mut encoded, system.and_then(|fields| fields.permission));
    encoded.extend_from_slice(&(raw.len() as u64).to_be_bytes());
    encoded.extend_from_slice(&Sha256::digest(raw));
    append_optional_bytes(&mut encoded, preserve_raw.then_some(raw))?;
    Ok(URL_SAFE_NO_PAD.encode(encoded))
}

fn encode_checkpoint(
    generation: u64,
    stream: CloudNativeStream,
    token: &[u8],
) -> Result<String, CloudNativeFetchFailure> {
    if token.len() > MAX_CONTINUATION_TOKEN_BYTES {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidCheckpoint,
            None,
        ));
    }
    let mut encoded = Vec::with_capacity(CHECKPOINT_MAGIC.len() + token.len() + 32);
    encoded.extend_from_slice(CHECKPOINT_MAGIC);
    encoded.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    encoded.extend_from_slice(&generation.to_be_bytes());
    encoded.push(stream.tag());
    append_bytes(&mut encoded, token)?;
    Ok(URL_SAFE_NO_PAD.encode(encoded))
}

struct NativeByteCursor<'a> {
    value: &'a [u8],
    offset: usize,
}

impl<'a> NativeByteCursor<'a> {
    fn new(value: &'a [u8]) -> Self {
        Self { value, offset: 0 }
    }

    fn take(&mut self, length: usize) -> Option<&'a [u8]> {
        let end = self.offset.checked_add(length)?;
        let result = self.value.get(self.offset..end)?;
        self.offset = end;
        Some(result)
    }

    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_be_bytes(self.take(2)?.try_into().ok()?))
    }

    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_be_bytes(self.take(8)?.try_into().ok()?))
    }

    fn byte(&mut self) -> Option<u8> {
        self.take(1).map(|value| value[0])
    }

    fn bytes(&mut self, maximum: usize) -> Option<Vec<u8>> {
        let length = u32::from_be_bytes(self.take(4)?.try_into().ok()?) as usize;
        if length > maximum {
            return None;
        }
        Some(self.take(length)?.to_vec())
    }

    fn optional_bytes(&mut self, maximum: usize) -> Option<Option<Vec<u8>>> {
        match self.byte()? {
            0 => Some(None),
            1 => self.bytes(maximum).map(Some),
            _ => None,
        }
    }

    fn optional_string(&mut self, maximum: usize) -> Option<Option<String>> {
        self.optional_bytes(maximum)?
            .map(String::from_utf8)
            .transpose()
            .ok()
    }

    fn optional_i32(&mut self) -> Option<Option<i32>> {
        match self.byte()? {
            0 => Some(None),
            1 => Some(Some(i32::from_be_bytes(self.take(4)?.try_into().ok()?))),
            _ => None,
        }
    }

    fn optional_u32(&mut self) -> Option<Option<u32>> {
        match self.byte()? {
            0 => Some(None),
            1 => Some(Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))),
            _ => None,
        }
    }

    fn optional_f64(&mut self) -> Option<Option<f64>> {
        match self.byte()? {
            0 => Some(None),
            1 => Some(Some(f64::from_bits(u64::from_be_bytes(
                self.take(8)?.try_into().ok()?,
            )))),
            _ => None,
        }
    }

    fn finished(&self) -> bool {
        self.offset == self.value.len()
    }
}

fn seconds_to_millis(value: Option<f64>) -> Option<Option<i64>> {
    match value {
        Some(seconds) => {
            if !seconds.is_finite() {
                return None;
            }
            let millis = seconds * 1_000.0;
            if millis < i64::MIN as f64 || millis > i64::MAX as f64 {
                return None;
            }
            Some(Some(millis.round() as i64))
        }
        None => Some(None),
    }
}

fn decode_raw_envelope(
    encoded: &str,
    expected_generation: u64,
    expected_stream: CloudNativeStream,
) -> Result<CloudNativeRawEnvelope, CloudNativeFetchFailure> {
    if encoded.len() > MAX_PROTECTED_FILE_BYTES {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::OversizedRecord,
            None,
        ));
    }
    let bytes = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    if bytes.len() > MAX_PROTECTED_FILE_BYTES {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::OversizedRecord,
            None,
        ));
    }
    let mut cursor = NativeByteCursor::new(&bytes);
    if cursor.take(RAW_ENVELOPE_MAGIC.len()) != Some(RAW_ENVELOPE_MAGIC)
        || cursor.u16() != Some(FORMAT_VERSION)
    {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        ));
    }
    let generation = cursor.u64().ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let stream = cursor
        .byte()
        .and_then(CloudNativeStream::from_tag)
        .ok_or_else(|| {
            CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::MalformedResponse,
                None,
            )
        })?;
    if generation != expected_generation || stream != expected_stream {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::CheckpointContextMismatch,
            None,
        ));
    }
    let kind = match cursor.byte() {
        Some(1) => CloudNativeRawEnvelopeKind::EncryptedUpsert,
        Some(2) => CloudNativeRawEnvelopeKind::Tombstone,
        Some(3) => CloudNativeRawEnvelopeKind::UnsupportedRecordType,
        Some(4) => CloudNativeRawEnvelopeKind::MalformedMetadata,
        _ => {
            return Err(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::MalformedResponse,
                None,
            ))
        }
    };
    let record_name = cursor.optional_string(MAX_METADATA_BYTES).ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let record_type = cursor.optional_string(MAX_METADATA_BYTES).ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let change_type = cursor.optional_i32().ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let etag = cursor.optional_string(MAX_METADATA_BYTES).ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let server_created_at_millis = seconds_to_millis(cursor.optional_f64().ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?)
    .ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let server_modified_at_millis = seconds_to_millis(cursor.optional_f64().ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?)
    .ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let permission = cursor.optional_u32().ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let raw_length = cursor.u64().ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let raw_digest = cursor.take(32).ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        )
    })?;
    let raw = cursor.optional_bytes(MAX_RAW_RECORD_BYTES).ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::OversizedRecord,
            None,
        )
    })?;
    if !cursor.finished()
        || raw
            .as_ref()
            .is_some_and(|value| value.len() as u64 != raw_length)
        || raw
            .as_ref()
            .is_some_and(|value| Sha256::digest(value).as_slice() != raw_digest)
    {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
            None,
        ));
    }
    let raw_digest_hex = raw_digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    Ok(CloudNativeRawEnvelope {
        generation,
        stream,
        kind,
        record_name,
        record_type,
        change_type,
        etag,
        server_created_at_millis,
        server_modified_at_millis,
        permission,
        raw_length,
        raw_digest_hex,
        raw,
    })
}

fn decode_checkpoint(
    encoded: &str,
    expected_generation: u64,
    expected_stream: CloudNativeStream,
) -> Result<Vec<u8>, CloudNativeFetchFailure> {
    let bytes = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidCheckpoint,
            None,
        )
    })?;
    let mut cursor = NativeByteCursor::new(&bytes);
    if cursor.take(CHECKPOINT_MAGIC.len()) != Some(CHECKPOINT_MAGIC)
        || cursor.u16() != Some(FORMAT_VERSION)
        || cursor.u64() != Some(expected_generation)
        || cursor.byte() != Some(expected_stream.tag())
    {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidCheckpoint,
            None,
        ));
    }
    let token = cursor.bytes(MAX_CONTINUATION_TOKEN_BYTES).ok_or_else(|| {
        CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidCheckpoint,
            None,
        )
    })?;
    if !cursor.finished() {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidCheckpoint,
            None,
        ));
    }
    Ok(token)
}

fn raw_bytes(change: &CloudMessageRecordPageChange) -> (&[u8], bool) {
    match (
        change.encrypted_record.as_deref(),
        change.tombstone_payload.as_deref(),
    ) {
        (Some(value), None) => (value, true),
        (None, Some(value)) => (value, true),
        (Some(value), Some(_)) => (value, false),
        (None, None) => (&[], false),
    }
}

fn metadata_bytes(change: &CloudMessageRecordPageChange) -> Option<usize> {
    let mut total = change.record_name.as_ref().map_or(0, String::len);
    total = total.checked_add(change.record_type.as_ref().map_or(0, String::len))?;
    total = total.checked_add(
        change
            .system_fields
            .as_ref()
            .and_then(|fields| fields.etag.as_ref())
            .map_or(0, String::len),
    )?;
    Some(total)
}

fn server_modified_at_millis(change: &CloudMessageRecordPageChange) -> Option<i64> {
    let seconds = change.system_fields.as_ref()?.modified_at?;
    if !seconds.is_finite() {
        return None;
    }
    let millis = seconds * 1_000.0;
    if millis < i64::MIN as f64 || millis > i64::MAX as f64 {
        return None;
    }
    Some(millis.round() as i64)
}

fn sha256_digest(value: &[u8]) -> CloudCanonicalDigest {
    CloudCanonicalDigest::new(sha256_hex(value))
        .expect("SHA-256 hex satisfies canonical digest grammar")
}

fn sha256_hex(value: &[u8]) -> String {
    Sha256::digest(value)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn map_store_failure(failure: CloudNativeStoreFailure) -> CloudNativeFetchFailure {
    let safe_code = match failure {
        CloudNativeStoreFailure::ContextMismatch => CloudNativeSafeCode::CheckpointContextMismatch,
        CloudNativeStoreFailure::InvalidReference => CloudNativeSafeCode::InvalidCheckpoint,
        CloudNativeStoreFailure::InvalidStorage | CloudNativeStoreFailure::Io => {
            CloudNativeSafeCode::LocalStoreFailed
        }
        CloudNativeStoreFailure::ProtectionUnavailable => CloudNativeSafeCode::ProtectionFailed,
    };
    CloudNativeFetchFailure::new(CloudNativeFailureCategory::LocalStorage, safe_code, None)
}

fn preflight_code(
    change: &CloudMessageRecordPageChange,
    raw_shape_valid: bool,
    oversized: bool,
) -> Option<CloudNativePreflightCode> {
    if oversized {
        return Some(CloudNativePreflightCode::OversizedRecord);
    }
    if !raw_shape_valid {
        return Some(CloudNativePreflightCode::InvalidChangeShape);
    }
    if change.record_name.as_deref().is_none_or(str::is_empty) {
        return Some(CloudNativePreflightCode::MalformedMetadata);
    }
    match change.kind {
        CloudMessageRecordKind::EncryptedUpsert => {
            if change.encrypted_record.is_none()
                || change.tombstone_payload.is_some()
                || change.record_type.as_deref().is_none_or(str::is_empty)
            {
                Some(CloudNativePreflightCode::InvalidChangeShape)
            } else {
                None
            }
        }
        CloudMessageRecordKind::Tombstone => {
            if change.tombstone_payload.is_none() || change.encrypted_record.is_some() {
                Some(CloudNativePreflightCode::InvalidChangeShape)
            } else {
                None
            }
        }
        CloudMessageRecordKind::UnsupportedRecordType => {
            Some(CloudNativePreflightCode::UnsupportedRecordType)
        }
        CloudMessageRecordKind::MalformedMetadata => {
            Some(CloudNativePreflightCode::MalformedMetadata)
        }
    }
}

struct PreparedChange {
    change_id: CloudCanonicalHash,
    record_id_hash: CloudCanonicalHash,
    etag_hash: Option<CloudCanonicalHash>,
    kind: CloudNativeChangeKind,
    payload_digest: CloudCanonicalDigest,
    payload_length: u64,
    server_modified_at_millis: Option<i64>,
    preflight_code: Option<CloudNativePreflightCode>,
    is_tombstone: bool,
    identity_plaintext_index: usize,
    raw_plaintext_index: usize,
}

fn stable_missing_record_identity(
    stream: CloudNativeStream,
    change: &CloudMessageRecordPageChange,
    payload_digest: &CloudCanonicalDigest,
) -> String {
    // A record with no server identifier has no stable occurrence discriminator.
    // Exact duplicate malformed changes intentionally coalesce; any observable
    // kind, type, change type, or payload difference produces a distinct hash.
    let kind_tag = match change.kind {
        CloudMessageRecordKind::EncryptedUpsert => 1,
        CloudMessageRecordKind::Tombstone => 2,
        CloudMessageRecordKind::UnsupportedRecordType => 3,
        CloudMessageRecordKind::MalformedMetadata => 4,
    };
    let record_type = change.record_type.as_deref().unwrap_or("");
    let change_type = change
        .change_type
        .map(|value| value.to_string())
        .unwrap_or_else(|| "none".to_owned());
    format!(
        "missing\u{0}{}\u{0}{}\u{0}{}:{}\u{0}{}\u{0}{}",
        stream.tag(),
        kind_tag,
        record_type.len(),
        record_type,
        change_type,
        payload_digest.value(),
    )
}

fn protect_native_page(
    store: &dyn CloudNativeProtectedStore,
    hasher: &CloudSemanticIdentifierHasher,
    request: &CloudNativeFetchRequest<'_>,
    page: CloudMessageRecordPage,
) -> CloudNativeProtectedFetchOutcome {
    if let Err(failure) = request.scope.validate_for_stream(request.stream) {
        return CloudNativeProtectedFetchOutcome::Failure(failure);
    }
    let maximum_changes = request.maximum_changes as usize;
    if maximum_changes == 0 || maximum_changes > MAX_CHANGES_PER_PAGE {
        return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    if page.changes.len() > maximum_changes || page.changes.len() > MAX_CHANGES_PER_PAGE {
        return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::OversizedPage,
            None,
        ));
    }
    if !page.is_complete() && page.next_token.is_none() {
        return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidCheckpoint,
            None,
        ));
    }
    if page
        .next_token
        .as_ref()
        .is_some_and(|token| token.len() > MAX_CONTINUATION_TOKEN_BYTES)
    {
        return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidCheckpoint,
            None,
        ));
    }

    let mut admitted_bytes = page.next_token.as_ref().map_or(0, Vec::len);
    for change in &page.changes {
        let (raw, _) = raw_bytes(change);
        let Some(metadata) = metadata_bytes(change) else {
            return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::OversizedPage,
                None,
            ));
        };
        if metadata > MAX_METADATA_BYTES {
            return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::OversizedRecord,
                None,
            ));
        }
        admitted_bytes = match admitted_bytes
            .checked_add(metadata)
            .and_then(|size| size.checked_add(raw.len()))
            .and_then(|size| size.checked_add(256))
        {
            Some(value) if value <= MAX_RAW_PAGE_BYTES => value,
            _ => {
                return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::MalformedRecord,
                    CloudNativeSafeCode::OversizedPage,
                    None,
                ))
            }
        };
    }

    let mut plaintexts = Vec::with_capacity(page.changes.len() * 2 + 1);
    let mut prepared = Vec::with_capacity(page.changes.len());
    for change in &page.changes {
        let (raw, raw_shape_valid) = raw_bytes(change);
        let oversized = raw.len() > MAX_RAW_RECORD_BYTES;
        let preflight = preflight_code(change, raw_shape_valid, oversized);
        let payload_digest = sha256_digest(raw);
        let record_identity = change
            .record_name
            .as_deref()
            .filter(|value| !value.is_empty());
        let fallback_identity =
            stable_missing_record_identity(request.stream, change, &payload_digest);
        let record_id_hash = match hasher
            .canonical_server_record_id_hash(record_identity.unwrap_or(&fallback_identity))
        {
            Ok(value) => value,
            Err(_) => {
                return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::MalformedRecord,
                    CloudNativeSafeCode::MalformedResponse,
                    None,
                ))
            }
        };
        let etag_hash = match change
            .system_fields
            .as_ref()
            .and_then(|fields| fields.etag.as_deref())
            .filter(|etag| !etag.is_empty())
            .map(|etag| hasher.canonical_etag_hash(etag))
            .transpose()
        {
            Ok(value) => value,
            Err(_) => {
                return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::MalformedRecord,
                    CloudNativeSafeCode::MalformedResponse,
                    None,
                ))
            }
        };
        let kind = match (change.kind, preflight) {
            (_, Some(_)) => CloudNativeChangeKind::Quarantined,
            (CloudMessageRecordKind::EncryptedUpsert, None) => CloudNativeChangeKind::Save,
            (CloudMessageRecordKind::Tombstone, None) => CloudNativeChangeKind::Delete,
            (
                CloudMessageRecordKind::UnsupportedRecordType
                | CloudMessageRecordKind::MalformedMetadata,
                None,
            ) => CloudNativeChangeKind::Quarantined,
        };
        let change_material = format!(
            "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
            request.generation,
            record_id_hash.value(),
            match kind {
                CloudNativeChangeKind::Save => 1,
                CloudNativeChangeKind::Delete => 2,
                CloudNativeChangeKind::Quarantined => 3,
            },
            change.change_type.unwrap_or_default(),
            etag_hash
                .as_ref()
                .map(CloudCanonicalHash::value)
                .unwrap_or("none"),
            payload_digest.value(),
        );
        let change_id = match hasher.canonical_change_id_hash(&change_material) {
            Ok(value) => value,
            Err(_) => {
                return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::MalformedRecord,
                    CloudNativeSafeCode::MalformedResponse,
                    None,
                ))
            }
        };
        let identity_plaintext =
            match encode_record_identity(request.generation, request.stream, record_identity) {
                Ok(value) => value,
                Err(failure) => return CloudNativeProtectedFetchOutcome::Failure(failure),
            };
        let raw_plaintext = match encode_raw_envelope(
            request.generation,
            request.stream,
            change,
            raw,
            !oversized,
        ) {
            Ok(value) => value,
            Err(failure) => return CloudNativeProtectedFetchOutcome::Failure(failure),
        };
        let identity_plaintext_index = plaintexts.len();
        plaintexts.push(CloudNativePlaintext {
            purpose: CloudNativeProtectionPurpose::ServerRecordId,
            value: identity_plaintext,
        });
        let raw_plaintext_index = plaintexts.len();
        plaintexts.push(CloudNativePlaintext {
            purpose: CloudNativeProtectionPurpose::RawRecord,
            value: raw_plaintext,
        });
        prepared.push(PreparedChange {
            change_id,
            record_id_hash,
            etag_hash,
            kind,
            payload_digest,
            payload_length: raw.len() as u64,
            server_modified_at_millis: server_modified_at_millis(change),
            preflight_code: preflight,
            is_tombstone: matches!(change.kind, CloudMessageRecordKind::Tombstone),
            identity_plaintext_index,
            raw_plaintext_index,
        });
    }

    let checkpoint_plaintext_index = if let Some(token) = page.next_token.as_deref() {
        let value = match encode_checkpoint(request.generation, request.stream, token) {
            Ok(value) => value,
            Err(failure) => return CloudNativeProtectedFetchOutcome::Failure(failure),
        };
        let index = plaintexts.len();
        plaintexts.push(CloudNativePlaintext {
            purpose: CloudNativeProtectionPurpose::CheckpointToken,
            value,
        });
        Some(index)
    } else {
        None
    };
    let protected_plaintext_bytes = plaintexts
        .iter()
        .try_fold(0usize, |total, value| total.checked_add(value.value.len()));
    if protected_plaintext_bytes.is_none_or(|total| total > MAX_PROTECTED_PLAINTEXT_BATCH_BYTES) {
        return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::OversizedPage,
            None,
        ));
    }
    let mut batch_material = format!(
        "{}\u{1f}{}\u{1f}{}\u{1f}{}",
        request.generation,
        request.stream.tag(),
        page.status,
        page.is_complete()
    );
    for change in &prepared {
        batch_material.push('\u{1f}');
        batch_material.push_str(change.change_id.value());
    }
    if let Some(token) = page.next_token.as_deref() {
        batch_material.push('\u{1f}');
        batch_material.push_str(sha256_digest(token).value());
    }
    let batch_id = match hasher.canonical_change_id_hash(&batch_material) {
        Ok(value) => value,
        Err(_) => {
            return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::MalformedResponse,
                None,
            ))
        }
    };
    let protected_batch = match store.protect_batch(request.scope, &plaintexts) {
        Ok(value) if value.references.len() == plaintexts.len() => value,
        Ok(_) => {
            return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::LocalStorage,
                CloudNativeSafeCode::ProtectionFailed,
                None,
            ))
        }
        Err(error) => {
            return CloudNativeProtectedFetchOutcome::Failure(map_store_failure(error));
        }
    };
    let references = &protected_batch.references;

    let changes = prepared
        .into_iter()
        .map(|change| CloudNativeProtectedChange {
            change_id: change.change_id,
            record_id_hash: change.record_id_hash,
            etag_hash: change.etag_hash,
            kind: change.kind,
            payload_digest: change.payload_digest,
            payload_length: change.payload_length,
            protected_record_identity_reference: references[change.identity_plaintext_index]
                .clone(),
            protected_raw_envelope_reference: references[change.raw_plaintext_index].clone(),
            server_modified_at_millis: change.server_modified_at_millis,
            preflight_code: change.preflight_code,
            is_tombstone: change.is_tombstone,
        })
        .collect::<Vec<_>>();
    CloudNativeProtectedFetchOutcome::Page(CloudNativeProtectedPage {
        changes,
        batch_id,
        generation: request.generation,
        page_lease: protected_batch.lease,
        protected_next_checkpoint_reference: checkpoint_plaintext_index
            .map(|index| references[index].clone()),
        status: page.status,
        complete: page.is_complete(),
        admitted_raw_bytes: admitted_bytes as u64,
    })
}

fn retry_after_seconds(error: &PushError) -> Option<u64> {
    match error {
        PushError::CloudKitError(result) => result
            .error
            .as_ref()
            .and_then(|error| error.retry_after_seconds)
            .filter(|seconds| *seconds > 0)
            .map(|seconds| (seconds as u64).min(MAX_RETRY_AFTER_SECONDS)),
        PushError::CloudKitHttpError {
            retry_after: Some(retry_after),
            ..
        } if !retry_after.is_zero() => {
            Some(retry_after.as_secs().max(1).min(MAX_RETRY_AFTER_SECONDS))
        }
        PushError::DoNotRetry(inner) => retry_after_seconds(inner),
        PushError::BatchError(inner) => retry_after_seconds(inner),
        _ => None,
    }
}

fn map_fetch_failure(error: &PushError) -> CloudNativeFetchFailure {
    let retry_after = retry_after_seconds(error);
    let (category, safe_code) = match error {
        PushError::CloudKitChangeTokenExpired => (
            CloudNativeFailureCategory::Unknown,
            CloudNativeSafeCode::CloudKitResetRequired,
        ),
        PushError::CloudKitWarmAuthenticationRequired => (
            CloudNativeFailureCategory::Authorization,
            CloudNativeSafeCode::CloudKitAuthorization,
        ),
        PushError::CloudKitError(result) => match classify_cloudkit_failure(result) {
            CloudKitFailureClass::Throttled => (
                CloudNativeFailureCategory::Throttled,
                CloudNativeSafeCode::CloudKitThrottled,
            ),
            CloudKitFailureClass::TransientServer => (
                CloudNativeFailureCategory::Server,
                CloudNativeSafeCode::CloudKitServer,
            ),
            CloudKitFailureClass::Authentication => (
                CloudNativeFailureCategory::Authorization,
                CloudNativeSafeCode::CloudKitAuthorization,
            ),
            CloudKitFailureClass::Conflict => (
                CloudNativeFailureCategory::Conflict,
                CloudNativeSafeCode::CloudKitConflict,
            ),
            CloudKitFailureClass::ResetRequired => (
                CloudNativeFailureCategory::Unknown,
                CloudNativeSafeCode::CloudKitResetRequired,
            ),
            CloudKitFailureClass::Permanent => (
                CloudNativeFailureCategory::Unknown,
                CloudNativeSafeCode::CloudKitPermanent,
            ),
            CloudKitFailureClass::Unknown => (
                CloudNativeFailureCategory::Unknown,
                CloudNativeSafeCode::CloudKitUnknown,
            ),
        },
        PushError::RequestError(error) => {
            if error.is_timeout() || error.is_connect() {
                return CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::Network,
                    CloudNativeSafeCode::Network,
                    retry_after,
                );
            }
            match error.status().map(|status| status.as_u16()) {
                Some(401 | 403) => (
                    CloudNativeFailureCategory::Authorization,
                    CloudNativeSafeCode::HttpAuthorization,
                ),
                Some(408) => (
                    CloudNativeFailureCategory::Network,
                    CloudNativeSafeCode::HttpTimeout,
                ),
                Some(429) => (
                    CloudNativeFailureCategory::Throttled,
                    CloudNativeSafeCode::HttpThrottled,
                ),
                Some(500..=599) => (
                    CloudNativeFailureCategory::Server,
                    CloudNativeSafeCode::HttpServer,
                ),
                _ => (
                    CloudNativeFailureCategory::Unknown,
                    CloudNativeSafeCode::HttpUnknown,
                ),
            }
        }
        PushError::StatusError(status) => match status.as_u16() {
            401 | 403 => (
                CloudNativeFailureCategory::Authorization,
                CloudNativeSafeCode::HttpAuthorization,
            ),
            408 => (
                CloudNativeFailureCategory::Network,
                CloudNativeSafeCode::HttpTimeout,
            ),
            429 => (
                CloudNativeFailureCategory::Throttled,
                CloudNativeSafeCode::HttpThrottled,
            ),
            500..=599 => (
                CloudNativeFailureCategory::Server,
                CloudNativeSafeCode::HttpServer,
            ),
            _ => (
                CloudNativeFailureCategory::Unknown,
                CloudNativeSafeCode::HttpUnknown,
            ),
        },
        PushError::CloudKitHttpError { status, .. } => match *status {
            401 | 403 => (
                CloudNativeFailureCategory::Authorization,
                CloudNativeSafeCode::HttpAuthorization,
            ),
            408 => (
                CloudNativeFailureCategory::Network,
                CloudNativeSafeCode::HttpTimeout,
            ),
            429 => (
                CloudNativeFailureCategory::Throttled,
                CloudNativeSafeCode::HttpThrottled,
            ),
            500..=599 => (
                CloudNativeFailureCategory::Server,
                CloudNativeSafeCode::HttpServer,
            ),
            _ => (
                CloudNativeFailureCategory::Unknown,
                CloudNativeSafeCode::HttpUnknown,
            ),
        },
        PushError::ResourceTimeout
        | PushError::ResourceGenTimeout
        | PushError::ResourceStalled
        | PushError::NotConnected => (
            CloudNativeFailureCategory::Network,
            CloudNativeSafeCode::Network,
        ),
        PushError::TooManyRequests => (
            CloudNativeFailureCategory::Throttled,
            CloudNativeSafeCode::CloudKitThrottled,
        ),
        PushError::UnauthorizedAccountError
        | PushError::TokenMissing
        | PushError::UserNotFound
        | PushError::AuthInvalid(_)
        | PushError::MobileMeError(_, _) => (
            CloudNativeFailureCategory::Authorization,
            CloudNativeSafeCode::CloudKitAuthorization,
        ),
        PushError::AnisetteError(error) => match error {
            rustpush::AnisetteError::ReqwestError(error) => {
                if error.is_timeout() || error.is_connect() {
                    (
                        CloudNativeFailureCategory::Network,
                        CloudNativeSafeCode::Network,
                    )
                } else {
                    match error.status().map(|status| status.as_u16()) {
                        Some(408) => (
                            CloudNativeFailureCategory::Network,
                            CloudNativeSafeCode::HttpTimeout,
                        ),
                        Some(429) => (
                            CloudNativeFailureCategory::Throttled,
                            CloudNativeSafeCode::HttpThrottled,
                        ),
                        Some(500..=599) => (
                            CloudNativeFailureCategory::Server,
                            CloudNativeSafeCode::HttpServer,
                        ),
                        _ => (
                            CloudNativeFailureCategory::Authorization,
                            CloudNativeSafeCode::NativeAuthUnavailable,
                        ),
                    }
                }
            }
            rustpush::AnisetteError::WsError(_)
            | rustpush::AnisetteError::ProvisioningSocketClosed => (
                CloudNativeFailureCategory::Network,
                CloudNativeSafeCode::Network,
            ),
            rustpush::AnisetteError::ProvisioningServerError(_) => (
                CloudNativeFailureCategory::Server,
                CloudNativeSafeCode::HttpServer,
            ),
            _ => (
                CloudNativeFailureCategory::Authorization,
                CloudNativeSafeCode::NativeAuthUnavailable,
            ),
        },
        PushError::CloudKitSemanticOperationDenied => (
            CloudNativeFailureCategory::Authorization,
            CloudNativeSafeCode::ReadAuthenticationScope,
        ),
        PushError::PCSRecordKeyMissing
        | PushError::PCSKeyIdMismatch
        | PushError::PCSDecryptionFailed
        | PushError::MasterKeyNotFound
        | PushError::NotInClique
        | PushError::ShareKeyNotFound(_)
        | PushError::NoRoutingKey => (
            CloudNativeFailureCategory::PcsUnavailable,
            CloudNativeSafeCode::PcsUnavailable,
        ),
        PushError::PCSCiphertextMalformed
        | PushError::BadMsg
        | PushError::PlistError(_)
        | PushError::ProtobufError(_)
        | PushError::JsonError(_) => (
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::MalformedResponse,
        ),
        PushError::CloudKitProtocolError(CloudKitProtocolError::ContinuationTokenNoProgress) => (
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::ContinuationNoProgress,
        ),
        PushError::IoError(_) => (
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::LocalStoreFailed,
        ),
        PushError::DoNotRetry(inner) => return map_fetch_failure(inner),
        PushError::BatchError(inner) => return map_fetch_failure(inner),
        _ => (
            CloudNativeFailureCategory::Unknown,
            CloudNativeSafeCode::Unknown,
        ),
    };
    CloudNativeFetchFailure::new(category, safe_code, retry_after)
}

fn encode_reset_proof(request: &CloudNativeFetchRequest<'_>) -> String {
    let checkpoint_digest = Sha256::digest(
        request
            .previous_checkpoint_reference
            .unwrap_or_default()
            .as_bytes(),
    );
    let mut encoded =
        Vec::with_capacity(RESET_PROOF_MAGIC.len() + 2 + 8 + 1 + 1 + 32);
    encoded.extend_from_slice(RESET_PROOF_MAGIC);
    encoded.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    encoded.extend_from_slice(&request.generation.to_be_bytes());
    encoded.push(request.stream.tag());
    encoded.push(1); // authenticated remote change-token/reset rejection
    encoded.extend_from_slice(&checkpoint_digest);
    URL_SAFE_NO_PAD.encode(encoded)
}

fn protect_reset_failure(
    store: &dyn CloudNativeProtectedStore,
    request: &CloudNativeFetchRequest<'_>,
    error: &PushError,
) -> CloudNativeFetchFailure {
    let mut failure = map_fetch_failure(error);
    if failure.safe_code != CloudNativeSafeCode::CloudKitResetRequired {
        return failure;
    }

    let protected = match store.protect_batch(
        request.scope,
        &[CloudNativePlaintext {
            purpose: CloudNativeProtectionPurpose::ResetProof,
            value: encode_reset_proof(request),
        }],
    ) {
        Ok(batch) if batch.references.len() == 1 => batch,
        Ok(batch) => {
            let _ = store.rollback_lease(&batch.lease);
            return failure;
        }
        Err(_) => return failure,
    };
    let proof_reference = protected.references[0].clone();
    let retained = HashSet::from([proof_reference.value().to_owned()]);
    if store.commit_lease(&protected.lease, &retained).is_err() {
        // Commit can fail after its durable receipt is written. Recovery owns
        // either the remaining manifest or receipt, so do not risk deleting a
        // value whose commit outcome is uncertain.
        return failure;
    }
    // The protected value is now durable. Removing the commit receipt is only
    // cleanup; a failed acknowledgement is recovered independently and does
    // not invalidate the capability returned to the caller.
    let _ = store.acknowledge_committed_lease(&protected.lease);
    failure.protected_reset_proof_reference = Some(proof_reference);
    failure
}

async fn cloud_sync_fetch_protected_page_with_store(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    read_authentication_permit: Option<&CloudKitReadAuthenticationPermit<'_>>,
    hasher: &CloudSemanticIdentifierHasher,
    store: &dyn CloudNativeProtectedStore,
    request: &CloudNativeFetchRequest<'_>,
) -> CloudNativeProtectedFetchOutcome {
    if request.maximum_changes == 0
        || request.maximum_changes as usize > MAX_CHANGES_PER_PAGE
        || request.generation == 0
    {
        return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    if let Err(failure) = request.scope.validate_for_stream(request.stream) {
        return CloudNativeProtectedFetchOutcome::Failure(failure);
    }
    if read_authentication_permit.is_some()
        && !matches!(
            request.stream,
            CloudNativeStream::Chats | CloudNativeStream::Messages | CloudNativeStream::Attachments
        )
    {
        return CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidScope,
            None,
        ));
    }
    let continuation_token = match decode_previous_checkpoint(store, request) {
        Ok(value) => value,
        Err(failure) => return CloudNativeProtectedFetchOutcome::Failure(failure),
    };

    let fetch = async {
        match (request.stream, read_authentication_permit) {
            (CloudNativeStream::Chats, Some(permit)) => {
                cloud_messages_client
                    .sync_chats_page_for_read_authentication(
                        permit,
                        continuation_token,
                        Some(request.maximum_changes),
                    )
                    .await
            }
            (CloudNativeStream::Messages, Some(permit)) => {
                cloud_messages_client
                    .sync_messages_page_for_read_authentication(
                        permit,
                        continuation_token,
                        Some(request.maximum_changes),
                    )
                    .await
            }
            (CloudNativeStream::Attachments, Some(permit)) => {
                cloud_messages_client
                    .sync_attachments_page_for_read_authentication(
                        permit,
                        continuation_token,
                        Some(request.maximum_changes),
                    )
                    .await
            }
            (
                CloudNativeStream::MessageUpdate
                | CloudNativeStream::RecoverableMessageDelete
                | CloudNativeStream::ScheduledMessage
                | CloudNativeStream::Chat1,
                Some(_),
            ) => unreachable!("permit-bound semantic stream was rejected before fetch"),
            (CloudNativeStream::Chats, None) => {
                cloud_messages_client
                    .sync_chats_page(continuation_token, Some(request.maximum_changes))
                    .await
            }
            (CloudNativeStream::Messages, None) => {
                cloud_messages_client
                    .sync_messages_page(continuation_token, Some(request.maximum_changes))
                    .await
            }
            (CloudNativeStream::Attachments, None) => {
                cloud_messages_client
                    .sync_attachments_page(continuation_token, Some(request.maximum_changes))
                    .await
            }
            (CloudNativeStream::MessageUpdate, None) => {
                cloud_messages_client
                    .sync_message_update_page(continuation_token, Some(request.maximum_changes))
                    .await
            }
            (CloudNativeStream::RecoverableMessageDelete, None) => {
                cloud_messages_client
                    .sync_recoverable_message_delete_page(
                        continuation_token,
                        Some(request.maximum_changes),
                    )
                    .await
            }
            (CloudNativeStream::ScheduledMessage, None) => {
                cloud_messages_client
                    .sync_scheduled_message_page(continuation_token, Some(request.maximum_changes))
                    .await
            }
            (CloudNativeStream::Chat1, None) => {
                cloud_messages_client
                    .sync_chat1_page(continuation_token, Some(request.maximum_changes))
                    .await
            }
        }
    };
    match tokio::time::timeout(FETCH_DEADLINE, fetch).await {
        Err(_) => CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::Network,
            CloudNativeSafeCode::FetchDeadline,
            None,
        )),
        Ok(Err(error)) => {
            CloudNativeProtectedFetchOutcome::Failure(protect_reset_failure(
                store, request, &error,
            ))
        }
        Ok(Ok(page)) => protect_native_page(store, hasher, request, page),
    }
}

fn decode_previous_checkpoint(
    store: &dyn CloudNativeProtectedStore,
    request: &CloudNativeFetchRequest<'_>,
) -> Result<Option<Vec<u8>>, CloudNativeFetchFailure> {
    match request.previous_checkpoint_reference {
        Some(reference) => {
            let reference = match CloudCanonicalProtectedReference::new(reference.to_owned()) {
                Ok(value) => value,
                Err(_) => {
                    return Err(CloudNativeFetchFailure::new(
                        CloudNativeFailureCategory::LocalStorage,
                        CloudNativeSafeCode::InvalidCheckpoint,
                        None,
                    ))
                }
            };
            let protected = match store.unprotect(
                request.scope,
                CloudNativeProtectionPurpose::CheckpointToken,
                &reference,
            ) {
                Ok(value) => value,
                Err(error) => return Err(map_store_failure(error)),
            };
            decode_checkpoint(&protected, request.generation, request.stream).map(Some)
        }
        None => Ok(None),
    }
}

fn windows_feed_probe_request(
    zone: rustpush::cloudkit_proto::RecordZoneIdentifier,
    token: Option<Vec<u8>>,
    newest_first: bool,
    include_self: bool,
) -> rustpush::cloudkit::FetchRecordChangesOperation {
    let mut operation = rustpush::cloudkit::FetchRecordChangesOperation::new_with_limit(
        zone, token, &rustpush::cloudkit::NO_ASSETS, 200,
    );
    operation.0.newest_first = Some(newest_first);
    if include_self { operation.0.ignore_calling_device_changes = Some(false); }
    operation
}

/// Read-only comparison, invoked only by the Windows dev-profile API. It does
/// not protect, journal, retire, or adopt any returned token or record.
pub(crate) async fn cloud_sync_windows_probe_feed(
    client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    permit: &CloudKitReadAuthenticationPermit<'_>,
    directory: PathBuf,
    hasher: &CloudSemanticIdentifierHasher,
    request: &CloudNativeFetchRequest<'_>,
    target: &str,
) -> anyhow::Result<String> {
    let store = PlatformCloudNativeProtectedStore::new(directory);
    let token = decode_previous_checkpoint(&store, request)
        .map_err(|_| anyhow::anyhow!("cloud_sync_windows_feed_probe_checkpoint_invalid"))?;
    let container = client.get_cached_container_for_read_authentication(permit).await
        .map_err(|_| anyhow::anyhow!("cloud_sync_windows_feed_probe_auth_failed"))?;
    let zone = container.private_zone("messageManateeZone".to_owned());
    let mut results = Vec::new();
    for (label, continuation, newest, include_self) in [
        ("current_include_self", token.clone(), false, true),
        ("current_newest_include_self", token, true, true),
        ("newest_default", None, true, false),
        ("newest_include_self", None, true, true),
    ] {
        let active = client.get_cached_container_for_read_authentication(permit).await
            .map_err(|_| anyhow::anyhow!("cloud_sync_windows_feed_probe_auth_failed"))?;
        if !Arc::ptr_eq(&active, &container) {
            return Err(anyhow::anyhow!("cloud_sync_windows_feed_probe_auth_failed"));
        }
        let requested_token = continuation.clone();
        let operation = windows_feed_probe_request(zone.clone(), continuation, newest, include_self);
        let response = tokio::time::timeout(FETCH_DEADLINE,
            container.perform_semantic_read_only(&rustpush::cloudkit::CloudKitSession::new(), operation),
        ).await;
        let (_, response) = match response {
            Ok(Ok(response)) => response,
            _ => {
                results.push(serde_json::json!({"mode": label, "failed": true}));
                continue;
            }
        };
        let active = client.get_cached_container_for_read_authentication(permit).await
            .map_err(|_| anyhow::anyhow!("cloud_sync_windows_feed_probe_auth_failed"))?;
        if !Arc::ptr_eq(&active, &container) {
            return Err(anyhow::anyhow!("cloud_sync_windows_feed_probe_auth_failed"));
        }
        if response.change.len() > 200 {
            return Err(anyhow::anyhow!("cloud_sync_windows_feed_probe_page_oversized"));
        }
        let matches = response.change.iter().filter(|change| change.identifier.as_ref()
            .and_then(|id| id.value.as_ref()).and_then(|value| value.name.as_deref())
            .is_some_and(|name| hasher.server_record_id_hash(name) == target)).count();
        results.push(serde_json::json!({"mode": label, "failed": false,
            "changes": response.change.len(), "target_matches": matches,
            "status": response.status(), "deltas": response.changed_deltas.len(),
            "obligations": response.sync_obligations.len(),
            "shares": response.changed_shares.len(),
            "response_token_present": response.sync_continuation_token.is_some(),
            "response_token_matches_input": response.sync_continuation_token == requested_token,
            "client_token_present": response.client_change_token.is_some(),
            "pending_archived": response.pending_archived_records,
            "zone_attributes": response.zone_attributes_changes.is_some()}));
    }
    Ok(serde_json::json!({"reads": results}).to_string())
}

#[cfg(test)]
mod windows_feed_probe_tests {
    use super::*;

    #[test]
    fn cloud_sync_windows_feed_probe_changes_only_explicit_read_options() {
        let zone = Default::default();
        let ordinary = windows_feed_probe_request(zone, Some(vec![1, 2]), false, false);
        assert_eq!(ordinary.0.sync_continuation_token, Some(vec![1, 2]));
        assert_eq!(ordinary.0.ignore_calling_device_changes, None);
        assert_eq!(ordinary.0.newest_first, Some(false));
        assert_eq!(ordinary.0.max_changes, Some(200));
        assert_eq!(ordinary.0.assets_to_download.unwrap().all_assets, Some(false));
        let probe = windows_feed_probe_request(Default::default(), None, true, true);
        assert_eq!(probe.0.sync_continuation_token, None);
        assert_eq!(probe.0.ignore_calling_device_changes, Some(false));
        assert_eq!(probe.0.newest_first, Some(true));
        assert_eq!(probe.0.requested_changes_types, ordinary.0.requested_changes_types);
    }

}

pub(crate) async fn cloud_sync_fetch_protected_page(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    read_authentication_permit: Option<&CloudKitReadAuthenticationPermit<'_>>,
    storage_directory: PathBuf,
    hasher: &CloudSemanticIdentifierHasher,
    request: &CloudNativeFetchRequest<'_>,
) -> CloudNativeProtectedFetchOutcome {
    let store = PlatformCloudNativeProtectedStore::new(storage_directory);
    cloud_sync_fetch_protected_page_with_store(
        cloud_messages_client,
        read_authentication_permit,
        hasher,
        &store,
        request,
    )
    .await
}

/// Unprotects and validates exactly one raw-record capability for the transient
/// semantic decoder. Raw identifiers and bytes never leave Rust.
pub(crate) fn cloud_sync_unprotect_raw_envelope(
    storage_directory: PathBuf,
    scope: &CloudNativeProtectionScope,
    stream: CloudNativeStream,
    generation: u64,
    protected_raw_envelope_reference: &str,
) -> Result<CloudNativeRawEnvelope, CloudNativeFetchFailure> {
    if generation == 0 {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    scope.validate_for_stream(stream)?;
    let reference =
        CloudCanonicalProtectedReference::new(protected_raw_envelope_reference.to_owned())
            .map_err(|_| {
                CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::LocalStorage,
                    CloudNativeSafeCode::InvalidRequest,
                    None,
                )
            })?;
    let encoded = PlatformCloudNativeProtectedStore::new(storage_directory)
        .unprotect(scope, CloudNativeProtectionPurpose::RawRecord, &reference)
        .map_err(map_store_failure)?;
    decode_raw_envelope(&encoded, generation, stream)
}

/// Called only after the local ObjectBox journal transaction has adopted every
/// reference in the page.
pub(crate) fn cloud_sync_commit_protected_page(
    storage_directory: PathBuf,
    page: &CloudNativeProtectedPage,
    retained_references: &[String],
) -> Result<(), CloudNativeFetchFailure> {
    cloud_sync_commit_protected_page_lease(
        storage_directory,
        page.page_lease_reference(),
        retained_references,
    )
}

/// Called when local journal validation or admission rejects the page.
pub(crate) fn cloud_sync_rollback_protected_page(
    storage_directory: PathBuf,
    page: &CloudNativeProtectedPage,
) -> Result<(), CloudNativeFetchFailure> {
    cloud_sync_rollback_protected_page_lease(storage_directory, page.page_lease_reference())
}

pub(crate) fn cloud_sync_commit_protected_page_lease(
    storage_directory: PathBuf,
    page_lease_reference: &str,
    retained_references: &[String],
) -> Result<(), CloudNativeFetchFailure> {
    let lease = CloudNativePageLease::parse(page_lease_reference)?;
    let retained = parse_protected_reference_set(retained_references)?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .commit_lease(&lease, &retained)
        .map_err(map_store_failure)
}

pub(crate) fn cloud_sync_verify_committed_lease_exact(
    storage_directory: PathBuf,
    lease_reference: &str,
    retained_references: &[String],
) -> Result<(), CloudNativeFetchFailure> {
    let lease = CloudNativePageLease::parse(lease_reference)?;
    let retained = parse_protected_reference_set(retained_references)?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .verify_committed_lease_exact(&lease, &retained)
        .map_err(map_store_failure)
}

/// Native-only result of staging one outbound message and its stable CloudKit
/// record name in a single crash-recoverable protected-store lease.
pub(crate) struct CloudNativeProtectedOutboundStage {
    pub(crate) protected_envelope_reference: String,
    pub(crate) lease_reference: String,
}

/// Stages the outbound payload and server record identity together. Neither
/// plaintext value is returned through Flutter Rust Bridge; callers receive
/// only opaque capabilities and adopt them in their local journal before
/// committing the lease.
pub(crate) fn cloud_sync_stage_protected_outbound_envelope(
    storage_directory: PathBuf,
    account_fingerprint: String,
    outbound_envelope: String,
) -> Result<CloudNativeProtectedOutboundStage, CloudNativeFetchFailure> {
    stage_protected_outbound_value(
        storage_directory,
        account_fingerprint,
        outbound_envelope,
        CloudNativeStream::Messages,
        CloudNativeProtectionPurpose::OutboundMessage,
    )
}

pub(crate) fn cloud_sync_stage_protected_outbound_chat_envelope(
    storage_directory: PathBuf,
    account_fingerprint: String,
    outbound_envelope: String,
) -> Result<CloudNativeProtectedOutboundStage, CloudNativeFetchFailure> {
    stage_protected_outbound_value(
        storage_directory,
        account_fingerprint,
        outbound_envelope,
        CloudNativeStream::Chats,
        CloudNativeProtectionPurpose::OutboundChat,
    )
}

pub(crate) fn cloud_sync_stage_protected_outbound_attachment_envelope(
    storage_directory: PathBuf,
    account_fingerprint: String,
    outbound_envelope: String,
) -> Result<CloudNativeProtectedOutboundStage, CloudNativeFetchFailure> {
    stage_protected_outbound_value(storage_directory, account_fingerprint, outbound_envelope,
        CloudNativeStream::Attachments, CloudNativeProtectionPurpose::OutboundAttachment)
}

pub(crate) fn cloud_sync_stage_protected_attachment_upload_envelope(
    storage_directory: PathBuf,
    account_fingerprint: String,
    outbound_envelope: String,
) -> Result<CloudNativeProtectedOutboundStage, CloudNativeFetchFailure> {
    stage_protected_outbound_value(storage_directory, account_fingerprint, outbound_envelope,
        CloudNativeStream::Attachments, CloudNativeProtectionPurpose::OutboundAttachmentUpload)
}

pub(crate) fn cloud_sync_stage_protected_ids_attachment_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    source_envelope: String,
) -> Result<CloudNativeProtectedOutboundStage, CloudNativeFetchFailure> {
    stage_protected_outbound_value(storage_directory, account_fingerprint, source_envelope,
        CloudNativeStream::Messages, CloudNativeProtectionPurpose::IdsAttachmentSource)
}

pub(crate) fn cloud_sync_open_protected_ids_attachment_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
) -> Result<String, CloudNativeFetchFailure> {
    cloud_sync_open_protected_outbound_value(storage_directory, account_fingerprint, protected_reference,
        CloudNativeStream::Messages, CloudNativeProtectionPurpose::IdsAttachmentSource)
}

pub(crate) fn cloud_sync_stage_protected_ids_mutation_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    source_envelope: String,
) -> Result<CloudNativeProtectedOutboundStage, CloudNativeFetchFailure> {
    stage_protected_outbound_value(storage_directory, account_fingerprint, source_envelope,
        CloudNativeStream::Messages, CloudNativeProtectionPurpose::IdsMutationSource)
}

pub(crate) fn cloud_sync_open_protected_ids_mutation_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
) -> Result<String, CloudNativeFetchFailure> {
    cloud_sync_open_protected_outbound_value(storage_directory, account_fingerprint, protected_reference,
        CloudNativeStream::Messages, CloudNativeProtectionPurpose::IdsMutationSource)
}

fn stage_protected_outbound_value(
    storage_directory: PathBuf,
    account_fingerprint: String,
    outbound_envelope: String,
    stream: CloudNativeStream,
    purpose: CloudNativeProtectionPurpose,
) -> Result<CloudNativeProtectedOutboundStage, CloudNativeFetchFailure> {
    if outbound_envelope.is_empty() {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::MalformedRecord,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    let scope = CloudNativeProtectionScope::new(account_fingerprint, stream)?;
    let store = PlatformCloudNativeProtectedStore::new(storage_directory);
    let batch = store
        .protect_batch(
            &scope,
            &[CloudNativePlaintext {
                purpose,
                value: outbound_envelope,
            }],
        )
        .map_err(map_store_failure)?;
    if batch.references.len() != 1 {
        let _ = store.rollback_lease(&batch.lease);
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::ProtectionFailed,
            None,
        ));
    }
    Ok(CloudNativeProtectedOutboundStage {
        protected_envelope_reference: batch.references[0].value().to_owned(),
        lease_reference: batch.lease.value().to_owned(),
    })
}

pub(crate) fn cloud_sync_open_protected_outbound_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
) -> Result<String, CloudNativeFetchFailure> {
    cloud_sync_open_protected_outbound_value(
        storage_directory,
        account_fingerprint,
        protected_reference,
        CloudNativeStream::Messages,
        CloudNativeProtectionPurpose::OutboundMessage,
    )
}

pub(crate) fn cloud_sync_open_protected_outbound_chat(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
) -> Result<String, CloudNativeFetchFailure> {
    cloud_sync_open_protected_outbound_value(
        storage_directory,
        account_fingerprint,
        protected_reference,
        CloudNativeStream::Chats,
        CloudNativeProtectionPurpose::OutboundChat,
    )
}

pub(crate) fn cloud_sync_open_protected_outbound_attachment(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
) -> Result<String, CloudNativeFetchFailure> {
    cloud_sync_open_protected_outbound_value(storage_directory, account_fingerprint, protected_reference,
        CloudNativeStream::Attachments, CloudNativeProtectionPurpose::OutboundAttachment)
}

pub(crate) fn cloud_sync_open_protected_attachment_upload(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
) -> Result<String, CloudNativeFetchFailure> {
    cloud_sync_open_protected_outbound_value(storage_directory, account_fingerprint, protected_reference,
        CloudNativeStream::Attachments, CloudNativeProtectionPurpose::OutboundAttachmentUpload)
}

pub(crate) fn cloud_sync_persist_ids_send_receipt(
    storage_directory: PathBuf,
    receipt: CloudNativeIdsSendReceipt,
) -> Result<CloudNativeIdsSendReceiptReplay, CloudNativeFetchFailure> {
    let store = PlatformCloudNativeProtectedStore::new(storage_directory);
    let receipt_id = store
        .persist_ids_send_receipt(&receipt)
        .map_err(map_store_failure)?;
    Ok(CloudNativeIdsSendReceiptReplay {
        receipt_id,
        guid_hash: receipt.guid_hash,
        native_session_id: receipt.native_session_id,
        source_binding: receipt.source_binding,
    })
}

pub(crate) fn cloud_sync_replay_ids_send_receipts(
    storage_directory: PathBuf,
    expected_account_fingerprint: &str,
    expected_protected_store_identity: &str,
    after_receipt_id: Option<&str>,
) -> Result<CloudNativeIdsSendReceiptReplayPage, CloudNativeFetchFailure> {
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .replay_ids_send_receipts(
            expected_account_fingerprint,
            expected_protected_store_identity,
            after_receipt_id,
        )
        .map_err(map_store_failure)
}

pub(crate) fn cloud_sync_acknowledge_ids_send_receipt(
    storage_directory: PathBuf,
    expected: &CloudNativeIdsSendReceiptReplay,
    expected_account_fingerprint: &str,
    expected_protected_store_identity: &str,
) -> Result<(), CloudNativeFetchFailure> {
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .acknowledge_ids_send_receipt(
            expected,
            expected_account_fingerprint,
            expected_protected_store_identity,
        )
        .map_err(map_store_failure)
}

fn cloud_sync_open_protected_outbound_value(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_reference: &str,
    stream: CloudNativeStream,
    purpose: CloudNativeProtectionPurpose,
) -> Result<String, CloudNativeFetchFailure> {
    let scope = CloudNativeProtectionScope::new(account_fingerprint, stream)?;
    let reference =
        CloudCanonicalProtectedReference::new(protected_reference.to_owned()).map_err(|_| {
            CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::LocalStorage,
                CloudNativeSafeCode::InvalidRequest,
                None,
            )
        })?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .unprotect(&scope, purpose, &reference)
        .map_err(map_store_failure)
}

pub(crate) fn cloud_sync_acknowledge_committed_page_lease(
    storage_directory: PathBuf,
    page_lease_reference: &str,
) -> Result<(), CloudNativeFetchFailure> {
    let lease = CloudNativePageLease::parse(page_lease_reference)?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .acknowledge_committed_lease(&lease)
        .map_err(map_store_failure)
}

pub(crate) fn cloud_sync_rollback_protected_page_lease(
    storage_directory: PathBuf,
    page_lease_reference: &str,
) -> Result<(), CloudNativeFetchFailure> {
    let lease = CloudNativePageLease::parse(page_lease_reference)?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .rollback_lease(&lease)
        .map_err(map_store_failure)
}

/// Bounded startup recovery. It must run before any fetch is in flight.
pub(crate) fn cloud_sync_recover_abandoned_page_leases(
    storage_directory: PathBuf,
    adopted_lease_references: &[String],
    live_references: &[String],
    live_reference_enumeration_complete: bool,
) -> Result<CloudNativeRecoverySummary, CloudNativeFetchFailure> {
    if !live_reference_enumeration_complete
        || adopted_lease_references.len() > MAX_ADOPTED_LEASES_PER_RECOVERY
        || adopted_lease_references.iter().any(|reference| {
            !reference.starts_with("obcs2.lease.")
                || reference.len() != "obcs2.lease.".len() + 32
                || !is_lease_token(&reference["obcs2.lease.".len()..])
        })
    {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    let adopted = adopted_lease_references
        .iter()
        .cloned()
        .collect::<HashSet<_>>();
    if adopted.len() != adopted_lease_references.len() {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    let live = parse_protected_reference_set(live_references)?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .recover_abandoned_leases(&adopted, &live, live_reference_enumeration_complete)
        .map_err(map_store_failure)
}

pub(crate) fn cloud_sync_retire_protected_references(
    storage_directory: PathBuf,
    references: &[String],
) -> Result<usize, CloudNativeFetchFailure> {
    if references.len() > MAX_RETIRE_REFERENCES_PER_CALL {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    let references = parse_protected_reference_set(references)?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .retire_references(&references)
        .map_err(map_store_failure)
}

pub(crate) fn cloud_sync_collect_protected_garbage(
    storage_directory: PathBuf,
    live_references: &[String],
    live_reference_enumeration_complete: bool,
) -> Result<CloudNativeGarbageCollectionSummary, CloudNativeFetchFailure> {
    if !live_reference_enumeration_complete {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    let live = parse_protected_reference_set(live_references)?;
    PlatformCloudNativeProtectedStore::new(storage_directory)
        .collect_garbage(&live, live_reference_enumeration_complete)
        .map_err(map_store_failure)
}

fn parse_protected_reference_set(
    references: &[String],
) -> Result<HashSet<String>, CloudNativeFetchFailure> {
    if references.len() > MAX_LIVE_REFERENCES_PER_MAINTENANCE {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    let unique = references.iter().cloned().collect::<HashSet<_>>();
    if unique.len() != references.len()
        || unique.iter().any(|reference| {
            reference
                .strip_prefix("obcs2.ref.")
                .is_none_or(|token| !is_bare_digest(token))
        })
    {
        return Err(CloudNativeFetchFailure::new(
            CloudNativeFailureCategory::LocalStorage,
            CloudNativeSafeCode::InvalidRequest,
            None,
        ));
    }
    Ok(unique)
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashMap,
        sync::{
            atomic::{AtomicBool, Ordering},
            Mutex,
        },
    };

    use prost::Message as _;
    use tempfile::tempdir;

    use super::*;

    #[derive(Default)]
    struct MemoryProtectedStore {
        values: Mutex<HashMap<String, (String, CloudNativeProtectionPurpose, String)>>,
        leases: Mutex<HashMap<String, Vec<String>>>,
        committed: Mutex<HashMap<String, HashSet<String>>>,
        fail_protection: AtomicBool,
    }

    impl MemoryProtectedStore {
        fn plaintexts(&self) -> Vec<String> {
            self.values
                .lock()
                .expect("values lock")
                .values()
                .map(|(_, _, value)| value.clone())
                .collect()
        }
    }

    impl CloudNativeProtectedStore for MemoryProtectedStore {
        fn protect_batch(
            &self,
            scope: &CloudNativeProtectionScope,
            values: &[CloudNativePlaintext],
        ) -> Result<CloudNativeProtectedBatch, CloudNativeStoreFailure> {
            if self.fail_protection.load(Ordering::SeqCst) {
                return Err(CloudNativeStoreFailure::ProtectionUnavailable);
            }
            let lease_token = Uuid::new_v4().simple().to_string();
            let lease = CloudNativePageLease {
                reference: CloudCanonicalProtectedReference::new(format!(
                    "obcs2.lease.{lease_token}"
                ))
                .expect("lease reference"),
            };
            let mut staged = Vec::with_capacity(values.len());
            for (index, value) in values.iter().enumerate() {
                let token = URL_SAFE_NO_PAD.encode(Sha256::digest(
                    format!(
                        "{}\u{1f}{}\u{1f}{}\u{1f}{}",
                        lease_token,
                        index,
                        value.purpose.value(),
                        value.value
                    )
                    .as_bytes(),
                ));
                let reference = CloudCanonicalProtectedReference::new(format!("obcs2.ref.{token}"))
                    .expect("protected reference");
                staged.push((
                    reference,
                    (scope.binding(), value.purpose, value.value.clone()),
                ));
            }
            let references = staged
                .iter()
                .map(|(reference, _)| reference.clone())
                .collect::<Vec<_>>();
            {
                let mut stored = self.values.lock().expect("values lock");
                for (reference, value) in staged {
                    stored.insert(reference.value().to_owned(), value);
                }
            }
            self.leases.lock().expect("leases lock").insert(
                lease.reference.value().to_owned(),
                references
                    .iter()
                    .map(|reference| reference.value().to_owned())
                    .collect(),
            );
            Ok(CloudNativeProtectedBatch { references, lease })
        }

        fn unprotect(
            &self,
            scope: &CloudNativeProtectionScope,
            purpose: CloudNativeProtectionPurpose,
            reference: &CloudCanonicalProtectedReference,
        ) -> Result<String, CloudNativeStoreFailure> {
            let values = self.values.lock().expect("values lock");
            let Some((binding, actual_purpose, value)) = values.get(reference.value()) else {
                return Err(CloudNativeStoreFailure::InvalidReference);
            };
            if binding != &scope.binding() || actual_purpose != &purpose {
                return Err(CloudNativeStoreFailure::ContextMismatch);
            }
            Ok(value.clone())
        }

        fn commit_lease(
            &self,
            lease: &CloudNativePageLease,
            retained_references: &HashSet<String>,
        ) -> Result<(), CloudNativeStoreFailure> {
            let references = self
                .leases
                .lock()
                .expect("leases lock")
                .remove(lease.reference.value());
            if let Some(references) = references {
                let manifest = references.iter().cloned().collect::<HashSet<_>>();
                if !manifest.is_superset(retained_references) {
                    return Err(CloudNativeStoreFailure::InvalidReference);
                }
                let mut values = self.values.lock().expect("values lock");
                for reference in manifest.difference(retained_references) {
                    values.remove(reference);
                }
                self.committed.lock().expect("committed lock").insert(
                    lease.reference.value().to_owned(),
                    retained_references.clone(),
                );
                return Ok(());
            }
            if self
                .committed
                .lock()
                .expect("committed lock")
                .get(lease.reference.value())
                == Some(retained_references)
            {
                return Ok(());
            }
            Err(CloudNativeStoreFailure::InvalidReference)
        }

        fn acknowledge_committed_lease(
            &self,
            lease: &CloudNativePageLease,
        ) -> Result<(), CloudNativeStoreFailure> {
            self.committed
                .lock()
                .expect("committed lock")
                .remove(lease.reference.value());
            Ok(())
        }

        fn rollback_lease(
            &self,
            lease: &CloudNativePageLease,
        ) -> Result<(), CloudNativeStoreFailure> {
            let references = self
                .leases
                .lock()
                .expect("leases lock")
                .remove(lease.reference.value())
                .ok_or(CloudNativeStoreFailure::InvalidReference)?;
            let mut values = self.values.lock().expect("values lock");
            for reference in references {
                values.remove(&reference);
            }
            Ok(())
        }

        fn recover_abandoned_leases(
            &self,
            adopted_lease_references: &HashSet<String>,
            live_references: &HashSet<String>,
            live_reference_enumeration_complete: bool,
        ) -> Result<CloudNativeRecoverySummary, CloudNativeStoreFailure> {
            if !live_reference_enumeration_complete {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            let leases = self
                .leases
                .lock()
                .expect("leases lock")
                .iter()
                .map(|(lease, references)| (lease.clone(), references.clone()))
                .collect::<Vec<_>>();
            let present_leases = leases
                .iter()
                .map(|(lease, _)| lease.clone())
                .collect::<HashSet<_>>();
            let mut summary = CloudNativeRecoverySummary::default();
            let mut values = self.values.lock().expect("values lock");
            for (lease, references) in leases {
                if adopted_lease_references.contains(&lease) {
                    let retained = references
                        .iter()
                        .filter(|reference| live_references.contains(*reference))
                        .cloned()
                        .collect::<HashSet<_>>();
                    for reference in references
                        .iter()
                        .filter(|reference| !retained.contains(*reference))
                    {
                        values.remove(reference);
                    }
                    self.committed
                        .lock()
                        .expect("committed lock")
                        .insert(lease.clone(), retained);
                    summary.finalized_adopted_lease_references.push(
                        CloudCanonicalProtectedReference::new(lease)
                            .expect("memory lease reference"),
                    );
                } else {
                    for reference in references {
                        values.remove(&reference);
                    }
                    summary.rolled_back += 1;
                }
            }
            summary.absent_adopted_lease_references = adopted_lease_references
                .iter()
                .filter(|reference| !present_leases.contains(*reference))
                .map(|reference| {
                    CloudCanonicalProtectedReference::new(reference.clone())
                        .expect("memory recovery fixture uses canonical lease references")
                })
                .collect();
            self.leases.lock().expect("leases lock").clear();
            Ok(summary)
        }

        fn retire_references(
            &self,
            references: &HashSet<String>,
        ) -> Result<usize, CloudNativeStoreFailure> {
            let mut values = self.values.lock().expect("values lock");
            let mut removed = 0;
            for reference in references {
                if values.remove(reference).is_some() {
                    removed += 1;
                }
            }
            Ok(removed)
        }

        fn collect_garbage(
            &self,
            live_references: &HashSet<String>,
            live_reference_enumeration_complete: bool,
        ) -> Result<CloudNativeGarbageCollectionSummary, CloudNativeStoreFailure> {
            if !live_reference_enumeration_complete {
                return Err(CloudNativeStoreFailure::InvalidReference);
            }
            let values = self.values.lock().expect("values lock");
            Ok(CloudNativeGarbageCollectionSummary {
                scanned: values.len(),
                preserved_live: values
                    .keys()
                    .filter(|reference| live_references.contains(*reference))
                    .count(),
                ..CloudNativeGarbageCollectionSummary::default()
            })
        }
    }

    fn scope(stream: CloudNativeStream) -> CloudNativeProtectionScope {
        CloudNativeProtectionScope::new(
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_owned(),
            stream,
        )
        .expect("scope")
    }

    #[test]
    fn auxiliary_streams_roundtrip_parse_tag_and_zone() {
        let cases = [
            (CloudNativeStream::Chats, 1u8, "chatManateeZone", "chats"),
            (
                CloudNativeStream::Messages,
                2u8,
                "messageManateeZone",
                "messages",
            ),
            (
                CloudNativeStream::Attachments,
                3u8,
                "attachmentManateeZone",
                "attachments",
            ),
            (
                CloudNativeStream::MessageUpdate,
                4u8,
                "messageUpdateZone",
                "messageUpdateZone",
            ),
            (
                CloudNativeStream::RecoverableMessageDelete,
                5u8,
                "recoverableMessageDeleteZone",
                "recoverableMessageDeleteZone",
            ),
            (
                CloudNativeStream::ScheduledMessage,
                6u8,
                "scheduledMessageZone",
                "scheduledMessageZone",
            ),
            (
                CloudNativeStream::Chat1,
                7u8,
                "chat1ManateeZone",
                "chat1ManateeZone",
            ),
        ];

        for (stream, tag, zone, parsed_zone) in cases {
            assert_eq!(stream.tag(), tag);
            assert_eq!(stream.zone(), zone);
            assert_eq!(CloudNativeStream::from_tag(tag), Some(stream));
            assert_eq!(CloudNativeStream::parse(parsed_zone), Some(stream));
        }
        assert_eq!(CloudNativeStream::parse("futureZone"), None);
        assert_eq!(CloudNativeStream::from_tag(8), None);
    }

    fn change(name: &str, raw: Vec<u8>) -> CloudMessageRecordPageChange {
        CloudMessageRecordPageChange {
            record_name: Some(name.to_owned()),
            record_type: Some("Message".to_owned()),
            change_type: Some(1),
            system_fields: Some(CloudMessageRecordSystemFields {
                etag: Some(format!("etag-{name}")),
                created_at: Some(1.0),
                modified_at: Some(2.0),
                permission: Some(1),
            }),
            encrypted_record: Some(raw),
            tombstone_payload: None,
            kind: CloudMessageRecordKind::EncryptedUpsert,
        }
    }

    fn request<'a>(
        scope: &'a CloudNativeProtectionScope,
        checkpoint: Option<&'a str>,
    ) -> CloudNativeFetchRequest<'a> {
        CloudNativeFetchRequest {
            stream: CloudNativeStream::Messages,
            scope,
            generation: 7,
            previous_checkpoint_reference: checkpoint,
            maximum_changes: 50,
        }
    }

    fn hasher() -> CloudSemanticIdentifierHasher {
        CloudSemanticIdentifierHasher::new(b"native-fetch-test-key").expect("hasher")
    }

    #[test]
    fn protected_page_exposes_only_canonical_identifiers_lengths_and_references() {
        let store = MemoryProtectedStore::default();
        let scope = scope(CloudNativeStream::Messages);
        let page = CloudMessageRecordPage {
            changes: vec![change("RAW-RECORD-NAME", b"RAW-SERVER-ENVELOPE".to_vec())],
            next_token: Some(b"RAW-CONTINUATION".to_vec()),
            status: 2,
        };
        let outcome = protect_native_page(&store, &hasher(), &request(&scope, None), page);
        let CloudNativeProtectedFetchOutcome::Page(page) = outcome else {
            panic!("expected protected page");
        };
        assert_eq!(page.changes.len(), 1);
        let protected = &page.changes[0];
        assert!(is_bare_digest(protected.change_id()));
        assert!(is_bare_digest(protected.record_id_hash()));
        assert!(is_bare_digest(protected.etag_hash().expect("etag hash")));
        assert_eq!(protected.payload_digest.value().len(), 64);
        assert!(protected
            .protected_record_identity_reference()
            .starts_with("obcs2.ref."));
        assert!(protected
            .protected_raw_envelope_reference()
            .starts_with("obcs2.ref."));
        assert_ne!(
            protected.protected_record_identity_reference(),
            protected.protected_raw_envelope_reference()
        );
        let safe_debug = format!("{page:?}");
        for secret in [
            "RAW-RECORD-NAME",
            "RAW-SERVER-ENVELOPE",
            "RAW-CONTINUATION",
            "etag-RAW-RECORD-NAME",
        ] {
            assert!(!safe_debug.contains(secret));
        }
        let protected_plaintexts = store.plaintexts().join("|");
        assert!(!safe_debug.contains(&protected_plaintexts));
        assert!(store.plaintexts().iter().any(|value| {
            URL_SAFE_NO_PAD.decode(value).is_ok_and(|decoded| {
                decoded
                    .windows(b"RAW-RECORD-NAME".len())
                    .any(|window| window == b"RAW-RECORD-NAME")
            })
        }));
    }

    #[test]
    fn missing_record_identity_is_stable_when_server_page_order_changes() {
        fn malformed_changes() -> (CloudMessageRecordPageChange, CloudMessageRecordPageChange) {
            let mut missing = change("ignored-missing", b"malformed-missing".to_vec());
            missing.record_name = None;
            let mut empty = change("ignored-empty", b"malformed-empty".to_vec());
            empty.record_name = Some(String::new());
            (missing, empty)
        }

        fn protected_identity_by_payload(
            page: CloudNativeProtectedPage,
        ) -> Vec<(String, String, String)> {
            let mut identities = page
                .changes
                .into_iter()
                .map(|change| {
                    (
                        change.payload_digest.value().to_owned(),
                        change.record_id_hash().to_owned(),
                        change.change_id().to_owned(),
                    )
                })
                .collect::<Vec<_>>();
            identities.sort();
            identities
        }

        let scope = scope(CloudNativeStream::Messages);
        let (missing, empty) = malformed_changes();

        let first = protect_native_page(
            &MemoryProtectedStore::default(),
            &hasher(),
            &request(&scope, None),
            CloudMessageRecordPage {
                changes: vec![missing, empty],
                next_token: None,
                status: 3,
            },
        );
        let (missing, empty) = malformed_changes();
        let second = protect_native_page(
            &MemoryProtectedStore::default(),
            &hasher(),
            &request(&scope, None),
            CloudMessageRecordPage {
                changes: vec![empty, missing],
                next_token: None,
                status: 3,
            },
        );
        let CloudNativeProtectedFetchOutcome::Page(first) = first else {
            panic!("expected first protected page");
        };
        let CloudNativeProtectedFetchOutcome::Page(second) = second else {
            panic!("expected reordered protected page");
        };

        assert!(first.changes.iter().all(|change| {
            change.kind() == CloudNativeChangeKind::Quarantined
                && change.preflight_code() == Some(CloudNativePreflightCode::MalformedMetadata)
        }));
        assert_eq!(
            protected_identity_by_payload(first),
            protected_identity_by_payload(second)
        );
    }

    #[test]
    fn protection_failure_returns_no_partial_page_or_values() {
        let store = MemoryProtectedStore::default();
        store.fail_protection.store(true, Ordering::SeqCst);
        let scope = scope(CloudNativeStream::Messages);
        let outcome = protect_native_page(
            &store,
            &hasher(),
            &request(&scope, None),
            CloudMessageRecordPage {
                changes: vec![change("one", vec![1]), change("two", vec![2])],
                next_token: None,
                status: 3,
            },
        );
        assert_eq!(
            outcome,
            CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::LocalStorage,
                CloudNativeSafeCode::ProtectionFailed,
                None,
            ))
        );
        assert!(store.plaintexts().is_empty());
    }

    #[test]
    fn checkpoint_is_bound_to_scope_generation_and_stream() {
        let store = MemoryProtectedStore::default();
        let message_scope = scope(CloudNativeStream::Messages);
        let plaintext = CloudNativePlaintext {
            purpose: CloudNativeProtectionPurpose::CheckpointToken,
            value: encode_checkpoint(7, CloudNativeStream::Messages, b"token").expect("encode"),
        };
        let batch = store
            .protect_batch(&message_scope, &[plaintext])
            .expect("protect checkpoint");
        let reference = batch.references[0].value().to_owned();
        assert_eq!(
            store.unprotect(
                &message_scope,
                CloudNativeProtectionPurpose::RawRecord,
                &batch.references[0],
            ),
            Err(CloudNativeStoreFailure::ContextMismatch)
        );

        let attachment_scope = scope(CloudNativeStream::Attachments);
        let wrong_scope_request = CloudNativeFetchRequest {
            stream: CloudNativeStream::Attachments,
            scope: &attachment_scope,
            generation: 7,
            previous_checkpoint_reference: Some(&reference),
            maximum_changes: 50,
        };
        assert_eq!(
            decode_previous_checkpoint(&store, &wrong_scope_request),
            Err(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::LocalStorage,
                CloudNativeSafeCode::CheckpointContextMismatch,
                None,
            ))
        );

        let wrong_generation = CloudNativeFetchRequest {
            generation: 8,
            ..request(&message_scope, Some(&reference))
        };
        assert_eq!(
            decode_previous_checkpoint(&store, &wrong_generation),
            Err(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::LocalStorage,
                CloudNativeSafeCode::InvalidCheckpoint,
                None,
            ))
        );
    }

    #[test]
    fn page_and_record_bounds_are_enforced_before_raw_values_escape() {
        let store = MemoryProtectedStore::default();
        let scope = scope(CloudNativeStream::Messages);
        let too_many = CloudMessageRecordPage {
            changes: (0..=MAX_CHANGES_PER_PAGE)
                .map(|index| change(&format!("record-{index}"), vec![1]))
                .collect(),
            next_token: None,
            status: 3,
        };
        assert_eq!(
            protect_native_page(&store, &hasher(), &request(&scope, None), too_many),
            CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::OversizedPage,
                None,
            ))
        );

        let oversized = CloudMessageRecordPage {
            changes: vec![change("large", vec![7; MAX_RAW_RECORD_BYTES + 1])],
            next_token: None,
            status: 3,
        };
        let CloudNativeProtectedFetchOutcome::Page(page) =
            protect_native_page(&store, &hasher(), &request(&scope, None), oversized)
        else {
            panic!("oversized individual record must be quarantined");
        };
        assert_eq!(
            page.changes[0].preflight_code,
            Some(CloudNativePreflightCode::OversizedRecord)
        );
        assert_eq!(page.changes[0].kind, CloudNativeChangeKind::Quarantined);

        let aggregate_store = MemoryProtectedStore::default();
        let aggregate = CloudMessageRecordPage {
            changes: (0..3)
                .map(|index| change(&format!("aggregate-{index}"), vec![9; MAX_RAW_RECORD_BYTES]))
                .collect(),
            next_token: None,
            status: 3,
        };
        assert_eq!(
            protect_native_page(
                &aggregate_store,
                &hasher(),
                &request(&scope, None),
                aggregate,
            ),
            CloudNativeProtectedFetchOutcome::Failure(CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::OversizedPage,
                None,
            ))
        );
        assert!(aggregate_store.plaintexts().is_empty());
    }

    #[test]
    fn lease_reference_parser_accepts_only_canonical_safe_grammar() {
        assert!(
            CloudNativePageLease::parse("obcs2.lease.0123456789abcdef0123456789abcdef").is_ok()
        );
        for invalid in [
            "obcs2.lease.0123456789ABCDEF0123456789ABCDEF",
            "obcs2.lease.short",
            "obcs2.ref.0123456789abcdef0123456789abcdef",
            "raw-record-name",
        ] {
            assert_eq!(
                CloudNativePageLease::parse(invalid),
                Err(CloudNativeFetchFailure::new(
                    CloudNativeFailureCategory::LocalStorage,
                    CloudNativeSafeCode::InvalidRequest,
                    None,
                ))
            );
        }
    }

    #[test]
    fn retry_after_and_protocol_failures_map_to_fixed_codes() {
        let throttled = PushError::CloudKitHttpError {
            status: 429,
            retry_after: Some(Duration::from_secs(91)),
        };
        assert_eq!(
            map_fetch_failure(&throttled),
            CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::Throttled,
                CloudNativeSafeCode::HttpThrottled,
                Some(91),
            )
        );
        assert_eq!(
            map_fetch_failure(&PushError::CloudKitProtocolError(
                CloudKitProtocolError::ContinuationTokenNoProgress,
            )),
            CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::ContinuationNoProgress,
                None,
            )
        );
        assert_eq!(
            retry_after_seconds(&PushError::CloudKitHttpError {
                status: 429,
                retry_after: Some(Duration::from_secs(MAX_RETRY_AFTER_SECONDS + 1)),
            }),
            Some(MAX_RETRY_AFTER_SECONDS),
        );
    }

    #[test]
    fn fetched_record_roundtrips_through_protect_unprotect_and_raw_decode() {
        let store = MemoryProtectedStore::default();
        let scope = scope(CloudNativeStream::Messages);
        let raw_record = rustpush::cloudkit_proto::Record {
            r#type: Some(rustpush::cloudkit_proto::record::Type {
                name: Some("Message".to_owned()),
            }),
            ..Default::default()
        }
        .encode_to_vec();
        let page = CloudMessageRecordPage {
            changes: vec![change("faithful-fake-message", raw_record.clone())],
            next_token: None,
            status: 3,
        };

        let CloudNativeProtectedFetchOutcome::Page(protected_page) =
            protect_native_page(&store, &hasher(), &request(&scope, None), page)
        else {
            panic!("expected protected page");
        };
        let raw_reference = CloudCanonicalProtectedReference::new(
            protected_page.changes[0]
                .protected_raw_envelope_reference()
                .to_owned(),
        )
        .expect("protected raw reference");
        let protected_plaintext = store
            .unprotect(
                &scope,
                CloudNativeProtectionPurpose::RawRecord,
                &raw_reference,
            )
            .expect("unprotect raw envelope");
        let envelope = decode_raw_envelope(
            &protected_plaintext,
            request(&scope, None).generation,
            CloudNativeStream::Messages,
        )
        .expect("decode raw envelope");

        assert_eq!(envelope.record_name(), Some("faithful-fake-message"));
        assert_eq!(envelope.record_type(), Some("Message"));
        assert_eq!(envelope.raw(), Some(raw_record.as_slice()));
        let decoded_record =
            rustpush::cloudkit_proto::Record::decode(envelope.raw().expect("raw record protobuf"))
                .expect("decode record protobuf");
        assert_eq!(
            decoded_record
                .r#type
                .as_ref()
                .and_then(|record_type| record_type.name.as_deref()),
            Some("Message")
        );
    }

    #[test]
    fn structured_cloudkit_state_failures_map_to_distinct_content_free_codes() {
        let token_expired = map_fetch_failure(&PushError::CloudKitChangeTokenExpired);
        assert_eq!(
            token_expired,
            CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::Unknown,
                CloudNativeSafeCode::CloudKitResetRequired,
                None,
            )
        );

        let warm_auth = map_fetch_failure(&PushError::CloudKitWarmAuthenticationRequired);
        assert_eq!(
            warm_auth,
            CloudNativeFetchFailure::new(
                CloudNativeFailureCategory::Authorization,
                CloudNativeSafeCode::CloudKitAuthorization,
                None,
            )
        );

        assert_ne!(token_expired, warm_auth);
        for rendered in [format!("{token_expired:?}"), format!("{warm_auth:?}")] {
            assert!(!rendered.contains("private-message-sentinel"));
            assert!(!rendered.contains("dsid-sentinel"));
            assert!(!rendered.contains("token-sentinel"));
        }
    }

    #[test]
    fn reset_failure_protects_only_bound_content_free_evidence() {
        let store = MemoryProtectedStore::default();
        let scope = scope(CloudNativeStream::Messages);
        let prior_token = URL_SAFE_NO_PAD.encode(Sha256::digest(b"prior-checkpoint"));
        let prior_reference = format!("obcs2.ref.{prior_token}");
        let request = request(&scope, Some(&prior_reference));

        let failure = protect_reset_failure(
            &store,
            &request,
            &PushError::CloudKitChangeTokenExpired,
        );

        assert_eq!(
            failure.safe_code(),
            CloudNativeSafeCode::CloudKitResetRequired
        );
        let proof_reference = failure
            .protected_reset_proof_reference()
            .expect("protected reset proof");
        assert!(!format!("{failure:?}").contains(proof_reference));
        let reference = CloudCanonicalProtectedReference::new(proof_reference.to_owned())
            .expect("canonical proof reference");
        assert_eq!(
            store.unprotect(
                &scope,
                CloudNativeProtectionPurpose::CheckpointToken,
                &reference,
            ),
            Err(CloudNativeStoreFailure::ContextMismatch)
        );
        let protected_plaintext = store
            .unprotect(
                &scope,
                CloudNativeProtectionPurpose::ResetProof,
                &reference,
            )
            .expect("bound reset proof");
        let decoded = URL_SAFE_NO_PAD
            .decode(protected_plaintext)
            .expect("decode reset proof");
        assert!(decoded.starts_with(RESET_PROOF_MAGIC));
        let mut cursor = NativeByteCursor::new(&decoded[RESET_PROOF_MAGIC.len()..]);
        assert_eq!(cursor.u16(), Some(FORMAT_VERSION));
        assert_eq!(cursor.u64(), Some(7));
        assert_eq!(cursor.byte(), Some(CloudNativeStream::Messages.tag()));
        assert_eq!(cursor.byte(), Some(1));
        assert_eq!(
            cursor.take(32),
            Some(Sha256::digest(prior_reference.as_bytes()).as_slice())
        );
        assert!(cursor.finished());
        assert!(!decoded
            .windows(prior_reference.len())
            .any(|window| window == prior_reference.as_bytes()));
        assert!(store.leases.lock().expect("leases lock").is_empty());
        assert!(store.committed.lock().expect("committed lock").is_empty());

        let ordinary = protect_reset_failure(&store, &request, &PushError::BadMsg);
        assert_eq!(ordinary.safe_code(), CloudNativeSafeCode::MalformedResponse);
        assert!(ordinary.protected_reset_proof_reference().is_none());
        assert_eq!(store.plaintexts().len(), 1);
    }

    #[test]
    fn platform_store_persists_a_reset_proof_with_the_production_protector() {
        let directory = tempdir().expect("temporary protected store");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let scope = scope(CloudNativeStream::Messages);
        let request = request(&scope, None);

        let failure = protect_reset_failure(
            &store,
            &request,
            &PushError::CloudKitChangeTokenExpired,
        );

        let reference = CloudCanonicalProtectedReference::new(
            failure
                .protected_reset_proof_reference()
                .expect("production-protected reset proof")
                .to_owned(),
        )
        .expect("canonical reset proof reference");
        let plaintext = store
            .unprotect(
                &scope,
                CloudNativeProtectionPurpose::ResetProof,
                &reference,
            )
            .expect("unprotect production reset proof");
        let decoded = URL_SAFE_NO_PAD
            .decode(plaintext)
            .expect("decode production reset proof");
        assert!(decoded.starts_with(RESET_PROOF_MAGIC));
        assert!(!format!("{failure:?}").contains(reference.value()));
    }

    #[test]
    fn known_semantic_read_failures_do_not_collapse_to_bare_unknown() {
        let cases = [
            (
                PushError::AnisetteError(rustpush::AnisetteError::AnisetteNotProvisioned),
                CloudNativeFailureCategory::Authorization,
                CloudNativeSafeCode::NativeAuthUnavailable,
            ),
            (
                PushError::AnisetteError(rustpush::AnisetteError::ProvisioningServerError(
                    "private-message-sentinel".to_owned(),
                )),
                CloudNativeFailureCategory::Server,
                CloudNativeSafeCode::HttpServer,
            ),
            (
                PushError::CloudKitSemanticOperationDenied,
                CloudNativeFailureCategory::Authorization,
                CloudNativeSafeCode::ReadAuthenticationScope,
            ),
            (
                PushError::BadMsg,
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::MalformedResponse,
            ),
            (
                PushError::PCSCiphertextMalformed,
                CloudNativeFailureCategory::MalformedRecord,
                CloudNativeSafeCode::MalformedResponse,
            ),
            (
                PushError::PCSKeyIdMismatch,
                CloudNativeFailureCategory::PcsUnavailable,
                CloudNativeSafeCode::PcsUnavailable,
            ),
            (
                PushError::PCSDecryptionFailed,
                CloudNativeFailureCategory::PcsUnavailable,
                CloudNativeSafeCode::PcsUnavailable,
            ),
        ];

        for (error, expected_category, expected_safe_code) in cases {
            let failure = map_fetch_failure(&error);
            assert_eq!(failure.category(), expected_category);
            assert_eq!(failure.safe_code(), expected_safe_code);
            assert_ne!(failure.safe_code(), CloudNativeSafeCode::Unknown);
            let rendered = format!("{failure:?}");
            assert!(!rendered.contains("private-message-sentinel"));
            assert!(!rendered.contains("dsid-sentinel"));
            assert!(!rendered.contains("token-sentinel"));
        }
    }

    #[test]
    fn journal_rejection_rolls_back_all_new_files_and_manifest() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["protected-one".to_owned(), "protected-two".to_owned()])
            .expect("persist protected batch");
        let paths = batch
            .references
            .iter()
            .map(|reference| store.reference_path(reference).expect("reference path"))
            .collect::<Vec<_>>();
        assert!(paths.iter().all(|path| path.is_file()));
        assert!(store
            .lease_path(&batch.lease)
            .expect("lease path")
            .is_file());

        cloud_sync_rollback_protected_page_lease(
            directory.path().to_path_buf(),
            batch.lease.value(),
        )
        .expect("rollback by safe lease reference");
        cloud_sync_rollback_protected_page_lease(
            directory.path().to_path_buf(),
            batch.lease.value(),
        )
        .expect("idempotent rollback");
        assert!(paths.iter().all(|path| !path.exists()));
        assert!(!store.lease_path(&batch.lease).expect("lease path").exists());
    }

    #[test]
    fn crash_recovery_is_bounded_and_removes_only_abandoned_lease_files() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["protected-after-crash".to_owned()])
            .expect("persist protected batch");
        let protected_path = store
            .reference_path(&batch.references[0])
            .expect("reference path");
        drop(store);

        let reopened = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        assert_eq!(
            reopened
                .recover_abandoned_leases(&HashSet::new(), &HashSet::new(), true)
                .expect("recover"),
            CloudNativeRecoverySummary {
                finalized_adopted_lease_references: vec![],
                absent_adopted_lease_references: vec![],
                rolled_back: 1,
                removed_temporary_files: 0,
                has_more: false,
            }
        );
        assert!(!protected_path.exists());
        assert_eq!(
            reopened
                .recover_abandoned_leases(&HashSet::new(), &HashSet::new(), true)
                .expect("idempotent"),
            CloudNativeRecoverySummary::default()
        );
    }

    #[test]
    fn journal_committed_before_native_commit_preserves_adopted_files() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["journal-adopted-value".to_owned()])
            .expect("persist protected batch");
        let protected_path = store
            .reference_path(&batch.references[0])
            .expect("reference path");
        let adopted = HashSet::from([batch.lease.value().to_owned()]);
        let live = HashSet::from([batch.references[0].value().to_owned()]);
        drop(store);

        let reopened = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        assert_eq!(
            reopened
                .recover_abandoned_leases(&adopted, &live, true)
                .expect("recover adopted lease"),
            CloudNativeRecoverySummary {
                finalized_adopted_lease_references: vec![batch.lease.reference.clone()],
                absent_adopted_lease_references: vec![],
                rolled_back: 0,
                removed_temporary_files: 0,
                has_more: false,
            }
        );
        assert!(protected_path.is_file());
        assert!(!reopened
            .lease_path(&batch.lease)
            .expect("lease path")
            .exists());
    }

    #[test]
    fn recovery_never_rolls_back_an_unmarked_manifest_still_named_by_objectbox() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["unexpected-live-unmarked-value".to_owned()])
            .expect("persist protected batch");
        let live = HashSet::from([batch.references[0].value().to_owned()]);
        let path = store
            .reference_path(&batch.references[0])
            .expect("protected path");

        assert!(matches!(
            store.recover_abandoned_leases(&HashSet::new(), &live, true),
            Err(CloudNativeStoreFailure::InvalidReference)
        ));
        assert!(path.is_file());
        assert!(store
            .lease_path(&batch.lease)
            .expect("lease path")
            .is_file());
    }

    #[test]
    fn adopted_recovery_over_sixty_four_manifests_is_exact_and_repeatable() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batches = (0..(MAX_RECOVERY_MANIFESTS_PER_PASS + 1))
            .map(|index| {
                store
                    .persist_batch(&[format!("adopted-value-{index}")])
                    .expect("persist adopted batch")
            })
            .collect::<Vec<_>>();
        let adopted = batches
            .iter()
            .map(|batch| batch.lease.value().to_owned())
            .collect::<HashSet<_>>();
        let protected_paths = batches
            .iter()
            .map(|batch| {
                store
                    .reference_path(&batch.references[0])
                    .expect("protected path")
            })
            .collect::<Vec<_>>();
        let live = batches
            .iter()
            .map(|batch| batch.references[0].value().to_owned())
            .collect::<HashSet<_>>();

        let first = store
            .recover_abandoned_leases(&adopted, &live, true)
            .expect("first bounded recovery");
        assert_eq!(
            first.finalized_adopted_lease_references.len(),
            MAX_RECOVERY_MANIFESTS_PER_PASS
        );
        assert_eq!(first.rolled_back, 0);
        assert!(first.has_more);

        let mut remaining_adopted = adopted.clone();
        for reference in &first.finalized_adopted_lease_references {
            remaining_adopted.remove(reference.value());
            let lease = CloudNativePageLease {
                reference: reference.clone(),
            };
            store
                .acknowledge_committed_lease(&lease)
                .expect("ack finalized recovery receipt");
        }
        let second = store
            .recover_abandoned_leases(&remaining_adopted, &live, true)
            .expect("second bounded recovery");
        assert_eq!(second.finalized_adopted_lease_references.len(), 1);
        assert!(second.absent_adopted_lease_references.is_empty());
        assert_eq!(second.rolled_back, 0);
        assert!(!second.has_more);
        assert!(protected_paths.iter().all(|path| path.is_file()));
    }

    #[test]
    fn temporary_only_recovery_over_sixty_four_files_reports_progress() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let store_directory = directory.path().join(STORE_DIRECTORY_NAME);
        let temporary_directory = store_directory.join(TEMPORARY_DIRECTORY_NAME);
        fs::create_dir_all(&temporary_directory).expect("temporary store directory");
        for index in 0..(MAX_RECOVERY_TEMPORARY_FILES_PER_PASS + 1) {
            fs::write(
                temporary_directory.join(format!(".tmp-progress-{index}.protected")),
                b"unadopted-temporary-data",
            )
            .expect("temporary recovery fixture");
        }

        let first = store
            .recover_abandoned_leases(&HashSet::new(), &HashSet::new(), true)
            .expect("first temporary recovery");
        assert_eq!(
            first.removed_temporary_files,
            MAX_RECOVERY_TEMPORARY_FILES_PER_PASS
        );
        assert!(first.has_more);
        assert!(first.finalized_adopted_lease_references.is_empty());
        assert!(first.absent_adopted_lease_references.is_empty());
        assert_eq!(first.rolled_back, 0);

        let second = store
            .recover_abandoned_leases(&HashSet::new(), &HashSet::new(), true)
            .expect("second temporary recovery");
        assert_eq!(second.removed_temporary_files, 1);
        assert!(!second.has_more);
        assert!(fs::read_dir(&temporary_directory)
            .expect("temporary directory remains readable")
            .next()
            .is_none());
    }

    #[test]
    fn recovery_handles_partial_blob_durability_without_exposing_a_page() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["durable-first".to_owned(), "missing-second".to_owned()])
            .expect("persist protected batch");
        let first = store
            .reference_path(&batch.references[0])
            .expect("first path");
        let second = store
            .reference_path(&batch.references[1])
            .expect("second path");
        fs::remove_file(&second).expect("simulate partial durability");
        let temporary = store
            .temporary_directory()
            .expect("temporary directory")
            .join(".tmp-crash-fixture.protected");
        fs::write(&temporary, b"partial-temporary-value").expect("temporary crash fixture");

        assert_eq!(
            store
                .recover_abandoned_leases(&HashSet::new(), &HashSet::new(), true)
                .expect("recover partial lease"),
            CloudNativeRecoverySummary {
                finalized_adopted_lease_references: vec![],
                absent_adopted_lease_references: vec![],
                rolled_back: 1,
                removed_temporary_files: 1,
                has_more: false,
            }
        );
        assert!(!first.exists());
        assert!(!second.exists());
        assert!(!temporary.exists());
        assert!(!store.lease_path(&batch.lease).expect("lease path").exists());
    }

    #[test]
    fn rollback_never_deletes_a_replaced_or_preexisting_file() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["original-protected-value".to_owned()])
            .expect("persist protected batch");
        let path = store
            .reference_path(&batch.references[0])
            .expect("reference path");
        fs::write(&path, b"pre-existing-replacement").expect("replace fixture");

        store.rollback_lease(&batch.lease).expect("rollback");
        assert_eq!(
            fs::read(&path).expect("replacement remains"),
            b"pre-existing-replacement"
        );
    }

    #[test]
    fn committed_lease_survives_later_recovery() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["adopted-protected-value".to_owned()])
            .expect("persist protected batch");
        let path = store
            .reference_path(&batch.references[0])
            .expect("reference path");

        let retained = vec![batch.references[0].value().to_owned()];
        cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(),
            batch.lease.value(),
            &retained,
        )
        .expect("commit by safe lease reference");
        cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(),
            batch.lease.value(),
            &retained,
        )
        .expect("idempotent commit");
        drop(store);
        let reopened = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let adopted = HashSet::from([batch.lease.value().to_owned()]);
        let live = HashSet::from([batch.references[0].value().to_owned()]);
        let recovery = reopened
            .recover_abandoned_leases(&adopted, &live, true)
            .expect("recover stale adoption marker");
        assert_eq!(
            recovery.finalized_adopted_lease_references,
            vec![batch.lease.reference.clone()]
        );
        assert!(recovery.absent_adopted_lease_references.is_empty());
        assert_eq!(recovery.rolled_back, 0);
        assert!(!recovery.has_more);
        assert!(path.is_file());

        reopened
            .acknowledge_committed_lease(&batch.lease)
            .expect("acknowledge receipt after marker release");
        let after_ack = reopened
            .recover_abandoned_leases(&adopted, &live, true)
            .expect("receipt acknowledgement is idempotent");
        assert_eq!(
            after_ack.absent_adopted_lease_references,
            vec![batch.lease.reference.clone()]
        );
    }

    #[test]
    fn outbound_submission_requires_an_exact_fully_committed_lease() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&[
                "retained-outbound-envelope".to_owned(),
                "unretained-fixture".to_owned(),
            ])
            .expect("persist protected batch");
        let retained = HashSet::from([batch.references[0].value().to_owned()]);

        assert!(matches!(
            store.verify_committed_lease_exact(&batch.lease, &retained),
            Err(CloudNativeStoreFailure::InvalidReference)
        ));

        store
            .commit_lease(&batch.lease, &retained)
            .expect("commit exact outbound capability");
        store
            .verify_committed_lease_exact(&batch.lease, &retained)
            .expect("verify committed outbound capability");

        let wrong = HashSet::from([batch.references[1].value().to_owned()]);
        assert!(matches!(
            store.verify_committed_lease_exact(&batch.lease, &wrong),
            Err(CloudNativeStoreFailure::InvalidReference)
        ));
        assert!(matches!(
            store.verify_committed_lease_exact(&batch.lease, &HashSet::new()),
            Err(CloudNativeStoreFailure::InvalidReference)
        ));
    }

    #[test]
    fn all_duplicate_page_commit_deletes_every_unretained_reference() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&[
                "duplicate-record-id".to_owned(),
                "duplicate-envelope".to_owned(),
                "duplicate-checkpoint".to_owned(),
            ])
            .expect("persist duplicate page");
        let paths = batch
            .references
            .iter()
            .map(|reference| store.reference_path(reference).expect("reference path"))
            .collect::<Vec<_>>();

        store
            .commit_lease(&batch.lease, &HashSet::new())
            .expect("commit exact empty retained subset");
        store
            .commit_lease(&batch.lease, &HashSet::new())
            .expect("repeat exact empty commit");

        assert!(paths.iter().all(|path| !path.exists()));
        assert!(!store.lease_path(&batch.lease).expect("lease path").exists());
        assert!(store
            .committed_lease_path(&batch.lease)
            .expect("receipt path")
            .is_file());
    }

    #[test]
    fn mixed_duplicate_page_commit_retains_only_the_exact_live_subset() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&[
                "duplicate-record".to_owned(),
                "new-record".to_owned(),
                "duplicate-checkpoint".to_owned(),
            ])
            .expect("persist mixed page");
        let retained = HashSet::from([batch.references[1].value().to_owned()]);
        let paths = batch
            .references
            .iter()
            .map(|reference| store.reference_path(reference).expect("reference path"))
            .collect::<Vec<_>>();

        store
            .commit_lease(&batch.lease, &retained)
            .expect("commit exact mixed subset");
        store
            .commit_lease(&batch.lease, &retained)
            .expect("repeat exact mixed commit");

        assert!(!paths[0].exists());
        assert!(paths[1].is_file());
        assert!(!paths[2].exists());
        assert!(matches!(
            store.commit_lease(&batch.lease, &HashSet::new()),
            Err(CloudNativeStoreFailure::InvalidReference)
        ));
    }

    #[test]
    fn replacing_checkpoint_retires_only_the_prior_reference() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let old = store
            .persist_batch(&["old-checkpoint".to_owned()])
            .expect("persist old checkpoint");
        let new = store
            .persist_batch(&["new-checkpoint".to_owned()])
            .expect("persist new checkpoint");
        let old_reference = old.references[0].value().to_owned();
        let new_reference = new.references[0].value().to_owned();
        let old_path = store
            .reference_path(&old.references[0])
            .expect("old checkpoint path");
        let new_path = store
            .reference_path(&new.references[0])
            .expect("new checkpoint path");

        store
            .commit_lease(&old.lease, &HashSet::from([old_reference.clone()]))
            .expect("commit old checkpoint");
        store
            .acknowledge_committed_lease(&old.lease)
            .expect("ack old checkpoint");
        store
            .commit_lease(&new.lease, &HashSet::from([new_reference]))
            .expect("commit new checkpoint");
        store
            .acknowledge_committed_lease(&new.lease)
            .expect("ack new checkpoint");

        assert_eq!(
            store
                .retire_references(&HashSet::from([old_reference]))
                .expect("retire prior checkpoint"),
            1
        );
        assert!(!old_path.exists());
        assert!(new_path.is_file());
    }

    #[test]
    fn crash_between_receipt_write_and_manifest_removal_reports_one_finalization() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["crash-window-value".to_owned()])
            .expect("persist crash window page");
        let entries = store
            .read_lease_entries(&store.lease_path(&batch.lease).expect("lease path"))
            .expect("read manifest");
        store
            .write_committed_receipt(&batch.lease, &entries)
            .expect("simulate durable receipt before manifest removal");
        let adopted = HashSet::from([batch.lease.value().to_owned()]);
        let live = HashSet::from([batch.references[0].value().to_owned()]);

        let recovery = store
            .recover_abandoned_leases(&adopted, &live, true)
            .expect("recover both manifest and receipt");

        assert_eq!(
            recovery.finalized_adopted_lease_references,
            vec![batch.lease.reference.clone()]
        );
        assert!(recovery.absent_adopted_lease_references.is_empty());
        assert!(!store.lease_path(&batch.lease).expect("lease path").exists());
        assert!(store
            .committed_lease_path(&batch.lease)
            .expect("receipt path")
            .is_file());
    }

    #[test]
    fn crash_after_marker_release_before_receipt_ack_leaks_safely_then_cleans_receipt() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["live-after-marker-release".to_owned()])
            .expect("persist page");
        let retained = HashSet::from([batch.references[0].value().to_owned()]);
        let path = store
            .reference_path(&batch.references[0])
            .expect("reference path");
        store
            .commit_lease(&batch.lease, &retained)
            .expect("commit before marker release");

        let recovery = store
            .recover_abandoned_leases(&HashSet::new(), &retained, true)
            .expect("startup without adoption marker");

        assert!(recovery.finalized_adopted_lease_references.is_empty());
        assert!(path.is_file());
        assert!(!store
            .committed_lease_path(&batch.lease)
            .expect("receipt path")
            .exists());
    }

    #[test]
    fn garbage_collection_preserves_active_lease_manifest_references() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["active-lease-value".to_owned()])
            .expect("persist active lease");
        let reference = &batch.references[0];
        let token = reference
            .value()
            .strip_prefix("obcs2.ref.")
            .expect("reference token");

        let first = store
            .collect_garbage_unlocked_at(&HashSet::new(), true, 10)
            .expect("scan active lease");
        let second = store
            .collect_garbage_unlocked_at(&HashSet::new(), true, 10 + GC_GRACE_PERIOD.as_secs())
            .expect("rescan active lease after grace");

        assert_eq!(first.preserved_active_lease, 1);
        assert_eq!(second.preserved_active_lease, 1);
        assert_eq!(first.deleted + second.deleted, 0);
        assert!(!store
            .gc_candidate_path(token)
            .expect("candidate path")
            .exists());
        assert!(store
            .reference_path(reference)
            .expect("protected path")
            .is_file());
    }

    #[test]
    fn incomplete_liveness_enumeration_fails_closed_without_marking() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["orphan-candidate".to_owned()])
            .expect("persist candidate");
        let retained = HashSet::from([batch.references[0].value().to_owned()]);
        store
            .commit_lease(&batch.lease, &retained)
            .expect("commit candidate");
        store
            .acknowledge_committed_lease(&batch.lease)
            .expect("ack candidate");
        let token = batch.references[0]
            .value()
            .strip_prefix("obcs2.ref.")
            .expect("reference token");

        assert!(matches!(
            store.collect_garbage_unlocked_at(&HashSet::new(), false, 10),
            Err(CloudNativeStoreFailure::InvalidReference)
        ));
        assert!(!store
            .gc_candidate_path(token)
            .expect("candidate path")
            .exists());
        assert!(store
            .reference_path(&batch.references[0])
            .expect("protected path")
            .is_file());
    }

    #[test]
    fn a_reference_becoming_live_clears_its_orphan_history() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let batch = store
            .persist_batch(&["temporarily-orphaned-value".to_owned()])
            .expect("persist candidate");
        let reference = batch.references[0].value().to_owned();
        let retained = HashSet::from([reference.clone()]);
        store
            .commit_lease(&batch.lease, &retained)
            .expect("commit candidate");
        store
            .acknowledge_committed_lease(&batch.lease)
            .expect("ack candidate");

        let first = store
            .collect_garbage_unlocked_at(&HashSet::new(), true, 10)
            .expect("first orphan observation");
        let live = store
            .collect_garbage_unlocked_at(&retained, true, 10 + GC_GRACE_PERIOD.as_secs())
            .expect("reference becomes live");
        let orphan_again = store
            .collect_garbage_unlocked_at(
                &HashSet::new(),
                true,
                10 + (GC_GRACE_PERIOD.as_secs() * 2),
            )
            .expect("fresh orphan history");

        assert_eq!(first.first_observed, 1);
        assert_eq!(live.preserved_live, 1);
        assert_eq!(orphan_again.first_observed, 1);
        assert_eq!(orphan_again.deleted, 0);
        assert!(store
            .reference_path(&batch.references[0])
            .expect("protected path")
            .is_file());
    }

    #[test]
    fn garbage_collection_over_sixty_four_references_makes_bounded_progress() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let mut paths = Vec::new();
        for index in 0..(MAX_GC_REFERENCES_PER_PASS + 1) {
            let batch = store
                .persist_batch(&[format!("bounded-gc-{index}")])
                .expect("persist bounded GC fixture");
            let retained = HashSet::from([batch.references[0].value().to_owned()]);
            paths.push(
                store
                    .reference_path(&batch.references[0])
                    .expect("protected path"),
            );
            store
                .commit_lease(&batch.lease, &retained)
                .expect("commit bounded GC fixture");
            store
                .acknowledge_committed_lease(&batch.lease)
                .expect("ack bounded GC fixture");
        }

        let first = store
            .collect_garbage_unlocked_at(&HashSet::new(), true, 100)
            .expect("first bounded mark page");
        let second = store
            .collect_garbage_unlocked_at(&HashSet::new(), true, 100)
            .expect("second bounded mark page");
        assert_eq!(first.scanned, MAX_GC_REFERENCES_PER_PASS);
        assert_eq!(first.first_observed, MAX_GC_REFERENCES_PER_PASS);
        assert!(first.has_more);
        assert_eq!(second.scanned, 1);
        assert_eq!(second.first_observed, 1);
        assert!(!second.has_more);
        assert!(paths.iter().all(|path| path.is_file()));

        let after_grace = 100 + GC_GRACE_PERIOD.as_secs();
        let third = store
            .collect_garbage_unlocked_at(&HashSet::new(), true, after_grace)
            .expect("first bounded sweep page");
        let fourth = store
            .collect_garbage_unlocked_at(&HashSet::new(), true, after_grace)
            .expect("second bounded sweep page");
        assert_eq!(third.deleted, MAX_GC_REFERENCES_PER_PASS);
        assert!(third.has_more);
        assert_eq!(fourth.deleted, 1);
        assert!(!fourth.has_more);
        assert!(paths.iter().all(|path| !path.exists()));
        assert!(fs::read_dir(store.gc_directory().expect("GC directory"))
            .expect("read GC directory")
            .all(|entry| {
                !entry
                    .expect("GC entry")
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".candidate-")
            }));
    }

    #[test]
    fn explicit_retirement_is_bounded_to_sixty_four_references() {
        let directory = tempdir().expect("temp directory");
        let references = (0..(MAX_RETIRE_REFERENCES_PER_CALL + 1))
            .map(|index| {
                let digest = URL_SAFE_NO_PAD.encode(Sha256::digest(index.to_le_bytes()));
                format!("obcs2.ref.{digest}")
            })
            .collect::<Vec<_>>();

        assert!(matches!(
            cloud_sync_retire_protected_references(directory.path().to_path_buf(), &references),
            Err(CloudNativeFetchFailure {
                safe_code: CloudNativeSafeCode::InvalidRequest,
                ..
            })
        ));
    }

    fn ids_send_receipt_fixture(
        directory: &Path,
        guid_hash: char,
        account_fingerprint: char,
        native_session_id: char,
    ) -> CloudNativeIdsSendReceipt {
        CloudNativeIdsSendReceipt {
            guid_hash: guid_hash.to_string().repeat(64),
            account_fingerprint: account_fingerprint.to_string().repeat(43),
            protected_store_identity: cloud_sync_protector::protected_store_identity(
                directory.to_string_lossy().into_owned(),
            )
            .expect("protected store identity"),
            native_session_id: native_session_id.to_string().repeat(43),
            source_binding: None,
        }
    }

    #[test]
    fn ids_send_receipt_persist_is_durable_and_idempotent() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let receipt = ids_send_receipt_fixture(directory.path(), 'a', 'A', 'N');

        let first = store
            .persist_ids_send_receipt(&receipt)
            .expect("persist first receipt");
        let second = store
            .persist_ids_send_receipt(&receipt)
            .expect("persist duplicate receipt");
        assert_eq!(first, second);
        assert!(store
            .ids_send_receipt_path(&first)
            .expect("receipt path")
            .is_file());
        let replayed = store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                None,
            )
            .expect("replay receipt")
            .receipts;
        assert_eq!(replayed.len(), 1);
        assert_eq!(replayed[0].receipt_id, first);
        assert_eq!(replayed[0].guid_hash, receipt.guid_hash);
        assert_eq!(replayed[0].native_session_id, receipt.native_session_id);
    }

    #[test]
    fn legacy_completion_only_receipt_is_retained_but_never_replayed_or_acknowledged() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let receipt = ids_send_receipt_fixture(directory.path(), 'a', 'A', 'N');
        let receipt_id = store.persist_ids_send_receipt(&receipt).unwrap();
        let path = store.ids_send_receipt_path(&receipt_id).unwrap();
        let mut legacy: serde_json::Value = serde_json::from_str(&receipt.encode().unwrap()).unwrap();
        legacy["version"] = serde_json::json!(1);
        assert!(CloudNativeIdsSendReceipt::decode(&legacy.to_string()).is_err());
        let scope = CloudNativeProtectionScope::new(
            receipt.account_fingerprint.clone(), CloudNativeStream::Messages,
        ).unwrap();
        let ciphertext = store.protect_one(&scope, &CloudNativePlaintext {
            purpose: CloudNativeProtectionPurpose::IdsSendReceipt,
            value: legacy.to_string(),
        }).unwrap();
        fs::write(&path, ciphertext.as_bytes()).unwrap();
        let page = store.replay_ids_send_receipts(
            &receipt.account_fingerprint, &receipt.protected_store_identity, None,
        ).unwrap();
        assert!(page.receipts.is_empty());
        let replay = CloudNativeIdsSendReceiptReplay {
            receipt_id, guid_hash: receipt.guid_hash.clone(),
            native_session_id: receipt.native_session_id.clone(),
            source_binding: None,
        };
        assert!(store.acknowledge_ids_send_receipt(
            &replay, &receipt.account_fingerprint, &receipt.protected_store_identity,
        ).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), ciphertext);
    }

    #[test]
    fn ids_send_receipt_wrong_identity_is_hidden_and_ack_fails_closed() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let receipt = ids_send_receipt_fixture(directory.path(), 'b', 'B', 'M');
        let receipt_id = store
            .persist_ids_send_receipt(&receipt)
            .expect("persist receipt");
        let replay = CloudNativeIdsSendReceiptReplay {
            receipt_id,
            guid_hash: receipt.guid_hash.clone(),
            native_session_id: receipt.native_session_id.clone(),
            source_binding: None,
        };

        assert!(store
            .replay_ids_send_receipts(
                &"C".repeat(43),
                &receipt.protected_store_identity,
                None,
            )
            .expect("foreign account is hidden")
            .receipts
            .is_empty());
        let wrong_session = CloudNativeIdsSendReceiptReplay {
            native_session_id: "Z".repeat(43),
            ..replay.clone()
        };
        assert_eq!(
            store.acknowledge_ids_send_receipt(
                &wrong_session,
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
            ),
            Err(CloudNativeStoreFailure::ContextMismatch)
        );
        assert_eq!(
            store
                .replay_ids_send_receipts(
                    &receipt.account_fingerprint,
                    &receipt.protected_store_identity,
                    None,
                )
                .expect("receipt retained")
                .receipts
                .len(),
            1
        );
    }

    #[test]
    fn ids_send_receipt_ack_is_exact_and_idempotent() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let receipt = ids_send_receipt_fixture(directory.path(), 'c', 'C', 'S');
        let receipt_id = store
            .persist_ids_send_receipt(&receipt)
            .expect("persist receipt");
        let replay = CloudNativeIdsSendReceiptReplay {
            receipt_id,
            guid_hash: receipt.guid_hash.clone(),
            native_session_id: receipt.native_session_id.clone(),
            source_binding: None,
        };

        store
            .acknowledge_ids_send_receipt(
                &replay,
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
            )
            .expect("ack receipt");
        store
            .acknowledge_ids_send_receipt(
                &replay,
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
            )
            .expect("duplicate ack");
        assert!(store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                None,
            )
            .expect("replay after ack")
            .receipts
            .is_empty());
    }

    fn ids_send_source_binding_fixture() -> CloudNativeIdsSendSourceBinding {
        CloudNativeIdsSendSourceBinding {
            source_sha256: "a".repeat(64),
            protected_reference: format!("obcs2.ref.{}", "A".repeat(43)),
            lease_reference: format!("obcs2.lease.{}", "b".repeat(32)),
            payload_sha256: "c".repeat(64),
            payload_length: 123,
        }
    }

    #[test]
    fn ids_send_receipt_source_binding_version_roundtrip() {
        let directory = tempdir().expect("temp directory");
        let bare = ids_send_receipt_fixture(directory.path(), 'f', 'F', 'R');
        let bare_encoded = bare.encode().expect("encode v2");
        let bare_value: serde_json::Value =
            serde_json::from_str(&bare_encoded).expect("parse v2");
        let bare_object = bare_value.as_object().expect("v2 object");
        assert_eq!(bare_object.len(), 5);
        assert_eq!(
            bare_object.get("version").and_then(serde_json::Value::as_u64),
            Some(2)
        );
        assert!(!bare_object.contains_key("sourceBinding"));
        let bare_decoded =
            CloudNativeIdsSendReceipt::decode(&bare_encoded).expect("decode v2");
        assert_eq!(bare_decoded.source_binding, None);
        assert_eq!(bare_decoded.guid_hash, bare.guid_hash);

        let mut bound = ids_send_receipt_fixture(directory.path(), 'f', 'F', 'R');
        bound.source_binding = Some(ids_send_source_binding_fixture());
        let bound_encoded = bound.encode().expect("encode v3");
        let bound_value: serde_json::Value =
            serde_json::from_str(&bound_encoded).expect("parse v3");
        let bound_object = bound_value.as_object().expect("v3 object");
        assert_eq!(bound_object.len(), 6);
        assert_eq!(
            bound_object.get("version").and_then(serde_json::Value::as_u64),
            Some(3)
        );
        assert!(bound_object.contains_key("sourceBinding"));
        let bound_decoded =
            CloudNativeIdsSendReceipt::decode(&bound_encoded).expect("decode v3");
        assert_eq!(bound_decoded.source_binding, bound.source_binding);
        assert_eq!(bound_decoded.guid_hash, bound.guid_hash);
    }

    #[test]
    fn ids_send_receipt_source_binding_rejects_invalid() {
        let directory = tempdir().expect("temp directory");
        let mut receipt = ids_send_receipt_fixture(directory.path(), 'f', 'F', 'R');
        receipt.source_binding = Some(ids_send_source_binding_fixture());
        let valid = receipt.encode().expect("valid v3 encodes");
        let valid_value: serde_json::Value =
            serde_json::from_str(&valid).expect("valid v3 parses");

        let mut bad_hash = ids_send_source_binding_fixture();
        bad_hash.source_sha256 = "A".repeat(64);
        assert!(bad_hash.validate().is_err());
        let mut bad_ref = ids_send_source_binding_fixture();
        bad_ref.protected_reference = format!("obcs2.ref.{}", "A".repeat(42));
        assert!(bad_ref.validate().is_err());
        let mut bad_lease = ids_send_source_binding_fixture();
        bad_lease.lease_reference = format!("obcs2.lease.{}", "B".repeat(32));
        assert!(bad_lease.validate().is_err());
        let mut bad_len = ids_send_source_binding_fixture();
        bad_len.payload_length = 0;
        assert!(bad_len.validate().is_err());
        let mut too_big = ids_send_source_binding_fixture();
        too_big.payload_length = MAX_IDS_SEND_SOURCE_PAYLOAD_BYTES + 1;
        assert!(too_big.validate().is_err());

        let mut v2_with_binding = valid_value.clone();
        v2_with_binding["version"] = serde_json::json!(2);
        assert!(CloudNativeIdsSendReceipt::decode(&v2_with_binding.to_string()).is_err());
        let mut v3_without_binding: serde_json::Value =
            serde_json::from_str(&ids_send_receipt_fixture(directory.path(), 'f', 'F', 'R').encode().unwrap()).unwrap();
        v3_without_binding["version"] = serde_json::json!(3);
        assert!(CloudNativeIdsSendReceipt::decode(&v3_without_binding.to_string()).is_err());
        let mut unknown_version = valid_value.clone();
        unknown_version["version"] = serde_json::json!(4);
        assert!(CloudNativeIdsSendReceipt::decode(&unknown_version.to_string()).is_err());
        let mut extra_key = valid_value.clone();
        extra_key["extra"] = serde_json::json!(1);
        assert!(CloudNativeIdsSendReceipt::decode(&extra_key.to_string()).is_err());
        let mut extra_nested = valid_value.clone();
        extra_nested["sourceBinding"]["extra"] = serde_json::json!(1);
        assert!(CloudNativeIdsSendReceipt::decode(&extra_nested.to_string()).is_err());
        let mut bad_nested = valid_value.clone();
        bad_nested["sourceBinding"]["payload_length"] = serde_json::json!(0);
        assert!(CloudNativeIdsSendReceipt::decode(&bad_nested.to_string()).is_err());
        for invalid in [serde_json::Value::Null, serde_json::json!([]), serde_json::json!("binding")] {
            let mut wrong_shape = valid_value.clone();
            wrong_shape["sourceBinding"] = invalid;
            assert!(CloudNativeIdsSendReceipt::decode(&wrong_shape.to_string()).is_err());
        }
        for invalid in [serde_json::json!(-1), serde_json::json!(1.5), serde_json::json!("123"), serde_json::json!(true)] {
            let mut wrong_length = valid_value.clone();
            wrong_length["sourceBinding"]["payload_length"] = invalid;
            assert!(CloudNativeIdsSendReceipt::decode(&wrong_length.to_string()).is_err());
        }
        let mut missing_field = valid_value.clone();
        missing_field["sourceBinding"].as_object_mut().unwrap().remove("source_sha256");
        assert!(CloudNativeIdsSendReceipt::decode(&missing_field.to_string()).is_err());
    }

    #[test]
    fn ids_send_receipt_source_binding_idempotent_and_substitution_rejected() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let mut receipt = ids_send_receipt_fixture(directory.path(), 'f', 'F', 'R');
        receipt.source_binding = Some(ids_send_source_binding_fixture());
        let first = store.persist_ids_send_receipt(&receipt).expect("persist bound");
        let second = store.persist_ids_send_receipt(&receipt).expect("persist same source");
        assert_eq!(first, second);

        // Same origin tuple but a different source binding must not overwrite.
        let mut other_binding = ids_send_source_binding_fixture();
        other_binding.payload_sha256 = "d".repeat(64);
        let substituted = CloudNativeIdsSendReceipt {
            guid_hash: receipt.guid_hash.clone(),
            account_fingerprint: receipt.account_fingerprint.clone(),
            protected_store_identity: receipt.protected_store_identity.clone(),
            native_session_id: receipt.native_session_id.clone(),
            source_binding: Some(other_binding),
        };
        assert_eq!(
            store.persist_ids_send_receipt(&substituted),
            Err(CloudNativeStoreFailure::ContextMismatch)
        );
        let replayed = store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                None,
            )
            .expect("replay after substitution attempt")
            .receipts;
        assert_eq!(replayed.len(), 1);
        assert_eq!(replayed[0].guid_hash, receipt.guid_hash);
        assert_eq!(replayed[0].source_binding, receipt.source_binding);
        assert_ne!(
            replayed[0].guid_hash,
            ids_send_source_binding_fixture().payload_sha256
        );
    }

    #[test]
    fn ids_send_receipt_replay_and_ack_carry_source_binding() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let mut receipt = ids_send_receipt_fixture(directory.path(), 'f', 'F', 'R');
        receipt.source_binding = Some(ids_send_source_binding_fixture());
        let receipt_id = store.persist_ids_send_receipt(&receipt).expect("persist bound");
        let page = store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                None,
            )
            .expect("replay bound");
        assert_eq!(page.receipts.len(), 1);
        assert_eq!(page.receipts[0].source_binding, receipt.source_binding);

        let mismatched = CloudNativeIdsSendReceiptReplay {
            receipt_id: receipt_id.clone(),
            guid_hash: receipt.guid_hash.clone(),
            native_session_id: receipt.native_session_id.clone(),
            source_binding: None,
        };
        assert_eq!(
            store.acknowledge_ids_send_receipt(
                &mismatched,
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
            ),
            Err(CloudNativeStoreFailure::ContextMismatch)
        );
        assert_eq!(
            store
                .replay_ids_send_receipts(
                    &receipt.account_fingerprint,
                    &receipt.protected_store_identity,
                    None,
                )
                .expect("receipt preserved after binding mismatch")
                .receipts
                .len(),
            1
        );
        let expected = CloudNativeIdsSendReceiptReplay {
            receipt_id,
            guid_hash: receipt.guid_hash.clone(),
            native_session_id: receipt.native_session_id.clone(),
            source_binding: receipt.source_binding.clone(),
        };
        store
            .acknowledge_ids_send_receipt(
                &expected,
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
            )
            .expect("ack with matching binding");
        assert!(store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                None,
            )
            .expect("replay after ack")
            .receipts
            .is_empty());
    }

    #[test]
    fn corrupt_receipts_do_not_starve_later_matching_receipt() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let receipt = ids_send_receipt_fixture(directory.path(), 'd', 'D', 'T');
        let receipt_id = store
            .persist_ids_send_receipt(&receipt)
            .expect("persist receipt");
        let original = store
            .ids_send_receipt_path(&receipt_id)
            .expect("receipt path");
        let later_id = format!("{IDS_SEND_RECEIPT_PREFIX}{}", "z".repeat(43));
        let later = store
            .ids_send_receipt_path(&later_id)
            .expect("later receipt path");
        fs::rename(original, &later).expect("move valid receipt after corrupt fixtures");
        let receipt_directory = store
            .ids_send_receipt_directory()
            .expect("receipt directory");
        for index in 0..MAX_IDS_SEND_RECEIPTS_PER_REPLAY {
            let token = format!("A{index:042}");
            fs::write(
                receipt_directory.join(format!("{token}{IDS_SEND_RECEIPT_SUFFIX}")),
                b"corrupt",
            )
            .expect("write corrupt receipt");
        }

        let first = store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                None,
            )
            .expect("replay corrupt receipt page");
        assert!(first.receipts.is_empty());
        let cursor = first.next_cursor.expect("corrupt page cursor");
        let replayed = store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                Some(&cursor),
            )
            .expect("replay later matching receipt");
        assert_eq!(replayed.receipts.len(), 1);
        assert_eq!(replayed.receipts[0].receipt_id, later_id);
        assert_eq!(replayed.next_cursor, None);
    }

    #[test]
    fn replay_cursor_advances_past_sixty_four_retained_receipts() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let target = ids_send_receipt_fixture(directory.path(), 'e', 'E', 'U');
        let target_id = store
            .persist_ids_send_receipt(&target)
            .expect("persist target receipt");
        let target_path = store
            .ids_send_receipt_path(&target_id)
            .expect("target path");
        let last_id = format!("{IDS_SEND_RECEIPT_PREFIX}{}", "z".repeat(43));
        fs::rename(
            target_path,
            store.ids_send_receipt_path(&last_id).expect("last path"),
        )
        .expect("move target last");
        for index in 0..MAX_IDS_SEND_RECEIPTS_PER_REPLAY {
            let retained = CloudNativeIdsSendReceipt {
                guid_hash: format!("{index:064x}"),
                account_fingerprint: target.account_fingerprint.clone(),
                protected_store_identity: target.protected_store_identity.clone(),
                native_session_id: target.native_session_id.clone(),
                source_binding: None,
            };
            store
                .persist_ids_send_receipt(&retained)
                .expect("persist retained receipt");
        }

        let first = store
            .replay_ids_send_receipts(
                &target.account_fingerprint,
                &target.protected_store_identity,
                None,
            )
            .expect("first receipt page");
        assert_eq!(first.receipts.len(), MAX_IDS_SEND_RECEIPTS_PER_REPLAY);
        let cursor = first.next_cursor.expect("next cursor");
        let second = store
            .replay_ids_send_receipts(
                &target.account_fingerprint,
                &target.protected_store_identity,
                Some(&cursor),
            )
            .expect("second receipt page");
        assert_eq!(second.receipts.len(), 1);
        assert_eq!(second.receipts[0].receipt_id, last_id);
        assert_eq!(second.receipts[0].guid_hash, target.guid_hash);
        assert_eq!(second.next_cursor, None);
    }

    #[test]
    fn ids_send_receipt_replay_scans_large_noise_with_bounded_candidates() {
        let directory = tempdir().expect("temp directory");
        let store = PlatformCloudNativeProtectedStore::new(directory.path().to_path_buf());
        let receipt_directory = store
            .ids_send_receipt_directory()
            .expect("receipt directory");
        fs::create_dir_all(&receipt_directory).expect("create receipt directory");
        for index in 0..=4_096 {
            fs::write(receipt_directory.join(format!("noise-{index}")), b"x")
                .expect("write bounded noise fixture");
        }
        let receipt = ids_send_receipt_fixture(directory.path(), 'f', 'F', 'V');
        let receipt_id = store
            .persist_ids_send_receipt(&receipt)
            .expect("persist receipt after noise");
        let replayed = store
            .replay_ids_send_receipts(
                &receipt.account_fingerprint,
                &receipt.protected_store_identity,
                None,
            )
            .expect("replay receipt after noise");

        assert_eq!(replayed.receipts.len(), 1);
        assert_eq!(replayed.receipts[0].receipt_id, receipt_id);
        assert_eq!(replayed.next_cursor, None);
    }

    #[test]
    fn native_seam_source_has_no_frb_or_serializable_raw_dto() {
        let source = include_str!("cloud_sync_native_fetch.rs");
        let production = source
            .split("#[cfg(test)]")
            .next()
            .expect("production source");
        for forbidden in ["#[frb", "Serialize", "Deserialize", "CloudSyncRawChange"] {
            assert!(
                !production.contains(forbidden),
                "native seam must not contain {forbidden}"
            );
        }
    }
}
