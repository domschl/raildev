extends Node3D

# Camera-centered streaming 3D forest & vegetation detail bubble.
# Renders up to ~4,000 micro-scale Alpine conifers, valley broadleaf trees & shrubs
# in just 3 GPU MultiMesh draw calls, seamlessly fading in when zoomed close!

const CELL_SIZE := 0.020        # Fine micro-scale grid cell -> lush, dense forests!
const BUBBLE_RADIUS := 1.15     # Stream radius around camera focus point
const REBUILD_MOVE_DIST := 0.14 # Only rebuild MultiMesh transforms when camera pans > 0.14u
const ZOOM_SHOW_MAX := 8.5      # Start fading in vegetation below this camera distance
const ZOOM_FULL_DIST := 3.2     # Full scale below this camera distance

const MAX_SPRUCE := 4200
const MAX_OAK := 2200
const MAX_SHRUB := 1400

var world_ref: Node3D = null
var rail_ref: Node3D = null

var mm_spruce: MultiMeshInstance3D = null
var mm_oak: MultiMeshInstance3D = null
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

	mm_spruce = _make_mm("StreamSpruce", world._load_glb_mesh("res://assets/models/tree_alpine_spruce.glb"), MAX_SPRUCE)
	mm_oak = _make_mm("StreamOak", world._load_glb_mesh("res://assets/models/tree_temperate_oak.glb"), MAX_OAK)
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
		mm_spruce.visible = should_show
		mm_oak.visible = should_show
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
	var gx0 := int(floor((center.x - BUBBLE_RADIUS) / CELL_SIZE))
	var gx1 := int(ceil((center.x + BUBBLE_RADIUS) / CELL_SIZE))
	var gz0 := int(floor((center.y - BUBBLE_RADIUS) / CELL_SIZE))
	var gz1 := int(ceil((center.y + BUBBLE_RADIUS) / CELL_SIZE))
	var r2 := BUBBLE_RADIUS * BUBBLE_RADIUS

	var sp_mm := mm_spruce.multimesh
	var ok_mm := mm_oak.multimesh
	var sh_mm := mm_shrub.multimesh
	var sp_cnt := 0
	var ok_cnt := 0
	var sh_cnt := 0

	var land_scale: float = world_ref.LAND_HEIGHT_SCALE

	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var jx := (_hash2(gx, gz, 1) - 0.5) * 0.85
			var jz := (_hash2(gx, gz, 2) - 0.5) * 0.85
			var wx := (float(gx) + 0.5 + jx) * CELL_SIZE
			var wz := (float(gz) + 0.5 + jz) * CELL_SIZE
			var dx := wx - center.x
			var dz := wz - center.y
			if dx * dx + dz * dz > r2:
				continue

			# 1. Landuse check: only place trees inside real OSM/Sentinel-2 forest areas (avoid urban & roads!)
			var lu: Color = world_ref.sample_landuse(wx, wz)
			if lu.r < 0.35 or lu.g > 0.45 or lu.b > 0.35:
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
			if slope_m > 75.0:
				continue

			# 5. Railway right-of-way clearance: never clip into tracks or stations!
			if rail_ref and rail_ref.is_near_railway(Vector2(wx, wz), 0.045, 0.085):
				continue

			var wy := elev * land_scale - 0.001
			var yaw := _hash2(gx, gz, 3) * TAU
			var r_size := _hash2(gx, gz, 4)
			var r_type := _hash2(gx, gz, 5)
			var r_tint := _hash2(gx, gz, 6)

			# Tone-match to deep natural Sentinel-2 Alpine/valley woodland palette
			var tint := 0.66 + r_tint * 0.24
			var col := Color(tint * 0.82, tint * 0.90, tint * 0.78)

			# Timberline krummholz shrubs above 1,720m or sparse forest edge understory
			if elev > 1720.0 or (lu.r < 0.52 and r_type < 0.40):
				if sh_cnt < MAX_SHRUB:
					var s := 0.0055 + r_size * 0.0040
					var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s * 0.85, s)), Vector3(wx, wy, wz))
					sh_mm.set_instance_transform(sh_cnt, xf)
					sh_mm.set_instance_color(sh_cnt, col)
					sh_cnt += 1
			elif elev < 820.0 and r_type < 0.45:
				# Valley broadleaf oak / beech woodland
				if ok_cnt < MAX_OAK:
					var s := 0.0068 + r_size * 0.0046
					var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s * (0.88 + r_size * 0.24), s)), Vector3(wx, wy, wz))
					ok_mm.set_instance_transform(ok_cnt, xf)
					ok_mm.set_instance_color(ok_cnt, Color(tint * 0.84, tint * 0.92, tint * 0.72))
					ok_cnt += 1
			else:
				# Alpine & foothill spruce / conifer forest
				if sp_cnt < MAX_SPRUCE:
					var s := 0.0072 + r_size * 0.0050
					var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s * (0.95 + r_size * 0.35), s)), Vector3(wx, wy, wz))
					sp_mm.set_instance_transform(sp_cnt, xf)
					sp_mm.set_instance_color(sp_cnt, Color(tint * 0.72, tint * 0.86, tint * 0.72))
					sp_cnt += 1

	sp_mm.visible_instance_count = sp_cnt
	ok_mm.visible_instance_count = ok_cnt
	sh_mm.visible_instance_count = sh_cnt
