#!/usr/bin/env bash
# Build a per-region OFFLINE place-search index: a SQLite FTS5 database of named places + POIs from
# OSM, so the app can search destinations by name with no signal. Output: packs/<id>/search.sqlite.
#
# Usage (same args as build-basemap.sh, called in parallel by build-region.sh):
#   ./build-search.sh <id> "<Name>" <W> <S> <E> <N>
#
# Reads the state's OSM extract (cached in build-tmp/zones, same source as routing), clips to the
# state bbox, keeps named places/POIs as nodes, and loads them into FTS5. Requires: osmium, sqlite3,
# python3.
set -euo pipefail
cd "$(dirname "$0")"

ID="$1"; NAME="$2"; W="$3"; S="$4"; E="$5"; N="$6"
DIR="packs/$ID"; mkdir -p "$DIR"
TMP="build-tmp/$ID-search"; rm -rf "$TMP"; mkdir -p "$TMP"
CACHE="build-tmp/zones"; mkdir -p "$CACHE"

dl() {  # <url> <dest> — many-connection aria2 with resumable curl fallback (EU mirrors throttle)
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x16 -s16 -k1M --console-log-level=warn -d "$(dirname "$2")" -o "$(basename "$2")" "$1"
  else
    curl -L --fail -C - -A "idash-regions/1.0" -o "$2" "$1"
  fi
}

echo "fetching OSM extract (cached) for search index..."
STATE_PBF="$CACHE/$ID.osm.pbf"
if [ ! -f "$STATE_PBF" ]; then
  if curl -sIL --fail "https://download.openstreetmap.fr/extracts/asia/india/$ID.osm.pbf" >/dev/null 2>&1; then
    dl "https://download.openstreetmap.fr/extracts/asia/india/$ID.osm.pbf" "$STATE_PBF"
  else
    echo "✗ no cached/openstreetmap.fr extract for '$ID'; run build-region.sh first (it caches the zone pbf)"; exit 1
  fi
fi

echo "keeping named places + POIs (nodes), clipped to $W,$S,$E,$N..."
osmium extract -b "$W,$S,$E,$N" "$STATE_PBF" -o "$TMP/region.osm.pbf" -f pbf --overwrite
# Named, user-meaningful destinations only. -R skips referenced objects (we want point features).
osmium tags-filter -R "$TMP/region.osm.pbf" \
  n/place=city,town,village,suburb,hamlet,locality,neighbourhood,quarter \
  n/amenity n/shop n/tourism n/leisure n/office \
  n/aeroway=aerodrome n/railway=station n/highway=services,rest_area \
  -o "$TMP/named.osm.pbf" --overwrite
osmium export "$TMP/named.osm.pbf" -f geojsonseq -o "$TMP/places.geojsonseq" --overwrite

echo "loading FTS5 index..."
DB="$DIR/search.sqlite"; rm -f "$DB"
python3 - "$TMP/places.geojsonseq" "$DB" <<'PY'
import json, sqlite3, sys

src, db = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.executescript("""
PRAGMA journal_mode = OFF;
PRAGMA synchronous  = OFF;
CREATE TABLE places(id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT, lat REAL, lon REAL);
CREATE VIRTUAL TABLE places_fts USING fts5(name, content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
""")

# Pick the category from the most search-relevant tag present (drives the app's result icon).
KIND_TAGS = ("place", "amenity", "shop", "tourism", "leisure", "office", "aeroway", "railway", "highway")

def kind_of(p):
    for t in KIND_TAGS:
        if p.get(t):
            return f"{t}={p[t]}"
    return None

rows, seen = [], set()
with open(src, encoding="utf-8") as f:
    for line in f:
        line = line.strip().lstrip("\x1e")   # geojsonseq may prefix RS (0x1e)
        if not line:
            continue
        try:
            feat = json.loads(line)
        except json.JSONDecodeError:
            continue
        p = feat.get("properties", {}) or {}
        name = p.get("name:en") or p.get("name") or p.get("int_name")
        if not name:
            continue
        geom = feat.get("geometry") or {}
        if geom.get("type") != "Point":
            continue
        lon, lat = geom["coordinates"][:2]
        # FTS over the English + local name; de-dupe identical name@coarse-location.
        key = (name.lower(), round(lat, 4), round(lon, 4))
        if key in seen:
            continue
        seen.add(key)
        fts_name = name
        if p.get("name") and p["name"] != name:
            fts_name = f"{name} {p['name']}"
        rows.append((name, kind_of(p), lat, lon, fts_name))

cur = con.cursor()
for i, (name, kind, lat, lon, fts_name) in enumerate(rows, 1):
    cur.execute("INSERT INTO places(id, name, kind, lat, lon) VALUES(?,?,?,?,?)", (i, name, kind, lat, lon))
    cur.execute("INSERT INTO places_fts(rowid, name) VALUES(?,?)", (i, fts_name))
con.commit()
con.execute("INSERT INTO places_fts(places_fts) VALUES('optimize')")
con.commit()
con.execute("VACUUM")
con.close()
print(f"  {len(rows)} places indexed → {db}")
PY

SZ=$(du -h "$DB" | cut -f1)
echo "search: $SZ ($DB)"
rm -rf "$TMP"
