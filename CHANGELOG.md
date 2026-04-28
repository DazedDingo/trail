# Changelog

All notable changes to **Trail** are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) with the Android `versionCode+build` suffix.

## [0.10.5+69] — 2026-04-28

### Added
- **Live-location toggle on the map AppBar.** The Settings tile from 0.10.4+68 stays, but the most useful place to flip the dot is on the map itself — when a busy stretch of trail is hiding behind it. New action between the path-line toggle and Regions, with a `my_location` / `location_disabled` icon pair. Backed by the same `liveLocationDotEnabledProvider`, so both surfaces stay in sync.

## [0.10.4+68] — 2026-04-28

### Fixed
- **Heatmap crashed the app on toggle.** The rgba expression passed to `addHeatmapLayer` reads `scheme.tertiary.r/g/b.round()` — but in Flutter 3.27+ those getters are 0.0–1.0 doubles (the M3 colour overhaul), so `.round()` collapsed each channel to 0 or 1. The resulting expression was `rgba(0,0,1,0)` etc; maplibre-native's expression parser threw on it as soon as the first heatmap tile rendered. Now scaled to 0–255 before rounding.

### Added
- **Settings toggle: "Live location dot"** (Settings → Offline map → Live location dot). Disables maplibre_gl's native blue-dot indicator on the full-screen map for users who find the platform-rendered dot too prominent at high-DPI / zoom 14+. Default on (matches every prior build). The trail logger and every other location flow are unaffected — only the dot is hidden.

### Changed
- **Head pin is now vivid red (`#FF1744`) at radius 11.** The prior `scheme.tertiary` derived a muted warm tone from the teal seed and washed out against the small primary-tinted earlier pins. A fixed Material Red Accent 400 reads cleanly against any tile palette. The HUD's "Now" legend dot matches.

## [0.10.3+67] — 2026-04-28

### Fixed
- **"Previous" pin was indistinguishable from earlier pins.** The 0.10.2+66 styling used `scheme.secondary` at radius 6 — but secondary in the Material 3 dark theme derives from the same teal seed as primary, so it read as just-another-small-circle. The previous fix is now a hollow amber ring (radius 10, transparent fill, thick `#FFB300` stroke) — a warm-tone outline that pops against both the teal small pins and the tertiary-tinted head. The HUD's "Prev" dot uses the same amber so the legend matches.
- **Backward slider drag left the path line at its full pre-drag length.** Two compounding bugs. (1) Rapid slider drags fired `_refreshAnnotations` on every onChanged event, so 5+ refreshes ran concurrently and raced on the shared `_renderedCircles` list — the line update from one call was overwritten by an in-flight remove from another, leaving the geometry stale. New single-flight wrapper (`_scheduleRefresh` + `_runRefreshLoop`) collapses bursts into "current run + at most one pending"; the loop drains it once and exits. (2) maplibre_gl's `updateLine` → `setGeoJsonFeature` path on Android annotations didn't reliably redraw on geometry shrinkage. Brute-force fix on the backward path: `removeLine` + `addLine` rather than `updateLine`. One extra platform call per backward step but the line now visibly shrinks in lock-step with the slider.

## [0.10.2+66] — 2026-04-28

### Added
- **Playback HUD: "Now" and "Prev" timestamps in the top-left of the map.** Translucent badge with a tertiary-tinted dot for the head fix and a secondary-tinted dot for the previous one, alongside the gap between them (`30m`, `2h 15m`, `3d`). Updates on every slider drag and every playback tick — useful when fast playback blurs which fix is current vs. just-passed.
- **Distinct "previous" pin styling on the map.** The fix immediately before the head now renders as a medium secondary-tinted circle (radius 6) instead of the standard small primary one. At a glance you can see which way you've just come from, especially during fast playback.
- **Slider drag is now incrementally rendered in both directions.** The 0.10.1+65 fix only short-circuited forward steps; backward drag still fell through to the full clear+rebuild path. Now backward drag pops trailing circles via `removeCircle` and re-promotes the new tail to head + previous styles in place. Drag-back at hundreds of fixes is as smooth as drag-forward.

## [0.10.1+65] — 2026-04-28

### Fixed
- **Map playback was choppy with hundreds of fixes.** `_refreshAnnotations` always cleared every line + circle and re-added them on each playback tick — N+3 platform-channel calls per tick where N = visible fix count. At 30-min cadence on a busy day that's hundreds of calls per 350 ms, more than the maplibre_gl annotation pipeline could process. Now the path-mode renderer keeps refs to the line + head-circle and short-circuits to an *incremental* update on forward-only slider advances: demote old head to small (1 call), add new circles for any intermediate fixes (≥0 calls), add new head (1 call), `updateLine` with the new geometry (1 call). Three calls per tick at 1× speed, regardless of how many fixes are visible. Falls back to the old clear+rebuild on render-key changes (filter, heatmap toggle, path toggle, region swap) or backward steps.
- **"Top places" listed the same city repeatedly.** The 1 km bucketing in `StatsService.topPlaces` is finer than the system geocoder's locality resolution, so a single city like Bristol resolved to the same label across 5+ buckets. New `topPlacesProvider` over-fetches 30 buckets, geocodes them in parallel, then merges buckets sharing a label (sums counts, keeps the larger contributor's centroid as the pin location). Returns the top 10 deduped places. Buckets with no geocoder label are kept unmerged — coords don't look duplicated.

