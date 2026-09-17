---
type: architecture
title: Cloud Sync V2 Current Connection Treemap
description: Current source of truth for CloudKit V2 architecture, safety boundaries, qualification state, and next gates.
resource: openbubbles-app
tags: [openbubbles, cloudkit, messages-in-icloud, architecture, recovery, canary]
timestamp: 2026-09-16
---

# Cloud Sync V2 current connection treemap

This document is the short operational source of truth. It contains current
architecture, safety rules, qualification state, and the next falsification
test. Dated investigations, obsolete candidates, run-by-run notes, patents,
and historical evidence remain intact in the
[investigation log](cloud_sync_v2/history/CLOUD_SYNC_V2_INVESTIGATION_LOG_FROM_2026-09-07.md).
The [bundle index](cloud_sync_v2/index.md) points to both documents and the
current evidence set.

## Decision

Treat Messages in iCloud as a durable replicated log. Remote ingestion and
local projection are separate progress clocks. A successful fetch is not a
successful sync. Undecryptable or temporarily unprojectable records remain
durable repair work and never disappear merely because a later token exists.

Every protected operation must remain bound to one exact tuple:

```text
account fingerprint
  + live CloudMessagesClient identity
  + read-authentication generation
  + protected-store identity
  + native writer-pause permit
  + container/database/zone
  + checkpoint generation
```

If any member changes, fail closed and retain the evidence. Never borrow a
different identity or container, create PCS state from the read path, fall
back to legacy sync, clear a cursor, or continue under a replacement account.

## Status legend

| Status | Meaning |
| --- | --- |
| `LIVE-PROVEN` | A content-free trace exercised the exact boundary on the named platform. Proof does not transfer between platforms. |
| `TEST-PROVEN` | Source-contract or behavioral tests cover the boundary; current-device proof remains. |
| `SOURCE-IMPLEMENTED` | The repair is in the candidate, but full exact-source qualification is incomplete. |
| `IN REPAIR` | A concrete counterexample invalidated the previous candidate. |
| `GAP` | A safe end-to-end behavior is not implemented or needs a product decision. |

## Current candidate

### Immediate handoff: heading qualification and relay isolation, September 16 evening

- **SOURCE-IMPLEMENTED:** heading source `d1734c01d` failed hosted run35171127739
  with E0004 in canonical identity validation. The correction now verifies the
  optional linked Message hash while preserving the heading's own identity.
  Four reviewed native regressions cover foreign-key, wrong-envelope and actual
  reply cases; native compilation/execution of the correction is still pending.
- **TEST-PROVEN Dart:** 377 affected decoder, projector, registry, applier and
  store-gateway cases pass, plus two digest tests. Ten heading cases cover reopen,
  replay, real type2 child content, missing/self/foreign navigation and actual
  reply dependencies. A detected snapshot-parent mismatch is now rejected.
  Two frozen heading digest vectors await independent Rust verification.
- Generated artifact10475984769 was downloaded and its exact eight-file inventory
  checked; only one Dart enum line and three Rust dispatch lines changed. Both
  generated guards pass. Next hosted run must prove regeneration reproducibility
  and execute native tests. **Installed Windows native remains 3c780a8d7**;
  current application/heading source must not run against that older DLL.
- Pixel Canary20002227 logs show IDS6005 at16:46 and no-identity/send6005 at
  16:51 and18:46. The last saved relay probe failed at18:15; its generic warning
  does not distinguish network, validation rejection or malformed response.
  User reports Windows/Canary contention with this iPhone relay. No competing
  Windows live client was identified. Phone status: sync/logout/coordinator idle,
  authentication flag true, outbox blocked. No repair/reset was invoked by agent.
- **TEST-PROVEN, not activated:** a fresh user-provided Mac hardware export
  decodes through the signed Windows3c bridge in an offline native test.
  Eight protected profile hashes are unchanged. `MacOSConfig` still rejects
  validation on non-macOS; both IDS and Apple delegate refresh require it.
  Cached CloudKit access is not proof of a durable relay replacement. Neither
  Windows nor Pixel hardware/account was changed; activation material is not
  stored in the repository or evidence files. Prefer serialized live relay use.
- Relay source helper Zeno was reviewed and closed, shutdown verified. It made
  no files or worktree. Supported agent-session deletion is unavailable; no
  transcript was manually removed. No new paid cloud build or APK was started.
- Heading identity helper Aristotle was reviewed, integrated and closed with
  shutdown verified. No active child remains. Its unique synthetic test source
  is retained. Next action: qualify the corrected committed candidate on hosted
  Rust CI, then build the matching Windows host before live heading replay.

### Current live-qualified parent locator, September 16

App integration **3c780a8d7bd1459988a95d4140942ce39ff63992** includes a cached-only
native parent locator from source **8859a4f1aeac7c83554a3ca805177936340cabc0**.
The locator derives an exact keyed Message record identity from a freshly
authenticated child (extension/reply/reaction/attachment). No caller-supplied
GUID, remote fetch, file staging, cursor change, projection or write is added.
The opt-in Windows inspector validates its child/generation/session binding,
then can query the physical journal even when no canonical map exists.

Hosted native run **35163901886 passed**: 753 app tests (including eight new
locator cases), 351 rustpush, 11 authentication-provider and 40 protector tests.
Artifact 10474590417 has eight generated members, all verified and imported;
SHA256 `f13a2b6ecf2c1c4b543eaac11c7eaeac5e51b2c25bb50becfdb5c717c98d739b`.
Both generated guards pass. Reproducibility against the pre-generation commit
was deliberately skipped. Targeted Dart integration passed 34 cases; analysis
has no errors/warnings, with eight pre-existing harness style infos.

