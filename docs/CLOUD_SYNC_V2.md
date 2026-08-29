---
type: architecture_plan
title: OpenBubbles Cloud Sync V2
description: Safety-first architecture for message reconciliation across Pixel Android, Windows ARM64, and Windows x64.
resource: openbubbles-app
tags: [android, pixel, windows, arm64, x64, cloudkit, sync, objectbox, rust, security]
timestamp: 2026-07-31
---

# OpenBubbles Cloud Sync V2

## Decision

Build one architecture-neutral Cloud Sync V2 engine for Android, Windows ARM64,
and Windows x64. Keep IDS as the live messaging path, ObjectBox as the local
source of truth, and Apple's private Messages CloudKit container as a delayed
reconciliation layer.

Do not enable new CloudKit writes until Windows secret storage, durable
checkpoints, and a read-only shadow-sync phase pass the gates in this document.
Do not automatically reset an iCloud Keychain clique or delete CloudKit zones.

## Why this boundary

The current implementation talks to Apple's private
`com.apple.messages.cloud` container. It does not use a supported public
CloudKit SDK or a documented third-party contract. It requires Apple
authentication, CloudKit tokens, iCloud Keychain clique membership, and PCS
keys. Apple can change the protocol or server policy without notice.

CloudKit is therefore useful for eventual reconciliation, but it is the wrong
place to put latency-sensitive message delivery. A CloudKit outage must never
delay IDS sends, incoming pushes, local persistence, or UI updates.

## Current implementation findings

| Finding | Evidence | Risk |
| --- | --- | --- |
| Private Apple Messages container | `rustpush/src/imessage/cloud_messages.rs`, container declaration | No supported compatibility guarantee |
| Three implemented zones | `chatManateeZone`, `messageManateeZone`, and `attachmentManateeZone` | Other Apple zones and features are not synchronized |
| SharedPreferences checkpoints | `chatSyncToken`, `messageSyncToken`, and `attachmentSyncToken` in `rustpush_service.dart` | Tokens are not account-scoped or transactionally coupled to applied data |
| Fixed retries | Three attempts with a constant five-second delay in `cloud_messages.rs` | Restarts and outages can cause retry bursts |
| Static desktop encryption key | `SoftwareEncryptor(*b"desktopisinsecureyoushouldn'tber")` in `rust/src/api/api.rs` | Apple secrets are not protected by the Windows user account |
| Daily/startup scheduling | Timers in `rustpush_service.dart` | Not real-time and not durable across crashes |
| Existing-GUID short circuit | Current pull logic updates limited CloudKit state for some existing messages | Reads, edits, retractions, and other mutable state can remain stale |
| Random server record IDs | Upload path and later logical-GUID deduplication | Two clients can race and create duplicate logical records |

The current uncommitted `cloud_message_upload_state.dart` logic is worth
preserving. It serializes operations and treats only explicit per-record success
as confirmation. Missing or failed response entries remain retryable.

### Uncommitted implementation snapshot (2026-08-01)

The current working tree now contains the Phase 0 foundation and a dormant
Phase 1 read-only path:

- Rust returns one ordered, bounded raw page for the chat, message, or
  attachment zone. It preserves tombstones and malformed or unsupported records
  for quarantine and applies request and response size limits. Dart additionally
  enforces a 32 MiB whole-page admission before the first protector call,
  including binary payloads, UTF-8 metadata, continuation token, and
  conservative object overhead. The uncommitted native path now preserves
  HTTP `Retry-After` and maps repeated continuation tokens to a typed,
  nonretryable no-progress failure. Those new bridge and rustpush tests still
  require a clean ARM64 and x64 native compile before the gate is closed.
- The V2 transport adapter exposes that page through generated Flutter Rust
  Bridge bindings and refuses every V2 write/delete operation. The wider
  generated API still contains legacy CloudKit mutation methods, so a live V2
  composition also needs an explicit write-call tripwire.
