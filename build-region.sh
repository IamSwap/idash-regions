#!/usr/bin/env bash
# Build a region's offline ROUTING pack (Valhalla tile-extract tar) from OSM and add it to the
# catalog. Basemap packs are added separately (see README — OSM raster scraping is blocked).
#
# Usage:  ./build-region.sh <id> "<Name>" <W> <S> <E> <N>
# Example:./build-region.sh pune "Pune" 73.80 18.49 73.92 18.58
#
# Requires: docker (running), osmium-tool (brew install osmium-tool), curl, python3.
set -euo pipefail
if [ "$#" -ne 6 ]; then echo "usage: $0 <id> \"<Name>\" <W> <S> <E> <N>"; exit 1; fi
ID="$1"; NAME="$2"; W="$3"; S="$4"; E="$5"; N="$6"
cd "$(dirname "$0")"
DIR="packs/$ID"; TMP="build-tmp/$ID"
mkdir -p "$DIR" "$TMP/cf"

echo "1/3 Fetching OSM road network for $NAME ($W,$S,$E,$N)…"
Q="[out:xml][timeout:600];way[\"highway\"]($S,$W,$N,$E);(._;>;);out body;"
curl -sS --fail-with-body -A "idash-regions/1.0 (offline pack builder)" \
  -o "$TMP/$ID.osm" --data-urlencode "data=$Q" https://overpass.kumi.systems/api/interpreter
tail -c 12 "$TMP/$ID.osm" | grep -q "</osm>" || { echo "Overpass response truncated — retry"; exit 1; }
osmium cat "$TMP/$ID.osm" -o "$TMP/cf/region.osm.pbf" -f pbf --overwrite

echo "2/3 Building Valhalla tiles + extract tar (Docker)…"
docker run --rm --entrypoint bash -v "$PWD/$TMP/cf:/cf" ghcr.io/gis-ops/docker-valhalla/valhalla:latest -lc '
  set -e; cd /cf
  valhalla_build_config --mjolnir-tile-dir /cf/t --mjolnir-tile-extract /cf/tiles.tar > v.json
  valhalla_build_tiles -c v.json region.osm.pbf >/dev/null 2>&1
  valhalla_build_extract -c v.json -v >/dev/null 2>&1'

cp "$TMP/cf/tiles.tar" "$DIR/tiles.tar"
cat > "$DIR/meta.json" <<EOF
{ "id": "$ID", "name": "$NAME", "bbox": [$W, $S, $E, $N] }
EOF
rm -rf "$TMP"

echo "3/3 Regenerating catalog…"
./gen-catalog.sh
echo "✅ Built $NAME → $DIR/tiles.tar ($(du -h "$DIR/tiles.tar" | cut -f1)). git add/commit/push to publish."
