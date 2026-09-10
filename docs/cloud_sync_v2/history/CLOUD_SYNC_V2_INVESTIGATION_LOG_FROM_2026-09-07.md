---
type: log
title: Cloud Sync V2 Investigation Log from 2026-09-07
description: Chronological qualification results after the current treemap was separated from the historical investigation record.
resource: openbubbles-app
tags: [openbubbles, cloudkit, investigation, evidence, canary]
timestamp: 2026-09-10
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

## 2026-09-09, atomic VM observation and upload integrity

- Full run `34427563744` failed at the write-preparation VM test, before Rust
  tests or APK assembly. The observer published result fields individually,
  so a VM-service poll could see a GUID with status still `pending`.
  Read and write tooling now publish a complete snapshot through one reference
  assignment. A real-VM fixture with a slow result getter reproduces the old
  failure when field-by-field publication is restored and passes with the fix.
  All 15 focused VM tests pass; targeted analysis reports no issues.
- Cleanup for the failed run succeeded. Independent GitHub runner and GCE
  instance inventories were empty. No APK from this run was installed.
- Reviewed the Muse API patch and required identity preflight before file or
  container I/O, a no-I/O empty-batch return, and rejection of empty expected
  signatures. Attachment and group-photo uploads now correlate by record ID
  plus expected signature, not the first matching hash. Identical file bytes
  under distinct records no longer collapse into the first record. Fourteen
  synthetic API tests cover these cases, pending cloud compilation/execution.
- Native dependency `9584f0c28afb31e17a1883d54301ec6faf195341` validates upload
  request identity and the uint32 wire-size limit before authorization. Missing
  authorization fields or receipts return content-free errors instead of
  panicking. Six new tests cover malformed requests, authorization, partial
  receipts, duplicate content, and preserved encryption metadata. Syntax
  parsing passed; Rust type checking and execution remain pending.
- This repairs shared upload primitives, not the full V2 attachment-write
  state machine. Returned record IDs are constructed from local requests.
  An MMCS receipt does not prove a CloudAttachment record was saved, and a
  missing record does not prove an earlier byte upload never happened.
- The existing Muse agent's earlier implementation/report was preserved and
  reviewed. Its accepted read-only follow-up later returned `not_found` with
  no parent close or follow-up result. The exact agent/submission handles were
  sent to the designated repair task. No replacement worktree, task database
  edit, or transcript deletion was attempted.
- Source `925b02181c99985763df7a52d27dcb2b6371559c` and its exact dependency
  were pushed to the user's forks, with no upstream PR created. Full GCE run
  `34434823427` uses T2D-60, primary lane, manual writer/background read on,
  automatic uploads off, and pilot `a35bfc526`. Quota readback showed 100 T2D
  CPUs/500 GB SSD available with zero usage before dispatch. Runner creation
  passed. Compilation, tests, APK/signing, and cleanup remain to be verified.

## 2026-09-09, qualification gate and exact attachment bytes

- Run `34434823427` completed unsuccessfully because a source-contract test
  still searched for `drainConfirmedAndPersist()` without its new budget
  argument. `4479546f4` corrects the search and validates offsets before using
  them. The full production-composition plus real-VM suites pass 42 tests.
  This run passed bridge generation/drift checks and Rust type checking, but
  did not execute native tests or build an APK. Cleanup passed; independent
  runner and VM inventories were empty.
- Isolated pilot `f8520b1ee` collects independent Dart/Rust/protector failures
  in the same run, then requires every selected original step outcome to be
  success before packaging. YAML/Bash/wiring and 23 executable success,
  failure, skipped, cancelled, and missing-outcome cases passed. The official
  GitHub steps-context documentation confirms why `outcome`, not the adjusted
  `conclusion`, is required. No signing or infrastructure configuration changed.
  An initial push used the upstream remote and was denied; the corrected push
  updated only the user's fork. No upstream change occurred.
- Parent rejected the first attachment-reuse claim that saved XML metadata was
  an encrypted receipt: it contains an MMCS descriptor and key saved before
  actual IDS completion, and the Attachment row remains mutable. The chosen
  direction pins the exact sent descriptor in protected state and recovers
  original bytes from MMCS, rather than adding another permanent plaintext
  journal or uploading whichever local file happens to occupy the path.
