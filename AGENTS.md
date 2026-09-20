# OpenBubbles thread handoff rules

## Scope

These rules apply to task `01a098ec-c448-73a1-a73f-696d142de228` and its
delegated agents. They supplement, not replace, inherited project instructions.

## Primary implementation and checkpoint review (September 18)

- User assigned primary remaining OpenBubbles implementation to existing task
  `01a0abe1-9bbe-71b2-a9ce-4d4578022b0e` (facetime & find my), using the
  Muse model selected in that task. CloudKit production
  readiness is the priority; existing FaceTime/Find My work remains preserved.
- That task now owns edits in this CloudKit checkout and its current branch.
  This explicitly replaces the earlier read-only restriction. Keep independent
  FaceTime/Find My changes in their existing checkout; no automatic bulk merge
  or simultaneous generated-file edits across workstreams.
- Supervisor task `01a098ec-c448-73a1-a73f-696d142de228` reviews checkpoints,
  rather than running a competing implementation/build loop. Send it one
  concise checkpoint after a meaningful fix or gate result, before enabling
  high-risk auth/encryption/identity/write-recovery changes, and when a concrete
  blocker needs a decision. Include exact revisions, changed paths, executed
  checks, live versus unverified behavior, and the decision requested.
- Routine source work and relevant tests do not require step-by-step approval.
  Continue independent useful work while awaiting review. Do not create an
  acknowledgement loop or send repeated unchanged status messages. Final
  integration and release claims require supervisor review of actual evidence.
- Shared auth/registration, rust/src/api/api.rs, rustpush_service.dart, native
  gates, dependency locks and FRB bindings require announced scope and reviewed
  integration. Feature work in a separate checkout is not permission to change
  the active account/profile or installed build.
- Primary owner schedules exclusive Pixel or Windows live-profile testing.
  Announce live use, confirm no other worker is using the profile, and release
  it after testing. Any other task must request and receive the primary owner's
  acknowledgement before install/restart/UI/relay/account actions. Preserve
  Alpha and all real data. An announced window never expands user authorization.
- That reservation must also cover the shared iPhone relay across platforms.
  The user reports that simultaneous Windows/Canary use can displace registration.
  Run one authenticated live client at a time for this relay. Separate worktrees
  or different operating systems do not establish independent relay identities.
  Do not treat a displaced registration as a proved CloudKit regression.
- No upstream PR/draft without explicit user confirmation. User renewed GCE
  approval on September 17 and on September 18 assigned direct operation of
  the established source-only GCE workflow to the primary Muse task. It owns
  its authorized commits, source publication, preflight, dispatch, monitoring,
  log/artifact review, and cleanup verification itself. A separate dispatcher
  or supervisor is not required for those routine operations. This supersedes
  the earlier requirement to route every run through task
  `01a0ac53-985b-7713-a21c-79251501c75c`.
- Follow [the direct GCE workflow guide](docs/GCE_SOURCE_ONLY_WORKFLOW.md).
  Use one justified bounded source-only run for an immutable reviewed revision;
  adopt an existing run rather than dispatching a duplicate. Preserve the
  current workflow, primary lane, Spot limits, automatic cleanup and lifetime.
  Do not modify infrastructure, IAM, secrets or billing, or upload credentials.
  High-risk integration and release review requirements above still apply.
  The primary implementation task manages its own helpers and current goal;
  the supervisor tracks checkpoint reviews and integration readiness.

## Helper model preference

Respect the user's selected Muse route and its actual effort support:
`meta-muse/muse-spark-1.3` is the subscription choice at `max`;
`meta-model/muse-spark-1.3-contributor` is the API choice at `xhigh`.
Do not request Contributor at `max` or silently change routes when one is rate
limited. An explicit user model/effort choice overrides a saved preference.
Keep assignments bounded and review their work before integration. Higher
effort does not justify extra parallel agents without useful independent work.

## Goal continuity and active jobs

- A queued or running CI job, shell session, or child task with a usable handle
  is ongoing work. Keep the goal active and use the declared wait/poll tools.
  Preserve the handle across turns. An unchanged running job is not a blocker,
  and sending a progress update does not end the monitoring responsibility.
- Use integer milliseconds for timer arguments, for example
  `clock.sleep` with `{"duration_ms":30000}`. If a tool rejects the shape,
  correct it or use another declared bounded wait mechanism; do not repeatedly
  send the same invalid argument or mark the goal blocked because one timer failed.
- In code mode, `ALL_TOOLS` lists tools callable through `functions.exec`, not
  every directly declared tool namespace. Check the current direct declarations
  before concluding that a clock or collaboration tool is unavailable. Call a
  direct tool through its declared namespace, never by inventing a `tools.*` alias.
- Before requesting blocked status, check live handles and permitted independent
  work. Apply the existing three-consecutive-goal-turn audit only to a real
  external blocker. A resumed goal starts a fresh audit; do not inherit its
  previous count. A pending checkpoint review is not a reason to stop unrelated
  permitted work. Genuine approval and physical-device gates remain in force.
