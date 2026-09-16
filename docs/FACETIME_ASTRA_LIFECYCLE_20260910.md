---
type: Investigation
title: FaceTime explicit-leave lifecycle repair
description: Current FaceTime runtime boundary and preserved historical explicit-leave repair evidence.
tags: [facetime, android, lifecycle, regression]
timestamp: 2026-09-15
---

# Current result (September 15)

The explicit-leave and viewer-layout repairs are already in current main:
`2c259fe0b`, `509aa1d34` and its import correction `9241d447e`. Main also has
the exact-call timeout/cache guards. Do not apply the older isolated branch or
port those fixes again. Successful two-way media remains unproved.

The Windows app launches an external browser. Its policy/JVM/Node harnesses do
not run Android's FaceTimeActivity, WebView permissions, injected getStats loop
or native diagnostics writer. Their passing results cannot close that live gate.
The retained older call observation reached the securing-media UI but did not
prove advancing remote media; no fresh native trace is available.

Next approved Android call: enable both developer mode and FaceTime diagnostics
before setup, retain the two bounded `logs/facetime-native` generations plus
WebView/build versions, and distinguish missing inbound reports, stalled bytes
and changing peer identity. Do not infer remote hangup from an inactive snapshot.
CloudKit's current engine-lifecycle candidate is tracked in the
[connection treemap](CLOUD_SYNC_V2_CONNECTION_TREEMAP.md), not here.

# Historical isolated candidate (September 12)

Candidate only, not integrated, installed, or proven to fix the reported call.
Base app `6c1a1c6e4b01b71b516e9df87a1cc3aef57cf0dd`; rustpush remains unpopulated
and unchanged at the parent-specified gitlink. All changes are confined to
`C:\Codex\OpenBubblesReview\worktrees\facetime-astra-20260910`.

The base rewrites **every** `this.onLeave.notifyListeners()` into a native leave
callback, whose Activity handler unconditionally closes the call screen. It does
not establish that the user pressed Leave. The original regression produced
one native close from one synthetic internal notification, with no button tap.

Historical `facetime-avconference-integration` commit `21f256168` already
separated explicit taps from generic notifications. The `facetime-sidecar`
runbook and `e775bb672` lifecycle change reinforce intent/owner isolation.
The handshake worktree's `0ec1f2ff8` is a Rust protocol integration, not proof
that its changes or a successful live call exist in this app base. These sources
were read only; no historical branch was bulk-merged.

## Patch behavior

- Prepend an idempotent explicit-Leave listener before Apple's main script.
  Join/Rejoin, disabled controls, and unsolicited/duplicate lifecycle notifiers
  cannot request native teardown. Apple still receives its original events.
- A Leave tap requests native ending, then waits for the web notifier to confirm
  closure. The existing 1.5-second native fallback remains available only after
  explicit End/Leave. A JavaScript click result no longer shortens it to 500 ms.
  No additional calls, rings, network retries, or signaling requests are added.
- Disposed web documents and native callback policies ignore late confirmations.
  Activity ownership guards protect a newer call from an old callback/fallback.
- Remote-hangup automatic close remains **unresolved**. Parent rejected the
  all-inactive native snapshot predicate from the first candidate; the corrective
  commit removes its sender, unused receiver/method and diagnostic state. No
  participant snapshot or media loss now authorizes additional teardown.
- Retain the existing collision-safe End footer, permissions and same-peer media
  admission checks. Explicit Leave/native End retain their bounded fallback.

## Material parent review rejection

Do not integrate `9cfd45dee` alone. Apply its corrective follow-up too. Against
exact rustpush `fdced92b7ff94dbb923cd48a5b711605b044218f`, `src/facetime.rs`:

- Lines 308-323, `unpack_participants`: clears every active entry before applying
  the received snapshot and excludes local-token participants from repopulation.
- Lines 1564-1572, `unprop_conv`: explicitly clears the local participant's active
  state during handoff. Lines 2272-2290 trigger unprop when the temporary browser
  participant joins a propped session.
- Lines 2382-2433: command 208 is a participant LeaveEvent, guarded by that
  participant's `last_join_date`; it is not an authoritative whole-session-ended
  event. All-inactive updates ringing/missed state, but does not prove irreversible
  session termination or rule out partial/out-of-order snapshots.

