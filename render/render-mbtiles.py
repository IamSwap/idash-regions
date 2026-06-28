#!/usr/bin/env python3
"""Render a tileserver-gl style over a bbox into a raster MBTiles (TMS rows).

Usage: render-mbtiles.py <out.mbtiles> <name> <minlon> <minlat> <maxlon> <maxlat> <minz> <maxz> [style_base]
Schema matches MBTilesBasemap.swift: tiles(zoom_level, tile_column, tile_row, tile_data), TMS row flip.
"""
import io, math, os, sqlite3, sys, urllib.request, concurrent.futures as cf
from PIL import Image

out, name = sys.argv[1], sys.argv[2]
W, S, E, N = map(float, sys.argv[3:7])
MINZ, MAXZ = int(sys.argv[7]), int(sys.argv[8])
BASE = sys.argv[9] if len(sys.argv) > 9 else "http://localhost:8080/styles/dark"
# Tiles spend most of their time blocked on the style's remote DEM (hillshade) fetches, so the
# renderer is latency-bound, not CPU-bound — more in-flight requests hide that latency. Override
# with RENDER_WORKERS (two themes render concurrently, so total in-flight ≈ 2× this).
WORKERS = int(os.environ.get("RENDER_WORKERS", "8"))
# Tile-path suffix for the requested pixel size. tileserver-gl's base tile is 256px, so "@2x" yields
# 512px; tileserver-rs renders a 512px base, so it wants no suffix. Override with RENDER_SUFFIX.
SUFFIX = os.environ.get("RENDER_SUFFIX", "@2x")


def lon2x(lon, z): return int((lon + 180.0) / 360.0 * (1 << z))
def lat2y(lat, z):
    r = math.radians(lat)
    return int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * (1 << z))


def jobs():
    for z in range(MINZ, MAXZ + 1):
        x0, x1 = lon2x(W, z), lon2x(E, z)
        y0, y1 = lat2y(N, z), lat2y(S, z)  # N has smaller y
        n = 1 << z
        for x in range(max(0, x0), min(n - 1, x1) + 1):
            for y in range(max(0, y0), min(n - 1, y1) + 1):
                yield z, x, y


def fetch(job):
    z, x, y = job
    try:
        with urllib.request.urlopen(f"{BASE}/{z}/{x}/{y}{SUFFIX}.png", timeout=30) as r:
            raw = r.read()
        # Quantize: these flat dark tiles have few colors, so an 8-bit palette shrinks
        # them ~4x with no visible loss — keeps state-size packs small.
        im = Image.open(io.BytesIO(raw)).convert("RGB").quantize(colors=64, method=Image.MEDIANCUT)
        buf = io.BytesIO()
        im.save(buf, format="PNG", optimize=True)
        return z, x, y, buf.getvalue()
    except Exception:
        return z, x, y, None


tiles = list(jobs())
print(f"rendering {len(tiles)} tiles z{MINZ}-{MAXZ} for {name}…", flush=True)

if os.path.exists(out):
    os.remove(out)
db = sqlite3.connect(out)
db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
db.execute("CREATE TABLE tiles (zoom_level INT, tile_column INT, tile_row INT, tile_data BLOB)")
db.execute("CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)")
for k, v in [("name", name), ("format", "png"), ("type", "baselayer"), ("version", "1"),
             ("minzoom", str(MINZ)), ("maxzoom", str(MAXZ)),
             ("bounds", f"{W},{S},{E},{N}")]:
    db.execute("INSERT INTO metadata VALUES (?,?)", (k, v))

done = ok = 0
with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
    for z, x, y, data in ex.map(fetch, tiles):
        done += 1
        if data:
            ok += 1
            tms = (1 << z) - 1 - y
            db.execute("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)", (z, x, tms, data))
        if done % 500 == 0:
            db.commit()
            print(f"  {done}/{len(tiles)} ({ok} ok)", flush=True)

db.commit()
db.execute("VACUUM")
db.close()
print(f"done: {ok}/{len(tiles)} tiles → {out} ({os.path.getsize(out)//1024} KB)")
