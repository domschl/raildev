extends Node3D

# Camera-centered streaming 3D city buildings + station-connected forecourt districts.
# Renders thousands of micro-scale European townhouses, mansard blocks & landmark spires
# in 4 GPU MultiMesh draw calls, organically aligned around stations & real Sentinel-2 city footprints.

const CELL_SIZE := 0.0132       # Dense European block spacing (~190m micro-scale grid)
const BUBBLE_RADIUS := 0.92     # Stream radius around camera focus point
const REBUILD_MOVE_DIST := 0.12
const ZOOM_SHOW_MAX := 7.2      # Start fading in city buildings below this camera distance
const ZOOM_FULL_DIST := 2.6     # Full scale below this camera distance

const MAX_TOWNHOUSE := 3400
const MAX_MANSARD := 2600
const MAX_VILLA := 1800
const MAX_PLAZA := 120

var world_ref: Node3D = null
var rail_ref: Node3D = null

var mm_townhouse: MultiMeshInstance3D = null
var mm_mansard: MultiMeshInstance3D = null
var mm_villa: MultiMeshInstance3D = null
var mm_plaza: MultiMeshInstance3D = null
var urban_mat: ShaderMaterial = null

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

	mm_townhouse = _make_mm("StreamTownhouse", world._load_glb_mesh("res://assets/models/bldg_north_townhouse.glb"), MAX_TOWNHOUSE)
	mm_mansard = _make_mm("StreamMansard", world._load_glb_mesh("res://assets/models/bldg_north_mansard.glb"), MAX_MANSARD)
	mm_villa = _make_mm("StreamVilla", world._load_glb_mesh("res://assets/models/bldg_med_villa.glb"), MAX_VILLA)

	# Cobblestone station forecourt apron mesh
	var pmesh := BoxMesh.new()
	pmesh.size = Vector3(1.0, 0.08, 1.0)
	mm_plaza = _make_mm("StreamStationPlazas", pmesh, MAX_PLAZA)


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
	inst.material_override = urban_mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
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
		mm_plaza.visible = should_show
	if not should_show:
		return

	urban_mat.set_shader_parameter("bubble_center", Vector3(cam_target.x, 0.0, cam_target.z))
	urban_mat.set_shader_parameter("zoom_fade", zoom_fade)

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
	var pl_mm := mm_plaza.multimesh
	var th_cnt := 0
	var mn_cnt := 0
	var vl_cnt := 0
	var pl_cnt := 0

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
				Vector2(-0.028, plaza_off + 0.019),
				Vector2(-0.014, plaza_off + 0.021),
				Vector2( 0.000, plaza_off + 0.022),
				Vector2( 0.014, plaza_off + 0.021),
				Vector2( 0.028, plaza_off + 0.019),
				Vector2(-0.034, plaza_off + 0.003),
				Vector2( 0.034, plaza_off + 0.003),
				Vector2(-0.022, plaza_off + 0.034),
				Vector2( 0.000, plaza_off + 0.035),
				Vector2( 0.022, plaza_off + 0.034),
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
				if rail_ref.is_near_railway(bp, 0.020, 0.024):
					continue
				var belev: float = world_ref.sample_elevation_m(bp.x, bp.y)
				if belev < 2.0 or belev > 1850.0:
					continue
				var bwy := belev * land_scale - 0.0020
				var s := 0.0074 + _hash2(si * 31 + oi, 7, 1) * 0.0020
				var sy := s * (0.95 + _hash2(si * 31 + oi, 7, 2) * 0.28)
				var bcol: Color = palette[(si * 7 + oi) % palette.size()] * (0.88 + _hash2(si * 31 + oi, 7, 3) * 0.16)
				var bxf := Transform3D(Basis(Vector3.UP, -ang).scaled(Vector3(s, sy, s)), Vector3(bp.x, bwy, bp.y))
				if oi % 2 == 0 and mn_cnt < MAX_MANSARD:
					mn_mm.set_instance_transform(mn_cnt, bxf)
					mn_mm.set_instance_color(mn_cnt, bcol)
					mn_cnt += 1
				elif th_cnt < MAX_TOWNHOUSE:
					th_mm.set_instance_transform(th_cnt, bxf)
					th_mm.set_instance_color(th_cnt, bcol)
					th_cnt += 1

	# 2. Real-Footprint Streaming City Buildings across Sentinel-2 Urban Areas!
	var gx0 := int(floor((center.x - BUBBLE_RADIUS) / CELL_SIZE))
	var gx1 := int(ceil((center.x + BUBBLE_RADIUS) / CELL_SIZE))
	var gz0 := int(floor((center.y - BUBBLE_RADIUS) / CELL_SIZE))
	var gz1 := int(ceil((center.y + BUBBLE_RADIUS) / CELL_SIZE))

	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var jx := (_hash2(gx, gz, 11) - 0.5) * 0.62
			var jz := (_hash2(gx, gz, 12) - 0.5) * 0.62
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

			# Avoid steep slopes
			var ex: float = world_ref.sample_elevation_m(wx + 0.02, wz)
			var ez: float = world_ref.sample_elevation_m(wx, wz + 0.02)
			if maxf(absf(ex - elev), absf(ez - elev)) > 26.0:
				continue

			# Keep railway tracks & stations cleanly clear!
			if rail_ref and rail_ref.is_near_railway(Vector2(wx, wz), 0.024, 0.042):
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

			var wy := elev * land_scale - 0.0020
			var s := (0.0064 + r_size * 0.0026) * (1.10 if in_city_core else 0.92)
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

			if is_med:
				if vl_cnt < MAX_VILLA:
					vl_mm.set_instance_transform(vl_cnt, xf)
					vl_mm.set_instance_color(vl_cnt, bcol)
					vl_cnt += 1
			elif in_city_core and r_kind < 0.58:
				if mn_cnt < MAX_MANSARD:
					mn_mm.set_instance_transform(mn_cnt, xf)
					mn_mm.set_instance_color(mn_cnt, bcol)
					mn_cnt += 1
			else:
				if th_cnt < MAX_TOWNHOUSE:
					th_mm.set_instance_transform(th_cnt, xf)
					th_mm.set_instance_color(th_cnt, bcol)
					th_cnt += 1

	th_mm.visible_instance_count = th_cnt
	mn_mm.visible_instance_count = mn_cnt
	vl_mm.visible_instance_count = vl_cnt
	pl_mm.visible_instance_count = pl_cnt
