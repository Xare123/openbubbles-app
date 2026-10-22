---
type: build_runbook
title: OpenBubbles Windows ARM64 fast loop
description: Exact-source native test-host qualification and bounded production Dart/ObjectBox reads without a new APK or full Windows media build.
resource: openbubbles-app
tags: [windows, arm64, cloudkit, rust, objectbox, testing]
timestamp: 2026-10-22
---

# Windows ARM64 fast-loop runbook

Owner: OpenBubbles CloudKit parent task. Use after a relevant source change,
not as a reason to repeat passing suites. Last verified October22,2026.

Read [the runtime checkpoint](CLOUDKIT_RUNTIME_CHECKPOINT_20261021.md) first.
It owns current handles, account readiness and next action. Older chronology
is preserved byte-exact in [the historical guide](cloud_sync_v2/history/WINDOWS_HOST_BUILD_ENVIRONMENT_PRE_CURRENT_HOST_20261022.md).

## Purpose and scope

Use the production Dart/ObjectBox reader with a matching native Windows library
to investigate CloudKit records efficiently. Native-test-host mode does not
build the full Windows GUI, media graph or an APK. It does not establish Android
lifecycle, real attachment playback, independent-recipient visibility or release
readiness. Those remain separate [release gates](CLOUD_SYNC_V2_CONNECTION_TREEMAP.md).

Prefer source/JVM/Windows work where equivalent. Personal Pixel availability and
personal-app shutdown are not prerequisites. Shared iPhone-relay use still needs
one authenticated test client; preserve all account and app data.

## Verified baseline, not an instruction to rerun it

| Item | Actual verified value |
| --- | --- |
| Windows native and Dart application source | 300fdc0c0a82d26b41f0079432ed3f70a4ee5f69 |
| Windows build sidecar | 306c6e09baa295eb51fa0cc571b7df0ca306ba86 |
| Later tooling-only source | 8185f2d3013398114bf0128f4667d66652e99ab2 |
| Successful Windows run / artifact | 39797787352 / 12434599541 |
| Mode / variant | native-test-host / read-only |
| Inner ZIP SHA256 | fe62b739330b57bd319aa56d37fff92a7427d613699a527d9bb0270b0ff3d906 |
| Provenance SHA256 | e195d30caf26dccea5e2296fc24407d2dc1c1981d05dd38af5521ff4b8c60d32 |
| Locally signed native DLL SHA256 | 9dae80e3239ebcbb709873268a58fdee890f0fcaf00e9a735d4393a3716a913c |
| Unmodified ObjectBox5.3.2 ARM64 DLL SHA256 | 9c8583c4015ab9e4ce2ed3d2d581811fa059e03bb528cb8c8387adcdfda8d8a5 |

Actual CI:773 focused Dart,51 packaged-DLL codec,101 converter,35 extension,
24 DTO,7 compose,7 diagnostic,2 discovery,2 repair-digest and5 system-event
tests passed, plus both PowerShell contract scripts. These are selected scopes,
not the full1013-case native executable. All four new parent-detail tests ran.
Local signed-host6 parent-filtered native tests and51 actual-DLL codec tests
passed.55 source inputs and13 evidence-log hashes matched independently.

No GUI startup, live Apple request or fresh Android qualification occurred in
this Windows run. The last live Android candidate remains b9bb977/APK3c238819.
Canonical private evidence:
C:/Codex/OpenBubblesReview/worktrees/cloudkit-v2-update-seam-live-bbfa/build-evidence/message-parent-diagnostics-20261022.
That checkout owns tooling/evidence, but its APP source is old; do not build it.

## Prerequisites

- Inspect current source, dirty work, recursive pins, active jobs and disk space.
  Preserve unrelated edits. Do not reset, clean or blindly reuse an old host.
- GitHub CLI: C:/Program Files/GitHub CLI/gh.exe. Repository:
  Xare123/openbubbles-app. Source publication is not upstream release approval.
- Flutter: C:/Codex/Toolchains/flutter-3.44.8-arm64/bin/flutter.bat.
  Dart is under bin/cache/dart-sdk/bin/dart.exe. Use artifact provenance for
  actual Rust/MSVC/tool versions, not an older stable-version assumption.
- Before local ObjectBox tests, prepend
  C:/Codex/Toolchains/objectbox-windows-arm64-v5.3.2/lib to this process's PATH.
