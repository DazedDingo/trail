# Changelog

All notable changes to **Trail** (gps-pinger) are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) with the Android `versionCode+build` suffix.

## [0.1.1+2] — 2026-04-18

### Fixed

- **CI APK build** — bumped `workmanager` from `^0.5.2` to `^0.9.0+3`. The
  0.5.x line referenced the long-removed Flutter v1 plugin embedding
  (`ShimPluginRegistry`, `PluginRegistrantCallback`), which broke compilation
  against Flutter 3.41+. Every release-workflow run since the workflow was
  added had failed at `:workmanager:compileReleaseKotlin`. APK now builds.
- Migrated to the new workmanager API: `ExistingPeriodicWorkPolicy.update`
  (was `ExistingWorkPolicy.replace`), `NetworkType.notRequired` (was the
  snake-case `not_required`), and dropped the deprecated `isInDebugMode`
  parameter.

### Added

- `CHANGELOG.md` (this file).
- `README.md` rewritten to reflect Phase 1 reality (was still labelled
  "design phase, not yet implemented" with the pre-decision 6h cadence).

### Tests

- 118 / 118 green, stable across 3 consecutive runs.

## [0.1.0+1] — 2026-04-16

Initial Phase 1 scaffold.

### Added

- **Encrypted local storage** — SQLite + SQLCipher, passphrase generated
  once on first launch via Android Keystore (`KeystoreKey`). 32 bytes of
  `Random.secure()` entropy, base64url-encoded, stored under
  `trail_db_passphrase_v1`. `android:allowBackup="false"` prevents cross-
  device restore (which would orphan the DB).
- **4h scheduled pings** — WorkManager periodic worker
  (`WorkmanagerScheduler`) with the cadence/retry/skip logic extracted into
  a pure `SchedulerPolicy` for unit-testable thresholds:
  - `< 5%` battery → skip the fix, log a `skipped_low_battery` marker row.
  - `< 20%` battery → next periodic cadence drops from 4h to 8h.
  - No-fix → enqueue a 5-minute one-shot retry (except for the skip marker
    — retrying a skip would just re-skip).
  - All four WorkManager constraint flags (`requiresBatteryNotLow`,
    `requiresCharging`, `requiresDeviceIdle`, `requiresStorageNotLow`)
    pinned to `false` and asserted in tests — Android otherwise silently
    defers the worker exactly when the user most needs the log.
- **Boot-time ping** — native `BootReceiver` enqueues a one-shot worker
  that writes a `device_boot` marker row, then chains into the normal
  scheduled-ping path so reboots don't leave a 4h gap.
- **Biometric gate** — `BiometricService` via `local_auth` with PIN
  fallback. Lock screen is a UI gate; Phase 2 hardens it for panic mode.
- **Onboarding flow** — staged permission requests in the correct order
  (fine location → background location → notifications → ignore battery
  optimizations). Requesting background-location before fine-location
  silently collapses to denied on Android 11+.
- **Exporters** — GPX and CSV exporters with pure `build()` methods so
  output is testable without share_plus. CSV is RFC-4180 quoted; GPX
  injects a deterministic `<time>` for reproducible exports.
- **Emergency contacts** — `ContactDao` + model (Phase 2 panic-share
  consumer).
- **Battery + network telemetry** — every ping captures battery percent,
  network state (wifi > mobile > ethernet > none > unknown priority), cell
  ID, and Wi-Fi SSID via passive reads.
- **History + home screens** — last successful ping, heartbeat indicator,
  recent history list, manual export.
- **Dark theme only** — explicit `ThemeMode.dark`.

### CI

- `.github/workflows/release.yml` — push-to-main → `flutter build apk` →
  attached to a GitHub Release. (Built but did not produce an APK until
  0.1.1+2 fixed the workmanager incompatibility.)

### Tests

- 118 unit tests across 9 files. Highlights:
  - `scheduler_policy_test.dart` — 25 tests for thresholds + WorkManager
    constraint regression guards.
  - `ping_dao_test.dart` — 17 tests against in-memory `sqflite_common_ffi`
    (production uses `sqflite_sqlcipher`, unavailable in unit context).
  - `keystore_key_test.dart` — 15 tests faking the
    `flutter_secure_storage` MethodChannel directly.
  - `location_service_test.dart` — 13 tests covering every error branch
    behind a `GeoClient` abstraction.
  - `csv_exporter_test.dart` / `gpx_exporter_test.dart` — 24 tests for
    serialization edge cases (RFC 4180 quoting, XML escape, no_fix skip,
    optional fields).
