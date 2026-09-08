---
type: log
title: Cloud Sync V2 Investigation Log from 2026-09-07
description: Chronological qualification results after the current treemap was separated from the historical investigation record.
resource: openbubbles-app
tags: [openbubbles, cloudkit, investigation, evidence, canary]
timestamp: 2026-09-07
---

# Cloud Sync V2 investigation log from 2026-09-07

This is a chronological evidence log. It does not override the
[current connection treemap](../../CLOUD_SYNC_V2_CONNECTION_TREEMAP.md).

## 2026-09-07, restored-group candidate qualification

### Run 34168948855, infrastructure-invalid

- App source: `4eb1d66c44e218a373770fc42e0f6421fcf172ac`
- Result: checkout failed before tests or build.
- Cause: the app referenced rustpush
  `2274cee63c05432c89fc5dbb61915b5659fa9721`, which was present locally but
  absent from the user's rustpush fork.
- Repair: reviewed the clean three-file dependency commit and pushed only its
  existing branch to `Xare123/rustpush`.
- Cleanup: GCE runner deletion and deregistration passed.

### Run 34169243930, candidate-invalid

- App source: `4eb1d66c44e218a373770fc42e0f6421fcf172ac`
- Dependency checkout, toolchain setup, generated bindings, and binding drift
  checks passed.
- Dart result: 2,423 passed, 3 failed. Rust, protector, APK, native-library,
  and signing steps did not run after the test gate failed.
- Failure 1: the pre-admission ObjectBox model fixture retained future property
  14 while declaring `lastPropertyId` 10.
- Failure 2: the pre-chat-binding fixture retained future property 14 while
  declaring `lastPropertyId` 12.
- Failure 3: the non-BMP group-routing vector expected a stale digest. Dart
  runtime and an independent UTF-8 length-framed SHA-256 calculation both
  produced `745cda1e196792998ef8b585fec5b2d6e6d96cf5960af0a261740a769c44dd4b`.
- Repair: candidate `84b1018e4200d6bd838740682424d21dfee7995c`
  removes future property 14 from both historical fixtures and pins the
  independently verified digest in Dart and Rust.
- Focused local proof: all 25 group-route tests passed; both ObjectBox upgrade
  tests passed; scoped analysis reported no issues. A local Rust attempt
  stopped during `ring` setup because `clang` was absent from that command's
  environment, before executing the test.
- Cleanup: GCE runner deletion and deregistration passed.

### Run 34170476606, runtime-valid but reproducibility-invalid

- App source: `84b1018e4200d6bd838740682424d21dfee7995c`
- Dependency: rustpush `2274cee63c05432c89fc5dbb61915b5659fa9721`
- Passed: generated bridge compilation, full Dart suite, Rust library,
  automatic-upload flags, rustpush production features, protector harness,
  Canary APK compilation, and native-library verification.
- Signing was correctly skipped because the generated-binding reproducibility
  gate found one Linux-only trailing space in `rust/src/frb_generated.rs`.
- Repair: candidate `7a0aa17068c8e11aa951ebf10b8cc80dd395e71d`
  makes the existing generated-Rust normalizer strip and reject trailing
  horizontal whitespace. Applying it to the uploaded Linux artifact produced
  the same SHA-256 as the normalized committed file.
- Cleanup: GCE runner deletion and deregistration passed.

### Run 34188248440, passed

- App source: `7a0aa17068c8e11aa951ebf10b8cc80dd395e71d`
- Dependency: rustpush `2274cee63c05432c89fc5dbb61915b5659fa9721`
- Requested gates: generated bindings, full Dart suite, Rust library,
  automatic-upload flags, rustpush production features, protector harness,
  Canary APK, ARM64 native-library verification, GitHub-hosted signing, and
  ephemeral-runner cleanup.
- Result: every requested gate passed. The GCE build job completed in 26m29s,
  GitHub-hosted signing and verification completed in 58s, and VM plus runner
  cleanup completed in 1m48s.
- Signed artifact: `GCE CloudKit V2 Canary APK
  7a0aa17068c8e11aa951ebf10b8cc80dd395e71d writer-true automatic-true`,
  SHA-256
  `6F94FB2FD31CB4674FF5CB54AF53E536C654C7ECC8C25DDDF3049B4070F6BD60`.
- Local artifact verification reconfirmed application ID
  `com.bluebubbles.messaging.cloudkitcanary`, APK Signature Scheme v2 and v3,
  and the four required ARM64 native libraries.
