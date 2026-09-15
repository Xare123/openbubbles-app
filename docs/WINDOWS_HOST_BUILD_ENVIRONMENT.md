---
type: build_runbook
title: OpenBubbles Windows ARM64 Host Build Environment
description: Verified toolchain layout and the non-obvious constraints for building the Rust bridge and running the test suites for Android, Windows ARM64, and Windows x64 from one Windows-on-ARM host.
resource: openbubbles-app
tags: [windows, arm64, x64, android, rust, objectbox, openssl, toolchain, testing]
timestamp: 2026-09-13
---

# OpenBubbles Windows ARM64 host build environment

## Fastest current Dart loop, September 13

September 14 update: `run_imported_cloud_sync_v2_dart_live.ps1` now separates
the current Dart source from the qualified native source. It permits reuse only
when the native source is an ancestor and the committed native/FRB/ObjectBox/
pubspec boundary is byte-unchanged. Host receipts are checked against the native
source; reports remain bound to current Dart. Its 17 PowerShell contract tests
pass, and the real compatibility check accepted Dart `ea7560b83` over native
`9712487af`. Session `2c544457b08a06406aabcfa8fc5cb10a` then completed two
stable ordinary read-only passes in about 103 seconds total. Each retained
94 Chats, 5,046 Messages and 1,112 Attachments, observed all zones terminal,
kept outbox 21 -> 21, disabled remote writes, removed raw output and confirmed
owned-process cleanup. This is the preferred loop when only Dart/test code has
changed; any native-boundary change still requires a rebuilt and reverified host.

Current handoff: Windows native-only run 34782347926 is qualified
for source `4e7121a18`. Its separate signed directory is
`C:\Codex\OpenBubblesReview\artifacts\windows-native-34782347926\signed`;
DLL SHA256 `80f97298fad435f53b30cd4dc2b0479e3f350fb47136e644673b3a052d08b3c8`.
All 51 packaged-DLL codec tests passed locally with App Control enabled, and
the actual loaded module path was verified. The original GUI/runtime was not
replaced. Archive, unsigned/signed lineage and source-EOL comparison evidence
are in the adjacent `local-qualification.json` and `provenance.json`.

That DLL includes the logger-handle repair, `extensionMetadataJson` contract and
v2 session context, multipart replies and direct-data archive fields. It passed
153 selected native tests and 658 Dart tests. Five sampled raw-JPEG icons now
decode; replay/sweep added 14 extension-message rows and one attachment record,
with separate display metadata instead of treating placeholder base text as prose.
The earlier e5547e8c7 drain restored 284 distinct messages (278 replies) and
applied 11 attachment records. Shared-contract extraction and raw-icon routing
are in this DLL. Attachment-date repair 4e7121a18 is now also live-qualified:
eight exact failures became ready, and a normal replay applied 86 attachments.
Copied-source tests verify the eight samples' canonical parent links and
production download-source resolution. No file-byte or Pixel display claim.
The Chat1 discovery bindings are now matched to source
`c6091ddf92e13c902fc61bd911606def5ac373a7`. Windows 34789713162 produced the
separately signed DLL at
`C:\Codex\OpenBubblesReview\artifacts\windows-native-34789713162\signed`, SHA256
`9B0B7899BBD31D1EE6C6A15482208055C8C9FED52CF858761CDACD622A0C0C79`.
Full GCE Canary 34789714678 passed its actual suites and regenerated all seven
bindings byte-for-byte. A mutex-held Windows test-host read then fetched one
bounded 50-row Chat1 page without canonical/outbox mutation; a cache-only repeat
confirmed 50 distinct protected raw saves without a network call. The rows remain
unsupported/quarantined. Do not substitute the older 4e7121a18 DLL or enable
auxiliary semantic decode.

The next exact pair, source `97f63b5f5d8e4d89aa5b0a6deefb85060999f9e7`,
passed Windows 34797113685 and full GCE Canary 34797113773. Its separately signed
ARM64 DLL SHA256 is
`5B22D174FC50A680DDCE0A64CECD3018F4E551C387B9237600426E84A94E5B12`.
A mutex-held cache-only correlation verified all eight target route hashes and all
50 Chat1 records, performed no network read, exposed no content and left durable
state unchanged. It found zero exact record-name matches, closing only that
hypothesis.

