#!/usr/bin/env python3
"""
Headless Blender 5.2+ procedural generator for UV-mapped European 3D building archetypes in Raildev 3D.

Run via:
    blender --background --python tools/blender_generate_buildings.py

Generates 5 clean, UV-unwrapped glTF 2.0 (.glb) building archetypes with:
  - Deep buried stone foundation plinths (z = -0.45 in Blender Z-up -> y = -0.45 in Godot Y-up)
  - Recessed 3D window bays with stone sills, roof eaves overhangs, dormers, chimneys & cornices
  - Clean 0..1 box-mapped UVs on every wall, roof slope & plinth (ready for 2x2 AI facade atlas!)
  - Semantic vertex colors (walls, roofs, dark glass windows, timber/balconies, stone plinth)
"""

import math
import os
import bpy
import bmesh
from mathutils import Vector

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "godot", "assets", "models")


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def make_material(name: str) -> bpy.types.Material:
    mat = bpy.data.materials.new(name=name)
    # Wire Vertex Color ("Col") -> Principled BSDF Base Color so glTF 2.0 ALWAYS exports COLOR_0!
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    vcol = nodes.new("ShaderNodeVertexColor")
    vcol.layer_name = "Col"
    if bsdf:
        links.new(vcol.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def add_uv_box(
    bm: bmesh.types.BMesh,
    uv_layer,
    col_layer,
    cx: float,
    cy: float,
    cz: float,
    sx: float,
    sy: float,
    sz: float,
    color: tuple,
    top_color: tuple = None,
    uv_scale: float = 1.0,
):
    """Add an axis-aligned box with clean world-proportioned UVs (u along width, v along height Z)."""
    hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    x0, x1 = cx - hx, cx + hx
    y0, y1 = cy - hy, cy + hy
    z0, z1 = cz - hz, cz + hz
    tc = top_color if top_color else color

    # 8 corners (Blender Z-up)
    v000 = bm.verts.new((x0, y0, z0))
    v100 = bm.verts.new((x1, y0, z0))
    v110 = bm.verts.new((x1, y1, z0))
    v010 = bm.verts.new((x0, y1, z0))
    v001 = bm.verts.new((x0, y0, z1))
    v101 = bm.verts.new((x1, y0, z1))
    v111 = bm.verts.new((x1, y1, z1))
    v011 = bm.verts.new((x0, y1, z1))

    # (verts, uv_w, uv_h, col)
    faces = [
        ((v000, v100, v101, v001), sx, sz, color),  # -Y front
        ((v110, v010, v011, v111), sx, sz, color),  # +Y back
        ((v100, v110, v111, v101), sy, sz, color),  # +X right
        ((v010, v000, v001, v011), sy, sz, color),  # -X left
        ((v001, v101, v111, v011), sx, sy, tc),     # +Z top
    ]
    for fverts, uw, uh, col in faces:
        try:
            f = bm.faces.new(fverts)
            f.smooth = False
            u_max = max(0.25, uw * uv_scale)
            v_max = max(0.25, uh * uv_scale)
            uvs = [(0.0, 0.0), (u_max, 0.0), (u_max, v_max), (0.0, v_max)]
            for loop, uv in zip(f.loops, uvs):
                loop[uv_layer].uv = uv
                loop[col_layer] = (col[0], col[1], col[2], 1.0)
        except ValueError:
            pass


def add_gable_roof(
    bm: bmesh.types.BMesh,
    uv_layer,
    col_layer,
    cx: float,
    cy: float,
    base_z: float,
    sx: float,
    sy: float,
    roof_h: float,
    roof_col: tuple,
    gable_col: tuple,
    overhang: float = 0.08,
    ridge_along_x: bool = True,
):
    """Pitched gable roof with eaves overhang, soffit underside, and UV-mapped slopes."""
    hx = sx * 0.5 + overhang
    hy = sy * 0.5 + overhang
    top_z = base_z + roof_h

    if ridge_along_x:
        fl = bm.verts.new((cx - hx, cy - hy, base_z))
        fr = bm.verts.new((cx + hx, cy - hy, base_z))
        bl = bm.verts.new((cx - hx, cy + hy, base_z))
        br = bm.verts.new((cx + hx, cy + hy, base_z))
        rl = bm.verts.new((cx - hx, cy, top_z))
        rr = bm.verts.new((cx + hx, cy, top_z))
        slope_len = math.sqrt(hy * hy + roof_h * roof_h)
        # Front & back roof slopes
        for fv in ((fl, fr, rr, rl), (br, bl, rl, rr)):
            f = bm.faces.new(fv)
            for loop, uv in zip(f.loops, [(0.0, 0.0), (hx * 2.0, 0.0), (hx * 2.0, slope_len), (0.0, slope_len)]):
                loop[uv_layer].uv = uv
                loop[col_layer] = (roof_col[0], roof_col[1], roof_col[2], 1.0)
        # Left & right gable end triangles (flush with walls, inset slightly from overhang)
        gx0, gx1 = cx - sx * 0.5, cx + sx * 0.5
        gy0, gy1 = cy - sy * 0.5, cy + sy * 0.5
        gfl = bm.verts.new((gx0, gy0, base_z))
        gbl = bm.verts.new((gx0, gy1, base_z))
        grl = bm.verts.new((gx0, cy, top_z - 0.01))
        gfr = bm.verts.new((gx1, gy0, base_z))
        gbr = bm.verts.new((gx1, gy1, base_z))
        grr = bm.verts.new((gx1, cy, top_z - 0.01))
        for fv in ((gbl, gfl, grl), (gfr, gbr, grr)):
            f = bm.faces.new(fv)
            for loop, uv in zip(f.loops, [(0.0, 0.0), (sy, 0.0), (sy * 0.5, roof_h)]):
                loop[uv_layer].uv = uv
                loop[col_layer] = (gable_col[0], gable_col[1], gable_col[2], 1.0)
    else:
        fl = bm.verts.new((cx - hx, cy - hy, base_z))
        fr = bm.verts.new((cx + hx, cy - hy, base_z))
        bl = bm.verts.new((cx - hx, cy + hy, base_z))
        br = bm.verts.new((cx + hx, cy + hy, base_z))
        rf = bm.verts.new((cx, cy - hy, top_z))
        rb = bm.verts.new((cx, cy + hy, top_z))
        slope_len = math.sqrt(hx * hx + roof_h * roof_h)
        for fv in ((fl, rf, rb, bl), (br, rb, rf, fr)):
            f = bm.faces.new(fv)
            for loop, uv in zip(f.loops, [(0.0, 0.0), (slope_len, 0.0), (slope_len, hy * 2.0), (0.0, hy * 2.0)]):
                loop[uv_layer].uv = uv
                loop[col_layer] = (roof_col[0], roof_col[1], roof_col[2], 1.0)
        gx0, gx1 = cx - sx * 0.5, cx + sx * 0.5
        gy0, gy1 = cy - sy * 0.5, cy + sy * 0.5
        gfl = bm.verts.new((gx0, gy0, base_z))
        gfr = bm.verts.new((gx1, gy0, base_z))
        grf = bm.verts.new((cx, gy0, top_z - 0.01))
        gbl = bm.verts.new((gx0, gy1, base_z))
        gbr = bm.verts.new((gx1, gy1, base_z))
        grb = bm.verts.new((cx, gy1, top_z - 0.01))
        for fv in ((gfl, gfr, grf), (gbr, gbl, grb)):
            f = bm.faces.new(fv)
            for loop, uv in zip(f.loops, [(0.0, 0.0), (sx, 0.0), (sx * 0.5, roof_h)]):
                loop[uv_layer].uv = uv
                loop[col_layer] = (gable_col[0], gable_col[1], gable_col[2], 1.0)


def add_hip_roof(
    bm: bmesh.types.BMesh,
    uv_layer,
    col_layer,
    cx: float,
    cy: float,
    base_z: float,
    sx: float,
    sy: float,
    roof_h: float,
    roof_col: tuple,
    ridge_frac: float = 0.55,
    overhang: float = 0.06,
):
    """Hipped / Mansard roof with 4 sloped planes & UV mapping."""
    hx = sx * 0.5 + overhang
    hy = sy * 0.5 + overhang
    rhx = hx * ridge_frac
    top_z = base_z + roof_h

    fl = bm.verts.new((cx - hx, cy - hy, base_z))
    fr = bm.verts.new((cx + hx, cy - hy, base_z))
    br = bm.verts.new((cx + hx, cy + hy, base_z))
    bl = bm.verts.new((cx - hx, cy + hy, base_z))
    rl = bm.verts.new((cx - rhx, cy, top_z))
    rr = bm.verts.new((cx + rhx, cy, top_z))

    quads = [(fl, fr, rr, rl), (br, bl, rl, rr)]
    tris = [(fr, br, rr), (bl, fl, rl)]
    for fv in quads:
        f = bm.faces.new(fv)
        for loop, uv in zip(f.loops, [(0.0, 0.0), (sx, 0.0), (sx * 0.8, roof_h * 1.4), (sx * 0.2, roof_h * 1.4)]):
            loop[uv_layer].uv = uv
            loop[col_layer] = (roof_col[0], roof_col[1], roof_col[2], 1.0)
    for fv in tris:
        f = bm.faces.new(fv)
        for loop, uv in zip(f.loops, [(0.0, 0.0), (sy, 0.0), (sy * 0.5, roof_h * 1.4)]):
            loop[uv_layer].uv = uv
            loop[col_layer] = (roof_col[0], roof_col[1], roof_col[2], 1.0)


def add_window_bay(
    bm: bmesh.types.BMesh,
    uv_layer,
    col_layer,
    wx: float,
    wy: float,
    wz: float,
    w: float,
    h: float,
    facing: str,
    win_col=(0.11, 0.14, 0.19),
    sill_col=(0.62, 0.58, 0.52),
):
    """Add a 3D framed window with protruding stone sill & dark reflective glass pane."""
    if facing in ("-Y", "+Y"):
        sign = -1.0 if facing == "-Y" else 1.0
        # Dark recessed glass pane
        add_uv_box(bm, uv_layer, col_layer, wx, wy + sign * 0.012, wz, w, 0.026, h, win_col)
        # Protruding stone window sill
        add_uv_box(bm, uv_layer, col_layer, wx, wy + sign * 0.028, wz - h * 0.5 - 0.015, w + 0.04, 0.05, 0.03, sill_col)
        # Top stone lintel
        add_uv_box(bm, uv_layer, col_layer, wx, wy + sign * 0.020, wz + h * 0.5 + 0.014, w + 0.03, 0.035, 0.025, sill_col)
    else:
        sign = -1.0 if facing == "-X" else 1.0
        add_uv_box(bm, uv_layer, col_layer, wx + sign * 0.012, wy, wz, 0.026, w, h, win_col)
        add_uv_box(bm, uv_layer, col_layer, wx + sign * 0.028, wy, wz - h * 0.5 - 0.015, 0.05, w + 0.04, 0.03, sill_col)
        add_uv_box(bm, uv_layer, col_layer, wx + sign * 0.020, wy, wz + h * 0.5 + 0.014, 0.035, w + 0.03, 0.025, sill_col)


def add_dormer(bm, uv_layer, col_layer, cx, cy, cz, w, d, h, wall_col, roof_col, facing="-Y"):
    """Small projecting roof dormer with mini gable roof & window."""
    add_uv_box(bm, uv_layer, col_layer, cx, cy, cz, w, d, h, wall_col)
    add_gable_roof(bm, uv_layer, col_layer, cx, cy, cz + h * 0.5, w, d, h * 0.55, roof_col, wall_col, overhang=0.025, ridge_along_x=False)
    sign = -1.0 if facing == "-Y" else 1.0
    add_uv_box(bm, uv_layer, col_layer, cx, cy + sign * (d * 0.5 + 0.008), cz, w * 0.52, 0.02, h * 0.58, (0.11, 0.14, 0.19))


def finalize_and_export(name: str, bm: bmesh.types.BMesh, filename: str):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(make_material("UrbanMat"))
    bm.to_mesh(mesh)
    bm.free()
    if mesh.color_attributes:
        mesh.color_attributes.active_color_index = 0
        mesh.color_attributes.render_color_index = 0

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
        export_vertex_color='ACTIVE',
        export_materials='EXPORT',
    )
    print(f"  [blender] exported {filename} ({len(mesh.polygons)} polys, {len(mesh.vertices)} verts)")


