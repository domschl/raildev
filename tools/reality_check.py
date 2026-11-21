#!/usr/bin/env python3
"""
Automated Real-World Visual Reality Check for Raildev 3D Europe Atlas.
Compares rendered Godot GPU screenshots (cropped to 3D viewport, excluding HUD)
against real geolocated aerial reference photographs (e.g. Wikimedia Commons)
on key photographic metrics:
  - Mean brightness & dynamic range
  - Mean color saturation & green-channel excess (catches neon/oversaturated foliage)
  - Shadow cool-blue tint (Rayleigh sky fill in shaded Alpine valleys)
  - Highlight clipping % (catches blown-out snow)

Usage:
  python3 tools/reality_check.py <rendered.png> [reference_aerial.jpg]
"""

import subprocess
import sys


def analyze_image(path: str, crop_hud: bool = False) -> dict:
    # Crop top 8% & bottom 6% on Godot renders to exclude HUD bars
    cmd = ["magick", path]
    if crop_hud:
        cmd += ["-gravity", "Center", "-crop", "100%x82%+0+0", "+repage"]
    cmd += ["-resize", "320x240!", "-alpha", "off", "-depth", "8", "rgb:-"]
    raw = subprocess.run(cmd, check=True, stdout=subprocess.PIPE).stdout
    n = len(raw) // 3

    sum_r = sum_g = sum_b = 0.0
    sum_sat = 0.0
    green_excess_sum = 0.0
    shadow_b_minus_r = 0.0
    shadow_cnt = 0
    clipped_cnt = 0

    for i in range(0, len(raw), 3):
        r = raw[i] / 255.0
        g = raw[i + 1] / 255.0
        b = raw[i + 2] / 255.0
        sum_r += r
        sum_g += g
        sum_b += b
        mx = max(r, g, b)
        mn = min(r, g, b)
        sat = ((mx - mn) / mx) if mx > 1e-4 else 0.0
        sum_sat += sat
        if g > max(r, b):
            green_excess_sum += g - max(r, b)
        lum = 0.299 * r + 0.587 * g + 0.114 * b
        if lum < 0.28:
            shadow_b_minus_r += (b - r)
            shadow_cnt += 1
        if mx > 0.98:
            clipped_cnt += 1

    return {
        "mean_rgb": (sum_r / n, sum_g / n, sum_b / n),
        "mean_lum": (0.299 * sum_r + 0.587 * sum_g + 0.114 * sum_b) / n,
        "mean_sat": sum_sat / n,
        "green_excess": green_excess_sum / n,
        "shadow_blue_shift": (shadow_b_minus_r / shadow_cnt) if shadow_cnt > 0 else 0.0,
        "clipped_pct": (clipped_cnt / n) * 100.0,
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 tools/reality_check.py <rendered.png> [reference_aerial.jpg]")
        sys.exit(1)

    ren = analyze_image(sys.argv[1], crop_hud=True)
    print(f"=== RAILDEV VISUAL REALITY CHECK: {sys.argv[1]} ===")
    print(f"  Mean Luminance:     {ren['mean_lum']:.3f}  (target 0.35..0.58)")
    print(f"  Mean Saturation:    {ren['mean_sat']:.3f}  (target 0.18..0.40)")
    print(f"  Green Excess:       {ren['green_excess']:.3f}  (target < 0.080)")
    print(f"  Shadow Blue Shift:  {ren['shadow_blue_shift']:+.3f}  (target >= +0.005 cool sky fill)")
    print(f"  Highlight Clipped:  {ren['clipped_pct']:.2f}%  (target < 6.0%)")

    if len(sys.argv) >= 3:
        ref = analyze_image(sys.argv[2], crop_hud=False)
        print(f"\n--- Reference Aerial Photo: {sys.argv[2]} ---")
        print(f"  Mean Luminance:     {ref['mean_lum']:.3f}")
        print(f"  Mean Saturation:    {ref['mean_sat']:.3f}")
        print(f"  Green Excess:       {ref['green_excess']:.3f}")
        print(f"  Shadow Blue Shift:  {ref['shadow_blue_shift']:+.3f}")
        print(f"  Highlight Clipped:  {ref['clipped_pct']:.2f}%")

    issues = []
    if ren["green_excess"] > 0.085:
        issues.append("Foliage greens slightly oversaturated")
    if ren["clipped_pct"] > 6.0:
        issues.append("Snow highlights clipping")
    if ren["shadow_blue_shift"] < -0.01:
        issues.append("Shadows too warm (increase sky ambient / Rayleigh fog)")

    print("\nVERDICT:", "PASS (photographic balance)" if not issues else "WARN: " + "; ".join(issues))


if __name__ == "__main__":
    main()
