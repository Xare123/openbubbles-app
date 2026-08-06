# Delivery, routing, and performance verification

Use this plan when comparing an app change against a known-good Alpha build.
It separates transport, persistence, rendering, and Android background work so
that a faster WebSocket does not hide a database or notification regression.

## Reproducible build gate

The repository CI workflow (`.github/workflows/build.yml`) currently uses:

```text
Flutter 3.24.0 (stable)
Rust stable
Java 21 (Temurin)
Android SDK and protoc
```

Run the same commands locally from the repository root:

```bash
flutter pub get
flutter test --no-pub
flutter analyze --no-pub <changed Dart paths>
```

The repository still contains analyzer noise in vendored and example sources,
so review the changed Dart paths directly and require zero analyzer errors
there. Existing warnings or deprecations should be listed rather than hidden.

On Windows, use the verified Android wrapper so a stale or incomplete APK
cannot be mistaken for a successful build:

```powershell
.\tooling\android\build_verified_alpha.ps1 -Mode profile
.\tooling\android\build_verified_alpha.ps1 -Mode debug
.\tooling\android\build_verified_alpha.ps1 -Mode profile -SplitPerAbi
```

The wrapper removes the prior target artifact before building and verifies
that the APK contains nonempty ARM64 `libflutter.so`, `libapp.so`, and
`librust_lib_bluebubbles.so` entries. `-SplitPerAbi` additionally rejects any
native library outside `lib/arm64-v8a/`; use it for a Pixel-specific sideload
instead of carrying unused ARMv7 and x86 libraries. `-Mode release` is
supported only when `android/key.properties` supplies the release signing
configuration. The Android CI job also runs:

```bash
cd android
./gradlew :app:testAlphaDebugUnitTest :app:compileAlphaDebugKotlin
```

Do not call a build verified when tests failed, the native-library inspection
was skipped, or the machine used a different Flutter or Java major version.

### Environment evidence from the Windows review host

On 2026-07-31 this host verified the changed surfaces with Flutter 3.24.0,
Java 21, the local Android SDK, and Rust-backed APK packaging. Record the exact
test count, artifact byte size, SHA-256, and required native-library entries in
the review handoff. Device installation and live delivery behavior remain
separate gates.

### Pixel profile installation record

The ARM64-only Alpha profile artifact installed as an in-place update on the
Pixel test device. The installation retained the application package and data;
no uninstall or data clear was used.

```text
version name: 1.15.0
version code: 20004227
artifact bytes: 194,911,911
SHA-256: 518E6F0ADD5811170B13F57E222B7021060BE032A0EC5BC74C9B0F2428407539
lib/arm64-v8a/libflutter.so: 15,402,480 bytes
lib/arm64-v8a/libapp.so: 39,388,064 bytes
lib/arm64-v8a/librust_lib_bluebubbles.so: 36,620,096 bytes
```

The post-install inspection found no native library outside `arm64-v8a`.
ObjectBox files, app-managed files, and existing logs remained present. The
app started without a native-library load failure or fatal startup exception.
That proves packaging, upgrade preservation, and startup only. It does not
replace foreground/background delivery, locked-phone endurance, battery, or
the explicit fullscreen-video gesture check.

### Windows x64 release record

The same source state produced a Windows x64 Release bundle on the ARM64
review host. The portable bundle was isolated from the build tree before
signing and contains:

```text
files: 167
bundle bytes: 170,009,166
PE files: 99
PE machine type: 0x8664 (x64), 99 of 99
Authenticode status: Valid, 99 of 99
portable archive bytes: 66,633,911
portable archive SHA-256:
00253D214A45F4AC78DD68A4AB2B73C6FC3719008AE6819796F50ABB894A84E4
```

Static import inspection found no unresolved redistributable DLL. The eight
names not present as physical files are Windows API-set contracts. The bundle
includes the target-specific `WebView2Loader.dll`, the Rust library, ObjectBox,
Flutter, and media playback libraries. Debug-only C/C++ runtime DLLs were
excluded.

All 152 Flutter tests passed with the x64 bundle on `PATH`. The changed Pixel
logging, fullscreen-video, and Cloud Sync surfaces also passed focused
analysis with no issue, and the generated-Rust guard reported zero duplicate
SSE implementation groups.

The bundle is signed for local testing with a certificate trusted only in the
current user's certificate stores. That signature is not a public publisher
identity and should not be used for distribution.

One clean-build dependency remains before an upstream Windows submission is
fully reproducible: `desktop_webview_auth` currently requires a small
Windows patch that removes its unnecessary ATL dependency, converts the
WebView URL with `WideCharToMultiByte`, and releases the COM-allocated source
buffer. The verified host used that patch in its package cache. Publish it in
a dedicated plugin fork or upstream plugin change, then pin the reviewed
revision in `pubspec.yaml`; do not present the application repository alone as
a clean-machine reproduction until that is done.

