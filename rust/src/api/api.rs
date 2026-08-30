#[cfg(target_os = "windows")]
use crate::windows_secret_storage::open_windows_keystore;
use anyhow::anyhow;
use flutter_rust_bridge::{frb, DartFnFuture, IntoDart, JoinHandle};
#[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
use keystore::software::SoftwareEncryptor;
#[cfg(not(target_os = "android"))]
use keystore::software::SoftwareKeystore;
use keystore::{
    init_keystore, keystore, AesKeystoreKey, EcCurve, EcKeystoreKey, EncryptMode,
    KeystoreAccessRules, KeystoreDigest, KeystoreEncryptKey, KeystorePadding, RsaKey,
};
use log::{debug, error, info, warn};
pub use plist::Value;
use plist::{Data, Dictionary};
pub use rustpush::{default_provider, ArcAnisetteClient, DefaultAnisetteProvider, LoginClientInfo};
use sha2::{Digest, Sha256};
pub use std::time::SystemTime;
use std::{
    borrow::{Borrow, BorrowMut},
    collections::HashSet,
    fs::{self, File},
    future::Future,
    io::{Cursor, ErrorKind, Read, Write},
    ops::Deref,
    panic,
    str::FromStr,
    sync::{Arc, OnceLock, Weak},
    time::Duration,
    u64,
};

use async_recursion::async_recursion;
use base64::prelude::*;
pub use broadcast::Receiver;
pub use mpsc::Sender;
use prost::Message as prostMessage;
use rand::Rng;
use rustpush::cloudkit_operation_gate::{
    acquire_cloudkit_read_authentication, with_cloudkit_writer_operation,
    CloudKitReadAuthenticationPermit,
};
pub use rustpush::cloudkit_proto::EscrowData;
pub use rustpush::findmy::{FindMyFriendsClient, FindMyPhoneClient};
pub use rustpush::passwords::PasswordManager;
use rustpush::passwords::{
    pause_password_cloudkit_operations, resume_password_cloudkit_operations,
};
pub use rustpush::sharedstreams::{SharedAlbum, SyncStatus};
pub use rustpush::DebugMutex as Mutex;
pub use rustpush::IdmsAuthListener;
use rustpush::KeyCache;
pub use rustpush::{
    authenticate_apple, authenticate_phone, authenticate_smsless,
    cloud_messages::CloudMessagesClient,
    cloudkit::{CloudKitClient, CloudKitState},
    facetime::{FTClient, FTState, FACETIME_SERVICE, VIDEO_SERVICE},
    findmy::{FindMyClient, FindMyState, FindMyStateManager, MULTIPLEX_SERVICE},
    keychain::{KeychainClient, KeychainClientState},
    login_apple_delegates,
    name_photo_sharing::ProfilesClient,
    sharedstreams::{
        AssetMetadata, FFMpegFilePackager, FileMetadata, FilePackager, PreparedAsset, PreparedFile,
        SharedStreamClient, SharedStreamsState, SyncController, SyncManager, SyncState,
    },
    statuskit::{ChannelInterestToken, StatusKitClient, StatusKitState, StatusKitStatus},
    APSMessage, CircleClientSession, CircleServerSession, EntitlementAuthState, IDSNGMIdentity,
    LoginDelegate, TokenProvider, MADRID_SERVICE,
};
use rustpush::{
    cloud_messages::{CloudMessageRecordKind, CloudMessageRecordPage},
    cloudkit::{classify_cloudkit_failure, CloudKitFailureClass},
    CloudKitProtocolError,
};
use rustpush::{
    cloudkit::contact_info_to_handle,
    cloudkit_proto::{base64_encode, CuttlefishSerializedKey},
    findmy::SharedBeaconClient,
    keychain::{CloudKey, CurrentBottle, SivKey},
    passwords::PasswordState,
    request_update_account, AnisetteProvider, DebugRwLock,
};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::io::Seek;
pub use std::path::PathBuf;
use tokio::{
    runtime::Runtime,
    select,
    sync::{broadcast, mpsc, watch, RwLock},
};
use uniffi::HandleAlloc;
use uuid::Uuid;

use crate::{
    frb_generated::{SseEncode, StreamSink},
    init_logger,
    native::{PackagedFile, HANDLE_WIFI_NETWORKS, PACKAGER_LOCK, QUEUED_MESSAGES},
    RUNTIME,
};

use flutter_rust_bridge::for_generated::{
    lazy_static, BaseAsyncRuntime, NoOpErrorListener, SimpleExecutor, SimpleHandler,
    SimpleThreadPool,
};

pub type MyHandler = SimpleHandler<
    SimpleExecutor<NoOpErrorListener, SimpleThreadPool, MyAsyncRuntime>,
    NoOpErrorListener,
>;

include!("./mirrors.rs");

#[derive(Debug, Default)]
pub struct MyAsyncRuntime();

impl BaseAsyncRuntime for MyAsyncRuntime {
    fn spawn<F>(&self, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        RUNTIME.spawn(future)
    }
}

lazy_static! {
    pub static ref FLUTTER_RUST_BRIDGE_HANDLER: MyHandler = {
        MyHandler::new(
            SimpleExecutor::new(NoOpErrorListener, Default::default(), Default::default()),
            NoOpErrorListener,
        )
    };
}

pub fn do_first_time_init(path: String) {
    let dir = PathBuf::from_str(&path).unwrap();

    init_logger(&dir);
}

/// Protects one Cloud Sync V2 value at rest.
///
/// The complete scope and purpose are authenticated by the platform bridge.
/// This function does not perform CloudKit I/O or enable sync writes.
#[frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn cloud_sync_protect(
    storage_directory: String,
    account_fingerprint: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
    purpose: String,
    plaintext: String,
) -> anyhow::Result<String> {
    crate::cloud_sync_protector::protect(
        storage_directory,
        account_fingerprint,
        container,
        database,
        zone,
        stream_kind,
        schema_version,
        purpose,
        plaintext,
    )
    .map_err(Into::into)
}

/// Opens one Cloud Sync V2 value only in its original scope and purpose.
#[frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn cloud_sync_unprotect(
    storage_directory: String,
    account_fingerprint: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
    purpose: String,
    ciphertext: String,
) -> anyhow::Result<String> {
    crate::cloud_sync_protector::unprotect(
        storage_directory,
        account_fingerprint,
        container,
        database,
        zone,
        stream_kind,
        schema_version,
        purpose,
        ciphertext,
    )
    .map_err(Into::into)
}

/// Returns a per-install HMAC-SHA256 account fingerprint.
#[frb(sync)]
pub fn cloud_sync_fingerprint_account(
    storage_directory: String,
    raw_account_identifier: String,
) -> anyhow::Result<String> {
    crate::cloud_sync_protector::fingerprint_account(storage_directory, raw_account_identifier)
        .map_err(Into::into)
}

/// Redacted identity binding for one active Cloud Messages client.
///
/// The raw DSID is read and transformed entirely in Rust. Three derived values
/// cross FRB: two per-install HMAC values and a per-install protected-store
/// identity. None of them is an Apple credential.
pub struct CloudSyncNativeAuthMetadata {
    pub native_session_id: String,
    pub account_fingerprint: String,
    pub protected_store_identity: String,
}

const CLOUD_SYNC_READ_AUTH_WARM_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloudSyncReadAuthWarmFailure {
    WriterPauseScope,
    MessagesContainer,
    KeychainContainer,
    SecurityContainer,
    CloudKitToken,
}

impl CloudSyncReadAuthWarmFailure {
    fn safe_code(self) -> &'static str {
        match self {
            Self::WriterPauseScope => "cloud_sync_native_auth_writer_pause_scope_failed",
            Self::MessagesContainer => "cloud_sync_native_auth_messages_container_failed",
            Self::KeychainContainer => "cloud_sync_native_auth_keychain_container_failed",
            Self::SecurityContainer => "cloud_sync_native_auth_security_container_failed",
            Self::CloudKitToken => "cloud_sync_native_auth_cloudkit_token_failed",
        }
    }
}

async fn bounded_cloud_sync_read_authentication<F, T>(
    timeout: Duration,
    future: F,
) -> anyhow::Result<T>
where
    F: Future<Output = Result<T, CloudSyncReadAuthWarmFailure>>,
{
    match tokio::time::timeout(timeout, future).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(failure)) => Err(anyhow!(failure.safe_code())),
        Err(_) => Err(anyhow!("cloud_sync_native_auth_warm_timeout")),
    }
}

/// Explicitly authenticates the read-only Cloud Sync V2 container.
///
/// Callers must hold the CloudKit operation interlock. This may perform one
/// bounded `ckAppInit` request for a cold client, but it cannot issue record,
/// zone, subscription, save, or delete operations. Protected fetch and
/// semantic decode remain lookup-only after this step.
pub async fn cloud_sync_warm_read_authentication(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
) -> anyhow::Result<()> {
    cloud_sync_warm_read_authentication_inner(cloud_messages_client, None).await
}

/// Authenticates the read-only Cloud Sync V2 containers under the exact
/// native writer-pause token established by the semantic Canary.
pub async fn cloud_sync_warm_read_authentication_under_writer_pause(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    pause_token: u64,
) -> anyhow::Result<()> {
    let permit = acquire_cloudkit_read_authentication(pause_token)
        .map_err(|_| anyhow!(CloudSyncReadAuthWarmFailure::WriterPauseScope.safe_code()))?;
    cloud_sync_warm_read_authentication_inner(cloud_messages_client, Some(&permit)).await
}

async fn cloud_sync_warm_read_authentication_inner(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    read_authentication_permit: Option<&CloudKitReadAuthenticationPermit<'_>>,
) -> anyhow::Result<()> {
    let account_before_warm = cloud_messages_client
        .validated_native_account_identifier()
        .await
        .map_err(|_| anyhow!("cloud_sync_native_auth_identity_mismatch"))?;
    bounded_cloud_sync_read_authentication(CLOUD_SYNC_READ_AUTH_WARM_TIMEOUT, async {
        if let Some(permit) = read_authentication_permit {
            cloud_messages_client
                .get_container_for_read_authentication(permit)
                .await
                .map_err(|_| CloudSyncReadAuthWarmFailure::MessagesContainer)?;
            cloud_messages_client
                .keychain
                .get_container_for_read_authentication(permit)
                .await
                .map_err(|_| CloudSyncReadAuthWarmFailure::KeychainContainer)?;
            cloud_messages_client
                .keychain
                .get_security_container_for_read_authentication(permit)
                .await
                .map_err(|_| CloudSyncReadAuthWarmFailure::SecurityContainer)?;
        } else {
            cloud_messages_client
                .get_container()
                .await
                .map_err(|_| CloudSyncReadAuthWarmFailure::MessagesContainer)?;
            cloud_messages_client
                .keychain
                .get_container()
                .await
                .map_err(|_| CloudSyncReadAuthWarmFailure::KeychainContainer)?;
            cloud_messages_client
                .keychain
                .get_security_container()
                .await
                .map_err(|_| CloudSyncReadAuthWarmFailure::SecurityContainer)?;
        }
        cloud_messages_client
            .client
            .token_provider
            .get_mme_token_cached("cloudKitToken")
            .await
            .map_err(|_| CloudSyncReadAuthWarmFailure::CloudKitToken)?;
        Ok(())
    })
    .await?;
    let account_after_warm = cloud_messages_client
        .validated_native_account_identifier()
        .await
        .map_err(|_| anyhow!("cloud_sync_native_auth_identity_mismatch"))?;
    if account_after_warm != account_before_warm {
        return Err(anyhow!("cloud_sync_native_auth_account_changed"));
    }
    Ok(())
}

pub async fn cloud_sync_capture_auth_snapshot(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
) -> anyhow::Result<CloudSyncNativeAuthMetadata> {
    let raw_account_identifier = cloud_messages_client
        .validated_native_account_identifier()
        .await
        .map_err(|_| anyhow!("cloud_sync_native_auth_identity_mismatch"))?;
    let account_fingerprint = crate::cloud_sync_protector::fingerprint_account(
        storage_directory.clone(),
        raw_account_identifier.clone(),
    )
    .map_err(|_| anyhow!("cloud_sync_native_auth_account_fingerprint_failed"))?;
    let client_generation_input = format!(
        "{raw_account_identifier}\0client:{:p}",
        Arc::as_ptr(cloud_messages_client)
    );
    let native_session_id = crate::cloud_sync_protector::fingerprint_account(
        storage_directory.clone(),
        client_generation_input,
    )
    .map_err(|_| anyhow!("cloud_sync_native_auth_session_fingerprint_failed"))?;
    let protected_store_identity =
        crate::cloud_sync_protector::protected_store_identity(storage_directory)
            .map_err(|_| anyhow!("cloud_sync_native_auth_store_identity_failed"))?;
    Ok(CloudSyncNativeAuthMetadata {
        native_session_id,
        account_fingerprint,
        protected_store_identity,
    })
}

fn cloud_sync_password_writer_pause_error(error: rustpush::PushError) -> anyhow::Error {
    match error {
        rustpush::PushError::IoError(error) if error.kind() == ErrorKind::TimedOut => {
            anyhow!("cloud_sync_native_writer_pause_timeout")
        }
        rustpush::PushError::IoError(error)
            if matches!(
                error.kind(),
                ErrorKind::WouldBlock | ErrorKind::AlreadyExists
            ) =>
        {
            anyhow!("cloud_sync_native_writer_pause_already_active")
        }
        _ => anyhow!("cloud_sync_native_writer_pause_failed"),
    }
}

fn cloud_sync_password_writer_resume_error(error: rustpush::PushError) -> anyhow::Error {
    match error {
        rustpush::PushError::IoError(error) if error.kind() == ErrorKind::PermissionDenied => {
            anyhow!("cloud_sync_native_writer_resume_token_invalid")
        }
        _ => anyhow!("cloud_sync_native_writer_resume_failed"),
    }
}

/// Pauses every native CloudKit writer workflow for one semantic pull.
///
/// The bridge name is retained for generated-binding compatibility. `token`
/// is generated by Dart before the request so a lost bridge response can be
/// retried or canceled without stranding the native permit.
pub async fn cloud_sync_pause_password_cloudkit_writers(token: u64) -> anyhow::Result<u64> {
    pause_password_cloudkit_operations(token)
        .await
        .map_err(cloud_sync_password_writer_pause_error)
}

/// Releases the native CloudKit writer pause matching `token`.
pub async fn cloud_sync_resume_password_cloudkit_writers(token: u64) -> anyhow::Result<()> {
    resume_password_cloudkit_operations(token)
        .await
        .map_err(cloud_sync_password_writer_resume_error)
}

#[cfg(test)]
mod cloud_sync_password_writer_pause_bridge_tests {
    use super::*;

    #[test]
    fn pause_bridge_exposes_only_fixed_failure_codes() {
        let timeout = cloud_sync_password_writer_pause_error(rustpush::PushError::IoError(
            std::io::Error::new(ErrorKind::TimedOut, "sensitive detail"),
        ));
        assert_eq!(
            timeout.to_string(),
            "cloud_sync_native_writer_pause_timeout"
        );

        let busy = cloud_sync_password_writer_pause_error(rustpush::PushError::IoError(
            std::io::Error::new(ErrorKind::WouldBlock, "sensitive detail"),
        ));
        assert_eq!(
            busy.to_string(),
            "cloud_sync_native_writer_pause_already_active"
        );

        let retry_in_flight = cloud_sync_password_writer_pause_error(rustpush::PushError::IoError(
            std::io::Error::new(ErrorKind::AlreadyExists, "sensitive detail"),
        ));
        assert_eq!(
            retry_in_flight.to_string(),
            "cloud_sync_native_writer_pause_already_active"
        );

        let unknown = cloud_sync_password_writer_pause_error(rustpush::PushError::BadMsg);
        assert_eq!(unknown.to_string(), "cloud_sync_native_writer_pause_failed");
    }

    #[test]
    fn resume_bridge_exposes_only_fixed_failure_codes() {
        let invalid = cloud_sync_password_writer_resume_error(rustpush::PushError::IoError(
            std::io::Error::new(ErrorKind::PermissionDenied, "sensitive detail"),
        ));
        assert_eq!(
            invalid.to_string(),
            "cloud_sync_native_writer_resume_token_invalid"
        );

        let unknown = cloud_sync_password_writer_resume_error(rustpush::PushError::BadMsg);
        assert_eq!(
            unknown.to_string(),
            "cloud_sync_native_writer_resume_failed"
        );
    }
}

#[cfg(test)]
mod cloud_sync_read_authentication_tests {
    use super::*;

    #[test]
    fn writer_pause_scope_failure_has_a_fixed_safe_code() {
        assert_eq!(
            CloudSyncReadAuthWarmFailure::WriterPauseScope.safe_code(),
            "cloud_sync_native_auth_writer_pause_scope_failed"
        );
    }

    #[tokio::test]
    async fn bounded_warm_authentication_times_out_with_only_a_safe_code() {
        let failure = bounded_cloud_sync_read_authentication(
            Duration::from_millis(1),
            std::future::pending::<Result<(), CloudSyncReadAuthWarmFailure>>(),
        )
        .await
        .expect_err("pending warm authentication must time out");

        assert_eq!(failure.to_string(), "cloud_sync_native_auth_warm_timeout");
    }

    #[tokio::test]
    async fn bounded_warm_authentication_returns_only_a_fixed_stage_code() {
        let failure = bounded_cloud_sync_read_authentication(Duration::from_secs(1), async {
            Err::<(), _>(CloudSyncReadAuthWarmFailure::CloudKitToken)
        })
        .await
        .expect_err("failed warm authentication must remain content-free");

        assert_eq!(
            failure.to_string(),
            "cloud_sync_native_auth_cloudkit_token_failed"
        );
    }

    #[tokio::test]
    async fn bounded_warm_authentication_timeout_releases_owned_mutex_guards() {
        let initialization = Arc::new(tokio::sync::Mutex::new(()));
        let timed_initialization = Arc::clone(&initialization);
        let failure =
            bounded_cloud_sync_read_authentication(Duration::from_millis(10), async move {
                let _guard = timed_initialization.lock().await;
                std::future::pending::<Result<(), CloudSyncReadAuthWarmFailure>>().await
            })
            .await
            .expect_err("stalled initialization must time out");

        assert_eq!(failure.to_string(), "cloud_sync_native_auth_warm_timeout");
        let _guard = tokio::time::timeout(Duration::from_secs(1), initialization.lock())
            .await
            .expect("cancellation must release the initialization mutex");
    }
}

// CLOUD_SYNC_PROTECTED_DTO_BEGIN
/// D0-safe change disposition emitted by the native protected fetch boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncProtectedChangeKind {
    Save,
    Delete,
    Quarantined,
}

/// Fixed, content-free preflight classification.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncProtectedPreflightCode {
    UnsupportedRecordType,
    MalformedMetadata,
    OversizedRecord,
    InvalidChangeShape,
}

/// One protected CloudKit change. Every string is either a fixed-format digest
/// or an opaque `obcs2.ref.*` capability. No Apple identifier or record body is
/// present.
#[derive(Clone, Debug)]
pub struct CloudSyncProtectedChange {
    pub change_id: String,
    pub record_id_hash: String,
    pub etag_hash: Option<String>,
    pub kind: CloudSyncProtectedChangeKind,
    pub payload_sha256: String,
    pub payload_length: u64,
    pub protected_record_identity_reference: String,
    pub protected_raw_envelope_reference: String,
    pub server_modified_at_millis: Option<i64>,
    pub preflight_code: Option<CloudSyncProtectedPreflightCode>,
    pub is_tombstone: bool,
}

/// One bounded protected page. Checkpoints and page leases remain opaque
/// native-store references.
#[derive(Clone, Debug)]
pub struct CloudSyncProtectedPage {
    pub changes: Vec<CloudSyncProtectedChange>,
    pub batch_id: String,
    pub generation: u64,
    pub page_lease_reference: String,
    pub protected_next_checkpoint_reference: Option<String>,
    pub complete: bool,
    pub admitted_raw_bytes: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncProtectedFailureCategory {
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

/// Fixed safe-code vocabulary for the protected bridge. These variants carry
/// no server body, path, token, identifier, or record content.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncProtectedSafeCode {
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
    NativeAuthUnavailable,
    Unknown,
}

#[derive(Clone, Debug)]
pub struct CloudSyncProtectedFailure {
    pub category: CloudSyncProtectedFailureCategory,
    pub safe_code: CloudSyncProtectedSafeCode,
    pub retry_after_seconds: Option<u64>,
}

/// Exactly one of `page` and `failure` is populated.
#[derive(Clone, Debug)]
pub struct CloudSyncProtectedFetchResult {
    pub page: Option<CloudSyncProtectedPage>,
    pub failure: Option<CloudSyncProtectedFailure>,
}

/// A lease mutation succeeds only when `failure` is absent.
#[derive(Clone, Debug)]
pub struct CloudSyncProtectedLeaseResult {
    pub failure: Option<CloudSyncProtectedFailure>,
}

#[derive(Clone, Debug)]
pub struct CloudSyncProtectedRecovery {
    pub finalized_adopted_lease_references: Vec<String>,
    pub absent_adopted_lease_references: Vec<String>,
    pub rolled_back_count: u32,
    pub removed_temporary_files_count: u32,
    pub has_more: bool,
}

/// Exactly one of `recovery` and `failure` is populated.
#[derive(Clone, Debug)]
pub struct CloudSyncProtectedRecoveryResult {
    pub recovery: Option<CloudSyncProtectedRecovery>,
    pub failure: Option<CloudSyncProtectedFailure>,
}

#[derive(Clone, Debug)]
pub struct CloudSyncProtectedRetirementResult {
    pub retired_count: u32,
    pub failure: Option<CloudSyncProtectedFailure>,
}

#[derive(Clone, Debug)]
pub struct CloudSyncProtectedGarbageCollection {
    pub scanned_count: u32,
    pub first_observed_count: u32,
    pub deleted_count: u32,
    pub preserved_live_count: u32,
    pub preserved_active_lease_count: u32,
    pub has_more: bool,
}

#[derive(Clone, Debug)]
pub struct CloudSyncProtectedGarbageCollectionResult {
    pub collection: Option<CloudSyncProtectedGarbageCollection>,
    pub failure: Option<CloudSyncProtectedFailure>,
}
// CLOUD_SYNC_PROTECTED_DTO_END

// CLOUD_SYNC_OUTBOUND_DTO_BEGIN
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncOutboundSafeCode {
    InvalidScope,
    InvalidRequest,
    UnsupportedMessage,
    MalformedMessage,
    OversizedMessage,
    ProtectedStorage,
    BindingMismatch,
    NativeAuthUnavailable,
    NativePrepareFailed,
    AlreadyConsumed,
    CorrelationMismatch,
}

#[derive(Clone, Debug)]
pub struct CloudSyncProtectedOutboundStage {
    pub logical_entity_key_hash: String,
    pub protected_payload_reference: String,
    pub payload_sha256: String,
    pub payload_length: u64,
    pub protected_server_record_reference: String,
    pub server_record_id_hash: String,
    pub lease_reference: String,
}

#[derive(Debug)]
pub struct CloudSyncProtectedOutboundStageResult {
    pub stage: Option<CloudSyncProtectedOutboundStage>,
    pub failure: Option<CloudSyncOutboundSafeCode>,
}

#[derive(Clone, Debug)]
pub struct CloudSyncPreparedMessageCreateInput {
    pub local_operation_id: String,
    pub logical_entity_key_hash: String,
    pub protected_lease_reference: String,
    pub protected_payload_reference: String,
    pub payload_sha256: String,
    pub protected_server_record_reference: String,
    pub server_record_id_hash: String,
    pub apple_operation_uuid: String,
}

#[frb(opaque)]
pub struct CloudSyncPreparedMessageCreateHandle {
    prepared: tokio::sync::Mutex<
        Option<
            rustpush::cloud_messages::CloudMessagesPreparedSaveSubmission<DefaultAnisetteProvider>,
        >,
    >,
}

impl std::fmt::Debug for CloudSyncPreparedMessageCreateHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CloudSyncPreparedMessageCreateHandle(redacted)")
    }
}

