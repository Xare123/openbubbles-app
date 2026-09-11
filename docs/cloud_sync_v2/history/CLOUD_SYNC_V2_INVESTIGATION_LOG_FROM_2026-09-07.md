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
- Committed/pushed reviewed source as app `6abbeede2cf522706d619c16d3aee147d14d6e64`
  and rustpush `f33dcacc043b2a2363a0b8d12e4429bf936b6856`. Preserved unrelated
  CRLF-only modifications. Both Rust files parsed without modification; the
  expanded nine-test Windows local-write suite passed. No native or live repair
  success is implied by those checks.
- Dispatched source-only Windows `34497409120`, GCE app-rust-only `34497413348`
  on primary T2D-32 and rustpush-only `34497413071` on parallel T2D-32, all pilot
  `a2680baac`. Preflight inventories were empty. Regional T2D quota was 100 CPUs,
  SSD 500 GB, and all-regions CPU quota was 164 with zero usage. Combined GCE
  request is 64 CPUs and 200 GB SSD; original exact-instance cleanup and VM
  lifetime remain unchanged. Dispatch succeeded; outcomes still pending.
- Preserved the failed fresh-request status in build evidence as
  `fresh-write-qualification-20260910-03-failed.json`, SHA256
  `51b6fa7b8230f64edb5848fc30fa5e9a6b989763a7f08570ed96319b176e774d`.

### 2026-09-10: native qualification and retained-write evidence audit

- Exact source `6abbeede2` passed 380 app Rust tests in `34497413348` and
  261 rustpush tests in `34497413071`. Both ephemeral-runner cleanup jobs
  succeeded. Independent GCE and GitHub inventories returned zero instances
  and zero self-hosted runners. No APK, Apple session, or production signing
  was used by these runs.
- Windows `34497409120` attempt 1 failed before compilation with dependency
  download authorization (Flutter exit 69). Lockfiles were unchanged from the
  successful baseline. Reran the failed Windows job once, not the passing GCE
  tests; attempt 2 is still running. No guessed package or credential repair.
- Added an offline readback inspector reusing the production exact-intent
  validator. Three ObjectBox tests passed, including rejection of fabricated
  matching flags without real admission authority. Targeted Dart analysis
  passed. A historical request can be selected without replacing the current
  request or launching the native writer.
- With the Windows app exited, inspected request `qualification-20260907-02`
  using a disposable copy of the retained ObjectBox database. One canonical
  message was legible and source-valid, but its IDS proof version was 0 and
  exact-readback marker absent. The outbox was confirmed, but that alone did
  not prove end-to-end write. Saved the content-free result under
  `build-evidence/windows-fast-loop-34491135220/retained-write-proof-qualification-20260907-02.json`.
  Before/after hashes proved the source database, request and claim unchanged.
  The copied database and its generated lock file were removed after close;
  no source data or rollback evidence was removed. Scratch inspection was empty.
- Bernoulli's edit/unsend review identified useful decode/projection entrypoints,
  but parent rejected its conclusion that legacy `save_records(update=true)`
  applies only to chats. `CloudMessagesClient.save_messages` invokes that generic
  path for `messageManateeZone`; `Message.toCloud` serializes `ec/ep/otr/rp`.
  `RustPushService.unsend` and `edit` call the legacy upload paths. These are
  reusable wire primitives, not proof of a safe V2 causal mutation. The generic
  constructor does not set a predecessor record ETag; V2 still needs exact
  conflict, admission, readback and replay behavior. Do not invent schema or
  treat an unnamed historical three-file scaffold as available implementation.
- Parent also rejected the proposed Dart-only acceleration as unproven:
  `-SkipBuild` cannot incorporate source edits, and normal `flutter build`
  invokes the native graph blocked locally by policy. Reusing DLL bytes alone
  does not supply CargoKit intermediates or prove a rebuilt kernel's identity.
  No launcher safety check was bypassed and no local native build was started.
- Rawls reviewed FaceTime guest admission and the possible media/completion
  cycle. Source does not establish a cycle: Android clicks Join before media
  confirmation; Dart completes its correlation ticket after the native answer;
  Rust approval/group progression does not read Android media state. Parent
  accepted this as a negative source finding, not proof that calls work. Latest
  retained logs predate bounded persistent diagnostics and do not classify the
  terminal event. Keep verification intact and capture a future authorized
  call on the diagnostic-enabled Android candidate. No calls or account access
  occurred in these reviews.
- Closed Bernoulli and Rawls after integrating the accepted findings and
  explicitly rejecting the unsupported conclusions above. Supported agent
  controls then reported both `not_found`. No dedicated worktrees existed;
  review evidence and transcripts remain necessary provenance. Supported
  transcript/session deletion is unavailable. No agent artifacts were deleted.
- Accepted Bacon's two bundle-verifier files after parent repairs for strict
  boolean flags, exact native path, safe fixture ownership and actual cloud
  variant identifiers. Parent reran 16 checks, including all 78 files in the
  retained real bundle; all passed. Unsupported replay bundles are rejected.
  Closed Bacon and verified `not_found`. An earlier abandoned synthetic fixture
  contains one zero-byte ZIP and two directories; exact cleanup was rejected by
  tool policy, so retained it without trying another deletion route. Manifest:
  `build-evidence/agent-bacon-cleanup-20260910.json`. Reclaimed zero bytes.

### 2026-09-10: repaired Windows fresh write and restart passed

- Windows `34497409120` attempt 2 succeeded on app `6abbeede2`, pilot
  `a2680baac`: 24m17s job, 945.8s Flutter compile, 30 focused Dart tests,
  48 real Rust-DLL codec cases, launcher contracts and invalid-launch marker.
  Downloaded artifact `10161789903`; verified all 78 files and original ZIP
  SHA256 `ed2e69228661ff1d6f19344ad00f2c8b7038f570dee03f6c359ec5e799f4eb13`.
- Imported to detached `worktrees/windows-cloudkit-qualified-6abbeede2` without
  touching the prior runtime. Signed five binaries with the existing development
  certificate, preserved the pinned vendor ObjectBox bytes, and verified native
  load/unload. A local invalid-launch smoke observed its exact marker and zero
  dummy-profile state files; only that smoke process was terminated after its
  bounded wait. No security policy/trust change or account export occurred.
- Preserved the old build receipt and current unclaimed request before adding
  `refreshSenderAuthentication:true`. Wrote/verified the matching local receipt.
  At `2026-09-10T16:20:53.242725Z`, PID 7536 finished the fresh request:
  `native_send_confirmed=true`, admitted 1, deferred 0, outbox not blocked,
  no pending Chat readback. This is a real authorized test send, not a resumed
  old claim. Sender authentication/registration recovered without new user 2FA.
- With the process exited, the offline inspector independently read a disposable
  database copy: IDS version 2, exact source binding, one canonical legible
  message, exact-readback marker matching admission, released protected receipt.
  `persisted_readback_proven=true`; all source/request/claim hashes unchanged by
  inspection. The marker is set only by the production exact remote-readback
  callback, not generic save success or report cleanup.
- At `2026-09-10T16:22:49.471789Z`, PID 16396 resumed the identical claimed
  request and finished with admitted 0, deferred 0, outbox not blocked. Claim
  bytes and OS-config fingerprint remained identical across restart. The
  repeated offline inspector still found one canonical message and all proofs.
  `save_attempt_count` remained 0; it is not a network-call counter. No new
  admissions or duplicate local test message were observed. The existing-claim
  code path skips sender preparation and native sending, including repair.
- The full `hw_info.plist` hash changed during fresh startup, as `setup_push`
  rewrites APS connection material and saved identity representation. It is not
  proof that hardware identity changed; same-profile account/config fences ran
  and the OS configuration remained stable across the subsequent restart.
- Content-free import, fresh/restart statuses and both proof results are under
  `build-evidence/windows-fast-loop-34497409120`. Retained earlier weaker proof,
  pre-repair failure, old runtime and request remain rollback/provenance.
  This closes bounded Windows direct write qualification only. Independent
  Apple-device display, restored groups, reactions, attachment writes, causal
  edits/unsends, Android convergence/lifecycle and FaceTime remain unqualified.

### 2026-09-10: exact-group qualification and attachment envelope integration

- Found a concrete Windows diagnostic gap: `readExactIntent` assumed one
  recipient even though the ordinary journal supports group plaintext. Added
  a separate exact restored-group selector and version-3 Windows request,
  pinning group GUID, complete member set, sender and immutable message source.
  Sender lookup verifies every requested member using one IDS client. No
  legacy ownership, automatic writer, group creation or unrelated outbox drain
  was enabled; direct request v1/v2 bindings are preserved.
- With the Windows process exited, an explicit disposable-copy inventory found
  zero chats with exactly the two approved test numbers. The source database
  and existing request stayed unchanged. No test request was replaced and no
  message was sent. The current direct-write proof was re-inspected under the
  edited Dart code and still passed every predicate, with one readable message.
- The first parent run caught an invalid duplicate-GUID fixture assumption:
  ObjectBox already enforces GUID uniqueness. Corrected the fixture to assert
  that protection. The subsequent 100-test focused run passed; final group
  additions and native attachment code still require their own qualification.
- Attachment review confirmed reusable native upload and create-only record
  primitives. V2 still needs durable upload staging, protected transport and
  parent dependency integration, not activation of the legacy writer. Parent
  rejected an initial codec comparison that required fetched upload receipts
  and complete Asset bytes to match the submitted upload. Immutable recovery
  bytes and semantic remote-content readback are distinct proofs; download
  credentials can differ while signatures, key, size and metadata remain bound.
- Final parent run: 174 focused Dart/ObjectBox tests passed, including a real
  close/reopen of the synthetic database after group-message admission. Group
  mutation after reopen still fails the protected Chat dependency. One test
  initially expected `StateError`; corrected it to assert the actual typed
  `cloud_sync_local_send_chat_not_ready` failure, without changing the guard.
  Targeted analysis passed across all edited Dart files.
- The native attachment envelope codec is implemented but not connected to
  staging/upload transport yet. Parent fixed record/zone/owner comparison,
  two now-invalid renamed-record test assumptions, and unnecessary duplicate
  serialization. The full original upload envelope remains hash-bound while
  readback uses exact metadata, signatures, key, size and record identity.
  Nine native tests are written; source-only GCE qualification is next. Local
  rustfmt parsing/check passed using the existing toolchain's absolute path.
- Closed both reviewed agents. Feynman's two disposable PowerShell wrappers
  (838 bytes) were removed after exact hash/path/process checks; their source
  tests and review evidence remain. Manifest is
  `build-evidence/agent-feynman-cleanup-20260910.json`. No dedicated worktrees
  existed. Required review transcripts remain, with supported session deletion
  unavailable. The previously rejected zero-byte fixture removal was not retried.
- Committed/pushed reviewed source as `955d8acada99c9b051d59a5d6998cc0cb7b02f1a`
  with automatic CI skipped. Explicit GCE `34505595606` targets that source on
  pilot `a2680baac`, `t2d-standard-32`, primary lane, `app-rust-only`, writer and
  automatic uploads false. Runner creation passed and dependency setup was
  live. No account data was exported, no APK was built/requested, and the local
  qualified runtime/request remain unchanged. Follow this exact run through
  native tests and cleanup before claiming native qualification.

