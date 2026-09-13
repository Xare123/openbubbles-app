---
type: historical_snapshot
title: CloudKit treemap historical tail before multipart-reply qualification
description: Preserved superseded critical-path, ownership, and mutation-development notes from the September 13 treemap consolidation.
resource: openbubbles-app
tags: [cloudkit, history, qualification]
timestamp: 2026-09-13
---

# Historical snapshot, not current instructions

The text below is preserved from the treemap before consolidation. References
to pending native qualification, initial-create-only transport, and pristine-only
mutation tests describe older checkpoints. Use the current treemap for active
source versions, live evidence, gates, and next actions.

## Current critical path

1. Finish native session-candidate qualification (run 34766997568), then inspect
   the retained seven-record sample with its separately verified/signed DLL.
   V2 context uses the existing string ABI, so no bridge regeneration is required.
   Preserve records and scope fences. Qualify late/out-of-order inherited-media
   convergence before claiming session restoration complete. Ordinary Windows
   read and timestamp write/echo/restart proof remain established on prior source.
2. Reconnect and inspect the existing Pixel session. Use verified cooperative cancellation
   or let it finish; observation timeouts do not prove termination. Install after native settlement.
3. Resume through Profile > Backup. Verify progress, media access between sessions,
   pause/resume, readable history, terminal state and retained categories.
4. Use the ordinary composer on automatic-upload builds for approved +16177106179.
   The manual-write host gate intentionally rejects that build mode. Recover existing
   exact intents before creating another test.
5. Verify exact readback, restart and independent rendering, then approved groups,
   attachments, reactions, chained edits/unsends and supported deletions.
6. Qualify a durably bound fresh-stream recent-first policy in Windows/cloud tests
   before another APK. Existing cursors keep their order.

Retained totals include excluded telephony, tombstones, malformed entries and
dependencies; they are not the number of missing readable messages. The last
observed Pixel pull was incomplete.

### Current ownership for continuation

- Parent owns native converter/API/DTO/content-digest integration and real account
  tests. Nullable `extensionMetadataJson` requires newly generated bindings and a
  matching DLL before any live use. Existing qualified runtimes remain preserved.
- Native helper worker is closed and its bounded pinned-plist implementation is
  under parent integration. The constructor validates metadata schema and bundle
  binding; malformed/unsupported archives remain retained.
- Both Muse workers are closed. Parent reviewed/refined the Dart integration and
  isolated Windows test lane (pilot `02fc8e810`). New component tests needed the
  existing route/ownership fixtures; parent fixed those and completed decoder
  boundary tests. All source/evidence remains preserved for native qualification.
- Hash exact transport UTF-8; validate parent bundle identity before transaction;
  store metadata atomically. Cloud bridge run 34761004976 produced the matching
  bindings and compiled the library; the test fixture type error is corrected.
  Current local evidence: 169 prepared/core/adapter, 45 decoder and 75 existing
  harness/write/precision/digest tests pass across focused runs. Static analysis
  of the four production Dart files has no issues. Native suite/live proof pending.
- System-event worker is closed; its reviewed change excludes normal-message
  `eCode`/`flags` only from class 3-7 unsupported-event classification, never from
  ordinary message conversion. It restores no message by itself; all five targeted
  system-event tests passed in Windows run 34762729315.

Current session candidate: closed v2 JSON context carries base/update role, wire
session GUID and keyed logical identity; v1 remains accepted. No generated-bridge
change is needed. Native type 2 is admitted only with a valid app balloon/session;
type 4000/meta and 1000/no-balloon remain retained. The semantic parent represents
the exact session base, independent from tapback/reply fields. The projector proves
base/predecessor ownership and chat/provider agreement, copies attributed references
without moving attachment backlinks, and groups rows with `amkSessionId`.

Local tests pass: 247 retry/gateway/quarantine/registry/decoder; 31 metadata parser;
149 adapter before the final equal-time case; nine targeted session cases; eight
cache-invalidation cases; shared digest vectors. Static analysis has no issues.
Session context is not yet native-qualified or exercised against retained data.
The new cache watch is lazy, store-bound and disposed on close.

Convergence source implemented: scoped projection markers distinguish inherited
content from owned media and bind its rendered-content digest. A late update
repairs later inherited rows in paged reads inside the original transaction,
stopping at the next own-media row. Source records, snapshots, payload metadata,
and attachment backlinks remain unchanged. Four local tests cover late arrival,
own-media stop, independently changed content, and a 260-row chain including
rollback on a late-page conflict. Native/live qualification remains outstanding.
All Muse workers are closed; unique code, logs and rollback material are preserved.