**Windows run 35165381313 passed**, source 3c780a8d7, isolated pilot
bb0411345b3396dbceb5231aef6f6622f8801a85 on
`agent/windows-dependency-locator-20260916`. This adds the eight exact ARM64
selector tests, nine parent-observer tests and source-provenance inputs to the
existing GitHub-hosted qualification. It passed 694 Dart, 51 native encoder and
13 native diagnostic cases, including all eight locator cases. All 61 source
inputs, six submodule pins, 13 log hashes and three ARM64 binaries verified.
Watch3481 is terminal; do not dispatch a duplicate.
The shared GCE pilot
remote advanced independently to d5533dd1e; it was not merged or overwritten.
Its pre-existing local asset_graph deletion remains untouched.

**Installed Windows native is now 3c780a8d7**, signed DLL SHA256
`9aadb2bcc9c4abd040977c8db28ecd243736b63ff2275eada7296d6f75bbe849`.
Existing signer only, vendor ObjectBox untouched; the prior aa953 bundle remains
recoverable. Inner archive SHA256
`6c5a5c6eca087f901177899094db5c53d57c168fd8ef0f3acdefa81ba7130947`,
provenance `cc6042f8cdd597a3d793e4f3765995933711f8320c7ca18819b00a4806e5e142`.
Import still checks exact source3c780a8d7. Updated verification tooling71809eb67
takes explicit `-ExpectedNativeDiagnosticTestCount 13`; its old default5 remains
for rollback archives. Verifier23 and importer36 synthetic cases passed.
The private observation wrapper takes these exact pins plus `-LocateParents`.
No new APK or paid GCE run from this task.

**LIVE-PROVEN** observation78a51359654e103f086601d27790bb83 (Dart71809eb67)
located all 13 sampled ready children's physical parent identities. Five
extension parents ARE cached, but the decoder rejects association type3. Two
attachment parents decode as excluded SMS-family; six are unobserved in the
current journal, not proved absent remotely. Checkpoints/outbox and observed
inbox metadata were unchanged; raw output removed and process cleanup verified.

**Root repair being qualified: type-3 heading support.** Same-run native shape logs show
bare association references, both range fields present, renderable text and an
Apple non-URL extension. Reviewed Beeper source classifies3 as heading, not
reaction. Its fixtures include different own/linked GUIDs and range lengths
0 and -1 in SQLite, so do not reinterpret3 as ordinary0, impose self-reference,
or infer CloudKit's unsigned range encoding. Represent heading/link metadata
explicitly and preserve exact wire values; its link is not automatically a
required parent or session-base identity. Source now implements this shape,
but the compile failure above prevents qualification. Cached parent decode, not another
history sweep, is now the critical path. Detailed primary references are in
the investigation log. Exact fetch is still needed only for unobserved parents.
No helper or live-profile process is active; the profile window is released.

### Last installed Windows qualification and storage baseline

Product/native integration16430e0f2 is unchanged. Fixture-only source
aa953639a3c7dfb5b6f40fcb742b3f60b9b81953 corrects a remaining generation1 key
inside the edit/reopen test. Hosted Windows35152394873 failed681/682 on that
fixture; parent reproduced it locally, changed no product behavior, then passed
157 canonical-adapter cases and the exact21-file Windows batch682/682.

Corrected Windows run35154038683 PASSED, pilot13f388527237b82750824e1930bbc149fbdcc63d,
native-test-host/read-only.682 Dart cases and51 native encoder cases passed,
plus selected native suites.55 source inputs and13 logs match provenance;
53 source hashes use Windows CRLF checkout form, not a content change. Three
ARM64 binaries and the vendor ObjectBox pin passed. Watch42650 is terminal.
Evidence: build-evidence/windows-reader-35154038683/verification.json.

Imported and signed exact sourceaa953639a with the existing engineering signer.
Signed native DLL SHA256:
`52887b284c590a19ec1a53c61ed24057ad802413d37cc344c64bdfb155d5edaa`.
The original source branch was restored after exact-source import. The prior
b9c567f runtime archive/provenance remains verified/recoverable; the importer
removes its temporary transaction rollback folder after successful install.
A hash-verified156,438,528-byte private pre-schema DB snapshot is preserved.
No signing policy or account registration was changed.

**LIVE-PROVEN Windows read/restart:** session339c757b fetched109/applied79, then
zero/zero at an empty terminal page. The initial two-pass gate remained unproven
because its first pass changed state. A second unchanged-source session9566ce36
then passed two fresh processes with zero fetch/apply, all three zones empty-
terminal, retained count unchanged and outbox24 unchanged. No remote writes or
content exposure; process cleanup confirmed and raw stdout/stderr removed. The
profile window is released. This does not prove Android lifecycle or full sync.

**LIVE-PROVEN full Windows retained sweep:** sessionb2a08181fd98c588ec06171c6a9db0a1,
Dart source8e652804f/nativeaa953639a, finished23:03:24Z. Remote head drained;
all798 remaining blocked message saves and1011 attachment saves examined in58
windows, with zero further applications in this final sweep. Outbox24 unchanged,
no remote writes, cleanup confirmed. Retained total6269 =3779 known excluded
saves +681 tombstones +1809 unresolved saves. Thirteen message records left
the retained backlog across these runs; no independent UI proof is inferred.

Post-sweep observations `bf3b650c`, `4e493089`, and `f6241fb4` each examined
37 cases without checkpoint/outbox or sampled-inbox changes. All five sampled
ready messages resolve their Chat through exact production ownership. They have
no local Message row and declare an extension-session parent. The read-only
legacy-row proof therefore reports an expected missing-row mismatch; it does
not establish a timestamp or Chat bug. Their session-base dependency is the
next discriminator. Eight sampled attachments still have no local Message owner.

