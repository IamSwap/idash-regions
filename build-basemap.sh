#!/usr/bin/env bash
# Build a region's offline raster BASEMAPs (dark + light .mbtiles) by self-rendering Protomaps
# vector tiles — no OSM raster scraping (that's blocked), no API key. Two themed packs let the dash
# follow the app's Day/Night theme. Hillshade relief comes from AWS terrain-tiles (needs internet
# at build time; the style's `dem` source).
#
#   Protomaps planet .pmtiles ──pmtiles extract (ranged)──▶ region vector tiles
#     ──tileserver-gl + render/{dark,light}.json (+ DEM hillshade)──▶ PNGs
#     ──render-mbtiles.py──▶ basemap-dark.mbtiles + basemap-light.mbtiles
#
# Usage:  ./build-basemap.sh <id> "<Name>" <W> <S> <E> <N> [maxzoom]
# Requires: pmtiles (brew install pmtiles), docker (running), python3 + pillow.
set -euo pipefail
if [ "$#" -lt 6 ]; then echo "usage: $0 <id> \"<Name>\" <W> <S> <E> <N> [maxzoom]"; exit 1; fi
ID="$1"; NAME="$2"; W="$3"; S="$4"; E="$5"; N="$6"; MAXZ="${7:-12}"; MINZ=5
# The Protomaps planet caps vector tiles at z14; raster can still be rendered sharply at higher
# zooms from that vector (geometry is vector, not pixels). So extract vector up to z14, but render
# raster up to MAXZ — rendering the pack to the app's nav zoom (17) avoids raster overzoom blur.
VMAXZ=$MAXZ; [ "$VMAXZ" -gt 14 ] && VMAXZ=14
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

echo "2/3 Extracting region vector tiles (z0-$VMAXZ; raster renders to z$MAXZ)…"
for attempt in 1 2 3 4 5; do
  if pmtiles extract "$PLANET" "$BUILD/region.pmtiles" --bbox="$W,$S,$E,$N" --minzoom=0 --maxzoom="$VMAXZ"; then break; fi
  echo "    extract attempt $attempt failed (transient?) — retrying…"; sleep 5
  [ "$attempt" = 5 ] && { echo "extract failed after 5 attempts"; exit 1; }
done
cp render/dark.json render/light.json render/config.json "$BUILD/"
cp -R render/fonts "$BUILD/fonts"   # Noto Sans Regular glyphs for labels (mounted at /data/fonts)

echo "3/3 Rendering dark + light raster → mbtiles…"
docker rm -f idash-tsgl >/dev/null 2>&1 || true
docker run -d --name idash-tsgl -p 8080:8080 -v "$PWD/$BUILD:/data" \
  maptiler/tileserver-gl:latest --config /data/config.json >/dev/null
for i in $(seq 1 40); do curl -sf -o /dev/null "http://localhost:8080/styles/dark/0/0/0.png" && break; sleep 1; done
# Self-contained Pillow (system python3 may lack it / be externally-managed).
VENV="build-tmp/venv"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --disable-pip-version-check pillow
# Two themed packs (the dash picks one by day/night): basemap-dark / basemap-light.
"$VENV/bin/python" render/render-mbtiles.py "$DIR/basemap-dark.mbtiles"  "$NAME" "$W" "$S" "$E" "$N" "$MINZ" "$MAXZ" "http://localhost:8080/styles/dark"
"$VENV/bin/python" render/render-mbtiles.py "$DIR/basemap-light.mbtiles" "$NAME" "$W" "$S" "$E" "$N" "$MINZ" "$MAXZ" "http://localhost:8080/styles/light"
docker rm -f idash-tsgl >/dev/null 2>&1 || true
rm -rf "$BUILD"
echo "✅ basemaps → $DIR/basemap-dark.mbtiles ($(du -h "$DIR/basemap-dark.mbtiles" | cut -f1)), $DIR/basemap-light.mbtiles ($(du -h "$DIR/basemap-light.mbtiles" | cut -f1))"