### 2026-09-10: native attachment qualification and randomized-upload recovery

- GCE `34505595606` completed successfully on exact source `955d8acad`: 389
  native tests passed, including all nine attachment envelope/readback cases.
  Cleanup succeeded. Independent GCE and GitHub inventories returned zero
  instances and zero self-hosted runners. No APK or account-data transfer.
- Source review distinguished byte-upload completion from attachment record save.
  It also confirmed `prepare_put_v2` generates random chunk keys, FORD key and
  IV even for identical file bytes. Restoring only a filename, content signature,
  or record name cannot restore the original preparation. A complete protected
  preparation snapshot is necessary before starting the byte upload.
- Parent is integrating an exact upload plan with parent GUID/source hash,
  full record identifier, metadata, file digest and original preparation. Two
  bounded Muse tasks cover snapshot serialization and protected-purpose staging.
  Neither a staged plan nor record NotFound grants upload-retry authority. The
  actual IDS-descriptor journal, durable upload attempt, transport and parent
  dependency remain required; no new write path is enabled by this slice.
- Implemented source-only pre-upload staging and completed-attachment staging
  on distinct protected purposes, with committed-lease, digest and identity
  checks on upload-plan reopening. Preparation hashes the same bytes in the
  same pass as lookup-only MMCS preparation. A fixed preparation-unavailable
  error is distinct from protected-store failure. No raw keychain error escapes.
- Reviewed Faraday's snapshot code and added the parent plan tests. Snapshot
  decode validates FORD AES-SIV metadata and chunk-key/length consistency;
  no regeneration, logging, file I/O or network permission is built into it.
  Rejected the review suggestion to strip the original completed Asset's
  transient fields: the recovery envelope deliberately retains the full
  original upload, while remote readback uses the separate stable witness.
  The review's absent IDS provenance is a real remaining integration gate,
  already explicit in the tree, not authority supplied by this native plan.
- Ptolemy's patch attempts failed because numeric unified-diff hunk headers
  were interpreted as literal source context. Parent applied the reviewed
  stage/open changes with bare `@@` headers. The repair task independently
  confirmed the grammar error; no permission/security changes were needed.
  Rejected a proposed test asserting attachment protobuf cannot parse as the
  chat protobuf: those fields share wire types and unknown fields are ignored.
  Actual protected-purpose separation is tested instead.
- Both agents were closed with supported controls and verified `not_found`.
  No dedicated worktrees, sessions or disposable agent files were deleted.
  Reviewed source and required transcripts remain; session deletion is not
  supported. Free C: space remained about 66.6 GiB before cloud qualification.

### 2026-09-10: exact source ownership and journal retention

- Previous goal work produced evidence, not merely a status restatement:
  exact source `11de45796` / rustpush `f041db67` passed GCE `34508598558`
  (397 app Rust tests) and `34508602298` (265 rustpush tests). Both cleanup
  jobs succeeded. Independent inventories returned no instances or runners.
- Current critical path is the protected actual IDS attachment descriptor,
  not another direct test send. The existing content-free IDS receipt can be
  acknowledged before upload admission, so that receipt cannot be the only
  owner of descriptor recovery material. No personal account was accessed.
- Added nullable `CloudSyncLocalSendIntentEntity.protectedSourceBinding`:
  property `16:5377428623302990429`, preserving all preceding UIDs. Synthetic
  old-schema pending/deferred/adopted rows reopen with null binding and no
  inferred IDS acceptance. Parent reviewed generated source and normalized
  generator-added trailing whitespace only in `api.freezed.dart`, after
  proving it had no substantive change.
- Journal adoption is write-once before IDS success, validates exact local
  account/store/message/source, and is idempotent only for the same binding.
  Existing plaintext captures remain unchanged. The protected reference and
  lease now participate in GC and recovery liveness; malformed origin binding
  stops cleanup. Outbox adoption v3 includes the source binding when present,
  retaining the exact preexisting v1/v2 bytes for null-source rows.
- Parent tests initially had three incorrect exception matchers (closure
  compared directly to StateError); repaired with `throwsA`, not changed
  production guards. All 204 combined journal/schema/store/binding tests then
  passed, and targeted static analysis reported no issues. Another 128
  lifecycle/restored-group/chat-origin regression tests passed. Neither suite
  proves live attachment sending or native OS protection.
- Actual attachment composer capture, source-bound positive IDS receipt,
  durable byte-upload attempts and parent-record dependency remain integration
  work. Do not enable them by removing the existing plain-text-only guard.
- Source inspection found the next concrete seam: `IMClient.send` calls
  `MessageInst.prepare_send`, which always replaces `sent_timestamp` and may
  add sender/conversation routing fields. The source-bound receipt must check
  final descriptors, not claim that pre-send capture proves unchanged wire.
  A focused validator for these three known preparation changes may avoid
  redesigning the send API; preserve exact body/recipients/descriptor identity.

### 2026-09-10: native source review and prepared-message validation

- Parent reviewed both agents' source and schema changes. The final eight-suite
  Dart run passed 398 tests, including source substitution after database reopen,
  old-schema compatibility, journal retention, lease lifecycle and group origin.
- Parent corrected a native test that passed the original single GUID while
  expecting a count mismatch. Added actual group/profile roundtrip coverage,
  unknown protobuf/plist rejection on recovery and committed-lease roundtrip with
  account/source/digest mismatch cases. Eleven native tests are written, not yet
  compiled or passed. Rustfmt and `git diff --check` passed.
- Added a minimal prepared-message validator against the real rustpush
  `prepare_send`: preserve the entire body and descriptor, allow only generated
  missing sender GUID, appended self participant and timestamp inside the native
  send interval. A positive IDS result remains independently required. No network
  sender hook or positive receipt integration was enabled in this slice.
- Accepted Goodall's code after parent fixes and the integration-map locations;
  rejected its proposal to put the attachment payload digest in `guid_hash`.
  That field must retain message-GUID identity; source binding needs its own
  versioned field. Accepted Ramanujan's additive schema and regression work.
- Both workers used the shared worktree, so no dedicated worktree is disposable.
  Their source, test evidence and transcripts remain needed; supported transcript
  deletion is unavailable. No user data or build evidence was removed by parent.
  C: had 64.78 GiB free; cloud instance and GitHub runner inventories were empty
  before the next source-only run. No local Cargo build or account access.

### 2026-09-10: qualified capture and source-bound native receipts

- Source `8bbffb1ab` qualification first hit `ZONE_RESOURCE_POOL_EXHAUSTED` in
  `us-west1-b` for T2D-32 (run `34513644167`); no compiler ran, cleanup passed.
  The existing N2D-16 / `us-west1-a` option then passed run `34513911095`: all
  408 app Rust tests, including all 11 capture/stage/prepared-message cases.
  The full workflow and cleanup completed successfully. No APK was built.
- The next slice extends receipt version 3 with an explicit optional source
  binding, preserving v2 encoding and the GUID/account/store/session receipt
  identity. Replay and acknowledgement compare that binding. Kant's focused
  native patch was parent-reviewed and accepted; no dedicated worktree/files
  were removed. Shared source and required transcript evidence remain retained.
- Parent added the source-staging API with exact current native auth binding,
  committed-source preflight in `send`, and post-`prepare_send` verification.
  A mismatch after positive IDS acceptance returns a receipt error, not a send
  failure or automatic resubmission instruction. Two synthetic native API tests
  exercise these seams without accessing any Apple account.
- Dart now checks the native source binding against the journal before native
  receipt resolution/promotion/acknowledgement. Missing or different source
  proof cannot promote an attachment-bearing origin. Original v2 text receipts
  remain valid when the journal has no attachment source.
- This newer API/receipt integration is uncompiled and needs bridge regeneration
  in the next source-only run. Composer attachment capture/adoption and durable
  CloudKit upload attempts remain unfinished; no production enablement occurred.
- Committed source/API slice `389465734` to the fork and dispatched source-only
  GCE `34515270061` on the known-working N2D-16 / `us-west1-a` configuration.
  Writer and automatic uploads are false. Binding drift is expected because this
  introduces an additive bridge type/field; review the generated artifact before
  committing it, then run the Dart journal/receipt regressions against that API.
  All three used child agents were closed and independently returned `not_found`.
  C: remained about 64.8 GiB free; no local account/device data was accessed.

### 2026-09-10: receipt boundary qualification and attachment reflection

- GCE `34515270061` compiled source `389465734` and ran 414 native tests:
  413 passed, including all new source-bound receipt/API cases. The one failure
  was `native_seam_source_has_no_frb_or_serializable_raw_dto`, which correctly
  rejected the added derive on the content-free binding. Parent removed the
  general serialization implementation in favor of explicit versioned receipt
  fields, preserving the unchanged source guard and nested-field validation.
  Added malformed nested shape/type cases. This repair awaits requalification.
- Generated bridge artifact `10167797226` is retained for exact-source import
  and review. No APK or account-bound test ran. The failed workflow's cleanup
  completed; independent GCE and GitHub inventories both returned zero runners.
- Source inspection found that normal attachment reflection changes local GUIDs
  and placeholder characters. Both upload finish and reflection use the same
  `saveAttachment` representation of the MMCS descriptor. The next composer
  identity must compare ordered descriptor contents and text, tolerating only
  these expected UI transformations. Legacy `getAttachmentMeta` also derives
  Apple's attachment GUID from the reflected local alias; V2 must preserve the
  corresponding parent references instead of using a pre-send temporary GUID.
- Two bounded Muse workers handle bridge import/tests and the attachment-body
  comparison helper. An Astra worker examines one offline-testable FaceTime
  establishment/retry defect, with parent approval before edits. No personal
  device or Apple account is being exercised by these workers.
- Parent reviewed the generated API/codec changes and imported artifact
  `10167797226`; all 398 targeted Dart tests passed against the new bridge.
  The pilot workflow head differs from the app source by design. Native job
  `102999506731` explicitly checked out and verified source `389465734` at
  18:37:46Z, resolving the import worker's provenance concern. Its reviewed
  source and test log remain retained; the completed bridge worker was closed.
- Source `da428b635` commits the receipt boundary repair and reviewed bridge.
  Source-only GCE `34517138488` requalifies it on N2D-16 / `us-west1-a`, with
  writer and automatic uploads disabled. No APK is requested.
- Astra found and repaired a separate FaceTime teardown defect: the native
  timeout handler ignored its event call UUID and could finish or discard a
  newer call. Exact nonblank ID matching now gates activity and cache cleanup
  independently. Parent reviewed all five changed files and the activity's
  existing instance-bound `onDestroy`; accepted the patch. Worker tests passed
  58 Kotlin, 9 Dart and 10 JavaScript cases, including an A/B stale-timeout
  trace and a production wiring regression that failed before the fix.
  Android runtime and the reported media-establishment cutout remain unproven.
