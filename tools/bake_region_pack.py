#!/usr/bin/env python3
"""
Modular Regional High-Resolution DEM Pack Baker for Raildev 3D Europe Atlas.
Downloads AWS Mapzen Terrarium z=9 (~220m/pixel) tiles for a named mountain region
and bakes a seamless float32 inset pack into godot/data/packs/<name>_height.f32
+ <name>_pack.json.

Usage:
  python3 tools/bake_region_pack.py alps
  python3 tools/bake_region_pack.py pyrenees
"""

import array
import concurrent.futures
import json
import math
import os
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

EUROPE_LON_MIN = -10.5
EUROPE_LON_MAX = 26.5
EUROPE_LAT_MIN = 35.5
EUROPE_LAT_MAX = 59.5

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKS_DIR = os.path.join(ROOT_DIR, "godot", "data", "packs")
CACHE_DIR = os.path.join(ROOT_DIR, "tools", "cache")
NE_CACHE = os.path.join(CACHE_DIR, "natural_earth")
DEM_CACHE = os.path.join(CACHE_DIR, "terrarium_z9")
TERRARIUM_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
EOX_S2_WMS_URL = (
    "https://tiles.maps.eox.at/wms?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap"
    "&LAYERS=s2cloudless-2021&STYLES=&FORMAT=image/jpeg&SRS=EPSG:4326"
    "&BBOX={lon0},{lat0},{lon1},{lat1}&WIDTH={w}&HEIGHT={h}"
)

# Predefined high-res regional mountain option packs (lon_min, lon_max, lat_min, lat_max, out_w, out_h, z)
PACKS = {
    "zugspitze": {
        "title": "Munich - Zugspitze - Innsbruck Ultra Pack (~40m/px, z=11)",
        "lon_min": 10.4, "lon_max": 12.6,
        "lat_min": 47.0, "lat_max": 48.3,
        "width": 4096, "height": 3072, "z": 11,
    },
    "alps": {
        "title": "Alpine Realism Pack (Mont Blanc to Vienna, ~220m/px)",
        "lon_min": 5.0, "lon_max": 16.5,
        "lat_min": 44.2, "lat_max": 48.2,
        "width": 4096, "height": 2048, "z": 9,
    },
    "pyrenees": {
        "title": "Pyrenees Realism Pack (Pic d'Aneto & Central Pyrenees, ~80m/px, z=10)",
        "lon_min": -1.6, "lon_max": 2.4,
        "lat_min": 42.1, "lat_max": 43.4,
        "width": 4096, "height": 2048, "z": 10,
    },
    "carpathians": {
        "title": "Carpathians Realism Pack (~220m/px)",
        "lon_min": 18.0, "lon_max": 26.4,
        "lat_min": 44.5, "lat_max": 49.8,
        "width": 3072, "height": 2048, "z": 9,
    },
    "norway": {
        "title": "Norwegian Fjords Realism Pack (~220m/px)",
        "lon_min": 4.5, "lon_max": 12.5,
        "lat_min": 57.8, "lat_max": 59.5,
        "width": 3072, "height": 1024, "z": 9,
    },
}


def lonlat_to_mercator_tile(lon: float, lat: float, z: int):
    n = 1 << z
    tx = (lon + 180.0) / 360.0 * n
    lat_rad = math.radians(lat)
    ty = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) * 0.5 * n
    return tx, ty


