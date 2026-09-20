---
type: log
title: Cloud Sync V2 Investigation Log from 2026-09-07
description: Chronological qualification results after the current treemap was separated from the historical investigation record.
resource: openbubbles-app
tags: [openbubbles, cloudkit, investigation, evidence, canary]
timestamp: 2026-09-18
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

### September 11, no-progress sweep and bounded background metadata

- Pixel final report `obcs2-semantic-1789120061809426` completed at
  09:47:41.809426Z on installed `f860966d5`. The content-free preserved copy is
  `build-evidence/pixel-f860966d5/semantic-projection-0947.json`. Chats retained
  476 rows (395 out of scope, 81 tombstones), with no blocking save. Messages
  examined 1,893 blocking saves in 60 batches/631,219 ms; Attachments examined
  1,694 in 53 batches/632,899 ms. Neither zone applied a record. Their total
  retained inventories were 7,820 and 1,813 respectively. Both remain degraded,
  not lost or successfully restored. Saves/deletes stayed off, outbox `0 -> 0`.
- A later metadata read began after the foreground sweep. Source review found
  that the Android background path reused exhaustive head repair and required
  full retained projection completion before marking a metadata wake complete.
  This could repeatedly redo unchanged history without making forward progress.
  The small patch makes only background metadata omit the exhaustive sweep.
  Normal reads still fetch/project and perform bounded retained work; explicit
  foreground catch-up keeps its full sweep. A safe empty-terminal three-zone
  read may complete that wake while retaining and reporting unresolved history.
  Unsafe reports, changed outboxes, authorization failures and nonterminal reads
  still retry. No write, cursor reset, evidence deletion or relaxed identity gate.
- Qualification: 129 tests passed across the manual sampler, semantic drain,
  Android background policy/composition and production composition suites.
  The added two-wake regression preserves the same retained rows, avoids the
  exhaustive callback, and balances native pause/resume. Targeted analysis of
  seven changed files found no issues. This is local Dart proof only, not an
  installed repair, native qualification or a measured runtime speedup.

### September 11, approved registration repair and sidecar review

- Used the normal Canary Profile repair action once, with the user's existing
  approval. The repair cooperatively quiesced CloudKit and reopened setup.
  It intentionally resets rejected IDS registration through the supported
  `reset_state(reset_hw: false, logout: false)` path. No manual credential,
  cursor, database or hardware deletion occurred. ObjectBox, CloudKit, keychain
  and existing iPhone relay identity remain; Alpha was not changed.
- Reused the saved account once through ordinary setup. The UI returned
  `Phone Number validation failed, please re-authenticate!` and cleared stale
  cached SMS authentication through its existing handler. That handler rewrites
  any 6005 while phone users exist, so the text does not prove which upstream
  authentication stage failed. Normal phone-number validation is pending;
  no email-only downgrade, new SIM activation, outbound qualification-07 send,
  CloudKit upload or delivery is claimed. Do not loop reset or replay old tests.
- Reviewed and accepted Carver's bounded IDS diagnosis, closed it and verified
  `not_found`. No dedicated disposable worktree/logs existed; supported session
  deletion is unavailable. Singer remains active on required Find My work.
  Singer's upstream comparison found no proved regression in People models,
  exact-ID joins, authentication headers or AirTag inventory requests. The
  missing Items diagnostic stage is being added without changing auth, polling
  or writer-permit behavior. No real-account location restoration is claimed.
- Singer's earlier FaceTime remote-target guard is reviewed, with three parent
  JS source-contract tests passing and seven native cases still uncompiled.
  Both sidecar patches remain separate uncommitted work for the next reviewed
  native qualification bundle. No new APK, cloud run or upstream PR was created.
  C: has about 46.4 GiB free; no evidence or agent artifacts were deleted.

### September 11, background checkpoint and source-only qualification

- Parent CloudKit checkpoint `0bb67d2c4` was committed and pushed only to the
  fork's trusted feature branch. GCE Dart-only run `34588214811` was dispatched
  at 10:14:15Z against its full exact SHA, using one T2D 60 runner in us-west1-b,
  existing 75-minute lifetime and cleanup jobs. No APK, native build, signing,
  automatic upload, Apple credentials or live account test is selected. The
  pre-dispatch inventories contained zero VMs and zero registered runners.
  Result and post-run cleanup remain pending, not assumed successful.
- Singer completed the bounded Items extension. Parent reviewed the code and
  independently passed all 15 diagnostic tests and the three FaceTime source
  contracts. Native tests remain uncompiled. Accepted patches are retained
  uncommitted, separate from `0bb67d2c4`; no location/call runtime fix is claimed.
  Singer was closed after review and verified `not_found`; no required child
  agent remains active. Its unique source and necessary evidence are preserved,
  not disposable cache. Session deletion remains unsupported.

### September 11, cloud qualification completed and read replay repair

- GCE Dart-only run `34588214811` passed on exact source `0bb67d2c4`.
  The Dart suite and 14 semantic-outbox plus 3 evidence-output cases passed;
  cleanup completed at 10:28:27Z. No APK, native compilation, signing or live
  account access was performed. Total elapsed time was about 14 minutes.
- Reviewed and committed sidecars: dependency `dd5fbee` guards FaceTime against
  self-only/empty remote targets, and `aff6379` adds default-off bounded People,
  FMIP and Items diagnostics. App integration `2fd0da2a3` pins the dependency
  and includes Dart diagnostic handling. GCE rustpush-only `34589003289` passed
  all 287 native tests, including the new guard and diagnostics. Cleanup ended
  at 10:32:58Z; independent inventories at 10:33Z showed zero VMs and zero
  runners. No call/location success, combined APK or installation is claimed.
- Curie's test-only audit reproduced stale retraction loss after ObjectBox
  reopen. Parent expanded it: explicit clear, smaller nonempty list and a list
  with another part each discarded known retractions before repair. The parent
  made retractions an irreversible union. All 112 then-current adapter tests
  passed; targeted analysis found no issues.
- The follow-up test reproduced stale edit rollback after reopening ObjectBox:
  a two-revision current message became the original text when an older
  one-revision snapshot replayed. Native revision indexes are page-local, and
  Message.buildMessageParts does not derive current body text from history.
  The parent repair compares complete decoded histories, keeps body/history
  together, preserves older-subset state and defers incompatible snapshots.
  Legacy Apple seconds are normalized only for comparison, using the native
  converter's existing epoch rules. Parent reviewed the agent tests and added
  real two-part body cases, out-of-order/duplicate legacy history and a stale
  edited replay after retraction. The final four-suite run passed 278 tests
  (120 adapter, plus inbox, ObjectBox gateway and safe-failure coverage). The
  initial aggregate run caught a missing diagnostic allowlist entry; the fixed
  content-free code now survives both the safe-failure and diagnostic paths.
- Full-flow review found a separate earlier gate: the native Message converter
  fingerprints current subject/text/attributed bytes as immutable; inbox merge
  quarantines a changed fingerprint before reaching the adapter. This remains
  a read-edit gap, not solved by the projection tests. A causal exception must
  prove stable identity and compatible edit/retraction evidence and preserve
  old protected snapshots; do not disable digest checks or rewrite metadata.
  Outbound causal edit/unsend transport remains closed.
- Curie's reviewed source was preserved, the agent was closed and `not_found`
  verified. No child remains active or owns a disposable worktree/log. Supported
  session deletion remains unavailable. C: has about 46.5 GiB free; no user,
  credential, device evidence, transcript or rollback artifact was removed.

- Replay repair checkpoint `fd60a8a204e5d1cd452d1ee06e096a7ad48ca034`
  passed targeted analysis and was pushed only to the fork. GCE Dart-only
  `34591532159` started at 10:55:15Z, T2D 60, existing bounded runner lifecycle,
  all writer flags off. The full Dart job passed and cleanup completed at
  11:06:53Z, total elapsed about 11 minutes 38 seconds. Independent inventories
  then showed zero VMs and zero registered runners. Signing was skipped as
  intended. This run did not build or install an APK.
- Lorentz's initial merge fixtures omitted the actual payload summary fields.
  Parent rejected that coverage claim and required realistic edit/retraction
  DTOs. The corrected two desired-behavior tests still reproduce
  `applied` expected versus `quarantined` actual before the adapter. They remain
  uncommitted drafts in `cloud_inbox_applier_test.dart`; the qualified source
  does not contain those failing tests. This is a memory-store merge-boundary
  counterexample, not native decoding or real ObjectBox end-to-end proof.
  Reviewed draft work is retained, agent closed and shutdown verified.
- Read-only wireless status confirmed Pixel `192.168.68.51:39749` connected:
  `setup_finished=false`, `auth_ready=false`, semantic pull inactive, no active
  coordinator, empty outbox, legacy sync off. No launch, reset, new sign-in,
  semantic start, outbound send or install was invoked.

### September 11, proved read-edit transition across the real transaction

- Added an optional local-projection transition proof without changing native
  digests, schema, remote update transport or global conflict policy. Gateway
  evidence binds the exact stored snapshot, physical record, changed ETag,
  protected reference and prior applied replay/inbox sequence. A bounded query
  rejects duplicate evidence. The canonical reader verifies stable identity
  and complete compatible part/body history; it never creates handles or writes
  rows while classifying. Unknown or multi-body ambiguity remains a conflict.
- Parent implemented and reviewed the canonical/orchestration path. Pascal's
  gateway work initially had an invalid test getter, an unbounded receipt query
  and a proof-only test transaction missing its required terminal outcome.
  Parent review required corrections: exact bounded lookup, explicit sequence
  validation, test-only rollback, and confirmation the classifier returned
  before that deliberate rollback. No production transaction contract weakened.
- Eight new gateway boundary tests cover valid delegation and missing/forged,
  stale, same-tag, different-record, mismatched-local and old-reference proof.
  Canonical tests cover reopen, edit/undo, stable sender/time/subject, complete
  lineage, multipart unchanged parts and malformed/ambiguous ranges. The real
  inbox/merge/ObjectBox test applies original/edit/stale/undo, quarantines an
  unproved body and keeps one canonical message, five receipts and zero outbox
  rows. Its decoder boundary is synthetic, not a live Apple response.
- Four focused suites passed 296 tests. All six changed Dart files analyzed
  cleanly. No APK, native build, live account mutation or phone install occurred.
  Full-suite cloud qualification is the next step; no production claim is made.
- Checkpoint `90f98b7eb7bcc8ec74fcdae90cb7c5d655c4cc0c` pushed to the fork
  only. GCE Dart-only `34594546421` dispatched at approximately 11:32Z, T2D 60,
  both writer flags off, existing bounded runner/cleanup workflow unchanged.
  Eight gateway proof tests passed again after strengthening the rollback
  harness. Full cloud result and cleanup are pending.
- Pascal's work was reviewed, corrected and integrated; the agent was closed
  and shutdown verified. Its source/tests and session retain review provenance;
  there is no disposable dedicated worktree/log, and supported session deletion
  is unavailable. No artifacts were removed. C: remained above 46 GiB free.
- Pixel status remained `setup_finished=false`, `auth_ready=false`, idle and
  outbox empty. This turn did not repeat registration repair or touch Alpha.

### September 11, read-transition qualification and preview counterexample

- GCE `34594546421` passed on exact source `90f98b7eb`: 3,147 Dart tests,
  14 semantic-outbox contract cases and 3 evidence-output cases. The test step
  took 4m28s; total orchestration through cleanup was 11m30s. Cleanup completed
  at 11:44:17Z, then independent inventories showed zero VMs and registrations.
  Dart-only means no APK, signing, native build or Apple-account access.
- Repeated the existing offline ObjectBox inspector after recovering a lost
  tool response and confirming no app/test process remained. Its disposable
  copy showed 700 chats, 13,648 messages, 2,418 attachments, 16,759 snapshots and
  8 outbox rows. The source database SHA-256 stayed unchanged. This is retained
  Windows data, not a new sync or proof of complete iCloud history. The tool
  removed its validated temporary copy; protected source/evidence remains.
- Socrates found a request-level ETag in Apple's historical runtime header.
  Parent fetched and verified both request and Record headers independently,
  and confirmed the local proto/builder omit a predecessor tag. Accepted the
  missing-protocol-evidence finding; rejected inference as permission to guess
  fields 4/5 or enum values. No existing Apple save capture was identified by
  scoped filename searches. Research agent closed and `not_found` verified;
  no dedicated worktree/log exists. Session provenance remains retained because
  supported session deletion is unavailable.
- Preview regression reproduced locally before repair: seven synthetic tests
  failed because unsent text/subject or payload descriptions were still used.
  Normal/pinned tile listeners also skipped same-GUID updates without a changed
  dateEdited. The repair returns a content-free unsent/partial-unsent label,
  suppresses quoting retracted reaction parents, and compares actual previews
  from already-fetched rows. It preserves stored text/history and does not
  invent timestamps or issue projection writes. The five-suite cohort passed
  48 tests, including mounted normal/pinned previews driven by real ObjectBox.
  Parent negative control restored same-ID suppression, observed the mounted
  edit-refresh failure, then restored the repair and passed the full cohort.
  Web source uses the same refresh rule, but no browser runtime was tested.
- Muse's tool call failed with undeclared `default.apply_patch`; the parent
  reported routing evidence to the repair task and recovered the draft as text.
  Parent reviewed/applied it, added validated temporary-directory cleanup and
  older-row regression, and corrected native-port timing in the fake-clock
  widget harness. Agent closed and shutdown verified. No dedicated agent
  worktree/log existed; reviewed draft provenance remains in its session.
- The existing inspector's separate legacy-shape aggregate found 318 messages
  with edit history (684 entries, zero invalid/before-creation timestamps) and
  65 with retraction metadata. Zero proved unrendered retractions; three offline
  part builds could not be verified, which may require live presentation
  services and is not proof of device failure. It also reported 61 visible rows
  without renderable content by its heuristic. These retained-data counters
  are investigation inputs, not new downloads or an end-to-end completeness
  claim. Source hash remained unchanged after this read-only copy inspection.

- Astra's bounded Find My sidecar confirmed People endpoint/auth/model/ID joins
  match upstream. No initial-null fix is claimed. It identified a real coupling:
  Items waits on the protected writer gate, while an aggregate UI in-flight bit
  suppressed later People/Devices polls until Items completed. Parent reviewed
  the independent single-flight scheduler and disposal guards. Busy lanes skip
  polls without building a queue; the Items-only retry shares that same slot.
  The protected writer gate and required native alignment writes are unchanged.
  Agent reported 82 focused and 23 diagnostics-enabled tests passed, including
  a 100-poll stalled-Items case. This prevents cross-section refresh starvation,
  not a missing native People location. No live Find My call was made.

- Preview checkpoint `269620126` and separate reviewed Find My checkpoint
  `ee9729ec3` were pushed only to the fork. Parent independently passed the
  31-test refresh/People/scheduling subset. Helper/new test analysis is clean;
  UI analysis retains the pre-existing immutable-widget warning and two
  withOpacity deprecation notices, not new errors. Both patches are batched in
  GCE Dart-only `34597175527`, dispatched at 12:05:36Z with exact source
  `ee9729ec32fc132b386e4cbd42e608424968dbec`, T2D 60, both writer flags off.
  Run result and cleanup remain pending; no APK/native build is requested.
- All three agents used in this checkpoint were reviewed and closed with
  shutdown verified. No dedicated disposable worktree/log was created. Source,
  unresolved runtime findings and session provenance are retained; supported
  session deletion is unavailable. No protected source/device data or rollback
  evidence was removed. C: remained above 46 GiB free at integration.

### September 11: isolated Apple save serializer acquisition

- GCE `34597175527` passed on exact app `ee9729ec3`: 3,167 Dart tests,
  14 semantic-outbox cases and 3 evidence-output cases. Tests ran from
  12:12:08Z to 12:16:38Z. Cleanup completed at 12:18:21Z; independent GCE
  instance and GitHub runner inventories were empty. No native build or APK.
- Epicurus completed a bounded primary-source check and confirmed that neither
  missing request ETag numbering nor enum meanings are proved by headers.
  Accepted the serializer/decoder acquisition recommendation, not guessed
  fields or enums. Closed and verified not_found after review. No dedicated
  files/worktree/logs existed; session provenance is retained because supported
  session deletion is unavailable.
- Added a synthetic-only Objective-C serializer probe and an opt-in macOS job
  in the already registered Windows workflow. Normal push/PR builds are
  unchanged; probe dispatch skips them and uses a separate concurrency group.
  No account, message data, profile, credentials, CloudKit operation or security
  setting is provided. Local YAML and diff checks passed; actual macOS class
  availability and compilation remain pending. Enum probing is bounded and
  explicitly not proof of server semantics.
- Find My agent resume hit the account usage limit without new work. After the
  user reported that limit lifted, resumed its same bounded follow-up rather
  than creating another agent. Prior source and unresolved runtime evidence
  remain preserved; no deletion was performed. C: had over 46 GiB free.

- Probe run `34620660937` succeeded on app `8f540c2e4`, 16:12:38Z to
  16:13:05Z. Both Windows matrix jobs were skipped. Apple macOS 15.7.9 build
  24G830 loaded CloudKitDaemon UUID `002449BA-60D0-341F-933F-D5582A63F116`.
  Request ETag emitted field 4; semantics field 6 mapped 1 failIfOutdated,
  2 failIfExists, 3 override through both conversion methods. Zone/record PCS
  tags emitted 7/8. Every synthetic wire case round-tripped. The 34-value enum
  scan is bounded, not an exhaustive enum proof. No Apple account/server used.
- Retained complete JSON under
  `build-evidence/apple-save-wire-probe-34620660937/apple-save-wire-probe.json`,
  SHA-256 `e05fdca3ee4378bb566a0cfaed20a1032d501007ccaa812380a0db7bd823facf`.
  The protocol fixtures copy independently observed Apple bytes, not bytes
  produced by rustpush. Added missing request ETag to the private proto and
  a disconnected conditional-save builder; unchanged legacy constructors
  continue emitting failIfExists/override with absent request ETag.
- Parent and Epicurus reviewed the low-level builder. Accepted its account
  provenance and unknown-outcome integration cautions. Added explicit rejection
  of custom protection, missing PCS keys or changed default key before a merge,
  plus matching-key/tag-separation tests. No live writer invokes the new helper.
  Native compile/unit validation remains pending, not production qualification.
- Find My follow-up reported 12/12 source-contract checks against upstream,
  not parser execution or live account proof. No new fix: owned AirTags also
  require a matching naming record upstream; serde declarations and token
  routes showed no differential. Existing native/Dart diagnostics must both be
  compiled in for the next live check. No account, caches or sharing changed.

- Reviewed dependency `fbf9b4c` was pushed to the rustpush fork; app checkpoint
  `4dc324995` pins it. Native-only GCE run `34621760644` is validating on T2D 60,
  both writer flags off. No APK/signing/account operations requested. Status and
  cleanup remain pending. The first push used a nonexistent remote name `fork`;
  verified this submodule uses `origin = Xare123/rustpush`, then pushed normally.
- Parent addressed the review's test flakiness nit: the randomly generated
  rotated test key must actually have a different prefix. Both agents' reviewed
  work is integrated or recorded; closed them and verified `not_found`. No
  dedicated worktrees/logs/files to remove, and session provenance remains
  protected without a supported deletion control. Free C: was approximately
  49.9 GiB; no storage reclamation is attributed to this task.

- GCE `34621760644` finished successfully. Exact app
  `4dc3249959be32a5ed63c7f0348320b288a39ca4` pinned dependency `fbf9b4c`;
  native compilation took 56.03s and all 297 tests passed in 6.30s, including
  all ten new Apple-wire/conditional-save/legacy-compatibility cases. Cleanup
  completed at 16:29:20Z; independent GitHub runner and GCE instance inventories
  were empty. No ignored/filtered tests, APK, production account, signing or
  writer activation. Updated the treemap with the durable mutation-to-readback
  sequence; low-level protocol qualification is not end-to-end update proof.

## 2026-09-11, mutation source and retained-version inventory

- Parent added native exact edit/unsend source codec `c65584196`. Separate
  operation and target identities, bounded canonical decoding, exact route/
  body/format/index capture, reconstruction, and validation against the actual
  native `prepare_send` method have focused tests. No FRB, ObjectBox schema,
  live send, protected-store adoption or remote-save activation changed.
- GCE app-Rust-only runs `34623645666` (T2D 60, us-west1-b), `34623788831`
  (T2D 32, same zone) and `34623918659` (N2D 16, us-west1-a) all failed before
  compilation with `ZONE_RESOURCE_POOL_EXHAUSTED`. Each cleanup succeeded;
  independent instance and runner inventories were empty. These are capacity
  failures, not failed source tests. Existing GitHub-hosted bridge workflow
  `34624049558` is validating the exact `c65584196` source instead, drift
  permission false. No APK/signing/account operation was requested.
- Erdos found no newer substantive FaceTime trace and no evidence-backed
  additional patch. Its 66 JS/source cases passed, but both retained trace
  analyzers admitted zero records. ADB refused connection. Current media/lifecycle
  fixes still require a consented live answered call and repeat-call check.
  Reviewed the report, closed the agent and verified `not_found`. No dedicated
  new files existed; retained evidence/session provenance was not deleted.
- Russell's first inventory review found that current aggregate counts cannot
  prove a same-physical-record edit/unsend pair. Assigned a bounded metadata-only
  inspector extension instead of another capture. Parent corrected the query
  design: scope record identity by account/scope, generation and zone; a
  retraction can be a save, not necessarily a record tombstone. No actual
  before/after pair is claimed until the query and protected bytes are checked.
- Parent reviewed and retained Russell's metadata-only inspector; fixed empty
  digests being counted as retry proof and added cap/overflow, generation/zone,
  example-bound and source-preservation regressions. Seven actual ObjectBox
  tests pass locally using the existing ARM64 DLL on process PATH; targeted
  analysis reports no issues. The earlier missing-DLL failure is environmental,
  not a need for another build. App-Rust-only CI does not test Dart inspectors.
- Offline live-profile query, under the existing launcher mutex with no
  OpenBubbles process running, found 23,413 scoped records, zero multi-row or
  changed-ETag candidates, and 679 missing-tag/tombstone groups. Source database
  SHA-256 was identical before and after; inspector removed its disposable copy.
  No message contents, routing identifiers or protected references were printed.
  This snapshot cannot prove edit/unsend transitions and should not be rescanned
  without new ingestion. A deliberate before/after capture remains required.
- Russell was closed after review and shutdown verified as `not_found`.
  Its shared-worktree code is retained for integration; no dedicated disposable
  worktree was created. Session provenance remains retained because no supported
  session-deletion tool is available. C: free space is approximately 48.6 GiB;
  no cleanup credit is claimed. One bounded Muse worker now owns mutation-source
  protected staging; a second provides the journal integration map without edits.
- Maxwell's codec-test changes were reviewed; parent caught use of `unwrap_err`
  on a deliberately non-Debug private type and a wrong canonical-JSON error
  expectation. Both were corrected, error branches checked against source and
  the single file formatted. Runtime qualification of the expanded tests is
  pending. Agent closed and shutdown verified; source preserved.
- Kant's map confirmed the initial-create identity validator must not be
  weakened for edits/unsends. Accepted a distinct mutation-intent journal and
  the existing positive-receipt lifecycle; rejected making remote `ckRecordId`
  availability a prerequisite for ordinary IDS mutation. It gates CloudKit
  admission later. Source binding, receipt replay and protected-byte liveness
  need to land together. This is an integration decision, not implemented schema.
  Agent closed after review; no dedicated files were created.
- GCE Dart-only `34625386547` on reviewed source `4f7674c1f` successfully
  provisioned `n2d-standard-16` in `us-west1-c`, with both writer flags off.
  No quota/settings changes were needed; qualification and cleanup are pending.
  The UI's generic build-job label does not mean an APK is requested in dart-only.
- Native protected mutation staging now has a reviewed implementation. Hilbert
  delivered a partial wrapper; parent completed the purpose and native wrappers,
  strict reference/lease validation and four protected-store test scenarios.
  Tests cover edit/unsend reopen after exact idempotent commit, uncommitted
  rejection, account/source/digest/length/reference/lease/request drift,
  cross-purpose substitution, and malformed descriptors without storage writes.
  The one-MiB wrapper ceiling matches existing receipt limits. No FRB, ObjectBox,
  network call or save activation changed. Exact native qualification is pending.
- Hilbert's first relative patch landed at the inherited task working directory
  instead of the assigned worktree. Parent verified its 7,242-byte stray source
  was identical to the retained project copy except terminal newline, closed the
  agent, verified `not_found`, then removed only that exact duplicate file.
  The integrated source and original session provenance remain retained. The
  routing issue was sent to the designated Muse repair task. No broader folder,
  session, transcript or evidence deletion occurred.
- GitHub `34624049558` completed successfully on exact codec source `c65584196`.
  Bridge reproduction, native compile, app/dependency tests, Anisette provider
  tests and protector harness all passed. This does not qualify later staging
  integration or an Android build. ADB wireless discovery reconnected the Pixel;
  Astra now owns a bounded read-only FaceTime evidence capture, with no calls,
  installs, log resets or account changes permitted.
- Native checkpoint `3d95920ff` was pushed to the fork only. GCE app-Rust-only
  `34625938024` is queued on the same primary lane behind Dart-only
  `34625386547`, preserving the single N2D-16 quota and cleanup ordering.
  No APK or production credentials are involved. This run must cover the new
  protected-stage and expanded codec tests before their source is qualified.
- Parent reviewed Astra's bounded current-Pixel capture: no new usable
  FaceTime admission/media/termination trace. Current native diagnostic
  directories are absent; general warnings cannot identify a handshake failure.
  Fifty-four JS regressions passed. Logs and manifest total 2,790,624 bytes in
  the local ignored `device-evidence/facetime-20260911-live-review/`
  `capture-20260911-100513-a1` directory. Installed exact source was not newly
  attested by the agent. No additional FaceTime patch or success claim follows
  from this evidence. Rawls closed after review and shutdown verified; the
  bounded evidence is retained. No child agents remain active.

- GCE Dart-only `34625386547` completed: 3,169 Dart tests, 14 semantic
  outbox cases and 3 evidence-output cases passed on source `4f7674c1f`.
  Cleanup succeeded at 17:13:11Z; the exact old VM and runner were absent
  from independent inventories while the successor native run was active.
  Native-only `34625938024` on `3d95920ff` provisioned successfully in
  `us-west1-c`. No quota or infrastructure configuration changed.
- Parent is integrating purpose-typed mutation staging and restore into the
  native send boundary. Original source is checked before submission and
  again after native preparation. A post-acceptance mismatch suppresses
  CloudKit authority without reporting a resendable delivery failure. New
  version-4 receipts distinguish mutation from attachment sources across
  persistence, replay and acknowledgement. Versions 2/3 retain their meaning.
  This is not wired to ordinary edit/unsend UI, a durable mutation journal or
  a remote save. Exact-source bridge generation/native tests remain required.
- Feynman's new content-free mutation binding and its ten tests were reviewed;
  parent reran them with the twelve unchanged attachment-binding tests, all
  22 passed. Targeted Dart analysis reports no issues. No schema, account,
  send, upload or CloudKit authority comes from this codec alone.
- Astra identified a native-only FaceTime log export eligibility defect and
  was assigned its bounded fix. Both diagnostic switches are connected in
  source; absent files are not a handshake diagnosis. Remote LeaveEvent
  observability remains a distinct gap, not permission for automatic teardown.
- GCE `34625938024` completed successfully on `3d95920ff`: bridge
  reproduction, native compile and 503 app Rust tests passed. Cleanup completed
  at 17:23:33Z and independent VM/runner inventories were empty. This qualifies
  protected staging and expanded codec tests, not the subsequent API/receipt work.
- Parent review added a real send-start ambiguity repair: rustpush's
  `IdentityManager::send_message` can abort a send task after a 15-second
  no-progress timeout, after packets may have been sent. Its `SendTimedOut`
  text previously reached Dart's one-time automatic retry even for tracked
  intents. Tracked starts now return the fixed completion-unknown code;
  untracked legacy behavior is unchanged. Native regression qualification is
  pending with the mutation API batch.
- Beauvoir's receipt patch and later test additions were reviewed, including
  exact historical v2/v3 shapes, strict v4 purpose/fields, idempotent persist,
  replay, and wrong-kind acknowledgement preservation. Parent strengthened
  historical fixture checks to compare encoded bytes too. Both Muse workers
  were closed after review and shutdown verified. Their source is retained;
  supported transcript deletion is unavailable, so provenance is preserved.
- User additionally requested an Astra FaceTime viewer redesign. The same
  Astra worker now owns the layout task after the export fix: video-first
  iOS-style controls, safe insets and no overlap, while preserving signaling
  and explicit-user teardown semantics. It is not integrated or tested yet.
- Native API/receipt commit `ab7f640c5` was pushed to the fork and submitted
  once as GCE `34627823377`: app-Rust-only, N2D-16 in `us-west1-c`, writer and
  automatic-upload flags off. The previous runs were terminal and the VM
  inventory was empty before dispatch. The source was validated before the
  later local FaceTime commit. No APK or account operation was requested.
- Astra's viewer candidate was reviewed and committed separately as `509aa1d34`.
  Parent removed a duplicate caller header through review and retained Apple's
  Leave control. Measured status/WebView/dock regions replace overlay offsets;
  signaling and explicit-user end authority are unchanged. Parent verification:
  70 Kotlin tests, nine Dart source contracts, 63 JS/source regressions passed.
  One source-test regex initially counted equality as assignment and was fixed.
  Android Activity compilation and actual rendering remain unverified.
- The native-only FaceTime export fix remains separate and uncommitted pending
  generated-binding import. Its Flutter test failed to load on the missing new
  CloudKit enum/field, not an export assertion. No repeated tests or temporary
  hand-edits of generated bindings were used. Astra was closed after review;
  shutdown was verified. Shared source and provenance are retained, and no
  supported session-deletion control is available. C: retained about 49 GiB free.
- GCE `34627823377` on `ab7f640c5`: native compile and **513 Rust tests passed**;
  only the generated-binding drift gate failed. Artifact `10274958197` ZIP
  SHA-256 `15ebf3465035a83a1b19b8bad98192387b8095a0075400d9ceda583f4a501912`
  was verified before exact-list extraction/import. All seven destination paths
  were clean before import and matched source hashes afterward; five changed
  logically. Existing dirty Freezed/platform/generated edits were not overwritten.
  Binding guards passed. The focused Dart rerun passed 39 tests, including the
  eight export cases previously blocked by the missing generated source-purpose field.
  Cleanup completed at 17:38:18Z; independent VM/runner inventories were empty.
- Muse Lorentz's read-only mutation-journal map was reviewed. Reuse transaction
  and receipt lifecycle patterns, not the create-origin validator or attachment-only
  readback predicate. Native intent capture, separate durable mutation identity,
  both protected-reference roots, positive-receipt replay and local reflection
  must be integrated coherently before enabling capture. Remote conditional saves
  still require an actual Apple before/after transition. No account data was read
  and no files changed by the agent; it was closed and shutdown verified.
- Generated binding/evidence import committed as `2e87833b6`; the separately
  reviewed native-only export fix committed as `b701e36a7`. Targeted Dart
  analysis found no issues. Fork source `b701e36a7f91276f940000800ff340de4392a801`
  is now running full Dart qualification in GCE `34629000411`, N2D-16 in
  `us-west1-c`, dart-only with both writer flags off. Do not duplicate this run
  or claim its result before completion. It does not compile the Android
  viewer or install a matching native library on Windows/Pixel.
- GCE `34629000411` completed on `b701e36a7`: 3,184 Dart tests, 14 semantic
  outbox cases and three evidence-output cases passed. Cleanup completed at
  17:51:15Z; independent VM and runner inventories were empty. The generic
  build-job label was not an APK build in this dart-only run.
- Parent integrated the separate local mutation journal foundation, entity 35
  and both protected-reference scans. Existing ObjectBox entities, properties
  and retired entity IDs are unchanged. Synthetic tests cover staged/claimed/
  confirmed/reflected reopen, duplicate receipts, session-bound replay, stale
  writer epochs, rollback, target drift and retained bytes/leases in all states.
  This remains unconnected to the ordinary app path or a remote save. The
  local reflection callback is a transaction seam, not proof of source-derived
  edit history or unsend projection. Stage/commit/recovery composition remains.
- Parent reproduced three route-substitution failures: the initial journal
  accepted otherwise-valid mutations with a different sender, peer or chat.
  The wire identity now binds a content-free route digest checked independently
  against the target's persisted chat at capture and adoption. All three now
  reject before inserting an intent. Eight focused suites passed 351 tests;
  the run log is retained under local `build-evidence/mutation-journal-20260911`.
- Final parent review also rejects a projector changing routing or advancing
  writer authority during the transaction; both cases roll back all row changes.
  Targeted analysis found no issues. Filtered ObjectBox/Freezed generation
  completed successfully; existing warnings about unrelated DateTime fields
  and unsupported transient properties remain unchanged.
- Galileo's helper/tests were reviewed. Parent corrected two syntax defects,
  replaced an inaccurate whitespace predicate with the native Unicode behavior,
  and added route verification. Helper eligibility remains conservatively
  limited to hyphenated UUID spellings; the native parser accepts more forms.
  Agent was closed, shutdown verified, and its shared source retained. The older
  upload-result worker was also closed after confirming its work was already
  integrated at `925b02181`; no descendants or dedicated worktree existed.
  Supported session deletion is unavailable, so transcript provenance remains.
  C: free space was 49.7 GiB; no evidence, credentials or user data was removed.
- Checkpoint `f24e7379f` was committed and pushed to the fork only. GCE
  `34631352089` now runs dart-only qualification on that source, N2D-16 in
  `us-west1-c`, both writer flags off. The preceding VM/runner inventories were
  empty; no quota or infrastructure configuration changed. Windows fast-loop
  `34631493537` independently builds the matching native API on the same source
  with the unchanged qualified pilot `9c63ab24d`. Its local-write option only
  selects compilation; no valid account launch, Apple credential, message send
  or remote save occurs on the hosted runner. Bundle import/local signing and
  runtime qualification remain pending; retained Windows/Pixel apps are unchanged.
- GCE `34631352089` finished with 3,220 passing and three failing Dart cases.
  All failures were stale model-upgrade fixtures after entity 35 was added:
  old entity-32/33 fixtures accidentally retained the new entity, and the
  current-schema assertion still expected last entity 34. The parent corrected
  all three and added an entity-34 upgrade followed by two opens preserving
  existing chats, messages and local-send intents. A direct predecessor/current
  model comparison found 26 unchanged entity definitions and unchanged retired
  entity IDs. No real user database was opened or migrated. Cleanup succeeded
  and independent GCE/runner inventories were empty.
- Added mutation protected-source preparation: capture the persisted target,
  reuse an unclaimed source or stage/adopt it once, commit the original lease,
  restore/validate the exact native wire, then claim once under current auth.
  Both exclusions release before the caller could submit IDS. Failed adopted
  commits remain recoverable without a second stage; post-claim interruptions
  stay unknown, never automatically resendable. Tests cover edit and unsend,
  commit/reopen, altered target/wire/auth, busy exclusion and mismatched store.
  The first local run exposed a synchronous preflight exception; the async
  boundary is now consistent. A new migration test initially used a nonexistent
  constructor field; it was corrected to the actual existing send entity.
- Live native confirmation and cold replay now dispatch mutation-purpose
  receipts to the separate journal. Unknown receipts stay retained; original
  native-session binding still applies on replay. Neither the create writer
  nor generic receipt acknowledgement is reached. Ordinary edit/unsend capture,
  exact-source local projector and conditional CloudKit updates are still not
  enabled; the next real integration target is the matching Windows fast loop.
- Parent reviewed Astra Boole's bounded FaceTime remote-leave diagnostics.
  Accepted as default-off observation only, not a calling fix or protocol reason.
  Reported targeted validation: 74 Kotlin, 49 Flutter and 63 JavaScript tests;
  Android Activity/channel compilation and live calls remain unqualified.
  Agent was closed after review and shutdown was verified. No descendants or
  dedicated worktree existed; shared source and provenance remain necessary.
  Supported session deletion is unavailable. C: had about 49 GiB free and no
  user data, protected evidence or session was deleted.
- Final combined local qualification passed **410 tests across 12 suites**:
  mutation identity/journal/source, send source/journal/recovery, reactions,
  upload journal, ObjectBox store/migration, receipt and production composition.
  An initial cohort command named a nonexistent reaction test file (402 real
  cases passed); the corrected command validates every suite path first and
  passes as a whole. The new/modified CloudKit source analysis is clean; the
  shared service retains four pre-existing style infos outside these changes.
- CloudKit composition/fixture repair committed as `c988a5844`; reviewed
  FaceTime diagnostic changes committed separately as `99d45a9c7`. Shared
  service hunks were staged by subsystem and reviewed before committing;
  unrelated generated/native/tooling edits remained untouched. Both commits
  were pushed only to the fork. Full Dart rerun `34633136729` targets exact
  `99d45a9c7a0cf21be2ecbcaea3ea673e402c870d`, with the unchanged isolated
  pilot `9c63ab24d`, N2D-16/us-west1-c, both writer flags off. Previous-run
  cleanup and empty GCE inventory were verified before dispatch. Windows
  `34631493537` continues its original native build on `f24e7379f`; no duplicate
  native build, APK, account operation or device installation was started.
  Final run/cleanup results remain pending. C: free was 49.3 GiB.

### September 11, Windows mutation submission and qualification

- GCE `34633136729` passed 3,237 Dart tests and the 14 outbox/3 evidence-output
  cases on `99d45a9c7`. Cleanup and independent empty VM/runner inventories
  were verified. Windows `34631493537` passed 38 focused Dart cases, 51 actual
  packaged-DLL codec cases and ARM64 invalid-launch/load smoke on `f24e7379f`.
  Artifact `10277865440` remains unimported; existing signed runtimes preserved.
- Native `db5c1508c` adds a Windows-only-profile confirmed mutation API: exact
  committed source, full IDS job and positive recipient acceptance, unchanged
  authentication, then durable mutation-purpose receipt. Four new tests pass
  alongside the native cohort: GCE `34634299421` passed **517 Rust tests** and
  compilation. Only expected generated-binding drift failed. Artifact
  `10277519451` SHA-256
  `c1aaad49e9bf1e4cb466d0f8cd682a2812efcf07fea73addf6a8c6c11e48bbbf`
  was verified before importing its exact seven-file allowlist. Three files
  have logical changes. Cleanup succeeded at 18:47:41Z; inventories empty.
- Reviewed Muse Euler's parser and target tests. Request v6 binds direct
  edit/unsend part 0 to an exact earlier successful test request. All v1-v5
  bindings remain compatible. The first regression attempt lacked ObjectBox
  on PATH; rerun with the existing ARM64 library passed. Duplicate GUID setup
  correctly fails at the database unique index; the test records that boundary
  rather than claiming to exercise an impossible duplicate row.
- Parent blocked mutation fall-through to the ordinary initial-create branch
  and wired a distinct Windows mutation path. A flushed exclusive claim
  precedes staging and sending; journal/source adoption, committed restore,
  final target/auth checks, one IDS send and exact positive receipt retention
  are composed. Failed/ambiguous claims can only reconcile native receipts
  after restart, never resend. No CK save, body reflection or receipt ack.
  Fresh first-pristine plaintext parents only, with a deliberate 60-second
  experiment window. Chained edits and general app capture are not enabled.
- Parent added timeout, wrong-purpose receipt, post-send identity change,
  after-prepare target change and reopen regressions; the combined local
  request/target/journal/confirmation cohort passed **75 tests**. New source analysis is
  clean. The Windows harness now points to the exact new native API, requiring
  a matching native build; no old-DLL content-hash bypass or account launch.
- A projector prerequisite remains explicit: original mutation source starts
  at timestamp zero; native preparation supplies the actual wire timestamp.
  Local reflection/CloudKit summary generation must qualify the retained time
  semantics rather than copying zero or guessing from receipt arrival.
- Euler's work was reviewed and accepted, the agent closed and shutdown
  verified. Shared uncommitted source/tests and transcript provenance remain
  necessary; no dedicated worktree exists and supported session deletion is
  unavailable. No user files, profiles, credentials, device evidence or logs
  were removed. C: free approximately 49.3 GiB. No Pixel operations this pass.

## 2026-09-11, exact mutation time and source-derived local reflection

- Native `6b59bf45107cb0ce6298222634b0e6ac7ef7838b`, GCE `34637298156`:
  generated bridge compilation and **524 Rust tests passed**. Only the expected
  generated-file drift gate failed. Artifact `10279009262`, SHA-256
  `d50bd8543397234c46561eb53d715f00e9acfe7ff81e87ed6b39476a15325d99`,
  was verified before extraction against an exact seven-file allowlist. The
  three changed files carry optional `preparedSentTimestampMs`; all seven local
  generated files compare equal to the artifact. Cleanup succeeded and both
  independently queried GCE and GitHub runner inventories were empty.
- Windows `34635971964` succeeded on earlier source `89c06f4de`: 38 focused
  Dart tests, 51 actual packaged-DLL codec cases, ARM64 load and invalid-launch
  smoke. Artifact `10277893755` is retained in GitHub, not downloaded or
  installed. It does not have the newer receipt serialization; no Dart-only
  overlay may combine the new receipt API with that predecessor DLL.
- Dart journal receipt proof v2 binds the prepared time exactly. Historical
  no-time receipts retain byte-identical v1 proof and acceptance evidence, but
  cannot authorize reflection. Changed-time, removed-time and added-time
  receipts fail after reopen without rewriting the stored proof or source.
- Parent connected source restoration, receipt proof and pure local projection
  under the existing protected-store and authentication exclusions. Snapshot
  comparison and message/journal writes share an ObjectBox transaction. Failed
  or delayed reflection preserves newer text, the protected source and receipt.
  Unsend retains original bytes and marks only part zero retracted. It creates
  no initial-send intent or CloudKit outbox entry and acknowledges no receipt.
- Windows request-v6 now reflects only its own confirmed source. Restarts read
  the original protected receipt even after local reflection, with the existing
  replay fence. Missing receipts or unprojectable time stay explicit failures;
  no path resubmits a claimed mutation. Remote update remains disabled.
- Local qualification: **245 tests passed** in the combined ten-suite cohort;
  **eight pure projection tests passed** for exact target/source, fresh empty
  summaries, multiple flagged UTF-16 runs, second edits, preserved history,
  legacy Apple-time comparison and no resurrection. The first new timestamp
  test compared UTC and local DateTime objects; comparing the same UTC instant
  correctly preserves the ObjectBox invariant. The first wider run exposed one
  old source-contract prohibition of all reflection, now narrowed to permit
  only the staged, receipt-bound path while prohibiting initial-create writes.
- Agent Kant's committed receipt contribution and partial projection draft were
  reviewed. Parent corrected the draft's missing wire-to-target comparison,
  fresh-summary rejection, redundant original-row parameter, prior-history
  comparison and timestamp heuristic. No agent-authored projection test file
  was delivered; parent implemented and ran the eight tests. Agent close
  succeeded and the subsequent control lookup returned `not_found`. No dedicated
  worktree or child process was reported. Session provenance is retained because
  supported session deletion is unavailable; no shared database was edited.
- No Apple account operation, Pixel install or reset was performed. C: free
  approximately 49.2 GiB. Existing app profiles, rollback binaries, requests,
  claims, unrelated edits and evidence remain intact. Full Dart and exact-source
  Windows qualification are next; no production completion is claimed.

## 2026-09-11, full Dart qualification and Windows mutation preflight

- Exact application source `d54e2238b49681cc80e51887c706463c1a76d362`
  passed GCE `34639474394`: **3,278 Dart tests**, 14 semantic-outbox contract
  cases and three evidence-output cases. This was the Dart-only lane despite
  the generic APK job label. No APK, signing or Apple account operation ran.
  Cleanup succeeded; independent GCE and GitHub inventories returned zero
  instances and zero registered runners.
- Matching Windows ARM64 build `34639474581` is compiling the exact source.
  A clean detached checkout `windows-cloudkit-qualified-d54e2238b` and an
  exact-source import script are prepared. The import has not run. It verifies
  provenance, archive and individual file hashes, the 51 packaged native-codec
  cases, native load and invalid-launch smoke. It preserves the current private
  profile, previous build receipt and all existing runtimes, including the
  reaction-05/06 claims. Vendor ObjectBox bytes are never re-signed.
- Extended the existing copied-database inspector for request-v6. It reports
  exact target/route, stored edit text or retraction, journal markers and any
  incorrectly created initial-send intent. Its scope is explicitly DB-only;
  it never promotes marker presence into native acceptance or CloudKit-update
  proof. Eight inspector tests pass, including restart, wrong target/source,
  missing display time and confirmed-but-unreflected rows. The initial test
  compile exposed fixture misuse of `Content` and the empty-summary factory;
  those were corrected. Targeted analysis and exact-file whitespace checks pass.
- Ran the inspector against a temporary copy of the existing private Windows
  database. Reaction-06 still has exact-source validation, one canonical
  message, matching target and persisted readback, with the confirmed receipt
  released. Database/request/claim hashes were unchanged; the temporary copy
  was removed by the inspector's exact generated-file cleanup. No Apple call.
- Prepared, but did not execute, a bounded live experiment for the approved
  test recipient: fresh synthetic parent, one edit or unsend, then a
  receipt-only separate-process restart. It refuses existing experiment
  claims, archives private requests, preserves checkpoint evidence, and keeps
  CloudKit existing-record updates disabled. The Windows import and exact-source
  smoke must pass first. C: has approximately 48.9 GiB free; no agents are active.

## 2026-09-11, live mutation exposed the no-response confirmation mismatch

- Windows `34639474581` completed in 23m16s on exact `d54e2238b`: 38 focused
  tests, 51 packaged-native codec tests and smoke passed. Artifact `10280247398`
  outer SHA-256 `02f812af098bc28211c215237f67e7eca8de39b0bf88da5291046d11e8e4d053`
  was verified against GitHub. Seven exact outer entries and 78 inner files
  were verified; inner bundle SHA-256
  `4571234e9359e3f5a252b4f1e44e1a1d8db914175c9a83d0a080b26758b6acc7`.
  Local import qualified at 19:58:13Z, native load/unload and invalid-launch
  marker passed, zero dummy-profile files appeared, and protected profile
  hashes stayed unchanged. Five engineering binaries were signed; vendor
  ObjectBox bytes and local security policy stayed unchanged.
- Reaction-06 reopened at 19:58:52Z with zero admissions, zero deferrals and no
  blocked/readback-pending outbox work. The next synthetic plaintext parent-07
  received positive IDS confirmation, one admission and exact CloudKit readback.
- Edit-08 failed at 19:59:47Z with native fixed error
  `cloud_sync_windows_sender_unconfirmed` (mapped from diagnostic SHA-256
  `a2f98e38ed986249f6a456949bad6ce2d7113c48b28648aeb8dd19c2b568fa1a`).
  Copied-database inspection found one claimed mutation (state 1), structurally
  valid source, exact target/route, no receipt marker, no reflection, zero
  initial-send intents for the mutation and outbox count nine. The original
  database was unchanged by inspection. No restart/resend or unsend test ran.
- Root cause is a protocol-mode mismatch, not another login regression:
  `Message::get_nr` returns `Some(true)` for Edit and Unsend, and IDS constructs
  `SendConfirmation` with `supports_confirmation=false` in that mode.
  `require_confirmed` must then reject it regardless of successful dispatch.
  Delivery itself remains unknown. The [upstream implementation at f35c4ee](https://github.com/OpenBubbles/rustpush/blob/f35c4ee062b3c3eae54dc96b89b90ee99f5e1d0c/src/imessage/messages.rs)
  uses the same no-response convention. GitHub lookup supplied no proof that
  opting into acknowledgments is accepted for this command; live proof remains.
- The candidate adds an explicitly named opt-in mutation transport that clears
  only the no-response flag, checks command 118 and excludes queued, scheduled,
  relay, missing-body and overriding-extra shapes. It uses zero retries while
  ordinary sending retains its existing five-retry limit and no-response flags.
  Only the Windows mutation experiment calls it. Positive status zero for every
  intended recipient is still mandatory; no synthetic receipt or weaker 5008
  acceptance is added. Also added the observed fixed error to safe diagnostics.
- Inspector formatting cleanup accidentally removed its two new imports after
  initial qualification. The real copied-DB invocation caught this before any
  data access; imports were restored. Nine combined unit/real-inspector cases
  then passed, followed by 26 inspector/Windows-request tests. Native source
  parsing passed without compilation. New native compilation and tests remain
  required before another live experiment; no completed production gate is claimed.

## 2026-09-11, bounded acknowledgment candidate cloud qualification

- Dependency `98cc67a80eb76af605ed2449f1853a592282aa0d` and app
  `c02379430071ec8cabc5829d6370ad126027bcc2` are committed and pushed to the
  existing fork branches. No upstream PR, APK, account reset or signing-policy
  change occurred. Unrelated dirty files remain excluded.
- Local qualification: 26 Windows-request/inspector tests passed and targeted
  Dart analysis found no issues. Rust syntax parsing passed. Dependency run
  `34642902143` passed 299 tests, including both opt-in envelope tests, at
  20:14:57Z; compile took 53.98 seconds and tests 6.30 seconds. Cleanup is pending.
- Parallel app-native run `34642902097` uses N2D-16; dependency uses T2D-32.
  Global quota was verified at 164 CPUs, regional T2D 100/N2D 16, with zero
  preexisting instances/runners. The existing bounded lanes, cleanup and
  75-minute lifetime remain unchanged. Both remote writer flags are off.
- Windows exact-source build `34642902373` runs on GitHub-hosted ARM64 without
  Apple credentials. Prepared local import/test scripts live in its evidence
  folder. Preview selects fresh edit parent-11/edit-12 and unsend parent-13/
  unsend-14, with no execution yet. Existing edit-08 is never replayed.
- The one mutation attempt may enable the existing verbose-native toggle only
  for its bounded first pass, storing logs locally. The script restores the
  prior setting in a finally block. No private logs go to cloud runners.
- Existing-record review reconfirmed that decoding and reencoding a partial
  MessageProto model cannot prove unknown-byte preservation. Retain raw
  predecessor bytes; do not connect the conditional builder until genuine
  before/after semantics and conflict/readback reconciliation are qualified.
- No new agents were created; the previously verified closeout still applies.
  C: had 48.26 GiB free before the next artifact download. No evidence was deleted.
- Follow-up: dependency cleanup succeeded, and independent inventories retained
  only the active app-native VM/registration. App-native qualification passed
  524 tests at 20:20:24Z, compilation and exact generated-bridge comparison.
  Its test compile took 1m56s, tests 2.27s; its cleanup remains in progress.
  Windows compilation is still running. No new live mutation has been sent.

## 2026-09-11, Windows edit and unsend receipts/reflection proven

- Exact `c02379430` Windows run `34642902373` passed 39 focused Dart tests,
  51 packaged-native codec tests and smoke. Artifact `10281157306` outer SHA-256
  `9b4db4536d119730cb77843edd1f9a1becaad4342d488f7cfbc55013770070b9` and inner
  `0a0dd40d0f1e3ab66f2b3a8ef03c6a2aa3e9ca2dcf00a0c015d0c6baf90e0d16`
  were verified. Local import at 20:37:41Z verified 78 files, retained the prior
  runtime, passed native load and invalid-launch checks, and preserved protected
  profile hashes. No account data went to CI or signing-policy change occurred.
- Parent-11 stopped before claim at 20:38:12Z with
  `cloud_sync_native_auth_refresh_session_missing`. A bounded read-only launch
  of the same binary renewed the cache and finished at 20:44:47Z: fetched 0,
  applied 0, retained 6,654 and repaired one chat-order cache row. No new SMS was
  required. This does not establish the missing session's cause or full projection.
- The one-off preservation guard failed because it hashed all of `hw_info.plist`.
  Source review showed `setup_push` saves APS state and reencrypts the restored
  identity on connection. The guard's in-memory hashes were not retained, so it
  cannot retrospectively prove every file byte. Request-11 still matches its
  archive and is unclaimed; old write-claim timestamps remain unchanged. No
  reset or replacement hardware path ran. Preserve this guard failure as evidence.
- Fresh parent-15 passed IDS send and CloudKit save/readback. Edit-16 then passed
  positive IDS confirmation, native receipt retention, local reflection and a
  separate-process no-send reconciliation, completed at 20:46:57Z. Fresh parent-17
  and unsend-18 passed the same sequence at 20:47:56Z. Each experiment used only
  the approved test recipient. Existing-record cloud updates stayed off.
- Read-only inspection of disposable database copies independently found state 3,
  structurally valid source, receipt/reflection markers, exact target/route and
  stored display matches for both mutations. Neither created an initial-send
  intent under its mutation GUID. Original database/request/claim hashes stayed
  unchanged; two scoped inspector tests passed. Outbox row count was 11, not
  evidence of 11 pending writes. No independent recipient display is claimed.
- Raw MessageProto patch helper `a42ecb74f` passed all nine new cases within
  533 app-native tests in GCE `34644303016`; compile 2m07s, tests 2.60s, exact
  bridge regeneration and cleanup passed. Dependency/app runs `34642902143`
  and `34642902097` also cleaned up successfully. Independent inventories:
  zero GCE instances and zero registered runners. No APK was built.
- Follow-up Windows harness preflight calls the existing single-attempt read
  authentication recovery before constructing a writer. Recovery stops the
  original invocation; write failures never enter that catch. All 41 focused
  tests passed after correcting the test shell's missing ObjectBox DLL PATH.
  This patch is not in the live-qualified runtime and is not runtime-qualified.
- Astra child Anscombe's default-off, content-free FaceTime setup markers were
  reviewed and committed separately as `1ab2e7941`; parent reran all 36 focused
  tests successfully. No call-policy or timeout change and no live-call proof.
  Child shutdown was verified with `not_found`. No dedicated worktree or log
  bundle was created; transcript retained because supported session deletion
  and an exclusive transcript locator were unavailable. No shared session data
  or unrelated working-tree changes were removed.
- Final targeted analysis found no issues; the exact final 41-test rerun passed.
  End check: C: free 47.62 GiB, active checkout build 2.391 GiB and `.dart_tool`
  7.502 GiB. No live OpenBubbles process or new inspection scratch directory
  remained. Only verified disposable database copies used by the inspector were
  removed by its scoped cleanup; original data and all run evidence were retained.

## 2026-09-11, preserve predecessors and reconcile edit/unsend history

- Source review found typed `CloudMessage` lookup unsuitable as a lossless
  conditional-update predecessor. Rustpush `90787d3`, pinned by app `c092ef1a7`,
  adds native-only `lookup_message_record_version`. It preserves decoded record
  fields, opaque encrypted values and metadata, validates full identity/type/ETag,
  and redacts debug output. Existing typed lookup delegates to it. General
  container and cached PCS are checked before the read, and the container is
  revalidated afterward. No save, asset fetch, key creation or trust mutation.
- GCE dependency-only `34647348048` passed 305 tests, including six new version
  tests/contracts. Tests completed at 21:06:04Z in 6.30s; runner cleanup succeeded
  at 21:07:53Z. The run used source-only T2D-32 with both writer flags off.
  App-native compatibility `34647652095` passed 533 tests in 2.59s and exact
  bridge regeneration, with cleanup completed at 21:14:59Z.
- Astra child Ptolemy identified a real two-line encoding error: strikethrough
  presence and value were read from italic. Parent reviewed, reran the four
  regressions, and committed `e35c8382c`. The combined Windows/encoding cohort
  passed 45 tests. Analysis of the existing message file reported 11 unchanged
  warnings/info, including two unused imports; no clean-analysis claim. No
  unrelated formatting or generated-file cleanup was included.
- A second concrete mismatch appeared while tracing summary preservation.
  Both legacy unsend and journaled local projection retain edit history/edited
  part IDs while adding the retracted part. The canonical reader rejected that
  overlap before validating history. `5bb07dcdf` removes only that exclusion:
  history is not current visibility. Timestamp/body/part checks still run.
  The old quarantine enum is retained for persisted data and bridge compatibility.
- New native coverage expects the original and edited revisions plus retraction
  to survive conversion; fractional timestamps remain deferred even when the
  part is retracted. GCE app-native `34648004825` passed 534 tests in 2.51s
  at 21:17:40Z and exact bridge regeneration. All 136 local
  ObjectBox/projection tests passed, including the strengthened real-store case
  with history and retraction in one page, database reopen, stale replay and an
  unsent UI model. This proves the app contract, not independent Apple authoring
  or recipient display. No existing-record CloudKit writer was enabled.
- Ptolemy's advice was reviewed, the encoding patch integrated, and shutdown
  verified with `not_found`. No dedicated worktree or per-agent log bundle was
  created. The session/transcript was retained because supported deletion and
  an exclusive artifact locator were unavailable. Protected/unrelated files,
  device data, evidence and credentials remain untouched. C: free 47.54 GiB.
- Final qualification cleanup completed at 21:19:27Z for `34648004825`.
  Independent inventories then showed zero GCE instances and zero registered
  GitHub runners. All three scoped runs succeeded. No APK or Windows runtime
  was rebuilt or installed, and no Apple credentials or user content went to CI.
  Final local generated output remained 2.39 GiB in `build` and 7.50 GiB in
  `.dart_tool`, with about 47.55 GiB free. No manual artifact deletion occurred.

## 2026-09-11, qualify conditional-update staging and retained receipt proof

- App `b8b27bee3` adds native-only immutable update staging under a separate
  protected purpose and bounded summary mutation. Exact predecessor, ETag,
  encrypted request, source/authority digests and attempt UUIDs remain pinned.
  Reopen requires an exact committed lease. No network write is enabled.
- Parent review of Astra's summary patch retained singleton histories, unknown
  plist values and old attributed-body bytes. Follow-up `d07ecf6ff` accepts the
  reader's legacy whole Unix-millisecond dates alongside Apple-second dates,
  normalizing only comparisons, never rewriting historical values. Its composed
  edit-then-unsend test uses the actual attributed-body encoder, lossless proto
  patcher and message converter, including unknown outer protobuf field bytes.
- GCE `34650028801` compiled and regenerated the exact bridge, then passed 549
  tests and failed three staging cases with `ProtectedStorage`. The new purpose
  had not been registered in the native protector allowlist. `3260dc506` fixes
  that omission and bounds the nested envelope to 9 MiB for the existing 18 MiB
  protected-file limit. The failed run cleaned up at 21:43:07Z; independent
  inventories showed zero instances and zero GitHub runner registrations before
  the corrected run began. Pending obsolete run `34650475225` was canceled
  before any job existed and created no runner.
- Corrected exact-source run `34650587629` passed all 554 native tests in 2.74s
  at 21:50:15Z, exact bridge regeneration and cleanup at 21:52:03Z. No APK or
  signing occurred despite the generic job's APK label. Both writer flags were
  off; the source-only runner used T2D-32 and no Apple credentials.
- `8d98a8c56` extracts exact, non-consuming receipt verification from the
  existing protected acknowledgement path. Missing receipts fail verification
  while repeated acknowledgement remains idempotent. A native integration seam
  joins that verification to committed mutation-source reopen and current auth.
  Historical send sessions remain valid under the same store/account after a
  cold login; no replacement IDS send or invented wire time is allowed. Three
  new tests cover cold reopen, source/receipt/auth substitutions and retained
  timeless historical evidence. Exact-source GCE `34651357165` passed 557 native
  tests in 2.76s at 21:59:18Z and exact bridge regeneration. Compilation plus
  tests took 1m38s; the native job took 5m52s. Cleanup completed at 22:01:12Z.
  Independent inventories then showed zero GCE instances and zero registered
  GitHub runners. Both source-only qualification runs are fully complete.
- Reviewed Muse patch `9a8fd6d50` requires the outgoing FaceTime join to match
  the session and an active non-self participant in the refreshed snapshot.
  Self, missing, stale and unrelated join events no longer count as acceptance.
  Parent reran five focused suites: 53 tests passed. This is source/test proof,
  not a live-call fix claim or an installed APK.
- Both child agents (Pasteur and Godel) had their work reviewed and integrated;
  shutdown was verified with `not_found`. No dedicated worktrees/log bundles
  were created. The agent's stray helper copy outside the checkout was removed
  and its absence verified. Transcripts remain because an exclusive artifact
  locator and supported session deletion were unavailable. No shared databases,
  unrelated changes, user data or evidence were deleted. C: free 47.26 GiB;
  existing checkout outputs remain about 7.50 GiB `.dart_tool` and 2.39 GiB build.
- Next boundary is causal candidate preparation and atomic journal/outbox
  adoption, then exact conditional submission/conflict/readback. The new helpers
  alone do not establish live CloudKit edits/unsends. Alpha, Canary, the Windows
  runtime, account credentials and messages were untouched during this work.

## 2026-09-12, exact-source Canary progressively projected live history

- Exact committed source `883f001868ac64a160c20018b2fb46e3aedb029e`
  passed Build workflow `34727839709`, Rust bridge workflow `34727839730`,
  and Windows validation `34727839757`. The Build workflow included the full
  Dart suite, diagnostic scan, FaceTime replay, all 119 Android JVM tests,
  APK/native-library verification, stable Canary signing, and artifact upload.
  CI used no Apple account or message data.
- The signed Canary was installed in place at 17:57:09 Pacific. Package
  `com.bluebubbles.messaging.cloudkitcanary` reported version `1.15.0`
  (`20002227`) and retained its stable signature and existing app data. The
  running semantic reports identify the same exact build commit.
- Live preflight remained healthy throughout the observed run: setup and auth
  ready, legacy sync off, coordinator active, and semantic outbox empty. The
  phone stayed awake while plugged in. The user observed two real messages,
  then additional conversations and messages, appearing progressively in the
  normal Messages UI. This closes the former “records fetched but nothing is
  visible” counterexample for this exact run; it does not prove full drain.
- Completed content-free slices preserved remote saves/deletes off and outbox
  `0 -> 0`. Message projection accelerated as Chat parents became available:
  the first two slices applied 1 and 2 Messages, a later slice applied 247,
  and the next applied 198. The latter slice also observed the Chat zone's
  terminal empty read. Its remaining retained counts were 94 Chats, 308
  Messages, and 983 Attachments; many are explicitly out-of-scope SMS/RCS,
  tombstones, malformed records, or children still waiting on parents.
- The semantic coordinator was still active at the checkpoint, so no terminal
  drain, idempotent replay, background/lock, or restart qualification is
  claimed. Do not start a second pull, clear caches, or force-stop this run.
- Current-source update safety was rechecked locally: the confirmation,
  mutation-adoption, and native update cohort passed 39 tests with one
  intentional native-live skip. Current code fails closed before IDS if V2
  owns the mutation but preparation is unavailable, retains terminal source
  evidence through exact readback, finalizes protected leases before receipt
  acknowledgement, and emits content-free correlated stage markers. Pixel
  edit/unsend and independent-recipient display remain release gates.

## 2026-09-12, current-state consolidation

The following sections were moved verbatim from the treemap, preserving
source-specific evidence and obsolete next steps. The current treemap overrides
these historical instructions. No qualification evidence was deleted.

## Current candidate

| Item | Current state |
| --- | --- |
| App branch | `agent/cloudkit-v2-update-seam` at exact committed source `883f001868ac64a160c20018b2fb46e3aedb029e`. Generated bridge output is reproducible. The checkout has only unrelated generated desktop-plugin drift; do not fold it into the candidate. |
| Conditional-update executor candidate | **TEST-PROVEN and installed, not independently display-proven:** the retained positive IDS receipt admits one exact version-checked update, preserves the original record identity/ETag, submits once, and reconciles only by exact readback. The repaired order commits native evidence, clears the mutation fence, finalizes ObjectBox, and acknowledges receipts last. Current source also fails closed before IDS when V2 owns mutations but runtime preparation is unavailable, and retains terminal source evidence until exact readback cleanup. A September 12 rerun of the confirmation/adoption/update cohort passed 39 tests with one intentional native-live skip. |
| Confirmed-create raw predecessor retention | **TEST-PROVEN, not installed:** live request 20 proved a real Message create and exact restart readback. Edit request 23 exposed that its map retained the ETag but not the exact raw record. The repair performs one no-save exact readback, adopts its raw capability in ObjectBox, commits the native readback lease, finalizes ObjectBox, then acknowledges the source and readback receipts. Manual confirmed replay now resumes an already-adopted readback locally before any new remote fetch, preventing duplicate leases and `message_create_readback_already_pending`. Create and update pending states remain distinguished by equal versus changed ETags. |
| Conditional-update predecessor | **TEST-PROVEN:** app `c092ef1a7` pins rustpush `90787d3`. Native `lookup_message_record_version` retains decoded CloudKit fields, opaque encrypted payloads and exact identity/ETag without a typed `CloudMessage` roundtrip. The old typed lookup delegates to it; current-container and cached-PCS checks remain. GCE dependency-only `34647348048` passed 305 tests and cleanup; app-native `34647652095` passed 533 tests and exact bridge regeneration. No update/save path is enabled. |
| Conditional-update staging | **TEST-PROVEN, not enabled:** exact `3260dc506` passed 554 native tests and bridge regeneration in GCE `34650587629`; cleanup completed at 21:52:03Z. Protected staging retains the original predecessor, conditional merge request, ciphertext, ETag and request IDs. Summary patching preserves unknown plist values, singleton history and both supported timestamp formats. A composed test passes edit then unsend through the real message converter without discarding unknown protobuf fields. The first qualification exposed a missing protected-purpose allowlist entry, now fixed. These helpers do not authorize a save. |
| Conditional-update source proof | **TEST-PROVEN:** exact `8d98a8c56` passed 557 native tests and bridge regeneration in GCE `34651357165`; cleanup completed at 22:01:12Z, with independent instance/runner inventories empty. It reopens a committed mutation source plus its exact encrypted positive IDS receipt, without consuming either. Current login and historical send session are checked separately, permitting cold recovery without resending IDS. Missing, changed or timeless receipts do not supply update authority; legacy evidence remains retained. The preparer and journal/outbox integration remain unconnected. |
| Edited-then-unsent readback | **TEST-PROVEN:** `5bb07dcdf` removes the reader's mutual-exclusion rule for edited/retracted part IDs. Both existing producers retain that history on unsend; the DTO and projection already support it. Timestamp/body/part validation remains. All 136 focused Dart tests passed, including real ObjectBox reopen and stale replay without resurrection. GCE `34648004825` passed 534 native tests and exact bridge regeneration; no Apple-device or APK proof yet. |
| September 11 mutation candidate | **LIVE-PROVEN on Windows, IDS/local scope only:** `c02379430` with dependency `98cc67a` passed fresh edit-16 and unsend-18, each with positive IDS acknowledgment, retained native receipt, local reflection and a separate-process reconciliation without resending. Both parent messages passed CloudKit save/readback. Copied-DB inspection confirmed state 3, exact stored display and zero initial-send intents for each mutation; source DB unchanged. Existing-record CloudKit updates remain disabled, and independent recipient display is unverified. Old edit-08 stays unknown and must never be resent. |
| Installed Android candidate | Signed exact source `883f001868ac64a160c20018b2fb46e3aedb029e`, installed in place on Canary September 12 at 17:57:09 Pacific with its stable package/signature and existing data preserved. Authentication is ready, legacy sync is off, the V2 outbox remains `0 -> 0`, and the user observed real chats/messages progressively appear during the active semantic catch-up. Completed content-free slices advanced from 1-2 projected Messages to 247 and then 198 per slice as parent dependencies resolved. The run remains active; this is positive progressive-read evidence, not a terminal drain or lifecycle qualification. Alpha is untouched. |
| Qualified source, not installed | Read-transition `90f98b7eb` passed 296 focused tests, targeted analysis, and GCE `34594546421`: 3,147 Dart tests plus 14 outbox and 3 evidence-output cases. Cleanup completed at 11:44:17Z; independent VM/runner inventories were empty. It includes replay repair `fd60a8a20` and background patch `0bb67d2c4`, which avoids repeating exhaustive retained-history sweeps on routine metadata wakes. No APK or Pixel runtime proof for these patches yet. |
| Windows candidate | Imported `c02379430` from `34642902373`: 39 focused tests, 51 packaged-DLL codec cases, 78 verified bundle files, native load and isolated invalid-launch smoke passed. Protected profile hashes stayed unchanged during import. Dependency run `34642902143` passed 299 tests; app-native `34642902097` passed 524 tests and exact bridge regeneration. All cleanup completed. A read-only pass renewed the missing auth cache before live writes; no reset or new code was needed. The follow-up preflight repair is test-proven only, not in this imported runtime. |
| Current full qualification | Exact source `883f00186` passed the full Build workflow `34727839709`, including the Dart suite, diagnostic scan, FaceTime replay tests, all 119 Android JVM tests, APK packaging/native-library checks, stable Canary signing, and artifact upload. Rust bridge workflow `34727839730` reproduced bindings and passed both Rust suites plus protector tests. Windows workflow `34727839757` passed x64 checks and ARM64 bootstrap/public-binary gates. These CI results contain no live Apple-account proof; the separately installed Canary supplies the live read evidence above. |
| Qualification | GCE `34485566441` passed 2,566 Dart tests plus 14 semantic outbox and 3 evidence-output cases on exact source `7df4fced8`, including the new real ObjectBox manual-selection tests. Cleanup succeeded and both VM and registration inventories were empty. This dart-only run did not build an APK or native Windows binary. Earlier full signed qualification `34444190598` covers installed code `e060bcb41`, not the new patches. Native base `35551340c` passed 377 app Rust and 260 rustpush tests. Live ordinary-send/save/readback remains separate. |
| Main change | Direct and restored-group plaintext admission, IDS receipt recovery, protected reset proof, crash-safe generation rebootstrap, bounded replay, manual read/write gates, and a Canary-only durable Android metadata wake are wired with automatic uploads off. The wake stores only the exact semantic-scope hash, revalidates the live account and safety state in Dart, and cannot invoke the outbound writer. |
| Dependency | App `2fd0da2a3` pins `aff6379`, including the reviewed FaceTime remote-target guard and default-off bounded Find My diagnostics. GCE `34589003289` passed 287 dependency tests; cleanup completed at 10:32:58Z. No sidecar runtime success is claimed and no APK includes them yet. Writer fix `d201fb5` adds the exact attachment zone; IDS-proof base `f2e8ea3` still requires status 0 for every intended recipient. |
| Prior-source qualification | GCE run `34437410835` fully succeeded for exact source `75440cafc`: full Dart suite, 373 app Rust tests, 253 rustpush tests, 34 protector tests, bridge drift checks, APK/native-library verification, Android JVM tests, trusted signing, and cleanup. This APK lacks the new positive-acknowledgment repair and is not a write-qualified release candidate. Older `fc132e5f8` also has the headless ready-handshake deadlock. |
| Android release proof | The signed `ad822f37c` APK was installed in place with Canary data preserved and Alpha untouched. Its live read-only pull drained the remote head in one pass and finished without an unsafe failure. The final local sweep completed Chats with the exact 476-row durable backlog, kept remote save/delete disabled, and kept outbox `0 -> 0`. Messages and Attachments remain honestly degraded with 1,893 and 1,693 blocking saves respectively. |
| Production claim | Not yet allowed. |

Next technical gate: qualify the integrated conditional existing-record writer
on Android and independently verify the recipient-visible result. Read-transition
candidate `90f98b7eb` passed GCE Dart-only qualification `34594546421`; the prior
blocking IDS/local subgate passed on exact `c02379430` at 20:46:57Z (edit-16) and
20:47:56Z (unsend-18). The current working tree now connects that exact confirmed
source to a separate durable update lane without weakening message-create rules.

Completed in the current working tree:

1. The native confirmed-source opener is bound to the journal's exact retained
   receipt. State 3 alone does not authorize a CloudKit update.
2. The original record version is fetched under existing auth/PCS fences and the
   source-proven mutation preserves opaque fields, nested data and the original
   conditional ETag.
3. The staged update is atomically adopted into its own versioned outbox lane;
   `cloud_sync_prepare_message_create` remains create-only.
4. Submission is single-attempt per retained request. Conflict or unknown outcome
   enters exact readback, never a new IDS send or replacement predecessor.
5. Restart and teardown retain and replay the native receipt only while the exact
   operation remains eligible. Native evidence is acknowledged only after durable
   outbox confirmation and protected-source finalization.

Remaining qualification, in order:

1. Commit the crash-recovery repair, run exact-source full GCE qualification, then
   build and independently verify a signed Canary. APKs from `34700082731` and
   `34712211230` are superseded and must not be installed.
2. Retry existing edit request 23 in reconciliation-only mode. Prove the retained
   create gains its exact raw predecessor, the edit reaches exact CloudKit
   readback, and no duplicate IDS mutation is sent across restart.
3. Independently verify recipient or second-client display. Same-client local
   reflection is not sufficient production evidence.
4. Exercise one conflict/unknown-outcome recovery on the installed candidate and
   confirm the original receipt, predecessor and operation identity remain stable.

Preview repair `269620126` and reviewed Find My lane isolation `ee9729ec3`
passed GCE Dart-only `34597175527`, exact source
`ee9729ec32fc132b386e4cbd42e608424968dbec`: 3,167 Dart tests plus 14 outbox
and 3 evidence-output cases. The test step took 4m30s; cleanup completed at
12:18:21Z and independent VM/runner inventories were empty. Both writer flags
were off; no APK, signing, or native compilation was requested.
The real inbox merge and ObjectBox test now applies an edit, rejects an
unproved changed body, preserves current text on an older replay and applies
an unsend after reopen. The four focused suites pass 296 tests. Full-suite GCE
qualification passed; installed-device proof remains separate. The original memory
regressions now opt in explicitly to the proof capability; the real-store
test, not those fakes, demonstrates the combined path.

Next device gate: finish normal Canary authentication, then exercise the
combined signed Android source and independently verify
written content on the recipient/second-client side. Runtime parent admission,
separate-process no-op write restart and two cold read-only launches now pass.
The same client has not ingested the written Message; absence of a self-echo
does not invalidate exact record readback or prove cross-device visibility.
The offline v4 inspector lacks the real retained-child proof reader and must
remain diagnostic-only, not become another mandatory rewrite. Restored groups,
Android reactions and independent Apple-device visibility remain separate requirements.
The September 10 offline Windows inventory found **zero** chats with exactly
the two approved test recipients. Do not select another personal group. The
new request-v3 route binds the entire member set and exact restored group GUID;
its journal/adapter selection passed local qualification (174 focused tests,
including exact adopted-group selection after database reopen). This does not create
groups or bypass the existing protected semantic dependency. Live group proof
needs the approved conversation restored/created first. Direct-reaction work
and attachment integration can proceed independently of that prerequisite.
Current private request `qualification-20260911-unsend-18` completed receipt-only
restart. Edit-16 and unsend-18 both have persisted local state 3; their parents
15/17 have exact CloudKit readback proof. Old edit-08 remains claimed without a
receipt and must never be resent. Parent-11 failed before claim during auth
preflight and remains unclaimed. Prior plaintext, attachment, reaction and all
mutation evidence remain preserved. Qualified runtime:
`../windows-cloudkit-qualified-c02379430`. The read-only renewal guard incorrectly
required byte-identical `hw_info.plist`: `setup_push` reencrypts the retained
identity and saves APS state on connection. This is not an account-reset signal;
future guards must compare stable identity/configuration, not randomized ciphertext.
Older runtimes and receipts remain rollback material.

### Current attachment-write boundary

```text
committed original IDS source
  -> source-derived attachment inventory
  -> retained upload plans (one original randomized plan per child)
  -> durable byte-upload result
  -> Attachment record save and exact readback
  -> parent Message admission, save and exact readback
```

| Boundary | Evidence / next gate |
| --- | --- |
| Canonical identity | Native upload, final record and readback use the same owned `(message, part)` key as ingestion. Do not rekey older retained plans. |
| Native direct parent | Source `787869904`, GCE `34544585837`: **484 Rust tests passed**. Included in later native qualification below. |
| App integration | Candidate connects plan reuse, upload execution, ordered record drain and parent admission. A versioned journal proof requires every source-derived child to pass readback. Save acknowledgments and generic receipt cleanup cannot stand in for readback. |
| Local qualification | Combined admission/journal/dependency/transport/composition suite: 278 passed. Timeout/reconciliation/transport subset: 42 passed after parent review. These overlap and do not establish live-account behavior. |
| Timeout correction | Release tracked preparation before draining record saves. Otherwise a save timeout can quiesce the outer operation that is waiting on that save. A dedicated sequencing test covers this boundary. |
| Group attachments | Native `d5b31d5b9`, GCE `34547723829`: 490 Rust tests passed; only generated-interface drift failed. Artifact `10179880441` was hash-verified and imported; VM/runner inventories empty. Exact restored group binding is pinned before staging and after awaits. Local transport passed 15 tests, admission 73; no live group-attachment proof. |
| Recovery | Original source, epoch and attempt IDs remain immutable. Under current stable authority, the coordinator reuses existing plans and stages only missing entries from the original native inventory. A newly ambiguous upload may schedule only its own receipt-first next pass after native quiescence, exact fence/attempt verification and unchanged identity. Parent's composed guard/consumer test proves the missing-receipt pass creates no outbox entry or second upload. Combined qualification: **936 tests passed across 28 suites**, including fixed-inventory interruption/reopen and historical upgrades; full Dart CI passed below. Live runtime remains unqualified. |
| Full-suite checkpoint | Source `0ff8e5595`, GCE `34555255259`: **3,016 Dart tests, 14 semantic-outbox contract cases and 3 evidence-output cases passed**. The three previous fixture/constructor-contract failures were repaired and rechecked. Cleanup completed at 02:47:11Z on September 11; independent VM/runner inventories were empty. No APK, native compilation, signing or live account access occurred in this dart-only run. |
| Windows baseline | Historical source `0ff8e5595`, Windows run `34555641336`: 30 focused Dart tests, 51 actual Rust-DLL codec tests, ARM64 load and invalid-launch marker passed. Parent verified 78 bundle files. This baseline predates the attachment-request and durable-source-lookup repairs; it is retained rollback evidence, not the active runtime. |
| Durable source lookup | Review found that `validateReadyForCreate` reloads a Message with an empty transient `attachments` list. The executor now selects its exact persisted `dbAttachments` relation instead, retaining exactly-one original/reflected GUID matching. Eight database-reopen regressions cover both aliases, ambiguity, unrelated rows and forbidden transient/global fallback. Exact source `3ebcc81c9` passed 3,042 Dart tests plus 14 outbox and 3 evidence-output cases in GCE `34557585998`; cleanup and independent empty VM/runner inventories verified. Live attachment proof remains open. |
| Windows attachment input | Explicit request v4 adds synthetic `text-v1` and `png-v1` files only, no arbitrary user-file upload. Claim, original descriptor, protected source staging, positive IDS confirmation and the existing exact-intent production adapter remain required. Previous request-v1/v2/v3 bindings are unchanged. Interrupted IDS confirmation stays unconfirmed, not resendable. |
| Live attachment failure | Native `62221f9` passed preparation and byte upload on September 11. Read-only inspection after the 06:11:34Z failure found one exact IDS-confirmed message, one adopted upload and one matching pending Attachment create with attempt count zero. The `invalid_checkpoint` failure is before record save, not a rejected login or failed IDS send. Request and claim remain unchanged. |
| Diagnostic repair | `1d9de8629` preserves fixed native failures through FRB. Native fix `62221f9` passed 493 app Rust tests in GCE `34567150925`, 276 dependency tests on test-only successor `c206428a3`, and Windows run `34567152272`. All GCE cleanup succeeded; independent VM/runner inventories were empty. |
| Upload recovery roots | `readLiveProtectedOutboundLeaseReferences` included upload leases, but `readLiveProtectedReferences` omitted plan/result bytes. Five ObjectBox reopen cases failed before the 13-line repair `db27373d9`; 184 related tests passed afterward. Qualified overlay `17818cd3d` moved the exact retained child from pending to confirmed without the previous `invalid_checkpoint`. The remaining parent-admission receipt failure was repaired below; do not clear or regenerate the retained source. |
| Released result receipt | App `436c61bbb`: the upload result lease is also the final-save receipt. Verified child readback clears the outbox adoption marker and acknowledges that native receipt. Recovery incorrectly demanded it again from the immutable upload row. Recovery now reuses the exact child-readback predicate before excluding only that retired receipt; original plan, payload/result references and upload history remain live. The restart regression failed before repair; 276 targeted tests passed afterward, including 20 incomplete/mismatched proof cases. Overlay `46bc6f027` passed real parent admission and a separate-process no-op restart. Missing or mismatched receipts still fail closed. |

Protected bytes and receipt-adoption markers are different liveness sets.
Readback releases the shared result receipt, not the encrypted result payload.
Do not delete upload history, suppress all missing leases, or infer release from
a generic terminal state. See the current investigation log for exact traces.

Prepared-handle lifecycle correction: a failed native consume can retain its
unconsumed owner and writer permit. Waiting for futures alone cannot release
that permit. Native `590cf25bb` adds idempotent owner release without changing
files, fences or protected leases. GCE `34548927310` passed **493 Rust tests**;
only generated bridge drift failed. Artifact `10180257648` was hash-verified
and imported; VM and runner inventories were empty after cleanup. Dart
engine/transport cleanup passed the 125-test release/admission/adapter cohort,
including 20 focused release cases for late preparation, both heartbeat losses,
returned failure, thrown failure and consumed success. Release does not cancel
an owner already taken by consume. The combined 868-test checkpoint passed;
the full-suite result above and live attachment write/recovery remain release gates.

An ambiguous MMCS upload still cannot be blindly replayed. Original CloudKit
UUIDs do not prove MMCS request idempotency, and chunk deduplication is not
asset-completion recovery. Retain unknown attempts. Durable native completed
receipts recover lost Dart responses, not network outcomes without a receipt.

Detailed prior source SHAs, bridge artifacts, test counts and failed-run evidence
are retained in the [current investigation log](cloud_sync_v2/history/CLOUD_SYNC_V2_INVESTIGATION_LOG_FROM_2026-09-07.md).
GCE cleanup for `34544585837` succeeded; independent inventories showed no
instances or runner registrations. Apple credentials and stores remain local.

The first September 10 attempt failed on retained IDS credentials before send.
Explicit request-bound sender authentication from the same retained GSA session
then succeeded on `6abbeede2`. It did not reset onboarding or clear CloudKit
state. `setup_push` rewrites saved APS connection material, so the full hardware
file hash is not a hardware-identity comparison. The OS-config fingerprint and
immutable request claim stayed unchanged across the subsequent restart.

Retained Windows exact-source qualification: app `6abbeede2`, rustpush `f33dcac`, pilot
`a2680baac`. GCE app Rust `34497413348` passed 380 tests and rustpush
`34497413071` passed 261. Both cleanup jobs passed; independent inventories
showed zero VMs and zero runner registrations. Neither run built an APK or
accessed Apple credentials. Windows `34497409120` attempt 2 passed in 24m17s
(Flutter compile 945.8s), following one package-download failure before compile.
All 78 bundle files were verified before extraction. Local signing preserved
the vendor ObjectBox DLL, native load/unload passed, and the invalid-launch
marker was observed with zero dummy-profile files. No PC policy was changed.

Offline inspection of the retained September 7 test on a disposable database
copy confirmed one canonical legible message with a valid source binding, but
IDS proof remains version 0 and the exact-readback marker is absent. The
retained confirmed outbox row alone is not full write proof. Source database,
request and claim stayed unchanged; the temporary database copy was removed.
The new September 10 request independently passed all these checks with IDS
version 2, valid source binding, legible text, exact-readback marker and released
receipt. Restart kept those proofs and one canonical message with zero new
admissions. This closes that bounded Windows gate, not full production parity.

Keep native compilation isolated: the local signed `slab` build script remains
blocked by App Control error 4551. No security policy was changed. Targeted
Dart tests work with the matching ObjectBox library on PATH. The approved
cloud budget is $200 through September 15; Apple credentials and message stores
remain local. [Build runbook](WINDOWS_HOST_BUILD_ENVIRONMENT.md) contains setup
and import boundaries; the investigation log retains failed-run evidence.

Historical installed Canary came from full signed GCE run `34444190598`, app source
`3dc614c9eced02b49f130a2752ce531d9e6aec7a` (code `e060bcb41`): build,
GitHub-hosted signing, and cleanup jobs all succeeded. The signature-verified
APK was installed in place on Canary at 2026-09-09 23:43:18 Pacific; Alpha's
package snapshot and Canary's UID/data directory/first-install time were
preserved. Host preflight verifies artifact identity, not the running Dart
build: that earlier observation left `sourceCommitDeviceVerified` false. The
current signed `f860966d5` installation and runtime proof supersede this baseline.

Earlier live observation, 2026-09-10 05:43-05:50 Pacific: two user-triggered
plaintext sends received native confirmations which were journaled. The test
conversation rendered the edited message and the subsequent unsend notice.
This qualifies that local live-send/UI boundary only. No exact CloudKit
save/readback, restart, or independent-device edit/unsend proof was obtained.
The conversation-list preview still displayed the retracted message's text,
an observed stale-preview defect now repaired locally: previews honor retracted
parts without deleting retained text; normal and pinned tiles recompute on
same-record updates even when dateEdited is unchanged. The five-suite cohort
passes 48 tests, including real mounted widgets/ObjectBox updates and preserved
history. Reinstating the old same-ID gate makes that widget test fail. Full
cloud qualification and installation of this preview patch remain pending.
A semantic pull remained active during the original observation and was not
restarted. See the current investigation log for timestamps and private
evidence paths. Causal edit/unsend writes remain a gap, not a passed gate.

### What the candidate includes

- Native and Dart compute the same deterministic group-routing digest from the
  canonical group, current raw group ID, service/style, group version, and
  normalized participants.
- Both sides use UTF-8 byte ordering. Exact `urn:biz:<UUID>` participants are
  retained; arbitrary schemes remain rejected.
- Older applied groups can receive a missing digest only through protected
  null-to-non-null projection repair with an otherwise exact snapshot match.
- Restored, nonprovisional group plaintext uses opaque dependency binding tag
  3. It binds generation, owner, aliases, server record, ETag/raw reference,
  latest applied save, and routing digest.
- Direct tag-1 and reaction tag-2 encoders and bindings remain unchanged.
- Provisional group creation, group reactions, group-state mutations, remote
  deletion, and update merge remain closed.
- Exact out-of-scope chat satellites and retained tombstones no longer make a
  valid physical-retention result fail the whole Chats zone.
- Retained message and attachment blockers are counted separately from the
  larger physical backlog. The current live blocker is therefore 3,586 saves,
  not all 10,108 retained rows.
- Content-free Windows inspection proved all 189 native `msgProto` field-2
  wire mismatches are classes 4-7, whose Apple schemas use int64 rather than
  the ordinary message string. The same inspection found five class-3 system
  events. The decoder base `12035ec0c` validates all five variant schemas and retains
  them as `UnsupportedMessageType`; it does not invent projection semantics.
- Existing-history write deferrals report fixed counts for local-chat, snapshot,
  alias, prior-origin, record-map, and tombstone conflicts. The classifier is
  observational only and does not authorize adoption or alter failure precedence.
- Canary ADB control is package-scoped, challenge-confirmed, and read-only by
  default. Host parsing accounts for Android SharedPreferences key prefixes and
  harmless Windows PowerShell native-stderr promotion.
- Receipt discovery keeps only a bounded candidate window in memory and reads at
  most 64 receipts per replay page. Its cursor advances past invalid receipts,
  while leaving later valid receipts discoverable on subsequent pages.
- Startup receipt replay completes before stale-send normalization. The
  ObjectBox startup claim then retains native-confirmation work and clears only
  sends that are proven untracked in the same transaction.
- Canary can register one exact, content-free semantic-scope hash with Android
  WorkManager. Foreground, headless APNs, and network hints coalesce into a
  metadata-only read. The native waiter is bounded to five attempts and eight
  minutes; Flutter-engine readiness is cancellable and bounded to one minute.
  The repaired Dart drain requests cooperative cancellation after five minutes
  and awaits protected quiescence. A native timeout does not prove Dart stopped.
  Engine leases survive waiter cancellation until Dart replies; delayed teardown
  rechecks exact engine identity, active calls, and the idle generation on Main.
  Alpha, Beta, production, media-prefetch, and every outbound lane remain closed.


## Scope and current evidence

| Capability | Status | Remaining proof or work |
| --- | --- | --- |
| Chat and message history | `LIVE-PROVEN` for restored readable history | Qualify sustained incremental sync, restart, and account lifecycle on the release candidate. |
| Reactions on read | `LIVE-PROVEN` for representative records | Continue retaining unavailable parents; qualify current candidate on Pixel. |
| Photos and videos on read | `SOURCE-IMPLEMENTED` after prior live proof | Current source resolves generic and UTI-only image/video records consistently across profile and message surfaces. Pixel must prove HEIC, video, and tap-to-open behavior; GIF data remains preserved but profile animation is not a release requirement. |
| Documents and plugin payloads | `TEST-PROVEN` | Supported documents remain visible, unknown opaque files remain available, and only the exact `.pluginPayloadAttachment` suffix is hidden from profile media/documents without deleting its row. Pixel UI proof remains. |
| Direct plaintext create | `LIVE-PROVEN` for bounded Windows request `qualification-20260910-03` | Positive IDS version 2, exact-readback marker, one canonical legible message and restart with zero new admissions passed. Independent Apple-device display and ordinary Pixel composer convergence remain open. |
| Restored-group plaintext create | `SOURCE-IMPLEMENTED` and exact-source qualified | Perform one authorized live group test with pinned route/binding plus exact readback/restart proof. Provisional group creation remains closed. |
| Write-send provenance | `SOURCE-IMPLEMENTED` | Native positive-acceptance tests pass. Qualify the additive persisted-proof upgrade and dispatch/reconciliation tests. Old deferred/ready intents cannot promote or enter fresh admission without new proof; old adopted pending entries are retained and skipped for new leases. Submission rechecks proof. Exact readback remains allowed and does not retroactively prove IDS acceptance. A fresh v2 native confirmation can requalify the exact unchanged old source without resending it. Automatic uploads remain off pending execution and live proof. |
| Retained writer queue usability | `TEST-PROVEN` | One journal-bound, read-only classifier covers queue drain, queued Chat observation, and preflight. It exempts only pristine pending creates with proof version 0, exact protected envelope/mapping, current owner/generation, no lease, attempt, Apple UUID or receipt. All rows remain counted and fingerprinted; no upload, acknowledgement, deletion, or proof upgrade occurs. GCE passed the real consumer/admission/store regression with a fresh qualified send beside retained work and reopen without duplicate submission. Apple responses are synthetic in this test; live proof remains. Unknown/retried/leased/malformed rows still block. |
| Direct reactions | `LIVE-PROVEN` for bounded Windows like-05/remove-like-06 | Positive IDS confirmation, one admission, exact persisted readback and separate-process zero-admission restarts passed. Ordinary Pixel composition and independent Apple-device display remain. |
| Edits and unsends | Read transition `TEST-PROVEN`; bounded Windows writes `LIVE-PROVEN`; Pixel gate open | Same-record, rotated-tag transitions require exact durable predecessor binding and real canonical identity plus complete compatible body/history proof. Windows request 21 recovered an unknown edit without another IDS send and reached exact CloudKit confirmation. Fresh-parent request 24 submitted one unsend update and reached one exact confirmation, with zero not-applied, diverged, or unresolved operations. The offline mutation inspector found terminal state 5, positive IDS and reflection markers, exact route/source binding, matching stored display, zero initial-send intents, and an unchanged source database. Unsupported multi-body encodings, ambiguous lineage, chained mutation qualification, ordinary Pixel composition, and independent counterpart display remain open. |
| Attachment writes | `LIVE-PROVEN` for bounded Windows image 04 admission/readback recovery | Source-bound upload, child readback, parent admission and no-op restart passed overlay `46bc6f027`. Independent recipient/second-client rendering, ordinary Pixel composer convergence, group attachment proof and exact-source Android qualification remain. Upload receipt alone is not record-save proof. |
| Tombstones and deletion | Closed | Define exact ownership and recoverable semantics before enabling any local or remote delete. |
| Token expiry | `TEST-PROVEN` | Live expired-token/restart proof remains. The exact-source path requires an authenticated protected reset proof, releases the semantic read boundary, reacquires the destructive-reset interlock and native pause, advances once, reconciles authority after process death, and replays once. |
| Android background catch-up | `IN REPAIR` | The ready-handshake/lifecycle repair is qualified in installed `f860966d5`. Live evidence then exposed a no-progress exhaustive projection sweep. The next patch keeps routine metadata bounded, avoids retrying solely for retained projection debt, and preserves deep repair, scope/reset/cancellation gates and truthful partial reports. 129 focused tests pass; combined exact-source qualification and Pixel lifecycle proof remain. |
| SMS, MMS, and RCS | Out of scope | Do not add them to this CloudKit V2 release path. |


## Release gates

### Candidate qualification

- [x] Reset-proof base `7df608af7` passed the full exact-source suite and
  signed-APK path in GCE run `34407071539`, with automatic uploads off.
- [x] Current app code `0b86a6465` reproduced bindings and passed 2,522 Dart,
  359 app Rust, 226 rustpush, 34 protector, and 14 semantic-outbox contract
  tests in run `34414062044`.
- [x] The `0b86a6465` Canary contains every required ARM64 native library and
  is signed on the existing trusted GitHub-hosted signing path.
- [x] Run `34414062044` deleted its VM and deregistered its runner; independent
  inventories confirmed zero remaining runners and zero GCE instances.
- [x] Exact source `fc132e5f8` reproduced 2,542 Dart, 359 app Rust, 226
  rustpush, 34 protector, 14 semantic-outbox, and 3 evidence-output cases in
  run `34423632222`; bindings reproduced and the signed ARM64 Canary contains
  every required native library. Runner and VM inventories both returned zero.

### Read qualification

- [x] Representative chats and readable messages project on Canary.
- [x] Representative reactions and media metadata project without deleting
  unavailable evidence.
- [ ] A cold-start candidate executes authentication, pause, three-zone warm,
  fetch, decode, journal, projection, and token promotion in one process.
  Windows `f90226831` completed this path after repair `b432b9e8a`; the
  corresponding Android release candidate remains unqualified.
- [ ] A second pull is idempotent and reports fetched, retained, and projected
  counts separately.
  Windows fresh-process repeat passed with fetched=0, applied=0, retained=6654
  and settled outbox unchanged; retain the Pixel gate separately.
- [ ] Restart, background/lock, account replacement, and expired-token paths
  preserve evidence and fail closed.

### Write qualification

- [x] Source `6abbeede2` direct plaintext request `qualification-20260910-03`
  has positive IDS version-2 confirmation, a persisted exact-readback marker,
  one canonical legible message, and restart with zero new admissions. The
  earlier pre-repair failure and September 7 weaker proof remain historical
  counterexamples, not substitutes for this fresh observation.
- [x] Host-controlled Pixel prepare/run/verify tooling exercises the existing
  exact-intent production path across fresh Canary processes, rejects candidate
  drift, redacts arbitrary failures, and requires automatic uploads off. Live
  execution against Apple remains below.
- [ ] Confirmed direct replay proves zero saves and independent Apple-device
  display for the release candidate.
- [ ] Restored-group plaintext passes exact-source tests, one authorized live
  group create, exact readback, restart, and independent display.
- [ ] Direct reactions pass live save/readback/restart and independent display.
- [ ] Ordinary composer queue admission atomically commits the first durable
  outgoing Message and state-0 local-send intent. Native IDS success is durably
  recorded before `SendConfirm`; restart recovery promotes it to state 3 and
  acknowledges that receipt only after the ObjectBox commit. Protected staging
  then atomically adopts the intent into the outbox and converges automatically.
- [ ] Attachment write, edits, unsends, and supported tombstone semantics each
  receive an implemented and verified causal/recovery path before full release.

### Production qualification

- [ ] One signed Canary survives foreground/background, lock, reconnect,
  process restart, and account repair without duplicate sends or lost tokens.
- [ ] Current retained backlog is zero or every retained category has an
  explicit non-destructive repair or honest unavailable state.
- [ ] User-visible status distinguishes remote ingestion, projection, media
  materialization, live delivery, and write reconciliation.
- [ ] Scope documentation names supported operations precisely. Initial text
  creation must not be advertised as complete Messages parity.


## Current critical path

Checkpoint `58236f330` passed the complete local CloudSync suite: 2,859 tests,
one intentional skip and zero failures. Signed-Canary run `34714333139`
produced the correct package, stable v2 signature and ARM64 Rust/ObjectBox
libraries. Exact-source GCE run `34714796195` passed binding regeneration, the
full Dart suite, both Rust suites, the protector harness, APK packaging and
native-library verification. Its final Android JVM step exposed three
`FileNotFoundException` failures in the unrelated FaceTime layout test because
that test assumed the repository root while Gradle runs from `android/`. The
test now resolves app source from repository, Android-project or app-module
working directories. Requalify the resulting test-only head before installing;
do not treat this harness-path failure as a CloudKit protocol regression.
Retry `34716439200` proved the path repair: all 119 Android JVM tests passed,
along with full Dart, both Rust suites, the protector harness, APK packaging
and native-library verification. Its only failure was the delayed bridge-drift
gate. Review of the uploaded generator artifact found exactly two nonfunctional
normalization differences: four FRB diagnostic comments in generated Dart and
six generated Rust separator blank lines. The exact reviewed generator outputs
are now imported. A binding-reproducibility run must prove zero drift on the
resulting head before installation.

1. Ship the confirmed-create raw-readback repair to Canary, then resume edit
   request 23 without another IDS send. Exact readback must populate the raw
   predecessor map first; the conditional edit may then reconcile and finalize
   both protected leases across restart. A same-client local reflection is not
   sufficient evidence.
2. Qualify the combined attachment and cold-start-auth source on Android and
   independently verify the written attachment through a second client.
   Windows overlay `46bc6f027` completed exact image 04 parent admission and a
   separate-process restart with no new admission or blocked work; read-only
   `f90226831` completed two cold reads without a reset. Do not demand that the
   writer's incremental cursor self-echo its record, or weaken the offline
   inspector to manufacture proof. Preserve the original source and attempt across writer
   epochs; absent receipts never authorize blind reupload. Also prove source
   staging remains usable during long reads, not merely lossless on contention.
3. Preserve qualified Windows direct request `qualification-20260910-03` and
   its proof. No additional direct send is needed merely to recheck that result.
   The exact restored-group route is implemented/tested, but no group with the
   approved two test recipients exists in the retained Windows profile. Restore
   or create that approved conversation before live group qualification. Never
   substitute another personal group.
4. Windows direct reaction add/remove and no-op restarts now pass. Continue
   attachment/causal-write qualification, preserving exact readback, recovery and
   independent Apple-device display as separate gates. Implement group creation,
   group reactions and supported edits/unsends, not just restored plaintext.
5. Qualify lifecycle P0 before automatic sync: expired-token reset must advance
   exactly once and replay once; a second reset signal must stop. Process death
   must recover prepared or unknown authority without losing old evidence.
   Same-generation authentication may refresh once; account replacement must
   preserve evidence and fail closed.
6. The durable Android metadata entrypoint is under lifecycle repair after a
   concrete ready-handshake counterexample. Requalify it and prove background, lock,
   APNs, reconnect, process restart, bounded retry, and stale-identity behavior
   on Pixel before considering production enablement.
7. Run lifecycle soak and produce one release-candidate report that proves
   identity stability, token continuity, zero duplicate writes, and honest
   retained counts. Complete attachment writes, reactions, edits/unsends, and
   supported group/deletion semantics for the full production goal. Keep each
   unqualified operation disabled during development, not excluded from completion.

## Next falsification test

Image 04 is already claimed and IDS-confirmed. Windows parent admission and
separate-process write restart pass. App `b432b9e8a` fixes a real cold-read
failure: reset recovery captured native identity before read authentication
had restored its identifiers. Authentication now runs under the semantic-read
interlock, which releases before reset recovery takes its own lock. The exact
identity/reset predicates remain intact. All 126 targeted tests passed and
read-only overlay `f90226831` completed two separate-process reads.

Those reads preserve 6,654 old retained entries, including out-of-scope services,
with no new Message ingestion for image 04. This is not a new send failure.
The next useful proof is independent client visibility, not repeated empty
self-reads or another inspector implementation. Disposable-copy inspection
still honestly cannot certify v4 source/readback without its child-proof
callback. Do not send another image, weaken child readback, clear credentials,
reset cursors, or use the older `5e9a532be` APK as containing the cold fix.

The isolated Windows direct test and restart passed; do not repeat the claimed
request. Source inventory, canonical read/write identity and parent UTF-16 body
passed GCE `34541849568`; executor adversarial tests and the real persistent
guard passed locally. Windows attachment admission and restart are evidence
for overlay `46bc6f027`, not Android proof. Combined Android source `f860966d5`
is now signed and installed; its batched device session is in progress. Independent
Apple-device display remains separate; component tests cannot replace it.
When the approved group is present, falsify exact selection, acceptance by every
intended target, group encoding, readback and restart without resending. Preserve
the direct claim. The inspector must distinguish readable text, positive IDS
confirmation and exact-readback proof.
Then qualify the ready/lease/budget repair with Android behavioral tests and
an exact-source signed APK. Do not install `fc132e5f8` as background-qualified.
Use one batched Pixel session: cold read, idempotent
second read, background/lock/APNs/reconnect, expired-token/restart recovery, and
the authorized direct process-death write test. The write must recover state 3,
adopt exactly one
protected outbox operation, obtain exact CloudKit readback and independent
Apple-device display, and create zero duplicate local or remote records.
Automatic uploads remain disabled during this proof.
Existing-history adoption remains a separate write gate; diagnostic counts
cannot authorize or perform adoption.

## September 13: real own-edit recovery and restart proof

- Reviewed source `6f778c99eda74f0c1e98eeca205c85afefba6054` fixes old writer
  floating-point loss of one edit millisecond, conservatively matches the exact
  old own-writer mapping, and adds a fenced one-attempt recovery of an uncommitted
  quarantine. Original source, failure evidence and immutable replay checks stay
  intact; only normal application may commit canonical state or advance cursors.
- Real copied-database testing rejected two invalid assumptions: a write-readback
  envelope is not the identical change-feed envelope, and an empty own sender
  does not imply every previous local producer stored handle ID zero. Final
  recovery uses freshly native-validated fetched content and finalized local
  operation/map provenance, not mapped raw content or a fabricated receipt.
- Copy proof passed through production recovery and normal applier, preserving
  history. Before live use, a separate rollback database was retained under the
  Windows profile mutex. Live report `obcs2-semantic-1789278811033254.json`
  applied two pending messages. Fresh-process report `1789278895014946` fetched
  and applied zero. Both reached empty terminal reads in all zones, had no
  quarantined conflict and preserved outbox 15 -> 15 with remote writes disabled.
- Local qualification: parent 343 focused Dart tests, then agent 167 focused
  recovery/canonical tests after copy-driven corrections. Current targeted
  analysis has no errors/warnings and two existing harness style infos. Two
  extracted native helper tests pass; full native crate remains a cloud gate.
- Retained totals remain 6,654. Ordinary retry selection rotates durably by
  attempt timestamp and sequence; differing diagnostic mixes across these runs
  do not establish first-window starvation. Exhaustive sequence sweeps separately
  restart from zero after process death, an explicit scheduling limitation, not
  proof that ordinary retries cannot reach later records. Telephony exclusions
  are not missing iMessage counts.
- Full qualification dispatched as GCE 34741584069 (T2D60, writer/automatic
  Canary). Never describe the retained Windows DLL as executing the new native
  writer arithmetic. Pixel ADB inventory is empty; no install or device reset.
- FaceTime test matcher correction was reviewed and its four tests rerun by
  parent. Missing native traces prevent a call-success claim. Its worker and
  the recovery worker were closed and verified absent after integration/review.
  Transcript deletion is unsupported by the available controls; shared build
  outputs, protected profiles, evidence and uncommitted work were preserved.
  Find My host implementation remains active in a disjoint write set.

### Retained sample and native-only Windows qualification

- `retained-sample-20260913.json` in the same private evidence directory contains
  37 bounded observations (first eight by sequence/category in each current
  semantic generation). No fetch, projection, row rewrite, cursor movement or
  outbound operation occurred. Categories are selection strata, not prevalence.
- Message dependency sample: one now classified as excluded SMS, seven unsupported
  extension payloads. Malformed sample: six required-identity failures, one parent
  failure, one ambiguous reply. Five unsupported-service rows remain unsupported.
- All eight Attachment dependency samples decode but their declared Message parent
  is absent locally; six are materializable and two have unsupported media
  credentials. Eight malformed samples remain native malformed-record failures.
  Missing parents could include excluded or unavailable records; do not fabricate
  routing or claim these are all repairable iMessage attachments.
- Added content-free native diagnostic classification, not a decoder fallback:
  fixed nine-bit absent/without-value masks (msgType, eCode, chatID, sender, time,
  msgProto, flags, guid, svc), empty-identity booleans, fixed provider category and
  typed failure outcome. Values/identifiers/bodies never enter the diagnostic.
  Two native tests accompany it; Rustfmt parses it, native execution is pending.
- Isolated pilot `96a2c33e26690aa98808df71e65283898f3200b7` adds a native-test-host
  mode to the existing Windows ARM64 cloud lane. It builds/tests the new Rust DLL
  and a distinct test executable, omitting GUI/media compilation. Parent reviewed
  the patch and reran actionlint/PowerShell parsing. No main-branch CI migration,
  secrets, infrastructure or local trust changes. Existing approved signer/private
  key is available, but acceptance of newly signed bytes remains an import gate.

### Native qualification, live Find My, and logger lifetime repair

- GCE 34741584069 completed all selected checks, signed the Canary and removed
  its VM/registration. Independent inventories were empty. Signed artifact ID
  10312788076 remains in GitHub; no Pixel install occurred because ADB is absent.
- Windows native run 34742235201 passed 7 compose, 2 diagnostic and 51 packaged-DLL
  codec cases. Parent verified archive/binary/test-log hashes and source inputs
  (nine differed only by cloud CRLF checkout versus local LF), signed a separate
  copy with the existing certificate, and reran all 51 codec cases under enabled
  App Control. The actual loaded module path was inspected. Old runtime untouched.
- Two live Find My passes completed with unchanged retained-state checks and
  confirmed child cleanup. User confirms the sole followed person still shares.
  Roster and selected-detail requests both returned that person without coordinates;
  FMIP returned zero devices. Items remain untested. No permission/consent inference.
  The launcher needed exact SDK dartvm/dartaotruntime ancestry tracking; the failed
  first attempt never admitted native requests. A stale selected-result reason was
  separately reproduced and repaired. Parent rerun: 37 Dart and 11 Python tests pass.
- The gate audit found FIFO RwLock acquisition, not a lost Notify wakeup. An active
  pause can block Items, but V2 ownership is not a permanent prohibition. No speculative
  gate patch was made. Find My history was preserved verbatim; the current guide is short.
- Newly compiled retained diagnostics remained absent. The pinned flexi_logger
  0.28.5 contract and actual reproduction established that dropping the returned
  LoggerHandle shuts down writers. The app discarded it immediately. A two-case
  witness reproduced shutdown before first write; five tests of exact extracted
  repaired logger code passed, including real file output, debug output with console
  disabled, idempotence and secret suppression. Full rebuilt-DLL proof remains open.
- Repair retains LoggerHandle, parses console filters, and preserves secret filtering
  on desktop as well as Android. Find My test mode logs only its value-free diagnostic
  module; general native logs remain off in that mode. No parser admission was loosened.
  Native-only pilot f110e2562 now requires logger/restricted-mode tests and compiles
  the existing bounded Find My diagnostic switch. No new app/GUI build is required
  for the next Windows protocol inspection.

### September 13 live write and actionable retained categories

- Parent-25 initially failed recipient lookup with bad sender authentication before
  claim/send. Explicit retained-identity registration refresh succeeded; one text
  was accepted and exactly saved/read back. Edit-26 reused the refreshed registration
  in a fresh process, received its native receipt and exact CloudKit update confirmation.
- Claim-bound native echo comparison verified the expected edited text and both
  history timestamps to the millisecond. Completed-edit replay performed no new
  submission, and a later read applied zero records with the same exact comparison.
  This does not prove independent Apple UI display or mid-flight crash recovery.
- Logger-fixed native b2797dd07 was cloud-qualified, signed separately and passed
  all 51 local codec cases. Real diagnostics now appear. Six sampled identity
  failures were classes 3/4 with missing normal flags/error fields; seven sampled
  Apple extension failures had base text and attributed content. No decryption
  shortcut or raw-payload discard was used. Evidence is in windows-write-20260913.
- System-event common-envelope classification is corrected in pending source;
  classes 3/4 are GroupTitleChange/LocationShareStatusChange, not normal MessageProto.
  This is unsupported-event classification only, not current sharing authority.
- Find My selected probe on b279 again found the sole entry without location and
  preserved profile state. Its value-free logger uses explicit target
  `findmy_diagnostic`, not its module path. The restricted filter was corrected
  and its test now checks actual target admission and unrelated-target rejection.
  That fix awaits the next native batch; do not infer raw response shape yet.
- Native extension work is reusing bounded plist streaming with exact 1.7.0 pin
  and reviewed feature enabling, plus keyed-archive UID checks. Immutable Dart
  prepared metadata passed 25 parent-run tests. API/DTO/projector integration is
  still pending; no base-only fallback is being called complete restoration.

### September 13 extension integration and lower-cost delegation

- User requested Muse Contributor for delegated work. The interrupted Astra
  worker was closed and its partial Dart changes retained for Muse review.
- Native extension metadata now connects to canonical conversion and the API
  source. The canonical constructor validates the generated metadata schema,
  parent bundle and reaction exclusion. Repair digests include exact JSON UTF-8.
- Local FRB generation attempted Cargo expansion and stopped on missing clang;
  no bindings were generated. Use the existing cloud bridge workflow, then
  qualify a matching Windows DLL before exercising this ABI on the live profile.
- The user reconfirmed exactly one person shares location, their spouse. Current
  evidence remains one matching entry without coordinates; this is not evidence
  of stopped sharing. Find My guide now records the latest native repeat.

### September 13 coherent extension candidate qualification

- Cloud run 34761004976 regenerated seven bridge files and compiled the native
  library. Rust test compilation failed E0283 in the new synthetic dictionary
  fixture. Parent made dictionary key types explicit; native tests await rerun.
- Imported generated files together from artifact 10318519609. Both FRB guards
  passed. Added a shared Unicode/icon metadata digest vector with LF-pinned input;
  Dart passes the fixed corpus and native consumes the same fixture/expectation.
- Parent refined Muse's older-snapshot guard to preserve the provider together
  with its newer renderer data. Four new adapter tests lacked route/ownership
  fixtures; existing setup helpers fixed the tests without weakening production.
- 169 prepared/core/adapter, 45 decoder and 75 existing harness/write/precision/
  digest tests pass across focused local runs. Initial database tests lacked the
  vendor DLL in PATH; corrected-path reruns passed. No account was opened by
  these unit tests. The signed old Rust DLL was not initialized against new ABI.
- Pilot 02fc8e810 qualifies the actual native extension/converter/DTO/digest/
  system-event scopes and Dart projector/decoder using one shared compile.
  Both Muse workers are closed; no session/worktree/evidence deletion performed.

### September 13 live qualification and session-association boundary

- Windows 34762729315 passed in 23m21s. Source 3496034e3 and pilot 02fc8e810:
  141 selected native tests, 51 packaged-library codec tests; local signed copy
  passed another 51 codec cases under App Control. Artifact provenance is in
  `artifacts/windows-native-34762729315/local-qualification.json` privately.
- A 37-record non-projecting inspection preserved durable state. The seven
  sampled extension failures now expose five sticker-deferred and two unknown
  association failures; none of those seven is proved restored. The earlier
  blanket extension check had hidden these later conditions.
- Parent and Muse traced native type 2 to extension-session updates, type 4000
  to meta updates and type 1000 to no-balloon extensions. Type 2 must preserve
  amk session/base inheritance. No promotion or diagnostic-only rebuild was
  accepted. The agent's design findings were reviewed and the agent closed.
- Normal run report obcs2-semantic-1789312307027272.json applied four retained
  message records, fetched zero, reached empty terminal reads in all streams
  and kept outbox 17 -> 17. Total retained is 6650. No claim that all four are
  distinct newly restored messages or that the new metadata parser caused them.
- Find My host must await native initialization. After fixing it, launch
  2ca02f9e0f1f41f7bb4e299eff227386 recorded real FMF init/refresh responses with
  absent locations fields, one following entry and no coordinate join. Profile
  invariants/cleanup passed. No sharing settings or Items initialization changed.
- Nested rustpush has pre-existing formatting edits. Relevant Find My diagnostic
  and extension live-path differences reviewed here were formatting-only; retain
  all uncommitted submodule work and compare the pinned commit when qualifying.

### September 13 session-aware candidate

- Implemented closed v2 metadata context inside the existing string bridge. It
  carries the wire session identity separately from the archive's balloon UUID.
  Native conversion creates a semantic base dependency for validated type 2;
  type 4000 and 1000 remain retained. No ObjectBox entity or generated ABI change.
- Projector resolves base and chronological predecessor with exact durable scope
  ownership, same chat/provider and timestamp bounds; inherits attributed references
  without moving attachment ownership. Grouping uses existing amkSessionId.
- Muse contributed parser/tests, adapter fixtures and lazy message-cache invalidation.
  Parent reviewed/refined lifecycle, tested actual callbacks and fixed an async test
  expectation that inspected an old cache before its change notification arrived.
- 247 broader transaction/decoder tests passed, plus 31 parser, 149 adapter, nine
  targeted session, eight cache tests and the expanded fixed digest corpus.
- Remaining: native qualification/live decode and convergence when an earlier
  asset update arrives after a newer inherited row. The tested chronological
  behavior is not declared complete. No new Pixel installation or remote write.

### September 13 derived-session convergence

- Native run 34766997568 compiled the library/test executable and passed the Dart
  suite, 24 extension tests and 77 converter tests. The remaining failure was a
  source contract requiring the converter's single fixed logging site. Parent
  moved the new fixed-enum debug diagnostic into the bounded extension decoder
  helper and retained the original private-converter restriction.
- Added atomic downstream repair for late assets. Only scoped, durably owned
  inherited rows with unchanged derived-content digests can be updated. Paging
  bounds memory; a new own-media row stops propagation. Raw cloud records and
  attachment owners are untouched.
- Four focused tests passed: late arrival without manual replay, stopping at own
  media, preserving independent local changes, and 260 descendants with full
  rollback when a conflict occurs beyond the first page. A generic Map key type
  initially failed ObjectBox serialization; explicit string-keyed maps fixed it.
- Muse test worker drifted into unrelated reads and was closed without changes;
  parent wrote and verified the regression tests. No live account test used the
  unqualified session candidate.

### September 13 qualification resume and handoff hygiene

- Rechecked run 34768626100: exact source validation passed for 16112ec69;
  native build/test packaging was still active. No replacement run launched.
  Current local Rust/lib/test sources compare unchanged against that source.
- Muse's bounded Find My async review found awaited roster/selection/native
  refresh calls. Parent verified the call sites and accepted no code change.
  It does not resolve absent coordinates or establish stopped sharing.
- Reviewed the older precision/retry audit and Find My host agent's final
  work. Precision agent is no longer present; completed Find My host and new
  review agents were closed. Integrated source and required findings remain;
  no transcripts, evidence, worktrees or user data were deleted. Supported
  session deletion was unavailable.
- Added a thread-scoped AGENTS.md rule requiring document reconciliation and
  active-job/agent handoff before planned compaction, or immediately afterward
  if automatic compaction interrupted it. Removed superseded native-candidate
  rows from the current board; their qualification history remains above.

### September 13 session qualification and real retained replay

- Run 34768626100 passed in 22m50s: source 16112ec69, pilot 2343e13f9,
  143 selected native tests, 519 focused Dart tests and 51 packaged-library
  codec tests. Parent verified archive/39 source inputs/12 logs/three ARM64
  binaries, signed only a staged Rust DLL, and reran all 51 codec cases with
  App Control enabled. Original runtime and vendor ObjectBox were preserved.
- The actual new DLL was observed in the live test process. Non-projecting
  inspection passed with unchanged durable state, 37 cases. Five type-2 cases
  now reach the extension decoder but fail `Malformed`; two previously unknown
  associations are type 3. None of the sampled seven is proved restored.
- Normal read report obcs2-semantic-1789318496467790.json applied two retained
  Message records, fetched zero, observed empty terminal reads in all streams,
  and kept outbox 17 -> 17 with remote saves/deletes off. Retained count 6648.
  Exact rollback copy and report are under private windows-session-20260913.
  Initial token refresh reported session missing before the eventual completed
  reads; this is not an auth-lifecycle success claim.
- Normal replies also repeatedly hit AmbiguousReply. A bounded Muse worker is
  comparing the native parser to existing live/legacy interpretation. Parent
  added content-free metadata decode-stage labels without changing acceptance;
  these edits require native qualification before live use. No raw archive was
  exported and no real messages or credentials were added to source/tests.
- Muse traced two AmbiguousReply causes: the strict two-component parser and
  the explicit reaction/extension-plus-reply coexistence guard. Current normal
  assoc-0/no-payload cases isolate the parser. Native live and Dart legacy
  imports use different split rules, so no guessed parent mapping was adopted.
  Parent added a bounded bridge-only shape classifier: component-count cap,
  UUID position class and canonical-decimal-part flag, never target strings.
  Both diagnostic additions have synthetic regression cases and are batched
  into the same next native run. Muse made no changes and was closed.
- Next native-only run 34770635736 was dispatched for 008a342c5663 with pilot
  a8db46f655. Job 103759469072 passed exact-source validation and was checking
  out sources at handoff. No duplicate run or Pixel APK was launched.
- PowerShell parse and Rust formatting/diff checks passed. The sensitive-log
  scanner caught an existing combined boolean-body-shape/redacted-outcome line;
  separating the scalar shape and typed outcome made the intended boundaries
  explicit and the scan passed. These checks are not a native test substitute.
- All reviewed agents are closed and verified absent. No active local app,
  Flutter test, Cargo or Rust process remained. C: had 76.99 GiB free; no cleanup
  threshold was crossed and no retained source/evidence was removed.

### September 13 chained writes and observed multipart replies

- Native run 34770635736 passed in 25m56s: 145 selected Rust tests, 519 focused
  Dart tests and 51 packaged-DLL codec cases. Parent verified 39 source inputs,
  12 logs, three ARM64 binaries, signed separately and reran 51 codec tests.
  Actual loaded module path was verified during the fresh account read.
- The Windows harness had blocked every edited parent. Added an explicit
  previous-mutation request binding and read-only confirmed-predecessor proof;
  immutable history, receipt, exact confirmed operation, pending-free map,
  account, owner and protected-store identity are required before new sends.
  Old v6 bindings/pristine checks and terminal-source restrictions remain.
- Muse worker produced no patch after bounded redirection and was closed.
  Parent implemented/reviewed the proof and fixtures. An initial test command
  referenced a nonexistent executor test; corrected to the existing transport
  test. New fixture initially used historical terminal times before its real
  staging time; corrected the fixture and made every negative case first prove
  its valid baseline. 27 request/target and 88 journal/projection/transport tests
  passed; analyzer clean. No negative-only test pass was counted as proof.
- Parent request 27 failed IDS 6005 before claim/send. Explicit same-identity
  refresh on new request 31 succeeded. Requests 31, 32, 33, 34 then completed
  send/edit/edit/unsend using qualified native 16112ec69 and current Dart. Each
  mutation had one exact CloudKit confirmation, zero unresolved operations.
- Fresh read obcs2-semantic-1789321273552358.json with native 008a342c5663 proved
  exact final text, three edit-history entries and millisecond timestamps,
  plus matching one-part retraction. Outbox 21 -> 21, remote writes off.
  Messages fetched/applied one echo and did not observe an empty terminal read
  that pass; Chats and Attachments did. Completed-unsend restart submitted zero
  updates. This is bounded protocol proof, not independent Apple/Pixel display.
- Rejected normal replies consistently exposed four components after r:
  three canonical decimal parts and one final UUID. Native and Dart legacy
  splits agree for that exact shape. Candidate parser preserves the full path
  and case-exact UUID, admits only unique final canonical UUID multipart forms,
  and retains ambiguous forms. DTO/converter regressions added; native rerun
  required. Reaction-plus-reply coexistence is not relaxed.
- Extension diagnostics found LiveLayout/Malformed and BinaryPreflight/
  LimitExceeded, rather than a decryption failure. Added fixed wrapper/data
  shape and byte-size observations for the next batch; no limit increase,
  raw payload export, or guessed format acceptance. Type 3 remains unsupported.
- Private provenance: artifacts/windows-native-34770635736/local-qualification.json,
  build-evidence/windows-chain-20260913 and windows-chain-echo-20260913. No Pixel
  install, personal-message deletion, identity reset, or main-repository PR.
- Committed candidate e5547e8c7 and dispatched Windows run 34772982148 with
  pilot a3724ebd0. Job 103765852345 passed exact-source validation and is active.
  Qualification now explicitly includes the chain proof tests and new native
  reply DTO/converter cases. Native changes are not yet live-qualified.
- Pre-handoff: docs reconciled, child shutdown verified, no local app/test/Cargo
  process remains, completed request unsend-34 retained for reconciliation-only
  restart, C: 76.15 GiB free. No protected artifacts removed. Supported session
  deletion remains unavailable; closed transcripts are retained, not erased.

### September 13 qualification wait, reply integration and treemap consolidation

- Added Dart tests preserving multipart reply paths through native-domain mapping
  and actual ObjectBox storage/replay. Missing and cross-chat parents reject with
  the exact parent-unavailable code. Initial replay fixture lacked the ownership
  snapshot normally written by the gateway; fixed the fixture, not production.
  Full adapter/decoder suites passed 204 tests. These test-only additions postdate
  the currently building e5547e8c7 artifact; verify its pinned test blobs separately.
- Bounded Find My comparison confirmed the shared non-daemon API path. Existing
  init/refresh observations already rule out the proposed cached-first timing
  explanation. Parent rejected the unsupported inference that Pixel/Windows
  saved configuration values are identical. No code/share-setting change; worker
  closed and current native service/response issue remains.
- Registration source already persists renewed users and retries failed lookup
  once. Scoped evidence/backups had no useful pre-failure registration snapshot.
  Local-reach's broad filename query did not return promptly and was stopped;
  bounded fallback searches found only unrelated older installations. No expiry
  cause or missing-persistence fix is claimed and no credentials were printed.
- Treemap reduced from 814 to 461 lines before checklist touchups. Preserved its
  434-line historical tail verbatim (verified normalized text equality) in
  TREEMAP_PRE_MULTIPART_2026-09-13.md and linked it from the index. Replaced stale
  active-job/initial-create-only narratives with current gates and invariants.

### September 13 reply restoration and direct-data extension repair

- Run 34772982148 passed in 26m9s: 148 selected native tests, 616 Dart tests,
  51 packaged-DLL codec cases. Parent verified 45 source inputs, 12 logs and
  three ARM64 binaries, signed separately, and passed 51 local codec cases.
  Two post-dispatch test-only inputs were verified against pinned Git blobs;
  current native/ABI remained exact. Smart App Control stayed enabled.
- Non-projecting inspection preserved durable state. A prior ambiguous reply
  was now ready with its body/history intact. Five type-2 extension failures
  showed direct plist Data at liveLayoutInfo (about 4.9-11.9 KiB archives).
  Parent implemented direct/wrapped data equivalence with unchanged live-layout
  and icon limits/gzip validation, plus type/size regressions. No null/string/
  array coercion or raw-value logging. Internal limit labels added without
  raising any budget; observed other failures were only 19-200 KiB on the wire.
- Report obcs2-semantic-1789323940156030.json applied 34 retained messages,
  fetched zero, observed all streams empty and kept outbox 21 -> 21.
  Verified local-copy delta proved 34 distinct new messages, 32 multipart replies,
  33 with text. Two replacement characters were present; no full visual QA claim.
- Existing read-only drain then completed in 5m5s with remote_drained=true,
  projection partial and no cap hit. Its initial remote read is report
  obcs2-semantic-1789324543739425.json; final local sweep is
  obcs2-semantic-1789324819203393.json. Sweep applied 250 Message and 11 Attachment
  records. Copy delta proved 250 distinct messages, 246 multipart replies, 245
  with text and two replacement characters. Remaining retained total 6353;
  outbox unchanged, no remote saves/deletes. Counts examined include repeated
  dependency work and are not unique-message counts.
- Total across these two passes: 284 distinct restored messages, including 278
  replies. Attachment record projection is not a completed-body-download claim.
  Private evidence and verified copies are under windows-multipart-20260913 and
  windows-multipart-drain-20260913 in build-evidence.
- Small Muse cache review made no changes. Parent did not accept its blanket
  claim that compiled caching necessarily requires a source-SHA key; no measured
  cache speedup or safety benchmark exists yet. Review worker closed. Keep the
  current lane unchanged pending a separately justified benchmark.
- Read-only GCP check before the next batch: zero instances; us-west1 T2D quota
  100 CPUs, global CPU quota 164, SSD quota 500 GiB, all usage zero. Existing
  T2D-60 primary lane and GitHub-hosted signing are retained, not reconfigured.
- Candidate 991b8379f was committed and dispatched in parallel to Windows
  34775816810 and full GCE Canary 34775818423, pilot 2da3562ce. Both exact-source
  validation stages passed. GCE create job 103773610019 was provisioning the
  existing primary-lane runner; Windows job 103773606609 was setting up Flutter.
  Expected VM/runner gce-34775818423-1, 75-minute lifetime. No new infrastructure,
  secret/IAM changes or signing migration. Outbound/automatic-upload build flags
  match the prior approved Canary configuration; no account is run in CI.
- Before handoff: all current review workers closed and verified absent; no
  local Flutter/app/Cargo process remained; roughly 75 GiB free on C:. Docs,
  history index and current resume handles reconciled. No protected data or
  evidence was deleted; platform-supported transcript deletion is unavailable.

### September 13 actual full-suite failure and shared metadata boundary

- Windows 34775816810 passed on source 991b8379f: 150 selected Rust tests,
  620 Dart tests and 51 packaged-DLL codec tests. Parent verified/sign-staged
  the artifact and reran all 51 codec cases with App Control unchanged.
  Newer unbuilt metadata extraction was not passed off as the built source;
  its original archive source was verified against the pinned Git blob.
- Live 37-record inspection crossed the raw-data live-layout boundary, but
  the five sampled records still failed at Icon/InvalidIcon. Normal read
  obcs2-semantic-1789327578312833.json added zero records; all streams empty,
  outbox 21 -> 21, retained 6353. No additional restoration claim.
- GCE full Canary 34775818423 failed before APK packaging. Actual outcomes:
  Dart 3563 passed, one failed, four skipped; app Rust/rustpush/automatic-upload
  suites passed; protector harness failed unresolved extension-module imports.
  The earlier green-step interpretation was wrong because continue-on-error
  changes step conclusions. Parent corrected the report. Signing was skipped;
  cleanup passed and independent inventories confirmed no VM/runner remains.
- Muse fixed seven missing literal projector error codes and removed one
  no-longer-emitted literal from the exact current-producer set, retaining the
  historical diagnostic vocabulary. Parent reviewed and passed both complete
  safe-error/diagnostic suites, 38 tests. No prefix allowance/test weakening.
- Parent moved the unchanged metadata schema/JSON validation into the pure
  cloud_sync_extension_metadata module. DTO and archive decoder import it;
  the protector harness uses that same module, not a stub or the network stack.
  Harness serde_json is pinned to the app's 1.0.134. Lockfile metadata resolves
  without rustpush/reqwest; it also reconciles the existing libc=0.2.175 pin and
  required tempfile/rustix changes. Broad offline lock regeneration was rejected
  and replaced by a minimal lock-preserving resolution. Compilation still needs
  cloud proof; Cargo metadata is not a test pass.
- Candidate icon handling adds signature-based raw-image byte routing under the
  same input cap, with PNG fixture/byte-preservation tests, and differentiates
  gzip decode/integrity/trailing-byte failures. Unknown data/corrupt gzip remain
  rejected. This is not evidence of the actual failed icons' encoding/rendering.
- Windows qualification now includes safe-code/diagnostic regressions and all
  shared metadata/harness inputs. GCE persists actual selected-suite outcomes as
  JSON before its unchanged strict gate, and runs the protector with --locked.
  YAML, embedded reporter Python and PowerShell parsing passed; no cache,
  signing, IAM or infrastructure migration was made.
- Find My research identified an experimental secure-People/SearchParty flow,
  but its public author reports no successful live automatic key delivery. It
  is a protocol lead only. No live key request or sharing change was attempted.
  Both review workers are closed; their commands have exited.
- Committed fccca0bb5 and pilot 5fd8d03fe. Retrying Windows 34779665447 and full
  GCE Canary 34779666716 in parallel; both initial exact-source/configuration
  validations passed. Windows job 103784229966 was checking contracts; GCE create
  job 103784232405 was provisioning gce-34779666716-1. Keep these exact handles.
- Pre-dispatch inventory was empty. No old VM, runner or local test/app process
  remains from the failed attempt. Current agents are closed and verified absent.
  Approximately 74.4 GiB free; no evidence, private profile, or transcript was
  deleted. This handoff preserves the full CloudKit/FaceTime/Find My goal.

### September 13 post-compaction reconciliation and date-boundary evidence

- Recovered completed inspection session 68799: exit zero, durable state
  unchanged, offset 256. All eight sampled malformed Attachment records were
  native-ready but Dart rejected DateTime.fromMillisecondsSinceEpoch at
  rust_cloud_semantic_decoder.dart:1239. Fixed filename/line diagnostics contain
  no personal message bodies or credentials. Timestamp field and units require
  investigation; no coercion, omission or reset is authorized by this result.
- Different retained windows also measured 50,507-80,485-byte extension strings
  against the 16,384-byte preflight limit. Archive sizes remain below the total
  cap. The large field is not yet identified, so blanket limit increases are
  not justified. Existing explicit-empty chat identities remain retained.
- Windows 34779665447 and full GCE Canary 34779666716 both completed successfully
  on fccca0bb5 / pilot 5fd8d03fe. Actual outcome JSON confirms app Rust,
  automatic uploads, Dart, protector and rustpush all passed. Packaging, signing
  and cleanup succeeded; independent inventories are empty. Windows artifact
  10325461041 and signed Canary artifact 10324607303 await local qualification.
- Five previously named workers rechecked: all not_found, none active. No
  supported transcript deletion is available. Private evidence and profiles are
  retained; no deletion performed. C: has about 74 GiB free; ADB inventory empty.
- Read-only offset/failure diagnostics in the Windows Dart harness remain an
  uncommitted test overlay, separate from the cloud-qualified native source.

### September 13 raw-JPEG restoration and attachment timestamp repair

- Imported Windows artifact 10325461041 from run 34779665447, source fccca0bb5,
  pilot 5fd8d03fe. Verified 53 source inputs, 12 test logs, archive/member hashes
  and three ARM64 PEs. Cloud proof: 151 selected native, 658 Dart and 51 actual-DLL
  codec tests. Separately signed Rust/test executable; unchanged vendor ObjectBox.
  Local 51 codec plus 24 harness tests passed. Later date-shape changes pass all
  25 harness tests. Analyzer found only two existing style infos, no new errors.
  Smart App Control remains enabled. Native lineage is in the private artifact
  root windows-native-34779665447/local-qualification.json.
- Native inspection identified five failed icons as 2,036-byte raw JPEGs. Those
  five messages now decode ready and have an exact local chat candidate. This
  proves the compatibility fix against actual data, not full widget rendering.
- Run-once 1789332457042301 added one distinct extension-message row. A 3m15s
  drain then added 13 more distinct rows and applied one Attachment record:
  remote report 1789332557626821; local sweep 1789332723873549. All remote streams
  were empty; retained total is 6338; outbox stayed 21; remote saves/deletes off.
  Hash-verified before/after copies independently establish the row deltas.
- All 14 new rows have placeholder-only base text, one replacement character
  each, plus separate extension display text and icon metadata. None of those
  display-text values contains a replacement character. The normal message
  holder routes these records to InteractiveHolder, not TextBubble. This is
  not yet a claim that every interactive provider is supported or that current
  Pixel rendering is correct. Private copy audits now distinguish this shape
  from readable base prose; old text-count metrics alone were insufficient.
- Offset-256 observation confirms eight native-ready Attachment failures all
  have createdAt populated outside Dart's millisecond range, with no other date
  populated. Their scale matches Apple-epoch nanos. Independent source evidence
  establishes that unit: getAttachmentMeta/nsSinceAppleEpoch, legacy attachment
  cutoff, and NativeAttachmentMetaTimes. The converter incorrectly passed that
  raw field as Unix milliseconds.
- Muse worker 01a09c7f-ee9d-7b92-a145-e6f657997f71 implemented the narrow converter
  repair. Parent reviewed source semantics, shortened comments and expanded
  signed/fractional/zero/int64-edge regression cases. Only the converter changed
  in committed 4e7121a18e8c011ae5472831111af86a61280178. No date omission, identity
  fallback, protected-state reset, or Dart-side production coercion was added.
  Native compilation/live repaired-date proof are pending. Worker reviewed and
  closed; shared worktree/evidence retained, transcript deletion unsupported.
- Windows 34782347926 (job 103791533166) is qualifying that exact source.
  GCE app-rust-only 34782416330 (create 103791721863, build 103791894323) is active
  on t2d-standard-60/us-west1-b, runner gce-34782416330-1, existing lifetime.
  This lane intentionally produces no APK. First launch 34782349481 rejected
  APK-writer flags in app-rust-only mode before VM creation. Parent corrected
  flags, verified no VM/runner from that failed launch, and did not alter guards.
- Current Dart-only inspection/copy-audit overlay is separately tested. No local
  native build, Pixel install, account reset or new outbound send was performed.
  ADB is empty. C: has about 65 GiB free; active-worktree build output is about
  9.32 GiB (591 files). Private evidence is preserved; no deletions. Two cloud
  jobs above are the exact resume handles, not reasons to dispatch duplicates.
- GCE date qualification 34782416330 subsequently passed all 631 Rust library
  tests (zero failures/ignored/filtered), including both new date tests. The
  app-rust-only actual-outcomes artifact 10325955208 confirms success; other
  suites were intentionally skipped. Cleanup completed and independent VM and
  runner inventories are empty. Windows 34782347926 still builds the matching
  ARM64 runtime. No claim of repaired live dates before importing that runtime.
- Second Muse worker 01a09c99-78d2-7550-ae24-68b510ae3624 reviewed type-3
  associations read-only. Parent checked the existing type-2 session and
  reaction-range guards. No in-repo type-3 semantics were established; no
  accept/flatten patch was made. Its proposed presence diagnostics mostly
  duplicate existing evidence and are not a reason for another build. Worker
  closed; retained records remain available for a protocol-backed investigation.
- Retained observations now include only the existing account-scoped record
  HMAC alongside fixed classifications, to compare the exact before/after
  records across runtime upgrades without printing raw identities or dates.
- Stored exact pre-repair HMAC observations for eight attachments in private
  windows-icons-20260913/retained-date-before.json. They bind the next native
  repeat to the same records instead of assuming offsets select the same data.
- Flutter's actual image decoder successfully decoded all 14 new stored app
  icons from database copies, with explicit byte/dimension/count bounds and
  proper native-resource disposal. No image file or private display text was
  emitted. This closes the icon-byte validity check, not full interactive UI.
- Final local command suites remain green; actual analyzer output has three
  existing brace-style infos (two harness, one copy audit), not runtime errors.
  Both Muse workers are closed and verified absent; no local app/test/native
  build process remains. Windows 34782347926 is the only active qualification
  job. Keep the goal active and qualify live repaired dates after its artifact.

### September 13 exact attachment-date replay qualified

- Windows 34782347926 succeeded on 4e7121a18 / pilot 5fd8d03fe. Imported artifact
  10326285636; parent verified 53 inputs, 12 logs, three ARM64 PEs and hashes.
  Cloud: 153 selected native, 658 Dart, 51 actual-DLL codec tests. Local signed
  runtime passed 51 codec and 25 harness tests, with original vendor ObjectBox
  and unchanged App Control. Signing/provenance is recorded in the private
  windows-native-34782347926/local-qualification.json.
- Non-projecting repeat matched all eight prior record HMACs, preserved durable
  state, and changed each date failure to ready with a valid Unix-millisecond
  date and one existing local parent. Proof is private
  windows-attachment-date-comparison-20260913.json under build-evidence.
- Normal drain f8b70cf784874ca3b023670d606499e3 completed in 3m28s. Remote report
  1789335099312100 observed empty streams; local report 1789335274615314 applied
  86 Attachment records. Retained total 6252 (94/5046/1112); outbox 21 -> 21;
  remote saves/deletes off. No new messages were applied by this replay.
- Hash-verified before/after copies under windows-attachment-dates-20260913
  passed test/live/cloud_sync_attachment_date_replay_test.dart. Each of the
  eight selected prior malformed sources is uniquely identified in the before
  copy, applied afterward, retains its exact change/etag/generation/payload, and
  has a matching canonical snapshot, parent link and resolvable production
  download source. This is not a file-byte-download or Pixel rendering claim.
- Muse source review distinguishes current legacy repair from upstream history.
  Current legacy searches/refetches authoritative CloudChat parents, not guessed
  Message-derived rosters. V2's existing native Chat observer serves outbound
  direct-candidate disjointness, not raw inbound chatId lookup. A bounded cache
  correlation can use existing protected decoding without invoking that writer
  path. No parent synthesis or unsafe lookup was implemented from this review.

### September 13 parent coverage and separate raw discovery candidate

- Non-projecting cached coverage read 794 current-generation Chat records:
  700 decoded, 81 latest tombstones and 13 out-of-scope. It was not capped.
  Eight distinct missing Message routes found no match against decoded Chat
  identities, alias hashes or legacy normalization. Four applied controls
  correctly found proven parents, verifying the comparison. No durable sync or
  canonical state changed. Missing samples are five bare UUIDs, two direct
  phone routes and one direct email route. This does not prove remote absence
  or intentional deletion; raw record IDs/undecrypted auxiliary sources remain
  outside this comparison. Private evidence: windows-parent-coverage-20260913.json.
- Parent independently verified published upstream message.dart at
  eed1b6332efbb17adbf5ebfa2263ad770169f75e, lines 1100-1115: applyFromCloud returns
  without saving when its parent lookup fails. That method does not synthesize
  a chat. Caller-loop behavior was not independently established here. Our
  current local legacy refetch/repair helper is a later modification, not proof
  of original upstream behavior.
- Auxiliary raw sampling includes chat1ManateeZone in older source, but the
  active permit-bound protected fetch rejects all auxiliary streams. The
  unbound raw API is not an acceptable substitute. No auxiliary live query was
  performed, and no claim is made that the missing parents are there.
- Implemented a distinct protected Chat1 discovery API, fixed zone and 50-row
  cap, with a private purpose gate. Existing semantic fetch retains its three
  allowed streams; Chat1 discovery requires a permit, and semantic decoding of
  auxiliary streams remains rejected. Shared protection/lease handling is
  reused, not replaced. Added policy-matrix/budget tests and source contracts.
- Muse wrote only the rustpush raw-only wrapper and its structural test. Parent
  reviewed the cached bound-container/lookup-only path and kept the existing
  semantic-wrapper forbid list. Dependency c4dd64b5afc086e87d508fed04090f8cd0abc555
  is pushed to fork branch agent/cloudkit-chat1-discovery. An initial shorthand
  refspec failed from detached HEAD; the full refs/heads target succeeded.
  Other pre-existing rustpush changes were not included.
- Local source-contract/harness suites passed 31 tests; Rust syntax parsing
  passed. Native tests, new FRB generation and live discovery are pending. The
  published API is new, so all generated bridge files must be imported together
  and paired with a newly qualified DLL. No partial binding/native substitution.
  Worker reviewed and closed; shared work/evidence retained, session deletion
  unsupported. No Pixel install, new message send, account reset or cloud-data
  mutation occurred in this investigation.
- Candidate 4ffce9c12 ran in GCE app-rust-only 34788562396 and rustpush-only
  34788563781. App Rust passed 633 tests, including the discovery scope/budget
  matrix; rustpush passed 308, including its raw-only wrapper contract. The app
  run correctly failed the generated-binding drift gate because this new API
  changed committed glue. This is not an end-to-end qualification success.
  Both runners were cleaned up; independent inventories returned no VMs/runners.
- Imported exactly seven generated files from artifact 10327298772, with source
  4ffce9c12 and artifact digest
  56c0766ce869c7cf9e3aa47313c36ab13e544d4adc1198d4ac262ae35557d3e1.
  All destination files were clean before import and copy hashes matched.
  SSE-duplicate and diagnostic normalization checks passed; 31 local source
  contract/harness tests passed against the new Dart surface. Current Dart/old
  4e7121a18 native pairing is prohibited. Requalify a matching runtime before
  any live discovery call. No protected Chat1 page has yet been fetched.
- Committed coherent source c6091ddf92e13c902fc61bd911606def5ac373a7. Isolated
  pilot 3ac9ccadb26859e118ba471fa860739f12e34db8 adds native-fetch/source-contract
  provenance inputs, two explicit discovery-policy tests and timestamp spot
  cases/minimum 81 converter tests. PowerShell syntax and diff checks passed;
  the pilot's unrelated asset-graph deletion remains untouched.
- Dispatched Windows 34789713162 and full GCE Canary 34789714678. Expected
  runner gce-34789714678-1, t2d-standard-60/us-west1-b, primary lane, existing
  75-minute lifetime and GitHub-hosted signing. Both builds use the exact source
  above. Review their actual outcomes/artifacts and cleanup before promotion.
- All current Muse workers were reviewed, closed and verified absent. No
  dedicated worktree was created and no protected artifacts were removed;
  supported transcript deletion is unavailable. Local target app/test/Cargo
  processes are absent. C: has about 67.5 GiB free. ADB inventory is empty.
  Existing generated-plugin and unrelated rustpush edits are preserved.
- Next work is the explicit test-host discovery caller with correct protected
  lease adoption/cleanup and separate shadow state, followed by a live bounded
  read only after matching-runtime qualification. The existing raw/general API
  and semantic auxiliary decode remain off-limits as shortcuts.

### September 13-14 matching qualification and first protected Chat1 page

- Windows native-only 34789713162 and full GCE Canary 34789714678 completed
  successfully for exact source c6091ddf92e13c902fc61bd911606def5ac373a7.
  Windows passed 666 Dart tests plus the selected native/discovery contracts.
  GCE passed every actual selected suite and regenerated all seven bindings
  byte-for-byte. Cleanup and independent inventories found no remaining VM or
  runner registration; no production credentials were used or exposed.
- Parent verified the separately signed Windows DLL SHA256
  `9B0B7899BBD31D1EE6C6A15482208055C8C9FED52CF858761CDACD622A0C0C79`, valid
  signer thumbprint `8240557965890665F3B49E5FEC83D511CA4F2C9D`, and vendor
  ObjectBox SHA256
  `9C8583C4015AB9E4CE2ED3D2D581811FA059E03BB528CB8C8387ADCDFDA8D8A5`.
- Added an explicit Windows test-host Chat1 caller under the existing account,
  protected-store, native-session and client-identity fence. It adopts the
  held writer-pause capability, fixes the scope to
  `com.apple.messages.cloud/private/chat1ManateeZone/messages/schema2/shadow`,
  journals into the shadow lane, rejects semantic application and returns only
  bounded counts/safe categories. Focused Dart qualification passed 178 tests
  with one intentional live-only skip; the edited live files analyze clean.
- The first live protected Chat1 request fetched exactly one page: generation 1,
  sequence 0 -> 50, token present, 50 fetched/journaled, zero rejected, and no
  canonical or outbox mutation. This proves the auxiliary zone is present and
  safely readable with the matched runtime. It does not prove missing-parent
  correlation, semantic meaning, complete-zone coverage or production readiness.
- A subsequent cache-only run acquired the same profile mutex and exact signed
  runtime, performed no network read and passed. It found 50 distinct pending
  saves, each with protected identity/raw references and a payload digest; no
  duplicate record hashes, tombstones or system references. Every row is still
  deliberately classified `unsupportedRecordType` / `malformedRecord`, so no
  Chat1 data entered the ordinary decoder or canonical message store.
- The next smallest diagnostic is native-only record-name correlation against
  the eight sampled missing Message parent routes. It must verify each retained
  record-name HMAC, keep clear identifiers and decrypted envelopes inside Rust,
  return counts/booleans only and remain test-host/permit/account bound. Try this
  before any bounded field-shape inspection; do not weaken auxiliary semantic
  rejection or infer deletion from a zero match.

### September 13-14 Chat1 correlation boundary

- Exact source `97f63b5f5d8e4d89aa5b0a6deefb85060999f9e7` passed Windows
  34797113685 and full GCE Canary 34797113773. Parent independently verified the
  engineering bundle, ARM64 PE architecture and matching source provenance. The
  separately signed Rust DLL SHA256 is
  `5B22D174FC50A680DDCE0A64CECD3018F4E551C387B9237600426E84A94E5B12`;
  Authenticode is valid under the retained development certificate. GCE selected
  suites, Android packaging, JVM tests, GitHub-hosted signing and teardown all
  passed. Independent inventory found no remaining VM or current-run runner.
- A mutex-held live cache-only correlation used the retained profile and exact
  signed runtime. It verified eight distinct missing-message route sources and
  50 Chat1 records, performed no network request, exposed no content and left
  durable state unchanged. It found zero exact record-name match pairs. That is
  decisive against record-name equality for this sample, but is not evidence of
  Chat1 irrelevance, remote absence or deletion.
- Native source `e79d1663d4c5c577117b86d4ff298c4a78dc30e8` adds the next
  bounded diagnostic: lookup-only Chat1 PCS acquisition followed by decryption
  of only `cid`, `gid`, `ogid` and `guid` from `chatEncryptedv2` records. Clear
  values and envelopes stay inside Rust; only aggregate counts cross the bridge.
  It cannot page the zone, admit records, persist tokens, send, write or repair
  identity. App-Rust 34799734371 and bindings-only 34799735662 were dispatched
  for this exact source. Matching generated bindings and a newly qualified,
  separately signed Windows DLL are required before the live call.

### September 13-14 encrypted-route result and bounded page walk

- Exact source `19022ea7bf6d4ea1fe32a60c1b5797eeccc15491` passed Windows
  34801034688 and full GCE Canary 34801034710. Parent independently verified the
  schema-2 native bundle and its exact three-file manifest, then copied and
  separately signed only the ARM64 Rust DLL. Signed SHA256 is
  `7D768E4686E62BF21E595C8BAD796A7F3EFE49454A9F42B1F6484A2FDBE886B6`;
  Authenticode and ARM64 PE checks passed. GCE passed every selected suite,
  Android package/native-library identity, JVM tests, GitHub-hosted signing and
  cleanup.
- A mutex-held live semantic correlation used the retained profile and exact
  runtime. It made one lookup-only PCS request, decoded all 50 first-page
  `chatEncryptedv2` records and the bounded `cid`, `gid`, `ogid` and `guid`
  fields, returned no record or routing-field decode failures, and found zero
  direct or semantic route pairs for all eight target routes. No content crossed
  the Rust boundary and durable state remained unchanged. This closes only the
  first-page hypothesis; the discovery fetch was capped and returned a
  continuation token.
- Exact source `2a22acde04031a6a97fb74acb30ae2b48798f1d6` added a bounded,
  in-memory continuation walk. It starts fresh, holds the existing read permit
  and writer pause, scans at most 20 pages / 1,000 changes, decrypts only the
  four routing fields and stops at terminal state, complete eight-route coverage
  or budget. It persists no diagnostic cursor/raw record and cannot project,
  admit, send, write or repair identity. App-Rust 34803552482 passed bridge
  compilation and every selected Rust suite; bindings-only 34803554103 produced
  the expected three-file generated drift. Parent imported exactly those three
  generated files and verified their artifact hashes.
- Coherent source and bindings
  `a951e1251c658e81e9ef6533e5b3e8874b28bae7` passed Windows 34804132572 and
  full GCE Canary 34804133857 through pilot
  `629df1f5d70b2c63c51212b362b05d569df2c3d4`. Parent verified the schema-2
  archive, provenance and exact three-file ARM64 bundle, then copied and signed
  only its Rust DLL. Signed DLL SHA256 is
  `9220F65671F4DBF385BF065C47D35139904DA9FA6BC3A748697BF7A3801832AA`;
  Authenticode and ARM64 PE checks passed. Full GCE suites, packaging, Android
  JVM tests, GitHub-hosted signing and teardown passed; current-run VM and
  runner registrations are absent.
- The mutex-held live paged diagnostic reached terminal state after four pages /
  167 changes. It observed 165 valid `chatEncryptedv2` records and two
  tombstones, with zero other types, record-decode failures or routing-field
  failures. Exact and raw semantic comparisons both produced zero matches for
  all eight target routes. No content crossed the bridge and durable state was
  unchanged. This closes raw equality across the entire current Chat1 zone; it
  does not prove Chat1 irrelevant, deleted or remotely absent. Private log:
  `build-evidence/chat1-paged-correlation-live-34804132572.log`, SHA256
  `DAB31525F0FD23E8878D7BC3DE163251B0439F8E46D971AAFBB887214ADF3EBD`.
- Source `6a1507e9ee3f1908eef650c4378d1300e0f463ad` now adds the smallest
  deterministic next test: comparison-only variants for known iMessage route
  wrappers, `tel:` / `mailto:` schemes and case. All variant values remain in
  Rust and only aggregate counts cross FRB. It neither rewrites stored identity
  nor grants merge, projection or write authority. App-Rust 34806640078 and
  bindings-only 34806647641 are active on isolated T2D lanes; matching bindings
  and a separately verified/signed native runtime remain required before one
  bounded live repeat.

### September 14 normalized closure and parent-field compile repair

- Coherent source `a2f72eff9edce5cc377ca62c472e5f8bc3aa5c4d` passed full GCE
  34807869942 and Windows ARM64 fast-loop 34807865131. The mutex-held live retry
  reached terminal state over four pages / 167 changes, with 165 valid Chat1
  records, two tombstones and no decode failures. Raw and normalized
  `cid/gid/ogid/guid` equality families were all zero for the eight target routes.
  Content exposure was false and durable state remained unchanged. This closes
  only those tested equality families for the current zone.
- Source `2da86926b73cd43c30106c396f8bfcd9be617d40` added the next bounded
  parent signals: participant URIs, property legacy group identifiers,
  last-addressed handle, message `msgProto4.groupId`, sender, service and style.
  Windows workflow 34814691311 passed its platform checks, but bridge run
  34814691313 found two stale generated files. GCE 34814740085 and 34814739930
  then exposed three real Rust compile errors before any selected tests or APK.
  Both GCE cleanup jobs passed; no live diagnostic was run.
- Repair `a48a61565e5ffeff521458ce9771eea84f012864` fixes the optional integer
  result and homogeneous iterator types, and imports only the exact regenerated
  Dart/Rust bridge files that drifted. Mis-keyed dispatches 34815902074 and
  34815902111 were canceled; their cleanup paths completed. Correct app-Rust
  34815927602 and bindings-only 34815927569 now qualify the verified SHA on two
  bounded T2D lanes. Push workflows 34815886008, 34815889414 and 34815886570 are
  also active. No APK/Pixel or Apple-account operation is authorized by these
  compile gates.

### September 14 terminal parent-field run isolates two wire-shape mismatches

- Coherent source and generated bindings
  `cb5e81410f135f969fc15cffee957ad79ab63abd` passed Windows ARM64 fast-loop run
  34843955881. Job 103977295987 completed successfully after 26m06s. It passed
  666 focused Dart tests, 51 packaged native local-send encoder tests, source and
  launcher contracts, ARM64 PE checks and the invalid-launch guard. No Apple
  profile or database was bundled, and no writer or automatic-send capability
  was compiled into the harness.
- Parent verified archive SHA256
  `DCEFCAE4A829914D5715C6324F21489DBE53EFE7605B3C57E1A2C2C2E7B8B88B`, source
  `cb5e81410`, sidecar `629df1f5d70b2c63c51212b362b05d569df2c3d4`, ARM64 architecture, pinned
  ObjectBox bytes and local signature before importing it into the clean
  detached `chat1-live-a93671` checkout.
- Mutex-held live correlation launch `61909185c0e0f5736b8e5c44569236bf`
  completed in about 34 seconds. It was account-bound, performed the intended
  read, exposed no content and left durable state unchanged. It reached terminal
  Chat1 state in four pages / 167 changes: 165 Chat records and two tombstones,
  with zero record-decode failures and no page-budget exhaustion. Cleanup
  confirmed all four owned processes stopped.
- Every one of the 165 records failed before selective comparison for exactly
  one of two reasons: 18 `lah` values decrypted to an empty string, and 147
  `ptcpts` outer lists omitted an explicit false encryption flag. First-page
  counts were eight and 42 respectively. No authentication, PCS, paging, cursor,
  record-envelope or transport failure occurred.
- Source comparison found that production participant preflight already rejects
  only an explicitly true outer flag and only an explicitly false inner flag.
  It therefore accepts omitted flags. Canonical conversion also treats empty
  `lah` as non-authoritative. The diagnostic alone was stricter. The smallest
  repair is to accept empty `lah` as absent for that field only and mirror the
  production participant-flag contract while retaining all type, payload, cap,
  decrypt and participant validation checks. Matrix positions remain stable.
- The completed Muse worker was reviewed and closed. Its aggregate-only
  relationship-shape classifier is deferred, not integrated, because this live
  result found an earlier and narrower blocker. No unique files or commits were
  produced by that worker.
- Repair `908ccc0040ed4bb60d2611db945e0b304eff639c` implements only those two
  compatibility changes. New tests prove empty `lah` does not weaken `cid`, both
  allowed participant flag forms still decrypt and validate, and explicit
  contradictory flags still fail. Rust formatting, diff checks, protected-bridge
  source contracts and live-launch safety/cleanup contracts pass locally. The
  native local test attempted compilation but stopped at the host's missing
  `clang`; this is an environment block, not a passing native result.
- GCE app-Rust run 34849044238 and Windows ARM64 read-only harness run
  34849043947 were dispatched against that exact trusted source. Neither runner
  receives an Apple profile/database, writer capability or automatic-send
  capability. Verify actual native tests, bindings coherence, artifact lineage
  and teardown before importing or making another live request.
- GCE 34849044238 passed the full Rust library suite and generated/check-compiled
  coherent bridge code. Its overall build job then failed the deliberate drift
  gate because only the generated Dart ignored-private-functions comment gained
  `encrypted_last_addressed_handle` and
  `encrypted_string_field_with_empty_policy`. Parent hash-compared all eight
  generated files: the other seven are byte-identical. The exact one-line
  generator output is staged locally; it changes no public API, codec or ABI.
- GCE cleanup for 34849044238 passed and the project has zero remaining compute
  instances. Three older offline, non-busy repository runner registrations tied
  to completed September 12 runs were independently verified to have no backing
  instance and removed; the repository runner inventory now contains zero
  self-hosted runners.

### September 14 exact compatibility qualification and selective parent signal

- Windows ARM64 run 34849043947 completed successfully in 23m57s against exact
  source `908ccc0040ed4bb60d2611db945e0b304eff639c` and pilot
  `629df1f5d70b2c63c51212b362b05d569df2c3d4`. It passed 666 Dart tests, 51
  packaged native codec cases, launcher contracts, ARM64 checks and provenance
  verification. Artifact 10351037466 and its sidecar both hash to
  `6647710ec763084e741541a7cfd9f6a2a272d1395bc7afcf698280a0f96498d6`.
  The 78-file, 335,772,787-byte bundle was imported into the clean detached
  `chat1-live-a93671` runtime. The local receipt, app and Rust DLL all bind to
  the same source and pilot; signatures are valid and pinned ObjectBox bytes
  are unchanged.
- Live launch `1cec35e558d6dc76a0040286129c59eb` then proved the compatibility
  repair against the account-bound Chat1 zone. It reached terminal state in
  four pages / 167 changes, decoded all 165 Chat records plus two tombstones,
  and produced zero record or route-field failures. Its first wrapper version
  preserved only failure matrices and basic counts, so the run did not retain
  the selective match counters needed for the next decision.
- The launcher was narrowed to preserve only a fixed, bounded allowlist of
  aggregate booleans and counters. It rejects arbitrary strings, out-of-range
  counters, malformed matrices, content exposure and durable mutation. A child
  failure may retain only the same bounded `failure-aggregate.json`; raw stdout
  is always removed. Synthetic launcher tests pass.
- Repeat launch `4842d0299701cd6b74748f714e04b894` reached the ready boundary but
  the Dart child exited nonzero. The first wrapper revision then hit a strict
  property-access failure before retaining the bounded aggregate. Cleanup still
  confirmed all four owned processes stopped and raw stdout was removed. This
  transient failed attempt remains evidence; it is not rewritten as a pass.
- Identical retry `dd0cf181df5b3751342e8a2f78dc07ad` succeeded. It was
  account-bound, performed the requested read, exposed no content and left all
  durable state unchanged. Four pages contained 167 changes: 165 Chat records
  and two tombstones, terminal without budget exhaustion, with zero record and
  route-field failures. All exact/raw/normalized `cid`, `gid`, `ogid`, `guid`,
  legacy and last-addressed-handle match families were zero for the eight
  unresolved Message sources.
- Sender membership in Chat1 participants was the sole positive relationship:
  25 pairs / three sender targets / 11 Chat records on the first page, and 76
  normalized pairs / three sender targets / 31 Chat records across the zone.
  Every Chat record had participants; there were 59 direct-style and 106
  group-style records. This proves a relationship edge but not a unique parent.
  Sender-only admission would be unsafe because three targets fan out across 31
  records. The next bounded test must classify complete participant-set, style,
  service, time and already-proven ownership corroboration. It may propose only
  a unique candidate; ambiguity remains retained.
- Cleanup for all three launches confirmed four owned processes stopped and no
  raw stdout remains. No APK was built or installed and no CloudKit write was
  performed.

### September 14 standalone identity and read-authentication lifecycle

- The first direct native-test-host attempt against source `4d774121a` failed
  before Apple setup because the test treated the protected-store identity as a
  bare digest. Production intentionally uses `obcs2.store.<digest>`. The failed
  attempt retained no aggregate and left the 212-file, 155,026,542-byte Cloud
  Sync state byte-for-byte unchanged.
- Source `df8c75bceed50622ddbb1f7cd3f717854034c9e1` added the exact
  protected-store grammar validator plus an early fail-closed manifest check.
  GCE app-Rust run 34873674805 passed all 673 Rust tests in 2.86 seconds and
  completed VM/runner cleanup. The workflow's final status was failure only
  because regeneration added `is_protected_store_identity` to one generated
  Dart private-helper comment. Parent imported that exact one-line result; no
  bridge API, codec or ABI changed.
- Windows ARM64 run 34873675005 succeeded for the same exact source. Artifact
  10361047371 passed the independent native-test-host verifier: exactly three
  ARM64 files, 110,998,016 bytes, read-only variant, source/pilot provenance and
  51 native codec cases. The executable, vendor ObjectBox and Rust DLL SHA256
  values are respectively
  `8D27909E60D574EA0925246A610CFEE0CD7BCB6DA25C21B7C15336D8D3CBCE95`,
  `9C8583C4015AB9E4CE2ED3D2D581811FA059E03BB528CB8C8387ADCDFDA8D8A5`
  and `22B80DCA5923F7FB7E09A5574AB9FB26EDDF8B37ABAEE31C25684E757CBF0207`.
- Two controlled standalone attempts then passed protected-manifest validation,
  hardware/account restoration and client construction but stopped before any
  Chat1 page at `chat1_standalone_read_authentication_failed`. Neither emitted
  an aggregate; both preserved every Cloud Sync file and byte. The identical
  repeat rules out the earlier manifest fix and a one-off process race.
- Full-flow review found a test-host lifecycle omission. `make_cloudkit`
  restores a persisted read-authentication generation when usable, but the
  standalone caller went directly to container warmup. Production explicitly
  calls `cloud_sync_ensure_read_authentication` first so an expired or missing
  generation is refreshed before the writer pause. This is test-path debt, not
  evidence of a Chat1 schema or PCS failure.
- Candidate `fdd2beb595a4599c8783fbc8be5ed3e286415e69` now mirrors that
  production order, classifies only fixed safe refresh failures and adds a
  source-order regression test. Exact-source Windows run 34877349884 and GCE
  app-Rust run 34877349816 are active. No APK, CloudKit record write, personal
  content upload or Alpha change is part of either lane.

### September 14 privacy-safe relationship graph and epoch finding

- Source `b39c785b36579586843616cbbac5bd639f4fb85f` extends only the
  Windows-test relationship graph. It decodes the eight exact target Message
  sources plus a bounded 2,048-source Message anchor cohort, pseudonymizes every
  identifier before serialization, and records route-cluster evidence. It does
  not admit, project, save, update or delete a CloudKit record.
- GCE app-Rust run 34889517605 completed successfully with reproducible bridge
  bindings, the selected Rust suite and verified ephemeral-runner teardown.
  Bindings run 34889470902 also passed Rust, rustpush, remote-Anisette and
  protector-harness checks. Windows ARM64 run 34889520601 passed in 24m53s and
  produced artifact 10366986676. Parent verified exact source/pilot provenance,
  three ARM64 binaries, the pinned ObjectBox hash and the local development
  signatures before execution.
- The exact b39 standalone run authenticated and reached terminal Chat1 state:
  four pages / 167 changes, 165 decoded Chat records, two tombstones and no
  record failure. Of 2,048 protected Message anchors, 1,622 decoded and 426
  remained safely skipped. No plaintext or raw identifier crossed the report,
  and all 212 Cloud Sync files / 155,026,542 bytes were byte-identical before
  and after.
- Five of the eight target messages had no candidate. Three incoming bare-route
  messages each retained the same two group-style candidates, indexes 79 and
  164. Sender membership, service/style and destination `dcId` against Chat1
  `lah` corroborated both. Route, group and direct last-seen evidence matched
  neither. Participant coverage also cannot decide: Chat1 participants contain
  remote members while `lah` holds the local handle, and each target contributes
  only one observed remote member. Selecting the two-member rather than the
  three-member candidate would therefore guess missing participants.
- A separate source audit found that CloudKit record system dates are Apple-
  reference seconds. `cloud_sync_native_fetch.rs` currently multiplies those
  seconds without adding 978,307,200,000 ms in both envelope decode and page
  preparation; the currently unused semantic decoder repeats the defect. The
  protected envelope preserves the original floating-point seconds, while
  derived ObjectBox times, equality fences and attachment source-version hashes
  can carry the legacy interpretation. The diagnostic currently compensates by
  adding the offset to those legacy milliseconds. A production fix must version
  the derived representation and lazily recompute from protected bytes; blindly
  adding the offset or changing only the decoder would break existing rows and
  double-shift the diagnostic.

### September 14 versioned system-timestamp repair candidate

- The local candidate now converts CloudKit system-field `Date.time` values
  from Apple-reference seconds to Unix milliseconds in both native fetch decode
  paths. Conversion preserves the prior containing-millisecond rounding, rejects
  non-finite or out-of-range values and uses checked addition for the
  978,307,200,000 ms epoch offset. The standalone b39 relationship probe now
  consumes the native canonical value directly instead of adding the offset a
  second time.
- `CloudInboxChangeEntity` adds nullable ObjectBox property 28,
  `serverModifiedAtFormatVersion`. Null is the durable representation of a row
  written before the property existed, explicit 0 is legacy Apple-epoch
  compatibility and explicit 1 is canonical Unix. New semantic and shadow
  journal rows write 1. A single checked read helper normalizes null/0 lazily;
  it never rewrites the row, checkpoint, generation, sequence, cursor or
  outbox. Unknown nonempty formats and arithmetic overflow fail closed.
- The actual predecessor-schema test creates a database without property 28,
  reopens it twice with the current model and proves the marker remains null,
  the canonical read gains exactly one epoch offset and all control fields stay
  unchanged. Store tests prove newly journaled semantic and shadow rows persist
  marker 1. Gateway tests prove legacy normalization preserves the physical row,
  unknown formats stop before mutation and a canonical mismatch still loses the
  exact inbox fence.
- Attachment cache manifests are now `obcs2-attachment-cache-v2`; a dedicated
  native test proves a correctly sized and hashed v1 pair is rejected rather
  than reused. Quarantine evidence is v3 and includes the nullable format marker
  so a marker change invalidates old repair evidence instead of silently
  changing timestamp meaning.
- Local qualification passed 221 focused ObjectBox model/store/gateway tests,
  180 downstream quarantine/attachment/identity/group/recovery tests and 72
  production-adapter/Windows-harness/materialization tests. Four focused
  Rust tests pass for native fetch conversion, semantic conversion, diagnostic
  conversion and legacy cache rejection. One extra-`?` Rust type error and one
  attempted double normalization of the already-canonical identity DTO were
  caught by these checks and corrected. Exact-source GCE, Windows live replay
  and Pixel existing-database upgrade proof remain; this is not yet a release
  claim.

### September 14 retired-receipt recovery and ordinary Windows replay

- Commit `306d00700` makes protected fetch recovery tolerant only of missing
  outbound receipts that no longer carry write authority. Strict write recovery
  is always fresh. Proven terminal local-send and attachment-upload source bytes
  remain in complete liveness even after their historical receipt stops being a
  recovery prerequisite.
- A Muse audit found the first local-send retirement predicate trusted stored
  marker equality without recomputing the current outbox binding. Parent accepted
  the finding and committed `ea7560b83`, which binds retirement to the exact
  deterministic operation, scope, generation, key, payload, creation time,
  confirmation state and Apple request/operation identities. The four focused
  suites pass all 172 tests; targeted analysis reports no issues.
- The dual-provenance Windows launcher passed 17 contract tests and a real source
  compatibility check. It ran current Dart `ea7560b83` with the unchanged,
  qualified native host `9712487af`. Session
  `2c544457b08a06406aabcfa8fc5cb10a` completed two fresh stable ordinary
  read-only passes. Both fetched/applied 0/0, retained 94 Chats, 5,046 Messages
  and 1,112 Attachments, observed terminal empty reads for all zones and kept
  outbox 21 -> 21. Remote saves/deletes were disabled, no content was exposed,
  raw output was removed and owned-process cleanup was confirmed.
- A content-free post-run inventory finds 21 confirmed outbox rows and five
  absent historical outbound receipts. The terminal local-send and upload-plan
  receipts are now proven retired. The strict write block is exactly three
  mutation rows: one state-1 edit, one state-3 edit and one state-3 unsend. All
  three protected files exist; each reference hash and embedded lease owner
  matches its durable lease binding. No receipt was synthesized and no row was
  retried, promoted, deleted or remotely submitted.
- The exact reconstruction candidate is now source-implemented across native,
  generated FRB, Dart transport, lifecycle and ObjectBox. Native validation
  reopens the exact protected source and independently binds the account/store,
  purpose, source/reference/payload hashes, payload length, embedded lease owner,
  mutation/target GUID hashes and target part. The repair writes only the exact
  committed receipt; it provides no send, retry, state transition, release or
  acknowledgement authority. Changed claims, active manifests and tampered
  sources fail without a receipt.
- Local qualification passed 299 focused Flutter tests, two native adversarial
  tests and targeted analysis. The next falsification is full exact-source GCE
  qualification, then live Windows fast-loop recovery of the same three rows.
  The state-1 edit must remain outcome-unknown with zero resend; only the state-3
  edit/unsend may finalize after exact predecessor proof. A fresh process must
  prove zero duplicate IDS or CloudKit operations before any Pixel candidate.

### September 14 exact receipt repair and fresh-chain restart

- Commit `bbfa149f1` passed Build 34923170226, GCE 34923191959 and Windows
  fast-loop 34923533854. The imported local-write artifact passed exact source,
  ARM64, provenance, native-library and 51-case native verification.
- Strict recovery reconstructed exactly three missing committed lease receipts.
  Reopening the state-1 edit returned the required no-retry safe code, changed
  no durable mutation state and issued no IDS or CloudKit resend.
- Metadata-only inspection tied the unfinished state-1 edit, state-3 edit and
  state-3 unsend to writer epoch 2. Current stable V2 authority is epoch 14.
  The state-3 attempt therefore stopped before network I/O at
  `cloud_sync_local_mutation_owner_changed`. Those historical rows remain
  unresolved evidence and will not be rebound across epochs.
- A fresh approved parent request created no claim and sent no message because
  IDS returned transient alias-removal status 5052 during registration. The
  ordinary setup path already retries this exact condition once. Commit
  `07e58fd0b` applies the same bounded five-second retry to the Windows harness,
  duplicates the FRB-owned user for each attempt and changes no send authority.
  Focused analysis and all 18 Windows-write tests pass. Exact-source Windows
  fast-loop run 34926960736 is in progress.

### September 15 exact same-epoch write chain

- Windows fast-loop run 34926960736 completed successfully in 25m9s against
  source `07e58fd0b1cd1c0d8c38e20829ca7a67a5c653b0` and pilot
  `629df1f5d70b2c63c51212b362b05d569df2c3d4`. Artifact 10380667192 contains
  78 files / 335,925,603 bytes and passed 669 Dart tests, 51 packaged native
  codec cases, launcher contracts, ARM64 inventory and provenance checks. The
  internal archive SHA256 is
  `ea87e2931a58cf6f84093478ca6a41c9bc8734170be746d8c7b81a80d8cd7a39`.
- Parent independently verified source, pilot, variant, writer flags, file
  hashes, signatures and the pinned ObjectBox runtime, then imported the bundle
  into the clean detached 07e worktree through the rollback-protected importer.
  The receipt, executable and Rust DLL all bind to the same exact archive.
- Fresh request `qualification-20260915-chain-parent-35` completed after the
  bounded 5052 retry path. It recorded positive IDS confirmation, one admitted
  send, exact readback, finalized its protected outbox lease and left no chat
  readback pending.
- Edit-36 and unsend-37 each completed with one CloudKit submission, one exact
  confirmation, zero not-applied/diverged/unresolved operations and complete
  local reflection. A new process reopened unsend-37 and performed
  reconciliation only: zero CloudKit submissions and zero confirmations.
- The content-free post-run audit changed no retained database bytes. Outbox
  count moved from 21 to 24 and all 24 rows are confirmed. Local-send rows moved
  14 to 15. Mutation rows moved 9 to 11, with terminal state-5 rows moving 6 to
  8. The new edit and unsend are terminal; the final unsend projection matches
  the bound target and route, carries positive IDS/source/reflection evidence,
  and created no initial-send intent. Writer authority is stable at epoch 18.
- The three historical epoch-2 mutation rows remain deliberately unresolved:
  one state-1 edit, one state-3 edit and one state-3 unsend. Their protected
  files and lease envelopes remain intact. They were not rebound, resent,
  promoted or deleted.
- This closes the exact Windows direct-send/edit/unsend/restart gate. It does
  not establish independent recipient UI behavior, ordinary Pixel composer
  behavior, Android lock/reconnect/process-death recovery, groups, media writes
  or the separate FaceTime and Find My gates.

### September 15 exact signed Pixel candidate installation

- GCE runner-pilot run 34929558345 built and signed Canary from exact source
  `10d58a5bd89fab82fe64fd6adee802634db1a162`. Artifact 10382240064 passed the
  full selected suites, automatic-writer qualification, Rust, rustpush,
  protector and Android JVM tests, package/native-library verification,
  signing and runner cleanup.
- The downloaded `app-canary-debug.apk` is 452,930,083 bytes with SHA256
  `B2B8EDDAFA1FAEC044E9B492BE7CBE888E568F928A77C678D6758C3C11A162DB`.
  An in-place `adb install --no-streaming -r` succeeded. The installed base APK
  has the same hash, package `com.bluebubbles.messaging.cloudkitcanary`, version
  1.15.0 (20002227), signing identity `292b62eb`, and preserved first-install
  timestamp. Alpha was not modified.
- Canary reopened its existing ObjectBox store and displayed retained chats.
  Startup reported receipt replay deferred followed by automatic writer ready.
  It also posted an `iMessage registration needs attention` notification saying
  sending is unavailable. Until source and timestamped logs distinguish a stale
  persisted recovery notification from a current registration failure, the
  ordinary Pixel send is deliberately not attempted.
- Preserve the immediately preceding verified Canary APK as rollback until this
  candidate passes registration, ordinary send/readback and restart-dedupe.
  Other superseded APKs are disposable only after exact hash/provenance review.

### September 15 semantic evidence vocabulary repair and replacement candidate

- The installed 10d Canary reached semantic pull but aborted safely before pass
  1 with `cloud_sync_protocol_evidence_event_type_invalid`. The emitted event
  was not malformed CloudKit data: `fetchStarted` and `inboxApplyStarted` are
  valid `CloudSyncEventType` values used by the production pipeline, but both
  were absent from the fixed evidence-label vocabulary.
- Commit `0feaa063a1489621d6828e711305d602f12a31cc` adds only those two missing
  labels and a regression test that constructs evidence for every enum value.
  A clean detached checkout passed all 11 focused evidence tests.
- Full GCE run 34938077867 passed all five selected suite outcomes, automatic-
  writer checks, Android JVM tests, native/package verification, GitHub-hosted
  signing and cleanup. The ephemeral instance `gce-34938077867-1` and runner
  registration were absent after cleanup.
- Signed artifact 10384629324 downloaded as a 452,930,083-byte Canary APK with
  SHA256 `8A99FBEB7A2B28D25E352A7DB18DFC11A35EA1DBF9ADBD724945127D22F222A6`.
  Local verification confirms APK signature schemes v2/v3, signer certificate
  SHA256 `0ea17c1b67581ca79660d33db45af0a36b71ea36a4cbafec5293d3ae80570d79`,
  package `com.bluebubbles.messaging.cloudkitcanary`, version 1.15.0
  (20002227), and all three required ARM64 native libraries.
- No ADB target was available after qualification, so the APK remains
  uninstalled. The next falsification is an in-place Canary upgrade followed by
  a semantic pull proving the invalid-event code is absent and pass 1 advances.
  Build success is not Pixel-live proof, and Alpha remains out of scope.

### September 15 exhaustive retained projection and empty-route evidence

- The Windows live launcher gained explicit `drain` and excluded-Chat replay
  modes, exact terminal-stage checks and content-free native diagnostic
  aggregation. Its contract suite passes 21 cases. Raw process output is still
  removed after bounded evidence extraction.
- Exact read-only drain `ad42f0997054fef22da1547807361a93` examined 1,359
  Message saves in 43 batches and 1,011 Attachment saves in 32 batches. It
  reached remote terminal state and attempted the retained projection sweep,
  while preserving all 6,252 retained rows and 24 confirmed outbox rows. It
  performed no remote write and exposed no content.
- Excluded-Chat replay `11bcb9af66e228e0ca630ae1696e1b90` examined all 13
  excluded Chat saves: three were iMessage Lite and ten were RCS. None can
  provide the missing iMessage parent relationship.
- Diagnostic drain `1373eeba766d871af6f790e0401b494f` proved that all 539
  `MalformedRequiredIdentity` messages contain every required CloudKit field,
  but their decrypted `chatID` value is empty. The set contains 490 incoming
  records with a sender and 49 outgoing records with no sender. This branch is
  distinct from the 183 converted messages retained as
  `canonical_message_chat_unavailable` and from the earlier eight-record Chat1
  correlation sample.
- No routing fallback is yet authorized. The next bounded experiment must
  classify `msgProto4.groupId`, `dcId`, outer type and unique Chat1 ownership
  without retaining identifiers or content. Sender-only routing is unsafe
  because an incoming sender can also be a member of a group conversation.

### September 15 exact service split and bounded carrier reclassification

- Re-analysis of the same 539 content-free route shapes found 531 top-level
  `SMS` records and only eight iMessage records. The SMS rows comprise 483
  incoming and 48 outgoing records; 475 carry a nonempty `msgProto4.groupId`
  and 56 do not. The eight iMessage rows comprise seven incoming and one
  outgoing record, all without group evidence. This explains why the previous
  490/49 direction split was insufficient: almost the entire apparent
  malformed-identity backlog is carrier data that the semantic iMessage lane
  must deliberately exclude.
- Commit `7d38f1dd8900110e298ee091fc8e715a8d988212` retains strict field-presence
  validation but no longer requires nonempty `guid`/`chatID` values before
  returning a typed SMS/RCS out-of-scope disposition. A nested non-carrier
  service remains an unsupported-service quarantine, and iMessage plus
  iMessage Lite identity rules remain strict.
- Retained replay can relabel a historical malformed row only when the fresh
  decoder produces that typed carrier disposition and both caller and locked
  ObjectBox row carry the exact same eligible prior category. Dependency,
  conflict, tombstone, changed-row and forged-category paths remain closed.
  Reclassification rotates the exact row only; it does not open a canonical
  transaction, advance a checkpoint or alter the outbox.
- Local qualification passed all 145 focused applier/ObjectBox tests, including
  restart durability, exact-row fencing, forged-category rejection and zero
  canonical mutation. The initial GCE dispatch 34957336240 was rejected before
  VM creation because the operator supplied an incorrect expanded commit SHA;
  cleanup passed. Correct exact-source app-Rust run 34957446005 then passed all
  682 Rust tests and reproduced the committed bridge bindings. Its build job
  completed in 6m01s. Runner cleanup passed, and independent GCE-instance and
  GitHub-runner inventories found no residue. The read-only app-Rust lane built
  no APK and received no production account or CloudKit credentials.
- The separate 183-row `canonical_message_chat_unavailable` branch is not fixed
  by this service correction. Its eight sampled records have nonempty matching
  `chatID`/`msgProto4.groupId` route evidence, but terminal Chat1 correlation
  still proves no unique owner. Visible provisional-Chat creation remains
  closed until deletion/tombstone semantics rule out resurrecting a removed
  conversation.
- Exact Windows native-test-host run 34957628962 completed successfully in
  24m35s against source `7d38f1dd8900110e298ee091fc8e715a8d988212`
  and pilot `629df1f5d70b2c63c51212b362b05d569df2c3d4`. Artifact
  10392807158 passed 671 Dart tests, 51 packaged native codec cases, ARM64 and
  pinned-ObjectBox checks. Its declared and actual archive SHA256 both equal
  `7e5a7071e8cfe610bf8d4fbcc7577b0fe39b2ddaa71ef9e8ac25ad02412a279a`;
  provenance SHA256 is
  `97bdc2a056477983ba9b52b6dd019f7f485a6c49c3e3b23ad48c25bb8edad5b6`.
- The independently verified bundle was imported through the protected
  native-test-host importer. Before any live mutation, the isolated Windows
  ObjectBox and Cloud Sync V2 native store were backed up locally as
  `build-evidence/cloudkit-v2-pre-7d38-live-20260915.zip`, SHA256
  `54DA744F2BEA11DB3DD76DAF193ACBA6B31216E27F959FD66A9BB2C68BAA0C43`.
  The backup contains personal data and must never be uploaded.
- Two initial harness launches failed before semantic work because the clean
  detached worktree lacked ignored Flutter package metadata and then the
  pinned `telephony_plus` submodule. Restoring only compatible generated
  metadata and exact submodule commit
  `5210e940dd92ae371f8c74eaeb552d0704034244` made the non-live compile gate
  pass with the source worktree still clean. This was harness setup debt, not a
  CloudKit or account regression.
- Live drain `2b31b210b1d2d500044db1c9acd958be`, report
  `obcs2-semantic-1789469940365007.json`, completed on exact source. Remote
  streams were already drained; fetched/applied remained 0/0, retained totals
  stayed 94 Chats + 5,046 Messages + 1,112 Attachments, outbox stayed 24, and
  remote saves/deletes remained disabled. The exact-row transaction relabeled
  573 Message saves from `malformedRecord` to typed carrier
  `outOfScopeService`, reducing blocking Message saves from 1,359 to 786.
- The earlier 531-row forecast covered only the newly recognized
  present-but-empty carrier identities. The additional 42 are the malformed
  subset of 110 rows that the prior decoder already typed as carrier but could
  not relabel under its unsupported-only durable gate. The other 68 still fail
  the exact eligible prior-category check and remain unchanged. Thus 573 equals
  531 newly typed rows plus 42 stale-label corrections; no unrelated category
  moved.
- Fresh-process drain `911bb545a8c357f6942e57e5bfe5dc3a`, report
  `obcs2-semantic-1789470215197415.json`, proved idempotence: no transition
  diagnostic, no fetch/apply, and unchanged Message counts of 3,763
  out-of-scope, 307 malformed, 474 dependency and five unsupported. Retained
  totals, outbox 24 and the remote-write-disabled posture were unchanged. The
  remaining 786 Message and 1,011 Attachment blocking saves require separate
  evidence; this result does not authorize broader admission or relabeling.

### September 15 full 81b Canary qualification and Find My live evidence

- Full GCE run 34961566410 built exact source
  `81b17b36b9361936fc92c7e6d64bb91eb2ee3d90` with the conditional writer and
  automatic uploads enabled. The full Dart suite, all 682 Rust tests,
  rustpush production tests, Cloud Sync protector harness, reproducible bridge
  bindings, Android JVM tests, package/native verification and GitHub-hosted
  signing passed. The producer job took 29m46s; the complete workflow including
  VM creation, signing and teardown took 33m13s.
- Signed artifact 10394532278 downloaded as a 452,942,371-byte
  `app-canary-debug.apk`, SHA256
  `57046E3AF204A7A52E2537EC554A00C4C97485FDBD9976BA62F46A61B55EFA3C`.
  Local verification confirms package
  `com.bluebubbles.messaging.cloudkitcanary`, version 1.15.0 (20002227), APK
  signature schemes v2/v3, the expected Canary certificate, and the Rust,
  Irondash and super-native-extensions libraries for ARM64. Independent
  post-run inventories contain no GCE instance and no self-hosted runner.
- The Pixel was not reachable over wired or wireless ADB after artifact
  verification. Installation and all Android lifecycle/read/write claims
  remain pending. Alpha was not touched.
- Retained Windows Find My launch
  `1bed3346c9374c3b81f402075da59746` used the separately verified signed
  `7d38f1dd8` native runtime. Fresh People and Devices requests completed.
  People returned one uniquely selected row but no native location; its native
  response marked sharing opted out and supplied no coordinate, permission or
  locate-in-progress signal. Devices returned zero rows. Items remained
  deliberately not invoked because their initialization side effects are not
  yet qualified. This establishes that this capture lacks coordinates at the
  native response, not that the user's wife actually stopped sharing.
- The live launcher writes a `findmy-windows-testhost-v1` envelope around its
  nested `windows-findmy-probe-v1` report. The offline qualifier documented the
  launcher report as accepted but rejected the envelope as an unknown schema.
  Commit `d13d88797` pins the launcher to the exact signed runtime and adds a
  strict envelope extractor that requires ABI verification, a finished valid
  terminal stage, typed process/native fields and matching launch IDs before
  qualifying the nested probe. Unknown, failed, replaced and forbidden-field
  envelopes fail closed. All 54 qualifier tests, 11 retained-preflight tests,
  the synthetic process/mutex/cleanup launcher contract and the Flutter host
  contract pass. The real report now qualifies as partial with fixed codes
  `absent-coordinates`, `empty-inventory`, `items-not-invoked` and
  `selection-matched-no-location`.

### September 15 retained outbound-lease integrity gate

- Tooling commit `a849ae04a` adds a content-free, opt-in Windows inspector for
  every durable outbound lease owner: page fetches, outbox rows, local-send
  source bindings, edit/unsend intents, record-map readbacks and attachment
  upload plans/results. Terminal source references are classified separately
  from leases that must still exist, so correct cleanup cannot be mislabeled as
  loss. The live mode fails if a required lease, protected mutation source,
  envelope binding or mutation claim is missing or duplicated.
- The inspector was compiled and analyzed with no issues, skipped by default,
  then run only against a temporary exact copy of the retained Windows profile.
  It found 24 outbox rows, all confirmed; 15 local-send rows; 11 mutation rows;
  one attachment-upload row; zero pending record-map leases; and stable writer
  authority at epoch 18. All three required leases belong to the preserved
  historical epoch-2 mutation rows, all are present, and every protected file
  matches its lease envelope. There are zero required-lease absences, missing
  protected sources, mismatched envelopes, duplicate claims or unmatched
  claims. The terminal protected send and terminal attachment upload both have
  their expected released-reference evidence and no stale required lease.
- A complete SHA256/length snapshot proved the original profile remained
  unchanged across the first cloned run: 48,805 files before and after, zero
  changes. The exact temporary copy is
  `C:\Codex\OpenBubblesReview\temp\lease-inspector-20260915-1145`, 48,805
  files / 600,028,057 bytes. It is disposable because the source snapshot is
  intact, but the platform destructive-action guard rejected its removal. Keep
  it classified as pending cleanup; do not treat that copy as another account
  profile or upload it because it contains personal data.

### September 15 exact 78d Pixel upgrade and live semantic pull

- The independently verified signed artifact from full GCE run 34983806715 was
  installed in place on the Pixel 10 Pro Canary package over wired ADB. The
  package, 1.15.0 (20002227) version and signing certificate match the qualified
  artifact. Existing setup, registration, chats and retained CloudKit state
  survived. Alpha was not touched, and no uninstall, data clear, checkpoint
  reset or registration repair was performed.
- After the user recovered the encryption setting with an off/on cycle, the
  content-free Canary status reported setup and authentication ready, legacy
  sync and logout inactive, coordinator ownership active and outbox settled.
- Reports `obcs2-semantic-1789486767100501.json`,
  `obcs2-semantic-1789486866607721.json` and
  `obcs2-semantic-1789486960673517.json` bind to exact source `78d0f8cf2`.
  Each kept outbox 1 -> 1 with remote writes disabled and fetched zero because
  the Apple cursors were already at their terminal head. Retained local
  projection reduced Messages 7,439 -> 7,409 -> 7,369 and Attachments
  1,330 -> 1,302 -> 1,242 while Chats remained 94. The third report applied
  40 Messages and 60 Attachments. These were intermediate progress reports.
- The same foreground operation reached terminal report
  `obcs2-semantic-1789489102934586.json` at 09:18 local: two passes, remote
  drained, fetched zero, applied 203, retained 8,502, deferred/quarantined zero
  and outbox 1 -> 1. Remote saves/deletes remained disabled. It applied 192
  Message and 11 Attachment rows, released the coordinator and kept
  authentication ready.
- The retained total is classified rather than silently discarded. Chats retain
  94 rows, including 13 out-of-scope saves and 81 tombstones. Messages retain
  7,177 rows with 718 blocking saves. Attachments retain 1,231 rows with 1,116
  blocking saves. This is terminal Apple-head and bounded-projection evidence,
  not proof that every historical record can be projected.
- The log showed sustained local Message and Attachment projection with
  no authentication or CloudKit-fatal error. It also exposed one Find My
  message null assertion at `find_my.dart:75` and a follow-on deactivated route
  lookup at `stateful_boilerplate.dart:164`; the engine continued. A repeated
  `ListTile` background/ink warning is a UI styling warning, not a CloudKit
  crash. These defects require separate source repair and focused tests after
  the exact-source live run ends.
- The removable Canary ADB receiver reports the active UI pull through
  `semantic_pull_active`, but its controller-owned `pull_state` remains `idle`
  because the operation was launched in the UI. This is an observability gap for
  qualification tooling and must not be interpreted as an idle engine.
- Android background wake first returned `outcome=retry` at 09:23 after a
  transient HTTP-server/timeout boundary. WorkManager retried without changing
  registration or the outbox. Report `obcs2-semantic-1789489571217410.json`
  then completed at 09:26 with one pass, all three zones empty-terminal,
  fetched/applied zero, retained 8,502 and outbox 1 -> 1. The background policy
  classifies this safe terminal read as complete. Its success return does not
  currently emit an explicit `outcome=complete` line, so that missing line is a
  logging seam, not proof of a continuing retry.
- Post-wake status was stable with semantic engine inactive, authentication
  ready, coordinator inactive, outbox settled and semantic pull available. The
  next unchanged-artifact lifecycle gate is a controlled cold restart followed
  by a no-duplicate incremental pull.
- A separate Pixel UI defect appeared when one failed attachment materialization
  (`cloud_attachment_source_invalid`) rendered its error state: Flutter reported
  a vertical RenderFlex overflow. Nearby attachments downloaded successfully.
  Reproduce the narrow/high-text-scale failure state and fix the layout without
  hiding or reclassifying the underlying materialization error.
- After two stable idle preflight checks, Canary was force-stopped and cold
  launched without uninstall, data clear, cache clear, registration repair or
  legacy-sync change. The new process retained setup and authentication and
  reached writer-ready state with the settled outbox intact.
- That fresh process scheduled one bounded background read without a competing
  manual start. Report `obcs2-semantic-1789490381477658.json` finished at
  09:39 local on exact build `78d0f8cf2`: one pass, every zone empty-terminal,
  fetched/applied zero, retained 8,502, remote saves/deletes false and outbox
  1 -> 1. This qualifies cold process restart plus read-side no-duplicate
  incremental behavior for the installed artifact. It does not yet qualify a
  locked-network reconnect or outbound replay after a new Pixel write.
- Startup first attempted native receipt replay before writer-owner preparation
  and logged one deferred warning. The later owner-preparation path awaited the
  replay and then logged `automatic writer ready`; no second warning followed.
  Preserve this ordering evidence and improve its diagnostics separately rather
  than treating the recovered first attempt as a duplicate-send failure.

### September 15 reply overflow, shared sync progress and native size diagnosis

- The failed attachment was reproduced in the actual ReplyBubble and
  AttachmentHolder widget tree: 58-pixel overflow at ordinary text scaling and
  106 at double scaling; ordinary message holders passed. The repair moves the
  100-pixel reply limit to already-downloaded media. Failed/pending prompts may
  grow, while the decoded-thumbnail test proves compact reply media remains.
- Profile progress now reports elapsed time and separate whole-run averages for
  newly fetched records and retained-row visits, frozen at completion and reset
  for a new run. It never derives a percentage from a configured cap. A mounted
  one-second status refresh recognizes another reader and re-enables resume
  after it finishes; page closure disposes that timer without canceling service
  work. Main status copy now shows downloaded/restored counts with detailed
  counters under Sync details.
- The developer catch-up action now enters the same prepared Profile flow.
  This removes its duplicate refresh/presentation path, exposes progress for
  developer starts and uses the no-upload-wake read method. The shared local
  ordering/list refresh has bounded 30-second waits. The Android background
  success path logs its actual classified outcome, matching the error path.
- Local qualification passed 70 Flutter tests across attachment layout,
  progress model, progress widgets, PCS preparation and production composition.
  The subsequent shorter card copy passed all eight widget tests. Initial test
  compilation caught an import appended below declarations; it was corrected
  before the passing run. Analysis reported no errors, five existing Profile
  warnings and 14 existing lint/deprecation infos. Existing unrelated lint
  cleanup was not included. The status card was rendered for visual review.
- Wired ADB disconnected; the discovered wireless endpoint reconnected. Its
  native log contained four failed attempts for one media asset after exact
  decryption and unique Ford-key-qualified selection. Each ended in MMCS with
  `io:InvalidData`. This is later than metadata/source selection. The local
  bounded destination can also emit that kind when bytes exceed the canonical
  size, so the current trace does not establish a malformed Apple response.
- Native candidate replaces only that writer's generic size-limit I/O error
  with a typed error. It maps to the existing SizeMismatch result and gives
  content-free maximum/written/incoming counts. An arbitrary I/O error string
  cannot impersonate the typed error. The byte cap, final integrity check and
  atomic cache admission remain intact. Formatting passed; its native tests
  await GCE and it is not installed.
- Muse child 01a0a5eb-40aa-7f63-8557-e59c97d7141b and Terra child
  01a0a5f5-68d8-7fb3-9d19-f1dd20c14b2c both failed before work with 429 and
  were closed. The repair task identified the actual cause as the local
  OpenCodex 2.55.0 root-task budget guard, not an upstream provider throttle.
  Its 2.56.0 upgrade is awaiting a request-free pause. No further child retry
  is authorized by this checkpoint before its explicit live notice.
- All local test/analysis handles are terminal; no GCE build was dispatched.
  Fresh inventories show zero GCE instances and zero registered runners.
  C: is 37.5 GiB free. No evidence, user data, transcript or rollback artifact
  was deleted. Supported transcript deletion is unavailable. Preserve this
  source candidate and installed `78d0f8cf2` while the proxy restarts.
- Final wireless preflight at the pause found another existing semantic reader
  active, coordinator owned, authentication ready and outbox settled. It was
  left running; a local proxy restart does not terminate the phone operation.
  Resume by reading its terminal state before starting any additional work.

### September 15 tooling recovered, no-paid-GCE policy and authenticated media extent

- OpenCodex repair reported 2.56.0 live. Muse child
  `01a0a60a-8c88-7192-a253-27fa723445e9` and Luna child
  `01a0a60a-ed15-7452-bc86-7ff7b429eaac` each ran their distinct shell marker,
  returned PowerShell 7.5.4 and exit 0. Parent inspected commandExecution
  evidence and reported it to repair task `01a0687b-43f0-7a22-999f-260c60ae3d42`.
- Source `ee9bf7c7e` was pushed to the fork. GCE runs 34999813050 (T2D-60/b),
  34999977302 (N2D-16/c), 35000254167 (N2D-8/a) failed to allocate VMs with
  ZONE_RESOURCE_POOL_EXHAUSTED. Each cleanup succeeded. Final cloud/runner
  inventories were empty. The user then reported exhausted free credits;
  do not start paid GCE without renewed approval.
- GitHub-hosted bridge 34999813864 passed 683 app Rust, 308 rustpush, 11
  remote Anisette and 40 protector cases, including both typed size-limit
  tests. Windows native-host 35000180863 succeeded. Duplicate feature-branch
  Build 34999813862 and bridge 34999813974 were canceled and verified terminal.
  The trusted-branch Build 34999813897 continues; it is not a new Canary.
- Stable capture of the 135,184,384-byte Pixel database was hash-verified before,
  after and against the transfer. Offline inspection copied it for ObjectBox,
  printed only counts, fixed classifications, sizes and timestamps, verified
  source unchanged, then removed only its scratch clone. The source capture
  is retained privately. The inspector initially compared two differently
  namespaced scope digests; corrected reconstruction now resolves all twelve
  sampled attempts to exactly one canonical row and source.
- The failed HEIC is declared 1,048,576 bytes, streaming/verified0. Native
  logs for the matching attempt report asset_bytes=2,302,773 after successful
  record decryption and unique Ford-key selection. The other three latest
  attempts completed at 52,525, 1,159,494 and 106,907 bytes, matching native
  descriptors. The canonical size comes directly from cm.tb, without a clamp.
  The old untyped InvalidData does not itself prove how many bytes were written.
- Parent rejected the proposal to permanently fail all size disagreement.
  New rustpush `c43760e` derives a typed native plaintext extent from selected,
  authenticated Ford chunk lengths. A no-network refusal test exercises the
  callback before any file data transfer. Parent fixed the FnMut binding,
  requested-order association and release of Ford buffers before streaming.
  No-Ford transfers retain the existing exact metadata size, and Asset.size
  never authorizes a larger body.
- App integration begins the bounded writer with metadata size, admits the
  native extent once before writing, requires complete exact bytes, and uses
  v3 cache/source binding for recovery. Dart keeps original metadata and stores
  completed native size via the existing verification-reference field, with
  replay/provenance checks. No entity schema migration or remote writes.
  Local qualification passed 80 cases across two targeted batches; focused
  analysis and sensitive-log scan pass. Native execution for this candidate
  remains pending; do not install or claim live repair from these tests.
- FaceTime review proved current log/export paths align and 75 offline cases
  pass. Historical missing logs do not establish whether diagnostics were
  enabled or installed; a verified current call trace remains required. Parent
  rejected speculative teardown and no new call was placed.
- Find My reviewers withdrew blanket defaults and the claim that Onitrack
  automatically obtains live People keys. Existing handler can discard a
  candidate 242/type10 shape, but real topic/framing remains unverified. A
  bounded observation design is under cross-review. No key requests, sharing
  changes, key imports or server writes were made.

### September 15 authenticated extent compiled, hosted packages ready

- Native 35005611468 exposed an untyped callback inference error. Rustpush
  `6ca98b8` and app `b9c567f89` add the explicit callback type. Windows native
  host 35006456632 passed. Bridge 35006453847 passed 685 app tests and 316/317
  rustpush tests; only a source-contract assertion expected the old reader
  method name. No body-verification test failed.
- Rustpush `5522fa0` corrects that assertion and retains the closed-reader,
  exact-index, singleton-length and no-authorize-get checks. App `1e2aa395d`
  adopts it; bridge 35008514692 passed 685 app, 317 rustpush, 11 Anisette and
  40 protector tests. Local packaging/control tests passed 16 cases.
- Candidate `710003e7b9feb8b74bf3cd795da22da3be0e56bb` also enables the removable
  Canary ADB controls in the existing Build workflow. Dispatching the dedicated
  unregistered canary workflow returned 404 and created no run. Existing Build
  35008622263 with canary_only=true succeeded, including signing, identity and
  native-library checks. Its artifact is 10413547986. This is packaging evidence,
  not a claim that the workflow ran the full Flutter/JVM qualification suite.
- Windows artifact 10413045788 from 35006456632 is source-bound to b9c567f89;
  import requires its exact clean source checkout. Both artifacts remain
  unimported/uninstalled at this checkpoint. Installed Pixel is still 78d0f8cf2.
  The next live check is the exact previously failed media object, followed by
  completed-byte, rendered-image and cache/restart verification.
- Six known native child handles no longer resolve after compaction. Closing
  the completed reviewer likewise returned not_found. The app independently
  shows the Find My observer task interrupted/notLoaded, with four unique
  uncommitted files preserved. Its dependency feature/allocation review is
  incomplete and none of that observer is integrated. The MMCS agent worktree
  is clean and retained for current qualification. Session deletion is not
  supported; no protected evidence or user data was deleted. C: 35.14 GiB free.
- No new GCE work was started. Both hosted qualification handles are terminal
  success. Do not rerun them merely because a prior observation was interrupted.

### September 15 installed media candidate and restart evidence

- Downloaded artifact 10413547986 matches GitHub digest
  `8fed78313129c6b5cf2a677aacfd37a74cde1a20db54d1a0d562e9d51d812505`.
  Extracted 452,934,107-byte APK is
  `8d87ec693bbbcbb9d31b0ab886e254cc2ef5c1a9253c3fc7acac9dc3233ad90b`.
  Java apksigner independently verifies v2/v3 and the established Canary
  certificate; package/version/native inventory and absent dotenv asset pass.
  Wired in-place install succeeded at 13:45 local. On-device APK hash matches;
  Alpha version and install/update timestamps remain unchanged.
- Operator error: a raw status-plus-install command did not branch on the
  second status. Background semantic sync had restarted, but installation
  continued. The parent disclosed the overlap immediately after detecting it.
  No forced lease reset, logout, reinstall, data clearing or credential repair
  followed. Fresh process preserved setup and regained authentication.
- New status temporarily had no semantic activity but an unexpired coordinator
  lease. A Muse source review found exact owner/generation protection and a
  five-minute TTL. At 20:51:12Z the live coordinator flag became false, with
  auth ready, settled outbox and semantic read available. This proves expiry
  recovery for this interruption, not every crash or in-flight write outcome.
- Stable 135,282,688-byte capture `device-evidence/20260915-restart-710003e`
  was hash-qualified before/after/transfer. Offline cloned inspection preserves
  the source and shows 700 chats, 11,841 messages, 2,413 attachments, outbox 3,
  no pending checkpoint batch/token. Two upload admissions appear in old-build
  logs at 20:45:30Z before installation; the older outbox-1 report is not the
  immediate pre-install baseline. Both lingering lease rows have 300-second
  duration. The known HEIC remains tempStreaming with metadata 1,048,576 and
  verified 0, awaiting an actual retry on the new build.
- Host-only assert-idle now fails on busy, unavailable or malformed state,
  with 24 offline cases. It is explicitly a snapshot rather than an atomic
  installation lease. The initial inspector run lacked process-local ObjectBox
  PATH and failed load; rerunning with the pinned ARM64 vendor DLL passed.
- Windows artifact 10413045788 matches GitHub digest
  `33bfbaa890720cb23d3ef15fcc7e573a170e940186799776d2b986dfb1e3c081`.
  Inner archive `fd42c97f55025eedb7eb11c7bbc22e8a6c5210f493d829366481c9edf6325b34`
  passed the three-file/ARM64/source/pilot/codec verifier. Exact source-only
  checkout `scratch/native-import-b9c567f-20260915` admitted import. The existing
  importer signed only the executable and app DLL; ObjectBox stayed byte-exact.
  Signed DLL SHA256 is
  `140ab5c25b39daca8263f60e2085433557311676d8e1885d17d74a0af49b56d7`.
  All 29 native attachment cache/extent tests passed on this local Windows host.
  No live Apple call was made by this Windows test.
- User was asked to open Gizelle's profile and retry one previously failed
  photo, without another history pull. No fresh media attempt is yet observed.
- Schrodinger and Kierkegaard were reviewed and closed through supported
  controls, then absent from the active native registry. Find My's five-file
  unique observer patch remains isolated/uncompiled and is not in the installed
  APK. No transcript deletion API exists; no sessions were removed.
- Host guard cases pass 24/24 and existing Canary-control cases pass 12/12;
  the extended offline inspector passes targeted analysis with no issues.
  The temporary screenshot of the Messages list was removed after inspection;
  no original image or app data was deleted. C: 34.08 GiB free. All started
  build/test handles are terminal; the next step awaits one user-selected photo
  attempt, not another build or full history pull.

### September 15 live HEIC repair and current-runtime Windows convergence

- User retried the failed HEIC on Pixel710003e7b and confirmed images rendered,
  then confirmed reopening worked. Native log at21:03:07Z binds one qualified
  Ford candidate and admits 2,302,773 authenticated bytes against unchanged
  1,048,576-byte metadata. Dart logs completion in5775ms. Stable capture
  `device-evidence/20260915-media-success-710003e` (135,294,976 bytes) has that
  size-mismatched record referenced, verifiedBytes2,302,773, one canonical owner
  and resolved source. Counts remain700 chats/11,841 messages/2,413 attachments/
  outbox3, and checkpoint sequences unchanged. No further download was logged
  through the reopen confirmation. No private photo was exported.
- Fresh offline ObjectBox production-store restore accepts this exact saved
  native-size proof and returns materializedBytes2,302,773. Eleven previously
  completed attachments also restore. The source capture is unchanged. The
  added diagnostic initially failed compile from wrong lexical placement; that
  placement was corrected and the real-copy test now passes. No product code
  or device state was changed by the diagnostic failure.
- Windows b9 session ee1e30dcf6a40a8530e048fffb93885b fetched/applied three new
  records, then a fresh process reached empty-terminal0/0. Outbox stayed24 and
  retained6252. The launcher correctly reported stable-repeat-unproven because
  it requires two consecutive empty reads. Subsequent session
  5cc09831638901f97a8aba4c22c4b9da passed both empty-terminal fresh-process reads
  with0/0, unchanged outbox24 and retained6252. Owned processes stopped and raw
  stdout/stderr were removed. Remote writes remained disabled.
- Exact b9 Windows checkout needed its pinned telephony_plus submodule and
  offline pub dependencies. Pub generated seven platform registrant files;
  those are generated output, not intended product changes. No native build ran.
- Independent Muse review accepted the bounded Find My observer for compile
  qualification only. Its five source paths were unchanged by advancing the
  media baseline to5522fa0. Reviewed rustpush bd69aeac6 is pushed to the fork;
  isolated app qualification85942edcb points to it. GitHub-hosted bridge
  35024579387 is running. It is not merged into the active CloudKit candidate,
  not in the installed APK, and not proof that People locations work. Hume was
  reviewed and closed. No new GCE or APK job was dispatched.

### September 15 Profile entry, mutation lock and group-history comparison

- Profile candidate `1e534e48c` is committed locally. Focused suites passed:
  101 combined cases, then 23 widget/release cases including the final header
  adjustment. These overlap and must not be added as unique tests. Normal
  Profile read preparation no longer needs Developer Settings; public writer
  rollout and device UX are still open. No replacement APK was installed.
- Qualified failed-HEIC materialization and Windows b9 convergence remain valid.
  Find My observer qualification `35031241619` passed after a test-only partial
  move/borrow repair. The observer is not integrated into CloudKit source or
  installed on Pixel and is not a functional location fix.
- User edit at 23:15:59Z and unsend at 23:16:37/42Z failed in
  `_ProcessIsolateReservation.acquire`, before backend dispatch. Both durable
  leases were expired during the later audit, yet the process-local name stayed
  occupied. A real local Flutter isolate-exit probe reports ownerStopped=true,
  mappingRetained=true, successorAdmitted=false, nativeOperationsStarted=0.
  Engine-disposal paths ignore protected CloudKit work. Exact causality on the
  phone still requires lifecycle evidence; a timeout cannot authorize takeover.
- A stable 135,319,552-byte Canary retry capture has 701 chats, 11,887 messages,
  2,414 attachments and nine outbox rows. Eight are confirmed and one remains
  unknown outcome. The sole historical claimed unsend predates these attempts.
  The earlier changing-during-transfer copy remains explicitly unqualified.
- Alpha's exact named-group copy contains 27 message GUIDs, none cloud-synced or
  message-record-mapped. Alpha legacy sync is disabled. Neither qualified Canary
  nor Windows copy contains those GUIDs. This is evidence for missing upload,
  not a remote-absence claim. Canary separately contains canonical group row695
  with zero messages and live row701 with 13 messages; exact alias overlap and
  guid-only live selectors motivate a narrow routing repair, not blind merging.
- App/native disconnect logs were saved at 17:02:57 PDT. At 17:14 the ADB device
  list was empty and no active client transfer/install existed. All current
  agents confirmed no phone dependency; the user was told safe to disconnect.
- Agent hygiene: reviewed Profile/MMCS/Find My work was preserved in Git refs
  before five clean worktrees were removed. Manifest
  `build-evidence/agent-cleanup-20260915-profile/manifest.json` records
  406,196,141 logical bytes. No transcript deletion API is available. Current
  Darwin UI patch and Heisenberg engine-exit patch remain uncommitted and
  protected pending parent integration; Hypatia's routing review is retained.

### September 15 offline routing and UI integration checkpoint

- Parent integrated the four reviewed mutation-UI files, corrected pre-first-
  build dialog cleanup, and added exact-route/next-dialog regression coverage.
  Failures retain the edit draft and report unconfirmed outcome rather than
  implying that dispatch could not have happened. No retry or backend bypass.
- Live chat selection now consults a unique exact CloudKit alias after the
  established guid/guidRefs path and before participant fallback. Existing
  direct routing wins; SMS/stub invocation cannot use the new cloud fallback.
  Existing split rows are not merged or reparented. Six new database cases,
  20 existing cloud identity cases, and ten mutation UI cases pass together.
  The first new test expected empty guidRefs, but the Chat constructor seeds
  its own GUID; the corrected fixture now asserts that unchanged value.
  Targeted analysis of new helper/tests and chat.dart reports no issues.
- The exact three-profile comparison was rerun: 27 Alpha GUIDs are absent
  from both Canary and Windows, unchanged source hashes, zero network calls.
  The two Canary alias-sharing rows remain separate, preserving all 13 local
  messages while the historical upload gap is investigated.
- Parent rejected stale-base FaceTime timeout and Find My empty-handle patches
  because current main already contains those repairs. Workers were redirected
  to current native/tester protocol boundaries. No duplicate fixes integrated.
- Parent rejected the first engine-exit proposal because super.onDestroy still
  permitted FlutterFragment to kill the owning isolate. Pinned Flutter source
  proves an Activity-only shouldDestroyEngineWithHost override does not reach
  the new-engine builder. The revised candidate must own native destruction,
  not merely wait on Dart futures or clear a stale name by timeout.


### September 15 historical qualification rows moved from treemap

Historical point-in-time claims below are preserved verbatim except for relative
link adjustment. They do not supersede the current treemap checkpoint.

### Qualification history and retained evidence

| Item | Current evidence |
| --- | --- |
| Latest CI-qualified APK | Exact source `78d0f8cf2e5e0d49560766c79644f4ecec869a4b`; [GCE 34983806715](https://github.com/Xare123/openbubbles-app/actions/runs/34983806715) passed the full Dart and Rust suites, automatic-writer checks, rustpush production tests, the Cloud Sync protector harness, Android JVM tests, package/native verification, GitHub-hosted signing and cleanup. Signed artifact 10404276881 downloaded as 452,938,275-byte `app-canary-debug.apk`, SHA256 `6707AE4BD99F418406DDCCCE25AD339FDF54078D64BE4FF93804D471F3C66DB4`. Independent local `apksig` verification reports v2/v3 valid, zero errors and certificate SHA256 `0ea17c1b67581ca79660d33db45af0a36b71ea36a4cbafec5293d3ae80570d79`; `aapt2` verifies package `com.bluebubbles.messaging.cloudkitcanary`, version 1.15.0 (20002227), and all four required ARM64 native libraries are present. Independent inventories show no GCE instance or matching self-hosted runner after cleanup. |
| Last observed Pixel | Signed `710003e7b` is now installed in place as Canary. Downloaded and device APK SHA256 both equal `8d87ec693bbbcbb9d31b0ab886e254cc2ef5c1a9253c3fc7acac9dc3233ad90b`; v2/v3 signature and stable certificate independently pass. All four required ARM64 libraries are present and no dotenv asset is packaged. Alpha version/install/update timestamps are unchanged. The install unintentionally overlapped a background read because the host printed but did not enforce its second busy check. The new process retained registration/chats and recovered the old five-minute coordinator lease by expiry at 20:51Z without reset or lease edits. Status is authenticated/idle/settled. The exact failed-photo retry and a new terminal read remain pending. |
| Semantic-pull regression and repair | The 10d Pixel run safely aborted before pass 1 with `cloud_sync_protocol_evidence_event_type_invalid`: production emitted valid `fetchStarted` and `inboxApplyStarted` events that the fixed evidence vocabulary omitted. Exact source `0feaa063a` repaired the vocabulary and is an ancestor of the current `78d0f8cf2` candidate. The current full qualification passed the regression coverage, but Pixel live proof remains pending. |
| Recent-first | `TEST-PROVEN` on exact source `78d0f8cf2`: a live read-only Windows wire probe proves Apple returns a bounded newest-first page for a fresh no-token stream, and the product now durably binds direction before request one. Fresh exact Chats, Messages and Attachments streams use newest-first; Chat1 and every existing cursor remain forward. Direction is carried through each continuation, restart, reset and journal CAS. GCE app-Rust 34982392496 passed 682/682 tests; full GCE 34983806715 passed every selected suite, packaging, signing and cleanup. Pixel lifecycle proof remains open. |
| Windows writes | `LIVE-PROVEN` for a fresh direct single-part chain on exact source `07e58fd0b`. Parent-35 sent with exact readback, edit-36 and unsend-37 each submitted and confirmed one CloudKit update, and a new-process unsend replay submitted zero IDS/CloudKit work. The post-run store has exactly three additional confirmed outbox operations, both new mutations are terminal, and the retained database was unchanged by the metadata-only audit. Evidence: `build-evidence/windows-chain-20260915-07e58fd0`. Pixel, groups, independent recipient UI and persistent registration health remain open. |
| Outbound lease integrity | A content-free inspector on an exact temporary copy of the retained Windows profile found 24/24 outbox rows confirmed, three still-required protected mutation leases present, all three source envelopes bound to their leases, zero missing required outbound leases, zero duplicate/unmatched mutation claims, and correct lease release after the one terminal protected send and one terminal attachment upload. Writer authority remained stable at epoch 18. The original 48,805-file profile snapshot was unchanged. This is restart-state integrity evidence, not a new Apple submission. |
| Release state | Full production is not established. Remaining gates below apply. |
| Logging repair | Logger lifetime and explicit Find My target are qualified in native 3496034e3. Awaiting `doFirstTimeInit` in the Windows hosts fixes startup ordering. Native Find My init/refresh diagnostics now show absent `locations`, not a coordinate-join failure. |
| Find My live boundary | Exact retained Windows launch `1bed3346c9374c3b81f402075da59746` used the signed `7d38f1dd8` runtime and completed fresh People and Devices service reads. People returned one uniquely selected row but no native location; the service marked that row opted out of sharing and supplied no coordinate or locate-in-progress signal. Devices returned zero rows. Items were deliberately not invoked because their initialization side effects are not yet reviewed. The UI is not discarding coordinates in this capture; the native response contains none. Commit `d13d88797` repairs test provenance and makes the offline qualifier accept only the exact verified successful launcher envelope; 54 qualifier, 11 preflight, launcher and Flutter contract tests pass. |
| Current native qualification | Windows 34779665447 passed fccca0bb5 / pilot 5fd8d03fe: 151 selected Rust tests, 658 Dart tests, 51 packaged-DLL codec cases. Parent verified 53 source inputs/12 logs/three ARM64 binaries; signed DLL `501f40e89d6268d52cd7e678a21b669d8952ca18c0421fba31ed1d0b2bb90e3f`. Local 51 codec and 24 harness tests passed; later date-shape harness has 25 passing tests. App Control remains enabled; vendor ObjectBox unchanged. |
| Next integration | The exact-source foreground pull, bounded Android background wake and controlled cold-restart incremental read are terminal with Apple cursors drained, authentication ready, outbox 1 -> 1 and remote writes disabled. Next qualify profile Regular/Turbo status, cancellation and lock/reconnect. If registration remains healthy, run one authorized ordinary-composer send, exact CloudKit readback, restart/no-duplicate replay and representative media/document checks on this same installed hash. |
| Current source changes | Installed candidate `710003e7b9feb8b74bf3cd795da22da3be0e56bb` includes reply overflow/shared progress, authenticated media-body extent and removable Canary ADB controls. Rustpush is `5522fa0ced1c1fe7ed70262ac230261889ca06c5`. GitHub bridge 35008514692 passed 685 app, 317 rustpush, 11 Anisette and 40 protector tests; 80 targeted Flutter and 16 packaging/control cases pass locally. Build 35008622263 successfully packaged/signed the independently verified Canary artifact 10413547986. This workflow did not run the full Flutter/JVM suite. Windows 35006456632 artifact 10413045788 is independently verified/imported against exact `b9c567f89`; 29 attachment tests passed from that signed native executable on the local PC. This is native cache/extent evidence, not a live Apple download. |
| Latest full Canary qualification | GCE 34983806715 completed successfully in 33m02s on exact source `78d0f8cf2`: every selected suite passed, the producer and signed APK artifacts were uploaded, Android JVM tests passed, GitHub-hosted signing passed, and cleanup deleted the ephemeral runner. Independent post-run inventories found zero GCE instances and no matching self-hosted runner registration. This establishes build/test/signing integrity, not Pixel lifecycle or end-user behavior. |
| Current artifact boundary | Installed signed `710003e7b` is retained at project-root `build-evidence/github-canary-710003e-35008622263/extracted/app-canary-debug.apk`; previous `78d0f8cf2` is retained as rollback evidence, not the current installation. Preserve app data and retained database. No clean install, data clear, checkpoint reset or Alpha change is authorized by this qualification. |
| Current qualified runtime | Source `4e7121a18e8c011ae5472831111af86a61280178`, pilot 5fd8d03fe: Windows 34782347926 passed 153 selected native / 658 Dart / 51 DLL-codec tests. Parent verified 53 inputs/12 logs/three ARM64 PEs, separately signed DLL `80f97298fad435f53b30cd4dc2b0479e3f350fb47136e644673b3a052d08b3c8`, and passed 51 local codec + 25 harness tests. GCE 34782416330 passed all 631 Rust tests and completed cleanup. No active build or new APK. |
| Fast Windows loop | Current Dart plus the verified native DLL opens the retained projection in 8.65 seconds. The stale Windows relay ticket was updated to the Pixel's working ticket after proving the same physical relay and preserving Windows installation IDs/keys. Fresh exact-source session `9fd22af4898c86559573004e9c07d21d` on September 15 ran two independent 7d38 processes to a stable terminal result: fetched/applied 0/0, retained 6,252, outbox 24 -> 24, all zones empty-terminal, zero stderr, remote writes disabled and owned-process cleanup confirmed. The initial attempt correctly rejected an older 07e native bundle as byte-incompatible before profile access. |
| Current merge repair | Real native-source/copy qualification passed the bounded production recovery and normal applier, preserving local history. Live Windows report `obcs2-semantic-1789278811033254.json` applied two pending messages; fresh-process repeat `1789278895014946` fetched/applied zero, with no conflict. Both observed empty terminal reads in all zones and kept outbox 15 -> 15 with remote writes disabled. Full native-crate qualification remains. |
| Current read result | Qualified reply replay added 34 distinct messages (32 replies), then a 5m5s drain added 250 distinct messages (246 replies) and applied 11 attachment records. Total 284 new messages, 278 replies. Outbox stayed 21; remote saves/deletes off. Drain proved remote-empty streams, but local projection remains partial with 6353 retained records. Private evidence: windows-multipart-20260913 and windows-multipart-drain-20260913 under build-evidence. New-text copies contain four replacement characters across both batches; full visual QA remains open. |
| Actual extension boundary | The 37-record inspection preserved durable state. A formerly ambiguous reply became ready with body/history intact. Five type-2 failures are 4.9-11.9 KiB raw-data live-layout archives; two type-3 records remain unsupported. Other preflight limit failures have total wire sizes about 19-200 KiB, below the 1 MiB input cap. Diagnose the exact internal bound, not an assumed oversized file. |
| Retained diagnosis | A non-projecting Windows sample inspected 37 current-generation retained saves with unchanged checkpoints, outbox and sampled rows. Seven sampled Message dependencies are unsupported extension payloads; all eight sampled Attachment dependencies lack a local parent, six otherwise materializable. This deliberate sample does not establish prevalence or parent causality. Native fixed-field diagnostics are prepared for the next Windows DLL; no parser admission was loosened. |
| Additional retained windows | Read-only probe offsets 128/256 preserve durable state and expose distinct records. Offset 256 finds extension strings 50,507-80,485 bytes against the 16,384-byte string limit, not the 1 MiB archive cap. Which field is large remains unproved. Eight sampled malformed Attachment records are native-ready but fail Dart date conversion at rust_cloud_semantic_decoder.dart:1239. Diagnose units/field semantics before changing bounds or dropping dates. Probe-only Dart changes are not part of the qualified native source. |
| Latest read/shape proof | Run-once `1789332457042301` added one row; 3m15s drain remote report `1789332557626821` plus local sweep `1789332723873549` added 13 distinct rows and one Attachment record. Retained total 6338; remote streams empty; outbox 21 -> 21. All 14 new rows have placeholder-only base text and separate extension display text/icon metadata; full rendering is not proved. Date probe shows all eight failed attachments have only createdAt populated, outside Dart range and matching the Apple-ns scale. Source write/cutoff paths establish the unit, not magnitude alone. |
| Date repair live proof / next boundary | All eight exact pre-repair record HMACs now decode with valid dates and one existing parent each. Normal 3m28s drain applied 86 Attachment records; retained total 6252, outbox 21 -> 21, remote streams empty. Copy audit proves all eight sampled sources transitioned retained -> applied with unchanged source identity/etag, bound canonical rows/parents, and successful production download-source resolution. Media bytes were not downloaded. Reports `1789335099312100` (remote) / `1789335274615314` (local sweep). Next: correlate missing Message chat references with cached protected Chat evidence; do not synthesize participants or treat missing as deleted. |
| Parent coverage result | Complete current-generation cached Chat scan: 794 physical records, 700 decoded, 81 tombstones and 13 out-of-scope. Eight sampled missing routes match neither current native identities nor legacy normalization; four applied controls correctly find proven parents. Five samples are bare UUIDs; three are explicit direct phone/email routes. No alias/index regression is established by these samples, and no remote-absence/deletion inference is made. |
| Protected Chat1 discovery proof | Separate opt-in, permit-bound Chat1 discovery is compiled and live-qualified for source c6091ddf92e13c902fc61bd911606def5ac373a7. A Windows test-host read fetched exactly one capped page: 50 distinct saves, generation 1, sequence 0 -> 50, protected token present, 0 rejected and no canonical/outbox mutation. A subsequent mutex-held cache-only inspection made no network request and found 50 pending raw rows, all with protected identity/raw references and payload digests, no duplicates, tombstones or system references. All 50 remain deliberately quarantined as `unsupportedRecordType`/`malformedRecord`; semantic admission is still forbidden. |
| Matching bindings/runtime | All seven generated bridge files are paired with the signed c6091ddf Windows DLL, SHA256 `9B0B7899BBD31D1EE6C6A15482208055C8C9FED52CF858761CDACD622A0C0C79`, signer thumbprint `8240557965890665F3B49E5FEC83D511CA4F2C9D`. Windows 34789713162 passed 666 Dart tests plus selected native/discovery contracts; full GCE Canary 34789714678 passed every actual selected suite and regenerated bindings byte-for-byte. Vendor ObjectBox SHA256 remains `9C8583C4015AB9E4CE2ED3D2D581811FA059E03BB528CB8C8387ADCDFDA8D8A5`. |
| Qualification cleanup | Both 34789713162 and 34789714678 completed successfully. GCE cleanup and independent inventory found no remaining VM or runner registration; no production credentials were used or exposed. The current test-host caller and cache inventory are local uncommitted follow-up changes, covered by 178 focused tests with one intentional live skip and a successful live cache-only execution. |
| Cached Chat1 correlation result | Exact source `97f63b5f5d8e4d89aa5b0a6deefb85060999f9e7` passed Windows 34797113685 and full GCE Canary 34797113773. The separately signed ARM64 DLL SHA256 is `5B22D174FC50A680DDCE0A64CECD3018F4E551C387B9237600426E84A94E5B12`. A mutex-held, cache-only live run verified eight distinct missing-message routes and 50 Chat1 records without network, content exposure or durable mutation. Exact record-name correlation produced zero pairs. This falsifies only the record-name-equals-route hypothesis; it does not establish that Chat1 is irrelevant or remotely absent. |
| Encrypted Chat1 routing-field result | Exact source `19022ea7bf6d4ea1fe32a60c1b5797eeccc15491` passed Windows 34801034688 and full GCE Canary 34801034710. The exact signed ARM64 DLL SHA256 is `7D768E4686E62BF21E595C8BAD796A7F3EFE49454A9F42B1F6484A2FDBE886B6`. A mutex-held live diagnostic made one PCS lookup, decoded all 50 first-page `chatEncryptedv2` records and their `cid`, `gid`, `ogid` and `guid` fields without exposing content or mutating durable state. It found zero direct or semantic route pairs for the eight targets. This is conclusive only for the first capped page. |
| Bounded paged Chat1 result | Exact source and bindings `a951e1251c658e81e9ef6533e5b3e8874b28bae7` passed Windows 34804132572 and full GCE Canary 34804133857 through pilot `629df1f5d70b2c63c51212b362b05d569df2c3d4`; signing and teardown passed. The verified copied ARM64 DLL was separately signed, SHA256 `9220F65671F4DBF385BF065C47D35139904DA9FA6BC3A748697BF7A3801832AA`. A mutex-held live walk reached terminal state after four pages / 167 changes: 165 valid `chatEncryptedv2` records, two tombstones, no other records or decode failures, and zero exact or raw semantic matches for all eight target routes. No content crossed the bridge and durable state remained unchanged. This closes the entire current Chat1-zone raw-equality hypothesis, not Chat1 relevance or remote existence. |
| Normalized comparison result | Exact source `a2f72eff9edce5cc377ca62c472e5f8bc3aa5c4d` passed full GCE 34807869942 and Windows fast loop 34807865131. Its mutex-held live retry reached the same terminal four-page / 167-change Chat1 state and found zero normalized `cid`, `gid`, `ogid` or `guid` matches for the eight routes, with no record/field decode failures, content exposure or durable mutation. This closes only those equality families for the current zone. |
| Parent-field live result / current blocker | Exact source and bindings `cb5e81410f135f969fc15cffee957ad79ab63abd` passed Windows fast loop 34843955881. Artifact SHA256 `DCEFCAE4A829914D5715C6324F21489DBE53EFE7605B3C57E1A2C2C2E7B8B88B`; the imported ARM64 runtime was signature-checked before launch. Live run `61909185c0e0f5736b8e5c44569236bf` reached terminal Chat1 state in four pages / 167 changes: 165 Chat records and two tombstones, with account binding, network read, no content exposure and unchanged durable state. All 165 records failed only two diagnostic assumptions: 18 encrypted empty `lah` values and 147 `ptcpts` lists whose outer false flag is omitted. The production preflight already accepts the omitted flag, and canonical conversion treats empty `lah` as non-authoritative. Repair those two diagnostic-only shape assumptions without loosening other route fields or admission. |
| Current compatibility candidate | `908ccc0040ed4bb60d2611db945e0b304eff639c` accepts encrypted empty `lah` as absent for that field only and mirrors the production participant-flag contract: outer rejects only explicit true, entries reject only explicit false. All type, payload, key, decrypt, cap, plist and participant validation remains. GCE app-Rust 34849044238 passed the full Rust library suite and coherent bridge generation/compilation; its only failing gate was the expected one-line generated private-helper comment drift, now imported exactly. Cleanup passed, zero GCE instances remain, and the repository self-hosted runner inventory is empty. |
| Exact Windows qualification | Windows ARM64 run 34849043947 passed in 23m57s for exact source `908ccc004` and pilot `629df1f5d70b2c63c51212b362b05d569df2c3d4`: 666 Dart tests, 51 packaged native codec tests, launcher contracts and ARM64/provenance checks. Artifact 10351037466 was hash-verified (`6647710ec763084e741541a7cfd9f6a2a272d1395bc7afcf698280a0f96498d6`), imported into the clean detached `chat1-live-a93671` runtime and locally signature-checked. The receipt binds the installed app/DLL to the same source and sidecar; pinned ObjectBox bytes remained unchanged. |
| Repaired Chat1 live result / current blocker | Live launch `dd0cf181df5b3751342e8a2f78dc07ad` reached terminal state in four pages / 167 changes: 165 decoded Chat records, two tombstones, zero record or route-field failures, no content exposure and unchanged durable state. All raw/normalized route, group and legacy equality families remained zero. The only positive relationship was sender membership in Chat1 participant lists: 76 normalized pairs, three of five sender targets, spanning 31 Chat records. This proves a useful edge but is many-to-many and cannot authorize admission. Next measure exact participant-set, route style, service and temporal/ownership corroboration, then require one uniquely proven parent or retain the message. |
| Standalone parent-correlation boundary | Windows ARM64 run 34873675005 qualified exact source `df8c75bceed50622ddbb1f7cd3f717854034c9e1`; its three-file native-test-host bundle passed provenance, ARM64, ObjectBox and 51-codec verification. GCE 34873674805 passed all 673 Rust tests and clean teardown; its overall failure was only the exact one-line generated private-helper comment drift, now imported. Two standalone live attempts advanced past protected-manifest identity validation but failed before Chat1 fetch at `chat1_standalone_read_authentication_failed`; both preserved all 212 Cloud Sync files and 155,026,542 bytes byte-for-byte. The test host had restored state but omitted production's explicit read-authentication refresh before writer pause. Candidate `fdd2beb595a4599c8783fbc8be5ed3e286415e69` adds refresh-before-pause ordering, bounded safe failure markers and a cross-platform source-order regression test. Windows 34877349884 and GCE 34877349816 must pass before another live attempt. |
| Exact relationship-probe qualification | Source `b39c785b36579586843616cbbac5bd639f4fb85f` passed GCE app-Rust 34889517605 with reproducible bindings, the full selected Rust suite and clean ephemeral-runner teardown; bindings workflow 34889470902 also passed Rust, rustpush, Anisette and protector-harness checks. Windows ARM64 run 34889520601 passed in 24m53s and produced artifact 10366986676, archive digest `805fe7e50bd858f1a56c2812f4cf4f3aa71af245bd8ae87d864dc76080563da3`. Parent independently verified its three ARM64 binaries, source/pilot provenance and pinned ObjectBox library, then signed only the executable and OpenBubbles DLL with the existing local development certificate. |
| Exact b39 live result | The standalone relationship probe authenticated, scanned 2,048 protected Message anchors, decoded 1,622, skipped 426 safely, and reached the terminal Chat1 page after four pages / 167 changes: 165 Chat records plus two tombstones. It exposed no plaintext or raw identifier and left the 212-file, 155,026,542-byte profile byte-for-byte unchanged. Five target messages had zero Chat1 candidates. Three incoming bare-route messages each retained the same two candidates (Chat1 indexes 79 and 164); sender membership, service/style and `dcId`-to-`lah` corroborated both equally, while route/group/last-seen relationships matched neither. A second no-build analysis proved Chat1 participants exclude the local `dcId`: only one remote participant was observed for either candidate, so the two-versus-three-member difference cannot safely select a parent. |
| Timestamp epoch compatibility candidate | Product source `08ee7bf8c719ee629ac0a1e3b4f963e656edc5ad` converts native CloudKit `Date.time` from Apple-reference seconds to Unix milliseconds at both native decode paths and removes the b39 diagnostic's compensating double conversion. ObjectBox property 28 is nullable: null preserves an actually absent server timestamp, an unversioned nonzero row remains a legacy Apple-epoch value, explicit format 0 preserves the real Apple epoch at zero, and format 1 preserves Unix zero and negative values. Unknown formats and overflow fail closed. The attachment cache and standalone Chat1 input manifests are versioned; Chat1 schema v2 names `server_modified_at_format: unix_epoch_milliseconds`, so a v1 Apple-epoch export cannot be silently reinterpreted. Focused local qualification passed 295 Flutter tests, 42 Rust correlation tests, Rust standalone-host compilation, focused analysis with no errors, and PowerShell parser validation. Rust 34906185049 and Windows 34906185093 passed on the product source. Build 34906185018 and Windows native-test-host 34906247493 each exposed the same test-fixture mismatch: a synthesized inbox row omitted the newly meaningful format property and therefore represented explicit Apple-epoch zero instead of an absent timestamp. Test-only source `9712487afc9c418d2fe04b5b84f3f0a28c8c7dc9` marks that fixture null without loosening production behavior. Windows 34907920177, Build 34907920178, full Canary GCE 34908830021 and read-only Windows native-test-host 34908829840 all completed successfully against 9712487af. Pixel upgrade qualification remains. |

| Retired-receipt recovery repair | Commits `306d00700` and `ea7560b83` distinguish terminal readback receipts from unfinished mutation authority. Fetch recovery may tolerate an absent retired local-send/upload receipt, but every write still performs a fresh strict recovery. Local-send retirement now recomputes the exact operation/scope/payload/generation/UUID binding. The focused 172-test suite and targeted analysis pass. |
| Latest ordinary Windows proof | The dual-provenance launcher ran current Dart `ea7560b83` against qualified native `9712487af` without rebuilding. Session `2c544457b08a06406aabcfa8fc5cb10a` completed two fresh stable read-only passes: fetched/applied 0/0, retained 94 Chats + 5,046 Messages + 1,112 Attachments, outbox 21 -> 21, all zones terminal, no content exposed and remote saves/deletes disabled. This is `LIVE-PROVEN` for Windows read recovery, not Android or write proof. |
| Exact receipt-reconstruction repair | `LIVE-PROVEN` on Windows at `bbfa149f1`. Build 34923170226, GCE 34923191959 and Windows fast loop 34923533854 all passed. The verified imported harness reconstructed exactly three committed protection receipts. Reopening the state-1 edit returned `cloud_sync_windows_mutation_send_unconfirmed_no_retry`, changed no mutation state and issued no resend. |
| Historical mutation disposition | The unfinished state-1 edit, state-3 edit and state-3 unsend were written at authority epoch 2; current stable V2 authority is epoch 18 after the fresh qualification chain. The state-3 replay stopped before network I/O at `cloud_sync_local_mutation_owner_changed`. Preserve these rows as unresolved evidence. Never rebind stale intent across epochs merely to complete a test; a future reconciler may perform readback only. |
| Fresh same-epoch chain gate | `LIVE-PROVEN` on Windows. Commit `07e58fd0b` passed 18 focused tests and Windows fast-loop run 34926960736 in 25m9s. Artifact 10380667192 was independently verified as 78 files / 335,925,603 bytes with exact source/pilot provenance, 51 native codec cases and archive SHA256 `ea87e2931a58cf6f84093478ca6a41c9bc8734170be746d8c7b81a80d8cd7a39`, then imported and locally signed through the rollback-protected importer. Parent-35, edit-36 and unsend-37 completed; edit and unsend each submitted/confirmed one update. A fresh-process unsend replay was reconciliation-only with zero submissions. Outbox moved 21 -> 24 and all 24 rows are confirmed; terminal mutations moved 6 -> 8. Final unsend projection, source binding and receipt markers pass. Independent recipient UI and Pixel lifecycle remain required. |
| Carrier backlog correction | `LIVE-PROVEN` on the isolated Windows profile for exact source `7d38f1dd8`. The first exhaustive read-only drain reclassified 573 retained Message saves from stale `malformedRecord` to typed carrier `outOfScopeService`: 531 newly recognized empty-identity SMS records plus 42 records already typed as carrier by the prior decoder but carrying an older malformed label. All 68 rows outside the exact eligible prior-category fence remained unchanged. A fresh-process repeat emitted no further transition and preserved 94 Chats, 5,046 Messages, 1,112 Attachments and outbox 24. Both runs fetched/applied 0/0 and disabled remote writes. Remaining blocking saves are 786 Messages and 1,011 Attachments. |

Prior tables and obsolete next steps were preserved verbatim in the September 12
consolidation entry of the [investigation log](../../cloud_sync_v2/history/CLOUD_SYNC_V2_INVESTIGATION_LOG_FROM_2026-09-07.md).
Historical tests do not establish current-device behavior.

### September 15 detailed evidence moved from treemap

### September 15 newest-first wire proof

- The exact signed `07e58fd0b1cd-local-write` Windows harness ran the bounded
  `probe-message-feed` operation from a provenance-verified 78-file archive.
  The probe implementation is unchanged between `07e58fd0b` and candidate
  `7d38f1dd8`, and the operation pauses the native writer, adopts no token and
  returns counts and token properties only.
- With the current continuation token, ordinary and `newest_first=true` reads
  each returned one terminal change and zero target matches. This shows that
  changing direction on an established cursor does not create a recent-history
  bootstrap.
- With no continuation token and `newest_first=true`, both default self-filter
  behavior and explicit own-device inclusion returned the bounded maximum of
  200 changes, a continuation token, a nonterminal status and one exact target
  match. Apple therefore exposes the recent-first traversal needed for a fresh
  bootstrap; own-device inclusion did not change this target result.
- The probe asserted `checkpoint_unchanged=true` after rolling back every page
  lease. The older pre-write checkpoint reference returned
  `invalidCheckpoint`, so it is not evidence for replaying an expired historic
  cursor and is not used for the bootstrap conclusion.
- Standard launcher reuse now requires an exact binary-and-configuration
  receipt for this live probe and binds terminal status to the expected build
  identifier. A newer report from a different executable can no longer qualify
  a stale `-SkipBuild -MessageFeedProbe` bundle.
- Evidence is retained under
  `build-evidence/windows-feed-probe-20260915-07e58fd0/`. Exact source
  `78d0f8cf2` now persists fresh-stream direction atomically before request one
  and preserves it through continuation, restart, reset and journal commit.
  Remaining work is live Pixel qualification of multi-page catch-up,
  incremental follow-up, cancellation and crash recovery while proving existing
  cursor direction remains untouched.

### September 15 durable newest-first implementation

- `CloudSyncFetchDirection` has two closed values: `forward` and `newestFirst`.
  ObjectBox property ID `24:4160469815668187907` stores that choice on the
  checkpoint; unknown values fail closed.
- A fresh exact semantic V2 checkpoint for Chats, Messages or Attachments binds
  `newestFirst`. Any prior read evidence, including a token, pending token,
  sequence or journal row, binds an unclassified legacy checkpoint to `forward`.
  Outbound-only mutation history does not forfeit a fresh newest-first bootstrap.
  Chat1 remains forward.
- The engine supplies the persisted direction on every page and compares it
  again inside the write transaction that journals the batch. Reset preserves
  the bound direction. Native newest-first transport requires the writer pause;
  the legacy raw transport rejects it.
- Focused Dart qualification passed 274 tests, including eight direction tests,
  140 engine tests and 105 native-transport tests. GCE app-Rust run 34982392496
  regenerated and checked the bridge, then passed all 682 library tests and the
  aggregate gate on exact source `78d0f8cf2`; cleanup removed the runner. Full
  GCE run 34983806715 then passed every selected Dart/Rust/protector suite,
  automatic-upload qualification, APK/native identity checks, Android JVM
  tests, GitHub-hosted signing and cleanup on the same exact source. The signed
  APK is independently verified locally. This is source/test/build evidence,
  not a claim of completed Pixel lifecycle behavior.

### September 15 exact Pixel installation and terminal retained projection

- The signed GCE artifact for exact source `78d0f8cf2` was installed in place on
  Canary. Post-install verification matched package
  `com.bluebubbles.messaging.cloudkitcanary`, version 1.15.0 (20002227) and the
  expected signing certificate. Registration, chats and retained CloudKit state
  survived; Alpha was not touched.
- The UI-started semantic pull reached a terminal report at 09:18 local in
  `obcs2-semantic-1789489102934586.json`: two passes, remote drained, fetched
  zero, applied 203, retained 8,502, deferred/quarantined zero and outbox
  1 -> 1. Remote saves and deletes remained disabled, authentication remained
  ready and the coordinator released cleanly.
- The terminal local work applied 192 Message and 11 Attachment rows. Retained
  state is not one undifferentiated failure: the 94 Chat rows include 13 typed
  out-of-scope saves and 81 tombstones, while Messages retain 7,177 rows with
  718 blocking saves and Attachments retain 1,231 rows with 1,116 blocking
  saves. Those unresolved records remain explicit and are not silently deleted.
- The first Android background wake ended with `outcome=retry` at 09:23 after a
  transient HTTP-server/timeout boundary. WorkManager retried without changing
  registration or the outbox. Report `obcs2-semantic-1789489571217410.json`
  then finished at 09:26 with all three zones empty-terminal, fetched/applied
  zero, the same 8,502 retained rows and outbox 1 -> 1. The policy classifies
  that safe terminal read as complete. The success return currently lacks an
  explicit `Android background outcome=complete` log, which is an observability
  gap rather than evidence of another retry loop.
- Current logs show no authentication or CloudKit-fatal error. A failed
  attachment bubble separately overflowed vertically while materialization
  reported `cloud_attachment_source_invalid`; nearby attachments downloaded.
  The responsive-layout defect and the underlying source-data failure must be
  tested and repaired independently from CloudKit cursor qualification.
- Two actionable UI exceptions occurred without stopping the engine: a missing
  Message handle was force-unwrapped in `find_my.dart`, followed by an ancestor
  lookup after widget deactivation in `stateful_boilerplate.dart`. Repeated
  `ListTile background color or ink splashes may be invisible` entries are one
  styling warning emitted during rebuilds, not repeated CloudKit crashes. Keep
  these UI repairs separate from the exact-source qualification result.
- The shell-only Canary status receiver accurately exposes engine activity,
  authentication and coordinator state, but its controller-owned `pull_state`
  remains `idle` for UI and background launches. Product status qualification
  must therefore use the shared progress source or repair that observability
  seam before claiming end-user progress accuracy. The stable post-wake state
  was engine inactive, authentication ready, coordinator inactive, outbox
  settled and semantic pull available.
- A controlled force-stop and cold launch preserved setup, registration and
  authentication. The fresh process automatically scheduled one bounded read;
  report `obcs2-semantic-1789490381477658.json` completed with one pass, all
  zones empty-terminal, fetched/applied zero, retained 8,502 and outbox
  1 -> 1. This is exact-installed-hash process-restart and read-side
  no-duplicate evidence. The first pre-owner native receipt replay deferred,
  then owner preparation completed its awaited replay and logged the automatic
  writer ready before the read began; there was no second replay warning.

### September 15 exhaustive retained-projection split

- The exact Windows `drain` lane now follows the production exhaustive retained
  sweep instead of treating two empty fetch/apply passes as projection stability.
  Read-only session `ad42f0997054fef22da1547807361a93` drained every current
  zone and attempted all retained saves without changing the 24 confirmed
  outbox rows, issuing a remote write or exposing message content.
- Replaying all 13 excluded Chat saves in session
  `11bcb9af66e228e0ca630ae1696e1b90` classified three as iMessage Lite and ten
  as RCS. They do not contain the missing iMessage parents.
- Content-free native shape capture in session
  `1373eeba766d871af6f790e0401b494f` separates two projection branches:
  539 messages have every required CloudKit field present but an explicitly
  empty decrypted `chatID`; a separate 183 converted messages have nonempty
  route evidence but no uniquely proven canonical Chat.
- The exact 539-row matrix changes the diagnosis: 531 are top-level `SMS`
  records, split into 483 incoming and 48 outgoing. Their `msgProto4.groupId`
  is absent for 56 and nonempty for 475. Only eight are iMessage records, seven
  incoming and one outgoing; all eight lack group evidence. The earlier
  490-incoming/49-outgoing total was correct but hid this service split.
- Candidate `7d38f1dd8` keeps required-field presence strict and keeps iMessage
  identity strict. It classifies only `SMS`/`RCS` rows with present-but-empty
  identities as typed out-of-scope service, preserves a nested non-carrier
  mismatch as `unsupportedService`, and permits only an exact durable
  `malformedRecord` or `unsupportedService` -> `outOfScopeService` transition
  after a fresh typed decode. It advances no checkpoint and mutates no
  canonical entity. The focused Dart/ObjectBox gate passes 145 tests. Exact
  GCE app-Rust run 34957446005 passed all 682 Rust tests and reproduced the
  committed bridge bindings; its build job took 6m01s. Cleanup passed, and
  independent GCE-instance and GitHub-runner inventories found no residue.
- Windows native-test-host run 34957628962 passed in 24m35s for exact source
  `7d38f1dd8900110e298ee091fc8e715a8d988212`: 671 Dart tests, 51 packaged
  native codec cases, ARM64/provenance checks and pinned ObjectBox verification.
  The archive and provenance digests were independently verified before the
  rollback-protected import into the isolated profile.
- Live session `2b31b210b1d2d500044db1c9acd958be`, report
  `obcs2-semantic-1789469940365007.json`, performed the exhaustive local
  projection sweep with fetched/applied 0/0 and outbox 24 -> 24. It changed
  only 573 exact retained failure labels: all moved from `malformedRecord` to
  `outOfScopeService`; dependency, unsupported-service, canonical, checkpoint
  and outbox state did not move. The 573 are the 531 newly typed empty-identity
  SMS rows plus 42 of the prior 110 carrier-typed rows whose durable label was
  also malformed. The other 68 prior rows failed the exact category fence.
- Fresh-process session `911bb545a8c357f6942e57e5bfe5dc3a`, report
  `obcs2-semantic-1789470215197415.json`, emitted no additional out-of-scope
  transition. Counts stayed at 3,763 out-of-scope, 307 malformed, 474
  dependency and five unsupported Message saves; outbox stayed 24 and remote
  saves/deletes remained disabled. This is the restart/idempotence proof for
  the bounded carrier correction, not proof that the remaining retained rows
  are safe to project.
- Do not sender-route the remaining eight empty-route iMessages. They have no
  group corroboration and remain retained. They are also distinct from the
  eight sampled records inside the separate 183-row parent-unavailable branch.
- In that 183-row branch, the sampled eight have nonempty `chatID` and matching
  `msgProto4.groupId`: five are bare UUID routes and three are qualified direct
  routes. Terminal Chat1 correlation found no unique owner. Do not synthesize
  a visible Chat until deletion/tombstone semantics can prove that doing so
  will not resurrect a removed conversation; retaining an orphan is safer than
  misrouting it.

### September 15 media/UI and authenticated body size

- The real reply layout reproduces the reported 58-pixel failed-photo overflow
  (106 pixels at double text scale). Download/error prompts now grow naturally;
  downloaded reply thumbnails retain their 100-pixel limit. The five widget
  cases cover ordinary messages, replies, large text and a decoded thumbnail.
- Developer catch-up now uses `startCloudSyncV2Progress`, sharing PCS
  preparation, Regular sizing, pause ownership, read-only execution and bounded
  chat-list refresh with the Profile card. The card shows elapsed time and
  separate fetch/replay rates; an external reader disables a duplicate start
  and its completion updates the UI automatically. Background returns also
  log their actual fixed outcome on the successful path.
- Wireless Pixel native evidence narrows the failed photo to MMCS after exact
  record fetch, decryption and unique key-qualified reference validation. Four
  attempts returned `io:InvalidData`; this does not prove the asset is deleted
  or undecryptable. The local byte-limited writer uses the same error kind.
  A typed size-limit error now distinguishes that local rejection and reports
  only maximum/written/incoming byte counts. It preserves the byte limit and
  cache admission rules. Native tests and a live reproduction remain required.
- Focused Flutter qualification: 70 passing cases; after the concise card copy
  change, all eight card widget tests passed again. Analysis has zero errors,
  five existing Profile warnings and 14 pre-existing lint/deprecation infos.
  Rust formatting/parsing passed; native execution has not run for this change.
- OpenCodex 2.56.0 is live. Native Muse/Luna children each executed a read-only
  shell marker with exit 0 and PowerShell 7.5.4; actual tool outputs were
  independently reviewed and sent to the repair task. Delegation works again.
- Stable Pixel database copy `device-evidence/20260915-mmcs-size-check` proves
  the failed HEIC has one resolved source, declared/canonical size 1,048,576,
  and streaming state without completed bytes. The same-time native asset
  descriptor reports 2,302,773. Three successful nearby transfers have equal
  declared/body sizes. No pipeline 1-MiB clamp exists; cm.tb is not a reliable
  exact size for every stored media representation.
- The candidate uses a private-constructor native length proof from the exact
  selected AES-SIV-decrypted Ford entries. Lengths count repeated references,
  require matching keys and retain per-chunk and 512-MiB total limits. The
  callback admits the body extent once before any data write; no-Ford keeps
  the metadata limit. Final byte count and hash are exact. Cache v3 binds the
  body extent to the unchanged source digest; original cm.tb stays unchanged.
- Dart stores completed native bytes separately using its existing versioned
  verification-reference field. No ObjectBox schema migration is introduced.
  Restart requires consistent source and body evidence; the UI reports actual
  downloaded bytes. Local tests pass 39 state/materializer/coordinator and 41
  source/adapter/file cases; focused analysis and sensitive-log scan pass.
  Rustpush `5522fa0` and app candidate `710003e7b` now pass native qualification:
  bridge 35008514692 has 685 app/317 rustpush/11 Anisette/40 protector cases.
  Canary 35008622263 and Windows native-host 35006456632 are successful.
  Both packages were independently verified. The Canary is installed in place;
  the Windows native package is imported and separately signed, with original
  ObjectBox preserved. Local signed-host attachment tests pass 29/29. Live
  failed-photo recovery is now `LIVE-PROVEN` on Pixel `710003e7b`: at 21:03Z
  the same 1,048,576-byte metadata record downloaded 2,302,773 authenticated
  bytes in 5.775 seconds and reached referenced state. The user confirmed
  images rendered and subsequently reopened successfully. The stable
  post-download database preserves metadata and records the verified body size.
  A fresh offline ObjectBox instance restored this state through the production
  store successfully, along with eleven existing completed attachments.
  No further download was logged through the user's reopen confirmation.
  This closes this exact HEIC failure, not every media/document case.
- GCE free credits are exhausted: no paid GCE starts without renewed user
  approval. Before this restriction, three VM starts failed with regional
  resource exhaustion; all cleanup completed with zero instances/runners.
  Use GitHub-hosted native validation and Windows fast-loop builds. Do not
  create duplicate runs by pushing both feature and trusted-source branches.
- Last old-build report `obcs2-semantic-1789498769734234.json` reached remote
  head with fetched/applied 0/0, retained 8,502 and outbox 1 -> 1. Later old-build
  automatic upload logs show two admissions before the upgrade. A stable
  post-upgrade copy has 700 chats, 11,841 messages, 2,413 attachments, outbox 3,
  no pending checkpoint batch/token and intact failed-HEIC source metadata.
  Do not compare this outbox to the older report as an upgrade side effect.
- Host `canary_adb_control.ps1 -Action assert-idle` now throws on busy, missing
  or malformed status rather than returning a successful status-print command.
  Its 24 offline cases pass. It is a point-in-time guard, not an atomic lease;
  never continue a lifecycle command after guard failure. Do not clear a live
  or unexpired coordinator lease to expedite a test.
- Post-compaction agent reconciliation: six known native child handles return
  `not_found`; a close retry is unsupported for those handles, not shutdown
  proof. The app reports Find My child `01a0a60c-f4ac-7812-9cc1-c0a940a6f96a`
  interrupted/notLoaded. Preserve its four unique uncommitted observer files
  in `agent-worktrees/findmy-ids-shape-20260915`. The integrated MMCS worktree
  is clean and retained until package/live qualification. No session deletion
  API is available; no transcripts or worktrees were removed. C: is 35.14 GiB
  free before artifact download. No build remains active. Follow-up Muse
  Schrodinger completed isolated observer dependency/parser corrections;
  parent deferred integration pending native compilation and full observer
  review. Muse Kierkegaard traced crash recovery to five-minute lease expiry,
  confirmed by live status; no product lease-recovery change was warranted.
  Both were closed successfully and no longer resolve as active native agents.

### September 15 detached-engine repair, current qualification and handoff

- Committed/pushed `0696757b2` for edit/unsend UI recovery and unique exact live
  chat alias fallback. Thirty-six focused tests pass. No existing chat merge,
  reparent, Alpha upload or account mutation. Captured comparisons remain intact.
- Parent rejected the first lifecycle-agent patch because it left automatic
  FlutterFragment destruction intact and duplicated service busy-state logic.
  Parent replacement `f027aad2a17c131f7d68687ea68f58b334473e8f` closes admission
  synchronously at the interlock, awaits actual release including same-kind
  nested cleanup, and never completes poisoned work by timeout. Direct edit/
  unsend futures retain their whole post-lock receipt tail. Queue preparation
  is counted before the runner exists. Native Fragment ownership bypasses
  automatic engine destruction, waits for the Dart handshake and outstanding
  IPC replies, then destroys only that detached instance after acknowledging.
- Independent resumed Muse review found no blocking defect in those paths.
  Parent added its diagnostic-only stalled-drain notice and documented the
  new-host/new-engine invariant. Typed busy rejection matches existing catches.
  Thirty-three Dart interlock/coordinator/queue tests and eight Kotlin lifetime
  cases pass; focused analysis has no errors (five pre-existing style notices
  remain in the large RustPush service). These are not device lifecycle proof.
- Hosted Build `35058684776` is running for exact f027 with canary_only=true;
  the Alpha job is skipped. No GCE, credentials/configuration change, upstream
  PR or phone installation. Do not dispatch a duplicate while it is live.
- Windows session `c936a56175d792b302385e4df76a1f63` used the exact signed b9c
  runtime: first pass fetched/applied five changes, next two were stable empty
  terminal passes, retained total6252, outbox24 unchanged, writes disabled.
  Four owned processes per pass stopped; cleanup.json confirms raw-output
  removal. This is baseline runtime proof, not f027 Android validation. The
  strict dual-source guard was not weakened or bypassed: b9->f027's rustpush
  gitlink difference is a cfg(test) assertion update, but is still a difference.
- FaceTime/Find My workers exchanged and reviewed current-source findings after
  their stale-base duplicate fixes were rejected. Windows FaceTime opens an
  external browser and cannot exercise Android's WebView admission/probe. No
  newer native trace exists. Find My's only observer ingress is the mutating
  handle path (ACK, possible share-state saves/deletes); the Windows host lacks
  a receive listener. Do not invoke that handler as a read-only probe. Neither
  side is production-qualified; the next tests must reach the actual runtime.
- Final engine reviewer, FaceTime and Find My tasks are idle and archived using
  supported app controls. Native handles became unavailable after the host
  reload, so app state/reports were checked. Frozen unique/uncommitted work and
  evidence are retained; no raw session/transcript deletion API exists.
- Moved 313 historical treemap lines to this log with relative links adjusted;
  current critical path is now separate from completed experiments. C:28.12GiB
  free; active main build output0.69GiB. No storage deletion in this continuation.
- Follow-up column-only comparison confirms the existing live GUID equals the
  restored group's cloudGuid, not its guidRefs, chatIdentifier or record ID in
  either Canary or Windows. This ties the preventive fallback to the observed
  missing-column route; the existing duplicate is still not automatically merged.
- GitHub-hosted run35058684776 subsequently completed successfully, producer
  duration44m51s, no GCE. Artifact10432532324 archive digest matched GitHub;
  downloaded APK452,999,643 bytes has SHA256
  d34e72bb78add5f5654adf04e5183cffd8c786bdb5a526ab2a19a424b8e7ab50.
  Independent apksigner verifies v2/v3 and the stable Canary certificate; aapt2
  verifies com.bluebubbles.messaging.cloudkitcanary,1.15.0(20002227),SDK36.
  Four required ARM64 libraries, absent dotenv, and DEX lifecycle markers pass.
  No phone is present in fresh USB/mDNS discovery, so no install occurred.
  Detailed local verification.json retains source, archive and APK provenance.
- Saved-copy group follow-up finds13 incoming messages and zero outgoing send,
  adopted-send or mutation journal references in either split row. Original
  captures remain hash-identical and no Apple request occurred. Existing group
  binding still pins local row ID and protected source, so this finding alone
  is not a safe reparent/merge operation. A resumed helper turn was empty and
  was not counted as a completed independent review.

### September 16 incoming-archive gap and structural group proof

- The production local group-binding validator passes on canonical saved rows
  Canary695 and Windows664 at generation1. Live Canary701 captures a provisional
  route and fails the restored-parent gate. This opens no native protected blob
  and authorizes no write. Source captures stayed hash-identical; no rows moved.
- Parent source review plus Rawls' call-graph audit establishes that V2 drains
  only locally sent, positive-receipt intents. Genuine incoming and own-device
  mirrored messages persist locally but have no V2 archive producer. Legacy's
  all-unsynced upload is correctly disabled under V2 ownership. This is a
  production capability gap, separate from missing chat projection. The older
  27 Alpha GUIDs were not searched in all protected raw CloudKit records, so
  canonical-table absence remains weaker than remote absence.
- Added INCOMING_ARCHIVE_DESIGN.md and corrected the user guide's coverage.
  Incoming origins must not fake outgoing receipts or invoke IDS sends. Exact
  archive record identity/deduplication, durable intent, source, protected chat
  binding, create/readback and independent Apple-client proof remain required.
  A two-file eligibility prototype is isolated and in review, not installed.
- Find My's initial new observer wrapper called network-capable receive_message;
  cache miss can query directory keys and re-register on6005. Parent rejected
  its read-only claim. The worker changed to cache-only lookup/decrypt with fixed
  outcomes; caps, errors, successful decrypt purity and actual delivery ownership
  still require review/qualification. APS has a separate auto-ACK receiver, so
  an independent broadcast subscription alone is not a durability proof.
- Windows findmy.plist exists (27,135bytes, last modified July31); keychain and
  hardware files exist too. File presence alone does not prove fmfd initialized.
  Native make_findmy requires that state; normal recv_wait dispatches to fmfd
  when present. Background-following APIs are used by conversation location
  widgets, while the People page uses a separate foreground client. Bootstrap
  differences are being checked before adding more listener infrastructure.

### September 16 continuation checkpoint

- Reconciled after automatic compaction. No Dart/Rust/build process remained;
  the final eligibility format/test result was not recoverable and is not
  counted as passing. Two new untracked eligibility files are in main, not
  hooked to receive or upload. The verified f027 APK is unchanged.
- Reviewed and closed completed Noether and Rawls using native agent controls;
  follow-up lookup returns not_found. Their dedicated worktrees retain unique
  uncommitted source/review material. No supported transcript/session deletion
  exists, so those are retained too. No storage removal; C:29.23GiB free.
- Find My standalone probe requests no daemon topics and has no normal receive
  dispatch, while APS owns a separate auto-ACK listener. This is a qualification
  gap, not proof that any user message was lost or that every alternative host
  is impossible. Do not enable that probe on the retained registration until
  normal delivery ownership is proved. Prefer observation inside the normal
  app receive loop. Current saved Find My state exists, so bootstrap absence
  alone is not the demonstrated cause of missing People coordinates.
- Wireless discovery now advertises the Pixel again. Connection/read-only
  preflight is next; no update, force-stop or reset has occurred.

### September 16 reviewed received identity and wireless evidence

- Pixel connected wirelessly. Content-free status reports ready sign-in/UI,
  legacy off, no active pull/coordinator, and blocked outbox. Stable compressed
  capture at08:12:51Z is135,319,552bytes with device-before/device-after/local
  SHA256 `2ec96eee37eff46b06a3549d26285d4757093f6f1d6ed6a16470de44da82e6a0`.
  Inspector verified unchanged source and found eight confirmed creates plus
  the same unknown create last updated September15 23:12:40Z. Nineteen send
  intents include ten ready, nine intact and one changed; no source was repaired
  or retried. The older unconfirmed unsend is not the user's newer failed edits.
- Saved app log and both native generations under private
  `device-evidence/20260916-outbox-preflight`; fresh worker log08:15:06Z still
  reports cloudkit_interlock_busy. This supports the lock-busy diagnosis, not
  proof of the exact retained port owner. Existing guard blocks lifecycle work;
  parent asked for explicit in-place restart/update and did not bypass it.
- Parent proved three prototype failures with failing-then-passing tests:
  outgoing sender preference, same-row canonical chat adoption and deleted-chat
  eligibility. Removing mutable chat routing from the content digest does not
  authorize reparenting; current row relation and later protected parent proof
  remain separate requirements.
- Rawls' resumed source handoff corrected its earlier target assumption.
  Native IDSRecvMessage.to_message carries a reply-device token on ordinary
  iMessage. A native-shaped fixture reproduced rejection before the fix. The
  actual addressed local tP is lost on uncertified MessageInst conversion, so
  the candidate now requires separately captured receivedOnHandle and checks
  certified endpoints when available. No native propagation was implemented.
- Final batch:36 eligibility cases plus232 existing local-send journal,
  mutation-identity and chat-origin cases,268 total pass. Focused analysis has
  no issues. No production caller imports the new component; no remote save,
  receive hook, schema or APK change. f027 remains the frozen device candidate.
- Reviewed the source-only native reuse handoff: keep a distinct origin and
  protected envelope, use exact existing native record-name derivation, and
  handle Apple-first semantic equivalence separately from exact own-write
  readback. Existing outbox is reusable after admission, but offline/provisional
  receive work still requires its own durable pre-admission ownership.
- Rawls closed after final review; both current native agent handles return
  not_found. Their uncommitted worktrees and sessions remain protected; current
  tool discovery exposes no session deletion. No storage deletion, C:29.03GiB
  free, no active build/test, no paid cloud run or upstream PR.

### September 16 native received-origin propagation

- Previous goal turn made concrete progress (e65bee42e and qualified device
  evidence), not a wait. Pixel restart/update still awaits explicit approval;
  no new phone action was taken in this continuation.
- Native rustpush9ced48bae256bcdd7d46db84eefb331bd9d86d88 preserves original
  local tP independently of reply-device tokens in MessageInst. Existing local
  constructors explicitly leave it unset. App0e9d2d2d089d67b7ef454e81ea7df978b2dbe9eb
  mirrors it through FRB and keeps attachment/edit/unsend source validators from
  interpreting receive-marked objects as local outgoing source. Existing protected
  source serialization remains unchanged; old local envelopes reconstruct None.
- Pushed only to Xare123 fork branches agent/cloudkit-v2-received-origin-20260916,
  with skip-ci commits to avoid automatic APK builds. Manually dispatched the
  existing GitHub-hosted bridge workflow with allow_generated_drift=true. No GCE,
  signing changes, credentials, infrastructure, APK build or upstream PR.
- Run35075169331 completed successfully08:53:55Z, started08:41:35Z (12m20s).
  App Rust685, rustpush321, Anisette11 and protector40 tests passed. Four native
  receive-origin cases ran; outgoing codec rejection cases also ran. Committed
  generated-drift verification was intentionally skipped by this generation run.
- Artifact10437743507 is380,187bytes with SHA256
  2c554a5e4c5704375bd481bfab5feb93a236913fca914f4aa88ef1012718d695.
  Verified before extraction; imported exactly seven generated members into
  previously clean tracked paths. Only api.dart, frb_generated.dart and
  frb_generated.rs materially differ. SSE and diagnostic normalization guards
  pass locally. Evidence retained under build-evidence/received-origin-bridge-35075169331.
- Dart changes require native recipient/context agreement and reject receive
  metadata in outgoing text, reaction and mutation capture. Four regressions
  failed before implementation; all288 cases in the five-file targeted batch
  now pass. Focused analysis has no issues. The tested source does not enable
  incoming CloudKit writes or change the frozen f027 APK.
- Carver Muse/max is active in received-intent-journal-20260916 at basee65bee42e.
  First journal draft was rejected for precomputed-identity drift and circular
  first-save proof. Revised API captures from loaded persisted rows plus original
  wire inside the caller's atomic persistence transaction. Parent also rejected
  old-epoch reference omission from GC and a bounded scan that resets its offset
  every call. Requires retain-all ownership and an explicit keyset continuation
  with a multi-call starvation regression. No journal/schema integration yet.
  Telephony dependency was initialized at its recorded commit using local Git
  objects. Seven unrelated plugin registrant changes remain outside approved
  integration scope. Keep the active agent and unique work; no cleanup deletion.

### September 16 durable received journal integration

- Carver froze a13-test revision. Parent reviewed/imported only its eight owned
  source/model/generated files, not unrelated plugin registrants. All27 existing
  ObjectBox entity/property definitions and retired entity/property UID arrays
  compare unchanged; entity36:4861163290100543941 adds13 metadata properties.
- Parent reproduced and fixed further failures: partial ready-page capacity
  advanced past an unreturned valid row, a changed auth callback could commit
  persistence, and deleted Message metadata remained ready. Keyset now advances
  only after considered rows; auth/owner is rechecked after the synchronous put;
  deleted rows remain retained but not eligible. Original wire/body/sender/time
  are validated inside the same transaction as initial Message plus intent save.
- Added real production-store reference inventory wiring, not just journal
  helpers. A failing-before/passing-after test proves retained received blob and
  lease ownership across database reopen and unknown/old epochs. Corrupt binding
  stops cleanup. These remain local references, not remote write permission.
- Forward-upgrade test creates a synthetic pre-received e65 model store, writes
  a Message/Chat, opens with the new model, verifies values and relationship,
  and reopens again. It neither opens user evidence nor proves old-APK downgrade.
- Final combined batch passes446 across ten files; focused analysis has no
  issues. No production receive hook, native source stage, incoming outbox
  admission or Apple-first equivalence path is enabled. No phone restart,
  installation, user-data mutation or new cloud build occurred in this step.
- Carver closed after accepted-with-corrections review; native lookup returns
  not_found. Its frozen original source is retained for provenance until a clean
  Git snapshot is recorded and supported worktree cleanup is verified. Main
  retains the corrected implementation. Raw sessions/transcripts are not deleted.
- Corrected journal/GC/schema work committed ascd77ec555 and pushed only to the
  fork's received-origin branch. Original helper snapshot committed locally as
  ea4a3cc589 on agent/received-intent-journal-review-20260916 for provenance, not
  deployment. Dedicated worktree measured391,223,213bytes/1,986files, clean,
  no running build/test, with only unset test environment values. Standard Git
  removal refused its initialized submodule. Parent verified that submodule's
  clean Git metadata belonged exclusively to this helper (distinct from main),
  then used exact-target Git-aware forced removal. Target gone; retained ref,
  main/submodule, private evidence and verified APK remain intact. Observed free
  space increased396,410,880bytes; C:28.48GiB. Manifest records both initial
  refusal and successful reviewed cleanup. No session/transcript deletion.

### September 16 protected receive source and typed duplicate comparison

- Previous goal turn was progress (native destination propagation, atomic journal
  and forward schema proof), not a wait. This continuation adds native source
  serialization/protection under idsReceivedArchiveSource, plus cached capture-only
  identity and staging APIs. The original writer snapshot still validates current
  GSA; capture-only cached identity is explicitly not remote authentication.
- Source codec preserves exact sender/recipient/direction/text/time/conversation
  identity, excluding reply routing tokens and certification receipts. Unicode/
  control-character source/GUID digest vectors agree with the Dart v1 contract.
  Staging requires exact committed lease before reopen, rejects tampered descriptor,
  wrong account and wrong purpose, and performs no Apple request or send.
- Dart coordinator stages, atomically persists Message+intent, then commits under
  protected-store exclusion. Lost commit response preserves journal ownership;
  restart reuses and recommits the original lease with one native stage total.
  A fresh pre-adoption failure rolls back only its own lease; post-adoption auth
  drift retains the source. No network-wide writer interlock was added to capture.
- Fermat's typed comparator received parent corrections: ordinary part-zero and
  false-formatting attributes allowed, text-only records allowed, timestamp
  comparison respects millisecond precision, redundant direct groupId is not a
  group, unsupported expectations fail before comparison, no caller-bool adoption
  gate, and the decoder shares one bounded implementation. Parent further fixed
  mirrored empty-sender shape and the WAS_DATA_DETECTED flag distinction.
  Comparator is not raw-record/adoption proof, and every Found result forbids
  duplicate create. Raw unknown-protobuf validation remains a real open gate.
- App089b87fa26243d5f231f44cf9e8d96361e611c74 pushed only to the fork branch.
  Hosted run35086913808 succeeded11:05:19Z after17m18s. Native counts708/321/11/40;
  no APK or GCE. Generated artifact10442727024 has381,798bytes and SHA256
  7c9facdf6f52bb02323156f998a08f0e7fe9264aaf72630a96f5c0d8a26d01fe, verified before
  importing seven clean targets. SSE/diagnostic guards pass. Committed generated
  reproducibility was intentionally skipped by allow_generated_drift=true.
- Native descriptor conversion and exact safe failure vocabulary are integrated.
  ArgumentError exposes only an allowlisted message code, not invalidValue/name.
  Eleven-file Dart batch passes480; focused analysis clean. No live received
  producer, outbox admission, native raw equivalence/adoption or incoming uploader
  is enabled. No phone installation/restart, account action or upstream PR.
- Fermat closed, native handle missing. Original helper source preserved at
  d9f5674c57 under agent/received-record-match-review-20260916. Its136,857,020byte
  clean dedicated worktree was removed Git-aware after submodule ownership checks.
  Observed free space increased147,750,912bytes. Main, source refs, user evidence,
  credentials and frozen APK verified retained. No transcript/session deletion.
  CI watch28863 and Dart batch60412 are terminal; no helper or build remains live.

### September 16 live-receive hook and local lease, qualification pending

- Parent added a default-off live receive persistence callback and delivery
  fallback. Errors after durable adoption return the verified committed row;
  precommit rollback restores the Dart object's ID before ordinary persistence.
  Replacement-account fallback is forbidden. A pre-stage failure still lacks
  durable original-source retry, so archival completeness is not claimed.
- Review found the old Dart exclusion is isolate-local. Recovery could inventory
  no receive reference, then delete a freshly staged source before adoption.
  Heisenberg supplied a native per-directory task mutex plus OS-file lease;
  parent added bounded registry and link/poison handling. The lease is local,
  not a network writer permit. Current Dart maintenance and staging integration
  and new opaque APIs are unqualified; generated bindings are not yet refreshed.
- After automatic compaction, source/agent/test state was reconciled before new
  implementation. HEAD a79119ca2 has dirty hook/lease changes. Test84412 passed57
  before final lease integration; analyzer16714 ended with existing diagnostics.
  No active test/build remains. Heisenberg is reused for read-only main-path
  review, with its worktree retained. C:28.49GiB free. No device mutation or GCE.

### September 16 live-capture component qualification complete, uploader still off

- Native local-store lease checkpointdf23a06d58deda16286c5ca5f0d38ff940bbad63
  passed GitHub-hosted35094043857 (12:07:35Z to12:25:16Z). Native counts:
  717 app Rust,321 rustpush,11 remote Anisette,40 protector. Tests include actual
  child-process lock contention/exit, task exclusion, bounded waiter rejection,
  no owner takeover, path/link rejection and idempotent release. Linux evidence
  does not establish native Windows/Android runtime behavior.
- Artifact10445637603,383,023bytes, SHA256
  0ccbb8c6592fe5b0de83eb43417ea1d5b683cd2498788998f602d3487ccb8419 matched before
  extraction/import. All seven generated members remain byte-identical; SSE
  and diagnostic guards pass. allow_generated_drift=true intentionally skipped
  committed reproduction. No APK build, GCE launch or production credentials.
- Parent separated the local capture lease from the old isolate gate, which
  surrounds network fetches. Maintenance retains old-gate then local-lease order;
  receive uses the local lease only. Its commit/rollback bypass cannot invert
  that order. New tests prove receive can finish during a held fetch gate,
  maintenance inventories after capture adoption, and maintenance still waits
  for a preexisting fetched-page lifecycle. Closed zone reuse is rejected and
  quiescence joins explicit release, retaining release failures.
- Live queue hook is default-off and direct-text only. New persistence callback
  exercises the real ActionHandler/Chat/ObjectBox seam. Rollback preserves no
  partial row; duplicate capture keeps a later edit and emits no new notification.
  Source/row checks, own-send overlap rejection, and account/store fences remain.
  Queued identity is pinned before async work. Reset drains captures. Unsupported
  shapes retain their original queue path. Optional preflight failure preserves
  ordinary messaging but does not create durable archival retry ownership.
- Parent first omitted ObjectBox DLL PATH, causing harness-only error126; fixed
  the process PATH and documented it in AGENTS. A fault-injection closure inferred
  Never was rejected by ObjectBox before execution; corrected the test to perform
  a runtime-injected failure and prove in-transaction save plus rollback. Broader
  testing found four stale old-model fixtures retaining new entity36 and a stale
  three-composition source expectation. Fixtures now omit later tables, retain
  predecessor counters/bindings and actually reopen stored synthetic content.
  New received composition is checked for its independent default-off fences.
- Final23-file batch passed676 (session12327, terminal). Focused14-file analysis
  passed; larger action/service files retain seven existing warnings/info and no
  errors. App/source plus generated bridge committedcfc37e26a5b2d5350dfe709cead0fbeb67e097ba.
  This remains component qualification, not incoming uploads or live Pixel proof.
- Heisenberg closed, verified not_found. Original source retained locally at
  refagent/protected-store-lease-review-20260916 /055f3cd6b22704cc712ac2c881add153f2ab811c.
  Final follow-up had no final report, so it is not counted as extra sign-off.
  Exact clean helper136,957,706bytes removed with Git-aware worktree removal after
  exclusive submodule/no-process checks. Observed C:free gain143,134,720bytes;
  main, source refs, private device evidence and signed f027 APK verified retained.
  Manifest: build-evidence/agent-cleanup-20260916-local-lease/manifest.json.
  Sessions/transcripts retained because supported deletion is unavailable.
- Remaining: durable pre-source capture retry, raw duplicate/adoption evidence,
  received outbox create/readback and independent-client/live qualification.
  Capture flag remainsfalse. No helper/test/build remains active. Pixel in-place
  restart/update is still pending user approval; no reset/replay/Alpha change.

### September 16 encrypted receive retry job and raw comparison qualification

- Previous turn progressed through native local leases and live capture tests.
  This continuation replaces foreground file staging with native platform-
  encrypted inline seeds. Message and original source ownership now commit in
  one ObjectBox transaction before file work. Native sealing still can fail
  before ownership exists; ordinary-delivery fallback is not archival proof.
- Reuses the existing source-binding column with version2 ciphertext form,
  no schema UID changes. GC inventories validate inline seeds but never invent
  file references for them. Version1 file descriptors stay supported. Local
  materialization transitions state0 tostate1 only after exact commit. A lost
  commit response retains the original descriptor and recommits without stage.
  Worker rounds have snapshot high-watermarks and bounded pages; continuous
  ingress cannot indefinitely delay retained failures. Reset joins disposal.
- Native APIs use cached same-account/store identity, local registered handles
  and platform protection only. No IDS send, dependency warming or CloudKit save.
  Native source projection preserves original endpoint rather than mutable chat
  sender preferences. A raw protobuf checker now verifies original presence and
  field values before typed comparison, accepting field order without a lossy
  reencode equality shortcut. Parent corrected one helper fixture's expected
  error for truncated fixed64, and required optional-proto/overflow coverage.
- Hosted native9293a457c/run35099318119 succeeded13:19:19Z, total17m40s.
  Counts737/321/11/40. Artifact10447797443,384,004bytes, SHA256
  827bba84a9182376e8534cceba25f5019d89edfb3354b5db53bcd274a0a07d07 verified before
  importing seven clean generated targets; exact byte matches and both generated
  guards pass. Committed reproducibility deliberately skipped. No APK or GCE.
  App/source integrationf403006b9abac5d2943372fcd0b50d4c62dd3a56 passed692 cases
  across25 Dart files; focused analysis clean. Larger service has five existing
  info diagnostics, no errors. Separate FaceTime six-file batch63 also passed.
- Parent rejected three review claims with source/test evidence: delivery seal
  errors do reach the ordinary-persistence wrapper; native abandoned-lease
  recovery already covers crash-before-adopt orphans; scheduler disposal already
  joins its active drain. Accepted the deferred-round starvation concern and
  added the durable-ID ceiling plus regression. Helpers are input, not authority.
- FaceTime review found no new proved production cause without a native media
  trace. One empty-join-handle regression integrated and tested. Original helper
  source retained at4caaab120 underagent/facetime-acceptance-review-20260916.
- Find My independent observer rejected: receive_message/get_key_for_sender/
  cache_keys_once can call ensure_ready and refresh_now on6005. Godel revised to
  a synchronous value-free tap on handle's existing decoded object, no second
  receive/key/cache call or ACK/control-flow change. Franklin and parent reviewed
  it; native execution remains pending for next batch. Isolated app160356758/
  native9b09a541 retained locally underagent/findmy-singlepass-review-20260916;
  native objects fetched into active rustpush without switching its9ced48b HEAD.
  Corrected helper history: fe9b9/576f466 qualified pair DID compile; only later
  uncommitted cache-only api sketch referenced a nonexistent method.
- Three helpers closed and native lookupsnot_found. Euclid exact source retained
  atd16a55e6b;133,761,041byte worktree removed Git-aware, observed free+136,302,592.
  FaceTime341,919,086bytes and FindMy137,053,035bytes were previewed for removal,
  with source refs, empty env values and exclusive submodule metadata verified.
  Cleanup command was policy-blocked before execution. No alternate deletion
  path attempted: both worktrees,82 plugin symlinks and12byte probe remain.
  Shared plugin targets were not touched. Manifests underbuild-evidence/agent-
  cleanup-20260916-{raw-proof,sidecars}; sessions/transcripts deletion unsupported.
- No live account traffic, phone change, unknown-outcome replay or Alpha mutation.
  No active tests/jobs/helpers at checkpoint. Next: connect materialized source
  to exact native raw lookup/adoption/create-only flow, checking raw outer flag
  bits before generic decoder truncation. Not production ready or enabled.

### September 16 exact received-record inspection and restart qualification

- Resumed from native app f139a899b4cd51706a93d011753d462092eb5fcb and rustpush
  fb864a302d2d07b4480d2b40ad3cee4c1d134729. Hosted35107521313 succeeded with
  737 app Rust,350 rustpush,11 remote Anisette and40 protector cases. Euclid's
  final review accepted original-frame validation before result-code handling,
  strict record-wire retention, restored semantic transport and bounded gzip.
  Closed Euclid and verified not_found. No dedicated worktree was created by
  that latest review; prior blocked cleanup was not bypassed.
- Artifact10450679242 was386,132bytes, SHA256
  2f8a4c807d8f9aa113797ca3eafde5012cb33b3f382d99b20d26f970b646ec4a. Verified
  all seven clean generated targets before import. Generated SSE/diagnostic
  guards passed. Committed reproducibility was intentionally skipped. Evidence
  manifest: build-evidence/received-exact-inspection-35107521313/verification.json.
- Initial Dart batch185 passed. Parent then reproduced three lost-commit
  failures by checking the ACTUAL worker selector, not just directly retrying
  the coordinator: a retained observation was excluded by onlyWithoutObservation
  after raw commit failed. Removed that selector. State1 remains eligible until
  exact local observation commit; state2 means local inspection finished, never
  remote save. Source recommit cannot regress state2. GC retains both source
  and observation across epochs/restarts. Escaped oversize bindings are rejected
  at construction, before writing an unreadable descriptor. Before the next
  native split, the27-file integration batch passed808 cases;11-file analysis
  was clean. Existing entity/property IDs and global counters were verified
  unchanged; only nullable entity36 property14:3909871882147317660 was added.
- Muse Popper's reuse review was accepted with a correction: existing outgoing
  native validation intentionally rejects received sender/direction. The archive
  must retain distinct source authority rather than relax outgoing validation,
  forge an IDS receipt, or reconstruct a mutable Message. Found remains blocked
  from new create; Absent must be checked again when admitting. Full incoming
  create/adoption remains open, including incoming groups/media and pre-seal
  readiness failure. No additional comparator is being called an uploader.
- Parent verified a concrete cross-engine maintenance gap: mutation code calls
  ensureRecoveredBeforeWrite before taking its network interlock. An isolate-
  only inspection lock cannot protect a new raw file before ObjectBox adoption.
  Native6eaba5c223463ac211d561da7d405b357156a49d splits exact network preparation
  from local stage. Single-use opaque handle retains read result in memory;
  cross-engine local exclusion covers stage/adopt/commit with source/container/
  parent revalidation, and explicit discard releases unused memory. No network
  fetch is performed while holding the short local lease. A new native test
  checks original field order retained byte-for-byte and exact double commit.
- Hosted bridge35136724953 qualifies that source with unchanged rustpushfb864a3.
  Artifact10463731660,387,557bytes, SHA256
  940147d25bf649f0600cbac0c77dbaf4f2e540ca7b587ab9ccde00918b609d5a was verified
  and imported after matching current generated files to the prior artifact.
  All seven members match, guards pass. Full native run remains pending here.
  Old native DLLs must not be paired with these bindings. No APK was built.
- User requested more efficient OpenAI-style delegation. Read official guidance
  and recorded bounded outputs, small context, disjoint writes, evidence-based
  integration and risk-proportionate testing in AGENTS.md. Parent owned native/
  Dart production; Popper owned only received journal tests and passed28/28.
  Parent's separate changed-source batch passed19, with eight-file clean analysis.
  These are subsets, not added to808 as independent coverage. Popper's fake proves
  handoff ordering, not native OS lock behavior. Native double-commit remains a
  hosted test. Popper closed and verified not_found after review.
- No new helper worktrees, build trees, raw-content evidence, credentials, account
  traffic, phone actions or paid GCE. C:27.14GiB free at checkpoint. Supported
  session/transcript deletion unavailable; shared session stores retained.
  Current job35136724953 is the only active job; all local sessions terminal.
  Next resume: check this job, import no mismatched artifact, finish exact-source
  tests/commit, then received source-bound admission and normal reader adoption.

- Final local integration14ce1d7499efe4aa7ba9737040fd33e3d48de087 passed811 tests
  across27 files and clean14-file analysis. No extra full run is needed without
  changed code or a concrete new risk. Native generation and compile succeeded
  on35136724953; native test steps remain in progress at this checkpoint.
  Artifact10463731660's seven generated files remain exact matches after commit.
  Current build output is743,168,141bytes and .dart_tool62,973,595bytes; C:free
  29,101,309,952bytes. No local Dart/Flutter/Cargo/Rust compiler remained active.

- Hosted35136724953 ended FAILED: native compiled,737 app Rust tests passed and
  the new received_readback_preserves_original_wire_and_recommits_after_lost_response
  failed at the fixture's assert_ne before calling the production helper. ETag
  is tag1, so prepending it had produced canonical order. Parent corrected the
  fixture to append that known field last, leaving production and assertion
  unchanged. Later native suites were skipped by the failed step, not passed.
  Fix4066778045915a8f4f951bb8eb7bfcb0171391b1 is pushed to the isolated fork
  branch. New job35138299645 qualifies it, now with allow_generated_drift=false
  to verify the committed bridge. No narrower native-only workflow was available;
  no new CI infrastructure, APK or local native rebuild was introduced.
  Resume that job rather than rerunning the old SHA. All helpers remain closed.

### September 16 received creates enter the real protected outbox

- Prior inspection rerun35138299645 passed:738 app Rust,350 rustpush,11 Anisette,
  40 protector, plus committed-bindings reproduction. Artifact10463524620 has
  SHA2566ae2d27ff090c5a9086585ad017842c52b302148675f945d1727120d34a6f4ab,
  387,557bytes; all seven generated targets matched without overwriting source.
- Nativef33a2e76431a058d167b74a4389dea55e731d91b and rustpush5862be3c0ddf0ac0a81e3a45e33cf64d67d996ef
  add the actual received create/readback seam. Fresh native NotFound produces
  a single-use local stage; a distinct magic-prefixed envelope cannot parse as
  ordinary outgoing data, including own-device mirrors. Original source and
  authenticated parent are reopened for prepare/consume/reconcile. Ordinary IDS
  success gates remain unchanged; received archival never calls IDS send.
- Dart stages under a short cross-engine lease, adopts journal/outbox/map in one
  ObjectBox transaction, then commits the same lease. Unknown outcomes retain
  the exact envelope/request IDs. Received state3 marks outbox ownership only.
  Native writer preflight/readback uses strict original-wire lookup and retains
  original raw bytes. A fresh Found replaces only old no-raw Absent evidence;
  it never reaches create. Current known edits/unsends defer stale originals.
- Received creates share the existing queue drain, mutation capability and
  restart/readback machinery. Missing local Message rows can still resolve the
  journal-pinned existing canonical Chat for readback; deleted/changed Chat stays
  deferred. A new independent upload flag and existing capture/inspection flags
  remain false. Incoming groups/media/mutations and Found projection are not
  claimed complete by this direct-unchanged-text implementation.
- Schema comparison verified all28 entities and all preexisting property UIDs
  unchanged. New nullable fields15:6918628364972964921 and16:6065925816449012533,
  with index104:3906661285702552393, preserve forward migration. No user DB was
  opened/upgraded by these tests. Downgrade is not qualified.
- Hosted35142500478 succeeded19:45:47Z to20:03:03Z:743 app Rust,351 rustpush,
  11 Anisette,40 protector. Artifact10465832549,389,704bytes, SHA256
  0a96906406669b9b5b19bb2de6042a701678503c96c346b411bf383d49466788, verified
  before importing seven clean targets. Generated guards pass; committed
  regeneration deliberately skipped. Evidence: build-evidence/received-create-35142500478.
- App integration383ac8038da13e506a0fe0b8ed4d8b6e89976037 passed853 Dart cases
  across28 files. Analysis found no errors/warnings, only five existing style
  infos in rustpush_service. The parent transport proof test needed a fake release
  capability and semantic scope (fixture repairs, no production guard bypass).
- Popper wrote24 admission cases in one existing test file; all52 file cases
  passed. Parent reviewed atomic rollback/revision, source/parent/account drift,
  received-vs-outgoing separation, late edit/unsend and unknown-outcome restart.
  UTC representation and a Never-returning rollback closure were fixture-only
  fixes. Closed Popper, verified not_found. Raman produced no code after repeated
  exploration; parent rejected the non-result, closed it (not_found) and wrote
  the codec. No child worktree/cache was created. Transcripts remain because
  supported deletion is unavailable; no shared session DB was edited.
- No paid GCE, APK, phone action, production account request, source replay or
  Alpha change. C:28,865,392,640bytes free at checkpoint. All local test/analyzer
  sessions and hosted jobs are terminal; helpers closed. Next: Found-to-reader
  durable handoff, then representative live cross-device proof on matched code.

### September 16 independent FaceTime and Find My ownership

- User explicitly assigned FaceTime/Find My to existing task01a0abe1-9bbe-71b2-a9ce-4d4578022b0e,
  title facetime & find my, and asked this task to focus on CloudKit. Parent read
  target state (idle in an unrelated directory), then sent the full evidence-
  backed implementation handoff through supported task messaging. Start baseline
  appb1468abbb/native5862be3 is committed; current dirty reader work is excluded.
- Independent branch/worktree proposed: agent/facetime-findmy-independent-20260916
  at C:/Codex/OpenBubblesReview/worktrees/facetime-findmy-independent-20260916,
  verified absent before dispatch. Destination owns setup/goal after user entry.
  No shared worktree or credential copying; no upstream PR or paid GCE approval.
  Shared source edits require advance notice and later reviewed commits. Pixel
  and Windows live-profile mutation require an acknowledged exclusive test window.
- No competing FaceTime/FindMy helpers remain here. CloudKit reader helper Popper
  stays active for required isolated tests. Parent owns native/local reader
  integration; current dirty code and bindings are unqualified, no CI active.
  User receives a pasteable goal for the independent task; message delivery is
  not falsely reported as goal activation or product completion.

### September 16 Found-reader integration and post-reset key repair

- User changed this task's goal to production-ready CloudKit only. Independent
  FaceTime/Find My task acknowledged its isolated checkout and owns its own
  runtime qualification. Its bounded Windows read window ended without account
  use because a DLL hash/ABI guard rejected the installed artifact. No guard
  was bypassed and no side-lane commit was merged into CloudKit.
- Nativec5559d5bb48bc3e0d1f921e1d5d5ff6b1aff63cc stages fresh supported Found
  records through ordinary protected-change hashing, preserves original wire
  bytes and exposes no server cursor. One-use, age, source, parent, auth and
  container checks remain. Tests prove history-identical change identity,
  unknown-field byte retention, idempotent local commit, mismatch rejection
  and rollback of unowned records. Hosted35149164355 passed745 app Rust,
  351 rustpush,11 Anisette and40 protector tests (20:52:50Z to21:10:44Z).
- Artifact10468512025 (390,597bytes), SHA256
  a2b067b4e1783a06d0280882d36930a9314106d52dc0aa89a04ab773beb76eda, was verified
  before importing exactly seven generated files; SSE/diagnostic guards pass.
  Committed reproduction was intentionally skipped. Evidence is under
  build-evidence/received-reader-35149164355, including verification.json.
- Dart atomically adopts Found into the normal semantic inbox without changing
  fetched/pending token ciphertext or fetch direction. Nullable property17
  readerChangeId has UID1215215624103446605; every existing entity/property/index
  UID is unchanged. State4 means reader-owned, never projected or cloud-written.
  Duplicate evidence keeps its existing owner; known different versions and
  tombstones defer. No IDS receipt, resend or direct Message.text write is added.
- The worker now resumes inspected state2 independently of capture state0/1.
  Reader wake survives both tracked and unmarked pending pages after a crash.
  Lost native commit response cannot make fairness bookkeeping reject state4.
  One admission precedes ordinary reader drain. Its internal wake skips exhaustive
  unrelated retained-history repair and never recursively starts uploads. A
  fresh Found discovered during create preflight also wakes this reader.
- Popper provided61 transaction tests and the actual journal -> inbox -> applier
  -> canonical gateway regression. Original-row adoption, newer edit/retraction,
  rendered unsent state, reopen and idempotent replay passed. Generation2 then
  FAILED before the fix: retryable/semantic_inbox_fence_lost. This was a real key
  mismatch, not missing CloudKit data: journal uses change-generation-N after a
  reset while fence/context/attachment/repair consumers used change for all
  generations. Shared cloudSyncPersistentChangeKey now preserves the original
  producer format everywhere. No on-disk migration or old-generation fallback.
  Exact failing case passed after the fix; full gateway97 passed.
- Planck corrected independently frozen attachment/repair fixtures that wrongly
  labeled generation1 keys as generation7. N2/N3 acceptance and cross-generation
  rejection now pass:73 tests. No pre-fix red claimed for these two files; the
  gateway supplies the red/green reproduction. A duplicate-ID fixture error was
  corrected without weakening the resolver's ambiguity rejection.
- Parent passed113 changed-source tests,291 store/reader/key cases and61
  reset/lifecycle/attachment cases. These batches overlap in61 received-journal
  cases and must not be summed as independent coverage. Fourteen-file analysis
  has no errors/warnings (four test style infos); service analysis has five
  preexisting brace-style infos. Native and tests do not prove live remote sync.
- Popper and Planck changes reviewed/accepted, agents closed and verified
  not_found. Hypatia exceeded its bounded review without a patch; parent stopped
  and closed it, verified not_found, and completed the native tests. No dedicated
  worktrees/dependency caches were created. Sessions/transcripts retained because
  supported deletion is unavailable; shared databases were never edited.
- The treemap's378-line superseded checkpoint block was preserved in
  TREEMAP_PRE_RECEIVED_READER_2026-09-16.md and replaced with current state/links.
  FaceTime/Find My are not CloudKit completion gates. No credentials or content
  were added to documentation. Output sizing: build742,959,925bytes,
  .dart_tool62,981,389bytes; C:about28.8GiB free. No paid GCE, APK install,
  live account request, Alpha change or message deletion in this slice.
- Next: checkpoint integrated source, qualify a matching Windows/Pixel runtime,
  then received group/media/mutations and independent Apple-device convergence.
  Existing unknown-outcome writes stay readback-only. All received flags remain
  default-false; the overall CloudKit goal remains active, not production-ready.
- Integration16430e0f2b778124bbe43cdc2be0551b5e107292 is committed and pushed only
  to fork/agent/cloudkit-v2-received-origin-20260916. Working tree clean after
  that checkpoint; no automatic full build was triggered. Updated7 generated
  files still match the verified native artifact. No helper, native CI or local
  test/analyzer session remains active. The next runtime must match this API;
  existing Windows native hosts are not silently rebound to the new bridge.

### September 16 Windows qualification retry and selective cache purge

- Pilot13f388527 changes only the Windows workflow's trusted branch from the
  old update-seam to agent/cloudkit-v2-received-origin-20260916. Exact commit
  validation remains. Main's missing android-smsmms submodule was initialized
  at recorded36f34f48 for source preflight; no pointer changed. No GCP/secret/
  variable/signing modification. Local ValidateOnly passed source31fc2613b.
- Hosted Windows35152394873 failed before packaging:681 Dart tests passed,
  one canonical-adapter edit/reopen fixture failed applied-vs-retryable. It
  independently constructed a generation1 key despite a later generation.
  Parent reproduced the failure, repaired only that fixture in aa953639a,
  passed157/157 in that file, then the exact21-file Windows matrix682/682.
  No production checks were relaxed and no artifact from the failed run was
  imported. Corrected Windows35154038683 is active, watched by session42650.
- One mutex-owned offline copied-profile inspection found701 chats,13,969
  messages,2,516 attachments and24 confirmed outbox rows with no active leases.
  All three semantic checkpoints remain generation1. Original data.mdb size
  156,438,528bytes and before/after hash equality prove the source copy read
  did not change that database. No Apple request, IDS restore or outbound send.
- Windows profile reservations were exchanged with the independent Find My
  task, then released while builds run. Its results remain in that task; no
  stopped-sharing or key-delivery cause is inferred here. Pixel adb list empty.
- Popper's bounded group review accepted: preserve directv1 source bytes;
  add an explicit v2 received-group source, exact authenticated group-parent
  proof and matching raw/readback routes. Canonical Chat GUID and CloudKit
  group ID are distinct. Native/legacy current-sender shortcuts are rejected.
  No group implementation claimed; note retained in the current run evidence.
- User requested an agent purge unneeded project storage. Einstein's scoped
  audit was reviewed; parent narrowed mixed Cargo trees to an exact per-file
  manifest and rejected whole-tree deletion of DLL/EXE/PDB/LIB/EXP or evidence.
  Script validates resolved cache-only paths, no reparse/Git/data.mdb, no native
  builder, unchanged inventory and exclusive file opens before literal removal.
  The agent executed the approved script once. Removed22,588 files,
  6,050,275,183bytes (5.635GiB); observed free-space delta6,020,091,904bytes.
  No failures; all10,825 preserved files unchanged. Parent independently
  verified zero selected files remain and no preserved file-size changes.
  No directory/worktree/session or live profile data was removed. Regeneration
  from retained source/lockfiles is recovery; no new cache backup was created.
- Cleanup manifest SHA256473ceaaf5f5c254421455fa8cf9ec57fba3b7eaf7d94a7a8357b9b33aa88b56f
  and result are under build-evidence/storage-purge-20260916-luna. Live profile
  native DLL/ObjectBox data remain at the correct APPDATA/OpenBubbles path;
  the helper's shorter APPDATA path was corrected in parent verification.
  C:about34.8GiB free. Completed helpers closed; supported transcript deletion
  unavailable, so they remain protected. Native Windows run only remains active.
- Next safe resume: follow35154038683, verify its artifact/provenance and only
  then import exactsourceaa953639a and request a bounded shared-profile read
  window. Documentation-only descendant HEAD may temporarily select that
  committed candidate from a clean worktree for the exact-source importer,
  then restore the original branch. Never overwrite dirty source or use a
  mismatched existing DLL. Goal remains full production CloudKit, not complete.

### September 16 matched Windows live read and stable restart proof

- Run35154038683 passed21:44:33Z to22:08:35Z for sourceaa953639a/pilot13f388527.
 682 Windows Dart tests and51 native encoder cases passed, with selected native
  suites. Artifact10471535119 is35,535,525bytes, SHA256
  61a90ad51c1aa2adf83c66d2e97cb7c1415f815c7ff0a3969c0ded1138328e40.
  Inner runtime archive SHA7127cf8ef77b5b2de28e73ff010129235d5e872107c226fde745fa03dcc232e0;
  provenance SHA2f0e700940205b2153c24ee3b0c9364cca7fd9eb17762df4324964eb2f82a35d.
  All55 source inputs match exact declared Git blobs (53 WindowsCRLF forms),
  all13 log hashes match, and three ARM64 binaries/vendor ObjectBox pin verify.
- The strict importer temporarily selected clean committedaa953639a, signed
  with the established engineering certificate and restored the original branch.
  Signed DLL52887b284c590a19ec1a53c61ed24057ad802413d37cc344c64bdfb155d5edaa;
  signaturesValid, ObjectBox untouched. Earlier commentary's rollback statement
  refers to retained verifiedb9c567f archive/provenance, not an on-disk temporary
  transaction rollback directory: the importer removes that temporary directory
  after success. Parent verified the prior archive remains recoverable (SHA
  fd42c97f55025eedb7eb11c7bbc22e8a6c5210f493d829366481c9edf6325b34).
- A private pre-schema DB snapshot156,438,528bytes was copied under the profile
  mutex; source/copy/after hashes agreed:
  c7efacc0df66906ab1526bc15064f676f952fd4575d1126da051fd3248811c4c.
  Snapshot retained under backups/windows-reader-aa953-20260916, never uploaded.
- Live Dart sourcef560401345168bf43856ae0069016fb11f39abce has documentation-only
  differences from nativeaa953639a; native compatibility verified. Session
  339c757b0e6e5a370def532737d9daa5 fetched109/applied79, then0/0 at all-zone
  empty-terminal. Its two-pass stable gate remained unproven, correctly, because
  the first pass changed state. No expectation was weakened.
- Session9566ce363d14f37fbc81184116a7ae57 then passed two fresh-process0/0
  empty-terminal reads with retained total6282 unchanged and outbox24 unchanged.
  completed=true,stable_repeat=true. Both sessions remote_writes_enabled=false,
  content_exposed=false. Process cleanup confirmed; raw stdout/stderr deleted by
  the launcher, bounded redacted aggregates retained. Profile window released to
  independent FaceTime/Find My task. No IDS restore/send, re-registration, relay
  change, remote save/delete, Pixel install or paid GCE action.
- Retained classification from actual reports: chats94=13 out-of-scope saves+81
  tombstones; messages5076=3766 out-of-scope saves+811 still blocked saves+499
  tombstones; attachments1112=1011 still blocked saves+101 tombstones. Exact
  remaining saved-record count is1822. These
  are records needing classification/repair, not proof every item is recoverable.
  Current samples include missing chat/parent dependencies, unsupported extension
  payloads, malformed/ambiguous reply and association shapes. Windows feed/restart
  proof does not qualify all retained data, incoming writes or Android lifecycle.
- A source-only group draft is committed locally at6c66ea3f5 on
  agent/received-group-source-20260916 in agent-worktrees/received-group-source-20260916.
  Parent wrote four native files: explicit groupv2 capture/digest while preserving
  directv1; authenticated route-pair projection; opt-in typed/raw group comparators;
  synthetic cases for endpoint/origin/group alias/unknown-field behavior. Rustfmt
  syntax parse only, no native compile/test and no Dart/API producer integration.
  This is NOT enabled/merged. Tesla exceeded the bounded review with no patch;
  parent stopped/closed it, verifiednot_found, and wrote the draft. Worktree134MB
  is retained for unique ongoing parent work; no dependency caches/builds added.
- Live/runtime/source manifests: build-evidence/windows-reader-35154038683.
  All CI, live sessions and local tests are terminal; no active child. Next is
  bounded retained-read repair using this runtime, plus full received-group/API
  integration. Compatible Dart changes can reuse the DLL; native changes require
  a new qualified runtime. Main goal remains active and production incomplete.

### September 16 retained-record discriminator before further code changes

- Reused qualified nativeaa953639a with Dart source028cee5a. An evidence-only
  wrapper invokes the existing inspect-retained harness under the source,
  signature, ObjectBox, mutex and process-owner guards. Initial wrapper setup
  failed before account access because dot-sourcing overwrote its repository
  variable; corrected locally. Another attempt correctly stopped for the
  independent task's offline Dart process. That task paused its own test.
- Observation1dbbed6b1c3856122d6ead10bc606322 completed37 bounded cached-record
  cases. durable_state_unchanged=true, remote_writes_enabled=false, process
  cleanup confirmed, raw output removed. Evidence and the scoped wrapper stay
  under build-evidence/windows-reader-35154038683; no product change.
- Five sampled message dependencies now decode ready with one direct-chat
  candidate each; one is carrier out-of-scope and two retain unsupported
  association types. Eight attachment dependencies decode ready but each has
  zero parent candidates. Other sampled malformed/unsupported records remain
  retained. These counts are diagnostic samples, not whole-database estimates.
- Popper's source review was checked and accepted: service exclusion records
  only the physical retained identity, while children require a logical Message
  owner. Absence does not prove an excluded parent. Any exclusion join needs
  exact current-generation/current-version identity, not a stale map or title.
  Helper closed and verifiednot_found; no code or live activity from it.
- Parent rejected building more copied-replay infrastructure before exercising
  the existing production drain/full retained sweep. Requested and received an
  exclusive20-minute Windows profile window; no Flutter/live work from the
  independent FaceTime/Find My task until explicit release. Next run is read-only
  remotely, with normal fenced local projection and no excluded-chat replay.
- Cleanup receipts rechecked:22,588 files/6,050,275,183bytes removed, zero failures,
  10,825 protected files unchanged. Current C:free31.4GiB, not a new cleanup delta.
  The remaining idle native-test helper was already superseded by parent tests;
  shutdown requested after confirming its interrupted state. Its transcript is
  retained because supported deletion is unavailable. No repeated cache purge.

### September 16 full-sweep launcher logging correction

- Source34b049f32/nativeaa953639a launched drain5d98bacd921f51902a06f3db1b4c2964.
  The remote report obcs2-semantic-1789599164467798 records an empty terminal
  read in all zones and outbox unchanged. During the retained sweep the launcher
  stopped at dart_applier_output_overflow. No terminal sweep report exists;
  partial projection is not a completion claim. Owned processes stopped and
  raw temporary output was removed, confirmed by cleanup.json and process check.
- Cause found in New-DartApplierStartInfo: it scrubs OPENBUBBLES_* and RUST_LOG
  but omitted the distinct native WINDOWS_HARNESS flag. Native init_logger
  therefore selected full debug logging instead of the existing bounded filter.
  A metadata-only log scan counted33,867 INFO lines in the current rotated
  native log, without printing message content.
- Commit4759bf88e sets the missing native harness flag after scrubbing. No
  native/ABI, authentication, projection or output-limit change. New assertions
  failed21pass/2fail before the fix and passed23/23 afterward; diff check passed.
  Same qualified DLL remains usable. No APK or native rebuild is necessary.
- Retry2b06e810300b630e9cf4ffff013eff20 safely returned cloudkit_interlock_busy
  before sweep. It occurred within the documented five-minute durable lease
  after forced shutdown. No remaining owned tester processes; cleanup verified.
  Wait for normal expiry, not manual lease deletion or a bypass, before retry.
- Independent task was informed and still holds off Flutter/live profile access.
  Final cleanup recheck found0 deleted candidates present and0 protected-file
  metadata changes across10,825 preserved files. C:free31.1GiB at that check.
  The last interrupted native-test helper is now verifiednot_found.

### September 16 completed full retained sweep after bounded-logging repair

- After normal interlock expiry, source8e652804f/nativeaa953639a completed
  drainb2a08181fd98c588ec06171c6a9db0a1 in one process pass. Remote feed drained;
  retained projection incomplete. Final reportobcs2-semantic-1789599802849774
  examined798 blocked message saves across25 windows and1011 attachment saves
  across32 windows, plus one empty eligible-chat window. Zero further records
  applied in the final sweep. This is a complete diagnostic sweep, not full sync.
- Retained totals:chats94,messages5063,attachments1112,total6269. Compared with
  the earlier6282 baseline,13 message records left the retained backlog during
  these runs. The interrupted first sweep had no terminal summary, so no exact
  per-record/UI restoration attribution is claimed. Known excluded saves3779
  and tombstones681 remain separately counted;1809 saves still need repair or
  exact classification, not necessarily1809 recoverable iMessages.
- The complete sweep observed185 missing-chat references,68 current native
  carrier exclusions rejected because their previous failure differed,178
  message decoder dependencies,279 malformed message decodes and5 unsupported
  services. Counts are diagnostic events and may overlap. Attachments included
  810 ready decodes,195 malformed decodes and6 decoder dependencies; missing
  parents dominate, but do not imply an excluded service without an exact join.
- Outbox24before/after, remote writes disabled and no content exposed by the
  retained result. stdout407,113bytes/stderr0, well below unchanged limits.
  cleanup.json confirms processes stopped/raw output removed; parent independently
  found no remaining dart/flutter_tester/native-compose-tests processes. Profile
  and offline-Flutter window explicitly released to the independent task.
- pass-1.json SHA2562d4b3900ba43ef6d9c2f9347fc6fa272473beaddf79fab024e5d5d540c0fea5c.
  Evidence lives under the private profile's cloud-sync-v2/diagnostics/
  dart-applier-live/b2a08181fd98c588ec06171c6a9db0a1. No new runtime/native/APK,
  account reset, IDS send, remote mutation or paid GCE.
- C:free29.3GiB at closeout. Main local build1,751,785,941bytes and.dart_tool
  62,981,389bytes at the preceding check; active test output was not deleted.
  Cleanup remains the reviewed5.635GiB purge, not the fluctuating later free-space
  measurement. No active child; unique group draft/evidence/transcripts retained.
- Next discriminating step is a bounded exact-owner dependency inspection,
  not another unchanged full sweep. The remaining carrier-disposition mismatch
  and absent logical parent links need separate evidence and regression cases.
  Overall goal remains active; Windows read proof does not qualify production.

### September 16 post-sweep ownership investigation and context repair

- Previous goal turn was progress: qualified full sweep and corrected bounded
  logging. This turn reused one Muse Contributor helper for a bounded carrier
  disposition review while the parent inspected the remaining dependency path.
  OpenAI's delegation/test-calibration guidance was refreshed; no standing pool,
  new worktree, native build or broad repeated matrix was created.
- Fresh observation `bf3b650c5abcb120fd716f2ad4cb1da7` still finds the same five
  ready direct-message candidates after the full sweep. Inspector-only commits
  `737f9e4e9` and `09c2a5b1d` add a production read-only ownership proof and
  local-row/parent booleans. Observations `4e4930890561653c8dc10a48df1b2d60` and
  `f6241fb42aaf4e483736b8705da94572` each pass 37 cases. Native remains aa953639a.
- All five resolve one eligible Chat with exact durable ownership. None has
  a local Message row; every one has a declared extension-session parent and
  no association parent. Thus the diagnostic legacy-row mismatch is expected,
  not evidence of a timestamp mismatch. Actual parent row/proof availability
  still needs a targeted join; a missing remote base is not yet established.
  Eight sampled attachments have no local owner. Do not loosen Chat rules.
- Checkpoints/outbox and selected inbox status/retry/time/digest stayed unchanged;
  these checks are not a complete bytewise database audit. Raw output was removed
  and owned-process cleanup confirmed. The Windows/Flutter window was released.
  A separate orphan tester PID24668 belonged to the independent task's stopped
  offline suite, proven by its package/config paths and absent parent. Parent
  left it untouched; that task verified ownership, stopped it, and confirmed gone.
- Popper's classification review was checked against the native envelope binder,
  Dart result validation and ObjectBox commit. Fresh carrier decode binds exact
  retained bytes but not necessarily the latest remote version. A bare service
  enum does not authorize discarding previous dependency evidence. Its proposed
  bound classification/history receipt remains unimplemented; existing rejection
  stays intact. Reviewed helper closed and verified not_found.
- A separate concrete defect was reproduced: the early carrier-disposition catch
  bypassed the normal post-decode active-scope revalidator. Three tests covering
  previous unsupported-service, malformed and dependency failures all completed
  incorrectly before the fix. Parent added the existing authorization check
  before classification/retry metadata changes in commit `ea8d86b8b`. No category eligibility expanded.
  The affected two-file batch passed 152 tests, including all three regressions;
  analysis found no issues. No native/ABI/schema or remote-write change.
- The GCE pilot task reported its own explicitly user-approved paid infrastructure
  run. It confirmed this is not current CloudKit qualification and will make no
  additional paid run without approval. Main CloudKit neither launched that run
  nor adopted its older source/signing/infrastructure changes.
- Next: exact parent snapshot/map/latest-inbox correlation, followed only if
  necessary by a bounded authenticated-child-derived remote lookup design. Do
  not repeat the unchanged full sweep or fake writer/received-source authority.
  Received-group draft, full write/receive, Pixel lifecycle and independent-client
  display gates remain open. No main live/test process or active helper remains;
  C: free approximately 29 GiB at the last checkpoint. No additional deletion.

### September 16 authenticated parent locator and ARM64 qualification

- Previous turn was progress (scope-race repair and dependency evidence). This
  turn implemented an actual ObjectBox parent correlation helper and reused
  Popper for six synthetic database cases. Parent reviewed them, added physical
  locator/result-binding cases, and all nine helper cases plus 25 harness cases
  passed. Synthetic test stores were removed by their scoped teardown; no copy
  of personal data or extra worktree was created.
- Live observation 07740683eea5012339db223b59a80a8c, source a7b426a9b/native
  aa953639a, examined 37 records. Every sampled ready child (five extension
  updates and eight attachments) has zero exact/case-variant parent rows,
  current Message snapshots and record maps. The journal cannot be joined
  through a nonexistent map. Source checkpoints/outbox and sampled inbox
  metadata stayed unchanged, raw output removed, owned processes stopped and
  the profile reservation released. Remote absence is still unproven.
- Native source 8859a4f1aeac7c83554a3ca805177936340cabc0 adds a separate
  cloud_sync_dependency API module. It decodes only the authenticated protected
  child with cached PCS, selects a declared Message parent, recomputes its logical
  identity, derives Apple's exact salted record name inside Rust, and returns
  keyed metadata only. Account/client/store/container/source are revalidated
  after awaited work. It performs no remote fetch/save/delete, PCS warmup,
  staging or projection; exact remote lookup remains unimplemented.
- Popper supplied seven behavioral native tests and one cached-path contract.
  They exercise real canonical constructors, independent balloon/session IDs,
  replies/reactions/attachments, stale-install and substituted hashes, exact
  GUID case and container salt. Parent reviewed, wired the test module and
  qualified it in hosted run 35163901886. All 753 app, 351 rustpush, 11 Anisette
  provider and 40 protector cases passed. The helper is closed/not_found.
- Run 35163901886 completed at 2026-09-17T00:05:49Z. Artifact10474590417 is
  394079 bytes, archive SHA256
  f13a2b6ecf2c1c4b543eaac11c7eaeac5e51b2c25bb50becfdb5c717c98d739b.
  Exact eight-member whitelist and per-member hashes verified before import.
  New member is lib/src/rust/api/cloud_sync_dependency.dart; both generated
  guards pass. Committed-binding reproducibility was explicitly skipped, not
  claimed. Evidence staged under build-evidence/dependency-locator-35163901886.
- Dart integration 3c780a8d7bd1459988a95d4140942ce39ff63992 is committed/pushed
  only to the internal fork source branch. Two initial test-host typing errors
  (Object versus Arc client and BigInt versus platform i64) were corrected before
  the 34-case passing run. Analysis has only eight existing harness style infos.
  Locator results must match child IDs, generations, parent key and session;
  mixed/error/malformed results cannot select physical journal evidence.
- Windows pilot bb0411345 adds exact native test names, the new database test
  and source manifests only. A transient push failed; a later non-fast-forward
  showed the shared remote advanced to d5533dd1e. Parent preserved that branch
  and published its known Windows lineage under the separate
  agent/windows-dependency-locator-20260916 branch. Existing local asset_graph
  deletion was not staged, restored or removed. No GCP/signing policy changed.
- Windows run 35165381313 is now active for app3c780a8d7/pilotbb0411345,
  native-test-host/read-only. ValidateOnly passed. Never pair its new bindings
  with the installed aa953639a DLL. Follow the existing job, verify artifact
  provenance, import/sign under a reserved window, then use the private wrapper's
  explicit source/native/pilot/archive/provenance pins plus LocateParents.
  Wrapper parse and old 37-case report validation passed; the locator itself
  has not yet been exercised on the live Windows profile or Pixel.
- Parent request wrapper remains at build-evidence/windows-reader-35154038683/
  run-retained-inspection.ps1. Main local processes are idle; Linux watch75930
  completed and no helper remains active. C: free about27.8GiB. No extra cleanup.
  Full received/group/write/device/public-release gates remain open.

- Windows source-contract check passed and the existing job entered build/test/
  packaging. Watch session3481 follows run35165381313; no new runtime is installed.
  Documentation-only descendant8b5598b9f was pushed after that source pin passed,
  so the running job still builds exact app3c780a8d7. No new dispatch is needed.

### September 16 live parent classification identifies rejected headings

- Previous turn made progress and left verified Windows run35165381313 active.
  While it ran, Dart-only commitde1f9a2bd added exact cached-parent re-decode to
  the bounded observer. Its 25 harness cases passed; analysis has only eight
  pre-existing style infos. It preserves native identity checks and reports
  parent disposition separately from the child, with no projection or fetch.
- Windows35165381313 passed in24m36s for app3c780a8d7/pilotbb0411345. Artifact
  10474154655 is35575387bytes, outer SHA256
  7907b0534ca6171048f6da9986d0b75747a9d32cf7632d055ba99483599b01e7.
  Inner archive6c5a5c6eca087f901177899094db5c53d57c168fd8ef0f3acdefa81ba7130947;
  provenancecc6042f8cdd597a3d793e4f3765995933711f8320c7ca18819b00a4806e5e142.
  All61 input hashes matched declared Git blobs (2 raw,59 WindowsCRLF); six
  recursive submodule pins and13 logs verified. The actual ARM64 log records
  all eight locator tests;694 Dart and51 encoder cases passed.
- The old verifier's exact diagnostic count5 rejected the new13-case suite.
  Tooling71809eb67 adds a trusted caller parameter, preserving default5 and
  requiring explicit13 for this candidate. Synthetic verification23/import36
  cases passed, including refusal to infer counts from bundle metadata and
  forwarding through dot-source parameter preservation. No check was disabled.
- The reviewed new tooling was loaded, clean checkout3c780a8d7 selected for the
  unchanged exact-source import guard, then the original branch/HEAD restored.
  Existing signer signed only EXE/DLL, not vendor ObjectBox. Signed DLL:
  9aadb2bcc9c4abd040977c8db28ecd243736b63ff2275eada7296d6f75bbe849;
  EXE987364eefa5c1808441659691e6e40f0acfe334065df90aef95b23f1c103b046.
  Old aa953 runtime archive/provenance retained; no account or schema change.
  Detailed receipt: build-evidence/windows-parent-locator-35165381313/verification.json.
- Live cached-only observation78a51359654e103f086601d27790bb83 used Dart71809eb67
  and native3c780a8d7. All37 cases completed. The five extension children locate
  cached retained parents, rejected as unsupported_association_type. Two of eight
  attachment owners locate excluded SMS-family records; six are unobserved in
  the current journal. No remote-absence, restored-message or child-exclusion
  claim follows automatically. Selected inbox/checkpoint/outbox checks passed;
  raw output deleted and no owned tester remained. Profile window released.
- Same-run native logs contain seven type3/bare-reference shapes, matching the
  five parent re-decodes and two previously sampled type3 failures. Both range
  fields are present; text/attributed-body present; extension_class=apple_other;
  no reply. Exact range values and reference equality were not exposed. Only
  fixed, content-free shape lines were inspected, not message text or targets.
- Agent Reach's GitHub backend provided primary-source corroboration, reviewed
  by the parent: Beeper maps3 to heading and preserves linkedMessageID in its
  heading renderer. Fixtures prove own GUID can differ from the associated GUID,
  and show SQLite ranges(0,-1) and(0,0). These are not CloudKit protobuf fixtures.
  Do not impose self-reference/zero-only ranges or normalize a sentinel by guess.
  Sources: [type mapping](https://github.com/beeper/platform-imessage/blob/f28eab5ab4e5f874a4f29d0504b612e8c1accf03/src/IMessage/Sources/IMessage/Mappers/MessageMapperTypes.swift#L206-L210),
  [heading handler](https://github.com/beeper/platform-imessage/blob/f28eab5ab4e5f874a4f29d0504b612e8c1accf03/src/IMessage/Sources/IMessage/Mappers/MessageMapper%2BAssociated.swift#L25-L62),
  [associated fixture](https://github.com/beeper/platform-imessage/blob/f28eab5ab4e5f874a4f29d0504b612e8c1accf03/src/IMessage/Sources/IMessageTests/Fixtures/message_gamepigeon_associated.json#L6-L36),
  [invite fixture](https://github.com/beeper/platform-imessage/blob/f28eab5ab4e5f874a4f29d0504b612e8c1accf03/src/IMessage/Sources/IMessageTests/Fixtures/message_gamepigeon_invite.json#L6-L11).
- Pending implementation: explicit type3 heading representation through the
  supported app carrier, retaining its own identity and exact linked GUID/range
  fields, without making a reaction or unconditional causal/base dependency.
  Add native/Dart tests for non-self linkage and opaque range preservation,
  then retry the cached parent and descendants. No blanket reclassification.
- Popper's separate received-group review found an original_group_id-only alias
  can select two distinct group routes. Parent confirmed the OR-match in draft
  projection code; draft6c66 remains unmerged. Require a unique authenticated
  owner, not title/member heuristics, and frozen direct-v1 bytes before integration.
  Both bounded reviews were accepted as findings, not deployed fixes; helper closed.
- Windows watch3481 is terminal. No active main live/test process or helper;
  C:free about27.3GiB. Updated native host stays available for compatible Dart
  checks. Pixel, received/group/write and independent-client release gates remain.

### September 16 evening: heading compilation, relay diagnosis and Mac import

- Heading native source d1734c01d introduces explicit non-causal linked heading
  metadata, opaque optional uint32 ranges, and ten converter regressions.
  Parent-owned Dart decoder/projector/registry changes and two test files remain
  uncommitted and unqualified. Run35171127739 generated bindings but failed
  native compilation: E0004 in cloud_sync_transient_bridge.rs:2142, missing
  Heading arm in canonical identity validation. Artifact10475984769 exists;
  no import, new Windows host, APK or duplicate run was performed. Installed
  native/generated source3c780a8d7 remains the qualified baseline.
- User requested registration diagnosis. USB read of Canary20002227 captured
  IDS6005 at16:46 and no-identity/send6005 at16:51/18:46. No new relay-health
  exception is present in the latest Dart log. Stored relay state last checked
  2026-09-17T01:15:52Z=false, last success2026-09-15T06:17:15Z. Status probe
  reports no active legacy/semantic/logout/coordinator operation, auth_ready=true,
  outbox_state=blocked. This does not prove a healthy registration or safe queue
  discard. No reset, account repair, hardware import or Alpha mutation occurred.
- User clarified that Windows live testing can displace Canary on their shared
  iPhone relay. No current Windows live client was identified. Cross-platform
  relay ownership is now required by AGENTS.md. Zeno independently reviewed the
  two health-check legs and ambiguous error coercion; findings accepted as source
  issues, not proven event cause. No auth code changed. Helper closed/not_found;
  no dedicated files/worktree, unsupported transcript deletion not attempted.
- User supplied a fresh Mac export specifically for Windows. Independent task
  granted an exclusive profile window. An offline Flutter/native test decoded
  the export with signed DLL9aadb2bcc9c4abd040977c8db28ecd243736b63ff2275eada7296d6f75bbe849,
  source3c780a8d7 and matching generated API. One test passed in about10seconds;
  all eight protected profile files retained their SHA256 hashes. No account,
  network, APS or IDS setup ran. The code existed only in the invocation's
  process environment, not a source/evidence file.
- The Mac export is syntactically usable, but MacOSConfig validation is
  explicitly unavailable in this non-macOS build. Apple delegate authentication
  at auth.rs:1175 and IDS registration need that provider. The CloudKit-only
  harness avoids IDS restoration, but that does not prove renewable Mac-only
  credentials. Hardware remains unchanged; no live Mac login was claimed.
  Offline test source/evidence stays under build-evidence/mac-activation-20260916.
- Two old flutter_tester processes (42092/46880) belong to the independent
  FaceTime/Find My checkout, not the Mac probe. Their owner was notified to review
  them; this task did not stop them. Available C:space was about27.3GiB.
- Owner subsequently confirmed both were completed-suite orphans, stopped them,
  and verified shutdown. Parent's final process check found no Flutter/Dart/app
  process. The Mac-setup profile window is released; authenticated shared-relay
  tests remain paused while the user repairs Canary. USB is connected again.

### September 16 heading identity correction and Dart integration

- Prior turn made progress through phone evidence and the offline Mac import;
  the goal remains active. Live relay use stays paused. Parent repaired the
  concrete E0004 in validate_canonical_identity_bindings, recomputing both the
  optional linked Message hash and the heading's own Message hash. The link
  remains non-causal. A single bounded Muse Contributor max helper authored
  four synthetic native tests in cloud_sync_heading_identity_tests.rs; parent
  reviewed the entire fixture/test file, included it, and verified shutdown.
  No new worktree/cache or manually deleted session was involved.
- Artifact10475984769 (run35171127739/source d1734c01d) has exact eight-member
  generated inventory. Only four generated lines differ from installed3c;
  imported them and verified all eight contents plus both normalization guards.
  Failed-run generation is not native qualification. The installed runtime is
  unchanged and cannot be used for current heading application source.
- First heading run passed six and failed two. One fixture inherited an
  unrelated snapshot parent; source also failed to reject such mismatches for
  headings. Parent added the same actual-reply dependency check used by session
  messages and covered correct/mismatched reply snapshots. Reopen fixture's
  redundant unique ownership-proof insert was removed; the test now asserts
  the proof survived the reopen, with no reseeding.
- Ten focused heading cases passed, then the five-file affected integration
  batch passed377 in34seconds; analysis of seven changed Dart files returned
  no issues. Two frozen digest vectors cover linked heading with uint32MAX and
  unlinked heading with an independently present range length. Both Dart digest
  tests pass. Rust implementations must independently match these pinned values
  in the next hosted run. Rustfmt parse checks pass; no local Cargo was attempted.
- Official OpenAI subagent/test guidance was refreshed. Its effect was one
  disjoint test helper, parent-owned integration, and one affected batch rather
  than repeated full builds. All feature/public-release gates stay unchanged
  until the new source is qualified and the cached real parents are replayed.

- Correction66658db67a67d300bbadda75b4ff0ccde8f216f7 was committed and pushed
  fork-only. Hosted35173960820 runs with allow_generated_drift=false; strict
  regeneration, native compilation and application Rust tests passed by02:33Z.
  rustpush/provider/protector checks are still active. Watch35990 follows it.
- With the GCE task owner's no-overlap acknowledgement, parent changed only
  the original pilot's Windows builder: four exact heading identity cases,
  two heading converter spot cases, source preflight routing for included files,
  and three additional provenance inputs. ValidateOnly passed against66658db67.
  Commitf21cf96314ad86a5c039aa5d9fc7880057f995ec was pushed only to
  agent/windows-dependency-locator-20260916; shared agent/gce-runner-pilot and
  pre-existing asset_graph deletion remain untouched. Windows35174173364 is
  active, source checks passed, watch39651. These two hosted platform jobs run
  in parallel; neither is a new paid GCE run or an APK installation.
- Read-only group reviewer Locke identified the current direct-only caller
  chain and the absence of a complete group-owner resolver. Parent accepted the
  callsite inventory but rejected its proposed bare DTO list and later final-
  page witness: they can omit an owner, and a terminal delta page is not a census.
  No guessed identifier normalization is accepted. Preserve original-alias
  support as an explicit remaining requirement with real scoped ownership
  evidence. Draft6c66 stays unmerged; no safety check was weakened. Helper closed.
- C: dipped below25GiB, so parent audited only current .dart_tool/build outputs.
  They total about2.63GiB; twelve compiler cache files dominate. Prepared exact
  ten-file manifest, preserving the newest unit/live harness caches and all
  protected artifacts. Execution policy rejected the deletion command before
  process launch. Remeasurement confirms all ten targets remain: zero reclaimed,
  about24.2GiB free. No workaround attempted. Manifest under
  build-evidence/cleanup-heading-20260916; no source/profile/session deleted.
- A fresh USB status probe is unchanged: no active sync/logout/coordinator,
  auth client present, outgoing queue blocked, relay last checked01:15:52Z=false.
  No registration, hardware or outbox mutation was attempted. Live Windows relay
  usage remains paused while Canary repair is unresolved.

- Native qualification35173960820 completed successfully at02:37:13Z, source
  66658db67a67d300bbadda75b4ff0ccde8f216f7, duration17m51s. Logs explicitly show
  all ten converter heading cases and four identity-validator cases passed.
  Totals:767 application,351 rustpush,11 remote Anisette provider and40 protector
  tests. Strict committed-binding regeneration passed, not skipped. The two
  pinned heading digest vectors therefore agree in independently executed Dart
  and Rust implementations. Artifact10477413177 is394111bytes, outer SHA256
  6cd3e6379f03f8c2ea2347d99da94f8434980108317f9f7d074b1e8b3cdb4ef1;
  metadata recorded, archive not redownloaded because strict reproduction already
  verifies committed content. Linux watch35990 exited0. Windows35174173364 and
  watch39651 remain active; no new native runtime or APK has been installed.
  Main handoff-only descendant0e7316d60 does not change the native boundary.

### September 16 Windows heading qualification and Canary activation diagnosis

- Windows35174173364 succeeded in26m23 for source66658db67/pilotf21cf9631.
  Verified64 source inputs, six recursive pins,13 log hashes and three ARM64
  binaries. Inner archive SHA256
  `de908ce161853c2bd1c8d54321fdf6470921c12fc1f79e9efab34bc90da1bf40`,
  provenance `d94f1336271afd07a917596c062bf52aed5bfe68fe69affb4594cd9bd0bf4816`.
  Installed with existing engineering signer; signed DLL
  `c04cc711008999a3871cd7ef13306c2bb48e334c04215fdae34d10c6b0dbb377`.
  48700 protected profile files retained their hashes during import. Local15
  native cases plus one actual-DLL Flutter encoder test passed; processes exited.
- User approved exclusive Windows read-only test. Observation
  b0e626b0a5a3e252c4ef2d5fc3130900 completed37 cases, durable state unchanged,
  no remote writes, raw output removed and process cleanup verified. Five cached
  heading parents now reach extension Name/Malformed instead of unsupported
  association. Seven message cases total remain extension-deferred. Six attachment
  parents remain unobserved; two SMS parents intentionally excluded. No message
  restoration claimed. Windows reservation released after the observation.
- Kepler's primary-source review supports heading text being independent of a
  generic balloon payload. Main parser still requires string `an`; external
  implementations alone do not establish the real cached CloudKit field shape.
  Findings accepted, no speculative parser relaxation, helper closed.
- Pixel repeatedly reported interlock-busy while sync/logout/coordinator were
  idle. Stable offline snapshot preserves702 chats/11917 messages/2416 attachments
  and nine queued operations. Stored lease was about28h expired, with no active
  operation-file handle observed. User approved one restart only; no data clear
  or lease edit. Busy advanced to legacy/V2 conflict, then user setup reset left
  no hardware/id file. GSA, keychain and database remain. Alpha unchanged.
- Relay version endpoint comparison using the same saved code/origin: Windows
  application token200, empty/missing application token401. Canary710 developer
  workflow omits that compile define, unlike Alpha/Beta. The existing uninstalled
  f027 APK has the same omission, so installing it is not an activation remedy.
  Fresh Mac export decodes offline but non-macOS validation remains unavailable.
- User approved an additional restart plus private staging of the known relay
  configuration using the debug VM and normal config/selection API. No Windows
  keys/account/messages will be copied. Helper is outside source, secret-free,
  inspect-first with exact origin/page/code guards. Ohm reviewed it read-only;
  accepted async-void timeout warning, API scope preflight and host verification.
  No apply yet. Independent task acknowledged Pixel/relay exclusivity. C:24.04GiB;
  no deletion or paid build. Final provisioning result must be appended.
- The approved second restart was rejected by execution policy before launch.
  No workaround attempted. Read-only check confirms Canary PID8013 unchanged,
  no VM-service marker, no ADB forward, and another app foreground. Provisioning
  has not run; next step requires the user to force-stop/reopen Canary and leave
  the self-hosted activation page visible. Ohm shutdown verified not_found;
  no dedicated worktree or files to remove, supported session deletion unavailable.

### September 16 source-only progress while Canary restart awaits the user

- Read-only USB check confirms the old PID8013, not a completed manual restart.
  No restart workaround, provisioning, registration, outbox or live relay call.
  Independent task acknowledges its live clients remain paused.
- Accepted/reviewed Muse helper Epicurus's bounded relay fix in db1fe6d76:
  official-origin requests fail locally when build app access is absent; custom
  origins retain their existing behavior.401/403 no longer proves a rejected
  device code. Parent required concise wording and URI/default-port equivalence,
  then verified the return precedes both HTTP and native setup calls. Malformed
  non-string version keys return a classified failure instead of throwing.
  Sixteen validator and four secret-contract tests pass; parent Dart analysis
  clean. No token/CI changes. Helper closed and verified not_found; no dedicated
  artifact/worktree to delete, unsupported session deletion not attempted.
- b03c7bc16 adds a diagnostic discriminator for the actual Name/Malformed case:
  six fixed field types, with fixed wrapper classifications, not raw values.
  It preserves required-name decoding and every existing archive bound. A native
  regression covers absent, wrapped, scalar and over-limit cases. Rustfmt passes;
  compilation/execution still pending hosted qualification. Windows schema4
  aggregate parser passes24 cases and drops unrecognized/injected field values.
  This prepares one informative observation, not a speculative parser fallback.
- Agent Reach's GitHub backend confirmed prior Windows35174173364 completed
  successfully and no feature run is active. Native changes need a new exact
  runtime; do not weaken the fast-loop compatibility guard to reuse66658. No
  APK/paid GCE run, no local Cargo build, C:about24.17GiB free. Commits use skip-ci
  to prevent unrelated APK builds; only explicit hosted qualification is planned.
- Committed handoff5fdefad3a and pushed the fork-only trusted source branch.
  Windows35181742445 dispatched once through unchangedf21 sidecar; exact source
  and source-contract preflights passed. No APK, signing changes or profile use.
- User explicitly renewed GCE approval for the new system. Its owner verified
  workflowd5533dd1e does not yet allow the current source branch and has no
  combined no-APK test mode. Parent authorized the smallest isolated workflow
  patch for review before push/dispatch, preserving lifetime/cost/cleanup gates.
  No GCP/IAM/secret/infrastructure changes; no paid run as of this checkpoint.
- Native source inspection found pretty_env_logger writes stderr, but the
  Windows aggregate collector inspected stdout alone. Commit99495e3ba accepts
  both bounded streams and persists fixed classifications only.25 PowerShell
  checks passed, including stderr-only output and private-content rejection.
  The private retained wrapper now saves native-diagnostics.json before its
  existing raw stream cleanup; syntax check has zero errors. This is a real
  observability fix, not additional restored-message or runtime proof.
- GCE owner implemented14c2a16ce in its isolated pilot: allow this trusted source
  branch, combine binding/app-Rust/Dart/PowerShell qualification, and explicitly
  skip Android/APK/signing for the new mode. Parent reviewed the diff, selectors,
  source gate and outcome requirements, then authorized one16-vCPU Spot run.
  35182317779 started at exact app5f; source checkout/verification and cargo-check
  passed, selected suites active. Owner retains lifecycle and cost responsibility.
- Final source-specific audit found inherited generated-file lists omitted
  cloud_sync_dependency.dart and cloud_sync_chat_identity.dart. Parent sent a
  hold, but dispatch had already occurred. The running job remains useful for
  Rust/Dart, not complete current binding reproduction. No cancellation that
  could orphan cleanup and no duplicate full run. Parent rejected a dependency-
  only correction, reviewed whole-tree correctionc46ba12, and approved publishing
  identical tree0e219e811798a792d03e486661f9787e6231eb11 with skip-ci message.
  Published pilotfab604fc7119b7d489caf39e96619d59d3c3e697 is a fast-forward from14c2.
  It guards/uploads all lib/src/rust and three Rust generated outputs. Synthetic
  tracked-module modifications and a new untracked module were all detected;
  fixture restored and Git-aware temporary worktree cleanup verified by owner.
- Main756121b21 mirrors full-tree drift detection, including untracked outputs.
  Parent actionlint exit0, diff-check clean. Historical strict-generation claims
  are limited to their explicitly enumerated output lists; do not promote them
  to full-tree proof. Future actual native repair builds will use the correction.
  Windows35181742445 remains active, watch60611, no runtime imported yet.
- USB disappeared, wireless192.168.68.50:38787 remains connected with PID8013.
  User restart/private activation staging still pending; no secret provision,
  account mutation or message deletion. C:24.29GiB free; scoped local compiler
  cache32,094,223bytes. All main child agents closed/verified, evidence retained.

### September 16 optional extension-name failure proved in the matched Windows loop

- Windows35181742445 passed in24m15s. Artifact10480214202 outer SHA256
  `8a89578ef025b6a603d9e9d0cbe0b513e71d72d4c6cac19a064816b9f08a5080`;
  exact16-member safe inventory extracted. Inner archive
  `541ab4925f36f3c5ce2c146e512f3df81343a7c639bfcce34093276dccc4d307`,
  provenance `343e3b02222ac0a24ecca70c3bac7f6ddcda5d5302a3938362c0bc1391185169`.
  Verified64 Git source inputs(2raw/62WindowsEOL),6 recursive pins,13 actual log
  hashes,3 ARM64 binaries. Logs prove704 Dart,51 real-DLL encoders and33 extension
  cases including the new shape test;17 diagnostic cases passed. No missing
  success marker inferred from an incompatible log reporter: native codec log is
  JSON testDone/done, Dart qualification log reports704 directly.
- Imported source5f using existing signer, source checkout temporarily pinned
  then restored to27f719d70. Signed DLL14d421aba82c292c01e9f3bc8175e295d598e115ce32e604b5f0b841625e8f3e,
  testEXE8a9d24168437ef08750b02c0be59589ddf2e255cf3cd902b26ebf0e8760a1553.
  All15 checked account/keychain/database hashes unchanged. One exact installed
  native shape test and one actual-DLL Flutter encoder smoke passed; processes
  exited. Original vendor ObjectBox not signed, previous66658 archive retained.
- GCE35182317779 completed successfully at immutable app5f/workflow14c2. App Rust,
  full Flutter and existing PowerShell outbox contracts passed. Native generation
  and cargo-check passed; only the inherited enumerated-files drift check ran.
  Do not call it full-tree reproduction proof. No APK/Android JVM/signing step.
  Owner verified VM lifetime16m07.729s, delete response and zero GCE instances;
  parent verified cleanup job success and repository runner count0. Estimated
  compute$0.0769(about$0.08), not invoiced total. No duplicate run dispatched.
- With a newly acknowledged exclusive relay/profile window and fresh Canary
  setup_finished=false/auth_ready=false/idle preflight, ran one cached-only
  retained observer.5cb1823cf2aeb48811b03bf37a8fb434 returned37 cases with unchanged
  durable state/no remote writes. Captured stderr aggregates prove all7 extension
  Name failures: absent name, NSURL URL, absent app ID, string display/layout,
  NSDictionary userInfo. This is missing optional display data, not evidence of
  bad account encryption. Five are cached parents of extension children. Raw
  streams removed and owned processes gone; reservation released back to the
  Canary-setup hold. No phone registration or message mutation.
- Parent implemented optional native app display name and sparse template text
  labels. No fake title, identity/session default, unsupported layout acceptance
  or malformed-present-value coercion. JSON v1/v2 stays unchanged, using existing
  empty-label strings; original presence stays in the protected archive. Tests
  cover sparse fields, bad types, missing URL and layout/userInfo pairing. Removed
  old test assumption that all six template captions were mandatory. Native
  execution pending; Rustfmt and targeted Dart analysis pass. Ampere is reviewing
  exactly this delta, no broad audit or local Cargo/APK build.
- find-docs/Context7 retrieved Apple's [template layout](https://developer.apple.com/documentation/messages/msmessagetemplatelayout),
  [caption](https://developer.apple.com/documentation/messages/msmessagetemplatelayout/caption),
  [image subtitle](https://developer.apple.com/documentation/messages/msmessagetemplatelayout/imagesubtitle)
  and trailing-caption APIs: display properties are optional/nil. This informs
  omission handling only. It does not document private CloudKit field names or
  prove those exact seven archives' remaining layout fields. Current keys come
  from the existing rustpush/parser schema. Real re-decode is still required.
- Storage audit found build/test_cache2,620,715,360bytes, .dart_tool62,981,389bytes;
  C:about20.86GiB free. No deletions; do not infer that all concurrent disk usage
  belongs to this task. Keep full suites on the approved ephemeral cloud runner.
- Ampere independently reviewed the exact decoder/test diff and redacted shape
  aggregate, with no data/network/device access or execution. No blocker found;
  parent accepted review, verified no loss of class/type/identity/budget checks,
  and committeda7911bd7a837ef2f007e8c8ba10d78f8e1b1c2c7. Helper closed/not_found,
  no dedicated worktree or files; supported session deletion unavailable. New
  source remains unqualified until GCE and matched Windows execution, not a
  restored-message claim. No further live window currently reserved for Windows.
- Pushed exact sourceb9ebb102e (a791 repair + docs) to trusted fork branch.
  Windows35185153466 dispatched once onf21/native-test-host/read-only and GCE
  owner dispatched35185177773 on correctedfab604fc7/cloudkit-qualification.
  Both source-only; no APK, no outbound flags, no live credentials uploaded.
  GCE runtime cleanup/cost remains with its owner. Source pin must stay exact
  until checkout gate passes. Averroes classifies21 remaining unknown sample
  results using redacted observations while builds run, no edits or live access.
- Condensed the current treemap by moving300 lines of superseded build/runtime
  checkpoints verbatim into TREEMAP_PRE_OPTIONAL_LABEL_REPAIR_2026-09-16.md.
  Exact body comparison passed. Replaced them with actionable architecture,
  unresolved received/group/retained work and archive links; release gates and
  current evidence remain in the treemap. No historical evidence was deleted.
- Averroes classified all21 unknown samples at decoder quarantine throw460:
  5 unsupported-service,7 unsupported-message-type,1 malformed-parent,
  8 attachment malformed-record. Parent accepted the source/category inventory,
  rejected linking equal aggregate counts to the7 name failures, and rejected
  a claim that a name-only change could repair attachment failures before parent
  probing. Agent withdrew both inferences, made no edits, and closed/not_found.
  Known quarantine category is not proof that a record may be excluded.
- Reporting repair797d6210c attaches the typed native quarantine reason to its
  exception and adds exactly14 reviewed code strings to the report allowlist.
  Category, retry/admission and out-of-scope behavior stay unchanged. Tests
  freeze every enum mapping, reject appended/private/unreviewed content and
  verify these codes are not Canary-retainable dependency permissions.112
  focused Dart decoder/safe-failure/prepared-extension cases passed; analysis
  clean. This Dart-only descendant is separate from in-flight nativeb9 evidence;
  it requires no new native build. All main helpers are closed and verified.

### September 16 late: optional-label repair restores real Windows rows and survives restart

- Corrected GCE35185177773 passed at exact appb9ebb102e/workflowfab604fc7:
  full generated-Dart subtree reproduction, generated Rust check,770 app Rust,
  3941 Dart with5 skips,14 semantic and3 evidence PowerShell checks. No APK,
  Android JVM tests, signing, live credentials or account access. Owner verified
  VM lifetime15m06.835s, deletion and zero project instances; parent verified
  completed success and zero GitHub runners. Estimated compute$0.0720(about$0.07),
  not a final invoice. No duplicate build.
- Windows35185153466 passed in25m25s at appb9/pilotf21. Artifact10482492949 outer
  SHA256c3748d31b0671b4b09867570e625370e752466e6aa1f4945aff960ac16f6a8de,
  innerd33a581a7cebd140ecad941288cb4233c2a24ea190bbca4e0effb05be8ecf642,
  provenanceb011e9db61aa3acda6d101920f88ad3f826c0be3b55f5de4f1c1c5707e6d3783.
  Verified16 outer members,64 Git source inputs,6 recursive pins,13 log hashes
  and3 ARM64 binaries.705 Dart,51 DLL encoders,17 native diagnostics and35 native
  extension cases passed, including sparse success and strict rejection controls.
- Imported/signed b9 using the existing signer. Current DLL
  2f960b7365ba9d87f25a87effd92cf30916b3faea008e644c84a153c21422919;
  testEXE47f295c249addeb9af79ca6ca6fa16c654b4fc0a295090cdf67514b77d5d6296.
  All15 checked account/database hashes unchanged during import. Three installed
  sparse-layout cases plus one actual-DLL smoke passed. Previous5f bundle and
  source provenance remain rollback material; no device APK or keys copied.
- After explicit peer reservation and fresh Canary signed-out/idle preflight,
  observation1a6913ac507a0658b047646403c53da4 rechecked the same37 cached entries.
  Both standalone extension failures became Ready; all5 previously failing
  parent-decode checks became Ready. These are7 decode checks, not proof of7
  unique messages. The21 other quarantines are now reported by their exact native
  reason, unchanged in classification. State unchanged, remote writes off, raw
  output removed and process cleanup confirmed.
- Reserved the normal local-projection window separately. Preserved an idle,
  hash-stable157,138,944-byte ObjectBox rollback snapshot before the operation.
  SHA256a48f405fcfa28eea9d6fb1f8c336829851f8f0f313cfdd9c8d7c392f90c53789;
  private path/manifest under build-evidence/optional-label-projection-20260917.
  No restore is automatic. Normal draincb040c7a12c340ac4bb14fd0e750c1c1 completed
  one process: remote fetch0; initial replay applied9 message/9 attachment changes,
  retained sweep applied5 further changes. Retained6246 remains incomplete;
  outbox24->24. No remote writes/deletes or IDS sends, raw cleanup confirmed.
- Independent offline before/after comparison reopened disposable copies and
  verified14,044->14,058 Message rows and2,530->2,539 Attachment rows. Every old
  row ID remains. Outbox IDs/operation IDs/states/update timestamps are identical.
  All14 new messages contain display text and parseable app metadata; no Unicode
  replacement characters or payload parse errors. This is structural persistence
  proof, not a visual Pixel/Windows GUI claim. No text/names/IDs printed. Original
  hashes remained unchanged during inspection; disposable working copies removed.
  Result: build-evidence/optional-label-projection-20260917/result.json.
- A separately reserved cold-reader pair1a35a2802cd2848458fcfe4ef2387933 then ran
  two fresh processes: both fetched0/applied0, retained6246 stable, outbox24 stable.
  No duplicate work observed, no remote writes, raw output removed, processes
  gone. Both Windows/profile/relay reservations released; no standing lock for
  the pending Canary user restart. Peer must request before new shared live use.
- All helper agents closed and shutdown verified. All watches/smokes/observers
  (81248,14224,17240,99219,74157,32085) are terminal. GCE VMs/runners deleted.
  C:about20.47GiB free; no cleanup of protected logs, snapshots or sessions.
  Goal remains active: full retained repair, incoming/group/media/write gates,
  Pixel activation/lifecycle/visual checks and independent-client proof remain.

### September 16 late: bounded attachment-rejection discriminator

- Previous goal turn made real progress through live restoration and cold-repeat
  proof. Current task remains active; no completion/blocked claim. The8 sampled
  attachment malformed-record cases are the next independent read diagnosis.
- Native trace showed the same quarantine can occur before typed conversion
  (missing cm or failed decrypted-plist presence capture) or inside the converter.
  Sourceba47b1f0973d1b8fdbc51cdd38a487d3fa0e1e43 adds closed secondary detail for
  both layers using the existing optional diagnostic bridge field, no new API.
  Original disposition/category and validation predicates stay unchanged.
  User-info details distinguish empty/mixed media modes, inline fields and MMCS
  validation sites without carrying actual values. Later identity normalization
  cannot be mislabeled as the earlier converter failure.
- Parent added native success/defer/quarantine controls and a4096-combination
  reference comparison against the previous user-info predicate. These tests are
  authored, not executed yet; Rustfmt syntax parse passed without reformatting
  unrelated source. No local Cargo build or schema change.
- Muse Ptolemy edited only semantic_diagnostics.dart and its test. Parent reviewed
  all30 exact details and13 rejection cases, corrected a test that claimed
  admission proof while testing only diagnostics, and required actual primary-
  failure/retainable non-membership checks. Agent13 tests passed, combined parent
  decoder/diagnostic64 passed; analysis clean. Helper closed/not_found, no unique
  workspace/cache produced; supported transcript deletion remains unavailable.
- Installed nativeb9 remains unchanged. No live/window/device action this turn.
  C:about20.5GiB, previous scoped cache audit still applies; no deletion performed.
  Plan: one source-only GCE qualification plus matching Windows host, then the
  existing cached-only observer. Do not weaken parsing before observing detail.
- Exact sourcef43919ba3cbf18599be8d1270924293cae339aae dispatched once to
  Windows35192422648(pilotf21) and GCE35192463601(correctedfab604fc7). Both exact
  source gates passed. GCE is source-only/no APK and owner retains cleanup/cost
  responsibility. No live account/device/projection activity in this iteration.
- Sartre reviewed the received lookup/adoption chain without edits or live data.
  Parent confirmed location derivation uses received GUID plus container user ID,
  although preparation currently requires a direct Chat first. Accepted that
  coupling inventory, not the broad safe/preferred split claim: raw comparison
  needs a chat-derived expectation, native Found staging revalidates chatSource,
  and Dart adoption still checks a restored direct parent twice. Captured a
  proposed read-only Found discovery/ordinary-reader ingress design with no
  equivalence/create authority; group capture and NotFound write rules unchanged.
  No implementation enabled. Helper closed; no unique files/worktree created.
- GCE35192463601 completed successfully at exact f439/workflowfab604fc7. Whole
  generated-tree reproduction and Rust bridge check passed.774 app Rust,
  3946 Dart(+5 skips),14 semantic plus3 evidence PowerShell cases passed. Owner
  verified each of the4 new native diagnostic tests once as `ok`, including
  all4096 comparison inputs. VM lifetime15m53.746s, estimated compute$0.0758;
  cleanup job succeeded, GCP inventory0 and GitHub runner count0. No retry, APK,
  signing or live credentials. Parent independently saw overall success and0
  repository runners. Windows35192422648 remains active; no new host installed.
- New ADB inventory is empty. No phone restart/provisioning or account call was
  attempted. All helper agents remain closed. Current goal turn made qualification
  progress; no blocked/complete status asserted. C:about20.5GiB free, no deletion.
- Windows35192422648 passed in27m23s. Artifact10485377244 outer
  cec1750d9670f45e11633e0569363853df8145c66135fb8f66162eb38e8809b7,
  inner98ad6e09b197b02d4e44a4686aa2d99da24f5a30956961fdf8194b81bb7b8d66,
  provenance8f3f15610cb460f4f966940d750c0b6e968bd507923e13a9eb4ddab077a3ed14.
  Verified16outer members,64Git inputs,6pins,13logs,3ARM64 binaries;710Dart,
  51real-DLL encoders and native scopes pass. All3 new converter tests appear as
  ok in their log. Proof at build-evidence/windows-attachment-diagnostics-35192422648.
- Reserved an offline-only profile window with the independent task, imported
  exactf439 under the existing signer, then restored source checkout6173d7a7d.
  SignedDLL4bfdd1218ca2559c5ea5e2a756111a0432030bc1ed96da291de8d426b4c77084;
  EXEece1445af4a491b8709055069ef99b7d5deb2fa029a9b530664fb7de43ca5a97.
  All15checked account/database hashes unchanged. Four installed native tests
  including4096comparison inputs and one actual-DLL smoke passed. b9 retained
  as rollback; no profile/relay/network call occurred during these offline tests.
- Pixel remains absent from ADB. Asked user whether Canary is still at activation
  or now signed in before the next shared-relay test. No f439 live observation,
  reset or private provisioning attempted. Watch44222 and smoke96533 completed,
  no owned process remains, offline window released, no standing lock. C:20.18GiB;
  no cache/evidence deletion. This turn made artifact/import validation progress.
- Safe-alternative audit: Windows harness `_initialize` skips account setup only
  for projection viewers. Retained inspection uses setupPush, makeAnisette,
  restoreAccount and makeCloudkit. Encrypted read-auth cache can restore locally,
  but the existing path is not guaranteed network-free: APS setup runs and stale
  credentials can trigger MobileMe refresh. A local viewer cannot diagnose raw
  retained attachment records. No fake account/connection or gate bypass added.
  ADB remains empty; Canary sign-in question unanswered. No live request, account
  mutation or duplicate build. The source check rules out a ready-made offline
  shortcut; live preflight remains pending user state confirmation.
- Blocked audit completed September17: unknown Canary sign-in state persisted
  across three consecutive goal turns since the diagnostic runtime was ready.
  Fresh ADB list empty, source clean atf6b5b0849, no owned Flutter/Dart process,
  Windows35192422648 and GCE35192463601 terminal success, repository runners0.
  No live test, account repair, data reset, new build or network workaround.
  Marked the existing production goal blocked, not complete, awaiting Canary
  state confirmation or Pixel reconnection. Resume with the already-qualified
  attachment probe under a fresh shared-relay reservation; other release gates
  remain open. C:about20.18GiB free; all helpers closed, evidence preserved.

## September 18: user-directed Muse primary ownership handoff

- User requested that existing task `01a0abe1-9bbe-71b2-a9ce-4d4578022b0e`
  (facetime & find my) perform primary remaining OpenBubbles work, with this
  supervisor receiving checkpoint messages for periodic review. CloudKit stays
  the production priority; this is not permission to discard its other work.
- Verified clean CloudKit source `7aa70b1617669d55bca7c9da38ebd2c2e16e3c7c`,
  branch `agent/cloudkit-v2-newest-bootstrap`, no matching local application or
  Flutter/Dart process, and C: free space 26.75 GiB. No live account/device check,
  build, cleanup, source fix or runtime change occurred during the handoff.
- Updated AGENTS.md and the current tree to transfer CloudKit write ownership
  to that task, replace the obsolete read-only restriction, preserve separate
  feature work, and define evidence-based review checkpoints. Primary task owns
  shared-profile scheduling; supervisor starts no competing implementation loop.
- Dispatch uses exact model `meta-model/muse-spark-1.3-contributor`, effort max.
  A dispatched instruction alone is not proof of execution; verify the task's
  acknowledgement and report any routing failure before claiming takeover.
- Handoff committed locally as `764eba960`. First dispatch turn
  `01a0b500-d0d2-7940-a1d4-f876af9cac4a` failed before execution with provider
  `unknown parameter access_programs`. One alternate configured Muse Contributor
  route, `opencode-free/muse-spark-1.3-contributor-free`, failed during remote
  compaction in turn `01a0b501-676b-71d0-a313-e476d865f52c` with the same error.
  Both turns are terminal failures, not active work. No third unchanged retry.
- Existing repair task `01a0687b-43f0-7a22-999f-260c60ae3d42` was assigned a
  bounded read-only diagnosis using Luna high. Its latest user instruction to
  keep OpenCodex off remains in force. No provider/service/security change is
  authorized by that diagnosis; report the smallest supported correction and
  required approval. The primary ownership assignment remains pending execution.
- User then explicitly instructed "Keep open codex on" and asked the Muse repair
  agent to fix the failure. Forwarded this new authority to the same repair task,
  superseding the initial read-only/no-enable restriction. It owns the smallest
  compatible repair, service-state preservation and actual Muse tool/compaction
  verification. Application work stays pending until that checkpoint succeeds;
  no access safeguard bypass or unrelated configuration change is authorized.

## September 20: unknown-only attachment ui policy fix qualified and live-compared

- Policy commit c7924eb6b: present-but-unrecognized ui (no recognized MMCS/inline fields) continues conversion like absent ui; the protected lqa/ALL_ASSETS lane stays authoritative for the body. validate_attachment_user_info and all other rejection branches unchanged. New raw-cm test proves Ready AND Materializable through typed decode for absent/empty/descriptive/unknown-3/unknown-4 ui, plus malformed-owner continuation and wrong-type decode failure.
- Fixture correction baba20b16: synthetic auth-probe status handshake before timed waits; delayed-startup case; actual failure codes surfaced. Probe file passes locally. Production launcher untouched.
- Qualification run 35537790499 success (sidecar 5d16015, native-test-host read-only): converter 99 green incl. new policy fixture, all six lock cases, encoder 51, diagnostic 17, timestamp 7, zero failures. Artifact/source/provenance hashes verified; signer 82405579; import and local smoke green (lock 8/8, shape 2/2, policy 1/1).
- Offset0 comparison sample c78014c2 vs baseline 4df5a8f7 (LocateParents=false both): 37 cases, all 37 record hashes match; the exact 8 UserInfoEmpty attachments each match one new Ready case. Ready total 23 (16 attachments, 4 messages, 3 reactions); remaining malformed-parent/unsupported-type/service/SMS persist. Rejection-only shape log empty as predicted. Durable unchanged, remote writes off, cleanup confirmed, raw streams removed.
- Decoder Ready is proven for these 8; body download, projection, and UI restoration are not. Auth cache renewed FCC94201 to 49410c50 (routine same-account renewal); message/data hashes unchanged. Rollback bytes and receipts preserved in staging.


## September 20: protected-native body proof for one unblocked attachment

- Caller commits 278e7479e/09b135dea/87191bc91/5efa84ff1/6a9e0c9f4 (test-only Dart, no native/API/FRB changes): guarded dev-harness method scans retained attachment rows, decodes each, selects one image <=10MiB with valid origin, and calls the existing guarded native materializer unchanged.
- Result: IMG_0169.heic, completed:true, verified_bytes=1163741, failure null. Exact-record ALL_ASSETS lookup with preserved account/ETag/permit/size checks; MMCS evidence asset_bytes=1171456 validation_ok. Placed file byte-identical; ftypheic plus full meta tree plus mdat plus Exif; ffmpeg decoded a real frame to PNG proof in staging.
- Fixes along the way: synthesized request entries must carry verbatim row identity (sequence/batch/attempts/created/server-record/sysref/modified); zeros fail bind. Synth-entry self-decode check added for future diagnostics.
- Scoped as protected-native body proof from a retained record, not the ordinary projected-row UI flow. Cache writes only in the private test profile; no projection/drain, no remote writes, no auth changes. Rollback bytes and receipts preserved.

## September 20: measured durable-state receipt prepared for retained body caller (uncommitted, in review)

- Working-copy change only on base d84d8cba3, no commit: materializeRetainedBodyForTestHost in lib/cloud_sync_v2_windows_harness.dart keeps the selected inbox row id, snapshots sorted checkpoints plus sorted outbox plus that row status, retry and source fields before and after the guarded materialize, and returns durable_state_unchanged as a measured boolean. No rows, tokens, contents, or filenames in the report. Body cache stays outside the snapshot. No restore or overwrite. A throw propagates with no comparison claimed. No native, FRB, API, or build change.
- Matching one line live test expectation added in test/live/cloud_sync_v2_windows_live_harness_test.dart. Both diffs sent to the supervisor for the validator requirement. Commit held for approval. Both handed off PowerShell scripts untouched. No live call, no runner dispatched, no toolchain run locally.
- Matching one line live test assertion added in test/live/cloud_sync_v2_windows_live_harness_test.dart, awaiting the live run and not an executed offline regression. Both diffs sent to the supervisor for the validator requirement. Commit held for approval. Both handed off PowerShell scripts untouched. No live call, no runner dispatched. Scoped dart analyze run locally, results below.
- Matching one line live test assertion added in test/live/cloud_sync_v2_windows_live_harness_test.dart, awaiting the live run and not an executed offline regression. Scoped dart analyze with the explicit SDK path shows no errors; the 11 remaining warnings and infos sit in pre-existing regions, none from the new snapshot code. Both handed off PowerShell scripts untouched. No live call, no runner dispatched.