def build_north_townhouse():
    clear_scene()
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    col = bm.loops.layers.color.new("Col")

    stone = (0.46, 0.44, 0.40)
    wall  = (0.82, 0.78, 0.70)
    trim  = (0.64, 0.60, 0.54)
    roof  = (0.60, 0.27, 0.19)
    chim  = (0.48, 0.28, 0.21)

    # Buried stone plinth (z = -0.45 .. +0.12)
    add_uv_box(bm, uv, col, 0.0, 0.0, -0.165, 1.04, 0.78, 0.57, stone)
    # Main 2-story plastered facade + mid belt cornice + eaves cornice
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.50, 0.98, 0.72, 0.76, wall)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.48, 1.01, 0.75, 0.035, trim)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.87, 1.03, 0.77, 0.05, trim)

    # Recessed 3D windows with stone sills & lintels (front & back, 2 floors x 3 bays)
    for y_face, facing in ((-0.36, "-Y"), (0.36, "+Y")):
        for wz in (0.32, 0.66):
            for wx in (-0.28, 0.0, 0.28):
                add_window_bay(bm, uv, col, wx, y_face, wz, 0.13, 0.18, facing)
    # Side gable attic windows
    for x_face, facing in ((-0.49, "-X"), (0.49, "+X")):
        add_window_bay(bm, uv, col, x_face, 0.0, 1.04, 0.12, 0.15, facing)

    # Steep Central European gable roof + central dormer + brick chimney
    add_gable_roof(bm, uv, col, 0.0, 0.0, 0.89, 0.98, 0.72, 0.54, roof, wall, overhang=0.08)
    add_dormer(bm, uv, col, 0.0, -0.22, 1.12, 0.22, 0.24, 0.20, wall, roof, facing="-Y")
    add_uv_box(bm, uv, col, 0.28, 0.14, 1.32, 0.13, 0.13, 0.34, chim)

    finalize_and_export("NorthTownhouse", bm, "bldg_north_townhouse.glb")


