# GPS Pinger — Implementation Plan (living design doc)

Status: design phase, not yet implemented. Owned by Zach (DazedDingo).
Last updated: 2026-04-16.

## Goal

A personal-safety + curious-data-gathering app that runs constantly on an Android phone, fully offline. Pings GPS every 6 hours, writes encrypted local log, renders an in-app offline map of history, supports panic-ping on demand, and exports GPX/CSV.

## Confirmed requirements

- Platform: Flutter, Android-only.
- Cadence: one scheduled GPS ping every 6 hours. No internet dependency.
- Data per ping: timestamp, lat, lon, accuracy, altitude, battery %, network state, source (`scheduled` | `panic`), optional note.
- Storage: SQLite encrypted with SQLCipher. Key derived via Android Keystore (via `flutter_secure_storage`) — no user PIN for MVP.
- Panic ping: prominent manual button, high-accuracy fix, optional short note, runs in a short-lived foreground service to guarantee completion.
- Reliability UI: home screen shows "last successful ping" timestamp; heartbeat card turns red if >7h since last ping. "No fix" rows logged when 2-min GPS budget expires so gaps are never silent.
- Export: GPX + CSV via share sheet.
- In-app map: raster tile offline map (MBTiles), shows pings as pins colour-coded by source, with a time slider.

## Repo

- Name: `DazedDingo/gps-pinger` (working title — open to rename).
- Local path: `/home/ubuntu/projects/gps-pinger`.
- CI: fork of `watchnext/.github/workflows/release.yml` — push to `main` auto-builds and publishes APK to GitHub Releases. Reuse pinned `DEBUG_KEYSTORE_B64` pattern for consistent SHA-1 (no Google services needed, so no `GOOGLE_SERVICES_JSON` step).
- Stack: Flutter (Dart ^3.11), Riverpod, go_router — matches `watchnext`/`groceries-app`.

## Directory / file structure

```
lib/
  main.dart
  app.dart                         # MaterialApp + router
  models/ping.dart                 # Ping data class + enum PingSource
  db/
    database.dart                  # SQLCipher open + migrations
    ping_dao.dart                  # insert/query/paginate
    keystore_key.dart              # Keystore-backed DB key
  services/
    location_service.dart          # geolocator wrapper, scheduled + panic fetch
    battery_network_service.dart   # battery_plus + connectivity_plus snapshot
    scheduler/
      workmanager_scheduler.dart   # PeriodicWorkRequest baseline
      alarm_scheduler.dart         # AlarmManager exact fallback (MethodChannel)
      scheduler.dart               # abstract + selection logic
    permissions_service.dart       # staged permission flow
    export/
      gpx_exporter.dart
      csv_exporter.dart
    tiles/
      mbtiles_source.dart          # flutter_map TileProvider backed by MBTiles
      region_manager.dart          # install/remove .mbtiles in app docs dir
  providers/                       # Riverpod: pingListProvider, lastPingProvider, healthProvider
  screens/
    home_screen.dart               # last-ping card, heartbeat status, panic button
    history_screen.dart            # list view
    map_screen.dart                # flutter_map + ping pins + time slider
    export_screen.dart
    regions_screen.dart            # manage installed tile regions
    settings_screen.dart           # permissions, battery-opt, scheduler mode, diag
android/
  app/src/main/kotlin/.../AlarmReceiver.kt
  app/src/main/AndroidManifest.xml
.github/workflows/release.yml
```

## Plugin choices (sanity-checked against Flutter 3.x)

- `geolocator` ^13
- `workmanager` ^0.5
- `sqflite_sqlcipher` ^3
- `flutter_secure_storage` ^9
- `permission_handler` ^11
- `battery_plus` ^6, `connectivity_plus` ^6
- `share_plus` ^10
- `flutter_local_notifications` ^17 (missed-heartbeat warnings only)
- `flutter_map` ^7 + `flutter_map_mbtiles` — offline raster tile rendering
- `path_provider`, `intl`, `package_info_plus`
- Riverpod ^2.5, go_router ^14

## Phased milestones

