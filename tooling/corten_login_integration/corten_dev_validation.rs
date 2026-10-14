//! Explicit private-build adapter for the qualified Corten component.
//! No login flow, relay path, profile serialization, or production default changes.
use corten_mac_validation_probe::{
    decode_transfer,
    exchange::{self, ExchangeControl},
    load_framework,
    nac::HardwareConfig,
};
use rustpush::{
    mac_validation_provider::{MacValidationProvider, ValidationResult},
    PushError,
};
use std::{
    io::Read,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};
use tokio::sync::Semaphore;

const MARKER: &str = "openbubbles-corten-development:v1";
static INITIALIZATION: Mutex<()> = Mutex::new(());
static AUTHORITY: ProfileAuthority = ProfileAuthority::new();

struct ProfileAuthority {
    directory: OnceLock<PathBuf>,
    active: AtomicBool,
    revoked: AtomicBool,
}

impl ProfileAuthority {
    const fn new() -> Self {
        Self {
            directory: OnceLock::new(),
            active: AtomicBool::new(false),
            revoked: AtomicBool::new(false),
        }
    }
    fn bind(&self, directory: PathBuf) -> Result<(), PushError> {
        if self.revoked.load(Ordering::SeqCst) {
            return Err(safe_failure("profile revoked"));
        }
        // The initialization mutex serializes this operation in production.
        if let Some(bound) = self.directory.get() {
            if bound != &directory {
                self.revoke();
                return Err(safe_failure("profile binding"));
            }
        } else {
            self.directory
                .set(directory)
                .map_err(|_| safe_failure("profile binding"))?;
        }
        Ok(())
    }
    fn revoke(&self) {
        self.revoked.store(true, Ordering::SeqCst);
        self.active.store(false, Ordering::SeqCst);
    }
    fn check(&self) -> Result<(), PushError> {
        if self.revoked.load(Ordering::SeqCst) || !self.active.load(Ordering::SeqCst) {
            return Err(safe_failure("profile binding"));
        }
        Ok(())
    }
}

struct Provider {
    framework: Arc<Vec<u8>>,
    hardware: HardwareConfig,
    worker: Arc<Semaphore>,
}

fn safe_failure(stage: &str) -> PushError {
    PushError::IoError(std::io::Error::other(format!(
        "Mac validation failed at {stage}"
    )))
}

