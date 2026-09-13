---
type: Implementation Report
title: Find My bounded projection repair
description: Source-proven stale-row and missing-address fixes, with native service gates still open.
tags: [findmy, regression, windows]
timestamp: 2026-09-11T00:00:00-07:00
---

# Result

Bounded Dart repair on app `6c1a1c6e4b01b71b516e9df87a1cc3aef57cf0dd`.
No Rust/submodule, generated bridge, authentication, sharing, or CloudKit changes.
No live profile, account, device, call, location probe, or private capture access.
This is not proof that the wife's location or missing items now work end-to-end.

## Proven defects fixed

- People responses without accepted handles reused the entire last-good person.
  This discarded fresh coordinates and could retain old coordinates after an
  explicit missing-location response. Now only the handle for that same native
  person ID is reused; every returned record is freshly projected.
- Correction (2026-09-11): the earlier flag-derived location suppression was
  unsupported. `optedNotToShare` has no established directional permission
  meaning in the inspected source. Upstream displays native `lastLocation`
  directly. The review patch restores that behavior; explicit native null still
  clears the prior projected location. No remote sharing permission is changed.
- People and accessory rows with valid coordinates but no geocoded address
  incorrectly said `No location found`. They now say `Location available`.
  Absent/invalid coordinates still say `No location found`, even with an old address.

## Full path and current limits

| Section | Data path | What remains unresolved |
| --- | --- | --- |
| People | FMF `first/initClient` / refresh / selection, Rust `FindMyFriendsStateUpdate` merge, bridge `Follow`, `requestPeople`, projection, valid/unknown buckets | Corrected Dart stale-row path. No real response establishes whether this account currently receives coordinates or fails decoding/auth. |
| Devices / cloud AirPods | FMIP init/refresh, `FindMyPhoneStateUpdate.content`, bridge `FoundDevice`, `refreshCloudDevices`, shared display list | No evidence of whole-list rendering loss. Rows without latitude are present in the collapsed Unknown Location section. Service/parser result needs live probe. |
| AirTags / encrypted Items | keychain clique + `fmfd`, `getBeaconItems`, `sync_item_positions`, BeaconStore records and encrypted location reports, `DartBeacon`, shared display list | Not a read-only workflow: sync holds a CloudKit writer permit and can save alignment records. Missing service/keychain, fetch/decode, and absent reports remain distinct possibilities. Not invoked. |

Prior source checked read-only: `findmy-password-sidecar` commit `085681570`
and `openbubbles-findmy` commit `4e42f3520`. Neither was blindly cherry-picked.
Base already includes independent section refresh, selected-result publication,
live-merge/marker fixes, and neutral missing-location wording. Current scoped
history confirms the original probe scaffold was rejected and replaced with
actual native callbacks; it still explicitly excludes Items.

## Validation

Historical results below predate the flag-suppression correction. The earlier
synthetic 'revocation' cases did not establish Apple field semantics and are
replaced in the separate review patch. Passing mocks never proved consent or
end-to-end behavior.

- 32 passing tests: `findmy_projection_regression_test.dart` (9 new cases),
  `findmy_refresh_test.dart`, `findmy_people_refresh_test.dart`.
- 15 additional passing tests: `findmy_live_merge_test.dart`,
  `findmy_play_sound_test.dart`. No actual sound or network operation is run.
- Targeted helper/test analysis: no issues. Page-inclusive analysis: no errors,
  3 existing warnings and 19 existing deprecation infos, left untouched.
- `git diff --check` passed.
- First test setup lacked package graph metadata; first page test compile lacked
  the detached telephony submodule. Referenced existing SDK/pub cache/telephony
  source read-only through ignored local package metadata; no dependency copies.
  Rerun passed. No Cargo/native/full app build was run.

These are synthetic regression and compile checks, not Apple response parsing,
native end-to-end success, or rendered live UI proof.

## Exact parent-owned live gate

