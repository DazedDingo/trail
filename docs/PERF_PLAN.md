# Trail performance plan — map pin loading + app-wide improvements

**Date:** 2026-08-22 · **Baseline:** 0.13.10+94 (`adaa942`) · **Status:** plan only, nothing implemented yet.
All `file:line` references are against that commit.

---

## TL;DR

The "pick a multi-year range → pins appear seconds (or minutes) later" lag is **not the database** (3 years at the default 4 h cadence is ~7 000 rows / 20–35 ms). It is the way pins are handed to MapLibre: `full_map_panel.dart` draws each pin with its own `await controller.addCircle(...)`, and in `maplibre_gl` 0.26.0 every `addCircle` **re-serialises the entire circle collection to JSON on the UI isolate, ships it over the platform channel, and re-parses it natively**. N pins ⇒ Θ(N²) work. One year of pins (~2 200) is ~2.4 million feature serialisations (~560 MB of JSON text); three years (~7 000) is ~25 million. That is the whole lag, and it is why it only shows "over years".

Two bugs ride along with it and explain the word *eventual*:

1. The map is **torn down and remounted** on every new date range (`loading:` branch swaps `MapLibreMap` out) — 0.5–2 s of blank map, style re-parse, tile refetch, and an animated camera fly before the first pin can even be drawn.
2. Re-selecting a range that is already cached **never renders pins at all** — `_resetAnnotationTrackingOnFilterChange` nulls `_controller`, the map doesn't remount for a cached provider, so `onMapCreated` never runs again and `_refreshAnnotationsIfReady` bails forever.

**Fix:** stop using the annotation API for pins. Upload all fixes **once** as a GeoJSON source + native circle/line layers (the pattern the heatmap already uses), build the JSON string off the UI isolate, and change the visible time window with a single `setFilter` call — constant cost whether there are 100 pins or 100 000. Keep the map mounted across range changes. Expected result: range change ≈ 50–300 ms for the data load, playback scrubbing ≈ one ~80-byte platform call per tick.

Beyond the map, the audit found ~20 further improvements (cold-start, memory, stats, slideshow, export, background worker, build config). They are ranked in §3.

---

## 1. The reported bug — what happens today

### 1.1 Path from tap to pixels

| Step | Where | Cost at N fixes |
|---|---|---|
| Chip tap / picker / Clear → `onApply(range)` | `inline_date_filter_panel.dart:143-152` | — |
| `_applyDateFilter` → `setState` rebuilds the **whole panel**, `_sliderMax = null`, `_initialFitDone = false`, `_resetAnnotationTrackingOnFilterChange()` (which sets `_controller = null`, `_styleReady = false`) | `full_map_panel.dart:233-246`, `:205-218` | — |
| `ref.watch(pingsByRangeProvider(_dateFilter))` — `FutureProvider.family`, no `autoDispose` | `full_map_panel.dart:142`, `pings_provider.dart:38-51` | cache hit if the same `DateTimeRange` was used before |
| Cold key ⇒ `AsyncLoading` ⇒ `loading:` branch replaces the subtree ⇒ **`MapLibreMap` is disposed** | `full_map_panel.dart:169-171` | — |
| SQL: `SELECT * FROM pings WHERE ts_utc BETWEEN ? AND ? ORDER BY ts_utc ASC` (or `all()` for "All time"), 15 columns, no LIMIT; index `idx_pings_ts_utc` is used | `ping_dao.dart:87-98`, `:77-80`, `database.dart:220` | ~2–5 ms native |
| Result rows cross the platform channel and are `StandardMessageCodec`-decoded on the UI isolate; `Ping.fromMap` per row | `ping_dao.dart:97`, `ping.dart:121-140` | ~30–50 ms / 10k rows |
| `data:` branch ⇒ new `MapLibreMap` ⇒ new Android platform view + GL surface, 75 KB style re-parse, every visible tile re-fetched from `LocalTileServer` over loopback | `full_map_panel.dart:395` | **0.5–2 s**, N-independent |
| `onMapCreated` sets `_controller`; `onStyleLoadedCallback` → `_scheduleRefresh` + `_fitToFixes` (an **animated** `animateCamera`) | `full_map_panel.dart:406-420`, `:878-887` | ~300 ms animation |
| `_refreshAnnotations` → `clearLines` + `clearCircles` (twice: `:510-511` and again `:558-559`) | | 4 round-trips |
| `_renderPathFromScratch`: `for (i…) await c.addCircle(...)` | `full_map_panel.dart:576-582` | **Θ(N²)** — see §1.2 |
| Slider tap-to-jump / playback: `_renderPathIncrementalForward` does the same loop for the delta; backward does `removeCircle` per pin (also Θ(N²)) | `:607-614`, `:630-636` | Θ(k²) for a k-pin jump |

