# Canary ADB Control (removable, debug-only)

Plain-ADB control for the temporary Android Canary qualification loop. It can
query content-free readiness, classify the current route, open Developer Tools,
start a protected semantic catch-up, and query that catch-up later. It removes
the need for screenshot/coordinate automation while this branch is tested.

## Scope and lifecycle boundary

The native receiver exists only in `src/canaryDebug`, requires the privileged
`android.permission.DUMP` permission held by the ADB shell, and has no intent
filter. Dart additionally requires a compile flag, `kDebugMode`, the Canary
package, an exact action allowlist, and fixed result schemas.

`ping`, `status`, `route`, `semantic-status`, and `semantic-start` **never
launch MainActivity**. The app must already have a ready Dart engine. This is
intentional: starting the ordinary activity runs normal OpenBubbles lifecycle,
which may start configured services or wake an opted-in writer. If the engine
is absent, the receiver returns `adb_app_not_ready` and drops nothing.

Only `open-dev` and `open-sync` launch MainActivity. The host then waits for a
real ping/result handshake, not a fixed sleep, before sending navigation. Those
two commands therefore have the same normal startup side effects as the user
opening Canary. Do not use them as a read-only status substitute.

## Semantic operation

`semantic-start -Confirm` performs two messages with the same action and
sequence. The first reads the full preflight and issues a cryptographically
random, 20-second, one-use challenge. The second must return that challenge;
it is bound to `semantic_pull_start` and the sequence and is consumed on every
attempt. Preconditions are read again after challenge consumption.

The accepted result is immediate. The bounded pull continues asynchronously,
so a large catch-up cannot be mistaken for a host timeout. Query progress and
completion with `semantic-status`.

The special ADB entry point does not call `_queueCloudSyncV2LocalSends` when it
finishes. The ADB command itself therefore does not wake the outbound worker.
It is not a zero-mutation operation: normal semantic sync fetches CloudKit
records, projects supported records into local ObjectBox entities, persists
reports, and advances durable read/projection checkpoints under the existing
safety/interlock rules. CloudKit saves, CloudKit deletes, local tombstone
deletion, and outbound admission are not called by this entry point. An already
running writer remains governed by the app's normal runtime, which is why the
preflight reports settled versus blocked outbox state and the host never starts
the activity for semantic actions.

## Fixed result contracts

Results contain only exact keys and values for their action/code pair:

- setup, Developer Mode, legacy enabled/active, logout, UI/auth readiness;
- semantic compiled/in-flight/quiescing/available state;
- coordinator state and an outbox class (`empty`, `settled`, `blocked`, or
  `unavailable`), never outbox payloads or operation IDs;
- coarse route class (`developer_tools`, `other`, or `unknown`), never a
  dynamic route;
- pull state, bounded pass count, terminal outcome, and fixed failure class;
- fixed report diagnostic code and zone allowlists. The latter become populated
  after the feature branch's diagnostic report exception is integrated.

Message text, phone numbers, email addresses, GUIDs, routes, account/device
identity, credentials, record values, CloudKit tokens, and file paths are
structurally unrepresentable. The only opaque value is the short-lived control
challenge. Native receiver log lines are fixed phrases; Dart logs only the
closed action and result code and never serializes result data to logs.

## Commands

```powershell
./tooling/canary_adb_control.ps1 -Action status
./tooling/canary_adb_control.ps1 -Action open-sync
./tooling/canary_adb_control.ps1 -Action semantic-start
./tooling/canary_adb_control.ps1 -Action semantic-start -Confirm
./tooling/canary_adb_control.ps1 -Action semantic-status
```

The first semantic-start is a non-executing preflight. `-Confirm` performs a
fresh preflight/challenge and returns `adb_semantic_accepted`, not completion.

Build with both temporary flags:

```text
--dart-define=OPENBUBBLES_CANARY_ADB_CONTROL=true
--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true
```

## Removal

Delete the canaryDebug manifest/receiver, this document, the host script, the
dispatcher and its test. Remove every `CANARY_ADB_HOOK` import/case/getter/read-
only entry point. Build without the ADB flag immediately disables Dart handling.
This utility must be removed before an upstream PR or production build.

## Verification gates

Static/unit gates cover exact allowlists, parser rejection, action-specific
schemas, plaintext/phone/email/GUID/dynamic-route rejection, challenge binding
and expiry, no receiver-side activity start, fixed receiver logs, and manifest
source-set scope. Qualification still needs:

1. Flutter format/analyze and targeted/full relevant tests.
2. Assemble `canaryDebug` and `canaryRelease`; inspect merged manifests or APKs
   to prove the receiver exists only in debug.
3. Live ADB proof that shell delivery through `DUMP` works, background status
   does not foreground Canary, a dead engine returns `adb_app_not_ready`,
   navigation waits for readiness, semantic start returns promptly, and a later
   status reaches the same terminal result as the UI.

Do not weaken the permission or add a background activity launch if live shell
delivery fails. Re-open the mechanism instead.
