extends Node3D

enum ToolMode { INSPECT, BUILD_STATION, BUILD_TRACK, PLACE_SIGNAL, DEMOLISH }
enum SignalType { BLOCK, ONE_WAY, CHAIN }
enum SimSpeed { PAUSED, REAL, FAST, TURBO, ULTRA }

const STATION_COST := 25000
const STATION_UPGRADE_COST := 20000
const SIGNAL_COST := 1200
const TRAIN_COST := 35000
const TRAIN_UPKEEP_MONTHLY := 1200
const STATION_UPKEEP_MONTHLY := 150
const DOUBLE_TRACK_OFFSET := 0.022
const STATION_SCALE := 0.034
const STATION_HALF_LEN := 0.042
const KM_PER_UNIT := 15.0
const TRAIN_SCALE := 0.028
const CARRIAGE_SPACING := 0.038

var world_ref: Node3D = null
var camera_zoom_dist: float = 40.0
var _last_zoom_applied: float = -1.0

# Economy & Calendar Clock (1835 start)
var treasury: int = 500000
var sim_speed: int = SimSpeed.REAL
var last_active_speed: int = SimSpeed.REAL
var sim_day_accum: float = 0.0
var year: int = 1835
var month: int = 5
var day: int = 1

# Build State
var tool: int = ToolMode.INSPECT
var double_track: bool = false
var station_two_track: bool = false
var auto_signal: bool = true
var signal_type: int = SignalType.ONE_WAY
var station_angle: float = 0.0
var track_curve_angle: float = 0.0

var has_track_start: bool = false
var track_start_pos: Vector2 = Vector2.ZERO
var track_start_node_id: int = 0
var track_start_node_id2: int = 0
var track_start_split_edge_id: int = 0
var track_start_split_t: float = 0.0
var track_start_split_edge_id2: int = 0
var track_start_split_t2: float = 0.0
var hover_node_id: int = 0
var hover_node_id2: int = 0
var hover_edge_id: int = 0
var hover_edge_t: float = 0.0
var hover_edge_id2: int = 0
var hover_edge_t2: float = 0.0
var hover_station_idx: int = -1
var hover_station_city_idx: int = -1
var live_preview: Dictionary = {}
var live_preview2: Dictionary = {}

# Graph & Economy Data
var next_id: int = 1
var nodes: Dictionary = {}      # id -> {id, pos: Vector2, edges: Array[int], station_id: int}
var edges: Dictionary = {}      # id -> {id, node_a, node_b, p0, c1, c2, p1, pts: Array[Vector3], cum_dist, length_km, max_grade, has_bridge, has_tunnel, t_entry, t_exit, direction, signals: Array, mesh_node}
var stations: Array = []        # Array of {id, name, pos: Vector2, angle, city_idx, node_a, node_b, mesh_node}
var lines: Array = []           # Array of {id, name, st_a, st_b, route_ab, route_ba, total_km, revenue_total, train_count}
var trains: Array = []          # Active 3D passenger trains
var collision_count: int = 0
var collision_log: Array[String] = []
var city_waiting_pax: Dictionary = {}   # city_idx -> float
var city_growth_accum: Dictionary = {}  # city_idx -> float
var floating_popups: Array = []         # {node: Label3D, age: float}
var steam_puffs: Array = []             # {node: MeshInstance3D, age: float, vel: Vector3}

# Cached 3D meshes & preview nodes
var mesh_station: Mesh = null
var mesh_station_2track: Mesh = null
var mesh_signal: Mesh = null
var mesh_tunnel_portal: Mesh = null
var mesh_locomotive: Mesh = null
var mesh_carriage: Mesh = null
var mesh_steam_puff: SphereMesh = null
var mat_steam_puff: StandardMaterial3D = null

var mat_solid: Material = null
var mat_tunnel_guide: StandardMaterial3D = null
var mat_ghost_ok: StandardMaterial3D = null
var mat_ghost_warn: StandardMaterial3D = null
var mat_ghost_bad: StandardMaterial3D = null

var preview_station_inst: MeshInstance3D = null
var preview_track_inst: MeshInstance3D = null
var preview_track_inst2: MeshInstance3D = null
var snap_ring_inst: MeshInstance3D = null
var snap_ring_inst2: MeshInstance3D = null
var city_catchment_ring_inst: MeshInstance3D = null


func setup_world(world: Node3D) -> void:
	world_ref = world
	mesh_station = world._load_glb_mesh("res://assets/models/rail_station.glb")
	mesh_station_2track = world._load_glb_mesh("res://assets/models/rail_station_2track.glb")
	mesh_signal = world._load_glb_mesh("res://assets/models/rail_signal.glb")
	mesh_tunnel_portal = world._load_glb_mesh("res://assets/models/rail_tunnel_portal.glb")
	mesh_locomotive = world._load_glb_mesh("res://assets/models/rail_locomotive.glb")
	mesh_carriage = world._load_glb_mesh("res://assets/models/rail_carriage.glb")

	mesh_steam_puff = SphereMesh.new()
	mesh_steam_puff.radius = 0.0055
	mesh_steam_puff.height = 0.010
	mesh_steam_puff.radial_segments = 10
	mesh_steam_puff.rings = 5
	mat_steam_puff = StandardMaterial3D.new()
	mat_steam_puff.albedo_color = Color(0.95, 0.96, 0.98, 0.52)
	mat_steam_puff.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_steam_puff.roughness = 0.96
	mat_steam_puff.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	for i in range(world.cities.size()):
		city_waiting_pax[i] = float(clampi(int(world.cities[i]["population"]) / 6000, 15, 90))
		city_growth_accum[i] = 0.0

	var rail_pbr_shader := load("res://shaders/rail_pbr.gdshader")
	if rail_pbr_shader:
		var sm := ShaderMaterial.new()
		sm.shader = rail_pbr_shader
		mat_solid = sm
	else:
		mat_solid = StandardMaterial3D.new()
		mat_solid.vertex_color_use_as_albedo = true
		mat_solid.roughness = 0.78

	mat_tunnel_guide = StandardMaterial3D.new()
	mat_tunnel_guide.vertex_color_use_as_albedo = true
	mat_tunnel_guide.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_tunnel_guide.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_tunnel_guide.no_depth_test = true
	mat_tunnel_guide.cull_mode = BaseMaterial3D.CULL_DISABLED

	mat_ghost_ok = _make_ghost_mat(Color(0.28, 0.92, 0.48, 0.75))
	mat_ghost_warn = _make_ghost_mat(Color(0.98, 0.78, 0.25, 0.78))
	mat_ghost_bad = _make_ghost_mat(Color(0.95, 0.26, 0.26, 0.78))

	preview_station_inst = MeshInstance3D.new()
	preview_station_inst.mesh = mesh_station
	preview_station_inst.material_override = mat_ghost_ok
	preview_station_inst.visible = false
	preview_station_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(preview_station_inst)

	preview_track_inst = MeshInstance3D.new()
	preview_track_inst.visible = false
	preview_track_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(preview_track_inst)

	preview_track_inst2 = MeshInstance3D.new()
	preview_track_inst2.visible = false
	preview_track_inst2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(preview_track_inst2)

	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.24
	ring_mesh.outer_radius = 0.34
	snap_ring_inst = MeshInstance3D.new()
	snap_ring_inst.mesh = ring_mesh
	snap_ring_inst.material_override = mat_ghost_warn
	snap_ring_inst.visible = false
	snap_ring_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(snap_ring_inst)

	snap_ring_inst2 = MeshInstance3D.new()
	snap_ring_inst2.mesh = ring_mesh
	snap_ring_inst2.material_override = mat_ghost_warn
	snap_ring_inst2.visible = false
	snap_ring_inst2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(snap_ring_inst2)

	var catch_mesh := TorusMesh.new()
	catch_mesh.inner_radius = 0.94
	catch_mesh.outer_radius = 1.00
	city_catchment_ring_inst = MeshInstance3D.new()
	city_catchment_ring_inst.mesh = catch_mesh
	city_catchment_ring_inst.material_override = mat_ghost_ok
	city_catchment_ring_inst.visible = false
	city_catchment_ring_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(city_catchment_ring_inst)


func _make_ghost_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	return m


func _process(delta: float) -> void:
	_update_visual_effects(delta)
	if sim_speed == SimSpeed.PAUSED:
		return
	var speed_mult := 1.0
	var day_rate := 0.25
	match sim_speed:
		SimSpeed.REAL:
			speed_mult = 1.0
			day_rate = 0.25
		SimSpeed.FAST:
			speed_mult = 15.0
			day_rate = 1.0
		SimSpeed.TURBO:
			speed_mult = 60.0
			day_rate = 3.0
		SimSpeed.ULTRA:
			speed_mult = 300.0
			day_rate = 10.0
	_update_trains(delta * speed_mult)
	sim_day_accum += delta * day_rate
	while sim_day_accum >= 1.0:
		sim_day_accum -= 1.0
		_advance_one_day()


func _advance_one_day() -> void:
	const DAYS_IN_MONTH := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	day += 1
	var max_d: int = DAYS_IN_MONTH[month - 1]
	if month == 2 and (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)):
		max_d = 29
	if day > max_d:
		day = 1
		month += 1
		if month > 12:
			month = 1
			year += 1
		# Monthly upkeep for running trains and stations
		var upkeep := trains.size() * TRAIN_UPKEEP_MONTHLY + stations.size() * STATION_UPKEEP_MONTHLY
		if upkeep > 0:
			treasury -= upkeep

	# Daily passenger generation at cities with stations
	if world_ref:
		for i in range(world_ref.cities.size()):
			var pop: float = float(world_ref.cities[i]["population"])
			var daily := clampf(pop / 28000.0, 2.0, 24.0)
			var cap := clampf(pop / 1800.0, 60.0, 260.0)
			city_waiting_pax[i] = minf(cap, float(city_waiting_pax.get(i, 0.0)) + daily)


func formatted_date() -> String:
	const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%02d %s %04d" % [day, MONTHS[month - 1], year]


func toggle_pause() -> void:
	if sim_speed == SimSpeed.PAUSED:
		sim_speed = last_active_speed if last_active_speed != SimSpeed.PAUSED else SimSpeed.REAL
	else:
		last_active_speed = sim_speed
		sim_speed = SimSpeed.PAUSED


func set_tool(new_tool: int) -> void:
	tool = new_tool
	clear_track_start()
	_hide_previews()


func clear_track_start() -> void:
	has_track_start = false
	track_start_node_id = 0
	track_start_node_id2 = 0
	track_start_split_edge_id = 0
	track_start_split_t = 0.0
	track_start_split_edge_id2 = 0
	track_start_split_t2 = 0.0
	track_curve_angle = 0.0
	live_preview = {}
	live_preview2 = {}
	if preview_track_inst:
		preview_track_inst.visible = false
	if preview_track_inst2:
		preview_track_inst2.visible = false


func _hide_previews() -> void:
	if preview_station_inst:
		preview_station_inst.visible = false
	if preview_track_inst:
		preview_track_inst.visible = false
	if preview_track_inst2:
		preview_track_inst2.visible = false
	if snap_ring_inst:
		snap_ring_inst.visible = false
	if snap_ring_inst2:
		snap_ring_inst2.visible = false
	if city_catchment_ring_inst:
		city_catchment_ring_inst.visible = false
	hover_station_city_idx = -1


func find_node_near(pos: Vector2, radius: float) -> int:
	var best_id := 0
	var best_d2 := radius * radius
	for nid in nodes.keys():
		var n = nodes[nid]
		var d2 := pos.distance_squared_to(n["pos"])
		if d2 < best_d2:
			best_d2 = d2
			best_id = nid
	return best_id


func find_edge_near(pos: Vector2, radius: float) -> Dictionary:
	var best_id := 0
	var best_t := 0.5
	var best_d2 := radius * radius
	for eid in edges.keys():
		var e = edges[eid]
		if e.get("internal", false):
			continue
		var pts: Array = e["pts"]
		var count := pts.size()
		if count < 2:
			continue
		for i in range(count):
			var p3: Vector3 = pts[i]
			var d2 := pos.distance_squared_to(Vector2(p3.x, p3.z))
			if d2 < best_d2:
				best_d2 = d2
				best_id = eid
				best_t = float(i) / float(count - 1)
	return {"edge_id": best_id, "t": best_t}


func find_station_near(pos: Vector2, radius: float) -> int:
	var best_idx := -1
	var best_d2 := radius * radius
	for i in range(stations.size()):
		var d2 := pos.distance_squared_to(stations[i]["pos"])
		if d2 < best_d2:
			best_d2 = d2
			best_idx = i
	return best_idx


func is_near_railway(world_xz: Vector2, track_clearance: float = 0.55, station_clearance: float = 1.05) -> bool:
	var st_r2 := station_clearance * station_clearance
	for st in stations:
		if world_xz.distance_squared_to(st["pos"]) < st_r2:
			return true
	var tr_r2 := track_clearance * track_clearance
	for e in edges.values():
		if e.get("internal", false):
			continue
		var pts: Array = e["pts"]
		for p3 in pts:
			var p2 := Vector2((p3 as Vector3).x, (p3 as Vector3).z)
			if world_xz.distance_squared_to(p2) < tr_r2:
				return true
	return false


func find_double_track_partner(node_id: int) -> int:
	if node_id == 0 or not nodes.has(node_id):
		return 0
	var n1 = nodes[node_id]
	if int(n1["station_id"]) != -1 or (n1["edges"] as Array).is_empty():
		return 0

	# 1. If already linked to a partner node via an internal crossover edge, return that exact partner!
	for eid in n1["edges"]:
		if edges.has(eid) and edges[eid].get("internal", false):
			var xe = edges[eid]
			var other_n: int = int(xe["node_b"]) if int(xe["node_a"]) == node_id else int(xe["node_a"])
			if nodes.has(other_n) and int(nodes[other_n]["station_id"]) == -1:
				return other_n

	# 2. Otherwise, find the closest parallel non-station track node (works for degree 1, 2, or 3+!)
	var p1: Vector2 = n1["pos"]
	var t1 := Vector2.ZERO
	for eid in n1["edges"]:
		if edges.has(eid) and not edges[eid].get("internal", false):
			var e1 = edges[eid]
			t1 = ((e1["c1"] - e1["p0"]) if int(e1["node_a"]) == node_id else (e1["c2"] - e1["p1"])).normalized()
			break
	if t1.length_squared() < 1e-6:
		return 0

	var max_d := DOUBLE_TRACK_OFFSET * 2.1
	var best_partner := 0
	var best_d := max_d
	for nid in nodes.keys():
		if nid == node_id:
			continue
		var n2 = nodes[nid]
		if int(n2["station_id"]) != -1 or (n2["edges"] as Array).is_empty():
			continue
		var d := p1.distance_to(n2["pos"])
		if d < best_d and d > 0.010:
			# Skip nodes directly connected by a real track edge
			var shared_real := false
			var t2 := Vector2.ZERO
			for e2_id in n2["edges"]:
				if not edges.has(e2_id) or edges[e2_id].get("internal", false):
					continue
				var e2 = edges[e2_id]
				if int(e2["node_a"]) == node_id or int(e2["node_b"]) == node_id:
					shared_real = true
					break
				if t2.length_squared() < 1e-6:
					t2 = ((e2["c1"] - e2["p0"]) if int(e2["node_a"]) == nid else (e2["c2"] - e2["p1"])).normalized()
			if shared_real or t2.length_squared() < 1e-6:
				continue
			# Parallel track rails have parallel or antiparallel tangents
			if absf(t1.dot(t2)) > 0.75:
				best_d = d
				best_partner = nid
	return best_partner


func find_parallel_edge_point(edge_id: int, t: float) -> Dictionary:
	if not edges.has(edge_id):
		return {"valid": false}
	var e = edges[edge_id]
	var dir: int = int(e.get("direction", 0))
	if dir == 0:
		return {"valid": false}
	var pts: Array = e["pts"]
	if pts.size() < 3:
		return {"valid": false}
	var idx := clampi(int(round(t * float(pts.size() - 1))), 1, pts.size() - 2)
	var p3: Vector3 = pts[idx]
	var p2 := Vector2(p3.x, p3.z)

	var best_eid := 0
	var best_t := 0.5
	var best_p3 := Vector3.ZERO
	var best_d2 := (DOUBLE_TRACK_OFFSET * 2.2) * (DOUBLE_TRACK_OFFSET * 2.2)
	for peid in edges.keys():
		if peid == edge_id:
			continue
		var pe = edges[peid]
		if pe.get("internal", false) or int(pe.get("direction", 0)) != -dir:
			continue
		var ppts: Array = pe["pts"]
		for pi in range(1, ppts.size() - 1):
			var pp3: Vector3 = ppts[pi]
			var d2 := p2.distance_squared_to(Vector2(pp3.x, pp3.z))
			if d2 < best_d2:
				best_d2 = d2
				best_eid = peid
				best_t = float(pi) / float(ppts.size() - 1)
				best_p3 = pp3
	if best_eid == 0:
		return {"valid": false}
	return {"valid": true, "edge_id": best_eid, "t": best_t, "p3": best_p3}


