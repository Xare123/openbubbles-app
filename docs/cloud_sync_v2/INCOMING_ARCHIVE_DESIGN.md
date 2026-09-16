---
type: design
title: CloudKit incoming-message archival gap and implementation boundary
description: Source-backed coverage gap and minimum separate archival path required before claiming complete two-way sync.
resource: openbubbles-app
tags: [cloudkit, receive, archive, production-gate]
timestamp: 2026-09-16
---

# Decision

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

Next functional gap: Found-to-reader reconciliation. Use the normal semantic
decoder/projector and existing duplicate/edit/retraction rules; do not assign
Message.text or make a fake send. Stage a normal protected record identity and
raw envelope, bind exact generation/record/ETag/source, adopt that read durably
without advancing Apple's cursor, then let normal projection update the row.
If a later retained save/tombstone or different known version already exists,
retain/defer rather than inject an older observation as a newer fetch sequence.
Recover the same adopted read on restart. Add direct, stale-version, local-edit,
unsend, crash/recommit and duplicate-pull behavioral checks before enabling it.

## Exact lookup and local ownership, current continuation

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

Current app14ce1d749/native6eaba5c22 plus fixture repair406677804 is qualifying
a two-phase handoff in run35138299645:
network preparation retains an opaque in-memory result; local stage/adopt/commit
runs under cross-engine exclusion without holding that short lease over network
I/O. Lost local commit responses remain state1 and retry their exact observation.
State2 marks only finished local inspection, not projection or cloud archival.
The received table adds nullable observation property14 and preserves prior IDs.
Final27-file Dart integration passed811. Native compilation passed on predecessor
run35136724953, then its new noncanonical-wire fixture failed before testing the
handoff: ETag tag1 was accidentally still first. The repair appends it last and
keeps the inequality assertion. The rerun must pass; no native-green claim yet.

Remaining vertical work: bind Found through normal semantic projection without
overwriting newer local edits; admit a freshly absent received source through a
distinct source-bound encoder into the existing single-submit/readback outbox.
The generic outgoing encoder rejects received sender/direction, deliberately.
Do not relax it or synthesize a positive IDS-send receipt to reuse that lane.
Incoming groups/media and pre-seal readiness failure still need coverage.
Capture and inspection stay default-off until their respective live gates pass.

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
