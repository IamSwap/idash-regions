#!/usr/bin/env bash
# Build a region's offline dark raster BASEMAP (.mbtiles) by self-rendering Protomaps vector
# tiles — no OSM raster scraping (that's blocked), no API key.
#
#   Protomaps planet .pmtiles ──pmtiles extract (ranged)──▶ region vector tiles
#     ──tileserver-gl + render/dark.json──▶ dark PNGs ──render-mbtiles.py──▶ basemap.mbtiles
#
# Usage:  ./build-basemap.sh <id> "<Name>" <W> <S> <E> <N> [maxzoom]
# Requires: pmtiles (brew install pmtiles), docker (running), python3 + pillow.
set -euo pipefail
if [ "$#" -lt 6 ]; then echo "usage: $0 <id> \"<Name>\" <W> <S> <E> <N> [maxzoom]"; exit 1; fi
ID="$1"; NAME="$2"; W="$3"; S="$4"; E="$5"; N="$6"; MAXZ="${7:-12}"; MINZ=5
cd "$(dirname "$0")"
DIR="packs/$ID"; mkdir -p "$DIR"
BUILD="build-tmp/$ID-basemap"; rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "1/3 Locating latest Protomaps planet build…"
PLANET=""
for i in $(seq 0 16); do
  d=$(date -v-${i}d +%Y%m%d 2>/dev/null || date -d "-$i day" +%Y%m%d)
  code=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -r 0-0 "https://build.protomaps.com/$d.pmtiles" || true)
  if [ "$code" = "206" ] || [ "$code" = "200" ]; then PLANET="https://build.protomaps.com/$d.pmtiles"; break; fi
done
[ -n "$PLANET" ] || { echo "no Protomaps planet build found in last 16 days"; exit 1; }
echo "    planet: $PLANET"

echo "2/3 Extracting region vector tiles (z0-$MAXZ)…"
pmtiles extract "$PLANET" "$BUILD/region.pmtiles" --bbox="$W,$S,$E,$N" --minzoom=0 --maxzoom="$MAXZ"
cp render/dark.json render/config.json "$BUILD/"

echo "3/3 Rendering dark raster → mbtiles…"
docker rm -f idash-tsgl >/dev/null 2>&1 || true
docker run -d --name idash-tsgl -p 8080:8080 -v "$PWD/$BUILD:/data" \
  maptiler/tileserver-gl:latest --config /data/config.json >/dev/null
for i in $(seq 1 40); do curl -sf -o /dev/null "http://localhost:8080/styles/dark/0/0/0.png" && break; sleep 1; done
python3 render/render-mbtiles.py "$DIR/basemap.mbtiles" "$NAME" "$W" "$S" "$E" "$N" "$MINZ" "$MAXZ"
docker rm -f idash-tsgl >/dev/null 2>&1 || true
rm -rf "$BUILD"
echo "✅ basemap → $DIR/basemap.mbtiles ($(du -h "$DIR/basemap.mbtiles" | cut -f1))"