## Existing-history adoption evidence gate

Automatic adoption is not safe from the offline checkout alone. For each
queued intent, a content-free live observation must first distinguish the six
`existing_history` categories and prove exactly one current direct-iMessage Chat
owner under the same account, protected store, scope, generation, writer epoch,
and native session. The proof must bind the canonical Chat lookup hash, semantic
snapshot, service-identifier alias, canonical/member record map, latest applied
non-tombstone save, ETag, protected record reference, and payload digest. A
later retained save, tombstone, competing owner, or native `overlaps` /
`incomplete` result remains a defer.

Only after that proof may the production local-send admission seam atomically
re-read the state-1 journal intent and unchanged provisional Message/Chat,
adopt the exact existing relationship, and persist its durable reconciliation
binding under the existing `v2ReadWrite` interlock and auth fence. That
transaction must create no Chat stage, outbox row, record-map mutation, remote
save, merge-update, or delete. Restart must repeat as a no-op; any mismatch must
roll back and leave the intent ready/deferred. A bare Message reparent is not a
fallback because the journal source digest binds the original Chat row and UUID.

## Edit and unsend evidence gate

Apple carries edit history and retracted parts inside the existing message's
`msgProto.messageSummaryInfo` blob (`ec`, `ep`, `otr`, and `rp`). The read path
already validates part-key consistency, page-local edit ordering, and the rule
that present-but-empty collections are absent rather than an explicit clear.
Native revision numbers are sorted indexes regenerated for each payload, not
cross-record causal clocks. Local projection must keep the displayed body and
edit history on one compatible snapshot. A complete newer history may replace
both; an older subset cannot replace either; incompatible histories remain
retained with a content-free conflict. Retractions are an irreversible union
for the exact owned message. Do not synthesize multipart bodies from histories:
the renderer takes current text from the attributed body, not its edit list.

**Read transition candidate:** the native digest still includes current body
bytes. The inbox applier may reconcile that difference only through the optional
transaction proof: exact stored snapshot, same physical Message record, distinct
non-null ETags, exact protected reference and an earlier durable applied
replay cross-checked against its original inbox row. The bounded lookup reads
at most two matching receipts and rejects ambiguity. The real canonical adapter
then verifies owner, chat, sender, creation date, subject, full body/part ranges
and compatible edit/retraction lineage without modifying rows. Unchanged parts
and their order are preserved; unknown retractions and contradictory text fail.
One-body multipart content is supported; ambiguous multi-body encodings remain
conflicts. Global immutable and edit-revision conflict checks stay enabled.

The combined regression uses real ObjectBox, the inbox applier and a synthetic
decoded DTO boundary. It proves edit, forged-body rejection, stale replay and
undo across reopen with zero outbound rows. It does not prove native Apple
decoding, capture a real Apple update or authorize remote writes. Earlier raw
records/receipts remain intact. Outbound ETag handling is a separate gate.

The legacy `Message.toCloud` already serializes these fields, and generic
`CloudMessagesClient.save_records` is called by `save_messages` for message
updates. Reuse that encoding. Its `SaveRecordOperation::try_new(update=true)`
does not set a predecessor record ETag; it is not evidence of V2-safe causal
conflict handling. V2 transport currently remains initial-create-only.

