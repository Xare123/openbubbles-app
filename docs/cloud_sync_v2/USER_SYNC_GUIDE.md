---
type: Guide
title: Cloud Sync V2 normal user sync guide (candidate rollout)
description: Candidate Profile-based iCloud Message Sync path and developer/public boundary for the CloudKit V2 qualification build.
resource: openbubbles-app
tags: [openbubbles, cloudkit, cloud-sync-v2, user-guide, release-boundary]
timestamp: 2026-09-15
---

# Cloud Sync V2 normal user sync guide (candidate rollout)

> Status: candidate rollout pending integrated UI qualification. Profile
> placement, encryption setup and progress are being qualified together.
> This guide does not assert the public
> build uses this path already, and nothing here is proof of production
> readiness.

## Normal setup (Profile path)

1. Open Profile and find the `iCloud Message Sync` section.
2. Tap `Start / resume`. The flow first prepares encrypted history access
   then resumes from the last saved position.
3. If prompted, choose a trusted Apple device and enter that device's
   passcode or login password in the app. This is not your Android unlock
   PIN or necessarily your Apple Account password. After an app restart, tap `Start / resume`
   again; session counters restart at zero and resume uses durable
   checkpoints, not the on-screen counters.
4. Do not toggle the older sync on and off to unlock encryption. Existing
   legacy users keep their current controls; this candidate does not silently
   migrate an enabled legacy account.

## Regular vs Turbo

- Default is Regular: smaller batches with pauses between batches, leaving
  more room for using the phone.
- Turbo uses larger batches. Confirm the Turbo prompt only if acceptable:
  it can slow the phone, make it hot, and drain the battery.
- Background sync and media downloads are unchanged by this choice.

## What progress means

- History totals are unknown; the bar has no denominator. The card reports
  downloaded and restored-record counts, journaled pages, finished batches,
  per-zone pages, and elapsed time.
- Reaching the remote history head means the remote head was reached, not
  that every local dependency or attachment is done.
- Messages sync as history; media stays on demand. The card reports active
  media work separately, plus per-session completed and failed download
  attempts.

## If it stops or warns

- Offline or saved relay unavailable: check the connection or pairing code,
  then tap `Start / resume`. Downloaded history stays saved.
- Another history sync is active: `Start / resume` stays unavailable
  until it finishes. On-screen counters describe the last foreground run.
- Canceled verification: nothing else starts. Tap `Start / resume` when ready;
  previously downloaded history stays saved.
- Other errors: follow the displayed action. If it persists, open Sync details
  and include the diagnostic code in a support report.
- Restart required (encryption preparation timed out): fully close and
  restart OpenBubbles before resuming; sync and account teardown stay
  blocked for safety until then.
- Chat list did not refresh after a save: restart OpenBubbles to refresh it.
- Leaving the page does not stop sync. Backgrounding the app pauses
  foreground catch-up at a safe boundary. Pause catch-up finishes
  protected work first.

## What this does not promise

No promise of full production readiness, every old attachment, SMS/MMS/RCS
coverage, or a real-time Apple-device mirror. This Profile change covers
foreground history and encryption setup. Automatic uploads and background
reads still have their separate qualification gates; removing their temporary
Developer Mode dependency is a remaining public-rollout task.

The current V2 automatic-upload path covers eligible messages sent by this
installation. It does not yet archive new incoming messages or messages mirrored
from another device. Live iMessage delivery can still work; their appearance in
iCloud depends on an existing cloud copy or another client uploading them.

## Developer Settings vs Canary ADB automation

- Developer Settings stay for diagnostics. Ordinary Profile sync must not
  require them.
- The Canary ADB control receiver is temporary, shell-only test automation:
  it ships only in the `canaryDebug` source set (verified under its java
  language root), has no intent filter,
  requires `android.permission.DUMP`, checks the Canary package and
  debuggable flag and allows only a fixed action list. Only open-dev and
  open-sync launch an activity (MainActivity, with the same normal startup
  side effects as opening Canary yourself); every other action never does,
  and those two must not be used as read-only status substitutes. It must
  be absent from main, debug, profile, and all
  flavor-inherited or release source sets. Do not disable its current
  Canary controls; this guide only documents the boundary.
- V2 rollout read/write gates (shadow sampler, semantic pull, outbound
  canary, local-send runtime, background read, protocol evidence) ship off
  unless a build explicitly opts in with its documented dart-define. They
  must never be blindly enabled for release.

## Support and reports (no secret export)

Send only the on-screen diagnostic code, app and source versions, what was
tapped, and what the card showed. Never export message text, contact
details, credentials, device PINs or passwords, photos, or full logs with
personal content.

---

## Maintainer checklist

- Profile card keeps iOS-style theme and widgets; no redesign or rebrand.
- The ordinary start control stays a plain callback with no developer-mode
  requirement; the card agent owns user wording, so contract checks target
  the callback seam, not titles or counts.
- `CanaryAdbControlReceiver` resolves only under
  `android/app/src/canaryDebug`, never under `src/main`, `src/debug`,
  `src/profile`, or flavor-inherited sets.
- `CloudSyncDevGate` V2 rollout gates and
  `CanaryAdbControlGate.compiledIn` default to false in ordinary builds;
  release workflow adds no V2 dart-defines to the public path.
- Main manifest keeps `android:debuggable="false"`.
- Parent runs Flutter tests in the dependency-ready main checkout after
  integration; this worktree runs only diff checks, no builds.
