---
type: research_note
title: Cloud Sync V2 Production Readiness Research
description: Current primary-source and upstream-issue evidence for production gates on Android, Windows x64, and Windows ARM64.
resource: openbubbles-app
tags: [cloud-sync, cloudkit, android, windows, objectbox, rustpush, production-readiness]
timestamp: 2026-08-01
---

# Cloud Sync V2 production readiness research

## Decision

Keep Cloud Sync V2 in read-only shadow mode. Do not enable semantic pull, saves,
or tombstones for general users until the release gates below pass on a real Pixel,
Windows x64, and Windows ARM64. The architecture in `CLOUD_SYNC_V2.md` remains
sound, but current upstream reports prove that authentication/PCS, partial history,
large-history responsiveness, and two-phase attachments are not yet production
risks that can be treated as hypothetical.

This note is source research, not an assertion that the private Apple Messages
CloudKit service supports a particular client behavior. No Apple access was made,
and no third-party code was copied.

## Primary-source findings that change the implementation gate

### CKSyncEngine is a model, not a usable transport replacement

Apple documents that `CKSyncEngine` must be initialized with its last state
serialization, and that an app must durably persist every state update together
with the local changes to which it applies. It batches record changes, has a
250-record request maximum, emits per-record failures, uses push subscriptions as
sync hints, monitors account changes, and can cancel outstanding operations.
It handles transient network and throttling failures, but the application still
owns conflict handling, zone recreation, and local persistence.

OpenBubbles cannot substitute this API for the private Messages container. Apply
the same invariants to the Rust transport: atomically couple journal/checkpoint,
make deletions tombstones, retain a pending operation after a missing or failed
per-record response, and treat any push as a coalesced *hint* to fetch rather
than proof of data. On account switch or sign-out, stop the scoped coordinator,
retire its lease, and never reuse its checkpoint or queue for a different account.