- GCE `34517138488` completed successfully for source `da428b635`: all 414
  app-native tests and generated-bridge reproducibility passed. Cleanup passed;
  independent GCE and GitHub inventories returned zero instances/registrations.
- Parent connected explicit attachment-body identity to journal capture,
  reflection/reopen validation and source-bound native confirmation. Plaintext
  hash domains and admission remain unchanged. Generic completion APIs cannot
  qualify an attachment source; receipt and auth-store bindings remain required.
  All 401 tests in the eight journal/schema/admission/lifecycle suites passed.
  The worker's additional helper test initially failed to compile and is under
  correction; it is not counted as qualified. Production composer/uploader
  calls remain disabled until stage/adopt/commit is integrated and tested.
- Parent reviewed the helper's before/after wire fingerprint and independently
  ran helper plus journal: all 110 tests passed, including descriptor replacement,
  wire-message replacement and in-place MMCS/list mutation during serializer
  awaits. Together with the unchanged seven suites above, this qualifies 428
  targeted cases. The earlier helper syntax failure is resolved. This proves
  identity/journal behavior, not production attachment upload or device UI.
- Source checkpoint `4652d2e41` commits that reviewed identity slice. Parent then
  wired composer capture, pending persistence, local source stage/adopt/commit
  and native receipt context. The coordinator never owns exclusion during IDS;
  busy history sync currently rejects preparation promptly with pending state
  retained, which remains a production usability gate rather than silent success.
- Concrete restart counterexample: a new MMCS upload changes encryption material,
  while rebuilding ConversationData/profile from the current Chat can change the
  original wire. Journaled attachment retries now retain their descriptor; a
  native-only reconstruction helper and same-account/store/session/GUID API
  restore the exact committed source. Generated bridge and native tests pending.
  Parent's pre-bridge composer/journal/retry run passed 120 tests. The staging
  worker reports nine behavioral tests passed before the new API reference; the
  final combined run must await generated bindings. No APK or account access.
- Native source `4164ea77160218111d49290a4ee84d6dfe00c225` is pushed to the
  fork and under source-only qualification in GCE `34521476151` (N2D-16,
  `us-west1-a`, app-rust-only, writer and automatic uploads false). Four new
  native reconstruction tests cover exact round trips, optional/profile fields,
  multi-part groups, drifted routes/descriptors and invalid input. Parent also
  added auth/GUID/store/digest and uncommitted-lease rejection to the native
  preflight test. Rustfmt syntax checks passed; Cargo results remain pending.
- Parent accepted the two bounded workers' source after review. Curie's native
  work is committed above; shutdown independently returned `not_found`. Cicero's
  staging tests additionally prove both gates remain held through adoption and
  commit with exactly the retained reference. Their final execution awaits the
  generated retry API. Shared source and necessary evidence are retained; no
  dedicated disposable worktree exists and no transcript-deletion tool is used.
- GCE `34521476151` verified source `4164ea771` and passed all 418 native
  tests, including the four new reconstruction cases. The only failed step
  was expected generated-bridge drift. Parent reviewed artifact `10170133961`:
  additive restore API, paired generated dispatch-ID shifts and content hash;
  no manual generated-code edits. Imported the seven artifact paths (three
  have substantive changes). Cleanup passed and independent GCE/GitHub
  inventories both returned zero instances/registrations.
- Parent ran all twelve targeted Dart suites against the imported API:
  475 passed, including all ten staging cases. Analysis of the eight changed
  Dart source/test files found zero errors and four existing brace-style infos.
  This closes offline composer stage/adopt/commit qualification, not remote
  upload/save or Pixel UI proof. Cicero's reviewed source is retained and its
  shutdown independently returned `not_found`. No personal data was accessed.
- Next integration is a separate durable upload-attempt phase followed by the
  existing immutable final record-save outbox and parent dependency. Parent
  rejected treating a preparation plan as an existing final save envelope or
  using a missing CloudKit record as permission to replay an uncertain upload.
  Original randomized preparation must stay bound across every transition.
  Known production UX gaps remain: history-sync exclusion can reject a pending
  attachment send, and source reuse alone does not prove that a retry after
  positive IDS acceptance skips another IDS submission.
- Composer/source checkpoint `42647ee3a8ce00f0e2b226db0126b390b5209ee3`
  passed GCE `34523305646`, including the bridge reproducibility gate. Cleanup
  completed; independent inventories returned zero instances and registrations.
- Next candidate introduces a dedicated content-free upload-attempt entity
  instead of changing the existing immutable record-save envelope. Parent
  implements origin/epoch/generation-checked transitions, same-attempt late
  receipt handling, atomic final-outbox handoff and protected lease retention.
  Bounded workers own additive schema/migration tests, behavioral journal tests,
  and the one-attempt native upload owner. No account/device data is used.
  Parent independently compared the generated model: all 25 prior entities
  remain exactly unchanged, with one new entity (number 34). Compilation,
  migration and complete upload wiring remain pending for this newer candidate.
- Parent reviewed the upload journal and independently passed 220 targeted
  Dart cases: 13 new real-ObjectBox upload cases plus migration, store, source
  staging and local-send journal coverage. They prove begin-once across reopen,
  exact late receipts, atomic save-outbox handoff/rollback, reset/account/store
  rejection and retained plan/result leases. Analyzer reports no issues for
  the three affected journal/store source files. These are synthetic tests,
  not an Apple upload or a real-profile migration.
- Native dependency `975015f32b17655705c5b267397411bd80efa899` adds a single-use
  prepared upload owner and one identified authorization plus bounded MMCS
  transfer, without record creation or blind replay. Parent reviewed all three
  paths, corrected an invalid source-contract assertion and ambiguous wording,
  and passed Rust syntax parsing. Native compilation remains pending. The
  app adapter validates and rewinds the exact retained source handle while
  restoring its original randomized preparation. No user credentials enter CI.
- FaceTime source `a266fe0f2` fixes an independently reproducible media-sampling
  race: a connection closed during asynchronous stats collection no longer
  masks a remaining live connection. Parent reviewed the patch and reran all
  12 JavaScript tests successfully; the worker also reports 58 Kotlin cases.
  This is evidence-selection qualification, not proof that calls now connect.
  The worker was closed and independently returned `not_found`; reviewed
  shared source and necessary test evidence are retained.

### 2026-09-10: upload identity and final-record integration

- Exact checkpoint `78a872dda` passed 419 app-native tests and bridge
  reproducibility in GCE `34526397409`. Dependency `975015f` passed 269 tests in
  `34526397036`. Both cleanup jobs succeeded; independent inventories returned
  zero instances and zero registered runners. Job labels still say APK but
  validation modes were app-rust-only and rustpush-only, with no APK/signing.
- Parent reproduced a journal rejection with real `CloudOperationIdentity`
  output: the old validator expected bare hex, while production uses `op1:`.
  The corrected validator requires the exact attachment initial-create ID.
  All 221 targeted Dart cases then passed, including atomic rejection/rollback
  for foreign operation IDs. The added cross-language fixed vector and journal
  also passed a focused 15-case rerun; analyzer reported no issues.
- The pending native candidate retains both original upload UUIDs in version-2
  protected plans. Version-1 material remains readable without manufacturing
  a new request. Attachment record prepare/readback now uses the existing
  single-use, capability-fenced consumer and exact stable-content witness.
  Authentication/transport failure remains unresolved, not record absence.
  Native compilation and generated-bridge qualification are still pending.
- Reviewed Muse source adds descriptor-bound metadata selection and local
  plaintext verification. Parent removed duplicated reader/metadata conversion,
  corrected test types and rejected a default-timestamp restriction. Dependency
  `f2e8ea3` retains the same immutable handle after original-key/signature check.
  Actual canonical parent-part mapping and immutable-file orchestration still
  need integration; none of these helpers alone authorizes network upload.
- Astra reviewed the retained FaceTime trace: admission is recorded, but the
  post-admission media progression and terminating event are missing. No new
  speculative handshake patch was made. Its 12 JavaScript cases passed again;
  parent checked the evidence and closed the worker, verified `not_found`.
- C: has approximately 65 GiB free. No storage cleanup was needed or performed.
  Shared source, unresolved evidence, user data and credentials are retained.

- Checkpoint `d8136c9b9` compiled and passed 428 app-native tests in GCE
  `34529635517`. Only the expected generated-bridge drift gate failed. Artifact
  `10173280244` contained exactly the seven permitted generated files; hashes
  matched after import. Dependency `f2e8ea3` passed 275 tests in `34529638374`.
  Both cleanup jobs passed and independent VM/runner inventories were empty.
  Parent also reran six targeted Dart suites: 222 passed. No APK or Windows
  executable was built, no account data entered CI, and no live send occurred.
- Parent invalidated the worker's claimed GUID-construction evidence gap:
  `rustpush_service.dart::indexedPartsToAttributedBodyDyn` explicitly creates
  `msgId_fieldIdx`; `reflectMessageDyn` uses an empty initial body. The native
  MMCS part may differ from indexed-part idx, as the existing fixture already
  demonstrates (idx 1, MMCS part 0). The revised helper removes caller-provided
  mappings and projects actual fieldIdx, rendered-attachment counting, skipped
  iris/SMIL, and run removal. Seven synthetic cases await the next native run.
  Retained capture/restore semantics are unchanged.

- Parent reviewed Attachment-specific prepare/readback and completed the worker's
  missing mutation-guard recovery branch. The real generator-built operation
  identity and original save UUIDs/references remain bound. Exact record absence
  resolves final-save uncertainty, not successful save or byte-upload replay.
  All 113 transport/guard cases passed independently; the worker's four-file
  analyzer reported no issues. Shared code is retained; worker closed and
  independently verified `not_found`.
- Native plan staging now opens the exact protected IDS source, checks the
  selected file against its original MMCS descriptor using an OS-cleaned private
  snapshot, derives actual reflected metadata, and prepares one randomized V2
  plan under the exact warmed container. Account/store/session/container are
  revalidated before staging. No public byte-upload consume path is added yet.
  Parent corrected the snapshot's initial over-read to the strict size-plus-one
  bound and added a counterexample test, removed a duplicate dev dependency,
  and reviewed the seven snapshot cases. Native compilation remains pending.
  Snapshot worker closed and independently verified `not_found`; required shared
  source/evidence retained. Supported transcript deletion is unavailable.

- Checkpoint `04a0d6384211e19e9aeaa6f70b6f79f531e696aa`: N2D run
  `34532630728` failed before compile with `ZONE_RESOURCE_POOL_EXHAUSTED`.
  Cleanup passed and both inventories were empty before retrying on T2D-32.
  Replacement `34532764241` passed 441 native tests; only expected bridge drift
  failed. Artifact `10174428804` contained the seven expected generated files,
  all imported with exact SHA-256 matches. Cleanup passed, independently zero
  instances/runners. No APK, signing, live account data or remote write involved.
