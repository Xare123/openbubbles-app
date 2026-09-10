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

### Run 34211915641 and exact Pixel retained-sweep proof

- Android app source `ad822f37cbf468a6bc74d602965e78ae02a852d1`
  passed the build-only GCE benchmark: source-SHA verification, Canary APK,
  ARM64 native-library inspection, GitHub-hosted signing, runner cleanup, and
  VM cleanup. The signed artifact used APK Signature Schemes v2 and v3.
  Generated-binding and full Dart/Rust test steps were intentionally skipped;
  this run is not exact-source full-suite evidence.
- The APK was installed in place over Canary only. Its data and first-install
  time were preserved; Alpha's version and install timestamps remained exact.
- The live semantic pull reached a terminal `partial` result after one remote
  pass with the remote head drained. Automatic triggers, remote saves, remote
  deletes, and tombstone semantic deletes were all false. The outbox remained
  exactly `0 -> 0`.
- The terminal local-projection report retained the same 10,108 durable rows as
  the preceding remote report. Chats completed with all 476 rows explicitly
  outside active projection eligibility: 395 out-of-scope saves and 81 retained
  tombstones. No stale invariant or invalid diagnostic recurred.
- Messages remained degraded with 1,893 blocking saves. The exact sweep found
  586 decoder-ready records, 1,086 malformed records, 216 dependency records,
  and 5 unsupported-service records; no row was silently discarded.
- Attachments remained degraded with 1,693 blocking saves. The exact sweep
  found 1,359 decoder-ready records, 328 malformed records, and dependency or
  ownership conflicts. The physical attachment backlog remains 1,812 including
  119 retained tombstones.
- Host-only source `f826cd400a623b3a759cafe391580731d137ae8b`
  repaired Windows PowerShell native-stderr handling and Android
  SharedPreferences key-prefix parsing in the Canary ADB controller. Thirteen
  focused tests and a live `open-sync` result readback passed.
- The next repair is not another broad fetch. It is a content-free classifier
  for the exact existing-history ownership branches, followed by at most one
  same-revision remote readback under the existing identity and writer-pause
  gates. It cannot adopt, save, delete, advance a token, or mutate ObjectBox.

### Windows retained-message discriminator proof

- The Windows development profile completed a read-only replay with remote
  writes and deletes disabled and its outbox unchanged. Every one of 189 native
  message protobuf failures had the same bounded signature: `msgProto` field 2
  arrived as protobuf wire type 0 while the compiled ordinary-message schema
  expected wire type 2.
- A temporary offline reader copied the ObjectBox database, extracted only
  protected raw-envelope references, and inspected only the unencrypted
  `MessageEncryptedV3.msgType` discriminator after Windows DPAPI unprotection.
  It emitted no message text, sender, chat identifier, GUID, or decrypted
  payload. The source database hash was unchanged before and after inspection.
- The 1,158 retained malformed non-tombstone records partitioned as class 1:
  846, class 2: 118, class 3: 5, class 4: 36, class 5: 1, class 6: 141, and
  class 7: 11. Classes 4-7 total exactly 189, matching the wire-mismatch cohort.
- Apple runtime headers and the repository's earlier protobuf schema agree on
  the discriminator mapping: class 3 is group-title change, class 4 is
  location-share status change, class 5 is message action, class 6 is
  participant change, and class 7 is group action. Classes 4-7 use int64 field
  2; ordinary `MessageProto` uses a string there.
- Candidate `12035ec0cefe73a9d4f7f779d2e9a06c4c7667b0` restores those five
  schemas, selects them by the outer discriminator, preserves the existing
  required-identity presence gate, and retains valid system events as typed
  `UnsupportedMessageType` until projection semantics are implemented. It
  enables no save, delete, token advancement, or inferred system-event update.
- Exact-source full qualification passed on T2D-60 GCE as run `34226323430`:
  2,441 Dart tests, 346 Rust app tests, 223 rustpush production-feature tests,
  and 32 protector tests passed; generated bindings were reproducible; the
  Canary APK built, its ARM64 application and native libraries were verified,
  and GitHub-hosted signing completed. The build job took 28m43s and the full
  workflow took 32m11s. Cleanup verified that both the runner VM and GitHub
  registration were absent. The signed artifact digest is
  `sha256:47221e522f997c84500e0ca993b7e42210190d8c59197e2e138e15e61a517ade`.

### Existing-history classifier and run 34240730080

- App source `1c269b7e1c676fbb4dc7e23ec200ec0e013cf19a` adds six fixed,
  content-free counters for existing local Chat, semantic snapshot, alias,
  prior outbound origin, record-map, and tombstone conflicts. The observation
  does not change admission, failure precedence, storage, outbox, checkpoint,
  or remote-write behavior.
- The focused production-path fixture suite passed 109 of 109 tests. An
  independent audit confirmed that later diagnostic reads remain best-effort
  only after an earlier existing-history result is known and cannot replace an
  original failure.
- Exact-source T2D-60 GCE run `34240730080` passed 2,447 Dart tests, 346 Rust
  app tests, 223 rustpush production-feature tests, and 32 protector tests.
  Generated bindings reproduced, the Canary APK built, ARM64 application and
  native libraries passed verification, GitHub-hosted signing succeeded, and
  runner and VM cleanup completed. Automatic-upload qualification did not run
  because the exact candidate intentionally used `automatic_uploads=false`.
