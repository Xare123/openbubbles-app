---
type: architecture
title: Cloud Sync V2 Current Connection Treemap
description: Current source of truth for CloudKit V2 architecture, safety boundaries, qualification state, and next gates.
resource: openbubbles-app
tags: [openbubbles, cloudkit, messages-in-icloud, architecture, recovery, canary]
timestamp: 2026-09-07
---

# Cloud Sync V2 current connection treemap

This document is the short operational source of truth. It contains current
architecture, safety rules, qualification state, and the next falsification
test. Dated investigations, obsolete candidates, run-by-run notes, patents,
and historical evidence remain intact in the
[investigation log](cloud_sync_v2/history/CLOUD_SYNC_V2_INVESTIGATION_LOG_THROUGH_2026-09-07.md).
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

| Item | Current state |
| --- | --- |
| App branch | `agent/cloudkit-v2-sms-chat-contract` |
| Candidate | `4eb1d66c44e218a373770fc42e0f6421fcf172ac` |
| Main change | Restored group plaintext is bound to protected routing state. |
| Dependency | rustpush `2274cee63c05432c89fc5dbb61915b5659fa9721`, published to the user's fork after the first clean-run checkout failure. |
| Full qualification | GCE run `34169243930` is the replacement exact-source run. Its result must be recorded before installation. |
| Android release proof | Pending a signed Canary and controlled Pixel test. Alpha remains untouched. |
| Production claim | Not yet allowed. |

### What the candidate changes

- Native and Dart compute the same deterministic group-routing digest from the
  canonical group, current raw group ID, service/style, group version, and
  normalized participants.
- Both sides use UTF-8 byte ordering. Exact `urn:biz:<UUID>` participants are
  retained; arbitrary schemes remain rejected.
- Older applied groups can receive a missing digest only through protected
  null-to-non-null projection repair with an otherwise exact snapshot match.
- Restored, nonprovisional group plaintext uses opaque dependency binding tag
  3. It binds generation, owner, aliases, server record, ETag/raw reference,
  latest applied save, and routing digest.
- Direct tag-1 and reaction tag-2 encoders and bindings remain unchanged.
- Provisional group creation, group reactions, group-state mutations, remote
  deletion, and update merge remain closed.

## Scope and current evidence

| Capability | Status | Remaining proof or work |
| --- | --- | --- |
| Chat and message history | `LIVE-PROVEN` for restored readable history | Qualify sustained incremental sync, restart, and account lifecycle on the release candidate. |
| Reactions on read | `LIVE-PROVEN` for representative records | Continue retaining unavailable parents; qualify current candidate on Pixel. |
| Photos and videos on read | `LIVE-PROVEN` for user-visible examples | One HEIC exact-size edge and some gallery/profile surfaces remain. GIF rendering is deferred, but data must remain preserved. |
| Documents and plugin payloads | Partial | Classify and expose supported document payloads without mislabeling opaque plugin payload containers as ordinary files. |
| Direct plaintext create | `LIVE-PROVEN` in the Windows development loop | Confirm exact remote readback, restart no-save replay, independent Apple-device visibility, and ordinary Pixel composer convergence. |
| Restored-group plaintext create | `SOURCE-IMPLEMENTED` | Pass exact-source GCE, then perform one authorized live group test and exact readback/restart proof. |
| Direct reactions | `TEST-PROVEN` | Live Apple save/readback and independent-reader display remain. |
| Edits and unsends | `GAP` | Require distinct causal mutation and anti-resurrection contracts. |
| Attachment writes | `GAP` | Require protected asset staging, record binding, save/readback, and recovery. |
| Tombstones and deletion | Closed | Define exact ownership and recoverable semantics before enabling any local or remote delete. |
| Token expiry | `GAP` | Wire generation-scoped rebootstrap and reconcile retained old-generation evidence. |
| SMS, MMS, and RCS | Out of scope | Do not add them to this CloudKit V2 release path. |

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

## Fast qualification loop

Use the cheapest boundary that can falsify the current hypothesis:

```text
source contract or behavioral logic
  -> focused local test when policy allows, otherwise GCE
  -> full exact-source GCE suite and APK build

Apple protocol, PCS, save, readback, or replay behavior
  -> private-profile Windows fast loop

Android registration, ObjectBox/UI, background, lock, or lifecycle behavior
  -> signed Canary on Pixel

cross-device convergence
  -> independent Apple device confirmation
```

Do not rebuild a Canary for every code edit. Dart-only development may use
Windows hot reload. Rust or bridge changes need an incremental DLL rebuild and
process restart. Credentials and PCS state stay on the private Windows profile,
never on GCE. Pixel is the final release proof, not the everyday protocol loop.

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
| Token expired | Stop, obtain an account-bound reset proof, quiesce coordinators, increment generation atomically, and rebootstrap only after old-evidence reconciliation is defined. |
| Write result unknown | Preserve request and operation UUIDs, protected receipt, and fence. Exact readback is the only next network action. |

## Source-linked boundary map