- Parent added the real ObjectBox completed-upload admission path: upload row,
  original record map and pending final save are one transaction. Restart does
  not re-admit or allocate another record. Leasing revalidates the same upload
  journal and original positive IDS source; generic stores cannot dispatch these
  saves. Five new behavioral cases cover handoff/reopen, incomplete-read rollback,
  unuploaded/unknown rejection, mandatory journal at dispatch and changed-origin
  rejection. All 340 cases across eight targeted Dart suites passed after bridge
  import. Three changed source/test files analyze cleanly. Full runtime uploader
  and parent-message dependency remain open, not claimed by these component tests.

## 2026-09-10, native byte-upload execution and completed-result recovery

- Parent connected original-plan reopen to the immutable IDS-verified file and
  one-shot native upload owner. Prepare/consume/recover bridge APIs retain the
  exact account/store/session/container and reuse the record-save mutation-fence
  validator. The byte upload has its own durable identity, not a fabricated
  final-record operation. No live upload or new runtime has been requested.
- The native claim is made before upload; successful completed-envelope bytes
  are protected before staging the result or returning to Dart. A lost response
  or revoked fence retains the receipt. Recovery revalidates its exact asset,
  metadata, record name and parent-source hash against the original plan.
- The Dart journal does not retain the transient plan envelope length. The new
  resume reference accepts its actual five persisted fields and keeps committed
  lease, bounded native read, complete payload hash and semantic identity checks.
  Added a real protected-store reopen test, not just a constructed DTO fixture.
- Muse's receipt-store draft provided the encryption contract and six synthetic
  tests. Parent found and corrected the cross-process claim race caused by Unix
  rename replacement, directory-symlink traversal before containment checks,
  and whole-file reads after a racy length check. Added no-clobber publication,
  partial-claim and symlink tests, plus four shared native-consumer behavior tests.
  This new batch is source-only until isolated GCE qualification completes.
- Muse protocol audit reviewed rustpush `f2e8ea3`: CloudKit upload authorization
  has original request/operation UUIDs, but MMCS generates its own fresh request
  UUIDs (`mmcs.rs:1098`, `2095`, `2136`). Existing chunk states/receipts are content
  deduplication, not evidence of safe ambiguous replay. Parent verified the native
  upload timeout/receipt/asset-shape boundary at `cloudkit.rs:5778-5817` and kept
  unknown attempts fenced. A missing final record is not an MMCS status query.
  Research agent reviewed and closed, independently verified not_found.

## 2026-09-10, native compile repair and upload evidence/authority separation

- Runs `34536416793` (T2D-32/a) and `34536976956` (N2D-16/b) exhausted
  zonal capacity before compiling. `34537137418` (C4D-16/a) instead failed
  the C4D family quota, currently zero. Do not retry C4D without a separate
  quota approval. No quota or infrastructure configuration was changed.
- N2D-8/c run `34537334179` successfully provisioned and compiled source
  `9a503bbf2`, then failed at three native integration errors: two optional
  failure classes passed to a non-optional mapper, and FRB's automatic opaque
  result getter requiring a clone of a deliberately single-use upload owner.
  Corrected optional mapping and explicitly non-opaque result serialization;
  the owner itself remains non-cloneable. These source repairs await rerun.
- Artifact `10176146633` was downloaded only for diagnosis. Its generated
  files were not imported because they reproduce the failing result getter.
  Cleanup succeeded and independent inventories returned no VMs or runners.
- Added native completed-receipt verification without restaging: it binds the
  original plan/attempt/source and live auth, returns content-free completion
  hashes, and preserves an already-adopted result lease. Synthetic tests check
  missing completion, original-attempt matching, wrong plan, and repeated
  inspection without receipt-file changes. No live account operation occurred.
- Parent and Muse identified a runtime mismatch: mutation fencing advances the
  writer epoch but upload recovery re-entered the new-send epoch check. Astra
  confirmed it affects read, late receipt retention, final admission and dispatch.
  Repair direction: immutable original evidence survives epoch rotation; new
  byte attempts remain strict, and final saves need current stable authority.
  No old row, plan, epoch, or receipt is rewritten. Unknown upload isolation
  still requires proved native quiescence, not a Dart timeout or absent record.

## 2026-09-10, completed-upload recovery qualification

- N2D-8/c run `34538305947`, exact source `0ef0b3099`, compiled the regenerated
  bridge and passed all 457 Rust library tests. Only the bridge-drift gate failed.
  Artifact `10176572039` contained exactly seven expected files; SHA-256 checks
  matched each downloaded file to its imported repository counterpart.
- The combined eight targeted Dart suites passed 386 cases after import. They
  cover historical source evidence across writer E/E+1/E+2, fresh authority for
  final admission, exact completion/attempt/result/fence matching, missing
  receipts, identity changes and restart persistence. No uncertain upload is
  replayed merely because its receipt is absent.
- Astra reviewed the native inspection API, journal authority separation and
  guard release without finding a concrete correctness bug. Reviewed agents
  were closed and shutdown verified. Shared source and necessary evidence remain;
  no supported per-agent session deletion was available.
- Cleanup completed successfully. Independent GCE and GitHub inventories were
  empty. No Apple credentials or messages were uploaded, no live account writes
  occurred, and no APK/runtime was installed. Runtime attachment execution and
  parent-message integration remain required.

## 2026-09-10, attachment integration review and cross-layer identity repair

- The ordinary writer now receives the exact attachment journal/checkpoint
  generation. Queue processing is Chat -> Attachment -> Message, with exact
  readback before advancing. The 110 targeted queue/runtime/composition tests
  passed. This does not execute attachment bytes or admit their parent yet.
- Parent review rejected the first executor draft as unqualified: two undefined
  native-client type references, unknown-result marking after the mutation guard
  released, auth not rechecked after lease commit, and insufficient pinning of
  the pre-prepare durable source/plan. The same worker is repairing its two
  files with adversarial tests. No production enablement occurred.
- Native body review found incorrect success/failure fixtures for Dart's
  first-use index eviction, plus a gap between explicit UTF-16 starts and the
  sequential lengths serialized by NSAttributedString. The worker is correcting
  both before native qualification. The source inventory returns original and
  reflected GUIDs plus the canonical key, never text or media credentials.
- A cross-layer counterexample was found: upload/final-save code hashed the raw
  Apple attachment GUID, but canonical ingestion and parent references hash the
  owner message and part. The candidate unifies those identities without changing
  the established read path. Previously staged differently keyed plans remain
  evidence, not authority for silent rekeying or replay.
- These changes are pending exact-source GCE validation and bridge regeneration.
  Apple credentials and stores remain local. No APK or live-account write ran.

## 2026-09-10, attachment identity and executor qualification

- Exact source `ef1d45cf2645192ece672c3a1b6f54d48e6e1ee3` passed all 475 Rust
  tests in N2D-8/c run `34541849568`. Only generated bridge drift failed.
  Artifact `10177858701` contained the seven expected generated files; each
  source/destination SHA-256 matched after import. Cleanup succeeded, with
  zero GCE instances and zero GitHub runner registrations independently checked.
- The parent-reviewed executor, upload journal, real persistent mutation guard,
  three-zone queue, production adapter/composition and exact-selection tests
  passed 195 cases together. Review fixed null/throwing auth capture cleanup,
  original-source/plan pinning, result identity checks inside authorization,
  and receipt-context storage binding. Journal-owned leases survive failures;
  an unknown result retains the real guard fence and blocks another consume.
- The reviewed executor worker was closed and shutdown verified. Shared source
  and required evidence remain; supported dedicated session deletion is absent.
- Next implementation: native source-bound parent envelope with unchanged
  plaintext/reaction gates, plus original-plan coordination before upload.
  Source credentials and messages remained local. No live write or APK install.

## 2026-09-10, original-plan coordination and parent-header contract

- Added the bounded plan coordinator: inspect the pinned native source, validate
  the full inventory before staging, reuse retained plans, adopt/commit new plans
  once, and preserve ambiguous adoption/commit outcomes. Parent review corrected
  an invalid UUID-only assumption: reflected IDs are `<messageGuid>_<part>`.
  Source/auth are explicit callback inputs and the inventory is frozen.
- Added header-only encoding for the native attachment-parent route. It checks
  the retained source digest against the current local message and leaves text
  and attributed bytes absent, for reconstruction from the original native IDS
  source. Existing direct plaintext encoding shares its unchanged header logic.
- Parent-run encoder/coordinator tests passed 57 cases; targeted analysis found
  no issues. The coordinator worker was reviewed, closed and shutdown verified.
- Astra is implementing native source-bound parent staging, reopening and exact
  readback. Review requires reuse of the existing bounded typedstream decoder
  where possible; group parent routing and runtime child-dependency admission
  remain open. Header tests are not native group-send proof.

## 2026-09-10, native attachment-parent candidate review

- Reviewed source-bound staging, prepare and reconciliation across the four
  native files. The API requires the exact committed original-source context;
  ordinary plaintext/reaction validation remains separate. Readback compares
  original protected bytes, allowing only the established CloudKit Date roundtrip.
- Reused the existing bounded typedstream decoder instead of adding another
  parser. Semantic comparison rejects unknown/duplicate attributes and extra
  fields. Archive versions remain byte-bound rather than semantic authorization.
- All four native files passed syntax parsing and scoped diff checks. Nine
  synthetic tests are added but require cloud compilation/execution. Restored
  group routing and runtime child-readback enforcement remain required work.
- Native plan adapter plus coordinator passed 10 targeted Dart cases, with no
  analyzer issues. These use a generated-API mock, not an Apple account.
- No APK install, live write, credentials upload or Alpha changes in this batch.

## 2026-09-10, native parent qualification and composed writer review

- Exact source `787869904153e0a2da96c2da0cf476a4442b05a6`, GCE
  `34544585837`: 484 Rust tests passed. The only failing step was generated
  bridge drift. Artifact `10178805496` supplied the seven expected files;
  every source/destination hash matched after import. No APK was built.
  Cleanup succeeded, with zero instances and runner registrations independently
  verified. Generated files are local pending the next reviewed commit.
- Parent reran the composed admission, journal, dependency, native transport and
  production adapter/composition suites: 278 passed. Subsequent timeout,
  mutation-guard and transport subset: 42 passed. Counts overlap.
- App integration now prepares original plans, uploads children, drains Chat,
  Attachment and Message records in order, and requires a persisted complete
  child-readback proof before admitting the containing Message. Existing
  plaintext, reaction and group-text routes keep their own validators.
- Parent review identified an actual retention-state alias: immediate receipt
  release after a save could resemble exact readback. Commit, transition and
  generic-clear paths now reject that state for journal-owned Attachment creates.
  Real ObjectBox negative tests exercise those paths.
- The unknown-outcome guard constructed a separate Message input and omitted
  its attachment source context. It now receives the same original journal
  source as prepare/readback; account/store/session/directory drift keeps the
  mutation fence armed. Chat and Attachment records do not consult this reader.
- Composition review found a timeout self-wait: record draining inside tracked
  preparation could quiesce the outer operation waiting on that drain. A small
  coordinator now ends preparation before draining, then validates child
  readback. The regression test explicitly waits for preparation quiescence.
- Restored-group parent proof and epoch-resume composition remain open work.
  A failed test compilation overlapped an unfinished worker edit, not a native
  failure; testing resumed only after the source compiled again.
