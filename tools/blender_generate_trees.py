#!/usr/bin/env python3
"""
Headless Blender 5.2+ procedural generator for LOD0 alpha-cutout 3D trees in Raildev 3D.

Run via:
    blender --background --python tools/blender_generate_trees.py

Generates multi-material glTF 2.0 (.glb) models with:
  - Surface 0 ("Bark"):    Smooth tapered rooted trunks & forked limbs (y = -0.45 root depth) with cylindrical UVs
  - Surface 1 ("Foliage"): Curved, cupped alpha-cutout branch cards with clean 0..1 UVs,
                           blended spherical/radial crown normals for lush volumetric shading,
                           and baked inner-to-outer crown AO in vertex colors.
"""

import math
import os
import random
import bpy
import bmesh
from mathutils import Matrix, Vector, Euler

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "godot", "assets", "models")


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def make_material(name: str, base_color=(0.5, 0.5, 0.5, 1.0)) -> bpy.types.Material:
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = base_color
    return mat


def add_tapered_limb(
    bm: bmesh.types.BMesh,
    uv_layer,
    col_layer,
    pts: list[tuple[Vector, float]],
    segs: int = 8,
    mat_idx: int = 0,
    v_scale: float = 1.6,
    color=(0.32, 0.24, 0.16, 1.0),
):
    """Add a smooth tapered tubular trunk/limb along a polyline of (position, radius)."""
    rings = []
    cum_len = 0.0
    prev_p = pts[0][0]
    for i, (p, r) in enumerate(pts):
        if i > 0:
            cum_len += (p - prev_p).length
        prev_p = p
        if i < len(pts) - 1:
            tang = (pts[i + 1][0] - p).normalized()
        else:
            tang = (p - pts[i - 1][0]).normalized()
        up_ref = Vector((1.0, 0.0, 0.0)) if abs(tang.z) > 0.92 else Vector((0.0, 0.0, 1.0))
        side = tang.cross(up_ref).normalized()
        binorm = tang.cross(side).normalized()

        ring = []
        for s in range(segs):
            ang = 2.0 * math.pi * s / segs
            offset = (side * math.cos(ang) + binorm * math.sin(ang)) * r
            v = bm.verts.new(p + offset)
            ring.append((v, float(s) / segs, cum_len * v_scale))
        rings.append(ring)

    for i in range(len(rings) - 1):
        r0 = rings[i]
        r1 = rings[i + 1]
        for s in range(segs):
            sn = (s + 1) % segs
            v00, u0, v_a = r0[s]
            v01, u1, _ = r0[sn]
            v11, _, v_b = r1[sn]
            v10, _, _ = r1[s]
            u1_wrap = 1.0 if sn == 0 else u1
            try:
                f = bm.faces.new((v00, v01, v11, v10))
                f.material_index = mat_idx
                f.smooth = True
                uvs = [(u0, v_a), (u1_wrap, v_a), (u1_wrap, v_b), (u0, v_b)]
                for loop, uv in zip(f.loops, uvs):
                    loop[uv_layer].uv = uv
                    loop[col_layer] = color
            except ValueError:
                pass


def add_curved_bough_card(
    bm: bmesh.types.BMesh,
    uv_layer,
    col_layer,
    origin: Vector,
    yaw: float,
    pitch: float,
    roll: float,
    length: float,
    width: float,
    droop: float,
    cup: float,
    mat_idx: int = 1,
    ao_base: float = 0.58,
    ao_tip: float = 1.00,
):
    """
    Create a 3x2 curved, arched & cupped bough card anchored at `origin` (UV v=0 at stem, v=1 at tip).
    In Blender space, Z is up; glTF exporter automatically converts Blender Z-up -> Godot Y-up!
    """
    rot = Euler((pitch, roll, yaw), 'XYZ').to_matrix().to_4x4()
    # Local card extends along +Y (length), spans -X..+X (width), arches/droops along Z
    grid = []
    rows = 3  # 0, 1, 2 along length
    cols = 3  # 0, 1, 2 across width
    for r in range(rows):
        v_t = r / (rows - 1)  # 0 at stem, 1 at outer tip
        # Slight upward arch then natural droop at tip
        z_arch = math.sin(v_t * math.pi) * (length * 0.08) - (v_t * v_t) * droop
        row_verts = []
        for c in range(cols):
            u_t = c / (cols - 1)  # 0 left, 0.5 center, 1 right
            x_off = (u_t - 0.5) * width
            # Gentle cup/V-fold across width so card has 3D volume from every angle
            z_cup = -abs(u_t - 0.5) * 2.0 * cup
            local_p = Vector((x_off, v_t * length, z_arch + z_cup))
            world_p = origin + (rot @ local_p)
            vert = bm.verts.new(world_p)
            ao = ao_base + (ao_tip - ao_base) * (0.35 + 0.65 * v_t)
            row_verts.append((vert, u_t, v_t, ao))
        grid.append(row_verts)

    for r in range(rows - 1):
        for c in range(cols - 1):
            v00, u00, tv00, a00 = grid[r][c]
            v01, u01, tv01, a01 = grid[r][c + 1]
            v11, u11, tv11, a11 = grid[r + 1][c + 1]
            v10, u10, tv10, a10 = grid[r + 1][c]
            try:
                f = bm.faces.new((v00, v01, v11, v10))
                f.material_index = mat_idx
                f.smooth = True
                for loop, (u, v, a) in zip(
                    f.loops,
                    [(u00, tv00, a00), (u01, tv01, a01), (u11, tv11, a11), (u10, tv10, a10)],
                ):
                    loop[uv_layer].uv = (u, v)
                    loop[col_layer] = (a, a, a, 1.0)
            except ValueError:
                pass