def build_north_mansard():
    clear_scene()
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    col = bm.loops.layers.color.new("Col")

    stone = (0.50, 0.48, 0.44)
    wall  = (0.80, 0.77, 0.70)
    trim  = (0.64, 0.61, 0.55)
    slate = (0.25, 0.29, 0.35)
    chim  = (0.52, 0.46, 0.40)

    # Buried rusticated ground base (z = -0.45 .. +0.24)
    add_uv_box(bm, uv, col, 0.0, 0.0, -0.105, 1.14, 0.94, 0.69, stone)
    # 3-story Gründerzeit / Haussmann facade + belt courses + crown cornice
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.64, 1.08, 0.88, 0.84, wall)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.25, 1.12, 0.92, 0.04, trim)
    add_uv_box(bm, uv, col, 0.0, 0.0, 1.05, 1.14, 0.94, 0.06, trim)

    # Front & back 3D windows (3 floors x 3 bays)
    for y_face, facing in ((-0.44, "-Y"), (0.44, "+Y")):
        for wz in (0.40, 0.68, 0.92):
            for wx in (-0.32, 0.0, 0.32):
                add_window_bay(bm, uv, col, wx, y_face, wz, 0.14, 0.16, facing)
    # Side 3D windows (2 bays)
    for x_face, facing in ((-0.54, "-X"), (0.54, "+X")):
        for wz in (0.44, 0.82):
            for wy in (-0.20, 0.20):
                add_window_bay(bm, uv, col, x_face, wy, wz, 0.14, 0.16, facing)

    # Mansard hip slate roof + 2 front dormers + twin chimneys
    add_hip_roof(bm, uv, col, 0.0, 0.0, 1.08, 1.08, 0.88, 0.38, slate, ridge_frac=0.64, overhang=0.06)
    add_dormer(bm, uv, col, -0.24, -0.34, 1.23, 0.19, 0.22, 0.18, wall, slate, facing="-Y")
    add_dormer(bm, uv, col,  0.24, -0.34, 1.23, 0.19, 0.22, 0.18, wall, slate, facing="-Y")
    add_uv_box(bm, uv, col, -0.30, -0.16, 1.48, 0.12, 0.12, 0.24, chim)
    add_uv_box(bm, uv, col,  0.30,  0.16, 1.48, 0.12, 0.12, 0.24, chim)

    finalize_and_export("NorthMansard", bm, "bldg_north_mansard.glb")


