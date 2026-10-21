---
type: design
title: CloudKit incoming-message archival gap and implementation boundary
description: Source-backed coverage gap and minimum separate archival path required before claiming complete two-way sync.
resource: openbubbles-app
tags: [cloudkit, receive, archive, production-gate]
timestamp: 2026-10-21
---

# Decision

## Active received edit/unsend slice, October21

Native source8cf3a05a461aa04cc94d23981dfb8fcc2e4b1c0d adds a private immutable
received-mutation codec and platform-encrypted inline seed. It reuses the existing
seal API signature, not the outgoing receipt API. Distinct purpose and GUID/source
domains prevent promotion into an original create or local-send confirmation.
Both native account and registered-handle checks remain before synchronous sealing.
One strict native39601015873/job119225221607 is running. Generated binding
reproducibility, native compilation and app Rust tests have passed; dependency
suites and postjobs are still pending. This is not Android or Apple proof.

The pending Dart integration owns an encrypted event before ordinary reflection,
including when its original target is missing. It reuses the existing incoming
queue and capture/engine drain. Target reflection and its journal marker commit
together. A duplicate cannot apply again; late edits and post-retraction edits
stay retained rather than overwrite newer local state. Only reflection-owned
fields change, preserving concurrent read/delivery/bookmark/cloud-map state.

Retained events veto stale received/historical **creates and fresh dispatch**,
not exact unknown-outcome readback or the ordinary semantic reader. This is not
a conditional-update producer. No pending-event restart replay or remote update
is claimed. These require a received-origin predecessor/actor proof and current
generation/raw record/map/ETag through the existing update queue, never a fake IDS
send receipt or an absence-to-overwrite shortcut.

Final combined12-file affected run passed305tests. Earlier journal14, identity31,
stale-create188 and integrated72-case batches overlap and are not additional
coverage counts. Nine new paths analyzed clean; final analysis has zero errors,
the exact8service baseline diagnostics, plus2unchanged handler diagnostics.
Existing29 model
entity/property/index definitions match dd0778c7 exactly; new entity38/index113
only. The new synthetic forward-upgrade case preserves messages, media relations
and uncertain queue entries across reopen. Initial boundary/timezone fixtures and
two old index-limit fixtures were corrected without changing production limits.
All five received flags stay off. No APK, Pixel, account, send/upload or live
database operation is part of this slice. Full CloudKit production is incomplete.

## Current offline integration, October21

Source14876fecb on319ec27d5 adds a separate, explicit received-text scope to the
existing Profile automatic-archive grant. V1 sent-only consent remains unchanged;
v2 includes queued and future supported received/mirrored plain text. A new
Profile flag plus all four received flags are default false. No flags are
selected by this change and no build has deployed it. Direct/group/mirrored
plain-text source qualification is not rich/media or received-mutation coverage.

The existing runtime, queue and normal reader are reused. Capture and dispatch
check the same account/store/ownership lineage and fresh scope grant. Scope
downgrade preserves and pauses only pristine, source/checkpoint/map-proven
received creates, without blocking ordinary sent jobs. Operations that entered
submission still require exact readback; that exception grants no new create.
The native mutation boundary rechecks the current grant synchronously.

Affected674tests, final readback230tests (overlapping) and six enabled-gate tests
passed offline; 19path analysis clean. Disposable real ObjectBox fixtures use
synthetic native collaborators, not Apple or Android evidence. The native
seal-order repair passed sole strict native39593669378/job119200605175:
951appRust/449rustpush/16provider(1ignored/12filtered)/40protector passed,
binding reproducibility, compilation and postjobs passed,18m37s. No new API,
generated bindings, schema, lockfile or submodule pins changed.

