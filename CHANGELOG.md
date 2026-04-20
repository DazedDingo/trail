# Changelog

All notable changes to **Trail** (gps-pinger) are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) with the Android `versionCode+build` suffix.

## [0.6.1+16] — 2026-04-20

### Added

- **Auto-send panic SMS** (opt-in, off by default). New native
  `SmsManager.sendTextMessage` path on the `com.dazeddingo.trail/panic`
  channel; Dart side at `PanicService.autoSendSms` handles the runtime
  `SEND_SMS` grant + multipart split. The panic button now shows a
  5-second undo SnackBar before the send fires, so an accidental panic
  tap can still be cancelled; tapping "UNDO" keeps the ping logged but
  blocks the SMS. Toggle lives at `Settings → Panic → Auto-send panic
  SMS`; state persists via `panicAutoSendProvider` (same secure-storage
  pattern as the continuous-duration tile). When the toggle is off,
  the existing compose-intent flow (open SMS app → user taps Send) is
  unchanged.

### Changed

- **Home-screen panic button de-emphasised.** Pre-0.6.1 was a bright
  red `FilledButton` that fired on a single tap — too easy to
  accidentally trigger from pocket taps or UI mis-touches. Now:
  - **Hold-to-trigger** (600 ms). Long-press fills a progress overlay
    across the button; releasing before the hold completes cancels
    cleanly.
  - **Outlined** red instead of filled, on a lighter card tint
    (`errorContainer` alpha 0.15 ↓ from 0.4, border alpha 0.45 ↓ from
    0.6). Still visually distinct, no longer dominates the screen.
  - Continuous-panic action demoted from outlined-button to a
    lower-emphasis TextButton below the main action.
  - Label switched from "PANIC NOW" to "Hold to panic" so the gesture
    is self-describing.
- `AndroidManifest.xml` declares the new `SEND_SMS` permission. It's
  a runtime-dangerous permission, so the system prompts on first
  auto-send — users who never flip the toggle never see the dialog.

## [0.6.0+15] — 2026-04-20

### Added

- **Phase 6: polish.** The last planned phase lands — closes out the
  diagnostics, heatmap, home-location, and date-range-export items
  held back from earlier work, plus confirms the adaptive icon is
  already shipping in the intended neutral style.

  - **Diagnostics screen** at `Settings → Diagnostics`. Permission
    matrix (fine / background location, battery optimisation,
    notifications, exact-alarm) loaded in parallel via `Future.wait`,
    each row showing the `PermissionStatus` with colour-coded iconography.
    **DB integrity check** button runs `PRAGMA integrity_check` on the
    shared UI handle and surfaces the result list inline (healthy DB =
    single `ok` row). **Last 20 worker runs** list sourced from a new
    `WorkerRunLog` (shared-prefs, rolling, JSON-encoded) that every
    branch of the WorkManager `_callbackDispatcher` now writes to
    (`ok` / `no_fix` / `low_battery_skip` / `awaiting_passphrase` /
    `error`, with a battery-% / reason note). **Copy-all** AppBar
    action dumps the whole snapshot — version, permissions,
    recent runs — to clipboard for pasting into a bug report.
    Screen refreshes on lifecycle resume (`WidgetsBindingObserver`)
    so returning from the Android settings pane shows the new
    permission state immediately.
  - **Date-range export.** The home-screen's "Export GPX" + "Export
    CSV" pair (both dumped ALL history) collapses to a single
    "Export…" entry opening an `ExportDialog`. Uses
    `showDateRangePicker` + a `RadioGroup<ExportFormat>` for
    GPX+CSV / GPX-only / CSV-only; "All history" stays as a
    one-tap preset. Filter logic is factored to a pure
    `filterPingsByRange(rows, range)` (inclusive start, `end` bumped
    to next-day midnight so a single-day pick covers the whole local
    day — picker returns 00:00 local for both sides). Empty-range
    exports surface an inline error instead of sharing an empty file.
  - **Heatmap overlay** on the map screen. AppBar toggle swaps the
    path polyline + pins for a density view: pings bucketed into
    0.001° grid cells (~100 m at the equator), each bucket rendered
    as a `RadialGradient`-filled `Marker` with radius and alpha
    scaled to normalised bucket count. Gives a single glance at
    "where do I actually spend my time" without squinting at
    overlapping pins.
  - **Home location.** `Settings → Home` lets the user store a
    lat/lon + optional label, either by reusing the last successful
    fix or by manual entry. `HomeLocationService` persists to shared
    prefs (`trail_home_lat_v1` / `trail_home_lon_v1` /
    `trail_home_label_v1` / `trail_home_saved_at_v1`). Home screen
    shows a "`X km from home`" line under the current coords using
    `HomeLocation.distanceMetersTo` (Haversine, R=6371000). Empty
    labels normalise to null at write-time so the UI doesn't render
    an empty title.
  - **Adaptive icon** confirmed. `mipmap-anydpi-v26/ic_launcher.xml`
    already ships with a neutral teal Material-pin foreground on
    `#0E1115` background (plus the round and monochrome variants),
    matching the PLAN's "neutral / disguised" requirement. No code
    change needed — documented here so Phase 6 is bookkept complete.

