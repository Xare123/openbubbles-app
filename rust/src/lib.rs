use std::{
    path::Path,
    sync::{LazyLock, OnceLock},
};

use flexi_logger::{opt_format, Age, Cleanup, Criterion, FileSpec, Logger, Naming, WriteMode};
use log::info;
use tokio::runtime::Runtime;

static LOGGER_INITIALIZED: OnceLock<()> = OnceLock::new();

uniffi::setup_scaffolding!();

#[cfg(target_os = "android")]
struct SensitiveLogFilter {
    inner: Box<dyn log::Log>,
}

#[cfg(target_os = "android")]
impl SensitiveLogFilter {
    fn new(inner: Box<dyn log::Log>) -> Self {
        Self { inner }
    }
}

#[cfg(target_os = "android")]
impl log::Log for SensitiveLogFilter {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::Level::Warn && self.inner.enabled(metadata)
    }

    fn log(&self, record: &log::Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }

        let message = record.args().to_string();
        if contains_sensitive_log_material(&message) {
            return;
        }

        self.inner.log(record);
    }

    fn flush(&self) {
        self.inner.flush();
    }
}

fn contains_sensitive_log_material(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    const SENSITIVE_MARKERS: &[&str] = &[
        "authorization",
        "auth response",
        "cookie",
        "credential",
        "decoded_spd",
        "device-key",
        "mailto:",
        "password data",
        "plist",
        "private-key",
        "pseud:",
        "push-token",
        "raw connect response",
        "register response",
        "security code failed, response",
        "sending apns query",
        "session-token",
        "tel:+",
        "xml body",
    ];

    SENSITIVE_MARKERS
        .iter()
        .any(|marker| message.contains(marker))
}

pub static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    info!("creating runner");
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("tokio-rustpush")
        .enable_all()
        .build()
        .unwrap()
});

pub mod bbhwinfo {
    include!(concat!(env!("OUT_DIR"), "/bbhwinfo.rs"));
}

pub fn init_logger(path: &Path) {
    LOGGER_INITIALIZED.get_or_init(|| {
        #[cfg(target_os = "android")]
        let system = android_logger::AndroidLogger::new(
            android_logger::Config::default().with_max_level(log::LevelFilter::Warn),
        );
        #[cfg(not(target_os = "android"))]
        let system = {
            if let Err(_) = std::env::var("RUST_LOG") {
                std::env::set_var("RUST_LOG", "debug");
            }
            pretty_env_logger::formatted_builder().build()
        };

        #[cfg(target_os = "android")]
        let log_spec = "warn";
        #[cfg(not(target_os = "android"))]
        let log_spec = "debug";

        let (logger, _) = Logger::try_with_str(log_spec)
            .expect("No logger?")
            .log_to_file(
                FileSpec::default()
                    .directory(path.join("logs"))
                    .suppress_timestamp(),
            )
            .append()
            .format(opt_format)
            .cleanup_in_background_thread(false)
            .rotate(
                Criterion::AgeOrSize(Age::Day, 1024 * 1024 * 10 /* 10 MB */),
                Naming::Numbers,
                Cleanup::KeepLogFiles(1),
            )
            .write_mode(WriteMode::BufferAndFlush)
            .build()
            .unwrap();

        // Logging is process-global. Background isolates can call this entry
        // point again, so repeated initialization must be harmless.
        #[cfg(target_os = "android")]
        let outputs: Vec<Box<dyn log::Log>> = vec![
            Box::new(SensitiveLogFilter::new(Box::new(system))),
            Box::new(SensitiveLogFilter::new(logger)),
        ];
        #[cfg(not(target_os = "android"))]
        let outputs: Vec<Box<dyn log::Log>> = vec![Box::new(system), logger];

        #[cfg(target_os = "android")]
        let max_level = log::Level::Warn;
        #[cfg(not(target_os = "android"))]
        let max_level = log::Level::Trace;

        let _ = multi_log::MultiLogger::init(outputs, max_level);
    });
}

#[cfg(test)]
mod tests {
    use super::contains_sensitive_log_material;

    #[test]
    fn suppresses_ids_secrets_and_raw_responses() {
        assert!(contains_sensitive_log_material(
            r#"session-token": Data([1, 2, 3])"#
        ));
        assert!(contains_sensitive_log_material(
            r#"push-token": Data([4, 5, 6])"#
        ));
        assert!(contains_sensitive_log_material(
            "Got auth response YWJjZA=="
        ));
        assert!(contains_sensitive_log_material(
            "raw connect response [1, 2, 3]"
        ));
        assert!(contains_sensitive_log_material(
            "Validating pseudonym pseud:example for handle mailto:user@example.com"
        ));
        assert!(contains_sensitive_log_material(
            "Registering handle tel:+15555550100"
        ));
    }

    #[test]
    fn preserves_actionable_transport_diagnostics() {
        assert!(!contains_sensitive_log_material(
            "APS connection closed with status 503"
        ));
        assert!(!contains_sensitive_log_material(
            "Failed to read from APS socket"
        ));
    }
}

pub mod api;
mod cloud_sync_canonical_converter;
mod cloud_sync_canonical_dto;
mod cloud_sync_native_fetch;
mod cloud_sync_protector;
mod cloud_sync_semantic_decoder;
mod cloud_sync_semantic_identity;
mod cloud_sync_transient_bridge;
mod frb_generated;
mod keystore;
mod native;
#[cfg(target_os = "windows")]
pub mod windows_secret_storage; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
