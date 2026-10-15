# Pixel authentication recovery candidate, 2026-10-15

## Observed failure and scope

Saved Alpha and Canary logs both contain Apple status -80045. Installed Canary
was dated October 2 and Alpha August 29; neither contains this patch set.
The read-only Canary control reported setup/auth incomplete, sync inactive and
the outgoing queue settled. Logs were retained privately; no reset, login,
registration repair, upload or message operation was performed for the capture.

## Included repairs

- Match remote ADI authentication descriptors to the provider metadata. The
  narrow compatibility mapping requires the exact anisette-v3-server v2.2.2
  implementation, old MacBookPro descriptor and AKD user agent. Other providers
  keep their returned descriptors; native providers retain existing behavior.
  Hardware headers, APS token, account context and saved activation are retained.
- Keep ec0/hsc409 without `au` in verification, not authenticated registration.
  An already-issued trusted-device challenge can use direct verification without
  creating another challenge. Accepted codes still require fresh SRP/PET proof.
- Preserve saved device/key material on read, import and persistence failures.
  Do not replace unreadable keys or report successful activation after failure.
- Keep stale SMS/verification responses from replacing a newer login session.
  Surface a rejected trusted-phone request without claiming that SMS was sent.
- Initialize the native profile before restoring it. Rust and generated Dart
  bindings must travel together; candidate ABI content hash is -346250373.

The optional Corten development provider, its dependency/lock changes and private
inputs are excluded from this candidate. Test-only SMS bootstrap experiments
remain ignored and are not enabled in application builds or treated as a fix.

## Qualification and limits

- Native focused library tests: 54 passed, four manual/network cases ignored.
  This includes provider metadata validation, header bounds, cached proofs and
  preservation of independent hardware/account fields.
- Windows Flutter focused batch: 37 passed after the user independently changed
  Smart App Control. No security setting was changed by the agent. The initial
  blocked invocation ran no tests.
- The existing keystore fixture qualification reported 13 passing cases. Current
  patches were reviewed for no-overwrite and serialized-import behavior.
- Independent read-only review found no blocking defect in the three-file
  provider change. Metadata is required before remote authentication; a failed
  initialization may refetch on a later call, while successful metadata is cached
  for that provider instance.

These are source and host tests, not Pixel sign-in or CloudKit acceptance. Native
SMS setup previously returned HTTP 403 before an SMS PUT; that gate is still
open. Do not promise that this build fixes every -80045 cause or SMS delivery.

## Build and acceptance

Use the existing `gce-runner-pilot.yml` workflow on remote ref
`agent/gce-runner-pilot` (verified workflow SHA
993ba2a046b70ebf75c872f610586b174b17b309), one standard n2d-standard-16 in
us-west1-b, full validation, Canary/ARM64, both writer capability flags enabled,
and the existing 75-minute lifetime/signing/cleanup controls. Publish exact
nested source pins first and fast-forward the trusted received-origin branch.

Require generated-binding parity, selected suites, APK/native-library checks,
unchanged Canary package/signing identity and verified runner/VM cleanup. Update
only Canary in place. Preserve Alpha, local history, credentials and outbox data.
Live acceptance begins with normal activation/sign-in and the selected 2FA
channel; do not clear data, weaken TLS, guess phone IDs or loop login attempts.
