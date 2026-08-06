# Diagnostics and delivery troubleshooting

Use this guide to collect evidence for slow delivery, duplicate messages,
rendering failures, battery drain, or incorrect routing. The goal is a small,
redacted reproduction, not a permanent verbose log.

## Controlled reproduction

1. Keep Google Messages as the default SMS app.
2. Turn off OpenBubbles SMS forwarding while testing iMessage delivery.
3. Turn on OpenBubbles Developer Mode.
4. Force-close and reopen the test build.
5. Send one uniquely identifiable test message in each direction.
6. Record the sender, receiver, network (Wi-Fi or cellular), and approximate
   timestamps locally. Do not put message text or phone numbers in a public
   issue.
7. Export only the relevant log window and remove credentials and personal
   content before sharing.

For Android-side timing, a developer can also collect a bounded window with
the package filter (replace the package if testing a different flavor):

```bash
adb logcat -c
adb shell am force-stop com.bluebubbles.messaging.alpha
adb shell monkey -p com.bluebubbles.messaging.alpha 1
# Reproduce one operation, then stop capture promptly.
adb logcat -d -v threadtime -t 2000 > openbubbles-log.txt
```

Do not attach an unfiltered `logcat` dump. It can contain notification text,
contact data, URLs, and platform identifiers.

## What to look for

### Slow or missing receives

Trace the sequence, in order:

1. relay/WebSocket receive
2. event parsing and validation
3. message-service queueing
4. database save/upsert
5. acknowledgement back to the relay
6. UI refresh and notification

A transport connection without a database save is not a delivered message.
An acknowledgement before persistence can create a loss window after a process
restart. Any instrumentation should use a short redacted event ID and elapsed
milliseconds, never message text or a secret.

On Android, a notification can arrive before Flutter finishes registering its
method-channel handler. The bounded startup handoff records only these redacted
state markers:

- `engine_buffered`: the pointer is waiting for the UI engine to become ready;
- `engine_buffer_flush`: the ready UI engine accepted the buffered pointer;
- `headless_handoff`: a destroyed UI engine transferred the pointer once to
  the existing headless worker.

The raw native pointer must never be logged. Repeated `engine_buffered` entries
without a flush or handoff indicate a startup-readiness regression.

### Duplicates or wrong app routing

Check that only one SMS/MMS/RCS path is enabled. If both Google Messages and
OpenBubbles forwarding are enabled, disable forwarding and repeat the test.
For iMessage, verify that the event is not being inserted once from the live
stream and again from a refresh/reconnect path. Compare stable server/message
IDs rather than message text.

### Battery drain

Look for reconnect loops, unbounded timers, repeated database refreshes, or
notifications that fail and retry continuously. A healthy relay should use
bounded reconnect backoff and one active connection manager. Compare Android
battery statistics over the same time window with the test build stopped.

### UI/rendering failures

Repeated `LateError`, null avatar, or “unexpected error occurred when
rendering” entries indicate a UI data-shape problem. Capture the incident ID,
screen, and safe event timing. Do not work around a rendering failure by
silently dropping the entire conversation.

### Registration and validation

Registration input should not be decoded until it matches the complete expected
format. Validation errors should be surfaced as a bounded failure and retry,
not a tight loop. Relay registration secrets belong in Keychain on iOS and must
never appear in logs or shared preferences.

### Cloud message sync

A message is synchronized only after the CloudKit API explicitly confirms the
write. A missing or false result remains pending and should be retried. A batch
that contains only retryable failures stops without spinning forever.

When diagnosing a cross-device gap, distinguish:

1. local database save;
2. cloud upload requested;
3. cloud write confirmed;
4. other device pull started;
5. pulled record saved locally.

Do not treat an upload request or generated record ID as proof of cloud
persistence. Current sync is startup, periodic, or manual rather than a
continuous real-time replication channel.

## Current audit themes

The recent field logs identified five recurring classes to keep covered by
tests and review:

- notification avatar data can be incomplete;
- CloudKit plist decoding can receive an unexpected byte-array shape;
- reaction events can race message persistence;
- anisette/validation WebSockets can reset during provisioning;
- APS can lose DNS or a socket, reconnect, and then miss or mis-correlate a
  rapid send acknowledgement. Keep DNS, TCP 5223-to-443 fallback, connection
  budget, subscribe-before-send, and acknowledgement-ID tests together.

These are not all necessarily present in every build. When a fix is proposed,
include the before/after log counts and a focused test or reproduction.

### Redacted Pixel field evidence

The pre-fix Pixel capture contained 406 warnings and 9 errors in the affected
archived log. The useful signals were:

- contact matching emitted hundreds of per-candidate warnings that included
  phone or email identifiers;
- relay reminder scheduling sometimes ran before timezone initialization;
- initial clique checks and scheduled password or CloudKit maintenance could
  escape as unhandled asynchronous errors when the account was not in a
  clique.

The current implementation replaces candidate-level output with one redacted
debug summary, initializes timezone data inside the notification service
owner with a UTC fallback, and awaits or catches the initial and scheduled
maintenance futures. A failed clique check now records the service as not
ready instead of escaping through the Flutter zone.

After the updated profile APK was installed over the existing package, the
bounded per-process `logcat` check contained no matching fatal, exception,
timeout, clique, APS, CloudKit, or WebSocket entry. The active on-device
developer log was still empty, so this is a startup smoke check, not an
endurance or delivery-pass claim.

### Fullscreen video paging

On mobile, video controls and the surrounding `PageView` can both claim a
horizontal drag. The fullscreen viewer now gives an active video one
navigation owner: a bounded raw-pointer swipe surface advances the parent
pager, while the bottom 88 logical pixels remain reserved for playback
controls. Inactive videos pause and do not retain their page unnecessarily.

Keep the gesture unit tests and a physical-device check together. Test from
the middle of a playing video in both directions, then verify that seeking,
play/pause, and the bottom controls still work. Do not call the gesture fix
device-validated until that exact check passes.

## Privacy and retention

Keep raw captures in a local, access-controlled folder. Delete them when the
issue is closed. Redact before uploading to GitHub, Discord, or a bug tracker.
Never request or paste an Apple password, two-factor code, registration secret,
private key, or full device identifier into an issue.