def build_med_villa():
    clear_scene()
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    col = bm.loops.layers.color.new("Col")

    plinth = (0.54, 0.48, 0.40)
    ochre  = (0.78, 0.68, 0.52)
    terra  = (0.60, 0.33, 0.22)
    trim   = (0.66, 0.58, 0.46)

    # Main wing + buried stone plinth
    add_uv_box(bm, uv, col, 0.0, 0.0, -0.16, 1.10, 0.78, 0.58, plinth)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.44, 1.04, 0.72, 0.64, ochre)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.75, 1.08, 0.76, 0.04, trim)
    for y_face, facing in ((-0.36, "-Y"), (0.36, "+Y")):
        for wx in (-0.28, 0.0, 0.28):
            add_window_bay(bm, uv, col, wx, y_face, 0.48, 0.13, 0.18, facing)
    add_hip_roof(bm, uv, col, 0.0, 0.0, 0.77, 1.04, 0.72, 0.28, terra, ridge_frac=0.56, overhang=0.08)

    # Stepped side wing
    add_uv_box(bm, uv, col, 0.34, -0.44, -0.18, 0.48, 0.48, 0.54, plinth)
    add_uv_box(bm, uv, col, 0.34, -0.44, 0.34, 0.44, 0.44, 0.54, ochre)
    add_window_bay(bm, uv, col, 0.34, -0.66, 0.38, 0.13, 0.16, "-Y")
    add_hip_roof(bm, uv, col, 0.34, -0.44, 0.61, 0.44, 0.44, 0.19, terra, ridge_frac=0.35, overhang=0.06)

    finalize_and_export("MedVilla", bm, "bldg_med_villa.glb")