def apply_radial_foliage_normals(obj: bpy.types.Object, crown_center: Vector, blend: float = 0.78):
    """
    Blend foliage card loop normals outward from `crown_center` so intersecting alpha cards
    shade as a lush, continuous 3D tree volume instead of showing flat-card lighting seams.
    """
    mesh = obj.data
    normals = []
    for poly in mesh.polygons:
        for loop_idx in poly.loop_indices:
            v_idx = mesh.loops[loop_idx].vertex_index
            co = mesh.vertices[v_idx].co
            base_n = mesh.vertices[v_idx].normal
            if poly.material_index == 1:
                radial = (co - crown_center)
                # Slight upward bias so canopy catches warm sky/sun light naturally
                radial.z += 0.25
                if radial.length > 1e-5:
                    radial.normalize()
                    n = (base_n * (1.0 - blend) + radial * blend).normalized()
                else:
                    n = Vector((0.0, 0.0, 1.0))
                normals.append(n)
            else:
                normals.append(base_n.normalized())
    mesh.normals_split_custom_set(normals)


def export_glb(obj: bpy.types.Object, filename: str):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    out_path = os.path.join(OUT_DIR, filename)
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format='GLB',
        use_selection=True,
        export_yup=True,
        export_texcoords=True,
        export_normals=True,
        export_attributes=True,
        export_materials='EXPORT',
    )
    print(f"  [blender] exported {filename} ({len(obj.data.polygons)} polys, {len(obj.data.vertices)} verts)")


