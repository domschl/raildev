extends Node3D

const MAP_W := 2048
const MAP_H := 1536
const HI_W := 4096
const HI_H := 3072
const CHUNKS_X := 32
const CHUNKS_Z := 24
const WORLD_SIZE := Vector2(204.8, 153.6)
const LAND_HEIGHT_SCALE := 0.00018
const SEA_DEPTH_SCALE := 0.00022

var height_data: PackedFloat32Array
var splat_data: PackedByteArray
var regional_packs: Array = []   # {uv_rect: Vector4, width: int, height: int, heights: PackedFloat32Array, water_img: Image}
var urban_img: Image = null
var urban_tex: ImageTexture = null
var terrain_chunks: Array = []   # {node: MeshInstance3D, center: Vector2, lod: int}
var terrain_lod_meshes: Array[ArrayMesh] = []
var cities: Array = []
var regions: Array = []
var city_labels: Array = []
var vegetation_streamer: Node3D = null
var growth_mesh_north: Mesh = null
var growth_mesh_med: Mesh = null
var growth_mat: StandardMaterial3D = null
var growth_rng := RandomNumberGenerator.new()

@onready var atlas_camera: Node3D = $AtlasCamera
@onready var railway_system: Node3D = $RailwaySystem


func _ready() -> void:
	_setup_environment_and_sun()
	_load_map_data()
	_build_terrain_and_water()
	_append_local_regional_towns()
	_build_instanced_forests()
	_build_3d_cities()
	if railway_system:
		railway_system.setup_world(self)
	if atlas_camera:
		atlas_camera.setup_world(self, railway_system)
	var veg_script := load("res://scripts/VegetationStreamer.gd")
	if veg_script:
		vegetation_streamer = Node3D.new()
		vegetation_streamer.name = "VegetationStreamer"
		vegetation_streamer.set_script(veg_script)
		add_child(vegetation_streamer)
		vegetation_streamer.setup(self, railway_system)
	_check_visual_test_args()


func _check_visual_test_args() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := ""
	var run_sim := false
	for i in range(args.size()):
		if args[i] == "--visual-test" and i + 1 < args.size():
			out_dir = args[i + 1]
		elif args[i] == "--sim-test":
			run_sim = true
	if run_sim:
		call_deferred("_run_sim_stress_test")
		return
	if out_dir.is_empty():
		return
	call_deferred("_run_visual_test", out_dir)


func _run_sim_stress_test() -> void:
	print("=== RAILDEV FAST SIMULATION STRESS TEST ===")
	railway_system.treasury = 5000000
	var munich := map_to_world_xz(1222.0, 727.0)
	var frankfurt := map_to_world_xz(1062.0, 601.0)
	var prague := map_to_world_xz(1381.0, 604.0)

	railway_system.add_station(munich, 17, "Munich Central", 2.4)
	railway_system.add_station(frankfurt, 14, "Frankfurt Central", 2.4)
	railway_system.add_station(prague, 24, "Prague Central", 0.1)

	var st0_th: Vector2 = railway_system.nodes[railway_system.stations[0]["node_a"]]["pos"]
	var st1_th: Vector2 = railway_system.nodes[railway_system.stations[1]["node_b"]]["pos"]
	var st2_th: Vector2 = railway_system.nodes[railway_system.stations[2]["node_a"]]["pos"]

	# 1. Dual-track Munich <-> Frankfurt
	railway_system.set_tool(railway_system.ToolMode.BUILD_TRACK)
	railway_system.double_track = true
	railway_system.update_hover_and_preview(st0_th, 18.0)
	railway_system.perform_primary_action(st0_th)
	railway_system.update_hover_and_preview(st1_th, 18.0)
	railway_system.perform_primary_action(st1_th)
	railway_system.clear_track_start()

	# 2. Launch 2 trains on Munich <-> Frankfurt BEFORE building the branch (tests live splicing!)
	var l1: Dictionary = railway_system.create_passenger_line(0, 1)
	if not l1["ok"]:
		push_error("Line Munich-Frankfurt failed: " + str(l1))
		get_tree().quit(1)
		return
	railway_system.buy_train_for_line(int(l1["line"]["id"]))
	for _s in range(40):
		railway_system._update_trains(22.0)
	railway_system.buy_train_for_line(int(l1["line"]["id"]))
	for _s in range(40):
		railway_system._update_trains(22.0)

	# 3. Build dual-track branch from mainline -> Prague while trains are actively running!
	var branch_pt := munich.lerp(frankfurt, 0.5)
	for e in railway_system.edges.values():
		if not e.get("internal", false) and int(e.get("direction", 0)) == 1:
			var epts: Array = e["pts"]
			if epts.size() > 6:
				var mp3: Vector3 = epts[epts.size() / 2]
				branch_pt = Vector2(mp3.x, mp3.z)
				break
	railway_system.update_hover_and_preview(branch_pt, 18.0)
	railway_system.perform_primary_action(branch_pt)
	railway_system.update_hover_and_preview(st2_th, 18.0)
	railway_system.perform_primary_action(st2_th)
	railway_system.set_tool(railway_system.ToolMode.INSPECT)

	# 4. Launch 2 more trains on Munich <-> Prague AND 2 on Frankfurt <-> Prague (6 trains total!)
	var l2: Dictionary = railway_system.create_passenger_line(0, 2)
	var l3: Dictionary = railway_system.create_passenger_line(1, 2)
	print("Line Munich-Prague ok=", l2["ok"], " | Line Frankfurt-Prague ok=", l3["ok"])
	if l2["ok"]:
		railway_system.buy_train_for_line(int(l2["line"]["id"]))
	if l3["ok"]:
		railway_system.buy_train_for_line(int(l3["line"]["id"]))
	for _s in range(60):
		railway_system._update_trains(22.0)
	if l2["ok"]:
		railway_system.buy_train_for_line(int(l2["line"]["id"]))
	if l3["ok"]:
		railway_system.buy_train_for_line(int(l3["line"]["id"]))

	# 5. Fast-forward 12,000 ticks (at realistic 120 km/h!) checking for collisions, teleports & deadlocks
	var prev_pos: Dictionary = {}
	var max_jump := 0.0
	var wait_ticks: Dictionary = {}
	var max_wait_ticks: Dictionary = {}
	for tr in railway_system.trains:
		prev_pos[int(tr["id"])] = tr["world_pos"]
		wait_ticks[int(tr["id"])] = 0
		max_wait_ticks[int(tr["id"])] = 0

	for step in range(12000):
		railway_system._update_trains(22.0)
		if step % 20 == 0:
			railway_system._advance_one_day()
		for tr in railway_system.trains:
			var tid: int = int(tr["id"])
			var cur_p: Vector3 = tr["world_pos"]
			var jump := cur_p.distance_to(prev_pos[tid])
			if jump > max_jump:
				max_jump = jump
			prev_pos[tid] = cur_p
			if String(tr["state"]) == "WAITING":
				wait_ticks[tid] = int(wait_ticks[tid]) + 1
				if int(wait_ticks[tid]) > int(max_wait_ticks[tid]):
					max_wait_ticks[tid] = wait_ticks[tid]
			else:
				wait_ticks[tid] = 0

	# Check leftover signals near junctions
	var bad_sigs := 0
	for nid in railway_system.nodes.keys():
		var n = railway_system.nodes[nid]
		if int(n["station_id"]) == -1 and (n["edges"] as Array).size() >= 3:
			var jp: Vector2 = n["pos"]
			for e in railway_system.edges.values():
				for sig in e["signals"]:
					var sn: Node3D = sig["node"]
					if sn != null and is_instance_valid(sn):
						if Vector2(sn.position.x, sn.position.z).distance_to(jp) < 0.32:
							bad_sigs += 1

	print("RESULTS after 12,000 steps (600s, ", railway_system.trains.size(), " trains):")
	print("  Collisions:          ", railway_system.collision_count)
	print("  Max single-step jump:", snappedf(max_jump, 0.001), " units (teleport if > 0.6)")
	print("  Signals in junctions:", bad_sigs)
	for tr in railway_system.trains:
		var tid: int = int(tr["id"])
		print("  ", tr["name"], " | state=", tr["state"], " | rev=£", tr["revenue"],
			" | max_wait=", max_wait_ticks[tid], " | end_wait=", wait_ticks[tid],
			" | reason=", tr.get("wait_reason", "-"))
	# 6. Verify triangular wye (AB, BC, CA) routing: add 3rd triangle chord connecting Munich-side
	#    to Prague-branch and check ZERO 180-deg turns & direct chord routing!
	var target_a := munich.lerp(branch_pt, 0.25)
	var target_c := branch_pt.lerp(prague, 0.25)
	var leg_a_pt := target_a
	var leg_c_pt := target_c
	var best_da := 1e9
	var best_dc := 1e9
	for ee in railway_system.edges.values():
		if ee.get("internal", false) or int(ee.get("direction", 0)) != 1:
			continue
		var epts: Array = ee["pts"]
		for p3 in epts:
			var pm2 := Vector2((p3 as Vector3).x, (p3 as Vector3).z)
			var da := pm2.distance_to(target_a)
			if da < best_da:
				best_da = da
				leg_a_pt = pm2
			var dc := pm2.distance_to(target_c)
			if dc < best_dc:
				best_dc = dc
				leg_c_pt = pm2
	var edges_before: int = railway_system.edges.size()
	railway_system.set_tool(railway_system.ToolMode.BUILD_TRACK)
	railway_system.double_track = true
	railway_system.update_hover_and_preview(leg_a_pt, 18.0)
	railway_system.perform_primary_action(leg_a_pt)
	railway_system.update_hover_and_preview(leg_c_pt, 18.0)
	print("  Chord preview valid=", railway_system.live_preview.get("valid", false),
		" pv2=", railway_system.live_preview2.get("valid", false),
		" reason=", railway_system.live_preview.get("reason", ""))
	var old_l2_km: float = float(l2["line"]["total_km"]) if l2["ok"] else 0.0
	railway_system.perform_primary_action(leg_c_pt)
	railway_system.set_tool(railway_system.ToolMode.INSPECT)
	var new_l2_km: float = float(l2["line"]["total_km"]) if l2["ok"] else 0.0
	print("  Edges before chord=", edges_before, " after=", railway_system.edges.size(),
		" | Live Munich-Prague line km: ", snappedf(old_l2_km, 0.1), " -> ", snappedf(new_l2_km, 0.1))

	var sharp_turns := 0
	var pairs := [[0, 1], [1, 0], [0, 2], [2, 0], [1, 2], [2, 1]]
	for pr in pairs:
		var r: Dictionary = railway_system.find_station_route(int(pr[0]), int(pr[1]))
		if not r["valid"]:
			print("  TRIANGLE ROUTE FAILED: ", pr)
			continue
		var segs: Array = r["segs"]
		var prev_end_dir := Vector2.ZERO
		var has_prev := false
		for sg in segs:
			var ee = railway_system.edges[int(sg["edge_id"])]
			if ee.get("internal", false):
				continue
			var epts: Array = ee["pts"]
			var fwd: bool = bool(sg["forward"])
			var s_dir := Vector2((epts[1] as Vector3).x - (epts[0] as Vector3).x,
				(epts[1] as Vector3).z - (epts[0] as Vector3).z).normalized() if fwd else \
				Vector2((epts[epts.size() - 2] as Vector3).x - (epts[epts.size() - 1] as Vector3).x,
				(epts[epts.size() - 2] as Vector3).z - (epts[epts.size() - 1] as Vector3).z).normalized()
			var e_dir := Vector2((epts[epts.size() - 1] as Vector3).x - (epts[epts.size() - 2] as Vector3).x,
				(epts[epts.size() - 1] as Vector3).z - (epts[epts.size() - 2] as Vector3).z).normalized() if fwd else \
				Vector2((epts[0] as Vector3).x - (epts[1] as Vector3).x,
				(epts[0] as Vector3).z - (epts[1] as Vector3).z).normalized()
			if has_prev and prev_end_dir.dot(s_dir) < -0.15:
				sharp_turns += 1
				print("  SHARP TURN on ", pr, " dot=", snappedf(prev_end_dir.dot(s_dir), 0.01))
			prev_end_dir = e_dir
			has_prev = true
		print("  Triangle route ", pr[0], "->", pr[1], ": km=", snappedf(float(r["km"]), 0.1), " segs=", segs.size())
	print("  Triangle sharp/180-deg turns: ", sharp_turns)
	get_tree().quit()


