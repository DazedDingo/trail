# Building offline `.pmtiles` for Trail

Trail's map viewer reads `.pmtiles` (single-file vector tile archives,
[Protomaps spec](https://docs.protomaps.com/pmtiles/)) from the app's
documents directory. Build one on your PC, push it to the phone,
install via **Settings → Offline map → Regions → Install**, and then
set it as active. The viewer renders a placeholder until a region is
active; the app is offline-only and there is no online tile fallback.

This doc is the one-time build pipeline — nothing here runs on the
phone. Switched from raster MBTiles to vector PMTiles in 0.7.2+28; if
you have an old `.mbtiles` file lying around it won't load any more.

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
won't match the layer names in `style.json`.

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
