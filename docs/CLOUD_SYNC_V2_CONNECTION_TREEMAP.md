---
type: architecture
title: Cloud Sync V2 Connection Treemap and Recovery State Machine
description: Source-linked end-to-end model for safely authenticating, fetching, decoding, journaling, projecting, recovering, and validating Messages in iCloud data.
resource: openbubbles-app
tags: [openbubbles, cloudkit, messages-in-icloud, architecture, recovery, canary]
timestamp: 2026-09-05
---

# Cloud Sync V2 connection treemap and recovery state machine

## Decision

Treat Messages in iCloud as a durable replicated log whose ingestion is
separate from local message projection. A successful network fetch is not a
successful sync, and an undecryptable or temporarily unprojectable record must
not disappear merely because a later CloudKit cursor exists.

Every protected operation in one run must remain bound to the same tuple:

```text
account fingerprint
  + live CloudMessagesClient identity
  + read-authentication generation
  + protected-store identity
  + native writer-pause permit
  + container/database/zone
  + checkpoint generation
```

If any member changes, the run fails closed. It must not borrow another
container, create PCS state, fall back to legacy sync, clear a cursor, or
continue under a new account.

## Status legend

| Status | Meaning |
| --- | --- |
| `LIVE-PROVEN` | A content-free report or device trace has exercised the boundary on the Pixel. |
| `TEST-PROVEN` | Focused source-contract or behavioral tests cover the boundary, but current-device proof is incomplete. |
| `REPAIRED; LIVE PROOF PENDING` | Source contains the intended repair; generated bindings, signed APK, or device proof remains. |
| `IN REPAIR` | A concrete counterexample invalidated the prior candidate and the replacement has not passed every gate yet. |
| `GAP / POLICY DECISION` | The safe behavior is not wired end to end or needs an explicit product decision. |

## Latest integration checkpoint, 2026-09-05

- Installed Canary remains `317adb489`: the user confirms working photos, but
  current IDS registration repair still needs completed sign-in and an ordinary
  send. Alpha and the source inspection databases are untouched.
- Reviewed gallery/document, recipient-validation, FaceTime and Find My fixes
  are frozen at `d5413ec9c` for GCE run `33981816999`. Local checks pass 107 Dart
  and 10 JavaScript tests. This APK candidate does not include the later
  immutable chat-dependency repair below.
- The later writer patch passes 311 focused Dart persistence, admission,
  receipt, transport, ownership and model-upgrade tests. An offline copy of the
  preserved September 5 Canary database validates all 133 direct-chat bindings
  both before and after Store restart, without opening the source as a database
  or making any remote call. Its source hash is unchanged. The first probe was
  pointed at the older September 2 pre-chat capture, found zero candidates and
  failed its nonempty gate; that result is not evidence against the newer data.
- Automatic uploading is still not wired. Remaining work is durable handling
  of origin-capture failures, initial-message capture, account-scoped recovery
  and scheduling, then an exact live create/readback and restart qualification.
  Do not equate these local tests with production synchronization.

## Live investigation board: personal integration review, 2026-09-04

This board supersedes the historical board below. Reviewed baseline:
`7db9ed89b9443ffa5beef07b373e8d281ccaac40`, including its pinned rustpush
`722fa440e9458459290bfb09ceda20c4e578161e`, plus the focused settled-outbox
repair described below. Do not infer current installed-device behavior from an old checkpoint,
an APK build, or a test count. The user has since observed real chats and
photos; sequence 475 and zero displayed messages are historical failures, not
the current universal blocker. No fresh device read or live remote write was
performed during this first review.

The highest-value remaining work is integration, not another decoder rewrite:

```text
Relay identity -> Apple account -> Keychain clique / PCS -> CloudMessagesClient
  |
  +-- V2 developer read -> protected journal -> canonical projection -> UI
  |     |                                                         |
  |     +-- durable cursors / replay                               +-- on-demand media
  |     +-- no startup/reconnect/background production caller
  |
  +-- normal composer -> IDS live delivery -> local Message save
  |     +-- local-origin intent + Message saved in one transaction
  |           pending -> ready only after matching IDS success / identity proof
  |           +-- protected stage -> atomic outbox/map/intent adoption
  |           +-- restart resolves exact adopted envelope, never re-encodes
  |           +-- automatic admission / upload consumer NOT wired yet
  |
  +-- developer one-message writer -> protected outbox -> create-only CloudKit
        -> exact receipt -> confirmed-only readback -> retained terminal row
        -> acknowledged, immutable settled row -> next semantic read
           (Windows ObjectBox restart test passes; live Apple cycle pending)
```

| Boundary | Current source evidence | Status / required proof |
| --- | --- | --- |
| Identity and read prerequisites | Ordinary Apple login and Keychain clique preparation are separate. The dedicated V2 preparation path exists; historical live read and the user's restored messages prove the private read protocol is reachable. | Preserve the working identity. Do not reset Alpha, copy platform-bound keys, or reopen a solved login investigation without fresh evidence. Fresh-device setup remains a separate qualification gate. |
| Read and visible projection | `RustPushService.runCloudSyncV2AutomaticSemanticCatchUpConfirmed` loops bounded semantic batches. `ObjectBoxCanonicalSemanticEntityAdapter` projects owned records. The user has confirmed readable chats and working photos. | Useful restore exists. Requalify the exact current build and specific gallery/GIF case; do not report all media as broken or all media as proven. |
| Persistent automatic sync | The automatic catch-up method is called by `troubleshoot_panel.dart`, not startup, reconnect, or a background worker. `CloudSyncShadowRuntime` is shadow-only. The Android scheduling worker is explicitly dormant. | **Production gap.** One-click foreground catch-up is not continuous cross-device sync. Compose one durable account-scoped runtime before enabling background scheduling. |
| Outgoing integration | The gated normal-send path journals supported fresh local sends with the Message transaction. Actual IDS text/route and native account/session/store identity are checked; interrupted sends remain pending. `admitLocalSend` now atomically links an existing ready intent to its protected outbox and record map. Restart uses the original envelope. The automatic consumer is not connected. | **Partial integration, not automatic upload.** Add durable handling of capture failures, scheduling/lease policy for independently owned creates, and a recovery consumer. Do not enqueue restored history or make CloudKit availability determine live-send success. |
| Read after write | The reader now distinguishes completely settled, confirmed rows from blocking work in one ObjectBox snapshot. The semantic sampler compares fingerprints of every durable outbox column before/after its paused read; receipts are not deleted. Pending, leased, paused, quarantined, unknown, invalid states and unacknowledged protected receipts still block. Shadow reads retain their zero-row rule. Schema 7 reports only counts and the equality result, never the fingerprint; the device reader preserves schema 6's zero-row gate. | **TEST-PROVEN on Windows ObjectBox.** The test performs an initial read, exact receipt commit, restart, blocked unreconciled read, durable receipt acknowledgement, restart, then two successful reads with zero transport saves. Same-count mutation is rejected. Restoring the original guard makes this regression test fail with `outbox_not_empty`. This is synthetic Apple transport evidence, not a live upload claim. |
| Final native admission | The unfinished generation-fence patch moved `claimForConsumption` inside the armed mutation action. A wrong persisted UUID returned an unknown-outcome result without a native call. | **Reproduced and repaired locally.** Claim validation now follows the durable generation recheck but precedes fence arming. The regression test proves rejection, zero native calls, no fence, reuse with the correct identity, and harmless rejection of repeated consumption. The focused Dart set passes 107 tests. |
| Rust CI capability tests | Runs `33930475652` and `33930441506` exposed a test-keystore dependency, not a demonstrated parallelism failure. The replacement injects only key loading into the same private consume implementation; the public entry point always uses protected storage. Run `33936071705` on exact `7db9ed89b` passed 285 app Rust tests, 203 rustpush tests, and 30 protector tests. | **TEST-PROVEN on GCE Linux.** Failure, retry and single-use assertions now run through the production consume logic. Do not confuse these passing code gates with the separate failed APK packaging gate. |
| Media responsiveness during catch-up | Both CloudKit media lanes and native semantic sessions share a FIFO gate on V2 Canary. The final retained-record sweep now yields after at most 32 candidates, reacquiring native permission and validating account, all zone generations/sequences/tokens, and the settled outbox before continuing. Alpha and IDS scheduling are unchanged. | **GCE-QUALIFIED at `a5f84f30a`; Pixel installation/concurrency proof pending.** The 210-test sampler/adapter/report/media/drain/interlock set passes. The installed build's completed sweep took 23.7 minutes and applied zero records. A fresh HEIC then downloaded and opened full-screen in the gallery. The remaining multi-pass remote session can still delay media; unchanged failed rows can still be retried on a later invocation. |
| Remote deletion and message operations | `applyTombstone` intentionally returns `canonical_tombstone_dto_incomplete`. Edit/retracted-part fields have projection code, but outgoing transport supports initial create only. | Do not promise deletion propagation or write-side edit/unsend parity. Preserve history while establishing exact causality and ownership. These are separate capabilities, not automatically provided by a successful text create. |
| Test versus installed build | GCE run `33943836515` qualified exact `6517f86612a0cf229f2ab8dbc56cf9b70928e182`; it remains installed in place with history preserved. The later user-started pull produced fresh remote-head and final projection reports, unlike the initial timed-out VM probe. | **Current read and specific gallery HEIC proven; production integration incomplete.** The installed build excludes the local settled-outbox boundary, local-send journal, VM observation, and scheduling follow-ups. Those changes require their own frozen-source qualification. No live Apple upload claim. |
| Later cleanup | The user requested cleanup of unnecessary or disorganized code after correctness work. | Keep cleanup in separate commits: remove proven dead/duplicate paths, superseded diagnostics and misleading documentation, with tests unchanged or stronger. Do not combine a broad refactor with protocol or persistence changes. |

### Review scope and restraint

The first pass personally traced authentication/PCS, protected fetch and
projection, the media UI/downloader route, writer admission and reconciliation,
runtime callers, and build/test composition. This is not a claim to have read
every line of unrelated FaceTime/Find My code or to have live-verified all
message types. No new review agents were used after the user requested a
personal pass. Alpha, the private Windows profile, and Apple data were not
modified. The later follow-ups repair the settled-outbox contract and add the
local ordinary-send journal described below, with bounded Sol test/audit help.
Broad runtime and tombstone changes remain outside these repairs.

### Settled-outbox audit follow-up, 2026-09-04

The bounded Sol audit of `6517f8661` found two contract mismatches, not a
receipt bypass. Preflight now rejects counts above the schema-7 report limit
of 65,535 before store/transport creation. The successful device probe prints
the validated before/after counts instead of claiming `0 -> 0` unconditionally.
Both new tests failed on the prior source. After repair, 91 focused Dart tests,
14 PowerShell contract cases and three evidence-output cases pass; targeted
analysis is clean. This report-size limit is a Canary limitation, not a
production receipt-retention strategy.

GCE run `33943836515` successfully qualified the earlier exact `6517f8661`
source, not this follow-up. Do not call its artifact the follow-up build. The
review agents are closed; their read-only reports remain audit provenance.
No dedicated build worktree was created for either review. Platform-supported
session deletion is unavailable in this session, so transcripts are retained.

### Ordinary-send integration decision

`RustPushBackend.sendMessage` persists a stable staging GUID before IDS and
the final message after IDS. `ActionHandler.sendMessage` then reconciles the
returned message. The gated V2 Canary path now shares those save transactions
with an explicitly local send journal; ordinary generic `Message.save` and
remote projection do not create intents.
`CloudSyncOutboundAdmissionCoordinator.admitLocalSend` starts from that durable
origin, awaits native protected staging, and commits the intent's adoption in
the same transaction as its outbox and record map. Calling the older
`admitMessage` unawaited after `Message.save` would still leave a crash window.

The additive `CloudSyncLocalSendIntentEntity` is entity 33. Existing entity and
property UIDs are unchanged. The real ObjectBox upgrade test opens the old
model whose last entity ID was 32, saves synthetic message/attachment/chat/checkpoint sentinels,
then upgrades and reopens without losing them. State 0 is awaiting IDS success;
state 1 is ready for protected admission; state 2 links the exact adopted
operation. The table holds only hashes, local row ID, account scope, epoch,
timestamps, the opaque operation ID and its immutable payload-binding digest,
not raw GUIDs, bodies or recipients. The two optional fields are additive;
upgrading existing pending
and ready rows preserves their state and a null link across reopen. Preserve
the intent after adoption and distinguish confirmed IDS
submission from an interrupted or failed send. CloudKit being
offline must not turn a delivered iMessage into a failed live send. Do not
derive intent from `ckSyncState == false`: V2 restored messages also retain
that default. Do not use `Message.metadata`, which belongs to link previews
and can be replaced independently.

The bounded Sol integration audit identified three P1 provenance hazards:
restored records entering the fresh-GUID path, mutable local content differing
from the actual wire payload, and in-place native account drift escaping an
object-identity check. Repairs reject existing CloudKit provenance, require the
temporary local GUID path for new origin, compare the actual IDS payload and
route on first construction and retry, and recapture the complete native auth
snapshot immediately before each joint save. A changed retry cannot promote
the original intent. The two restored-origin negative controls failed before
repair. The 38 journal/wire/auth tests pass, including account teardown during
an awaited capture, same-client account/session/store replacement, rollback,
restart and unsupported shape rejection. The broader eight-file regression
suite passes 280 tests. A direct model comparison confirms all 24 existing
entity definitions are unchanged (the highest entity ID was 32). These tests use synthetic data and
do not claim a real IDS send. The audit agent is closed; its report is retained.

One P2 durability finding remains open: the one-second native capture timeout
or a missing V2 authority allows live sending but can leave no journal row. A
later confirmed send whose auth recheck fails can remain pending. Do not infer
success after restart or reconstruct origin from arbitrary messages. Before
enabling automatic admission, add a durable provisional-send/recovery design
with exact account provenance and a visible unresolved state. An unbound row
alone cannot prove which Apple account may upload it.

Local verification also caught `build_runner` deleting the unrelated generated
`lib/src/rust/api/api.freezed.dart`. Only that unchanged tracked generated file
was restored from HEAD and its zero diff verified. Preserve the generated Rust
API when doing another filtered ObjectBox generation; no bridge behavior was
intentionally changed by the entity addition.

Before wiring automatic admission, resolve its remaining scheduling dependency:
semantic reads still block on pending/unknown outbox work, while
`_requireMessagesCloudAccountProjectionReadyLocked` requires all three zones
fully projected and rejects retained tombstones before leasing writes. Simply
hooking sends into the existing queue can strand both lanes. Keep local intents
distinct from prepared remote mutations, prove recovery ordering, and establish
new-create ownership/tombstone handling before relaxing any gate. Fresh protected
admission now checks this prerequisite before creating a blocking outbox row;
the ordering repair below does not relax the writer's projection requirement.
A one-message manual upload is not evidence that this production integration exists.

The protected admission boundary now has 22 focused tests, including native
commit failure followed by database reopen and replay with the local Message
removed. Recovery returns the original operation and protected envelope with
no second encoding or stage. Text, recipient-route, writer-epoch, native-session
and journal changes during staging reject adoption and roll back the outbox,
map, revision counter and intent transition together. Missing adopted outbox
state fails closed; a repeated IDS callback cannot downgrade state 2. Combined
journal, admission, old-model upgrade and store tests pass 154 cases. These are
synthetic persistence/ordering tests, not Apple write proof. No automatic
consumer, projection-readiness relaxation or remote mutation was added.

The follow-up Sol audit was reviewed and closed. Two accepted findings now
have negative controls: construction rejects a writer authority from another
Store, and restart validates the current generation, record mapping, immutable
payload-binding digest and protected-reference shapes in the same transaction
as the journal link. Missing maps or altered payload references/hashes do not
cause re-encoding. Lease clearing after an acknowledged receipt remains valid;
native recovery/submission still verifies the live lease's protected contents.
The recommendation to re-encode on every receipt/timestamp change was not
adopted: these are mutable observations, not a second local send. The staged
snapshot remains authoritative, while text/routing or unsupported semantic
changes still reject admission. A regression pins that distinction. Later
metadata-update support requires its own ordered mutation, not a replacement
initial create.

### Admission ordering and native evidence review, 2026-09-05

The completed Pixel report `obcs2-semantic-1788591977487853.json` retains
694 deletion markers: 81 Chat, 494 Message and 119 Attachment records.
They are not failed message sends. Allowing only non-tombstone projection debt
would therefore still block this account's writes. Do not label these markers
applied or remove their evidence to obtain an artificial green state.

The reproduced ordering defect was earlier than submission: new protected
admission accepted an outbox row even when the unchanged lease/submission
guard could already prove it ineligible. Semantic reads then saw that blocking
row. Seven negative controls reproduced this acceptance before the repair.

```text
IDS-confirmed local intent (ready, no remote work yet)
  -> read-only projection preflight before encoding / native staging
     -> not ready: preserve intent, create no outbox/map/revision
                   do not introduce an outbox blocker for future reads
     -> ready: stage the protected original payload
               -> one write transaction rechecks all sibling checkpoints
                  -> changed: roll back new lease; keep intent ready
                  -> unchanged: atomically adopt outbox/map/intent
  -> already adopted: recover exact existing envelope without re-encoding
                      leasing/submission still enforce current readiness
```

The final check also protects direct protected admission, not just the ordinary
send coordinator. No automatic caller or remote operation was enabled. The
production runtime must still serialize reads and admissions, reconcile unknown
outcomes first, and decide when a fresh create can be independent of unrelated
history. The repair prevents admission behind already-known debt; it is not a
claim that every future ordering dependency is solved.

Verification: 31 admission tests and the combined 248-test journal, ObjectBox,
model-upgrade, writer-authority and production-adapter set pass; targeted
analysis is clean. New tests cover missing sibling checkpoints, retained saves
and tombstones, pending pages, backoff, history arriving during native staging,
direct admission, restart after read recovery, and exact adopted-envelope
recovery despite later debt. The actual leasing guard still rejects that last
case. Alpha and the Pixel were not modified by these tests.

Two native release questions remain distinct from this local ordering fix:

- The pinned writer saves only `MessageEncryptedV3` in `messageManateeZone`.
  Its local Chat/routing validation is not evidence of a remote
  `chatEncryptedv2` record. There is no Chat-zone lookup/save in
  `prepare_message_save_submission`; do not promise discovery of a brand-new
  conversation on another Apple device without a Chat dependency or observed
  synthesis. The bounded Sol lookup was independently checked and closed.
- The builder selects `save_semantics = 2` with the update flag false.
  Independent Apple-client enum evidence is now recorded below. A controlled
  live collision/readback test remains a separate release gate; client enum
  evidence does not establish that a particular live write succeeded.

The documentation lookup used Apple's current page directly after the Agent
Reach reader rejected anonymous access. No credentials were sent to a research
service. The 04:59 PDT device check found the same installed `6517f8661` package
at 6 percent, unplugged, and the latest persisted report still ended at 00:06
PDT. VM status discovery was unavailable, so this is not proof that no pull was
in flight. No update, force-stop or new pull was performed. The signed
`a5f84f30a` media APK remains a separate, not-yet-installed artifact.

### Qualified fresh-create readiness, 2026-09-05

The `StringAsSaveSemantics:` implementation in independently published Apple
client decompilations maps `failIfOutdated` to 1, `failIfExists` to 2, and
`override` to 3. The mapping agrees in both
[iOS 18.2, pinned source](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/CloudKitDaemon.framework/CKDPRecordSaveRequest.m)
and [iOS 26.1, pinned source](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/CloudKitDaemon.framework/CloudKitDaemon/CKDPRecordSaveRequest.mm).
Only protocol facts are used here, not copied implementation code. This is
independent client evidence, not an Apple-published private API contract or a
live server-collision result. In particular, value 3 must not be described as
conditional updating.

An explicitly configured `ObjectBoxCloudSyncStore(localSendJournal: ...)`
can now admit and lease an initial create with durable local-origin evidence
despite unrelated retained history. The default store and generic admissions
retain the original full-projection requirement.

```text
ready local intent + stable V2 authority + exact account/epoch
  -> all three zones have complete durable terminal journals
     (applied or retained, not pending/holed/backed-off)
  -> stage original protected envelope
  -> atomic adoption rechecks origin, account, history and target tombstones
  -> lease and submission independently recheck adopted envelope/map/authority
  -> native explicit failIfExists create
  -> exact receipt or unknown-outcome reconciliation, never blind replay
```

