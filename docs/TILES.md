# Building offline `.pmtiles` for Trail

Trail's map viewer reads `.pmtiles` (single-file vector tile archives,
[Protomaps spec](https://docs.protomaps.com/pmtiles/)) and `.mbtiles`
(SQLite) from the app's documents directory. Build one on your PC, push
it to the phone, install via **Settings → Offline map → Regions →
Install**, and give it a role. The viewer renders a placeholder until
at least one archive is installed; the app is offline-only and there is
no online tile fallback.

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

## Pipeline (one tool: planetiler)

`planetiler` produces PMTiles directly from an OSM `.pbf` extract. No
secondary rasterisation step.

### 1. Install Java 21 and download the planetiler jar

Java 17 is too old; planetiler is compiled for Java 21+.

```bash
sudo apt install openjdk-21-jre-headless          # or sdkman / brew
mkdir -p ~/tools
curl -sL -o ~/tools/planetiler.jar \
  https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
```

### 2. Grab a Geofabrik extract

```bash
mkdir -p ~/maps/build && cd ~/maps/build
curl -sLO https://download.geofabrik.de/europe/great-britain-latest.osm.pbf
```

For region-only builds (Lake District, Snowdonia, Highlands etc.), grab
a smaller sub-extract from Geofabrik or use a `.poly` file with
`--polygon`.

### 3. Run planetiler

```bash
java -Xmx8g -jar ~/tools/planetiler.jar \
  --osm-path=great-britain-latest.osm.pbf \
  --output=gb-z13.pmtiles \
  --maxzoom=13 \
  --force --download
```

Reasonable zoom caps:

| `--maxzoom` | Visible at top zoom            | UK-wide PMTiles size |
|-------------|--------------------------------|----------------------|
| `12`        | major roads, no paths          | ~300 MB              |
| `13`        | tracks, service roads          | ~500 MB              |
| `14`        | individual paths, footways     | ~1.5 GB              |

For a *trail* app you want at least z13. The OpenMapTiles schema only
emits `path`/`footway` features at z14+, so z14 is necessary if you
want every hiking trail rendered — but UK-wide z14 is probably too big
to ship per-file. Region-only z14 builds (Lake District, Snowdonia)
land in the 50–150 MB range and are the recommended workflow.

Planetiler writes ~6 GB of intermediate state to `data/tmp/` while
processing; clean up afterwards if disk is tight.

### 4. Sideload to the phone

Get the file onto the device's storage (SAF-accessible location). USB
transfer, ADB push, or any cloud-sync tool that lands the file
somewhere the file picker can reach.

In the app: **Settings → Offline map → Regions → Install**. The picker
filters for `.pmtiles`. The file is copied into
`<appDocumentsDir>/tiles/` so the original is no longer needed and SAF
URI expiry can't break the viewer.

## Style

The app ships **OSM Liberty** (`assets/maptiles/style.json`) bundled
with its sprites and Roboto Regular/Medium/Condensed Italic glyph
PBFs (Latin + extended Latin ranges). The bundled style has no remote
dependencies — fully offline once a region is installed.

The style's `openmaptiles` source URL is a placeholder string
(`pmtiles://__TRAIL_ACTIVE_REGION__`) rewritten at runtime by
`TrailStyle.loadForRegion` to point at the absolute file path of the
active region. If you ever swap the bundled style for a different one
(positron, osm-bright, custom), keep that placeholder convention or
the runtime substitution won't work.

Use the **OpenMapTiles** schema (planetiler's default) — anything else
won't match the layer names in `style.json`. In particular the Protomaps
daily planet builds are the *Protomaps basemap* schema (`roads`,
`places`, `earth`, …): they install and serve fine, but OSM Liberty
only draws their `water`/`landuse` layers. See `docs/TIMELINE_IMPORT.md`
§ 3 "Corrections" for the pending choice between staying on
OpenMapTiles and switching the bundled style.

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