func get_edge_merge_info(edge_id: int, t: float, other_pos: Vector2, is_starting_from_edge: bool, paired_double: bool = false) -> Dictionary:
	if not edges.has(edge_id):
		return {"valid": false}
	var e = edges[edge_id]
	var pts: Array = e["pts"]
	var n := pts.size()
	if n < 2:
		return {"valid": false}
	var idx := clampi(int(round(t * float(n - 1))), 1, n - 2)
	var p3: Vector3 = pts[idx]
	var p_prev: Vector3 = pts[idx - 1]
	var p_next: Vector3 = pts[idx + 1]
	var seg_vec := Vector2(p_next.x - p_prev.x, p_next.z - p_prev.z)
	if seg_vec.length_squared() < 1e-8:
		return {"valid": false}
	var edge_tan := seg_vec.normalized()
	var hdist := maxf(1e-4, seg_vec.length())
	var edge_slope_y := (p_next.y - p_prev.y) / hdist

	var p2 := Vector2(p3.x, p3.z)
	var to_other := (other_pos - p2).normalized()

	# Align merge tangent with the shallowest angle toward other_pos on bi-directional tracks
	# and paired dual-track corridors (which carry both +1 and -1 directions!), or unidirectionally on lone 1-way tracks.
	var dir_sign := 1.0
	var edge_dir: int = int(e.get("direction", 0))
	if paired_double or edge_dir == 0:
		dir_sign = 1.0 if edge_tan.dot(to_other) >= 0.0 else -1.0
	elif edge_dir == 1:
		dir_sign = 1.0 if is_starting_from_edge else -1.0
	else:
		dir_sign = -1.0 if is_starting_from_edge else 1.0

	var merge_dir := edge_tan * dir_sign
	var merge_slope_y := clampf(edge_slope_y * dir_sign, -0.14, 0.14)
	return {
		"valid": true,
		"pos": p2,
		"dir": merge_dir,
		"y": p3.y,
		"slope_y": merge_slope_y,
		"idx": idx,
	}


func split_edge_at_t(edge_id: int, t: float, auto_crossover: bool = true) -> int:
	if not edges.has(edge_id):
		return 0
	var e = edges[edge_id]
	var pts: Array = e["pts"]
	var n := pts.size()
	if n < 4:
		return int(e["node_a"]) if t < 0.5 else int(e["node_b"])
	var idx := clampi(int(round(t * float(n - 1))), 1, n - 2)
	var split_p3: Vector3 = pts[idx]
	var split_p2 := Vector2(split_p3.x, split_p3.z)

	# Create junction node right on the existing track
	var jnode := _create_node(split_p2, -1)

	# Split sampled 3D points cleanly into part 1 [0..idx] and part 2 [idx..n-1]
	var pts1: Array[Vector3] = []
	var pts2: Array[Vector3] = []
	for i in range(0, idx + 1):
		pts1.append(pts[i])
	for i in range(idx, n):
		pts2.append(pts[i])

	var dir: int = int(e.get("direction", 0))
	var old_na: int = int(e["node_a"])
	var old_nb: int = int(e["node_b"])
	var old_len: float = float(e["length_km"])
	var frac := float(idx) / float(n - 1)

	# Detach old edge from old_na and old_nb, keeping its existing 3D mesh on edge 1
	(nodes[old_na]["edges"] as Array).erase(edge_id)
	(nodes[old_nb]["edges"] as Array).erase(edge_id)

	var make_cum := func(arr: Array[Vector3]) -> Array[float]:
		var cd: Array[float] = []
		cd.resize(arr.size())
		var acc := 0.0
		for k in range(arr.size()):
			if k > 0:
				acc += arr[k].distance_to(arr[k - 1])
			cd[k] = acc
		return cd

	var p0_1 := Vector2(pts1[0].x, pts1[0].z)
	var p1_1 := split_p2
	var tan_start: Vector2 = ((e["c1"] as Vector2) - (e["p0"] as Vector2)).normalized()
	var tan_mid := Vector2(pts[idx + 1].x - pts[idx - 1].x, pts[idx + 1].z - pts[idx - 1].z).normalized()
	var d1 := p0_1.distance_to(p1_1)
	var d2 := split_p2.distance_to(Vector2(pts2[pts2.size() - 1].x, pts2[pts2.size() - 1].z))

	# Reuse edge_id for first half (keeps original mesh_node & signals visually intact!)
	var old_c2: Vector2 = e["c2"]
	var old_p1: Vector2 = e["p1"]
	e["node_b"] = jnode
	e["p1"] = p1_1
	e["c1"] = p0_1 + tan_start * (d1 * 0.33)
	e["c2"] = p1_1 - tan_mid * (d1 * 0.33)
	e["pts"] = pts1
	e["cum_dist"] = make_cum.call(pts1)
	e["length_km"] = maxf(1.0, old_len * frac)
	(nodes[old_na]["edges"] as Array).append(edge_id)
	(nodes[jnode]["edges"] as Array).append(edge_id)

	# Create second half edge (mesh already rendered by edge_id's mesh_node)
	var eid2 := next_id
	next_id += 1
	var p1_2 := Vector2(pts2[pts2.size() - 1].x, pts2[pts2.size() - 1].z)
	var tan_end: Vector2 = (old_c2 - old_p1).normalized()
	edges[eid2] = {
		"id": eid2, "node_a": jnode, "node_b": old_nb,
		"p0": split_p2, "c1": split_p2 + tan_mid * (d2 * 0.33),
		"c2": p1_2 + tan_end * (d2 * 0.33), "p1": p1_2,
		"pts": pts2, "cum_dist": make_cum.call(pts2),
		"length_km": maxf(1.0, old_len * (1.0 - frac)),
		"max_grade": e["max_grade"], "has_bridge": e["has_bridge"], "has_tunnel": e["has_tunnel"],
		"t_entry": -1, "t_exit": -1, "direction": dir,
		"internal": false, "signals": [], "mesh_node": null, "split_sibling": edge_id,
	}
	(nodes[jnode]["edges"] as Array).append(eid2)
	(nodes[old_nb]["edges"] as Array).append(eid2)

	# Re-arrange signals cleanly on BOTH halves around the new junction/merge point!
	_resignal_edge(edge_id, false, true)
	_resignal_edge(eid2, true, false)

	# Splice eid2 seamlessly into all existing lines & running trains so NO train ever teleports!
	_splice_split_edge_into_routes(edge_id, eid2)

	# If splitting a one-way double-track rail, automatically link a crossover switch to its
	# opposite-direction parallel rail so branch lines can route both ways across the mesh!
	if auto_crossover and dir != 0:
		var best_pe := 0
		var best_pt := 0.5
		var best_d2 := (DOUBLE_TRACK_OFFSET * 2.2) * (DOUBLE_TRACK_OFFSET * 2.2)
		for peid in edges.keys():
			if peid == edge_id or peid == eid2:
				continue
			var pe = edges[peid]
			if pe.get("internal", false) or int(pe.get("direction", 0)) != -dir:
				continue
			var ppts: Array = pe["pts"]
			for pi in range(1, ppts.size() - 1):
				var pp3: Vector3 = ppts[pi]
				var d2p := split_p2.distance_squared_to(Vector2(pp3.x, pp3.z))
				if d2p < best_d2:
					best_d2 = d2p
					best_pe = peid
					best_pt = float(pi) / float(ppts.size() - 1)
		if best_pe != 0:
			var jnode2 := split_edge_at_t(best_pe, best_pt, false)
			_link_crossover_nodes(jnode, jnode2)

	if auto_crossover:
		_cleanup_junction_signals()

	return jnode


func _link_crossover_nodes(jnode: int, jnode2: int) -> void:
	if jnode == 0 or jnode2 == 0 or jnode == jnode2 or not nodes.has(jnode) or not nodes.has(jnode2):
		return
	var p2_a: Vector2 = nodes[jnode]["pos"]
	var p2_b: Vector2 = nodes[jnode2]["pos"]
	var wy: float = world_ref.sample_world_y(p2_a.x, p2_a.y)
	var xpts: Array[Vector3] = [Vector3(p2_a.x, wy, p2_a.y), Vector3(p2_b.x, wy, p2_b.y)]
	var xid := next_id
	next_id += 1
	edges[xid] = {
		"id": xid, "node_a": jnode, "node_b": jnode2,
		"p0": p2_a, "c1": p2_a.lerp(p2_b, 0.33),
		"c2": p2_a.lerp(p2_b, 0.67), "p1": p2_b,
		"pts": xpts, "cum_dist": [0.0, xpts[0].distance_to(xpts[1])],
		"length_km": 0.5, "max_grade": 0.0,
		"has_bridge": false, "has_tunnel": false,
		"t_entry": -1, "t_exit": -1, "direction": 0,
		"internal": true, "signals": [], "mesh_node": null,
	}
	(nodes[jnode]["edges"] as Array).append(xid)
	(nodes[jnode2]["edges"] as Array).append(xid)


func _splice_split_edge_into_routes(eid1: int, eid2: int) -> void:
	if not edges.has(eid1) or not edges.has(eid2):
		return
	var e1 = edges[eid1]
	var e2 = edges[eid2]
	var len1_km: float = float(e1["length_km"])
	var len2_km: float = float(e2["length_km"])
	var cum1: Array = e1["cum_dist"]
	var cum2: Array = e2["cum_dist"]
	var len1_u: float = float(cum1[cum1.size() - 1]) if not cum1.is_empty() else 0.0
	var len2_u: float = float(cum2[cum2.size() - 1]) if not cum2.is_empty() else 0.0

	var splice_arr := func(segs: Array) -> Array:
		var out: Array = []
		for seg in segs:
			if int(seg["edge_id"]) == eid1:
				var fwd: bool = bool(seg["forward"])
				if fwd:
					out.append({"edge_id": eid1, "forward": true, "length_km": len1_km})
					out.append({"edge_id": eid2, "forward": true, "length_km": len2_km})
				else:
					out.append({"edge_id": eid2, "forward": false, "length_km": len2_km})
					out.append({"edge_id": eid1, "forward": false, "length_km": len1_km})
			else:
				out.append(seg)
		return out

	for l in lines:
		l["route_ab"] = splice_arr.call(l["route_ab"])
		l["route_ba"] = splice_arr.call(l["route_ba"])

	for tr in trains:
		var old_segs: Array = tr["segs"]
		var cur_idx: int = int(tr["seg_idx"])
		var cur_d: float = float(tr["dist_u"])
		var new_segs: Array = []
		var new_idx := cur_idx
		var new_d := cur_d
		for i in range(old_segs.size()):
			var seg = old_segs[i]
			if int(seg["edge_id"]) == eid1:
				var fwd: bool = bool(seg["forward"])
				if i < cur_idx:
					new_idx += 1
				elif i == cur_idx:
					if fwd:
						if cur_d > len1_u:
							new_idx += 1
							new_d = maxf(0.0, cur_d - len1_u)
					else:
						# Backward: eid2 comes first, then eid1
						if cur_d > len2_u:
							new_idx += 1
							new_d = maxf(0.0, cur_d - len2_u)
				if fwd:
					new_segs.append({"edge_id": eid1, "forward": true, "length_km": len1_km})
					new_segs.append({"edge_id": eid2, "forward": true, "length_km": len2_km})
				else:
					new_segs.append({"edge_id": eid2, "forward": false, "length_km": len2_km})
					new_segs.append({"edge_id": eid1, "forward": false, "length_km": len1_km})
			else:
				new_segs.append(seg)
		tr["segs"] = new_segs
		tr["seg_idx"] = clampi(new_idx, 0, maxi(0, new_segs.size() - 1))
		tr["dist_u"] = new_d


func _resignal_edge(edge_id: int, junc_at_start: bool, junc_at_end: bool) -> void:
	if not edges.has(edge_id):
		return
	var e = edges[edge_id]
	if e.get("internal", false):
		return
	# Clear old signals cleanly so none remain misplaced or sitting on the switch
	for sig in e["signals"]:
		if sig["node"] != null and is_instance_valid(sig["node"]):
			sig["node"].queue_free()
	e["signals"] = []

	var dir: int = int(e.get("direction", 0))
	var len_km: float = float(e["length_km"])
	if len_km < 22.0:
		return  # Keep short triangle/junction links clean & uncluttered!

	if dir != 0:
		# Consistent green One-Way signals (no extra blue Chain clutter inside triangles),
		# placed only at the arrival/approach end + evenly spaced intermediate blocks
		var t_min := 0.16 if junc_at_start else 0.10
		var t_max := 0.84 if junc_at_end else 0.90
		if dir > 0:
			add_signal(edge_id, 0.86 if junc_at_end else 0.93, SignalType.ONE_WAY, dir)
		else:
			add_signal(edge_id, 0.14 if junc_at_start else 0.07, SignalType.ONE_WAY, dir)
		var cnt := clampi(int(floor(len_km / 48.0)), 0, 8)
		for i in range(1, cnt + 1):
			var t := float(i) / float(cnt + 1)
			if t > t_min + 0.08 and t < t_max - 0.08:
				add_signal(edge_id, t, SignalType.ONE_WAY, dir)
	elif len_km >= 35.0:
		var cnt := clampi(int(floor(len_km / 65.0)), 1, 6)
		for i in range(1, cnt + 1):
			var t := float(i) / float(cnt + 1)
			if t > 0.18 and t < 0.82:
				add_signal(edge_id, t, SignalType.BLOCK, 1)


func _cleanup_junction_signals() -> void:
	# Remove ANY signal sitting too close to a junction node (degree >= 3) or right at a junction exit
	# so trains NEVER stop inside a switch or leave stray signals clustered around triangles!
	var junc_positions: Array[Vector2] = []
	for nid in nodes.keys():
		var n = nodes[nid]
		if int(n["station_id"]) == -1 and (n["edges"] as Array).size() >= 3:
			junc_positions.append(n["pos"])
	if junc_positions.is_empty():
		return

	const CLEAR_RADIUS := 0.35  # Full micro-scale train-length + smooth Y-turnout clearance around every switch
	for eid in edges.keys():
		var e = edges[eid]
		var sigs: Array = e["signals"]
		for i in range(sigs.size() - 1, -1, -1):
			var sig = sigs[i]
			var snode: Node3D = sig["node"]
			if snode == null or not is_instance_valid(snode):
				sigs.remove_at(i)
				continue
			var sp2 := Vector2(snode.position.x, snode.position.z)
			var too_close := false
			for jp in junc_positions:
				if sp2.distance_to(jp) < CLEAR_RADIUS:
					too_close = true
					break
			if too_close:
				snode.queue_free()
				sigs.remove_at(i)


func demolish_edge(edge_id: int) -> void:
	if not edges.has(edge_id):
		return
	var e = edges[edge_id]
	if e.get("internal", false):
		return
	# Refund 50% of base track cost
	var refund := maxi(500, int(round(float(e["length_km"]) * 120.0)))
	treasury += refund
	var pts: Array = e["pts"]
	if not pts.is_empty():
		var mid: Vector3 = pts[pts.size() / 2]
		_spawn_floating_popup(mid + Vector3(0, 0.5, 0), "+£%d (Demolished)" % refund, Color(1.0, 0.72, 0.40))

	if e["mesh_node"] != null and is_instance_valid(e["mesh_node"]):
		e["mesh_node"].queue_free()
	for sig in e["signals"]:
		if sig["node"] != null and is_instance_valid(sig["node"]):
			sig["node"].queue_free()

	var na: int = int(e["node_a"])
	var nb: int = int(e["node_b"])
	if nodes.has(na):
		(nodes[na]["edges"] as Array).erase(edge_id)
		if (nodes[na]["edges"] as Array).is_empty() and int(nodes[na]["station_id"]) == -1:
			nodes.erase(na)
	if nodes.has(nb):
		(nodes[nb]["edges"] as Array).erase(edge_id)
		if (nodes[nb]["edges"] as Array).is_empty() and int(nodes[nb]["station_id"]) == -1:
			nodes.erase(nb)

	edges.erase(edge_id)
	_revalidate_lines_and_trains()


func demolish_station(st_idx: int) -> void:
	if st_idx < 0 or st_idx >= stations.size():
		return
	var st = stations[st_idx]
	var refund := STATION_COST / 2
	treasury += refund
	var st_pos: Vector2 = st["pos"]
	var wy: float = world_ref.sample_world_y(st_pos.x, st_pos.y)
	_spawn_floating_popup(Vector3(st_pos.x, wy + 0.6, st_pos.y), "+£%d (Station Removed)" % refund, Color(1.0, 0.72, 0.40))

	if st["mesh_node"] != null and is_instance_valid(st["mesh_node"]):
		st["mesh_node"].queue_free()

	# Remove internal station edge and detach throat nodes
	for nid in [int(st["node_a"]), int(st["node_b"])]:
		if nodes.has(nid):
			nodes[nid]["station_id"] = -1
			var e_copy := (nodes[nid]["edges"] as Array).duplicate()
			for eid in e_copy:
				if edges.has(eid) and edges[eid].get("internal", false):
					(nodes[nid]["edges"] as Array).erase(eid)
					edges.erase(eid)
			if (nodes[nid]["edges"] as Array).is_empty():
				nodes.erase(nid)

	# Remove any lines & trains referencing this station, and shift higher station indices down
	for li in range(lines.size() - 1, -1, -1):
		var l = lines[li]
		if int(l["st_a"]) == st_idx or int(l["st_b"]) == st_idx:
			_remove_line_and_trains(int(l["id"]))
		else:
			if int(l["st_a"]) > st_idx:
				l["st_a"] = int(l["st_a"]) - 1
			if int(l["st_b"]) > st_idx:
				l["st_b"] = int(l["st_b"]) - 1

	stations.remove_at(st_idx)
	_revalidate_lines_and_trains()