A subsequent Dart-only capture correction separates local source retention
from foreground upload-worker availability. A fresh background engine reloads
the saved v2 grant after actual native identity and durable owner capture, then
checks exact account/store/automatic-archive epoch and grant token before atomic
Message/seed retention and after asynchronous identity checks. Missing/revoked
scope keeps ordinary persistence; no upload worker or network write is started.
Inspection/upload workers keep their foreground grant gates. Source RED/GREEN
and six-file165affected tests passed, including real disposable ObjectBox;
four-path analysis has zero errors and the exact same8baseline diagnostics
(1warning/7info). Review accepted; not a live cross-engine timing claim.

Rich/media,
received mutations, truly unavailable pre-seal keys/account proof, live lifecycle
and public rollout remain open. Canonical evidence: received-profile-consent-20261021.

## Current working source, October21: group source qualified

Published319ec27d5 includes7dbd3d2bb's plain received-group parent/create/readback wiring.
It reuses ordinary restored direct/group parent proof, protected received source,
fresh native absence check, the existing single-submit queue and normal reader.
Exact captured wire ID must match authenticated identifier/gid/original-gid;
outer chat_id=parent.gid and protobuf4route=parent.guid, with original endpoint.
Public direct comparators and outgoing validators stay direct/source-strict.
Provisional/unproven groups keep exact discovery, whose NotFound grants no create.

Corrected eight-file196Dart batch passed, including seven new real ObjectBox
group cases; targeted five-path analysis clean. Initial missing supplied test path
and stale direct-selector assertion retained and corrected, no product bypass.
Initial strict39584343466 failed on1generated doccomment drift; native compile/
tests skipped, postjobs success/watch79769 terminal1. Corrected that exact comment
from ZIP-SHA-verified artifact12338189145 and checked all12generated files
byte-exact. No executable binding/signature change; contenthash1705609692.
Corrected strict39585410495/job119172967938 TERMINAL SUCCESS17m37s for exact319,
watch23976 terminal0. Actual951appRust/449rustpush/16provider(1ignored/12filtered)/
40protector passed; all10new group cases observed ok. Strict drift/compile/
postjobs passed, no active job or owned watch. Source qualified, NOT packaged
or live accepted. No new API signatures,
schema, locks, pins or flags. All4received flags stay defaultoff.
Native private logic changed: oldd259/624libraries cannot execute this feature.
No new APK/device/account request/send/upload. Evidence in canonical
build-evidence/received-group-create-20261021. No active helper/local tests.

Local uncommitted repair on319ec27d5 addresses the native seal-order finding:
both actual native DSID/client-composition checks and both registered-handle
reads now finish before synchronous encryption, with no later await before
returning the seed to Dart. Existing3d retention can then own valid ciphertext.
Source-order RED/GREEN and four-file127Dart passed; two-path Dart analysis no
issues. Native compilation/runtime for this delta is not yet qualified. No new
API/binding/schema/pin/flag or rollout change. This source finding was not a new
live incident, and genuinely unavailable keys/account remain separate.

Pre-seal failures, rich/media receive, received mutation chaining, normal Profile
rollout and same-source live acceptance remain open. No full production claim.

## Prior source and packaged boundary

Published source `ae3520938` additionally retains exact plain group receive
sources for the existing GUID discovery/normal-reader path. Group V2 keeps the
wire UUID and has no direct peer; direct V1 encoding/digests are unchanged. Group
rows skip direct-parent inspection and cannot enter direct create. All four
rollout flags remain off. Final175affected Dart tests passed, including group
source/store reopening and idempotent pending-reader adoption without outbox
entries. ONE strict native39579656758/job119153826958 passed941appRust,
449rustpush,16provider(1ignored/12filtered),40protector; all6new native tests,
strict binding drift, compilation and postjobs passed. Watch21649 ended0.
This native implementation change needs a matching new library/APK;
no API/bindings/schema/lock/pin changed, and no package or live proof exists for
this delta. Native encrypted group reopen/discovery and format tests passed,
not actual Android/platform-key or Apple acceptance. No active job remains.
Group creation, media/richer incoming shapes and pre-seal failure
remain open. The last signed d259 package below does not contain these changes.

