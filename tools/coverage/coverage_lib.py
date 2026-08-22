"""Pure logic for the Trail coverage-extract job (Phase B, docs/TIMELINE_IMPORT.md §3).

No I/O, no subprocess, no network here — that all lives in extract.py. Keeping
this module pure means every rule (clustering, padding, merging, exclusion,
slugging, argv-building) is unit-testable without a pmtiles binary or a
network connection.
"""

from __future__ import annotations

import csv
import io
import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Fixes (a single lat/lon/timestamp reading from a Trail export)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Fix:
    ts: str
    lat: float
    lon: float


# BBox is always (west, south, east, north) — i.e. (min_lon, min_lat, max_lon,
# max_lat) — matching pmtiles' own --bbox order.
BBox = Tuple[float, float, float, float]


# ---------------------------------------------------------------------------
# Parsing the app's export formats
# ---------------------------------------------------------------------------


def parse_csv_fixes(text: str) -> List[Fix]:
    """Parses Trail's CSV export (see lib/services/export/csv_exporter.dart).

    Header: timestamp_utc,lat,lon,accuracy_m,altitude_m,heading_deg,
    speed_mps,battery_pct,network_state,cell_id,wifi_ssid,source,note

    Rows with an empty lat or lon (no-fix rows) are skipped.
    """
    fixes: List[Fix] = []
    reader = csv.DictReader(io.StringIO(text))
    for row in reader:
        lat_raw = (row.get("lat") or "").strip()
        lon_raw = (row.get("lon") or "").strip()
        if not lat_raw or not lon_raw:
            continue
        fixes.append(
            Fix(ts=row.get("timestamp_utc", ""), lat=float(lat_raw), lon=float(lon_raw))
        )
    return fixes


def parse_gpx_fixes(text: str) -> List[Fix]:
    """Parses Trail's GPX export (see lib/services/export/gpx_exporter.dart).

    Trail emits <wpt lat="..." lon="..."><time>...</time></wpt> elements
    (no-fix rows are never written — GPX requires coordinates on <wpt>).
    <trkpt> is also accepted for forward-compatibility with a future
    track-based exporter; the shape is identical.
    """
    root = ET.fromstring(text)
    fixes: List[Fix] = []
    for el in root.iter():
        tag = el.tag.rsplit("}", 1)[-1]
        if tag not in ("wpt", "trkpt"):
            continue
        lat_raw = el.get("lat")
        lon_raw = el.get("lon")
        if not lat_raw or not lon_raw:
            continue
        ts = ""
        for child in el:
            if child.tag.rsplit("}", 1)[-1] == "time":
                ts = child.text or ""
                break
        fixes.append(Fix(ts=ts, lat=float(lat_raw), lon=float(lon_raw)))
    return fixes


def parse_export_text(text: str) -> List[Fix]:
    """Auto-detects CSV vs GPX from content and parses accordingly."""
    stripped = text.lstrip()
    if stripped.startswith("<?xml") or stripped.startswith("<gpx"):
        return parse_gpx_fixes(text)
    return parse_csv_fixes(text)


def parse_export_file(path: str) -> List[Fix]:
    with open(path, "r", encoding="utf-8") as f:
        return parse_export_text(f.read())


# ---------------------------------------------------------------------------
# Haversine
# ---------------------------------------------------------------------------

EARTH_RADIUS_KM = 6371.0088
KM_PER_DEG_LAT = 111.32


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(min(1.0, math.sqrt(a)))


# ---------------------------------------------------------------------------
# Clustering
# ---------------------------------------------------------------------------


@dataclass
class Cluster:
    fixes: List[Fix] = field(default_factory=list)

    @property
    def centroid(self) -> Tuple[float, float]:
        n = len(self.fixes)
        return (sum(f.lat for f in self.fixes) / n, sum(f.lon for f in self.fixes) / n)

    @property
    def raw_bbox(self) -> BBox:
        lats = [f.lat for f in self.fixes]
        lons = [f.lon for f in self.fixes]
        return (min(lons), min(lats), max(lons), max(lats))


def cluster_fixes(fixes: Iterable[Fix], cluster_km: float) -> List[Cluster]:
    """Greedy centroid clustering.

    A fix joins the first existing cluster whose *running* centroid (mean of
    the fixes already in it) is within cluster_km (haversine); otherwise it
    starts a new cluster. Order-dependent by design — fixes are walked in
    the order given.
    """
    clusters: List[Cluster] = []
    for fix in fixes:
        placed = False
        for c in clusters:
            clat, clon = c.centroid
            if haversine_km(fix.lat, fix.lon, clat, clon) <= cluster_km:
                c.fixes.append(fix)
                placed = True
                break
        if not placed:
            clusters.append(Cluster(fixes=[fix]))
    return clusters


