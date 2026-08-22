"""Tests for the Trail tile extract service (tools/coverage/server.py).

The pure parts (validation, cache keys, naming, rate limiting, tokens) are
tested directly. The HTTP surface is tested against a real server on an
ephemeral port with a fake `pmtiles` runner, so no network and no binary are
needed.
"""

import datetime as dt
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

import server as srv

BATH_BBOX = (-2.45, 51.33, -2.28, 51.43)
PLANET_URL = "https://build.protomaps.com/20260822.pmtiles"
PLANET_DATE = "20260822"

DRY_RUN_OUTPUT = (
    "2026/08/22 21:11:29 extract.go:441: Region tiles 124, result tile entries 124\n"
    "2026/08/22 21:11:29 extract.go:612: Extract transferred 2.7 MB "
    "(overfetch 0.05) for an archive size of 2.7 MB\n"
)


# ---------------------------------------------------------------------------
# Query validation
# ---------------------------------------------------------------------------


class ParseExtractParamsTests(unittest.TestCase):
    def parse(self, **query):
        return srv.parse_extract_params(query)

    def assertApiError(self, status, **query):
        with self.assertRaises(srv.ApiError) as ctx:
            srv.parse_extract_params(query)
        self.assertEqual(ctx.exception.status, status)
        return ctx.exception

    def test_valid_request(self):
        params = self.parse(bbox="-2.45,51.33,-2.28,51.43", minzoom="7", maxzoom="14")
        self.assertEqual(params.bbox, BATH_BBOX)
        self.assertEqual(params.minzoom, 7)
        self.assertEqual(params.maxzoom, 14)
        self.assertFalse(params.dry_run)

    def test_zooms_default_to_coverage_defaults(self):
        params = self.parse(bbox="-2.45,51.33,-2.28,51.43")
        self.assertEqual((params.minzoom, params.maxzoom), (7, 14))

    def test_missing_bbox_is_400(self):
        err = self.assertApiError(400)
        self.assertIn("bbox", err.message)

    def test_empty_bbox_is_400(self):
        self.assertApiError(400, bbox="")

    def test_wrong_bbox_arity_is_400(self):
        self.assertApiError(400, bbox="-2.45,51.33,-2.28")
        self.assertApiError(400, bbox="-2.45,51.33,-2.28,51.43,9")

    def test_non_numeric_bbox_is_400(self):
        self.assertApiError(400, bbox="a,b,c,d")

    def test_non_finite_bbox_is_400(self):
        self.assertApiError(400, bbox="nan,51.33,-2.28,51.43")
        self.assertApiError(400, bbox="-2.45,51.33,inf,51.43")

    def test_west_must_be_less_than_east(self):
        err = self.assertApiError(400, bbox="-2.28,51.33,-2.45,51.43")
        self.assertIn("west", err.message)
        self.assertApiError(400, bbox="-2.45,51.33,-2.45,51.43")  # zero width

    def test_south_must_be_less_than_north(self):
        err = self.assertApiError(400, bbox="-2.45,51.43,-2.28,51.33")
        self.assertIn("south", err.message)
        self.assertApiError(400, bbox="-2.45,51.33,-2.28,51.33")  # zero height

    def test_latitude_limit_is_85(self):
        self.parse(bbox="-2.45,84.5,-2.28,85.0")  # exactly 85 is allowed
        err = self.assertApiError(400, bbox="-2.45,-85.5,-2.28,-85.1")
        self.assertIn("latitude", err.message)
        self.assertApiError(400, bbox="-2.45,84.9,-2.28,85.1")

    def test_longitude_limit_is_180(self):
        self.parse(bbox="-180.0,51.33,-179.5,51.43")
        err = self.assertApiError(400, bbox="-180.5,51.33,-180.1,51.43")
        self.assertIn("longitude", err.message)

    def test_non_integer_zoom_is_400(self):
        self.assertApiError(400, bbox="-2.45,51.33,-2.28,51.43", minzoom="7.5")
        self.assertApiError(400, bbox="-2.45,51.33,-2.28,51.43", maxzoom="lots")

    def test_zoom_range_is_0_to_15(self):
        self.parse(bbox="-2.45,51.33,-2.28,51.43", minzoom="0", maxzoom="15")
        self.assertApiError(400, bbox="-2.45,51.33,-2.28,51.43", minzoom="-1")
        err = self.assertApiError(400, bbox="-2.45,51.33,-2.28,51.43", maxzoom="16")
        self.assertIn("between 0 and 15", err.message)

    def test_minzoom_must_not_exceed_maxzoom(self):
        self.parse(bbox="-2.45,51.33,-2.28,51.43", minzoom="9", maxzoom="9")
        err = self.assertApiError(400, bbox="-2.45,51.33,-2.28,51.43", minzoom="10", maxzoom="9")
        self.assertIn("maxzoom", err.message)

    def test_bbox_area_cap_is_one_square_degree(self):
        # 1.0 x 1.0 is exactly at the limit and allowed.
        self.parse(bbox="0,50,1,51")
        err = self.assertApiError(413, bbox="0,50,5,55")
        self.assertIn("25.00 square degrees", err.message)
        self.assertIn(srv.RELEASES_URL, err.message)

    def test_area_cap_applies_to_thin_wide_bboxes(self):
        self.assertApiError(413, bbox="-10,50,10,50.2")  # 20 x 0.2 = 4.0

    def test_dry_run_flag_parsing(self):
        base = "-2.45,51.33,-2.28,51.43"
        self.assertTrue(self.parse(bbox=base, dry_run="1").dry_run)
        self.assertTrue(self.parse(bbox=base, dry_run="true").dry_run)
        self.assertFalse(self.parse(bbox=base, dry_run="0").dry_run)
        self.assertFalse(self.parse(bbox=base, dry_run="").dry_run)
        self.assertApiError(400, bbox=base, dry_run="maybe")

    def test_bbox_area_helper(self):
        self.assertAlmostEqual(srv.bbox_area_sq_deg((0.0, 0.0, 2.0, 3.0)), 6.0)


