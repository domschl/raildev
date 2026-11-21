# Raildev 3D — European Railway Simulator

A 3D European railway construction and simulation game built with **Godot Engine 4**, combining real open-license European topography and Sentinel-2 satellite imagery with micro-scale 3D railway assets, block/chain signaling, and a zoom-out cartographic map overlay.

## Highlights
- **Real European Terrain & Regional Ultra-Packs**: Seam-free 32×24 chunked 4-LOD terrain with GPU Cubic B-Spline elevation, Sentinel-2 Cloudless satellite albedo, and modular high-resolution regional packs (`zugspitze` at ~40 m/px, `pyrenees` at ~80 m/px).
- **Two-Regime Scale**: Micro-scale 3D stations (1-track & 2-track passing stations with entry/exit switches), flush terrain-hugging single/double tracks, steam locomotives with dynamic plumes, and a crisp 2D cartographic railway overlay that cross-fades in as you zoom out.
- **Close-Up Living Environment**: Camera-centered streaming 3D Alpine & valley forests (`VegetationStreamer.gd`), close-up ground micro-detail, and pixel-accurate OSM+Sentinel-2 lakes and rivers for both visuals and accurate bridge detection.
- **Realistic Simulation & Signaling**: Grade-aware European train speeds (`1x` real-time up to `300x` with sub-stepping), automatic single-track & double-track signaling, live junction splicing, and collision-free routing.

## Quick Start

### 1. Generate 3D Models & Bake Local Map Data
Large baked map binaries (`*.f32`, `*.rgba`, `*.jpg`, `godot/data/packs/`) are intentionally excluded from Git. Regenerate them locally from open-license sources:

```bash
# 1. Build C++ base map exporter & export initial Europe grid
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
./build/export_map godot/data

# 2. Generate procedural PBR glTF (.glb) 3D models
python3 tools/generate_3d_assets.py

# 3. Enrich continental Europe DEM + CORINE forests + Natural Earth rivers/lakes
python3 tools/enrich_europe_topography.py
python3 tools/bake_region_pack.py europe_albedo

# 4. Bake optional high-resolution regional realism packs (DEM + satellite + OSM water & landuse)
python3 tools/bake_region_pack.py zugspitze
python3 tools/bake_region_pack.py pyrenees
```

### 2. Run in Godot 4
```bash
godot4 --path godot
```

### 3. Headless Simulation Stress Test
```bash
godot4 --headless --path godot -- --sim-test
```

## Controls
- **Pan**: Left/Middle-Drag, Two-Finger Pan, or `WASD` / Arrow Keys
- **Zoom**: Scroll Wheel, Pinch, or `+` / `-` / `PgUp` / `PgDn`
- **Orbit**: Right-Drag or `Q` / `E` (`R` = North-Up)
- **Tools**: `I` Inspect · `B` Station (`R`/`Shift+R` rotate, click 1-track station to upgrade to 2-track) · `T` Track (`L` double-track, `,`/`.` curve, `0` straight) · `N` Signals · `X` Demolish · `M` Lines & Trains
- **Speed**: `Space` Pause · `1` (`1x`) · `2` (`15x`) · `3` (`60x`) · `4` (`300x`)

## License & Attribution
- Source code: **[MIT License](LICENSE)**
- Third-party libraries & open geospatial datasets: **[ATTRIBUTION.md](ATTRIBUTION.md)**
