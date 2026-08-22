#!/usr/bin/env python3
"""Trail coverage-extract job (Phase B, docs/TIMELINE_IMPORT.md §3).

Builds .pmtiles archives (Protomaps basemap schema) from the daily
Protomaps planet build (https://build.protomaps.com/YYYYMMDD.pmtiles) via
the `pmtiles extract` CLI:

  - `overview`  a world z0-6 basemap (~45 MB), plain OSM.
  - `region`    a country/area extract (a preset or custom bbox), plain OSM.
  - `coverage`  one small high-zoom extract per visited-place cluster,
                derived from a Trail CSV/GPX export.

Creating extracts with the pmtiles CLI is the intended, ToS-compliant use
of the Protomaps daily build. Hotlinking a dated build URL as a live tile
source is NOT supported by Protomaps (dated URLs 404 within about a week)
and must never be done — this tool only ever produces local files.

Stdlib only. No third-party dependencies.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shlex
import subprocess
import sys
import urllib.request
from typing import List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from coverage_lib import (  # noqa: E402
    PRESETS,
    build_coverage_clusters,
    build_extract_argv,
    build_release_create_argv,
    build_release_upload_argv,
    build_release_view_argv,
    candidate_dates,
    coverage_filename,
    date_from_planet_url,
    fmt_bbox,
    overview_filename,
    parse_bbox,
    parse_dry_run_stats,
    parse_export_file,
    pick_planet_url,
    region_filename,
    resolve_cluster_name,
)

DEFAULT_PMTILES_BIN = os.path.expanduser("~/tools/pmtiles")


# ---------------------------------------------------------------------------
# Subprocess helper — the ONE place that shells out.
# ---------------------------------------------------------------------------


def run(
    argv: Sequence[str], dry_run: bool = False, capture: bool = False
) -> Optional[subprocess.CompletedProcess]:
    """Prints argv (shell-quoted, for humans) and, unless dry_run, runs it.
    Never uses shell=True. Returns None when dry_run is True."""
    print("$ " + " ".join(shlex.quote(str(a)) for a in argv))
    if dry_run:
        return None
    kwargs = {}
    if capture:
        kwargs["capture_output"] = True
        kwargs["text"] = True
    return subprocess.run(list(argv), check=False, **kwargs)


def http_head_ok(url: str, timeout: float = 10.0) -> bool:
    # build.protomaps.com's CDN 403s urllib's default User-Agent string.
    req = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": "Mozilla/5.0 (trail-coverage-extract)"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            return 200 <= resp.status < 300
    except Exception:
        return False


def resolve_planet(args: argparse.Namespace) -> str:
    if args.planet:
        return args.planet
    dates = candidate_dates(dt.datetime.now(dt.timezone.utc).date(), days=7)
    url = pick_planet_url(dates, http_head_ok)
    if url is None:
        print(
            "error: could not find a Protomaps daily build in the last 7 days "
            "(pass --planet URL to override)",
            file=sys.stderr,
        )
        sys.exit(1)
    return url


def resolve_date(args: argparse.Namespace, planet_url: str) -> str:
    if args.date:
        return args.date
    return date_from_planet_url(planet_url) or dt.datetime.now(
        dt.timezone.utc
    ).strftime("%Y%m%d")


# ---------------------------------------------------------------------------
# planet
# ---------------------------------------------------------------------------


def cmd_planet(args: argparse.Namespace) -> int:
    dates = candidate_dates(dt.datetime.now(dt.timezone.utc).date(), days=args.days)
    url = pick_planet_url(dates, http_head_ok)
    if url is None:
        print(
            f"No Protomaps daily build found in the last {args.days} days.",
            file=sys.stderr,
        )
        return 1
    print(url)
    return 0


# ---------------------------------------------------------------------------
# overview
# ---------------------------------------------------------------------------


def cmd_overview(args: argparse.Namespace) -> int:
    planet = resolve_planet(args)
    date = resolve_date(args, planet)
    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, overview_filename(date, args.maxzoom))
    argv = build_extract_argv(args.pmtiles_bin, planet, out_path, maxzoom=args.maxzoom)
    print(f"plan: world overview z0-{args.maxzoom} -> {out_path}")
    if args.dry_run:
        print("[dry-run] stopping before extract")
        return 0
    result = run(argv)
    return 0 if result is None or result.returncode == 0 else result.returncode


# ---------------------------------------------------------------------------
# region
# ---------------------------------------------------------------------------


def cmd_region(args: argparse.Namespace) -> int:
    if args.preset:
        if args.preset not in PRESETS:
            print(
                f"error: unknown preset {args.preset!r} (known: "
                f"{', '.join(sorted(PRESETS))})",
                file=sys.stderr,
            )
            return 2
        bbox = PRESETS[args.preset]
        name = args.name or args.preset
    else:
        if not args.bbox:
            print("error: pass either --preset or --bbox", file=sys.stderr)
            return 2
        if not args.name:
            print("error: --name is required with --bbox", file=sys.stderr)
            return 2
        bbox = parse_bbox(args.bbox)
        name = args.name

    planet = resolve_planet(args)
    date = resolve_date(args, planet)
    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, region_filename(name, date, args.maxzoom))
    argv = build_extract_argv(
        args.pmtiles_bin, planet, out_path, bbox=bbox, maxzoom=args.maxzoom
    )
    print(f"plan: region {name} {fmt_bbox(bbox)} z0-{args.maxzoom} -> {out_path}")
    if args.dry_run:
        print("[dry-run] stopping before extract")
        return 0
    result = run(argv)
    return 0 if result is None or result.returncode == 0 else result.returncode


# ---------------------------------------------------------------------------
# coverage
# ---------------------------------------------------------------------------


def cmd_coverage(args: argparse.Namespace) -> int:
    fixes = parse_export_file(args.export)
    if not fixes:
        print(f"error: no fixes with coordinates found in {args.export}", file=sys.stderr)
        return 2

    exclude_bboxes = []
    for preset in args.exclude_preset or []:
        if preset not in PRESETS:
            print(f"error: unknown exclude-preset {preset!r}", file=sys.stderr)
            return 2
        exclude_bboxes.append(PRESETS[preset])
    for bbox_str in args.exclude_bbox or []:
        exclude_bboxes.append(parse_bbox(bbox_str))

    names = {}
    if args.names:
        if os.path.exists(args.names):
            with open(args.names, "r", encoding="utf-8") as f:
                names = json.load(f)
        else:
            print(f"warning: --names {args.names} not found, ignoring", file=sys.stderr)

    clusters = build_coverage_clusters(
        fixes, args.cluster_km, args.pad_km, exclude_bboxes
    )
    if not clusters:
        print("No clusters left after exclusions — nothing to extract.")
        return 0

    planet = resolve_planet(args)
    date = resolve_date(args, planet)
    os.makedirs(args.out, exist_ok=True)

    bin_exists = os.path.exists(args.pmtiles_bin)

    plan = []
    header = f"{'cluster':<24} {'fixes':>6}  {'bbox':<42} {'tiles':>8}  {'size':>10}"
    print(header)
    print("-" * len(header))
    for cluster_fixes_list, bbox in clusters:
        name = resolve_cluster_name(bbox, names)
        out_path = os.path.join(
            args.out, coverage_filename(name, date, args.minzoom, args.maxzoom)
        )
        extract_argv = build_extract_argv(
            args.pmtiles_bin,
            planet,
            out_path,
            bbox=bbox,
            minzoom=args.minzoom,
            maxzoom=args.maxzoom,
        )
        tiles_str, size_str = "?", "?"
        if bin_exists:
            probe_argv = build_extract_argv(
                args.pmtiles_bin,
                planet,
                os.devnull,
                bbox=bbox,
                minzoom=args.minzoom,
                maxzoom=args.maxzoom,
                dry_run=True,
            )
            probe = run(probe_argv, capture=True)
            if probe is not None:
                output = (probe.stdout or "") + (probe.stderr or "")
                tiles, size = parse_dry_run_stats(output)
                tiles_str = str(tiles) if tiles is not None else "?"
                size_str = size or "?"
        print(
            f"{name:<24} {len(cluster_fixes_list):>6}  {fmt_bbox(bbox):<42} "
            f"{tiles_str:>8}  {size_str:>10}"
        )
        plan.append((name, out_path, extract_argv))

    if not bin_exists:
        print(f"note: {args.pmtiles_bin} not found — tile/size columns are unavailable")

    if args.dry_run:
        print("[dry-run] stopping before extract")
        return 0

    for _name, _out_path, extract_argv in plan:
        run(extract_argv)
    return 0


# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------


def cmd_publish(args: argparse.Namespace) -> int:
    view_argv = build_release_view_argv(args.repo, args.tag)
    view_result = run(view_argv, capture=True)
    exists = view_result is not None and view_result.returncode == 0
    if not exists:
        create_argv = build_release_create_argv(args.repo, args.tag, args.notes)
        create_result = run(create_argv)
        if create_result is not None and create_result.returncode != 0:
            return create_result.returncode

    upload_argv = build_release_upload_argv(args.repo, args.tag, args.files)
    upload_result = run(upload_argv)
    return 0 if upload_result is None or upload_result.returncode == 0 else upload_result.returncode


# ---------------------------------------------------------------------------
# argparse wiring
# ---------------------------------------------------------------------------


def _add_common_flags(p: argparse.ArgumentParser) -> None:
    p.add_argument("--planet", help="Override the planet build URL (skips auto-pick)")
    p.add_argument("--date", help="Override the YYYYMMDD used in output file names")
    p.add_argument(
        "--pmtiles-bin",
        default=DEFAULT_PMTILES_BIN,
        help=f"Path to the pmtiles binary (default: {DEFAULT_PMTILES_BIN})",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="extract.py", description="Trail coverage-extract job (Phase B)."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_planet = sub.add_parser("planet", help="Resolve the newest Protomaps daily build")
    p_planet.add_argument("--days", type=int, default=7, help="How many days back to try")
    p_planet.set_defaults(func=cmd_planet)

    p_overview = sub.add_parser("overview", help="Extract the world z0-6 overview")
    p_overview.add_argument("--out", required=True, help="Output directory")
    p_overview.add_argument("--maxzoom", type=int, default=6)
    p_overview.add_argument("--dry-run", action="store_true")
    _add_common_flags(p_overview)
    p_overview.set_defaults(func=cmd_overview)

    p_region = sub.add_parser("region", help="Extract a region (preset or bbox)")
    p_region.add_argument("--preset", choices=sorted(PRESETS))
    p_region.add_argument("--bbox", help="W,S,E,N")
    p_region.add_argument("--name", help="Region name (required with --bbox)")
    p_region.add_argument("--maxzoom", type=int, default=13)
    p_region.add_argument("--out", required=True, help="Output directory")
    p_region.add_argument("--dry-run", action="store_true")
    _add_common_flags(p_region)
    p_region.set_defaults(func=cmd_region)

    p_coverage = sub.add_parser(
        "coverage", help="Cluster a Trail export into visit-bbox extracts"
    )
    p_coverage.add_argument("--export", required=True, help="Trail CSV or GPX export file")
    p_coverage.add_argument("--minzoom", type=int, default=7)
    p_coverage.add_argument("--maxzoom", type=int, default=14)
    p_coverage.add_argument("--cluster-km", type=float, default=15.0)
    p_coverage.add_argument("--pad-km", type=float, default=3.0)
    p_coverage.add_argument(
        "--exclude-preset", action="append", choices=sorted(PRESETS), default=[]
    )
    p_coverage.add_argument("--exclude-bbox", action="append", default=[], help="W,S,E,N")
    p_coverage.add_argument("--out", required=True, help="Output directory")
    p_coverage.add_argument("--names", help="JSON file mapping slug -> friendly name")
    p_coverage.add_argument("--dry-run", action="store_true")
    _add_common_flags(p_coverage)
    p_coverage.set_defaults(func=cmd_coverage)

    p_publish = sub.add_parser("publish", help="Upload files to a GitHub release")
    p_publish.add_argument("--repo", required=True, help="OWNER/NAME")
    p_publish.add_argument("--tag", required=True)
    p_publish.add_argument("--notes", default=None)
    p_publish.add_argument("files", nargs="+")
    p_publish.set_defaults(func=cmd_publish)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