def decode_png_to_rgb(png_path: str) -> bytes:
    res = subprocess.run(
        ["magick", png_path, "-alpha", "off", "-depth", "8", "rgb:-"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return res.stdout


def scanline_fill_polygon(ring_px, out_w: int, out_h: int):
    if len(ring_px) < 3:
        return []
    ys = [p[1] for p in ring_px]
    min_y = max(0, int(math.floor(min(ys))))
    max_y = min(out_h - 1, int(math.ceil(max(ys))))
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
            x1 = min(out_w - 1, int(math.ceil(xs[k + 1])))
            if x0 <= x1:
                spans.append((y, x0, x1))
    return spans


def bake_pack(pack_name: str):
    if pack_name not in PACKS:
        print(f"Unknown pack '{pack_name}'. Available: {', '.join(PACKS.keys())}", file=sys.stderr)
        sys.exit(1)

    cfg = PACKS[pack_name]
    lon_min, lon_max = cfg["lon_min"], cfg["lon_max"]
    lat_min, lat_max = cfg["lat_min"], cfg["lat_max"]
    out_w, out_h, z = cfg["width"], cfg["height"], cfg["z"]

    tx_min_f, ty_min_f = lonlat_to_mercator_tile(lon_min, lat_max, z)
    tx_max_f, ty_max_f = lonlat_to_mercator_tile(lon_max, lat_min, z)
    tx0, tx1 = int(math.floor(tx_min_f)), int(math.floor(tx_max_f))
    ty0, ty1 = int(math.floor(ty_min_f)), int(math.floor(ty_max_f))

    tile_cache_dir = os.path.join(CACHE_DIR, f"terrarium_z{z}")
    os.makedirs(tile_cache_dir, exist_ok=True)
    os.makedirs(PACKS_DIR, exist_ok=True)
    tile_jobs = [(x, y) for y in range(ty0, ty1 + 1) for x in range(tx0, tx1 + 1)]

    def dl_tile(xy):
        x, y = xy
        p = os.path.join(tile_cache_dir, f"{z}_{x}_{y}.png")
        if not os.path.exists(p) or os.path.getsize(p) < 100:
            url = TERRARIUM_URL.format(z=z, x=x, y=y)
            req = urllib.request.Request(url, headers={"User-Agent": "RaildevRegionPack/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp, open(p, "wb") as out:
                shutil.copyfileobj(resp, out)
        return x, y, p

    print(f"[{pack_name}] {cfg['title']}")
    print(f"Fetching {len(tile_jobs)} AWS Terrarium z={z} tiles...")
    tile_rgb = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        for x, y, p in ex.map(dl_tile, tile_jobs):
            tile_rgb[(x, y)] = decode_png_to_rgb(p)

    # Assemble stitched float32 elevation grid in tile space
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

    # Bilinear resample to pack equirectangular grid
    n_tiles = 1 << z
    col_gx = [
        (lon_min + (px + 0.5) / out_w * (lon_max - lon_min) + 180.0) / 360.0 * n_tiles * 256.0
        for px in range(out_w)
    ]
    row_gy = []
    for py in range(out_h):
        lat = lat_max - (py + 0.5) / out_h * (lat_max - lat_min)
        lat_rad = math.radians(lat)
        gy = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) * 0.5 * n_tiles * 256.0
        row_gy.append(gy)

    heights = array.array("f", [0.0]) * (out_w * out_h)
    base_gx = tx0 * 256.0
    base_gy = ty0 * 256.0
    max_gx = grid_w - 1.001
    max_gy = grid_h - 1.001

    for py in range(out_h):
        fy = max(0.0, min(max_gy, row_gy[py] - base_gy))
        y0 = int(fy)
        ty_f = fy - y0
        r0 = y0 * grid_w
        r1 = (y0 + 1) * grid_w
        out_row = py * out_w
        for px in range(out_w):
            fx = max(0.0, min(max_gx, col_gx[px] - base_gx))
            x0 = int(fx)
            tx_f = fx - x0
            e00 = stitched[r0 + x0]
            e10 = stitched[r0 + x0 + 1]
            e01 = stitched[r1 + x0]
            e11 = stitched[r1 + x0 + 1]
            heights[out_row + px] = (e00 + (e10 - e00) * tx_f) * (1.0 - ty_f) + (e01 + (e11 - e01) * tx_f) * ty_f

    # Level Natural Earth lakes inside this pack cleanly at full inset resolution
    lakes_leveled = 0
    for lfile in ("ne_10m_lakes.geojson", "ne_10m_lakes_europe.geojson"):
        lp = os.path.join(NE_CACHE, lfile)
        if not os.path.exists(lp):
            continue
        with open(lp, "r", encoding="utf-8") as f:
            gj = json.load(f)
        for feat in gj.get("features", []):
            geom = feat.get("geometry")
            if not geom:
                continue
            polys = [geom["coordinates"]] if geom["type"] == "Polygon" else (geom["coordinates"] if geom["type"] == "MultiPolygon" else [])
            for poly in polys:
                if not poly:
                    continue
                ring = poly[0]
                if not any((lon_min - 0.5) <= pt[0] <= (lon_max + 0.5) and (lat_min - 0.5) <= pt[1] <= (lat_max + 0.5) for pt in ring):
                    continue
                ring_px = [
                    ((pt[0] - lon_min) / (lon_max - lon_min) * out_w, (lat_max - pt[1]) / (lat_max - lat_min) * out_h)
                    for pt in ring
                ]
                spans = scanline_fill_polygon(ring_px, out_w, out_h)
                if not spans:
                    continue
                elevs = []
                for y, x0, x1 in spans:
                    ro = y * out_w
                    for x in range(x0, x1 + 1):
                        if heights[ro + x] > 0.2:
                            elevs.append(heights[ro + x])
                if not elevs:
                    continue
                elevs.sort()
                le = elevs[len(elevs) // 4]
                for y, x0, x1 in spans:
                    ro = y * out_w
                    for x in range(x0, x1 + 1):
                        if heights[ro + x] >= -0.5:
                            heights[ro + x] = le
                lakes_leveled += 1

    # Compute Europe UV rectangle [u0, v0, du, dv]
    u0 = (lon_min - EUROPE_LON_MIN) / (EUROPE_LON_MAX - EUROPE_LON_MIN)
    u1 = (lon_max - EUROPE_LON_MIN) / (EUROPE_LON_MAX - EUROPE_LON_MIN)
    v0 = (EUROPE_LAT_MAX - lat_max) / (EUROPE_LAT_MAX - EUROPE_LAT_MIN)
    v1 = (EUROPE_LAT_MAX - lat_min) / (EUROPE_LAT_MAX - EUROPE_LAT_MIN)

    bin_path = os.path.join(PACKS_DIR, f"{pack_name}_height.f32")
    meta_path = os.path.join(PACKS_DIR, f"{pack_name}_pack.json")
    with open(bin_path, "wb") as f:
        f.write(heights.tobytes())

    # Fetch & transform EOX Sentinel-2 Cloudless satellite imagery into an albedo-balanced game texture!
    sat_out = os.path.join(PACKS_DIR, f"{pack_name}_albedo.jpg")
    sat_cache_dir = os.path.join(CACHE_DIR, f"s2_{pack_name}")
    os.makedirs(sat_cache_dir, exist_ok=True)
    # Download in 2x2 tiles (each <= 2048px) and stitch + color-grade to match the 3D atlas palette
    qx, qy = 2, 2
    tw, th = out_w // qx, out_h // qy
    lon_mid = 0.5 * (lon_min + lon_max)
    lat_mid = 0.5 * (lat_min + lat_max)
    quads = [
        ("tl", lon_min, lat_mid, lon_mid, lat_max),
        ("tr", lon_mid, lat_mid, lon_max, lat_max),
        ("bl", lon_min, lat_min, lon_mid, lat_mid),
        ("br", lon_mid, lat_min, lon_max, lat_mid),
    ]

    def dl_sat(q):
        tag, x0, y0, x1, y1 = q
        p = os.path.join(sat_cache_dir, f"{tag}_{tw}x{th}.jpg")
        if not os.path.exists(p) or os.path.getsize(p) < 1000:
            url = EOX_S2_WMS_URL.format(lon0=x0, lat0=y0, lon1=x1, lat1=y1, w=tw, h=th)
            req = urllib.request.Request(url, headers={"User-Agent": "RaildevRegionPack/1.0"})
            with urllib.request.urlopen(req, timeout=45) as resp, open(p, "wb") as out:
                shutil.copyfileobj(resp, out)
        return tag, p

    print(f"[{pack_name}] Fetching & transforming Sentinel-2 Cloudless satellite imagery ({out_w}x{out_h})...")
    qpaths = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        for tag, p in ex.map(dl_sat, quads):
            qpaths[tag] = p

    # Stitch 2x2 quads and lift dark satellite reflectance into warm, albedo-balanced game texture
    subprocess.run([
        "magick",
        "(", qpaths["tl"], qpaths["tr"], "+append", ")",
        "(", qpaths["bl"], qpaths["br"], "+append", ")",
        "-append",
        "-gamma", "1.45",
        "-modulate", "126,112,100",
        "-quality", "90",
        sat_out,
    ], check=True)

    meta = {
        "name": pack_name,
        "title": cfg["title"],
        "width": out_w,
        "height": out_h,
        "uv_rect": [u0, v0, u1 - u0, v1 - v0],
        "has_albedo": True,
        "min_m": round(float(min(heights)), 1),
        "max_m": round(float(max(heights)), 1),
    }
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"[{pack_name}] Done! {out_w}x{out_h}, min={meta['min_m']}m, max={meta['max_m']}m, leveled {lakes_leveled} lakes.")
    print(f"  -> {bin_path}")
    print(f"  -> {sat_out}")
    print(f"  -> {meta_path}")


def bake_europe_albedo(out_w: int = 4096, out_h: int = 3072):
    """Fetch & transform continental Sentinel-2 Cloudless 2021 satellite albedo for ALL of Europe."""
    sat_out = os.path.join(ROOT_DIR, "godot", "data", "europe_albedo.jpg")
    sat_cache_dir = os.path.join(CACHE_DIR, "s2_europe")
    os.makedirs(sat_cache_dir, exist_ok=True)
    tw, th = out_w // 2, out_h // 2
    lon_mid = 0.5 * (EUROPE_LON_MIN + EUROPE_LON_MAX)
    lat_mid = 0.5 * (EUROPE_LAT_MIN + EUROPE_LAT_MAX)
    quads = [
        ("tl", EUROPE_LON_MIN, lat_mid, lon_mid, EUROPE_LAT_MAX),
        ("tr", lon_mid, lat_mid, EUROPE_LON_MAX, EUROPE_LAT_MAX),
        ("bl", EUROPE_LON_MIN, EUROPE_LAT_MIN, lon_mid, lat_mid),
        ("br", lon_mid, EUROPE_LAT_MIN, EUROPE_LON_MAX, lat_mid),
    ]

    def dl_sat(q):
        tag, x0, y0, x1, y1 = q
        p = os.path.join(sat_cache_dir, f"{tag}_{tw}x{th}.jpg")
        if not os.path.exists(p) or os.path.getsize(p) < 1000:
            url = EOX_S2_WMS_URL.format(lon0=x0, lat0=y0, lon1=x1, lat1=y1, w=tw, h=th)
            req = urllib.request.Request(url, headers={"User-Agent": "RaildevRegionPack/1.0"})
            with urllib.request.urlopen(req, timeout=60) as resp, open(p, "wb") as out:
                shutil.copyfileobj(resp, out)
        return tag, p

    print(f"[europe] Fetching & transforming continental Sentinel-2 Cloudless albedo ({out_w}x{out_h})...")
    qpaths = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        for tag, p in ex.map(dl_sat, quads):
            qpaths[tag] = p

    subprocess.run([
        "magick",
        "(", qpaths["tl"], qpaths["tr"], "+append", ")",
        "(", qpaths["bl"], qpaths["br"], "+append", ")",
        "-append",
        "-gamma", "1.45",
        "-modulate", "126,112,100",
        "-quality", "90",
        sat_out,
    ], check=True)
    print(f"[europe] Done! -> {sat_out}")


def _assemble_rings(ways_pts):
    """Stitch unordered OSM relation member segments into closed polygon rings."""
    segs = [list(w) for w in ways_pts if len(w) >= 2]
    rings = []
    while segs:
        cur = segs.pop(0)
        changed = True
        while changed and len(cur) >= 2 and cur[0] != cur[-1]:
            changed = False
            for i, s in enumerate(segs):
                if s[0] == cur[-1]:
                    cur.extend(s[1:])
                    segs.pop(i)
                    changed = True
                    break
                elif s[-1] == cur[-1]:
                    cur.extend(list(reversed(s[:-1])))
                    segs.pop(i)
                    changed = True
                    break
                elif s[-1] == cur[0]:
                    cur = s[:-1] + cur
                    segs.pop(i)
                    changed = True
                    break
                elif s[0] == cur[0]:
                    cur = list(reversed(s[1:])) + cur
                    segs.pop(i)
                    changed = True
                    break
        if len(cur) >= 3:
            rings.append(cur)
    return rings


def bake_osm_water_mask(pack_name: str):
    """Fetch & extract pixel-accurate OpenStreetMap lakes & rivers (EOX osm WMS, EPSG:4326) into <pack>_water.png."""
    if pack_name not in PACKS:
        print(f"Unknown pack '{pack_name}'.", file=sys.stderr)
        sys.exit(1)

    from PIL import Image, ImageFilter

    cfg = PACKS[pack_name]
    lon_min, lon_max = cfg["lon_min"], cfg["lon_max"]
    lat_min, lat_max = cfg["lat_min"], cfg["lat_max"]
    out_w, out_h = cfg["width"], cfg["height"]

    water_cache_dir = os.path.join(CACHE_DIR, f"eox_osm_{pack_name}")
    os.makedirs(water_cache_dir, exist_ok=True)
    os.makedirs(PACKS_DIR, exist_ok=True)
    water_out = os.path.join(PACKS_DIR, f"{pack_name}_water.png")

    eox_osm_url = (
        "https://tiles.maps.eox.at/wms?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap"
        "&LAYERS=osm&STYLES=&FORMAT=image/png&SRS=EPSG:4326"
        "&BBOX={lon0},{lat0},{lon1},{lat1}&WIDTH={w}&HEIGHT={h}"
    )

    tw, th = out_w // 2, out_h // 2
    lon_mid = 0.5 * (lon_min + lon_max)
    lat_mid = 0.5 * (lat_min + lat_max)
    quads = [
        ("tl", lon_min, lat_mid, lon_mid, lat_max),
        ("tr", lon_mid, lat_mid, lon_max, lat_max),
        ("bl", lon_min, lat_min, lon_mid, lat_mid),
        ("br", lon_mid, lat_min, lon_max, lat_mid),
    ]

    def dl_osm(q):
        tag, x0, y0, x1, y1 = q
        p = os.path.join(water_cache_dir, f"{tag}_{tw}x{th}.img")
        if not os.path.exists(p) or os.path.getsize(p) < 1000:
            url = eox_osm_url.format(lon0=x0, lat0=y0, lon1=x1, lat1=y1, w=tw, h=th)
            req = urllib.request.Request(url, headers={"User-Agent": "RaildevRegionPack/1.0"})
            with urllib.request.urlopen(req, timeout=45) as resp, open(p, "wb") as out:
                shutil.copyfileobj(resp, out)
        return tag, p

    print(f"[{pack_name}] Fetching EOX OpenStreetMap hydrography ({out_w}x{out_h}, EPSG:4326)...")
    qpaths = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        for tag, p in ex.map(dl_osm, quads):
            qpaths[tag] = p

    # Stitch 2x2 quads into full-res RGB image
    full = Image.new("RGB", (out_w, out_h))
    full.paste(Image.open(qpaths["tl"]).convert("RGB"), (0, 0))
    full.paste(Image.open(qpaths["tr"]).convert("RGB"), (tw, 0))
    full.paste(Image.open(qpaths["bl"]).convert("RGB"), (0, th))
    full.paste(Image.open(qpaths["br"]).convert("RGB"), (tw, th))

    # Extract EOX OSM steel-blue water signature:
    # - Core lakes/wide rivers: B > 164, B - R >= 20, B >= G + 6, G >= R + 4
    # - Thin anti-aliased mountain rivers (Isar, Loisach, Lech): B > 148, B - R >= 13, B >= G + 4, R < 208
    #   (Zero overlap with orange motorways, yellow roads, grey railways, or sage-green forests where G > B!)
    raw_rgb = full.tobytes()
    n_px = out_w * out_h
    mask_bytes = bytearray(n_px)
    river_bytes = bytearray(n_px)
    water_count = 0
    for i in range(n_px):
        o = i * 3
        r = raw_rgb[o]
        g = raw_rgb[o + 1]
        b = raw_rgb[o + 2]
        if b > 164 and (b - r) >= 20 and (b - g) >= 6 and (g - r) >= 4 and r < 205:
            mask_bytes[i] = 255
            water_count += 1
        elif b > 148 and (b - r) >= 13 and (b - g) >= 4 and (g - r) >= 2 and r < 208:
            river_bytes[i] = 255

    raw_mask = Image.frombytes("L", (out_w, out_h), bytes(mask_bytes))
    # Bridge-gap closing on thin river channels (closes 2-4px road/bridge crossings & tiny label breaks
    # along rivers like Isar south of Munich -> continuous mountain rivers!)
    river_im = Image.frombytes("L", (out_w, out_h), bytes(river_bytes))
    river_closed = river_im.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(3))
    rc_b = river_closed.tobytes()
    for i in range(n_px):
        if mask_bytes[i] == 0 and rc_b[i] > 128:
            mask_bytes[i] = 255
            water_count += 1
    raw_mask = Image.frombytes("L", (out_w, out_h), bytes(mask_bytes))

    # Eliminate rectangular OSM text-label cut-outs (e.g. "Lake Starnberg", "Tutzing", "Ammersee")
    # by flood-filling from OSM water pixels ONLY across pixels that are dark water in Sentinel-2
    # AND are OSM text/halo (not OSM sage-green forest!) -> zero rectangular holes, zero shore speckles!
    sat_path = os.path.join(PACKS_DIR, f"{pack_name}_albedo.jpg")
    if os.path.exists(sat_path):
        sat_im = Image.open(sat_path).convert("RGB")
        if sat_im.size != (out_w, out_h):
            sat_im = sat_im.resize((out_w, out_h), Image.BILINEAR)
        sat_rgb = sat_im.tobytes()
        # Seed BFS from boundary pixels of OSM water, expanding only <= 28px into dark Sentinel-2 lake water
        q = []
        dist_map = bytearray(n_px)
        for y in range(1, out_h - 1):
            row = y * out_w
            for x in range(1, out_w - 1):
                idx = row + x
                if mask_bytes[idx] == 255:
                    if (mask_bytes[idx - 1] == 0 or mask_bytes[idx + 1] == 0
                            or mask_bytes[idx - out_w] == 0 or mask_bytes[idx + out_w] == 0):
                        q.append(idx)
                        dist_map[idx] = 1
        head = 0
        while head < len(q):
            cur = q[head]
            head += 1
            d = dist_map[cur]
            if d >= 28:
                continue
            cx = cur % out_w
            cy = cur // out_w
            for nb in (cur - 1, cur + 1, cur - out_w, cur + out_w):
                if nb < 0 or nb >= n_px or mask_bytes[nb] == 255 or dist_map[nb] != 0:
                    continue
                if abs((nb % out_w) - cx) > 1:
                    continue
                o = nb * 3
                # Must NOT be OSM green forest or orange motorway
                or_, og_, ob_ = raw_rgb[o], raw_rgb[o + 1], raw_rgb[o + 2]
                if (og_ - ob_) >= 8 or (or_ - ob_) >= 25:
                    continue
                # Must be dark water in Sentinel-2 (not bright land/urban)
                sr, sg, sb = sat_rgb[o], sat_rgb[o + 1], sat_rgb[o + 2]
                if sr < 50 and sg < 72 and sb < 84 and (sr + sg + sb) < 190:
                    mask_bytes[nb] = 255
                    dist_map[nb] = d + 1
                    water_count += 1
                    q.append(nb)
        raw_mask = Image.frombytes("L", (out_w, out_h), bytes(mask_bytes))

    # Fill any tiny remaining enclosed text-stroke holes (<= 450 px) via BFS flood-fill (zero boxy edges!)
    visited = bytearray(n_px)
    for y in range(1, out_h - 1):
        row = y * out_w
        for x in range(1, out_w - 1):
            idx = row + x
            if mask_bytes[idx] == 0 and visited[idx] == 0:
                # Only start BFS if adjacent to water (fast!)
                if mask_bytes[idx - 1] == 0 and mask_bytes[idx - out_w] == 0:
                    continue
                comp = [idx]
                visited[idx] = 1
                touches_border = False
                head = 0
                too_big = False
                while head < len(comp):
                    cur = comp[head]
                    head += 1
                    cx = cur % out_w
                    cy = cur // out_w
                    if cx == 0 or cx == out_w - 1 or cy == 0 or cy == out_h - 1:
                        touches_border = True
                    for nb in (cur - 1, cur + 1, cur - out_w, cur + out_w):
                        if 0 <= nb < n_px and mask_bytes[nb] == 0 and visited[nb] == 0:
                            visited[nb] = 1
                            if len(comp) < 460:
                                comp.append(nb)
                            else:
                                too_big = True
                if not touches_border and not too_big and len(comp) <= 450:
                    for cidx in comp:
                        mask_bytes[cidx] = 255

    raw_mask = Image.frombytes("L", (out_w, out_h), bytes(mask_bytes))
    # Distinguish lakes (interior after 7px erosion -> 255) from narrow rivers (190) cleanly
    lake_core = raw_mask.filter(ImageFilter.MinFilter(7)).filter(ImageFilter.MaxFilter(7))

    mb = raw_mask.tobytes()
    lb = lake_core.tobytes()
    out_bytes = bytearray(n_px)
    for i in range(n_px):
        if lb[i] > 128:
            out_bytes[i] = 255
        elif mb[i] > 128:
            out_bytes[i] = 190

    out_img = Image.frombytes("L", (out_w, out_h), bytes(out_bytes))
    out_img = out_img.filter(ImageFilter.GaussianBlur(radius=0.7))
    out_img.save(water_out, optimize=True)
    pct = 100.0 * water_count / float(n_px)
    print(f"[{pack_name}] Baked pixel-accurate OSM+Sentinel2 water mask ({out_w}x{out_h}, {pct:.2f}% water) -> {water_out}")


def bake_osm_landuse_mask(pack_name: str):
    """Extract offline RGB landuse mask (R=forest, G=urban, B=roads) from cached EOX OSM + Sentinel-2."""
    if pack_name not in PACKS:
        print(f"Unknown pack '{pack_name}'.", file=sys.stderr)
        sys.exit(1)

    from PIL import Image, ImageFilter

    cfg = PACKS[pack_name]
    out_w, out_h = cfg["width"], cfg["height"]
    tw, th = out_w // 2, out_h // 2
    lu_w, lu_h = out_w // 2, out_h // 2  # Half-res (80-160m/px) -> fast CPU sampling & tiny PNG!

    water_cache_dir = os.path.join(CACHE_DIR, f"eox_osm_{pack_name}")
    qpaths = {tag: os.path.join(water_cache_dir, f"{tag}_{tw}x{th}.img") for tag in ("tl", "tr", "bl", "br")}
    if not all(os.path.exists(p) for p in qpaths.values()):
        bake_osm_water_mask(pack_name)

    full = Image.new("RGB", (out_w, out_h))
    full.paste(Image.open(qpaths["tl"]).convert("RGB"), (0, 0))
    full.paste(Image.open(qpaths["tr"]).convert("RGB"), (tw, 0))
    full.paste(Image.open(qpaths["bl"]).convert("RGB"), (0, th))
    full.paste(Image.open(qpaths["br"]).convert("RGB"), (tw, th))
    osm_half = full.resize((lu_w, lu_h), Image.BILINEAR)
    osm_rgb = osm_half.tobytes()

    sat_path = os.path.join(PACKS_DIR, f"{pack_name}_albedo.jpg")
    sat_rgb = None
    if os.path.exists(sat_path):
        sat_im = Image.open(sat_path).convert("RGB").resize((lu_w, lu_h), Image.BILINEAR)
        sat_rgb = sat_im.tobytes()

    n_px = lu_w * lu_h
    r_ch = bytearray(n_px)  # Forest
    g_ch = bytearray(n_px)  # Urban / residential
    b_ch = bytearray(n_px)  # Major roads / highways
    f_cnt = u_cnt = rd_cnt = 0

    for i in range(n_px):
        o = i * 3
        r, g, b = osm_rgb[o], osm_rgb[o + 1], osm_rgb[o + 2]
        # 1. Major roads: orange motorways & yellow primary/secondary roads
        if (r > 205 and g > 100 and b < 110) or (r > 218 and g > 202 and b < 165):
            b_ch[i] = 255
            rd_cnt += 1
            continue
        # Skip blue water
        if b > 152 and (b - r) >= 14 and (b - g) >= 4:
            continue
        # 2. Forest: EOX OSM sage-green woodland (cross-checked against Sentinel-2 so bright snow/urban stay clear)
        if g > r + 5 and g > b + 4 and g < 235 and r > 145:
            ok_forest = True
            if sat_rgb is not None:
                sr, sg, sb = sat_rgb[o], sat_rgb[o + 1], sat_rgb[o + 2]
                # Exclude bright Alpine snow/ice & bright concrete urban roofs
                if sr > 150 and sg > 150 and sb > 150:
                    ok_forest = False
            if ok_forest:
                r_ch[i] = 255
                f_cnt += 1
                continue
        # 3. Urban / residential built-up: OSM neutral grey built-up + bright neutral Sentinel-2 urban fabric
        if sat_rgb is not None:
            sr, sg, sb = sat_rgb[o], sat_rgb[o + 1], sat_rgb[o + 2]
            if (195 <= r <= 232 and abs(r - g) <= 6 and abs(g - b) <= 6) and (sr > 88 and abs(sr - sg) < 22 and sb < 175):
                g_ch[i] = 255
                u_cnt += 1

    im_r = Image.frombytes("L", (lu_w, lu_h), bytes(r_ch)).filter(ImageFilter.GaussianBlur(radius=0.8))
    im_g = Image.frombytes("L", (lu_w, lu_h), bytes(g_ch)).filter(ImageFilter.GaussianBlur(radius=0.8))
    im_b = Image.frombytes("L", (lu_w, lu_h), bytes(b_ch))
    lu_out = os.path.join(PACKS_DIR, f"{pack_name}_landuse.png")
    Image.merge("RGB", (im_r, im_g, im_b)).save(lu_out, optimize=True)
    print(f"[{pack_name}] Baked landuse mask ({lu_w}x{lu_h}: forest={100*f_cnt/n_px:.1f}%, urban={100*u_cnt/n_px:.1f}%, roads={100*rd_cnt/n_px:.1f}%) -> {lu_out}")


if __name__ == "__main__":
    args = sys.argv[1:]
    target = args[0] if args else "alps"
    water_only = "--water-only" in args
    landuse_only = "--landuse-only" in args
    if target == "europe_albedo":
        bake_europe_albedo()
    elif water_only:
        bake_osm_water_mask(target)
    elif landuse_only:
        bake_osm_landuse_mask(target)
    else:
        bake_pack(target)
        bake_osm_water_mask(target)
        bake_osm_landuse_mask(target)
