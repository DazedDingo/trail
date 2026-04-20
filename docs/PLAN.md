# Trail — Implementation Plan (living design doc)

Status: design phase, not yet implemented. Owned by Zach (DazedDingo).
Last updated: 2026-04-16.

## Goal

A personal-safety + curious-data-gathering app that runs constantly on an Android phone, fully offline. Pings GPS every 4 hours, writes encrypted local log, renders an in-app offline map of history, supports panic-ping (on-demand or widget/tile-triggered) that optionally auto-shares location to pre-configured contacts, and exports GPX/CSV.

## Product identity

- **App display name:** `Trail`
- **Android `applicationId`:** `com.dazeddingo.trail` (proposed — stable, reverse-DNS, Play-ready if ever published)
- **Repo / working title:** `gps-pinger` (repo name stays — low-churn)
- **Icon style:** neutral / disguised (generic compass or map pin, blends in with default system apps — intentionally not branded)
- **Theme:** dark mode default (user preference across all their apps)

## Battery budget — **top priority: negligible impact**

Battery conservation is an explicit design constraint. The app must be invisible in daily battery stats. Every feature below is scrutinised against this:

### Hard rules
- **No persistent foreground service for scheduled pings.** Only WorkManager / AlarmManager for the every-4h job. Foreground service exists ONLY during an active panic-continuous session.
- **No background service between pings.** App process should be fully dead between windows.
- **No polling loops anywhere.** Everything scheduled-or-event-driven.
- **No `LocationAccuracy.best` for scheduled pings.** Use `LocationAccuracy.high` (or Fused balanced) — good enough at human scale, uses GPS efficiently. `best` is reserved for panic pings where the tradeoff is worth it.
- **GPS radio on for as little time as possible per ping.** Target: acquire fix, stop updates, release client. Typical 10–30s warm, up to 2min cold. Never leave GPS streaming.
- **No wake-lock beyond the WorkManager worker lifetime.** WorkManager handles this automatically — don't add custom wake locks.
- **Screen stays off** — worker must not wake the display.
- **Cell / Wi-Fi capture is passive.** Read last-known cell-info and last-known Wi-Fi info; do NOT trigger active scans. If data is stale/unavailable, skip the field.
- **No Doze-busting for scheduled pings.** Exact alarms (Phase 5) are opt-in and explicitly labelled "higher battery use" in settings.

### Estimated cost per ping (scheduled)
- GPS fix acquisition: ~20–40 mA for 15–60s → ≈0.2–0.6 mAh per ping
- SQLCipher write + small compute: negligible
- At 4h cadence: 6 pings/day × ~0.4 mAh average ≈ **2–3 mAh/day** ≈ ~0.05% of a 5000 mAh battery
- Retry-once-after-5min adds at most one extra fix per failure window

### Panic burst (user-triggered only)
- Continuous mode 1–2min cadence × up to 60min = ~30 fixes + visible foreground service
- Expected cost: ~20–40 mAh per panic session (≈1% of battery for a 60-min panic)
- Acceptable because it's user-initiated and safety-critical

### Verification plan
- Phase 1 includes a diagnostic screen showing "last N worker runs" — duration, success, power-relevant events
- Before release, sanity-check via Android Settings → Battery → App usage over a few days; target <1% allocation attributed to Trail
- Fix any hotspot in Phase 6 polish if observed above baseline

## Confirmed requirements (decisions log)

### Core cadence & data
- **Platform:** Flutter, Android-only
- **Cadence:** one scheduled ping every **4 hours**
- **Data per ping:** timestamp (UTC), lat, lon, accuracy, altitude, heading, speed, battery %, network state, nearby cell-tower ID, nearby Wi-Fi SSID, source (`scheduled` | `panic` | `boot` | `no_fix`), optional note
- **Retry on failed scheduled ping:** log `no_fix` row, retry **once 5 min later**, then wait until next 4h window
- **Retention:** keep forever. Provide a manual "archive older than X" flow that exports to GPX/CSV then deletes from DB. No auto-prune.

