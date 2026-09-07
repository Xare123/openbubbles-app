---
type: index
title: Cloud Sync V2 Documentation Index
description: Entry point for the current CloudKit V2 architecture, preserved investigation history, and qualification evidence.
resource: openbubbles-app
tags: [openbubbles, cloudkit, index, evidence]
timestamp: 2026-09-07
---

# Cloud Sync V2 documentation

## Start here

- [Current connection treemap](../CLOUD_SYNC_V2_CONNECTION_TREEMAP.md):
  authoritative current architecture, safety boundaries, release gates, and
  next falsification test.
- [Investigation log through 2026-09-07](history/CLOUD_SYNC_V2_INVESTIGATION_LOG_THROUGH_2026-09-07.md):
  preserved chronological checkpoints, prior candidates, run IDs, source
  evidence, patents, and rejected hypotheses. Historical status does not
  override the current treemap.
- [Current investigation log](history/CLOUD_SYNC_V2_INVESTIGATION_LOG_FROM_2026-09-07.md):
  chronological qualification results recorded after the documentation split.

## Evidence roots

- `evidence/windows-replay-20260906/`: Windows fast-loop, ObjectBox, analyzer,
  route, reaction, save/readback, and Smart App Control evidence.
- GitHub Actions run `34170476606`: current exact-source full GCE qualification
  for candidate `84b1018e4`.
- GitHub Actions run `34168948855`: invalidated infrastructure attempt. The app
  checkout succeeded, but rustpush commit `2274cee63` was absent from the fork;
  no tests or APK build ran. Runner cleanup passed.
- GitHub Actions run `34169243930`: invalidated candidate `4eb1d66c4` after
  2,423 Dart tests passed and three failed. The concrete failures and repair
  are recorded in the current investigation log. Runner cleanup passed.

## Reading rule

Use the current treemap to choose work. Consult the historical log only for an
exact prior observation, rejected hypothesis, source SHA, run ID, or evidence
path. When a current candidate changes, update the short treemap first and add
the dated details to a new investigation-log continuation rather than growing
the treemap into another chronological transcript.
