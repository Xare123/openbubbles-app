# Backend agent application

October24 user direction: qualify the Android/backend through machine commands
without the personal Pixel, then integrate end-user CloudKit UI. Implementation
is IN PROGRESS. No new Firebase/Google allocation until the conversion is ready.

`agentDebug` uses `com.bluebubbles.messaging.backendtest`, separate from Canary.
It requires `OPENBUBBLES_AGENT_BACKEND=true` and immutable40-character
`OPENBUBBLES_BACKEND_SOURCE`. Normal packages/release builds cannot enter command
mode. A minimal console replaces consumer navigation after normal backend init.

Compiled VM extension `ext.openbubbles.backend` accepts exactly
`{protocol:1,requestId,action,arguments}`. Hello VM parameters contain only
`request`; other calls also require the32-character hello `sessionId`, checked
before backend invocation. Host verifies exact source/package and unique isolate.
`tooling/vm_backend_harness.dart` uses private stdin
`{uri,expected_source,expected_package,request}`, optionally adding
`dispatch_journal:{directory,run_owner}`, an owned authenticated loopback
VM endpoint, and no expression compilation/widget traversal/screenshots/clicks.
The old Canary ADB control is a different, still bounded debug utility.

Long operations return a job handle immediately; `job.status` is explicit.
Duplicate identical submissions return the same job; retargeting/concurrent
mutations/history eviction are refused. Timeouts never resubmit/cancel native
work. Public receipts preserve `outcome_uncertain`; late connections retain
cleanup ownership. Unknown jobs/timeouts are not permission to clear app data.

The optional journal claim names an existing private absolute directory and a
32-character lowercase hexadecimal run owner. All actions outside the closed
observation allowlist require it. Exclusive ownership and append/flush precede
VM discovery/RPC; source/package/run header and consumed IDs persist. Invalid
or truncated journals refuse without repair/rotation. Keep the journal with
the run. Fresh IDs do not authorize replacement sends. Windows ownership was
tested; Linux locking remains unexecuted. Content-free dispatch records do not
provide Android Keystore/native operation recovery.

`tooling/backend_harness_session.dart` is the private persistent pipe transport.
Its first line is exactly `{uri,expected_source,expected_package,dispatch_journal}`
and has no acknowledgement. Each subsequent line is an ordinary protocol request;
one validated private reply follows. It retains one connection/client/journal,
bounds each frame to64KiB before decoding, first input to15s and session to25min.
EOF/deadline closes owned host transport, preserving native jobs and uncertainty.
Never attach its full private stdout stream to a public terminal or log.

Synthetic fixture receipts optionally contain participantsSha256/editHistorySha256
in addition to fixtureId/messageGuid/visibleTextSha256. The exact reader accepts
chatGuid plus both digests together. That comparison checks the actual parent,
the complete sorted wire participant set and full ordered edit/retraction summary,
including timestamps. Use these expectations for group/edit assertions; text and
edit counts alone do not establish them. Public receipt projection omits fixtures.

Current command families cover identity/jobs/status, relay, Apple login/code/
restore/status, protector health, Profile read/pause/PCS and native-bound archive
prepare/scope/status. Inspect hello.actions for the actual implemented manifest.
Read uses the existing Profile service. Pause/deadline is cooperative
and closes pending input prompts without discarding entered operations. Native
clique checks, selected bottle and account/interlock/continuation fences remain.
Input acknowledgment is not authentication, membership or readback proof. Only
closed phases/flags/counts/opaque challenges are public; names/passwords stay private.

SetupInteractionPort is an optional presentation seam on the existing setup
controller. The compiled account adapter uses the existing native resource,
attempt-generation, relay reuse, Apple login/verification and registration paths.
It supplies waits, SMS destination input and a blocked registration-support result.
An identity snapshot and native registration are separate facts; neither claims
a fresh CloudKit read. Default consumer setup behavior is retained.

Archive prepare captures the existing native account/store/epoch-bound preference.
Scope requires a short-lived single-use confirmation and explicit queued/future
upload acknowledgment, then calls the same service as Profile. An uncertain save
consumes its confirmation. No direct preference writes or IDS sends were added.
These adapters have offline proof, not installed Android/account qualification.

Required before another hosted backend batch:

1. Qualify the compiled programmatic relay/login/2FA/registration, retained
   setup/restore and protector adapters together. Complete any necessary PIN
   presentation seam using the existing resource/lifetime paths. Never use
   configureAppReview, fake success markers, hidden consumer widgets, or imported
   personal account databases.