#[derive(Debug)]
pub struct CloudSyncPreparedMessageCreateResult {
    pub handle: Option<CloudSyncPreparedMessageCreateHandle>,
    pub failure: Option<CloudSyncOutboundSafeCode>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncOutboundSaveDisposition {
    Succeeded,
    UnknownOutcome,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncOutboundFailureClass {
    Throttled,
    TransientServer,
    Authentication,
    Conflict,
    ResetRequired,
    Permanent,
    Unknown,
}

#[derive(Clone, Debug)]
pub struct CloudSyncOutboundSaveOutcome {
    pub local_operation_id: String,
    pub apple_operation_uuid: String,
    pub disposition: CloudSyncOutboundSaveDisposition,
    pub failure_class: Option<CloudSyncOutboundFailureClass>,
    pub retry_after_seconds: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct CloudSyncOutboundConsumeResult {
    pub outcomes: Vec<CloudSyncOutboundSaveOutcome>,
    pub failure: Option<CloudSyncOutboundSafeCode>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncOutboundReconcileDisposition {
    Committed,
    NotApplied,
    Diverged,
    Unresolved,
}

#[derive(Clone, Debug)]
pub struct CloudSyncOutboundReconcileResult {
    pub disposition: Option<CloudSyncOutboundReconcileDisposition>,
    pub protected_proof_reference: Option<String>,
    pub failure_class: Option<CloudSyncOutboundFailureClass>,
    pub retry_after_seconds: Option<u64>,
    pub failure: Option<CloudSyncOutboundSafeCode>,
}
// CLOUD_SYNC_OUTBOUND_DTO_END

// CLOUD_SYNC_TRANSIENT_DTO_BEGIN
/// D1-only entity vocabulary. These values are safe fixed discriminants.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientEntityKind {
    Chat,
    Message,
    Reaction,
    Attachment,
    GroupPhoto,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientMutationKind {
    Upsert,
    Tombstone,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientFieldState {
    Absent,
    Value,
    ExplicitClear,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientService {
    IMessage,
    Sms,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientChatStyle {
    Direct,
    Group,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientChatAliasKind {
    GroupId,
    OriginalGroupId,
    ServiceIdentifier,
    LegacyGroupIdentifier,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientReactionKind {
    Heart,
    Like,
    Dislike,
    Laugh,
    Emphasize,
    Question,
    Emoji,
    StickerBack,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientAssociationKind {
    None,
    Sticker,
    ReactionAdd,
    ReactionRemove,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientDeferredReason {
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
pub enum CloudSyncTransientQuarantineReason {
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientFailureCode {
    InvalidRequest,
    ActiveAccountMismatch,
    WarmAuthenticationRequired,
    ScopeMismatch,
    GenerationMismatch,
    StoreIdentityMismatch,
    ProtectedReferenceMismatch,
    MalformedRecord,
    OversizedRecord,
    PcsUnavailable,
    RetryableUpstream,
    DecoderFailure,
}

/// Content-free edit metadata used by the merge policy.
#[derive(Clone)]
pub struct CloudSyncTransientEditPart {
    pub part_key_hash: String,
    pub revision: u32,
    pub content_digest: String,
    pub modified_at_millis: i64,
}

#[derive(Clone)]
pub struct CloudSyncTransientKnownMessageFlags {
    pub from_me: bool,
    pub delivered: bool,
    pub read: bool,
    pub has_data_detector_results: bool,
    pub delivered_quietly: bool,
    pub did_notify_recipient: bool,
}

#[derive(Clone)]
pub struct CloudSyncTransientTextRun {
    pub start_utf16: u32,
    pub length_utf16: u32,
    pub message_part: Option<u32>,
    pub attachment_canonical_guid: Option<String>,
    pub attachment_logical_key_hash: Option<String>,
    pub mention_handle: Option<String>,
    pub audio_transcript: Option<String>,
    pub text_effect: Option<i64>,
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub strikethrough: Option<bool>,
    pub underline: Option<bool>,
}

#[derive(Clone)]
pub struct CloudSyncTransientAttributedBody {
    pub text: String,
    pub runs: Vec<CloudSyncTransientTextRun>,
}

#[derive(Clone)]
pub struct CloudSyncTransientMessageEdit {
    pub part: u32,
    pub revision: u32,
    pub bodies: Vec<CloudSyncTransientAttributedBody>,
    pub modified_at_millis: i64,
    pub original_range_location: Option<u32>,
    pub original_range_length: Option<u32>,
}

/// Content-free canonical snapshot. The opaque protected source reference is
/// retained so unknown semantics can be retried by a later decoder.
#[derive(Clone)]
pub struct CloudSyncTransientSnapshot {
    pub entity_kind: CloudSyncTransientEntityKind,
    pub logical_entity_key_hash: String,
    pub parent_logical_key_hash: Option<String>,
    pub immutable_content_digest: Option<String>,
    pub created_at_millis: Option<i64>,
    pub read_at_millis: Option<i64>,
    pub delivered_at_millis: Option<i64>,
    pub edit_parts: Vec<CloudSyncTransientEditPart>,
    pub retracted_at_millis: Option<i64>,
    pub group_version: Option<u32>,
    pub group_metadata_digest: Option<String>,
    pub etag_hash: Option<String>,
    pub protected_source_reference: String,
}

/// Transient chat content. This type has no Debug, Display, serde, or durable
/// representation and must flow directly into the canonical applier.
#[derive(Clone)]
pub struct CloudSyncTransientChatAlias {
    pub kind: CloudSyncTransientChatAliasKind,
    pub key_hash: String,
}

#[derive(Clone)]
pub struct CloudSyncTransientChatPayload {
    pub logical_entity_key_hash: String,
    /// Validated application-level chat GUID. Transient typed memory only.
    pub canonical_guid: String,
    /// Validated chat identifier used to bind message records.
    pub chat_identifier: String,
    pub group_id: String,
    pub original_group_id: String,
    /// Content-free aliases already authenticated by the canonical envelope.
    pub aliases: Vec<CloudSyncTransientChatAlias>,
    pub service: CloudSyncTransientService,
    pub style: CloudSyncTransientChatStyle,
    pub participant_handles: Vec<String>,
    pub display_name_state: CloudSyncTransientFieldState,
    pub display_name: Option<String>,
    pub last_addressed_handle_state: CloudSyncTransientFieldState,
    pub last_addressed_handle: Option<String>,
    pub group_version_state: CloudSyncTransientFieldState,
    pub group_version: Option<u32>,
    pub last_seen_message_guid_state: CloudSyncTransientFieldState,
    pub last_seen_message_guid: Option<String>,
    pub group_photo_guid_state: CloudSyncTransientFieldState,
    pub group_photo_guid: Option<String>,
}

/// Transient message/reaction content. Raw CloudKit record names and Apple
/// private identifiers are deliberately absent; validated app canonical
/// identities may cross this typed in-memory boundary.
#[derive(Clone)]
pub struct CloudSyncTransientMessagePayload {
    pub logical_entity_key_hash: String,
    /// Validated application-level message/reaction GUID. Transient only.
    pub canonical_guid: String,
    pub chat_alias_key_hash: String,
    pub chat_identifier: String,
    pub sender_handle: String,
    pub created_at_millis: i64,
    pub error: i64,
    pub service: CloudSyncTransientService,
    pub subject_state: CloudSyncTransientFieldState,
    pub subject: Option<String>,
    pub body_state: CloudSyncTransientFieldState,
    pub body: Option<String>,
    pub attributed_bodies_state: CloudSyncTransientFieldState,
    pub attributed_bodies: Vec<CloudSyncTransientAttributedBody>,
    pub balloon_bundle_id_state: CloudSyncTransientFieldState,
    pub balloon_bundle_id: Option<String>,
    pub effect_state: CloudSyncTransientFieldState,
    pub effect: Option<String>,
    pub read_at_millis_state: CloudSyncTransientFieldState,
    pub read_at_millis: Option<i64>,
    pub delivered_at_millis_state: CloudSyncTransientFieldState,
    pub delivered_at_millis: Option<i64>,
    pub known_flags: CloudSyncTransientKnownMessageFlags,
    pub association_kind: CloudSyncTransientAssociationKind,
    pub reaction_kind: Option<CloudSyncTransientReactionKind>,
    pub reaction_removed: bool,
    pub reaction_parent_logical_key_hash: Option<String>,
    pub reaction_parent_canonical_guid: Option<String>,
    pub reaction_parent_part: Option<u32>,
    pub associated_range_location: Option<u32>,
    pub associated_range_length: Option<u32>,
    pub reply_parent_logical_key_hash: Option<String>,
    pub reply_parent_canonical_guid: Option<String>,
    pub reply_parent_part: Option<String>,
    pub edits_state: CloudSyncTransientFieldState,
    pub edits: Vec<CloudSyncTransientMessageEdit>,
    pub retracted_parts_state: CloudSyncTransientFieldState,
    pub retracted_parts: Vec<u32>,
    pub associated_emoji_state: CloudSyncTransientFieldState,
    pub associated_emoji: Option<String>,
}

#[derive(Clone)]
pub struct CloudSyncTransientAttachmentPayload {
    pub logical_entity_key_hash: String,
    pub canonical_guid: String,
    pub owner_logical_key_hash: Option<String>,
    pub owner_canonical_guid: Option<String>,
    pub owner_part: Option<u32>,
    pub uti_state: CloudSyncTransientFieldState,
    pub uti: Option<String>,
    pub file_name_state: CloudSyncTransientFieldState,
    pub file_name: Option<String>,
    pub mime_type_state: CloudSyncTransientFieldState,
    pub mime_type: Option<String>,
    pub total_bytes_state: CloudSyncTransientFieldState,
    pub total_bytes: Option<u64>,
    pub is_outgoing_state: CloudSyncTransientFieldState,
    pub is_outgoing: Option<bool>,
    pub protected_local_reference_state: CloudSyncTransientFieldState,
    pub protected_local_reference: Option<String>,
}

#[derive(Clone)]
pub struct CloudSyncTransientGroupPhotoPayload {
    pub logical_entity_key_hash: String,
    pub owner_logical_key_hash: String,
    pub photo_guid: String,
    pub protected_local_reference: String,
}

/// Exactly one payload member is populated for an upsert.
#[derive(Clone)]
pub struct CloudSyncTransientPayload {
    pub chat: Option<CloudSyncTransientChatPayload>,
    pub message: Option<CloudSyncTransientMessagePayload>,
    pub attachment: Option<CloudSyncTransientAttachmentPayload>,
    pub group_photo: Option<CloudSyncTransientGroupPhotoPayload>,
}

#[derive(Clone)]
pub struct CloudSyncTransientTombstone {
    pub entity_kind: CloudSyncTransientEntityKind,
    pub logical_entity_key_hash: String,
    pub deleted_at_millis: Option<i64>,
    pub server_confirmed: bool,
}

/// A bounded, single-record D1 result. Exactly one of `mutation`,
/// `deferred_reason`, `quarantine_reason`, and `failure_code` is populated.
/// The optional source capability is echoed only after it passes the native
/// protected-reference grammar.
#[derive(Clone)]
pub struct CloudSyncTransientDecodeResult {
    pub protected_source_reference: Option<String>,
    pub generation: u64,
    pub change_id: Option<String>,
    pub entity_kind: Option<CloudSyncTransientEntityKind>,
    pub mutation_kind: Option<CloudSyncTransientMutationKind>,
    pub snapshot: Option<CloudSyncTransientSnapshot>,
    pub payload: Option<CloudSyncTransientPayload>,
    pub tombstone: Option<CloudSyncTransientTombstone>,
    pub deferred_reason: Option<CloudSyncTransientDeferredReason>,
    pub quarantine_reason: Option<CloudSyncTransientQuarantineReason>,
    pub failure_code: Option<CloudSyncTransientFailureCode>,
}
// CLOUD_SYNC_TRANSIENT_DTO_END

fn map_cloud_sync_outbound_failure(
    failure: crate::cloud_sync_outbound::CloudSyncOutboundFailure,
) -> CloudSyncOutboundSafeCode {
    use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Native;
    match failure {
        Native::UnsupportedMessage => CloudSyncOutboundSafeCode::UnsupportedMessage,
        Native::MalformedMessage => CloudSyncOutboundSafeCode::MalformedMessage,
        Native::OversizedMessage => CloudSyncOutboundSafeCode::OversizedMessage,
        Native::ProtectedStorage => CloudSyncOutboundSafeCode::ProtectedStorage,
        Native::BindingMismatch => CloudSyncOutboundSafeCode::BindingMismatch,
    }
}

fn map_cloud_sync_outbound_failure_class(
    failure: rustpush::cloudkit::CloudKitFailureClass,
) -> CloudSyncOutboundFailureClass {
    use rustpush::cloudkit::CloudKitFailureClass as Native;
    match failure {
        Native::Throttled => CloudSyncOutboundFailureClass::Throttled,
        Native::TransientServer => CloudSyncOutboundFailureClass::TransientServer,
        Native::Authentication => CloudSyncOutboundFailureClass::Authentication,
        Native::Conflict => CloudSyncOutboundFailureClass::Conflict,
        Native::ResetRequired => CloudSyncOutboundFailureClass::ResetRequired,
        Native::Permanent => CloudSyncOutboundFailureClass::Permanent,
        Native::Unknown => CloudSyncOutboundFailureClass::Unknown,
    }
}

fn cloud_sync_outbound_failure_result(
    failure: CloudSyncOutboundSafeCode,
) -> CloudSyncProtectedOutboundStageResult {
    CloudSyncProtectedOutboundStageResult {
        stage: None,
        failure: Some(failure),
    }
}

/// Converts one transient outgoing iMessage into a protected, crash-recoverable
/// outbox payload and stable server-record mapping. Message content and the raw
/// server record name remain native-only.
pub async fn cloud_sync_stage_outbound_message(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    message: CloudMessage,
) -> CloudSyncProtectedOutboundStageResult {
    let auth =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_outbound_failure_result(
                    CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                )
            }
        };
    if expected_account_fingerprint != auth.account_fingerprint
        || expected_protected_store_identity != auth.protected_store_identity
    {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    match crate::cloud_sync_outbound::stage_outbound_message(
        PathBuf::from(storage_directory),
        auth.account_fingerprint,
        message,
    ) {
        Ok(stage) => CloudSyncProtectedOutboundStageResult {
            stage: Some(CloudSyncProtectedOutboundStage {
                logical_entity_key_hash: stage.logical_entity_key_hash,
                protected_payload_reference: stage.protected_payload_reference,
                payload_sha256: stage.payload_sha256,
                payload_length: stage.payload_length,
                protected_server_record_reference: stage.protected_server_record_reference,
                server_record_id_hash: stage.server_record_id_hash,
                lease_reference: stage.lease_reference,
            }),
            failure: None,
        },
        Err(failure) => {
            cloud_sync_outbound_failure_result(map_cloud_sync_outbound_failure(failure))
        }
    }
}

fn cloud_sync_prepare_failure(
    failure: CloudSyncOutboundSafeCode,
) -> CloudSyncPreparedMessageCreateResult {
    CloudSyncPreparedMessageCreateResult {
        handle: None,
        failure: Some(failure),
    }
}

fn is_cloud_sync_hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_cloud_sync_operation_id(value: &str) -> bool {
    value.len() == 68
        && value.starts_with("op1:")
        && value[4..]
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_cloud_sync_keyed_hash(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn is_cloud_sync_protected_reference(value: &str) -> bool {
    value.len() == 53 && value.starts_with("obcs2.ref.") && is_cloud_sync_keyed_hash(&value[10..])
}

fn is_cloud_sync_lease_reference(value: &str) -> bool {
    value.len() == 44
        && value.starts_with("obcs2.lease.")
        && value[12..]
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

/// Prepares a create-only CloudKit request without performing remote I/O. The
/// returned opaque handle owns PCS material, prepared authentication, exact
/// request identity, and all operations. It can be consumed only once.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_prepare_message_create(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    request_uuid: String,
    request_timeout_seconds: u64,
    inputs: Vec<CloudSyncPreparedMessageCreateInput>,
) -> CloudSyncPreparedMessageCreateResult {
    if inputs.is_empty()
        || inputs.len() > 200
        || request_timeout_seconds == 0
        || request_timeout_seconds > 300
    {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidRequest);
    }
    let auth =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
            }
        };
    if auth.account_fingerprint != expected_account_fingerprint
        || auth.protected_store_identity != expected_protected_store_identity
    {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }

    let mut local_ids = HashSet::with_capacity(inputs.len());
    let mut lease_references = HashSet::with_capacity(inputs.len());
    let mut payload_references = HashSet::with_capacity(inputs.len());
    let mut server_references = HashSet::with_capacity(inputs.len());
    let mut server_hashes = HashSet::with_capacity(inputs.len());
    if inputs.iter().any(|input| {
        !is_cloud_sync_operation_id(&input.local_operation_id)
            || crate::cloud_sync_outbound::initial_message_create_operation_id(
                &expected_account_fingerprint,
                &input.logical_entity_key_hash,
            )
            .as_deref()
                != Ok(input.local_operation_id.as_str())
            || !is_cloud_sync_keyed_hash(&input.logical_entity_key_hash)
            || !is_cloud_sync_lease_reference(&input.protected_lease_reference)
            || !is_cloud_sync_protected_reference(&input.protected_payload_reference)
            || !is_cloud_sync_hex_digest(&input.payload_sha256)
            || !is_cloud_sync_protected_reference(&input.protected_server_record_reference)
            || !is_cloud_sync_keyed_hash(&input.server_record_id_hash)
            || input.protected_payload_reference != input.protected_server_record_reference
            || !local_ids.insert(input.local_operation_id.as_str())
            || !lease_references.insert(input.protected_lease_reference.as_str())
            || !payload_references.insert(input.protected_payload_reference.as_str())
            || !server_references.insert(input.protected_server_record_reference.as_str())
            || !server_hashes.insert(input.server_record_id_hash.as_str())
    }) {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidRequest);
    }

    let operation_uuids = inputs
        .iter()
        .map(|input| input.apple_operation_uuid.clone())
        .collect::<Vec<_>>();
    if operation_uuids.iter().any(|uuid| uuid == &request_uuid) {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidRequest);
    }
    let request_identity =
        match rustpush::cloudkit::CloudKitRequestIdentity::new(request_uuid, operation_uuids) {
            Ok(identity) => identity,
            Err(_) => return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidRequest),
        };
    let hasher =
        match crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
            Ok(hasher) => hasher,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::ProtectedStorage)
            }
        };

    let storage_path = PathBuf::from(&storage_directory);
    let mut messages = Vec::with_capacity(inputs.len());
    for input in inputs {
        if crate::cloud_sync_native_fetch::cloud_sync_verify_committed_lease_exact(
            storage_path.clone(),
            &input.protected_lease_reference,
            std::slice::from_ref(&input.protected_payload_reference),
        )
        .is_err()
        {
            return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::ProtectedStorage);
        }
        let message = match crate::cloud_sync_outbound::open_staged_outbound_message(
            storage_path.clone(),
            auth.account_fingerprint.clone(),
            &input.protected_payload_reference,
            &input.payload_sha256,
        ) {
            Ok(message) => message,
            Err(failure) => {
                return cloud_sync_prepare_failure(map_cloud_sync_outbound_failure(failure))
            }
        };
        let logical_hash = match hasher.canonical_entity_key_hash(
            crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Message,
            &message.guid,
        ) {
            Ok(hash) => hash,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::BindingMismatch)
            }
        };
        if logical_hash.value() != input.logical_entity_key_hash {
            return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::BindingMismatch);
        }
        let server_record_name = match crate::cloud_sync_outbound::open_staged_server_record_name(
            storage_path.clone(),
            auth.account_fingerprint.clone(),
            &input.protected_server_record_reference,
            &input.server_record_id_hash,
        ) {
            Ok(record_name) => record_name,
            Err(failure) => {
                return cloud_sync_prepare_failure(map_cloud_sync_outbound_failure(failure))
            }
        };
        messages.push(rustpush::cloud_messages::CloudMessageSaveInput {
            local_operation_id: input.local_operation_id,
            server_record_name,
            apple_operation_uuid: input.apple_operation_uuid,
            message,
        });
    }

    match cloud_messages_client
        .prepare_message_save_submission(
            messages,
            request_identity,
            Duration::from_secs(request_timeout_seconds),
        )
        .await
    {
        Ok(prepared) => CloudSyncPreparedMessageCreateResult {
            handle: Some(CloudSyncPreparedMessageCreateHandle {
                prepared: tokio::sync::Mutex::new(Some(prepared)),
            }),
            failure: None,
        },
        Err(_) => cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativePrepareFailed),
    }
}

pub async fn cloud_sync_consume_prepared_message_create(
    handle: &CloudSyncPreparedMessageCreateHandle,
) -> CloudSyncOutboundConsumeResult {
    let prepared = {
        let mut guard = handle.prepared.lock().await;
        guard.take()
    };
    let Some(prepared) = prepared else {
        return CloudSyncOutboundConsumeResult {
            outcomes: vec![],
            failure: Some(CloudSyncOutboundSafeCode::AlreadyConsumed),
        };
    };
    let outcomes = match prepared.consume_once().await {
        Ok(outcomes) => outcomes,
        Err(_) => {
            return CloudSyncOutboundConsumeResult {
                outcomes: vec![],
                failure: Some(CloudSyncOutboundSafeCode::CorrelationMismatch),
            }
        }
    };
    CloudSyncOutboundConsumeResult {
        outcomes: outcomes
            .into_iter()
            .map(|outcome| {
                use rustpush::cloud_messages::CloudMessagesSaveResult as NativeResult;
                let (disposition, failure_class, retry_after_seconds) = match outcome.result {
                    NativeResult::Succeeded => {
                        (CloudSyncOutboundSaveDisposition::Succeeded, None, None)
                    }
                    NativeResult::UnknownOutcome {
                        failure_class,
                        retry_after,
                    } => (
                        CloudSyncOutboundSaveDisposition::UnknownOutcome,
                        failure_class.map(map_cloud_sync_outbound_failure_class),
                        retry_after.map(|value| value.as_secs()),
                    ),
                    NativeResult::Failed {
                        failure_class,
                        retry_after,
                        ..
                    } => (
                        CloudSyncOutboundSaveDisposition::Failed,
                        failure_class.map(map_cloud_sync_outbound_failure_class),
                        retry_after.map(|value| value.as_secs()),
                    ),
                };
                CloudSyncOutboundSaveOutcome {
                    local_operation_id: outcome.local_operation_id,
                    apple_operation_uuid: outcome.apple_operation_uuid,
                    disposition,
                    failure_class,
                    retry_after_seconds,
                }
            })
            .collect(),
        failure: None,
    }
}

fn cloud_sync_reconcile_failure(
    failure: CloudSyncOutboundSafeCode,
) -> CloudSyncOutboundReconcileResult {
    CloudSyncOutboundReconcileResult {
        disposition: None,
        protected_proof_reference: None,
        failure_class: None,
        retry_after_seconds: None,
        failure: Some(failure),
    }
}

fn is_valid_cloud_sync_reconcile_message_create_input(
    expected_account_fingerprint: &str,
    request_uuid: &str,
    input: &CloudSyncPreparedMessageCreateInput,
) -> bool {
    is_cloud_sync_operation_id(&input.local_operation_id)
        && crate::cloud_sync_outbound::initial_message_create_operation_id(
            expected_account_fingerprint,
            &input.logical_entity_key_hash,
        )
        .as_deref()
            == Ok(input.local_operation_id.as_str())
        && is_cloud_sync_keyed_hash(&input.logical_entity_key_hash)
        && is_cloud_sync_lease_reference(&input.protected_lease_reference)
        && is_cloud_sync_protected_reference(&input.protected_payload_reference)
        && is_cloud_sync_hex_digest(&input.payload_sha256)
        && is_cloud_sync_protected_reference(&input.protected_server_record_reference)
        && is_cloud_sync_keyed_hash(&input.server_record_id_hash)
        && input.protected_payload_reference == input.protected_server_record_reference
        && request_uuid != input.apple_operation_uuid
        && rustpush::cloudkit::CloudKitRequestIdentity::new(
            request_uuid.to_owned(),
            vec![input.apple_operation_uuid.clone()],
        )
        .is_ok()
}

enum CloudSyncReconcileObservation {
    FoundPayloadDigest(String),
    DivergedRecord,
    NotFound,
    Unresolved {
        failure_class: Option<CloudKitFailureClass>,
        retry_after: Option<Duration>,
    },
    UnknownFailure,
}

fn classify_cloud_sync_reconcile_observation(
    observation: CloudSyncReconcileObservation,
    expected_payload_sha256: &str,
    protected_proof_reference: String,
) -> CloudSyncOutboundReconcileResult {
    let (disposition, failure_class, retry_after_seconds, decisive) = match observation {
        CloudSyncReconcileObservation::FoundPayloadDigest(observed_digest)
            if observed_digest == expected_payload_sha256 =>
        {
            (
                CloudSyncOutboundReconcileDisposition::Committed,
                None,
                None,
                true,
            )
        }
        CloudSyncReconcileObservation::FoundPayloadDigest(_)
        | CloudSyncReconcileObservation::DivergedRecord => (
            CloudSyncOutboundReconcileDisposition::Diverged,
            Some(CloudSyncOutboundFailureClass::Conflict),
            None,
            true,
        ),
        CloudSyncReconcileObservation::NotFound => (
            CloudSyncOutboundReconcileDisposition::NotApplied,
            None,
            None,
            true,
        ),
        CloudSyncReconcileObservation::Unresolved {
            failure_class,
            retry_after,
        } => (
            CloudSyncOutboundReconcileDisposition::Unresolved,
            failure_class.map(map_cloud_sync_outbound_failure_class),
            retry_after.map(|value| value.as_secs()),
            false,
        ),
        CloudSyncReconcileObservation::UnknownFailure => (
            CloudSyncOutboundReconcileDisposition::Unresolved,
            Some(CloudSyncOutboundFailureClass::Unknown),
            None,
            false,
        ),
    };
    CloudSyncOutboundReconcileResult {
        disposition: Some(disposition),
        protected_proof_reference: decisive.then_some(protected_proof_reference),
        failure_class,
        retry_after_seconds,
        failure: None,
    }
}

/// Reconciles one ambiguous create by fetching its stable CloudKit record name
/// and comparing the decrypted server message with the exact protected payload
/// staged before submission. Only explicit record absence permits replay.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_reconcile_message_create(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    request_uuid: String,
    input: CloudSyncPreparedMessageCreateInput,
) -> CloudSyncOutboundReconcileResult {
    if !is_valid_cloud_sync_reconcile_message_create_input(
        &expected_account_fingerprint,
        &request_uuid,
        &input,
    ) {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidRequest);
    }
    let auth =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_reconcile_failure(
                    CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                )
            }
        };
    if auth.account_fingerprint != expected_account_fingerprint
        || auth.protected_store_identity != expected_protected_store_identity
    {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }

    let storage_path = PathBuf::from(&storage_directory);
    if crate::cloud_sync_native_fetch::cloud_sync_verify_committed_lease_exact(
        storage_path.clone(),
        &input.protected_lease_reference,
        std::slice::from_ref(&input.protected_payload_reference),
    )
    .is_err()
    {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::ProtectedStorage);
    }
    let expected_message = match crate::cloud_sync_outbound::open_staged_outbound_message(
        storage_path.clone(),
        auth.account_fingerprint.clone(),
        &input.protected_payload_reference,
        &input.payload_sha256,
    ) {
        Ok(message) => message,
        Err(failure) => {
            return cloud_sync_reconcile_failure(map_cloud_sync_outbound_failure(failure))
        }
    };
    let hasher =
        match crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
            Ok(hasher) => hasher,
            Err(_) => {
                return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::ProtectedStorage)
            }
        };
    let logical_hash = match hasher.canonical_entity_key_hash(
        crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Message,
        &expected_message.guid,
    ) {
        Ok(hash) => hash,
        Err(_) => return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::BindingMismatch),
    };
    if logical_hash.value() != input.logical_entity_key_hash {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    let server_record_name = match crate::cloud_sync_outbound::open_staged_server_record_name(
        storage_path,
        auth.account_fingerprint,
        &input.protected_server_record_reference,
        &input.server_record_id_hash,
    ) {
        Ok(record_name) => record_name,
        Err(failure) => {
            return cloud_sync_reconcile_failure(map_cloud_sync_outbound_failure(failure))
        }
    };

    use rustpush::cloud_messages::CloudMessageRecordLookup;
    let observation = match cloud_messages_client
        .lookup_message_record(&server_record_name)
        .await
    {
        Ok(CloudMessageRecordLookup::Found(message)) => {
            match crate::cloud_sync_outbound::outbound_message_payload_sha256(
                message,
                &server_record_name,
            ) {
                Ok(digest) => CloudSyncReconcileObservation::FoundPayloadDigest(digest),
                Err(_) => CloudSyncReconcileObservation::DivergedRecord,
            }
        }
        Ok(CloudMessageRecordLookup::NotFound) => CloudSyncReconcileObservation::NotFound,
        Ok(CloudMessageRecordLookup::Unresolved {
            failure_class,
            retry_after,
        }) => CloudSyncReconcileObservation::Unresolved {
            failure_class,
            retry_after,
        },
        Err(_) => CloudSyncReconcileObservation::UnknownFailure,
    };
    classify_cloud_sync_reconcile_observation(
        observation,
        &input.payload_sha256,
        input.protected_payload_reference,
    )
}

#[cfg(test)]
mod cloud_sync_outbound_reconcile_contract_tests {
    use super::*;

    const REQUEST_UUID: &str = "11111111-2222-4ABC-8DEF-555555555555";
    const OPERATION_UUID: &str = "AAAAAAAA-BBBB-4CCC-8DDD-000000000001";

    fn account() -> String {
        "A".repeat(43)
    }

    fn input() -> CloudSyncPreparedMessageCreateInput {
        let logical_entity_key_hash = "L".repeat(43);
        CloudSyncPreparedMessageCreateInput {
            local_operation_id: crate::cloud_sync_outbound::initial_message_create_operation_id(
                &account(),
                &logical_entity_key_hash,
            )
            .unwrap(),
            logical_entity_key_hash,
            protected_lease_reference: format!("obcs2.lease.{}", "a".repeat(32)),
            protected_payload_reference: format!("obcs2.ref.{}", "P".repeat(43)),
            payload_sha256: "b".repeat(64),
            protected_server_record_reference: format!("obcs2.ref.{}", "P".repeat(43)),
            server_record_id_hash: "S".repeat(43),
            apple_operation_uuid: OPERATION_UUID.to_owned(),
        }
    }

    #[test]
    fn reconciliation_input_binds_the_semantic_operation_and_both_uuids() {
        let valid = input();
        assert!(is_valid_cloud_sync_reconcile_message_create_input(
            &account(),
            REQUEST_UUID,
            &valid
        ));

        let mut wrong_operation_id = valid.clone();
        wrong_operation_id.local_operation_id = format!("op1:{}", "f".repeat(64));
        assert!(!is_valid_cloud_sync_reconcile_message_create_input(
            &account(),
            REQUEST_UUID,
            &wrong_operation_id
        ));

        assert!(!is_valid_cloud_sync_reconcile_message_create_input(
            &"B".repeat(43),
            REQUEST_UUID,
            &valid
        ));
        assert!(!is_valid_cloud_sync_reconcile_message_create_input(
            &account(),
            OPERATION_UUID,
            &valid
        ));

        let mut malformed_operation_uuid = valid;
        malformed_operation_uuid.apple_operation_uuid = OPERATION_UUID.to_lowercase();
        assert!(!is_valid_cloud_sync_reconcile_message_create_input(
            &account(),
            REQUEST_UUID,
            &malformed_operation_uuid
        ));
    }

    #[test]
    fn exact_digest_commits_and_explicit_absence_is_the_only_replay_proof() {
        let protected_reference = format!("obcs2.ref.{}", "P".repeat(43));
        let expected_digest = "b".repeat(64);
        let committed = classify_cloud_sync_reconcile_observation(
            CloudSyncReconcileObservation::FoundPayloadDigest(expected_digest.clone()),
            &expected_digest,
            protected_reference.clone(),
        );
        assert_eq!(
            committed.disposition,
            Some(CloudSyncOutboundReconcileDisposition::Committed)
        );
        assert_eq!(
            committed.protected_proof_reference,
            Some(protected_reference.clone())
        );
        assert_eq!(committed.failure_class, None);

        let absent = classify_cloud_sync_reconcile_observation(
            CloudSyncReconcileObservation::NotFound,
            &expected_digest,
            protected_reference.clone(),
        );
        assert_eq!(
            absent.disposition,
            Some(CloudSyncOutboundReconcileDisposition::NotApplied)
        );
        assert_eq!(absent.protected_proof_reference, Some(protected_reference));
        assert_eq!(absent.failure_class, None);
    }

    #[test]
    fn divergent_or_malformed_found_records_quarantine_as_conflicts() {
        for observation in [
            CloudSyncReconcileObservation::FoundPayloadDigest("c".repeat(64)),
            CloudSyncReconcileObservation::DivergedRecord,
        ] {
            let result = classify_cloud_sync_reconcile_observation(
                observation,
                &"b".repeat(64),
                format!("obcs2.ref.{}", "P".repeat(43)),
            );
            assert_eq!(
                result.disposition,
                Some(CloudSyncOutboundReconcileDisposition::Diverged)
            );
            assert_eq!(
                result.failure_class,
                Some(CloudSyncOutboundFailureClass::Conflict)
            );
            assert!(result.protected_proof_reference.is_some());
            assert_eq!(result.retry_after_seconds, None);
        }
    }

    #[test]
    fn transient_and_transport_or_decrypt_failures_never_emit_a_proof() {
        let transient = classify_cloud_sync_reconcile_observation(
            CloudSyncReconcileObservation::Unresolved {
                failure_class: Some(CloudKitFailureClass::TransientServer),
                retry_after: Some(Duration::from_secs(901)),
            },
            &"b".repeat(64),
            format!("obcs2.ref.{}", "P".repeat(43)),
        );
        assert_eq!(
            transient.disposition,
            Some(CloudSyncOutboundReconcileDisposition::Unresolved)
        );
        assert_eq!(
            transient.failure_class,
            Some(CloudSyncOutboundFailureClass::TransientServer)
        );
        assert_eq!(transient.retry_after_seconds, Some(901));
        assert_eq!(transient.protected_proof_reference, None);

        let failed = classify_cloud_sync_reconcile_observation(
            CloudSyncReconcileObservation::UnknownFailure,
            &"b".repeat(64),
            format!("obcs2.ref.{}", "P".repeat(43)),
        );
        assert_eq!(
            failed.disposition,
            Some(CloudSyncOutboundReconcileDisposition::Unresolved)
        );
        assert_eq!(
            failed.failure_class,
            Some(CloudSyncOutboundFailureClass::Unknown)
        );
        assert_eq!(failed.protected_proof_reference, None);
    }
}

fn map_cloud_sync_protected_category(
    category: crate::cloud_sync_native_fetch::CloudNativeFailureCategory,
) -> CloudSyncProtectedFailureCategory {
    use crate::cloud_sync_native_fetch::CloudNativeFailureCategory as Native;
    match category {
        Native::Network => CloudSyncProtectedFailureCategory::Network,
        Native::Throttled => CloudSyncProtectedFailureCategory::Throttled,
        Native::Server => CloudSyncProtectedFailureCategory::Server,
        Native::Authorization => CloudSyncProtectedFailureCategory::Authorization,
        Native::PcsUnavailable => CloudSyncProtectedFailureCategory::PcsUnavailable,
        Native::MalformedRecord => CloudSyncProtectedFailureCategory::MalformedRecord,
        Native::Conflict => CloudSyncProtectedFailureCategory::Conflict,
        Native::LocalStorage => CloudSyncProtectedFailureCategory::LocalStorage,
        Native::Unknown => CloudSyncProtectedFailureCategory::Unknown,
    }
}

fn map_cloud_sync_protected_safe_code(
    safe_code: crate::cloud_sync_native_fetch::CloudNativeSafeCode,
) -> CloudSyncProtectedSafeCode {
    use crate::cloud_sync_native_fetch::CloudNativeSafeCode as Native;
    match safe_code {
        Native::InvalidScope => CloudSyncProtectedSafeCode::InvalidScope,
        Native::InvalidRequest => CloudSyncProtectedSafeCode::InvalidRequest,
        Native::InvalidCheckpoint => CloudSyncProtectedSafeCode::InvalidCheckpoint,
        Native::CheckpointContextMismatch => CloudSyncProtectedSafeCode::CheckpointContextMismatch,
        Native::OversizedPage => CloudSyncProtectedSafeCode::OversizedPage,
        Native::OversizedRecord => CloudSyncProtectedSafeCode::OversizedRecord,
        Native::ProtectionFailed => CloudSyncProtectedSafeCode::ProtectionFailed,
        Native::LocalStoreFailed => CloudSyncProtectedSafeCode::LocalStoreFailed,
        Native::FetchDeadline => CloudSyncProtectedSafeCode::FetchDeadline,
        Native::Network => CloudSyncProtectedSafeCode::Network,
        Native::CloudKitThrottled => CloudSyncProtectedSafeCode::CloudKitThrottled,
        Native::CloudKitServer => CloudSyncProtectedSafeCode::CloudKitServer,
        Native::CloudKitAuthorization => CloudSyncProtectedSafeCode::CloudKitAuthorization,
        Native::CloudKitConflict => CloudSyncProtectedSafeCode::CloudKitConflict,
        Native::CloudKitResetRequired => CloudSyncProtectedSafeCode::CloudKitResetRequired,
        Native::CloudKitPermanent => CloudSyncProtectedSafeCode::CloudKitPermanent,
        Native::CloudKitUnknown => CloudSyncProtectedSafeCode::CloudKitUnknown,
        Native::HttpAuthorization => CloudSyncProtectedSafeCode::HttpAuthorization,
        Native::HttpTimeout => CloudSyncProtectedSafeCode::HttpTimeout,
        Native::HttpThrottled => CloudSyncProtectedSafeCode::HttpThrottled,
        Native::HttpServer => CloudSyncProtectedSafeCode::HttpServer,
        Native::HttpUnknown => CloudSyncProtectedSafeCode::HttpUnknown,
        Native::PcsUnavailable => CloudSyncProtectedSafeCode::PcsUnavailable,
        Native::MalformedResponse => CloudSyncProtectedSafeCode::MalformedResponse,
        Native::ContinuationNoProgress => CloudSyncProtectedSafeCode::ContinuationNoProgress,
        Native::Unknown => CloudSyncProtectedSafeCode::Unknown,
    }
}

fn map_cloud_sync_protected_failure(
    failure: &crate::cloud_sync_native_fetch::CloudNativeFetchFailure,
) -> CloudSyncProtectedFailure {
    CloudSyncProtectedFailure {
        category: map_cloud_sync_protected_category(failure.category()),
        safe_code: map_cloud_sync_protected_safe_code(failure.safe_code()),
        retry_after_seconds: failure.retry_after_seconds(),
    }
}

fn local_cloud_sync_protected_failure(
    category: CloudSyncProtectedFailureCategory,
    safe_code: CloudSyncProtectedSafeCode,
) -> CloudSyncProtectedFailure {
    CloudSyncProtectedFailure {
        category,
        safe_code,
        retry_after_seconds: None,
    }
}

