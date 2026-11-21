extends Node3D

# Camera-centered streaming 3D forest & vegetation detail bubble.
# Renders up to ~4,000 micro-scale Alpine conifers, valley broadleaf trees & shrubs
# in just 3 GPU MultiMesh draw calls, seamlessly fading in when zoomed close!

const CELL_SIZE_INNER := 0.0095 # Tight interlocking crown spacing -> real dense forest up close!
const CELL_SIZE_OUTER := 0.0155 # Slightly wider outer LOD1 spacing with fuller crowns -> fast & seamless!
const BUBBLE_RADIUS := 1.05     # Outer stream radius around camera focus point
const LOD0_RADIUS := 0.40       # Inner dense high-detail LOD0 forest ring around camera!
const REBUILD_MOVE_DIST := 0.12 # Only rebuild MultiMesh transforms when camera pans > 0.12u
const ZOOM_SHOW_MAX := 8.5      # Start fading in vegetation below this camera distance
const ZOOM_FULL_DIST := 3.2     # Full scale below this camera distance

const MAX_SPRUCE_0 := 4500
const MAX_SPRUCE_1 := 7500
const MAX_OAK_0 := 2200
const MAX_OAK_1 := 3800
const MAX_SHRUB := 2400

var world_ref: Node3D = null
var rail_ref: Node3D = null

var mm_spruce_0: MultiMeshInstance3D = null
var mm_spruce_1: MultiMeshInstance3D = null
var mm_oak_0: MultiMeshInstance3D = null
var mm_oak_1: MultiMeshInstance3D = null
var mm_shrub: MultiMeshInstance3D = null
var veg_mat: ShaderMaterial = null

var _last_build_center := Vector2(1e9, 1e9)
var _last_rail_sig := -1
var _currently_visible := false


func setup(world: Node3D, rail: Node3D) -> void:
	world_ref = world
	rail_ref = rail

	veg_mat = ShaderMaterial.new()
	veg_mat.shader = load("res://shaders/vegetation_pbr.gdshader")
	veg_mat.set_shader_parameter("bubble_radius", BUBBLE_RADIUS)
	veg_mat.set_shader_parameter("zoom_fade", 0.0)
	veg_mat.set_shader_parameter("tex_foliage", world._load_texture_direct("res://textures/pbr_foliage.png"))
	veg_mat.set_shader_parameter("tex_foliage_n", world._load_texture_direct("res://textures/pbr_foliage_n.png"))
	veg_mat.set_shader_parameter("tex_bark", world._load_texture_direct("res://textures/pbr_bark.png"))
	veg_mat.set_shader_parameter("tex_bark_n", world._load_texture_direct("res://textures/pbr_bark_n.png"))

	mm_spruce_0 = _make_mm("StreamSpruceLOD0", world._load_glb_mesh("res://assets/models/tree_alpine_spruce_lod0.glb"), MAX_SPRUCE_0)
	mm_spruce_1 = _make_mm("StreamSpruceLOD1", world._load_glb_mesh("res://assets/models/tree_alpine_spruce.glb"), MAX_SPRUCE_1)
	mm_oak_0 = _make_mm("StreamOakLOD0", world._load_glb_mesh("res://assets/models/tree_temperate_oak_lod0.glb"), MAX_OAK_0)
	mm_oak_1 = _make_mm("StreamOakLOD1", world._load_glb_mesh("res://assets/models/tree_temperate_oak.glb"), MAX_OAK_1)
	mm_shrub = _make_mm("StreamShrub", world._load_glb_mesh("res://assets/models/veg_shrub_cluster.glb"), MAX_SHRUB)