2. Qualify native-bound recovery/status and the implemented report/fixture
   adapters around the existing journals. Exact GUID/text/edit/retraction checks
   include current scoped map/inbox provenance; parent-bound materialization
   compares actual attachment bytes. These are local projection assertions
   until a fresh independent reader retrieves the same cloud record.
   Preserve account/store/epoch/ownership/receipt guards.
   Fresh synthetic sends/mutations in the combined test remain within the
   approved recipient scope; existing held/personal messages are never retried.
3. Qualify dedicated-package Android background/lifecycle/restart integration.
   Native registration/scheduler/channel gates now admit the exact backend
   package only when installed debuggable; component checks are recorded in the
   checkpoint. WorkManager/channel/lifecycle execution is not yet live-qualified. Windows
   new command entry is not wired; the existing qualified fast loop remains usable.
4. Qualify reviewed local build sidecar5c62b374 with final frozen source and
   actual GCE flavor/source/artifact/signing, then one warranted immutable-source
   build. Never relabel the old Canary artifact.
5. Replace Google UI navigation with compiled commands and real job polling,
   preserving source/package/owner checks,1800s reservation,300s cleanup reserve
   and one authenticated shared-relay client. Pixel data/USB is not a prerequisite.
6. Actual Android boot/command latency/account/read/archive/readback/media/
   lifecycle/unknown recovery proof. Offline tests/manifest presence prove none
   of those live outcomes.

After backend qualification, complete end-user integration and production
packaging. Alpha merging and original Play Store UI/APK/FaceTime review remain
deferred. Retain the separate16KB source repair for later full qualification.
The runtime checkpoint owns current sources, results, owners and next actions.

## Combined acceptance batch

October24 user explicitly requests multiple related cases per run and an
independent GCE OpenBubbles reader. Use one frozen build and one orchestrated
batch with writer and independent-reader phases, not a new build/session for
every case. No iOS readback flag is required. Keep the shared relay exclusive
and verify the writer handoff before admitting the fresh reader.

| Case | Required assertion |
| --- | --- |
| Shared setup | Exact source/package/actions, normal relay/account/PCS, actual protector health, native-bound archive acknowledgment |
| Existing manual target | Fresh iCloud retrieval of its exact GUID/content on GCE, without Pixel DB import or resending it |
| Direct text and edit | Fresh synthetic fixture, positive IDS/durable source, archive result, GCE exact GUID/latest text/edit history |
| Timely Undo Send | Separate fresh fixture, supported time window, settled predecessor, retained retraction and fresh reader behavior; run before long history work |
| Approved group | Exact approved participants and parent identity, group text and supported media; no global alias merge |
| Attachments | Supported image/document identity, parent association, successful materialization and byte digest; user-facing preview/playback remains a later UI check |
| Restart and continuation | Settled idle restart, saved session, no duplicate canonical messages/IDS/CloudKit submission; bounded incremental/background observation |

Reuse the prior Pixel edit/readback/idle-restart and Windows direct/edit/undo/
completed-replay passes within their source/platform scope. Re-run only changed
or missing assertions. Capture a separate result per case and retain passed
results if another case stops the batch. Full-history completion is a release
gate, not a prerequisite that consumes this scenario's setup/restart reserve.

Before admitting writes on an expiring device, prove recovery survives expiry.
Boot-local job handles and content-free counts are insufficient. Bind the host
ledger to the existing durable operations/receipts; refuse replacement sends and
routine app clearing after uncertainty. Reuse the established cloud allocation,
artifact, private-input and cleanup controls. The old read-only Google driver's
cleanup must not be copied into an unresolved writer path.

Current discriminating review found no supported DDP snapshot/key-free operation
transfer. Google wipes a device after session end; copying ciphertext/receipts
does not recreate its Android Keystore context. The next practical sequencing
uses the existing retained Windows writer/profile followed by the independent
Google Android reader. Preserve Windows DPAPI user/profile/native sources and
reconcile uncertainty there. This advances backend proof; real Android writer
expiry/recovery qualification remains open. Do not substitute a new emulator
infrastructure lane or extend sessions without resolving the applicable scope.

TOOLS/tooling/cloud_sync/network_observe/google_backend_control.py supplies the
compiled reader adapter over an owned PID-derived VM endpoint/ADB forward and
private persistent Dart pipes. The existing run_google_canary_launch.py accepts
an explicit backend_step for the dedicated package, preserving read-only
preflight, install/native checks, lifetime and cleanup while skipping consumer
UI traversal. Source/artifact/private-input/DNS admission must be rebound to the
actual frozen agent artifact before live use. No Google runtime proof yet.

Astra's accepted evidence/workflow review is retained in TOOLS/build-evidence/
received-parent-retention-20261024/PRIOR_LIVE_GATE_RECONCILIATION.md and
BACKEND_WORKFLOW_FINISH_LINE_REVIEW.md. The parent independently confirmed the
specific historical Pixel edit/readback/restart and Windows chain receipt fields.