Every loop over the ping list on this path is O(N) and there are four of them per slider tick (`:173-175`, `:265-267`, `:461-463`, `:466-468`) plus a fresh `List<LatLng>` per refresh — a few ms, annoying but not the problem.

### 1.2 Why `addCircle` is quadratic (package internals, `maplibre_gl` 0.26.0)

- `MapLibreMapController.addCircle` → `circleManager.add(circle)` — `maplibre_gl-0.26.0/lib/src/controller.dart:1346`
- `AnnotationManager.add` → `_idToAnnotation[id] = annotation; await _setAll();` — `lib/src/annotation_manager.dart:152-155`
- `_setAll` → `controller.setGeoJsonSource(layerId, buildFeatureCollection([for (l in _idToAnnotation.values) l.toGeoJson()]))` — `:134-141`. **Every add rebuilds a Dart map for all N annotations.**
- `setGeoJsonSource` → `jsonEncode(geojson)` **on the UI isolate** → one `invokeMethod('source#setGeoJson')` — `maplibre_gl_platform_interface-0.26.0/lib/src/method_channel_maplibre_gl.dart:756-764`
- Android: Gson `JsonParser.parseString` + `FeatureCollection.fromJson` + `geoJsonSource.setGeoJson(...)` — `MapLibreMapController.java:415, 458-482`
- Each `Circle.toGeoJson()` stamps 7 style keys + `draggable` + `id` twice into `properties` (~230 bytes/feature) — `circle.dart:120-130`

So N sequential `addCircle` calls = N round-trips, N full encodes, Σ(1..N) ≈ N²/2 feature serialisations. `removeCircle` → `remove()` → `_setAll()` has the same shape. `addCircles(List)` / `removeCircles(List)` exist (`controller.dart:1368-1385`) and do **one** `_setAll` — the app never calls them.

### 1.3 Numbers

Row volume (`scheduler_policy.dart:16-35`; default cadence 4 h; no auto-prune, PLAN.md:56):

| Cadence | rows/year | 3 years |
|---|---|---|
| 30 min | ~17 500 | ~52 600 |
| 1 h | ~8 800 | ~26 300 |
| **4 h (default)** | **~2 200 (+~10 % no-fix/boot/panic ≈ 2 400)** | **~7 200** |

Cost of the current `addCircle` loop (Σk ≈ N²/2 features × ~230 B):

| N | feature serialisations | JSON produced | rough wall time |
|---|---|---|---|
| 500 (a week at 30 min) | 125 k | ~29 MB | ~1 s |
| 2 200 (1 yr @ 4 h) | 2.4 M | ~560 MB | 10–30 s |
| 7 200 (3 yr @ 4 h) | 26 M | ~6 GB | minutes |
| 10 000 | 50 M | ~11.5 GB | minutes / ANR / OOM |

Versus the storage layer for the same 3-year load: **~20–35 ms** (default cadence) to **~160–260 ms** (30 min cadence). Storage is two orders of magnitude off the critical path.

### 1.4 Root causes, ranked

1. **Per-pin `addCircle` / `removeCircle` loops** — `full_map_panel.dart:576-582`, `:607-614`, `:630-636` (dead twin in `trail_map.dart:95-112`). Θ(N²). *The* lag.
2. **`MapLibreMap` remount on every cold range** — `full_map_panel.dart:169-171` → `:395` → `:410-420` → `:878-887`. 0.5–2 s blank map + flicker per selection (documented as accepted in CLAUDE.md gotcha 22 — it should not be accepted).
3. **`_controller = null` in `_resetAnnotationTrackingOnFilterChange`** — `:207`, bail at `:458`. Cached ranges never render pins. Correctness bug; matches "eventual".
4. **`_sliderMax` default divergence** — build uses `_sliderMax ?? first` (`:264`), refresh uses `_sliderMax ?? chrono.last` (`:465`). "Latest", the path/heatmap toggles and the post-filter refresh render **all N** while the HUD says "1 / N"; each of those detonates #1 at full N.
5. **Everything after SQL runs on the UI isolate** with no `compute()`/`Isolate.run` anywhere in `lib/` — ~150–400 ms of channel decode + `fromMap` + GC per 10k rows, plus each selected range retained forever (no `autoDispose`).
6. **No cancellation** — `_scheduleRefresh` single-flights but a running N-pin render must finish before a newer, smaller request runs. Selecting "3 years" then "1 week" waits for the 3-year render.