func _run_visual_test(out_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	if railway_system:
		railway_system.treasury = 2000000
		var munich := map_to_world_xz(1222.0, 727.0)
		var frankfurt := map_to_world_xz(1062.0, 601.0)
		var prague := map_to_world_xz(1381.0, 604.0)
		railway_system.add_station(munich, 17, "Munich Central", 2.4)
		railway_system.add_station(frankfurt, 14, "Frankfurt Central", 2.4)
		railway_system.add_station(prague, 24, "Prague Central", 0.1)

		var st0_th: Vector2 = railway_system.nodes[railway_system.stations[0]["node_a"]]["pos"]
		var st1_th: Vector2 = railway_system.nodes[railway_system.stations[1]["node_b"]]["pos"]
		var st2_th: Vector2 = railway_system.nodes[railway_system.stations[2]["node_a"]]["pos"]

		# 1. Dual-track mainline Munich <-> Frankfurt
		railway_system.set_tool(railway_system.ToolMode.BUILD_TRACK)
		railway_system.double_track = true
		railway_system.update_hover_and_preview(st0_th, 18.0)
		railway_system.perform_primary_action(st0_th)
		railway_system.update_hover_and_preview(st1_th, 18.0)
		railway_system.perform_primary_action(st1_th)
		railway_system.clear_track_start()

		# 2. Dual-track branch connecting smoothly into the dual-track mainline -> Prague!
		var branch_pt := munich.lerp(frankfurt, 0.5)
		for e in railway_system.edges.values():
			if not e.get("internal", false) and int(e.get("direction", 0)) == 1:
				var epts: Array = e["pts"]
				if epts.size() > 6:
					var mp3: Vector3 = epts[epts.size() / 2]
					branch_pt = Vector2(mp3.x, mp3.z)
					break
		railway_system.update_hover_and_preview(branch_pt, 18.0)
		railway_system.perform_primary_action(branch_pt)
		railway_system.update_hover_and_preview(st2_th, 18.0)
		railway_system.perform_primary_action(st2_th)
		railway_system.set_tool(railway_system.ToolMode.INSPECT)

		# Focus right on the dual-track-to-dual-track Y-junction!
		atlas_camera.target_pos = Vector3(branch_pt.x, 0.0, branch_pt.y)
		atlas_camera.current_pos = atlas_camera.target_pos
		atlas_camera.target_distance = 10.5
		atlas_camera.current_distance = 10.5

	for _f in range(8):
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_dual_junction.png"))

	# Ultra-close micro-scale shot of Munich Central station & dual tracks (cam_dist = 0.65)
	if railway_system and railway_system.stations.size() > 0:
		var m_pos: Vector2 = railway_system.stations[0]["pos"]
		atlas_camera.target_pos = Vector3(m_pos.x, 0.0, m_pos.y)
		atlas_camera.current_pos = atlas_camera.target_pos
		atlas_camera.target_distance = 0.65
		atlas_camera.current_distance = 0.65
		for _f in range(6):
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_micro_station.png"))

	# Also capture Alpine Lakes & Rivers overview (Geneva, Constance, Garda, Rhine, Danube)
	var alps_xz := map_to_world_xz(1110.0, 775.0)
	atlas_camera.target_pos = Vector3(alps_xz.x, 0.0, alps_xz.y)
	atlas_camera.current_pos = atlas_camera.target_pos
	atlas_camera.target_distance = 42.0
	atlas_camera.current_distance = 42.0
	for _f in range(6):
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_europe_lakes.png"))
	# Close-up shot of Zurich + Lake Zurich + Alpine foothills + CORINE forest canopy (cam_dist = 13.5!)
	var zurich_xz := map_to_world_xz(1055.0, 792.0)
	atlas_camera.target_pos = Vector3(zurich_xz.x, 0.0, zurich_xz.y)
	atlas_camera.current_pos = atlas_camera.target_pos
	atlas_camera.target_distance = 13.5
	atlas_camera.current_distance = 13.5
	for _f in range(6):
		await get_tree().process_frame
	# Ultra-close shot of Zugspitze / Garmisch / Karwendel + Multi-Sun-Angle Lighting Reality Check!
	var zug_xz := map_to_world_xz(1190.0, 773.0)
	atlas_camera.target_pos = Vector3(zug_xz.x, 0.0, zug_xz.y)
	atlas_camera.current_pos = atlas_camera.target_pos
	atlas_camera.target_distance = 1.6
	atlas_camera.current_distance = 1.6
	for _f in range(6):
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_alpine_forest.png"))

	atlas_camera.target_distance = 4.5
	atlas_camera.current_distance = 4.5
	for _f in range(6):
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_zugspitze.png"))

	var sun_node := get_node_or_null("SunLight") as DirectionalLight3D
	if sun_node:
		var orig_rot := sun_node.rotation_degrees
		# Morning low sun (East)
		sun_node.rotation_degrees = Vector3(-24.0, -68.0, 0.0)
		for _f in range(3):
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_zugspitze_morning.png"))
		# Golden hour low sun (West)
		sun_node.rotation_degrees = Vector3(-20.0, 112.0, 0.0)
		for _f in range(3):
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(out_dir.path_join("shot_zugspitze_golden.png"))
		sun_node.rotation_degrees = orig_rot
	get_tree().quit()


func _process(_delta: float) -> void:
	if not atlas_camera:
		return
	_update_terrain_lods()
	var cam_dist: float = atlas_camera.get_zoom_distance()
	if vegetation_streamer:
		vegetation_streamer.update_for_camera(atlas_camera.current_pos, cam_dist)
	for entry in city_labels:
		var lbl: Label3D = entry["node"]
		var tier: int = entry["tier"]
		var visible_dist := 140.0 if tier == 3 else (95.0 if tier == 2 else (55.0 if tier == 1 else 16.0))
		lbl.visible = cam_dist <= visible_dist
		# Keep label readable at both overview and close-up without becoming huge
		var s := clampf(cam_dist * 0.022, 0.14, 1.85)
		if tier == 3:
			s *= 1.18
		elif tier == 1:
			s *= 0.86
		elif tier == 0:
			s *= 0.72
		lbl.scale = Vector3.ONE * s


func map_to_world_xz(mx: float, my: float) -> Vector2:
	var u := mx / float(MAP_W)
	var v := my / float(MAP_H)
	return Vector2((u - 0.5) * WORLD_SIZE.x, (v - 0.5) * WORLD_SIZE.y)


func world_xz_to_map(wx: float, wz: float) -> Vector2:
	var u := (wx / WORLD_SIZE.x) + 0.5
	var v := (wz / WORLD_SIZE.y) + 0.5
	return Vector2(u * float(MAP_W), v * float(MAP_H))


func world_xz_to_latlon(wx: float, wz: float) -> Vector2:
	var u := (wx / WORLD_SIZE.x) + 0.5
	var v := (wz / WORLD_SIZE.y) + 0.5
	var lon := -10.5 + u * (26.5 - (-10.5))
	var lat := 59.5 - v * (59.5 - 35.5)
	return Vector2(lat, lon)


func sample_elevation_m(wx: float, wz: float) -> float:
	if height_data.is_empty():
		return 0.0
	var mp := world_xz_to_map(wx, wz)
	var fx := clampf(mp.x, 0.0, float(MAP_W - 1))
	var fy := clampf(mp.y, 0.0, float(MAP_H - 1))
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var x1 := mini(x0 + 1, MAP_W - 1)
	var y1 := mini(y0 + 1, MAP_H - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var e00 := height_data[y0 * MAP_W + x0]
	var e10 := height_data[y0 * MAP_W + x1]
	var e01 := height_data[y1 * MAP_W + x0]
	var e11 := height_data[y1 * MAP_W + x1]
	var base_e := lerpf(lerpf(e00, e10, tx), lerpf(e01, e11, tx), ty)

	# Blend exact 40-80m/px regional pack DEM when inside a loaded pack (matches GPU terrain!)
	if not regional_packs.is_empty():
		var u := (wx / WORLD_SIZE.x) + 0.5
		var v := (wz / WORLD_SIZE.y) + 0.5
		for pk in regional_packs:
			var r: Vector4 = pk["uv_rect"]
			if u >= r.x and u <= r.x + r.z and v >= r.y and v <= r.y + r.w:
				var iu := (u - r.x) / r.z
				var iv := (v - r.y) / r.w
				var pw: int = int(pk["width"])
				var ph: int = int(pk["height"])
				var pfx := clampf(iu * float(pw - 1), 0.0, float(pw - 1))
				var pfy := clampf(iv * float(ph - 1), 0.0, float(ph - 1))
				var px0 := int(floor(pfx))
				var py0 := int(floor(pfy))
				var px1 := mini(px0 + 1, pw - 1)
				var py1 := mini(py0 + 1, ph - 1)
				var ptx := pfx - float(px0)
				var pty := pfy - float(py0)
				var ph_arr: PackedFloat32Array = pk["heights"]
				var pe := lerpf(
					lerpf(ph_arr[py0 * pw + px0], ph_arr[py0 * pw + px1], ptx),
					lerpf(ph_arr[py1 * pw + px0], ph_arr[py1 * pw + px1], ptx),
					pty
				)
				var bw := smoothstep(0.0, 0.04, iu) * smoothstep(0.0, 0.04, 1.0 - iu) \
					* smoothstep(0.0, 0.04, iv) * smoothstep(0.0, 0.04, 1.0 - iv)
				base_e = lerpf(base_e, pe, bw)
	return base_e


func sample_water_mask(wx: float, wz: float) -> float:
	# Inside a regional realism pack with high-res OSM hydrography, use exact 40-80m/px water mask
	# (eliminates false bridges in Alpine lowlands near rivers!)
	if not regional_packs.is_empty():
		var u := (wx / WORLD_SIZE.x) + 0.5
		var v := (wz / WORLD_SIZE.y) + 0.5
		for pk in regional_packs:
			var wimg: Image = pk.get("water_img", null)
			if wimg == null:
				continue
			var r: Vector4 = pk["uv_rect"]
			if u >= r.x and u <= r.x + r.z and v >= r.y and v <= r.y + r.w:
				var iu := (u - r.x) / r.z
				var iv := (v - r.y) / r.w
				var px := clampi(int(round(iu * float(wimg.get_width() - 1))), 0, wimg.get_width() - 1)
				var py := clampi(int(round(iv * float(wimg.get_height() - 1))), 0, wimg.get_height() - 1)
				return wimg.get_pixel(px, py).r
	if splat_data.is_empty():
		return 0.0
	var mp := world_xz_to_map(wx, wz)
	var ix := clampi(int(round(mp.x)), 0, MAP_W - 1)
	var iy := clampi(int(round(mp.y)), 0, MAP_H - 1)
	return float(splat_data[(iy * MAP_W + ix) * 4 + 1]) / 255.0


func sample_landuse(wx: float, wz: float) -> Color:
	# Returns RGB landuse inside regional packs (R=forest, G=urban, B=roads),
	# falling back to continental CORINE forest splat outside regional packs.
	if not regional_packs.is_empty():
		var u := (wx / WORLD_SIZE.x) + 0.5
		var v := (wz / WORLD_SIZE.y) + 0.5
		for pk in regional_packs:
			var lu_img: Image = pk.get("landuse_img", null)
			if lu_img == null:
				continue
			var r: Vector4 = pk["uv_rect"]
			if u >= r.x and u <= r.x + r.z and v >= r.y and v <= r.y + r.w:
				var iu := (u - r.x) / r.z
				var iv := (v - r.y) / r.w
				var px := clampi(int(round(iu * float(lu_img.get_width() - 1))), 0, lu_img.get_width() - 1)
				var py := clampi(int(round(iv * float(lu_img.get_height() - 1))), 0, lu_img.get_height() - 1)
				return lu_img.get_pixel(px, py)
	if splat_data.is_empty():
		return Color(0.0, 0.0, 0.0, 1.0)
	var mp := world_xz_to_map(wx, wz)
	var ix := clampi(int(round(mp.x)), 0, MAP_W - 1)
	var iy := clampi(int(round(mp.y)), 0, MAP_H - 1)
	var f := float(splat_data[(iy * MAP_W + ix) * 4 + 0]) / 255.0
	return Color(f, 0.0, 0.0, 1.0)


func sample_world_y(wx: float, wz: float) -> float:
	var e := sample_elevation_m(wx, wz)
	if e >= 0.0:
		return e * LAND_HEIGHT_SCALE
	return maxf(-3.8, e * SEA_DEPTH_SCALE)


func _load_texture_direct(res_path: String, generate_mipmaps: bool = true) -> ImageTexture:
	var abs_path := ProjectSettings.globalize_path(res_path)
	var img := Image.load_from_file(abs_path)
	if img == null:
		push_error("Failed to load texture: " + abs_path)
		return ImageTexture.new()
	if generate_mipmaps:
		img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _load_glb_mesh(res_path: String) -> Mesh:
	var abs_path := ProjectSettings.globalize_path(res_path)
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var err := gltf.append_from_file(abs_path, state)
	if err != OK:
		push_error("Failed to load GLB: " + abs_path)
		return BoxMesh.new()
	var scene := gltf.generate_scene(state)
	var mesh := _find_first_mesh(scene)
	scene.queue_free()
	if mesh == null:
		push_error("No MeshInstance3D found in GLB: " + abs_path)
		return BoxMesh.new()
	return mesh


func _find_first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and node.mesh != null:
		return node.mesh
	for child in node.get_children():
		var found := _find_first_mesh(child)
		if found != null:
			return found
	return null


func _load_map_data() -> void:
	# 1. Float32 raw heightmap
	var hf := FileAccess.open("res://data/europe_height.f32", FileAccess.READ)
	if hf:
		var bytes := hf.get_buffer(MAP_W * MAP_H * 4)
		height_data = bytes.to_float32_array()
		hf.close()
	else:
		push_error("Missing res://data/europe_height.f32 — run ./build/export_map godot/data")

	# 2. RGBA8 splat map
	var sf := FileAccess.open("res://data/europe_splat.rgba", FileAccess.READ)
	if sf:
		splat_data = sf.get_buffer(MAP_W * MAP_H * 4)
		sf.close()

	# 3. Cities & Region Presets JSON
	var jf := FileAccess.open("res://data/europe_meta.json", FileAccess.READ)
	if jf:
		var parsed = JSON.parse_string(jf.get_as_text())
		jf.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			cities = parsed.get("cities", [])
			regions = parsed.get("regions", [])
			regions.append({"name": "Zugspitze / Munich (40m)", "x": 1190.0, "y": 773.0, "zoom": 10.0})
			regions.append({"name": "Pyrenees / Pic d'Aneto (80m)", "x": 617.0, "y": 1077.0, "zoom": 9.0})


func _append_local_regional_towns() -> void:
	# Iconic local railway towns inside the high-res Zugspitze & Pyrenees packs (tier=0 -> shown when zoomed in!)
	var local_towns := [
		# Munich - Zugspitze - Innsbruck Ultra Pack (40m/px)
		["Garmisch-Partenkirchen", "DE", 47.4917, 11.0955, 27000],
		["Mittenwald", "DE", 47.4419, 11.2614, 7500],
		["Seefeld in Tirol", "AT", 47.3292, 11.1878, 3600],
		["Starnberg", "DE", 47.9972, 11.3406, 23500],
		["Weilheim", "DE", 47.8398, 11.1422, 23000],
		["Murnau", "DE", 47.6775, 11.2014, 12000],
		["Rosenheim", "DE", 47.8561, 12.1289, 64000],
		["Kufstein", "AT", 47.5830, 12.1691, 19500],
		["Bad Tölz", "DE", 47.7603, 11.5567, 19000],
		["Tegernsee", "DE", 47.7094, 11.7586, 4000],
		["Augsburg", "DE", 48.3705, 10.8978, 296000],
		["Füssen", "DE", 47.5696, 10.7004, 15500],
		["Reutte", "AT", 47.4886, 10.7186, 7000],
		["Landeck", "AT", 47.1411, 10.5656, 7800],
		["Brenner", "IT", 47.0031, 11.5050, 2300],
		# Pyrenees Realism Pack (80m/px)
		["Lourdes", "FR", 43.0915, -0.0457, 13500],
		["Pau", "FR", 43.2951, -0.3708, 77000],
		["Tarbes", "FR", 43.2329, 0.0781, 43000],
		["Bagnères-de-Luchon", "FR", 42.7905, 0.5936, 2300],
		["Foix", "FR", 42.9639, 1.6069, 9500],
		["Ax-les-Thermes", "FR", 42.7196, 1.8389, 1300],
		["Andorra la Vella", "AD", 42.5063, 1.5218, 23000],
		["Jaca", "ES", 42.5701, -0.5499, 13400],
		["Canfranc", "ES", 42.7166, -0.5250, 600],
		["Vielha", "ES", 42.7024, 0.7955, 5600],
		["Huesca", "ES", 42.1401, -0.4089, 54000],
	]
	var existing_names: Dictionary = {}
	for c in cities:
		existing_names[String(c["name"])] = true
	for t in local_towns:
		var tname: String = t[0]
		if existing_names.has(tname):
			continue
		var lat: float = float(t[2])
		var lon: float = float(t[3])
		var pop: int = int(t[4])
		var u := (lon - (-10.5)) / (26.5 - (-10.5))
		var v := (59.5 - lat) / (59.5 - 35.5)
		var mx := u * float(MAP_W)
		var my := v * float(MAP_H)
		var xz := map_to_world_xz(mx, my)
		var elev := maxf(2.0, sample_elevation_m(xz.x, xz.y))
		var rad := clampf(2.6 + sqrt(float(pop) / 10000.0) * 1.4, 2.8, 7.5)
		cities.append({
			"name": tname,
			"country": String(t[1]),
			"lat": lat,
			"lon": lon,
			"population": pop,
			"tier": 0,
			"x": mx,
			"y": my,
			"elev": elev,
			"radius": rad,
			"blocks": [],
		})


func _setup_environment_and_sun() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.18, 0.40, 0.78)
	sky_mat.sky_horizon_color = Color(0.66, 0.78, 0.90)
	sky_mat.ground_bottom_color = Color(0.11, 0.21, 0.31)
	sky_mat.ground_horizon_color = Color(0.55, 0.65, 0.74)
	sky_mat.sun_angle_max = 18.0
	sky.sky_material = sky_mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.50
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.90

	# Rayleigh cool-blue atmospheric aerial perspective (separates foreground & distant Alpine ridges!)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.64, 0.76, 0.90)
	env.fog_density = 0.0042
	env.fog_aerial_perspective = 0.78
	world_env.environment = env
	add_child(world_env)

	# Warm Northwest directional sunlight casting crisp 3D Alpine & tree shadows
	var sun := DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 1.22
	sun.shadow_enabled = true
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 180.0
	sun.rotation_degrees = Vector3(-38.0, 38.0, 0.0)
	add_child(sun)


func _build_terrain_and_water() -> void:
	# Prefer full 4096x3072 z=7 Terrarium heightmap on GPU if available; fallback to 2048x1536
	var hi_path := "res://data/europe_height_hi.f32"
	var height_tex: ImageTexture
	var h_texel := Vector2(1.0 / float(MAP_W), 1.0 / float(MAP_H))
	if FileAccess.file_exists(hi_path):
		var hf := FileAccess.open(hi_path, FileAccess.READ)
		var hbytes := hf.get_buffer(HI_W * HI_H * 4)
		hf.close()
		if hbytes.size() == HI_W * HI_H * 4:
			var hi_img := Image.create_from_data(HI_W, HI_H, false, Image.FORMAT_RF, hbytes)
			height_tex = ImageTexture.create_from_image(hi_img)
			h_texel = Vector2(1.0 / float(HI_W), 1.0 / float(HI_H))
		else:
			var h_img := Image.create_from_data(MAP_W, MAP_H, false, Image.FORMAT_RF, height_data.to_byte_array())
			height_tex = ImageTexture.create_from_image(h_img)
	else:
		var h_img := Image.create_from_data(MAP_W, MAP_H, false, Image.FORMAT_RF, height_data.to_byte_array())
		height_tex = ImageTexture.create_from_image(h_img)

	var s_img := Image.create_from_data(MAP_W, MAP_H, false, Image.FORMAT_RGBA8, splat_data)
	var splat_tex := ImageTexture.create_from_image(s_img)

	var tex_north := _load_texture_direct("res://textures/terrain_grass.png")
	var tex_med := _load_texture_direct("res://textures/terrain_grass_mediterranean.png")
	var tex_rock := _load_texture_direct("res://textures/terrain_rock.png")
	var tex_forest := _load_texture_direct("res://textures/terrain_forest.png")
	var tex_urban := _load_texture_direct("res://textures/city_urban.png")
	var tex_water := _load_texture_direct("res://textures/terrain_water.png")

	# Build dynamic to-scale urban footprint mask (1024x768 R8) that expands live as cities grow!
	urban_img = Image.create(MAP_W / 2, MAP_H / 2, false, Image.FORMAT_R8)
	urban_img.fill(Color(0.0, 0.0, 0.0, 1.0))
	for i in range(cities.size()):
		_paint_city_urban_mask(i)
	urban_img.generate_mipmaps()
	urban_tex = ImageTexture.create_from_image(urban_img)

	# 1. Seam-Free 16x12 Chunked LOD 3D Terrain (4 LODs: 256x256 ultra-close, 128x128 close, 48x48 mid, 20x20 far)
	var chunk_w := WORLD_SIZE.x / float(CHUNKS_X)
	var chunk_h := WORLD_SIZE.y / float(CHUNKS_Z)
	terrain_lod_meshes = [
		_create_lod_chunk_mesh(256, chunk_w, chunk_h),
		_create_lod_chunk_mesh(128, chunk_w, chunk_h),
		_create_lod_chunk_mesh(48, chunk_w, chunk_h),
		_create_lod_chunk_mesh(20, chunk_w, chunk_h),
	]

	var terrain_mat := ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/europe_terrain.gdshader")
	terrain_mat.set_shader_parameter("height_tex", height_tex)
	terrain_mat.set_shader_parameter("splat_tex", splat_tex)
	terrain_mat.set_shader_parameter("urban_tex", urban_tex)
	terrain_mat.set_shader_parameter("tex_grass_north", tex_north)
	terrain_mat.set_shader_parameter("tex_grass_med", tex_med)
	terrain_mat.set_shader_parameter("tex_rock", tex_rock)
	terrain_mat.set_shader_parameter("tex_forest", tex_forest)
	terrain_mat.set_shader_parameter("tex_urban", tex_urban)
	terrain_mat.set_shader_parameter("world_size", WORLD_SIZE)
	terrain_mat.set_shader_parameter("height_texel", h_texel)
	terrain_mat.set_shader_parameter("land_height_scale", LAND_HEIGHT_SCALE)
	terrain_mat.set_shader_parameter("sea_depth_scale", SEA_DEPTH_SCALE)

	# Load continental Sentinel-2 Cloudless satellite albedo for ALL of Europe if baked!
	var eu_sat_path := "res://data/europe_albedo.jpg"
	if FileAccess.file_exists(eu_sat_path):
		var eu_sat_tex := _load_texture_direct(eu_sat_path, true)
		terrain_mat.set_shader_parameter("europe_albedo_tex", eu_sat_tex)
		terrain_mat.set_shader_parameter("has_europe_albedo", 1.0)

	# Step B: Load up to 2 simultaneous Regional Realism Packs (e.g. zugspitze + pyrenees!)
	var loaded_slots := 0
	for pack_name in ["zugspitze", "pyrenees", "alps"]:
		if loaded_slots >= 2:
			break
		var pack_meta_path := "res://data/packs/%s_pack.json" % pack_name
		var pack_bin_path := "res://data/packs/%s_height.f32" % pack_name
		if FileAccess.file_exists(pack_meta_path) and FileAccess.file_exists(pack_bin_path):
			var pm_f := FileAccess.open(pack_meta_path, FileAccess.READ)
			var pm = JSON.parse_string(pm_f.get_as_text())
			pm_f.close()
			if typeof(pm) == TYPE_DICTIONARY:
				var pw: int = int(pm["width"])
				var ph: int = int(pm["height"])
				var uvr: Array = pm["uv_rect"]
				var pb_f := FileAccess.open(pack_bin_path, FileAccess.READ)
				var pbytes := pb_f.get_buffer(pw * ph * 4)
				pb_f.close()
				if pbytes.size() == pw * ph * 4:
					var p_img := Image.create_from_data(pw, ph, false, Image.FORMAT_RF, pbytes)
					var p_tex := ImageTexture.create_from_image(p_img)
					var prefix := "inset" if loaded_slots == 0 else "inset2"
					terrain_mat.set_shader_parameter(prefix + "_height_tex", p_tex)
					terrain_mat.set_shader_parameter(prefix + "_uv_rect", Vector4(float(uvr[0]), float(uvr[1]), float(uvr[2]), float(uvr[3])))
					terrain_mat.set_shader_parameter(prefix + "_texel", Vector2(1.0 / float(pw), 1.0 / float(ph)))
					var sat_path := "res://data/packs/%s_albedo.jpg" % pack_name
					if FileAccess.file_exists(sat_path):
						var sat_tex := _load_texture_direct(sat_path, true)
						terrain_mat.set_shader_parameter(prefix + "_albedo_tex", sat_tex)
						terrain_mat.set_shader_parameter("has_" + prefix + "_albedo", 1.0)
					var water_img: Image = null
					var water_path := "res://data/packs/%s_water.png" % pack_name
					if FileAccess.file_exists(water_path):
						var w_abs := ProjectSettings.globalize_path(water_path)
						water_img = Image.load_from_file(w_abs)
						if water_img != null:
							var w_tex_img := water_img.duplicate()
							w_tex_img.generate_mipmaps()
							var w_tex := ImageTexture.create_from_image(w_tex_img)
							terrain_mat.set_shader_parameter(prefix + "_water_tex", w_tex)
							terrain_mat.set_shader_parameter("has_" + prefix + "_water", 1.0)
					var landuse_img: Image = null
					var lu_path := "res://data/packs/%s_landuse.png" % pack_name
					if FileAccess.file_exists(lu_path):
						landuse_img = Image.load_from_file(ProjectSettings.globalize_path(lu_path))
					regional_packs.append({
						"name": pack_name,
						"uv_rect": Vector4(float(uvr[0]), float(uvr[1]), float(uvr[2]), float(uvr[3])),
						"width": pw,
						"height": ph,
						"heights": pbytes.to_float32_array(),
						"water_img": water_img,
						"landuse_img": landuse_img,
					})
					loaded_slots += 1
					print("Loaded Regional Realism Pack [slot %d]: %s (%dx%d%s%s)" % [
						loaded_slots, String(pm.get("title", pack_name)), pw, ph,
						", OSM water" if water_img != null else "",
						", landuse" if landuse_img != null else ""])

	var chunks_root := Node3D.new()
	chunks_root.name = "EuropeTerrainChunks"
	add_child(chunks_root)
	terrain_chunks.clear()

	var du := 1.0 / float(CHUNKS_X)
	var dv := 1.0 / float(CHUNKS_Z)
	var chunk_aabb := AABB(Vector3(-0.2, -4.0, -0.2), Vector3(chunk_w + 0.4, 9.0, chunk_h + 0.4))
	for cz in range(CHUNKS_Z):
		for cx in range(CHUNKS_X):
			var inst := MeshInstance3D.new()
			inst.name = "Chunk_%d_%d" % [cx, cz]
			inst.mesh = terrain_lod_meshes[3]
			inst.material_override = terrain_mat
			inst.custom_aabb = chunk_aabb
			inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			var wx0 := -WORLD_SIZE.x * 0.5 + float(cx) * chunk_w
			var wz0 := -WORLD_SIZE.y * 0.5 + float(cz) * chunk_h
			inst.position = Vector3(wx0, 0.0, wz0)
			inst.set_instance_shader_parameter("chunk_uv_rect", Vector4(float(cx) * du, float(cz) * dv, du, dv))
			chunks_root.add_child(inst)
			terrain_chunks.append({
				"node": inst,
				"center": Vector2(wx0 + chunk_w * 0.5, wz0 + chunk_h * 0.5),
				"lod": 3,
			})

	# 2. Reflective Animated 3D Ocean Surface at y = 0
	var water_mesh := PlaneMesh.new()
	water_mesh.size = WORLD_SIZE
	water_mesh.subdivide_width = 64
	water_mesh.subdivide_depth = 48

	var water_mat := ShaderMaterial.new()
	water_mat.shader = load("res://shaders/europe_water.gdshader")
	water_mat.set_shader_parameter("height_tex", height_tex)
	water_mat.set_shader_parameter("splat_tex", splat_tex)
	water_mat.set_shader_parameter("water_tex", tex_water)

	var water_inst := MeshInstance3D.new()
	water_inst.name = "EuropeOcean"
	water_inst.mesh = water_mesh
	water_inst.material_override = water_mat
	water_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water_inst)


