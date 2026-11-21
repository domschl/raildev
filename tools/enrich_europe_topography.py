#!/usr/bin/env python3
"""
Enrich Raildev's Europe 3D Atlas (godot/data/europe_height.f32, europe_splat.rgba, europe_meta.json)
with three real open-license geospatial datasets:
  1. Real European Elevation & Bathymetry: AWS Mapzen Terrarium DEM (z=6, CC0 / Public Domain)
     -> Real Alpine passes (Brenner, Gotthard, Semmering), Rhine gorge, Po plain, Norwegian fjords.
  2. Pixel-Accurate European Forest Cover: Copernicus CORINE Land Cover 2018 WMS (EEA EU Open Data)
     -> Real coniferous, broadleaf & mixed forests (Black Forest, Bavarian Forest, Landes, Ardennes,
        Alps, Carpathians, Scandinavia).
  3. Crisp European Rivers, Lakes & Glaciers: Natural Earth 1:10m (Public Domain CC0)
     -> 600+ real European rivers with realistic widths & 238 leveled inland lakes.

Uses only Python stdlib + ImageMagick (`magick`). All downloads are cached in tools/cache/.
"""

import array
import concurrent.futures
import json
import math
import os
import shutil
import subprocess
import sys
import urllib.request

MAP_W = 2048
MAP_H = 1536
HI_W = 4096
HI_H = 3072
LON_MIN = -10.5
LON_MAX = 26.5
LAT_MIN = 35.5
LAT_MAX = 59.5

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT_DIR, "godot", "data")
CACHE_DIR = os.path.join(ROOT_DIR, "tools", "cache")
NE_CACHE = os.path.join(CACHE_DIR, "natural_earth")
DEM_CACHE = os.path.join(CACHE_DIR, "terrarium_z7")

NE_BASE_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
CORINE_WMS_URL = (
    "https://image.discomap.eea.europa.eu/arcgis/services/Corine/CLC2018_WM/MapServer/WMSServer"
    f"?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=12&STYLES=&FORMAT=image/png"
    f"&SRS=EPSG:4326&BBOX={LON_MIN},{LAT_MIN},{LON_MAX},{LAT_MAX}&WIDTH={MAP_W}&HEIGHT={MAP_H}"
)
TERRARIUM_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


def lonlat_to_px(lon: float, lat: float):
    x = (lon - LON_MIN) / (LON_MAX - LON_MIN) * MAP_W
    y = (LAT_MAX - lat) / (LAT_MAX - LAT_MIN) * MAP_H
    return x, y


def lonlat_to_mercator_tile(lon: float, lat: float, z: int):
    n = 1 << z
    tx = (lon + 180.0) / 360.0 * n
    lat_rad = math.radians(lat)
    ty = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) * 0.5 * n
    return tx, ty


