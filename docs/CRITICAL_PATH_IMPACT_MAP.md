---
type: architecture
title: OpenBubbles Critical-Path Impact Map
description: Operational dependency map for live messaging, startup, CloudKit, outbound sends, and account transitions.
resource: openbubbles-app
tags: [openbubbles, architecture, messaging, cloudkit, regression-prevention]
timestamp: 2026-08-30
---

# OpenBubbles critical-path impact map

## Purpose

This is a change-impact map, not a complete source inventory. It identifies
shared gates where a local change can stop or corrupt more than one feature.
Use it before changing startup, native state, message persistence, CloudKit,
or account-reset code.

## Non-negotiable invariants

| Boundary | Invariant |
| --- | --- |
| Incoming APN | A native pointer is acknowledged only after durable local projection succeeds. |
| Receive readiness | Optional iCloud, CloudKit, contact, relay, and analytics work never blocks live message receipt. |
| Incoming retry | A failure is visible and leaves the pointer retryable; duplicate delivery is idempotent. |
| Outbound send | Every terminal path leaves exactly one recoverable local message with deterministic send state. |
| Live delivery vs cloud archive | A successful IDS/APNs send or local reflection does not prove that a Messages in iCloud record exists. |
| Legacy CloudKit | A failed page does not advance its token or issue destructive duplicate cleanup. |
| V2 semantic pull | Checkpoints represent a contiguous durable terminal prefix; retained-unprojected rows remain replayable. |
| Account transition | Old-account work is quiescent before state is replaced or disposed. |
| Canary | Semantic pull performs no remote content write, delete, subscription, or PCS creation. |

## Change-impact matrix

Use this table before editing a shared hotspot. A marked product path must be
treated as in scope even when the requested feature belongs to only one column.

| Shared hotspot | Live receive | Outbound send | Legacy CloudKit | V2 CloudKit | Account reset | Minimum required gate |
| --- | :---: | :---: | :---: | :---: | :---: | --- |
| `RustPushService.initFuture` and native-state bootstrap | X | X | X | X | X | Startup-readiness contract plus Android cold-start delivery tests |
| `RustPushService.state` ownership and disposal | X | X | X | X | X | State-replacement-before-ack test plus account-transition quiescence tests |
| `Database.waitForInit()` and ObjectBox lifecycle | X | X | X | X | X | Receive-readiness test plus persistence and model-compatibility tests |
| Android engine and headless APN handoff | X |  |  |  | X | Pending APN queue tests plus Android cold-start delivery tests |
| Incoming queue, `handleMsg`, and `Message.save()` | X | X | X | X |  | Duplicate delivery and exactly-once projection tests |
| CloudKit operation interlock and writer ownership |  |  | X | X | X | Interlock, writer-authority, and mutation-surface tests |
| Account and cached identity selection | X | X | X | X | X | Exact-account binding tests plus mismatch fail-closed tests |
| Canonical conversion and associated-parent parsing | X | X | X | X |  | Rust converter tests plus Dart association and reaction tests |
| Page journal, inbox applier, and checkpoint store |  |  | X | X | X | Crash-boundary replay and contiguous-prefix checkpoint tests |
| Semantic replay, projection repair, and ObjectBox candidate queries | X | X |  | X | X | Bounded native queries, cooperative-yield tests, and device ANR validation |
| Canary artifact identity, VM trigger, and report export |  |  |  | X |  | Exact-source CI plus separate signer verification, followed by APK package, trigger hash, unique report, and full redacted-schema validation |
| Attachment materialization and file ownership | X | X | X | X | X | Attachment store tests plus account-reset cleanup tests |

The matrix is intentionally small. A generated graph of every import would
mostly describe compilation dependencies, while these entries describe
runtime ordering, durable ownership, and acknowledgement dependencies where
data loss and cross-feature regressions occur.

## 1. Live incoming message

```text
APNService.receievedMsg
  -> main engine, bounded engine queue, or headless DartWorker
  -> MethodChannelService "APNMsg"
  -> RustPushService.recievedMsgPointer
       -> native pointer decode
       -> waitForRustPushReceiveReadiness
            -> native state bootstrap
            -> ObjectBox initialization
            -> bounded wait
       -> handleMsg
            -> reflection and incoming queue
            -> ActionHandler.handleNewMessage
            -> Chat.addMessage / ObjectBox
       -> verify account state did not change
       -> completeMsg native acknowledgement
```

Primary code:

- `android/app/src/main/kotlin/com/bluebubbles/messaging/services/rustpush/APNService.kt`
- `android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/DartWorker.kt`
- `lib/services/backend/java_dart_interop/method_channel_service.dart`
- `lib/services/rustpush/rustpush_receive_readiness.dart`
- `lib/services/rustpush/rustpush_service.dart`
- `lib/services/backend/action_handler.dart`

Impact rule: any new `await` before `handleMsg` or `completeMsg` must be
bounded, receive-critical, and covered by a failure test. The August 29, 2026
Alpha regression violated this rule by putting optional password and clique
maintenance inside `initFuture`; native retries then expired and dropped the
unacknowledged pointers.

