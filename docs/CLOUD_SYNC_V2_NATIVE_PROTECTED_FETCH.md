---
type: design
title: Cloud Sync V2 Native Protected Fetch Boundary
description: Private default-off CloudKit page fetch, protection, and two-phase local adoption contract.
resource: OpenBubbles
tags:
  - cloud-sync-v2
  - cloudkit
  - privacy
  - rust
  - recovery
timestamp: 2026-08-02
---

# Cloud Sync V2 Native Protected Fetch Boundary

## Status

This is a private, default-off Rust boundary with a generated Flutter Rust
Bridge wrapper and a concrete read-only Dart transport. The protected transport
is deliberately absent from production runtime composition and does not replace
the dormant Dart raw transport yet.

The boundary proves that raw CloudKit record names, etags, encrypted record
envelopes, tombstone payloads, and continuation tokens can remain in native
code. Its outward data is limited to typed operations, fixed safe codes, bounded
lengths, keyed identifiers, payload digests, opaque protected-local references,
and an opaque page lease. This is compile- and contract-tested foundation, not a
production-ready or runtime-enabled sync path.

## Canonical outward grammar

- `change_id`: bare 43-character base64url HMAC-SHA256
- `record_id_hash`: bare 43-character base64url HMAC-SHA256
- `etag_hash`: optional bare 43-character base64url HMAC-SHA256
- `payload_digest`: lowercase 64-character SHA-256 hex
- protected record identity and raw-envelope references: `obcs2.ref.<43-character-token>`
- page adoption lease: `obcs2.lease.<32-character-hex-token>`
- protected native-store recovery identity: `obcs2.store.<43-character-token>`

The HMAC domains for change, record, and etag identifiers are distinct. Raw record identity is stored only in the scope-bound `serverRecordId` protected value. The raw encrypted record or tombstone is stored only in the scope-bound `rawRecord` protected value. A continuation token is stored only in the scope-bound `checkpointToken` protected value.

## Bounds

- maximum 200 changes per page
- maximum 8 MiB raw bytes per record
- maximum 24 MiB admitted raw bytes per page
- maximum 64 KiB continuation token
- maximum 16 KiB combined record metadata
- maximum 18 MiB per protected local file
- maximum 36 MiB aggregate protected plaintext per page lease
- maximum 48 MiB aggregate protected ciphertext per page lease
- maximum 401 protected references total per page lease (two per change plus
  one checkpoint)
- maximum 128 KiB lease manifest
- maximum 64 lease manifests processed per recovery pass
- maximum 4,096 adopted lease identifiers supplied to one recovery call
- maximum 131,072 ObjectBox-live protected references per maintenance snapshot
- maximum 64 explicitly retired references per call
- maximum 64 protected blobs examined per garbage-collection pass
- maximum 4,096 active lease manifests examined as garbage-collection roots
- 24-hour minimum orphan grace period across two scans
- 40-second native fetch deadline

An individually oversized record is represented as a quarantined change. Its protected envelope retains only its digest and length, not the oversized raw bytes. A page that exceeds aggregate admission bounds is rejected before protection.

## Two-phase journal adoption

Protection happens before ObjectBox journal admission, so the native store returns a page lease with the protected page.

The required caller sequence is:

1. Fetch and protect one page. Native code returns D0-safe page data and `page_lease_reference`.
2. In one ObjectBox transaction, validate the page, write every journal row and protected reference, advance the protected checkpoint when appropriate, and durably record the same `page_lease_reference` as adopted.
3. After the transaction commits, enumerate a complete ObjectBox liveness
   snapshot. Compute the exact intersection between references in this page and
   references adopted by newly inserted inbox rows plus the newly committed
   checkpoint. Pass that retained subset to
   `cloud_sync_commit_protected_page_lease`.
   - Native verifies that every retained reference belongs to the lease and its
     ciphertext digest still matches.
   - Native deletes exact-digest manifest entries omitted from the retained
     subset. This removes duplicate-page blobs immediately.
   - Native durably writes a committed receipt, then removes the active
     manifest. Repeating the commit is accepted only with the same exact
     retained subset.
4. If validation or the ObjectBox transaction rejects the page, call
   `cloud_sync_rollback_protected_page_lease`. This removes only files created
   by that lease whose ciphertext digest still matches the manifest.
5. Delete the ObjectBox adoption marker only after native commit succeeds, then
   acknowledge the committed receipt. Receipt acknowledgement is idempotent.
   A release or acknowledgement failure invalidates the process recovery cache,
   so the next fetch performs bounded cleanup without requiring a restart.