fn map_cloud_sync_protected_change(
    change: &crate::cloud_sync_native_fetch::CloudNativeProtectedChange,
) -> CloudSyncProtectedChange {
    use crate::cloud_sync_native_fetch::{
        CloudNativeChangeKind as NativeKind, CloudNativePreflightCode as NativePreflight,
    };
    let kind = match change.kind() {
        NativeKind::Save => CloudSyncProtectedChangeKind::Save,
        NativeKind::Delete => CloudSyncProtectedChangeKind::Delete,
        NativeKind::Quarantined => CloudSyncProtectedChangeKind::Quarantined,
    };
    let preflight_code = change.preflight_code().map(|code| match code {
        NativePreflight::UnsupportedRecordType => {
            CloudSyncProtectedPreflightCode::UnsupportedRecordType
        }
        NativePreflight::MalformedMetadata => CloudSyncProtectedPreflightCode::MalformedMetadata,
        NativePreflight::OversizedRecord => CloudSyncProtectedPreflightCode::OversizedRecord,
        NativePreflight::InvalidChangeShape => CloudSyncProtectedPreflightCode::InvalidChangeShape,
    });
    CloudSyncProtectedChange {
        change_id: change.change_id().to_owned(),
        record_id_hash: change.record_id_hash().to_owned(),
        etag_hash: change.etag_hash().map(str::to_owned),
        kind,
        payload_sha256: change.payload_digest().to_owned(),
        payload_length: change.payload_length(),
        protected_record_identity_reference: change
            .protected_record_identity_reference()
            .to_owned(),
        protected_raw_envelope_reference: change.protected_raw_envelope_reference().to_owned(),
        server_modified_at_millis: change.server_modified_at_millis(),
        preflight_code,
        is_tombstone: change.is_tombstone(),
    }
}

fn map_cloud_sync_protected_page(
    page: &crate::cloud_sync_native_fetch::CloudNativeProtectedPage,
) -> CloudSyncProtectedPage {
    CloudSyncProtectedPage {
        changes: page
            .changes()
            .iter()
            .map(map_cloud_sync_protected_change)
            .collect(),
        batch_id: page.batch_id().to_owned(),
        generation: page.generation(),
        page_lease_reference: page.page_lease_reference().to_owned(),
        protected_next_checkpoint_reference: page
            .protected_next_checkpoint_reference()
            .map(str::to_owned),
        complete: page.complete(),
        admitted_raw_bytes: page.admitted_raw_bytes(),
    }
}

/// Fetches and protects one bounded CloudKit page without allowing raw record
/// material, Apple identifiers, etags, continuation tokens, or paths to cross
/// Flutter Rust Bridge.
pub async fn cloud_sync_fetch_protected_page(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    stream: String,
    generation: u64,
    previous_checkpoint_reference: Option<String>,
    maximum_changes: u32,
) -> CloudSyncProtectedFetchResult {
    use crate::cloud_sync_native_fetch::{
        CloudNativeFetchRequest, CloudNativeProtectedFetchOutcome, CloudNativeProtectionScope,
        CloudNativeStream,
    };

    let Some(stream) = CloudNativeStream::parse(&stream) else {
        return CloudSyncProtectedFetchResult {
            page: None,
            failure: Some(local_cloud_sync_protected_failure(
                CloudSyncProtectedFailureCategory::MalformedRecord,
                CloudSyncProtectedSafeCode::InvalidRequest,
            )),
        };
    };
    let auth =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => {
                return CloudSyncProtectedFetchResult {
                    page: None,
                    failure: Some(local_cloud_sync_protected_failure(
                        CloudSyncProtectedFailureCategory::Authorization,
                        CloudSyncProtectedSafeCode::NativeAuthUnavailable,
                    )),
                }
            }
        };
    if expected_account_fingerprint.len() != 43
        || !expected_account_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        || expected_account_fingerprint != auth.account_fingerprint
    {
        return CloudSyncProtectedFetchResult {
            page: None,
            failure: Some(local_cloud_sync_protected_failure(
                CloudSyncProtectedFailureCategory::MalformedRecord,
                CloudSyncProtectedSafeCode::InvalidScope,
            )),
        };
    }
    let scope = match CloudNativeProtectionScope::new(auth.account_fingerprint, stream) {
        Ok(scope) => scope,
        Err(failure) => {
            return CloudSyncProtectedFetchResult {
                page: None,
                failure: Some(map_cloud_sync_protected_failure(&failure)),
            }
        }
    };
    let hasher =
        match crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
            Ok(hasher) => hasher,
            Err(_) => {
                return CloudSyncProtectedFetchResult {
                    page: None,
                    failure: Some(local_cloud_sync_protected_failure(
                        CloudSyncProtectedFailureCategory::LocalStorage,
                        CloudSyncProtectedSafeCode::ProtectionFailed,
                    )),
                }
            }
        };
    let request = CloudNativeFetchRequest::new(
        stream,
        &scope,
        generation,
        previous_checkpoint_reference.as_deref(),
        maximum_changes,
    );
    match crate::cloud_sync_native_fetch::cloud_sync_fetch_protected_page(
        cloud_messages_client,
        PathBuf::from(storage_directory),
        &hasher,
        &request,
    )
    .await
    {
        CloudNativeProtectedFetchOutcome::Page(page) => CloudSyncProtectedFetchResult {
            page: Some(map_cloud_sync_protected_page(&page)),
            failure: None,
        },
        CloudNativeProtectedFetchOutcome::Failure(failure) => CloudSyncProtectedFetchResult {
            page: None,
            failure: Some(map_cloud_sync_protected_failure(&failure)),
        },
    }
}

#[frb(sync)]
pub fn cloud_sync_commit_protected_page_lease(
    storage_directory: String,
    page_lease_reference: String,
    retained_references: Vec<String>,
) -> CloudSyncProtectedLeaseResult {
    let failure = crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
        PathBuf::from(storage_directory),
        &page_lease_reference,
        &retained_references,
    )
    .err()
    .map(|failure| map_cloud_sync_protected_failure(&failure));
    CloudSyncProtectedLeaseResult { failure }
}

#[frb(sync)]
pub fn cloud_sync_acknowledge_committed_page_lease(
    storage_directory: String,
    page_lease_reference: String,
) -> CloudSyncProtectedLeaseResult {
    let failure = crate::cloud_sync_native_fetch::cloud_sync_acknowledge_committed_page_lease(
        PathBuf::from(storage_directory),
        &page_lease_reference,
    )
    .err()
    .map(|failure| map_cloud_sync_protected_failure(&failure));
    CloudSyncProtectedLeaseResult { failure }
}

#[frb(sync)]
pub fn cloud_sync_rollback_protected_page_lease(
    storage_directory: String,
    page_lease_reference: String,
) -> CloudSyncProtectedLeaseResult {
    let failure = crate::cloud_sync_native_fetch::cloud_sync_rollback_protected_page_lease(
        PathBuf::from(storage_directory),
        &page_lease_reference,
    )
    .err()
    .map(|failure| map_cloud_sync_protected_failure(&failure));
    CloudSyncProtectedLeaseResult { failure }
}

#[frb(sync)]
pub fn cloud_sync_recover_abandoned_page_leases(
    storage_directory: String,
    adopted_lease_references: Vec<String>,
    live_references: Vec<String>,
    live_reference_enumeration_complete: bool,
) -> CloudSyncProtectedRecoveryResult {
    match crate::cloud_sync_native_fetch::cloud_sync_recover_abandoned_page_leases(
        PathBuf::from(storage_directory),
        &adopted_lease_references,
        &live_references,
        live_reference_enumeration_complete,
    ) {
        Ok(summary) => CloudSyncProtectedRecoveryResult {
            recovery: Some(CloudSyncProtectedRecovery {
                finalized_adopted_lease_references: summary
                    .finalized_adopted_lease_references()
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
                absent_adopted_lease_references: summary
                    .absent_adopted_lease_references()
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
                rolled_back_count: summary.rolled_back_count() as u32,
                removed_temporary_files_count: summary.removed_temporary_file_count() as u32,
                has_more: summary.has_more(),
            }),
            failure: None,
        },
        Err(failure) => CloudSyncProtectedRecoveryResult {
            recovery: None,
            failure: Some(map_cloud_sync_protected_failure(&failure)),
        },
    }
}

#[frb(sync)]
pub fn cloud_sync_retire_protected_references(
    storage_directory: String,
    references: Vec<String>,
) -> CloudSyncProtectedRetirementResult {
    match crate::cloud_sync_native_fetch::cloud_sync_retire_protected_references(
        PathBuf::from(storage_directory),
        &references,
    ) {
        Ok(retired_count) => CloudSyncProtectedRetirementResult {
            retired_count: retired_count as u32,
            failure: None,
        },
        Err(failure) => CloudSyncProtectedRetirementResult {
            retired_count: 0,
            failure: Some(map_cloud_sync_protected_failure(&failure)),
        },
    }
}

#[frb(sync)]
pub fn cloud_sync_collect_protected_garbage(
    storage_directory: String,
    live_references: Vec<String>,
    live_reference_enumeration_complete: bool,
) -> CloudSyncProtectedGarbageCollectionResult {
    match crate::cloud_sync_native_fetch::cloud_sync_collect_protected_garbage(
        PathBuf::from(storage_directory),
        &live_references,
        live_reference_enumeration_complete,
    ) {
        Ok(summary) => CloudSyncProtectedGarbageCollectionResult {
            collection: Some(CloudSyncProtectedGarbageCollection {
                scanned_count: summary.scanned_count() as u32,
                first_observed_count: summary.first_observed_count() as u32,
                deleted_count: summary.deleted_count() as u32,
                preserved_live_count: summary.preserved_live_count() as u32,
                preserved_active_lease_count: summary.preserved_active_lease_count() as u32,
                has_more: summary.has_more(),
            }),
            failure: None,
        },
        Err(failure) => CloudSyncProtectedGarbageCollectionResult {
            collection: None,
            failure: Some(map_cloud_sync_protected_failure(&failure)),
        },
    }
}

fn map_cloud_sync_transient_entity_kind(
    kind: crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind,
) -> CloudSyncTransientEntityKind {
    use crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind as Canonical;
    match kind {
        Canonical::Chat => CloudSyncTransientEntityKind::Chat,
        Canonical::Message => CloudSyncTransientEntityKind::Message,
        Canonical::Reaction => CloudSyncTransientEntityKind::Reaction,
        Canonical::Attachment => CloudSyncTransientEntityKind::Attachment,
        Canonical::GroupPhoto => CloudSyncTransientEntityKind::GroupPhoto,
    }
}

fn unmap_cloud_sync_transient_entity_kind(
    kind: CloudSyncTransientEntityKind,
) -> crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind {
    use crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind as Canonical;
    match kind {
        CloudSyncTransientEntityKind::Chat => Canonical::Chat,
        CloudSyncTransientEntityKind::Message => Canonical::Message,
        CloudSyncTransientEntityKind::Reaction => Canonical::Reaction,
        CloudSyncTransientEntityKind::Attachment => Canonical::Attachment,
        CloudSyncTransientEntityKind::GroupPhoto => Canonical::GroupPhoto,
    }
}

fn map_cloud_sync_transient_field_state(
    state: crate::cloud_sync_canonical_dto::CloudCanonicalFieldState,
) -> CloudSyncTransientFieldState {
    use crate::cloud_sync_canonical_dto::CloudCanonicalFieldState as Canonical;
    match state {
        Canonical::Absent => CloudSyncTransientFieldState::Absent,
        Canonical::Value => CloudSyncTransientFieldState::Value,
        Canonical::ExplicitClear => CloudSyncTransientFieldState::ExplicitClear,
    }
}

fn map_cloud_sync_transient_service(
    service: crate::cloud_sync_canonical_dto::CloudCanonicalService,
) -> CloudSyncTransientService {
    use crate::cloud_sync_canonical_dto::CloudCanonicalService as Canonical;
    match service {
        Canonical::IMessage => CloudSyncTransientService::IMessage,
        Canonical::Sms => CloudSyncTransientService::Sms,
    }
}

#[cfg(test)]
mod cloud_sync_transient_service_tests {
    use super::*;
    use crate::cloud_sync_canonical_dto::CloudCanonicalService;

    #[test]
    fn maps_only_the_two_exactly_supported_services() {
        assert_eq!(
            map_cloud_sync_transient_service(CloudCanonicalService::IMessage),
            CloudSyncTransientService::IMessage
        );
        assert_eq!(
            map_cloud_sync_transient_service(CloudCanonicalService::Sms),
            CloudSyncTransientService::Sms
        );
    }
}

fn map_cloud_sync_transient_chat_style(
    style: crate::cloud_sync_canonical_dto::CloudCanonicalChatStyle,
) -> CloudSyncTransientChatStyle {
    use crate::cloud_sync_canonical_dto::CloudCanonicalChatStyle as Canonical;
    match style {
        Canonical::Direct => CloudSyncTransientChatStyle::Direct,
        Canonical::Group => CloudSyncTransientChatStyle::Group,
    }
}

fn map_cloud_sync_transient_chat_alias_kind(
    kind: crate::cloud_sync_canonical_dto::CloudCanonicalAliasKind,
) -> CloudSyncTransientChatAliasKind {
    use crate::cloud_sync_canonical_dto::CloudCanonicalAliasKind as Canonical;
    match kind {
        Canonical::ChatGroupId => CloudSyncTransientChatAliasKind::GroupId,
        Canonical::ChatOriginalGroupId => CloudSyncTransientChatAliasKind::OriginalGroupId,
        Canonical::ChatServiceIdentifier => CloudSyncTransientChatAliasKind::ServiceIdentifier,
        Canonical::ChatLegacyGroupIdentifier => {
            CloudSyncTransientChatAliasKind::LegacyGroupIdentifier
        }
    }
}

fn map_cloud_sync_transient_reaction_kind(
    kind: crate::cloud_sync_canonical_dto::CloudCanonicalReactionKind,
) -> CloudSyncTransientReactionKind {
    use crate::cloud_sync_canonical_dto::CloudCanonicalReactionKind as Canonical;
    match kind {
        Canonical::Heart => CloudSyncTransientReactionKind::Heart,
        Canonical::Like => CloudSyncTransientReactionKind::Like,
        Canonical::Dislike => CloudSyncTransientReactionKind::Dislike,
        Canonical::Laugh => CloudSyncTransientReactionKind::Laugh,
        Canonical::Emphasize => CloudSyncTransientReactionKind::Emphasize,
        Canonical::Question => CloudSyncTransientReactionKind::Question,
        Canonical::Emoji => CloudSyncTransientReactionKind::Emoji,
        Canonical::StickerBack => CloudSyncTransientReactionKind::StickerBack,
    }
}

fn map_cloud_sync_transient_text_run(
    run: &crate::cloud_sync_canonical_dto::CloudCanonicalTextRun,
) -> CloudSyncTransientTextRun {
    let attachment = run.attachment();
    CloudSyncTransientTextRun {
        start_utf16: run.start_utf16(),
        length_utf16: run.length_utf16(),
        message_part: run.message_part(),
        attachment_canonical_guid: attachment.map(|value| value.canonical_guid().to_owned()),
        attachment_logical_key_hash: attachment
            .map(|value| value.logical_key_hash().value().to_owned()),
        mention_handle: run.mention().map(str::to_owned),
        audio_transcript: run.audio_transcript().map(str::to_owned),
        text_effect: run.text_effect(),
        bold: run.bold(),
        italic: run.italic(),
        strikethrough: run.strikethrough(),
        underline: run.underline(),
    }
}

fn map_cloud_sync_transient_attributed_body(
    body: &crate::cloud_sync_canonical_dto::CloudCanonicalAttributedBody,
) -> CloudSyncTransientAttributedBody {
    CloudSyncTransientAttributedBody {
        text: body.text().to_owned(),
        runs: body
            .runs()
            .iter()
            .map(map_cloud_sync_transient_text_run)
            .collect(),
    }
}

fn map_cloud_sync_transient_message_edit(
    edit: &crate::cloud_sync_canonical_dto::CloudCanonicalMessageEdit,
) -> CloudSyncTransientMessageEdit {
    let (original_range_location, original_range_length) = edit
        .original_range()
        .map_or((None, None), |(location, length)| {
            (Some(location), Some(length))
        });
    CloudSyncTransientMessageEdit {
        part: edit.part(),
        revision: edit.revision(),
        bodies: edit
            .bodies()
            .iter()
            .map(map_cloud_sync_transient_attributed_body)
            .collect(),
        modified_at_millis: edit.modified_at_millis(),
        original_range_location,
        original_range_length,
    }
}

fn map_cloud_sync_transient_known_flags(
    flags: crate::cloud_sync_canonical_dto::CloudCanonicalKnownMessageFlags,
) -> CloudSyncTransientKnownMessageFlags {
    CloudSyncTransientKnownMessageFlags {
        from_me: flags.from_me,
        delivered: flags.delivered,
        read: flags.read,
        has_data_detector_results: flags.has_data_detector_results,
        delivered_quietly: flags.delivered_quietly,
        did_notify_recipient: flags.did_notify_recipient,
    }
}

/// The only immutable-content digest admitted to the local quarantine-repair
/// lane. It is built over the exact transient canonical payload that Dart
/// receives, with domain/version tags and explicit framing for every field.
/// Keep this byte contract in lockstep with cloudkit_repair_content_digest.dart.
struct CloudKitRepairDigestWriter {
    parts: Vec<Vec<u8>>,
}

impl CloudKitRepairDigestWriter {
    fn new(entity_kind: &str) -> Self {
        let mut writer = Self { parts: Vec::new() };
        writer.string("domain", "bluebubbles.cloudkit.repair.digest");
        writer.string("version", "1");
        writer.string("entityKind", entity_kind);
        writer
    }

    fn add(&mut self, name: &str, type_tag: u8, value: impl AsRef<[u8]>) {
        self.parts.push(name.as_bytes().to_vec());
        let mut tagged = Vec::with_capacity(value.as_ref().len() + 1);
        tagged.push(type_tag);
        tagged.extend_from_slice(value.as_ref());
        self.parts.push(tagged);
    }

    fn null(&mut self, name: &str) {
        self.add(name, 0, []);
    }

    fn string(&mut self, name: &str, value: &str) {
        self.add(name, 1, value.as_bytes());
    }

    fn optional_string(&mut self, name: &str, value: Option<&str>) {
        match value {
            Some(value) => self.string(name, value),
            None => self.null(name),
        }
    }

    fn integer<T: ToString>(&mut self, name: &str, value: T) {
        self.add(name, 2, value.to_string().as_bytes());
    }

    fn optional_integer<T: ToString + Copy>(&mut self, name: &str, value: Option<T>) {
        match value {
            Some(value) => self.integer(name, value),
            None => self.null(name),
        }
    }

    fn boolean(&mut self, name: &str, value: bool) {
        self.add(name, 3, [u8::from(value)]);
    }

    fn optional_boolean(&mut self, name: &str, value: Option<bool>) {
        match value {
            Some(value) => self.boolean(name, value),
            None => self.null(name),
        }
    }

    fn optional_bytes(&mut self, name: &str, value: Option<&[u8]>) {
        match value {
            Some(value) => self.add(name, 4, value),
            None => self.null(name),
        }
    }

    fn finish(self) -> String {
        let mut hasher = Sha256::new();
        for part in self.parts {
            hasher.update((part.len() as u64).to_be_bytes());
            hasher.update(part);
        }
        hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

fn repair_digest_field_state(value: CloudSyncTransientFieldState) -> &'static str {
    match value {
        CloudSyncTransientFieldState::Absent => "absent",
        CloudSyncTransientFieldState::Value => "value",
        CloudSyncTransientFieldState::ExplicitClear => "explicitClear",
    }
}

fn repair_digest_association(value: CloudSyncTransientAssociationKind) -> &'static str {
    match value {
        CloudSyncTransientAssociationKind::None => "none",
        CloudSyncTransientAssociationKind::Sticker => "sticker",
        CloudSyncTransientAssociationKind::ReactionAdd => "reactionAdd",
        CloudSyncTransientAssociationKind::ReactionRemove => "reactionRemove",
    }
}

fn repair_digest_reaction_type(kind: CloudSyncTransientReactionKind, removed: bool) -> String {
    let base = match kind {
        CloudSyncTransientReactionKind::Heart => "love",
        CloudSyncTransientReactionKind::Like => "like",
        CloudSyncTransientReactionKind::Dislike => "dislike",
        CloudSyncTransientReactionKind::Laugh => "laugh",
        CloudSyncTransientReactionKind::Emphasize => "emphasize",
        CloudSyncTransientReactionKind::Question => "question",
        CloudSyncTransientReactionKind::Emoji => "emoji",
        CloudSyncTransientReactionKind::StickerBack => "stickerback",
    };
    if removed {
        format!("-{base}")
    } else {
        base.to_owned()
    }
}

fn repair_digest_flags(
    writer: &mut CloudKitRepairDigestWriter,
    flags: Option<&CloudSyncTransientKnownMessageFlags>,
) {
    let Some(flags) = flags else {
        writer.null("knownFlagsPresent");
        return;
    };
    writer.boolean("knownFlagsPresent", true);
    writer.boolean("knownFlags.fromMe", flags.from_me);
    writer.boolean("knownFlags.delivered", flags.delivered);
    writer.boolean("knownFlags.read", flags.read);
    writer.boolean(
        "knownFlags.hasDataDetectorResults",
        flags.has_data_detector_results,
    );
    writer.boolean("knownFlags.deliveredQuietly", flags.delivered_quietly);
    writer.boolean("knownFlags.didNotifyRecipient", flags.did_notify_recipient);
}

fn repair_digest_bodies(
    writer: &mut CloudKitRepairDigestWriter,
    name: &str,
    bodies: &[CloudSyncTransientAttributedBody],
) {
    writer.integer(&format!("{name}.count"), bodies.len());
    for (body_index, body) in bodies.iter().enumerate() {
        let prefix = format!("{name}[{body_index}].");
        writer.string(&format!("{prefix}text"), &body.text);
        writer.integer(&format!("{prefix}runs.count"), body.runs.len());
        for (run_index, run) in body.runs.iter().enumerate() {
            let prefix = format!("{prefix}runs[{run_index}].");
            writer.integer(&format!("{prefix}startUtf16"), run.start_utf16);
            writer.integer(&format!("{prefix}lengthUtf16"), run.length_utf16);
            writer.optional_integer(&format!("{prefix}messagePart"), run.message_part);
            writer.optional_string(
                &format!("{prefix}attachmentCanonicalGuid"),
                run.attachment_canonical_guid.as_deref(),
            );
            writer.optional_string(
                &format!("{prefix}attachmentLogicalKeyHash"),
                run.attachment_logical_key_hash.as_deref(),
            );
            writer.optional_string(
                &format!("{prefix}mentionHandle"),
                run.mention_handle.as_deref(),
            );
            writer.optional_string(
                &format!("{prefix}audioTranscript"),
                run.audio_transcript.as_deref(),
            );
            writer.optional_integer(&format!("{prefix}textEffect"), run.text_effect);
            writer.optional_boolean(&format!("{prefix}bold"), run.bold);
            writer.optional_boolean(&format!("{prefix}italic"), run.italic);
            writer.optional_boolean(&format!("{prefix}strikethrough"), run.strikethrough);
            writer.optional_boolean(&format!("{prefix}underline"), run.underline);
        }
    }
}

fn cloudkit_repair_content_digest(payload: &CloudSyncTransientPayload) -> Option<String> {
    let value = payload.message.as_ref()?;
    if let Some(kind) = value.reaction_kind {
        let mut writer = CloudKitRepairDigestWriter::new("reaction");
        writer.string("logicalEntityKeyHash", &value.logical_entity_key_hash);
        writer.string("canonicalGuid", &value.canonical_guid);
        writer.optional_string(
            "parentLogicalKeyHash",
            value.reaction_parent_logical_key_hash.as_deref(),
        );
        writer.optional_string(
            "parentCanonicalGuid",
            value.reaction_parent_canonical_guid.as_deref(),
        );
        writer.optional_integer("parentPart", value.reaction_parent_part);
        writer.string("senderHandle", &value.sender_handle);
        writer.string(
            "reactionType",
            &repair_digest_reaction_type(kind, value.reaction_removed),
        );
        writer.optional_string("associatedEmoji", value.associated_emoji.as_deref());
        writer.integer("createdAtMs", value.created_at_millis);
        writer.integer("error", value.error);
        writer.string(
            "service",
            match value.service {
                CloudSyncTransientService::IMessage => "iMessage",
                CloudSyncTransientService::Sms => "sms",
            },
        );
        repair_digest_flags(&mut writer, Some(&value.known_flags));
        writer.string(
            "readAtState",
            repair_digest_field_state(value.read_at_millis_state),
        );
        writer.optional_integer("readAtMs", value.read_at_millis);
        writer.string(
            "deliveredAtState",
            repair_digest_field_state(value.delivered_at_millis_state),
        );
        writer.optional_integer("deliveredAtMs", value.delivered_at_millis);
        writer.optional_integer("associatedRangeLocation", value.associated_range_location);
        writer.optional_integer("associatedRangeLength", value.associated_range_length);
        return Some(writer.finish());
    }

    Some(cloudkit_repair_message_content_digest(
        value,
        Some(&value.known_flags),
    ))
}

fn cloudkit_repair_message_content_digest(
    value: &CloudSyncTransientMessagePayload,
    known_flags: Option<&CloudSyncTransientKnownMessageFlags>,
) -> String {
    let mut writer = CloudKitRepairDigestWriter::new("message");
    writer.string("logicalEntityKeyHash", &value.logical_entity_key_hash);
    writer.string("canonicalGuid", &value.canonical_guid);
    writer.string("chatAliasKeyHash", &value.chat_alias_key_hash);
    writer.string("chatIdentifier", &value.chat_identifier);
    writer.optional_string("body", value.body.as_deref());
    writer.string("senderHandle", &value.sender_handle);
    writer.integer("createdAtMs", value.created_at_millis);
    writer.integer("error", value.error);
    writer.string(
        "service",
        match value.service {
            CloudSyncTransientService::IMessage => "iMessage",
            CloudSyncTransientService::Sms => "sms",
        },
    );
    writer.string(
        "subjectState",
        repair_digest_field_state(value.subject_state),
    );
    writer.optional_string("subject", value.subject.as_deref());
    writer.string("bodyState", repair_digest_field_state(value.body_state));
    writer.string(
        "attributedBodiesState",
        repair_digest_field_state(value.attributed_bodies_state),
    );
    writer.string(
        "balloonBundleIdState",
        repair_digest_field_state(value.balloon_bundle_id_state),
    );
    writer.optional_string("balloonBundleId", value.balloon_bundle_id.as_deref());
    writer.string("decodedExtensionPayloadState", "absent");
    writer.optional_bytes("decodedExtensionPayload", None);
    writer.string("effectState", repair_digest_field_state(value.effect_state));
    writer.optional_string("effect", value.effect.as_deref());
    writer.string(
        "readAtState",
        repair_digest_field_state(value.read_at_millis_state),
    );
    writer.optional_integer("readAtMs", value.read_at_millis);
    writer.string(
        "deliveredAtState",
        repair_digest_field_state(value.delivered_at_millis_state),
    );
    writer.optional_integer("deliveredAtMs", value.delivered_at_millis);
    repair_digest_flags(&mut writer, known_flags);
    writer.string(
        "associationKind",
        repair_digest_association(value.association_kind),
    );
    writer.optional_string(
        "associationParentLogicalKeyHash",
        value.reaction_parent_logical_key_hash.as_deref(),
    );
    writer.optional_string(
        "associationParentCanonicalGuid",
        value.reaction_parent_canonical_guid.as_deref(),
    );
    writer.optional_integer("associationParentPart", value.reaction_parent_part);
    writer.optional_integer("associatedRangeLocation", value.associated_range_location);
    writer.optional_integer("associatedRangeLength", value.associated_range_length);
    writer.optional_string(
        "replyParentLogicalKeyHash",
        value.reply_parent_logical_key_hash.as_deref(),
    );
    writer.optional_string(
        "replyParentCanonicalGuid",
        value.reply_parent_canonical_guid.as_deref(),
    );
    writer.optional_string("replyParentPart", value.reply_parent_part.as_deref());
    writer.string("editsState", repair_digest_field_state(value.edits_state));
    writer.string(
        "retractedPartsState",
        repair_digest_field_state(value.retracted_parts_state),
    );
    repair_digest_bodies(&mut writer, "attributedBodies", &value.attributed_bodies);
    writer.integer("edits.count", value.edits.len());
    for (index, edit) in value.edits.iter().enumerate() {
        let prefix = format!("edits[{index}].");
        writer.integer(&format!("{prefix}part"), edit.part);
        writer.integer(&format!("{prefix}revision"), edit.revision);
        writer.integer(&format!("{prefix}modifiedAtMs"), edit.modified_at_millis);
        writer.optional_integer(
            &format!("{prefix}originalRangeLocation"),
            edit.original_range_location,
        );
        writer.optional_integer(
            &format!("{prefix}originalRangeLength"),
            edit.original_range_length,
        );
        repair_digest_bodies(&mut writer, &format!("{prefix}bodies"), &edit.bodies);
    }
    writer.integer("retractedParts.count", value.retracted_parts.len());
    for (index, part) in value.retracted_parts.iter().enumerate() {
        writer.integer(&format!("retractedParts[{index}]"), part);
    }
    writer.finish()
}

#[cfg(test)]
mod cloudkit_repair_digest_tests {
    use super::*;

    const CORPUS: &str =
        include_str!("../../../test/fixtures/cloud_sync/cloudkit_repair_digest_golden_v1.tsv");

    fn flags() -> CloudSyncTransientKnownMessageFlags {
        CloudSyncTransientKnownMessageFlags {
            from_me: true,
            delivered: false,
            read: true,
            has_data_detector_results: false,
            delivered_quietly: true,
            did_notify_recipient: false,
        }
    }

    fn basic_message(body: &str) -> CloudSyncTransientMessagePayload {
        CloudSyncTransientMessagePayload {
            logical_entity_key_hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
            canonical_guid: "guid".to_owned(),
            chat_alias_key_hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_owned(),
            chat_identifier: "chat".to_owned(),
            sender_handle: "sender".to_owned(),
            created_at_millis: 1,
            error: 2,
            service: CloudSyncTransientService::IMessage,
            subject_state: CloudSyncTransientFieldState::Value,
            subject: Some("subject".to_owned()),
            body_state: CloudSyncTransientFieldState::Value,
            body: Some(body.to_owned()),
            attributed_bodies_state: CloudSyncTransientFieldState::Absent,
            attributed_bodies: vec![],
            balloon_bundle_id_state: CloudSyncTransientFieldState::Absent,
            balloon_bundle_id: None,
            effect_state: CloudSyncTransientFieldState::Absent,
            effect: None,
            read_at_millis_state: CloudSyncTransientFieldState::Absent,
            read_at_millis: None,
            delivered_at_millis_state: CloudSyncTransientFieldState::Absent,
            delivered_at_millis: None,
            known_flags: flags(),
            association_kind: CloudSyncTransientAssociationKind::None,
            reaction_kind: None,
            reaction_removed: false,
            reaction_parent_logical_key_hash: None,
            reaction_parent_canonical_guid: None,
            reaction_parent_part: None,
            associated_range_location: None,
            associated_range_length: None,
            reply_parent_logical_key_hash: None,
            reply_parent_canonical_guid: None,
            reply_parent_part: None,
            edits_state: CloudSyncTransientFieldState::Absent,
            edits: vec![],
            retracted_parts_state: CloudSyncTransientFieldState::Absent,
            retracted_parts: vec![],
            associated_emoji_state: CloudSyncTransientFieldState::Absent,
            associated_emoji: None,
        }
    }

    fn field_state_message(
        state: CloudSyncTransientFieldState,
    ) -> CloudSyncTransientMessagePayload {
        let mut value = basic_message("");
        value.canonical_guid = "field-guid".to_owned();
        value.chat_identifier = "field-chat".to_owned();
        value.created_at_millis = 2;
        value.error = 0;
        value.subject_state = state;
        value.subject = None;
        value.body_state = state;
        value.body = None;
        value.attributed_bodies_state = state;
        value.balloon_bundle_id_state = state;
        // Native defers extension payloads before this transient boundary;
        // cloudkit_repair_message_content_digest therefore writes absent.
        value.effect_state = state;
        value.read_at_millis_state = state;
        value.delivered_at_millis_state = state;
        value.edits_state = state;
        value.retracted_parts_state = state;
        value
    }

