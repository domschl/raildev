#!/usr/bin/env python3
"""
Procedural glTF 2.0 (.glb) 3D Asset Pipeline for Raildev 3D.

Generates cohesive, stylized 19th-century European miniature diorama assets
(trees, vegetation, regional buildings, cathedrals, basilicas, harbor piers)
with baked vertex colors and crisp low-poly normals.

Zero external dependencies — runs natively on aarch64 and x86_64.
All generated .glb files are standard glTF 2.0 binaries compatible with
Godot 4 and Blender.
"""

import json
import math
import os
import struct


class MeshBuilder:
    """Accumulates flat-shaded triangles with positions, normals, and RGBA vertex colors."""

    def __init__(self):
        self.positions = []
        self.normals = []
        self.colors = []

    def add_tri(self, p0, p1, p2, col):
        ux, uy, uz = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
        vx, vy, vz = p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]
        nx = uy * vz - uz * vy
        ny = uz * vx - ux * vz
        nz = ux * vy - uy * vx
        length = math.sqrt(nx * nx + ny * ny + nz * nz)
        if length < 1e-8:
            return
        n = (nx / length, ny / length, nz / length)
        # Subtle baked vertical ambient occlusion / top-light lift
        shade = 0.88 + 0.14 * max(0.0, n[1])
        c = (
            min(1.0, col[0] * shade),
            min(1.0, col[1] * shade),
            min(1.0, col[2] * shade),
            1.0,
        )
        for p in (p0, p1, p2):
            self.positions.append(p)
            self.normals.append(n)
            self.colors.append(c)

    def add_quad(self, p0, p1, p2, p3, col):
        self.add_tri(p0, p1, p2, col)
        self.add_tri(p0, p2, p3, col)

    def add_box(self, cx, cy, cz, sx, sy, sz, col, top_col=None):
        hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
        x0, x1 = cx - hx, cx + hx
        y0, y1 = cy - hy, cy + hy
        z0, z1 = cz - hz, cz + hz
        tc = top_col if top_col else col
        # +Z front
        self.add_quad((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1), col)
        # -Z back
        self.add_quad((x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0), col)
        # +X right
        self.add_quad((x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1), col)
        # -X left
        self.add_quad((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0), col)
        # +Y top
        self.add_quad((x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0), tc)

    def add_gable_roof(self, cx, base_y, cz, sx, sy, sz, col, overhang=0.06):
        hx = sx * 0.5 + overhang
        hz = sz * 0.5 + overhang
        top_y = base_y + sy
        # Ridge runs along X axis
        fl = (cx - hx, base_y, cz + hz)
        fr = (cx + hx, base_y, cz + hz)
        bl = (cx - hx, base_y, cz - hz)
        br = (cx + hx, base_y, cz - hz)
        rl = (cx - hx, top_y, cz)
        rr = (cx + hx, top_y, cz)
        # Front & back roof slopes
        self.add_quad(fl, fr, rr, rl, col)
        self.add_quad(br, bl, rl, rr, col)
        # Left & right gable triangles (slightly darker)
        gcol = (col[0] * 0.85, col[1] * 0.85, col[2] * 0.85)
        self.add_tri(bl, fl, rl, gcol)
        self.add_tri(fr, br, rr, gcol)

    def add_cylinder_z(self, cx, cy, z0, z1, r0, r1, segs, col):
        """Horizontal cylinder / frustum aligned along Z axis (ideal for steam boilers)."""
        pts0, pts1 = [], []
        for i in range(segs):
            a = 2.0 * math.pi * i / segs
            ca, sa = math.cos(a), math.sin(a)
            pts0.append((cx + ca * r0, cy + sa * r0, z0))
            pts1.append((cx + ca * r1, cy + sa * r1, z1))
        for i in range(segs):
            j = (i + 1) % segs
            self.add_quad(pts0[i], pts0[j], pts1[j], pts1[i], col)
        # End caps
        c0, c1 = (cx, cy, z0), (cx, cy, z1)
        cap_col = (col[0] * 0.88, col[1] * 0.88, col[2] * 0.88)
        for i in range(segs):
            j = (i + 1) % segs
            if r0 > 1e-4:
                self.add_tri(c0, pts0[j], pts0[i], cap_col)
            if r1 > 1e-4:
                self.add_tri(c1, pts1[i], pts1[j], cap_col)

    def add_cylinder_x(self, x0, x1, cy, cz, r, segs, col):
        """Horizontal cylinder / wheel aligned along X axis (ideal for locomotive/coach wheels)."""
        pts0, pts1 = [], []
        for i in range(segs):
            a = 2.0 * math.pi * i / segs
            ca, sa = math.cos(a), math.sin(a)
            pts0.append((x0, cy + sa * r, cz + ca * r))
            pts1.append((x1, cy + sa * r, cz + ca * r))
        for i in range(segs):
            j = (i + 1) % segs
            self.add_quad(pts0[i], pts1[i], pts1[j], pts0[j], col)
        c0, c1 = (x0, cy, cz), (x1, cy, cz)
        cap_col = (col[0] * 0.90, col[1] * 0.90, col[2] * 0.90)
        for i in range(segs):
            j = (i + 1) % segs
            self.add_tri(c0, pts0[i], pts0[j], cap_col)
            self.add_tri(c1, pts1[j], pts1[i], cap_col)

    def add_hip_roof(self, cx, base_y, cz, sx, sy, sz, col, ridge_frac=0.5, overhang=0.05):
        hx = sx * 0.5 + overhang
        hz = sz * 0.5 + overhang
        rx = hx * ridge_frac
        rz = hz * 0.08
        top_y = base_y + sy
        fl = (cx - hx, base_y, cz + hz)
        fr = (cx + hx, base_y, cz + hz)
        bl = (cx - hx, base_y, cz - hz)
        br = (cx + hx, base_y, cz - hz)
        tfl = (cx - rx, top_y, cz + rz)
        tfr = (cx + rx, top_y, cz + rz)
        tbl = (cx - rx, top_y, cz - rz)
        tbr = (cx + rx, top_y, cz - rz)
        self.add_quad(fl, fr, tfr, tfl, col)
        self.add_quad(br, bl, tbl, tbr, col)
        self.add_quad(bl, fl, tfl, tbl, col)
        self.add_quad(fr, br, tbr, tfr, col)
        self.add_quad(tfl, tfr, tbr, tbl, col)

    def add_cylinder(self, cx, y0, y1, cz, r0, r1, segs, col, rot_offset=0.0, star_amp=0.0):
        ring0 = []
        ring1 = []
        for i in range(segs):
            a = rot_offset + (2.0 * math.pi * i) / segs
            mod = 1.0 + (star_amp if (i % 2 == 0) else -star_amp)
            ca, sa = math.cos(a), math.sin(a)
            ring0.append((cx + ca * r0 * mod, y0, cz + sa * r0 * mod))
            ring1.append((cx + ca * r1 * mod, y1, cz + sa * r1 * mod))
        for i in range(segs):
            j = (i + 1) % segs
            if r1 > 1e-5:
                self.add_quad(ring0[i], ring0[j], ring1[j], ring1[i], col)
            else:
                self.add_tri(ring0[i], ring0[j], (cx, y1, cz), col)
        if r1 > 1e-5:
            top_c = (cx, y1, cz)
            for i in range(segs):
                j = (i + 1) % segs
                self.add_tri(ring1[i], ring1[j], top_c, col)

    def add_faceted_blob(self, cx, cy, cz, rx, ry, rz, col, lat_segs=4, lon_segs=7, seed=0.0):
        """Organic low-poly foliage puff or dome."""
        rings = []
        for la in range(1, lat_segs):
            phi = math.pi * la / lat_segs
            sp, cp = math.sin(phi), math.cos(phi)
            ring = []
            for lo in range(lon_segs):
                th = 2.0 * math.pi * lo / lon_segs + la * 0.35
                wobble = 1.0 + 0.14 * math.sin(th * 3.0 + seed + la * 1.7)
                ring.append((
                    cx + math.cos(th) * sp * rx * wobble,
                    cy + cp * ry * wobble,
                    cz + math.sin(th) * sp * rz * wobble,
                ))
            rings.append(ring)

        top = (cx, cy + ry, cz)
        bot = (cx, cy - ry, cz)
        # Top cap
        for lo in range(lon_segs):
            lo2 = (lo + 1) % lon_segs
            self.add_tri(rings[0][lo2], rings[0][lo], top, col)
        # Middle bands
        for r in range(len(rings) - 1):
            for lo in range(lon_segs):
                lo2 = (lo + 1) % lon_segs
                self.add_quad(rings[r + 1][lo], rings[r + 1][lo2], rings[r][lo2], rings[r][lo], col)
        # Bottom cap
        bot_col = (col[0] * 0.72, col[1] * 0.72, col[2] * 0.72)
        for lo in range(lon_segs):
            lo2 = (lo + 1) % lon_segs
            self.add_tri(rings[-1][lo], rings[-1][lo2], bot, bot_col)

    def export_glb(self, out_path):
        n = len(self.positions)
        if n == 0:
            raise ValueError("Empty mesh")

        pos_bytes = b"".join(struct.pack("<fff", *p) for p in self.positions)
        nrm_bytes = b"".join(struct.pack("<fff", *v) for v in self.normals)
        col_bytes = b"".join(struct.pack("<ffff", *c) for c in self.colors)

        min_p = [min(p[i] for p in self.positions) for i in range(3)]
        max_p = [max(p[i] for p in self.positions) for i in range(3)]

        bin_blob = pos_bytes + nrm_bytes + col_bytes
        # Pad binary chunk to 4-byte boundary
        while len(bin_blob) % 4 != 0:
            bin_blob += b"\x00"

        gltf = {
            "asset": {"version": "2.0", "generator": "raildev-asset-pipeline"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "materials": [{
                "name": "VertexColorMat",
                "pbrMetallicRoughness": {
                    "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.86,
                },
            }],
            "meshes": [{
                "primitives": [{
                    "attributes": {
                        "POSITION": 0,
                        "NORMAL": 1,
                        "COLOR_0": 2,
                    },
                    "material": 0,
                }]
            }],
            "buffers": [{"byteLength": len(bin_blob)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": len(pos_bytes), "target": 34962},
                {"buffer": 0, "byteOffset": len(pos_bytes), "byteLength": len(nrm_bytes), "target": 34962},
                {"buffer": 0, "byteOffset": len(pos_bytes) + len(nrm_bytes), "byteLength": len(col_bytes), "target": 34962},
            ],
            "accessors": [
                {
                    "bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3",
                    "min": min_p, "max": max_p,
                },
                {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
                {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC4"},
            ],
        }

        json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
        while len(json_bytes) % 4 != 0:
            json_bytes += b" "

        total_len = 12 + 8 + len(json_bytes) + 8 + len(bin_blob)
        header = struct.pack("<4sII", b"glTF", 2, total_len)
        json_chunk = struct.pack("<I4s", len(json_bytes), b"JSON") + json_bytes
        bin_chunk = struct.pack("<I4s", len(bin_blob), b"BIN\x00") + bin_blob

        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "wb") as f:
            f.write(header + json_chunk + bin_chunk)


def build_alpine_spruce():
    """LOD1 Alpine Norway spruce (rooted underground to prevent slope floating)."""
    m = MeshBuilder()
    bark = (0.28, 0.20, 0.13)
    m.add_cylinder(0.0, -0.45, 0.55, 0.0, 0.12, 0.05, 6, bark)
    tiers = [
        (0.24, 0.86, 0.54, (0.14, 0.26, 0.15), 0.0),
        (0.58, 1.20, 0.44, (0.17, 0.31, 0.17), 0.35),
        (0.92, 1.48, 0.32, (0.20, 0.36, 0.20), 0.72),
        (1.22, 1.72, 0.18, (0.23, 0.40, 0.22), 1.05),
    ]
    for y0, y1, rad, col, rot in tiers:
        m.add_cylinder(0.0, y0, y1, 0.0, rad, 0.0, 10, col, rot_offset=rot, star_amp=0.22)
    return m


def build_alpine_spruce_lod0():
    """LOD0 detailed Alpine Norway spruce with rooted trunk, 7 drooping jagged bough whorls & asymmetric branch clusters."""
    m = MeshBuilder()
    bark = (0.26, 0.19, 0.12)
    # Deeply rooted trunk so tree never floats on steep Alpine slopes
    m.add_cylinder(0.0, -0.45, 1.50, 0.0, 0.13, 0.025, 7, bark)
    # 7 staggered drooping conifer whorls with strong star-bough indentation + individual outer branch tufts
    tiers = [
        (0.18, 0.62, 0.56, (0.12, 0.23, 0.13), 0.00, 0.28),
        (0.42, 0.86, 0.50, (0.14, 0.26, 0.15), 0.52, 0.26),
        (0.66, 1.08, 0.43, (0.16, 0.29, 0.16), 1.04, 0.25),
        (0.88, 1.28, 0.36, (0.18, 0.33, 0.18), 1.56, 0.24),
        (1.10, 1.46, 0.28, (0.20, 0.36, 0.20), 2.08, 0.22),
        (1.30, 1.62, 0.20, (0.22, 0.39, 0.21), 2.60, 0.20),
        (1.48, 1.78, 0.12, (0.25, 0.42, 0.23), 3.12, 0.16),
    ]
    for idx, (y0, y1, rad, col, rot, amp) in enumerate(tiers):
        m.add_cylinder(0.0, y0, y1, 0.0, rad, 0.0, 12, col, rot_offset=rot, star_amp=amp)
        # Add 3 asymmetric drooping bough tufts around lower/mid whorls for organic silhouette
        if idx < 4:
            for k in range(3):
                ang = rot + k * (2.0 * math.pi / 3.0) + idx * 0.45
                bx = math.cos(ang) * rad * 0.52
                bz = math.sin(ang) * rad * 0.52
                by = y0 + 0.08
                bcol = (col[0] * 1.06, col[1] * 1.08, col[2] * 1.04)
                m.add_faceted_blob(bx, by, bz, rad * 0.34, 0.11, rad * 0.34, bcol, lat_segs=3, lon_segs=6, seed=ang * 3.1)
    return m


def build_temperate_oak():
    """LOD1 European deciduous oak/beech (rooted underground)."""
    m = MeshBuilder()
    bark = (0.30, 0.21, 0.13)
    m.add_cylinder(0.0, -0.45, 0.58, 0.0, 0.13, 0.07, 6, bark)
    blobs = [
        (0.0,   0.98,  0.0,   0.46, 0.40, 0.44, (0.24, 0.40, 0.19), 1.0),
        (0.28,  0.82,  0.14,  0.34, 0.30, 0.32, (0.21, 0.36, 0.17), 2.3),
        (-0.26, 0.84,  0.18,  0.33, 0.29, 0.33, (0.26, 0.44, 0.21), 3.7),
        (0.10,  0.80, -0.28,  0.35, 0.30, 0.32, (0.19, 0.34, 0.16), 5.1),
        (-0.18, 0.92, -0.18,  0.32, 0.32, 0.30, (0.25, 0.42, 0.20), 6.4),
    ]
    for cx, cy, cz, rx, ry, rz, col, sd in blobs:
        m.add_faceted_blob(cx, cy, cz, rx, ry, rz, col, lat_segs=4, lon_segs=7, seed=sd)
    return m


def build_temperate_oak_lod0():
    """LOD0 detailed European oak/beech with flared roots, forked limbs & 11 layered organic foliage boughs."""
    m = MeshBuilder()
    bark = (0.28, 0.20, 0.13)
    # Deeply rooted trunk + flared root collar + 3 primary limbs
    m.add_cylinder(0.0, -0.45, 0.12, 0.0, 0.17, 0.12, 7, bark)
    m.add_cylinder(0.0,  0.12, 0.68, 0.0, 0.12, 0.06, 7, bark)
    m.add_box( 0.14, 0.68,  0.08, 0.22, 0.07, 0.07, bark)
    m.add_box(-0.14, 0.66,  0.06, 0.20, 0.07, 0.07, bark)
    m.add_box( 0.02, 0.64, -0.14, 0.07, 0.07, 0.20, bark)

    # 11 overlapping organic leaf-bough clusters forming an irregular natural canopy
    boughs = [
        ( 0.00, 1.12,  0.00, 0.38, 0.32, 0.36, (0.26, 0.43, 0.21), 1.1),
        ( 0.28, 0.96,  0.16, 0.30, 0.24, 0.28, (0.24, 0.40, 0.19), 2.2),
        (-0.26, 0.98,  0.20, 0.29, 0.25, 0.29, (0.28, 0.46, 0.22), 3.3),
        ( 0.14, 0.94, -0.28, 0.30, 0.24, 0.28, (0.20, 0.35, 0.17), 4.4),
        (-0.22, 0.96, -0.22, 0.28, 0.26, 0.27, (0.25, 0.42, 0.20), 5.5),
        ( 0.38, 0.78, -0.06, 0.24, 0.19, 0.23, (0.19, 0.34, 0.16), 6.6),
        (-0.36, 0.80, -0.04, 0.23, 0.19, 0.24, (0.22, 0.38, 0.18), 7.7),
        ( 0.04, 0.78,  0.34, 0.25, 0.19, 0.23, (0.25, 0.42, 0.20), 8.8),
        (-0.08, 0.76, -0.34, 0.24, 0.18, 0.23, (0.18, 0.32, 0.15), 9.9),
        ( 0.16, 1.24,  0.10, 0.22, 0.18, 0.22, (0.29, 0.48, 0.23), 10.7),
        (-0.14, 1.22, -0.08, 0.23, 0.18, 0.21, (0.27, 0.45, 0.21), 11.4),
    ]
    for cx, cy, cz, rx, ry, rz, col, sd in boughs:
        m.add_faceted_blob(cx, cy, cz, rx, ry, rz, col, lat_segs=4, lon_segs=7, seed=sd)
    return m


def build_med_cypress():
    m = MeshBuilder()
    bark = (0.30, 0.22, 0.14)
    m.add_cylinder(0.0, 0.0, 0.26, 0.0, 0.06, 0.04, 6, bark)
    dark = (0.14, 0.26, 0.14)
    mid  = (0.18, 0.32, 0.16)
    tip  = (0.22, 0.37, 0.18)
    m.add_cylinder(0.0, 0.20, 0.65, 0.0, 0.17, 0.22, 7, dark)
    m.add_cylinder(0.0, 0.65, 1.35, 0.0, 0.22, 0.14, 7, mid, rot_offset=0.25)
    m.add_cylinder(0.0, 1.35, 1.88, 0.0, 0.14, 0.0,  7, tip, rot_offset=0.50)
    return m


def build_med_olive():
    m = MeshBuilder()
    bark = (0.38, 0.31, 0.23)
    m.add_cylinder(0.0, 0.0, 0.40, 0.0, 0.10, 0.06, 6, bark)
    # Silvery-olive Mediterranean foliage clusters
    olive1 = (0.44, 0.50, 0.30)
    olive2 = (0.38, 0.45, 0.26)
    olive3 = (0.49, 0.54, 0.34)
    m.add_faceted_blob(-0.20, 0.64,  0.08, 0.36, 0.24, 0.32, olive1, 3, 7, 1.2)
    m.add_faceted_blob( 0.22, 0.62, -0.06, 0.34, 0.23, 0.34, olive2, 3, 7, 2.8)
    m.add_faceted_blob( 0.02, 0.74,  0.02, 0.32, 0.22, 0.30, olive3, 3, 7, 4.4)
    return m


def build_shrub_cluster():
    m = MeshBuilder()
    m.add_faceted_blob( 0.00, 0.16,  0.00, 0.30, 0.19, 0.28, (0.30, 0.44, 0.20), 3, 6, 0.5)
    m.add_faceted_blob( 0.24, 0.12,  0.14, 0.22, 0.15, 0.20, (0.26, 0.39, 0.18), 3, 6, 2.1)
    m.add_faceted_blob(-0.20, 0.13, -0.10, 0.24, 0.16, 0.22, (0.34, 0.47, 0.22), 3, 6, 3.7)
    return m


def build_north_townhouse():
    m = MeshBuilder()
    stone = (0.44, 0.42, 0.39)
    wall  = (0.80, 0.76, 0.68)
    trim  = (0.64, 0.60, 0.54)
    roof  = (0.58, 0.26, 0.19)
    chim  = (0.45, 0.27, 0.21)
    win   = (0.13, 0.16, 0.20)
    # Deeply rooted stone plinth (extends to y = -0.38 so houses never float on slopes)
    m.add_box(0.0, -0.14, 0.0, 1.04, 0.48, 0.78, stone)
    # Main plastered facade + cornice
    m.add_box(0.0, 0.48, 0.0, 0.98, 0.76, 0.72, wall)
    m.add_box(0.0, 0.85, 0.0, 1.02, 0.06, 0.76, trim)
    # Windows (front & back, 2 floors x 3 bays)
    for z_side in (-0.365, 0.365):
        for wy in (0.34, 0.64):
            for wx in (-0.28, 0.0, 0.28):
                m.add_box(wx, wy, z_side, 0.13, 0.18, 0.03, win)
    # Steep Central European gable roof + chimney
    m.add_gable_roof(0.0, 0.88, 0.0, 0.98, 0.52, 0.72, roof, overhang=0.07)
    m.add_box(0.28, 1.24, -0.14, 0.14, 0.34, 0.14, chim)
    return m


def build_north_mansard():
    m = MeshBuilder()
    stone = (0.48, 0.46, 0.43)
    wall  = (0.78, 0.75, 0.68)
    trim  = (0.62, 0.59, 0.54)
    slate = (0.24, 0.27, 0.32)
    chim  = (0.50, 0.44, 0.39)
    win   = (0.13, 0.16, 0.20)
    # Deeply rooted stone plinth (extends to y = -0.38)
    m.add_box(0.0, -0.14, 0.0, 1.14, 0.48, 0.94, stone)
    # Main Haussmann / Gründerzeit block + cornice
    m.add_box(0.0, 0.56, 0.0, 1.08, 0.92, 0.88, wall)
    m.add_box(0.0, 0.99, 0.0, 1.13, 0.06, 0.93, trim)
    # Windows (front & back, 3 floors x 3 bays)
    for z_side in (-0.445, 0.445):
        for wy in (0.28, 0.56, 0.82):
            for wx in (-0.32, 0.0, 0.32):
                m.add_box(wx, wy, z_side, 0.14, 0.17, 0.03, win)
    # Side windows (2 bays)
    for x_side in (-0.545, 0.545):
        for wy in (0.34, 0.70):
            for wz in (-0.20, 0.20):
                m.add_box(x_side, wy, wz, 0.03, 0.17, 0.14, win)
    # Mansard hip slate roof + twin chimneys
    m.add_hip_roof(0.0, 1.02, 0.0, 1.08, 0.36, 0.88, slate, ridge_frac=0.62, overhang=0.05)
    m.add_box(-0.30, 1.40, 0.16, 0.12, 0.24, 0.12, chim)
    m.add_box( 0.30, 1.40, -0.16, 0.12, 0.24, 0.12, chim)
    return m


def build_north_cathedral():
    m = MeshBuilder()
    stone = (0.74, 0.70, 0.63)
    roof  = (0.30, 0.35, 0.41)
    spire = (0.24, 0.30, 0.35)
    # Nave & Transept
    m.add_box(0.0, 0.48, 0.0, 1.50, 0.96, 0.68, stone)
    m.add_gable_roof(0.0, 0.96, 0.0, 1.50, 0.48, 0.68, roof, overhang=0.04)
    m.add_box(0.05, 0.44, 0.0, 0.58, 0.88, 1.24, stone)
    # West Bell Tower & Tall Gothic Spire
    m.add_box(-0.56, 0.88, 0.0, 0.48, 1.76, 0.48, stone)
    m.add_cylinder(-0.56, 1.76, 2.95, 0.0, 0.24, 0.0, 4, spire, rot_offset=math.pi * 0.25)
    return m


def build_med_villa():
    """Rooted Pyrenean/Mediterranean stone & stucco villa with terracotta roof & recessed windows."""
    m = MeshBuilder()
    plinth = (0.54, 0.48, 0.40)
    ochre  = (0.74, 0.64, 0.49)
    terra  = (0.58, 0.32, 0.22)
    win    = (0.12, 0.14, 0.16)
    m.add_box(0.0, -0.15, 0.0, 1.10, 0.46, 0.78, plinth)
    m.add_box(0.0, 0.42, 0.0, 1.04, 0.64, 0.72, ochre)
    for wx in (-0.28, 0.0, 0.28):
        m.add_box(wx, 0.48,  0.365, 0.12, 0.16, 0.02, win)
        m.add_box(wx, 0.48, -0.365, 0.12, 0.16, 0.02, win)
    m.add_hip_roof(0.0, 0.74, 0.0, 1.04, 0.28, 0.72, terra, ridge_frac=0.55, overhang=0.07)
    m.add_box(0.34, 0.32, 0.48, 0.46, 0.56, 0.44, ochre)
    m.add_hip_roof(0.34, 0.60, 0.48, 0.46, 0.18, 0.44, terra, ridge_frac=0.35, overhang=0.05)
    return m


def build_med_basilica():
    m = MeshBuilder()
    marble = (0.90, 0.84, 0.72)
    terra  = (0.75, 0.41, 0.28)
    gold   = (0.86, 0.74, 0.42)
    # Basilica nave
    m.add_box(0.0, 0.46, 0.0, 1.38, 0.92, 0.82, marble)
    m.add_gable_roof(0.0, 0.92, 0.0, 1.38, 0.32, 0.82, terra, overhang=0.05)
    # Octagonal drum + Renaissance terracotta dome + lantern
    m.add_cylinder(0.0, 1.05, 1.48, 0.0, 0.42, 0.40, 8, marble)
    m.add_faceted_blob(0.0, 1.48, 0.0, 0.41, 0.42, 0.41, terra, lat_segs=4, lon_segs=8, seed=0.0)
    m.add_cylinder(0.0, 1.88, 2.12, 0.0, 0.10, 0.02, 6, gold)
    # Slender Italian Campanile bell tower beside basilica
    m.add_box(0.86, 0.92, 0.36, 0.30, 1.84, 0.30, marble)
    m.add_cylinder(0.86, 1.84, 2.32, 0.36, 0.21, 0.0, 4, terra, rot_offset=math.pi * 0.25)
    return m


def build_harbor_pier():
    m = MeshBuilder()
    stone = (0.58, 0.55, 0.50)
    wood  = (0.52, 0.38, 0.24)
    roof  = (0.45, 0.36, 0.30)
    white = (0.92, 0.91, 0.88)
    red   = (0.78, 0.24, 0.20)
    # Stone quay & pier
    m.add_box(0.0, 0.10, 0.0, 1.80, 0.20, 0.52, stone)
    # Small port warehouse
    m.add_box(-0.36, 0.38, 0.0, 0.72, 0.36, 0.36, wood)
    m.add_gable_roof(-0.36, 0.56, 0.0, 0.72, 0.20, 0.36, roof, overhang=0.04)
    # Miniature harbor lighthouse at pier tip
    m.add_cylinder(0.72, 0.20, 0.78, 0.0, 0.14, 0.09, 8, white)
    m.add_cylinder(0.72, 0.78, 0.94, 0.0, 0.11, 0.11, 8, red)
    m.add_cylinder(0.72, 0.94, 1.10, 0.0, 0.11, 0.0,  8, red)
    return m


def build_rail_station():
    """Detailed 19th-century Central European railway station with arched iron-glass train shed & brick headhouse."""
    m = MeshBuilder()
    apron    = (0.28, 0.27, 0.25)  # Weathered ground foundation apron
    platform = (0.48, 0.46, 0.43)  # Aged stone platform paving
    coping   = (0.62, 0.59, 0.54)  # Pale granite platform edge
    ballast  = (0.26, 0.24, 0.22)
    brick    = (0.56, 0.30, 0.23)  # Muted weathered Bavarian brick
    stone    = (0.66, 0.62, 0.55)  # Aged limestone trim
    glass    = (0.36, 0.44, 0.49)  # Smoke-tinted industrial skylight glass
    iron     = (0.19, 0.21, 0.23)  # Cast-iron trusses & columns
    slate    = (0.23, 0.26, 0.31)  # Weathered dark slate roof
    copper   = (0.30, 0.44, 0.40)  # Patinated copper spire
    win_dark = (0.12, 0.14, 0.17)  # Recessed window glazing

    # Subtle ground-embedding apron (prevents floating corners on gentle terrain slopes)
    m.add_box(0.0, -0.02, 0.22, 2.38, 0.08, 1.78, apron)

    # Dual platforms running along X axis with crisp granite coping edges
    m.add_box(0.0, 0.06,  0.46, 2.24, 0.12, 0.34, platform)
    m.add_box(0.0, 0.06, -0.46, 2.24, 0.12, 0.34, platform)
    m.add_box(0.0, 0.125,  0.30, 2.24, 0.02, 0.04, coping)
    m.add_box(0.0, 0.125, -0.30, 2.24, 0.02, 0.04, coping)
    # Recessed ballast trackbed between platforms
    m.add_box(0.0, 0.025, 0.00, 2.28, 0.05, 0.58, ballast)

    # Barrel-vault arched iron & smoke-tinted glass train shed canopy (5 curved segments)
    shed_x0, shed_x1 = -0.88, 0.88
    arch_r = 0.58
    arch_cy = 0.34
    arch_segs = 6
    for i in range(arch_segs):
        a0 = math.pi * (0.10 + 0.80 * i / arch_segs)
        a1 = math.pi * (0.10 + 0.80 * (i + 1) / arch_segs)
        z0, y0 = math.cos(a0) * arch_r, arch_cy + math.sin(a0) * 0.42
        z1, y1 = math.cos(a1) * arch_r, arch_cy + math.sin(a1) * 0.42
        # Alternate dark slate outer eaves and smoke-tinted glass upper skylight
        seg_col = slate if (i == 0 or i == arch_segs - 1) else glass
        m.add_quad((shed_x0, y0, z0), (shed_x1, y0, z0), (shed_x1, y1, z1), (shed_x0, y1, z1), seg_col)
    # Clerestory ridge skylight vent along canopy crest
    m.add_box(0.0, 0.78, 0.0, 1.66, 0.06, 0.14, iron)
    m.add_box(0.0, 0.82, 0.0, 1.72, 0.025, 0.18, slate)

    # Cast-iron support columns & curved arch ribs across 5 structural bays
    for x in (-0.86, -0.43, 0.0, 0.43, 0.86):
        m.add_box(x, 0.27,  0.54, 0.045, 0.38, 0.045, iron)
        m.add_box(x, 0.27, -0.54, 0.045, 0.38, 0.045, iron)
        # Overhead iron truss rib
        for i in range(arch_segs):
            a0 = math.pi * (0.10 + 0.80 * (i + 0.5) / arch_segs)
            zm, ym = math.cos(a0) * arch_r, arch_cy + math.sin(a0) * 0.42 + 0.015
            m.add_box(x, ym, zm, 0.032, 0.032, 0.20, iron)

    # Classic brick & limestone headhouse on the +Z side with recessed arched windows & cornice
    m.add_box(0.0, 0.35, 0.82, 1.44, 0.56, 0.46, brick)
    m.add_box(0.0, 0.09, 0.82, 1.50, 0.14, 0.50, stone)   # Rusticated stone plinth
    m.add_box(0.0, 0.62, 0.82, 1.50, 0.05, 0.50, stone)   # Upper stone cornice
    # Recessed dark-glass windows on street (+Z) and platform (-Z) facades
    for wx in (-0.54, -0.32, 0.32, 0.54):
        m.add_box(wx, 0.30, 1.055, 0.11, 0.18, 0.02, win_dark)
        m.add_box(wx, 0.50, 1.055, 0.11, 0.14, 0.02, win_dark)
        m.add_box(wx, 0.30, 0.585, 0.11, 0.18, 0.02, win_dark)
    # Slate hip roof + twin brick chimneys
    m.add_hip_roof(0.0, 0.64, 0.82, 1.44, 0.26, 0.46, slate, ridge_frac=0.62, overhang=0.06)
    m.add_box(-0.48, 0.90, 0.86, 0.09, 0.20, 0.09, brick)
    m.add_box( 0.48, 0.90, 0.86, 0.09, 0.20, 0.09, brick)
    # Central limestone clock tower & patinated copper spire
    m.add_box(0.0, 0.56, 0.94, 0.36, 0.88, 0.28, stone)
    m.add_box(0.0, 0.32, 1.085, 0.14, 0.22, 0.02, win_dark)  # Entrance portal
    m.add_box(0.0, 0.80, 1.085, 0.13, 0.13, 0.02, (0.76, 0.74, 0.68))  # Clock face
    m.add_cylinder(0.0, 1.00, 1.32, 0.94, 0.19, 0.0, 4, copper, rot_offset=math.pi * 0.25)
    return m


def build_rail_station_2track():
    """Upgraded 2-track Central European through-station with dual parallel platform tracks,
    island + side platforms, wider arched iron-glass train shed, and built-in entry/exit switches."""
    m = MeshBuilder()
    apron    = (0.28, 0.27, 0.25)
    platform = (0.48, 0.46, 0.43)
    coping   = (0.62, 0.59, 0.54)
    ballast  = (0.25, 0.23, 0.21)
    rail_col = (0.42, 0.45, 0.50)
    brick    = (0.56, 0.30, 0.23)
    stone    = (0.66, 0.62, 0.55)
    glass    = (0.36, 0.44, 0.49)
    iron     = (0.19, 0.21, 0.23)
    slate    = (0.23, 0.26, 0.31)
    copper   = (0.30, 0.44, 0.40)
    win_dark = (0.12, 0.14, 0.17)

    # Wider ground foundation apron
    m.add_box(0.0, -0.02, 0.26, 2.74, 0.08, 2.38, apron)

    # Wide ballast bed covering both parallel platform tracks + entry/exit switch aprons
    m.add_box(0.0, 0.025, 0.0, 2.66, 0.05, 1.18, ballast)

    # Dual parallel steel track beds inside station (z = -0.32 and z = +0.32) + switch converging leads at x = ±1.05..±1.30
    for tz in (-0.32, 0.32):
        m.add_box(0.0, 0.055, tz - 0.08, 2.16, 0.015, 0.03, rail_col)
        m.add_box(0.0, 0.055, tz + 0.08, 2.16, 0.015, 0.03, rail_col)
        # Entry/exit converging switch blades toward central throat (x = ±1.28, z = 0)
        for sx in (-1.0, 1.0):
            x0, x1 = sx * 1.04, sx * 1.30
            m.add_quad((x0, 0.06, tz - 0.05), (x1, 0.06, -0.04), (x1, 0.06, 0.04), (x0, 0.06, tz + 0.05), rail_col)

    # Outer platforms (z = ±0.72) + slim central island platform (z = 0.0)
    m.add_box(0.0, 0.065,  0.72, 2.24, 0.13, 0.28, platform)
    m.add_box(0.0, 0.065, -0.72, 2.24, 0.13, 0.28, platform)
    m.add_box(0.0, 0.065,  0.00, 1.96, 0.13, 0.22, platform)
    m.add_box(0.0, 0.132,  0.59, 2.24, 0.018, 0.035, coping)
    m.add_box(0.0, 0.132, -0.59, 2.24, 0.018, 0.035, coping)
    m.add_box(0.0, 0.132,  0.10, 1.96, 0.018, 0.030, coping)
    m.add_box(0.0, 0.132, -0.10, 1.96, 0.018, 0.030, coping)

    # Grand wider barrel-vault arched iron & smoked-glass train shed over BOTH tracks
    shed_x0, shed_x1 = -0.96, 0.96
    arch_r = 0.84
    arch_cy = 0.36
    arch_segs = 8
    for i in range(arch_segs):
        a0 = math.pi * (0.08 + 0.84 * i / arch_segs)
        a1 = math.pi * (0.08 + 0.84 * (i + 1) / arch_segs)
        z0, y0 = math.cos(a0) * arch_r, arch_cy + math.sin(a0) * 0.56
        z1, y1 = math.cos(a1) * arch_r, arch_cy + math.sin(a1) * 0.56
        seg_col = slate if (i <= 1 or i >= arch_segs - 2) else glass
        m.add_quad((shed_x0, y0, z0), (shed_x1, y0, z0), (shed_x1, y1, z1), (shed_x0, y1, z1), seg_col)
    m.add_box(0.0, 0.94, 0.0, 1.84, 0.065, 0.18, iron)
    m.add_box(0.0, 0.985, 0.0, 1.90, 0.028, 0.22, slate)

    # Cast-iron support columns & curved arch ribs across 5 structural bays
    for x in (-0.92, -0.46, 0.0, 0.46, 0.92):
        m.add_box(x, 0.29,  0.80, 0.048, 0.42, 0.048, iron)
        m.add_box(x, 0.29, -0.80, 0.048, 0.42, 0.048, iron)
        for i in range(arch_segs):
            a0 = math.pi * (0.08 + 0.84 * (i + 0.5) / arch_segs)
            zm, ym = math.cos(a0) * arch_r, arch_cy + math.sin(a0) * 0.56 + 0.016
            m.add_box(x, ym, zm, 0.032, 0.032, 0.22, iron)

    # Grand brick & limestone headhouse on the +Z side
    m.add_box(0.0, 0.37, 1.10, 1.72, 0.60, 0.48, brick)
    m.add_box(0.0, 0.09, 1.10, 1.78, 0.14, 0.52, stone)
    m.add_box(0.0, 0.66, 1.10, 1.78, 0.05, 0.52, stone)
    for wx in (-0.68, -0.46, -0.26, 0.26, 0.46, 0.68):
        m.add_box(wx, 0.32, 1.345, 0.11, 0.18, 0.02, win_dark)
        m.add_box(wx, 0.52, 1.345, 0.11, 0.14, 0.02, win_dark)
    m.add_hip_roof(0.0, 0.68, 1.10, 1.72, 0.28, 0.48, slate, ridge_frac=0.66, overhang=0.06)
    m.add_box(-0.60, 0.96, 1.14, 0.09, 0.22, 0.09, brick)
    m.add_box( 0.60, 0.96, 1.14, 0.09, 0.22, 0.09, brick)
    # Central limestone clock tower & patinated copper spire
    m.add_box(0.0, 0.62, 1.22, 0.40, 0.98, 0.30, stone)
    m.add_box(0.0, 0.34, 1.375, 0.16, 0.24, 0.02, win_dark)
    m.add_box(0.0, 0.88, 1.375, 0.14, 0.14, 0.02, (0.76, 0.74, 0.68))
    m.add_cylinder(0.0, 1.11, 1.46, 1.22, 0.21, 0.0, 4, copper, rot_offset=math.pi * 0.25)
    return m


def build_rail_signal():
    """Miniature European railway semaphore / light signal post."""
    m = MeshBuilder()
    base = (0.30, 0.30, 0.32)
    mast = (0.20, 0.22, 0.24)
    head = (0.14, 0.16, 0.18)
    lamp = (0.94, 0.94, 0.94)  # Tinted per-instance by signal type
    m.add_box(0.0, 0.05, 0.0, 0.22, 0.10, 0.22, base)
    m.add_cylinder(0.0, 0.10, 0.95, 0.0, 0.045, 0.035, 8, mast)
    m.add_box(0.0, 0.86, 0.06, 0.18, 0.26, 0.14, head)
    m.add_faceted_blob(0.0, 0.88, 0.14, 0.07, 0.07, 0.05, lamp, 3, 8, 0.0)
    return m


def build_rail_tunnel_portal():
    """Arched Alpine granite masonry tunnel portal embedded into a rocky hillside mound."""
    m = MeshBuilder()
    stone = (0.48, 0.46, 0.43)
    trim  = (0.36, 0.35, 0.32)
    rock  = (0.40, 0.40, 0.37)
    rock2 = (0.34, 0.34, 0.32)
    dark  = (0.04, 0.04, 0.05)

    # Front stone masonry facade facing +Z with keystone & arch cornice
    m.add_box(-0.34, 0.30, 0.16, 0.24, 0.60, 0.22, stone)
    m.add_box( 0.34, 0.30, 0.16, 0.24, 0.60, 0.22, stone)
    m.add_box( 0.00, 0.64, 0.16, 0.96, 0.20, 0.24, stone)
    m.add_box( 0.00, 0.76, 0.18, 1.06, 0.08, 0.28, trim)
    m.add_box( 0.00, 0.62, 0.29, 0.14, 0.18, 0.04, trim)  # Keystone
    # Flared granite wing walls
    m.add_box(-0.56, 0.20, 0.10, 0.22, 0.40, 0.34, stone)
    m.add_box( 0.56, 0.20, 0.10, 0.22, 0.40, 0.34, stone)
    # Deep pitch-black tunnel mouth interior
    m.add_box( 0.00, 0.27, 0.04, 0.48, 0.54, 0.24, dark)

    # Rocky Alpine earth-mound hood extending behind the portal (-Z)
    m.add_box( 0.00, 0.38, -0.58, 1.24, 0.84, 1.18, rock)
    m.add_faceted_blob( 0.00, 0.72, -0.62, 0.86, 0.44, 0.88, rock,  lat_segs=4, lon_segs=8, seed=1.3)
    m.add_faceted_blob(-0.46, 0.40, -0.54, 0.52, 0.42, 0.76, rock2, lat_segs=3, lon_segs=7, seed=2.7)
    m.add_faceted_blob( 0.46, 0.40, -0.54, 0.52, 0.42, 0.76, rock2, lat_segs=3, lon_segs=7, seed=4.1)
    m.add_box( 0.00, -0.18, -0.42, 1.32, 0.36, 1.42, rock2)
    return m


def build_rail_locomotive():
    """Detailed European steam locomotive + coal tender with true cylindrical boiler & spoked wheels, facing +Z."""
    m = MeshBuilder()
    iron     = (0.15, 0.16, 0.18)
    smokebox = (0.12, 0.13, 0.15)
    boiler   = (0.18, 0.23, 0.20)  # Deep Bavarian locomotive dark green-iron
    cab_grn  = (0.17, 0.32, 0.21)
    brass    = (0.78, 0.62, 0.24)
    red      = (0.58, 0.18, 0.15)
    steel    = (0.46, 0.49, 0.53)
    coal     = (0.09, 0.09, 0.11)
    win_dark = (0.10, 0.12, 0.14)

    # Heavy cast-iron chassis frame & front red buffer beam with twin buffers (+Z = front)
    m.add_box(0.0, 0.15,  0.16, 0.42, 0.12, 1.22, iron)
    m.add_box(0.0, 0.16,  0.79, 0.48, 0.10, 0.06, red)
    m.add_cylinder_z(-0.15, 0.16, 0.82, 0.89, 0.032, 0.042, 8, iron)
    m.add_cylinder_z( 0.15, 0.16, 0.82, 0.89, 0.032, 0.042, 8, iron)

    # True 12-sided cylindrical horizontal boiler + darker front smokebox & brass bands
    m.add_cylinder_z(0.0, 0.38, -0.10, 0.50, 0.19, 0.19, 12, boiler)
    m.add_cylinder_z(0.0, 0.38,  0.50, 0.72, 0.195, 0.195, 12, smokebox)
    # Brass boiler bands
    for bz in (0.04, 0.24, 0.44):
        m.add_cylinder_z(0.0, 0.38, bz - 0.015, bz + 0.015, 0.198, 0.198, 12, brass)
    # Brass headlamp on front smokebox door
    m.add_cylinder_z(0.0, 0.40, 0.72, 0.77, 0.045, 0.045, 8, brass)

    # Brass steam dome + sand dome
    m.add_cylinder(0.0, 0.54, 0.72, 0.22, 0.095, 0.08, 10, brass)
    m.add_cylinder(0.0, 0.54, 0.65, 0.00, 0.075, 0.065, 10, boiler)

    # Flared Victorian smokestack funnel at front (+Z = 0.60) with brass rim
    m.add_cylinder(0.0, 0.54, 1.00, 0.60, 0.062, 0.088, 10, smokebox)
    m.add_cylinder(0.0, 0.97, 1.03, 0.60, 0.098, 0.098, 10, brass)

    # Driver cab at rear (-Z) with recessed windows & arched iron roof
    m.add_box(0.0, 0.44, -0.26, 0.44, 0.46, 0.36, cab_grn)
    m.add_box(-0.225, 0.52, -0.26, 0.015, 0.16, 0.20, win_dark)
    m.add_box( 0.225, 0.52, -0.26, 0.015, 0.16, 0.20, win_dark)
    m.add_box(0.0, 0.70, -0.26, 0.48, 0.05, 0.44, iron)

    # Cylindrical crimson driving wheels + horizontal steel coupling rods along both sides
    for wz, wr in ((0.54, 0.09), (0.24, 0.13), (-0.06, 0.13), (-0.32, 0.10)):
        m.add_cylinder_x(-0.25, -0.20, wr, wz, wr, 12, red)
        m.add_cylinder_x( 0.20,  0.25, wr, wz, wr, 12, red)
    # Steel side coupling rods
    m.add_box(-0.255, 0.12, 0.09, 0.016, 0.032, 0.68, steel)
    m.add_box( 0.255, 0.12, 0.09, 0.016, 0.032, 0.68, steel)

    # Attached Coal Tender (-Z) with wheels & heaped dark anthracite coal
    m.add_box(0.0, 0.15, -0.82, 0.40, 0.11, 0.60, iron)
    m.add_box(0.0, 0.34, -0.82, 0.40, 0.28, 0.56, cab_grn)
    m.add_box(0.0, 0.49, -0.82, 0.43, 0.03, 0.60, iron)
    m.add_faceted_blob(0.0, 0.52, -0.82, 0.17, 0.10, 0.23, coal, 3, 8, 0.4)
    for wz in (-0.64, -0.98):
        m.add_cylinder_x(-0.24, -0.19, 0.09, wz, 0.09, 10, red)
        m.add_cylinder_x( 0.19,  0.24, 0.09, wz, 0.09, 10, red)
    return m


def build_rail_carriage():
    """Detailed European passenger coach (weathered mahogany/cream with recessed windows & bogies), facing +Z."""
    m = MeshBuilder()
    iron     = (0.16, 0.17, 0.19)
    wood     = (0.44, 0.22, 0.15)  # Weathered mahogany lower panels
    cream    = (0.68, 0.65, 0.57)  # Muted sunlit cream upper fascia
    roof     = (0.24, 0.26, 0.30)  # Weathered slate-iron roof
    brass    = (0.76, 0.60, 0.24)
    win_dark = (0.11, 0.14, 0.17)

    # Steel undercarriage, end buffers & twin bogie wheelsets
    m.add_box(0.0, 0.13, 0.0, 0.40, 0.10, 1.38, iron)
    for bz in (-0.72, 0.72):
        m.add_cylinder_z(-0.14, 0.14, bz - 0.03, bz + 0.03, 0.028, 0.028, 8, iron)
        m.add_cylinder_z( 0.14, 0.14, bz - 0.03, bz + 0.03, 0.028, 0.028, 8, iron)
    for wz in (-0.48, -0.28, 0.28, 0.48):
        m.add_cylinder_x(-0.23, -0.18, 0.085, wz, 0.085, 10, iron)
        m.add_cylinder_x( 0.18,  0.23, 0.085, wz, 0.085, 10, iron)

    # Coach body: weathered mahogany lower band + muted cream window fascia
    m.add_box(0.0, 0.29, 0.0, 0.44, 0.22, 1.28, wood)
    m.add_box(0.0, 0.48, 0.0, 0.43, 0.18, 1.26, cream)
    # 5 recessed passenger windows per side
    for wz in (-0.44, -0.22, 0.0, 0.22, 0.44):
        m.add_box(-0.22, 0.48, wz, 0.015, 0.12, 0.14, win_dark)
        m.add_box( 0.22, 0.48, wz, 0.015, 0.12, 0.14, win_dark)

    # Curved clerestory roof + brass roof lamp ventilators
    m.add_box(0.0, 0.60, 0.0, 0.48, 0.06, 1.36, roof)
    m.add_box(0.0, 0.66, 0.0, 0.30, 0.06, 1.18, roof)
    for vz in (-0.36, 0.0, 0.36):
        m.add_cylinder(0.0, 0.69, 0.74, vz, 0.035, 0.025, 8, brass)
    return m


def main():
    out_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "godot", "assets", "models",
    )
    os.makedirs(out_dir, exist_ok=True)

    assets = {
        "tree_alpine_spruce.glb":      build_alpine_spruce,
        "tree_alpine_spruce_lod0.glb": build_alpine_spruce_lod0,
        "tree_temperate_oak.glb":      build_temperate_oak,
        "tree_temperate_oak_lod0.glb": build_temperate_oak_lod0,
        "tree_med_cypress.glb":   build_med_cypress,
        "tree_med_olive.glb":     build_med_olive,
        "veg_shrub_cluster.glb":  build_shrub_cluster,
        "bldg_north_townhouse.glb": build_north_townhouse,
        "bldg_north_mansard.glb":   build_north_mansard,
        "bldg_north_cathedral.glb": build_north_cathedral,
        "bldg_med_villa.glb":       build_med_villa,
        "bldg_med_basilica.glb":    build_med_basilica,
        "landmark_harbor_pier.glb": build_harbor_pier,
        "rail_station.glb":         build_rail_station,
        "rail_station_2track.glb":  build_rail_station_2track,
        "rail_signal.glb":          build_rail_signal,
        "rail_tunnel_portal.glb":   build_rail_tunnel_portal,
        "rail_locomotive.glb":      build_rail_locomotive,
        "rail_carriage.glb":        build_rail_carriage,
    }

    for fname, fn in assets.items():
        mesh = fn()
        path = os.path.join(out_dir, fname)
        mesh.export_glb(path)
        print(f"Generated {fname:26s} ({len(mesh.positions) // 3:4d} tris)")


if __name__ == "__main__":
    main()
