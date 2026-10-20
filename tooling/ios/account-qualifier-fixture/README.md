# Separate single-use USB account qualifier fixture

Bundle `dev.openbubbles.diagnostics.accountqualifier` is separate from the original
Account Signing Check and ValidationRelay. It signs only an empty input and the
original bytes of one parent-supplied, bundled, credential-free V2 request body.
There is no login/account/registration/reset call, private-key export, HTTP server,
arbitrary signing request, signature file, or production route change in this app.
The private Apple framework may independently access native state, create signing
caches, or use its own network operations. Its exact iOS15 implementation and
server acceptance remain unqualified.

## Frozen inputs required before building

Parent supplies **both** `body.plist` and `fixture.json` in this source directory.
The build fails closed if either is missing. This implementation does not generate
a replacement body. `fixture.json` has exactly these keys:

```json
{"schema":1,"run_id":"0a34797b7dc44e8e8a41f1fe4c2b01d8","client_id":"7332110D-8CF0-4B5A-9C4D-EB9C806CF832","body_sha256":"<64 lowercase hex for actual frozen body bytes>"}
```

The bundled `body.plist` must be the final Rust-produced XML plist, at most 8 KiB.
The source file may have exactly one patch-added final LF: build staging removes
that one byte **only if** the remaining bytes match the manifest's production SHA.
Already matching source bytes are unchanged. Extra LF/CRLF, whitespace trimming,
XML reserialization or a hash mismatch are never accepted as normalization.
The current source is 648 bytes and the production/staged body is exactly 647,
SHA256 `9b2e7baef14416e69de6d8a09d3096c5d697b9b02216af5edda3157523cec239`.
The schema
guard permits exactly protocolVersion `1.0`, userInfo (client-id matching the
manifest, bounded printable language/timezone), and the IDS/MobileMe delegate
dictionaries (IDS protocol-version `4`). No credentials/Authorization/account IDs
are admitted. This validates the supplied serialization without rewriting XML.
Any future producer schema change requires review here first.

`validate_fixture.py` rejects duplicate JSON/plist keys, unknown fields, wrong
types, non-XML data, excessive size and SHA mismatch. The build validates source
inputs with `--source`, generates exact output bytes with `--stage`, then validates
the staged files strictly and embeds both exact SHA256 digests into the executable.
Neither strict staged validation nor runtime permits final-LF normalization.
Runtime repeats the bundle ID, byte hashes, sizes and
schema checks before listening. JSON SHA binding also prevents ambiguous metadata
from being substituted after build validation. Source SHA is embedded separately.

## One exchange per launch

1. Complete/dismiss the trusted-device 2FA push first. After the PC reaches its
   postdata/fixture-wait stage, bring this fixture foreground and tap **Arm once**.
   Resigning active (including a system prompt or app switch) cancels this
   launch's exchange; do not arm before the 2FA interaction. Normal/manual launch
   never automatically arms. Keep the fixture foreground until its final
   disposition appears. The optional exact PC-launch mode below replaces only
   this tap, never the fixed USB frame or any account-authorization gate.
2. Bind IPv4 **127.0.0.1:49173** only. Address reuse permits a new process after
   TCP teardown; duplicate live-port reuse, all-interface and IPv6 listeners
   remain forbidden. A second live listener must still fail.
   Parent must separately verify that its existing paired usbmux route reaches
   that exact loopback socket. Loopback itself does not authenticate a PC or
   exclude another local iPhone process. The nonce is a fixed fixture admission
   token, not an account credential; do not publish/use a public fixture package.
3. Accept one connection within 120 seconds and close the listener immediately.
   A bad/idle client consumes this launch's opportunity. No accept/retry loop
   after that first successful accept.
4. PC sends exactly **41 ASCII bytes**: `OBQUAL2:` + manifest run_id + newline.
   This is the complete frame: **do not half-close/shutdown the write direction**.
   The reader completes with that direction still open, within 10 seconds, and
   rejects wrong/truncated frames or trailing bytes observed in its nonblocking
   peek. Without EOF, future appended bytes cannot be ruled out before signing.
   They are never interpreted or signed, cannot supply a payload, and cannot
   trigger a second operation. A queued extra byte or second frame rejects the
   exchange before signing. `OBQUAL1` is not accepted.
5. Use one `AAAbsintheSigner.sharedSigner` result for sequential empty/body calls.
   The main observer is installed before native dispatch. A separate native serial
   queue prevents factory/sign stalls blocking UI or timeout observation. Every
   call/callback checks the deadline and stage; duplicate/late replies are ignored.
6. Reply with 4-byte unsigned big-endian JSON length, then that many UTF-8 bytes
   (maximum 16,384). The exact keys are:

   `schema`, `source_sha`, `run_id`, `body_sha256`, `empty_signature_b64`,
   `body_signature_b64`, `elapsed_ms`, `error`.

   Success has `error: null`. Every failure has empty strings for both proof fields
   and a fixed error enum. Signing elapsed_ms excludes waiting for the PC and
   reports actual elapsed time; a timeout can run slightly late if the OS delays
   observation, and the PC must reject late success. Timeout outcomes carry no
   partial proof. Every signature is at most 2,048 bytes, matching the PC bound.
7. The accepted socket closes after the reply or on every exit. No descriptor is
   shared with native callbacks or main timers. Closing assigns `-1` before the
   actual close, preventing duplicate/late descriptor reuse. Backgrounding cancels
   observation; no background mode keeps the fixture alive.