def pad_bbox_km(bbox: BBox, pad_km: float, at_lat: Optional[float] = None) -> BBox:
    """Pads a (W,S,E,N) bbox by pad_km, converting km to degrees at at_lat
    (defaults to the bbox's own mid-latitude)."""
    w, s, e, n = bbox
    lat = at_lat if at_lat is not None else (s + n) / 2
    dlat = pad_km / KM_PER_DEG_LAT
    cos_lat = math.cos(math.radians(lat))
    dlon = pad_km / (KM_PER_DEG_LAT * cos_lat) if cos_lat > 1e-9 else 180.0
    return (w - dlon, s - dlat, e + dlon, n + dlat)


def bboxes_overlap(a: BBox, b: BBox) -> bool:
    aw, as_, ae, an = a
    bw, bs, be, bn = b
    return aw <= be and bw <= ae and as_ <= bn and bs <= an


def union_bbox(a: BBox, b: BBox) -> BBox:
    aw, as_, ae, an = a
    bw, bs, be, bn = b
    return (min(aw, bw), min(as_, bs), max(ae, be), max(an, bn))


def bbox_inside(inner: BBox, outer: BBox) -> bool:
    iw, is_, ie, in_ = inner
    ow, os_, oe, on_ = outer
    return ow <= iw and is_ >= os_ and ie <= oe and in_ <= on_


ClusterBoxed = Tuple[List[Fix], BBox]


def merge_overlapping(clusters: Sequence[ClusterBoxed]) -> List[ClusterBoxed]:
    """Merges clusters whose (already padded) bboxes overlap, repeating
    until no pair overlaps. Merging unions both the fix lists and the
    bboxes (not a re-pad from the combined fixes)."""
    items = list(clusters)
    changed = True
    while changed:
        changed = False
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                if bboxes_overlap(items[i][1], items[j][1]):
                    merged_fixes = items[i][0] + items[j][0]
                    merged_bbox = union_bbox(items[i][1], items[j][1])
                    items = [items[k] for k in range(len(items)) if k not in (i, j)]
                    items.append((merged_fixes, merged_bbox))
                    changed = True
                    break
            if changed:
                break
    return items


def filter_excluded(
    clusters: Sequence[ClusterBoxed], exclude_bboxes: Sequence[BBox]
) -> List[ClusterBoxed]:
    """Drops any cluster whose bbox lies entirely inside one of the
    exclude_bboxes (the active region already covers it)."""
    if not exclude_bboxes:
        return list(clusters)
    return [
        c for c in clusters if not any(bbox_inside(c[1], ex) for ex in exclude_bboxes)
    ]


def build_coverage_clusters(
    fixes: Iterable[Fix],
    cluster_km: float,
    pad_km: float,
    exclude_bboxes: Optional[Sequence[BBox]] = None,
) -> List[ClusterBoxed]:
    """Full pipeline: cluster -> pad -> merge overlaps -> drop excluded.

    Returns a list of (fixes, padded/merged bbox) tuples.
    """
    raw_clusters = cluster_fixes(fixes, cluster_km)
    padded: List[ClusterBoxed] = [
        (c.fixes, pad_bbox_km(c.raw_bbox, pad_km)) for c in raw_clusters
    ]
    merged = merge_overlapping(padded)
    return filter_excluded(merged, exclude_bboxes or [])


# ---------------------------------------------------------------------------
# Slugs
# ---------------------------------------------------------------------------


def bbox_center(bbox: BBox) -> Tuple[float, float]:
    w, s, e, n = bbox
    return ((s + n) / 2, (w + e) / 2)  # (lat, lon)


def _fmt_deg(value: float, int_digits: int) -> str:
    width = int_digits + 3  # sign is added separately; width covers digits+'.'+2dp
    sign = "+" if value >= 0 else "-"
    return f"{sign}{abs(value):0{width}.2f}"


def slug_for_bbox(bbox: BBox) -> str:
    """lat<+/-dd.dd>_lon<+/-ddd.dd> of the bbox centre."""
    lat, lon = bbox_center(bbox)
    return f"lat{_fmt_deg(lat, 2)}_lon{_fmt_deg(lon, 3)}"


def resolve_cluster_name(bbox: BBox, names: Optional[Dict[str, str]] = None) -> str:
    slug = slug_for_bbox(bbox)
    if names and slug in names:
        return names[slug]
    return slug


# ---------------------------------------------------------------------------
# Region presets (approximate, 1-decimal precision — see README)
# ---------------------------------------------------------------------------

# All bboxes are (west, south, east, north) i.e. (min_lon, min_lat, max_lon, max_lat).
PRESETS: Dict[str, BBox] = {
    "uk": (-8.7, 49.8, 1.9, 60.9),
    "gb": (-8.2, 49.8, 1.9, 60.9),
    "ireland": (-10.7, 51.4, -5.4, 55.4),
    "lake-district": (-3.4, 54.3, -2.7, 54.7),
    "snowdonia": (-4.2, 52.8, -3.6, 53.2),
    "cairngorms": (-4.1, 56.8, -3.0, 57.3),
    "portugal": (-9.6, 36.8, -6.1, 42.2),
    "iberia": (-9.6, 35.9, 3.4, 43.9),
}


