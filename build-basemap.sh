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

# Region vector tiles are cached across rebuilds (keyed by id + extract zoom) — the planet extract
# is the dominant cost of a minimal build (network), and rebuilds are usually for a style/version
# bump, not fresher map data. Delete the cache file (or build-tmp/pmtiles) to force a fresh pull.
PMCACHE="build-tmp/pmtiles/${ID}-z${VMAXZ}.pmtiles"; mkdir -p build-tmp/pmtiles
if [ -s "$PMCACHE" ]; then
  echo "1/3 Reusing cached region vector tiles ($(du -h "$PMCACHE" | cut -f1)) — skipping planet extract."
  cp "$PMCACHE" "$BUILD/region.pmtiles"
else
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
  cp "$BUILD/region.pmtiles" "$PMCACHE"
fi
cp render/dark.json render/light.json render/config.json "$BUILD/"
cp -R render/fonts "$BUILD/fonts"   # Noto Sans Regular glyphs for labels (mounted at /data/fonts)

# Minimal basemap (default): a flat earth + water + roads + boundaries + road/place labels, with the
# hillshade relief and landcover/landuse/buildings fills stripped out. These spartan tiles quantize
# to very few colours and compress hard, so the pack can render to the nav zoom (z14) at a fraction
# of the size. MINIMAL=0 keeps the full styled basemap (terrain relief, landcover) — bigger, nicer
# for mountains. Done on the BUILD copies so the source styles stay full.
if [ "${MINIMAL:-1}" = 1 ]; then
  echo "    minimal style: stripping hillshade + landcover/landuse/buildings (MINIMAL=0 keeps them)"
  python3 - "$BUILD" <<'PY'
import json, sys
b = sys.argv[1]
drop = {"lc-farmland", "lc-wood", "lc-grass", "lc-sand", "lc-barren", "lc-wetland", "lc-glacier",
        "landuse-green", "landuse-builtup", "buildings"}
for style in ("dark.json", "light.json"):
    s = json.load(open(f"{b}/{style}"))
    s["layers"] = [l for l in s["layers"]
                   if l.get("id") not in drop and l.get("type") != "hillshade"]
    s.get("sources", {}).pop("dem", None)
    json.dump(s, open(f"{b}/{style}", "w"))
PY
fi

# Optional contour lines: only when this region has a contours pack (build-contours.sh). Injected
# into the BUILD copies (source styles stay contour-free, so regions without contours never get a
# dangling source reference). Skipped in minimal mode (contours are terrain detail + extra bytes).
if [ "${MINIMAL:-1}" != 1 ] && [ -f "$DIR/contours.pmtiles" ]; then
  echo "    + injecting contour lines (contours.pmtiles present)"
  cp "$DIR/contours.pmtiles" "$BUILD/contours.pmtiles"
  python3 - "$BUILD" <<'PY'
import json, sys
b = sys.argv[1]
cfg = json.load(open(f"{b}/config.json"))
cfg["data"]["c"] = {"pmtiles": "contours.pmtiles"}
json.dump(cfg, open(f"{b}/config.json", "w"))
for style, color in [("dark.json", "#3a4150"), ("light.json", "#b8a98e")]:
    s = json.load(open(f"{b}/{style}"))
    layer = {"id": "contour", "type": "line", "source": "c", "source-layer": "contours", "minzoom": 11,
             "paint": {"line-color": color, "line-opacity": 0.45,
                       "line-width": ["interpolate", ["linear"], ["zoom"], 11, 0.3, 14, 0.8]}}
    idx = next((i for i, l in enumerate(s["layers"]) if str(l.get("id", "")).startswith("label-")), len(s["layers"]))
    s["layers"].insert(idx, layer)   # under labels, over terrain/roads
    json.dump(s, open(f"{b}/{style}", "w"))
PY
fi

# Local DEM cache: the style's hillshade `dem` source is otherwise fetched per-tile from AWS S3 at
# render time — the render's dominant stall (cores sit idle on network latency). Pre-download the
# region's DEM once into a local mbtiles, serve it from tileserver, and repoint the `dem` source at
# it: ~3x faster render, pixel-identical output. Cached under build-tmp/dem (reused across rebuilds);
# z0-MAXZ is sufficient (a z12 render needs only z12 DEM). USE_LOCAL_DEM=0 reverts to the AWS source.
# Skipped in minimal mode — there's no hillshade layer to feed.
if [ "${MINIMAL:-1}" != 1 ] && [ "${USE_LOCAL_DEM:-1}" = 1 ]; then
  DEMCACHE="build-tmp/dem/${ID}-z${MAXZ}.mbtiles"; mkdir -p build-tmp/dem
  if [ ! -s "$DEMCACHE" ]; then
    echo "    pre-caching hillshade DEM (z0-$MAXZ) for bbox…"
    python3 render/build-dem-cache.py "$DEMCACHE" "$W" "$S" "$E" "$N" 0 "$MAXZ"
  else
    echo "    reusing cached DEM ($(du -h "$DEMCACHE" | cut -f1))"
  fi
  cp "$DEMCACHE" "$BUILD/dem.mbtiles"
  python3 - "$BUILD" "$MAXZ" <<'PY'