- Source inspection found the standard MMCS download lane lacked the complete
  target checks already required by closed CloudKit downloads. Parent also
  found `IMessageContainer` ignored short sink writes. Current native repairs
  require complete targets, use `write_all`, and bind successful plaintext
  length to the original descriptor. Their cloud execution remains pending.
- Boundary-key review rejected `state.get_data` as truly lookup-only because
  it calls `ensure_secret` for wrapped entries. The reviewed replacement uses
  the vendored keystore's `get_secret`, an exact DSID under the entry lock,
  and injected AES-SIV tests that never initialize or mutate the global store.
- Typed attachment save/readback is a native primitive, not full V2 upload
  admission. It reuses single-use save ownership, verifies both required
  fields with checked crypto instead of generated default filling, and bounds
  decompression. Protected descriptor staging, upload uncertainty recovery,
  and parent-message dependency integration remain required.
- The old non-Pixel agent's claimed test file was absent from the current
  checkout and Git history. Its stale result was rejected as current proof,
  and the unused agent was closed. Native task history remains evidence;
  no shared session database, credentials, or user data was deleted.
- Reviewed native code was committed/pushed as `a78ccfd25eb324c7561146aff784b4e293ced1c1`
  and pinned by app code `2e89e642c`. Parent rejected the proposed checksum-only
  fanout, retained the existing selector, and required complete target coverage
  instead. Current V2 source recovery will request one pinned descriptor at a
  time; ambiguous duplicate standard Ford references remain an explicit gap.
  All current child handles were closed after review and verified absent.
  No dedicated worktrees were created. Required native task history is retained;
  supported session deletion is unavailable in this tool surface, so no shared
  database or raw transcript deletion was attempted. C: retained over 63 GiB
  free before cloud dispatch, with zero GCE CPU/SSD usage.
- Exact-source full run `34437303360` failed before building with
  `ZONE_RESOURCE_POOL_EXHAUSTED` for T2D-60 in `us-west1-b`. Cleanup succeeded;
  independent GCE and GitHub runner inventories were empty. This is capacity
  failure, not a code/test result. Retried the unchanged source `75440cafc`
  and pilot `f8520b1ee` in `us-west1-a`, run `34437410835`, manual writer and
  background read on, automatic uploads off. Trusted-source validation passed
  and runner creation is in progress; every downstream result is still pending.

## 2026-09-09, actual IDS acceptance versus completed work

- While tracing immutable attachment capture, parent found two meanings of
  `SendJob.handle == None`: finished work and zero destination targets. The
  send worker also reports APSError/TimedOut progress while returning `Ok(())`.
  The old Android receipt bridge and Windows loop treated that completion as
  success proof. This invalidates completion-only claims, not independently
  observed remote CloudKit records or readable history.
- Code `35551340c` with rustpush `2bfbe8a` shares explicit participant acceptance
  across send retries, retains missing intended group participants, and checks
  the evidence only after successful job completion. Status 0 alone qualifies.
  Legacy 5008 semantics are unqualified for V2. A self-send needs an actual
  other-device acknowledgment, not an empty fanout; no read-receipt or Apple UI
  proof is inferred. Ordinary untracked send behavior remains unchanged.
- Protected receipt version/domain 2 distinguishes the stronger evidence.
  Tests cover keeping old version-1 ciphertext intact while rejecting replay
  and acknowledgment. Dart no longer promotes an intent from an untracked
  receipt-less event. Fixed unconfirmed errors do not contain the Dart retry
  trigger. Pre-fix ready/adopted intents are a separate unresolved release gate;
  automatic uploads remain off, with no migration, deletion or blind resend.
- The attachment handoff was reviewed and its read-only worker closed, verified
  absent. Parent rejected storing the only source in the short-lived IDS
  receipt. The protected source still needs adoption and GC ownership. No
  attachment admission was enabled during this investigation.
- A bounded second review corroborated the completion bypass repair. Parent
  incorporated its 5008 and missing-proof observability findings, kept valid
  other-device self-send support, and retained the old-intent migration gate.
  The reviewer was closed after disposition; no worker worktree or scratch
  files were created. Review transcripts remain needed provenance; unsupported
  session deletion was not attempted. C: remained above 63 GiB free.