### Phase 1 — MVP (logs + exports)
Scaffold, encrypted DB with Keystore key, `LocationService.getScheduledPing()`, `WorkManager` 6h PeriodicWorkRequest, home screen (last ping card + history list), GPX + CSV export via share sheet, staged permission flow (fine → background → "Allow all the time" education dialog). **Demo:** install, grant permissions, see pings accumulate over a day, export to GPX, open in OsmAnd.

### Phase 2 — Panic ping + reliability
Big panic button on home with note field; panic path starts a short-lived foreground service (`foregroundServiceType="location"`) to guarantee a fix within 2min. Heartbeat card turns red if `now - lastPingTs > 7h`. Battery-optimization exemption prompt on first launch. **Demo:** hit panic outdoors, high-accuracy row appears immediately with note.

### Phase 3 — Offline map
Raster MBTiles. `regions_screen` lets user install one or more `.mbtiles` files into the app's documents dir (via file picker — tiles are built externally on PC with `tilemaker`/OpenMapTiles, not downloaded at runtime). `map_screen` renders installed tiles via `flutter_map_mbtiles` and overlays ping pins colour-coded by source. Time slider to scrub history. **Demo:** install a UK-region `.mbtiles`, open map with a month of pings plotted.

### Phase 4 — Scheduling hardening
Add `AlarmManager.setExactAndAllowWhileIdle` path behind a MethodChannel (`SCHEDULE_EXACT_ALARM` on API 31+, `USE_EXACT_ALARM` on 33+). Settings screen lets user pick WorkManager vs exact-alarm mode and view last N scheduling events. **Demo:** toggle modes, compare punctuality over a week.

### Phase 5 — Polish
In-app diagnostics (permission matrix, doze state, last 20 worker runs), DB integrity check, export filtering by date range, app icon + adaptive icon, heatmap overlay on map screen (nice-to-have).

## Architectural risks & mitigations

1. **Doze clustering** — PeriodicWorkRequest has no exactness guarantee. Mitigation: dual-path scheduling (Phase 4), visible heartbeat staleness, battery-opt exemption, "no fix" rows so gaps are never silent.
2. **Cold GPS fix without A-GPS** can exceed 2min. Mitigation: configurable budget, log partial/failed attempts.
3. **Background-location grant friction** on Android 11+. Mitigation: onboarding screen with explicit "Allow all the time" instruction and `permission_handler.openAppSettings()` deep link.
4. **Keystore key loss on backup restore** could brick DB. Mitigation: detect open failure, offer "reset DB" with warning; disable cloud backup of app data (`allowBackup="false"` in manifest).
5. **SQLCipher + WorkManager isolate**: background isolate must re-init plugin registry and re-open encrypted DB. Verify early in Phase 1 (known sharp edge).
6. **Tile file size**: UK-wide raster MBTiles at reasonable zoom can be several hundred MB. Mitigation: user picks regions to install; unused regions deletable from `regions_screen`.

## Testing strategy

- Unit-testable: GPX/CSV serializers, Ping model, DAO against in-memory SQLCipher DB, heartbeat-staleness logic, MBTiles tile-lookup. Target ~70% coverage here.
- Mocked: `LocationService` behind an interface so providers/screens test without GPS.
- Manual-QA-only: WorkManager cadence (multi-day soak), AlarmManager exactness, permission dialogs, panic FG service, Doze behaviour (`adb shell dumpsys deviceidle force-idle`), live map rendering.

## Tile sourcing (one-time, on PC — not runtime)

- Download OpenStreetMap regional extract from Geofabrik (e.g. `great-britain-latest.osm.pbf`).
- Render to raster MBTiles with `tilemaker` or use a pre-built raster MBTiles source.
- Copy `.mbtiles` file to phone via USB or share, then install into app via `regions_screen`.
- Document the exact command/pipeline in `docs/TILES.md` when Phase 3 starts.

## Open questions

- **Regions covered?** — UK only for MVP, plus ad-hoc additions when travelling? Confirm before Phase 3.
- **Retention policy** — keep forever, or auto-prune after N months? Default: forever.
- **Panic notification** — fire a local notification as visible receipt? Leaning yes, Phase 2.
- **Versioning** — push-to-main-auto-releases (like watchnext), or gate behind tags? Leaning match-watchnext.
- **Repo visibility** — public or private on GitHub? Safety app, so private by default unless user says otherwise.
