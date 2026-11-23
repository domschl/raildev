extends Node3D

# Camera-centered streaming 3D city buildings + station-connected forecourt districts.
# Renders thousands of micro-scale European townhouses, mansard blocks & landmark spires
# in 4 GPU MultiMesh draw calls, organically aligned around stations & real Sentinel-2 city footprints.

const CELL_SIZE := 0.0198       # Dense European block spacing harmonized with station/train/tree scale
const BUBBLE_RADIUS := 1.15     # Stream radius around camera focus point (RTX 4070 Ti headroom!)
const REBUILD_MOVE_DIST := 0.12
const ZOOM_SHOW_MAX := 7.2      # Start fading in city buildings below this camera distance
const ZOOM_FULL_DIST := 2.6     # Full scale below this camera distance

const MAX_TOWNHOUSE := 4200
const MAX_MANSARD := 3000
const MAX_VILLA := 2000
const MAX_CHALET := 2000
const MAX_CORNER := 1600
const MAX_PLAZA := 120
const MAX_YARD := 9500
const MAX_GARDEN_SHRUB := 6500
const MAX_GARDEN_TREE := 1500

var world_ref: Node3D = null
var rail_ref: Node3D = null

var mm_townhouse: MultiMeshInstance3D = null
var mm_mansard: MultiMeshInstance3D = null
var mm_villa: MultiMeshInstance3D = null
var mm_chalet: MultiMeshInstance3D = null
var mm_corner: MultiMeshInstance3D = null
var mm_plaza: MultiMeshInstance3D = null
var mm_yard: MultiMeshInstance3D = null
var mm_garden_shrub: MultiMeshInstance3D = null
var mm_garden_tree: MultiMeshInstance3D = null
var urban_mat: ShaderMaterial = null
var yard_mat: ShaderMaterial = null
var garden_veg_mat: ShaderMaterial = null
var garden_bark_mat: ShaderMaterial = null
var garden_oak_card_mat: ShaderMaterial = null

var _last_build_center := Vector2(1e9, 1e9)
var _last_rail_sig := -1
var _currently_visible := false


