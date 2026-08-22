---
type: roadmap
title: OpenBubbles Cloud Sync V2 Path to Production
description: Dependency-ordered sequence from the current verified state to a production rollout, separating code work from work that needs live Apple access, hardware, or a licensing decision.
resource: openbubbles-app
tags: [cloudkit, sync, rollout, validation, android, windows, arm64, x64]
timestamp: 2026-08-22
---

# Cloud Sync V2 path to production

## Purpose

The rollout plan in [Cloud Sync V2](CLOUD_SYNC_V2.md) describes phases. The
gate documents describe conditions. Neither says, in order, what is actually
left and which parts cannot be finished by writing code. This does.

Every claim below is either measured or labelled as an estimate. Where a
prior document is stale, this one says so rather than repeating it.

## Where this actually stands

Latest local evidence was refreshed on 2026-08-22. The current CI rerun is
pending after removing an unrelated protobuf rename that broke the committed
FRB mirror; Windows x64 and ARM64 already pass on the same change set:

| Evidence | Result |
| --- | --- |
| Dart suite, ARM64 host | 533 tests pass |
| Cloud Sync suite, ARM64 host | 388 tests pass |
| Legacy ObjectBox upgrade probe, ARM64 host | copied pre-V2 database opens; source SHA-256 remains unchanged |
| Cloud Sync suite, x64 host | 296 pass on the prior cross-platform run |
| Cloud Sync suite in CI on Linux | passes, first time it has ever run there |
| `cloud_sync_protector_harness`, ARM64 | 43 tests pass |
| Kotlin FaceTime unit tests, Alpha variant | 14 tests pass |
| Windows x64 CI lane | passes |
| Windows ARM64 CI lane | passes |
| Release Rust libraries | correct PE ARM64, PE x64, ELF64 AArch64 |
| `cargo test` on the main crate | 130 tests pass |

What that evidence does **not** cover: no live CloudKit fetch has ever run, no
record has been decoded from a real Apple account, and nothing has been written
to a message table by the V2 path. The production code now supports that first
bounded semantic canary, but code-path coverage is not live-account evidence.

## The honest shape of the remaining work

Three categories, and only the first is ours to finish by typing.

1. **Code and tests.** The bounded semantic canary is now composed behind its
   own compile-time and Developer Mode gates. It projects supported chats,
   messages, reactions, and attachment metadata into ObjectBox while remote
   saves, remote deletes, local tombstones, automatic triggers, and unbounded
   traversal remain structurally disabled. The remaining code work is
   hardening found by review and the later write path, not the first read-only
   semantic projection.
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
2. ~~**Decide the discovery zone set.**~~ **Done for the raw sampler.** The
   bounded read-only sampler now inspects the original three Manatee zones plus
   `messageUpdateZone`, `recoverableMessageDeleteZone`,
   `scheduledMessageZone`, and `chat1ManateeZone`. Stable native stream tags 4
   through 7 preserve checkpoint separation. The four auxiliary streams are
   deliberately rejected before semantic decode, and the existing production
   record-count path remains limited to its original three zones.
3. **Resolve the `EMPTY_LIST` question.** The CloudKit wire format has a
   distinct type for "present but empty" and our tri-state depends on it. Prior
   art collapses it with absent and therefore cannot answer whether Apple emits
   it. This is a question for the first live fetch, but the transport must be
   able to *record* the distinction before that run, or the run cannot answer it.

4. ~~**Decide what unblocks a stalled applied floor.**~~ **Done: advance
   through terminal quarantine while retaining the journal evidence.**
   `_advanceContiguousApplied` now treats both `applied` and `quarantined` as
   terminal. Pending and retryable rows still block the floor.

   The consequence chain is worth stating plainly. One malformed record blocks
   the floor, the pending journal keeps growing, the journal budget eventually
   refuses further fetches, and sync stops. If the stall outlasts the CloudKit
   change-token lifetime the token expires and the cost is a full re-bootstrap
   of the entire zone, which is far worse than the single record that caused it.
   That lifetime is undocumented, so no safe stall duration can be assumed.

   The retained quarantine row preserves the protected source reference,
   failure category, and replay evidence for a later decoder or targeted
   recovery. It is not silently deleted. The tradeoff is explicit: CloudKit
   will not automatically re-offer that change after the terminal floor moves,
   so a future fetch-by-record-name repair path remains useful. This is safer
   than allowing one malformed record to stop an entire zone indefinitely when
   Apple's change-token lifetime is undocumented.

