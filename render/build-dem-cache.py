#!/usr/bin/env python3
"""Pre-download AWS terrarium DEM tiles for a bbox into a local raster mbtiles, so tileserver reads
hillshade elevation from disk instead of fetching every tile from S3 mid-render (the render's main
stall). Tiles are stored raw — terrarium encodes elevation in RGB, so quantizing would corrupt it.

Usage: build-dem-cache.py <out.mbtiles> <W> <S> <E> <N> <minz> <maxz>
"""
import math, os, sqlite3, sys, urllib.request, concurrent.futures as cf

out = sys.argv[1]
W, S, E, N = map(float, sys.argv[2:6])
MINZ, MAXZ = int(sys.argv[6]), int(sys.argv[7])
DEM = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
WORKERS = int(os.environ.get("DEM_WORKERS", "32"))


def lon2x(lon, z): return int((lon + 180.0) / 360.0 * (1 << z))
def lat2y(lat, z):
    r = math.radians(lat)
    return int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * (1 << z))


def jobs():
    for z in range(MINZ, MAXZ + 1):
        x0, x1 = lon2x(W, z), lon2x(E, z)
        y0, y1 = lat2y(N, z), lat2y(S, z)
        n = 1 << z
        for x in range(max(0, x0), min(n - 1, x1) + 1):
            for y in range(max(0, y0), min(n - 1, y1) + 1):
                yield z, x, y


def fetch(job):
    z, x, y = job
    try:
        req = urllib.request.Request(DEM.format(z=z, x=x, y=y), headers={"User-Agent": "idash-regions/1.0"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return z, x, y, r.read()   # raw PNG — do NOT re-encode/quantize
    except Exception:
        return z, x, y, None


tiles = list(jobs())
print(f"caching {len(tiles)} DEM tiles z{MINZ}-{MAXZ}…", flush=True)

if os.path.exists(out):
    os.remove(out)
db = sqlite3.connect(out)
db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
db.execute("CREATE TABLE tiles (zoom_level INT, tile_column INT, tile_row INT, tile_data BLOB)")
db.execute("CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)")
for k, v in [("name", "dem"), ("format", "png"), ("type", "baselayer"), ("version", "1"),
             ("minzoom", str(MINZ)), ("maxzoom", str(MAXZ)), ("bounds", f"{W},{S},{E},{N}")]:
    db.execute("INSERT INTO metadata VALUES (?,?)", (k, v))

done = ok = 0
with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
    for z, x, y, data in ex.map(fetch, tiles):
        done += 1
        if data:
            ok += 1
            tms = (1 << z) - 1 - y
            db.execute("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)", (z, x, tms, data))
        if done % 1000 == 0:
            db.commit()
            print(f"  {done}/{len(tiles)} ({ok} ok)", flush=True)

db.commit()
db.execute("VACUUM")
db.close()
print(f"done: {ok}/{len(tiles)} DEM tiles → {out} ({os.path.getsize(out)//1024} KB)")