Sources: [Apple CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5),
[WWDC23 Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/),
and [Apple's MIT sample](https://github.com/apple/sample-cloudkit-sync-engine).

### Android must not poll for near-real-time reconciliation

Android Doze suspends network access and defers JobScheduler work, including
WorkManager. The platform recommends FCM rather than a persistent client
connection when it is available. Normal-priority notifications may wait for a
maintenance window. High priority is only for user-visible, time-sensitive
notifications; it receives a short processing window, after which an expedited
WorkManager job may continue necessary work. WorkManager is restart/reboot
durable, but normal workers are not real-time and have a ten-minute execution
limit.

For the private APNs/IDS path, do not request a battery-optimization exemption
merely to improve CloudKit freshness. A received IDS/APNs event, foreground
resume, manual sync, or detected local gap should enqueue one named, account-
scoped sync request. Coalesce events for 15 seconds, give an interactive manual
request a 30-second foreground budget, and let ordinary reconciliation use a
network-constrained WorkManager job. Use unmetered network for attachment
prefetch and user-selected media only; metadata and user-tapped media may use a
connected network. Persist the lease before scheduling, and release it only after
the ObjectBox transaction marks the page outcome.

Android Keystore operations cross into a system process and Android explicitly
warns of performance trade-offs. It should unwrap a per-install master once when
the worker starts, protect it in memory only for that bounded run, and encrypt
small journal values locally. It must not Keystore-wrap every record, attachment
chunk, retry, or UI frame.

Sources: [Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby),
[WorkManager scheduling](https://developer.android.com/develop/background-work/background-tasks/persistent),
[battery optimization guidance](https://developer.android.com/develop/background-work/background-tasks/optimize-battery),
[FCM priority](https://firebase.google.com/docs/cloud-messaging/android-message-priority),
and [Android Keystore](https://developer.android.com/privacy-and-security/keystore).

### Windows secrets and migrations need one user-scoped, architecture-neutral contract

Default DPAPI protection is decryptable by the same Windows user on the same
machine. `CRYPTPROTECT_LOCAL_MACHINE` instead permits every local user and is not
appropriate for Apple identity material. DPAPI is an OS service, not a portable
backup format; a copied Windows profile or different user must fail closed and
enter an explicit recovery flow.

Use the same current-user DPAPI blob and format for x64 and ARM64. Protect one
random master key at profile initialization and use that master for normal
authenticated encryption, rather than calling DPAPI for every secret use. For a
migration: take an exclusive, user-qualified lock; parse/authenticate the whole
legacy file; write and flush a same-directory temporary V2; reopen and verify it;
then invoke `ReplaceFileW` with a backup. `ReplaceFile` may still fail at several
steps, so startup must examine original, replacement, and backup candidates by
format version and authenticated content before declaring a corrupt empty store.
Do not use TxF as the recovery strategy.

Sources: [CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata),
[DPAPI scope guidance](https://learn.microsoft.com/en-us/windows/win32/seccrypto/example-c-program-using-cryptprotectdata),
and [ReplaceFileFromAppW failure semantics](https://learn.microsoft.com/en-us/windows/win32/api/fileapifromapp/nf-fileapifromapp-replacefilefromappw).

### ObjectBox needs page-level writes, not message-level durability calls

ObjectBox states that commits require a filesystem sync and can cost milliseconds;
many implicit puts turn a large history into a write-amplification and UI-jank
problem. Its explicit transactions are ACID and are the right boundary for
`inbox rows + semantic writes + contiguous applied position`, not for network,
PCS decryption, or attachment downloading. Keep external Apple IDs as stable
unique properties, not ObjectBox IDs. Preserve the ObjectBox model JSON and UIDs
as source-controlled migration state across all three platforms.

For media, stream into a bounded temporary file, hash while streaming, validate,
flush, atomically place it under a content hash, then transactionally create the
attachment reference. A message with text and an attachment is expressly a
two-phase delivery shape upstream, so attachment updates must be idempotent and
requeue a missing local blob after the metadata replacement commits.

Sources: [ObjectBox transactions](https://docs.objectbox.io/transactions),
[ObjectBox IDs](https://docs.objectbox.io/advanced/object-ids), and
[ObjectBox model IDs and UIDs](https://docs.objectbox.io/advanced/meta-model-ids-and-uids).

## Current OpenBubbles evidence

| Evidence | Production implication |
| --- | --- |
| [#222](https://github.com/OpenBubbles/openbubbles-app/issues/222), updated 2026-07-22: `AnyhowException (Bad message)` after reinstall/sync | Never make local-state wipe the recovery path. Preserve a redacted failure envelope, checkpoint, and raw protected record reference for diagnosis. |
| [#186](https://github.com/OpenBubbles/openbubbles-app/issues/186): PCS share-key failure | Missing PCS/clique material is a paused, typed, non-destructive state, not a retry loop or reset condition. |
| [#212](https://github.com/OpenBubbles/openbubbles-app/issues/212): only partial history and empty chats | A completion UI must distinguish fetched pages, semantically applied records, quarantined records, and declared time-window exclusions. |
| [#194](https://github.com/OpenBubbles/openbubbles-app/issues/194): eight-year history causes performance issues | Enforce bounded raw-page, protected-journal, semantic-apply, and UI-yield budgets. Time-window sync is a product choice, never an invisible data-loss mechanism. |
| [#207](https://github.com/OpenBubbles/openbubbles-app/issues/207): text-plus-attachment second phase persists metadata but does not start download | Make attachment metadata updates enqueue idempotent blob work; expose pending/retry state rather than a dead MIME placeholder. |
| [#169](https://github.com/OpenBubbles/openbubbles-app/issues/169): Apple response schema lacks `trustedPhoneNumbers` | Treat login/profile responses as versioned, optional-field protocol data; decode failures must be recoverable diagnostics, never an unhandled setup crash. |
| [#226](https://github.com/OpenBubbles/openbubbles-app/pull/226): acknowledged push after failed handling could permanently drop an incoming message | Retain the ordering invariant: commit semantic message state before acknowledgement; a failure leaves the event retryable. |
| [#231](https://github.com/OpenBubbles/openbubbles-app/pull/231), draft: remaining long-duration and Windows validation | Its Android cache limits are useful guardrails, but x64 installation/launch and ARM64 remain explicit readiness gaps. |

`rustpush` is presently reported by GitHub as license `Other`; keep it as a
protocol boundary and do not copy source into the Apache-2.0 Flutter layer without
an explicit license decision. Apple's sample is MIT. ObjectBox documentation and
Android/Windows documentation are design references, not code sources.

## Direct rustpush transport evidence and V2 adapter requirements

The current [`cloud_messages.rs`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs)
implements three private zones: `chatManateeZone`, `messageManateeZone`, and
`attachmentManateeZone`. The record decoder defines encrypted
[`chatEncryptedv2`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L232-L233),
[`MessageEncryptedV3`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L314-L315),
and [`attachment`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L473-L474)
records. `CloudAttachment` contains metadata and CloudKit assets, but the
fetch path requests `NO_ASSETS`; it is therefore metadata reconciliation, not
proof that a local attachment blob is present.

The generic fetch path forwards an opaque continuation token to CloudKit and
returns the next token plus an in-memory map of `record ID -> decoded record or
None`. A missing `change.record` becomes `None` (a deletion/tombstone signal).
However, a record whose type differs from the requested type is silently skipped,
and a `PCSRecordKeyMissing` clears the cached zone configuration then aborts the
entire call. The code also dereferences several server fields with `unwrap`.
See [`sync_records`, lines 503-549](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L503-L549).

V2 must not expose that lossy map as its checkpoint boundary. The Rust bridge
should return an ordered, bounded raw change envelope for *every* change with:
record-ID hash, record type, deletion marker, raw protected payload reference,
server status, and next-token candidate. Dart can then commit the complete page
to the account-scoped journal before invoking a strict decoder. A missing PCS
record key becomes a per-record quarantined/paused outcome where possible. If the
private protocol makes it impossible to continue past the missing key, preserve
the pre-page token and report the whole page as blocked. Do not silently advance
to the returned token.

The current save path batches 256 operations and records individual save
outcomes, which is useful for V2's explicit-confirmation rule. The delete path
instead retries whole 256-record batches three times at a fixed five-second
delay and returns only a batch-level result. See
[`save_records`, lines 552-582](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L552-L582)
and [`delete_records`, lines 584-599](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L584-L599).
Before enabling tombstones, change the V2 adapter contract, not necessarily the
legacy path: retain each delete as a durable outbox item until a specific server
confirmation is recorded; retry only classified transient failures; and preserve
any server-provided retry hint. Fixed retries are unacceptable for an automatic
mobile/desktop scheduler.

The upstream implementation includes a `reset()` routine that deletes the three
active zones plus several additional private zones. It is not a recovery action
for V2. An automatic call would be destructive and cannot repair an account
switch, failed PCS fetch, or continuation issue. See
[`reset`, lines 620-652](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L620-L652).

One current issue supplies a Windows ARM64 production failure mode that belongs
in the scheduler tests: a backward NTP correction after Modern Standby can panic
the IDS identity cache and drive a CloudKit retry loop at approximately 13
errors/minute with a pegged core. [rustpush #29](https://github.com/OpenBubbles/rustpush/issues/29)
has the reproduction and evidence. All sync backoff and lease expiry must use a
monotonic elapsed clock in-process. Persisted eligibility time must tolerate a
wall-clock rollback by imposing a bounded restart delay, not repeatedly becoming
immediately eligible.

## Exact platform constraints and recovery additions

For normal metadata reconciliation, require `NetworkType.CONNECTED` plus
`BatteryNotLow` and `StorageNotLow`. For automatic attachment prefetch, require
`NetworkType.UNMETERED`, `BatteryNotLow`, and `StorageNotLow`; add `RequiresCharging`
only for non-user-visible catch-up/backfill. Multiple WorkManager constraints are
conjunctive, and a worker stops and retries if one becomes unmet mid-run. Do not
set `DeviceIdle` on an interaction-triggered sync because it intentionally waits
for inactivity. Sources: [Android work-request constraints](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)
and [Constraints.Builder](https://developer.android.com/reference/kotlin/androidx/work/Constraints.Builder).

DPAPI's documented same-user/same-machine scope means a protected blob should
be architecture-neutral in representation, but this is an interoperability
requirement to prove, not a Windows guarantee specific to OpenBubbles. The
release test must copy one synthetic profile between an x64 and ARM64 build
under the same user, protect/unprotect fixture secrets in both directions, then
repeat after a partial migration. A different Windows user or machine must fail
closed. `ReplaceFileW` requires replacement, target, and optional backup to be
on the same volume, and documents intermediate failure outcomes, so startup
recovery must authenticate and choose among original, replacement, and backup;
it must never pick a file merely because it exists. Source:
[ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).

## Additional focused tests

1. A fixture page containing a tombstone, an unsupported record type, a malformed
   encrypted record, and a PCS-key-missing record must either journal all four
   outcomes or leave the old checkpoint unchanged.
2. Replay a raw page twice on Pixel, Windows x64, and Windows ARM64. Compare a
   normalized export of logical IDs, revisions, tombstone state, attachment
   content hashes, and quarantine category. ObjectBox internal IDs, timestamps,
   filesystem paths, and protected bytes are deliberately excluded.
3. Deliver attachment metadata twice, then complete or cancel the blob stream in
   each order. The message must have one attachment reference and at most one
   final content-addressed file. A restart between file placement and database
   reference must be repairable by startup reconciliation.
4. Inject a backward wall-clock adjustment during exponential backoff and after
   a Windows Modern Standby resume. Assert no panic, no CPU spin, one lease, and
   no more than the configured retry attempt before its monotonic delay expires.

## Decoder, scheduler, and media details from this follow-up pass

### Treat the private schema as partial knowledge, not a complete contract

Direct inspection shows useful but deliberately uncertain field semantics in
rustpush. A chat records a stable chat identifier, group identifier, service,
participants, read timestamp, GUID, optional display name, and optional group
photo; its `style` comment identifies 45 as normal and 43 as group. See
[`CloudChat`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L231-L269).
A message exposes unencrypted `utm`, `msgType`, and `eCode`, while its chat ID,
sender, Apple-epoch nanosecond time, GUID, service, flags, and compressed
protobuf payloads are encrypted. See
[`CloudMessage`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L313-L340).
Attachment metadata includes MIME type, declared total bytes, transfer state,
attachment GUID, filename, UTI, created date, and a truncated MD5 field, while
the record also has an `lqa` asset. See
[`AttachmentMeta` and `CloudAttachment`](https://github.com/OpenBubbles/rustpush/blob/master/src/imessage/cloud_messages.rs#L424-L477).

The comments explicitly call some fields unknown and state that dates can be
negative. V2 must therefore not treat `style`, `state`, transfer state, display
name, timestamps, filename, or truncated MD5 as an authoritative conflict key
or integrity proof. Use record identity plus the explicit logical GUIDs where
present; store unrecognized fields in the protected raw envelope for a later
decoder instead of normalizing them away. Validate actual blob byte count and a
full locally computed digest after download. Never derive a filesystem path from
the cloud filename or UTI.

The local private protocol defines each change as `identifier`, `etag`,
`recordType`, integer `type`, and optional `record`, and returns both a server
continuation token and a client change token. That makes a no-record change a
tombstone observation tied to the immutable identifier and etag, not a reason to
discard the record identity. It also carries `changedShares`, archived-record,
delta, obligation, and zone-attribute fields that the current path does not
model. See
[`RetrieveChangesResponse`](https://github.com/OpenBubbles/rustpush/blob/master/cloudkit-proto/src/cloudkit.proto#L772-L800).
V2 raw pages must preserve all of these known fields or explicitly record the
unsupported field category before checkpoint advancement. A tombstone's durable
identity is `account scope + zone + record identifier hash + etag`, not only a
message GUID that may be unavailable after deletion.

### Checkpoint and quarantine model

The Apache CouchDB replication protocol provides a directly applicable durable
checkpoint rule: record a checkpoint only after a batch has been uploaded and
committed successfully, so recovery resumes at the last point of success. Its
history/common-ancestry algorithm also demonstrates why a checkpoint needs a
replication identity and session provenance, not merely a naked token. See
[CouchDB replication protocol](https://docs.couchdb.org/en/stable/replication/protocol.html).

For V2, add `checkpointGeneration`, `runID`, and `rawPageDigest` to the
account-scoped checkpoint. The one ObjectBox transaction that admits a page must
write: raw inbox rows or per-record quarantine rows, the page digest/generation,
and the next token candidate. The separate semantic transaction advances the
applied generation only through the contiguous resolved prefix. If current
protocol limitations force a whole-page PCS failure, store a scoped
`blockedPCS` generation with the old fetch token, not the returned token. A
manual credential/key recovery may clear only that scoped block and replay.

### Android process coordination and unique-work policy

`WorkManager.enqueueUniqueWork` guarantees only one named *work chain*, not a
single owner of ObjectBox across a foreground Flutter engine, background Flutter
engine, or an already-running worker. Use a unique name derived from an
account-scope hash and `KEEP` for a pure debounce trigger. Do not use `REPLACE`:
it cancels running work, and cancellation/constraint loss invokes `onStopped`.
The worker must make cleanup/cancellation idempotent and leave its durable lease
recoverable. `APPEND` is also wrong for recurring hints because a failed or
cancelled prerequisite propagates that status; `APPEND_OR_REPLACE` is useful only
when intentionally building a durable follow-up chain. Sources:
[Manage work](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/manage-work),
[ExistingWorkPolicy](https://developer.android.com/reference/androidx/work/ExistingWorkPolicy),
and [WorkManager](https://developer.android.com/reference/kotlin/androidx/work/WorkManager).

A Dart `RandomAccessFile` lock is not sufficient as the only coordinator: the
Dart API documents platform-specific semantics, including that multiple isolates
in one Linux/macOS process can obtain an exclusive advisory lock; on Windows the
lock is associated with the acquiring file handle. Use the ObjectBox lease row as
the authority, with a fencing generation checked in every write transaction.
Optionally add a best-effort native/file lock to reduce contention, but never let
it decide correctness. Source: [Dart RandomAccessFile.lock](https://api.dart.dev/dart-io/RandomAccessFile/lock.html).

### Attachment placement and time contract

The directly relevant `atomic-blob-store` project documents an appropriate
media-file contract: size-limited streaming write, content-addressed key,
complete-blob validation on read, explicit quarantine, and the possibility that
an atomic-commit error is ambiguous and must be resolved by reloading the
canonical location. Its license is reported by GitHub as `Other`, so use this as
an architectural reference only, not copied code. Source:
[atomic-blob-store](https://github.com/thehouseisonfire/atomic-blob-store).

Implement `attachment_download` as a durable state machine:
`metadataReady -> tempStreaming -> contentVerified -> filePlaced -> referenced`.
The temp filename must be generated in the final directory, opened exclusively,
and never exposed to the UI. Stream with a hard byte limit and a full SHA-256 or
BLAKE3 digest; validate expected length/type; flush and close; atomically place
under the digest; reopen and validate on an ambiguous placement error; then add
the ObjectBox reference. At startup, reconcile final files with references and
only remove an old, application-owned temp file after confirming that it is not
the sole recovery evidence for an in-flight journal row.

Use a monotonic clock only for in-process lease expiry, cancellation deadlines,
and retry delays. Rust documents `Instant` as opaque and monotonic but not
persistable or guaranteed to span suspension consistently, so it cannot be the
on-disk schedule. Android's `elapsedRealtime` is monotonic and includes deep
sleep; Windows QPC is monotonic and independent of external time. On restart,
compare a persisted wall deadline defensively: if it is implausibly far in the
future after clock rollback, cap the wait to a small conservative delay, retain
the attempt count, and record `clockSkew`; do not make the work immediately due
or reset its budget. Sources: [Rust Instant](https://doc.rust-lang.org/std/time/struct.Instant.html),
[Android SystemClock](https://developer.android.google.cn/reference/android/os/SystemClock),
and [Windows QPC guidance](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps).

## New regression cases

1. Decode every known field from the three record types, plus negative dates,
   unknown enum values, absent optional fields, an unknown record type, and a
   tombstone with only identifier/etag/type. Assert lossless protected-envelope
   journaling and no panic.
2. Race a foreground engine, an APNs background engine, and a WorkManager worker
   against one account scope. Verify unique-work coalesces hints while the
   ObjectBox fencing lease admits exactly one semantic/page writer.
3. Cancel an active unique work request and drop the network constraint mid-page.
   Verify `onStopped` leaves no in-flight lease permanent, no token movement,
   and no partially referenced attachment.
4. Kill during each attachment state and simulate a final-placement ambiguity.
   Restart must reach one of: verified final blob plus reference, verified final
   blob awaiting reference, or a retained recoverable temp/journal row. It must
   never display a completed attachment whose digest was not verified.

## Budget proposal and acceptance tests

These are client policies, deliberately not claimed Apple service limits.

| Area | Budget | Gate |
| --- | --- | --- |
| Metadata fetch/admission | 256 records and 4 MiB decoded metadata per page; reject atomically above either bound | Exact limit, one-over, repeated continuation, malformed record, and crash before/after page journal commit. |
| Semantic apply | 100 records or 100 ms per ObjectBox transaction, then yield; no network/PCS work inside transaction | 8-year sanitized fixture: no duplicate GUID, no skipped contiguous checkpoint, UI remains responsive. |
| Automatic work | One coordinator/account/scope; 15 s trigger debounce; full-jitter persisted backoff, honor `Retry-After` | 100 push/reconnect hints, process death, clock change, and metered/unmetered transitions produce one active lease and no retry storm. |
| Android wake cost | No polling; normal background work for reconciliation; expedited work only immediately after a user-visible high-priority event | Doze, Battery Saver, locked screen, and 24-hour idle run: no exemption prompt, no persistent socket kept only for CloudKit. |
| Media | 1 concurrent automatic transfer, 2 user-tapped transfers; 8 MiB RAM buffer ceiling per transfer; streamed hash/dedupe | Text-plus-media two-phase event, duplicate attachment, cancellation midstream, disk full, resume, and orphan-temp cleanup. |
| Windows migration | x64 -> ARM64 -> x64 under the same Windows user; no plaintext secret file; crash points at every migration step | Original/temp/backup recovery permutations, second process lock contention, wrong user, and corrupted authenticated blob fail closed. |

## Ship criteria

Enable Phase 2 semantic pull only after all three platforms pass the same
fixture/replay corpus, Android passes the Doze and locked-phone suite, and both
Windows architectures pass profile migration plus installed-artifact smoke tests.
Enable writes only after partial save/delete responses, zone loss, retry-after,
PCS unavailable, account switch, and offline two-client convergence have no
message loss, duplicate logical GUID, account bleed, or implicit destructive
recovery. Profiles remain a separate opt-in because their transport/auth failure
must never block Messages reconciliation.

## Blocker-focused evidence update: 2026-08-01

### FRB 2.3.0 bindings: one canonical generator, multiple compile consumers

This tree pins `flutter_rust_bridge` 2.3.0 in both Rust and Dart, and both
generated roots report codegen version 2.3.0. FRB performs a runtime codegen
version sanity check, so a locally newer generator is not a harmless formatting
change. The upstream 2.3.0 CI generated examples on Windows, macOS, and Ubuntu
and failed when regeneration changed committed output. This is evidence that
generation is intended to be deterministic across hosts, not evidence that an
ARM64 Windows host must generate ARM64-specific Dart bindings. Source:
[FRB 2.3.0 generation CI](https://github.com/fzyzcjy/flutter_rust_bridge/blob/v2.3.0/.github/workflows/ci.yaml#L170-L221).

Make Ubuntu the only binding-authority job. Regenerate with the exact released
generator, then fail on any committed-output drift:

```bash
cargo install flutter_rust_bridge_codegen --version 2.3.0 --locked
flutter_rust_bridge_codegen --version
flutter pub get
flutter_rust_bridge_codegen generate
git diff --exit-code -- \
  lib/src/rust \
  rust/src/frb_generated.rs \
  rust/src/frb_generated.io.rs \
  rust/src/frb_generated.web.rs
```

`flutter pub get` is deliberately separate because FRB's `generate` command
does not perform the integration command's package setup. The Windows x64 and
Windows ARM64 jobs should consume the committed output without regenerating it,
then compile and run an ABI/load smoke test. A Windows-only generated diff is a
generator bug to isolate, not output to commit conditionally. The drift check
must include the namespace/API Dart files as well as the three top-level Rust
files.

### Vendored OpenSSL on `aarch64-pc-windows-msvc`

The locked path is `openssl` 0.10.68, `openssl-sys` 0.9.104, and
`openssl-src` `300.4.1+3.4.0`. That `openssl-src` release maps
`aarch64-pc-windows-msvc` to OpenSSL Configure target `VC-WIN64-ARM`, then uses
the MSVC and `nmake` branch. It does not use the Unix `clang` path for that
target. Source:
[openssl-src target selection](https://github.com/alexcrichton/openssl-src-rs/blob/300.4.1%2B3.4.0/src/lib.rs#L310-L313).

Therefore an error where GNU `clang` receives flags such as `/O2`, `/Fd`, or
other MSVC-style options is a contaminated or unsupported toolchain route. It
is not fixed safely by suppressing the flags. A reported Rust ARM64 Windows
failure was resolved by installing the Visual Studio ARM64 components plus
Perl and making `nmake` available:
[rust-openssl issue 2236](https://github.com/sfackler/rust-openssl/issues/2236).
OpenSSL's `VC-WIN64-ARM` configuration was also reported as Windows-specific
and unsuitable for Linux `clang-cl` cross compilation:
[OpenSSL issue 12363](https://github.com/openssl/openssl/issues/12363).
A later cross-configuration effort exists, but it is not present in this locked
OpenSSL 3.4.0 source:
[OpenSSL PR 28545](https://github.com/openssl/openssl/pull/28545).

The preferred CI lane is a native Windows ARM64 runner initialized with the
Visual Studio ARM64 build environment. Before Cargo, remove generic GNU
compiler overrides from the current process and prove the required tools:

```powershell
'CC','CXX','CFLAGS','CXXFLAGS','AR','RANLIB','CROSS_COMPILE' |
  ForEach-Object { Remove-Item "Env:$_" -ErrorAction SilentlyContinue }

where.exe cl
where.exe link
where.exe lib
where.exe nmake
where.exe perl
cargo build --locked --target aarch64-pc-windows-msvc
```

If vendoring remains unreliable, the supported escape hatch is a versioned,
checksummed ARM64 OpenSSL artifact, not a Linux GNU-clang build. `openssl-sys`
checks target-prefixed environment variables before generic ones, so the
fallback can be scoped without changing x64:

```powershell
$env:AARCH64_PC_WINDOWS_MSVC_OPENSSL_NO_VENDOR = '1'
$env:AARCH64_PC_WINDOWS_MSVC_OPENSSL_LIB_DIR = 'D:\deps\openssl-arm64\lib'
$env:AARCH64_PC_WINDOWS_MSVC_OPENSSL_INCLUDE_DIR = 'D:\deps\openssl-arm64\include'
$env:AARCH64_PC_WINDOWS_MSVC_OPENSSL_STATIC = '1'
cargo build --locked --target aarch64-pc-windows-msvc
```

The job must inspect the `.lib` machine type as ARM64 and record the dependency
hash before accepting this route. The prefix behavior and vendored opt-out are
defined by the locked build script:
[openssl-sys environment resolution](https://github.com/sfackler/rust-openssl/blob/openssl-v0.10.68/openssl-sys/build/main.rs#L41-L54).

### CloudKit and PCS: safe two-account, read-only validation

Apple's public automation boundary is important here. A CloudKit management
token can manage schema but cannot access private or shared data. A user token
can access private/shared data only after interactive authorization and is
short-lived. `cktool` stores its credentials in the macOS Keychain and operates
against a developer's own container. Sources:
[Automating CloudKit Development](https://developer.apple.com/icloud/cloudkit/automating/)
and [cktool](https://developer.apple.com/icloud/ck-tool/).

OpenBubbles reads Apple's private `com.apple.messages.cloud` service container,
not an OpenBubbles-owned development container. Consequently, CloudKit Console,
schema reset, `cktool`, management tokens, and a development-environment clone
are not safe or applicable ways to test this integration. Apple does recommend
real-world tests on multiple devices with different iCloud accounts, and its
sharing sample explicitly uses two devices logged into different accounts:
[CloudKit testing guidance](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html)
and [CloudKit sharing sample](https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users).

Use this read-only live protocol:

1. Create two dedicated, consenting, non-personal Apple test accounts, each
   containing only synthetic Messages text and media. Use one isolated device
   or OS profile and one application data directory per account.
2. Gate the build to fetch and raw-journal only:
   `semanticApply=false`, `saves=false`, `deletes=false`, `profiles=false`, and
   outbound notification/write paths disabled. Abort the run if instrumentation
   observes any write-class request.
3. Run cold fetch, continuation, retry, and replay for account A, then repeat
   independently for B. Hash account identifiers in telemetry. Do not store
   Apple credentials, user tokens, PCS material, or message contents in CI.
4. Test switching only after the independent runs pass. Stop the old
   coordinator, prove its lease is released, select the new account-scoped
   store/checkpoint, and then start B. A row, token, media reference, or log
   correlation crossing scopes is a hard failure.
5. Never reset a trusted clique, delete a zone, modify records, or invoke
   CloudKit developer tooling against the Messages service as a recovery step.

PCS fault behavior should be fixture-driven first. At the current rustpush
revision, `pcs_keys_for_record` can panic when both `protection_info` and
`pcs_key` are absent, and returns `PCSRecordKeyMissing` when the requested key
ID is absent from zone defaults:
[rustpush PCS key path](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/cloudkit.rs).
Add fixtures for both fields absent, unknown key ID, stale zone-key cache,
corrupted wrapped key, and successful refresh. V2 must translate every case to
a typed scoped result, retain the old checkpoint, and never panic or trigger a
destructive clique action. The live two-account pass then validates only that
these boundaries stay read-only under real authentication.

### Android production telemetry: published redlines and local gates

The exact public Android production thresholds are platform vitals, not a
universal sync-specific mAh or CPU budget:

| Signal | Published production threshold |
| --- | --- |
| Excessive partial wake lock | At least 2 cumulative background hours in a 24-hour session; the Android Vitals bad-behavior threshold is 5% of sessions over 28 days. |
| Stuck partial wake lock | At least one background partial wake lock held for 1 hour in a 24-hour period. |
| Excessive wakeups | Play Reporting classifies users with more than 10 wakeups per hour. |
| User-perceived crash | 1.09% overall; 8% per-device bad-behavior threshold. |
| User-perceived ANR | 0.47% overall; 8% per-device bad-behavior threshold. |
| App launch target | Cold under 500 ms, warm under 200 ms, hot under 150 ms. |

Sources:
[excessive partial wake locks](https://developer.android.com/topic/performance/vitals/excessive-wakelock),
[stuck partial wake locks](https://developer.android.com/topic/performance/vitals/stuck-wakelock),
[Android Vitals core thresholds](https://developer.android.com/topic/performance/vitals),
[Play excessive wakeup rate](https://developers.google.com/play/developer/reporting/reference/rest/v1alpha1/vitals.excessivewakeuprate),
and [Android performance measurement](https://developer.android.com/topic/performance/measuring-performance).

A current production sync implementation provides useful scheduling constants,
but not a battery-consumption acceptance number. Firefox Android uses unique
work with `ExistingWorkPolicy.KEEP`, requires a connected network, applies
exponential backoff starting at 3 minutes, delays startup sync by 5 seconds to
avoid database contention, and notes WorkManager's 15-minute minimum periodic
interval:
[Firefox WorkManagerSyncManager at commit fe8a71c](https://github.com/mozilla-mobile/firefox-android/blob/fe8a71cd70ad5674abe1824fe11dc78372b736c2/android-components/components/service/firefox-accounts/src/main/java/mozilla/components/service/fxa/sync/WorkManagerSyncManager.kt#L184-L266)
and [its timing constants](https://github.com/mozilla-mobile/firefox-android/blob/fe8a71cd70ad5674abe1824fe11dc78372b736c2/android-components/components/service/firefox-accounts/src/main/java/mozilla/components/service/fxa/sync/WorkManagerSyncManager.kt#L546).

Do not invent a cross-device `mAh/hour` limit. Battery hardware, radio state,
message volume, and OEM scheduling make that number non-portable. Use paired
sync-off/sync-on runs on the same reference devices and retain raw charge,
worker-start, network-byte, CPU-time, wakeup, and wake-lock deltas.

For rollout, adopt stricter OpenBubbles alarms, explicitly labeled as local
policy rather than published Android limits:

| Signal | Proposed OpenBubbles stop/alarm gate |
| --- | --- |
| Sync-attributed wakeups | No account exceeds 10/hour; any repeated periodic pattern while idle is a hard failure. |
| Excessive partial wake-lock sessions | Alarm at 1%; stop staged rollout before the Play 5% redline. Cloud Sync V2 should acquire no manual partial wake lock. |
| User-perceived ANR | Alarm at 0.2% overall or 4% for a device cohort; stop on a statistically credible regression versus control. |
| User-perceived crash | Alarm at 0.5% overall or 4% for a device cohort; stop on a statistically credible regression versus control. |
| Launch time | Stop if enabled-vs-disabled P95 regresses by more than 10% on the same device/build; separately drive toward Android's absolute launch targets. |
| Battery energy | No universal absolute number. The enabled-run delta must remain inside the predeclared paired-test tolerance derived from control-run variance; publish the raw delta and interval. |

These gates turn published external failure thresholds into earlier rollback
signals while avoiding a fabricated battery precision that will not transfer
between Pixel, Samsung, and emulator cohorts.

## Notification, profiles, assets, and CI evidence update: 2026-08-01

### Private Messages zone change notifications

#### Verified facts

Apple documents CloudKit subscriptions as per-user notification sources, not
durable delivery logs. Changes in custom record zones can trigger push
notifications, but notifications may be coalesced, may omit the originating
device, and can be lost through APNs or network failure. Apple therefore
requires clients to treat push as a hint and fetch changes using persistent,
opaque server tokens:
[CKDatabaseSubscription](https://developer.apple.com/documentation/CloudKit/CKDatabaseSubscription),
[CKFetchRecordZoneChangesOperation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation),
and [Apple QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html).
Apple's private-database sample creates a `CKRecordZoneSubscription` with a
content-available notification:
[ViewModel.swift](https://github.com/apple/sample-cloudkit-privatedb-sync/blob/b30a0ccef9a2e22cc8d2dccf46819e0f9327ffcb/PrivateSync/ViewModel.swift).
Apple's current CKSyncEngine sample also states that remote-notification testing
requires a real device or Mac because simulators do not receive those pushes:
[sample-cloudkit-sync-engine](https://github.com/apple/sample-cloudkit-sync-engine).

Public rustpush master at commit
[`70ec162`](https://github.com/OpenBubbles/rustpush/commit/70ec162c6838830194d55792c8b26e4d6681c816)
already contains a generic `CloudKitNotifWatcher`. It parses APS CloudKit
payloads, filters them by container, deduplicates zones, debounces for 10
seconds, and returns changed record-zone identifiers:
[cloudkit.rs lines 618-655](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/cloudkit.rs#L618-L655).
The same client can request the container APS topic, create a database
subscription, and register its token:
[watch_notifs](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/cloudkit.rs#L1298-L1310)
and [subscription/token registration](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/cloudkit.rs#L1632-L1665).
The password-manager implementation proves that this generic path is wired for
another container in rustpush today:
[passwords.rs lines 1090-1175](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/passwords.rs#L1090-L1175).

Messages uses the private database in container `com.apple.messages.cloud` with
bundle identifier `com.apple.imagent`:
[cloud_messages.rs lines 78-82](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L78-L82).
However, the current `CloudMessagesClient` owns only a container client and
keychain and does not create a subscription, register a token, or own a
`CloudKitNotifWatcher`:
[cloud_messages.rs lines 479-493](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L479-L493).
The current IDS APS client requests only the Madrid and SMS topics, not the
Messages CloudKit container topic:
[aps_client.rs lines 116-130](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/aps_client.rs#L116-L130).

#### Inference and production action

Rustpush has a reusable CloudKit hint mechanism, but it does not currently
expose a reliable Messages-zone hint source to OpenBubbles. IDS arrival can
trigger an inexpensive reconciliation attempt, but it cannot prove that the
private zone is current. It does not represent missed history, deletions,
attachment materialization, or changes that occurred while the client was
offline.

Add a read-only experimental lane that requests the
`com.apple.icloud-container.com.apple.imagent` APS topic, creates the Messages
database subscription, registers its token, and maps returned zone identifiers
to the V2 scheduler. Keep that lane behind an experiment flag because this is
reverse-engineered use of an Apple private container. A push must only schedule
a checkpoint fetch. It must never advance a change token itself. Startup,
manual refresh, account reauthentication, and network recovery must still
reconcile without a notification.

### Shared profile, contact card, and avatar storage

#### Verified facts

Rustpush's current shared-profile implementation uses the public CloudKit
database in container `com.apple.messages.profiles`, bundle
`com.apple.imtransferagent`:
[name_photo_sharing.rs lines 253-282](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/name_photo_sharing.rs#L253-L282).
Its primary record type is `imsgNicknamePublicv2`, with name field `n`, avatar
metadata `am`, and avatar asset `ad`. The optional companion `poster` record
contains poster metadata `pr` and `wm` plus `lrwd` and `wd` assets:
[record definitions](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/name_photo_sharing.rs#L25-L80).
Inbound resolution fetches an exact pointer record and optional `<record>-wp`
companion, downloads their assets, and decrypts them using the key delivered in
the IDS `ShareProfileMessage`:
[get_record](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/name_photo_sharing.rs#L282-L335).

The public OpenBubbles default branch at commit
[`eed1b63`](https://github.com/OpenBubbles/openbubbles-app/commit/eed1b6332efbb17adbf5ebfa2263ad770169f75e)
attaches `ShareProfileMessage` to a one-to-one IDS message, then projects the
resolved name, raw avatar bytes, shared state, and optional poster path into an
ObjectBox `Contact`:
[rustpush_service.dart lines 2819-2906](https://github.com/OpenBubbles/openbubbles-app/blob/eed1b6332efbb17adbf5ebfa2263ad770169f75e/lib/services/rustpush/rustpush_service.dart#L2819-L2906)
and [contact.dart lines 15-42](https://github.com/OpenBubbles/openbubbles-app/blob/eed1b6332efbb17adbf5ebfa2263ad770169f75e/lib/database/io/contact.dart#L15-L42).
Its `savePoster()` and `saveTranscriptPoster()` paths call asynchronous
`savePosterData(...)` without awaiting completion, so a returned path or
preview can race file persistence:
[rustpush_service.dart lines 2957-2988](https://github.com/OpenBubbles/openbubbles-app/blob/eed1b6332efbb17adbf5ebfa2263ad770169f75e/lib/services/rustpush/rustpush_service.dart#L2957-L2988).
Open pull request
[#227](https://github.com/OpenBubbles/openbubbles-app/pull/227) explicitly
isolates malformed CloudKit profile failures from message delivery and adds a
bounded retry, but it is not merged into the default branch. Open issue
[#103](https://github.com/OpenBubbles/openbubbles-app/issues/103) records a
Linux chat-avatar flow stuck at “Saving avatar.” That issue concerns chat/group
avatar handling, not the shared-profile record schema, but it is still a
relevant avatar-persistence regression.

The rustpush write path has additional concrete hazards. It deletes the prior
record before replacement is ready, requests poster asset uploads using the
nickname record type, unwraps missing `lrwd` and `wd` upload responses, and may
delete the currently queried record before retrying a failed save:
[set_record lines 336-425](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/name_photo_sharing.rs#L336-L425).
Its own-record query returns the first public-zone result without an explicit
ordering or duplicate-reconciliation rule:
[get_my_record lines 426-461](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/name_photo_sharing.rs#L426-L461).
The mismatched upload record type is suspicious, but server-side failure from
that mismatch is not proven by the available source.

Reverse-engineered iOS 26.1 framework source independently corroborates the
schema. It queries `imsgNicknamePublicv2` by creator, reads `ad`, `wd`, `lrwd`,
and `wm`, and constructs both nickname and `poster` records:
[IMTransferAgent.mm](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/IMTransferAgent.framework/IMTransferAgent/IMTransferAgent.mm#L3087-L3089).
The decompiled nickname controller identifies container
`com.apple.messages.profiles`:
[IMTransferAgentNicknameController.mm](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/90aa0cfe59d9682b4265e1354c8b19ec3c7823ab/System/Library/PrivateFrameworks/IMTransferAgent.framework/IMTransferAgent/IMTransferAgentNicknameController.mm#L635).
Private SDK symbols also expose CloudKit record-key and decryption-key message
dictionary entries:
[IMDaemonCore.tbd](https://github.com/xybp888/iOS-SDKs/blob/1b92ff4a8928f582876e1d388d1381c6a0c59eb9/iPhoneOS26.1.sdk/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore.tbd).
These are useful reverse-engineered schema witnesses, not supported Apple API
contracts.

#### Inference and production action

The shared-profile path is pointer-driven public-record retrieval, not a
private-zone stream like Messages. Build a durable profile-pointer inbox from
decoded IDS metadata rather than inventing a public-database checkpoint poll.
Key each work item by account scope, sender, CloudKit record key, and
decryption-key fingerprint. Retain the received pointer, journal the raw
profile and asset metadata, fetch the exact record and optional poster, verify
the selected assets, then transactionally update the contact projection.

Keep device Contacts sync and own-profile publishing outside this stream.
Replace `unwrap` and unbounded in-memory asset failure paths with typed,
per-asset errors and bounded retry. Do not expose a poster path before its
atomic file write completes. Preserve pointer history and deduplicate it
because one sender may share the same profile with multiple handles. Treat
own-profile writes as a separate, explicit feature until replacement can be
made without delete-first data loss.

### Attachment retrieval, resume, and integrity

#### Verified facts

The Messages `CloudAttachment` field named `md5` contains only the first eight
bytes of MD5:
[cloud_messages.rs line 466](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L466).
The available CloudKit asset record contains stronger transport metadata:
asset signature, reference signature, expected size, download token and URLs,
expiration, protection information, and bundled request identifier:
[cloudkit.proto lines 1009-1027](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/cloudkit-proto/src/cloudkit.proto#L1009-L1027).
The generic proto also defines `sha256Signature`, but the current Messages
asset path does not populate or consume that field. It is therefore not a
proven expected digest for Messages attachments.

`download_attachment` accepts whole-record identifiers and caller-provided
write sinks, requests all assets, then delegates to `get_assets`:
[cloud_messages.rs lines 694-706](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L694-L706).
`get_assets` uses the full asset signature and protection information and
streams through MMCS:
[cloudkit.rs lines 2072-2100](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/cloudkit.rs#L2072-L2100).
MMCS records a full file checksum plus per-chunk checksums, sizes, and offsets.
It splits files into 5 MiB chunks and cryptographically checks V2 chunk IDs
during decryption:
[mmcs.rs](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/mmcs.rs).
Those verification branches currently use assertions, so corrupted input can
panic instead of returning a typed integrity failure.

The public API exposes no durable offset or resume token. The current MMCS
container opens an ordinary GET from the beginning and contains no Range,
If-Range, or Content-Range request handling:
[ensure_stream lines 927-980](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/mmcs.rs#L927-L980).
Its offset bookkeeping consumes bytes within the active stream; it is not
process-death resume. Apple's generic resumable-download guidance requires a
saved ETag plus `Range` and `If-Range`, followed by validation of a `206`
response and exact `Content-Range`:
[Apple QA1761](https://developer.apple.com/library/archive/qa/qa1761/_index.html).
That guidance defines a safe experiment, but it does not prove that MMCS
endpoints support ranges.

Open issue [#207](https://github.com/OpenBubbles/openbubbles-app/issues/207)
reports that the text-plus-attachment two-phase path persists replacement
metadata but does not start automatic download, while attachment-only messages
do. This is a current queue-orchestration failure rather than evidence of an
MMCS integrity defect.

#### Inference and production action

Persist the CloudKit asset signature, reference signature, expected size, MMCS
file checksum, and chunk manifest before transfer. Compute an
application-owned SHA-256 over final plaintext and use it as the content
address. The truncated MD5 may remain a compatibility field but must not be
the production integrity decision.

Implement the first safe resume boundary at verified MMCS chunks. Persist only
completed chunk identifiers, digests, sizes, and offsets, reauthorize after
restart, and assemble only verified chunks. Never blindly append to a partial
plaintext file. Convert all integrity assertions and missing-field unwraps to
typed `integrityMismatch`, `manifestChanged`, or `authorizationExpired`
failures before enabling production sync.

Treat byte-range resume as a later capability probe. Require `Accept-Ranges`
and ETag, send `If-Range`, accept only `206` with an exact `Content-Range`, and
discard the partial object on any mismatch or full `200` response. The durable
attachment queue must also model the issue #207 replacement event so metadata
arrival wakes the same download state machine as attachment-only delivery.

### Flutter Rust Bridge generation and native Windows CI

#### Verified facts

A current Flutter Rust Bridge project pins its generator, runs generation once
on Linux, fails on generated-file drift, and builds with
`--skip-frb-codegen` afterward:
[Xybrid build-flutter.yml](https://github.com/xybrid-ai/xybrid/blob/6f664540b17b2ff5c1cc13dd59a28e82ef475959/.github/workflows/build-flutter.yml#L123-L160).
Another current project checks both `git status --porcelain` and
`git diff --exit-code` after exact-version generation:
[NTS CI workflow](https://github.com/nick-llewellyn/nts/blob/236e78f803a8a7ce54a2136f911774a200256db6/.github/workflows/ci.yml)
and [development contract](https://github.com/nick-llewellyn/nts/blob/236e78f803a8a7ce54a2136f911774a200256db6/DEVELOPMENT.md).
Both checks are necessary because `git diff` alone misses newly generated,
untracked files.

GitHub now provides the standard `windows-11-arm` hosted runner to public and
private repositories, alongside x64 Windows labels:
[GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
and [private-repository availability announcement](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/).
Current Flutter Rust Bridge documentation identifies
`x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc` as the Windows targets.
A native Windows ARM64 build pattern from XNNPACK confirms that
`windows-11-arm` can use the native ARM64 MSVC compiler without a cross
toolchain:
[build-windows-arm64-native.cmd](https://github.com/google/XNNPACK/blob/c0e881d1947dc72787db45c380abed2a0e4e68c3/scripts/build-windows-arm64-native.cmd).

#### Inference and production action

Use one required `bindings` job on `ubuntu-24.04`. Install the exact project
Flutter Rust Bridge version, currently 2.3.0, with `--locked`; generate once;
then fail if either tracked generated content changed or a new generated file
appeared. Scope both checks to the configured Dart and Rust output paths.
Include `flutter_rust_bridge.yaml`, Cargo and pub manifests and locks, Rust API
sources, mirrored types, and generated outputs in the workflow path filter.

Make two native Windows jobs depend on `bindings`:

| Architecture | Runner | Rust target |
| --- | --- | --- |
| x64 | `windows-2022` | `x86_64-pc-windows-msvc` |
| ARM64 | `windows-11-arm` | `aarch64-pc-windows-msvc` |

Neither Windows job may install or invoke the generator. Each should assert
the runner architecture with
`[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture`, record
`rustc -vV`, run locked native compile and test steps, perform a PE
architecture/load smoke test, and verify that generated paths remain clean
after the build. If an ARM64 dependency is not yet portable, isolate only that
specific compile step as experimental and retain its logs. Do not mark the
whole architecture job successful while skipping native compilation.

## Decoder contract evidence update: 2026-08-01

### Fact: Messages stream identity is zone-scoped and type-specific

The current public rustpush Messages client reads `chatManateeZone`,
`messageManateeZone`, and `attachmentManateeZone`. Its encrypted record types
are respectively `chatEncryptedv2`, `MessageEncryptedV3`, and `attachment`.
The attachment record contains encrypted `cm` metadata plus the `lqa` asset;
message records include both encrypted fields and a small set of explicitly
unencrypted fields. These are reverse-engineered implementation schemas, not
an Apple public contract.

Source: [rustpush Messages schemas and zones at 70ec162](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L231-L314),
[attachment schema](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L444-L475),
and [zone methods](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L660-L730).

**Action:** Retain zone plus expected record type in every protected V2 raw
envelope. The semantic decoder may only project an upsert when the stream,
record type, record identifier, and encrypted record agree. Do not infer an
attachment's final content identity from its short `md5` metadata or from
unencrypted message fields.

### Fact: `change_type` cannot be the sole semantic discriminator

The V2 transport preserves `change_type` as `Option<i32>`. Authenticated Canary
evidence established the private Messages in iCloud matrix: `Some(1)` with a
record is a create/upsert, `Some(2)` with a record is an update/upsert, and
`Some(3)` without a record is a delete/tombstone. `None` remains valid when the
record body shape is otherwise unambiguous. Transport and semantic validation
must apply this same closed matrix; treating `2` as deletion rejects every live
updated record before PCS conversion.

Source: current V2 transport shape validation in
[`cloud_messages.rs`](../rustpush/src/imessage/cloud_messages.rs), bridge
validation in
[`cloud_sync_transient_bridge.rs`](../rust/src/cloud_sync_transient_bridge.rs),
and the closed semantic matrix in
[`cloud_sync_semantic_decoder.rs`](../rust/src/cloud_sync_semantic_decoder.rs).
Public rustpush also represents synced records as `Option` values, where
absence is the deletion signal, in
[the generic Messages sync contract](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L660-L688).

**Action:** Keep the transport, protected bridge, and semantic boundary on the
same validated matrix. Preserve the optional raw type for redacted diagnostics.
Retain fixtures for create, update, delete, `None` with either valid body shape,
and contradictory record/type shapes. No checkpoint may advance until each
change is projected or durably quarantined.

### Fact: PCS failures are wider than malformed record data

The public Messages sync loop specifically treats `PCSRecordKeyMissing` as a
key-material problem, clears the cached zone encryption configuration, and
returns the error. Rustpush also exposes distinct `NotInClique`,
`ShareKeyNotFound`, `MasterKeyNotFound`, and `NoRoutingKey` errors. Its older
generic decode paths still contain `expect` calls around PCS lookup, so a native
failure must not be reclassified as malformed payload merely because it reaches
the V2 boundary.

Source: [Messages PCS retry path](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L994-L1007),
[PCS lookup](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/cloudkit.rs#L548-L568),
[error definitions](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/error.rs#L200-L220),
and [generic panic-prone decode path](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/icloud/cloudkit.rs#L220-L239).

**Action:** Preserve a three-way V2 outcome: `blockedPCS` for known
key/clique/routing states, `retryableNativeFailure` for transport or unexpected
native errors, and `malformedProtectedRecord` only after deterministic envelope
or schema validation fails. All three retain the protected raw envelope and
keep the existing checkpoint. The decoder must never convert an unknown
`PushError` into a discardable malformed record.

### Fact: current upstream reports match the V2 loss and latency risks

Open issue [#222](https://github.com/OpenBubbles/openbubbles-app/issues/222)
reports a `Bad message` failure after reinstall, and open issue
[#212](https://github.com/OpenBubbles/openbubbles-app/issues/212) reports
partial history and empty conversations. Open issue
[#141](https://github.com/OpenBubbles/openbubbles-app/issues/141) reports
historical videos repeatedly failing while newly received videos work. These
reports do not prove a single root cause, but they rule out treating raw decode,
checkpoint, and attachment resumption as independent best-effort features.

Source: [#222](https://github.com/OpenBubbles/openbubbles-app/issues/222),
[#212](https://github.com/OpenBubbles/openbubbles-app/issues/212), and
[#141](https://github.com/OpenBubbles/openbubbles-app/issues/141).

**Action:** Production readiness requires fault-injection tests that interrupt
after raw page persistence, during PCS refresh, during semantic projection, and
during attachment transfer. Verify restart convergence against the same source
history, with no page-token jump, duplicate logical record, or permanently
stuck attachment job.

### Fact: a Windows ARM64 sleep/wake report shows native wall-clock panic can
wedge CloudKit retries

Open rustpush issue [#29](https://github.com/OpenBubbles/rustpush/issues/29)
documents a Windows ARM64 Modern Standby wake where a backward NTP correction
triggers `SystemTime::duration_since(...).expect(...)` in identity-cache
staleness logic, followed by repeated CloudKit sync failures, a frozen UI, and
high CPU. This is an upstream report, not yet a reproduced V2 defect.

Source: [rustpush issue #29](https://github.com/OpenBubbles/rustpush/issues/29)
and the implicated [identity-cache implementation](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/ids/identity_manager.rs#L45-L65).

**Action:** Add an ARM64 and x64 sleep/wake and backward-clock test gate around
Cloud Sync V2's cancellation/retry supervisor. Native panics must become a
single bounded failed run with diagnostics and backoff, never a tight restart
loop. Keep persisted server timestamps separate from eligibility deadlines and
continue using monotonic time for in-process lease and timeout decisions.

## Canonical local-projection evidence update: 2026-08-01

### Fact: the legacy CloudKit conversion path already carries most message
semantics, but it mutates while converting

`Message.applyFromCloud` decodes `MessageProto`, maps body and attachments,
reconstructs `MessageSummaryInfo` edit history (`ec`, `ep`, `otr`) and
retracted parts (`rp`), reads delivery/read timestamps, maps reaction ranges,
and reads threaded-reply and emoji metadata. It then calls `save(chat: chat)`
directly. Its matching upload method encodes the same edit/retraction/receipt
fields, so this is the closest existing field-level mapping witness.

Source: current legacy mapper in
[`message.dart`](../lib/database/io/message.dart) lines `1021-1220`, including
the [upload mapping](../lib/database/io/message.dart#L1021-L1106) and
[download mapping](../lib/database/io/message.dart#L1107-L1220). The public
Messages schema supplies `msgProto`, optional `msgProto2/3/4`, flags, GUID, and
chat ID: [rustpush schema at 70ec162](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L314-L368).

**Action:** Reuse the existing protobuf and attributed-body parsers as field
decoders, but not `Message.applyFromCloud` as an unguarded V2 callback. The
semantic adapter must first resolve its record-map idempotency key, then apply
the complete message, its edit/retraction history, and its associated-message
links in one bounded ObjectBox transaction. A completed journal entry must make
a second pass a no-op rather than a second `save`.

### Fact: legacy chat and attachment helpers have useful canonical identities,
but are not transactional primitives

`Chat.findFromCloud` resolves a cloud chat in priority order by `groupId`,
`chatIdentifier`, then exact participant set, and otherwise creates a chat.
`Chat.applyFromCloud` updates group version from `properties.pv`, last-read
GUID, participants, display name, cloud payload, and group photo state, then
writes to ObjectBox. `Attachment.applyFromCloud` maps a CloudKit attachment
record into its local metadata and normalizes an Apple attachment GUID of the
form `at_<part>_<message-guid>` into local `<message-guid>_<part>`, then writes
and optionally links it to the message.

Source: [chat lookup and creation](../lib/database/io/chat.dart#L1047-L1088),
[chat projection and persistence](../lib/database/io/chat.dart#L1167-L1208),
and [attachment GUID conversion plus persistence](../lib/database/io/attachment.dart#L57-L77).
The corresponding encrypted CloudKit records expose chat `group_id`,
participants, `properties`, optional `group_photo`, and attachment `cm` plus
`lqa`: [rustpush schemas](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L231-L297)
and [attachment schema](https://github.com/OpenBubbles/rustpush/blob/70ec162c6838830194d55792c8b26e4d6681c816/src/imessage/cloud_messages.rs#L444-L475).

**Action:** Treat the legacy lookup order and attachment GUID transform as
compatibility rules to test, not as a ready-made V2 transaction. Split V2 into
pure `resolveChat`, `projectChat`, and `projectAttachment` stages, then persist
their record-map updates and local entities atomically. Do not let a record-map
collision call legacy `findFromCloud`, `applyFromCloud`, or `backend.createChat`
outside that transaction.

### Fact: associated-message GUIDs need an explicit normalization contract

The legacy upload path serializes a reaction target as
`p:<part>/<guid>`. The download path assigns the received
`associatedMessageGuid` directly, while the local reaction lookup later queries
by exact local `Message.guid`. The source therefore does not establish that
CloudKit reaction targets arrive already normalized to the local GUID format.

Source: [reaction target serialization](../lib/database/io/message.dart#L1055-L1062),
[direct receive assignment](../lib/database/io/message.dart#L1180-L1191), and
[associated-message lookup](../lib/database/io/message.dart#L1222-L1235).

**Action:** Define one tested V2 parser for `p:<part>/<guid>` that yields the
logical parent GUID and part separately, while preserving the original raw value
in the protected envelope. Include fixtures for reaction add/remove, sticker,
thread reply, edit before parent arrival, unsend before parent arrival, and
parent record deletion. Deferred associations must be durable and must resolve
only when the parent record map is present.

### Fact: the legacy loop mixes inbound recovery with outbound deletion and
main-isolate writes

The current legacy sync loops immediately delete local rows for tombstones,
deduplicate record-ID conflicts by adding prior IDs to outbound deletion lists,
persist continuation tokens page by page, and call the mutation helpers while
decoding. It also performs the message loop on the Flutter main isolate and
yields only after every 25 records. Those choices explain why the helpers cannot
be reused as a crash-safe reconciliation engine without a transaction boundary.

Source: [legacy chat, attachment, and message loops](../lib/services/rustpush/rustpush_service.dart#L3157-L3445),
[local delete behavior](../lib/database/io/message.dart#L1253-L1271), and open
[large-history issue #194](https://github.com/OpenBubbles/openbubbles-app/issues/194)
plus [restart/hang issue #168](https://github.com/OpenBubbles/openbubbles-app/issues/168).

**Action:** V2 semantic apply must never enqueue an outbound CloudKit delete
while processing a remote upsert or tombstone. Retain tombstones and conflicting
record mappings for review, make the token/journal/entity update atomic, and
execute bounded batches outside the presentation-critical path. Require a
large-history restart test that injects interruption before and after each
commit, then verifies no duplicate entity, no outbound delete, and no
re-download of an already committed page.

### Fact: historical media and ARM64 resume failures are active upstream risk
signals

Open issue [#141](https://github.com/OpenBubbles/openbubbles-app/issues/141)
reports historical iCloud videos repeatedly failing to download even though
newly received video works. Open rustpush issue
[#29](https://github.com/OpenBubbles/rustpush/issues/29) remains open and
documents a Windows ARM64 sleep/wake backward-clock panic that can wedge
CloudKit retry behavior. Neither report proves V2 behavior, but both require
platform-specific interruption coverage before a production claim.

Source: [OpenBubbles #141](https://github.com/OpenBubbles/openbubbles-app/issues/141)
and [rustpush #29](https://github.com/OpenBubbles/rustpush/issues/29).

**Action:** Add a test matrix with a historical-video fixture and a simulated
ARM64 sleep/wake cancellation. The attachment state machine must leave a
durable retryable state with its verified metadata after interruption; the
supervisor must suppress tight retries after a native panic and require an
explicit safe re-entry trigger.

## Attachment resume and cross-box transaction evidence update: 2026-08-01

### Fact: the current MMCS read path verifies V2 chunks, but has no persisted
resume contract

The MMCS preparation path splits data into `5,242,880` byte chunks and carries
their IDs, sizes, and encryption metadata. During a V2 read, the decoder
decrypts a chunk, hashes its plaintext, and checks the derived HMAC against the
chunk ID. However, that integrity failure is currently an `assert_eq!`, not a
typed recoverable error. The get container opens an ordinary fresh HTTP stream,
tracks progress only in its in-memory `transfer_progress`, and does not expose a
range, ETag, `If-Range`, checkpoint, or cancellation argument. The generic
`FileContainer` writes each decoded chunk straight into its supplied writer.

Source: [5 MiB preparation and chunk descriptors](../rustpush/src/icloud/mmcs.rs#L185-L310),
[V2 decrypt and assertion](../rustpush/src/icloud/mmcs.rs#L933-L972),
[fresh stream and volatile progress](../rustpush/src/icloud/mmcs.rs#L1207-L1325),
and [get pipeline plus direct writer target](../rustpush/src/icloud/mmcs.rs#L1366-L1557).
The same durability pattern is used by mature resumable downloaders: Rustup
writes and verifies a `.partial` file before replacing the final file, while
Helmor persists a `.part`, verifies SHA-256, and only then renames it
([Rustup implementation](https://github.com/rust-lang/rustup/blob/a1676f4adf942c22c4a5ae58a8e30b8bb81a2029/src/dist/download.rs),
[Helmor worker](https://github.com/dohooo/helmor/blob/main/src-tauri/src/downloads/worker.rs)).

**Action:** Model MMCS authorization as an expiring transfer epoch, not as a
resumable HTTP byte stream. Persist, before writing, an immutable job identity
containing the CloudKit record/asset identity, expected logical size, ordered
chunk IDs and sizes, the authorization epoch, and a versioned local-stage
format. Persist only a verified contiguous chunk prefix, then on restart
re-authorize and compare the returned manifest before reuse. If the manifest or
record identity differs, abandon the stage as stale rather than appending.
Replace each V2 assertion with a typed integrity failure that preserves the
stage for diagnosis but never marks it complete. Do not promise byte-range
resume until MMCS authorization responses and `transfer_mmcs_container` prove
that range requests are supported.

### Fact: Cloud attachment downloads currently stream directly into their
final visible path

For cloud attachments, `RustPushBackend.downloadAttachment` gives the Rust
bridge `(attachment.path, cloudRecordID)`, so the MMCS writer owns the final
attachment path during the transfer. `FileContainer.write` calls `write_all`
without a staging or durable-sync step. The non-cloud `Attachment.writeToDisk`
helper also creates and writes its final path directly.

Source: [cloud download call site](../lib/services/rustpush/rustpush_service.dart#L554-L565),
[MMCS file writer](../rustpush/src/icloud/mmcs.rs#L518-L565), and
[direct local write helper](../lib/database/io/attachment.dart#L161-L165).
The Dart `File.rename` API documents that a rename cannot cross file systems and
may replace an existing destination, so a safe implementation must make the
destination and staging-path rules explicit rather than treating rename as a
general recovery mechanism ([Dart File API](https://api.dart.dev/stable/dart-io/File/rename.html)).

**Action:** Never send a final attachment path to a new V2 transfer. Create a
unique same-directory `<final>.cloudsync.<job-id>.partial` file and stream only
there. The state machine is `metadataReady -> transferPending -> streaming ->
verified -> filePlaced -> referenced`; file creation, writes, hashing, flush,
and rename stay outside ObjectBox transactions. After every verified contiguous
chunk, write a compact atomic sidecar/checkpoint; after the final size and
digest check, atomically place the file on the same volume, then perform the
short database commit that exposes the attachment. Startup reconciliation must
compare the final file, partial file, sidecar, and job state, and must never
blindly delete a partial merely because the process previously stopped. Guard
against an existing final destination before rename, because replacement would
otherwise turn a duplicate retry into data loss.

### Fact: cancellation is not presently a first-class MMCS download control

`get_mmcs` accepts the configuration, authorization response, output writers,
progress callback, and Ford flag. Its public signature contains no cancellation
token, and the inner reader awaits response chunks until EOF or an error. The
current native call surface can therefore report progress but cannot describe a
safe pause point or distinguish an intentional stop from a transport failure.

Source: [`get_mmcs` signature and transfer loop](../rustpush/src/icloud/mmcs.rs#L1366-L1377)
and [response-chunk read loop](../rustpush/src/icloud/mmcs.rs#L1300-L1315).
Open-source transfer engines that support recovery make this control explicit:
they observe cancel between chunks, preserve partial state, and resume only
after a protocol-supported checkpoint ([Helmor worker](https://github.com/dohooo/helmor/blob/main/src-tauri/src/downloads/worker.rs),
[rusty-cat restart design](https://github.com/0barman/rusty-cat)).

**Action:** Add a V2 native cancellation handle checked before each next chunk
read, before each stage write, and before final placement. Cancellation must
flush and retain the partial/checkpoint as `paused`, without publishing a final
attachment or advancing the semantic replay record. Treat network errors as
`retryable` only when the last durable checkpoint still validates; integrity,
manifest, or final-placement conflicts need distinct terminal or operator-visible
states. Keep transfer concurrency deliberately bounded, especially on mobile,
until actual battery, memory, and historical-video measurements justify a higher
limit.

### Fact: ObjectBox can compose multiple boxes in one Store transaction, but
the callback itself must be synchronous

OpenBubbles already wraps `Store.runInTransaction` as
`Database.runInTransaction`. Current ObjectBox Dart source rejects an async
transaction callback, because it would leave the transaction boundary while the
Future is outstanding. `runInTransactionAsync` instead opens an independent
Store connection in a worker isolate and still executes the transaction body
synchronously there. `Box.putMany` automatically wraps its own work in a
transaction for that box, but it does not define an atomic boundary with writes
to other boxes.

Source: [OpenBubbles database wrapper](../lib/database/database.dart#L240-L243),
[ObjectBox Store transaction implementation](https://github.com/objectbox/objectbox-dart/blob/main/objectbox/lib/src/native/store.dart),
and [ObjectBox Box batch implementation](https://github.com/objectbox/objectbox-dart/blob/main/objectbox/lib/src/native/box.dart).

**Action:** Every V2 state transition that changes a `Message`, `Chat`, or
`Attachment` together with a Cloud Sync record map, replay journal, inbox row,
or transfer-state row must execute in one short,
`Database.runInTransaction(TxMode.write, ...)` callback. Resolve network,
PCS/MMCS work, parsing, file I/O, hashing, and UI notifications before or after
that callback, never with `await` inside it. Where projection work is genuinely
expensive, use `runInTransactionAsync` with primitive immutable payloads, but
retain the same all-box transaction and idempotency key. A per-box `putMany`
call is not sufficient for exactly-once Cloud Sync replay.

## Semantic reconciliation and rebootstrap evidence update: 2026-08-01

### Fact: the three CloudKit streams have distinct canonical identities and
relationships

`chatEncryptedv2` carries a chat GUID, `chat_identifier`, `group_id`, service,
participants, optional properties, group-photo fields, and a display name.
`MessageEncryptedV3` carries message GUID, `chatID`, sender, timestamp,
service, flags, four protobuf envelopes, and unencrypted message type/error
fields. The `attachment` record carries encrypted attachment metadata (`cm`)
and an asset (`lqa`); the metadata includes the attachment GUID, transfer state,
filename/name, type, byte count, outgoing flag, dates, and optional MMCS or
inline transfer metadata. The actual message-to-attachment relation is therefore
not an ObjectBox foreign key supplied by CloudKit: it is reconstructed from the
message body and attachment GUID normalization.

Source: [chat schema](../rustpush/src/imessage/cloud_messages.rs#L231-L297),
[message schema](../rustpush/src/imessage/cloud_messages.rs#L314-L368),
and [attachment schema and metadata](../rustpush/src/imessage/cloud_messages.rs#L444-L475).
The existing local projection performs attachment-guid normalization before
persistence: [attachment mapping](../lib/database/io/attachment.dart#L57-L77).

**Action:** Define V2 keys explicitly: `serverRecordId` is the immutable
CloudKit-envelope key, `chatGuid`, `messageGuid`, and normalized
`attachmentGuid` are logical entity keys, and a link is valid only after both
logical entities exist. Retain a protected raw envelope and its schema version
for each mapping. Apply chat, message, and attachment records independently,
then resolve message attachment references from the canonical decoded message
body in the same idempotent local-apply transaction. Never infer a link from a
file path, filename, record arrival order, or a best-effort current chat.

### Fact: `p:` identifies an associated-message target, while `bp` is a
separate balloon-payload field

The CloudKit upload mapper serializes an associated-message target as
`p:<part>/<guid>`. Its download counterpart presently assigns the whole raw
value into `associatedMessageGuid`, while later local queries compare that field
to a bare local `Message.guid`. This is a real normalization mismatch. By
contrast, `bp` in the native incoming iMessage schema is `balloon_part` data,
with `bpdi` as its MMCS descriptor; it is fed into the extension/balloon parser,
not used as a reaction-parent identity.

Source: [CloudKit reaction serialization](../lib/database/io/message.dart#L1055-L1062),
[current direct assignment](../lib/database/io/message.dart#L1180-L1191),
[local parent lookup](../lib/database/io/message.dart#L1222-L1235), and
[raw `bp`/`bpdi` fields](../rustpush/src/imessage/rawmessages.rs#L388-L447) with
[balloon parsing](../rustpush/src/imessage/messages.rs#L3613-L3645).

**Action:** Parse `p:<part>/<guid>` into a typed parent reference
`{ parentGuid, parentPart, rawValue }` before any ObjectBox write, and persist a
durable unresolved-association row when the parent is not yet present. Parse
thread replies (`r:<part>:<guid>`) under a separate typed contract. Treat `bp`
and `bpdi` exclusively as extension payload material, not as aliases for a
reaction parent. The replay suite must cover parent-before-child,
child-before-parent, several reactions to one parent, reaction removal, sticker,
thread reply, edit, and unsend, all with duplicate delivery and restart between
the child apply and parent resolution.

### Fact: raw-page transport retains the information needed for replay, but
the legacy sync loop loses that safety boundary

The page API emits an ordered list rather than a map. Each entry includes the
opaque record name/type, optional system fields, the encoded encrypted record
for an upsert, or the original encoded change envelope for a tombstone. It
classifies malformed metadata and unsupported record types without decoding
them. The legacy loop instead converts received records to `HashMap`s, directly
deletes a locally mapped entity on a null value, and asks CloudKit to delete
prior record IDs when it sees a logical duplicate. The page fetcher itself uses
`newest_first: false`, while the older generic path requests `newest_first:
true`; neither order establishes a parent-before-child guarantee across streams.

Source: [replay-capable page shape and classification](../rustpush/src/imessage/cloud_messages.rs#L738-L883),
[page fetch path](../rustpush/src/imessage/cloud_messages.rs#L922-L946),
[legacy direct delete and duplicate-delete behavior](../lib/services/rustpush/rustpush_service.dart#L3176-L3445),
and [the two fetch-order settings](../rustpush/src/icloud/cloudkit.rs#L1312-L1322)
plus [legacy request](../rustpush/src/imessage/cloud_messages.rs#L963-L972).

**Action:** V2 must consume the ordered page envelope one event at a time and
first insert it into a durable inbox keyed by `(account, zone, serverRecordId,
serverVersion-or-envelopeDigest)`. In a single local transaction, apply an
eligible envelope, update record map/tombstone/deferred-parent rows, mark the
inbox row applied, and advance only that page's candidate token. A server
tombstone may hide a local item only after its record map resolves it; a missing
map is a durable `tombstoneMappingMissing` review/rebootstrap condition, not a
guess or deletion. A logical duplicate must be diagnosed as a mapping conflict,
not resolved by emitting an outbound delete during inbound replay.

### Fact: CloudKit continuation tokens are opaque, per-zone checkpoints and
can require a full reset

Apple documents a record-zone change token as an opaque point in that zone's
history, with `nil` meaning a fetch from the beginning; the platform also has a
`changeTokenExpired` error. Rustpush already recognizes its protocol's
`FullResetNeeded` result: the Find My client clears its token and materialized
state, then fetches again. The message-stream page API returns a next token and
completion status, but the existing iMessage sync loop persists tokens
independently in preferences, outside the record mutations it just performed.

Source: [Apple record-zone changes documentation](https://developer.apple.com/documentation/cloudkit/ckdatabase/recordzonechanges(inzonewith:since:desiredkeys:resultslimit:)),
[Apple change-token error documentation](https://developer.apple.com/documentation/cloudkit/ckerror/code/changetokenexpired),
[rustpush `FullResetNeeded` classifier](../rustpush/src/icloud/cloudkit.rs#L1530-L1537),
[existing safe-reset call site](../rustpush/src/findmy.rs#L1019-L1039), and
[legacy iMessage token writes](../lib/services/rustpush/rustpush_service.dart#L3250-L3457).

**Action:** Store a token with an explicit namespace of account identity hash,
private database, zone name, stream schema version, and rebootstrap generation.
Commit it only with the successful local inbox/apply state for that page. On a
recognized token-expired/full-reset response, atomically mark the zone
`rebootstrapRequired`, stop all workers for that zone, retain raw journal and
record-map evidence, invalidate the token, then refetch with `nil` into a new
generation. Reconcile that generation by stable logical identity and
server-version rules, not by clearing user-visible messages or files. Do not
reuse a message-zone token for chats or attachments, and do not inspect or sort
an opaque token.

### Fact: exactly-once is achievable only for the local apply, not for the
CloudKit fetch itself

The replay-safe inbox pattern persists an event before handling it and commits
the local effect together with its processed marker. This absorbs fetch retries
and process crashes, while external transport remains at-least-once. Reference
implementations also retain failed records for bounded retry and operator
requeue rather than silently dropping them.

Source: [transactional inbox/outbox reference](https://github.com/qwertyboy0325/handoff-semantics)
and [event-ID replay protection and local transaction boundary](https://github.com/inbox4j/inbox4j).

**Action:** State the production guarantee precisely: Cloud Sync V2 provides
at-least-once CloudKit fetch with exactly-once *local database projection* for a
retained inbox key. It cannot claim global exactly-once delivery or ordering
across Apple zones. Add fault tests for crash before inbox insert, after inbox
insert, after entity apply but before token commit, duplicate page, token reset,
older upsert after newer upsert, tombstone before upsert, and conflicting server
record IDs for the same logical GUID. Keep malformed, PCS-blocked, and mapping
conflict rows out of normal retry loops and visible in redacted diagnostics.

### Fact: a push or IDS event is a reconcile hint, never evidence that a
CloudKit checkpoint is current

Apple documents that CloudKit can coalesce notifications and prune their
payloads. A client must treat a notification as an indication that a remote
change might exist, then fetch from its saved change token. Rustpush's APNS
transport reconnects over TCP 5223 with TCP 443 fallback, while the message
CloudKit API separately fetches record pages from a continuation token. The
current tree contains generic CloudKit subscription machinery used by the
Passwords and keychain clients, but no equivalent subscription-creation call in
the Messages sync path. An incoming IDS message, APNS reconnect, or
network-change event therefore cannot prove that every message-zone change has
been received, nor authorize a token advance.

Source: [Apple Remote Records](https://developer.apple.com/documentation/cloudkit/remote-records),
[Apple CKQueryNotification](https://developer.apple.com/documentation/cloudkit/ckquerynotification),
[APNS transport ports](../rustpush/src/aps.rs#L1596-L1599),
[message page fetch](../rustpush/src/imessage/cloud_messages.rs#L922-L946), and
[non-Messages subscription call sites](../rustpush/src/passwords.rs#L1310-L1317).

**Action:** Create one durable, account-scoped `reconcileRequested` latch.
Foreground activation, network restoration, a native connection resume, an
inbound IDS event, and any validated CloudKit notification may set that latch,
but none may write a CloudKit token. A single per-account worker should debounce
and coalesce those hints, drain each zone until its page indicates completion,
then atomically commit its candidate token with the local projection. Keep a
bounded, jittered recovery poll only as a missed-hint safety net, with no
one-request-per-push behavior. Do not add or depend on subscriptions to Apple's
Messages container without explicit protocol and account-safety validation.

### Fact: name/photo sharing is a separate, two-stage public-CloudKit protocol,
not message-history replication

Apple states that a shared iMessage name/photo is an immutable encrypted public
CloudKit record with a new record ID and key whenever the sender changes their
profile. The record ID and key are carried in an encrypted iMessage payload; a
recipient then fetches, authenticates, and optionally adopts the profile.
OpenBubbles matches this separation: it attaches a profile only to eligible
one-to-one sends, deduplicates its download by CloudKit record key, and retries
transient profile failures independently so they cannot disrupt message
delivery.

Source: [Apple secure iMessage name and photo sharing](https://support.apple.com/guide/security/secure-imessage-name-and-photo-sharing-secea5f2e977/web),
[profile-send eligibility](../lib/services/rustpush/rustpush_service.dart#L3806-L3831),
and [independent profile retry and fetch](../lib/services/rustpush/rustpush_service.dart#L3842-L3972).

**Action:** Keep profile processing outside the message-history inbox. Persist a
separate `ProfileFetchJob` keyed by sender identity hash, CloudKit record ID,
and record-key version, with immutable provenance of `shared-profile`. It may
update a shared contact/avatar only after decrypt-and-authenticate success; it
must never silently overwrite a local My Card, manually selected avatar, or
conversation background. The release suite must distinguish no embedded profile
payload, public-record fetch failure, cryptographic validation failure, and
user-policy refusal. Test a normal message, an initial profile share, and a
changed profile which must arrive under a new record reference.

### Fact: account topology determines what a Cloud Sync test proves

Apple's Messages in iCloud guidance is scoped to devices using the same Apple
Account. A second account can validate peer send/receive, reactions, media, and
profile sharing, but cannot by itself prove that one account's history converges
across local OpenBubbles installations. Reusing a local state store while
changing accounts also risks mixing opaque tokens and record maps that belong to
different accounts.

Source: [Apple Messages in iCloud setup](https://support.apple.com/guide/icloud/set-up-messages-mm0de0d4528d/icloud)
and [opaque, segregated change-token guidance](https://developer.apple.com/documentation/cloudkit/ckserverchangetoken).

**Action:** Use a disposable test Apple Account A for three clean,
independently stored OpenBubbles profiles: Android, Windows x64, and Windows
ARM64. This is the replication cohort. Use a separate disposable Account B on
an Apple-native peer only to generate inbound/outbound traffic. Never switch an
existing local test profile in place: an account mismatch must quarantine its
tokens, journal, record map, and profile jobs, then require a new generation.
Record each test's sender, receiver, attachment SHA-256, operation type, and
timestamps so same-account convergence and cross-account transport failures are
not conflated.

### Fact: Android and Windows should coalesce recovery work around lifecycle
events, not keep the device artificially awake for metadata sync

Android documents WorkManager as persistent work that survives process death
and reboot, supports unique work, constraints, and retry/backoff. It also warns
that immediate execution is not guaranteed and recommends combining related
work to reduce device wakeups. The existing setup currently recommends disabling
battery optimization to preserve notifications. Windows App SDK lifecycle APIs
provide power and system-state notifications, including suspend and resume.

Source: [Android persistent task scheduling](https://developer.android.com/develop/background-work/background-tasks/persistent),
[Android battery optimization guidance](https://developer.android.com/develop/background-work/background-tasks/optimize-battery),
[Windows AppLifecycle sample](https://learn.microsoft.com/en-us/samples/microsoft/windowsappsdk-samples/applifecycle/),
[existing Android notification recommendation](../lib/app/layouts/setup/pages/setup_checks/battery_optimization.dart#L14-L22),
and [current network-change debounce](../lib/services/rustpush/rustpush_service.dart#L1555-L1595).

**Action:** On Android, use one unique, network-constrained V2 reconcile worker
for a hint or connectivity recovery, with bounded metadata work and documented
backoff. Keep attachment prefetch/materialization as separately constrained
work, such as unmetered or charging when it is not user-initiated. Do not claim
background immediate delivery, and do not require a permanent wake lock for
Cloud Sync metadata. On Windows, request a coalesced reconcile after a valid
resume or network restoration while the desktop app can run; persist the dirty
latch before suspend and accept that a sleeping PC cannot provide a live-sync
guarantee. Both clients must expose the reason, last completed zone/token
generation, retry class, and next eligible attempt in redacted diagnostics.

### Fact: the release gate must force every crash boundary and stale-state path

The current page interface can return a bounded ordered batch and a next token,
while the implementation has explicit token-reset recognition elsewhere. Those
properties permit deterministic fault injection without relying on an Apple
account failure to occur naturally. A correctness test that only sends messages
on a healthy network cannot detect a token committed ahead of its local
projection, stale-account reuse, or a duplicate-hint storm.

Source: [bounded page request and next-token result](../rustpush/src/icloud/cloudkit.rs#L1291-L1367),
[page-envelope classification](../rustpush/src/imessage/cloud_messages.rs#L738-L883),
and [existing reset detection](../rustpush/src/icloud/cloudkit.rs#L1530-L1537).

**Action:** Add a scripted fault matrix to the live gate: duplicate and
coalesced hints; offline before raw-inbox write; process kill after inbox write,
after projection, and before token commit; token-expired/full-reset response;
account identity change; malformed encrypted record; deferred reaction parent;
profile public-record missing or invalid; and interrupted attachment download.
For every case, require one of successful eventual convergence with one local
projection, durable quarantine with an actionable code, or explicit
rebootstrap-required state. The gate fails if any case silently drops a message,
advances a token without its local apply, reuses another account's state, or
keeps a high-frequency background wake loop alive.

### Fact: Flutter and Rust have native Windows ARM64 targets, but the current
application matrix is intentionally not a shippable ARM64 release

Flutter's Windows build output is architecture-specific (`build/windows/x64` or
`build/windows/arm64`). Rust officially supports both
`x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc`, and MSVC can
cross-compile between Windows architectures when the matching Visual Studio
components are installed. Cargokit already passes its selected Rust target to
Cargo and installs it through Rustup. The repository's CI correctly separates
x64 from ARM64, bootstraps an ARM64 Dart SDK/Flutter engine on a native ARM64
runner, and selects the matching Rust target. However, that ARM64 job is marked
experimental and exits before build because locked native dependencies are not
ARM64-compatible.

Source: [Flutter Windows build architecture](https://docs.flutter.dev/release/breaking-changes/windows-build-architecture),
[Rust Windows MSVC targets](https://doc.rust-lang.org/stable/rustc/platform-support/windows-msvc.html),
[Cargokit target invocation](../rust_builder/cargokit/build_tool/lib/src/builder.dart#L116-L156),
and [current CI architecture and block](../.github/workflows/windows-build.yml#L23-L109).

**Action:** Treat x64 as the only release-capable Windows architecture until
the ARM64 preflight passes. Keep independent `windows-x64` and `windows-arm64`
jobs on native runners, using `x86_64-pc-windows-msvc` and
`aarch64-pc-windows-msvc` respectively. Each job must emit an architecture
manifest for every PE in the final directory, including the runner, Flutter
engine, Rust bridge, ObjectBox, media DLLs, PDF renderer, WebView2 loader, and
plugin DLLs. Reject a bundle if any machine type differs from its declared
artifact architecture; do not use x64 emulation as evidence of an ARM64 release.

### Fact: CMake platform selection must follow the Visual Studio target, not
the host processor

For Visual Studio generators, CMake's `-A` option selects the target platform
and stores it in `CMAKE_GENERATOR_PLATFORM`. This repository already compensates
for an ARM64 host generating an x64 target by normalizing
`CMAKE_SYSTEM_PROCESSOR` to `AMD64`, because ObjectBox uses that value to select
its native archive. The explicit install rules also add the target-architecture
WebView2 loader and exclude a media package's debug-runtime DLLs. The existing
normalization is deliberately x64-only; ARM64 must retain its requested target
value so an ARM64-aware dependency chooses ARM64, rather than inheriting an
emulated process architecture.

Source: [CMake Visual Studio platform selection](https://cmake.org/cmake/help/latest/variable/CMAKE_GENERATOR_PLATFORM.html),
[repository architecture normalization and packaging](../windows/CMakeLists.txt#L1-L19),
and [WebView2/media install handling](../windows/CMakeLists.txt#L52-L76).

**Action:** Require each CI configure/build log to record
`CMAKE_GENERATOR_PLATFORM`, `CMAKE_VS_PLATFORM_NAME`,
`CMAKE_SYSTEM_PROCESSOR`, the Rust target triple, and the resulting PE machine
types. ARM64 enablement must use a clean build/cache directory, never a reused
x64 Flutter, CMake, Cargo, or dependency cache. Keep the current x64 override
only for a true x64 target on an ARM64 host, and add a targeted configure test
that fails if an ARM64 job resolves an x64 ObjectBox, WebView2, PDFium, libmpv,
ANGLE, or Rust bridge artifact.

### Fact: ObjectBox Windows ARM64 is now available upstream, but the locked
ObjectBox package in this repository still blocks it

The current CI records that `objectbox_flutter_libs 4.0.3` selects ObjectBox C
4.0.2 and that release has only x86/x64 Windows archives. Newer ObjectBox C
5.3.2 release assets include `objectbox-windows-arm64.zip`, and the current
ObjectBox Flutter Windows CMake source derives the archive from
`CMAKE_SYSTEM_PROCESSOR`. This removes one external blocker only after a
reviewed ObjectBox Flutter package upgrade; it does not prove that the current
lockfile, generated bindings, database migration behavior, or release bundle
will work unchanged.

Source: [current repository ARM64 block](../.github/workflows/windows-build.yml#L58-L79),
[ObjectBox C 5.3.2 Windows ARM64 asset](https://github.com/objectbox/objectbox-c/releases/tag/v5.3.2),
and [current ObjectBox Flutter Windows CMake](https://github.com/objectbox/objectbox-dart/blob/main/flutter_libs/windows/CMakeLists.txt).

**Action:** Split ObjectBox from the broad ARM64 effort. First upgrade it in a
dedicated, reviewable branch, regenerate only required bindings, and run the
existing ObjectBox/open-store/migration tests on both architectures. Inspect the
final `objectbox.dll` machine type and open a copied production-shaped database
on native ARM64 before removing only the ObjectBox blocker. Do not change the
application model or Cloud Sync V2 schema merely to achieve architecture parity.

### Fact: media and PDF native dependencies remain the higher-risk ARM64 gate

The repository's locked `media_kit_libs_windows_video` package selects an
x86_64 libmpv archive and x64 ANGLE bundle, while the locked `printing` package
hard-codes x64 PDFium. The CI stops for those reasons. Upstream media-kit work
shows an ARM64 libmpv/ANGLE path is being developed, but that work has had
upstream-binary and runtime-validation dependencies. Therefore an ARM64 media
compile, even if forced through CMake, cannot demonstrate safe video, audio,
GPU, or PDF behavior.

Source: [current CI dependency block](../.github/workflows/windows-build.yml#L66-L77),
[locked media/PDF dependencies](../pubspec.yaml#L118-L123),
[locked printing dependency](../pubspec.yaml#L132-L145), and
[media-kit ARM64 work status](https://github.com/media-kit/media-kit/pull/1381).

**Action:** Before enabling ARM64 packaging, require independently maintained,
pinned ARM64-capable replacements for libmpv, ANGLE, and PDFium. Verify their
license notices and checksums, then run native ARM64 smoke tests covering:
MP4/H.264 and HEVC playback, audio-only messages, paused/fullscreen swipe
transitions, thumbnail generation, a large image/PDF render, GPU fallback, and
app exit/relaunch. The test artifact may be labeled `arm64-preview` only after
all PE checks and those runtime tests pass; otherwise keep it absent rather than
publishing a package that can launch but fails on received media.

### Fact: the existing Windows CI produces hashable draft ZIPs, not a signed
Windows release package

The x64 workflow builds a release directory, compresses it, writes a SHA-256
sidecar, and uploads both as a GitHub Actions artifact. It does not sign the
executables/DLLs, create an MSIX, or produce provenance attestations. GitHub
artifact attestations can establish build provenance, but are distinct from
Windows publisher trust. Microsoft documents that an installable MSIX must be
signed; self-signed certificates are appropriate only where each test user
explicitly trusts the certificate, and the certificate subject must match the
package publisher.

Source: [current ZIP and SHA packaging](../.github/workflows/windows-build.yml#L221-L247),
[GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations),
and [Microsoft MSIX test signing](https://learn.microsoft.com/en-us/windows/msix/package/create-certificate-package-signing).

**Action:** Keep unsigned, SHA-256-checked ZIPs as restricted draft-test
artifacts only. For a public pre-release, create separate x64 and ARM64
packages from the verified bundle, attach the architecture manifest, test log,
SBOM/license inventory, SHA-256, and provenance attestation. Choose one
distribution path before public release: signed portable bundle/installer, or
signed MSIX with a publisher identity that matches the certificate. Sign the
final package and each executable native payload after staging, timestamp it,
and verify both signature and architecture in a clean Windows VM/native ARM64
machine. Never place a PFX, password, Apple credential, or self-signed trust
step in a public workflow or release artifact.

### Fact: the ObjectBox ARM64 unblock is a coordinated SDK, generator, and
runtime upgrade, not a one-line native-library substitution

The repository locks `objectbox`, `objectbox_flutter_libs`, and
`objectbox_generator` at 4.0.3, with an older `build_runner` resolution. The
current 5.3.2 Flutter runtime package requires Dart 3.7, and the matching
generator requires Dart 3.7, analyzer 8.1.1+, build 4+, and source_gen 4+.
ObjectBox's 5.0/5.1 release notes require regenerated code after an upgrade;
5.1 adds a required generated `GeneratorVersion` parameter, so retaining the
4.0.3 `objectbox.g.dart` produces a compile error. The x64 CI still uses
Flutter 3.24, which is below the Flutter 3.29/Dart 3.7 baseline documented by
ObjectBox for its newer packages.

Source: [locked package set](../pubspec.lock#L2276-L2299),
[current ObjectBox Flutter package constraints](https://pub.dev/packages/objectbox_flutter_libs/versions/5.3.2),
[ObjectBox 5.0-5.3 release notes](https://pub.dev/packages/objectbox/changelog),
and [current x64 Flutter CI version](../.github/workflows/windows-build.yml#L23-L40).

**Action:** Make this a dedicated dependency branch with exact, aligned
versions of `objectbox`, `objectbox_flutter_libs`, and `objectbox_generator`
at 5.3.2, rather than allowing one package to float. Raise the shared Dart and
Flutter toolchain to a validated Dart 3.7/Flutter 3.29-or-newer baseline before
resolving packages, and deliberately update the generator toolchain until
`build_runner`, `build`, `analyzer`, and `source_gen` satisfy ObjectBox 5.3.
Then run `dart run build_runner build`, review only the model/generator diff,
and fail CI if a subsequent generator run is not clean. Do not land the
ObjectBox package update mixed with unrelated Flutter upgrades or Cloud Sync
schema edits.

### Fact: the model JSON and generated bindings, not the Dart class names
alone, protect existing stores

ObjectBox persists entity/property IDs and UIDs in `lib/objectbox-model.json`,
then uses the generated model when opening a store. Adding/removing properties
is generally automatic, but renaming requires the preserved UID and changing a
persisted property type requires application-managed migration. The repository
has a version-controlled model with message, contact, attachment, and Cloud
Sync V2 journal entities; its generated file is currently emitted by the 4.0
generator and has no ObjectBox 5.1 `generatorVersion` argument. Its Cloud Sync
V2 state is ordinary local ObjectBox data, not ObjectBox Sync: there is no
`SyncClient` or ObjectBox Admin dependency in the application paths.

Source: [ObjectBox data-model update rules](https://docs.objectbox.io/advanced/data-model-updates),
[ObjectBox meta-model/UID rules](https://docs.objectbox.io/advanced/meta-model-ids-and-uids),
[current repository model](../lib/objectbox-model.json#L1625-L1633),
[current generated model definition](../lib/objectbox.g.dart#L1643-L1757), and
[Cloud Sync V2 entity source](../lib/database/io/cloud_sync_records.dart#L1-L11).

**Action:** Freeze `lib/objectbox-model.json` before the package upgrade and
compare entity names, IDs, UIDs, property IDs/UIDs, relation IDs, and retired
UID lists after generation. No entity/property rename or type change is in
scope for the ARM64 unblock. Add a schema-fixture test that opens a realistic
4.0.3-created store under 5.3.2 and verifies messages, chats, attachments,
contacts, and every Cloud Sync V2 journal/checkpoint/lease/outbox row before
and after a close/reopen. Treat any unexpected model-JSON semantic change as a
release blocker, not formatting noise.

### Fact: rollback must restore a closed-store snapshot, not assume that a
newer native runtime is backward-compatible

ObjectBox documents how a model mismatch can prevent a store from opening and
identifies reconstructing the UID model or deleting the database as its two
resolution paths. Deleting a published user's database loses data. The
documentation does not make a general promise that an older ObjectBox 4.0.3
runtime can reopen every store that a newer 5.3.2 runtime has written. This
application opens its live desktop store directly from the app documents path
and already copies an older custom-path store into that location, so an
in-place package replacement without a closed-store rollback artifact would be
unsafe.

Source: [ObjectBox meta-model conflict guidance](https://docs.objectbox.io/advanced/meta-model-ids-and-uids),
[ObjectBox troubleshooting](https://docs.objectbox.io/troubleshooting), and
[repository desktop-store open/copy path](../lib/database/database.dart#L135-L151).

**Action:** Before first production launch of the upgraded build, take a
verified cold copy of the entire ObjectBox directory only after the store is
closed, plus the matching app settings/database-version record. In validation,
run both directions on disposable copies: 4.0.3-created store -> 5.3.2 open,
mutate, close, then 4.0.3 reopen; and 5.3.2-created store -> 5.3.2 reopen. If
the first reverse-open is not explicitly validated, rollback means restoring
the cold snapshot with the prior application build, never downgrading against
the modified live store. Do not use a data-directory deletion as recovery for
an update failure.

### Fact: ObjectBox 5.3.2 supplies the Windows ARM64 archive, but its Flutter
CMake package does not pin that download's digest

ObjectBox C 5.3.2 publishes both `objectbox-windows-arm64.zip` and
`objectbox-windows-x64.zip`. The current Flutter package derives the archive
name from `CMAKE_SYSTEM_PROCESSOR`, maps `AMD64` to `x64`, links
`objectbox.dll`, and exports it as a bundled library. The upstream CMake
`FetchContent` declaration pins the release URL but contains no `URL_HASH`.
GitHub's release metadata provides SHA-256 digests: ARM64
`e32ea12aebd76f00bcf9def941a3c73b24d2cc2dcd0e79a033b49522a2b2c0fd` and
x64 `57d7db013bbb46efe415307c9f3baf7564bdc40818ee1f1c42046f4241403d63`.

Source: [ObjectBox 5.3.2 release assets](https://github.com/objectbox/objectbox-c/releases/tag/v5.3.2),
[ObjectBox Flutter Windows CMake](https://github.com/objectbox/objectbox-dart/blob/main/flutter_libs/windows/CMakeLists.txt),
and [repository platform normalization](../windows/CMakeLists.txt#L6-L11).

**Action:** In CI, independently download or inspect the resolved ObjectBox C
archive and verify the architecture-specific SHA-256 before CMake configures
the release. Record the archive name, digest, ObjectBox version, final
`objectbox.dll` SHA-256, and PE machine type in the per-architecture manifest.
Use fresh per-architecture FetchContent/CMake caches. The x64 target on an
ARM64 host may retain the existing `AMD64` normalization; the native ARM64
target must resolve `objectbox-windows-arm64.zip`. Do not accept an x64 DLL
loaded through emulation as an ARM64 validation.

### Fact: dual-architecture validation needs physical-store portability tests,
not only a build and unit-test pass

The repository already has focused ObjectBox Cloud Sync store tests that create
a store, exercise journal/checkpoint/outbox state, close it, and reopen it.
That demonstrates a useful test harness, but it currently runs only against
the active local native library and does not prove x64-to-ARM64 store
interoperability. The application itself relies on transactions, `Store.attach`,
and a persisted store containing user history, making an architecture-specific
corruption or model-open failure a release-critical defect.

Source: [existing ObjectBox Cloud Sync reopen tests](../test/services/cloud_sync/objectbox_cloud_sync_store_test.dart#L17-L45),
[existing attachment-state reopen test](../test/services/cloud_sync/cloud_attachment_materialization_store_test.dart#L32-L63),
and [production store initialization](../lib/database/database.dart#L112-L151).

**Action:** Build a disposable seed store with the 4.0.3 x64 baseline and
record stable counts/hashes for each core box and V2 Cloud Sync box. Validate
four clean-machine sequences: baseline x64 -> upgraded x64; baseline x64 ->
upgraded ARM64; upgraded ARM64 -> upgraded x64; and upgraded x64 -> upgraded
ARM64. In each sequence open, query, write one reversible fixture row, close,
reopen, then assert stable data plus all journal invariants. Run the same
smoke test through the packaged release directories, not just `flutter test`.
Remove the ObjectBox entry from the ARM64 CI block only after all four
sequences, PE/digest manifest checks, and a native ARM64 physical-device run
pass; leave PDF/media blockers in place independently.

### Fact: the local ARM64 branch's Flutter blocker is obsolete, but its
cross-compilation warning remains valid

Flutter's current stable `BuildWindowsCommand` selects `windows-arm64` when
the host platform is `HostPlatform.windows_arm64`, selects `windows-x64` on
other Windows hosts, and passes the resulting platform through to CMake as
both `-A ARM64`/`-A x64` and `FLUTTER_TARGET_PLATFORM`. The same behavior is
present in the verified 3.44.8 source. The Windows ARM64 umbrella records that
Flutter 3.44.0 stable began producing the ARM64 Dart SDK and Flutter engine
for every release; the issue remains open because its broader checklist still
includes cross-compilation and other follow-up work. The local
`agent/windows-arm64-native` guide instead says stock 3.44.8 cannot produce a
native ARM64 application. That statement conflicts with the current 3.44.8
tool source and must not remain a release decision input.

Source: [Flutter stable Windows build command](https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/commands/build_windows.dart),
[Flutter stable CMake target selection](https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/windows/build_windows.dart),
[Flutter ARM64 umbrella, current open state](https://github.com/flutter/flutter/issues/62597),
[Flutter 3.44.8 tag](https://github.com/flutter/flutter/tree/3.44.8), and
[stale local alpha guide](windows-arm64-alpha.md#blocker-flutter-windows-arm64-target).

**Action:** Replace the alpha guide's "blocker zero" assertion with a
host/target matrix: native Windows ARM64 host plus ARM64 Dart/engine builds
ARM64 by default; native x64 host builds x64 by default; x64-to-ARM64
cross-compilation is not a supported release path. Retain Flutter 3.44.8 as
the minimum native-ARM64 CI baseline, because 3.44.0 is the first stable
release with the required downloadable artifacts, but do not describe it as a
patched Flutter requirement. Re-run dependency resolution and a minimal
native ARM64 app build before treating the application-level dependency work
as the remaining blocker.

### Fact: `flutter build windows --target-platform windows-arm64` is not the
official stable command path

The current stable command exposes no Windows `--target-platform` argument;
its target is derived from the host architecture. Flutter issue #129808,
still open, explicitly proposes that option for cross-compilation and says it
should error on the beta and stable channels. A native ARM64 runner must
therefore execute plain `flutter build windows --release` after its ARM64 SDK
and engine have been selected. Passing a proposed flag, forcing an ARM64
CMake generator from an x64 Flutter tool, or interpreting an x64-emulated
build as an ARM64 artifact would create a false validation result.

Source: [Flutter stable build command](https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/commands/build_windows.dart),
[cross-compilation proposal #129808](https://github.com/flutter/flutter/issues/129808), and
[repository native ARM64 CI lane](../.github/workflows/windows-build.yml#L26-L92).

**Action:** Keep separate native `windows-2022` x64 and `windows-11-arm` ARM64
jobs. For each, use plain `flutter build windows --release`, retain the
post-build PE-machine manifest check, and publish neither job as the other
architecture. Close the ARM64 experimental gate only after the ARM64 job
finishes package resolution, release build, and native-device smoke tests;
do not wait for cross-compilation support that the product does not require.

### Fact: the existing cache refresh is an upstream-described artifact
selection workaround, not a local Flutter patch

The Windows Flutter SDK archive still starts with x64 Dart and engine
components. The ARM64 umbrella documents the same sequence used in this
repository: remove `bin/cache/engine-dart-sdk.stamp`, refresh Dart so it
downloads `windows_arm64`, then run `flutter precache --windows` and verify
the ARM64 engine. The repository currently forces
`subosito/flutter-action@v2` to install `architecture: x64` and then performs
that refresh manually. The action itself now declares `arm64` as a supported
SDK architecture and defaults its architecture input to the runner's
architecture. This makes the forced-x64/bootstrap combination a candidate
for removal, but third-party action behavior must be demonstrated on the
native GitHub runner before deleting the independent Dart/engine assertions.

Source: [Flutter ARM64 artifact instructions](https://github.com/flutter/flutter/issues/62597),
[repository forced-x64/bootstrap sequence](../.github/workflows/windows-build.yml#L60-L92), and
[flutter-action architecture input](https://github.com/subosito/flutter-action/blob/main/action.yaml).

**Action:** In a disposable ARM64 CI run, set the action architecture to
`arm64` (or omit it and verify its native-runner default), retain only the
read-only assertions that `dart --version` reports `windows_arm64` and that
`windows-arm64-release` exists, then run a clean minimal app build. If that
passes from an empty Flutter-action cache, remove the forced `architecture:
x64`, stamp deletion, and direct call to Flutter's internal update script.
Keep the architecture and engine-directory assertions permanently. If the
action does not supply the correct artifacts, restore the documented refresh
sequence and record that as a tool bootstrap constraint rather than a Flutter
source fork.

### Fact: the ARM64 branch's application changes are native-dependency work,
not Flutter-framework patches, and cannot be removed on framework support
alone

The ARM64 branch contains no Flutter engine/tool fork. It removes the
`printing` plugin's x64-only PDFium use and vendors an ARM64 media bundle;
its remaining ObjectBox path requires the coordinated 5.3.2 upgrade above.
Flutter's closed ARM64 plugin-linking report confirms that a clean Flutter app
builds natively and that failures from plugins carrying x64-only precompiled
libraries are expected, not a framework regression. Consequently, native
Flutter support resolves the stale framework blocker but does not make an
x64-only PDF, media, database, WebView, or other DLL loadable in an ARM64
process.

Source: [ARM64 branch commit/file delta](https://github.com/OpenBubbles/openbubbles-app/compare/main...agent/windows-arm64-native),
[local ARM64 media/PDF guide](windows-arm64-alpha.md), and
[Flutter native-plugin architecture report #186836](https://github.com/flutter/flutter/issues/186836).

**Action:** Preserve the printing removal, media PE-machine verification, and
ObjectBox upgrade plan until an upstream dependency release replaces each one
and a clean native ARM64 release package passes audio, video, PDF export, and
existing-store tests. Update the alpha guide to separate framework readiness
from dependency readiness: Flutter is now a host-build prerequisite that can
be validated in CI, while each native dependency remains an independently
testable release gate. Do not remove a dependency workaround merely because a
framework-level ARM64 build succeeds.

### Fact: ObjectBox publishes the Dart API, Flutter runtime package, generator,
and desktop C library as a matched release set

The repository currently resolves `objectbox`, `objectbox_flutter_libs`, and
`objectbox_generator` to 4.0.3. In that release, both the Flutter runtime
package and generator depend on `objectbox: 4.0.3` exactly. The corresponding
5.3.2 packages likewise require `objectbox: 5.3.2` exactly. ObjectBox's
getting-started guidance instructs Flutter users to add compatible package
versions together, and its 4.0.3 and 5.3.2 release notes each name the desktop
ObjectBox C version bundled for Flutter Windows/Linux and Dart Native apps.
This is a published release-coupling pattern, not a collection of independent
native artifacts.

Source: [current repository lockfile](../pubspec.lock#L2276-L2298),
[ObjectBox Dart 4.0.3 package definitions](https://github.com/objectbox/objectbox-dart/tree/v4.0.3),
[ObjectBox Dart 5.3.2 package definitions](https://github.com/objectbox/objectbox-dart/tree/v5.3.2),
[ObjectBox getting-started guidance](https://docs.objectbox.io/getting-started),
[ObjectBox Dart 4.0.3 release](https://github.com/objectbox/objectbox-dart/releases/tag/v4.0.3), and
[ObjectBox Dart 5.3.2 release](https://github.com/objectbox/objectbox-dart/releases/tag/v5.3.2).

**Action:** Treat `objectbox`, `objectbox_flutter_libs`, and
`objectbox_generator` as one versioned unit. Do not ship a manifest or local
native-artifact override that claims the 4.0.3 Dart/generator packages are a
supported counterpart of ObjectBox C 5.3.2 merely because it supplies the
needed ARM64 DLL.

### Fact: ObjectBox Dart 4.0.3 performs only a lower-bound native-library
check, so it will not by itself reject ObjectBox C 5.3.2

The 4.0.3 Dart binding loads `objectbox.dll` dynamically and accepts a native
library whose reported C API is at least 4.0.1 and whose core version is at
least `4.0.2-2024-10-15`; it has no upper-bound or exact-version comparison.
ObjectBox C's own header instructs dynamic-library consumers to verify that a
compatible version was linked through `obx_version()` or
`obx_version_is_at_least()`. Therefore, assuming the ARM64 DLL reports its
published 5.3.2 version, 4.0.3's startup guard is expected to accept it.

Source: [4.0.3 native loader and compatibility guard](https://github.com/objectbox/objectbox-dart/blob/v4.0.3/objectbox/lib/src/native/bindings/bindings.dart),
[ObjectBox C version-check contract](https://github.com/objectbox/objectbox-c/blob/v5.3.2/include/objectbox.h), and
[ObjectBox C 5.3.2 release](https://github.com/objectbox/objectbox-c/releases/tag/v5.3.2).

**Action:** Use the lower-bound result only as a diagnostic fact: it explains
why a 4.0.3/5.3.2 experiment may load rather than fail immediately. Add an
explicit startup diagnostic that records the loaded C API/core version and PE
machine type during any temporary experiment, but do not use a successful
load, smoke test, or absence of a guard failure as proof of production ABI or
store compatibility.

### Inference: loading is not a published guarantee that the 4.0.3 FFI binding
is production-safe with ObjectBox C 5.3.2

The 4.0.3 binding was generated from older ObjectBox C headers, while the
5.3.2 release updates C API headers and generated Dart FFI bindings. ObjectBox
has added explicit runtime/generator compatibility enforcement in the 5.x
series and repeatedly directs users to release-matched native dependencies
when the runtime changes. No official compatibility matrix or maintainer
statement found in this review guarantees every 4.0.3 Dart FFI call, callback,
observer, query stream, or on-disk behavior against ObjectBox C 5.3.2 across a
major version boundary. That absence does not prove an ABI break, but it makes
the mixed-major configuration unsupported for a production messaging store.

Source: [5.3.2 C-API/binding update commit](https://github.com/objectbox/objectbox-dart/commit/30936773c6f2a4ea6d11758f9564dd8dbe589ea5),
[ObjectBox 5.1 generator compatibility release note](https://github.com/objectbox/objectbox-dart/releases/tag/v5.1.0),
[maintainer guidance on matching runtime dependencies](https://github.com/objectbox/objectbox-dart/issues/690), and
[5.3.2 release pairing](https://github.com/objectbox/objectbox-dart/releases/tag/v5.3.2).

**Action:** Reject 4.0.3 Dart bindings plus ObjectBox C 5.3.2 as the release
baseline for both Windows architectures. It may remain an isolated,
non-production proof-of-load only if it uses a disposable database, contains
no Sync/Admin features, records exact native versions, and is never used to
mutate or validate an upgrade path for a user's live store.

### Fact: the 5.3.2 upgrade requires Dart 3.7 and generator regeneration, so
the current x64 and ARM64 toolchains must move together

`objectbox_flutter_libs` 5.3.2 and `objectbox_generator` 5.3.2 require Dart
`^3.7.0`; the generator also requires analyzer 8.1.1+, build 4+, and
source_gen 4.0.1+. ObjectBox 5.1 introduced a mandatory `GeneratorVersion`
argument specifically to enforce generated-code/runtime compatibility and
states that `dart run build_runner build` must be run after updating the
ObjectBox package. The repository's x64 workflow is pinned to Flutter 3.24.0,
whose release coincided with Dart 3.5, so it cannot satisfy the 5.3.2 Dart
floor. Flutter 3.44 includes Dart 3.12 and meets that floor, but an ARM64-only
toolchain upgrade would leave x64 package resolution and generated code out of
parity.

Source: [ObjectBox 5.3.2 Flutter runtime package](https://github.com/objectbox/objectbox-dart/blob/v5.3.2/flutter_libs/pubspec.yaml),
[ObjectBox 5.3.2 generator constraints](https://github.com/objectbox/objectbox-dart/blob/v5.3.2/generator/pubspec.yaml),
[ObjectBox 5.1 regeneration requirement](https://github.com/objectbox/objectbox-dart/releases/tag/v5.1.0),
[current x64/ARM64 CI matrix](../.github/workflows/windows-build.yml#L18-L40),
[Flutter 3.24/Dart 3.5 release context](https://docs.flutter.dev/release/archive-whats-new), and
[Flutter 3.44 release notes](https://docs.flutter.dev/release/release-notes/release-notes-3.44.0).

**Action:** Use one coordinated baseline for the production migration:
Flutter 3.44.8 on both Windows x64 and ARM64, with the exact ObjectBox 5.3.2
trio and a reviewed Dart/build-runner/analyzer/source_gen resolution. Regenerate
`objectbox.g.dart`, preserve the model JSON/UIDs, and run the existing-store
portability matrix before any release. This is a larger upgrade than a DLL
swap, but it is the safest route because it gives both architectures the same
toolchain, generated bindings, native API expectation, and supportable
rollback boundary.