The former all-inactive predicate could close a call during state churn. Its
unit/source tests established implementation behavior, not correct native terminal
semantics. Parent explicitly rejected that behavior, and no live evidence cures
the uncertainty. The safe subset retains explicit user-controlled exits only.

## Exact changed paths

Relative to the exclusive worktree:

```text
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeCallStateHandler.kt
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeDiagnosticLog.kt
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeEndPolicy.kt
android/app/src/test/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeEndPolicyTest.kt
lib/services/rustpush/rustpush_service.dart
test/services/facetime/run_face_time_host_tests.ps1
tooling/facetime/analyze_native_trace.mjs
tooling/facetime/analyze_native_trace.test.mjs
tooling/facetime/web_leave_bridge.test.mjs
docs/FACETIME_ASTRA_LIFECYCLE_20260910.md
```

After the corrective commit, the speculative FaceTime LeaveEvent additions are gone.
No CloudKit, Find My, login, generated bridge, identity, dependency, or profile
changes. No pushes, CI dispatches, new agents, native Cargo/full builds, or
account/device access. No user-data deletions. The initial test build artifact was the ignored
84,404-byte `build/facetime-host-tests/tests.jar`; dependencies are reused in place.
C: free space at review was 57.08 GiB, above the size-audit threshold.

## Verification

From this worktree:

```powershell
node --test tooling/facetime/web_leave_bridge.test.mjs tooling/facetime/web_rtc_diagnostic_bootstrap.test.mjs tooling/facetime/analyze_native_trace.test.mjs test/services/facetime/face_time_media_probe_test.cjs
.\test\services\facetime\run_face_time_host_tests.ps1
```

- Initial candidate JS/source suites: **64 passed**, exit 0. Execute the production embedded bridge
  and notifier transform. Include duplicate notifications, delayed confirmation,
  nested controls, disabled controls, reinstallation and document teardown.
- Initial candidate cached Kotlin compiler/JUnit: **65 passed**, exit 0. Execute native end-policy
  request/confirmation/disposal, queued-callback rejection, ID matching and
  existing media/timeout/diagnostic policies. This does not compile Android Activity.
- `git diff --check`: passed. Dart `format --output=none` parsed the changed service
  without writing it, exit 0; emitted a missing `package:lints/recommended.yaml`
  resolution warning. This is **not** Flutter analysis or a clean full build.

Corrective follow-up: 63 JS/source tests and 64 Kotlin/JUnit tests passed. The
obsolete native-terminal positive tests were removed/replaced with a regression
against speculative teardown. Exact initial-path list above is historical; the
corrective Git diff records the removals.

Parent must schedule Android Kotlin compilation on its approved GCE/CI workflow
before integration/device installation. The FaceTime Flutter suite subsequently
passed locally in the timer follow-up described below.
Do not dispatch from this worktree or bundle into the current Windows CloudKit run.

## Real-data limit and smallest remaining live gate

Read the parent's existing `device-evidence/pixel-write-20260909-3dc614c9e/`
`facetime-login-observation-20260910.md`. It records successful admission response,
local preview and no preserved native media-stage span identifying the close.
No raw private captures were copied and no new trace was obtained. **This patch
does not establish why the wife's phone failed to ring, why media was absent, or
which event ended that specific call.** Mock peers are not end-to-end evidence.

After parent approval/build, capture one consented outgoing call from before its
start until ten seconds after remote hangup, then one manual subsequent call and
explicit web Leave. Verify remote ringing, answer persistence, bidirectional audio
and video, behavior after remote hangup, repeat-call availability and End/Leave spacing.
Native End fallback still needs a separate controlled check if not exercised.

Smallest trace: both bounded `logs/facetime-native/facetime-native*.log` generations
from that candidate, covering created, admission, resolved same-peer samples
(ICE, audio/video track counts and advancing inbound bytes), leave request,
close reason and destruction. To investigate remote termination retain content-free
native LeaveEvent correlation and participant active/total counts, plus app commit
and WebView version. No URLs, SDP, handles, credentials, media or account DBs.
The parent coordinates collection; the leased Windows profile is irrelevant.

