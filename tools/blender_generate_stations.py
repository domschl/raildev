#!/usr/bin/env python3
"""
Headless Blender 5.1+ procedural generator for UV-mapped 19th-century Central European
railway stations in Raildev 3D:
  - godot/assets/models/rail_station.glb        (1-track through station)
  - godot/assets/models/rail_station_2track.glb (2-track passing station with island platform)

Coordinate convention:
  Blender Z-up -> glTF Y-up (export_yup=True): (X, Y, Z) -> (X, Z, -Y)
  - Tracks run along X (x = -1.25 .. +1.25)
  - Height is Blender Z (buried stone foundation down to z = -0.35 so stations never float)
  - Headhouse sits on Blender -Y -> Godot +Z (matching UrbanStreamer forecourt plazas)
"""

import math
import os
import bpy
import bmesh

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "godot", "assets", "models")

# Semantic vertex-color palette recognized by rail_pbr.gdshader (asset_mode == 2):
COL_APRON    = (0.34, 0.32, 0.30)  # Ground stone apron (cobble)
COL_PLATFORM = (0.56, 0.54, 0.50)  # Stone-paved passenger platforms (cobble)
COL_COPING   = (0.72, 0.69, 0.63)  # Pale dressed granite platform edge
COL_BALLAST  = (0.26, 0.25, 0.24)  # Crushed granite trackbed
COL_RAIL     = (0.34, 0.37, 0.42)  # Gleaming steel rails
COL_BRICK    = (0.72, 0.40, 0.32)  # Bavarian / Gründerzeit brick headhouse (triggers brick atlas)
COL_STONE    = (0.76, 0.72, 0.64)  # Dressed ashlar limestone/sandstone plinth, quoins, clock tower
COL_ROOF     = (0.54, 0.24, 0.18)  # Terracotta/slate tiled hip roof (triggers tex_roof)
COL_SLATE    = (0.24, 0.27, 0.33)  # Dark slate canopy eaves & spire base
COL_GLASS    = (0.18, 0.27, 0.34)  # Dark smoked Victorian skylight glass (triggers glass + mullions)
COL_IRON     = (0.15, 0.17, 0.19)  # Cast-iron trusses, columns, ridge lantern
COL_COPPER   = (0.28, 0.48, 0.42)  # Patinated verdigris copper clock spire
COL_WIN      = (0.09, 0.11, 0.15)  # Recessed dark headhouse window glazing
COL_CLOCK    = (0.86, 0.83, 0.74)  # Cream illuminated station clock face
COL_BENCH    = (0.34, 0.22, 0.14)  # Wooden platform benches


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def make_material(name: str) -> bpy.types.Material:
    mat = bpy.data.materials.new(name=name)
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    vcol = nodes.new("ShaderNodeVertexColor")
    vcol.layer_name = "Col"
    if bsdf:
        links.new(vcol.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def add_uv_box(bm, uv_layer, col_layer, cx, cy, cz, sx, sy, sz, color, top_color=None, uv_scale=1.0):
    hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    x0, x1 = cx - hx, cx + hx
    y0, y1 = cy - hy, cy + hy
    z0, z1 = cz - hz, cz + hz
    tc = top_color if top_color else color

    v000 = bm.verts.new((x0, y0, z0))
    v100 = bm.verts.new((x1, y0, z0))
    v110 = bm.verts.new((x1, y1, z0))
    v010 = bm.verts.new((x0, y1, z0))
    v001 = bm.verts.new((x0, y0, z1))
    v101 = bm.verts.new((x1, y0, z1))
    v111 = bm.verts.new((x1, y1, z1))
    v011 = bm.verts.new((x0, y1, z1))

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
            u_max = max(0.20, uw * uv_scale)
            v_max = max(0.20, uh * uv_scale)
            for loop, uv in zip(f.loops, [(0.0, 0.0), (u_max, 0.0), (u_max, v_max), (0.0, v_max)]):
                loop[uv_layer].uv = uv
                loop[col_layer] = (col[0], col[1], col[2], 1.0)
        except ValueError:
            pass


def add_quad_uv(bm, uv_layer, col_layer, p0, p1, p2, p3, col, u_max=1.0, v_max=1.0):
    verts = [bm.verts.new(p) for p in (p0, p1, p2, p3)]
    try:
        f = bm.faces.new(verts)
        f.smooth = False
        for loop, uv in zip(f.loops, [(0.0, 0.0), (u_max, 0.0), (u_max, v_max), (0.0, v_max)]):
            loop[uv_layer].uv = uv
            loop[col_layer] = (col[0], col[1], col[2], 1.0)
    except ValueError:
        pass


def add_hip_roof(bm, uv_layer, col_layer, cx, cy, base_z, sx, sy, roof_h, roof_col, ridge_frac=0.64, overhang=0.07):
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

    for fv in ((fl, fr, rr, rl), (br, bl, rl, rr)):
        f = bm.faces.new(fv)
        for loop, uv in zip(f.loops, [(0.0, 0.0), (sx, 0.0), (sx * 0.8, roof_h * 1.6), (sx * 0.2, roof_h * 1.6)]):
            loop[uv_layer].uv = uv
            loop[col_layer] = (roof_col[0], roof_col[1], roof_col[2], 1.0)
    for fv in ((fr, br, rr), (bl, fl, rl)):
        f = bm.faces.new(fv)
        for loop, uv in zip(f.loops, [(0.0, 0.0), (sy, 0.0), (sy * 0.5, roof_h * 1.6)]):
            loop[uv_layer].uv = uv
            loop[col_layer] = (roof_col[0], roof_col[1], roof_col[2], 1.0)


def add_pyramid_spire(bm, uv_layer, col_layer, cx, cy, base_z, half_w, height, col):
    v0 = bm.verts.new((cx - half_w, cy - half_w, base_z))
    v1 = bm.verts.new((cx + half_w, cy - half_w, base_z))
    v2 = bm.verts.new((cx + half_w, cy + half_w, base_z))
    v3 = bm.verts.new((cx - half_w, cy + half_w, base_z))
    vt = bm.verts.new((cx, cy, base_z + height))
    for tri in ((v0, v1, vt), (v1, v2, vt), (v2, v3, vt), (v3, v0, vt)):
        f = bm.faces.new(tri)
        for loop, uv in zip(f.loops, [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)]):
            loop[uv_layer].uv = uv
            loop[col_layer] = (col[0], col[1], col[2], 1.0)


