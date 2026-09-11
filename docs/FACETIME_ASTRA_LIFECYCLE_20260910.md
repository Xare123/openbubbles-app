---
type: Investigation
title: FaceTime explicit-leave lifecycle repair
description: Isolated candidate restoring intent-scoped native teardown, with offline regression evidence and remaining Android live gates.
tags: [facetime, android, lifecycle, regression]
timestamp: 2026-09-11
---

# Result

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
The offline analyzer is unchanged: it currently skips this new stage and clears
its media baseline at an unknown record. Inspect the redacted exported lines
directly for this evidence; do not interpret them as a new analyzer terminal verdict.

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