Exact source `19022ea7bf6d4ea1fe32a60c1b5797eeccc15491` then passed
Windows 34801034688 and full GCE Canary 34801034710. Its schema-2 native bundle
was independently verified and the copied Rust DLL separately signed; signed
SHA256 is `7D768E4686E62BF21E595C8BAD796A7F3EFE49454A9F42B1F6484A2FDBE886B6`.
The live mutex-held diagnostic made one PCS lookup, decoded all 50 first-page
`chatEncryptedv2` records and all four bounded routing fields, and found zero
direct or semantic matches without content exposure or durable mutation. This
does not cover records beyond that capped page.

Exact source and generated bindings
`a951e1251c658e81e9ef6533e5b3e8874b28bae7` passed Windows 34804132572 and
full GCE Canary 34804133857 through pilot
`629df1f5d70b2c63c51212b362b05d569df2c3d4`. The independently verified copied
ARM64 DLL was separately signed, SHA256
`9220F65671F4DBF385BF065C47D35139904DA9FA6BC3A748697BF7A3801832AA`.
A mutex-held live walk reached the current Chat1 terminal state in four pages /
167 changes: 165 valid records, two tombstones, no decode failures and zero raw
route-field matches for all eight targets. Durable state and content exposure
remained unchanged. Do not repeat raw paging or infer remote absence.

Exact normalized source `a2f72eff9edce5cc377ca62c472e5f8bc3aa5c4d`
passed full GCE 34807869942 and Windows fast-loop 34807865131. Its live retry
reached terminal state over four pages / 167 changes and found zero normalized
`cid`, `gid`, `ogid` or `guid` matches, without decode failures, content exposure
or durable mutation. That exact signed/runtime lineage does not cover the next
source.

Exact source `cb5e81410f135f969fc15cffee957ad79ab63abd` passed Windows
ARM64 fast loop 34843955881. Its read-only engineering archive SHA256 is
`DCEFCAE4A829914D5715C6324F21489DBE53EFE7605B3C57E1A2C2C2E7B8B88B` and was
imported into the clean detached `chat1-live-a93671` checkout only after source,
manifest, architecture, ObjectBox and signature checks. Live launch
`61909185c0e0f5736b8e5c44569236bf` reached terminal Chat1 state in four pages /
167 changes, with 165 Chat records and two tombstones. It exposed no content,
left durable state unchanged and cleaned up all four owned processes. All 165
route-field failures reduced to 18 encrypted empty `lah` values and 147 omitted
outer `ptcpts` false flags. The next runtime must contain the narrow diagnostic
compatibility repair and be rebuilt, reimported and reverified before another
live call. Do not reuse the `cb5e81410` DLL after that source change.
The Find My launcher remains pinned
to its separately qualified 3496034e3 runtime until deliberately updated.

For explicit chained Windows requests, optional `previousMutationFromRequestId`
in version 6 must identify the completed previous edit and retain the original
`existingChatFromRequestId`. Its immutable request/claim, exact reflected history,
confirmed operation, pending-free map and current owner/auth are checked before
claim and send. Old v6 bindings/pristine selection are unchanged. Each later
mutation gets a new request ID; completed-request restart reconciles only.
Private request snapshots remain in the test profile, never source or CI.

Parent-31 -> edits-32/33 -> unsend-34 passed with qualified 16112ec69 native code
and separately tested current Dart (115 local tests). Exact echo used 008a342c5663.
This does not establish recipient UI behavior or Apple's mutation timing limits.
An initial IDS 6005 was rejected before a claim; explicit same-identity sender
refresh worked. Do not silently repeat registration on every failed send.
Active next qualification and resume action are tracked in the treemap.

For full GCE runs, read the final selected-suite gate or its new actual-outcomes
artifact, not a green continue-on-error step. Run 34775818423 failed Dart vocabulary
and protector-harness compilation even though their step conclusions appeared
successful. No APK was signed. The candidate fixes share the real metadata schema
with the dependency-light protector harness and enforce its lockfile. Cargo
metadata validation is not compilation/test proof. Full run 34779666716 then
passed all actual outcomes, including protector, and signed its Canary. For
app-rust-only qualification set outbound_writer=false and automatic_uploads=false;
those are APK-only flags requiring full qualification, not switches to enable
native test coverage. Misconfigured run 34782349481 was rejected before creation.