# ---------------------------------------------------------------------------
# Cache keys + naming
# ---------------------------------------------------------------------------


class CacheKeyTests(unittest.TestCase):
    def test_key_is_stable(self):
        a = srv.cache_key(BATH_BBOX, 7, 14, PLANET_DATE)
        b = srv.cache_key(BATH_BBOX, 7, 14, PLANET_DATE)
        self.assertEqual(a, b)
        self.assertEqual(len(a), 40)

    def test_key_rounds_to_four_decimals(self):
        near = (-2.450001, 51.330001, -2.280001, 51.430001)
        self.assertEqual(
            srv.cache_key(BATH_BBOX, 7, 14, PLANET_DATE),
            srv.cache_key(near, 7, 14, PLANET_DATE),
        )

    def test_key_changes_with_bbox_zooms_and_date(self):
        base = srv.cache_key(BATH_BBOX, 7, 14, PLANET_DATE)
        self.assertNotEqual(base, srv.cache_key((-2.4, 51.33, -2.28, 51.43), 7, 14, PLANET_DATE))
        self.assertNotEqual(base, srv.cache_key(BATH_BBOX, 8, 14, PLANET_DATE))
        self.assertNotEqual(base, srv.cache_key(BATH_BBOX, 7, 13, PLANET_DATE))
        self.assertNotEqual(base, srv.cache_key(BATH_BBOX, 7, 14, "20260821"))

    def test_fifth_decimal_difference_still_collapses(self):
        # 1e-5 degrees is ~1 m: deliberately the same cache entry.
        self.assertEqual(
            srv.cache_key((0.00001, 50.0, 1.0, 51.0), 7, 14, PLANET_DATE),
            srv.cache_key((0.0, 50.0, 1.0, 51.0), 7, 14, PLANET_DATE),
        )


