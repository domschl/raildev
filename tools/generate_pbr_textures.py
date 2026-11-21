#!/usr/bin/env python3
"""
Generate seamless 512x512 tileable PBR albedo + normal textures for Raildev 3D:
  - Architectural: roof tiles, aged European wall plaster/masonry, granite cobblestones
  - Vegetation:    leaf/needle foliage clusters, vertical furrowed tree bark
  - Terrain:       normal maps baked directly from existing terrain_grass/forest/rock PNGs

All generated textures are tileable (periodic wrap) and MIT-licensed.
"""

import os
import numpy as np
from PIL import Image

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "godot", "textures")
SIZE = 512


def tileable_noise(size: int, freq: int, seed: int) -> np.ndarray:
    """Periodic smooth value noise in [0, 1] with exact wrap-around tiling."""
    rng = np.random.default_rng(seed)
    grid = rng.random((freq, freq), dtype=np.float32)
    y = np.linspace(0, freq, size, endpoint=False, dtype=np.float32)
    x = np.linspace(0, freq, size, endpoint=False, dtype=np.float32)
    yi = np.floor(y).astype(np.int32)
    xi = np.floor(x).astype(np.int32)
    yf = y - yi
    xf = x - xi
    # Smoothstep
    u = xf * xf * (3.0 - 2.0 * xf)
    v = yf * yf * (3.0 - 2.0 * yf)
    yi0 = yi % freq
    yi1 = (yi + 1) % freq
    xi0 = xi % freq
    xi1 = (xi + 1) % freq

    v00 = grid[np.ix_(yi0, xi0)]
    v10 = grid[np.ix_(yi0, xi1)]
    v01 = grid[np.ix_(yi1, xi0)]
    v11 = grid[np.ix_(yi1, xi1)]

    top = v00 * (1.0 - u[None, :]) + v10 * u[None, :]
    bot = v01 * (1.0 - u[None, :]) + v11 * u[None, :]
    return top * (1.0 - v[:, None]) + bot * v[:, None]


