---
type: validation_plan
title: OpenBubbles Cloud Sync V2 Live Validation
description: Safety-gated two-account validation runbook for Pixel Android, Windows ARM64, Windows x64, and a Mac truth source.
resource: openbubbles-app
tags: [android, pixel, windows, arm64, x64, cloudkit, sync, testing, security]
timestamp: 2026-08-22
---

# OpenBubbles Cloud Sync V2 live validation

## Current readiness

The bounded Android read-only shadow and semantic-pull canaries now have
production composition paths, explicit developer-only manual triggers,
fail-closed preflight, protected persistence, and redacted reports. They remain
separately compile-gated and are not connected to the legacy `Messages in
iCloud (BETA)` switch. That legacy switch must remain off throughout these
canaries.

Offline evidence on 2026-08-22 at `75e779b2d`: 533 Flutter tests, 130 main
Rust tests, and 43 standalone protector tests passed. An independent final
audit found no P0-P2 release blocker for the bounded read-only semantic canary,
and its 84 focused tests passed. The exact Beta sampler job, Windows x64,
Windows ARM64, bridge, and fail-closed media-provenance jobs are green. The
remaining Alpha packaging steps are not prerequisites for installing the
separate Beta canary.

This is readiness for the **first controlled live canary**, not evidence that
CloudKit V2 works with Apple's production service. No real Apple record has yet
been decoded or projected by V2. Remote saves, remote deletes, local
tombstones, automatic triggers, and full-history sync remain disabled.

### Blockers to the first live fetch

| Priority | Blocker | State | Required closure |
| --- | --- | --- | --- |
| 1 | Authoritative CI and APK provenance | Closed for Beta canary | Exact `75e779b2d` Beta job passed; downloaded artifact package, APK v2 signature, SHA-256, ARM64 ABI, and required native libraries were verified |
| 2 | Account and app-data isolation | Open on device | Prove Beta has a distinct package, UID, and data directory; use only the Mac-activated test account and never restore Alpha data into Beta |
| 3 | Live PCS/keychain authorization | Open | The fail-closed preflight must pass on the test account without resetting a clique, zone, token, or trust relationship |
| 4 | Account-switch disposal race | Closed offline | Keep the idempotent cancel-and-quiesce tests green; reset must abort before client disposal if the bounded 50-second quiescence wait expires |
| 5 | Raw-page resource bounds | Closed offline | Keep the 32 MiB page admission and one-page/50-change-per-zone semantic limits green before every device build |
| 6 | Native package architecture and bridge parity | Closed for Beta canary | ARM64 Android libraries plus Windows x64, Windows ARM64, and bridge jobs passed from exact commit `75e779b2d` |
| 7 | Live Apple record shapes and ordering | Open | Run shadow first, then the bounded semantic pull, then an immediate replay; stop safely on any deferred, quarantined, retried, skipped, duplicate, or remote-write count |
| 8 | Remote mutation isolation | Closed for read-only canary | Confirm saves, deletes, tombstones, notification hints, profiles, and automatic triggers remain disabled and the outbox count stays zero |

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
- The first live phase is manual, read-only shadow sync. The semantic pull is a
  distinct second canary and may project bounded CloudKit records locally.
- Keep the existing `Messages in iCloud (BETA)` switch off. It is the legacy
  mutating engine, not the V2 shadow sampler.
- Required shadow flags are:
  - `readOnlyFetch: true`
  - `semanticApply: false`
  - `saves: false`
  - `deletions: false`
  - `profiles: false`
  - `notificationHints: false`
  - `automaticTriggersEnabled: false`
- Required semantic-canary flags are:
  - `readOnlyFetch: true`
  - `semanticApply: true`
  - `saves: false`
  - `deletions: false`
  - `profiles: false`
  - `notificationHints: false`
  - `automaticTriggersEnabled: false`
- The Beta artifact must be compiled with both
  `OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true` and
  `OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true`.
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

### Verified Beta canary artifact

