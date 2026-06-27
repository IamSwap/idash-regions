#!/usr/bin/env bash
# Build a full offline region pack (ROUTING + dark BASEMAP) for an Indian state and add it to the
# catalog. Routing comes from the state's Geofabrik zone extract (clipped to the state bbox);
# basemap is self-rendered (see build-basemap.sh).
#
# Usage by state id (looks up bbox + zone in states.tsv):
#   ./build-region.sh maharashtra
# Or explicit:
#   ./build-region.sh <id> "<Name>" <zone> <W> <S> <E> <N> [maxzoom]
#
# Artifacts over 50 MB are uploaded as GitHub Release assets (tag = region id) and the catalog
# points at the release URLs, so the repo stays small. Requires: docker, osmium-tool, pmtiles,
# python3+pillow, gh (for release upload). REL_MB=50 by default.
set -euo pipefail
cd "$(dirname "$0")"
REL_MB="${REL_MB:-50}"
REPO="IamSwap/idash-regions"

if [ "$#" -eq 1 ]; then
  row=$(grep -E "^$1\b" states.tsv || true)
  [ -n "$row" ] || { echo "unknown state id '$1' — see states.tsv"; exit 1; }
  IFS=$'\t' read -r ID NAME ZONE W S E N MAXZ <<<"$row"
  MAXZ="${MAXZ:-12}"
elif [ "$#" -ge 7 ]; then
  ID="$1"; NAME="$2"; ZONE="$3"; W="$4"; S="$5"; E="$6"; N="$7"; MAXZ="${8:-12}"
else
  echo "usage: $0 <state-id>   |   $0 <id> \"<Name>\" <zone> <W> <S> <E> <N> [maxzoom]"; exit 1
fi
echo "▶ $NAME ($ID) zone=$ZONE bbox=$W,$S,$E,$N maxz=$MAXZ"

DIR="packs/$ID"; mkdir -p "$DIR"
TMP="build-tmp/$ID"; rm -rf "$TMP"; mkdir -p "$TMP/cf"
CACHE="build-tmp/zones"; mkdir -p "$CACHE"

echo "1/4 Fetching OSM extract (cached) + clipping to state bbox…"
# EU OSM mirrors throttle per-connection (single-stream can be <20 KB/s); aria2 with many
# connections is ~100x faster. Fall back to resumable curl if aria2 isn't installed.
dl() {  # <url> <dest>
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x16 -s16 -k1M --console-log-level=warn -d "$(dirname "$2")" -o "$(basename "$2")" "$1"
  else
    curl -L --fail -C - -A "idash-regions/1.0" -o "$2" "$1"
  fi
}
# Prefer OSM France's per-state extract (smaller); fall back to the Geofabrik zone extract.
STATE_PBF="$CACHE/$ID.osm.pbf"
if [ ! -f "$STATE_PBF" ]; then
  if curl -sIL --fail "https://download.openstreetmap.fr/extracts/asia/india/$ID.osm.pbf" >/dev/null 2>&1; then
    dl "https://download.openstreetmap.fr/extracts/asia/india/$ID.osm.pbf" "$STATE_PBF"
  else
    ZONE_PBF="$CACHE/$ZONE-latest.osm.pbf"
    [ -f "$ZONE_PBF" ] || dl "https://download.geofabrik.de/asia/india/$ZONE-latest.osm.pbf" "$ZONE_PBF"
    STATE_PBF="$ZONE_PBF"
  fi
fi
osmium extract -b "$W,$S,$E,$N" "$STATE_PBF" -o "$TMP/cf/region.osm.pbf" -f pbf --overwrite

if [ -f "$DIR/tiles.tar" ]; then
  echo "2/4 Routing tar already built ($(du -h "$DIR/tiles.tar" | cut -f1)) — reusing."
  rm -rf "$TMP"
else
  echo "2/4 Building Valhalla tiles + extract tar (Docker)…"
  docker run --rm --entrypoint bash -v "$PWD/$TMP/cf:/cf" ghcr.io/gis-ops/docker-valhalla/valhalla:latest -lc '
    set -e; cd /cf
    valhalla_build_config --mjolnir-tile-dir /cf/t --mjolnir-tile-extract /cf/tiles.tar > v.json
    valhalla_build_tiles -c v.json region.osm.pbf >/dev/null 2>&1
    valhalla_build_extract -c v.json -v >/dev/null 2>&1'
  cp "$TMP/cf/tiles.tar" "$DIR/tiles.tar"
  rm -rf "$TMP"
  echo "    routing: $(du -h "$DIR/tiles.tar" | cut -f1)"
fi

echo "3/4 Building dark + light basemaps…"
./build-basemap.sh "$ID" "$NAME" "$W" "$S" "$E" "$N" "$MAXZ"

echo "4/4 Writing meta + catalog (large files → GitHub Release)…"
fsize_mb() { echo $(( ( $(stat -f%z "$1" 2>/dev/null || stat -c%s "$1") + 999999 ) / 1000000 )); }
RMB=$(fsize_mb "$DIR/tiles.tar"); BDMB=$(fsize_mb "$DIR/basemap-dark.mbtiles"); BLMB=$(fsize_mb "$DIR/basemap-light.mbtiles")
SIZE_MB=$(( RMB + BDMB + BLMB ))
publish() {  # <file> → echoes the release download URL if uploaded, else nothing
  local f="$1" asset; asset="$(basename "$f")"   # release tag ($ID) namespaces the asset
  [ -f "$f" ] || return 0
  local mb=$(( $(stat -f%z "$f" 2>/dev/null || stat -c%s "$f") / 1000000 ))
  if [ "$mb" -ge "$REL_MB" ]; then
    gh release view "$ID" -R "$REPO" >/dev/null 2>&1 || \
      gh release create "$ID" -R "$REPO" -t "$NAME offline pack" -n "Offline routing + basemap for $NAME." >/dev/null
    gh release upload "$ID" -R "$REPO" "$f" --clobber >/dev/null
    echo "https://github.com/$REPO/releases/download/$ID/$asset"
  fi
}
ROUTING_URL=$(publish "$DIR/tiles.tar")
BASEMAP_DARK_URL=$(publish "$DIR/basemap-dark.mbtiles")
BASEMAP_LIGHT_URL=$(publish "$DIR/basemap-light.mbtiles")
[ -n "$ROUTING_URL" ] && rm -f "$DIR/tiles.tar"             # hosted on release, don't bloat repo
[ -n "$BASEMAP_DARK_URL" ] && rm -f "$DIR/basemap-dark.mbtiles"
[ -n "$BASEMAP_LIGHT_URL" ] && rm -f "$DIR/basemap-light.mbtiles"

VERSION="$(date +%Y-%m-%d)"        # pack build date → app shows "Update" when it changes
python3 - "$ID" "$NAME" "$W" "$S" "$E" "$N" "$ROUTING_URL" "$BASEMAP_DARK_URL" "$BASEMAP_LIGHT_URL" "$SIZE_MB" "$VERSION" <<'PY'
import json, sys
id, name, W, S, E, N, ru, bd, bl, size, version = sys.argv[1:12]
m = {"id": id, "name": name, "bbox": [float(W), float(S), float(E), float(N)], "sizeMB": int(size), "version": version}
if ru: m["routingURL"] = ru
if bd: m["basemapDarkURL"] = bd
if bl: m["basemapLightURL"] = bl
if bd: m["basemapURL"] = bd        # back-compat: older app builds download a single (dark) basemap
json.dump(m, open(f"packs/{id}/meta.json", "w"), indent=2)
PY
./gen-catalog.sh
echo "✅ $NAME built. git add/commit/push to publish."
