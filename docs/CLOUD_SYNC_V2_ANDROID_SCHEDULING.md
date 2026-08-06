---
type: implementation_note
title: Cloud Sync V2 Android Scheduling Foundation
description: Dormant WorkManager policy, constraints, and integration gates for Cloud Sync V2.
resource: openbubbles-app
tags: [android, workmanager, cloud-sync, battery, safety]
timestamp: 2026-08-01
---

# Cloud Sync V2 Android Scheduling Foundation

## Current behavior

The Android scheduling adapter is present but disabled by default. Nothing in
`MainActivity`, `APNService`, `MethodCallHandler`, or the APNs/IDS receive path
calls it. The dormant worker validates only redacted scheduling input and exits
successfully. It does not start a Flutter engine, call Rust, open ObjectBox, or
perform CloudKit I/O.

When a future reviewed composition explicitly enables it, each request will:

- wait 15 seconds from the first hint, coalescing same-scope hints with one
  scope-hashed WorkManager unique-work name and `ExistingWorkPolicy.KEEP`;
- require `CONNECTED`, `BatteryNotLow`, and `StorageNotLow` for metadata;
- additionally require `UNMETERED` for automatic media;
- use normal one-time work only. No polling, battery-optimization prompt, or
  expedited request is present. A user-visible manual kind is explicit but is
  still normal work until its foreground/user-notification contract is reviewed;
- allow explicit cancellation by the same scope-hashed unique-work name.

The WorkManager request surviving process death is only a wake handoff. It is
not a lock and never authorizes work by itself. Any live handoff must acquire,
renew, and release the existing ObjectBox coordinator lease transactionally.
Network I/O, Apple cryptography, and CloudKit remain outside ObjectBox
transactions.

## Remaining gates before any activation

1. Compose a Flutter/Rust entrypoint that reads the durable account-scoped
   ObjectBox state and treats a lost lease or cancellation as a clean stop.
2. Test foreground-engine versus APNs-worker contention, process death before
   and during lease acquisition, and cancellation while the durable worker is
   pending or active.
3. Require the V2 read-only shadow, protected storage, and explicit rollout
   gates already documented in `CLOUD_SYNC_V2.md`. Keep all writes blocked.
4. Add a user-visible foreground/notification design before considering any
   expedited behavior. Do not place CloudKit on the IDS/APNs receive path.