Next: inspect each selected parent's exact current-generation snapshot/map and
latest physical inbox version. Determine whether its source is retained,
unsupported, tombstoned, or unobserved. If the local journal cannot answer,
design one bounded read-only exact lookup derived from the authenticated child,
then feed Found records through the ordinary reader. Never fabricate a received
intent or outgoing receipt to borrow a writer lookup. No new lookup API or
copied-store replay helper exists yet; remote absence remains unproven.

The 68 carrier dispositions with an older dependency failure remain retained.
Popper's reviewed report rejects blindly overwriting that history. Parent fixed
a concrete early-return race: carrier classification now revalidates the active
scope after decode, before any metadata mutation (commit `ea8d86b8b`). Three new cases failed before
the fix; the full affected applier/gateway batch passed 152 cases afterward, and
analysis is clean. This Dart-only repair is not yet Pixel-qualified. Do not repeat
an unchanged full sweep, merge by title, or relax ownership/classification checks.

Launcher4759bf88e fixes a missing native bounded-logging flag. Its two regression
assertions failed before and all23 launcher checks pass after. The first sweep
hit the unchanged raw-output cap; the corrected complete run used407,113 stdout
bytes and0 stderr bytes, then removed raw files. Normal five-minute interlock
expiry after forced shutdown was respected, never cleared. Shared profile window
released; no main live process remains. Compatible Dart/tooling repairs reuse the
qualified runtime without another native build. Full sync/Pixel proof remains open.

The offline copied-profile inspector left source data bytes unchanged and found
701 chats,13,969 messages,2,516 attachments,24 confirmed outbox rows, no active
outbox leases and generation1 semantic checkpoints. It did not contact Apple.
Pixel was absent from adb devices. FaceTime/Find My remains independently owned.

User-requested purge removed22,588 regenerable Rust intermediate files totaling
6,050,275,183bytes (5.635GiB). Every10,825 excluded file remained unchanged; no
DLL/EXE/PDB/LIB/EXP, source, evidence, runtime, ObjectBox, signing material or
credential was removed. C:free measured about34.8GiB immediately after cleanup,
29.3GiB at the later test closeout. Exact plan/results:
build-evidence/storage-purge-20260916-luna. Storage helperEinstein was reviewed
and closed; group-route reviewerPopper was reviewed and closed. No child is
needed now. Closed transcripts remain because supported deletion is unavailable.

Received-group draft: source-only worktree
`C:/Codex/OpenBubblesReview/agent-worktrees/received-group-source-20260916`, branch
agent/received-group-source-20260916, commit6c66ea3f5. Parent drafted v2 group
source, protected-parent projection and explicit typed/raw group comparison;
v1 direct hashes/bytes must remain unchanged. Syntax parsing only, no native
tests yet. Dart capture/proof/API wiring remains incomplete, so it is not merged
or enabled. Tesla exceeded the bounded inspection window without code and was
closed/not_found; parent owns the134,308,477-byte worktree and unique draft.
No participant-count/title shortcut or copied outgoing receipt is accepted.

### Ownership and in-progress reader handoff, September 16

User transferred FaceTime and Find My to task
`01a0abe1-9bbe-71b2-a9ce-4d4578022b0e` (facetime & find my). Full handoff sent,
including source/test provenance, isolation, live-device coordination and no paid
GCE. That task starts from committed appb1468abbb/rustpush5862be3 in its own
worktree. This task now implements CloudKit only; shared integration remains
explicitly reviewed. AGENTS.md records the ownership boundaries.

Current integration is16430e0f2b778124bbe43cdc2be0551b5e107292, including native
c5559d5bb with locally qualified Dart changes:
native exact-lookup-to-normal-protected-change staging, atomic semantic inbox
admission preserving cursor fields, and nullable received readerChangeId/state4.
`cloud_sync_received_reader_adapter.dart` is now connected to the bounded worker.
State2 Found rows resume separately from captured state0/1. State4 wakes the normal
reader for both tracked pending pages and unmarked inbox work after a crash.
One admission per pass avoids self-blocking; internal reads skip exhaustive old
history repair and never recursively wake uploads. All three received flags stay
false. New FRB APIs match nativec5559d5bb. Hosted35149164355 passed745 app Rust,
351 rustpush,11 Anisette,40 protector. The actual received journal-to-inbox-to-
canonical gateway passes direct adoption, late edit/retraction and reopen/replay.
All97 gateway cases passed; parent batches passed113 and291 (overlapping subsets,
not additive independent totals). Existing ObjectBox UIDs are preserved.

The new generation2 end-to-end case exposed a real producer/consumer mismatch:
the journal used generation-specific change keys but semantic, attachment and
repair readers expected generation1. It failed semantic_inbox_fence_lost before
the shared key fix and passed after. No stored key is rewritten, no prior epoch
accepted. Attachment/repair73 and reset/lifecycle/media61 cases also passed.
Analysis is clean of errors/warnings; remaining style infos are documented.
Popper and Planck changes reviewed and both closed; Hypatia stopped without
code and parent wrote native tests. No helper remains active.
No CI/local test remains running; all three helpers are closed and verified
not_found. C:about28.8GiB free; current local build742,959,925bytes and
.dart_tool62,981,389bytes. Evidence remains preserved, no session deletion.
Next: retained-record repair on the now-qualified Windows read loop, received
group/media/mutation integration, Pixel and independent Apple-client visibility. Never pair new
bindings with an older DLL; do not enable public automatic uploads yet.

### Active received-create integration, September 16

App integration `383ac8038da13e506a0fe0b8ed4d8b6e89976037` includes native source
`f33a2e76431a058d167b74a4389dea55e731d91b`, rustpush
`5862be3c0ddf0ac0a81e3a45e33cf64d67d996ef`. Hosted35142500478 PASSED:
743 app Rust,351 rustpush,11 Anisette,40 protector. Final28-file Dart batch
passed853. Targeted analysis has no errors/warnings (five existing style infos
in rustpush_service). No APK or live account request was made; flags remain off.
Do not pair these generated bindings with an older Windows DLL.

