---
type: validation_plan
title: OpenBubbles Cloud Sync V2 Live Validation
description: Safety-gated two-account validation runbook for Pixel Android, Windows ARM64, Windows x64, and a Mac truth source.
resource: openbubbles-app
tags: [android, pixel, windows, arm64, x64, cloudkit, sync, testing, security]
timestamp: 2026-08-01
---

# OpenBubbles Cloud Sync V2 live validation

## Current readiness

The offline foundation is testable, but this checkout is **not ready for a live
CloudKit fetch**. Cloud Sync V2 has no production composition path, manual
trigger, fail-closed preflight, or redacted diagnostic export. The existing
`Messages in iCloud (BETA)` setting invokes the legacy sync engine and must
remain off throughout V2 Phase 1.

This document is the gated execution plan after those blockers are closed. It
must not be interpreted as evidence that a live shadow run is currently
available.

Offline evidence on 2026-08-01: 85 focused Dart/ObjectBox tests passed, the
focused Flutter analyzer was clean, and 16 protector tests passed on
`aarch64-pc-windows-msvc`. The protector harness also compiled for
`x86_64-pc-windows-msvc`, with non-fatal missing-PDB linker warnings; its test
executable was not run. The new rustpush/bridge error-semantics tests, packaged
ABIs, live CloudKit, and devices remain unvalidated.

### Blockers to the first live fetch

| Priority | Blocker | State | Required closure |
| --- | --- | --- | --- |
| 1 | No production V2 composition or invocation path | Implemented offline, live run open | The developer-only manual sampler and its gated troubleshoot-panel entry point exist and are unit-tested; `tooling\cloud_sync\verify_foundation.ps1` asserts the composition symbols and passes. Its fail-closed preflight has not been exercised against live CloudKit |
| 2 | Windows production protection still has a legacy static software-encryption path | Open | Integrate the tested per-install protected-secret migration and make corruption fail closed |
| 3 | Native retry and protocol failures lost important semantics at the Dart boundary | Implemented; ARM64 compile closed, test run blocked by host policy | `cargo check --locked --all-targets` is clean for `aarch64-pc-windows-msvc` and the standalone protector harness passes 39 tests there. `cargo test` on the main crate is blocked by this host's Smart App Control policy, not by the code; see [Windows host build environment](WINDOWS_HOST_BUILD_ENVIRONMENT.md) |
| 4 | Runtime disposal could return while old-account work was active | Implemented offline | Keep the idempotent cancel-and-quiesce barrier and account-switch regression tests green |
| 5 | Raw response bytes were not capped before per-record protection | Implemented offline | Keep the 32 MiB total page admission and its binary, UTF-8 metadata, fixed-overhead, exact-limit, and pre-protection rejection tests green |
| 6 | Native execution covers ARM64 only; x64 is compile-only | Partially closed | Release libraries now build for `aarch64-pc-windows-msvc`, `x86_64-pc-windows-msvc`, and `aarch64-linux-android` with verified PE/ELF machine types, and the Cloud Sync Dart suite passes on both the ARM64 and x64 Dart test hosts. Still open: execute the x64 harness without triggering Windows Application Control, and inspect the native ABIs inside a packaged Windows bundle |
| 7 | Current per-install fingerprints cannot prove the same event crossed clients | Open | Add ephemeral test-run event HMACs and explicit `ids` versus `cloud` provenance |
| 8 | Production FRB facades used dynamic calls that unit-test fakes could not type-check | Implemented offline | Keep the typed `RustLibApi` raw-fetch/protect/unprotect/fingerprint facades and post-generation analysis green |

## Decision

Use a separate, Mac-activated Apple Account as the Cloud Sync V2 test account.
Keep the user's real account as a message counterparty and do not enable
experimental CloudKit writes against it.

A different account is useful for producing IDS traffic, but it does not by
itself prove CloudKit reconciliation. The same test account must run on at
least two isolated clients, initially Pixel beta and one isolated Windows
profile. The Mac signed into that test account is the Apple-side truth source.
Even then, a message appearing on both clients is not proof of Cloud Sync:
both clients may have independently received the same IDS push. A passing
semantic-sync test requires explicit `source=cloud` provenance.

