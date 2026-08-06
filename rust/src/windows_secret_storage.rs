//! Windows-only protected storage primitives for Cloud Sync V2.
//!
//! Production callers use [`open_windows_keystore`], which acquires a
//! profile-wide lifetime lock before it inspects, creates, or migrates state.
//! Lower-level migration helpers remain path-free for deterministic tests.

use std::{
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::windows::{ffi::OsStrExt, fs::OpenOptionsExt, io::AsRawHandle},
    path::{Path, PathBuf},
    ptr,
    sync::Arc,
    thread,
    time::Duration,
};

use keystore::{
    software::{SoftwareEncryptor, SoftwareKeystoreState},
    KeystoreError,
};
use plist::Data;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use windows_sys::Win32::{
    Foundation::{LocalFree, HANDLE},
    Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    },
    Storage::FileSystem::{FlushFileBuffers, ReplaceFileW},
};

pub const WINDOWS_KEYSTORE_FORMAT_VERSION: u32 = 2;
pub const CLOUD_SYNC_INSTALL_SECRET_FORMAT_VERSION: u32 = 1;
const MASTER_KEY_LENGTH: usize = 32;
const LEGACY_WINDOWS_KEY: [u8; MASTER_KEY_LENGTH] = *b"desktopisinsecureyoushouldn'tber";
const MAX_ENVELOPE_BYTES: u64 = 64 * 1024 * 1024;
const SECRET_OPEN_RETRY_ATTEMPTS: usize = 100;
const SECRET_OPEN_RETRY_DELAY: Duration = Duration::from_millis(10);