Reviewed app source d259a9b29 and the actual compile arguments of signed Canary
39564344037/APK2405e07c. Received capture, inspection, upload and discovery defines
are not supplied; all four constants in cloud_sync_dev_gate.dart default false.
The capture hook and its worker additionally require the developer runtime.
The writer/automatic-upload availability flags enable the separately consented
local-send path, not received or mirrored-message archival.

Existing CloudKit reads can still restore received messages already archived
by another Apple client. This gap concerns archiving local receives that are not
already in CloudKit; it is not a basic IDS-delivery failure or proof that any
particular missing message is absent remotely.


The direct-text receive hook, platform-encrypted seed, exact inspection and
normal-reader ingress are implemented components. Source `3d376e4d6` closes a
specific post-seal loss window: it atomically retains the encrypted seed and
Message before the next asynchronous identity check. A failed post-check keeps
that local work and wakes the existing bounded worker, which must independently
revalidate before any remote operation. Local retention is not upload admission.
Two new regressions and the affected 142-test batch passed offline. Native APIs,
generated bindings, schema, rollout flags and six submodule pins are unchanged.
This Dart-only delta is published but NOT in the signed `d259a9b29` APK.

No new same-source live receive/create/readback proof was obtained. Groups,
richer incoming content and durable ownership of failures before native sealing
remain open; ordinary receive fallback preserves the message but is not a
backup job. Missing native key/account proof cannot be replaced by plaintext or
asserted Dart metadata. Exact evidence is in the canonical checkout's
`build-evidence/received-seed-retention-20261021/QUALIFICATION.json`.
Never fabricate an outgoing receipt, relax identity/parent checks or reinterpret
historical/local recovery as live-receive provenance to bypass this boundary.

Next receive qualification should follow one supported real receive through its
protected source, duplicate-aware exact lookup, create-or-reader handoff and
readback, then its existing recovery path. Do not repeat unrelated passing relay
login/send or full source suites without a new failure or relevant code change.
The current exact-source treemap owns release and device state. Older dated
sections below describe historical component work, not current enablement.


Incoming archival is a missing production capability, not a reason to relax the
outgoing positive-receipt gate. No received message may be represented as a
successful outgoing send, and archive work must never send an IDS message.
Direct unchanged received text now has a default-off, component-qualified upload
path. It is not live-verified or production-enabled, and does not cover the full
incoming archive scope yet.

## Received create checkpoint, September 16

App383ac8038/nativef33a2e764 with rustpush5862be3 passed hosted35142500478
(743 app Rust,351 rustpush,11 Anisette,40 protector), plus853 Dart cases across
28 files. The separate received envelope preserves original direction, sender,
addressed endpoint, timestamp and text; ordinary outgoing validators remain.
An exact new native NotFound is required to stage it. Durable source/outbox/map
adoption is atomic; every prepare, consume and readback checks the source and
parent again. Received unknown outcomes use the existing single-submit/readback
queue, not IDS resend. Native readback checks original outer/protobuf fields.

State3 means adopted by the outbox, not cloud-confirmed. Fields15/16 and index104
record that ownership without changing older UIDs. A new Found supersedes only
a cached no-raw Absent and retains its evidence. Known edits/retractions block
fresh received creates until received mutation chaining is implemented. Removing
the Message row does not erase the journal's parent proof for readback, provided
the exact canonical Chat still exists.

Found-to-reader reconciliation is now source-implemented, under qualification.
Native c5559d5bb stages an ordinary protected record identity and raw envelope;
Dart adopts that change into the existing semantic inbox without advancing or
clearing any Apple cursor. State4 owns a reader change, not a completed projection
or upload. Existing different versions and tombstones remain ordering barriers.
The worker resumes both state2 observations and state4 pending work after restart,
then uses ordinary decoding/projection. No direct Message.text assignment and no
synthetic outgoing receipt. Sixty-one transaction tests and97 gateway tests
passed, including direct projection, a newer local edit/retraction, reopen/replay
and generation2. Native run35149164355 passed745 app tests. All received flags
stay off.

