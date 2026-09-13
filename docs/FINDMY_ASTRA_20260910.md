---
type: build_runbook
title: Find My current diagnosis and Windows test loop
description: Verified live evidence, exact safe invocation, and remaining People, Devices, and Items gates.
tags: [findmy, windows, diagnostics, recovery]
timestamp: 2026-09-13
---

# Current result

Find My is **not production-qualified**. The Windows test loop works and now
provides real account evidence without an APK rebuild.

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

The verbatim older investigation and superseded guard discussions are preserved
in [Find My history](history/FINDMY_ASTRA_HISTORY_20260910_20260913.md).