Read-only retained inspection now accepts OPENBUBBLES_INSPECT_RETAINED_OFFSET
(canonical decimal 0-4096, default 0), validated before native/profile startup.
Each category/zone is still capped at eight records. Fixed date-shape and
failure-source classifications never print date values, message content or
arbitrary stacks. Different offsets are samples, not prevalence estimates.

Use the existing `drain` operation after an empty-stream read when the goal is a
complete retained-work sweep, not repeated 150-row restarts. Latest run took
5m5s and finished below the test host's six-minute cap. Do not treat a timeout as
successful completion. The controller's remote-drained status and its final
local-sweep report are different evidence: local sweep zones do not perform
remote reads. Preserve both reports and classify remaining work explicitly.
`test/live/cloud_sync_projection_delta_test.dart` audits bounded new-row counts
only on verified before/after copies via OPENBUBBLES_PROJECTION_DELTA_COPIES;
it neither proves full visual legibility nor touches the live profile.
Set OPENBUBBLES_PROJECTION_VALIDATE_ICONS=1 only for a bounded copied-data
audit: it decodes at most 32 stored extension icons with Flutter, capped at
1 MiB encoded image bytes and 1024-pixel dimensions, without output images or
network. All 14 newly restored icons decoded successfully. This does not prove
full InteractiveHolder behavior, provider support, or Pixel display.
Earlier source `ea757e188` proved an ordinary text send/edit and exact readback.
Bridge run 34761004976 generated the matching bindings; its synthetic test fixture
error was corrected before successful Windows qualification.

Use the cloud workflow for binding changes: local generation invokes Cargo
expansion and a full native dependency build. The local attempt stopped on
missing clang. Import the seven generated artifact files together, verify both
FRB normalization guards, and qualify the coherent source in the Windows lane.
Pilot `02fc8e810` adds extension, converter, DTO, digest, system-event and Dart
projector/decoder tests using the same native test executable.

After qualification, verify test cases and hashes, stage/sign separately, rerun
the packaged-DLL codec cases, then inspect retained records with the new DLL.
Do not silently substitute a new native library under the old GUI receipt.
The Find My test host separately pins its allowed DLL hash/source files; update
those only after review of the newly qualified artifact, not merely to bypass
a rejected import. Current live roster/selected results and invocation are in
[the Find My guide](FINDMY_ASTRA_20260910.md).

Use `test/live/cloud_sync_v2_windows_live_harness_test.dart` before rebuilding a
Windows bundle when native code and generated interfaces are unchanged. It runs
the real retained dev profile with the current Dart source and an explicitly
selected, hash-verified native DLL. The source comparison for `bc9cbab79` against
the qualified native base `7f2569165` found only six added blank lines in generated
Rust; this exception must not authorize functional native changes.

Required process environment: `OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS=1`,
`OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST=1`,
`OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_HARNESS=1`, a fresh 32-hex
`OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID`, and the verified
`OPENBUBBLES_TEST_NATIVE_LIBRARY` path. Select `view-projection` or `run-once`
with `OPENBUBBLES_LIVE_HARNESS_OPERATION`. Compile the existing Windows dev,
semantic-pull and sampler gates and a truthful source identifier. Native writer
flags are unnecessary for these two read operations. Hold the existing profile
launcher mutex and keep other Windows app/test processes out of that profile.

Prepend the qualified runtime folder to PATH for the test process so ObjectBox
5.3.2 ARM64 is found. The initial missing-path attempt failed with error 126 before
the account operation. After correcting PATH, local projection startup passed in
8.65 seconds without a native rebuild. A live read then failed authentication
refresh. The opt-in `OPENBUBBLES_DIAGNOSE_READ_AUTH=1` probe identified
`relay_offline` through a normal quota read without outputting quota values,
tokens or response bodies. This does not prove a successful CloudKit read.

Evidence: `C:\Codex\OpenBubblesReview\build-evidence\windows-live-testhost-20260912\result.json`.
The native refresh wrapper currently collapses this condition to a generic code;
the pending precise relay-unavailable mapping needs native qualification before use.