6. At startup, before any fetch begins, load durable adopted lease identifiers
   and a complete ObjectBox liveness snapshot, then pass both to
   `cloud_sync_recover_abandoned_page_leases`.
   - An adopted active lease retains only its manifest entries present in the
     complete ObjectBox liveness set.
   - An adopted committed receipt is verified against the liveness set and
     reported for exact marker release.
   - An unadopted lease is rolled back.
   - An unadopted committed receipt is removed without deleting its blobs.
   - Recovery is bounded to 64 manifests per pass and can be called repeatedly.

This closes the crash windows before and after the ObjectBox transaction and
native commit. Recovery and collection reject an incomplete liveness snapshot.
The durable adopted-lease row can be deleted only after native recovery or
commit confirms finalization. A crash before old-checkpoint retirement leaks
the old capability safely; retirement never precedes the ObjectBox checkpoint
replacement transaction.

The private native lifecycle signatures are:

```text
cloud_sync_commit_protected_page_lease(
  storage_directory,
  page_lease_reference,
  retained_references[exact manifest subset]
)
  -> Result<(), fixed safe failure>

cloud_sync_acknowledge_committed_page_lease(
  storage_directory,
  page_lease_reference
) -> Result<(), fixed safe failure>

cloud_sync_rollback_protected_page_lease(storage_directory, page_lease_reference)
  -> Result<(), fixed safe failure>

cloud_sync_recover_abandoned_page_leases(
  storage_directory,
  adopted_lease_references[0..=4096],
  live_references[0..=131072],
  live_reference_enumeration_complete
) -> Result<{
  finalized_adopted_lease_references[],
  absent_adopted_lease_references[],
  rolled_back_count,
  removed_temporary_file_count,
  has_more
}, fixed safe failure>

cloud_sync_retire_protected_references(
  storage_directory,
  references[0..=64]
) -> Result<retired_count, fixed safe failure>

cloud_sync_collect_protected_garbage(
  storage_directory,
  live_references[0..=131072],
  live_reference_enumeration_complete
) -> Result<{
  scanned_count,
  first_observed_count,
  deleted_count,
  preserved_live_count,
  preserved_active_lease_count,
  has_more
}, fixed safe failure>
```

Commit and rollback accept only `obcs2.lease.<32 lowercase hex characters>`.
They do not accept a page object or any raw record identity. The generated D0
FRB adapter exposes only these reference-based calls, not the private page
helper overloads.

The exact finalized-adopted list lets Dart delete only the corresponding ObjectBox adoption rows after recovery. A count alone is insufficient because each recovery pass handles at most 64 manifests.

When `has_more` is true, Dart must keep the full remaining ObjectBox adoption set and call recovery again. It may delete only adoption rows named in `finalized_adopted_lease_references`. This repeats until `has_more` is false. A crash between passes is safe because both native finalization and adoption-row deletion are idempotent.

When `has_more` is false, native recovery has scanned every remaining manifest. It then returns any supplied adoption references with no manifest in `absent_adopted_lease_references`. These are the crash-after-native-commit, before-ObjectBox-marker-delete case and are also safe for Dart to retire. Dart may delete only the union of the exact finalized and absent reference lists from that result.

Commit is idempotent only for the exact retained subset recorded in its durable
receipt. Rollback and receipt acknowledgement are idempotent for an
already-finalized valid lease reference. This permits safe retry after a
process interruption or a directory-fsync error without accepting a broadened
retained set.

Startup recovery is keyed process-wide by the native-issued
`obcs2.store.<43-character-token>` identity. Separate Dart wrapper instances
for the same native store therefore share one recovery barrier without exposing
the storage path. A failed commit, rollback, adoption-marker release, or
receipt acknowledgement invalidates that successful process recovery so the
next fetch re-enters bounded native recovery.

Lease-specific blob tokens prevent one page from owning a pre-existing blob. Rollback also verifies the ciphertext SHA-256 recorded by the lease before deletion. A file that was replaced or did not originate from the lease is preserved.

The store fsyncs the lease manifest before protected blobs become visible, fsyncs every protected blob before rename, and fsyncs the containing directory after manifest creation, blob rename, rollback, and lease commit.

Lease manifests and in-progress files live in dedicated `.leases` and `.temporary` subdirectories. Startup recovery therefore remains bounded even when the store contains years of adopted protected blobs. It removes at most 64 abandoned temporary files and processes at most 64 lease manifests per pass. Either backlog sets `has_more`.

