---
type: build_runbook
title: Find My current diagnosis and Windows test loop
description: Verified live evidence, exact safe invocation, and remaining People, Devices, and Items gates.
tags: [findmy, windows, diagnostics, recovery]
timestamp: 2026-09-15
---

# Current result

Find My is **not production-qualified**. The Windows test loop works and now
provides real account evidence without an APK rebuild.

September 15 follow-up: current main already uses `projectFindMyPeople` and
handles empty accepted-handle lists safely. Do not reapply the old `.first` UI
fix from a stale tester checkout. The remaining gap is not that exception.

The isolated IDS-242 shape observer (rustpush `576f466c`, app `fe9b9f306`,
hosted bridge `35031241619`) is test-qualified but not in the installed runtime.
Its Windows caller is also missing: the host performs roster/selected reads,
not IDS receive dispatch. The observer currently sits inside `FindMyClient.handle`,
which has ACK and share-mutation branches, including remote deletions. Calling
that complete handler is not an acceptable read-only observation shortcut.
A separate bounded observer ingress must preserve verified decryption and
ordinary delivery without invoking those mutation branches. Until that boundary
is reviewed and qualified, more synthetic observer tests do not demonstrate
live People coordinates or Items inventory.

- The user confirms exactly one person shares their location with this account,
  their spouse, and that sharing remains enabled.
  Both roster and selected-person reads returned that entry, but no native
  location. Do not interpret `optedNotToShare` or `tkPermission` as proof that she
  stopped sharing; the fields' directional meaning is not established here.
- FMIP initialization/refresh completed and the final decoded device list was
  empty. This does not test AirTags or prove the separate Items inventory is empty.
- Items were deliberately not invoked: their ordinary initialization can perform
  CloudKit alignment writes and requires its own reviewed test.
- Successful probes verified the FRB runtime handshake, existing DLL signature,
  unchanged protected-profile invariants, and confirmed exit of every admitted
  test process. No sharing change, sound, message, logout, or reset occurred.

## Evidence and source binding

Private aggregate evidence:
`C:\Codex\OpenBubblesReview\build-evidence\findmy-windows-live-20260913`.

| Pass | Launch | Result |
| --- | --- | --- |
| Roster | `2a760d5c97d34b89ac3e6f26ccccf338` | 1 person, 0 locations, 0 FMIP devices |
| Selected person | `b883750254d74f09b5c975570c6be4a6` | Exact sole entry matched; fresh selected response still lacked location |
| Logger-fixed native repeat | `ab1225a716454ee482b1762eaa78e3dd` | 1 person, 0 locations, 0 FMIP devices; protected-profile checks passed |
| Awaited native initialization | `2ca02f9e0f1f41f7bb4e299eff227386` | Same aggregate result; native diagnostics show FMF init and refresh omit the `locations` field |

The latest tested native DLL is SHA256
`bf1507c72421fed903dcaffcbe863a001d0d59bd2c04e20b8ce8befe6345147e`,
source `3496034e3b41c2bfc862e75f975e62c266336cce`, run 34762729315.
The earlier two probes used retained source `7f2569165`.
Each private `qualification.json` separately records the actual host/probe/bridge
hashes. An uncommitted host must not be described as contained in its base SHA.

No old full-app receipt was relabeled. The new Windows native-only build is a
separate CloudKit qualification, not proof of a Find My fix. The current DLL
includes the restricted `findmy_diagnostic` target. Awaiting `doFirstTimeInit`
in the test host restored native diagnostic output. Observed FMF initialization
returned `following: Array(1), locations: Absent`; refresh returned both fields
absent while retaining the contact. No coordinate join was attempted. This
narrows investigation to request/response handling but does not prove a secure
protocol failure or sharing change. Selected aggregate results are also empty,
but no selected raw-shape line is claimed.

## Run the existing loop

Use PowerShell 7 in the current feature checkout. Keep the Windows app closed;
the launcher owns the same profile mutex as the CloudKit host. Do not run these
two live workflows concurrently.

```powershell
$previousFindMyEnable = $env:OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE
try {
    $env:OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE = '1'
    & .\tooling\windows\run_findmy_windows_live.ps1 -EnableLive -SelectSolePerson
} finally {
    $env:OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE = $previousFindMyEnable
}
```

