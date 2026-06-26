# iDash Offline Regions

Catalog + hosting for [iDash](https://github.com/IamSwap/iDash) offline map/routing packs, served
as a static **GitHub Pages** site. The app fetches `regions.json` and downloads the packs it lists.

- **Browse page:** https://iamswap.github.io/idash-regions/
- **Catalog (set this in the app):** https://iamswap.github.io/idash-regions/regions.json
  — iDash → Settings → Offline maps → Region catalog → paste → Load.

## Layout
```
packs/<id>/tiles.tar        # Valhalla tile-extract (routing) — required
packs/<id>/basemap.mbtiles  # raster basemap (optional)
packs/<id>/meta.json        # { id, name, bbox:[W,S,E,N] }
regions.json                # generated catalog (gen-catalog.sh)
```

## Add a routing region
Requires Docker (running), `osmium-tool` (`brew install osmium-tool`), `python3`.
```bash
./build-region.sh <id> "<Name>" <W> <S> <E> <N>
# e.g. ./build-region.sh pune "Pune" 73.80 18.49 73.92 18.58
git add -A && git commit -m "add <id> region" && git push
```
That fetches the OSM road network, builds Valhalla tiles → `tiles.tar`, writes `meta.json`, and
regenerates `regions.json`. Push, and the region appears in the app's catalog + the browse page.

## Basemap packs (note)
Raster basemaps can't be scraped from OpenStreetMap's tile servers (bulk access is **blocked** —
you get "Access blocked" tiles). To add a real basemap for a region, render raster tiles from
vector (e.g. `tileserver-gl` over OpenMapTiles/OpenFreeMap) or use a provider that permits offline
generation, output an `.mbtiles`, drop it at `packs/<id>/basemap.mbtiles`, and re-run
`./gen-catalog.sh`. Routing works fully without a basemap (route line + turn-by-turn on a dark map).

## Big regions
GitHub Pages is fine for small packs. For large ones, host the binaries as **GitHub Release
assets** and point the `routingURL`/`basemapURL` in `regions.json` at the release download URLs
(keeps the repo small + supports big files).