- Run `34437410835` passed full source qualification through APK/native-library
  and Android JVM tests for `75440cafc`, including 373 app Rust, 253 rustpush,
  and 34 protector tests. Signing/cleanup were still running at observation.
  It does not contain the new receipt repair. New run `34439102945` was rejected
  before VM creation because writer controls require full validation; cleanup
  succeeded, and inventories showed only the existing full-run VM/runner.
  Corrected narrow runs `34439315172` (app Rust) and `34439316836` (rustpush)
  use source `35551340c`, T2D-32, separate bounded lanes, and writer/automatic
  upload flags off. No new APK or Apple credentials are used. Results pending.
- Final readback confirmed full run `34437410835` succeeded including trusted
  signing and cleanup. Independent inventories no longer list its VM/runner;
  only the two new narrow-validation runners remain. Both new runs passed
  trusted-source validation and started builds. Pixel ADB inventory was empty;
  no app was installed and no device data or messages were changed.

## 2026-09-09, persisted IDS proof and a shorter database-test loop

- Parent reviewed the complete read/write flow after the user's status request.
  Media upload primitives are not integrated attachment writes; edits/unsends
  remain gaps. No production claim or narrowed completion gate was made.
- Source `731988a3d` adds one ObjectBox property, IDS confirmation version,
  preserving entity IDs and existing data. Absent proof stays 0; positive native
  confirmation writes 2. New dispatch rejects old proof; exact envelope recovery
  and CloudKit readback remain available without treating readback as IDS proof.
  Old pending entries do not consume eligible-send windows. Nothing is deleted,
  blindly resent, or automatically enabled. Database behavior remains unverified
  until the new regression and actual predecessor-schema tests execute.
- Prior native code `35551340c` completed 377 app Rust and 260 rustpush tests.
  Both GCE cleanup jobs succeeded, and independent inventories showed no VMs or
  registered GitHub runners. Current 27 composition contracts pass; Dart analysis
  reports no errors/warnings (four pre-existing service style infos). Local
  database tests compiled but failed setup with ObjectBox DLL error 126. This is
  not a pass and does not establish a behavioral regression in the patch.
- A bounded worker supplied the predecessor-schema regression; parent corrected
  inconsistent sentinel bindings and missing assertions before accepting it.
  The Windows inventory worker found a signed existing DLL but its exact build
  receipt proves `cf8ae21b61ea-dirty-b3f4575d0e4c`, not the current native code.
  Parent rejected the worker's initial claim that a dirty tree or SAC being On
  alone proves Windows execution impossible. Both workers are closed and verified
  absent; their findings and test source are retained. No credentials were read.
- The isolated pilot is receiving a Dart-only validation lane, with no Android
  build or Rust recompile, to remove the full-APK prerequisite for ObjectBox
  tests. Infrastructure, signing, and existing full qualification stay separate.
  Pixel ADB inventory is empty. Alpha and device data remain untouched. C: has
  over 63 GiB free; no evidence, sessions, or user data were removed.
- The workflow worker's partial patch was reviewed, then the worker was stopped
  and verified absent so parent could finish the immediate critical path. Parent
  corrected input indentation and APK upload/signing exclusions, checked all
  prior-mode step selections unchanged, and verified orchestration, cleanup,
  environment, and signing steps unchanged. Isolated pilot `e4baad9ee` was pushed;
  run `34441590911` uses exact source `423a084250758246f7331501165b498651bcd34a`
  (code `731988a3d`), T2D-32, primary lane, `us-west1-a`, writer/automatic uploads
  off. No production claim, artifact install, or Apple access is implied.
- Parent also kept the broader consumer gate explicit: a lease skip is not proof
  that the shared queue drain lets fresh sends proceed past safe old pending work.
  This must be resolved without skipping unknown outcomes or deleting evidence.

### 2026-09-09: whole-flow queue repair and Windows loop refresh path

- GCE `34441590911` completed: 2,553 Dart tests passed; one predecessor-schema
  fixture failed because property 15 remained below declared lastPropertyId 13.
  Parent corrected the fixture and retained the no-auto-proof assertions. The
  new persisted IDS-proof and upgrade tests passed. VM and runner inventories
  were empty after cleanup. No Apple credentials or phone changes were involved.
