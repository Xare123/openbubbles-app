---
type: history
title: CloudKit treemap checkpoints before received reader integration
description: Preserved September 16 source, artifact, agent and device checkpoints moved out of the active treemap.
resource: openbubbles-app
tags: [cloudkit, history, qualification]
timestamp: 2026-09-16
---

# Historical checkpoints

These are historical snapshots, including superseded running-job and next-step
statements. Use the [current treemap](../../CLOUD_SYNC_V2_CONNECTION_TREEMAP.md)
for the active source and next action.

### Current exact received-record lookup qualification, September 16

**Qualified inspection predecessor:** `4066778045915a8f4f951bb8eb7bfcb0171391b1`
contains app integration14ce1d749 and native handoff6eaba5c22. Batch35138299645
PASSED:738 app Rust,350 rustpush,11 Anisette,40 protector; committed bridge
reproducibility passed. Artifact10463524620,387,557bytes, SHA256
`6ae2d27ff090c5a9086585ad017842c52b302148675f945d1727120d34a6f4ab`, verified
against all seven existing generated files without replacing current source.
Prior35136724953 compiled but failed one NEW fixture assertion (737 passed):
the intended reordered record still put ETag tag1 first, matching canonical
order. The fixture now appends tag1 last; production code was not changed to
make it pass. The corrected native test now passes. The newer received-create
integration above needs its own qualification; this green predecessor does not
prove that new code or any remote upload.
Do not install this candidate or use an older native DLL with its Dart API.

- Parent reproduced and fixed a retry selector bug: an adopted observation with
  a lost raw-commit response was filtered out forever. State1 now stays eligible
  until exact local commit; state2 means observation committed, never uploaded.
  Final27-file integration passed811 Dart cases after the split, with14-file
  clean analysis. The28-case helper journal batch and19-case parent batch are
  subsets, not additional independent tests.
- A separate cross-engine cleanup race exists before raw observation adoption.
  Native preparation now returns only a single-use in-memory handle. A short
  native local-store exclusion covers stage/adopt/commit, with no network fetch
  held under that exclusion. Source/container/parent are checked again at stage.
- Popper01a0ab7a-8fdd-7522-820d-a66bfd8d786f's bounded test changes were reviewed
  and accepted. Closed and verified not_found; no separate worktree/build. No
  active helpers or local test processes. Native CI35138299645 is the only
  running job; do not rerun the failed predecessor SHA.
- User-requested delegation guidance is recorded in AGENTS.md: bounded tasks,
  disjoint writes, concise evidence, no duplicated investigation or routine
  repeated full tests. Muse Contributor max remains the selected helper model.

Native source `f139a899b4cd51706a93d011753d462092eb5fcb`, rustpush
`fb864a302d2d07b4480d2b40ad3cee4c1d134729`, passed hosted bridge run
`35107521313` (14:17:39Z to14:35:22Z). This includes the reviewed single-pass
Find My observer. Current Dart observation/schema/adapter work is committed in
14ce1d749. Do not install this candidate or pair it with the older Windows DLL.

- Exact lookup uses restored semantic-read transport, bounds gzip output and
  rejects trailing members, validates original response wire before interpreting
  NotFound, and retains original Record bytes without reencoding. Reviewer found
  no additional blocker after these repairs. No account request was made.
- Generated artifact10450679242,386,132bytes, SHA256
  `2f8a4c807d8f9aa113797ca3eafde5012cb33b3f382d99b20d26f970b646ec4a`
  verified before importing seven clean targets; all seven byte-match. Committed
  reproducibility was intentionally skipped. Evidence is under
  `build-evidence/received-exact-inspection-35107521313`.
- Received entity36 adds nullable property14 without changing any existing ID.
  New observation is read evidence only: Found retains raw/version for later
  adoption/projection, Absent must be revalidated before create, and Unresolved
  never creates. Actual create-only admission/readback remains required. Both
  received capture and inspection flags remain false.
- Euclid, Godel and Franklin reviews are integrated or explicitly rejected as
  documented in history; all are closed and verified not_found. Euclid's latest
  work was in main, without a new dedicated worktree. Prior blocked sidecar
  removal is not retried; supported session deletion remains unavailable.
- C:27.10GiB free at latest source checkpoint. No APK, paid GCE, phone restart/install, unknown-
  outcome replay or Alpha change. Next: pass the Dart recovery/GC/schema batch,
  then connect the qualified observation to duplicate-safe admission/readback.

