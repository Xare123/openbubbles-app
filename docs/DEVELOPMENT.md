# OpenBubbles Android development

This document describes the supported local workflow for the Flutter Android
client. It is intentionally separate from the end-user setup guide: a local
build is useful for testing, but it does not replace a trusted relay, Apple
device, or production signing configuration.

## Scope and message routing

OpenBubbles is the iMessage client. The relay or Mac/iPhone side handles the
Apple service connection; the Android app renders conversations, sends user
actions, persists local state, and receives relay events.

For a predictable test environment, keep the routing boundary explicit:

- iMessage traffic stays in OpenBubbles and its configured relay.
- SMS, MMS, and RCS stay in the device's default Google Messages app unless a
  test specifically targets forwarding.
- Do not enable Google Messages and OpenBubbles SMS forwarding at the same time
  during a delivery test. Two active paths can create duplicates, reorder
  messages, or make a successful delivery look lost.

This boundary is a diagnostic control, not a claim that every carrier or relay
configuration behaves identically.

## Toolchain

The current CI workflow is the source of truth for the tested build matrix:

- Flutter 3.44.8, stable channel
- Dart 3.12 or newer, supplied by that Flutter release
- Rust stable for the Rust bridge and RustPush components
- Java 21 (Temurin in CI)
- Android SDK and command-line tools
- Protobuf compiler (`protoc`)

The older Java 8 link in historical contribution notes is not the CI target.
Use the same major Java version as CI when diagnosing Gradle failures.

## Local checkout and build

Clone the repository with submodules, then install dependencies:

```bash
git clone --recurse-submodules <your-fork-url>
cd openbubbles-app
flutter pub get
```

Run a focused test before a full build:

```bash
flutter test test/helpers/message_helper_test.dart
flutter test test/helpers/memory/bounded_byte_cache_test.dart \
  test/helpers/memory/bounded_lru_map_test.dart
```

The CI workflow builds unsigned arm64 Alpha artifacts. The equivalent local
commands are:

```bash
flutter build apk --flavor alpha --profile --target-platform android-arm64
flutter build apk --flavor alpha --debug --target-platform android-arm64
```

On Windows, use the verified wrapper so a stale APK cannot survive a failed
Rust native build:

```powershell
.\tooling\android\build_verified_alpha.ps1 -Mode profile
```

The wrapper deletes only the previous target APK before building and verifies
that the resulting archive contains Flutter, Dart AOT, and
`librust_lib_bluebubbles.so` ARM64 libraries. Do not install an APK when the
wrapper fails this gate. It discovers Flutter and `protoc` from `PATH`, the
Android SDK from `ANDROID_SDK_ROOT` or `ANDROID_HOME`, and Cargo/Rustup from
their standard environment variables. Non-standard toolchains can be passed
with the script's explicit path parameters. `-PerlExecutable`,
`-PerlModuleRoot`, and `-MakeExecutable` are available for Windows OpenSSL
environments that do not provide those prerequisites on `PATH`.

Use a release build for performance measurements. Do not compare a debug build
with a store release and attribute every frame difference to application code.
Generated files, signing keys, `.env` values, relay registration codes, and
Apple credentials must not be committed.

### Rust bridge regeneration guard

The currently pinned `flutter_rust_bridge_codegen` can emit six duplicate SSE
codec implementations after the Cloud Sync API types are added. The duplicate
bodies observed in this repository are byte-identical, but Rust correctly
rejects the duplicate trait implementations.

After bridge regeneration, run the guarded postprocessor once and then verify
the result:

```powershell
flutter_rust_bridge_codegen generate
.\tooling\frb\guard_generated_sse_impls.ps1 -Mode Deduplicate -ExpectedRemovalCount 6
.\tooling\frb\guard_generated_sse_impls.ps1 -Mode Verify
```

The script refuses to write if the number changes, duplicate bodies differ,
the generated file changes concurrently, or any duplicate signature remains.
Treat any refusal as a code-generation change that requires review. Do not
increase the expected count merely to make generation pass. The long-term fix
is to update or correct the generator, then remove this narrow guard.

## Windows x64 build notes

When an x64 build runs on a Windows ARM64 host, use the Visual Studio x64
generator and confirm every packaged PE has machine type `0x8664`. The
repository CMake configuration normalizes `CMAKE_SYSTEM_PROCESSOR` for this
case so ObjectBox selects its x64 binary.

Long OpenSSL build paths can exceed compiler limits. `cargokit.cmake` accepts
`CARGOKIT_TARGET_TEMP_DIR_OVERRIDE` for an explicit short Cargo target
directory. Keep that cache outside the source tree and do not silently reuse
an artifact built for another architecture.

The Windows install rule excludes the isolated debug-runtime cluster copied by
the media package and explicitly bundles the target-specific
`WebView2Loader.dll`. After packaging, require all of the following:

1. every EXE and DLL reports x64 machine type;
2. no static import points to a missing redistributable DLL;
3. no debug C/C++ runtime is bundled or imported;
4. all Flutter tests pass with the release directory on `PATH`;
5. signing is applied only to the isolated release bundle, never to build
   inputs.

The local x64 verification currently also depends on an uncommitted
`desktop_webview_auth` package-cache patch that replaces ATL `CW2A` conversion
with `WideCharToMultiByte` and frees the WebView2 source buffer with
`CoTaskMemFree`. Move that change to a reviewable plugin fork and pin its
revision before claiming clean-machine reproducibility.

## Change and review workflow

1. Start from a clean branch based on the intended upstream branch.
2. Make one narrow change per branch where practical.
3. Add or update a focused test for message parsing, routing, or state changes.
4. Run the focused test and the relevant Flutter analyzer/build locally.
5. Describe the user-visible behavior, failure mode, and test evidence in the PR.
6. Keep performance claims tied to a reproducible device, build mode, and test
   scenario.

Changes that affect both the Android client and ValidationRelay should be
reviewed as a coordinated pair. The Android client must tolerate relay
disconnects and malformed responses; the relay must not log or persist secrets.

## Safe diagnostics

Enable the app's Developer Mode only for a controlled reproduction. Capture a
short window around one send or receive operation, then redact or remove the
capture before sharing it publicly. See [`DIAGNOSTICS.md`](DIAGNOSTICS.md) for
the collection checklist and known failure classes.

Never include registration codes, registration secrets, Apple IDs, phone
numbers, message text, attachment URLs, auth tokens, or full device identifiers
in an issue or pull request. A short-lived hash or local incident ID is enough
to correlate events.

## Memory and media lifecycle

See [`MEMORY_MANAGEMENT.md`](MEMORY_MANAGEMENT.md) for cache budgets, media
ownership, physical-device measurement, acceptance thresholds, known
limitations, and rollback guidance.

## Known limitations

- Android background execution, Doze, OEM battery policies, and network path
  changes can delay relay delivery even when the app code is healthy.
- CloudKit/Apple plist payloads can contain types that are not present in every
  historical message. Decoding must fail closed and preserve the rest of the
  sync rather than crashing the UI.
- Notifications can arrive with incomplete contact/group metadata. UI and
  notification code must use a generic avatar fallback instead of throwing.
- Reaction events may race message persistence. A missing target should be
  retried or ignored with bounded logging, not trigger an unbounded lookup loop.
- A green WebSocket connection only proves transport connectivity. It does not
  prove that registration, validation, or message persistence succeeded.

These are test boundaries, not promises of feature support. Record the exact
device, Android version, build variant, relay, and network when reporting a
failure.
