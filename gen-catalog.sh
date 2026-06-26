#!/usr/bin/env bash
# Regenerate regions.json from every packs/*/meta.json. Run after adding/building a region.
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
    if not os.path.exists(tar):     # routing is required
        continue
    entry = {"id": rid, "name": m.get('name', rid),
             "routingURL": f"{base}/packs/{rid}/tiles.tar"}
    if m.get('bbox'):
        entry["bbox"] = m['bbox']      # [W,S,E,N] — shown on the site; ignored by the app
    size = os.path.getsize(tar)
    if os.path.exists(mb):
        entry["basemapURL"] = f"{base}/packs/{rid}/basemap.mbtiles"
        size += os.path.getsize(mb)
    entry["sizeMB"] = max(1, size // 1_000_000)
    out.append(entry)
json.dump(out, open('regions.json', 'w'), indent=2)
print(f"wrote regions.json with {len(out)} region(s)")
PY