- The treemap's repeated build chronology was condensed to current boundaries;
  earlier evidence in this history file remains intact. No live writes, APK
  installation, Alpha mutation, policy bypass or credential transfer occurred.

## 2026-09-10, FaceTime trace sufficiency tooling

- Added an offline, Windows-compatible reader for the existing content-free
  native FaceTime trace format. It reports complete lifecycle capture separately
  from increasing inbound media bytes on the same peer after admission.
- Parent review corrected the initial classifier: a completely captured failed
  call does not require successful media. Pre-admission counters cannot prove
  later media progression. Parent-run analyzer plus existing probe/bootstrap
  suites passed 51 tests. The reviewed worker was closed and shutdown verified.
- Retained pre-probe evidence cannot establish the missing current lifecycle.
  The Windows qualified harness opens FaceTime externally, not in the Android
  WebView. Next diagnosis needs a new native trace from the probe-enabled build;
  this tool is not a FaceTime fix. No calls, installs or policy changes occurred.

## 2026-09-10, retained group-parent integration

- Reviewed and pushed native candidate `d5b31d5b991343470c45790081ecdbda8973e1a2`.
  GCE `34547723829` runs app-Rust-only on N2D8 in us-west1-c. Previous run was
  terminal and the instance inventory empty before dispatch. No signing,
  APK build, account credentials or message data are part of this run.
- The native group proof comes from cached protected Chat decoding under the
  existing read pause. It preserves the distinction between group GUID and
  opaque Chat ID and revalidates exact source/auth/expiry before submission.
- Dart opens that proof per operation, releases the read pause before staging,
  and recaptures its source after awaits. Unknown-outcome reconciliation uses
  the original adopted dependency, not a mutable Message. Integration remains
  unqualified until generated bindings and combined tests are complete.
- Parent independently passed 63 exact-selection/readiness tests and a
  257-test store/admission batch before this group wiring. Counts overlap
  prior suites and do not establish live write behavior.
- Review caught a regression in the new dependency reader: ordinary adopted
  plaintext/reaction rows have no attachment wrapper and must return null,
  while source-bearing rows must validate the current protected store.
  The worker is correcting this before qualification.

### Native prepared-owner release and attachment recovery, September 10 evening

- Group source `d5b31d5b9` passed 490 Rust tests in GCE `34547723829`.
  Native release source `590cf25bb` then passed 493 in `34548927310`.
  Both workflows failed only the generated bridge consistency gate, not
  native tests. The latter used the existing N2D-16 selector and finished
  including cleanup in about 10.4 minutes. Neither built an APK.
- Imported artifact `10180257648` into the seven explicit generated paths,
  after checking current files matched the previous imported artifact.
  All destination hashes matched the new artifact. The generated change
  exposes idempotent release of an unconsumed native prepared owner.
- Independent post-run inventories showed no GCE VMs or GitHub runners.
  No account data, credentials or signing material was uploaded.
- Parent qualification of admission, parent transport and retained-epoch
  tests passed 98 cases with one remaining receipt-marker fixture failure:
  `cloud_sync_local_send_adopted_mapping_changed` during leasing. This is
  not evidence of successful end-to-end retained-parent receipt release.
- Two reviewers confirmed the state-1 recovery gap: provenance uses the
  original writer epoch, while current mutation authority advances after
  reconciliation. Plan a scoped resume retaining every original plan and
  refusing missing inventory or ambiguous byte-upload retries. Removed
  adapter-lifetime epoch rejection; per-pass identity/epoch fencing and
  native quiescence remain. Composed recovery qualification is still open.

- Subsequent frozen qualification passed **100 tests** across plan coordinator,
  upload executor, retained-epoch, parent-dependency and upload-journal suites.
  The marker fixture now seeds the exact persisted mapping as well as its
  operation header. The resume path retains the original epoch/plan across
  restart, and a started/unknown attempt still cannot prepare or consume again.
- Added `resumeExistingPlans` with complete native-derived inventory validation
  before any plan-lease commit. Missing or partial inventory cannot enter the
  existing missing-plan staging loop. The executor opts into one retained first
  attempt only when supplied that complete inventory; ordinary attempts stay
  strict. Parent's four-file targeted Dart analysis passed.
- Lifecycle review rejected a Dart inference that a returned consume result
  proves its owner was taken. Native ProtectedStorage failures can return
  without taking it. Always ask the idempotent native release after settlement.
  Also require blocked-release/late-prepare quiescence coverage and release
  when post-prepare lease renewal fails. These are not yet qualified.
- FaceTime reviewer found no additional evidence-backed offline source repair.
  The control layout fix already exists, and 51 analyzer/bootstrap/probe tests
  passed. A full probe-enabled device call trace remains necessary to identify
  the media disconnect. No call was made; reviewer closed and shutdown verified.

### September 10, recovery composition after native qualification

- Parent fixed the missing retained-group flag and connected the ready chooser
  to old protected attachment origins only. Original epochs stay immutable;
  ordinary old plaintext and future-epoch origins remain rejected. The current
  owner and complete child readback are independently checked at adoption.
- Parent ran the release/admission/adapter cohort: 125 passed, including all
  20 native-transport/engine release cases. The journal/coordinator/executor/
  engine cohort passed 292 actual tests; one additional requested test path did
  not exist, so that invocation exited nonzero. Seven-file analysis was clean.
- Receipt-only recovery now precedes record queue admission, including an empty
  outbox. Verified clearance ends the old pass; a new pass requires completed
  native cleanup and an independent unchanged-account/store check under a newer
  stable V2 owner. Nine standalone orchestration tests passed. Runtime and
  selection tests also passed; combined qualification is pending.
- Parent review rejected counting all historical uploaded/adopted rows against
  the 64-attempt discovery bound. Only unresolved attempts may consume this cap.
  The guard owner is correcting this with a settled-history regression.
- The composed epoch cohort found two missing canonical Chat fixtures and an
  obsolete empty-ready expectation. These are being repaired without relaxing
  production dependency checks. No APK, account write or cloud run in this pass.

- Final parent cohort: **868 passed across 24 suites**, two local test workers,
  about 40 seconds of test execution. This includes the corrected 20-case epoch
  suite and exact guard recovery with 65 settled historical uploads plus one
  pending attempt. Readback/discovery never stages a replacement or admits an
  outbox operation. One redundant promoted-string cast was subsequently removed.
- Remaining full-flow gaps are explicit: a newly ambiguous byte upload needs
  its own exact-fence scheduling handoff into receipt-only recovery; older ready
  origins without complete retained plan inventory still defer. Stable E+2
  rollover alone does not solve these. Independent Apple display, supported
  edit/undo writes, read backlog closure and native FaceTime media remain open.
- Reviewed Jason and Gibbs contributions and closed both workers. Shared source,
  test evidence and sessions are retained for provenance and unfinished work;
  no supported session-deletion control is available and no dedicated worktree
  was proven disposable. No files deleted. C: remained approximately 62.4 GiB free.

- Reviewed integration committed and pushed to the fork as `927977c693a9f644a5e2f0f5a2feb12711ff2019`.
  Analysis of all 33 changed Dart source/test files passed after removing two
  unused fixture declarations and normalizing string construction. Unrelated
  generated/platform/native working-tree changes were preserved and not staged.
- Dispatched exact-source `dart-only` GCE run `34553546240` on the existing
  N2D-16/us-west1-c primary lane. Pre-dispatch checks showed zero VMs and zero
  GitHub runners. Writer and automatic-upload flags are false; no APK/signing
  or account data in this run. Pending full-suite and cleanup verification.

### September 10, full-suite failures and composed upload recovery

- GCE `34553546240` finished: 2,951 Dart tests passed, three failed. The two
  historical local-send upgrade fixtures retained property 16 under declared
  last-property IDs 13/14. The transport construction contract omitted the
  reviewed local IDS-source lease composition in `rustpush_service.dart`.
  This is not a green release. Fixture/contract repairs are under review.
- Cleanup completed at 02:21:02Z September 11. Independent GCE instance and
  GitHub runner listings were empty. The run took about 11.1 minutes including
  cleanup, with no APK, signing, account credentials or live writes.
- Parent connected exact pending-upload scheduling after quiescence. The
  wrapper reacquires the V2 interlock, checks the same account/store/client,
  and asks the same guard to validate its own attempted upload and E fence
  against unknown E+1. This schedules a new receipt-first invocation only.
- Parent added a real guard/consumer/recovery composition test: a lost response
  invalidates the consumer's owner, cleanup precedes scheduling, and the next
  empty-outbox pass performs one receipt lookup, no second upload and no
  admission when the receipt is absent. The guard/adapter cohort passed 77
  tests; eight changed-file analysis passed. The 14 PowerShell outbox-contract
  cases and three evidence-output cases also passed without device operations.
- The retained coordinator now stages missing inventory entries under a
  current permit while preserving all existing plans. Parent requested a
  stronger partial-plan fixture with fixed [A,B] inventory interrupted at E,
  then resumed after reopen at E+2; expanding the native inventory between
  invocations was not sufficient evidence for that case.
- Post-compaction lifecycle check found 45 earlier child handles absent from
  the active set. Dirac and Schrodinger remain assigned to the required CI
  repairs. Sessions/evidence are retained; no supported session deletion is
  available. C: had approximately 62.7 GiB free; nothing was deleted.
- Final parent cohort passed **936 tests across 28 suites**, two workers,
  54 seconds of test execution. This includes both historical upgrade repairs,
  the gated lease-only construction contract, fixed [A,B] partial-plan recovery,
  exact unknown-upload scheduling and receipt-first consumer composition.
  Analysis found one redundant cast and four string-construction style notices
  in the new fixtures; parent applied mechanical fixes for recheck.
- Reviewed both workers' changes, retaining production auth and native receipt
  checks. Closed Dirac and Schrodinger; both returned `not_found` on follow-up.
  Shared source, necessary test evidence and sessions remain preserved; no
  dedicated disposable worktree or supported session deletion was available.
  No account write, call, APK build or installation occurred in this checkpoint.
- Mechanical fixture cleanup recheck passed: 21 tests in the two touched suites
  and no analyzer issues. All 12 changed Dart source/test files are now analyzed
  clean. Diff checks passed; C: retained approximately 62.6 GiB free.
- Reviewed source committed/pushed as `0ff8e559516e243cfa8d8e7242dcc454667c485c`.
  GCE `34555255259` runs the full Dart suite on that exact source using the
  existing N2D-16 primary lane, with writer/automatic-upload flags false.
  The previous run was terminal and both inventories empty before dispatch.
- Reviewed the existing isolated Windows ARM64 sidecar before requesting a new
  runtime. Current source adds three attachment-header tests; the default
  mock-backed file has 50 passing visible test events, plus one native-only
  legacy comparison. Updated the exact native gate from 48 to 51 in isolated
  pilot commit `9c63ab24d340a9de80879f1bf2ce0e5fd43159cc`, not the feature branch.
  PowerShell parsing/diff checks passed. No infrastructure or signing changes.