func _remove_line_and_trains(line_id: int) -> void:
	for ti in range(trains.size() - 1, -1, -1):
		var tr = trains[ti]
		if int(tr["line_id"]) == line_id:
			if is_instance_valid(tr["loco"]):
				tr["loco"].queue_free()
			for c in tr["coaches"]:
				if is_instance_valid(c):
					c.queue_free()
			trains.remove_at(ti)
	for li in range(lines.size() - 1, -1, -1):
		if int(lines[li]["id"]) == line_id:
			lines.remove_at(li)


func _recalculate_all_line_routes() -> void:
	# Recompute shortest valid routes for all existing passenger lines whenever new tracks are added,
	# seamlessly switching active trains onto shorter routes without teleporting!
	for l in lines:
		var ab := find_station_route(int(l["st_a"]), int(l["st_b"]))
		var ba := find_station_route(int(l["st_b"]), int(l["st_a"]))
		if not (ab["valid"] and ba["valid"]):
			continue
		l["route_ab"] = ab["segs"]
		l["route_ba"] = ba["segs"]
		l["total_km"] = float(ab["km"])
		var lid: int = int(l["id"])
		for tr in trains:
			if int(tr["line_id"]) != lid:
				continue
			var new_segs: Array = l["route_ab"] if bool(tr["going_to_b"]) else l["route_ba"]
			if new_segs.is_empty():
				continue
			# If loading at station, switch immediately
			if String(tr["state"]) == "LOADING" and int(tr["seg_idx"]) == 0 and float(tr["dist_u"]) < 0.01:
				tr["segs"] = new_segs
				tr["seg_idx"] = 0
				continue
			# If mid-journey and our current (edge_id, forward) is on the new route, switch seamlessly in-place!
			var old_segs: Array = tr["segs"]
			var old_idx: int = int(tr["seg_idx"])
			if old_idx >= 0 and old_idx < old_segs.size():
				var cur_eid: int = int(old_segs[old_idx]["edge_id"])
				var cur_fwd: bool = bool(old_segs[old_idx]["forward"])
				for ni in range(new_segs.size()):
					if int(new_segs[ni]["edge_id"]) == cur_eid and bool(new_segs[ni]["forward"]) == cur_fwd:
						tr["segs"] = new_segs
						tr["seg_idx"] = ni
						break
				# Otherwise, let the train finish its current leg on old_segs; it will adopt the new route on arrival.


func _revalidate_lines_and_trains() -> void:
	# Re-route existing lines across the current mesh; remove lines that lost connectivity
	for li in range(lines.size() - 1, -1, -1):
		var l = lines[li]
		var ab := find_station_route(int(l["st_a"]), int(l["st_b"]))
		var ba := find_station_route(int(l["st_b"]), int(l["st_a"]))
		if ab["valid"] and ba["valid"]:
			l["route_ab"] = ab["segs"]
			l["route_ba"] = ba["segs"]
			l["total_km"] = float(ab["km"])
			for tr in trains:
				if int(tr["line_id"]) == int(l["id"]):
					tr["segs"] = l["route_ab"] if bool(tr["going_to_b"]) else l["route_ba"]
					tr["seg_idx"] = clampi(int(tr["seg_idx"]), 0, maxi(0, (tr["segs"] as Array).size() - 1))
		else:
			_remove_line_and_trains(int(l["id"]))


func get_node_tangent(node_id: int, toward: Vector2) -> Dictionary:
	if not nodes.has(node_id):
		return {"valid": false, "dir": Vector2.RIGHT, "has_y": false, "y": 0.0, "slope_y": 0.0}
	var n = nodes[node_id]
	var n_edges: Array = n["edges"]
	if n_edges.is_empty():
		return {"valid": false, "dir": Vector2.RIGHT, "has_y": false, "y": 0.0, "slope_y": 0.0}

	var n_pos: Vector2 = n["pos"]
	var to_target: Vector2 = (toward - n_pos).normalized()
	var best_dir := Vector2.ZERO
	var best_dot := -2.0
	var best_y := 0.0
	var best_slope_y := 0.0
	var found_y := false
	for eid in n_edges:
		if not edges.has(eid):
			continue
		var e = edges[eid]
		var tan_v := Vector2.ZERO
		var e_y := 0.0
		var e_slope_y := 0.0
		var e_pts: Array = e["pts"]
		if e["node_a"] == node_id:
			tan_v = (e["c1"] - e["p0"]).normalized()
			if e_pts.size() >= 2:
				var p0: Vector3 = e_pts[0]
				var p1: Vector3 = e_pts[1]
				var hdist := maxf(1e-4, Vector2(p1.x - p0.x, p1.z - p0.z).length())
				e_y = p0.y
				# Outgoing continuation goes opposite to p0->p1, so slope reverses sign
				e_slope_y = -(p1.y - p0.y) / hdist
		else:
			tan_v = (e["c2"] - e["p1"]).normalized()
			if e_pts.size() >= 2:
				var p_end: Vector3 = e_pts[e_pts.size() - 1]
				var p_prev: Vector3 = e_pts[e_pts.size() - 2]
				var hdist := maxf(1e-4, Vector2(p_end.x - p_prev.x, p_end.z - p_prev.z).length())
				e_y = p_end.y
				e_slope_y = (p_end.y - p_prev.y) / hdist
		# Outgoing continuation is opposite to incoming edge tangent
		var cont := -tan_v
		var d := cont.dot(to_target)
		if d > best_dot:
			best_dot = d
			best_dir = cont
			best_y = e_y
			best_slope_y = clampf(e_slope_y, -0.14, 0.14)
			found_y = e_pts.size() >= 2
	if best_dir.length_squared() < 0.01:
		return {"valid": false, "dir": Vector2.RIGHT, "has_y": false, "y": 0.0, "slope_y": 0.0}
	return {"valid": true, "dir": best_dir.normalized(), "has_y": found_y, "y": best_y, "slope_y": best_slope_y}


func find_nearest_city_catchment(pos: Vector2) -> int:
	if not world_ref:
		return -1
	var best_idx := -1
	var best_dist := 1e9
	for i in range(world_ref.cities.size()):
		var c = world_ref.cities[i]
		var cxz: Vector2 = world_ref.map_to_world_xz(float(c["x"]), float(c["y"]))
		var r_world := float(c["radius"]) * 0.1 * 1.55
		var d := pos.distance_to(cxz)
		if d <= r_world and d < best_dist:
			best_dist = d
			best_idx = i
	return best_idx


func update_hover_and_preview(world_xz: Vector2, cam_dist: float) -> void:
	if not world_ref:
		return
	var snap_r := clampf(cam_dist * 0.022, 0.045, 2.2)
	var ring_s := clampf(cam_dist * 0.055, 0.18, 1.35)
	if snap_ring_inst:
		snap_ring_inst.scale = Vector3.ONE * ring_s
	if snap_ring_inst2:
		snap_ring_inst2.scale = Vector3.ONE * ring_s
	hover_node_id = 0
	hover_node_id2 = 0
	hover_edge_id = 0
	hover_edge_id2 = 0
	hover_station_idx = -1
	hover_station_city_idx = -1
	snap_ring_inst.visible = false
	snap_ring_inst2.visible = false
	if city_catchment_ring_inst:
		city_catchment_ring_inst.visible = false
	snap_ring_inst.material_override = mat_ghost_warn
	snap_ring_inst2.material_override = mat_ghost_warn
	preview_station_inst.visible = false

	if tool == ToolMode.DEMOLISH:
		preview_track_inst.visible = false
		preview_track_inst2.visible = false
		hover_station_idx = find_station_near(world_xz, snap_r * 1.1)
		if hover_station_idx >= 0:
			var sp: Vector2 = stations[hover_station_idx]["pos"]
			var sy: float = world_ref.sample_world_y(sp.x, sp.y)
			snap_ring_inst.material_override = mat_ghost_bad
			snap_ring_inst.position = Vector3(sp.x, maxf(0.0, sy) + 0.14, sp.y)
			snap_ring_inst.visible = true
			return
		var hit_d := find_edge_near(world_xz, snap_r)
		hover_edge_id = hit_d["edge_id"]
		hover_edge_t = hit_d["t"]
		if hover_edge_id != 0 and edges.has(hover_edge_id):
			var e = edges[hover_edge_id]
			var pts: Array = e["pts"]
			var idx := clampi(int(round(hover_edge_t * float(pts.size() - 1))), 0, pts.size() - 1)
			var p3: Vector3 = pts[idx]
			snap_ring_inst.material_override = mat_ghost_bad
			snap_ring_inst.position = p3 + Vector3(0, 0.14, 0)
			snap_ring_inst.visible = true
		return

	if tool == ToolMode.BUILD_STATION:
		# Check if hovering an existing 1-track station -> offer one-click 2-Track Passing Loop upgrade!
		var near_st := find_station_near(world_xz, snap_r * 1.1)
		if near_st >= 0 and int(stations[near_st].get("tracks", 1)) < 2:
			hover_station_idx = near_st
			var st = stations[near_st]
			var sp: Vector2 = st["pos"]
			var sy: float = world_ref.sample_world_y(sp.x, sp.y)
			preview_station_inst.mesh = mesh_station_2track
			preview_station_inst.visible = true
			preview_station_inst.position = Vector3(sp.x, maxf(0.0, sy) + 0.002, sp.y)
			preview_station_inst.rotation = Vector3(0.0, -float(st["angle"]), 0.0)
			preview_station_inst.scale = Vector3.ONE * STATION_SCALE
			preview_station_inst.material_override = mat_ghost_ok if treasury >= STATION_UPGRADE_COST else mat_ghost_bad
			preview_track_inst.visible = false
			preview_track_inst2.visible = false
			return

		var elev: float = world_ref.sample_elevation_m(world_xz.x, world_xz.y)
		var wy: float = world_ref.sample_world_y(world_xz.x, world_xz.y)
		var build_cost := STATION_COST + (STATION_UPGRADE_COST if station_two_track else 0)
		preview_station_inst.mesh = mesh_station_2track if station_two_track else mesh_station
		preview_station_inst.visible = true
		preview_station_inst.position = Vector3(world_xz.x, maxf(0.0, wy) + 0.002, world_xz.y)
		preview_station_inst.rotation = Vector3(0.0, -station_angle, 0.0)
		preview_station_inst.scale = Vector3.ONE * STATION_SCALE
		var can_place := elev >= 1.0 and treasury >= build_cost
		preview_station_inst.material_override = mat_ghost_ok if can_place else mat_ghost_bad
		preview_track_inst.visible = false
		preview_track_inst2.visible = false

		# Highlight city catchment ring when close enough to count as a city station!
		hover_station_city_idx = find_nearest_city_catchment(world_xz)
		if hover_station_city_idx >= 0 and city_catchment_ring_inst:
			var c = world_ref.cities[hover_station_city_idx]
			var cxz: Vector2 = world_ref.map_to_world_xz(float(c["x"]), float(c["y"]))
			var cy: float = world_ref.sample_world_y(cxz.x, cxz.y)
			var r_world := float(c["radius"]) * 0.1 * 1.55
			city_catchment_ring_inst.position = Vector3(cxz.x, maxf(0.0, cy) + 0.12, cxz.y)
			city_catchment_ring_inst.scale = Vector3(r_world, 0.35, r_world)
			city_catchment_ring_inst.material_override = mat_ghost_ok if can_place else mat_ghost_bad
			city_catchment_ring_inst.visible = true
		return

	if tool == ToolMode.BUILD_TRACK:
		hover_node_id = find_node_near(world_xz, snap_r)
		var end_pos := world_xz
		if hover_node_id != 0:
			end_pos = nodes[hover_node_id]["pos"]
			var sy: float = world_ref.sample_world_y(end_pos.x, end_pos.y)
			snap_ring_inst.position = Vector3(end_pos.x, maxf(0.0, sy) + 0.12, end_pos.y)
			snap_ring_inst.visible = true

			# Detect stopped double-track partner node so continuing/joining snaps to BOTH rails!
			if double_track:
				hover_node_id2 = find_double_track_partner(hover_node_id)
				if hover_node_id2 != 0:
					var p2_pos: Vector2 = nodes[hover_node_id2]["pos"]
					var sy2: float = world_ref.sample_world_y(p2_pos.x, p2_pos.y)
					snap_ring_inst2.position = Vector3(p2_pos.x, maxf(0.0, sy2) + 0.12, p2_pos.y)
					snap_ring_inst2.visible = true
					end_pos = (end_pos + p2_pos) * 0.5
		else:
			# Snap to mid-edge of an existing track for smooth unidirectional merge / Y-switch!
			var hit_e := find_edge_near(world_xz, snap_r * 0.85)
			if int(hit_e["edge_id"]) != 0:
				hover_edge_id = int(hit_e["edge_id"])
				hover_edge_t = clampf(float(hit_e["t"]), 0.08, 0.92)
				var e = edges[hover_edge_id]
				var pts: Array = e["pts"]
				var idx := clampi(int(round(hover_edge_t * float(pts.size() - 1))), 1, pts.size() - 2)
				var p3: Vector3 = pts[idx]
				end_pos = Vector2(p3.x, p3.z)
				snap_ring_inst.position = p3 + Vector3(0, 0.12, 0)
				snap_ring_inst.visible = true

				# If building a double track onto an existing double track, lock onto BOTH rails!
				if double_track:
					var par := find_parallel_edge_point(hover_edge_id, hover_edge_t)
					if par["valid"]:
						hover_edge_id2 = int(par["edge_id"])
						hover_edge_t2 = clampf(float(par["t"]), 0.08, 0.92)
						var p3_2: Vector3 = par["p3"]
						snap_ring_inst2.position = p3_2 + Vector3(0, 0.12, 0)
						snap_ring_inst2.visible = true
						end_pos = (end_pos + Vector2(p3_2.x, p3_2.z)) * 0.5

		if not has_track_start:
			preview_track_inst.visible = false
			preview_track_inst2.visible = false
			live_preview = {}
			live_preview2 = {}
			return

		var start_dir := Vector2.ZERO
		var has_start_dir := false
		var has_start_y := false
		var start_y := 0.0
		var start_slope_y := 0.0
		if track_start_node_id != 0:
			var st := get_node_tangent(track_start_node_id, end_pos)
			if st["valid"]:
				start_dir = st["dir"]
				has_start_dir = true
				has_start_y = st["has_y"]
				start_y = st["y"]
				start_slope_y = st["slope_y"]
		elif track_start_split_edge_id != 0:
			var sm := get_edge_merge_info(track_start_split_edge_id, track_start_split_t, end_pos, true, track_start_split_edge_id2 != 0)
			if sm["valid"]:
				start_dir = sm["dir"]
				has_start_dir = true
				has_start_y = true
				start_y = sm["y"]
				start_slope_y = sm["slope_y"]
		if not has_start_dir and absf(track_curve_angle) > 0.001:
			var base_ang := (end_pos - track_start_pos).angle() + track_curve_angle
			start_dir = Vector2(cos(base_ang), sin(base_ang))
			has_start_dir = true

		var end_dir := Vector2.ZERO
		var has_end_dir := false
		var has_end_y := false
		var end_y := 0.0
		var end_slope_y := 0.0
		if hover_node_id != 0:
			var et := get_node_tangent(hover_node_id, track_start_pos)
			if et["valid"]:
				end_dir = et["dir"]
				has_end_dir = true
				has_end_y = et["has_y"]
				end_y = et["y"]
				end_slope_y = et["slope_y"]
		elif hover_edge_id != 0:
			var em := get_edge_merge_info(hover_edge_id, hover_edge_t, track_start_pos, false, hover_edge_id2 != 0)
			if em["valid"]:
				end_dir = em["dir"]
				has_end_dir = true
				has_end_y = true
				end_y = em["y"]
				end_slope_y = em["slope_y"]

		if double_track:
			# Ensure paired start node/edge is always resolved if user started on a double track
			if track_start_node_id != 0 and track_start_node_id2 == 0:
				var p_nid := find_double_track_partner(track_start_node_id)
				if p_nid != 0 and nodes.has(p_nid):
					track_start_node_id2 = p_nid
					track_start_pos = (nodes[track_start_node_id]["pos"] + nodes[p_nid]["pos"]) * 0.5
			elif track_start_split_edge_id != 0 and track_start_split_edge_id2 == 0:
				var p_ed := find_parallel_edge_point(track_start_split_edge_id, track_start_split_t)
				if p_ed["valid"]:
					track_start_split_edge_id2 = int(p_ed["edge_id"])
					track_start_split_t2 = clampf(float(p_ed["t"]), 0.08, 0.92)
					var p3_2: Vector3 = p_ed["p3"]
					track_start_pos = (track_start_pos + Vector2(p3_2.x, p3_2.z)) * 0.5

			var diff := end_pos - track_start_pos
			var dist := diff.length()
			if dist >= 0.12:
				var h := DOUBLE_TRACK_OFFSET * 0.5
				# Stay cleanly parallel (unpin) whenever starting/ending on a paired double track!
				var pin_start := (track_start_node_id != 0 and track_start_node_id2 == 0) or (track_start_split_edge_id != 0 and track_start_split_edge_id2 == 0)
				var pin_end := (hover_node_id != 0 and hover_node_id2 == 0) or (hover_edge_id != 0 and hover_edge_id2 == 0)

				var has_s2_y := has_start_y
				var s2_y := start_y
				var s2_slope := start_slope_y
				var s2_dir := start_dir
				var has_s2_dir := has_start_dir
				if track_start_node_id2 != 0 and nodes.has(track_start_node_id2):
					var st2 := get_node_tangent(track_start_node_id2, end_pos)
					if st2["valid"]:
						s2_dir = st2["dir"]
						has_s2_dir = true
						has_s2_y = st2["has_y"]
						s2_y = st2["y"]
						s2_slope = st2["slope_y"]

				live_preview = preview_track(
					track_start_pos, end_pos, has_start_dir, start_dir, has_end_dir, end_dir,
					+h, pin_start, pin_end, has_start_y, start_y, start_slope_y, has_end_y, end_y, end_slope_y)
				live_preview2 = preview_track(
					track_start_pos, end_pos, has_s2_dir, s2_dir, has_end_dir, end_dir,
					-h, pin_start, pin_end, has_s2_y, s2_y, s2_slope, has_end_y, end_y, end_slope_y)
				_update_preview_mesh(preview_track_inst, live_preview)
				_update_preview_mesh(preview_track_inst2, live_preview2)
			else:
				live_preview = {}
				live_preview2 = {}
				preview_track_inst.visible = false
				preview_track_inst2.visible = false
		else:
			live_preview = preview_track(
				track_start_pos, end_pos, has_start_dir, start_dir, has_end_dir, end_dir,
				0.0, false, false, has_start_y, start_y, start_slope_y, has_end_y, end_y, end_slope_y)
			live_preview2 = {}
			_update_preview_mesh(preview_track_inst, live_preview)
			preview_track_inst2.visible = false
		return

	if tool == ToolMode.PLACE_SIGNAL:
		preview_track_inst.visible = false
		preview_track_inst2.visible = false
		var hit := find_edge_near(world_xz, snap_r)
		hover_edge_id = hit["edge_id"]
		hover_edge_t = hit["t"]
		if hover_edge_id != 0:
			var e = edges[hover_edge_id]
			var p2 := _eval_bezier(e["p0"], e["c1"], e["c2"], e["p1"], hover_edge_t)
			var sy: float = world_ref.sample_world_y(p2.x, p2.y)
			snap_ring_inst.position = Vector3(p2.x, maxf(0.0, sy) + 0.14, p2.y)
			snap_ring_inst.visible = true
		return

	_hide_previews()