def fbm_tileable(size: int, base_freq: int, octaves: int, seed: int) -> np.ndarray:
    acc = np.zeros((size, size), dtype=np.float32)
    amp = 0.5
    norm = 0.0
    for o in range(octaves):
        f = min(size // 2, base_freq * (2 ** o))
        acc += tileable_noise(size, f, seed + o * 37) * amp
        norm += amp
        amp *= 0.5
    return acc / max(norm, 1e-6)


def height_to_normal(h: np.ndarray, strength: float = 3.5) -> np.ndarray:
    """Convert periodic heightmap in [0, 1] to OpenGL/Godot tangent-space RGB normal map."""
    gx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5 * strength
    gy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5 * strength
    nx = -gx
    ny = -gy
    nz = np.ones_like(h, dtype=np.float32)
    inv_len = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    rgb = np.stack([
        (nx * inv_len) * 0.5 + 0.5,
        (ny * inv_len) * 0.5 + 0.5,
        (nz * inv_len) * 0.5 + 0.5,
    ], axis=-1)
    return np.clip(rgb * 255.0, 0, 255).astype(np.uint8)


def save_png(arr: np.ndarray, name: str) -> None:
    path = os.path.join(OUT_DIR, name)
    Image.fromarray(arr).save(path, optimize=True)
    print(f"  wrote {name} ({arr.shape[1]}x{arr.shape[0]})")


def gen_roof_tiles():
    """Seamless overlapping European clay/slate roof shingles (neutral luminance so vertex color tints it)."""
    rows = 16
    cols = 14
    y = np.linspace(0.0, rows, SIZE, endpoint=False, dtype=np.float32)[:, None]
    x = np.linspace(0.0, cols, SIZE, endpoint=False, dtype=np.float32)[None, :]

    row_i = np.floor(y).astype(np.int32)
    # Stagger alternating courses by half a tile
    x_stagger = x + (row_i % 2) * 0.5
    col_i = np.floor(x_stagger).astype(np.int32) % cols
    ty = y - row_i
    tx = x_stagger - np.floor(x_stagger)

    # Curved barrel/shingle profile + horizontal course overlap shadow
    arch = np.sin(tx * np.pi) ** 0.7
    slope = 0.25 + 0.75 * ty
    seam_x = np.clip(np.minimum(tx, 1.0 - tx) * 14.0, 0.0, 1.0)
    seam_y = np.clip(ty * 9.0, 0.0, 1.0)

    # Subtle per-tile weathering variation
    rng = np.random.default_rng(101)
    tile_var = rng.uniform(0.86, 1.10, size=(rows, cols)).astype(np.float32)
    t_mul = tile_var[row_i % rows, col_i]

    grain = fbm_tileable(SIZE, 16, 4, 102)
    h = np.clip((0.35 * arch + 0.45 * slope) * seam_x * seam_y + (grain - 0.5) * 0.14, 0.0, 1.0)

    # Neutral bright-gray albedo (centered ~0.82 so multiplying vertex roof color preserves exact terracotta/slate hue!)
    alb = np.clip((0.68 + 0.28 * h) * t_mul * (0.92 + 0.16 * grain), 0.30, 1.0)
    rgb = np.stack([alb, alb * 0.99, alb * 0.98], axis=-1)
    save_png((rgb * 255.0).astype(np.uint8), "pbr_roof_tiles.png")
    save_png(height_to_normal(h, strength=5.0), "pbr_roof_tiles_n.png")


def gen_wall_plaster():
    """Seamless aged European lime plaster with faint stone/brick coursework underneath."""
    grain_coarse = fbm_tileable(SIZE, 8, 4, 201)
    grain_fine = fbm_tileable(SIZE, 32, 3, 202)
    # Subtle masonry courses
    rows = 24
    cols = 10
    y = np.linspace(0.0, rows, SIZE, endpoint=False, dtype=np.float32)[:, None]
    x = np.linspace(0.0, cols, SIZE, endpoint=False, dtype=np.float32)[None, :]
    row_i = np.floor(y).astype(np.int32)
    tx = (x + (row_i % 2) * 0.5) % 1.0
    ty = y - row_i
    mortar = np.minimum(np.clip(np.minimum(tx, 1.0 - tx) * 22.0, 0.0, 1.0),
                        np.clip(np.minimum(ty, 1.0 - ty) * 16.0, 0.0, 1.0))

    h = np.clip(0.55 * grain_coarse + 0.30 * grain_fine + 0.15 * mortar, 0.0, 1.0)
    alb = np.clip(0.76 + 0.18 * (grain_coarse - 0.5) + 0.12 * (grain_fine - 0.5) - 0.06 * (1.0 - mortar), 0.45, 1.0)
    rgb = np.stack([alb, alb * 0.995, alb * 0.985], axis=-1)
    save_png((rgb * 255.0).astype(np.uint8), "pbr_wall_plaster.png")
    save_png(height_to_normal(h, strength=3.0), "pbr_wall_plaster_n.png")


def gen_cobble():
    """Seamless European granite cobblestone paving (for station forecourts & urban streets)."""
    rows = 18
    cols = 14
    y = np.linspace(0.0, rows, SIZE, endpoint=False, dtype=np.float32)[:, None]
    x = np.linspace(0.0, cols, SIZE, endpoint=False, dtype=np.float32)[None, :]
    # Subtle organic warp so rows feel hand-laid
    warp = (fbm_tileable(SIZE, 6, 3, 301) - 0.5) * 0.22
    y_w = y + warp
    row_i = np.floor(y_w).astype(np.int32) % rows
    x_w = x + (row_i % 2) * 0.5 + warp * 0.6
    col_i = np.floor(x_w).astype(np.int32) % cols
    ty = y_w - np.floor(y_w)
    tx = x_w - np.floor(x_w)

    # Rounded granite sett pillow profile
    dx = np.abs(tx - 0.5) * 2.0
    dy = np.abs(ty - 0.5) * 2.0
    edge = np.maximum(dx, dy)
    sett = np.clip((1.0 - edge) * 4.5, 0.0, 1.0) ** 0.55

    rng = np.random.default_rng(302)
    stone_var = rng.uniform(0.80, 1.12, size=(rows, cols)).astype(np.float32)
    stone_warm = rng.uniform(-0.04, 0.04, size=(rows, cols)).astype(np.float32)
    s_mul = stone_var[row_i, col_i]
    s_wrm = stone_warm[row_i, col_i]

    grit = fbm_tileable(SIZE, 24, 3, 303)
    h = np.clip(sett * (0.82 + 0.18 * grit), 0.0, 1.0)

    # Dark mortar joints + warm/cool European porphyry & granite cobbles
    base = np.where(sett > 0.12, (0.50 + 0.24 * sett) * s_mul * (0.90 + 0.20 * grit), 0.28 + 0.08 * grit)
    r = np.clip(base + s_wrm, 0.15, 0.95)
    g = np.clip(base + s_wrm * 0.4, 0.15, 0.95)
    b = np.clip(base - s_wrm * 0.6, 0.15, 0.95)
    rgb = np.stack([r, g, b], axis=-1)
    save_png((rgb * 255.0).astype(np.uint8), "pbr_cobble.png")
    save_png(height_to_normal(h, strength=5.5), "pbr_cobble_n.png")


def gen_foliage():
    """Seamless organic leaf/needle canopy cluster texture + crisp micro-bump normal map."""
    n1 = fbm_tileable(SIZE, 12, 4, 401)
    n2 = fbm_tileable(SIZE, 36, 3, 402)
    # Stamp periodic circular leaf/needle clusters onto heightmap
    h = np.zeros((SIZE, SIZE), dtype=np.float32)
    rng = np.random.default_rng(403)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    for _ in range(260):
        cx = rng.uniform(0, SIZE)
        cy = rng.uniform(0, SIZE)
        rad = rng.uniform(10.0, 26.0)
        # Periodic wrapped distance
        dx = np.abs(xx - cx)
        dx = np.minimum(dx, SIZE - dx)
        dy = np.abs(yy - cy)
        dy = np.minimum(dy, SIZE - dy)
        d2 = (dx * dx + dy * dy) / (rad * rad)
        blob = np.clip(1.0 - d2, 0.0, 1.0) ** 0.7 * rng.uniform(0.55, 1.0)
        h = np.maximum(h, blob)

    h = np.clip(h * 0.65 + n1 * 0.20 + n2 * 0.15, 0.0, 1.0)
    # Neutral luminance centered around 0.85 so vertex/Sentinel-2 forest color stays faithful!
    alb = np.clip(0.58 + 0.42 * h, 0.35, 1.0)
    rgb = np.stack([alb * 0.97, alb * 1.02, alb * 0.95], axis=-1)
    save_png((rgb * 255.0).astype(np.uint8), "pbr_foliage.png")
    save_png(height_to_normal(h, strength=6.0), "pbr_foliage_n.png")


def gen_bark():
    """Seamless vertical furrowed tree bark texture + normal map."""
    # Anisotropic vertical stretch (high freq in X, low freq in Y)
    y = np.linspace(0.0, 6.0, SIZE, endpoint=False, dtype=np.float32)[:, None]
    x = np.linspace(0.0, 26.0, SIZE, endpoint=False, dtype=np.float32)[None, :]
    warp = fbm_tileable(SIZE, 8, 3, 501) * 2.2
    ridge = 0.5 + 0.5 * np.sin((x + warp) * np.pi * 2.0)
    fine = fbm_tileable(SIZE, 32, 3, 502)
    h = np.clip(ridge * 0.62 + fine * 0.38, 0.0, 1.0)
    alb = np.clip(0.52 + 0.42 * h, 0.25, 0.95)
    rgb = np.stack([alb * 1.04, alb * 0.96, alb * 0.88], axis=-1)
    save_png((rgb * 255.0).astype(np.uint8), "pbr_bark.png")
    save_png(height_to_normal(h, strength=5.5), "pbr_bark_n.png")


def bake_terrain_normals():
    """Bake 512x512 seamless Sobel normal maps directly from existing terrain_grass/forest/rock PNGs."""
    specs = [
        ("terrain_grass.png",  "terrain_grass_n.png",  4.2),
        ("terrain_forest.png", "terrain_forest_n.png", 5.2),
        ("terrain_rock.png",   "terrain_rock_n.png",   6.5),
    ]
    for src_name, dst_name, strength in specs:
        src_path = os.path.join(OUT_DIR, src_name)
        if not os.path.exists(src_path):
            print(f"  [skip] missing {src_name}")
            continue
        im = Image.open(src_path).convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
        arr = np.asarray(im, dtype=np.float32) / 255.0
        lum = arr[:, :, 0] * 0.299 + arr[:, :, 1] * 0.587 + arr[:, :, 2] * 0.114
        save_png(height_to_normal(lum, strength=strength), dst_name)


def gen_ballast():
    """Seamless crushed granite railway ballast gravel + crisp normal map."""
    h = np.zeros((SIZE, SIZE), dtype=np.float32)
    alb = np.full((SIZE, SIZE), 0.50, dtype=np.float32)
    rng = np.random.default_rng(601)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    # Scatter hundreds of sharp angular crushed-stone pebbles (periodic wrap)
    for _ in range(900):
        cx = rng.uniform(0, SIZE)
        cy = rng.uniform(0, SIZE)
        rx = rng.uniform(4.5, 13.0)
        ry = rng.uniform(4.5, 13.0)
        dx = np.abs(xx - cx)
        dx = np.minimum(dx, SIZE - dx) / rx
        dy = np.abs(yy - cy)
        dy = np.minimum(dy, SIZE - dy) / ry
        d = np.maximum(dx, dy) * 0.65 + np.sqrt(dx * dx + dy * dy) * 0.35
        stone_h = np.clip(1.0 - d, 0.0, 1.0) ** 0.65 * rng.uniform(0.55, 1.0)
        mask = stone_h > h
        h = np.where(mask, stone_h, h)
        alb = np.where(mask, rng.uniform(0.42, 0.88), alb)

    grit = fbm_tileable(SIZE, 32, 3, 602)
    h = np.clip(h * 0.80 + grit * 0.20, 0.0, 1.0)
    col = np.clip(alb * (0.72 + 0.36 * h), 0.22, 0.96)
    rgb = np.stack([col * 1.02, col * 0.99, col * 0.95], axis=-1)
    save_png((rgb * 255.0).astype(np.uint8), "pbr_ballast.png")
    save_png(height_to_normal(h, strength=6.5), "pbr_ballast_n.png")


def gen_wood_ties():
    """Seamless curve-following wooden railway sleepers/ties (V = along track, U = across track)."""
    ties = 12
    y = np.linspace(0.0, ties, SIZE, endpoint=False, dtype=np.float32)[:, None]
    x = np.linspace(0.0, 1.0, SIZE, endpoint=False, dtype=np.float32)[None, :]
    ty = y - np.floor(y)
    # Each tie occupies 56% of pitch along V; 44% is dark recessed gravel gap between ties
    tie_mask = np.clip((0.56 - np.abs(ty - 0.5) * 1.8) * 14.0, 0.0, 1.0)
    # Wood grain running horizontally across the sleeper (along X)
    grain = fbm_tileable(SIZE, 16, 4, 701)
    fibers = 0.5 + 0.5 * np.sin((y * 18.0 + grain * 3.2) * np.pi * 2.0)
    gravel = fbm_tileable(SIZE, 36, 3, 702)

    h = np.clip(tie_mask * (0.74 + 0.18 * fibers + 0.08 * grain) + (1.0 - tie_mask) * (0.18 + 0.20 * gravel), 0.0, 1.0)
    wood_col = 0.62 + 0.26 * fibers + 0.14 * grain
    gap_col = 0.34 + 0.22 * gravel
    c = tie_mask * wood_col + (1.0 - tie_mask) * gap_col
    rgb = np.stack([c * 1.08, c * 0.96, c * 0.84], axis=-1)
    save_png((np.clip(rgb, 0.12, 0.95) * 255.0).astype(np.uint8), "pbr_wood_ties.png")
    save_png(height_to_normal(h, strength=6.0), "pbr_wood_ties_n.png")


def gen_metal():
    """Seamless brushed/riveted painted steel & cast iron for locomotives, coaches & station ironwork."""
    brushed = fbm_tileable(SIZE, 24, 3, 801)
    soot = fbm_tileable(SIZE, 8, 4, 802)
    # Panel seams + subtle rivet rows
    panels = 6
    y = np.linspace(0.0, panels, SIZE, endpoint=False, dtype=np.float32)[:, None]
    x = np.linspace(0.0, panels, SIZE, endpoint=False, dtype=np.float32)[None, :]
    fx = x - np.floor(x)
    fy = y - np.floor(y)
    seam = np.minimum(np.clip(np.minimum(fx, 1.0 - fx) * 32.0, 0.0, 1.0),
                      np.clip(np.minimum(fy, 1.0 - fy) * 32.0, 0.0, 1.0))

    h = np.clip(0.55 + 0.22 * (brushed - 0.5) + 0.18 * (soot - 0.5) - 0.25 * (1.0 - seam), 0.0, 1.0)
    alb = np.clip(0.84 + 0.14 * (brushed - 0.5) + 0.14 * (soot - 0.5) - 0.16 * (1.0 - seam), 0.40, 1.0)
    rgb = np.stack([alb, alb, alb], axis=-1)
    save_png((rgb * 255.0).astype(np.uint8), "pbr_metal.png")
    save_png(height_to_normal(h, strength=3.2), "pbr_metal_n.png")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("Generating seamless PBR albedo + normal textures in", OUT_DIR)
    gen_roof_tiles()
    gen_wall_plaster()
    gen_cobble()
    gen_foliage()
    gen_bark()
    gen_ballast()
    gen_wood_ties()
    gen_metal()
    bake_terrain_normals()
    print("Done!")


if __name__ == "__main__":
    main()