def decode_png_to_rgb(png_path: str) -> bytes:
    """Decode any PNG to raw 8-bit RGB bytes using ImageMagick."""
    res = subprocess.run(
        ["magick", png_path, "-alpha", "off", "-depth", "8", "rgb:-"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return res.stdout


def fetch_file(url: str, local_path: str, desc: str) -> str:
    os.makedirs(os.path.dirname(local_path), exist_ok=True)
    if not os.path.exists(local_path) or os.path.getsize(local_path) < 100:
        print(f"Downloading {desc}...")
        req = urllib.request.Request(url, headers={"User-Agent": "RaildevMapBaker/1.0"})
        with urllib.request.urlopen(req, timeout=45) as resp, open(local_path, "wb") as out:
            shutil.copyfileobj(resp, out)
    return local_path


def fetch_geojson(filename: str) -> dict:
    path = fetch_file(NE_BASE_URL + filename, os.path.join(NE_CACHE, filename), filename)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def build_real_dem_heightmap(out_w: int = HI_W, out_h: int = HI_H, z: int = 7) -> array.array:
    """Download AWS Mapzen Terrarium z=7 tiles covering Europe and resample to out_w x out_h float32."""
    tx_min_f, ty_min_f = lonlat_to_mercator_tile(LON_MIN, LAT_MAX, z)
    tx_max_f, ty_max_f = lonlat_to_mercator_tile(LON_MAX, LAT_MIN, z)
    tx0, tx1 = int(math.floor(tx_min_f)), int(math.floor(tx_max_f))
    ty0, ty1 = int(math.floor(ty_min_f)), int(math.floor(ty_max_f))

    os.makedirs(DEM_CACHE, exist_ok=True)
    tile_jobs = [(x, y) for y in range(ty0, ty1 + 1) for x in range(tx0, tx1 + 1)]

    def dl_tile(xy):
        x, y = xy
        p = os.path.join(DEM_CACHE, f"{z}_{x}_{y}.png")
        if not os.path.exists(p) or os.path.getsize(p) < 100:
            url = TERRARIUM_URL.format(z=z, x=x, y=y)
            req = urllib.request.Request(url, headers={"User-Agent": "RaildevMapBaker/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp, open(p, "wb") as out:
                shutil.copyfileobj(resp, out)
        return x, y, p

    print(f"Fetching {len(tile_jobs)} AWS Terrarium DEM tiles (z={z})...")
    tile_rgb = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
        for x, y, p in ex.map(dl_tile, tile_jobs):
            tile_rgb[(x, y)] = decode_png_to_rgb(p)

    # Precompute tile pixel coordinates per column & row for fast bilinear sampling
    n_tiles = 1 << z
    col_info = []
    for px in range(out_w):
        lon = LON_MIN + (px + 0.5) / out_w * (LON_MAX - LON_MIN)
        gx = (lon + 180.0) / 360.0 * n_tiles * 256.0
        col_info.append(gx)

    row_info = []
    for py in range(out_h):
        lat = LAT_MAX - (py + 0.5) / out_h * (LAT_MAX - LAT_MIN)
        lat_rad = math.radians(lat)
        gy = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) * 0.5 * n_tiles * 256.0
        row_info.append(gy)

    # Assemble stitched float elevation grid in tile space for super-fast bilinear lookup
    grid_w = (tx1 - tx0 + 1) * 256
    grid_h = (ty1 - ty0 + 1) * 256
    stitched = array.array("f", [0.0]) * (grid_w * grid_h)
    for (tx, ty), raw in tile_rgb.items():
        ox = (tx - tx0) * 256
        oy = (ty - ty0) * 256
        for ry in range(256):
            src_row = ry * 256 * 3
            dst_row = (oy + ry) * grid_w + ox
            for rx in range(256):
                off = src_row + rx * 3
                r, g, b = raw[off], raw[off + 1], raw[off + 2]
                stitched[dst_row + rx] = (r * 256.0 + g + b / 256.0) - 32768.0

    # Bilinear resample to out_w x out_h equirectangular
    heights = array.array("f", [0.0]) * (out_w * out_h)
    base_gx = tx0 * 256.0
    base_gy = ty0 * 256.0
    max_gx = grid_w - 1.001
    max_gy = grid_h - 1.001

    for py in range(out_h):
        fy = max(0.0, min(max_gy, row_info[py] - base_gy))
        y0 = int(fy)
        ty_f = fy - y0
        r0 = y0 * grid_w
        r1 = (y0 + 1) * grid_w
        out_row = py * out_w
        for px in range(out_w):
            fx = max(0.0, min(max_gx, col_info[px] - base_gx))
            x0 = int(fx)
            tx_f = fx - x0
            e00 = stitched[r0 + x0]
            e10 = stitched[r0 + x0 + 1]
            e01 = stitched[r1 + x0]
            e11 = stitched[r1 + x0 + 1]
            h = (e00 + (e10 - e00) * tx_f) * (1.0 - ty_f) + (e01 + (e11 - e01) * tx_f) * ty_f
            heights[out_row + px] = h

    print(f"Built real European DEM ({out_w}x{out_h}): min={min(heights):.0f}m, max={max(heights):.0f}m")
    return heights


def build_corine_forest_mask(heights: array.array) -> bytearray:
    """Download Copernicus CORINE Land Cover 2018 (2048x1536) and extract pixel-accurate forest density."""
    clc_path = fetch_file(
        CORINE_WMS_URL,
        os.path.join(CACHE_DIR, "corine_clc2018_2048x1536.png"),
        "Copernicus CORINE Land Cover 2018 (2048x1536)",
    )
    raw = decode_png_to_rgb(clc_path)
    assert len(raw) == MAP_W * MAP_H * 3, f"Unexpected CORINE RGB length {len(raw)}"

    # CORINE official palette forest & woodland classes:
    #   311 Broad-leaved forest:  (128, 255, 0)
    #   312 Coniferous forest:    (0, 166, 0)
    #   313 Mixed forest:         (77, 255, 0)
    #   324 Transitional shrub:   (166, 242, 0)
    #   323 Sclerophyllous veg:   (166, 230, 77)
    forest_raw = bytearray(MAP_W * MAP_H)
    forest_px = 0
    for i in range(MAP_W * MAP_H):
        if heights[i] < 5.0 or heights[i] > 1850.0:
            continue
        off = i * 3
        r, g, b = raw[off], raw[off + 1], raw[off + 2]
        # Strong green dominance with low blue = CORINE forest/woodland classes
        if g >= 140 and b <= 90 and (g - b) >= 100 and (g - r) >= 45:
            if r <= 100 and g <= 200:
                forest_raw[i] = 240  # Dense coniferous forest (312)
            elif r <= 145:
                forest_raw[i] = 225  # Mixed / broad-leaved forest (311/313)
            else:
                forest_raw[i] = 155  # Transitional woodland / shrub (324)
            forest_px += 1

    # Gentle 3x3 smoothing pass so forest boundaries blend organically into meadows
    forest_smooth = bytearray(MAP_W * MAP_H)
    for y in range(1, MAP_H - 1):
        row = y * MAP_W
        for x in range(1, MAP_W - 1):
            idx = row + x
            if heights[idx] < 5.0:
                continue
            s = (
                forest_raw[idx - MAP_W - 1] + forest_raw[idx - MAP_W] + forest_raw[idx - MAP_W + 1]
                + forest_raw[idx - 1] + forest_raw[idx] * 2 + forest_raw[idx + 1]
                + forest_raw[idx + MAP_W - 1] + forest_raw[idx + MAP_W] + forest_raw[idx + MAP_W + 1]
            )
            forest_smooth[idx] = s // 10

    print(f"Extracted pixel-accurate Copernicus CORINE forest cover ({forest_px} forest pixels).")
    return forest_smooth


def bbox_overlaps(coords) -> bool:
    for pt in coords:
        lon, lat = pt[0], pt[1]
        if (LON_MIN - 1.0) <= lon <= (LON_MAX + 1.0) and (LAT_MIN - 1.0) <= lat <= (LAT_MAX + 1.0):
            return True
    return False


def rasterize_polyline(water_buf: bytearray, heights: array.array, coords, core_r: float, bank_r: float):
    n = len(coords)
    if n < 2:
        return
    pxs = []
    any_in = False
    for pt in coords:
        x, y = lonlat_to_px(pt[0], pt[1])
        pxs.append((x, y))
        if -10 <= x <= MAP_W + 10 and -10 <= y <= MAP_H + 10:
            any_in = True
    if not any_in:
        return

    max_r = int(math.ceil(bank_r)) + 1
    core_r2 = core_r * core_r
    bank_r2 = bank_r * bank_r

    for i in range(n - 1):
        x0, y0 = pxs[i]
        x1, y1 = pxs[i + 1]
        if max(x0, x1) < -max_r or min(x0, x1) >= MAP_W + max_r:
            continue
        if max(y0, y1) < -max_r or min(y0, y1) >= MAP_H + max_r:
            continue

        min_x = max(0, int(math.floor(min(x0, x1))) - max_r)
        max_x = min(MAP_W - 1, int(math.ceil(max(x0, x1))) + max_r)
        min_y = max(0, int(math.floor(min(y0, y1))) - max_r)
        max_y = min(MAP_H - 1, int(math.ceil(max(y0, y1))) + max_r)

        dx = x1 - x0
        dy = y1 - y0
        seg_len2 = dx * dx + dy * dy
        inv_len2 = (1.0 / seg_len2) if seg_len2 > 1e-6 else 0.0

        for py in range(min_y, max_y + 1):
            row_off = py * MAP_W
            for px in range(min_x, max_x + 1):
                if heights[row_off + px] < -0.5:
                    continue
                if seg_len2 > 1e-6:
                    t = ((px + 0.5 - x0) * dx + (py + 0.5 - y0) * dy) * inv_len2
                    if t < 0.0:
                        t = 0.0
                    elif t > 1.0:
                        t = 1.0
                    cx = x0 + t * dx
                    cy = y0 + t * dy
                else:
                    cx, cy = x0, y0
                ddx = (px + 0.5) - cx
                ddy = (py + 0.5) - cy
                d2 = ddx * ddx + ddy * ddy
                if d2 > bank_r2:
                    continue
                if d2 <= core_r2:
                    val = 220
                else:
                    d = math.sqrt(d2)
                    frac = (d - core_r) / max(0.01, bank_r - core_r)
                    # Crisp falloff: water core stays tight, bank halo stays green (< 130)
                    val = int(round(190.0 * (1.0 - frac) * (1.0 - frac)))
                idx = row_off + px
                if val > water_buf[idx]:
                    water_buf[idx] = val


def scanline_fill_polygon(ring_px):
    if len(ring_px) < 3:
        return []
    ys = [p[1] for p in ring_px]
    min_y = max(0, int(math.floor(min(ys))))
    max_y = min(MAP_H - 1, int(math.ceil(max(ys))))
    if min_y > max_y:
        return []

    spans = []
    n = len(ring_px)
    for y in range(min_y, max_y + 1):
        sy = y + 0.5
        xs = []
        j = n - 1
        for i in range(n):
            xi, yi = ring_px[i]
            xj, yj = ring_px[j]
            if (yi <= sy < yj) or (yj <= sy < yi):
                xs.append(xi + (sy - yi) * (xj - xi) / (yj - yi))
            j = i
        if len(xs) < 2:
            continue
        xs.sort()
        for k in range(0, len(xs) - 1, 2):
            x0 = max(0, int(math.floor(xs[k])))
            x1 = min(MAP_W - 1, int(math.ceil(xs[k + 1])))
            if x0 <= x1:
                spans.append((y, x0, x1))
    return spans


def process_polygon_rings(rings, on_spans):
    if not rings or not bbox_overlaps(rings[0]):
        return
    outer_px = [lonlat_to_px(pt[0], pt[1]) for pt in rings[0]]
    spans = scanline_fill_polygon(outer_px)
    if spans:
        on_spans(spans)


def main():
    height_path = os.path.join(DATA_DIR, "europe_height.f32")
    height_hi_path = os.path.join(DATA_DIR, "europe_height_hi.f32")
    splat_path = os.path.join(DATA_DIR, "europe_splat.rgba")
    meta_path = os.path.join(DATA_DIR, "europe_meta.json")
    splat_base = os.path.join(DATA_DIR, "europe_splat.base.rgba")

    if not os.path.exists(splat_base):
        shutil.copy2(splat_path, splat_base)
    with open(splat_base, "rb") as f:
        splat = bytearray(f.read())

    # 1. Real High-Res European DEM (AWS Mapzen Terrarium z=7 -> 4096x3072 + 2048x1536 CPU copy)
    heights_hi = build_real_dem_heightmap(HI_W, HI_H, z=7)
    heights = array.array("f", [0.0]) * (MAP_W * MAP_H)
    for y in range(MAP_H):
        r0 = (y * 2) * HI_W
        r1 = (y * 2 + 1) * HI_W
        out_r = y * MAP_W
        for x in range(MAP_W):
            hx = x * 2
            heights[out_r + x] = 0.25 * (
                heights_hi[r0 + hx] + heights_hi[r0 + hx + 1]
                + heights_hi[r1 + hx] + heights_hi[r1 + hx + 1]
            )

    # 2. Pixel-accurate European Forest Cover (Copernicus CORINE 2018)
    forest_buf = build_corine_forest_mask(heights)

    # 3. Crisp Natural Earth 1:10m Rivers (realistic thin proportions!)
    water_buf = bytearray(MAP_W * MAP_H)
    lake_mask = bytearray(MAP_W * MAP_H)

    river_count = 0
    for rfile in ("ne_10m_rivers_lake_centerlines.geojson", "ne_10m_rivers_europe.geojson"):
        gj = fetch_geojson(rfile)
        is_supp = "europe" in rfile
        for feat in gj.get("features", []):
            geom = feat.get("geometry")
            if not geom:
                continue
            props = feat.get("properties") or {}
            sr = float(props.get("scalerank") or 7)
            # Crisp, realistically proportioned & 100% continuous river widths (min core_r >= 0.54 avoids dashed gaps!)
            if sr <= 3:
                core_r, bank_r = 0.85, 2.1
            elif sr <= 5:
                core_r, bank_r = 0.68, 1.65
            elif sr <= 7:
                core_r, bank_r = 0.58, 1.35
            else:
                core_r, bank_r = 0.54, 1.20

            gtype = geom.get("type")
            coords = geom.get("coordinates", [])
            if gtype == "LineString":
                if bbox_overlaps(coords):
                    rasterize_polyline(water_buf, heights, coords, core_r, bank_r)
                    river_count += 1
            elif gtype == "MultiLineString":
                for line in coords:
                    if bbox_overlaps(line):
                        rasterize_polyline(water_buf, heights, line, core_r, bank_r)
                        river_count += 1
    print(f"Rasterized {river_count} crisp European river segments.")

    # 4. Crisp Natural Earth 1:10m Lakes (exact polygon interior, zero outward bloat!)
    lake_count = 0
    lake_pixels = 0

    def fill_lake_spans(spans):
        nonlocal lake_count, lake_pixels
        elevs = []
        for y, x0, x1 in spans:
            row_off = y * MAP_W
            for x in range(x0, x1 + 1):
                e = heights[row_off + x]
                if e > 0.2:
                    elevs.append(e)
        if not elevs:
            return
        elevs.sort()
        lake_elev = elevs[len(elevs) // 4]
        lake_count += 1

        for y, x0, x1 in spans:
            row_off = y * MAP_W
            r_hi0 = (y * 2) * HI_W
            r_hi1 = (y * 2 + 1) * HI_W
            for x in range(x0, x1 + 1):
                idx = row_off + x
                if heights[idx] < -0.5:
                    continue
                heights[idx] = lake_elev
                hx = x * 2
                heights_hi[r_hi0 + hx] = lake_elev
                heights_hi[r_hi0 + hx + 1] = lake_elev
                heights_hi[r_hi1 + hx] = lake_elev
                heights_hi[r_hi1 + hx + 1] = lake_elev
                water_buf[idx] = 255
                lake_mask[idx] = 1
                lake_pixels += 1

        # Subtle 1px green shore tint only (65 < blue threshold 158, never inflates lake width!)
        for y, x0, x1 in spans:
            for bx in (x0 - 1, x1 + 1):
                if 0 <= bx < MAP_W:
                    idx = y * MAP_W + bx
                    if heights[idx] >= 0.0 and water_buf[idx] < 65:
                        water_buf[idx] = 65

    for lfile in ("ne_10m_lakes.geojson", "ne_10m_lakes_europe.geojson"):
        gj = fetch_geojson(lfile)
        for feat in gj.get("features", []):
            geom = feat.get("geometry")
            if not geom:
                continue
            gtype = geom.get("type")
            coords = geom.get("coordinates", [])
            if gtype == "Polygon":
                process_polygon_rings(coords, fill_lake_spans)
            elif gtype == "MultiPolygon":
                for poly in coords:
                    process_polygon_rings(poly, fill_lake_spans)
    print(f"Rasterized {lake_count} crisp European lakes ({lake_pixels} pixels, leveled).")

    # 5. Update city elevations in europe_meta.json from the real DEM (keeping coastal cities >= 3m)
    if os.path.exists(meta_path):
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
        for city in meta.get("cities", []):
            cx = max(0, min(MAP_W - 1, int(round(float(city["x"])))))
            cy = max(0, min(MAP_H - 1, int(round(float(city["y"])))))
            e = heights[cy * MAP_W + cx]
            if e < 3.0:
                # Ensure historic coastal/canal cities (Venice, Amsterdam, etc.) stay above sea level
                for dy in range(-3, 4):
                    for dx in range(-3, 4):
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < MAP_W and 0 <= ny < MAP_H and heights[ny * MAP_W + nx] < 3.0:
                            heights[ny * MAP_W + nx] = max(heights[ny * MAP_W + nx], 3.0)
                e = 3.0
            city["elev"] = round(float(e), 1)
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(meta, f)

    # 6. Combine CORINE forests + Natural Earth water into splat.rgba (keep existing roads & med biome)
    for i in range(MAP_W * MAP_H):
        w = water_buf[i]
        s_idx = i * 4
        splat[s_idx] = 0 if w >= 145 else forest_buf[i]
        splat[s_idx + 1] = w
        if lake_mask[i]:
            splat[s_idx + 2] = 0

    with open(height_path, "wb") as f:
        f.write(heights.tobytes())
    with open(height_hi_path, "wb") as f:
        f.write(heights_hi.tobytes())
    with open(splat_path, "wb") as f:
        f.write(splat)

    print("Done! Baked 4096x3072 z=7 Terrarium DEM + CORINE 2018 forests + crisp Natural Earth rivers/lakes.")


if __name__ == "__main__":
    main()
