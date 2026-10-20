# Separate native iPhone authentication diagnostic

## Version4 native-header completeness, October20

Actual Signing3 on iPhone15.7.9 returned the fixed native-header-incomplete
failure before any account request. Its first implementation did not identify
which required name was absent. No Apple login failure is inferred from this.
System-registered TrollStore apps still reject House Arrest; do not retry that
unchanged receipt path or switch registration to bypass it.

Version4 calls the runtime's ABI-checked `ak_addLocalUserUUIDHashHeader` only if
the anisette dictionary omitted X-Apple-I-MD-LU. This method is declared in the
already-reviewed pinned iOS15.3.1 NSMutableURLRequest header linked below. No
local UUID/hash, account identity, Android header or provisioning fallback is
fabricated. Existing serial/native factories and strict required keys remain.
If incomplete, the reply now names the first missing *allowlisted header name*,
not a value. This is a targeted native composition candidate and diagnostic,
not proof the local-user field was the original absent field or a working login.
Entitlements, one-shot loopback transport and account-free input remain unchanged.

## Version3 private USB header comparison, October19

Version2 ran on the actual iPhone15.7.9: the native NO-provision fetch reported
machine/OTP/routing present, class/ABI valid and no error. This was observed on
the diagnostic screen with owned-PID cleanup; TrollStore's System registration
rejected both House Arrest modes, so a source-attested JSON receipt was not
retrieved. This is availability evidence, not a working Apple login.

Version3 adds ONLY the exact singleton developer argument
`--ob-native-authkit-usb-once-v1`. Ordinary launch/manual signing and the prior
metadata-only `--ob-native-authkit-no-provision-v1` mode remain unchanged.
The new mode is a private credential-bearing test transport, not a public relay:
it listens on127.0.0.1:49174 for one fixed41-byte `OBHDRS1:`/32lowerhex nonce/newline
frame. It accepts no account, password, verification code, URL or signing body.
Only one connection/response is possible per launch. Existing owner exclusion,
SO_REUSEADDR, deadlines and lifecycle cancellation apply; no SO_REUSEPORT.

The fetch uses `fetchAnisetteDataAndProvisionIfNecessary:error:` with NO and
checks runtime ABI and required data before calling Apple's own
NSMutableURLRequest AuthKit header factories. It does not use a guessed Xcode
context, convenience fetch, provisioning/erase fallback, account object or
URLSession. The factories are declared in pinned iOS15.3.1 runtime headers;
actual15.7.9 dictionary behavior remains unqualified until the new transport runs.

The allowlisted native header map, exact source, nonce and fixed error metadata
travel only in one <=32768B length-prefixed USB reply. Header values must be
bounded printable ASCII and cannot include arbitrary Authorization/Cookie/ADSID
fields. The app displays/saves only counts and disposition metadata. Mutable
wire data is wiped; immutable framework/JSON temporaries are released with their
scope, not claimed cryptographically erased. Internal AuthKit caches/network
may still be used. No raw header values may enter PC logs, files, CI or source.
The PC must validate source/nonce/shape and actual device ID/serial, pin provider
identity across all account phases, and collect a new snapshot on each required
refresh. No Android fallback, profile promotion or production default is implied.

The response also carries an AuthKit-style User-Agent assembled from the actual
runtime CFNetwork bundle version and uname kernel release, not the saved relay
string. The latter is already a full user-agent while the current helper treats
its first token as a platform suffix. This observed contract mismatch is not a
proved explanation of401; the isolated provider must nevertheless keep its
native proof and client metadata coherent throughout the account exchange.

Source leads, not exact15.7.9 runtime proof:
- [iOS15 NSMutableURLRequest factories](https://github.com/yuzhouheike/iOS15.3.1-Runtime-Headers/blob/44a5b62df41f5f20d8af6dead3b426a7b401e118/Frameworks/CFNetwork.framework/NSMutableURLRequest.h)
- [Reconstructed native dictionary formatting](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/AuthKit.framework/NSMutableURLRequest%28AuthKit%29.m)

Everything below describes the original/default and metadata-only modes unless
explicitly stated otherwise. The new private USB mode is not metadata-only.

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