## Exact lookup and local ownership, current continuation

### Proposed Found-read separation, not implemented

Source inspection at appf43919ba3 shows `cloud_sync_prepare_received_archive_inspection`
in `rust/src/api/api.rs` decodes a canonical Chat and projects the expected message
before deriving its lookup name from only the received GUID and container user ID.
The location lookup itself does not need that parent selection. This is a candidate
way to discover already-existing group records without guessing an owner.

It is **not** safe to remove the current parent check in isolation. The raw/typed
comparison needs that expected projection; native Found staging revalidates the
Chat source; the Dart reader adapter requires restored-direct-Chat proof before
and after awaits. Reusing those paths with a dummy parent would bypass a boundary.

The smallest candidate separation is an authenticated, source-bound GUID lookup
with no write capability, followed by ordinary reader ingress for exact Found
bytes. Bind account/session/store, protected source, container, generation,
record name, ETag and original bytes. Discovery alone must not mark a captured
message equivalent, archived or projected, or reparent a local row. Normal reader
ownership/conflict gates still decide whether it can be applied. Test GUID/core
identity collisions, ambiguous original-group aliases, stale bindings, duplicate
ingress and failed projection before enabling this path. NotFound-to-create keeps
its separate exact parent/unique-owner proof; group capture/write flags remain off.

This is a reviewed design question, not completed group support. The lookup
independence is source-backed; safe adoption without the existing direct-parent
dependency still requires a concrete implementation and proof.

An opt-in inspection adapter now takes a materialized source and the latest
applied protected direct-chat parent to one native exact record lookup. It
distinguishes equivalent, needs-projection, conflicting-identity, absent and
unresolved. Every Found blocks duplicate create. An old Absent is never a
reusable create permit; Unresolved is retained work, not permission to send.

The first native snapshot f139a899b/fb864a3 passed hosted35107521313 with
737 app Rust,350 rustpush,11 Anisette and40 protector cases. Original response
frames are checked before NotFound interpretation, original Record bytes are
retained, and decompression rejects excess output/trailing members. This proves
components only. App integration before the next split passed808 Dart tests.

App14ce1d749/native6eaba5c22 plus fixture repair406677804 qualified
a two-phase handoff in successful run35138299645:
network preparation retains an opaque in-memory result; local stage/adopt/commit
runs under cross-engine exclusion without holding that short lease over network
I/O. Lost local commit responses remain state1 and retry their exact observation.
State2 marks only finished local inspection, not projection or cloud archival.
The received table adds nullable observation property14 and preserves prior IDs.
Final27-file Dart integration passed811. Native compilation passed on predecessor
run35136724953, then its new noncanonical-wire fixture failed before testing the
handoff: ETag tag1 was accidentally still first. The repair appends it last and
keeps the inequality assertion. The rerun passed738 app Rust,350 rustpush,
11 Anisette and40 protector cases; see the history log for exact artifact proof.

Remaining vertical work: qualify Found through normal semantic projection without
overwriting newer local edits, then prove the received create/readback flow live.
The generic outgoing encoder rejects received sender/direction, deliberately.
Do not relax it or synthesize a positive IDS-send receipt to reuse that lane.
Incoming groups/media and pre-seal readiness failure still need coverage.
Capture and inspection stay default-off until their respective live gates pass.

### Discovery slice implementation, September 18