- Received direct plaintext now has an explicitly separate protected envelope,
  original-source/parent proof, fresh native Absent-only stage, atomic received
  journal/outbox/map adoption, and existing single-submit/unknown-readback wiring.
  Ordinary outgoing validators/IDS confirmation remain unchanged. Incoming and
  mirrored origins never send IDS traffic or fabricate an outgoing receipt.
- Exact writer preflight/readback uses original raw record fields, not the lossy
  general decoder. Found blocks new create. A fresh Found can replace ONLY a
  cached no-raw Absent, retaining its evidence for normal reader reconciliation.
- Received state3 means outbox-adopted, not CloudKit-confirmed. Existing schema
  IDs are retained; nullable admission fields15/16 and index104 are new. The new
  upload flag remains default-off, as do capture/inspection. No account requests.
- Artifact10465832549,389,704bytes, SHA256
  `0a96906406669b9b5b19bb2de6042a701678503c96c346b411bf383d49466788`
  verified before import; seven members match and both generated guards pass.
  Committed regeneration was deliberately skipped, not claimed verified.
- Popper01a0ab7a-8fdd-7522-820d-a66bfd8d786f produced24 source/outbox transaction
  cases in its one assigned test file; all52 cases in that file passed. Three
  UTC-vs-local fixture comparisons and one Never callback were corrected without
  weakening rollback assertions. Closed and verified not_found.
  Raman01a0ab9f-6662-7001-af04-16980d58027b repeated inspection
  without producing code; parent rejected that non-result, closed it (verified
  not_found), and implemented the codec. No new worktree or dependency caches.
- Remaining before enabling: live worker and recovery faults, all Found-to-reader
  adoption, received mutations/media/groups,
  then same-source Windows/Pixel and independent Apple-client proof. Known edits
  or unsends defer received fresh creates rather than upload stale originals.

### Current native qualification

Hosted bridge run35149164355 PASSED for native source
`c5559d5bb48bc3e0d1f921e1d5d5ff6b1aff63cc`, rustpush5862be3.
This one run regenerates the new Found-reader API and executes native suites.
Artifact10468512025 (390,597bytes) was hash-verified and all seven generated
members imported. Both generated-code guards pass. Archive SHA256:
`a2b067b4e1783a06d0280882d36930a9314106d52dc0aa89a04ab773beb76eda`.
Committed reproducibility is intentionally skipped, not claimed passed. No
local native compiler, paid GCE, APK or account action.

### Retained device baseline

- Installed Pixel source was710003e7b at the last read-only snapshot. Its
  interlock failure and one unknown-outcome outbox row still need exact readback
  and current-device qualification. Eight confirmed rows are not a completion
  claim for the unknown row.
- The already-built f027aad2a Canary from hosted35058684776 is verified but not
  installed. It contains Profile encryption/progress and engine-lifetime fixes.
  APK SHA256:
  `d34e72bb78add5f5654adf04e5183cffd8c786bdb5a526ab2a19a424b8e7ab50`.
  Evidence: build-evidence/github-canary-f027aad-35058684776.
- A previously failing HEIC download/reopen was user-confirmed. Group routing,
  incoming archival and edit/unsend behavior still have open gates below.
- Prior native counts, artifacts, rejected variants, cleanup exceptions and
  detailed September16 checkpoints are preserved in the
  [pre-reader treemap snapshot](cloud_sync_v2/history/TREEMAP_PRE_RECEIVED_READER_2026-09-16.md).
  Do not rerun or restore an older checkpoint merely because it passed a
  narrower test. The current candidate above controls new work.

## Scope and current evidence

| Capability | Established | Remaining |
| --- | --- | --- |
| History read | Fresh Canary visibly restores chats/messages. Current Windows candidate caught up and passed two fresh-process empty-terminal repeats. | Classify/repair remaining retained saves, explain unavailable data, and repeat on Pixel. |
| Media/documents/reactions read | Earlier representative live results; current materialization/filtering implemented. | Current Pixel photos, video, transcript GIFs, documents and incremental updates. GIFs need not appear in profile media. |
| Direct writes | Fresh exact-source Windows parent send, edit, unsend and new-process no-submit replay, plus earlier reaction and image protocol results. | Ordinary Pixel composition, restart recovery, group/media cases and independent client display. |
| Incoming/mirrored archival | Default-off receive hook, encrypted source, direct create/readback and Found-to-reader handoff implemented; source/transaction qualification progressing. | Same-source live receive/create/readback, groups/media/mutations, pre-seal failures and independent-client proof. |
| Groups | Restored-group binding implemented/tested. | Approved two-recipient text, attachments, reactions and supported mutations. No personal group substitution. |
| Edits/deletes | Direct single-part Windows send/edit/unsend, exact CloudKit confirmation/local reflection, terminal retraction and zero-submit restart replay. | Pixel, groups, conflicts, independent display, supported tombstones and mid-flight recovery. |
| Lifecycle | Identity/reset fences and bounded Android worker implemented/tested. | Current background/lock, reconnect, process death, token expiry and account repair. |
| Progress/speed | Card and smaller Regular workload implemented. | Integrated qualification, Pixel UX and measured performance. |
| Newest history first | Local recent-chat admission fixed. | Durable fresh-stream direction plus multi-page/restart/incremental qualification. |
| SMS/MMS/RCS | Excluded by user. | Preserve and label exclusion separately from iMessage failures. |

## Safety gates

These gates are non-negotiable:

1. Bind account, live client, credential generation, protected store, zone,
   checkpoint generation, and writer-pause capability at every external wait.
2. Journal each protected page and pending token atomically before committing
   the native page lease.