`-SelectSolePerson` selects only an exact singleton from a fresh roster, in memory.
An explicit existing selector takes precedence. Zero/multiple/invalid/cached rows
never select the first result. The roster is reused, not fetched twice.

Files:
- `test/live/findmy_windows_live_test.dart`: bounded native bootstrap and test.
- `test/live/findmy_windows_sole_person_test.dart`: selection regressions.
- `tooling/windows/run_findmy_windows_live.ps1`: artifact, mutex, and process guard.
- `tooling/windows/findmy_windows_preflight.py`: private retained-state checks.
- `lib/cloud_sync_v2_windows_findmy_probe.dart`: shared aggregate orchestration.

Standard APS local persistence and normal authentication/Anisette renewal on the
existing service are authorized. This is not a claim that bootstrap is mutation-free.
Missing retained account/keys, identity replacement, interactive sign-in, CloudKit
sync, Items sync, IDS registration, ringing, sharing changes, and resets stay out
of this host. Native/test raw output is discarded; only bounded aggregates escape.

The SDK process chain includes `dartvm.exe` and `dartaotruntime.exe`. The launcher
tracks their exact SDK paths and process ancestry before admitting the exact
`flutter_tester.exe`. Do not weaken this to a ready PID or basename check.
The first failed attempt never reached native service access; cleanup and profile
invariants passed. The corrected chain was reproduced in a synthetic real-SDK test.

## Actual unresolved boundaries

| Path | What is established | Next evidence |
| --- | --- | --- |
| People | Native `last_location` is filled only from matching legacy `locations[].id`. Real init/refresh responses omit `locations`; this is not a failed coordinate join. Secure/fallback capability fields have no behavior in this implementation. | Compare the requested service/context and authorized response variants against a known working path. Do not infer consent or force a protocol downgrade. |
| Devices | Final refreshed `content` decoded to an empty list. | Compare initialization and refresh counts plus allowlisted response status/context, not just the final list. |
| Items | Inventory/position sync acquires the global native writer permit and may save alignment records. Active semantic reads pause that gate; V2 ownership alone is not a permanent prohibition. | Confirm same-process pause/resume and Items stage, then qualify a reviewed normal Items workflow. |

Secure-location keys elsewhere in the source belong to Beacon/Items. They are not
proof that secure People decoding exists. No protocol fallback is authorized by
an empty location or by a successful HTTP response alone.

## Qualification and handoff

After the selected-detail enhancement: 37 Dart tests passed, 1 live test skipped;
11 Python preflight tests and synthetic launcher/cleanup checks passed. Parent
also reproduced and fixed a stale report reason: successful selected reads were
still labeled `safe_authenticated_session_unavailable`. The updated test fails
before the correction and passes afterward. Source pins were updated for that
reviewed aggregate-only change.

Full Android UI, real continuously updating coordinates, and Items remain open.
Do not ask the user to reconfigure sharing based on these incomplete results.

September 13 follow-up: Muse reviewed the selected-person async chain; parent
confirmed the callback and native API call sites. Roster refresh, selection,
native refresh and aggregate reads are awaited. No missing-await patch was
warranted. This rules out that specific host-ordering hypothesis, not the
remaining native service/context or response-handling problem.

A second bounded comparison confirmed the production People page and Windows
host call the same makeFindMyFriends/refreshFollowing/selectFriend APIs, with
the same hardcoded non-daemon branch. The production first poll reads the clone
of initClient; the host explicitly refreshes. Existing native evidence already
shows absent locations during initialization as well as refresh, so repeating
that timing check is not the next useful test. The review does not prove the
Pixel and Windows retained configuration values are identical. No secure/FMFD
fallback was found in either caller, and no sharing setting was changed.

The verbatim older investigation and superseded guard discussions are preserved
in [Find My history](history/FINDMY_ASTRA_HISTORY_20260910_20260913.md).

## Secure People research lead, not a working integration

