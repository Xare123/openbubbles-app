# Canary ADB Control (removable, debug-only)

Headless parent-agent control for the Android Canary over plain ADB: open the
Developer Tools / Cloud Sync V2 page, query route and readiness, and run the
bounded read-only semantic catch-up. No screenshots, no coordinate taps, no
VM-service port forwarding, no Dart SDK on the host.

## Architecture

Host (PowerShell, plain adb) --explicit broadcast--> on-device receiver
--MethodChannel--> Dart dispatcher --result--> private prefs + logcat.

1. tooling/canary_adb_control.ps1 launches the Canary activity explicitly
   (required: background activity starts from a receiver are blocked on
   modern Android), sends one explicit broadcast to the receiver component,
   and polls the content-free result.
2. android/app/src/canaryDebug/.../CanaryAdbControlReceiver.kt (canaryDebug
   ONLY) validates the action against a 7-item allowlist and forwards to
   Dart. Immediate ack via setResultData (visible as data="..." in am
   broadcast output). Its own startActivity call is best-effort only.
3. lib/services/rustpush/cloud_sync/cloud_sync_canary_adb_control.dart
   executes the command: navigation via the existing NavigatorService,
   readiness via existing pushService gates, and the semantic catch-up via a
   dedicated read-only entry point (see gates below). Results are counts,
   booleans, route names, and safe codes only.
4. Two hook lines in
   lib/services/backend/java_dart_interop/method_channel_service.dart
   (marked CANARY_ADB_HOOK): one case in the existing native-call switch, one
   pending-action drain on init for cold start.

## Compile and runtime gates

- Dart: --dart-define=OPENBUBBLES_CANARY_ADB_CONTROL=true (default false).
- Dart runtime: kDebugMode must be true (false in profile and release, even
  if the flag leaks).
- Native: receiver class and manifest entry exist only in the canaryDebug
  variant (src/canaryDebug). Alpha, Beta, prod, and canaryRelease APKs
  physically lack them. The receiver is exported=true with
  android:permission="android.permission.DUMP": exported=true is mandatory
  because the shell UID cannot deliver even an explicit broadcast to an
  exported=false component on modern Android (this app targets SDK 36), and
  the DUMP permission (signature|privileged, pre-granted to the adb shell
  UID, unobtainable by third-party apps) is what keeps it shell-only.
- Origin check: Dart requires originPackage ==
  com.bluebubbles.messaging.cloudkitcanary.
- Semantic start additionally requires
  pushService.cloudSyncV2ManualSemanticPullAvailable (canary package,
  Developer Mode, setup done, legacy sync off, no logout, no in-flight pull,
  supported ABI) and an explicit two-step confirm. It calls the dedicated
  runCloudSyncV2AutomaticSemanticCatchUpReadOnly entry point, which shares
  the confirmed flow's guards, bounded sessions, interlock, and in-flight
  exclusion but never wakes the ordinary-send worker, so no CloudKit upload
  can be caused from this path. (The Confirmed entry point resumes automatic
  uploads on completion and is never referenced by this channel.) Local
  canonical projection of fetched records is unchanged from the UI flow;
  CloudKit saves/deletes stay disabled by the sampler's own flags.

## Actions

ping, status, query_route, open_developer_settings, open_cloud_sync_v2,
semantic_pull_status, semantic_pull_start (needs -Confirm on the second call).

Action contracts: open_developer_settings and open_cloud_sync_v2 both land on
the Developer Tools (Troubleshoot) page, which hosts the Cloud Sync V2
section, and both report developer_mode so the host can tell whether the
section is rendered. No per-section visibility logic lives in this channel.

Outbound/write canary entry points are never referenced. No deletes, no
message sends, no credential or key access, no network listener. The only
mutable state: navigation stack, a pending-action string, last-nav marker,
and the last-result JSON in private prefs.

## Build and run

flutter run --flavor canary --debug --dart-define=OPENBUBBLES_CANARY_ADB_CONTROL=true --dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true

Then from this repo worktree:

./tooling/canary_adb_control.ps1 -Action status
./tooling/canary_adb_control.ps1 -Action open-sync
./tooling/canary_adb_control.ps1 -Action semantic-start
./tooling/canary_adb_control.ps1 -Action semantic-start -Confirm

## Kill switch and removal path

