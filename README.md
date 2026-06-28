# DashMate Offline Regions

Catalog + hosting for DashMate offline map/routing packs, served as a static **GitHub Pages** site.
The app fetches `regions.json` and downloads the packs it lists. Regions are **Indian states**.

- **Browse page:** https://iamswap.github.io/idash-regions/
- **Catalog (set this in the app):** https://iamswap.github.io/idash-regions/regions.json
  — DashMate → Settings → Offline maps → Region catalog → paste → Load.

Each region pack is two parts: **routing** (Valhalla tiles, for offline turn-by-turn) and a
**basemap** (dark raster `.mbtiles`, the map drawn under the route). Both are optional per region,
but routing is what makes a region useful offline.

## Layout
```
states.tsv                  # state id → name, Geofabrik zone, bbox, basemap maxzoom
packs/<id>/tiles.tar        # Valhalla routing tiles (small packs only; big ones → Releases)
packs/<id>/basemap.mbtiles  # dark raster basemap (small packs only; big ones → Releases)
packs/<id>/meta.json        # { id, name, bbox, sizeMB, routingURL?, basemapURL? }
regions.json                # generated catalog (gen-catalog.sh)
render/                     # basemap render assets: dark.json (style), config.json, render-mbtiles.py
```

## Build a state
Requires Docker (running), `osmium-tool`, `pmtiles`, `python3`+`pillow`, `gh`.
```bash
brew install osmium-tool pmtiles
./build-region.sh maharashtra            # uses bbox + zone from states.tsv
git add -A && git commit -m "add maharashtra" && git push
```
This:
1. **Routing** — downloads the state's Geofabrik **zone** extract (cached), clips it to the state
   bbox with osmium, and builds Valhalla tiles → `tiles.tar`.
2. **Basemap** — self-renders a dark raster basemap (no OSM scraping): `pmtiles extract` pulls just
   the region's vector tiles from the Protomaps planet, `tileserver-gl` renders them with
   `render/dark.json`, and tiles are quantized into `basemap.mbtiles` (z5–maxzoom).
3. **Publish** — artifacts ≥ 50 MB are uploaded as **GitHub Release** assets (tag = state id) so the
   repo stays small; `meta.json` then points the catalog at the release URLs. Regenerates
   `regions.json`.

Basemaps cap at an overview zoom (~z12) because a whole state at nav zoom would be millions of
tiles. The app **overzooms** (upscales) the basemap for close-in nav — the route line and turn
markers are drawn as crisp vector overlays on top, so only the backdrop softens when zoomed in.

Add or adjust states (bbox, zone, maxzoom) in `states.tsv`, or pass them explicitly:
`./build-region.sh <id> "<Name>" <zone> <W> <S> <E> <N> [maxzoom]`.

## Just a basemap
`./build-basemap.sh <id> "<Name>" <W> <S> <E> <N> [maxzoom]` builds only the dark basemap pack.

## Attribution
Routing & basemap derive from © OpenStreetMap contributors (ODbL); basemap vector tiles via the
[Protomaps](https://protomaps.com) planet build.
