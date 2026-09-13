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

/// Find My test-host diagnostics are a bounded, value-free module even when
/// broad native verbosity was requested by the surrounding environment.
pub(crate) fn log_spec_with_probe(
    windows_harness: bool,
    verbose_harness: bool,
    findmy_probe: bool,
) -> &'static str {
    if findmy_probe {
        "off,rustpush::findmy::diagnostics=debug"
    } else {
        log_spec(windows_harness, verbose_harness)
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

    #[test]
    fn findmy_probe_cannot_enable_broad_native_debug() {
        for harness in [false, true] {
            for verbose in [false, true] {
                assert_eq!(
                    super::log_spec_with_probe(harness, verbose, true),
                    "off,rustpush::findmy::diagnostics=debug"
                );
                assert_eq!(
                    super::log_spec_with_probe(harness, verbose, false),
                    super::log_spec(harness, verbose)
                );
            }
        }
    }
}