### Earlier component checkpoint: encrypted receive retry jobs

App checkpoint `f403006b9abac5d2943372fcd0b50d4c62dd3a56`, native source
`9293a457c7f3c8bc476ec5341a2c39aa5caac116`, adds platform-
encrypted inline receive seeds, original-source projection and a bounded raw
protobuf equivalence checker. The seed commits with Message in ObjectBox before
file staging; a local worker resumes stage/adopt/commit after restart. State0 is
pending local materialization, state1 is exact local commit, never cloud-saved.
No schema ID changed. The flag remains default-off and no APK/device change.

- Current Dart integration passed 692 tests across 25 files, including the
  real receive seam, seed retry/reopen/GC, finite worker rounds and one FaceTime
  acceptance regression. Focused analysis is clean except existing service infos.
- Hosted bridge run35099318119 passed for exact9293a457c: 737 app Rust,
  321 rustpush, 11 Anisette and 40 protector tests. Generated artifact10447797443,
  384,004 bytes, SHA256`827bba84a9182376e8534cceba25f5019d89edfb3354b5db53bcd274a0a07d07`
  verified and all seven members byte-matched. Committed reproducibility was
  intentionally skipped. Evidence: build-evidence/received-retry-seed-35099318119/verification.json.
- Seed sealing itself can still fail before durable archival ownership. The
  normal delivery fallback preserves the Message, not a completed archive. Do
  not claim this protection/readiness failure is closed by file retry.
  Raw outer-record extraction/identity binding, duplicate-aware admission and
  independent-client/live proofs remain required. The raw checker is not wired
  to a live lookup yet, and the projector is not an uploader.
- FaceTime: parent reran six focused files, 63 tests pass. One acceptance
  regression added, no new production call fix proven without fresh media logs.
- Find My: the independent receive_message observer is rejected because the
  key-cache path can trigger6005 re-registration. Revised single-pass value-free
  tap is parent/peer source-reviewed, not native-tested/integrated. Preserved
  app ref`agent/findmy-singlepass-review-20260916` at160356758, native ref with
  the same name in active rustpush at9b09a541. Use this for the NEXT native batch;
  main rustpush remains9ced48b. Historical fe9b9/576f466 did compile; only its
  later uncommitted cache-only sketch lacked the proposed method.
- All three helpers closed, verified not_found. Euclid's134MB worktree removed,
  source retained atref`agent/received-raw-proof-review-20260916`/d16a55e6b.
  FaceTime/Find My source is preserved, but cleanup guard blocked removal of
  their342MB/137MB worktrees and 82 generated plugin symlinks. No bypass was
  attempted; paths and shared caches remain. Manifests under
  build-evidence/agent-cleanup-20260916-{raw-proof,sidecars}. Sessions/transcripts
  remain because supported deletion is unavailable.
- Native job/test/analyzer handles are terminal. C:27.86GiB. No active helpers,
  paid GCE, fresh account traffic, messages, restart/install or Alpha changes.
- **Next concrete implementation:** native read-only exact-record inspection
  for a materialized received source, then wire Found to protected adoption or
  reader reconciliation and NotFound to existing create-only/readback machinery.
  Verify outer field presence/types and raw flags: the generic CloudMessage
  decoder truncates unknown MessageFlags, so typed equality alone is insufficient.
  Do not spend another iteration only adding comparator helpers.

### Earlier implementation checkpoint, September 16

Received-source checkpoint is `cfc37e26a5b2d5350dfe709cead0fbeb67e097ba`,
rustpush `9ced48bae256bcdd7d46db84eefb331bd9d86d88`. The actual receive queue
now has a **component-tested, default-off** direct-text capture hook. No incoming
uploader or new APK is enabled. The frozen f027 deployment candidate below is
unchanged; the old Windows DLL must not be paired with these newer bindings.

- The old Dart gate is isolate-local and covers long network fetches. Native
  local leases now fence capture stage/adopt/commit against maintenance's full
  inventory/cleanup. Maintenance retains the old gate; receive avoids it.
  Tests prove both ordering directions, no stale-zone reuse, explicit release,
  failure retention, and quiescence. A two-second native waiter timeout rejects
  contention without taking another owner's lock. OS process-exit tests ran on
  Linux, not Android/Windows live hardware.