func preview_track(p0: Vector2, p1: Vector2, has_sdir: bool, sdir: Vector2,
		has_edir: bool, edir: Vector2,
		lateral_offset: float = 0.0, pin_start: bool = false, pin_end: bool = false,
		has_start_y: bool = false, start_y: float = 0.0, start_slope_y: float = 0.0,
		has_end_y: bool = false, end_y: float = 0.0, end_slope_y: float = 0.0) -> Dictionary:
	var chord := p0.distance_to(p1)
	if chord < 0.10:
		return {"valid": false, "reason": "Track segment too short", "pts": []}

	var handle := chord * 0.35
	var c1 := p0 + (sdir * handle if has_sdir else (p1 - p0) * 0.35)
	var c2 := p1 + (edir * handle if has_edir else (p0 - p1) * 0.35)

	# Fixed physical station-throat turnout length (~0.16u = ~4x station length) so dual tracks
	# separate crisply right outside the station regardless of whether the line is 10 km or 300 km!
	var taper_t := clampf(0.16 / maxf(0.10, chord), 0.006, 0.25)
	var base_steps := clampi(int(ceil(chord * 12.0)), 14, 128)
	var t_vals: Array[float] = []
	for i in range(base_steps + 1):
		t_vals.append(float(i) / float(base_steps))
	if absf(lateral_offset) > 1e-5:
		if pin_start:
			for frac in [0.22, 0.48, 0.76, 1.0]:
				t_vals.append(taper_t * frac)
		if pin_end:
			for frac in [0.22, 0.48, 0.76, 1.0]:
				t_vals.append(1.0 - taper_t * frac)
		t_vals.sort()
		# Deduplicate nearly-identical t values
		var dedup: Array[float] = [t_vals[0]]
		for k in range(1, t_vals.size()):
			if t_vals[k] - dedup[dedup.size() - 1] > 1e-4:
				dedup.append(t_vals[k])
		t_vals = dedup
	var steps := t_vals.size() - 1
	var pts3: Array[Vector3] = []
	var elevs: Array[float] = []
	var is_bridge_pt: Array[bool] = []
	var total_len := 0.0
	var max_grade := 0.0
	var has_bridge := false
	var sea_span := 0.0
	var max_sea_span := 0.0
	var deep_sea := false

	var e_start: float = maxf(0.0, world_ref.sample_elevation_m(p0.x, p0.y))
	var e_end: float = maxf(0.0, world_ref.sample_elevation_m(p1.x, p1.y))
	var max_elev := maxf(e_start, e_end)

	var actual_p0 := p0
	var actual_p1 := p1
	var prev2 := p0
	var clearance_y: Array[float] = []
	for i in range(steps + 1):
		var t := t_vals[i]
		var pt := _eval_bezier(p0, c1, c2, p1, t)
		var tan2 := _eval_bezier_tangent(p0, c1, c2, p1, t)
		var nrm := Vector2(-tan2.y, tan2.x).normalized() if tan2.length_squared() > 1e-8 else Vector2.RIGHT
		if absf(lateral_offset) > 1e-5:
			var sw := smoothstep(0.0, taper_t, t) if pin_start else 1.0
			var ew := smoothstep(1.0, 1.0 - taper_t, t) if pin_end else 1.0
			pt += nrm * (lateral_offset * sw * ew)
		if i == 0:
			actual_p0 = pt
		elif i == steps:
			actual_p1 = pt
		var elev: float = world_ref.sample_elevation_m(pt.x, pt.y)
		# Sample uphill/downhill track shoulders so side-hill tracks never sink under mountains
		var elev_l: float = world_ref.sample_elevation_m(pt.x - nrm.x * 0.025, pt.y - nrm.y * 0.025)
		var elev_r: float = world_ref.sample_elevation_m(pt.x + nrm.x * 0.025, pt.y + nrm.y * 0.025)
		var shoulder_elev := maxf(elev, maxf(elev_l, elev_r))

		var river_v := _sample_river(pt)
		var seg_d := prev2.distance_to(pt) if i > 0 else 0.0
		total_len += seg_d

		var on_water := (elev < 0.0) or (river_v > 0.36)
		if elev < -45.0:
			deep_sea = true
		if elev < 0.0:
			sea_span += seg_d
			max_sea_span = maxf(max_sea_span, sea_span)
		else:
			sea_span = 0.0

		if on_water:
			has_bridge = true
		max_elev = maxf(max_elev, elev)
		elevs.append(elev)
		is_bridge_pt.append(on_water)

		var wy: float = maxf(0.003, shoulder_elev * world_ref.LAND_HEIGHT_SCALE + 0.0012)
		if on_water:
			wy = maxf(wy, maxf(0.0, elev) * world_ref.LAND_HEIGHT_SCALE + 0.005)
		clearance_y.append(wy)
		pts3.append(Vector3(pt.x, wy, pt.y))
		prev2 = pt

	# Check grades over a resolution-independent ~5 km window (so high-res micro-scale sampling
	# follows terrain smoothly without local DEM undulations triggering spurious long tunnels)
	var avg_step_km := maxf(0.05, (total_len * KM_PER_UNIT) / float(steps))
	var grade_span := clampi(int(round(5.0 / avg_step_km)), 1, maxi(1, steps / 4))
	for i in range(grade_span, steps + 1):
		var j := i - grade_span
		var horiz_m := pts3[i].distance_to(Vector3(pts3[j].x, pts3[i].y, pts3[j].z)) * KM_PER_UNIT * 1000.0
		if horiz_m > 1.0:
			var de := absf(maxf(0.0, elevs[i]) - maxf(0.0, elevs[j]))
			var g := (de / horiz_m) * 100.0
			max_grade = maxf(max_grade, g)

	if deep_sea or max_sea_span * KM_PER_UNIT > 22.0:
		return {"valid": false, "reason": "Cannot bridge open sea", "pts": pts3}

	# Automatic Alpine Tunnel when crossing steep/high mountain ridges (with engineering limits)
	var has_tunnel := false
	var tunnel_entry := -1
	var tunnel_exit := -1
	var tunnel_len_km := 0.0
	var ridge_excess := max_elev - maxf(e_start, e_end)
	if max_grade > 5.8 or ridge_excess > 550.0:
		var total_m := maxf(1.0, total_len * KM_PER_UNIT * 1000.0)
		var bore_grade := (absf(e_end - e_start) / total_m) * 100.0
		if bore_grade > 4.8:
			return {"valid": false, "reason": "Grade too steep even for tunnel (%.1f%% > 4.8%%)" % bore_grade, "pts": pts3}

		has_tunnel = true
		var tunnel_pts := 0
		for i in range(steps + 1):
			var t := float(i) / float(steps)
			var tunnel_elev := lerpf(e_start, e_end, t)
			if elevs[i] > tunnel_elev + 65.0:
				if tunnel_entry == -1:
					tunnel_entry = i
				tunnel_exit = i
				tunnel_pts += 1
				pts3[i].y = tunnel_elev * world_ref.LAND_HEIGHT_SCALE + 0.02
		tunnel_len_km = (float(tunnel_pts) / float(steps)) * total_len * KM_PER_UNIT
		if tunnel_len_km > 150.0:
			return {"valid": false, "reason": "Tunnel bore too long (%.0f km > 150 km)" % tunnel_len_km, "pts": pts3}
		max_grade = bore_grade

	# Anchor endpoints to exact connected node elevations for seamless 3D node junctions
	if has_start_y:
		pts3[0].y = start_y
		clearance_y[0] = start_y
	if has_end_y:
		pts3[steps].y = end_y
		clearance_y[steps] = end_y

	# Strict peak ceiling: track may NEVER rise higher than the highest actual terrain point
	var max_peak_y := maxf(pts3[0].y, pts3[steps].y)
	for i in range(steps + 1):
		max_peak_y = maxf(max_peak_y, clearance_y[i])

	# Step 1: Hermite C1 vertical tangent blend at connected intermediate nodes
	var seg_len_u := total_len / float(steps)
	var target_y: Array[float] = []
	target_y.resize(steps + 1)
	for i in range(steps + 1):
		target_y[i] = pts3[i].y

	var blend_n := mini(8, steps / 2)
	if has_start_y and blend_n >= 2:
		for i in range(1, blend_n):
			var u := float(i) / float(blend_n)
			var w := (1.0 - u) * (1.0 - u) * (1.0 + 2.0 * u)  # Hermite h00(u): 1 at u=0 with 0 deriv, 0 at u=1
			var tangent_y := clampf(start_y + start_slope_y * (seg_len_u * float(i)), 0.015, max_peak_y)
			target_y[i] = lerpf(target_y[i], tangent_y, w)
	if has_end_y and blend_n >= 2:
		for k in range(1, blend_n):
			var idx := steps - k
			var u := float(k) / float(blend_n)
			var w := (1.0 - u) * (1.0 - u) * (1.0 + 2.0 * u)
			var tangent_y := clampf(end_y + end_slope_y * (seg_len_u * float(k)), 0.015, max_peak_y)
			target_y[idx] = lerpf(target_y[idx], tangent_y, w)

	# Step 2: Tight Gaussian smoothing (sigma = 2.0) — strictly bounded by [min, max_peak_y], zero inflation!
	var sigma := 2.0
	var inv_2s2 := 1.0 / (2.0 * sigma * sigma)
	var smooth_y: Array[float] = []
	smooth_y.resize(steps + 1)
	smooth_y[0] = target_y[0]
	smooth_y[steps] = target_y[steps]
	for i in range(1, steps):
		var in_tun := (tunnel_entry != -1 and i >= tunnel_entry and i <= tunnel_exit)
		if in_tun:
			smooth_y[i] = target_y[i]
			continue
		var sum_w := 0.0
		var sum_v := 0.0
		var j0 := maxi(0, i - 6)
		var j1 := mini(steps, i + 6)
		for j in range(j0, j1 + 1):
			var d := float(i - j)
			var gw := exp(-d * d * inv_2s2)
			sum_w += gw
			sum_v += target_y[j] * gw
		smooth_y[i] = clampf(sum_v / maxf(1e-6, sum_w), 0.015, max_peak_y)

	# Re-enforce exact C1 slope at i=1 and i=steps-1 for connected intermediate nodes
	if has_start_y and steps >= 3:
		smooth_y[1] = clampf(start_y + start_slope_y * seg_len_u, clearance_y[1] - 0.002, max_peak_y)
	if has_end_y and steps >= 3:
		smooth_y[steps - 1] = clampf(end_y + end_slope_y * seg_len_u, clearance_y[steps - 1] - 0.002, max_peak_y)

	# Step 3: Take max with clearance_y (capped at max_peak_y) + 4 gentle clamped smoothing passes
	# (never rises above max_peak_y, never drops under terrain because clearance_y has +0.004 margin)
	for i in range(1, steps):
		var in_tun := (tunnel_entry != -1 and i >= tunnel_entry and i <= tunnel_exit)
		if in_tun:
			pts3[i].y = smooth_y[i]
		else:
			pts3[i].y = clampf(maxf(smooth_y[i], clearance_y[i] - 0.0015), clearance_y[i] - 0.0015, max_peak_y)

	for _pass in range(4):
		var prev_y: Array[float] = []
		prev_y.resize(steps + 1)
		for i in range(steps + 1):
			prev_y[i] = pts3[i].y
		for i in range(1, steps):
			var in_tun := (tunnel_entry != -1 and i >= tunnel_entry and i <= tunnel_exit)
			var sm := 0.25 * prev_y[i - 1] + 0.50 * prev_y[i] + 0.25 * prev_y[i + 1]
			if in_tun:
				pts3[i].y = sm
			else:
				pts3[i].y = clampf(maxf(sm, clearance_y[i] - 0.002), clearance_y[i] - 0.002, max_peak_y)

	var length_km := total_len * KM_PER_UNIT
	var base_cost := int(round(length_km * 240.0))
	if has_bridge:
		base_cost += int(round(length_km * 180.0)) + 8000
	if has_tunnel:
		base_cost += int(round(length_km * 320.0)) + 16000
	base_cost = maxi(1500, base_cost)

	return {
		"valid": true,
		"p0": actual_p0, "c1": c1 + (actual_p0 - p0), "c2": c2 + (actual_p1 - p1), "p1": actual_p1,
		"pts": pts3,
		"is_bridge_pt": is_bridge_pt,
		"length_km": length_km,
		"max_grade": max_grade,
		"has_bridge": has_bridge,
		"has_tunnel": has_tunnel,
		"tunnel_entry": tunnel_entry,
		"tunnel_exit": tunnel_exit,
		"cost": base_cost,
	}