Supervisor approved the bounded authenticated discovery-to-normal-reader path
(default off, source/test only until checkpoint review). New binding-neutral
module `rust/src/cloud_sync_received_record_discovery.rs` implements the
lookup half of the separation above: exact GUID plus container-scoped user
identity derives one record name; account, store, container identity, and
message_generation (alongside account, store, and container identity) is pinned
before the lookup and revalidated after it; read-permit freshness itself stays
with the existing container and auth-snapshot machinery;
`NotFound` stays a payload-free separate observation with no create grant;
`Found` binds ETag and original raw bytes for normal reader ingress only,
deciding no equivalence. No owner selection, no candidate lists, no
title/membership matching, no writes, no IDS activity, no new flags. The
reader-ingress wiring and hosted qualification remain open before enabling.
Status September 18 (uncompiled scaffolding, under review): the request now
immutably binds its preparation snapshot and settlement rejects cross-scope
replays (regression test included); the raw-size bound reuses the established
8MiB `MAX_RAW_RECORD_BYTES`; and private `cloud_sync_discover_received_record_exact`
in `rust/src/api/api.rs` performs the real read-only preparation, exact
lookup, receipt and raw-wire validation, and after-await revalidation with no
parent, reusing the existing inspector and permit machinery. Validated finds
stage raw bytes as `Unresolved` for the normal reader pipeline; no equivalence
is claimed and no reader-ingress wiring exists yet. Native compile and tests
are unverified locally and await one coherent hosted qualification batch.

## Current retry architecture, September 16 continuation

The receive transaction now targets an inline platform-encrypted seed rather
than waiting for protected-file staging. Native sealing binds account, store
and the exact immutable received source; only ciphertext/hashes cross back to
Dart. ObjectBox commits Message and seed together. Version2 bindings reuse the
existing intent column; version1 file descriptors remain supported. No schema
ID is changed and no plaintext fallback is introduced.

A bounded local worker materializes the seed under the local lease. It retains
the seed until descriptor adoption, then retains the exact descriptor across a
lost commit response. State1 records completed local commit only, so later
receives do not repeat staging. A high-watermark bounds a worker round; later
captures cannot indefinitely starve retained failures. Transient row failures
back off, while identity/engine-admission failures need a fresh explicit event.
Reset disposes and joins the worker before clearing its cursor. Native orphan
cleanup already handles a crash before descriptor adoption.

This closes the file-staging crash gap after sealing, not failures of sealing
or identity readiness themselves. The latter still preserve normal messages
through the existing delivery fallback but do not prove a durable archive job.
The capture flag remains false. Neither materialization, native source-to-message
projection nor raw protobuf comparison grants remote write/adoption authority.

Qualification: appf403006b9/native9293a457c passed hosted35099318119 with737 app
Rust,321 rustpush,11 Anisette and40 protector tests;25-file Dart batch692 and
focused analysis passed. The new source projector preserves original sender,
addressed local endpoint, direction, text and checked Apple-epoch time, using an
exact direct parent rather than the current sending alias. Raw proto1/2/3/4
checks reject unknown/duplicate singular fields, wrong wire types, overflow,
truncation and presence mismatches without requiring field order or reencoding.
These are components, not a successful CloudKit upload or Apple-client display.

Next vertical slice, no extra general-purpose framework:

```text
materialized received intent
  -> authenticated same-account native source + exact canonical chat
  -> deterministic Messages record name + exact read-only lookup
     -> Found: inspect original outer fields/raw flags and decrypted proto bytes
          -> equivalent: retain exact raw/version and adopt mapping atomically
          -> changed/unsupported: keep record, route to reader, never new create
     -> NotFound: durable create-only operation, one submit, exact readback
     -> uncertain: retain job, no blind create or IDS send
```

The generic CloudMessage decoder uses from_bits_truncate for flags; the native
inspector must check original flag bits before comparing, not treat a lossy typed
model as complete evidence. Exact lookup identity/etag and raw adoption remain
required. Existing unknown outcomes and outgoing receipt gates stay unchanged.

## Verified coverage at product f027aad2a