def build_spruce_lod0():
    """Alpine Norway spruce: rooted bark trunk + 8 drooping alpha-cutout bough whorls + spire crown."""
    clear_scene()
    rng = random.Random(4201)

    mesh = bpy.data.meshes.new("AlpineSpruceLOD0")
    obj = bpy.data.objects.new("AlpineSpruceLOD0", mesh)
    bpy.context.collection.objects.link(obj)

    mat_bark = make_material("Bark", (0.28, 0.20, 0.13, 1.0))
    mat_fol = make_material("Foliage", (0.20, 0.36, 0.18, 1.0))
    obj.data.materials.append(mat_bark)
    obj.data.materials.append(mat_fol)

    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    col_layer = bm.loops.layers.color.new("Col")

    # Rooted trunk (Blender Z-up -> Godot Y-up; z = -0.45 ensures ZERO floating on steep Alpine slopes!)
    trunk_pts = [
        (Vector((0.0, 0.0, -0.45)), 0.13),
        (Vector((0.0, 0.0,  0.02)), 0.115),
        (Vector((0.008, -0.005, 0.45)), 0.085),
        (Vector((-0.006, 0.007, 0.95)), 0.055),
        (Vector((0.004, -0.004, 1.42)), 0.028),
        (Vector((0.0, 0.0, 1.70)), 0.010),
    ]
    add_tapered_limb(bm, uv_layer, col_layer, trunk_pts, segs=8, mat_idx=0)

    # 10 dense staggered conifer whorls (full, overlapping Alpine spruce silhouette!)
    whorls = [
        # (z_height, num_cards, length, width, pitch_deg, droop, ao_base)
        (0.20, 9, 0.66, 0.58, -15.0, 0.14, 0.46),
        (0.34, 9, 0.62, 0.56, -13.0, 0.13, 0.50),
        (0.48, 8, 0.57, 0.52, -10.0, 0.11, 0.54),
        (0.64, 8, 0.52, 0.48,  -7.0, 0.09, 0.58),
        (0.80, 8, 0.46, 0.44,  -4.0, 0.08, 0.64),
        (0.96, 7, 0.40, 0.40,   0.0, 0.06, 0.68),
        (1.12, 7, 0.34, 0.36,   5.0, 0.05, 0.74),
        (1.28, 6, 0.28, 0.31,  12.0, 0.03, 0.80),
        (1.44, 6, 0.22, 0.26,  20.0, 0.02, 0.86),
        (1.58, 5, 0.16, 0.20,  32.0, 0.01, 0.90),
    ]
    for w_idx, (zh, count, length, width, pitch_deg, droop, ao_b) in enumerate(whorls):
        ang_off = w_idx * 0.57
        for k in range(count):
            yaw = ang_off + (2.0 * math.pi * k / count) + rng.uniform(-0.16, 0.16)
            pitch = math.radians(pitch_deg + rng.uniform(-7.0, 7.0))
            roll = math.radians(rng.uniform(-18.0, 18.0))
            z_j = zh + rng.uniform(-0.035, 0.035)
            # Anchor slightly inside trunk so stem never detaches
            r_in = 0.015
            orig = Vector((math.cos(yaw - math.pi * 0.5) * r_in, math.sin(yaw - math.pi * 0.5) * r_in, z_j))
            add_curved_bough_card(
                bm, uv_layer, col_layer,
                origin=orig,
                yaw=yaw,
                pitch=pitch,
                roll=roll,
                length=length * rng.uniform(0.92, 1.12),
                width=width * rng.uniform(0.94, 1.14),
                droop=droop,
                cup=width * 0.16,
                mat_idx=1,
                ao_base=ao_b,
                ao_tip=min(1.0, ao_b + 0.38),
            )

    # Inner vertical/angled core filler cards so the spruce crown is opaque and dense from every angle
    for z_core, rad_c, len_c in [(0.42, 0.18, 0.44), (0.76, 0.14, 0.38), (1.10, 0.09, 0.32)]:
        for k in range(4):
            yaw = k * (math.pi * 0.5) + z_core * 2.1
            add_curved_bough_card(
                bm, uv_layer, col_layer,
                origin=Vector((0.0, 0.0, z_core)),
                yaw=yaw,
                pitch=math.radians(52.0),
                roll=math.radians(rng.uniform(-15.0, 15.0)),
                length=len_c,
                width=rad_c * 2.1,
                droop=0.03,
                cup=0.04,
                mat_idx=1,
                ao_base=0.42,
                ao_tip=0.78,
            )

    # Vertical crossed spire cards at the very tip (makes silhouette crisp from both side & top-down!)
    for k in range(4):
        yaw = k * (math.pi / 4.0) + 0.2
        add_curved_bough_card(
            bm, uv_layer, col_layer,
            origin=Vector((0.0, 0.0, 1.50)),
            yaw=yaw,
            pitch=math.radians(82.0),
            roll=0.0,
            length=0.32,
            width=0.28,
            droop=0.01,
            cup=0.02,
            mat_idx=1,
            ao_base=0.84,
            ao_tip=1.0,
        )

    bm.to_mesh(mesh)
    bm.free()
    apply_radial_foliage_normals(obj, Vector((0.0, 0.0, 0.85)), blend=0.82)
    export_glb(obj, "tree_alpine_spruce_lod0.glb")


