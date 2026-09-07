/// Keep the diagnostic Windows loop useful without serializing bulk CloudKit
/// records into rotating logs. Normal desktop applications keep their existing
/// behavior; an operator can explicitly request full native harness logging.
pub(crate) fn log_spec(windows_harness: bool, verbose_harness: bool) -> &'static str {
    if windows_harness && !verbose_harness {
        "warn,rust_lib_bluebubbles::cloud_sync_transient_bridge=debug"
    } else {
        "debug"
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn harness_is_bounded_unless_explicitly_verbose() {
        assert_eq!(super::log_spec(false, false), "debug");
        assert_eq!(super::log_spec(false, true), "debug");
        assert_eq!(super::log_spec(true, true), "debug");
        assert_eq!(
            super::log_spec(true, false),
            "warn,rust_lib_bluebubbles::cloud_sync_transient_bridge=debug"
        );
    }
}
