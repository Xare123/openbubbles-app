---
type: research_note
title: Cloud Sync V2 Open-Source Pattern Review
description: License-aware review of synchronization projects whose proven patterns can strengthen OpenBubbles Cloud Sync V2.
resource: openbubbles-app
tags: [cloud-sync, cloudkit, reliability, open-source, licensing, testing]
timestamp: 2026-08-01
---

# Cloud Sync V2 open-source pattern review

## Recommendation

Reimplement four mature patterns in OpenBubbles' own architecture:

1. a durable dependency-aware outbox;
2. explicit, account-scoped checkpoints;
3. journal-first page commits with poison-record quarantine;
4. content-addressed, atomic media storage.

These directly address message loss, duplicate replay, stuck retries, and large
attachment recovery. Do not add a CRDT engine or replace IDS with CloudKit.
Those changes add substantial complexity without improving the current
read-only foundation.

No third-party source code was copied during this review.

## Best references

| Project | Pattern to learn | OpenBubbles application | License posture |
| --- | --- | --- | --- |
| [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk) | Durable per-room send queues, restart rehydration, dependent work such as upload-before-send, and explicit wedged items | Model each pending CloudKit save as durable work with prerequisites, retry eligibility, terminal quarantine, and restart recovery | Apache-2.0; compatible reference, but reimplement to fit the existing engine |
| [Apache PouchDB](https://github.com/apache/pouchdb) | Replication-specific checkpoints and conservative recovery from divergent endpoints | Scope tokens by account, container, database, zone, stream, and schema; advance only in the same durable transaction as the complete page journal | Apache-2.0; compatible reference |
| [Mozilla Application Services](https://github.com/mozilla/application-services) | Independent sync engines coordinated by shared authentication, scheduling, backoff, and telemetry | Keep messages, attachments, profiles, and future state engines isolated while sharing one coordinator and retry policy | Mixed/file-specific licensing; use architectural concepts only unless each source file is reviewed |
| [Chatmail Core](https://github.com/chatmail/core) | Restart-safe message processing, deduplication, bounded failure handling, and blob lifecycle patterns | Quarantine malformed records without losing later work; write media to a temporary file, verify it, then atomically rename into content-addressed storage | MPL-2.0 at repository root; reimplement concepts or isolate any modified MPL-covered file |
| [flutter_secure_storage](https://github.com/juliansteenbakker/flutter_secure_storage) | Platform-backed secret storage and migration concerns | Use as a behavior checklist for Android Keystore and Windows protected storage, not as a mandatory dependency | BSD-3-Clause |
| [Automerge](https://github.com/automerge/automerge) | Conflict-free merging of app-owned collaborative data | Consider only for future drafts or app-owned settings; Apple message history has server semantics and should not become a generic CRDT | MIT |
| [Signal Desktop](https://github.com/signalapp/Signal-Desktop) | Desktop queue, media, database, and recovery ideas | Architecture-only comparison; do not copy implementation into the Apache-2.0 app without an explicit relicensing decision | AGPL-3.0; direct reuse is not acceptable under the current app license |
| [OpenBubbles rustpush](https://github.com/OpenBubbles/rustpush) | Existing IDS and private CloudKit protocol boundary | Keep protocol-specific behavior behind the transport interface and document derivative-work boundaries | SSPL-1.0; handle separately from the Apache-2.0 Flutter app |

## Concrete design translations

### 1. Durable outbox state machine

Each outbound logical operation should persist:

- stable operation ID and account-scoped destination;
- prerequisites, such as attachment upload completion;
- attempt count, next eligible time, and server `Retry-After`;
- idempotency identity;
- `pending`, `inFlight`, `retryable`, `wedged`, `confirmed`, or `cancelled`
  state;
- a redacted failure category.

Process one account and stream through a single coordinator. A process crash
must return stale `inFlight` work to a safe replay state. User-visible failure
must not silently discard the operation.

### 2. Checkpoint contract

A checkpoint is valid only for one:

`account fingerprint + container + database + zone + stream + schema version`

The page journal, quarantined-record decisions, and replacement continuation
token must commit atomically. A record that was neither journaled nor durably
quarantined blocks token advancement. Repeating a completed page must create no
new logical work.

### 3. Poison-record handling

Malformed, undecryptable, oversized, or unsupported records should enter a
bounded quarantine with:

- keyed diagnostic fingerprint;
- safe failure category;
- first and last observed timestamps;
- bounded attempt count;
- source page/run identity without raw Apple identifiers.

Quarantine is evidence, not deletion. A later decoder or key recovery can
replay it. Repeated poison records must not create an infinite retry loop.

### 4. Media pipeline

For downloaded attachments:

1. stream into a bounded temporary file;
2. enforce declared and observed byte limits;
3. compute a content hash while streaming;
4. verify integrity and expected media type;
5. atomically rename into content-addressed storage;
6. persist the database reference only after the file is durable;
7. reclaim unreferenced temporary files on startup.

This avoids holding full media in memory and makes retry, deduplication, and
cross-client evidence straightforward.

## What to build first

The highest-return sequence is:

1. propagate and persist `Retry-After`;
2. add a raw-page byte cap before protection;
3. add fail-closed V2 composition and a manual shadow sampler;
4. add redacted provenance and ephemeral cross-client event fingerprints;
5. add deterministic crash points around journal/checkpoint commit;
6. only then implement semantic apply and the durable outbox.

CRDT merging, broad background scheduling, CloudKit deletions, and profile
synchronization should remain deferred. They would expand the failure surface
before the read-only transport and recovery invariants are live-proven.

## License rule for implementation

For every borrowed implementation idea, record the project, exact source URL,
license, whether code or only a concept was used, and the OpenBubbles file that
implements it. Apache-2.0, BSD, and MIT material may still require notices and
attribution. MPL code needs file-level handling. AGPL and SSPL code must not be
copied into the Apache-2.0 application without a deliberate licensing decision.