### Changed

- Home-screen layout: coords block now includes a home-distance
  subtitle when home is set; export row is a single outlined
  "Export…" button instead of two side-by-side format buttons.
- Settings screen now has a **Home** section (between Panic and
  Offline map) with a tile showing the current home label /
  coords or "Not set" + chevron to the setter screen.
- `WorkManager` dispatcher records a `WorkerRunLog` entry on every
  branch — callers don't need to opt in, it's wired at each
  terminal outcome in `_handleScheduled`, `_handleRetry`,
  `_handlePanic`, `_handleBoot`, and the `catch` /
  `PassphraseNeededException` paths.

### Tests

- `home_location_service_test.dart` (10 cases): round-trip
  lat/lon/label + `savedAt`, null-on-fresh-install,
  empty-label-normalises-to-null, `clear()` wipes, overwrite
  semantics, `HomeLocation.distanceMetersTo` Haversine
  sanity (zero / London↔Paris ≈ 343.6 km / 100 m at equator ≈
  0.0009° / antipodal ≈ 20 015 km).
- `worker_run_log_test.dart` (10 cases): empty-on-fresh-install,
  round-trip, null note, newest-first order, maxEntries trim
  (25 writes → 20 survivors, oldest dropped), malformed-JSON
  fallback, non-list-JSON fallback, non-map entry filter,
  missing-field fallback (`unknown`), trim-then-append stability.
- `export_dialog_filter_test.dart` (6 cases): null range
  passthrough, empty input, single-day inclusive/exclusive
  bounds, multi-day range, input-order preservation.
- Full suite: **245 tests passing.** `flutter analyze` clean.

## [0.5.0+14] — 2026-04-20

### Added

- **Phase 5: exact alarms + archive flow.** Closes out the two
  scheduling-and-retention items the plan held back until the map and
  regions work landed.

  - **Scheduler mode toggle** (`Settings → Scheduling → Mode`). Two
    options: **Battery saver** (default, WorkManager — the existing
    4h periodic job, system-batched, battery-aware) and **Precise**
    (Android `AlarmManager.setExactAndAllowWhileIdle` per ping, fires
    ± a small window even under Doze at the cost of more frequent
    standalone wakeups). Switching mode cancels the other side's
    scheduled work so only one driver is ever active. Precise mode
    requires `SCHEDULE_EXACT_ALARM` on API 31+; when denied, the tile
    deep-links to the per-app settings page via
    `Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM` and the mode
    switch aborts cleanly instead of silently degrading.
  - **Scheduler events** log (last 20, newest-first) surfaces on
    Settings → Scheduling → Recent events. Native side records
    `EXACT_SCHEDULED`, `EXACT_FIRED`, `EXACT_CANCELLED`,
    `EXACT_PERMISSION_DENIED`, `MODE_CHANGED`, and
    `WORKMANAGER_ENQUEUED`. Gives the user concrete evidence that the
    4h cadence is actually firing instead of staring at the black box
    of WorkManager.
  - **Boot re-arm for exact mode.** `BootReceiver` reads
    `SchedulerPrefs.isExactMode` and calls
    `ExactAlarmScheduler.scheduleNext(context)` on
    `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED`, so the alarm chain
    survives reboots and APK upgrades without waiting for the user
    to open the app. The MethodChannel mirror
    (`recordModeChanged`) writes the same prefs file so this works
    even without the Flutter UI running.
  - **Archive older pings** (`Settings → History → Archive older
    pings`). Pick a cutoff date, pick export format (GPX + CSV
    default, or either alone), preview how many rows would be
    archived plus the earliest/latest timestamp, then confirm a
    destructive dialog. The flow writes every selected export file
    to the temp dir *first*; only if every write succeeds does the
    DB `DELETE` run, so a failed export leaves the DB untouched.
    On success, `share_plus` opens the share sheet so the user
    lands the archive in Drive / email / wherever before closing
    the app. Default cutoff is "1 year ago" to protect against
    accidental recent-history pruning.

