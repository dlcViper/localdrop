# LocalDrop

An Android app (Flutter) that turns your phone into a local-network file transfer hub. Other devices connect via browser — no app install needed on the client side.

## Phase 1 — Implemented

- **Embedded HTTP server** (shelf + shelf_router) on local IP, port 8080 with auto-fallback
- **PIN auth** with SHA-256 session tokens (not logged)
- **File listing** with folders + files, breadcrumb navigation
- **Downloads** with HTTP Range support, correct Content-Disposition (RFC 5987 filename* for unicode), `Cache-Control: no-store`
- **Zip downloads** — streamed stored-method ZIP, no full in-memory buffering
- **Uploads** — multipart form data, streamed directly to disk, no buffering; per-file progress tracking
- **Progress polling** endpoint (`/api/progress`) with per-transfer IDs
- **Structured logging** — server logs to rotating file (2 MB cap) + in-memory ring buffer + in-app log viewer; browser client logs to console with `[tag]` format
- **Permissions** — real Android system permission dialog on first launch; explanatory screen with settings button if denied
- **Plain functional UI** — default Material 3, no polish (Phase 2)
- **QR code** for quick connection from client devices
- **Foreground service** to keep server alive in background

## Tech Stack

- Flutter 3.x (Dart)
- shelf + shelf_router
- flutter_foreground_task, qr_flutter, file_picker, path_provider, network_info_plus, permission_handler
- archive (zip), mime, crypto, uuid

## Android Manifest Permissions

- `INTERNET`, `ACCESS_WIFI_STATE`, `ACCESS_NETWORK_STATE`
- `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`
- `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO`
- `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`, `WAKE_LOCK`

## Build & Run

```bash
# Prerequisites: Flutter SDK, Android SDK
flutter pub get
flutter run        # on connected device
```

## GitHub Actions APK

Push to `main` and `build.yml` runs `flutter build apk --debug --target-platform=android-arm64`. The debug APK is uploaded as a workflow artifact.

## Known / Deferred

- HTTPS for Chrome "download insecure" warning (flagged, Phase 2 follow-up)
- Chrome "can't download securely" — currently addressed via `Content-Type` + `Content-Disposition` headers and `Cache-Control`; HTTPS with self-signed cert is a follow-up item if needed
- Phase 2 visual redesign (ZArchiver-style file manager, animated progress, dark mode)
- iOS support (out of scope)
- Multiple simultaneous client sessions (out of scope)

## Project Structure

```
lib/
  main.dart
  ui/           — Flutter screens (permission gate, server, settings, logs)
  server/       — LocalDropServer (shelf-based HTTP)
  services/     — auth, logging, transfer tracking, server controller
  models/       — FileEntry, TransferInfo
assets/web/   — index.html, app.js, style.css
android/      — Android manifest, Gradle config
``` 