def add_window_bay(bm, uv_layer, col_layer, wx, wy, wz, w, h, facing="-Y"):
    sign = -1.0 if facing == "-Y" else 1.0
    add_uv_box(bm, uv_layer, col_layer, wx, wy + sign * 0.010, wz, w, 0.024, h, COL_WIN)
    add_uv_box(bm, uv_layer, col_layer, wx, wy + sign * 0.026, wz - h * 0.5 - 0.014, w + 0.036, 0.044, 0.026, COL_STONE)
    add_uv_box(bm, uv_layer, col_layer, wx, wy + sign * 0.020, wz + h * 0.5 + 0.016, w + 0.034, 0.034, 0.028, COL_STONE)


def add_train_shed(bm, uv_layer, col_layer, shed_half_x, arch_r, arch_base_z, arch_h, num_bays=5, arch_segs=8):
    """Victorian arched cast-iron & dark smoked-glass barrel-vault train shed."""
    x0, x1 = -shed_half_x, shed_half_x
    shed_len = x1 - x0

    # Curved barrel vault (outer side eaves = dark slate, upper vault = smoked skylight glass)
    for i in range(arch_segs):
        a0 = math.pi * (0.08 + 0.84 * i / arch_segs)
        a1 = math.pi * (0.08 + 0.84 * (i + 1) / arch_segs)
        y0, z0 = math.cos(a0) * arch_r, arch_base_z + math.sin(a0) * arch_h
        y1, z1 = math.cos(a1) * arch_r, arch_base_z + math.sin(a1) * arch_h
        is_eave = (i == 0 or i == arch_segs - 1)
        seg_col = COL_SLATE if is_eave else COL_GLASS
        # Outer surface (facing up/out)
        add_quad_uv(bm, uv_layer, col_layer, (x0, y0, z0), (x1, y0, z0), (x1, y1, z1), (x0, y1, z1), seg_col, shed_len * 2.0, 1.0)
        # Underside so shed looks solid from low track-level views
        add_quad_uv(bm, uv_layer, col_layer, (x0, y1, z1 - 0.012), (x1, y1, z1 - 0.012), (x1, y0, z0 - 0.012), (x0, y0, z0 - 0.012), COL_IRON, shed_len, 1.0)
        # Longitudinal cast-iron purlin bar between skylight segments
        if i > 0:
            add_uv_box(bm, uv_layer, col_layer, 0.0, y0, z0 + 0.012, shed_len + 0.02, 0.024, 0.024, COL_IRON)

    # Raised clerestory ventilation lantern along the crest
    crest_z = arch_base_z + arch_h
    add_uv_box(bm, uv_layer, col_layer, 0.0, 0.0, crest_z + 0.032, shed_len * 0.94, 0.14, 0.055, COL_IRON)
    add_uv_box(bm, uv_layer, col_layer, 0.0, 0.0, crest_z + 0.068, shed_len * 0.98, 0.20, 0.024, COL_SLATE)

    # Cast-iron columns & external arch ribs across structural bays
    col_y = arch_r * 0.94
    col_h = arch_base_z + 0.14
    for bi in range(num_bays):
        bx = x0 + (x1 - x0) * (bi / max(1, num_bays - 1))
        add_uv_box(bm, uv_layer, col_layer, bx,  col_y, col_h * 0.5, 0.044, 0.044, col_h, COL_IRON)
        add_uv_box(bm, uv_layer, col_layer, bx, -col_y, col_h * 0.5, 0.044, 0.044, col_h, COL_IRON)
        # Curved iron rib segments over the vault
        for i in range(arch_segs):
            am = math.pi * (0.08 + 0.84 * (i + 0.5) / arch_segs)
            ym, zm = math.cos(am) * arch_r, arch_base_z + math.sin(am) * arch_h + 0.016
            add_uv_box(bm, uv_layer, col_layer, bx, ym, zm, 0.036, 0.20, 0.030, COL_IRON)

    # Decorative cast-iron glazed gable spandrel arches at both open train-shed ends
    for ex in (x0, x1):
        add_uv_box(bm, uv_layer, col_layer, ex, 0.0, crest_z - 0.03, 0.032, arch_r * 0.85, 0.045, COL_IRON)