func perform_primary_action(world_xz: Vector2) -> int:
	# Returns newly selected city index if any (-1 unchanged / none)
	if not world_ref:
		return -1

	if tool == ToolMode.DEMOLISH:
		if hover_station_idx >= 0:
			demolish_station(hover_station_idx)
			hover_station_idx = -1
		elif hover_edge_id != 0:
			demolish_edge(hover_edge_id)
			hover_edge_id = 0
		return -1

	if tool == ToolMode.BUILD_STATION:
		if hover_station_idx >= 0 and hover_station_idx < stations.size() and int(stations[hover_station_idx].get("tracks", 1)) < 2:
			if upgrade_station_to_two_track(hover_station_idx):
				return int(stations[hover_station_idx]["city_idx"])
			return -1
		var elev: float = world_ref.sample_elevation_m(world_xz.x, world_xz.y)
		var build_cost := STATION_COST + (STATION_UPGRADE_COST if station_two_track else 0)
		if elev >= 1.0 and treasury >= build_cost:
			var c_idx := find_nearest_city_catchment(world_xz)
			var st_name := ""
			if c_idx >= 0:
				st_name = String(world_ref.cities[c_idx]["name"]) + " Central"
			else:
				st_name = "Junction #%d" % (stations.size() + 1)
			add_station(world_xz, c_idx, st_name, station_angle, 2 if station_two_track else 1)
			treasury -= build_cost
			return c_idx
		return -1

	if tool == ToolMode.BUILD_TRACK:
		var click_pos := world_xz
		var snap_id := hover_node_id
		var snap_id2 := hover_node_id2
		if snap_id != 0 and nodes.has(snap_id):
			click_pos = nodes[snap_id]["pos"]
			if snap_id2 != 0 and nodes.has(snap_id2):
				click_pos = (click_pos + nodes[snap_id2]["pos"]) * 0.5
		elif hover_edge_id != 0 and edges.has(hover_edge_id):
			var e = edges[hover_edge_id]
			var pts: Array = e["pts"]
			var idx := clampi(int(round(hover_edge_t * float(pts.size() - 1))), 1, pts.size() - 2)
			click_pos = Vector2((pts[idx] as Vector3).x, (pts[idx] as Vector3).z)
			if hover_edge_id2 != 0 and edges.has(hover_edge_id2):
				var e2 = edges[hover_edge_id2]
				var pts2: Array = e2["pts"]
				var idx2 := clampi(int(round(hover_edge_t2 * float(pts2.size() - 1))), 1, pts2.size() - 2)
				click_pos = (click_pos + Vector2((pts2[idx2] as Vector3).x, (pts2[idx2] as Vector3).z)) * 0.5

		if not has_track_start:
			if world_ref.sample_elevation_m(click_pos.x, click_pos.y) >= 0.0:
				has_track_start = true
				track_start_pos = click_pos
				track_start_node_id = snap_id
				track_start_node_id2 = snap_id2
				track_start_split_edge_id = hover_edge_id if snap_id == 0 else 0
				track_start_split_t = hover_edge_t
				track_start_split_edge_id2 = hover_edge_id2 if snap_id == 0 else 0
				track_start_split_t2 = hover_edge_t2
				track_curve_angle = 0.0
		else:
			# Validate preview & funds BEFORE splitting any existing edges!
			var can_build := false
			if double_track:
				can_build = live_preview.get("valid", false) and live_preview2.get("valid", false) \
					and treasury >= int(live_preview["cost"]) + int(live_preview2["cost"])
			else:
				can_build = live_preview.get("valid", false) and treasury >= int(live_preview["cost"])
			if not can_build:
				return -1

			# Split existing edge(s) into real junction nodes if starting/ending mid-edge!
			var start_nid := track_start_node_id
			var start_nid2 := track_start_node_id2
			if start_nid == 0 and track_start_split_edge_id != 0:
				if track_start_split_edge_id2 != 0:
					start_nid = split_edge_at_t(track_start_split_edge_id, track_start_split_t, false)
					start_nid2 = split_edge_at_t(track_start_split_edge_id2, track_start_split_t2, false)
					_link_crossover_nodes(start_nid, start_nid2)
				else:
					start_nid = split_edge_at_t(track_start_split_edge_id, track_start_split_t, true)
					if double_track:
						start_nid2 = find_double_track_partner(start_nid)
				track_start_split_edge_id = 0
				track_start_split_edge_id2 = 0
			var end_nid := snap_id
			var end_nid2 := snap_id2
			if end_nid == 0 and hover_edge_id != 0:
				if hover_edge_id2 != 0:
					end_nid = split_edge_at_t(hover_edge_id, hover_edge_t, false)
					end_nid2 = split_edge_at_t(hover_edge_id2, hover_edge_t2, false)
					_link_crossover_nodes(end_nid, end_nid2)
				else:
					end_nid = split_edge_at_t(hover_edge_id, hover_edge_t, true)
					if double_track:
						end_nid2 = find_double_track_partner(end_nid)

			if double_track:
				if live_preview.get("valid", false) and live_preview2.get("valid", false):
					var total_cost: int = int(live_preview["cost"]) + int(live_preview2["cost"])
					if treasury >= total_cost:
						# Match parallel start & end nodes by proximity so rails never cross!
						var s1_id := start_nid
						var s2_id := start_nid2 if start_nid2 != 0 else start_nid
						if start_nid != 0 and start_nid2 != 0 and nodes.has(start_nid) and nodes.has(start_nid2):
							var p0_1: Vector2 = live_preview["p0"]
							if p0_1.distance_squared_to(nodes[start_nid2]["pos"]) < p0_1.distance_squared_to(nodes[start_nid]["pos"]):
								s1_id = start_nid2
								s2_id = start_nid
						var e1_id := end_nid
						var e2_id := end_nid2 if end_nid2 != 0 else end_nid
						if end_nid != 0 and end_nid2 != 0 and nodes.has(end_nid) and nodes.has(end_nid2):
							var p1_1: Vector2 = live_preview["p1"]
							if p1_1.distance_squared_to(nodes[end_nid2]["pos"]) < p1_1.distance_squared_to(nodes[end_nid]["pos"]):
								e1_id = end_nid2
								e2_id = end_nid

						# Automatic right-hand directional double track:
						# Track 1 (+h right side) = +1 (A -> B), Track 2 (-h left side) = -1 (B -> A)
						var eid1 := add_track_from_preview(live_preview, s1_id, e1_id, 1, true)
						var eid2 := add_track_from_preview(live_preview2, s2_id, e2_id, -1, true)
						treasury -= total_cost
						if end_nid != 0:
							# Connected to a station, existing node, or another track -> switch off continuation mode!
							clear_track_start()
						else:
							track_start_pos = click_pos
							track_start_node_id = edges[eid1]["node_b"] if eid1 != 0 else 0
							track_start_node_id2 = edges[eid2]["node_b"] if eid2 != 0 else 0
							track_curve_angle = 0.0
							live_preview = {}
							live_preview2 = {}
						_recalculate_all_line_routes()
			elif live_preview.get("valid", false):
				var cost: int = int(live_preview["cost"])
				if treasury >= cost:
					var eid := add_track_from_preview(live_preview, start_nid, end_nid, 0, true)
					if eid != 0:
						treasury -= cost
						if end_nid != 0:
							# Connected to a station, existing node, or another track -> switch off continuation mode!
							clear_track_start()
						else:
							track_start_pos = click_pos
							track_start_node_id = edges[eid]["node_b"]
							track_start_node_id2 = 0
							track_curve_angle = 0.0
							live_preview = {}
						_recalculate_all_line_routes()
		return -1

	if tool == ToolMode.PLACE_SIGNAL:
		if hover_edge_id != 0 and edges.has(hover_edge_id):
			if auto_signal:
				var cnt := auto_signal_edge(hover_edge_id, 45.0, signal_type)
				treasury = maxi(0, treasury - cnt * SIGNAL_COST)
			elif treasury >= SIGNAL_COST:
				add_signal(hover_edge_id, hover_edge_t, signal_type)
				treasury -= SIGNAL_COST
		return -1

	return -1


func add_station(pos: Vector2, city_idx: int, st_name: String, angle: float, tracks: int = 1) -> int:
	var st_id := next_id
	next_id += 1

	var dir := Vector2(cos(angle), sin(angle))
	var pa := pos - dir * STATION_HALF_LEN
	var pb := pos + dir * STATION_HALF_LEN

	var na := _create_node(pa, st_id)
	var nb := _create_node(pb, st_id)

	# Internal station edge connecting throat A <-> throat B (bi-directional)
	var eid := next_id
	next_id += 1
	var wy: float = world_ref.sample_world_y(pos.x, pos.y)
	var p3a := Vector3(pa.x, wy + 0.0015, pa.y)
	var p3b := Vector3(pb.x, wy + 0.0015, pb.y)
	edges[eid] = {
		"id": eid, "node_a": na, "node_b": nb,
		"p0": pa, "c1": pa.lerp(pb, 0.33), "c2": pa.lerp(pb, 0.67), "p1": pb,
		"pts": [p3a, p3b],
		"cum_dist": [0.0, p3a.distance_to(p3b)],
		"length_km": STATION_HALF_LEN * 2.0 * KM_PER_UNIT,
		"max_grade": 0.0, "has_bridge": false, "has_tunnel": false,
		"t_entry": -1, "t_exit": -1, "direction": 0,
		"internal": true, "station_id": st_id, "signals": [], "mesh_node": null,
	}
	nodes[na]["edges"].append(eid)
	nodes[nb]["edges"].append(eid)

	# Spawn 3D station model (1-track or upgraded 2-track passing station with entry/exit switches!)
	var inst := MeshInstance3D.new()
	inst.name = "Station_%d" % st_id
	inst.mesh = mesh_station_2track if tracks >= 2 else mesh_station
	inst.material_override = mat_solid
	inst.position = Vector3(pos.x, maxf(0.0, wy) - 0.001, pos.y)
	inst.rotation = Vector3(0.0, -angle, 0.0)
	inst.scale = Vector3.ONE * STATION_SCALE
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(inst)

	stations.append({
		"id": st_id, "name": st_name, "pos": pos, "angle": angle,
		"city_idx": city_idx, "node_a": na, "node_b": nb, "mesh_node": inst,
		"tracks": maxi(1, tracks), "internal_edge_id": eid,
	})
	return st_id


func upgrade_station_to_two_track(st_idx: int) -> bool:
	if st_idx < 0 or st_idx >= stations.size():
		return false
	var st = stations[st_idx]
	if int(st.get("tracks", 1)) >= 2:
		return false
	if treasury < STATION_UPGRADE_COST:
		return false
	treasury -= STATION_UPGRADE_COST
	st["tracks"] = 2
	var inst: MeshInstance3D = st["mesh_node"]
	if inst != null and is_instance_valid(inst) and mesh_station_2track != null:
		inst.mesh = mesh_station_2track
	var sp: Vector2 = st["pos"]
	var wy: float = world_ref.sample_world_y(sp.x, sp.y)
	_spawn_floating_popup(Vector3(sp.x, wy + 0.14, sp.y), "%s: 2-Track Passing Station!" % String(st["name"]), Color(0.55, 0.95, 1.0))
	return true


func add_track_from_preview(pv: Dictionary, start_node_id: int, end_node_id: int,
		direction: int = 0, auto_place_signals: bool = true) -> int:
	if not pv.get("valid", false):
		return 0
	var na := start_node_id if (start_node_id != 0 and nodes.has(start_node_id)) else _create_node(pv["p0"], -1)
	var nb := end_node_id if (end_node_id != 0 and nodes.has(end_node_id)) else _create_node(pv["p1"], -1)

	var eid := next_id
	next_id += 1

	var track_node := _build_track_3d(pv)
	track_node.name = "Track_%d" % eid
	add_child(track_node)

	# Precompute cumulative 3D arc-length along sampled points for smooth train travel
	var pts: Array = pv["pts"]
	var cum_dist: Array[float] = []
	cum_dist.resize(pts.size())
	var acc := 0.0
	for i in range(pts.size()):
		if i > 0:
			acc += (pts[i] as Vector3).distance_to(pts[i - 1] as Vector3)
		cum_dist[i] = acc

	edges[eid] = {
		"id": eid, "node_a": na, "node_b": nb,
		"p0": pv["p0"], "c1": pv["c1"], "c2": pv["c2"], "p1": pv["p1"],
		"pts": pts, "cum_dist": cum_dist,
		"length_km": pv["length_km"], "max_grade": pv["max_grade"],
		"has_bridge": pv["has_bridge"], "has_tunnel": pv["has_tunnel"],
		"t_entry": pv.get("tunnel_entry", -1), "t_exit": pv.get("tunnel_exit", -1),
		"direction": direction,
		"internal": false, "signals": [], "mesh_node": track_node,
	}
	nodes[na]["edges"].append(eid)
	nodes[nb]["edges"].append(eid)

	# Automatic regular-interval signaling (included with track construction!)
	if auto_place_signals:
		var len_km: float = float(pv["length_km"])
		var total_u_sig: float = maxf(0.1, float(cum_dist[cum_dist.size() - 1]))
		if direction != 0:
			# Station-approach home signal placed safely OUTSIDE the 0.16u throat taper (>= 0.28u from station!)
			# so waiting trains never block outgoing trains on the opposite parallel rail!
			var arr_margin_t := clampf(0.28 / total_u_sig, 0.07, 0.38)
			var cnt := clampi(int(floor(len_km / 45.0)), 1, 10)
			if len_km >= 20.0:
				if direction > 0:
					add_signal(eid, 1.0 - arr_margin_t, SignalType.ONE_WAY, direction)
				else:
					add_signal(eid, arr_margin_t, SignalType.ONE_WAY, direction)
			for i in range(1, cnt + 1):
				var t := float(i) / float(cnt + 1)
				if t > arr_margin_t + 0.06 and t < (1.0 - arr_margin_t) - 0.06:
					add_signal(eid, t, SignalType.ONE_WAY, direction)
		elif len_km >= 55.0:
			# Long bi-directional single track: automatic Block signals every ~65 km
			var cnt := clampi(int(floor(len_km / 65.0)), 1, 8)
			for i in range(1, cnt + 1):
				var t := float(i) / float(cnt + 1)
				add_signal(eid, t, SignalType.BLOCK, 1)
		_cleanup_junction_signals()

	return eid


func add_signal(edge_id: int, t: float, sig_type: int, dir_sign: int = 1) -> void:
	if not edges.has(edge_id):
		return
	var e = edges[edge_id]
	var pts: Array = e["pts"]
	if pts.size() < 2:
		return
	# Skip placing physical signal posts underground inside tunnels
	var idx := clampi(int(round(t * float(pts.size() - 1))), 0, pts.size() - 1)
	var t_en: int = e.get("t_entry", -1)
	var t_ex: int = e.get("t_exit", -1)
	if t_en != -1 and idx >= t_en and idx <= t_ex:
		return

	var p3: Vector3 = pts[idx]
	var p_prev: Vector3 = pts[maxi(0, idx - 1)]
	var p_next: Vector3 = pts[mini(pts.size() - 1, idx + 1)]
	var tan2 := Vector2(p_next.x - p_prev.x, p_next.z - p_prev.z)
	if tan2.length_squared() < 1e-8:
		tan2 = Vector2.RIGHT
	else:
		tan2 = tan2.normalized() * float(dir_sign)
	var right2 := Vector2(-tan2.y, tan2.x) * 0.019
	var spos := Vector2(p3.x, p3.z) + right2

	var inst := MeshInstance3D.new()
	inst.mesh = mesh_signal
	var smat := StandardMaterial3D.new()
	smat.vertex_color_use_as_albedo = true
	if sig_type == SignalType.CHAIN:
		smat.albedo_color = Color(0.55, 0.85, 1.0)
		smat.emission_enabled = true
		smat.emission = Color(0.25, 0.65, 1.0)
		smat.emission_energy_multiplier = 0.8
	elif sig_type == SignalType.ONE_WAY:
		smat.albedo_color = Color(0.55, 1.0, 0.65)
		smat.emission_enabled = true
		smat.emission = Color(0.25, 0.90, 0.40)
		smat.emission_energy_multiplier = 0.8
	else:
		smat.albedo_color = Color(1.0, 0.88, 0.45)
		smat.emission_enabled = true
		smat.emission = Color(0.95, 0.72, 0.18)
		smat.emission_energy_multiplier = 0.8
	inst.material_override = smat
	inst.position = Vector3(spos.x, maxf(0.005, p3.y), spos.y)
	inst.rotation = Vector3(0.0, -tan2.angle(), 0.0)
	inst.scale = Vector3.ONE * 0.032
	add_child(inst)

	e["signals"].append({
		"t": t, "type": sig_type, "dir": dir_sign,
		"node": inst, "mat": smat, "is_red": false,
	})
	# Keep signals sorted along edge parameter t so block intervals are exact
	(e["signals"] as Array).sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))


func auto_signal_edge(edge_id: int, spacing_km: float, sig_type: int) -> int:
	if not edges.has(edge_id):
		return 0
	var e = edges[edge_id]
	var len_km: float = e["length_km"]
	var count := clampi(int(floor(len_km / maxf(10.0, spacing_km))), 1, 16)
	var placed := 0
	for i in range(1, count + 1):
		if treasury < (placed + 1) * SIGNAL_COST:
			break
		var t := float(i) / float(count + 1)
		add_signal(edge_id, t, sig_type)
		placed += 1
	return placed


func _create_node(pos: Vector2, station_id: int) -> int:
	var nid := next_id
	next_id += 1
	nodes[nid] = {"id": nid, "pos": pos, "edges": [], "station_id": station_id}
	return nid