- Native checkpoint `df23a06d5` passed hosted run `35094043857`: 717 app Rust,
  321 rustpush, 11 Anisette, 40 protector cases. Artifact10445637603, 383,023 bytes,
  SHA256 `0ccbb8c6592fe5b0de83eb43417ea1d5b683cd2498788998f602d3487ccb8419`,
  verified before importing all seven generated members. Committed
  reproducibility was deliberately skipped, not claimed passed.
- Current 23-file Dart regression batch passes 676. Focused analysis is clean;
  larger pre-existing service files retain seven warnings/info, no errors.
  Real ObjectBox callback rollback, duplicate delivery preserving edits, outgoing
  overlap, old-model upgrades, source digests and capture/recovery tests pass.
  Unsupported media/groups/SMS keep their existing queue path. Reset drains
  active captures; the queued original account/store fence cannot be rebound.
- **Next gate:** durable retry when capture fails before an encrypted source
  exists, then raw-record duplicate/adoption proof and received outbox admission.
  Current fallback preserves ordinary messaging but does not prove complete
  archival. Keep the capture flag false until these gaps and live gates close.
- Heisenberg is closed, verified not_found. Its reviewed 137 MB worktree was
  removed with original source retained at ref `agent/protected-store-lease-review-20260916`.
  Manifest `build-evidence/agent-cleanup-20260916-local-lease/manifest.json`.
  No active helper/build/test remains; sessions/transcripts retained because
  supported deletion is unavailable. C: about 28 GiB free; no paid GCE run.
- Pixel restart/update approval remains pending. No phone change, account reset,
  message send, unknown-outcome replay, Alpha mutation or upstream PR occurred.

### Resume checkpoint: September 16, post-build offline work

These are the frozen deployment versions, not the newer received-source checkpoint above. Product source is
`f027aad2a17c131f7d68687ea68f58b334473e8f`; installed Pixel source remains
`710003e7b`. Rustpush remains `5522fa0ced1c1fe7ed70262ac230261889ca06c5`.
These are the frozen deployment candidate versions. The separate received-archive
development now starts at app `0e9d2d2d089d67b7ef454e81ea7df978b2dbe9eb` /
rustpush `9ced48bae256bcdd7d46db84eefb331bd9d86d88`; it is not an APK or a
replacement for the ready f027 package.

- **Media: live-proven for the failed HEIC.** The user confirmed download and
  reopen; production cache restoration verified the authenticated 2,302,773-byte
  body without changing the original 1,048,576-byte metadata.
- **Profile onboarding: implemented and locally tested, not installed.**
  `1e534e48c` adds normal Profile encryption preparation, readiness/progress and
  plain-language failure handling. Legacy-on behavior stays intact. The normal
  background writer still needs its separate public-rollout review.
- **Edit/unsend: in repair.** Pixel attempts failed during mutation preparation
  with `cloudkit_interlock_busy`, before dispatch. A terminated-isolate local
  runtime probe reproduced a retained named-port mapping that denies the next
  owner. This proves the mechanism, not the exact phone owner. Do not reclaim
  the mapping on elapsed time alone or resend an unknown-outcome mutation.
  Candidate `0696757b2` fixes draft/dialog recovery. Candidate `f027aad2a`
  closes admission and drains actual interlocks, retains direct mutation receipt
  tails, and prevents native host teardown until owned work and IPC replies end.
  It passed 33 Dart cases plus eight Kotlin lifetime tests. No Android live proof.
- **Verified APK ready:** GitHub-hosted Build `35058684776` passed, exact
  `f027aad2a`, canary_only=true; Alpha skipped. Artifact10432532324 archive
  SHA256 `27e6279c323de585ec27b1e7baa0457cc125a77369dda20f43ed40105b54b39a`
  matched after download. APK452,999,643 bytes, SHA256
  `d34e72bb78add5f5654adf04e5183cffd8c786bdb5a526ab2a19a424b8e7ab50`.
  Stable Canary v2/v3 signatures, exact package, four ARM64 libraries, no dotenv,
  and the new native lifecycle markers independently pass. Evidence is under
  `build-evidence/github-canary-f027aad-35058684776`; not installed. This workflow
  compiled/packaged the app, not the full Flutter/JVM test suites.
- **Group history: two separate findings.** Alpha contains 27 historical
  messages absent from both qualified Canary and Windows copies; none has a
  cloud-synced flag or message record ID, and Alpha legacy sync was disabled.
  This supports an upload gap, not proof of remote absence. Separately, Canary
  has a restored canonical group row and a newer live-receive row sharing exact
  aliases. Investigate alias-aware routing; never merge by title or membership.
