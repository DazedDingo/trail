# Trail — GPS Logger Codebase Guide

**Trail** is a personal-safety + data-gathering Android app. Pings GPS every 4 hours, logs to encrypted SQLite, renders offline map history, supports on-demand panic pings. Fully offline, no internet dependency.

## Tech Stack

- **Flutter:** Dart ^3.5.0
- **State management:** Riverpod (FutureProvider, StateProvider, ConsumerWidget)
- **Routing:** GoRouter with redirect rule (onboarding gate, lock screen)
- **Storage:** SQLite + SQLCipher (encrypted, Keystore-derived key)
- **Location:** geolocator + LocationAccuracy.high (battery-conscious)
- **Background scheduling:** dual-path as of 0.5.0+14 — **Battery saver** (default: WorkManager 4h periodic, battery-aware) or **Precise** (`AlarmManager.setExactAndAllowWhileIdle` per ping, Doze-bypassing, opt-in). User switches via `Settings → Scheduling → Mode`; only one driver active at a time.
- **Biometric lock:** local_auth (fingerprint/face fallback to PIN)
- **Native permissions:** permission_handler (staged: fine → background location)
- **Battery/network telemetry:** battery_plus, connectivity_plus
- **Export:** GPX + CSV exporters (share_plus)
- **Map viewer:** flutter_map + OpenStreetMap raster tiles when no
  active region is set; `flutter_map_mbtiles` + sideloaded `.mbtiles`
  when the user has installed and activated a region via
  `Settings → Offline map → Regions`. The logging pipeline has been
  fully offline since Phase 1 — as of 0.4.0+13 the viewer is offline
  too whenever a region is active.
- **Android-only** (no iOS variant planned)

## Directory Map: `lib/`

```
lib/
├── main.dart                    # Entry point: WorkManager init, onboarding gate
├── app.dart                     # Router (GoRouter), root ConsumerWidget
├── models/                      # Data classes (Ping, EmergencyContact)
├── db/                          # Database layer
│   ├── database.dart           # TrailDatabase (SQLCipher wrapper, schema v1)
│   ├── ping_dao.dart           # CRUD for pings table
│   ├── contact_dao.dart        # CRUD for emergency_contacts
│   └── keystore_key.dart       # Keystore-backed passphrase
├── providers/                   # Riverpod state
│   ├── pings_provider.dart     # recentPingsProvider, lastSuccessfulPingProvider, heartbeatHealthyProvider, approxLocationProvider
│   ├── onboarding_provider.dart # onboardingCompleteProvider, OnboardingGate (secure storage)
│   ├── backup_provider.dart     # backupEnabledProvider, needsUnlockProvider, computeNeedsUnlock()
│   ├── contacts_provider.dart   # emergencyContactsProvider (FutureProvider, ContactDao)
│   └── panic_provider.dart      # panicDurationProvider (AsyncNotifier, secure-storage-backed)
├── services/                    # Business logic
│   ├── location_service.dart    # Wraps geolocator, enforces 2min timeout, passive cell/Wi-Fi reads
│   ├── permissions_service.dart # Staged permission requests (fine → background location)
│   ├── biometric_service.dart   # BiometricService (local_auth, PIN fallback)
│   ├── battery_network_service.dart # Battery % + network state snapshots
│   ├── cell_wifi_service.dart   # Passive cell tower ID + Wi-Fi SSID capture
│   ├── geo_client.dart          # Geolocator wrapper (testable)
│   ├── geocoding_service.dart   # Reverse geocode wrapper (offline-tolerant)
│   ├── passphrase_service.dart  # PBKDF2 + salt file for the backup-passphrase mode
│   ├── notification_service.dart # flutter_local_notifications wrapper, `trail_panic` channel
│   ├── home_location_service.dart # HomeLocation + shared-prefs CRUD + Haversine distance (Phase 6, shipped 0.6.0+15)
│   ├── panic/
│   │   ├── panic_service.dart          # triggerOnce / startContinuous / stopContinuous / MethodChannel
│   │   └── panic_share_builder.dart    # sms: URI compose + PANIC body format
│   ├── scheduler/
│   │   ├── workmanager_scheduler.dart # WorkManager init, periodic/retry/boot/panic task enqueue (records WorkerRunLog at every outcome since 0.6.0+15)
│   │   ├── scheduler_policy.dart      # Cadence constants, battery/network constraints
│   │   ├── scheduler_mode.dart        # SchedulerMode enum, ExactAlarmBridge MethodChannel wrapper, switchSchedulerMode(). Shipped 0.5.0+14.
│   │   └── worker_run_log.dart        # Rolling last-20 SharedPreferences log of dispatcher outcomes; diagnostics UI reads this. Shipped 0.6.0+15.
│   ├── archive/
│   │   └── archive_service.dart # Export-then-delete flow (keeps DB untouched if any export write throws). Shipped 0.5.0+14.
│   └── export/
│       ├── gpx_exporter.dart    # GPX serialization
│       └── csv_exporter.dart    # CSV serialization
├── screens/                     # Screens (all ConsumerWidget)
│   ├── home_screen.dart         # Panic button + last ping + heartbeat + trail viz + export + recent history
│   ├── history_screen.dart      # Paginated full history list
│   ├── map_screen.dart          # Full-screen map over all pings: time slider, path-line toggle, bbox-fit default viewport. Shipped 0.4.0+13.
│   ├── regions_screen.dart      # Offline MBTiles library: install (.mbtiles picker), delete, set-active. Shipped 0.4.0+13.
│   ├── archive_screen.dart      # Archive older pings: cutoff picker, format radio, preview, export-and-delete confirm. Shipped 0.5.0+14.
│   ├── diagnostics_screen.dart  # Permission matrix, DB integrity-check button, last-20 worker runs, copy-all action. Shipped 0.6.0+15.
│   ├── export_dialog.dart       # Date-range + format picker dialog (replaces home screen's two export buttons). Shipped 0.6.0+15.
│   ├── home_location_screen.dart # Set home lat/lon/label: "use last fix" or manual form. Shipped 0.6.0+15.
│   ├── settings_screen.dart     # Diagnostics (link), scheduling (mode toggle + events log), permissions, cloud-backup setup, panic duration, home location, history (archive), app version
│   ├── contacts_screen.dart     # Emergency contacts CRUD (stored in encrypted DB)
│   ├── lock_screen.dart         # Biometric/PIN unlock gate (pre-home)
│   ├── passphrase_entry_screen.dart # Post-restore backup-passphrase unlock gate
│   └── onboarding/              # First-run flow (permissions, emergency contacts)
│       └── onboarding_flow.dart
├── widgets/
│   └── trail_map.dart           # flutter_map (OSM tiles) + polyline + markers + recenter button
├── theme/
│   └── app_theme.dart           # Dark theme only (ThemeMode.dark explicit)
```

