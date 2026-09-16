# OpenBubbles thread handoff rules

## Scope

These rules apply to task `01a098ec-c448-73a1-a73f-696d142de228` and its
delegated agents. They supplement, not replace, inherited project instructions.

## Helper model preference

For newly spawned Muse helper agents, use
`meta-model/muse-spark-1.3-contributor` with `reasoning_effort: max` unless the
user explicitly requests a different model or effort. Keep assignments bounded
and review their work before integration. Higher effort does not justify extra
parallel agents without useful independent work.

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
- Avoid whole-file formatter churn in existing files. Keep prototype changes
  isolated until parent review and executed tests. No paid GCE run without
  renewed approval; full qualification currently uses GitHub-hosted Actions.

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
