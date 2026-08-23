# Google Maps Timeline import — feasibility + plan

**Date:** 2026-08-22 · **Status:** built the same day — Android `Timeline.json` import with preview/thinning/dedupe/undo shipped in **0.16.0+99** (iOS dialect and legacy Takeout deferred; see CLAUDE.md gotchas 34–36); map coverage Phases A/B/C shipped in 0.15.0 / 0.15.1 / 0.16.0. Sources were checked on that date; Google publishes no schema, so re-verify the format before implementing. Map-coverage design (§ Commander's considerations 3) completed with measured sizing the same day.

## Verdict

Yes. Everything Trail needs already exists (file picker, encrypted `pings` table with a `source` enum, a map that renders 50k native points). The work is a streaming JSON reader + a mapper + a thinning/dedupe pass + a small Settings flow. **~1–1.5 weeks for the Android export + undo; +1 day for the iOS dialect; +1 day for the legacy Takeout `Records.json`.**

## What can actually be exported in 2026

| Path | Status | File |
|---|---|---|
| **On-device export (Android):** Settings → Location → Location services → Timeline → account → *Export Timeline data* (or Maps → Your Timeline → ⋮ → Location & privacy settings → Export) | **Live — the primary path.** Timeline has been device-resident since the Dec-2024 → Jun-2025 migration. Contains only what's on the phone (90-day default at migration; auto-delete 3/18/36 months). | `Timeline.json` (pretty-printed, 20–200 MB typical, 250 MB worst case) |
| On-device export (iOS) | Live; different dialect | `location-history.json` |
| Google Takeout "Location History (Timeline)" | **Effectively dead** for migrated accounts (folder holds `Encrypted Backups.txt` + settings + tombstones). Only pre-2025 Takeout zips still carry `Records.json` + `Semantic Location History/`. | `Records.json` (legacy) |
| Web Timeline KML | Gone (web Timeline shut 2025-06). | — |
| Encrypted cloud backup | Exists but is **not downloadable**; restore it onto a phone, then run the on-device export. | — |

## Format (Android `Timeline.json`)

Top level `{"semanticSegments":[…], "rawSignals":[…], "userLocationProfile":{…}}`. Coordinates are strings with degree signs (`"51.5074°, -0.1278°"`, `°` = bytes `C2 B0`); timestamps are ISO-8601 with offset; probabilities 0–1.

- `semanticSegments[]` — one of:
  - `timelinePath: [{point: "lat°, lon°", time: ISO}]` — the bulk breadcrumb (1–2 h windows while moving, minute-snapped times, no accuracy).
  - `visit: {topCandidate: {placeId, semanticType (HOME|WORK|UNKNOWN|INFERRED_HOME|…), placeLocation: {latLng}}}` + `startTime`/`endTime`.
  - `activity: {start: {latLng}, end: {latLng}, distanceMeters, topCandidate: {type: WALKING|IN_PASSENGER_VEHICLE|CYCLING|…}}`.
  - `timelineMemory` — trip summary, no coordinates (skip).
- `rawSignals[]` — `{position: {LatLng (capital L!), accuracyMeters, altitudeMeters, speedMetersPerSecond, source: GPS|WIFI|CELL|UNKNOWN, timestamp}}` | `{wifiScan}` | `{activityRecord}`. Present for roughly the last 30 days; ~2 000 positions/day; the only records with accuracy/altitude/speed. Since mid-2026 exports routinely carry both streams, and raw ≠ path (different second granularity; only ~1 % coincide exactly).
- `userLocationProfile.frequentPlaces[{label: HOME|WORK, placeLocation: "lat°, lon°"}]` — a free "set home location from Google" feature.

iOS dialect: bare root array, `"geo:lat,lon"` strings, `placeID`, numbers as strings, path points carry `durationMinutesOffsetFromStartTime` instead of `time`.

Legacy `Records.json`: `{locations: [{latitudeE7, longitudeE7, accuracy, altitude, velocity, heading, source, timestamp|timestampMs}]}` — 500–2 000 points/day; some files wrap negative E7 values as unsigned 32-bit (subtract 2³² when |lat| > 9e8 / |lon| > 1.8e9).

Densities seen in the wild: ~180 path points/day (1-yr, 21 MB, 66k points); 15-year exports approach 0.5–1 M candidate points. **Thinning is mandatory by default.**

## Mapping → `pings`

- New `PingSource.imported` → db `'import'` (old builds read unknown values as `scheduled`; acceptable). Provenance in `note` with a fixed prefix so it's greppable and undoable: `gmaps:path`, `gmaps:visit:<semanticType>:<placeId>`, `gmaps:activity:<type>:<m>m`, `gmaps:raw:<source>`, `gmaps:records:<source>`.
- `timelinePath` points → rows (all sensor columns NULL). `visit` → two rows (start, end) at the place coords. `activity` → start/end rows only when no kept point within ±5 min of the endpoint. `rawSignals.position` with accuracy ≤ 100 m → rows with accuracy/altitude/speed. Skip `timelineMemory`, `wifiScan`, `activityRecord`.
- **Exclusions that must ship with it:** `latestSuccessful` / heartbeat must ignore `source='import'` (otherwise an export becomes the "last ping"); imported rows must never feed the Wikimedia auto-fetch (coordinates would leave the device — CLAUDE.md gotcha 21); **amended 2026-08-23 by the commander:** the *manual* backfill sheet and the per-import *Photos…* action do include imports — explicit taps, with the privacy note on screen; stats heatmap either thins hard or scales per source (imports at 100s/day would swamp 6/day of live pings).
- Thinning (user preset): keep a candidate when Δt ≥ 15 min **or** ≥ 250 m from the last kept (Normal; ≈ 20–40/day → ~10k/yr); Coarse = 60 min / 1 km; Full = none (warn above 50k projected rows). Within a 60-s window prefer the candidate with non-null accuracy (raw over path) — this is also the raw-vs-path dedupe. Visit start/end always kept.
- Dedupe vs existing pings: load `(ts_utc, lat, lon)` for the file's range, skip a candidate within ±60 s and < 25 m of an existing row (binary search on ts). Refuse byte-identical re-imports (hash of first 1 MB + length). **Undo last import** = delete by note prefix + time range (or add an `import_id` column).
- Time zones: use the offset in each ISO string, `toUtc()`. Validate lat/lon (reject NaN, out of range, (0,0)).

## Parsing

`jsonDecode` on a 200 MB file builds a ~500 MB object tree and gets LMK-killed on 3–4 GB phones; the SDK's chunked decoder still materialises the whole object at `close()`. The document shape is fixed (an object with two big arrays, or a bare array on iOS), so the robust zero-dependency approach is a ~120-line **byte-level splitter** that tracks string/escape/depth, yields each depth-2 `{…}` element of `semanticSegments` / `rawSignals` as bytes, and `jsonDecode`s elements one at a time (bounded memory ≈ chunk + one element). Pure function → unit-testable with synthetic fixtures (don't copy Dawarich/Reitti fixtures — AGPL). Run it in `Isolate.spawn` (not `Isolate.run` — we need progress), ship batches of ~2 000 candidate rows to the UI isolate, insert there with `Batch` inside one transaction (the background isolate must not share the UI DB handle — gotcha 1). SQLCipher inserts dominate, hence thin before insert. Fallback package if we'd rather not own the scanner: `json_events` 1.2.2 (event streamer, last published 2024-02). Input via `File(path).openRead()`; decode with `allowMalformed: true` (real exports contain invalid UTF-8). `file_picker` copies the SAF pick into the app cache — call `clearTemporaryFiles()` after; stay on 11.x (`withReadStream`) — 12.0.0 (2026-08-14) removed it.

