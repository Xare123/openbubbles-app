//! Local protected-store lifecycle lease.
//!
//! True local mutual exclusion for the native protected-store directory,
//! independent of the network CloudKit interlock.
//!
//! The parent bridges acquire/release around receive stage/adopt/commit and
//! recovery/GC inventory+cleanup only, never around remote network fetch:
//! holding process-wide exclusion across network I/O would stall peers.
//!
//! Each lease holds two gates for its whole lifetime: a per-canonical-directory
//! process-wide Tokio mutex (same-process tasks wait asynchronously) and an
//! fs2 OS file lock (cross-process peers fail fast with a fixed busy error).
//! Same-process waits are bounded too: timeout rejects the waiter, never the
//! owner, so an abandoned handle cannot wedge ordinary message delivery.
//! There is no TTL or elapsed-time takeover; contention fails closed and the
//! caller retries later.
//!
//! Leak behavior also fails closed: a leaked (never released) lease keeps both
//! gates until process exit, when the OS releases the file lock. Do not rely
//! on Dart finalizers; always release explicitly.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use anyhow::anyhow;

/// Fixed failure vocabulary. Strings are stable for parent matching and never
/// embed filesystem paths.
pub const ERR_INVALID_DIRECTORY: &str = "cloud_sync_local_store_lock_invalid_directory";
pub const ERR_UNSAFE_LINK: &str = "cloud_sync_local_store_lock_unsafe_link";
pub const ERR_BUSY: &str = "cloud_sync_local_store_lock_busy";
pub const ERR_UNAVAILABLE: &str = "cloud_sync_local_store_lock_unavailable";
pub const ERR_CLOSED: &str = "cloud_sync_local_store_lock_closed";

/// Lock file inside the private store directory. It carries no data; the OS
/// advisory lock on it is the cross-process gate.
const LOCK_FILE_NAME: &str = "protected_store.lock";
/// Raw Win32 ERROR_LOCK_VIOLATION reported by LockFileEx with
/// LOCKFILE_FAIL_IMMEDIATELY on contention. Unix contention already surfaces
/// as WouldBlock through flock.
#[cfg(target_os = "windows")]
const ERROR_LOCK_VIOLATION_RAW: i32 = 33;
const MAX_LIVE_DIRECTORIES: usize = 128;

type DirSlot = tokio::sync::Mutex<()>;

fn registry() -> &'static Mutex<HashMap<PathBuf, Weak<DirSlot>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<PathBuf, Weak<DirSlot>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn slot_for(key: &Path) -> anyhow::Result<Arc<DirSlot>> {
    let mut map = registry()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if let Some(slot) = map.get(key).and_then(Weak::upgrade) {
        return Ok(slot);
    }
    // Drop dead entries so the registry cannot grow without bound from
    // directories that are no longer leased. Live entries are always kept,
    // so a directory never loses its shared slot while leased.
    map.retain(|_, weak| weak.upgrade().is_some());
    if map.len() >= MAX_LIVE_DIRECTORIES {
        return Err(anyhow!("{}", ERR_UNAVAILABLE));
    }
    let slot = Arc::new(DirSlot::new(()));
    map.insert(key.to_path_buf(), Arc::downgrade(&slot));
    Ok(slot)
}

fn canonical_directory(dir: &Path) -> anyhow::Result<PathBuf> {
    if !dir.is_absolute() {
        return Err(anyhow!("{}", ERR_INVALID_DIRECTORY));
    }
    let meta = std::fs::symlink_metadata(dir).map_err(|_| anyhow!("{}", ERR_INVALID_DIRECTORY))?;
    if meta.file_type().is_symlink() || !meta.file_type().is_dir() {
        return Err(anyhow!("{}", ERR_INVALID_DIRECTORY));
    }
    std::fs::canonicalize(dir).map_err(|_| anyhow!("{}", ERR_INVALID_DIRECTORY))
}

