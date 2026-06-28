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
# Routing (native pyvalhalla) and the vector basemap (pmtiles extract) are built in parallel.
# Artifacts over 50 MB are uploaded as GitHub Release assets (tag = region id) and the catalog
# points at the release URLs, so the repo stays small. The build then commits the meta + catalog and
# pushes (so GitHub Pages deploys) automatically — set PUSH=0 to stop after building.
# Requires: osmium-tool, pmtiles, gh (release upload), Python ≥3.12 (pyvalhalla; or USE_DOCKER_VALHALLA=1
# for the routing build). REL_MB=50 by default.
set -euo pipefail
cd "$(dirname "$0")"
REL_MB="${REL_MB:-50}"
REPO="IamSwap/idash-regions"

if [ "$#" -eq 1 ]; then
  row=$(grep -E "^$1\b" states.tsv || true)
  [ -n "$row" ] || { echo "unknown state id '$1' — see states.tsv"; exit 1; }
  IFS=$'\t' read -r ID NAME ZONE W S E N MAXZ <<<"$row"
  MAXZ="${MAXZ:-14}"
elif [ "$#" -ge 7 ]; then
  ID="$1"; NAME="$2"; ZONE="$3"; W="$4"; S="$5"; E="$6"; N="$7"; MAXZ="${8:-14}"
else
  echo "usage: $0 <state-id>   |   $0 <id> \"<Name>\" <zone> <W> <S> <E> <N> [maxzoom]"; exit 1
fi
echo "▶ $NAME ($ID) zone=$ZONE bbox=$W,$S,$E,$N maxz=$MAXZ"

DIR="packs/$ID"; mkdir -p "$DIR"
TMP="build-tmp/$ID"
CACHE="build-tmp/zones"; mkdir -p "$CACHE"

# EU OSM mirrors throttle per-connection (single-stream can be <20 KB/s); aria2 with many
# connections is ~100x faster. Fall back to resumable curl if aria2 isn't installed.
dl() {  # <url> <dest>
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x16 -s16 -k1M --console-log-level=warn -d "$(dirname "$2")" -o "$(basename "$2")" "$1"
  else
    curl -L --fail -C - -A "idash-regions/1.0" -o "$2" "$1"
  fi
}

# Pick a Python ≥3.12 (pyvalhalla wheels are cp312-abi3); prints nothing + fails if none found.
find_py312() {
  local c v
  for c in python3.14 python3.13 python3.12 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    v=$("$c" -c 'import sys; print(1 if sys.version_info[:2] >= (3, 12) else 0)' 2>/dev/null || echo 0)
    [ "$v" = 1 ] && { echo "$c"; return 0; }
  done
  return 1
}

# Build Valhalla routing tiles → $DIR/tiles.tar. Native pyvalhalla by default: no Docker image, and
# tiles are written to APFS instead of a slow Docker bind mount. Set USE_DOCKER_VALHALLA=1 to use the
# Docker image instead (A/B or fallback if the pyvalhalla graph version ever mismatches the app).
build_routing() {
  if [ -f "$DIR/tiles.tar" ]; then
    echo "routing tar already built ($(du -h "$DIR/tiles.tar" | cut -f1)) — reusing."
    return 0
  fi
  rm -rf "$TMP"; mkdir -p "$TMP/cf"

  echo "fetching OSM extract (cached) + clipping to state bbox…"
  # Prefer OSM France's per-state extract (smaller); fall back to the Geofabrik zone extract.
  local STATE_PBF="$CACHE/$ID.osm.pbf"
  if [ ! -f "$STATE_PBF" ]; then
    if curl -sIL --fail "https://download.openstreetmap.fr/extracts/asia/india/$ID.osm.pbf" >/dev/null 2>&1; then
      dl "https://download.openstreetmap.fr/extracts/asia/india/$ID.osm.pbf" "$STATE_PBF"
    else
      local ZONE_PBF="$CACHE/$ZONE-latest.osm.pbf"
      [ -f "$ZONE_PBF" ] || dl "https://download.geofabrik.de/asia/india/$ZONE-latest.osm.pbf" "$ZONE_PBF"
      STATE_PBF="$ZONE_PBF"
    fi
  fi
  osmium extract -b "$W,$S,$E,$N" "$STATE_PBF" -o "$TMP/cf/region.osm.pbf" -f pbf --overwrite

  local CF="$PWD/$TMP/cf"   # absolute: build commands run with cwd=$CF
  if [ "${USE_DOCKER_VALHALLA:-0}" = 1 ]; then
    echo "building Valhalla tiles (Docker)…"
    docker run --rm --entrypoint bash -v "$CF:/cf" ghcr.io/gis-ops/docker-valhalla/valhalla:latest -lc '
      set -e; cd /cf
      valhalla_build_config --mjolnir-tile-dir /cf/t --mjolnir-tile-extract /cf/tiles.tar > v.json
      valhalla_build_tiles -c v.json region.osm.pbf >/dev/null 2>&1
      valhalla_build_extract -c v.json -v >/dev/null 2>&1'
  else
    echo "building Valhalla tiles (native pyvalhalla)…"
    local VVENV="$PWD/build-tmp/venv-valhalla"
    if [ ! -x "$VVENV/bin/python" ]; then
      local PY; PY=$(find_py312) || { echo "✗ need Python ≥3.12 for pyvalhalla (brew install python@3.14), or rerun with USE_DOCKER_VALHALLA=1"; exit 1; }
      "$PY" -m venv "$VVENV"
    fi
    "$VVENV/bin/pip" install --quiet --disable-pip-version-check pyvalhalla
    # The bin/ console scripts mis-resolve the C++ exe name; locate the real binaries directly.
    local VBIN; VBIN="$("$VVENV/bin/python" -m valhalla print_bin_path)"
    (
      cd "$CF"
      "$VVENV/bin/valhalla_build_config" --mjolnir-tile-dir "$CF/t" --mjolnir-tile-extract "$CF/tiles.tar" > v.json
      "$VBIN/valhalla_build_tiles" -c v.json region.osm.pbf >/dev/null
      "$VVENV/bin/valhalla_build_extract" -c v.json -v >/dev/null
    )
  fi
  cp "$CF/tiles.tar" "$DIR/tiles.tar"
  rm -rf "$TMP"
  echo "routing: $(du -h "$DIR/tiles.tar" | cut -f1)"
}