## Key Conventions

### State Management (Riverpod)
- **FutureProvider** for async data (ping queries, location fix, exports).
- **StateProvider** for simple flags (onboarding-complete, settings overrides).
- UI-isolate providers share a single DB handle via `TrailDatabase.shared()` — never `close()` it. Four concurrent `open()` calls on the home screen raced SQLCipher key derivation + first-install `onCreate` in 0.1.3 and surfaced as a generic "database exception" (fixed in 0.1.4).
- Invalidation via `ref.invalidate(providerName)` after writes (manual ping, export).

### Screens & Widgets
- All screens extend **ConsumerWidget** for direct `ref.watch()` of providers.
- Navigation via **GoRouter** — no named routes in `go_router.dart`, only path-based.
- Router's `redirect` rule gates onboarding (hard block) + lock screen (UI gate).

### Permissions (Android 11+ aware)
- **Staged request order** (critical — must request fine *before* background):
  1. Fine location (ACCESS_FINE_LOCATION)
  2. Background location (ACCESS_BACKGROUND_LOCATION)
  3. Notifications (POST_NOTIFICATIONS, Phase 2)
  4. Ignore battery optimizations (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
- Manifest declares all permissions upfront; some granted automatically on < API 33.
- See `PermissionsService.requestFineLocation()` → `requestBackgroundLocation()`.

### GPS Acquisition (Battery-Critical)
- **LocationAccuracy.high** for scheduled pings (never `.best`).
- **2-minute timeout** hardcoded in `LocationService.getScheduledPing()`.
- **No streaming** — `getCurrentPosition()` acquires once, releases GPS client on completion.
- Passive cell/Wi-Fi reads (no active scans) via `CellWifiService`.

### Background Scheduling
- **WorkManager** (Dart + native integration) handles periodic + one-off tasks.
- **Cadence:** 4h periodic ping; 5min retry after no-fix; boot marker on reboot.
- **Callback dispatcher** (`_callbackDispatcher` in `workmanager_scheduler.dart`) runs in isolated Dart VM — no access to UI providers.
- **Isolate model:** background callback opens fresh DB handle, cannot share UI isolate's handle.
- **Constraints:** no battery required, no charging required, device may be idle (no `requiresDeviceIdle: true`).
- See `SchedulerPolicy` for cadence + constraint constants (unit-tested, testable without native plugin).

### Biometric Lock
- **BiometricService** uses `local_auth` with `biometricOnly: false` → falls back to device PIN if no fingerprint/face enrolled.
- Lock screen is **not** a hard gate; users can swipe past (Phase 2 hardens this with panic-mode gating).

### Database Schema (Phase 1, v1)
- **pings table:** timestamp_utc (primary key for queries), lat/lon/accuracy/altitude/heading/speed, battery_pct, network_state, cell_id, wifi_ssid, source (enum: scheduled|panic|boot|no_fix), note.
- **emergency_contacts table:** name, phone_e164 (Phase 2 panic-share).
- **Index:** `idx_pings_ts_utc DESC` for fast recent queries.
- **Encryption:** SQLCipher with a 32-byte key persisted in Keystore-backed secure storage. Two key-source modes:
  - **Keystore mode (default):** 32 bytes of `Random.secure()` entropy generated on first launch, base64url-encoded. Zero user interaction.
  - **Passphrase mode (opt-in via Settings → Enable cloud backup):** key is PBKDF2-SHA256(user passphrase, salt, 210k). Salt is a 16-byte random blob in `trail_salt_v1.bin` alongside the DB; both files are `include`'d in Android's `backup_rules.xml` so Google Drive auto-backup preserves them across uninstall. The derived key is cached in secure storage the same way the random key is, so the background WorkManager isolate never sees the passphrase itself. Setup rekeys the DB in place via `PRAGMA rekey`. Post-restore detection: salt file present + secure storage empty → route to `/unlock`; `KeystoreKey.getOrCreate()` returns `null` rather than silently overwriting.

## Build, Test, Run

### Run (development)
```bash
flutter pub get
flutter run
```

### Test
```bash
flutter test
```
Tests live in `test/`; use `sqflite_common_ffi` for in-memory SQLite DAO tests (no SQLCipher at test time).

### Build APK (release)
```bash
flutter build apk --release
```
GitHub Actions workflow (`.github/workflows/release.yml`) pushes APK to GitHub Releases on push-to-main.

### Signing (pinned debug keystore)

Both local and CI builds sign with the committed `android/app/debug.keystore`
(password `android`, alias `androiddebugkey`, SHA-1 pinned to `EXPECTED_SHA1`
in the release workflow). Do NOT delete the keystore or regenerate it —
every release must share the same cert or users hit
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`. The `.gitignore` wildcard
`*.keystore` is explicitly overridden with `!android/app/debug.keystore`
so the pin survives commits; if that negation ever drops, CI restores
would revert to random-keystore-per-build (the v0.1.5 fix was exactly
that).

### Key Android manifest entries
- **Boot receiver:** enqueues WorkManager task + logs `boot` row on reboot.
- **Permissions declared:** fine/coarse/background location, boot completed, exact alarms, notifications, ignore battery optimizations, nearby Wi-Fi, read phone state, foreground service (Phase 2 only).
- **No backup:** `android:allowBackup="false"` (encrypted DB not intended to sync across devices).

## Commit Conventions

Commits follow conventional pattern:
- **`feat(phase-1):`** new feature
- **`fix(scheduler):`** bug fix with component prefix
- **`test:`** test coverage additions
- **`docs:`** design decisions, PLAN updates
- **`ci:`** GitHub Actions, build config

Example: `feat(scheduler): extract SchedulerPolicy for testable cadence logic`

See `git log --oneline -20` for recent pattern.

## Known Constraints & Gotchas

1. **WorkManager isolate isolation:** background callback runs in separate Dart VM; cannot share DB handles or plugin state with UI isolate. Always open fresh handle in callback.
2. **Permission staging order (Android 11+):** requesting background-location before fine-location silently collapses to denied. Always request fine first.
3. **SQLCipher + tests:** sqflite_sqlcipher does not work in unit test context (platform channel unavailable). Use sqflite_common_ffi for test database. Production uses sqflite_sqlcipher.
4. **Dark mode only:** no light theme variant. All Color tokens assume `ThemeMode.dark` explicitly.
5. **Phase scope as of 0.6.0+15:** Phases 1–6 shipped. Panic (Phase 2, shipped 0.2.0+11), quick-settings tile + home widget (Phase 3, shipped 0.3.0+12), offline MBTiles + full map screen (Phase 4, shipped 0.4.0+13), exact alarms + archive flow (Phase 5, shipped 0.5.0+14), polish (Phase 6, shipped 0.6.0+15: diagnostics screen, DB integrity, date-range export, heatmap, home location, worker run log — adaptive icon was already in place), and notifications (`trail_panic` channel) are live. All planned phases complete; further work is maintenance/integration testing. Manifest declared all permissions upfront so validation passes early.
6. **`PassphraseNeededException`:** `TrailDatabase.open()` throws this in passphrase-mode-post-restore installs. The UI startup gate (`computeNeedsUnlock` → `needsUnlockProvider`) detects this at `main()` and routes to `/unlock`. Background workers catch and skip silently — they can't write a marker row when the DB is the thing they can't open. Don't handle this exception ad-hoc in new providers; catch at the screen boundary (or rely on the router gate).
7. **Don't disable `allowBackup` or remove `backup_rules.xml`.** Passphrase-mode users rely on auto-backup for uninstall survivability. If you ever add a new on-disk file that must NOT be backed up, add an `<exclude>` to `backup_rules.xml` + `data_extraction_rules.xml`. MBTiles regions under `<appDocumentsDir>/mbtiles/` are already `<exclude>`d — sideloaded raster packs run 200–600 MB per region and would blow Android's 25 MB per-app Google Drive quota.
8. **MBTiles tests and the `libsqlite3.so` loader.** `flutter_map_mbtiles` pins `sqflite_common_ffi 2.3.7+1`, which unconditionally calls `DynamicLibrary.open('libsqlite3.so')`. The unversioned symlink is only in `libsqlite3-dev`, missing on CI and fresh arm64 dev images. `test/ping_dao_test.dart` works around this with an `ffiInit` callback passed to `createDatabaseFactoryFfi` — the callback must be a **top-level function** because it's serialized across `Isolate.spawn`, and it registers `open.overrideFor(OperatingSystem.linux, ...)` *inside* the background isolate (the main-isolate override registry doesn't propagate). If you add a new SQLite-backed test, reuse that pattern (see also `test/archive_service_test.dart` which copies it verbatim).
9. **Exact-alarm receiver chain self-reschedules.** Unlike WorkManager's `PeriodicWorkRequest`, `setExactAndAllowWhileIdle` fires once and stops. `ExactAlarmReceiver` re-arms the next alarm (+4h) on every delivery *before* enqueuing the one-off `BackgroundWorker` to do the actual ping. If you ever modify that receiver, keep the reschedule call — dropping it silently breaks the whole cadence after one fire. `BootReceiver` checks `SchedulerPrefs.isExactMode(context)` and calls `ExactAlarmScheduler.scheduleNext(context)` on reboot / APK upgrade, so the chain survives cold reboots without the Flutter UI ever running.
10. **Archive = export-then-delete, never parallel.** `ArchiveService.archive` writes every requested export format to the temp dir first, and only after every `writeAsString` returns does it call `dao.deleteOlderThan(cutoff)`. SQLite transactions can't enlist external files; this sequential ordering is the only safety net. If you add a new export format, extend the "write first" block, not the "delete after" block — a throw between the two is the safe failure mode (user keeps all data, loses only a temp file).
11. **`WorkerRunLog` is cross-isolate SharedPreferences.** The WorkManager dispatcher isolate (where `_callbackDispatcher` runs) has no access to UI providers, but it can and does write `trail_worker_runs_v1` via `SharedPreferences.getInstance()`. The diagnostics screen (UI isolate) reads the same key. SharedPreferences acquires an in-process lock per access so concurrent writes from both isolates are safe; neither side caches. If you add a new outcome to the dispatcher, add a matching `WorkerRunLog.record(...)` call at the terminal branch — the log is the user's only post-hoc evidence of what the worker actually did. `maxEntries = 20`; the read path tolerates malformed JSON by returning `[]` rather than throwing (garbage-in-prefs shouldn't blank the diagnostics screen).
12. **Heatmap grid uses local-plane bucketing, not great-circle.** `_buildHeatmapMarkers` in `map_screen.dart` quantises each ping to a 0.001° grid (`(lat/gridSize).round()` × gridSize) — that's ~100 m at the equator and ~60 m at 50°N. Cells are *not* equal-area; they get narrower toward the poles. The user is in the UK so this is fine in practice, but if the app ever expands to high-latitude use, switch to a proper hex grid or degree-scaled lon buckets rather than hoping the visual distortion stays imperceptible.
13. **Export filter is exported.** `filterPingsByRange(rows, range)` in `export_dialog.dart` is a top-level pure function precisely so `export_dialog_filter_test.dart` can hit it without spinning up a widget tree. The `_run()` state method just calls it. If you add a new filter axis (e.g. source=scheduled-only), add a parameter to the pure function, don't reintroduce a private state method — the test would then need a `WidgetTester` harness instead of a plain unit test.
14. **Home location is shared-prefs, deliberately.** `HomeLocationService` stores lat/lon/label/savedAt in plain `SharedPreferences` (keys prefixed `trail_home_*_v1`), *not* the encrypted DB. Rationale: (a) it's not sensitive in the way panic contacts are (a single coord the user typed in themselves), (b) keeping it outside SQLCipher means the home-distance header on the home screen renders instantly without waiting on key derivation, (c) the absence/presence of the keys alone is the "home is set" signal — no DB migration needed. If home location ever grows to include sensitive metadata (doctors, safe-house addresses), move it to the DB and deprecate the prefs keys — don't layer sensitivity onto shared prefs.

## Related Docs

- **`docs/PLAN.md`:** full design, battery budget, phase breakdown, open questions, confirmed decisions (19 total).
- **`README.md`:** project summary, planned stack.
