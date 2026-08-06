---
type: design
title: Cloud Sync V2 Semantic Applier Boundary
description: Platform-neutral reconciliation contract and remaining adapters for guarded semantic pull.
resource: OpenBubbles Cloud Sync V2
tags:
  - openbubbles
  - cloud-sync
  - reconciliation
timestamp: 2026-08-01
---

# Cloud Sync V2 Semantic Applier Boundary

`TransactionalCloudInboxApplier` and
`ObjectBoxCloudSemanticStoreGateway` are dormant Phase 2 building blocks.
Neither has a production canonical adapter or runtime composition, and
`semanticApply` remains disabled.

## Established boundary

The native decoder must return a `CloudDecodedMutation` with two deliberately
separate lanes:

- A typed `CloudSemanticEntityPayload` carries transient plaintext needed to
  create or update the canonical Message, Chat, Attachment, Reaction, group
  photo, or shared-profile row. Payload types have no JSON or Map conversion,
  and their string representation is permanently redacted.
- A `CloudSemanticSnapshot` carries only account-scoped, content-free merge
  metadata: digests, timestamps, protected raw-record references, and safe
  logical-key hashes.

The transient payload may exist in memory because the app must render the
decrypted entity. It must never be persisted in Cloud Sync replay, conflict,
quarantine, checkpoint, or diagnostic metadata.

The local adapter must implement `CloudSemanticStoreGateway`. Its transaction
must atomically:

1. Revalidate the active account, coordinator lease owner/generation/expiry,
   checkpoint scope/generation, and exact pending inbox row.
2. Check a replay outcome bound to the change, server-record digest, payload
   digest/protected-reference digest, generation, sequence, and change type.
3. Read and merge the content-free local semantic snapshot.
4. Apply the transient payload to the canonical entity, write the semantic
   snapshot, and upsert the protected record map.
5. Commit exactly one replay outcome (`applied`, `appliedWithConflict`, or
   `quarantined`) and the matching inbox terminal state.

The transaction callback is synchronous by design. An adapter must not await
network, native decoding, or another isolate while an ObjectBox write
transaction is open. Per-Store reentrancy and transaction-lifetime guards reject
nested calls, discarded nested futures, microtask use, and use after return.

Every durable semantic digest is either a 43-character unpadded base64url value
or a 64-character lowercase hexadecimal value. Scope components are bounded
and reject control characters and the storage-key delimiter. Unknown
adapter/ObjectBox exceptions are converted to a fixed redacted failure code.

## Remaining native decoder adapter

The Rust adapter still needs a reviewed decoder for each supported Apple record
type. It must:

- decrypt only inside the existing native/keystore boundary;
- canonicalize logical keys, content, edit parts, group metadata, reactions,
  and parent references into keyed hashes or digests;
- prove whether a tombstone is authoritative server state;
- preserve unknown fields through a protected raw-record reference;
- return typed malformed, PCS, authorization, and unsupported-record failures;
- clear plaintext buffers after decoding where practical;
- never send message bodies, handles, account identifiers, or keys to Dart
  diagnostics or durable sync metadata.

## Established ObjectBox metadata adapter

The ObjectBox gateway now provides the fenced transaction, snapshot, protected
record-map, replay, and inbox-status metadata boundary. Tests cover lease
takeover/expiry, account switch, generation reset, exact inbox matching,
rollback, replay binding, record-map conflicts, strict digest privacy,
secret-bearing exceptions, nested/escaped transactions, process reopen,
parent-integrity checks, and stream/entity allowlists.

The remaining production adapter must map the transient payload to the app's
existing canonical chat/message/reaction models rather than create a second
message database. The current fixture adapter exists only to prove transaction
behavior.

Tombstones remain disabled in the durable gateway. Before enabling
`semanticApply`, add the production canonical adapter, reviewed native-to-Dart
binding, real canonical-model relation tests, cross-architecture reopen tests,
schema migration fixtures, reaction-parent arrival ordering, local-outbox
ordering, and authoritative deletion recovery. No adapter may reuse the Phase 1
shadow inbox row itself as plaintext semantic storage.