func setup(world: Node3D, rail: Node3D) -> void:
	world_ref = world
	rail_ref = rail

	urban_mat = ShaderMaterial.new()
	urban_mat.shader = load("res://shaders/urban_pbr.gdshader")
	urban_mat.set_shader_parameter("bubble_radius", BUBBLE_RADIUS)
	urban_mat.set_shader_parameter("zoom_fade", 0.0)
	urban_mat.set_shader_parameter("tex_roof", world._load_texture_direct("res://textures/pbr_roof_tiles.png"))
	urban_mat.set_shader_parameter("tex_roof_n", world._load_texture_direct("res://textures/pbr_roof_tiles_n.png"))
	urban_mat.set_shader_parameter("tex_wall", world._load_texture_direct("res://textures/pbr_wall_plaster.png"))
	urban_mat.set_shader_parameter("tex_wall_n", world._load_texture_direct("res://textures/pbr_wall_plaster_n.png"))
	urban_mat.set_shader_parameter("tex_cobble", world._load_texture_direct("res://textures/pbr_cobble.png"))
	urban_mat.set_shader_parameter("tex_cobble_n", world._load_texture_direct("res://textures/pbr_cobble_n.png"))
	# Automatically enable 2x2 AI facade atlas once dropped into godot/textures/
	var atlas_abs := ProjectSettings.globalize_path("res://textures/pbr_facade_atlas.png")
	if FileAccess.file_exists(atlas_abs):
		urban_mat.set_shader_parameter("use_facade_atlas", true)
		urban_mat.set_shader_parameter("tex_facade_atlas", world._load_texture_direct("res://textures/pbr_facade_atlas.png"))
		urban_mat.set_shader_parameter("tex_facade_atlas_n", world._load_texture_direct("res://textures/pbr_facade_atlas_n.png"))

	mm_townhouse = _make_mm("StreamTownhouse", world._load_glb_mesh("res://assets/models/bldg_north_townhouse.glb"), MAX_TOWNHOUSE)
	mm_mansard = _make_mm("StreamMansard", world._load_glb_mesh("res://assets/models/bldg_north_mansard.glb"), MAX_MANSARD)
	mm_villa = _make_mm("StreamVilla", world._load_glb_mesh("res://assets/models/bldg_med_villa.glb"), MAX_VILLA)
	mm_chalet = _make_mm("StreamChalet", world._load_glb_mesh("res://assets/models/bldg_alpine_chalet.glb"), MAX_CHALET)
	mm_corner = _make_mm("StreamCorner", world._load_glb_mesh("res://assets/models/bldg_corner_block.glb"), MAX_CORNER)

	# Cobblestone station forecourt apron mesh
	var pmesh := BoxMesh.new()
	pmesh.size = Vector3(1.0, 0.08, 1.0)
	mm_plaza = _make_mm("StreamStationPlazas", pmesh, MAX_PLAZA)

	# Organic ground-contact AO + weathered stone/gravel/moss yard pad under every house
	yard_mat = ShaderMaterial.new()
	yard_mat.shader = load("res://shaders/urban_yard.gdshader")
	yard_mat.set_shader_parameter("bubble_radius", BUBBLE_RADIUS)
	yard_mat.set_shader_parameter("zoom_fade", 0.0)
	yard_mat.set_shader_parameter("tex_cobble", world._load_texture_direct("res://textures/pbr_cobble.png"))
	yard_mat.set_shader_parameter("tex_cobble_n", world._load_texture_direct("res://textures/pbr_cobble_n.png"))
	var ymesh := PlaneMesh.new()
	ymesh.size = Vector2(1.0, 1.0)
	mm_yard = _make_mm("StreamHouseYards", ymesh, MAX_YARD, yard_mat, false)

	# Urban garden hedges, corner shrubs & backyard broadleaf trees hugging houses
	garden_veg_mat = ShaderMaterial.new()
	garden_veg_mat.shader = load("res://shaders/vegetation_pbr.gdshader")
	garden_veg_mat.set_shader_parameter("bubble_radius", BUBBLE_RADIUS)
	garden_veg_mat.set_shader_parameter("zoom_fade", 0.0)
	garden_veg_mat.set_shader_parameter("tex_foliage", world._load_texture_direct("res://textures/pbr_foliage.png"))
	garden_veg_mat.set_shader_parameter("tex_foliage_n", world._load_texture_direct("res://textures/pbr_foliage_n.png"))
	garden_veg_mat.set_shader_parameter("tex_bark", world._load_texture_direct("res://textures/pbr_bark.png"))
	garden_veg_mat.set_shader_parameter("tex_bark_n", world._load_texture_direct("res://textures/pbr_bark_n.png"))

	garden_bark_mat = garden_veg_mat.duplicate()
	garden_bark_mat.set_shader_parameter("force_bark", true)

	garden_oak_card_mat = ShaderMaterial.new()
	garden_oak_card_mat.shader = load("res://shaders/vegetation_card_pbr.gdshader")
	garden_oak_card_mat.set_shader_parameter("bubble_radius", BUBBLE_RADIUS)
	garden_oak_card_mat.set_shader_parameter("zoom_fade", 0.0)
	garden_oak_card_mat.set_shader_parameter("tex_card", world._load_texture_direct("res://textures/pbr_oak_bough.png"))
	garden_oak_card_mat.set_shader_parameter("tex_card_n", world._load_texture_direct("res://textures/pbr_oak_bough_n.png"))

	mm_garden_shrub = _make_mm("StreamGardenShrubs", world._load_glb_mesh("res://assets/models/veg_shrub_cluster.glb"), MAX_GARDEN_SHRUB, garden_veg_mat, true)
	var oak_mesh: Mesh = world._load_glb_mesh("res://assets/models/tree_temperate_oak_lod0.glb")
	if oak_mesh != null and oak_mesh.get_surface_count() >= 2:
		oak_mesh = oak_mesh.duplicate()
		oak_mesh.surface_set_material(0, garden_bark_mat)
		oak_mesh.surface_set_material(1, garden_oak_card_mat)
		mm_garden_tree = _make_mm("StreamGardenTrees", oak_mesh, MAX_GARDEN_TREE, null, true)
	else:
		mm_garden_tree = _make_mm("StreamGardenTrees", oak_mesh, MAX_GARDEN_TREE, garden_veg_mat, true)


func _make_mm(node_name: String, mesh: Mesh, max_count: int, mat_override: Material = urban_mat, cast_shadows: bool = true) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = max_count
	mm.visible_instance_count = 0

	var inst := MultiMeshInstance3D.new()
	inst.name = node_name
	inst.multimesh = mm
	if mat_override != null:
		inst.material_override = mat_override
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.visible = false
	add_child(inst)
	return inst