- **Write ambiguity remains.** The latest Canary copy has eight confirmed
  outbox rows and one unknown-outcome row. Reconcile the latter by exact readback
  only. The older unresolved mutation is not one of the user's latest attempts.
- **Incoming archival gap, source-confirmed:** the V2 automatic uploader drains
  only locally sent positive-receipt intents. Incoming and other-device mirrored
  rows have no V2 archive producer; the old all-unsynced uploader is disabled
  under V2 ownership. Full two-way sync requires a separate received-archive
  origin, not weakening outgoing receipt checks. See the
  [implementation boundary](cloud_sync_v2/INCOMING_ARCHIVE_DESIGN.md).
- **Pixel reconnected wirelessly, read-only preflight complete.** September16
  snapshot and both native log generations are saved under
  `device-evidence/20260916-outbox-preflight`. Auth/UI report ready and sync idle,
  but outbox is blocked: eight confirmed rows, one unknown outcome, ten ready
  send intents (one has changed source). Latest worker still reports
  `cloudkit_interlock_busy`. Database three-way SHA256 begins `2ec96eee37ef`;
  source-copy inspection made no device changes. In-place restart/update was
  requested; approval remains pending. No reset, resend or installation.
- **Find My observer: isolated test-qualified, not integrated.** Rustpush
  `576f466ce33ea424ae1f617f750c48b0dea4d938` / app `fe9b9f306` passed hosted
  bridge run `35031241619` (685 app, 332 rustpush, 11 Anisette, 40 protector).
  This does not establish working People coordinates or Items.
- **Resources:** no paid GCE launch without renewed approval; C:29.03GiB free.
  Five reviewed clean agent worktrees were removed with retained Git refs;
  manifest `build-evidence/agent-cleanup-20260915-profile/manifest.json` records
  406,196,141 logical bytes. Sessions/transcripts were retained because supported
  session deletion is unavailable. Current agent work and evidence are protected.

Next: on Pixel reconnect, qualify detached-engine recovery and edit/unsend with
the verified APK in one session, after safe installed-state preflight. Do not reset app data,
enable Alpha uploads, replay the ambiguous outbox, or claim production readiness.

Historical component checkpoints (not current active work handles):

- Parent integrated the four mutation-UI files and corrected cleanup when an
  error occurs before the dialog's first build. Ten focused tests pass, including
  early failure, a newer dialog, another route and host disposal. Full widget
  file analysis reports pre-existing warnings; no analyzer errors. This is local
  candidate work, not installed or proof of successful backend edit/unsend.
- Parent added unique exact CloudKit alias fallback after existing live GUID and
  guidRefs lookup, restricted to iMessage/non-routing-stub receives. Six real
  ObjectBox routing tests plus 20 existing resolution tests and the ten UI cases
  pass together (36 total). Lookup does not normalize, merge, reparent or mutate
  aliases. It prevents new splits in unambiguous cases; already-split rows retain
  their direct route and still need a separately proven repair.
- Offline three-profile comparison was rerun against hash-qualified temporary
  copies: all 27 Alpha message GUIDs absent from both other stores, all source
  bytes unchanged, zero remote calls. Alpha uploads were not enabled.
  Column-level follow-up confirms the live GUID equals the restored cloudGuid
  but is absent from restored guidRefs. The new fallback addresses that exact
  lookup gap; it still deliberately leaves the already-split rows untouched.
  Additional saved-copy check: the live row's13 messages are all incoming;
  both rows have zero local-send/adopted-send/mutation journal references. This
  is a repair prerequisite only, not permission to merge or proof of every
  canonical/source dependency. A resumed helper returned no report, so parent
  continued this check directly and did not count it as an independent review.
  Follow-up production group-binding validation on copies passes for canonical
  Canary695 and Windows664 (generation1); live Canary701 is provisional and
  fails `cloud_sync_local_send_chat_not_ready`. This validates stored metadata
  bindings only: native protected blobs were not opened and no live write was
  authorized. `Chat.merge` is a UI value merge, not a durable row repair.
- All five reviewed helper tasks are stopped or idle; the final engine reviewer
  and FaceTime/Find My helpers were archived through supported app controls.
  Native agent handles disappeared after the host reload; app status and final
  reports were checked before archival. Unique uncommitted/rejected work and
  evidence remain protected; no session/transcript deletion is supported.