func _make_mm(node_name: String, mesh: Mesh, max_count: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = max_count
	mm.visible_instance_count = 0

	var inst := MultiMeshInstance3D.new()
	inst.name = node_name
	inst.multimesh = mm
	inst.material_override = veg_mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	inst.visible = false
	add_child(inst)
	return inst


func update_for_camera(cam_target: Vector3, cam_dist: float) -> void:
	if not world_ref or not veg_mat:
		return

	var zoom_fade := clampf((ZOOM_SHOW_MAX - cam_dist) / (ZOOM_SHOW_MAX - ZOOM_FULL_DIST), 0.0, 1.0)
	var should_show := zoom_fade > 0.005
	if should_show != _currently_visible:
		_currently_visible = should_show
		mm_spruce_0.visible = should_show
		mm_spruce_1.visible = should_show
		mm_oak_0.visible = should_show
		mm_oak_1.visible = should_show
		mm_shrub.visible = should_show
	if not should_show:
		return

	veg_mat.set_shader_parameter("bubble_center", Vector3(cam_target.x, 0.0, cam_target.z))
	veg_mat.set_shader_parameter("zoom_fade", zoom_fade)

	# Detect if tracks or stations were added/removed so railway right-of-way stays clear!
	var rail_sig := 0
	if rail_ref:
		rail_sig = rail_ref.edges.size() * 1009 + rail_ref.stations.size() * 37
	var center2 := Vector2(cam_target.x, cam_target.z)
	if center2.distance_to(_last_build_center) >= REBUILD_MOVE_DIST or rail_sig != _last_rail_sig:
		_last_build_center = center2
		_last_rail_sig = rail_sig
		_rebuild_bubble(center2)


func _hash2(ix: int, iz: int, salt: int) -> float:
	var n: int = (ix * 374761393 + iz * 668265263 + salt * 1442695041) & 0x7fffffff
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7fffffff
	return float((n ^ (n >> 16)) & 0x00ffffff) / 16777216.0


func _rebuild_bubble(center: Vector2) -> void:
	var r2 := BUBBLE_RADIUS * BUBBLE_RADIUS
	var lod0_r2 := LOD0_RADIUS * LOD0_RADIUS

	var sp0_mm := mm_spruce_0.multimesh
	var sp1_mm := mm_spruce_1.multimesh
	var ok0_mm := mm_oak_0.multimesh
	var ok1_mm := mm_oak_1.multimesh
	var sh_mm := mm_shrub.multimesh
	var sp0_cnt := 0
	var sp1_cnt := 0
	var ok0_cnt := 0
	var ok1_cnt := 0
	var sh_cnt := 0

	var land_scale: float = world_ref.LAND_HEIGHT_SCALE

	# Pass 1: Dense inner LOD0 forest ring (interlocking crowns!)
	# Pass 2: Outer LOD1 woodland ring (fuller crowns for continuous canopy at low GPU cost)
	for pass_idx in range(2):
		var is_inner := (pass_idx == 0)
		var cell := CELL_SIZE_INNER if is_inner else CELL_SIZE_OUTER
		var rad := LOD0_RADIUS if is_inner else BUBBLE_RADIUS
		var gx0 := int(floor((center.x - rad) / cell))
		var gx1 := int(ceil((center.x + rad) / cell))
		var gz0 := int(floor((center.y - rad) / cell))
		var gz1 := int(ceil((center.y + rad) / cell))

		for gz in range(gz0, gz1 + 1):
			for gx in range(gx0, gx1 + 1):
				var jx := (_hash2(gx, gz, 1 + pass_idx * 17) - 0.5) * 0.88
				var jz := (_hash2(gx, gz, 2 + pass_idx * 17) - 0.5) * 0.88
				var wx := (float(gx) + 0.5 + jx) * cell
				var wz := (float(gz) + 0.5 + jz) * cell
				var dx := wx - center.x
				var dz := wz - center.y
				var d2 := dx * dx + dz * dz
				if is_inner:
					if d2 > lod0_r2:
						continue
				else:
					if d2 <= lod0_r2 or d2 > r2:
						continue

				# 1. Landuse check: only place trees inside real OSM/Sentinel-2 forest areas (avoid urban & roads!)
				var lu: Color = world_ref.sample_landuse(wx, wz)
				if lu.r < 0.28 or lu.g > 0.45 or lu.b > 0.35:
					continue

				# 2. Water check: never place trees in lakes or rivers!
				if world_ref.sample_water_mask(wx, wz) > 0.20:
					continue

				# 3. Elevation & Alpine timberline check
				var elev: float = world_ref.sample_elevation_m(wx, wz)
				if elev < 5.0 or elev > 1960.0:
					continue

				# 4. Slope check: allow steep forested Alpine valley walls, exclude sheer vertical cliffs
				var ex: float = world_ref.sample_elevation_m(wx + 0.025, wz)
				var ez: float = world_ref.sample_elevation_m(wx, wz + 0.025)
				var slope_m := maxf(absf(ex - elev), absf(ez - elev))
				if slope_m > 78.0:
					continue

				# 5. Railway right-of-way clearance: never clip into tracks or stations!
				if rail_ref and rail_ref.is_near_railway(Vector2(wx, wz), 0.028, 0.048):
					continue

				# Embed slightly below bilinear terrain surface (combined with -0.45 underground trunk roots -> ZERO floating!)
				var wy := elev * land_scale - 0.0025
				var yaw := _hash2(gx, gz, 3) * TAU
				var r_size := _hash2(gx, gz, 4)
				var r_type := _hash2(gx, gz, 5)
				var r_tint := _hash2(gx, gz, 6)

				# Tone-match directly to the underlying Sentinel-2 satellite canopy color
				var sat_c: Color = world_ref.sample_sat_color(wx, wz)
				var sat_boost := clampf(0.95 / maxf(0.18, sat_c.g), 0.75, 1.55)
				var ground_tint := Color(
					clampf(sat_c.r * sat_boost, 0.40, 0.90),
					clampf(sat_c.g * sat_boost, 0.50, 0.96),
					clampf(sat_c.b * sat_boost, 0.36, 0.84)
				)
				var var_l := 0.80 + r_tint * 0.28
				var col := Color(ground_tint.r * var_l, ground_tint.g * var_l, ground_tint.b * var_l)
				# Outer LOD1 crowns are slightly fuller (1.28x) so the forest reads as a continuous dense canopy
				var lod_mul := 1.0 if is_inner else 1.28

				# Timberline krummholz shrubs above 1,720m or forest-edge feathering
				if elev > 1720.0 or (lu.r < 0.46 and r_type < 0.50):
					if sh_cnt < MAX_SHRUB:
						var s := (0.0055 + r_size * 0.0042) * lod_mul
						var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s * 0.80, s)), Vector3(wx, wy, wz))
						sh_mm.set_instance_transform(sh_cnt, xf)
						sh_mm.set_instance_color(sh_cnt, col)
						sh_cnt += 1
				elif elev < 820.0 and r_type < 0.45:
					var s := (0.0068 + r_size * 0.0046) * lod_mul
					var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s * (0.85 + r_size * 0.22), s)), Vector3(wx, wy, wz))
					if is_inner and ok0_cnt < MAX_OAK_0:
						ok0_mm.set_instance_transform(ok0_cnt, xf)
						ok0_mm.set_instance_color(ok0_cnt, col)
						ok0_cnt += 1
					elif (not is_inner) and ok1_cnt < MAX_OAK_1:
						ok1_mm.set_instance_transform(ok1_cnt, xf)
						ok1_mm.set_instance_color(ok1_cnt, col)
						ok1_cnt += 1
				else:
					var s := (0.0074 + r_size * 0.0050) * lod_mul
					var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s * (0.95 + r_size * 0.35), s)), Vector3(wx, wy, wz))
					var sp_col := Color(col.r * 0.90, col.g * 0.95, col.b * 0.90)
					if is_inner and sp0_cnt < MAX_SPRUCE_0:
						sp0_mm.set_instance_transform(sp0_cnt, xf)
						sp0_mm.set_instance_color(sp0_cnt, sp_col)
						sp0_cnt += 1
					elif (not is_inner) and sp1_cnt < MAX_SPRUCE_1:
						sp1_mm.set_instance_transform(sp1_cnt, xf)
						sp1_mm.set_instance_color(sp1_cnt, sp_col)
						sp1_cnt += 1

	sp0_mm.visible_instance_count = sp0_cnt
	sp1_mm.visible_instance_count = sp1_cnt
	ok0_mm.visible_instance_count = ok0_cnt
	ok1_mm.visible_instance_count = ok1_cnt
	sh_mm.visible_instance_count = sh_cnt