- Queue review found three linked gates, not only leasing: shared drain,
  queued Chat observation, and account preflight. A single journal-bound
  read-only classifier now recognizes pristine unsubmitted pre-proof creates
  across those gates. Protected envelopes and journal rows remain unchanged;
  uncertain/retried/leased/malformed work remains blocking. A real consumer,
  admission, ObjectBox transition and reopen test was added with synthetic
  Apple responses. This is not live end-to-end qualification.
- Local queue/composition tests: 59 passed. A Muse test worker's nonterminal
  case originally simulated successful flush, contradicting its expected
  blocked result; parent caught it and the fixture was corrected. Windows
  launcher tests pass. Parent reviewed and refined Muse's build-only patch:
  no app launch, no production Store close, exact writer configuration receipt
  before reuse. Both agents are closed and verified absent. No dedicated
  worktrees were created; their reviewed source and provenance are retained.
- Candidate `e060bcb41` was pushed to the fork and dispatched to Dart-only GCE
  `34443435257` on T2D-32 in `us-west1-a`. The local build-only writer refresh
  failed in 8.9 seconds because Application Control explicitly blocked the
  compiler helper. Its self-signed development certificate verifies, but does
  not satisfy the execution policy. No policy bypass, trust modification, or
  repeated build attempt was made. Receipt remains the old one. Wireless ADB
  reconnected to Pixel; Canary metadata and a no-launch status check were read.
  The diagnostic engine was not ready. Neither app was launched or modified.
- GCE `34443435257` then passed all 2,560 Dart tests, including the new mixed
  ordinary-consumer queue/reopen test and both predecessor-schema fixtures.
  Fourteen semantic-outbox plus three evidence-output cases also passed.
  Cleanup succeeded and independent VM/runner inventories were empty. This
  qualifies code `e060bcb41` at the synthetic-response boundary, not at Apple.
  Next: one full signed Canary qualification build, then the controlled live
  plaintext send/save/readback. No claim of completed attachment writing or
  causal edits/unsends/deletion is made.

### 2026-09-10: installed candidate and user send/edit/unsend observation

- Full signed run `34444190598` completed successfully for app source
  `3dc614c9eced02b49f130a2752ce531d9e6aec7a`, with pilot workflow head
  `e4baad9ee5d7883ad4bb53610ea7720e504eab0e`. Those are distinct provenance
  roles. Build, signing/verification, and runner deletion jobs passed.
- Installed artifact SHA-256:
  `b16dbac5fbd04f838ea6c12ffade4d4b001eeed04f3c70475d1512674735285a`.
  The saved after-install preflight records v2 signature verified, one signer,
  separate Alpha/Canary UIDs and data directories, and Canary update time
  2026-09-09 23:43:18 Pacific. That timestamp was rechecked during this test.
  It explicitly records `sourceCommitDeviceVerified: false`; do not replace
  the unresolved running-build/mode gate with artifact provenance.
- User performed two new tests on the approved direct test conversation:
  send then edit, and send then edit then undo-send. At 12:43:04.168558Z and
  12:44:01.468636Z, the application logged native send confirmation journaled.
  The subsequent local change events were at 12:43:50.025983Z,
  12:44:15.074803Z, and 12:44:20.043559Z. The generic logger calls an unsend
  `state=edited`, so that label alone is not proof of retraction.
- Parent opened only the already-observed approved test conversation and
  visually confirmed the edited bubble and latest unsend notice. No message,
  edit, unsend, CloudKit write, logout, restart, install, or reset was invoked
  by the parent in this observation. Opening the conversation is ordinary UI
  navigation, not a claim that all app activity is read-only.
- Counterexample: before opening it, the conversation-list preview still
  contained the latest retracted message text. Investigate preview selection
  and invalidation separately from remote mutation semantics. Local rendering
  and send acceptance do not establish CloudKit edit/unsend durability.