1. Immediate: rebuild/install without the dart-define (defaults off; the Dart
   handler records adb_control_disabled and does nothing).
2. Full removal (7 items): delete
   lib/services/rustpush/cloud_sync/cloud_sync_canary_adb_control.dart,
   test/services/cloud_sync/canary_adb_control_test.dart,
   tooling/canary_adb_control.ps1, docs/CANARY_ADB_CONTROL.md,
   the android/app/src/canaryDebug tree, the two CANARY_ADB_HOOK lines in
   method_channel_service.dart, and the CANARY_ADB_HOOK read-only entry point
   in rustpush_service.dart. No other file is touched.

## Security boundaries (mapped to requirements)

- Canary/debug only: canaryDebug source set + dart-define + kDebugMode.
- Impossible in Alpha/release: class and manifest entry absent outside
  canaryDebug; verified by grepping the main manifest and listing the
  canaryRelease APK receivers on qualification.
- No message content or identifiers in responses: result envelope restricted
  to num/bool/short safe-charset strings; unit test rejects identifier-like
  keys and free-form values.
- No deletion, no send, no credentials: dispatcher references none of the
  outbound, delete, keychain, or socket APIs (grep-checked in verification).
- No remote listener: no sockets/ports; entry is a receiver with no
  intent-filter, reachable only by explicit on-device broadcast (ADB/shell).
- Localhost/ADB only: the receiver requires android.permission.DUMP, held by
  the shell UID and unobtainable by third-party apps, which get a
  SecurityException. Verified by manifest assertion test, not by assumption:
  exported=true plus the DUMP permission are both asserted in
  canary_adb_control_test.dart.
- Semantic pull only when safe: same availability gate as the UI button plus
  sampler fail-closed preflight/interlock; first call only reports
  preconditions (adb_confirmation_required). The executed entry point never
  wakes the ordinary-send worker, so the documented no-upload claim is
  structural, not behavioral.

## Comparison: why this instead of VM trigger or uiautomator

- Existing tooling/vm_trigger_semantic.dart already drives the semantic pull
  and --status through the Dart VM service. It needs a debug build with the
  observatory exposed, adb port forwarding, the ws URI, and the Dart
  vm_service packages on the host. It also evaluates broad expressions rather
  than an allowlist, and it cannot navigate the UI.
- Uiautomator/coordinate taps work on any build but are slow, resolution and
  timing dependent, and break on layout changes.
- This channel works on any canaryDebug install with plain adb, is
  deterministic, allowlisted to 7 safe actions, and script-friendly.
- Honest limit: it IS an app change (4 new files, a 5-line channel hook, and
  one additive read-only service entry point), so it must
  be removed before any upstream PR. If the team prefers zero app changes,
  stay with vm_trigger_semantic --status plus uiautomator taps for
  navigation; this channel is strictly better only while a local canaryDebug
  qualification loop is active.

## Verification

Performed in worktree worktrees/canary-adb-control at 7a0aa1706:

- New-file tests: test/services/cloud_sync/canary_adb_control_test.dart
  (allowlist exactness, parse rejection, origin refusal, result scanner,
  default-off gate). Run: flutter test test/services/cloud_sync/canary_adb_control_test.dart
- PowerShell parse check of tooling/canary_adb_control.ps1 (Parser API, zero
  errors).
- Grep checks: CanaryAdb absent from the main manifest; dispatcher contains
  no outq/socket/delete/send/keychain/credential symbols; only
  method_channel_service.dart modified (2 hook hunks).
- Manifest checks: canaryDebug overlay asserts exported=true, DUMP
  permission, and the receiver name; main manifest asserts no CanaryAdb
  trace (both in canary_adb_control_test.dart).
- Parent worktree openbubbles-app untouched (git status compared before and
  after; work done only in worktrees/canary-adb-control).

Still required on the build machine (no Flutter/Android SDK on this host):
flutter test, flutter analyze of the new files, and a canaryDebug +
canaryRelease assemble to prove the receiver merges only into canaryDebug
(check with aapt dump xmltree / package receivers), plus one live-device
pass of each host action. The first successful status round-trip on a
canaryDebug install is the live proof that shell delivery through the
DUMP-permissioned receiver works; if it is ever refused, stop and re-open
the mechanism question rather than widening the permission.

Do not push, do not create a PR, do not touch upstream. Delete this whole
feature (see removal path) before announcing or opening the upstream PR.