## Separate outgoing timer ownership repair, 2026-09-11

In `placeOutgoingCall`, correlation is published before awaiting createFacetime,
but the 30-second timer is installed afterward without checking that the same call
is still pending. An immediate JoinEvent can accept the call and cancel no timer;
creation then returns and arms a timer that cancels the accepted session. Its
callback and asynchronous cleanup also mutate shared `currentOutgoingCall` and
metadata without checking ownership, potentially clearing a subsequent call.
This is now repaired in a separate identity-scoped Dart commit. Its occurrence in
the reported live call is still not established.

The production-used `FaceTimeOutgoingLifecycle` owns one ticket per outgoing call:
immutable ID, its reactive status object, launch metadata and timer. Installation
requires a still-pending owner; terminal actions claim and cancel before awaiting;
queued callbacks recheck ownership; finally releases only the identical ticket.
Creation failure, JoinEvent, decline, timeout and explicit End use that seam.
Existing accepted/declined/timeout strings, 30-second deadline, signaling calls
and explicit manual retry remain. Late failure cannot mark an accepted call failed.
Incoming admission cleanup after launch is also guarded against replacing a newer
ticket. Duplicate pending setup is ignored rather than orphaning its invitation;
a manual retry can start while terminal cleanup is in flight. No blind retries.

The first two deterministic seam tests retained the old ordering and failed:
early acceptance yielded cancellation count 1 instead of 0, and old finally
changed the new current ticket to null. After repair, ten tests execute the same
production-used seam with Completers and manually fired timers, including queued
cancelled callbacks, failed launch/cancel cleanup, duplicate terminal events,
duplicate setup, same-ID/different-object ownership and idempotent installation.
This is local async regression evidence, not real-device signaling evidence.

Exact paths changed by the timer commit, relative to this exclusive worktree:

```text
lib/services/rustpush/face_time_outgoing_lifecycle.dart
lib/services/rustpush/rustpush_service.dart
lib/helpers/ui/facetime_helpers.dart
test/services/facetime/face_time_outgoing_lifecycle_test.dart
test/services/facetime/face_time_outgoing_start_test.dart
docs/FACETIME_ASTRA_LIFECYCLE_20260910.md
```

Final validation command (the existing Flutter installation was invoked through
its cached flutter_tools snapshot, with no pub or test-asset build):

```powershell
flutter test --no-pub --no-test-assets --reporter expanded test/services/facetime/face_time_outgoing_start_test.dart test/services/facetime/face_time_incoming_admission_test.dart test/services/facetime/face_time_diagnostics_contract_test.dart test/services/facetime/face_time_log_export_test.dart test/services/facetime/face_time_outgoing_lifecycle_test.dart
```

Result: **41 passed**, including ten deterministic ownership tests and existing
incoming-admission, outgoing-start, native-contract and synthetic-log export
tests. Application sources compile through these targeted Flutter tests. The
Android Activity itself and real WebView/account flows are not compiled/executed
by them. Analyzer: zero errors, two preexisting unused-import warnings in the
helper and 14 info diagnostics, exit 1. The newly unused logger import was removed;
unrelated warnings were left intact. Scoped diff whitespace check passed.

Only local package-resolution metadata was materialized in this worktree; its
bluebubbles root points here. Dependencies remain in their existing locations;
no dependency/cache trees were copied or downloaded. Generated test output is
about 190 MiB, mostly Dart kernel/test cache. Native-assets manifest is 45 bytes
with an empty asset map, not a native build. C: had 56.09 GiB free at verification.

Cherry-pick order: initial `9cfd45dee`, mandatory review correction `4bd672cdc`,
then the separate outgoing ownership commit. Never install the first commit alone.
Live answer/media/end/repeat-call gates above are unchanged. Remote-hangup
automatic close remains unresolved and is deliberately not inferred from a
participant snapshot.

## September 11 viewer layout follow-up

