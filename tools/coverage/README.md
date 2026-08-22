# tools/coverage — Phase B coverage-extract job

Builds `.pmtiles` archives for Trail's offline map viewer from the daily
Protomaps planet build (`https://build.protomaps.com/YYYYMMDD.pmtiles`,
Protomaps basemap schema — see `docs/TIMELINE_IMPORT.md` §3). Run this on
the VPS, not on the phone; the resulting files are sideloaded into the app
(`Settings → Offline map → Regions`) or fetched by `TileDownloader` from a
GitHub release URL.

Stdlib-only Python 3. The one third-party binary it drives is
[`go-pmtiles`](https://github.com/protomaps/go-pmtiles)'s `pmtiles` CLI
(`--pmtiles-bin`, default `~/tools/pmtiles`).

**Terms:** creating extracts with `pmtiles extract` against the daily
planet build is the intended, supported use. **Never** hotlink a dated
build URL as a live tile source in the app or anywhere else — Protomaps
does not support that, and dated URLs 404 within about a week anyway. This
tool only ever writes local `.pmtiles` files.

## The three archive kinds

Trail's `TilesService` auto-tags an archive by its file name, so the
naming below isn't cosmetic:

| Kind | Role in the app | File name | Zoom | Typical size |
|---|---|---|---|---|
| `overview` | World overview (every pin has context, everywhere) | `overview-z0-<maxzoom>-YYYYMMDD.pmtiles` | z0–6 | ~45 MB |
| `region` | The one active region (detailed area, e.g. the UK) | `region-<name>-z0-<maxzoom>-YYYYMMDD.pmtiles` | z0–13 | see `--dry-run` (UK z13 is hundreds of MB) |
| `coverage` | High-zoom detail around a visited cluster | `coverage-<slug-or-name>-z<minzoom>-<maxzoom>-YYYYMMDD.pmtiles` | z7–14 (defaults) | ~2 MB/town, ~35 MB/metro |

File names must contain `overview` / `coverage` (and region files contain
`region`) — the app's role auto-detection depends on this.

## Subcommands

```
extract.py planet                      # print the newest build.protomaps.com URL
extract.py overview --out DIR [--maxzoom 6]
extract.py region (--preset uk|gb|ireland|lake-district|snowdonia|cairngorms|portugal|iberia
                    | --bbox W,S,E,N --name NAME) [--maxzoom 13] --out DIR
extract.py coverage --export FILE.csv|.gpx [--minzoom 7] [--maxzoom 14]
                     [--cluster-km 15] [--pad-km 3]
                     [--exclude-preset uk]... [--exclude-bbox W,S,E,N]...
                     --out DIR [--names names.json]
extract.py publish --repo OWNER/NAME --tag TAG [--notes TEXT] FILES...
```

Common flags on the extraction subcommands: `--planet URL` (skip
auto-pick), `--date YYYYMMDD` (override the file-name date; default is the
date embedded in the resolved planet URL), `--pmtiles-bin PATH` (default
`~/tools/pmtiles`).

`overview`, `region` and `coverage` all print the exact command before
running it and support `--dry-run` (stop before the real extract).
`coverage` additionally prints a plan table — cluster name, fix count,
bbox, and (when the pmtiles binary is present) the tile count + size from
`pmtiles extract --dry-run` — **before** extracting, dry-run or not.

Region preset bboxes (`W,S,E,N`) are **approximate**, 1-decimal precision,
looked up by hand — good enough for a coverage pass, not a legal boundary:

```
uk             -8.7, 49.8,  1.9, 60.9
gb             -8.2, 49.8,  1.9, 60.9
ireland       -10.7, 51.4, -5.4, 55.4
lake-district  -3.4, 54.3, -2.7, 54.7
snowdonia      -4.2, 52.8, -3.6, 53.2
cairngorms     -4.1, 56.8, -3.0, 57.3
portugal       -9.6, 36.8, -6.1, 42.2
iberia         -9.6, 35.9,  3.4, 43.9
```

### `coverage` clustering

Fixes are read from a Trail CSV or GPX export (auto-detected; both formats
skip no-fix/coordinate-less rows already). Algorithm:

1. **Greedy centroid clustering** (haversine): a fix joins the first
   existing cluster whose running centroid is within `--cluster-km`,
   else it starts a new cluster.
2. Each cluster's bbox (of its raw fixes) is **padded** by `--pad-km`,
   converting km to degrees at that bbox's own latitude.
3. Padded bboxes that **overlap are merged** (repeated until stable).
4. Any cluster **entirely inside** an `--exclude-preset` / `--exclude-bbox`
   is **dropped** — the active region already covers it.
5. Each surviving cluster gets a slug `lat<±dd.dd>_lon<±ddd.dd>` from its
   bbox centre, or a friendly name from `--names names.json`
   (`{"lat+51.38_lon-002.36": "bath"}`).

## Typical session

```bash
# 1. Export from the app (Home → Export, or the archive flow) and copy it over.
scp trail_export_*.csv vps:~/trail-export.csv

# 2. Find today's build.
python3 extract.py planet

# 3. Preview the coverage plan (no network writes beyond dry-run probes).
python3 extract.py coverage --export ~/trail-export.csv --dry-run \
    --exclude-preset uk --out ~/coverage-out

# 4. Actually extract.
python3 extract.py coverage --export ~/trail-export.csv \
    --exclude-preset uk --out ~/coverage-out

# 5. Publish. Coverage packs go to a PRIVATE repo (see below); overview/
#    region archives can go on the public trail repo's releases.
python3 extract.py publish --repo yourname/trail-coverage-private \
    --tag coverage-20260822 ~/coverage-out/coverage-*.pmtiles
```

Re-run `coverage` whenever new trips/imports land — clustering is
idempotent on the same export plus the exclusion of the active region, so
re-running mostly regenerates the same files (new `YYYYMMDD` in the name
each day, since it always targets the current planet build unless
`--planet`/`--date` pin it).

## Privacy

**Coverage packs outline where the user has been** — their bboxes are
literally a map of visited places. Publish them **only** to a private
GitHub repo's releases. `overview` and `region` archives are plain OSM
data with no user information in them and are fine on the public
`DazedDingo/trail` releases.

## Size expectations

- World overview z0–6: **~45 MB** (measured).
- A town-sized coverage cluster: **~2 MB** (measured, Bath ~10×10 km,
  z10–14; a z7–14 extract is a little larger since it adds low zooms).
- UK region at z13: hundreds of MB — always check `--dry-run` for the
  exact number before committing to a download; it's byte-exact versus a
  real extract.

## Extract service

`server.py` is the on-demand half of the same job: a small localhost HTTP
service that hands the app a coverage extract for a bbox it asks for,
instead of the commander running `extract.py coverage` by hand and
sideloading the result (Phase C of `docs/TIMELINE_IMPORT.md` §3). Same
`pmtiles extract`, same Protomaps daily build, same file naming — only the
trigger changes.

Stdlib-only, single file, no framework. It binds `127.0.0.1:8766`; exposing
it to the phone is the tailnet's job, not the service's.

### Endpoints

| Route | Auth | Returns |
|---|---|---|
| `GET /v1/health` | no | `{"ok": true, "planet": "<url or null>", "planetDate": "YYYYMMDD", "version": "1"}` |
| `GET /v1/planet` | yes | `{"url": …, "date": …}` |
| `GET /v1/extract?bbox=W,S,E,N&minzoom=7&maxzoom=14` | yes | the `.pmtiles` file |
| `GET /v1/extract?…&dry_run=1` | yes | `{"tiles": n, "bytes": n, "size": "2.7 MB", "planetDate": …}` |

`HEAD` works on all three (same headers, no body — note that a `HEAD` on
`/v1/extract` still does the extract, since that's the only way to know
`Content-Length`). `Range` requests are **not** supported; the archives are
small enough to fetch whole, and `TileDownloader` already retries.

Errors are always `{"error": "..."}` with a real status code:

| Status | When |
|---|---|
| 400 | bbox isn't 4 finite numbers, W≥E, S≥N, \|lat\|>85, \|lon\|>180, non-integer zoom, zoom outside 0–15, minzoom>maxzoom, unparseable `dry_run` |
| 401 | missing or wrong bearer token |
| 404 | unknown route |
| 413 | bbox area > 1.0 square degrees — build region-sized archives offline with `extract.py region` and publish them to a release |
| 429 | more than 120 requests per 10 minutes on one token (`Retry-After` set) |
| 502 | `pmtiles extract` exited non-zero, wrote nothing, or printed unparseable dry-run output |
| 503 | no Protomaps daily build reachable, or waited 60 s for an extract slot |
| 504 | `pmtiles extract` exceeded the 300 s timeout |

File responses carry `Content-Type: application/octet-stream`,
`Content-Length`, `X-Planet-Date`, `X-Cache: HIT|MISS` and
`Content-Disposition: attachment; filename="coverage-<slug>-z<min>-<max>-<date>.pmtiles"`
(the slug is `coverage_lib`'s, so a served file is named exactly as the
equivalent `extract.py coverage` output). The body is streamed in 1 MiB
chunks.

### Behaviour

- **Disk cache** at `~/maps/cache/` (`--cache-dir`), keyed by
  `sha1("W,S,E,N|min-max|planetdate")` with the bbox rounded to 4 dp (~11 m,
  so a phone that recomputes a cluster centroid slightly differently still
  hits the same entry). A new planet build changes every key, which is how
  the cache expires. Extracts land on a `.partial` file and are renamed into
  place, so a crashed run never leaves a half-file to be served.
- **Single-flight**: concurrent requests for the same key wait on one
  extract rather than starting N of them.
- **Concurrency cap**: at most 2 extracts (including dry-runs) run at once;
  others wait up to 60 s and then get a 503.
- **Dry-run answers** are cached in memory for 1 h — a preview costs one
  round trip, not a re-probe per swipe.
- **Planet resolution** (`pick_planet_url` + a HEAD probe) is cached for 1 h;
  a failed resolution is retried after 60 s rather than being pinned for the
  hour.
- **Rate limit**: 120 requests / 10 min per token, sliding window.
- One log line per request on stdout: method, path, status, ms, bytes. The
  token is never logged (a `token=` query param would be redacted too).

### Setup

```bash
# 1. Create the bearer token (0600, printed once — copy it into the app).
python3 server.py --init-token          # ~/.config/trail-tiles/token

# 2. Install as a systemd user unit.
mkdir -p ~/.config/systemd/user
cp trail-tiles.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now trail-tiles
loginctl enable-linger ubuntu           # survive logout / reboot

# 3. Check it.
curl -s localhost:8766/v1/health
curl -s -H "Authorization: Bearer $(cat ~/.config/trail-tiles/token)" \
  'localhost:8766/v1/extract?bbox=-2.45,51.33,-2.28,51.43&minzoom=7&maxzoom=14&dry_run=1'
journalctl --user -u trail-tiles -f
```

Flags: `--host`, `--port`, `--cache-dir`, `--pmtiles-bin`, `--token-file`,
`--planet URL` (pin the build, skipping auto-pick), `--init-token`.
`SIGTERM` shuts down gracefully, so `systemctl --user restart` is clean.

Measured on the VPS (Bath, `bbox=-2.45,51.33,-2.28,51.43`, z7–14):
dry-run 3.7 s → 124 tiles / 2.7 MB; real extract 5.9 s → 2 700 354 bytes;
cached repeat 0.2 s.

### Tests

```bash
cd tools/coverage && python3 -m unittest -v
```

`test_server.py` covers validation, cache keys, naming, the rate limiter,
tokens and the extract service directly, plus an in-process HTTP test that
runs a real server on an ephemeral port with a fake `pmtiles` runner — no
network and no binary needed.