Verified protocol lead: the [Apple daemon request header](https://github.com/JaviSoto/iOS10-Runtime-Headers/blob/1501f5e689fda4644df0adbffc50c0f737c4ab96/PrivateFrameworks/CloudKitDaemon.framework/CKDPRecordSaveRequest.h)
has a request-level `etag`, distinct from the nested Record's `etag`. The
header alone did not establish wire numbers. That gap is now resolved by
[Apple's actual serializer/decoder](https://github.com/Xare123/openbubbles-app/actions/runs/34620660937)
on macOS 15.7.9 (24G830), not by our own generated request:

| Observed property | Wire representation |
| --- | --- |
| Request `etag` | string field 4 |
| `saveSemantics` | varint field 6: `1 = failIfOutdated`, `2 = failIfExists`, `3 = override` |
| Zone / record PCS tags | string fields 7 / 8; neither is the version precondition |

`tooling/cloud_sync/apple_save_wire_probe.m` loaded the local
Apple serializer on an isolated macOS runner with synthetic values only. The
opt-in `apple_wire_probe` input on Windows validation skips both Windows build
jobs. Run `34620660937` compiled, serialized and round-tripped each property in
27 seconds, with no Apple credentials, user profile or CloudKit operation.
Image UUID: `002449BA-60D0-341F-933F-D5582A63F116`. Full synthetic report SHA-256:
`e05fdca3ee4378bb566a0cfaed20a1032d501007ccaa812380a0db7bd823facf`.
Bounded enum observations are not an exhaustive enum definition or server proof.

The separate `SaveRecordOperation::try_update_if_unchanged` builder is added
but **not connected to V2 transport**. It binds the exact fetched record identity,
type and nonempty ETag, checks the supplied PCS zone and unchanged default key,
and rejects custom record protection instead of silently replacing it. Legacy
save bytes remain unchanged. Independent Apple wire fixtures and rejection tests
passed GCE qualification. The caller still needs durable mutation intent,
account/container/database authority and unknown-outcome readback reconciliation;
an ETag conflict after a lost success response does not prove that nothing saved.

The native-only `cloud_sync_message_proto_patch` candidate patches decompressed
msgProto fields 3/4/7 while preserving all other wire spans verbatim. It rejects
ambiguous mutable fields and malformed/over-budget input. All nine synthetic
tests passed within 533 app-native tests on `a42ecb74f`, GCE `34644303016`, with
exact bridge regeneration and successful cleanup. Independent VM and runner
inventories were empty afterward. This helper is not connected to a writer;
it does not prove Apple mutation semantics, PCS authority or causal merge.

The predecessor lookup now retains the fetched `Record` instead of rebuilding
it from `CloudMessage`, whose fixed field list drops unrecognized fields.
This preserves decoded CloudKit fields and embedded opaque bytes, not unknown
outer protobuf tags already discarded by the transport decoder. Future saves
must be field-limited merges so omitted server fields remain untouched. The
native-only version result has redacted debug output and carries no write permit.
Exact identity, type and nonempty ETag checks precede admission; missing ETags
remain unresolved, never evidence of absence. Qualification is tracked above.

Do not construct mutation summary info through `Message.toCloud()`: its typed
roundtrip injects defaults and omits unknown plist entries. Patch the retained
plist value tree and preserve existing history/body bytes instead. Source review
found a concrete producer/consumer mismatch: legacy `rustpush_service.dart` and
`cloud_sync_local_mutation_projection.dart` both retain edited parts/history
when adding a retraction, while the reader rejected their overlap. `5bb07dcdf`
removes that mutual-exclusion check, not timestamp/body/part validation. History
and terminal state are retained together; the real ObjectBox regression keeps
the message unsent after reopen and stale replay. This is current-app contract
evidence, not a claim of independently captured Apple serialization. The old
quarantine enum remains for persisted/bridge compatibility; do not reset stored
records or tokens to force adoption of the repair.

Dependency `fbf9b4c` passed native-only GCE qualification `34621760644`, pinned
by app `4dc324995`: 297 tests, zero failures. Compile took 56s, tests 6.3s,
and the full run including cleanup took approximately 5m12s. Cleanup completed
at 16:29:20Z; independent VM/runner inventories were empty. No APK, account
access or writer activation; both writer flags were off.

The next end-to-end path is:

```text
durable edit/unsend intent (mutation UUID distinct from target message GUID)
  -> positive IDS confirmation for that exact mutation
  -> reflected body/history/retractions and protected native source
  -> fetch exact remote predecessor under unchanged writer authority
  -> retain merge candidate + ETag + request identity before submission
  -> one version-checked save -> exact readback -> confirmed
     conflict/unknown -> readback/refetch, never blind recreate or overwrite
```

Reuse existing request/receipt boundaries; do not weaken the initial-send
journal's rejection of already-edited messages. The ordinary edit/unsend route
currently invokes its legacy upload before its explicit reflection call and
can return while native still owns a background IDS send. That ordering is not
proof of a live legacy bug (local broadcast can race it), but it cannot serve
as the V2 durable mutation/positive-confirmation contract. Preserve unknown
remote fields and previous attempts when deriving a new candidate.

Mutation source checkpoint `c65584196` adds a native-only exact-intent codec
(`rust/src/cloud_sync_ids_mutation_source.rs`). It separates the mutation UUID
from the target GUID/part and preserves the sender, ordered route, text runs,
formatting and indexes. Reconstruction uses retained intent, not mutable chat
state; prepared validation permits only `MessageInst::prepare_send` changes.
Native protected staging is now implemented in
`rust/src/cloud_sync_ids_mutation_stage.rs`: one immutable source/hash wrapper,
its own `idsMutationSource` purpose, bounded descriptor, and exact committed
lease validation before reopen. The native-test-proven integration adds
purpose-typed bridge staging/restore, exact pre-send and prepared-send checks,
and a version-4 native positive-IDS receipt that preserves mutation ownership
through replay and acknowledgement. Historical receipt versions 2/3 retain
their original meanings; create consumers retain mutation receipts without
acknowledging them. That native checkpoint predates the journal integration
described below; neither checkpoint enables a CloudKit existing-record save.
Text-with-flags edits and unsends are represented; unsupported replacement
parts must remain explicit pending work, never flattened or counted complete.
Next integration: protected source adoption/commit adapter and app receipt
recovery with an exact-source local projector, then predecessor/readback.
Initial-create admission remains unchanged.
The codec-only checkpoint passed GitHub `34624049558`; expanded codec and
protected staging passed exact-source GCE `34625938024` on `3d95920ff`:
503 Rust tests and bridge reproduction succeeded. The subsequent API/send and
version-4 receipt integration `ab7f640c5` passed native compilation and 513 Rust
tests in GCE `34627823377` (`us-west1-c`, app-Rust-only, both writer flags off).
Only the expected generated-binding drift gate failed. Artifact `10274958197`
was SHA-256 verified and its exact seven generated files imported; five have
logical changes. Unrelated dirty generated files were preserved. The 39 focused
Dart tests now pass, including mutation/attachment bindings and FaceTime export
and diagnostics contracts. This is not a full Dart suite or native/app runtime test.
Cleanup succeeded at 17:38:18Z; independent VM/runner inventories were empty.
The new bridge requires its matching native library. Do not apply this Dart
binding as an overlay onto retained Windows native `62221f9c2`, bypass the FRB
content-hash check, or infer that the current installed APK contains this API.

Journal integration decision: keep mutation intent separate from the existing
initial-create journal, whose immutable source must remain unedited. Reuse its
transaction/receipt lifecycle, not its create-origin validator. Bind operation
UUID, target GUID/part, target snapshot and protected source independently.
Stage and durably adopt the original mutation before IDS submission; positive
native confirmation and exact receipt replay precede local reflection and
CloudKit admission. Remote-record availability gates the later CloudKit update,
not ordinary IDS edit/unsend support. A missing remote predecessor never permits
recreating a previously known message. Receipt recovery and all protected-byte
liveness roots must include the new journal together, not in later patches.

The local journal foundation is now source-implemented and covered by 351
focused Dart tests across eight suites. It uses additive ObjectBox entity 35
(all pre-existing entities and their UIDs are unchanged), with separate
operation UUID and target GUID/part, a protected source binding, and a snapshot
of the original target. The state path is staged -> submission claimed ->
positive native receipt retained -> local reflection committed. A claimed
unknown result cannot be resent automatically. Cold receipt replay retains
the original native session binding, even under a new live authenticated
session. Both protected-byte and lease scans retain every journal state/account.
Three parent-authored regressions reproduced acceptance of a wire with an
unrelated sender, recipient or conversation; route binding now rejects all
three. A projection cannot change routing or writer epoch during its commit.
Local projection currently has a tested transaction seam only, not a
qualified source-derived projector. Protected-source preparation now composes
adoption, idempotent original-lease commit, exact restored-wire validation and
one-time submission claiming under the existing exclusions/auth fence. A
commit failure can reuse the staged source after reopen; a claimed outcome
cannot re-enter submission. Both live callbacks and cold native receipt replay
route mutations to their own journal without create admission or receipt
acknowledgement. This is not connected to ordinary edit/unsend capture or a
remote save. The Windows request now composes submission and confirmation;
exact-source projection remains required before enabling app capture.

GCE Dart-only `34629000411` passed 3,184 Dart tests plus 14 outbox and three
evidence-output cases on `b701e36a7`, before this journal addition. Cleanup
succeeded at 17:51:15Z and independent inventories showed zero VMs/runners.
Despite its generic job label, this run produced no APK. Exact journal-source
full-suite qualification remains separate from these prior results.
Checkpoint `f24e7379f` failed GCE Dart qualification `34631352089`: 3,220
passed, three migration fixtures failed because they retained entity 35 while
pretending to be an entity-32/33 model, or expected the last entity to be 34.
The fixtures are corrected, and an actual entity-34 upgrade/reopen case now
preserves existing messages and send intents. Independent comparison confirmed
all 26 predecessor entity definitions and retired entity IDs are unchanged.
Cleanup succeeded; subsequent VM and runner inventories were empty.
Windows fast-loop `34631493537` passed on `f24e7379f` with isolated pilot
`9c63ab24d`: 38 focused Dart tests, 51 packaged-DLL codec cases, ARM64 load and
invalid-launch smoke. Its local-write configuration was compiled only, not run
against an account. Artifact `10277865440` is not yet imported or locally
signed. Preserve native `62221f9c2` until a matching replacement is qualified.
This result does not replace the installed Windows or Pixel app.
The combined source-preparation, mutation/send/reaction/upload journals, GC,
migration and app receipt-composition cohort now passes **410 local tests**
across 12 suites. This is synthetic/local-store qualification, not an Apple
account test. Full cloud qualification must be rerun on the repaired candidate.
Source preparation/receipt routing and fixture repairs are committed as
`c988a5844`. Reviewed default-off FaceTime diagnostics are separate at
`99d45a9c7`. Full Dart rerun `34633136729` passed that exact combined head:
3,237 Dart tests, 14 outbox cases and 3 evidence-output cases. Cleanup and
independent empty VM/runner inventories were verified before the next run.

Windows mutation experiment: native source `db5c1508c` passed compilation and
517 Rust tests in GCE app-Rust-only `34634299421`, N2D-16/us-west1-c, writer
flags off. Only generated-binding drift failed. Artifact `10277519451` was
checksum-verified and imported: the exact API plus paired bridge dispatch/hash
changes, with unrelated generated edits preserved. Cleanup succeeded at
18:47:41Z and independent inventories were empty. The API waits for
positive IDS acceptance and persists the mutation-purpose receipt. The working
Dart request-v6 branch now uses separate mutation journaling, never initial-create
admission. Missing native callback fails before authentication or claim. Requests
bind one exact prior successful test send, direct plaintext part 0, and a fresh
60-second qualification window. Reopening a claim can reconcile retained receipts
only, never submit again. The composed local pipeline passes 39 journal tests,
including timeout, wrong-purpose receipt, post-send auth change, and reopen.
The 75-test local cohort covers request compatibility, exact target/payload,
source-to-confirmation composition, unknown-result restart and branch separation.
The request/target agent's patches were reviewed, refined and retained; agent
shutdown was verified. Combined source `89c06f4de9ce7f51dc78ff233d19cff8dfb0750a`
failed GCE Dart-only run `34635968989`: 3,256 passed and one structural test
still expected only one Windows protected-transport construction. The test now
checks initial-send and mutation compositions separately, their shared entry
gates, staging and branch isolation; all five focused bridge-contract tests pass.
Cleanup completed at 19:07:49Z; independent VM/runner inventories are empty.
Windows ARM64 fast-loop `34635971964` passed on `89c06f4de`: 38 focused Dart
tests, 51 packaged-DLL codec cases, ARM64 load and invalid-launch smoke. Artifact
`10277893755` remains cloud-retained rather than downloading an already superseded
native candidate. It lacks the prepared-time field. No APK is requested
despite the generic GCE job label. Full combined qualification and Windows runtime proof remain. No real
edit/unsend sent, local body projected or CK update enabled.
Before local reflection, qualify mutation time semantics: `new_msg` starts at
timestamp zero and `prepare_send` changes it. Do not project time zero, or
mistake receipt arrival time for the exact on-wire edit time.
The inspected version-4 receipt had no prepared timestamp. The next native
candidate retains the validated actual wire time in a protected version-5 mutation
receipt and carries it through replay/ack. Both ordinary native confirmation and
the Windows experiment use it only after exact prepared-source validation and
positive participant acceptance. Existing v2/v3/v4 shapes and receipt IDs stay
unchanged; a same-ID time change, upgrade or downgrade cannot overwrite evidence.
The original staged source remains immutable. Native `6b59bf451` passed 524
Rust tests and bridge compilation in GCE `34637298156`. Only expected binding
drift failed. Artifact `10279009262` was checksum-verified, exact seven-file
allowlist reviewed and imported. Cleanup passed; independent VM and runner
inventories were empty. The three changed generated files now carry the optional
prepared time. Do not pair these bindings with the predecessor Windows DLL.
Dart receipt v2 proof binds this exact time; legacy no-time v1 proof stays
unchanged and cannot authorize reflection. Time alteration/removal/upgrade,
cold replay and unsupported-time retention passed the 87-test combined cohort.
Source-derived reflection is now composed under protected-store and auth
exclusions, with an atomic target-snapshot check and no CloudKit save. A cold
launch rereads the exact native receipt and committed original, never prepares
or sends another mutation. The combined journal/staging/initial-send/Windows
cohort passes 245 tests; eight additional pure projection cases cover empty
summaries, exact UUIDs, Unicode formatting, second edits, legacy timestamp
comparison, independent history copies and anti-resurrection. Targeted analysis
is clean. Full Dart, matching Windows build, live edit/unsend and genuine Apple
before/after record evidence remain next. No schema change duplicates time.

Retained-version inspection now has live **offline** evidence: the Windows
profile contains 23,413 scoped record groups and zero multi-row groups, so
it cannot supply a same-record before/after pair. The source database hash
was unchanged under the launcher lock. Schema-12 metadata-only inspection
passes seven ObjectBox tests, including generation/zone isolation, capped
distinct-value counts, missing digests and source preservation. Do not repeat
this inventory without new ingestion; obtain a targeted real Apple edit/unsend
transition when a second client is available. Storage/receipt integration can
continue independently, but remote updates remain disabled.

GCE Dart-only `34625386547`, source `4f7674c1f`, passed 3,169 Dart tests,
14 outbox contract cases and 3 evidence-output cases. Cleanup succeeded at
17:13:11Z on September 11; its exact VM and runner registration were absent
from subsequent inventories. Native-only `34625938024` on `3d95920ff`
passed in `us-west1-c`; cleanup succeeded at 17:23:33Z and independent VM and
runner inventories were empty. Its scope predates the new bridge/receipt integration.
The new Dart mutation-binding codec passed 10 focused tests plus the 12
unchanged attachment-binding tests; this is identity parsing, not journal,
delivery, CloudKit save or independent-client proof.

Do not enable update transport from structural inference alone. First capture
one genuine Apple edit and one unsend read-only, proving the same record name,
the before/after protected system fields and change tag, the complete rewritten
or merged field set, and the resulting `messageSummaryInfo` bytes. Then require
stale-tag refetch and reapply, exact retry identity, and anti-resurrection proof.
Explicit `NOT_FOUND` is not permission to recreate a previously known message.

An older review mentioned a three-file identity scaffold without identifying
its paths. It was not located in the current checkout and must not be counted
as implementation. Historical discussion remains in the investigation log.

### September 12 Windows causal-write qualification

Candidate build `7f25691656ef-dirty-ca780901f9c8-local-write` used the retained
Windows profile and approved test route only. Edit request
`qualification-20260912-terminal-edit-21` resumed a previously claimed
positive IDS mutation without another native send. Exact predecessor recovery
crossed the deliberately narrow stable E -> mutation-unknown E+1 -> stable E+2
authority transition, reconciled one unknown operation, confirmed one exact
CloudKit update, and left zero not-applied, diverged, or unresolved operations.
The production Android restart path now probes the exact reflected mutation
before trying native receipt restoration, so an already-reflected state-3/4
intent proceeds to adopted-operation reconciliation instead of re-entering the
fresh-write reflection path. All other errors remain fail closed.

Unsend request `qualification-20260912-unsend-24` targeted fresh, independently
confirmed parent request `qualification-20260912-unsend-parent-23`. It attempted
one native unsend, retained and acknowledged its positive mutation receipt,
submitted one version-checked CloudKit update, confirmed one exact readback,
and reported zero recovered, unknown, not-applied, diverged, or unresolved
operations. Local reflection completed. Read-only inspection of a disposable
ObjectBox copy found mutation terminal state 5, structurally valid source
binding, positive IDS and local-reflection markers, matching route and retracted
display, zero ordinary initial-send intents for the mutation, and no change to
the retained source database.

Request `qualification-20260912-terminal-unsend-22` was rejected locally before
claim or network activity because its parent had already been edited. The
qualification harness at that historical checkpoint permitted only one mutation over a pristine parent;
it does not weaken initial-create validation to test chained mutations. A
separate fresh parent was used instead. These results close bounded Windows
protocol execution for independent edit and unsend. They do not close ordinary
Pixel UI capture, Android lifecycle/restart behavior, independent recipient
display, attachment mutation, chained mutations, or the broad regression and
fresh-Canary gates.

