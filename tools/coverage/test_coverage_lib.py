import datetime as dt
import unittest

import coverage_lib as lib

BATH_CSV = """timestamp_utc,lat,lon,accuracy_m,altitude_m,heading_deg,speed_mps,battery_pct,network_state,cell_id,wifi_ssid,source,note
2026-08-20T10:00:00.000Z,51.3811,-2.3590,10.0,50.0,180.0,0.0,80,wifi,,HomeWifi,scheduled,
2026-08-20T14:00:00.000Z,,,,,,,75,none,,,no_fix,
2026-08-20T18:00:00.000Z,51.5074,-0.1278,8.0,20.0,90.0,1.2,70,mobile,1234,,scheduled,
"""

BATH_GPX = """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Trail" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>Trail export</name>
    <time>2026-08-22T12:00:00.000Z</time>
  </metadata>
  <wpt lat="51.3811" lon="-2.3590">
    <time>2026-08-20T10:00:00.000Z</time>
    <desc>acc=10.0m</desc>
    <type>scheduled</type>
  </wpt>
  <wpt lat="51.5074" lon="-0.1278">
    <time>2026-08-20T18:00:00.000Z</time>
    <type>scheduled</type>
  </wpt>
</gpx>
"""


class ParsingTests(unittest.TestCase):
    def test_csv_parses_fixes_and_skips_no_fix_row(self):
        fixes = lib.parse_csv_fixes(BATH_CSV)
        self.assertEqual(len(fixes), 2)
        self.assertEqual(fixes[0].ts, "2026-08-20T10:00:00.000Z")
        self.assertAlmostEqual(fixes[0].lat, 51.3811)
        self.assertAlmostEqual(fixes[0].lon, -2.3590)
        self.assertAlmostEqual(fixes[1].lat, 51.5074)
        self.assertAlmostEqual(fixes[1].lon, -0.1278)

    def test_gpx_parses_wpt_fixes(self):
        fixes = lib.parse_gpx_fixes(BATH_GPX)
        self.assertEqual(len(fixes), 2)
        self.assertEqual(fixes[0].ts, "2026-08-20T10:00:00.000Z")
        self.assertAlmostEqual(fixes[0].lat, 51.3811)
        self.assertAlmostEqual(fixes[0].lon, -2.3590)
        self.assertEqual(fixes[1].ts, "2026-08-20T18:00:00.000Z")

    def test_gpx_supports_trkpt_too(self):
        text = (
            '<?xml version="1.0"?>'
            '<gpx xmlns="http://www.topografix.com/GPX/1/1">'
            '<trk><trkseg>'
            '<trkpt lat="51.0" lon="-2.0"><time>2026-01-01T00:00:00Z</time></trkpt>'
            "</trkseg></trk></gpx>"
        )
        fixes = lib.parse_gpx_fixes(text)
        self.assertEqual(len(fixes), 1)
        self.assertEqual(fixes[0].lat, 51.0)

    def test_auto_detect_dispatches_csv_and_gpx(self):
        self.assertEqual(len(lib.parse_export_text(BATH_CSV)), 2)
        self.assertEqual(len(lib.parse_export_text(BATH_GPX)), 2)


class HaversineTests(unittest.TestCase):
    def test_bath_to_london(self):
        km = lib.haversine_km(51.3811, -2.3590, 51.5074, -0.1278)
        self.assertAlmostEqual(km, 156, delta=5)

    def test_zero_distance(self):
        self.assertAlmostEqual(lib.haversine_km(51.0, -2.0, 51.0, -2.0), 0.0)


# Bath-ish cluster of 3, Lisbon-ish cluster of 2, one London singleton.
BATH_FIXES = [
    lib.Fix(ts="t1", lat=51.375, lon=-2.360),
    lib.Fix(ts="t2", lat=51.380, lon=-2.365),
    lib.Fix(ts="t3", lat=51.385, lon=-2.355),
]
LISBON_FIXES = [
    lib.Fix(ts="t4", lat=38.715, lon=-9.140),
    lib.Fix(ts="t5", lat=38.720, lon=-9.135),
]
LONDON_FIX = lib.Fix(ts="t6", lat=51.5074, lon=-0.1278)


class ClusteringTests(unittest.TestCase):
    def test_three_clusters_at_15km(self):
        fixes = BATH_FIXES + LISBON_FIXES + [LONDON_FIX]
        clusters = lib.cluster_fixes(fixes, cluster_km=15)
        self.assertEqual(len(clusters), 3)
        sizes = sorted(len(c.fixes) for c in clusters)
        self.assertEqual(sizes, [1, 2, 3])

    def test_bath_and_london_merge_at_200km(self):
        fixes = BATH_FIXES + LISBON_FIXES + [LONDON_FIX]
        clusters = lib.cluster_fixes(fixes, cluster_km=200)
        self.assertEqual(len(clusters), 2)
        sizes = sorted(len(c.fixes) for c in clusters)
        # Bath (3) + London (1) = 4 in one cluster, Lisbon (2) stays separate.
        self.assertEqual(sizes, [2, 4])