- The GCE build job took 27m15s; the APK build step took 13m30s. The downloaded
  signed artifact is package `com.bluebubbles.messaging.cloudkitcanary`, uses
  APK Signature Schemes v2 and v3, and has digest
  `sha256:31360153479d820a78e4828ee39db2825fb26124f27577febd59e94f85e95f54`.
- The next evidence remains one in-place Canary install and read-only retained
  replay, followed by an exact-intent diagnostic read for the two deferred
  creates. No adoption or retry is authorized by a diagnostic count alone.

### Atomic composer admission and durable IDS receipt

- Commit `d4f618ced` moved eligible plaintext composer admission ahead of the
  queue boundary. The first local Message and its state-0 intent now commit in
  one ObjectBox transaction or both roll back. URL/rich-link candidates remain
  excluded, and automatic CloudKit uploads remain off.
- Commit `51314b83d` added a content-free protected native receipt that is
  synced before Rust emits `SendConfirm`. Dart records IDS success as state 3
  before acknowledging the receipt, and startup replay recovers receipts after
  a process restart without treating a new native session as the old session.
- Replay pages are bound to one exact account fingerprint, protected-store
  identity, native session, Dart state, native client, ObjectBox store, and
  storage path. A transition aborts the page before its cursor advances. Send
  retries retain their original admission fence even if rebuilt payload
  capture is discarded; a pre-admitted composer source change fails closed.
- The focused integrated suite passed 122 tests and the source composition
  suite passed 26 tests. Targeted handwritten analysis found no errors or
  warnings. An independent post-fix static audit reported no remaining
  concrete crash-consistency findings. Full GCE and live process-kill proof are
  still required before automatic uploads can be considered.

## 2026-09-09, background startup and lifetime counterexamples

- Prior GCE run `34423632222` passed its selected suites and produced the
  signed `fc132e5f8` APK. It did not execute Android JVM tests, and source-string
  assertions did not detect the following runtime dependency cycle:
  Dart service initialization awaits `ready`; Kotlin resumed its own waiter
  without replying; the background wake awaits the unfinished service graph.
- The repair acknowledges every ready request before native dispatch and emits
  startup once. Missing callback handles fail before engine allocation. Failed
  or canceled startup disposes only its own unclaimed engine.
- Native waiter cancellation no longer decrements active Dart work. Engine
  leases end on actual reply or synchronous dispatch failure, including late
  and duplicate replies. Delayed disposal rechecks exact engine identity,
  active leases, and idle generation on Main. APNs network callbacks that
  originate on IO are marshaled onto Main before Flutter dispatch.
- The background drain requests cooperative cancellation at five minutes,
  closes further admission, and awaits protected quiescence. The eight-minute
  Android timeout bounds the waiter, not native operation completion. Current
  protected work is never declared stopped or force-destroyed due to elapsed
  time. Late completion remains safe to reconcile on the next wake.
- Focused verification: 26 Android tests (including 16 behavioral ready,
  invocation, and lifetime cases) and 32 Dart controller/policy/composition
  tests passed. Targeted Dart analysis found no issues. Neither result is
  proof of a fresh installed Android lifecycle run.
- The subsequent whole Android JVM suite passed 89 tests across 15 suites,
  with zero failures, errors, or skipped tests. It reused built ARM64 Flutter
  output while compiling current Kotlin and test code, taking 35 seconds.
- Parent review rejected an attachment-upload validation stub: an unwired
  type would not implement uploads. Legacy upload and record save are separate
  operations; a missing CloudAttachment cannot disprove an earlier MMCS upload.
  The upload implementation uses a general container and cannot be borrowed
  without V2 identity and writer fences. Preserve separate uncertain-upload
  and uncertain-record-save states in the upcoming attachment implementation;
  source-level content hashing does not prove server-side upload deduplication.
- Retained-history review corrected the claim that no bounded sweep existed.
  Parent rejected the proposed already-applied replay change: the agent's
  fixture independently seeded an applied marker plus a retained inbox row,
  while production commits replay and inbox state atomically and validates
  exact inbox sequence, payload, record map, and revision. The existing suite
  explicitly requires retaining this conflicting state. No legitimate path or
  live evidence justified weakening that guard. The agent patch and duplicate
  synthetic test were removed, with the original files restored exactly.
  The old 1,893/1,693 live blocking counts remain historical observations,
  not a current recount or a diagnosed single-cause backlog.
- Lifecycle code committed and pushed to the user's fork at `f4ba34d8e`;
  reviewed source `68d5958b5a2d1b12cda75b87887c198e4b80944f` is under full
  GCE qualification in run `34427563744`. Isolated pilot commit `a35bfc526`
  adds selected-flavor Android JVM tests after APK assembly, reuses existing
  ARM64 Flutter output, rejects missing/zero-executed/failing XML reports,
  and retains those reports for seven days. Parent corrected the proposed
  artifact path and verified YAML, Bash, and embedded Python syntax before
  dispatch. No infrastructure, signing, or cleanup policy was changed.
- All three bounded agents were reviewed and closed; supported agent controls
  report their handles absent. Research evidence stays in native task history;
  no dedicated worktrees were created or credential/user-data artifacts deleted.
  C: retained approximately 64.9 GiB free at the checkpoint. Pixel ADB had no
  connected devices, so no install or account mutation was attempted.