# Prefix a command's output with a tag and stream it live. The function's exit status is the
# command's (PIPESTATUS[0]), not the `while`'s, so a backgrounded `wait` still sees real failures.
run_tagged() {  # <tag> <cmd...>
  local tag="$1"; shift
  "$@" 2>&1 | while IFS= read -r line; do printf '%s %s\n' "$tag" "$line"; done
  return "${PIPESTATUS[0]}"
}

# Routing and basemap are fully independent (routing reads the OSM pbf; basemap reads the Protomaps
# planet), so build them concurrently — routing is CPU-bound while the basemap's planet fetch is
# network-bound, so they overlap well on a multicore Mac.
echo "1/2 Building routing + basemap in parallel…"
run_tagged "[route]" build_routing &
RPID=$!
run_tagged "[ map ]" ./build-basemap.sh "$ID" "$NAME" "$W" "$S" "$E" "$N" "$MAXZ" &
BPID=$!
trap 'kill "$RPID" "$BPID" 2>/dev/null || true' EXIT
RC=0; wait "$RPID" || RC=$?
BC=0; wait "$BPID" || BC=$?
trap - EXIT
[ "$RC" -eq 0 ] || { echo "✗ routing build failed (exit $RC)"; exit 1; }
[ "$BC" -eq 0 ] || { echo "✗ basemap build failed (exit $BC)"; exit 1; }

echo "2/2 Writing meta + catalog (large files → GitHub Release)…"
fsize_mb() { echo $(( ( $(stat -f%z "$1" 2>/dev/null || stat -c%s "$1") + 999999 ) / 1000000 )); }
RMB=$(fsize_mb "$DIR/tiles.tar"); BVMB=$(fsize_mb "$DIR/basemap.pmtiles")
SIZE_MB=$(( RMB + BVMB ))
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
[ -n "$ROUTING_URL" ] && rm -f "$DIR/tiles.tar"             # hosted on release, don't bloat repo
VERSION="$(date +%Y-%m-%d)"        # pack build date → app shows "Update" when it changes

# One theme-independent vector pack (basemap.pmtiles); the app styles it per day/night in code.
BASEMAP_URL=$(publish "$DIR/basemap.pmtiles")
[ -n "$BASEMAP_URL" ] && rm -f "$DIR/basemap.pmtiles"
python3 - "$ID" "$NAME" "$W" "$S" "$E" "$N" "$ROUTING_URL" "$BASEMAP_URL" "$SIZE_MB" "$VERSION" <<'PY'
import json, sys
id, name, W, S, E, N, ru, bv, size, version = sys.argv[1:11]
m = {"id": id, "name": name, "bbox": [float(W), float(S), float(E), float(N)], "sizeMB": int(size),
     "version": version, "basemapFormat": "pbf"}
if ru: m["routingURL"] = ru
if bv: m["basemapURL"] = bv
json.dump(m, open(f"packs/{id}/meta.json", "w"), indent=2)
PY
./gen-catalog.sh

# Auto-publish: large artifacts are already on the GitHub Release (publish() above); now commit the
# pack dir (meta.json + any small packs served from Pages) and the catalog, and push so Pages deploys.
# PUSH=0 to stop after building (commit/push by hand).
if [ "${PUSH:-1}" = 1 ]; then
  echo "Publishing: committing meta + catalog and pushing…"
  git add "$DIR" regions.json
  if git diff --cached --quiet; then
    echo "✅ $NAME built — no catalog changes to push."
  else
    git commit -q -m "Publish $NAME pack ($VERSION)"
    git push origin HEAD
    echo "✅ $NAME published → pushed to origin/$(git rev-parse --abbrev-ref HEAD); GitHub Pages will deploy."
  fi
else
  echo "✅ $NAME built. PUSH=0 — git add/commit/push to publish."
fi