The diagnosis was a stale saved pairing, not an outage of the user's current relay.
After matching host, token and physical-device version/serial/identity fields, only
the Windows relay code was rotated, with an exact backup. Per-install UUID/UDID,
keys and certificates were preserved. The next read passed authentication in the
same short loop and returned two changes. Its first report contained an edit-history
conflict, despite the live test reporting a completed operation. The harness now
checks the report's semantic acceptance predicate before reporting success.

That preserved conflict compares equal in text/format but differs by one millisecond
in one edit. A frozen ObjectBox copy plus the actual native decoder and ordinary
transactional applier demonstrated the precision fix: applied inbox state, unchanged
local history, original quarantine untouched. No production requeue was simulated
on the real profile during that first proof.

September 13: the cause-specific production retry subsequently passed on a fresh
copy and then through ordinary live `run-once`: two pending messages applied,
all three zones observed an empty terminal read, no remaining conflict, outbox
15 -> 15. Report `obcs2-semantic-1789278811033254.json` still records retained
projection debt; this is not a complete-history claim. A rollback copy was made
under the profile mutex before the live run. Evidence is in
`C:\Codex\OpenBubblesReview\build-evidence\windows-edit-precision-recovery-20260913`.

Two real-copy counterexamples refined recovery: a write readback envelope cannot
be decoded using change-feed metadata, and an empty native own sender does not
require prior local handle ID zero. Recovery validates the fetched source,
complete directional precision echo, finalized local operation/map provenance,
no semantic replay, first-page barrier and lease. It never consumes mapped raw
bytes, writes remotely or advances a cursor; ordinary application does that local
commit. The new native writer arithmetic is not exercised by the retained DLL.

## Decision

Drive all three architecture targets from one Windows-on-ARM host. Nothing here
changes shipped code; it records the host constraints that otherwise present as
unrelated failures (60+ Dart test errors, a missing proc-macro crate, an
OpenSSL Makefile that never appears).

Every item below was verified on this host on 2026-08-06. Where a constraint is
a host-policy interaction rather than a repository problem, that is stated.

## Toolchain layout

| Component | Path | Notes |
| --- | --- | --- |
| Flutter ARM64 | `C:\Codex\Toolchains\flutter-3.44.8-arm64` | Native host; Dart 3.12.2 |
| Flutter x64 | `C:\Codex\Toolchains\flutter-3.44.8` | Runs emulated |
| Cargo/rustup | `C:\Codex\Toolchains\cargo`, `C:\Codex\Toolchains\rustup` | Set `CARGO_HOME` and `RUSTUP_HOME` |
| MSVC | Visual Studio Build Tools 2022 17.14, MSVC 14.44.35207 | `Hostarm64` tools present |
| clang | `C:\Codex\Toolchains\LLVM-22.1.8-woa64-portable\bin` | Required by `ring`; see below |
| Android SDK/NDK | `C:\Codex\Toolchains\AndroidSdk`, NDK `26.1.10909125` | Host prebuilt is `windows-x86_64` |
| GNU make | `C:\Codex\Toolchains\android-build-bin\make.exe` | Needs Strawberry's mingw runtime DLLs on PATH |
| Perl modules | `C:\Codex\Toolchains\git-perl-extra` | Point `PERL5LIB` here |
| ObjectBox ARM64 | `C:\Codex\Toolchains\objectbox-windows-arm64-v5.3.2\lib` | Matches the pinned 5.3.2 |

Installed Rust targets: `aarch64-pc-windows-msvc`, `x86_64-pc-windows-msvc`,
`aarch64-linux-android`.

## Constraint: the Dart test host needs an architecture- and version-matched ObjectBox

`pubspec.yaml` pins the `objectbox` trio to 5.3.2. The Dart test host loads
`objectbox.dll` from `PATH`, so that library must match both the pinned version
and the architecture of the Flutter SDK's own `dart.exe`.

A stale 4.0.2 `objectbox.dll` still sits in this repository's
`build\windows\x64\runner\Release`. Selecting it fails 63 Cloud Sync tests with
`LateInitializationError: Local 'objectBox' has not been initialized`, which
names neither the version nor the library. `tooling\cloud_sync\verify_foundation.ps1`
now derives the host architecture from `dart.exe`, reads the pinned version from
`pubspec.yaml`, inspects each candidate library's PE machine type and embedded
version banner, and refuses to run on a mismatch.

Verified libraries:

- ARM64 host: `C:\Codex\Toolchains\objectbox-windows-arm64-v5.3.2\lib`
- x64 host: `..\cloudsync_objectbox5_sandbox\build\windows\x64\runner\Release`

## Constraint: `ring` needs clang for the ARM64 MSVC target

`ring` 0.17.8 assembles GNU-syntax `.S` sources for
`aarch64-pc-windows-msvc`. `cl.exe` cannot consume them, so `clang` must be
reachable or the build fails with `failed to find tool "clang"`. Put the
portable LLVM `bin` directory after the MSVC directories so `cl`, `link`, and
`lib` still resolve to Visual Studio.

Remove `CC`, `CXX`, `AR`, `LD`, `RANLIB`, `CFLAGS`, and `CXXFLAGS` before
building an MSVC target. The `cc` crate honours them ahead of `cl.exe`, and a
stale GNU value either fails compiler detection or produces the wrong machine
type. Drop Strawberry's `c\bin` from `PATH` for the same reason, but keep
`C:\Strawberry\perl\bin` because the OpenSSL build needs perl.

## Constraint: `ring` 0.16.20 cannot target ARM64 and was reachable only through a dead dependency

`icloud_auth` declared `rustls = "0.20.7"` and `rustls-pemfile = "1.0.1"` while
using neither; its `reqwest` uses `default-tls`, and `rustpush` itself uses
rustls 0.23.38. Those two unused declarations pulled `rustls` 0.20.9 and with it
`ring` 0.16.20, which predates ARM64 Windows support and fails in `build.rs`.

Removing them drops `ring` 0.16.20, `rustls` 0.20.9, `spin` 0.5.2,
`untrusted` 0.7.1, and `webpki` 0.22.4 and changes no other resolved package.
This edit lands in the `rustpush` submodule.

## Constraint: vendored OpenSSL for Android needs a Unix-path perl, GNU make, and forward-slash compiler paths

`openssl` is a vendored dependency, so the Android build compiles OpenSSL from
source. Three separate host requirements follow, each of which fails with a
different and unrelated-looking message:

1. **Configure needs Unix-style paths.** Strawberry's MSWin32 perl reports
   `This perl implementation doesn't produce Unix like paths` and no Makefile
   appears. Git's msys perl (`C:\Program Files\Git\usr\bin\perl.exe`) must win
   the `perl` lookup.
2. **Configure needs modules Git's minimal perl omits.** Point `PERL5LIB` at
   `C:\Codex\Toolchains\git-perl-extra`. `tooling\android\build_verified_alpha.ps1`
   converts that to a `//localhost/C$/...` UNC path first, because OpenSSL runs
   perl through a POSIX shell where the drive-letter colon would otherwise be
   read as a `PERL5LIB` separator.
3. **The generated Makefile routes `CC` through msys `sh`, which eats
   backslashes.** A Windows-style compiler path arrives as
   `C:CodexToolchains...clang.exe: command not found`. Set
   `CC_aarch64_linux_android`, `AR_aarch64_linux_android`, and
   `RANLIB_aarch64_linux_android` with forward slashes. Configure already
   supplies `--target=aarch64-linux-android24`, so plain `clang.exe` is
   correct; the `.cmd` wrapper is still right for the Cargo linker.

`make` must also be on `PATH`, and `android-build-bin\make.exe` links
`libintl-8.dll` from Strawberry's `c\bin`. Removing Strawberry entirely to force
msys perl makes `make` fail with `0xc0000135` (DLL not found). Order `PATH` so
Git's `usr\bin` precedes Strawberry rather than removing Strawberry.

## Host policy: Smart App Control can block new native binaries

**September 7, 2026 update:** the reaction-integrated Windows harness built at
`454a2c08e` cannot load `rust_lib_bluebubbles.dll` (error 4551). This DLL has a
valid local Authenticode signature from `OpenBubbles ARM64 Development`, but
Code Integrity event 3077 identifies the enforcing
`VerifiedAndReputableDesktop` policy blocking it. The failure occurs during
native initialization, before opening the database or Apple session.
The older successful native tests and release builds below are historical
results, not a guarantee that every subsequent binary will be accepted.