def build_oak_lod0():
    """European temperate oak/beech: rooted trunk + 4 forked limbs + lush alpha-cutout broadleaf crown."""
    clear_scene()
    rng = random.Random(5102)

    mesh = bpy.data.meshes.new("TemperateOakLOD0")
    obj = bpy.data.objects.new("TemperateOakLOD0", mesh)
    bpy.context.collection.objects.link(obj)

    mat_bark = make_material("Bark", (0.30, 0.21, 0.13, 1.0))
    mat_fol = make_material("Foliage", (0.26, 0.42, 0.19, 1.0))
    obj.data.materials.append(mat_bark)
    obj.data.materials.append(mat_fol)

    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    col_layer = bm.loops.layers.color.new("Col")

    # Rooted trunk with flared base
    trunk_pts = [
        (Vector((0.0, 0.0, -0.45)), 0.17),
        (Vector((0.0, 0.0,  0.04)), 0.135),
        (Vector((0.01, -0.01, 0.36)), 0.105),
        (Vector((0.0, 0.01, 0.68)), 0.082),
    ]
    add_tapered_limb(bm, uv_layer, col_layer, trunk_pts, segs=8, mat_idx=0)

    # 4 primary forked limbs radiating into the canopy
    limbs = [
        [Vector((0.0, 0.0, 0.58)), Vector((0.18, 0.10, 0.84)), Vector((0.30, 0.16, 1.02))],
        [Vector((0.0, 0.0, 0.56)), Vector((-0.18, 0.12, 0.82)), Vector((-0.28, 0.20, 1.00))],
        [Vector((0.0, 0.0, 0.60)), Vector((0.08, -0.20, 0.84)), Vector((0.14, -0.32, 0.98))],
        [Vector((0.0, 0.0, 0.64)), Vector((-0.10, -0.14, 0.92)), Vector((-0.14, -0.20, 1.12))],
    ]
    for pts in limbs:
        limb_rad = [(pts[0], 0.068), (pts[1], 0.045), (pts[2], 0.022)]
        add_tapered_limb(bm, uv_layer, col_layer, limb_rad, segs=6, mat_idx=0)

    # Multi-layered dome of broadleaf bough cards (horizontal, angled, and vertical cards for fullness from every angle)
    crown_center = Vector((0.0, 0.0, 0.96))
    # Lower skirt ring (10 outward cards)
    for k in range(10):
        yaw = (2.0 * math.pi * k / 10.0) + rng.uniform(-0.18, 0.18)
        pitch = math.radians(rng.uniform(-12.0, 14.0))
        roll = math.radians(rng.uniform(-24.0, 24.0))
        orig = Vector((math.cos(yaw) * 0.12, math.sin(yaw) * 0.12, 0.72 + rng.uniform(-0.06, 0.08)))
        add_curved_bough_card(
            bm, uv_layer, col_layer,
            origin=orig, yaw=yaw, pitch=pitch, roll=roll,
            length=0.52 * rng.uniform(0.88, 1.12),
            width=0.46 * rng.uniform(0.88, 1.12),
            droop=0.10, cup=0.07, mat_idx=1, ao_base=0.56, ao_tip=0.94,
        )

    # Mid canopy ring (12 tilted outward & upward cards)
    for k in range(12):
        yaw = (2.0 * math.pi * k / 12.0) + 0.25 + rng.uniform(-0.20, 0.20)
        pitch = math.radians(rng.uniform(14.0, 42.0))
        roll = math.radians(rng.uniform(-30.0, 30.0))
        orig = Vector((math.cos(yaw) * 0.10, math.sin(yaw) * 0.10, 0.88 + rng.uniform(-0.06, 0.08)))
        add_curved_bough_card(
            bm, uv_layer, col_layer,
            origin=orig, yaw=yaw, pitch=pitch, roll=roll,
            length=0.50 * rng.uniform(0.88, 1.12),
            width=0.46 * rng.uniform(0.88, 1.12),
            droop=0.08, cup=0.07, mat_idx=1, ao_base=0.66, ao_tip=0.98,
        )

    # Upper crown cap (8 spreading cards + 6 steeper filler cards so top-down view is lush & solid!)
    for k in range(8):
        yaw = (2.0 * math.pi * k / 8.0) + 0.4 + rng.uniform(-0.22, 0.22)
        pitch = math.radians(rng.uniform(32.0, 62.0))
        roll = math.radians(rng.uniform(-25.0, 25.0))
        orig = Vector((math.cos(yaw) * 0.05, math.sin(yaw) * 0.05, 1.04 + rng.uniform(-0.04, 0.05)))
        add_curved_bough_card(
            bm, uv_layer, col_layer,
            origin=orig, yaw=yaw, pitch=pitch, roll=roll,
            length=0.40 * rng.uniform(0.88, 1.12),
            width=0.40 * rng.uniform(0.88, 1.12),
            droop=0.06, cup=0.06, mat_idx=1, ao_base=0.76, ao_tip=1.0,
        )

    for k in range(6):
        yaw = (2.0 * math.pi * k / 6.0) + 0.15
        pitch = math.radians(rng.uniform(60.0, 78.0))
        roll = math.radians(rng.uniform(-20.0, 20.0))
        orig = Vector((rng.uniform(-0.10, 0.10), rng.uniform(-0.10, 0.10), 0.94))
        add_curved_bough_card(
            bm, uv_layer, col_layer,
            origin=orig, yaw=yaw, pitch=pitch, roll=roll,
            length=0.42, width=0.38,
            droop=0.04, cup=0.05, mat_idx=1, ao_base=0.72, ao_tip=1.0,
        )

    bm.to_mesh(mesh)
    bm.free()
    apply_radial_foliage_normals(obj, crown_center, blend=0.84)
    export_glb(obj, "tree_temperate_oak_lod0.glb")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("Generating Blender LOD0 alpha-cutout trees in", OUT_DIR)
    build_spruce_lod0()
    build_oak_lod0()
    print("Done!")


if __name__ == "__main__":
    main()