An observed tombstone for the exact target record still blocks the create,
whether retained or already applied. No historical row is relabeled, applied,
deleted or inferred to be locally authored. Restart recovers the original
adopted envelope without reading or re-encoding a changed/deleted Message.
Unknown-outcome reconciliation remains independent of new-send readiness.

Verification: 258 focused journal/admission/store/model/authority/canary tests
pass. The optional journal must be composed into the same store used for
admission and submission. **No production consumer has been connected and no
live write has been qualified by these tests.** New-chat remote dependencies,
durable handling of origin-capture failures, continuous read/write scheduling
and real receipt/readback qualification remain open.

### Pixel media and registration incident, 2026-09-05 morning

The installed build remains `6517f8661`; no APK was installed or account reset
by the operator during this session. The 12:58:41 UTC semantic report records
zero new fetched/applied records, retained historical debt, an unchanged empty
outbox and remote saves/deletes disabled. Subsequent user testing is a separate
event and must not be covered by that earlier report's safety counts.

- At 12:56:42 UTC, an attachment failed during the native exact-record fetch.
  Dart collapsed its native result into `cloud_attachment_source_invalid`.
  Another attachment completed in 2326 ms. The user subsequently reported only
  a few working gallery photos and five unsuccessful taps. Do not classify all
  those attempts as queued, missing or decoded without per-attempt evidence.
- At 13:03:13 UTC, the recipient dialog produced a disposed TextEditingController
  error and cascading widget-tree errors. Its caller disposed the controller
  when the showDialog Future completed, before route teardown. The repaired
  dialog owns its controller until State.dispose; three widget tests cover
  the closing animation, cancellation/reopening and empty input. Not deployed.
- At 13:03:33 UTC, IDS returned 6005 and attempted re-registration. Later normal
  sends failed with `Resource has been closed`; account reset was deferred by
  `cloudkit_interlock_busy`. The user confirms the Developer Settings write
  test came before the failed ordinary chat send. Do not retry the remote write
  without checking durable outbox state.
- The installed native ResourceManager publishes a terminal failure and then
  overwrites it with Closed. Installed Dart treats that non-retryable state as
  "Logged out by Apple" and starts an automatic reset. The source repair below
  preserves the cause and removes that automatic account transition. Live
  Canary registration repair remains open; Alpha is not proof of readiness.

The media handoff APK is still pending installation. Photo presence alone is
not proof of current download reliability or a successful CloudKit write.

A later local control-state inspection used a 110,600,192-byte Canary database
copy whose SHA-256 matched before transfer, after transfer and locally. It
reported **zero outbox rows**, three checkpoints without pending page/token
markers, 318 chats, 10,126 messages and 2,391 attachment rows. These are current
stored counts, not counts restored overnight or proof of downloaded bodies.
No V2 upload remained queued in that snapshot. The inspection made no device
database changes; the private copy remains local as incident evidence.

### Registration lifecycle and explicit repair, 2026-09-05

The investigation identifies linked failures, not proof that a CloudKit save
revoked an Apple Account. The developer recipient dialog failed first; native
IDS later reported 6005; the resource worker then erased its terminal cause;
and Dart attempted an account transition while protected CloudKit work was
still active. A later snapshot had no V2 outbox operation queued.

The repaired dependency path is:

```text
native resource generation
  -> transient failure: retain retry delay; immediate retry can recover
  -> terminal failure: retain exact failure after worker exits; no blind retry
  -> explicit shutdown: Closed; refresh cannot report success
startup or live registration observation
  -> same observer: show failure, preserve account and CloudKit handles
  -> failure notification: open Profile, never claim an account-wide logout
Profile
  -> retryable: existing interlocked Retry now
  -> terminal: confirmation, recheck account/state, existing interlocked repair
     -> busy: preserve attached state; wait or ask the user to retry
     -> admitted: reopen sign-in without hardware reset or remote logout_all
```