func _update_terrain_lods() -> void:
	if terrain_chunks.is_empty() or terrain_lod_meshes.size() < 4 or not atlas_camera:
		return
	var cp: Vector3 = atlas_camera.current_pos
	var cam_xz := Vector2(cp.x, cp.z)
	var cam_d: float = atlas_camera.get_zoom_distance()
	var r0 := 11.0 + cam_d * 0.35
	var r1 := 24.0 + cam_d * 0.55
	var r2 := 52.0 + cam_d * 0.85
	var allow_lod0 := cam_d < 24.0
	var allow_lod1 := cam_d < 56.0
	for ch in terrain_chunks:
		var d: float = cam_xz.distance_to(ch["center"] as Vector2)
		var want_lod := 3
		if allow_lod0 and d < r0:
			want_lod = 0
		elif allow_lod1 and d < r1:
			want_lod = 1
		elif d < r2:
			want_lod = 2
		if int(ch["lod"]) != want_lod:
			ch["lod"] = want_lod
			(ch["node"] as MeshInstance3D).mesh = terrain_lod_meshes[want_lod]


func _create_lod_chunk_mesh(grid_n: int, chunk_w: float, chunk_h: float) -> ArrayMesh:
	var cols := grid_n + 1
	var main_v := cols * cols
	var skirt_v := cols * 4
	var total_v := main_v + skirt_v

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	verts.resize(total_v)
	uvs.resize(total_v)
	colors.resize(total_v)

	var inv_n := 1.0 / float(grid_n)
	var col_surf := Color(0.0, 0.0, 0.0, 1.0)
	var col_skirt := Color(1.0, 0.0, 0.0, 1.0)

	for gz in range(cols):
		var v := float(gz) * inv_n
		var pz := v * chunk_h
		var row := gz * cols
		for gx in range(cols):
			var u := float(gx) * inv_n
			var idx := row + gx
			verts[idx] = Vector3(u * chunk_w, 0.0, pz)
			uvs[idx] = Vector2(u, v)
			colors[idx] = col_surf

	# Duplicate 4 border rows/cols as downward skirt vertices (COLOR.r = 1.0)
	var s_top := main_v
	var s_bot := main_v + cols
	var s_left := main_v + cols * 2
	var s_right := main_v + cols * 3
	for i in range(cols):
		# Top (gz = 0)
		var it := i
		verts[s_top + i] = verts[it]; uvs[s_top + i] = uvs[it]; colors[s_top + i] = col_skirt
		# Bottom (gz = grid_n)
		var ib := grid_n * cols + i
		verts[s_bot + i] = verts[ib]; uvs[s_bot + i] = uvs[ib]; colors[s_bot + i] = col_skirt
		# Left (gx = 0)
		var il := i * cols
		verts[s_left + i] = verts[il]; uvs[s_left + i] = uvs[il]; colors[s_left + i] = col_skirt
		# Right (gx = grid_n)
		var ir := i * cols + grid_n
		verts[s_right + i] = verts[ir]; uvs[s_right + i] = uvs[ir]; colors[s_right + i] = col_skirt

	var indices := PackedInt32Array()
	indices.resize((grid_n * grid_n + grid_n * 4) * 6)
	var wi := 0
	for gz in range(grid_n):
		var r0 := gz * cols
		var r1 := (gz + 1) * cols
		for gx in range(grid_n):
			var a := r0 + gx
			var b := a + 1
			var c := r1 + gx + 1
			var d := r1 + gx
			indices[wi] = a; indices[wi + 1] = b; indices[wi + 2] = c
			indices[wi + 3] = a; indices[wi + 4] = c; indices[wi + 5] = d
			wi += 6

	# Skirt quads along all 4 chunk borders (outward-facing, crack-free across any LOD step)
	for i in range(grid_n):
		# Top skirt (z = 0, facing -Z)
		var a := i; var b := i + 1; var sa := s_top + i; var sb := s_top + i + 1
		indices[wi] = a; indices[wi + 1] = sb; indices[wi + 2] = b
		indices[wi + 3] = a; indices[wi + 4] = sa; indices[wi + 5] = sb
		wi += 6
		# Bottom skirt (z = grid_n, facing +Z)
		a = grid_n * cols + i; b = a + 1; sa = s_bot + i; sb = s_bot + i + 1
		indices[wi] = a; indices[wi + 1] = b; indices[wi + 2] = sb
		indices[wi + 3] = a; indices[wi + 4] = sb; indices[wi + 5] = sa
		wi += 6
		# Left skirt (x = 0, facing -X)
		a = i * cols; b = (i + 1) * cols; sa = s_left + i; sb = s_left + i + 1
		indices[wi] = a; indices[wi + 1] = b; indices[wi + 2] = sb
		indices[wi + 3] = a; indices[wi + 4] = sb; indices[wi + 5] = sa
		wi += 6
		# Right skirt (x = grid_n, facing +X)
		a = i * cols + grid_n; b = (i + 1) * cols + grid_n; sa = s_right + i; sb = s_right + i + 1
		indices[wi] = a; indices[wi + 1] = sb; indices[wi + 2] = b
		indices[wi + 3] = a; indices[wi + 4] = sa; indices[wi + 5] = sb
		wi += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