### Changed

- **Onboarding copy** — the emergency-contacts step no longer says
  "later you'll be able to add contacts". Panic + contacts shipped
  in 0.2.0+11; the step now points the user to
  `Settings → Emergency contacts`. Home-location step still frames
  the feature as future because the actual home-location UI is
  Phase 6.

### Tests

- **`test/archive_service_test.dart`** — 7 tests against
  `archiveWithHandle` with in-memory SQLite + tempdir: export-then-
  delete ordering, `StateError` on empty archive (DB untouched,
  zero files on disk), format selectors (gpxAndCsv / gpxOnly /
  csvOnly produce the expected extensions), filename encodes
  cutoff `YYYYMMDD`, strict-`<` cutoff leaves exact-match rows
  alone.
- **`test/ping_dao_test.dart`** adds 9 tests covering
  `countOlderThan` / `olderThan` / `deleteOlderThan`: empty table,
  strict `<` cutoff, noFix inclusion, ASCENDING export order, row
  count returned from delete, newer rows untouched.
- **`test/scheduler_event_test.dart`** — 8 tests: full round-trip
  of the Kotlin → Dart JSON shape, nullable `note`, tolerant `tsMs`
  (int and Long-as-double), fallback to `unknown` on missing kind,
  `SchedulerMode.fromWire` defaults to `workmanager` for null /
  garbage input.

## [0.4.0+13] — 2026-04-20

### Added

- **Phase 4: offline MBTiles regions + full-screen map.** The map
  viewer now reads from sideloaded raster `.mbtiles` packages when the
  user has a region installed and active, and falls back to online
  OpenStreetMap tiles when it doesn't. The logging pipeline has been
  offline since Phase 1; this closes the loop so the *viewer* can be
  offline too.

  - **Regions library** (`Settings → Offline map`). Install a
    `.mbtiles` via the Android SAF picker — Trail copies it into
    `<appDocumentsDir>/mbtiles/` so sideloads survive the SAF URI
    going stale. Per-region tiles show filename + size. Popup menu
    actions: Set as active · Clear active · Delete. Deleting the
    active region clears the active pref so the viewer doesn't point
    at a missing file.
  - **Active region state** is persisted in `SharedPreferences`
    (`trail_active_mbtiles_v1`) rather than the encrypted DB — this
    is a UX preference, not sensitive data, and it needs to be
    readable from every isolate without a DB plumb. `getActive()`
    verifies the file still exists on disk; if it's gone (user
    deleted from a file manager, OS upgrade nuked it), the pref is
    auto-cleared and the viewer silently reverts to online OSM.
  - **Full-screen map** (`/map`, opened via the "Full map" button in
    the home-screen header). Renders all historical pings at once
    (new `allPingsProvider`), fits the bounding box on first load,
    and offers a time slider that limits the visible window to the N
    earliest pings with the HH:mm of the last visible ping shown
    next to the slider. Path-line toggle uses the same warning text
    as the home-screen trail — 4-hour intervals *don't* mean the
    user walked a straight line, so pins-only is the default.
  - **Tile pipeline** — `docs/TILES.md` now documents the one-time
    PC-side flow: Geofabrik extract → `tilemaker` →
    rasterise → `adb push` → install via regions screen. UK-wide
    raster MBTiles land around 200–600 MB.