- Earlier, at 12:38:27Z, a send failed with registration 6005. Subsequent
  tested sends succeeded. Three PCS-zone read-auth failures were recorded
  before the later active semantic pull, which was processing records during
  observation. Do not attribute those earlier failures to the successful
  edit/unsend sequence, or mistake quarantine counts for failed live sends.
- Both ADB status checks reported the semantic pull/coordinator active and
  outbox empty. The semantic summary simultaneously reported idle/no passes;
  this inconsistent progress display is retained evidence, not a completed
  pull. No restart was used to obtain a VM endpoint while the pull was active.
- Private evidence root:
  `C:\Codex\OpenBubblesReview\device-evidence\pixel-write-20260909-3dc614c9e`.
  `send-edit-undo-app-20260910-0547.log` contains the persisted app trace;
  `send-edit-undo-20260910-0546.log` is the bounded live logcat capture;
  `test-conversation-20260910-0552.png` proves the local UI observation.
  Screenshots and raw logs remain private and are not added to Git.
  The first logcat launch rejected an incorrectly grouped PowerShell argument;
  its empty log/error are not test evidence. The corrected capture and
  persisted app log recovered the required event window.
- Screen timeout readback remained 86400000 ms, with charging stay-awake 7.
  Original 1800000 ms is saved in `awake-settings-restore.json` for restoration
  after testing. PIN/keyguard were not changed. C: free space was 70.47 GiB;
  these small captures do not require another large storage cleanup.

### 2026-09-10: Windows build isolation and manual-selection qualification

- Read-only loader check: the existing ARM64 `rust_lib_bluebubbles.dll` loads
  and unloads, and the signed compiler wrapper invokes `rustc --version`.
  Neither operation authenticates, launches the app, or changes its receipt.
- The real `test_cloud_sync_v2_native.ps1 -TestFilter cloud_sync_` attempt
  failed before tests executed. Application Control error 4551 blocked the
  generated `slab-3f53265ea60998f8/build-script-build.exe`; both executable
  aliases have identical SHA-256 and valid Authenticode status. Do not infer
  an unsigned-file, missing-extension, or CloudKit protocol failure.
  Local evidence: `evidence/windows-native-tests/20260910-063634-9b5e75f7`.
- Policy enumeration returned Access denied. No security setting, signer
  trust, or application-control policy was changed. The user approved an
  isolated cloud build environment within $200 of credits through September
  15. At the start of that work, GCE instances and GitHub runner registrations
  were both empty. Existing Linux GCE qualification and a Windows fast-loop
  binary build are distinct jobs; Linux results cannot prove Windows loading.
- The six manual-selection retained-queue tests initially failed in setup
  because the test process could not find `objectbox.dll`. Prepending the
  existing `C:/Codex/Toolchains/objectbox-windows-x64-v5.3.2/lib` to that
  process's PATH resolved it. All six real ObjectBox-backed tests passed,
  and the three changed Dart files passed analysis. No dependency download,
  real message database, app profile, or Apple account was involved.
- The selection now pins journal-proven pristine pre-proof creates while
  permitting a fresh exact selection. Tests reject attempt, proof, account,
  generation, and deletion drift. Pinned rows are not uploaded, acknowledged,
  deleted, or retroactively given proof. Full-suite and live server readback
  remain required.
- Four host argument-array tests also passed. The repaired Pixel helper
  preserves separate arguments with spaces instead of concatenating the
  package option, script, URI, and flags. This is host invocation proof, not
  a device send or CloudKit write result.
- Storage checkpoint: C: had 68.62 GiB free. No cleanup deletion was needed.

### 2026-09-10: isolated suite and companion patch review

- Source `7df4fced8b0d5846039674e5c899e6ed3d8029b6` was pushed to the fork.
  GCE run `34485566441`, pilot `e4baad9ee5d7883ad4bb53610ea7720e504eab0e`,
  uses one T2D-32 runner in dart-only mode. The displayed build job name still
  mentions an APK, but this mode produces none. No Apple profile was uploaded.
  The full run succeeded: 2,566 Dart tests plus 14 semantic outbox and 3
  evidence-output cases. The test step took 3m56s, and dispatch through cleanup
  took 9m06s. Independent GCE inventory and GitHub registration queries both
  returned empty after the cleanup job passed. No actual billing total is
  claimed from elapsed time alone.
