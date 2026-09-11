#[cfg(target_os = "windows")]
use crate::windows_secret_storage::{open_windows_keystore, replace_file_without_backup};
use anyhow::anyhow;
use async_recursion::async_recursion;
use base64::prelude::*;
pub use broadcast::Receiver;
use flutter_rust_bridge::{frb, DartFnFuture, IntoDart, JoinHandle};
#[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
use keystore::software::SoftwareEncryptor;
#[cfg(not(target_os = "android"))]
use keystore::software::SoftwareKeystore;
use keystore::{
    init_keystore, keystore, try_init_keystore, AesKeystoreKey, EcCurve, EcKeystoreKey,
    EncryptMode, KeystoreAccessRules, KeystoreDigest, KeystoreEncryptKey, KeystoreError,
    KeystorePadding, KeystorePublicKey, RsaKey,
};
use log::{debug, error, info, warn};
pub use mpsc::Sender;
use openssl::{ec::EcKey as OpenSslEcKey, rsa::Rsa as OpenSslRsa};
pub use plist::Value;
use plist::{Data, Dictionary};
use prost::Message as prostMessage;
use rand::Rng;
#[cfg(any(target_os = "android", target_os = "windows"))]
use rustpush::cloudkit_operation_gate::try_acquire_cloudkit_operation;
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
#[cfg(any(target_os = "android", target_os = "windows"))]
use rustpush::CloudKitReadAuthenticationRevoker;
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
pub use rustpush::{default_provider, ArcAnisetteClient, DefaultAnisetteProvider, LoginClientInfo};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
#[cfg(any(target_os = "android", target_os = "windows"))]
use std::fs::OpenOptions;
use std::io::Seek;
pub use std::path::PathBuf;
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

#[cfg(target_os = "windows")]
static WINDOWS_PROTECTED_KEYSTORE_PROFILE: OnceLock<PathBuf> = OnceLock::new();
#[cfg(target_os = "windows")]
static WINDOWS_PROTECTED_KEYSTORE_INITIALIZATION: OnceLock<std::sync::Mutex<()>> = OnceLock::new();
#[cfg(target_os = "windows")]
const CLOUD_SYNC_WINDOWS_AUTH_PROBE_MARKER: &str = ".openbubbles-cloud-sync-v2-windows-auth-probe";
#[cfg(target_os = "windows")]
const CLOUD_SYNC_WINDOWS_AUTH_PROBE_MARKER_CONTENTS: &str =
    "openbubbles-cloud-sync-v2-windows-auth-probe:v1";

fn is_cloud_sync_windows_auth_probe_identifier(value: &str) -> bool {
    value.len() == 32
        && value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
}

#[cfg(target_os = "windows")]
fn cloud_sync_windows_auth_probe_lexical_path(
    path: PathBuf,
    unavailable_message: &'static str,
) -> anyhow::Result<PathBuf> {
    if !path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                std::path::Component::CurDir | std::path::Component::ParentDir
            )
        })
    {
        return Err(anyhow!(unavailable_message));
    }
    Ok(path)
}

#[cfg(target_os = "windows")]
fn normalized_cloud_sync_windows_auth_probe_path(path: &std::path::Path) -> Option<String> {
    let path = path.to_str()?.replace('/', "\\");
    let path = if let Some(path) = path.strip_prefix("\\\\?\\UNC\\") {
        format!("\\\\{path}")
    } else {
        path.strip_prefix("\\\\?\\").unwrap_or(&path).to_owned()
    };
    Some(path.trim_end_matches('\\').to_lowercase())
}

#[cfg(target_os = "windows")]
fn cloud_sync_windows_auth_probe_paths_equal(
    left: &std::path::Path,
    right: &std::path::Path,
) -> bool {
    normalized_cloud_sync_windows_auth_probe_path(left)
        .zip(normalized_cloud_sync_windows_auth_probe_path(right))
        .is_some_and(|(left, right)| left == right)
}

#[cfg(target_os = "windows")]
fn ensure_no_cloud_sync_windows_auth_probe_reparse_ancestors(
    path: &std::path::Path,
) -> anyhow::Result<()> {
    use std::os::windows::fs::MetadataExt;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    let mut current = Some(path);
    while let Some(candidate) = current {
        match fs::symlink_metadata(candidate) {
            Ok(metadata) => {
                if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                    return Err(anyhow!(
                        "Cloud Sync Windows authentication probe path contains a reparse point"
                    ));
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(_) => {
                return Err(anyhow!(
                    "Cloud Sync Windows authentication probe path metadata is unavailable"
                ));
            }
        }
        current = candidate.parent();
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn initialize_windows_protected_keystore(directory: &std::path::Path) -> anyhow::Result<()> {
    let canonical_directory = fs::canonicalize(directory)
        .map_err(|_| anyhow!("Windows protected keystore directory is unavailable"))?;
    let _initialization_guard = WINDOWS_PROTECTED_KEYSTORE_INITIALIZATION
        .get_or_init(|| std::sync::Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("Windows protected keystore initialization lock was poisoned"))?;
    if let Some(bound_directory) = WINDOWS_PROTECTED_KEYSTORE_PROFILE.get() {
        if bound_directory == &canonical_directory {
            return Ok(());
        }
        return Err(anyhow!(
            "Windows protected keystore is already bound to another profile"
        ));
    }

    let opened = open_windows_keystore(&canonical_directory.join("keystore.plist"))?;
    let writer = opened.writer;
    try_init_keystore(SoftwareKeystore {
        state: std::sync::RwLock::new(opened.state),
        update_state: Box::new(move |state| {
            writer
                .write_state(state)
                .expect("Windows protected keystore persistence failed");
        }),
        encryptor: opened.encryptor,
    })
    .map_err(|_| anyhow!("A different process-global keystore is already initialized"))?;
    WINDOWS_PROTECTED_KEYSTORE_PROFILE
        .set(canonical_directory)
        .map_err(|_| anyhow!("Windows protected keystore profile binding failed"))?;
    Ok(())
}

pub fn do_first_time_init(path: String) {
    let dir = PathBuf::from_str(&path).unwrap();

    // This dedicated process emits only the Dart allowlisted probe report.
    // Authentication errors must not escape into unrestricted native logs.
    if !windows_findmy_probe_enabled() { init_logger(&dir); }

    #[cfg(target_os = "windows")]
    if let Err(error) = initialize_windows_protected_keystore(&dir) {
        error!("Windows protected keystore initialization failed: {error}");
    }
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

/// Content-free context for making one successful native SendJob completion
/// crash-recoverable before SendConfirm is emitted.
#[derive(Clone)]
pub struct CloudSyncNativeSendReceiptContext {
    pub storage_directory: String,
    pub guid_hash: String,
    pub account_fingerprint: String,
    pub protected_store_identity: String,
    pub native_session_id: String,
    pub source_binding: Option<CloudSyncNativeSendSourceBinding>,
}

impl std::fmt::Debug for CloudSyncNativeSendReceiptContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CloudSyncNativeSendReceiptContext(redacted)")
    }
}

/// A source purpose is not a permission to send or write a CloudKit record.
/// An unset kind in attachment call sites remains attachment-only, never mutation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloudSyncNativeSendSourceKind {
    Attachment,
    Mutation,
}

/// Content-free ownership of an already-staged IDS source. This
/// identifies protected local data, never delivery or CloudKit write authority.
#[derive(Clone)]
pub struct CloudSyncNativeSendSourceBinding {
    pub kind: Option<CloudSyncNativeSendSourceKind>,
    pub source_sha256: String,
    pub protected_reference: String,
    pub lease_reference: String,
    pub payload_sha256: String,
    pub payload_length: u64,
}

impl From<CloudSyncNativeSendSourceBinding>
    for crate::cloud_sync_native_fetch::CloudNativeIdsSendSourceBinding
{
    fn from(source: CloudSyncNativeSendSourceBinding) -> Self {
        Self {
            kind: match source.kind {
                Some(CloudSyncNativeSendSourceKind::Mutation) =>
                    crate::cloud_sync_native_fetch::CloudNativeIdsSendSourceKind::Mutation,
                None | Some(CloudSyncNativeSendSourceKind::Attachment) =>
                    crate::cloud_sync_native_fetch::CloudNativeIdsSendSourceKind::Attachment,
            },
            source_sha256: source.source_sha256,
            protected_reference: source.protected_reference,
            lease_reference: source.lease_reference,
            payload_sha256: source.payload_sha256,
            payload_length: source.payload_length,
        }
    }
}

impl From<crate::cloud_sync_native_fetch::CloudNativeIdsSendSourceBinding>
    for CloudSyncNativeSendSourceBinding
{
    fn from(source: crate::cloud_sync_native_fetch::CloudNativeIdsSendSourceBinding) -> Self {
        Self {
            kind: match source.kind {
                crate::cloud_sync_native_fetch::CloudNativeIdsSendSourceKind::Mutation =>
                    Some(CloudSyncNativeSendSourceKind::Mutation),
                crate::cloud_sync_native_fetch::CloudNativeIdsSendSourceKind::Attachment => None,
            },
            source_sha256: source.source_sha256,
            protected_reference: source.protected_reference,
            lease_reference: source.lease_reference,
            payload_sha256: source.payload_sha256,
            payload_length: source.payload_length,
        }
    }
}

/// Opaque durable receipt identity plus the two content-free values needed to
/// match and acknowledge exactly the protected native record.
#[derive(Clone)]
pub struct CloudSyncNativeSendReceipt {
    pub receipt_id: String,
    pub guid_hash: String,
    pub native_session_id: String,
    pub source_binding: Option<CloudSyncNativeSendSourceBinding>,
    /// Actual native-validated mutation wire time, never receipt arrival time.
    /// Historical receipts remain valid delivery evidence with unknown time.
    pub prepared_sent_timestamp_ms: Option<u64>,
}

pub struct CloudSyncNativeSendReceiptPage {
    pub receipts: Vec<CloudSyncNativeSendReceipt>,
    pub next_cursor: Option<String>,
}

fn cloud_sync_local_send_guid_hash(stable_guid: &str) -> String {
    let encoded = serde_json::to_vec(&["cloud-sync-local-send-guid-v1", stable_guid])
        .expect("static string arrays serialize");
    Sha256::digest(encoded)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn persist_cloud_sync_native_send_receipt(
    context: CloudSyncNativeSendReceiptContext,
    stable_guid: &str,
    prepared_sent_timestamp_ms: Option<u64>,
) -> anyhow::Result<CloudSyncNativeSendReceipt> {
    if cloud_sync_local_send_guid_hash(stable_guid) != context.guid_hash {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    let mutation = context.source_binding.as_ref().is_some_and(|source|
        source.kind == Some(CloudSyncNativeSendSourceKind::Mutation));
    if mutation != prepared_sent_timestamp_ms.is_some()
        || prepared_sent_timestamp_ms.is_some_and(|time| time == 0 || time > i64::MAX as u64)
    {
        return Err(anyhow!("cloud_sync_native_mutation_prepared_time_invalid"));
    }
    let receipt = crate::cloud_sync_native_fetch::cloud_sync_persist_ids_send_receipt(
        PathBuf::from(context.storage_directory),
        crate::cloud_sync_native_fetch::CloudNativeIdsSendReceipt {
            guid_hash: context.guid_hash,
            account_fingerprint: context.account_fingerprint,
            protected_store_identity: context.protected_store_identity,
            native_session_id: context.native_session_id,
            source_binding: context.source_binding.map(Into::into),
            prepared_sent_timestamp_ms,
        },
    )
    .map_err(|_| anyhow!("cloud_sync_native_send_receipt_persist_failed"))?;
    Ok(CloudSyncNativeSendReceipt {
        receipt_id: receipt.receipt_id,
        guid_hash: receipt.guid_hash,
        native_session_id: receipt.native_session_id,
        source_binding: receipt.source_binding.map(Into::into),
        prepared_sent_timestamp_ms: receipt.prepared_sent_timestamp_ms,
    })
}

pub async fn cloud_sync_replay_native_send_receipts(
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    after_receipt_id: Option<String>,
) -> anyhow::Result<CloudSyncNativeSendReceiptPage> {
    crate::cloud_sync_native_fetch::cloud_sync_replay_ids_send_receipts(
        PathBuf::from(storage_directory),
        &expected_account_fingerprint,
        &expected_protected_store_identity,
        after_receipt_id.as_deref(),
    )
    .map(|page| CloudSyncNativeSendReceiptPage {
        receipts: page
            .receipts
            .into_iter()
            .map(|receipt| CloudSyncNativeSendReceipt {
                receipt_id: receipt.receipt_id,
                guid_hash: receipt.guid_hash,
                native_session_id: receipt.native_session_id,
                source_binding: receipt.source_binding.map(Into::into),
                prepared_sent_timestamp_ms: receipt.prepared_sent_timestamp_ms,
            })
            .collect(),
        next_cursor: page.next_cursor,
    })
    .map_err(|_| anyhow!("cloud_sync_native_send_receipt_replay_failed"))
}

#[frb(sync)]
pub fn cloud_sync_acknowledge_native_send_receipt(
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    receipt: CloudSyncNativeSendReceipt,
) -> anyhow::Result<()> {
    crate::cloud_sync_native_fetch::cloud_sync_acknowledge_ids_send_receipt(
        PathBuf::from(storage_directory),
        &crate::cloud_sync_native_fetch::CloudNativeIdsSendReceiptReplay {
            receipt_id: receipt.receipt_id,
            guid_hash: receipt.guid_hash,
            native_session_id: receipt.native_session_id,
            source_binding: receipt.source_binding.map(Into::into),
            prepared_sent_timestamp_ms: receipt.prepared_sent_timestamp_ms,
        },
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    )
    .map_err(|_| anyhow!("cloud_sync_native_send_receipt_acknowledge_failed"))
}

const CLOUD_SYNC_READ_AUTH_WARM_TIMEOUT: Duration = Duration::from_secs(30);

#[frb(ignore)]
fn cloud_sync_require_source_context_auth(
    context: &CloudSyncNativeSendReceiptContext,
    auth: &CloudSyncNativeAuthMetadata,
) -> anyhow::Result<()> {
    if auth.account_fingerprint != context.account_fingerprint
        || auth.protected_store_identity != context.protected_store_identity
        || auth.native_session_id != context.native_session_id
    {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    Ok(())
}

/// Restores only the exact committed local source for an authenticated retry.
/// No Apple request, upload or send is performed. The caller still validates
/// its current local body/route and journal before handing this value to IDS.
pub async fn cloud_sync_restore_ids_attachment_source(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
) -> anyhow::Result<MessageInst> {
    let auth = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    let message = cloud_sync_restore_attachment_source_bound(&context, &auth)?;
    let after = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &after)?;
    Ok(message)
}

#[frb(ignore)]
fn cloud_sync_restore_attachment_source_bound(
    context: &CloudSyncNativeSendReceiptContext,
    auth: &CloudSyncNativeAuthMetadata,
) -> anyhow::Result<MessageInst> {
    let envelope = cloud_sync_open_attachment_source_bound(context, auth)?;
    crate::cloud_sync_ids_attachment_source::restore_ids_attachment_message(&envelope)
        .map_err(|_| anyhow!("cloud_sync_native_attachment_source_invalid"))
}

#[frb(ignore)]
fn cloud_sync_open_attachment_source_bound(
    context: &CloudSyncNativeSendReceiptContext,
    auth: &CloudSyncNativeAuthMetadata,
) -> anyhow::Result<Vec<u8>> {
    cloud_sync_require_source_context_auth(context, auth)?;
    let binding = context.source_binding.as_ref()
        .ok_or_else(|| anyhow!("cloud_sync_native_attachment_source_unavailable"))?;
    if binding.kind == Some(CloudSyncNativeSendSourceKind::Mutation) {
        return Err(anyhow!("cloud_sync_native_attachment_source_invalid"));
    }
    let identity = crate::cloud_sync_protector::protected_store_identity(
        context.storage_directory.clone(),
    ).map_err(|_| anyhow!("cloud_sync_native_attachment_source_unavailable"))?;
    if identity != context.protected_store_identity {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    let stage = crate::cloud_sync_ids_attachment_source::NativeIdsAttachmentSourceStage {
        protected_reference: binding.protected_reference.clone(),
        lease_reference: binding.lease_reference.clone(),
        payload_sha256: binding.payload_sha256.clone(),
        payload_length: binding.payload_length,
    };
    let envelope = crate::cloud_sync_ids_attachment_source::open_staged_source_envelope(
        PathBuf::from(&context.storage_directory), context.account_fingerprint.clone(),
        &binding.source_sha256, &stage,
    ).map_err(|_| anyhow!("cloud_sync_native_attachment_source_unavailable"))?;
    let message = crate::cloud_sync_ids_attachment_source::restore_ids_attachment_message(&envelope)
        .map_err(|_| anyhow!("cloud_sync_native_attachment_source_invalid"))?;
    if cloud_sync_local_send_guid_hash(&message.id) != context.guid_hash {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    Ok(envelope)
}

/// Identity-only inventory of the original protected IDS body. The lookup is
/// performed before allocating a randomized upload plan. Local reflection may
/// rename attachments; the original source GUID still selects the same bytes.
/// This contains no message text, MMCS credentials, or attachment contents.
#[frb(non_opaque)]
pub struct CloudSyncAttachmentSourceEntry {
    pub original_attachment_guid: String,
    pub reflected_attachment_guid: String,
    pub logical_entity_key_hash: String,
}

impl std::fmt::Debug for CloudSyncAttachmentSourceEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CloudSyncAttachmentSourceEntry(redacted)")
    }
}

/// Local protected-source inspection only. Caller holds the same interlock
/// and protected-store exclusion used by preparation. This does not warm an
/// Apple container, allocate an upload plan, or perform a remote operation.
pub async fn cloud_sync_inspect_attachment_sources(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
) -> anyhow::Result<Vec<CloudSyncAttachmentSourceEntry>> {
    let auth = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    let inventory = cloud_sync_inspect_attachment_sources_bound(&context, &auth)?;
    let after = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &after)?;
    Ok(inventory)
}

#[frb(ignore)]
fn cloud_sync_inspect_attachment_sources_bound(
    context: &CloudSyncNativeSendReceiptContext,
    auth: &CloudSyncNativeAuthMetadata,
) -> anyhow::Result<Vec<CloudSyncAttachmentSourceEntry>> {
    let encoded = cloud_sync_open_attachment_source_bound(context, auth)?;
    let decoded = crate::cloud_sync_ids_attachment_source::decode_ids_attachment_source(&encoded)
        .map_err(|_| anyhow!("cloud_sync_native_attachment_source_invalid"))?;
    let projection = crate::cloud_sync_attachment_parent::project_parent_attributed_body(&decoded)
        .map_err(|_| anyhow!("cloud_sync_native_attachment_parent_invalid"))?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        context.storage_directory.clone(),
    ).map_err(|_| anyhow!("cloud_sync_native_attachment_source_unavailable"))?;
    projection.links.into_iter().map(|link| {
        let logical = hasher.canonical_attachment_key_hash(&link.apple_guid)
            .map_err(|_| anyhow!("cloud_sync_native_attachment_parent_invalid"))?;
        Ok(CloudSyncAttachmentSourceEntry {
            original_attachment_guid: link.original_guid,
            reflected_attachment_guid: link.local_guid,
            logical_entity_key_hash: logical.value().to_owned(),
        })
    }).collect()
}

/// Stages the provided native IDS attachment value without sending anything or
/// touching Apple. Caller must journal ownership and commit the lease under
/// the protected-store exclusive lock before passing this binding to send().
pub async fn cloud_sync_stage_ids_attachment_source(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
    local_source_sha256: String,
    message: MessageInst,
    attachment_guids: Vec<String>,
) -> anyhow::Result<CloudSyncNativeSendSourceBinding> {
    if context.source_binding.is_some()
        || cloud_sync_local_send_guid_hash(&message.id) != context.guid_hash
    {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    let auth = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &auth)?;
    let staged = crate::cloud_sync_ids_attachment_source::stage_ids_attachment_source(
        PathBuf::from(context.storage_directory), context.account_fingerprint,
        &local_source_sha256, &message, &attachment_guids,
    ).map_err(|_| anyhow!("cloud_sync_native_attachment_source_stage_failed"))?;
    Ok(CloudSyncNativeSendSourceBinding {
        kind: None,
        source_sha256: local_source_sha256,
        protected_reference: staged.protected_reference,
        lease_reference: staged.lease_reference,
        payload_sha256: staged.payload_sha256,
        payload_length: staged.payload_length,
    })
}

/// Stage an edit/unsend's exact original IDS request. The caller must adopt the
/// binding in its distinct mutation journal and commit its lease before send.
/// Neither a staged source nor a restored request authorizes resubmission.
pub async fn cloud_sync_stage_ids_mutation_source(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
    local_source_sha256: String,
    message: MessageInst,
) -> anyhow::Result<CloudSyncNativeSendSourceBinding> {
    let auth = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_stage_mutation_source_bound(&context, &auth, &local_source_sha256, &message)
}

#[frb(ignore)]
fn cloud_sync_stage_mutation_source_bound(
    context: &CloudSyncNativeSendReceiptContext,
    auth: &CloudSyncNativeAuthMetadata,
    source_sha256: &str,
    message: &MessageInst,
) -> anyhow::Result<CloudSyncNativeSendSourceBinding> {
    cloud_sync_require_source_context_auth(context, auth)?;
    if context.source_binding.is_some()
        || cloud_sync_local_send_guid_hash(&message.id) != context.guid_hash
        || crate::cloud_sync_protector::protected_store_identity(context.storage_directory.clone())
            .map_err(|_| anyhow!("cloud_sync_native_mutation_source_unavailable"))?
            != context.protected_store_identity
    {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    let staged = crate::cloud_sync_ids_mutation_stage::stage_ids_mutation_source(
        PathBuf::from(&context.storage_directory), context.account_fingerprint.clone(),
        source_sha256, message,
    ).map_err(|_| anyhow!("cloud_sync_native_mutation_source_stage_failed"))?;
    Ok(CloudSyncNativeSendSourceBinding {
        kind: Some(CloudSyncNativeSendSourceKind::Mutation),
        source_sha256: source_sha256.to_owned(),
        protected_reference: staged.protected_reference,
        lease_reference: staged.lease_reference,
        payload_sha256: staged.payload_sha256,
        payload_length: staged.payload_length,
    })
}

/// Reopen the original committed request for validation, never reconstruct an
/// edit from the current displayed body. Unknown IDS outcomes stay unknown.
pub async fn cloud_sync_restore_ids_mutation_source(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
) -> anyhow::Result<MessageInst> {
    let auth = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &auth)?;
    let envelope = cloud_sync_open_mutation_source_bound(&context)?;
    let message = crate::cloud_sync_ids_mutation_source::open_mutation_source(&envelope)
        .and_then(|source| source.message())
        .map_err(|_| anyhow!("cloud_sync_native_mutation_source_invalid"))?;
    let after = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &after)?;
    Ok(message)
}

#[frb(ignore)]
fn cloud_sync_open_mutation_source_bound(
    context: &CloudSyncNativeSendReceiptContext,
) -> anyhow::Result<Vec<u8>> {
    let binding = context.source_binding.as_ref()
        .filter(|binding| binding.kind == Some(CloudSyncNativeSendSourceKind::Mutation))
        .ok_or_else(|| anyhow!("cloud_sync_native_mutation_source_unavailable"))?;
    let identity = crate::cloud_sync_protector::protected_store_identity(context.storage_directory.clone())
        .map_err(|_| anyhow!("cloud_sync_native_mutation_source_unavailable"))?;
    if identity != context.protected_store_identity {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    let stage = crate::cloud_sync_ids_mutation_stage::NativeIdsMutationSourceStage {
        protected_reference: binding.protected_reference.clone(),
        lease_reference: binding.lease_reference.clone(),
        payload_sha256: binding.payload_sha256.clone(),
        payload_length: binding.payload_length,
    };
    let envelope = crate::cloud_sync_ids_mutation_stage::open_staged_mutation_source_envelope(
        PathBuf::from(&context.storage_directory), context.account_fingerprint.clone(),
        &binding.source_sha256, &stage,
    ).map_err(|_| anyhow!("cloud_sync_native_mutation_source_unavailable"))?;
    let source = crate::cloud_sync_ids_mutation_source::open_mutation_source(&envelope)
        .map_err(|_| anyhow!("cloud_sync_native_mutation_source_invalid"))?;
    if cloud_sync_local_send_guid_hash(source.mutation_guid()) != context.guid_hash {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    Ok(envelope)
}

/// Protected byte-upload preparation only. This is not an uploaded asset,
/// final-record envelope, IDS confirmation, or permission to send anything.
#[derive(Debug)]
pub struct CloudSyncAttachmentUploadPlanResult {
    pub stage: CloudSyncProtectedOutboundStage,
    pub upload_attempt_id: String,
}

/// Stage one original upload plan from the exact retained IDS source. The
/// caller holds the V2 writer interlock and protected-store exclusion, proves
/// the local intent has a positive IDS receipt, then adopts/commits this plan
/// before any upload. Recovery opens that plan rather than calling this again.
/// File keys, original record name and plaintext never cross back into Dart.
pub async fn cloud_sync_stage_attachment_upload_plan(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
    original_attachment_guid: String,
    source_path: String,
    start_date_ns: i64,
    created_date_ns: i64,
) -> anyhow::Result<CloudSyncAttachmentUploadPlanResult> {
    let auth = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    let encoded = cloud_sync_open_attachment_source_bound(&context, &auth)?;
    let decoded = crate::cloud_sync_ids_attachment_source::decode_ids_attachment_source(&encoded)
        .map_err(|_| anyhow!("cloud_sync_native_attachment_source_invalid"))?;
    let source_binding = context.source_binding.as_ref()
        .ok_or_else(|| anyhow!("cloud_sync_native_attachment_source_unavailable"))?;
    let writer_binding = cloud_messages_client
        .warm_attachment_writer_preparation_lookup_only().await
        .map_err(|error| {
            warn!("Cloud Sync writer preparation failed kind=attachment cause={}",
                cloud_sync_writer_preparation_failure_code(&error));
            log::logger().flush();
            anyhow!("cloud_sync_attachment_preparation_auth_unavailable")
        })?;
    let after_warm = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &after_warm)?;
    cloud_messages_client.validate_writer_preparation_binding(&writer_binding).await
        .map_err(|_| anyhow!("cloud_sync_attachment_preparation_binding_changed"))?;

    // Recreate the native private-zone shape using the exact warmed container's
    // owner, not a Dart-supplied owner or a different read-auth container.
    let record_identifier = cloud_sync_attachment_upload_record_identifier(
        writer_binding.container_scoped_user_id(),
        &Uuid::new_v4().to_string().to_uppercase(),
    )?;
    let path = PathBuf::from(source_path);
    let metadata = fs::symlink_metadata(&path)
        .map_err(|_| anyhow!("cloud_sync_attachment_source_unavailable"))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(anyhow!("cloud_sync_attachment_source_unavailable"));
    }
    let mut source = File::open(path)
        .map_err(|_| anyhow!("cloud_sync_attachment_source_unavailable"))?;
    if !source.metadata().is_ok_and(|value| value.is_file()) {
        return Err(anyhow!("cloud_sync_attachment_source_unavailable"));
    }
    let plan = crate::cloud_sync_attachment_upload::prepare_verified_ids_upload_plan(
        cloud_messages_client, &decoded, source_binding.source_sha256.clone(),
        &original_attachment_guid,
        &crate::cloud_sync_ids_attachment_source::NativeAttachmentMetaTimes {
            start_date_ns, created_date_ns,
        },
        record_identifier, &mut source, std::path::Path::new(&context.storage_directory),
    ).await.map_err(|error| anyhow!("{error}"))?;
    let after_prepare = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &after_prepare)?;
    cloud_messages_client.validate_writer_preparation_binding(&writer_binding).await
        .map_err(|_| anyhow!("cloud_sync_attachment_preparation_binding_changed"))?;
    let upload_attempt_id = plan.upload_attempt_id()
        .map_err(|_| anyhow!("cloud_sync_attachment_preparation_invalid"))?.to_owned();
    let stage = crate::cloud_sync_attachment_upload::stage_attachment_upload(
        PathBuf::from(context.storage_directory), context.account_fingerprint, &plan,
    ).map_err(|_| anyhow!("cloud_sync_attachment_preparation_stage_failed"))?;
    Ok(CloudSyncAttachmentUploadPlanResult {
        stage: CloudSyncProtectedOutboundStage {
            logical_entity_key_hash: stage.logical_entity_key_hash,
            protected_payload_reference: stage.protected_payload_reference,
            payload_sha256: stage.payload_sha256,
            payload_length: stage.payload_length,
            protected_server_record_reference: stage.protected_server_record_reference,
            server_record_id_hash: stage.server_record_id_hash,
            lease_reference: stage.lease_reference,
        },
        upload_attempt_id,
    })
}

#[frb(ignore)]
fn cloud_sync_attachment_upload_record_identifier(
    container_user_id: &str,
    record_name: &str,
) -> anyhow::Result<rustpush::cloudkit_proto::RecordIdentifier> {
    use rustpush::cloudkit_proto::{identifier::Type, Identifier, RecordZoneIdentifier};
    if container_user_id.is_empty() || container_user_id.len() > 4096
        || container_user_id.chars().any(char::is_control)
        || !Uuid::parse_str(record_name).is_ok_and(|id|
            id.get_version() == Some(uuid::Version::Random)
                && id.to_string().to_uppercase() == record_name)
    {
        return Err(anyhow!("cloud_sync_attachment_preparation_binding_invalid"));
    }
    Ok(rustpush::cloudkit::record_identifier(RecordZoneIdentifier {
        value: Some(Identifier {
            name: Some("attachmentManateeZone".to_owned()),
            r#type: Some(Type::RecordZone as i32),
        }),
        owner_identifier: Some(Identifier {
            name: Some(container_user_id.to_owned()),
            r#type: Some(Type::User as i32),
        }),
        environment: None,
    }, record_name))
}

/// Byte-upload owner, separate from a final CloudKit record-save owner. The
/// immutable file, randomized plan, exact client and native permit stay native.
#[frb(opaque)]
pub struct CloudSyncPreparedAttachmentUploadHandle {
    owner: tokio::sync::Mutex<Option<CloudSyncAttachmentUploadOwner>>,
    context: CloudSyncNativeSendReceiptContext,
    receipt_binding: crate::cloud_sync_attachment_upload_receipt::AttachmentUploadReceiptBinding,
    handle_binding_sha256: String,
    reconciliation_binding_sha256: std::sync::OnceLock<String>,
}

impl std::fmt::Debug for CloudSyncPreparedAttachmentUploadHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CloudSyncPreparedAttachmentUploadHandle(redacted)")
    }
}

enum CloudSyncAttachmentUploadOwner {
    Native {
        prepared: rustpush::cloud_messages::CloudMessagesPreparedUploadSubmission<
            DefaultAnisetteProvider, crate::cloud_sync_attachment_source_file::OwnedAttachmentSource>,
        permit: rustpush::cloudkit_operation_gate::CloudKitWriterOperationPermit,
        client: Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
        writer_binding: rustpush::cloud_messages::CloudMessagesWriterPreparationBinding<DefaultAnisetteProvider>,
        plan: crate::cloud_sync_attachment_upload::AttachmentUploadPlan,
        local_operation_id: String,
    },
    #[cfg(test)]
    Test {
        remote_calls: Arc<std::sync::atomic::AtomicUsize>,
        completed: Vec<u8>,
        after_call: Option<Box<dyn FnOnce() + Send>>,
    },
}

// Move the opaque owner into the Dart result, as with prepared record saves.
// Auto-opaque field access would generate a Clone requirement for that owner.
#[frb(non_opaque)]
#[derive(Debug)]
pub struct CloudSyncPreparedAttachmentUploadResult {
    pub handle: CloudSyncPreparedAttachmentUploadHandle,
    pub handle_binding_sha256: String,
    pub upload_attempt_id: String,
}

/// Exactly the fields persisted in CloudSyncAttachmentUploadJournal. Do not
/// require a discarded transient stage length to resume after process death.
#[derive(Clone, Debug)]
pub struct CloudSyncAttachmentUploadPlanReference {
    pub logical_entity_key_hash: String,
    pub protected_payload_reference: String,
    pub payload_sha256: String,
    pub server_record_id_hash: String,
    pub lease_reference: String,
}

/// `Succeeded` means uploaded bytes with a protected receipt, NOT record save
/// or parent-message synchronization. Unknown never grants another upload.
#[derive(Debug)]
pub struct CloudSyncAttachmentUploadConsumeResult {
    pub upload_attempt_id: String,
    pub disposition: CloudSyncOutboundSaveDisposition,
    pub stage: Option<CloudSyncProtectedOutboundStage>,
    pub failure_class: Option<CloudSyncOutboundFailureClass>,
    pub retry_after_seconds: Option<u64>,
}

/// Authenticated native completion evidence, not a record-save receipt. No
/// asset keys, URLs or plaintext cross the bridge. Inspection creates no lease.
#[derive(Debug)]
pub struct CloudSyncAttachmentUploadReceiptEvidence {
    pub upload_attempt_id: String,
    pub plan_payload_sha256: String,
    pub completed_payload_sha256: String,
    pub logical_entity_key_hash: String,
    pub server_record_id_hash: String,
}

fn cloud_sync_open_journaled_upload(context: &CloudSyncNativeSendReceiptContext,
    stage: &CloudSyncAttachmentUploadPlanReference)
    -> anyhow::Result<crate::cloud_sync_attachment_upload::AttachmentUploadPlan> {
    crate::cloud_sync_attachment_upload::open_journaled_attachment_upload(
        PathBuf::from(&context.storage_directory), context.account_fingerprint.clone(),
        &stage.logical_entity_key_hash, &stage.protected_payload_reference,
        &stage.payload_sha256, &stage.server_record_id_hash, &stage.lease_reference,
    ).map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_unavailable"))
}

fn cloud_sync_bridge_stage(stage: crate::cloud_sync_outbound::NativeProtectedOutboundStage)
    -> CloudSyncProtectedOutboundStage {
    CloudSyncProtectedOutboundStage {
        logical_entity_key_hash: stage.logical_entity_key_hash,
        protected_payload_reference: stage.protected_payload_reference,
        payload_sha256: stage.payload_sha256,
        payload_length: stage.payload_length,
        protected_server_record_reference: stage.protected_server_record_reference,
        server_record_id_hash: stage.server_record_id_hash,
        lease_reference: stage.lease_reference,
    }
}

fn cloud_sync_upload_receipt_binding(
    context: &CloudSyncNativeSendReceiptContext,
    stage: &CloudSyncAttachmentUploadPlanReference,
    plan: &crate::cloud_sync_attachment_upload::AttachmentUploadPlan,
) -> anyhow::Result<crate::cloud_sync_attachment_upload_receipt::AttachmentUploadReceiptBinding> {
    Ok(crate::cloud_sync_attachment_upload_receipt::AttachmentUploadReceiptBinding {
        account_fingerprint: context.account_fingerprint.clone(),
        protected_store_identity: context.protected_store_identity.clone(),
        plan_payload_sha256: stage.payload_sha256.clone(),
        upload_attempt_id: plan.upload_attempt_id()
            .map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?.to_owned(),
    })
}

/// Reopens the adopted original plan; does not upload. Caller must retain the
/// protected-store exclusion and V2 interlock, and durably begin the same
/// journal attempt before calling consume under the mutation guard.
pub async fn cloud_sync_prepare_attachment_upload(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
    plan_stage: CloudSyncAttachmentUploadPlanReference,
    original_attachment_guid: String,
    source_path: String,
    request_timeout_seconds: u64,
) -> anyhow::Result<CloudSyncPreparedAttachmentUploadResult> {
    if !(1..=300).contains(&request_timeout_seconds) {
        return Err(anyhow!("cloud_sync_attachment_upload_timeout_invalid"));
    }
    let auth = cloud_sync_capture_auth_snapshot(cloud_messages_client, context.storage_directory.clone())
        .await.map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
    let encoded = cloud_sync_open_attachment_source_bound(&context, &auth)?;
    let decoded = crate::cloud_sync_ids_attachment_source::decode_ids_attachment_source(&encoded)
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_source_invalid"))?;
    let source_binding = context.source_binding.as_ref()
        .ok_or_else(|| anyhow!("cloud_sync_attachment_upload_source_missing"))?;
    let plan = cloud_sync_open_journaled_upload(&context, &plan_stage)?;
    let receipt_binding = cloud_sync_upload_receipt_binding(&context, &plan_stage, &plan)?;
    let writer_binding = cloud_messages_client.warm_attachment_writer_preparation_lookup_only()
        .await.map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
    let record = cloud_sync_attachment_upload_record_identifier(
        writer_binding.container_scoped_user_id(),
        plan.record_name().map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?,
    )?;
    let path = PathBuf::from(source_path);
    let metadata = fs::symlink_metadata(&path)
        .map_err(|_| anyhow!("cloud_sync_attachment_source_unavailable"))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(anyhow!("cloud_sync_attachment_source_unavailable"));
    }
    let mut source = File::open(path).map_err(|_| anyhow!("cloud_sync_attachment_source_unavailable"))?;
    if !source.metadata().is_ok_and(|meta| meta.is_file()) {
        return Err(anyhow!("cloud_sync_attachment_source_unavailable"));
    }
    let local_operation_id = format!("upload1:{}", plan_stage.payload_sha256);
    let permit = rustpush::cloudkit_operation_gate::acquire_cloudkit_writer_operation().await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_writer_busy"))?;
    let prepared = permit.run(plan.prepare_verified_submission(
        cloud_messages_client, &writer_binding, &decoded, &source_binding.source_sha256,
        &original_attachment_guid, &record, local_operation_id.clone(), &mut source,
        std::path::Path::new(&context.storage_directory), Duration::from_secs(request_timeout_seconds),
    )).await.map_err(|_| anyhow!("cloud_sync_attachment_upload_prepare_failed"))?;
    let after = cloud_sync_capture_auth_snapshot(cloud_messages_client, context.storage_directory.clone())
        .await.map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &after)?;
    cloud_messages_client.validate_writer_preparation_binding(&writer_binding).await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_binding_changed"))?;
    let handle_binding_sha256 = cloud_sync_new_prepared_handle_binding_sha256();
    let upload_attempt_id = receipt_binding.upload_attempt_id.clone();
    Ok(CloudSyncPreparedAttachmentUploadResult {
        handle: CloudSyncPreparedAttachmentUploadHandle {
            owner: tokio::sync::Mutex::new(Some(CloudSyncAttachmentUploadOwner::Native {
                prepared, permit, client: cloud_messages_client.clone(), writer_binding, plan,
                local_operation_id,
            })),
            context, receipt_binding,
            handle_binding_sha256: handle_binding_sha256.clone(),
            reconciliation_binding_sha256: std::sync::OnceLock::new(),
        },
        handle_binding_sha256, upload_attempt_id,
    })
}

fn cloud_sync_upload_capability_valid(handle: &CloudSyncPreparedAttachmentUploadHandle, token: &str) -> bool {
    cloud_sync_bound_mutation_capability_is_valid(
        &handle.context.storage_directory, &handle.context.account_fingerprint,
        &handle.context.protected_store_identity, &handle.handle_binding_sha256,
        &handle.reconciliation_binding_sha256, token,
    )
}

/// The journal starts before this call. Native exclusive claim is an additional
/// cross-process barrier: a second prepared handle cannot repeat that attempt.
/// A completed receipt is encrypted and made durable before staging/returning.
pub async fn cloud_sync_consume_prepared_attachment_upload(
    handle: &CloudSyncPreparedAttachmentUploadHandle,
    mutation_capability_token: String,
) -> anyhow::Result<CloudSyncAttachmentUploadConsumeResult> {
    if !cloud_sync_upload_capability_valid(handle, &mutation_capability_token) {
        return Err(anyhow!("cloud_sync_attachment_upload_capability_invalid"));
    }
    let owner = {
        let mut guard = handle.owner.lock().await;
        let owner = guard.as_ref().ok_or_else(|| anyhow!("cloud_sync_attachment_upload_already_consumed"))?;
        if let CloudSyncAttachmentUploadOwner::Native { client, writer_binding, .. } = owner {
            let auth = cloud_sync_capture_auth_snapshot(client, handle.context.storage_directory.clone()).await
                .map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
            cloud_sync_require_source_context_auth(&handle.context, &auth)?;
            client.validate_writer_preparation_binding(writer_binding).await
                .map_err(|_| anyhow!("cloud_sync_attachment_upload_binding_changed"))?;
        }
        // Recheck after authentication awaits, before persisting a claim.
        if !cloud_sync_upload_capability_valid(handle, &mutation_capability_token) {
            return Err(anyhow!("cloud_sync_attachment_upload_capability_invalid"));
        }
        crate::cloud_sync_attachment_upload_receipt::claim_attempt(
            std::path::Path::new(&handle.context.storage_directory), &handle.receipt_binding,
        ).map_err(|_| anyhow!("cloud_sync_attachment_upload_attempt_unavailable"))?;
        if !cloud_sync_upload_capability_valid(handle, &mutation_capability_token) {
            // The durable claim remains conservative after this interruption,
            // but its file owner must not survive as another usable handle.
            guard.take();
            return Err(anyhow!("cloud_sync_attachment_upload_capability_changed"));
        }
        guard.take().ok_or_else(|| anyhow!("cloud_sync_attachment_upload_already_consumed"))?
    };
    let mut result = CloudSyncAttachmentUploadConsumeResult {
        upload_attempt_id: handle.receipt_binding.upload_attempt_id.clone(),
        disposition: CloudSyncOutboundSaveDisposition::UnknownOutcome, stage: None,
        failure_class: None, retry_after_seconds: None,
    };
    let active_client = match &owner {
        CloudSyncAttachmentUploadOwner::Native { client, .. } => Some(client.clone()),
        #[cfg(test)]
        CloudSyncAttachmentUploadOwner::Test { .. } => None,
    };
    let completed = match owner {
        CloudSyncAttachmentUploadOwner::Native { prepared, permit, client, writer_binding, plan, local_operation_id } => {
            use rustpush::cloud_messages::CloudAttachmentNativeUploadResult as NativeResult;
            let outcome = permit.run(prepared.consume_once(&client, &writer_binding)).await
                .map_err(|_| anyhow!("cloud_sync_attachment_upload_consume_failed"))?;
            if outcome.local_operation_id != local_operation_id || outcome.apple_operation_uuid != result.upload_attempt_id {
                return Err(anyhow!("cloud_sync_attachment_upload_correlation_changed"));
            }
            match outcome.result {
                NativeResult::Uploaded(asset) => {
                    let attachment = plan.complete(asset)
                        .map_err(|_| anyhow!("cloud_sync_attachment_upload_result_invalid"))?;
                    Some(crate::cloud_sync_outbound_attachment::encode_attachment(&attachment,
                        plan.record_name().map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?)
                        .map_err(|_| anyhow!("cloud_sync_attachment_upload_result_invalid"))?)
                },
                NativeResult::Failed { failure_class, retry_after } => {
                    result.disposition = CloudSyncOutboundSaveDisposition::Failed;
                    result.failure_class = failure_class.map(map_cloud_sync_outbound_failure_class);
                    result.retry_after_seconds = retry_after.map(|value| value.as_secs());
                    None
                },
                NativeResult::UnknownOutcome { failure_class, retry_after } => {
                    result.failure_class = failure_class.map(map_cloud_sync_outbound_failure_class);
                    result.retry_after_seconds = retry_after.map(|value| value.as_secs());
                    None
                },
            }
        },
        #[cfg(test)]
        CloudSyncAttachmentUploadOwner::Test { remote_calls, completed, after_call } => {
            remote_calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if let Some(action) = after_call { action(); }
            Some(completed)
        },
    };
    if let Some(encoded) = completed {
        crate::cloud_sync_attachment_upload_receipt::persist_completed(
            std::path::Path::new(&handle.context.storage_directory), &handle.receipt_binding, &encoded,
        ).map_err(|_| anyhow!("cloud_sync_attachment_upload_receipt_unavailable"))?;
        // Preserve the receipt even if the UI timed out/revoked authority while
        // Apple returned success. Recovery will revalidate against its plan.
        if !cloud_sync_upload_capability_valid(handle, &mutation_capability_token) {
            return Err(anyhow!("cloud_sync_attachment_upload_capability_changed"));
        }
        let (attachment, record_name) = crate::cloud_sync_outbound_attachment::decode_attachment_envelope(&encoded)
            .map_err(|_| anyhow!("cloud_sync_attachment_upload_result_invalid"))?;
        result.stage = Some(cloud_sync_bridge_stage(crate::cloud_sync_outbound_attachment::stage_outbound_attachment(
            PathBuf::from(&handle.context.storage_directory), handle.context.account_fingerprint.clone(),
            attachment, &record_name,
        ).map_err(|_| anyhow!("cloud_sync_attachment_upload_result_stage_failed"))?));
        result.disposition = CloudSyncOutboundSaveDisposition::Succeeded;
    }
    if !cloud_sync_upload_capability_valid(handle, &mutation_capability_token) {
        return Err(anyhow!("cloud_sync_attachment_upload_capability_changed"));
    }
    if let Some(client) = active_client {
        let auth = cloud_sync_capture_auth_snapshot(&client, handle.context.storage_directory.clone()).await
            .map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
        cloud_sync_require_source_context_auth(&handle.context, &auth)?;
        // Identity capture may yield while the Dart owner revokes the fence.
        if !cloud_sync_upload_capability_valid(handle, &mutation_capability_token) {
            return Err(anyhow!("cloud_sync_attachment_upload_capability_changed"));
        }
    }
    Ok(result)
}

async fn cloud_sync_load_attachment_upload_completion(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: &CloudSyncNativeSendReceiptContext,
    plan_stage: &CloudSyncAttachmentUploadPlanReference,
) -> anyhow::Result<(crate::cloud_sync_attachment_upload::AttachmentUploadPlan, Option<Vec<u8>>)> {
    let auth = cloud_sync_capture_auth_snapshot(cloud_messages_client, context.storage_directory.clone()).await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
    let encoded_source = cloud_sync_open_attachment_source_bound(context, &auth)?;
    let decoded = crate::cloud_sync_ids_attachment_source::decode_ids_attachment_source(&encoded_source)
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_source_invalid"))?;
    let plan = cloud_sync_open_journaled_upload(context, plan_stage)?;
    plan.validate_parent_source(&decoded.message_guid, &context.source_binding.as_ref()
        .ok_or_else(|| anyhow!("cloud_sync_attachment_upload_source_missing"))?.source_sha256)
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_source_changed"))?;
    let binding = cloud_sync_upload_receipt_binding(context, plan_stage, &plan)?;
    let encoded = plan.recover_completed_receipt(
        std::path::Path::new(&context.storage_directory), &binding,
    ).map_err(|_| anyhow!("cloud_sync_attachment_upload_receipt_unavailable"))?;
    let after = cloud_sync_capture_auth_snapshot(cloud_messages_client, context.storage_directory.clone()).await
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(context, &after)?;
    Ok((plan, encoded))
}

/// No upload, record save, envelope staging or lease creation. This lets the
/// writer verify an already-adopted result without replacing its durable lease.
pub async fn cloud_sync_verify_attachment_upload_receipt(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
    plan_stage: CloudSyncAttachmentUploadPlanReference,
    expected_attempt_id: String,
) -> anyhow::Result<Option<CloudSyncAttachmentUploadReceiptEvidence>> {
    let (plan, encoded) = cloud_sync_load_attachment_upload_completion(
        cloud_messages_client, &context, &plan_stage,
    ).await?;
    if plan.upload_attempt_id().map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))? != expected_attempt_id {
        return Err(anyhow!("cloud_sync_attachment_upload_attempt_changed"));
    }
    Ok(encoded.map(|value| CloudSyncAttachmentUploadReceiptEvidence {
        upload_attempt_id: expected_attempt_id,
        plan_payload_sha256: plan_stage.payload_sha256,
        completed_payload_sha256: format!("{:x}", sha2::Sha256::digest(&value)),
        logical_entity_key_hash: plan_stage.logical_entity_key_hash,
        server_record_id_hash: plan_stage.server_record_id_hash,
    }))
}

/// No network mutation. Reconstructs a lost bridge result from the original
/// native receipt. Use only while the local upload is started/unknown; if Dart
/// already adopted a result, commit/reuse that exact existing lease instead.
pub async fn cloud_sync_recover_attachment_upload(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
    plan_stage: CloudSyncAttachmentUploadPlanReference,
) -> anyhow::Result<Option<CloudSyncProtectedOutboundStage>> {
    let (plan, encoded) = cloud_sync_load_attachment_upload_completion(
        cloud_messages_client, &context, &plan_stage,
    ).await?;
    let Some(encoded) = encoded else { return Ok(None); };
    let attachment = plan.validate_completed_envelope(&encoded)
        .map_err(|_| anyhow!("cloud_sync_attachment_upload_result_invalid"))?;
    Ok(Some(cloud_sync_bridge_stage(crate::cloud_sync_outbound_attachment::stage_outbound_attachment(
        PathBuf::from(context.storage_directory), context.account_fingerprint, attachment,
        plan.record_name().map_err(|_| anyhow!("cloud_sync_attachment_upload_plan_invalid"))?,
    ).map_err(|_| anyhow!("cloud_sync_attachment_upload_result_stage_failed"))?)))
}

#[cfg(test)]
mod cloud_sync_attachment_upload_consume_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    const ATTEMPT: &str = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE1";
    const RECORD: &str = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE2";

    fn completed() -> Vec<u8> {
        use rustpush::{cloud_messages::{AttachmentMeta, CloudAttachment, GZipWrapper},
            cloudkit_proto::{Asset, ProtectionInfo}};
        let attachment = CloudAttachment {
            cm: GZipWrapper(AttachmentMeta {
                guid: "synthetic-guid".to_owned(), version: 1, is_outgoing: true, total_bytes: 7,
                ..Default::default()
            }),
            lqa: Asset {
                signature: Some(vec![4; 21]), reference_signature: Some(vec![1; 21]), size: Some(7),
                protection_info: Some(ProtectionInfo { protection_info: Some(vec![7; 32]), ..Default::default() }),
                record_id: Some(cloud_sync_attachment_upload_record_identifier("fixture-owner", RECORD).unwrap()),
                upload_receipt: Some("synthetic-asset-receipt".to_owned()), ..Default::default()
            },
        };
        crate::cloud_sync_outbound_attachment::encode_attachment(&attachment, RECORD).unwrap()
    }

    fn handle(directory: &std::path::Path, calls: Arc<AtomicUsize>, after_call: Option<Box<dyn FnOnce() + Send>>)
        -> CloudSyncPreparedAttachmentUploadHandle {
        let store_identity = crate::cloud_sync_protector::protected_store_identity(directory.to_string_lossy().into_owned()).unwrap();
        CloudSyncPreparedAttachmentUploadHandle {
            owner: tokio::sync::Mutex::new(Some(CloudSyncAttachmentUploadOwner::Test {
                remote_calls: calls, completed: completed(), after_call,
            })),
            context: CloudSyncNativeSendReceiptContext {
                storage_directory: directory.to_string_lossy().into_owned(),
                guid_hash: "G".repeat(43), account_fingerprint: "A".repeat(43),
                protected_store_identity: store_identity.clone(), native_session_id: "fixture-session".to_owned(), source_binding: None,
            },
            receipt_binding: crate::cloud_sync_attachment_upload_receipt::AttachmentUploadReceiptBinding {
                account_fingerprint: "A".repeat(43), protected_store_identity: store_identity,
                plan_payload_sha256: "a".repeat(64), upload_attempt_id: ATTEMPT.to_owned(),
            },
            handle_binding_sha256: "b".repeat(64), reconciliation_binding_sha256: std::sync::OnceLock::new(),
        }
    }

    fn arm(handle: &CloudSyncPreparedAttachmentUploadHandle, token: &str) -> PathBuf {
        let path = PathBuf::from(&handle.context.storage_directory).join(CLOUD_SYNC_WRITER_MUTATION_FENCE_FILE);
        fs::write(&path, serde_json::to_vec(&serde_json::json!({
            "accountFingerprint": handle.context.account_fingerprint,
            "capabilitySha256": format!("{:x}", Sha256::digest(token.as_bytes())),
            "container": "com.apple.messages.cloud", "database": "private", "epoch": 1,
            "owner": "v2", "preparedHandleBindingSha256": handle.handle_binding_sha256,
            "protectedStoreIdentity": handle.context.protected_store_identity,
            "reconciliationBindingSha256": "c".repeat(64), "version": 3,
        })).unwrap()).unwrap();
        path
    }

    #[tokio::test]
    async fn wrong_capability_does_not_claim_or_consume_upload() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let owner = handle(dir.path(), calls.clone(), None);
        arm(&owner, &"d".repeat(64));
        assert!(cloud_sync_consume_prepared_attachment_upload(&owner, "e".repeat(64)).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        let result = cloud_sync_consume_prepared_attachment_upload(&owner, "d".repeat(64)).await.unwrap();
        assert_eq!(result.disposition, CloudSyncOutboundSaveDisposition::Succeeded);
        assert!(result.stage.is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn upload_has_one_consumption_and_durable_completed_receipt() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let owner = handle(dir.path(), calls.clone(), None);
        arm(&owner, &"d".repeat(64));
        let (first, second) = tokio::join!(
            cloud_sync_consume_prepared_attachment_upload(&owner, "d".repeat(64)),
            cloud_sync_consume_prepared_attachment_upload(&owner, "d".repeat(64)),
        );
        assert_ne!(first.is_ok(), second.is_ok());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let recovered = crate::cloud_sync_attachment_upload_receipt::recover_completed(dir.path(), &owner.receipt_binding).unwrap().unwrap();
        assert_eq!(recovered, completed());
        // Reconstructed native owners after a restart cannot replay the claim.
        let reopened = handle(dir.path(), calls.clone(), None);
        arm(&reopened, &"d".repeat(64));
        assert!(cloud_sync_consume_prepared_attachment_upload(&reopened, "d".repeat(64)).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn revoked_fence_after_upload_preserves_receipt_for_recovery() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(CLOUD_SYNC_WRITER_MUTATION_FENCE_FILE);
        let calls = Arc::new(AtomicUsize::new(0));
        let owner = handle(dir.path(), calls.clone(), Some(Box::new(move || { fs::remove_file(path).unwrap(); })));
        arm(&owner, &"d".repeat(64));
        assert!(cloud_sync_consume_prepared_attachment_upload(&owner, "d".repeat(64)).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(crate::cloud_sync_attachment_upload_receipt::recover_completed(dir.path(), &owner.receipt_binding).unwrap().unwrap(), completed());
    }

    #[tokio::test]
    async fn receipt_storage_failure_prevents_any_remote_upload() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let owner = handle(dir.path(), calls.clone(), None);
        arm(&owner, &"d".repeat(64));
        fs::write(dir.path().join("cloud_sync_v2_native_store"), b"not a directory").unwrap();
        assert!(cloud_sync_consume_prepared_attachment_upload(&owner, "d".repeat(64)).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }
}

#[cfg(test)]
mod cloud_sync_attachment_upload_staging_tests {
    use super::*;

    const RECORD: &str = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";

    #[test]
    fn upload_record_uses_exact_warmed_owner_and_attachment_zone() {
        use rustpush::cloudkit_proto::identifier::Type;
        let first = cloud_sync_attachment_upload_record_identifier("fixture-owner", RECORD).unwrap();
        let zone = first.zone_identifier.as_ref().unwrap();
        assert_eq!(first.value.as_ref().unwrap().name.as_deref(), Some(RECORD));
        assert_eq!(first.value.as_ref().unwrap().r#type, Some(Type::Record as i32));
        assert_eq!(zone.value.as_ref().unwrap().name.as_deref(), Some("attachmentManateeZone"));
        assert_eq!(zone.value.as_ref().unwrap().r#type, Some(Type::RecordZone as i32));
        assert_eq!(zone.owner_identifier.as_ref().unwrap().name.as_deref(), Some("fixture-owner"));
        assert_eq!(zone.owner_identifier.as_ref().unwrap().r#type, Some(Type::User as i32));
        assert!(zone.environment.is_none());
        let other = cloud_sync_attachment_upload_record_identifier("other-owner", RECORD).unwrap();
        assert_ne!(first, other);
    }

    #[test]
    fn upload_record_rejects_missing_owner_and_nonallocated_names() {
        for owner in ["".to_owned(), "x".repeat(4097), "owner\n".to_owned()] {
            assert!(cloud_sync_attachment_upload_record_identifier(&owner, RECORD).is_err());
        }
        for name in ["".to_owned(), RECORD.to_lowercase(), "x".repeat(64),
            "AAAAAAAA-BBBB-1CCC-8DDD-EEEEEEEEEEEE".to_owned()] {
            assert!(cloud_sync_attachment_upload_record_identifier("fixture-owner", &name).is_err());
        }
    }

    #[test]
    fn source_open_rejects_auth_change_before_touching_storage() {
        let context = CloudSyncNativeSendReceiptContext {
            storage_directory: "must-not-open-this-directory".to_owned(),
            guid_hash: "a".repeat(64),
            account_fingerprint: "A".repeat(43),
            protected_store_identity: "S".repeat(43),
            native_session_id: "N".repeat(43),
            source_binding: None,
        };
        for auth in [
            CloudSyncNativeAuthMetadata { account_fingerprint: "B".repeat(43), protected_store_identity: "S".repeat(43), native_session_id: "N".repeat(43) },
            CloudSyncNativeAuthMetadata { account_fingerprint: "A".repeat(43), protected_store_identity: "T".repeat(43), native_session_id: "N".repeat(43) },
            CloudSyncNativeAuthMetadata { account_fingerprint: "A".repeat(43), protected_store_identity: "S".repeat(43), native_session_id: "M".repeat(43) },
        ] {
            let err = cloud_sync_open_attachment_source_bound(&context, &auth).unwrap_err();
            assert_eq!(err.to_string(), "cloud_sync_native_send_receipt_context_invalid");
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloudSyncReadAuthWarmFailure {
    WriterPauseScope,
    MessagesContainer,
    KeychainContainer,
    SecurityContainer,
    PcsZones,
    CloudKitToken,
    CredentialsUnavailable,
    CredentialsRejected,
    Transport,
}

impl CloudSyncReadAuthWarmFailure {
    fn safe_code(self) -> &'static str {
        match self {
            Self::WriterPauseScope => "cloud_sync_native_auth_writer_pause_scope_failed",
            Self::MessagesContainer => "cloud_sync_native_auth_messages_container_failed",
            Self::KeychainContainer => "cloud_sync_native_auth_keychain_container_failed",
            Self::SecurityContainer => "cloud_sync_native_auth_security_container_failed",
            Self::PcsZones => "cloud_sync_native_auth_pcs_zones_failed",
            Self::CloudKitToken => "cloud_sync_native_auth_cloudkit_token_failed",
            Self::CredentialsUnavailable => "cloud_sync_native_auth_credentials_unavailable",
            Self::CredentialsRejected => "cloud_sync_native_auth_credentials_rejected",
            Self::Transport => "cloud_sync_native_auth_transport_failed",
        }
    }
}

fn classify_cloud_sync_read_authentication_failure(
    error: PushError,
    fallback: CloudSyncReadAuthWarmFailure,
) -> CloudSyncReadAuthWarmFailure {
    match error {
        PushError::CloudKitWarmAuthenticationRequired | PushError::TokenMissing => {
            CloudSyncReadAuthWarmFailure::CredentialsUnavailable
        }
        PushError::UnauthorizedAccountError
        | PushError::MobileMeError(_, _)
        | PushError::DelegateLoginFailed(_, _, _)
        | PushError::AuthError(_) => CloudSyncReadAuthWarmFailure::CredentialsRejected,
        PushError::RequestError(_) => CloudSyncReadAuthWarmFailure::Transport,
        _ => fallback,
    }
}

fn cloud_sync_read_authentication_refresh_error(error: PushError) -> anyhow::Error {
    let safe_code = match error {
        PushError::CloudKitWarmAuthenticationRequired | PushError::TokenMissing => {
            "cloud_sync_native_auth_refresh_session_missing"
        }
        PushError::UnauthorizedAccountError
        | PushError::MobileMeError(_, _)
        | PushError::DelegateLoginFailed(_, _, _)
        | PushError::AuthError(_) => "cloud_sync_native_auth_refresh_credentials_rejected",
        PushError::RequestError(_) | PushError::AnisetteError(_) => {
            "cloud_sync_native_auth_refresh_transport_failed"
        }
        _ => "cloud_sync_native_auth_refresh_failed",
    };
    anyhow!(safe_code)
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
                .map_err(|error| {
                    classify_cloud_sync_read_authentication_failure(
                        error,
                        CloudSyncReadAuthWarmFailure::MessagesContainer,
                    )
                })?;
            cloud_messages_client
                .keychain
                .get_container_for_read_authentication(permit)
                .await
                .map_err(|error| {
                    classify_cloud_sync_read_authentication_failure(
                        error,
                        CloudSyncReadAuthWarmFailure::KeychainContainer,
                    )
                })?;
            cloud_messages_client
                .keychain
                .get_security_container_for_read_authentication(permit)
                .await
                .map_err(|error| {
                    classify_cloud_sync_read_authentication_failure(
                        error,
                        CloudSyncReadAuthWarmFailure::SecurityContainer,
                    )
                })?;
            cloud_messages_client
                .warm_semantic_read_zone_encryption_configs(permit)
                .await
                .map_err(|error| {
                    classify_cloud_sync_read_authentication_failure(
                        error,
                        CloudSyncReadAuthWarmFailure::PcsZones,
                    )
                })?;
        } else {
            cloud_messages_client
                .get_container()
                .await
                .map_err(|error| {
                    classify_cloud_sync_read_authentication_failure(
                        error,
                        CloudSyncReadAuthWarmFailure::MessagesContainer,
                    )
                })?;
            cloud_messages_client
                .keychain
                .get_container()
                .await
                .map_err(|error| {
                    classify_cloud_sync_read_authentication_failure(
                        error,
                        CloudSyncReadAuthWarmFailure::KeychainContainer,
                    )
                })?;
            cloud_messages_client
                .keychain
                .get_security_container()
                .await
                .map_err(|error| {
                    classify_cloud_sync_read_authentication_failure(
                        error,
                        CloudSyncReadAuthWarmFailure::SecurityContainer,
                    )
                })?;
        }
        if !cloud_messages_client
            .client
            .token_provider
            .cloudkit_read_authentication_is_warm()
            .await
        {
            return Err(CloudSyncReadAuthWarmFailure::CloudKitToken);
        }
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
        assert_eq!(
            CloudSyncReadAuthWarmFailure::PcsZones.safe_code(),
            "cloud_sync_native_auth_pcs_zones_failed"
        );
    }

    #[test]
    fn semantic_pcs_warmup_is_inside_the_writer_pause_permit_branch() {
        let source = include_str!("api.rs");
        let function_start = source
            .find("async fn cloud_sync_warm_read_authentication_inner")
            .expect("read-authentication warmup");
        let function_end = source[function_start..]
            .find("\n#[cfg(test)]")
            .expect("following test module");
        let function = &source[function_start..function_start + function_end];
        let permit_branch_start = function
            .find("if let Some(permit) = read_authentication_permit")
            .expect("writer-pause permit branch");
        let general_branch_start = function[permit_branch_start..]
            .find("} else {")
            .map(|offset| permit_branch_start + offset)
            .expect("general authentication branch");
        let permit_branch = &function[permit_branch_start..general_branch_start];
        let general_branch = &function[general_branch_start..];

        assert!(permit_branch.contains("warm_semantic_read_zone_encryption_configs(permit)"));
        assert!(permit_branch.contains("CloudSyncReadAuthWarmFailure::PcsZones"));
        assert!(!general_branch.contains("warm_semantic_read_zone_encryption_configs"));
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

    #[test]
    fn read_authentication_failures_preserve_only_retry_relevant_safe_classes() {
        assert_eq!(
            classify_cloud_sync_read_authentication_failure(
                PushError::CloudKitWarmAuthenticationRequired,
                CloudSyncReadAuthWarmFailure::MessagesContainer,
            )
            .safe_code(),
            "cloud_sync_native_auth_credentials_unavailable"
        );
        assert_eq!(
            classify_cloud_sync_read_authentication_failure(
                PushError::UnauthorizedAccountError,
                CloudSyncReadAuthWarmFailure::MessagesContainer,
            )
            .safe_code(),
            "cloud_sync_native_auth_credentials_rejected"
        );
        assert_eq!(
            classify_cloud_sync_read_authentication_failure(
                PushError::IoError(std::io::Error::new(
                    ErrorKind::PermissionDenied,
                    "sensitive detail",
                )),
                CloudSyncReadAuthWarmFailure::MessagesContainer,
            )
            .safe_code(),
            "cloud_sync_native_auth_messages_container_failed"
        );
        assert_eq!(
            cloud_sync_read_authentication_refresh_error(PushError::UnauthorizedAccountError)
                .to_string(),
            "cloud_sync_native_auth_refresh_credentials_rejected"
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
    ReadAuthenticationScope,
    NativeAuthUnavailable,
    Unknown,
}

#[derive(Clone)]
pub struct CloudSyncProtectedFailure {
    pub category: CloudSyncProtectedFailureCategory,
    pub safe_code: CloudSyncProtectedSafeCode,
    pub retry_after_seconds: Option<u64>,
    pub protected_reset_proof_reference: Option<String>,
}

impl std::fmt::Debug for CloudSyncProtectedFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CloudSyncProtectedFailure")
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
    MutationCapabilityInvalid,
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
    /// Required only for source-bound attachment parents. Retain the exact
    /// committed source lease through prepare and ambiguous-write recovery.
    pub attachment_parent_context: Option<CloudSyncNativeSendReceiptContext>,
    /// Ephemeral retained-Chat authority, required only for group attachment parents.
    pub attachment_parent_group_proof: Option<CloudSyncAttachmentParentGroupProof>,
}

/// Cached-only decode result, not caller-authored route data or write authority.
/// Reopen from the same pinned journal source after restart or five minutes.
#[frb(opaque)]
#[derive(Clone)]
pub struct CloudSyncAttachmentParentGroupProof {
    storage_directory: String,
    auth: Arc<CloudSyncNativeAuthMetadata>,
    generation: u64,
    source: super::cloud_sync_chat_identity::CloudSyncChatIdentitySourceInput,
    request: crate::cloud_sync_transient_bridge::CloudTransientDecodeRequest,
    route: crate::cloud_sync_canonical_dto::CloudCanonicalChatPayload,
    expires_at: std::time::Instant,
}

impl std::fmt::Debug for CloudSyncAttachmentParentGroupProof {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CloudSyncAttachmentParentGroupProof(redacted)")
    }
}

/// No lookup, keychain sync, projection, lease mutation or write authority.
/// The caller pins current generation/latest applied Chat in its existing
/// adopted binding and retains that source. Release the existing writer pause
/// before staging/preparing a Message; the proof does not own that pause.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_open_attachment_parent_group_proof(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    generation: u64,
    routing_metadata_digest: String,
    source: super::cloud_sync_chat_identity::CloudSyncChatIdentitySourceInput,
) -> anyhow::Result<CloudSyncAttachmentParentGroupProof> {
    use crate::cloud_sync_transient_bridge::{cloud_sync_decode_transient_record_cached_only,
        CloudTransientDecodeOutcome};
    if !is_cloud_sync_hex_digest(&routing_metadata_digest) {
        return Err(anyhow!("cloud_sync_attachment_parent_group_proof_invalid"));
    }
    let permit = acquire_cloudkit_read_authentication(native_writer_pause_token)
        .map_err(|_| anyhow!("cloud_sync_attachment_parent_group_proof_auth"))?;
    let before = cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone()).await
        .map_err(|_| anyhow!("cloud_sync_attachment_parent_group_proof_auth"))?;
    if before.account_fingerprint != expected_account_fingerprint
        || before.protected_store_identity != expected_protected_store_identity
    { return Err(anyhow!("cloud_sync_attachment_parent_group_proof_scope")); }
    let request = cloud_sync_attachment_group_decode_request(&storage_directory, &before, generation, &source)
        .map_err(|_| anyhow!("cloud_sync_attachment_parent_group_proof_invalid"))?;
    let mutation = match cloud_sync_decode_transient_record_cached_only(
        cloud_messages_client, &permit, request.clone(),
    ).await {
        CloudTransientDecodeOutcome::Ready(value) => value,
        _ => return Err(anyhow!("cloud_sync_attachment_parent_group_proof_unavailable")),
    };
    let route = cloud_sync_attachment_group_route(&mutation, generation, &routing_metadata_digest)
        .map_err(|_| anyhow!("cloud_sync_attachment_parent_group_proof_mismatch"))?;
    let after = cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone()).await
        .map_err(|_| anyhow!("cloud_sync_attachment_parent_group_proof_auth"))?;
    if !cloud_sync_auth_identity_remains_exact(&before, &after,
        &expected_account_fingerprint, &expected_protected_store_identity)
    { return Err(anyhow!("cloud_sync_attachment_parent_group_proof_scope")); }
    let proof = CloudSyncAttachmentParentGroupProof {
        storage_directory, auth: Arc::new(after), generation, source, request, route,
        expires_at: std::time::Instant::now() + Duration::from_secs(300),
    };
    // Reopen the exact protected raw record after awaited decoding/auth checks.
    cloud_sync_validate_attachment_group_proof(&proof.storage_directory, &proof.auth, &proof)
        .map_err(|_| anyhow!("cloud_sync_attachment_parent_group_proof_mismatch"))?;
    Ok(proof)
}

#[frb(ignore)]
fn cloud_sync_attachment_group_decode_request(
    storage: &str,
    auth: &CloudSyncNativeAuthMetadata,
    generation: u64,
    source: &super::cloud_sync_chat_identity::CloudSyncChatIdentitySourceInput,
) -> Result<crate::cloud_sync_transient_bridge::CloudTransientDecodeRequest, CloudSyncOutboundSafeCode> {
    use crate::cloud_sync_transient_bridge::{CloudTransientDecodeRequest, CloudTransientExpectedChangeKind};
    CloudTransientDecodeRequest::new(PathBuf::from(storage), auth.account_fingerprint.clone(),
        auth.protected_store_identity.clone(), "com.apple.messages.cloud".into(), "private".into(),
        "chatManateeZone".into(), "messages".into(), 2, crate::cloud_sync_native_fetch::CloudNativeStream::Chats,
        generation, CloudTransientExpectedChangeKind::Save, source.change_id_hash.clone(),
        source.record_id_hash.clone(), Some(source.etag_hash.clone()), source.payload_sha256.clone(),
        source.payload_length, source.server_modified_at_millis, source.protected_raw_envelope_reference.clone(), None)
        .map_err(|_| CloudSyncOutboundSafeCode::BindingMismatch)
}

#[frb(ignore)]
fn cloud_sync_attachment_group_route(
    mutation: &crate::cloud_sync_canonical_dto::CloudCanonicalMutation,
    generation: u64,
    digest: &str,
) -> Result<crate::cloud_sync_canonical_dto::CloudCanonicalChatPayload, CloudSyncOutboundSafeCode> {
    use crate::cloud_sync_canonical_dto::{CloudCanonicalPayload, CloudCanonicalChatStyle,
        CloudCanonicalService};
    if generation == 0 || mutation.envelope().generation() != generation
        || !is_cloud_sync_hex_digest(digest)
        || mutation.snapshot().and_then(|v| v.group_metadata_digest()).map(|v| v.value()) != Some(digest)
    { return Err(CloudSyncOutboundSafeCode::BindingMismatch); }
    match mutation.payload() {
        Some(CloudCanonicalPayload::Chat(chat))
            if chat.style() == CloudCanonicalChatStyle::Group && chat.service() == CloudCanonicalService::IMessage => Ok((**chat).clone()),
        _ => Err(CloudSyncOutboundSafeCode::BindingMismatch),
    }
}

#[frb(ignore)]
fn cloud_sync_validate_attachment_group_proof(
    storage: &str,
    auth: &CloudSyncNativeAuthMetadata,
    proof: &CloudSyncAttachmentParentGroupProof,
) -> Result<(), CloudSyncOutboundSafeCode> {
    use crate::cloud_sync_native_fetch::{CloudNativeProtectionScope, CloudNativeStream,
        cloud_sync_unprotect_raw_envelope};
    if std::time::Instant::now() >= proof.expires_at || proof.storage_directory != storage
        || !cloud_sync_auth_identity_remains_exact(&proof.auth, auth,
            &auth.account_fingerprint, &auth.protected_store_identity)
    { return Err(CloudSyncOutboundSafeCode::InvalidScope); }
    let actual_store = crate::cloud_sync_protector::protected_store_identity(storage.to_owned())
        .map_err(|_| CloudSyncOutboundSafeCode::ProtectedStorage)?;
    if actual_store != auth.protected_store_identity { return Err(CloudSyncOutboundSafeCode::InvalidScope); }
    let scope = CloudNativeProtectionScope::new(auth.account_fingerprint.clone(), CloudNativeStream::Chats)
        .map_err(|_| CloudSyncOutboundSafeCode::InvalidScope)?;
    let envelope = cloud_sync_unprotect_raw_envelope(PathBuf::from(storage), &scope,
        CloudNativeStream::Chats, proof.generation, &proof.source.protected_raw_envelope_reference)
        .map_err(|_| CloudSyncOutboundSafeCode::ProtectedStorage)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(storage.to_owned())
        .map_err(|_| CloudSyncOutboundSafeCode::ProtectedStorage)?;
    crate::cloud_sync_transient_bridge::bind_envelope(&proof.request, &envelope, &hasher)
        .map_err(|_| CloudSyncOutboundSafeCode::BindingMismatch)
}

/// Historical bridge name retained for binding compatibility. The owner is
/// record-agnostic: typed Message and Chat prepare APIs freeze their own exact
/// operations before constructing this handle. Consumption cannot change the
/// record type, zone, payload, or persisted request/operation identity.
#[frb(opaque)]
pub struct CloudSyncPreparedMessageCreateHandle {
    prepared: tokio::sync::Mutex<Option<CloudSyncPreparedMessageCreateOwner>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    expected_handle_binding_sha256: String,
    expected_reconciliation_binding_sha256: std::sync::OnceLock<String>,
}

enum CloudSyncPreparedMessageCreateOwner {
    Native {
        prepared:
            rustpush::cloud_messages::CloudMessagesPreparedSaveSubmission<DefaultAnisetteProvider>,
        native_writer_permit: rustpush::cloudkit_operation_gate::CloudKitWriterOperationPermit,
        cloud_messages_client: Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
        writer_binding: rustpush::cloud_messages::CloudMessagesWriterPreparationBinding<
            DefaultAnisetteProvider,
        >,
        attachment_parent_group_proofs: Vec<CloudSyncAttachmentParentGroupProof>,
    },
    #[cfg(test)]
    Test {
        remote_call_count: Arc<std::sync::atomic::AtomicUsize>,
        after_remote_call: Option<Box<dyn FnOnce() + Send>>,
        outcomes: Vec<CloudSyncOutboundSaveOutcome>,
    },
}

enum CloudSyncPreparedMessageCreateConsumption {
    Native(Vec<rustpush::cloud_messages::CloudMessagesSaveOutcome>),
    #[cfg(test)]
    Test(Vec<CloudSyncOutboundSaveOutcome>),
}

impl CloudSyncPreparedMessageCreateOwner {
    async fn consume_once(
        self,
    ) -> Result<CloudSyncPreparedMessageCreateConsumption, CloudSyncOutboundSafeCode> {
        match self {
            Self::Native {
                prepared,
                native_writer_permit,
                cloud_messages_client,
                writer_binding,
                attachment_parent_group_proofs,
            } => {
                cloud_messages_client
                    .validate_writer_preparation_binding(&writer_binding)
                    .await
                    .map_err(|_| CloudSyncOutboundSafeCode::InvalidScope)?;
                // A delayed prepared handle cannot submit using an expired,
                // removed or account/session-stale retained Chat proof.
                if let Some(proof) = attachment_parent_group_proofs.first() {
                    let auth = cloud_sync_capture_auth_snapshot(&cloud_messages_client,
                        proof.storage_directory.clone()).await
                        .map_err(|_| CloudSyncOutboundSafeCode::NativeAuthUnavailable)?;
                    for bound in &attachment_parent_group_proofs {
                        cloud_sync_validate_attachment_group_proof(&proof.storage_directory, &auth, bound)?;
                    }
                }
                let outcomes = native_writer_permit
                    .run(prepared.consume_once())
                    .await
                    .map_err(|_| CloudSyncOutboundSafeCode::CorrelationMismatch)?;
                cloud_messages_client
                    .validate_writer_preparation_binding(&writer_binding)
                    .await
                    .map_err(|_| CloudSyncOutboundSafeCode::InvalidScope)?;
                Ok(CloudSyncPreparedMessageCreateConsumption::Native(outcomes))
            }
            #[cfg(test)]
            Self::Test {
                remote_call_count,
                after_remote_call,
                outcomes,
            } => {
                remote_call_count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                if let Some(after_remote_call) = after_remote_call {
                    after_remote_call();
                }
                Ok(CloudSyncPreparedMessageCreateConsumption::Test(outcomes))
            }
        }
    }
}

impl std::fmt::Debug for CloudSyncPreparedMessageCreateHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CloudSyncPreparedMessageCreateHandle(redacted)")
    }
}

const CLOUD_SYNC_WRITER_MUTATION_FENCE_FILE: &str =
    ".openbubbles-cloudkit-writer-mutation-v1.fence";
const CLOUD_SYNC_WRITER_MUTATION_FENCE_MAX_BYTES: u64 = 4096;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CloudSyncWriterMutationFence {
    account_fingerprint: String,
    capability_sha256: String,
    container: String,
    database: String,
    epoch: u64,
    owner: String,
    prepared_handle_binding_sha256: String,
    protected_store_identity: String,
    reconciliation_binding_sha256: String,
    version: u32,
}

fn cloud_sync_new_prepared_handle_binding_sha256() -> String {
    Sha256::digest(Uuid::new_v4().as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn cloud_sync_writer_mutation_capability_is_valid(
    handle: &CloudSyncPreparedMessageCreateHandle,
    capability_token: &str,
) -> bool {
    cloud_sync_bound_mutation_capability_is_valid(
        &handle.storage_directory,
        &handle.expected_account_fingerprint,
        &handle.expected_protected_store_identity,
        &handle.expected_handle_binding_sha256,
        &handle.expected_reconciliation_binding_sha256,
        capability_token,
    )
}

/// Same native fence validation for record saves and byte uploads. The
/// reconciliation binding identifies the appropriate durable journal, not a
/// synthetic record-save operation used to disguise a byte upload.
fn cloud_sync_bound_mutation_capability_is_valid(
    storage_directory: &str,
    expected_account_fingerprint: &str,
    expected_protected_store_identity: &str,
    expected_handle_binding_sha256: &str,
    expected_reconciliation_binding_sha256: &std::sync::OnceLock<String>,
    capability_token: &str,
) -> bool {
    if capability_token.len() != 64
        || !capability_token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        return false;
    }
    let fence_path =
        PathBuf::from(storage_directory).join(CLOUD_SYNC_WRITER_MUTATION_FENCE_FILE);
    let metadata = match fs::symlink_metadata(&fence_path) {
        Ok(metadata) => metadata,
        Err(_) => return false,
    };
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() == 0
        || metadata.len() > CLOUD_SYNC_WRITER_MUTATION_FENCE_MAX_BYTES
    {
        return false;
    }
    let encoded = match fs::read_to_string(fence_path) {
        Ok(encoded) => encoded,
        Err(_) => return false,
    };
    let fence: CloudSyncWriterMutationFence = match serde_json::from_str(&encoded) {
        Ok(fence) => fence,
        Err(_) => return false,
    };
    let capability_sha256 = Sha256::digest(capability_token.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let fence_is_valid = fence.version == 3
        && fence.epoch > 0
        && fence.owner == "v2"
        && fence.container == "com.apple.messages.cloud"
        && fence.database == "private"
        && fence.account_fingerprint == expected_account_fingerprint
        && fence.protected_store_identity == expected_protected_store_identity
        && fence.prepared_handle_binding_sha256 == expected_handle_binding_sha256
        && fence.capability_sha256 == capability_sha256
        && is_cloud_sync_hex_digest(&fence.reconciliation_binding_sha256);
    if !fence_is_valid {
        return false;
    }

    match expected_reconciliation_binding_sha256.get() {
        Some(expected) => expected == &fence.reconciliation_binding_sha256,
        None => match expected_reconciliation_binding_sha256
            .set(fence.reconciliation_binding_sha256)
        {
            Ok(()) => true,
            Err(binding) => expected_reconciliation_binding_sha256
                .get()
                .is_some_and(|expected| expected == &binding),
        },
    }
}

#[derive(Debug)]
pub struct CloudSyncPreparedMessageCreateResult {
    pub handle: Option<CloudSyncPreparedMessageCreateHandle>,
    pub handle_binding_sha256: Option<String>,
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
    /// Per-install HMAC of the validated CloudKit record name. Present only
    /// when [disposition] is [CloudSyncOutboundSaveDisposition::Succeeded].
    pub server_record_id_hash: Option<String>,
    /// Per-install HMAC of the nonempty ETag from the same validated server
    /// response. Present only for a proven success.
    pub etag_hash: Option<String>,
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
    /// Receipt hashes are emitted only for an exact committed readback.
    pub server_record_id_hash: Option<String>,
    pub etag_hash: Option<String>,
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
pub enum CloudSyncTransientOutOfScopeService {
    SmsFamily,
    Rcs,
    IMessageLite,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientFailureCode {
    InvalidRequest,
    ReadAuthenticationScope,
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
    ResetRequired,
}

/// Content-free failure vocabulary for one native attachment-body fetch.
///
/// This never exposes paths, record identifiers, MMCS authorization, or asset
/// metadata. The only successful value returned to Dart is the verified byte
/// count after native atomic placement.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncAttachmentMaterializationFailureCode {
    InvalidRequest,
    ReadAuthenticationScope,
    ActiveAccountMismatch,
    StoreIdentityMismatch,
    ProtectedReferenceMismatch,
    SourceUnusable,
    PcsUnavailable,
    CloudKitResetRequired,
    RetryableUpstream,
    LocalStorage,
    SizeMismatch,
    IntegrityMismatch,
    DecoderFailure,
}

/// Exactly one of `completed` and `failure` is populated. `verified_bytes`
/// is meaningful only when `completed` is true.
#[derive(Clone)]
pub struct CloudSyncAttachmentMaterializationResult {
    pub completed: bool,
    pub verified_bytes: u64,
    pub failure: Option<CloudSyncAttachmentMaterializationFailureCode>,
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
    pub chat_id_exact_guid_logical_key_hash: String,
    /// Diagnostic-only service-qualified direct-CID candidate for a bare
    /// message chatID. It is not authoritative owner evidence.
    pub chat_id_bare_direct_service_identifier_alias_key_hash: Option<String>,
    pub chat_id_alias_candidates: Vec<CloudSyncTransientChatAlias>,
    pub msg_proto_4_group_id_alias_key_hash: Option<String>,
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

/// Content-free statement of whether the native build can materialize an
/// attachment body from the protected source that produced its metadata.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncTransientAttachmentMaterializationCapability {
    Materializable,
    MetadataOnlyUnsupportedMediaCredentials,
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
    pub materialization_capability: CloudSyncTransientAttachmentMaterializationCapability,
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
/// `out_of_scope_service`, `deferred_reason`, `quarantine_reason`, and
/// `failure_code` is populated.
/// `quarantine_diagnostic_safe_code` is optional secondary metadata drawn
/// only from a closed native vocabulary and never contains record content or
/// identifiers.
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
    pub out_of_scope_service: Option<CloudSyncTransientOutOfScopeService>,
    pub deferred_reason: Option<CloudSyncTransientDeferredReason>,
    pub quarantine_reason: Option<CloudSyncTransientQuarantineReason>,
    pub quarantine_diagnostic_safe_code: Option<String>,
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

pub(super) fn cloud_sync_auth_identity_remains_exact(
    before: &CloudSyncNativeAuthMetadata,
    after: &CloudSyncNativeAuthMetadata,
    expected_account_fingerprint: &str,
    expected_protected_store_identity: &str,
) -> bool {
    before.native_session_id == after.native_session_id
        && before.account_fingerprint == after.account_fingerprint
        && before.protected_store_identity == after.protected_store_identity
        && after.account_fingerprint == expected_account_fingerprint
        && after.protected_store_identity == expected_protected_store_identity
}

fn cloud_sync_outbound_failure_result(
    failure: CloudSyncOutboundSafeCode,
) -> CloudSyncProtectedOutboundStageResult {
    CloudSyncProtectedOutboundStageResult {
        stage: None,
        failure: Some(failure),
    }
}

// Never format a PushError here: delegate/plist/HTTP errors may contain
// credentials or record contents. Preserve a bounded, closed vocabulary.
fn cloud_sync_writer_preparation_failure_code(mut error: &PushError) -> &'static str {
    for _ in 0..8 {
        match error {
            PushError::DoNotRetry(inner) => error = inner,
            PushError::BatchError(inner) => error = inner,
            PushError::ResourceFailure(inner) => error = &inner.error,
            PushError::TokenMissing => return "token-missing",
            PushError::CloudKitWarmAuthenticationRequired => return "warm-auth-required",
            PushError::CloudKitSemanticOperationDenied => return "writer-scope-denied",
            PushError::DelegateLoginFailed(_, _, _) => return "delegate-login-failed",
            PushError::AuthError(_) => return "authentication-rejected",
            PushError::UnauthorizedAccountError => return "account-identity-unavailable",
            PushError::DecryptionKeyNotFound(_) | PushError::CloudKeyNotFound { .. } => {
                return "pcs-key-missing";
            }
            _ => return cloud_sync_failure_category(error).1,
        }
    }
    "error-wrapper-limit"
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
    let writer_binding = match cloud_messages_client
        .warm_message_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(error) => {
            warn!("Cloud Sync writer preparation failed kind=message cause={}",
                cloud_sync_writer_preparation_failure_code(&error));
            log::logger().flush();
            return cloud_sync_outbound_failure_result(
                CloudSyncOutboundSafeCode::NativeAuthUnavailable,
            )
        }
    };
    let auth_after_preparation =
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
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    match crate::cloud_sync_outbound::stage_outbound_message(
        PathBuf::from(storage_directory),
        auth_after_preparation.account_fingerprint,
        writer_binding.container_scoped_user_id().to_owned(),
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

/// Stages one direct iMessage Chat and its original random record name.
/// The caller must durably adopt this exact lease before prepare; staging is
/// not local-origin admission and must never be repeated to recover a submit.
pub async fn cloud_sync_stage_outbound_chat(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    chat: CloudChat,
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
    let writer_binding = match cloud_messages_client
        .warm_chat_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(error) => {
            warn!("Cloud Sync writer preparation failed kind=chat cause={}",
                cloud_sync_writer_preparation_failure_code(&error));
            log::logger().flush();
            return cloud_sync_outbound_failure_result(
                CloudSyncOutboundSafeCode::NativeAuthUnavailable,
            )
        }
    };
    let auth_after_preparation =
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
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    match crate::cloud_sync_outbound_chat::stage_outbound_chat(
        PathBuf::from(storage_directory),
        auth_after_preparation.account_fingerprint,
        chat,
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
        handle_binding_sha256: None,
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
    let writer_binding = match cloud_messages_client
        .warm_message_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(_) => {
            return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
        }
    };
    let auth_after_preparation =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
            }
        };
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    let container_scoped_user_id = writer_binding.container_scoped_user_id().to_owned();

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
    let attachment_parent_inputs: Vec<_> = inputs.iter()
        .filter(|input| input.attachment_parent_context.is_some()).cloned().collect();
    let attachment_parent_group_proofs = inputs.iter()
        .filter_map(|input| input.attachment_parent_group_proof.clone()).collect();
    let mut messages = Vec::with_capacity(inputs.len());
    for input in inputs {
        let opened = match cloud_sync_open_message_create_bound(
            &storage_directory, &auth_after_preparation, &container_scoped_user_id, &input,
        ) {
            Ok(opened) => opened,
            Err(code) => return cloud_sync_prepare_failure(code),
        };
        messages.push(rustpush::cloud_messages::CloudMessageSaveInput {
            local_operation_id: input.local_operation_id,
            server_record_name: opened.record_name().to_owned(),
            apple_operation_uuid: input.apple_operation_uuid,
            message: opened.message().clone(),
        });
    }

    let native_writer_permit =
        match rustpush::cloudkit_operation_gate::acquire_cloudkit_writer_operation().await {
            Ok(permit) => permit,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativePrepareFailed)
            }
        };
    let prepared_result = native_writer_permit
        .run(cloud_messages_client.prepare_message_save_submission(
            &writer_binding,
            messages,
            request_identity,
            Duration::from_secs(request_timeout_seconds),
        ))
        .await;
    match prepared_result {
        Ok(prepared) => {
            let auth_after_native_prepare = match cloud_sync_capture_auth_snapshot(
                cloud_messages_client,
                storage_directory.clone(),
            )
            .await
            {
                Ok(auth) => auth,
                Err(_) => {
                    return cloud_sync_prepare_failure(
                        CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                    )
                }
            };
            if !cloud_sync_auth_identity_remains_exact(
                &auth_after_preparation,
                &auth_after_native_prepare,
                &expected_account_fingerprint,
                &expected_protected_store_identity,
            ) {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
            }
            if cloud_messages_client
                .validate_writer_preparation_binding(&writer_binding)
                .await
                .is_err()
            {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
            }
            for input in &attachment_parent_inputs {
                if let Err(code) = cloud_sync_open_message_create_bound(
                    &storage_directory, &auth_after_native_prepare, &container_scoped_user_id, input,
                ) { return cloud_sync_prepare_failure(code); }
            }
            let handle_binding_sha256 = cloud_sync_new_prepared_handle_binding_sha256();
            CloudSyncPreparedMessageCreateResult {
                handle: Some(CloudSyncPreparedMessageCreateHandle {
                    prepared: tokio::sync::Mutex::new(Some(
                        CloudSyncPreparedMessageCreateOwner::Native {
                            prepared,
                            native_writer_permit,
                            cloud_messages_client: cloud_messages_client.clone(),
                            writer_binding,
                            attachment_parent_group_proofs,
                        },
                    )),
                    storage_directory,
                    expected_account_fingerprint,
                    expected_protected_store_identity,
                    expected_handle_binding_sha256: handle_binding_sha256.clone(),
                    expected_reconciliation_binding_sha256: std::sync::OnceLock::new(),
                }),
                handle_binding_sha256: Some(handle_binding_sha256),
                failure: None,
            }
        }
        Err(_) => cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativePrepareFailed),
    }
}

/// Prepares exactly one chatManateeZone create from an adopted version-1
/// envelope. No record/request/operation UUID is allocated here. Authentication
/// warmup is lookup-only; remote RecordSave requires the shared consume API.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_prepare_chat_create(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    request_uuid: String,
    request_timeout_seconds: u64,
    inputs: Vec<CloudSyncPreparedMessageCreateInput>,
) -> CloudSyncPreparedMessageCreateResult {
    if !is_valid_cloud_sync_chat_create_request(
        &expected_account_fingerprint,
        &request_uuid,
        request_timeout_seconds,
        &inputs,
    ) {
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
    let writer_binding = match cloud_messages_client
        .warm_chat_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(_) => {
            return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
        }
    };
    let auth_after_preparation =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
            }
        };
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }

    let input = &inputs[0];
    let request_identity = match rustpush::cloudkit::CloudKitRequestIdentity::new(
        request_uuid,
        vec![input.apple_operation_uuid.clone()],
    ) {
        Ok(identity) => identity,
        Err(_) => return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidRequest),
    };
    let storage_path = PathBuf::from(&storage_directory);
    if crate::cloud_sync_native_fetch::cloud_sync_verify_committed_lease_exact(
        storage_path.clone(),
        &input.protected_lease_reference,
        std::slice::from_ref(&input.protected_payload_reference),
    )
    .is_err()
    {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::ProtectedStorage);
    }
    let (chat, server_record_name) =
        match crate::cloud_sync_outbound_chat::open_staged_outbound_chat(
            storage_path,
            auth_after_preparation.account_fingerprint.clone(),
            &input.protected_payload_reference,
            &input.payload_sha256,
            &input.server_record_id_hash,
        ) {
            Ok(value) => value,
            Err(failure) => {
                return cloud_sync_prepare_failure(map_cloud_sync_outbound_failure(failure))
            }
        };
    let hasher =
        match crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
            Ok(hasher) => hasher,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::ProtectedStorage)
            }
        };
    let logical_hash = match hasher.canonical_entity_key_hash(
        crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Chat,
        &chat.guid,
    ) {
        Ok(hash) => hash,
        Err(_) => return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::BindingMismatch),
    };
    if logical_hash.value() != input.logical_entity_key_hash {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    let chat_input = rustpush::cloud_messages::CloudChatSaveInput {
        local_operation_id: input.local_operation_id.clone(),
        server_record_name,
        apple_operation_uuid: input.apple_operation_uuid.clone(),
        chat,
    };

    let native_writer_permit =
        match rustpush::cloudkit_operation_gate::acquire_cloudkit_writer_operation().await {
            Ok(permit) => permit,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativePrepareFailed)
            }
        };
    let prepared_result = native_writer_permit
        .run(cloud_messages_client.prepare_chat_save_submission(
            &writer_binding,
            chat_input,
            request_identity,
            Duration::from_secs(request_timeout_seconds),
        ))
        .await;
    match prepared_result {
        Ok(prepared) => {
            let auth_after_native_prepare = match cloud_sync_capture_auth_snapshot(
                cloud_messages_client,
                storage_directory.clone(),
            )
            .await
            {
                Ok(auth) => auth,
                Err(_) => {
                    return cloud_sync_prepare_failure(
                        CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                    )
                }
            };
            if !cloud_sync_auth_identity_remains_exact(
                &auth_after_preparation,
                &auth_after_native_prepare,
                &expected_account_fingerprint,
                &expected_protected_store_identity,
            ) {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
            }
            if cloud_messages_client
                .validate_writer_preparation_binding(&writer_binding)
                .await
                .is_err()
            {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
            }
            let handle_binding_sha256 = cloud_sync_new_prepared_handle_binding_sha256();
            CloudSyncPreparedMessageCreateResult {
                handle: Some(CloudSyncPreparedMessageCreateHandle {
                    prepared: tokio::sync::Mutex::new(Some(
                        CloudSyncPreparedMessageCreateOwner::Native {
                            prepared,
                            native_writer_permit,
                            cloud_messages_client: cloud_messages_client.clone(),
                            writer_binding,
                            attachment_parent_group_proofs: vec![],
                        },
                    )),
                    storage_directory,
                    expected_account_fingerprint,
                    expected_protected_store_identity,
                    expected_handle_binding_sha256: handle_binding_sha256.clone(),
                    expected_reconciliation_binding_sha256: std::sync::OnceLock::new(),
                }),
                handle_binding_sha256: Some(handle_binding_sha256),
                failure: None,
            }
        }
        Err(_) => cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativePrepareFailed),
    }
}

fn is_valid_cloud_sync_attachment_create_input(
    expected_account_fingerprint: &str,
    request_uuid: &str,
    input: &CloudSyncPreparedMessageCreateInput,
) -> bool {
    input.attachment_parent_context.is_none()
        && input.attachment_parent_group_proof.is_none()
        && is_cloud_sync_operation_id(&input.local_operation_id)
        && crate::cloud_sync_outbound_attachment::initial_attachment_create_operation_id(
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

/// Stages an initial attachment parent from its exact committed IDS source.
/// message_headers must have no attributed body and no nonempty text. This
/// creates no upload/send authority; Dart retains the source lease and admits
/// the Message only after its complete attachment dependency set is ready.
pub async fn cloud_sync_stage_outbound_attachment_parent(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    context: CloudSyncNativeSendReceiptContext,
    message_headers: CloudMessage,
    attachment_parent_group_proof: Option<CloudSyncAttachmentParentGroupProof>,
) -> CloudSyncProtectedOutboundStageResult {
    let storage = context.storage_directory.clone();
    let auth = match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage.clone()).await {
        Ok(auth) => auth,
        Err(_) => return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::NativeAuthUnavailable),
    };
    if cloud_sync_open_attachment_parent_source(&storage, &auth, &context).is_err() {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    let binding = match cloud_messages_client.warm_message_writer_preparation_lookup_only().await {
        Ok(binding) => binding,
        Err(_) => return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::NativeAuthUnavailable),
    };
    let after = match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage.clone()).await {
        Ok(auth) => auth,
        Err(_) => return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::NativeAuthUnavailable),
    };
    if !cloud_sync_auth_identity_remains_exact(&auth, &after,
        &context.account_fingerprint, &context.protected_store_identity)
        || cloud_messages_client.validate_writer_preparation_binding(&binding).await.is_err()
    {
        return cloud_sync_outbound_failure_result(CloudSyncOutboundSafeCode::InvalidScope);
    }
    // Reopen after awaits, rather than relying on the earlier source snapshot.
    let source = match cloud_sync_open_attachment_parent_source(&storage, &after, &context) {
        Ok(source) => source,
        Err(code) => return cloud_sync_outbound_failure_result(code),
    };
    if let Some(proof) = &attachment_parent_group_proof {
        if let Err(code) = cloud_sync_validate_attachment_group_proof(&storage, &after, proof) {
            return cloud_sync_outbound_failure_result(code);
        }
    }
    match crate::cloud_sync_outbound::stage_outbound_attachment_parent_with_group(
        PathBuf::from(storage), after.account_fingerprint,
        binding.container_scoped_user_id().to_owned(), message_headers, &source,
        attachment_parent_group_proof.as_ref().map(|v| &v.route),
    ) {
        Ok(stage) => CloudSyncProtectedOutboundStageResult {
            stage: Some(cloud_sync_bridge_stage(stage)), failure: None,
        },
        Err(failure) => cloud_sync_outbound_failure_result(map_cloud_sync_outbound_failure(failure)),
    }
}

#[frb(ignore)]
fn cloud_sync_open_attachment_parent_source(
    storage_directory: &str,
    auth: &CloudSyncNativeAuthMetadata,
    context: &CloudSyncNativeSendReceiptContext,
) -> Result<crate::cloud_sync_ids_attachment_source::DecodedIdsAttachmentSource, CloudSyncOutboundSafeCode> {
    // Exact caller scope, not a context-supplied alternate directory. The
    // source helper also checks actual store identity, account, native session,
    // committed lease, wrapper hash/length, local source hash and receipt GUID.
    if context.storage_directory != storage_directory {
        return Err(CloudSyncOutboundSafeCode::InvalidScope);
    }
    cloud_sync_require_source_context_auth(context, auth)
        .map_err(|_| CloudSyncOutboundSafeCode::InvalidScope)?;
    let encoded = cloud_sync_open_attachment_source_bound(context, auth)
        .map_err(|_| CloudSyncOutboundSafeCode::BindingMismatch)?;
    crate::cloud_sync_ids_attachment_source::decode_ids_attachment_source(&encoded)
        .map_err(map_cloud_sync_outbound_failure)
}

// A validated discriminant, not an attributed-body sniff. Ordinary messages
// still use the exact existing validators; parent messages always retain the
// source and original envelope together for readback.
enum CloudSyncOpenedMessageCreate {
    Ordinary { message: CloudMessage, record_name: String },
    AttachmentParent {
        parent: crate::cloud_sync_outbound::NativeOpenedAttachmentParent,
        source: crate::cloud_sync_ids_attachment_source::DecodedIdsAttachmentSource,
    },
}
impl CloudSyncOpenedMessageCreate {
    fn message(&self) -> &CloudMessage {
        match self { Self::Ordinary { message, .. } => message,
            Self::AttachmentParent { parent, .. } => parent.message() }
    }
    fn record_name(&self) -> &str {
        match self { Self::Ordinary { record_name, .. } => record_name,
            Self::AttachmentParent { parent, .. } => parent.server_record_name() }
    }
    fn verify_readback(&self, actual: CloudMessage, digest: &str)
        -> Result<String, crate::cloud_sync_outbound::CloudSyncOutboundFailure>
    {
        match self {
            Self::Ordinary { message, record_name } =>
                crate::cloud_sync_outbound::verify_message_readback(actual, message, record_name, digest),
            Self::AttachmentParent { parent, source } =>
                crate::cloud_sync_outbound::verify_attachment_parent_readback(actual, parent, digest, source),
        }
    }
}

#[frb(ignore)]
fn cloud_sync_open_message_create_bound(
    storage_directory: &str,
    auth: &CloudSyncNativeAuthMetadata,
    container_scoped_user_id: &str,
    input: &CloudSyncPreparedMessageCreateInput,
) -> Result<CloudSyncOpenedMessageCreate, CloudSyncOutboundSafeCode> {
    use crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind;
    let storage = PathBuf::from(storage_directory);
    if input.attachment_parent_context.is_none() && input.attachment_parent_group_proof.is_some() {
        return Err(CloudSyncOutboundSafeCode::InvalidRequest);
    }
    if input.protected_payload_reference != input.protected_server_record_reference {
        return Err(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    crate::cloud_sync_native_fetch::cloud_sync_verify_committed_lease_exact(
        storage.clone(), &input.protected_lease_reference,
        std::slice::from_ref(&input.protected_payload_reference),
    ).map_err(|_| CloudSyncOutboundSafeCode::ProtectedStorage)?;
    let (opened, kind) = match &input.attachment_parent_context {
        Some(context) => {
            let source = cloud_sync_open_attachment_parent_source(storage_directory, auth, context)?;
            if let Some(proof) = &input.attachment_parent_group_proof {
                cloud_sync_validate_attachment_group_proof(storage_directory, auth, proof)?;
            }
            let parent = crate::cloud_sync_outbound::open_staged_outbound_attachment_parent_with_group(
                storage, auth.account_fingerprint.clone(), &input.protected_payload_reference,
                &input.payload_sha256, &source,
                input.attachment_parent_group_proof.as_ref().map(|v| &v.route),
            ).map_err(map_cloud_sync_outbound_failure)?;
            (CloudSyncOpenedMessageCreate::AttachmentParent { parent, source }, CloudCanonicalEntityKind::Message)
        }
        None => {
            let message = crate::cloud_sync_outbound::open_staged_outbound_message(
                storage.clone(), auth.account_fingerprint.clone(),
                &input.protected_payload_reference, &input.payload_sha256,
            ).map_err(map_cloud_sync_outbound_failure)?;
            let kind = crate::cloud_sync_outbound::outbound_entity_kind(&message)
                .map_err(map_cloud_sync_outbound_failure)?;
            let record_name = crate::cloud_sync_outbound::open_staged_server_record_name(
                storage, auth.account_fingerprint.clone(),
                &input.protected_server_record_reference, &input.server_record_id_hash,
            ).map_err(map_cloud_sync_outbound_failure)?;
            (CloudSyncOpenedMessageCreate::Ordinary { message, record_name }, kind)
        }
    };
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.to_owned())
        .map_err(|_| CloudSyncOutboundSafeCode::ProtectedStorage)?;
    let logical_hash = hasher.canonical_entity_key_hash(kind, &opened.message().guid)
        .map_err(|_| CloudSyncOutboundSafeCode::BindingMismatch)?;
    if logical_hash.value() != input.logical_entity_key_hash
        || hasher.server_record_id_hash(opened.record_name()) != input.server_record_id_hash
    { return Err(CloudSyncOutboundSafeCode::BindingMismatch); }
    crate::cloud_sync_outbound::verify_deterministic_message_record_name(
        &opened.message().guid, container_scoped_user_id, opened.record_name(),
    ).map_err(map_cloud_sync_outbound_failure)?;
    Ok(opened)
}

#[cfg(test)]
mod cloud_sync_attachment_parent_create_tests {
    use super::*;
    use crate::cloud_sync_outbound::attachment_parent_test_support::{headers, source};

    fn group_mutation(opaque_id: &str) -> crate::cloud_sync_canonical_dto::CloudCanonicalMutation {
        use crate::cloud_sync_canonical_converter::{CloudCanonicalConversionContext,
            CloudCanonicalConversionOutcome, CloudRawRecordPresence, convert_chat};
        use crate::cloud_sync_canonical_dto::CloudCanonicalHash;
        use rustpush::{cloud_messages::{CloudChat, CloudParticipant}, cloudkit_proto::{Record, record::{Field, field}}};
        let hasher = crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher::new([7; 32]).unwrap();
        let hash = |c: &str| CloudCanonicalHash::new(c.repeat(43)).unwrap();
        let context = CloudCanonicalConversionContext::new(&hasher, hash("a"), hash("b"), 7,
            hash("c"), "chat-record", Some("etag"), None, None, "obcs2.fixture.protected");
        let record = Record { record_field: ["guid", "cid", "gid", "ogid", "svc", "stl", "ptcpts"]
            .into_iter().map(|name| Field { identifier: Some(field::Identifier { name: Some(name.into()) }),
                value: Some(field::Value::default()), ..Default::default() }).collect(), ..Default::default() };
        let presence = CloudRawRecordPresence::extract(&record).unwrap();
        let chat = CloudChat { guid: "iMessage;+;restored-chat".into(), chat_identifier: "restored-chat".into(),
            group_id: opaque_id.into(), original_group_id: "original-group-id".into(),
            service_name: "iMessage".into(), style: 43,
            participants: vec![CloudParticipant { uri: "mailto:peer@example.invalid".into() },
                CloudParticipant { uri: "tel:+15555550100".into() }], ..Default::default() };
        match convert_chat(&context, &presence, &chat) {
            CloudCanonicalConversionOutcome::Ready(value) => *value,
            _ => panic!("synthetic group conversion failed"),
        }
    }

    fn group_proof_fixture(storage: &str) -> CloudSyncAttachmentParentGroupProof {
        let auth = CloudSyncNativeAuthMetadata { account_fingerprint: "A".repeat(43),
            native_session_id: "N".repeat(43),
            protected_store_identity: crate::cloud_sync_protector::protected_store_identity(storage.into()).unwrap() };
        let source = super::super::cloud_sync_chat_identity::CloudSyncChatIdentitySourceInput {
            change_id_hash: "C".repeat(43), record_id_hash: "R".repeat(43), etag_hash: "E".repeat(43),
            payload_sha256: "a".repeat(64), payload_length: Some(20), server_modified_at_millis: None,
            protected_raw_envelope_reference: format!("obcs2.ref.{}", "P".repeat(43)),
        };
        let request = cloud_sync_attachment_group_decode_request(storage, &auth, 7, &source).unwrap();
        CloudSyncAttachmentParentGroupProof { storage_directory: storage.into(), auth: Arc::new(auth), generation: 7, source, request,
            route: crate::cloud_sync_outbound::attachment_parent_test_support::group(),
            expires_at: std::time::Instant::now() + Duration::from_secs(300) }
    }

    #[test]
    fn group_parent_proof_selects_native_route_only_for_exact_generation_and_digest() {
        let mutation = group_mutation("opaque-CloudKit-chat-id");
        let digest = mutation.snapshot().unwrap().group_metadata_digest().unwrap().value();
        let route = cloud_sync_attachment_group_route(&mutation, 7, digest).unwrap();
        assert_eq!(route.group_id(), "opaque-CloudKit-chat-id");
        assert_ne!(route.guid(), route.group_id());
        assert!(cloud_sync_attachment_group_route(&mutation, 8, digest).is_err());
        assert!(cloud_sync_attachment_group_route(&mutation, 0, digest).is_err());
        assert!(cloud_sync_attachment_group_route(&mutation, 7, &"0".repeat(64)).is_err());
        let different = group_mutation("different-opaque-id");
        assert!(cloud_sync_attachment_group_route(&different, 7, digest).is_err());
        // Feed the real converter result into the integrated parent encoder/open.
        use crate::cloud_sync_outbound::{attachment_parent_test_support::{group_headers, group_source},
            encode_outbound_attachment_parent_with_group, decode_outbound_attachment_parent_with_group};
        let source = group_source();
        let bytes = encode_outbound_attachment_parent_with_group(group_headers(), "record", &source, Some(&route)).unwrap();
        assert!(decode_outbound_attachment_parent_with_group(&bytes, &source, Some(&route)).is_ok());
        let other_digest = different.snapshot().unwrap().group_metadata_digest().unwrap().value();
        let other_route = cloud_sync_attachment_group_route(&different, 7, other_digest).unwrap();
        assert!(decode_outbound_attachment_parent_with_group(&bytes, &source, Some(&other_route)).is_err());
    }

    #[test]
    fn group_parent_proof_expiry_scope_and_missing_protected_source_fail_closed() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let mut proof = group_proof_fixture(storage);
        // A structurally valid request and route are not enough. The raw
        // protected source must still exist and authenticate on every use.
        assert!(matches!(cloud_sync_validate_attachment_group_proof(storage, &proof.auth, &proof),
            Err(CloudSyncOutboundSafeCode::ProtectedStorage)));
        proof.expires_at = std::time::Instant::now();
        assert!(matches!(cloud_sync_validate_attachment_group_proof(storage, &proof.auth, &proof),
            Err(CloudSyncOutboundSafeCode::InvalidScope)));
        proof.expires_at = std::time::Instant::now() + Duration::from_secs(300);
        for field in 0..3 {
            let mut auth = CloudSyncNativeAuthMetadata { account_fingerprint: proof.auth.account_fingerprint.clone(),
                native_session_id: proof.auth.native_session_id.clone(), protected_store_identity: proof.auth.protected_store_identity.clone() };
            match field { 0 => auth.account_fingerprint = "B".repeat(43),
                1 => auth.native_session_id = "M".repeat(43), _ => auth.protected_store_identity = "T".repeat(43) }
            assert!(matches!(cloud_sync_validate_attachment_group_proof(storage, &auth, &proof),
                Err(CloudSyncOutboundSafeCode::InvalidScope)));
        }
        assert!(matches!(cloud_sync_validate_attachment_group_proof("alternate-storage", &proof.auth, &proof),
            Err(CloudSyncOutboundSafeCode::InvalidScope)));
        assert!(cloud_sync_attachment_group_decode_request(storage, &proof.auth, 0, &proof.source).is_err());
        let mut malformed = proof.source.clone();
        malformed.etag_hash.clear();
        assert!(cloud_sync_attachment_group_decode_request(storage, &proof.auth, 7, &malformed).is_err());
        assert_eq!(format!("{proof:?}"), "CloudSyncAttachmentParentGroupProof(redacted)");
    }

    #[test]
    fn group_proof_is_not_authority_for_ordinary_chat_or_attachment_inputs() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let proof = group_proof_fixture(storage);
        let mut input = CloudSyncPreparedMessageCreateInput {
            local_operation_id: crate::cloud_sync_outbound_chat::initial_chat_create_operation_id(&proof.auth.account_fingerprint, &"L".repeat(43)).unwrap(),
            logical_entity_key_hash: "L".repeat(43),
            protected_lease_reference: format!("obcs2.lease.{}", "a".repeat(32)),
            protected_payload_reference: format!("obcs2.ref.{}", "P".repeat(43)), payload_sha256: "a".repeat(64),
            protected_server_record_reference: format!("obcs2.ref.{}", "P".repeat(43)), server_record_id_hash: "R".repeat(43),
            apple_operation_uuid: "AAAAAAAA-BBBB-4CCC-8DDD-000000000001".into(),
            attachment_parent_context: None, attachment_parent_group_proof: Some(proof.clone()),
        };
        let request = "11111111-2222-4ABC-8DEF-555555555555";
        assert!(matches!(cloud_sync_open_message_create_bound(storage, &proof.auth, "container-user", &input),
            Err(CloudSyncOutboundSafeCode::InvalidRequest)));
        assert!(!is_valid_cloud_sync_chat_create_input(&proof.auth.account_fingerprint, request, &input));
        input.attachment_parent_group_proof = None;
        assert!(is_valid_cloud_sync_chat_create_input(&proof.auth.account_fingerprint, request, &input));
        input.local_operation_id = crate::cloud_sync_outbound_attachment::initial_attachment_create_operation_id(
            &proof.auth.account_fingerprint, &input.logical_entity_key_hash).unwrap();
        assert!(is_valid_cloud_sync_attachment_create_input(&proof.auth.account_fingerprint, request, &input));
        input.attachment_parent_group_proof = Some(proof.clone());
        assert!(!is_valid_cloud_sync_attachment_create_input(&proof.auth.account_fingerprint, request, &input));
        input.attachment_parent_group_proof = None;
        assert!(matches!(cloud_sync_open_message_create_bound(storage, &proof.auth, "container-user", &input),
            Err(CloudSyncOutboundSafeCode::ProtectedStorage)));
    }

    #[test]
    fn protected_parent_create_requires_exact_context_and_both_committed_leases() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_string_lossy().into_owned();
        let (message, guids) = crate::cloud_sync_ids_attachment_source::message_inst_from_decoded_source(&source()).unwrap();
        let source_stage = crate::cloud_sync_ids_attachment_source::stage_ids_attachment_source(
            directory.path().to_path_buf(), "A".repeat(43), &"a".repeat(64), &message, &guids,
        ).unwrap();
        let context = CloudSyncNativeSendReceiptContext {
            storage_directory: storage.clone(), guid_hash: cloud_sync_local_send_guid_hash(&message.id),
            account_fingerprint: "A".repeat(43), native_session_id: "N".repeat(43),
            protected_store_identity: crate::cloud_sync_protector::protected_store_identity(storage.clone()).unwrap(),
            source_binding: Some(CloudSyncNativeSendSourceBinding {
                kind: None,
                source_sha256: "a".repeat(64), protected_reference: source_stage.protected_reference.clone(),
                lease_reference: source_stage.lease_reference.clone(), payload_sha256: source_stage.payload_sha256.clone(),
                payload_length: source_stage.payload_length,
            }),
        };
        let auth = CloudSyncNativeAuthMetadata {
            account_fingerprint: context.account_fingerprint.clone(), native_session_id: context.native_session_id.clone(),
            protected_store_identity: context.protected_store_identity.clone(),
        };
        assert!(cloud_sync_open_attachment_parent_source(&storage, &auth, &context).is_err());
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(), &source_stage.lease_reference,
            std::slice::from_ref(&source_stage.protected_reference),
        ).unwrap();
        let decoded = cloud_sync_open_attachment_parent_source(&storage, &auth, &context).unwrap();
        let stage = crate::cloud_sync_outbound::stage_outbound_attachment_parent(
            directory.path().to_path_buf(), context.account_fingerprint.clone(),
            "container-user".to_owned(), headers(), &decoded,
        ).unwrap();
        let input = CloudSyncPreparedMessageCreateInput {
            local_operation_id: crate::cloud_sync_outbound::initial_message_create_operation_id(
                &context.account_fingerprint, &stage.logical_entity_key_hash,
            ).unwrap(),
            logical_entity_key_hash: stage.logical_entity_key_hash,
            protected_lease_reference: stage.lease_reference,
            protected_payload_reference: stage.protected_payload_reference,
            payload_sha256: stage.payload_sha256,
            protected_server_record_reference: stage.protected_server_record_reference,
            server_record_id_hash: stage.server_record_id_hash,
            apple_operation_uuid: "AAAAAAAA-BBBB-4CCC-8DDD-000000000001".to_owned(),
            attachment_parent_context: Some(context.clone()),
            attachment_parent_group_proof: None,
        };
        assert!(cloud_sync_open_message_create_bound(&storage, &auth, "container-user", &input).is_err());
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(), &input.protected_lease_reference,
            std::slice::from_ref(&input.protected_payload_reference),
        ).unwrap();
        let opened = cloud_sync_open_message_create_bound(&storage, &auth, "container-user", &input).unwrap();
        assert_eq!(opened.message().msg_proto.0.text.as_deref(), Some("A😀 B "));
        assert_eq!(opened.verify_readback(opened.message().clone(), &input.payload_sha256).unwrap(), input.payload_sha256);
        assert!(cloud_sync_open_message_create_bound(&storage, &auth, "other-user", &input).is_err());
        let alternate_storage = format!("{storage}-different");
        assert!(cloud_sync_open_attachment_parent_source(&alternate_storage, &auth, &context).is_err());
        for field in 0..10 {
            let mut wrong = input.clone();
            let c = wrong.attachment_parent_context.as_mut().unwrap();
            match field {
                0 => c.storage_directory = alternate_storage.clone(),
                1 => c.account_fingerprint = "B".repeat(43),
                2 => c.protected_store_identity.push('x'),
                3 => c.native_session_id = "M".repeat(43),
                4 => c.guid_hash = "b".repeat(64),
                5 => c.source_binding = None,
                6 => c.source_binding.as_mut().unwrap().payload_sha256 = "b".repeat(64),
                7 => c.source_binding.as_mut().unwrap().source_sha256 = "b".repeat(64),
                8 => c.source_binding.as_mut().unwrap().payload_length += 1,
                _ => c.source_binding.as_mut().unwrap().lease_reference = input.protected_lease_reference.clone(),
            }
            assert!(cloud_sync_open_message_create_bound(&storage, &auth, "container-user", &wrong).is_err());
        }
        let mut unbound = input.clone();
        unbound.attachment_parent_context = None;
        assert!(cloud_sync_open_message_create_bound(&storage, &auth, "container-user", &unbound).is_err());
        let inventory = cloud_sync_inspect_attachment_sources_bound(&context, &auth).unwrap();
        assert_eq!(inventory.len(), 2);
        assert_eq!(inventory[0].original_attachment_guid, "original-A");
        assert_eq!(inventory[1].reflected_attachment_guid, "parent-fixture-guid_7");
        // Reopen has not allocated a new parent, changed identity or consumed
        // the source lease. Recovery keeps the original protected reference.
        let reopened = cloud_sync_open_message_create_bound(&storage, &auth, "container-user", &input).unwrap();
        assert_eq!(opened.record_name(), reopened.record_name());
        assert!(cloud_sync_open_attachment_parent_source(&storage, &auth, &context).is_ok());
        assert_eq!(format!("{context:?}"), "CloudSyncNativeSendReceiptContext(redacted)");

        let request = "11111111-2222-4ABC-8DEF-555555555555";
        let mut other_kind = input.clone();
        other_kind.local_operation_id = crate::cloud_sync_outbound_chat::initial_chat_create_operation_id(
            &context.account_fingerprint, &input.logical_entity_key_hash,
        ).unwrap();
        assert!(!is_valid_cloud_sync_chat_create_input(&context.account_fingerprint, request, &other_kind));
        other_kind.attachment_parent_context = None;
        assert!(is_valid_cloud_sync_chat_create_input(&context.account_fingerprint, request, &other_kind));
        other_kind.attachment_parent_context = Some(context.clone());
        other_kind.local_operation_id = crate::cloud_sync_outbound_attachment::initial_attachment_create_operation_id(
            &context.account_fingerprint, &input.logical_entity_key_hash,
        ).unwrap();
        assert!(!is_valid_cloud_sync_attachment_create_input(&context.account_fingerprint, request, &other_kind));
        other_kind.attachment_parent_context = None;
        assert!(is_valid_cloud_sync_attachment_create_input(&context.account_fingerprint, request, &other_kind));
    }
}

fn is_valid_cloud_sync_attachment_create_request(
    expected_account_fingerprint: &str,
    request_uuid: &str,
    request_timeout_seconds: u64,
    inputs: &[CloudSyncPreparedMessageCreateInput],
) -> bool {
    inputs.len() == 1
        && (1..=300).contains(&request_timeout_seconds)
        && is_valid_cloud_sync_attachment_create_input(
            expected_account_fingerprint,
            request_uuid,
            &inputs[0],
        )
}

/// Prepares the original completed attachment record for the same single-use
/// capability-fenced consumer as Message and Chat. Does not upload bytes.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_prepare_attachment_create(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    request_uuid: String,
    request_timeout_seconds: u64,
    inputs: Vec<CloudSyncPreparedMessageCreateInput>,
) -> CloudSyncPreparedMessageCreateResult {
    if !is_valid_cloud_sync_attachment_create_request(
        &expected_account_fingerprint,
        &request_uuid,
        request_timeout_seconds,
        &inputs,
    ) {
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
    let writer_binding = match cloud_messages_client
        .warm_attachment_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(_) => {
            return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
        }
    };
    let auth_after_preparation =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
            }
        };
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }

    let input = &inputs[0];
    let request_identity = match rustpush::cloudkit::CloudKitRequestIdentity::new(
        request_uuid,
        vec![input.apple_operation_uuid.clone()],
    ) {
        Ok(identity) => identity,
        Err(_) => return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidRequest),
    };
    let storage_path = PathBuf::from(&storage_directory);
    if crate::cloud_sync_native_fetch::cloud_sync_verify_committed_lease_exact(
        storage_path.clone(),
        &input.protected_lease_reference,
        std::slice::from_ref(&input.protected_payload_reference),
    )
    .is_err()
    {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::ProtectedStorage);
    }
    let (attachment, server_record_name) =
        match crate::cloud_sync_outbound_attachment::open_staged_outbound_attachment(
            storage_path,
            auth_after_preparation.account_fingerprint.clone(),
            &input.protected_payload_reference,
            &input.payload_sha256,
            &input.server_record_id_hash,
        ) {
            Ok(value) => value,
            Err(failure) => {
                return cloud_sync_prepare_failure(map_cloud_sync_outbound_failure(failure))
            }
        };
    let hasher =
        match crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
            Ok(hasher) => hasher,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::ProtectedStorage)
            }
        };
    let logical_hash = match hasher.canonical_attachment_key_hash(&attachment.cm.0.guid) {
        Ok(hash) => hash,
        Err(_) => return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::BindingMismatch),
    };
    if logical_hash.value() != input.logical_entity_key_hash {
        return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    let attachment_input = rustpush::cloud_messages::CloudAttachmentSaveInput {
        local_operation_id: input.local_operation_id.clone(),
        server_record_name,
        apple_operation_uuid: input.apple_operation_uuid.clone(),
        attachment,
    };

    let native_writer_permit =
        match rustpush::cloudkit_operation_gate::acquire_cloudkit_writer_operation().await {
            Ok(permit) => permit,
            Err(_) => {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativePrepareFailed)
            }
        };
    let prepared_result = native_writer_permit
        .run(cloud_messages_client.prepare_attachment_save_submission(
            &writer_binding,
            attachment_input,
            request_identity,
            Duration::from_secs(request_timeout_seconds),
        ))
        .await;
    match prepared_result {
        Ok(prepared) => {
            let auth_after_native_prepare = match cloud_sync_capture_auth_snapshot(
                cloud_messages_client,
                storage_directory.clone(),
            )
            .await
            {
                Ok(auth) => auth,
                Err(_) => {
                    return cloud_sync_prepare_failure(
                        CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                    )
                }
            };
            if !cloud_sync_auth_identity_remains_exact(
                &auth_after_preparation,
                &auth_after_native_prepare,
                &expected_account_fingerprint,
                &expected_protected_store_identity,
            ) {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
            }
            if cloud_messages_client
                .validate_writer_preparation_binding(&writer_binding)
                .await
                .is_err()
            {
                return cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::InvalidScope);
            }
            let handle_binding_sha256 = cloud_sync_new_prepared_handle_binding_sha256();
            CloudSyncPreparedMessageCreateResult {
                handle: Some(CloudSyncPreparedMessageCreateHandle {
                    prepared: tokio::sync::Mutex::new(Some(
                        CloudSyncPreparedMessageCreateOwner::Native {
                            prepared,
                            native_writer_permit,
                            cloud_messages_client: cloud_messages_client.clone(),
                            writer_binding,
                            attachment_parent_group_proofs: vec![],
                        },
                    )),
                    storage_directory,
                    expected_account_fingerprint,
                    expected_protected_store_identity,
                    expected_handle_binding_sha256: handle_binding_sha256.clone(),
                    expected_reconciliation_binding_sha256: std::sync::OnceLock::new(),
                }),
                handle_binding_sha256: Some(handle_binding_sha256),
                failure: None,
            }
        }
        Err(_) => cloud_sync_prepare_failure(CloudSyncOutboundSafeCode::NativePrepareFailed),
    }
}

/// Drops only an unconsumed prepared owner and its native writer permit.
/// Idempotent: true means an owner was released; false means no owner remains
/// in this handle. An already-taken consume owner is untouched, so false is
/// NOT proof of quiescence or of the remote outcome. Dart must first await
/// the settled native future, including timeout quiescence, before release.
/// This performs no submission and changes no fence, file, or protected lease.
/// Historical Message name also covers Chat and Attachment prepared handles.
pub async fn cloud_sync_release_prepared_message_create(
    handle: &CloudSyncPreparedMessageCreateHandle,
) -> bool {
    let mut prepared = handle.prepared.lock().await;
    let released = prepared.is_some();
    drop(prepared.take());
    released
}

/// Historical message name: this record-agnostic consumer also consumes the
/// opaque handle returned by Chat and Attachment prepare. No capability, permit, keystore,
/// single-use, container revalidation, or receipt fence is bypassed.
pub async fn cloud_sync_consume_prepared_message_create(
    handle: &CloudSyncPreparedMessageCreateHandle,
    mutation_capability_token: String,
) -> CloudSyncOutboundConsumeResult {
    cloud_sync_consume_prepared_message_create_with_hasher(
        handle,
        mutation_capability_token,
        |directory| {
            crate::cloud_sync_protector::semantic_identifier_hasher(directory).map_err(|_| ())
        },
    )
    .await
}

// Keep capability, keystore, single-use, and post-submit checks on one path.
// Tests inject only the platform keystore boundary, never a different consume
// implementation. The exported entry point always uses protected storage.
async fn cloud_sync_consume_prepared_message_create_with_hasher(
    handle: &CloudSyncPreparedMessageCreateHandle,
    mutation_capability_token: String,
    load_hasher: impl FnOnce(
        String,
    ) -> Result<
        crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
        (),
    >,
) -> CloudSyncOutboundConsumeResult {
    if !cloud_sync_writer_mutation_capability_is_valid(handle, &mutation_capability_token) {
        return CloudSyncOutboundConsumeResult {
            outcomes: vec![],
            failure: Some(CloudSyncOutboundSafeCode::MutationCapabilityInvalid),
        };
    }
    // Load the per-install hash key before taking the single-use owner. A
    // protected-storage failure must leave the prepared handle unconsumed and
    // cannot be discovered only after a remote mutation has crossed the wire.
    let hasher = match load_hasher(handle.storage_directory.clone()) {
        Ok(hasher) => hasher,
        Err(_) => {
            return CloudSyncOutboundConsumeResult {
                outcomes: vec![],
                failure: Some(CloudSyncOutboundSafeCode::ProtectedStorage),
            }
        }
    };
    let prepared = {
        let mut guard = handle.prepared.lock().await;
        guard.take()
    };
    let Some(owner) = prepared else {
        return CloudSyncOutboundConsumeResult {
            outcomes: vec![],
            failure: Some(CloudSyncOutboundSafeCode::AlreadyConsumed),
        };
    };
    let consumed = match owner.consume_once().await {
        Ok(outcomes) => outcomes,
        Err(failure) => {
            return CloudSyncOutboundConsumeResult {
                outcomes: vec![],
                failure: Some(failure),
            }
        }
    };
    if !cloud_sync_writer_mutation_capability_is_valid(handle, &mutation_capability_token) {
        return CloudSyncOutboundConsumeResult {
            outcomes: vec![],
            failure: Some(CloudSyncOutboundSafeCode::MutationCapabilityInvalid),
        };
    }
    let outcomes = match consumed {
        CloudSyncPreparedMessageCreateConsumption::Native(outcomes) => outcomes
            .into_iter()
            .map(|outcome| map_cloud_sync_native_save_outcome(outcome, &hasher))
            .collect(),
        #[cfg(test)]
        CloudSyncPreparedMessageCreateConsumption::Test(outcomes) => outcomes,
    };
    CloudSyncOutboundConsumeResult {
        outcomes,
        failure: None,
    }
}

fn map_cloud_sync_native_save_outcome(
    outcome: rustpush::cloud_messages::CloudMessagesSaveOutcome,
    hasher: &crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
) -> CloudSyncOutboundSaveOutcome {
    use rustpush::cloud_messages::CloudMessagesSaveResult as NativeResult;

    let (disposition, failure_class, retry_after_seconds, server_record_id_hash, etag_hash) =
        match outcome.result {
            NativeResult::Succeeded(receipt) => {
                let server_record_id_hash = hasher.server_record_id_hash(receipt.record_name());
                match hasher.canonical_etag_hash(receipt.etag()) {
                    Ok(etag_hash) => (
                        CloudSyncOutboundSaveDisposition::Succeeded,
                        None,
                        None,
                        Some(server_record_id_hash),
                        Some(etag_hash.value().to_owned()),
                    ),
                    Err(_) => (
                        CloudSyncOutboundSaveDisposition::UnknownOutcome,
                        Some(CloudSyncOutboundFailureClass::Unknown),
                        None,
                        None,
                        None,
                    ),
                }
            }
            NativeResult::UnknownOutcome {
                failure_class,
                retry_after,
            } => (
                CloudSyncOutboundSaveDisposition::UnknownOutcome,
                failure_class.map(map_cloud_sync_outbound_failure_class),
                retry_after.map(|value| value.as_secs()),
                None,
                None,
            ),
            NativeResult::Failed {
                failure_class,
                retry_after,
                ..
            } => (
                CloudSyncOutboundSaveDisposition::Failed,
                failure_class.map(map_cloud_sync_outbound_failure_class),
                retry_after.map(|value| value.as_secs()),
                None,
                None,
            ),
        };
    CloudSyncOutboundSaveOutcome {
        local_operation_id: outcome.local_operation_id,
        apple_operation_uuid: outcome.apple_operation_uuid,
        disposition,
        failure_class,
        retry_after_seconds,
        server_record_id_hash,
        etag_hash,
    }
}

#[cfg(test)]
mod cloud_sync_writer_mutation_capability_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const LOCAL_OPERATION_ID: &str = "obcs2.op.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const APPLE_OPERATION_UUID: &str = "AAAAAAAA-BBBB-4CCC-8DDD-000000000001";

    async fn consume_test_handle(
        handle: &CloudSyncPreparedMessageCreateHandle,
        token: String,
    ) -> CloudSyncOutboundConsumeResult {
        cloud_sync_consume_prepared_message_create_with_hasher(handle, token, |_| {
            crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher::new(
                b"capability-test-only-install-key",
            )
            .map_err(|_| ())
        })
        .await
    }

    #[test]
    fn native_owner_revalidates_exact_container_around_submission() {
        let source = include_str!("api.rs");
        let start = source
            .find("impl CloudSyncPreparedMessageCreateOwner")
            .expect("prepared-owner implementation");
        let end = source[start..]
            .find("impl std::fmt::Debug for CloudSyncPreparedMessageCreateHandle")
            .expect("following prepared-handle implementation");
        let owner = &source[start..start + end];
        let first_validation = owner
            .find("validate_writer_preparation_binding")
            .expect("pre-submission container validation");
        let submission = owner
            .find(".run(prepared.consume_once())")
            .expect("native submission");
        let second_validation = owner[submission..]
            .find("validate_writer_preparation_binding")
            .map(|offset| submission + offset)
            .expect("post-submission container validation");

        assert!(first_validation < submission);
        assert!(submission < second_validation);
        assert_eq!(
            owner.matches("validate_writer_preparation_binding").count(),
            2
        );
    }

    fn capability_sha256(token: &str) -> String {
        Sha256::digest(token.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    fn write_valid_fence(
        directory: &std::path::Path,
        token: &str,
        account_fingerprint: &str,
        protected_store_identity: &str,
        prepared_handle_binding_sha256: &str,
    ) -> PathBuf {
        let path = directory.join(CLOUD_SYNC_WRITER_MUTATION_FENCE_FILE);
        let encoded = serde_json::json!({
            "accountFingerprint": account_fingerprint,
            "capabilitySha256": capability_sha256(token),
            "container": "com.apple.messages.cloud",
            "database": "private",
            "epoch": 1,
            "owner": "v2",
            "preparedHandleBindingSha256": prepared_handle_binding_sha256,
            "protectedStoreIdentity": protected_store_identity,
            "reconciliationBindingSha256": "9".repeat(64),
            "version": 3,
        });
        fs::write(&path, serde_json::to_vec(&encoded).unwrap()).unwrap();
        path
    }

    fn test_handle(
        directory: &std::path::Path,
        remote_call_count: Arc<AtomicUsize>,
        after_remote_call: Option<Box<dyn FnOnce() + Send>>,
        handle_binding_sha256: &str,
    ) -> CloudSyncPreparedMessageCreateHandle {
        CloudSyncPreparedMessageCreateHandle {
            prepared: tokio::sync::Mutex::new(Some(CloudSyncPreparedMessageCreateOwner::Test {
                remote_call_count,
                after_remote_call,
                outcomes: vec![CloudSyncOutboundSaveOutcome {
                    local_operation_id: LOCAL_OPERATION_ID.to_owned(),
                    apple_operation_uuid: APPLE_OPERATION_UUID.to_owned(),
                    disposition: CloudSyncOutboundSaveDisposition::Succeeded,
                    failure_class: None,
                    retry_after_seconds: None,
                    server_record_id_hash: Some("S".repeat(43)),
                    etag_hash: Some("E".repeat(43)),
                }],
            })),
            storage_directory: directory.to_string_lossy().into_owned(),
            expected_account_fingerprint: "account-fingerprint".to_owned(),
            expected_protected_store_identity: "protected-store".to_owned(),
            expected_handle_binding_sha256: handle_binding_sha256.to_owned(),
            expected_reconciliation_binding_sha256: std::sync::OnceLock::new(),
        }
    }

    #[test]
    fn dart_v3_fence_requires_stable_reconciliation_binding() {
        let directory = tempfile::tempdir().unwrap();
        let token = "a".repeat(64);
        let handle_binding_sha256 = "d".repeat(64);
        let fence_path = write_valid_fence(
            directory.path(),
            &token,
            "account-fingerprint",
            "protected-store",
            &handle_binding_sha256,
        );
        let handle = test_handle(
            directory.path(),
            Arc::new(AtomicUsize::new(0)),
            None,
            &handle_binding_sha256,
        );

        assert!(cloud_sync_writer_mutation_capability_is_valid(
            &handle, &token
        ));

        let mut fence: serde_json::Value =
            serde_json::from_slice(&fs::read(&fence_path).unwrap()).unwrap();
        fence["version"] = serde_json::json!(2);
        fs::write(&fence_path, serde_json::to_vec(&fence).unwrap()).unwrap();
        assert!(!cloud_sync_writer_mutation_capability_is_valid(
            &handle, &token
        ));

        fence["version"] = serde_json::json!(3);
        fence
            .as_object_mut()
            .unwrap()
            .remove("reconciliationBindingSha256");
        fs::write(&fence_path, serde_json::to_vec(&fence).unwrap()).unwrap();
        assert!(!cloud_sync_writer_mutation_capability_is_valid(
            &handle, &token
        ));

        fence["reconciliationBindingSha256"] = serde_json::json!("8".repeat(64));
        fs::write(&fence_path, serde_json::to_vec(&fence).unwrap()).unwrap();
        assert!(!cloud_sync_writer_mutation_capability_is_valid(
            &handle, &token
        ));

        fence["reconciliationBindingSha256"] = serde_json::json!("A".repeat(64));
        fs::write(&fence_path, serde_json::to_vec(&fence).unwrap()).unwrap();
        let fresh_handle = test_handle(
            directory.path(),
            Arc::new(AtomicUsize::new(0)),
            None,
            &handle_binding_sha256,
        );
        assert!(!cloud_sync_writer_mutation_capability_is_valid(
            &fresh_handle,
            &token
        ));
    }

    #[tokio::test]
    async fn random_capability_cannot_consume_handle_or_reach_remote_path() {
        let directory = tempfile::tempdir().unwrap();
        let valid_token = "a".repeat(64);
        let random_token = "b".repeat(64);
        let handle_binding_sha256 = "d".repeat(64);
        write_valid_fence(
            directory.path(),
            &valid_token,
            "account-fingerprint",
            "protected-store",
            &handle_binding_sha256,
        );
        let remote_call_count = Arc::new(AtomicUsize::new(0));
        let handle = test_handle(
            directory.path(),
            remote_call_count.clone(),
            None,
            &handle_binding_sha256,
        );

        let rejected =
            cloud_sync_consume_prepared_message_create_with_hasher(&handle, random_token, |_| {
                panic!("invalid capability must not reach protected storage")
            })
            .await;

        assert_eq!(
            rejected.failure,
            Some(CloudSyncOutboundSafeCode::MutationCapabilityInvalid)
        );
        assert!(rejected.outcomes.is_empty());
        assert_eq!(remote_call_count.load(Ordering::SeqCst), 0);
        assert!(handle.prepared.lock().await.is_some());

        let accepted = consume_test_handle(&handle, valid_token).await;

        assert_eq!(accepted.failure, None);
        assert_eq!(accepted.outcomes.len(), 1);
        assert_eq!(
            accepted.outcomes[0].disposition,
            CloudSyncOutboundSaveDisposition::Succeeded
        );
        assert_eq!(
            accepted.outcomes[0].server_record_id_hash.as_deref(),
            Some("SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS")
        );
        assert_eq!(
            accepted.outcomes[0].etag_hash.as_deref(),
            Some("EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE")
        );
        assert_eq!(remote_call_count.load(Ordering::SeqCst), 1);
        assert!(handle.prepared.lock().await.is_none());
    }

    #[tokio::test]
    async fn capability_loss_after_remote_call_never_reports_success() {
        let directory = tempfile::tempdir().unwrap();
        let valid_token = "c".repeat(64);
        let handle_binding_sha256 = "e".repeat(64);
        let fence_path = write_valid_fence(
            directory.path(),
            &valid_token,
            "account-fingerprint",
            "protected-store",
            &handle_binding_sha256,
        );
        let remote_call_count = Arc::new(AtomicUsize::new(0));
        let handle = test_handle(
            directory.path(),
            remote_call_count.clone(),
            Some(Box::new(move || fs::remove_file(fence_path).unwrap())),
            &handle_binding_sha256,
        );

        let result = consume_test_handle(&handle, valid_token).await;

        assert_eq!(remote_call_count.load(Ordering::SeqCst), 1);
        assert_eq!(
            result.failure,
            Some(CloudSyncOutboundSafeCode::MutationCapabilityInvalid)
        );
        assert!(result.outcomes.is_empty());
        assert!(handle.prepared.lock().await.is_none());
    }

    #[tokio::test]
    async fn capability_for_one_prepared_handle_cannot_consume_another() {
        let directory = tempfile::tempdir().unwrap();
        let valid_token = "f".repeat(64);
        let binding_a = "1".repeat(64);
        let binding_b = "2".repeat(64);
        write_valid_fence(
            directory.path(),
            &valid_token,
            "account-fingerprint",
            "protected-store",
            &binding_a,
        );
        let remote_call_count = Arc::new(AtomicUsize::new(0));
        let handle_b = test_handle(
            directory.path(),
            remote_call_count.clone(),
            None,
            &binding_b,
        );

        let rejected = consume_test_handle(&handle_b, valid_token.clone()).await;

        assert_eq!(
            rejected.failure,
            Some(CloudSyncOutboundSafeCode::MutationCapabilityInvalid)
        );
        assert!(rejected.outcomes.is_empty());
        assert_eq!(remote_call_count.load(Ordering::SeqCst), 0);
        assert!(handle_b.prepared.lock().await.is_some());

        let handle_a = test_handle(
            directory.path(),
            remote_call_count.clone(),
            None,
            &binding_a,
        );
        let accepted = consume_test_handle(&handle_a, valid_token).await;
        assert_eq!(accepted.failure, None);
        assert_eq!(accepted.outcomes.len(), 1);
        assert_eq!(remote_call_count.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn chat_owner_uses_shared_scope_capability_and_single_use_fences() {
        let directory = tempfile::tempdir().unwrap();
        let token = "a".repeat(64);
        let binding = "d".repeat(64);
        let calls = Arc::new(AtomicUsize::new(0));
        let mut handle = test_handle(directory.path(), calls.clone(), None, &binding);
        handle.expected_account_fingerprint = "A".repeat(43);
        handle.expected_protected_store_identity = "S".repeat(43);
        let chat_operation = crate::cloud_sync_outbound_chat::initial_chat_create_operation_id(
            &handle.expected_account_fingerprint,
            &"L".repeat(43),
        )
        .unwrap();
        if let Some(CloudSyncPreparedMessageCreateOwner::Test { outcomes, .. }) =
            handle.prepared.lock().await.as_mut()
        {
            outcomes[0].local_operation_id = chat_operation.clone();
        } else {
            panic!("fixture owner missing");
        }
        let path = write_valid_fence(
            directory.path(),
            &token,
            &handle.expected_account_fingerprint,
            &handle.expected_protected_store_identity,
            &binding,
        );
        // Freeze the same original-submission binding before checking replay.
        assert!(cloud_sync_writer_mutation_capability_is_valid(
            &handle, &token
        ));
        let original: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        for (field, replacement) in [
            ("accountFingerprint", "B".repeat(43)),
            ("protectedStoreIdentity", "T".repeat(43)),
            ("preparedHandleBindingSha256", "e".repeat(64)),
            ("reconciliationBindingSha256", "8".repeat(64)),
            ("capabilitySha256", "0".repeat(64)),
            ("owner", "legacy".to_owned()),
            ("container", "other.container".to_owned()),
            ("database", "public".to_owned()),
        ] {
            let mut changed = original.clone();
            changed[field] = serde_json::json!(replacement);
            fs::write(&path, serde_json::to_vec(&changed).unwrap()).unwrap();
            let result = consume_test_handle(&handle, token.clone()).await;
            assert_eq!(
                result.failure,
                Some(CloudSyncOutboundSafeCode::MutationCapabilityInvalid)
            );
            assert!(result.outcomes.is_empty());
            assert!(handle.prepared.lock().await.is_some());
            assert_eq!(calls.load(Ordering::SeqCst), 0);
        }
        fs::write(&path, serde_json::to_vec(&original).unwrap()).unwrap();
        let accepted = consume_test_handle(&handle, token.clone()).await;
        assert_eq!(accepted.failure, None);
        assert_eq!(accepted.outcomes[0].local_operation_id, chat_operation);
        let replay = consume_test_handle(&handle, token).await;
        assert_eq!(
            replay.failure,
            Some(CloudSyncOutboundSafeCode::AlreadyConsumed)
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn protected_storage_failure_preserves_owner_without_remote_submission() {
        let directory = tempfile::tempdir().unwrap();
        let valid_token = "a".repeat(64);
        let binding = "d".repeat(64);
        write_valid_fence(
            directory.path(),
            &valid_token,
            "account-fingerprint",
            "protected-store",
            &binding,
        );
        let remote_calls = Arc::new(AtomicUsize::new(0));
        let handle = test_handle(directory.path(), remote_calls.clone(), None, &binding);
        let rejected = cloud_sync_consume_prepared_message_create_with_hasher(
            &handle,
            valid_token.clone(),
            |_| Err(()),
        )
        .await;
        assert_eq!(
            rejected.failure,
            Some(CloudSyncOutboundSafeCode::ProtectedStorage)
        );
        assert!(rejected.outcomes.is_empty());
        assert_eq!(remote_calls.load(Ordering::SeqCst), 0);
        assert!(handle.prepared.lock().await.is_some());

        let accepted = consume_test_handle(&handle, valid_token.clone()).await;
        assert_eq!(accepted.failure, None);
        let repeated = consume_test_handle(&handle, valid_token).await;
        assert_eq!(
            repeated.failure,
            Some(CloudSyncOutboundSafeCode::AlreadyConsumed)
        );
        assert_eq!(remote_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn release_after_storage_failure_drops_owner_without_submitting_or_changing_fence() {
        let directory = tempfile::tempdir().unwrap();
        let token = "a".repeat(64);
        let binding = "d".repeat(64);
        let fence_path = write_valid_fence(directory.path(), &token,
            "account-fingerprint", "protected-store", &binding);
        let original_fence = fs::read(&fence_path).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let handle = test_handle(directory.path(), calls.clone(), None, &binding);
        let failed = cloud_sync_consume_prepared_message_create_with_hasher(
            &handle, token.clone(), |_| Err(()),
        ).await;
        assert_eq!(failed.failure, Some(CloudSyncOutboundSafeCode::ProtectedStorage));
        assert!(handle.prepared.lock().await.is_some());
        assert!(cloud_sync_release_prepared_message_create(&handle).await);
        assert!(handle.prepared.lock().await.is_none());
        assert!(!cloud_sync_release_prepared_message_create(&handle).await);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(fs::read(&fence_path).unwrap(), original_fence);
        let rejected = consume_test_handle(&handle, token).await;
        assert_eq!(rejected.failure, Some(CloudSyncOutboundSafeCode::AlreadyConsumed));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(fs::read(&fence_path).unwrap(), original_fence);
    }

    #[tokio::test]
    async fn release_after_consumption_is_an_idempotent_noop() {
        let directory = tempfile::tempdir().unwrap();
        let token = "a".repeat(64);
        let binding = "d".repeat(64);
        let fence_path = write_valid_fence(directory.path(), &token,
            "account-fingerprint", "protected-store", &binding);
        let original_fence = fs::read(&fence_path).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let handle = test_handle(directory.path(), calls.clone(), None, &binding);
        assert_eq!(consume_test_handle(&handle, token).await.failure, None);
        assert!(!cloud_sync_release_prepared_message_create(&handle).await);
        assert!(!cloud_sync_release_prepared_message_create(&handle).await);
        assert!(handle.prepared.lock().await.is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(fs::read(&fence_path).unwrap(), original_fence);
    }

    #[tokio::test]
    async fn release_cannot_cancel_an_already_taken_consume_owner() {
        let directory = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let handle = test_handle(directory.path(), calls.clone(), None, &"d".repeat(64));
        // Exercise the exact ownership-transfer boundary used by consume.
        // Once taken, the owner no longer belongs to the releasable handle.
        let owner = handle.prepared.lock().await.take().unwrap();
        assert!(!cloud_sync_release_prepared_message_create(&handle).await);
        assert!(!cloud_sync_release_prepared_message_create(&handle).await);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert!(owner.consume_once().await.is_ok());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(!cloud_sync_release_prepared_message_create(&handle).await);
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
        server_record_id_hash: None,
        etag_hash: None,
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

fn is_valid_cloud_sync_chat_create_request(
    expected_account_fingerprint: &str,
    request_uuid: &str,
    request_timeout_seconds: u64,
    inputs: &[CloudSyncPreparedMessageCreateInput],
) -> bool {
    inputs.len() == 1
        && (1..=300).contains(&request_timeout_seconds)
        && is_valid_cloud_sync_chat_create_input(
            expected_account_fingerprint,
            request_uuid,
            &inputs[0],
        )
}

fn is_valid_cloud_sync_chat_create_input(
    expected_account_fingerprint: &str,
    request_uuid: &str,
    input: &CloudSyncPreparedMessageCreateInput,
) -> bool {
    input.attachment_parent_context.is_none()
        && input.attachment_parent_group_proof.is_none()
        && is_cloud_sync_operation_id(&input.local_operation_id)
        && crate::cloud_sync_outbound_chat::initial_chat_create_operation_id(
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
    FoundPayloadDigest {
        payload_sha256: String,
        server_record_id_hash: String,
        etag_hash: String,
    },
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
    let (
        disposition,
        failure_class,
        retry_after_seconds,
        decisive,
        server_record_id_hash,
        etag_hash,
    ) = match observation {
        CloudSyncReconcileObservation::FoundPayloadDigest {
            payload_sha256,
            server_record_id_hash,
            etag_hash,
        } if payload_sha256 == expected_payload_sha256 => (
            CloudSyncOutboundReconcileDisposition::Committed,
            None,
            None,
            true,
            Some(server_record_id_hash),
            Some(etag_hash),
        ),
        CloudSyncReconcileObservation::FoundPayloadDigest { .. }
        | CloudSyncReconcileObservation::DivergedRecord => (
            CloudSyncOutboundReconcileDisposition::Diverged,
            Some(CloudSyncOutboundFailureClass::Conflict),
            None,
            true,
            None,
            None,
        ),
        CloudSyncReconcileObservation::NotFound => (
            CloudSyncOutboundReconcileDisposition::NotApplied,
            None,
            None,
            true,
            None,
            None,
        ),
        CloudSyncReconcileObservation::Unresolved {
            failure_class,
            retry_after,
        } => (
            CloudSyncOutboundReconcileDisposition::Unresolved,
            failure_class.map(map_cloud_sync_outbound_failure_class),
            retry_after.map(|value| value.as_secs()),
            false,
            None,
            None,
        ),
        CloudSyncReconcileObservation::UnknownFailure => (
            CloudSyncOutboundReconcileDisposition::Unresolved,
            Some(CloudSyncOutboundFailureClass::Unknown),
            None,
            false,
            None,
            None,
        ),
    };
    CloudSyncOutboundReconcileResult {
        disposition: Some(disposition),
        protected_proof_reference: decisive.then_some(protected_proof_reference),
        failure_class,
        retry_after_seconds,
        server_record_id_hash,
        etag_hash,
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
    let writer_binding = match cloud_messages_client
        .warm_message_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(_) => {
            return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
        }
    };
    let auth_after_preparation =
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
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    let container_scoped_user_id = writer_binding.container_scoped_user_id().to_owned();

    let opened = match cloud_sync_open_message_create_bound(
        &storage_directory, &auth_after_preparation, &container_scoped_user_id, &input,
    ) {
        Ok(opened) => opened,
        Err(code) => return cloud_sync_reconcile_failure(code),
    };
    let expected_message = opened.message();
    let server_record_name = opened.record_name();
    let hasher =
        match crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
            Ok(hasher) => hasher,
            Err(_) => {
                return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::ProtectedStorage)
            }
        };
    use rustpush::cloud_messages::CloudMessageRecordLookup;
    let observation = match cloud_messages_client
        .lookup_message_record(&writer_binding, &server_record_name)
        .await
    {
        Ok(CloudMessageRecordLookup::Found(message, receipt)) => {
            let differences = crate::cloud_sync_outbound::message_readback_differences(&expected_message, &message);
            if !differences.is_empty() {
                warn!("Cloud Sync message readback differing_fields={}", differences.join(","));
            }
            let receipt_server_record_id_hash = hasher.server_record_id_hash(receipt.record_name());
            let receipt_etag_hash = hasher
                .canonical_etag_hash(receipt.etag())
                .map(|hash| hash.value().to_owned());
            if receipt_server_record_id_hash != input.server_record_id_hash {
                CloudSyncReconcileObservation::DivergedRecord
            } else {
                match (
                    opened.verify_readback(message, &input.payload_sha256),
                    receipt_etag_hash,
                ) {
                    (Ok(payload_sha256), Ok(etag_hash)) => {
                        CloudSyncReconcileObservation::FoundPayloadDigest {
                            payload_sha256,
                            server_record_id_hash: receipt_server_record_id_hash,
                            etag_hash,
                        }
                    }
                    _ => CloudSyncReconcileObservation::DivergedRecord,
                }
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
    let auth_after_lookup =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory).await {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_reconcile_failure(
                    CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                )
            }
        };
    if !cloud_sync_auth_identity_remains_exact(
        &auth_after_preparation,
        &auth_after_lookup,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    // Even NotFound cannot release a replay proof after source/context loss.
    if let Some(context) = &input.attachment_parent_context {
        // Its storage_directory was compared to the passed directory before
        // lookup and the immutable context has not changed across that await.
        if let Err(code) = cloud_sync_open_message_create_bound(
            &context.storage_directory, &auth_after_lookup, &container_scoped_user_id, &input,
        ) { return cloud_sync_reconcile_failure(code); }
    }
    classify_cloud_sync_reconcile_observation(
        observation,
        &input.payload_sha256,
        input.protected_payload_reference,
    )
}

fn cloud_sync_chat_lookup_observation(
    lookup: Result<rustpush::cloud_messages::CloudChatRecordLookup, rustpush::PushError>,
    original_record_name: &str,
    input: &CloudSyncPreparedMessageCreateInput,
    hasher: &crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
) -> CloudSyncReconcileObservation {
    use rustpush::cloud_messages::CloudChatRecordLookup;
    match lookup {
        Ok(CloudChatRecordLookup::Found(chat, receipt)) => {
            let receipt_server_record_id_hash = hasher.server_record_id_hash(receipt.record_name());
            let receipt_etag_hash = hasher
                .canonical_etag_hash(receipt.etag())
                .map(|hash| hash.value().to_owned());
            if receipt_server_record_id_hash != input.server_record_id_hash {
                CloudSyncReconcileObservation::DivergedRecord
            } else {
                match (
                    crate::cloud_sync_outbound_chat::verify_chat_readback(
                        &chat,
                        receipt.record_name(),
                        original_record_name,
                        &input.payload_sha256,
                    ),
                    receipt_etag_hash,
                ) {
                    (Ok(payload_sha256), Ok(etag_hash)) => {
                        CloudSyncReconcileObservation::FoundPayloadDigest {
                            payload_sha256,
                            server_record_id_hash: receipt_server_record_id_hash,
                            etag_hash,
                        }
                    }
                    _ => CloudSyncReconcileObservation::DivergedRecord,
                }
            }
        }
        Ok(CloudChatRecordLookup::NotFound) => CloudSyncReconcileObservation::NotFound,
        Ok(CloudChatRecordLookup::Unresolved {
            failure_class,
            retry_after,
        }) => CloudSyncReconcileObservation::Unresolved {
            failure_class,
            retry_after,
        },
        Err(_) => CloudSyncReconcileObservation::UnknownFailure,
    }
}

/// Exact readback of the ORIGINAL protected Chat/name, never a new stage or
/// legacy saver. Only explicit NotFound proves absence. The proof reference
/// identifies the same account/store-scoped, committed envelope, not a bearer
/// authorization to replay. As with messages, the durable caller must supply
/// the original persisted UUIDs and bind this result to that submission via the
/// writer guard's reconciliation fence before releasing it or permitting retry.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_reconcile_chat_create(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    request_uuid: String,
    input: CloudSyncPreparedMessageCreateInput,
) -> CloudSyncOutboundReconcileResult {
    if !is_valid_cloud_sync_chat_create_input(&expected_account_fingerprint, &request_uuid, &input)
    {
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
    let writer_binding = match cloud_messages_client
        .warm_chat_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(_) => {
            return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
        }
    };
    let auth_after_preparation =
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
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
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
    let (expected_chat, server_record_name) =
        match crate::cloud_sync_outbound_chat::open_staged_outbound_chat(
            storage_path.clone(),
            auth_after_preparation.account_fingerprint.clone(),
            &input.protected_payload_reference,
            &input.payload_sha256,
            &input.server_record_id_hash,
        ) {
            Ok(value) => value,
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
        crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind::Chat,
        &expected_chat.guid,
    ) {
        Ok(hash) => hash,
        Err(_) => return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::BindingMismatch),
    };
    if logical_hash.value() != input.logical_entity_key_hash {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    let lookup = cloud_messages_client
        .lookup_chat_record(&writer_binding, &server_record_name)
        .await;
    let observation =
        cloud_sync_chat_lookup_observation(lookup, &server_record_name, &input, &hasher);
    let auth_after_lookup =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory).await {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_reconcile_failure(
                    CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                )
            }
        };
    if !cloud_sync_auth_identity_remains_exact(
        &auth_after_preparation,
        &auth_after_lookup,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    classify_cloud_sync_reconcile_observation(
        observation,
        &input.payload_sha256,
        input.protected_payload_reference,
    )
}

fn cloud_sync_attachment_lookup_observation(
    lookup: Result<rustpush::cloud_messages::CloudAttachmentRecordLookup, rustpush::PushError>,
    expected: &rustpush::cloud_messages::CloudAttachment,
    original_record_name: &str,
    input: &CloudSyncPreparedMessageCreateInput,
    hasher: &crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
) -> CloudSyncReconcileObservation {
    use rustpush::cloud_messages::CloudAttachmentRecordLookup;
    match lookup {
        Ok(CloudAttachmentRecordLookup::Found(actual, receipt)) => {
            let record_hash = hasher.server_record_id_hash(receipt.record_name());
            let etag_hash = hasher.canonical_etag_hash(receipt.etag());
            if record_hash != input.server_record_id_hash {
                return CloudSyncReconcileObservation::DivergedRecord;
            }
            match (
                crate::cloud_sync_outbound_attachment::verify_attachment_readback(
                    expected, &actual, receipt.record_name(), original_record_name, &input.payload_sha256,
                ),
                etag_hash,
            ) {
                (Ok(payload_sha256), Ok(etag)) => CloudSyncReconcileObservation::FoundPayloadDigest {
                    payload_sha256,
                    server_record_id_hash: record_hash,
                    etag_hash: etag.value().to_owned(),
                },
                _ => CloudSyncReconcileObservation::DivergedRecord,
            }
        }
        Ok(CloudAttachmentRecordLookup::NotFound) => CloudSyncReconcileObservation::NotFound,
        Ok(CloudAttachmentRecordLookup::Unresolved { failure_class, retry_after }) =>
            CloudSyncReconcileObservation::Unresolved { failure_class, retry_after },
        Err(_) => CloudSyncReconcileObservation::UnknownFailure,
    }
}

/// Reads back the exact saved attachment against its original protected upload
/// result. NotFound is record absence only, never permission to upload bytes again.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_reconcile_attachment_create(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    request_uuid: String,
    input: CloudSyncPreparedMessageCreateInput,
) -> CloudSyncOutboundReconcileResult {
    if !is_valid_cloud_sync_attachment_create_input(&expected_account_fingerprint, &request_uuid, &input)
    {
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
    let writer_binding = match cloud_messages_client
        .warm_attachment_writer_preparation_lookup_only()
        .await
    {
        Ok(binding) => binding,
        Err(_) => {
            return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::NativeAuthUnavailable)
        }
    };
    let auth_after_preparation =
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
    if !cloud_sync_auth_identity_remains_exact(
        &auth,
        &auth_after_preparation,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
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
    let (expected_attachment, server_record_name) =
        match crate::cloud_sync_outbound_attachment::open_staged_outbound_attachment(
            storage_path.clone(),
            auth_after_preparation.account_fingerprint.clone(),
            &input.protected_payload_reference,
            &input.payload_sha256,
            &input.server_record_id_hash,
        ) {
            Ok(value) => value,
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
    let logical_hash = match hasher.canonical_attachment_key_hash(&expected_attachment.cm.0.guid) {
        Ok(hash) => hash,
        Err(_) => return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::BindingMismatch),
    };
    if logical_hash.value() != input.logical_entity_key_hash {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::BindingMismatch);
    }
    let lookup = cloud_messages_client
        .lookup_attachment_record(&writer_binding, &server_record_name)
        .await;
    let observation =
        cloud_sync_attachment_lookup_observation(lookup, &expected_attachment, &server_record_name, &input, &hasher);
    let auth_after_lookup =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory).await {
            Ok(auth) => auth,
            Err(_) => {
                return cloud_sync_reconcile_failure(
                    CloudSyncOutboundSafeCode::NativeAuthUnavailable,
                )
            }
        };
    if !cloud_sync_auth_identity_remains_exact(
        &auth_after_preparation,
        &auth_after_lookup,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
    if cloud_messages_client
        .validate_writer_preparation_binding(&writer_binding)
        .await
        .is_err()
    {
        return cloud_sync_reconcile_failure(CloudSyncOutboundSafeCode::InvalidScope);
    }
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
            attachment_parent_context: None,
            attachment_parent_group_proof: None,
        }
    }

    fn chat_input() -> CloudSyncPreparedMessageCreateInput {
        let mut chat = input();
        chat.local_operation_id =
            crate::cloud_sync_outbound_chat::initial_chat_create_operation_id(
                &account(),
                &chat.logical_entity_key_hash,
            )
            .unwrap();
        chat
    }

    fn attachment_input() -> CloudSyncPreparedMessageCreateInput {
        let mut attachment = input();
        attachment.local_operation_id =
            crate::cloud_sync_outbound_attachment::initial_attachment_create_operation_id(
                &account(),
                &attachment.logical_entity_key_hash,
            ).unwrap();
        attachment
    }

    #[test]
    fn attachment_prepare_accepts_only_its_exact_initial_create() {
        let attachment = attachment_input();
        for timeout in [1, 300] {
            assert!(is_valid_cloud_sync_attachment_create_request(
                &account(), REQUEST_UUID, timeout, &[attachment.clone()]
            ));
        }
        for timeout in [0, 301] {
            assert!(!is_valid_cloud_sync_attachment_create_request(
                &account(), REQUEST_UUID, timeout, &[attachment.clone()]
            ));
        }
        for inputs in [vec![], vec![attachment.clone(), attachment.clone()], vec![input()], vec![chat_input()]] {
            assert!(!is_valid_cloud_sync_attachment_create_request(
                &account(), REQUEST_UUID, 30, &inputs
            ));
        }
        assert!(!is_valid_cloud_sync_chat_create_input(&account(), REQUEST_UUID, &attachment));
        assert!(!is_valid_cloud_sync_reconcile_message_create_input(&account(), REQUEST_UUID, &attachment));
        assert!(!is_valid_cloud_sync_attachment_create_input(&"B".repeat(43), REQUEST_UUID, &attachment));

        let mutations: &[fn(&mut CloudSyncPreparedMessageCreateInput)] = &[
            |input| input.local_operation_id = "b".repeat(64),
            |input| input.local_operation_id = format!("op1:{}", "b".repeat(64)),
            |input| input.logical_entity_key_hash = "K".repeat(43),
            |input| input.protected_lease_reference.clear(),
            |input| input.protected_payload_reference.clear(),
            |input| input.protected_server_record_reference = format!("obcs2.ref.{}", "Q".repeat(43)),
            |input| input.payload_sha256 = "not-a-digest".to_owned(),
            |input| input.server_record_id_hash.clear(),
            |input| input.apple_operation_uuid = REQUEST_UUID.to_owned(),
            |input| input.apple_operation_uuid.clear(),
        ];
        for mutate in mutations {
            let mut changed = attachment.clone();
            mutate(&mut changed);
            assert!(!is_valid_cloud_sync_attachment_create_input(&account(), REQUEST_UUID, &changed));
        }
    }

    #[test]
    fn chat_prepare_is_one_initial_create_not_a_message_or_mutation_replay() {
        let chat = chat_input();
        assert!(is_valid_cloud_sync_chat_create_request(
            &account(),
            REQUEST_UUID,
            300,
            &[chat.clone()]
        ));
        assert!(!is_valid_cloud_sync_chat_create_request(
            &account(),
            REQUEST_UUID,
            0,
            &[chat.clone()]
        ));
        assert!(!is_valid_cloud_sync_chat_create_request(
            &account(),
            REQUEST_UUID,
            301,
            &[chat.clone()]
        ));
        assert!(!is_valid_cloud_sync_chat_create_request(
            &account(),
            REQUEST_UUID,
            1,
            &[]
        ));
        assert!(!is_valid_cloud_sync_chat_create_request(
            &account(),
            REQUEST_UUID,
            1,
            &[chat.clone(), chat.clone()]
        ));
        assert!(!is_valid_cloud_sync_chat_create_input(
            &account(),
            REQUEST_UUID,
            &input()
        ));
        assert!(!is_valid_cloud_sync_reconcile_message_create_input(
            &account(),
            REQUEST_UUID,
            &chat
        ));
        let canonical = vec![
            "cloud-sync-initial-create-v1".to_owned(),
            account(),
            "com.apple.messages.cloud".to_owned(),
            "private".to_owned(),
            "chatManateeZone".to_owned(),
            "messages".to_owned(),
            "2".to_owned(),
            "semantic".to_owned(),
            chat.logical_entity_key_hash.clone(),
            "save".to_owned(),
            "1".to_owned(),
        ];
        for (index, replacement) in [
            (0, "cloud-sync-operation-v1"),
            (2, "other.container"),
            (3, "public"),
            (4, "messageManateeZone"),
            (5, "profiles"),
            (6, "1"),
            (7, "shadow"),
            (9, "delete"),
            (10, "2"),
        ] {
            let mut other = canonical.clone();
            other[index] = replacement.to_owned();
            let digest = Sha256::digest(other.join("\u{001f}").as_bytes())
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            let mut changed = chat.clone();
            changed.local_operation_id = format!("op1:{digest}");
            assert!(!is_valid_cloud_sync_chat_create_input(
                &account(),
                REQUEST_UUID,
                &changed
            ));
        }
    }

    #[test]
    fn chat_reconcile_rejects_wrong_scope_references_and_uuid_shapes() {
        let chat = chat_input();
        assert!(!is_valid_cloud_sync_chat_create_input(
            &"B".repeat(43),
            REQUEST_UUID,
            &chat
        ));
        for request in [
            OPERATION_UUID.to_owned(),
            REQUEST_UUID.to_lowercase(),
            "bad".to_owned(),
        ] {
            assert!(!is_valid_cloud_sync_chat_create_input(
                &account(),
                &request,
                &chat
            ));
        }
        let changes: &[fn(&mut CloudSyncPreparedMessageCreateInput)] = &[
            |i| i.local_operation_id = format!("op1:{}", "f".repeat(64)),
            |i| i.logical_entity_key_hash = "M".repeat(43),
            |i| i.protected_lease_reference.clear(),
            |i| i.protected_payload_reference.clear(),
            |i| i.payload_sha256 = "B".repeat(64),
            |i| i.protected_server_record_reference = format!("obcs2.ref.{}", "Q".repeat(43)),
            |i| i.server_record_id_hash.clear(),
            |i| i.apple_operation_uuid = OPERATION_UUID.to_lowercase(),
            |i| i.apple_operation_uuid = REQUEST_UUID.to_owned(),
        ];
        for change in changes {
            let mut changed = chat.clone();
            change(&mut changed);
            assert!(!is_valid_cloud_sync_chat_create_input(
                &account(),
                REQUEST_UUID,
                &changed
            ));
        }
    }

    #[test]
    fn chat_lookup_only_explicit_not_found_can_prove_absence() {
        use rustpush::cloud_messages::CloudChatRecordLookup;
        let chat = chat_input();
        let hasher = crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher::new(
            b"chat-readback-fixture-only-key",
        )
        .unwrap();
        for (lookup, expected) in [
            (
                Ok(CloudChatRecordLookup::NotFound),
                CloudSyncOutboundReconcileDisposition::NotApplied,
            ),
            (
                Ok(CloudChatRecordLookup::Unresolved {
                    failure_class: Some(CloudKitFailureClass::Authentication),
                    retry_after: None,
                }),
                CloudSyncOutboundReconcileDisposition::Unresolved,
            ),
            (
                Ok(CloudChatRecordLookup::Unresolved {
                    failure_class: Some(CloudKitFailureClass::TransientServer),
                    retry_after: Some(Duration::from_secs(7)),
                }),
                CloudSyncOutboundReconcileDisposition::Unresolved,
            ),
            (
                Err(rustpush::PushError::BadMsg),
                CloudSyncOutboundReconcileDisposition::Unresolved,
            ),
        ] {
            let result = classify_cloud_sync_reconcile_observation(
                cloud_sync_chat_lookup_observation(
                    lookup,
                    "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
                    &chat,
                    &hasher,
                ),
                &chat.payload_sha256,
                chat.protected_payload_reference.clone(),
            );
            assert_eq!(result.disposition, Some(expected));
            assert_eq!(
                result.protected_proof_reference,
                (expected == CloudSyncOutboundReconcileDisposition::NotApplied)
                    .then(|| chat.protected_payload_reference.clone())
            );
            assert_eq!(result.server_record_id_hash, None);
            assert_eq!(result.etag_hash, None);
        }
    }

    #[test]
    fn attachment_lookup_does_not_turn_transport_failure_into_absence() {
        use rustpush::cloud_messages::{CloudAttachment, CloudAttachmentRecordLookup};
        let input = attachment_input();
        let hasher = crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher::new(
            b"attachment-readback-fixture-key",
        ).unwrap();
        for (lookup, expected) in [
            (Ok(CloudAttachmentRecordLookup::NotFound), CloudSyncOutboundReconcileDisposition::NotApplied),
            (Ok(CloudAttachmentRecordLookup::Unresolved {
                failure_class: Some(CloudKitFailureClass::Authentication), retry_after: None,
            }), CloudSyncOutboundReconcileDisposition::Unresolved),
            (Ok(CloudAttachmentRecordLookup::Unresolved {
                failure_class: Some(CloudKitFailureClass::TransientServer), retry_after: Some(Duration::from_secs(7)),
            }), CloudSyncOutboundReconcileDisposition::Unresolved),
            (Err(rustpush::PushError::BadMsg), CloudSyncOutboundReconcileDisposition::Unresolved),
        ] {
            let result = classify_cloud_sync_reconcile_observation(
                cloud_sync_attachment_lookup_observation(
                    lookup, &CloudAttachment::default(),
                    "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", &input, &hasher,
                ),
                &input.payload_sha256, input.protected_payload_reference.clone(),
            );
            assert_eq!(result.disposition, Some(expected));
            assert_eq!(result.protected_proof_reference,
                (expected == CloudSyncOutboundReconcileDisposition::NotApplied)
                    .then(|| input.protected_payload_reference.clone()));
            assert_eq!(result.server_record_id_hash, None);
            assert_eq!(result.etag_hash, None);
        }
    }

    #[test]
    fn chat_auth_proof_rejects_account_store_and_native_session_drift() {
        let before = CloudSyncNativeAuthMetadata {
            native_session_id: "N".repeat(43),
            account_fingerprint: account(),
            protected_store_identity: "S".repeat(43),
        };
        assert!(cloud_sync_auth_identity_remains_exact(
            &before,
            &before,
            &account(),
            &"S".repeat(43)
        ));
        for (session, account_fingerprint, store) in [
            ("M".repeat(43), account(), "S".repeat(43)),
            ("N".repeat(43), "B".repeat(43), "S".repeat(43)),
            ("N".repeat(43), account(), "T".repeat(43)),
        ] {
            let after = CloudSyncNativeAuthMetadata {
                native_session_id: session,
                account_fingerprint,
                protected_store_identity: store,
            };
            assert!(!cloud_sync_auth_identity_remains_exact(
                &before,
                &after,
                &account(),
                &"S".repeat(43)
            ));
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
        let server_record_id_hash = "S".repeat(43);
        let etag_hash = "E".repeat(43);
        let committed = classify_cloud_sync_reconcile_observation(
            CloudSyncReconcileObservation::FoundPayloadDigest {
                payload_sha256: expected_digest.clone(),
                server_record_id_hash: server_record_id_hash.clone(),
                etag_hash: etag_hash.clone(),
            },
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
        assert_eq!(committed.server_record_id_hash, Some(server_record_id_hash));
        assert_eq!(committed.etag_hash, Some(etag_hash));

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
        assert_eq!(absent.server_record_id_hash, None);
        assert_eq!(absent.etag_hash, None);
    }

    #[test]
    fn divergent_or_malformed_found_records_quarantine_as_conflicts() {
        for observation in [
            CloudSyncReconcileObservation::FoundPayloadDigest {
                payload_sha256: "c".repeat(64),
                server_record_id_hash: "S".repeat(43),
                etag_hash: "E".repeat(43),
            },
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
            assert_eq!(result.server_record_id_hash, None);
            assert_eq!(result.etag_hash, None);
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
        assert_eq!(transient.server_record_id_hash, None);
        assert_eq!(transient.etag_hash, None);

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
        assert_eq!(failed.server_record_id_hash, None);
        assert_eq!(failed.etag_hash, None);
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
        Native::ReadAuthenticationScope => CloudSyncProtectedSafeCode::ReadAuthenticationScope,
        Native::NativeAuthUnavailable => CloudSyncProtectedSafeCode::NativeAuthUnavailable,
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
        protected_reset_proof_reference: failure
            .protected_reset_proof_reference()
            .map(str::to_owned),
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
        protected_reset_proof_reference: None,
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

/// Windows-only read diagnostic. Compares bounded feed variants without
/// persisting tokens, projecting records, or returning account content.
pub async fn cloud_sync_windows_probe_message_feed(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: String,
    expected_account_fingerprint: String,
    generation: u64,
    checkpoint_reference: String,
    expected_record_id_hash: String,
) -> anyhow::Result<String> {
    use crate::cloud_sync_native_fetch::{CloudNativeFetchRequest, CloudNativeProtectionScope, CloudNativeStream};
    if !is_cloud_sync_windows_dev_profile(&storage_directory) || generation == 0 ||
        expected_record_id_hash.len() != 43 || !expected_record_id_hash.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-')) {
        return Err(anyhow!("cloud_sync_windows_feed_probe_request_invalid"));
    }
    let permit = acquire_cloudkit_read_authentication(native_writer_pause_token)
        .map_err(|_| anyhow!("cloud_sync_windows_feed_probe_auth_failed"))?;
    let auth = cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone()).await
        .map_err(|_| anyhow!("cloud_sync_windows_feed_probe_auth_failed"))?;
    if auth.account_fingerprint != expected_account_fingerprint {
        return Err(anyhow!("cloud_sync_windows_feed_probe_account_mismatch"));
    }
    let scope = CloudNativeProtectionScope::new(auth.account_fingerprint, CloudNativeStream::Messages)
        .map_err(|_| anyhow!("cloud_sync_windows_feed_probe_request_invalid"))?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone())
        .map_err(|_| anyhow!("cloud_sync_windows_feed_probe_protector_failed"))?;
    let request = CloudNativeFetchRequest::new(CloudNativeStream::Messages, &scope,
        generation, Some(&checkpoint_reference), 200);
    crate::cloud_sync_native_fetch::cloud_sync_windows_probe_feed(cloud_messages_client,
        &permit, PathBuf::from(storage_directory), &hasher, &request, &expected_record_id_hash).await
}

/// Fetches and protects one bounded CloudKit page for the separately compile-
/// gated, non-projecting shadow diagnostic. Semantic projection must use
/// `cloud_sync_fetch_protected_page_under_writer_pause` instead.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_fetch_protected_page(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
    expected_account_fingerprint: String,
    stream: String,
    generation: u64,
    previous_checkpoint_reference: Option<String>,
    maximum_changes: u32,
) -> CloudSyncProtectedFetchResult {
    cloud_sync_fetch_protected_page_inner(
        cloud_messages_client,
        None,
        storage_directory,
        expected_account_fingerprint,
        stream,
        generation,
        previous_checkpoint_reference,
        maximum_changes,
    )
    .await
}

/// Fetches and protects one bounded semantic CloudKit page while holding a
/// non-cloneable read-authentication permit for the exact active native writer
/// pause. Missing, stale, or foreign pause tokens fail before authentication or
/// network work. No general-container fallback is available on this path.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_fetch_protected_page_under_writer_pause(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: String,
    expected_account_fingerprint: String,
    stream: String,
    generation: u64,
    previous_checkpoint_reference: Option<String>,
    maximum_changes: u32,
) -> CloudSyncProtectedFetchResult {
    let permit = match acquire_cloudkit_read_authentication(native_writer_pause_token) {
        Ok(permit) => permit,
        Err(_) => {
            return CloudSyncProtectedFetchResult {
                page: None,
                failure: Some(local_cloud_sync_protected_failure(
                    CloudSyncProtectedFailureCategory::Authorization,
                    CloudSyncProtectedSafeCode::ReadAuthenticationScope,
                )),
            }
        }
    };
    cloud_sync_fetch_protected_page_inner(
        cloud_messages_client,
        Some(&permit),
        storage_directory,
        expected_account_fingerprint,
        stream,
        generation,
        previous_checkpoint_reference,
        maximum_changes,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn cloud_sync_fetch_protected_page_inner(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    read_authentication_permit: Option<&CloudKitReadAuthenticationPermit<'_>>,
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
        read_authentication_permit,
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

fn map_cloud_sync_transient_attachment_materialization_capability(
    capability: crate::cloud_sync_canonical_dto::CloudCanonicalAttachmentMaterializationCapability,
) -> CloudSyncTransientAttachmentMaterializationCapability {
    use crate::cloud_sync_canonical_dto::CloudCanonicalAttachmentMaterializationCapability as Canonical;
    match capability {
        Canonical::Materializable => {
            CloudSyncTransientAttachmentMaterializationCapability::Materializable
        }
        Canonical::MetadataOnlyUnsupportedMediaCredentials => {
            CloudSyncTransientAttachmentMaterializationCapability::MetadataOnlyUnsupportedMediaCredentials
        }
    }
}

#[cfg(test)]
mod cloud_sync_transient_attachment_materialization_capability_tests {
    use super::*;
    use crate::cloud_sync_canonical_dto::CloudCanonicalAttachmentMaterializationCapability as Canonical;

    #[test]
    fn maps_both_content_free_attachment_materialization_capabilities() {
        assert_eq!(
            map_cloud_sync_transient_attachment_materialization_capability(
                Canonical::Materializable
            ),
            CloudSyncTransientAttachmentMaterializationCapability::Materializable
        );
        assert_eq!(
            map_cloud_sync_transient_attachment_materialization_capability(
                Canonical::MetadataOnlyUnsupportedMediaCredentials
            ),
            CloudSyncTransientAttachmentMaterializationCapability::MetadataOnlyUnsupportedMediaCredentials
        );
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
            chat_id_exact_guid_logical_key_hash: "ccccccccccccccccccccccccccccccccccccccccccc"
                .to_owned(),
            chat_id_bare_direct_service_identifier_alias_key_hash: None,
            chat_id_alias_candidates: vec![
                CloudSyncTransientChatAlias {
                    kind: CloudSyncTransientChatAliasKind::ServiceIdentifier,
                    key_hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_owned(),
                },
                CloudSyncTransientChatAlias {
                    kind: CloudSyncTransientChatAliasKind::GroupId,
                    key_hash: "ddddddddddddddddddddddddddddddddddddddddddd".to_owned(),
                },
                CloudSyncTransientChatAlias {
                    kind: CloudSyncTransientChatAliasKind::OriginalGroupId,
                    key_hash: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee".to_owned(),
                },
                CloudSyncTransientChatAlias {
                    kind: CloudSyncTransientChatAliasKind::LegacyGroupIdentifier,
                    key_hash: "fffffffffffffffffffffffffffffffffffffffffff".to_owned(),
                },
            ],
            msg_proto_4_group_id_alias_key_hash: None,
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
                chat_id_exact_guid_logical_key_hash: payload
                    .chat_id_exact_guid_logical_key_hash()
                    .value()
                    .to_owned(),
                chat_id_bare_direct_service_identifier_alias_key_hash: payload
                    .chat_id_bare_direct_service_identifier_alias_key_hash()
                    .map(|value| value.value().to_owned()),
                chat_id_alias_candidates: payload
                    .chat_id_alias_candidates()
                    .iter()
                    .map(|alias| CloudSyncTransientChatAlias {
                        kind: map_cloud_sync_transient_chat_alias_kind(alias.kind()),
                        key_hash: alias.key_hash().value().to_owned(),
                    })
                    .collect(),
                msg_proto_4_group_id_alias_key_hash: payload
                    .msg_proto_4_group_id_alias_key_hash()
                    .map(|value| value.value().to_owned()),
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
                materialization_capability:
                    map_cloud_sync_transient_attachment_materialization_capability(
                        payload.materialization_capability(),
                    ),
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

pub(super) fn map_cloud_sync_transient_failure(
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
        Native::ResetRequired => CloudSyncTransientFailureCode::ResetRequired,
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
        out_of_scope_service: None,
        deferred_reason: None,
        quarantine_reason: None,
        quarantine_diagnostic_safe_code: None,
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
/// crosses FRB. Production composition admits this entry point only through
/// the explicit read-only semantic Canary while the exact native writer-pause
/// permit remains active. `expected_payload_length` is optional for legacy D0
/// rows that retained the exact SHA-256 but not the redundant byte count; the
/// protected capability, digest, change ID, record hash, etag hash, and server
/// timestamp fences remain mandatory.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_decode_protected_change(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
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
        cloud_sync_decode_transient_record_cached_only, CloudTransientDecodeOutcome,
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

    let permit = match acquire_cloudkit_read_authentication(native_writer_pause_token) {
        Ok(permit) => permit,
        Err(_) => {
            failure_result.failure_code =
                Some(CloudSyncTransientFailureCode::ReadAuthenticationScope);
            return failure_result;
        }
    };

    match cloud_sync_decode_transient_record_cached_only(cloud_messages_client, &permit, request)
        .await
    {
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
                out_of_scope_service: None,
                deferred_reason: None,
                quarantine_reason: None,
                quarantine_diagnostic_safe_code: None,
                failure_code: None,
            }
        }
        CloudTransientDecodeOutcome::ChatIdentityObserved(_) => {
            // Observation is never a canonical mutation or projection success.
            failure_result.failure_code = Some(CloudSyncTransientFailureCode::InvalidRequest);
            failure_result
        }
        CloudTransientDecodeOutcome::OutOfScopeService(service) => {
            let mut result =
                cloud_sync_transient_empty_result(protected_source_reference, generation);
            result.out_of_scope_service = Some(match service {
                crate::cloud_sync_canonical_converter::CloudCanonicalOutOfScopeService::SmsFamily => {
                    CloudSyncTransientOutOfScopeService::SmsFamily
                }
                crate::cloud_sync_canonical_converter::CloudCanonicalOutOfScopeService::Rcs => {
                    CloudSyncTransientOutOfScopeService::Rcs
                }
                crate::cloud_sync_canonical_converter::CloudCanonicalOutOfScopeService::IMessageLite => {
                    CloudSyncTransientOutOfScopeService::IMessageLite
                }
            });
            result
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
        CloudTransientDecodeOutcome::QuarantinedWithDiagnostic(reason, diagnostic) => {
            let mut result =
                cloud_sync_transient_empty_result(protected_source_reference, generation);
            result.quarantine_reason = Some(map_cloud_sync_transient_quarantine(reason));
            result.quarantine_diagnostic_safe_code = Some(diagnostic.safe_code());
            result
        }
        CloudTransientDecodeOutcome::Failure(failure) => {
            failure_result.failure_code = Some(map_cloud_sync_transient_failure(failure));
            failure_result
        }
    }
}

fn map_cloud_sync_attachment_materialization_failure(
    failure: crate::cloud_sync_attachment_materialization::CloudNativeAttachmentMaterializationFailure,
) -> CloudSyncAttachmentMaterializationFailureCode {
    use crate::cloud_sync_attachment_materialization::CloudNativeAttachmentMaterializationFailure as Native;
    match failure {
        Native::InvalidRequest => CloudSyncAttachmentMaterializationFailureCode::InvalidRequest,
        Native::ReadAuthenticationScope => {
            CloudSyncAttachmentMaterializationFailureCode::ReadAuthenticationScope
        }
        Native::ActiveAccountMismatch => {
            CloudSyncAttachmentMaterializationFailureCode::ActiveAccountMismatch
        }
        Native::StoreIdentityMismatch => {
            CloudSyncAttachmentMaterializationFailureCode::StoreIdentityMismatch
        }
        Native::ProtectedReferenceMismatch => {
            CloudSyncAttachmentMaterializationFailureCode::ProtectedReferenceMismatch
        }
        Native::SourceUnusable => CloudSyncAttachmentMaterializationFailureCode::SourceUnusable,
        Native::PcsUnavailable => CloudSyncAttachmentMaterializationFailureCode::PcsUnavailable,
        Native::ResetRequired => {
            CloudSyncAttachmentMaterializationFailureCode::CloudKitResetRequired
        }
        Native::RetryableUpstream => {
            CloudSyncAttachmentMaterializationFailureCode::RetryableUpstream
        }
        Native::LocalStorage => CloudSyncAttachmentMaterializationFailureCode::LocalStorage,
        Native::SizeMismatch => CloudSyncAttachmentMaterializationFailureCode::SizeMismatch,
        Native::IntegrityMismatch => {
            CloudSyncAttachmentMaterializationFailureCode::IntegrityMismatch
        }
        Native::DecoderFailure => CloudSyncAttachmentMaterializationFailureCode::DecoderFailure,
    }
}

/// Downloads and atomically places one attachment body selected by an already
/// journaled V2 attachment row. This is a read-only CloudKit/MMCS operation:
/// it cannot save or delete records, enable legacy sync, or modify keychain
/// state. Raw CloudKit record IDs, etags, PCS material, asset descriptors, and
/// final filesystem paths remain entirely in Rust. The two app-private roots
/// are supplied separately because Android does not guarantee that application
/// support and application documents resolve to the same directory.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_materialize_attachment_body(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: String,
    application_documents_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    generation: u64,
    expected_change_id: String,
    expected_record_id_hash: String,
    expected_etag_hash: String,
    expected_payload_sha256: String,
    expected_server_modified_at_millis: Option<i64>,
    protected_raw_envelope_reference: String,
    logical_entity_key_hash: String,
    expected_canonical_guid_sha256: String,
    expected_bytes: u64,
) -> CloudSyncAttachmentMaterializationResult {
    let request =
        crate::cloud_sync_attachment_materialization::CloudNativeAttachmentMaterializationRequest {
            storage_directory: PathBuf::from(storage_directory),
            application_documents_directory: PathBuf::from(application_documents_directory),
            expected_account_fingerprint,
            expected_protected_store_identity,
            generation,
            expected_change_id,
            expected_record_id_hash,
            expected_etag_hash,
            expected_payload_sha256,
            expected_server_modified_at_millis,
            protected_raw_envelope_reference,
            logical_entity_key_hash,
            expected_canonical_guid_sha256,
            expected_bytes,
        };
    let permit = match acquire_cloudkit_read_authentication(native_writer_pause_token) {
        Ok(permit) => permit,
        Err(_) => {
            return CloudSyncAttachmentMaterializationResult {
                completed: false,
                verified_bytes: 0,
                failure: Some(
                    CloudSyncAttachmentMaterializationFailureCode::ReadAuthenticationScope,
                ),
            }
        }
    };
    match crate::cloud_sync_attachment_materialization::cloud_sync_materialize_attachment_body(
        cloud_messages_client,
        &permit,
        request,
    )
    .await
    {
        Ok(verified_bytes) => CloudSyncAttachmentMaterializationResult {
            completed: true,
            verified_bytes,
            failure: None,
        },
        Err(failure) => CloudSyncAttachmentMaterializationResult {
            completed: false,
            verified_bytes: 0,
            failure: Some(map_cloud_sync_attachment_materialization_failure(failure)),
        },
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
    fn semantic_decode_is_bound_to_the_native_pause_and_cached_read_auth() {
        let source = include_str!("api.rs");
        let method_start = source
            .find("pub async fn cloud_sync_decode_protected_change")
            .expect("semantic decode method");
        let following_method = source[method_start..]
            .find("pub async fn cloud_sync_materialize_attachment_body")
            .expect("following attachment method");
        let method = &source[method_start..method_start + following_method];
        let compact_method = method.split_whitespace().collect::<Vec<_>>().join(" ");

        assert!(method.contains("native_writer_pause_token: u64"));
        assert!(compact_method
            .contains("acquire_cloudkit_read_authentication(native_writer_pause_token)"));
        assert!(compact_method.contains(
            "cloud_sync_decode_transient_record_cached_only(cloud_messages_client, &permit, request)"
        ));
        assert!(!method.contains("cloud_sync_decode_transient_record("));
    }

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
        assert!(result.quarantine_diagnostic_safe_code.is_none());
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

fn persist_migrated_plist_state<T: serde::Serialize>(
    directory: &std::path::Path,
    file_name: &str,
    value: &T,
) -> anyhow::Result<()> {
    let mut encoded = Vec::new();
    plist::to_writer_xml(&mut encoded, value)?;
    persist_login_state_file(directory, file_name, &encoded)
}

fn import_migrated_rsa_key(
    handle: &str,
    bits: u16,
    private_key: &[u8],
    access_rules: KeystoreAccessRules,
) -> Result<(), KeystoreError> {
    match RsaKey::import(handle, bits, private_key, access_rules) {
        Ok(_) => Ok(()),
        Err(KeystoreError::KeyAlreadyExists) => {
            let incoming_public =
                OpenSslRsa::private_key_from_der(private_key)?.public_key_to_der()?;
            let existing_public = RsaKey(handle.to_owned()).get_public_key()?;
            if incoming_public == existing_public {
                Ok(())
            } else {
                Err(KeystoreError::KeystoreError(format!(
                    "existing RSA migration key does not match {handle}"
                )))
            }
        }
        Err(error) => Err(error),
    }
}

fn import_migrated_ec_key(
    handle: &str,
    curve: EcCurve,
    private_key: &[u8],
    access_rules: KeystoreAccessRules,
) -> Result<(), KeystoreError> {
    match EcKeystoreKey::import(handle, curve, private_key, access_rules) {
        Ok(_) => Ok(()),
        Err(KeystoreError::KeyAlreadyExists) => {
            let incoming_public =
                OpenSslEcKey::private_key_from_der(private_key)?.public_key_to_der()?;
            let existing_public = EcKeystoreKey(handle.to_owned()).get_public_key()?;
            if incoming_public == existing_public {
                Ok(())
            } else {
                Err(KeystoreError::KeystoreError(format!(
                    "existing EC migration key does not match {handle}"
                )))
            }
        }
        Err(error) => Err(error),
    }
}

fn migrate(dir: &std::path::Path) -> bool {
    let hw_config_path = dir.join("hw_info.plist");

    if let Ok(mut item) = plist::from_file::<_, Dictionary>(&hw_config_path) {
        if let Some(v) = item.get("os_config") {
            let config: JoinedOSConfig = plist::from_value(v).expect("got os ");
            if let Some(Value::Dictionary(dict)) = item.get_mut("push") {
                if let Some(Value::Dictionary(item)) = dict.get_mut("keypair") {
                    if let Some(private) = item.get_mut("private") {
                        if let Value::Data(cert) = private {
                            let handle = format!("activation:{}", config.get_serial_number());
                            import_migrated_rsa_key(
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
                            persist_migrated_plist_state(dir, "hw_info.plist", &item)
                                .expect("failed to save!");
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
                persist_migrated_plist_state(dir, "hw_info.plist", &item).expect("failed to save!");
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
                        import_migrated_rsa_key(
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
            persist_migrated_plist_state(dir, "id.plist", &users).expect("failed to save!");
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
                        import_migrated_ec_key(
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
                        import_migrated_ec_key(
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
                persist_migrated_plist_state(dir, "keychain.plist", &users)
                    .expect("failed to save!");
            }
        }
    }

    false
}

fn validate_cloud_sync_windows_auth_probe_legacy_gsa(account: &Dictionary) -> anyhow::Result<()> {
    let Some(Value::String(username)) = account.get("username") else {
        return Err(anyhow!(
            "Cloud Sync Windows authentication probe account identifier is missing"
        ));
    };
    if username.trim().is_empty() || username.len() > 320 {
        return Err(anyhow!(
            "Cloud Sync Windows authentication probe account identifier is malformed"
        ));
    }
    let Some(Value::Data(password)) = account.get("password") else {
        return Err(anyhow!(
            "Cloud Sync Windows authentication probe password digest is missing"
        ));
    };
    if password.len() != 32 {
        return Err(anyhow!(
            "Cloud Sync Windows authentication probe password digest is malformed"
        ));
    }
    if account.contains_key("encrypted_password") {
        return Err(anyhow!(
            "Cloud Sync Windows authentication probe GSA state is ambiguous"
        ));
    }
    if !matches!(account.get("postdata_done"), Some(Value::Boolean(true))) {
        return Err(anyhow!(
            "Cloud Sync Windows authentication probe postdata state is unavailable"
        ));
    }
    Ok(())
}

fn migrate_gsa_state_locked(directory: &std::path::Path) -> anyhow::Result<()> {
    let gsa_path = directory.join("gsa.plist");
    let Ok(mut account) = plist::from_file::<_, Dictionary>(&gsa_path) else {
        return Ok(());
    };
    let Some(Value::Data(password)) = account.remove("password") else {
        return Ok(());
    };
    if password.len() != 32 {
        return Err(anyhow!("GSA password digest is malformed"));
    }
    account.insert(
        "encrypted_password".to_string(),
        Value::Data(GSAConfig::encrypt(&password)?.into()),
    );

    let findmy_path = directory.join("findmy.plist");
    if let Ok(users) = plist::from_file::<_, FindMyState>(&findmy_path) {
        let encoded = users.encode()?;
        persist_login_state_file(&directory, "findmy.plist", &encoded)?;
    }

    let mut encoded = Vec::new();
    plist::to_writer_xml(&mut encoded, &account)?;
    persist_login_state_file(&directory, "gsa.plist", &encoded)?;
    Ok(())
}

#[cfg(test)]
mod cloud_sync_windows_auth_probe_tests {
    use super::{
        is_cloud_sync_windows_auth_probe_identifier,
        validate_cloud_sync_windows_auth_probe_legacy_gsa, Dictionary, Value,
    };

    fn legacy_gsa(password_len: usize) -> Dictionary {
        let mut account = Dictionary::new();
        account.insert(
            "username".to_owned(),
            Value::String("person@example.com".to_owned()),
        );
        account.insert("password".to_owned(), Value::Data(vec![7; password_len]));
        account.insert("postdata_done".to_owned(), Value::Boolean(true));
        account
    }

    #[test]
    fn accepts_one_complete_sha256_legacy_gsa_record() {
        assert!(validate_cloud_sync_windows_auth_probe_legacy_gsa(&legacy_gsa(32)).is_ok());
        assert!(is_cloud_sync_windows_auth_probe_identifier(
            "0123456789abcdef0123456789abcdef"
        ));
    }

    #[test]
    fn rejects_malformed_or_ambiguous_legacy_gsa_records() {
        assert!(validate_cloud_sync_windows_auth_probe_legacy_gsa(&legacy_gsa(31)).is_err());

        let mut ambiguous = legacy_gsa(32);
        ambiguous.insert("encrypted_password".to_owned(), Value::Data(vec![8; 60]));
        assert!(validate_cloud_sync_windows_auth_probe_legacy_gsa(&ambiguous).is_err());

        let mut missing_postdata = legacy_gsa(32);
        missing_postdata.remove("postdata_done");
        assert!(validate_cloud_sync_windows_auth_probe_legacy_gsa(&missing_postdata).is_err());

        let mut empty_account = legacy_gsa(32);
        empty_account.insert("username".to_owned(), Value::String(" ".to_owned()));
        assert!(validate_cloud_sync_windows_auth_probe_legacy_gsa(&empty_account).is_err());

        for identifier in [
            "0123456789abcdef",
            "0123456789ABCDEF0123456789ABCDEF",
            "0123456789abcdef0123456789abcdeg",
        ] {
            assert!(!is_cloud_sync_windows_auth_probe_identifier(identifier));
        }
    }
}

#[frb(sync)]
pub fn new_ngm_identity() -> anyhow::Result<IDSNGMIdentity> {
    Ok(IDSNGMIdentity::new()?)
}

#[frb(sync)]
pub fn read_hardware(path: String) -> Option<SavedHardwareState> {
    let dir = PathBuf::from_str(&path).unwrap();
    if windows_findmy_probe_enabled() {
        require_windows_findmy_probe_profile(&dir).ok()?;
    }
    let hw_config_path = dir.join("hw_info.plist");

    let hardware = plist::from_file::<_, SavedHardwareState>(&hw_config_path).ok()?;
    if windows_findmy_probe_enabled() {
        let account: GSAConfig = plist::from_file(dir.join("gsa.plist")).ok()?;
        validate_findmy_probe_retained_state(
            account.postdata_done,
            !hardware.identity.is_empty(),
            hardware.push.keypair.is_some(),
            hardware.push.token.is_some(),
        ).ok()?;
        // The Find My constructors read this retained DSID, never create it.
        let streams: SharedStreamsState = plist::from_file(dir.join("sharedstreams.plist")).ok()?;
        if streams.dsid.is_empty() { return None; }
    }
    Some(hardware)
}

fn windows_findmy_probe_enabled() -> bool {
    cfg!(target_os = "windows") &&
        std::env::var("OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE").as_deref() == Ok("1")
}

fn require_windows_findmy_probe_profile(directory: &std::path::Path) -> anyhow::Result<()> {
    let expected = PathBuf::from(std::env::var_os("APPDATA")
        .ok_or_else(|| anyhow!("findmy_probe_profile_required"))?)
        .join("OpenBubbles").join("cloudkit-v2-dev");
    if fs::canonicalize(directory)? != fs::canonicalize(&expected)? ||
        !is_cloud_sync_windows_dev_profile(&directory.to_string_lossy()) {
        return Err(anyhow!("findmy_probe_profile_required"));
    }
    Ok(())
}

fn validate_findmy_probe_retained_state(
    postdata_done: Option<bool>, identity_present: bool, aps_key_present: bool, aps_token_present: bool,
) -> anyhow::Result<()> {
    if postdata_done != Some(true) || !identity_present || !aps_key_present || !aps_token_present {
        return Err(anyhow!("findmy_probe_retained_state_required"));
    }
    Ok(())
}

async fn findmy_probe_native_read<T>(
    future: impl std::future::Future<Output = Result<T, PushError>>,
) -> anyhow::Result<T> {
    if windows_findmy_probe_enabled() {
        // Cancel the native read itself, not merely Dart's wait for its result.
        bounded_findmy_probe_read(Duration::from_secs(15), future).await
    } else {
        future.await.map_err(Into::into)
    }
}

async fn bounded_findmy_probe_read<T>(
    deadline: Duration, future: impl Future<Output = Result<T, PushError>>,
) -> anyhow::Result<T> {
    tokio::time::timeout(deadline, future).await
        .map_err(|_| anyhow!("findmy_probe_native_timeout"))?
        .map_err(|error| match error {
            // Never format the original error: it may contain bodies, URLs or credentials.
            PushError::StatusError(status) => anyhow!("findmy_probe_native_http_{}", status.as_u16()),
            PushError::RequestError(error) if error.is_timeout() => anyhow!("findmy_probe_native_timeout"),
            PushError::RequestError(error) if error.is_decode() => anyhow!("findmy_probe_native_decode"),
            PushError::JsonError(_) | PushError::PlistError(_) => anyhow!("findmy_probe_native_decode"),
            PushError::RequestError(_) | PushError::IoError(_) | PushError::TLSError(_) => anyhow!("findmy_probe_native_transport"),
            _ => anyhow!("findmy_probe_native_read_failed"),
        })
}

#[cfg(test)]
mod findmy_probe_guard_tests {
    use super::{bounded_findmy_probe_read, validate_findmy_probe_retained_state, Duration, PushError};

    #[tokio::test]
    async fn native_deadline_drops_read_and_failures_do_not_expose_details() {
        use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
        struct Dropped(Arc<AtomicBool>);
        impl Drop for Dropped {
            fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); }
        }
        let dropped = Arc::new(AtomicBool::new(false));
        let flag = dropped.clone();
        let pending = async move {
            let _guard = Dropped(flag);
            std::future::pending::<Result<(), PushError>>().await
        };
        let error = bounded_findmy_probe_read(Duration::from_millis(1), pending).await.unwrap_err();
        assert_eq!(error.to_string(), "findmy_probe_native_timeout");
        assert!(dropped.load(Ordering::SeqCst));
        let failure = async { Err::<(), _>(PushError::MobileMeError("private-error-body".into(), None)) };
        let error = bounded_findmy_probe_read(Duration::from_secs(1), failure).await.unwrap_err();
        assert_eq!(error.to_string(), "findmy_probe_native_read_failed");
        assert_eq!(bounded_findmy_probe_read(Duration::from_secs(1), async { Ok(7) }).await.unwrap(), 7);
    }

    #[tokio::test]
    async fn native_failures_preserve_only_category_and_numeric_http_status() {
        for code in [401, 429, 503] {
            let failure = PushError::StatusError(code.to_string().parse().unwrap());
            let error = bounded_findmy_probe_read(Duration::from_secs(1), async { Err::<(), _>(failure) }).await.unwrap_err();
            assert_eq!(error.to_string(), format!("findmy_probe_native_http_{code}"));
        }
        let failures = [
            (PushError::JsonError(serde_json::from_str::<serde_json::Value>("private-body").unwrap_err()), "findmy_probe_native_decode"),
            (PushError::IoError(std::io::Error::new(std::io::ErrorKind::ConnectionReset, "private-url-and-body")), "findmy_probe_native_transport"),
            (PushError::MobileMeError("findmy_probe_native_http_401 private-body".into(), None), "findmy_probe_native_read_failed"),
        ];
        for (failure, expected) in failures {
            let error = bounded_findmy_probe_read(Duration::from_secs(1), async { Err::<(), _>(failure) }).await.unwrap_err();
            assert_eq!(error.to_string(), expected);
        }
    }

    #[test]
    fn requires_completed_postdata_and_every_retained_identity_component() {
        assert!(validate_findmy_probe_retained_state(Some(true), true, true, true).is_ok());
        for postdata in [None, Some(false)] {
            assert!(validate_findmy_probe_retained_state(postdata, true, true, true).is_err());
        }
        for (identity, key, token) in [(false, true, true), (true, false, true), (true, true, false)] {
            let error = validate_findmy_probe_retained_state(Some(true), identity, key, token).unwrap_err();
            assert_eq!(error.to_string(), "findmy_probe_retained_state_required");
        }
    }
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
        let requested_dir = PathBuf::from_str(&path).unwrap();
        #[cfg(any(target_os = "android", target_os = "windows"))]
        let dir = match canonical_cloudkit_state_directory(&requested_dir) {
            Ok(directory) => directory,
            Err(error) => {
                error!("CloudKit state directory could not be resolved: {error}");
                return None;
            }
        };
        #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
        let dir = requested_dir;
        let path = dir.to_string_lossy().into_owned();
        #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
        let keystore = dir.join("keystore.plist");

        #[cfg(target_os = "windows")]
        {
            match initialize_windows_protected_keystore(&dir) {
                Ok(()) => {}
                Err(error) => {
                    error!("Windows protected keystore restore failed: {error}");
                    return None;
                }
            }
        }

        #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
        init_keystore(SoftwareKeystore {
            state: plist::from_file(&keystore).unwrap_or_default(),
            update_state: Box::new(move |state| {
                plist::to_file_xml(&keystore, state).unwrap();
            }),
            encryptor: SoftwareEncryptor(*b"desktopisinsecureyoushouldn'tber"),
        });

        {
            #[cfg(any(target_os = "android", target_os = "windows"))]
            let _migration_lifecycle_guard = {
                let lifecycle_gate = match cloudkit_read_authentication_lifecycle_gate(&dir) {
                    Ok(gate) => gate,
                    Err(error) => {
                        error!("CloudKit migration lifecycle gate failed: {error}");
                        return None;
                    }
                };
                lifecycle_gate.lock_owned().await
            };
            #[cfg(any(target_os = "android", target_os = "windows"))]
            let _migration_state_write_guard = match cloudkit_state_file_write_guard() {
                Ok(guard) => guard,
                Err(error) => {
                    error!("CloudKit migration state-file gate failed: {error}");
                    return None;
                }
            };
            #[cfg(any(target_os = "android", target_os = "windows"))]
            if let Err(error) = cloudkit_login_advance_generation(&dir) {
                error!("CloudKit migration generation advance failed: {error}");
                return None;
            }

            if let Err(err) = panic::catch_unwind(panic::AssertUnwindSafe(|| {
                migrate(&dir);
            })) {
                if let Some(s) = err.downcast_ref::<&str>() {
                    info!("Panic message: {}", s);
                } else if let Some(s) = err.downcast_ref::<String>() {
                    info!("Panic message: {}", s);
                } else {
                    info!("Panic occurred, but message has unknown type");
                }

                panic!("panicked")
            }
            if let Err(error) = migrate_gsa_state_locked(&dir) {
                error!("GSA migration failed: {error}");
                return None;
            }
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
    let requested_directory = PathBuf::from_str(&path).ok()?;
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let dir = canonical_cloudkit_state_directory(&requested_directory).ok()?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let dir = requested_directory;

    #[cfg(any(target_os = "android", target_os = "windows"))]
    let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&dir).ok()?;
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let _lifecycle_guard = lifecycle_gate.lock().await;

    let mut state = plist::from_file::<_, GSAConfig>(&dir.join("gsa.plist")).ok()?;

    // Recheck the exact state read under the existing lifecycle lock. A separate
    // preflight is not authority to update postdata or restore a fresh account.
    if windows_findmy_probe_enabled() {
        require_windows_findmy_probe_profile(&dir).ok()?;
        if state.postdata_done != Some(true) { return None; }
    }

    let mut apple_account = AppleAccount::new_with_anisette(
        get_login_config(&dir, config, conn).await,
        anisette.clone(),
    )
    .ok()?;

    apple_account.username = Some(state.username.clone());
    apple_account.hashed_password = Some(state.get_password().ok()?);

    if state.postdata_done.is_none() {
        info!("Updating postdata");
        apple_account
            .update_postdata("Apple Device", None, &["icloud", "imessage", "facetime"])
            .await
            .ok()?;
        state.postdata_done = Some(true);
        #[cfg(any(target_os = "android", target_os = "windows"))]
        persist_gsa_config_atomically(&dir, &state).ok()?;
        #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
        plist::to_file_xml(dir.join("gsa.plist"), &state).ok()?;
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
    let requested_directory = PathBuf::from_str(&path).ok()?;
    let (dir, runtime_generation) = runtime_state_writer_setup(&requested_directory);
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let runtime_generation = runtime_generation?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let _ = runtime_generation;

    let stream_path = dir.join("sharedstreams.plist");

    let state = plist::from_file(&stream_path).ok()?;

    let writer_directory = dir.clone();
    let client = SharedStreamClient::new(
        state,
        Box::new(move |update| {
            #[cfg(any(target_os = "android", target_os = "windows"))]
            let result = persist_runtime_plist_state(
                &writer_directory,
                "sharedstreams.plist",
                update,
                runtime_generation,
            );
            #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
            let result =
                persist_runtime_plist_state(&writer_directory, "sharedstreams.plist", update);
            if let Err(error) = result {
                warn!("Shared Streams state update was not persisted: {error}");
            }
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
    let requested_directory = PathBuf::from_str(&path).unwrap();
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let dir = canonical_cloudkit_state_directory(&requested_directory).ok()?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let dir = requested_directory;

    #[cfg(any(target_os = "android", target_os = "windows"))]
    if restore_persisted_cloudkit_read_authentication(&dir, token_provider)
        .await
        .is_err()
    {
        error!("CloudKit read-authentication lifecycle restore failed");
    }

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
    let requested_directory = PathBuf::from_str(&path).unwrap();
    let (dir, runtime_generation) = runtime_state_writer_setup(&requested_directory);

    let passwords_path = dir.join("passwords.plist");
    let state: PasswordState = plist::from_file(&passwords_path).unwrap_or_default();
    let writer_directory = dir.clone();

    PasswordManager::new(
        keychain.clone(),
        cloudkit.clone(),
        client.identity.clone(),
        conn.clone(),
        state,
        Box::new(move |item| {
            #[cfg(any(target_os = "android", target_os = "windows"))]
            let result = match runtime_generation {
                Some(generation) => persist_runtime_plist_state(
                    &writer_directory,
                    "passwords.plist",
                    item,
                    generation,
                ),
                None => Err(anyhow!("Runtime state writer is unavailable")),
            };
            #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
            let result = persist_runtime_plist_state(&writer_directory, "passwords.plist", item);
            if let Err(error) = result {
                warn!("Passwords state update was not persisted: {error}");
            }
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
    let requested_directory = PathBuf::from_str(&path).unwrap();
    let (dir, runtime_generation) = runtime_state_writer_setup(&requested_directory);
    let facetime_path = dir.join("facetime.plist");
    let state: FTState = plist::from_file(&facetime_path).unwrap_or_default();
    let writer_directory = dir.clone();
    Arc::new(
        FTClient::new(
            state,
            Box::new(move |state| {
                #[cfg(any(target_os = "android", target_os = "windows"))]
                let result = match runtime_generation {
                    Some(generation) => persist_runtime_plist_state(
                        &writer_directory,
                        "facetime.plist",
                        state,
                        generation,
                    ),
                    None => Err(anyhow!("Runtime state writer is unavailable")),
                };
                #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
                let result =
                    persist_runtime_plist_state(&writer_directory, "facetime.plist", state);
                if let Err(error) = result {
                    warn!("FaceTime state update was not persisted: {error}");
                }
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
    let requested_directory = PathBuf::from_str(&path).unwrap();
    let (dir, runtime_generation) = runtime_state_writer_setup(&requested_directory);

    let statuskit_path = dir.join("statuskit.plist");
    let state: StatusKitState = plist::from_file(&statuskit_path).unwrap_or_default();
    let writer_directory = dir.clone();
    StatusKitClient::new(
        state,
        Box::new(move |state| {
            #[cfg(any(target_os = "android", target_os = "windows"))]
            let result = match runtime_generation {
                Some(generation) => persist_runtime_plist_state(
                    &writer_directory,
                    "statuskit.plist",
                    state,
                    generation,
                ),
                None => Err(anyhow!("Runtime state writer is unavailable")),
            };
            #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
            let result = persist_runtime_plist_state(&writer_directory, "statuskit.plist", state);
            if let Err(error) = result {
                warn!("StatusKit state update was not persisted: {error}");
            }
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
    let requested_directory = PathBuf::from_str(&path).ok()?;
    let (dir, runtime_generation) = runtime_state_writer_setup(&requested_directory);
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let runtime_generation = runtime_generation?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let _ = runtime_generation;
    let cloudkit_path = dir.join("keychain.plist");

    if let Err(e) = plist::from_file::<_, KeychainClientState>(&cloudkit_path) {
        info!("Failed to desrialized {e}");
    }

    let state: KeychainClientState = plist::from_file(&cloudkit_path).ok()?;
    let writer_directory = dir.clone();

    Some(Arc::new(KeychainClient {
        anisette: anisette.clone(),
        token_provider: token_provider.clone(),
        state: DebugRwLock::new(state),
        config: config.config(),
        update_state: Box::new(move |update| {
            #[cfg(any(target_os = "android", target_os = "windows"))]
            let result = persist_runtime_plist_state(
                &writer_directory,
                "keychain.plist",
                update,
                runtime_generation,
            );
            #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
            let result = persist_runtime_plist_state(&writer_directory, "keychain.plist", update);
            if let Err(error) = result {
                warn!("Keychain state update was not persisted: {error}");
            }
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
    let requested_directory = PathBuf::from_str(&path).ok()?;
    let (dir, runtime_generation) = runtime_state_writer_setup(&requested_directory);
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let runtime_generation = runtime_generation?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let _ = runtime_generation;
    let id_path = dir.join("findmy.plist");
    let state = FindMyState::restore(&fs::read(&id_path).ok()?).ok()?;
    let writer_directory = dir.clone();

    Some(Arc::new(
        FindMyClient::new(
            conn.clone(),
            cloudkit.clone(),
            keychain.clone(),
            config.config(),
            Arc::new(FindMyStateManager {
                state: Mutex::new(state),
                update: Box::new(move |state| {
                    #[cfg(any(target_os = "android", target_os = "windows"))]
                    let result = persist_runtime_state_file(
                        &writer_directory,
                        "findmy.plist",
                        &state,
                        runtime_generation,
                    );
                    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
                    let result =
                        persist_login_state_file(&writer_directory, "findmy.plist", &state);
                    if let Err(error) = result {
                        warn!("Find My state update was not persisted: {error}");
                    }
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
        native_receipt: Option<CloudSyncNativeSendReceipt>,
        native_receipt_error: Option<String>,
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

#[frb(ignore)]
fn cloud_sync_attachment_send_source(
    context: Option<&CloudSyncNativeSendReceiptContext>,
    message: &MessageInst,
) -> anyhow::Result<Option<(Vec<u8>, Vec<String>)>> {
    let Some(context) = context else { return Ok(None); };
    let Some(binding) = &context.source_binding else { return Ok(None); };
    if binding.kind == Some(CloudSyncNativeSendSourceKind::Mutation) {
        return Err(anyhow!("cloud_sync_native_attachment_source_invalid"));
    }
    let stage = crate::cloud_sync_ids_attachment_source::NativeIdsAttachmentSourceStage {
        protected_reference: binding.protected_reference.clone(),
        lease_reference: binding.lease_reference.clone(),
        payload_sha256: binding.payload_sha256.clone(),
        payload_length: binding.payload_length,
    };
    let protected_identity = crate::cloud_sync_protector::protected_store_identity(
        context.storage_directory.clone(),
    ).map_err(|_| anyhow!("cloud_sync_native_attachment_source_unavailable"))?;
    if protected_identity != context.protected_store_identity {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    let envelope = crate::cloud_sync_ids_attachment_source::open_staged_source_envelope(
        PathBuf::from(&context.storage_directory), context.account_fingerprint.clone(),
        &binding.source_sha256, &stage,
    ).map_err(|_| anyhow!("cloud_sync_native_attachment_source_unavailable"))?;
    let decoded = crate::cloud_sync_ids_attachment_source::decode_ids_attachment_source(&envelope)
        .map_err(|_| anyhow!("cloud_sync_native_attachment_source_invalid"))?;
    crate::cloud_sync_ids_attachment_source::validate_ids_attachment_source(
        &envelope, message, &decoded.attachment_guids,
    ).map_err(|_| anyhow!("cloud_sync_native_attachment_source_changed"))?;
    Ok(Some((envelope, decoded.attachment_guids)))
}

// These bytes remain only in native memory until the actual send completes.
// They are never logged or exposed by Debug/FRB.
#[frb(ignore)]
enum CloudSyncBoundSendSource {
    Attachment(Vec<u8>, Vec<String>),
    Mutation(Vec<u8>),
}

#[frb(ignore)]
fn cloud_sync_send_source(
    context: Option<&CloudSyncNativeSendReceiptContext>,
    message: &MessageInst,
) -> anyhow::Result<Option<CloudSyncBoundSendSource>> {
    let Some(context) = context else { return Ok(None); };
    if context.source_binding.as_ref().is_some_and(|binding|
        binding.kind == Some(CloudSyncNativeSendSourceKind::Mutation))
    {
        let source = cloud_sync_open_mutation_source_bound(context)?;
        crate::cloud_sync_ids_mutation_source::validate_mutation_source(&source, message)
            .map_err(|_| anyhow!("cloud_sync_native_mutation_source_changed"))?;
        Ok(Some(CloudSyncBoundSendSource::Mutation(source)))
    } else {
        cloud_sync_attachment_send_source(Some(context), message)
            .map(|source| source.map(|(bytes, guids)| CloudSyncBoundSendSource::Attachment(bytes, guids)))
    }
}

#[frb(ignore)]
fn cloud_sync_validate_prepared_send_source(
    source: Option<CloudSyncBoundSendSource>,
    message: &MessageInst,
    start_ms: u64,
    finish_ms: u64,
) -> Result<Option<u64>, &'static str> {
    match source {
        Some(CloudSyncBoundSendSource::Attachment(bytes, guids)) =>
            crate::cloud_sync_ids_attachment_source::validate_prepared_ids_attachment_source(
                &bytes, message, &guids, start_ms, finish_ms,
            ).map(|()| None).map_err(|_| "cloud_sync_native_attachment_prepared_source_changed"),
        Some(CloudSyncBoundSendSource::Mutation(bytes)) => {
            crate::cloud_sync_ids_mutation_source::validate_prepared_mutation_source(
                &bytes, message, start_ms, finish_ms,
            ).map_err(|_| "cloud_sync_native_mutation_prepared_source_changed")?;
            if message.sent_timestamp == 0 || message.sent_timestamp > i64::MAX as u64 {
                return Err("cloud_sync_native_mutation_prepared_time_invalid");
            }
            Ok(Some(message.sent_timestamp))
        },
        None => Ok(None),
    }
}

#[frb(ignore)]
fn cloud_sync_send_start_error(error: PushError, tracked: bool) -> anyhow::Error {
    // IdentityManager can return SendTimedOut after spawning send_targets and
    // sending packets, but before any progress event. Aborting that task does
    // not prove non-delivery. Do not expose the legacy automatic-retry string
    // for a tracked intent; retain it for receipt/readback reconciliation.
    match (tracked, error) {
        (true, PushError::SendTimedOut) => anyhow!("cloud_sync_native_send_completion_unknown"),
        (_, error) => error.into(),
    }
}

pub async fn send(
    state: &Arc<IMClient>,
    local: &Arc<mpsc::Sender<PushMessage>>,
    mut msg: MessageInst,
    native_receipt_context: Option<CloudSyncNativeSendReceiptContext>,
) -> anyhow::Result<bool> {
    if native_receipt_context
        .as_ref()
        .is_some_and(|context| cloud_sync_local_send_guid_hash(&msg.id) != context.guid_hash)
    {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    let source = cloud_sync_send_source(native_receipt_context.as_ref(), &msg)?;
    let send_started_ms = systemtime_to_millis(SystemTime::now());
    let result = state.send(&mut msg).await
        .map_err(|error| cloud_sync_send_start_error(error, native_receipt_context.is_some()))?;
    let send_finished_ms = systemtime_to_millis(SystemTime::now());
    let source_validation = cloud_sync_validate_prepared_send_source(
        source, &msg, send_started_ms, send_finished_ms,
    );
    let confirmation = result.confirmation();
    info!("send_finish");

    let local = local.clone();
    if let Some(handle) = result.handle {
        let uuid = msg.id.clone();
        tokio::spawn(async move {
            let result = handle.await;
            info!("Finished handle");
            let (maybeerr, native_receipt, native_receipt_error) = match result {
                Ok(result) => cloud_sync_send_confirmation_fields_with_source(
                    result,
                    native_receipt_context,
                    &uuid,
                    || confirmation.require_confirmed(),
                    source_validation,
                ),
                Err(_) => (
                    Some("cloud_sync_native_send_completion_unknown".to_owned()),
                    None,
                    None,
                ),
            };
            let _ = local
                .send(PushMessage::SendConfirm {
                    uuid,
                    error: maybeerr,
                    native_receipt,
                    native_receipt_error,
                })
                .await;
        });
        Ok(true)
    } else if native_receipt_context.is_some() {
        // A missing handle can be synchronous completion OR a zero-target
        // no-op. Require actual participant acceptance before emitting a
        // protected success receipt in either completion path.
        let uuid = msg.id.clone();
        let (error, native_receipt, native_receipt_error) =
            cloud_sync_send_confirmation_fields_with_source(Ok(()), native_receipt_context, &uuid,
                || confirmation.require_confirmed(), source_validation);
        let _ = local
            .send(PushMessage::SendConfirm {
                uuid,
                error,
                native_receipt,
                native_receipt_error,
            })
            .await;
        Ok(true)
    } else {
        Ok(false)
    }
}

#[frb(ignore)]
#[cfg(test)]
fn cloud_sync_send_confirmation_fields(
    result: Result<(), PushError>,
    native_receipt_context: Option<CloudSyncNativeSendReceiptContext>,
    stable_guid: &str,
    confirm_participants: impl FnOnce() -> Result<(), PushError>,
) -> (
    Option<String>,
    Option<CloudSyncNativeSendReceipt>,
    Option<String>,
) {
    cloud_sync_send_confirmation_fields_with_source(
        result, native_receipt_context, stable_guid, confirm_participants, Ok(None),
    )
}

#[frb(ignore)]
fn cloud_sync_send_confirmation_fields_with_source(
    result: Result<(), PushError>,
    native_receipt_context: Option<CloudSyncNativeSendReceiptContext>,
    stable_guid: &str,
    confirm_participants: impl FnOnce() -> Result<(), PushError>,
    source_validation: Result<Option<u64>, &'static str>,
) -> (Option<String>, Option<CloudSyncNativeSendReceipt>, Option<String>) {
    // Legacy/untracked send semantics stay unchanged. Strict V2 receipts need
    // both job completion and positive acceptance, not APSError/TimedOut
    // progress or a missing native handle. Fixed errors cannot trigger the
    // Dart wrapper's automatic "Send timeout; try again" resubmission.
    let result = if native_receipt_context.is_some() {
        result.and_then(|_| confirm_participants())
    } else {
        result
    };
    match result {
        // IDS already accepted the send. A local source mismatch suppresses
        // CloudKit authority, but must not ask the user/wrapper to resend it.
        Ok(()) if source_validation.is_err() => (
            None, None, source_validation.err().map(str::to_owned),
        ),
        Ok(()) => match native_receipt_context {
            Some(context) => match persist_cloud_sync_native_send_receipt(
                context, stable_guid, source_validation.expect("validated source"),
            ) {
                Ok(receipt) => (None, Some(receipt), None),
                Err(error) => (None, None, Some(error.to_string())),
            },
            None => (None, None, None),
        },
        Err(_) if native_receipt_context.is_some() => (
            Some("cloud_sync_native_send_failed".to_owned()),
            None,
            None,
        ),
        Err(error) => (Some(error.to_string()), None, None),
    }
}

/// Windows qualification only. Uses the already-bound GSA account instead of
/// replaying onboarding (which would replace unrelated CloudKit/Keychain state).
/// No credentials or tokens cross this boundary, and no local state is written.
pub async fn cloud_sync_windows_authenticate_sender(
    path: String,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    config: &JoinedOSConfig,
) -> anyhow::Result<IDSUser> {
    if !is_cloud_sync_windows_dev_profile(&path) {
        return Err(anyhow!("cloud_sync_windows_sender_profile_required"));
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (account, config);
        Err(anyhow!("cloud_sync_windows_sender_profile_required"))
    }
    #[cfg(target_os = "windows")]
    {
        let directory = canonical_cloudkit_state_directory(&PathBuf::from(path))?;
        let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&directory)?;
        let _lifecycle_guard = lifecycle_gate.lock().await;
        let saved: GSAConfig = plist::from_file(directory.join("gsa.plist"))
            .map_err(|_| anyhow!("cloud_sync_windows_sender_account_unavailable"))?;
        let hardware: SavedHardwareState = plist::from_file(directory.join("hw_info.plist"))
            .map_err(|_| anyhow!("cloud_sync_windows_sender_hardware_unavailable"))?;
        let mut account = account.lock().await;
        if account.username.as_deref() != Some(saved.username.as_str())
            || hardware.os_config.config().get_udid() != config.config().get_udid()
        {
            return Err(anyhow!("cloud_sync_windows_sender_identity_mismatch"));
        }
        // This is the same PET/delegate exchange used by the ordinary client.
        // A missing session fails here. Never reset credentials to make it pass.
        if account.get_token("com.apple.gs.idms.pet").await.is_none()
            || account.get_pet().is_none()
            || account.spd.as_ref().and_then(|spd| spd.get("adsid"))
                .and_then(Value::as_string).is_none_or(str::is_empty)
        {
            return Err(anyhow!("cloud_sync_windows_sender_auth_required"));
        }
        let delegates = login_apple_delegates(
            &*account, None, &*config.config(), &[LoginDelegate::IDS],
        ).await.map_err(|_| anyhow!("cloud_sync_windows_sender_delegate_failed"))?;
        let ids = delegates.ids
            .ok_or_else(|| anyhow!("cloud_sync_windows_sender_delegate_missing"))?;
        authenticate_apple(ids, &*config.config()).await
            .map_err(|_| anyhow!("cloud_sync_windows_sender_authentication_failed"))
    }
}

/// Unlike `send`, this returns only after the actual native SendJob completes.
/// A timeout/crash must remain an unconfirmed journal entry, never a replayed
/// send or synthetic confirmation. The caller owns the exact pre-send intent.
pub async fn cloud_sync_windows_send_confirmed(
    path: String,
    state: &Arc<IMClient>,
    mut msg: MessageInst,
) -> anyhow::Result<()> {
    if !is_cloud_sync_windows_dev_profile(&path) {
        return Err(anyhow!("cloud_sync_windows_sender_profile_required"));
    }
    let result = state.send(&mut msg).await
        .map_err(|_| anyhow!("cloud_sync_windows_sender_send_failed"))?;
    let confirmation = result.confirmation();
    cloud_sync_windows_finish_send_job(result.handle,
        || confirmation.require_confirmed()).await
}

/// Explicit Windows qualification path for a journal-claimed edit/unsend.
/// Uses the same committed-source checks and protected receipt as ordinary
/// sending. Never retries, returns early, acknowledges receipts or saves CK.
/// A successful IDS send followed by any local failure remains reconciliation
/// work, not permission to resubmit the claimed mutation.
pub async fn cloud_sync_windows_send_mutation_confirmed(
    state: &Arc<IMClient>,
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    mut msg: MessageInst,
    context: CloudSyncNativeSendReceiptContext,
) -> anyhow::Result<CloudSyncNativeSendReceipt> {
    if !is_cloud_sync_windows_dev_profile(&context.storage_directory) {
        return Err(anyhow!("cloud_sync_windows_sender_profile_required"));
    }
    let auth = cloud_sync_capture_auth_snapshot(
        cloud_messages_client, context.storage_directory.clone(),
    ).await.map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))?;
    cloud_sync_require_source_context_auth(&context, &auth)?;
    let source = cloud_sync_windows_mutation_send_source(&context, &msg)?;
    let started = systemtime_to_millis(SystemTime::now());
    let result = state.send_mutation_requesting_acknowledgment(&mut msg).await
        .map_err(|error| cloud_sync_send_start_error(error, true))?;
    let finished = systemtime_to_millis(SystemTime::now());
    let validation = cloud_sync_validate_prepared_send_source(Some(source), &msg, started, finished);
    let confirmation = result.confirmation();
    let storage = context.storage_directory.clone();
    cloud_sync_windows_finish_mutation_send(
        result.handle, || confirmation.require_confirmed(), context, &msg.id,
        validation, async {
            cloud_sync_capture_auth_snapshot(cloud_messages_client, storage).await
                .map_err(|_| anyhow!("cloud_sync_native_send_auth_unavailable"))
        },
    ).await
}

#[frb(ignore)]
async fn cloud_sync_windows_finish_mutation_send(
    handle: Option<tokio::task::JoinHandle<Result<(), PushError>>>,
    confirm_participants: impl FnOnce() -> Result<(), PushError>,
    context: CloudSyncNativeSendReceiptContext,
    stable_guid: &str,
    source_validation: Result<Option<u64>, &'static str>,
    reauthenticate: impl std::future::Future<Output = anyhow::Result<CloudSyncNativeAuthMetadata>>,
) -> anyhow::Result<CloudSyncNativeSendReceipt> {
    cloud_sync_windows_finish_send_job(handle, confirm_participants).await?;
    cloud_sync_require_source_context_auth(&context, &reauthenticate.await?)?;
    cloud_sync_windows_mutation_send_receipt(context, stable_guid, source_validation)
}

#[frb(ignore)]
fn cloud_sync_windows_mutation_send_source(
    context: &CloudSyncNativeSendReceiptContext,
    msg: &MessageInst,
) -> anyhow::Result<CloudSyncBoundSendSource> {
    if cloud_sync_local_send_guid_hash(&msg.id) != context.guid_hash
        || !context.source_binding.as_ref().is_some_and(|binding|
            binding.kind == Some(CloudSyncNativeSendSourceKind::Mutation))
    {
        return Err(anyhow!("cloud_sync_native_send_receipt_context_invalid"));
    }
    match cloud_sync_send_source(Some(context), msg)? {
        Some(source @ CloudSyncBoundSendSource::Mutation(_)) => Ok(source),
        _ => Err(anyhow!("cloud_sync_native_mutation_source_changed")),
    }
}

#[frb(ignore)]
fn cloud_sync_windows_mutation_send_receipt(
    context: CloudSyncNativeSendReceiptContext,
    stable_guid: &str,
    source_validation: Result<Option<u64>, &'static str>,
) -> anyhow::Result<CloudSyncNativeSendReceipt> {
    let time = source_validation.map_err(|code| anyhow!(code))?
        .ok_or_else(|| anyhow!("cloud_sync_native_mutation_prepared_time_invalid"))?;
    persist_cloud_sync_native_send_receipt(context, stable_guid, Some(time))
}

#[frb(ignore)]
async fn cloud_sync_windows_finish_send_job(
    handle: Option<tokio::task::JoinHandle<Result<(), PushError>>>,
    confirm_participants: impl FnOnce() -> Result<(), PushError>,
) -> anyhow::Result<()> {
    if let Some(handle) = handle {
        handle.await
            .map_err(|_| anyhow!("cloud_sync_windows_sender_completion_unknown"))?
            .map_err(|_| anyhow!("cloud_sync_windows_sender_send_failed"))?;
    }
    confirm_participants()
        .map_err(|_| anyhow!("cloud_sync_windows_sender_unconfirmed"))
}

#[cfg(test)]
mod cloud_sync_mutation_send_tests {
    use super::*;

    #[tokio::test]
    async fn windows_mutation_completion_retains_real_receipt_without_remote_save() {
        for unsend in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let message = fixture(unsend);
            let mut context = context(directory.path(), &message);
            context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
                &context, &auth(&context), &"a".repeat(64), &message,
            ).unwrap());
            assert!(cloud_sync_windows_mutation_send_source(&context, &message).is_err());
            commit(&context);
            let source = cloud_sync_windows_mutation_send_source(&context, &message).unwrap();
            let mut prepared = message.clone();
            let started = systemtime_to_millis(SystemTime::now());
            prepared.prepare_send(&[message.sender.clone().unwrap()]);
            let finished = systemtime_to_millis(SystemTime::now());
            let validation = cloud_sync_validate_prepared_send_source(Some(source), &prepared, started, finished);
            let receipt = cloud_sync_windows_finish_mutation_send(
                Some(tokio::spawn(async { Ok(()) })), || Ok(()), context.clone(),
                &prepared.id, validation, async { Ok(auth(&context)) },
            ).await.unwrap();
            let replay = cloud_sync_replay_native_send_receipts(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), None,
            ).await.unwrap();
            assert_eq!(replay.receipts.len(), 1);
            assert_eq!(replay.receipts[0].receipt_id, receipt.receipt_id);
            assert_eq!(receipt.prepared_sent_timestamp_ms, Some(prepared.sent_timestamp));
            assert_eq!(replay.receipts[0].prepared_sent_timestamp_ms, Some(prepared.sent_timestamp));
            assert_eq!(receipt.source_binding.unwrap().kind, Some(CloudSyncNativeSendSourceKind::Mutation));
            assert!(cloud_sync_open_mutation_source_bound(&context).is_ok());
        }
    }

    #[test]
    fn windows_mutation_preflight_rejects_guid_purpose_and_changed_wire() {
        let directory = tempfile::tempdir().unwrap();
        let message = fixture(false);
        let mut context = context(directory.path(), &message);
        assert!(cloud_sync_windows_mutation_send_source(&context, &message).is_err());
        context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
            &context, &auth(&context), &"a".repeat(64), &message,
        ).unwrap());
        commit(&context);
        for alteration in 0..4 {
            let mut changed_context = context.clone();
            let mut changed_wire = message.clone();
            match alteration {
                0 => changed_context.guid_hash = "b".repeat(64),
                1 => changed_context.source_binding.as_mut().unwrap().kind = None,
                2 => changed_context.source_binding.as_mut().unwrap().kind = Some(CloudSyncNativeSendSourceKind::Attachment),
                _ => changed_wire.sender = Some("mailto:other@example.invalid".to_owned()),
            }
            assert!(cloud_sync_windows_mutation_send_source(&changed_context, &changed_wire).is_err());
        }
    }

    #[tokio::test]
    async fn windows_mutation_requires_job_acceptance_current_auth_and_validated_source() {
        for failure in 0..5 {
            let directory = tempfile::tempdir().unwrap();
            let message = fixture(false);
            let mut context = context(directory.path(), &message);
            context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
                &context, &auth(&context), &"a".repeat(64), &message,
            ).unwrap());
            commit(&context);
            let handle = if failure == 0 {
                Some(tokio::spawn(async { Err(PushError::SendTimedOut) }))
            } else if failure == 1 {
                let pending = tokio::spawn(async {
                    std::future::pending::<Result<(), PushError>>().await
                });
                pending.abort();
                Some(pending)
            } else { None };
            let mut after = auth(&context);
            if failure == 3 { after.native_session_id = "other".to_owned(); }
            let validation = if failure == 4 {
                Err("cloud_sync_native_mutation_prepared_source_changed")
            } else { Ok(Some(123)) };
            let result = cloud_sync_windows_finish_mutation_send(handle, || {
                assert!(failure > 1, "failed job must not confirm");
                if failure == 2 { Err(PushError::NoValidTargets) } else { Ok(()) }
            }, context.clone(), &message.id, validation, async { Ok(after) }).await;
            assert!(result.is_err());
            let replay = cloud_sync_replay_native_send_receipts(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), None,
            ).await.unwrap();
            assert!(replay.receipts.is_empty());
            assert!(cloud_sync_open_mutation_source_bound(&context).is_ok());
        }
    }

    #[tokio::test]
    async fn windows_mutation_changed_prepared_source_persists_no_receipt() {
        let directory = tempfile::tempdir().unwrap();
        let message = fixture(false);
        let mut context = context(directory.path(), &message);
        context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
            &context, &auth(&context), &"a".repeat(64), &message,
        ).unwrap());
        commit(&context);
        let source = cloud_sync_windows_mutation_send_source(&context, &message).unwrap();
        let mut changed = message.clone();
        changed.sender = Some("mailto:other@example.invalid".to_owned());
        let validation = cloud_sync_validate_prepared_send_source(Some(source), &changed, 0, 1);
        assert!(cloud_sync_windows_mutation_send_receipt(context.clone(), &message.id, validation).is_err());
        let replay = cloud_sync_replay_native_send_receipts(
            context.storage_directory.clone(), context.account_fingerprint.clone(),
            context.protected_store_identity.clone(), None,
        ).await.unwrap();
        assert!(replay.receipts.is_empty());
        assert!(cloud_sync_open_mutation_source_bound(&context).is_ok());
    }

    #[test]
    fn tracked_start_timeout_cannot_trigger_legacy_automatic_resubmission() {
        assert_eq!(cloud_sync_send_start_error(PushError::SendTimedOut, true).to_string(),
            "cloud_sync_native_send_completion_unknown");
        assert_eq!(cloud_sync_send_start_error(PushError::SendTimedOut, false).to_string(),
            "Send timeout; try again");
        for tracked in [false, true] {
            let expected = PushError::NoValidTargets.to_string();
            assert_eq!(cloud_sync_send_start_error(PushError::NoValidTargets, tracked).to_string(), expected);
            let expected = PushError::SendErr(6005).to_string();
            assert_eq!(cloud_sync_send_start_error(PushError::SendErr(6005), tracked).to_string(), expected);
        }
    }

    fn fixture(unsend: bool) -> MessageInst {
        let target = "22222222-2222-4abc-8def-555555555555".to_owned();
        MessageInst {
            id: "11111111-2222-4abc-8def-555555555555".to_owned(),
            sender: Some("mailto:sender@example.invalid".to_owned()),
            conversation: Some(rustpush::ConversationData {
                participants: vec!["mailto:peer@example.invalid".to_owned()],
                cv_name: None, sender_guid: None, after_guid: None,
            }),
            message: if unsend {
                Message::Unsend(rustpush::UnsendMessage { tuuid: target, edit_part: 2 })
            } else {
                Message::Edit(rustpush::EditMessage {
                    tuuid: target, edit_part: 2,
                    new_parts: rustpush::MessageParts(vec![rustpush::IndexedMessagePart {
                        part: rustpush::MessagePart::Text("synthetic edit".to_owned(),
                            rustpush::TextFormat::Flags(rustpush::TextFlags::default())),
                        idx: Some(2), ext: None,
                    }]),
                })
            },
            sent_timestamp: 123, send_delivered: false, target: None,
            verification_failed: false, certified_context: None,
        }
    }

    fn context(directory: &std::path::Path, message: &MessageInst) -> CloudSyncNativeSendReceiptContext {
        let storage = directory.to_string_lossy().into_owned();
        CloudSyncNativeSendReceiptContext {
            protected_store_identity: crate::cloud_sync_protector::protected_store_identity(storage.clone()).unwrap(),
            storage_directory: storage, guid_hash: cloud_sync_local_send_guid_hash(&message.id),
            account_fingerprint: "A".repeat(43), native_session_id: "N".repeat(43), source_binding: None,
        }
    }

    fn auth(context: &CloudSyncNativeSendReceiptContext) -> CloudSyncNativeAuthMetadata {
        CloudSyncNativeAuthMetadata {
            account_fingerprint: context.account_fingerprint.clone(),
            protected_store_identity: context.protected_store_identity.clone(),
            native_session_id: context.native_session_id.clone(),
        }
    }

    fn commit(context: &CloudSyncNativeSendReceiptContext) {
        let binding = context.source_binding.as_ref().unwrap();
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            PathBuf::from(&context.storage_directory), &binding.lease_reference,
            std::slice::from_ref(&binding.protected_reference),
        ).unwrap();
    }

    #[test]
    fn mutation_stage_requires_exact_auth_and_unbound_operation() {
        let directory = tempfile::tempdir().unwrap();
        let message = fixture(false);
        let mut context = context(directory.path(), &message);
        let auth = auth(&context);
        for field in 0..4 {
            let mut changed = context.clone();
            match field {
                0 => changed.guid_hash = "b".repeat(64),
                1 => changed.account_fingerprint = "B".repeat(43),
                2 => changed.protected_store_identity = format!("obcs2.store.{}", "B".repeat(43)),
                _ => changed.native_session_id = "B".repeat(43),
            }
            assert!(cloud_sync_stage_mutation_source_bound(&changed, &auth, &"a".repeat(64), &message).is_err());
        }
        context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
            &context, &auth, &"a".repeat(64), &message,
        ).unwrap());
        assert!(cloud_sync_stage_mutation_source_bound(&context, &auth, &"a".repeat(64), &message).is_err());
        assert!(cloud_sync_send_source(Some(&context), &message).is_err());
        commit(&context);
        assert!(cloud_sync_send_source(Some(&context), &message).is_ok());
    }

    #[tokio::test]
    async fn edit_and_unsend_source_survive_preparation_receipt_replay_and_exact_ack() {
        for unsend in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let message = fixture(unsend);
            let mut context = context(directory.path(), &message);
            context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
                &context, &auth(&context), &"a".repeat(64), &message,
            ).unwrap());
            commit(&context);
            let source = cloud_sync_send_source(Some(&context), &message).unwrap();
            let envelope = cloud_sync_open_mutation_source_bound(&context).unwrap();
            let restored = crate::cloud_sync_ids_mutation_source::open_mutation_source(&envelope).unwrap().message().unwrap();
            assert!(cloud_sync_send_source(Some(&context), &restored).is_ok());
            assert!(cloud_sync_attachment_send_source(Some(&context), &message).is_err());
            assert!(cloud_sync_open_attachment_source_bound(&context, &auth(&context)).is_err());
            let mut prepared = message.clone();
            let start = systemtime_to_millis(SystemTime::now());
            prepared.prepare_send(&[message.sender.clone().unwrap()]);
            let finish = systemtime_to_millis(SystemTime::now());
            let validation = cloud_sync_validate_prepared_send_source(source, &prepared, start, finish);
            assert_eq!(validation, Ok(Some(prepared.sent_timestamp)));
            let (error, receipt, receipt_error) = cloud_sync_send_confirmation_fields_with_source(
                Ok(()), Some(context.clone()), &message.id, || Ok(()), validation,
            );
            assert!(error.is_none() && receipt_error.is_none());
            let receipt = receipt.unwrap();
            assert_eq!(receipt.prepared_sent_timestamp_ms, Some(prepared.sent_timestamp));
            assert_eq!(receipt.source_binding.unwrap().kind, Some(CloudSyncNativeSendSourceKind::Mutation));
            let replay = cloud_sync_replay_native_send_receipts(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), None,
            ).await.unwrap();
            assert_eq!(replay.receipts.len(), 1);
            let receipt = replay.receipts.into_iter().next().unwrap();
            assert_eq!(receipt.prepared_sent_timestamp_ms, Some(prepared.sent_timestamp));
            assert_eq!(receipt.source_binding.as_ref().unwrap().kind, Some(CloudSyncNativeSendSourceKind::Mutation));
            let mut wrong_time = receipt.clone();
            wrong_time.prepared_sent_timestamp_ms = Some(prepared.sent_timestamp + 1);
            assert!(cloud_sync_acknowledge_native_send_receipt(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), wrong_time,
            ).is_err());
            let mut wrong = receipt.clone();
            wrong.source_binding.as_mut().unwrap().kind = None;
            assert!(cloud_sync_acknowledge_native_send_receipt(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), wrong,
            ).is_err());
            cloud_sync_acknowledge_native_send_receipt(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), receipt,
            ).unwrap();
            let replay = cloud_sync_replay_native_send_receipts(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), None,
            ).await.unwrap();
            assert!(replay.receipts.is_empty());
            // Ack releases the receipt, not the original mutation source.
            assert!(cloud_sync_open_mutation_source_bound(&context).is_ok());
        }
    }

    #[tokio::test]
    async fn mutation_receipt_never_invents_a_time_or_uses_receipt_arrival() {
        for unsend in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let message = fixture(unsend);
            let mut context = context(directory.path(), &message);
            context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
                &context, &auth(&context), &"a".repeat(64), &message,
            ).unwrap());
            commit(&context);
            let original = cloud_sync_open_mutation_source_bound(&context).unwrap();
            for time in [0, i64::MAX as u64 + 1] {
                let source = cloud_sync_send_source(Some(&context), &message).unwrap();
                let mut prepared = message.clone();
                prepared.prepare_send(&[message.sender.clone().unwrap()]);
                prepared.sent_timestamp = time;
                assert_eq!(cloud_sync_validate_prepared_send_source(source, &prepared, time, time),
                    Err("cloud_sync_native_mutation_prepared_time_invalid"));
            }
            for time in [None, Some(0), Some(i64::MAX as u64 + 1)] {
                let (error, receipt, receipt_error) = cloud_sync_send_confirmation_fields_with_source(
                    Ok(()), Some(context.clone()), &message.id, || Ok(()), Ok(time),
                );
                assert!(error.is_none() && receipt.is_none());
                assert_eq!(receipt_error.as_deref(), Some("cloud_sync_native_mutation_prepared_time_invalid"));
            }
            assert!(cloud_sync_replay_native_send_receipts(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), None,
            ).await.unwrap().receipts.is_empty());
            // A fixed old time survives both delayed acceptance and cold replay.
            let source = cloud_sync_send_source(Some(&context), &message).unwrap();
            let mut prepared = message.clone();
            prepared.prepare_send(&[message.sender.clone().unwrap()]);
            prepared.sent_timestamp = 123;
            let validation = cloud_sync_validate_prepared_send_source(source, &prepared, 120, 130);
            let (_, receipt, error) = cloud_sync_send_confirmation_fields_with_source(
                Ok(()), Some(context.clone()), &message.id, || Ok(()), validation,
            );
            assert!(error.is_none());
            assert_eq!(receipt.unwrap().prepared_sent_timestamp_ms, Some(123));
            assert_eq!(cloud_sync_replay_native_send_receipts(
                context.storage_directory.clone(), context.account_fingerprint.clone(),
                context.protected_store_identity.clone(), None,
            ).await.unwrap().receipts[0].prepared_sent_timestamp_ms, Some(123));
            assert_eq!(cloud_sync_open_mutation_source_bound(&context).unwrap(), original);
        }
    }

    #[test]
    fn mutation_preflight_rejects_purpose_identity_and_intent_substitution() {
        let directory = tempfile::tempdir().unwrap();
        let message = fixture(false);
        let mut context = context(directory.path(), &message);
        context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
            &context, &auth(&context), &"a".repeat(64), &message,
        ).unwrap());
        commit(&context);
        for field in 0..7 {
            let mut wrong = context.clone();
            match field {
                0 => wrong.guid_hash = "b".repeat(64),
                1 => wrong.account_fingerprint = "B".repeat(43),
                2 => wrong.protected_store_identity = format!("obcs2.store.{}", "B".repeat(43)),
                3 => wrong.source_binding.as_mut().unwrap().kind = None,
                4 => wrong.source_binding.as_mut().unwrap().source_sha256 = "b".repeat(64),
                5 => wrong.source_binding.as_mut().unwrap().payload_sha256 = "b".repeat(64),
                _ => wrong.source_binding.as_mut().unwrap().payload_length += 1,
            }
            assert!(cloud_sync_send_source(Some(&wrong), &message).is_err());
        }
        for field in 0..6 {
            let mut changed = message.clone();
            match field {
                0 => changed.id = "33333333-2222-4abc-8def-555555555555".to_owned(),
                1 => if let Message::Edit(edit) = &mut changed.message { edit.edit_part += 1; },
                2 => if let Message::Edit(edit) = &mut changed.message { edit.tuuid = "44444444-2222-4abc-8def-555555555555".to_owned(); },
                3 => changed.message = fixture(true).message,
                4 => changed.send_delivered = !changed.send_delivered,
                _ => changed.conversation.as_mut().unwrap().participants.push("mailto:other@example.invalid".to_owned()),
            }
            assert!(cloud_sync_send_source(Some(&context), &changed).is_err());
        }
    }

    #[test]
    fn accepted_but_changed_mutation_never_authorizes_cloudkit_or_resend() {
        let directory = tempfile::tempdir().unwrap();
        let message = fixture(true);
        let mut context = context(directory.path(), &message);
        context.source_binding = Some(cloud_sync_stage_mutation_source_bound(
            &context, &auth(&context), &"a".repeat(64), &message,
        ).unwrap());
        commit(&context);
        let source = cloud_sync_send_source(Some(&context), &message).unwrap();
        let mut prepared = message.clone();
        let start = systemtime_to_millis(SystemTime::now());
        prepared.prepare_send(&[message.sender.clone().unwrap()]);
        let finish = systemtime_to_millis(SystemTime::now());
        if let Message::Unsend(unsend) = &mut prepared.message { unsend.edit_part += 1; }
        let validation = cloud_sync_validate_prepared_send_source(source, &prepared, start, finish);
        assert_eq!(validation, Err("cloud_sync_native_mutation_prepared_source_changed"));
        let (error, receipt, receipt_error) = cloud_sync_send_confirmation_fields_with_source(
            Ok(()), Some(context.clone()), &message.id, || Ok(()), validation,
        );
        assert!(error.is_none() && receipt.is_none());
        assert_eq!(receipt_error.as_deref(), Some("cloud_sync_native_mutation_prepared_source_changed"));
        let (error, receipt, _) = cloud_sync_send_confirmation_fields_with_source(
            Ok(()), Some(context), &message.id, || Err(PushError::NoValidTargets), Ok(Some(prepared.sent_timestamp)),
        );
        assert_eq!(error.as_deref(), Some("cloud_sync_native_send_failed"));
        assert!(receipt.is_none());
    }
}

#[cfg(test)]
mod cloud_sync_windows_sender_tests {
    use super::*;

    #[tokio::test]
    async fn cloud_sync_windows_sender_waits_for_actual_completion() {
        let (release, wait) = tokio::sync::oneshot::channel();
        let native = tokio::spawn(async move { wait.await.unwrap(); Ok(()) });
        let completion = tokio::spawn(cloud_sync_windows_finish_send_job(Some(native), || Ok(())));
        tokio::task::yield_now().await;
        assert!(!completion.is_finished());
        release.send(()).unwrap();
        completion.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn cloud_sync_windows_sender_failure_never_confirms() {
        let native = tokio::spawn(async { Err(PushError::TokenMissing) });
        let error = cloud_sync_windows_finish_send_job(Some(native), || panic!("failed job must not confirm")).await.unwrap_err();
        assert_eq!(error.to_string(), "cloud_sync_windows_sender_send_failed");
    }

    #[tokio::test]
    async fn cloud_sync_windows_sender_lost_job_is_unknown() {
        let native = tokio::spawn(async { std::future::pending::<Result<(), PushError>>().await });
        native.abort();
        let error = cloud_sync_windows_finish_send_job(Some(native), || panic!("lost job must not confirm")).await.unwrap_err();
        assert_eq!(error.to_string(), "cloud_sync_windows_sender_completion_unknown");
        cloud_sync_windows_finish_send_job(None, || Ok(())).await.unwrap();
    }

    #[test]
    fn ids_success_with_receipt_failure_is_not_reported_as_send_failure() {
        let stable_guid = "11111111-2222-4abc-8def-555555555555";
        let context = CloudSyncNativeSendReceiptContext {
            storage_directory: "missing-receipt-directory".to_owned(),
            guid_hash: cloud_sync_local_send_guid_hash(stable_guid),
            account_fingerprint: "A".repeat(43),
            protected_store_identity: format!("obcs2.store.{}", "S".repeat(43)),
            native_session_id: "N".repeat(43),
            source_binding: None,
        };

        let (send_error, receipt, receipt_error) =
            cloud_sync_send_confirmation_fields(Ok(()), Some(context), stable_guid, || Ok(()));
        assert_eq!(send_error, None);
        assert!(receipt.is_none());
        assert_eq!(
            receipt_error.as_deref(),
            Some("cloud_sync_native_send_receipt_persist_failed")
        );
    }

    #[tokio::test]
    async fn cloud_sync_windows_completed_job_without_acceptance_never_confirms() {
        let missing_targets = cloud_sync_windows_finish_send_job(
            None, || Err(PushError::NoValidTargets),
        ).await.unwrap_err();
        assert_eq!(missing_targets.to_string(), "cloud_sync_windows_sender_unconfirmed");
        let completed = tokio::spawn(async { Ok(()) });
        let no_ack = cloud_sync_windows_finish_send_job(
            Some(completed), || Err(PushError::SendTimedOut),
        ).await.unwrap_err();
        assert_eq!(no_ack.to_string(), "cloud_sync_windows_sender_unconfirmed");
    }

    #[test]
    fn tracked_completion_without_acceptance_never_persists_a_receipt() {
        let directory = tempfile::tempdir().expect("temp directory");
        let stable_guid = "11111111-2222-4abc-8def-555555555555";
        let context = CloudSyncNativeSendReceiptContext {
            storage_directory: directory.path().to_string_lossy().into_owned(),
            guid_hash: cloud_sync_local_send_guid_hash(stable_guid),
            account_fingerprint: "A".repeat(43),
            protected_store_identity: format!("obcs2.store.{}", "S".repeat(43)),
            native_session_id: "N".repeat(43),
            source_binding: None,
        };
        for failure in [PushError::NoValidTargets, PushError::SendTimedOut, PushError::SendErr(6005)] {
            let (error, receipt, receipt_error) = cloud_sync_send_confirmation_fields(
                Ok(()), Some(context.clone()), stable_guid, || Err(failure),
            );
            assert_eq!(error.as_deref(), Some("cloud_sync_native_send_failed"));
            assert!(receipt.is_none());
            assert!(receipt_error.is_none());
        }
        // Negative confirmation must not even initialize the protected store.
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
    }

    #[test]
    fn accepted_ids_with_changed_prepared_source_retains_delivery_but_no_receipt() {
        let directory = tempfile::tempdir().unwrap();
        let guid = "11111111-2222-4abc-8def-555555555555";
        let context = CloudSyncNativeSendReceiptContext {
            storage_directory: directory.path().to_string_lossy().into_owned(),
            guid_hash: cloud_sync_local_send_guid_hash(guid),
            account_fingerprint: "A".repeat(43),
            protected_store_identity: format!("obcs2.store.{}", "S".repeat(43)),
            native_session_id: "N".repeat(43),
            source_binding: None,
        };
        let (send_error, receipt, receipt_error) = cloud_sync_send_confirmation_fields_with_source(
            Ok(()), Some(context), guid, || Ok(()),
            Err("cloud_sync_native_attachment_prepared_source_changed"),
        );
        assert!(send_error.is_none());
        assert!(receipt.is_none());
        assert_eq!(receipt_error.as_deref(), Some("cloud_sync_native_attachment_prepared_source_changed"));
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
    }

    #[tokio::test]
    async fn source_bound_native_send_preflight_and_receipt_recover_exact_origin() {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_string_lossy().into_owned();
        let guid = "11111111-2222-4abc-8def-555555555555";
        let message = MessageInst {
            id: guid.to_owned(),
            sender: Some("mailto:sender@example.invalid".to_owned()),
            conversation: Some(rustpush::ConversationData {
                participants: vec!["mailto:peer@example.invalid".to_owned()],
                cv_name: None, sender_guid: None, after_guid: None,
            }),
            message: Message::Message(rustpush::NormalMessage {
                parts: rustpush::MessageParts(vec![rustpush::IndexedMessagePart {
                    part: rustpush::MessagePart::Attachment(rustpush::Attachment {
                        a_type: rustpush::AttachmentType::MMCS(rustpush::MMCSFile {
                            key: vec![7; 32], signature: vec![8; 21],
                            object: "synthetic-object".to_owned(),
                            url: "https://example.invalid/asset".to_owned(), size: 123,
                        }),
                        part: 0, uti_type: "public.jpeg".to_owned(),
                        mime: "image/jpeg".to_owned(), name: "synthetic.jpg".to_owned(), iris: false,
                    }), idx: Some(0), ext: None,
                }]),
                effect: None, reply_guid: None, reply_part: None, service: rustpush::MessageType::IMessage,
                subject: None, app: None, link_meta: None, voice: false, scheduled: None, embedded_profile: None,
            }),
            sent_timestamp: 123, target: None, send_delivered: false,
            verification_failed: false, certified_context: None,
        };
        let stage = crate::cloud_sync_ids_attachment_source::stage_ids_attachment_source(
            directory.path().to_path_buf(), "A".repeat(43), &"a".repeat(64),
            &message, &["synthetic-attachment".to_owned()],
        ).unwrap();
        let context = CloudSyncNativeSendReceiptContext {
            storage_directory: storage.clone(), guid_hash: cloud_sync_local_send_guid_hash(guid),
            account_fingerprint: "A".repeat(43),
            protected_store_identity: crate::cloud_sync_protector::protected_store_identity(storage.clone()).unwrap(),
            native_session_id: "N".repeat(43),
            source_binding: Some(CloudSyncNativeSendSourceBinding {
                kind: None,
                source_sha256: "a".repeat(64), protected_reference: stage.protected_reference.clone(),
                lease_reference: stage.lease_reference.clone(), payload_sha256: stage.payload_sha256.clone(),
                payload_length: stage.payload_length,
            }),
        };
        let auth = CloudSyncNativeAuthMetadata {
            account_fingerprint: context.account_fingerprint.clone(),
            protected_store_identity: context.protected_store_identity.clone(),
            native_session_id: context.native_session_id.clone(),
        };
        assert!(cloud_sync_restore_attachment_source_bound(&context, &auth).is_err());
        assert!(cloud_sync_inspect_attachment_sources_bound(&context, &auth).is_err());
        assert!(cloud_sync_attachment_send_source(Some(&context), &message).is_err());
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(), &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        ).unwrap();
        let (source, guids) = cloud_sync_attachment_send_source(Some(&context), &message).unwrap().unwrap();
        let restored = cloud_sync_restore_attachment_source_bound(&context, &auth).unwrap();
        assert!(cloud_sync_attachment_send_source(Some(&context), &restored).is_ok());
        // The retry inventory resolves the original opaque source GUID to the
        // reflected local GUID, using the same key that a subsequent CloudKit
        // read projects for the owned attachment. It never needs a new upload.
        let inventory = cloud_sync_inspect_attachment_sources_bound(&context, &auth).unwrap();
        assert_eq!(inventory.len(), 1);
        assert_eq!(inventory[0].original_attachment_guid, "synthetic-attachment");
        assert_eq!(inventory[0].reflected_attachment_guid, format!("{guid}_0"));
        let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(storage.clone()).unwrap();
        let expected_key = hasher.canonical_owned_attachment_key_hash(guid, 0).unwrap();
        assert_eq!(inventory[0].logical_entity_key_hash, expected_key.value());
        assert_eq!(format!("{:?}", inventory[0]), "CloudSyncAttachmentSourceEntry(redacted)");
        let replay_inventory = cloud_sync_inspect_attachment_sources_bound(&context, &auth).unwrap();
        assert_eq!(replay_inventory[0].logical_entity_key_hash, inventory[0].logical_entity_key_hash);
        assert_eq!(replay_inventory[0].original_attachment_guid, inventory[0].original_attachment_guid);
        for field in 0..4 {
            let mut wrong = context.clone();
            match field {
                0 => wrong.guid_hash = "b".repeat(64),
                1 => wrong.account_fingerprint = "B".repeat(43),
                2 => wrong.native_session_id = "B".repeat(43),
                _ => wrong.protected_store_identity = format!("obcs2.store.{}", "B".repeat(43)),
            }
            assert!(cloud_sync_restore_attachment_source_bound(&wrong, &auth).is_err());
            assert!(cloud_sync_inspect_attachment_sources_bound(&wrong, &auth).is_err());
        }
        let mut missing = context.clone();
        missing.source_binding = None;
        assert!(cloud_sync_restore_attachment_source_bound(&missing, &auth).is_err());
        assert!(cloud_sync_inspect_attachment_sources_bound(&missing, &auth).is_err());
        let mut corrupted = context.clone();
        corrupted.source_binding.as_mut().unwrap().payload_sha256 = "b".repeat(64);
        assert!(cloud_sync_restore_attachment_source_bound(&corrupted, &auth).is_err());
        assert!(cloud_sync_inspect_attachment_sources_bound(&corrupted, &auth).is_err());
        let mut changed = message.clone();
        changed.send_delivered = true;
        assert!(cloud_sync_attachment_send_source(Some(&context), &changed).is_err());
        let mut prepared = message;
        let start = systemtime_to_millis(SystemTime::now());
        prepared.prepare_send(&["mailto:sender@example.invalid".to_owned()]);
        let end = systemtime_to_millis(SystemTime::now());
        let validation = crate::cloud_sync_ids_attachment_source::validate_prepared_ids_attachment_source(
            &source, &prepared, &guids, start, end,
        ).map(|()| None).map_err(|_| "cloud_sync_native_attachment_prepared_source_changed");
        let (error, receipt, receipt_error) = cloud_sync_send_confirmation_fields_with_source(
            Ok(()), Some(context.clone()), guid, || Ok(()), validation,
        );
        assert!(error.is_none() && receipt_error.is_none());
        let receipt = receipt.unwrap();
        assert_eq!(receipt.guid_hash, cloud_sync_local_send_guid_hash(guid));
        assert_eq!(receipt.prepared_sent_timestamp_ms, None);
        assert_eq!(receipt.source_binding.as_ref().unwrap().payload_sha256, stage.payload_sha256);
        let replay = cloud_sync_replay_native_send_receipts(
            storage.clone(), context.account_fingerprint.clone(), context.protected_store_identity.clone(), None,
        ).await.unwrap();
        assert_eq!(replay.receipts.len(), 1);
        assert_eq!(replay.receipts[0].source_binding.as_ref().unwrap().source_sha256, "a".repeat(64));
        cloud_sync_acknowledge_native_send_receipt(
            storage, context.account_fingerprint, context.protected_store_identity, receipt,
        ).unwrap();
        // The journal-owned source survives acknowledgement of the IDS receipt.
        let recovered = crate::cloud_sync_ids_attachment_source::open_staged_ids_attachment_source(
            directory.path().to_path_buf(), "A".repeat(43), &"a".repeat(64), &stage,
        ).unwrap();
        assert_eq!(recovered.message_guid, guid);
    }

    #[test]
    fn untracked_send_keeps_legacy_completion_semantics() {
        let result = cloud_sync_send_confirmation_fields(
            Ok(()), None, "unused", || panic!("untracked send must not require strict proof"),
        );
        assert!(result.0.is_none() && result.1.is_none() && result.2.is_none());
    }

    #[tokio::test]
    async fn no_handle_success_has_durable_receipt_before_confirmation_fields_return() {
        let directory = tempfile::tempdir().expect("temp directory");
        let stable_guid = "11111111-2222-4abc-8def-555555555555";
        let account_fingerprint = "A".repeat(43);
        let protected_store_identity = crate::cloud_sync_protector::protected_store_identity(
            directory.path().to_string_lossy().into_owned(),
        )
        .expect("protected store identity");
        let context = CloudSyncNativeSendReceiptContext {
            storage_directory: directory.path().to_string_lossy().into_owned(),
            guid_hash: cloud_sync_local_send_guid_hash(stable_guid),
            account_fingerprint: account_fingerprint.clone(),
            protected_store_identity: protected_store_identity.clone(),
            native_session_id: "N".repeat(43),
            source_binding: None,
        };

        let (send_error, receipt, receipt_error) =
            cloud_sync_send_confirmation_fields(Ok(()), Some(context), stable_guid, || Ok(()));
        assert_eq!(send_error, None);
        assert_eq!(receipt_error, None);
        let receipt = receipt.expect("durable receipt returned");
        let page = cloud_sync_replay_native_send_receipts(
            directory.path().to_string_lossy().into_owned(),
            account_fingerprint,
            protected_store_identity,
            None,
        )
        .await
        .expect("replay persisted no-handle receipt");
        assert_eq!(page.receipts.len(), 1);
        assert_eq!(page.receipts[0].receipt_id, receipt.receipt_id);
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

    findmy_probe_native_read(FindMyPhoneClient::new(
        &*config.config(),
        state.dsid.clone(),
        aps.clone(),
        anisette.clone(),
        provider.clone(),
    )).await
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
    findmy_probe_native_read(client.refresh(&*config.config())).await?;
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

    let fmf_client = findmy_probe_native_read(FindMyFriendsClient::new(
        &*config.config(),
        state.dsid.clone(),
        provider.clone(),
        aps.clone(),
        anisette.clone(),
        false,
    )).await?;
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
    findmy_probe_native_read(client.refresh(&*config.config())).await?;
    Ok(client.following.clone())
}

pub async fn select_friend(
    config: &JoinedOSConfig,
    client: &mut FindMyFriendsClient<DefaultAnisetteProvider>,
    friend: Option<String>,
) -> anyhow::Result<Vec<Follow>> {
    client.selected_friend = friend;
    findmy_probe_native_read(client.refresh(&*config.config())).await?;
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

const CLOUDKIT_READ_AUTHENTICATION_CACHE_FILE: &str = "cloudkit_read_authentication.cache";
const CLOUDKIT_READ_AUTHENTICATION_KEY_ALIAS: &str = "gsa:cloudkit-read-authentication";
const CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION: u32 = 2;
const CLOUDKIT_READ_AUTHENTICATION_MAX_BYTES: u64 = 64 * 1024;

#[cfg(any(target_os = "android", target_os = "windows"))]
static CLOUDKIT_READ_AUTHENTICATION_STORAGE_LOCK: OnceLock<std::sync::Mutex<()>> = OnceLock::new();
#[cfg(any(target_os = "android", target_os = "windows"))]
static CLOUDKIT_READ_AUTHENTICATION_REVOCATIONS: OnceLock<
    std::sync::Mutex<HashMap<PathBuf, CloudKitReadAuthenticationRevoker>>,
> = OnceLock::new();
#[cfg(any(target_os = "android", target_os = "windows", test))]
static CLOUDKIT_READ_AUTHENTICATION_LIFECYCLE_GATES: OnceLock<
    std::sync::Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>,
> = OnceLock::new();
#[cfg(any(target_os = "android", target_os = "windows", test))]
static CLOUDKIT_LOGIN_LIFECYCLES: OnceLock<
    std::sync::Mutex<HashMap<PathBuf, CloudKitLoginLifecycle>>,
> = OnceLock::new();
#[cfg(any(target_os = "android", target_os = "windows"))]
static CLOUDKIT_STATE_FILE_WRITE_LOCK: OnceLock<std::sync::Mutex<()>> = OnceLock::new();

#[cfg(any(target_os = "android", target_os = "windows", test))]
#[derive(Default)]
#[frb(ignore)]
struct CloudKitLoginLifecycle {
    generation: u64,
    admissions: HashMap<usize, u64>,
}

#[cfg(any(target_os = "android", target_os = "windows", test))]
fn canonical_cloudkit_state_directory(directory: &std::path::Path) -> anyhow::Result<PathBuf> {
    fs::canonicalize(directory)
        .map_err(|_| anyhow!("CloudKit read-authentication directory is unavailable"))
}

/// Returns the single lifecycle gate for an on-disk CloudKit state directory.
/// Canonicalizing before lookup prevents equivalent path spellings from
/// creating independent gates around the same credential files.
#[cfg(any(target_os = "android", target_os = "windows", test))]
fn cloudkit_read_authentication_lifecycle_gate(
    directory: &std::path::Path,
) -> anyhow::Result<Arc<tokio::sync::Mutex<()>>> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let mut gates = CLOUDKIT_READ_AUTHENTICATION_LIFECYCLE_GATES
        .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("CloudKit read-authentication lifecycle lock was poisoned"))?;
    Ok(gates
        .entry(canonical_directory)
        .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
        .clone())
}

#[cfg(any(target_os = "android", target_os = "windows", test))]
fn cloudkit_login_advance_generation(canonical_directory: &std::path::Path) -> anyhow::Result<u64> {
    let mut lifecycles = CLOUDKIT_LOGIN_LIFECYCLES
        .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("CloudKit login lifecycle lock was poisoned"))?;
    let lifecycle = lifecycles
        .entry(canonical_directory.to_owned())
        .or_default();
    lifecycle.generation = lifecycle
        .generation
        .checked_add(1)
        .ok_or_else(|| anyhow!("CloudKit login generation was exhausted"))?;
    lifecycle.admissions.clear();
    Ok(lifecycle.generation)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn cloudkit_login_current_generation(canonical_directory: &std::path::Path) -> anyhow::Result<u64> {
    let mut lifecycles = CLOUDKIT_LOGIN_LIFECYCLES
        .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("CloudKit login lifecycle lock was poisoned"))?;
    Ok(lifecycles
        .entry(canonical_directory.to_owned())
        .or_default()
        .generation)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn cloudkit_login_generation_is_current(
    canonical_directory: &std::path::Path,
    expected_generation: u64,
) -> anyhow::Result<bool> {
    let lifecycles = CLOUDKIT_LOGIN_LIFECYCLES
        .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("CloudKit login lifecycle lock was poisoned"))?;
    Ok(lifecycles
        .get(canonical_directory)
        .is_some_and(|lifecycle| lifecycle.generation == expected_generation))
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn cloudkit_runtime_state_writer_context(
    requested_directory: &std::path::Path,
) -> anyhow::Result<(PathBuf, u64)> {
    let canonical_directory = canonical_cloudkit_state_directory(requested_directory)?;
    let generation = cloudkit_login_current_generation(&canonical_directory)?;
    Ok((canonical_directory, generation))
}

fn runtime_state_writer_setup(requested_directory: &std::path::Path) -> (PathBuf, Option<u64>) {
    #[cfg(any(target_os = "android", target_os = "windows"))]
    {
        match cloudkit_runtime_state_writer_context(requested_directory) {
            Ok((directory, generation)) => (directory, Some(generation)),
            Err(error) => {
                warn!("Runtime state writer is disabled: {error}");
                (requested_directory.to_owned(), None)
            }
        }
    }
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    {
        (requested_directory.to_owned(), None)
    }
}

#[cfg(any(target_os = "android", target_os = "windows", test))]
fn cloudkit_login_register_admission(
    canonical_directory: &std::path::Path,
    expected_generation: u64,
    account_key: usize,
) -> anyhow::Result<()> {
    let mut lifecycles = CLOUDKIT_LOGIN_LIFECYCLES
        .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("CloudKit login lifecycle lock was poisoned"))?;
    let lifecycle = lifecycles
        .entry(canonical_directory.to_owned())
        .or_default();
    if lifecycle.generation != expected_generation {
        return Err(anyhow!("CloudKit login attempt was superseded"));
    }
    lifecycle
        .admissions
        .insert(account_key, expected_generation);
    Ok(())
}

#[cfg(any(target_os = "android", target_os = "windows", test))]
fn cloudkit_login_validate_admission(
    canonical_directory: &std::path::Path,
    account_key: usize,
) -> anyhow::Result<u64> {
    let lifecycles = CLOUDKIT_LOGIN_LIFECYCLES
        .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("CloudKit login lifecycle lock was poisoned"))?;
    let lifecycle = lifecycles
        .get(canonical_directory)
        .ok_or_else(|| anyhow!("CloudKit login admission is missing"))?;
    let expected_generation = lifecycle
        .admissions
        .get(&account_key)
        .copied()
        .ok_or_else(|| anyhow!("CloudKit login admission is missing"))?;
    if lifecycle.generation != expected_generation {
        return Err(anyhow!("CloudKit login attempt was superseded"));
    }
    Ok(expected_generation)
}

#[cfg(any(target_os = "android", target_os = "windows", test))]
fn cloudkit_login_consume_admission(
    canonical_directory: &std::path::Path,
    expected_generation: u64,
    account_key: usize,
) -> anyhow::Result<()> {
    let mut lifecycles = CLOUDKIT_LOGIN_LIFECYCLES
        .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| anyhow!("CloudKit login lifecycle lock was poisoned"))?;
    let lifecycle = lifecycles
        .get_mut(canonical_directory)
        .ok_or_else(|| anyhow!("CloudKit login admission is missing"))?;
    if lifecycle.generation != expected_generation
        || lifecycle.admissions.get(&account_key) != Some(&expected_generation)
    {
        return Err(anyhow!("CloudKit login attempt was superseded"));
    }
    lifecycle.admissions.remove(&account_key);
    Ok(())
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn cloudkit_read_authentication_storage_guard() -> anyhow::Result<std::sync::MutexGuard<'static, ()>>
{
    CLOUDKIT_READ_AUTHENTICATION_STORAGE_LOCK
        .get_or_init(|| std::sync::Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("CloudKit read-authentication storage lock was poisoned"))
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn cloudkit_state_file_write_guard() -> anyhow::Result<std::sync::MutexGuard<'static, ()>> {
    CLOUDKIT_STATE_FILE_WRITE_LOCK
        .get_or_init(|| std::sync::Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("CloudKit state-file write lock was poisoned"))
}

#[cfg(any(target_os = "android", target_os = "windows"))]
async fn register_cloudkit_read_authentication_revoker(
    directory: PathBuf,
    revoker: CloudKitReadAuthenticationRevoker,
) -> anyhow::Result<()> {
    let canonical_directory = canonical_cloudkit_state_directory(&directory)?;
    let previous = {
        let mut revocations = CLOUDKIT_READ_AUTHENTICATION_REVOCATIONS
            .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
            .lock()
            .map_err(|_| anyhow!("CloudKit read-authentication registry lock was poisoned"))?;
        if revocations
            .get(&canonical_directory)
            .is_some_and(|existing| existing.is_same_generation(&revoker))
        {
            return Ok(());
        }
        revocations.insert(canonical_directory, revoker)
    };
    if let Some(previous) = previous {
        previous.revoke().await;
    }
    Ok(())
}

#[cfg(any(target_os = "android", target_os = "windows"))]
async fn revoke_registered_cloudkit_read_authentication(directory: &PathBuf) -> anyhow::Result<()> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let revoker = {
        let mut revocations = CLOUDKIT_READ_AUTHENTICATION_REVOCATIONS
            .get_or_init(|| std::sync::Mutex::new(HashMap::new()))
            .lock()
            .map_err(|_| anyhow!("CloudKit read-authentication registry lock was poisoned"))?;
        revocations.remove(&canonical_directory)
    };
    if let Some(revoker) = revoker {
        revoker.revoke().await;
    }
    Ok(())
}

#[cfg(any(target_os = "android", target_os = "windows"))]
async fn install_cloudkit_read_authentication_generation(
    canonical_directory: &PathBuf,
    token_provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
    mme_auth_token: String,
    cloudkit_token: String,
    refreshed: SystemTime,
    generation_id: String,
) -> anyhow::Result<bool> {
    let invalidation_directory = canonical_directory.clone();
    let invalidation_generation_id = generation_id.clone();
    let restored = token_provider
        .restore_cloudkit_read_authentication(
            mme_auth_token,
            cloudkit_token,
            refreshed,
            move || {
                clear_cloudkit_read_authentication_cache_generation(
                    &invalidation_directory,
                    &invalidation_generation_id,
                )
                .map(|_| ())
                .map_err(|error| {
                    PushError::IoError(std::io::Error::new(
                        ErrorKind::Other,
                        format!("CloudKit read-authentication cache invalidation failed: {error}"),
                    ))
                })
            },
        )
        .await;
    let Some(revoker) = restored else {
        return Ok(false);
    };
    if register_cloudkit_read_authentication_revoker(canonical_directory.clone(), revoker.clone())
        .await
        .is_err()
    {
        revoker.revoke().await;
        clear_cloudkit_read_authentication_cache_generation(canonical_directory, &generation_id)
            .map_err(|_| anyhow!("CloudKit read-authentication registration cleanup failed"))?;
        return Err(anyhow!(
            "CloudKit read-authentication revoker registration failed"
        ));
    }
    Ok(true)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
async fn restore_persisted_cloudkit_read_authentication(
    directory: &PathBuf,
    token_provider: &Arc<TokenProvider<DefaultAnisetteProvider>>,
) -> anyhow::Result<()> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&canonical_directory)?;
    let _lifecycle_guard = lifecycle_gate.lock().await;
    let gsa = match plist::from_file::<_, GSAConfig>(canonical_directory.join("gsa.plist")) {
        Ok(gsa) => gsa,
        Err(_) => return Ok(()),
    };

    match load_cloudkit_read_authentication_cache(&canonical_directory, &gsa.username) {
        Ok(Some((mme_auth_token, cloudkit_token, refreshed, generation_id))) => {
            match install_cloudkit_read_authentication_generation(
                &canonical_directory,
                token_provider,
                mme_auth_token,
                cloudkit_token,
                refreshed,
                generation_id,
            )
            .await?
            {
                true => {
                    info!("Restored encrypted CloudKit read-authentication cache");
                }
                false => {
                    clear_cloudkit_read_authentication_cache(&canonical_directory).map_err(
                        |_| anyhow!("Stale CloudKit read-authentication cache cleanup failed"),
                    )?;
                    warn!("Encrypted CloudKit read-authentication cache is stale");
                }
            }
        }
        Ok(None) => {}
        Err(_) => {
            clear_cloudkit_read_authentication_cache(&canonical_directory).map_err(|_| {
                anyhow!("Unreadable CloudKit read-authentication cache cleanup failed")
            })?;
            warn!("Encrypted CloudKit read-authentication cache could not be opened");
        }
    }
    Ok(())
}

/// Ensures that the isolated semantic-read credential generation is current.
///
/// A warm generation is reused without network I/O. A missing, stale, or
/// remotely invalidated generation is replenished with one bounded MobileMe
/// authentication refresh, encrypted at rest, and installed under the account
/// lifecycle gate. This function never opens a CloudKit container and cannot
/// issue record, zone, subscription, save, or delete operations.
pub async fn cloud_sync_ensure_read_authentication(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    storage_directory: String,
) -> anyhow::Result<()> {
    if cloud_messages_client
        .client
        .token_provider
        .cloudkit_read_authentication_is_warm()
        .await
        && cloud_messages_client
            .validated_native_account_identifier()
            .await
            .is_ok()
    {
        return Ok(());
    }

    #[cfg(any(target_os = "android", target_os = "windows"))]
    {
        let canonical_directory =
            canonical_cloudkit_state_directory(&PathBuf::from(storage_directory))?;
        let operation_permit = try_acquire_cloudkit_operation()
            .map_err(|_| anyhow!("cloud_sync_native_auth_refresh_writer_busy"))?;
        let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&canonical_directory)?;
        let _lifecycle_guard = lifecycle_gate.lock().await;
        let (persisted_account_identifier, _) = cloud_messages_client
            .validated_persisted_native_account_identifiers()
            .await
            .map_err(|_| anyhow!("cloud_sync_native_auth_identity_mismatch"))?;
        let account_before_refresh = cloud_messages_client
            .validated_native_account_identifier()
            .await
            .ok();
        if cloud_messages_client
            .client
            .token_provider
            .cloudkit_read_authentication_is_warm()
            .await
            && account_before_refresh
                .as_ref()
                .is_some_and(|account| account == &persisted_account_identifier)
        {
            return Ok(());
        }

        let gsa = plist::from_file::<_, GSAConfig>(canonical_directory.join("gsa.plist"))
            .map_err(|_| anyhow!("cloud_sync_native_auth_refresh_session_missing"))?;
        let active_username = cloud_messages_client
            .client
            .token_provider
            .get_gsa_email()
            .await
            .ok_or_else(|| anyhow!("cloud_sync_native_auth_refresh_session_missing"))?;
        if !active_username.eq_ignore_ascii_case(&gsa.username) {
            return Err(anyhow!("cloud_sync_native_auth_account_changed"));
        }

        let (mme_auth_token, cloudkit_token, refreshed) = match tokio::time::timeout(
            CLOUD_SYNC_READ_AUTH_WARM_TIMEOUT,
            cloud_messages_client
                .client
                .token_provider
                .refresh_cloudkit_read_authentication_material(),
        )
        .await
        {
            Ok(Ok(material)) => material,
            Ok(Err(error)) => return Err(cloud_sync_read_authentication_refresh_error(error)),
            Err(_) => return Err(anyhow!("cloud_sync_native_auth_refresh_timeout")),
        };
        let account_after_refresh = cloud_messages_client
            .validated_native_account_identifier()
            .await
            .map_err(|_| anyhow!("cloud_sync_native_auth_identity_mismatch"))?;
        if account_after_refresh != persisted_account_identifier
            || account_before_refresh
                .as_ref()
                .is_some_and(|account| account != &account_after_refresh)
        {
            return Err(anyhow!("cloud_sync_native_auth_account_changed"));
        }

        let generation_id = persist_cloudkit_read_authentication_cache(
            &canonical_directory,
            &gsa.username,
            &mme_auth_token,
            &cloudkit_token,
            refreshed,
        )
        .map_err(|_| anyhow!("cloud_sync_native_auth_refresh_state_failed"))?;
        let installed = install_cloudkit_read_authentication_generation(
            &canonical_directory,
            &cloud_messages_client.client.token_provider,
            mme_auth_token,
            cloudkit_token,
            refreshed,
            generation_id,
        )
        .await
        .map_err(|_| anyhow!("cloud_sync_native_auth_refresh_state_failed"))?;
        if !installed {
            clear_cloudkit_read_authentication_cache(&canonical_directory)
                .map_err(|_| anyhow!("cloud_sync_native_auth_refresh_state_failed"))?;
            return Err(anyhow!("cloud_sync_native_auth_refresh_failed"));
        }
        if !cloud_messages_client
            .client
            .token_provider
            .cloudkit_read_authentication_is_warm()
            .await
        {
            return Err(anyhow!("cloud_sync_native_auth_refresh_failed"));
        }
        drop(operation_permit);
        return Ok(());
    }

    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    {
        let _ = storage_directory;
        Err(anyhow!("cloud_sync_native_auth_refresh_unsupported"))
    }
}

#[cfg(any(target_os = "android", target_os = "windows"))]
async fn revoke_clear_and_reset_cloudkit_state(directory: &PathBuf) -> anyhow::Result<u64> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&canonical_directory)?;
    let _lifecycle_guard = lifecycle_gate.lock().await;
    revoke_clear_and_reset_cloudkit_state_locked(&canonical_directory).await
}

#[cfg(any(target_os = "android", target_os = "windows"))]
async fn revoke_clear_and_reset_cloudkit_state_locked(
    canonical_directory: &PathBuf,
) -> anyhow::Result<u64> {
    let generation = cloudkit_login_advance_generation(canonical_directory)?;
    revoke_registered_cloudkit_read_authentication(canonical_directory).await?;
    clear_cloudkit_read_authentication_cache(canonical_directory)?;
    reset_user(canonical_directory)?;
    Ok(generation)
}

#[derive(Serialize, Deserialize)]
struct CachedCloudKitReadAuthentication {
    schema_version: u32,
    generation_id: String,
    username: String,
    refreshed_at_millis: u64,
    mme_auth_token: String,
    cloudkit_token: String,
}

impl CachedCloudKitReadAuthentication {
    fn has_generation(&self, expected_generation_id: &str) -> bool {
        !expected_generation_id.is_empty() && self.generation_id == expected_generation_id
    }

    fn into_tokens_for_account(
        self,
        expected_username: &str,
    ) -> Option<(String, String, SystemTime, String)> {
        if self.schema_version != CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION
            || self.generation_id.is_empty()
            || !self.username.eq_ignore_ascii_case(expected_username)
            || self.mme_auth_token.is_empty()
            || self.cloudkit_token.is_empty()
        {
            return None;
        }
        let refreshed =
            SystemTime::UNIX_EPOCH.checked_add(Duration::from_millis(self.refreshed_at_millis))?;
        Some((
            self.mme_auth_token,
            self.cloudkit_token,
            refreshed,
            self.generation_id,
        ))
    }
}

#[cfg(any(target_os = "android", target_os = "windows", test))]
fn cloudkit_read_authentication_key_alias(canonical_directory: &std::path::Path) -> String {
    let directory_identity = canonical_directory.as_os_str().to_string_lossy();
    #[cfg(target_os = "windows")]
    let directory_identity = directory_identity.to_lowercase();
    let digest = Sha256::digest(directory_identity.as_bytes());
    format!(
        "{}:{}",
        CLOUDKIT_READ_AUTHENTICATION_KEY_ALIAS,
        encode_hex(&digest[..16])
    )
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn cloudkit_read_authentication_key(
    canonical_directory: &std::path::Path,
) -> Result<AesKeystoreKey, PushError> {
    Ok(AesKeystoreKey::ensure(
        &cloudkit_read_authentication_key_alias(canonical_directory),
        256,
        KeystoreAccessRules {
            block_modes: vec![EncryptMode::Gcm],
            can_encrypt: true,
            can_decrypt: true,
            ..Default::default()
        },
    )?)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn persist_state_bytes_atomically(
    canonical_directory: &std::path::Path,
    file_name: &str,
    temporary_label: &str,
    serialized: &[u8],
) -> anyhow::Result<()> {
    let destination = canonical_directory.join(file_name);
    let temporary =
        canonical_directory.join(format!(".{}.{}.tmp", temporary_label, Uuid::new_v4()));
    let result = (|| -> anyhow::Result<()> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)?;
        file.write_all(serialized)?;
        file.sync_all()?;
        drop(file);

        install_state_file_atomically(&temporary, &destination)?;
        if fs::read(&destination)? != serialized {
            return Err(anyhow!("State replacement verification failed"));
        }
        OpenOptions::new()
            .write(true)
            .open(&destination)?
            .sync_all()?;
        #[cfg(target_os = "android")]
        File::open(canonical_directory)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn persist_login_state_file(
    directory: &std::path::Path,
    file_name: &str,
    serialized: &[u8],
) -> anyhow::Result<()> {
    #[cfg(any(target_os = "android", target_os = "windows"))]
    {
        persist_state_bytes_atomically(directory, file_name, file_name, serialized)
    }
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    {
        let destination = directory.join(file_name);
        fs::write(&destination, serialized)?;
        File::open(destination)?.sync_all()?;
        Ok(())
    }
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn persist_runtime_state_file(
    canonical_directory: &std::path::Path,
    file_name: &str,
    serialized: &[u8],
    expected_generation: u64,
) -> anyhow::Result<()> {
    let _write_guard = cloudkit_state_file_write_guard()?;
    if !cloudkit_login_generation_is_current(canonical_directory, expected_generation)? {
        return Err(anyhow!("Runtime state writer was superseded"));
    }
    persist_state_bytes_atomically(canonical_directory, file_name, file_name, serialized)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn persist_runtime_plist_state<T: serde::Serialize>(
    canonical_directory: &std::path::Path,
    file_name: &str,
    value: &T,
    expected_generation: u64,
) -> anyhow::Result<()> {
    let mut serialized = Vec::new();
    plist::to_writer_xml(&mut serialized, value)?;
    persist_runtime_state_file(
        canonical_directory,
        file_name,
        &serialized,
        expected_generation,
    )
}

#[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
fn persist_runtime_plist_state<T: serde::Serialize>(
    directory: &std::path::Path,
    file_name: &str,
    value: &T,
) -> anyhow::Result<()> {
    let mut serialized = Vec::new();
    plist::to_writer_xml(&mut serialized, value)?;
    persist_login_state_file(directory, file_name, &serialized)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn persist_gsa_config_atomically(
    canonical_directory: &std::path::Path,
    config: &GSAConfig,
) -> anyhow::Result<()> {
    let mut serialized = Vec::new();
    plist::to_writer_xml(&mut serialized, config)?;
    persist_state_bytes_atomically(canonical_directory, "gsa.plist", "gsa", &serialized)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn persist_cloudkit_read_authentication_cache(
    directory: &PathBuf,
    username: &str,
    mme_auth_token: &str,
    cloudkit_token: &str,
    refreshed: SystemTime,
) -> anyhow::Result<String> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let _storage_guard = cloudkit_read_authentication_storage_guard()?;
    let generation_id = Uuid::new_v4().to_string();
    let cached = CachedCloudKitReadAuthentication {
        schema_version: CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION,
        generation_id: generation_id.clone(),
        username: username.to_owned(),
        refreshed_at_millis: systemtime_to_millis(refreshed),
        mme_auth_token: mme_auth_token.to_owned(),
        cloudkit_token: cloudkit_token.to_owned(),
    };
    let mut serialized = Vec::new();
    plist::to_writer_binary(Cursor::new(&mut serialized), &cached)?;
    let encrypted = cloudkit_read_authentication_key(&canonical_directory)?
        .encrypt(&serialized, &mut EncryptMode::Gcm)?;

    persist_state_bytes_atomically(
        &canonical_directory,
        CLOUDKIT_READ_AUTHENTICATION_CACHE_FILE,
        "cloudkit_read_authentication",
        &encrypted,
    )?;
    Ok(generation_id)
}

#[cfg(target_os = "android")]
fn install_state_file_atomically(
    temporary: &std::path::Path,
    destination: &std::path::Path,
) -> anyhow::Result<()> {
    fs::rename(temporary, destination)?;
    Ok(())
}

#[cfg(target_os = "windows")]
fn install_state_file_atomically(
    temporary: &std::path::Path,
    destination: &std::path::Path,
) -> anyhow::Result<()> {
    if destination.is_file() {
        replace_file_without_backup(destination, temporary)?;
    } else {
        fs::rename(temporary, destination)?;
    }
    Ok(())
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn load_cloudkit_read_authentication_cache(
    directory: &PathBuf,
    expected_username: &str,
) -> anyhow::Result<Option<(String, String, SystemTime, String)>> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let _storage_guard = cloudkit_read_authentication_storage_guard()?;
    let Some(cached) = read_cloudkit_read_authentication_cache_locked(&canonical_directory)? else {
        return Ok(None);
    };
    cached
        .into_tokens_for_account(expected_username)
        .map(Some)
        .ok_or_else(|| anyhow!("CloudKit read-authentication cache identity is invalid"))
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn read_cloudkit_read_authentication_cache_locked(
    directory: &std::path::Path,
) -> anyhow::Result<Option<CachedCloudKitReadAuthentication>> {
    let path = directory.join(CLOUDKIT_READ_AUTHENTICATION_CACHE_FILE);
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let length = file.metadata()?.len();
    if length == 0 || length > CLOUDKIT_READ_AUTHENTICATION_MAX_BYTES {
        return Err(anyhow!(
            "CloudKit read-authentication cache size is invalid"
        ));
    }
    let mut encrypted = Vec::with_capacity(length as usize);
    file.take(CLOUDKIT_READ_AUTHENTICATION_MAX_BYTES + 1)
        .read_to_end(&mut encrypted)?;
    if encrypted.len() as u64 > CLOUDKIT_READ_AUTHENTICATION_MAX_BYTES {
        return Err(anyhow!("CloudKit read-authentication cache is too large"));
    }
    let decrypted =
        cloudkit_read_authentication_key(directory)?.decrypt(&encrypted, &mut EncryptMode::Gcm)?;
    let cached: CachedCloudKitReadAuthentication = plist::from_bytes(&decrypted)?;
    Ok(Some(cached))
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn clear_cloudkit_read_authentication_cache(directory: &PathBuf) -> anyhow::Result<()> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let _storage_guard = cloudkit_read_authentication_storage_guard()?;
    clear_cloudkit_read_authentication_cache_locked(&canonical_directory)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn clear_cloudkit_read_authentication_cache_generation(
    directory: &std::path::Path,
    expected_generation_id: &str,
) -> anyhow::Result<bool> {
    let canonical_directory = canonical_cloudkit_state_directory(directory)?;
    let _storage_guard = cloudkit_read_authentication_storage_guard()?;
    let Some(cached) = read_cloudkit_read_authentication_cache_locked(&canonical_directory)? else {
        return Ok(false);
    };
    if !cached.has_generation(expected_generation_id) {
        return Ok(false);
    }
    clear_cloudkit_read_authentication_cache_locked(&canonical_directory)?;
    Ok(true)
}

#[cfg(any(target_os = "android", target_os = "windows"))]
fn clear_cloudkit_read_authentication_cache_locked(
    directory: &std::path::Path,
) -> anyhow::Result<()> {
    let key_result = keystore().destroy_key(&cloudkit_read_authentication_key_alias(directory));
    let file_result = match fs::remove_file(directory.join(CLOUDKIT_READ_AUTHENTICATION_CACHE_FILE))
    {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    };
    key_result?;
    file_result?;
    Ok(())
}

#[cfg(test)]
mod cloudkit_read_authentication_cache_tests {
    use super::{
        canonical_cloudkit_state_directory, cloudkit_login_advance_generation,
        cloudkit_login_consume_admission, cloudkit_login_register_admission,
        cloudkit_login_validate_admission, cloudkit_read_authentication_key_alias,
        cloudkit_read_authentication_lifecycle_gate, reset_user,
        two_factor_fresh_login_is_authenticated, two_factor_verification_authorizes_fresh_login,
        CachedCloudKitReadAuthentication, LoginState, CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION,
    };
    use std::{
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
        time::{Duration, SystemTime},
    };

    fn cache(username: &str, schema_version: u32) -> CachedCloudKitReadAuthentication {
        CachedCloudKitReadAuthentication {
            schema_version,
            generation_id: "test-generation".to_owned(),
            username: username.to_owned(),
            refreshed_at_millis: 1_000,
            mme_auth_token: "test-mme-token".to_owned(),
            cloudkit_token: "test-cloudkit-token".to_owned(),
        }
    }

    #[test]
    fn read_authentication_payload_is_bound_to_the_same_account() {
        let (mme_auth_token, cloudkit_token, refreshed, generation_id) = cache(
            "person@example.com",
            CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION,
        )
        .into_tokens_for_account("PERSON@example.com")
        .expect("same account should restore");

        assert_eq!(mme_auth_token, "test-mme-token");
        assert_eq!(cloudkit_token, "test-cloudkit-token");
        assert_eq!(generation_id, "test-generation");
        assert_eq!(
            refreshed.duration_since(SystemTime::UNIX_EPOCH).unwrap(),
            std::time::Duration::from_secs(1)
        );
    }

    #[test]
    fn read_authentication_payload_rejects_another_account_or_schema() {
        assert!(cache(
            "person@example.com",
            CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION
        )
        .into_tokens_for_account("other@example.com")
        .is_none());
        assert!(cache(
            "person@example.com",
            CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION + 1
        )
        .into_tokens_for_account("person@example.com")
        .is_none());
    }

    #[test]
    fn persisted_generation_compare_rejects_stale_invalidator() {
        let cached = cache(
            "person@example.com",
            CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION,
        );
        assert!(cached.has_generation("test-generation"));
        assert!(!cached.has_generation("older-generation"));
        assert!(!cached.has_generation(""));
    }

    #[test]
    fn cache_key_alias_is_scoped_to_canonical_directory() {
        let root = std::env::temp_dir().join(format!(
            "openbubbles-cloudkit-key-alias-{}",
            uuid::Uuid::new_v4()
        ));
        let first = root.join("first");
        let second = root.join("second");
        std::fs::create_dir_all(&first).expect("create first cache directory");
        std::fs::create_dir_all(&second).expect("create second cache directory");
        let first = canonical_cloudkit_state_directory(&first).expect("canonical first directory");
        let second =
            canonical_cloudkit_state_directory(&second).expect("canonical second directory");
        let first_alias = canonical_cloudkit_state_directory(&first.join("."))
            .expect("canonical alias for first directory");

        assert_eq!(
            cloudkit_read_authentication_key_alias(&first),
            cloudkit_read_authentication_key_alias(&first_alias)
        );
        assert_ne!(
            cloudkit_read_authentication_key_alias(&first),
            cloudkit_read_authentication_key_alias(&second)
        );

        std::fs::remove_dir_all(&root).expect("remove key alias test directories");
    }

    #[test]
    fn read_authentication_payload_rejects_missing_required_token() {
        let mut cached = cache(
            "person@example.com",
            CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION,
        );
        cached.mme_auth_token.clear();
        assert!(cached
            .into_tokens_for_account("person@example.com")
            .is_none());

        let mut cached = cache(
            "person@example.com",
            CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION,
        );
        cached.generation_id.clear();
        assert!(cached
            .into_tokens_for_account("person@example.com")
            .is_none());

        let mut cached = cache(
            "person@example.com",
            CLOUDKIT_READ_AUTHENTICATION_SCHEMA_VERSION,
        );
        cached.cloudkit_token.clear();
        assert!(cached
            .into_tokens_for_account("person@example.com")
            .is_none());
    }

    #[tokio::test]
    async fn lifecycle_gate_serializes_restore_against_logout_for_canonical_path() {
        let directory = std::env::temp_dir().join(format!(
            "openbubbles-cloudkit-read-auth-lifecycle-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&directory).expect("create lifecycle test directory");

        let restore_gate =
            cloudkit_read_authentication_lifecycle_gate(&directory).expect("restore gate");
        let logout_gate =
            cloudkit_read_authentication_lifecycle_gate(&directory.join(".")).expect("logout gate");
        assert!(Arc::ptr_eq(&restore_gate, &logout_gate));

        let restore_guard = restore_gate.lock().await;
        let logout_entered = Arc::new(AtomicBool::new(false));
        let logout_entered_task = logout_entered.clone();
        let (attempted_tx, attempted_rx) = tokio::sync::oneshot::channel();
        let logout_task = tokio::spawn(async move {
            let _ = attempted_tx.send(());
            let _logout_guard = logout_gate.lock().await;
            logout_entered_task.store(true, Ordering::SeqCst);
        });

        attempted_rx.await.expect("logout attempted lifecycle lock");
        tokio::task::yield_now().await;
        assert!(!logout_entered.load(Ordering::SeqCst));

        drop(restore_guard);
        tokio::time::timeout(Duration::from_secs(1), logout_task)
            .await
            .expect("logout acquired lifecycle lock")
            .expect("logout task completed");
        assert!(logout_entered.load(Ordering::SeqCst));

        std::fs::remove_dir(&directory).expect("remove lifecycle test directory");
    }

    #[test]
    fn generation_advance_invalidates_stale_login_admission() {
        let directory = std::env::temp_dir().join(format!(
            "openbubbles-cloudkit-login-generation-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&directory).expect("create login generation test directory");
        let canonical_directory =
            canonical_cloudkit_state_directory(&directory).expect("canonical directory");
        let account_key = 41usize;

        let initial_generation =
            cloudkit_login_advance_generation(&canonical_directory).expect("initial generation");
        cloudkit_login_register_admission(&canonical_directory, initial_generation, account_key)
            .expect("register initial admission");
        assert_eq!(
            cloudkit_login_validate_admission(&canonical_directory, account_key)
                .expect("initial admission is current"),
            initial_generation
        );

        let replacement_generation =
            cloudkit_login_advance_generation(&canonical_directory).expect("advance generation");
        assert!(replacement_generation > initial_generation);
        assert!(cloudkit_login_validate_admission(&canonical_directory, account_key).is_err());
        assert!(cloudkit_login_register_admission(
            &canonical_directory,
            initial_generation,
            account_key,
        )
        .is_err());

        cloudkit_login_register_admission(
            &canonical_directory,
            replacement_generation,
            account_key,
        )
        .expect("register replacement admission");
        cloudkit_login_consume_admission(&canonical_directory, replacement_generation, account_key)
            .expect("consume replacement admission");
        assert!(cloudkit_login_validate_admission(&canonical_directory, account_key).is_err());

        std::fs::remove_dir(&directory).expect("remove login generation test directory");
    }

    #[test]
    fn reset_user_surfaces_deletion_failure_before_accepting_new_state() {
        let directory = std::env::temp_dir().join(format!(
            "openbubbles-cloudkit-reset-failure-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(directory.join("gsa.plist"))
            .expect("create undeletable-as-file GSA path");
        std::fs::write(directory.join("findmy.plist"), b"old-account-state")
            .expect("write old account state");

        assert!(reset_user(&directory).is_err());
        assert!(directory.join("findmy.plist").is_file());

        std::fs::remove_dir_all(&directory).expect("remove reset failure test directory");
    }

    #[test]
    fn two_factor_state_requires_a_fresh_authenticated_login() {
        assert!(two_factor_verification_authorizes_fresh_login(
            &LoginState::NeedsLogin
        ));
        assert!(two_factor_verification_authorizes_fresh_login(
            &LoginState::LoggedIn
        ));
        assert!(!two_factor_verification_authorizes_fresh_login(
            &LoginState::NeedsDevice2FA
        ));
        assert!(two_factor_fresh_login_is_authenticated(
            &LoginState::LoggedIn,
            true
        ));
        assert!(!two_factor_fresh_login_is_authenticated(
            &LoginState::LoggedIn,
            false
        ));
        assert!(!two_factor_fresh_login_is_authenticated(
            &LoginState::NeedsLogin,
            true
        ));
    }
}

pub async fn do_login(
    path: String,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    finish: Option<UpdateAccountFinish>,
    os_config: &JoinedOSConfig,
) -> anyhow::Result<IDSUser> {
    let requested_conf_dir = PathBuf::from_str(&path).unwrap();
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let conf_dir = canonical_cloudkit_state_directory(&requested_conf_dir)?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let conf_dir = requested_conf_dir;

    // The directory gate must be acquired before the account lock. Logout and
    // account replacement take the same gate, advance the generation, and
    // remove every outstanding admission before clearing persistent state.
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let canonical_conf_dir = conf_dir.clone();
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&conf_dir)?;
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let _lifecycle_guard = lifecycle_gate.lock().await;
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let login_account_key = Arc::as_ptr(account) as usize;
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let expected_login_generation =
        cloudkit_login_validate_admission(&canonical_conf_dir, login_account_key)?;

    let mut account = account.lock().await;

    account
        .update_postdata("Apple Device", None, &["icloud", "imessage", "facetime"])
        .await?;

    let Some(_pet) = account.get_pet() else {
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
    let _acname = spd
        .get("acname")
        .ok_or(anyhow!("No acname!"))?
        .as_string()
        .ok_or_else(|| anyhow!("Invalid acname!"))?
        .to_string();
    let dsid = spd
        .get("DsPrsId")
        .ok_or(anyhow!("No dsid!"))?
        .as_unsigned_integer()
        .ok_or_else(|| anyhow!("Invalid dsid!"))?
        .to_string();
    let adsid = spd
        .get("adsid")
        .ok_or(anyhow!("No adsid!"))?
        .as_string()
        .ok_or_else(|| anyhow!("Invalid adsid!"))?
        .to_owned();

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

    let ids = delegates
        .ids
        .ok_or_else(|| anyhow!("IDS delegate was missing"))?;
    let mobileme = delegates
        .mobileme
        .ok_or_else(|| anyhow!("MobileMe delegate was missing"))?;
    let username = account
        .username
        .clone()
        .ok_or_else(|| anyhow!("Apple Account username was missing"))?;
    let hashed_password = account
        .hashed_password
        .clone()
        .ok_or_else(|| anyhow!("Apple Account password digest was missing"))?;
    let gsa = GSAConfig {
        username: username.clone(),
        encrypted_password: GSAConfig::encrypt(&hashed_password)?,
        postdata_done: Some(true),
    };

    let findmy = FindMyState::new(dsid.clone());
    let shared_streams = SharedStreamsState::new(dsid.clone(), &mobileme);
    let cloudkitstate = CloudKitState::new(dsid.clone())
        .ok_or_else(|| anyhow!("CloudKit delegate tokens were missing"))?;
    let keychain = KeychainClientState::new(dsid.clone(), adsid, &mobileme)
        .ok_or_else(|| anyhow!("Keychain delegate tokens were missing"))?;

    debug!("Spd finish parse");

    // Remote authentication must succeed before the first local state write.
    // gsa.plist is written last and acts as the local commit marker.
    let user = authenticate_apple(ids, &*os_config.config()).await?;

    let statuskit_path = conf_dir.join("statuskit.plist");
    let statuskit = plist_to_string(&StatusKitState {
        my_key: None,
        ..plist::from_file(&statuskit_path).unwrap_or_default()
    })?;
    persist_login_state_file(&conf_dir, "statuskit.plist", statuskit.as_bytes())?;

    let findmy_path = conf_dir.join("findmy.plist");
    if !findmy_path.exists() {
        let encoded = findmy.encode()?;
        persist_login_state_file(&conf_dir, "findmy.plist", &encoded)?;
    }

    if let Some(shared_streams) = shared_streams {
        let shared_streams_path = conf_dir.join("sharedstreams.plist");
        if !shared_streams_path.exists() {
            let encoded = plist_to_string(&shared_streams)?;
            persist_login_state_file(&conf_dir, "sharedstreams.plist", encoded.as_bytes())?;
        }
    } else {
        warn!("missing shared streams tokens!");
    }

    let cloudkit_path = conf_dir.join("cloudkit.plist");
    if !cloudkit_path.exists() {
        let encoded = plist_to_string(&cloudkitstate)?;
        persist_login_state_file(&conf_dir, "cloudkit.plist", encoded.as_bytes())?;
    }

    let keychain_path = conf_dir.join("keychain.plist");
    if !keychain_path.exists() {
        let encoded = plist_to_string(&keychain)?;
        persist_login_state_file(&conf_dir, "keychain.plist", encoded.as_bytes())?;
    }

    #[cfg(any(target_os = "android", target_os = "windows"))]
    {
        let (mme_auth_token, cloudkit_token) = match (
            mobileme.tokens.get("mmeAuthToken"),
            mobileme.tokens.get("cloudKitToken"),
        ) {
            (Some(mme_auth_token), Some(cloudkit_token)) => (mme_auth_token, cloudkit_token),
            _ => {
                clear_cloudkit_read_authentication_cache(&conf_dir)?;
                return Err(anyhow!("CloudKit read-authentication tokens were missing"));
            }
        };
        if let Err(persist_error) = persist_cloudkit_read_authentication_cache(
            &conf_dir,
            &username,
            mme_auth_token,
            cloudkit_token,
            SystemTime::now(),
        ) {
            return match clear_cloudkit_read_authentication_cache(&conf_dir) {
                Ok(()) => Err(anyhow!(
                    "CloudKit read-authentication cache could not be persisted: {persist_error}"
                )),
                Err(cleanup_error) => Err(anyhow!(
                    "CloudKit read-authentication persistence failed ({persist_error}); cleanup failed ({cleanup_error})"
                )),
            };
        }
    }

    #[cfg(any(target_os = "android", target_os = "windows"))]
    if let Err(gsa_error) = persist_gsa_config_atomically(&conf_dir, &gsa) {
        return match clear_cloudkit_read_authentication_cache(&conf_dir) {
            Ok(()) => Err(anyhow!("GSA state could not be committed: {gsa_error}")),
            Err(cleanup_error) => Err(anyhow!(
                "GSA state commit failed ({gsa_error}); CloudKit cache cleanup failed ({cleanup_error})"
            )),
        };
    }
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    plist::to_file_xml(conf_dir.join("gsa.plist"), &gsa)?;

    #[cfg(any(target_os = "android", target_os = "windows"))]
    cloudkit_login_consume_admission(
        &canonical_conf_dir,
        expected_login_generation,
        login_account_key,
    )?;

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
    let requested_conf_dir = PathBuf::from_str(&path).unwrap();
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let conf_dir = canonical_cloudkit_state_directory(&requested_conf_dir)?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let conf_dir = requested_conf_dir;

    #[cfg(any(target_os = "android", target_os = "windows"))]
    let (canonical_conf_dir, expected_login_generation) = if creds.is_some() {
        let canonical_conf_dir = conf_dir.clone();
        let expected_login_generation = revoke_clear_and_reset_cloudkit_state(&conf_dir).await?;
        (canonical_conf_dir, expected_login_generation)
    } else {
        let canonical_conf_dir = conf_dir.clone();
        let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&conf_dir)?;
        let _lifecycle_guard = lifecycle_gate.lock().await;
        let _state_write_guard = cloudkit_state_file_write_guard()?;
        let expected_login_generation = cloudkit_login_advance_generation(&canonical_conf_dir)?;
        (canonical_conf_dir, expected_login_generation)
    };

    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    if creds.is_some() {
        reset_user(&conf_dir)?;
    }

    info!("Here");
    let mut apple_account = AppleAccount::new_with_anisette(
        get_login_config(&conf_dir, conf, conn).await,
        anisette.clone(),
    )?;

    let result = if let Some((username, password)) = creds {
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

    #[cfg(any(target_os = "android", target_os = "windows"))]
    {
        let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&conf_dir)?;
        let _lifecycle_guard = lifecycle_gate.lock().await;
        cloudkit_login_register_admission(
            &canonical_conf_dir,
            expected_login_generation,
            Arc::as_ptr(&account) as usize,
        )?;
    }

    #[cfg(target_os = "windows")]
    if is_cloud_sync_windows_dev_profile(&path) && matches!(&login_state, LoginState::LoggedIn) {
        if account.lock().await.get_pet().is_none() {
            return Err(anyhow!(
                "Windows read authentication login did not produce a PET"
            ));
        }
        cloud_sync_windows_consume_login_admission(&path, &account).await?;
    }

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
    let spd = account
        .spd
        .as_ref()
        .ok_or_else(|| anyhow!("Trusted-device 2FA session is unavailable"))?;
    let dsid = spd
        .get("DsPrsId")
        .and_then(Value::as_unsigned_integer)
        .filter(|value| *value != 0)
        .ok_or_else(|| anyhow!("Trusted-device 2FA account is unavailable"))?;
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
        PushError::AnisetteError(error) => match error {
            rustpush::AnisetteError::ReqwestError(error) => {
                if error.is_timeout() || error.is_connect() {
                    (CloudSyncRawFailureCategory::Network, "network")
                } else {
                    match error.status().map(|status| status.as_u16()) {
                        Some(408) => (
                            CloudSyncRawFailureCategory::Network,
                            "native-auth-unavailable",
                        ),
                        Some(429) => (
                            CloudSyncRawFailureCategory::Throttled,
                            "native-auth-unavailable",
                        ),
                        Some(500..=599) => (
                            CloudSyncRawFailureCategory::Server,
                            "native-auth-unavailable",
                        ),
                        _ => (
                            CloudSyncRawFailureCategory::Authorization,
                            "native-auth-unavailable",
                        ),
                    }
                }
            }
            rustpush::AnisetteError::WsError(_)
            | rustpush::AnisetteError::ProvisioningSocketClosed => (
                CloudSyncRawFailureCategory::Network,
                "native-auth-unavailable",
            ),
            rustpush::AnisetteError::ProvisioningServerError(_) => (
                CloudSyncRawFailureCategory::Server,
                "native-auth-unavailable",
            ),
            _ => (
                CloudSyncRawFailureCategory::Authorization,
                "native-auth-unavailable",
            ),
        },
        PushError::CloudKitSemanticOperationDenied => (
            CloudSyncRawFailureCategory::Authorization,
            "read-authentication-scope",
        ),
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
        | PushError::BadMsg
        | PushError::PlistError(_)
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
    fn writer_preparation_diagnostics_never_format_private_error_contents() {
        let cases = [
            (PushError::TokenMissing, "token-missing"),
            (PushError::CloudKitWarmAuthenticationRequired, "warm-auth-required"),
            (PushError::CloudKitSemanticOperationDenied, "writer-scope-denied"),
            (PushError::DelegateLoginFailed("private-delegate".into(), 123,
                "private-response".into()), "delegate-login-failed"),
            (PushError::AuthError(Value::String("private-token".into())),
                "authentication-rejected"),
            (PushError::CloudKeyNotFound { zone: "private-zone".into(), class: "private-class".into() },
                "pcs-key-missing"),
            (PushError::CloudKitHttpError { status: 503, retry_after: None }, "http-server"),
        ];
        for (error, expected) in cases {
            assert_eq!(cloud_sync_writer_preparation_failure_code(&error), expected);
            let wrapped = PushError::DoNotRetry(Box::new(PushError::BatchError(Arc::new(error))));
            assert_eq!(cloud_sync_writer_preparation_failure_code(&wrapped), expected);
        }
        let mut deep = PushError::TokenMissing;
        for _ in 0..8 { deep = PushError::DoNotRetry(Box::new(deep)); }
        assert_eq!(cloud_sync_writer_preparation_failure_code(&deep), "error-wrapper-limit");
    }

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

    #[test]
    fn raw_semantic_failures_have_specific_content_free_codes() {
        let cases = [
            (
                PushError::AnisetteError(rustpush::AnisetteError::AnisetteNotProvisioned),
                CloudSyncRawFailureCategory::Authorization,
                "native-auth-unavailable",
            ),
            (
                PushError::AnisetteError(rustpush::AnisetteError::ProvisioningServerError(
                    "private-message-sentinel".to_owned(),
                )),
                CloudSyncRawFailureCategory::Server,
                "native-auth-unavailable",
            ),
            (
                PushError::CloudKitSemanticOperationDenied,
                CloudSyncRawFailureCategory::Authorization,
                "read-authentication-scope",
            ),
            (
                PushError::BadMsg,
                CloudSyncRawFailureCategory::MalformedRecord,
                "malformed-response",
            ),
        ];

        for (error, expected_category, expected_safe_code) in cases {
            let (category, safe_code) = cloud_sync_failure_category(&error);
            assert_eq!(category, expected_category);
            assert_eq!(safe_code, expected_safe_code);
            assert_ne!(safe_code, "unknown");
            assert!(!safe_code.contains("private-message-sentinel"));
        }
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

/// Reject ambiguous identities before opening files or initializing a container.
fn preflight_upload_request_records(files: &[(String, String)]) -> anyhow::Result<()> {
    let mut seen: HashSet<&str> = HashSet::new();
    for (_, record) in files {
        if record.is_empty() {
            return Err(anyhow!("upload request record identifier was missing"));
        }
        if !seen.insert(record.as_str()) {
            return Err(anyhow!("duplicate upload request record"));
        }
    }
    Ok(())
}
/// Bind by record identity, not the first matching content signature. Distinct
/// records may have identical bytes. These IDs are constructed by rustpush from
/// the request: correlation is not proof that a CloudKit record was saved.
fn match_upload_results_to_records(
    expected: &[(String, Vec<u8>)],
    results: Vec<Asset>,
) -> anyhow::Result<HashMap<String, Asset>> {
    let mut expected_sigs: HashMap<&str, &[u8]> = HashMap::new();
    for (record, sig) in expected {
        if sig.is_empty() {
            return Err(anyhow!("upload request signature was missing"));
        }
        if expected_sigs
            .insert(record.as_str(), sig.as_slice())
            .is_some()
        {
            return Err(anyhow!("duplicate upload request record"));
        }
    }
    if results.len() != expected.len() {
        return Err(anyhow!(
            "upload result count mismatch: expected {} results, got {}",
            expected.len(),
            results.len()
        ));
    }
    let mut finish: HashMap<String, Asset> = HashMap::with_capacity(results.len());
    for result in results {
        let name = result
            .record_id
            .as_ref()
            .and_then(|id| id.value.as_ref())
            .and_then(|value| value.name.as_deref())
            .filter(|name| !name.is_empty())
            .ok_or_else(|| anyhow!("upload result was missing its record identifier"))?;
        let expected_sig = expected_sigs
            .get(name)
            .ok_or_else(|| anyhow!("upload result referenced an unexpected record"))?;
        let actual_sig = result
            .signature
            .as_deref()
            .ok_or_else(|| anyhow!("upload result was missing its signature"))?;
        if actual_sig != *expected_sig {
            return Err(anyhow!("upload result signature mismatch"));
        }
        if finish.insert(name.to_string(), result).is_some() {
            return Err(anyhow!("duplicate upload result record"));
        }
    }
    if finish.len() != expected.len() {
        return Err(anyhow!("upload reply was missing results"));
    }
    Ok(finish)
}

pub async fn upload_cloud_attachments(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    files: Vec<(String, String)>,
) -> anyhow::Result<HashMap<String, Asset>> {
    preflight_upload_request_records(&files)?;
    if files.is_empty() {
        return Ok(HashMap::new());
    }
    let mut to_upload = vec![];
    let mut expected: Vec<(String, Vec<u8>)> = vec![];
    for (file, record) in &files {
        let prepared = cloud_messages_client
            .prepare_file(std::fs::File::open(file)?)
            .await?;
        expected.push((record.clone(), prepared.total_sig.clone()));
        to_upload.push((prepared, std::fs::File::open(file)?, record.clone()));
    }

    let results = cloud_messages_client.upload_attachments(to_upload).await?;

    match_upload_results_to_records(&expected, results)
}

pub async fn upload_group_photo(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    files: Vec<(String, String)>,
) -> anyhow::Result<HashMap<String, Asset>> {
    preflight_upload_request_records(&files)?;
    if files.is_empty() {
        return Ok(HashMap::new());
    }
    let mut to_upload = vec![];
    let mut expected: Vec<(String, Vec<u8>)> = vec![];
    for (file, record) in &files {
        let prepared = cloud_messages_client
            .prepare_file(std::fs::File::open(file)?)
            .await?;
        expected.push((record.clone(), prepared.total_sig.clone()));
        to_upload.push((prepared, std::fs::File::open(file)?, record.clone()));
    }

    let results = cloud_messages_client.upload_group_photo(to_upload).await?;

    match_upload_results_to_records(&expected, results)
}

#[cfg(test)]
mod upload_result_integrity_tests {
    use super::*;

    fn test_asset(record_name: Option<&str>, signature: Option<Vec<u8>>) -> Asset {
        Asset {
            signature,
            record_id: record_name.map(|name| rustpush::cloudkit_proto::RecordIdentifier {
                value: Some(rustpush::cloudkit_proto::Identifier {
                    name: Some(name.to_string()),
                    r#type: Some(rustpush::cloudkit_proto::identifier::Type::Record as i32),
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn expected_two() -> Vec<(String, Vec<u8>)> {
        vec![
            ("record-a".to_string(), b"sig-a".to_vec()),
            ("record-b".to_string(), b"sig-b".to_vec()),
        ]
    }

    #[test]
    fn duplicate_content_distinct_ids_bind_exactly() {
        let sig = b"sig-sentinel-duplicate-bytes".to_vec();
        let expected = vec![
            ("record-a".to_string(), sig.clone()),
            ("record-b".to_string(), sig.clone()),
        ];
        let results = vec![
            test_asset(Some("record-b"), Some(sig.clone())),
            test_asset(Some("record-a"), Some(sig.clone())),
        ];
        let bound = match_upload_results_to_records(&expected, results).unwrap();
        assert_eq!(bound.len(), 2);
        assert_eq!(bound["record-a"].signature.as_deref(), Some(&sig[..]));
        assert_eq!(bound["record-b"].signature.as_deref(), Some(&sig[..]));
    }

    #[test]
    fn reordered_results_still_bind() {
        let expected = expected_two();
        let results = vec![
            test_asset(Some("record-b"), Some(b"sig-b".to_vec())),
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
        ];
        let bound = match_upload_results_to_records(&expected, results).unwrap();
        assert_eq!(bound["record-a"].signature.as_deref(), Some(&b"sig-a"[..]));
        assert_eq!(bound["record-b"].signature.as_deref(), Some(&b"sig-b"[..]));
    }

    #[test]
    fn wrong_signature_rejected_without_content_leak() {
        let expected = expected_two();
        let results = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(Some("record-b"), Some(b"sig-sentinel-wrong".to_vec())),
        ];
        let err = match_upload_results_to_records(&expected, results).unwrap_err();
        let rendered = format!("{err:?}");
        assert!(rendered.contains("signature mismatch"));
        assert!(!rendered.contains("sig-sentinel-wrong"));
    }

    #[test]
    fn missing_signature_rejected() {
        let expected = expected_two();
        let results = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(Some("record-b"), None),
        ];
        let err = match_upload_results_to_records(&expected, results).unwrap_err();
        assert!(format!("{err:?}").contains("missing its signature"));
    }

    #[test]
    fn missing_record_id_rejected() {
        let expected = expected_two();
        let missing = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(None, Some(b"sig-b".to_vec())),
        ];
        let err = match_upload_results_to_records(&expected, missing).unwrap_err();
        assert!(format!("{err:?}").contains("missing its record identifier"));
        let empty_name = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(Some(""), Some(b"sig-b".to_vec())),
        ];
        let err = match_upload_results_to_records(&expected, empty_name).unwrap_err();
        assert!(format!("{err:?}").contains("missing its record identifier"));
    }

    #[test]
    fn unexpected_record_id_rejected() {
        let expected = expected_two();
        let results = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(Some("record-unknown"), Some(b"sig-b".to_vec())),
        ];
        let err = match_upload_results_to_records(&expected, results).unwrap_err();
        assert!(format!("{err:?}").contains("unexpected record"));
    }

    #[test]
    fn duplicate_results_rejected() {
        let expected = expected_two();
        let results = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
        ];
        let err = match_upload_results_to_records(&expected, results).unwrap_err();
        assert!(format!("{err:?}").contains("duplicate upload result"));
    }

    #[test]
    fn partial_reply_rejected() {
        let expected = expected_two();
        let results = vec![test_asset(Some("record-a"), Some(b"sig-a".to_vec()))];
        let err = match_upload_results_to_records(&expected, results).unwrap_err();
        assert!(format!("{err:?}").contains("count mismatch"));
    }

    #[test]
    fn extra_results_rejected() {
        let expected = expected_two();
        let results = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(Some("record-b"), Some(b"sig-b".to_vec())),
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
        ];
        let err = match_upload_results_to_records(&expected, results).unwrap_err();
        assert!(format!("{err:?}").contains("count mismatch"));
    }

    #[test]
    fn duplicate_request_ids_rejected() {
        let expected = vec![
            ("record-a".to_string(), b"sig-a".to_vec()),
            ("record-a".to_string(), b"sig-a".to_vec()),
        ];
        let results = vec![
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
            test_asset(Some("record-a"), Some(b"sig-a".to_vec())),
        ];
        let err = match_upload_results_to_records(&expected, results).unwrap_err();
        assert!(format!("{err:?}").contains("duplicate upload request"));
    }

    #[test]
    fn preflight_rejects_duplicate_request_ids_before_any_io() {
        let files = vec![
            ("a.bin".to_string(), "record-a".to_string()),
            ("b.bin".to_string(), "record-a".to_string()),
        ];
        let err = preflight_upload_request_records(&files).unwrap_err();
        assert!(format!("{err:?}").contains("duplicate upload request"));
    }

    #[test]
    fn preflight_rejects_empty_request_ids() {
        let files = vec![
            ("a.bin".to_string(), "record-a".to_string()),
            ("b.bin".to_string(), String::new()),
        ];
        let err = preflight_upload_request_records(&files).unwrap_err();
        assert!(format!("{err:?}").contains("missing"));
        let ok = vec![
            ("a.bin".to_string(), "record-a".to_string()),
            ("b.bin".to_string(), "record-b".to_string()),
        ];
        assert!(preflight_upload_request_records(&ok).is_ok());
    }

    #[test]
    fn preflight_accepts_empty_batch() {
        assert!(preflight_upload_request_records(&[]).is_ok());
    }

    #[test]
    fn empty_expected_signature_rejected() {
        let expected = vec![("record-a".to_string(), Vec::new())];
        let empty_result = vec![test_asset(Some("record-a"), Some(Vec::new()))];
        let err = match_upload_results_to_records(&expected, empty_result).unwrap_err();
        assert!(format!("{err:?}").contains("signature was missing"));
        let mismatched = vec![test_asset(Some("record-a"), Some(b"sig-a".to_vec()))];
        let err = match_upload_results_to_records(&expected, mismatched).unwrap_err();
        assert!(format!("{err:?}").contains("signature was missing"));
    }
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

fn two_factor_verification_authorizes_fresh_login(state: &LoginState) -> bool {
    matches!(state, LoginState::NeedsLogin | LoginState::LoggedIn)
}

fn two_factor_fresh_login_is_authenticated(state: &LoginState, has_pet: bool) -> bool {
    matches!(state, LoginState::LoggedIn) && has_pet
}

#[cfg(target_os = "windows")]
fn is_cloud_sync_windows_dev_profile(path: &str) -> bool {
    canonical_cloudkit_state_directory(&PathBuf::from(path))
        .ok()
        .and_then(|directory| {
            fs::read_to_string(directory.join(".openbubbles-cloud-sync-v2-windows-dev")).ok()
        })
        .is_some_and(|marker| marker == "openbubbles-cloud-sync-v2-windows-dev-profile:v1")
}

#[cfg(not(target_os = "windows"))]
fn is_cloud_sync_windows_dev_profile(_path: &str) -> bool {
    false
}

/// Initializes and migrates only a disposable Windows authentication probe.
///
/// This entry point deliberately does not initialize logging, ObjectBox,
/// CloudKit, Keychain, or any message service. The distinct probe marker keeps
/// it from mutating the ordinary isolated development profile.
#[frb(sync)]
pub fn prepare_cloud_sync_windows_auth_probe(path: String) -> anyhow::Result<()> {
    #[cfg(not(target_os = "windows"))]
    {
        let _ = path;
        return Err(anyhow!(
            "Cloud Sync Windows authentication probe requires Windows"
        ));
    }

    #[cfg(target_os = "windows")]
    {
        let requested_directory = cloud_sync_windows_auth_probe_lexical_path(
            PathBuf::from_str(&path)
                .map_err(|_| anyhow!("Cloud Sync Windows authentication probe path is invalid"))?,
            "Cloud Sync Windows authentication probe path is invalid",
        )?;
        let local_app_data = cloud_sync_windows_auth_probe_lexical_path(
            PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or_else(|| {
                anyhow!("Cloud Sync Windows authentication probe root is unavailable")
            })?),
            "Cloud Sync Windows authentication probe root is unavailable",
        )?;
        let process_app_data = cloud_sync_windows_auth_probe_lexical_path(
            PathBuf::from(std::env::var_os("APPDATA").ok_or_else(|| {
                anyhow!("Cloud Sync Windows authentication probe process root is unavailable")
            })?),
            "Cloud Sync Windows authentication probe process root is unavailable",
        )?;
        let probe_identifier = process_app_data
            .file_name()
            .and_then(|value| value.to_str())
            .filter(|value| is_cloud_sync_windows_auth_probe_identifier(value))
            .ok_or_else(|| anyhow!("Cloud Sync Windows authentication probe root is invalid"))?;
        let expected_probe_root = local_app_data
            .join("OpenBubbles")
            .join("CloudSyncV2AuthProbes");
        let expected_process_app_data = expected_probe_root.join(probe_identifier);
        if !cloud_sync_windows_auth_probe_paths_equal(&process_app_data, &expected_process_app_data)
        {
            return Err(anyhow!(
                "Cloud Sync Windows authentication probe process root is invalid"
            ));
        }
        let expected_requested_directory = expected_process_app_data
            .join("OpenBubbles")
            .join("cloudkit-v2-dev");
        if !cloud_sync_windows_auth_probe_paths_equal(
            &requested_directory,
            &expected_requested_directory,
        ) {
            return Err(anyhow!(
                "Cloud Sync Windows authentication probe profile is outside the process root"
            ));
        }
        for candidate in [
            local_app_data.as_path(),
            expected_probe_root.as_path(),
            process_app_data.as_path(),
            requested_directory.as_path(),
        ] {
            ensure_no_cloud_sync_windows_auth_probe_reparse_ancestors(candidate)?;
        }

        let probe_root = fs::canonicalize(&expected_probe_root)
            .map_err(|_| anyhow!("Cloud Sync Windows authentication probe root is unavailable"))?;
        let process_app_data = fs::canonicalize(&process_app_data).map_err(|_| {
            anyhow!("Cloud Sync Windows authentication probe process root is unavailable")
        })?;
        if process_app_data.parent() != Some(probe_root.as_path()) {
            return Err(anyhow!(
                "Cloud Sync Windows authentication probe escaped its dedicated root"
            ));
        }
        let canonical_directory = fs::canonicalize(&requested_directory).map_err(|_| {
            anyhow!("Cloud Sync Windows authentication probe directory is unavailable")
        })?;
        let expected_directory = fs::canonicalize(&expected_requested_directory).map_err(|_| {
            anyhow!("Cloud Sync Windows authentication probe profile is unavailable")
        })?;
        if canonical_directory != expected_directory {
            return Err(anyhow!(
                "Cloud Sync Windows authentication probe profile is outside the process root"
            ));
        }
        for candidate in [
            probe_root.as_path(),
            process_app_data.as_path(),
            canonical_directory.as_path(),
        ] {
            ensure_no_cloud_sync_windows_auth_probe_reparse_ancestors(candidate)?;
        }
        let marker =
            fs::read_to_string(canonical_directory.join(CLOUD_SYNC_WINDOWS_AUTH_PROBE_MARKER))
                .map_err(|_| {
                    anyhow!("Cloud Sync Windows authentication probe marker is unavailable")
                })?;
        if marker != CLOUD_SYNC_WINDOWS_AUTH_PROBE_MARKER_CONTENTS {
            return Err(anyhow!(
                "Cloud Sync Windows authentication probe marker is invalid"
            ));
        }
        for forbidden in [
            "cloudkit.plist",
            "keychain.plist",
            "objectbox",
            "cloud-sync-v2",
        ] {
            if canonical_directory.join(forbidden).exists() {
                return Err(anyhow!(
                    "Cloud Sync Windows authentication probe contains forbidden state"
                ));
            }
        }

        let legacy = plist::from_file::<_, Dictionary>(canonical_directory.join("gsa.plist"))
            .map_err(|_| {
                anyhow!("Cloud Sync Windows authentication probe GSA state is unreadable")
            })?;
        validate_cloud_sync_windows_auth_probe_legacy_gsa(&legacy)?;

        initialize_windows_protected_keystore(&canonical_directory)?;
        let _state_write_guard = cloudkit_state_file_write_guard()?;
        migrate_gsa_state_locked(&canonical_directory)?;

        let migrated = plist::from_file::<_, GSAConfig>(canonical_directory.join("gsa.plist"))
            .map_err(|_| anyhow!("Cloud Sync Windows authentication probe GSA migration failed"))?;
        if migrated.get_password()?.len() != 32 {
            return Err(anyhow!(
                "Cloud Sync Windows authentication probe password digest is malformed"
            ));
        }
        Ok(())
    }
}

#[cfg(target_os = "windows")]
async fn cloud_sync_windows_consume_login_admission(
    path: &str,
    account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
) -> anyhow::Result<()> {
    let canonical_directory = canonical_cloudkit_state_directory(&PathBuf::from(path))?;
    let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&canonical_directory)?;
    let _lifecycle_guard = lifecycle_gate.lock().await;
    let account_key = Arc::as_ptr(account) as usize;
    let expected_generation = cloudkit_login_validate_admission(&canonical_directory, account_key)?;
    cloudkit_login_consume_admission(&canonical_directory, expected_generation, account_key)
}

#[cfg(not(target_os = "windows"))]
async fn cloud_sync_windows_consume_login_admission(
    _path: &str,
    _account: &Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
) -> anyhow::Result<()> {
    Ok(())
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
    let verification_state = {
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
    let verification_state = {
        // The code shown by Apple's normal trusted-device prompt can be
        // verified directly without waiting on an unavailable BLE exchange.
        account.lock().await.verify_2fa(code).await?
    };

    if !two_factor_verification_authorizes_fresh_login(&verification_state) {
        return Err(anyhow!(
            "Trusted-device verification did not authorize a fresh login"
        ));
    }

    // Apple can populate the SPD token dictionary before reporting that 2FA
    // is still required. Those pre-verification tokens are not authenticated
    // CloudKit authority. Always perform a fresh SRP exchange after the code
    // is accepted and require an explicit logged-in response with a PET.
    let login_state = {
        let mut locked = account.lock().await;
        let username = locked
            .username
            .clone()
            .ok_or_else(|| anyhow!("Trusted-device verification account is unavailable"))?;
        let hashed_password = locked
            .hashed_password
            .clone()
            .ok_or_else(|| anyhow!("Trusted-device verification credential is unavailable"))?;
        locked.login_email_pass(&username, &hashed_password).await?
    };
    if !two_factor_fresh_login_is_authenticated(
        &login_state,
        account.lock().await.get_pet().is_some(),
    ) {
        return Err(anyhow!(
            "Trusted-device verification did not produce a post-verification login"
        ));
    }

    let mut user = None;
    if is_cloud_sync_windows_dev_profile(&path) {
        cloud_sync_windows_consume_login_admission(&path, account).await?;
    } else {
        let identity = do_login(path, &account, None, os_config).await?;
        user = Some(identity);
    }
    info!("Trusted-device verification completed a fresh authenticated login");

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
    let verification_state = account.verify_sms_2fa(code, body.clone()).await?;
    if !two_factor_verification_authorizes_fresh_login(&verification_state) {
        return Err(anyhow!("SMS verification did not authorize a fresh login"));
    }

    let username = account
        .username
        .clone()
        .ok_or_else(|| anyhow!("SMS verification account is unavailable"))?;
    let hashed_password = account
        .hashed_password
        .clone()
        .ok_or_else(|| anyhow!("SMS verification credential is unavailable"))?;
    let login_state = account
        .login_email_pass(&username, &hashed_password)
        .await?;
    if !two_factor_fresh_login_is_authenticated(&login_state, account.get_pet().is_some()) {
        return Err(anyhow!(
            "SMS verification did not produce a post-verification login"
        ));
    }

    let mut user = None;
    drop(account);
    if is_cloud_sync_windows_dev_profile(&path) {
        cloud_sync_windows_consume_login_admission(&path, account_mut).await?;
    } else {
        let identity = do_login(path, &account_mut, None, config).await?;
        user = Some(identity);
    }
    info!("SMS verification completed a fresh authenticated login");

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

fn remove_file_if_present(path: &std::path::Path) -> anyhow::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn reset_user(directory: &std::path::Path) -> anyhow::Result<()> {
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let _write_guard = cloudkit_state_file_write_guard()?;
    for file_name in [
        "gsa.plist",
        "findmy.plist",
        "facetime.plist",
        "cloudkit.plist",
        "keychain.plist",
        "passwords.plist",
        "sharedstreams.plist",
    ] {
        remove_file_if_present(&directory.join(file_name))?;
    }

    let statuskit_path = directory.join("statuskit.plist");
    let statuskit = plist_to_string(&StatusKitState {
        my_key: None,
        ..plist::from_file(&statuskit_path).unwrap_or_default()
    })?;
    persist_login_state_file(directory, "statuskit.plist", statuskit.as_bytes())?;
    Ok(())
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
    let requested_directory = PathBuf::from_str(&path).unwrap();
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let dir = canonical_cloudkit_state_directory(&requested_directory)?;
    #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
    let dir = requested_directory;

    // Keep logout serialized through the remote account logout and every local
    // state mutation. A new login cannot enter after local clearing but before
    // the old account's server session has been invalidated.
    #[cfg(any(target_os = "android", target_os = "windows"))]
    let _cloudkit_lifecycle_guard = if logout || reset_hw {
        let lifecycle_gate = cloudkit_read_authentication_lifecycle_gate(&dir)?;
        let lifecycle_guard = lifecycle_gate.lock_owned().await;
        if logout {
            revoke_clear_and_reset_cloudkit_state_locked(&dir).await?;
        } else {
            cloudkit_login_advance_generation(&dir)?;
            revoke_registered_cloudkit_read_authentication(&dir).await?;
            clear_cloudkit_read_authentication_cache(&dir)?;
        }
        Some(lifecycle_guard)
    } else {
        None
    };

    info!("c");
    if logout {
        #[cfg(all(not(target_os = "android"), not(target_os = "windows")))]
        reset_user(&dir)?;
        if let Some(hardware) = read_hardware(dir.to_string_lossy().into_owned()) {
            // try deregistering from iMessage, but if it fails we don't really care
            if let Ok(identity) = IDSNGMIdentity::restore(hardware.identity.as_ref(), "openbubbles")
            {
                if let Err(error) = register(
                    &*config.config(),
                    &*aps.state.read().await,
                    &[],
                    &mut [],
                    &identity,
                )
                .await
                {
                    warn!("Best-effort iMessage deregistration failed: {error}");
                }
            }
        }
        if let Some(account) = &account {
            if let Err(error) = account.lock().await.logout_all("Apple Device").await {
                warn!("Best-effort remote Apple Account logout failed: {error}");
            }
        }
    }
    remove_file_if_present(&dir.join("id.plist"))?;
    let id_cache_path = dir.join("id_cache.plist");
    if id_cache_path.exists() {
        let mut cache = plist::from_file::<_, Dictionary>(&id_cache_path)?;
        // keep replay counters which are nessesary if our identity doesn't change
        cache
            .get_mut("cache")
            .ok_or_else(|| anyhow!("Identity cache dictionary was missing"))?
            .as_dictionary_mut()
            .ok_or_else(|| anyhow!("Identity cache entry was not a dictionary"))?
            .clear();
        let mut encoded = Vec::new();
        plist::to_writer_xml(&mut encoded, &cache)?;
        persist_login_state_file(&dir, "id_cache.plist", &encoded)?;
    }

    if reset_hw {
        #[cfg(any(target_os = "android", target_os = "windows"))]
        let _state_write_guard = cloudkit_state_file_write_guard()?;
        remove_file_if_present(&dir.join("hw_info.plist"))?;
        remove_file_if_present(&dir.join("id_cache.plist"))?; // our identity is wiped so we can wipe our counters too
        remove_file_if_present(&dir.join("statuskit.plist"))?;
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
