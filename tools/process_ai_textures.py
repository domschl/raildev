#!/usr/bin/env python3
"""
Process high-resolution AI-generated raw textures into game-ready seamless 1024x1024 PBR sets:
  - Albedo PNG (`pbr_*.png`): seamlessly tiled, illumination-flattened, luminance-normalized
    for vertex-color tinting where needed.
  - Normal+Height RGBA PNG (`pbr_*_n.png`): RGB = multi-scale Scharr tangent-space normal map,
    A = 8-bit height/depth map (for Parallax Occlusion Mapping & crevice AO with zero extra binds).
  - Alpha-cutout foliage cards (`pbr_spruce_bough.png` + `pbr_spruce_bough_n.png`):
    chroma/white background removal with crisp anti-aliased alpha + edge color dilation so
    mipmaps never show white fringes!
"""

import argparse
import os
import numpy as np
from PIL import Image, ImageFilter


OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "godot", "textures")
SIZE = 1024


def box_blur_periodic(arr: np.ndarray, radius: int) -> np.ndarray:
    """Fast periodic Gaussian-like blur via repeated box/FFT or PIL on wrapped tile."""
    # FFT Gaussian low-pass is exact, periodic, and O(N log N)
    h, w = arr.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    sigma = max(1.0, float(radius))
    # Frequency-domain Gaussian kernel
    k = np.exp(-2.0 * (np.pi ** 2) * (sigma ** 2) * (fx * fx + fy * fy)).astype(np.float32)
    if arr.ndim == 2:
        return np.fft.ifft2(np.fft.fft2(arr) * k).real.astype(np.float32)
    out = np.empty_like(arr, dtype=np.float32)
    for c in range(arr.shape[2]):
        out[:, :, c] = np.fft.ifft2(np.fft.fft2(arr[:, :, c]) * k).real
    return out


def find_best_periodic_crop(a: np.ndarray, min_frac: float = 0.68, strip: int = 24) -> np.ndarray:
    """
    Find the optimal (h_cut, w_cut) where the right/bottom border best matches the
    left/top border in phase (ideal for structured patterns like roof tiles & cobblestones).
    """
    h, w, _ = a.shape
    gray = a[:, :, 0] * 0.299 + a[:, :, 1] * 0.587 + a[:, :, 2] * 0.114
    # Search best horizontal period
    x_min = int(w * min_frac)
    x_max = w - strip - 1
    left_s = gray[:, :strip]
    best_x, best_ex = w - strip, 1e9
    for x in range(x_min, x_max, 2):
        diff = gray[:, x:x + strip] - left_s
        err = float(np.mean(diff * diff))
        if err < best_ex:
            best_ex = err
            best_x = x
    # Search best vertical period
    y_min = int(h * min_frac)
    y_max = h - strip - 1
    top_s = gray[:strip, :best_x]
    best_y, best_ey = h - strip, 1e9
    for y in range(y_min, y_max, 2):
        diff = gray[y:y + strip, :best_x] - top_s
        err = float(np.mean(diff * diff))
        if err < best_ey:
            best_ey = err
            best_y = y
    return a[:best_y, :best_x]