func _paint_city_urban_mask(city_idx: int) -> void:
	if urban_img == null or city_idx < 0 or city_idx >= cities.size():
		return
	var c = cities[city_idx]
	var cx: float = float(c["x"]) * 0.5
	var cy: float = float(c["y"]) * 0.5
	var rad: float = float(c["radius"]) * 0.58
	var uw := urban_img.get_width()
	var uh := urban_img.get_height()
	var min_x := maxi(0, int(floor(cx - rad - 2.0)))
	var max_x := mini(uw - 1, int(ceil(cx + rad + 2.0)))
	var min_y := maxi(0, int(floor(cy - rad - 2.0)))
	var max_y := mini(uh - 1, int(ceil(cy + rad + 2.0)))
	for py in range(min_y, max_y + 1):
		for px in range(min_x, max_x + 1):
			var dx := float(px) - cx
			var dy := float(py) - cy
			var d := sqrt(dx * dx + dy * dy)
			if d > rad:
				continue
			var mx := clampi(px * 2, 0, MAP_W - 1)
			var my := clampi(py * 2, 0, MAP_H - 1)
			var idx := my * MAP_W + mx
			if height_data[idx] < 1.5 or splat_data[idx * 4 + 1] > 140:
				continue
			var w := clampf(1.0 - (d / maxf(1.0, rad)), 0.0, 1.0)
			w = pow(w, 0.55)
			var cur := urban_img.get_pixel(px, py).r
			if w > cur:
				urban_img.set_pixel(px, py, Color(w, 0.0, 0.0, 1.0))