def add_headhouse(bm, uv_layer, col_layer, center_y, width_x, depth_y, wall_h, num_win_pairs=2):
    """Historic Gründerzeit / Bavarian brick & dressed sandstone station headhouse with clock tower."""
    # Deep buried stone foundation plinth (z = -0.35 .. +0.14)
    add_uv_box(bm, uv_layer, col_layer, 0.0, center_y, -0.105, width_x + 0.06, depth_y + 0.05, 0.49, COL_STONE, uv_scale=1.2)
    # Main red-brick facade body
    body_cz = 0.14 + wall_h * 0.5
    add_uv_box(bm, uv_layer, col_layer, 0.0, center_y, body_cz, width_x, depth_y, wall_h, COL_BRICK, uv_scale=1.3)
    # Mid belt course + upper stone eaves cornice + corner sandstone quoins
    add_uv_box(bm, uv_layer, col_layer, 0.0, center_y, 0.14 + wall_h * 0.50, width_x + 0.04, depth_y + 0.035, 0.032, COL_STONE)
    add_uv_box(bm, uv_layer, col_layer, 0.0, center_y, 0.14 + wall_h, width_x + 0.07, depth_y + 0.06, 0.048, COL_STONE)
    for sx in (-1.0, 1.0):
        add_uv_box(bm, uv_layer, col_layer, sx * (width_x * 0.5 - 0.02), center_y, body_cz, 0.08, depth_y + 0.025, wall_h, COL_STONE)

    # Recessed 3D windows on street (-Y) and platform (+Y) facades
    street_y = center_y - depth_y * 0.5
    plat_y = center_y + depth_y * 0.5
    span = width_x * 0.5 - 0.16
    for side in (-1.0, 1.0):
        for k in range(num_win_pairs):
            t = (k + 0.5) / num_win_pairs
            wx = side * (0.24 + t * (span - 0.24))
            add_window_bay(bm, uv_layer, col_layer, wx, street_y, 0.14 + wall_h * 0.26, 0.11, 0.16, "-Y")
            add_window_bay(bm, uv_layer, col_layer, wx, street_y, 0.14 + wall_h * 0.72, 0.11, 0.14, "-Y")
            add_window_bay(bm, uv_layer, col_layer, wx, plat_y,   0.14 + wall_h * 0.26, 0.11, 0.16, "+Y")

    # Tiled terracotta hip roof + twin brick chimneys
    roof_base = 0.14 + wall_h + 0.02
    add_hip_roof(bm, uv_layer, col_layer, 0.0, center_y, roof_base, width_x, depth_y, 0.28, COL_ROOF, ridge_frac=0.64, overhang=0.07)
    for sx in (-1.0, 1.0):
        add_uv_box(bm, uv_layer, col_layer, sx * (width_x * 0.34), center_y - 0.04, roof_base + 0.22, 0.09, 0.09, 0.24, COL_BRICK)

    # Central dressed-sandstone clock tower + arched entrance portico + patinated copper spire
    tw_w = 0.38
    tw_d = 0.32
    tw_y = center_y - depth_y * 0.24
    tw_h = wall_h + 0.44
    add_uv_box(bm, uv_layer, col_layer, 0.0, tw_y, -0.105, tw_w + 0.05, tw_d + 0.05, 0.49, COL_STONE)
    add_uv_box(bm, uv_layer, col_layer, 0.0, tw_y, 0.14 + tw_h * 0.5, tw_w, tw_d, tw_h, COL_STONE, uv_scale=1.1)
    add_uv_box(bm, uv_layer, col_layer, 0.0, tw_y, 0.14 + tw_h, tw_w + 0.06, tw_d + 0.06, 0.045, COL_STONE)
    # Street entrance portal & illuminated clock face
    tw_front = tw_y - tw_d * 0.5
    add_uv_box(bm, uv_layer, col_layer, 0.0, tw_front - 0.012, 0.28, 0.15, 0.028, 0.24, COL_WIN)
    add_uv_box(bm, uv_layer, col_layer, 0.0, tw_front - 0.032, 0.41, 0.22, 0.06, 0.035, COL_STONE)  # Portico lintel
    add_uv_box(bm, uv_layer, col_layer, 0.0, tw_front - 0.014, 0.14 + tw_h - 0.16, 0.15, 0.026, 0.15, COL_CLOCK)
    # Clock tower copper pyramid spire + finial
    spire_base = 0.14 + tw_h + 0.02
    add_pyramid_spire(bm, uv_layer, col_layer, 0.0, tw_y, spire_base, tw_w * 0.54, 0.36, COL_COPPER)