fn open_and_lock(key: &Path) -> anyhow::Result<std::fs::File> {
    let lock_path = key.join(LOCK_FILE_NAME);
    // Never open through a computed symlink: a swapped lock path could
    // serialize against (or disturb) an unrelated file. The residual
    // check-then-open race is bounded by the private-directory trust
    // boundary, since an actor able to swap entries there already has
    // write access to the store itself.
    if let Ok(meta) = std::fs::symlink_metadata(&lock_path) {
        if meta.file_type().is_symlink() {
            return Err(anyhow!("{}", ERR_UNSAFE_LINK));
        }
        if !meta.file_type().is_file() {
            return Err(anyhow!("{}", ERR_UNAVAILABLE));
        }
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options
        .open(&lock_path)
        .map_err(|_| anyhow!("{}", ERR_UNAVAILABLE))?;
    let opened = file
        .metadata()
        .map_err(|_| anyhow!("{}", ERR_UNAVAILABLE))?;
    if !opened.is_file() || opened.file_type().is_symlink() {
        return Err(anyhow!("{}", ERR_UNSAFE_LINK));
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::MetadataExt;
        if opened.file_attributes() & 0x400 != 0 {
            return Err(anyhow!("{}", ERR_UNSAFE_LINK));
        }
    }
    match fs2::FileExt::try_lock_exclusive(&file) {
        Ok(()) => Ok(file),
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
            Err(anyhow!("{}", ERR_BUSY))
        }
        // LockFileEx reports contention as raw ERROR_LOCK_VIOLATION (33).
        // Match that code as well so cross-process contention reports busy
        // regardless of standard-library ErrorKind mapping. Every other
        // error, including permission failures, stays unavailable.
        #[cfg(target_os = "windows")]
        Err(error) if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION_RAW) => {
            Err(anyhow!("{}", ERR_BUSY))
        }
        Err(_) => Err(anyhow!("{}", ERR_UNAVAILABLE)),
    }
}

struct LeaseState {
    slot: Option<tokio::sync::OwnedMutexGuard<()>>,
    file: Option<std::fs::File>,
    closed: bool,
}

/// Opaque-friendly lease handle. Send + Sync so flutter_rust_bridge can hold
/// it opaquely; Debug is redacted to the closed flag only.
pub struct LocalProtectedStoreLease {
    state: Mutex<LeaseState>,
}

impl LocalProtectedStoreLease {
    /// Acquires the lease for an existing absolute private directory.
    /// Same-process callers wait on the per-directory mutex; a lock held by
    /// another process fails fast with ERR_BUSY. Blocking filesystem and
    /// OS-lock work runs on the blocking pool, never the async worker.
    pub async fn acquire(dir: &Path) -> anyhow::Result<Arc<Self>> {
        let pending = dir.to_path_buf();
        let key = tokio::task::spawn_blocking(move || canonical_directory(&pending))
            .await
            .map_err(|_| anyhow!("{}", ERR_UNAVAILABLE))??;
        let guard = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            slot_for(&key)?.lock_owned(),
        )
        .await
        .map_err(|_| anyhow!("{}", ERR_BUSY))?;
        let pending = key.clone();
        let file = tokio::task::spawn_blocking(move || open_and_lock(&pending))
            .await
            .map_err(|_| anyhow!("{}", ERR_UNAVAILABLE))?;
        match file {
            Ok(file) => Ok(Arc::new(Self {
                state: Mutex::new(LeaseState {
                    slot: Some(guard),
                    file: Some(file),
                    closed: false,
                }),
            })),
            Err(error) => {
                drop(guard);
                Err(error)
            }
        }
    }

    /// Idempotent release. Safe to call any number of times, from any thread,
    /// and from Drop. Never fails: the handle is closed, which releases the
    /// OS lock even if unlock reports an error.
    pub fn release(&self) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if state.closed {
            return;
        }
        state.closed = true;
        if let Some(file) = state.file.take() {
            let _ = fs2::FileExt::unlock(&file);
        }
        state.slot.take();
    }

    /// True once released. A closed lease must not guard new work; acquire a
    /// fresh lease instead.
    pub fn is_closed(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .closed
    }

    /// Fails with ERR_CLOSED when this lease was already released.
    pub fn ensure_usable(&self) -> anyhow::Result<()> {
        if self.is_closed() {
            return Err(anyhow!("{}", ERR_CLOSED));
        }
        Ok(())
    }
}