- Pixel installation: installed in place with `adb install -r`; Canary's
  original install time and data were preserved, the process launched, and
  Alpha's installed state remained unchanged.
- First post-install observation: no startup crash. Two existing queued uploads
  were safely deferred with `cloud_sync_chat_identity_not_disjoint`; projection
  repair and controlled lifecycle proof are still required.

### Pixel semantic repair at 2026-09-08T05:30:32Z

- Exact app source: `7a0aa17068c8e11aa951ebf10b8cc80dd395e71d`.
- The manual read-only run left the outbox unchanged and enabled no remote save,
  remote delete, or tombstone delete behavior.
- Message repair applied 47 retained records. Remaining retained message and
  attachment evidence stayed durable rather than being falsely counted as
  projected.
- Chat backlog classification found 395 retained saves and 81 tombstones. Of
  the saves, 392 were explicitly outside the iMessage projection scope. The
  remaining three reported `decoder_unsupported_service` and remain blocking
  because their identity has not yet been proven disjoint from the authorized
  write candidates.
- The two queued writes therefore remained deferred with
  `cloud_sync_chat_identity_not_disjoint`. The next falsification test is an
  exact, content-minimized identity observation of those three records, not a
  looser admission rule or another broad fetch.

### Large retained sweep at 2026-09-08T06:03Z

- The installed `7a0aa1706` Canary continued a retained-projection sweep while
  backgrounded. Content-free logs showed thousands of message and attachment
  outcomes and no remote save or delete admission.
- At `2026-09-08T06:36:51Z`, the sweep stopped safely with
  `cloud_sync_semantic_report_zone_invalid`. No new report file appeared, so the
  run is not completion evidence even though earlier projection transactions
  remain durable.
- The upload scheduler subsequently admitted zero operations and deferred both
  queued chat creates as `cloud_sync_outbound_chat_existing_history`. This is a
  stronger, later barrier than the earlier aggregate identity-disjointness
  failure: the store found matching local or retained history and correctly
  refused to create another random Chat record.
- Historical evidence identifies the three exact unsupported service labels as
  `iMessageLite`, Apple's satellite-messaging service. Candidate
  `d750467b826c0576717b3255aa6ad960159d399f`
  adds an exact, case-sensitive typed out-of-scope classification across Rust,
  generated bindings, Dart, safe diagnostics, and tests. It does not remove the
  records from writer identity observation and does not authorize either queued
  create.
- Local verification for `d750467b826c0576717b3255aa6ad960159d399f`: 75 targeted converter tests, all 359 Rust
  library tests, and all 42 Rust semantic-decoder Dart tests passed. Exact-source
  GCE qualification, installation, report-invariant diagnosis, and live
  reclassification proof remain required.

### Run 34200238001 and exact Pixel diagnosis

- App source `98ebe6ba4d926ecb57efbd8347c2e729a909cf8d` passed the full GCE path:
  generated bindings, all Dart and Rust suites, rustpush production features,
  protector harness, Canary APK, ARM64 native-library verification,
  GitHub-hosted signing, VM deletion, and runner deregistration.
- The signed APK was installed in place. Canary data and signing identity were
  preserved, and Alpha remained installed and untouched.
- The read-only semantic run preserved every protected source, enabled no
  CloudKit save or delete, and left the outbox exactly `0 -> 0`.
- Chats examined the three prior unsupported saves and typed all three as exact
  `iMessageLite` out-of-scope state. The engine then failed
  `retained_projection_result_invalid` because its older invariant incorrectly
  required `hasRemaining=true` whenever physical retained rows remained. That
  contradicts the intentional contract in which proven out-of-scope rows stay
  physically retained but leave the eligible replay query.
- The same three records emitted
  `native_out_of_scope_i_message_lite`, which was missing from the closed
  diagnostic vocabulary and therefore collapsed to
  `diagnostic_code_invalid:3`.
- The early engine failure left its reported Chat backlog at zero while the
  sampler independently read the correct durable total of 476, producing the
  downstream `retained_backlog_summary_mismatch`. This was an honest failure,
  not a third storage defect.
- Candidate `f19fe8034605117b1bd167757581d5b967645c86` removes only the stale correlation clause
  and adds only the missing fixed diagnostic. It retains nonnegative,
  arithmetic, bound, scope, lease, durable-backlog, outbox, and report guards.
  Focused local proof passed all 185 engine, decoder, and diagnostic tests.
  A broader local directory run was intentionally stopped because this checkout
  lacks `objectbox.dll`; exact full qualification belongs on GCE.