## [0.10.0+64] — 2026-04-28

### Added
- **Stats screen** (Settings → Insights → Stats). Four derived views over the existing ping history, no schema change:
  - **Calendar heatmap** — 12 weeks × 7 days of pings-per-local-day, GitHub-style intensity. Tap a day → opens the full map filtered to that day.
  - **Top places** — pings bucketed on a ~1 km lat/lon grid, ranked by visit count, reverse-geocoded for a "Cambridge, England" label where the system geocoder cooperates.
  - **Time of day** — 24-hour radial chart showing when in the day successful fixes happen, local time. `no_fix` rows are excluded so a phone with motion-aware-skip on still shows a useful pattern instead of a flat ring of stationary skips. Peak-hour summary line.
  - **Trips** — automatic detection of stretches > 10 km from home for ≥ 6 h. Each trip card shows date span, max distance, ping count; tap to open the map filtered to the trip window.
- **Map screen accepts an `initialFilter` extra.** `context.push('/map', extra: DateTimeRange(...))` opens the map with that filter pre-applied — used by the stats screen's heatmap and trip cards. Existing nav paths still pass `null` and behave as before.

## [0.9.6+63] — 2026-04-27

### Changed
- **Encrypted export switched from `TRLENC01` to a standard AES-256 zip.** The previous format required a Python decrypt script — too much friction. Now the toggle produces a single `trail_export_<ts>.zip` containing every GPX/CSV in the run, AES-256 encrypted via zip4j on the native side (new `EncryptedZipPlugin` Kotlin MethodChannel + `net.lingala.zip4j:zip4j:2.11.5`). Opens directly with 7-Zip, macOS Archive Utility, or Linux `7z x` — no Trail-specific tooling on the recipient side. Plaintext temp files are still best-effort deleted after the zip is built. `docs/decrypt-export.py` removed.

## [0.9.5+62] — 2026-04-28