- Windows run `34555641336` builds `0ff8e559516e243cfa8d8e7242dcc454667c485c`
  with `local-write`, automatic uploads disabled, on the existing ephemeral
  GitHub ARM64 host. It must pass the 51 tests against its actual packaged DLL,
  PE/hash/provenance checks and invalid-launch observation before import.
  No active Windows run was replaced. Account profiles remain local and the
  original vendor ObjectBox DLL must remain untouched during import.
- At 02:43:58Z both exact-source runs were live: GCE executing the full Dart
  suite, Windows setting up Flutter. Neither is yet a successful build or
  live CloudKit proof. Windows's explicit outbound harness still supports text
  requests only; attachment-request support is needed for its live attachment
  vertical test unless an existing retained attachment intent can be selected.

### September 10 evening, exact-source qualification and Windows attachment entry

- GCE `34555255259` completed successfully on `0ff8e5595`: 3,016 Dart tests,
  14 semantic-outbox cases and three evidence-output cases passed. Full Dart
  execution took 5m39s; cleanup finished at 02:47:11Z September 11. Independent
  GCE and GitHub runner inventories returned empty. No APK/native build or
  account operation occurred in this dart-only job.
- Windows ARM64 run `34555641336` also passed on exact `0ff8e5595`, pilot
  `9c63ab24d`: 30 focused Dart tests, both PowerShell contracts and all 51 visible
  codec tests against the packaged Rust DLL passed. Parent independently counted
  51 successful, zero failed/skipped events. Job duration was 22m21s, Flutter
  compilation 872.4 seconds. The invalid-launch Dart marker was observed, with
  no account/profile side effects. Parent verified 78 files, ARM64 PE headers,
  the archive and every manifest hash without extracting into an account runtime.
  The bounded archive/provenance are retained under
  `build-evidence/windows-fast-loop-34555641336` outside Git.
- Parent added explicit Windows request v4 for deterministic tiny PNG/text
  attachments. It uses ordinary MMCS upload, the existing local-send journal,
  original protected IDS source staging, positive native send completion and
  exact-intent production upload/child/parent admission. No native API, account
  reset, automatic-send flag or prior request binding changed. A claimed request
  skips upload and IDS send on restart. Unknown IDS completion still requires
  reconciliation, never a guessed acknowledgment or automatic resend.
- Astra review found a concrete prior production bug: the upload source callback
  searched the transient `Message.attachments` list after the journal reloads
  from ObjectBox. The callback now resolves the exact `dbAttachments` relation;
  original/reflected aliases and exactly-one cardinality remain required. Eight
  real-store reopen cases reject missing, ambiguous and transient-only sources.
  Parent reviewed the three-file fix and accepted it.
- Muse supplied bounded synthetic fixture helpers. Parent required actual PNG
  decoding, profile-root link rejection, length-before-read bounds and honest
  link-test skips before acceptance. No user file is accepted by this harness
  input. Shared source and necessary agent evidence are retained.
- Parent combined qualification passed 121 tests across six suites; all eight
  changed integration Dart files analyzed clean. The fixture's 15 tests and
  two-file analysis passed at worker review. Bundle verifier tests passed 17/17
  and removed only their 14 synthetic files and 11 empty scratch directories.
  Its native-codec expectation is now explicit (51 current, 48 only when the
  caller explicitly requests the historical baseline), never trusted from
  bundle metadata alone. The real 0ff8e5595 archive passed this verifier.
- The old manual-selection agent was still listed by the environment. Parent
  checked its idle task and reviewed final scope; its test is already committed
  as `7df4fced8` and included in the full suite above. Shutdown was requested and
  verified `not_found`. No exclusive disposable worktree or supported session
  deletion was available; its integrated tests and provenance were preserved.
- Parent reran all 15 fixture cases (zero skipped) and analysis successfully,
  including actual image decoding and root/intermediate link rejection. Both
  current workers were reviewed, accepted and closed; both handles then returned
  `not_found`. Shared source and necessary evidence/transcripts remain retained,
  with no supported session deletion or exclusive disposable worktree available.
  C: had approximately 62.6 GiB free. No account write, call or install occurred.
- The explicit native-send await and post-send account recheck passed the
  17-test Windows/transport contract recheck. Reviewed integration committed and
  pushed as `3ebcc81c9c9aeac7164103e2260e7d19c94ae4fe`; unrelated dirty generated
  and source files were not staged. The current-source total is 136 targeted
  Dart cases across seven suites, with clean analysis of all ten changed Dart
  source/test files; repetitions are not additional unique test coverage.
- Dispatched exact-source GCE `34557585998` (N2D-16/us-west1-c, dart-only) and
  Windows ARM64 `34557587481` (manual local-write variant), both on existing
  pilot `9c63ab24d`. Prior runs were terminal-success, with no GCE instances or
  registered runners before dispatch. Automatic uploads remain disabled; no
  credentials/profile data enter either cloud job. At 03:12:54Z both new runs
  were queued. Recheck these exact handles; do not redispatch on observation
  timeout. No new live attachment save/readback/restart proof exists yet.

### September 10 evening, latest full suite and local runtime preparation

- Exact-source `3ebcc81c9` GCE `34557585998` passed 3,042 Dart tests,
  14 semantic-outbox cases and three evidence-output cases. Cleanup completed
  at 03:23:38Z September 11. Independent GCE instances and GitHub runner
  inventories were empty. This was dart-only, with no APK or account access.
- Prepared clean detached checkout `windows-cloudkit-qualified-3ebcc81c9`
  for the matching Windows cloud bundle. The old runtime, private profile,
  hardware and claimed `qualification-20260910-03` request remain unchanged.
  The current build `34557587481` is still compiling; no live attachment test
  has run. A bounded import script is staged under that run's private evidence
  directory and will verify every archive file, preserve the ObjectBox vendor
  bytes, qualify startup, and preserve the previous launch receipt.
- Astra's bounded FaceTime review confirmed that the Windows harness has no
  call operation and the JavaScript diagnostic harness uses fake peers. Its
  51 offline tests pass, but cannot reproduce remote ringing/admission/media.
  Parent checked the operation enum, desktop browser handoff and native log
  export path. Fresh probe-enabled Android native call evidence remains the
  next discriminator. No speculative FaceTime patch was accepted or applied.
  Reviewer closed and shutdown verified; necessary report/session evidence
  retained, with no supported session deletion or dedicated disposable files.

### September 10 evening, first image send and isolated diagnostic loop

- Windows run `34557587481` completed successfully (23m50s; Flutter compile
  928.7s). Parent verified the archive, all 78 files, 51 actual native codec
  tests, native load and isolated invalid-launch rejection. Existing engineering
  signing preserved the vendor ObjectBox DLL. No PC security policy changed.
- Imported `3ebcc81c9` into its clean detached runtime. Initial image request
  failed on IDS 6005 before upload/send. One explicit refresh using retained
  same-account and same-hardware credentials succeeded; the request was still
  unclaimed when that refresh was selected.
- At 03:40:53Z September 11, image request
  `qualification-20260910-attachment-04` had positive IDS confirmation but
  CloudKit admission returned admitted=0, deferred=1,
  `cloud_sync_unknown_failure`, outboxBlocked=false. The now-claimed request
  must never be changed or sent again. Prior plaintext request 03 is preserved.
- Read-only inspection opened a disposable database copy. The exact image
  intent has state 1, a valid protected/local source and fixture metadata,
  zero upload-plan rows and no parent operation. Source database, request and
  claim hashes stayed unchanged; the wrapper removed only its generated copy.
  This narrows the failure to before plan adoption, not remote readback.
- Source `1d9de8629` adds a closed native-error mapping at the attachment-plan
  adapter. Three native preparation messages map by exact equality; approved
  fixed codes survive, arbitrary content becomes a stage-specific fallback.
  No retry, authority or send behavior changed. All 32 targeted tests passed
  and analysis was clean. Only the two Dart source files and their test were
  committed; unrelated dirty files remained unstaged.
- Preparing a separate Dart-only overlay from clean detached source
  `windows-cloudkit-dart-1d9de8629` with the verified 3eb native bundle. Original
  runtime and profile receipt stay unchanged until fresh qualification. The
  actual native cause and image save/readback/restart remain unproven.

### September 11, Dart-only overlay qualification and preparation-auth cause (IN REPAIR)

- Current runtime source `1d9de8629793824fad8295c888609af8a3a09687` is a separately qualified Dart-only kernel overlay of the existing signed native `3ebcc81c9` bundle, isolated source C:\Codex\OpenBubblesReview\worktrees\windows-cloudkit-dart-1d9de8629. Evidence: `C:\Codex\OpenBubblesReview\build-evidence\windows-dart-overlay-1d9de8629\local-qualification.json`, `overlay-provenance.json`, `attachment-resume-status.json` (bulk manifest not dumped).
- Exact claimed image `qualification-20260910-attachment-04` resumed, no second IDS send. Latest 05:30:03Z September 11 status: `native_send_confirmed=true`, `admitted=0`, `deferred=1`, reason `cloud_sync_attachment_preparation_auth_unavailable`.
- Known native `warm_attachment_writer_preparation_lookup_only` failed BEFORE the upload-plan stage. That code is generic over container/zone/PCS/identity errors, not confirmed bad Apple credentials. Parent investigates now.
- Parent found the concrete mismatch in `rustpush/src/icloud/cloudkit.rs` `validate_writer_pcs_lookup_scope` line 3611: it matches only `chatManateeZone` and `messageManateeZone`, while the warm attachment path always passes `attachmentManateeZone`, so it deterministically returns `CloudKitSemanticOperationDenied` before PCS lookup. No credential reset corrects that. Parent is adding the exact attachment zone plus behavioral regressions, awaiting test/live verification. Mark `SOURCE-IMPLEMENTED` only once that parent patch lands; currently `IN REPAIR`.
- 32 targeted tests passed, committed `1d9de8629`. Qualification: source/native checks, same SDK, dummy launch, unchanged profile, kernel SHA in manifest. Scripts initially had Git-wrapper case-insensitive recursion (parent killed the exact process), internal assemble empty-output list, and packaging PowerShell filter bug; compiler succeeded, parent fixed lookup and packaging recovered using recorded kernel/input hashes; all native files unchanged. No inflated success; image save/readback/restart remain unproven.

### September 11, attachment-zone fix dispatched (pending)

- Fix committed as app `62221f9c2fab1a85780cc2b4a938ca1525c476d3` (`fix(cloudkit): unblock attachment writer preparation scope`) on dependency `d201fb5e7443e8dc5a0d6f4b460f74f58229ee1c`, pushed fork only.
- Isolated runs dispatched: rustpush GCE `34567149795` (T2D-60 primary), app-Rust GCE `34567150925` (T2D-32 parallel), Windows ARM64 build `34567152272`. All pending; nothing claimed passed.
- Before dispatch: no VMs/registrations, quotas 92/100 T2D and 200/500 SSD, existing 75-minute lifetime/cleanup unchanged. No APK, new account, or sending action. Active runtime stays `1d9` until a new bundle qualifies.

### September 11, rustpush CI test-compile failure and test-only fix (pending)