1. Finish/release the current Windows profile operation. Do not run concurrently.
2. Qualify a separate same-source **read-only** Windows variant through the parent
   CI lane. The qualified `local-write` variant is rejected by both the launcher
   receipt/build-ID contract and Dart preflight. Do not relabel its receipt or
   loosen the writer checks. No build was dispatched by this agent.
3. From the matching qualified checkout run
   `tooling/windows/run_cloud_sync_v2_dev.ps1 -FindMyProbe -SkipBuild`.
   Parent may use the private `windows-findmy-probe-request.json` with version 1
   and `selectedHandle` for the already-shared person; do not disclose the value.
4. Return only report `devices`, `people`, and `selected` aggregate counts,
   location presence/age buckets, selected-match boolean, explicit native sharing
   flags and finite failure category/HTTP status. No coordinates, handles or tokens.
   A decode failure requires a follow-up redacted key/type shape from that exact
   failed response before changing serde parsing. Do not dump raw responses.
5. A successful read still needs actual UI verification with this Dart patch:
   known handle-less rows update, native null clears the map marker, valid
   ungeocoded rows show location availability. Unknown new identities remain
   skipped as before; this patch does not invent a handle or restore absent data.
6. Items require a separately reviewed truly read-only adapter or an explicitly
   authorized normal-app workflow. Existing `getBeaconItems` is NOT that adapter.

The actual account-level blocker is not yet established. Do not label absent
coordinates as lack of consent, nor claim this projection repair restores a
location the service did not return.

## September 12 fast-loop safety review: blocked before native initialization

Requested main HEAD: `bc9cbab7937799c39e161564ef957d0d3772ab01`, verified.
The requested exception was a current-Dart Windows test host using the existing
signed native runtime, with **no writer initialization**, not merely no CloudKit
writer operation. No safe launch was implemented under that constraint. No new
`test/live/findmy_windows_live_test.dart` or launcher was added: an enabled stub
or a launcher that reuses the side-effecting bootstrap would not supply the
requested capability.

### Static call-path evidence

- `lib/src/rust/frb_generated.dart`: `executeRustInitializers()` is empty.
  Loading the bridge is distinct from calling the application bootstrap. This
  supports the parent's general test-host approach, but does not qualify the
  subsequent Find My initialization path.
- `prepareWindowsFindMyProbeReads()` in
  `lib/cloud_sync_v2_windows_findmy_probe.dart` calls `readHardware`,
  `decodeIdentity`, `setupPush`, `makeAnisette`, `restoreAccount`, and
  `makeTokenProvider` before the lazy FMIP/FMF constructors.
- `rust/src/api/api.rs::setup_push` immediately persists `hw_info.plist` on
  successful APS connection and spawns a subscriber that persists subsequent
  generated-state updates. Neither write is conditioned on
  `windows_findmy_probe_enabled()`. Retained keys and a completed postdata flag
  do not suppress those writes. `ApsConnection` is opaque to Dart; the inspected
  bridge supplies no non-persisting replacement constructor.
- `do_first_time_init` calls `initialize_windows_protected_keystore`, which
  installs an `update_state` callback using `WindowsProtectedKeystoreWriter`.
  `rust/src/windows_secret_storage.rs::open_windows_keystore` can create a
  missing keystore or migrate a legacy envelope, as well as opening its lock.
  Probe mode suppresses logger initialization, not these storage paths.
- `make_find_my_phone` and `make_find_my_friends` themselves restore the DSID
  from `sharedstreams.plist` and construct FMIP/FMF clients. The FMF constructor
  uses `daemon=false`. Their init/refresh paths do not construct the Items,
  ordinary sync, IDS messaging, or CloudKit writer clients. That narrower fact
  does not make the prerequisite APS/keystore bootstrap writer-free.
- `read_hardware` and `restore_account` require retained state in probe mode;
  the latter rejects incomplete postdata before its update path. This is useful
  protection against fresh-account setup, not an override for the writes above.

### Artifact and ABI limits