    fn nested_body() -> (
        CloudSyncTransientAttributedBody,
        CloudSyncTransientAttributedBody,
    ) {
        let first = CloudSyncTransientAttributedBody {
            text: "A🙂B".to_owned(),
            runs: vec![CloudSyncTransientTextRun {
                start_utf16: 0,
                length_utf16: 3,
                message_part: Some(0),
                attachment_canonical_guid: Some("attachment_guid".to_owned()),
                attachment_logical_key_hash: Some(
                    "ccccccccccccccccccccccccccccccccccccccccccc".to_owned(),
                ),
                mention_handle: Some("person@example.com".to_owned()),
                audio_transcript: Some("spoken".to_owned()),
                text_effect: Some(7),
                bold: Some(true),
                italic: Some(false),
                strikethrough: None,
                underline: Some(true),
            }],
        };
        let second = CloudSyncTransientAttributedBody {
            text: "second".to_owned(),
            runs: vec![],
        };
        (first, second)
    }

    fn nested_message(retracted_parts: Vec<u32>) -> CloudSyncTransientMessagePayload {
        let (first, second) = nested_body();
        let mut value = basic_message("A🙂B");
        value.canonical_guid = "nested-guid".to_owned();
        value.chat_identifier = "nested-chat".to_owned();
        value.created_at_millis = 3;
        value.error = 0;
        value.subject_state = CloudSyncTransientFieldState::Absent;
        value.subject = None;
        value.attributed_bodies_state = CloudSyncTransientFieldState::Value;
        value.attributed_bodies = vec![first.clone(), second.clone()];
        value.edits_state = CloudSyncTransientFieldState::Value;
        value.edits = vec![CloudSyncTransientMessageEdit {
            part: 0,
            revision: 2,
            bodies: vec![second, first],
            modified_at_millis: 4,
            original_range_location: Some(1),
            original_range_length: Some(2),
        }];
        value.retracted_parts_state = CloudSyncTransientFieldState::Value;
        value.retracted_parts = retracted_parts;
        value
    }

    fn reaction(removed: bool, parent_part: Option<u32>) -> CloudSyncTransientMessagePayload {
        let mut value = basic_message("");
        value.logical_entity_key_hash = "ddddddddddddddddddddddddddddddddddddddddddd".to_owned();
        value.canonical_guid = if removed {
            "reaction-remove".to_owned()
        } else {
            "reaction-add".to_owned()
        };
        value.sender_handle = "sender".to_owned();
        value.created_at_millis = 5;
        value.error = 0;
        value.subject_state = CloudSyncTransientFieldState::Absent;
        value.subject = None;
        value.body_state = CloudSyncTransientFieldState::Absent;
        value.body = None;
        value.association_kind = if removed {
            CloudSyncTransientAssociationKind::ReactionRemove
        } else {
            CloudSyncTransientAssociationKind::ReactionAdd
        };
        value.reaction_kind = Some(CloudSyncTransientReactionKind::Emoji);
        value.reaction_removed = removed;
        value.reaction_parent_logical_key_hash =
            Some("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee".to_owned());
        value.reaction_parent_canonical_guid = Some("parent-guid".to_owned());
        value.reaction_parent_part = parent_part;
        value.associated_range_location = Some(1);
        value.associated_range_length = Some(2);
        value.read_at_millis_state = CloudSyncTransientFieldState::Value;
        value.read_at_millis = Some(6);
        value.delivered_at_millis_state = CloudSyncTransientFieldState::ExplicitClear;
        value.associated_emoji_state = CloudSyncTransientFieldState::Value;
        value.associated_emoji = Some("🔥".to_owned());
        value
    }

    fn digest(value: &CloudSyncTransientMessagePayload) -> String {
        cloudkit_repair_content_digest(&CloudSyncTransientPayload {
            chat: None,
            message: Some(value.clone()),
            attachment: None,
            group_photo: None,
        })
        .expect("message and reaction payloads have repair digests")
    }

    fn raw_bytes_framing_digest() -> String {
        let mut writer = CloudKitRepairDigestWriter::new("framingProbe");
        writer.string("unicodeText", "é🙂");
        writer.optional_bytes("rawBytes", Some(&[0, 255, 1, 128, 10]));
        writer.finish()
    }

    fn corpus() -> Vec<(&'static str, &'static str)> {
        CORPUS
            .lines()
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(|line| {
                let mut fields = line.split('\t');
                let name = fields.next().expect("corpus name");
                let digest = fields.next().expect("corpus digest");
                assert!(fields.next().is_none(), "invalid corpus row");
                (name, digest)
            })
            .collect()
    }

    #[test]
    fn cloudkit_repair_digest_matches_every_pinned_neutral_vector() {
        let flags_absent = basic_message("flags");
        let actual = vec![
            ("basic-message", digest(&basic_message("body"))),
            ("reaction-add-partless", digest(&reaction(false, None))),
            (
                "reaction-remove-part-zero",
                digest(&reaction(true, Some(0))),
            ),
            (
                "unicode-multibyte",
                digest(&basic_message("مرحبا 👩🏽‍🚀 café 漢字")),
            ),
            (
                "fields-absent",
                digest(&field_state_message(CloudSyncTransientFieldState::Absent)),
            ),
            (
                "fields-explicit-clear",
                digest(&field_state_message(
                    CloudSyncTransientFieldState::ExplicitClear,
                )),
            ),
            ("known-flags-present", digest(&basic_message("flags"))),
            (
                "known-flags-absent",
                cloudkit_repair_message_content_digest(&flags_absent, None),
            ),
            (
                "nested-attributed-edits",
                digest(&nested_message(vec![3, 1])),
            ),
            ("retracted-order-1-2", digest(&nested_message(vec![1, 2]))),
            ("retracted-order-2-1", digest(&nested_message(vec![2, 1]))),
            ("raw-bytes-framing", raw_bytes_framing_digest()),
        ];
        let expected = corpus();
        assert_eq!(actual.len(), expected.len());
        for ((actual_name, actual_digest), (expected_name, expected_digest)) in
            actual.iter().zip(expected)
        {
            assert_eq!(*actual_name, expected_name);
            assert_eq!(actual_digest, expected_digest, "{actual_name}");
        }
    }

    #[test]
    fn cloudkit_repair_digest_changes_for_semantic_and_order_mutations() {
        assert_ne!(
            digest(&basic_message("body")),
            digest(&basic_message("changed"))
        );
        assert_ne!(
            digest(&nested_message(vec![1, 2])),
            digest(&nested_message(vec![2, 1]))
        );
        assert_ne!(
            digest(&reaction(false, None)),
            digest(&reaction(false, Some(0)))
        );

        let imessage = basic_message("body");
        let mut sms = imessage.clone();
        sms.service = CloudSyncTransientService::Sms;
        assert_ne!(digest(&imessage), digest(&sms));

        let imessage_reaction = reaction(false, None);
        let mut sms_reaction = imessage_reaction.clone();
        sms_reaction.service = CloudSyncTransientService::Sms;
        assert_ne!(digest(&imessage_reaction), digest(&sms_reaction));
    }
}

fn map_cloud_sync_transient_snapshot(
    snapshot: &crate::cloud_sync_canonical_dto::CloudCanonicalSnapshot,
) -> CloudSyncTransientSnapshot {
    CloudSyncTransientSnapshot {
        entity_kind: map_cloud_sync_transient_entity_kind(snapshot.entity_kind()),
        logical_entity_key_hash: snapshot.logical_entity_key_hash().value().to_owned(),
        parent_logical_key_hash: snapshot
            .parent_logical_key_hash()
            .map(|value| value.value().to_owned()),
        immutable_content_digest: snapshot
            .immutable_content_digest()
            .map(|value| value.value().to_owned()),
        created_at_millis: snapshot.created_at_millis(),
        read_at_millis: snapshot.read_at_millis(),
        delivered_at_millis: snapshot.delivered_at_millis(),
        edit_parts: snapshot
            .edit_parts()
            .iter()
            .map(|part| CloudSyncTransientEditPart {
                part_key_hash: part.part_key_hash().value().to_owned(),
                revision: part.revision(),
                content_digest: part.content_digest().value().to_owned(),
                modified_at_millis: part.modified_at_millis(),
            })
            .collect(),
        retracted_at_millis: snapshot.retracted_at_millis(),
        group_version: snapshot.group_version(),
        group_metadata_digest: snapshot
            .group_metadata_digest()
            .map(|value| value.value().to_owned()),
        etag_hash: snapshot.etag_hash().map(|value| value.value().to_owned()),
        protected_source_reference: snapshot
            .protected_raw_envelope_reference()
            .value()
            .to_owned(),
    }
}

fn map_cloud_sync_transient_payload(
    logical_entity_key_hash: &str,
    aliases: &[crate::cloud_sync_canonical_dto::CloudCanonicalAlias],
    payload: &crate::cloud_sync_canonical_dto::CloudCanonicalPayload,
) -> Option<CloudSyncTransientPayload> {
    use crate::cloud_sync_canonical_dto::CloudCanonicalPayload as Canonical;
    let mut result = CloudSyncTransientPayload {
        chat: None,
        message: None,
        attachment: None,
        group_photo: None,
    };
    match payload {
        Canonical::Chat(payload) => {
            result.chat = Some(CloudSyncTransientChatPayload {
                logical_entity_key_hash: logical_entity_key_hash.to_owned(),
                canonical_guid: payload.guid().to_owned(),
                chat_identifier: payload.chat_identifier().to_owned(),
                group_id: payload.group_id().to_owned(),
                original_group_id: payload.original_group_id().to_owned(),
                aliases: aliases
                    .iter()
                    .map(|alias| CloudSyncTransientChatAlias {
                        kind: map_cloud_sync_transient_chat_alias_kind(alias.kind()),
                        key_hash: alias.key_hash().value().to_owned(),
                    })
                    .collect(),
                service: map_cloud_sync_transient_service(payload.service()),
                style: map_cloud_sync_transient_chat_style(payload.style()),
                participant_handles: payload.participant_handles().to_vec(),
                display_name_state: map_cloud_sync_transient_field_state(
                    payload.display_name_state(),
                ),
                display_name: payload.display_name().value().cloned(),
                last_addressed_handle_state: map_cloud_sync_transient_field_state(
                    payload.last_addressed_handle_state(),
                ),
                last_addressed_handle: payload.last_addressed_handle().value().cloned(),
                group_version_state: map_cloud_sync_transient_field_state(
                    payload.group_version_state(),
                ),
                group_version: payload.group_version().value().copied(),
                last_seen_message_guid_state: map_cloud_sync_transient_field_state(
                    payload.last_seen_message_guid_state(),
                ),
                last_seen_message_guid: payload.last_seen_message_guid().value().cloned(),
                group_photo_guid_state: map_cloud_sync_transient_field_state(
                    payload.group_photo_guid_state(),
                ),
                group_photo_guid: payload.group_photo_guid().value().cloned(),
            });
        }
        Canonical::Message(payload) => {
            let (association_kind, reaction_kind, association_parent, reaction_removed) =
                match payload.association().reaction() {
                    Some((kind, parent, removed)) => (
                        if removed {
                            CloudSyncTransientAssociationKind::ReactionRemove
                        } else {
                            CloudSyncTransientAssociationKind::ReactionAdd
                        },
                        Some(map_cloud_sync_transient_reaction_kind(kind)),
                        Some(parent),
                        removed,
                    ),
                    None => match payload.association().sticker() {
                        Some(parent) => (
                            CloudSyncTransientAssociationKind::Sticker,
                            None,
                            Some(parent),
                            false,
                        ),
                        None => (CloudSyncTransientAssociationKind::None, None, None, false),
                    },
                };
            let reply = payload.reply();
            result.message = Some(CloudSyncTransientMessagePayload {
                logical_entity_key_hash: logical_entity_key_hash.to_owned(),
                canonical_guid: payload.guid().to_owned(),
                chat_alias_key_hash: payload.chat_alias_key_hash().value().to_owned(),
                chat_identifier: payload.chat_identifier().to_owned(),
                sender_handle: payload.sender_handle().to_owned(),
                created_at_millis: payload.created_at_millis(),
                error: payload.error(),
                service: map_cloud_sync_transient_service(payload.service()),
                subject_state: map_cloud_sync_transient_field_state(payload.subject().state()),
                subject: payload.subject().value().cloned(),
                body_state: map_cloud_sync_transient_field_state(payload.text_state()),
                body: payload.text().value().cloned(),
                attributed_bodies_state: map_cloud_sync_transient_field_state(
                    payload.attributed_bodies_state(),
                ),
                attributed_bodies: payload
                    .attributed_bodies()
                    .iter()
                    .map(map_cloud_sync_transient_attributed_body)
                    .collect(),
                balloon_bundle_id_state: map_cloud_sync_transient_field_state(
                    payload.balloon_bundle_id().state(),
                ),
                balloon_bundle_id: payload.balloon_bundle_id().value().cloned(),
                effect_state: map_cloud_sync_transient_field_state(payload.effect().state()),
                effect: payload.effect().value().cloned(),
                read_at_millis_state: map_cloud_sync_transient_field_state(
                    payload.read_at_millis().state(),
                ),
                read_at_millis: payload.read_at_millis().value().copied(),
                delivered_at_millis_state: map_cloud_sync_transient_field_state(
                    payload.delivered_at_millis().state(),
                ),
                delivered_at_millis: payload.delivered_at_millis().value().copied(),
                known_flags: map_cloud_sync_transient_known_flags(payload.flags()),
                association_kind,
                reaction_kind,
                reaction_removed,
                reaction_parent_logical_key_hash: association_parent
                    .map(|parent| parent.parent_hash().value().to_owned()),
                reaction_parent_canonical_guid: association_parent
                    .map(|parent| parent.parent_guid().to_owned()),
                reaction_parent_part: association_parent.and_then(|parent| parent.parent_part()),
                associated_range_location: association_parent
                    .and_then(|parent| parent.range_location()),
                associated_range_length: association_parent
                    .and_then(|parent| parent.range_length()),
                reply_parent_logical_key_hash: reply
                    .map(|parent| parent.parent_hash().value().to_owned()),
                reply_parent_canonical_guid: reply.map(|parent| parent.parent_guid().to_owned()),
                reply_parent_part: reply.map(|parent| parent.parent_part().to_owned()),
                edits_state: map_cloud_sync_transient_field_state(payload.edits_state()),
                edits: payload
                    .edits()
                    .iter()
                    .map(map_cloud_sync_transient_message_edit)
                    .collect(),
                retracted_parts_state: map_cloud_sync_transient_field_state(
                    payload.retracted_parts_state(),
                ),
                retracted_parts: payload.retracted_parts().to_vec(),
                associated_emoji_state: map_cloud_sync_transient_field_state(
                    payload.associated_emoji().state(),
                ),
                associated_emoji: payload.associated_emoji().value().cloned(),
            });
        }
        Canonical::Attachment(payload) => {
            result.attachment = Some(CloudSyncTransientAttachmentPayload {
                logical_entity_key_hash: logical_entity_key_hash.to_owned(),
                canonical_guid: payload.canonical_guid().to_owned(),
                owner_logical_key_hash: payload
                    .owner_message_key_hash()
                    .map(|value| value.value().to_owned()),
                owner_canonical_guid: payload.owner_message_guid().map(str::to_owned),
                owner_part: payload.owner_part(),
                uti_state: map_cloud_sync_transient_field_state(payload.uti().state()),
                uti: payload.uti().value().cloned(),
                file_name_state: map_cloud_sync_transient_field_state(
                    payload.transfer_name().state(),
                ),
                file_name: payload.transfer_name().value().cloned(),
                mime_type_state: map_cloud_sync_transient_field_state(payload.mime_type().state()),
                mime_type: payload.mime_type().value().cloned(),
                total_bytes_state: map_cloud_sync_transient_field_state(
                    payload.total_bytes().state(),
                ),
                total_bytes: payload.total_bytes().value().copied(),
                is_outgoing_state: map_cloud_sync_transient_field_state(
                    payload.is_outgoing().state(),
                ),
                is_outgoing: payload.is_outgoing().value().copied(),
                protected_local_reference_state: map_cloud_sync_transient_field_state(
                    payload.verified_local_file_reference().state(),
                ),
                protected_local_reference: payload
                    .verified_local_file_reference()
                    .value()
                    .map(|value| value.value().to_owned()),
            });
        }
        Canonical::GroupPhoto(payload) => {
            result.group_photo = Some(CloudSyncTransientGroupPhotoPayload {
                logical_entity_key_hash: logical_entity_key_hash.to_owned(),
                owner_logical_key_hash: payload.chat_key_hash().value().to_owned(),
                photo_guid: payload.photo_guid().to_owned(),
                protected_local_reference: payload
                    .verified_local_file_reference()
                    .value()
                    .to_owned(),
            });
        }
    }
    Some(result)
}

fn map_cloud_sync_transient_deferred(
    reason: crate::cloud_sync_canonical_converter::CloudCanonicalDeferredReason,
) -> CloudSyncTransientDeferredReason {
    use crate::cloud_sync_canonical_converter::CloudCanonicalDeferredReason as Canonical;
    match reason {
        Canonical::NestedPresenceUnavailable => {
            CloudSyncTransientDeferredReason::NestedPresenceUnavailable
        }
        Canonical::UnprovenEditTimestamp => CloudSyncTransientDeferredReason::UnprovenEditTimestamp,
        Canonical::UnsupportedExtensionPayload => {
            CloudSyncTransientDeferredReason::UnsupportedExtensionPayload
        }
        Canonical::UnsupportedMediaCredentials => {
            CloudSyncTransientDeferredReason::UnsupportedMediaCredentials
        }
        Canonical::UnsupportedGroupPhoto => CloudSyncTransientDeferredReason::UnsupportedGroupPhoto,
        Canonical::UnsupportedSticker => CloudSyncTransientDeferredReason::UnsupportedSticker,
        Canonical::UnsupportedScheduling => CloudSyncTransientDeferredReason::UnsupportedScheduling,
        Canonical::UnsupportedOffGridMetadata => {
            CloudSyncTransientDeferredReason::UnsupportedOffGridMetadata
        }
        Canonical::UnsupportedNegativeAttachmentSize => {
            CloudSyncTransientDeferredReason::UnsupportedNegativeAttachmentSize
        }
    }
}

fn map_cloud_sync_transient_quarantine(
    reason: crate::cloud_sync_canonical_converter::CloudCanonicalQuarantineReason,
) -> CloudSyncTransientQuarantineReason {
    use crate::cloud_sync_canonical_converter::CloudCanonicalQuarantineReason as Canonical;
    match reason {
        Canonical::MalformedRequiredIdentity => {
            CloudSyncTransientQuarantineReason::MalformedRequiredIdentity
        }
        Canonical::FieldPresenceMismatch => {
            CloudSyncTransientQuarantineReason::FieldPresenceMismatch
        }
        Canonical::UnsupportedService => CloudSyncTransientQuarantineReason::UnsupportedService,
        Canonical::UnsupportedChatStyle => CloudSyncTransientQuarantineReason::UnsupportedChatStyle,
        Canonical::UnsupportedMessageType => {
            CloudSyncTransientQuarantineReason::UnsupportedMessageType
        }
        Canonical::UnsupportedAssociationType => {
            CloudSyncTransientQuarantineReason::UnsupportedAssociationType
        }
        Canonical::MalformedParent => CloudSyncTransientQuarantineReason::MalformedParent,
        Canonical::AmbiguousReply => CloudSyncTransientQuarantineReason::AmbiguousReply,
        Canonical::MalformedAttributedBody => {
            CloudSyncTransientQuarantineReason::MalformedAttributedBody
        }
        Canonical::MalformedMessageSummary => {
            CloudSyncTransientQuarantineReason::MalformedMessageSummary
        }
        Canonical::ConflictingEditAndRetraction => {
            CloudSyncTransientQuarantineReason::ConflictingEditAndRetraction
        }
        Canonical::OversizedContent => CloudSyncTransientQuarantineReason::OversizedContent,
        Canonical::InvalidCanonicalPayload => {
            CloudSyncTransientQuarantineReason::InvalidCanonicalPayload
        }
        Canonical::MalformedRecord => CloudSyncTransientQuarantineReason::MalformedRecord,
    }
}

fn map_cloud_sync_transient_failure(
    failure: crate::cloud_sync_transient_bridge::CloudTransientBridgeFailure,
) -> CloudSyncTransientFailureCode {
    use crate::cloud_sync_transient_bridge::CloudTransientBridgeFailure as Native;
    match failure {
        Native::InvalidRequest => CloudSyncTransientFailureCode::InvalidRequest,
        Native::ActiveAccountMismatch => CloudSyncTransientFailureCode::ActiveAccountMismatch,
        Native::WarmAuthenticationRequired => {
            CloudSyncTransientFailureCode::WarmAuthenticationRequired
        }
        Native::ScopeMismatch => CloudSyncTransientFailureCode::ScopeMismatch,
        Native::GenerationMismatch => CloudSyncTransientFailureCode::GenerationMismatch,
        Native::StoreIdentityMismatch => CloudSyncTransientFailureCode::StoreIdentityMismatch,
        Native::ProtectedReferenceMismatch => {
            CloudSyncTransientFailureCode::ProtectedReferenceMismatch
        }
        Native::MalformedRecord => CloudSyncTransientFailureCode::MalformedRecord,
        Native::OversizedRecord => CloudSyncTransientFailureCode::OversizedRecord,
        Native::PcsUnavailable => CloudSyncTransientFailureCode::PcsUnavailable,
        Native::RetryableUpstream => CloudSyncTransientFailureCode::RetryableUpstream,
        Native::DecoderFailure => CloudSyncTransientFailureCode::DecoderFailure,
    }
}

fn cloud_sync_transient_empty_result(
    protected_source_reference: Option<String>,
    generation: u64,
) -> CloudSyncTransientDecodeResult {
    CloudSyncTransientDecodeResult {
        protected_source_reference,
        generation,
        change_id: None,
        entity_kind: None,
        mutation_kind: None,
        snapshot: None,
        payload: None,
        tombstone: None,
        deferred_reason: None,
        quarantine_reason: None,
        failure_code: None,
    }
}

fn is_cloud_sync_protected_source_reference(value: &str) -> bool {
    value.strip_prefix("obcs2.ref.").is_some_and(|suffix| {
        suffix.len() == 43
            && suffix
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    })
}

/// Reads, unprotects, decrypts, and canonically converts one D0 protected
/// change. No raw Apple/CloudKit identifier, credential, key, or record body
/// crosses FRB. This entry point is intentionally not wired into production
/// composition. `expected_payload_length` is optional for legacy D0 rows that
/// retained the exact SHA-256 but not the redundant byte count; the protected
/// capability, digest, change ID, record hash, etag hash, and server timestamp
/// fences remain mandatory.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_decode_protected_change(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
    native_stream: String,
    generation: u64,
    expected_change_kind: CloudSyncProtectedChangeKind,
    expected_change_id: String,
    expected_record_id_hash: String,
    expected_etag_hash: Option<String>,
    expected_payload_sha256: String,
    expected_payload_length: Option<u64>,
    expected_server_modified_at_millis: Option<i64>,
    protected_raw_envelope_reference: String,
    tombstone_entity_kind: Option<CloudSyncTransientEntityKind>,
    tombstone_logical_entity_key_hash: Option<String>,
) -> CloudSyncTransientDecodeResult {
    use crate::cloud_sync_native_fetch::CloudNativeStream;
    use crate::cloud_sync_transient_bridge::{
        cloud_sync_decode_transient_record, CloudTransientDecodeOutcome,
        CloudTransientDecodeRequest, CloudTransientExpectedChangeKind,
        CloudTransientTombstoneMapping,
    };

    let protected_source_reference =
        is_cloud_sync_protected_source_reference(&protected_raw_envelope_reference)
            .then(|| protected_raw_envelope_reference.clone());
    let mut failure_result =
        cloud_sync_transient_empty_result(protected_source_reference.clone(), generation);

    let Some(stream) = CloudNativeStream::parse(&native_stream) else {
        failure_result.failure_code = Some(CloudSyncTransientFailureCode::InvalidRequest);
        return failure_result;
    };
    let expected_change_kind = match expected_change_kind {
        CloudSyncProtectedChangeKind::Save => CloudTransientExpectedChangeKind::Save,
        CloudSyncProtectedChangeKind::Delete => CloudTransientExpectedChangeKind::Delete,
        CloudSyncProtectedChangeKind::Quarantined => CloudTransientExpectedChangeKind::Quarantined,
    };
    let tombstone_mapping = match (tombstone_entity_kind, tombstone_logical_entity_key_hash) {
        (Some(kind), Some(logical_hash)) => {
            match CloudTransientTombstoneMapping::new(
                unmap_cloud_sync_transient_entity_kind(kind),
                logical_hash,
            ) {
                Ok(mapping) => Some(mapping),
                Err(failure) => {
                    failure_result.failure_code = Some(map_cloud_sync_transient_failure(failure));
                    return failure_result;
                }
            }
        }
        (None, None) => None,
        _ => {
            failure_result.failure_code = Some(CloudSyncTransientFailureCode::InvalidRequest);
            return failure_result;
        }
    };
    let request = match CloudTransientDecodeRequest::new(
        PathBuf::from(storage_directory),
        expected_account_fingerprint,
        expected_protected_store_identity,
        container,
        database,
        zone,
        stream_kind,
        schema_version,
        stream,
        generation,
        expected_change_kind,
        expected_change_id,
        expected_record_id_hash,
        expected_etag_hash,
        expected_payload_sha256,
        expected_payload_length,
        expected_server_modified_at_millis,
        protected_raw_envelope_reference,
        tombstone_mapping,
    ) {
        Ok(request) => request,
        Err(failure) => {
            failure_result.failure_code = Some(map_cloud_sync_transient_failure(failure));
            return failure_result;
        }
    };

    match cloud_sync_decode_transient_record(cloud_messages_client, request).await {
        CloudTransientDecodeOutcome::Ready(mutation) => {
            let envelope = mutation.envelope();
            let source_matches = protected_source_reference.as_deref()
                == Some(envelope.protected_raw_envelope_reference().value());
            if envelope.generation() != generation || !source_matches {
                failure_result.failure_code =
                    Some(CloudSyncTransientFailureCode::GenerationMismatch);
                return failure_result;
            }
            let mut snapshot = mutation.snapshot().map(map_cloud_sync_transient_snapshot);
            let payload = mutation.payload().and_then(|payload| {
                map_cloud_sync_transient_payload(
                    envelope.logical_entity_key_hash().value(),
                    envelope.aliases(),
                    payload,
                )
            });
            if let (Some(snapshot), Some(payload)) = (&mut snapshot, &payload) {
                // Replace the decoder-internal/raw digest with the repair
                // digest over the exact transient canonical payload Dart will
                // validate before any local repair write.
                if let Some(digest) = cloudkit_repair_content_digest(payload) {
                    snapshot.immutable_content_digest = Some(digest);
                }
            }
            let tombstone = mutation
                .tombstone()
                .map(|tombstone| CloudSyncTransientTombstone {
                    entity_kind: map_cloud_sync_transient_entity_kind(tombstone.entity_kind()),
                    logical_entity_key_hash: tombstone.logical_entity_key_hash().value().to_owned(),
                    deleted_at_millis: tombstone.deleted_at_millis(),
                    server_confirmed: tombstone.server_confirmed(),
                });
            let mutation_kind = match envelope.mutation_kind() {
                crate::cloud_sync_canonical_dto::CloudCanonicalMutationKind::Upsert => {
                    CloudSyncTransientMutationKind::Upsert
                }
                crate::cloud_sync_canonical_dto::CloudCanonicalMutationKind::Tombstone => {
                    CloudSyncTransientMutationKind::Tombstone
                }
            };
            if (mutation_kind == CloudSyncTransientMutationKind::Upsert
                && (snapshot.is_none() || payload.is_none()))
                || (mutation_kind == CloudSyncTransientMutationKind::Tombstone
                    && tombstone.is_none())
            {
                failure_result.failure_code = Some(CloudSyncTransientFailureCode::DecoderFailure);
                return failure_result;
            }
            CloudSyncTransientDecodeResult {
                protected_source_reference,
                generation: envelope.generation(),
                change_id: Some(envelope.change_id().value().to_owned()),
                entity_kind: Some(map_cloud_sync_transient_entity_kind(envelope.entity_kind())),
                mutation_kind: Some(mutation_kind),
                snapshot,
                payload,
                tombstone,
                deferred_reason: None,
                quarantine_reason: None,
                failure_code: None,
            }
        }
        CloudTransientDecodeOutcome::Deferred(reason) => {
            let mut result =
                cloud_sync_transient_empty_result(protected_source_reference, generation);
            result.deferred_reason = Some(map_cloud_sync_transient_deferred(reason));
            result
        }
        CloudTransientDecodeOutcome::Quarantined(reason) => {
            let mut result =
                cloud_sync_transient_empty_result(protected_source_reference, generation);
            result.quarantine_reason = Some(map_cloud_sync_transient_quarantine(reason));
            result
        }
        CloudTransientDecodeOutcome::Failure(failure) => {
            failure_result.failure_code = Some(map_cloud_sync_transient_failure(failure));
            failure_result
        }
    }
}

#[cfg(test)]
mod cloud_sync_protected_bridge_contract_tests {
    use super::{
        cloud_sync_transient_empty_result, is_cloud_sync_lease_reference,
        is_cloud_sync_protected_reference, is_cloud_sync_protected_source_reference,
        CloudSyncTransientFailureCode,
    };

    #[test]
    fn outbound_capabilities_require_exact_bounded_formats() {
        assert!(is_cloud_sync_protected_reference(&format!(
            "obcs2.ref.{}",
            "A".repeat(43)
        )));
        assert!(!is_cloud_sync_protected_reference("obcs2.ref.short"));
        assert!(!is_cloud_sync_protected_reference(&format!(
            "obcs2.ref.{}extra",
            "A".repeat(43)
        )));
        assert!(is_cloud_sync_lease_reference(&format!(
            "obcs2.lease.{}",
            "a".repeat(32)
        )));
        assert!(!is_cloud_sync_lease_reference(&format!(
            "obcs2.lease.{}",
            "A".repeat(32)
        )));
    }

    #[test]
    fn protected_dtos_contain_only_hashes_opaque_references_and_safe_scalars() {
        let source = include_str!("api.rs");
        let dto_source = source
            .split("// CLOUD_SYNC_PROTECTED_DTO_BEGIN")
            .nth(1)
            .and_then(|source| source.split("// CLOUD_SYNC_PROTECTED_DTO_END").next())
            .expect("protected DTO source markers");
        for forbidden in [
            "record_name:",
            "etag: Option<String>",
            "continuation_token",
            "encrypted_record",
            "tombstone_payload",
            "credentials",
            "PathBuf",
            "storage_directory",
        ] {
            assert!(
                !dto_source.contains(forbidden),
                "protected DTO boundary must not expose {forbidden}"
            );
        }
    }

    #[test]
    fn transient_dtos_exclude_native_identifiers_credentials_and_binary_records() {
        let source = include_str!("api.rs");
        let dto_source = source
            .split("// CLOUD_SYNC_TRANSIENT_DTO_BEGIN")
            .nth(1)
            .and_then(|source| source.split("// CLOUD_SYNC_TRANSIENT_DTO_END").next())
            .expect("transient DTO source markers");
        for forbidden in [
            "record_name:",
            "record_type:",
            "server_record_id:",
            "raw_account_identifier:",
            "continuation_token:",
            "credentials:",
            "decryption_key:",
            "encrypted_record:",
            "Vec<u8>",
            "PathBuf",
            "Serialize",
            "Deserialize",
            "derive(Clone, Debug",
        ] {
            assert!(
                !dto_source.contains(forbidden),
                "transient DTO boundary must not expose {forbidden}"
            );
        }
        assert!(dto_source.contains("protected_source_reference:"));
    }

