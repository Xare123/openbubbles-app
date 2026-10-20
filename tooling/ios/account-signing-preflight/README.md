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

### Version2 native AuthKit discriminator, October19

Real iPhone body and empty Absinthe proofs were both transported freshly into
the Windows account test; both reached the expected service endpoint with over
290 seconds of PET lifetime and still returned401. This does not establish the
cause, but signing availability alone is not sufficient. The next discriminator
is native iPhone anisette availability, separate from qualifier signing.

Normal/manual app launch retains the original signing check. The exact singleton
developer launch argument `--ob-native-authkit-no-provision-v1` instead starts one
native AuthKit check on first activation. Runtime verifies the exact class,
selector return/argument encodings, then calls
`fetchAnisetteDataAndProvisionIfNecessary:error:` with **NO**. No convenience
retrieval/provisioning/erase/SIM fallback, password, verification code or account
login is used. A 45-second observer precedes framework work; cancellation prevents
queued fetches and late results cannot replace a finished receipt. Idle-lock
prevention applies only while this short diagnostic is active and is restored on
finish/resignation. Native internal cache/network access is possible even with
provisioning disabled; a timeout does not cancel an already-running framework call.

Only class/ABI/fetch and data-presence booleans plus an allowlisted error domain
and integer code enter the existing metadata receipt. No OTP, machine ID or
routing value is persisted or displayed. Native availability is not login proof.
The parent collector selects only a newly created receipt from this app and exact
source, then verifies that its owned process stopped. It does not read other apps.

Version2 adds only `com.apple.authkit.client.private` under the user's explicit
full-device diagnostic authorization. The app's identity/keychain groups remain
unchanged; no platform-application or account-store privilege is added. This is
needed to test the native client boundary shown by existing implementations,
not a claim that the exact15.7.9 daemon will accept it. No global entitlement,
trust, account or relay setting is changed by building this package.

Primary ABI/implementation leads, not exact15.7.9 runtime proof:

- [iOS15.3.1 provisioning controller](https://github.com/yuzhouheike/iOS15.3.1-Runtime-Headers/blob/44a5b62df41f5f20d8af6dead3b426a7b401e118/PrivateFrameworks/AuthKit.framework/AKAnisetteProvisioningController.h)
- [iOS15.3.1 data accessors](https://github.com/yuzhouheike/iOS15.3.1-Runtime-Headers/blob/44a5b62df41f5f20d8af6dead3b426a7b401e118/PrivateFrameworks/AuthKit.framework/AKAnisetteData.h)
- [AltDaemon native header implementation](https://github.com/altstoreio/AltStore/blob/56854e66fef2eac32dad88dcbad1dc131d430e60/AltDaemon/AnisetteDataManager.swift)

### Existing isolated build lane

Use `gce-runner-pilot`'s isolated manual mode
`iphone-account-signing-preflight-only` once at an exact reviewed source
revision. It uses macOS/Xcode's existing iPhone SDK, compiles only
this small ARM64 app, and ad-hoc signs only this separate diagnostic's reviewed
entitlements described above. No Apple framework is embedded,
no signing/account key is created, and no GCE/Android build or phone action runs.
The package is only for the user's existing TrollStore test installation path;
it is not ordinarily iOS-installable or App Store qualified.

Installation must be performed through that existing supported device workflow,
without changing the relay's signing/registration or adding unreviewed entitlements.
Do not use a normal installation failure as permission to jailbreak, reset,
change trust, disable checks, or export private keys. Keep the current relay
running unless the operator explicitly selects the diagnostic app briefly.

Build/static signature checks are not on-device evidence. A runtime result with
nonempty signatures is only availability evidence, not accepted iCloud delegates,
new APNs activation, phone-number registration or full CloudKit readiness. Do not
alter the production login route or request another code based on this build.
