# Credential-free production-client transport lane

`production-transport-only` and `production-android-build-only` use the existing
ephemeral GCE workflow and its
unchanged identity, 75-minute lifetime and exact-name cleanup. It accepts only
application source `ad05e2136a9f722aab74d3381a65483e49f5d1dc`, the existing trusted
branch, primary lane, and both write/upload flags off.

The application Cargo.lock and all six recursive pins are verified. Temporary
exports expose the actual unchanged IDS/CloudKit Rustls client and empty
AppleAccount native-TLS client. There is no account/profile, Anisette request,
hardware validation, CloudKit operation, iMessage, APK, Flutter, Gradle or emulator.
Three fixed public GETs report status/origin/errors only; response bodies,
headers and cookies are not inspected. Existing certificate/hostname checks and
AppleAccount redirect policy remain intact. A configured proxy causes a refusal,
not an environment override.

One locked preparation, one Linux build/run, and one ARM64 Android console build
are bounded individually. Android is compiled, NOT executed. Failed Google
control stops the Android build. Source overlays are restored byte-exactly after
errors/signals; owned process groups are reaped. Source restoration failure is
a failed result. The runner timeout and existing cleanup remain the final bound.

The initial run38222855679 passed Linux strict transport (Google200, original
init.ess200, original gsa404) but Android OpenSSL install failed because default
`aarch64-linux-android-ranlib` was absent. The pinned openssl-src300.4.1 builder
uses cc1.2.60's target-prefixed RANLIB lookup. Select the existing NDK's
`RANLIB_aarch64_linux_android=.../llvm-ranlib`; no dependency or trust change.

`production-android-build-only` invokes `--android-only` and skips the Linux
binary and HTTPS requests. It retains exact source/cleanliness/proxy/ABI and
restoration guards. Its result is `android_artifact_ready_transport_unrun` with
`linux_probe_executed=false`; it does not copy a previous transport pass into a
new result. Use prior run38222855679 for the separate Linux evidence. This
avoids repeating passed HTTPS checks when repairing only the Android build.

The artifact contains only public diagnostic source, logs, hashes, restoration
receipts and the ARM64 console binary. Strict TLS is separate from service health
(HTTP 5xx), authentication, device compatibility and release acceptance. No green
workflow proves Apple login or CloudKit. Do not retry automatically after failure.

Run the console binary on an authorized disposable ARM64 device only after
hash/ABI verification. R's earlier single Private DNS grant does not authorize a
second setting change; obtain a fresh bounded grant and restore settings. Do not
enter credentials or use the Pixel as a transport shortcut.