- A second, narrower protected-fetch bridge now keeps raw CloudKit record
  names, etags, tombstone payloads, encrypted envelopes, and continuation
  tokens in Rust. Its Dart transport receives only keyed digests, bounded safe
  scalars, fixed codes, `obcs2.ref.*` protected capabilities, and
  `obcs2.lease.*` adoption leases. It is generated and contract-tested but
  remains absent from runtime composition. Native protected-blob liveness and
  bounded garbage collection, concrete semantic decoding, platform reopen
  tests, and process-kill testing are required before it may replace the raw
  shadow transport.
- Dart converts each record into one authenticated protected envelope before
  journaling. Persisted record IDs, etags, change tags, and batch identifiers are
  hashed; raw account identifiers are limited to the native HMAC boundary.
- Cloud Sync journal values on Windows use current-user DPAPI plus a per-install
  HMAC secret. Android uses AES-256-GCM with a non-auth-bound Android Keystore
  key. Protection context includes account, container, database, zone, stream,
  schema, and purpose. The broader Windows Apple-keystore initialization still
  contains a legacy static software-encryption path and must be migrated before
  Windows live testing.
- A preflight-invalid record is journaled and quarantined without invoking the
  semantic decoder. A page that exceeds the entry, byte, age, or generation
  boundary is rejected atomically with no continuation-token movement.
- Automatic startup, network, IDS, and gap triggers remain disabled. Existing
  message tables and Apple's CloudKit container are not mutated by this path.
  Runtime disposal is idempotent and waits for active work to become quiescent
  before an account can replace its credentials.
- Incoming attachment materialization now has a durable, account- and
  generation-scoped state machine. It records only protected references and a
  contiguous native-verified byte boundary. A crash tail is truncated back to
  that boundary, an incomplete verified prefix restarts from zero, and a final
  file cannot be referenced until content verification and atomic placement
  have both completed.

Local validation re-measured on 2026-08-06 on a Windows-on-ARM host:

- 294 Cloud Sync Dart/ObjectBox tests pass on both the ARM64 and the x64 Dart
  test host, with a clean focused analyzer.
- 388 tests pass across the whole Dart suite.
- The standalone `cloud_sync_protector_harness` passes 39 tests on ARM64.
- 12 Alpha Kotlin/JUnit tests pass, including Kotlin compilation.
- `cargo check --locked --all-targets` is clean for
  `aarch64-pc-windows-msvc`, and release libraries build for
  `aarch64-pc-windows-msvc`, `x86_64-pc-windows-msvc`, and
  `aarch64-linux-android` with the expected PE and ELF machine types.

`cargo test` on the main crate is currently blocked by this host's Smart App
Control policy rather than by the repository; see
[Windows host build environment](WINDOWS_HOST_BUILD_ENVIRONMENT.md).

This is still not live CloudKit, native semantic-decoder, crash-injection, or
physical-device validation. The native bridge must also compile after every
binding regeneration before any app build is considered installable.

## Architecture

```text
IDS receive/send
      |
      v
Semantic message upsert  <----  Cloud inbox apply
      |                            ^
      v                            |
ObjectBox source of truth     Cloud fetch journal
      |
      +---- local mutation ----> Cloud outbox
                                  |
                                  v
                         Rust Apple transport/crypto
```

The same semantic upsert pipeline must process IDS events and CloudKit changes.
This prevents the two transports from implementing different merge behavior.

Suggested Dart module:

```text
lib/services/rustpush/cloud_sync/
  cloud_sync_engine.dart
  cloud_sync_store.dart
  cloud_merge_policy.dart
  cloud_sync_scheduler.dart
  cloud_sync_observability.dart
```

Rust should retain Apple protocol, authentication, PCS, and cryptography work.
The existing `rustpush_service.dart` should become a thin facade rather than
owning sync transactions and retry policy.

## Durable records

Use ObjectBox records rather than SharedPreferences for Cloud Sync V2 state.

### `CloudSyncCheckpoint`

- Account fingerprint, never a raw DSID
- Container, database, zone, typed stream, and schema version
- Fetched server token
- Last completed apply position
- Last successful run and last error category

Every inbox, outbox, record-map, lease, and run row stores the same hashed
scope key. Querying by account plus zone alone is forbidden because a zone name
can be reused across containers, databases, streams, or schema generations.

### `CloudInboxChange`