class PaddingTests(unittest.TestCase):
    def test_pad_bbox_km_at_lat_51(self):
        bbox = (0.0, 51.0, 0.0, 51.0)
        w, s, e, n = lib.pad_bbox_km(bbox, 3.0)
        dlat = n - 51.0
        dlon = e - 0.0
        self.assertAlmostEqual(dlat, 0.027, places=3)
        self.assertAlmostEqual(dlon, 0.043, places=3)


class MergeOverlapTests(unittest.TestCase):
    def test_overlapping_bboxes_merge(self):
        items = [
            ([lib.Fix("a", 0, 0)], (-1.0, -1.0, 1.0, 1.0)),
            ([lib.Fix("b", 0, 0)], (0.5, -1.0, 2.0, 1.0)),
        ]
        merged = lib.merge_overlapping(items)
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0][1], (-1.0, -1.0, 2.0, 1.0))
        self.assertEqual(len(merged[0][0]), 2)

    def test_non_overlapping_bboxes_stay_separate(self):
        items = [
            ([lib.Fix("a", 0, 0)], (-1.0, -1.0, 1.0, 1.0)),
            ([lib.Fix("b", 0, 0)], (10.0, 10.0, 11.0, 11.0)),
        ]
        merged = lib.merge_overlapping(items)
        self.assertEqual(len(merged), 2)


class ExclusionTests(unittest.TestCase):
    def test_exclude_drops_cluster_inside_uk_keeps_lisbon(self):
        fixes = BATH_FIXES + LISBON_FIXES
        clusters = lib.build_coverage_clusters(
            fixes, cluster_km=15, pad_km=3, exclude_bboxes=[lib.PRESETS["uk"]]
        )
        self.assertEqual(len(clusters), 1)
        remaining_fixes, bbox = clusters[0]
        # Should be the Lisbon cluster, not Bath.
        self.assertTrue(all(f.lon < -5 for f in remaining_fixes))


class SlugTests(unittest.TestCase):
    def test_slug_format(self):
        bbox = (-2.5, 51.0, -2.0, 51.5)
        self.assertEqual(lib.slug_for_bbox(bbox), "lat+51.25_lon-002.25")

    def test_slug_negative_lat_positive_lon(self):
        bbox = (2.0, -38.5, 2.5, -38.0)
        self.assertEqual(lib.slug_for_bbox(bbox), "lat-38.25_lon+002.25")

    def test_names_json_overrides_slug(self):
        bbox = (-2.5, 51.0, -2.0, 51.5)
        names = {"lat+51.25_lon-002.25": "bath"}
        self.assertEqual(lib.resolve_cluster_name(bbox, names), "bath")
        self.assertEqual(lib.resolve_cluster_name(bbox, {}), "lat+51.25_lon-002.25")
        self.assertEqual(lib.resolve_cluster_name(bbox, None), "lat+51.25_lon-002.25")


class PlanetUrlTests(unittest.TestCase):
    def test_pick_planet_url_falls_back_to_newest_head_200(self):
        dates = lib.candidate_dates(dt.date(2026, 8, 22), days=7)
        self.assertEqual(dates[0], "20260822")
        self.assertEqual(len(dates), 7)

        good_date = "20260819"

        def fake_head(url: str) -> bool:
            return url == lib.planet_url_for_date(good_date)

        url = lib.pick_planet_url(dates, fake_head)
        self.assertEqual(url, lib.planet_url_for_date(good_date))

    def test_pick_planet_url_returns_none_when_nothing_matches(self):
        dates = lib.candidate_dates(dt.date(2026, 8, 22), days=7)
        self.assertIsNone(lib.pick_planet_url(dates, lambda url: False))

    def test_date_from_planet_url(self):
        self.assertEqual(
            lib.date_from_planet_url("https://build.protomaps.com/20260822.pmtiles"),
            "20260822",
        )
        self.assertIsNone(lib.date_from_planet_url("not-a-url"))


class FilenameTests(unittest.TestCase):
    def test_overview_filename(self):
        self.assertEqual(
            lib.overview_filename("20260822", 6), "overview-z0-6-20260822.pmtiles"
        )

    def test_region_filename(self):
        self.assertEqual(
            lib.region_filename("uk", "20260822", 13), "region-uk-z0-13-20260822.pmtiles"
        )

    def test_coverage_filename(self):
        self.assertEqual(
            lib.coverage_filename("bath", "20260822", 7, 14),
            "coverage-bath-z7-14-20260822.pmtiles",
        )


