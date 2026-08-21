---
type: runbook
title: FaceTime Reliability Testing
description: Pre-install gates and minimal live-call validation for Android FaceTime changes.
tags: [facetime, android, testing, reliability]
timestamp: 2026-08-21
---

# FaceTime reliability testing

Repeated calls are the final integration check, not the primary debugging loop. A candidate APK is eligible for device installation only after these gates pass:

1. Rust signaling replay: command 207 join, command 209 snapshot, and command 208 leave, including partial and out-of-order events.
2. Android call-state scenarios: incoming answer, outgoing join retries, stale timeout isolation, and WebView compatibility transforms.
3. Cached Apple bundle preflight: confirm the current `main.js` still matches the three compatibility patches without exposing the FaceTime link.
4. GitHub Actions: Rust, Flutter, Android unit/Kotlin compilation, APK native-library checks, and Windows builds.

Run the device-independent tests:

```powershell
cd C:\Codex\OpenBubblesReview\worktrees\device-alpha-v27\android
.\gradlew.bat :app:testAlphaDebugUnitTest --tests "com.bluebubbles.messaging.services.facetime.*" --no-daemon
```

```bash
cd /mnt/c/Codex/OpenBubblesReview/worktrees/device-alpha-v27/rustpush
mkdir -p certs/proxy
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout certs/proxy/push_key.pem \
  -out certs/proxy/push_certificate_chain.pem
CARGO_TARGET_DIR=/tmp/openbubbles-rustpush-facetime cargo test --lib --features remote-anisette-v3 facetime::tests
```

With the existing Alpha app connected through ADB, validate Apple's cached bundle without making a call:

```powershell
.\tooling\facetime\verify_cached_web_bundle.ps1 -Serial <adb-serial>
```

After all gates pass, install in place with `adb install -r -t`. Preserve app storage. Validate only one outgoing and one incoming call. A successful live result requires all of the following:

- the remote party can answer without the call ending;
- both sides receive audio and video;
- the Pixel reaches a confirmed joined state;
- explicit Leave ends the matching call only;
- no unknown-participant sequence, WebView renderer loss, or fatal process error appears in the fresh diagnostics.
