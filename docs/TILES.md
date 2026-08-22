# Offline map archives for Trail

Trail's map viewer reads `.pmtiles` (single-file vector tile archives,
[Protomaps spec](https://docs.protomaps.com/pmtiles/)) and `.mbtiles`
(SQLite) from the app's documents directory. Since **0.15.1** the
archives Trail ships and builds are **Protomaps basemap** extracts of the
daily planet build, rendered with the bundled Protomaps *dark* style;
archives in the older **OpenMapTiles** schema (planetiler builds, the
pre-0.15.1 catalog) still render — the app keeps OSM Liberty as a second
style and picks the style from the schema of the served archives.

Get an archive onto the phone one of four ways — **Settings → Offline
map → Regions → Add region**: pick a file, paste a URL, browse the
catalog (`docs/tilesets.json` → the `tilesets-v1` release), or build one
on demand (GitHub Actions, needs a PAT) — then give it a role. The viewer
renders a placeholder until at least one archive is installed; the app is
offline-only and there is no online tile fallback.

## Roles and how tiles are served (0.15.0+)

Every installed archive has a role, set from the row menu (the installer
guesses from the file name: `…overview…` → world overview,
`…coverage…` → coverage, anything else → region):

| Role | How many | Typical file | Purpose |
|---|---|---|---|
| **Region** | one *active* at a time | `gb-z13.pmtiles` (500 MB) | the big detailed archive for where you live |
| **Coverage** | any number, always served | `coverage-lisbon-z7-14.pmtiles` (6 MB) | detail around places you visited |
| **World overview** | usually one, always served | `overview-z0-6.pmtiles` (45 MB) | context for every pin on Earth |

All of them are served through one in-app loopback HTTP server
(`LocalTileServer`) — MapLibre's own `pmtiles://` / `mbtiles://` file
URLs never worked on Android, which is why `.pmtiles` regions rendered
nothing between 0.8.0 and 0.14.1. For each tile the server asks the
archives in order *coverage → active region → overview* and returns the
first hit. If **no** archive holds that tile, the server finds the
nearest coarser tile in any archive and overzooms it itself (scales,
translates and clips the vector geometry into the requested tile), so an
area that only the z0–6 overview covers still draws — coarse, never
blank. MapLibre would otherwise render a missing tile as empty: it only
overzooms past the source's `maxzoom`, which Trail sets to the highest
zoom any installed archive holds.

This doc is the one-time build pipeline — nothing here runs on the
phone. Switched from raster MBTiles to vector in 0.8.0+29; raster
`.mbtiles` files still won't render (the style expects vector layers),
but vector `.mbtiles` from planetiler work exactly like `.pmtiles`.

## Why vector

Vector tiles are 5–10× smaller than raster for the same coverage:
UK-wide is ~500 MB at z13 (paths/tracks/service roads visible) vs
~10+ GB raster at the same zoom. The MapLibre renderer parses the MVT
geometry on the phone and rasterises with the GPU — modern hardware
handles this trivially, and we get to restyle without rebaking.

## Pipeline (one tool: `pmtiles extract`)

Everything comes out of the Protomaps daily planet build
(`https://build.protomaps.com/YYYYMMDD.pmtiles`, ~137 GB, z0–15, basemap
schema v4.x). `pmtiles extract` pulls just the tiles for a bbox/zoom range
over HTTP range requests — seconds for a town, ~20 s for the UK at z13 —
and that is the sanctioned use (hotlinking the build as a live tile
source is not allowed; Trail never does).

| Extract | Flags | Size | Time (VPS) |
|---|---|---|---|
| World overview | `--maxzoom=6` | 45 MB | 4 s |
| UK region | `--bbox=-8.7,49.8,1.9,60.9 --maxzoom=13` | 738 MB | 21 s |
| UK at z14 | same, `--maxzoom=14` | 1.5 GB | — |
| Town coverage pack (Bath) | `--bbox=… --minzoom=7 --maxzoom=14` | 2.7 MB | 5 s |
| Lisbon | z7–14 | 7.7 MB | — |
| London metro | z7–14 | 60 MB | — |

Three ways to run it:

1. **VPS job — `tools/coverage/extract.py`** (stdlib Python, README in
   that folder). `planet` resolves the newest build; `overview`, `region
   --preset uk`, and `coverage --export trail.csv` (clusters your ping
   history into visit bboxes, dry-run sizes first) produce files named so
   the app auto-tags their role; `publish` uploads to a release.
   Coverage packs outline where you have been — publish those only to a
   private repo and install them from the phone's browser download; the
   overview and regions are plain OSM and live on the public
   `tilesets-v1` release.
2. **GitHub Actions — `build-region.yml`** (the in-app "build on
   demand" flow): name + bbox + min/max zoom → extract → `tilesets-v1`
   asset + catalog entry.
3. **By hand:** `pmtiles extract https://build.protomaps.com/$(date -u
   +%Y%m%d).pmtiles out.pmtiles --bbox=W,S,E,N --maxzoom=13` (go-pmtiles
   CLI; the VPS has v1.31.2 at `~/tools/pmtiles`).

Zoom guidance for the basemap schema: z13 shows tracks and service
roads; z14 adds footways and individual buildings. Regions: z13 UK-wide;
coverage packs: z7–14 (z7–9 is cheap and keeps the transition from the
z6 overview crisp — without it those zooms are drawn from overzoomed z6
tiles, present but coarse).

### Legacy: planetiler / OpenMapTiles

Before 0.15.1 regions were built with planetiler from Geofabrik extracts
(OpenMapTiles schema, OSM Liberty style). Those files still work — the
app auto-selects the matching style — but don't mix schemas in one
served set: only the chosen schema's archives draw fully. To rebuild one:
`java -Xmx8g -jar planetiler.jar --osm-path=great-britain-latest.osm.pbf
--output=gb-z13.pmtiles --maxzoom=13 --force --download` (Java 21).

## Style

The bundled styles have no remote dependencies — fully offline once an
archive is installed.

The style's `openmaptiles` source URL is a placeholder string
(`pmtiles://__TRAIL_ACTIVE_REGION__`) rewritten at runtime by
`TrailStyle.loadForRegion` to point at the absolute file path of the
active region. If you ever swap the bundled style for a different one
(positron, osm-bright, custom), keep that placeholder convention or
the runtime substitution won't work.

Two styles are bundled and chosen automatically from the served
archives' `vector_layers`: `assets/maptiles/protomaps-dark.json`
(Protomaps basemap schema — `roads`, `places`, `earth`, …; generated by
`tools/style/gen_protomaps_style.mjs` from `@protomaps/basemaps`, Noto
Sans glyphs + the v4 dark sprite) and `assets/maptiles/style.json` (OSM
Liberty, OpenMapTiles schema, Roboto glyphs, `osm-liberty` sprite). Both
use the same placeholders. If you regenerate the Protomaps style, keep the
`__TRAIL_*` placeholders and the `protomaps` source name.

## Backup behaviour

`<appDocumentsDir>/tiles/` is `<exclude>`d from
`backup_rules.xml` and `data_extraction_rules.xml`. Vector packs run
50–700 MB, way over Android's 25 MB per-app cloud-backup quota. After
a restore the user re-sideloads via the regions screen — the
encrypted ping DB is what auto-backup actually preserves.

## Verifying the file

The PMTiles header is plain bytes; Python can parse it:

```python
import struct, json, gzip
with open('gb-z13.pmtiles','rb') as f:
    head = f.read(127)
    assert head[0:7] == b'PMTiles'
    spec_v = head[7]
    fields = struct.unpack('<QQQQQQQQQQQQQQ', head[8:8+14*8])
    md_offset, md_len = fields[2], fields[3]
    f.seek(md_offset)
    meta = json.loads(gzip.decompress(f.read(md_len)))
    print(spec_v, meta['name'], [l['id'] for l in meta['vector_layers']])
```

Should report spec version 3, `OpenMapTiles`, and the standard layer
list (`aerodrome_label`, `aeroway`, `boundary`, `building`, `housenumber`,
`landcover`, `landuse`, `mountain_peak`, `park`, `place`, `poi`,
`transportation`, `transportation_name`, `water`, `water_name`,
`waterway`).