def _fmt_num(x: float) -> str:
    """6dp is ~11cm of precision — plenty for a bbox — and trims trailing
    zeros so plan-table output stays readable (padded/merged bboxes are
    computed floats, not clean presets)."""
    s = f"{round(x, 6):.6f}".rstrip("0").rstrip(".")
    if s in ("", "-0"):
        s = "0"
    return s


def fmt_bbox(bbox: BBox) -> str:
    return ",".join(_fmt_num(x) for x in bbox)


def parse_bbox(text: str) -> BBox:
    parts = [float(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError(f"bbox must be W,S,E,N — got {text!r}")
    return (parts[0], parts[1], parts[2], parts[3])


# ---------------------------------------------------------------------------
# Planet URL resolution
# ---------------------------------------------------------------------------

PLANET_URL_TEMPLATE = "https://build.protomaps.com/{date}.pmtiles"


def planet_url_for_date(date: str) -> str:
    return PLANET_URL_TEMPLATE.format(date=date)


def candidate_dates(today, days: int = 7) -> List[str]:
    """today: a datetime.date. Returns YYYYMMDD strings, newest first."""
    import datetime as dt

    return [(today - dt.timedelta(days=i)).strftime("%Y%m%d") for i in range(days)]


def pick_planet_url(
    dates: Sequence[str], head: Callable[[str], bool]
) -> Optional[str]:
    """Returns the first URL (newest date first) for which head(url) is
    True, or None if none matched."""
    for date in dates:
        url = planet_url_for_date(date)
        if head(url):
            return url
    return None


def date_from_planet_url(url: str) -> Optional[str]:
    m = re.search(r"(\d{8})\.pmtiles", url)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# Output file naming
# ---------------------------------------------------------------------------


def overview_filename(date: str, maxzoom: int = 6) -> str:
    return f"overview-z0-{maxzoom}-{date}.pmtiles"


def region_filename(name: str, date: str, maxzoom: int = 13) -> str:
    return f"region-{name}-z0-{maxzoom}-{date}.pmtiles"


def coverage_filename(name: str, date: str, minzoom: int = 7, maxzoom: int = 14) -> str:
    return f"coverage-{name}-z{minzoom}-{maxzoom}-{date}.pmtiles"


# ---------------------------------------------------------------------------
# pmtiles extract argv builders (pure — no subprocess here)
# ---------------------------------------------------------------------------


def build_extract_argv(
    pmtiles_bin: str,
    input_path: str,
    output_path: str,
    *,
    bbox: Optional[BBox] = None,
    minzoom: Optional[int] = None,
    maxzoom: Optional[int] = None,
    dry_run: bool = False,
) -> List[str]:
    argv = [pmtiles_bin, "extract", input_path, output_path]
    if bbox is not None:
        argv.append(f"--bbox={fmt_bbox(bbox)}")
    if minzoom is not None:
        argv.append(f"--minzoom={minzoom}")
    if maxzoom is not None:
        argv.append(f"--maxzoom={maxzoom}")
    if dry_run:
        argv.append("--dry-run")
    return argv


_DRY_RUN_TILES_RE = re.compile(r"result tile entries (\d+)")
_DRY_RUN_SIZE_RE = re.compile(r"archive size of ([\d.]+)\s*([kKmMgG]?B)")


def parse_dry_run_stats(output: str) -> Tuple[Optional[int], Optional[str]]:
    """Parses go-pmtiles' `extract --dry-run` log output for the tile count
    and human-readable size, e.g.:
      "...Region tiles 124, result tile entries 124..."
      "...for an archive size of 2.7 MB"
    Returns (tiles, size_str); either may be None if not found.
    """
    tiles = None
    m = _DRY_RUN_TILES_RE.search(output)
    if m:
        tiles = int(m.group(1))
    size = None
    m2 = _DRY_RUN_SIZE_RE.search(output)
    if m2:
        size = f"{m2.group(1)} {m2.group(2)}"
    return tiles, size


# ---------------------------------------------------------------------------
# gh release argv builders (pure)
# ---------------------------------------------------------------------------


def build_release_view_argv(repo: str, tag: str) -> List[str]:
    return ["gh", "release", "view", tag, "-R", repo]


def build_release_create_argv(repo: str, tag: str, notes: Optional[str] = None) -> List[str]:
    return [
        "gh",
        "release",
        "create",
        tag,
        "-R",
        repo,
        "--title",
        tag,
        "--notes",
        notes or "",
    ]


def build_release_upload_argv(repo: str, tag: str, files: Sequence[str]) -> List[str]:
    return ["gh", "release", "upload", tag, *files, "-R", repo, "--clobber"]