## UI

Settings → History → *Import Google Timeline* → file picker → dry-run preview ("N rows after thinning, M duplicates skipped, range X–Y", preset picker, projected-row warning) → progress with cancel → result → *Undo last import*. Optional: "Set home location from Google" from `frequentPlaces[HOME]`.

## Effort

| Piece | Size |
|---|---|
| Streaming splitter + element decoder (pure, tested) | M (2–3 d) |
| Android mappers (path / visit / activity / raw / profile) | S–M (1 d) |
| Thinning + dedupe engine (pure; haversine exists in `HomeLocationService`) | S–M (1 d) |
| Isolate pipeline + batched insert + progress/cancel | M (1–2 d) |
| Settings flow + preview + undo | M (1–2 d) |
| `PingSource.imported` + heartbeat/photo-fetch/stats exclusions + tests | S (0.5 d) |
| iOS dialect | S (0.5 d) |
| Legacy `Records.json` | S–M (1 d) — user unzips Takeout themselves |
| Legacy Semantic monthly files | M — defer; low value in 2026 |

## Risks

1. No schema, silent format drift (`rawSignals` appeared/expanded in 2025-03 and 2026-06; enum spellings vary). Parse permissively, never fail the whole file on one element, report per-section skip counts.
2. Data the user can't get: migrated accounts only have the on-device window; pre-migration history lives in the non-downloadable encrypted backup ("restore the backup on your phone first, then export").
3. Volume vs UX: 15-year exports ≈ 1 M candidates; the preview + projected-row warning is the guardrail.
4. Provenance leakage into Wikimedia auto-fetch — default-off for imports.
5. Backup quota: in passphrase mode the DB is in Android auto-backup (25 MB per-app quota, gotcha 7); a 100k-row import blows it. Warn on the import screen.
6. Terms: none blocking — Google ToS keeps user content the user's; Takeout help explicitly contemplates moving exports to other services; Place IDs may be stored.