## Non-negotiable guardrails

- IDS remains the live send and receive path. CloudKit failure must not delay
  delivery, local persistence, notifications, or UI updates.
- The first live phase is manual, read-only shadow sync.
- Keep the existing `Messages in iCloud (BETA)` switch off. It is the legacy
  mutating engine, not the V2 shadow sampler.
- Required flags are:
  - `readOnlyFetch: true`
  - `semanticApply: false`
  - `saves: false`
  - `deletions: false`
  - `profiles: false`
  - `notificationHints: false`
  - `automaticTriggersEnabled: false`
- Never automatically reset an iCloud Keychain clique, delete a CloudKit zone,
  clear a token after an unknown failure, or discard a pending shadow journal.
- Never copy a database, checkpoint, protected install secret, or Apple account
  state between Account A and Account B.
- Never run Windows ARM64 and Windows x64 processes against the same ObjectBox
  profile concurrently.
- Do not place Apple credentials, device passcodes, handles, message content,
  DSIDs, tokens, PCS keys, or raw server record IDs in test notes or logs.

## Test topology

| Role | Account | Client | Purpose |
| --- | --- | --- | --- |
| Counterparty | Account A, real | Existing Pixel OpenBubbles alpha or Apple client | Sends and receives controlled synthetic messages only |
| System under test | Account B, test | Pixel OpenBubbles beta | IDS baseline and Cloud Sync V2 shadow client |
| System under test | Account B, test | Isolated Windows profile | Same-account cross-client reconciliation |
| Truth source | Account B, test | Mac with Messages in iCloud | Confirms Apple-visible message and mutation state |
| Architecture parity | Account B, test | Windows ARM64 then x64, sequentially | Confirms identical normalized output and protected-state compatibility |

Use a separate Windows user profile for Account B during the first live test.
That is a stronger isolation boundary than changing environment variables or
renaming an executable. Architecture-switch testing can later use a synthetic
copied profile, followed by a backed-up Account B profile, but never Account A
first.

The current Gradle flavors use distinct Android package IDs:

- Alpha: `com.bluebubbles.messaging.alpha`
- Beta: `com.bluebubbles.messaging.beta`

Verify each built APK's package, signature, UID, native ABI, and private data
directory before installing it. Set up Beta fresh for Account B and never
restore Alpha's backup into it. If that isolation cannot be proven on the
actual artifacts, use a second Android device rather than an app-cloning tool.

## Readiness gates

### Gate 0: offline foundation

- All focused Dart Cloud Sync tests pass, including ObjectBox durability tests.
- Focused analyzer reports no issues.
- Native protector harness passes on Windows ARM64 and x64.
- Windows production composition uses protected per-install key material rather
  than the legacy static desktop software-encryption key.
- Native `Retry-After` reaches Dart and is durably honored across restarts.
- Repeated continuation tokens produce a typed, bounded no-progress failure,
  not a generic local-storage error.
- Generated Flutter Rust Bridge bindings expose the bounded raw-page fetch and
  protection calls.
- APK and Windows packages contain the correct native architecture libraries.
- Read-only shadow runtime rejects every non-shadow feature configuration.
- A raw-page byte cap is enforced before protection or persistence.
- A dedicated developer-only V2 shadow sampler passes its fail-closed
  preflight. It is not wired to the legacy Cloud Sync setting.

### Gate 1: account and storage isolation

- Account B has its own Android app data and Windows profile.
- Account fingerprints differ without logging either raw identifier.
- Each checkpoint is scoped by account fingerprint, container, database, zone,
  stream, and schema version.
- Switching accounts cannot open the previous account's checkpoint, inbox,
  outbox, record map, lease, or protected values.

### Gate 2: IDS baseline

With Cloud Sync V2 dormant, Account A and Account B exchange controlled text
and media in both directions. Capture delivery latency and confirm that no
message is missing or duplicated. Do not proceed if IDS is already unreliable.