## Liveness, retirement, and bounded garbage collection

ObjectBox is the mark authority. Its complete snapshot includes native
references from every inbox row, including pending, applied, and quarantined
rows. Quarantined rows remain nonterminal checkpoint barriers. The snapshot
also includes outbox rows, record maps, attachment materializations, and every
protected checkpoint. Applied inbox rows are intentionally never
collectible until a separately reviewed compaction policy removes those rows.
Enumeration runs in one ObjectBox read transaction and pages row materialization
in batches of 1,024 to bound transient entity memory.

Native adoption, rollback, retirement, and collection share one store-operation
mutex. Active lease manifests are additional roots, so a page cannot be
collected between native protection and ObjectBox adoption. A liveness snapshot
can become stale after its read transaction; the active-manifest root plus a
two-scan, 24-hour grace period makes that race leak-first instead of
delete-first.

One collection pass:

1. rejects an incomplete or malformed liveness snapshot;
2. reads at most 4,096 active manifests as temporary roots;
3. examines at most 64 sorted protected files after a durable cursor;
4. clears prior orphan marks for ObjectBox-live or active-lease references;
5. records first observation for an unreferenced blob;
6. deletes only a still-unreferenced blob observed again after at least 24
   hours, after recomputing and verifying its reference token from the stored
   bytes.

Collection is private and default-off. The caller must invoke bounded passes;
no production scheduler is enabled by this gate.

## Retry and checkpoint behavior

Network, throttling, server, authorization, PCS, conflict, malformed response,
continuation-no-progress, and local-storage failures map to fixed enums.
Retry-after seconds survive CloudKit and HTTP 429 mapping and are clamped to
seven days before crossing the bridge.

Checkpoint plaintext binds format version, generation, stream, and the raw continuation token. Platform protection additionally binds account fingerprint, container, database, zone, stream kind, schema version, and purpose. A reference protected under another account, zone, stream, schema, or purpose is rejected before a CloudKit request.

## Remaining production blockers

- Integrate the protected transport into a default-off manual shadow composition
  and prove the real journal, checkpoint, semantic-store, and restart path. The
  current adapter maps the protected record-identity reference into
  `CloudFetchedChange.encryptedServerRecordId`, but it is intentionally not
  selected by production composition.
- Serialize recovery and maintenance against every protected fetch sharing the
  same native-store identity. Recovery is correct only when no fetch is in
  flight, and a complete ObjectBox liveness snapshot must remain fenced from
  concurrent protected-reference adoption until its native maintenance call
  completes.
- Add platform reopen tests for Android and Windows protected storage.
- Add process-kill tests around manifest fsync, each blob rename, ObjectBox commit, native lease commit, and bounded recovery.
- Add real platform endurance tests for periodic maintenance, ObjectBox
  enumeration near the 131,072-reference fail-closed bound, and interrupted
  garbage-collection cursor/candidate updates.
- Complete the concrete native semantic decoder and integrate the canonical
  converter only after journal durability.
- Validate native binary packaging and protected-store identity continuity on
  Pixel Android, Windows x64, and Windows ARM64.
- Remove or permanently disable the dormant Dart raw transport only after the protected path passes shadow comparison and endurance testing.

## Verification completed for this gate

- FRB 2.3.0 bindings were generated from the Rust API and the generated Rust
  bridge passed `cargo check --lib` in the Linux ARM64 toolchain.
- Focused Dart tests cover safe page mapping, tombstone shape, malformed
  capabilities, read-only enforcement, exact retained subsets, duplicate-page
  deletion, checkpoint-retirement ordering, lease commit/rollback/recovery,
  shared native-store recovery identity, same-process release/ack retry,
  fail-closed incomplete liveness, and strict 43-character account
  fingerprints.
- Rust tests cover exact empty/mixed retention, manifest/receipt crash windows,
  reopen/idempotence, active-lease roots, incomplete liveness, 24-hour
  two-scan collection, and bounded progress beyond 64 blobs.
- ObjectBox liveness capture explicitly retains applied terminal inbox
  references and materializes rows in 1,024-row pages inside one read
  transaction.
- Rust and Dart source-contract tests reject raw identifiers, etags, tokens,
  payloads, credentials, plaintext, and paths from the protected DTO surface.
- The protected transport remains absent from every production Dart
  composition.

No production enablement, commit, push, device installation, live CloudKit
exchange, or platform process-kill validation is part of this gate.