## 2. Startup and native state

```text
APNService.launchAgent
  -> initNative
  -> nativeReady / APNService.ready
  -> get-native-handle
  -> RustPushService.onInit
       -> restore SharedPushState
       -> initFuture completes
       -> live receive can proceed
       -> optional iCloud maintenance starts separately
       -> contacts, relay health, and UI follow
```

Shared gates:

- `APNService.ready`, `started`, and `pushState`
- `MainActivity.engine` and `engine_ready`
- `RustPushService.state` and `initFuture`
- `Database.waitForInit()`

Impact rule: `initFuture` is a receive-critical barrier. Do not add CloudKit,
password sync, clique probes, contact refresh, FaceTime prefetch, analytics,
or other optional network work to it.

## 3. Outbound message

```text
UI or notification reply
  -> OutgoingQueue
  -> ActionHandler.sendMessage
       -> persist temporary local state
       -> RustPushService.sendMessage / sendMsg
       -> native send and retry
       -> replace or finalize ObjectBox row
       -> deterministic failure state and notification
```

Shared state includes `RustPushService.state`, `sendingServiceId`, native
resource readiness, the outgoing queue, and ObjectBox. A change to retry or
timeout behavior therefore requires persistence tests, not only transport
tests.

### Live send and Messages in iCloud are separate paths

```text
OpenBubbles send
  -> IDS/APNs delivery
  -> local reflection and ObjectBox persistence
  -> optional reflection to another registered Apple device
       -> native Mac/iPhone Messages persistence and possible cloud archival
       -> not an OpenBubbles durability guarantee

separate CloudKit archival path
  -> explicit legacy or V2 CloudKit save
  -> remote record confirmation
  -> later semantic pull observes the record
```

Impact rule: do not infer CloudKit persistence from successful delivery, a
local reflected row, or another online OpenBubbles client. The restore-only
Canary intentionally blocks CloudKit saves. Before enabling V2 outbound writes,
test whether the iPhone relay reliably archives a uniquely identified live
send and whether that record later appears through the read-only semantic pull.
The regular Windows client's Mac mini backing proves only the Mac-owned native
path; it is not evidence for the Pixel's iPhone-relay path. Treat relay archival
as an optimization only if repeated offline, delayed, and reconnect cases prove
it; otherwise retain an audited explicit CloudKit writer.

## 4. Legacy CloudKit

```text
doCloudKitSync
  -> background isolate or desktop coordinator
  -> writer ownership and operation interlock
  -> chat, attachment, and message page loops
  -> validate every page
  -> project locally
  -> advance token only after the page is valid
```

Restore-only mode may project local data, but it must not delete local rows
from tombstones or issue remote duplicate deletion. A single failed item must
hold the page checkpoint.

## 5. V2 semantic pull

```text
manual confirmed pull
  -> production preflight
  -> operation interlock and native-writer pause
  -> cached account identity validation
  -> bounded ObjectBox projection-repair candidate pages
  -> bounded protected fetch by zone
  -> journal page
  -> synchronous per-entry ObjectBox transaction
  -> cooperative event-loop yield after the durable terminal state
  -> apply contiguous durable inbox prefix
  -> checkpoint
  -> revalidate identity and remote-write tripwire
  -> resume native writer
```

Shared gates include writer ownership, operation interlock, coordinator and
page leases, account-bound storage, and semantic-pull quiescence. Crash tests
must cover fetch-before-journal, journal-before-apply, and
apply-before-checkpoint boundaries.

The August 30, 2026 Canary exposed a second boundary: ordered semantic replay
can remain correct while starving Flutter's UI isolate. Android recorded a
5,003 ms input-dispatch ANR while the pull processed retained records. Candidate
queries must apply native ObjectBox limits before `find()`, and replay or repair
loops must yield between completed rows. Never insert a cooperative fairness
yield inside an ObjectBox transaction, while a transient identity lease is held,
or before inbox status, canonical projection, replay metadata, and checkpoint
state are atomically durable.

### V2 chat-to-attachment dependency chain

```text
raw CloudKit record and raw field-presence evidence
  -> typed CloudChat
  -> required chat identity and service validation
       -> optional `lah` disagreement: discard only `lah`, retain chat identity
       -> RCS service: retain and count, but do not project or relabel as SMS
       -> alias conflict: retain; never guess which conversation owns the alias
  -> canonical chat plus exact service-identifier aliases
  -> message `chatID` alias lookup and exact-GUID repair
  -> canonical message and associated-parent aliases
  -> attachment parent lookup
       -> validated MMCS metadata plus protected `lqa`: project, then materialize natively
       -> inline metadata: retain until a native inline-body path exists
       -> malformed or mixed metadata: quarantine; never guess
```

Impact rule: chat conversion is an upstream identity gate. Rejecting a chat
before its aliases are emitted can make otherwise valid messages report
`chat_unavailable`, then make their attachments report `parent_missing`.
Optional `last_addressed_handle` (`lah`) metadata is not chat identity and must
not erase that chain when raw presence and the defaulted typed string disagree.
Only that unproven field is dropped; a malformed wire field still quarantines,
required identity remains strict, RCS remains unsupported rather than being
relabeled as SMS, and alias ownership conflicts remain fail-closed.

