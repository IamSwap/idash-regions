#!/usr/bin/env bash
# Build a region's offline VECTOR basemap: extract the region's Protomaps vector tiles (z0–14) from
# the latest planet build and ship them as one theme-independent basemap.pmtiles. The iDash app draws
# it on-device with Core Graphics (PMTiles/MVTile/BasemapStyle), styled per day/night in code — there
# is no server-side raster render anymore (that pipeline was retired once vector was bike-validated).
#
#   Protomaps planet .pmtiles ──pmtiles extract (ranged)──▶ basemap.pmtiles
#
# Usage:  ./build-basemap.sh <id> "<Name>" <W> <S> <E> <N> [maxzoom]
# Requires: pmtiles. maxzoom caps at 14 (the Protomaps planet's vector max; the app overzooms above it).
set -euo pipefail
if [ "$#" -lt 6 ]; then echo "usage: $0 <id> \"<Name>\" <W> <S> <E> <N> [maxzoom]"; exit 1; fi
ID="$1"; NAME="$2"; W="$3"; S="$4"; E="$5"; N="$6"; MAXZ="${7:-14}"
VMAXZ=$MAXZ; [ "$VMAXZ" -gt 14 ] && VMAXZ=14
cd "$(dirname "$0")"
DIR="packs/$ID"; mkdir -p "$DIR"

# Region vector tiles are cached across rebuilds (keyed by id + zoom) — the planet extract is the only
# cost. Delete build-tmp/pmtiles (or the file) to force a fresh pull from a newer planet build.
PMCACHE="build-tmp/pmtiles/${ID}-z${VMAXZ}.pmtiles"; mkdir -p build-tmp/pmtiles
if [ -s "$PMCACHE" ]; then
  echo "Reusing cached region vector tiles ($(du -h "$PMCACHE" | cut -f1))."
  cp "$PMCACHE" "$DIR/basemap.pmtiles"
else
  echo "Locating latest Protomaps planet build…"
  PLANET=""
  for i in $(seq 0 16); do
    d=$(date -v-${i}d +%Y%m%d 2>/dev/null || date -d "-$i day" +%Y%m%d)
    code=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -r 0-0 "https://build.protomaps.com/$d.pmtiles" || true)
    if [ "$code" = "206" ] || [ "$code" = "200" ]; then PLANET="https://build.protomaps.com/$d.pmtiles"; break; fi
  done
  [ -n "$PLANET" ] || { echo "no Protomaps planet build found in last 16 days"; exit 1; }
  echo "    planet: $PLANET"
  echo "Extracting region vector tiles (z0–$VMAXZ)…"
  for attempt in 1 2 3 4 5; do
    if pmtiles extract "$PLANET" "$DIR/basemap.pmtiles" --bbox="$W,$S,$E,$N" --minzoom=0 --maxzoom="$VMAXZ"; then break; fi
    echo "    extract attempt $attempt failed (transient?) — retrying…"; sleep 5
    [ "$attempt" = 5 ] && { echo "extract failed after 5 attempts"; exit 1; }
  done
  cp "$DIR/basemap.pmtiles" "$PMCACHE"
fi
echo "✅ vector basemap → $DIR/basemap.pmtiles ($(du -h "$DIR/basemap.pmtiles" | cut -f1))"
