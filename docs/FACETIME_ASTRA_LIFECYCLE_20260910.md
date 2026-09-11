---
type: Investigation
title: FaceTime explicit-leave lifecycle repair
description: Isolated candidate restoring intent-scoped native teardown, with offline regression evidence and remaining Android live gates.
tags: [facetime, android, lifecycle, regression]
timestamp: 2026-09-10
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
account/device access. No deletions. The only test build artifact is the ignored
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

Parent must schedule Android Kotlin compilation and the existing FaceTime Flutter
tests on its approved GCE/CI workflow before integration/device installation.
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

## Independent timer defect for parent review, not patched here

In `placeOutgoingCall`, correlation is published before awaiting createFacetime,
but the 30-second timer is installed afterward without checking that the same call
is still pending. An immediate JoinEvent can accept the call and cancel no timer;
creation then returns and arms a timer that cancels the accepted session. Its
callback and asynchronous cleanup also mutate shared `currentOutgoingCall` and
metadata without checking ownership, potentially clearing a subsequent call.
Keep this as a separate identity-scoped Dart lifecycle repair with deterministic
async tests. Its occurrence in the reported live call is not established.