def make_seamless_crossfade(img_rgb: np.ndarray, blend_frac: float = 0.18, phase_align: bool = False, flatten_spots: bool = False) -> np.ndarray:
    """
    Guarantee 100% periodic wrap-around tiling.
    For structured patterns (phase_align=True), first crops to the best phase-matched
    repeating period so rows/columns wrap cleanly with a narrow seam feather (zero ghosting!).
    """
    h, w, _ = img_rgb.shape
    pad_y, pad_x = int(h * 0.03), int(w * 0.03)
    cropped = img_rgb[pad_y:h - pad_y, pad_x:w - pad_x]
    if phase_align:
        cropped = find_best_periodic_crop(cropped)
        blend_frac = 0.055

    im = Image.fromarray(np.clip(cropped * 255.0, 0, 255).astype(np.uint8)).resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    a = np.asarray(im, dtype=np.float32) / 255.0

    # Flatten low-frequency illumination gradient (and medium-scale repeating soil spots when flatten_spots=True)
    lp_radius = SIZE // 28 if flatten_spots else SIZE // 10
    lp_strength = 0.88 if flatten_spots else 0.65
    low = box_blur_periodic(a, radius=lp_radius)
    mean_rgb = a.mean(axis=(0, 1), keepdims=True)
    a = np.clip(a - (low - mean_rgb) * lp_strength, 0.0, 1.0)

    if phase_align:
        # Phase-aligned wrap: blend opposite borders directly across a tiny feather band
        bw = max(8, int(SIZE * blend_frac))
        t = np.linspace(0.0, 1.0, bw, dtype=np.float32)
        t = t * t * (3.0 - 2.0 * t)
        # Blend horizontal seam (left edge <-> right edge)
        out = a.copy()
        left_orig = a[:, :bw, :].copy()
        right_orig = a[:, -bw:, :].copy()
        # Symmetric smooth blend so col 0 == col -1
        for i in range(bw):
            w_edge = 0.5 * (1.0 - t[i])  # 0.5 at very edge, 0.0 at bw
            out[:, i, :] = left_orig[:, i, :] * (1.0 - w_edge) + right_orig[:, i, :] * w_edge
            out[:, -bw + i, :] = right_orig[:, i, :] * (1.0 - (0.5 * t[i])) + left_orig[:, i, :] * (0.5 * t[i])
        # Blend vertical seam (top edge <-> bottom edge)
        top_orig = out[:bw, :, :].copy()
        bot_orig = out[-bw:, :, :].copy()
        for i in range(bw):
            w_edge = 0.5 * (1.0 - t[i])
            out[i, :, :] = top_orig[i, :, :] * (1.0 - w_edge) + bot_orig[i, :, :] * w_edge
            out[-bw + i, :, :] = bot_orig[i, :, :] * (1.0 - (0.5 * t[i])) + top_orig[i, :, :] * (0.5 * t[i])
        return np.clip(out, 0.0, 1.0)

    # Organic textures: half-shift copy + smooth edge crossfade
    b = np.roll(np.roll(a, SIZE // 2, axis=0), SIZE // 2, axis=1)

    y = np.linspace(-1.0, 1.0, SIZE, endpoint=False, dtype=np.float32)[:, None]
    x = np.linspace(-1.0, 1.0, SIZE, endpoint=False, dtype=np.float32)[None, :]
    ex = 1.0 - np.abs(x)
    ey = 1.0 - np.abs(y)
    wx = np.clip(ex / blend_frac, 0.0, 1.0)
    wy = np.clip(ey / blend_frac, 0.0, 1.0)
    wx = wx * wx * (3.0 - 2.0 * wx)
    wy = wy * wy * (3.0 - 2.0 * wy)
    w_a = (wx * wy)[:, :, None]

    blended = a * w_a + b * (1.0 - w_a)
    return np.clip(blended, 0.0, 1.0)


def derive_height_and_normal(rgb: np.ndarray, strength: float = 5.0, invert_height: bool = False) -> tuple[np.ndarray, np.ndarray]:
    """
    Derive a multi-scale height/depth map in [0, 1] and OpenGL/Godot tangent-space normal+height RGBA.
    Combines fine detail, medium structure, and broad relief so POM & normal lighting look crisp.
    """
    lum = rgb[:, :, 0] * 0.299 + rgb[:, :, 1] * 0.587 + rgb[:, :, 2] * 0.114
    if invert_height:
        lum = 1.0 - lum

    # Multi-scale high-pass + broad luminance so crevices are genuinely deep and peaks are high
    lp_fine = box_blur_periodic(lum, radius=3)
    lp_med = box_blur_periodic(lum, radius=14)
    lp_broad = box_blur_periodic(lum, radius=48)

    detail_fine = lum - lp_fine
    detail_med = lp_fine - lp_med
    detail_broad = lp_med - lp_broad

    h = 0.50 + detail_broad * 1.10 + detail_med * 1.35 + detail_fine * 0.90
    # Stretch robustly (2nd–98th percentile) into [0.02, 0.98]
    p2, p98 = np.percentile(h, [2.0, 98.0])
    h = np.clip((h - p2) / max(p98 - p2, 1e-4), 0.0, 1.0).astype(np.float32)

    # Multi-scale Scharr gradient for crisp, alias-free normal map
    def scharr_grad(field: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        gx = (
            3.0 * np.roll(np.roll(field, -1, 1), -1, 0)
            + 10.0 * np.roll(field, -1, 1)
            + 3.0 * np.roll(np.roll(field, -1, 1), 1, 0)
            - 3.0 * np.roll(np.roll(field, 1, 1), -1, 0)
            - 10.0 * np.roll(field, 1, 1)
            - 3.0 * np.roll(np.roll(field, 1, 1), 1, 0)
        ) / 32.0
        gy = (
            3.0 * np.roll(np.roll(field, -1, 0), -1, 1)
            + 10.0 * np.roll(field, -1, 0)
            + 3.0 * np.roll(np.roll(field, -1, 0), 1, 1)
            - 3.0 * np.roll(np.roll(field, 1, 0), -1, 1)
            - 10.0 * np.roll(field, 1, 0)
            - 3.0 * np.roll(np.roll(field, 1, 0), 1, 1)
        ) / 32.0
        return gx, gy

    gx1, gy1 = scharr_grad(h)
    gx2, gy2 = scharr_grad(box_blur_periodic(h, radius=3))
    gx = (gx1 * 0.65 + gx2 * 0.35) * strength
    gy = (gy1 * 0.65 + gy2 * 0.35) * strength

    nx = -gx
    ny = -gy
    nz = np.ones_like(h, dtype=np.float32)
    inv_len = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)

    rgba = np.stack([
        (nx * inv_len) * 0.5 + 0.5,
        (ny * inv_len) * 0.5 + 0.5,
        (nz * inv_len) * 0.5 + 0.5,
        h,
    ], axis=-1)
    return h, np.clip(rgba * 255.0, 0, 255).astype(np.uint8)


def normalize_for_tinting(rgb: np.ndarray, target_mean: float, sat_scale: float = 1.0) -> np.ndarray:
    """Adjust mean luminance & saturation so shaders that multiply by vertex COLOR stay balanced."""
    lum = rgb[:, :, 0:1] * 0.299 + rgb[:, :, 1:2] * 0.587 + rgb[:, :, 2:3] * 0.114
    out = lum + (rgb - lum) * sat_scale
    cur_mean = float(out.mean())
    if cur_mean > 1e-4:
        out = out * (target_mean / cur_mean)
    return np.clip(out, 0.06, 0.99)


def process_tileable(src_path: str, dst_base: str, target_mean: float | None, sat_scale: float, normal_strength: float, phase_align: bool = False, flatten_spots: bool = False) -> None:
    im = Image.open(src_path).convert("RGB")
    raw = np.asarray(im, dtype=np.float32) / 255.0
    seamless = make_seamless_crossfade(raw, phase_align=phase_align, flatten_spots=flatten_spots)
    if target_mean is not None:
        albedo = normalize_for_tinting(seamless, target_mean=target_mean, sat_scale=sat_scale)
    else:
        albedo = seamless

    _, norm_rgba = derive_height_and_normal(seamless, strength=normal_strength)

    alb_path = os.path.join(OUT_DIR, f"{dst_base}.png")
    nrm_path = os.path.join(OUT_DIR, f"{dst_base}_n.png")
    Image.fromarray(np.clip(albedo * 255.0, 0, 255).astype(np.uint8)).save(alb_path, optimize=True)
    Image.fromarray(norm_rgba, mode="RGBA").save(nrm_path, optimize=True)
    print(f"  [ok] {dst_base}.png + {dst_base}_n.png (1024x1024, RGB normal + A depth)")


def process_alpha_bough(src_path: str, dst_base: str, normal_strength: float = 5.5) -> None:
    """
    Extract crisp RGBA alpha-cutout foliage card from an isolated white-background botanical render,
    and dilate RGB colors into transparent pixels so GPU mipmaps have ZERO white halo fringes!
    """
    im = Image.open(src_path).convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    rgb = np.asarray(im, dtype=np.float32) / 255.0

    # White background has high luminance AND low saturation
    cmax = rgb.max(axis=2)
    cmin = rgb.min(axis=2)
    sat = (cmax - cmin) / np.maximum(cmax, 1e-4)
    lum = rgb[:, :, 0] * 0.299 + rgb[:, :, 1] * 0.587 + rgb[:, :, 2] * 0.114

    # Foreground score: low luminance OR noticeable saturation (green/brown)
    bg_dist = np.maximum(1.0 - lum, sat * 1.45)
    alpha = np.clip((bg_dist - 0.12) / 0.18, 0.0, 1.0)
    alpha = alpha * alpha * (3.0 - 2.0 * alpha)

    # STRICT interior mask (only pure foliage pixels with zero white-background bleed!)
    # Dilate pure interior foliage RGB outward across BOTH semi-transparent edges AND transparent bg
    # so GPU mipmaps and alpha-scissor edges have ZERO white/frosted halo!
    core_mask = (alpha > 0.88) & (lum < 0.78)
    fg_rgb = rgb.copy()
    mask = core_mask.copy()
    for _ in range(20):
        acc = np.zeros_like(fg_rgb)
        cnt = np.zeros((SIZE, SIZE, 1), dtype=np.float32)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
            m_s = np.roll(np.roll(mask, dy, axis=0), dx, axis=1)[:, :, None]
            r_s = np.roll(np.roll(fg_rgb, dy, axis=0), dx, axis=1)
            acc += r_s * m_s
            cnt += m_s
        fill = (~mask)[:, :, None] & (cnt > 0.0)
        fg_rgb = np.where(fill, acc / np.maximum(cnt, 1.0), fg_rgb)
        mask = mask | (cnt[:, :, 0] > 0.0)

    # Any remaining unfilled pixel falls back to mean interior foliage color (never white!)
    if np.any(core_mask):
        mean_col = rgb[core_mask].mean(axis=0)
        fg_rgb = np.where(mask[:, :, None], fg_rgb, mean_col[None, None, :])

    rgba = np.concatenate([fg_rgb, alpha[:, :, None]], axis=-1)
    _, norm_rgba = derive_height_and_normal(fg_rgb, strength=normal_strength)

    alb_path = os.path.join(OUT_DIR, f"{dst_base}.png")
    nrm_path = os.path.join(OUT_DIR, f"{dst_base}_n.png")
    Image.fromarray(np.clip(rgba * 255.0, 0, 255).astype(np.uint8), mode="RGBA").save(alb_path, optimize=True)
    Image.fromarray(norm_rgba, mode="RGBA").save(nrm_path, optimize=True)
    print(f"  [ok] {dst_base}.png (RGBA alpha card) + {dst_base}_n.png (1024x1024)")


def process_facade_atlas(
    plaster_path: str,
    halftimber_path: str,
    sandstone_path: str,
    brick_path: str,
    dst_base: str = "pbr_facade_atlas",
) -> None:
    """
    Build a 2048x2048 2x2 European facade PBR atlas (albedo + RGBA normal/depth):
      Quadrant 0 (top-left):     style 0 = lime plaster / stucco
      Quadrant 1 (top-right):    style 1 = half-timber (Fachwerk)
      Quadrant 2 (bottom-left):  style 2 = dressed ashlar sandstone
      Quadrant 3 (bottom-right): style 3 = aged European brick
    Each 1024x1024 quadrant packs a 960x960 seamless tile with a 32px periodic
    wrap-around gutter on all 4 sides so GPU linear filtering & mipmaps never
    bleed across quadrant boundaries.
    """
    quad_sz = 1024
    gutter = 32
    core_sz = quad_sz - 2 * gutter  # 960

    specs = [
        # (path, row, col, target_mean, sat_scale, normal_strength, mode, invert_height)
        # mode: "phase" = periodic crop + feather, "direct" = full-frame edge feather (already edge-aligned)
        (plaster_path,    0, 0, 0.85, 0.50, 4.2, "phase",  False),
        (halftimber_path, 0, 1, 0.78, 0.85, 6.2, "direct", True),
        (sandstone_path,  1, 0, 0.80, 0.55, 5.8, "direct", False),
        (brick_path,      1, 1, 0.76, 0.90, 6.5, "phase",  True),
    ]

    atlas_alb = np.zeros((quad_sz * 2, quad_sz * 2, 3), dtype=np.uint8)
    atlas_nrm = np.zeros((quad_sz * 2, quad_sz * 2, 4), dtype=np.uint8)

    for src_path, row, col, t_mean, sat_s, n_str, mode, inv_h in specs:
        im = Image.open(src_path).convert("RGB")
        raw = np.asarray(im, dtype=np.float32) / 255.0
        if mode == "direct":
            # Full-frame resize + gentle low-freq flatten + narrow symmetric edge feather
            im_r = im.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
            a = np.asarray(im_r, dtype=np.float32) / 255.0
            low = box_blur_periodic(a, radius=SIZE // 10)
            a = np.clip(a - (low - a.mean(axis=(0, 1), keepdims=True)) * 0.45, 0.0, 1.0)
            bw = 16
            t = np.linspace(0.0, 1.0, bw, dtype=np.float32)
            t = t * t * (3.0 - 2.0 * t)
            out = a.copy()
            left_orig, right_orig = a[:, :bw, :].copy(), a[:, -bw:, :].copy()
            for i in range(bw):
                w_edge = 0.5 * (1.0 - t[i])
                out[:, i, :] = left_orig[:, i, :] * (1.0 - w_edge) + right_orig[:, i, :] * w_edge
                out[:, -bw + i, :] = right_orig[:, i, :] * (1.0 - (0.5 * t[i])) + left_orig[:, i, :] * (0.5 * t[i])
            top_orig, bot_orig = out[:bw, :, :].copy(), out[-bw:, :, :].copy()
            for i in range(bw):
                w_edge = 0.5 * (1.0 - t[i])
                out[i, :, :] = top_orig[i, :, :] * (1.0 - w_edge) + bot_orig[i, :, :] * w_edge
                out[-bw + i, :, :] = bot_orig[i, :, :] * (1.0 - (0.5 * t[i])) + top_orig[i, :, :] * (0.5 * t[i])
            seamless = np.clip(out, 0.0, 1.0)
        else:
            seamless = make_seamless_crossfade(raw, phase_align=(mode == "phase"))
        albedo = normalize_for_tinting(seamless, target_mean=t_mean, sat_scale=sat_s)
        _, norm_rgba = derive_height_and_normal(seamless, strength=n_str, invert_height=inv_h)

        # Resize seamless tile + normal map to core_sz (960x960) and wrap-pad by 32px -> 1024x1024
        alb_u8 = np.asarray(
            Image.fromarray(np.clip(albedo * 255.0, 0, 255).astype(np.uint8)).resize(
                (core_sz, core_sz), Image.Resampling.LANCZOS
            ),
            dtype=np.uint8,
        )
        nrm_u8 = np.asarray(
            Image.fromarray(norm_rgba, mode="RGBA").resize(
                (core_sz, core_sz), Image.Resampling.LANCZOS
            ),
            dtype=np.uint8,
        )
        alb_quad = np.pad(alb_u8, ((gutter, gutter), (gutter, gutter), (0, 0)), mode="wrap")
        nrm_quad = np.pad(nrm_u8, ((gutter, gutter), (gutter, gutter), (0, 0)), mode="wrap")

        y0, y1 = row * quad_sz, (row + 1) * quad_sz
        x0, x1 = col * quad_sz, (col + 1) * quad_sz
        atlas_alb[y0:y1, x0:x1, :] = alb_quad
        atlas_nrm[y0:y1, x0:x1, :] = nrm_quad

    alb_path = os.path.join(OUT_DIR, f"{dst_base}.png")
    nrm_path = os.path.join(OUT_DIR, f"{dst_base}_n.png")
    Image.fromarray(atlas_alb, mode="RGB").save(alb_path, optimize=True)
    Image.fromarray(atlas_nrm, mode="RGBA").save(nrm_path, optimize=True)
    print(f"  [ok] {dst_base}.png + {dst_base}_n.png (2048x2048 2x2 atlas with 32px periodic gutters)")


def main():
    parser = argparse.ArgumentParser(description="Process AI raw textures into seamless 1024x1024 PBR sets.")
    parser.add_argument("--foliage", type=str)
    parser.add_argument("--bark", type=str)
    parser.add_argument("--roof", type=str)
    parser.add_argument("--wall", type=str)
    parser.add_argument("--cobble", type=str)
    parser.add_argument("--ballast", type=str)
    parser.add_argument("--wood-ties", type=str)
    parser.add_argument("--spruce-bough", type=str)
    parser.add_argument("--oak-bough", type=str)
    parser.add_argument("--terrain-forest", type=str)
    parser.add_argument("--terrain-grass", type=str)
    parser.add_argument("--terrain-grass-med", type=str)
    parser.add_argument("--terrain-rock", type=str)
    parser.add_argument(
        "--facade-atlas",
        nargs=4,
        metavar=("PLASTER", "HALFTIMBER", "SANDSTONE", "BRICK"),
        help="Pack 4 AI facade textures into 2048x2048 2x2 pbr_facade_atlas.png + _n.png",
    )
    parser.add_argument("--rebake-terrain-normals", action="store_true")
    args = parser.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    if args.foliage:
        process_tileable(args.foliage, "pbr_foliage", target_mean=0.72, sat_scale=0.35, normal_strength=6.5)
    if args.bark:
        process_tileable(args.bark, "pbr_bark", target_mean=0.72, sat_scale=0.55, normal_strength=6.5)
    if args.roof:
        process_tileable(args.roof, "pbr_roof_tiles", target_mean=0.80, sat_scale=0.18, normal_strength=6.0, phase_align=True)
    if args.wall:
        process_tileable(args.wall, "pbr_wall_plaster", target_mean=0.82, sat_scale=0.22, normal_strength=3.8)
    if args.cobble:
        process_tileable(args.cobble, "pbr_cobble", target_mean=0.60, sat_scale=0.85, normal_strength=6.5, phase_align=True)
    if args.ballast:
        process_tileable(args.ballast, "pbr_ballast", target_mean=0.58, sat_scale=0.85, normal_strength=7.0)
    if args.wood_ties:
        im = Image.open(args.wood_ties).convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
        a = np.asarray(im, dtype=np.float32) / 255.0
        low = box_blur_periodic(a, radius=SIZE // 10)
        a = np.clip(a - (low - a.mean(axis=(0, 1), keepdims=True)) * 0.45, 0.0, 1.0)
        albedo = normalize_for_tinting(a, target_mean=0.46, sat_scale=0.95)
        _, norm_rgba = derive_height_and_normal(a, strength=6.8)
        Image.fromarray(np.clip(albedo * 255.0, 0, 255).astype(np.uint8)).save(os.path.join(OUT_DIR, "pbr_wood_ties.png"), optimize=True)
        Image.fromarray(norm_rgba, mode="RGBA").save(os.path.join(OUT_DIR, "pbr_wood_ties_n.png"), optimize=True)
        print("  [ok] pbr_wood_ties.png + pbr_wood_ties_n.png (1024x1024, RGB normal + A depth)")
    if args.spruce_bough:
        process_alpha_bough(args.spruce_bough, "pbr_spruce_bough", normal_strength=5.5)
    if args.oak_bough:
        process_alpha_bough(args.oak_bough, "pbr_oak_bough", normal_strength=5.0)
    if args.terrain_forest:
        process_tileable(args.terrain_forest, "terrain_forest", target_mean=None, sat_scale=1.0, normal_strength=6.0)
    if args.terrain_grass:
        process_tileable(args.terrain_grass, "terrain_grass", target_mean=None, sat_scale=1.0, normal_strength=4.8, flatten_spots=True)
    if args.terrain_grass_med:
        process_tileable(args.terrain_grass_med, "terrain_grass_mediterranean", target_mean=None, sat_scale=1.0, normal_strength=4.8, flatten_spots=True)
    if args.terrain_rock:
        process_tileable(args.terrain_rock, "terrain_rock", target_mean=None, sat_scale=1.0, normal_strength=7.2)
    if args.facade_atlas:
        process_facade_atlas(*args.facade_atlas)
    if args.rebake_terrain_normals:
        for base, strength in [("terrain_grass", 4.8), ("terrain_forest", 6.0), ("terrain_rock", 7.2)]:
            src = os.path.join(OUT_DIR, f"{base}.png")
            if os.path.exists(src):
                im = Image.open(src).convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
                rgb = np.asarray(im, dtype=np.float32) / 255.0
                _, norm_rgba = derive_height_and_normal(rgb, strength=strength)
                Image.fromarray(norm_rgba, mode="RGBA").save(os.path.join(OUT_DIR, f"{base}_n.png"), optimize=True)
                print(f"  [ok] rebaked {base}_n.png (1024x1024 RGBA normal + depth)")


if __name__ == "__main__":
    main()