This later candidate is in `cloudkit-decoder-diagnostic`, not the exclusive
historical worktree above. It changes presentation only. A measured vertical
layout separates the wrapping native status, weighted WebView and bottom End
dock. System-bar, cutout and keyboard insets belong to the root; PiP releases
the native controls and padding. No estimated footer offsets remain in the
Activity. The black canvas, system type, charcoal dock and red 56dp-minimum End
button follow the requested iOS style, with pressed and disabled feedback.

Parent rejected a duplicate native caller-name header. Apple's name, self-preview,
participant count and Leave control remain unchanged. The native End is a separate
fallback, not a replacement for all Apple controls. Signaling, admission, permissions,
explicit-user exit authority and the existing teardown fallback are unchanged.

Parent verification: 70 cached Kotlin/JUnit tests, nine Dart source-contract tests
and 63 production-script/source regressions passed. The source-contract assignment
counter initially also matched `==`; a negative lookahead now counts assignments
only. Astra additionally compiled the four new/changed XML resources. These checks
do not compile the Activity or prove real portrait, landscape, large-font or PiP
rendering. Android compilation and actual rendering remain release gates. No call,
APK installation or account action was performed for this layout change.

## September 11 bounded inbound LeaveEvent diagnostic follow-up

Scope: `C:\Codex\OpenBubblesReview\worktrees\cloudkit-decoder-diagnostic`.
The layout (`509aa1d34`) and native-only export (`b701e36a7`) review status was
provided by the parent. This sidecar ran no Git commands and did not reverify
commit/branch identity. No Android/device qualification is claimed.

The gap exists. In current `rustpush/src/facetime.rs`, command 208 checks
`last_join_date`, clears the participant's active state, possibly removes a
temporary participant, updates ringing/missed state, and emits `FTMessage::LeaveEvent`.
Its existing generic log lines do not describe that transition. The emitted
event exposes only guid, participant and handle, with no protocol reason field.
The Dart handler refreshes the session lists and applies its existing ringing
overlay/missed-call handling without emitting a bounded native leave trace.
Neither that event nor an all-inactive snapshot proves whole-session termination.

The diagnostic-only change adds `stage=remote_leave` with three finite states:
`received`, `refreshed`, and `refresh_failed`. It reuses `update-call-state` with
an early-return `remote_leave_diagnostic` branch and the existing native writer.
It does not send `timeout`/`ended`, invoke signaling, or change automatic teardown.
The existing refresh still runs once; its original exception is rethrown.

- Both Android and Dart require developer mode plus the existing default-off
  FaceTime diagnostics setting. Diagnostic exceptions are swallowed without
  logging their bodies. The Dart sender bypasses the generic method-send logger.
- Each marker contains fixed `reason=participant_leave`, active/total participant
  counts, and `matches_active_call=true|false|unavailable`. This reason labels the
  event type, not why the peer left or a terminal reason code. Only equality is
  persisted; the UUID is used internally in the existing channel, never logged.
  No handles, participant IDs, tokens, links, SDP, media or account data are added.
- `received` uses the currently cached Dart snapshot. `refreshed` uses the snapshot
  after the existing refresh. `refresh_failed` may contain stale cached counts.
  Both session lists are searched; missing snapshots produce `unavailable`, not
  zero. These are observations around a refresh, not atomic native transitions.
- Counts are typed and clamped to 0..65535. Native state strings are allowlisted.
  Existing 256-byte lines, per-stage/state rate limits and two 64 KiB generations
  remain. Four new executable Kotlin tests cover redaction, malformed data,
  opt-out, rotation, throttling and independent close/lifecycle logging.
- Dart never awaits diagnostics in call dispatch. A finite in-flight phase set
  permits at most three pending channel operations per service, drops duplicate
  phases while pending, and releases entries on completion/failure. There is no
  retry, queue or new logger. Three Dart source-contract tests check this wiring.

Limitations: rapid events may be coalesced by these bounds. Equality reflects the
native Activity at marker handling time, not an immutable per-call correlation ID.
Overlapping calls cannot be reconstructed from these markers alone. An inbound
LeaveEvent may reflect another device or handoff; it does not prove the remote
human pressed Hang Up. Native events suppressed by the timestamp guard and native
protocol reason/transition details remain unobservable through the current event
contract. No shared Rust API, FRB or generated changes were required or made.
The original analyzer skipped this stage and cleared its media baseline. The
September 12 follow-up below repairs that parser gap; participant observations
still do not constitute a terminal verdict.