- Noether `01a0a8d7-b079-7dc2-961d-ff7efd9c6400` and Rawls
  `01a0a8f2-4c11-76f0-bff2-b9ad08685326` finished their bounded reviews and
  were closed through native controls; subsequent lookup returns not_found.
  Both isolated worktrees contain uncommitted review material and are retained.
  Session/transcript deletion is unsupported. No agent files were deleted.
- Received-archive eligibility is an unhooked two-file source component, not an
  enabled uploader. Parent fixed outgoing-sender dependence, same-row canonical
  adoption drift and deleted-chat admission. Native-source follow-up corrected
  the helper's mistaken SMS-only interpretation of MessageInst.target: normal
  iMessage also carries a reply-device token. The digest now binds the separately
  captured local recipient, never an inferred current chat default. Thirty-six
  synthetic eligibility tests and 232 existing send/mutation/chat regressions
  pass together (268); focused analysis is clean. Native recipient propagation,
  protected source, durable received intent and Apple-first deduplication are
  still missing. No APK/native change or live received upload is claimed.
- Noether's transport review confirms the standalone Find My probe has no
  normal dispatch loop, while APS has an independent auto-ACK task. Source
  alone does not establish safe server delivery ownership, so no live standalone
  observer is enabled. Cache-only prototype remains isolated, without native
  compile/live qualification. Existing findmy.plist is present; missing bootstrap
  is conditional, not the proven cause of this user's missing coordinates.
- Rawls was briefly resumed for the distinct native-reuse handoff, then reviewed
  and closed again. Both current child handles now return not_found; no helper
  is producing work and no build/test session remains. Unique worktrees and
  transcripts are retained. Do not treat the original isolated prototype as the
  reviewed main revision.
- **New native boundary qualified:** hosted bridge run `35075169331` succeeded
  for exact0e9d2d2d0/9ced48b in12m20s. Native tests passed685 app,321 rustpush,
  11 Anisette and40 protector cases. Original IDS tP now survives in optional
  MessageInst.received_on_handle, separately from reply tokens; local sends keep
  it unset and outgoing native source codecs reject receive-marked values.
  Artifact10437743507 SHA256
  `2c554a5e4c5704375bd481bfab5feb93a236913fca914f4aa88ef1012718d695`
  matched locally. Its seven generated files were imported after a clean-file
  check, with only three files materially changed (20 insertions/four deletions).
  Generation allowed drift intentionally; committed reproducibility was skipped,
  not claimed passed. Native compilation and all listed suites did run.
- Parent's Dart follow-up requires the native receivedOnHandle to match captured
  context and rejects receive origins in local send/reaction/edit/unsend capture.
  Four new regressions failed before the guards and passed afterward. Full five-
  file targeted batch passes288; focused analysis is clean. No source envelope,
  receive producer or remote received archive is enabled by these changes.
- **Received journal integrated, not enabled:** Carver's bounded journal and
  binding passed parent review after corrections. Capture revalidates original
  wire against the actual persisted row inside the same Message/intent transaction.
  Parent also fixed auth changes during persistence, deleted-message readiness,
  and a partial-page cursor that skipped an unreturned valid row. Production GC
  inventories retain received blob/lease references across all epochs/states and
  fail closed on malformed ownership. No remote-admission/producer hook exists.
  The ten-file Dart batch passes446 and focused analysis is clean.
- Schema adds only CloudSyncReceivedArchiveIntentEntity (ID36); all27 previous
  entity/property layouts and retired UID arrays are unchanged. A synthetic old-
  model store upgrades, preserves Message/Chat values and relationships, and
  reopens successfully. This is forward-upgrade proof, not a live-data migration
  or a supported downgrade/rollback claim. No device schema was changed.
- Carver `01a0a95a-f229-7c83-8d70-befba78d6012` is closed, confirmed by missing
  native handle. Original helper source is preserved at local ref
  `agent/received-intent-journal-review-20260916` / `ea4a3cc589`; corrected source
  is app `cd77ec55560c4c898102d13a5886620b73cc91f8` on the fork received-origin
  branch. The dedicated clean worktree/cache was removed Git-aware after verifying
  its submodule metadata was exclusive. Manifest:
  `build-evidence/agent-cleanup-20260916-received/manifest.json`.
  Logical bytes391,223,213 removed; observed C:free increased396,410,880bytes
  to28.48GiB. Main, device evidence, APK and retained source ref verified intact.
  Sessions/transcripts remain because supported deletion is unavailable. No
  helper, native test job or parent test session remains active.
