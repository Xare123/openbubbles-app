# services/network/ — Network Communication

## HTTP (`http_service.dart`)
Dio-based REST client. All HTTP endpoints live here — don't add endpoints elsewhere.
- `runApiGuarded()` — wraps every call; handles retries on 502, propagates errors
- `buildQueryParams(map)` — injects auth GUID; call this on every request
- `returnSuccessOrError(response)` — validates status code
- Timeouts configured globally from settings (`apiTimeout`); don't override per-request

See `.claude/rules/api.md` for full HTTP conventions.

## WebSocket (`socket_service.dart`)
socket_io_client connection to the BlueBubbles server.
- State: `Rx<SocketState>` — `connected / disconnected / error / connecting`
- Auto-reconnect on connectivity change (monitors `Connectivity()` stream)
- Don't create additional `Socket` instances — one connection managed here

## TLS / Certificates
- `websocket_adapter.dart` — custom `HttpClientAdapter` for self-signed cert support
- `http_overrides.dart` — global `HttpOverrides` for certificate validation
- `user_certificates.dart` — user-added certificate management (Android native injection)

## Downloads (`downloads_service.dart`)
Attachment download state machine:
`queued → downloading → processing → complete / error`
- Concurrent download management
- EXIF extraction and format conversion post-download

## Firebase (`firebase/`) → `firebase/CLAUDE.md`
- `cloud_messaging_service.dart` — FCM device token registration (Android + Desktop)
- `firebase_database_service.dart` — Firebase Dart client setup for Desktop/Web; config fetching with fallback URLs
