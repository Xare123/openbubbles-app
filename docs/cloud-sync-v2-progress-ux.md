---
type: Decision Record
title: Bounded CloudKit V2 history progress
description: Normal account settings surface over the existing checkpointed semantic catch-up runner.
tags: [cloudkit, sync, ux, safety]
timestamp: 2026-09-12
---

# Scope

Integration update: source `9d33235fc` passed full GCE qualification and produced
a signed Canary in run `34732301245`. It is not installed. The subsequent pacing
repair below needs its own exact-source qualification and Pixel validation.

Code audited against `883f001868ac64a160c20018b2fb46e3aedb029e`; isolated branch rebased cleanly onto documentation-only `af5d746f71dc5081fceba60645fe86a2024a7007`. Adds an account settings card, not a new sync engine or an authorization expansion. No app version bump: this is an isolated source change, not a packaged release.

The card is available in the normal profile settings on an explicitly semantic-enabled Canary build. Developer Mode, authenticated client, supported ABI, foreground isolate, preflight, identity, writer pause, and operation interlock checks remain required. Ordinary production/Alpha rollout is not enabled by this change.

# Behavior

- Start / resume explicitly calls `prepareCloudSyncV2PcsConfirmed`, then the existing read-only automatic catch-up entry point. The sampler's authentication warming alone does not join the existing keychain clique. Apple may require device-password verification through the existing prompt. Canceling that prompt, pausing, account replacement, or teardown prevents a read. Duplicate starts join one service-owned run; page navigation does not cancel preparation or catch-up. This wrapper never wakes the upload writer.
- Regular uses one pass per session, one page of at most 50 fresh records and at
  most 32 retained replay attempts per zone, then yields 250 ms after releasing
  the protected session. Turbo uses 16 passes per session, four pages and 150
  replay attempts per zone, with the existing 1 ms inter-session yield. Maximum
  sessions are 512 Regular and 16 Turbo, preserving the earlier fresh-record
  caps of 25,600 and 51,200 per zone. These are volume limits, not expected totals
  or a speed guarantee. Leases, retries, native settlement and the at-head sweep
  are unchanged. Background and older developer entry points keep their budgets.
- The report writer receives the same immutable budget as the sampler. It checks
  the selected page count and bounds fresh versus total local work separately:
  Regular permits 50 fetched and 82 applied/work records per zone/pass. Default
  developer probes still require the original four-page report contract.
- Authentication, PCS, zone fetch, replay, queued/retry wait, pausing, paused/capped, remote head, unresolved projection, and fixed-code failure states are distinct. Progress cannot authorize a request or advance a checkpoint.
- No percentage is invented. CloudKit history has no stable total and sparse fetch sequences are not row counts. Exact counters identify journaled pages, newly inserted journal records by zone, completed batches, and retained sweep row visits/projections. Repeat visits are labeled. Backlog counters come from the last persisted report, not an invented initial zero.
- Media is on demand and separate. The existing serialized attachment download action reports active/completed/failed attempts without changing its limits, cancellation, identity validation, or scheduling. Remote head never claims all bodies are downloaded.
- Pause closes this foreground drain's admission and waits for protected work. A new optional foreground-only policy lets the active bounded remote pass finish and persist before reporting cancellation; retained projection waits for its active window. No future is abandoned and the native pause is released normally. Background cancellation policy remains unchanged. An unrelated failure during pause remains an error.
- Resume after process restart uses the existing durable checkpoints. UI state/counters are deliberately in memory; no parallel cursor or migration is added. Turbo is not persisted. Pause is not a global pause for media, background wakes, or already opted-in send work.
- Successful history catch-up refreshes the chat presentation through the existing repair/init path. A refresh failure is reported separately from sync success.
- Hidden, paused, or detached app lifecycle requests a cooperative pause; inactive alone does not cancel an authentication prompt. Resume does not auto-start or silently restore Turbo. No foreground service, keep-alive preference, or new background scheduler is added. Existing independently gated Android workers and their budgets remain unchanged.
- PCS preparation holds the existing identity-maintenance interlock and revalidates account, service-close, fence, and optional foreground continuation after asynchronous steps. PCS operation deadlines are not native cancellation: the existing 30-second native-call deadline returns `cloud_sync_v2_pcs_restart_required` without waiting indefinitely for native settlement, and poisons the existing process-wide exclusion until process restart. The UI explicitly says native work may still be running and disables Start / resume. Late success or failure cannot continue preparation, retry a join, or release the lock. Explicit account teardown and replacement operations stay fenced rather than releasing handles beneath native work. Clique reset remains unreachable; no unknown join is automatically retried. Password prompts still wait for user input; this is a native-call deadline, not an overall authentication deadline.
- If native pause acquisition cleanup or release is unconfirmed, the sampler now poisons its interlock before the exclusive callback unwinds. A sampler-local active flag alone did not fence replacement samplers or account teardown. Normal cancellation still awaits evidence flush, report persistence, native pause release, and controller disposal before reporting Paused. A failure at any of these boundaries remains an error; cancellation does not hide it.