Exact paths changed by this sidecar, relative to the worktree above:

```text
lib/services/rustpush/rustpush_service.dart
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeCallStateHandler.kt
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeDiagnosticLog.kt
android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeDiagnostics.kt
android/app/src/test/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeDiagnosticLogTest.kt
test/services/facetime/face_time_diagnostics_contract_test.dart
test/services/facetime/face_time_media_probe_test.cjs
docs/FACETIME_ASTRA_LIFECYCLE_20260910.md
```

Validation from this worktree, using the supplied ARM64 Flutter/Dart SDK:

```powershell
& 'C:\Codex\Toolchains\flutter-3.44.8-arm64\bin\flutter.bat' test --no-pub --no-test-assets --reporter expanded test/services/facetime/face_time_outgoing_start_test.dart test/services/facetime/face_time_incoming_admission_test.dart test/services/facetime/face_time_diagnostics_contract_test.dart test/services/facetime/face_time_log_export_test.dart test/services/facetime/face_time_outgoing_lifecycle_test.dart
& '.\test\services\facetime\run_face_time_host_tests.ps1'
node --test tooling/facetime/web_leave_bridge.test.mjs tooling/facetime/web_rtc_diagnostic_bootstrap.test.mjs tooling/facetime/analyze_native_trace.test.mjs test/services/facetime/face_time_media_probe_test.cjs
& 'C:\Codex\Toolchains\flutter-3.44.8-arm64\bin\dart.bat' analyze lib/services/rustpush/rustpush_service.dart test/services/facetime/face_time_diagnostics_contract_test.dart
```