func _build_track_3d(pv: Dictionary) -> Node3D:
	var root := Node3D.new()
	var pts: Array = pv["pts"]
	var bridge_flags: Array = pv["is_bridge_pt"]
	var n := pts.size()
	if n < 2:
		return root

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var st_tun := SurfaceTool.new()
	st_tun.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_tun_tris := false

	var col_ballast := Color(0.30, 0.27, 0.24)
	var col_sleeper := Color(0.20, 0.16, 0.13)
	var col_bridge  := Color(0.46, 0.43, 0.39)
	var col_rail    := Color(0.38, 0.41, 0.46)
	var col_tunnel  := Color(0.95, 0.74, 0.28, 0.62)

	var t_entry: int = pv.get("tunnel_entry", -1)
	var t_exit: int = pv.get("tunnel_exit", -1)

	# Precompute smooth continuous mitered right-vectors at every vertex (zero saw-tooth!)
	var rights: Array[Vector3] = []
	rights.resize(n)
	for i in range(n):
		var p_prev: Vector3 = pts[maxi(0, i - 1)]
		var p_next: Vector3 = pts[mini(n - 1, i + 1)]
		var fwd := Vector3(p_next.x - p_prev.x, 0.0, p_next.z - p_prev.z)
		if fwd.length_squared() < 1e-8:
			rights[i] = Vector3.RIGHT
		else:
			fwd = fwd.normalized()
			rights[i] = Vector3(-fwd.z, 0.0, fwd.x)

	for i in range(n - 1):
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var ra: Vector3 = rights[i]
		var rb: Vector3 = rights[i + 1]

		var in_tunnel := (t_entry != -1 and i >= t_entry and i < t_exit)
		if in_tunnel:
			# Dashed translucent subterranean tunnel alignment visible through the mountain
			if i % 2 == 0:
				var tw := 0.009
				var lift := Vector3(0, 0.006, 0)
				_emit_quad(st_tun, a - ra * tw + lift, b - rb * tw + lift, b + rb * tw + lift, a + ra * tw + lift, col_tunnel)
				has_tun_tris = true
			continue

		var is_br: bool = bridge_flags[i] or bridge_flags[i + 1]
		var half_bed := 0.011 if is_br else 0.009
		var half_skirt := half_bed * 1.45
		var y_lift := 0.0022 if is_br else 0.0007
		var bed_col := col_bridge if is_br else col_ballast
		var side_col := bed_col.darkened(0.22)

		# Continuous mitered ballast / stone bridge deck top (clockwise winding -> +Y normal)
		var a0 := a - ra * half_bed + Vector3(0, y_lift, 0)
		var a1 := a + ra * half_bed + Vector3(0, y_lift, 0)
		var b0 := b - rb * half_bed + Vector3(0, y_lift, 0)
		var b1 := b + rb * half_bed + Vector3(0, y_lift, 0)
		_emit_quad(st, a0, b0, b1, a1, bed_col)

		# Snug ground-hugging ballast shoulder (subtle masonry deck only on water bridges)
		var drop_y := -0.012 if is_br else -0.0055
		var w_side := half_bed if is_br else half_skirt * 1.15
		var as0 := a - ra * w_side + Vector3(0, y_lift + drop_y, 0)
		var as1 := a + ra * w_side + Vector3(0, y_lift + drop_y, 0)
		var bs0 := b - rb * w_side + Vector3(0, y_lift + drop_y, 0)
		var bs1 := b + rb * w_side + Vector3(0, y_lift + drop_y, 0)
		_emit_quad(st, as0, bs0, b0, a0, side_col)
		_emit_quad(st, a1, b1, bs1, as1, side_col)

		# Dark timber-sleeper center strip + twin weathered gunmetal iron rails
		var sl := Vector3(0, y_lift + 0.0008, 0)
		var swa: Vector3 = ra * 0.006
		var swb: Vector3 = rb * 0.006
		_emit_quad(st, a - swa + sl, b - swb + sl, b + swb + sl, a + swa + sl, col_sleeper)
		for side: float in [-1.0, 1.0]:
			var rca: Vector3 = ra * (0.0046 * side)
			var rcb: Vector3 = rb * (0.0046 * side)
			var rwa: Vector3 = ra * 0.0016
			var rwb: Vector3 = rb * 0.0016
			var rl := Vector3(0, y_lift + 0.0016, 0)
			_emit_quad(st, a + rca - rwa + rl, b + rcb - rwb + rl, b + rcb + rwb + rl, a + rca + rwa + rl, col_rail)

	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat_solid
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mi)

	if has_tun_tris:
		var tun_mi := MeshInstance3D.new()
		tun_mi.mesh = st_tun.commit()
		tun_mi.material_override = mat_tunnel_guide
		tun_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(tun_mi)

	# Spawn rock-hooded 3D stone masonry tunnel portals facing outward toward approaching track
	# (their -Z rocky mountain mound extends inward to cover & hide the track behind the portal!)
	if t_entry >= 0 and t_exit > t_entry:
		var entry_i := t_entry
		var exit_i := t_exit
		var portal_specs := [
			[entry_i, maxi(0, entry_i - 1)],
			[exit_i, mini(n - 1, exit_i + 1)],
		]
		for spec in portal_specs:
			var p: Vector3 = pts[spec[0]]
			var p_out: Vector3 = pts[spec[1]]
			var out_dx := p_out.x - p.x
			var out_dz := p_out.z - p.z
			var portal := MeshInstance3D.new()
			portal.mesh = mesh_tunnel_portal
			portal.material_override = mat_solid
			portal.position = Vector3(p.x, p.y, p.z)
			# Local +Z (open arch) points directly toward p_out; local -Z (rocky mound) buries into mountain
			portal.rotation = Vector3(0.0, atan2(out_dx, out_dz), 0.0)
			portal.scale = Vector3.ONE * 0.048
			portal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			root.add_child(portal)

	return root


func _update_preview_mesh(inst: MeshInstance3D, pv: Dictionary) -> void:
	if pv.is_empty() or pv.get("pts", []).size() < 2:
		inst.visible = false
		return
	var pts: Array = pv["pts"]
	var n := pts.size()
	var rights: Array[Vector3] = []
	rights.resize(n)
	for i in range(n):
		var p_prev: Vector3 = pts[maxi(0, i - 1)]
		var p_next: Vector3 = pts[mini(n - 1, i + 1)]
		var fwd := Vector3(p_next.x - p_prev.x, 0.0, p_next.z - p_prev.z)
		rights[i] = Vector3.RIGHT if fwd.length_squared() < 1e-8 else Vector3(-fwd.z, 0.0, fwd.x).normalized()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(n - 1):
		var a: Vector3 = pts[i] + Vector3(0, 0.010, 0)
		var b: Vector3 = pts[i + 1] + Vector3(0, 0.010, 0)
		var ra: Vector3 = rights[i] * 0.013
		var rb: Vector3 = rights[i + 1] * 0.013
		_emit_quad(st, a - ra, b - rb, b + rb, a + ra, Color.WHITE)
	st.generate_normals()
	inst.mesh = st.commit()
	if not pv.get("valid", false):
		inst.material_override = mat_ghost_bad
	elif pv.get("has_bridge", false) or pv.get("has_tunnel", false):
		inst.material_override = mat_ghost_warn
	else:
		inst.material_override = mat_ghost_ok
	inst.visible = true


func _emit_quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, col: Color) -> void:
	st.set_color(col)
	st.add_vertex(p0)
	st.set_color(col)
	st.add_vertex(p1)
	st.set_color(col)
	st.add_vertex(p2)
	st.set_color(col)
	st.add_vertex(p0)
	st.set_color(col)
	st.add_vertex(p2)
	st.set_color(col)
	st.add_vertex(p3)


func _sample_river(xz: Vector2) -> float:
	if not world_ref:
		return 0.0
	return world_ref.sample_water_mask(xz.x, xz.y)


func _eval_bezier(p0: Vector2, c1: Vector2, c2: Vector2, p1: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return p0 * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t) + p1 * (t * t * t)