- Rustpush GCE `34567149795` FAILED on the new test only: E0616, private field `CloudKitState.dsid` at `cloud_messages` 4118. The production patch compiled; the test suite did not run.
- Parent fixed the fixture with `*state = CloudKitState::new(...)`. Test-only dependency `fdced92b7ff94dbb923cd48a5b711605b044218f`, app `c206428a30a9ad1b2d9a53ac392c48350ed7ba58` (app commit verified locally); new rustpush GCE `34567564253` pending. Windows `34567152272` and app-Rust `34567150925` continue on the `62221f9` fix since only the `#[cfg(test)]` body changed, so no rerun.
- Failed-run cleanup SUCCESS; independent inventory shows the failed runner absent, with the expected app-Rust VM active. Push-triggered generic duplicates Build `34567150152` / Windows `34567150137` / Bindings `34567150154` verified cancelled (no APKs/redundancy); the explicit new CI still runs despite the test commit push-only `[skip ci]`.

### September 11, native attachment-zone qualification

- App-Rust GCE `34567150925` completed successfully on `62221f9`: 493 tests
  passed, including the fixed-vocabulary preparation-diagnostic test. Bridge
  regeneration/check passed. Cleanup succeeded; its VM and registration were
  independently absent afterward.
- Dependency GCE `34567564253` on test-only successor `c206428a3` passed 276
  tests at 05:54:36Z, including the real cached attachment-warm call and all
  three writer-zone scope cases. Its cleanup is still in progress at this
  checkpoint. The only change from the Windows build's dependency is inside
  the `#[cfg(test)]` identity fixture; no production behavior changed.
- Windows run `34567152272` is still compiling the `62221f9` runtime. The new
  detached checkout and reviewed import script are staged, but no bundle was
  imported and no new account operation ran. Exact image claim 04, source,
  previous runtime and profile receipt remain retained.
- Parent reran the database-inspection helper's five tests and analyzer:
  all passed. Its attachment output is diagnostics only and cannot claim
  persisted child readback merely from upload rows or an IDS success.
- Next-gate review confirmed that raw server etags already exist in native
  save receipts and exact fetches. The missing edit/unsend work is conditional
  update admission/encoding and reconciliation, not discovering etags from
  scratch. Do not copy the legacy pre-reflection update path into V2.
- All three sidecar agents were reviewed and closed, then returned
  `not_found`. Shared patches and necessary reports/transcripts were retained;
  there was no exclusive disposable worktree or supported session deletion.
  C: had about 58.8 GiB free; no user data or evidence was deleted.

### September 11, live byte upload and missing recovery roots (IN REPAIR)

- Windows `34567152272` succeeded on `62221f9c2`; Flutter build took 865.9 seconds.
  Parent verified 78 manifest files, 51 actual native codec tests, retained vendor
  ObjectBox hash, native load/unload, invalid-launch rejection and unchanged
  protected profile files. No policy changes or account material went to CI.
  Both GCE runs above finished cleanup; independent VM/runner inventories were empty.
- Exact image 04 resumed once. At 06:11:34Z it stopped as `invalid_checkpoint`.
  Disposable-copy inspection found a valid original source, positive IDS
  confirmation, one canonical message, one adopted upload, and one matching
  pending Attachment operation with attempt count zero. No parent operation or
  child/parent readback proof existed. Request and claim were not modified.
- Root cause: ObjectBox retained upload leases but omitted plan/result references
  from the complete liveness snapshot. Native committed-receipt recovery requires
  retained receipt entries to be a subset of that snapshot, and maps the
  mismatch to `invalid_checkpoint`. This was not an Apple password rejection.
- Five real ObjectBox reopen tests, covering every upload state, failed on the
  missing plan reference before repair. App `db27373d9` adds both roots, row
  validation and bounded accounting in 13 production lines. All 184 upload,
  ObjectBox and protected-lease tests passed after repair. Readback is still open.
- Isolated overlay source `17818cd3d` is exactly native-qualified `62221f9c2`
  plus the two-file Dart/test repair. It preserves native inputs and generates
  only a new kernel. Initial assembly used a 13-character source label; the
  canonical 12-character launcher check rejected it before profile mutation.
  The build label now derives from the pinned source; corrected assembly is
  being qualified. Failed assembly and prior runtime remain evidence.
- Astra FaceTime and Find My tasks were interrupted, not completed. Parent
  recovered their persisted findings and resumed the same task IDs through
  supported app controls. FaceTime is reviewing a missed close-on-notifier fix;
  Find My is fixing stale People projection. Neither is live-verified. The
  Find My read-only probe cannot use a writer build and does not cover Items;
  Items currently invoke a writer-capable key-alignment path, so that API must
  not be mislabeled as a read-only probe.

### September 11, qualified overlay advances the retained child

- Corrected canonical overlay `17818cd3d0b4-local-write` passed qualification
  against unchanged native `62221f9c2`. The failed 13-character-label assembly
  was not launched. Protected profile hashes and vendor binaries were preserved.
- At 06:42:35Z the retained image 04 pass failed with `cloud_sync_unknown_failure`.
  Offline inspection of a disposable database copy found one matching confirmed
  Attachment operation, cleared receipt lease and a positive confirmation time.
  Its generation and record binding match the adopted upload. No parent Message
  operation exists. Attempt count zero alone cannot distinguish a prior remote
  record lookup from a newly submitted save. Full attachment proof remains false.
- Parent extended the offline inspector with exact-account/zone child diagnostics;
  all five tests pass, including wrong-account/zone and unknown-query cases.
  Original request, claim and database remain unchanged by inspection.
- Find My Astra patch `c77b5def4` was reviewed and integrated as `5515d92c4` for
  the next app candidate. Parent reran all 47 Flutter tests successfully. Only
  same-person identity is reused across handle-less updates; fresh location and
  explicit revocation replace stale state. Valid ungeocoded locations are labeled
  available. Actual account coordinates and missing Items are still unproven.
- FaceTime candidate `9cfd45dee` passed parent reruns of 64 JavaScript and 65
  Kotlin tests, but is NOT integrated. Deeper native review showed all-inactive
  participants after LeaveEvent are not authoritative termination under partial
  snapshots/browser handoff. Parent rejected that automatic-ended addition and
  requested its removal. Explicit Leave/native End repair remains a candidate;
  the same Astra task is separately repairing the early-Join/timer ownership race.
- Two existing Astra tasks remain assigned to required follow-up. No additional
  agents, APK builds, account resets or evidence deletion occurred. C: had about
  57 GiB free at parent review.

### September 11, shared result receipt and successful Windows attachment pass

- Fixed-code allowlist `468a72e4f` added 34 reviewed attachment diagnostics.
  The qualified `d3e0a6c60` pass still failed as unknown. It was not evidence
  that the allowlist repaired the underlying write.
- Content-free source attribution `c2022aa38` passed 41 targeted tests and ran
  as qualified overlay `05e603992`. At 07:28:49Z its trace identified
  `cloud_protected_page_lease_lifecycle.dart:124`: `protected_outbound_lease_missing`.
  No password, server response, handle, message or unrestricted stack was logged.
- The completed upload and final Attachment operation share the result lease.
  Exact no-save readback clears the outbox lease marker, then native
  acknowledgment removes its receipt. The upload row correctly retains its
  immutable history, but the global recovery scan incorrectly treated that
  historical result lease as still adopted. Parent admission stopped on restart.
- App `436c61bbb` reuses the existing exact child-readback predicate to omit
  only a proven released result receipt from adoption recovery. Plan/result
  bytes remain in protected-reference liveness; the original upload row is not
  cleared or regenerated. A production-store release/reopen test reproduced
  the bug. After repair, 276 tests passed across upload, parent dependency,
  epoch, executor, protected lease lifecycle/maintenance, ObjectBox and safe
  diagnostics. Twenty altered/incomplete proof cases still require the lease.
- Qualified overlay `46bc6f027185-local-write` uses unchanged signed native
  `62221f9c2`. At 07:42:09Z image 04 finished with admitted=1, deferred=0,
  outbox_blocked=false. At 07:44:53Z a new process finished with admitted=0,
  deferred=0 and no blocked work. Original request and claim hashes match
  before/after; no new IDS request or synthetic image was created.
- Offline inspection after admission found state-2 intent, one canonical
  message/attachment, one adopted upload, a confirmed child operation and a parent operation.
  The old inspector's `forRetainedQueueInspection` has no retained attachment
  proof callback, so exact-source validation reports
  `cloud_sync_attachment_parent_readback_required` and its deliberately
  conservative v4 proof flag remains false. Do not weaken that inspector or
  interpret its limitation as failed runtime admission. Independent fresh
  read/recipient rendering and full Android qualification remain open.
- Evidence: `build-evidence/windows-dart-overlay-05e603992` and
  `build-evidence/windows-dart-overlay-46bc6f027` contain pinned manifests,
  qualification, exact terminal traces and tests. Prior runtimes were verified
  and moved to named rollback folders with manifests, not deleted.

### September 11, reviewed sidecar integration and retained limits

- Full Android qualification `34576684370` was dispatched at 07:55:40Z on
  exact source `5e9a532be4eead18f7b6c760bfddf03daf1ae2c9`, T2D 60,
  Canary writer enabled, automatic uploads disabled for bounded qualification.
  It uses the unchanged ephemeral pilot and GitHub-hosted signing path. No
  Apple credentials or personal profile files were sent to CI. Dispatch is
  not test or build success; check the run and cleanup before release.
- Follow-up disposable-copy inspection found the image-04 parent in state 2,
  its readback marker equal to its admission binding, and its confirmed
  receipt released. Both parent and child report save-attempt count 0 (a
  stored counter, not proof that no server save occurred). Source, request
  and claim stayed unchanged. Five inspector tests include forged markers,
  pending and missing parent operations. The v4 overall proof remains false
  until exact source/child revalidation is wired; no success flag was relaxed.
  Evidence: `windows-dart-overlay-46bc6f027/image-04-parent-inspection.log`.

- FaceTime `2c259fe0b` integrates explicit Leave/native End ownership after
  removing the rejected all-inactive-participant teardown. `509690a4b` fixes
  early-Join timer and stale asynchronous cleanup ownership. Parent reruns:
  63 JS/source tests, 64 Kotlin tests and 41 Flutter tests passed. Android
  Activity compilation, real bidirectional calling and remote hangup remain
  unproven. Native partial participant snapshots are not terminal-call evidence.
- The Find My agent corrected its unsupported interpretation of
  `optedNotToShare`. Upstream directly projects native lastLocation; parent
  integrated the reviewed correction as `3bc595905` and reran 81 tests.
  Same-ID handle fallback and fresh location projection remain. This patch is
  not installed and cannot repair the probe's upstream native null location.
- Read-only Windows `06c3ca5cf75a` at 07:13:37Z returned Devices=0 and People=1,
  no native location; selection and Items were not tested. User subsequently
  clarified the Pixel does not have the original app installed. A working
  original-Pixel comparison is therefore UNVERIFIED. Do not infer revoked
  sharing, missing AirTags, or wrong credentials from these counts.