fn bounded_input(path: &Path, max: u64) -> Result<Vec<u8>, PushError> {
    let meta = std::fs::symlink_metadata(path)?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > max {
        return Err(safe_failure("private input admission"));
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(max + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max {
        return Err(safe_failure("private input admission"));
    }
    Ok(bytes)
}

/// No marker is normal. Once bound, another profile or malformed setup revokes
/// the provider for this process, including any exchange between stages.
pub(crate) fn initialize(directory: &Path) -> Result<(), PushError> {
    let result = (|| {
        let _guard = INITIALIZATION
            .lock()
            .map_err(|_| safe_failure("initialization"))?;
        let directory = std::fs::canonicalize(directory)?;
        AUTHORITY.bind(directory.clone())?;
        if AUTHORITY.active.load(Ordering::SeqCst) {
            return Ok(());
        }
        let private = directory.join(".mac-validation-dev");
        if !private.exists() {
            return Ok(());
        }
        if std::fs::canonicalize(&private)?.parent() != Some(directory.as_path()) {
            return Err(safe_failure("profile binding"));
        }
        if bounded_input(&private.join("ENABLED"), 64)? != MARKER.as_bytes() {
            return Err(safe_failure("development marker"));
        }
        let transfer = bounded_input(&private.join("hardware.oabs"), 4096)?;
        let hardware =
            decode_transfer(&transfer).map_err(|_| safe_failure("genuine hardware admission"))?;
        let framework = load_framework(&private.join("IMDAppleServices"))
            .map_err(|_| safe_failure("pinned framework admission"))?;
        let provider = Provider {
            framework: Arc::new(framework),
            hardware,
            worker: Arc::new(Semaphore::new(1)),
        };
        rustpush::mac_validation_provider::install(Arc::new(provider))?;
        AUTHORITY.active.store(true, Ordering::SeqCst);
        Ok(())
    })();
    if result.is_err() {
        AUTHORITY.revoke();
    }
    result
}

fn copy_hardware(hw: rustpush::macos::HardwareConfig) -> HardwareConfig {
    HardwareConfig {
        product_name: hw.product_name,
        io_mac_address: hw.io_mac_address,
        platform_serial_number: hw.platform_serial_number,
        platform_uuid: hw.platform_uuid,
        root_disk_uuid: hw.root_disk_uuid,
        board_id: hw.board_id,
        os_build_num: hw.os_build_num,
        platform_serial_number_enc: hw.platform_serial_number_enc,
        platform_uuid_enc: hw.platform_uuid_enc,
        root_disk_uuid_enc: hw.root_disk_uuid_enc,
        rom: hw.rom,
        rom_enc: hw.rom_enc,
        mlb: hw.mlb,
        mlb_enc: hw.mlb_enc,
    }
}

struct CancelOnDrop(ExchangeControl);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}

/// Dropping this future cancels later stages, but does not pretend to abort a
/// blocking request already in flight. Its permit is held until actual exit.
async fn run_worker<T, F>(worker: Arc<Semaphore>, budget: Duration, job: F) -> Result<T, PushError>
where
    T: Send + 'static,
    F: FnOnce(&ExchangeControl) -> Result<T, PushError> + Send + 'static,
{
    let control = ExchangeControl::new(budget);
    let _cancel = CancelOnDrop(control.clone());
    let work = async move {
        let permit = worker
            .acquire_owned()
            .await
            .map_err(|_| safe_failure("worker admission"))?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            control
                .check()
                .map_err(|_| safe_failure("worker cancellation"))?;
            job(&control)
        })
        .await
        .map_err(|_| safe_failure("worker completion"))?
    };
    tokio::time::timeout(budget, work)
        .await
        .map_err(|_| safe_failure("bounded exchange timeout"))?
}