func _build_instanced_forests() -> void:
	# Tier 1: Forests are now rendered at true map scale directly in europe_terrain.gdshader
	# from pixel-accurate Copernicus CORINE 2018 forest cover + procedural 3D crown relief!
	return
	if height_data.is_empty() or splat_data.is_empty():
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = 18350501

	var spruce_xf: Array[Transform3D] = []
	var spruce_col: Array[Color] = []
	var oak_xf: Array[Transform3D] = []
	var oak_col: Array[Color] = []
	var cypress_xf: Array[Transform3D] = []
	var cypress_col: Array[Color] = []
	var olive_xf: Array[Transform3D] = []
	var olive_col: Array[Color] = []
	var shrub_xf: Array[Transform3D] = []
	var shrub_col: Array[Color] = []

	# Sample across Europe with fine jittered spacing
	const STEP := 7
	for gy in range(8, MAP_H - 8, STEP):
		for gx in range(8, MAP_W - 8, STEP):
			var mx := float(gx) + rng.randf_range(-3.2, 3.2)
			var my := float(gy) + rng.randf_range(-3.2, 3.2)
			var ix := clampi(int(round(mx)), 0, MAP_W - 1)
			var iy := clampi(int(round(my)), 0, MAP_H - 1)
			var idx := iy * MAP_W + ix

			var elev := height_data[idx]
			if elev < 20.0 or elev > 1680.0:
				continue

			var forest_d := float(splat_data[idx * 4 + 0]) / 255.0
			var river_v := float(splat_data[idx * 4 + 1]) / 255.0
			var road_v := float(splat_data[idx * 4 + 2]) / 255.0
			var med_t := float(splat_data[idx * 4 + 3]) / 255.0

			if river_v > 0.25 or road_v > 0.25:
				continue

			var xz := map_to_world_xz(mx, my)
			var wy := elev * LAND_HEIGHT_SCALE
			var rot_y := rng.randf_range(0.0, TAU)

			# Lowland shrubs / hedgerows along forest fringes & meadows
			if forest_d >= 0.38 and forest_d < 0.48:
				if rng.randf() < 0.12:
					var ss := rng.randf_range(0.18, 0.30)
					var sb := Basis(Vector3.UP, rot_y).scaled(Vector3(ss, ss * rng.randf_range(0.8, 1.2), ss))
					shrub_xf.append(Transform3D(sb, Vector3(xz.x, wy - 0.02, xz.y)))
					var tint := rng.randf_range(0.86, 1.12)
					shrub_col.append(Color(tint, tint * (0.96 if med_t > 0.5 else 1.02), tint * 0.94))
				continue

			if forest_d < 0.48:
				continue
			if rng.randf() > clampf((forest_d - 0.44) * 2.1, 0.0, 0.86):
				continue

			# Properly miniature tree scale (~0.24..0.42 world units tall)
			var s := rng.randf_range(0.24, 0.42)
			var basis := Basis(Vector3.UP, rot_y).scaled(Vector3(s, s * rng.randf_range(0.85, 1.22), s))
			var xform := Transform3D(basis, Vector3(xz.x, wy - 0.02, xz.y))
			var v := rng.randf_range(0.86, 1.14)

			if elev > 460.0 or (med_t < 0.20 and rng.randf() < 0.42):
				spruce_xf.append(xform)
				spruce_col.append(Color(v * 0.94, v, v * 0.95))
			elif med_t > 0.48:
				if rng.randf() < 0.45:
					cypress_xf.append(xform)
					cypress_col.append(Color(v * 0.92, v, v * 0.92))
				else:
					olive_xf.append(xform)
					olive_col.append(Color(v * 1.02, v, v * 0.92))
			else:
				oak_xf.append(xform)
				oak_col.append(Color(v * 0.96, v, v * 0.92))

	var wind_mat := ShaderMaterial.new()
	wind_mat.shader = load("res://shaders/vegetation_wind.gdshader")

	_spawn_multimesh("ForestSpruce", _load_glb_mesh("res://assets/models/tree_alpine_spruce.glb"), wind_mat, spruce_xf, spruce_col)
	_spawn_multimesh("ForestOak", _load_glb_mesh("res://assets/models/tree_temperate_oak.glb"), wind_mat, oak_xf, oak_col)
	_spawn_multimesh("ForestCypress", _load_glb_mesh("res://assets/models/tree_med_cypress.glb"), wind_mat, cypress_xf, cypress_col)
	_spawn_multimesh("ForestOlive", _load_glb_mesh("res://assets/models/tree_med_olive.glb"), wind_mat, olive_xf, olive_col)
	_spawn_multimesh("VegetationShrubs", _load_glb_mesh("res://assets/models/veg_shrub_cluster.glb"), wind_mat, shrub_xf, shrub_col)