Read-only file checks of the supplied ARM64 Debug runtime verified native SHA256
`6C85D27E7F1DBE8D92AAC7C7292F1B5676CB6911C4FD67FD7802CED8C627140E`
and Authenticode status `Valid`. Smart App Control's
`VerifiedAndReputablePolicyState` remained `1`. The DLL was not loaded.

The source base identified by the parent's Windows host notes is `7f2569165`.
Its `setup_push`, both Find My constructors, `restore_account`, `read_hardware`,
`initialize_windows_protected_keystore`, and `do_first_time_init` bodies match
the inspected current bodies after line-ending normalization. The generated
Dart/Rust bridge files have no diff against that base in this review; Dart
advertises FRB `2.3.0` and content hash `-849563835`. This is static comparison,
not a runtime ABI handshake or independent binary-to-source attestation.
Current parent-owned Rust edits include functional changes elsewhere, so the old
DLL must not be presented as executing all current Rust source.

### Remaining parent gate

The earlier full read-only build/receipt gate remains unchanged. A read-only
compile variant alone does not solve this stricter no-persistence requirement.
Proceed only after separately authorizing and qualifying a native adapter that
restores existing protected state without creation/migration/write callbacks,
creates APS without hardware-state persistence, and fails closed when retained
state is insufficient. Native/ABI changes are outside this task's write scope.

Any later explicit test-host launcher must verify the qualified DLL/source/ABI
binding, retain exact `1` environment opt-in, and hold the existing
`Local\OpenBubblesCloudSyncV2Launcher-<SHA256>` profile mutex before profile or
native access. The existing mutex hashes the uppercase full profile path with
trailing backslashes removed. Parent must also exclude independently launched
app/test processes. A mutex does not remove bootstrap side effects.

Keep native read cancellation (currently 15 seconds), bounded Dart sections
(currently 35 seconds), and an outer exact-child process watchdog.
`closeAps` exists, but a Dart `Future.timeout` alone does not cancel native work;
cleanup and lock release must wait for confirmed child termination. No Items,
send, sound, sharing, ordinary sync, auth reset, or identity reset is admitted.
Output remains aggregate presence/age and finite failure categories only. No
live report or account-level conclusion was produced by this review.

### Offline validation

- Existing SDK/cache reused, no dependency copies or native/full build:
  `C:\Codex\Toolchains\flutter-3.44.8-arm64\bin\cache\dart-sdk\bin\dart.exe C:\Codex\Toolchains\flutter-3.44.8-arm64\bin\cache\flutter_tools.snapshot test --no-pub test/services/cloud_sync/cloud_sync_windows_findmy_probe_test.dart --reporter expanded`
  passed **22 tests**. These use synthetic callbacks and cover native-binding
  orchestration, initialization/section timeouts, late completion, exact error
  markers, aggregate redaction, selection, and unavailable-session behavior.
- `tooling/windows/test_windows_findmy_probe_contract.ps1` passed its synthetic
  launcher contract checks, including conflicting-mode rejection and fresh
  launch/process/build binding. It did not launch an app or read a real profile.
- No real account/device/network probe, credentials or database read, native
  load, profile lock acquisition, CI dispatch, push, commit, agent, or worktree
  creation. Parent-owned source and launcher files were not modified.

## Follow-up scope correction: local housekeeping is authorized

The parent clarified that standard retained-identity APS connection-state
persistence and normal existing-keystore open are permitted. The preceding
review's requirement for a new non-persisting APS adapter is superseded. Do not
build that subsystem. Remote CloudKit/Find My writers, Items/keychain sync,
messaging, ringing, sharing changes, IDS registration, logout/reset, identity
creation/change, and interactive provisioning remain outside this operation.
Missing retained hardware, credentials, or a protected keystore must fail before
bootstrap; normal open must not become missing-keystore creation or migration.

### Remaining authentication branch requiring a scope decision

The narrower FMIP/FMF path does not initialize `CloudMessagesClient`,
`FindMyClient` (Items), `KeychainClient`, ordinary sync, or an IDS messaging
client. Its prerequisite authentication is not limited to reading local state:

1. `TokenProvider::new` starts with an empty MobileMe token cache.
   `get_mme_token` calls `refresh_mme`; retained GSA login and MobileMe delegate
   authentication are therefore needed before FMIP/FMF reads.
2. Both the qualified source base `7f2569165:rust/Cargo.toml` and current source
   select `remote-anisette-v3`. This provider is inside the `apple-private-apis`
   submodule pinned at `e2891c317e264dd0eb73e6bb87f0ef37714cc160` by the qualified
   rustpush source. The following fallback also exists at that pinned commit.
3. In `omnisette/src/remote_anisette_v3.rs`,
   `RemoteAnisetteProviderV3::get_anisette_headers` handles
   `AnisetteNotProvisioned` by clearing `adi_pb` and `endpoint` in memory,
   calling `client.provision(state)`, and persisting the replacement state.
   Provisioning opens a remote provisioning session and sends Apple start/end
   provisioning requests. This is automatic, not interactive.
4. The fallback retains `keychain_identifier`; the inspected code does not
   rotate the retained hardware/IDS identity or log out the account. However,
   it does replace authentication provisioning material. It must not be
   described as merely local APS housekeeping or an FMIP/FMF read request.

Checking an existing, provisioned, correctly endpoint-bound file can reject
missing state and endpoint mismatch, but cannot rule out the later server
rejection above. The public bridge has no option to disable that fallback, and
a Dart timeout cannot prevent it. Thus the remaining question is whether this
automatic authentication reprovisioning is permitted by the clarified scope.
If it is not, a narrowly scoped native fail-closed provisioning guard would be
needed and separately qualified, not a new APS subsystem. No native edit or
launch has been authorized or performed here. Full-app receipts remain unchanged.

The supplied DLL hash and `Valid` signature were rechecked without loading it.
No profile files, credentials, or database were read to investigate this branch.

## Implemented fast-loop host after final parent authorization

This section supersedes both earlier blockers. The parent expressly permits
normal local APS/keystore housekeeping and automatic Anisette renewal or
reprovisioning on the already-configured service, including remote authentication
traffic. No new APS subsystem, native guard, generated bridge, compiled launcher,
or native build was needed. Implementation checkout HEAD was `6f778c99e`.

### Scoped files

- `test/live/findmy_windows_live_test.dart`: independent Flutter test host; no
  production harness, app initialization, database, logger, or sync imports.
- `tooling/windows/run_findmy_windows_live.ps1`: explicit parent-only launcher.
  Imports only the existing launcher's functions-only mode to reuse its exact
  profile mutex and exact-process stop checks. Does not run its build/receipt path.
- `tooling/windows/findmy_windows_preflight.py`: standard-library-only binary/XML
  plist preflight and private before/after invariant checks. Never decrypts or
  prints credentials. Python is reused, not installed or copied.
- `tooling/windows/test_findmy_windows_preflight.py` and
  `tooling/windows/test_findmy_windows_live_launcher.ps1`: synthetic local tests.
- This document, append only. All changes remain uncommitted by this agent.

### Admission, side effects, and cleanup

The launcher requires both `-EnableLive` and exact environment value
`OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE=1`. It acquires the existing named mutex for
the fixed `%APPDATA%/OpenBubbles/cloudkit-v2-dev` profile. Parent must finish any
other operation using that profile and exclude manually launched app/test
processes that do not participate in that mutex. No arbitrary profile is accepted.

Before FFI, preflight checks plain non-reparse paths, the existing profile marker,
hardware identity ciphertext, APS token/certificate and existing key alias,
completed GSA postdata and encrypted credentials, an existing v2 protected
keystore, existing GSA/identity-storage keys, retained DSID, and retained Anisette
identifier with the exact configured `https://ani.sidestore.io` endpoint. Missing
or legacy keystores and missing/mismatched service bindings fail closed, with no
creation, migration, alternate endpoint, or interactive repair. ADI material may
be renewed when the retained identifier and service binding already exist.

