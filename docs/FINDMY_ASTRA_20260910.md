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
- Explicit native `optedNotToShare == true` now removes projected coordinates,
  addresses, and timestamp even if the native view still carries an old location.
  Unknown sharing status does not imply revocation. No permissions are inferred
  from missing coordinates or changed remotely.
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
   known handle-less rows update, revocation clears the map marker, valid
   ungeocoded rows show location availability. Unknown new identities remain
   skipped as before; this patch does not invent a handle or restore absent data.
6. Items require a separately reviewed truly read-only adapter or an explicitly
   authorized normal-app workflow. Existing `getBeaconItems` is NOT that adapter.

The actual account-level blocker is not yet established. Do not label absent
coordinates as lack of consent, nor claim this projection repair restores a
location the service did not return.