- Use the fixed isolated profile under APPDATA/OpenBubbles/cloudkit-v2-dev,
  with its exact marker and supported profile-scoped mutex. Never point the
  reader at Alpha, Canary, an arbitrary folder or the ordinary Store profile.
- Back up critical isolated-profile state before native/model upgrades.
  Keep keys, account files and message databases private. ZIP hash/inventory
  does not prove every entry was independently hash-compared.

## Procedure

### 1. Decide whether a native build is necessary

For Dart/test/tooling-only work, reuse a qualified native host only when its
source is an ancestor and the committed native boundary is byte-unchanged.
The existing run_imported_cloud_sync_v2_dart_live.ps1 guard checks rust,
rustpush, rust_builder, generated bindings, ObjectBox model/code, FRB config and
pubspec/lock. Do not disable its compatibility or API checks.

Any changed native boundary needs one newly matched host. Do not hot reload
new bindings against an old DLL. Do not rebuild Android for a protocol change
that the native test host can qualify first.

### 2. Freeze and publish the intended inputs

Use reviewed immutable commits. Publish changed nested pins first, then the
parent. Preserve unrelated staged/dirty work. Use normal fast-forward and
[skip ci] for source-only commits; inspect actual automatic workflow events.

The Windows workflow is on agent/gce-runner-pilot at
.github/workflows/windows-cloudkit-fast-loop.yml, with
tooling/windows-cloudkit-build/build_and_smoke.ps1. Review its current remote
SHA before dispatch. Its fixed trusted source branch is
agent/cloudkit-v2-received-origin-20260916. source_ref must equal that branch's
current full40-character head; do not change trust policy to bypass a mismatch.

Check active/queued runs first. Adopt a run already covering the source.
Baseline request39797787352 is consumed and completed; never replay it.

### 3. Dispatch once when justified

For a NEW reviewed source and reviewed pilot only:

~~~powershell
$gh = 'C:/Program Files/GitHub CLI/gh.exe'
$source = '<reviewed-full-40-character-source-SHA>'
if ($source -cnotmatch '^[0-9a-f]{40}$') { throw 'Select exact source first.' }
$dispatch = @('workflow','run','windows-cloudkit-fast-loop.yml',
  '-R','Xare123/openbubbles-app','--ref','agent/gce-runner-pilot',
  '-f',"source_ref=$source",'-f','artifact_mode=native-test-host',
  '-f','build_variant=read-only')
& $gh @dispatch
~~~

Capture the actual run ID. The GitHub-hosted Windows ARM64 job has an existing
90-minute limit and no persistent GCE VM. An uncertain CLI response is not
permission to dispatch again. Monitor the same handle and inspect actual step
results. A skipped register-only or GUI check is not a passed test.

The current sidecar pins seven native diagnostic cases and the new converter
spot names. Verify actual named tests in logs; function counts and a green
workflow label alone are insufficient.

### 4. Download and verify the exact artifact

Download the selected artifact once into a new task evidence directory.
Preserve partial output on failure. Verify inner ZIP checksum, provenance,
exact source/pilot/variant, three-file inventory, ARM64 PE machines, test names,
log hashes, source-input hashes and recursive pins.

~~~powershell
$verify = @{
  ArchivePath=$archive; ProvenancePath=$provenance
  ExpectedArchiveSha256=$archiveHash; ExpectedSourceSha=$source
  ExpectedPilotSha=$pilot; ExpectedVariant='read-only'
  ExpectedArtifactMode='native-test-host'
  ExpectedNativeDiagnosticTestCount=7
}
& ./tooling/windows/verify_windows_cloud_bundle.ps1 @verify
~~~

Seven is this baseline's reviewed count, not a number to raise blindly. Check
provenance's actual test selections for a future sidecar revision.

### 5. Import without replacing user data

Use a clean source checkout matching the artifact. A small separate runtime
checkout is appropriate when MAIN contains protected unrelated changes.
Pinned telephony_plus plus offline Dart pub get with FLUTTER_ROOT set resolved
Dart dependencies without changing tracked files. Do not copy credentials into
source or claim uninitialized submodules were verified.

The importer verifies, signs only the two engineering binaries with the
approved local certificate, preserves ObjectBox vendor bytes and installs a
source-bound receipt. Preserve the previous four-file host separately if its
original rollback artifact is not otherwise available.