Microsoft's [signing guidance](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control)
states that Smart App Control considers certificates from trusted providers.
Local signature verification alone does not satisfy that trust requirement.
Keep Smart App Control enabled. A trusted signed artifact or separately approved
test host is needed for this blocked launch; do not change policy, credentials
or registration in response to this loader failure. See the connection treemap
for the preserved build, status and Code Integrity evidence.

### Earlier native-test observations

This host runs Smart App Control in enforcement mode
(`HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy` →
`VerifiedAndReputablePolicyState = 1`). It intermittently blocks freshly built,
unsigned binaries with `An Application Control policy has blocked this file.
(os error 4551)`.

This affects `cargo test` on `rust_lib_bluebubbles`, which builds
dev-dependencies and their proc-macro DLLs. A blocked proc-macro surfaces as the
misleading `error[E0463]: can't find crate for 'rinja_derive'` even though that
crate compiles and its DLL exists. Retrying gets different binaries through, so
the failure moves rather than clearing.

What this does and does not block:

- **Not affected:** `cargo build --release`, which needs no dev-dependencies.
  All three release libraries build cleanly.
- **Not affected:** the standalone `cloud_sync_protector_harness`, whose 39
  tests run on ARM64.
- **Affected:** `cargo test` on the main crate.

Keep Smart App Control unchanged for this project. Microsoft's current
[FAQ](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions)
says recent Windows updates support re-enabling it without reinstalling,
subject to device eligibility; the older universal reinstall claim is obsolete.
That does not create a per-app exception or authorize a protection change.
Run the main crate's Rust tests on an approved isolated build host. This is
the open item that the live-validation
document records as "run the x64 harness without triggering Windows Application
Control".

**September 10 recheck:** the retained ARM64 DLL loads, and the signed compiler
wrapper starts, but actual native test compilation is blocked at a generated
`slab` build-script executable with error 4551 despite valid Authenticode.
There is no current guarantee that release builds or individual helpers avoid
the policy. See the treemap for the approved isolated cloud build path. Windows
Dart tests can use the existing x64 ObjectBox 5.3.2 directory on their process
PATH; six database-backed manual-selection tests passed with that configuration.

## Defect: CargoKit silently skipped the entire Rust build on Flutter 3.44.8

`rust_builder/cargokit/gradle/plugin.gradle` located Flutter's Gradle plugin by
comparing the fully qualified class name to `"FlutterPlugin"`. That matched while
Flutter's plugin was Groovy in the default package. Flutter 3.44.8 ships the
Kotlin rewrite as `com.flutter.gradle.FlutterPlugin`, so the comparison failed
and CargoKit printed `Flutter plugin not found, CargoKit plugin will not be
applied.` and returned.

The consequence is silent and serious: the Android build completes and reports
success while packaging no `librust_lib_bluebubbles.so` at all. A split ARM64
profile APK built before the fix contained `libflutter.so` and `libapp.so` but
no Rust bridge; `tooling\android\build_verified_alpha.ps1` is what caught it.
Its ABI assertion is the only thing standing between this failure mode and a
package that installs and then cannot work.

The fix accepts either the bare class name or any package-qualified
`.FlutterPlugin`. After it, the skip message no longer appears under
`flutter build`. Note that invoking a CargoKit Gradle task directly, rather than
through `flutter build`, legitimately prints the same message because the
Flutter plugin is not applied in that invocation; that is not a regression and
is not a valid way to test this.

`build_verified_alpha.ps1` also required `lib/arm64-v8a/libapp.so` for every
mode even though a debug package carries interpreted Dart in its asset bundle
instead. It now requires that entry only for profile and release.

### Host limit: memory, not correctness

Re-verifying a packaged APK after the CargoKit fix did not complete on this
host. With the fix in place Gradle additionally drives the Android cargo build,
including compiling OpenSSL from source in CargoKit's own target directory. This
machine has 15.6 GB of RAM, `android/gradle.properties` requests
`-Xmx6400M`, and with a browser and editor resident the daemon settles at
roughly 2.6 GB while free memory falls to about 1.4 GB. It then burns CPU
without writing build output, which is memory thrash rather than progress.

Before rerunning, free memory first and stop stale daemons
(`android\gradlew.bat --stop`), or lower `org.gradle.jvmargs`, or build on a
larger machine or CI runner:

```powershell
pwsh -NoProfile -File .\tooling\android\build_verified_alpha.ps1 -Mode profile -SplitPerAbi `
  -AndroidSdkRoot C:\Codex\Toolchains\AndroidSdk `
  -CargoHome C:\Codex\Toolchains\cargo -RustupHome C:\Codex\Toolchains\rustup `
  -ProtocPath C:\Codex\Toolchains\protoc-35.1-win64\bin\protoc.exe `
  -PerlExecutable "C:\Program Files\Git\usr\bin\perl.exe" `
  -PerlModuleRoot C:\Codex\Toolchains\git-perl-extra `
  -MakeExecutable C:\Codex\Toolchains\android-build-bin\make.exe
```

## Verified state on 2026-08-06

| Check | Result |
| --- | --- |
| Dart suite, ARM64 host | 388 tests pass |
| Cloud Sync Dart suite, x64 host | 294 tests pass |
| Cloud Sync focused analyzer | clean |
| `cloud_sync_protector_harness`, ARM64 | 39 tests pass |
| Kotlin unit tests, Alpha variant | 12 tests pass |
| `cargo check --locked --all-targets`, ARM64 | clean |
| Release library, `aarch64-pc-windows-msvc` | PE ARM64 |
| Release library, `x86_64-pc-windows-msvc` | PE x64 |
| Release library, `aarch64-linux-android` | ELF64 AArch64 |
| `cargo test`, main crate | blocked by host policy above |

No live CloudKit access, account mutation, or message send was performed.

## Deliberate gate: the Windows desktop build needs an ANGLE bundle built from source

`flutter build windows` fails at CMake configure on this host:

```text
Cannot find path '...\media_kit_libs_windows_video\windows\native\arm64\angle'
because it does not exist.
```

This is the repo-local `media_kit_libs_windows_video` fork failing closed on
purpose. Its README states that both architectures fail closed unless an ANGLE
bundle built from pinned official Google ANGLE source is present and passes its
manifest, SHA-256, PE-machine, provenance, and license-inventory checks, and
that the package never accepts the unlicensed third-party ARM64 ANGLE bundle.

`..\scratch\arm64-media-provenance` holds bare `angle-x64.7z`,
`libmpv-arm64.7z`, and `libmpv-x64.7z` with no manifest, license inventory, or
attestation beside them. **Do not stage those to satisfy the gate.** Produce a
bundle instead:

```powershell
pwsh -NoProfile -File .\packages\media_kit_libs_windows_video\tool\build_official_angle.ps1 -Architecture arm64 -WorkRoot C:\Codex\OpenBubblesReview\build-cache\official-angle-arm64 -OutputRoot .\packages\media_kit_libs_windows_video\windows\native\arm64\angle
```

That fetches pinned depot_tools and ANGLE source and runs a Chromium-scale
build, so treat it as a maintainer or CI step. Note also that
`provenance/native-dependencies.json` records libmpv redistribution as
`blocked_pending_transitive_license_inventory`, so this gate is not the only
thing standing between the current tree and a public Windows release.

This gate is unrelated to Cloud Sync. The CloudKit-relevant Windows artifact,
the Rust bridge, builds and verifies for both architectures.

## Isolated engineering build (September 10)

The isolated pilot branch now has `windows-cloudkit-fast-loop.yml`, backed by
`tooling/windows-cloudkit-build/build_and_smoke.ps1`. It uses GitHub's native
`windows-11-arm` host, a previously successful Rust build platform for this
fork. No GCE Windows bootstrap, Apple profile upload, PC security change, or
production signing is required. Linux-only GCE tests remain a separate lane.

The job builds the minimal CloudKit Flutter harness, not the full native-media
application. `local-write` is an explicit compile variant with automatic-send
runtime disabled. Build identity is derived with the existing launcher before
generated files change the checkout. The source SHA, variant, binary hashes,
and unsigned engineering status are recorded; public redistribution is not
qualified by this job.

Runtime proof requires the full native encoder suite against the packaged
DLL: 48 cases on current source `6c628feb6`. An invalid-launch GUI diagnostic
only qualifies startup if its exact Dart marker is captured. DLL load or any
nonzero exit alone is not that proof. Artifact logs/archives expire in three
days, and the Windows VM lifetime is bounded by its 90-minute job.