- A separate native Find My shape-logging proposal is retained, not integrated:
  its DEBUG output is unobservable in the current Android WARN-only and
  logger-disabled probe lanes. No logging-policy change or hidden service
  initialization is justified by that proposal alone.
- Completed older attachment/manual-selection agents and FaceTime were
  reviewed and closed through supported controls. Required evidence, shared
  source, unintegrated proposals and rollback artifacts remain. Session
  deletion is not supported; no shared Codex database/transcript was edited.
  Scoped storage audit: build-evidence 2.67 GiB, retained writer runtimes
  0.93 GiB and writer Dart cache 0.97 GiB at measurement; C: later 49.26 GiB
  free. Only the inspector's verified disposable database copy was removed.

### September 11, cold read authentication and independent-proof limits

- Read-only overlay `46bc6f027185` failed at 08:11:08Z with
  `cloud_sync_native_auth_identity_mismatch`. Reset recovery captured native
  identity before the ordinary read session restored GSA identifiers. The
  writer already established authentication first; no wrong password, account
  replacement or damaged CloudKit cursor was established by this failure.
- App `b432b9e8a` introduces the production provider's
  `prepareResetRecoveryAuthentication` under the semantic-read interlock. It
  releases that lock before the existing reset coordinator acquires its own.
  Exact identity, reset authority and client-replacement checks remain intact.
  The cold-path test reproduced the old failure; 126 adapter, reset, sampler
  and interlock tests passed afterward. No credential/cursor reset was used.
- Qualified read-only overlay `f90226831663`, signed native `62221f9c2`,
  completed fresh-process reads at 08:19:24Z and 08:23:09Z. First pass fetched
  one Attachment and repaired one chat-order cache; repeat fetched zero.
  Both applied zero new entries, retained 6,654 old entries and preserved
  settled outbox `6 -> 6`. Remote saves/deletes were disabled. All three zones
  retained the honest `retained_projection_incomplete` status, including
  out-of-scope SMS/service records and unresolved historical dependencies.
- Inspector `1c02fae40` adds bounded exact-account/scope/record ingestion
  diagnostics, with six tests. Image 04 has no matching Message inbox entry
  after the first fresh read. That same-client observation does not disprove
  the existing exact remote-record readback, and does not establish independent
  Apple-device visibility. Do not require a self-echo or build another proof
  framework merely to change the offline inspector's conservative result.
- Evidence: `build-evidence/windows-read-after-write-46bc6f027` contains the
  failed cold-auth trace and tests; `windows-read-after-write-f90226831`
  contains pinned 78-file manifests, qualification and both semantic reports.
  Original image-04 request/claim and writer runtime remain rollback material.
- The first fixed read's host observer incorrectly supplied a Find My-only
  schema expectation to `Wait-HarnessOperation`, so it missed a successful
  semantic terminal report. The parent verified exact launch ID, PID, build,
  stage and report before stopping that process. The corrected evidence
  wrapper retained those identity checks; the second launch exited successfully.
  This observer error is not a failed read or a changed production app result.
- GCE `34576684370` remains pinned to `5e9a532be`, excluding this cold fix.
  At 08:30Z its full qualification was building the APK. Do not install it as
  containing `b432b9e8a`, or call signing/cleanup passed before readback.
- All five reviewed agents now report `not_found` through supported shutdown
  verification. Required evidence, rollback runtimes and the unintegrated Find
  My proposal remain retained; supported session deletion is unavailable.
  C: free space at this checkpoint was 48.17 GiB. No evidence was deleted.

### September 11, full attachment candidate qualified; cold fix queued separately

- GCE `34576684370` completed successfully: full Dart suite, 14 semantic-outbox
  and 3 evidence-output cases, 493 app Rust, 276 rustpush and 38 protector
  tests; generated bindings reproduced. APK identity/native-library checks,
  Android JVM tests, trusted GitHub-hosted signing and exact cleanup passed.
  Signed artifact `10191138537` remains in GitHub, not downloaded or installed.
- Independent inventories showed the old VM `gce-34576684370-1` and its runner
  registration absent. At readback only successor VM `gce-34579830953-1` was
  running; no runner was registered yet. This is an active new run, not cleanup
  leakage. Required test steps and the selected-suite aggregate gate all passed.
- Source `f860966d53b6019b46f1437312e67662724f08ce` was reviewed and pushed to
  the fork. It adds only the cold-read repair, targeted tests, bounded inspector
  diagnostics and documentation above the fully qualified source. User data,
  credentials and pre-existing unrelated working changes were not staged.
- Full successor `34579830953` was dispatched at 08:34:10Z on the existing
  primary lane, T2D 60, Canary writer on and automatic uploads off. It waited
  for the previous run's signing/cleanup, then began provisioning. No pilot,
  cloud configuration, signing secret, IAM or upstream pull request was changed.
  Its eventual pass and cleanup must be verified before the next Pixel install.

### September 11, Windows reaction proof and signed Pixel installation

- Windows-only app `6458314d6` adds request-v5 standard reaction add/remove
  against one explicitly named, already-confirmed plaintext test parent. It
  reuses the production IDS payload, exact local source journal, positive
  recipient acknowledgment and protected CloudKit admission. No native rebuild
  was needed. Qualified Dart overlay `3984f810501b` retained signed native
  `62221f9c2`; all 78 runtime files and profile-preservation checks passed.
- Like-05 completed at 08:56:14Z, and remove-like-06 at 09:03:02Z. Both admitted
  exactly one record with no deferred intents or blocked outbox. Fresh processes
  completed at 08:57:56Z and 09:05:07Z respectively, with zero admissions.
  The original requests, positive IDS claims and prior attachment-04 are retained.
  No new text or personal-group message was sent during these reaction tests.
- Inspector `ef6ba340e` verified both reaction rows against their exact parent,
  source validation, durable readback marker and released receipt. Source DB,
  request, claim and parent claim hashes remained unchanged. The helper opens
  only a verified disposable DB copy, then removes that copy. Six inspector
  tests passed, including forged-proof, parent mismatch and null/zero part cases.
  Analyzer passed. Earlier harness/reaction suites passed 39 cases; overlapping
  suites must not be summed as unique coverage. This is persisted exact-readback
  proof, not a fresh independent Apple-client display observation.
- Inspect own-parent writer proofs with the producing runtime's V2 writer and
  outbound-canary compile flags. The default reader build correctly rejects
  parent authority as `cloudkit_writer_build_owner_mismatch`; no production
  guard was weakened to obtain the successful result.
- The bounded edit/unsend reviewer withdrew an unproven network-constructor
  recommendation. `Record.etag` exists, but the write-precondition meaning of
  the selected save semantics remains unproven. Do not enable network edits
  based on a field name alone. The reviewer was closed and verified absent.
- GCE `34579830953` passed build, native verification, Android JVM tests,
  trusted signing and cleanup for `f860966d5`. Independent inventories again
  showed zero GCE instances and zero registered GitHub runners. Signed artifact
  `10192048724` contains APK SHA-256
  `ad0d6ac3e2800245bb54847a7afb12366552fb592b5c180b3cb2262efe9d6a9d`.
  Local v2/v3 verification passed, with the same certificate as installed Canary:
  `0ea17c1b67581ca79660d33db45af0a36b71ea36a4cbafec5293d3ae80570d79`.
- Wireless `install -r` succeeded at 09:14:53Z. Canary package and original
  install time were retained, with Alpha baseline captured beforehand. Source
  binding is from the pinned signed CI artifact, not yet a runtime getter check.
  No credentials, cursors, messages or app storage were cleared. The previously
  retained Pixel report was actually source `3dc614c9e`, not the older installed
  source formerly listed in the treemap; the new candidate row corrects that drift.
- Initial preflight showed an active coordinator lease with no semantic pull.
  It naturally became inactive by 09:21Z, consistent with the five-minute lease
  boundary. No lease was deleted or ignored. Authentication remained ready and
  the protected semantic action became available. A combined restart/VM command
  was policy-blocked and was not retried through another route. Supported ADB
  status/preflight and ordinary protected semantic actions remain usable.
- Evidence: `build-evidence/windows-reaction-write-3984f8105`,
  `build-evidence/gce-full-f860966d5`, and `build-evidence/pixel-f860966d5`.
  Retain rollback runtimes, native receipts and original requests. C: remains
  above 46 GiB free; no retained evidence or agent transcripts were deleted.

### September 11, Pixel remote-head proof and ordinary-send blocker

- Protected ADB catch-up was accepted at about 09:21Z. Report
  `obcs2-semantic-1789118680461057` verified exact runtime source `f860966d5`:
  Chats/Messages fetched zero and observed empty terminal reads; Attachments
  fetched one. Report `obcs2-semantic-1789118793733527` then fetched zero in all
  three zones and proved the complete remote head. Both kept saves/deletes off,
  outbox `0 -> 0`, and settled-outbox identity unchanged. Native authentication
  passed on Pixel without clearing credentials or CloudKit state.
- These reports are partial, not full sync completion. Retained totals are
  Chats 476, Messages 7,820, Attachments 1,813. Message diagnostics distinguish
  5,433 out-of-scope service saves from 1,893 blocking saves; attachment blocking
  saves total 1,694. Do not conflate SMS exclusions with unresolved supported
  records. The bounded local sweep continues after the remote-head reports.
  The ADB controller publishes its final pass count only on completion, so
  `passes=0` during that sweep does not mean no remote passes occurred.
- Verified the actual developer screen after unlocking the device using the
  user-authorized temporary test access. The first black screenshot was the
  system lock-screen surface, not proof of a Flutter rendering regression.
- Opened ordinary composer through the existing `imessage://` handler with
  only approved direct test recipient and synthetic qualification-07 text.
  One Send tap was blocked by recipient validation, before sending; the draft
  remains intact. UI explicitly requested registration repair. Native logs
  recorded `IDS returned 6005; attempting to re-register` at 09:27:43Z
  (02:27:43 PDT). One validation-only retry remained unsuccessful.
  Do not count a send, CloudKit upload or delivery for qualification-07.
  Read authentication and IDS registration are separate gates. No login reset
  or hardware replacement was performed while the semantic read was active.
- Alpha version, original install time, last update and data directory all
  match the pre-install baseline. Native logs also contain earlier APS send
  timeouts and FaceTime link-validation failure; neither proves this read failed.
- Astra Find My worker produced default-off, value-free diagnostic source only:
  `lib/app/layouts/findmy/findmy_page.dart`, `findmy_diagnostics.dart`,
  `test/findmy_diagnostics_test.dart`, and native `src/findmy.rs` plus
  `src/findmy/diagnostics.rs`. Parent reviewed all five files and reran 10 tests
  successfully; worker reported 54 selected tests and 10 with the gate enabled.
  Seven native tests are still uncompiled. Preserve these unique uncommitted
  changes for the next bundled qualification, not the frozen current APK.
  Both build-time gates are `OPENBUBBLES_FINDMY_VERBOSE_DIAGNOSTICS=true`.
  No location restoration is claimed. Worker closed and verified `not_found`;
  no dedicated worktree or disposable artifact was created. Transcript deletion
  remains unsupported, and required source/evidence stays retained.