def build_alpine_chalet():
    """Bavarian / Tyrolean Alpine chalet with stone base, whitewashed lower floor, timber upper floor & balcony."""
    clear_scene()
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    col = bm.loops.layers.color.new("Col")

    stone  = (0.48, 0.46, 0.42)
    white  = (0.86, 0.84, 0.78)
    timber = (0.36, 0.24, 0.15)
    roof   = (0.34, 0.24, 0.19)
    chim   = (0.52, 0.48, 0.44)

    # Deep buried Alpine stone base (z = -0.45 .. +0.16)
    add_uv_box(bm, uv, col, 0.0, 0.0, -0.145, 1.12, 0.90, 0.61, stone)
    # Whitewashed ground floor
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.34, 1.06, 0.84, 0.38, white)
    # Dark Alpine timber upper floor
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.68, 1.08, 0.86, 0.32, timber)
    # Projecting wooden balcony deck + railing on front gable (-Y)
    add_uv_box(bm, uv, col, 0.0, -0.50, 0.53, 1.02, 0.16, 0.04, timber)
    add_uv_box(bm, uv, col, 0.0, -0.57, 0.62, 1.02, 0.03, 0.14, timber)
    add_uv_box(bm, uv, col, -0.50, -0.50, 0.62, 0.03, 0.16, 0.14, timber)
    add_uv_box(bm, uv, col,  0.50, -0.50, 0.62, 0.03, 0.16, 0.14, timber)

    # Windows on ground & upper floor
    for y_face, facing in ((-0.42, "-Y"), (0.42, "+Y")):
        for wx in (-0.28, 0.0, 0.28):
            add_window_bay(bm, uv, col, wx, y_face, 0.35, 0.13, 0.15, facing)
            add_window_bay(bm, uv, col, wx, y_face, 0.68, 0.12, 0.14, facing)

    # Wide low-pitched overhanging Alpine gable roof (ridge along Y so balcony sits under gable!)
    add_gable_roof(bm, uv, col, 0.0, 0.0, 0.84, 1.08, 0.86, 0.36, roof, timber, overhang=0.16, ridge_along_x=False)
    add_uv_box(bm, uv, col, 0.22, 0.16, 1.18, 0.13, 0.13, 0.28, chim)

    finalize_and_export("AlpineChalet", bm, "bldg_alpine_chalet.glb")