3. Project in dependency order: chats, messages, reactions, attachments.
4. Promote a token only across a complete contiguous terminal journal.
5. Keep fetched, retained, and exactly projected progress separate.
6. Keep live IDS/APNs receive readiness independent from archive repair.
7. Admit a write only from an exact durable row and a fresh protected
   dependency binding.
8. Prove exact remote absence before first create. Persist the ambiguity fence
   before consuming a prepared mutation.
9. After submission uncertainty, reconcile by exact readback only. Never
   automatically replay, update-merge, quarantine away ambiguity, or delete.
10. Require an exact protected receipt before committing a record map and
    terminal outbox state together.
11. Preserve Alpha, its hardware identity, its database, and its messages.
12. Keep Windows Smart App Control enabled. Use GCE or a trusted signed
    environment when local policy blocks an executable.

## Explicitly forbidden fallbacks

- Use of a general or write-capable container when semantic read authentication
  is cold.
- Cross-account, cross-client, cross-generation, cross-zone, or cross-store
  authentication and decryption.
- `ZoneSaveOperation`, PCS creation, clique reset, or remote mutation from the
  semantic read path.
- Silent fallback to legacy CloudKit sync.
- Cursor clearing for an unknown, malformed, or inconvenient error.
- Treating `retainedUnprojected` as successful local projection.
- Advancing past an incomplete journal.
- Deleting local rows for read-path tombstones.
- Letting optional CloudKit work delay live message startup or acknowledgment.
- Using GCE as a live Apple client or exporting account, relay, PCS, or device
  identity to CI.

## Read state machine

```mermaid
flowchart TD
  A[Explicit Canary or private Windows run] --> B[Admission and interlock]
  B --> C[Bind account, client, generation, store, and writer pause]
  C --> D[Warm exact Messages, Keychain, Security, and three PCS zones]
  D --> E[Fetch bounded protected page under the same capability]
  E --> F[Protect page and atomically journal rows plus pending token]
  F --> G[Commit protected page lease]
  G --> H[Decode under the same capability and exact cached PCS config]
  H --> I[Validate presence, identity, route, and canonical semantics]
  I --> J[Project chats, messages, reactions, and attachments in order]
  J --> K[Persist applied, retained, retryable, or quarantined state]
  K --> L[Promote only a complete terminal contiguous journal]
  L --> M[Revalidate identity, quiesce, report, and resume writers]
  H -. dependency or parser unavailable .-> R[Retain protected evidence]
  R --> H
  E -. token expired .-> X[Stop for generation-scoped rebootstrap]
```

The durable journal between fetch and projection is the critical cut. It makes
projection repair possible without refetching or losing the exact server
evidence.

## Outbound create state machine

```mermaid
flowchart TD
  A[Read and ownership gates pass] --> B[Select one exact durable outgoing row]
  B --> C[Bind content, route, members, generation, record, ETag, and snapshot]
  C --> D[Acquire v2ReadWrite interlock and revalidate after every await]
  D --> E[Derive deterministic record and operation identity]
  E --> F[Exact protected remote lookup]
  F -- same digest exists --> G[Confirm local no-op; zero saves]
  F -- exact NotFound --> H[Prepare create-only submission]
  F -- divergent --> I[Stop with conflict before submission]
  F -- unresolved --> J[Remain pending; zero saves]
  H --> K[Persist exact capability and ambiguity fence]
  K --> L[Consume once]
  L -- confirmed --> M[Commit exact receipt, map, and outbox terminal state]
  L -- timeout or uncertainty --> N[Mark mutationUnknown and preserve UUIDs]
  N --> O[Guard-owned exact readback; never submit]
  O -- committed --> M
  O -- proven not applied --> P[Return to pending after proof]
  O -- unresolved or divergent --> N
```

Direct, reaction, and group operations use distinct protected binding tags.
One lane cannot be cast into another. Confirmed replay is readback-only and
must prove zero saves.

### Attachment-write integration boundary

The next vertical slice must connect the existing composer journal to this
entire chain, not merely add an upload validator:

```text
exact attachment descriptor actually sent through IDS
  -> protected descriptor + metadata + one retained record identity
  -> verified original MMCS bytes, exact pinned length
  -> existing account/container + attachment-zone PCS + boundary-key lookup
  -> byte upload, retaining its receipt or unresolved-upload state
  -> create-only CloudAttachment(cm metadata, lqa asset)
  -> exact record readback and confirmed dependency
  -> parent Message with the same attachment references
```

- The Dart store atomically admits completed Attachment-v1 uploads, and the
  runtime byte-upload coordinator and parent-message connection are implemented.
  Live byte upload has succeeded; child/parent record readback remains open.
  Native integration separates protected pre-upload preparation
  (`outboundAttachmentUpload`) from completed record-create material
  (`outboundAttachment`). Neither grants network permission or parent admission.
- Existing `Attachment.metadata["rustpush"]` stores an MMCS descriptor with
  decryption material at upload-finish, before IDS send success. It is mutable,
  not an encrypted receipt or proof of what IDS sent. Pin the actual wire
  descriptor into protected admission before send, then bind native success to
  it. The v3 receipt now carries the protected source binding, not raw keys or
  descriptors. Composer source staging/adoption is connected; whole-runtime
  attachment qualification remains separate.
- Do not put the source only inside the IDS receipt: acknowledgment deletes
  that file immediately after durable confirmation, before outbound admission.
  A protected source needs its own durable reference and recovery/GC ownership
  through parent adoption. The additive journal `protectedSourceBinding` field
  now owns that reference independently; old rows remain null and unqualified.
- Re-fetching that pinned MMCS object avoids a second permanent plaintext-byte
  journal and mutable-file reuse. It needs APS/MMCS availability, complete
  target/chunk validation, and the pinned plaintext length. A missing or expired
  object must defer, not substitute a different local file. Chunk integrity and
  length do not validate a guessed CTR key; the key must be the one actually sent.