- Accepted the FaceTime native log/footer patch after catching and correcting
  its PiP footer regression. Parent checks passed: 54 Kotlin host tests,
  11 Dart diagnostic/export tests, and 10 JavaScript media-probe tests.
  The agent's broader JavaScript count is not substituted for this parent
  result. No Android build, call, or rendered PiP proof is claimed.
- Closed Boole (`01a08b86-f285-70d3-a249-1a4c4c8d2643`) after reviewing its
  patch; the follow-up control reports `not_found`. Shared-tree source and
  review provenance are retained for integration and rollback. No supported
  session/transcript deletion tool is available, and no dedicated worktree
  was created. No shared session database or source tree was deleted.
- Pascal's initial Find My probe was explicitly rejected as usable evidence:
  it had no native read callbacks. It remains uncommitted while the agent
  implements real devices/people reads with retained-account guards. Items
  remain untested; a scaffold-only pass is not a native service result.
- Accepted companion source commits `e3fa462a2` (FaceTime) and `e5e8288c3`
  (Find My People). The latter's 29 publication/merge/refresh tests were rerun
  successfully; the earlier 38 count also included play-sound tests. These
  commits are newer than the completed GCE run and are not installed.
- Windows bundle review identified a useful existing positive FFI test lane:
  `cloud_sync_local_send_encoder_test.dart` can load the produced DLL using
  `OPENBUBBLES_TEST_NATIVE_LIBRARY`. Replaced its restored-group test's
  mock-only cast with the production `decodeMessageproto4` API plus the mock
  adapter implementation. All 47 portable cases pass; the real DLL lane adds
  a legacy/V2 comparison and must run separately. No wire encoder changed.
- Isolated Windows sidecar was reviewed and pushed as pilot `00aca7383`, then
  `36fc1c15b` to derive the build identifier with the real retained launcher
  rather than an incompatible full-SHA assumption. Initial run `34489111897`
  was canceled during SDK setup before compilation. Its replacement is
  `34489497490`, explicitly building source `6c628feb6` and variant
  `local-write`; this run is in progress, not verified successful.
- Registration-only run `34489067885` succeeded. The two unrelated workflows
  triggered by that pilot push (`34489067831` and `34489067790`) were canceled
  and verified terminal, avoiding redundant full-app builds of the pilot tree.
  Subsequent pilot commits use skip-CI messages and explicit exact-source
  dispatch. No default-branch merge, GCE infrastructure change, or secret
  change was made.
- Parent validated PowerShell/YAML syntax and the test JSON protocol against
  all 47 portable encoder cases (47 visible successes, zero skipped/failing,
  terminal success). Native mode must separately prove 48. The sidecar also
  checks lockfile drift, keeps ARM-mutated SDKs out of shared x64 caches, and
  uploads the compressed bundle once rather than duplicating its raw contents.
- Closed Pauli (`01a08b94-1a70-79b2-8b7c-cd113ec6e2be`) after integration;
  the follow-up control reports `not_found`. The two committed pilot files and
  provenance remain; no dedicated worktree was created. Supported transcript
  deletion remains unavailable. C: had 68.58 GiB free; no cleanup deletion.
- Windows run `34489497490` finished failed: 27 focused Dart tests passed,
  but two ObjectBox-backed cases could not load `objectbox.dll` (error 126).
  Native compilation never started; teardown's uninitialized store was a
  consequence, not a new application failure. Pilot `a2680baac` supplies the
  official ObjectBox 5.3.2 ARM64 archive, SHA256-pinned and PE-checked, only on
  the ephemeral runner PATH. Dispatched same app source `6c628feb6`, variant
  `local-write`, as `34491135220`. YAML and embedded PowerShell parse passed;
  no local security policy, production signing, or Apple profile changed.
- Pascal's real Find My adapter replaced the rejected callback-less scaffold.
  Parent accepted the bounded retained-account read design and finite error
  categories, preserving numeric HTTP statuses without bodies or URLs. Parent
  reran 22 focused Dart tests and the launcher contract successfully. Native
  compilation remains unverified; all changes are retained uncommitted and
  excluded from the Windows baseline. Existing Friends 401 token refresh does
  not reissue the request and is not claimed repaired.