## Commander's considerations (added 2026-08-22)

### 1. Data that is already on the device
Two readings, both handled:
- **Overlap with Trail's own pings.** The dedupe rule above (skip a candidate within ±60 s and < 25 m of an existing row) applies to *every* existing row, so a period Trail was already logging gets only the Timeline points that fall between Trail's fixes. Trail's own fix always wins — imports never overwrite or re-time an existing row. Re-importing a newer export (a superset) adds only the new tail; a byte-identical file is refused outright. The preview must report "M duplicates skipped" so this is visible.
- **Reading Google's on-device Timeline store directly** is not possible: it is private to the Maps app (no content provider, no API), so the export step stays manual. We can shorten it to one tap from inside Trail by deep-linking to the Maps/Location settings page (verify the intent on device — it may only resolve on recent Play services) and by detecting the freshly saved `Timeline.json` in Downloads.

### 2. Points outside the UK
Today only Great Britain region builds exist, so anything outside the active region's bbox renders on a blank canvas. Pins themselves still draw (they are a native layer, independent of tiles), so an import "works" — it just looks like dots on nothing once you leave the UK. This is the real blocker for the feature and needs the map-coverage strategy below, which should ship *before* or *with* the import.

### 3. Map coverage: detailed where you've been, coarse everywhere else
Goal: the app owns its coverage decisions from the ping history — a world-level overview so every pin has context, plus high-zoom detail only around places actually visited, fetched efficiently (small, resumable, explicit/opt-in network use — the product is offline-only by default).

**Research completed 2026-08-22:** empirical sizing (`pmtiles extract --dry-run` against the 2026-08-22 Protomaps daily planet build — 137.5 GB, z0–15, gzip MVT; dry-run sizes verified byte-exact against a real extract), a maplibre_gl 0.26.0/0.27.0 offline-API audit, and a PMTiles v3 spec review.

#### Measured sizes

| Extract | Tiles | Size |
|---|---|---|
| World overview, z0–6 | 3 400 | **45 MB** |
| World overview, z0–7 | 10 667 | 187 MB (z7 alone ≈ 142 MB — not worth it) |
| Bath, ~10 × 10 km town, z10–14 | 75 | **1.7 MB** (verified real download) |
| London, ~40 × 40 km metro, z10–14 | 727 | 33 MB |
| Lisbon, holiday-city bbox, z10–14 | 154 | 6.5 MB |
| Bath z15 top-up | 182 | +1.6 MB (+64 %) — each zoom roughly doubles a file |

