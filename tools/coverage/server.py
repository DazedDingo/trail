#!/usr/bin/env python3
"""Trail tile extract service (Phase C, docs/TIMELINE_IMPORT.md §3).

A small localhost HTTP service that hands the Trail app map-detail extracts
on demand. It is the same `pmtiles extract` job as extract.py's `coverage`
subcommand, wrapped in a request/response shape the phone can drive:

  GET /v1/health                      liveness + which planet build is live
  GET /v1/planet                      the resolved planet URL + date
  GET /v1/extract?bbox=W,S,E,N&...    a .pmtiles file (or a --dry-run preview)

Bounded on purpose: bbox area is capped at 1 square degree (bigger regions
are built offline and published to a GitHub release), at most two extracts
run at once, identical concurrent requests collapse into one run, and every
answer is cached on disk by (bbox, zooms, planet date).

Creating extracts with the pmtiles CLI is the intended, ToS-compliant use of
the Protomaps daily build. This service only ever serves local files it
produced itself — it never proxies or hotlinks the dated build URL.

Stdlib only. No third-party dependencies.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable, Deque, Dict, Mapping, Optional, Tuple
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from coverage_lib import (  # noqa: E402
    BBox,
    build_extract_argv,
    candidate_dates,
    coverage_filename,
    date_from_planet_url,
    parse_dry_run_stats,
    pick_planet_url,
    slug_for_bbox,
)
from extract import http_head_ok  # noqa: E402  (carries the CDN User-Agent workaround)

API_VERSION = "1"

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8766
DEFAULT_CACHE_DIR = os.path.expanduser("~/maps/cache")
DEFAULT_TOKEN_FILE = os.path.expanduser("~/.config/trail-tiles/token")
DEFAULT_PMTILES_BIN = os.path.expanduser("~/tools/pmtiles")

DEFAULT_MINZOOM = 7
DEFAULT_MAXZOOM = 14
ZOOM_MIN = 0
ZOOM_MAX = 15

MAX_BBOX_AREA_SQ_DEG = 1.0
MAX_ABS_LAT = 85.0
MAX_ABS_LON = 180.0

EXTRACT_TIMEOUT_S = 300.0
MAX_CONCURRENT_EXTRACTS = 2
QUEUE_WAIT_S = 60.0

RATE_LIMIT_REQUESTS = 120
RATE_LIMIT_WINDOW_S = 600.0

PLANET_TTL_S = 3600.0
PLANET_FAILURE_TTL_S = 60.0
DRY_RUN_TTL_S = 3600.0

CHUNK_BYTES = 1 << 20  # 1 MiB

RELEASES_URL = "https://github.com/DazedDingo/trail/releases"


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class ApiError(Exception):
    """An error with an HTTP status; rendered as {"error": "..."}."""

    def __init__(self, status: int, message: str, headers: Optional[Dict[str, str]] = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.headers = headers or {}


# ---------------------------------------------------------------------------
# Request parsing / validation (pure)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ExtractParams:
    bbox: BBox
    minzoom: int
    maxzoom: int
    dry_run: bool


_TRUEISH = {"1", "true", "yes", "on"}
_FALSEISH = {"0", "false", "no", "off", ""}


def parse_bool_param(name: str, raw: Optional[str], default: bool = False) -> bool:
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in _TRUEISH:
        return True
    if value in _FALSEISH:
        return False
    raise ApiError(400, f"{name} must be 1 or 0")


def _parse_zoom(name: str, raw: Optional[str], default: int) -> int:
    if raw is None or raw.strip() == "":
        return default
    text = raw.strip()
    try:
        value = int(text)
    except ValueError:
        raise ApiError(400, f"{name} must be an integer") from None
    if not (ZOOM_MIN <= value <= ZOOM_MAX):
        raise ApiError(400, f"{name} must be between {ZOOM_MIN} and {ZOOM_MAX}")
    return value


def bbox_area_sq_deg(bbox: BBox) -> float:
    w, s, e, n = bbox
    return (e - w) * (n - s)


def parse_extract_params(query: Mapping[str, str]) -> ExtractParams:
    """Validates the /v1/extract query string. Raises ApiError on any breach.

    Rules: bbox is 4 floats W,S,E,N with W<E, S<N, |lat| <= 85, |lon| <= 180;
    zooms are ints in [0, 15] with minzoom <= maxzoom; bbox area is capped at
    MAX_BBOX_AREA_SQ_DEG square degrees (413 — big regions are built offline).
    """
    raw_bbox = query.get("bbox")
    if raw_bbox is None or raw_bbox.strip() == "":
        raise ApiError(400, "missing required parameter: bbox (W,S,E,N)")

    parts = raw_bbox.split(",")
    if len(parts) != 4:
        raise ApiError(400, "bbox must be 4 comma-separated numbers: W,S,E,N")
    try:
        w, s, e, n = (float(p) for p in parts)
    except ValueError:
        raise ApiError(400, "bbox values must be numbers") from None
    for value in (w, s, e, n):
        if value != value or value in (float("inf"), float("-inf")):  # NaN / inf
            raise ApiError(400, "bbox values must be finite numbers")

    if w >= e:
        raise ApiError(400, "bbox west must be less than east")
    if s >= n:
        raise ApiError(400, "bbox south must be less than north")
    if abs(s) > MAX_ABS_LAT or abs(n) > MAX_ABS_LAT:
        raise ApiError(400, f"bbox latitudes must be within +/-{MAX_ABS_LAT:g}")
    if abs(w) > MAX_ABS_LON or abs(e) > MAX_ABS_LON:
        raise ApiError(400, f"bbox longitudes must be within +/-{MAX_ABS_LON:g}")

    minzoom = _parse_zoom("minzoom", query.get("minzoom"), DEFAULT_MINZOOM)
    maxzoom = _parse_zoom("maxzoom", query.get("maxzoom"), DEFAULT_MAXZOOM)
    if minzoom > maxzoom:
        raise ApiError(400, "minzoom must be less than or equal to maxzoom")

    bbox: BBox = (w, s, e, n)
    area = bbox_area_sq_deg(bbox)
    if area > MAX_BBOX_AREA_SQ_DEG:
        raise ApiError(
            413,
            f"bbox area {area:.2f} square degrees exceeds the "
            f"{MAX_BBOX_AREA_SQ_DEG:g} square degree limit — build region-sized "
            f"archives offline with tools/coverage/extract.py and install them "
            f"from a release: {RELEASES_URL}",
        )

    dry_run = parse_bool_param("dry_run", query.get("dry_run"))
    return ExtractParams(bbox=bbox, minzoom=minzoom, maxzoom=maxzoom, dry_run=dry_run)


def cache_key(bbox: BBox, minzoom: int, maxzoom: int, planet_date: str) -> str:
    """Stable cache key: bbox rounded to 4dp (~11 m) + zooms + planet date."""
    w, s, e, n = bbox
    raw = f"{w:.4f},{s:.4f},{e:.4f},{n:.4f}|{minzoom}-{maxzoom}|{planet_date}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def download_filename(bbox: BBox, minzoom: int, maxzoom: int, planet_date: str) -> str:
    """coverage-<slug>-z<min>-<max>-<date>.pmtiles (coverage_lib naming)."""
    return coverage_filename(slug_for_bbox(bbox), planet_date, minzoom, maxzoom)


def content_disposition(filename: str) -> str:
    return f'attachment; filename="{filename}"'


_SIZE_UNITS = {"B": 1, "KB": 10**3, "MB": 10**6, "GB": 10**9, "TB": 10**12}
_SIZE_RE = re.compile(r"\s*([\d.]+)\s*([kKmMgGtT]?B)\s*")


def size_str_to_bytes(size: Optional[str]) -> Optional[int]:
    """'2.7 MB' -> 2700000. go-pmtiles prints SI (decimal) humanized sizes."""
    if not size:
        return None
    m = _SIZE_RE.fullmatch(size)
    if not m:
        return None
    try:
        return int(round(float(m.group(1)) * _SIZE_UNITS[m.group(2).upper()]))
    except (ValueError, KeyError):
        return None


# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------


def parse_bearer(header_value: Optional[str]) -> Optional[str]:
    if not header_value:
        return None
    parts = header_value.split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    token = parts[1].strip()
    return token or None


def tokens_match(expected: Optional[str], presented: Optional[str]) -> bool:
    """Constant-time compare; False if either side is missing."""
    if not expected or not presented:
        return False
    return hmac.compare_digest(expected.encode("utf-8"), presented.encode("utf-8"))


def token_fingerprint(token: str) -> str:
    """A short, non-reversible handle for rate-limit bookkeeping + logs."""
    return hashlib.sha1(token.encode("utf-8")).hexdigest()[:12]


def load_token(path: str) -> Optional[str]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            token = f.read().strip()
    except OSError:
        return None
    return token or None


def init_token(path: str) -> Tuple[str, bool]:
    """Creates the token file (0600) if missing. Returns (token, created)."""
    existing = load_token(path)
    if existing:
        return existing, False
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    token = secrets.token_urlsafe(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(token + "\n")
    os.chmod(path, 0o600)
    return token, True


# ---------------------------------------------------------------------------
# Rate limiting (pure-ish: injectable clock)
# ---------------------------------------------------------------------------


class RateLimiter:
    """Per-key sliding window: at most `limit` requests per `window_s`."""

    def __init__(
        self,
        limit: int = RATE_LIMIT_REQUESTS,
        window_s: float = RATE_LIMIT_WINDOW_S,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.limit = limit
        self.window_s = window_s
        self._clock = clock
        self._hits: Dict[str, Deque[float]] = {}
        self._lock = threading.Lock()

    def check(self, key: str) -> Tuple[bool, int]:
        """Records a hit if allowed. Returns (allowed, retry_after_seconds)."""
        now = self._clock()
        cutoff = now - self.window_s
        with self._lock:
            hits = self._hits.setdefault(key, deque())
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if len(hits) >= self.limit:
                retry_after = max(1, int(hits[0] + self.window_s - now) + 1)
                return False, retry_after
            hits.append(now)
            return True, 0


# ---------------------------------------------------------------------------
# TTL cache (planet resolution, dry-run answers)
# ---------------------------------------------------------------------------


class TtlCache:
    def __init__(self, clock: Callable[[], float] = time.monotonic):
        self._clock = clock
        self._entries: Dict[str, Tuple[float, object]] = {}
        self._lock = threading.Lock()

    def get(self, key: str):
        now = self._clock()
        with self._lock:
            entry = self._entries.get(key)
            if entry is None:
                return None
            expires_at, value = entry
            if expires_at <= now:
                self._entries.pop(key, None)
                return None
            return value

    def put(self, key: str, value, ttl_s: float) -> None:
        with self._lock:
            self._entries[key] = (self._clock() + ttl_s, value)


# ---------------------------------------------------------------------------
# Planet resolution
# ---------------------------------------------------------------------------


class PlanetResolver:
    """Resolves the newest Protomaps daily build, cached for PLANET_TTL_S.

    A failure is cached for a much shorter window so a transient network blip
    doesn't blackhole the service for an hour.
    """

    def __init__(
        self,
        forced_url: Optional[str] = None,
        head: Callable[[str], bool] = http_head_ok,
        days: int = 7,
        ttl_s: float = PLANET_TTL_S,
        failure_ttl_s: float = PLANET_FAILURE_TTL_S,
        clock: Callable[[], float] = time.monotonic,
        today: Optional[Callable[[], dt.date]] = None,
    ):
        self._forced_url = forced_url
        self._head = head
        self._days = days
        self._ttl_s = ttl_s
        self._failure_ttl_s = failure_ttl_s
        self._clock = clock
        self._today = today or (lambda: dt.datetime.now(dt.timezone.utc).date())
        self._cached: Optional[Tuple[str, str]] = None
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def resolve(self) -> Optional[Tuple[str, str]]:
        """Returns (url, YYYYMMDD) or None when no build is reachable."""
        if self._forced_url:
            date = date_from_planet_url(self._forced_url) or self._today().strftime("%Y%m%d")
            return self._forced_url, date
        with self._lock:
            if self._clock() < self._expires_at:
                return self._cached
            url = pick_planet_url(candidate_dates(self._today(), days=self._days), self._head)
            if url is None:
                self._cached = None
                self._expires_at = self._clock() + self._failure_ttl_s
                return None
            date = date_from_planet_url(url) or self._today().strftime("%Y%m%d")
            self._cached = (url, date)
            self._expires_at = self._clock() + self._ttl_s
            return self._cached


# ---------------------------------------------------------------------------
# Extraction (the one place that shells out)
# ---------------------------------------------------------------------------


@dataclass
class RunResult:
    returncode: int
    output: str


def run_pmtiles(argv, timeout_s: float) -> RunResult:
    proc = subprocess.run(
        list(argv),
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_s,
    )
    return RunResult(proc.returncode, (proc.stdout or "") + (proc.stderr or ""))


class ExtractService:
    """Disk-cached, single-flight, concurrency-capped `pmtiles extract`."""

    def __init__(
        self,
        cache_dir: str,
        pmtiles_bin: str = DEFAULT_PMTILES_BIN,
        timeout_s: float = EXTRACT_TIMEOUT_S,
        max_concurrent: int = MAX_CONCURRENT_EXTRACTS,
        queue_wait_s: float = QUEUE_WAIT_S,
        runner: Callable[..., RunResult] = run_pmtiles,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.cache_dir = cache_dir
        self.pmtiles_bin = pmtiles_bin
        self.timeout_s = timeout_s
        self.queue_wait_s = queue_wait_s
        self._runner = runner
        self._semaphore = threading.BoundedSemaphore(max_concurrent)
        self._key_locks: Dict[str, threading.Lock] = {}
        self._key_locks_guard = threading.Lock()
        self.dry_run_cache = TtlCache(clock=clock)
        os.makedirs(self.cache_dir, exist_ok=True)

    # -- helpers ----------------------------------------------------------

    def cache_path(self, key: str) -> str:
        return os.path.join(self.cache_dir, f"{key}.pmtiles")

    def _lock_for(self, key: str) -> threading.Lock:
        with self._key_locks_guard:
            return self._key_locks.setdefault(key, threading.Lock())

    def _acquire(self, lock, what: str):
        if not lock.acquire(timeout=self.queue_wait_s):
            raise ApiError(503, f"busy: waited {int(self.queue_wait_s)}s for {what}")

    # -- public -----------------------------------------------------------

    def dry_run(
        self, planet_url: str, planet_date: str, params: ExtractParams, key: str
    ) -> Dict[str, object]:
        cached = self.dry_run_cache.get(key)
        if cached is not None:
            return dict(cached)  # type: ignore[arg-type]
        argv = build_extract_argv(
            self.pmtiles_bin,
            planet_url,
            os.devnull,
            bbox=params.bbox,
            minzoom=params.minzoom,
            maxzoom=params.maxzoom,
            dry_run=True,
        )
        self._acquire(self._semaphore, "an extract slot")
        try:
            result = self._run(argv)
        finally:
            self._semaphore.release()
        tiles, size = parse_dry_run_stats(result.output)
        if tiles is None and size is None:
            raise ApiError(502, "could not parse pmtiles dry-run output")
        answer: Dict[str, object] = {
            "tiles": tiles,
            "bytes": size_str_to_bytes(size),
            "size": size,
            "planetDate": planet_date,
        }
        self.dry_run_cache.put(key, dict(answer), DRY_RUN_TTL_S)
        return answer

    def get_or_extract(
        self, planet_url: str, params: ExtractParams, key: str
    ) -> Tuple[str, bool]:
        """Returns (path, cache_hit). Runs at most one extract per key."""
        path = self.cache_path(key)
        if os.path.exists(path):
            return path, True

        key_lock = self._lock_for(key)
        self._acquire(key_lock, "an in-flight extract of the same area")
        try:
            if os.path.exists(path):  # another thread finished while we waited
                return path, True
            self._acquire(self._semaphore, "an extract slot")
            try:
                self._extract_to(path, planet_url, params, key)
            finally:
                self._semaphore.release()
        finally:
            key_lock.release()
        return path, False

    # -- internals --------------------------------------------------------

    def _extract_to(self, path: str, planet_url: str, params: ExtractParams, key: str) -> None:
        tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.partial"
        argv = build_extract_argv(
            self.pmtiles_bin,
            planet_url,
            tmp,
            bbox=params.bbox,
            minzoom=params.minzoom,
            maxzoom=params.maxzoom,
        )
        try:
            result = self._run(argv)
            if result.returncode != 0:
                raise ApiError(502, f"pmtiles extract failed (exit {result.returncode})")
            if not os.path.exists(tmp):
                raise ApiError(502, "pmtiles extract produced no output file")
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def _run(self, argv) -> RunResult:
        try:
            return self._runner(argv, self.timeout_s)
        except subprocess.TimeoutExpired:
            raise ApiError(504, f"pmtiles extract timed out after {int(self.timeout_s)}s") from None
        except FileNotFoundError:
            raise ApiError(500, f"pmtiles binary not found: {self.pmtiles_bin}") from None


# ---------------------------------------------------------------------------
# App (the wiring the handler reads)
# ---------------------------------------------------------------------------


class App:
    def __init__(
        self,
        token: Optional[str],
        extracts: ExtractService,
        planet: PlanetResolver,
        rate_limiter: Optional[RateLimiter] = None,
        log: Callable[[str], None] = print,
    ):
        self.token = token
        self.extracts = extracts
        self.planet = planet
        self.rate_limiter = rate_limiter or RateLimiter()
        self.log = log


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------


_TOKEN_QS_RE = re.compile(r"(?i)(token|access_token)=[^&]*")


def redact_path(path: str) -> str:
    """Belt-and-braces: never let a token reach the log, even in a query."""
    return _TOKEN_QS_RE.sub(r"\1=REDACTED", path)


class TileRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"trail-tiles/{API_VERSION}"
    sys_version = ""

    def version_string(self) -> str:
        # Default is "<server_version> <sys_version>"; drop the Python build
        # (and the trailing space an empty sys_version leaves behind).
        return self.server_version

    # -- plumbing ---------------------------------------------------------

    @property
    def app(self) -> App:
        return self.server.app  # type: ignore[attr-defined]

    def log_message(self, fmt, *args):  # noqa: A003 - silence BaseHTTPRequestHandler
        pass

    def do_GET(self):  # noqa: N802
        self._dispatch(with_body=True)

    def do_HEAD(self):  # noqa: N802
        self._dispatch(with_body=False)

    def _dispatch(self, with_body: bool) -> None:
        started = time.monotonic()
        parsed = urlsplit(self.path)
        status, sent = 500, 0
        try:
            status, sent = self._route(parsed.path, parsed.query, with_body)
        except ApiError as err:
            status, sent = self._send_json(err.status, {"error": err.message}, with_body, err.headers)
        except (BrokenPipeError, ConnectionResetError):
            status, sent = 499, 0  # client hung up mid-stream
        except Exception as err:  # noqa: BLE001 - never leak a traceback to the client
            status, sent = self._send_json(500, {"error": f"internal error: {err}"}, with_body)
        elapsed_ms = int((time.monotonic() - started) * 1000)
        self.app.log(
            f"{self.command} {redact_path(self.path)} {status} {elapsed_ms}ms {sent}b"
        )

    def _route(self, path: str, query: str, with_body: bool) -> Tuple[int, int]:
        params = {k: v[0] for k, v in parse_qs(query, keep_blank_values=True).items()}
        if path == "/v1/health":
            return self._handle_health(with_body)
        if path == "/v1/planet":
            self._authenticate()
            return self._handle_planet(with_body)
        if path == "/v1/extract":
            self._authenticate()
            return self._handle_extract(params, with_body)
        raise ApiError(404, f"not found: {path}")

    # -- auth -------------------------------------------------------------

    def _authenticate(self) -> str:
        presented = parse_bearer(self.headers.get("Authorization"))
        if not tokens_match(self.app.token, presented):
            raise ApiError(
                401,
                "missing or invalid bearer token",
                {"WWW-Authenticate": 'Bearer realm="trail-tiles"'},
            )
        assert presented is not None
        fingerprint = token_fingerprint(presented)
        allowed, retry_after = self.app.rate_limiter.check(fingerprint)
        if not allowed:
            raise ApiError(
                429,
                f"rate limit exceeded ({self.app.rate_limiter.limit} requests per "
                f"{int(self.app.rate_limiter.window_s)}s)",
                {"Retry-After": str(retry_after)},
            )
        return fingerprint

    # -- routes -----------------------------------------------------------

    def _handle_health(self, with_body: bool) -> Tuple[int, int]:
        planet = self.app.planet.resolve()
        return self._send_json(
            200,
            {
                "ok": True,
                "planet": planet[0] if planet else None,
                "planetDate": planet[1] if planet else None,
                "version": API_VERSION,
            },
            with_body,
        )

    def _handle_planet(self, with_body: bool) -> Tuple[int, int]:
        planet = self._require_planet()
        return self._send_json(200, {"url": planet[0], "date": planet[1]}, with_body)

    def _handle_extract(self, query: Mapping[str, str], with_body: bool) -> Tuple[int, int]:
        params = parse_extract_params(query)
        planet_url, planet_date = self._require_planet()
        key = cache_key(params.bbox, params.minzoom, params.maxzoom, planet_date)

        if params.dry_run:
            answer = self.app.extracts.dry_run(planet_url, planet_date, params, key)
            return self._send_json(200, answer, with_body)

        path, hit = self.app.extracts.get_or_extract(planet_url, params, key)
        filename = download_filename(params.bbox, params.minzoom, params.maxzoom, planet_date)
        return self._send_file(
            path,
            {
                "X-Planet-Date": planet_date,
                "X-Cache": "HIT" if hit else "MISS",
                "Content-Disposition": content_disposition(filename),
            },
            with_body,
        )

    def _require_planet(self) -> Tuple[str, str]:
        planet = self.app.planet.resolve()
        if planet is None:
            raise ApiError(
                503, "no Protomaps daily build is reachable right now — try again later"
            )
        return planet

    # -- responses --------------------------------------------------------

    def _send_json(
        self,
        status: int,
        payload: Dict[str, object],
        with_body: bool,
        headers: Optional[Dict[str, str]] = None,
    ) -> Tuple[int, int]:
        body = (json.dumps(payload) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if with_body:
            self.wfile.write(body)
            return status, len(body)
        return status, 0

    def _send_file(
        self, path: str, headers: Dict[str, str], with_body: bool
    ) -> Tuple[int, int]:
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        if not with_body:
            return 200, 0
        sent = 0
        with open(path, "rb") as f:
            while True:
                chunk = f.read(CHUNK_BYTES)
                if not chunk:
                    break
                self.wfile.write(chunk)
                sent += len(chunk)
        return 200, sent


class TileServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: Tuple[str, int], app: App):
        super().__init__(address, TileRequestHandler)
        self.app = app


def make_server(host: str, port: int, app: App) -> TileServer:
    return TileServer((host, port), app)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def stamped_log(line: str) -> None:
    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts} {line}", flush=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="server.py", description="Trail tile extract service (Phase C)."
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
    parser.add_argument("--pmtiles-bin", default=DEFAULT_PMTILES_BIN)
    parser.add_argument("--token-file", default=DEFAULT_TOKEN_FILE)
    parser.add_argument("--planet", help="Pin the planet URL (skips auto-pick)")
    parser.add_argument(
        "--init-token",
        action="store_true",
        help="Create the token file if missing, print the token once, and exit",
    )
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    if args.init_token:
        token, created = init_token(args.token_file)
        if created:
            print(f"token written to {args.token_file} (0600). Copy it now:")
            print(token)
        else:
            print(f"token already exists at {args.token_file} — not overwritten.")
        return 0

    token = load_token(args.token_file)
    if not token:
        print(
            f"error: no token at {args.token_file} — run "
            f"`python3 {os.path.basename(__file__)} --init-token` first",
            file=sys.stderr,
        )
        return 2

    app = App(
        token=token,
        extracts=ExtractService(cache_dir=args.cache_dir, pmtiles_bin=args.pmtiles_bin),
        planet=PlanetResolver(forced_url=args.planet),
        log=stamped_log,
    )
    httpd = make_server(args.host, args.port, app)

    def shutdown(signum, _frame):
        stamped_log(f"signal {signum} received, shutting down")
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    stamped_log(
        f"listening on http://{args.host}:{args.port} "
        f"(cache {args.cache_dir}, pmtiles {args.pmtiles_bin})"
    )
    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()
        stamped_log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