| Origin | Current path | Archive result |
| --- | --- | --- |
| Locally composed send | Fresh origin, positive native IDS receipt, local-send journal, protected outbox | Supported by the separately qualified send lane. |
| Incoming iMessage | Native receive, incoming queue, ActionHandler, local Message | No V2 archive intent producer. |
| Own message mirrored from another device | Same receive path | No fresh local-send intent; isFromMe alone is not submission evidence. |
| Existing CloudKit history | Protected read and canonical projection | Must not feed a new archive loop. |
| Older local/Alpha history | Legacy bulk-upload candidate only | Legacy writes are disabled under V2 ownership; import requires separate explicit disposition. |

Source anchors: `RustPushService.handleMsgInner`, `reflectMessageDyn`,
`IncomingQueue`, `ActionHandler.handleNewMessage`, `Chat.addMessage`,
`CloudSyncLocalSendIdentity.capture`, `CloudSyncLocalSendJournal.readReady`,
`CloudSyncProductionLocalSendAdapter`, and the legacy `uploadMessages` guard.
The local-send consumer explicitly drains its journal, not arbitrary Message
rows. The legacy query selects unsynced rows without a from-me filter, but that
writer is intentionally fenced off in a V2-owned installation.

This means an incoming thread can remain only local unless another client
uploads it. It does **not** prove that the missing 27 Alpha GUIDs are absent from
Apple: canonical-table absence is weaker than a protected raw-cache/remote
presence check. The 6,252 retained records must not be ignored in that diagnosis.

## Minimum implementation sequence

Current source contains a **default-off live capture hook and eligibility component**:
`CloudSyncReceivedArchiveIdentity`. It distinguishes incoming/mirrored direct
plain-text candidates without authorizing a save. It requires matching row,
parent, wire, sender and original local recipient; preserves source identity
across same-row canonical adoption and sender-preference changes; and rejects
deleted chats and unsupported shapes. Native receive-destination propagation
and matching Dart guards are now implemented and test-qualified. The earlier
ten-file Dart batch passed446, including receive-origin rejection in outgoing
send/reaction/edit/unsend capture, received journal restart/rollback, production
reference inventories and forward schema upgrade. There is no enabled production
archive receive hook or incoming uploader; the qualified local source is below.

The received journal is integrated but unenabled. Its synchronous persistence
callback and full wire/row validation share one ObjectBox transaction. The source
binding must already refer to a native-protected envelope; a typed string is not
authentication. The bounded reader returns an account/epoch-bound keyset cursor,
and callers must continue until exhausted. Metadata readiness is not proof of
current message-body equality or remote absence. GC includes every retained
received reference, including old epochs and unknown states. Admission, terminal
retirement and Apple-first semantic equivalence are still separate work.

### Native source candidate, component-qualified

App089b87fa2 adds a bounded native received-source codec and a distinct
`idsReceivedArchiveSource` protection purpose. The source retains the original
sender, local recipient, direction, peer, timestamp, plain text and conversation
identity. Reply-device tokens and delivery receipts are not copied into archive
material. Source and GUID digests use the existing Dart v1 contract, with frozen
cross-language vectors including Unicode and control-character encoding.

`cloud_sync_capture_received_identity` checks cached native CloudKit/keychain
composition without demanding refreshed GSA SPD after process restart. This is
local data ownership, not CloudKit authentication or write permission. The
existing full writer snapshot still performs its original current-GSA validation.
`cloud_sync_stage_received_archive_source` takes one configured SharedPushState,
checks registered handles and identity across waits, protects locally, and returns
only bound hashes/references. No dependency warming, keychain sync, IDS query,
re-registration, send or record save is introduced. A caller must still supply
actual live-receive provenance and revalidate its current state at adoption.
Do not equate IDS delegate profile IDs with CloudKit DSIDs: they are separately
named protocol inputs, not an established cross-component assertion.