impl std::fmt::Debug for LocalProtectedStoreLease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocalProtectedStoreLease")
            .field("closed", &self.is_closed())
            .finish()
    }
}

impl Drop for LocalProtectedStoreLease {
    fn drop(&mut self) {
        self.release();
    }
}

const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<LocalProtectedStoreLease>();
};

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn same_directory_tasks_exclude_through_release() {
        let dir = tempfile::tempdir().unwrap();
        let first = LocalProtectedStoreLease::acquire(dir.path()).await.unwrap();
        let path = dir.path().to_path_buf();
        let entered = Arc::new(AtomicBool::new(false));
        let entered_clone = entered.clone();
        let waiter = tokio::spawn(async move {
            let _second = LocalProtectedStoreLease::acquire(&path).await.unwrap();
            entered_clone.store(true, Ordering::SeqCst);
        });
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(
            !entered.load(Ordering::SeqCst),
            "second lease must wait for release"
        );
        first.release();
        tokio::time::timeout(Duration::from_secs(10), waiter)
            .await
            .expect("waiter finished after release")
            .expect("waiter joined");
        assert!(entered.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn distinct_directories_are_independent() {
        let first = tempfile::tempdir().unwrap();
        let second = tempfile::tempdir().unwrap();
        let _one = LocalProtectedStoreLease::acquire(first.path())
            .await
            .unwrap();
        let _two = LocalProtectedStoreLease::acquire(second.path())
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn release_is_idempotent_and_close_is_visible() {
        let dir = tempfile::tempdir().unwrap();
        let lease = LocalProtectedStoreLease::acquire(dir.path()).await.unwrap();
        let twin = lease.clone();
        assert!(!lease.is_closed());
        lease.ensure_usable().unwrap();
        lease.release();
        assert!(lease.is_closed());
        assert!(twin.is_closed());
        assert_eq!(lease.ensure_usable().unwrap_err().to_string(), ERR_CLOSED);
        lease.release();
        drop(lease);
        drop(twin);
        // A fresh lease works after release.
        let again = LocalProtectedStoreLease::acquire(dir.path()).await.unwrap();
        assert!(!again.is_closed());
    }

    #[tokio::test]
    async fn invalid_paths_are_rejected_without_path_detail() {
        let err = LocalProtectedStoreLease::acquire(Path::new("relative/path"))
            .await
            .unwrap_err();
        assert_eq!(err.to_string(), ERR_INVALID_DIRECTORY);
        let fixture = tempfile::tempdir().unwrap();
        let missing = fixture.path().join("no-such-dir");
        let err = LocalProtectedStoreLease::acquire(&missing)
            .await
            .unwrap_err();
        assert_eq!(err.to_string(), ERR_INVALID_DIRECTORY);
        assert!(!err.to_string().contains("no-such-dir"));
        let file = tempfile::NamedTempFile::new().unwrap();
        // NamedTempFile paths are absolute, so a non-directory is invalid.
        let err = LocalProtectedStoreLease::acquire(file.path())
            .await
            .unwrap_err();
        assert_eq!(err.to_string(), ERR_INVALID_DIRECTORY);
    }

    #[tokio::test]
    async fn symlinked_lock_file_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let lock_path = dir.path().join(LOCK_FILE_NAME);
        let target = dir.path().join("elsewhere");
        std::fs::write(&target, b"x").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &lock_path).unwrap();
        #[cfg(windows)]
        {
            if std::os::windows::fs::symlink_file(&target, &lock_path).is_err() {
                // Symlink privilege missing on this host; nothing to verify.
                return;
            }
        }
        let err = LocalProtectedStoreLease::acquire(dir.path())
            .await
            .unwrap_err();
        assert_eq!(err.to_string(), ERR_UNSAFE_LINK);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn symlinked_directory_is_rejected() {
        let fixture = tempfile::tempdir().unwrap();
        let dir = fixture.path().join("real");
        std::fs::create_dir(&dir).unwrap();
        let link = fixture.path().join("link");
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        let err = LocalProtectedStoreLease::acquire(&link).await.unwrap_err();
        assert_eq!(err.to_string(), ERR_INVALID_DIRECTORY);
    }

    #[tokio::test]
    async fn waiter_timeout_never_takes_ownership() {
        let dir = tempfile::tempdir().unwrap();
        let first = LocalProtectedStoreLease::acquire(dir.path()).await.unwrap();
        let err = LocalProtectedStoreLease::acquire(dir.path())
            .await
            .unwrap_err();
        assert_eq!(err.to_string(), ERR_BUSY);
        assert!(!first.is_closed());
        first.release();
        LocalProtectedStoreLease::acquire(dir.path()).await.unwrap();
    }

    const CHILD_ENV: &str = "OPENBUBBLES_LOCAL_STORE_LOCK_TEST_CHILD";
    const CHILD_DIR_ENV: &str = "OPENBUBBLES_LOCAL_STORE_LOCK_TEST_DIR";

    /// Lock-holding child for the cross-process test below. No-op unless
    /// spawned with CHILD_ENV set by that test.
    #[tokio::test]
    async fn cross_process_child_holds_lock() {
        if std::env::var(CHILD_ENV).as_deref() != Ok("1") {
            return;
        }
        let dir = std::env::var(CHILD_DIR_ENV).expect("child dir env");
        let _lease = LocalProtectedStoreLease::acquire(Path::new(&dir))
            .await
            .expect("child acquire");
        std::fs::write(Path::new(&dir).join("held"), b"1").expect("child marker");
        tokio::time::sleep(Duration::from_secs(60)).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cross_process_lock_reports_busy() {
        let dir = tempfile::tempdir().unwrap();
        let mut command = tokio::process::Command::new(std::env::current_exe().unwrap());
        command
            .kill_on_drop(true)
            .args([
                "--exact",
                "cloud_sync_local_store_lock::tests::cross_process_child_holds_lock",
                "--test-threads=1",
            ])
            .env(CHILD_ENV, "1")
            .env(CHILD_DIR_ENV, dir.path())
            .env("RUST_LOG", "off");
        #[cfg(target_os = "windows")]
        {
            command.creation_flags(0x08000000);
        }
        let mut child = command.spawn().expect("spawn lock child");
        let held = dir.path().join("held");
        for _ in 0..200 {
            if tokio::fs::metadata(&held).await.is_ok() {
                break;
            }
            assert!(
                child.try_wait().expect("child wait").is_none(),
                "lock child exited early"
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(
            tokio::fs::metadata(&held).await.is_ok(),
            "lock child never signalled"
        );
        let err = LocalProtectedStoreLease::acquire(dir.path())
            .await
            .unwrap_err();
        assert_eq!(err.to_string(), ERR_BUSY);
        child.start_kill().expect("kill lock child");
        child.wait().await.expect("reap lock child");
        // The OS releases the child lock with the process; poll briefly
        // rather than assuming a fixed teardown delay.
        let lease = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                match LocalProtectedStoreLease::acquire(dir.path()).await {
                    Ok(lease) => return lease,
                    Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
                }
            }
        })
        .await
        .expect("lock freed after child exit");
        lease.ensure_usable().unwrap();
    }
}
