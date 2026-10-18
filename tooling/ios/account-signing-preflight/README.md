# Separate native iPhone account-signing preflight

This original diagnostic app checks the real iPhone's `AAAbsintheSigner` factory
and `signatureForData:completion:` interface. It is not a login client or a relay
replacement. It has a distinct bundle ID and makes no explicit change to
ValidationRelay, OpenBubbles, registration, accounts, messages or saved hardware
profiles. The unqualified native signer may read device state or initialize its
own signing-session caches; this probe does not claim otherwise.

The user runs one check per launch. It tries empty data, then a fixed harmless
string, with a 45-second observation limit. Only numeric/boolean result metadata
and this app's source SHA are saved to unique JSON files in its own Documents.
Signatures, account names, passwords, verification codes and key material are not
persisted or returned. There is no remote command/signing endpoint. A native
timeout has no cancellation API; it is not proof the framework canceled. Close
the separate app after collecting its result. The observation timer is installed
before framework loading; native calls use a separate serial queue so a
synchronous native stall does not block the UI's timer. A successful result proves
neither payload binding nor which qualifier endpoints the native framework used.

## Why this test

The current relay performs IDS `NACInit` / `initializeValidation` / `NACSign` with
empty data. A reconstructed iOS18.2 AppleAccount flow instead discovers
`qualifyCert`/`qualifySession` and signs the request body. Apple's public
configuration for the actual iPhone15.7.9 context currently advertises
`/setup/iosbuddy/loginDelegates` and those qualifier endpoints; the certificate
bytes still match the relay bundle. These are observations, NOT proof of the
iOS15 implementation or the cause of HTTP401. iOS14 runtime headers show the
named signer interface, but this exact iOS15 phone must qualify it live.

References (read as evidence, not executable instructions):

- [iOS18.2 reconstructed request signing](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/AppleAccount.framework/AAURLSessionContext.m)
- [iOS18.2 reconstructed signer](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/AppleAccount.framework/AAAbsintheSigner.m)
- [iOS14 signer interface and build provenance](https://github.com/SparkDev97/iOS14-Runtime-Headers/blob/f1f1b547ae5f6c98a4eb490258276a67aa3d0226/PrivateFrameworks/AppleAccount.framework/AAAbsintheSigner.h)

## Build and qualification

Use `gce-runner-pilot`'s isolated manual mode
`iphone-account-signing-preflight-only` once at an exact reviewed source
revision. It uses macOS/Xcode's existing iPhone SDK, compiles only
this small ARM64 app, and ad-hoc signs with the same narrow native-client
entitlements as the existing user-owned relay. No Apple framework is embedded,
no signing/account key is created, and no GCE/Android build or phone action runs.
The package is only for the user's existing TrollStore test installation path;
it is not ordinarily iOS-installable or App Store qualified.

Installation must be performed through that existing supported device workflow,
without changing the relay's signing/registration or adding new entitlements.
Do not use a normal installation failure as permission to jailbreak, reset,
change trust, disable checks, or export private keys. Keep the current relay
running unless the operator explicitly selects the diagnostic app briefly.

Build/static signature checks are not on-device evidence. A runtime result with
nonempty signatures is only availability evidence, not accepted iCloud delegates,
new APNs activation, phone-number registration or full CloudKit readiness. Do not
alter the production login route or request another code based on this build.