class ExtractArgvTests(unittest.TestCase):
    def test_overview_argv(self):
        argv = lib.build_extract_argv(
            "/tools/pmtiles",
            "PLANET_URL",
            "/out/overview.pmtiles",
            maxzoom=6,
        )
        self.assertEqual(
            argv,
            [
                "/tools/pmtiles",
                "extract",
                "PLANET_URL",
                "/out/overview.pmtiles",
                "--maxzoom=6",
            ],
        )

    def test_region_argv(self):
        argv = lib.build_extract_argv(
            "/tools/pmtiles",
            "PLANET_URL",
            "/out/region-uk.pmtiles",
            bbox=lib.PRESETS["uk"],
            maxzoom=13,
        )
        self.assertEqual(
            argv,
            [
                "/tools/pmtiles",
                "extract",
                "PLANET_URL",
                "/out/region-uk.pmtiles",
                "--bbox=-8.7,49.8,1.9,60.9",
                "--maxzoom=13",
            ],
        )

    def test_coverage_argv(self):
        argv = lib.build_extract_argv(
            "/tools/pmtiles",
            "PLANET_URL",
            "/out/coverage-bath.pmtiles",
            bbox=(-2.4, 51.3, -2.3, 51.4),
            minzoom=7,
            maxzoom=14,
        )
        self.assertEqual(
            argv,
            [
                "/tools/pmtiles",
                "extract",
                "PLANET_URL",
                "/out/coverage-bath.pmtiles",
                "--bbox=-2.4,51.3,-2.3,51.4",
                "--minzoom=7",
                "--maxzoom=14",
            ],
        )

    def test_coverage_argv_with_dry_run(self):
        argv = lib.build_extract_argv(
            "/tools/pmtiles",
            "PLANET_URL",
            "/dev/null",
            bbox=(-2.4, 51.3, -2.3, 51.4),
            minzoom=7,
            maxzoom=14,
            dry_run=True,
        )
        self.assertEqual(argv[-1], "--dry-run")


class DryRunStatsParsingTests(unittest.TestCase):
    def test_parses_tiles_and_mb(self):
        output = (
            "2026/08/22 21:11:29 extract.go:441: Region tiles 124, "
            "result tile entries 124\n"
            "2026/08/22 21:11:29 extract.go:612: Extract transferred 2.7 MB "
            "(overfetch 0.05) for an archive size of 2.7 MB\n"
        )
        tiles, size = lib.parse_dry_run_stats(output)
        self.assertEqual(tiles, 124)
        self.assertEqual(size, "2.7 MB")

    def test_parses_kb(self):
        output = (
            "extract.go:441: Region tiles 5, result tile entries 5\n"
            "extract.go:612: Extract transferred 575 kB (overfetch 0.05) "
            "for an archive size of 575 kB\n"
        )
        tiles, size = lib.parse_dry_run_stats(output)
        self.assertEqual(tiles, 5)
        self.assertEqual(size, "575 kB")

    def test_missing_fields_return_none(self):
        tiles, size = lib.parse_dry_run_stats("garbage output")
        self.assertIsNone(tiles)
        self.assertIsNone(size)


class PublishArgvTests(unittest.TestCase):
    def test_view_argv(self):
        self.assertEqual(
            lib.build_release_view_argv("owner/repo", "v1"),
            ["gh", "release", "view", "v1", "-R", "owner/repo"],
        )

    def test_create_argv(self):
        self.assertEqual(
            lib.build_release_create_argv("owner/repo", "v1", "Coverage packs"),
            [
                "gh",
                "release",
                "create",
                "v1",
                "-R",
                "owner/repo",
                "--title",
                "v1",
                "--notes",
                "Coverage packs",
            ],
        )

    def test_create_argv_defaults_notes_to_empty_string(self):
        argv = lib.build_release_create_argv("owner/repo", "v1")
        self.assertEqual(argv[-1], "")

    def test_upload_argv(self):
        self.assertEqual(
            lib.build_release_upload_argv("owner/repo", "v1", ["a.pmtiles", "b.pmtiles"]),
            ["gh", "release", "upload", "v1", "a.pmtiles", "b.pmtiles", "-R", "owner/repo", "--clobber"],
        )


class BboxHelperTests(unittest.TestCase):
    def test_fmt_and_parse_roundtrip(self):
        bbox = (-8.7, 49.8, 1.9, 60.9)
        self.assertEqual(lib.fmt_bbox(bbox), "-8.7,49.8,1.9,60.9")
        self.assertEqual(lib.parse_bbox("-8.7,49.8,1.9,60.9"), bbox)

    def test_bbox_inside(self):
        self.assertTrue(lib.bbox_inside((-2.4, 51.3, -2.3, 51.4), lib.PRESETS["uk"]))
        self.assertFalse(lib.bbox_inside((-20.0, 51.3, -2.3, 51.4), lib.PRESETS["uk"]))


if __name__ == "__main__":
    unittest.main()