- Transient provider failures and usage limits are separate from goal completion.
  Report the actual error and reset time when available, preserve the checkpoint,
  and use supported bounded retry/wait behavior. Do not invent a completion or
  hide a transport error behind a blocked label. Do not pause the goal without
  the user's request, and do not broaden permissions, spend, or model routing.

## Delegation and test efficiency

Apply OpenAI's [subagent guidance](https://learn.chatgpt.com/docs/agent-configuration/subagents)
and [test calibration guidance](https://developers.openai.com/api/docs/guides/latest-model):

- The primary owner manages the critical path, implementation and test evidence;
  the supervisor reviews the high-risk and release checkpoints above. Delegate
  independent work that can run alongside a different required step, not work
  the primary owner or supervisor will immediately duplicate.
- Give each helper an exact outcome, source revision, allowed files/actions,
  acceptance check and concise return format. Prefer a small context packet to
  the full conversation. Return findings and changed paths, not raw tool logs.
- Use one helper per distinct task. Reuse a relevant helper for follow-up; do not
  grow a standing pool or recursive review chain. The user's selected model and
  effort remain authoritative; they are not a general OpenAI recommendation.
- Read-heavy exploration and test triage can run in parallel. Coding helpers
  need disjoint write scopes. Do not create duplicate dependency trees, worktrees
  or builds for a task that only needs source inspection or one test file.
- Check returned claims against source or reproductions. Integrate or reject
  them explicitly. Keep working on independent steps instead of repeated polls.
- Run the smallest meaningful failure regression, then one affected integration
  batch. Repeat or broaden only after changed code, a failure or a concrete risk.
  Batch native/bridge changes into one hosted qualification run; do not rebuild
  an APK merely to exercise protocol logic covered by the fast loop.
- Record the changed production gate, result and remaining uncertainty in the
  treemap/history. Test count and agent count are not measures of completion.
  Close unneeded helpers after review; existing preservation/cleanup rules apply.

## Local tool and worktree discipline

- Check the current main source before proposing a repair from an old tester
  worktree. A fix already present in main is not new progress.
- Flutter is `C:/Codex/Toolchains/flutter-3.44.8-arm64/bin/flutter.bat`; Dart is
  under its `bin/cache/dart-sdk/bin/dart.exe`. Rustfmt is
  `C:/Codex/Toolchains/rustup/toolchains/stable-aarch64-pc-windows-msvc/bin/rustfmt.exe`.
  PATH absence does not mean the toolchain is missing. A separate worktree may
  still need its own dependency resolution; do not mislabel that as no SDK.
- Before local Flutter/ObjectBox tests, prepend the process PATH with
  `C:/Codex/Toolchains/objectbox-windows-arm64-v5.3.2/lib`. Otherwise the tests
  fail with objectbox.dll error126 before exercising product code. Use
  `flutter.bat test --no-pub --concurrency=2` for an already-resolved targeted
  batch; do not copy DLLs or real credentials into helper worktrees.
- Use apply_patch with exact absolute forward-slash paths for isolated edits.
  If the routed tool rejects the path, return the patch to the parent. Do not
  create Desktop probe files or bypass the editing rule with shell file writes.
- The primary task runs its own Git and authenticated CI commands. If a
  sandboxed command is denied, use the declared tool's supported scoped
  approval path when available; do not assume another model must run it. In
  full-access sessions omit sandbox_permissions entirely. Keep any Git
  safe.directory override specific to the verified user-owned checkout.
- Avoid whole-file formatter churn in existing files. Keep prototype changes
  isolated until review and executed tests. Use the established GCE qualification
  and GitHub-hosted Windows/signing paths under the authorization above.

## Documentation before compaction

Before each planned compaction, the parent must reconcile the project documents
with verified current state:

- Update `docs/CLOUD_SYNC_V2_CONNECTION_TREEMAP.md` with the current gates,
  blockers, next discriminating test, and exact source, bindings, native-library,
  and installed-build versions relevant to the next action.
- Append new evidence and decisions to the current investigation log under
  `docs/cloud_sync_v2/history/`. Keep chronological detail out of the treemap.
- Update affected build and test guides when commands, prerequisites, workflow,
  safety constraints, or artifact locations have changed.
- Record active job IDs, process/session handles, agent assignments, pending
  results, and the exact safe resume action. Check storage at this checkpoint.
- Distinguish implemented, tested, live-verified, failed, and pending work.
  A passing component test is not proof of production readiness.
- Complete the required agent review and cleanup checks, retaining protected
  work and evidence. Record any unsupported cleanup or preservation exception.

Keep updates concise. Do not duplicate unchanged history or include credentials,
raw personal messages, or photos in documentation. Preserve necessary private
evidence separately and reference it without exposing its contents.

If automatic compaction occurs before this checkpoint, or the retained context
does not prove it completed, reconcile the documents and agent state immediately
afterward before starting new implementation or builds. The chat summary alone
does not replace the project documentation.