#[derive(Debug, Error)]
pub enum WindowsSecretStorageError {
    #[error("Windows secret-storage I/O failed")]
    Io(#[from] io::Error),

    #[error("Windows DPAPI {operation} failed")]
    Dpapi {
        operation: &'static str,
        #[source]
        source: io::Error,
    },

    #[error("Windows DPAPI returned an invalid result")]
    InvalidDpapiResult,

    #[error("Protected master key has an invalid length")]
    InvalidMasterKeyLength,

    #[error("Protected keystore envelope is invalid")]
    InvalidEnvelope,

    #[error("Unsupported protected keystore format version {0}")]
    UnsupportedFormatVersion(u32),

    #[error("Protected keystore envelope exceeds the size limit")]
    EnvelopeTooLarge,

    #[error("Software keystore validation failed")]
    Keystore(#[from] KeystoreError),

    #[error("Atomic replacement target does not exist")]
    MissingReplacementTarget,

    #[error("Atomic replacement backup already exists")]
    BackupAlreadyExists,

    #[error("Atomic replacement paths must share one directory")]
    PathsMustShareDirectory,

    #[error("Atomic replacement verification failed")]
    ReplacementVerificationFailed,

    #[error("Cloud Sync installation secret initialization did not settle")]
    SecretInitializationRace,

    #[error("Windows keystore profile is already open")]
    ProfileLocked,

    #[error("Windows keystore recovery backup requires explicit recovery")]
    RecoveryBackupPresent,
}

/// Versioned, architecture-neutral representation of the Windows software
/// keystore. The master key is protected with current-user DPAPI. Individual
/// keystore entries remain authenticated with the keystore crate's AES-GCM
/// `SoftwareEncryptor`.
#[derive(Serialize, Deserialize)]
pub struct WindowsProtectedKeystoreEnvelope {
    format_version: u32,
    protected_master_key: Data,
    state: SoftwareKeystoreState,
}

/// Unlocked state plus the profile-wide lock and protected persistence writer.
///
/// Keep [writer] alive for the lifetime of the process keystore. Its exclusive
/// lock prevents another OpenBubbles process or architecture from opening and
/// migrating the same profile concurrently.
pub struct WindowsOpenedKeystore {
    pub state: SoftwareKeystoreState,
    pub encryptor: SoftwareEncryptor,
    pub writer: WindowsProtectedKeystoreWriter,
}

pub struct WindowsProtectedKeystoreWriter {
    target: PathBuf,
    protected_master_key: Vec<u8>,
    _profile_lock: Arc<WindowsProfileLock>,
}

struct WindowsProfileLock {
    _file: File,
}

/// Small current-user protected secret used for account-fingerprint HMACs and
/// Cloud Sync local journal key derivation.
///
/// The format contains no architecture-sized values, so x64 and ARM64 builds
/// share the same file contract for one Windows user profile.
#[derive(Serialize, Deserialize)]
struct CloudSyncInstallSecretEnvelope {
    format_version: u32,
    protected_secret: Data,
}

impl WindowsProtectedKeystoreEnvelope {
    pub fn format_version(&self) -> u32 {
        self.format_version
    }

    /// Authenticates the DPAPI master and every encrypted software-keystore
    /// entry without exposing their contents.
    pub fn validate(&self) -> Result<(), WindowsSecretStorageError> {
        let encryptor = self.unlock_encryptor()?;
        self.state.validate(&encryptor)?;
        Ok(())
    }

    /// Consumes a validated envelope for integration with `SoftwareKeystore`.
    pub fn into_unlocked(
        self,
    ) -> Result<(SoftwareKeystoreState, SoftwareEncryptor), WindowsSecretStorageError> {
        let encryptor = self.unlock_encryptor()?;
        self.state.validate(&encryptor)?;
        Ok((self.state, encryptor))
    }

    fn unlock_encryptor(&self) -> Result<SoftwareEncryptor, WindowsSecretStorageError> {
        if self.format_version != WINDOWS_KEYSTORE_FORMAT_VERSION {
            return Err(WindowsSecretStorageError::UnsupportedFormatVersion(
                self.format_version,
            ));
        }

        let master = unprotect_current_user(self.protected_master_key.as_ref())?;
        let master: [u8; MASTER_KEY_LENGTH] = master
            .try_into()
            .map_err(|_| WindowsSecretStorageError::InvalidMasterKeyLength)?;
        Ok(SoftwareEncryptor(master))
    }
}

/// Re-wraps a strictly decoded legacy state with a fresh random master and
/// protects that master for the current Windows user.
///
/// This helper is intentionally state-to-state. It never discovers, reads,
/// replaces, or deletes a live profile.
pub fn migrate_legacy_state(
    legacy_state: &SoftwareKeystoreState,
    legacy_key: [u8; MASTER_KEY_LENGTH],
) -> Result<WindowsProtectedKeystoreEnvelope, WindowsSecretStorageError> {
    let legacy_encryptor = SoftwareEncryptor(legacy_key);
    let new_encryptor = SoftwareEncryptor::new();
    let state = legacy_state.rewrap(&legacy_encryptor, &new_encryptor)?;
    state.validate(&new_encryptor)?;

    let protected_master_key = protect_current_user(&new_encryptor.0)?;
    let envelope = WindowsProtectedKeystoreEnvelope {
        format_version: WINDOWS_KEYSTORE_FORMAT_VERSION,
        protected_master_key: protected_master_key.into(),
        state,
    };
    envelope.validate()?;
    Ok(envelope)
}

pub fn encode_envelope(
    envelope: &WindowsProtectedKeystoreEnvelope,
) -> Result<Vec<u8>, WindowsSecretStorageError> {
    envelope.validate()?;
    let mut encoded = Vec::new();
    plist::to_writer_binary(&mut encoded, envelope)
        .map_err(|_| WindowsSecretStorageError::InvalidEnvelope)?;
    if encoded.is_empty() || encoded.len() as u64 > MAX_ENVELOPE_BYTES {
        return Err(WindowsSecretStorageError::EnvelopeTooLarge);
    }
    Ok(encoded)
}

pub fn decode_envelope(
    encoded: &[u8],
) -> Result<WindowsProtectedKeystoreEnvelope, WindowsSecretStorageError> {
    if encoded.is_empty() || encoded.len() as u64 > MAX_ENVELOPE_BYTES {
        return Err(WindowsSecretStorageError::InvalidEnvelope);
    }
    let envelope: WindowsProtectedKeystoreEnvelope =
        plist::from_bytes(encoded).map_err(|_| WindowsSecretStorageError::InvalidEnvelope)?;
    envelope.validate()?;
    Ok(envelope)
}

pub fn read_envelope(
    path: &Path,
) -> Result<WindowsProtectedKeystoreEnvelope, WindowsSecretStorageError> {
    decode_envelope(&read_bounded(path)?)
}

/// Opens a protected profile, creates a protected new profile, or migrates one
/// strictly validated legacy profile while holding an exclusive lifetime lock.
pub fn open_windows_keystore(
    target: &Path,
) -> Result<WindowsOpenedKeystore, WindowsSecretStorageError> {
    let parent = target
        .parent()
        .ok_or(WindowsSecretStorageError::PathsMustShareDirectory)?;
    fs::create_dir_all(parent)?;
    let profile_lock = Arc::new(acquire_profile_lock(
        &parent.join(".openbubbles-keystore.lock"),
    )?);
    let backup = parent.join(format!(
        "{}.dpapi-v2-legacy-backup",
        target
            .file_name()
            .ok_or(WindowsSecretStorageError::InvalidEnvelope)?
            .to_string_lossy()
    ));

    if !target.exists() {
        if backup.exists() {
            return Err(WindowsSecretStorageError::RecoveryBackupPresent);
        }
        let state = SoftwareKeystoreState::default();
        let encryptor = SoftwareEncryptor::new();
        let protected_master_key = protect_current_user(&encryptor.0)?;
        let envelope = WindowsProtectedKeystoreEnvelope {
            format_version: WINDOWS_KEYSTORE_FORMAT_VERSION,
            protected_master_key: protected_master_key.clone().into(),
            state,
        };
        create_new_envelope(target, &envelope)?;
    } else {
        let encoded = read_bounded(target)?;
        match decode_envelope(&encoded) {
            Ok(_) => {}
            Err(protected_error) => {
                if looks_like_protected_envelope(&encoded) {
                    return Err(protected_error);
                }
                let legacy_state = decode_legacy_state_strict(&encoded, LEGACY_WINDOWS_KEY)?;
                let envelope = migrate_legacy_state(&legacy_state, LEGACY_WINDOWS_KEY)?;
                replace_existing_envelope_atomic(target, &backup, &envelope)?;
            }
        }
    }

    let envelope = read_envelope(target)?;
    let protected_master_key = envelope.protected_master_key.as_ref().to_vec();
    let (state, encryptor) = envelope.into_unlocked()?;
    Ok(WindowsOpenedKeystore {
        state,
        encryptor,
        writer: WindowsProtectedKeystoreWriter {
            target: target.to_path_buf(),
            protected_master_key,
            _profile_lock: profile_lock,
        },
    })
}

impl WindowsProtectedKeystoreWriter {
    /// Persists a complete state through a flushed same-directory replacement.
    /// The lifetime profile lock is still held by this writer.
    pub fn write_state(
        &self,
        state: &SoftwareKeystoreState,
    ) -> Result<(), WindowsSecretStorageError> {
        let envelope = WindowsProtectedKeystoreEnvelope {
            format_version: WINDOWS_KEYSTORE_FORMAT_VERSION,
            protected_master_key: self.protected_master_key.clone().into(),
            state: strict_clone_state(state)?,
        };
        let encoded = encode_envelope(&envelope)?;
        replace_existing_bytes_atomic(&self.target, &encoded)?;
        read_envelope(&self.target)?.validate()
    }
}

fn acquire_profile_lock(path: &Path) -> Result<WindowsProfileLock, WindowsSecretStorageError> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).share_mode(0);
    match options.open(path) {
        Ok(file) => Ok(WindowsProfileLock { _file: file }),
        Err(error) if is_transient_share_error(&error) => {
            Err(WindowsSecretStorageError::ProfileLocked)
        }
        Err(error) => Err(WindowsSecretStorageError::Io(error)),
    }
}

