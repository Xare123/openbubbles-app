---
type: index
title: OpenBubbles Engineering Documents
description: Progressive index for local technical designs, diagnostics, and verification plans.
resource: openbubbles-app
tags: [openbubbles, engineering, documentation]
timestamp: 2026-07-31
---

# OpenBubbles engineering documents

- [Development](DEVELOPMENT.md): local development and build guidance.
- [Diagnostics](DIAGNOSTICS.md): bounded, redacted runtime logging.
- [Verification](VERIFICATION.md): delivery, routing, and performance gates.
- [Memory management](MEMORY_MANAGEMENT.md): bounded media and conversation
  resource ownership.
- [Cloud Sync V2](CLOUD_SYNC_V2.md): guarded Pixel Android and Windows
  ARM64/x64 reconciliation architecture and rollout.
- [Cloud Sync V2 live validation](CLOUD_SYNC_V2_LIVE_VALIDATION.md):
  two-account test topology, safety gates, evidence, and stop conditions.
- [Cloud Sync V2 open-source pattern review](CLOUD_SYNC_V2_OPEN_SOURCE_REVIEW.md):
  license-aware queue, checkpoint, recovery, and media patterns worth
  reimplementing.
- [Cloud Sync V2 production-readiness research](CLOUD_SYNC_V2_PRODUCTION_READINESS_RESEARCH.md):
  current platform evidence, upstream risks, bounded operating budgets, and
  cross-platform release gates.
- [Cloud Sync V2 developer shadow sampler](CLOUD_SYNC_V2_MANUAL_SAMPLER.md):
  exact fail-closed composition, tripwires, report contract, and tests for the
  first live entry point.
- [Cloud Sync V2 semantic applier](CLOUD_SYNC_V2_SEMANTIC_APPLIER.md):
  content-free decoder contract, transactional reconciliation boundary, and
  remaining native and ObjectBox adapters.
- [Cloud Sync V2 canonical mapping](CLOUD_SYNC_V2_CANONICAL_MAPPING.md): Apple
  record field mapping, presence rules, parsing grammars, and fixture matrix.
- [Cloud Sync V2 Android scheduling](CLOUD_SYNC_V2_ANDROID_SCHEDULING.md):
  dormant WorkManager wake policy and its activation gates.
- [Cloud Sync V2 native protected fetch](CLOUD_SYNC_V2_NATIVE_PROTECTED_FETCH.md):
  narrow protected-page bridge, adoption leases, and bounded collection.
- [Cloud Sync V2 path to production](CLOUD_SYNC_V2_PATH_TO_PRODUCTION.md):
  dependency-ordered remaining sequence, separating code work from work that
  needs live Apple access, hardware, or a licensing decision.
- [Cloud Sync V2 field ownership](CLOUD_SYNC_V2_FIELD_OWNERSHIP.md): which
  fields the server owns, which the device owns, and the merge rule each class
  carries.
- [Cloud Sync V2 provenance ledger](CLOUD_SYNC_V2_PROVENANCE_LEDGER.md):
  per-idea record of borrowed protocol facts and patterns, their source licence,
  and the file implementing each one.
- [Decision: ObjectBox dependency posture](DECISION_OBJECTBOX_DEPENDENCY.md):
  what is actually depended on, which licence covers which part, and the
  triggers that would reopen the choice.
- [Windows host build environment](WINDOWS_HOST_BUILD_ENVIRONMENT.md): verified
  Windows-on-ARM toolchain layout and the host constraints for building the
  Rust bridge and running the suites for all three targets.