Additional safety closures in this stage:

- Dependency-deferred inbox rows now have a bounded terminal path, but only
  after both eight attempts and three days by default. Ordinary retryable
  network, server, and storage failures are not captured by that terminal rule.
- The outbox leases only the earliest nonterminal mutation for each logical
  entity, so a newer delete cannot overtake an older leased or paused save.
- Push-only runs can revive an all-paused authorization or PCS outbox after a
  successful subsystem refresh. Failed refreshes retain the paused row and a
  durable six-hour retry delay prevents a trigger-driven refresh storm.
- The current ObjectBox model successfully opens a copied legacy database and
  leaves the source hash unchanged. That source contained no canonical message
  rows, so a non-empty real-history migration probe is still required before
  rollout.

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
6. **Run the shadow sampler first.** This fetches and protects one bounded page
   without canonical message-table writes. Do not move to semantic projection
   if any zone fails its transport, journal, checkpoint, account, or write
   tripwire checks.
7. **Read the shadow result carefully.** A zone that returns `completed` with
   `fetched: 0` and no failure category is a success, but an empty zone and a
   never-populated zone are indistinguishable in the report. Confirm upload
   from the Mac first or this stage proves only that transport works.
8. **Run one semantic pull canary, then one immediate replay in the same
   session.** It processes chats, messages, then attachments, at one page and
   50 changes per zone. A pass requires all three exact zones to complete, zero
   deferred, quarantined, or retried records, and unchanged empty outbox
   tripwires. The replay must be in-session: the journal budget rejects pending
   entries older than 24 hours, so a next-day replay can be legitimately
   blocked and look like a failure.

Exit: bounded fetch, protected journaling, checkpoint behaviour, canonical
projection, and replay idempotence demonstrated against a real account. It
still does not prove full-history coverage, legacy coexistence, or writes.

### Stage 3 — semantic apply

The largest block of code work, and the first point at which the local message
database is written by this path.

9. ~~**Widen the bridge once.**~~ **Done.** Rich transient payloads now carry
   validated canonical identities for chats, messages, reactions, and
   attachment metadata without exposing raw CloudKit identifiers or records.

   Carry the `EMPTY_LIST` observation across at the same time.
   `CloudRawRecordPresence` already records which fields arrived with that wire
   type, but nothing can read it from Dart, so the evidence is gathered and
   discarded. It is held back rather than regenerated for one diagnostic field.
10. ~~**Implement the Dart semantic decoder boundary.**~~ **Done and composed
   only by the manual semantic canary.**
   `RustCloudSemanticDecoder` validates the complete scope, generation,
   protected source capability, native session before and after decode,
   one-of result shape, mutation kind, entity kind, logical hashes, field
   presence, and timestamps. Native failures map only to typed safe categories.
   Partial messages and unproven tombstone identities defer instead of
   inventing content or deletion targets. Fifteen focused tests cover all
   current payload lanes, every native failure code, source/session mismatches,
   mixed dispositions, partial messages, reactions and removals, explicit
   clears, edit revisions, tombstones, and auxiliary-zone rejection. The
   separately compile-gated canary now enables bounded local semantic apply;
   remote mutations and automatic execution remain disabled.
11. ~~**Expand the production entity adapter.**~~ **Done for the current canary
    lanes.** Supported chat, message, reaction, and attachment metadata records
    map onto the real ObjectBox entities. Display-name clears, profiles, group
    photos, media bytes, and tombstones remain gated or unsupported rather than
    guessed.
