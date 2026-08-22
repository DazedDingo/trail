# Trail — GPS Logger Codebase Guide

**Trail** is a personal-safety + data-gathering Android app. Pings GPS on a user-selectable cadence (30 min / 1 h / 2 h / 4 h — default 4 h, shipped 0.7.0+23), logs to encrypted SQLite, renders offline map history, supports on-demand panic pings. Fully offline, no internet dependency.

## Tech Stack

- **Flutter:** Dart ^3.5.0
- **State management:** Riverpod (FutureProvider, StateProvider, ConsumerWidget)
- **Routing:** GoRouter with redirect rule (onboarding gate, lock screen)
- **Storage:** SQLite + SQLCipher (encrypted, Keystore-derived key)
- **Location:** geolocator + LocationAccuracy.high (battery-conscious)
- **Background scheduling:** dual-path as of 0.5.0+14 — **Battery saver** (default: WorkManager periodic at the user-chosen cadence, battery-aware) or **Precise** (`AlarmManager.setExactAndAllowWhileIdle` per ping, Doze-bypassing, opt-in). User switches via `Settings → Scheduling → Mode`; cadence is a separate picker at `Settings → Scheduling → Cadence` (default 4h, 0.7.0+23); only one driver active at a time.
- **Biometric lock:** local_auth (fingerprint/face fallback to PIN)
- **Native permissions:** permission_handler (staged: fine → background location)
- **Battery/network telemetry:** battery_plus, connectivity_plus
- **Export:** GPX + CSV exporters (share_plus)
- **Map viewer:** `maplibre_gl` 0.26.0 (vector renderer, the older
  battle-tested community plugin) + sideloaded `.mbtiles` or
  `.pmtiles` regions activated via `Settings → Offline map →
  Regions`. When no region is active the viewer renders an "install a
  region" empty state — there is no online tile fallback (the app is
  offline-only). The logging pipeline has been offline since Phase 1;
  the viewer is offline whenever a region is active. Migration:
  raster (`flutter_map` + `flutter_map_mbtiles`) → vector via
  `maplibre` (0.8.0+29 through +37, broke on Android local files) →
  `maplibre_gl` (0.8.0+38, currently shipping).
- **Android-only** (no iOS variant planned)

## Directory Map: `lib/`