def finalize_and_export(name: str, bm: bmesh.types.BMesh, filename: str):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(make_material("StationMat"))
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


def build_station_1track():
    clear_scene()
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    col = bm.loops.layers.color.new("Col")

    # Deep ground-embedding stone apron (z = -0.35 .. +0.02)
    add_uv_box(bm, uv, col, 0.0, -0.22, -0.165, 2.38, 1.78, 0.37, COL_APRON, uv_scale=1.5)

    # Recessed crushed-granite ballast bed + slim steel rails along X (y = 0)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.025, 2.32, 0.54, 0.05, COL_BALLAST, uv_scale=2.0)
    for ry in (-0.066, 0.066):
        add_uv_box(bm, uv, col, 0.0, ry, 0.055, 2.32, 0.018, 0.014, COL_RAIL)

    # Dual stone-paved platforms (y = ±0.44) + granite coping + wooden benches
    for sy in (-1.0, 1.0):
        add_uv_box(bm, uv, col, 0.0, sy * 0.44, 0.065, 2.24, 0.34, 0.13, COL_PLATFORM, uv_scale=1.6)
        add_uv_box(bm, uv, col, 0.0, sy * 0.285, 0.132, 2.24, 0.036, 0.018, COL_COPING)
        for bx in (-0.52, 0.52):
            add_uv_box(bm, uv, col, bx, sy * 0.46, 0.155, 0.14, 0.045, 0.035, COL_BENCH)

    # Arched Victorian iron & dark-glass train shed
    add_train_shed(bm, uv, col, shed_half_x=0.88, arch_r=0.56, arch_base_z=0.34, arch_h=0.42, num_bays=5, arch_segs=8)

    # Brick & sandstone headhouse on -Y (exports to Godot +Z!)
    add_headhouse(bm, uv, col, center_y=-0.82, width_x=1.48, depth_y=0.46, wall_h=0.56, num_win_pairs=2)

    finalize_and_export("RailStation1Track", bm, "rail_station.glb")