The supplied native DLL must match the pinned SHA256, have a currently valid
Authenticode signature, and run with Smart App Control still enforced. Generated
Dart bridge/API and shared aggregate probe hashes are pinned too. A separate
`qualification.json` records exact DLL path/hash/signature, bridge expectation,
current Dart HEAD and host/helper hashes. It does not relabel or reuse a full-app
receipt. `RustLib.init` retains FRB's actual version/content-hash check; successful
runtime initialization is recorded as `abi_verified=true`, not assumed from a
signature. Current Rust changes outside the pinned DLL are not executed by it.

The host writes a ready PID and waits for a matching launch/PID acknowledgement.
The launcher acknowledges only a descendant at the exact SDK `flutter_tester.exe`
path after retaining that process's handle/start time. Thus an untracked test
cannot begin native/profile bootstrap. The launcher removes inherited
`OPENBUBBLES_*` modes from the child and passes only this operation's allowlist.

Allowed native flow: normal existing-keystore open, retained hardware/identity
decode, APS connection and its local persistence, Anisette construction, retained
account restore, MobileMe/GSA authentication including authorized Anisette renewal,
FMIP/FMF constructors and one refresh each, and optionally one selected-person
refresh through the existing bounded request parser. APS protocol traffic is not
user messaging. No CloudMessagesClient, CloudKit/keychain/Items client, ordinary
sync, IDS registration, user send, sound, sharing change, reset, or logout is called.
The entire bootstrap is **not mutation-free**: local state and service
authentication renewal are explicitly authorized side effects.

Native Find My requests retain their 15-second cancellation budgets; Dart retains
35-second sections and short initialization budgets. Test timeout is 120 seconds;
the launcher watchdog defaults to 150 seconds, capped at 180 including compilation.
The host closes APS and disposes the bridge. The launcher also stops/confirms all
recorded descendant process instances before releasing its mutex acquisition;
`cleanup.json` records the process identities and confirmation. A failed cleanup
does not report success or intentionally release the acquisition. No job-object,
suspended-process, executable compilation, or machine-wide process kill was added.

Private post-run digests compare credentials, complete OS/relay configuration,
APS keypair, keystore, shared-stream state, and Anisette identifier/endpoint, even
after an operation failure when cleanup succeeds. APS token and ADI renewal are
allowed. Hardware identity ciphertext is not compared byte-for-byte because
`setup_push` saves the same decoded identity with a fresh AES-GCM nonce. Its
identity preservation is source-traced; this is not independent decrypted identity
attestation. Drift is reported as failure, never automatically rolled back.

Raw native/test stdout and stderr are drained to Null, never printed. The host
stores only aggregate probe output and finite failure categories in `report.json`.
Missing data is not converted to zero rows or a consent conclusion. Native
selection flags retain their documented uncertainty. Keep `admission.json`
(private comparison digests) local; share only the aggregate report. Artifacts
live under the profile's `cloud-sync-v2/findmy-testhost/<launch-id>` directory;
no credentials or database are copied there. No actual live artifacts were made
by this agent.

### Parent invocation and remaining live gate

From the reviewed checkout in **PowerShell 7**, after the profile is free:

```powershell
$previousFindMyEnable = $env:OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE
try {
    $env:OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE = '1'
    & .\tooling\windows\run_findmy_windows_live.ps1 -EnableLive
} finally {
    $env:OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE = $previousFindMyEnable
}
```

Defaults reuse the approved ARM64 runtime, installed Flutter 3.44.8 SDK, and
existing Python interpreter. No dependency restoration or native build occurs.
An optional existing `windows-findmy-probe-request.json` remains private and is
not created by this launcher. Directly setting test environment flags is not an
approved substitute for the launcher's preflight/process acknowledgement.

Parent still must establish runtime load acceptance, actual retained-file
compatibility, successful authentication, real service results, and confirmed
cleanup. UI end-to-end verification remains separate. Passing synthetic tests
does not establish any of those live outcomes.

### Offline validation of this implementation