12. ~~**Respect the transaction boundary.**~~ **Done.** Canonical mutation,
    merge snapshot, identity mapping, replay outcome, inbox terminal state, and
    checkpoint floor share one ObjectBox transaction. A full native account
    identity recheck occurs immediately before that write.
13. **Prove no duplicate rows.** `Message.guid` is unique, and the legacy
    CloudKit path still ships. A live coexistence test is the only way to show
    V2 does not create duplicates alongside it.

Exit: deterministic identical projection across replay, restart, ARM64, and
x64, with zero lost and zero duplicated logical message GUIDs.

### Stage 4 — writes

14. **Enforce one writer per account.** V2 becomes the only CloudKit writer.
    The legacy path may remain available for read/restore during migration, but
    its uploads and duplicate-record deletion must be structurally unavailable
    whenever V2 owns the profile. Today the two paths have separate record maps,
    and legacy duplicate cleanup can otherwise delete a valid V2-owned record.
15. **Complete durable record identity.** Store the proven CloudKit change
    tag/CAS value, record type, owner, generation, server ordering, and deletion
    fence. Add reverse uniqueness for server record identity. Do not treat a
    different opaque etag hash as proof that an observation is newer.
16. **Validate every push result exactly.** Reject duplicate, missing, and
    unknown operation IDs before durable confirmation, and bind every result to
    action, logical identity, payload digest, server identity, and expected
    change tag. Chat saves are atomic in Apple's iOS 26 implementation; message
    and attachment saves are non-atomic and require per-record outcomes.
17. **Fence network workers through completion.** An expired outbox lease may
    never confirm a late result. Add lease generation/expiry CAS, bounded push
    duration or heartbeat renewal, coordinator renewal during network work, and
    attempt-plus-age retry/dead-letter policy. The direct expired-lease result
    race is now fixed in both ObjectBox and the in-memory reference store; the
    remaining generation and heartbeat work stays open.
18. **Couple local mutation and outbox admission.** One ObjectBox transaction
    must perform the canonical local mutation, allocate its monotonic revision,
    insert/coalesce the outbox operation, update any proven mapping, and
    revalidate account plus generation. No production caller has this API yet.
19. **Retain durable tombstone causality.** A delete needs an existing validated
    mapping, local/outbox revision checks, a durable deletion fence, and tests
    proving an older save cannot resurrect it. Incoming chat-record deletion
    must not erase a local conversation merely because CloudKit reported it;
    Apple's current importer deliberately leaves that action to IDS.
20. **Build a dedicated V2 Rust writer.** It must expose zone-specific PCS
    protection, explicit save policy and atomicity, per-record save/delete
    results, returned server change tags, conflict classification, and
    read-after-ambiguous-result reconciliation. Do not expose the legacy
    wrappers as though they satisfy this contract.

Exit: lost-response, duplicate/missing/unknown-result, change-tag conflict,
lease-expiry, crash-boundary, account-switch, reset-with-outbox,
save/delete/save, tombstone-replay, and legacy/V2 coexistence tests all pass.
Only then may a disposable test account run a one-record outbound canary.

### Stage 5 — rollout

21. Android wake-cost suite under Doze, Battery Saver, locked screen, and 24-hour
    idle, with paired sync-off and sync-on runs. No credible battery claim can
    be made before this, and none is made now.
22. Staged rollout with the alarm thresholds already specified in the
    production-readiness notes wired as rollback signals.

## What is blocked on something other than code

| Item | Blocker | Consequence if unresolved |
| --- | --- | --- |
| Windows desktop package | ANGLE built from pinned official source; the bundled media package deliberately refuses the unlicensed third-party ARM64 bundle | No runnable Windows build; the Rust bridge itself already builds for both architectures |
| Android release signing | Keystore and `android/key.properties` absent | Debug and profile packages only |
| Public redistribution | libmpv/FFmpeg transitive licence inventory incomplete | Cannot ship publicly regardless of engineering state |
| `rustpush` crate-level test execution on the Windows host | Smart App Control blocks newly rebuilt test executables | The dedicated CI gate now runs these tests; do not disable the local policy |
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
