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
    tar = os.path.join(d, 'tiles.tar')
    mb  = os.path.join(d, 'basemap.mbtiles')

    routing = m.get('routingURL') or (f"{base}/packs/{rid}/tiles.tar" if os.path.exists(tar) else None)
    if not routing:                       # routing is required
        continue
    basemap = m.get('basemapURL') or (f"{base}/packs/{rid}/basemap.mbtiles" if os.path.exists(mb) else None)

    entry = {"id": rid, "name": m.get('name', rid), "routingURL": routing}
    if basemap:
        entry["basemapURL"] = basemap
    if m.get('bbox'):
        entry["bbox"] = m['bbox']         # [W,S,E,N] — shown on the site; ignored by the app
    if m.get('sizeMB'):
        entry["sizeMB"] = m['sizeMB']
    else:
        size = sum(os.path.getsize(f) for f in (tar, mb) if os.path.exists(f))
        if size:
            entry["sizeMB"] = max(1, size // 1_000_000)
    out.append(entry)
json.dump(out, open('regions.json', 'w'), indent=2)
print(f"wrote regions.json with {len(out)} region(s)")
PY