The first Dart staging coordinator used an isolate-local protected-store lock
around stage, atomic journal adoption and lease commit. Review found that this
does not exclude recovery in another isolate. The current default-off candidate
adds a native local-store lease and requires it for capture plus maintenance
inventory/cleanup; generated bindings and component qualification now pass. It
does not take the network-wide CloudKit writer lock. Before adoption, failures
may roll back the fresh lease;
after adoption, failures retain the exact source for recommit/restart recovery.
Local tests cover a lost commit response, changed source and post-commit identity
loss without creating an outbox operation. No production receive hook is enabled.

The live queue hook is now present behind an independent default-false capture
flag. Its delivery fallback preserves ordinary receive and reuses a verified
committed row after a lost response, but never persists into a changed account.
Failure before a protected source exists still lacks durable capture retry.
Neither this hook nor the local lease is an enabled incoming uploader.

Checkpointcfc37e26a now wires only eligible direct text into the real incoming
queue persistence callback. Unsupported media/groups/SMS keep the prior queue
path. Account/store identity is captured before queueing and checked before
fallback; reset closes admission and drains active captures before teardown.
The new native local lease is independent of the long network gate; maintenance
still takes both gates, and only local protector methods bypass the network
gate under an active local scope. Expired scopes and failed release cannot claim
successful quiescence. Native contention rejects a waiter after two seconds,
never steals the owner's lock, and OS process-exit release is tested on Linux.

Hosted run35094043857 passed717 app Rust,321 rustpush,11 Anisette and40 protector
tests, with a hash-verified generated artifact. The23-file Dart batch passes676;
focused analysis is clean. Older migration fixtures now correctly omit the new
table when constructing their historical models; no existing model ID changed.
This proves source/lifecycle components, not Android delivery or remote archive.

Next discriminating work: persist retry ownership when native capture fails
before creating its encrypted source, then validate exact raw CloudKit record
presence/identity and unknown fields before duplicate-aware admission. A failed
capture's ordinary-delivery fallback must not be described as a completed backup.

The pure existing-record comparator can recognize direct plain text, including
standard plain NSAttributedString structural metadata and mirrored own messages.
It accounts for the receive path's millisecond precision rather than demanding
invented nanoseconds. Every Found outcome blocks a duplicate create. Its typed
comparison is **not adoption proof**: raw record identity/presence, unknown
protobuf fields and protected parent/source linkage remain caller requirements.
There is no boolean shortcut granting that proof. Edited, rich or otherwise
unproven records require projection/reconciliation, never overwrite.

Hosted run35086913808 passed native compilation and708 app Rust,321 rustpush,
11 Anisette and40 protector tests. The generated artifact hash was checked before
import. Current Dart qualification passes480 cases across11 files. These prove
the named component boundaries, not actual delivery, a production receive hook,
remote admission, raw-record equivalence, or independent Apple-client display.
The generation run deliberately skipped committed reproducibility checking.

1. Define a separate received-archive origin and durable intent after incoming
   persistence succeeds. Preserve account/store provenance, the exact original
   GUID, sender, direction, timestamp, chat route and content digest. Observe
   existing certified delivery; do not emit an extra acknowledgement or invent
   a send receipt. An older-history importer remains a different entry point.
2. Capture an immutable source before queueing work. Reuse protected source and
   archive/outbox machinery where its contracts fit. Keep local-send eligibility,
   positive receipt, one-time send claim and unknown-send rules unchanged.
   Admission must check the V2 record-map/snapshot and existing local-send
   journal, not just legacy ckRecordId/ckSyncState flags. An echoed local send
   cannot acquire a second identity merely because it arrived on the receiver.
3. Resolve the exact protected chat dependency. A group ID/name/member guess is
   insufficient; preserve validated canonical row IDs and record-map bindings.
   The saved canonical group passes local structural proof, but the split live
   row is provisional. A binding check on a copy is not live write permission.
4. Establish record naming and logical-message deduplication against existing
   Apple records before enabling creates. Already-present identical data is
   adopted without a new create; divergent or incomplete evidence is retained.
   Do not equate absence of a newly chosen record name with logical-message
   absence. Pin the request/operation identity before any external save.