- Account fingerprint and zone
- Server record ID hash and etag
- Change type
- Original PCS ciphertext or an encrypted local reference. Do not duplicate
  decrypted message content in the sync journal.
- Fetch sequence
- `pending`, `applied`, or `quarantined` status. Quarantine is retained as a
  nonterminal barrier; only an applied row advances the contiguous position.
- Typed failure category and retry count

### `CloudOutboxOperation`

- Stable local operation ID
- Logical entity key
- Save or delete action
- Dependency operation IDs
- Payload version
- Durable, monotonically increasing local mutation revision. Wall-clock time
  and operation-ID lexical order must not decide which save is newer.
- Attempt count and next eligible time
- Last typed error
- Explicit server confirmation state

### `CloudRecordMap`

- Logical application key
- Apple record ID
- Last-known etag and server metadata
- Last-known encrypted raw record reference

### `CloudSyncRun`

- Trigger and architecture
- Fetched, applied, read-only tombstone acknowledgement, quarantined,
  confirmed, and retried counts
- Redacted timing and failure categories
- Start and finish timestamps

### `CloudAttachmentMaterialization`

- Complete account scope, generation, and keyed logical attachment identity
- Expected byte count and a keyed digest of the native MMCS integrity tag
- Monotonic stage: metadata, streaming, verified, placed, then referenced
- Contiguous native-verified byte count
- Protected temporary-file, resume-manifest, verification, and final-file
  references, never raw paths or MMCS credentials
- Last update timestamp

Creation and every transition use an ObjectBox transaction. Updates are
compare-and-swap operations over the complete expected state so a stale
process, isolate, or resumed worker cannot regress a verified boundary. Network
I/O, hashing, decryption, truncation, and atomic file placement remain outside
the ObjectBox transaction.

## Pull transaction

1. Fetch records with record ID, etag, type, server metadata, and next token.
2. Persist the inbox batch and fetched-token candidate in one ObjectBox
   transaction; keep the candidate pending until every row is applied.
3. Apply inbox entries separately through the shared semantic upsert pipeline.
4. Mark each entry `applied` only after its local mutation commits. A disabled
   tombstone is acknowledged as applied without decoding, deleting, or opening
   a semantic transaction; its protected row remains as evidence.
5. Quarantine malformed, undecryptable, or otherwise failed records. Never
   silently drop them. A quarantined row remains a nonterminal barrier.
6. Advance the applied position and promote the pending token only through a
   contiguous range of rows persisted as `applied`.

This makes a crash recoverable without replaying the entire zone. A malformed
or otherwise failed record remains blocking until an explicit reviewed recovery
path changes its durable disposition, so the engine cannot silently skip it.

### Read-only shadow journal budget

Phase 1 currently contains a dormant runtime and scheduler foundation designed
for a future manual sampler. It has no production composition or invocation
path yet. Startup, network-reconnect, IDS-reconnect, and detected-gap callbacks
do nothing unless a later rollout explicitly enables automatic triggers.
Read-only fetch, semantic apply, saves, deletes, profiles, and notification
hints remain independently gated. In this phase, read-only fetch is the only
permitted capability; the shadow runtime rejects every engine with read-only
fetch disabled or with a mutation, profile, or notification gate enabled.

Pending shadow rows have deterministic limits per complete account scope:

- 4,096 pending entries
- 32 MiB conservative journal-row estimate
- Seven days from the oldest pending entry

These are client safety limits, not Apple quotas and not estimates of attachment
payload size or the complete ObjectBox file. Byte accounting uses fixed row and
index overhead plus UTF-8 lengths of protected references and redacted hashes.
It never inspects or logs decrypted message content.

Admission is all-or-nothing with the continuation token. Exact entry and byte
boundaries are accepted. A page that would cross either boundary is rejected
without persisting any row or advancing the token. Once the current journal is
at a limit or older than the age limit, the engine blocks before another
network fetch where possible. Diagnostics expose only retained entry count,
estimated bytes, rejected entry count, and the typed reason `maximumAge`,
`maximumEntries`, or `maximumEstimatedBytes`.