def build_station_2track():
    clear_scene()
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    col = bm.loops.layers.color.new("Col")

    # Deep ground-embedding stone apron (z = -0.35 .. +0.02)
    add_uv_box(bm, uv, col, 0.0, -0.26, -0.165, 2.74, 2.38, 0.37, COL_APRON, uv_scale=1.5)

    # Wide ballast bed + dual parallel fine-scale steel tracks at y = ±0.32 (matches DOUBLE_TRACK_OFFSET!)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.025, 2.66, 1.16, 0.05, COL_BALLAST, uv_scale=2.0)
    for ty in (-0.32, 0.32):
        add_uv_box(bm, uv, col, 0.0, ty - 0.066, 0.055, 2.22, 0.018, 0.014, COL_RAIL)
        add_uv_box(bm, uv, col, 0.0, ty + 0.066, 0.055, 2.22, 0.018, 0.014, COL_RAIL)

    # Outer stone platforms (y = ±0.72) + central island platform (y = 0.0) + coping + benches
    for sy in (-1.0, 1.0):
        add_uv_box(bm, uv, col, 0.0, sy * 0.72, 0.068, 2.24, 0.28, 0.136, COL_PLATFORM, uv_scale=1.6)
        add_uv_box(bm, uv, col, 0.0, sy * 0.59, 0.138, 2.24, 0.036, 0.018, COL_COPING)
    add_uv_box(bm, uv, col, 0.0, 0.0, 0.068, 1.98, 0.22, 0.136, COL_PLATFORM, uv_scale=1.6)
    add_uv_box(bm, uv, col, 0.0,  0.10, 0.138, 1.98, 0.030, 0.018, COL_COPING)
    add_uv_box(bm, uv, col, 0.0, -0.10, 0.138, 1.98, 0.030, 0.018, COL_COPING)
    for bx in (-0.54, 0.0, 0.54):
        add_uv_box(bm, uv, col, bx, 0.0, 0.158, 0.14, 0.048, 0.035, COL_BENCH)

    # Grand wider Victorian arched iron & dark-glass train shed over BOTH tracks
    add_train_shed(bm, uv, col, shed_half_x=0.96, arch_r=0.84, arch_base_z=0.36, arch_h=0.56, num_bays=5, arch_segs=8)

    # Grand brick & sandstone headhouse on -Y (exports to Godot +Z!)
    add_headhouse(bm, uv, col, center_y=-1.10, width_x=1.76, depth_y=0.48, wall_h=0.60, num_win_pairs=3)

    finalize_and_export("RailStation2Track", bm, "rail_station_2track.glb")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("Generating Blender UV-mapped European railway stations in", OUT_DIR)
    build_station_1track()
    build_station_2track()
    print("Done!")


if __name__ == "__main__":
    main()