import json, sys
b, maxz = sys.argv[1], int(sys.argv[2])
cfg = json.load(open(f"{b}/config.json"))
cfg["data"]["dem"] = {"mbtiles": "dem.mbtiles"}
cfg["options"]["paths"]["mbtiles"] = "/data"
json.dump(cfg, open(f"{b}/config.json", "w"))
for style in ("dark.json", "light.json"):
    s = json.load(open(f"{b}/{style}"))
    s["sources"]["dem"] = {"type": "raster-dem", "url": "mbtiles://{dem}",
                           "encoding": "terrarium", "tileSize": 256, "maxzoom": maxz}
    json.dump(s, open(f"{b}/{style}", "w"))
PY
fi

echo "3/3 Rendering dark + light raster → mbtiles…"
PORT="${RENDER_PORT:-8080}"
# Glyphs are baked at :8080 in the source styles; repoint them at our actual render port so labels
# load regardless of backend/port.
python3 - "$BUILD" "$PORT" <<'PY'
import json, sys
b, port = sys.argv[1], int(sys.argv[2])
for st in ("dark.json", "light.json"):
    s = json.load(open(f"{b}/{st}"))
    s["glyphs"] = f"http://localhost:{port}/fonts/{{fontstack}}/{{range}}.pbf"
    json.dump(s, open(f"{b}/{st}", "w"))
PY
# Self-contained Pillow (system python3 may lack it / be externally-managed).
VENV="build-tmp/venv"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --disable-pip-version-check pillow

# Renderer backend. Default: Dockerized tileserver-gl (CPU software GL) — rock-solid at any size.
# NATIVE_RENDER=1: native tileserver-gl via npm — GPU-backed macOS GL, faster, no Docker. Same
# renderer, but its headless GL stack leaks on the heavy (hillshade/landcover) style and slows over a
# long run; the MINIMAL default doesn't trigger that, so native is the sweet spot for minimal packs.
# For MINIMAL=0 across a whole state, prefer Docker (steady).
if [ "${NATIVE_RENDER:-0}" = 1 ]; then
  echo "    backend: native tileserver-gl :$PORT (NATIVE_RENDER=1)"
  TSGL="$PWD/build-tmp/tileserver-gl"
  if [ ! -x "$TSGL/node_modules/.bin/tileserver-gl" ]; then
    echo "    installing tileserver-gl once (needs: brew install pkg-config cairo pango libpng jpeg giflib librsvg harfbuzz)…"
    mkdir -p "$TSGL"; ( cd "$TSGL" && npm init -y >/dev/null 2>&1 && npm install --no-fund --no-audit --silent tileserver-gl )
  fi
  # Native resolves config paths from its working dir, not Docker's /data mount — make them relative.
  python3 - "$BUILD" <<'PY'
import json, sys
b = sys.argv[1]; cfg = json.load(open(f"{b}/config.json"))
cfg["options"]["paths"] = {"root": ".", "styles": ".", "pmtiles": ".", "mbtiles": ".", "fonts": "fonts"}
json.dump(cfg, open(f"{b}/config.json", "w"))
PY
  ( cd "$BUILD" && exec "$TSGL/node_modules/.bin/tileserver-gl" --config config.json -p "$PORT" ) > "build-tmp/tsgl-$ID.log" 2>&1 &
  TSPID=$!
  stop_render() { kill "$TSPID" 2>/dev/null || true; }
else
  docker rm -f idash-tsgl >/dev/null 2>&1 || true
  docker run -d --name idash-tsgl -p "$PORT:8080" -v "$PWD/$BUILD:/data" \
    maptiler/tileserver-gl:latest --config /data/config.json >/dev/null
  stop_render() { docker rm -f idash-tsgl >/dev/null 2>&1 || true; }
fi
for i in $(seq 1 60); do curl -sf -o /dev/null "http://localhost:$PORT/styles/dark/0/0/0.png" && break; sleep 1; done
# Two themed packs (the dash picks one by day/night): basemap-dark / basemap-light. Render both in
# parallel against the single tileserver — they write separate files, so this ~halves the render
# phase on a multicore Mac. The themes' progress lines interleave; the "done:" line names each.
"$VENV/bin/python" render/render-mbtiles.py "$DIR/basemap-dark.mbtiles"  "$NAME" "$W" "$S" "$E" "$N" "$MINZ" "$MAXZ" "http://localhost:$PORT/styles/dark"  & DPID=$!
"$VENV/bin/python" render/render-mbtiles.py "$DIR/basemap-light.mbtiles" "$NAME" "$W" "$S" "$E" "$N" "$MINZ" "$MAXZ" "http://localhost:$PORT/styles/light" & LPID=$!
DRC=0; wait "$DPID" || DRC=$?
LRC=0; wait "$LPID" || LRC=$?
stop_render
if [ "$DRC" -ne 0 ] || [ "$LRC" -ne 0 ]; then echo "✗ render failed (dark=$DRC light=$LRC)"; exit 1; fi
rm -rf "$BUILD"
echo "✅ basemaps → $DIR/basemap-dark.mbtiles ($(du -h "$DIR/basemap-dark.mbtiles" | cut -f1)), $DIR/basemap-light.mbtiles ($(du -h "$DIR/basemap-light.mbtiles" | cut -f1))"
