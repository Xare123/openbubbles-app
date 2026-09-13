---
type: Decision Record
title: Bounded CloudKit V2 history progress
description: Normal account settings surface over the existing checkpointed semantic catch-up runner.
tags: [cloudkit, sync, ux, safety]
timestamp: 2026-09-12
---

# Scope

Based on `883f001868ac64a160c20018b2fb46e3aedb029e`. Adds an account settings card, not a new sync engine or an authorization expansion. No app version bump: this is an isolated source change, not a packaged release.

The card is available in the normal profile settings on an explicitly semantic-enabled Canary build. Developer Mode, authenticated client, supported ABI, foreground isolate, preflight, identity, writer pause, and operation interlock checks remain required. Ordinary production/Alpha rollout is not enabled by this change.

# Behavior

- Start / resume runs the existing confirmed catch-up loop once and joins duplicate starts. Page navigation does not cancel it.
- Regular keeps the existing maximum of eight foreground batches. Turbo requires a heat, battery, and responsiveness warning, and permits sixteen. Both retain sixteen passes per batch and the existing four pages per zone, record limits, lease durations, retries, native quiescence, and projection sweep limits. Background calls never receive the foreground progress object or Turbo budget.
- Authentication, PCS, zone fetch, replay, queued/retry wait, pausing, paused/capped, remote head, unresolved projection, and fixed-code failure states are distinct. Progress cannot authorize a request or advance a checkpoint.
- No percentage is invented. CloudKit history has no stable total and sparse fetch sequences are not row counts. Exact counters identify journaled pages, newly inserted journal records by zone, completed batches, and retained sweep row visits/projections. Repeat visits are labeled. Backlog counters come from the last persisted report, not an invented initial zero.
- Media is on demand and separate. The existing serialized attachment download action reports active/completed/failed attempts without changing its limits, cancellation, identity validation, or scheduling. Remote head never claims all bodies are downloaded.
- Pause closes this foreground drain's admission and waits for protected work. A new optional foreground-only policy lets the active bounded remote pass finish and persist before reporting cancellation; retained projection waits for its active window. No future is abandoned and the native pause is released normally. Background cancellation policy remains unchanged. An unrelated failure during pause remains an error.
- Resume after process restart uses the existing durable checkpoints. UI state/counters are deliberately in memory; no parallel cursor or migration is added. Turbo is not persisted. Pause is not a global pause for media, background wakes, or already opted-in send work.
- Successful history catch-up refreshes the chat presentation through the existing repair/init path. A refresh failure is reported separately from sync success.

# Verification and remaining gates

Targeted Flutter tests cover progress ownership, caps, redaction, pause ordering, safe remote-pass persistence/release, media separation, normal settings actions, Turbo acceptance, navigation, and 320px layout at 1.6x text. Existing engine, sampler, drain, attachment gate, and Android composition tests cover checkpoint recovery, conflict/write guards, identity fences, and background budgets. Local widget render: `build/sync-progress-review.png` (generated, not committed).

Final combined run: **256 tests passed** with Flutter 3.44.8 ARM64, `--no-pub --concurrency=2`, across:

- `cloud_sync_progress_test.dart`
- `cloud_sync_progress_widget_test.dart`
- `cloud_sync_manual_semantic_pull_sampler_test.dart`
- `cloud_sync_semantic_drain_controller_test.dart`
- `cloud_sync_engine_test.dart`
- `cloud_attachment_sync_gate_test.dart`
- `cloud_sync_android_background_composition_contract_test.dart`

All paths above are under `test/services/cloud_sync/`. Logs are generated in `build/sync-progress-tests.log` and `build/sync-progress-analyze.log`. Targeted analysis of changed Dart files has zero errors; five existing warnings and nine existing info-level findings remain in the surrounding profile/service files. `git diff --check` passes.

No APK built, installed, or distributed. No Pixel operation, live authentication, PCS network call, CloudKit transport, or credentials used. Native performance, foreground lifetime under Android OS suspension, thermal impact, accessibility with real TalkBack, and authenticated end-to-end progress still require separately authorized device validation. The existing safety rollout remains a release gate.