Verified successful build: [run 34491135220](https://github.com/Xare123/openbubbles-app/actions/runs/34491135220),
pilot `a2680baac`, source `6c628feb6`. Job time was 23m27s, including 15m43.7s
Flutter compilation. The 29 focused Dart tests, both PowerShell contracts,
48 native-DLL codec cases, ARM64 PE checks, and actual invalid-launch Dart
marker all passed. This is engineering qualification, not a live sync result.
The previous run `34489497490` passed 27 focused Dart cases but failed two
database-backed cases with missing `objectbox.dll` (loader error 126), before
native compilation. Supply the pinned ObjectBox 5.3.2 Windows ARM64 release
archive on the runner's PATH before `flutter test`, not just during CMake.
The pilot checks its SHA256 and PE ARM64 architecture, without global install
or application changes. The replacement run completed those missing checks.
Import into the retained local profile still requires hash/identity verification,
local signing if required, and matching launch receipts. No identity or message
database should be overwritten by an engineering-bundle update.

### Preserve the ObjectBox vendor bytes

The imported bundle's 78 files matched the cloud manifest. Local re-signing of
`objectbox.dll` then caused App Control 4551 before the real database opened.
Both the old and newly self-signed copies were blocked. The verified,
unmodified ObjectBox 5.3.2 ARM64 DLL loaded under the same unchanged policy.
Replacing only that DLL in the qualified runtime allowed the retained profile
to open and an existing-request resume to finish. No trust or security setting
was changed. This counterexample is specific to these bytes and this host;
it does not establish that every unsigned binary will be accepted.

- Required vendor DLL SHA256: `9c8583c4015ab9e4ce2ed3d2d581811fa059e03bb528cb8c8387adcdfda8d8a5`.
- `Get-HarnessSignableArtifacts` excludes `objectbox.dll`; the launcher checks
  its exact version-bound hash before fresh builds or reuse. Review this pin
  when the dependency version changes. Never strip or replace signatures to
  satisfy this check; recover the original verified release artifact.
- Qualified checkout: `C:\Codex\OpenBubblesReview\worktrees\windows-cloudkit-qualified`.
- Provenance, original archive, rejected DLL and old receipt remain under
  `C:\Codex\OpenBubblesReview\build-evidence\windows-fast-loop-34491135220`.

The first fresh send test reached recipient lookup but failed with IDS `6005`.
It never created a claim or sent a message. That is an account-registration
boundary, not another loader failure or evidence of a CloudKit write failure.

## Exact Chat1 compatibility harness (September 14)

[Windows ARM64 run 34849043947](https://github.com/Xare123/openbubbles-app/actions/runs/34849043947)
qualified source `908ccc0040ed4bb60d2611db945e0b304eff639c` with pilot
`629df1f5d70b2c63c51212b362b05d569df2c3d4` in 23m57s. The read-only harness
passed 666 Dart tests, 51 packaged native codec cases, launcher contracts,
invalid-launch handling and ARM64 checks. Artifact 10351037466 was downloaded
and independently hash-checked; archive and sidecar SHA256 are both
`6647710ec763084e741541a7cfd9f6a2a272d1395bc7afcf698280a0f96498d6`.

The bounded importer verified 78 files and 335,772,787 bytes before placing the
bundle into the clean detached runtime at
`C:\Codex\OpenBubblesReview\worktrees\chat1-live-a93671`. Its receipt under the
private Windows profile binds the installed app and Rust DLL to the exact source
and pilot. Both local signatures are valid; the pinned ObjectBox DLL remains the
unmodified accepted vendor binary.

Live launch `dd0cf181df5b3751342e8a2f78dc07ad` completed an account-bound,
read-only Chat1 walk: four pages, 167 changes, 165 decoded Chat records, two
tombstones, terminal state and zero record/route-field failures. No content was
retained by the launcher and durable state was unchanged. The run found 76
normalized sender-to-participant pairs spanning three sender targets and 31 Chat
records. This is a real relationship signal but is too ambiguous for admission.
The Windows loop should now test complete participant-set/style/service/time
candidate cardinality before any Android build. It does not replace Pixel
lifecycle or independent-client qualification.

## Not covered here

Android release signing needs a keystore and `android/key.properties`, neither
of which is present. The `alpha`, `beta`, and `prod` flavours use
`signingConfigs.release`, so only debug-signed packages can be produced on this
host.