- Reuse `CloudMessagesPreparedSaveSubmission` for record-save correlation and
  single consumption; the next native candidate supplies typed preparation
  and checked readback without enabling admission. Do not use
  legacy `save_attachments`, which enters generic update-capable saving.
- Legacy `prepare_file` calls `get_boundary_key`, which can create a keychain
  item. V2 lookup must also use keystore `get_secret`, not `ensure_secret`, when
  unwrapping existing boundary material. Keep the DSID and entry under the same
  state lock; a missing key fails without generating either local or remote keys.
- The attachment-specific local-send path extends outbox admission and parent
  encoding together. The plaintext-only path still rejects media.
- Record identity must be persisted before first upload and reused on retry.
  Legacy allocates a random attachment record ID; do not assume the proven
  Message GUID HMAC naming rule also applies to attachment records.
- `prepare_put_v2` randomizes chunk keys, FORD key and IV. Re-preparing identical
  plaintext retains neither the original encrypted descriptor nor its reference.
  Preserve the entire `PreparedPut`, including each chunk's key/signature/length,
  under platform protection before upload. Bind it to the original parent source,
  attachment metadata, full container-issued record identifier and file digest.
  A returned asset must match that exact preparation before record-create staging.
- Upload uncertainty and record-save uncertainty are distinct. Record NotFound
  cannot authorize blind byte re-upload or record-ID replacement.
- Next integration order: protected actual-IDS descriptor ownership in the
  local-send journal; durable pre-upload plan and attempt state; exact completed
  upload adoption; existing create-only record transport/readback; parent message
  dependency and encoding. Do not bypass the missing journal ownership by calling
  the legacy uploader or treating native codec tests as end-to-end qualification.
- Native send preparation is a separate boundary: `IMClient.send` calls
  `MessageInst.prepare_send`, which assigns a new send timestamp and may add
  the sender/conversation GUID. Capturing a Dart-built MessageInst and then
  allowing preparation to mutate it is not proof of the final wire. Integration
  must validate the final attachment descriptors and bind positive IDS success
  to the original source. Prefer an explicit validator for the three known
  preparation changes (timestamp, generated conversation GUID, added self
  participant), with all body/recipient/attachment fields unchanged, if that
  avoids a new two-phase send API. Freezing the prepared submission is an
  alternative, not a prerequisite. Do not ignore arbitrary changed fields.
- Local reflection is another normal transformation: `indexedPartsToAttributedBodyDyn`
  changes attachment GUIDs to `<messageGuid>_<part>` and inserts a space where
  the composer may use an object placeholder. Source identity must bind ordered
  descriptors and actual text/formatting, not these local aliases. Resolve each
  body reference to its exact attachment; do not accept count-only matching,
  unrelated rows, substituted descriptors or changed text. The native protected
  source still pins the actual sent descriptor, independently of local UI IDs.

## Fast qualification loop

Use the cheapest boundary that can falsify the current hypothesis:

```text
source contract or behavioral logic
  -> focused local test when policy allows, otherwise GitHub-hosted Actions
  -> full exact-source GCE suite and APK build

Apple protocol, PCS, save, readback, or replay behavior
  -> exact-source trusted minimal Windows harness when available
  -> otherwise signed Canary on Pixel

Android registration, ObjectBox/UI, background, lock, or lifecycle behavior
  -> signed Canary on Pixel

cross-device convergence
  -> independent Apple device confirmation
```

Do not rebuild a Canary for every code edit. Use GitHub-hosted jobs for native
compilation and focused local Flutter tests. GCE credits are exhausted and
new paid GCE work requires renewed approval. The established GCE lanes below
remain a reference, not authorization to dispatch them.
Windows ARM64 bundles are built on the isolated GitHub runner and imported
only after archive, native-codec, source/configuration and launch verification.
The retained `6abbeede2` runtime proves its bounded direct write, not newer
attachment code; `3ebcc81c9` must pass import and its own live test.
Local Cargo compilation remains blocked by App Control 4551. Keep that policy
enabled. The verified cloud bundle runs with the existing engineering signing
path when the original ObjectBox vendor DLL is preserved; re-signing that
vendor DLL caused the earlier startup block. Credentials and PCS state remain
local, never on GCE. Windows qualifies protocol boundaries, not Pixel lifecycle
or final Android release behavior.

Use five promotion lanes and do not skip upward:

1. **Focused local lane:** handwritten Dart contracts and structural guards for
   the changed boundary. It may reject a patch but cannot qualify native Rust.
2. **Fast hosted native lane:** bridge qualification regenerates and verifies FRB bindings,
   checks the Rust bridge, and runs the app Rust library without Android SDK,
   Gradle, signing, or APK work.
3. **Full hosted lane:** only a promotion candidate runs every Dart/Rust/rustpush/
   protector test and produces the signed, ABI-verified Canary APK.
4. **Windows protocol lane:** exact-source minimal harnesses may falsify Apple
   request, PCS, save, readback, and replay behavior without an APK. They do not
   qualify Android lifecycle or UI behavior.
5. **Pixel release lane:** batch direct send, process-death recovery, group send,
   readback, restart, lifecycle, and UI evidence into as few signed-APK sessions
   as safety permits. Manual Apple-device display remains independent evidence.

The manual-writer Pixel lane now has a host-controlled three-phase gate:
[`pixel_cloudkit_write_gate.ps1`](../tooling/pixel_cloudkit_write_gate.ps1)
and [`vm_trigger_cloudkit_write.dart`](../tooling/vm_trigger_cloudkit_write.dart).
`prepare` establishes V2 ownership locally and returns only a candidate GUID
hash; `run` restarts Canary, reselects that exact hash, and invokes the existing
one-intent production path; optional `verify` restarts again and requires zero
new admissions. Every phase pins the app source and host-tool hashes, takes the
recipient only from a process environment variable bound to a separately
supplied SHA-256, emits content-free evidence, and requires the automatic
worker to be absent. The tooling is test-proven but does not replace live
CloudKit readback or independent Apple-device display.