| Boundary | Primary source | Current status |
| --- | --- | --- |
| Product admission and interlock | [`cloud_sync_manual_semantic_pull_sampler.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart), [`cloudkit_operation_interlock.dart`](../lib/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart) | Read live-proven; full session replacement qualification remains. |
| Read authentication and exact PCS | [`cloud_sync_production_sampler_adapter.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart), [`cloudkit.rs`](../rustpush/src/icloud/cloudkit.rs) | Representative live proof; current candidate requalification pending. |
| Protected fetch, journal, and token | [`native_protected_cloud_sync_transport.dart`](../lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart), [`objectbox_cloud_sync_store.dart`](../lib/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart) | Test and prior live proof. |
| Decode and canonical conversion | [`rust_cloud_semantic_decoder.dart`](../lib/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart), [`cloud_sync_canonical_converter.rs`](../rust/src/cloud_sync_canonical_converter.rs) | Test and representative live proof. |
| Ordered projection and retained repair | [`cloud_inbox_applier.dart`](../lib/services/rustpush/cloud_sync/cloud_inbox_applier.dart), [`objectbox_cloud_semantic_store_gateway.dart`](../lib/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart) | Read live-proven; current backlog must be explicit. |
| Write admission and recovery | [`cloud_sync_manual_outbound_canary.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart), [`cloudkit_writer_mutation_guard.dart`](../lib/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart) | Direct Windows live proof; Pixel and other operation families remain. |
| Direct and group encoders | [`cloud_sync_outbound_plaintext_encoder.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_outbound_plaintext_encoder.dart), [`cloud_sync_outbound_group_binding.dart`](../lib/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart) | Direct live-proven on Windows; group source-implemented. |
| Native create/readback receipt | [`api.rs`](../rust/src/api/api.rs), [`cloud_messages.rs`](../rustpush/src/imessage/cloud_messages.rs), [`chat_create.rs`](../rustpush/src/imessage/cloud_messages/chat_create.rs) | Direct Windows proof; exact-source suite and group live proof pending. |

## Release gates

### Candidate qualification

- [ ] Generated bindings reproduce with no unrelated drift.
- [ ] Full Dart, Rust, rustpush, protector, and ObjectBox tests pass at the
  exact app and submodule commits.
- [ ] Canary APK contains the expected ARM64 native library and is signed on
  the existing trusted GitHub-hosted signing path.
- [ ] Failed GCE runs delete the VM and deregister the runner.

### Read qualification

- [x] Representative chats and readable messages project on Canary.
- [x] Representative reactions and media metadata project without deleting
  unavailable evidence.
- [ ] A cold-start candidate executes authentication, pause, three-zone warm,
  fetch, decode, journal, projection, and token promotion in one process.
- [ ] A second pull is idempotent and reports fetched, retained, and projected
  counts separately.
- [ ] Restart, background/lock, account replacement, and expired-token paths
  preserve evidence and fail closed.

### Write qualification

- [x] Direct plaintext create has bounded Windows save/readback/restart proof.
- [ ] Confirmed direct replay proves zero saves and independent Apple-device
  display for the release candidate.
- [ ] Restored-group plaintext passes exact-source tests, one authorized live
  group create, exact readback, restart, and independent display.
- [ ] Direct reactions pass live save/readback/restart and independent display.
- [ ] Ordinary composer admission commits the local message and V2 outbox
  intent together, then converges automatically.
- [ ] Attachment write, edits, unsends, and tombstones each receive their own
  causal and recovery contract before release or remain explicitly disabled.

### Production qualification

- [ ] One signed Canary survives foreground/background, lock, reconnect,
  process restart, and account repair without duplicate sends or lost tokens.
- [ ] Current retained backlog is zero or every retained category has an
  explicit non-destructive repair or honest unavailable state.
- [ ] User-visible status distinguishes remote ingestion, projection, media
  materialization, live delivery, and write reconciliation.
- [ ] Scope documentation names supported operations precisely. Initial text
  creation must not be advertised as complete Messages parity.

## Current critical path

1. Complete GCE run `34169243930` against candidate `4eb1d66c4` and rustpush
   `2274cee63`. Do not install an artifact from a failed run.
2. If it passes, sign and install Canary in place. Preserve Canary identity and
   Alpha completely.
3. Run projection repair so eligible restored groups obtain the protected
   routing digest. Confirm the interlock is idle and no retained ownership
   barrier blocks admission.
4. Use the authorized test recipients only. First repeat direct no-duplicate
   readback proof, then create one controlled restored-group plaintext message.
5. Verify the group record by exact CloudKit readback, restart/no-save replay,
   and independent Apple-device display.
6. Qualify direct reactions. Keep edits, unsends, attachments, group-state
   changes, and deletion closed until their separate contracts pass.
7. Run lifecycle soak and produce one release-candidate report that proves
   identity stability, token continuity, zero duplicate writes, and honest
   retained counts.

## Next falsification test

The next test is not another broad device exploration. It is the exact-source
GCE run. A failure invalidates the candidate until its concrete source,
binding, native, or packaging cause is repaired. A pass permits one signed
Canary and the narrow live group create/readback/restart test. Neither outcome
permits remote deletion or update merge.