---

## 2. Map fix plan

### Phase M1 — native pin layers with a time filter (the fix) · effort L (~1 day)

Replace the annotation API in `full_map_panel.dart` with sources + style layers, created once per map/style lifetime in `onStyleLoadedCallback`:

```dart
// Sources (once, after style load). Use addSource() only if cluster/buffer are wanted;
// addGeoJsonSource() is cheaper but exposes no options.
await c.addGeoJsonSource(_pinsSrc, _emptyFc);           // points, one Feature per fix
await c.addGeoJsonSource(_segsSrc, _emptyFc);           // 2-point LineString per consecutive pair

// Layers (once). Filter is the time window; enableInteraction gives onFeatureTapped.
await c.addLineLayer(_segsSrc, _pathLayer,
    LineLayerProperties(lineColor: pathHex, lineWidth: 2, lineOpacity: 0.8),
    filter: tsFilter(t0, t1));
await c.addCircleLayer(_pinsSrc, _pinsLayer,
    CircleLayerProperties(
      circleRadius: ['case', ['==', ['get', 'id'], headId], 8, 3],   // head pin bigger
      circleColor: ['interpolate', ['linear'], ['get', 'ts'], t0, oldHex, t1, newHex], // age ramp
      circleStrokeWidth: 1, circleStrokeColor: strokeHex),
    filter: tsFilter(t0, t1), enableInteraction: true);

// Data (once per range change). editGeoJsonSource is the ONLY 0.26.0 upload that takes a
// pre-serialised String — build it in an isolate so the UI thread never jsonEncodes.
final json = await Isolate.run(() => buildPinsGeoJson(fixes));   // pure, unit-testable
await c.editGeoJsonSource(_pinsSrc, json);
await c.editGeoJsonSource(_segsSrc, await Isolate.run(() => buildSegmentsGeoJson(fixes)));

// Time window change (slider tick, step, jump, play): zero re-upload.
List<Object> tsFilter(int t0, int t1) => ['all', ['>=', ['get','ts'], t0], ['<=', ['get','ts'], t1]];
await c.setFilter(_pinsLayer, tsFilter(t0, sliderMaxMs));
await c.setFilter(_pathLayer, tsFilter(t0, sliderMaxMs));
await c.setLayerProperties(_pinsLayer, CircleLayerProperties(circleRadius: [...headId...]));
```

Details / decisions:

- **Feature shape:** `{"type":"Feature","id":<pingRowId>,"geometry":{"type":"Point","coordinates":[lon,lat]},"properties":{"id":<pingRowId>,"ts":<epochMs>}}`. Nothing else — do not copy the annotation API's 7 style keys per point. Segments carry `ts` of their later endpoint so the same filter works.
- **Head / previous pin styling** (`_headOptions`, `_prevOptions`, `_smallOptions` today): data-driven `circle-radius`/`circle-color` expressions keyed on `['get','id']`, updated with one `setLayerProperties` per tick. Alternative: a 1-feature `pin-head` source updated with `setGeoJsonSource` (tiny payload). Either is O(1).
- **Taps:** `c.onFeatureTapped.add(...)` replaces `onCircleTapped` + the `_circleToPing` map (`:578`, `:611`, `:613`). The callback delivers the feature `id` and `layerId`; look the ping up by id (`PingDao.byId`) or from an in-memory `Map<int, Ping>`. Hit radius: `circle-radius` plus `queryRenderedFeaturesInRect` around the tap if a fat finger margin is wanted (0.13.9's "tappable pin radius").
- **Heatmap:** already a source + `addHeatmapLayer` (`:759-777`, `:783-793`). Point it at `_pinsSrc` with its own filter instead of building a second FeatureCollection.
- **Delete-pin / invalidate:** re-run the upload (one `editGeoJsonSource`), not a remount.
- **Filter change vs data change:** keep `_renderedRangeKey` (the `DateTimeRange?` + ping-list identity). Data upload only when it changes; everything else is `setFilter`.
- **Cancellation:** guard the async upload with a generation counter so a stale `Isolate.run` result is dropped.
- `_resetAnnotationTrackingOnFilterChange` becomes: bump generation, clear `_renderedRangeKey`. **Never null `_controller`.**
- Remove the dead `trail_map.dart` annotation loop (only `test/trail_map_test.dart` references `TrailMap`; Home has hosted `FullMapPanel` since 0.10.13) or port it to the same helper. Update CLAUDE.md gotcha 22 (no longer true) and gotcha 12.
- Keep the pure helpers top-level (`buildPinsGeoJson`, `buildSegmentsGeoJson`, `tsFilter`, `visibleCount`) so they are unit-testable without a map (CLAUDE.md gotcha 18 pattern).

**Optional stop-gap (effort S, <1 h, could ship as 0.13.11 today):** swap the three loops for `c.addCircles(list)` / `c.removeCircles(list)` and drop the duplicate `clearLines/clearCircles`. Θ(N²) → Θ(N): 10k pins goes from minutes to ~150–400 ms. Still re-uploads everything per playback tick, so it is not the end state — only do it if M1 cannot ship soon.

### Phase M2 — keep the map mounted across range changes · effort S

- `full_map_panel.dart:169-171`: render the map from `pingsAsync.valueOrNull ?? _lastPings` and overlay a thin `LinearProgressIndicator` while loading, instead of replacing the subtree. Give `MapLibreMap` a stable `key`. The platform view, style and tiles survive; `_controller`/`_styleReady` stay valid — which is what makes root cause #3 disappear structurally.
- Keep `_initialFitDone = false` on range change but fit with `moveCamera` (instant) when the map was already showing, and only `animateCamera` on first mount.
- Drop the `AnimatedSize` collapse of the filter panel (`inline_date_filter_panel.dart:44-46`) during a load, or let it finish before the upload — resizing the platform view mid-upload costs a relayout.

### Phase M3 — slider / playback plumbing · effort S–M

- Unify `sliderMax` semantics into one helper (`effectiveSliderMax(chrono)`) used by build, refresh and the HUD; decide once whether "no selection" means *first* or *last* (HUD currently lies — `:1266-1267`).
- Precompute per provider value (keyed on `identical(pings, _lastPings)`): `chrono` (fixes with coordinates, already time-sorted by SQL) and a `List<int> tsMs`. `visible` count and `stepSliderTo` (`:1075-1084`) become `lowerBound` binary searches instead of `where().toList()` / linear scans.
- Move `_sliderMax` into a `ValueNotifier`; only the slider + HUD rebuild per tick (`ValueListenableBuilder`). The map receives `setFilter` only. Raise `playbackInterval`'s floor from 16 ms to 33 ms (`:1040-1046`) — there is no point ticking faster than the filter can apply.
- Throttle `_TimeSlider.onChanged` (`:339-343`) to one `setFilter` per frame (`SchedulerBinding.addPostFrameCallback` coalescing) — the existing single-flight loop drops work but never bounds it.

### Phase M4 — data path · effort M

- `PingDao.byDateRange` / `all()`: add a map-specific read `mapFixes(range)` returning a light record `(id, tsMs, lat, lon, source)` with `columns:` set and `AND lat IS NOT NULL` in SQL (`ping_dao.dart:87-98`). 15 → 5 values/row; no `Ping`/`DateTime` allocation per row.
- Schema v4 (`database.dart:220`): `CREATE INDEX idx_pings_ts_fix ON pings(ts_utc, lat, lon) WHERE lat IS NOT NULL` — covering + partial; also makes `latestSuccessful` (`ping_dao.dart:57-66`) O(1) instead of walking every `no_fix` row of a stationary streak. Run `ANALYZE` after the migration. Mirror the index in the three in-memory test schemas (CLAUDE.md gotcha 20).
- `pingsByRangeProvider`: `.autoDispose` + `ref.keepAlive()` for the active range; define `allPingsProvider` as `pingsByRangeProvider(null)` so stats/trips and the map share one copy (`pings_provider.dart:26-51`).
- `archive_screen` invalidates `recent`+`all` but not `pingsByRangeProvider` (`archive_screen.dart:117-118`) — invalidate the family too.
- LOD / downsampling is **not** needed for rendering (MapLibre draws 50k native circles fine); revisit only if 30-min-cadence users report slow *uploads* (~2–5 MB JSON, once per range). `GeojsonSourceProperties(cluster: true)` is available via `addSource` if ever wanted.

### Phase M5 — `maplibre_gl` 0.27.0 upgrade · effort S, separate commit

Latest on pub.dev is 0.27.0. Relevant: large GeoJSON payloads encoded off the UI thread (#366) — redundant once M1 uses `editGeoJsonSource` + `Isolate.run`, but it also fixes the Android `maxzoom` key mismatch on GeoJSON sources, makes `queryRenderedFeaturesInRect` honour its `filter`, adds feature-state on Android, `clusterMinPoints`, and `MapLibreMap.preWarm()` (170–480 ms off first map on Android). Breaking: style content must be (re)added inside `onStyleLoadedCallback` — M1 already does that; `SourceProperties.copyWith` → named params. Do it after M1 lands, not before.

### Expected outcome

| Scenario | Today | After M1–M4 |
|---|---|---|
| Select "3 years" (7 200 pins, default cadence) | minutes of progressive pin-by-pin placement, blank map first | ~50–150 ms DB + ~100–200 ms isolate JSON build + one upload; map never blanks |
| Select "3 years" at 30-min cadence (52 600 pins) | ANR / OOM territory | ~250 ms DB + ~0.5–1 s upload, once |
| Re-select a cached range | pins never appear | one `setFilter` (ms) |
| Playback at 16× | per-tick O(k) re-upload, callbacks pile up | one ~80-byte `setFilter` per tick |
| Slider tap-to-jump to the end | Θ(N²) add loop | one `setFilter` |

---

## 3. Other performance improvements (outside the pin path), ranked

Impact = user-visible effect; Effort S (<2 h) / M (half day) / L (day+).

| # | Area | Problem | Fix | Impact | Effort |
|---|---|---|---|---|---|
| 1 | Playback timer | `setState` on `_FullMapPanelState` per tick rebuilds the whole panel and copies the ping list twice (`full_map_panel.dart:917-941`, `:173-176`, `:265-268`); floor 16 ms | Covered by M3 | Frame drops + battery during playback | M (in M3) |
| 2 | Reverse geocoding | `reverseGeocodeProvider` keyed on raw `(lat,lon)` despite the "rounded" comment, no `autoDispose`, one platform/network call per list row (`pings_provider.dart:86-92`; callers `home_screen.dart:710`, `history_screen.dart:78`, `stats_screen.dart:379`); `stats_provider.dart:59-61` fires **30 concurrent** `placemarkFromCoordinates` | Round key to 4 dp; `.autoDispose` + `keepAlive()` on success; LRU in `GeocodingService`; cap stats burst at 4 | Scroll jank on Home/History, "Service not Available" bursts, steady memory leak | S |
| 3 | Cold start | `main.dart:20-47` awaits WorkManager init, notification init (redundant — idempotent and self-invoked by every caller), `FailedPhotoUris.preload` (whole prefs file incl. up to 2 000 URLs), `OnboardingGate.isComplete` (Keystore unwrap), `computeNeedsUnlock` **serially**; two separate `FlutterSecureStorage` instances (`onboarding_provider.dart:14`, `keystore_key.dart:37`) each pay Keystore init | `Future.wait` the two router-gating reads; move the other three to a post-frame callback; share one `FlutterSecureStorage` | ~150–400 ms off time-to-first-frame | S |
| 4 | User photos never render | `Image.asset` given a filesystem path for `file://` URIs (`slideshow_view.dart:339-347`, `ping_photos_gallery.dart:267-275`) — always hits `errorBuilder`, which then writes the whole denylist to prefs and `setState`s the gallery; no `cacheWidth` anywhere so a 12 MP shot decodes at full size (~48 MB) into a 132 px tile | `Image.file(File(path), cacheWidth: 320)`; `cacheWidth` in the slideshow | Bug fix + removes a 48 MB-per-photo decode and a prefs write storm | S |
| 5 | Memory caps | `imageCache` 5 000 entries / 250 MB (`main.dart:38-41`) + 50 MB Dart-heap tile cache (`local_tile_server.dart:38`) on top of MapLibre's native cache | ~120 MB / 1 000 entries; tile cache 16 MB; clear on `didHaveMemoryPressure` | Top OOM-kill / background-eviction risk | S |
| 6 | Stats screen | `dailyCounts`, `hourlyCounts`, `detectTrips` computed inside `build` (`stats_screen.dart:97,120,130`); `detectTrips` sorts an already-sorted list and runs Haversine twice per ping (`stats_service.dart:91-126`); `trips_provider.dart:14-18` recomputes the same trips independently | Make them `Provider`s derived from `allPingsProvider`; stats watches `tripsProvider`; drop the redundant sort; precompute `cos(homeLat)` | Stats paint cost ÷3; Trips screen free | S |
| 7 | Slideshow warm-up | `_warmFirstFrames` → 100 × `pickPhotoForPing` → `indexOf` + backward walk (`slideshow_view.dart:134-141`, `:516-527`); `pickSlideshowPing` full scan every build + a new post-frame callback per build (`:210`, `:224-226`) | `Map<pingId,index>` + resolved-photo cache built once per window; binary search (list is chronological) | Removes the multi-hundred-ms hitch entering picture mode | M |
| 8 | Export / archive | Export reads the whole table then filters in Dart (`export_dialog.dart:93-94`) and builds a multi-MB GPX/CSV string on the UI isolate (`gpx_exporter.dart:79-101`, `csv_exporter.dart:25-45`); `ArchiveService.preview` materialises every archivable row just for first/last timestamps (`archive_service.dart:81-84`), re-run on every cutoff change; no `VACUUM` after `deleteOlderThan` (`:128`) | `dao.byDateRange` + `compute()` for the string build; preview → `SELECT COUNT(*), MIN(ts_utc), MAX(ts_utc)`; `VACUUM` after archive | Removes an ANR-class freeze on export; archive screen instant; file actually shrinks | M |
| 9 | `byPingIds` unchunked IN-list | `ping_photo_dao.dart:36-45` builds one `?` per id; SQLCipher caps host params at 32 766 → slideshow over a long range at 30-min cadence throws "too many SQL variables" | Chunk at ≤900 and merge | Correctness at scale | S |
| 10 | Local tile server | `rootBundle.load` per glyph/sprite request — `CachingAssetBundle` doesn't cache `load()` (`local_tile_server.dart:170-190`); HTTP handler on the UI isolate (`:74`); unawaited `response.close()` (`:321`) | Small `Map<String, Uint8List>` for the ~1.4 MB of immutable glyph/sprite assets; await/catch close | Smoother first paint + pan | S |
| 11 | Style JSON | `trail_style.dart:37,95-98` re-loads 74 KB + 3 × `replaceAll` per mount from three call sites; `trail_map.dart:170-178` loads twice (port null → real) | Static memo keyed on `(path, port)` | 10–25 ms per map mount | S |
| 12 | Background worker | `_handleBoot` opens+closes the DB then `_handleScheduled` opens again → two SQLCipher KDF runs per boot (`workmanager_scheduler.dart:449-470`); periodic task re-registered with `update` policy on **every** tick (`:280-286`); `WorkerRunLog.record` does read→decode→encode→write per tick; Wikimedia fetch inside the worker with 2 × 8 s timeouts and no backoff (`:326`, `online_photo_service.dart:47,87,112`) | Pass the handle through; re-enqueue only when cadence changed; gate photo fetch on unmetered/charging | Battery per tick; ~100–300 ms per reboot | M |
| 13 | Photo backfill sheet | One stream event + `setState` per processed ping, no throttle on cache hits (`photo_backfill_service.dart:177-182`, `photo_backfill_sheet.dart:57-58`) | Emit every 25 pings or at 10 Hz | Backfill stops locking the UI | S |
| 14 | Settings screen | `FutureBuilder(future: _appVersionLabel())` created in `build` → re-fires `package_info_plus` on every rebuild/resume (`settings_screen.dart:386-387`); eager `ListView(children: [~40 tiles])`, ~12 of which each `ref.watch` a separate `FutureProvider` | `late final` version future; `ListView.builder` / lazy slivers | Flicker + repeated IPC on open/resume | S |
| 15 | Home screen | Four providers watched at the root (`home_screen.dart:39-42`) so any refresh/panic rebuilds the whole tree **including `FullMapPanel`**; `take(100).toList()` in build (`:195`); no `itemExtent` on fixed-height rows (`:196`) | Leaf `Consumer`s; `PingDao.recent(limit: 100)`; `itemExtent` | Removes a full-panel rebuild per refresh | S |
| 16 | Calendar heatmap | 84 × (`Tooltip` + `GestureDetector` + `Container`) with a `DateFormat` allocated per cell (`calendar_heatmap.dart:80-123`) | Hoist `DateFormat`s; one `CustomPaint` + hit-math; `RepaintBoundary` | Stats build time | M |
| 17 | Repaint hygiene | Zero `RepaintBoundary` in `lib/`; `ClockChart.shouldRepaint` compares lists by identity so it always repaints (`clock_chart.dart:131-134`) | `RepaintBoundary` around map + charts; `listEquals` | Fewer repaints | S |
| 18 | Provider retention | No `autoDispose` anywhere; `pingPhotosProvider` / `pingsByRangeProvider` families retain every key forever; same ping data held in 3–4 places (`photos_provider.dart:22-26`, `pings_provider.dart:38-51`, panel fields `:101,560,580`) | Covered by M4 + `.autoDispose` on photos | Bounded memory over a long session | S |
| 19 | Photo gallery | `where()` + per-photo `RegExp` in `build`, eager `ListView(children:)`, `setState` on every image error re-runs the filter (`ping_photos_gallery.dart:124-141`) | `ListView.builder` + `itemExtent`; memoise `shrinkWikimediaThumbUrl` | Gallery scroll | S |
| 20 | Build config | `android/app/build.gradle.kts:48-52` release block has no `isMinifyEnabled`/`isShrinkResources` (R8 off); CI builds one fat APK (arm64 + armeabi-v7a + x86_64) with no `--split-per-abi` / `--obfuscate --split-debug-info` (`.github/workflows/release.yml:49`) | Enable R8 + resource shrinking with Flutter's default ProGuard rules; `--split-per-abi` (update the signing-verify grep at `release.yml:57-60`) | Install size, dex load at cold start | S |
| 21 | SQLite pragmas | `synchronous` never set (defaults FULL under WAL); no `ANALYZE` ever; no `VACUUM` after archive (`database.dart:85-93`) | `PRAGMA synchronous=NORMAL; cache_size=-8000` in `onOpen`; `ANALYZE` after migrations | One fsync fewer per worker insert; planner picks the new indexes | S |
| 22 | Passphrase KDF on UI isolate | `PassphraseService.deriveKey` (PBKDF2 210k) runs synchronously on the UI isolate in `passphrase_entry_screen.dart:64` and `settings_screen.dart:976` — 1–3 s freeze | `Isolate.run` | Setup/unlock screens stop freezing | S |

Checked and clean: `PingPhotoDao.byPingIds` is a real batch; photo inserts use `Batch`; `TrailDatabase.shared()` memoises the future; `_scheduleRefresh` single-flights correctly; the tile server is lazily started; no sync file I/O in `build`; `debugPrint` only on rare/error paths; timestamps are INTEGER epoch ms with an index (no TEXT-timestamp problem).

---

## 4. Sequencing

| Release | Contents | Why this grouping |
|---|---|---|
| **0.14.0** | M1 + M2 + M3 (+ dead `trail_map.dart` loop removed, CLAUDE.md gotchas 12/22 rewritten) | The reported bug, fixed properly, in one coherent map-panel change |
| 0.14.1 | M4 (schema v4, light map read, autoDispose) + §3 #2, #3, #4, #5, #9 | Cheap, independent, mostly S-effort wins; schema bump warrants its own release |
| 0.14.2 | §3 #6, #7, #8, #13, #14, #15, #17, #19 | Screen-by-screen polish |
| 0.15.0 | M5 (`maplibre_gl` 0.27.0) + §3 #20 (R8, split-per-abi) + #12 | Dependency + build-config changes get their own version so a regression is easy to bisect |
| opportunistic | #10, #11, #16, #21, #22 | — |

If a same-day stop-gap is wanted before M1: the `addCircles` swap (§2, M1 "optional stop-gap") as 0.13.11.

---

## 5. Verification

**Unit (plain `flutter test`, no map needed — gotcha 18 pattern):**
- `buildPinsGeoJson` / `buildSegmentsGeoJson`: feature count, `id`/`ts` properties, `[lon,lat]` order, empty input → empty `FeatureCollection`, null-coordinate fixes excluded.
- `tsFilter(t0,t1)` literal shape; `visibleCount(tsMs, sliderMax)` binary search vs. brute force on random inputs; `effectiveSliderMax` semantics; `stepSliderTo` parity with the old linear scan.
- Schema v4 migration applies on a v3 in-memory DB; `mapFixes(range)` excludes `lat IS NULL`; existing `ping_dao_test.dart` schemas mirror the new index.
- A non-CI benchmark (`test/benchmark/` or `--tags bench`): `buildPinsGeoJson(50 000 fixes)` < 300 ms on the dev box, as a regression tripwire.

**On device (manual, the only place the map renders):**
1. Select "All time" with a multi-year DB (copy a real DB or seed 20k rows via the diagnostics screen/ADB) — pins visible < 1 s, no blank map, no flicker.
2. Re-select a previously selected range — pins update immediately (root cause #3).
3. Drag the slider end-to-end; tap-to-jump to the end; play at 16× — smooth, `adb shell dumpsys gfxinfo com.dazeddingo.trail` shows no frame > 32 ms during playback.
4. Tap a pin → detail sheet opens for the right ping; tap in the gap between pins → nothing.
5. Toggle heatmap / path; delete a pin from the sheet; archive older pings → map reflects it without remount.
6. `adb shell dumpsys meminfo com.dazeddingo.trail` before/after 10 range changes — stable (autoDispose).
7. Cold start stopwatch (`adb shell am start -W`) before/after §3 #3.

---

## Appendix — `maplibre_gl` 0.26.0 API facts used above

(`~/.pub-cache/hosted/pub.dev/maplibre_gl-0.26.0/lib/src/controller.dart` unless noted)

- `addGeoJsonSource(String sourceId, Map geojson, {String? promoteId})` `:446` — cheap, but no options; Android hardcodes `GeoJsonOptions().withSynchronousUpdate(dragEnabled)`.
- `addSource(String id, SourceProperties)` `:1775` — the only way to get `cluster`/`clusterRadius`/`buffer`/`tolerance`/`lineMetrics`; `data` must be a Map (a JSON *string* is treated as a URI and silently fails on Android); `maxzoom` is dropped on Android until 0.27.0.
- `setGeoJsonSource(id, Map)` `:469` and `setGeoJsonFeature(id, Map)` `:487` — `jsonEncode` on the UI isolate (`method_channel_maplibre_gl.dart:756-764`, `:1004`).
- **`editGeoJsonSource(String id, String data) → Future<bool>`** `:1061` — raw string passthrough (`method_channel:309-319`) straight to `GeoJsonSource.setGeoJson(String)` natively (`MapLibreMapController.java:1135-1156`). The one zero-UI-encode upload path.
- `addCircleLayer(sourceId, layerId, CircleLayerProperties, {belowLayerId, sourceLayer, minzoom, maxzoom, filter, enableInteraction})` `:801`; `addLineLayer` `:654`; `addSymbolLayer` `:611`; `addHeatmapLayer` `:907`. All `*LayerProperties` fields are `dynamic` → expressions allowed.
- `setFilter(layerId, filter)` `:1741` / `getFilter` `:1745`; `setLayerProperties` `:686` (nulls reset to default); `setLayerVisibility` `:1929`; `removeLayer` `:1737`; `removeSource` `:1705`.
- `onFeatureTapped` (`List<OnFeatureInteractionCallback>`, `:334`) — fires for style-layer features on layers created with `enableInteraction: true`, delivering the feature id + layer id. `queryRenderedFeatures` `:1562`, `queryRenderedFeaturesInRect` `:1571` (its `filter` is ignored on every platform in 0.26.0), `querySourceFeatures` `:1589`.
- Annotation API cost model: `addCircle` `:1346` → `annotation_manager.dart:152-155` → `_setAll` `:134-141` re-uploads the whole collection per call; `addCircles` `:1368` / `removeCircles` do it once per batch; `updateCircle` → `setGeoJsonFeature` (one feature over the wire, linear native scan).