func update_for_camera(cam_target: Vector3, cam_dist: float) -> void:
	if not world_ref or not urban_mat:
		return

	var zoom_fade := clampf((ZOOM_SHOW_MAX - cam_dist) / (ZOOM_SHOW_MAX - ZOOM_FULL_DIST), 0.0, 1.0)
	var should_show := zoom_fade > 0.005
	if should_show != _currently_visible:
		_currently_visible = should_show
		mm_townhouse.visible = should_show
		mm_mansard.visible = should_show
		mm_villa.visible = should_show
		mm_chalet.visible = should_show
		mm_corner.visible = should_show
		mm_plaza.visible = should_show
		mm_yard.visible = should_show
		mm_garden_shrub.visible = should_show
		mm_garden_tree.visible = should_show
	if not should_show:
		return

	var bcenter := Vector3(cam_target.x, 0.0, cam_target.z)
	urban_mat.set_shader_parameter("bubble_center", bcenter)
	urban_mat.set_shader_parameter("zoom_fade", zoom_fade)
	if yard_mat:
		yard_mat.set_shader_parameter("bubble_center", bcenter)
		yard_mat.set_shader_parameter("zoom_fade", zoom_fade)
	if garden_veg_mat:
		garden_veg_mat.set_shader_parameter("bubble_center", bcenter)
		garden_veg_mat.set_shader_parameter("zoom_fade", zoom_fade)
	if garden_bark_mat:
		garden_bark_mat.set_shader_parameter("bubble_center", bcenter)
		garden_bark_mat.set_shader_parameter("zoom_fade", zoom_fade)
	if garden_oak_card_mat:
		garden_oak_card_mat.set_shader_parameter("bubble_center", bcenter)
		garden_oak_card_mat.set_shader_parameter("zoom_fade", zoom_fade)

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
	var th_mm := mm_townhouse.multimesh
	var mn_mm := mm_mansard.multimesh
	var vl_mm := mm_villa.multimesh
	var ch_mm := mm_chalet.multimesh
	var cr_mm := mm_corner.multimesh
	var pl_mm := mm_plaza.multimesh
	var yd_mm := mm_yard.multimesh
	var gs_mm := mm_garden_shrub.multimesh
	var gt_mm := mm_garden_tree.multimesh
	var th_cnt := 0
	var mn_cnt := 0
	var vl_cnt := 0
	var ch_cnt := 0
	var cr_cnt := 0
	var pl_cnt := 0
	var yd_cnt := 0
	var gs_cnt := 0
	var gt_cnt := 0

	var land_scale: float = world_ref.LAND_HEIGHT_SCALE

	# Gather nearby cities for fast urban-footprint & regional-architecture checks
	var nearby_cities: Array = []
	for c in world_ref.cities:
		var cxz: Vector2 = world_ref.map_to_world_xz(float(c["x"]), float(c["y"]))
		var r_world := maxf(0.18, float(c["radius"]) * 0.1 * 1.35)
		if cxz.distance_to(center) <= BUBBLE_RADIUS + r_world:
			nearby_cities.append({
				"pos": cxz,
				"rad2": r_world * r_world,
				"lat": float(c["lat"]),
				"pop": int(c["population"]),
			})

	# 1. Station-Connected Forecourt Plazas & Aligned Station-Quarter Buildings!
	if rail_ref:
		for si in range(rail_ref.stations.size()):
			var st = rail_ref.stations[si]
			var sp: Vector2 = st["pos"]
			if sp.distance_squared_to(center) > r2 * 1.15:
				continue
			var ang: float = float(st["angle"])
			var fwd := Vector2(cos(ang), sin(ang))
			var side := Vector2(fwd.y, -fwd.x)  # -Z headhouse entrance side of station!
			var st_tracks: int = int(st.get("tracks", 1))
			var plaza_off := 0.036 if st_tracks >= 2 else 0.028
			var plaza_pos := sp + side * plaza_off
			var pelev: float = world_ref.sample_elevation_m(plaza_pos.x, plaza_pos.y)
			if pelev > 1.0 and pl_cnt < MAX_PLAZA:
				var pwy := pelev * land_scale - 0.0004
				var pxf := Transform3D(Basis(Vector3.UP, -ang).scaled(Vector3(0.056, 0.035, 0.028)), Vector3(plaza_pos.x, pwy, plaza_pos.y))
				pl_mm.set_instance_transform(pl_cnt, pxf)
				pl_mm.set_instance_color(pl_cnt, Color(0.54, 0.52, 0.48))
				pl_cnt += 1

			# Spawn station-aligned Bahnhofsplatz buildings framing the forecourt (hotels, cafés, townhouses)
			var offsets := [
				Vector2(-0.032, plaza_off + 0.021),
				Vector2(-0.011, plaza_off + 0.022),
				Vector2( 0.011, plaza_off + 0.022),
				Vector2( 0.032, plaza_off + 0.021),
				Vector2(-0.042, plaza_off + 0.003),
				Vector2( 0.042, plaza_off + 0.003),
				Vector2(-0.024, plaza_off + 0.041),
				Vector2( 0.000, plaza_off + 0.042),
				Vector2( 0.024, plaza_off + 0.041),
			]
			var palette := [
				Color(0.95, 0.88, 0.76),
				Color(0.90, 0.87, 0.82),
				Color(0.93, 0.82, 0.74),
				Color(0.84, 0.85, 0.86),
				Color(0.86, 0.88, 0.80),
			]
			for oi in range(offsets.size()):
				var off: Vector2 = offsets[oi]
				var bp := sp + fwd * off.x + side * off.y
				if world_ref.sample_water_mask(bp.x, bp.y) > 0.16:
					continue
				if rail_ref.is_near_railway(bp, 0.024, 0.026):
					continue
				var belev: float = world_ref.sample_elevation_m(bp.x, bp.y)
				if belev < 2.0 or belev > 1850.0:
					continue
				var bex1: float = world_ref.sample_elevation_m(bp.x + 0.018, bp.y)
				var bex2: float = world_ref.sample_elevation_m(bp.x - 0.018, bp.y)
				var bez1: float = world_ref.sample_elevation_m(bp.x, bp.y + 0.018)
				var bez2: float = world_ref.sample_elevation_m(bp.x, bp.y - 0.018)
				var b_min_elev := minf(belev, minf(minf(bex1, bex2), minf(bez1, bez2)))
				var bwy := b_min_elev * land_scale - 0.0006
				var s := 0.0116 + _hash2(si * 31 + oi, 7, 1) * 0.0030
				var sy := s * (0.95 + _hash2(si * 31 + oi, 7, 2) * 0.28)
				var bcol: Color = palette[(si * 7 + oi) % palette.size()] * (0.88 + _hash2(si * 31 + oi, 7, 3) * 0.16)
				var bxf := Transform3D(Basis(Vector3.UP, -ang).scaled(Vector3(s, sy, s)), Vector3(bp.x, bwy, bp.y))
				var b_cust := Color(float((si + oi) % 4), float((oi % 3)), _hash2(si * 13 + oi, 9, 4), _hash2(si * 19 + oi, 11, 5))
				if oi % 3 == 0 and cr_cnt < MAX_CORNER:
					cr_mm.set_instance_transform(cr_cnt, bxf)
					cr_mm.set_instance_color(cr_cnt, bcol)
					cr_mm.set_instance_custom_data(cr_cnt, b_cust)
					cr_cnt += 1
				elif oi % 2 == 0 and mn_cnt < MAX_MANSARD:
					mn_mm.set_instance_transform(mn_cnt, bxf)
					mn_mm.set_instance_color(mn_cnt, bcol)
					mn_mm.set_instance_custom_data(mn_cnt, b_cust)
					mn_cnt += 1
				elif th_cnt < MAX_TOWNHOUSE:
					th_mm.set_instance_transform(th_cnt, bxf)
					th_mm.set_instance_color(th_cnt, bcol)
					th_mm.set_instance_custom_data(th_cnt, b_cust)
					th_cnt += 1
				# Slope-aligned organic contact-AO & stone courtyard pad under Bahnhofsplatz building
				if yd_cnt < MAX_YARD:
					var bn := Vector3((bex2 - bex1) * land_scale, 2.0 * 0.018, (bez2 - bez1) * land_scale).normalized()
					var bfwd := Vector3(cos(ang), 0.0, sin(ang))
					bfwd = (bfwd - bn * bfwd.dot(bn)).normalized()
					var bright := bn.cross(bfwd).normalized()
					var y_basis := Basis(bright * (s * 1.95), bn, bfwd * (s * 1.65))
					var y_pos := Vector3(bp.x, belev * land_scale, bp.y) + bn * 0.00045
					yd_mm.set_instance_transform(yd_cnt, Transform3D(y_basis, y_pos))
					yd_mm.set_instance_color(yd_cnt, Color.WHITE)
					yd_mm.set_instance_custom_data(yd_cnt, Color(0.0, 0.0, _hash2(si * 17 + oi, 3, 6), _hash2(si * 23 + oi, 5, 7)))
					yd_cnt += 1

	# 2. Real-Footprint Streaming City Buildings across Sentinel-2 Urban Areas!
	var gx0 := int(floor((center.x - BUBBLE_RADIUS) / CELL_SIZE))
	var gx1 := int(ceil((center.x + BUBBLE_RADIUS) / CELL_SIZE))
	var gz0 := int(floor((center.y - BUBBLE_RADIUS) / CELL_SIZE))
	var gz1 := int(ceil((center.y + BUBBLE_RADIUS) / CELL_SIZE))

	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var jx := (_hash2(gx, gz, 11) - 0.5) * 0.50
			var jz := (_hash2(gx, gz, 12) - 0.5) * 0.50
			var wx := (float(gx) + 0.5 + jx) * CELL_SIZE
			var wz := (float(gz) + 0.5 + jz) * CELL_SIZE
			var dx := wx - center.x
			var dz := wz - center.y
			if dx * dx + dz * dz > r2:
				continue

			# Exclude forests, roads & water immediately
			var lu: Color = world_ref.sample_landuse(wx, wz)
			if lu.r > 0.26 or lu.b > 0.24:
				continue
			if world_ref.sample_water_mask(wx, wz) > 0.16:
				continue

			# Urban eligibility: OSM urban mask OR bright built-up Sentinel-2 rooftop inside a city footprint!
			var is_urban := (lu.g > 0.20)
			var is_med := false
			var in_city_core := false
			var city_dir := Vector2.RIGHT
			if not nearby_cities.is_empty():
				var p2 := Vector2(wx, wz)
				for nc in nearby_cities:
					var d2c := p2.distance_squared_to(nc["pos"])
					if d2c <= float(nc["rad2"]):
						is_med = float(nc["lat"]) < 44.8
						if d2c <= float(nc["rad2"]) * 0.32:
							in_city_core = true
						city_dir = (p2 - (nc["pos"] as Vector2))
						if not is_urban:
							# Check Sentinel-2 neutral/bright rooftop fabric (excludes green meadows/parks!)
							var sat_c: Color = world_ref.sample_sat_color(wx, wz)
							var lum := sat_c.r * 0.3 + sat_c.g * 0.59 + sat_c.b * 0.11
							var green_ex := sat_c.g - maxf(sat_c.r, sat_c.b)
							if lum > 0.26 and green_ex < 0.032:
								is_urban = true
						break
			if not is_urban:
				continue

			var elev: float = world_ref.sample_elevation_m(wx, wz)
			if elev < 2.0 or elev > 1750.0:
				continue

			# Avoid steep slopes & sample all 4 directions around footprint so house never floats on downhill side
			var ex: float = world_ref.sample_elevation_m(wx + 0.022, wz)
			var ex2: float = world_ref.sample_elevation_m(wx - 0.022, wz)
			var ez: float = world_ref.sample_elevation_m(wx, wz + 0.022)
			var ez2: float = world_ref.sample_elevation_m(wx, wz - 0.022)
			if maxf(maxf(absf(ex - elev), absf(ex2 - elev)), maxf(absf(ez - elev), absf(ez2 - elev))) > 26.0:
				continue

			# Keep railway tracks & stations cleanly clear!
			if rail_ref and rail_ref.is_near_railway(Vector2(wx, wz), 0.028, 0.048):
				continue

			# Align street blocks organically: each ~3x3 neighborhood block shares a street angle!
			var bx := int(floor(float(gx) / 3.0))
			var bz := int(floor(float(gz) / 3.0))
			var block_yaw := _hash2(bx, bz, 29) * TAU
			var q_yaw := block_yaw + (PI * 0.5 if _hash2(gx, gz, 31) > 0.5 else 0.0) + (_hash2(gx, gz, 13) - 0.5) * 0.10
			var r_size := _hash2(gx, gz, 14)
			var r_kind := _hash2(gx, gz, 15)
			var r_tint := _hash2(gx, gz, 16)
			var r_pal := int(_hash2(gx, gz, 17) * 5.0) % 5

			var min_elev := minf(elev, minf(minf(ex, ex2), minf(ez, ez2)))
			var wy := min_elev * land_scale - 0.0006
			var s := (0.0102 + r_size * 0.0040) * (1.10 if in_city_core else 0.92)
			var sy := s * (0.88 + r_size * 0.34)
			var tint := 0.82 + r_tint * 0.20
			var pal_col := Color(0.95, 0.88, 0.76)
			if r_pal == 1:
				pal_col = Color(0.89, 0.87, 0.83)
			elif r_pal == 2:
				pal_col = Color(0.93, 0.83, 0.75)
			elif r_pal == 3:
				pal_col = Color(0.83, 0.85, 0.87)
			elif r_pal == 4:
				pal_col = Color(0.86, 0.88, 0.81)
			var bcol := Color(pal_col.r * tint, pal_col.g * tint, pal_col.b * tint)
			var xf := Transform3D(Basis(Vector3.UP, -q_yaw).scaled(Vector3(s, sy, s)), Vector3(wx, wy, wz))
			var facade_style := float(int(_hash2(gx, gz, 21) * 4.0) % 4)
			var roof_style := float(int(_hash2(gx, gz, 22) * 3.0) % 3)
			var b_cust := Color(facade_style, roof_style, _hash2(gx, gz, 23), _hash2(gx, gz, 24))

			if is_med:
				if vl_cnt < MAX_VILLA:
					vl_mm.set_instance_transform(vl_cnt, xf)
					vl_mm.set_instance_color(vl_cnt, bcol)
					vl_mm.set_instance_custom_data(vl_cnt, b_cust)
					vl_cnt += 1
			elif elev > 600.0 and r_kind < 0.58:
				if ch_cnt < MAX_CHALET:
					ch_mm.set_instance_transform(ch_cnt, xf)
					ch_mm.set_instance_color(ch_cnt, bcol)
					ch_mm.set_instance_custom_data(ch_cnt, b_cust)
					ch_cnt += 1
			elif in_city_core and r_kind < 0.28:
				if cr_cnt < MAX_CORNER:
					cr_mm.set_instance_transform(cr_cnt, xf)
					cr_mm.set_instance_color(cr_cnt, bcol)
					cr_mm.set_instance_custom_data(cr_cnt, b_cust)
					cr_cnt += 1
			elif in_city_core and r_kind < 0.64:
				if mn_cnt < MAX_MANSARD:
					mn_mm.set_instance_transform(mn_cnt, xf)
					mn_mm.set_instance_color(mn_cnt, bcol)
					mn_mm.set_instance_custom_data(mn_cnt, b_cust)
					mn_cnt += 1
			else:
				if th_cnt < MAX_TOWNHOUSE:
					th_mm.set_instance_transform(th_cnt, xf)
					th_mm.set_instance_color(th_cnt, bcol)
					th_mm.set_instance_custom_data(th_cnt, b_cust)
					th_cnt += 1

			# Organic ground integration: slope-aligned contact-AO + courtyard/garden pad under every house
			if yd_cnt < MAX_YARD:
				var tn := Vector3((ex2 - ex) * land_scale, 2.0 * 0.022, (ez2 - ez) * land_scale).normalized()
				var y_fwd := Vector3(cos(q_yaw), 0.0, sin(q_yaw))
				y_fwd = (y_fwd - tn * y_fwd.dot(tn)).normalized()
				var y_right := tn.cross(y_fwd).normalized()
				var y_basis := Basis(y_right * (s * 2.05), tn, y_fwd * (s * 1.75))
				var y_pos := Vector3(wx, elev * land_scale, wz) + tn * 0.00045
				var yard_style := 0.0 if in_city_core else float(int(_hash2(gx, gz, 41) * 3.0) % 3)
				yd_mm.set_instance_transform(yd_cnt, Transform3D(y_basis, y_pos))
				yd_mm.set_instance_color(yd_cnt, Color.WHITE)
				yd_mm.set_instance_custom_data(yd_cnt, Color(yard_style, 0.0, _hash2(gx, gz, 42), _hash2(gx, gz, 43)))
				yd_cnt += 1

			# Lush garden hedges / bushes hugging house corners to break up the geometric wall-ground seam!
			var h_sh := _hash2(gx, gz, 51)
			if h_sh < 0.72 and gs_cnt < MAX_GARDEN_SHRUB:
				var c_ang := q_yaw + (0.65 if h_sh < 0.36 else -2.35) + (_hash2(gx, gz, 52) - 0.5) * 0.5
				var c_dist := s * (0.62 + _hash2(gx, gz, 53) * 0.24)
				var sx := wx + cos(c_ang) * c_dist
				var sz := wz + sin(c_ang) * c_dist
				var s_elev: float = world_ref.sample_elevation_m(sx, sz)
				var swy := s_elev * land_scale - 0.0008
				var sc := s * (0.52 + _hash2(gx, gz, 54) * 0.36)
				var sy_sh := sc * (0.82 + _hash2(gx, gz, 55) * 0.32)
				var g_tint := 0.72 + _hash2(gx, gz, 56) * 0.26
				var scol := Color(0.56 * g_tint, 0.74 * g_tint, 0.44 * g_tint)
				var sxf := Transform3D(Basis(Vector3.UP, _hash2(gx, gz, 57) * TAU).scaled(Vector3(sc, sy_sh, sc)), Vector3(sx, swy, sz))
				gs_mm.set_instance_transform(gs_cnt, sxf)
				gs_mm.set_instance_color(gs_cnt, scol)
				gs_cnt += 1
				# Second smaller hedge cluster on opposite corner for ~40% of houses
				if h_sh < 0.34 and gs_cnt < MAX_GARDEN_SHRUB:
					var c_ang2 := c_ang + PI * (0.85 + _hash2(gx, gz, 58) * 0.30)
					var sx2 := wx + cos(c_ang2) * (s * 0.66)
					var sz2 := wz + sin(c_ang2) * (s * 0.66)
					var swy2: float = world_ref.sample_elevation_m(sx2, sz2) * land_scale - 0.0008
					var sc2 := sc * 0.80
					var sxf2 := Transform3D(Basis(Vector3.UP, _hash2(gx, gz, 59) * TAU).scaled(Vector3(sc2, sc2 * 0.85, sc2)), Vector3(sx2, swy2, sz2))
					gs_mm.set_instance_transform(gs_cnt, sxf2)
					gs_mm.set_instance_color(gs_cnt, scol * 0.92)
					gs_cnt += 1

			# Occasional backyard / courtyard broadleaf tree nestled among houses
			var h_tr := _hash2(gx, gz, 61)
			if h_tr < (0.14 if in_city_core else 0.24) and gt_cnt < MAX_GARDEN_TREE:
				var t_ang := q_yaw + PI * (0.5 if _hash2(gx, gz, 62) > 0.5 else -0.5) + (_hash2(gx, gz, 63) - 0.5) * 0.7
				var t_dist := s * (0.88 + _hash2(gx, gz, 64) * 0.25)
				var tx := wx + cos(t_ang) * t_dist
				var tz := wz + sin(t_ang) * t_dist
				if not (rail_ref and rail_ref.is_near_railway(Vector2(tx, tz), 0.026, 0.044)):
					var twy: float = world_ref.sample_elevation_m(tx, tz) * land_scale - 0.0018
					var ts := 0.0058 + _hash2(gx, gz, 65) * 0.0032
					var t_tint := 0.76 + _hash2(gx, gz, 66) * 0.24
					var tcol := Color(0.58 * t_tint, 0.76 * t_tint, 0.46 * t_tint)
					var txf := Transform3D(Basis(Vector3.UP, _hash2(gx, gz, 67) * TAU).scaled(Vector3(ts, ts * (0.90 + _hash2(gx, gz, 68) * 0.22), ts)), Vector3(tx, twy, tz))
					gt_mm.set_instance_transform(gt_cnt, txf)
					gt_mm.set_instance_color(gt_cnt, tcol)
					gt_cnt += 1

	th_mm.visible_instance_count = th_cnt
	mn_mm.visible_instance_count = mn_cnt
	vl_mm.visible_instance_count = vl_cnt
	ch_mm.visible_instance_count = ch_cnt
	cr_mm.visible_instance_count = cr_cnt
	pl_mm.visible_instance_count = pl_cnt
	yd_mm.visible_instance_count = yd_cnt
	gs_mm.visible_instance_count = gs_cnt
	gt_mm.visible_instance_count = gt_cnt
