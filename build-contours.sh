#!/usr/bin/env bash
# Build contour-line vector tiles for a region → packs/<id>/contours.pmtiles, which build-basemap.sh
# then renders into the dash basemap (only when this file exists — see build-basemap.sh).
#
#   AWS terrain-tiles GeoTIFF (raw elevation) ──gdalwarp (bbox)──▶ region DEM
#     ──gdal_contour──▶ contour lines (GeoJSON) ──tippecanoe──▶ contours.pmtiles
#
# Usage:  ./build-contours.sh <id> <W> <S> <E> <N> [interval_m] [dem_zoom]
# Requires: gdal (gdalwarp, gdal_contour), tippecanoe.
#
# ⚠️  UNVALIDATED SCAFFOLD — not yet run end-to-end. The DEM fetch (GDAL WMS over the AWS
#     terrain-tiles GeoTIFF endpoint) and gdal_contour/tippecanoe params likely need tuning on a
#     real machine. Hillshade (in dark.json/light.json) already gives terrain relief; contour LINES
#     are the extra. Iterate here, then a region built with build-region.sh picks them up.
set -euo pipefail
if [ "$#" -lt 5 ]; then echo "usage: $0 <id> <W> <S> <E> <N> [interval_m] [dem_zoom]"; exit 1; fi
ID="$1"; W="$2"; S="$3"; E="$4"; N="$5"; INTERVAL="${6:-100}"; ZOOM="${7:-11}"
cd "$(dirname "$0")"
command -v gdalwarp >/dev/null    || { echo "need gdal (brew install gdal)"; exit 1; }
command -v gdal_contour >/dev/null|| { echo "need gdal_contour"; exit 1; }
command -v tippecanoe >/dev/null  || { echo "need tippecanoe (brew install tippecanoe)"; exit 1; }

DIR="packs/$ID"; mkdir -p "$DIR"
TMP="build-tmp/$ID-contours"; rm -rf "$TMP"; mkdir -p "$TMP"

# GDAL WMS/TMS over AWS terrain-tiles GeoTIFF (raw Float32 elevation, global, ~z14).
cat > "$TMP/dem.xml" <<XML
<GDAL_WMS>
  <Service name="TMS">
    <ServerUrl>https://s3.amazonaws.com/elevation-tiles-prod/geotiff/\${z}/\${x}/\${y}.tif</ServerUrl>
  </Service>
  <DataWindow>
    <UpperLeftX>-20037508.34</UpperLeftX><UpperLeftY>20037508.34</UpperLeftY>
    <LowerRightX>20037508.34</LowerRightX><LowerRightY>-20037508.34</LowerRightY>
    <TileLevel>14</TileLevel><TileCountX>1</TileCountX><TileCountY>1</TileCountY><YOrigin>top</YOrigin>
  </DataWindow>
  <Projection>EPSG:3857</Projection>
  <BlockSizeX>512</BlockSizeX><BlockSizeY>512</BlockSizeY>
  <BandsCount>1</BandsCount><DataType>Float32</DataType>
  <ZeroBlockHttpCodes>403,404</ZeroBlockHttpCodes>
  <Cache><Path>$TMP/gdalwmscache</Path></Cache>
</GDAL_WMS>
XML

echo "1/3 Fetching DEM for bbox (z$ZOOM)…"
gdalwarp -q -t_srs EPSG:4326 -te "$W" "$S" "$E" "$N" -tr 0.0008 0.0008 -r bilinear \
  -ovr NONE -wo NUM_THREADS=ALL_CPUS "$TMP/dem.xml" "$TMP/dem.tif"

echo "2/3 Generating contour lines every ${INTERVAL} m…"
gdal_contour -a ele -i "$INTERVAL" -f GeoJSON "$TMP/dem.tif" "$TMP/contours.geojson"

echo "3/3 Packing → contours.pmtiles (layer 'contours', attr 'ele')…"
tippecanoe -q -o "$DIR/contours.pmtiles" -f -l contours \
  --minimum-zoom=9 --maximum-zoom=14 --drop-densest-as-needed --simplification=4 \
  "$TMP/contours.geojson"
rm -rf "$TMP"
echo "✅ contours → $DIR/contours.pmtiles ($(du -h "$DIR/contours.pmtiles" | cut -f1)). Rebuild the region to bake them in."