The policy never deletes inbox data. Existing databases created before the
budget are measured in place on first use; an over-budget database becomes
blocked while its rows and checkpoint remain unchanged. Pending records remain
correctness-relevant until a separately reviewed migration explicitly marks
them as disposable shadow samples or replays the zone from a safe checkpoint.
Do not enable semantic apply by silently pruning them.

## Outbox transaction

1. Queue a CloudKit operation in the same ObjectBox transaction as its local
   mutation.
2. Coalesce repeated saves for the same logical entity.
3. Let a confirmed delete supersede an unconfirmed save only after tombstone
   support passes its dedicated safety gate.
4. Pull before pushing after startup, reconnect, or a detected IDS gap.
5. Upload attachment records before their owning message record.
6. Clear an operation only after explicit per-record confirmation.
7. Persist typed retry state across process restarts.

IDS delivery state and CloudKit backup state must remain separate. A message can
be delivered through IDS while its CloudKit copy is still pending.

## Merge policy

Stable logical keys:

- Message: Apple message GUID
- Reaction: reaction GUID plus parent GUID
- Attachment: attachment GUID plus owning message GUID
- Chat: Apple group or chat identifier, with a participant-set fallback

Rules:

- Immutable content: first valid canonical event wins. Conflicting content is
  quarantined for diagnosis.
- Read and delivery timestamps: monotonic maximum.
- Reactions without a parent: defer until the parent exists.
- Edits: union message parts by Apple edit metadata.
- Retractions: win only when newer or represented by Apple's canonical state.
- Group metadata: higher group version wins.
- Equal group versions: retain the last-known server base and log the conflict.
- Mark-unread: local only until Apple's server representation is verified.
- Unknown fields: retain the last-known raw record and etag.

## Scope

### Supported after validation

- iMessage chats and messages
- Read and delivery metadata
- Reactions
- Edit summaries and retractions
- Attachment metadata and encrypted assets
- Group photos
- Explicitly shared profile records when the pointer and decryption key are
  already known

### Not provided by this design

- SMS or RCS synchronization
- Windows or Android contact synchronization
- General iCloud Contacts synchronization
- Reliable discovery of an existing iPhone profile on a fresh Windows device
- Conversation wallpaper or call-background parity
- Custom records inside Apple's Messages container
- Scheduled-message or recoverable-delete zones

Profile sharing uses separate Apple records and encryption material. It should
be a later opt-in module, not a dependency of message reconciliation.

## Security gate

Cloud Sync V2 writes are blocked until all items below pass:

- Replace the static desktop key with Windows DPAPI or Credential Manager.
- Preserve protected state across ARM64 and x64 upgrades for the same Windows
  user and application identity.
- Protect Apple tokens, PCS material, keychain state, and profile keys.
- Hash account identifiers before writing journals or diagnostics.
- Redact message content, handles, DSIDs, tokens, keys, and raw server IDs.
- Require an explicit user action for any clique or zone reset.
- Prove that an account switch cannot reuse another account's checkpoints,
  inbox, outbox, or record map.
- Coordinate Android's foreground and background Flutter engines with the same
  durable database lease. A process-local Dart lock is not sufficient.

### Windows secret-storage design

Protect one randomly generated 256-bit master key with current-user Windows
DPAPI, then continue using the existing `SoftwareEncryptor` AES-GCM path for
normal keystore operations. DPAPI runs only during initialization, so signing,
IDS, CloudKit, and message processing do not gain per-operation IPC or
cryptography overhead.

Use the official Windows Rust bindings for:

- `CryptProtectData`
- `CryptUnprotectData`
- `CRYPTPROTECT_UI_FORBIDDEN`
- `DATA_BLOB`
- `LocalFree`
- `FlushFileBuffers`
- `ReplaceFileW` with flags set to zero

The repository lockfiles already contain `windows-sys` 0.59.0 and its ARM64
MSVC target. Use current-user scope. Do not use machine scope or optional
entropy, since either can break ARM64/x64 access for the same Windows user.

Version the persisted software-keystore format:

```text
format_version = 2
protected_master_key = <current-user DPAPI blob>
keys = <existing map encrypted by the random master>
secrets = <existing map encrypted by the random master>
```

Migration must:

1. Acquire an exclusive profile lock.
2. Strictly parse the existing file. Existing corruption must never become an
   empty default keystore.
3. Authenticate and decrypt every legacy entry in memory.
4. Re-encrypt all entries with the random master.
5. DPAPI-protect a complete recovery copy of the original legacy file.
6. Write a same-directory temporary V2 file and flush its file handle.
7. Reopen it, unlock the master, and verify every entry.
8. Atomically replace the original with `ReplaceFileW`, using a backup path and
   flags set to zero. Microsoft documents `REPLACEFILE_WRITE_THROUGH` as
   unsupported.
9. Reopen and verify the installed file before global initialization.

The old static key may exist only in an isolated legacy decoder. It must never
encrypt new or migrated state. If DPAPI cannot unlock a V2 master, fail closed
with a typed error. Do not fall back to the legacy key, create an empty
keystore, or reset the account.

Before migration ships, harden AES-GCM parsing so truncated nonces, invalid
tags, and unauthenticated data return typed errors rather than panicking. Make
all later writes atomic, return an error on duplicate global initialization,
correct the existing AES key-type label, and remove private-key material from
logs.

Ship DPAPI-capable x64 and ARM64 builds together. A pre-migration executable
cannot read V2 state. Validate x64 to ARM64 to x64 read/write compatibility
against a synthetic copied profile before touching a live profile.

### Android secret-storage and worker design

Use the existing Android Keystore integration to protect a random application
master key with a non-biometric AES-GCM key. The protected key must remain
available to the existing background APNs Flutter engine while the phone is
locked. Do not store the raw master, CloudKit tokens, Apple record IDs, or PCS
material in SharedPreferences.

The foreground app and background APNs service can run in separate Flutter
engines. They must coordinate through the ObjectBox coordinator lease and
outbox leases, not a process-local Dart mutex. Every lease acquisition,
renewal, release, and expired-lease recovery must be a short transaction.
Network work and Apple cryptography happen outside ObjectBox transactions.

An Android account switch must create a new account-scoped checkpoint, journal,
outbox, record map, and lease namespace. Old encrypted state is retained for
explicit recovery or deletion, but it is never automatically opened under the
new account.

### Platform and architecture parity

Android, Windows ARM64, and Windows x64 must use the same:

- Dart and Rust sync source
- ObjectBox schema and migration hashes
- CloudKit fixtures
- Merge tests
- Feature flags
- Application identity and protected-state migration contract

Only platform adapters, compiled native binaries, and packaging should differ.
Windows CI must inspect the PE architecture of the executable, Rust library,
ObjectBox library, media libraries, and TLS dependencies. Android CI must
inspect the APK or app bundle for the expected `arm64-v8a` Rust and ObjectBox
libraries.

Use a cross-process single-instance lock before opening the database. An ARM64
and x64 process must never open the same ObjectBox store concurrently.

### Windows shared-profile process boundary

Windows shared-profile support requires the official OpenBubbles runner. The
runner atomically creates or opens its named mutex before it creates the window
or initializes Flutter, keeps the first-instance handle alive until shutdown,
and makes later official launches forward their app link and exit without
opening the ObjectBox profile.

Opening the same profile from a custom runner, a second Windows session, a test
harness, or simultaneous x64 and ARM64 processes is unsupported. Those
processes do not inherit this invariant and can corrupt or race the shared
store. Release validation must keep the runner source-contract test green and
must never use a shared profile for parallel architecture testing.

## Scheduler and retry policy

Triggers:

- Startup
- Network reconnection
- Local outbox activity
- IDS reconnect or detected event gap
- Manual synchronization
- Optional Apple notification hint after read-only validation

Policy:

- One active coordinator per account and database.
- Debounce bursts of local mutations.
- Preserve the existing maximum batch size of 256 records.
- Use exponential backoff with full jitter for network, throttling, and server
  errors.
- Honor `Retry-After` when present.
- Refresh authentication once after an authorization failure.
- Pause cleanly when clique or PCS access is unavailable.
- Persist backoff so restarting cannot create a retry storm.

Apple does not publish dependable limits for this private service. These values
are conservative client policy, not claimed Apple quotas.

## Rollout