### Scheduling behaviour
- **Sleep window:** none — always ping every 4h regardless of time or charge state
- **Low-battery policy:** drop to **8h cadence below 20%**, **stop entirely below 5%** (log `no_fix` rows with battery note during stop)
- **Device off / reboot:** on boot, log a `boot` row immediately AND trigger a fresh ping attempt (don't wait for next scheduled window)

### Panic
- **Panic ping:** prominent in-app button, plus Android **quick-settings tile** AND **home-screen widget** for one-tap invocation without opening app
- **Continuous mode:** after panic triggered, keep pinging every 1–2 min via foreground service with visible notification, for a **user-configurable duration (15 / 30 / 60 min)**, then auto-stop
- **Panic receipt:** visible local notification "Panic ping logged at HH:MM — [coords]" (scheduled pings stay silent — too frequent to notify)
- **Panic external share:** maintain a list of pre-configured emergency contacts in settings. On panic, open the **default SMS app pre-filled** with those recipients and message text (`PANIC at HH:MM — https://maps.google.com/?q=lat,lon`). User still taps "send" — no `SEND_SMS` permission used (Play Store scrutiny, and keeps user in control).
- **Impact detection / auto-panic:** no (rejected — false positives, battery cost)
- **Duress PIN:** no (rejected — overkill)

### Security
- **Storage:** SQLite encrypted with **SQLCipher**. Key derived via Android Keystore (via `flutter_secure_storage`). No user-set passphrase.
- **App lock:** **biometric only** (fingerprint/face) on app open, with device-PIN fallback via `local_auth`
- **Backup:** `android:allowBackup="false"` in manifest — DB does not survive cloud restore
- **Contacts data:** emergency contacts stored inside the encrypted DB, not in shared prefs

### Map (offline)
- **Engine:** `flutter_map` + **raster MBTiles** via `flutter_map_mbtiles`
- **Tiles:** built externally on PC (tilemaker / OpenMapTiles), sideloaded into app's documents dir, managed by in-app regions screen
- **Initial region:** **UK only**; additional regions installable ad hoc
- **Default viewport:** fit bounding box of all pings in the currently selected time range
- **Paths:** pins only by default; line overlay available behind a toggle (at 4h intervals lines misrepresent actual travel)
- **Interim (shipped 0.1.9+10):** the home screen already runs `flutter_map` against OpenStreetMap's online raster tiles so users get an interactive, basemapped view today. Phase 4 swaps the `TileLayer` source for the MBTiles provider — the polyline/marker layers and gestures stay untouched.

### Reliability surfacing
- Home screen shows "last successful ping" timestamp prominently
- Heartbeat card turns red if `now - lastPingTs > 5h` (slight buffer past 4h cadence)
- `no_fix` rows so gaps are never silent

### Export
- GPX + CSV via share sheet. Notes included in GPX `<desc>` tag.

### Onboarding (first launch)
Full walkthrough:
1. Intro — what Trail does
2. Permissions — fine location, then background location education
3. Battery-optimization exemption prompt + `SCHEDULE_EXACT_ALARM`
4. Set emergency contacts (optional — can skip, add later)
5. Set home location (optional — used for "home radius" features if added later)
6. Enable biometric lock
7. Done

### Release / CI
- Match watchnext — every push to `main` auto-builds APK and publishes GitHub Release
- Fork watchnext's `.github/workflows/release.yml`, reuse pinned `DEBUG_KEYSTORE_B64` pattern for stable SHA-1. No `google-services.json` step (Trail uses no Google services).

## Repo

- GitHub: `https://github.com/DazedDingo/gps-pinger` (public)
- Local path: `/home/ubuntu/projects/gps-pinger`
- Stack: Flutter (Dart ^3.11), Riverpod, go_router — matches `watchnext` / `groceries-app`

## Directory / file structure

```
lib/
  main.dart
  app.dart                         # MaterialApp + router; dark theme default
  models/
    ping.dart                      # Ping data class + enum PingSource
    emergency_contact.dart
  db/
    database.dart                  # SQLCipher open + migrations
    ping_dao.dart                  # insert/query/paginate
    contact_dao.dart
    keystore_key.dart              # Keystore-backed DB key
  services/
    location_service.dart          # geolocator wrapper, scheduled + panic fetch
    battery_network_service.dart   # battery_plus + connectivity_plus snapshot
    cell_wifi_service.dart         # cell tower ID + Wi-Fi SSID (via plugin or MethodChannel)
    biometric_service.dart         # local_auth wrapper
    scheduler/
      workmanager_scheduler.dart   # PeriodicWorkRequest baseline
      alarm_scheduler.dart         # AlarmManager exact fallback (MethodChannel)
      scheduler.dart               # abstract + selection logic
    permissions_service.dart       # staged permission flow + battery-opt
    panic/
      panic_service.dart           # foreground service controller, continuous mode
      panic_share_builder.dart     # compose SMS text + recipients
    export/
      gpx_exporter.dart
      csv_exporter.dart
      archive_service.dart         # "archive older than X" flow
    tiles/
      mbtiles_source.dart          # flutter_map TileProvider backed by MBTiles
      region_manager.dart          # install/remove .mbtiles in app docs dir
  providers/                       # Riverpod: pingListProvider, lastPingProvider, healthProvider, contactsProvider
  screens/
    onboarding/                    # 7-step flow
    home_screen.dart               # last-ping card, heartbeat status, panic button
    history_screen.dart
    map_screen.dart                # flutter_map + ping pins + time slider + path toggle
    export_screen.dart
    archive_screen.dart
    regions_screen.dart
    contacts_screen.dart           # manage emergency contacts
    settings_screen.dart           # permissions, battery-opt, scheduler mode, panic duration, diag
  widgets/
    panic_button.dart              # reused in home + widget + quick-tile
android/
  app/src/main/kotlin/.../
    AlarmReceiver.kt               # exact-alarm fallback
    BootReceiver.kt                # triggers boot-row ping
    PanicQSTileService.kt          # quick-settings tile
    PanicWidgetProvider.kt         # home-screen widget
    PanicForegroundService.kt      # continuous panic + panic SMS intent
  app/src/main/AndroidManifest.xml
.github/workflows/release.yml
docs/
  PLAN.md                          # this file
  TILES.md                         # (Phase 3) tile build pipeline
```

## Plugin choices (Flutter 3.x)

- `geolocator` ^13
- `workmanager` ^0.5
- `sqflite_sqlcipher` ^3
- `flutter_secure_storage` ^9
- `local_auth` ^2 — biometric gate
- `permission_handler` ^11
- `battery_plus` ^6, `connectivity_plus` ^6
- `share_plus` ^10
- `flutter_local_notifications` ^17 — panic receipt + missed-heartbeat warnings
- `flutter_map` ^7 + `flutter_map_mbtiles` — offline raster tiles
- `home_widget` ^0.6 — home-screen widget bridging
- `path_provider`, `intl`, `package_info_plus`
- Riverpod ^2.5, go_router ^14
- Native Kotlin: quick-settings tile, widget, boot receiver, foreground service, cell/Wi-Fi info

## Phased milestones

### Phase 1 — MVP (logs + exports)
Scaffold, encrypted DB with Keystore key, `LocationService.getScheduledPing()` (includes heading/speed/battery/network/cell/Wi-Fi), `WorkManager` 4h PeriodicWorkRequest with retry-once-after-5min on no-fix, boot receiver logging `boot` row + triggering immediate ping, low-battery policy, home screen (last ping card + heartbeat + history list), GPX + CSV export via share sheet, staged permission flow, biometric gate on app open. Dark theme. **Demo:** install, onboard, grant permissions, see pings accumulate over a day, biometric unlocks app, export to GPX, open in OsmAnd.

### Phase 2 — Panic + emergency contacts ✅ (shipped 0.2.0+11)
Panic button on home + dedicated panic foreground service + continuous mode with configurable 15/30/60 min duration. Panic receipt notification. Emergency contacts screen (add/edit/delete contacts, stored in encrypted DB). Panic-share builder opens SMS app pre-filled with recipients and location text. **Demo:** hit panic, SMS app opens with contacts + maps link, continuous mode runs for chosen duration then auto-stops.

**Implementation notes:**
- Continuous mode uses the native FG service → WorkManager → Flutter dispatcher bridge (instead of a native DB write) so SQLCipher access stays in Dart and matches the scheduled-ping isolate model.
- `foregroundServiceType="location"` declared on the service; runtime `FOREGROUND_SERVICE_LOCATION` permission was already requested in Phase 1 staging.
- Duration preference persists in `flutter_secure_storage` under `trail_panic_duration_v1`, defaulting to 30 min.
- SMS hand-off uses `url_launcher` on an `sms:` URI with comma-joined recipients. No `SEND_SMS` permission ever requested — user taps Send in their own SMS app.

### Phase 3 — Quick-settings tile + home-screen widget
Native Kotlin quick-settings tile service and home-screen widget, both triggering panic via same foreground-service entry point. **Demo:** add widget, swipe down for tile, one-tap panic without opening the app.

### Phase 4 — Offline map
Raster MBTiles. Regions screen (install / delete `.mbtiles` via file picker). Map screen with pins, time slider, path-line toggle, bbox-fit default viewport. Document tile build pipeline in `docs/TILES.md`. **Demo:** install UK `.mbtiles`, open map with a month of pings plotted.

### Phase 5 — Scheduling hardening + archive
Add `AlarmManager.setExactAndAllowWhileIdle` path behind MethodChannel (`SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM`). Settings exposes WorkManager vs exact-alarm mode + last N scheduling events. Archive flow (export-and-delete older than X). **Demo:** toggle scheduler modes, compare punctuality over a week; archive a year of pings out to file and confirm DB shrunk.

### Phase 6 — Polish
Diagnostics screen (permission matrix, Doze state, last 20 worker runs), DB integrity check, date-range export filter, adaptive icon, heatmap overlay on map, home location feature if scoped.

## Architectural risks & mitigations

1. **Doze clustering** — PeriodicWorkRequest has no exactness guarantee. Mitigation: dual-path scheduling (Phase 5), visible heartbeat staleness, battery-opt exemption, `no_fix` rows.
2. **Cold GPS fix without A-GPS** can exceed 2 min. Mitigation: 2-min budget + retry-once-after-5min policy; log partial/failed attempts.
3. **Background-location grant friction** on Android 11+. Mitigation: onboarding screen explicit "Allow all the time" instruction, `permission_handler.openAppSettings()` deep link.
4. **Keystore key loss on backup restore** could brick DB. Mitigation: `allowBackup="false"`; also detect open failure and offer "reset DB" with warning.
5. **SQLCipher + WorkManager isolate**: background isolate must re-init plugin registry and re-open encrypted DB. Verify early in Phase 1.
6. **Panic foreground service Android 14+** — `foregroundServiceType="location"` now also needs `FOREGROUND_SERVICE_LOCATION` runtime permission. Handle in permission flow.
7. **Quick-settings tile + widget talking to Flutter isolate** — safest pattern is fire Android Intent to a foreground service in native Kotlin, which writes a `panic` ping directly via platform channel to Flutter isolate OR writes directly to the SQLCipher DB through a native binding. Decide this when Phase 3 starts; easiest MVP is native Kotlin writes a marker file, Flutter picks it up on next launch — but that breaks real-time panic. Revisit.
8. **Tile file size** — UK-wide raster MBTiles can be 200–600MB. Mitigation: regions screen lets user delete unused regions; don't bundle default tiles in APK.
9. **Cell tower / Wi-Fi SSID capture** — stock Android 12+ requires `ACCESS_FINE_LOCATION` + dedicated `NEARBY_WIFI_DEVICES` for Wi-Fi scan. Treat as optional field — if denied, just skip and log the rest.

## Testing strategy

- Unit-testable: GPX/CSV serializers, Ping/Contact models, DAO against in-memory SQLCipher DB, heartbeat-staleness logic, low-battery policy transitions, MBTiles tile-lookup, panic-share message builder.
- Mocked: `LocationService`, `BatteryNetworkService`, `CellWifiService` behind interfaces so providers/screens test without hardware.
- Manual-QA-only: WorkManager cadence (multi-day soak), AlarmManager exactness, permission dialogs, panic FG service, quick-tile + widget triggers, Doze behaviour (`adb shell dumpsys deviceidle force-idle`), biometric gate, live map rendering, SMS hand-off.

## Tile sourcing (Phase 4, one-time, on PC — not runtime)

- Download OpenStreetMap regional extract from Geofabrik (`great-britain-latest.osm.pbf`)
- Render to raster MBTiles with `tilemaker` using OpenMapTiles style, or use a pre-built raster MBTiles source
- Copy `.mbtiles` file to phone, install into app via regions screen
- Full pipeline in `docs/TILES.md` when Phase 4 starts

## Resolved items (previously open)

- Retention: forever with manual archive flow (answered — was Q13)
- Panic notification: visible for panic, silent for scheduled (answered — was Q14)
- Versioning: push-to-main auto-releases (answered — was Q15)
- Regions: UK now, others later (answered earlier)
- Encryption: yes, Keystore-derived, no user PIN (answered earlier)

## Still open (nothing blocking Phase 1)

- Accent colour / exact palette for dark theme — pick during Phase 1 scaffold
- Should onboarding "home location" step let user pick on a mini-map, or just store GPS at time of setup? Decide when building onboarding
- Quick-tile / widget → Flutter isolate IPC strategy — decide when Phase 3 starts (see risk #7)
