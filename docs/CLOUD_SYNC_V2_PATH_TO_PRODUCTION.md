---
type: roadmap
title: OpenBubbles Cloud Sync V2 Path to Production
description: Dependency-ordered sequence from the current verified state to a production rollout, separating code work from work that needs live Apple access, hardware, or a licensing decision.
resource: openbubbles-app
tags: [cloudkit, sync, rollout, validation, android, windows, arm64, x64]
timestamp: 2026-08-06
---

# Cloud Sync V2 path to production

## Purpose

The rollout plan in [Cloud Sync V2](CLOUD_SYNC_V2.md) describes phases. The
gate documents describe conditions. Neither says, in order, what is actually
left and which parts cannot be finished by writing code. This does.

Every claim below is either measured or labelled as an estimate. Where a
prior document is stale, this one says so rather than repeating it.

## Where this actually stands

Verified on 2026-08-06:

| Evidence | Result |
| --- | --- |
| Dart suite, ARM64 host | 388 tests pass |
| Cloud Sync suite, ARM64 and x64 hosts | 296 pass on each |
| Cloud Sync suite in CI on Linux | passes, first time it has ever run there |
| `cloud_sync_protector_harness`, ARM64 | 39 tests pass |
| Kotlin unit tests, Alpha variant | 12 tests pass |
| Windows x64 CI lane | passes |
| Windows ARM64 CI lane | passes |
| Release Rust libraries | correct PE ARM64, PE x64, ELF64 AArch64 |
| `cargo test` on the main crate | blocked by host policy, not by code |

What that evidence does **not** cover: no live CloudKit fetch has ever run, no
record has been decoded from a real Apple account, and nothing has been written
to a message table by the V2 path.

## The honest shape of the remaining work

Three categories, and only the first is ours to finish by typing.

1. **Code and tests.** Large but tractable. The dominant item is the semantic
   apply path, which is not a matter of polishing existing code: no Dart
   semantic decoder implementation exists, the canonical GUID does not cross
   the bridge for chats or messages, and the production entity adapter is a
   set of stubs.
2. **Live validation.** Cannot be done offline at any effort level. Needs a
   Mac-activated Apple account with real history, a trusted device for PCS key
   access, and soak time measured in days.
3. **Blocked by something other than engineering.** ANGLE from pinned source
   for the Windows desktop package, a signing keystore for release Android
   builds, and the licensing question on redistributing libmpv/FFmpeg.

## Sequence

Dependency-ordered. Each step assumes the ones above it.

### Stage 1 — close what CI can prove

Nothing here needs a device or an Apple account.

1. ~~**Land the protocol corrections** from the prior-art review.~~ **Done,
   with one correction worth recording.** The reaction parent now accepts the
   bare-GUID partless form and the `bp:` bubble/tapback spelling, both parsers
   agree on the part spelling, and the legacy CloudKit download path parses the
   parent instead of storing the wrapper.

   Two of the four items in the original review were already correct in the
   tree: `filt`/`sqry`/`ste` were already `i64`, and the `MessageSummaryInfo`
   nesting was already right down to `bcg` inside `MessageEdit`.

   The fourth was wrong, and the error is instructive. The review said
   `bp`/`bpdi` are IDS wire keys rather than record fields. That is true of the
   **field names** in the IDS payload, and says nothing about the `bp:`
   **prefix** inside `associatedMessageGuid`, which is a real shape that this
   app's own `Message.fromMap` has always stripped. Acting on the first
   statement as though it covered the second briefly made both parsers reject a
   valid parent. Field names and identifier prefixes are different things even
   when they share letters.
2. **Decide the zone set.** We synchronize three Manatee zones.
   `messageUpdateZone` and `recoverableMessageDeleteZone` also exist and are
   plausibly where edits and recoverable deletes live. If so, reconciliation
   built on three zones is incomplete by construction, and that is far cheaper
   to learn now than after semantic apply is built on the assumption.
3. **Resolve the `EMPTY_LIST` question.** The CloudKit wire format has a
   distinct type for "present but empty" and our tri-state depends on it. Prior
   art collapses it with absent and therefore cannot answer whether Apple emits
   it. This is a question for the first live fetch, but the transport must be
   able to *record* the distinction before that run, or the run cannot answer it.

4. **Decide what unblocks a stalled applied floor.** `_advanceContiguousApplied`
   stops at the first inbox row whose status is not `applied`, and a
   `quarantined` row therefore blocks the checkpoint permanently. That is
   deliberate: the design refuses to skip a change. What is missing is any
   bound on the stall.

   The consequence chain is worth stating plainly. One malformed record blocks
   the floor, the pending journal keeps growing, the journal budget eventually
   refuses further fetches, and sync stops. If the stall outlasts the CloudKit
   change-token lifetime the token expires and the cost is a full re-bootstrap
   of the entire zone, which is far worse than the single record that caused it.
   That lifetime is undocumented, so no safe stall duration can be assumed.

   Two options, and this needs an explicit choice rather than a default:

   - **Advance past a terminal quarantine.** The row stays in the inbox as
     evidence, so nothing is dropped, but the checkpoint moves past it and
     CloudKit will not re-offer that record. Recovery then depends on a
     fetch-by-record-name sweep that does not exist yet.
   - **Keep blocking, but bound the stall by token age** and force a decision
     before the token can expire. Preserves the no-skip guarantee at the cost
     of needing a token-age estimate we do not have.

   Whichever is chosen, the stall must become observable first. Today a blocked
   floor produces no diagnostic at all, so the symptom is sync quietly stopping.