```
lib/
├── main.dart                    # Entry point. Awaits ONLY the two router gates (onboarding + needs-unlock) in parallel; WorkManager / notification-channel / photo-denylist init run post-first-frame (0.14.1)
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
│   ├── secure_storage.dart      # The one shared `secureStorage` FlutterSecureStorage instance (0.14.1) — use it, don't construct new ones
│   ├── photo_uri.dart           # `localPathForUri` / `isLocalFileUri` — the single 'is this a local file' helper for photo URIs (0.14.1)
│   ├── memory_pressure.dart     # Cache caps (image 120 MB / 1 000, tile 16 MB) + `didHaveMemoryPressure` observer (0.14.1)
│   ├── lru_cache.dart           # Small generic LRU used by GeocodingService (0.14.1)
│   ├── bounded_map.dart         # Bounded insertion-ordered map helper (0.14.1)
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
│   ├── export/
│       ├── gpx_exporter.dart    # GPX serialization
│       └── csv_exporter.dart    # CSV serialization
│   └── map/
│       └── pin_geojson.dart     # Pure helpers for the map panel (0.14.0): PinSnapshot/PinColumns, buildPinsGeoJson/buildSegmentsGeoJson (run in Isolate.run), tsFilter, visibleCount/stepIndex (binary search), effectiveSliderMax, buildPinStyle, tap hit-test id parsing. Unit-tested in test/pin_geojson_test.dart
├── screens/                     # Screens (all ConsumerWidget)
│   ├── home_screen.dart         # Pinned top block (last ping + heartbeat + hold-to-panic + summary + export + map preview) with a scrollable Recent-pings list at the bottom. Recent tiles show reverse-geocoded labels. Layout shipped 0.7.1+24.
│   ├── history_screen.dart      # Paginated full history list
│   ├── map_screen.dart          # Full-screen map over all pings: time slider with playback (play/pause/step/1×-16×), path-line toggle, bbox-fit default viewport. Playback shipped 0.7.1+24; base shipped 0.4.0+13.
│   ├── regions_screen.dart      # Offline tiles library: install (.pmtiles picker), delete, set-active. PMTiles since 0.8.0+29.
│   ├── archive_screen.dart      # Archive older pings: cutoff picker, format radio, preview, export-and-delete confirm. Shipped 0.5.0+14.
│   ├── diagnostics_screen.dart  # Permission matrix, DB integrity-check button, last-20 worker runs, copy-all action. Shipped 0.6.0+15.
│   ├── export_dialog.dart       # Date-range + format picker dialog (replaces home screen's two export buttons). Shipped 0.6.0+15.
│   ├── home_location_screen.dart # Set home lat/lon/label: "use last fix" or manual form. Shipped 0.6.0+15.
│   ├── stats_screen.dart        # Calendar heatmap + top places + time-of-day clock + detected trips. All four computations are pure functions in services/stats/stats_service.dart. Shipped 0.10.0+64.
│   ├── settings_screen.dart     # Diagnostics (link), scheduling (mode toggle + events log), permissions, cloud-backup setup, panic duration, home location, history (archive), insights (stats), app version
│   ├── contacts_screen.dart     # Emergency contacts CRUD (stored in encrypted DB)
│   ├── lock_screen.dart         # Biometric/PIN unlock gate (pre-home)
│   ├── passphrase_entry_screen.dart # Post-restore backup-passphrase unlock gate
│   └── onboarding/              # First-run flow (permissions, emergency contacts)
│       └── onboarding_flow.dart
├── widgets/
│   ├── full_map_panel.dart      # The map: MapLibreMap host + date filter + time slider/playback + HUD + pin detail sheet. Pins/path/heatmap are native style layers fed from GeoJSON sources (0.14.0) — see gotcha 22
│   ├── inline_date_filter_panel.dart # Preset chips + custom range picker used by the map panel
│   └── stats/
│       ├── calendar_heatmap.dart # 12-week × 7-day GitHub-style cell grid, taps emit (day, count) up to the screen
│       └── clock_chart.dart     # 24-bar radial via CustomPainter
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
- **Cadence:** user-configurable periodic ping (30 min / 1 h / 2 h / 4 h, default 4h — see `PingCadence` in `scheduler_policy.dart` and `CadenceStore` in `scheduler_mode.dart`); 5 min retry after no-fix; boot marker on reboot.
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
- **Indexes:** `idx_pings_ts_utc DESC` for recent queries; `idx_pings_ts_fix ON pings(ts_utc, lat, lon) WHERE lat IS NOT NULL AND lon IS NOT NULL` (schema v4, 0.14.1) — partial + covering, serves every map read and `latestSuccessful`. See gotcha 28.
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
7. **Don't disable `allowBackup` or remove `backup_rules.xml`.** Passphrase-mode users rely on auto-backup for uninstall survivability. If you ever add a new on-disk file that must NOT be backed up, add an `<exclude>` to `backup_rules.xml` + `data_extraction_rules.xml`. PMTiles regions under `<appDocumentsDir>/tiles/` are already `<exclude>`d — sideloaded vector packs run 50 MB (region) to ~700 MB (UK z13) and would blow Android's 25 MB per-app Google Drive quota.
8. **`libsqlite3.so` loader workaround stays for `ping_dao_test.dart`.** Even after the 0.8.0+29 PMTiles cutover (which removed the `flutter_map_mbtiles` dep that previously pulled in this requirement), the encrypted-DB DAO tests still hit `sqflite_common_ffi`, which unconditionally calls `DynamicLibrary.open('libsqlite3.so')`. The unversioned symlink is only in `libsqlite3-dev`, missing on CI and fresh arm64 dev images. `test/ping_dao_test.dart` and `test/archive_service_test.dart` register an `open.overrideFor(OperatingSystem.linux, ...)` callback via a **top-level function** (it's serialized across `Isolate.spawn`); the override must be installed *inside* the background isolate. If you add a new SQLite-backed test, reuse that pattern.
9. **Exact-alarm receiver chain self-reschedules.** Unlike WorkManager's `PeriodicWorkRequest`, `setExactAndAllowWhileIdle` fires once and stops. `ExactAlarmReceiver` re-arms the next alarm at the user-chosen cadence (from `SchedulerPrefs.getCadenceMinutes`, mirrored by the UI via `ExactAlarmBridge.recordCadenceChanged` — 0.7.0+23) on every delivery *before* enqueuing the one-off `BackgroundWorker` to do the actual ping. If you ever modify that receiver, keep the reschedule call — dropping it silently breaks the whole cadence after one fire. `BootReceiver` checks `SchedulerPrefs.isExactMode(context)` and calls `ExactAlarmScheduler.scheduleNext(context)` on reboot / APK upgrade, so the chain survives cold reboots without the Flutter UI ever running — and uses the persisted cadence directly, no Flutter round-trip needed.
10. **Archive = export-then-delete, never parallel.** `ArchiveService.archive` writes every requested export format to the temp dir first, and only after every `writeAsString` returns does it call `dao.deleteOlderThan(cutoff)`. SQLite transactions can't enlist external files; this sequential ordering is the only safety net. If you add a new export format, extend the "write first" block, not the "delete after" block — a throw between the two is the safe failure mode (user keeps all data, loses only a temp file).
11. **`WorkerRunLog` is cross-isolate SharedPreferences.** The WorkManager dispatcher isolate (where `_callbackDispatcher` runs) has no access to UI providers, but it can and does write `trail_worker_runs_v1` via `SharedPreferences.getInstance()`. The diagnostics screen (UI isolate) reads the same key. SharedPreferences acquires an in-process lock per access so concurrent writes from both isolates are safe; neither side caches. If you add a new outcome to the dispatcher, add a matching `WorkerRunLog.record(...)` call at the terminal branch — the log is the user's only post-hoc evidence of what the worker actually did. `maxEntries = 20`; the read path tolerates malformed JSON by returning `[]` rather than throwing (garbage-in-prefs shouldn't blank the diagnostics screen).
12. **Heatmap is a native `HeatmapLayer` over the shared pins source.** Since 0.14.0 there is ONE GeoJSON source for fixes (`trail-pins-src`); the heatmap layer (`trail-heatmap-lyr`, `addHeatmapLayer`) reads it with its own copy of the time filter (`addHeatmapLayer` has no `filter` parameter in maplibre_gl 0.26.0, so it's applied by a follow-up `setFilter`). Heatmap mode hides the pin + path layers with `setLayerVisibility` and restores them on toggle-off. No Dart-side bucketing; it scales to 50k+ fixes natively. History: pre-0.8.0+29 a 0.001° grid of `CircleMarker`s; 0.8.0+29–0.13.x a separate `trail-heatmap-src` rebuilt as a Dart Map per refresh (gone).
13. **Export filter is exported.** `filterPingsByRange(rows, range)` in `export_dialog.dart` is a top-level pure function precisely so `export_dialog_filter_test.dart` can hit it without spinning up a widget tree. The `_run()` state method just calls it. If you add a new filter axis (e.g. source=scheduled-only), add a parameter to the pure function, don't reintroduce a private state method — the test would then need a `WidgetTester` harness instead of a plain unit test. Since 0.14.1 the dialog also clips at SQL (`byDateRange(start, endExclusive − 1 ms)` via the pure `exportRangeUtcBounds(range)`), and `_run()` still passes the rows through `filterPingsByRange` as the gate; an integration test pins SQL ≡ pure at every boundary. Don't unify `exportRangeUtcBounds` with the map's `mapRangeUtcBounds` — they are deliberately different rules.
14. **Home location is shared-prefs, deliberately.** `HomeLocationService` stores lat/lon/label/savedAt in plain `SharedPreferences` (keys prefixed `trail_home_*_v1`), *not* the encrypted DB. Rationale: (a) it's not sensitive in the way panic contacts are (a single coord the user typed in themselves), (b) keeping it outside SQLCipher means the home-distance header on the home screen renders instantly without waiting on key derivation, (c) the absence/presence of the keys alone is the "home is set" signal — no DB migration needed. If home location ever grows to include sensitive metadata (doctors, safe-house addresses), move it to the DB and deprecate the prefs keys — don't layer sensitivity onto shared prefs.
15. **Panic auto-send has two guards, layered.** Since 0.6.1+16 the panic button is **hold-to-trigger** (600 ms long-press with a visible fill) AND — if `panicAutoSendProvider` is on — fires the SMS only after a 5-second on-screen undo SnackBar elapses. Removing either guard is how accidental alerts get sent; both were added for the same reason. If you add a new panic ignition path (e.g. a new tile type), decide deliberately whether it needs the undo grace: background-triggered paths (tile, widget, boot-retry) already reflect explicit user intent, but any new *on-screen* panic entry should go through `_shareWithUndoGrace` in `home_screen.dart`. The compose-intent path (`openPanicSms`) is always the graceful degradation when `autoSendSms` returns 0 (permission denied, no plugin, native throw).
16. **`SEND_SMS` is declared, requested at toggle-on, never mid-panic, and reconciled on every app start.** The manifest ships the permission so `_AutoSendToggleTile` in `settings_screen.dart` *can* request it at runtime, but the prompt only fires when the user flips the toggle on — and only commits the toggle when the grant succeeds. Users who never opt in never see the dialog. `PanicService.autoSendSms` uses `Permission.sms.status` (check-only, no prompt) at panic-fire time, so if the user has system-revoked the grant between toggle and panic, the code falls back to `openPanicSms` rather than popping a dangerous-permission dialog in the middle of an emergency. `PanicAutoSendNotifier.build()` adds a third layer: it reconciles the persisted flag against `Permission.sms.status` on every app start, writing `false` if the toggle is stuck on `true` with no live grant — covers the 0.6.1+16 upgrade case (toggle persisted before toggle-time prompt existed) and the revoke-via-system-settings case. Historical note (fixed in 0.6.2+17): the request used to fire inside `autoSendSms` itself and returned denied-silently. Do not move the request earlier (e.g. into onboarding) — it scares users who don't need it and triggers Play Store restricted-perm review pipelines if the app ever leaves sideload distribution.
17. **Style placeholder rewrite (`pmtiles://__TRAIL_ACTIVE_REGION__`).** The bundled `assets/maptiles/style.json` ships with that literal string in the `openmaptiles` source URL because the active region's absolute file path isn't known at build time. `TrailStyle.loadForRegion(activeRegionPath)` reads the asset, substitutes the real path, and returns the rewritten JSON for `MapOptions.initStyle`. The PMTiles URL scheme is `pmtiles://<absolute-fs-path>` — the conventional triple slash arises naturally because Android documents-dir paths already begin with `/`. If you ever change the placeholder string, change both the bundled asset *and* the constant in `trail_style.dart`. Don't try to register the active region with `controller.style.addSource()` after `onStyleLoaded` — the bundled style references the source by id, so the substitution has to happen *before* MapLibre parses the JSON.
18. **Map widget tests don't mount `MapLibreMap`.** `flutter_test` has no native platform views; instantiating `MapLibreMap` in a widget test throws because the platform instance isn't registered. The actual map render is `maplibre_gl`'s responsibility upstream. Every piece of map logic worth testing lives in top-level pure functions — `lib/services/map/pin_geojson.dart` (GeoJSON text, filters, binary-search slider maths, pin style expressions, tap-result parsing; `test/pin_geojson_test.dart`) and `filterPingsByRange` outside `export_dialog.dart` — so it can be unit-tested without a map instance. Keep doing that; don't try to mount the panel in a widget test. (`TrailMap` + `trail_map_test.dart` were deleted in 0.14.0 — the widget had been dead since Home adopted `FullMapPanel` in 0.10.13.)
19. **Camera fits go in `onStyleLoaded`, not `onMapCreated`.** Both fire, but `onMapCreated` runs before vector tiles have parsed; calling `controller.fitBounds` there produces a visible flicker as the camera snaps into place after the empty canvas appears. Keep `_initialFitDone` flag scoped per active-region change so swapping regions re-fits, but don't fit on every `setState` — the time-slider logic depends on the user being able to pan freely without the camera snapping back to the bbox.

