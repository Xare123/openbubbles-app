use std::{
    path::Path,
    sync::{LazyLock, OnceLock},
};

use flexi_logger::{
    opt_format, Age, Cleanup, Criterion, FileSpec, Logger, LoggerHandle, Naming, WriteMode,
};
use log::info;
use tokio::runtime::Runtime;

// Dropping the handle shuts down flexi_logger's writers. Retain it for the
// process lifetime, including across background-isolate initialization calls.
static LOGGER_INITIALIZED: OnceLock<Option<LoggerHandle>> = OnceLock::new();

uniffi::setup_scaffolding!();

struct SensitiveLogFilter {
    inner: Box<dyn log::Log>,
}

impl SensitiveLogFilter {
    fn new(inner: Box<dyn log::Log>) -> Self {
        Self { inner }
    }
}

impl log::Log for SensitiveLogFilter {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        (!cfg!(target_os = "android") || metadata.level() <= log::Level::Warn)
            && self.inner.enabled(metadata)
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

#[cfg(not(target_os = "android"))]
mod desktop_native_logging;

pub fn init_logger(path: &Path) {
    LOGGER_INITIALIZED.get_or_init(|| {
        #[cfg(target_os = "android")]
        let log_spec = "warn";
        #[cfg(not(target_os = "android"))]
        let findmy_probe = cfg!(target_os = "windows")
            && std::env::var("OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE").as_deref()
                == Ok("1");
        #[cfg(not(target_os = "android"))]
        let log_spec = desktop_native_logging::log_spec_with_probe(
            cfg!(target_os = "windows")
                && std::env::var("OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS").as_deref() == Ok("1"),
            std::env::var("OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_VERBOSE_NATIVE_LOGS").as_deref()
                == Ok("1"),
            findmy_probe,
        );
        #[cfg(target_os = "android")]
        let system = android_logger::AndroidLogger::new(
            android_logger::Config::default().with_max_level(log::LevelFilter::Warn),
        );
        #[cfg(not(target_os = "android"))]
        let system = {
            if let Err(_) = std::env::var("RUST_LOG") {
                std::env::set_var("RUST_LOG", log_spec);
            }
            let mut builder = pretty_env_logger::formatted_builder();
            builder.parse_filters(&if findmy_probe {
                log_spec.to_owned()
            } else {
                std::env::var("RUST_LOG").unwrap_or_else(|_| log_spec.to_owned())
            });
            builder.build()
        };

        let (logger, handle) = Logger::try_with_str(log_spec)
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
        // Restored desktop logging must retain the same secret suppression as
        // Android, including when an operator opts into verbose diagnostics.
        let outputs: Vec<Box<dyn log::Log>> = vec![
            Box::new(SensitiveLogFilter::new(Box::new(system))),
            Box::new(SensitiveLogFilter::new(logger)),
        ];
        #[cfg(target_os = "android")]
        let max_level = log::Level::Warn;
        #[cfg(not(target_os = "android"))]
        let max_level = log::Level::Trace;

        match multi_log::MultiLogger::init(outputs, max_level) {
            Ok(()) => Some(handle),
            // Do not replace an existing process logger or crash account
            // startup. An unregistered file writer must be closed normally.
            Err(_) => None,
        }
    });
}

#[cfg(test)]
mod tests {
    use super::contains_sensitive_log_material;

    #[test]
    fn native_logger_handle_outlives_initialization() {
        // Isolate process-global registration from parallel native tests.
        const CHILD: &str = "OPENBUBBLES_LOGGER_LIFETIME_TEST_CHILD";
        if std::env::var(CHILD).as_deref() != Ok("1") {
            let mut command = std::process::Command::new(std::env::current_exe().unwrap());
            command
                .args([
                    "--exact",
                    "tests::native_logger_handle_outlives_initialization",
                    "--test-threads=1",
                ])
                .env(CHILD, "1")
                .env("OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS", "1")
                .env_remove("OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_FINDMY_PROBE")
                .env_remove("OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_VERBOSE_NATIVE_LOGS")
                .env("RUST_LOG", "off");
            #[cfg(target_os = "windows")]
            {
                use std::os::windows::process::CommandExt;
                command.creation_flags(0x08000000); // CREATE_NO_WINDOW
            }
            let output = command.output().unwrap();
            assert!(
                output.status.success(),
                "logger child failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        super::init_logger(directory.path());
        let handle = super::LOGGER_INITIALIZED
            .get()
            .and_then(Option::as_ref)
            .expect("registered live logger handle");
        log::warn!("synthetic-native-logger-lifetime-marker");
        log::debug!(target: "rust_lib_bluebubbles::cloud_sync_transient_bridge",
            "synthetic-retained-debug-marker");
        log::warn!("session-token: synthetic-secret-must-not-be-written");
        handle.flush();
        let mut contents = String::new();
        for entry in std::fs::read_dir(directory.path().join("logs")).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().is_some_and(|extension| extension == "log") {
                contents.push_str(&std::fs::read_to_string(path).unwrap());
            }
        }
        assert!(contents.contains("synthetic-native-logger-lifetime-marker"));
        #[cfg(not(target_os = "android"))]
        assert!(contents.contains("synthetic-retained-debug-marker"));
        assert!(!contents.contains("synthetic-secret-must-not-be-written"));
        super::init_logger(directory.path());
        assert!(std::ptr::eq(
            handle,
            super::LOGGER_INITIALIZED.get().unwrap().as_ref().unwrap()
        ));
        handle.shutdown();
    }

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
mod cloud_sync_attachment_materialization;
mod cloud_sync_attachment_parent;
mod cloud_sync_attachment_source_file;
mod cloud_sync_attachment_upload;
mod cloud_sync_attachment_upload_receipt;
mod cloud_sync_canonical_converter;
mod cloud_sync_canonical_dto;
mod cloud_sync_chat_identity;
mod cloud_sync_extension_payload;
mod cloud_sync_ids_attachment_source;
mod cloud_sync_ids_mutation_source;
mod cloud_sync_ids_mutation_stage;
mod cloud_sync_message_proto_patch;
mod cloud_sync_message_summary_patch;
mod cloud_sync_message_update_compose;
mod cloud_sync_message_update_stage;
mod cloud_sync_native_fetch;
mod cloud_sync_outbound;
mod cloud_sync_outbound_attachment;
mod cloud_sync_outbound_chat;
mod cloud_sync_protector;
mod cloud_sync_semantic_decoder;
mod cloud_sync_semantic_identity;
mod cloud_sync_transient_bridge;
mod frb_generated;
mod keystore;
mod native;
#[cfg(target_os = "windows")]
pub mod windows_secret_storage; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