- Source commit: `75e779b2d86dc3964662a5118e9a58b0d1ffdff1`
- GitHub Actions run/job: `32583069161` / `Beta Sampler APK`
- Artifact: `Beta Debug APK (Cloud Sync sampler)`
- Local file: `C:\Codex\OpenBubblesReview\artifacts\cloud-sync-v2-canary-75e779b2d-run-32583069161\app-beta-debug.apk`
- Package: `com.bluebubbles.messaging.beta`
- Version: `1.15.0` (`20002227`)
- SHA-256: `79F94A0E6456F5EE43BD6164527959709FFBD8712687049AA02BC6DD5B818CBA`
- APK signature: v2 verified, one Android Debug signer; certificate SHA-256
  `0c06a6d3d619476917521e75e5c56bd6af81390161217a99419efe48e0577d1c`
- Required ARM64 libraries present:
  `libflutter.so`, `libobjectbox-jni.so`, and
  `librust_lib_bluebubbles.so`

The package/UID/data-directory isolation check remains a live-device gate. Do
not infer it solely from the distinct package name.

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

### Gate 3B: bounded semantic pull

Proceed only after both shadow passes are clean. Run one manual semantic pull
in this exact zone order: chats, messages, attachments. Each zone is bounded to
four pages of 50 changes, or 200 records total. This canary may project chats,
messages, reactions, and attachment metadata into the isolated Beta ObjectBox
profile. It must not download media bodies or apply profiles, display clears,
group photos, or tombstones. Disabled tombstones are retained as protected,
read-only acknowledgements and do not delete canonical local state.

The UI may report `Cloud Sync V2 Complete` only when all three zones report
`completed`, no zone is skipped, deferred, quarantined, or retried counts are
zero, and the remote-write/outbox tripwire remains zero. The separate
read-only-tombstone acknowledgement count is expected evidence, not a
quarantine failure. Any other outcome is `Cloud Sync V2 Stopped Safely`;
preserve the redacted report and do not repeat until the cause is understood.

Immediately run the semantic pull once more in the same account session. The
replay must create zero duplicate logical records, retain monotonic state, and
perform zero remote saves or deletes. Confirm the active Apple account scope is
unchanged immediately before each local transaction.

### Gate 4: same-account cross-client reconciliation

Keep the Windows Account B client offline. Generate controlled events between
Accounts A and B, then reconnect Windows and run one manual shadow pass. The
bounded semantic canary can now decode and locally project selected chat,
message, reaction, and attachment-metadata lanes, but this has not been proven
against either platform's live Apple data. Raw encrypted bytes and
platform-specific protection envelopes may differ.

Before cross-client comparison, add an ephemeral test-run HMAC key used only to
derive comparable event fingerprints from stable Apple record identity. The
current per-install account fingerprint cannot correlate Pixel and Windows
events. Never export the raw record identity or HMAC key.

For cross-client semantic comparisons, first add a developer-only,
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

Do not begin this section until the authoritative PR-head workflows pass and
the exact downloaded Beta APK passes package, signature, ABI, and native-library
verification.

1. Confirm Account B, Mac activation, Messages in iCloud, and iCloud Keychain.
2. Confirm isolated Android package and Windows user profile.
3. Verify Alpha and Beta package IDs, UIDs, and data directories are distinct.
4. Run `tooling/cloud_sync/verify_foundation.ps1`.
5. Back up the Account B test profiles.
6. Confirm the legacy sync switch is off and V2 has no automatic trigger.

### Next 90 minutes

1. Run the IDS baseline.
2. Run one manual read-only shadow pass on Pixel.
3. Replay the shadow pass and inspect its redacted report.
4. Run one bounded semantic pull and inspect all strict pass criteria.
5. Replay the semantic pull and verify zero duplicates and zero remote writes.
6. Repeat the shadow phase on isolated Windows only after Pixel is clean.
7. Run T01 through T09 and compare redacted counters.

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