func _build_3d_cities() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 18351231

	var town_xf: Array[Transform3D] = []
	var town_col: Array[Color] = []
	var mansard_xf: Array[Transform3D] = []
	var mansard_col: Array[Color] = []
	var cath_xf: Array[Transform3D] = []
	var cath_col: Array[Color] = []
	var villa_xf: Array[Transform3D] = []
	var villa_col: Array[Color] = []
	var basilica_xf: Array[Transform3D] = []
	var basilica_col: Array[Color] = []
	var harbor_xf: Array[Transform3D] = []
	var harbor_col: Array[Color] = []

	var use_sat_cities := FileAccess.file_exists("res://data/europe_albedo.jpg")
	for city in cities:
		var cx: float = city["x"]
		var cy: float = city["y"]
		var radius_map: float = city["radius"]
		var tier: int = int(city["tier"])
		var lat: float = float(city["lat"])
		var is_med := lat < 45.2

		var center_xz := map_to_world_xz(cx, cy)
		var center_y := sample_world_y(center_xz.x, center_xz.y)

		# 4. Clean floating 3D city label (in satellite mode, real Sentinel-2 city footprints show cleanly!)
		var lbl := Label3D.new()
		lbl.text = String(city["name"])
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.font_size = 38 if tier == 3 else (32 if tier == 2 else 26)
		lbl.outline_size = 8
		lbl.outline_modulate = Color(0.10, 0.09, 0.08, 0.88)
		lbl.modulate = Color(0.99, 0.94, 0.80) if tier == 3 else Color(0.94, 0.93, 0.89)
		lbl.position = Vector3(center_xz.x, center_y + 0.45, center_xz.y)
		add_child(lbl)
		city_labels.append({"node": lbl, "tier": tier})

		if use_sat_cities:
			continue

		# 1. Historic Landmark in the city center (compact Gothic Cathedral or Mediterranean Basilica)
		var lm_scale := 0.19 if tier == 3 else (0.15 if tier == 2 else 0.12)
		var lm_basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * lm_scale)
		var lm_xform := Transform3D(lm_basis, Vector3(center_xz.x, center_y - 0.015, center_xz.y))
		if is_med:
			basilica_xf.append(lm_xform)
			basilica_col.append(Color(1.0, 0.98, 0.94))
		else:
			cath_xf.append(lm_xform)
			cath_col.append(Color(0.98, 0.98, 0.96))

		# 2. Tier 2 — Compact miniature 3D historic downtown rising out of to-scale urban fabric
		var blocks: Array = city.get("blocks", [])
		var max_blocks := 65 if tier == 3 else (40 if tier == 2 else 22)
		var step_b := maxi(1, int(ceil(float(blocks.size()) / float(max_blocks))))
		for bi in range(0, blocks.size(), step_b):
			var blk = blocks[bi]
			var bx: float = float(blk[0])
			var by: float = float(blk[1])
			var bang: float = float(blk[2])
			var bkind: int = int(blk[3])

			# Keep central plaza clear & keep 3D blocks within the compact historic core
			var dist_c := Vector2(bx - cx, by - cy).length()
			if dist_c < 1.3 or dist_c > radius_map * 0.72:
				continue

			var mpx := clampi(int(round(bx)), 0, MAP_W - 1)
			var mpy := clampi(int(round(by)), 0, MAP_H - 1)
			if not splat_data.is_empty() and splat_data[(mpy * MAP_W + mpx) * 4 + 1] > 125:
				continue

			var xz := map_to_world_xz(bx, by)
			var elev := sample_elevation_m(xz.x, xz.y)
			if elev < 2.0:
				continue
			var wy := elev * LAND_HEIGHT_SCALE

			var s := rng.randf_range(0.075, 0.115) * (1.12 if bkind == 0 else 0.90)
			var sy := s * rng.randf_range(0.85, 1.28)
			var b_basis := Basis(Vector3.UP, -bang).scaled(Vector3(s, sy, s))
			var xform := Transform3D(b_basis, Vector3(xz.x, wy - 0.015, xz.y))
			var tint := rng.randf_range(0.88, 1.08)

			if is_med:
				villa_xf.append(xform)
				villa_col.append(Color(tint, tint * 0.98, tint * 0.94))
			else:
				if bkind == 0 and rng.randf() < 0.55:
					mansard_xf.append(xform)
					mansard_col.append(Color(tint, tint, tint * 0.98))
				else:
					town_xf.append(xform)
					town_col.append(Color(tint, tint * 0.98, tint * 0.95))

		# 3. Coastal Harbor Pier & Lighthouse for port cities
		var best_sea_dist := 1e9
		var best_coast_pt := Vector2.ZERO
		var best_sea_ang := 0.0
		for ray in range(16):
			var a := TAU * float(ray) / 16.0
			for st in range(3, int(radius_map * 2.2)):
				var px := cx + cos(a) * float(st)
				var py := cy + sin(a) * float(st)
				var wxz := map_to_world_xz(px, py)
				if sample_elevation_m(wxz.x, wxz.y) < -4.0:
					if float(st) < best_sea_dist:
						best_sea_dist = float(st)
						best_coast_pt = wxz
						best_sea_ang = a
					break
		if best_sea_dist < radius_map * 2.1:
			var h_basis := Basis(Vector3.UP, -best_sea_ang).scaled(Vector3.ONE * 0.34)
			harbor_xf.append(Transform3D(h_basis, Vector3(best_coast_pt.x, -0.02, best_coast_pt.y)))
			harbor_col.append(Color(1.0, 1.0, 1.0))

	var city_mat := StandardMaterial3D.new()
	city_mat.vertex_color_use_as_albedo = true
	city_mat.roughness = 0.82
	growth_mat = city_mat
	growth_rng.seed = 18359999

	growth_mesh_north = _load_glb_mesh("res://assets/models/bldg_north_townhouse.glb")
	growth_mesh_med = _load_glb_mesh("res://assets/models/bldg_med_villa.glb")

	_spawn_multimesh("CityNorthTownhouses", growth_mesh_north, city_mat, town_xf, town_col)
	_spawn_multimesh("CityNorthMansards", _load_glb_mesh("res://assets/models/bldg_north_mansard.glb"), city_mat, mansard_xf, mansard_col)
	_spawn_multimesh("CityNorthCathedrals", _load_glb_mesh("res://assets/models/bldg_north_cathedral.glb"), city_mat, cath_xf, cath_col)
	_spawn_multimesh("CityMedVillas", growth_mesh_med, city_mat, villa_xf, villa_col)
	_spawn_multimesh("CityMedBasilicas", _load_glb_mesh("res://assets/models/bldg_med_basilica.glb"), city_mat, basilica_xf, basilica_col)
	_spawn_multimesh("CoastalHarbors", _load_glb_mesh("res://assets/models/landmark_harbor_pier.glb"), city_mat, harbor_xf, harbor_col)


