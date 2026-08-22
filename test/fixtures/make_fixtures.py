"""Builds test/fixtures/mini.mbtiles + mini_b.mbtiles for Trail's tile-archive tests.

Each tile blob is a hand-rolled, spec-valid Mapbox Vector Tile: one layer,
one full-tile polygon, extent 4096, gzip'd (as MBTiles requires).
"""
import gzip
import os
import sqlite3
import sys

OUT = sys.argv[1]


def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def ld(field: int, payload: bytes) -> bytes:
    return bytes([field << 3 | 2]) + varint(len(payload)) + payload


def vi(field: int, value: int) -> bytes:
    return bytes([field << 3 | 0]) + varint(value)


def zigzag(n: int) -> int:
    return (n << 1) ^ (n >> 31)


def mvt(layer_name: str, feature_id: int = 1) -> bytes:
    # Whole-tile polygon, clockwise in tile (screen) space.
    cmds = [
        9, zigzag(0), zigzag(0),                # MoveTo 1 -> (0, 0)
        26, zigzag(4096), zigzag(0),            # LineTo 3
        zigzag(0), zigzag(4096),
        zigzag(-4096), zigzag(0),
        15,                                     # ClosePath 1
    ]
    geom = b''.join(varint(c) for c in cmds)
    feature = vi(1, feature_id) + vi(3, 3) + ld(4, geom)  # id, POLYGON, geom
    layer = vi(15, 2) + ld(1, layer_name.encode()) + ld(2, feature) + vi(5, 4096)
    return ld(3, layer)


def build(path, *, name, layer, minzoom, maxzoom, bounds, center, tiles):
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute('PRAGMA page_size = 1024')
    db.execute('CREATE TABLE metadata (name TEXT, value TEXT)')
    db.execute(
        'CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, '
        'tile_row INTEGER, tile_data BLOB)'
    )
    db.execute(
        'CREATE UNIQUE INDEX tile_index ON tiles '
        '(zoom_level, tile_column, tile_row)'
    )
    meta = {
        'name': name,
        'format': 'pbf',
        'type': 'overlay',
        'version': '1',
        'description': 'trail test fixture',
        'minzoom': str(minzoom),
        'maxzoom': str(maxzoom),
        'bounds': bounds,
        'center': center,
        'json': '{"vector_layers":[{"id":"%s","description":"","minzoom":%d,'
                '"maxzoom":%d,"fields":{}}]}' % (layer, minzoom, maxzoom),
    }
    db.executemany('INSERT INTO metadata VALUES (?, ?)', sorted(meta.items()))
    rows = []
    for (z, x, y) in tiles:               # (z, x, y) given in XYZ
        tms_y = (1 << z) - 1 - y
        # Unique feature id per tile so every blob differs — lets tests assert
        # which archive (and which tile) a response actually came from, and
        # stops go-pmtiles run-length-encoding the whole set into one entry
        # (which zeroes the PMTiles header's maxZoom).
        blob = gzip.compress(mvt(layer, 1 + (z << 16) + (x << 8) + y), mtime=0)
        rows.append((z, x, tms_y, blob))
    db.executemany('INSERT INTO tiles VALUES (?, ?, ?, ?)', rows)
    db.commit()
    db.execute('VACUUM')
    db.close()
    print(f'{path}: {len(rows)} tiles, file={os.path.getsize(path)}B')


# Fixture A — world coverage, z0..z2.
a_tiles = [(0, 0, 0)]
a_tiles += [(1, x, y) for x in range(2) for y in range(2)]
a_tiles += [(2, x, y) for x in range(4) for y in range(4)]
build(
    os.path.join(OUT, 'mini.mbtiles'),
    name='mini', layer='water', minzoom=0, maxzoom=2,
    bounds='-180.0,-85.0511,180.0,85.0511', center='0.0,0.0,1',
    tiles=a_tiles,
)

# Fixture B — north-east quadrant only, z1..z3, different layer name so its
# blobs differ byte-for-byte from fixture A's.
b_tiles = [(1, 1, 0)]
b_tiles += [(2, x, y) for x in (2, 3) for y in (0, 1)]
b_tiles += [(3, 4, 0)]
build(
    os.path.join(OUT, 'mini_b.mbtiles'),
    name='mini_b', layer='land', minzoom=1, maxzoom=3,
    bounds='0.0,0.0,180.0,85.0511', center='90.0,45.0,2',
    tiles=b_tiles,
)