20. **Schema v2 (0.12.0) is additive — `pings.comment` + new `ping_photos` table.** Migration runs in a single transaction; `comment` is the "How is it?" reply-attach target (system-generated text stays in `note`), and `ping_photos` is the many-photos-per-pin join table with a `source` enum (`wikimedia` / `user_camera` / `user_gallery`), attribution, license, thumb_uri, and ordinal columns. Three in-memory test schemas (`ping_dao_test.dart`, `archive_service_test.dart`, `integration_test.dart`) mirror `TrailDatabase._onCreate` and were updated in lock-step — same gotcha as previous migrations, keep them aligned or DAO tests fail with `no such column`. Foreign-key cascade is declared but SQLCipher ships with FKs OFF by default; `PingPhotoDao.deleteForPing` is the explicit cleanup the archive path needs.

21. **Online photo lookup leaks lat/lon to Wikimedia Commons.** Default ON per product brief; the Settings tile in `Home → Auto-fetch photos from Wikimedia` carries a one-line privacy explainer in its subtitle (mandatory — don't strip it). `OnlinePhotoService` is keyless, free, and uses the two-hop `list=geosearch` → `prop=imageinfo` API; up to 5 photos per ping with CC-BY-SA attribution + license persisted. The WorkManager dispatcher fires `_autoFetchPhotos` after every real-fix scheduled ping (gated on `AutoPhotoService.isEnabled` + non-null lat/lon + `source != noFix`) and writes results via `PingPhotoDao.insertAll`. Idempotent: re-running on a ping that already has wikimedia rows is a no-op (`onlineCountForPing > 0` short-circuit). Failures are silent — photos are decorative; the ping write is what matters.

22. **Pins are native style layers; never null `_controller` for a data or range change.** (0.14.0 replaced the annotation API — `addCircle` per pin was Θ(N²) in maplibre_gl 0.26.0 because `AnnotationManager._setAll` re-serialises every annotation on each add; see `docs/PERF_PLAN.md` §1.) The model now:
    - `onStyleLoadedCallback` installs two GeoJSON sources (`trail-pins-src` points, `trail-segs-src` 2-point LineStrings) + `trail-pins-lyr` (circle) and `trail-path-lyr` (line). Sources/layers are created ONLY there (gotcha 19 / maplibre_gl 0.27 rule).
    - Data goes up once per provider list identity: `buildPinSnapshot` → typed `PinColumns` → `Isolate.run(buildPinsGeoJson/buildSegmentsGeoJson)` (inline below 256 fixes) → `editGeoJsonSource(id, String)` — the only 0.26.0 upload that takes a pre-serialised string. `_uploadGen` is bumped by `_invalidateUpload()`; every await re-checks it, so a superseded upload drops itself.
    - The time window is an ORDINAL filter, never a timestamp one: each feature carries `i` (0..N-1, chronological; segments carry the later endpoint's `i`) and a tick does `setFilter(layer, ['<=', ['get','i'], n-1])` with `n = visibleCount(tsMs, cursorMs)`, plus one `setLayerProperties` whose head/prev emphasis and age ramp are also keyed on `i`. **Why not `['get','ts']`:** maplibre-android's `Expression.Converter.convertToValue` narrows EVERY numeric literal to float32 (`getAsFloat()`, Expression.java ~4893) — an epoch-ms literal is off by up to ±65 s, which hid the head pin on half of all slider positions in the first cut. Ordinals are exact to 2^24; `test/pin_geojson_test.dart` asserts every emitted literal is float32-exact. Constant cost regardless of pin count. Never re-upload for a window change.
    - Taps: `onMapClick` → `queryRenderedFeaturesInRect` (24 dp pad × devicePixelRatio) → `pickNearestPinId` → id→Ping map → slider jump + sheet. Layers are `enableInteraction: false` on purpose — an interactive layer's direct hit fires `feature#onTap` and SUPPRESSES `onMapClick`, which would defeat the fat-finger box.
    - The map stays mounted across range changes (`_MapHost` keyed on region+port only; loading/empty states are overlays; `dragEnabled: false` so GeoJSON source updates are async on Android). `_forgetController()` runs only when the platform view actually dies (`_MapHost` epoch / slideshow unmount / region swap). A range or data change calls `_invalidateUpload()` and clears the sources in place. Re-introducing `_controller = null` on a filter change brings back the "cached range never renders" bug.

23. **Sub-1× playback speeds clamp the timer interval at 4 s ceiling.** `playbackInterval(baseStep, speed)` caps the result at `[33ms, 4000ms] (floor raised from 16 ms in 0.14.0 — a tick is now one `setFilter`; nothing faster than ~30 Hz was visible)` — the floor matches one display frame (faster speeds don't queue overlapping callbacks); the ceiling lets 0.25× on a 350ms base step render at 1400ms without bound-clipping. The `speed=0` defensive branch collapses to 1× rather than infinite-loop. `kPlaybackSpeeds = [0.25, 0.5, 1, 2, 4, 8, 16]` is the canonical cycle; `nextPlaybackSpeed` wraps past 16× to 0.25×. `formatPlaybackSpeedLabel` has an explicit aliasing guard for 0.25× — `toStringAsFixed(1)` would render as `0.3×`, indistinguishable from a hypothetical 0.3× entry.

24. **"How is it?" reply handler runs in the background isolate.** The notification's `AndroidNotificationAction` with an `AndroidNotificationActionInput` surfaces an inline text-reply UI; the response routes to the top-level `backgroundQuickCommentResponseHandler` (`@pragma('vm:entry-point')`) which can't share state with the UI isolate. Payload encodes `ping_id:<rowid>` so the handler doesn't re-query for "latest" (which could drift past a panic ping landing between prompt + reply). One notification slot id (43001) — fresh prompts replace the previous one in the tray, so a 4 h-old prompt can't accidentally attach the user's reply to the wrong ping. `sanitizeQuickComment` is the pure entry — blank/whitespace returns null (no DB write), inline newlines collapse to one space, 280-char cap with ellipsis.

25. **Trips are detected purely from `allPingsProvider` ∩ `homeLocationProvider`.** `StatsService.detectTrips` already existed for the stats heatmap (≥6 h continuous away ≥10 km). `tripsProvider` is a thin Provider that joins both inputs and re-runs on every change; cheap at household scale (1 year × 4 h cadence ≈ 2 200 pings, sub-ms). The new `/trips` route surfaces them as a Timeline. If the cost ever shows up in profiling, swap to a memo keyed on ping-count + home identity. `formatTripDateRange` + `formatTripSubtitle` are pure formatters exposed for unit tests; same-month trips collapse to "12–15 May 2026" via `DateFormat.yMMMM`, cross-month uses full `yMMMd` on both ends.

26. **Schema v3 (0.13.3) is additive — new `area_photos` per-cell cache.** Wikimedia lookups are quantized by lat/lon to 3 decimals (~110 m cells) and the cell pool persists in `area_photos`. The dispatcher + `PhotoBackfillService` both check the cache first; only fresh cells hit Wikimedia. Each ping inside a cell gets a deterministic-but-rotated slice via `pickRotatedPhotos(allCellPhotos, pingId, k, salt)` (pure helper in `lib/services/cell_photo_picker.dart`). `PhotoShufflePrefs.bumpSalt()` is the user-controlled "Re-shuffle" path — drops every wikimedia `ping_photos` row and re-runs the regular backfill, which is now all cache hits and finishes in seconds. `ping_dao_test.dart`'s in-memory schema mirrors the new table; the other two test schemas (`archive_service_test`, `integration_test`) don't touch photos, so left alone. **Determinism**: the picker uses a pure 32-bit `_mix32` mixer instead of `Random(seed)` because the language spec doesn't pin `Random()`'s sequence — a future Dart VM upgrade could otherwise silently shuffle every user's photos.

27. **`FailedPhotoUris` denylist + slideshow prefetch (0.13.4).** The 0.13.2 extension whitelist drops *non*-image File: media at the parser, but `.jpg` URLs can still 404, get hotlink-blocked, or be corrupt at render time. `lib/services/failed_photo_uris.dart` is a SharedPreferences-backed persistent set of "this image already failed" URLs. Preloaded post-first-frame (0.14.1; `preload()` is memoised and `register`/`clearAll` await it) so `isFailed` stays sync (image error callbacks can't await) and reads false until the load lands. `file://` entries are SESSION-ONLY — never persisted, and any persisted ones are purged once at preload (the 0.13.x `Image.asset` bug had denylisted every user photo). Both the gallery (`_PhotoTile`) and slideshow `_buildImage` register failures in their `errorWidget`, and `pickPhotoForPing` now walks the full `Map<int, List<PingPhoto>>` (not just first photo per ping) and skips any URL in the denylist — picture-mode advances to a sibling photo or the previous ping's photo rather than showing the broken-image icon. The slideshow also prefetches the next ~5 frames via `precacheImage(CachedNetworkImageProvider(url), context)` so playback at 0.25× doesn't stutter on cellular. Capacity-capped at 2 000 entries (LinkedHashSet insertion-order eviction). User can clear via Settings → Retry broken photos.

28. **Schema v4 (0.14.1) is index-only.** `idx_pings_ts_fix ON pings(ts_utc, lat, lon) WHERE lat IS NOT NULL AND lon IS NOT NULL` — partial + covering. SQLite proves partial-index implication *syntactically*, so `PingDao.fixPredicate` and the index's WHERE text must stay byte-identical (a test pins it). The v3→v4 step runs in a transaction and is followed by `ANALYZE` — the only ANALYZE the app ever runs (not in `_onCreate`: stats on an empty table would mislead the planner forever). Mirrored in the three in-memory schemas (gotcha 20), but prefer `TrailDatabase.createSchemaForTest` / `upgradeSchemaForTest(from:)` / `useSharedForTest(db)` for new tests — they run the production DDL and providers on an ffi DB instead of adding a fourth mirror. Planner facts pinned by `database_migration_test.dart`: the fixes range read, the unbounded fixes read and `latestSuccessful` use `idx_pings_ts_fix`; `recent()` stays on `idx_pings_ts_utc`.

29. **Two ping providers, two different queries — not a duplicate.** `pingsByRangeProvider` is `FutureProvider.autoDispose.family`, fixes-only (`PingDao.fixesByDateRange`, no-fix rows dropped at SQL), retained only while the map watches it, and deliberately has NO `ref.keepAlive()` (that would recreate the retain-every-range leak; the panel copies the list into `_snap` before the GeoJSON build, so disposal can't race an upload). `allPingsProvider` stays non-autoDispose and returns the full table incl. no-fix rows because stats/trips/export need the gaps. **Invalidate `pingsByRangeProvider` (the whole family) after every `pings` write** — archive, delete-pin, panic, "Ping now", pull-to-refresh all do; a new path that writes pings must too. `approxLocationProvider` is `autoDispose.family<String?, GeocodeKey>` (4-dp int pair via `geocodeKey(lat, lon)`), `keepAlive()` only on a non-null result; `GeocodingService` holds a 512-entry LRU + in-flight dedupe, and `reverseLookupAll` runs at most 4 lookups concurrently. `PingPhotoDao.byPingIds` dedupes ids and chunks at `inListChunk = 900` (SQLCipher's 32 766 host-parameter cap).

30. **Startup is two awaits, everything else is post-frame.** `main()` awaits `Future.wait([OnboardingGate.isComplete(), computeNeedsUnlock()])` and nothing else. `WorkmanagerScheduler.initialize()` is memoised (a failure resets it for retry) and every enqueue path awaits it, so the lock screen cannot enqueue before init; `NotificationService` init is a memoised future (the old bool guard wasn't concurrency-safe). Don't add new `await`s before `runApp` — put them in the post-frame block. Honest note: sharing `secureStorage` is hygiene, not a measurable win — `flutter_secure_storage` 9.2.4 re-runs its native `ensureInitialized()` on every call regardless.

## Related Docs

- **`docs/PLAN.md`:** full design, battery budget, phase breakdown, open questions, confirmed decisions (19 total).
- **`docs/PERF_PLAN.md`:** 2026-08-22 performance analysis + phased fix plan (M1–M3 shipped in 0.14.0+95; M4 + §3 #2, #3, #4, #5, #9 in 0.14.1+96; M5 and the rest of §3 pending). Root cause of the slow multi-year pin load (per-pin `addCircle` is Θ(N²) in `maplibre_gl` 0.26.0, map remount on range change, `_controller = null` bug on cached ranges) and 22 ranked app-wide improvements. Read it before touching `full_map_panel.dart` rendering.
- **`docs/TIMELINE_IMPORT.md`:** 2026-08-22 feasibility + plan for importing Google Maps Timeline exports (`Timeline.json`, iOS dialect, legacy Takeout). Not built; read it before starting that feature — it records the export paths that still exist, the format, the thinning/dedupe rules and the exclusions (heartbeat, Wikimedia auto-fetch) that must ship with it.
- **`README.md`:** project summary, planned stack.