### Gate 3: read-only shadow

Run one manual shadow pass on Account B. It may fetch and journal encrypted raw
changes, checkpoints, and redacted run metadata. It must not:

- change the existing message, chat, or attachment tables;
- save or delete any Apple record;
- reset a trust relationship or CloudKit zone;
- download full attachment bodies;
- schedule a second run automatically.

Run the same manual pass again. The second pass must be bounded and
deterministic, with no duplicate logical changes and no token regression.

### Gate 4: same-account cross-client reconciliation

Keep the Windows Account B client offline. Generate controlled events between
Accounts A and B, then reconnect Windows and run one manual shadow pass.
Phase 1 intentionally journals protected raw records and does not yet decode
message, reaction, edit, retraction, or read-state semantics. Compare only
bounded transport and journal evidence at this gate. Raw encrypted bytes and
platform-specific protection envelopes may differ.

Before cross-client comparison, add an ephemeral test-run HMAC key used only to
derive comparable event fingerprints from stable Apple record identity. The
current per-install account fingerprint cannot correlate Pixel and Windows
events. Never export the raw record identity or HMAC key.

Semantic comparisons move to Phase 2. For those tests, add a developer-only,
auto-expiring **cloud-only destination mode** on Account B that pauses semantic
IDS ingestion while leaving manual V2 fetch available. Sends remain disabled.
Without explicit `source=cloud` provenance, visibility on two clients is only
an IDS test and must not be reported as Cloud Sync proof.

### Gate 5: outbound canary

CloudKit saves remain disabled until the read-only gates pass and outbound
write activation receives a separate review. When approved, enable writes only
for Account B and progress in this order:

1. one text message;
2. one reaction;
3. one edit;
4. one retraction;
5. one small image;
6. one larger video.

CloudKit deletions remain separately disabled.

## Controlled test matrix

Use markers such as `OB-CS2-T01-<UTC>-<random>` so evidence can be correlated
without storing personal conversation content.

| ID | Event | Required result |
| --- | --- | --- |
| T01 | Account A sends text to B | IDS delivery is immediate; Phase 1 later contains one protected raw event fingerprint; Phase 2 records `source=cloud` |
| T02 | Account B sends text to A | IDS delivery succeeds independently of CloudKit |
| T03 | A sends image and video to B | Metadata is bounded; no eager full-media load in the shadow phase |
| T04 | A reacts to a message | Phase 2: reaction is linked to one parent or safely deferred |
| T05 | A edits a message twice | Phase 2: revisions are deterministic and no stale text replaces a newer revision |
| T06 | A retracts a message | Phase 2: tombstone is preserved and the original is not resurrected |
| T07 | A marks conversation read | Phase 2: read state moves monotonically and cannot move backward |
| T08 | Windows B offline, then reconnects | One bounded catch-up pass, no duplicates, no IDS delay |
| T09 | Repeat the same page and token | Idempotent journal result and no checkpoint regression |
| T10 | Deterministic transport repeats the same non-final token | Typed no-progress failure, bounded retry, no hot loop |
| T11 | Malformed or undecryptable record | Quarantined with redacted reason; later records are retained |
| T12 | Process stops around journal/checkpoint commit | Restart produces either the complete transaction or no transaction |
| T13 | Network changes Wi-Fi to cellular and back | IDS remains healthy; no automatic shadow storm |
| T14 | Windows ARM64 to x64 to ARM64 | Sequential access only, identical normalized result, protected state still opens |
| T15 | Account switch on test profile | Previous account namespace is inaccessible; no state bleed |

Advanced Data Protection and Messages-key rotation are separate later tests.
Do not combine them with the first functional run.
Repeated tokens, forced server failures, reaction-before-parent ordering, and
crash boundaries belong in deterministic fault-injection tests; do not try to
provoke them against Apple's production services.

## Evidence and diagnostics

Every run should record only:

- test ID and build commit;
- platform, architecture, and client label;
- phase, trigger, and explicit event source (`ids` or `cloud`);
- bounded fetched, journaled, quarantined, and rejected counts;
- duration and typed failure category;
- checkpoint generation and a keyed or protected diagnostic fingerprint;
- duplicate logical-GUID count;
- process memory and CPU summary;
- whether IDS delivery remained healthy.

For cross-client correlation, derive an event fingerprint with a temporary
test-run HMAC key. The key must be memory-only, scoped to one run, and destroyed
after evidence comparison. Do not reuse the per-install account fingerprint
for this purpose.

Logs must not include message text, handles, Apple account identifiers, DSIDs,
tokens, PCS material, device passcodes, record names, raw etags, or attachment
paths. Exported diagnostics must be reviewed before sharing publicly.

## Pass criteria

- Zero lost logical message GUIDs.
- Zero duplicate logical messages after replay.
- Zero Account A or Account B state bleed.
- Zero CloudKit writes or deletions during the shadow phase.
- Zero automatic clique or zone resets.
- No checkpoint advance past a rejected or unjournaled page.
- Bounded pages, records, bytes, wall time, and retries.
- No measurable IDS send or receive regression.
- Deterministic normalized results across Pixel, Windows ARM64, and Windows x64.
- No unbounded attachment memory or eager media download.

## Stop conditions

Stop immediately and preserve diagnostics if any of these occur:

- missing or duplicate message;
- local message table changes during shadow mode;
- repeated continuation token without a typed stop;
- sustained CPU, heat, or memory growth after cancellation;
- account fingerprint or protected-state mismatch;
- automatic sync trigger despite the dormant setting;
- any Apple save, delete, reset, or zone mutation call;
- any secret or personal content in logs.

## Fastest execution schedule

### First 30 minutes

Do not begin this section until the production composition, manual sampler,
preflight, diagnostics, byte cap, protected Windows key path, and durable
`Retry-After` gates above are implemented and verified.

1. Confirm Account B, Mac activation, Messages in iCloud, and iCloud Keychain.
2. Confirm isolated Android package and Windows user profile.
3. Run `tooling/cloud_sync/verify_foundation.ps1`.
4. Back up the Account B test profiles.
5. Confirm Cloud Sync V2 remains dormant.

### Next 90 minutes

1. Run the IDS baseline.
2. Run one manual read-only shadow pass on Pixel.
3. Replay it.
4. Repeat on isolated Windows.
5. Run T01 through T09 and compare redacted counters.

### Soak

Run offline/reconnect, process restart, network change, large-history, and
architecture-switch cases for at least 24 hours before considering outbound
CloudKit writes.

## Inputs needed when the operator returns

- A Mac-activated test Apple Account with Messages in iCloud enabled.
- Access to its 2FA and trusted-device verification, entered locally.
- A second Android device or proof that Alpha and Beta package/data
  directories are isolated. The preferred same-device test uses the verified
  Alpha and Beta flavor packages listed above.
- Permission to create or use a separate local Windows user for Account B.
- The Pixel and Mac connected when live validation begins.

Do not send Apple credentials or device passcodes through chat.

## Primary references

- [Apple Platform Security: iMessage security overview](https://support.apple.com/guide/security/imessage-security-overview-secd9764312f/web)
- [Apple Platform Security: how iMessage sends and receives messages](https://support.apple.com/guide/security/how-imessage-sends-and-receives-messages-sec70e68c949/web)
- [Apple: Messages in iCloud](https://support.apple.com/guide/icloud/what-you-can-do-with-icloud-and-messages-mma17ed475f7/icloud)
- [Apple CloudKit synchronization state](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/state-swift.class)
- [OpenBubbles large-history sync stall](https://github.com/OpenBubbles/openbubbles-app/issues/168)
- [OpenBubbles large-history performance issue](https://github.com/OpenBubbles/openbubbles-app/issues/194)
- [OpenBubbles current iCloud sync failures](https://github.com/OpenBubbles/openbubbles-app/issues/222)
- [OpenBubbles rustpush](https://github.com/OpenBubbles/rustpush)