impl MacValidationProvider for Provider {
    fn generate(&self, hardware: rustpush::macos::HardwareConfig) -> ValidationResult {
        let hardware = copy_hardware(hardware);
        let matches = hardware == self.hardware;
        let framework = Arc::clone(&self.framework);
        let worker = Arc::clone(&self.worker);
        Box::pin(async move {
            if !matches {
                return Err(safe_failure("hardware binding"));
            }
            AUTHORITY.check()?;
            run_worker(worker, Duration::from_secs(75), move |control| {
                let mut phase = "startup";
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    exchange::generate(&hardware, &framework, &mut phase, &mut |_| {}, &|| {
                        AUTHORITY.check().map_err(|_| "profile binding rejected")?;
                        control.check()
                    })
                    .map_err(|_| ())
                }));
                match result {
                    Ok(Ok(proof)) => Ok(proof),
                    _ => Err(safe_failure(phase)),
                }
            })
            .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_private_input_is_bounded() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("hardware.oabs");
        std::fs::write(&file, [0; 4097]).unwrap();
        assert!(bounded_input(&file, 4096).is_err());
        assert!(bounded_input(temp.path(), 4096).is_err());
    }
    #[test]
    fn failure_does_not_include_hardware_or_proof() {
        assert_eq!(
            safe_failure("hardware binding").to_string(),
            "IO error: Mac validation failed at hardware binding"
        );
    }
    #[test]
    fn another_profile_permanently_revokes_the_provider() {
        let authority = ProfileAuthority::new();
        authority.bind(PathBuf::from("profile-a")).unwrap();
        authority.active.store(true, Ordering::SeqCst);
        assert!(authority.check().is_ok());
        assert!(authority.bind(PathBuf::from("profile-b")).is_err());
        assert!(authority.check().is_err());
        assert!(authority.bind(PathBuf::from("profile-a")).is_err());
    }
    #[test]
    fn an_unprovisioned_profile_does_not_authorize_a_later_profile() {
        let authority = ProfileAuthority::new();
        authority.bind(PathBuf::from("profile-a")).unwrap();
        assert!(authority.check().is_err());
        assert!(authority.bind(PathBuf::from("profile-b")).is_err());
    }
    #[tokio::test]
    async fn mismatched_hardware_fails_before_framework_or_network_access() {
        // Deliberately invalid values are rejection-only fixtures, never sent.
        let hardware = rustpush::macos::HardwareConfig {
            product_name: String::new(),
            io_mac_address: [0; 6],
            platform_serial_number: String::new(),
            platform_uuid: String::new(),
            root_disk_uuid: String::new(),
            board_id: String::new(),
            os_build_num: String::new(),
            platform_serial_number_enc: vec![],
            platform_uuid_enc: vec![],
            root_disk_uuid_enc: vec![],
            rom: vec![],
            rom_enc: vec![],
            mlb: String::new(),
            mlb_enc: vec![],
        };
        let mut expected = copy_hardware(hardware.clone());
        expected.board_id = "different-rejection-fixture".into();
        let provider = Provider {
            framework: Arc::new(vec![]),
            hardware: expected,
            worker: Arc::new(Semaphore::new(1)),
        };
        let error = provider.generate(hardware).await.unwrap_err();
        assert_eq!(
            error.to_string(),
            safe_failure("hardware binding").to_string()
        );
    }
    #[tokio::test]
    async fn production_mac_path_retains_unconfigured_guard() {
        use rustpush::OSConfig;
        // The real provider registry is never installed by these unit tests.
        let config = rustpush::macos::MacOSConfig {
            inner: rustpush::macos::HardwareConfig {
                product_name: String::new(),
                io_mac_address: [0; 6],
                platform_serial_number: String::new(),
                platform_uuid: String::new(),
                root_disk_uuid: String::new(),
                board_id: String::new(),
                os_build_num: String::new(),
                platform_serial_number_enc: vec![],
                platform_uuid_enc: vec![],
                root_disk_uuid_enc: vec![],
                rom: vec![],
                rom_enc: vec![],
                mlb: String::new(),
                mlb_enc: vec![],
            },
            version: String::new(),
            protocol_version: 0,
            device_id: String::new(),
            icloud_ua: String::new(),
            aoskit_version: String::new(),
            udid: None,
        };
        assert!(matches!(
            config.generate_validation_data().await,
            Err(PushError::MacValidationUnavailable)
        ));
    }
    #[tokio::test]
    async fn caller_cancellation_keeps_the_permit_until_worker_exit() {
        let worker = Arc::new(Semaphore::new(1));
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (done_tx, done_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(run_worker(
            worker.clone(),
            Duration::from_secs(5),
            move |control| {
                started_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(3)).unwrap();
                let cancelled = control.check().is_err();
                done_tx.send(cancelled).unwrap();
                Ok(())
            },
        ));
        started_rx.await.unwrap();
        task.abort();
        let _ = task.await;
        assert_eq!(worker.available_permits(), 0);
        release_tx.send(()).unwrap();
        assert!(done_rx.await.unwrap());
        let permit = tokio::time::timeout(Duration::from_secs(1), worker.acquire())
            .await
            .unwrap()
            .unwrap();
        drop(permit);
    }
    #[tokio::test]
    async fn cancelled_queued_worker_never_starts() {
        let worker = Arc::new(Semaphore::new(1));
        let held = worker.clone().acquire_owned().await.unwrap();
        let result = run_worker(worker.clone(), Duration::from_millis(10), |_| {
            panic!("a queued timeout must not run the job");
            #[allow(unreachable_code)]
            Ok::<(), PushError>(())
        })
        .await;
        assert!(result.is_err());
        drop(held);
        assert_eq!(worker.available_permits(), 1);
    }
}
