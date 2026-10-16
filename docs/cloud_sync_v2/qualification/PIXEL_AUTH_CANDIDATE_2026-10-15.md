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

## Completed build receipt, 2026-10-15T19:07Z

Run38785270996 passed on exact source07c6eaea77ca9e0a75ebe8e2ff746c6ec240f5e5.
Source suites6340 passed with five explicit live skips; Android JVM140 passed.
All12 generated bindings matched the committed blobs. Signed artifact12000601092
was downloaded once and independently verified: unchanged Canary identity and
signer, v2/v3 signatures and four required ARM64 libraries. APK SHA256
23176ee57a409cc158fa83d942e3dfd1888c4eb73cc8d338696a9aa75369a183.
Actual deletion receipt plus fresh empty instance/runner inventories establish
cleanup. Detailed timings, native hash and receipts are retained in ignored
build-evidence/pixel-auth-20261015/run-38785270996/RESULT.md.

After user readiness, foreground/unlocked/idle guards passed and adb install -r
completed successfully. Device-local update time2026-10-15 12:57:29. Installed
APK hash matches the signed artifact; original Canary install date/data directory
and Alpha package metadata are unchanged. Startup ui_ready=true, PID32154,
visible Welcome screen; no new-process fatal/bridge-mismatch/not-implemented
events observed. The user's subsequent normal sign-in returned SRP-init HTTP503
HTML before password proof/2FA, corroborated by three private USB log captures.
This is not a login/SMS pass. No new login, OTP, relay reservation or account
mutation was initiated by the agent after that result.

Local follow-up (not in this installed APK): production-client public HTTPS GET
reached GSA404 with zero provider calls. New5xx/429 error classification passed
six focused native regressions, then affected auth45/controller20/login-widget2
tests and the root offline/locked cargo check. Synthetic widget proof confirms
visible errors, spinner recovery and retained input, not live authentication.
The pre-auth reset review found and repaired account/encryption-state deletion
before authentication. Replacement is now deferred until authenticated do_login,
with lifecycle/generation admission protection. Native15 plus related12 tests
passed; this is local synthetic persistence proof, not successful live login.
The later password-page ownership/keyboard repair passed the affected eight-file
Flutter batch. At that checkpoint these changes were local/uncommitted, not in
this APK. No duplicate APK was built. See service-error-fast-loop/RESULT.md and
PASSWORD_UI_RECOVERY.md under the same ignored evidence root.

## Follow-up source batch: failed-login recovery

The reviewed follow-up includes only the service-error classification, deferred
account-state replacement, runtime-writer generation fence, password-page
request ownership and their focused regressions. It changes no generated API,
hardware identity, transport endpoint, TLS policy, automatic retry or SMS route.
The current source Windows DLL passed51 real-FFI cases with bridge -346250373.

The optional Corten adapter, dependency/lock changes, native ARM64 engine
experiment, private auth tools/data and unrelated working-tree edits remain
excluded. Publish nested auth and rustpush pins before the frozen app commit.
Use one existing full Canary qualification to check the exact clean composition,
Android compilation and artifact identity. Do not create another run to retry
Apple503, and do not install until the device is available and idle.

Live sign-in is still unqualified: Windows native-provider SRP-complete503 and
the retained Android-provider Windows comparison SRP-init503. Neither reached
an SMS request or authenticated snapshot. A green build cannot close this gate.
The new recovery batch must retain normal Profile/login, encryption, history,
media, incremental sync, exact write readback and restart acceptance requirements.