    #[test]
    fn transient_source_reference_grammar_is_closed() {
        let valid = format!("obcs2.ref.{}", "A".repeat(43));
        assert!(is_cloud_sync_protected_source_reference(&valid));
        for invalid in [
            "",
            "obcs2.ref.short",
            "obcs2.ref.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/",
            "obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "raw-record-id",
        ] {
            assert!(!is_cloud_sync_protected_source_reference(invalid));
        }
    }

    #[test]
    fn transient_failure_result_contains_one_safe_disposition_and_no_content() {
        let source = format!("obcs2.ref.{}", "B".repeat(43));
        let mut result = cloud_sync_transient_empty_result(Some(source.clone()), 9);
        result.failure_code = Some(CloudSyncTransientFailureCode::ScopeMismatch);
        assert_eq!(
            result.protected_source_reference.as_deref(),
            Some(source.as_str())
        );
        assert_eq!(result.generation, 9);
        assert!(result.change_id.is_none());
        assert!(result.snapshot.is_none());
        assert!(result.payload.is_none());
        assert!(result.tombstone.is_none());
        assert!(result.deferred_reason.is_none());
        assert!(result.quarantine_reason.is_none());
        assert_eq!(
            result.failure_code,
            Some(CloudSyncTransientFailureCode::ScopeMismatch)
        );
    }
}

#[frb(opaque)]
#[derive(Serialize, Deserialize, Clone)]
#[serde(tag = "type")]
pub enum JoinedOSConfig {
    MacOS(Arc<MacOSConfig>),
    Relay(Arc<RelayConfig>),
}

impl JoinedOSConfig {
    fn config(&self) -> Arc<dyn OSConfig> {
        match self {
            Self::MacOS(conf) => conf.clone(),
            Self::Relay(conf) => conf.clone(),
        }
    }
}

impl Deref for JoinedOSConfig {
    type Target = dyn OSConfig;

    fn deref(&self) -> &Self::Target {
        match self {
            Self::MacOS(conf) => conf.as_ref(),
            Self::Relay(conf) => conf.as_ref(),
        }
    }
}

pub trait SeekRead: Seek + Read {}
impl<T: Seek + Read> SeekRead for T {}

#[derive(Serialize, Deserialize, Clone)]
pub struct SavedHardwareState {
    pub push: APSState,
    #[serde(serialize_with = "bin_serialize", deserialize_with = "bin_deserialize")]
    pub identity: Vec<u8>,
    pub os_config: JoinedOSConfig,
}

#[frb(sync)]
pub fn decode_identity(identity: &[u8]) -> anyhow::Result<IDSNGMIdentity> {
    Ok(IDSNGMIdentity::restore(identity, "openbubbles")?)
}

pub fn bin_serialize<S>(x: &[u8], s: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    s.serialize_bytes(x)
}

fn bin_deserialize_16<'de, D>(d: D) -> Result<[u8; 16], D::Error>
where
    D: Deserializer<'de>,
{
    let s: Data = Deserialize::deserialize(d)?;
    let s: Vec<u8> = s.into();
    Ok(s.try_into().unwrap())
}

pub fn bin_deserialize<'de, D>(d: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    let s: Data = Deserialize::deserialize(d)?;
    Ok(s.into())
}

#[cfg(not(target_os = "android"))]
pub type MyFilePackager = FFMpegFilePackager;

#[cfg(target_os = "android")]
pub type MyFilePackager = FFIFilePackager;

#[derive(Default)]
pub struct FFIFilePackager {}

#[frb(sync)]
pub fn decode_extension_app(bp: &[u8], bid: &str) -> anyhow::Result<ExtensionApp> {
    Ok(ExtensionApp::from_bp(bp, bid)?)
}

#[frb(sync)]
pub fn encode_extension_app(app: &ExtensionApp) -> anyhow::Result<(Vec<u8>, Option<Vec<u8>>)> {
    Ok(app.to_raw()?)
}

impl FilePackager for FFIFilePackager {
    type Reader = Box<dyn SeekRead + Send + Sync>;
    async fn get_files(&mut self, path: PathBuf) -> Result<PreparedAsset<Self::Reader>, PushError> {
        info!("Preparing to package {}", PACKAGER_LOCK.get().is_some());
        let processed = PACKAGER_LOCK
            .get()
            .expect("No FFI packager!")
            .get_file(path.to_str().unwrap().to_string());

        info!("Packaged");
        let inner = match processed {
            PackagedFile::Failure(failure) => return Err(PushError::FilePackageError(failure)),
            PackagedFile::Info(info) => info,
        };

        let is_video = inner.duration.is_some();
        let file = PreparedFile::<Box<dyn SeekRead + Send + Sync>>::new(
            Box::new(File::open(&path)?),
            FileMetadata {
                width: inner.width as usize,
                height: inner.height as usize,
                uti_type: if is_video {
                    "public.mpeg-4".to_string()
                } else {
                    "public.jpeg".to_string()
                },
                video_type: if is_video {
                    Some("720p".to_string())
                } else {
                    None
                },
                asset_metadata: if !is_video {
                    Some(AssetMetadata {
                        asset_type: "derivative".to_string(),
                        asset_type_flags: 2,
                    })
                } else {
                    None
                },
            },
        )
        .await?;

        let mut prepared_files = vec![file];

        if let Some(thumbnail) = inner.thumbnail {
            let thumbnail = PreparedFile::<Box<dyn SeekRead + Send + Sync>>::new(
                Box::new(Cursor::new(thumbnail)),
                FileMetadata {
                    width: inner.width as usize,
                    height: inner.height as usize,
                    uti_type: "public.jpeg".to_string(),
                    video_type: Some("PosterFrame".to_string()),
                    asset_metadata: None,
                },
            )
            .await?;
            prepared_files.push(thumbnail);
        }

        Ok(PreparedAsset {
            files: prepared_files,
            name: path.file_name().unwrap().to_str().unwrap().to_string(),
            date_created: fs::metadata(path)?.created().unwrap_or(SystemTime::now()),
            video_duration: inner.duration,
            guid: Uuid::new_v4().to_string().to_uppercase(),
        })
    }
}

pub struct ActiveCircleSession {
    session: CircleServerSession<DefaultAnisetteProvider>,
    atxnid: String,
    txnid: String,
    init_message: Option<IdmsCircleMessage>,
    otp: u32,
}

pub fn service_from_ptr(ptr: String) -> Option<SharedPushState> {
    let pointer: u64 = ptr.parse().unwrap();
    info!("using state {pointer}");
    let service = unsafe { Weak::from_raw(pointer as *const SharedPushState) };
    service.upgrade().map(|s| (*s).clone())
}

fn plist_to_buf<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, plist::Error> {
    let mut buf: Vec<u8> = Vec::new();
    let writer = Cursor::new(&mut buf);
    plist::to_writer_xml(writer, &value)?;
    Ok(buf)
}

fn plist_to_string<T: serde::Serialize>(value: &T) -> Result<String, plist::Error> {
    plist_to_buf(value).map(|val| String::from_utf8(val).unwrap())
}

fn plist_to_bin<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, plist::Error> {
    let mut buf: Vec<u8> = Vec::new();
    let writer = Cursor::new(&mut buf);
    plist::to_writer_binary(writer, &value)?;
    Ok(buf)
}

fn migrate(path: String) -> bool {
    let dir = PathBuf::from_str(&path).unwrap();
    let hw_config_path = dir.join("hw_info.plist");

    if let Ok(mut item) = plist::from_file::<_, Dictionary>(&hw_config_path) {
        if let Some(v) = item.get("os_config") {
            let config: JoinedOSConfig = plist::from_value(v).expect("got os ");
            if let Some(Value::Dictionary(dict)) = item.get_mut("push") {
                if let Some(Value::Dictionary(item)) = dict.get_mut("keypair") {
                    if let Some(private) = item.get_mut("private") {
                        if let Value::Data(cert) = private {
                            let handle = format!("activation:{}", config.get_serial_number());
                            RsaKey::import(
                                &handle,
                                1024,
                                cert,
                                KeystoreAccessRules {
                                    signature_padding: vec![KeystorePadding::PKCS1],
                                    digests: vec![KeystoreDigest::Sha1],
                                    can_sign: true,
                                    ..Default::default()
                                },
                            )
                            .expect("failed to import RSA");
                            *private = Value::String(handle);
                            plist::to_file_xml(&hw_config_path, &item).expect("failed to save!");
                        }
                    }
                }
            }
        }
        if let Some(value) = item.get_mut("identity") {
            if value.as_dictionary().is_some() {
                let identity: IDSNGMIdentity =
                    plist::from_value(&value).expect("NGM Identity parse");
                *value = Value::Data(identity.save("openbubbles").expect("Failed to save"));
                plist::to_file_xml(&hw_config_path, &item).expect("failed to save!");
            }
        }
    }

    let id_path = dir.join("id.plist");
    if let Ok(mut users) = plist::from_file::<_, Vec<Dictionary>>(&id_path) {
        let mut modified = false;
        for user in &mut users {
            let user_id = user
                .get("user_id")
                .unwrap()
                .as_string()
                .unwrap()
                .to_string();
            if let Some(Value::Dictionary(item)) = user.get_mut("auth_keypair") {
                if let Some(private) = item.get_mut("private") {
                    if let Value::Data(cert) = private {
                        let handle = format!("ids:{user_id}");
                        RsaKey::import(
                            &handle,
                            2048,
                            cert,
                            KeystoreAccessRules {
                                signature_padding: vec![KeystorePadding::PKCS1],
                                digests: vec![KeystoreDigest::Sha1],
                                can_sign: true,
                                ..Default::default()
                            },
                        )
                        .expect("failed to import RSA");
                        *private = Value::String(handle);
                        modified = true;
                    }
                }
            }
            if let Some(Value::Dictionary(item)) = user.get_mut("registration") {
                for service in item.values_mut() {
                    if let Some(Value::Dictionary(item)) =
                        service.as_dictionary_mut().unwrap().get_mut("id_keypair")
                    {
                        if let Some(private) = item.get_mut("private") {
                            if let Value::Data(cert) = private {
                                let handle = format!("ids:{user_id}");
                                *private = Value::String(handle);
                            }
                        }
                    }
                }
            }
        }
        if modified {
            plist::to_file_xml(&id_path, &users).expect("failed to save!");
        }
    }

    let cloudkit_path = dir.join("keychain.plist");
    if let Ok(mut users) = plist::from_file::<_, Dictionary>(&cloudkit_path) {
        let anisette_path = dir.join("anisette_test/state.plist");
        if let Ok(AnisetteState {
            provisioned: Some(ProvisionedAnisette { mid, .. }),
            ..
        }) = plist::from_file::<_, AnisetteState>(&anisette_path)
        {
            let mid = base64_encode(mid.as_ref());
            let mut migrate = false;
            let dsid = users.get("dsid").unwrap().as_string().unwrap().to_string();
            if let Some(Value::Dictionary(item)) = users.get_mut("user_identity") {
                if let Some(private) = item.get_mut("signing_key") {
                    if let Value::Data(cert) = private {
                        let handle = format!("keychain:signing:{mid}");
                        EcKeystoreKey::import(
                            &handle,
                            EcCurve::P384,
                            &cert,
                            KeystoreAccessRules {
                                can_sign: true,
                                digests: vec![KeystoreDigest::Sha384, KeystoreDigest::Sha256],
                                ..Default::default()
                            },
                        )
                        .expect("Failed to import EC");
                        *private = Value::String(handle);
                        migrate = true;
                    }
                }
                if let Some(private) = item.get_mut("encryption_key") {
                    if let Value::Data(cert) = private {
                        let handle = format!("keychain:encryption:{mid}");
                        EcKeystoreKey::import(
                            &handle,
                            EcCurve::P384,
                            &cert,
                            KeystoreAccessRules {
                                can_agree: true,
                                digests: vec![KeystoreDigest::Sha384, KeystoreDigest::Sha256],
                                ..Default::default()
                            },
                        )
                        .expect("Failed to import EC");
                        *private = Value::String(handle);
                    }
                }
            }
            if migrate {
                if let Some(private) = users.get_mut("current_bottle") {
                    // convert escrowed_signing_key to data from vec u8
                    #[derive(Deserialize)]
                    struct BadBottle {
                        escrowed_signing_key: Vec<u8>,
                    }
                    let bad: BadBottle =
                        plist::from_value(&private).expect("bottle Identity parse");
                    let dict = private.as_dictionary_mut().unwrap();
                    dict.insert(
                        "escrowed_signing_key".to_string(),
                        Value::Data(bad.escrowed_signing_key),
                    );

                    let identity: CurrentBottle =
                        plist::from_value(&private).expect("bottle Identity parse");
                    *private = Value::Data(identity.save(&dsid).expect("Failed to save"));
                }
                if let Some(Value::Array(items)) = users.get_mut("keystore") {
                    let keystore = SivKey(
                        keystore()
                            .ensure_secret(&format!("keychain:cloudkey-access-key:{}", dsid), 64)
                            .expect("wha"),
                    );
                    for key in items {
                        let Value::Data(data) = key else { continue };
                        let serialized = CuttlefishSerializedKey::decode(&mut Cursor::new(data))
                            .expect("failed to decode");
                        let cloud = CloudKey::from_serialized_key(serialized, &keystore);
                        *key = plist::to_value(&cloud).expect("Faield to serizsdf");
                    }
                }
                if let Some(Value::Dictionary(dict)) = users.get_mut("items") {
                    dict.clear();
                }
                plist::to_file_xml(&cloudkit_path, &users).expect("failed to save!");
            }
        }
    }

    let gsa_path = dir.join("gsa.plist");
    if let Ok(mut account) = plist::from_file::<_, Dictionary>(&gsa_path) {
        if let Some(Value::Data(password)) = account.remove("password") {
            account.insert(
                "encrypted_password".to_string(),
                Value::Data(GSAConfig::encrypt(&password).expect("Undo").into()),
            );
            plist::to_file_xml(&gsa_path, &account).expect("failed to save!");

            let findmy = dir.join("findmy.plist");
            if let Ok(users) = plist::from_file::<_, FindMyState>(&findmy) {
                std::fs::write(findmy, users.encode().expect("what")).unwrap();
            }
        }
    }

    false
}

#[frb(sync)]
pub fn new_ngm_identity() -> anyhow::Result<IDSNGMIdentity> {
    Ok(IDSNGMIdentity::new()?)
}

#[frb(sync)]
pub fn read_hardware(path: String) -> Option<SavedHardwareState> {
    let dir = PathBuf::from_str(&path).unwrap();
    let hw_config_path = dir.join("hw_info.plist");

    plist::from_file::<_, SavedHardwareState>(&hw_config_path).ok()
}

#[frb(sync)]
pub fn reset_anisette(path: String) {
    let dir = PathBuf::from_str(&path).unwrap();

    let anisette_dir = dir.join("anisette_test");
    if anisette_dir.exists() {
        fs::remove_dir_all(dir.join("anisette_test")).expect("failed to remvoe anisette");
    }
}

pub async fn make_anisette(
    path: String,
    config: &JoinedOSConfig,
    conn: &APSConnection,
) -> ArcAnisetteClient<DefaultAnisetteProvider> {
    let dir = PathBuf::from_str(&path).unwrap();

    default_provider(
        get_login_config(&dir, config, conn).await,
        dir.join("anisette_test"),
    )
}

#[frb(sync)]
pub fn restore_users(path: String) -> Option<Vec<IDSUser>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let id_path = dir.join("id.plist");
    plist::from_file::<_, Vec<IDSUser>>(&id_path).ok()
}

#[frb(sync)]
pub fn save_users(users: &Vec<IDSUser>, path: String) {
    let dir = PathBuf::from_str(&path).unwrap();
    let id_path = dir.join("id.plist");

    plist::to_file_xml(id_path, users).unwrap();
}

pub async fn make_imclient(
    path: String,
    conn: &APSConnection,
    users: &Vec<IDSUser>,
    identity: &IDSNGMIdentity,
) -> Arc<IMClient> {
    let dir = PathBuf::from_str(&path).unwrap();
    let id_path = dir.join("id.plist");

    let incident_path = dir.join("incident");
    if !incident_path.exists() {
        if plist::from_file::<_, KeyCache>(dir.join("id_cache.plist")).is_ok() {
            let _ = fs::File::create(dir.join("incident_affected"));
        }
        let _ = fs::File::create(incident_path);
    }

    Arc::new(
        IMClient::new(
            conn.clone(),
            users.clone(),
            identity.clone(),
            &[
                &MADRID_SERVICE,
                &MULTIPLEX_SERVICE,
                &FACETIME_SERVICE,
                &VIDEO_SERVICE,
            ],
            dir.join("id_cache.plist"),
            conn.os_config.clone(),
            Box::new(move |updated_keys| {
                println!("updated keys!!!");
                std::fs::write(&id_path, plist_to_string(&updated_keys).unwrap()).unwrap();
            }),
        )
        .await,
    )
}

pub struct APSWatcher {
    reg_state: watch::Receiver<ResourceState>,
    cancel_poll_recv: mpsc::Receiver<()>,
    local_messages: mpsc::Receiver<PushMessage>,
    inq_queue: broadcast::Receiver<APSMessage>,
}

#[frb(sync)]
pub fn build_watcher(
    conn: &APSConnection,
    client: &Arc<IMClient>,
) -> (mpsc::Sender<()>, Arc<mpsc::Sender<PushMessage>>, APSWatcher) {
    import_watcher(conn.messages_cont.subscribe(), client)
}

#[frb(sync)]
pub fn import_watcher(
    queue: broadcast::Receiver<APSMessage>,
    client: &Arc<IMClient>,
) -> (mpsc::Sender<()>, Arc<mpsc::Sender<PushMessage>>, APSWatcher) {
    let (cancel_send, cancel_recv) = mpsc::channel::<()>(1);
    let (sender, recv) = mpsc::channel(999);

    (
        cancel_send,
        Arc::new(sender),
        APSWatcher {
            reg_state: client.identity.resource_state.subscribe(),
            cancel_poll_recv: cancel_recv,
            local_messages: recv,
            inq_queue: queue,
        },
    )
}

#[frb(sync)]
pub fn subscribe_conn(conn: &APSConnection) -> broadcast::Receiver<APSMessage> {
    conn.messages_cont.subscribe()
}

#[frb(ignore)]
pub struct DaemonData {
    pub watcher: APSWatcher,
    pub state: SharedPushState,
}

#[frb(sync)]
pub fn send_daemon(state: SharedPushState, watcher: APSWatcher) -> (String, SharedPushState) {
    let data = DaemonData {
        watcher,
        state: state.clone(),
    };

    let num = Box::into_raw(Box::new(data)) as u64;

    info!("emitting pointer {num}");

    (num.to_string(), state)
}

#[frb(sync)]
pub fn dup_daemon_desk(state: SharedPushState) -> (Arc<SharedPushState>, SharedPushState) {
    (Arc::new(state.clone()), state)
}

#[frb(non_opaque)]
#[derive(Clone)]
pub struct SharedPushState {
    // core config
    pub os_config: JoinedOSConfig,
    pub cancel_poll: mpsc::Sender<()>,
    pub conf_dir: String,
    pub local_broadcast: Arc<mpsc::Sender<PushMessage>>,

    // core services
    pub anisette: ArcAnisetteClient<DefaultAnisetteProvider>,
    pub conn: APSConnection,
    pub icloud_services: Option<SharedICloudServices>,

    // APN services
    pub client: Arc<IMClient>,
    pub ft_client: Arc<FTClient>,
    pub idms_client: Arc<IdmsAuthListener>,

    // state
    pub active_circle_sessions: Arc<Mutex<Vec<ActiveCircleSession>>>,
    pub client_session: Arc<Mutex<Option<CircleClientSession<DefaultAnisetteProvider>>>>,
}

pub async fn make_idms(conn: &APSConnection) -> Arc<IdmsAuthListener> {
    IdmsAuthListener::new(conn.clone()).await.into()
}

#[frb(non_opaque)]
#[derive(Clone)]
pub struct SharedICloudServices {
    pub account: Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    pub token_provider: Arc<TokenProvider<DefaultAnisetteProvider>>,

    pub cloudkit_client: Option<Arc<CloudKitClient<DefaultAnisetteProvider>>>,
    pub keychain: Option<Arc<KeychainClient<DefaultAnisetteProvider>>>,
    pub passwords: Option<Arc<PasswordManager<DefaultAnisetteProvider>>>,
    pub profiles_client: Arc<ProfilesClient<DefaultAnisetteProvider>>,
    pub fmfd: Option<Arc<FindMyClient<DefaultAnisetteProvider>>>,
    pub sharedstreams: Option<SyncManager<DefaultAnisetteProvider, MyFilePackager>>,
    pub cloud_messages_client: Option<Arc<CloudMessagesClient<DefaultAnisetteProvider>>>,
    pub statuskit_client: Arc<StatusKitClient<DefaultAnisetteProvider>>,
}

impl SharedPushState {
    pub async fn restore(path: String) -> Option<(Self, APSWatcher)> {
        info!("restroing");
        let dir = PathBuf::from_str(&path).unwrap();
        let keystore = dir.join("keystore.plist");

        #[cfg(target_os = "windows")]
        {
            let opened = match open_windows_keystore(&keystore) {
                Ok(opened) => opened,
                Err(error) => {
                    error!("Windows protected keystore restore failed: {error}");
                    return None;
                }
            };
            let writer = opened.writer;
            init_keystore(SoftwareKeystore {
                state: std::sync::RwLock::new(opened.state),
                update_state: Box::new(move |state| {
                    writer
                        .write_state(state)
                        .expect("Windows protected keystore persistence failed");
                }),
                encryptor: opened.encryptor,
            });
        }

        #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
        init_keystore(SoftwareKeystore {
            state: plist::from_file(&keystore).unwrap_or_default(),
            update_state: Box::new(move |state| {
                plist::to_file_xml(&keystore, state).unwrap();
            }),
            encryptor: SoftwareEncryptor(*b"desktopisinsecureyoushouldn'tber"),
        });

        if let Err(err) = panic::catch_unwind(|| {
            migrate(path.clone());
        }) {
            if let Some(s) = err.downcast_ref::<&str>() {
                info!("Panic message: {}", s);
            } else if let Some(s) = err.downcast_ref::<String>() {
                info!("Panic message: {}", s);
            } else {
                info!("Panic occurred, but message has unknown type");
            }

            panic!("panicked")
        }

        let hardware = read_hardware(path.clone())?;
        let users = restore_users(path.clone())?;
        let config = &hardware.os_config;
        let identity = IDSNGMIdentity::restore(hardware.identity.as_ref(), "openbubbles").ok()?;
        let (conn, _) =
            setup_push(config, &identity, Some(hardware.push.clone()), path.clone()).await;
        let client = make_imclient(path.clone(), &conn, &users, &identity).await;
        let anisette = make_anisette(path.clone(), config, &conn).await;

        let account = restore_account(path.clone(), &anisette, config, &conn).await;

        info!("account {}", account.is_some());

        let (cancel_poll, local_broadcast, watcher) = build_watcher(&conn, &client);

        Some((
            Self {
                os_config: config.clone(),
                cancel_poll,
                conf_dir: path.clone(),
                local_broadcast,

                anisette: anisette.clone(),
                conn: conn.clone(),
                icloud_services: if let Some(account) = &account {
                    let token_provider = make_token_provider(account, config);
                    let cloudkit = make_cloudkit(path.clone(), &anisette, config, &token_provider)
                        .await
                        .expect("todo remove");
                    let keychain =
                        make_keychain(path.clone(), &cloudkit, &anisette, config, &token_provider);

                    Some(SharedICloudServices {
                        account: account.clone(),
                        token_provider: token_provider.clone(),

                        cloudkit_client: Some(cloudkit.clone()),
                        keychain: keychain.clone(),
                        passwords: if let Some(keychain) = &keychain {
                            Some(
                                make_passwords(path.clone(), keychain, &cloudkit, &client, &conn)
                                    .await,
                            )
                        } else {
                            None
                        },
                        profiles_client: make_profiles(&cloudkit).await,
                        fmfd: if let Some(keychain) = &keychain {
                            make_findmy(
                                path.clone(),
                                &token_provider,
                                &conn,
                                &cloudkit,
                                &keychain,
                                &anisette,
                                config,
                                &client,
                            )
                            .await
                        } else {
                            None
                        },
                        sharedstreams: make_shared_streams(
                            path.clone(),
                            &conn,
                            &anisette,
                            config,
                            &token_provider,
                        )
                        .await,
                        cloud_messages_client: if let Some(keychain) = &keychain {
                            Some(make_cloud_messages_client(&cloudkit, &keychain))
                        } else {
                            None
                        },
                        statuskit_client: make_statuskit(
                            path.clone(),
                            &token_provider,
                            &conn,
                            config,
                            &client,
                        )
                        .await,
                    })
                } else {
                    None
                },

                ft_client: make_facetime(path.clone(), &conn, &client).await,
                client,
                idms_client: make_idms(&conn).await,

                active_circle_sessions: make_circle_sessions(),
                client_session: make_client_session(None),
            },
            watcher,
        ))
    }
}

#[frb(sync)]
pub fn make_client_session(
    circle: Option<CircleClientSession<DefaultAnisetteProvider>>,
) -> Arc<Mutex<Option<CircleClientSession<DefaultAnisetteProvider>>>> {
    Arc::new(Mutex::new(circle))
}

#[frb(sync)]
pub fn make_circle_sessions() -> Arc<Mutex<Vec<ActiveCircleSession>>> {
    Arc::new(Mutex::new(vec![]))
}

pub async fn restore_account(
    path: String,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    config: &JoinedOSConfig,
    conn: &APSConnection,
) -> Option<Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let mut state = plist::from_file::<_, GSAConfig>(&dir.join("gsa.plist")).ok()?;

    let mut apple_account = AppleAccount::new_with_anisette(
        get_login_config(&dir, config, conn).await,
        anisette.clone(),
    )
    .expect("aacbf?");

    apple_account.username = Some(state.username.clone());
    apple_account.hashed_password = state.get_password().ok();

    if state.postdata_done.is_none() {
        info!("Updating postdata");
        let _ = apple_account
            .update_postdata("Apple Device", None, &["icloud", "imessage", "facetime"])
            .await;
        state.postdata_done = Some(true);
        plist::to_file_xml(dir.join("gsa.plist"), &state).unwrap();
    }

    Some(Arc::new(Mutex::new(apple_account)))
}

#[frb(sync)]
pub fn make_token_provider(
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    config: &JoinedOSConfig,
) -> Arc<TokenProvider<DefaultAnisetteProvider>> {
    TokenProvider::new(account.clone(), config.config())
}

pub async fn make_shared_streams(
    path: String,
    conn: &APSConnection,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    config: &JoinedOSConfig,
    token: &Arc<TokenProvider<DefaultAnisetteProvider>>,
) -> Option<SyncManager<DefaultAnisetteProvider, MyFilePackager>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let stream_path = dir.join("sharedstreams.plist");

    let state = plist::from_file(&stream_path).ok()?;

    let client = SharedStreamClient::new(
        state,
        Box::new(move |update| {
            plist::to_file_xml(&stream_path, update).unwrap();
        }),
        token.clone(),
        conn.clone(),
        anisette.clone(),
        config.config(),
    )
    .await;

    let sync = SyncController::new(
        client,
        dir.join("sync.plist"),
        MyFilePackager::default(),
        Duration::from_secs(60 * 30),
    )
    .await;
    subscribe_streams(sync.clone());

    Some(sync)
}

pub async fn make_cloudkit(
    path: String,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    config: &JoinedOSConfig,
    token_provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
) -> Option<Arc<CloudKitClient<DefaultAnisetteProvider>>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let cloudkit_path = dir.join("cloudkit.plist");

    let state = plist::from_file(&cloudkit_path).ok()?;
    let cloudkit = Arc::new(CloudKitClient {
        state: DebugRwLock::new(state),
        anisette: anisette.clone(),
        config: config.config(),
        token_provider: token_provider.clone(),
    });

    Some(cloudkit)
}

pub async fn make_profiles(
    cloudkit: &Arc<CloudKitClient<DefaultAnisetteProvider>>,
) -> Arc<ProfilesClient<DefaultAnisetteProvider>> {
    Arc::new(ProfilesClient::new(cloudkit.clone()))
}

pub async fn make_passwords(
    path: String,
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
    cloudkit: &Arc<CloudKitClient<DefaultAnisetteProvider>>,
    client: &Arc<IMClient>,
    conn: &APSConnection,
) -> Arc<PasswordManager<DefaultAnisetteProvider>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let path = dir.join("passwords.plist");
    let state: PasswordState = plist::from_file(&path).unwrap_or_default();

    PasswordManager::new(
        keychain.clone(),
        cloudkit.clone(),
        client.identity.clone(),
        conn.clone(),
        state,
        Box::new(move |item| {
            plist::to_file_xml(&path, item).expect("Failed to serialize plist!");
        }),
        Box::new(|manager, wifi| {
            if !wifi {
                return;
            }
            tokio::spawn(async move {
                sync_wifi_passwords(&manager, false).await;
            });
        }),
    )
    .await
}

pub async fn sync_wifi_passwords(
    manager: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    user_approve: bool,
) {
    let wifi_networks: HashMap<String, String> = get_wifi_passwords(manager)
        .await
        .into_values()
        .map(|(_, p)| (p.acct, String::from_utf8(p.data).expect("bad password!")))
        .collect();

    if let Some(handle) = HANDLE_WIFI_NETWORKS.get() {
        handle.handle_wifi_networks(wifi_networks, user_approve);
    }
}

pub async fn make_facetime(
    path: String,
    conn: &APSConnection,
    client: &Arc<IMClient>,
) -> Arc<FTClient> {
    let dir = PathBuf::from_str(&path).unwrap();
    let facetime_path = dir.join("facetime.plist");
    let state: FTState = plist::from_file(&facetime_path).unwrap_or_default();
    Arc::new(
        FTClient::new(
            state,
            Box::new(move |state| {
                plist::to_file_xml(&facetime_path, state).expect("Failed to serialize plist!");
            }),
            conn.clone(),
            client.identity.clone(),
            conn.os_config.clone(),
        )
        .await,
    )
}

pub async fn make_statuskit(
    path: String,
    provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
    conn: &APSConnection,
    config: &JoinedOSConfig,
    client: &Arc<IMClient>,
) -> Arc<StatusKitClient<DefaultAnisetteProvider>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let path = dir.join("statuskit.plist");
    let state: StatusKitState = plist::from_file(&path).unwrap_or_default();
    StatusKitClient::new(
        state,
        Box::new(move |state| {
            plist::to_file_xml(&path, state).unwrap();
        }),
        provider.clone(),
        conn.clone(),
        config.config(),
        client.identity.clone(),
    )
    .await
}

#[frb(sync)]
pub fn make_keychain(
    path: String,
    cloudkit: &Arc<CloudKitClient<DefaultAnisetteProvider>>,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    config: &JoinedOSConfig,
    token_provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
) -> Option<Arc<KeychainClient<DefaultAnisetteProvider>>> {
    let dir = PathBuf::from_str(&path).unwrap();
    let cloudkit_path = dir.join("keychain.plist");

    if let Err(e) = plist::from_file::<_, KeychainClientState>(&cloudkit_path) {
        info!("Failed to desrialized {e}");
    }

    let state: KeychainClientState = plist::from_file(&cloudkit_path).ok()?;

    Some(Arc::new(KeychainClient {
        anisette: anisette.clone(),
        token_provider: token_provider.clone(),
        state: DebugRwLock::new(state),
        config: config.config(),
        update_state: Box::new(move |update| {
            plist::to_file_xml(&cloudkit_path, update).unwrap();
        }),
        container: tokio::sync::Mutex::new(None),
        container_initialization: tokio::sync::Mutex::new(()),
        security_container: tokio::sync::Mutex::new(None),
        security_container_initialization: tokio::sync::Mutex::new(()),
        client: cloudkit.clone(),
    }))
}