Results: **49 Flutter tests passed; 74 Kotlin/JUnit tests passed; 63 JavaScript
tests passed**. The first JavaScript run was 62/63 because the existing source
contract required the old five-argument diagnostic forwarding call. Its two
assertions now require forwarding both media and remote-leave evidence; rerun
passed. Analyzer exited 0 with no errors/warnings and four style infos on untouched
statements. These tests do not compile the Android-dependent handler/Activity,
exercise the new channel on Android, or qualify a real call. No devices, calls,
credentials, accounts, Git/push/CI, heavy builds or descendants were used. Other
dirty files were not edited; existing targeted build/test outputs were reused.
End-of-task read-only storage check: C: free 49.38 GiB; existing worktree `build`
2.205 GiB and `.dart_tool` 7.502 GiB (whole-tree totals, not this patch's growth).
The targeted Kotlin test jar is 99,065 bytes. No cleanup or deletion was performed.

## September 11 bounded outgoing lifecycle recheck at 439ebff7e

No service stall reproduced; initial 18 tests passed. No timeout or calling-policy change.
Approved follow-up adds `facetime_setup` markers to the existing capped Dart logger, not native logs.
Both developer mode and the existing default-off FaceTime diagnostics toggle gate emission.
Fields are a service-local ticket ordinal, fixed event and phase labels; no call IDs or private content.
Events bracket link lookup, optional handles lookup, creation and timer arm, plus rejection and terminal cleanup/release.
At most 13 events per ticket; repeated rejections coalesce to the first. Late results retain terminal phase.
Ordinals reset with the service and wrap after 2147483647; they cannot correlate native UUIDs or separate runs.
Next check: enable before starting, retain only `facetime_setup` lines from the ordinary app log (INFO required).
For the same ordinal, distinguish unmatched preparation/creation `before`, `timer_armed`, and `terminal_cleanup` without `terminal_released`.
`rejected` identifies the blocking ticket's phase; an accepted retry gets a new ordinal even while old cleanup awaits.
Do not share the whole ordinary log: unrelated entries may contain private data. Filtering/rotation/crash can lose markers.
Validation: 36 focused Dart tests passed via supplied Flutter SDK with `--no-pub --no-test-assets` (lifecycle, outgoing-start, diagnostics-contract).
These are seam/formatter/source checks, not runtime delivery or media proof. No device, native build, dependency, CI or Git-write operations.

## September 12 offline leave-event analysis repair

The native writer's valid `remote_leave` markers were rejected because both the
stage and the `matches_active_call` field were unsupported. This hid leave
observations and broke the baseline between otherwise valid media samples.
The analyzer now validates the exact five-field contract, preserves unavailable
counts as null, records the three finite leave phases in log order, and retains
the media baseline across valid observations. Malformed or unknown input still
breaks that baseline. Reversed timestamps invalidate ordering.

The targeted regression failed before the fix (zero advancing pairs instead of
one). All 35 Node analyzer tests passed after the fix and in parent verification.
The patch changes only offline analysis and its tests. It does not infer that a
participant leave ends a session, close a viewer, or establish that calls work.
The next live check remains one answered call with verified two-way media beyond
30 seconds, followed by remote hangup and observation of the existing close path.

## September 12 scoped regression recheck at bc9cbab793

Checkout: `C:\Codex\OpenBubblesReview\worktrees\cloudkit-v2-update-seam`,
HEAD `bc9cbab7937799c39e161564ef957d0d3772ab01` verified locally. This section
supersedes older worktree/test-status claims for this review only. Production
FaceTime is still unqualified; no new production defect was reproduced in the
owned Kotlin/WebView/JS or outgoing Dart lifecycle paths. No production edits.

### Retained evidence, not a new capture

Targeted filename inventory used local-reach, then an ignore-independent filename
check under `device-evidence`. No `facetime-native*.log` generation was found.
No general app/Rust logs, profiles, databases, credentials or device were opened.

- Latest FaceTime capture folder found:
  `facetime-20260911-live-review/capture-20260911-100513-a1`.
  Its `review-summary.json` reports absent native diagnostic directories and zero
  native lifecycle records. Both `pid-facetime-logcat.txt` and its retry are zero
  bytes, verified directly. The current analyzer on the retry returns zero accepted
  records, zero ignored lines, no segments, exit 2 (insufficient evidence).
- Earlier retained `pixel-write-20260909-3dc614c9e/`
  `facetime-login-native-20260910-0555.log` is 815 bytes. The current analyzer
  returns zero accepted records, five ignored lines, no segments, exit 2.
  Raw lines were not echoed. This is not a current-schema lifecycle trace.
- The September 11 summary has no installed source-commit attestation. Its shared
  version code and recorded WebView version cannot prove this HEAD was installed.
  These captures cannot establish remote ringing/answer, two-way media, the cause
  of an early close, or repeat-call availability. Absence of records is not absence
  of failure.

### Current code and the only failing regression

Current source retains explicit-user Leave authority and its 1.5-second native
fallback, pending-ticket timer ownership, stale-cleanup isolation, same-peer inbound
media progression, diagnostic-only remote-leave handling, and the newer active
non-self JoinEvent acceptance gate. Preview, invitation, self-echo and all-inactive
snapshots do not establish working media or authorize a new terminal predicate.

Initial Node suite: 73/74 passed. The failing invitation source-contract test used
the exact text `if ring && !has_remote_invitation_target(`. Current Rust formats
that condition across lines 1333-1347, still after target lookup and before
`.send_message` at 1349 and `session.is_propped = true` at 1455. This was a test
matcher defect, not missing invitation protection or a demonstrated no-ring cause.

Only `tooling/facetime/outgoing_invitation_contract.test.mjs` changed besides this
document. It now accepts whitespace between condition tokens while retaining the
lookup/guard/send/success order and guard-body assertions. A negative regression
still rejects missing and post-dispatch guards; the production check covers both
current wrapped and single-line formatting. No Rust or application behavior changed.

### Fresh local verification

- `node --test tooling/facetime/*.test.mjs test/services/facetime/face_time_media_probe_test.cjs`:
  75/75 passed after the matcher correction, including 35 trace-analyzer tests.
- `test/services/facetime/run_face_time_host_tests.ps1`: 76/76 Kotlin/JUnit tests
  passed using existing compiler jars, no Gradle/download/native build.
- Existing ARM64 Flutter 3.44.8 SDK, through its cached Dart executable and
  `flutter_tools.snapshot`, `test --no-pub --no-test-assets --reporter expanded`:
  61/61 passed across outgoing lifecycle, outgoing start, outgoing acceptance,
  incoming admission, diagnostics contract and log export tests.
- Same cached Dart executable, `analyze lib/services/rustpush/face_time_outgoing_lifecycle.dart lib/helpers/ui/facetime_helpers.dart test/services/facetime`:
  zero errors, two existing unused-import warnings in the helper, 11 infos; exit 1.
  Unrelated lint cleanup was deliberately not included.

These checks do not compile the Android Activity or qualify Apple WebView behavior,
remote ringing, real media or device lifecycle. Existing unrelated working-tree
changes were left intact. Plain Git status encountered broken nested-submodule
metadata; app status was inspected with `--ignore-submodules=all`. No metadata repair,
commit, push, CI, new agents/worktrees, device/account access or cleanup was performed.

### Smallest next parent-owned live gate

After parent-approved Android compilation/installation with an attested app commit,
enable developer mode plus FaceTime diagnostics before starting. Use two consented
manual calls, not automated retries:

1. Outgoing call: independently confirm remote ringing and answer. Verify two-way
   audio and video for at least 35 seconds after answer. Remote hangs up; observe
   the viewer for ten seconds without local End. Record whether it closes, remains
   open, or closes early. If it remains open, use native End once for recovery and
   distinguish that local action from the preceding remote-hangup observation.
2. Without restarting the app, manually place the next call, confirm ringing,
   answer and two-way media, then use Apple's explicit Leave. Verify viewer closure
   and that the app is available afterward. A normal close does not by itself test
   the native fallback; qualify that separately only if this gate does not exercise it.

Retain only both bounded `logs/facetime-native/facetime-native*.log` generations
(at most 128 KiB total), build/WebView version, and content-free human observations.
Analyze generations separately. Needed stages: creation/admission, resolved
same-peer ICE/tracks/advancing inbound bytes, any `remote_leave` phases, explicit
leave/close reason and destruction. Inbound counters supplement, not replace,
independent two-way media confirmation. Missing or rotated stages remain unknown.
For setup/retry failure before a native span, additionally retain only bounded
`facetime_setup` markers from the existing INFO app logger, never the whole app log.

No Rust/API/service seam change is justified by the retained captures. If the viewer
survives remote hangup, that observation plus its trace is the next evidence for a
parent-owned terminal-event seam decision, not authority to infer termination from
participant inactivity. Parent reviews this test/doc-only diff before integration.

End-of-review storage: C: free 64.59 GiB; existing checkout `build` 5.588 GiB and
`.dart_tool` 0.444 GiB (whole-tree totals, not attributed growth). Targeted JVM jar:
100,411 bytes. Existing test caches were reused; no dependency trees were copied.

## September 16 independent-lane entry (branch agent/facetime-findmy-independent-20260916)

Implemented and tested, not live-proven: commit 52bf20ec2 refactors the
outgoing acceptance gate behind a PII-free verdict enum (accepted,
snapshotMissing, guidMismatch, noSelfHandles, eventFromSelf, noActiveRemote)
with identical gate semantics, and logs one `facetime_accept` line per
JoinEvent carrying only the verdict plus active/total participant counts
behind the existing developer plus FaceTime-diagnostics switches. A rejected
remote acceptance previously left no trace between JoinEvent and the timeout
cancel, which reads exactly like remote-ends-on-accept. The Rust invitation
path was re-verified by inspection: create_session binds a fresh conversation
link before prop_up_conv sends the Invitation, and link rotation reassigns
usage slots without invalidating the launched URL, so neither is the current
suspect. Outgoing lifecycle, incoming admission, and acceptance suites pass;
targeted analysis shows no new findings.

Live protocol change for the next consented call: read the `facetime_accept`
verdict in the app log first. `noActiveRemote` points at the snapshot/join
event mismatch; anything else distinguishes gate behavior from missing join
events or launch failure. Sustained two-way media beyond 30 seconds, remote
and local hangup, subsequent-call recovery, and viewer overlap remain
device-gated and unproven. Live window requested from the CloudKit task;
no live call runs without its ack and same-day partner consent.