### Changed

- **Backup rules** (`res/xml/backup_rules.xml` +
  `data_extraction_rules.xml`) now `<exclude domain="file"
  path="mbtiles/"/>` so multi-hundred-megabyte tile packages don't
  count against Android's 25 MB per-app Google Drive quota. The
  encrypted DB and the PBKDF2 salt file are still included — the
  user can re-sideload regions after uninstall/restore, but they
  can't re-derive the key without the passphrase.
- `pubspec.yaml` pulls in `flutter_map_mbtiles 1.0.4`,
  `file_picker 11.0.2`, and `shared_preferences 2.5.5`.
- `flutter_map_mbtiles`'s transitive pins forced
  `sqflite_common_ffi` down from 2.4.0+2 to 2.3.7+1, which calls
  `DynamicLibrary.open('libsqlite3.so')`. The unversioned symlink
  lives in `libsqlite3-dev` (not installed on CI / fresh dev
  images), so `test/ping_dao_test.dart` now passes an `ffiInit`
  callback via `createDatabaseFactoryFfi` that registers
  `open.overrideFor(...)` *inside* the ffi background isolate —
  the main-isolate registry doesn't propagate across
  `Isolate.spawn`. Ladder tries `.so.0` at the usual
  `/lib/{arch}-linux-gnu/` locations.

### Tests

- **`test/mbtiles_service_test.dart`** — 14 tests against a
  temp-dir-backed fake `PathProviderPlatform`:
  `listInstalled` empty-case + non-mbtiles-skip + alphabetic-sort,
  `install` copy + overwrite + missing-source throw, active-region
  round-trip + stale-file auto-clear, `delete` removes-file +
  clears-active-when-active + leaves-other-active + idempotent.

## [0.3.0+12] — 2026-04-20

### Added

- **Phase 3: Quick-settings tile + home-screen widget.** Both trigger
  continuous-panic without opening the app, using the same ignition
  path as the home-screen panic button — native entry →
  `PanicForegroundService.start()` → WorkManager ticks → Flutter
  dispatcher writes a `panic` row. One pipeline, three entry points.

  - **Quick-settings tile** (`PanicTileService`). Register once via
    Android Quick Settings Edit pane; tap to start the FG service for
    the user's configured duration. Tile subtitle shows the current
    duration (e.g. "30 min") so users can see what they're about to
    start. `BIND_QUICK_SETTINGS_TILE` permission locks binding to the
    system.
  - **Home-screen widget** (`PanicWidgetProvider`, 2×1 resizeable).
    Tap to fire the same FG-service path. Widget face shows "PANIC" +
    a subtitle with the duration so it stays glanceable. No running
    indicator on the widget itself — the FG notification already owns
    that surface.
  - **Duration mirror**: the user's chosen 15/30/60-min preference is
    now mirrored from Flutter secure storage into a native
    `SharedPreferences` file (`trail_panic_prefs`) via a new
    `setContinuousDurationMinutes` MethodChannel method. Both the
    tile and widget read that mirror on click, so they honour the
    Settings-screen choice without ever touching Keystore-backed
    storage. Mirror is re-synced on every `panicDurationProvider`
    build and every `set()`, so it can never drift stale.

### Changed

- `AndroidManifest.xml` registers
  `<service android:name=".PanicTileService" …/>` with the
  `android.service.quicksettings.action.QS_TILE` intent-filter and
  `<receiver android:name=".PanicWidgetProvider" …/>` with the
  `APPWIDGET_UPDATE` + `WIDGET_PANIC` actions plus the
  `@xml/panic_widget_info` metadata.
- New resources: `res/layout/panic_widget.xml`,
  `res/drawable/panic_widget_bg.xml`,
  `res/xml/panic_widget_info.xml`.

## [0.2.0+11] — 2026-04-20

### Added