- **Protected received-source candidate qualified:** app089b87fa26243d5f231f44cf9e8d96361e611c74
  / rustpush9ced48b passed hosted bridge run35086913808 in17m18s:708 app Rust,
  321 rustpush,11 Anisette,40 protector tests. Native source and GUID hashes match
  frozen Dart vectors (including Unicode/control characters). Exact lease commit,
  descriptor tampering, wrong account and wrong-purpose reopen tests pass. Native
  APIs use cached local identity and protection, not writer warming or GSA refresh.
  The full writer snapshot's current-GSA validation remains unchanged.
- Artifact10442727024 (381,798bytes), SHA256
  `7c9facdf6f52bb02323156f998a08f0e7fe9264aaf72630a96f5c0d8a26d01fe`, verified
  before import. Seven generated members imported from clean targets; most
  generated diff is bridge call-index movement for the new APIs. This generation
  run allowed drift, so committed reproducibility was skipped, not proven.
  Evidence: `build-evidence/received-source-bridge-35086913808/verification.json`.
- Dart stage/adopt/commit handoff reuses a journal-owned source after a lost
  response and rolls back only an unadopted lease. Protected-store exclusion is
  local; it does not acquire the network-wide writer interlock. New exact failure
  codes are allowlisted without exception text/private ArgumentError values.
  Current11-file Dart batch passes480; focused analysis is clean.
- Existing-record matching is typed, direct plain-text comparison only. It
  handles standard part-zero/false-format attributes, millisecond timestamp
  precision, redundant direct proto4 groupId and mirrored empty-sender shape.
  Every Found outcome blocks duplicate creation. Raw presence/unknown-protobuf
  validation and exact protected parent/mapping adoption remain unimplemented
  requirements; a matching typed value is not permission to adopt or write.
- **Next required implementation:** connect the protected capture to actual live
  receive persistence, then implement duplicate-aware received outbox admission
  with exact raw-record proof. No live producer or received uploader is enabled.
  Do not declare full two-way sync from source/journal/component qualification.
- Fermat `01a0a99f-34db-7ce1-b0fa-43176f1c1ed2` is closed after parent corrections
  and hosted verification. Its original reviewed source is retained at local
  ref`agent/received-record-match-review-20260916`/`d9f5674c57`. Dedicated clean
  worktree136,857,020bytes removed Git-aware after exclusive submodule checks;
  observed free-space increase147,750,912bytes. Manifest:
  `build-evidence/agent-cleanup-20260916-record-match/manifest.json`.
  Sessions, shared repositories, private evidence and frozen f027 APK remain.
- Parent rejected both first sidecar patches as stale-base duplicate fixes;
  current main already handles empty People handles and exact call-timeout
  ownership. Agents were redirected to current-source native/tester boundaries.
  Initial engine-exit candidate also remains rejected. Parent's smaller actual
  native-retention implementation passed independent review; diagnostic-only
  stall reporting never authorizes teardown or lock takeover.
- Windows baseline session `c936a56175d792b302385e4df76a1f63` completed three
  fresh processes: five fetched/applied changes, then two empty terminal passes;
  outbox stayed 24 and retained total 6,252. Process cleanup is confirmed and
  raw output removed. This matched Dart/native `b9c567f89`, with writes disabled.
  This is an existing-runtime check, not f027 Android qualification. Current
  Dart/native pairing was not relabeled: b9->f027 changes the rustpush gitlink
  for a test-only assertion update and the strict compatibility guard rejects it.
- FaceTime Windows opens an external browser, not the Android WebView/probe.
  There is no newer native call trace. Next approved device call needs both
  diagnostics flags enabled before setup and both bounded native log generations.
- Find My Windows has no IDS receive listener feeding the qualified observer.
  Calling full `FindMyClient.handle` would ACK and mutate share state, including
  possible remote deletes. Do not use it as a read-only diagnostic. A separate
  reviewed receive/observe path and no-message-loss proof are required.

Older qualification rows are preserved in the [September 15 archive](cloud_sync_v2/history/CLOUD_SYNC_V2_INVESTIGATION_LOG_FROM_2026-09-07.md#september-15-historical-qualification-rows-moved-from-treemap). The resume checkpoint above is current.