#[frb(sync)]
pub fn make_cloud_messages_client(
    cloudkit: &Arc<CloudKitClient<DefaultAnisetteProvider>>,
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
) -> Arc<CloudMessagesClient<DefaultAnisetteProvider>> {
    Arc::new(CloudMessagesClient::new(cloudkit.clone(), keychain.clone()))
}

pub async fn make_findmy(
    path: String,
    token_provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
    conn: &APSConnection,
    cloudkit: &Arc<CloudKitClient<DefaultAnisetteProvider>>,
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    config: &JoinedOSConfig,
    client: &Arc<IMClient>,
) -> Option<Arc<FindMyClient<DefaultAnisetteProvider>>> {
    let dir = PathBuf::from_str(&path).unwrap();
    let id_path = dir.join("findmy.plist");
    let state = FindMyState::restore(&fs::read(&id_path).ok()?).ok()?;

    Some(Arc::new(
        FindMyClient::new(
            conn.clone(),
            cloudkit.clone(),
            keychain.clone(),
            config.config(),
            Arc::new(FindMyStateManager {
                state: Mutex::new(state),
                update: Box::new(move |state| {
                    fs::write(&id_path, state).expect("Failed to serialize plist!");
                }),
            }),
            token_provider.clone(),
            anisette.clone(),
            client.identity.clone(),
        )
        .await
        .unwrap(),
    ))
}

async fn shared_items<
    P: AnisetteProvider + Send + Sync + 'static,
    F: FilePackager + Send + Sync + 'static,
>(
    manager: &SyncManager<P, F>,
    seen_paths: &mut HashSet<PathBuf>,
) -> HashSet<PathBuf> {
    let paths = manager
        .sync_states
        .lock()
        .await
        .values()
        .map(|v| v.folder.clone())
        .collect::<Vec<_>>();
    let mut new = HashSet::new();
    seen_paths.retain(|a| fs::exists(a).is_ok_and(|a| a));
    for path in paths {
        let Ok(read) = fs::read_dir(path) else {
            continue;
        };
        for file in read {
            let Ok(result) = file else { continue };
            if seen_paths.contains(&result.path()) {
                continue;
            }
            seen_paths.insert(result.path());
            new.insert(result.path());
        }
    }
    new
}

fn subscribe_streams<
    P: AnisetteProvider + Send + Sync + 'static,
    F: FilePackager + Send + Sync + 'static,
>(
    manager: SyncManager<P, F>,
) {
    tokio::spawn(async move {
        let mut seen_paths = HashSet::new();
        shared_items(&manager, &mut seen_paths).await;
        let mut generated_sub = manager.generated_signal.subscribe();
        let manager_ref = Arc::downgrade(&manager);
        drop(manager);
        while let Ok(_) = generated_sub.recv().await {
            // drain any accumulations
            while let Ok(_) = generated_sub.try_recv() {}

            info!("Starting diff");
            let Some(manager) = manager_ref.upgrade() else {
                break;
            };
            let new = shared_items(&manager, &mut seen_paths).await;
            info!("Shared-stream diff found {} new files", new.len());
            if let Some(packager) = PACKAGER_LOCK.get() {
                packager.scan_files(
                    new.into_iter()
                        .map(|a| a.to_str().expect("Path not str??").to_string())
                        .collect(),
                );
            }
            info!("Diffed");
        }
    });
}

#[frb(sync)]
pub fn duplicate_user(user: &IDSUser) -> IDSUser {
    user.clone()
}

pub async fn register_ids(
    path: String,
    config: &JoinedOSConfig,
    aps: &APSConnection,
    identity: &IDSNGMIdentity,
    mut users: Vec<IDSUser>,
) -> anyhow::Result<(Option<Vec<IDSUser>>, Option<SupportAlert>)> {
    let dir = PathBuf::from_str(&path).unwrap();

    if let Err(err) = register(
        &*config.config(),
        &*aps.state.read().await,
        &[
            &MADRID_SERVICE,
            &MULTIPLEX_SERVICE,
            &FACETIME_SERVICE,
            &VIDEO_SERVICE,
        ],
        &mut users,
        identity,
    )
    .await
    {
        return if let PushError::CustomerMessage(support) = err {
            Ok((None, Some(support)))
        } else {
            Err(anyhow!(err))
        };
    }
    let id_path = dir.join("id.plist");
    std::fs::write(&id_path, plist_to_string(&users).unwrap()).unwrap();

    Ok((Some(users), None))
}

pub async fn set_identity(state_path: String, config: &JoinedOSConfig, identity: &IDSNGMIdentity) {
    let state_path = PathBuf::from_str(&state_path)
        .unwrap()
        .join("hw_info.plist");
    let state = SavedHardwareState {
        push: Default::default(),
        os_config: config.clone(),
        identity: identity.save("openbubbles").expect("failed to save").into(),
    };
    std::fs::write(&state_path, plist_to_string(&state).unwrap()).unwrap();
}

pub async fn setup_push(
    config: &JoinedOSConfig,
    identity: &IDSNGMIdentity,
    state: Option<APSState>,
    state_path: String,
) -> (APSConnection, Option<PushError>) {
    let state_path = PathBuf::from_str(&state_path)
        .unwrap()
        .join("hw_info.plist");
    let (conn, error) = APSConnectionResource::new(config.config(), state).await;

    let saved_identity = identity.save("openbubbles").expect("failed to save");
    if error.is_none() {
        let state = SavedHardwareState {
            push: conn.state.read().await.clone(),
            os_config: config.clone(),
            identity: saved_identity.clone().into(),
        };
        std::fs::write(&state_path, plist_to_string(&state).unwrap()).unwrap();
    }

    let mut to_refresh = conn.generated_signal.subscribe();
    let reconn_conn = Arc::downgrade(&conn);
    let config_ref = config.clone();
    tokio::spawn(async move {
        loop {
            match to_refresh.recv().await {
                Ok(()) => {
                    let Some(conn) = reconn_conn.upgrade() else {
                        break;
                    };
                    // update keys
                    let state = SavedHardwareState {
                        push: conn.state.read().await.clone(),
                        os_config: config_ref.clone(),
                        identity: saved_identity.clone().into(),
                    };
                    std::fs::write(&state_path, plist_to_string(&state).unwrap()).unwrap();
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    (conn, error)
}

#[derive(Clone, Debug, Serialize)]
pub struct ApsConnectionStatus {
    pub state: String,
    pub active_port: Option<u16>,
    pub error: Option<String>,
    pub retry_wait_seconds: Option<u64>,
}

pub async fn get_aps_connection_status(aps: &APSConnection) -> ApsConnectionStatus {
    let active_port = aps.active_port();
    match &*aps.resource_state.borrow() {
        ResourceState::Generated => ApsConnectionStatus {
            state: "connected".to_string(),
            active_port,
            error: None,
            retry_wait_seconds: None,
        },
        ResourceState::Generating => ApsConnectionStatus {
            state: "reconnecting".to_string(),
            active_port: None,
            error: None,
            retry_wait_seconds: None,
        },
        ResourceState::Failed(failure) => ApsConnectionStatus {
            state: "blocked".to_string(),
            active_port: None,
            error: Some(failure.error.to_string()),
            retry_wait_seconds: failure.retry_wait,
        },
        ResourceState::Closed => ApsConnectionStatus {
            state: "closed".to_string(),
            active_port: None,
            error: Some("Apple Push connection is closed".to_string()),
            retry_wait_seconds: None,
        },
    }
}

pub async fn refresh_aps_connection(aps: &APSConnection) -> anyhow::Result<()> {
    // A network transition is explicit evidence that the existing socket and backoff
    // belong to the old route. Do not retain ResourceManager's normal 15-second refresh
    // suppression here.
    aps.request_update_now().await;
    Ok(())
}

#[derive(Serialize, Deserialize)]
pub struct AnisetteState {
    #[serde(
        serialize_with = "bin_serialize",
        deserialize_with = "bin_deserialize_16"
    )]
    keychain_identifier: [u8; 16],
    provisioned: Option<ProvisionedAnisette>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct ProvisionedAnisette {
    client_secret: Data,
    mid: Data,
    metadata: Data,
    rinfo: String,
    #[serde(default)]
    flavor: ProvisionedFlavor,
}

#[derive(Serialize, Deserialize, Clone, Default)]
pub enum ProvisionedFlavor {
    #[default]
    Mac,
    IOS,
}

async fn get_login_config(
    conf_dir: &PathBuf,
    conf: &JoinedOSConfig,
    conn: &APSConnection,
) -> LoginClientInfo {
    let anisette_dir = conf_dir.join("anisette_test");
    let config_path = anisette_dir.join("state.plist");

    let require_mac = if let Ok(decoded) = plist::from_file::<_, AnisetteState>(config_path) {
        matches!(
            decoded.provisioned,
            Some(ProvisionedAnisette {
                flavor: ProvisionedFlavor::Mac,
                ..
            })
        )
    } else {
        false
    };

    conf.get_gsa_config(&*conn.state.read().await, require_mac)
}

pub async fn configure_app_review(path: String) -> anyhow::Result<()> {
    let path = PathBuf::from_str(&path).unwrap();

    std::fs::write(path.join("id.plist"), include_str!("id_testing.plist"))?;
    std::fs::write(path.join("hw_info.plist"), include_str!("hw_testing.plist"))?;

    // let state = SharedPushState::restore(path)
    Ok(())
}

pub fn encode_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        write!(&mut s, "{:02x}", b).unwrap();
    }
    s
}

pub struct HwExtra {
    pub version: String,
    pub protocol_version: u32,
    pub device_id: String,
    pub icloud_ua: String,
    pub aoskit_version: String,
}

pub fn generate_udid() -> String {
    let udid: [u8; 32] = rand::thread_rng().gen();
    encode_hex(&udid).to_uppercase()
}

pub fn config_from_validation_data(
    data: Vec<u8>,
    extra: HwExtra,
) -> anyhow::Result<JoinedOSConfig> {
    let inner = HardwareConfig::from_validation_data(&data)?;
    Ok(JoinedOSConfig::MacOS(Arc::new(MacOSConfig {
        inner,
        version: extra.version,
        protocol_version: extra.protocol_version,
        device_id: extra.device_id,
        icloud_ua: extra.icloud_ua,
        aoskit_version: extra.aoskit_version,
        udid: Some(generate_udid()),
    })))
}

pub async fn config_from_relay(
    code: String,
    host: String,
    token: &Option<String>,
) -> anyhow::Result<JoinedOSConfig> {
    Ok(JoinedOSConfig::Relay(Arc::new(RelayConfig {
        version: RelayConfig::get_versions(&host, &code, token).await?,
        icloud_ua: "com.apple.iCloudHelper/282 CFNetwork/1408.0.4 Darwin/22.5.0".to_string(),
        aoskit_version: "com.apple.AOSKit/282 (com.apple.accountsd/113)".to_string(),
        dev_uuid: Uuid::new_v4().to_string(),
        protocol_version: 1660,
        host: host.clone(),
        code: code.clone(),
        beeper_token: token.clone(),
        udid: Some(generate_udid()),
    })))
}

pub async fn validate_relay(config_ref: &JoinedOSConfig) -> anyhow::Result<Option<String>> {
    let Err(PushError::RelayError(_, message)) = config_ref.generate_validation_data().await else {
        return Ok(match config_ref {
            JoinedOSConfig::MacOS(macos) => None,
            JoinedOSConfig::Relay(relay) => Some(relay.code.clone()),
        });
    };
    if !message.contains("Subscription not active!")
        && !message.contains("Ticket not activated!")
        && !message.contains("Sorry, your hosted device is currently offline!")
    {
        info!("Validation failed {message}");
        return Ok(None);
    }
    Ok(match config_ref {
        JoinedOSConfig::MacOS(macos) => None,
        JoinedOSConfig::Relay(relay) => Some(relay.code.clone()),
    })
}

pub fn parse_transcript_poster(payload: Vec<u8>) -> anyhow::Result<SimplifiedTranscriptPoster> {
    Ok(SimplifiedTranscriptPoster::parse_payload(&payload)?)
}

pub fn pack_transcript_poster(mut payload: SimplifiedTranscriptPoster) -> anyhow::Result<Vec<u8>> {
    Ok(payload.to_payload()?)
}

pub fn parse_poster(poster: IMessagePosterRecord) -> anyhow::Result<SimplifiedIncomingCallPoster> {
    Ok(SimplifiedIncomingCallPoster::from_poster(&poster)?)
}

pub fn from_poster(
    mut poster: SimplifiedIncomingCallPoster,
) -> anyhow::Result<IMessagePosterRecord> {
    Ok(poster.to_poster()?)
}

// simple round trip to rust clones object
#[frb(sync)]
pub fn clone_poster(
    poster: SimplifiedIncomingCallPoster,
) -> anyhow::Result<SimplifiedIncomingCallPoster> {
    Ok(poster)
}

#[frb(sync)]
pub fn clone_transcript_poster(
    poster: SimplifiedTranscriptPoster,
) -> anyhow::Result<SimplifiedTranscriptPoster> {
    Ok(poster)
}

pub fn transcript_poster_save(poster: SimplifiedTranscriptPoster) -> anyhow::Result<Vec<u8>> {
    Ok(plist_to_bin(&poster)?)
}

pub fn from_transcript_poster_save(poster: Vec<u8>) -> anyhow::Result<SimplifiedTranscriptPoster> {
    debug!("Before");
    let got = plist::from_bytes(&poster)?;
    debug!("After");
    Ok(got)
}

pub fn parse_poster_save(poster: SimplifiedIncomingCallPoster) -> anyhow::Result<Vec<u8>> {
    Ok(plist_to_bin(&poster)?)
}

pub fn from_poster_save(poster: Vec<u8>) -> anyhow::Result<SimplifiedIncomingCallPoster> {
    debug!("Before");
    let got = match plist::from_bytes(&poster) {
        Ok(poster) => poster,
        Err(_) => {
            let result: SimplifiedPoster = plist::from_bytes(&poster)?;

            #[derive(Deserialize)]
            struct Extras {
                text_metadata: WallpaperMetadata,
                low_res: Data,
            }
            let extras: Extras = plist::from_bytes(&poster)?;
            SimplifiedIncomingCallPoster {
                poster: result,
                text_metadata: extras.text_metadata,
                low_res: extras.low_res.into(),
            }
        }
    };
    debug!("After");
    Ok(got)
}

pub struct DeviceInfo {
    pub name: String,
    pub serial: String,
    pub os_version: String,
    pub encoded_data: Option<Vec<u8>>,
}

pub fn get_device_info(config: &JoinedOSConfig) -> anyhow::Result<DeviceInfo> {
    let debug_info = config.get_debug_meta();
    Ok(DeviceInfo {
        name: debug_info.hardware_version.clone(),
        serial: debug_info.serial_number.clone(),
        os_version: debug_info.user_version.clone(),
        encoded_data: match config {
            JoinedOSConfig::MacOS(config) => {
                let copied = config.as_ref().clone();
                Some(
                    crate::bbhwinfo::HwInfo {
                        inner: Some(crate::bbhwinfo::hw_info::InnerHwInfo {
                            product_name: copied.inner.product_name,
                            io_mac_address: copied.inner.io_mac_address.to_vec(),
                            platform_serial_number: copied.inner.platform_serial_number,
                            platform_uuid: copied.inner.platform_uuid,
                            root_disk_uuid: copied.inner.root_disk_uuid,
                            board_id: copied.inner.board_id,
                            os_build_num: copied.inner.os_build_num,
                            platform_serial_number_enc: copied.inner.platform_serial_number_enc,
                            platform_uuid_enc: copied.inner.platform_uuid_enc,
                            root_disk_uuid_enc: copied.inner.root_disk_uuid_enc,
                            rom: copied.inner.rom,
                            rom_enc: copied.inner.rom_enc,
                            mlb: copied.inner.mlb,
                            mlb_enc: copied.inner.mlb_enc,
                        }),
                        version: copied.version,
                        protocol_version: copied.protocol_version as i32,
                        device_id: copied.device_id,
                        icloud_ua: copied.icloud_ua,
                        aoskit_version: copied.aoskit_version,
                    }
                    .encode_to_vec(),
                )
            }
            JoinedOSConfig::Relay(_) => None,
        },
    })
}

pub fn config_from_encoded(encoded: Vec<u8>) -> anyhow::Result<JoinedOSConfig> {
    let copied = crate::bbhwinfo::HwInfo::decode(&mut Cursor::new(encoded))?;
    let inner = copied.inner.unwrap();
    Ok(JoinedOSConfig::MacOS(Arc::new(MacOSConfig {
        inner: HardwareConfig {
            product_name: inner.product_name,
            io_mac_address: inner.io_mac_address.try_into().unwrap(),
            platform_serial_number: inner.platform_serial_number,
            platform_uuid: inner.platform_uuid,
            root_disk_uuid: inner.root_disk_uuid,
            board_id: inner.board_id,
            os_build_num: inner.os_build_num,
            platform_serial_number_enc: inner.platform_serial_number_enc,
            platform_uuid_enc: inner.platform_uuid_enc,
            root_disk_uuid_enc: inner.root_disk_uuid_enc,
            rom: inner.rom,
            rom_enc: inner.rom_enc,
            mlb: inner.mlb,
            mlb_enc: inner.mlb_enc,
        },
        version: copied.version,
        protocol_version: copied.protocol_version as u32,
        device_id: copied.device_id,
        icloud_ua: copied.icloud_ua,
        aoskit_version: copied.aoskit_version,
        udid: Some(generate_udid()),
    })))
}

pub async fn ptr_to_dart(ptr: String) -> Option<PushMessage> {
    let pointer: u64 = ptr.parse().unwrap();
    info!("using pointer {pointer}");
    QUEUED_MESSAGES.lock().await.1.get(&pointer).cloned()
}

pub async fn complete_msg(ptr: String) {
    let pointer: u64 = ptr.parse().unwrap();
    info!("finishing pointer {pointer}");
    QUEUED_MESSAGES.lock().await.1.remove(&pointer);
}

#[frb(sync)]
pub fn restore_attachment(data: String) -> Attachment {
    plist::from_reader_xml(Cursor::new(data)).unwrap()
}

pub fn save_attachment(att: &Attachment) -> String {
    plist_to_string(att).unwrap()
}

pub fn create_image_array(img: LPImageMetadata) -> NSArray<LPImageMetadata> {
    NSArray {
        objects: vec![img],
        class: NSArrayClass::NSArray,
    }
}

pub fn create_icon_array(img: LPIconMetadata) -> NSArray<LPIconMetadata> {
    NSArray {
        objects: vec![img],
        class: NSArrayClass::NSArray,
    }
}

#[frb(sync)]
pub fn ns_null() -> Vec<u8> {
    plist_to_bin(&Value::String("$null".to_string())).unwrap()
}

#[repr(C)]
#[derive(Clone)]
pub enum PushMessage {
    IMessage(MessageInst),
    SendConfirm {
        uuid: String,
        error: Option<String>,
    },
    RegistrationState(RegisterState),
    NewPhotostream(SharedAlbum),
    FaceTime(FTMessage),
    StatusUpdate(StatusKitMessage),
    Idms(IdmsMessage),
    TwoFaAuthEvent(bool),
    CircleFinishEvent,
    BeaconShared {
        sender: String,
        beacon: String,
        attributes: BeaconAttributes,
    },
}

pub async fn sync_passwords(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    conn: &APSConnection,
) -> anyhow::Result<()> {
    passwords.sync_passwords(conn).await?;

    sync_wifi_passwords(passwords, false).await;

    Ok(())
}

pub async fn get_passwords(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
) -> HashMap<String, (Option<String>, PasswordRawEntry)> {
    passwords.get_password_entries().await
}

pub async fn get_passwords_meta(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
) -> HashMap<String, (Option<String>, PasswordManagerMeta)> {
    passwords.get_password_entries().await
}

pub async fn get_passkeys(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
) -> HashMap<String, (Option<String>, Passkey)> {
    passwords.get_password_entries().await
}

pub async fn get_wifi_passwords(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
) -> HashMap<String, (Option<String>, WifiPassword)> {
    passwords.get_password_entries().await
}

pub async fn save_password(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    entry: &PasswordRawEntry,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords.insert_password_entry(&id, entry, group).await?)
}

pub async fn save_password_meta(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    entry: &PasswordManagerMeta,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords.insert_password_entry(&id, entry, group).await?)
}

pub async fn save_passkey(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    entry: &Passkey,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords.insert_password_entry(&id, entry, group).await?)
}

pub async fn save_wifi_password(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    entry: &WifiPassword,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords.insert_password_entry(&id, entry, group).await?)
}

pub async fn delete_password(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords
        .delete_password_entry::<PasswordRawEntry>(&id, group)
        .await?)
}

pub async fn delete_password_meta(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords
        .delete_password_entry::<PasswordManagerMeta>(&id, group)
        .await?)
}

pub async fn delete_passkey(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords
        .delete_password_entry::<Passkey>(&id, group)
        .await?)
}

pub async fn delete_wifi_password(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    id: String,
    group: Option<String>,
) -> anyhow::Result<()> {
    Ok(passwords
        .delete_password_entry::<WifiPassword>(&id, group)
        .await?)
}

pub struct GroupSummaryMember {
    pub name: Option<String>,
    pub handle: String,
    pub user_id: Option<String>,
    pub is_joined: bool,
}

pub struct GroupSummary {
    pub display_name: String,
    pub is_owner: bool,
    pub members: Vec<GroupSummaryMember>,
}

pub async fn get_groups(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
) -> anyhow::Result<(
    String,
    HashMap<String, GroupSummary>,
    HashMap<String, ShareInviteContentData>,
)> {
    let container = passwords.get_container().await?;
    let state = passwords.state.read().await;
    let filter = state
        .groups
        .iter()
        .filter_map(|(id, group)| {
            let item = group.share.as_ref()?;
            Some((
                id.clone(),
                GroupSummary {
                    display_name: item.display_name.clone(),
                    is_owner: group.is_owner,
                    members: item
                        .share_info
                        .participants
                        .iter()
                        .filter_map(|p| {
                            if p.state() == 3 {
                                None
                            } else {
                                Some(GroupSummaryMember {
                                    name: p.contact_information.as_ref()?.first_name.clone(),
                                    handle: p
                                        .contact_information
                                        .as_ref()
                                        .and_then(|c| contact_info_to_handle(c))?,
                                    user_id: p.user_id.as_ref().and_then(|u| u.name.clone()),
                                    is_joined: p.state() == 2,
                                })
                            }
                        })
                        .collect(),
                },
            ))
        })
        .collect::<HashMap<_, _>>();
    Ok((
        container.user_id.clone(),
        filter,
        state.invite_groups.clone(),
    ))
}

pub async fn create_group(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    name: String,
) -> anyhow::Result<String> {
    Ok(passwords.create_group(&name).await?)
}

pub async fn delete_group(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    gid: String,
) -> anyhow::Result<()> {
    Ok(passwords.remove_group(&gid).await?)
}

pub async fn invite_user(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    gid: String,
    handle: String,
) -> anyhow::Result<()> {
    Ok(passwords.invite_user(&gid, &handle).await?)
}

pub async fn remove_user(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    gid: String,
    handle: String,
) -> anyhow::Result<()> {
    Ok(passwords.remove_user(&gid, &handle).await?)
}

pub async fn rename_group(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    gid: String,
    newname: String,
) -> anyhow::Result<()> {
    Ok(passwords.rename_group(&gid, &newname).await?)
}

pub async fn accept_invite(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    invite_id: String,
) -> anyhow::Result<()> {
    Ok(passwords.accept_invite(&invite_id).await?)
}

pub async fn decline_invite(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    invite_id: String,
) -> anyhow::Result<()> {
    Ok(passwords.decline_invite(&invite_id).await?)
}

pub async fn query_handle(
    passwords: &Arc<PasswordManager<DefaultAnisetteProvider>>,
    handle: String,
) -> anyhow::Result<bool> {
    Ok(passwords.query_handle(&handle).await?)
}

async fn handle_photostream(
    client: &SharedStreamClient<DefaultAnisetteProvider>,
    changes: Vec<String>,
    local: &Arc<mpsc::Sender<PushMessage>>,
) {
    let lock = &client.state.read().await.albums;
    for change in changes {
        let Some(item) = lock.iter().find(|a| &a.albumguid == &change) else {
            continue;
        };
        if item.sharingtype == "pending" {
            local
                .send(PushMessage::NewPhotostream(item.clone()))
                .await
                .expect("Dropped?");
        }
    }
}

pub async fn update_account_headers(
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    config: &JoinedOSConfig,
) -> anyhow::Result<(String, UpdateAccountFinish)> {
    let account = account.lock().await;

    Ok(request_update_account(&*account, &*config.config()).await?)
}

pub async fn get_anisette_headers(
    state: &ArcAnisetteClient<DefaultAnisetteProvider>,
    config: &JoinedOSConfig,
) -> anyhow::Result<HashMap<String, String>> {
    let mut headers = state.lock().await.get_headers().await?.clone();
    headers.insert(
        "X-Mme-Client-Info".to_string(),
        config.get_adi_mme_info(
            "com.apple.AuthKit/1 (com.apple.findmy/375.20)",
            !headers["X-Mme-Client-Info"].contains("iPhone OS"),
        ),
    );
    Ok(headers)
}

pub async fn get_contacts_headers(
    path: String,
    state: &ArcAnisetteClient<DefaultAnisetteProvider>,
    token_provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
    config: &JoinedOSConfig,
) -> anyhow::Result<HashMap<String, String>> {
    let dir = PathBuf::from_str(&path).unwrap();

    // I know it's the wrong answer. Stop looking at me!
    let id_path = dir.join("sharedstreams.plist");
    let findmy_state: SharedStreamsState = plist::from_file(id_path)?;

    let mut headers = state.lock().await.get_headers().await?.clone();
    headers.insert(
        "X-Mme-Client-Info".to_string(),
        config.get_adi_mme_info(
            "com.apple.AuthKit/1 (com.apple.AddressBookSourceSync/2695.500.71)",
            !headers["X-Mme-Client-Info"].contains("iPhone OS"),
        ),
    );

    headers.insert(
        "X-APPLE-FAMILY-AUTH-TOKEN".to_string(),
        token_provider
            .get_gsa_token("com.apple.gs.icloud.family.auth")
            .await
            .expect("no Family auth token?"),
    );
    let mme_token = token_provider.get_mme_token("mmeAuthToken").await?;
    headers.insert(
        "Authorization".to_string(),
        format!(
            "X-MobileMe-AuthToken {}",
            base64_encode(format!("{}:{}", &findmy_state.dsid, mme_token).as_bytes())
        ),
    );

    Ok(headers)
}

pub async fn get_entitlements(
    config: &JoinedOSConfig,
    conn: &APSConnection,
    mccmnc: String,
    subscriber: String,
    imei: String,
    process_challenge: impl Fn(String) -> DartFnFuture<String>,
) -> anyhow::Result<IDSUser> {
    let mut entitlementstate = EntitlementAuthState::new(subscriber, mccmnc, imei);

    let entitlements = entitlementstate
        .get_entitlements(&*config.config(), &conn, |challenge| async move {
            Ok(process_challenge(challenge).await)
        })
        .await?;

    let user = authenticate_smsless(
        &entitlements.phone,
        &entitlements.host,
        &*config.config(),
        &conn,
    )
    .await?;

    Ok(user)
}

pub async fn get_albums(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
    refresh: bool,
) -> anyhow::Result<(Vec<SharedAlbum>, Vec<String>)> {
    if refresh {
        let _ = lock.client.get_changes().await?;

        let nameless_albums: Vec<_> = lock
            .client
            .state
            .read()
            .await
            .albums
            .iter()
            .filter(|album| album.name.is_none())
            .map(|album| album.albumguid.clone())
            .collect();
        for album in nameless_albums {
            lock.client.get_album_summary(&album).await?;
        }
    }

    let albums_ref = lock.client.state.read().await.albums.clone();
    let extras = lock
        .dirty_map
        .lock()
        .await
        .iter()
        .map(|a| a.0.clone())
        .collect();
    Ok((albums_ref, extras))
}