- **Phase 2: Panic button + emergency contacts + continuous panic.** Full
  Phase-2 scope shipped as a single release.

  - **Panic button** on the home screen fires a one-shot high-accuracy
    (`LocationAccuracy.best`, 45s budget) ping, writes a `panic` row
    through the existing DAO, posts a visible "Panic ping logged"
    notification, then opens the user's default SMS app pre-filled
    with every configured emergency contact and a
    `PANIC at HH:MM — https://maps.google.com/?q=lat,lon` body. No
    `SEND_SMS` permission is used — the user still taps Send in their
    SMS app. Empty-contacts case surfaces an inline "configure
    contacts" nudge instead of silently launching an empty SMS.
  - **Emergency contacts screen** (`/contacts`) with full CRUD: name
    and E.164-validated phone, stored in the existing encrypted
    `emergency_contacts` table (schema unchanged — table was already
    seeded in v1).
  - **Continuous-panic mode** runs for a user-selectable 15 / 30 / 60
    min duration (persisted in secure storage under
    `trail_panic_duration_v1`). A native foreground service
    (`PanicForegroundService.kt`,
    `foregroundServiceType="location"`) owns the ongoing
    "Panic active" notification with a Stop action and ticks every
    ~90s. Each tick enqueues a one-off WorkManager task that
    re-enters the Flutter dispatcher and runs `_handlePanic` in
    `workmanager_scheduler.dart` — same isolate + DAO path as
    scheduled pings, so SQLCipher access stays in Dart. Session
    auto-stops after the configured duration even if the app process
    dies. Stop action, `stopContinuous()` MethodChannel call, and
    auto-timeout all route through the same clean-shutdown path.
  - **Panic notification channel** (`trail_panic`) posts a receipt
    after every one-shot and every continuous tick. Scheduled pings
    stay silent — too frequent to notify.
  - **Settings → Panic** section: quick-link to `/contacts`, and a
    duration dropdown wired to `panicDurationProvider`.

### Changed

- `MainActivity.kt` now registers `PanicMethodChannel` alongside
  `CellWifiPlugin` for the `com.dazeddingo.trail/panic`
  MethodChannel (`startContinuous`, `stopContinuous`). Channel errors
  downgrade gracefully to the one-shot path so a broken native build
  can't block a panic in the field.
- `AndroidManifest.xml` declares
  `<service android:name=".PanicForegroundService" android:foregroundServiceType="location" android:exported="false"/>`.
  `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_LOCATION` permissions
  were already declared in Phase 1 for exactly this moment.
- Router gains `GoRoute('/contacts' …)` for the new screen.
- `main.dart` initialises `NotificationService` on startup so the
  first panic triggers a notification without channel-creation
  latency.

### Testing

- 9 new `panic_share_builder_test.dart` cases covering empty
  contacts, blank-phone filtering, comma-joined recipient paths,
  5-decimal maps-URL formatting, no-fix fallback, lat-only /
  lon-only defensive fallback, and deterministic `HH:mm`
  formatting. Full suite at 181 passing.

## [0.1.9+10] — 2026-04-20

### Added

- **Interactive map viewer on the home screen.** The home-screen
  `TrailMap` widget is now a real `flutter_map` view with pinch-zoom,
  pan, double-tap-zoom, fling, and scroll-wheel-zoom gestures; tiles
  are OpenStreetMap raster over HTTPS. Polyline + dot markers render
  on top of the basemap, the latest fix gets an accent marker in the
  theme's tertiary colour, and a corner recenter button fits the
  camera back to the trail bounds after the user pans away. A new
  frame auto-refits whenever a newer fix arrives so the current
  position stays on-screen across the 4h cadence.

### Changed

- `android.permission.INTERNET` is now declared in
  `AndroidManifest.xml` — required for the map viewer's tile
  requests. The logging pipeline itself (GPS, SQLCipher write, export)
  still has zero network dependencies; only the history visualisation
  reads tiles. Offline devices still log and export fine — the map
  surface just shows a blank grid with the polyline + markers drawn
  on top.