"World coarse + every visited cluster detailed" ≈ 45 MB + ~2 MB per town + ~35 MB per major metro — realistically **50–150 MB total**, ~30× below the 1.5 GB GB z14 build and far under the old "few hundred MB" guess. A town extract completes in ~6 s over 20–40 HTTP range requests, and dry-run sizing is exact, so any UI/script can preview true numbers before downloading. Clusters extract at `--minzoom 10` (the overview owns z0–6; z7–9 gap tiles overzoom from z6, which is how rendering already works — the style's source maxzoom is 13).

#### Architecture verdicts

1. **MapLibre offline-region manager — rejected.** `downloadOfflineRegion` is style-*URL*-driven (Trail passes inline `styleString`; there is no URL) and its cache is keyed by exact resource URL — `pmtiles://` sources fail natively, and the loopback binds a random port per launch so every cached key dies on restart. Using it means standing up a remote style + tile host (recurring metered cost) and abandoning sideloaded archives, the loopback, and the offline-only stance; plus one opaque `mbgl-offline.db`, a default 6 000-tile limit that *deletes a region mid-download*, and no cross-restart resume. 0.27.0 adds export/merge conveniences but changes none of this. Wholesale replacement, not composition.
2. **App-side PMTiles range fetcher — viable, deferred to Phase C.** `package:pmtiles` 2.2.0 (pure Dart, spec v3.6, verified publisher) does remote Range reads + batched tile fetch; per-tile cost amortises well (header+root dir = one 16 KB read per archive; Hilbert-ordered ids mean a bbox touches a handful of leaf dirs). But it re-implements on the phone what `pmtiles extract` already does on the VPS (~4–6 days of Dart incl. an HTTP retry/resume subsystem in an offline-first app), and Protomaps **forbids hotlinking daily builds as a live origin** (dated URLs 404 within a week), so it also needs a self-hosted planet: ~120 GB ≈ $2–3/mo on R2/Oracle Object Storage. Cost flag: the only option with a recurring bill.
3. **VPS extract job — chosen (Phase B).** ~100-line script, $0/mo, always-fresh daily OSM, zero new app-side fetch code (whole-archive `TileDownloader` + regions install already exist).

**Repo fact that shapes everything:** the only *working* local render path today is `.mbtiles` over the loopback server — `.pmtiles` regions fall through to `pmtiles://file://…`, which MapLibre Native 13.0.x silently fails on (`tile_server_provider.dart:8-16`, `trail_style.dart:62-63`). `pmtiles extract` emits `.pmtiles` and go-pmtiles converts only MBTiles→PMTiles, not back. Rather than converting on the VPS, teach the loopback to read `.pmtiles` via `package:pmtiles` (~1 day): it un-breaks local pmtiles regions generally, makes extract output directly installable, and is the exact dependency + tile-id plumbing Phase C would reuse. On-device the coverage store stays **MBTiles-schema SQLite** if Phase C ever writes one — PMTiles is append-hostile (fixed header, whole-directory re-encode, sections move on growth), while `(z,x,y)`-keyed SQLite gives dedupe and resume for free via `INSERT OR IGNORE`; the server already passes the gzip'd MVT blobs through verbatim.

#### Plan

- **Phase A — app: multi-archive loopback (~2 days, Dart-only).** `LocalTileServer` opens an ordered archive list and `_serveTile` falls through on miss: coverage extracts → active region → world overview. Style JSON untouched (still one source URL). Add the `.pmtiles` read path via `package:pmtiles`; `TilesService` grows role tags (overview / coverage / region) next to the active key; regions screen assigns roles. Unit-testable throughout (ffi pattern, CLAUDE.md gotcha 8); needs one on-device soak — loopback/MapLibre issues have historically only surfaced on device.
- **Phase B — VPS: coverage extract job (~1 day).** Script: cluster ping history (from a Trail export, or later the Timeline import file) into visit bboxes — `StatsService.detectTrips` logic + padding + overlap-merge — then per cluster `pmtiles extract --bbox … --minzoom 10 --maxzoom 14`, plus one world `--maxzoom 6` overview, against that day's Protomaps build; publish where `TileDownloader`/sideload can reach. Rerun on demand after trips or imports.
- **Phase C — in-app auto-fetch (commander's ask, 2026-08-22: "install relevant map tiles automatically when I import a timeline or go to a new place").** Not a self-hosted planet after all: the VPS runs `tools/coverage/server.py`, a token-protected HTTP service exposed through the already-present Tailscale Funnel (`https://portfolio-mcp.tail3b3dd1.ts.net:8443`), which answers `GET /v1/extract?bbox&minzoom&maxzoom` by running `pmtiles extract` against the newest daily build (seconds; cached by bbox/zoom/build date; bbox capped at ~1 square degree — big regions stay on GitHub releases). The app (`lib/services/coverage/`) keeps a prefs cache of installed-archive extents; the WorkManager tick notes any fix that no archive covers at z ≥ 12; on the next app open/resume (Wi-Fi only by default) the pending points are clustered (same greedy-centroid → pad 3 km → merge rule as the VPS tool), dry-run sized, fetched as `coverage-<slug>-z7-14-<date>.pmtiles` and installed with the coverage role — so they are served by the multi-archive loopback with no new store. The Timeline import ends with "download map detail for N places (≈ X MB)?"; Settings has the server URL + token, the auto/Wi-Fi toggles and a manual "fetch detail for my pins" button. Protomaps' daily build is never contacted from the phone (their terms: extracts yes, live origin no); the bbox of a new place goes only to the commander's own VPS over TLS.

Ordering: Phases A + B ship **before or with the 0.16.0 Timeline import** so imported non-UK points land on real tiles, per the blocker in § 2 above.

#### Corrections found while building Phase A (2026-08-22, late session)

1. **MapLibre does not overzoom a 404 inside the source's zoom range.** Verified in maplibre-native (`src/mln/tile/tile_loader_impl.hpp`: `NotFound` → `tile.setData(nullptr)`; `geometry_tile_worker.cpp` parses the empty tile and `GeometryTile::onLayout` marks it `renderable`). An absent tile renders as *empty*, not as its parent — parent fallback only exists above the source `maxzoom`. The "z7–9 gap tiles overzoom from z6" assumption above was wrong, and with one style source there is one `maxzoom` for archives that stop at 6, 13 and 14. Phase A therefore does the overzoom **server-side**: on a miss the loopback finds the nearest ancestor tile in any archive, scales + translates + clips its MVT geometry into the requested child (`lib/services/tiles/mvt_overzoom.dart`, pure Dart, unit-tested) and serves that. Consequences: the style source `maxzoom` is rewritten to the max over served archives; coverage extracts may still start at z7 rather than z10 for crispness (z7–9 from z6 is coarse but present, never blank); a z13 region now renders at z14 where a z14 coverage file exists next to it.
2. **Tile schema.** `docs/TILES.md` builds regions with planetiler in the **OpenMapTiles** schema (layers `transportation`, `place`, `landuse`, …) and the bundled OSM Liberty style only renders that schema. The sizing above was measured against the **Protomaps basemap** planet, whose layer names differ (`roads`, `places`, `landuse`, `earth`, …). The byte sizes still hold as estimates, but Phase B cannot simply `pmtiles extract` from the Protomaps build into the current style. Phase A is schema-agnostic (it serves whatever the archives hold), so it ships regardless. Phase B needs one of:
   - **(a) Stay OpenMapTiles.** Clusters: planetiler with `--bounds` on the Geofabrik country extract that contains each cluster (cheap, minutes). World overview z0–6: planetiler needs the planet PBF (~80 GB download, hours, ~24 GB RAM with `--storage=mmap`) — a one-off that rarely needs refreshing — *or* a one-off Python pass translating the 45 MB Protomaps z0–6 extract into OMT layer names/attributes (lossy mapping, ~300 lines, brittle).
   - **(b) Switch to the Protomaps basemap schema + style (recommended).** One pipeline (`pmtiles extract` against the daily planet) produces overview, coverage *and* the UK region from the same source, always fresh, no Java/planetiler on the VPS. Cost: bundle the Protomaps `dark` style + its Noto Sans glyphs/sprite (a few MB of assets), re-check the pin/heatmap layer ordering against the new layer ids, and re-extract the UK region once (~600 MB at z13, sideloaded like today). The OMT region keeps working until then because Phase A serves both schemas — it just renders with the style that matches it.
   Decision for the commander; nothing in Phase A depends on it.

## Decisions (locked 2026-08-22)

Import — decided, apply when 0.16.0 starts:
- Default thinning preset: **Normal (15 min / 250 m)**.
- Imported rows are **map-only** — they do not count in the stats heatmap (stats stay real Trail data).
- Legacy Takeout formats: **skip** unless an old zip turns up.
- Release slot: after 0.14.x perf work → 0.16.0.

Map coverage (§ 3 above) — decided:
- World overview zoom: **z0–6 (45 MB)**. z7 not worth 142 MB.
- Cluster detail maxzoom: **14**.
- Phase A slot: **folded into 0.15.0** with the maplibre_gl 0.27.0 upgrade (shipped as 0.15.0+97 — multi-archive loopback, `.pmtiles` read path, roles, server-side overzoom).
- Phase B publish channel: **private GitHub release asset** on this repo ($0, `gh` already wired, versioned; `TileDownloader` can fetch it by URL).

Decided later the same night (commander, 2026-08-22):
- Phase B tile schema: **(b) switch to the Protomaps basemap schema + dark style**; the UK region is re-extracted from the daily planet. The bundled OSM Liberty style stays in the app as a second style so existing OpenMapTiles archives keep rendering; the style follows the schema of the served archives.
- Coverage extract minzoom: **7**.
- Publish channel detail: `DazedDingo/trail` is public, so coverage packs (they outline where you have been) go to a **private** repo's releases; the world overview and the UK region are plain OSM and may sit on the public trail releases.