Exit: CI green on all lanes with the corrections landed.

### Stage 2 — first live read-only run

The prerequisites here are the reason this stage is not schedulable purely by us.

Operator inputs, none of which the app can supply: a Mac-activated Apple
account with Messages in iCloud enabled and real message history; iCloud
Keychain on with the device admitted to the clique; a trusted device passcode,
because PCS keys are only available to trusted devices and under Advanced Data
Protection there is no server-side fallback at all; and local 2FA entry.

5. **Install the sampler build** on a device whose profile is separate from any
   real account, and verify package identity, UID, native ABI, and data
   directory before trusting isolation.
6. **One manual read-only pass, then an immediate replay in the same session.**
   The replay must be in-session: the journal budget rejects pending entries
   older than 24 hours, so a next-day replay can be legitimately blocked and
   will look like a failure.
7. **Read the result carefully.** A zone that returns `completed` with
   `fetched: 0` and no failure category is a success, but an empty zone and a
   never-populated zone are indistinguishable in the report. Confirm upload
   from the Mac first or this stage proves only that transport works.

Exit: bounded fetch, protected journaling, checkpoint behaviour, and replay
idempotence demonstrated against a real account. This proves none of the
message semantics.

### Stage 3 — semantic apply

The largest block of code work, and the first point at which the local message
database is written by this path.

8. **Widen the bridge once.** The transient DTO carries a narrow subset and no
   canonical GUID for chats or messages. Widening it is a binding regeneration,
   which is disruptive, so it should happen once and deliberately rather than
   incrementally.

   Carry the `EMPTY_LIST` observation across at the same time.
   `CloudRawRecordPresence` already records which fields arrived with that wire
   type, but nothing can read it from Dart, so the evidence is gathered and
   discarded. It is held back rather than regenerated for one diagnostic field.
9. **Implement the Dart semantic decoder.** None exists today; the interface
   has no implementation outside test fakes.
10. **Expand the production entity adapter** to map onto the real `Chat`,
   `Message`, `Handle`, and `Attachment` entities. The legacy `applyFromCloud`
   path is the field-by-field reference implementation and already handles
   attributed bodies, edits, retractions, and reply parents. Field classes and
   merge rules are specified in [field ownership](CLOUD_SYNC_V2_FIELD_OWNERSHIP.md).
11. **Respect the transaction boundary.** The gateway already performs the whole
    multi-box transition in one write transaction. The adapter cannot reuse the
    entities' own `save()` methods, which open their own transactions, and
    `Handle.save()` reaches into the contacts service.
12. **Prove no duplicate rows.** `Message.guid` is unique, and the legacy
    CloudKit path still ships. A live coexistence test is the only way to show
    V2 does not create duplicates alongside it.

Exit: deterministic identical projection across replay, restart, ARM64, and
x64, with zero lost and zero duplicated logical message GUIDs.

### Stage 4 — writes

13. Durable dependency-aware outbox, explicit per-record confirmation, then
    tombstones behind their own flag. Deletion stays disabled until its own
    review.

### Stage 5 — rollout

14. Android wake-cost suite under Doze, Battery Saver, locked screen, and 24-hour
    idle, with paired sync-off and sync-on runs. No credible battery claim can
    be made before this, and none is made now.
15. Staged rollout with the alarm thresholds already specified in the
    production-readiness notes wired as rollback signals.

## What is blocked on something other than code

| Item | Blocker | Consequence if unresolved |
| --- | --- | --- |
| Windows desktop package | ANGLE built from pinned official source; the bundled media package deliberately refuses the unlicensed third-party ARM64 bundle | No runnable Windows build; the Rust bridge itself already builds for both architectures |
| Android release signing | Keystore and `android/key.properties` absent | Debug and profile packages only |
| Public redistribution | libmpv/FFmpeg transitive licence inventory incomplete | Cannot ship publicly regardless of engineering state |
| `cargo test` on the main crate | Smart App Control on the development host | Run on CI or another host; do not disable the policy, it cannot be re-enabled |
| Cross-client provenance | Per-install fingerprints cannot prove the same event reached two clients | Two clients showing the same message proves nothing without explicit cloud provenance |

## Standing constraints

These are invariants, not preferences.

- IDS delivery and CloudKit state stay separate. A CloudKit failure must never
  delay a send, a receive, local persistence, or the UI.
- Never automatically reset an iCloud Keychain clique, delete a zone, clear a
  token after an unknown failure, or discard a pending journal.
- Never switch an account in place on an existing local profile.
- rustpush is SSPL-licensed. Protocol facts learned from it are facts; its code,
  derive macros, and generated protobuf definitions are expression and must not
  be absorbed into the Apache-2.0 layer. Keep a provenance ledger entry per
  borrowed idea.

## What would change this plan

Finding that `messageUpdateZone` and `recoverableMessageDeleteZone` carry edits
and recoverable deletes would move zone coverage ahead of semantic apply,
because building the adapter against an incomplete zone set would need redoing.
That question is answerable in the first live run and should be asked then.