5. Reuse create-only save, exact readback, durable record-map adoption and
   restart recovery. Unknown outcomes reconcile by readback only. No legacy
   uploader fallback, blind retry, new record ID after timeout, or remote delete.
6. Expose the received-archive capability truthfully through Profile. Until it
   works, the existing automatic-upload switch must not be described as a full
   backup of incoming/mirrored conversations.

`Message.toCloud` is a useful legacy encoding reference, not a blanket safe
replacement for the V2 encoder. It must not reconstruct or overwrite existing
records and discard unknown fields. First prove fresh received text encoding,
then group, media and mutation interplay before a full production claim.

## Native integration boundary

- Implemented: `IDSRecvMessage::to_message` now preserves `target` (`tP`) as
  `MessageInst.received_on_handle`, carried through the regenerated bridge.
  `MessageInst.target` is instead an optional reply-device
  token, including on iMessage. `certifiedContext.target` retains the local
  recipient only when all certified-delivery fields exist. The Dart candidate
  requires its captured endpoint to equal the native field; missing/mismatched
  values fail, never borrow a current chat alias. Native tests cover certified,
  uncertified, missing-target and locally composed origins. This metadata alone
  is not an authentication capability or permission to archive.
- Keep incoming sender and addressed local endpoint in protected source. For a
  mirrored own send, also preserve its original local sender. The legacy
  `Message.toCloud` assumes current chat.usingHandle, so it is not a reliable
  provenance source. This encoding still needs independent-client qualification.
- Reuse protected staging, commit/rollback, create-only consumption and exact
  readback below a separate received-origin validator. Do not reuse the outgoing
  from-me gate, positive IDS receipt, attachment-send source or dependency-warming
  stage as a supposedly local-only receive capture.
- Native `deterministic_message_record_name` and
  `canonical_entity_key_hash(Message, guid)` provide existing record/local-key
  derivation. The new Dart digest is lane-local, not cross-device deduplication.
  Reuse the exact container/GUID binding, without case folding. A found remote
  record must not trigger a new create: Apple's attributed representation,
  delivery/read flags or timestamp can differ from our exact staged bytes.
  Existing-record semantic adoption needs separate proof; unexplained differences
  remain retained and never authorize overwrite.
- Existing outbox/map entities are sufficient after admission. Before admission,
  offline or provisional receives need durable protected-source ownership without
  blocking history reads. The new received-intent table provides that metadata
  ownership separately from outgoing intents/outbox, but native staging and its
  production producer are not wired. The schema adds entity36 without changing
  the27 existing entity/property layouts; only synthetic forward upgrade was
  tested. Do not claim old-APK downgrade support from that test.

## Required evidence

- Current incoming, mirrored, restored, unverified, and older imported origins
  remain distinguishable. No source is silently promoted between lanes.
- Crash/restart before save, during uncertain save and after readback produces
  no IDS resend, duplicate archive or lost durable candidate.
- A message independently uploaded by another Apple client is not duplicated or
  overwritten by the new lane.
- Direct and group sender/body/time remain correct; attachments and reply/edit/
  unsend behavior stay explicitly scoped and tested.
- An independent Apple client consumes the archived result correctly. A
  successful read through the same custom encoder/decoder is not that proof.

## Existing split-group repair

The observed live row has 13 incoming messages and no local-send/adopted-send/
mutation journal references. Its exact GUID matches the canonical cloudGuid,
and that canonical row passes the production local group-binding validator.
These are prerequisites, not authority to call `Chat.merge`: that method only
fills UI values and does not transact Message relations or protected bindings.
Do not rename/rekey canonical rows, move messages, or hide the split until a
separately reviewed local repair preserves every dependency and user setting.

Prefer finishing the received-archive origin and its relationship handling
over an unrelated destructive chat merge. No live data has been changed by
this investigation.