### Windows ARM64 boundary

The Windows ARM64 port has source parity for the transport, Cloud Sync,
diagnostic, fullscreen-media, and UI fixes. Its Flutter tests pass, focused
analysis has no errors, and a WSL ARM64 Rust check succeeds. A native Windows
ARM64 Release artifact is not yet validated because this host's Code Integrity
policy blocks an unsigned Rust proc-macro DLL during compilation. The locked
`media_kit_libs_windows_video` 1.0.11 package still selects an x86_64 libmpv
archive and an x64 ANGLE bundle. ObjectBox 5.3.2 publishes a Windows ARM64
binary, and `printing` 5.15.0 derives its PDFium architecture from the Flutter
target and uses a release that publishes `pdfium-win-arm64`. Those two
dependencies are no longer known static blockers, but neither has been
validated inside a complete native ARM64 app bundle. WSL proves source
compatibility only; it does not produce a Windows executable. Keep the ARM64
package experimental until the native build, PE architecture audit, dependency
audit, signing, launch, media playback, and sync tests all pass.

## Functional delivery matrix

Run each scenario once on the baseline and at least three times on the changed
build. Use a unique local test ID, not message text, in the timing sheet.

| Scenario | Expected result | Evidence |
| --- | --- | --- |
| iMessage receive, app foreground | One database row and one UI message | relay receive, save, UI timestamps |
| iMessage receive, app background | One notification and one database row | notification ID plus save timestamp |
| Duplicate relay event | One logical message, no duplicate notification | stable server/message ID count |
| Reconnect during receive | Event is retried or recovered, no loss | disconnect, reconnect, save, acknowledgement order |
| Updated message/reaction before base message | Event is eventually applied or boundedly deferred | target ID, retry count, final row |
| Malformed/partial payload | Event rejected safely; process remains alive | redacted error and subsequent message success |
| SMS/MMS/RCS routing | Delivered only by Google Messages in the control test | default-app state and notification source |

For the SMS/RCS control, keep Google Messages as the default SMS app and turn
off OpenBubbles forwarding. Test the forwarding path separately; do not use two
active paths to judge loss or duplication.

## Timing and correctness metrics

Instrument or correlate a redacted event ID at these boundaries:

1. relay/WebSocket receive
2. payload parse/validation
3. incoming queue start
4. database save/upsert complete
5. acknowledgement sent
6. UI listener refresh
7. notification scheduled

Report median and p95 milliseconds for each segment, plus counts of duplicate
IDs, missing IDs, parse failures, notification failures, and reconnects. The
minimum acceptance gate for a delivery fix is zero lost IDs and zero duplicate
IDs in the controlled run. Latency improvements are secondary to correctness.

## On-device performance capture

Use a profile APK for frame and CPU comparisons, and keep the same device,
Android version, screen refresh rate, chat history, network, and test script.
Replace the package name if using another flavor.

```bash
adb shell am force-stop com.bluebubbles.messaging.alpha
adb shell monkey -p com.bluebubbles.messaging.alpha 1
adb shell dumpsys gfxinfo com.bluebubbles.messaging.alpha reset
# Perform one 60-second scroll/open/send/receive script.
adb shell dumpsys gfxinfo com.bluebubbles.messaging.alpha framestats > gfxinfo.txt
adb shell dumpsys meminfo com.bluebubbles.messaging.alpha > meminfo.txt
adb shell dumpsys cpuinfo > cpuinfo.txt
```

Record total frames, missed frames, 90th/95th/99th percentile frame time, peak
RSS, and CPU share. A smoother UI should reduce long frames without trading
away receive or database work.

For battery and background behavior, use a fresh controlled window:

```bash
adb shell dumpsys batterystats --reset
# Leave the same build idle for 30 minutes, then exercise five receives.
adb shell dumpsys batterystats --charged > batterystats.txt
adb shell dumpsys netstats detail > netstats.txt
```

Compare baseline and changed builds under the same network. Look specifically
for reconnect loops, repeated refresh timers, foreground services that never
stop, and notification retry storms.

## Failure triage

- A WebSocket connect without a database save is a receive failure, not a pass.
- An acknowledgement before persistence is a possible loss window after a
  process restart; capture the ordering explicitly.
- Repeated null-avatar or render exceptions can make the app feel slow even if
  transport latency is normal.
- Reaction lookups that miss their target should be bounded and observable, not
  an unbounded retry loop.
- CloudKit plist decoding failures should isolate the malformed item and allow
  later messages to continue.
- Registration/anisette failures should back off; a tight retry loop is both a
  battery and delivery risk.

Attach only redacted logs and a small timing table to a review. Never include
message text, phone numbers, Apple credentials, relay secrets, auth tokens, or
full device identifiers.