fn create_new_envelope(
    target: &Path,
    envelope: &WindowsProtectedKeystoreEnvelope,
) -> Result<(), WindowsSecretStorageError> {
    let encoded = encode_envelope(envelope)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .share_mode(0)
        .open(target)?;
    file.write_all(&encoded)?;
    file.flush()?;
    flush_file_buffers(&file)?;
    drop(file);
    let installed = read_bounded(target)?;
    decode_envelope(&installed)?;
    Ok(())
}

fn looks_like_protected_envelope(encoded: &[u8]) -> bool {
    let Ok(plist::Value::Dictionary(dictionary)) = plist::from_bytes(encoded) else {
        return false;
    };
    dictionary.contains_key("format_version")
        || dictionary.contains_key("protected_master_key")
        || dictionary.contains_key("state")
}

fn decode_legacy_state_strict(
    encoded: &[u8],
    legacy_key: [u8; MASTER_KEY_LENGTH],
) -> Result<SoftwareKeystoreState, WindowsSecretStorageError> {
    let value: plist::Value =
        plist::from_bytes(encoded).map_err(|_| WindowsSecretStorageError::InvalidEnvelope)?;
    let plist::Value::Dictionary(dictionary) = value else {
        return Err(WindowsSecretStorageError::InvalidEnvelope);
    };
    if dictionary.len() != 2
        || !matches!(dictionary.get("keys"), Some(plist::Value::Dictionary(_)))
        || !matches!(dictionary.get("secrets"), Some(plist::Value::Dictionary(_)))
    {
        return Err(WindowsSecretStorageError::InvalidEnvelope);
    }
    let state: SoftwareKeystoreState =
        plist::from_bytes(encoded).map_err(|_| WindowsSecretStorageError::InvalidEnvelope)?;
    state.validate(&SoftwareEncryptor(legacy_key))?;
    Ok(state)
}

fn strict_clone_state(
    state: &SoftwareKeystoreState,
) -> Result<SoftwareKeystoreState, WindowsSecretStorageError> {
    let mut encoded = Vec::new();
    plist::to_writer_binary(&mut encoded, state)
        .map_err(|_| WindowsSecretStorageError::InvalidEnvelope)?;
    plist::from_bytes(&encoded).map_err(|_| WindowsSecretStorageError::InvalidEnvelope)
}

fn replace_existing_bytes_atomic(
    target: &Path,
    encoded: &[u8],
) -> Result<(), WindowsSecretStorageError> {
    let parent = target
        .parent()
        .ok_or(WindowsSecretStorageError::PathsMustShareDirectory)?;
    if !target.is_file() {
        return Err(WindowsSecretStorageError::MissingReplacementTarget);
    }
    let target_name = target
        .file_name()
        .ok_or(WindowsSecretStorageError::InvalidEnvelope)?;
    let mut temp_name = OsStr::new(".").to_os_string();
    temp_name.push(target_name);
    temp_name.push(format!(".{}.dpapi-v2.tmp", uuid::Uuid::new_v4()));
    let temp = parent.join(temp_name);

    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .share_mode(0)
            .open(&temp)?;
        file.write_all(encoded)?;
        file.flush()?;
        flush_file_buffers(&file)?;
        drop(file);
        replace_file_without_backup(target, &temp)?;
        let installed = read_bounded(target)?;
        if installed != encoded {
            return Err(WindowsSecretStorageError::ReplacementVerificationFailed);
        }
        Ok(())
    })();
    if temp.exists() {
        let _ = fs::remove_file(&temp);
    }
    result
}