At reviewed commit 04dd253, [Onitrack's People implementation](https://github.com/TureBentzin/onitrack/blob/04dd25312643d8c9aa93c883a343488a4b682635/onitrack/people.py)
separates FMF relationship discovery from encrypted SearchParty location fetching.
It uses an advertised identifier and P-224 relationship key, not an AirTag's
MasterBeaconRecord secret. Its [key-acquisition code](https://github.com/TureBentzin/onitrack/blob/04dd25312643d8c9aa93c883a343488a4b682635/onitrack/key_acquisition.py)
expects verified IDS command 242 and an inner type-10/version-1 key-delivery
payload. These are implementation leads, not observed packets from this account.

Crucially, the [project README](https://github.com/TureBentzin/onitrack/blob/04dd25312643d8c9aa93c883a343488a4b682635/README.md)
reports that live automatic key acquisition remains unsuccessful. The receiver
and key parser are synthetic-tested; successful sign-in/directory queries do not
prove key delivery or location retrieval. Do not import this as a working fix.

Our MULTIPLEX_SERVICE already declares FMF/FMD subservices and the FindMyClient
receiver accepts those topics. Next work must verify the exact delivered payload
and permitted relationship-key request, not merely add another topic. No live
distributeKeys request, sharing change or key import was attempted here.

## September 16 independent-lane entry (branch agent/facetime-findmy-independent-20260916)

Implemented and tested, not live-proven: commit a5485a223 makes the Windows
probe selected-person `location_found` require usable coordinates through one
rule shared with the aggregate counts, mirroring the app `hasFindMyLocation`
gate. A present-but-unusable location (0,0 sentinel, non-finite, out of
range) previously reported found while the app renders No location found.
No new report keys, no new native entry points, no sharing-state inference.
Unit, adversarial-selection, sole-person host, People refresh, and
single-pass observer contract suites pass; targeted analysis is clean.
Play-sound targeting was verified by inspection: the tapped tile device id
flows directly to the native call behind eligibility gates, a confirmation
dialog, and a per-device in-flight guard.

Standing live gates: real People coordinates for the confirmed shared entry,
verified Devices inventory, and AirTags/Items inventory (Items init stays
off-limits as a read-only probe for its CloudKit side effects). Windows live
probe window requested from the CloudKit task; no credential/profile use
without its ack. Do not reconfigure sharing from probe output.

September 16 provenance verdict: the granted live window was released unused
when the runner guard rejected the installed DLL (140ab5c2, source b9c567f89)
against the qualified pin (7e3eab). In-lane source comparison proved the
installed line unqualified for this probe ABI: its rustpush 6ca98b8 deletes
src/findmy/diagnostics.rs and the approved single-pass observer exists nowhere
in its tree, with wide FRB surface divergence. No qualified bundle exists
locally. Returned to the CloudKit task with evidence for re-qualification or
bundle restore; live probe awaits the next granted window.

September 16 lane runtime: hosted lane workflow built pinned source 5ecd7abe8
(run 35148810129, all steps green) with the observer and matching bindings;
bundle provenance verified (ARM64, read-only, findmy diagnostics compiled).
Imported and signed through the established local importer into the dedicated
lane path facetime-findmy-lane/native-test-host (receipt-bound, established
cert thumbprint, signature Valid; shared runtime untouched). The stock runner
still pins the obsolete DLL hash, so a lane pin update follows before any
live run. No credential or profile use yet; fresh window to be requested.

September 16 first live lane evidence (launch be119c86, window granted and
released): bounded read-only probe with sole-person selection finished
findmy-probe-complete, abi_verified true, retained invariants verified, on
the lane-signed runtime. People roster returned the 1 confirmed shared entry
from a fresh request with no coordinates (opted_not_to_share true,
tk_permission false, not locating); Devices returned 1 iPhone with no
location; selected match true with location_found false under the new
validity rule; Items not-tested by design. The offline qualifier independently
reproduced selection-matched-no-location / absent-coordinates, result
partial. No stopped-sharing inference is drawn from the native flags; the
confirmed share state stands. Proven: roster retrieval, ABI match, and the
report-to-verdict chain. Open: why no coordinates flow for a confirmed
share (relationship key delivery is the standing research lead), same for
Devices, and Items inventory stays gated on side-effect review.

Follow-up: the lane report now also carries the native secure-locations
capability flags (secure and shallow/live counts) through probe aggregates,
unit allowlist, and qualifier schema, uninterpreted, to correlate against
coordinates presence on the next live run.

Second live run (launch aac79013): first coordinates seen in-lane — Devices
returned 1 iPhone with a valid but stale pair (older bucket, is_old true).
People shows both secure-capability flags true yet still no coordinates, so
the absence is past capability: key delivery or server-side inclusion is
the narrowed lead. Qualifier reproduced the verdicts; window released.

Double run (launches 82ef1117, d3d4dae2, ~1 min apart): both cycles fresh
roster, zero People coordinates, secure+shallow flags true, never locating;
Devices kept its stale pair. Locate-latency weakened (second cycle had its
chance); user confirms Apple shows her live, so the gap is client-side
elicitation. Prime lead now: secure handshake over IDS receive, which the
Windows host never dispatches. Next split: whether the Android app (which
does dispatch IDS) shows her location.

September 16 dispatch-split verification (no live use): production daemon rust/src/api/api.rs recv_wait dispatches APS to fmfd.handle at line 13235, before FaceTime at 13296 and iMessage at 13306, so the full app on either platform elicits the IDS-242 handshake. The bounded Windows probe host and its binding use roster and selected reads only and never dispatch IDS receive. New source contract tooling/findmy/probe_daemon_dispatch_contract.test.mjs pins both sides, ruling out reading probe absence as daemon absence.
September 16: exclusive Windows shared-profile window granted to the CloudKit task for its bounded read/projection (up to 20 minutes); this lane runs no profile or credential operations until its release is announced.

September 16 observer-ingress safety verdict (read-only inspection, no live use): a decrypt-plus-observe ingress without ACK, import, or itemsharing handling is redelivery-safe. receive_message (identity_manager.rs) only parses and decrypts; both decrypt paths are stateless, legacy RSA plus AES-CTR in user.rs and NGM ECDH plus CTR in user.rs with the message counter only logged, so nothing one-time is consumed and a withheld 244 ACK leaves the server to redeliver to the production daemon later. Two disclosed side effects bound the read-only label: get_key_for_sender refreshes directory keys over the network when stale and put_keys persists the KeyCache plist to disk on that path, and an IDS 6005 response triggers production-identical re-registration. Ingress contract for review: observe FMF/FMD topics only, never send 244, never import mapping tokens, never enter the itemsharing branches, and report 6005 distinctly. This answers the documented prerequisite for the separate bounded observer; implementation stays queued behind CloudKit release and integration review.
September 16 observer ingress implemented as queued, caller-less code (observe_ids_message_redelivery_safe in rustpush/src/findmy.rs): verified-path decrypt plus single-pass observer on FMF/FMD topics only, with no acknowledgement, import, itemsharing, or CloudKit paths; contract test tooling/findmy/observer_ingress_contract.test.mjs pins the boundary and the no-callers rule. Not compiled locally (no Rust toolchain on this host) and not live-proven; needs fork CI compile, integration review, and a granted window before any call site is added.
September 16 ingress committed on lane branch agent/facetime-findmy-observer-20260916 in the rustpush fork (421616f) and the parent gitlink updated to it; the gitlink now moves ahead of the qualified lane-signed runtime, so any live run requires a re-qualification build plus pin refresh first. Shared-source change noted to the CloudKit task; no call sites added and no live use.
September 16 Android split answered: the Android canary shows AirTag locations yet lists the wife under friends with no location found, matching the Windows probe result. The gap is therefore account-wide for People rather than Windows-specific, and it persists on a full-app client whose daemon dispatches IDS receive. Narrowed lead: People relationship-key delivery or server-side inclusion for this share fails on both client identities while the Items pipeline works; Apple Find My still shows her live, so no stopped-sharing inference is drawn. The queued redelivery-safe observer remains the next instrument: it will show whether any key material for this share arrives at all.
September 16 CloudKit window released after its bounded read sequence (first read fetched 109 and applied 79, follow-ups zero, zones empty-terminal, outbox unchanged); lane ran nothing live and still holds no window. Next lane live step remains queued behind CI compile of the ingress, review, and a fresh window request.
Re-qualification path when review passes: dispatch the lane fast-loop workflow at the new parent SHA for the native-test-host artifact in the read-only variant, import and sign through the established local importer, refresh the lane pins, and only then request a window.
September 16 second CloudKit window granted (15 minutes, bounded retained-record inspections on the verified runtime); lane idle with no profile or credential use until release is announced. Separately, the fork Build run for the ingress commit shows its Dart-suite step failed; failure lines unreadable until the run completes, under diagnosis.
September 16 coordination learning: even offline lane Dart-suite tester processes trip the shared profile_process_running guard, so a local full-suite reproduction run was interrupted mid-flight and lane suite runs stay outside granted windows. Partial local tally at interrupt showed failures consistent with the fork CI Dart failure; full diagnosis deferred until release.
September 16 CI readouts: fork Rust bridge-bindings check completed success on the ingress commit, so the new caller-less method needs no binding regeneration. The fork Build run Dart-suite step failure is still unattributed; no lane file plausibly feeds the Dart suite (no Dart test shells to git or reads lane docs), and the interrupted local full-suite tally also showed failures in untouched helper areas, pointing at a pre-existing breakage to be confirmed by a base-commit control run after release.
September 16 Dart-failure differential: the fork Build run for f73d911a7 (contract test plus docs, no Rust change) shows its Dart-suite step success, while the run for 918e1ebea (adds the rustpush gitlink move plus observer contract) shows the same step failed. No Dart test shells to git or reads lane files, and the interrupted local tally showed its early failures outside lane-touched areas, so lane causation is unproven and flake or a pre-existing breakage remains open. Decisive control queued after release: full suite on a clean base-commit worktree, then failure-name comparison against the CI log.
September 16 ingress reverted: the new entry point provably violates the reviewed single-pass contract in test/services/findmy/find_my_single_pass_observer_contract_test.dart, which pins exactly one receive_message call site file-wide and forbids any additional observation entry point by name pattern, both confirmed by reading. The submodule file was restored byte-identical, the lane rustpush branch and its remote were deleted, the parent gitlink is back at 5862be3, and the ingress contract test was removed. Lesson: the reviewed no-second-entry-point rule outranks the older separate-ingress note; changing that rule needs a parent-owned review that amends the contract test first. The People-gap path stays with production-daemon delivery evidence.
September 16 CI hygiene: cancelled ten superseded fork Build runs for older lane pushes, keeping only the violating-commit run (for the failure-line record) and the revert-HEAD run (for the green confirmation).
September 16 second window released after the bounded 37-case retained observation with checkpoint and outbox unchanged; lane resumes offline Flutter runs, still nothing live.
September 16 third window granted (20 minutes, bounded production read-only drain plus retained-repair sweep on the verified runtime); lane confirmed idle with no tester processes and no Flutter or live work until release is announced.
September 16 causal confirmation: the fork Build run for the revert commit shows its Dart-suite step success, against the same step failed on the ingress commit. The reviewed contract test provably guards the gate in both directions, and the lane tree is back to a state the full CI suite accepts.
September 16 code-proven People gap: the Friends client only ever calls legacy FMF endpoints initClient, refreshClient, selFriend/refreshClient, and import, and import merely posts the mapping token URL for server-side association. No secure-location fetch for People exists anywhere in the implementation; the only SearchParty requests serve Items paths. Since every observed init and refresh omits legacy locations for this share on both clients, there is currently no code path at all that could yield her coordinates: the missing piece is a relationship-key-based secure fetch plus join, which is new implementation needing review and live validation, not a configuration or elicitation fix.
September 16 secure-fetch design sketch from the working Items path: derive P-224 advertised IDs from known public keys, POST findmyservice v2 fetch with IDs plus time window, ECDH plus SHA256 KDF plus AES-GCM decrypt per report, newest wins. People analog needs the friend relationship key material, the same fetch with those IDs, the same decrypt, and an in-memory join onto the roster instead of CloudKit persistence. Open unknowns needing live traffic: the People advertised-ID derivation, the exact fetch shape for people keys, and where relationship keys surface after mapping import. This scopes the future implementation review.
September 16 CI failure closed: the single failed test out of 3891 in the violating run is the reviewed single-pass observer contract, exactly the gate the reverted ingress broke, and the revert run Dart step is green. The earlier local partial-tally failures are explained as interrupt artifacts of stopping that run, not product failures.