pub async fn subscribe(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
    guid: String,
) -> anyhow::Result<Vec<SharedAlbum>> {
    let _ = lock.client.subscribe(&guid).await?;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn unsubscribe(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
    guid: String,
) -> anyhow::Result<Vec<SharedAlbum>> {
    let _ = lock.unsubscribe(&guid).await?;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn subscribe_token(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
    token: String,
) -> anyhow::Result<Vec<SharedAlbum>> {
    let _ = lock.client.subscribe_token(&token).await?;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn add_album(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
    guid: String,
    folder: String,
) -> anyhow::Result<Vec<SharedAlbum>> {
    lock.add_album(guid, PathBuf::from_str(&folder).unwrap())
        .await;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn remove_album(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
    guid: String,
) -> anyhow::Result<Vec<SharedAlbum>> {
    debug!("b");
    lock.remove_album(guid).await;
    debug!("c");
    let albums_ref = lock.client.state.read().await.albums.clone();
    debug!("d");
    Ok(albums_ref)
}

pub async fn get_syncstatus(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
) -> anyhow::Result<(HashMap<String, SyncStatus>, Option<(String, u64)>)> {
    let statuses = lock.sync_statuses.borrow().clone();

    let mut f: Option<(String, u64)> = None;
    if let ResourceState::Failed(failure) = &*lock.resource_state.borrow() {
        f = Some((
            format!("{}", failure.error),
            failure.retry_wait.unwrap_or(u64::MAX),
        ))
    }

    Ok((statuses, f))
}

pub async fn sync_now(
    lock: &SyncManager<DefaultAnisetteProvider, MyFilePackager>,
) -> anyhow::Result<()> {
    lock.refresh_now().await?;

    Ok(())
}

pub async fn ft_sessions(facetime: &Arc<FTClient>) -> anyhow::Result<Vec<FTSession>> {
    let sessions = facetime.state.read().await;
    Ok(sessions.sessions.values().cloned().collect())
}

pub async fn get_ft_link(facetime: &Arc<FTClient>, usage: String) -> anyhow::Result<String> {
    let handles = facetime.identity.get_handles().await.to_vec();

    let handle = handles[0].clone();
    Ok(facetime.get_link_for_usage(&handle, &usage).await?)
}

pub async fn use_link_for(
    facetime: &Arc<FTClient>,
    old_usage: String,
    usage: String,
) -> anyhow::Result<()> {
    Ok(facetime.use_link_for(&old_usage, &usage).await?)
}

pub async fn clear_links(facetime: &Arc<FTClient>) -> anyhow::Result<()> {
    Ok(facetime.clear_links().await?)
}

pub async fn get_2fa_code(
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
) -> anyhow::Result<u32> {
    info!("third lock");
    let code = anisette.lock().await.provider.get_2fa_code().await?;
    info!("fouth lock");
    Ok(code)
}

pub async fn teardown_2fa(
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    action: String,
    txnid: String,
) -> anyhow::Result<()> {
    let mut account = account.lock().await;
    account.teardown(&action, 100, &txnid).await?;
    Ok(())
}

pub async fn answer_ft_request(
    facetime: &Arc<FTClient>,
    request: LetMeInRequest,
    approved_group: Option<String>,
) -> anyhow::Result<()> {
    facetime
        .respond_letmein(request, approved_group.as_ref().map(|a| a.as_str()))
        .await?;
    Ok(())
}

pub async fn decline_facetime(facetime: &Arc<FTClient>, guid: String) -> anyhow::Result<()> {
    let mut lock = facetime.state.write().await;
    let state = lock.sessions.get_mut(&guid).expect("state");
    facetime.ensure_allocations(state, &[]).await?;
    facetime.decline_invite(state).await?;
    Ok(())
}

pub async fn create_facetime(
    facetime: &Arc<FTClient>,
    uuid: String,
    handle: String,
    participants: Vec<String>,
) -> anyhow::Result<()> {
    facetime.create_session(uuid, handle, &participants).await?;
    Ok(())
}

pub async fn cancel_facetime(facetime: &Arc<FTClient>, guid: String) -> anyhow::Result<()> {
    let mut lock = facetime.state.write().await;
    let state = lock.sessions.get_mut(&guid).expect("state");
    facetime.unprop_conv(state).await?;
    Ok(())
}

pub async fn validate_targets_facetime(
    state: &Arc<IMClient>,
    targets: Vec<String>,
    sender: String,
) -> anyhow::Result<Vec<String>> {
    Ok(state
        .identity
        .validate_targets(&targets, "com.apple.private.alloy.facetime.multi", &sender)
        .await?)
}

pub async fn certify_delivery(
    state: &Arc<IMClient>,
    context: CertifiedContext,
    notify: bool,
) -> anyhow::Result<()> {
    state
        .identity
        .certify_delivery("com.apple.madrid", &context, notify)
        .await?;
    Ok(())
}

pub async fn report_messages(
    state: &Arc<IMClient>,
    handle: String,
    messages: Vec<ReportMessage>,
) -> anyhow::Result<()> {
    state.identity.report_spam(&handle, &messages).await?;
    Ok(())
}

pub fn encode_profile_message(p: &ShareProfileMessage) -> String {
    plist_to_string(&p).unwrap()
}

pub fn decode_profile_message(s: String) -> anyhow::Result<ShareProfileMessage> {
    Ok(plist::from_bytes(s.as_bytes())?)
}

pub async fn fetch_profile(
    profiles: &Arc<ProfilesClient<DefaultAnisetteProvider>>,
    message: &ShareProfileMessage,
) -> anyhow::Result<IMessageNicknameRecord> {
    Ok(profiles.get_record(message).await?)
}

pub async fn set_profile(
    profiles: &Arc<ProfilesClient<DefaultAnisetteProvider>>,
    record: IMessageNicknameRecord,
    mut existing: Option<ShareProfileMessage>,
) -> anyhow::Result<ShareProfileMessage> {
    profiles.set_record(record, &mut existing).await?;
    Ok(existing.expect("No profile set??"))
}

pub async fn invite_to_channel(
    status: &Arc<StatusKitClient<DefaultAnisetteProvider>>,
    handle: String,
    to: HashMap<String, StatusKitPersonalConfig>,
) -> anyhow::Result<()> {
    Ok(status.invite_to_channel(&handle, to).await?)
}

pub async fn reset_channel_keys(
    status: &Arc<StatusKitClient<DefaultAnisetteProvider>>,
) -> anyhow::Result<()> {
    Ok(status.reset_keys().await)
}

pub async fn request_handles(
    status: &Arc<StatusKitClient<DefaultAnisetteProvider>>,
    to: Vec<String>,
) -> anyhow::Result<Option<ChannelInterestToken>> {
    Ok(if to.is_empty() {
        None
    } else {
        Some(status.request_handles(&to).await)
    })
}

pub async fn set_status(
    status: &Arc<StatusKitClient<DefaultAnisetteProvider>>,
    new_status: Option<String>,
) -> anyhow::Result<()> {
    status
        .share_status(&StatusKitStatus {
            active: new_status.is_none(),
            id: new_status,
        })
        .await?;
    Ok(())
}

pub enum PollResult {
    Stop,
    Cont(Option<PushMessage>),
}

// returns false to skip the message because our adsid is wrong
async fn handle_2fa(state: &SharedPushState, signin: &IdmsRequestedSignIn) -> bool {
    let Some(services) = &state.icloud_services else {
        warn!("Ignoring circle message for no account!");
        return false;
    };

    let account = &services.account;

    let mut lock = account.lock().await;
    if lock.spd.is_none() {
        // trigger gsa flow
        lock.get_token("com.apple.gs.idms.pet").await;
        if lock.spd.is_none() {
            warn!("Dropping message because GSA flow failed!");
            return false;
        }
    }
    let adsid = lock
        .spd
        .as_ref()
        .unwrap()
        .get("adsid")
        .expect("no adsid???s")
        .as_string()
        .unwrap();
    if adsid != &signin.adsid {
        warn!("Dropping 2fa code because the account identifier did not match");
        return false;
    }
    drop(lock);
    true
}

async fn handle_circle(
    state: &SharedPushState,
    signin: &Option<IdmsRequestedSignIn>,
    msg: &IdmsCircleMessage,
) {
    if msg.step % 2 == 0 {
        // this is a client step (we are the client)
        let mut locked = state.client_session.lock().await;
        let Some(client) = &mut *locked else {
            warn!("Ignoring unknown circle client session");
            return;
        };
        match client.handle_circle_request(msg).await {
            Err(e) => {
                warn!("error {e}");
            }
            Ok(Some(LoginState::LoggedIn)) => {
                // we are done
                *locked = None;
                let _ = state
                    .local_broadcast
                    .send(PushMessage::CircleFinishEvent)
                    .await;
                info!("Finished client circle!");
            }
            _ => info!("Did circle step {}", msg.step),
        }
        return;
    }

    let mut circle_lock = state.active_circle_sessions.lock().await;
    if !circle_lock.iter().any(|a| a.atxnid == msg.atxnid) {
        if msg.step != 1 {
            warn!("Ignoring middle session!");
            return;
        }
        let Some(signin) = signin else { return };
        let push_token = state.conn.get_token().await;
        let Some(account) = &state.icloud_services else {
            warn!("Ignoring circle message for no account!");
            return;
        };

        let mut lock = account.account.lock().await;
        if lock.spd.is_none() {
            // trigger gsa flow
            lock.get_token("com.apple.gs.idms.pet").await;
            if lock.spd.is_none() {
                warn!("Dropping message because GSA flow failed!");
                return;
            }
        }
        let dsid = lock
            .spd
            .as_ref()
            .unwrap()
            .get("DsPrsId")
            .expect("no dsid???s")
            .as_unsigned_integer()
            .unwrap();
        drop(lock);

        let mut rng = rand::thread_rng();
        let otp: u32 = rng.gen_range(0..1_000_000);
        let session = CircleServerSession::new(
            dsid,
            otp,
            account.account.clone(),
            push_token,
            account.keychain.clone(),
        );
        circle_lock.push(ActiveCircleSession {
            session,
            atxnid: msg.atxnid.clone(),
            txnid: signin.txnid.clone(),
            init_message: Some(msg.clone()),
            otp,
        });
        if circle_lock.len() > 5 {
            circle_lock.remove(0);
        }
        // wait for user to manually click approve to handle request
        return;
    }

    match circle_lock
        .iter_mut()
        .find(|a| a.atxnid == msg.atxnid)
        .unwrap()
        .session
        .handle_circle_request(msg)
        .await
    {
        Err(e) => {
            warn!("error {e}");
        }
        Ok(success) => {
            // login
            if msg.step == 3 {
                let _ = state
                    .local_broadcast
                    .send(PushMessage::TwoFaAuthEvent(success))
                    .await;
            }
        }
    }

    if msg.step == 5 {
        // last step, delete entry after
        circle_lock.retain(|a| a.atxnid != msg.atxnid);
    }
}

pub async fn approve_circle(
    state: &Arc<Mutex<Vec<ActiveCircleSession>>>,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    txnid: String,
) -> anyhow::Result<u32> {
    let mut circle_lock = state.lock().await;
    let Some(item) = circle_lock.iter_mut().find(|a| a.txnid == txnid) else {
        let account = account.lock().await;
        let code = account
            .anisette
            .lock()
            .await
            .provider
            .get_2fa_code()
            .await?;
        return Ok(code);
    };
    let Some(msg) = item.init_message.take() else {
        return Err(anyhow!("Idms init message missing for approve!"));
    };
    let otp = item.otp;
    drop(circle_lock);
    let state_ref = state.clone();
    RUNTIME.spawn(async move {
        let mut circle_lock = state_ref.lock().await;
        let Some(item) = circle_lock.iter_mut().find(|a| a.txnid == txnid) else {
            warn!("Session disappeared??");
            return;
        };
        if let Err(e) = item.session.handle_circle_request(&msg).await {
            warn!("cirlce error {e}");
            return;
        }
    });
    Ok(otp)
}

pub async fn recv_wait(watcher: &mut APSWatcher, state: &Arc<SharedPushState>) -> PollResult {
    if watcher.cancel_poll_recv.try_recv().is_ok() {
        return PollResult::Stop;
    }
    select! {
        msg = watcher.inq_queue.recv() => {
            let msg = msg.unwrap();
            if let Some(icloud) = &state.icloud_services {
                if let Some(fmfd) = &icloud.fmfd {
                    match fmfd.handle(msg.clone()).await {
                        Ok(mut items) => {
                            if !items.is_empty() {
                                let item = items.remove(0);
                                return PollResult::Cont(Some(PushMessage::BeaconShared {
                                    sender: item.0,
                                    beacon: item.1,
                                    attributes: item.2,
                                }))
                            }
                        },
                        Err(e) => {
                            warn!("FMF import error {e}");
                        }
                    }
                }
                if let Some(photostream) = &icloud.sharedstreams {
                    if let Ok(Some(changes)) = photostream.handle(msg.clone()).await {
                        handle_photostream(&photostream.client, changes, &state.local_broadcast).await;
                    }
                }
                match icloud.statuskit_client.handle(msg.clone()).await {
                    Err(e) => {
                        error!("Statuskit handle error {e}");
                        return PollResult::Cont(None);
                    },
                    Ok(None) => {},
                    Ok(Some(msg)) => {
                        return PollResult::Cont(Some(PushMessage::StatusUpdate(msg)))
                    }
                }
                if let Some(passwords) = &icloud.passwords {
                    if let Err(e) = passwords.handle(msg.clone()).await {
                        info!("error handling passwords {e}");
                    }
                }
            }
            match state.idms_client.handle(msg.clone()) {
                Err(e) => {
                    error!("IDMS handle error {e}");
                    return PollResult::Cont(None);
                },
                Ok(None) => {},
                Ok(Some(IdmsMessage::CircleRequest(circle, req))) => {
                    if let Some(req) = &req {
                        if !handle_2fa(&state, req).await { return PollResult::Cont(None) }
                    }
                    debug!("Circle here");
                    handle_circle(&state, &req, &circle).await;
                    if let Some(req) = req {
                        return PollResult::Cont(Some(PushMessage::Idms(IdmsMessage::RequestedSignIn(req))))
                    }
                },
                Ok(Some(IdmsMessage::RequestedSignIn(s))) => {
                    if !handle_2fa(&state, &s).await { return PollResult::Cont(None) }
                    return PollResult::Cont(Some(PushMessage::Idms(IdmsMessage::RequestedSignIn(s))))
                },
                Ok(Some(msg)) => {
                    return PollResult::Cont(Some(PushMessage::Idms(msg)))
                }
            }
            let ft_msg = state.ft_client.handle(msg.clone()).await;
            match ft_msg {
                Ok(Some(msg)) => return PollResult::Cont(Some(PushMessage::FaceTime(msg))),
                Ok(None) => {},
                Err(err) => {
                    // log and ignore for now
                    error!("ft err {}", err);
                    return PollResult::Cont(None);
                }
            }
            let msg = state.client.handle(msg).await;
            let msg = match msg {
                Ok(Some(msg)) => Some(PushMessage::IMessage(msg)),
                Ok(None) => None,
                Err(err) => {
                    // log and ignore for now
                    error!("{}", err);
                    return PollResult::Cont(None);
                }
            };
            PollResult::Cont(msg)
        },
        _reg_state = watcher.reg_state.changed() => {
            PollResult::Cont(Some(PushMessage::RegistrationState(get_regstate(&state.client).await.unwrap())))
        }
        reader = watcher.local_messages.recv() => {
            PollResult::Cont(Some(reader.unwrap()))
        },
        _cancel = watcher.cancel_poll_recv.recv() => {
            PollResult::Stop
        }
    }
}

pub async fn send(
    state: &Arc<IMClient>,
    local: &Arc<mpsc::Sender<PushMessage>>,
    mut msg: MessageInst,
) -> anyhow::Result<bool> {
    let result = state.send(&mut msg).await?;
    info!("send_finish");

    let local = local.clone();
    if let Some(handle) = result.handle {
        let uuid = msg.id.clone();
        tokio::spawn(async move {
            let result = handle.await.unwrap();
            info!("Finished handle {}", uuid);
            let maybeerr = result.err().map(|err| format!("{}", err));
            let _ = local
                .send(PushMessage::SendConfirm {
                    uuid,
                    error: maybeerr,
                })
                .await;
        });
        Ok(true)
    } else {
        Ok(false)
    }
}

pub async fn get_handles(state: &Arc<IMClient>) -> anyhow::Result<Vec<String>> {
    Ok(state.identity.get_handles().await.to_vec())
}

pub async fn get_my_phone_handles(state: &Arc<IMClient>) -> anyhow::Result<Vec<String>> {
    Ok(state.identity.get_my_phone_handles().await.to_vec())
}

pub async fn do_reregister(state: &Arc<IMClient>) -> anyhow::Result<()> {
    state.identity.refresh_now().await?;
    Ok(())
}

pub async fn new_msg(
    conversation: ConversationData,
    sender: String,
    message: Message,
) -> MessageInst {
    MessageInst::new(conversation, &sender, message)
}

pub async fn validate_targets(
    state: &Arc<IMClient>,
    targets: Vec<String>,
    sender: String,
) -> anyhow::Result<Vec<String>> {
    Ok(state
        .identity
        .validate_targets(&targets, "com.apple.madrid", &sender)
        .await?)
}

#[frb(type_64bit_int)]
pub struct TransferProgress {
    pub prog: usize,
    pub total: usize,
    pub attachment: Option<Attachment>,
}

pub async fn download_attachment(
    sink: StreamSink<TransferProgress>,
    aps: &APSConnection,
    attachment: Attachment,
    path: String,
) {
    wrap_sink(&sink, || async {
        let path = std::path::Path::new(&path);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;
        let mut file = std::fs::File::create(path)?;
        attachment
            .get_attachment(aps, &mut file, |prog, total| {
                let _ = sink.add(TransferProgress {
                    prog,
                    total,
                    attachment: None,
                });
            })
            .await?;
        file.flush()?;
        Ok(())
    })
    .await
}

pub async fn download_mmcs(
    sink: StreamSink<TransferProgress>,
    aps: &APSConnection,
    attachment: MMCSFile,
    path: String,
) {
    wrap_sink(&sink, || async {
        let path = std::path::Path::new(&path);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;

        let mut file = std::fs::File::create(path)?;
        attachment
            .get_attachment(aps, &mut file, |prog, total| {
                let _ = sink.add(TransferProgress {
                    prog,
                    total,
                    attachment: None,
                });
            })
            .await?;
        file.flush()?;
        Ok(())
    })
    .await
}

async fn wrap_sink<Fut, T: SseEncode + Send + Sync>(sink: &StreamSink<T>, f: impl FnOnce() -> Fut)
where
    Fut: Future<Output = anyhow::Result<()>>,
{
    if let Err(err) = f().await {
        let _ = sink.add_error(err);
    }
}

#[frb(type_64bit_int)]
pub struct MMCSTransferProgress {
    pub prog: usize,
    pub total: usize,
    pub file: Option<MMCSFile>,
}

pub async fn upload_mmcs(
    sink: StreamSink<MMCSTransferProgress>,
    aps: &APSConnection,
    path: String,
) {
    wrap_sink(&sink, || async {
        let mut file = std::fs::File::open(path)?;
        let prepared = MMCSFile::prepare_put(&mut file).await?;
        file.rewind()?;
        let attachment = MMCSFile::new(aps, &prepared, file, |prog, total| {
            let _ = sink.add(MMCSTransferProgress {
                prog,
                total,
                file: None,
            });
        })
        .await?;
        let _ = sink.add(MMCSTransferProgress {
            prog: 0,
            total: 0,
            file: Some(attachment),
        });
        Ok(())
    })
    .await
}

pub async fn upload_attachment(
    sink: StreamSink<TransferProgress>,
    aps: &APSConnection,
    path: String,
    mime: String,
    uti: String,
    name: String,
) {
    wrap_sink(&sink, || async {
        let mut file = std::fs::File::open(path)?;
        let prepared = MMCSFile::prepare_put(&mut file).await?;
        file.rewind()?;
        let attachment =
            Attachment::new_mmcs(aps, &prepared, file, &mime, &uti, &name, |prog, total| {
                let _ = sink.add(TransferProgress {
                    prog,
                    total,
                    attachment: None,
                });
            })
            .await?;
        let _ = sink.add(TransferProgress {
            prog: 0,
            total: 0,
            attachment: Some(attachment),
        });
        Ok(())
    })
    .await
}

pub async fn get_token(state: &APSConnection) -> Vec<u8> {
    state.get_token().await.to_vec()
}

pub fn save_user(user: &IDSUser) -> anyhow::Result<String> {
    Ok(plist_to_string(user)?)
}

pub fn restore_user(user: String) -> anyhow::Result<IDSUser> {
    info!("Restoring serialized IDS user (bytes={})", user.len());
    Ok(plist::from_reader(Cursor::new(user))?)
}

pub async fn make_find_my_phone(
    path: String,
    config: &JoinedOSConfig,
    aps: &APSConnection,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
) -> anyhow::Result<FindMyPhoneClient<DefaultAnisetteProvider>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let id_path = dir.join("sharedstreams.plist");
    let state: SharedStreamsState = plist::from_file(id_path)?;

    Ok(FindMyPhoneClient::new(
        &*config.config(),
        state.dsid.clone(),
        aps.clone(),
        anisette.clone(),
        provider.clone(),
    )
    .await?)
}

pub async fn get_devices(
    client: &mut FindMyPhoneClient<DefaultAnisetteProvider>,
) -> Vec<FoundDevice> {
    client.devices.clone()
}

pub async fn refresh_devices(
    config: &JoinedOSConfig,
    client: &mut FindMyPhoneClient<DefaultAnisetteProvider>,
) -> anyhow::Result<Vec<FoundDevice>> {
    client.refresh(&*config.config()).await?;
    Ok(client.devices.clone())
}

pub async fn play_find_my_sound(
    config: &JoinedOSConfig,
    client: &mut FindMyPhoneClient<DefaultAnisetteProvider>,
    device_id: String,
) -> anyhow::Result<()> {
    client.play_sound(&*config.config(), &device_id).await?;
    Ok(())
}

pub async fn make_find_my_friends(
    path: String,
    config: &JoinedOSConfig,
    aps: &APSConnection,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
) -> anyhow::Result<FindMyFriendsClient<DefaultAnisetteProvider>> {
    let dir = PathBuf::from_str(&path).unwrap();

    let id_path = dir.join("sharedstreams.plist");
    let state: SharedStreamsState = plist::from_file(id_path)?;

    let fmf_client = FindMyFriendsClient::new(
        &*config.config(),
        state.dsid.clone(),
        provider.clone(),
        aps.clone(),
        anisette.clone(),
        false,
    )
    .await?;
    Ok(fmf_client)
}

#[frb(type_64bit_int)]
pub struct DartBeaconShareInfo {
    pub share_id: String,
    pub acceptance_state: i64,
    pub owner_handle: String,
}

#[frb(type_64bit_int)]
pub struct DartBeacon {
    pub naming: BeaconNamingRecord,
    pub last_report: Option<LocationReport>,
    pub product_id: i64,
    pub battery_level: Option<i64>,
    pub vendor_id: i64,
    pub model: String,
    pub system_version: String,
    pub id: String,
    pub shared: Option<DartBeaconShareInfo>,
}

pub async fn accept_beacon_share(
    items: &Arc<FindMyClient<DefaultAnisetteProvider>>,
    share: String,
) -> anyhow::Result<()> {
    Ok(with_cloudkit_writer_operation(items.accept_item_share(&share)).await?)
}

pub async fn delete_beacon_share(
    items: &Arc<FindMyClient<DefaultAnisetteProvider>>,
    share: String,
) -> anyhow::Result<()> {
    Ok(with_cloudkit_writer_operation(items.delete_shared_item(&share, true)).await?)
}

pub async fn get_beacon_items(
    items: &Arc<FindMyClient<DefaultAnisetteProvider>>,
) -> anyhow::Result<Vec<DartBeacon>> {
    items.sync_item_positions().await?;

    let records = items.state.state.lock().await;

    Ok(records
        .accessories
        .iter()
        .map(|(id, a)| DartBeacon {
            naming: a.naming.clone(),
            last_report: a.last_report.clone(),
            product_id: a.master_record.product_id,
            battery_level: Some(a.master_record.battery_level),
            vendor_id: a.master_record.vendor_id,
            model: a.master_record.model.clone(),
            system_version: a.master_record.system_version.clone(),
            id: id.clone(),
            shared: None,
        })
        .chain(
            records
                .share_state
                .circles_member
                .iter()
                .filter_map(|(id, circle)| {
                    let a = records
                        .share_state
                        .shared_beacons
                        .get(&circle.beacon_identifier)?;
                    let def_state = SharedBeaconClient::default();
                    let client_state = records
                        .share_state
                        .shared_beacons_client
                        .get(&circle.beacon_identifier)
                        .unwrap_or(&def_state);
                    Some(DartBeacon {
                        naming: BeaconNamingRecord {
                            emoji: client_state.attributes.emoji.clone(),
                            name: client_state.attributes.name.clone(),
                            role_id: client_state.attributes.role_id,
                            associated_beacon: id.clone(),
                        },
                        last_report: client_state.last_report.clone(),
                        product_id: a.product_id,
                        battery_level: None,
                        vendor_id: a.vendor_id,
                        model: a.model.clone(),
                        system_version: a.system_version.clone(),
                        id: circle.beacon_identifier.clone(),
                        shared: Some(DartBeaconShareInfo {
                            share_id: id.clone(),
                            acceptance_state: circle.acceptance_state,
                            owner_handle: a.owner_handle.clone(),
                        }),
                    })
                }),
        )
        .collect())
}

pub async fn update_beacon_name(
    items: &Arc<FindMyClient<DefaultAnisetteProvider>>,
    naming_record: &BeaconNamingRecord,
) -> anyhow::Result<()> {
    with_cloudkit_writer_operation(items.update_beacon_name(naming_record)).await?;

    Ok(())
}

pub async fn get_following(
    client: &mut FindMyFriendsClient<DefaultAnisetteProvider>,
) -> Vec<Follow> {
    client.following.clone()
}

pub async fn refresh_following(
    config: &JoinedOSConfig,
    client: &mut FindMyFriendsClient<DefaultAnisetteProvider>,
) -> anyhow::Result<Vec<Follow>> {
    client.refresh(&*config.config()).await?;
    Ok(client.following.clone())
}

pub async fn select_friend(
    config: &JoinedOSConfig,
    client: &mut FindMyFriendsClient<DefaultAnisetteProvider>,
    friend: Option<String>,
) -> anyhow::Result<Vec<Follow>> {
    client.selected_friend = friend;
    client.refresh(&*config.config()).await?;
    Ok(client.following.clone())
}

pub async fn select_background_friend(
    fmfd: &Arc<FindMyClient<DefaultAnisetteProvider>>,
    friend: Option<String>,
) -> anyhow::Result<Vec<Follow>> {
    let mut x = fmfd.daemon.lock().await;
    x.selected_friend = friend;
    Ok(x.following.clone())
}

pub async fn get_background_following(
    fmfd: &Arc<FindMyClient<DefaultAnisetteProvider>>,
) -> Vec<Follow> {
    let x = fmfd.daemon.lock().await.following.clone();
    x
}

pub async fn refresh_background_following(
    state: &Arc<FindMyClient<DefaultAnisetteProvider>>,
    config: &JoinedOSConfig,
) -> anyhow::Result<Vec<Follow>> {
    let mut x = state.daemon.lock().await;
    x.refresh(&*config.config()).await?;
    Ok(x.following.clone())
}

#[frb(type_64bit_int)]
pub struct QuotaInfo {
    pub total_bytes: u64,
    pub available_bytes: u64,
    pub messages_bytes: u64,
}

pub async fn get_quota_info(
    info: &Arc<TokenProvider<DefaultAnisetteProvider>>,
) -> anyhow::Result<QuotaInfo> {
    let storage_info = info.get_storage_info().await?;
    Ok(QuotaInfo {
        total_bytes: storage_info.storage_data.quota_info_in_bytes.total_quota,
        available_bytes: storage_info
            .storage_data
            .quota_info_in_bytes
            .total_available,
        messages_bytes: storage_info
            .storage_usage_by_media
            .iter()
            .find(|m| &m.media_key == "messages")
            .map(|m| m.usage_in_bytes)
            .unwrap_or(0),
    })
}

#[derive(Serialize, Deserialize)]
struct GSAConfig {
    username: String,
    encrypted_password: Data,
    postdata_done: Option<bool>,
}

impl GSAConfig {
    fn get_password(&self) -> Result<Vec<u8>, PushError> {
        let key = AesKeystoreKey::ensure(
            &format!("gsa:password"),
            256,
            KeystoreAccessRules {
                block_modes: vec![EncryptMode::Gcm],
                can_encrypt: true,
                can_decrypt: true,
                ..Default::default()
            },
        )?;
        let encoded = key.decrypt(self.encrypted_password.as_ref(), &mut EncryptMode::Gcm)?;
        Ok(encoded)
    }

    fn encrypt(password: &[u8]) -> Result<Data, PushError> {
        let key = AesKeystoreKey::ensure(
            &format!("gsa:password"),
            256,
            KeystoreAccessRules {
                block_modes: vec![EncryptMode::Gcm],
                can_encrypt: true,
                can_decrypt: true,
                ..Default::default()
            },
        )?;
        let encoded = key.encrypt(password, &mut EncryptMode::Gcm)?;
        Ok(encoded.into())
    }
}

pub async fn do_login(
    path: String,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    finish: Option<UpdateAccountFinish>,
    os_config: &JoinedOSConfig,
) -> anyhow::Result<IDSUser> {
    let mut account = account.lock().await;

    let conf_dir = PathBuf::from_str(&path).unwrap();

    account
        .update_postdata("Apple Device", None, &["icloud", "imessage", "facetime"])
        .await?;

    let Some(pet) = account.get_pet() else {
        return Err(anyhow!("No pet!"));
    };
    let Some(spd) = &account.spd else {
        return Err(anyhow!("No spd!"));
    };

    debug!(
        "Parsed SPD metadata (keys={}, has_account_name={}, has_dsid={}, has_adsid={})",
        spd.len(),
        spd.contains_key("acname"),
        spd.contains_key("DsPrsId"),
        spd.contains_key("adsid")
    );
    let acname = spd
        .get("acname")
        .ok_or(anyhow!("No acname!"))?
        .as_string()
        .unwrap()
        .to_string();
    let dsid = spd
        .get("DsPrsId")
        .ok_or(anyhow!("No dsid!"))?
        .as_unsigned_integer()
        .unwrap()
        .to_string();
    let adsid = spd
        .get("adsid")
        .ok_or(anyhow!("No adsid!"))?
        .as_string()
        .unwrap();

    let delegates = if let Some(finish) = finish {
        finish
            .accept_terms(
                &[LoginDelegate::IDS, LoginDelegate::MobileMe],
                &*account,
                &*os_config.config(),
            )
            .await?
    } else {
        login_apple_delegates(
            &*account,
            None,
            &*os_config.config(),
            &[LoginDelegate::IDS, LoginDelegate::MobileMe],
        )
        .await?
    };

    plist::to_file_xml(
        conf_dir.join("gsa.plist"),
        &GSAConfig {
            username: account.username.clone().unwrap(),
            encrypted_password: GSAConfig::encrypt(&account.hashed_password.clone().unwrap())?,
            postdata_done: Some(true),
        },
    )
    .unwrap();

    let path = conf_dir.join("statuskit.plist");
    std::fs::write(
        &path,
        plist_to_string(&StatusKitState {
            my_key: None,
            ..plist::from_file(&path).unwrap_or_default()
        })
        .unwrap(),
    )
    .unwrap();

    let mobileme = delegates.mobileme.unwrap();
    let findmy = FindMyState::new(dsid.clone());

    let id_path = conf_dir.join("findmy.plist");
    if !id_path.exists() {
        std::fs::write(id_path, findmy.encode()?).unwrap();
    }

    let shared_streams = SharedStreamsState::new(dsid.clone(), &mobileme);
    if let Some(shared_streams) = shared_streams {
        let id_path = conf_dir.join("sharedstreams.plist");
        if !id_path.exists() {
            std::fs::write(id_path, plist_to_string(&shared_streams).unwrap()).unwrap();
        }
    } else {
        warn!("missing shared streams tokens!");
    }

    let cloudkitstate = CloudKitState::new(dsid.clone());
    if let Some(cloudkitstate) = cloudkitstate {
        let id_path = conf_dir.join("cloudkit.plist");
        if !id_path.exists() {
            std::fs::write(id_path, plist_to_string(&cloudkitstate).unwrap()).unwrap();
        }
    } else {
        warn!("missing cloudkit tokens!");
    }

    let keychain = KeychainClientState::new(dsid.clone(), adsid.to_string(), &mobileme);
    if let Some(keychain) = keychain {
        let id_path = conf_dir.join("keychain.plist");
        if !id_path.exists() {
            std::fs::write(id_path, plist_to_string(&keychain).unwrap()).unwrap();
        }
    } else {
        warn!("missing keychain tokens!");
    }

    debug!("Spd finish parse");

    let user = authenticate_apple(delegates.ids.unwrap(), &*os_config.config()).await?;
    Ok(user)
}

#[frb(sync)]
pub fn get_available_user(path: String) -> Option<String> {
    let conf_dir = PathBuf::from_str(&path).unwrap();
    plist::from_file::<_, GSAConfig>(&conf_dir.join("gsa.plist"))
        .ok()
        .map(|i| i.username)
}

pub async fn try_auth(
    path: String,
    conf: &JoinedOSConfig,
    conn: &APSConnection,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    creds: Option<(String, String)>,
) -> anyhow::Result<(
    Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    LoginState,
)> {
    let conf_dir = PathBuf::from_str(&path).unwrap();
    info!("Here");
    let mut apple_account = AppleAccount::new_with_anisette(
        get_login_config(&conf_dir, conf, conn).await,
        anisette.clone(),
    )?;

    let result = if let Some((username, password)) = creds {
        reset_user(&path);

        let mut password_hasher = sha2::Sha256::new();
        password_hasher.update(&password.as_bytes());
        let hashed_password = password_hasher.finalize();
        (username, hashed_password.to_vec())
    } else {
        let state = plist::from_file::<_, GSAConfig>(&conf_dir.join("gsa.plist"))?;
        (state.username.clone(), state.get_password()?)
    };

    let login_state = apple_account.login_email_pass(&result.0, &result.1).await?;

    info!("Here3");

    let account = Arc::new(Mutex::new(apple_account));

    info!("Here6");
    Ok((account, login_state))
}

pub async fn try_icloud_login(
    path: String,
    conf: &JoinedOSConfig,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
) -> anyhow::Result<Option<IDSUser>> {
    let pet = account.lock().await.get_pet();
    if let Some(pet) = pet {
        info!("Here4");
        let identity = do_login(path, &account, None, conf).await?;
        info!("Here5");

        Ok(Some(identity))
    } else {
        Ok(None)
    }
}

pub async fn auth_phone(
    conn: &APSConnection,
    config: &JoinedOSConfig,
    number: String,
    sig: Vec<u8>,
) -> anyhow::Result<IDSUser> {
    let identity = authenticate_phone(
        &number,
        AuthPhone {
            push_token: conn.get_token().await.to_vec().into(),
            sigs: vec![sig.into()],
        },
        &*config.config(),
    )
    .await?;

    Ok(identity)
}

pub async fn send_2fa_to_devices(
    state: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    conn: &APSConnection,
) -> anyhow::Result<(
    CircleClientSession<DefaultAnisetteProvider>,
    LoginState,
    Option<String>,
)> {
    let account = state.lock().await;
    let spd = account.spd.as_ref().unwrap();
    let dsid = spd["DsPrsId"].as_unsigned_integer().unwrap();
    drop(account);

    let client_session =
        CircleClientSession::new(dsid, state.clone(), conn.get_token().await).await?;

    #[cfg(target_os = "android")]
    {
        let sid = client_session.session_id.clone();
        Ok((client_session, LoginState::Needs2FAVerification, sid))
    }

    #[cfg(not(target_os = "android"))]
    {
        // Desktop cannot advertise the BLE proximity service required to
        // complete the circle exchange. Keep the session object for bridge
        // compatibility, but trigger Apple's standard trusted-device prompt.
        let login_state = state.lock().await.send_2fa_to_devices().await?;
        Ok((client_session, login_state, None))
    }
}

#[frb(type_64bit_int)]
pub struct ViableBottle {
    pub escrow: EscrowData,
    pub numeric_length: u64,
    pub device_name: String,
    pub model_class: String,
}

pub async fn is_in_clique(keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>) -> bool {
    match with_cloudkit_writer_operation(async {
        Ok::<bool, rustpush::PushError>(keychain.is_in_clique().await)
    })
    .await
    {
        Ok(in_clique) => in_clique,
        Err(error) => {
            warn!("Unable to acquire CloudKit writer permit for clique status check: {error}");
            false
        }
    }
}

pub async fn join_clique_with_bottle(
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
    bottle: &EscrowData,
    password: String,
    device_password: String,
) -> anyhow::Result<()> {
    with_cloudkit_writer_operation(keychain.join_clique_from_escrow(
        bottle,
        password.as_bytes(),
        device_password.as_bytes(),
    ))
    .await?;
    Ok(())
}

pub async fn reset_clique(
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
    cloud_messages: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    device_password: String,
) -> anyhow::Result<()> {
    with_cloudkit_writer_operation(async {
        keychain.reset_clique(device_password.as_bytes()).await?;
        cloud_messages.reset().await?;
        Ok::<(), rustpush::PushError>(())
    })
    .await?;
    Ok(())
}

pub async fn get_bottles(
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
) -> anyhow::Result<Vec<ViableBottle>> {
    let bottles = keychain.get_viable_bottles().await?;
    Ok(bottles
        .into_iter()
        .filter_map(|b| {
            let client_metadata = b.1.client_metadata.as_dictionary()?;
            Some(ViableBottle {
                escrow: b.0,
                numeric_length: client_metadata
                    .get("SecureBackupNumericPassphraseLength")
                    .and_then(|i| i.as_unsigned_integer())
                    .unwrap_or(0),
                device_name: client_metadata
                    .get("device_name")
                    .and_then(|i| i.as_string())
                    .unwrap_or("No Name")
                    .to_string(),
                model_class: client_metadata
                    .get("device_model_class")
                    .and_then(|i| i.as_string())
                    .unwrap_or("iMac")
                    .to_string(),
            })
        })
        .collect())
}

pub fn encode_summary_info(info: &MessageSummaryInfo) -> Vec<u8> {
    plist_to_bin(info).unwrap()
}

pub fn decode_summary_info(info: &[u8]) -> MessageSummaryInfo {
    plist::from_bytes(info).unwrap()
}

use rustpush::{coder_decode_flattened, coder_encode_flattened};

#[frb(sync)]
pub fn attachment_to_cloud(att: &Attachment) -> Option<MMCSAttachmentMeta> {
    att.into()
}

#[frb(sync)]
pub fn nscoder_encode(value: &[StCollapsedValue]) -> Vec<u8> {
    coder_encode_flattened(value)
}

#[frb(sync)]
pub fn nscoder_decode(data: &[u8]) -> Vec<StCollapsedValue> {
    coder_decode_flattened(data)
}

#[frb(sync)]
pub fn save_cloud_chat(value: &CloudChat) -> Vec<u8> {
    plist_to_bin(&value).unwrap()
}

#[frb(sync)]
pub fn restore_cloud_chat(data: &[u8]) -> CloudChat {
    plist::from_bytes(data).unwrap()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncRawRecordKind {
    EncryptedUpsert,
    Tombstone,
    UnsupportedRecordType,
    MalformedMetadata,
}

#[derive(Clone, Debug)]
pub struct CloudSyncRawSystemFields {
    pub etag: Option<String>,
    pub created_at: Option<f64>,
    pub modified_at: Option<f64>,
    pub permission: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct CloudSyncRawChange {
    pub record_name: Option<String>,
    pub record_type: Option<String>,
    pub change_type: Option<i32>,
    pub system_fields: Option<CloudSyncRawSystemFields>,
    pub encrypted_record: Option<Vec<u8>>,
    pub tombstone_payload: Option<Vec<u8>>,
    pub kind: CloudSyncRawRecordKind,
}

#[derive(Clone, Debug)]
pub struct CloudSyncRawPage {
    pub changes: Vec<CloudSyncRawChange>,
    pub next_token: Option<Vec<u8>>,
    pub status: i32,
    pub complete: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncRawFailureCategory {
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

/// Redacted failure information for the durable Dart scheduler. This contains
/// no server body, record identifier, token, account identifier, or message
/// content.
#[derive(Clone, Debug)]
pub struct CloudSyncRawFailure {
    pub category: CloudSyncRawFailureCategory,
    pub retry_after_seconds: Option<u64>,
    pub safe_code: String,
}

/// Exactly one of [page] and [failure] is populated.
#[derive(Clone, Debug)]
pub struct CloudSyncRawFetchResult {
    pub page: Option<CloudSyncRawPage>,
    pub failure: Option<CloudSyncRawFailure>,
}

fn map_cloud_sync_raw_page(page: CloudMessageRecordPage) -> CloudSyncRawPage {
    let complete = page.is_complete();
    CloudSyncRawPage {
        changes: page
            .changes
            .into_iter()
            .map(|change| CloudSyncRawChange {
                record_name: change.record_name,
                record_type: change.record_type,
                change_type: change.change_type,
                system_fields: change.system_fields.map(|fields| CloudSyncRawSystemFields {
                    etag: fields.etag,
                    created_at: fields.created_at,
                    modified_at: fields.modified_at,
                    permission: fields.permission,
                }),
                encrypted_record: change.encrypted_record,
                tombstone_payload: change.tombstone_payload,
                kind: match change.kind {
                    CloudMessageRecordKind::EncryptedUpsert => {
                        CloudSyncRawRecordKind::EncryptedUpsert
                    }
                    CloudMessageRecordKind::Tombstone => CloudSyncRawRecordKind::Tombstone,
                    CloudMessageRecordKind::UnsupportedRecordType => {
                        CloudSyncRawRecordKind::UnsupportedRecordType
                    }
                    CloudMessageRecordKind::MalformedMetadata => {
                        CloudSyncRawRecordKind::MalformedMetadata
                    }
                },
            })
            .collect(),
        next_token: page.next_token,
        status: page.status,
        complete,
    }
}

fn cloud_sync_retry_after_seconds(error: &PushError) -> Option<u64> {
    match error {
        PushError::CloudKitError(result) => result
            .error
            .as_ref()
            .and_then(|error| error.retry_after_seconds)
            .filter(|seconds| *seconds > 0)
            .map(|seconds| seconds as u64),
        PushError::CloudKitHttpError {
            retry_after: Some(retry_after),
            ..
        } if !retry_after.is_zero() => Some(retry_after.as_secs().max(1)),
        PushError::DoNotRetry(inner) => cloud_sync_retry_after_seconds(inner),
        PushError::BatchError(inner) => cloud_sync_retry_after_seconds(inner),
        _ => None,
    }
}

fn cloud_sync_failure_category(error: &PushError) -> (CloudSyncRawFailureCategory, &'static str) {
    match error {
        PushError::CloudKitError(result) => match classify_cloudkit_failure(result) {
            CloudKitFailureClass::Throttled => {
                (CloudSyncRawFailureCategory::Throttled, "cloudkit-throttled")
            }
            CloudKitFailureClass::TransientServer => {
                (CloudSyncRawFailureCategory::Server, "cloudkit-server")
            }
            CloudKitFailureClass::Authentication => (
                CloudSyncRawFailureCategory::Authorization,
                "cloudkit-authorization",
            ),
            CloudKitFailureClass::Conflict => {
                (CloudSyncRawFailureCategory::Conflict, "cloudkit-conflict")
            }
            // A checkpoint reset is a deliberate operator/engine decision. Do
            // not turn it into an automatic destructive retry here.
            CloudKitFailureClass::ResetRequired => (
                CloudSyncRawFailureCategory::Unknown,
                "cloudkit-reset-required",
            ),
            CloudKitFailureClass::Permanent => {
                (CloudSyncRawFailureCategory::Unknown, "cloudkit-permanent")
            }
            CloudKitFailureClass::Unknown => {
                (CloudSyncRawFailureCategory::Unknown, "cloudkit-unknown")
            }
        },
        PushError::RequestError(error) => {
            if error.is_timeout() || error.is_connect() {
                return (CloudSyncRawFailureCategory::Network, "network");
            }
            match error.status().map(|status| status.as_u16()) {
                Some(401 | 403) => (
                    CloudSyncRawFailureCategory::Authorization,
                    "http-authorization",
                ),
                Some(408) => (CloudSyncRawFailureCategory::Network, "http-timeout"),
                Some(429) => (CloudSyncRawFailureCategory::Throttled, "http-throttled"),
                Some(500..=599) => (CloudSyncRawFailureCategory::Server, "http-server"),
                _ => (CloudSyncRawFailureCategory::Unknown, "http-unknown"),
            }
        }
        PushError::StatusError(status) => match status.as_u16() {
            401 | 403 => (
                CloudSyncRawFailureCategory::Authorization,
                "http-authorization",
            ),
            408 => (CloudSyncRawFailureCategory::Network, "http-timeout"),
            429 => (CloudSyncRawFailureCategory::Throttled, "http-throttled"),
            500..=599 => (CloudSyncRawFailureCategory::Server, "http-server"),
            _ => (CloudSyncRawFailureCategory::Unknown, "http-unknown"),
        },
        PushError::CloudKitHttpError { status, .. } => match *status {
            401 | 403 => (
                CloudSyncRawFailureCategory::Authorization,
                "http-authorization",
            ),
            408 => (CloudSyncRawFailureCategory::Network, "http-timeout"),
            429 => (CloudSyncRawFailureCategory::Throttled, "http-throttled"),
            500..=599 => (CloudSyncRawFailureCategory::Server, "http-server"),
            _ => (CloudSyncRawFailureCategory::Unknown, "http-unknown"),
        },
        PushError::ResourceTimeout
        | PushError::ResourceGenTimeout
        | PushError::ResourceStalled
        | PushError::NotConnected => (CloudSyncRawFailureCategory::Network, "network"),
        PushError::TooManyRequests => {
            (CloudSyncRawFailureCategory::Throttled, "cloudkit-throttled")
        }
        PushError::UnauthorizedAccountError
        | PushError::TokenMissing
        | PushError::CloudKitWarmAuthenticationRequired
        | PushError::UserNotFound
        | PushError::AuthInvalid(_)
        | PushError::MobileMeError(_, _) => (
            CloudSyncRawFailureCategory::Authorization,
            "cloudkit-authorization",
        ),
        PushError::PCSRecordKeyMissing
        | PushError::PCSKeyIdMismatch
        | PushError::PCSDecryptionFailed
        | PushError::MasterKeyNotFound
        | PushError::NotInClique
        | PushError::ShareKeyNotFound(_)
        | PushError::NoRoutingKey => (
            CloudSyncRawFailureCategory::PcsUnavailable,
            "pcs-unavailable",
        ),
        PushError::PCSCiphertextMalformed
        | PushError::ProtobufError(_)
        | PushError::JsonError(_) => (
            CloudSyncRawFailureCategory::MalformedRecord,
            "malformed-response",
        ),
        PushError::CloudKitChangeTokenExpired => (
            CloudSyncRawFailureCategory::Unknown,
            "cloudkit-change-token-expired",
        ),
        PushError::CloudKitProtocolError(CloudKitProtocolError::ContinuationTokenNoProgress) => (
            CloudSyncRawFailureCategory::MalformedRecord,
            "cloudkit-continuation-no-progress",
        ),
        PushError::IoError(_) => (CloudSyncRawFailureCategory::LocalStorage, "local-storage"),
        PushError::DoNotRetry(inner) => cloud_sync_failure_category(inner),
        PushError::BatchError(inner) => cloud_sync_failure_category(inner),
        _ => (CloudSyncRawFailureCategory::Unknown, "unknown"),
    }
}

#[cfg(test)]
mod cloud_sync_failure_mapping_tests {
    use super::*;

    #[test]
    fn continuation_no_progress_is_nonretryable_protocol_failure() {
        let error =
            PushError::CloudKitProtocolError(CloudKitProtocolError::ContinuationTokenNoProgress);

        assert_eq!(
            cloud_sync_failure_category(&error),
            (
                CloudSyncRawFailureCategory::MalformedRecord,
                "cloudkit-continuation-no-progress",
            )
        );
        assert_eq!(cloud_sync_retry_after_seconds(&error), None);
    }

    #[test]
    fn cloudkit_http_retry_after_survives_bridge_mapping() {
        let error = PushError::CloudKitHttpError {
            status: 429,
            retry_after: Some(Duration::from_secs(901)),
        };

        assert_eq!(
            cloud_sync_failure_category(&error),
            (CloudSyncRawFailureCategory::Throttled, "http-throttled",)
        );
        assert_eq!(cloud_sync_retry_after_seconds(&error), Some(901));
    }
}

/// Fetches one bounded, ordered, read-only raw CloudKit page.
///
/// Records remain in their server-encrypted protobuf form. Unsupported or
/// malformed records are returned for quarantine rather than decoded.
const CLOUD_SYNC_RAW_FETCH_DEADLINE: Duration = Duration::from_secs(40);

pub async fn cloud_sync_fetch_raw_page(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    stream: String,
    continuation_token: Option<Vec<u8>>,
    max_changes: u32,
) -> CloudSyncRawFetchResult {
    if !matches!(
        stream.as_str(),
        "chats"
            | "messages"
            | "attachments"
            | "messageUpdateZone"
            | "recoverableMessageDeleteZone"
            | "scheduledMessageZone"
            | "chat1ManateeZone"
    ) {
        return CloudSyncRawFetchResult {
            page: None,
            failure: Some(CloudSyncRawFailure {
                category: CloudSyncRawFailureCategory::Unknown,
                retry_after_seconds: None,
                safe_code: "invalid-stream".to_string(),
            }),
        };
    }

    let fetch = async {
        match stream.as_str() {
            "chats" => {
                cloud_messages_client
                    .sync_chats_page(continuation_token, Some(max_changes))
                    .await
            }
            "messages" => {
                cloud_messages_client
                    .sync_messages_page(continuation_token, Some(max_changes))
                    .await
            }
            "attachments" => {
                cloud_messages_client
                    .sync_attachments_page(continuation_token, Some(max_changes))
                    .await
            }
            "messageUpdateZone" => {
                cloud_messages_client
                    .sync_message_update_page(continuation_token, Some(max_changes))
                    .await
            }
            "recoverableMessageDeleteZone" => {
                cloud_messages_client
                    .sync_recoverable_message_delete_page(continuation_token, Some(max_changes))
                    .await
            }
            "scheduledMessageZone" => {
                cloud_messages_client
                    .sync_scheduled_message_page(continuation_token, Some(max_changes))
                    .await
            }
            "chat1ManateeZone" => {
                cloud_messages_client
                    .sync_chat1_page(continuation_token, Some(max_changes))
                    .await
            }
            _ => unreachable!("stream was validated before starting the fetch"),
        }
    };

    let result = match tokio::time::timeout(CLOUD_SYNC_RAW_FETCH_DEADLINE, fetch).await {
        Ok(result) => result,
        Err(_) => {
            return CloudSyncRawFetchResult {
                page: None,
                failure: Some(CloudSyncRawFailure {
                    category: CloudSyncRawFailureCategory::Network,
                    retry_after_seconds: None,
                    safe_code: "fetch-deadline".to_string(),
                }),
            };
        }
    };

    match result {
        Ok(page) => CloudSyncRawFetchResult {
            page: Some(map_cloud_sync_raw_page(page)),
            failure: None,
        },
        Err(error) => {
            let (category, safe_code) = cloud_sync_failure_category(&error);
            CloudSyncRawFetchResult {
                page: None,
                failure: Some(CloudSyncRawFailure {
                    category,
                    retry_after_seconds: cloud_sync_retry_after_seconds(&error),
                    safe_code: safe_code.to_string(),
                }),
            }
        }
    }
}

pub async fn sync_chats(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    continuation_token: Option<Vec<u8>>,
) -> anyhow::Result<(Vec<u8>, HashMap<String, Option<CloudChat>>, i32)> {
    Ok(cloud_messages_client.sync_chats(continuation_token).await?)
}

pub async fn save_chats(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    chats: HashMap<String, CloudChat>,
) -> anyhow::Result<HashMap<String, bool>> {
    Ok(cloud_messages_client
        .save_chats(chats)
        .await?
        .into_iter()
        .map(|(a, b)| (a, b.is_ok()))
        .collect())
}

pub async fn delete_chats(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    chats: &[String],
) -> anyhow::Result<()> {
    Ok(cloud_messages_client.delete_chats(chats).await?)
}

pub async fn sync_messages(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    continuation_token: Option<Vec<u8>>,
) -> anyhow::Result<(Vec<u8>, HashMap<String, Option<CloudMessage>>, i32)> {
    Ok(cloud_messages_client
        .sync_messages(continuation_token)
        .await?)
}

pub async fn save_messages(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    messages: HashMap<String, CloudMessage>,
) -> anyhow::Result<HashMap<String, bool>> {
    Ok(cloud_messages_client
        .save_messages(messages)
        .await?
        .into_iter()
        .map(|(a, b)| (a, b.is_ok()))
        .collect())
}

pub async fn delete_messages(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    messages: &[String],
) -> anyhow::Result<()> {
    Ok(cloud_messages_client.delete_messages(messages).await?)
}

#[frb(sync)]
pub fn decode_message_info(data: &[u8]) -> anyhow::Result<MessageSummaryInfo> {
    Ok(plist::from_bytes(data)?)
}

#[frb(sync)]
pub fn encode_message_info(info: &MessageSummaryInfo) -> Vec<u8> {
    plist_to_bin(info).unwrap()
}

#[frb(external)]
impl MessageFlags {
    #[frb(sync)]
    pub fn bits(&self) -> i64 {}
    #[frb(sync)]
    pub fn from_bits_truncate(val: i64) -> Self {}
}

pub async fn sync_attachments(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    continuation_token: Option<Vec<u8>>,
) -> anyhow::Result<(Vec<u8>, HashMap<String, Option<CloudAttachment>>, i32)> {
    Ok(cloud_messages_client
        .sync_attachments(continuation_token)
        .await?)
}

pub async fn save_attachments(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    attachments: HashMap<String, CloudAttachment>,
) -> anyhow::Result<HashMap<String, bool>> {
    Ok(cloud_messages_client
        .save_attachments(attachments)
        .await?
        .into_iter()
        .map(|(a, b)| (a, b.is_ok()))
        .collect())
}

pub async fn delete_attachments(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    attachments: &[String],
) -> anyhow::Result<()> {
    Ok(cloud_messages_client
        .delete_attachments(attachments)
        .await?)
}

pub async fn count_records(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
) -> anyhow::Result<CloudMessageSummary> {
    Ok(cloud_messages_client.count_records().await?)
}

pub async fn download_cloud_attachments(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    files: Vec<(String, String)>,
) -> anyhow::Result<()> {
    let mut map = HashMap::new();
    for (file, record) in files {
        let path = std::path::Path::new(&file);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;

        map.insert(record, std::fs::File::create(file)?);
    }

    cloud_messages_client.download_attachment(map).await?;
    Ok(())
}

#[frb(sync, type_64bit_int)]
pub fn systemtime_to_millis(time: SystemTime) -> u64 {
    time.duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

#[frb(sync)]
pub fn utm_now() -> SystemTime {
    SystemTime::now()
}

#[frb(sync)]
pub fn date_now() -> plist::Date {
    SystemTime::now().into()
}

#[frb(sync, type_64bit_int)]
pub fn date_to_ms(date: &plist::Date) -> u64 {
    let systemtime: SystemTime = date.clone().into();
    systemtime
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

#[frb(sync, type_64bit_int)]
pub fn ms_to_date(ms: u64) -> plist::Date {
    let time = SystemTime::UNIX_EPOCH + Duration::from_millis(ms);
    time.into()
}

pub async fn download_cloud_group_photos(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    files: Vec<(String, String)>,
) -> anyhow::Result<()> {
    let mut map = HashMap::new();
    for (file, record) in files {
        let path = std::path::Path::new(&file);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;

        map.insert(record, std::fs::File::create(file)?);
    }

    cloud_messages_client.download_group_photo(map).await?;
    Ok(())
}

pub async fn upload_cloud_attachments(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    files: Vec<(String, String)>,
) -> anyhow::Result<HashMap<String, Asset>> {
    let mut to_upload = vec![];
    let mut hashes = vec![];
    for (file, record) in &files {
        let prepared = cloud_messages_client
            .prepare_file(std::fs::File::open(file)?)
            .await?;
        hashes.push(prepared.total_sig.clone());
        to_upload.push((prepared, std::fs::File::open(file)?, record.clone()));
    }

    let results = cloud_messages_client.upload_attachments(to_upload).await?;

    let mut finish = HashMap::new();
    for result in results {
        let idx = hashes
            .iter()
            .position(|h| h == result.signature.as_ref().unwrap())
            .unwrap();
        finish.insert(files[idx].1.clone(), result);
    }

    Ok(finish)
}

pub async fn upload_group_photo(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    files: Vec<(String, String)>,
) -> anyhow::Result<HashMap<String, Asset>> {
    let mut to_upload = vec![];
    let mut hashes = vec![];
    for (file, record) in &files {
        let prepared = cloud_messages_client
            .prepare_file(std::fs::File::open(file)?)
            .await?;
        hashes.push(prepared.total_sig.clone());
        to_upload.push((prepared, std::fs::File::open(file)?, record.clone()));
    }

    let results = cloud_messages_client.upload_group_photo(to_upload).await?;

    let mut finish = HashMap::new();
    for result in results {
        let idx = hashes
            .iter()
            .position(|h| h == result.signature.as_ref().unwrap())
            .unwrap();
        finish.insert(files[idx].1.clone(), result);
    }

    Ok(finish)
}

pub async fn change_escrow_password(
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
    device_password: String,
) -> anyhow::Result<()> {
    keychain
        .change_escrow_password(device_password.as_bytes())
        .await?;
    Ok(())
}

pub async fn circle_setup_clique(
    client: &Arc<Mutex<Option<CircleClientSession<DefaultAnisetteProvider>>>>,
    keychain: &Arc<KeychainClient<DefaultAnisetteProvider>>,
    device_password: String,
) -> anyhow::Result<bool> {
    with_cloudkit_writer_operation(async {
        let mut locked = client.lock().await;

        let Some(inner) = &mut *locked else {
            return Ok(true);
        };
        if let Err(e) = inner
            .setup_trusted_peers(keychain.clone(), device_password.as_bytes())
            .await
        {
            if let PushError::CircleOver = &e {
                return Ok(true);
            }
            return Err(e.into());
        }
        Ok(false)
    })
    .await
}

pub async fn verify_2fa(
    path: String,
    client: &mut CircleClientSession<DefaultAnisetteProvider>,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    os_config: &JoinedOSConfig,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    watcher: &mut broadcast::Receiver<APSMessage>,
    idms: &Arc<IdmsAuthListener>,
    code: String,
) -> anyhow::Result<(LoginState, Option<IDSUser>)> {
    #[cfg(target_os = "android")]
    let mut login_state = {
        client.send_code(&code).await?;

        let proximity_result = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let msg = watcher
                    .recv()
                    .await
                    .map_err(|error| anyhow!("Trusted-device 2FA push listener closed: {error}"))?;
                if let Some(test) = idms.handle(msg)? {
                    match test {
                        IdmsMessage::CircleRequest(c, _) => {
                            if let Some(state) = client.handle_circle_request(&c).await? {
                                break Ok::<_, anyhow::Error>(state);
                            }
                        }
                        _ => {}
                    }
                }
            }
        })
        .await;

        match proximity_result {
            Ok(Ok(state)) => state,
            Ok(Err(error)) => {
                warn!(
                    "Trusted-device 2FA proximity exchange failed ({error}); \
                     falling back to direct verification"
                );
                account.lock().await.verify_2fa(code).await?
            }
            Err(_) => {
                warn!(
                    "Trusted-device 2FA proximity response timed out; \
                     falling back to direct verification"
                );
                account.lock().await.verify_2fa(code).await?
            }
        }
    };

    #[cfg(not(target_os = "android"))]
    let mut login_state = {
        // The code shown by Apple's normal trusted-device prompt can be
        // verified directly without waiting on an unavailable BLE exchange.
        account.lock().await.verify_2fa(code).await?
    };

    let mut user = None;
    let pet = account.lock().await.get_pet();
    if let Some(pet) = pet {
        let identity = do_login(path, &account, None, os_config).await?;
        user = Some(identity);

        // who needs extra steps when you have a PET, amirite?
        info!("Trusted-device verification produced a PET");
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    Ok((login_state, user))
}

pub async fn get_2fa_sms_opts(
    state: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
) -> anyhow::Result<(Vec<TrustedPhoneNumber>, Option<LoginState>)> {
    let account = state.lock().await;
    let extras = account.get_auth_extras().await?;
    Ok((extras.trusted_phone_numbers, extras.new_state))
}

pub async fn send_2fa_sms(
    locked: Option<CircleClientSession<DefaultAnisetteProvider>>,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    phone_id: u32,
) -> anyhow::Result<LoginState> {
    if let Some(l) = locked {
        l.cancel().await?;
    }

    let account = account.lock().await;
    Ok(account.send_sms_2fa_to_devices(phone_id).await?)
}

pub async fn verify_2fa_sms(
    path: String,
    account_mut: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    anisette: &ArcAnisetteClient<DefaultAnisetteProvider>,
    config: &JoinedOSConfig,
    body: &VerifyBody,
    code: String,
) -> anyhow::Result<(LoginState, Option<IDSUser>)> {
    let mut account = account_mut.lock().await;
    let mut login_state = account.verify_sms_2fa(code, body.clone()).await?;

    let mut user = None;
    if let Some(pet) = account.get_pet() {
        drop(account);
        let identity = do_login(path, &account_mut, None, config).await?;
        user = Some(identity);

        // who needs extra steps when you have a PET, amirite?
        info!("SMS verification produced a PET");
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    Ok((login_state, user))
}

pub async fn validate_cert(conn: &APSConnection, user: &IDSUser) -> anyhow::Result<Vec<String>> {
    let x = Ok(user.get_possible_handles(&*conn.state.read().await).await?);
    info!("Validated cert");
    x
}

#[frb(sync)]
pub fn cancel_poll(cancel: &mpsc::Sender<()>) {
    let _ = cancel.try_send(());
}

fn reset_user(path: &str) {
    let dir = PathBuf::from_str(path).unwrap();

    let _ = std::fs::remove_file(dir.join("gsa.plist"));
    let _ = std::fs::remove_file(dir.join("findmy.plist"));
    let _ = std::fs::remove_file(dir.join("facetime.plist"));
    let _ = std::fs::remove_file(dir.join("cloudkit.plist"));
    let _ = std::fs::remove_file(dir.join("keychain.plist"));
    let _ = std::fs::remove_file(dir.join("passwords.plist"));
    let _ = std::fs::remove_file(dir.join("sharedstreams.plist"));

    let path = dir.join("statuskit.plist");
    std::fs::write(
        &path,
        plist_to_string(&StatusKitState {
            my_key: None,
            ..plist::from_file(&path).unwrap_or_default()
        })
        .unwrap(),
    )
    .unwrap();
}

pub async fn reset_state(
    cancel: &mpsc::Sender<()>,
    path: String,
    config: &JoinedOSConfig,
    aps: &APSConnection,
    account: Option<Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>>,
    reset_hw: bool,
    logout: bool,
) -> anyhow::Result<()> {
    // tell any poll to stop
    let _ = cancel.try_send(());
    let dir = PathBuf::from_str(&path).unwrap();

    info!("c");
    if logout {
        if let Some(hardware) = read_hardware(path.clone()) {
            // try deregistering from iMessage, but if it fails we don't really care
            if let Ok(identity) = IDSNGMIdentity::restore(hardware.identity.as_ref(), "openbubbles")
            {
                let _ = register(
                    &*config.config(),
                    &*aps.state.read().await,
                    &[],
                    &mut [],
                    &identity,
                )
                .await;
            }
        }
        if let Some(account) = &account {
            let _ = account.lock().await.logout_all("Apple Device").await;
        }

        reset_user(&path);
    }
    let _ = std::fs::remove_file(dir.join("id.plist"));
    if let Ok(mut cache) = plist::from_file::<_, Dictionary>(dir.join("id_cache.plist")) {
        // keep replay counters which are nessesary if our identity doesn't change
        cache
            .get_mut("cache")
            .expect("No cache?")
            .as_dictionary_mut()
            .unwrap()
            .clear();
        plist::to_file_xml(dir.join("id_cache.plist"), &cache)?;
    }

    if reset_hw {
        let _ = std::fs::remove_file(dir.join("hw_info.plist"));
        let _ = std::fs::remove_file(dir.join("id_cache.plist")); // our identity is wiped so we can wipe our counters too
        let _ = std::fs::remove_file(dir.join("statuskit.plist"));
    }

    Ok(())
}

pub async fn invalidate_id_cache(client: &Arc<IMClient>) -> anyhow::Result<()> {
    client.identity.invalidate_id_cache().await;
    Ok(())
}

#[frb(sync)]
pub fn close_client(client: &Arc<IMClient>) {
    client.identity.close();
}

#[frb(sync)]
pub fn close_aps(aps: &APSConnection) {
    aps.close();
}

#[frb(sync)]
pub fn close_syncmanager(shared: &SyncManager<DefaultAnisetteProvider, MyFilePackager>) {
    shared.close();
}

// NOTE, breaks linux registration for some god stupid awful reason
// only valid before registration
pub async fn get_user_name(
    state: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
) -> anyhow::Result<String> {
    let (first, last) = state.lock().await.get_name();
    Ok(format!("{first} {last}"))
}

#[derive(Clone)]
#[frb(type_64bit_int)]
pub enum RegisterState {
    Registered {
        next_s: i64,
    },
    Registering,
    Failed {
        retry_wait: Option<u64>,
        error: String,
    },
}

pub async fn get_regstate(state: &Arc<IMClient>) -> anyhow::Result<RegisterState> {
    let mutex_ref = state.identity.resource_state.borrow().clone();
    Ok(match &mutex_ref {
        ResourceState::Generating => RegisterState::Registering,
        ResourceState::Generated => RegisterState::Registered {
            next_s: state.identity.calculate_rereg_time_s().await,
        },
        ResourceState::Failed(failure) => RegisterState::Failed {
            retry_wait: failure.retry_wait,
            error: format!("{}", failure.error),
        },
        ResourceState::Closed => RegisterState::Failed {
            retry_wait: None,
            error: "Closed".to_owned(),
        },
    })
}

pub async fn convert_token_to_uuid(
    state: &Arc<IMClient>,
    handle: String,
    token: Vec<u8>,
) -> anyhow::Result<String> {
    let uuid = state.identity.token_to_uuid(&handle, &token).await?;
    Ok(uuid)
}

pub async fn get_sms_targets(
    state: &Arc<IMClient>,
    handle: String,
    refresh: bool,
) -> anyhow::Result<Vec<PrivateDeviceInfo>> {
    let targets = state.identity.get_sms_targets(&handle, refresh).await?;
    Ok(targets)
}