RCS is an explicit product-scope boundary for this release because the Android
messaging client remains authoritative for RCS. Its records stay durable and
diagnosable so support can be added later without refetching or data loss.
MMCS credentials and URLs remain inside the protected Rust envelope; canonical
payloads carry no credential material. Credential isolation alone is not proof
that an inline body can be downloaded, so inline and MMCS attachments must not
share an admission branch.

### Canary device-validation chain

```text
exact source commit on GCE
  -> full Dart, Rust, rustpush, protector, and bridge-drift gates
  -> Canary APK build and native-library verification
  -> GitHub-hosted signing
  -> local artifact verification: APK hash, signer, and application ID
  -> exact Canary package only
  -> adb install -r and unchanged firstInstallTime
  -> one post-launch process and post-launch VM-service URI
  -> no-rebind local port forward
  -> integrity-pinned VM trigger
  -> exactly one newly emitted report
  -> report timestamp bound to this invocation
  -> exact source commit and complete content-free schema
  -> remote-write flags false and outbox 0 -> 0
```

Impact rule: never make the probe's package target generic. APK identity and
trigger integrity must fail before installation or invocation. Do not select
the first report from a set difference; require exactly one report and bind its
timestamp to the current run. The semantic report is the diagnostic source for
this gate, so the probe must not copy full application logs. An in-place pull is
expected to change Canary's local projection state; preservation means no
uninstall, no clear-data operation, an unchanged `firstInstallTime`, and no
remote mutation, not byte-for-byte database equality.

Artifact-signature verification is a separate host step and is not delegated
to the device probe. Subscription creation and PCS creation are not encoded in
the current device report, so their absence remains an exact-source static
review and CI contract gate. The report independently proves that automatic
triggers, saves, deletes, semantic tombstone deletes, and outbox work remained
disabled at runtime. Do not claim that the report alone covers mutation
surfaces it does not encode; add direct counters before promoting that claim.

## 6. Account reset

```text
markFailedToLogin / reset
  -> block new V2 and outbound work
  -> wait for in-flight operations
  -> clear active state
  -> reset and dispose native clients
  -> resume owners for the next account
```

Impact rule: timeout is not proof of quiescence. If an operation cannot reach
a terminal state, preserve the native state and fail visibly rather than
reporting a clean reset.

## Required tests before changing a shared gate

1. Live APN projection completes before acknowledgement.
2. Readiness failure is bounded, logged, and remains retryable.
3. Optional startup maintenance cannot delay receive readiness.
4. Duplicate APN delivery projects exactly once.
5. Outbound success, timeout, retry, and failure each preserve one local row.
6. Legacy page failure holds the token and performs no destructive cleanup.
7. V2 crash boundaries replay without skipping or duplicating projection.
8. Account mismatch or reset prevents old-account mutation and acknowledgement.
9. Long V2 replay and projection repair permit event-loop progress without
   changing candidate order, transaction atomicity, or checkpoint advancement.
10. Canary device probes prove APK and trigger identity, select one report from
    the current invocation, validate its entire redacted schema, and never
    accept another package name.

## CI routing policy

The map should eventually select the smallest safe gate set for each change,
while an always-running classifier reports the decision as one stable required
check. Keep the existing full workflows as a safety net until the routing has
matched real failures across several pull requests.

| Changed surface | Required focused gates |
| --- | --- |
| Startup, native state, method channel, or APN handoff | Receive-readiness tests, queue tests, Android unit and Kotlin compile gates, and cold-start delivery tests |
| ObjectBox model or database lifecycle | Model compatibility, persistence, inbox-applier, and attachment-store tests |
| Cloud Sync Dart implementation | Full Cloud Sync Dart suite, ObjectBox persistence subset, cooperative-yield/query-bound tests, device ANR replay, and web parity |
| Rust bridge, rustpush gitlink, generated bindings, or CargoKit | Binding reproducibility, Rust tests, rustpush tests, protector harness, and an APK packaging check |
| FaceTime-only implementation | Dart FaceTime tests, Android FaceTime tests, and WebRTC diagnostic replay |
| Windows-only implementation | Windows x64 gates and ARM64 architecture/native-library verification |
| Documentation only | Frontmatter and link validation only |
| Dependencies, workflows, packaging, or ambiguous shared configuration | Full validation and artifact builds |

An artifact job must depend on its relevant test jobs. A Beta or Canary APK is
not valid evidence merely because it compiled while a boundary test failed.

## Change review checklist

Before merging a change in one of these paths:

- Identify every caller and shared state object in this map.
- Classify each new wait as receive-critical or optional.
- Put a timeout and safe retry behavior on every external wait.
- State the durable mutation that occurs before and after the wait.
- Add a contract test at the boundary, not only a unit test of the parser or API.
- Verify Alpha live receive, Canary semantic pull, and account reset separately.
