#!/usr/bin/env bash
# Regenerate regions.json from every packs/*/meta.json. Run after adding/building a region.
# meta.json may carry explicit routingURL/basemapURL (e.g. GitHub Release assets for big packs);
# otherwise URLs default to the packs/ path and the local file must exist.
# Usage: ./gen-catalog.sh [base-url]
set -euo pipefail
BASE="${1:-https://iamswap.github.io/idash-regions}"
cd "$(dirname "$0")"
python3 - "$BASE" <<'PY'
import json, os, sys, glob
base = sys.argv[1].rstrip('/')
out = []
for meta in sorted(glob.glob('packs/*/meta.json')):
    d = os.path.dirname(meta)
    m = json.load(open(meta))
    rid = m['id']
    tar  = os.path.join(d, 'tiles.tar')
    bd   = os.path.join(d, 'basemap-dark.mbtiles')
    bl   = os.path.join(d, 'basemap-light.mbtiles')
    blg  = os.path.join(d, 'basemap.mbtiles')   # legacy single-file raster pack
    bvec = os.path.join(d, 'basemap.pmtiles')   # theme-independent vector pack
    srch = os.path.join(d, 'search.sqlite')     # offline place-search index (FTS5)

    def local(path, fname):
        return f"{base}/packs/{rid}/{fname}" if os.path.exists(path) else None

    routing = m.get('routingURL') or local(tar, 'tiles.tar')
    if not routing:                       # routing is required
        continue

    entry = {"id": rid, "name": m.get('name', rid), "routingURL": routing}

    # Vector pack: one theme-independent basemap.pmtiles, styled per day/night in the app.
    vector = (m.get('basemapURL') if m.get('basemapFormat') == 'pbf' else None) or local(bvec, 'basemap.pmtiles')
    if m.get('basemapFormat') == 'pbf' or (vector and os.path.exists(bvec)):
        entry["basemapURL"] = vector
        entry["basemapFormat"] = "pbf"
    else:
        dark  = m.get('basemapDarkURL')  or local(bd, 'basemap-dark.mbtiles')  or m.get('basemapURL') or local(blg, 'basemap.mbtiles')
        light = m.get('basemapLightURL') or local(bl, 'basemap-light.mbtiles')
        if dark:
            entry["basemapDarkURL"] = dark
        if light:
            entry["basemapLightURL"] = light
        default_basemap = light or dark      # back-compat single basemap → default to light
        if default_basemap:
            entry["basemapURL"] = default_basemap
    # Offline place-search index (FTS5 SQLite); the app downloads it for offline destination search.
    search = m.get('searchURL') or local(srch, 'search.sqlite')
    if search:
        entry["searchURL"] = search
        entry["searchFormat"] = m.get('searchFormat', 'fts')
    if m.get('version'):
        entry["version"] = m['version']   # pack build date — app shows "Update" when it changes
    if m.get('bbox'):
        entry["bbox"] = m['bbox']         # [W,S,E,N] — shown on the site + used for route coverage
    if m.get('sizeMB'):
        entry["sizeMB"] = m['sizeMB']
    else:
        size = sum(os.path.getsize(f) for f in (tar, bd, bl, blg, bvec) if os.path.exists(f))
        if size:
            entry["sizeMB"] = max(1, size // 1_000_000)
    out.append(entry)
json.dump(out, open('regions.json', 'w'), indent=2)
print(f"wrote regions.json with {len(out)} region(s)")
PY