### Phase 0: protocol and security baseline

- Replace static-key secret storage.
- Define typed Rust errors and response envelopes.
- Return record IDs, etags, server metadata, and per-record outcomes.
- Freeze the exact ObjectBox schema, IDs, indexes, uniqueness rules, and
  forward/rollback migration invariants before transport code depends on it.
- Create sanitized fixtures for chat, message, attachment, reaction, edit,
  retraction, missing-key, and corrupt-record cases.

Exit gate: no secret leaves DPAPI-protected storage, and ARM64/x64 fixture
outputs are identical after normalization.

### Phase 1: read-only durable shadow sync

- Add ObjectBox checkpoint, inbox, map, and run records.
- Fetch without mutating existing message tables.
- Compare normalized CloudKit records with current local state.
- Quarantine failures and expose redacted diagnostics.
- Keep automatic triggers dormant and enforce per-scope entry, estimated-byte,
  and age admission limits without deleting pending data.

Exit gate: repeated runs lose no records, leak no account state, and resume
correctly after crash injection. Boundary rejection and a keystore failure must
leave both the inbox and continuation token unchanged.

### Phase 2: semantic pull

- Apply chats, messages, reactions, read state, and attachment metadata through
  the shared upsert path.
- Keep writes and deletions disabled.

Exit gate: deterministic results across replay, process restart, ARM64, and x64.

### Phase 3: durable saves

- Add the durable outbox.
- Require explicit per-record confirmation.
- Keep deletions disabled.

Exit gate: a failed, partial, or missing server response cannot suppress retry
or lose the local operation.

### Phase 4: mutable conflicts and guarded tombstones

- Add edits, retractions, group changes, and conflict tests.
- Enable deletion only behind a separate opt-in flag.

Exit gate: two-device races, offline changes, and repeated replay produce one
logical result without destructive resets.

### Phase 5: profile and notification experiments

- Add group photos and explicit shared profiles.
- Evaluate notification hints only as a scheduler optimization.

Exit gate: feature failure cannot block messaging, startup, or core sync.

## Feature flags and rollback

Use independent flags for:

- Read-only fetch
- Semantic apply
- Saves
- Deletions
- Profiles
- Notification hints

Rollback disables network writes while retaining checkpoints, quarantined
records, and pending outbox operations. Never repair a failed rollout by
silently clearing the clique, deleting Apple zones, or discarding the local
database.

## Validation matrix

- Crash before and after every inbox/checkpoint transaction
- Exact-limit, one-over-limit, stale-journal, pre-budget migration, and
  checkpoint-protection fault cases
- Duplicate-record and cross-device race
- Existing-message semantic update
- Reaction before parent
- Edit, unsend, delivery, and read-state conflicts
- Attachment dependency, partial response, and bounded-memory behavior
- Interrupted attachment download before and after each verified chunk,
  corrupt tail truncation, manifest reauthorization, content-integrity failure,
  atomic placement, and restart after every materialization stage
- Authorization failure, throttling, server failure, and disk full
- Account switch and application-architecture switch
- Corrupt record and missing PCS key with no Rust panic
- Identical normalized output on Pixel Android, Windows ARM64, and Windows x64
- Android foreground and background-engine contention, process death, and
  expired-lease recovery
- Two Windows devices plus an iPhone, including offline sends, media, group
  changes, process restart, and network changes

Acceptance requires:

- Zero lost logical message GUIDs
- Zero duplicate logical messages after replay
- No account-token bleed
- Durable retry across restarts
- Bounded attachment memory
- No automatic destructive reset
- No CloudKit failure delaying IDS messaging

## Estimate and priority

A trustworthy beta is approximately two to four weeks:

- Security and durable foundation: four to seven engineering days
- Safe pull and cross-architecture parity: four to seven days
- Uploads, conflicts, and attachment reliability: five to ten days
- Profiles, notification experiments, and multi-device soak: one to two
  additional calendar weeks

The highest-value contribution is Phase 0 followed by read-only Phase 1.
Profile bootstrap and conversation backgrounds should wait. They are
higher-risk and deliver less user value than proving that messages cannot be
lost, duplicated, or exposed.