### Added
- **Encrypted export with passphrase.** New "Encrypt with passphrase" toggle in the export dialog. Each GPX/CSV exported in this run is wrapped in a `TRLENC01`-tagged AES-256-GCM blob with a PBKDF2-HMAC-SHA256-derived key (210 000 iterations, same work factor as the SQLCipher passphrase mode). Format: `magic[8] || salt[16] || nonce[12] || ciphertext || gcmTag[16]`. Plaintext temp files are best-effort deleted after encryption. The companion `docs/decrypt-export.py` (depends on Python's `cryptography` package) reverses the format with `python decrypt-export.py file.gpx.enc` — passphrase prompted on stdin.

## [0.9.4+61] — 2026-04-28

### Changed
- **Lazy ping pagination via SQL-side date filtering.** `PingDao.byDateRange` and the new `pingsByRangeProvider` family take a `DateTimeRange?` and run a `WHERE ts_utc BETWEEN ? AND ?` at the SQL layer. The map screen now reads from this provider; when a filter is active, the round-trip is proportional to the filter window rather than the full `pings` table. With `null` range it falls through to `dao.all()` so the unfiltered view's behaviour is unchanged. The slider, playback re-arm, and refresh paths all honour the same filter so swapping the active range stays consistent.

## [0.9.3+60] — 2026-04-28

### Added
- **Motion-aware skip mode** (Settings → Scheduling → Motion-aware skipping; off by default). When the periodic worker fires, if the two most-recent fixes are within 50 m of each other AND the newest is < 2 h old, the worker logs a `no_fix` row with note `motion-aware skip (Xm, Ym old)` and skips the GPS warm-up entirely. GPS warm-up is the most expensive part of every periodic tick, so on a stationary day at home you skip the bulk of the cost; the next real fix is forced after 2 h of consecutive skips so a slow drift can't go undetected. Manual "Run ping now" and the no-fix retry path are unaffected — only the periodic 4 h / 30 min worker is allowed to skip.

## [0.9.2+59] — 2026-04-28

### Added
- **Tap a ping marker → bottom sheet with the row's full detail.** `MapLibreMapController.onCircleTapped` is now subscribed; each rendered Circle is recorded against its underlying Ping in `_circleToPing`, and a tap pops a sheet showing timestamp, lat/lon, accuracy, altitude, speed, battery, network state, cell ID, Wi-Fi SSID, source, and note. Heatmap circles are not in the mapping (different code path), so taps there silently do nothing.
- **Real `HeatmapStyleLayer` for heatmap mode.** Replaces the per-ping CircleLayer fudge with a proper `addHeatmapLayer` driven by a GeoJSON source — density-weighted Gaussian blending, tertiary-tinted gradient over a transparent base, scales to thousands of fixes without thousands of platform-side annotations. Mounted lazily; toggling off cleanly removes both the source and the layer.
- **Pinch-zoom map picker for the "Custom area" build flow.** `BboxPickerScreen` mounts a `MapLibreMap` at the active region's style with a centre crosshair and a "Use this area" button; tapping captures `getVisibleRegion` and pops with a `minLon,minLat,maxLon,maxLat` string. The Custom area dialog now has a tonal map-icon button next to the bbox text field that launches the picker — bypasses the bboxfinder.com round-trip entirely.

## [0.9.1+58] — 2026-04-28

### Fixed
- **Home-screen mini-map went white in `0.9.0+56`.** Two changes from that build interact badly with maplibre_gl's Android platform view inside a small (180 px) widget: turning on `myLocationEnabled` and the parent `Container`'s `clipBehavior: Clip.antiAlias` (rounded-corner clip on a platform view forces an off-the-default composition path that, on the small home preview, left the render surface blank). Both are off on the mini view now — clipping is gone (the rounded background decoration still draws, the map's square edges sit inside it, visually fine), and the live-location dot stays only on the full-screen map where it's more useful anyway.

## [0.9.1+57] — 2026-04-28

### Added
- **Explicit date-range filter on the full-screen map.** New calendar icon in the app bar opens a `showDateRangePicker` bounded to your actual ping history. Picking a range hides every fix outside the window — the time slider's first/last clamp to the window, the bbox-fit reframes to the filtered subset, and a banner above the slider shows `Filter: Apr 18 – Apr 25` with a one-tap Clear. Empty range gets its own empty-state.
- **In-process LRU cache for served tiles.** `LocalTileServer` keeps the last ~50 MB of decompressed tile blobs in a `LinkedHashMap` (insertion order = LRU order). Repeat panning over the same viewport now skips the SQLite query + gunzip on every hit. Diagnostic's `lastTile` line marks `cached` for cache-served responses. Cleared on every `stop()` so a region swap can never serve a stale tile.
- **Long Cache-Control on tile / glyph / sprite responses** (`public, max-age=31536000, immutable`). Each app launch picks a fresh random server port, so the URL itself is effectively a new origin per session — caching forever within a session is safe and lets MapLibre's OkHttp cache skip revalidation. Was `no-cache` before.

### Changed
- **Encrypted DB now opens in WAL journal mode** (`PRAGMA journal_mode=WAL` in `onOpen`). SQLCipher 3+ supports it. Lets the WorkManager worker's per-tick insert run concurrently with UI reads on the same path instead of serialising them. Idempotent on every open; no schema change.

## [0.9.0+56] — 2026-04-28

### Added
- **Live "you are here" indicator on both maps.** maplibre_gl's native blue-dot location source is now enabled on the home-screen trail preview and the full-screen history map (`myLocationEnabled: true`, tracking mode `none` so it doesn't auto-pan — you're reviewing history, not navigating). No new permissions needed; uses Trail's existing fine-location grant. Position is live and unsaved — there's no DB write, the indicator just reflects whatever Android's FusedLocationProvider currently has.

### Changed
- **Curated regions now build at z14 by default.** The earlier z13 presets duplicated the GB-wide z13 file you already have installed. z14 unlocks footpath / fence / wall / building-outline detail you can't get from the GB tileset (which doesn't fit in a Releases asset at z14), so the catalog is now genuinely additive. Approximate sizes scaled ~2.5× — Lake District ~125 MB, Cairngorms ~200 MB, Cotswolds ~175 MB; smallest (Dartmoor / Exmoor / Northumberland / New Forest) ~60 MB. All comfortably fit GitHub's 2 GB per-asset Release cap.

## [0.8.3+55] — 2026-04-28

### Fixed
- **AppBar back arrows landed on the wrong screen.** Every back button used `context.go('/parent')`, which *replaces* the GoRouter stack with the destination — so `/home → /map → tap Regions icon → back` landed on `/settings` instead of `/map`, and any deep-nested screen lost its history. Switched the leading arrows on Map / Settings / Regions / Archive / Diagnostics / Home-location to `context.pop()` (with a fallback to the natural parent route only when nothing's on the stack), and changed the Map screen's Regions actions icon from `go` to `push` so it nests under `/map` rather than wiping the stack.

## [0.8.3+54] — 2026-04-28

### Fixed
- **Full-map playback paused spuriously around duplicate timestamps.** `_stepTo` pivoted on the first ping with `ts >= current`, which returned a duplicate's own timestamp when two pings shared an exact `ts_utc` (panic burst, same-ms retry). The playback timer's `next.isAfter(current)` stop guard then fired and the user had to drag the slider past the dupe to resume. Now pivots on the **last** index ≤ `current`, so a forward step always lands on a strictly later index. Extracted to a top-level `stepSliderTo` so the regression is unit-tested (5 new tests, including a 5-deep duplicate-run case).

## [0.8.3+53] — 2026-04-28

### Changed
- **"Build a region" UX rebuilt around a preset list of UK national parks and AONBs.** Bbox / zoom / area is exactly the wrong vocabulary for a hiking app — the "Build a region" entry now opens a tappable list of 15 UK national parks and AONBs (Lake District, Snowdonia, Peak District, Dartmoor, Cairngorms, Cotswolds, etc.) with each row showing the region's parent county and the approximate file size at zoom 13. Tap a row → confirm dialog → build dispatched. The bbox form moves behind a "Custom area…" tail entry with a hint pointing at bboxfinder.com and a "Detail level" dropdown that explains each zoom (`13 — streets + tracks (recommended)`).

## [0.8.3+52] — 2026-04-28

### Added
- **On-demand region builds via GitHub Actions.** New `.github/workflows/build-region.yml` accepts `workflow_dispatch` inputs (name, bbox, max zoom, OSM area, optional description), runs planetiler against the requested area, uploads the MBTiles as an asset on the `tilesets-v1` release, and commits a corresponding entry into `docs/tilesets.json` so the curated catalog picks it up automatically. Free for public repos (unlimited Actions minutes); typical small-area builds finish in ~5–15 min.
- **App-side trigger.** Regions screen's "Add region" sheet now has a "Build a region" entry. Form takes name, bbox (`minLon,minLat,maxLon,maxLat`), zoom (10–14), OSM area (GB / Ireland / Europe), and an optional description. Submitting fires `POST /actions/workflows/build-region.yml/dispatches` against `DazedDingo/trail`.
- **Settings → GitHub token.** Personal Access Token storage in flutter_secure_storage (`trail_github_pat_v1` key, same Keystore-backed encryption as the SQLCipher key). Tile shows `Set: ghp_…last4 · Verified as @login` when configured. Save calls `/user` to verify the token's scopes before persisting; a known-bad token is wiped from storage rather than silently stranded. Classic `public_repo` or fine-grained `Actions: Read & write` is enough.

## [0.8.2+51] — 2026-04-28

### Added
- **In-app region download — from URL or curated catalog.** The Regions screen's "Add region" FAB now opens a sheet with three sources: pick an existing file (the previous behaviour), download from a direct URL, or browse the curated catalog. URL downloads stream into `<docs>/tiles/<filename>` with a cancellable progress dialog and an atomic `.partial → .mbtiles` rename so a killed app never leaves a stale half-file. The catalog reads `docs/tilesets.json` from the GitHub `main` branch (currently empty — populated as regions get built); each entry shows name, description, and file size, and tapping it kicks off a download with the same UI as the URL flow. After install a SnackBar offers a one-tap "Set active". `TileDownloader` and `TileCatalog` are split out as standalone services for future reuse.

## [0.8.1+50] — 2026-04-28

The renderer migration is finally settled — 0.8.1 is the first build of the rewrite the user has been able to actually use.

### Fixed
- **`@2x` sprite 404s.** The `LocalTileServer` regex was capturing the file extension into the wrong group, so `/sprites/osm-liberty@2x.json` and `.png` requests built an asset key without the extension and 404'd. Group accounting fixed; the user's log capture in +49 surfaced this immediately.
- **Glyph range U+2000-U+20FF (General Punctuation) was missing.** Some UK place labels reference characters in this block (en/em dashes, primes); maplibre-native logged a 404 per affected font stack. Bundled `8192-8447.pbf` for Roboto Regular / Medium / Condensed Italic.

### Removed
- **Diagnostic overlay on the home-screen trail preview.** Now that the renderer works, the bottom-left attribution strip goes back to the simple `Offline: <name> · © OpenMapTiles © OSM contributors` line. The supporting plumbing (`MapLibreLogTrap`, `LocalTileServer.tileRequestCount`/`lastTileStatus`, `MapLibreLogReader`) stays — zero runtime cost when nothing reads it, and worth keeping around for the next time something on the renderer side breaks.

## [0.8.0+49] — 2026-04-28

### Fixed
- **Glyphs + sprites served over the same loopback HTTP server.** `+48`'s log capture caught the smoking gun: maplibre-native logs `Failed to load glyph range 0-255 for font stack Roboto Regular: ( Could not read asset)` (and the same for Medium and Condensed Italic) — `asset://flutter_assets/...` URLs are unreachable from maplibre's Android asset source. The renderer then cancels every in-flight tile request (HTTP "Canceled" / "Socket closed" warnings in the same log) and shows nothing. `LocalTileServer` now also handles `/glyphs/<fontstack>/<range>.pbf` and `/sprites/osm-liberty(@2x)?(.json|.png)?`, reading from `rootBundle`. Bundled style placeholders `__TRAIL_GLYPHS__` and `__TRAIL_SPRITE__` rewrite to loopback URLs at runtime, same way `__TRAIL_ACTIVE_REGION__` already did.

## [0.8.0+48] — 2026-04-28

### Fixed
- **+47 didn't build:** `MapLibreLogTrap.kt` couldn't see `org.maplibre.android.log.{Logger,LoggerDefinition}` because maplibre_gl declares the underlying maplibre-native AAR as `implementation`, not `api`. Added a `compileOnly` declaration in `android/app/build.gradle.kts` so the app module's Kotlin can reference the classes; runtime resolution still goes through maplibre_gl plus the existing 13.0.3-pre0 override.

## [0.8.0+47] — 2026-04-28

### Added
- **In-app maplibre-native log capture.** `MapLibreLogTrap.kt` registers a `LoggerDefinition` with maplibre-native at startup that mirrors every log entry into a 200-line process-local ring buffer (and still calls through to `android.util.Log` so logcat works for adb-equipped users). A `MethodChannel` (`com.dazeddingo.trail/maplibre_logs`) exposes the buffer to Flutter; the home-screen diagnostic overlay polls it every 2s and shows the last 3 lines inline. Tapping the overlay copies the full diagnostic + log buffer to the clipboard. Long-press still re-pings the tile server. The inline log lines are `SelectableText` so individual messages can be copied without grabbing the whole dump.

## [0.8.0+46] — 2026-04-28

### Changed
- **Switch the openmaptiles source from `url:` (TileJSON) to `tiles:[]` (URL template).** Bypasses the TileJSON round-trip step entirely; MapLibre fetches MVT directly. Same delivery shape the renderer uses for any vector-tile URL — and the closest match to what worked in the +35 remote-PMTiles diagnostic. The bundled style now declares `minzoom: 0, maxzoom: 13, scheme: xyz` directly on the source.
- **Tile Content-Type → `application/vnd.mapbox-vector-tile`.** The Mapbox-spec MIME for MVT; some maplibre-native paths key on this exact type for vector parsing.

## [0.8.0+45] — 2026-04-28

### Fixed
- **Tile delivery: third combination — `Content-Encoding: gzip` + gzipped body.** `+40` (Content-Encoding + gzipped body, with sqflite singleInstance still on its broken default) and `+44` (no header + decompressed body) both rendered white. With the `+43` singleInstance fix in place, the +40 shape — which is the standard "remote vector tile over HTTP" delivery OkHttp is built for — should be the cleanest match for what the renderer wants. Server now declares `Content-Encoding: gzip`, ships the bytes verbatim from MBTiles; OkHttp on Android transparently decompresses and the MVT parser sees plain bytes.
- The `lastTile` diagnostic now also prints the first 8 raw bytes of the served blob, so we can spot if the tile_data is something other than gzipped MVT (`1f8b08…` = gzip magic).

## [0.8.0+44] — 2026-04-28

### Fixed
- **Server-side gunzip of MVT tiles.** With `+43`'s diagnostic showing 200 OK + 138 KB tile blobs reaching MapLibre, the renderer was still drawing nothing. Both Content-Encoding settings tried in `+40`/`+42` failed: with `Content-Encoding: gzip` OkHttp transparently decompressed but maplibre-native double-decompressed the result; without the header maplibre-native didn't auto-detect gzip from the magic bytes (despite the spec saying it should). `LocalTileServer` now decompresses on the server and ships plain MVT bytes — what maplibre's MVT parser expects unconditionally. The `lastTile` line in the diagnostic now reads `<compressed>→<decompressed>B` so the gunzip is visible.

## [0.8.0+43] — 2026-04-28

### Fixed
- **"database is closed" on the home / map screen.** The encrypted Trail DB and the WorkManager worker were both opening with sqflite's default `singleInstance: true`, which makes the platform plugin return the *same* native handle across isolates. The 4h worker would tick in the background, do its work, and `close()` in a `finally` — and that close tore down the UI isolate's `_shared` handle out from under it; the next `recentPingsProvider` query then surfaced as a database error card. All `openDatabase` calls in `database.dart` and `local_tile_server.dart` now pass `singleInstance: false`, so each isolate gets its own native handle and close-in-worker can no longer affect the UI. CLAUDE.md gotcha #1 was already aware of this in spirit; the code finally agrees.

## [0.8.0+42] — 2026-04-28

### Fixed
- **Drop `Content-Encoding: gzip` from tile responses.** OkHttp on Android transparently decompresses gzipped responses; maplibre-native then sniffs gzip magic on the *already-decompressed* bytes and fails to parse — silent white tiles. Sending the raw gzipped bytes without the header keeps OkHttp's hands off and lets the renderer decompress once.

### Added
- **Tile-request counters in the diagnostic overlay.** Two new fields: `tileReqs` (cumulative count of /{z}/{x}/{y}.pbf hits since server start) and `lastTile` (z/x/y + status of the most recent request). Refreshes every 2s. Lets us tell apart "MapLibre never tried" from "MapLibre asked, server answered, renderer still rejected."

## [0.8.0+41] — 2026-04-27

### Added
- **Tile-server self-test in the diagnostic overlay.** Two new fields: `port` (`LocalTileServer.instance.port`, or "off") and `serverPing` (Dart-side HTTP fetch of `/tilejson.json` from the loopback — shows `<status> (<bytes>B)` when reachable, `fail: <reason>` otherwise). Long-press the overlay to retest. Lets us tell apart "server didn't start" / "server up but MapLibre can't reach it" / "MapLibre reaches it but tiles still don't render".

## [0.8.0+40] — 2026-04-28

### Added
- **In-app localhost HTTP server for MBTiles tiles.** Working around the maplibre-native 13.0.x bug where local-file tile URLs (`mbtiles://file://`, `pmtiles://file://`) silently fail to render on Android even when the file is present and the style parses. `LocalTileServer` opens the active `.mbtiles` read-only via sqflite, binds an HTTP listener on `127.0.0.1` at a random port, and serves `/tilejson.json` and `/{z}/{x}/{y}.pbf` (with the TMS→XYZ y-flip baked into the handler). MapLibre fetches as a regular remote vector source — the path we already proved works in 0.8.0+35's diagnostic mode. AndroidManifest gets a `network_security_config.xml` that whitelists cleartext HTTP for `127.0.0.1` and `localhost` only; everything else stays HTTPS-only.

## [0.8.0+39] — 2026-04-27

### Changed
- Pin the maplibre-native Android SDK to `13.0.3-pre0` (the only version newer than the broken-locally `13.0.2`) via a gradle resolution-strategy override on top of `maplibre_gl 0.26.0`'s default `13.0.+`. Last roll of the dice on a native fix before falling through to the in-app localhost HTTP-server workaround.

## [0.8.0+38] — 2026-04-27

### Changed
- **Renderer plugin swap: `maplibre` 0.3.5 → `maplibre_gl` 0.26.0.** The newer `maplibre` package's local-file URL pipeline on Android silently dropped tile fetches for both `.pmtiles` and `.mbtiles` (verified across +30, +33, +34, +35, +37 with the diagnostic overlay — file present, style loaded, `cameraIdle` fired, but the canvas stayed blank). Remote URLs worked, confirming the bug was specifically the plugin's local-file bridge. `maplibre_gl` is the older mapbox_gl-derived community plugin with documented PMTiles + MBTiles examples and a different JNI codebase. Different API: imperative controller annotations (`addLine`, `addCircle`) instead of declarative `layers:`. Trail preview and full-screen map both rewritten against the new package.

## [0.8.0+37] — 2026-04-27

### Added
- **MBTiles support alongside PMTiles.** The Regions screen file picker now accepts both `.mbtiles` and `.pmtiles` files, and `TrailStyle` picks the right URL scheme per extension (`mbtiles:///<path>` vs `pmtiles://file://<path>`). Added because the +35 diagnostic confirmed maplibre 0.3.5 *can* render PMTiles on Android, but only over HTTPS — local-file PMTiles silently 404s. MBTiles is the older, more battle-tested path through MapLibre Native and works for the same data with a different file format. Planetiler emits MBTiles directly; same `--maxzoom`, same OpenMapTiles schema, slightly larger file.

## [0.8.0+36] — 2026-04-27

### Changed
- Diagnostic overlay on the home-screen trail preview is now tap-to-copy. Tapping the panel writes `last: …, fileExists: …, path: <full path>` to the clipboard and surfaces a brief "copied" SnackBar — easier than reading and spelling out the path on a phone.

## [0.8.0+35] — 2026-04-27

### Added
- **Map renderer diagnostic mode.** The Regions screen now has a bug-icon button in the app bar that flips the active region to a synthetic "remote demo" entry — the next map render uses the public Protomaps demo PMTiles over HTTPS instead of the local file. Lets us tell whether the renderer is broken vs whether local-file PMTiles is broken in the maplibre 0.3.5 Android plugin without writing native code. Tap any installed region tile to leave diagnostic mode.

## [0.8.0+34] — 2026-04-27

### Changed
- Diagnostic overlay rewritten to stack each field on its own line at fontSize 12 instead of cramming everything onto a single fontSize-10 line that clipped off the right edge on a phone. Same content (`last:`, `fileExists:`, `tail:`).

## [0.8.0+33] — 2026-04-27

### Added
- **Beefier white-map diagnostic.** The home-screen overlay now also shows whether the active region's file actually exists on disk and the tail of its path, alongside the last MapLibre event. Lets us spot a wrong path or unreadable file without adb. The earlier compression-mismatch theory turned out to be a wrong byte-mapping on my end — the file is GZIP-compressed, which MapLibre supports.

## [0.8.0+32] — 2026-04-27

### Changed
- **Each push now gets its own GitHub release.** The release workflow used to tag every build under `v<SemVer>` and overwrite the same `Trail-v<SemVer>.apk`, so successive build bumps couldn't be told apart from the release page (the only place the build number was visible was Settings → App version). Tags now include the build number — `v0.8.0-32` — and asset filenames follow suit: `Trail-v0.8.0-32.apk`. Older releases and the previously-shared `v0.8.0` tag stay where they are.

## [0.8.0+31] — 2026-04-27

### Fixed
- **Style asset paths inside the bundled `style.json` were missing the `flutter_assets/` prefix.** Flutter packages every pubspec asset into the APK at `assets/flutter_assets/<key>`, but maplibre-native Android's `asset://` resolver reads paths relative to `<APK>/assets/`. Glyph and sprite URLs now use `asset://flutter_assets/assets/maptiles/...`. This was a strong candidate for the lingering "white map" report on top of the +30 PMTiles URL fix.

### Added
- **Diagnostic overlay on the home-screen trail preview.** The bottom-left attribution strip now appends `last: <event>` showing the most recent MapLibre map event — `mapCreated`, `styleLoaded`, `cameraIdle`, etc. If the map renders white, the last event reveals whether the style ever loaded (vs tiles failing afterwards). Will be removed once the renderer settles in production.

## [0.8.0+30] — 2026-04-27

### Fixed
- **PMTiles map renders white on Android.** 0.8.0+29 built the source URL as `pmtiles://<path>`, but MapLibre Native Android requires `pmtiles://file://<path>` for local files — the bare form silently fails and the map shows only the OSM Liberty cream-white background. Added a regression test pinning the URL format so this can't recur.

## [0.8.0+29] — 2026-04-27

Same payload as the (mis-numbered) 0.7.2+28 build — relabelled as a
minor bump because the renderer swap is too big to live under a patch
version, and old `.mbtiles` files are unreadable by the new code.

### Changed
- **Map renderer cutover: vector PMTiles via MapLibre** (Phase 7). The home-screen trail preview and the full-screen history map now render vector tiles from sideloaded `.pmtiles` files, replacing the previous raster `.mbtiles` path. Vector tiles are 5–10× smaller for the same coverage and produce smoother labels and lines at all zooms. The Regions screen file picker now accepts `.pmtiles`; the storage directory moved from `<docs>/mbtiles/` to `<docs>/tiles/`. The active-region preference key was reset deliberately — old `.mbtiles` files can't be read by the new renderer, so the active selection clears on first launch and you reinstall the region.
- **No more online OSM fallback.** Without an active region, the map screen shows an "install a region" prompt rather than streaming raster tiles from openstreetmap.org. Trail's design has been offline-only since Phase 1; the tile fallback was an inconsistent leftover.

### Removed
- `flutter_map`, `flutter_map_mbtiles`, `latlong2`, `polylabel`, and a handful of transitive map deps. `maplibre` covers the whole rendering layer now.
- The custom 0.001°-grid heatmap bucketing in `map_screen.dart`. Heatmap mode now renders one blurred translucent CircleLayer over every fix and lets overlapping circles produce the hot spots — handles 10k+ pings on the GPU without re-bucketing on pan.

## [0.7.2+27] — 2026-04-27

### Added
- **MapLibre + PMTiles foundation** (Phase 7, in progress). The `maplibre` package and a bundled OSM Liberty style — style JSON + sprites + Roboto glyph PBFs, ~1.2 MB total — are now in the build, ahead of the widget swap. App still uses `flutter_map` + raster MBTiles for now; the renderer cutover lands in the next release.

## [0.7.1+26] — 2026-04-27

### Changed
- GitHub repository renamed from `DazedDingo/gps-pinger` to `DazedDingo/trail` to match the app and local directory. The old URL still redirects, so existing clones and Release downloads keep working.

## [0.7.1+25] — 2026-04-27

### Changed
- Project naming consistency: README, CHANGELOG header, and PLAN now refer to the project as **Trail** rather than the historical `gps-pinger` working title. Local working directory renamed to `trail/`. App behaviour, package id, and signing identity are unchanged.

## [0.7.1+24] — 2026-04-20

### Fixed

- **"Use last successful fix" on the home-location screen no longer
  throws a DB error.** The handler opened a second SQLCipher connection
  via `TrailDatabase.shared()` + `PingDao(db).latestSuccessful()` on
  tap, which — on fresh installs where the home-location screen is one
  of the first places a user navigates after onboarding — raced the UI
  isolate's Keystore key derivation and surfaced as a generic "database
  exception." This is the same 0.1.3 race pattern the home-screen
  providers already dodge; the fix routes through
  `ref.read(lastSuccessfulPingProvider.future)` so the shared,
  memoised handle is the only one in play.

### Changed

- **Home screen layout: only the "Recent pings" list scrolls.** Before
  0.7.1+24 the whole home screen was one `ListView`, so the last-ping
  card + panic button + summary + map preview would all slide off the
  top as the user scrolled through history. The top block is now
  pinned in a `Column`, and the recent-pings list lives in an
  `Expanded(ListView.builder)` — the heartbeat + hold-to-panic button
  are always visible while the user scrolls. The map preview was
  reduced from 260 → 180 px to fit the new pinned layout without
  pushing recent pings off-screen on small devices. Empty-state and
  error-state branches use `AlwaysScrollableScrollPhysics` so
  pull-to-refresh still works on a fresh install with no rows.
- **Recent-ping tiles now show the reverse-geocoded location.** Each
  tile renders the approximate place name ("Cambridge, MA") above the
  timestamp when the system geocoder has data for the coordinate,
  matching the pattern already used on the History screen's full
  tiles. Silent when the geocoder returns null — offline gaps don't
  clutter the list. `_PingTile` was converted from `StatelessWidget`
  to `ConsumerWidget` to watch `approxLocationProvider` per row;
  repeated pings at the same spot hit the provider family's cache.

### Added

- **Trail-map playback controls.** The Phase 4 time slider now sits
  above a row of playback buttons: jump-to-start, step-previous,
  play/pause, step-next, and a 1× / 2× / 4× / 8× / 16× speed cycle.
  Playback advances `_sliderMax` one fix at a time via a
  `Timer.periodic`, so each ping is visible for the same fraction of
  the animation regardless of gaps between fixes — a walk + an
  overnight sleep + a drive render proportionally in the playback
  even though the raw timestamps span very different durations.
  At 1× speed each step is ~350 ms (so 42 weekly pings play in
  ~15 s); 16× collapses the same range to ~1 s for quick "how did
  I move today" scrubbing. Any direct slider drag or step press
  pauses playback, and reaching the last fix auto-pauses. Tapping
  play when already at the last fix rewinds to the first fix first,
  so "play" is never a no-op.

## [0.7.0+23] — 2026-04-20

### Added

- **User-configurable ping cadence (Settings → Scheduling → Cadence).**
  The 4h interval between scheduled pings is now a picker with
  `30 min / 1 h / 2 h / 4 h` options (default still 4h, preserving
  pre-0.7 behaviour). Each step below 4h roughly doubles the per-day
  GPS-fix count and battery cost; the subtitle on the tile calls
  that out explicitly so the user doesn't pick 30 min expecting free
  precision. 15 min was considered and dropped — Doze + OEM throttling
  routinely stretches short WorkManager cadences on restrictive
  devices, so the "precision" benefit only lands in exact-alarm mode
  and isn't worth the floor-case battery drain. Implementation spans
  a new `PingCadence` enum in `scheduler_policy.dart`, a `CadenceStore`
  backed by `SharedPreferences` (cross-isolate-safe so the background
  worker reads the same value the UI writes), an `AsyncNotifier`
  provider, and native plumbing through `SchedulerPrefs` /
  `SchedulerMethodChannel` / `ExactAlarmScheduler` so exact-alarm
  mode respects the user's cadence even after reboot before the
  Flutter UI has run. Changing the cadence kicks the active driver
  immediately (re-enqueues the WorkManager periodic task, or cancels
  and re-arms the pending exact alarm) so the new value lands without
  waiting for the current window to expire. Battery-saver logic is
  preserved: `SchedulerPolicy.nextCadence` now takes an optional
  `base:` parameter so `<20%` battery still doubles whatever cadence
  the user picked (e.g. 30 min → 1 h, 2 h → 4 h), and `<5%` still
  skips entirely. Test suite grew a `PingCadence enum` group plus
  low-battery invariants that loop every cadence value.

## [0.6.7+22] — 2026-04-20

### Changed

- **GitHub Releases now carry their CHANGELOG section as the body.**
  The release workflow previously created each GitHub Release with
  only a tag + name and no description, so anyone visiting the
  Releases page saw empty bodies for every version. CI now extracts
  the `## [vX.Y.Z+N]` section from `CHANGELOG.md` into
  `release_notes.md` at build time (via a literal-prefix `awk` pass —
  the `+` in version strings breaks naive regex matching) and passes
  it to `softprops/action-gh-release` as `body_path`. Bodies for
  already-published 0.6.2+17 through 0.6.6+21 releases were backfilled
  manually via `gh release edit`.

## [0.6.6+21] — 2026-04-20

### Fixed

- **Settings back button points to `/home` instead of `/`.** The
  0.6.5+20 back button fix used `context.go('/')`, but the router
  has no `/` route — home is registered at `/home` — so tapping back
  threw `GoException: no routes for location: /`. Corrected to
  `context.go('/home')`.

## [0.6.5+20] — 2026-04-20

### Fixed

- **Settings screen now has a back button.** The `AppBar` was missing
  its `leading` widget entirely; Flutter's auto-inserted back button
  didn't render because GoRouter's `context.push('/settings')` from
  home doesn't leave a pop-able Navigator route in the way the AppBar
  heuristic expects. Added an explicit `IconButton` → `context.go('/')`
  matching the pattern already in use on regions / diagnostics /
  archive / home-location screens.

## [0.6.4+19] — 2026-04-20

### Fixed

- **5-second undo popup no longer needs manual dismissal.** The auto-
  send flow used `SnackBar.closed` as its timing mechanism — which is
  fine until Flutter's accessibility path kicks in: under TalkBack,
  Switch Access, or any service that sets `accessibleNavigation`, the
  framework pins SnackBars open until the user dismisses them, which
  silently blocked the send. Replaced the closed-future dependency
  with an independent `Timer` that fires the send after 5 seconds
  regardless of SnackBar state; UNDO cancels the timer directly,
  swipe-away still resolves as "send." The SnackBar is hidden
  explicitly once the resolution lands so there's no stale countdown
  lingering after the SMS goes out.

## [0.6.3+18] — 2026-04-20

### Fixed

- **Panic button fill no longer spills past the button edges.** The
  `Positioned.fill` overlay stretched to the parent `Stack`'s bounds
  while the `OutlinedButton` inside the Stack was intrinsic-width —
  so on release the red fill visibly extended past the button's sides
  on both edges. Wrapped the Stack in a fixed-height `SizedBox`,
  switched the Stack to `StackFit.expand`, matched the button's shape
  to a `RoundedRectangleBorder(8)`, and clipped the overlay with a
  matching `ClipRRect` so the fill can't escape the corners. The label
  also now uses `FittedBox(BoxFit.scaleDown)` as a last-resort guard
  against exotic font-scaling overflow.
- **Auto-send toggle reconciles with the live SMS grant.** Users who
  enabled auto-send on 0.6.1+16 (before the toggle-time prompt existed)
  upgraded to 0.6.2+17 with the toggle persisted ON but the underlying
  `SEND_SMS` permission never granted — panic-time fell through to the
  compose-intent fallback, same visible symptom as the 0.6.1 bug. The
  `PanicAutoSendNotifier.build()` method now checks `Permission.sms.
  status` after reading the persisted flag; if the flag says `on` but
  the permission isn't granted (upgrade case, or user revoked via
  system settings post-grant), it flips the stored flag to `false`.
  Next toggle-on re-prompts cleanly.

## [0.6.2+17] — 2026-04-20

### Fixed

- **Auto-send now actually auto-sends.** Before, flipping the toggle in
  Settings persisted the preference but never requested `SEND_SMS` —
  the request was deferred to panic-fire time, where a pre-existing
  denial returned immediately and silently fell through to the
  compose-intent path. Users saw the SMS app pop up with the body
  populated and nothing sent, which is exactly the manual flow the
  toggle was supposed to skip. The toggle now requests `SEND_SMS`
  up-front and only commits to `on` when the grant comes back — a
  denial shows a SnackBar (with a "Settings" action if permanently
  denied) and leaves the toggle off. Panic-time uses `.status` only,
  so there's no system dialog in the middle of an emergency.
- **"Hold to panic" label overflow.** The previous label rode inside
  `OutlinedButton.icon` next to a warning icon; on narrow screens the
  text ellipsised to "Hold to p…". Switched to plain `OutlinedButton`
  with an all-caps "HOLD TO PANIC" label (letter-spacing 1.4). The red
  outline and progress fill are already the affordance — no icon is
  needed. The `_working` state shows a compact `CircularProgressIndicator`
  + "LOGGING…" row instead of icon+label.

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