def build_corner_block():
    """L-shaped 3-story European corner city block (breaks up rectangular grids in city cores!)."""
    clear_scene()
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    col = bm.loops.layers.color.new("Col")

    stone = (0.48, 0.46, 0.42)
    wall  = (0.80, 0.75, 0.67)
    trim  = (0.64, 0.60, 0.54)
    roof  = (0.56, 0.26, 0.20)
    chim  = (0.48, 0.30, 0.23)

    # Wing A (along X: -0.62..+0.62, Y: -0.48..+0.12)
    add_uv_box(bm, uv, col, 0.0, -0.18, -0.14, 1.28, 0.64, 0.62, stone)
    add_uv_box(bm, uv, col, 0.0, -0.18, 0.58, 1.22, 0.58, 0.84, wall)
    add_uv_box(bm, uv, col, 0.0, -0.18, 0.99, 1.26, 0.62, 0.05, trim)
    add_gable_roof(bm, uv, col, 0.0, -0.18, 1.01, 1.22, 0.58, 0.42, roof, wall, overhang=0.06, ridge_along_x=True)

    # Wing B (along Y: -0.48..+0.66, X: -0.62..-0.02)
    add_uv_box(bm, uv, col, -0.32, 0.10, -0.14, 0.64, 1.18, 0.62, stone)
    add_uv_box(bm, uv, col, -0.32, 0.10, 0.58, 0.58, 1.12, 0.84, wall)
    add_uv_box(bm, uv, col, -0.32, 0.10, 0.99, 0.62, 1.16, 0.05, trim)
    add_gable_roof(bm, uv, col, -0.32, 0.10, 1.01, 0.58, 1.12, 0.42, roof, wall, overhang=0.06, ridge_along_x=False)

    # Windows on front (-Y) and left (-X) street facades
    for wz in (0.36, 0.64, 0.86):
        for wx in (-0.42, -0.14, 0.14, 0.42):
            add_window_bay(bm, uv, col, wx, -0.47, wz, 0.12, 0.15, "-Y")
        for wy in (-0.28, 0.02, 0.30, 0.52):
            add_window_bay(bm, uv, col, -0.61, wy, wz, 0.12, 0.15, "-X")

    add_uv_box(bm, uv, col, -0.28, -0.14, 1.44, 0.13, 0.13, 0.26, chim)
    add_uv_box(bm, uv, col,  0.34, -0.16, 1.40, 0.12, 0.12, 0.24, chim)

    finalize_and_export("CornerBlock", bm, "bldg_corner_block.glb")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("Generating Blender UV-mapped European buildings in", OUT_DIR)
    build_north_townhouse()
    build_north_mansard()
    build_med_villa()
    build_alpine_chalet()
    build_corner_block()
    print("Done!")


if __name__ == "__main__":
    main()
