# OpenBubbles thread handoff rules

## Scope

These rules apply to task `01a098ec-c448-73a1-a73f-696d142de228` and its
delegated agents. They supplement, not replace, inherited project instructions.

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