- `docs/PLAN.md` Phase 4 (offline MBTiles) is still planned — this is
  an intermediate "usable map today" step, not a replacement for the
  sideloaded raster tiles design. When Phase 4 lands, swapping the
  `TileLayer` source is a one-line change.

## [0.1.8+9] — 2026-04-20

### Fixed

- **"Database is closed" error when setting a backup passphrase.**
  `TrailDatabase.rekey()` called `openDatabase(path, password: ...)` to
  obtain a handle for `PRAGMA rekey`. sqflite's default
  `singleInstance: true` made that call return the exact same handle
  `TrailDatabase.shared()` was already serving to the UI isolate's
  Riverpod providers. Rekey's `finally { db.close() }` then tore down
  the handle those providers still held direct references to — the
  home screen's next query surfaced as a generic database exception
  right after the setup dialog closed.

  Fix: `invalidateShared()` is now async, awaits the close of the
  cached shared handle, and is invoked BEFORE `rekey()` so the
  `openDatabase` inside rekey produces a fresh handle it fully owns.
  After rekey + key persist, the pings providers are invalidated so
  they re-fetch with the new shared handle (freshly opened against the
  newly-persisted derived key).

## [0.1.7+8] — 2026-04-19

### Added

- **User-set backup passphrase → history survives uninstall.** New
  Settings → "Enable cloud backup" flow: user picks a passphrase, we
  derive a 32-byte SQLCipher key via PBKDF2-SHA256 (OWASP 2023: 210k
  iterations), save a 16-byte salt next to the DB, and `PRAGMA rekey`
  the encrypted database in place. Android's auto-backup is now on
  (`allowBackup="true"`), so the DB + salt get snapshotted to Google
  Drive; reinstall + re-enter passphrase = full history back.

  The derived key is still persisted in `FlutterSecureStorage` so the
  background WorkManager isolate reads it transparently — no plumbing
  changes in the scheduler. On a fresh install post-restore, the
  Keystore-bound secure storage is empty but the restored salt file
  signals "passphrase mode active"; `KeystoreKey.getOrCreate()`
  returns `null` in that case instead of silently generating a new
  random key (which would orphan the restored DB). The UI startup gate
  (`needsUnlockProvider`) detects this and routes to `/unlock`, the
  scheduler catches `PassphraseNeededException` and skips the ping
  cleanly until the user unlocks.

  Trade-off (called out explicitly in the setup dialog): if the user
  forgets the passphrase, the backup is unrecoverable. Same E2E
  property as any user-keyed encrypted backup.

### Changed

- `android:allowBackup` flipped from `false` to `true`. Backup rules
  (`res/xml/backup_rules.xml` + `res/xml/data_extraction_rules.xml`)
  explicitly include the `file` domain (covers `trail.db` +
  `trail_salt_v1.bin`) and exclude `FlutterSecureStorage.xml` — its
  Keystore master key doesn't migrate across uninstall, so a
  round-tripped entry would be unreadable anyway and the exclude
  avoids clobbering a freshly-generated Keystore alias on reinstall.
- `TrailDatabase.open()` now throws `PassphraseNeededException` when
  passphrase mode is active but no key is stored. Background handlers
  call `open()` *before* acquiring GPS so a locked-backup install
  doesn't spend 30s on a fix it can't record.
- `KeystoreKey.getOrCreate()` return type is now nullable (`String?`).
  `null` means "passphrase mode active, needs unlock" — distinct from
  "no key and ready to generate a fresh random one", which still
  returns a new key as before.

### Tests

- `test/passphrase_service_test.dart` — 14 new tests: PBKDF2
  determinism, salt-sensitivity, output format, salt file roundtrip,
  corrupted-salt handling, OWASP iteration-count floor.
- `test/keystore_key_test.dart` — added `read`/`persist` groups plus
  the passphrase-mode-aware `getOrCreate` group (salt present + no
  stored key → returns null, doesn't write).
- `test/android_manifest_sanity_test.dart` — replaced the
  `allowBackup=false` guard with `allowBackup=true` +
  `fullBackupContent="@xml/backup_rules"` + backup-rules-file-exists +
  include-file-exclude-sharedpref assertions.

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