The signing budget is at most 45 seconds for both calls together. The **entire
accepted exchange** is capped at 54 seconds to fit the parent's 55-second broker;
a slow header shortens signing time, and the reply has at most 3 seconds. All
network I/O is nonblocking and polls deadline/cancellation at most every 100 ms.
The signer has no cancellation API here: timeout/disconnect does not prove the
framework stopped. No late proof can enter a reply after deadline/consumption.
Native-owned returned bytes cannot be promised securely erased. Owned mutable
copies are cleared; transient serialization/callback objects leave scope without
any persistent write. UI displays only disposition and two byte counts.

October18 human runtime evidence for the earlier EOF-based fixture showed
`delivery-failed`, empty 261 bytes and body 917 bytes. Those counts are retained
only after both native calls succeed: the observed failure was reply delivery,
not cancellation or a request-only/native-signing failure. EOF-triggered usbmux
tunnel teardown is a supported inference, not a uniquely proven cause. `OBQUAL2`
removes that half-close dependency. Counts do not prove body binding or Apple
acceptance; the revised framing still requires separate transport qualification.

Fixed reply errors: `invalid-request`, `cancelled`, `signing-timeout`,
`framework-unavailable`, `factory-unavailable`, `selector-unavailable`,
`native-signing-failed`, `native-exception`, `internal-failure`. Before connection,
bundle/listener/arm failures have only local metadata UI, with no response socket.

## Optional PC launch, protocol 1

Manual **Arm once** remains the default. A supported developer launch may request
automatic arming only by passing exactly one argument after the executable:

```text
--ob-usb-transport-once-v1
```

The shared C parser accepts only that exact singleton. Duplicate flags, unknown
arguments, extra/empty arguments, spelling/case changes, and normal system launch
arguments do not opt in. Such launches remain manual; no environment variable,
URL/deep link, launch-options dictionary, or socket payload can enable auto mode.
The original process arguments are checked before `UIApplicationMain`; a later
activation cannot change the selection in an already-running process.

An opted-in launch arms synchronously on its **first** `applicationDidBecomeActive`,
using the same one-use `arm` method, 120-second window, listener and frozen inputs.
It does not arm during `didFinishLaunching`. Later active transitions cannot arm
again. Resigning active cancels the run, including a pending auto-arm before the
first active transition; it never rearms on return. Manual launches retain their
existing button behavior and cancellation after arming. Parent must order any
developer launch after prompts/2FA have been dismissed and keep the app foreground.

`Info.plist` advertises `OBUSBAutomationProtocol` string `1` and `CFBundleVersion`
string `3`. These are capability markers, not source identity or authorization.
The response's existing compiled-in `source_sha` and exact `body_sha256` remain
mandatory parent checks; no placeholder/static `OBSourceSHA` is added to the plist.
The launch argument is **not permission to log in**: this fixture still performs
only the same empty/frozen-body two native calls after one matching fixed frame.

This mode does not change entitlements, provisioning, Developer Mode, pairing,
background execution, or installability. In particular, the existing ad-hoc package
and private signing entitlement do not become ordinary non-jailbreak development
capabilities through a launch flag. Parent owns non-jailbreak signing, foreground
developer-launch and native-signing qualification; all remain unqualified here.

## Build and limits

On the existing macOS SDK runner, with a NEW absolute output directory:

```sh
OB_SOURCE_SHA=<40 lowercase hex source revision> bash tooling/ios/account-qualifier-fixture/build.sh /absolute/new-output
```

The script performs only local ARM64 compilation, ad-hoc signing, signature/package
checks and hashes. It never downloads, dispatches, installs, launches or accesses a
device/account. It uses exactly the preflight's narrow native entitlement classes,
with this app's own application/keychain identifiers. Parent owns workflow and
exact-source qualification; no workflow is modified here.

The existing Mac CI guard file compiles a small C/POSIX harness against the same
`launch_mode.h` and `request_reader.h` included by `main.m`. It executes the exact
launch parser/first-active/cancellation latch, and verifies reader completion while the
peer's write direction stays open, and rejection of truncated/wrong frames and
queued trailing bytes/frames under a deadline. These executable reader tests are
Mac-only and skipped on Windows; they do not invoke the native signer or qualify
usbmux, the iOS app lifecycle, or login.

Runtime and login remain **unqualified** until separately observed. The iOS18.2
reconstruction indicates a cached NAC context and per-input signing, not a reusable
cached signature. Its 540-second context cache does not establish signature expiry.

### October19 rapid-relaunch repair

The real iPhone completed one automated exchange, then an immediate fresh launch
showed `listener-unavailable` before either signing call. This also interrupted
the account harness locally; it is not an Apple authentication result. The old
listener did not enable address reuse. Version3 uses the shared
`loopback_listener.h` with `SO_REUSEADDR`, nonblocking/CLOEXEC descriptors, the
same fixed loopback address/port and a one-connection backlog. It never enables
duplicate active-port sharing. See Apple's archived
[setsockopt reference](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsockopt.2.html).

The Mac harness compiles this actual shared listener, verifies its socket options
and exclusive live owner, then performs four immediate server-first TCP teardown
and rebind cycles. These are kernel tests, not a mock of bind. Windows skips these
eight Mac C cases. A version3 build and real iPhone rapid-relaunch check remain
necessary before claiming this repair is deployed. Signing, body, framing,
entitlements and account behavior are unchanged.
Consume each returned proof at most once promptly; freeze final body bytes before
signing and send those identical bytes. Lengths alone do not prove body binding.
Native-empty versus native-body comparison must retain endpoint/header semantics;
production auth, pairing/transport and server acceptance belong to the parent.