func _eval_bezier_tangent(p0: Vector2, c1: Vector2, c2: Vector2, p1: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return (c1 - p0) * (3.0 * u * u) + (c2 - c1) * (6.0 * u * t) + (p1 - c2) * (3.0 * t * t)


# ==============================================================================
# Directed Pathfinding, Passenger Lines, 3D Steam Trains & Economy
# ==============================================================================

func find_station_route(st_idx_a: int, st_idx_b: int) -> Dictionary:
	if st_idx_a < 0 or st_idx_a >= stations.size() or st_idx_b < 0 or st_idx_b >= stations.size() or st_idx_a == st_idx_b:
		return {"valid": false, "segs": [], "km": 0.0}

	var st_a = stations[st_idx_a]
	var st_b = stations[st_idx_b]
	var goal_nodes := {st_b["node_a"]: true, st_b["node_b"]: true}

	# State-space Dijkstra over (node_id, incoming_edge_id) so mesh routing respects:
	# 1) Directional double-tracks (+1 / -1) and bi-directional single tracks (0)
	# 2) Smooth forward turnouts at Y-switches (forbids instant 180-deg hairpin reversals outside stations)
	# 3) Multi-hop traversal through intermediate stations & mesh loops!
	var dist: Dictionary = {}       # "nid:in_eid" -> float (virtual routing cost)
	var real_km: Dictionary = {}    # "nid:in_eid" -> float (actual track length km)
	var state_dir: Dictionary = {}  # "nid:in_eid" -> Vector2 (preserved across crossovers!)
	var prev_state: Dictionary = {} # state_key -> prev_state_key
	var prev_edge: Dictionary = {}  # state_key -> {edge_id, forward, length_km}
	var visited: Dictionary = {}

	var start_k1 := "%d:0" % int(st_a["node_a"])
	var start_k2 := "%d:0" % int(st_a["node_b"])
	dist[start_k1] = 0.0
	dist[start_k2] = 0.0
	real_km[start_k1] = 0.0
	real_km[start_k2] = 0.0

	var reached_key := ""
	while true:
		var best_k := ""
		var best_d := 1e18
		for k in dist.keys():
			if not visited.has(k) and float(dist[k]) < best_d:
				best_d = float(dist[k])
				best_k = k
		if best_k.is_empty():
			break
		visited[best_k] = true

		var parts := best_k.split(":")
		var cur_n := int(parts[0])
		var in_eid := int(parts[1])
		if goal_nodes.has(cur_n):
			reached_key = best_k
			break

		# Use the preserved incoming travel direction at non-station nodes so even traversing
		# a dual-track crossover NEVER allows a 180-degree U-turn!
		var at_station: bool = int(nodes[cur_n]["station_id"]) != -1
		var has_in_dir: bool = (not at_station) and state_dir.has(best_k)
		var in_dir: Vector2 = state_dir[best_k] if has_in_dir else Vector2.ZERO
		var prev_was_internal: bool = (in_eid != 0 and edges.has(in_eid) and bool(edges[in_eid].get("internal", false)))

		var n_edges: Array = nodes[cur_n]["edges"]
		for eid in n_edges:
			if eid == in_eid and not at_station:
				continue
			if not edges.has(eid):
				continue
			var e = edges[eid]
			var is_internal: bool = bool(e.get("internal", false))
			# Never bounce back-and-forth across two consecutive internal crossover edges
			if is_internal and prev_was_internal and not at_station:
				continue
			var dir: int = int(e.get("direction", 0))
			var next_n := 0
			var forward := true
			if int(e["node_a"]) == cur_n:
				if dir == -1:
					continue
				next_n = int(e["node_b"])
				forward = true
			elif int(e["node_b"]) == cur_n:
				if dir == 1:
					continue
				next_n = int(e["node_a"])
				forward = false
			else:
				continue

			# Enforce smooth switch angle on every real track (INCLUDING right after a crossover!)
			var next_dir := in_dir
			var has_next_dir := has_in_dir
			if not is_internal:
				var epts: Array = e["pts"]
				if epts.size() >= 2:
					var out_dir := Vector2.ZERO
					var end_dir := Vector2.ZERO
					if forward:
						out_dir = Vector2((epts[1] as Vector3).x - (epts[0] as Vector3).x,
										  (epts[1] as Vector3).z - (epts[0] as Vector3).z).normalized()
						end_dir = Vector2((epts[epts.size() - 1] as Vector3).x - (epts[epts.size() - 2] as Vector3).x,
										  (epts[epts.size() - 1] as Vector3).z - (epts[epts.size() - 2] as Vector3).z).normalized()
					else:
						out_dir = Vector2((epts[epts.size() - 2] as Vector3).x - (epts[epts.size() - 1] as Vector3).x,
										  (epts[epts.size() - 2] as Vector3).z - (epts[epts.size() - 1] as Vector3).z).normalized()
						end_dir = Vector2((epts[0] as Vector3).x - (epts[1] as Vector3).x,
										  (epts[0] as Vector3).z - (epts[1] as Vector3).z).normalized()
					if has_in_dir and in_dir.dot(out_dir) < -0.15:
						continue
					next_dir = end_dir
					has_next_dir = true

			var next_k := ("%d:%d:%d" % [next_n, eid, in_eid]) if is_internal else ("%d:%d" % [next_n, eid])
			var seg_km: float = float(e["length_km"])
			# Small routing preference for direct smooth curves over junction crossovers
			var cost_pen: float = 2.5 if (is_internal and not at_station) else 0.0
			var nd := best_d + seg_km + cost_pen
			if not dist.has(next_k) or nd < float(dist[next_k]):
				dist[next_k] = nd
				real_km[next_k] = float(real_km[best_k]) + seg_km
				if has_next_dir:
					state_dir[next_k] = next_dir
				prev_state[next_k] = best_k
				prev_edge[next_k] = {"edge_id": eid, "forward": forward, "length_km": seg_km}

	if reached_key.is_empty():
		return {"valid": false, "segs": [], "km": 0.0}

	var segs: Array = []
	var cur_k := reached_key
	while prev_edge.has(cur_k):
		segs.append(prev_edge[cur_k])
		cur_k = prev_state[cur_k]
	segs.reverse()

	return {"valid": true, "segs": segs, "km": float(real_km[reached_key])}


func create_passenger_line(st_idx_a: int, st_idx_b: int) -> Dictionary:
	var ab := find_station_route(st_idx_a, st_idx_b)
	if not ab["valid"]:
		return {"ok": false, "reason": "No valid rail path from %s to %s" % [
			String(stations[st_idx_a]["name"]), String(stations[st_idx_b]["name"])]}
	var ba := find_station_route(st_idx_b, st_idx_a)
	if not ba["valid"]:
		return {"ok": false, "reason": "No return rail path from %s to %s" % [
			String(stations[st_idx_b]["name"]), String(stations[st_idx_a]["name"])]}

	var lid := next_id
	next_id += 1
	var line_name := "%s — %s" % [String(stations[st_idx_a]["name"]), String(stations[st_idx_b]["name"])]
	var line := {
		"id": lid,
		"name": line_name,
		"st_a": st_idx_a,
		"st_b": st_idx_b,
		"route_ab": ab["segs"],
		"route_ba": ba["segs"],
		"total_km": float(ab["km"]),
		"revenue_total": 0,
		"train_count": 0,
	}
	lines.append(line)
	return {"ok": true, "line": line}


func buy_train_for_line(line_id: int) -> Dictionary:
	if treasury < TRAIN_COST:
		return {"ok": false, "reason": "Insufficient funds (need £35,000)"}
	var line_idx := -1
	for i in range(lines.size()):
		if int(lines[i]["id"]) == line_id:
			line_idx = i
			break
	if line_idx == -1:
		return {"ok": false, "reason": "Line not found"}

	var line = lines[line_idx]
	treasury -= TRAIN_COST
	line["train_count"] = int(line["train_count"]) + 1

	var tid := next_id
	next_id += 1

	var loco := MeshInstance3D.new()
	loco.name = "Loco_%d" % tid
	loco.mesh = mesh_locomotive
	loco.material_override = mat_solid
	loco.scale = Vector3.ONE * TRAIN_SCALE
	loco.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(loco)

	var coaches: Array[MeshInstance3D] = []
	for c in range(3):
		var coach := MeshInstance3D.new()
		coach.name = "Coach_%d_%d" % [tid, c]
		coach.mesh = mesh_carriage
		coach.material_override = mat_solid
		coach.scale = Vector3.ONE * TRAIN_SCALE
		coach.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(coach)
		coaches.append(coach)

	# Load initial passengers at station A
	var st_a_idx: int = int(line["st_a"])
	var init_pax := _load_passengers_at_station(st_a_idx, 60)

	var train := {
		"id": tid,
		"line_id": line_id,
		"name": "Express #%d" % (trains.size() + 1),
		"going_to_b": true,
		"segs": line["route_ab"],
		"seg_idx": 0,
		"dist_u": 0.0,
		"speed_kmh": 45.0,
		"state": "RUNNING",
		"load_timer": 0.0,
		"passengers": init_pax,
		"capacity": 60,
		"trip_km": float(line["total_km"]),
		"revenue": 0,
		"smoke_timer": 0.0,
		"at_station_idx": st_a_idx,
		"loco": loco,
		"coaches": coaches,
		"world_pos": Vector3.ZERO,
	}
	trains.append(train)
	_position_train_meshes(train)
	return {"ok": true, "train": train}


func _load_passengers_at_station(st_idx: int, capacity: int) -> int:
	if st_idx < 0 or st_idx >= stations.size():
		return 15
	var c_idx: int = int(stations[st_idx]["city_idx"])
	if c_idx < 0:
		return mini(capacity, 12)
	var avail: int = int(floor(float(city_waiting_pax.get(c_idx, 20.0))))
	var board := mini(capacity, maxi(8, avail))
	city_waiting_pax[c_idx] = maxf(0.0, float(city_waiting_pax.get(c_idx, 0.0)) - float(board))
	return board


func _deliver_passengers_at_station(train: Dictionary, st_idx: int) -> void:
	if st_idx < 0 or st_idx >= stations.size():
		return
	var pax: int = int(train["passengers"])
	if pax <= 0:
		return
	var trip_km: float = float(train["trip_km"])
	var fare := int(round(float(pax) * (6.5 + trip_km * 0.22)))
	treasury += fare
	train["revenue"] = int(train["revenue"]) + fare

	for line in lines:
		if int(line["id"]) == int(train["line_id"]):
			line["revenue_total"] = int(line["revenue_total"]) + fare
			break

	# Floating green revenue popup above the destination station
	var st = stations[st_idx]
	var st_pos: Vector2 = st["pos"]
	var wy: float = world_ref.sample_world_y(st_pos.x, st_pos.y)
	_spawn_floating_popup(Vector3(st_pos.x, wy + 0.65, st_pos.y), "+£%d (%d pax)" % [fare, pax])

	# City growth driven by passenger deliveries!
	var c_idx: int = int(st["city_idx"])
	if c_idx >= 0 and world_ref:
		var acc: float = float(city_growth_accum.get(c_idx, 0.0)) + float(pax)
		if acc >= 90.0:
			acc -= 90.0
			var growth_pop := maxi(2500, int(round(float(world_ref.cities[c_idx]["population"]) * 0.015)))
			world_ref.grow_city(c_idx, growth_pop)
			_spawn_floating_popup(Vector3(st_pos.x, wy + 1.05, st_pos.y),
				"%s +%d pop!" % [String(world_ref.cities[c_idx]["name"]), growth_pop],
				Color(1.0, 0.90, 0.42))
		city_growth_accum[c_idx] = acc


func _spawn_floating_popup(pos: Vector3, text: String, col: Color = Color(0.45, 0.98, 0.56)) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.font_size = 30
	lbl.outline_size = 7
	lbl.outline_modulate = Color(0.08, 0.08, 0.08, 0.9)
	lbl.modulate = col
	lbl.position = pos
	lbl.scale = Vector3.ONE * 0.65
	add_child(lbl)
	floating_popups.append({"node": lbl, "age": 0.0})


func _spawn_steam_puff(pos: Vector3, train_dir: Vector3 = Vector3.ZERO) -> void:
	if steam_puffs.size() > 120:
		return
	var p := MeshInstance3D.new()
	p.mesh = mesh_steam_puff
	p.material_override = mat_steam_puff
	p.position = pos
	p.scale = Vector3.ONE * 0.55
	p.transparency = 0.25
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	var drift := -train_dir.normalized() * 0.008 if train_dir.length_squared() > 1e-4 else Vector3.ZERO
	steam_puffs.append({
		"node": p, "age": 0.0,
		"vel": drift + Vector3(randf_range(-0.004, 0.004), randf_range(0.013, 0.021), randf_range(-0.004, 0.004))
	})


func _update_visual_effects(delta: float) -> void:
	for i in range(floating_popups.size() - 1, -1, -1):
		var pop = floating_popups[i]
		pop["age"] = float(pop["age"]) + delta
		var lbl: Label3D = pop["node"]
		lbl.position.y += delta * 0.35
		var t := float(pop["age"]) / 2.4
		lbl.modulate.a = clampf(1.0 - t, 0.0, 1.0)
		if t >= 1.0:
			lbl.queue_free()
			floating_popups.remove_at(i)

	# Emit gentle real-time chugging steam puffs from visible running locomotives when zoomed in
	if sim_speed != SimSpeed.PAUSED and camera_zoom_dist < 10.0:
		for train in trains:
			if String(train["state"]) != "RUNNING":
				continue
			var loco: MeshInstance3D = train["loco"]
			if not is_instance_valid(loco) or not loco.visible:
				continue
			train["smoke_timer"] = float(train["smoke_timer"]) + delta
			if float(train["smoke_timer"]) >= 0.14:
				train["smoke_timer"] = 0.0
				# Locomotive local +Z points forward (smokestack at front, cabin at rear)
				var fwd := loco.global_transform.basis.z.normalized()
				var up := loco.global_transform.basis.y.normalized()
				_spawn_steam_puff(loco.position + up * 0.022 + fwd * 0.011, fwd)

	for i in range(steam_puffs.size() - 1, -1, -1):
		var sf = steam_puffs[i]
		sf["age"] = float(sf["age"]) + delta
		var n: MeshInstance3D = sf["node"]
		var t := float(sf["age"]) / 1.65
		var vel: Vector3 = sf["vel"]
		# Gentle deceleration & buoyant expansion as steam dissipates into the Alpine air
		n.position += vel * (1.0 - 0.45 * t) * delta
		n.scale = Vector3.ONE * (0.55 + t * 1.55)
		n.transparency = clampf(0.25 + t * 0.75, 0.0, 1.0)
		if t >= 1.0:
			n.queue_free()
			steam_puffs.remove_at(i)


func _station_idx_for_node(nid: int) -> int:
	if not nodes.has(nid):
		return -1
	var st_id: int = int(nodes[nid]["station_id"])
	if st_id == -1:
		return -1
	for i in range(stations.size()):
		if int(stations[i]["id"]) == st_id:
			return i
	return -1


func _is_station_occupied(st_idx: int, ignore_tid: int) -> bool:
	if st_idx < 0 or st_idx >= stations.size():
		return false
	var cap: int = int(stations[st_idx].get("tracks", 1))
	var st_eid: int = int(stations[st_idx].get("internal_edge_id", -1))
	var occ := 0
	for other in trains:
		if int(other["id"]) == ignore_tid:
			continue
		var at_st: bool = (int(other.get("at_station_idx", -1)) == st_idx)
		if not at_st and st_eid != -1:
			var o_segs: Array = other["segs"]
			var o_idx: int = int(other["seg_idx"])
			if o_idx < o_segs.size() and int(o_segs[o_idx]["edge_id"]) == st_eid:
				at_st = true
		if at_st:
			occ += 1
			if occ >= cap:
				return true
	return false


func _pick_free_platform_slot(st_idx: int, ignore_tid: int) -> int:
	if st_idx < 0 or st_idx >= stations.size() or int(stations[st_idx].get("tracks", 1)) < 2:
		return 0
	var st_eid: int = int(stations[st_idx].get("internal_edge_id", -1))
	var slot0_used := false
	for other in trains:
		if int(other["id"]) == ignore_tid:
			continue
		var at_st: bool = (int(other.get("at_station_idx", -1)) == st_idx)
		if not at_st and st_eid != -1:
			var o_segs: Array = other["segs"]
			var o_idx: int = int(other["seg_idx"])
			if o_idx < o_segs.size() and int(o_segs[o_idx]["edge_id"]) == st_eid:
				at_st = true
		if at_st and int(other.get("platform_slot", 0)) == 0:
			slot0_used = true
			break
	return 1 if slot0_used else 0


func _is_block_occupied(edge_id: int, t_lo: float, t_hi: float, forward: bool, ignore_tid: int) -> bool:
	if not edges.has(edge_id):
		return false
	var e = edges[edge_id]
	var e_dir: int = int(e.get("direction", 0))
	var cum: Array = e["cum_dist"]
	var total_u: float = maxf(0.01, float(cum[cum.size() - 1])) if not cum.is_empty() else 1.0
	var tail_t := minf(0.25, (CARRIAGE_SPACING * 3.2) / total_u)

	# If this block terminates directly at a station, it is OCCUPIED whenever that station is occupied!
	if forward and t_hi >= 0.99:
		var dest_st := _station_idx_for_node(int(e["node_b"]))
		if dest_st >= 0 and _is_station_occupied(dest_st, ignore_tid):
			return true
	elif (not forward) and t_lo <= 0.01:
		var dest_st := _station_idx_for_node(int(e["node_a"]))
		if dest_st >= 0 and _is_station_occupied(dest_st, ignore_tid):
			return true

	for other in trains:
		if int(other["id"]) == ignore_tid:
			continue
		# A train still parked inside a station platform (LOADING or WAITING at dist_u == 0)
		# has not yet entered the open track — don't falsely occupy the track or deadlock opposing departures!
		if int(other.get("at_station_idx", -1)) >= 0 and float(other["dist_u"]) < 0.02 and String(other["state"]) != "RUNNING":
			continue
		var o_segs: Array = other["segs"]
		var o_idx: int = int(other["seg_idx"])
		if o_idx >= o_segs.size():
			continue
		var o_seg = o_segs[o_idx]
		if int(o_seg["edge_id"]) != edge_id:
			continue
		var o_fwd: bool = bool(o_seg["forward"])
		# On a bi-directional single track, ANY opposite-direction train occupies the entire edge!
		if e_dir == 0 and o_fwd != forward:
			return true
		var o_d: float = float(other["dist_u"])
		var head_t: float = (o_d / total_u) if o_fwd else (1.0 - o_d / total_u)
		var back_t: float = clampf(head_t - tail_t, 0.0, 1.0) if o_fwd else clampf(head_t + tail_t, 0.0, 1.0)
		var tr_lo := minf(head_t, back_t)
		var tr_hi := maxf(head_t, back_t)
		# Interval overlap check between train [tr_lo, tr_hi] and signal block [t_lo, t_hi]
		if tr_hi >= t_lo - 0.02 and tr_lo <= t_hi + 0.02:
			return true
	return false


func _update_signal_lights() -> void:
	for eid in edges.keys():
		var e = edges[eid]
		var sigs: Array = e["signals"]
		if sigs.is_empty():
			continue
		var n_sigs := sigs.size()
		for i in range(n_sigs):
			var sig = sigs[i]
			var st: float = float(sig["t"])
			var sdir: int = int(sig["dir"])
			var fwd := (sdir >= 0)
			var t_lo := st if fwd else (float(sigs[i - 1]["t"]) if i > 0 else 0.0)
			var t_hi := (float(sigs[i + 1]["t"]) if i + 1 < n_sigs else 1.0) if fwd else st

			var occupied := _is_block_occupied(eid, t_lo, t_hi, fwd, -1)
			var was_red: bool = bool(sig.get("is_red", false))
			if occupied != was_red:
				sig["is_red"] = occupied
				var smat: StandardMaterial3D = sig.get("mat", null)
				if smat != null:
					if occupied:
						smat.albedo_color = Color(1.0, 0.24, 0.20)
						smat.emission = Color(1.0, 0.14, 0.10)
						smat.emission_energy_multiplier = 1.6
					else:
						var stype: int = int(sig["type"])
						if stype == SignalType.CHAIN:
							smat.albedo_color = Color(0.55, 0.85, 1.0)
							smat.emission = Color(0.25, 0.65, 1.0)
						elif stype == SignalType.ONE_WAY:
							smat.albedo_color = Color(0.55, 1.0, 0.65)
							smat.emission = Color(0.25, 0.90, 0.40)
						else:
							smat.albedo_color = Color(1.0, 0.88, 0.45)
							smat.emission = Color(0.95, 0.72, 0.18)
						smat.emission_energy_multiplier = 0.8


func _check_signal_stop(train: Dictionary, e: Dictionary, eid: int, forward: bool,
		cur_d: float, next_d: float, total_u: float, segs: Array, seg_idx: int) -> bool:
	var tid: int = int(train["id"])
	var cur_t := (cur_d / total_u) if forward else (1.0 - cur_d / total_u)
	var next_t := (next_d / total_u) if forward else (1.0 - next_d / total_u)

	# 0. Before departing a station onto a bi-directional single track (dir == 0), ensure no oncoming train is already on it!
	if seg_idx == 0 and cur_d < 0.05 and int(e.get("direction", 0)) == 0:
		if _is_block_occupied(eid, 0.0, 1.0, forward, tid):
			train["wait_reason"] = "R0_SINGLE_DEPART(e=%d)" % eid
			return true

	# 1. Strictly obey ANY red signal ahead on the current edge (wide catch window for 1x-4x speed!)
	var sigs: Array = e["signals"]
	var n_sigs := sigs.size()
	for i in range(n_sigs):
		var sig = sigs[i]
		var sdir: int = int(sig["dir"])
		if (forward and sdir < 0) or (not forward and sdir > 0 and int(e.get("direction", 0)) != 0):
			continue
		var st: float = float(sig["t"])
		# Check if train is approaching or right at signal st (never skips over it even at 4x speed)
		var approaching := false
		if forward:
			approaching = (cur_t <= st + 0.015) and (next_t >= st - 0.045)
		else:
			approaching = (cur_t >= st - 0.015) and (next_t <= st + 0.045)
		if approaching:
			var t_lo := st if forward else (float(sigs[i - 1]["t"]) if i > 0 else 0.0)
			var t_hi := (float(sigs[i + 1]["t"]) if i + 1 < n_sigs else 1.0) if forward else st
			# Check occupancy ignoring `tid` (self) so a train NEVER self-deadlocks on its own red signal!
			if _is_block_occupied(eid, t_lo, t_hi, forward, tid):
				train["wait_reason"] = "R1_SIG(e=%d,t=%.2f)" % [eid, st]
				return true

	# 2. Check safe headway behind another same-direction train on this edge
	for other in trains:
		if int(other["id"]) == tid:
			continue
		var o_segs: Array = other["segs"]
		var o_idx: int = int(other["seg_idx"])
		if o_idx < o_segs.size() and int(o_segs[o_idx]["edge_id"]) == eid and bool(o_segs[o_idx]["forward"]) == forward:
			var gap := float(other["dist_u"]) - cur_d
			if gap > 0.0 and gap < 0.28:
				train["wait_reason"] = "R2_HEADWAY(e=%d,other=%d,gap=%.2f)" % [eid, int(other["id"]), gap]
				return true

	# 3. Before entering the DESTINATION station on the final leg, wait outside the physical station throat taper if station is occupied!
	if seg_idx == segs.size() - 1 and next_d >= total_u - 0.32:
		var end_node := int(e["node_b"]) if forward else int(e["node_a"])
		var dest_st := _station_idx_for_node(end_node)
		if dest_st >= 0 and _is_station_occupied(dest_st, tid):
			train["wait_reason"] = "R3_STATION(st=%d)" % dest_st
			return true

	# 4. Before entering the NEXT edge segment, check if its entry block (or entire single-track) is occupied!
	#    Stop cleanly behind the Y-switch fouling point (0.32u) so trains on other branches can pass freely!
	#    If the next edge is a short crossover/junction (< 0.45 units), act like a CHAIN SIGNAL:
	#    check BOTH the crossover AND the exit edge beyond it so no train ever parks inside a junction!
	var r4_stop_dist := minf(0.32, total_u * 0.35)
	if next_d >= total_u - r4_stop_dist and seg_idx + 1 < segs.size():
		var k := seg_idx + 1
		var check_end := mini(segs.size(), seg_idx + 2)
		while k < check_end:
			var nseg = segs[k]
			var neid: int = int(nseg["edge_id"])
			k += 1
			if not edges.has(neid) or edges[neid].get("internal", false):
				continue
			var ne = edges[neid]
			var nfwd: bool = bool(nseg["forward"])
			var ncum: Array = ne["cum_dist"]
			var ntotal_u: float = float(ncum[ncum.size() - 1]) if not ncum.is_empty() else 1.0
			if ntotal_u < 0.45:
				if k < segs.size() and check_end == k:
					check_end = k + 1
				var cmid: Vector2 = (ne["p0"] as Vector2).lerp(ne["p1"] as Vector2, 0.5)
				for other in trains:
					var otid: int = int(other["id"])
					if otid == tid or String(other["state"]) == "LOADING":
						continue
					var o_loco: MeshInstance3D = other["loco"]
					if Vector2(o_loco.position.x - cmid.x, o_loco.position.z - cmid.y).length() < 0.30:
						train["wait_reason"] = "R4_CROSSOVER(ne=%d,other=%d)" % [neid, otid]
						return true
					for c in other["coaches"]:
						var cp: Vector3 = (c as MeshInstance3D).position
						if Vector2(cp.x - cmid.x, cp.z - cmid.y).length() < 0.30:
							train["wait_reason"] = "R4_CROSSOVER(ne=%d,other=%d)" % [neid, otid]
							return true
			var nsigs: Array = ne["signals"]
			var nt_lo := 0.0
			var nt_hi := 1.0
			# On bi-directional single track (dir == 0), ALWAYS reserve the entire segment [0..1]
			# so two opposing trains never enter the same single track and deadlock mid-segment!
			if int(ne.get("direction", 0)) != 0 and not nsigs.is_empty():
				if nfwd:
					nt_hi = float(nsigs[0]["t"])
				else:
					nt_lo = float(nsigs[nsigs.size() - 1]["t"])
			if _is_block_occupied(neid, nt_lo, nt_hi, nfwd, tid):
				train["wait_reason"] = "R4_NEXT_EDGE(ne=%d)" % neid
				return true

	# 5. Spatial junction & crossing protection (scaled to fine-scale DOUBLE_TRACK_OFFSET = 0.06u!)
	if int(train.get("at_station_idx", -1)) >= 0:
		return false
	if (not e.get("internal", false)) and total_u < 0.45:
		return false

	var our_s := _sample_edge_at_dist(e, cur_d, forward)
	var our_pos: Vector3 = our_s["pos"]
	var our_fwd2 := Vector2((our_s["dir"] as Vector3).x, (our_s["dir"] as Vector3).z).normalized()
	var q0 := _sample_route_ahead(segs, seg_idx, cur_d, 0.03)["pos"] as Vector3
	var q1 := _sample_route_ahead(segs, seg_idx, cur_d, 0.14)["pos"] as Vector3
	var q2 := _sample_route_ahead(segs, seg_idx, cur_d, 0.28)["pos"] as Vector3
	var q3 := _sample_route_ahead(segs, seg_idx, cur_d, 0.45)["pos"] as Vector3
	var s0 := Vector2(q0.x, q0.z)
	var s1 := Vector2(q1.x, q1.z)
	var s2 := Vector2(q2.x, q2.z)
	var s3 := Vector2(q3.x, q3.z)

	for other in trains:
		var otid: int = int(other["id"])
		if otid == tid:
			continue
		if String(other["state"]) == "LOADING" or int(other.get("at_station_idx", -1)) >= 0:
			continue
		var o_segs: Array = other["segs"]
		var o_idx: int = int(other["seg_idx"])
		var same_edge: bool = (o_idx < o_segs.size() and int(o_segs[o_idx]["edge_id"]) == eid)
		var o_loco: MeshInstance3D = other["loco"]
		var o_pts: Array[Vector3] = [o_loco.position]
		for c in other["coaches"]:
			o_pts.append((c as MeshInstance3D).position)
		if String(other["state"]) == "RUNNING":
			o_pts.append(_sample_route_ahead(o_segs, o_idx, float(other["dist_u"]), 0.08)["pos"])
			o_pts.append(_sample_route_ahead(o_segs, o_idx, float(other["dist_u"]), 0.18)["pos"])
			o_pts.append(_sample_route_ahead(o_segs, o_idx, float(other["dist_u"]), 0.30)["pos"])

		var min_d0 := 1e9
		var min_dfwd := 1e9
		for op in o_pts:
			var op2 := Vector2(op.x, op.z)
			min_d0 = minf(min_d0, op2.distance_to(Vector2(our_pos.x, our_pos.z)))
			var d_a := op2.distance_to(Geometry2D.get_closest_point_to_segment(op2, s0, s1))
			var d_b := op2.distance_to(Geometry2D.get_closest_point_to_segment(op2, s1, s2))
			var d_c := op2.distance_to(Geometry2D.get_closest_point_to_segment(op2, s2, s3))
			min_dfwd = minf(min_dfwd, minf(d_a, minf(d_b, d_c)))

		# Parallel double tracks are DOUBLE_TRACK_OFFSET (0.022u) apart; continuous corridor radius 0.018u > 0.014u collision!
		if min_dfwd < 0.018:
			var o_s := _sample_route_ahead(o_segs, o_idx, float(other["dist_u"]), 0.0)
			var o_fwd2 := Vector2((o_s["dir"] as Vector3).x, (o_s["dir"] as Vector3).z).normalized()
			var lp: Vector3 = o_loco.position
			var lat_dist := absf((lp.x - our_pos.x) * (-our_fwd2.y) + (lp.z - our_pos.z) * our_fwd2.x)
			if (not same_edge) and our_fwd2.dot(o_fwd2) < -0.55 and lat_dist > 0.014:
				continue
			# Opposite-direction one-way rails at a 2-track station throat use separate entry/exit switches
			# to Platform 1 vs Platform 2 — never deadlock head-to-head inside the station throat!
			if (not same_edge) and our_fwd2.dot(o_fwd2) < -0.55 and int(e.get("direction", 0)) != 0:
				var o_eid: int = int(o_segs[o_idx]["edge_id"]) if o_idx < o_segs.size() else -1
				if o_eid != -1 and edges.has(o_eid) and int(edges[o_eid].get("direction", 0)) == -int(e.get("direction", 0)):
					if _is_near_two_track_station(Vector2(our_pos.x, our_pos.z), 0.35):
						continue
			if (not same_edge) and String(other["state"]) == "WAITING":
				var o_reason: String = String(other.get("wait_reason", ""))
				var waiting_for_our_edge := (o_reason == ("R4_NEXT_EDGE(ne=%d)" % eid))
				var loco_d0 := Vector2(lp.x - our_pos.x, lp.z - our_pos.z).length()
				if (tid < otid and (loco_d0 > 0.018 or String(train["state"]) == "WAITING")) or (waiting_for_our_edge and loco_d0 > 0.018):
					continue
			train["wait_reason"] = "R5_JUNCT(e=%d,other=%d,d0=%.2f,df=%.3f)" % [eid, otid, min_d0, min_dfwd]
			return true

	return false


func _is_near_two_track_station(pos2: Vector2, radius: float) -> bool:
	var r2 := radius * radius
	for st in stations:
		if int(st.get("tracks", 1)) >= 2 and pos2.distance_squared_to(st["pos"]) <= r2:
			return true
	return false


func _sample_route_ahead(segs: Array, seg_idx: int, dist_u: float, ahead_u: float) -> Dictionary:
	if segs.is_empty():
		return {"pos": Vector3.ZERO, "dir": Vector3.FORWARD, "in_tunnel": false}
	var idx := clampi(seg_idx, 0, segs.size() - 1)
	var d := dist_u + ahead_u
	while idx < segs.size():
		var e = edges[int(segs[idx]["edge_id"])]
		var cum: Array = e["cum_dist"]
		var total_u: float = float(cum[cum.size() - 1]) if not cum.is_empty() else 0.1
		if d <= total_u or idx == segs.size() - 1:
			return _sample_edge_at_dist(e, clampf(d, 0.0, total_u), bool(segs[idx]["forward"]))
		d -= total_u
		idx += 1
	return {"pos": Vector3.ZERO, "dir": Vector3.FORWARD, "in_tunnel": false}


func _check_train_collisions() -> void:
	for i in range(trains.size()):
		var t1 = trains[i]
		if String(t1["state"]) == "LOADING" or int(t1.get("at_station_idx", -1)) >= 0:
			continue
		var p1: Vector3 = (t1["loco"] as MeshInstance3D).position
		for j in range(i + 1, trains.size()):
			var t2 = trains[j]
			if String(t2["state"]) == "LOADING" or int(t2.get("at_station_idx", -1)) >= 0:
				continue
			# Check locomotive-to-locomotive & locomotive-to-coach physical overlap (< 0.11 units!)
			var t2_parts: Array[Vector3] = [(t2["loco"] as MeshInstance3D).position]
			for c in t2["coaches"]:
				t2_parts.append((c as MeshInstance3D).position)
			for p2 in t2_parts:
				if p1.distance_to(p2) < 0.014:
					# Opposite-direction one-way trains passing through a 2-track station's dual-platform switches
					var e1_chk: int = int(t1["segs"][int(t1["seg_idx"])]["edge_id"]) if int(t1["seg_idx"]) < (t1["segs"] as Array).size() else -1
					var e2_chk: int = int(t2["segs"][int(t2["seg_idx"])]["edge_id"]) if int(t2["seg_idx"]) < (t2["segs"] as Array).size() else -1
					if e1_chk != e2_chk and edges.has(e1_chk) and edges.has(e2_chk):
						var d1: int = int(edges[e1_chk].get("direction", 0))
						var d2: int = int(edges[e2_chk].get("direction", 0))
						if d1 != 0 and d2 == -d1 and _is_near_two_track_station(Vector2(p1.x, p1.z), 0.35):
							break
					if float(t1.get("crash_cooldown", 0.0)) <= 0.0:
						collision_count += 1
						var e1_id: int = int(t1["segs"][int(t1["seg_idx"])]["edge_id"]) if int(t1["seg_idx"]) < (t1["segs"] as Array).size() else -1
						var e2_id: int = int(t2["segs"][int(t2["seg_idx"])]["edge_id"]) if int(t2["seg_idx"]) < (t2["segs"] as Array).size() else -1
						var msg := "COLLISION #%d: %s (e=%d,%s) & %s (e=%d,%s) at (%.2f, %.2f)" % [
							collision_count, String(t1["name"]), e1_id, String(t1["state"]),
							String(t2["name"]), e2_id, String(t2["state"]), p1.x, p1.z]
						collision_log.append(msg)
						print(msg)
						_spawn_floating_popup(p1 + Vector3(0, 0.6, 0), "CRASH!", Color(1.0, 0.18, 0.15))
						t1["crash_cooldown"] = 3.0
						t2["crash_cooldown"] = 3.0
					break


func fwd_for_sig(f: bool) -> bool:
	return f


func _update_trains(sim_dt: float) -> void:
	# Sub-step large speed multipliers (60x / 300x) so each physics step advances <= ~0.035u
	# (guarantees identical signal, junction, and collision safety at every timescale!)
	var n_sub := maxi(1, int(ceil(sim_dt / 12.0)))
	var sub_dt := sim_dt / float(n_sub)
	for _k in range(n_sub):
		_step_trains(sub_dt)


func _step_trains(sim_dt: float) -> void:
	_update_signal_lights()

	for train in trains:
		if float(train.get("crash_cooldown", 0.0)) > 0.0:
			train["crash_cooldown"] = maxf(0.0, float(train["crash_cooldown"]) - sim_dt)
		if String(train["state"]) == "LOADING":
			train["load_timer"] = float(train["load_timer"]) - sim_dt
			if float(train["load_timer"]) <= 0.0:
				train["state"] = "RUNNING"
			continue

		var segs: Array = train["segs"]
		if segs.is_empty():
			continue
		var seg_idx: int = int(train["seg_idx"])
		if seg_idx >= segs.size():
			_on_train_arrived(train)
			continue

		var seg = segs[seg_idx]
		var eid: int = int(seg["edge_id"])
		if not edges.has(eid):
			continue
		var e = edges[eid]
		var cum: Array = e["cum_dist"]
		var total_u: float = maxf(0.05, float(cum[cum.size() - 1])) if not cum.is_empty() else 0.1
		var fwd: bool = bool(seg["forward"])

		# Realistic grade-aware European express speed (55..160 km/h at true 1x timescale!)
		var sample := _sample_edge_at_dist(e, float(train["dist_u"]), fwd)
		var pitch_grade: float = sample["dir"].y
		var target_kmh := clampf(120.0 - pitch_grade * 260.0, 55.0, 160.0)
		var cur_d: float = float(train["dist_u"])
		var step_u := (maxf(25.0, float(train["speed_kmh"])) / 3600.0 / KM_PER_UNIT) * sim_dt

		# Obey red block signals, single-track reservations & safe headway!
		if _check_signal_stop(train, e, eid, fwd, cur_d, cur_d + step_u, total_u, segs, seg_idx):
			train["state"] = "WAITING"
			train["speed_kmh"] = maxf(0.0, float(train["speed_kmh"]) - 35.0 * sim_dt)
			continue

		train["state"] = "RUNNING"
		if int(train.get("at_station_idx", -1)) >= 0 and cur_d > 0.24:
			train["at_station_idx"] = -1
		train["speed_kmh"] = lerpf(float(train["speed_kmh"]), target_kmh, clampf(sim_dt * 0.25, 0.0, 1.0))

		var speed_u := (float(train["speed_kmh"]) / 3600.0) / KM_PER_UNIT
		train["dist_u"] = cur_d + speed_u * sim_dt

		if float(train["dist_u"]) >= total_u:
			train["dist_u"] = float(train["dist_u"]) - total_u
			train["seg_idx"] = seg_idx + 1
			if int(train["seg_idx"]) >= segs.size():
				_on_train_arrived(train)
				continue

		_position_train_meshes(train)

	_check_train_collisions()


func _on_train_arrived(train: Dictionary) -> void:
	var line = null
	for l in lines:
		if int(l["id"]) == int(train["line_id"]):
			line = l
			break
	if line == null:
		return

	var arrived_st: int = int(line["st_b"]) if bool(train["going_to_b"]) else int(line["st_a"])
	_deliver_passengers_at_station(train, arrived_st)
	train["passengers"] = _load_passengers_at_station(arrived_st, int(train["capacity"]))

	# Reverse direction for return journey
	train["going_to_b"] = not bool(train["going_to_b"])
	train["segs"] = line["route_ab"] if bool(train["going_to_b"]) else line["route_ba"]
	train["seg_idx"] = 0
	train["dist_u"] = 0.0
	train["state"] = "LOADING"
	train["load_timer"] = 18.0
	train["at_station_idx"] = arrived_st
	train["platform_slot"] = _pick_free_platform_slot(arrived_st, int(train["id"]))
	_position_train_meshes(train)


func _get_train_zoom_mul() -> float:
	# Keep 3D trains at true fine scale (cartographic overlay handles overview visibility!)
	return 1.0


func set_camera_zoom(dist: float) -> void:
	camera_zoom_dist = dist


func _position_train_meshes(train: Dictionary) -> void:
	var segs: Array = train["segs"]
	if segs.is_empty():
		return
	var seg_idx: int = clampi(int(train["seg_idx"]), 0, segs.size() - 1)
	var dist_u: float = float(train["dist_u"])
	var zm := _get_train_zoom_mul()

	var loco_s := _sample_route_back(segs, seg_idx, dist_u, 0.0)
	var lat_off := 0.0
	var cur_eid: int = int(segs[seg_idx]["edge_id"])
	var active_st_idx := int(train.get("at_station_idx", -1))
	if active_st_idx == -1 and edges.has(cur_eid) and edges[cur_eid].get("internal", false):
		var sid: int = int(edges[cur_eid].get("station_id", -1))
		for si in range(stations.size()):
			if int(stations[si]["id"]) == sid:
				active_st_idx = si
				break
	if active_st_idx >= 0 and active_st_idx < stations.size() and int(stations[active_st_idx].get("tracks", 1)) >= 2:
		if not train.has("platform_slot") or (int(train.get("at_station_idx", -1)) == -1):
			train["platform_slot"] = _pick_free_platform_slot(active_st_idx, int(train["id"]))
		var slot: int = int(train.get("platform_slot", 0))
		lat_off = 0.011 if slot == 1 else -0.011

	var loco: MeshInstance3D = train["loco"]
	_apply_vehicle_transform(loco, loco_s, zm, lat_off)
	train["world_pos"] = loco.position

	var coaches: Array = train["coaches"]
	for c in range(coaches.size()):
		var cs := _sample_route_back(segs, seg_idx, dist_u, float(c + 1) * CARRIAGE_SPACING * zm)
		_apply_vehicle_transform(coaches[c], cs, zm, lat_off)


func _apply_vehicle_transform(inst: MeshInstance3D, sample: Dictionary, zoom_mul: float = 1.0, lat_offset: float = 0.0) -> void:
	inst.visible = not bool(sample["in_tunnel"])
	var pos: Vector3 = sample["pos"]
	var dir: Vector3 = sample["dir"]
	# Orient local +Z along travel direction with real 3D hill pitch
	if dir.length_squared() > 1e-6:
		var fwd := dir.normalized()
		var right := Vector3.UP.cross(fwd)
		if right.length_squared() < 1e-6:
			right = Vector3.RIGHT
		else:
			right = right.normalized()
		var up := fwd.cross(right).normalized()
		inst.position = pos + Vector3(0.0, 0.0045, 0.0) + right * lat_offset
		inst.basis = Basis(right, up, fwd).scaled(Vector3.ONE * (TRAIN_SCALE * zoom_mul))
	else:
		inst.position = pos + Vector3(0.0, 0.0045, 0.0)


func _sample_route_back(segs: Array, seg_idx: int, dist_u: float, back_u: float) -> Dictionary:
	var idx := seg_idx
	var d := dist_u - back_u
	while d < 0.0 and idx > 0:
		idx -= 1
		var prev_e = edges[int(segs[idx]["edge_id"])]
		var prev_cum: Array = prev_e["cum_dist"]
		d += float(prev_cum[prev_cum.size() - 1])
	var seg = segs[idx]
	return _sample_edge_at_dist(edges[int(seg["edge_id"])], maxf(0.0, d), bool(seg["forward"]))


func _sample_edge_at_dist(e: Dictionary, dist_u: float, forward: bool) -> Dictionary:
	var pts: Array = e["pts"]
	var cum: Array = e["cum_dist"]
	var n := pts.size()
	if n < 2:
		return {"pos": Vector3.ZERO, "dir": Vector3.FORWARD, "in_tunnel": false}
	var total_u: float = float(cum[n - 1])
	var target_d := clampf(dist_u if forward else (total_u - dist_u), 0.0, total_u)

	var i := 0
	while i + 1 < n - 1 and float(cum[i + 1]) < target_d:
		i += 1
	var seg_d := maxf(1e-5, float(cum[i + 1]) - float(cum[i]))
	var frac := clampf((target_d - float(cum[i])) / seg_d, 0.0, 1.0)

	var p0: Vector3 = pts[i]
	var p1: Vector3 = pts[i + 1]
	var pos := p0.lerp(p1, frac)
	var dir := (p1 - p0) if forward else (p0 - p1)
	if dir.length_squared() < 1e-8:
		dir = Vector3.FORWARD
	else:
		dir = dir.normalized()

	var t_en: int = int(e.get("t_entry", -1))
	var t_ex: int = int(e.get("t_exit", -1))
	var in_tun := (t_en != -1 and i >= t_en and i < t_ex)
	return {"pos": pos, "dir": dir, "in_tunnel": in_tun}