/// Opens the existing 32-byte per-install Cloud Sync secret, or creates it once.
///
/// `create_new` on the final path is the race arbiter. The winning writer holds
/// the file without sharing until the bytes are flushed with
/// `FlushFileBuffers`. Losing callers retry the strict reader and return the
/// exact same key. Existing corrupt or truncated files are never regenerated.
pub fn load_or_create_cloud_sync_install_secret(
    path: &Path,
) -> Result<[u8; MASTER_KEY_LENGTH], WindowsSecretStorageError> {
    match read_cloud_sync_install_secret(path) {
        Ok(secret) => return Ok(secret),
        Err(WindowsSecretStorageError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {}
        Err(WindowsSecretStorageError::Io(error)) if is_transient_share_error(&error) => {
            return read_cloud_sync_install_secret_after_race(path);
        }
        Err(error) => return Err(error),
    }

    let secret: [u8; MASTER_KEY_LENGTH] = rand::random();
    let encoded = encode_cloud_sync_install_secret(&secret)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true).share_mode(0);
    match options.open(path) {
        Ok(mut file) => {
            let write_result = (|| {
                file.write_all(&encoded)?;
                file.flush()?;
                flush_file_buffers(&file)?;
                Ok::<(), WindowsSecretStorageError>(())
            })();
            drop(file);
            write_result?;

            let installed = read_cloud_sync_install_secret(path)?;
            if installed != secret {
                return Err(WindowsSecretStorageError::ReplacementVerificationFailed);
            }
            Ok(installed)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            read_cloud_sync_install_secret_after_race(path)
        }
        Err(error) => Err(WindowsSecretStorageError::Io(error)),
    }
}

/// Strictly reads an existing Cloud Sync installation secret. Invalid
/// versions, DPAPI failures, truncation, and wrong plaintext lengths all fail
/// closed.
pub fn read_cloud_sync_install_secret(
    path: &Path,
) -> Result<[u8; MASTER_KEY_LENGTH], WindowsSecretStorageError> {
    let encoded = read_bounded(path)?;
    let envelope: CloudSyncInstallSecretEnvelope =
        plist::from_bytes(&encoded).map_err(|_| WindowsSecretStorageError::InvalidEnvelope)?;
    if envelope.format_version != CLOUD_SYNC_INSTALL_SECRET_FORMAT_VERSION {
        return Err(WindowsSecretStorageError::UnsupportedFormatVersion(
            envelope.format_version,
        ));
    }
    let secret = unprotect_current_user(envelope.protected_secret.as_ref())?;
    secret
        .try_into()
        .map_err(|_| WindowsSecretStorageError::InvalidMasterKeyLength)
}

/// Replaces an existing file using a flushed, same-directory temporary file
/// and `ReplaceFileW` with flags set to zero.
///
/// The caller supplies a non-existing backup path in the same directory. The
/// old target remains there after success. A post-replacement failure returns
/// an error and leaves that backup intact for explicit recovery.
pub fn replace_existing_envelope_atomic(
    target: &Path,
    backup: &Path,
    envelope: &WindowsProtectedKeystoreEnvelope,
) -> Result<(), WindowsSecretStorageError> {
    let target_parent = target
        .parent()
        .ok_or(WindowsSecretStorageError::PathsMustShareDirectory)?;
    if backup.parent() != Some(target_parent) {
        return Err(WindowsSecretStorageError::PathsMustShareDirectory);
    }
    if !target.is_file() {
        return Err(WindowsSecretStorageError::MissingReplacementTarget);
    }
    if backup.exists() {
        return Err(WindowsSecretStorageError::BackupAlreadyExists);
    }

    let encoded = encode_envelope(envelope)?;
    let target_name = target
        .file_name()
        .ok_or(WindowsSecretStorageError::InvalidEnvelope)?;
    let mut temp_name = OsStr::new(".").to_os_string();
    temp_name.push(target_name);
    temp_name.push(format!(".{}.cloudsync-v2.tmp", uuid::Uuid::new_v4()));
    let temp = target_parent.join(temp_name);

    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(&encoded)?;
        file.flush()?;
        flush_file_buffers(&file)?;
        drop(file);

        replace_file(target, &temp, backup)?;

        let installed = read_bounded(target)?;
        if installed != encoded {
            return Err(WindowsSecretStorageError::ReplacementVerificationFailed);
        }
        decode_envelope(&installed)?;
        Ok(())
    })();

    if temp.exists() {
        let _ = fs::remove_file(&temp);
    }
    result
}

