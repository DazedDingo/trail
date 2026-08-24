#!/usr/bin/env python3
"""One-off: how many Wikimedia geosearch calls does the photo backfill
really need once pings are grouped spatially?

Usage:
    python3 tools/photo_backfill_cell_count.py trail_export.csv

Input: Trail's CSV export (Settings -> Export -> CSV), which has `lat`
and `lon` columns for every ping including imported Timeline pins.
No-fix rows (empty lat/lon) are skipped. Pings that already have photos
are NOT excluded (the export doesn't say), so every count here is a
slight upper bound.

Prints, for each candidate grid, the number of distinct cells the pings
collapse into, plus projected API calls and runtime at the current
1.1 s/call throttle. The "~1 km fetch groups" row models the planned
design: one geosearch (gsradius ~1000 m, gslimit 500) per group plus an
average of ~1.5 follow-up imageinfo batches, serving every 110 m cell
inside the disc.
"""
import csv, math, sys

def dart_round(x, decimals):
    # Mirror Dart's roundToDouble(): half away from zero (Python's round is banker's).
    f = 10 ** decimals
    y = x * f
    return (math.floor(y + 0.5) if y >= 0 else math.ceil(y - 0.5)) / f

_B32 = "0123456789bcdefghjkmnpqrstuvwxyz"
def geohash(lat, lon, precision):
    lat_r, lon_r = [-90.0, 90.0], [-180.0, 180.0]
    bits, ch, even, out = 0, 0, True, []
    while len(out) < precision:
        r = lon_r if even else lat_r
        v = lon if even else lat
        mid = (r[0] + r[1]) / 2
        ch <<= 1
        if v >= mid:
            ch |= 1
            r[0] = mid
        else:
            r[1] = mid
        even = not even
        bits += 1
        if bits == 5:
            out.append(_B32[ch]); bits, ch = 0, 0
    return "".join(out)

def main(path):
    pts = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rdr = csv.DictReader(fh)
        cols = {c.lower().strip(): c for c in rdr.fieldnames or []}
        if "lat" not in cols or "lon" not in cols:
            sys.exit(f"CSV has no lat/lon columns; found: {rdr.fieldnames}")
        for row in rdr:
            try:
                lat = float(row[cols["lat"]]); lon = float(row[cols["lon"]])
            except (TypeError, ValueError):
                continue  # no-fix row
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                continue
            pts.append((lat, lon))

    n = len(pts)
    print(f"pings with coordinates: {n}")
    if not n:
        return

    grids = []
    grids.append(("3-decimal cells (~110 m, current cache key)",
                  {(dart_round(a, 3), dart_round(o, 3)) for a, o in pts}))
    grids.append(("geohash-7 (~153 m x 153 m)", {geohash(a, o, 7) for a, o in pts}))
    grids.append(("geohash-6 (~1.22 km x 0.61 km)", {geohash(a, o, 6) for a, o in pts}))
    for km in (0.5, 1.0, 2.0):
        dlat = km / 111.32
        cells = set()
        for a, o in pts:
            dlon = km / (111.32 * max(0.087, math.cos(math.radians(a))))
            cells.add((math.floor(a / dlat), math.floor(o / dlon)))
        grids.append((f"~{km:g} km fetch groups", cells))

    throttle = 1.1
    print(f"\n{'grid':<44}{'cells':>8}{'calls':>8}{'runtime':>10}")
    naive = n * throttle
    print(f"{'today: one call per ping':<44}{n:>8}{n:>8}{naive/3600:>9.1f}h")
    for name, cells in grids:
        c = len(cells)
        # 1 geosearch per cell/group + avg 1.5 imageinfo batches (<=50 titles each)
        calls = math.ceil(c * 2.5)
        secs = calls * throttle
        rt = f"{secs/3600:.1f}h" if secs >= 3600 else f"{secs/60:.0f}m"
        print(f"{name:<44}{c:>8}{calls:>8}{rt:>10}")
    print("\ncalls = cells x 2.5 (1 geosearch + ~1.5 imageinfo batches); "
          f"runtime at {throttle}s/call.")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