## Recovery policy

| Failure | Safe response |
| --- | --- |
| Read credential cold or revoked | Warm the in-memory same-account credential, restore the encrypted same-account credential, or perform one bounded refresh. Then require user action. |
| Account or client changes | Stop before projection or acknowledgment and preserve journal, source, and checkpoint. |
| PCS key unavailable | Warm or look up only the exact same-scope zone. Retain the protected record if still unavailable. |
| Network or throttling | Preserve token and evidence, honor bounded retry-after, and retry later. |
| Missing parent or parser | Retain protected evidence and retry projection after the dependency or parser repair. |
| Malformed record | Store a fixed content-free reason and explicit repairability classification. Never guess identity. |
| Process death after fetch | Recover the protected lease, replay the durable journal, and keep the prior token until terminal. |
| Token expired | Stop, require the account-bound protected reset proof, release the read boundary, reacquire the destructive-reset interlock and native pause, advance the exact zone generation once, fence old evidence, reconcile authority after interruption, and replay at most once. |
| Write result unknown | Preserve request and operation UUIDs, protected receipt, and fence. Exact readback is the only next network action. |

## Source-linked boundary map

| Boundary | Primary source | Current status |
| --- | --- | --- |
| Product admission and interlock | [`cloud_sync_manual_semantic_pull_sampler.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart), [`cloudkit_operation_interlock.dart`](../lib/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart) | Read live-proven; full session replacement qualification remains. |
| Read authentication and exact PCS | [`cloud_sync_production_sampler_adapter.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart), [`cloudkit.rs`](../rustpush/src/icloud/cloudkit.rs) | Exact `ad822f37c` live read-only pull completed; cold/account lifecycle proof remains. |
| Protected fetch, journal, and token | [`native_protected_cloud_sync_transport.dart`](../lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart), [`objectbox_cloud_sync_store.dart`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart) | Test and prior live proof. |
| Authenticated reset and restart recovery | [`cloud_sync_reset_coordinator.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_reset_coordinator.dart), [`cloud_sync_manual_semantic_pull_sampler.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart), [`cloudkit_writer_authority.dart`](../lib/services/rustpush/cloud_sync/cloudkit_writer_authority.dart), [`objectbox_cloud_sync_preflight.dart`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart) | Exact-source qualified at `0b86a6465`; live expired-token/restart proof remains. |
| Decode and canonical conversion | [`rust_cloud_semantic_decoder.dart`](../lib/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart), [`cloud_sync_canonical_converter.rs`](../rust/src/cloud_sync_canonical_converter.rs) | Test and representative live proof. |
| Ordered projection and retained repair | [`cloud_inbox_applier.dart`](../lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart), [`objectbox_cloud_semantic_store_gateway.dart`](../lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart) | Read live-proven; current backlog must be explicit. |
| Composer origin, IDS completion, and write admission | [`rustpush_service.dart`](../lib/services/rustpush/rustpush_service.dart), [`cloud_sync_local_send_journal.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart), [`cloud_sync_manual_outbound_canary.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart), [`cloudkit_writer_mutation_guard.dart`](../lib/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart) | Atomic direct/restored-group composer admission, bounded awaited receipt replay, atomic startup claim, protected receipt recovery, and reset-required fencing are exact-source qualified through `0b86a6465`; live Pixel process-death recovery, remote readback, and duplicate suppression remain. |
| Direct and group encoders | [`cloud_sync_local_send_encoder.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_local_send_encoder.dart), [`cloud_sync_outbound_group_binding.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart) | Direct live-proven on Windows; group source-implemented. |
| Native create/readback receipt | [`api.rs`](../rust/src/api/api.rs), [`cloud_messages.rs`](../rustpush/src/imessage/cloud_messages.rs), [`chat_create.rs`](../rustpush/src/imessage/cloud_messages/chat_create.rs) | Direct Windows proof; exact-source suite and group live proof pending. |
| Android durable read wake | [`CloudSyncV2Worker.kt`](../android/app/src/main/kotlin/com/bluebubbles/messaging/services/rustpush/CloudSyncV2Worker.kt), [`DartWorker.kt`](../android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/DartWorker.kt), [`cloud_sync_semantic_drain_controller.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart) | Current ready/lease/budget repair has focused behavioral proof. Prior `fc132e5f8` compilation did not detect the startup deadlock; Pixel lifecycle proof remains. |

## Release gates

- [x] Prior APK source 6f778c99 passed full GCE 34741584069 and signing verification (not installed).
- [x] That run completed cleanup; later GCE inventory was empty.
- [x] Fresh Canary visibly projects readable chats/messages.
- [x] Source-specific Windows text/reaction/image checks and direct single-part send/edit/edit/unsend, exact echoed history/retraction, completed restart.
- [x] Exact source `78d0f8cf2` passed full integrated GCE qualification, package/native verification, Android JVM tests and GitHub-hosted signing (34983806715).
- [x] Install that exact signed hash on Pixel in place without touching Alpha; package, version, certificate and retained state verified.
- [ ] Complete remote history and classify/repair actionable retained saves.
- [ ] Repeat with stable cursors, no duplicates and readable media/documents.
- [ ] Pause/resume, background/lock, reconnect, cold restart and token/account recovery.
- [ ] Ordinary Pixel send through IDS acceptance, durable admission, CloudKit save/update,
  exact readback and independent client display.
- [ ] Restart reconciliation with zero duplicate IDS/CloudKit operations.
- [ ] Approved group text/attachments/reactions and supported mutations.
- [ ] Pixel/group mutation chains, mid-flight conflict/unknown-outcome recovery and deletion semantics.
- [x] Newest-history bootstrap source implementation with direction durably bound before request one, existing cursors preserved and exact app-Rust qualification (GCE 34982392496, 682/682).
- [x] Full exact-source GCE packaging/signing qualification for newest-history bootstrap (34983806715).
- [ ] Pixel multi-page, restart, cancellation and incremental-follow-up qualification for newest-history bootstrap.
- [ ] Accurate status for fetched, projected, retained, media and outgoing reconciliation.
- [ ] Measured Regular/Turbo behavior and responsiveness during normal messaging.
- [ ] Document supported operations and limitations. No upstream draft until user confirmation.

## Current critical path

Found-to-reader handoff and post-reset key matching are component-qualified.
Current Windows ordinary read/restart is live-proven, but incoming archival is
not. Use the matching runtime for bounded retained-record observations:811
message saves and1011 attachment saves remain unclassified/unrepaired after
separating known carrier exclusions and tombstones. Do not repeatedly refetch an
already empty-terminal stream or erase raw records to manufacture completion.
No empty local journal proves that an Alpha-only chat is absent from Apple.

1. Identify representative retained iMessage/attachment causes through the
   matched Windows reader, repair proved decoder/parent-routing defects, and
   qualify convergence without using weak chat-title or membership aliases.
2. Complete the received-group draft through Dart capture, native source/proof,
   create/readback and normal reader wiring; then media/mutations and independent
   Apple-client visibility. Keep flags off until the full path passes.
3. Preserve the verified f027 APK/manifest from successful build35058684776.
   Wait for the Pixel connection and inspect installed identity/state. No
   installation while its owner is busy; an idle snapshot is not an atomic lease.
4. Batch Pixel qualification: Profile encryption/read progress, actual host
   detach during work, reopen without a stranded lock, ordinary approved test
   send/edit/unsend, exact readback and no-submit restart replay. Preserve Alpha.
5. Reconcile the existing ambiguous Canary outbox by readback only. Preserve
   older Windows epoch-2 mutations; current epoch-18 authority cannot rebind them.
6. Prove a repair for already-split group rows independently of the new routing
   prevention. Determine upload availability for Alpha-only history before
   calling its absence a download regression. Never merge by name or membership.
   Add received-message archival as a distinct production lane; an empty local
   journal is not proof of remote absence or a reason to forge send receipts.
7. Close supported group/media/conflict and independent-device display gates,
   plus normal Profile/public writer readiness. Keep current read direction,
   receipt integrity, carrier exclusions and retained-data safety unchanged.
FaceTime/Find My are independent task gates, not prerequisites for completing
CloudKit. Coordinate only shared-source and device/profile access windows.

Detailed September 15 wire, installation, retained-record and media evidence is preserved in the [investigation log](cloud_sync_v2/history/CLOUD_SYNC_V2_INVESTIGATION_LOG_FROM_2026-09-07.md#september-15-detailed-evidence-moved-from-treemap).

## Current ownership and continuation rules

- `cloud_sync_extension_metadata.rs` is the pure JSON/schema boundary shared by
  the canonical DTO, archive decoder and protector harness. Keep it independent
  of rustpush/IDS/network code. New metadata fields require both app and harness
  qualification; do not stub the harness to satisfy compilation.
- New projector failure literals require the exact reviewed vocabulary and
  safe-error tests. The Windows lane now includes these downstream checks.
- Parent owns account operations and integration. Current job and helper status
  is in the resume checkpoint. Prior experiments and launch IDs are historical
  evidence, not running work.
- Windows session c936 is closed with process cleanup confirmed. GitHub build
  35058684776 and its watch session19890 completed successfully. No build is
  running. Do not dispatch a duplicate or weaken source compatibility for a DLL.
  Preserve exact bundles, receipts, bounded aggregates and rollback evidence.
- Preserve the qualified DLLs, source manifests and rollback evidence. Current
  generated bindings already include extensionMetadataJson; a metadata JSON
  schema change inside that string is not a new FRB ABI by itself.
- Version-2 extension context separates wire session identity from the archive
  UUID. Base/predecessor ownership, chat/provider and timestamps are validated.
  Late-content repair is atomic and paged; attachment owners are never moved.
- Do not rebuild or install an APK for Dart-only Windows qualification. An actual
  native/ABI change needs its matching cloud-built, separately verified runtime.
- Follow AGENTS.md before compaction: reconcile docs, review agents and preserve
  exact resume handles. Do not restart a job solely after a polling timeout.

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

## Edit and unsend invariants

- Message history/retractions live in the existing message's summary fields
  (`ec`, `ep`, `otr`, `rp`). Revision indexes are payload-local, not global clocks.
  Displayed body and history must remain one compatible snapshot.
- Retractions are monotonic for the exact owned message. Older history cannot
  overwrite newer text or resurrect an unsent message. Unknown parts and
  incompatible histories remain retained; never flatten unsupported bodies.
- Patch retained summary/plist/protobuf values and preserve unknown fields.
  Do not rebuild an existing record with the lossy legacy Message.toCloud path.
  Native message patching changes only the intended field spans.
- Conditional updates bind the exact predecessor record and ETag. Persist the
  mutation intent, prepared time/source, positive IDS receipt, reflection and
  request identity before submission. Unknown outcomes reconcile by readback;
  they do not authorize a retry, recreation, or overwrite.
- A completed edit can provide read-only predecessor evidence for a later mutation
  only when its exact reflected history and confirmed operation/map still match.
  The previous source remains terminal. New mutations have distinct identities.
- Current direct Windows chain/readback/restart proof is in the candidate table.
  It does not establish independent recipient rendering, group behavior, ordinary
  Pixel capture, or all interruption points.

The superseded implementation chronology, wire-experiment details and older
qualification commands are preserved verbatim in the
[historical treemap tail](cloud_sync_v2/history/TREEMAP_PRE_MULTIPART_2026-09-13.md).
