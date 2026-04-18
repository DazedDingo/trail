# Trail (gps-pinger)

Personal-safety + curious-data-gathering Android app. Pings GPS every 4 hours, logs locally to an encrypted SQLite DB, supports on-demand panic ping, exports GPX/CSV. Fully offline — no internet dependency at runtime.

**Status:** Phase 1 scaffolded — encrypted DB, 4h WorkManager cadence, biometric gate, exporters, onboarding. 118 unit tests green.

See [`docs/PLAN.md`](docs/PLAN.md) for the phased plan and [`CHANGELOG.md`](CHANGELOG.md) for what shipped.

## Stack

- Flutter (Dart ^3.5), Android-only
- Riverpod + go_router
- SQLite + SQLCipher (Keystore-derived passphrase) — see `lib/db/keystore_key.dart`
- WorkManager 0.9.x for the 4h periodic cadence + boot/retry one-shots
- `geolocator` wrapped behind a testable `GeoClient` seam
- `local_auth` biometric gate (PIN fallback)
- `share_plus` + GPX/CSV exporters

## Hard rules (from `docs/PLAN.md`)

- **No persistent foreground service** for scheduled pings — WorkManager only.
- **Battery policy:** `<20%` → drop to 8h cadence; `<5%` → skip the fix and log a marker row (never a silent gap).
- **Always log a row per attempt.** No-fix rows are first-class so the gap is visible in history.
- **WorkManager constraints all stay false** (battery-not-low, charging, idle, storage-not-low, network) — the app exists for the long-hike-with-draining-battery case.
- **No backup** (`android:allowBackup="false"`) — encrypted DB is device-bound by design.

These invariants are guarded by tests in `test/scheduler_policy_test.dart`.

## Build & run

```bash
flutter pub get
flutter run                    # dev build on connected device
flutter test                   # 118 unit tests
flutter build apk --release    # signed release APK
```

Push to `main` triggers `.github/workflows/release.yml` → APK uploaded to GitHub Releases.

## Repo layout

See [`CLAUDE.md`](CLAUDE.md) for the full directory map and conventions.