pub fn protect_current_user(plaintext: &[u8]) -> Result<Vec<u8>, WindowsSecretStorageError> {
    if plaintext.is_empty() {
        return Err(WindowsSecretStorageError::InvalidMasterKeyLength);
    }
    let input = input_blob(plaintext)?;
    let mut output = empty_blob();
    let succeeded = unsafe {
        CryptProtectData(
            &input,
            ptr::null(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if succeeded == 0 {
        return Err(WindowsSecretStorageError::Dpapi {
            operation: "protect",
            source: io::Error::last_os_error(),
        });
    }
    copy_and_free_blob(output)
}

pub fn unprotect_current_user(protected: &[u8]) -> Result<Vec<u8>, WindowsSecretStorageError> {
    if protected.is_empty() {
        return Err(WindowsSecretStorageError::InvalidDpapiResult);
    }
    let input = input_blob(protected)?;
    let mut output = empty_blob();
    let succeeded = unsafe {
        CryptUnprotectData(
            &input,
            ptr::null_mut(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if succeeded == 0 {
        return Err(WindowsSecretStorageError::Dpapi {
            operation: "unprotect",
            source: io::Error::last_os_error(),
        });
    }
    copy_and_free_blob(output)
}

fn input_blob(data: &[u8]) -> Result<CRYPT_INTEGER_BLOB, WindowsSecretStorageError> {
    let len = u32::try_from(data.len()).map_err(|_| WindowsSecretStorageError::EnvelopeTooLarge)?;
    Ok(CRYPT_INTEGER_BLOB {
        cbData: len,
        pbData: data.as_ptr().cast_mut(),
    })
}

fn empty_blob() -> CRYPT_INTEGER_BLOB {
    CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: ptr::null_mut(),
    }
}

fn copy_and_free_blob(blob: CRYPT_INTEGER_BLOB) -> Result<Vec<u8>, WindowsSecretStorageError> {
    if blob.cbData == 0 || blob.pbData.is_null() {
        if !blob.pbData.is_null() {
            unsafe {
                LocalFree(blob.pbData.cast());
            }
        }
        return Err(WindowsSecretStorageError::InvalidDpapiResult);
    }

    let bytes = unsafe {
        std::slice::from_raw_parts(blob.pbData.cast_const(), blob.cbData as usize).to_vec()
    };
    let allocation = blob.pbData.cast();
    let not_freed = unsafe { LocalFree(allocation) };
    if !not_freed.is_null() {
        return Err(WindowsSecretStorageError::InvalidDpapiResult);
    }
    Ok(bytes)
}

fn read_bounded(path: &Path) -> Result<Vec<u8>, WindowsSecretStorageError> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    if metadata.len() == 0 {
        return Err(WindowsSecretStorageError::InvalidEnvelope);
    }
    if metadata.len() > MAX_ENVELOPE_BYTES {
        return Err(WindowsSecretStorageError::EnvelopeTooLarge);
    }

    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_ENVELOPE_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_ENVELOPE_BYTES {
        return Err(WindowsSecretStorageError::EnvelopeTooLarge);
    }
    Ok(bytes)
}

fn flush_file_buffers(file: &File) -> Result<(), WindowsSecretStorageError> {
    let handle = file.as_raw_handle() as HANDLE;
    let succeeded = unsafe { FlushFileBuffers(handle) };
    if succeeded == 0 {
        return Err(WindowsSecretStorageError::Io(io::Error::last_os_error()));
    }
    Ok(())
}

fn replace_file(
    target: &Path,
    replacement: &Path,
    backup: &Path,
) -> Result<(), WindowsSecretStorageError> {
    let target = wide_null(target);
    let replacement = wide_null(replacement);
    let backup = wide_null(backup);
    let succeeded = unsafe {
        ReplaceFileW(
            target.as_ptr(),
            replacement.as_ptr(),
            backup.as_ptr(),
            0,
            ptr::null(),
            ptr::null(),
        )
    };
    if succeeded == 0 {
        return Err(WindowsSecretStorageError::Io(io::Error::last_os_error()));
    }
    Ok(())
}

fn replace_file_without_backup(
    target: &Path,
    replacement: &Path,
) -> Result<(), WindowsSecretStorageError> {
    let target = wide_null(target);
    let replacement = wide_null(replacement);
    let succeeded = unsafe {
        ReplaceFileW(
            target.as_ptr(),
            replacement.as_ptr(),
            ptr::null(),
            0,
            ptr::null(),
            ptr::null(),
        )
    };
    if succeeded == 0 {
        return Err(WindowsSecretStorageError::Io(io::Error::last_os_error()));
    }
    Ok(())
}

fn wide_null(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

fn encode_cloud_sync_install_secret(
    secret: &[u8; MASTER_KEY_LENGTH],
) -> Result<Vec<u8>, WindowsSecretStorageError> {
    let envelope = CloudSyncInstallSecretEnvelope {
        format_version: CLOUD_SYNC_INSTALL_SECRET_FORMAT_VERSION,
        protected_secret: protect_current_user(secret)?.into(),
    };
    let mut encoded = Vec::new();
    plist::to_writer_binary(&mut encoded, &envelope)
        .map_err(|_| WindowsSecretStorageError::InvalidEnvelope)?;
    if encoded.is_empty() || encoded.len() as u64 > MAX_ENVELOPE_BYTES {
        return Err(WindowsSecretStorageError::EnvelopeTooLarge);
    }
    Ok(encoded)
}

fn read_cloud_sync_install_secret_after_race(
    path: &Path,
) -> Result<[u8; MASTER_KEY_LENGTH], WindowsSecretStorageError> {
    for _ in 0..SECRET_OPEN_RETRY_ATTEMPTS {
        match read_cloud_sync_install_secret(path) {
            Ok(secret) => return Ok(secret),
            Err(WindowsSecretStorageError::Io(error))
                if error.kind() == io::ErrorKind::NotFound || is_transient_share_error(&error) =>
            {
                thread::sleep(SECRET_OPEN_RETRY_DELAY);
            }
            Err(error) => return Err(error),
        }
    }
    Err(WindowsSecretStorageError::SecretInitializationRace)
}

fn is_transient_share_error(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::PermissionDenied || error.raw_os_error() == Some(32)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Barrier, RwLock};

    use keystore::{
        software::{SoftwareEncryptor, SoftwareKeystore, SoftwareKeystoreState},
        KeyType, Keystore, KeystoreAccessRules,
    };

    use super::*;

    const LEGACY_KEY: [u8; 32] = *b"desktopisinsecureyoushouldn'tber";

    fn legacy_state() -> SoftwareKeystoreState {
        let store = SoftwareKeystore {
            state: RwLock::new(SoftwareKeystoreState::default()),
            update_state: Box::new(|_| {}),
            encryptor: SoftwareEncryptor(LEGACY_KEY),
        };
        store
            .set_secret("test:secret", b"not written to diagnostics")
            .expect("legacy test secret should be stored");
        store
            .create_key(
                "test:key",
                KeyType::Aes(256),
                KeystoreAccessRules::default(),
            )
            .expect("legacy test key should be stored");

        let SoftwareKeystore { state, .. } = store;
        state
            .into_inner()
            .expect("test lock should not be poisoned")
    }

    fn write_legacy(path: &Path, state: &SoftwareKeystoreState) {
        let mut encoded = Vec::new();
        plist::to_writer_xml(&mut encoded, state).expect("legacy fixture should encode");
        fs::write(path, encoded).expect("legacy fixture should be written");
    }

    #[test]
    fn dpapi_current_user_round_trip() {
        let plaintext = b"cloud-sync-v2-current-user-test";
        let protected = protect_current_user(plaintext).expect("DPAPI protection should succeed");
        assert_ne!(protected, plaintext);
        let recovered =
            unprotect_current_user(&protected).expect("DPAPI unprotection should succeed");
        assert_eq!(recovered, plaintext);
    }

    #[test]
    fn dpapi_rejects_tampered_and_truncated_blobs() {
        let mut protected =
            protect_current_user(b"authenticated test value").expect("DPAPI should protect");
        let midpoint = protected.len() / 2;
        protected[midpoint] ^= 0x80;
        assert!(unprotect_current_user(&protected).is_err());

        let protected =
            protect_current_user(b"second authenticated value").expect("DPAPI should protect");
        assert!(unprotect_current_user(&protected[..protected.len() / 2]).is_err());
    }

    #[test]
    fn synthetic_migration_rewraps_keys_and_secrets() {
        let envelope =
            migrate_legacy_state(&legacy_state(), LEGACY_KEY).expect("migration should succeed");
        assert_eq!(envelope.format_version(), WINDOWS_KEYSTORE_FORMAT_VERSION);

        let (state, encryptor) = envelope
            .into_unlocked()
            .expect("migrated envelope should unlock");
        let store = SoftwareKeystore {
            state: RwLock::new(state),
            update_state: Box::new(|_| {}),
            encryptor,
        };
        assert_eq!(
            store
                .get_secret("test:secret")
                .expect("secret lookup should succeed")
                .expect("secret should exist"),
            b"not written to diagnostics"
        );
        assert!(matches!(
            store
                .get_key_type("test:key")
                .expect("key lookup should succeed"),
            Some(KeyType::Aes(256))
        ));
    }

    #[test]
    fn envelope_rejects_tampering_and_truncation() {
        let envelope =
            migrate_legacy_state(&legacy_state(), LEGACY_KEY).expect("migration should succeed");
        let encoded = encode_envelope(&envelope).expect("encoding should succeed");
        assert!(decode_envelope(&encoded[..encoded.len() / 2]).is_err());

        let mut decoded: WindowsProtectedKeystoreEnvelope =
            plist::from_bytes(&encoded).expect("test envelope should decode");
        let mut protected = decoded.protected_master_key.as_ref().to_vec();
        let midpoint = protected.len() / 2;
        protected[midpoint] ^= 0x40;
        decoded.protected_master_key = protected.into();
        assert!(decoded.validate().is_err());
    }

    #[test]
    fn atomic_replace_flushes_backs_up_and_reopens() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");
        let backup = directory.path().join("keystore.plist.legacy-backup");
        let old_bytes = b"synthetic legacy file";
        fs::write(&target, old_bytes).expect("legacy fixture should be written");

        let envelope =
            migrate_legacy_state(&legacy_state(), LEGACY_KEY).expect("migration should succeed");
        replace_existing_envelope_atomic(&target, &backup, &envelope)
            .expect("atomic replacement should succeed");

        read_envelope(&target)
            .expect("installed envelope should reopen")
            .validate()
            .expect("installed envelope should validate");
        assert_eq!(
            fs::read(&backup).expect("backup should be readable"),
            old_bytes
        );
    }

    #[test]
    fn atomic_replace_requires_existing_target_and_fresh_backup() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");
        let backup = directory.path().join("keystore.plist.backup");
        let envelope =
            migrate_legacy_state(&legacy_state(), LEGACY_KEY).expect("migration should succeed");

        assert!(matches!(
            replace_existing_envelope_atomic(&target, &backup, &envelope),
            Err(WindowsSecretStorageError::MissingReplacementTarget)
        ));

        fs::write(&target, b"old").expect("target fixture should be written");
        fs::write(&backup, b"preserve").expect("backup fixture should be written");
        assert!(matches!(
            replace_existing_envelope_atomic(&target, &backup, &envelope),
            Err(WindowsSecretStorageError::BackupAlreadyExists)
        ));
        assert_eq!(
            fs::read(&backup).expect("backup should remain readable"),
            b"preserve"
        );
    }

    #[test]
    fn new_profile_starts_protected_and_reopens_idempotently() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");

        let opened = open_windows_keystore(&target).expect("new profile should open");
        assert!(target.is_file());
        read_envelope(&target).expect("new profile must be protected");
        assert!(matches!(
            open_windows_keystore(&target),
            Err(WindowsSecretStorageError::ProfileLocked)
        ));
        drop(opened);

        let reopened = open_windows_keystore(&target).expect("protected profile should reopen");
        read_envelope(&target)
            .expect("reopened profile should remain protected")
            .validate()
            .expect("reopened profile should validate");
        drop(reopened);
    }

    #[test]
    fn legacy_profile_migrates_once_and_preserves_recovery_backup() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");
        let backup = directory
            .path()
            .join("keystore.plist.dpapi-v2-legacy-backup");
        let legacy = legacy_state();
        write_legacy(&target, &legacy);
        let original = fs::read(&target).expect("legacy fixture should read");

        let opened = open_windows_keystore(&target).expect("legacy profile should migrate");
        assert_eq!(
            fs::read(&backup).expect("recovery backup should remain"),
            original
        );
        let store = SoftwareKeystore {
            state: RwLock::new(opened.state),
            update_state: Box::new(|_| {}),
            encryptor: opened.encryptor,
        };
        assert_eq!(
            store
                .get_secret("test:secret")
                .expect("secret read should succeed")
                .expect("secret should survive migration"),
            b"not written to diagnostics"
        );
        drop(store);
        drop(opened.writer);

        let reopened = open_windows_keystore(&target).expect("repeat open should be idempotent");
        assert_eq!(
            fs::read(&backup).expect("original backup should remain unchanged"),
            original
        );
        drop(reopened);
    }

    #[test]
    fn corrupt_truncated_and_recovery_only_profiles_fail_closed() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");
        fs::write(&target, b"not a plist").expect("corrupt fixture should write");
        assert!(matches!(
            open_windows_keystore(&target),
            Err(WindowsSecretStorageError::InvalidEnvelope)
        ));
        assert_eq!(
            fs::read(&target).expect("corrupt target must remain"),
            b"not a plist"
        );

        fs::remove_file(&target).expect("corrupt fixture should remove");
        let backup = directory
            .path()
            .join("keystore.plist.dpapi-v2-legacy-backup");
        fs::write(&backup, b"recovery").expect("recovery fixture should write");
        assert!(matches!(
            open_windows_keystore(&target),
            Err(WindowsSecretStorageError::RecoveryBackupPresent)
        ));
        assert!(!target.exists());
        assert_eq!(
            fs::read(&backup).expect("recovery backup must remain readable"),
            b"recovery"
        );
    }

    #[test]
    fn startup_uses_valid_target_and_never_guesses_from_orphan_files() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");
        let opened = open_windows_keystore(&target).expect("new profile should open");
        drop(opened);
        let installed = fs::read(&target).expect("protected target should read");
        let orphan = directory.path().join(".keystore.plist.crash.dpapi-v2.tmp");
        fs::write(&orphan, b"partial replacement").expect("orphan fixture should write");
        let backup = directory
            .path()
            .join("keystore.plist.dpapi-v2-legacy-backup");
        fs::write(&backup, b"preserved old profile").expect("backup fixture should write");

        let reopened = open_windows_keystore(&target)
            .expect("valid installed target must remain authoritative");
        assert_eq!(
            fs::read(&target).expect("target should remain readable"),
            installed
        );
        assert_eq!(
            fs::read(&orphan).expect("orphan should be preserved for diagnosis"),
            b"partial replacement"
        );
        assert_eq!(
            fs::read(&backup).expect("backup should remain preserved"),
            b"preserved old profile"
        );
        drop(reopened);
    }

    #[test]
    fn legacy_target_with_existing_backup_requires_explicit_recovery() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");
        let backup = directory
            .path()
            .join("keystore.plist.dpapi-v2-legacy-backup");
        write_legacy(&target, &legacy_state());
        let original = fs::read(&target).expect("legacy fixture should read");
        fs::write(&backup, b"previous recovery").expect("backup fixture should write");

        assert!(matches!(
            open_windows_keystore(&target),
            Err(WindowsSecretStorageError::BackupAlreadyExists)
        ));
        assert_eq!(
            fs::read(&target).expect("legacy target must remain unchanged"),
            original
        );
        assert_eq!(
            fs::read(&backup).expect("backup must remain unchanged"),
            b"previous recovery"
        );
    }

    #[test]
    fn locked_writer_persists_updates_and_blocks_concurrent_open() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let target = directory.path().join("keystore.plist");
        let opened = open_windows_keystore(&target).expect("new profile should open");
        let writer = opened.writer;
        let store = SoftwareKeystore {
            state: RwLock::new(opened.state),
            update_state: Box::new(|_| {}),
            encryptor: opened.encryptor,
        };
        store
            .set_secret("persisted:test", b"persisted value")
            .expect("secret should be stored");
        let SoftwareKeystore { state, .. } = store;
        let state = state
            .into_inner()
            .expect("state lock should not be poisoned");
        writer
            .write_state(&state)
            .expect("protected update should be atomic");
        assert!(matches!(
            open_windows_keystore(&target),
            Err(WindowsSecretStorageError::ProfileLocked)
        ));
        drop(writer);

        let reopened = open_windows_keystore(&target).expect("updated profile should reopen");
        let store = SoftwareKeystore {
            state: RwLock::new(reopened.state),
            update_state: Box::new(|_| {}),
            encryptor: reopened.encryptor,
        };
        assert_eq!(
            store
                .get_secret("persisted:test")
                .expect("secret read should succeed")
                .expect("persisted secret should exist"),
            b"persisted value"
        );
        drop(store);
        drop(reopened.writer);
    }

    #[test]
    fn rejects_unknown_format_version() {
        let mut envelope =
            migrate_legacy_state(&legacy_state(), LEGACY_KEY).expect("migration should succeed");
        envelope.format_version = WINDOWS_KEYSTORE_FORMAT_VERSION + 1;
        assert!(matches!(
            envelope.validate(),
            Err(WindowsSecretStorageError::UnsupportedFormatVersion(_))
        ));
    }

    #[test]
    fn concurrent_install_secret_openers_return_one_key() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let path = directory.path().join("cloud-sync.install-secret");
        let barrier = Arc::new(Barrier::new(8));
        let mut threads = Vec::new();
        for _ in 0..8 {
            let barrier = Arc::clone(&barrier);
            let path = path.clone();
            threads.push(thread::spawn(move || {
                barrier.wait();
                load_or_create_cloud_sync_install_secret(&path)
            }));
        }

        let mut results = threads.into_iter().map(|handle| {
            handle
                .join()
                .expect("secret opener thread should not panic")
                .expect("secret opener should succeed")
        });
        let expected = results.next().expect("at least one result should exist");
        assert!(results.all(|secret| secret == expected));
        assert_eq!(
            read_cloud_sync_install_secret(&path).expect("stored secret should reopen"),
            expected
        );
    }

    #[test]
    fn install_secret_tampering_and_truncation_fail_closed() {
        let tamper_directory = tempfile::tempdir().expect("temporary directory should be created");
        let tamper_path = tamper_directory.path().join("cloud-sync.install-secret");
        load_or_create_cloud_sync_install_secret(&tamper_path)
            .expect("initial secret creation should succeed");
        let encoded = fs::read(&tamper_path).expect("secret envelope should be readable");
        let mut envelope: CloudSyncInstallSecretEnvelope =
            plist::from_bytes(&encoded).expect("secret envelope should decode");
        let mut protected = envelope.protected_secret.as_ref().to_vec();
        let midpoint = protected.len() / 2;
        protected[midpoint] ^= 0x20;
        envelope.protected_secret = protected.into();
        let mut tampered = Vec::new();
        plist::to_writer_binary(&mut tampered, &envelope).expect("tampered fixture should encode");
        fs::write(&tamper_path, &tampered).expect("tampered fixture should be written");
        assert!(load_or_create_cloud_sync_install_secret(&tamper_path).is_err());
        assert_eq!(
            fs::read(&tamper_path).expect("tampered file should remain"),
            tampered
        );

        let truncate_directory =
            tempfile::tempdir().expect("temporary directory should be created");
        let truncate_path = truncate_directory.path().join("cloud-sync.install-secret");
        load_or_create_cloud_sync_install_secret(&truncate_path)
            .expect("initial secret creation should succeed");
        let encoded = fs::read(&truncate_path).expect("secret envelope should be readable");
        fs::write(&truncate_path, &encoded[..encoded.len() / 2])
            .expect("truncated fixture should be written");
        assert!(load_or_create_cloud_sync_install_secret(&truncate_path).is_err());
        assert_eq!(
            fs::read(&truncate_path).expect("truncated file should remain"),
            &encoded[..encoded.len() / 2]
        );
    }
}