class DownloadNameTests(unittest.TestCase):
    def test_filename_uses_coverage_lib_slug(self):
        name = srv.download_filename(BATH_BBOX, 7, 14, PLANET_DATE)
        self.assertEqual(name, "coverage-lat+51.38_lon-002.37-z7-14-20260822.pmtiles")

    def test_filename_for_southern_western_bbox(self):
        name = srv.download_filename((2.0, -38.5, 2.5, -38.0), 10, 14, PLANET_DATE)
        self.assertEqual(name, "coverage-lat-38.25_lon+002.25-z10-14-20260822.pmtiles")

    def test_content_disposition(self):
        self.assertEqual(
            srv.content_disposition("coverage-x-z7-14-20260822.pmtiles"),
            'attachment; filename="coverage-x-z7-14-20260822.pmtiles"',
        )


class SizeParsingTests(unittest.TestCase):
    def test_si_units(self):
        self.assertEqual(srv.size_str_to_bytes("2.7 MB"), 2_700_000)
        self.assertEqual(srv.size_str_to_bytes("575 kB"), 575_000)
        self.assertEqual(srv.size_str_to_bytes("45 GB"), 45_000_000_000)
        self.assertEqual(srv.size_str_to_bytes("512 B"), 512)

    def test_unparseable_returns_none(self):
        self.assertIsNone(srv.size_str_to_bytes(None))
        self.assertIsNone(srv.size_str_to_bytes(""))
        self.assertIsNone(srv.size_str_to_bytes("some MB"))


# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------