# Verification and remaining gates

Targeted Flutter tests cover progress ownership, caps, redaction, pause ordering, safe remote-pass persistence/release, media separation, normal settings actions, Turbo acceptance, navigation, and 320px layout at 1.6x text. Existing engine, sampler, drain, attachment gate, and Android composition tests cover checkpoint recovery, conflict/write guards, identity fences, and background budgets. Local widget render: `build/sync-progress-review.png` (generated, not committed).

Initial patch combined run: **256 tests passed** with Flutter 3.44.8 ARM64, `--no-pub --concurrency=2`, across:

- `cloud_sync_progress_test.dart`
- `cloud_sync_progress_widget_test.dart`
- `cloud_sync_manual_semantic_pull_sampler_test.dart`
- `cloud_sync_semantic_drain_controller_test.dart`
- `cloud_sync_engine_test.dart`
- `cloud_attachment_sync_gate_test.dart`
- `cloud_sync_android_background_composition_contract_test.dart`

All paths above are under `test/services/cloud_sync/`. Logs are generated in `build/sync-progress-tests.log` and `build/sync-progress-analyze.log`. Targeted analysis of changed Dart files has zero errors; five existing warnings and nine existing info-level findings remain in the surrounding profile/service files. `git diff --check` passes.

PCS/lifecycle revision adds focused coverage in `cloud_sync_prepared_progress_test.dart` and extends widget navigation coverage through pending PCS. Source composition checks verify explicit preparation, no-writer-wake read routing, identity-maintenance exclusion, and service/lifecycle hooks. `build/sync-progress-pcs-focused-tests.log` records 46 passing focused tests. The final expanded run passes **317 tests** across the original seven files plus prepared-progress, production-composition, operation-interlock, and Android-background tests. Revision regression and analysis logs are `build/sync-progress-pcs-regression.log` and `build/sync-progress-pcs-analyze.log`. Analysis has zero errors and the same five existing warnings/nine info findings in surrounding code.

Follow-up safety review of `474ea753a`: **324 tests passed** in the same eleven-file expanded suite (`build/sync-progress-safety-regression-final.log`). Added never-settling PCS feedback, late completion/error, retained exclusion, restart-only UI, and lifecycle races across evidence flush, report persistence, and native release. The release-failure test exposed an interlock-release gap, corrected with poison before callback unwind. Earlier local runs also caught a test fixture's missing async modifier and a mistyped suite filename; the final suite has no failures. Targeted Dart analysis has zero errors or warnings, with five pre-existing style infos in `rustpush_service.dart` (`build/sync-progress-safety-analyze-final.log`). Base remains `af5d746f7`; no further rebase needed.

Those original agent tests used no APK, Pixel, live authentication, PCS network
call, CloudKit transport or credentials. The parent subsequently built and signed
9d33235fc as recorded above. Pixel throughput, thermal impact, accessibility and
authenticated end-to-end progress remain unverified. New pacing regression tests
exercise the real sampler and report-file writer: a small session releases the
interlock, resumes exact cursors under a larger budget, and preserves every held
record without running an exhaustive sweep before remote head. A fixture initially
claimed an empty terminal read while fetching 50 records; it was corrected rather
than weakening the terminal-read validator.

Integrated pacing qualification: 199 tests passed across progress model/widget,
prepared PCS, sampler, report-file writer, drain, production composition, media
gate and Android background composition. Targeted analysis returned no errors or
warnings, with five existing service style infos. The local widget render was
inspected for legibility; this does not replace the Pixel performance/UX gate.
Both scoped agents were reviewed and closed; no dedicated worktrees or caches
were created. Session transcripts remain because supported deletion is unavailable.