- `py -3 -B tooling/windows/test_findmy_windows_preflight.py`: **11 passed**.
  Binary/XML equivalence, missing files/keys, legacy/invalid fields, endpoint
  preservation, authorized ADI renewal, drift, bounds, symlink rejection, source
  pins and the exact host native-call allowlist. Fixtures are synthetic and removed.
- `tooling/windows/test_findmy_windows_live_launcher.ps1`: passed disabled-entry,
  synthetic mutex contention/reacquisition, descendant discovery, wrong-executable
  stop rejection and confirmed exact-child cleanup. Only synthetic PowerShell
  sleep processes were launched, not an app or native/account probe.
- `tooling/windows/test_windows_findmy_probe_contract.ps1`: existing full-app
  launcher restrictions still pass, unchanged.
- Existing SDK command from above with both
  `test/live/findmy_windows_live_test.dart` and
  `test/services/cloud_sync/cloud_sync_windows_findmy_probe_test.dart`:
  **25 passed, 1 live case skipped**. Includes offline process acknowledgement
  timeout/success and the existing redaction, section deadline and callback tests.
- Targeted Dart analysis: no issues. Scoped whitespace check passed.
- No real profile/credentials/DB read, live invocation, native load, full build,
  CI dispatch, push, commit, agent creation, worktree creation, or cache copying.

### Parent first-run admission failure: SDK dispatcher repair

Parent reported successful preflight, a ready PID, no go/report, and cleanup
containing only the root Dart process. The first synthetic launcher tests used
PowerShell descendants and did not cover the SDK's Dart dispatcher.

An isolated package-free Dart fixture confirmed this installed SDK launches
`dart.exe -> dartvm.exe`. The old discovery allowlist admitted only `dart.exe`
and `flutter_tester.exe`, so it could not traverse that intermediate process.
This is a process-discovery defect, not evidence of a native DLL/policy failure.

The launcher now validates exact SDK paths for `dart.exe`, `dartvm.exe`,
`dartaotruntime.exe`, and `flutter_tester.exe`. Discovery still follows only real
parent edges from retained process instances, now also matching OS creation time.
Only the exact SDK tester, already discovered through that ancestry, can receive
go. A ready PID, matching basename, or unrelated process at the same SDK path
does not establish ownership. No arbitrary ready-PID adoption was added.

`tooling/windows/fixtures/findmy_process_fixture.dart` contains only a bounded
delay and optional synthetic child spawn. The targeted PowerShell test uses the
actual installed SDK to reproduce the old root-only failure, track a four-process
`dart -> dartvm -> dart -> dartvm` chain, reject an unrelated identical-binary
PID and a wrong tester path, and confirm every tracked fixture process exits.
`tooling/windows/test_findmy_windows_live_launcher.ps1` passed these checks.

`admission-status.json` now records root exit code, ready presence/parse status,
tracked process count, expected-tester observation, and admission result. It
contains no compiler/native text. Raw stdout/stderr remain discarded before and
after admission. The parent alone must rerun the real profile; this repair was
tested only with synthetic processes, without profile/credentials access or FFI.

### Test-host-only sole-person selected-detail option

Parent may add `-SelectSolePerson` to the existing `-EnableLive` invocation.
An explicit ID/handle request always wins, including an unmatched explicit
selector. Otherwise the option captures one bounded fresh roster, selects only
its sole valid existing ID in memory, and passes that same-pass result to the
unchanged orchestrator. No duplicate roster refresh, selector file, or identifier
log is produced. Zero/multiple rows, cached/failed/timed-out rosters and invalid
IDs leave selection not tested. Selected-detail uses the existing bounded native
callback and aggregate report. The shared probe and source pins are unchanged.

Offline validation: 12 new selection cases; combined Dart suite **37 passed,
1 live case skipped**; targeted analysis clean; 11 preflight cases and launcher
switch/process tests passed. Patch is ready for parent review/live selected-detail
testing, not evidence that actual Find My location behavior is fixed.
