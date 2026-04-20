# Changelog

All notable changes to **Trail** (gps-pinger) are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) with the Android `versionCode+build` suffix.

## [0.1.6+7] — 2026-04-20

### Added

- **Approx location on History tiles.** The history screen already showed
  raw lat/lon; it now also renders the reverse-geocoded "Locality, Region"
  label under the coords (same `approxLocationProvider.family` the Home
  card uses, so repeated pings at the same spot — the common case at 4h
  cadence — are served from cache). Silently omits the line when the
  geocoder has nothing for that coordinate.

## [0.1.5+6] — 2026-04-19

### Fixed

- **Upgrades required an uninstall first.** The release workflow was
  running `echo '${{ secrets.DEBUG_KEYSTORE_B64 }}' | base64 -d > ~/.android/debug.keystore`,
  but that secret was never set on `DazedDingo/gps-pinger` (it exists on
  watchnext, which is the pattern this repo was forked from). An empty
  secret produced an empty file, Flutter regenerated a fresh debug
  keystore on each CI run, and every GitHub release was signed with a
  different cert — so every upgrade hit `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

  Pinned the keystore in-tree at `android/app/debug.keystore`, added an
  explicit `signingConfigs.debug` in `build.gradle.kts` pointing at it,
  and taught CI to verify the APK's SHA-1 matches the expected value
  after build. `.gitignore` gains an `!android/app/debug.keystore`
  negation so the wildcard doesn't silently hide it on future commits.
  (One-time uninstall still needed to get off the last random keystore
  — future upgrades install cleanly.)

### Added

- **Trail visualisation on Home.** A tile-free `CustomPaint` trail view
  that projects recent ping coordinates into the available rect and
  connects them with a path, latest fix highlighted. No internet / no
  map tiles — consistent with Trail's offline-first constraint.
- **Approximate location on the last-ping card.** Reverse geocoded via
  Android's system Geocoder (works partially offline from cached data).
  Renders as `Cambridge, MA` under the raw coordinates; silently omits
  when the geocoder has nothing, so poor-coverage locations don't
  render a misleading placeholder.
- **Diagnostics in Settings.**
  - "Run ping now" button exercises the scheduled handler end-to-end
    from the UI isolate so a stale heartbeat can be debugged as
    "pipeline broken" vs "phone throttling the worker" without adb.
  - Live status pills for battery-optimisation, fine location, and
    background location. Statuses re-read on resume so a grant/revoke
    made in system settings is reflected without reopening the page.
  - App version now shown at the bottom (matches the convention used
    by the other DazedDingo apps).

## [0.1.4+5] — 2026-04-18

### Fixed

- **Home screen dying on first launch with a truncated "database exception".**
  All four home-screen providers (`recentPingsProvider`,
  `lastSuccessfulPingProvider`, `heartbeatHealthyProvider`,
  `pingCountProvider`) plus the export action each opened their own
  `TrailDatabase.open()` in parallel. Four concurrent SQLCipher
  connections on the same DB file raced Keystore-backed passphrase
  derivation and the first-install `onCreate` schema, which surfaced as
  a generic "database exception" with no actionable detail.

  `TrailDatabase.shared()` now memoises a single `Future<Database>` for
  the UI isolate — all providers await the same open. The WorkManager
  background isolate still uses `open()` per-job; it runs in a separate
  Dart VM and cannot share the UI handle.
- **Diagnostic surface for DB errors.** The previous error branch on the
  home screen was a single-line `Text('Failed to load: $e')` that
  truncated the exception and had no copy path — field diagnosis was
  impossible. Replaced with a `SelectableText` card that shows the full
  exception + stack trace with a copy-to-clipboard action.

## [0.1.3+4] — 2026-04-18

### Fixed

- **Biometric unlock totally broken on the v0.1.2 APK.** Two canonical
  `local_auth` setup misses, both shipping in the very first installable
  build:
  - `MainActivity` extended `FlutterActivity` instead of
    `FlutterFragmentActivity`. The biometric prompt is rendered as a
    Fragment and needs a FragmentActivity host — without it,
    `authenticate()` throws and the lock screen reported a generic
    "Authentication failed" with no fingerprint UI ever shown.
  - `AndroidManifest.xml` was missing `USE_BIOMETRIC` (API 28+) and
    `USE_FINGERPRINT` (legacy API 23-27). With those absent,
    `canCheckBiometrics` returns `false`, which is what made the
    onboarding "bio test" button silently fail and offered no scan path.

  Both fixes are required — fixing one without the other still leaves
  bio broken.

## [0.1.2+3] — 2026-04-18

### Fixed

- **Native `BootReceiver` against workmanager 0.9.x.** Bumping the plugin
  in 0.1.1+2 fixed the Dart-side compile but the native `BootReceiver.kt`
  still imported `be.tramckrijte.workmanager.BackgroundWorker`. The
  plugin moved to the Flutter Community org — package is now
  `dev.fluttercommunity.workmanager` and the input-data key changed to
  `dev.fluttercommunity.workmanager.DART_TASK`. Also dropped the now-
  unused `IS_IN_DEBUG_MODE_KEY` (replaced by `WorkmanagerDebug` handlers).
- **Declared `androidx.work:work-runtime-ktx:2.10.2` directly.**
  workmanager_android 0.9.x downgraded its `androidx.work` dep from `api`
  to `implementation`, so it's no longer transitive. `BootReceiver`
  references `WorkManager`, `OneTimeWorkRequestBuilder`, and
  `ExistingWorkPolicy` directly and now declares its own dep.

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