class TokenTests(unittest.TestCase):
    def test_parse_bearer(self):
        self.assertEqual(srv.parse_bearer("Bearer abc123"), "abc123")
        self.assertEqual(srv.parse_bearer("bearer abc123"), "abc123")
        self.assertIsNone(srv.parse_bearer(None))
        self.assertIsNone(srv.parse_bearer(""))
        self.assertIsNone(srv.parse_bearer("abc123"))
        self.assertIsNone(srv.parse_bearer("Basic abc123"))
        self.assertIsNone(srv.parse_bearer("Bearer "))

    def test_tokens_match(self):
        self.assertTrue(srv.tokens_match("secret", "secret"))
        self.assertFalse(srv.tokens_match("secret", "secrez"))
        self.assertFalse(srv.tokens_match("secret", "secret2"))
        self.assertFalse(srv.tokens_match("secret", None))
        self.assertFalse(srv.tokens_match(None, "secret"))
        self.assertFalse(srv.tokens_match(None, None))
        self.assertFalse(srv.tokens_match("", ""))

    def test_fingerprint_is_short_and_not_the_token(self):
        fp = srv.token_fingerprint("secret")
        self.assertEqual(len(fp), 12)
        self.assertNotIn("secret", fp)
        self.assertEqual(fp, srv.token_fingerprint("secret"))

    def test_init_token_creates_0600_file_once(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        path = os.path.join(tmp, "sub", "token")

        token, created = srv.init_token(path)
        self.assertTrue(created)
        self.assertGreaterEqual(len(token), 32)
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")

        again, created_again = srv.init_token(path)
        self.assertFalse(created_again)
        self.assertEqual(again, token)
        self.assertEqual(srv.load_token(path), token)

    def test_load_token_missing_file_is_none(self):
        self.assertIsNone(srv.load_token("/nonexistent/trail-tiles/token"))


class RedactionTests(unittest.TestCase):
    def test_token_query_param_is_redacted(self):
        self.assertEqual(
            srv.redact_path("/v1/extract?token=abc&bbox=1,2,3,4"),
            "/v1/extract?token=REDACTED&bbox=1,2,3,4",
        )
        self.assertEqual(srv.redact_path("/v1/health"), "/v1/health")


# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------


class FakeClock:
    def __init__(self, now=0.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class RateLimiterTests(unittest.TestCase):
    def test_allows_up_to_the_limit_then_429s(self):
        clock = FakeClock()
        limiter = srv.RateLimiter(limit=3, window_s=600, clock=clock)
        for _ in range(3):
            self.assertEqual(limiter.check("k")[0], True)
        allowed, retry_after = limiter.check("k")
        self.assertFalse(allowed)
        self.assertGreater(retry_after, 0)

    def test_window_slides(self):
        clock = FakeClock()
        limiter = srv.RateLimiter(limit=2, window_s=600, clock=clock)
        limiter.check("k")
        clock.advance(300)
        limiter.check("k")
        self.assertFalse(limiter.check("k")[0])
        clock.advance(301)  # first hit falls out of the window
        self.assertTrue(limiter.check("k")[0])
        self.assertFalse(limiter.check("k")[0])

    def test_keys_are_independent(self):
        clock = FakeClock()
        limiter = srv.RateLimiter(limit=1, window_s=600, clock=clock)
        self.assertTrue(limiter.check("a")[0])
        self.assertFalse(limiter.check("a")[0])
        self.assertTrue(limiter.check("b")[0])

    def test_defaults_are_120_per_10_minutes(self):
        limiter = srv.RateLimiter()
        self.assertEqual(limiter.limit, 120)
        self.assertEqual(limiter.window_s, 600)


class TtlCacheTests(unittest.TestCase):
    def test_value_expires(self):
        clock = FakeClock()
        cache = srv.TtlCache(clock=clock)
        cache.put("k", {"tiles": 1}, ttl_s=3600)
        self.assertEqual(cache.get("k"), {"tiles": 1})
        clock.advance(3599)
        self.assertIsNotNone(cache.get("k"))
        clock.advance(2)
        self.assertIsNone(cache.get("k"))

    def test_missing_key(self):
        self.assertIsNone(srv.TtlCache().get("nope"))


# ---------------------------------------------------------------------------
# Planet resolution
# ---------------------------------------------------------------------------


class PlanetResolverTests(unittest.TestCase):
    def test_resolves_newest_and_caches_for_an_hour(self):
        clock = FakeClock()
        calls = []

        def head(url):
            calls.append(url)
            return url == PLANET_URL

        resolver = srv.PlanetResolver(
            head=head, clock=clock, today=lambda: dt.date(2026, 8, 22)
        )
        self.assertEqual(resolver.resolve(), (PLANET_URL, PLANET_DATE))
        probes = len(calls)
        self.assertEqual(resolver.resolve(), (PLANET_URL, PLANET_DATE))
        self.assertEqual(len(calls), probes)  # served from cache
        clock.advance(3601)
        self.assertEqual(resolver.resolve(), (PLANET_URL, PLANET_DATE))
        self.assertGreater(len(calls), probes)

    def test_no_build_resolves_to_none_and_retries_soon(self):
        clock = FakeClock()
        calls = []

        def head(url):
            calls.append(url)
            return False

        resolver = srv.PlanetResolver(
            head=head, clock=clock, today=lambda: dt.date(2026, 8, 22)
        )
        self.assertIsNone(resolver.resolve())
        probes = len(calls)
        self.assertIsNone(resolver.resolve())
        self.assertEqual(len(calls), probes)
        clock.advance(61)
        self.assertIsNone(resolver.resolve())
        self.assertGreater(len(calls), probes)

    def test_forced_url_never_probes(self):
        resolver = srv.PlanetResolver(
            forced_url=PLANET_URL, head=lambda url: self.fail("should not probe")
        )
        self.assertEqual(resolver.resolve(), (PLANET_URL, PLANET_DATE))


# ---------------------------------------------------------------------------
# ExtractService
# ---------------------------------------------------------------------------

DUMMY_BODY = b"PMTILES-DUMMY" * 100


def fake_runner(argv, timeout_s):
    """Stands in for `pmtiles extract`: writes a dummy archive (or reports
    dry-run stats) instead of hitting the network."""
    out = argv[3]
    if "--dry-run" in argv:
        return srv.RunResult(0, DRY_RUN_OUTPUT)
    with open(out, "wb") as f:
        f.write(DUMMY_BODY)
    return srv.RunResult(0, "")


class ExtractServiceTests(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.cache_dir)
        self.params = srv.ExtractParams(bbox=BATH_BBOX, minzoom=7, maxzoom=14, dry_run=False)
        self.key = srv.cache_key(BATH_BBOX, 7, 14, PLANET_DATE)

    def service(self, runner=fake_runner, **kwargs):
        return srv.ExtractService(
            cache_dir=self.cache_dir, pmtiles_bin="/fake/pmtiles", runner=runner, **kwargs
        )

    def test_extract_then_cache_hit(self):
        svc = self.service()
        path, hit = svc.get_or_extract(PLANET_URL, self.params, self.key)
        self.assertFalse(hit)
        self.assertEqual(open(path, "rb").read(), DUMMY_BODY)
        path2, hit2 = svc.get_or_extract(PLANET_URL, self.params, self.key)
        self.assertTrue(hit2)
        self.assertEqual(path2, path)

    def test_failed_extract_leaves_no_partial_file(self):
        svc = self.service(runner=lambda argv, t: srv.RunResult(1, "boom"))
        with self.assertRaises(srv.ApiError) as ctx:
            svc.get_or_extract(PLANET_URL, self.params, self.key)
        self.assertEqual(ctx.exception.status, 502)
        self.assertEqual(os.listdir(self.cache_dir), [])

    def test_timeout_is_504(self):
        import subprocess

        def timing_out(argv, t):
            raise subprocess.TimeoutExpired(argv, t)

        with self.assertRaises(srv.ApiError) as ctx:
            self.service(runner=timing_out).get_or_extract(PLANET_URL, self.params, self.key)
        self.assertEqual(ctx.exception.status, 504)

    def test_missing_binary_is_500(self):
        def missing(argv, t):
            raise FileNotFoundError(argv[0])

        with self.assertRaises(srv.ApiError) as ctx:
            self.service(runner=missing).get_or_extract(PLANET_URL, self.params, self.key)
        self.assertEqual(ctx.exception.status, 500)

    def test_single_flight_runs_one_extract_for_concurrent_requests(self):
        started = threading.Event()
        release = threading.Event()
        runs = []

        def slow(argv, t):
            runs.append(argv)
            started.set()
            release.wait(5)
            return fake_runner(argv, t)

        svc = self.service(runner=slow)
        results = []

        def call():
            results.append(svc.get_or_extract(PLANET_URL, self.params, self.key))

        threads = [threading.Thread(target=call) for _ in range(3)]
        for th in threads:
            th.start()
        started.wait(5)
        release.set()
        for th in threads:
            th.join(10)
        self.assertEqual(len(runs), 1)
        self.assertEqual(len(results), 3)
        self.assertEqual(sum(1 for _, hit in results if not hit), 1)

    def test_queue_wait_exhaustion_is_503(self):
        release = threading.Event()
        entered = threading.Semaphore(0)

        def blocking(argv, t):
            entered.release()
            release.wait(5)
            return fake_runner(argv, t)

        svc = self.service(runner=blocking, max_concurrent=1, queue_wait_s=0.05)
        other = srv.ExtractParams(bbox=(0.0, 50.0, 0.5, 50.5), minzoom=7, maxzoom=14, dry_run=False)
        blocker = threading.Thread(
            target=lambda: svc.get_or_extract(PLANET_URL, self.params, self.key)
        )
        blocker.start()
        self.assertTrue(entered.acquire(timeout=5))
        try:
            with self.assertRaises(srv.ApiError) as ctx:
                svc.get_or_extract(PLANET_URL, other, "otherkey")
            self.assertEqual(ctx.exception.status, 503)
        finally:
            release.set()
            blocker.join(10)

    def test_dry_run_json_shape_and_memory_cache(self):
        clock = FakeClock()
        calls = []

        def counting(argv, t):
            calls.append(argv)
            return fake_runner(argv, t)

        svc = self.service(runner=counting, clock=clock)
        params = srv.ExtractParams(bbox=BATH_BBOX, minzoom=7, maxzoom=14, dry_run=True)
        answer = svc.dry_run(PLANET_URL, PLANET_DATE, params, self.key)
        self.assertEqual(answer["tiles"], 124)
        self.assertEqual(answer["bytes"], 2_700_000)
        self.assertEqual(answer["size"], "2.7 MB")
        self.assertEqual(answer["planetDate"], PLANET_DATE)

        svc.dry_run(PLANET_URL, PLANET_DATE, params, self.key)
        self.assertEqual(len(calls), 1)  # served from the 1 h memory cache
        clock.advance(3601)
        svc.dry_run(PLANET_URL, PLANET_DATE, params, self.key)
        self.assertEqual(len(calls), 2)

    def test_dry_run_writes_nothing_to_the_cache_dir(self):
        svc = self.service()
        params = srv.ExtractParams(bbox=BATH_BBOX, minzoom=7, maxzoom=14, dry_run=True)
        svc.dry_run(PLANET_URL, PLANET_DATE, params, self.key)
        self.assertEqual(os.listdir(self.cache_dir), [])

    def test_unparseable_dry_run_output_is_502(self):
        svc = self.service(runner=lambda argv, t: srv.RunResult(0, "garbage"))
        params = srv.ExtractParams(bbox=BATH_BBOX, minzoom=7, maxzoom=14, dry_run=True)
        with self.assertRaises(srv.ApiError) as ctx:
            svc.dry_run(PLANET_URL, PLANET_DATE, params, self.key)
        self.assertEqual(ctx.exception.status, 502)


# ---------------------------------------------------------------------------
# HTTP surface (real server, ephemeral port, fake runner)
# ---------------------------------------------------------------------------


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        return json.loads(self.body.decode("utf-8"))


class HttpServerTests(unittest.TestCase):
    TOKEN = "test-token-abcdefghijklmnop"

    @classmethod
    def setUpClass(cls):
        cls.cache_dir = tempfile.mkdtemp()
        cls.app = srv.App(
            token=cls.TOKEN,
            extracts=srv.ExtractService(
                cache_dir=cls.cache_dir, pmtiles_bin="/fake/pmtiles", runner=fake_runner
            ),
            planet=srv.PlanetResolver(forced_url=PLANET_URL),
            log=lambda line: None,
        )
        cls.httpd = srv.make_server("127.0.0.1", 0, cls.app)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(5)
        shutil.rmtree(cls.cache_dir, ignore_errors=True)

    def get(self, path, token=TOKEN, method="GET"):
        url = f"http://127.0.0.1:{self.port}{path}"
        req = urllib.request.Request(url, method=method)
        if token is not None:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return Response(resp.status, dict(resp.headers), resp.read())
        except urllib.error.HTTPError as err:
            return Response(err.code, dict(err.headers), err.read())

    # -- health / planet --------------------------------------------------

    def test_health_needs_no_auth(self):
        resp = self.get("/v1/health", token=None)
        self.assertEqual(resp.status, 200)
        self.assertEqual(
            resp.json(),
            {"ok": True, "planet": PLANET_URL, "planetDate": PLANET_DATE, "version": "1"},
        )

    def test_planet_requires_auth(self):
        self.assertEqual(self.get("/v1/planet", token=None).status, 401)
        resp = self.get("/v1/planet")
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.json(), {"url": PLANET_URL, "date": PLANET_DATE})

    # -- auth -------------------------------------------------------------

    def test_extract_without_token_is_401(self):
        resp = self.get("/v1/extract?bbox=-2.45,51.33,-2.28,51.43", token=None)
        self.assertEqual(resp.status, 401)
        self.assertIn("error", resp.json())
        self.assertIn("Bearer", resp.headers.get("WWW-Authenticate", ""))

    def test_extract_with_wrong_token_is_401(self):
        resp = self.get("/v1/extract?bbox=-2.45,51.33,-2.28,51.43", token="nope")
        self.assertEqual(resp.status, 401)

    # -- validation over HTTP ---------------------------------------------

    def test_bad_bbox_is_400_json(self):
        resp = self.get("/v1/extract?bbox=notabbox")
        self.assertEqual(resp.status, 400)
        self.assertIn("bbox", resp.json()["error"])
        self.assertEqual(resp.headers["Content-Type"], "application/json")

    def test_oversized_bbox_is_413(self):
        resp = self.get("/v1/extract?bbox=0,50,5,55")
        self.assertEqual(resp.status, 413)
        self.assertIn(srv.RELEASES_URL, resp.json()["error"])

    def test_unknown_route_is_404(self):
        resp = self.get("/v1/nope")
        self.assertEqual(resp.status, 404)
        self.assertIn("error", resp.json())

    # -- extract ----------------------------------------------------------

    def test_extract_returns_file_then_cache_hit(self):
        path = "/v1/extract?bbox=-2.45,51.33,-2.28,51.43&minzoom=7&maxzoom=14"
        first = self.get(path)
        self.assertEqual(first.status, 200)
        self.assertEqual(first.body, DUMMY_BODY)
        self.assertEqual(first.headers["Content-Type"], "application/octet-stream")
        self.assertEqual(first.headers["Content-Length"], str(len(DUMMY_BODY)))
        self.assertEqual(first.headers["X-Cache"], "MISS")
        self.assertEqual(first.headers["X-Planet-Date"], PLANET_DATE)
        self.assertEqual(
            first.headers["Content-Disposition"],
            'attachment; filename="coverage-lat+51.38_lon-002.37-z7-14-20260822.pmtiles"',
        )

        second = self.get(path)
        self.assertEqual(second.status, 200)
        self.assertEqual(second.headers["X-Cache"], "HIT")
        self.assertEqual(second.body, DUMMY_BODY)

    def test_head_returns_headers_without_body(self):
        path = "/v1/extract?bbox=-1.0,51.0,-0.9,51.1&minzoom=7&maxzoom=14"
        resp = self.get(path, method="HEAD")
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.headers["Content-Length"], str(len(DUMMY_BODY)))
        self.assertEqual(resp.body, b"")

    def test_dry_run_returns_json(self):
        resp = self.get("/v1/extract?bbox=-3.0,51.0,-2.9,51.1&dry_run=1")
        self.assertEqual(resp.status, 200)
        payload = resp.json()
        self.assertEqual(payload["tiles"], 124)
        self.assertEqual(payload["bytes"], 2_700_000)
        self.assertEqual(payload["planetDate"], PLANET_DATE)

    def test_rate_limit_returns_429(self):
        app = srv.App(
            token=self.TOKEN,
            extracts=self.app.extracts,
            planet=self.app.planet,
            rate_limiter=srv.RateLimiter(limit=1, window_s=600),
            log=lambda line: None,
        )
        httpd = srv.make_server("127.0.0.1", 0, app)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{port}/v1/planet"

            def call():
                req = urllib.request.Request(url)
                req.add_header("Authorization", f"Bearer {self.TOKEN}")
                try:
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        return resp.status, dict(resp.headers)
                except urllib.error.HTTPError as err:
                    return err.code, dict(err.headers)

            self.assertEqual(call()[0], 200)
            status, headers = call()
            self.assertEqual(status, 429)
            self.assertIn("Retry-After", headers)
        finally:
            httpd.shutdown()
            httpd.server_close()
            thread.join(5)


if __name__ == "__main__":
    unittest.main()
