---
type: implementation_plan
title: Cloud Sync V2 Developer Shadow Sampler
description: Implementation-ready design for the first fail-closed, one-shot, read-only CloudKit validation entry point.
resource: openbubbles-app
tags: [cloud-sync, cloudkit, developer-tools, security, validation]
timestamp: 2026-08-01
---

# Cloud Sync V2 developer shadow sampler

## Decision

Build a one-shot sampler available only in explicitly enabled developer builds.
It is created after a confirmation, fetches at most four bounded pages from each
Messages zone, writes only protected V2 journal/checkpoint metadata, exports an
allowlisted report, and disposes immediately.

Do not create a persistent runtime or connect startup, network, IDS, or
background callbacks. Do not reuse the legacy `Messages in iCloud (BETA)`
setting.

Estimated implementation and offline validation: 10 to 16 engineering hours.
Controlled Account B sampling adds 1 to 2 hours, followed by a 24 to 72-hour
soak.

## Existing seams

Reuse:

- `CloudSyncShadowRuntime`
- `CloudSyncEngine`
- `RustCloudSyncTransport`
- `RustCloudSyncProtector`
- `ObjectBoxCloudSyncStore`
- the existing V2 ObjectBox checkpoint, inbox, lease, outbox, record-map, and
  run-history boxes
- the active `cloudMessagesClient`
- the active application-document directory

The UI belongs behind the active developer controls in
`troubleshoot_panel.dart`. The similarly named
`developer_mode_panel.dart_` file is not compiled.

## Hard-coded composition

Use only:

```text
container: com.apple.messages.cloud
database: private
zones:
  chatManateeZone
  messageManateeZone
  attachmentManateeZone
```

Sampler limits:

- four pages per zone, at most 200 records per zone per invocation;
- at most 50 changes per page;
- 8 MiB pending journal budget per scope;
- 512 pending entries per scope;
- 24-hour pending age ceiling;
- 32 MiB raw transport page admission;
- automatic triggers off;
- read-only fetch on;
- semantic apply, saves, deletions, profiles, and notification hints off.

The 512-entry journal budget applies to shadow-mode pending entries. Semantic
mode retains terminal journal evidence separately; its developer-only
invocation remains bounded to four sequential pages (200 records) per zone.

Use one shared protector and ObjectBox store. Construct one read-only engine per
zone and run them sequentially through `CloudSyncShadowRuntime`.

## Active-account binding

Do not use a cached settings value as the account identity. Add a narrow native
call that receives the active Cloud Messages client, reads its DSID internally,
derives the existing per-install HMAC account fingerprint, and returns only the
fingerprint.

Capture the active push-state object, Cloud Messages client object, and native
fingerprint. Recheck all three immediately before and after every fetch. If any
identity changes, discard the fetched page without journaling and return the
allowlisted `account_changed` failure.

The raw DSID must never enter Dart or diagnostics.

### Dormant production adapter

`CloudSyncProductionSamplerAdapter` is the only production composition seam.
Constructing it performs no network request and schedules no callback. It
creates the ObjectBox store, Rust protector, and Rust raw-read transport only
inside the explicitly confirmed manual sampler.

`cloud_sync_capture_auth_snapshot` accepts the active opaque Cloud Messages
client and private storage directory. Rust reads the client's DSID, derives the
per-install account fingerprint and an opaque client-generation tag, then
returns only those redacted HMAC values. Dart never receives the DSID, Apple
Account address, token, or key. The same opaque client object is retained in
the immutable snapshot and supplied to the raw-read transport.

The provider checks object identity after the native capture. The sampler then
checks the native generation, fingerprint, and client identity before each
zone and on both sides of every fetch. A replacement race therefore fails
before the fetched page can reach ObjectBox.

## Fail-closed preflight

Refuse the run unless:

- the compile-time sampler flag is enabled;
- the platform is Android or Windows;
- execution is on the UI isolate;
- RustPush setup and ObjectBox initialization are complete;
- the private storage directory exists;
- an active Cloud Messages client exists;
- logout and legacy cloud sync are inactive;
- no foreground or background legacy sync is active;
- no other sampler or coordinator lease owns the three scopes;
- all V2 outboxes for those scopes are empty;
- a local protector sentinel round trip succeeds;
- the account fingerprint remains unchanged;
- current journal use is inside the sampler budget.

Preflight must not check or reset the clique, refresh authorization or PCS,
erase tokens, delete zones, or make a network request. The first network call
occurs only after the confirmation and successful local preflight.

## Write tripwires

Use three independent barriers:

1. `RustCloudSyncTransport` refuses V2 push, allocation, conflict-write, and
   delete operations.
2. A shadow-only store façade delegates checkpoint, journal, lease,
   pull-result, and run-record methods, and rejects semantic/outbox/record-map
   mutation.
3. A rejecting inbox applier throws if semantic apply is attempted.

Also add a session-only `cloudV2ShadowRunActive` interlock to legacy CloudKit
save/delete/upload entry points. An attempted legacy write during a sampler
must fail locally with `cloud_sync_shadow_write_tripwire`.

Move `recoverExpiredOutboxLeases()` under the `saves` feature gate. A read-only
sampler must never inspect or mutate outbox work.

A successful report requires `applied`, `confirmed`, `deferred`, and `retried`
to remain zero.

## Lifecycle

The one-shot controller follows:

```text
register active sampler
try
  run local preflight
  create runtime
  run one manual pass
  validate write tripwires
  produce redacted report
finally
  await runtime disposal and full quiescence
  unregister active sampler
```

Logout and account replacement must cancel and await the active sampler before
clearing state or disposing the Cloud Messages client.

## Report contract

Export only:

- schema version and random local run ID;
- UTC timestamp;
- platform, architecture, and build commit;
- manual read-only mode and disabled automatic-trigger state;
- at most an eight-character fingerprint prefix;
- legacy-sync state;
- configured page/change limits;
- tripwire state and outbox counts before/after;
- per-zone status, fetched/journaled/rejected counts, conservative bytes,
  elapsed time, and allowlisted failure/skip/block category.

Never export Apple IDs, DSIDs, full fingerprints, handles, participants,
message bodies, filenames, raw or hashed Apple record identifiers, etags,
batch/change IDs, continuation tokens, protected values, ciphertext, keys, or
server bodies.

Phase 1 does not prove message semantics. It proves bounded CloudKit access,
durable protected journaling, checkpoint behavior, isolation, and replay
idempotence.

## Planned files

New:

- `cloud_sync_dev_gate.dart`
- `cloud_sync_shadow_store.dart`
- `cloud_sync_manual_shadow_sampler.dart`
- `cloud_sync_shadow_report.dart`
- `cloud_sync_v2_shadow_panel.dart`

Modify:

- `cloud_sync_engine.dart`
- `rust_cloud_sync_transport.dart`
- `cloud_sync.dart`
- `rust/src/api/api.rs` and generated bindings
- `rustpush_service.dart`
- `troubleshoot_panel.dart`

No ObjectBox schema change is required.

## Required tests

- sampler is absent when the compile flag is false;
- construction performs zero network calls;
- unsupported platform, non-UI isolate, missing/stale account, legacy-sync,
  active lease, active sampler, and nonempty outbox all fail closed;
- exact scopes, flags, page count, change count, and budgets cannot be relaxed
  by UI input;
- shadow store, transport, and applier reject every mutation route;
- saves disabled means outbox recovery is never called;
- account change after fetch discards the page before journaling;
- success, error, cancellation, concurrent run, route close, logout, and
  account switch all await quiescence;
- protector failure leaves checkpoint and journal unchanged;
- report serialization is allowlisted and passes a forbidden-value scan;
- static scan confirms sampler files contain no save/delete/upload bridge call;
- Android fake-binding behavior and Windows ARM64/x64 fixtures normalize
  identically.