~~~powershell
$import = @{
  ArchivePath=$archive; ProvenancePath=$provenance
  ExpectedArchiveSha256=$archiveHash; ExpectedSourceSha=$source
  ExpectedPilotSha=$pilot; ExpectedNativeDiagnosticTestCount=7
  ExpectedSignerThumbprint='8240557965890665F3B49E5FEC83D511CA4F2C9D'
  Repository=$cleanSourceCheckout
}
& ./tooling/windows/import_verified_windows_native_test_host.ps1 @import
~~~

Verify receipt hashes, actual Authenticode and vendor ObjectBox bytes afterward.
No OS security policy change is part of this procedure. Do not sign ObjectBox,
install unverified DLLs or disable Windows protections to make a test pass.

The process guard exempts only the OS-verified, healthy Store-signed
OpenBubbles.OpenBubbles_qrjz7esdc5g9p release at its exact WindowsApps executable.
Unknown apps and engineering hosts remain blocking. It never stops a process
and does not replace profile/file locks. Do not add a blanket Store/Pixel
shutdown prerequisite.

### 6. Separate local loading from live CloudKit acceptance

Use the actual imported DLL for one narrow local loader/codec qualification,
not the mock bridge. The encoder test takes OPENBUBBLES_TEST_NATIVE_LIBRARY;
it needs no account or profile initialization. Keep native logging bounded.

For a user-authorized live read, use run_imported_cloud_sync_v2_dart_live.ps1.
It requires EnableLive, the explicit live/personal-data acknowledgment flags,
exact source/native/pilot/archive/provenance pins and a clean product tree.
Default to one bounded ordinary pass. Use Drain only for a concrete remaining
history case, preserving existing pass/deadline limits. No writer flags,
archival acknowledgment, queue processing or IDS send is implied.

Qualification records include the sourced profile/process-guard hashes as
well as the main launcher and test hashes. Preserve the returned session ID,
private evidence path, actual counters and owned-process cleanup result.

## Troubleshooting and rollback

| Observation | Required response |
| --- | --- |
| Trusted source changed or native-boundary mismatch | Stop the mismatched launch. Inspect ancestry/content and obtain a matched artifact. |
| ObjectBox loader126 | Check exact vendor runtime and process PATH. Do not substitute an arbitrary DLL. |
| App Control4551 or denied launch | Preserve the real error. Use supported controls; do not weaken security or route around a denied action. |
| Unknown profile owner | Inspect actual ownership and retain the mutex. The verified unrelated Store exception is deliberately narrow. |
| Relay ticket404 or old native_auth_v1=false | Check current legitimate input/capability before login. Do not manually relabel identity, set flags, reset history or blindly retry passwords. |
| New code for the same physical iPhone | Existing config_from_relay/reuse_native_relay_setup performs normal capability and exact-device/key/token checks. Preserve its failure behavior; never silently fall back to fresh activation. |
| Automatic USB input denied | Do not try another execution route for that operation. Ask for current input while continuing permitted work. |
| Retained dependencies/malformed records | Preserve and diagnose them. A parent can release a dependency, not repair rejected grammar. |
| Counters increase or one zone reaches head | Report events and per-zone facts. Neither proves downloaded media or complete history. |

Finish or stop only owned test processes using supported cleanup. Never stop
the ordinary Store app or other chats' work. Restore a prior host/profile only
from exact verified rollback material after checking that newer messages,
unknown submissions and keys will not be overwritten. Do not reset to green.

Keep private account backups, credentials and raw records out of source/public
logs. New outbound tests remain limited to the two approved peers. Ask for
genuinely missing current relay/2FA input, never an old code or a guess.

## Related lanes and history

- [Runtime and next action](CLOUDKIT_RUNTIME_CHECKPOINT_20261021.md).
- [Production gates and architecture](CLOUD_SYNC_V2_CONNECTION_TREEMAP.md).
- [Established GCE/Android qualification](GCE_SOURCE_ONLY_WORKFLOW.md).
- [Full Windows media/provenance work](WINDOWS_ARM64_NATIVE_MEDIA.md), separate
  from this minimal CloudKit loop.
- [Preserved chronology and older toolchain detail](cloud_sync_v2/history/WINDOWS_HOST_BUILD_ENVIRONMENT_PRE_CURRENT_HOST_20261022.md).