func grow_city(city_idx: int, pop_delta: int) -> void:
	if city_idx < 0 or city_idx >= cities.size():
		return
	var c = cities[city_idx]
	c["population"] = int(c["population"]) + pop_delta
	c["radius"] = minf(28.0, float(c["radius"]) + 0.16)
	# In satellite mode, keep real satellite city outlines untouched (economy & catchment still grow!)
	if FileAccess.file_exists("res://data/europe_albedo.jpg"):
		return

	# Expand to-scale urban rooftop fabric live on the terrain shader!
	if urban_img != null and urban_tex != null:
		_paint_city_urban_mask(city_idx)
		urban_img.generate_mipmaps()
		urban_tex.update(urban_img)

	# Also spawn 1 miniature 3D building inside the expanding historic core (avoiding water & railways)
	var cx: float = float(c["x"])
	var cy: float = float(c["y"])
	var rad: float = float(c["radius"])
	var is_med := float(c["lat"]) < 45.2
	for _try in range(16):
		var ang := growth_rng.randf_range(0.0, TAU)
		var r := rad * growth_rng.randf_range(0.45, 0.78)
		var xz := map_to_world_xz(cx + cos(ang) * r, cy + sin(ang) * r)
		var elev := sample_elevation_m(xz.x, xz.y)
		if elev < 2.0 or elev > 1400.0:
			continue
		# Never build houses inside rivers or lakes!
		var mpx := clampi(int(round(cx + cos(ang) * r)), 0, MAP_W - 1)
		var mpy := clampi(int(round(cy + sin(ang) * r)), 0, MAP_H - 1)
		if not splat_data.is_empty() and splat_data[(mpy * MAP_W + mpx) * 4 + 1] > 110:
			continue
		if railway_system and railway_system.is_near_railway(xz, 0.55, 1.05):
			continue
		var wy := elev * LAND_HEIGHT_SCALE
		var inst := MeshInstance3D.new()
		inst.mesh = growth_mesh_med if is_med else growth_mesh_north
		inst.material_override = growth_mat
		var s := growth_rng.randf_range(0.08, 0.115)
		inst.position = Vector3(xz.x, wy - 0.015, xz.y)
		inst.rotation = Vector3(0.0, -ang + growth_rng.randf_range(-0.3, 0.3), 0.0)
		inst.scale = Vector3(s, s * growth_rng.randf_range(0.9, 1.2), s)
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(inst)
		break


func _spawn_multimesh(node_name: String, mesh: Mesh, mat: Material,
		xforms: Array[Transform3D], cols: Array[Color]) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, cols[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mmi)