Native commit `df74a78378e1f60fee41f16382190785816a4aa8`, pinned by app
`775bf22d5`, passed all **209 rustpush tests** on the T2D GCE runner in
[run 33970071687](https://github.com/Xare123/openbubbles-app/actions/runs/33970071687).
Six new tests exercise the actual resource worker without Apple credentials,
including late subscribers, permanent error refresh, transient recovery,
terminal failure after retry, healthy close and close during backoff.
Compilation took 47.43 seconds; tests took 5.71 seconds. Cleanup succeeded;
both the live runner-registration and VM inventories were empty afterward.
This was Rust-only validation, not an APK build or live authentication test.

Dart source now removes automatic resets from registration observation,
ordinary sends and target validation. Both startup and live state events use
`RegistrationStateObserver`; retryable-to-terminal transitions produce a new
notice, while repeated identical failure classes do not spam notifications.
Profile retains the terminal error and offers confirmed repair using
`hw: false`, `logout: false`, `ui: true`, with the existing quiescence and
interlock checks unchanged. Nine observer/confirmation tests and three
recipient-dialog tests pass. The earlier combined admission/journal/store/
canary/presentation set passes 267 tests. No new analyzer errors were found;
Profile still has five pre-existing unused/duplicate warnings.

At the subsequent USB check the Pixel remained on `6517f8661`, at 36 percent
and charging. No registration-success evidence appeared after the recorded
failure. No phone reset, install, send or writer retry was performed at that
check. Integrated APK qualification and live recovery were still required.

The same integration candidate adds a closed-set attachment-transfer diagnostic:
HTTP status, numeric CloudKit client/server code, I/O kind, or an existing safe
failure category. It never formats arbitrary PushError text, response bodies,
record identifiers or asset URLs. Two native tests pin cause separation and
redaction. This changes observability, not attachment permission, retry or
integrity policy; the five failed gallery taps are not yet classified.

The first integrated run, `33971506711` at `5eb6db19e`, failed at the Rust bridge
compile check with E0308: the new diagnostic combined `DoNotRetry(Box<_>)` and
`BatchError(Arc<_>)` in one pattern. This was an introduced compile defect,
not a device or Apple protocol failure. Split arms preserve both concrete
types, and the redaction test now includes both wrappers. No APK was produced;
cleanup completed and both live runner and VM inventories were empty. The
replacement full run is qualified below.

### Qualified integrated repair and restored-chat admission, 2026-09-05

[Run 33972171533](https://github.com/Xare123/openbubbles-app/actions/runs/33972171533)
at exact `317adb4891805a059dd37fa2ae7413724a09548c` passed **1,688 Dart,
287 app Rust, 209 rustpush and 30 protector tests**. APK compilation took
423 seconds; total through cleanup was 24 minutes 16 seconds. Its own VM
`gce-33972171533-1` and GitHub runner were deleted. An unrelated CYTV VM
remained and was not modified. Production credentials were not added to GCE.

The signed Canary APK passed local signature, package and four ARM64 ELF
checks before wireless `install -r` at 08:07:50 PDT. First-install time and
the complete ObjectBox database hash stayed unchanged. Alpha was untouched.
Local artifact qualification is retained with the APK in
`artifacts/gce-33972171533-signed-317adb489/qualification.json`. No live
registration repair or photo retry was attempted; installation is not proof
of either recovery.
This supersedes the historical installed-build references above for source
identity only, not their live-protocol findings.

The next, separate source patch binds fresh local-create admission to the
restored remote chat. `cloud_sync_outbound_chat_binding.dart` verifies the
current Chat-zone generation, canonical snapshot, unique service alias, exact
record map and latest applied save. It rejects missing, conflicting, stale,
tombstoned or retained dependencies without staging or introducing an outbox
blocker. After staging, the same check runs inside atomic adoption; failure
rolls back the new protected lease and retains the ready local intent.

The combined focused suite passes **283 tests**. An offline diagnostic on a
disposable copy of the preserved Canary database accepted **133 of 133 direct
iMessage chats**, with zero remote calls and no message content emitted. The
copy was removed after closing it; the source snapshot was preserved.

This admission patch is **not included in the installed 317adb489 APK** and
does not enable an automatic writer. Remaining work is to carry immutable chat
dependency proof through dispatch/restart, handle genuinely new remote chats,
connect the account-scoped runtime and prove a live write/readback cycle.
Existing adopted envelopes remain recoverable without re-encoding mutable
messages. This is not a permanent restriction of production scope to restored
direct chats.

### Document/gallery usability and fresh IDS failure, 2026-09-05

The user reports that photos now work on installed `317adb489`. This is
user-facing read/media evidence, not proof of successful IDS sending or CloudKit
writing. The newly captured native log records a fresh IDS 6005 at 08:59:04 PDT,
followed by unsuccessful registration recovery. Later target lookup/create-chat
calls receive the retained terminal failure. Do not attribute that rejection to
an outbox save: there is no automatic writer consumer in this build.

```text
Profile attachment overview
  -> six newest photo/video tiles (no older-page fetch on profile scroll)
  -> See all -> lazy paged gallery -> existing fullscreen/swipe viewer
  -> Documents & files immediately below the compact photo preview

Verified attachment body -> local path or bytes
  -> declared MIME, otherwise filename/path/UTI inference
  -> document card and operating-system open/share handler
```

`MediaGalleryCard` incorrectly required in-memory bytes to render a document
after download, even though the CloudKit materializer returns a verified local
file path. The source repair accepts that path without reading the entire
document into memory. MIME inference and document routing must agree between
the profile and message bubble. A card label does not prove bytes are available:
the fresh logs separately contain `cloud_attachment_source_unavailable` and
`cloud_attachment_size_mismatch`. Those require source recovery or integrity
diagnosis, not weakening verification or declaring all missing files fixed.

The compact/full gallery widget tests cover the six-item limit, reachable
documents, return navigation, lazy tile construction, paged loading and bounded
error/retry behavior. Physical-device verification of this new UI remains
pending an updated qualified APK.

For terminal IDS failure, the existing explicit Profile repair preserves chats,
hardware identity and CloudKit state, but removes the failed IDS identity/cache
and reopens account setup. It requires operator confirmation and CloudKit
quiescence. A green relay check is not proof of successful IDS registration.
Do not reset Alpha or loop repairs if Apple rejects registration again.

#### Write production gates, in dependency order

1. Repair Canary IDS registration and prove one ordinary text send. CloudKit
   must not become a prerequisite for live messaging or silently retry that
   text through a different delivery path.
2. Carry the exact restored Chat dependency into the immutable admitted send
   and revalidate it at dispatch/restart. Admission-only proof in `10a069d5c`
   is not sufficient. Handle genuinely new remote chats separately.
3. Compose an account-scoped durable consumer using the same journal, Store,
   auth fence and protected-admission coordinator. Only confirmed local origins
   may enter it. Recover original envelopes, never scan outgoing history or
   re-encode adopted messages. Handle origin-capture failure explicitly and
   cover the initial-message `createChat` path, which currently bypasses the
   ordinary-send journal.
4. Prove one create-only upload and exact server readback, then repeated runs,
   process death, reconnect and unknown-outcome recovery without duplicates.
   Enable ongoing uploads only after these pass. Group/media writes, edits and
   undo require their own supported contracts; text-create success is not proof
   of those operations.

The present change does not connect the automatic consumer or claim production
write readiness. No database schema, Apple credentials or remote cloud records
were changed in this investigation.

#### Reviewed integration candidate and repair handoff

The media, document, recipient-validation, registration-dialog and attachment
coordinator regression set passes 66 tests together on Windows ARM64. An actual
`MediaGalleryCard` test drives a path-only completion, displays `OtherFile`, and
verifies both callback subscriptions detach on exit. Targeted analysis of the
new helpers and widget fixtures reports no issues. Full Android qualification
and physical document opening remain pending; a synthetic local file is not
evidence that an unavailable CloudKit source has recovered.

The user explicitly approved one Canary registration repair. It reopened the
normal onboarding flow. Hardware, CloudKit and Keychain files retained their
pre-repair hashes. ObjectBox changed during the transition, so byte-for-byte
database preservation is not claimed; the repair path does not delete chat or
attachment rows. Alpha was untouched. Ordinary send and live CloudKit write
qualification still require completing Canary sign-in.

The bounded Astra implementation was reviewed and retained, and its worker
was closed. FaceTime now reads resolved asynchronous media evidence from the
trusted top-level Apple origin, rejects stale call/navigation results, and
keeps native hang-up available. Find My refreshes People, Devices and Items
independently, retains last-good data on failure, and does not mark a failed
Items fetch fresh. Parent verification passes 41 focused Dart tests and 10
JavaScript tests; the worker also reports 39 host Kotlin tests passed. These
do not prove a working live FaceTime handshake or a location-sharing record.

#### Immutable restored-chat dependency, 2026-09-05

Two negative controls failed on the predecessor: a queued local create could
lease after its chat snapshot disappeared across restart, and could enter
submission after an applied tombstone for that chat. The journal now captures
the restored chat's exact scope/generation, local row, canonical identity,
logical/server identity and service-alias hashes in the same transaction as
protected outbox adoption. No message body, address or raw GUID is added.

```text
confirmed local origin -> protected message envelope
  -> one transaction: outbox + record map + immutable chat binding
  -> lease: revalidate exact binding and current applied chat evidence
  -> submission: revalidate again before recording request identity
  -> unknown outcome: reconcile original envelope, even if chat proof changed
```

The optional `admittedChatBinding` is property 13 of entity 33. Existing entity
and property UIDs are unchanged. The v2 admission digest includes the binding.
Old v1 envelopes remain readable for recovery, but their missing dependency
cannot be manufactured from a current Message or used for dispatch. A newer
fully applied save of the same chat is allowed; the ETag is checked against
current evidence but is not frozen in the binding. A changed remote mapping,
missing/stale/conflicting proof or observed deletion blocks sending. Recovery
does not read or re-encode a subsequently edited/deleted local Message.

The 311-test set includes the two repaired negative controls, a consistent but
different remote-chat remap, tampered binding, older-envelope recovery, a newer
valid ETag, and database upgrade/reopen. Targeted analysis is clean. This patch
is not in GCE run `33981816999` and does not enable an automatic consumer.

### Installed Canary and VM observation follow-up

The signed `6517f8661` APK passed application-ID, native-library, signing and
SHA-256 checks before an in-place Canary-only install. Pixel's first-install
time remained unchanged; Alpha and existing reports were not modified. The
probe ended with `probe_new_report_not_emitted`, not a successful CloudKit
read. The checked exit history contained the expected package update and
probe restart, with no later recorded crash or ANR. That does not establish
whether the attempted pull started or completed.

The newest retained report still belongs to older source `e62a73297`: 476
Chat, 8,864 Message and 1,853 Attachment records retained as unprojected, with
`retained_projection_incomplete`. Those counts are not new-build evidence.
The phone remains connected but locked; do not force-stop an unresolved pull
merely to recover a VM endpoint.

The diagnostic driver previously treated a VM reference to the returned
Future as an invocation result without observing its outcome. It now selects
a ready UI isolate, schedules a fixed semantic method after evaluation returns,
and polls a content-free completion/error observer. Five real child-Dart-VM
tests cover delayed success, catch-up, immediate asynchronous failure, error
redaction and an unresolved timeout that leaves the remote operation alone.
Inline invocation reproduced a missed immediate error in that test; event-
queued invocation passes. No specific Dart SDK defect is claimed. The device
probe gives this observer its own 240-second budget instead of the ordinary
60-second child-process budget. These are tooling repairs, not new APK or live
Apple protocol proof. Recover current read-only status before another pull.

The `8d430e032` qualification run `33952316640` stopped before APK compilation:
1,629 Dart tests passed and two tooling tests failed. The command-line contract
still expected the pre-`--status` spelling, and the child-VM fixture printed
its readiness marker before the separate VM-service process wrote its
connection file. The fixture now waits, bounded to 20 seconds, for complete
service JSON. Missing/partial-file and invalid-mode regressions are covered;
all 31 VM/composition checks pass locally. No runtime sync logic was weakened
to pass these checks. Runner deletion succeeded and live inventories confirmed
zero GCE instances and zero GitHub runners. This failed run produced no
qualified APK; the scheduling patch still needs a new full qualification.

### Qualified media-handoff build, 2026-09-05

The replacement run `33962908484` qualified exact source
`a5f84f30a12c2123759eb8b98e4ff2bffa1b1d3a`: 1,638 Dart tests, 285 app Rust
tests, 203 rustpush tests and 30 protector tests passed, followed by APK
compilation, native-library verification, GitHub-hosted signing and cleanup.
Live GCE and GitHub inventories both confirmed zero remaining runners.

The downloaded APK is 448,551,294 bytes, SHA-256
`BA6D6F74433A6E9DE0A01015B80E830E4A6955A269208DA0DE0A06B3EFD96298`.
Local signature verification passed v2/v3 with the established Canary signer
`0ea17c1b67581ca79660d33db45af0a36b71ea36a4cbafec5293d3ae80570d79`.
The manifest is `com.bluebubbles.messaging.cloudkitcanary`, version code
20002227 / 1.15.0, and the embedded Rust ARM64 library is ELF64/AArch64
(machine 183). This is not an Alpha package.

Installation and live concurrent-media verification were deferred: the Pixel
was reachable wirelessly but at 7 percent, unplugged. No package update,
force-stop, message deletion or new pull was performed during that check.
The separately committed local-send adoption patch `f0cfa5eb2` passes 239
focused local tests and clean analysis but is **not in this qualified APK**.
It grants no automatic upload capability. Keep those two qualification states
separate; the installed device remains on `6517f8661` until an explicit
in-place update is verified.

### On-demand media handoff

The previous media wait observed `_cloudSyncV2SemanticPullInFlight`, which
covers every automatic batch. The replacement schedules the transport body and
each bounded semantic batch through `CloudAttachmentSyncGate`. It never locks
the whole automatic loop. Existing `synchronized` implementation inspection and
the regression test establish FIFO ordering: batch A, queued media, batch B,
with at most one operation active. A failed body does not poison the queue.

Queued work rechecks service teardown, client identity and private-store path
before running. Media also checks cancellation and rejects changed attachment
GUID or transport lane. These scheduling checks do not replace the V2 body's
full native account, source and integrity checks. Teardown quiesces admission,
then drains queued/active media before disposing the client; a barrier timeout
does not enqueue a delayed destructive action or release a still-active lock.
The change is limited to the V2 Canary runtime; Alpha and IDS retain their
existing scheduling. No native writer-pause or account-ownership gate was
relaxed. The Sol test work was reviewed and the agent closed. Current-device
gallery responsiveness and image decoding remain unverified for this patch.

### Pixel gallery qualification follow-up, 2026-09-05 UTC

The user manually started a semantic pull and limited photo testing to
Gizelle's conversation. Fresh schema-7 report
`obcs2-semantic-1788590554560231.json` identifies installed `6517f8661`, with
all three zones observing a terminal empty remote read, zero fetched records,
outbox `0 -> 0`, `settledOutboxUnchanged=true`, remote saves/deletes disabled
and retained evidence preserved. Retained counts remain 476 Chats, 8,864
Messages and 1,853 Attachments. The content-free report is retained under
`evidence/device-6517f8661-20260905/` outside this worktree; SHA-256 is
`6720d4d33e37474a5a2be7ebac60bed7bcf412fcc02c4eb4260391e0a8918b63`.
This is fresh remote-read evidence, not completed local projection.

On the actual Pixel UI, an already-available conversation image rendered,
while a requested PNG in the same contact's gallery remained a spinner.
Native logs continued processing retained records for more than ten minutes
after the remote report, including `invalid_snapshot` and nested Message
protobuf field-2 wire-type mismatches. No photo contents or message text belong
in this report. One private temporary UI capture was discarded from the PC;
no phone image, message, account data or app package was deleted or reset.

This observation exposed a remaining limit of the first scheduling patch:
`_catchUpWithinConfirmedSession` runs the entire `_sweepRetainedSavesAtHead`
inside the same confirmed native pause. That sweep restarts its cursor at zero
for every run and retries windows of retained saves. Yielding between outer
catch-up batches cannot interrupt this long final sweep. Do not qualify gallery
responsiveness merely because the FIFO tests pass. The next repair must split
retained projection into resumable, bounded work that revalidates the exact
account, checkpoint bounds and write fence between sessions. It must preserve
unresolved records and distinguish known unchanged conversion failures from
records whose dependencies or converter have changed. Simply dropping the
session-proof or native-pause checks is not a repair. Verify the same gallery
request after that handoff before diagnosing asset absence or HEIC decoding.

### Bounded projection handoffs and completed device evidence, 2026-09-05 UTC

Final installed-build report `obcs2-semantic-1788591977487853.json`, timestamp
`2026-09-05T07:06:17.487853Z`, confirms the retry sweep finished. It examined
3 chat, 2,937 message, and 1,734 attachment saves, retained every candidate,
and applied zero. Zone elapsed times were 1,007, 816,869, and 604,042 ms.
The settled outbox remained `0 -> 0`; retained totals remained 476, 8,864,
and 1,853. The content-free report is kept with the previous device evidence;
SHA-256: `d01728ef62f292209adf247d9a9898d7d8cfb25553f5d9013b38d2a0757beb88`.
The long work was local retry debt, not further network history retrieval.

After the sweep, a previously undownloaded 244.46 KB HEIC in the authorized
conversation gallery changed from cloud icon to rendered photo after a tap.
A second tap opened the full-screen viewer (5 of 24); a horizontal swipe
displayed the adjacent image (4 of 24). This is installed-build
evidence for that gallery item and decoder, not proof for every old asset,
GIF, source lane, or concurrent-sync behavior. Private photo contents are not
included in source or reports.

The follow-up changes the actual native session boundary:

```text
persist terminal remote-head report under the read pause
  -> capture account + every zone generation/sequence/token + settled outbox
  -> release native pause and durable interlock
  -> FIFO admission (queued media may acquire its own native session)
  -> fresh native pause + auth preparation + exact captured-state validation
  -> acquire a fresh zone lease, project at most 32 retained candidates
  -> verify lease and captured state, release lease/pause/interlock
  -> advance in-memory cursor; repeat, allowing queued media between windows
  -> final fresh admission, recount all zones, persist aggregate evidence
```

The old session-bound proof is not reused as permission. Each applier is
created inside the new session with its new pause token. The immutable head
snapshot only bounds local work and must match at every handoff. Neither a
changed token with unchanged sequence nor a same-count outbox mutation may
pass. No transport is created during projection. Cancellation or a changed
fence returns no completed sweep; already committed rows remain durable.
Uncertain native release retains the sampler's fail-closed latch.

Validation: 54 sampler tests and the combined 210-test production-adapter,
report, attachment, drain and interlock set pass. A media handoff test acquires
a different operation kind and native pause between windows, not just a Dart
callback. Tests cover account/session replacement, another zone's generation
or token change, outbox mutation, cancellation, lease loss, final evidence
revalidation, and the 32-candidate cap. Targeted analysis is clean; the service
still has four preexisting informational braces lints. A bounded independent
read-only audit found no additional actionable issue and the agent was closed.

Still open: the remote multi-pass phase is one session, not a strict latency
bound; projection cursors are in-memory, so an interrupted invocation may
replay failed rows; a later pull can repeat unchanged conversion failures.
Do not claim durable failure scheduling or new Pixel concurrency proof yet.

## Historical investigation board

The following table preserves evidence and prior decisions. Its references to
"current", "next", installed SHAs, and counts describe earlier checkpoints;
use the live board and current critical path above/below for work selection.

| Node | Current evidence | Status | Next falsification test |
| --- | --- | --- | --- |
| Windows private profile and identity | The isolated `cloudkit-v2-dev` profile and marker are present. A current read-only inspection of the real profile proves 668 chats, 12,258 messages, 2,237 attachments, and outbox zero. It contains one pre-existing contentless local row with no CloudKit record identity; the same row remains in the disposable copy and is not a V2 replay regression. Its 48,319-file tree hash was identical before and after the policy experiment, proving the source profile was untouched. The disposable copy now contains 12,569 messages and 2,370 attachments after replay. | Real profile and local projection `LIVE-PROVEN`; isolated policy candidate `LIVE-PROVEN` | Freeze the qualified source, retain the real profile as rollback evidence, and perform mutations only in disposable copies until Android qualification. |
| Relay activation and saved identity | Alpha's existing relay health check is green. A consumed sharing code is rejected by the registration relay with HTTP 401, while a fresh iPhone-relay code entered into the signed Canary was accepted and advanced through Apple password login to SMS 2FA. The OABS/QR exporter deliberately supports only `MacOSConfig`; `RelayConfig` has no encoded transfer payload. A Windows `hw_info.plist` contains a usable `RelayConfig`, but its NGM identity is bound to the Windows keystore. Android KeyMint rejected that copied identity, so it is not a portable login bundle. The repair now stages only the saved relay configuration and creates fresh Android-local NGM and APNS state through the same setup path Alpha uses. | Root cause `LIVE-PROVEN`; repaired path `TEST-PROVEN` | Qualify and install the repaired Canary, verify that Activation shows the saved relay device, then advance through Apple login without requesting another relay code. |
| Fresh Apple account and PCS bootstrap | The active CloudKit branch had diverged from the installed Alpha and omitted `201661268` and `b0ea2abbc`, Alpha's stale-login-attempt and Rust-handle lifetime repairs. Canary now restores Alpha's guarded login controller while retaining the content-free SRP response classifier. Exact source `6bb6a506db2f525a756d4e773fe1c98884bbcc05` completed fresh Android login, created Android-local identity state, and reached CloudKit. Its first V2 pull then stopped at `cloud_sync_native_auth_pcs_zones_failed`. A trusted-device PIN bootstrap through the existing legacy setup enlarged the local Keychain state, and the next V2 pull passed PCS authorization and fetched 450 protected changes with writes disabled. This isolates ordinary Apple login from the separate iCloud Keychain clique requirement. The dedicated V2 preparation action now checks clique membership, fetches existing escrow bottles, prompts for one trusted-device credential, and joins without enabling legacy sync. Empty recovery data fails closed, non-credential join failures are treated as outcome-unknown and rechecked before any retry, account teardown waits for the foreground operation, and the path contains no encrypted-data reset call. | Login and PCS boundary `LIVE-PROVEN`; dedicated V2 preparation `TEST-PROVEN` | Qualify the exact SHA, install it over Canary without clearing data, and prove the preparation action reports already-ready on the existing trusted profile. A fresh untrusted Canary remains a separate live join test. |
| Apple network path | On the current military Wi-Fi, the PC reached `gateway.icloud.com:443`, the APNS bag endpoint, and the same APNS courier host on TCP 5223 and 443. The committed rustpush revision tries 5223 then 443 with bounded timeouts. GitHub SSH 22 was blocked, so source submodules use a command-local HTTPS rewrite only. | `TEST-PROVEN`; live active APNS port not yet recorded | Record the selected APNS port and a successful CloudKit request from the signed Windows harness without logging credentials or content. |
| Session-wide no-write boundary | Independent audit disproved the first controller design: one-shot sampler calls resumed native writers between reports, before terminal-empty acceptance. The replacement holds one operation interlock and one native-writer pause across every pass, report persistence, and terminal decision. Every controller construction now requires an explicit session runner; the unsafe one-shot fallback is gone. The durable fence renews throughout the session. Exit settles an in-flight renewal and checks the actual operation state, while same-kind nested work is rejected immediately after fence loss. Sixty-six focused tests pass, targeted analysis is clean, and the post-fix independent audit found no P0-P3 issue. | `TEST-PROVEN`; GCE/live pending | Full Dart/Rust/GCE qualification on the frozen replacement SHA. |
| Crash-recovery interlock feedback | A force-stop during a live legacy sync correctly releases the process and file locks but leaves the durable database fence valid for its five-minute crash-safety lease. Immediate legacy and V2 retries fail closed. The interlock now reads only the active lease expiry through an optional owner-free status surface, bounds that advice to its own maximum lease duration, and gives the user an approximate retry interval. Missing, corrupt, or clock-skewed status falls back to the five-minute maximum. It never clears, steals, renews, or identifies the lease. | Safety behavior `LIVE-PROVEN`; repair and expiry tests `TEST-PROVEN`; device copy pending | Force-stop one Canary pull, restart, and require the busy message to explain the interrupted lease. Retry after expiry and require acquisition without clearing state. |
| Drain termination and launcher identity | The 16-pass outcome is now distinct resumable non-success. Every status is bound to a cryptographic launch ID and exact Dart PID, launchers are profile-serialized, and timeout or identity mismatch leaves the active exact process running. A later invocation rejects that retained harness before touching build artifacts and rechecks immediately before launch. The status reader now retries transient Windows sharing violations without accepting stale or malformed state. No-build drain selection chooses the latest matching read-only semantic report rather than an unrelated newer projection report. The local-only projection viewer uses a source-bound, artifact-hash build receipt; mutated-artifact and changed-source receipt tests fail closed. CloudKit-capable no-build operations retain the stricter fresh-report gate. | Viewer restart and status/report handling `LIVE-PROVEN`; drain terminal behavior `LIVE-PROVEN` on the isolated copy | Keep launch identity and report-selection contracts in the focused PowerShell suite, then repeat on the frozen Android candidate. |
| Initial-sync workload controls | The first authenticated Android semantic pass used four pages of 50 changes per zone. It fetched 200 chat, 50 message, and 200 attachment changes; attachment metadata processing alone took about 65 seconds, while no message could project because the eligible message preceded its owning iMessage chat behind an SMS-heavy change stream. CloudKit continuation is an opaque per-zone token plus `moreComing`, so the client can resume but cannot safely date-seek. The installed Canary offers one, four, or sixteen passes under one interlock and native-writer pause. It has now fetched through chat sequence 524, but the pending page is held behind sequence 475 rather than needing another page. A content-free comparison with the already-drained Windows profile places its corresponding heads at 793, 18,992, and 3,626 changes. The comparison is directional rather than a cursor equivalence proof, but it shows why one small run cannot complete history and why sixteen passes can reach the chat head long before the message head. | Workload and resumability `LIVE-PROVEN`; bounded composition `TEST-PROVEN`; current chat page blocked locally | Repair and replay the exact local barrier before fetching another chat page. Require persisted reports after every pass and increasing chat ownership. Escalate to Deep only after the current page drains. Do not fetch attachment bodies during initial history. |
| Remote-ingestion head | Engine evidence distinguishes a durably journaled terminal empty server page from a duplicate nonempty page that inserts zero rows. The isolated Windows profile reached a terminal empty read for all three zones with content-free checkpoint totals of 793 chat, 18,992 message, and 3,626 attachment changes. The preserved Android Canary has not reached any zone head; its message zone still has one protected pending page. | Windows topology `LIVE-PROVEN`; current Canary incomplete | Resume the Canary from its protected tokens. Treat a pass-limit exit as progress, not completion, and accept head only when each exact zone records an empty terminal read. |
| Exact local projection | Earlier signed Android state held 599 owned chats and projected 87 messages. The preserved Windows profile holds 668 owned chats and 12,258 owned messages. The isolated compatibility replay recovered 311 additional historical iMessage messages and 133 attachment metadata rows, reaching 12,569 messages and 2,370 attachments. All 311 replay-added messages are renderable. The full copy has 12,503 plain-text bodies, 65 attachment-only rows, and the same one pre-existing non-CloudKit blank row as its source. Its projected bodies contain zero replacement characters, unexpected controls, malformed UTF-16, common mojibake signatures, HTML error documents, or invisible-only text. Outbox remains zero, and a second drain applied zero rows. The read-only Windows list and detail viewers reached ready state in responsive signed windows. Of 262 current-provenance V2 attachments, all 262 resolve to exact protected sources; 115 are materializable and 147 are honestly metadata-only. A signed live probe transferred one 1,150-byte plugin payload through exact record fetch, ETag binding, PCS decryption, MMCS/Ford V2 authentication, and atomic placement. A second production-adapter call returned `alreadyReferenced=true`, preserved the file digest and timestamp, created no materialization partials, and left exactly one final `referenced` row. | Windows projection, replay, viewer, one attachment transfer, and live idempotency `LIVE-PROVEN`; Android presentation pending | Qualify one exact source and require the preserved Canary to show the same recovered history without a restart, orphan, new blank row, duplicate, or write. Then repeat one small on-demand attachment on Android and require one verified local body with no partial state. |
| Android projection-to-UI handoff | `ChatsService` ignores its first zero-to-nonzero count transition and its incremental watcher adds only one chat when a transaction creates many. The Windows replay exposed a second defect: direct semantic message writes never maintained `Chat.dbOnlyLatestMessageDate`, so all 545 chats with visible messages had a null ordering cache. The adapter now updates that cache monotonically per message, and a local-only post-pull repair backfills older projected profiles before the full chat-list refresh. On the disposable profile it repaired 545 rows, produced 545 exact matches with zero null/stale/ahead rows, and changed zero rows on repeat. A refresh failure still preserves the completed CloudKit result and gives an explicit restart fallback. CloudKit URL balloons also carried a valid projected URL while `hasDdResults` was false; the legacy getter therefore misclassified them as unsupported interactive messages. The getter now recognizes a URL-balloon marker plus a validated URL, preserves the first URL when multiple distinct links are present, and fails closed for invalid text and nullable legacy flags. | Ordering repair `LIVE-PROVEN` on Windows; URL-balloon repair and Android source contract `TEST-PROVEN`; device proof pending | Install only after full qualification, then require recent chats to appear in correct order immediately after catch-up and after app restart. Open a pulled multi-link URL balloon and prove a usable preview target without exposing message content. |
| Canonical ownership bootstrap | Exact source `046bea639793163e3343e67c8367c44e8a08a526` passed the full GCE, signing, runner-cleanup, and native-library gates in run `33622711864`, then installed over the preserved Canary with Alpha unchanged. The corrected nullable-style bootstrap committed one authenticated Chat snapshot and three iMessage aliases, proving the circular bootstrap repair works. The next Standard run reached chat sequence 524, but sequence 475 became a local barrier. The auth-drift repair let that exact protected row pass a stable before/after identity fence and reach `native_ready`. Content-free decoder instrumentation then isolated the remaining conflict as `decoder_chat_service_mismatch`: Rust intentionally emitted typed SMS `CloudChat` metadata for the mixed-route historical-iMessage resolver, while Dart still enforced the older iMessage-only Chat contract. The candidate removes only that stale Chat rejection; SMS/RCS Message and Reaction bodies remain rejected or typed out of scope. The current content-free census remains 176 local iMessage chat shells, one Chat snapshot, one record map, one replay row, zero projected Messages, and 49 later Chat rows ordered behind sequence 475. | Bootstrap and exact barrier cause `LIVE-PROVEN`; decoder contract repair `TEST-PROVEN` | Qualify and install the repaired Canary in place, replay sequence 475, and require sequences 476-524 to drain. Then require Chat snapshots to rise above one, the retained Message to gain an independently proven owner, visible chats/messages in the actual UI, unchanged outbox `0 -> 0`, and unchanged Alpha state. |
| Outbound authority and exclusion | The Android-Canary-only UI selects the newest eligible existing one-to-one iMessage text, shows only a GUID hash, timestamp, and character count, and requires two single-use confirmations. The operator must enter the exact recipient; the persisted candidate must use canonical iMessage endpoint forms and agree across chat GUID, chat identifier, sole participant, and one current IDS sending handle. The encoded native `CloudMessage` is then checked against that same exact route before any admission. Before provisioning and again inside the final `v2ReadWrite` exclusion, it re-reads only that newest row and requires an exact private content/routing binding; edits, deletion, rerouting, active-handle replacement, expiry, or a newer outgoing row cancel the operation without falling back. The core holds the cross-process interlock through native quiescence. Every native writer boundary independently requires that active interlock. A changed account, exact Dart transport client, protected-store identity, authority epoch, or exact cached writer-container instance revokes the permit; an ambiguous postcondition durably marks authority `mutationUnknown`. The guard rechecks timeout poisoning after asynchronous identity capture and before it can arm mutation state. Each native prepared handle has a random SHA-256 binding recorded in the durable capability fence, so a capability for one handle cannot consume another. The native consume boundary accepts that one digest-bound capability and revalidates the retained container on both sides of submission. | `TEST-PROVEN`; no live write yet | Qualify the exact source in CI, then prove one bounded Canary create while legacy/read-only owners cannot overlap it. |
| Deterministic Messages record identity | Apple derives a missing message record name as full lowercase hexadecimal HMAC-SHA256 with `ckAppInit.cloudKitUserId` as the UTF-8 key and the unchanged message GUID as UTF-8 data. A signed ARM64 Windows debug DLL from CI run `33484931375` compared that derivation with 142 Apple-created message records in the isolated profile: 142 matched and zero differed. No content or identity input was logged. The diagnostic oracle has been removed from the candidate. | `LIVE-PROVEN`; 142/142 exact matches | Keep the synthetic fixture in CI and reject any staged, prepared, or reconciled mapping that disagrees with the deterministic derivation. |
| Exact first-create reconciliation | V2 now initializes the exact general Messages container, resolves only the existing `messageManateeZone` PCS configuration, and keeps its container-scoped user ID native-only. It derives the stable name before staging, then recomputes the derivation at prepare and reconcile. A non-forgeable native binding retains the exact container `Arc`; same-user replacement fails before proof or submission and a post-submit replacement becomes mutation-unknown. Exact absence may admit create-only; an exact matching digest is a local confirmed no-op; divergent state is quarantined; unresolved state stays pre-submit. A post-submit create conflict is ambiguous until exact reconciliation proves same, divergent, or unresolved state. Recovery accepts one exact `pending` or `unknownOutcome` create and automatically routes an exact `confirmed` row into no-save replay. The Canary's transition policy retains the confirmed native receipt durably; protected-store recovery treats that receipt as live across restart. Exact readback returns an opaque proof bound to the operation and receipt. Only that proof can release the local receipt, while quarantined and ordinary confirmed rows keep terminal cleanup behavior. Neither lane admits a new message. | `REPAIRED`; live write pending | Run one exact remote-absence/create/confirmed-only-replay sequence and prove one remote record, one durable terminal outcome, and zero replay saves. |
| Outbound durability before live write | The first durability repair adds an all-or-none, scope- and generation-bound compare-and-swap renewal for the exact outbox batch. It renews both `leased` and ambiguity-fenced `unknownOutcome` rows through mapping preparation, native preflight, submission, response handling, and unknown-outcome reconciliation. Losing the renewal after submission fails the run without confirming or replaying the row. The receipt repair now binds every confirmed create to the exact operation ID, logical-key hash, server-record hash, and nonempty ETag hash. Rust accepts success only when Apple's full returned record identity matches the submitted identity; Dart rejects missing, malformed, mismatched, or wrongly correlated receipts; and the store updates the existing record map plus outbox terminal state atomically. Exact already-present preflight and unknown-outcome readback carry the same receipt contract. The manual unknown-recovery lane now commits that exact receipt through the same atomic store operation instead of using a generic confirmed transition; a failed or mismatched receipt remains unknown with backoff. A receiptless confirmation becomes outcome-unknown with backoff, and if a later per-record commit fails, the engine finalizes only the already-durable prefix while every remaining row keeps its submission identity for reconciliation. The expanded receipt, engine, manual-Canary, and production-composition surface passes 255 focused tests; generated bindings remain drift-clean. The first full GCE qualification passed the Dart suite but exposed three parallel Rust capability-test failures before APK packaging, so the exact follow-up source is not yet qualified. Local message mutation and outbox admission are still not one ObjectBox transaction; tombstone causality has no safe anti-resurrection proof; and account/generation fencing at the final native commit boundary plus live legacy/V2 one-writer coexistence remain unproven. | Receipt and lease repairs `TEST-PROVEN` locally; overall `NO-GO` for remote writes | Repair and qualify the Rust capability tests, then rerun the exact receipt stack on GCE, including Rust, ObjectBox transaction/reopen, full Dart, generated bindings, and APK packaging. Then close the final account/generation commit fence and make local mutation plus outbox admission atomic. Keep remote writes disabled until tombstones, account fencing, and coexistence pass restart and ambiguity tests. |
| Candidate qualification | GCE run `33622711864` qualified exact source `046bea639793163e3343e67c8367c44e8a08a526`: generated bindings, full Dart, Rust, rustpush, protector, Canary APK/native-library verification, GitHub-hosted signing, runner deregistration, and VM deletion all passed. The signed artifact was installed in place without clearing Canary data. Live login, PCS, protected read, no-write tripwires, and one Chat ownership bootstrap passed. The auth-drift repair and single-use barrier migration pass 237 focused decoder, engine, and ObjectBox tests. The follow-on SMS-Chat contract repair passes the 58-test decoder/safe-code set and the exact mixed-route ObjectBox integration test; full clean qualification is pending. | Installed predecessor `LIVE-PROVEN`; current repair `TEST-PROVEN`; end-user projection incomplete | Qualify and install the repair in place without clearing Canary data, inspect a read-only post-run copy, and use visible readable UI state as the release gate. |

### Investigation checkpoint: preserved retry generation after contract repair

Exact source `e78eb7ab11310878758bc01dc0c1dc7fab7e2621` passed generated-
binding drift, the full Dart suite, Rust library and production-feature tests,
the protector harness, Canary APK/native-library verification, GitHub-hosted
signing, runner deregistration, and VM deletion in GCE run `33720501924`. The
signed artifact installed in place with Canary's first-install time and signing
identity unchanged and Alpha untouched. The live Standard pull performed zero
remote saves or deletes, but the UI still showed no chats.

A stopped, read-only ObjectBox copy proved why. Chat sequence 475 remained the
first nonterminal row: quarantined as `conflict`, with no preflight, replay, or
record-map evidence and retry count 3. The repaired typed-SMS Chat decoder was
therefore never reached. The original migration accepted retry count 1 only;
two earlier signed diagnostic retries that isolated the decoder mismatch had
preserved the row and advanced that same historical count to 3.

The replacement migration admits only the non-adjacent historical counts 1 and
3 under the existing exact scope, active-fence, first-barrier, protected-source,
no-semantic-evidence, and fixed-cutoff constraints. Counts 2 and 4 are rejected,
so a failed retry from either admitted state cannot re-enter. Focused and full
ObjectBox tests prove both admitted states, both adjacent rejection states,
idempotence, checkpoint preservation, and evidence rejection. The next
falsification gate is a no-rebuild device replay: sequence 475 must reach the
repaired decoder and the ordered remainder through 524 must drain before a new
signed GCE artifact is produced.

### Investigation checkpoint: why projection worked before but not here

The apparent regression is multiple distinct states behind the same “pull
finished” UI. Authentication and PCS decoding worked, but the local ordered
projection stopped before its transaction.

1. The historical signed Android store had 599 independently authenticated
   Chat snapshots before it committed 87 Message snapshots. Seventy messages
   belonged to iMessage chats and 17 to SMS chats.
2. The isolated Windows fast-loop store reached all three remote heads and has
   668 Chat, 12,258 Message, and 2,108 Attachment snapshots. All 12,258 messages
   have a local chat; 10,125 belong to iMessage chats.
3. The current Canary has 176 local iMessage chat shells, but only one V2 Chat
   snapshot, one record map, and one replay row. It has zero projected Messages.
   The chat checkpoint fetched through sequence 524 but cannot apply beyond
   sequence 474 because sequence 475 is quarantined; 49 later valid rows remain
   ordered behind it.
4. Sequence 475 reached Rust `native_ready`. Before starting the semantic
   transaction, the decoder recaptured its native authentication snapshot and
   found that the client/session identity had changed. The old implementation
   classified this transient authorization drift as a nonretryable semantic
   conflict, even though no replay or record-map evidence was written.
5. A content-free comparison found no exact server-record hash for sequence 475
   in the isolated Windows snapshot. That absence means the profiles cannot be
   used to infer semantic equality or override the Android record's identity.
6. CloudKit Chat record names are generated identifiers, not a derivation of
   `Message.chatID`. The client therefore cannot safely exact-fetch the parent
   Chat by converting the message field into a record name.
7. The repair keeps the strict before/after identity fence. Drift now produces
   a retryable, content-free authorization code and no projection. A fixed-cutoff
   migration may reopen only this first current-generation Chat save, only at
   retry count one, only under the active coordinator fence, and only when no
   replay or record mapping exists. It preserves the protected source,
   checkpoint, token, and attempt history. A second real conflict cannot enter
   the migration again.
8. The bounded retry then passed a stable identity fence and returned native
   `ready`, but the newly split content-free decoder codes identified the next
   conflict as `decoder_chat_service_mismatch` rather than generic conflict.
9. This was a cross-layer contract regression. Commit `fa51bd5c4` deliberately
   retained typed SMS `CloudChat` metadata so one proven current SMS group can
   own its historical iMessages. Dart still carried the earlier iMessage-only
   Chat assertion from `b41f3df2b`, so the valid dependency could never reach
   the already-tested mixed-route resolver.
10. The repair admits typed SMS metadata only in the Chat lane. The existing
    native exact-service check remains authoritative, while SMS/RCS Message and
    Reaction bodies stay rejected or typed out of scope. Focused decoder,
    safe-code, and mixed-route ObjectBox tests pass.
11. After that page drains, safe recovery returns to the same ordering that
    succeeded before: authenticate and commit Chat owners and aliases, then
    replay retained Messages. A message-derived owner, copied Windows snapshot,
    legacy `ckRecordId`, or relaxed account boundary remains rejected.

The next experiment requires one in-place repair build while preserving Canary
state. On the first Standard pull, sequence 475 must commit as typed Chat
metadata, then sequences 476-524 must drain before another chat page is fetched.
Success requires more than a completed snackbar: Chat ownership must increase,
the retained Message must project, at least one readable chat/message must be
visible after an app restart, outbox must remain `0 -> 0`, and Alpha must remain
unchanged.

For Dart-only barrier diagnosis, the existing signed debug Canary now has a
proven no-rebuild loop: attach Flutter with the Canary's four exact compile-time
defines, hot-reload the bounded content-free diagnostic change, invoke the
existing semantic action, and inspect only the reviewed report vocabulary. The
initial attach took about 21 seconds and a one-to-two-library reload about one
second. This lane cannot qualify a release and cannot test Rust/native changes;
the final candidate still requires a clean exact-SHA build, native-library
inspection, signing, and in-place install.

### Investigation checkpoint: Windows projection and usability proof

A fresh read-only inspection of the isolated Windows ObjectBox profile on
2026-09-02 confirmed that CloudKit data is not merely downloaded and journaled:

1. all 12,258 projected messages are attached to one of 668 chats;
2. 12,192 use plain-text bodies and 1,828 carry attachment relationships; 65
   are attachment-only, while one pre-existing local row has neither content
   nor a CloudKit record identity;
3. the local outbox remained zero, with 15,034 semantic snapshots and matching
   record maps still present; and
4. a dedicated local-only viewer bypassed CloudKit authentication, exposed no
   send/delete controls, and displayed both the conversation list and a full
   conversation from the existing projection.

The full-conversation view rendered ten current viewport rows after the
latest-message positioning correction, retained an explicit read-only banner,
and showed no load error or empty-content placeholder. The exact signed build
then closed and reopened from a source- and artifact-hash receipt in 1.42
seconds, producing the same content-free UI result. The process remained
responsive on both launches. The Windows capture helper could read the Flutter
accessibility tree but could not foreground the custom window for a bitmap
capture; this is a test-helper limitation and is not counted as visual proof.

The later disposable replay added 311 messages without adding any blank or
malformed body. Its production body-selection path resolves 12,503 rows from
plain text and 65 from an attachment fallback; the sole contentless row is the
same non-CloudKit row already present in the source. A content-free scan found
zero replacement characters, unexpected control bytes, unpaired UTF-16,
common mojibake signatures, HTML error documents, or invisible-only projected
text. The untouched source and replayed copy also have the same 78 messages at
risk of an empty attachment placeholder, the same 137 missing referenced
attachment rows across 90 messages, and zero missing attachment relations.
Those placeholder risks are therefore pre-existing legacy projection debt,
not a V2 replay regression. No message body was printed, copied into a report,
or retained as a test artifact.

This closes a major ambiguity: the canonical converter, durable projection,
chat linkage, and basic rendering model can produce usable message history.
It does not prove Android Canary ownership catch-up, Android database refresh,
or production UI integration. Those remain the release gate.

Static review then found a deterministic Android presentation gap behind that
last boundary. The normal chat-count watcher ignores the first transition from
zero chats and cannot enumerate a multi-chat semantic transaction. The Canary
catch-up action now awaits one full `ChatsService` refresh after the durable
semantic session returns. The refresh uses the app's existing asynchronous chat
loader, remains outside the CloudKit transaction, and has a content-free
restart fallback so a presentation error cannot be mistaken for lost history.
Focused composition and presentation tests pass; signed-device proof remains
required.

### Investigation checkpoint: session and launcher safety

The 2026-08-31 controller/launcher checkpoint closed five concrete
counterexamples before another live request:

1. native writers no longer reopen between bounded drain passes;
2. the database fence heartbeat remains active for the whole confirmed session;
3. an in-flight renewal is settled and its concrete operation state is checked
   before success can escape (the earlier post-Zone static check was ineffective);
4. disposal closes admission and cannot start a later pass after the current
   persisted report; and
5. pass-limit, timeout, stale status, and concurrent-launch outcomes cannot be
   mistaken for a successful exact-process drain, and a retained timeout/2FA
   process blocks rebuilding its executable or DLL;
6. no controller construction can silently replace a confirmed session with
   repeated one-shot pulls; and
7. same-kind nested interlock work checks the concrete lost-fence state before
   entering its action.

Evidence at this checkpoint is 66 focused session/launcher Dart tests, 140
focused engine/report/mutation/composition tests, a clean targeted analyzer,
the PowerShell launcher behavioral suite, and `git diff --check`. The engine
batch includes the explicit duplicate-nonempty-page counterexample. This is
host proof only. The candidate remains unqualified until a fresh independent
audit, the full GCE matrix, and the signed isolated Windows profile all pass on
one exact commit. The broad local suite is not treated as evidence because this
shell lacks `objectbox.dll`; the pinned GCE image is the full-suite authority.
The bounded post-fix audit found no remaining P0-P3 issue in the session,
interlock, harness, or launcher diff.

### Investigation checkpoint: deterministic Messages record identity

Apple's current and iOS 18.2 implementations agree on the complete first-create
record-name function:

```text
lowercase_hex(HMAC-SHA256(
  key  = UTF8(container_scoped_cloudkit_user_id),
  data = UTF8(message_guid)
))
```

There is no input normalization, case folding, delimiter, prefix, Base64
encoding, or truncation. `CKRecordUtilities.recordNameUsingSalt:guid:` calls
the exported `IMSharedHelperHMACSHA256`; its CommonCrypto implementation passes
the salt as the HMAC key and GUID as data. Independently, CloudKit's private
container initialization returns JSON field `cloudKitUserId`, and rustpush
already stores that exact value as `CloudKitOpenContainer.user_id`. Apple's
container implementation exposes the same container-scoped value as the
current user's `CKRecordID.recordName`, which is the salt consumed by Messages.

This invalidates V2's former `allocate_or_reuse_record_name(None)` UUIDv4 path.
The content-free local oracle passed on 2026-09-01: a CI-built, SHA-256-checked,
ARM64-verified, locally signed debug DLL compared 142 already-fetched Apple
message records and emitted 142 `match=true` observations with zero mismatches.
No GUID, salt, record name, message body, credential, or derived digest was
logged or crossed FFI. The temporary oracle was then removed. V2 staging now
derives the record name inside Rust from the validated general Messages
container, and prepare plus reconcile independently recompute the same binding
before remote I/O.

## End-to-end treemap

```mermaid
flowchart TD
  A[Explicit Canary run] --> B[Product admission]
  B --> B1[Canary package + compile gate + developer mode]
  B --> B2[Legacy sync off + operation interlock]
  B --> B3[Read-only flags + outbox zero]

  B --> C[Identity and read capability]
  C --> C1[Capture active client and account fingerprint]
  C1 --> C2[Restore or refresh revocable read authentication]
  C2 --> C3[Pause native CloudKit writers]
  C3 --> C4[Warm exact Messages, Keychain, and Security containers]
  C4 --> C5[Warm exact chat, message, and attachment PCS zones]
  C5 --> C6[Require semantic lane plus exact pause capability at transport boundary]

  C6 --> D[Replicated-log ingestion]
  D --> D1[Read generation-bound checkpoint]
  D1 --> D2[Fetch bounded zone-change page under same permit]
  D2 --> D3[Protect raw envelopes and next token]
  D3 --> D4[Atomically journal page and pending token]
  D4 --> D5[Commit protected page lease]

  D5 --> E[Decode and projection]
  E --> E1[Reacquire same read-auth permit]
  E1 --> E2[Lookup exact cached PCS zone config]
  E2 --> E3[Unwrap record key and decrypt fields]
  E3 --> E4[Validate raw presence and canonicalize]
  E4 --> E4A[Resolve an ownership-proven exact message chat GUID first]
  E4A --> E4B[Otherwise require the strong service identifier binding]
  E4B --> E5[Keep group lineage and msgProto4 diagnostic-only]
  E5 --> E6[Project messages before reactions and attachments]
  E6 --> E7[Persist applied, retained, retryable, or quarantined state]
  E7 --> E7A[Measure the durable retained backlog after repair attempts]
  E7A --> E8[Promote token only for a complete terminal journal]

  E8 --> F[Exit and recovery]
  F --> F1[Revalidate account and client]
  F1 --> F2[Quiesce protected native operations]
  F2 --> F3[Verify no remote writes and unchanged outbox]
  F3 --> F4[Persist content-free report]
  F4 --> F4A[Accept terminal empty or resumable cap while pause remains held]
  F4A --> F5[Resume native writers]

  D2 -. token expired .-> R[Generation-scoped rebootstrap]
  R -. currently unwired .-> D1
  E3 -. key or dependency unavailable .-> Q[Retain durable evidence for repair]
  Q --> E1
```

The important cut is between `D4` and `E`: remote progress first becomes a
durable local journal. Projection may then retry without refetching or losing
the exact remote evidence.

### Outbound create state machine

```mermaid
flowchart TD
  A[Read setup and projection gates pass] --> A1[Query newest outgoing row only]
  A1 --> A2[Require fresh ordinary one-to-one iMessage text]
  A2 --> B[Show content-free hash, time, and character count]
  B --> B1[First explicit confirmation]
  B1 --> B2[Re-read newest row and require exact private content/routing binding]
  B2 --> B3[Arm the exact in-memory candidate]
  B3 --> B4[Provision V2 writer ownership; no CloudKit request]
  B4 --> B5[Second explicit confirmation]
  B5 --> C[Acquire cross-process v2ReadWrite interlock]
  C --> D[Revalidate account, client, store, epoch, and exact one-row outbox]
  D --> D1[Bind exact cached Messages container instance]
  D1 --> D1A[Read its container-scoped user ID]
  D1A --> D2[Derive stable record name from GUID and salt]
  D2 --> D2A[Derive payload-V2 operation ID identically in Dart and Rust]
  D2A --> D3{Read-learned mapping exists?}
  D3 -- yes and exact derivation agrees --> E[Stage and commit native outbound lease]
  D3 -- no --> E
  D3 -- disagreement --> I[Quarantine conflict; no update merge]
  E --> F[Exact deterministic remote record lookup]
  F -- exact digest already present --> G[Confirm local no-op; perform no save]
  F -- exact NotFound --> H[Prepare create-only submission]
  F -- divergent --> I[Quarantine conflict; no update merge]
  F -- unresolved --> J[Pause pre-submit; retain retryable work]
  H --> H1[Bind the exact prepared handle to a random SHA-256 digest]
  H1 --> K[Persist ambiguity boundary and exact-handle capability fence]
  K --> K1[Recheck timeout poison after identity capture]
  K1 --> L[Consume once and correlate every operation]
  L --> M[Revalidate postconditions and quiesce]
  M --> N[Acknowledge exact durable terminal outcome]
  L -. timeout or unknown result .-> U[Mark mutationUnknown; reconcile only]
  M -. identity or authority changed .-> U
  H -. create race conflict .-> U
  U --> U1[Lease the exact unknown row; preserve Apple UUIDs and protected receipt]
  U1 --> U2[Guard-owned exact native readback; no engine, admission, prepare, consume, or save]
  U2 -- committed --> U3[Confirm; preserve UUIDs and receipt for no-save replay]
  U2 -- proven not applied --> U4[Return pending; clear UUIDs only after proof; preserve receipt]
  U2 -- divergent, unresolved, or exception --> U5[Remain unknown; preserve UUIDs, receipt, and fence]
```

This writer is deliberately create-only. Exact absence is proven before the
first save, but the ambiguity boundary is still durable before consumption
because absence and create are not atomic. Once consumption may have happened,
no automatic replay is legal. A later exact lookup may confirm the same digest;
authoritatively prove that no create was applied; or leave the operation unknown.
Only pre-submission divergence may quarantine. Once native consumption may have
occurred, divergence, a readback error, and an unresolved result all preserve
the ambiguity evidence and stop.

There are four deliberately separate operator lanes:

1. **Initial create:** exact candidate selection, private binding revalidation,
   arm, local writer provisioning, final confirmation, then at most one create.
2. **Pending resubmission:** requires one exact `pending` row and a fresh second
   confirmation. It may use the ordinary one-row engine path, but cannot admit
   another message.
3. **Unknown-outcome reconciliation:** requires one exact `unknownOutcome` row
   and a fresh second confirmation. Its session has only read, quiesce, lease,
   exact-readback, and closed-transition capabilities. It never constructs the
   write transport, engine, admission coordinator, writer permit, conflict
   merge, quarantine, delete, prepare, consume, or submit surfaces.
4. **Confirmed-only replay verification:** requires the existing durable row to
   be terminal-confirmed before entry and performs an exact protected remote
   digest lookup. It never invokes native prepare, consume, or save, and must
   finish with zero saves, quarantines, or retries. The readback returns an
   opaque proof bound to the exact operation and protected receipt. Only that
   proof may release the receipt. Release consumes the proof, atomically
   compares every durable operation field, and clears the ObjectBox adoption
   marker before idempotently acknowledging the native receipt. If the process
   dies after the durable clear, startup recovery removes the now-unadopted
   receipt while the separate protected payload reference remains live. A
   stale row never loses its marker. Replay cannot silently become initial
   admission or a second create.

Provisioning is tracked as in-flight state. Account reset and teardown wait for
bounded provisioning quiescence, and synchronous disposal refuses to release
native handles underneath provisioning or a protected write.

Recovery and postflight validation use a closed lifecycle relation, not merely
an operation ID. A recoverable initial `pending` row has no Apple submission
UUIDs, lease, confirmation, or retry metadata. A retried `pending` row has both
failure and next-eligible metadata. An `unknownOutcome` row has the exact Apple
request/operation UUID pair, `unknown` failure, and no live lease or
confirmation. A `confirmed` row has that UUID pair and `confirmedAt`, with no
retry metadata or live lease. Postflight may preserve or newly assign the UUID
pair, but once assigned it cannot be cleared or replaced unless authoritative
`notApplied` readback returns the row to `pending`. Unknown recovery can only
confirm while preserving the pair and receipt, return to pending while clearing
the pair after proof and preserving the receipt, or remain unknown while
preserving all evidence. It cannot quarantine. `paused` is rejected until a
separately reviewed paused-resumption protocol exists.

### Canary installation identity boundary

The signed Canary is installed as
`com.bluebubbles.messaging.cloudkitcanary`, separate from Alpha. Its APK does
not contain the registration-relay token. For the owned Mac mini, setup imports
only the app's hardware-only `OABS` profile through Canary onboarding after
installation. Import creates fresh Canary-local UDID and NGM state. It does not
copy Alpha's `hw_info.plist`, Apple session, database, or messages.

Before import, check only Canary's private state. If Canary already has
`files/hw_info.plist`, stop and preserve it rather than re-importing. Keep the
OABS value out of command lines, logs, CI artifacts, and preferences; discard
the temporary transfer after successful onboarding. No setup command may read
or write Alpha's package path.

### Candidate qualification feedback loop

```mermaid
flowchart LR
  S[Freeze candidate SHA] --> A[Independent architecture and safety audit]
  A --> C[Bindings drift check and native compile]
  C --> T[Focused and full automated tests]
  T --> B[Signed Canary build]
  B --> L[One live in-place Canary pull]
  L --> Q[Canary-qualified candidate]

  A -. invariant failure .-> X[Invalidate candidate SHA]
  C -. compile failure .-> X
  T -. behavioral failure .-> X
  B -. package or signing failure .-> X
  L -. runtime or safety failure .-> X
  X --> M[Record root cause and affected boundary in this map]
  M --> F[Apply the smallest fail-closed boundary repair]
  F --> S
```

A passing downstream job never erases an upstream audit failure. Any source
change creates a new candidate SHA and restarts qualification. Failed GCE runs
are allowed to execute their cleanup path, but their APKs are never installed.

### Fast iteration split

```mermaid
flowchart LR
  I[New observation or fixture] --> K{Requires live Apple identity?}
  K -- No --> H[Host or GCE Rust, Dart, and ObjectBox tests]
  H --> R[Protection, decode, projection, checkpoint, and report proof]
  K -- Yes --> W[Private-profile Windows V2 development process]
  W --> P[Hold one interlock and writer pause across up to 16 bounded passes]
  P --> R1[Persist each schema-v5 content-free report before deciding]
  R1 --> S1{Exact zones and every safety gate pass?}
  S1 -- No --> S2[Stop safely; preserve report and durable checkpoints]
  S1 -- Yes --> E{All zones prove a terminal empty server read?}
  E -- No; cap remains --> P
  E -- No; cap reached --> S3[Exit resumable at the durable checkpoint]
  E -- Yes --> Z[Current server head reached; projection reported separately]
  N[Dart code changed] --> D[Windows hot reload]
  D --> W
  V[Rust or bridge code changed] --> B[Incremental Windows DLL rebuild and restart]
  B --> W
  Q[Frozen release candidate] --> C[Build and qualify Android Canary APK]
  C --> L[Final live Pixel proof]
  X[Standalone GCE live client] -. rejected .-> K
```

The live development boundary must own the exact in-process
`CloudMessagesClient`, revocable read-auth generation, cached PCS configuration,
platform secret storage, and writer-pause capability. Windows already provides
current-user DPAPI protection and the production semantic path admits Windows
x64 and ARM64, so a separately identifiable Windows V2 development build can
provide the fast loop without a phone. It must use a private profile and must
never open the Store app's profile concurrently. Dart changes may hot reload;
Rust or bridge changes require an incremental Windows DLL rebuild and process
restart, but an unchanged signed build may use `-SkipBuild` only when its latest
report proves the current source fingerprint and its native DLL signature is
still valid. That guarded path completed in 17 seconds on 2026-08-31, with no
Android APK. Synthetic records, checkpoint state, canonical
conversion, ObjectBox projection, and report logic remain host or GCE tests.
GCE must never become a live CloudKit client because that would require
exporting the Windows profile's credentials, identity, and PCS state. Android
Canary remains the final release proof, not the everyday edit/retry loop.

Initial catch-up is not one unbounded fetch and cannot be inferred from the
number of newly inserted journal rows. A nonempty duplicate CloudKit page may
insert zero rows, so `fetched == 0` is not proof that the server is empty. The
engine now emits `observedEmptyTerminalRead` only after it durably journals a
terminal page and every server page observed in that run contained zero
changes. The schema-v5 report carries that evidence independently for the exact
chat, message, and attachment zones.

[`run_cloud_sync_v2_dev.ps1`](../tooling/windows/run_cloud_sync_v2_dev.ps1)
launches `-Drain` once. The in-process controller repeats the existing
four-page, 50-change-per-page semantic operation, persists every content-free
report before inspecting it, and stops immediately on any status, quarantine,
retry, zone-shape, or outbox inconsistency. It declares remote catch-up only
when all three zones prove an empty terminal read. A 16-pass ceiling bounds one
session to 3,200 observed changes per zone and exits as explicitly resumable,
not complete. One operation interlock and one native-writer pause enclose the
whole loop, including report persistence and terminal acceptance; reopening
writers between one-shot reports is not a valid drain. ObjectBox checkpoints
remain the only cursor state. Local
projection completeness is reported separately because a terminal remote head
may still contain retained evidence awaiting a safe parser or dependency
repair. Focused engine, sampler, report, and controller tests cover duplicate
nonempty pages, terminal evidence, persistence ordering, unsafe-report abort,
overlap, disposal, and the resumable ceiling. The Windows launcher must also
bind status to its exact launch ID and PID, serialize profile launches, treat
the pass cap as non-success, and never force-kill an active native operation on
timeout. Signed Windows live qualification remains pending.

### Two progress clocks

The implementation intentionally has two different progress clocks. They must
not be collapsed into one user-visible "sync complete" state:

1. **Remote-ingestion progress** is the opaque fetched token. It may advance
   only when the current generation has a complete contiguous journal and
   every row is either exactly applied or explicitly `retainedUnprojected`.
2. **Exact-projection progress** is the contiguous applied sequence. It advances
   only across rows whose canonical projection committed atomically.

`retainedUnprojected` therefore prevents a parser or dependency defect from
pinning the remote cursor forever, but it is not success. The protected source,
digest, record mapping evidence, scope, and generation remain durable; the row
is retried locally; and Messages-in-iCloud write admission requires all three
zones to contain only exactly applied rows. Canary reports and future UI must
show fetched, retained, and projected counts separately.

## Source-linked audit

| Boundary | Current source | Required invariant | Status |
| --- | --- | --- | --- |
| Manual admission | [`troubleshoot_panel.dart`](../lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart#L436), [`rustpush_service.dart`](../lib/services/rustpush/rustpush_service.dart#L7448) | User-confirmed Canary entry only; no automatic semantic pull. | `LIVE-PROVEN` |
| Process and database exclusion | [`CloudKitOperationInterlock.runExclusive`](../lib/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart), [`CloudSyncManualSemanticPullSampler.runConfirmedSession`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart) | One CloudKit owner, durable renewing fence, one native-writer pause across all reports/decisions, settlement of any in-flight renewal before exit, direct final fence-state validation, and writer resume in `finally`. | `TEST-PROVEN`; session replacement not yet live-qualified |
| Account-bound read authentication | [`CloudSyncProductionAuthSnapshotProvider`](../lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart#L775), [`cloud_sync_ensure_read_authentication`](../rust/src/api/api.rs#L7520) | Restore or refresh only the active client's revocable read credential; reject a raced session replacement. | `TEST-PROVEN`; persisted restore exercised live |
| Writer-pause capability | [`prepareReadAuthenticationUnderNativeWriterPause`](../lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart#L826), [`NativeProtectedCloudSyncTransport.fetchChanges`](../lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart#L810), [`cloud_sync_warm_read_authentication_under_writer_pause`](../rust/src/api/api.rs#L319) | Exact positive 64-bit token, active interlock, and same client/account before and after warmup. An unbound fetch is legal only for the non-projecting shadow lane; a bound fetch is legal only for the semantic lane. | `TEST-PROVEN; LIVE-PROVEN ON SIGNED WINDOWS ARM64 HARNESS` |
| Exact PCS-zone warmup | [`warm_semantic_read_zone_encryption_configs`](../rustpush/src/imessage/cloud_messages.rs#L2201), [`get_cached_zone_encryption_config_exact`](../rustpush/src/icloud/cloudkit.rs#L3579) | Lookup only `chatManateeZone`, `messageManateeZone`, and `attachmentManateeZone` on the read-auth container. Never create a zone or use the general container. | `LIVE-PROVEN` across all three exact zones |
| Capability-bound protected fetch | [`cloud_sync_fetch_protected_page_under_writer_pause`](../rust/src/api/api.rs#L2190), [`sync_records_page_for_read_authentication`](../rustpush/src/imessage/cloud_messages.rs#L2388), [`CloudSyncEngine._pullChangesWhileStoreExclusive`](../lib/services/rustpush/cloud_sync/cloud_sync_engine.dart#L898) | Semantic fetch must acquire the exact active writer-pause capability, use only the permit-validated cached read-auth container, and hold it through the remote page read. Previous token and generation remain opaque; page, record, byte, and time limits remain enforced. The separate unbound entry point is restricted at composition and transport boundaries to the compile-gated, non-projecting shadow diagnostic. | `TEST-PROVEN; LIVE-PROVEN` for bounded 200-record windows per zone |
| Page adoption and crash recovery | [`CloudProtectedPageLeaseLifecycle`](../lib/services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart#L11), [`journalFetchedBatch`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart#L104) | Protect page before Dart exposure; atomically journal before committing the native page lease. | `TEST-PROVEN`; live reports show admitted pages |
| Same-capability protected decode | [`RustCloudSemanticDecoder`](../lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart#L577), [`cloud_sync_decode_protected_change`](../rust/src/api/api.rs#L3545), [`cloud_sync_decode_transient_record_cached_only`](../rust/src/cloud_sync_transient_bridge.rs#L1605) | Decode uses the same writer-pause permit and exact cached read-auth container/PCS key as fetch preparation. Deterministic nested-protobuf schema failures are malformed retained evidence; actual panics remain internal decoder failures. | `TEST-PROVEN; LIVE-PROVEN` without a page retry barrier |
| Post-decode identity fence and pretransaction recovery | [`RustCloudSemanticDecoder`](../lib/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart), [`CloudPretransactionChatConflictBarrierRecoveryStore`](../lib/services/rustpush/cloud_sync/cloud_sync_store.dart), [`ObjectBoxCloudSyncStore.requeuePretransactionChatConflictBarrier`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart) | Recapture the native client, account, protected-store, and session identity after decode. Any drift stops before projection and is retryable authorization, never semantic conflict. The migration may reopen only the first current-generation `chatManateeZone` save that an older build quarantined as conflict before a transaction, with retry count exactly one, a fixed historical cutoff, an active coordinator fence, protected source intact, and no replay or record mapping. It does not change a checkpoint, token, source, digest, or prior attempt. | `TEST-PROVEN`; 237 focused decoder, engine, and ObjectBox tests pass; device replay pending |
| Canonical conversion | [`cloud_sync_canonical_converter.rs`](../rust/src/cloud_sync_canonical_converter.rs), [`parse_associated_parent`](../rust/src/cloud_sync_canonical_dto.rs#L2023) | Preserve wire presence, reject malformed identity, and do not invent clear/delete semantics. | `TEST-PROVEN`; representative records decoded live |
| Ordered local projection | [`TransactionalCloudInboxApplier`](../lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart#L866), [`ObjectBoxCanonicalSemanticEntityAdapter`](../lib/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart#L204), [`ObjectBoxCloudSemanticStoreGateway`](../lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart#L305) | One local transaction records canonical state, replay metadata, record mapping, and terminal inbox state. Chat aliases precede messages; messages precede reactions and attachments. | `LIVE-PROVEN`, with remaining unsupported fields/attachments retained |
| Pre-digest ownership repair | [`TransactionalCloudInboxApplier.repairLegacyOwnershipEvidence`](../lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart), [`ObjectBoxCloudSemanticStoreGateway.repairLegacyOwnershipEvidence`](../lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart), [`ObjectBoxCanonicalSemanticEntityAdapter.proveLegacyCanonicalOwnership`](../lib/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart) | Run locally before transport under the current coordinator fence. Admit only a current applied save with unique replay, current record map, exact protected re-decode, exact stored snapshot, and exact immutable canonical identity. Cover every historically writable kind: chat, message, reaction, and attachment. Require reaction parents and attachment owners to resolve through an exact durable Message-zone owner in the current account and dependency generation. Update only `canonicalGuidHash` plus `canonicalGuidLookupHash`; never mutate canonical rows, aliases, inbox, replay, checkpoint, token, outbox, or transport state. The global null-owner barrier remains until every legacy owner in that scope is proven. | `TEST-PROVEN`; GCE and signed Canary proof pending |
| Pre-semantic canonical bootstrap | [`CloudLegacyCanonicalOwnershipProofAdapter.provePreexistingCanonicalOwnership`](../lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart), [`ObjectBoxCanonicalSemanticEntityAdapter.provePreexistingCanonicalOwnership`](../lib/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart), [`_ObjectBoxCloudSemanticStoreTransaction.applyEntity`](../lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart) | Use only after the normal ownership check reports `canonical_identity_owner_unproven`, only when no semantic snapshot exists for the incoming logical key, and only when the exact canonical row predates V2. Require the transient decoded owner plus exact immutable canonical identity. A null legacy Chat style is missing mutable projection state, not contrary identity; any non-null style must still equal the decoded direct/group style and the canonical upsert fills a null style atomically. Stage both ownership digests on the incoming snapshot in the same write transaction, rerun the full global ownership check, then atomically commit canonical state, snapshot, map, replay, inbox terminal state, and checkpoint. A missing row follows the ordinary create path; any partial, unrelated, ambiguous, cross-kind, mismatched, or competing ownership evidence remains blocking and rolls back the provisional proof. | Circular dependency and nullable-style cause `LIVE-PROVEN`; corrected candidate analyzer clean, GCE pending |
| Legacy unknown-row retry | [`CloudUnknownInboxBarrierRecoveryStore`](../lib/services/rustpush/cloud_sync/cloud_sync_store.dart#L290), [`ObjectBoxCloudSyncStore.requeueUnknownInboxBarrier`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart#L974) | Reopen only the first unresolved current-generation save in the still-pending batch, only if it predates the fixed migration cutoff. Preserve retry history, protected reference, digest, checkpoint, and token. Reject tombstones and preflight failures. | `TEST-PROVEN`; bounded one-time migration, not a general fallback |
| Retained projection repair | [`TransactionalCloudInboxApplier.reprojectRetainedUnprojected`](../lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart#L894), [`CloudRetainedProjectionStoreGateway`](../lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart#L797) | Candidate selection is scope- and generation-bound. A retained row becomes applied only in the same transaction that commits its complete canonical projection; failures rotate fairly without changing token or source evidence. | `TEST-PROVEN`; exercised live with unresolved rows remaining |
| Cursor promotion | [`_promotePendingFetchedTokenIfTerminalLocked`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart#L2456) | Promote the pending token only when every sequence exists and is terminal. `retainedUnprojected` may release fetch progress but remains repairable and never counts as fully applied. | `TEST-PROVEN`; exercised live |
| Honest Canary completion | [`CloudRetainedUnprojectedBacklogStore`](../lib/services/rustpush/cloud_sync/cloud_sync_store.dart#L290), [`ObjectBoxCloudSyncStore.readRetainedUnprojectedInboxCount`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart#L752), [`CloudSyncManualSemanticPullSampler`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart#L285), [`cloudSyncV2SemanticCanaryPresentation`](../lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart#L46) | Read the current-generation durable retained backlog after repair attempts, then sum it across all zones. A zero per-run transition count is insufficient. Report `Complete` only when the original three-zone/status/quarantine/retry/write-tripwire gates pass and durable retained count is zero; a completed read with retained evidence is degraded/`Partial`, while a blocking failure is `Stopped Safely`. | `TEST-PROVEN; LIVE-PROVEN` |
| Token-expiry reset | [`CloudSyncStore.rebootstrapAfterReset`](../lib/services/rustpush/cloud_sync/cloud_sync_store.dart#L150), [`ObjectBoxCloudSyncStore.rebootstrapAfterReset`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart#L1312) | Obtain an account-bound remote-reset proof, quiesce the coordinator, atomically fence old evidence, increment generation, and restart from no token. The coordinator must also prove how unresolved old-generation saves and tombstones remain repairable or are reconciled by the full refetch. | `GAP / POLICY DECISION`: durable primitive exists, but production orchestration has no caller and current-generation reprojection cannot consume generation-zero evidence |
| No-write exit tripwire | [`CloudSyncManualSemanticPullSampler._runConfirmedUnderInterlock`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart#L194) | Remote confirmations remain zero, outbox count is unchanged, active identity is revalidated, native operations quiesce, and writers resume. | `LIVE-PROVEN` |
| Manual writer admission | [`troubleshoot_panel.dart`](../lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart), [`CloudSyncManualOutboundCanary.runDoubleConfirmed`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart), [`CloudKitOperationInterlock`](../lib/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart) | Expose controls only in the compile-gated Android Canary. Initial create, interrupted recovery, and confirmed-only replay are separate two-confirmation lanes. Consume the confirmation before the first await, then hold one durable `v2ReadWrite` exclusion across fresh candidate or exact-operation revalidation, the second preflight, admission or reconciliation, one-row flush, terminal checks, and native quiescence. | `TEST-PROVEN`; live write pending |
| Exact local candidate binding | [`CloudSyncOutboundCanaryCandidateSelector`](../lib/services/rustpush/cloud_sync/cloud_sync_outbound_canary_candidate.dart), [`RustPushService.armCloudSyncV2OutboundConfirmed`](../lib/services/rustpush/rustpush_service.dart) | Query only the newest outgoing row. Require one fresh ordinary one-to-one iMessage text with no subject; never fall back. Require canonical persisted endpoint forms and exact agreement with the operator-entered recipient across chat GUID, chat identifier, and sole participant, plus a current IDS sending handle. Validate the encoded `CloudMessage` service, type, error, chat ID, sender, destination caller ID, and GUID against that route. Re-read current IDS handles and the exact row before arming and once more inside the final run exclusion; require the same private SHA-256 binding over content, route, time, and state. Keep the binding, body, recipient, and handles out of diagnostics. | `TEST-PROVEN`; live write pending |
| Writer provisioning quiescence | [`RustPushService.prepareCloudSyncV2OutboundWriter`](../lib/services/rustpush/rustpush_service.dart), [`RustPushService.resetAppleState`](../lib/services/rustpush/rustpush_service.dart), [`RustPushService.onClose`](../lib/services/rustpush/rustpush_service.dart) | Arm before provisioning. Track the provisioning future, reject concurrent admission, wait boundedly during account reset, and never dispose native handles underneath provisioning or an active write. | `TEST-PROVEN`; live write pending |
| Recovery and no-save replay | [`CloudSyncManualOutboundCanary.armRecoveryConfirmed`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart), [`CloudSyncManualOutboundCanary.armConfirmedReplay`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart), [`CloudKitWriterMutationGuard.reconcileUnknownOutcome`](../lib/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart), [`NativeProtectedCloudSyncTransport.releaseConfirmedReplayReceipt`](../lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart) | Recovery snapshots the complete exact durable row and passes its explicit kind plus snapshot to a disjoint session factory. Pending resubmission, unknown readback, and confirmed replay cannot be cast into one another. The unknown lane constructs no engine, admission coordinator, write transport, writer permit, prepare, consume, conflict merge, quarantine, or delete capability. Guard-owned native readback is exhaustive: committed carries an exact create receipt into the atomic record-map plus outbox commit while preserving UUIDs and the protected receipt; a missing or mismatched receipt stays unknown with backoff; proven-not-applied clears UUIDs only after proof while preserving the receipt and returning pending; divergent, unresolved, quarantined-envelope, and exception outcomes remain unknown and preserve UUIDs, receipt, and fence. ObjectBox reopen tests pin that evidence across restart. Confirmed replay remains exact no-save proof and is the only lane that can release a retained receipt after exact durable comparison. | `TEST-PROVEN`; live write pending |
| Revocable write authority | [`CloudKitWriterMutationGuard`](../lib/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart), [`NativeProtectedCloudSyncTransport`](../lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart), [`CloudMessagesWriterPreparationBinding`](../rustpush/src/imessage/cloud_messages.rs) | Every native writer boundary requires `v2ReadWrite`. Account, exact Dart transport client object, store, epoch, and exact cached writer-container instance must remain exact before and after action. Timeout poisoning is rechecked after asynchronous identity capture and before mutation state can be armed. Ambiguity moves authority from stable epoch `E` to `mutationUnknown` at `E+1`; exact committed/not-applied readback reconciles to stable `E+2`, while unresolved evidence remains fenced at `E+1`. Fence schema v3 binds the exact lowercase reconciliation SHA-256 before and after native submission. | `TEST-PROVEN`; live write pending |
| Exact prepared-handle capability | [`CloudKitWriterMutationGuard`](../lib/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart), [`cloud_sync_consume_prepared_message_create`](../rust/src/api/api.rs) | Every native prepared handle owns a content-free random SHA-256 binding. The durable fence must contain that exact binding plus the capability digest, account, store, owner, and scope. A capability/fence for one prepared handle cannot consume another, and a rejected attempt does not consume either handle. | `TEST-PROVEN`; live write pending |
| Cross-language operation identity | [`CloudOperationIdentity.forInitialCreate`](../lib/services/rustpush/cloud_sync/cloud_operation_identity.dart), [`initial_message_create_operation_id`](../rust/src/cloud_sync_outbound.rs) | Dart and Rust must hash the same semantic persistence lane and payload schema version. The semantic/payload-V2 synthetic fixture is pinned on both sides; a legacy-lane or V1 operation ID cannot enter a V2 prepared envelope. | `TEST-PROVEN`; live write pending |
| Exact first-create proof | [`NativeProtectedCloudSyncTransport.prepareSubmission`](../lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart) | Use the native exact record lookup before prepare. Only exact NotFound may create; exact digest match is a no-save confirmation with the exact server-record and ETag receipt; divergence conflicts; unresolved proof stays pre-submit. Mixed batches must partition exactly into remote operations and preconfirmed receipts, with no duplicate or missing operation ID. | `TEST-PROVEN`; GCE and live write pending |
| Create-only race handling | [`NativeProtectedCloudSyncTransport.consumePreparedSubmission`](../lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart) | Persist the ambiguity boundary before consume and correlate the complete operation set. After capability consumption, every non-confirmed result is durably `unknownOutcome` with its diagnostic failure category retained; a create conflict cannot quarantine, update-merge, or automatically replay until exact readback proves the outcome. | `TEST-PROVEN`; live write pending |
| Exact create-receipt commit | [`CloudSyncEngine._commitConfirmedCreateReceipts`](../lib/services/rustpush/cloud_sync/cloud_sync_engine.dart), [`CloudSyncStore.commitOutboxCreateReceipt`](../lib/services/rustpush/cloud_sync/cloud_sync_store.dart), [`CloudMessagesSaveReceipt`](../rustpush/src/imessage/cloud_messages.rs) | A confirmed create requires one content-free receipt bound to the operation, logical entity, full server record, and ETag. The current-generation record map must already bind that server hash. Mapping ETag and outbox confirmation commit atomically. Missing or mismatched proof stays reconciliation-only. A mid-batch local failure acknowledges only the durable terminal prefix; no uncommitted suffix receipt is released or resubmitted. | `TEST-PROVEN` locally; GCE ObjectBox/Rust qualification and live write pending |

## Recovery policy

| Failure | Safe lane | Current audit |
| --- | --- | --- |
| Read credential cold or revoked | Warm in-memory credential, otherwise restore encrypted same-account credential, otherwise perform one bounded same-account refresh. Pause and require explicit user action after that. | Implemented and tested; current capability-bound fetch and decoder handoffs await live proof. |
| Account/client changes mid-run | Stop before projection or acknowledgement under the old identity and preserve journal, protected source, and checkpoint. Report a bounded content-free authorization reason so ordinary retry can reacquire stable identity. An older pretransaction `conflict` is eligible for the single-use Chat-only migration only when no projection evidence exists. | Implemented at sampler, transport, decoder, projection, and bounded migration boundaries; focused tests pass, device replay pending. |
| PCS key unavailable | Lookup exact cached zone config, then one bounded same-scope warm/refresh. Retain the raw protected record and checkpoint evidence if unavailable. | Exact lookup repaired; live proof pending. |
| Network or server failure | Preserve prior token, record bounded backoff, honor server retry-after, and retry later. | Implemented. |
| Throttling | Honor bounded retry-after and do not spin or clear state. | Implemented. |
| Missing chat/message dependency | In the developer-only read-only Canary, a recognized dependency code may immediately become `retainedUnprojected`; ordinary sync requires the bounded attempt-and-age policy. Keep protected evidence and retry ordered projection after the parent or parser repair exists. | Implemented and compile-time/configuration gated away from write-capable sync. |
| Typed message-to-chat route | Preserve each canonical chat GUID owner. Exact canonical ownership is considered first and must agree with every present route-specific proof. When exact ownership is absent, an authenticated-service direct composite `chatID` (`<service>;-;<cid>`) may fall back only to the one-to-one `serviceIdentifier` owner; an authenticated-service group composite (`<service>;+;<gid>`) may fall back only to one validated current `groupId` owner whose projected chat has group style 43. A bare `chatID` is ambiguous and must be adjudicated by exact ownership plus chat style, a unique style-45 service owner, or a unique style-43 current-group owner. Disagreement, duplicate current-group owners, a foreign or structurally invalid composite, or a direct-style current-group owner is a conflict or malformed record. `originalGroupId`, legacy aliases, and `msgProto4.groupId` remain diagnostic-only and can neither select nor veto an owner. | `LIVE-PROVEN ON SIGNED WINDOWS ARM64`: route-kind selection is unit-proven across bare and composite direct/group variants, collisions, disagreement, malformed composites, and foreign service prefixes. The first signed route replay applied 56 of 59 decoder-ready messages: 46 through the unique current `groupId` owner and 10 through exact GUID ownership. Three unavailable routes remained retained, no route conflict was reported, remote saves/deletes stayed disabled, and the outbox remained `0 -> 0`. Legacy `alias1` rows remain preserved but non-authoritative. |
| Malformed or unsupported record | Persist a fixed content-free reason. Retain or quarantine according to whether a future parser can safely repair it; never guess identity or deletion. | Implemented, but every new reason needs an explicit repairability classification. |
| Tombstone in read-only Canary | Retain as unprojected evidence. Do not delete a local message and do not issue a remote delete. | Implemented and write-gated. |
| Process death after fetch | Recover/rollback the native page lease, replay the durable journal, and keep the previous token until the journal is terminal. | Implemented and crash-tested. |
| Change token expired | Verify same account and server reset condition, obtain a protected reset proof, stop all coordinators, atomically increment generation and fence old rows, then refetch. Before activation, define reconciliation for retained saves and tombstones from the old generation so evidence is not merely preserved but stranded. Never merely clear the token. | Primitive exists; production decision/orchestrator and cross-generation reconciliation policy are missing. |
| Attachment body unavailable | Project validated metadata first; materialize through bounded native MMCS work later. Retain inline bodies until a proven native path exists. | Partial implementation; not a release blocker for text/history if represented honestly. |
| Live message delivery | IDS/APNs continues independently of CloudKit archive repair. CloudKit work must never block receive readiness. | Architectural invariant; covered by the critical-path map. |

## Explicitly forbidden fallbacks

The following are not recovery mechanisms:

- using a general or write-capable CloudKit container when the read-auth
  container is cold;
- authenticating or decoding under a different account, client, credential
  generation, writer-pause token, protected-store identity, zone, or checkpoint
  generation;
- invoking `ZoneSaveOperation`, PCS creation, keychain clique reset, or remote
  record mutation from the semantic read path;
- silently enabling the legacy CloudKit path after a V2 failure;
- clearing a token because an error is unknown, malformed, or inconvenient;
- treating `retainedUnprojected` as a successful local projection;
- advancing past an incomplete or nonterminal page journal;
- deleting local messages for tombstones during the read-only Canary;
- allowing optional CloudKit work to delay IDS/APNs startup or acknowledgement.

## What likely matches Apple's engineering model

This section separates public evidence from inference. It does not claim that a
patent or public framework describes the private Messages implementation.

### Direct public evidence

- Apple documents `CKSyncEngine` state as opaque state that the client persists;
  it includes server change tokens and pending work. Account changes and fetched
  record-zone changes are explicit events.
- `CKFetchRecordZoneChangesOperation` uses per-zone opaque tokens and delivers
  successive batches. A client caches tokens on disk and must not infer their
  contents or ordering.
- Apple Platform Security describes private CloudKit data as protected by a
  per-user hierarchy, with record keys generated on trusted devices and wrapped
  into that hierarchy.
- Apple's CKSyncEngine sample persists local changes before queuing upload,
  applies remote modifications/deletions to its local store, and retains
  last-known server records for conflict handling.

Primary references:

- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- [CKSyncEngine.State](https://developer.apple.com/documentation/cloudkit/cksyncenginestate)
- [CKFetchRecordZoneChangesOperation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation)
- [Apple Platform Security: iCloud encryption](https://support.apple.com/guide/security/icloud-encryption-sec3cac31735/web)
- [Apple sample: CKSyncEngine](https://github.com/apple/sample-cloudkit-sync-engine)

### Architectural inference

The most plausible Apple-style design is a small number of independently
recoverable state machines:

1. account/trust establishes a revocable read capability;
2. a per-zone replication engine durably ingests opaque changes and tokens;
3. PCS resolves record keys under the same account/trust generation;
4. a local semantic projector applies records in dependency order;
5. live IDS/APNs delivery remains independent from archive reconciliation;
6. reset or account-change events create a new generation rather than mutating
   old evidence in place.

That model explains why one malformed or temporarily undecryptable record
should become durable repair work instead of forcing the server cursor backward
forever. Our journal, protected page lease, retained-unprojected state, and
generation fence already approximate this model. The read-capability handoff is
now repaired in source for both fetch and decode, but still needs generated-
binding and live proof. The missing production reset orchestrator remains the
major unimplemented state transition.

## Patent evidence rules

Apple patent records are useful for vocabulary, component boundaries, and
possible failure-state designs. They are not proof that current iOS, CloudKit,
PCS, or Messages uses the disclosed embodiment. Patent evidence must therefore
be recorded as:

```text
publication + family
  -> exact claim, paragraph, or figure
  -> direct disclosed mechanism
  -> narrow architectural inference
  -> source/code boundary it may inform
```

Do not copy patented implementation expression into the product. Prefer public
API behavior, device evidence, clean-room protocol facts, and independently
designed state-machine logic. No patent-derived inference is a code requirement.

### Patent ledger

| Publication/family | Direct disclosure | Narrow inference for this design | Explicit limit |
| --- | --- | --- | --- |
| [US10742732B1, Cloud storage and synchronization of messages](https://patents.google.com/patent/US10742732B1/en), continuation [US11190586B2](https://patents.google.com/patent/US11190586B2/en); Apple; priority 2017-03-02 | Claims 14-16 and Figures 3-6 describe a temporary delivery store separate from a long-term archival “truth zone,” bounded batches instead of a whole database, conversation state before message batches, stable cross-device record identifiers for duplicate avoidance, per-device time tags (claims 7 and 19), and recent-first recovery in Figure 5C. | Keep live delivery separate from archival restore; process chat/conversation identity before messages; deduplicate by stable record identity; retain per-device opaque progress; consider recent-first initial backfill only as a later optimization. | It does not disclose the private CloudKit protobuf, current Manatee schema, PCS, or exact server cursor semantics. “Truth zone” is not proof of a CloudKit zone name. |
| [US11012428B1, Cloud messaging system](https://patents.google.com/patent/US11012428B1/en) and its family; Apple; priority 2017-03-02 | The abstract, Figures 10, 14A-C, 16-17, and claims 1, 6, and 8 describe application-specific isolated containers, a user-private encrypted container, public/private databases, an account zone with short- and long-term records, and encrypted attachment assets addressed separately from access records. | Bind message reads to one application/account container. Keep protected record metadata separate from attachment bytes, and fail closed when expected read identity is unavailable. | It does not prove CloudKit, PCS, MMCS, current zone names, exact asset fields, or current credentials. Its cryptographic deletion is not a sync tombstone. |
| [US20160352518A1, Backup system with multiple recovery keys](https://patents.google.com/patent/US20160352518A1/en), issued as [US9904629B2](https://patents.google.com/patent/US9904629B2/en); Apple; priority 2015-05-31 | Section V, Figures 19-20, and claims 1, 6, 9, 11, and 13 describe a service identity that unlocks a container private key, then a zone private key, then a per-record key, plus separately wrapped device recovery material. | This is the strongest patent support for the capability chain `service identity -> container key -> zone key -> record key`. A successful account login does not prove the active device has the correct content-key generation. | It does not prove the PCS name/current API, current CKKS/Octagon recovery, Messages-specific service identities, or cached-only production behavior. |
| [US20140281540A1, Keychain syncing](https://patents.google.com/patent/US20140281540A1/en), issued as US9197700B2; Apple; priority 2013-01-18 | Figure 3 and claims 1, 4, 6, and 11-20 describe signed sync-circle membership, authenticated join approval, and keychain/private-key synchronization only among admitted devices. | Model trust membership and content access as revocable generations. Bind cached key material to the exact client/account generation and pause rather than substituting a broader identity. | It is a trust-state pattern, not proof of current iCloud Keychain, Octagon, CKKS, PCS, or Messages recovery policy. |
| [US7747784B2, Data synchronization protocol](https://patents.google.com/patent/US7747784B2/en), publication US20090228606A1; Apple; priority 2008-03-04 | Figures 30-31 and 41-43 and claims 1-5 describe opaque checkpoint anchors, persistence after interruption, explicit expired-anchor reset/slower synchronization, add/modify/delete changes, conflict resolution, and two-sided anchor commit. | Keep progress opaque and scope-bound; advance only after durable processing; handle token expiry through an explicit generation-scoped rebootstrap, not an unproved cursor clear. | It is generic synchronization evidence, not CloudKit, Messages, PCS, or `CKServerChangeTokenExpired` semantics. |
| [US20100198784A1, Reusable state information for synchronization and maintenance of data](https://patents.google.com/patent/US20100198784A1/en) and family; Apple; priority 2004-07-01 | The specification and claim 1 describe durable deleted/soft-deleted history, ancestry for conflict analysis, and garbage collection only after known peers no longer require the state. | Retain deletion evidence and prior record mappings until local deletion is safely projected and the relevant consumers have crossed the state. | It is tombstone-like generic sync evidence, not a CloudKit or Messages tombstone schema. |
| [US8589680B2, Synchronizing encrypted data on a device having file-level content protection](https://patents.google.com/patent/US8589680B2/en); Apple; priority 2010-04-07 | Synchronization initialization retrieves an escrow keybag, derives/decrypts protection-class keys from a sync ticket, and only then synchronizes protected data. | Authentication, protected-key warmup, and semantic decode are distinct gates. The same-permit PCS warmup remains necessary even after account login succeeds. | The file-protection mechanism predates current CloudKit/PCS and supplies no private Messages wire facts. |

The first family is the most useful message-specific result. The recovery-key
family supplies the strongest key-hierarchy analogy, and the older generic sync
families support explicit reset and conservative deletion-history handling.
Together they reinforce, but do not prove, this composite architecture:

```text
trusted/recovered service identity
  -> cached application container key
  -> exact zone key
  -> per-record key
  -> record or attachment decode
  -> stable-identity reconciliation or retained deletion evidence
  -> committed protected checkpoint
```

None of these patents justifies replacing opaque CloudKit tokens with
timestamps, inferring private field names, resetting trust from a read path, or
enabling writes.

## Release gates derived from the map

1. Generated bridge bindings expose the separate writer-pause-bound protected
   fetch and include the writer-pause token on protected decode, with no
   unrelated drift. Dart also rejects a semantic-lane fetch before the bridge
   when the exact writer-pause capability is absent, and rejects a bound fetch
   for every non-semantic persistence lane.
2. Focused Dart, Rust, rustpush, protector, and source-contract tests pass.
3. A cold-start integration test executes this exact chain in one process:
   `restore/refresh auth -> pause writers -> warm three PCS zones -> fetch ->
   decode with same permit -> journal -> project -> promote token`.
4. Synthetic token-expiry validation proves no automatic clear and then tests
   the approved generation-scoped rebootstrap workflow.
5. Crash injection covers fetch-before-journal, journal-before-lease-commit,
   projection-before-terminal-mark, and terminal-mark-before-token-promotion.
6. Account replacement at every external wait fails closed and preserves old
   evidence.
7. A signed in-place Canary run preserves `firstInstallTime`, creates exactly
   one report for the invocation, restores representative text/reaction/link
   records, and reports zero remote writes/deletes and outbox `0 -> 0`.
8. A second pull is idempotent: no duplicate canonical rows, no skipped page,
   and no repeated projection except explicitly retained repair work.
9. Reports distinguish remote-ingestion completeness from exact-projection
   completeness. Their retained count is the durable current backlog after
   repair attempts, not the number newly retained during this invocation.
   Production readiness requires that backlog to be zero or to have an
   explicitly reviewed, non-destructive repair policy.
10. The fixed-cutoff legacy unknown-row migration is removed after affected
    Canary databases have been retried, or remains covered by a source-contract
    test proving it cannot touch a newer row, tombstone, preflight failure,
    checkpoint, token, protected reference, or payload digest.
11. Every writer bridge boundary rejects calls without the exact active
    `v2ReadWrite` interlock or digest-bound mutation capability. The retained
    native preparation binding must still match the exact cached container
    instance immediately before and after submission; collision and same-user
    replacement tests fail before admitting a normal retry.
12. First-create tests cover exact absence, exact existing digest, divergence,
    indeterminate proof, swapped proof references, create races, and restart
    reconciliation after a persisted ambiguity boundary.
13. The first live write is one plain-text Canary message to the explicit test
    recipient. A confirmed-only replay of that exact durable operation must
    perform no save, and content-free
    evidence must prove one remote record, one local terminal operation, no
    delete, no update merge, and no automatic replay.

## Current critical path

Do not broaden scope to FaceTime, Find My, Windows ARM, or SMS/RCS while this
sequence is active. Keep the working read path and identity intact:

1. Finish exact-source GCE qualification. Final-admission and native capability
   tests passed on `7db9ed89b`; APK packaging failed with no underlying cause
   in the default log. The next pilot captures the full packaging stack and
   disk state. Keep live credentials out of GCE and do not skip native tests.
2. Include the tested settled-outbox repair in that qualification. The Windows
   real-ObjectBox read/receipt/restart/read sequence passes with synthetic
   transport; pending, unknown, invalid and unreconciled work still blocks.
   This local proof does not replace exact live remote readback/no-save replay.
3. Exercise one explicitly confirmed text create on Canary, followed by exact
   readback and no-save replay. Verify the text on the other Apple client and
   prove no duplicate. Keep Alpha untouched and remote deletes disabled.
4. Connect the normal composer/local save to durable V2 outbox admission in one
   transaction. Add one account-scoped foreground sync coordinator for wake,
   reconnect, and pending work; reuse tested engines rather than a parallel
   implementation. Keep read versus IDS live delivery distinct.
5. Give explicit media requests a safe turn between bounded catch-up batches.
   Verify a gallery HEIC, a recent GIF, and swiping on Android. Retain honest
   unavailable state for genuinely absent historical assets.
6. Qualify restart, interrupted read/write, lease loss, account switching,
   expired tokens, and locked/background execution. Only then activate the
   dormant Android scheduling adapter. Measure user-visible progress and
   resource use, not just fetched counts.
7. Release narrowly documented capabilities. Tombstones and outgoing edits /
   unsends require their own causal and anti-resurrection proof; initial text
   create support must not be advertised as complete Messages parity.

### Historical bounded live proof

The signed Windows ARM64 harness completed a clean rebuild in 99.7 seconds on
2026-08-31 after bridge regeneration. Its first replay projected 143 chats but
retained all 110 decoder-ready messages. Content-free cardinality diagnostics
then proved the actual precedence defect: 109 messages had one exact,
ownership-proven `chatID == Chat.guid` owner, while `msgProto4.groupId` resolved
to no `CloudChat.gid` owner for all 110 and incorrectly erased those exact
matches during intersection.

The first repair made exact GUID ownership decisive. The next signed Windows
ARM64 replay built incrementally in 40.1 seconds, projected all 109 exactly
proven messages, and consequently projected six attachment records. A static
follow-up audit then found that a unique weak group-lineage claim could still
select a chat when exact proof was absent. The resolver is now stricter: only
exact GUID ownership or the one-to-one strong `serviceIdentifier` binding may
select a chat, disagreement is a conflict, and group lineage plus
`msgProto4.groupId` are diagnostic-only. Unit tests cover exact precedence,
strong fallback, strong-path disagreement, and weak-only failure; a signed
replay of this stricter boundary completed after a 41.7-second incremental
build. Of 81
decoder-ready records in the next bounded message page, 77 had exact current
ownership and were projected. Four lacked exact or strong-service ownership
and remained retained; one of those had a unique weak group/lineage claim that
the resolver deliberately refused to promote. Nine attachment records then
reprojected after their message parents became available. Remote saves, remote
deletes, automatic triggers, and tombstone semantic deletes remained disabled,
and the outbox stayed `0 -> 0` throughout.

The next resolver revision promotes only the protocol-defined current route:
exact ownership is considered first, authenticated-service direct composites
fall back to `serviceIdentifier`, and group composites fall back to the current
`groupId`. Bare identifiers remain explicitly
ambiguous until exact ownership and chat style, a unique style-45 service
owner, or a unique style-43 current-group owner resolves them. It still
resolves exact, service, and current-group ownership independently and fails
closed if they disagree, if a current group ID has multiple owners, if it
points to a direct-style chat, or if a composite carries a foreign service
prefix. `originalGroupId`, legacy aliases, and `msgProto4.groupId` remain
unable to select a chat even when all three agree. Seventy-four focused adapter
tests and the 1,016-test Cloud Sync suite pass. Exact source commit
`115ee3432d1e4a6087857f23e2f654e4d5713d53` then passed the full GCE producer,
binding-reproducibility, Dart, Rust, rustpush, protector, native-library,
GitHub-hosted signing, runner-deregistration, and VM-deletion gates in run
`33386865466`.

The signed Windows ARM64 route replay completed after a 104.0-second rebuild.
It fetched 100 message changes and applied 56 of the 59 decoder-ready records:
46 used `canonical_message_chat_reference_current_group_id`, 10 used
`canonical_message_chat_reference_exact_guid`, and three unavailable routes
remained retained. No route-conflict diagnostic appeared. Remote saves, remote
deletes, automatic triggers, and tombstone semantic deletes remained disabled,
and the outbox stayed `0 -> 0`. The durable message backlog is still 144,
including 21 retained malformed decoder records and 98 retained unsupported-
service records; attachment projection also remains dependency-limited. The
local harness report labels the checkout dirty because unrelated pre-existing
worktree edits were present, so the exact-SHA GCE result remains the clean
source qualification and Android must be built from that exact committed SHA.

The deterministic decoder-retention repair at source commit
`3366f1fc6979dcb45ca09557f3f1dcdf66e9addf` then passed bridge
reproducibility, the full Dart suite, Rust, rustpush, the protector harness,
Canary APK/native-library verification, GitHub-hosted signing, runner
deregistration, and VM deletion in GCE run `33389976371`. The local Windows
ARM64 fast loop rebuilt that revision in 44.5 seconds. Its first semantic pull
reported zero retries and retained the unsupported reaction shape under its
exact safe code instead of collapsing it to an unknown failure. A no-build
follow-up completed in 13.2 seconds with all remote-write/delete tripwires
still disabled and the outbox unchanged at `0 -> 0`.

That no-build replay applied eight of 39 decoder-ready iMessage records. Seven
resolved by exact GUID and one by the current group ID. The other 31 all used
bare `chatID` syntax and had no exact, raw-service, current-group, lineage, or
`msgProto4` owner. They showed no collision, conflict, or retry. The next
mapped experiment is therefore observational: for a bare `chatID`, derive the
service-qualified direct-CID alias (`iMessage;-;<bare>`) inside the native
authenticated boundary and report only whether it maps to zero, one style-45,
multiple, or wrong-style owners. It must not select an owner until live replay
proves the interpretation and disagreement rules are reviewed. SMS, MMS, and
RCS rows remain preserved evidence but are outside iMessage projection and
release-completion counts.

### Isolated full-history compatibility and presentation proof

The later full-drain analysis found that the remaining projection gap was not
one universal missing alias. It was a mixed-service history boundary: current
Android state can own a group as SMS while older CloudKit records for that same
group remain iMessage. Promoting every opposite-service alias would merge
unrelated direct chats, so the compatibility rule is intentionally narrow.

An historical iMessage may use one current SMS group owner only when all of
these facts hold at once:

1. exact, strong-service, current-group, weak-lineage, and `msgProto4` owners
   are absent in the iMessage namespace;
2. the reference is not a direct route;
3. the opposite-service `serviceIdentifier` owner is absent;
4. the opposite-service current `groupId` has exactly one owner; and
5. that owner is a style-43 group chat marked `isRpSms`.

Every other opposite-service shape fails closed. SMS message bodies and all RCS
rows remain outside this iMessage release. The converter keeps SMS `CloudChat`
metadata typed as SMS so the resolver can prove this boundary without
pretending that SMS message content belongs to CloudKit V2.

The rule was exercised only on a disposable copy of the drained Windows
profile. One build-and-drain recovered 311 messages and 133 attachment metadata
rows. The copy then contained 668 chats, 12,569 messages, and 2,370 attachments.
It had zero messages without chat owners, zero replay-added messages without
renderable content, zero cross-kind ownership mismatches, and outbox zero. The
one contentless non-CloudKit row was already present in the protected source.
The source and copy both retained exactly 78 legacy messages at risk of an empty
attachment placeholder and 137 missing referenced attachment rows across 90
messages, proving the replay did not create that backlog.
Recognized URL counts rose with the recovered messages, while parser mismatch
remained zero. Rich link-preview payload projection remains a separately
measured test-proven repair until a fresh replay populates those payloads.

The attachment-body lane then completed one bounded live proof on this copy.
All 262 current-provenance rows resolved to their exact durable source; 115
were materializable and 147 remained explicitly metadata-only. The smallest
candidate transferred 1,150 authenticated bytes through exact CloudKit record
read, ETag binding, PCS decrypt, MMCS response handling, Ford V2 chunk
authentication, and atomic placement. The root defect was destination code
revalidating already source-authenticated Ford plaintext as a legacy
double-SHA chunk. The repaired destination-only mode cannot be used as a
source and preserves the V1, V2, and legacy source checks. A repeat production
adapter call returned `alreadyReferenced=true`, left the content digest and
modification time unchanged, created no materialization partial, and left zero
intermediate stage rows plus one final `referenced` row.

A second no-build drain applied zero messages and zero attachments. It repaired
zero chat-order rows, made no remote save or delete, and left the same canonical
counts. The remaining 181 route-unavailable records stay durably retained
because they lack sufficient ownership evidence; the projector neither guesses
an owner nor advances by discarding them.

Before and after this experiment, the protected source profile contained
48,319 files totaling 304,413,096 bytes and had the same SHA-256 tree digest.
This proves the experiment did not mutate the real Windows profile. The signed
read-only list and automatic detail viewers both reached ready state and stayed
responsive. Message content was used only inside the local rendering boundary
and was not emitted into reports, diagnostics, or this document.

The projection also exposed a presentation invariant that protocol tests had
missed. All 545 chats with visible messages had a null denormalized latest-
message date. The local-only repair set all 545 to their exact latest visible
message instant, with zero null, behind, or ahead values. Its second run changed
zero rows. New semantic message writes now maintain the same field
monotonically, and Android catch-up runs the repair before refreshing the chat
list.

The next release gates are therefore smaller and explicit:

1. pass the full Dart, Rust, rustpush, protector, PowerShell, analyzer, binding,
   and native-library qualification on one clean source commit;
2. install that exact signed Canary without clearing its protected state;
3. run bounded catch-up and require visible, correctly ordered conversations in
   the real Messages screen, both immediately and after restart;
4. repeat catch-up and require zero duplicates, no orphan/blank regression,
   outbox `0 -> 0`, and no remote save/delete evidence; and
5. keep the 181 unresolved routes, unpopulated link-preview payloads, and the
   remaining on-demand attachment bodies as separately measured backlog rather
   than hiding them inside a success claim.

### Android fresh-profile barrier recovery and Message ownership gate

The Pixel Canary replay on 2026-09-03 proved that the Chat-zone stall was a
bounded migration barrier, not a decoder or transport failure. Sequence 475
was a pre-transaction Chat conflict at retry count three. Every migration
safety predicate passed except the fixed completion-time cutoff. Extending
only that cutoff through 06:00 UTC requeued the row after hot restart and
drained the Chat queue to 140 terminal rows: 139 canonical Chat projections
and one read-only tombstone acknowledgement. The run retained 504 explicitly
unsupported or dependency-limited rows, quarantined zero, kept automatic
triggers and remote saves/deletes disabled, and left the outbox `0 -> 0`.

The next contiguous barrier is Message-zone sequence 7. The checkpoint has 50
fetched rows, 44 pending rows, six retained rows, a pending batch/token, and no
canonical Message, Message-zone snapshot, replay, or record-map writes. Its
decoder reaches `decoder_ready`, then canonical projection returns
`canonical_identity_owner_unproven`. This places the failure after native
decode and before any durable Message mutation.

The current code-path audit identifies an Android fresh-profile difference
from the successful disposable Windows replay. Message routing first treats
the raw `chatID` as an exact Chat GUID. A preexisting legacy Chat can match that
GUID without carrying V2 ownership, causing exact-owner validation to throw
before the already-projected, durably proven service/group aliases are
examined. The bounded repair under qualification treats that one shape as an
untrusted candidate rather than an owner: it leaves the legacy row untouched,
continues through the normal proven-alias resolver, and accepts only one
route-compatible durable V2 owner. Conflicts, malformed exact owners,
ambiguous aliases, and a missing proven alias still fail closed; the original
`canonical_identity_owner_unproven` failure is restored if no proven route can
be found.

The bounded repair passed its first Android visible-chat proof on 2026-09-03.
Exact source commit `fd917a3e9d5a6e77a23846885458a887a7322895`
passed bridge reproducibility, the full Dart suite, Rust, rustpush, the
protector harness, Canary package/native-library verification, GitHub-hosted
signing, runner deregistration, and VM deletion in GCE run `33729517116`.
The signed APK was installed in place without clearing the Canary profile;
Alpha remained a separate installed package.

The first Small catch-up report was
`obcs2-semantic-1788423471746064.json`. It fetched/applied 149/148 Chats,
155/101 Messages, and 50/1 Attachments. It quarantined zero projection rows,
kept automatic triggers, remote saves, and remote deletes disabled, and left
the outbox `0 -> 0`. The real Android Messages screen immediately contained
conversation rows and readable message previews. Opening one conversation
showed readable incoming and outgoing message bodies. One list preview was
initially stale as `Empty message`; after a cold process restart the same
profile reopened with its chats, readable previews, and ordering intact.

The next Small catch-up report was
`obcs2-semantic-1788423853801676.json`. Its Chat stream was already at the
current head (`fetched=0`, `applied=0`). It advanced to the next nonempty
Message and Attachment pages, applying another 67 Messages and two Attachment
metadata rows while again leaving the outbox `0 -> 0` and every remote writer
disabled. Additional correctly ordered conversations became visible and no
duplicate conversation was observed in the list. Records without sufficient
ownership evidence remained retained instead of being guessed into a chat.

Three boundaries remain before calling this production-complete:

1. reach an empty terminal Message page, then repeat once more and require zero
   canonical changes so live idempotency is proven rather than inferred from
   the unit suite;
2. remove or explain the one immediate post-catch-up stale-preview transition
   so restart is a fallback, not a normal refresh requirement; and
3. keep malformed, unsupported SMS/RCS, unresolved ownership, and
   attachment-body backlog measured separately from the now-live iMessage text
   projection path.

### Bounded Apple-transport interruption recovery candidate

Two later Android catch-up runs, `obcs2-semantic-1788446032250325.json` and
`obcs2-semantic-1788446635803393.json`, stopped safely after Apple interrupted
an otherwise healthy protected drain. The first durable report was already
committed, pending pages and opaque tokens remained intact, and the outbox
stayed `0 -> 0`. The older classifier nevertheless described a server-category
failure with the misleading `native_auth_unavailable` safe code, so the manual
launcher could not distinguish a transient Apple transport interruption from
an identity failure and required another user-initiated run.

Exact source commit `b1de189f6499c47922ebc896465d8b753ba32bb5`
adds a bounded continuation policy without weakening any projection or
checkpoint gate. HTTP 408, HTTP 429, Apple 5xx responses, socket/WebSocket
closure, and provisioning-server interruption normalize to transport,
throttling, or server categories. After persisting the failed attempt, the
sampler releases the native-writer pause and operation interlock before any
wait or reconnect. It may create at most two fresh confirmed read sessions,
with no more than 60 cumulative seconds of delay, and only while account,
native-client, read-authentication, protected-store, checkpoint generation,
and stable pending-page evidence remain unchanged. Cancellation stops a wait
promptly; disposal is idempotent; a generation change aborts before a new
transport is constructed; and uncertain native resume fails closed. Remote
saves, remote deletes, automatic triggers, and tombstone semantic deletes
remain disabled.

The final focused sampler/controller suite passed 62 tests and the targeted
Dart analyzer was clean. The same exact commit then passed bridge
reproducibility, the full Dart suite, Rust library tests, rustpush production-
feature tests, the protector harness, Canary APK/package/native-library
verification, and GitHub-hosted signing in GCE run `33781776979`. The ARM64 APK
build itself completed in 721 seconds. The ephemeral GCE VM and matching GitHub
runner registration were both verified absent after cleanup. The downloaded
signed artifact is 448,457,086 bytes with SHA-256
`B6CCD4B9562A375DE39EC5AF3E926CCB51D64CB49DA8A19A085A447943852F22`,
application ID `com.bluebubbles.messaging.cloudkitcanary`, the expected Canary
certificate, APK Signature Scheme v2 and v3, and all four required ARM64 native
libraries.

Android acceptance remains intentionally separate from build qualification.
Install this exact artifact in place without clearing Canary state or touching
Alpha, resume the protected pending pages to a terminal empty read in all three
zones, repeat once for zero-change idempotence, restart the process, and verify
recent readable messages plus a recent photo in the real Messages UI. Until
those gates pass, this commit is a qualified candidate rather than a completed
CloudKit release.

### One-action foreground catch-up qualification

Exact source commit `fe05bd8536c2f589a430e9504101ea793c16c4a1`
replaces the Small/Standard/Deep developer choices with one foreground,
checkpoint-resumable catch-up action. One confirmation may run eight
independently admitted units of at most 16 remote passes each. Every unit
releases and reacquires the operation interlock and native-writer pause,
revalidates the exact native client identity, and resumes only from durable
per-zone checkpoints. Normal logs contain aggregate counts only; an explicit
developer toggle adds bounded, content-free per-record disposition codes.
Neither mode records message text, contacts, credentials, keys, raw records,
or change tokens.

GitHub Actions run `33790763306` completed both the full OpenBubbles APK job and
the Beta Sampler APK job successfully for that exact commit. The signed Canary
artifact is 448,452,918 bytes with SHA-256
`7F861EA6B0F302258DD54AEB8925D237BEA5259245369D0EAFA17FAF3EA676E8`.
It passed package-ID, stable-certificate, APK Signature Scheme v2/v3, and all
four required ARM64 native-library checks. An in-place `adb install -r` on the
Pixel preserved the original install identity, all 20 retained reports, login
state, checkpoints, and visible chat database; Alpha remained separately
installed and untouched.

The first live one-action unit persisted 16 reports from
`2026-09-03T19:32:53Z` through `2026-09-03T20:23:29Z`. It fetched 3,026 Message
changes, projected 1,561 Messages and 278 Attachment records, reported zero
quarantine, kept the outbox `0 -> 0`, and kept remote saves, remote deletes,
and tombstone semantic deletes disabled. The user independently observed chats
and messages appearing incrementally in the real UI while the run continued.
The process remained responsive, with no observed ANR, fatal exception, or
process restart. Losing USB monitoring did not interrupt the device-local run;
the same PID and durable sequence continued and monitoring resumed over
wireless ADB.

The sixteenth pass ended with an Apple `http_server` result for Attachments.
The one-action wrapper released and reacquired ownership without another tap,
and new semantic outcomes began within approximately 20 seconds. The first
report of the second unit restored Attachments to a terminal read, projected 48
more Attachment records, and continued Message fetch/projection while a later
independent Chat request received `http_server`. No checkpoint, outbox, or
mutation invariant regressed. This is live evidence that transient per-zone
server failures no longer collapse the complete catch-up session or require a
new user confirmation.

This qualification is still in progress. Production readiness still requires
an all-zone terminal empty read, the exact retained-save projection sweep at
that proven head, a second zero-change/idempotence run, cold-restart UI checks
for readable recent messages/reactions/links/photos and duplicate absence, and
verification that disabling verbose diagnostics returns logs to aggregate-only
output. Newest-first history and OS background scheduling are not claimed by
this foreground checkpoint-ordered candidate.

The second independently admitted unit persisted another 16 reports from
`2026-09-03T20:27:19Z` through `2026-09-03T21:24:55Z`. It fetched 2,953
Message changes, projected 1,530 Messages, and linked 404 retained Attachment
records without fetching another Attachment page. Chats reached a terminal
empty read in 15 of 16 passes after one independently recovered Apple server
interruption; Attachments were terminal in all 16 passes; Messages remained
nonterminal. The final retained counts were 505 Chats, 7,612 Messages, and
2,335 Attachments. Every report kept quarantine at zero, the outbox `0 -> 0`,
and all remote mutation controls disabled. A third unit began automatically
without another tap and persisted its first report at
`2026-09-03T21:28:23Z`, directly proving a second release/revalidate/reacquire
handoff.

Content-free fixed-label diagnostics also isolated the dominant Message
blocker. Across 11,874 logged decoder events, all had top-level service class
`sms` and nested `msgProto4` service class `rcs`; 11,671 were normal-message
events and 203 were reaction events. These event counts include retries and
are not distinct-record counts, but the distribution is exact. Apple is
retaining carrier-message records across an SMS-to-RCS route transition; both
services remain outside this iMessage projection. Candidate commit
`55d5786c1a447051d016a6e3e1b606f26c0ee6d2` therefore permits only SMS/RCS
cross-carrier nested labels to become retained terminal out-of-scope rows.
Nested iMessage, FaceTime, unknown, and case-variant labels remain strict
quarantines, and the iMessage branch is unchanged. Cloud qualification and a
fresh retained-projection sweep are pending before this classification can be
called live-proven.

The third independently admitted unit persisted 16 reports from
`2026-09-03T21:28:23Z` through `2026-09-03T22:19:57Z`. It fetched 2,966
Messages, projected 1,760 Messages, and linked 482 Attachments. Chats and
Attachments were terminal in all 16 passes; Messages remained nonterminal.
The final retained counts were 505 Chats, 8,818 Messages, and 1,853
Attachments. Quarantine, outbox activity, and remote mutation again remained
zero. A fourth unit began automatically and its first report fetched 200 and
projected 177 Messages without an interlock error.

Candidate commit `55d5786c1a447051d016a6e3e1b606f26c0ee6d2`
passed the full 32-core GCE qualification in run `33808592803`, including
binding reproducibility, the full Dart suite, Rust, rustpush production-feature
tests, the protector harness, Canary APK/native-library checks, GitHub-hosted
signing, runner deregistration, and VM deletion. Flutter APK compilation took
approximately 805 seconds and the complete run took about 31 minutes. The
downloaded signed artifact is 448,444,798 bytes with SHA-256
`06B4D0DB0E55BDA86F8090F1077AACC91FF042389F9BCE6BCADA6DAA7A11534D`.
Independent post-run checks found zero matching GCE instances and zero matching
GitHub runner registrations. Installation remains deferred until the active
predecessor catch-up reaches a durable natural stop.

The fourth unit persisted the first all-zone terminal empty read in report
`obcs2-semantic-1788474657661228.json` at `2026-09-03T22:30:57Z`. All three
zones fetched and applied zero changes, no projection rows were examined in
that remote-read report, the outbox remained `0 -> 0`, and every remote
mutation control remained disabled. This proves that the checkpoint-ordered
remote catch-up reached the then-current CloudKit head. It does not by itself
prove local convergence: 8,864 retained Message rows and 1,853 retained
Attachment rows remained, so the same confirmed session immediately entered
the exact sequence-bounded retained-projection sweep required by
`runConfirmedCatchUpAndPersist`. That sweep emits its separate report only
after all bounded rows have been examined; the unchanged process remained
alive and continued producing content-free semantic outcomes while the report
was pending.

Attachment bodies are deliberately fetched on demand rather than during the
metadata catch-up. The on-demand CloudKit V2 body path and semantic catch-up
share the same exclusive operation interlock and native-writer pause. The
retained Android log contained 41 attachment-fetch error markers during the
catch-up. At least 33 bounded error blocks directly carried `CloudKit writer
operations are paused or pause is pending`; the same log contained no
`cloud_attachment_source_unavailable`, `cloud_attachment_size_unavailable`,
`cloud_attachment_final_file_missing`, or
`cloud_attachment_native_result_invalid` marker. This proves a transient
coordination failure for the observed batch rather than missing CloudKit asset
bodies. The production V2 attachment path now awaits the exact active semantic
pull future before attempting its independently validated body download. A
failed semantic pull still releases the waiter because completion is only a
coordination signal; source, account, size, and integrity checks remain owned
by the attachment path. The global queue continues to admit at most one V2
download at a time. Old assets removed from iCloud remain allowed to report
unavailable, and a recent retained asset still requires post-install Android
acceptance. The exact attachment coordination candidate is
`4a14a27f7f5ebecb4bbecad51fb216e3140436ed`.

The retained-projection sweep completed its row traversal at
`2026-09-03T23:24:18Z` but then stopped safely before report persistence with
`cloud_sync_semantic_report_zone_invalid`. Content-free timing reconstruction
from the fixed-label outcomes isolated the mismatch: Chats spanned 0.07
minutes, Messages spanned 39.42 minutes, and Attachments spanned 13.78 minutes.
The report writer imposed a fixed 30-minute per-zone ceiling even though the
sweep itself is sequence-bounded in batches and permits up to 4,096 batches.
The Messages zone therefore became invalid solely because a valid bounded
large-history sweep took longer than the unrelated fixed diagnostic ceiling.

The report duration guard now retains the 30-minute base but adds two minutes
for each declared projection batch. Batch count remains capped at 4,096, all
record-count and projection-balance invariants remain unchanged, and a duration
outside that scaled budget is still rejected. A red-green regression test
reproduced the live 40-minute rejection before the patch, then accepted it with
35 bounded batches; the inverse test rejects a 33-minute one-batch report. The
failed live report did not advance or fabricate a completion marker. A fresh
exact-build run must still persist the projection report, quantify the remaining
typed backlog, and pass the idempotence and recent-attachment UI gates. The
exact duration-bound candidate is
`7bca56dc3cb1ae65914ec15596d6fc99f6532da7`.

Exact combined source `447b513ac142ab3e142ca6946129fcaffaa4d86f`
passed the full 32-core GCE qualification in run `33818489639`. Bridge
reproducibility, the full Dart suite, Rust library tests, rustpush production-
feature tests, the protector harness, Canary package/native-library checks,
GitHub-hosted signing, runner deregistration, and VM deletion all passed. The
GCE build job completed in 21 minutes 16 seconds. Independent post-run
readback found zero registered repository runners and zero GCE instances. The
signed APK is 448,448,894 bytes with SHA-256
`40BB9EC1DB089E20CDC1DC002CC4C380FFA4E092ECB7261058EF7B0E9C85DF71` and
contains the ARM64 Flutter, ObjectBox, and rustpush libraries.

The signed APK was installed in place on the Pixel at
`2026-09-03T17:08:49-07:00`. Android preserved the Canary first-install time
(`2026-08-23T06:15:18-07:00`) and signing identity. All 20 semantic reports,
the 109,051,904-byte ObjectBox store, 47,361 native-store files, and the
nonempty profile, hardware-identity, read-authentication, CloudKit, and
keychain files remained present. Alpha's install/update times and signing
identity were unchanged. The fresh Canary process opened the Messages route
with zero observed crash, ANR, native-fatal, `not yet implemented`,
`cloudkit_interlock_busy`, or attachment-fetch-error markers. Live catch-up,
projection-report persistence, idempotence, and recent-attachment acceptance
remain the next device gates.

The first exact-build device sweep exposed a second attachment coordination
case without stopping projection. Five attachment-fetch errors between
`2026-09-04T00:17:02Z` and `2026-09-04T00:17:17Z` paired with ten native
writer-pause markers. Their production stack entered
`api.downloadCloudAttachments` from the `legacyCloudKit` branch, not the V2
body downloader, and no V2 source, size, final-file, or integrity failure was
present. Both CloudKit attachment lanes use the native client paused by the
semantic reader, while IDS does not. The attachment synchronization gate now
waits for the exact active semantic pull for `cloudSyncV2` and
`legacyCloudKit`; IDS and unavailable lanes remain independent. Cloud
qualification and a fresh in-pull attachment acceptance check remain pending.

The replacement attachment-coordination source
`5bc55262a881d8a1923a717c3773b8130a7c094b` passed the full GCE Canary
qualification in run `33821744950`. The 32-core build job completed in 22
minutes 39 seconds, GitHub-hosted signing and verification completed in 54
seconds, and runner deletion completed in 1 minute 51 seconds. Independent
post-run readback found zero registered repository runners and zero GCE
instances. The signed APK is 448,444,798 bytes with SHA-256
`405E65D98392D83ACF8BEB5C8EBFBF74B08D0933912A899CC3FB03965C05532C` and
contains the required ARM64 Flutter, ObjectBox, and rustpush libraries.

The exact installed `447b513ac142ab3e142ca6946129fcaffaa4d86f`
device run first persisted an all-zone terminal-empty remote report at
`2026-09-04T00:15:22.232604Z`. It reported 505 retained Chat records, 8,864
retained Message records, and 1,853 retained Attachment records while keeping
the outbox `0 -> 0` and every remote save, delete, and tombstone-semantic-delete
switch false. Its local retained-projection report then persisted successfully
at `2026-09-04T01:01:15.950030Z`, proving that the batch-scaled duration guard
accepts a real large-history sweep without weakening any count or tripwire
invariant. The report retained exact three-zone structure and every zone
satisfied `projectionExamined == applied + projectionRetained`.

That sweep did not newly apply a canonical row. Chats examined and retained 32
blocking saves in one batch; Messages examined and retained 6,003 rows in 24
batches; Attachments examined and retained 1,734 rows in seven batches. The
typed backlog summary now separates 5,825 durable out-of-scope SMS/RCS-family
records from 4,703 blocking iMessage-relevant saves: 32 Chats, 2,937 Messages,
and 1,734 Attachments. This makes the next critical path local and explicit.
Transport is at the CloudKit head; projection must resolve the remaining
malformed Chat shapes, Message chat/sender ownership failures, and Attachment
parent/legacy-ownership failures before another full sweep can materially
reduce debt.

The signed `5bc55262a881d8a1923a717c3773b8130a7c094b` APK was then installed
in place over Canary with `adb install -r -d`. Android preserved the original
first-install time and signing identity, all 20 retained reports, the
109,051,904-byte ObjectBox store, all 47,361 protected native-store files, and
the nonempty profile, hardware identity, read-authentication, CloudKit, and
keychain files. Alpha's install/update times and signing identity remained
unchanged. Fresh startup reached the Messages route with no observed crash,
ANR, `not yet implemented`, unique-violation, interlock-busy, attachment-fetch,
or native writer-pause marker. A recent-photo retry and an attachment request
held across an active semantic pull remain the user-facing acceptance gates.

### Investigation checkpoint: identity maintenance interrupted projection

The next diagnostic run proved that the apparent semantic stall was not a
decoder deadlock. Chat completed normally, Message records continued decoding,
and then the troubleshooting UI invoked IDS reregistration while the semantic
session was still active. Registration failed with Apple status 6005. That
failure entered account teardown from another Flutter engine in the same
Android process, nulled the account state, and disposed shared Rust resources
under the protected read. The resulting `Resource has been closed` and writer-
pause errors were consequences of that teardown, not malformed CloudKit data.
That first interrupted run persisted no completion report and issued no CloudKit
save, delete, or local message deletion.

The original teardown guard tracked only futures owned by one
`RustPushService` instance, so it could not see work owned by another Dart
isolate. Identity-cache clear, peer-cache invalidation, manual and relay-health
reregistration, explicit account reset, and service-close disposal now share
the existing profile-wide operation interlock. Active semantic work and
identity maintenance
exclude each other in both directions across isolates; account reset acquires
the destructive-reset lease before detaching state; a registration failure
during protected work defers teardown instead of releasing native handles.
All profile and troubleshooting UI entry points route through those guarded
service methods and display only allowlisted failure codes. The focused
two-isolate and production-composition suite passes 39 tests. A signed Android
rerun remains required to prove that an accidental identity action reports
busy while the pull completes and persists its diagnostic report.

A subsequent resync on the same installed build persisted schema-v6 report
`obcs2-semantic-1788497098780904.json` at `2026-09-04T04:44:58Z` before the
operator force-stopped the app. All three zones again recorded terminal empty
server reads, the outbox remained `0 -> 0`, and remote saves and deletes stayed
disabled. The report was correctly degraded rather than successful because
local retained projection is incomplete: 505 Chats, 8,864 Messages, and 1,853
Attachments remain retained. Its bounded diagnostic sample isolated the next
work without recording content. Chat examined 32 blocking saves and classified
29 as malformed nested property plists plus three unsupported services.
Message examined 150 retained rows; its overlapping counters included 65
native-ready payloads, 40 invalid canonical senders, 25 unavailable chat
owners, 61 malformed records, and six unsupported reaction shapes. Attachment
examined 150 rows, with 144 native-ready payloads, six malformed records, and
repeated missing-parent evidence. The force-stop did not invalidate this
already durable report. A newer schema-v6 local-projection report,
`obcs2-semantic-1788498328390583.json`, persisted at
`2026-09-04T05:05:28Z` and proves that the follow-on sweep also finished before
the process was stopped. It examined and retained all 32 currently blocking
Chat saves in one batch, 2,937 blocking Message saves in 12 batches, and 1,734
blocking Attachment saves in seven batches. It applied zero rows, left the
outbox at `0 -> 0`, and kept remote saves and deletes disabled. The force-stop
therefore did not interrupt an in-flight projection transaction; the visible
empty result is the current decoder, ownership, and dependency backlog rather
than lost progress.

The matching native Rust log narrows the opaque Message failure further without
exposing message content. It contains 17,141 successful
`optional_empty_normalized` events for `msgProto2`, 2,085 fixed-stage
`message_proto` failures, and the same 2,085 enclosing
`message_gzip_preflight` failures. The one-to-one count proves that the dominant
native malformed path reaches the required `msgProto` protobuf decoder after
bounded gzip handling. It is not evidence of a random CloudKit transport or PCS
ciphertext failure. The next diagnostic candidate therefore keeps the strict
failure disposition but classifies prost failures into a closed vocabulary such
as invalid UTF-8, wire-type mismatch, invalid varint, underflow, or other. It
never logs the prost error, bytes, identifiers, lengths, field values, or
message text. Chat nested-property failures receive an equally content-free
framing class: empty, gzip, zlib, binary plist, XML plist, or unknown. No shape
is accepted merely because it is classified. The 17
`invalid_canonical_payload` outcomes now likewise emit one fixed class for each
canonical validation variant, while a distinct `post_build_identity_binding`
class marks rejection after DTO construction. Both paths preserve the existing
quarantine result.

The replacement Android build initially failed before packaging because
rustpush quota hardening declared the live `AppleAccount.spd` dictionary as a
generic plist value and then called dictionary methods on it. This was a source
typing regression, not a device, CloudKit, or authentication regression.
Rustpush commit `ba17215` restores the dictionary contract and updates its
focused tests. The parent Rust crate compiles with that correction, the
content-free chat-shape test passes, and the new protobuf-classifier test
passes. A full GCE build and test run remains required before installing the
race-fixed Canary in place.

Exact source `87a026b0e196f412e7e55b3bfb53039e6a5080e8` passed the complete
32-core GCE Canary qualification in run `33842234699`, including bridge drift,
the full Dart and Rust suites, production-feature rustpush tests, native-library
verification, GitHub-hosted signing, runner deregistration, and VM deletion.
The signed APK was installed in place without changing Canary's first-install
time, signing identity, retained reports, ObjectBox store, protected native
store, profile, hardware identity, or CloudKit credentials. Alpha remained
untouched.

The resulting catch-up first persisted all-zone terminal-empty report
`obcs2-semantic-1788503467147086.json` at `2026-09-04T06:31:07Z`, then
completed the exact retained-projection sweep and persisted
`obcs2-semantic-1788504605483791.json` at `2026-09-04T06:50:05Z`. The sweep
took about 19 minutes: 6.8 seconds for Chat, 680.6 seconds for Message, and
450.2 seconds for Attachment. It examined and retained all 32 eligible Chat
saves, 2,937 Message saves, and 1,734 Attachment saves. No row was applied,
the outbox remained `0 -> 0`, and every remote-save, remote-delete, and
tombstone-semantic-delete switch remained false. CPU fell from more than one
core during the sweep to 0.3 percent after report persistence, proving the long
foreground indicator represented bounded work and then became stale UI state,
not a continuing sync.

This complete sweep converts two hypotheses into exact decoder work. All 29
blocking Chat property failures decrypted to zero bytes. `CloudChat.properties`
is optional, and the legacy `CloudKitBytes` decoder maps decrypted empty bytes
to `None`; V2 alone attempted to parse those bytes as a plist. The pending
compatibility candidate removes only an empty decrypted optional `prop` from
the locally decoded record, rebuilds effective raw presence so canonical
conversion sees absence, and leaves nonempty malformed properties fail-closed.
It never mutates the protected envelope or broadens any required field.

The first sampled pass emitted 16 fixed `message_proto` wire-type mismatches;
the complete sweep added 189, exactly matching its 189
`native_failure_malformed_record` outcomes. These failures occur after valid
PCS decryption and bounded gzip inflation, so changing transport or retry policy
cannot resolve them. The pending diagnostic candidate walks only top-level
protobuf tags, skips unknown fields by their actual wire type, and reports the
first schema-known mismatch as fixed stage, field number, expected wire type,
and actual wire type. It emits no values, bytes, lengths, identifiers, raw
errors, or message text and leaves the malformed disposition unchanged. The
protobuf schema will not change until this metadata identifies the exact live
field.

User validation on the exact `87a026b0e196f412e7e55b3bfb53039e6a5080e8`
Canary then passed the first Android attachment-body presentation gate: still
photos downloaded and rendered in message threads. One GIF failed before
Flutter rendering. The native log fixed the failure at
`requested-file-match` inside preauthorized MMCS response validation. CloudKit
had returned the explicitly requested checksum together with an unrequested
sibling asset reference in the same authorization response. The legacy matcher
already selects only requested files, but the closed V2 prevalidator rejected
the sibling before reaching the requested reference.

The pending rustpush compatibility patch now shape-validates every bundled
reference, ignores only structurally valid unrequested siblings, still requires
every requested checksum exactly once, preserves Ford-key binding, and reduces
network source chunks to the requested chunk-ID set. Three focused Rust tests
pass, including a distinct sibling chunk and malformed sibling Ford index. A
signed Android retry of that exact GIF remains the live acceptance gate.

The contact-details media gallery was a separate presentation fork. Unlike the
in-thread attachment holder, it treated only in-memory bytes as local, force-
unwrapped optional CloudKit filename and size metadata, and did not reuse the
shared prioritized retry queue. The pending Dart patch gives both paths the
same nonempty-file gate, safe metadata fallbacks, failed-controller retry, and
null-size progress fallback. The post-sync chat refresh also receives a bounded
30-second presentation timeout so durable completion cannot leave the UI
spinner indefinitely. Thirty-six focused Dart tests pass. Contact-profile
download, GIF playback, and spinner completion remain signed-Canary gates.

### Investigation checkpoint: unified attachment presentation qualified

Exact source `eb70c9733511463ec5b305ead899151ec5aceeac` passed the complete
32-core GCE Canary qualification in run `33852183295`. Bridge regeneration and
drift checks, 1,501 Dart tests, 282 parent Rust tests, 198 production-feature
rustpush tests, and 30 protector-harness tests passed. The producer package and
required ARM64 Flutter and rustpush libraries passed inspection. GitHub-hosted
signing verified APK Signature Schemes v2 and v3 with the expected dedicated
Canary certificate. Runner deregistration and VM deletion both passed, and
repository runner readback found no runner retained for the run.

The signed APK is 448,498,046 bytes with SHA-256
`1DCBE28FD862F4140646416DAF1B783DFAF5628EA41A9F7D1D9633DC7AA8532A`.
It was installed in place with `adb install -r -d` over only
`com.bluebubbles.messaging.cloudkitcanary`. Android retained the original
`2026-08-23T06:15:18-07:00` first-install time and the existing nonempty
CloudKit, Keychain, hardware-identity, and install-secret files. The upgraded
ARM64 process started with its foreground services active and no observed
Android, Flutter, or Rust fatal error. The device was then blocked at Android's
secure unlock screen. Retrying the exact GIF, a contact-profile shared-photo
download, and the bounded post-sync spinner are therefore the remaining live
presentation gates; none is claimed passed from CI alone.

### Investigation checkpoint: shared-media retry ownership

The contact-profile report exposed one more split in attachment ownership.
When a profile gallery joined an already-running transfer, it could display
that controller without subscribing to its completion. The downloader then
removed the shared controller before publishing the final local path. The
profile's bulk-download action also ignored every attachment that was not
already local, and fullscreen refresh created a second GetX controller instead
of joining the active transfer. Those paths could respectively leave a spinner,
silently do nothing, or wedge refresh after deleting the old cached file.

Source `24638c963` gives all three surfaces one get-or-start operation. A late
gallery or fullscreen subscriber now receives the same materialized local path
before controller disposal, explicit profile downloads enter the prioritized
queue, and an active fullscreen transfer is joined before any cached file is
removed. Invalid temporary rows fail and leave the queue instead of occupying a
zero-progress slot indefinitely. Sixteen focused attachment tests pass,
including active-transfer joining, target preservation during fullscreen
redownload, and temporary-row queue drainage. The exact contact-profile photo
tap, GIF playback, and bounded spinner still require signed-Canary acceptance;
these tests do not claim that user-facing gate.

Exact source `e62a73297f026f3f97ea1a3161bba798dbf91c22` then passed the
complete 32-core GCE Canary qualification in run `33856585608`: generated
binding checks, 1,504 Dart tests, 282 parent Rust tests, 198 production-feature
rustpush tests, 30 protector-harness tests, producer package and ARM64 native-
library inspection, GitHub-hosted signing, runner deregistration, and VM
deletion all passed. The signed APK is 448,502,142 bytes with SHA-256
`55538370916DF76C15AF1C19A4B54DA3A2D62A4C48EED63ED8F4CF637210344B`.
Local verification confirmed package
`com.bluebubbles.messaging.cloudkitcanary`, version `1.15.0` (`20002227`), the
dedicated Canary certificate, APK Signature Schemes v2 and v3, and the ARM64
rustpush library.

The artifact was installed in place with `adb install -r -d`. Android retained
the original `2026-08-23 06:15:18` first-install time and nonempty CloudKit,
Keychain, hardware-identity, and install-secret files; Alpha remained installed.
The upgraded process started without an observed Android, Flutter, Rust,
CloudKit, or MMCS fatal error. The device remained at its secure lock screen, so
the contact-profile photo tap and exact GIF retry remain deliberately unclaimed
live gates.

### Investigation checkpoint: Android attachment promotion policy

Two unlocked contact-profile gallery taps reached the V2 attachment download
coordinator and failed at native materialization with the closed
`local-storage` category. The Canary documents root and attachment directory
both existed, the protected cache root existed, and Android reported about
25.8 GB free. No body, manifest, or partial file survived either failed
attempt, so low storage, a missing Flutter documents directory, and a stale
partial were ruled out.

An isolated `run-as` probe then reproduced the boundary without reading or
changing message content. Android rejected a hard link from the protected cache
to the application attachment directory with `Permission denied`. It also
rejected a hard link created entirely inside the application attachment
directory, while an ordinary same-directory rename succeeded. The failure is
therefore the Pixel app-data policy, not CloudKit authorization, MMCS bytes,
HEIC decoding, or the profile-gallery tap route.

`rust/src/cloud_sync_attachment_materialization.rs` now treats every
non-`AlreadyExists` cache-to-documents hard-link failure as a request for the
existing bounded, hash-verified copy fallback. Fully verified temporary files
are promoted without replacement through the Linux `renameat2` syscall. The
syscall path avoids Android's API-30 libc wrapper because OpenBubbles supports
API 24, while preserving atomic visibility and the no-overwrite contract.
Successful cache reuse and recovery also consume deterministic partials before
their guards are committed.

The Windows fast loop passed all 20 focused native materialization tests,
including atomic no-replace promotion, existing-target preservation, crash
recovery, oversized-source rejection, and successful-reuse partial cleanup.
That proves the shared byte and filesystem state machine. Android compilation
and a signed in-place Canary retry remain required because Windows cannot prove
Android syscall availability, app-sandbox policy, HEIC/GIF rendering, or
touch-to-fullscreen behavior. The acceptance sequence is one profile HEIC tap,
the exact previously missing GIF, a second tap proving cache reuse, and a check
that no `.partial` file or `local-storage` failure remains. Alpha is outside
this gate and remains untouched.