- Closed Pascal (`01a08b85-8db6-7032-aa36-9c6263d174b9`) after review, transferring
  remaining native qualification to the parent. No dedicated worktree was
  created; shared source and unique uncommitted work are required and retained.
  Supported transcript deletion remains unavailable. No files were removed;
  C: had 68.54 GiB free.
- Condensed the Windows history on the active treemap and separated installed
  Android code from the new Windows candidate. Preserved prior local policy
  evidence here: events 3033/3077 blocked
  `proc_macro_signing_wrapper_delayed.exe` under policy
  `0283ac0f-fff1-49ae-ada1-8a933130cad6`, despite valid self-signed Authenticode.
  The September 10 recheck could load/unload the existing native DLL and run
  the wrapper's `rustc --version`, but actual compilation still failed on the
  signed `slab` build script with error 4551. No policy or trust change occurred.
- Read-only local preparation confirmed retained hardware/account/streams
  files and no running Windows app. The existing immutable version-2 write
  request targets an authorized test number and already has a claim. Resume
  checks must reconcile that claim without a new native send. No account
  request or message send was performed during this build-environment repair.

### 2026-09-10: qualified Windows startup and fresh IDS counterexample

- Windows run `34491135220` succeeded on source `6c628feb6`, pilot `a2680baac`:
  29 focused Dart cases, 48 real Rust-DLL codec cases, two launcher contracts,
  ARM64 checks and the actual invalid-launch Dart marker. Job 23m27s; Flutter
  compile 15m43.7s. GCE instance and self-hosted runner inventories were empty.
- Verified all 78 manifest files, path safety, lengths and SHA256s. Original
  ZIP SHA256: `25887ebfe37647851687adc329dbd232eba2a136067020f9c128385fc308e910`.
  Preserved source-only cloud provenance and the archive locally. No account
  credentials, message database, or hardware identity went to cloud runners.
- Re-signing ObjectBox produced a locally valid developer signature but loader
  4551; Code Integrity 3033/3077 named the unchanged policy. The old developer
  copy had identical blocked bytes. Original vendor DLL SHA256
  `9c8583c4015ab9e4ce2ed3d2d581811fa059e03bb528cb8c8387adcdfda8d8a5`
  loaded under that same policy. Restored only the new qualified runtime's DLL.
  The blocked copy and prior receipt are retained as evidence/rollback.
- The detached `windows-cloudkit-qualified` checkout uses exact source `6c628feb6`
  and matching local-write receipt. At 15:22:43Z it finished a prior-request
  resume: native confirmation was already retained, admissions/deferred were
  zero and outbox was not blocked. This proves startup/resume, not a new send.
- At 15:32:43Z fresh request `qualification-20260910-03` failed before intent
  creation at recipient lookup with fixed code
  `cloud_sync_windows_sender_bad_authentication`. The old request was preserved,
  new claim is absent, and the process exited. No new native send or remote
  CloudKit save occurred. The current native path already attempts registration
  refresh with the retained IDS user; explicit fresh IDS authentication from
  the retained GSA account is the next distinct action, not a blind retry.
- Added source-only explicit sender-auth refresh input, bound to the immutable
  request, without deleting retained users first or restarting onboarding.
  Claimed requests still skip preparation/sending. Not in the qualified binary.
- Vendor-byte launcher protection and the updated writer/Find My receipt
  contract passed parent tests. All three previously closed agents returned
  `not_found`; shared unique changes/evidence remain retained. C: 68.29 GiB free.
- Parent ran 50 focused Windows harness/write/Find My Dart tests after adding
  explicit repair; all passed, and targeted Dart analysis reported no issues.
  This covers source behavior, not successful Apple authentication.
- Darwin (`01a08bf4-211a-7723-920a-256cc65c0795`, Muse contributor) independently
  reviewed the pending native Find My adapter and bridge signatures. No concrete
  blocker was found; no native build or account access was performed. Parent
  reviewed the cited code, retained native qualification as open, closed the
  agent and verified `not_found`. No dedicated worktree/log artifacts existed;
  its review remains necessary evidence and supported transcript deletion is
  unavailable. No files were deleted. C: 68.26 GiB free.
