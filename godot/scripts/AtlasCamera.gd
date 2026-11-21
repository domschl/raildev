extends Node3D

const WORLD_SIZE := Vector2(204.8, 153.6)
const MIN_DISTANCE := 0.22
const MAX_DISTANCE := 125.0

var target_pos := Vector3(0.0, 0.0, 0.0)
var current_pos := Vector3(0.0, 0.0, 0.0)
var target_distance := 78.0
var current_distance := 78.0
var target_yaw := 0.0
var current_yaw := 0.0
var target_pitch_offset := 0.0
var current_pitch_offset := 0.0

var is_panning := false
var is_orbiting := false
var drag_moved := false
var drag_start := Vector2.ZERO
var drag_button := 0
var keyboard_cursor_active := false

var world_ref: Node3D = null
var rail_ref: Node3D = null
var region_idx := 0
var selected_city_idx := -1
var following_train_id := -1

@onready var cam: Camera3D = $Camera3D

# HUD widgets
var hud_status_lbl: Label = null
var hud_telemetry: Label = null
var hud_help_panel: PanelContainer = null
var hud_region_btn: OptionButton = null
var hud_city_panel: PanelContainer = null
var hud_city_lbl: Label = null
var hud_city_actions: VBoxContainer = null
var hud_tooltip_panel: PanelContainer = null
var hud_tooltip_lbl: Label = null
var hud_crosshair: Control = null
var hud_map_overlay: Control = null
var hud_lines_panel: PanelContainer = null
var opt_line_from: OptionButton = null
var opt_line_to: OptionButton = null
var lbl_line_status: Label = null
var vbox_trains_list: VBoxContainer = null
var lines_refresh_accum: float = 0.0

var speed_btns: Array[Button] = []
var tool_btns: Array[Button] = []
var box_station_opts: HBoxContainer = null
var box_track_opts: HBoxContainer = null
var box_signal_opts: HBoxContainer = null
var chk_double_track: CheckBox = null
var chk_two_track_station: CheckBox = null
var chk_auto_signal: CheckBox = null
var opt_signal_type: OptionButton = null


func _ready() -> void:
	if not cam:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		add_child(cam)
	cam.fov = 44.0
	cam.near = 0.006
	cam.far = 450.0
	_build_hud()
	_apply_camera_transform()


func setup_world(world: Node3D, rail: Node3D = null) -> void:
	world_ref = world
	rail_ref = rail
	if hud_map_overlay:
		hud_map_overlay.setup(cam, rail_ref, world_ref)
	if hud_region_btn:
		hud_region_btn.clear()
		for r in world_ref.regions:
			hud_region_btn.add_item(String(r["name"]))
	focus_on_map_coords(1024.0, 740.0, 78.0)
	_sync_hud_state()


func get_zoom_distance() -> float:
	return current_distance


func focus_on_map_coords(mx: float, my: float, dist: float) -> void:
	if not world_ref:
		return
	following_train_id = -1
	var xz: Vector2 = world_ref.map_to_world_xz(mx, my)
	target_pos = Vector3(xz.x, 0.0, xz.y)
	target_distance = clampf(dist, MIN_DISTANCE, _max_allowed_distance())
	_clamp_target_to_map()


func _max_allowed_distance() -> float:
	var vp := get_viewport().get_visible_rect().size
	var aspect := maxf(0.5, vp.x / maxf(1.0, vp.y))
	var fov_rad := deg_to_rad(cam.fov)
	var max_by_z := (WORLD_SIZE.y * 0.44) / tan(fov_rad * 0.5)
	var max_by_x := (WORLD_SIZE.x * 0.44) / (tan(fov_rad * 0.5) * aspect)
	return clampf(minf(max_by_z, max_by_x), MIN_DISTANCE + 5.0, MAX_DISTANCE)


func _clamp_target_to_map() -> void:
	target_distance = clampf(target_distance, MIN_DISTANCE, _max_allowed_distance())
	var fov_rad := deg_to_rad(cam.fov)
	var vp := get_viewport().get_visible_rect().size
	var aspect := maxf(0.5, vp.x / maxf(1.0, vp.y))
	var half_vis_z := target_distance * tan(fov_rad * 0.5) * 0.85
	var half_vis_x := half_vis_z * aspect

	var lim_x := maxf(0.0, WORLD_SIZE.x * 0.5 - half_vis_x)
	var lim_z := maxf(0.0, WORLD_SIZE.y * 0.5 - half_vis_z)
	target_pos.x = clampf(target_pos.x, -lim_x, lim_x)
	target_pos.z = clampf(target_pos.z, -lim_z, lim_z)


func _active_screen_cursor() -> Vector2:
	if keyboard_cursor_active:
		return get_viewport().get_visible_rect().size * 0.5
	return get_viewport().get_mouse_position()


func _raycast_terrain_xz(screen_pos: Vector2) -> Dictionary:
	var ray_o := cam.project_ray_origin(screen_pos)
	var ray_d := cam.project_ray_normal(screen_pos)
	if absf(ray_d.y) < 1e-4:
		return {"valid": false, "xz": Vector2.ZERO}
	# Start from y = 0 intersection, then refine 3 steps against actual 3D terrain elevation
	var t := -ray_o.y / ray_d.y
	if t < 0.0:
		return {"valid": false, "xz": Vector2.ZERO}
	var hit := ray_o + ray_d * t
	if world_ref:
		for _i in range(3):
			var wy: float = maxf(0.0, world_ref.sample_world_y(hit.x, hit.z))
			t = (wy - ray_o.y) / ray_d.y
			if t > 0.0:
				hit = ray_o + ray_d * t
	return {"valid": true, "xz": Vector2(hit.x, hit.z)}


func _pick_city_at_xz(xz: Vector2) -> int:
	if not world_ref:
		return -1
	var best_idx := -1
	var best_d := clampf(current_distance * 0.04, 1.4, 4.5)
	for i in range(world_ref.cities.size()):
		var c = world_ref.cities[i]
		var cxz: Vector2 = world_ref.map_to_world_xz(float(c["x"]), float(c["y"]))
		var r_world := maxf(best_d, float(c["radius"]) * 0.12)
		var d := xz.distance_to(cxz)
		if d < r_world and d < best_d + 1.0:
			best_d = d
			best_idx = i
	return best_idx


func _perform_cancel() -> void:
	if rail_ref:
		if rail_ref.has_track_start:
			rail_ref.clear_track_start()
		elif rail_ref.tool != rail_ref.ToolMode.INSPECT:
			rail_ref.set_tool(rail_ref.ToolMode.INSPECT)
		else:
			selected_city_idx = -1
		_sync_hud_state()
	else:
		selected_city_idx = -1


func _perform_primary(screen_pos: Vector2) -> void:
	var hit := _raycast_terrain_xz(screen_pos)
	if not hit["valid"]:
		return
	var xz: Vector2 = hit["xz"]
	if not rail_ref or rail_ref.tool == rail_ref.ToolMode.INSPECT:
		selected_city_idx = _pick_city_at_xz(xz)
	else:
		var c_idx: int = rail_ref.perform_primary_action(xz)
		if c_idx >= 0:
			selected_city_idx = c_idx
		rail_ref.update_hover_and_preview(xz, current_distance)
	_sync_hud_state()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		keyboard_cursor_active = false
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if mb.shift_pressed and rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_STATION:
				rail_ref.station_angle += PI / 18.0
			elif mb.shift_pressed and rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_TRACK and rail_ref.has_track_start:
				rail_ref.track_curve_angle += 0.10
			else:
				target_distance *= 0.92
				_clamp_target_to_map()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if mb.shift_pressed and rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_STATION:
				rail_ref.station_angle -= PI / 18.0
			elif mb.shift_pressed and rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_TRACK and rail_ref.has_track_start:
				rail_ref.track_curve_angle -= 0.10
			else:
				target_distance /= 0.92
				_clamp_target_to_map()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				drag_button = mb.button_index
				drag_start = mb.position
				drag_moved = false
				if mb.button_index == MOUSE_BUTTON_RIGHT:
					is_orbiting = true
				else:
					is_panning = true
			else:
				if not drag_moved:
					if drag_button == MOUSE_BUTTON_LEFT:
						_perform_primary(mb.position)
					elif drag_button == MOUSE_BUTTON_RIGHT:
						_perform_cancel()
				is_panning = false
				is_orbiting = false
				drag_button = 0

	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		var factor := clampf(mg.factor, 0.80, 1.25)
		target_distance /= pow(factor, 0.75)
		_clamp_target_to_map()

	elif event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		_pan_by_screen_delta(-pg.delta * 14.0)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		keyboard_cursor_active = false
		if is_panning or is_orbiting:
			if mm.position.distance_to(drag_start) > 5.0:
				drag_moved = true
		if is_panning:
			_pan_by_screen_delta(mm.relative)
		elif is_orbiting:
			target_yaw -= mm.relative.x * 0.005
			target_pitch_offset = _clamp_pitch_offset(target_pitch_offset + mm.relative.y * 0.22)

	elif event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.keycode:
			KEY_SPACE, KEY_P:
				if rail_ref:
					rail_ref.toggle_pause()
					_sync_hud_state()
			KEY_1:
				if rail_ref:
					rail_ref.sim_speed = rail_ref.SimSpeed.REAL
					_sync_hud_state()
			KEY_2:
				if rail_ref:
					rail_ref.sim_speed = rail_ref.SimSpeed.FAST
					_sync_hud_state()
			KEY_3:
				if rail_ref:
					rail_ref.sim_speed = rail_ref.SimSpeed.TURBO
					_sync_hud_state()
			KEY_4:
				if rail_ref:
					rail_ref.sim_speed = rail_ref.SimSpeed.ULTRA
					_sync_hud_state()
			KEY_0:
				if rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_TRACK:
					rail_ref.track_curve_angle = 0.0
			KEY_I, KEY_F1:
				if rail_ref:
					rail_ref.set_tool(rail_ref.ToolMode.INSPECT)
					_sync_hud_state()
			KEY_B, KEY_F2:
				if rail_ref:
					rail_ref.set_tool(rail_ref.ToolMode.BUILD_STATION)
					_sync_hud_state()
			KEY_T, KEY_F3:
				if rail_ref:
					rail_ref.set_tool(rail_ref.ToolMode.BUILD_TRACK)
					_sync_hud_state()
			KEY_N, KEY_F4:
				if rail_ref:
					rail_ref.set_tool(rail_ref.ToolMode.PLACE_SIGNAL)
					_sync_hud_state()
			KEY_X, KEY_F5:
				if rail_ref:
					rail_ref.set_tool(rail_ref.ToolMode.DEMOLISH)
					_sync_hud_state()
			KEY_R:
				if not (rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_STATION):
					target_yaw = 0.0
					target_pitch_offset = 0.0
			KEY_L:
				if rail_ref:
					rail_ref.double_track = not rail_ref.double_track
					_sync_hud_state()
			KEY_U:
				if rail_ref:
					rail_ref.auto_signal = not rail_ref.auto_signal
					_sync_hud_state()
			KEY_C:
				if rail_ref:
					rail_ref.signal_type = (rail_ref.signal_type + 1) % 3
					_sync_hud_state()
			KEY_ENTER, KEY_KP_ENTER:
				keyboard_cursor_active = true
				_perform_primary(_active_screen_cursor())
			KEY_ESCAPE, KEY_BACKSPACE:
				following_train_id = -1
				_perform_cancel()
			KEY_HOME:
				target_yaw = 0.0
				target_pitch_offset = 0.0
				focus_on_map_coords(1024.0, 740.0, 78.0)
			KEY_H, KEY_SLASH:
				if hud_help_panel:
					hud_help_panel.visible = not hud_help_panel.visible
			KEY_M:
				if hud_lines_panel:
					hud_lines_panel.visible = not hud_lines_panel.visible
					if hud_lines_panel.visible:
						_refresh_lines_panel()
			KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
				if world_ref and not world_ref.regions.is_empty():
					var n: int = world_ref.regions.size()
					region_idx = (region_idx + (1 if k.keycode == KEY_BRACKETRIGHT else n - 1)) % n
					_jump_to_region(region_idx)
			KEY_TAB:
				if world_ref and not world_ref.cities.is_empty():
					var n: int = world_ref.cities.size()
					selected_city_idx = (selected_city_idx + (-1 if k.shift_pressed else 1) + n) % n
					var c = world_ref.cities[selected_city_idx]
					focus_on_map_coords(float(c["x"]), float(c["y"]), 22.0)
					keyboard_cursor_active = true
					_sync_hud_state()


func _pan_by_screen_delta(delta: Vector2) -> void:
	following_train_id = -1
	var scale := current_distance * 0.00145
	var right := Vector3(cos(current_yaw), 0.0, -sin(current_yaw))
	var forward := Vector3(sin(current_yaw), 0.0, cos(current_yaw))
	target_pos -= right * (delta.x * scale)
	target_pos -= forward * (delta.y * scale)
	_clamp_target_to_map()


func _process(delta: float) -> void:
	var pan_vec := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		pan_vec.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		pan_vec.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		pan_vec.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		pan_vec.y += 1.0

	if pan_vec.length_squared() > 0.0:
		following_train_id = -1
		keyboard_cursor_active = true
		var speed := current_distance * (1.25 if Input.is_key_pressed(KEY_SHIFT) else 0.65)
		pan_vec = pan_vec.normalized() * speed * delta
		var right := Vector3(cos(current_yaw), 0.0, -sin(current_yaw))
		var forward := Vector3(sin(current_yaw), 0.0, cos(current_yaw))
		target_pos += right * pan_vec.x + forward * pan_vec.y
		_clamp_target_to_map()

	# Live Follow-Train camera tracking (orbit, tilt & zoom remain freely controllable!)
	if following_train_id != -1 and rail_ref:
		var found_tr := false
		for tr in rail_ref.trains:
			if int(tr["id"]) == following_train_id:
				var loco_node = tr.get("loco", null)
				var wp: Vector3 = loco_node.global_position if (loco_node and is_instance_valid(loco_node)) else (tr["world_pos"] as Vector3)
				target_pos = Vector3(wp.x, 0.0, wp.z)
				_clamp_target_to_map()
				found_tr = true
				break
		if not found_tr:
			following_train_id = -1

	# Smooth continuous camera orbit (Q/E) and tilt up/down (F/V) — ALWAYS active!
	if Input.is_key_pressed(KEY_Q):
		target_yaw += 1.25 * delta
	if Input.is_key_pressed(KEY_E):
		target_yaw -= 1.25 * delta
	if Input.is_key_pressed(KEY_F):
		target_pitch_offset = _clamp_pitch_offset(target_pitch_offset - 36.0 * delta)
	if Input.is_key_pressed(KEY_V):
		target_pitch_offset = _clamp_pitch_offset(target_pitch_offset + 36.0 * delta)

	# Smooth continuous keyboard zoom (+ / = / PgUp and - / PgDn)
	var zoom_dir := 0.0
	if Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_PLUS) or Input.is_key_pressed(KEY_KP_ADD) or Input.is_key_pressed(KEY_PAGEUP):
		zoom_dir -= 1.0
	if Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_KP_SUBTRACT) or Input.is_key_pressed(KEY_PAGEDOWN):
		zoom_dir += 1.0
	if zoom_dir != 0.0:
		var z_speed := 1.65 if Input.is_key_pressed(KEY_SHIFT) else 1.05
		target_distance *= exp(zoom_dir * z_speed * delta)
		_clamp_target_to_map()

	# Smooth continuous station rotation (R / Shift+R) while placing a station
	if rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_STATION and Input.is_key_pressed(KEY_R):
		var rot_sign := -1.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		rail_ref.station_angle += rot_sign * 1.9 * delta

	# Smooth continuous track curving (, / .) while laying a track
	if rail_ref and rail_ref.tool == rail_ref.ToolMode.BUILD_TRACK and rail_ref.has_track_start:
		if Input.is_key_pressed(KEY_COMMA):
			rail_ref.track_curve_angle -= 1.1 * delta
		if Input.is_key_pressed(KEY_PERIOD):
			rail_ref.track_curve_angle += 1.1 * delta

	var smooth := 1.0 - exp(-delta * 10.0)
	var pos_smooth := (1.0 - exp(-delta * 16.0)) if following_train_id != -1 else smooth
	current_pos = current_pos.lerp(target_pos, pos_smooth)
	current_distance = lerpf(current_distance, target_distance, smooth)
	current_yaw = lerpf(current_yaw, target_yaw, smooth)
	current_pitch_offset = lerpf(current_pitch_offset, target_pitch_offset, smooth)

	_apply_camera_transform()
	if rail_ref:
		rail_ref.set_camera_zoom(current_distance)
	if hud_map_overlay:
		hud_map_overlay.update_overlay(current_distance)
	_update_live_cursor_and_hud()
	if hud_lines_panel and hud_lines_panel.visible:
		lines_refresh_accum += delta
		if lines_refresh_accum >= 0.4:
			lines_refresh_accum = 0.0
			_refresh_lines_panel()


func _base_pitch_deg() -> float:
	var zoom_t := clampf((current_distance - MIN_DISTANCE) / (95.0 - MIN_DISTANCE), 0.0, 1.0)
	return lerpf(26.0, 76.0, pow(zoom_t, 0.65))


func _clamp_pitch_offset(v: float) -> float:
	var base_p := _base_pitch_deg()
	return clampf(v, 12.0 - base_p, 86.0 - base_p)


func _apply_camera_transform() -> void:
	var zoom_t := clampf((current_distance - MIN_DISTANCE) / (95.0 - MIN_DISTANCE), 0.0, 1.0)
	var base_pitch_deg := _base_pitch_deg()
	target_pitch_offset = _clamp_pitch_offset(target_pitch_offset)
	current_pitch_offset = _clamp_pitch_offset(current_pitch_offset)
	var pitch_deg := clampf(base_pitch_deg + current_pitch_offset, 12.0, 86.0)
	var pitch_rad := deg_to_rad(pitch_deg)

	var ground_y := 0.0
	if world_ref:
		ground_y = maxf(0.0, world_ref.sample_world_y(current_pos.x, current_pos.z))
	# Track exact terrain elevation when zoomed in close (so Alpine valleys & peaks stay centered)
	var target_y := ground_y * lerpf(1.0, 0.5, zoom_t)
	var look_target := Vector3(current_pos.x, target_y, current_pos.z)

	var horiz := current_distance * cos(pitch_rad)
	var vert := current_distance * sin(pitch_rad)
	var offset := Vector3(sin(current_yaw) * horiz, vert, cos(current_yaw) * horiz)

	var cam_pos := look_target + offset
	if world_ref:
		var cam_ground := maxf(0.0, world_ref.sample_world_y(cam_pos.x, cam_pos.z))
		var clearance := clampf(current_distance * 0.10, 0.015, 0.30)
		var min_cam_y := cam_ground + clearance
		if cam_pos.y < min_cam_y:
			var lift := min_cam_y - cam_pos.y
			cam_pos.y = min_cam_y
			# Lift look_target proportionally on steep mountain slopes so F/V tilt stays responsive!
			look_target.y += lift * 0.85

	cam.global_position = cam_pos
	cam.look_at(look_target, Vector3.UP)


func _format_money(amount: int) -> String:
	var s := str(amount)
	var out := ""
	var n := s.length()
	for i in range(n):
		if i > 0 and (n - i) % 3 == 0:
			out += ","
		out += s[i]
	return "£" + out


func _update_live_cursor_and_hud() -> void:
	if hud_crosshair:
		hud_crosshair.visible = keyboard_cursor_active
		if keyboard_cursor_active:
			hud_crosshair.position = get_viewport().get_visible_rect().size * 0.5

	if rail_ref and hud_status_lbl:
		var follow_tag := ""
		if following_train_id != -1:
			for tr in rail_ref.trains:
				if int(tr["id"]) == following_train_id:
					follow_tag = "  |  Following: %s [WASD/Esc]" % String(tr["name"])
					break
		hud_status_lbl.text = "RAILDEV 3D  |  %s  |  %s%s" % [
			rail_ref.formatted_date(), _format_money(rail_ref.treasury), follow_tag]

	if not world_ref:
		return

	var cursor_pos := _active_screen_cursor()
	var hit := _raycast_terrain_xz(cursor_pos)
	if hit["valid"]:
		var xz: Vector2 = hit["xz"]
		if rail_ref:
			rail_ref.update_hover_and_preview(xz, current_distance)

		if hud_telemetry:
			var ll: Vector2 = world_ref.world_xz_to_latlon(xz.x, xz.y)
			var elev: float = world_ref.sample_elevation_m(xz.x, xz.y)
			var st_cnt: int = rail_ref.stations.size() if rail_ref else 0
			var tr_cnt := 0
			var train_cnt: int = rail_ref.trains.size() if rail_ref else 0
			if rail_ref:
				for e in rail_ref.edges.values():
					if not e.get("internal", false):
						tr_cnt += 1
			if elev < 0.0:
				hud_telemetry.text = "%.2f° N, %.2f° E  |  Sea  |  Stations: %d  Tracks: %d  Trains: %d" % [
					ll.x, ll.y, st_cnt, tr_cnt, train_cnt]
			else:
				hud_telemetry.text = "%.2f° N, %.2f° E  |  Elev: %.0f m  |  Stations: %d  Tracks: %d  Trains: %d" % [
					ll.x, ll.y, elev, st_cnt, tr_cnt, train_cnt]

	# Floating build tooltip (Track preview OR Station city-catchment snap indicator)
	if hud_tooltip_panel and rail_ref:
		var show_track_tt: bool = (rail_ref.tool == rail_ref.ToolMode.BUILD_TRACK and rail_ref.has_track_start and not rail_ref.live_preview.is_empty())
		var show_station_tt: bool = (rail_ref.tool == rail_ref.ToolMode.BUILD_STATION and hit["valid"])
		hud_tooltip_panel.visible = show_track_tt or show_station_tt
		if show_station_tt:
			hud_tooltip_panel.position = cursor_pos + Vector2(18, 18)
			var h_st: int = int(rail_ref.hover_station_idx)
			if h_st >= 0 and h_st < rail_ref.stations.size() and int(rail_ref.stations[h_st].get("tracks", 1)) < 2:
				var sname: String = String(rail_ref.stations[h_st]["name"])
				hud_tooltip_lbl.text = "⬆ Upgrade %s to 2-Track Passing Station (£20,000)" % sname
				hud_tooltip_lbl.modulate = Color(0.55, 0.95, 1.0) if rail_ref.treasury >= rail_ref.STATION_UPGRADE_COST else Color(1.0, 0.42, 0.42)
			else:
				var c_idx: int = int(rail_ref.hover_station_city_idx)
				var st_cost: int = rail_ref.STATION_COST + (rail_ref.STATION_UPGRADE_COST if rail_ref.station_two_track else 0)
				var trk_tag := "2-Track " if rail_ref.station_two_track else ""
				if c_idx >= 0 and c_idx < world_ref.cities.size():
					hud_tooltip_lbl.text = "✓ %sCity Station: %s Central (%s)" % [trk_tag, String(world_ref.cities[c_idx]["name"]), _format_money(st_cost)]
					hud_tooltip_lbl.modulate = Color(0.50, 0.98, 0.60)
				else:
					hud_tooltip_lbl.text = "Open %sJunction (outside city catchment) — %s" % [trk_tag, _format_money(st_cost)]
					hud_tooltip_lbl.modulate = Color(0.84, 0.84, 0.78)
		elif show_track_tt:
			hud_tooltip_panel.position = cursor_pos + Vector2(18, 18)
			var pv: Dictionary = rail_ref.live_preview
			if not pv.get("valid", false):
				hud_tooltip_lbl.text = String(pv.get("reason", "Invalid"))
				hud_tooltip_lbl.modulate = Color(1.0, 0.40, 0.40)
			else:
				var total_cost: int = int(pv["cost"])
				if rail_ref.double_track and rail_ref.live_preview2.get("valid", false):
					total_cost += int(rail_ref.live_preview2["cost"])
				var tags := ""
				if pv.get("has_bridge", false):
					tags += " [BRIDGE]"
				if pv.get("has_tunnel", false):
					tags += " [TUNNEL]"
				var dbl_str := " (Double)" if rail_ref.double_track else ""
				hud_tooltip_lbl.text = "%.1f km  |  Grade: %.1f%%%s\nCost: %s%s" % [
					float(pv["length_km"]), float(pv["max_grade"]), tags,
					_format_money(total_cost), dbl_str]
				hud_tooltip_lbl.modulate = Color(0.55, 0.96, 0.62) if rail_ref.treasury >= total_cost else Color(1.0, 0.42, 0.42)


func _sync_hud_state() -> void:
	if rail_ref:
		for i in range(speed_btns.size()):
			speed_btns[i].modulate = Color(1.0, 0.80, 0.35) if rail_ref.sim_speed == i else Color.WHITE
		for i in range(tool_btns.size()):
			if rail_ref.tool == i:
				tool_btns[i].modulate = Color(1.0, 0.45, 0.42) if i == rail_ref.ToolMode.DEMOLISH else Color(0.45, 0.95, 0.58)
			else:
				tool_btns[i].modulate = Color.WHITE
		if box_station_opts:
			box_station_opts.visible = (rail_ref.tool == rail_ref.ToolMode.BUILD_STATION)
		if box_track_opts:
			box_track_opts.visible = (rail_ref.tool == rail_ref.ToolMode.BUILD_TRACK)
		if box_signal_opts:
			box_signal_opts.visible = (rail_ref.tool == rail_ref.ToolMode.PLACE_SIGNAL)
		if chk_double_track:
			chk_double_track.button_pressed = rail_ref.double_track
		if chk_two_track_station:
			chk_two_track_station.button_pressed = rail_ref.station_two_track
		if chk_auto_signal:
			chk_auto_signal.button_pressed = rail_ref.auto_signal
		if opt_signal_type:
			opt_signal_type.selected = rail_ref.signal_type

	# Update City Inspector Panel
	if hud_city_panel and world_ref:
		if selected_city_idx >= 0 and selected_city_idx < world_ref.cities.size():
			var c = world_ref.cities[selected_city_idx]
			var t_val := int(c["tier"])
			var tier_str := "Metropolis" if t_val == 3 else ("City" if t_val == 2 else ("Regional City" if t_val == 1 else "Local Town"))
			var wait_pax := int(floor(float(rail_ref.city_waiting_pax.get(selected_city_idx, 0.0)))) if rail_ref else 0
			var txt := "%s (%s)\nTier: %s  |  Pop: %d\nWaiting Passengers: %d\nElev: %.0f m  |  %.2f° N, %.2f° E\n" % [
				String(c["name"]), String(c["country"]), tier_str,
				int(c["population"]), wait_pax, float(c["elev"]), float(c["lat"]), float(c["lon"])]
			var st_lines := ""
			if hud_city_actions:
				for ch in hud_city_actions.get_children():
					ch.queue_free()
			if rail_ref:
				for si in range(rail_ref.stations.size()):
					var st = rail_ref.stations[si]
					if int(st["city_idx"]) == selected_city_idx:
						var trks: int = int(st.get("tracks", 1))
						st_lines += "\n• %s [%d-Track]" % [String(st["name"]), trks]
						if trks < 2 and hud_city_actions:
							var upg_btn := Button.new()
							upg_btn.text = "⬆ Upgrade %s to 2-Track (£20k)" % String(st["name"])
							var cap_si := si
							upg_btn.pressed.connect(func():
								if rail_ref and rail_ref.upgrade_station_to_two_track(cap_si):
									_sync_hud_state())
							hud_city_actions.add_child(upg_btn)
			if st_lines.is_empty():
				txt += "\nNo station connected yet."
			else:
				txt += "\nStations:" + st_lines
			hud_city_lbl.text = txt
			hud_city_panel.visible = true
		else:
			hud_city_panel.visible = false


func _jump_to_region(idx: int) -> void:
	if not world_ref or idx < 0 or idx >= world_ref.regions.size():
		return
	var r = world_ref.regions[idx]
	var dist := clampf(68.0 / maxf(0.5, float(r["zoom"])), MIN_DISTANCE + 4.0, _max_allowed_distance())
	focus_on_map_coords(float(r["x"]), float(r["y"]), dist)
	if hud_region_btn:
		hud_region_btn.selected = idx


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	# 0. Zoom-out Cartographic Railway Map Overlay (drawn beneath UI toolbars)
	var overlay_script := load("res://scripts/RailMapOverlay.gd")
	hud_map_overlay = Control.new()
	hud_map_overlay.set_script(overlay_script)
	layer.add_child(hud_map_overlay)

	# 1. Top Control & Construction Bar
	var top_panel := PanelContainer.new()
	top_panel.position = Vector2(12, 12)
	layer.add_child(top_panel)

	var top_vbox := VBoxContainer.new()
	top_vbox.add_theme_constant_override("separation", 6)
	top_panel.add_child(top_vbox)

	# Row 1: Date, Treasury, Speed, Zoom, Region, Help
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	top_vbox.add_child(row1)

	hud_status_lbl = Label.new()
	hud_status_lbl.text = "RAILDEV 3D  |  01 May 1835  |  £500,000"
	row1.add_child(hud_status_lbl)

	var speed_labels := ["|| [Space]", "1x [1]", "15x [2]", "60x [3]", "300x [4]"]
	for i in range(speed_labels.size()):
		var b := Button.new()
		b.text = speed_labels[i]
		var idx := i
		b.pressed.connect(func():
			if rail_ref:
				rail_ref.sim_speed = idx
				_sync_hud_state())
		row1.add_child(b)
		speed_btns.append(b)

	var btn_out := Button.new()
	btn_out.text = "Zoom [-]"
	btn_out.pressed.connect(func():
		target_distance /= 0.84
		_clamp_target_to_map())
	row1.add_child(btn_out)

	var btn_in := Button.new()
	btn_in.text = "Zoom [+]"
	btn_in.pressed.connect(func():
		target_distance *= 0.84
		_clamp_target_to_map())
	row1.add_child(btn_in)

	var btn_north := Button.new()
	btn_north.text = "North [R]"
	btn_north.pressed.connect(func():
		target_yaw = 0.0
		target_pitch_offset = 0.0)
	row1.add_child(btn_north)

	hud_region_btn = OptionButton.new()
	hud_region_btn.tooltip_text = "Jump to region ([ / ])"
	hud_region_btn.item_selected.connect(func(i: int): _jump_to_region(i))
	row1.add_child(hud_region_btn)

	var btn_help := Button.new()
	btn_help.text = "? [H]"
	btn_help.pressed.connect(func():
		if hud_help_panel:
			hud_help_panel.visible = not hud_help_panel.visible)
	row1.add_child(btn_help)

	# Row 2: Railway Construction Toolbar
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	top_vbox.add_child(row2)

	var tool_labels := ["Inspect [I]", "Station (£25k) [B]", "Track [T]", "Signals [N]", "Demolish [X]"]
	for i in range(tool_labels.size()):
		var tb := Button.new()
		tb.text = tool_labels[i]
		var t_idx := i
		tb.pressed.connect(func():
			if rail_ref:
				rail_ref.set_tool(t_idx)
				_sync_hud_state())
		row2.add_child(tb)
		tool_btns.append(tb)

	var btn_lines := Button.new()
	btn_lines.text = "Lines & Trains [M]"
	btn_lines.pressed.connect(func():
		if hud_lines_panel:
			hud_lines_panel.visible = not hud_lines_panel.visible
			if hud_lines_panel.visible:
				_refresh_lines_panel())
	row2.add_child(btn_lines)

	# Contextual Station Options
	box_station_opts = HBoxContainer.new()
	box_station_opts.visible = false
	row2.add_child(box_station_opts)
	var rot_l := Button.new()
	rot_l.text = "Rot - [Shift+R]"
	rot_l.pressed.connect(func():
		if rail_ref: rail_ref.station_angle -= PI / 12.0)
	box_station_opts.add_child(rot_l)
	var rot_r := Button.new()
	rot_r.text = "Rot + [R]"
	rot_r.pressed.connect(func():
		if rail_ref: rail_ref.station_angle += PI / 12.0)
	box_station_opts.add_child(rot_r)
	chk_two_track_station = CheckBox.new()
	chk_two_track_station.text = "2-Track (+£20k)"
	chk_two_track_station.toggled.connect(func(v: bool):
		if rail_ref: rail_ref.station_two_track = v)
	box_station_opts.add_child(chk_two_track_station)

	# Contextual Track Options
	box_track_opts = HBoxContainer.new()
	box_track_opts.visible = false
	row2.add_child(box_track_opts)
	chk_double_track = CheckBox.new()
	chk_double_track.text = "Double [L]"
	chk_double_track.toggled.connect(func(v: bool):
		if rail_ref: rail_ref.double_track = v)
	box_track_opts.add_child(chk_double_track)
	var crv_l := Button.new()
	crv_l.text = "Curve L [,]"
	crv_l.pressed.connect(func():
		if rail_ref: rail_ref.track_curve_angle -= 0.15)
	box_track_opts.add_child(crv_l)
	var crv_0 := Button.new()
	crv_0.text = "Straight [0]"
	crv_0.pressed.connect(func():
		if rail_ref: rail_ref.track_curve_angle = 0.0)
	box_track_opts.add_child(crv_0)
	var crv_r := Button.new()
	crv_r.text = "Curve R [.]"
	crv_r.pressed.connect(func():
		if rail_ref: rail_ref.track_curve_angle += 0.15)
	box_track_opts.add_child(crv_r)

	# Contextual Signal Options
	box_signal_opts = HBoxContainer.new()
	box_signal_opts.visible = false
	row2.add_child(box_signal_opts)
	chk_auto_signal = CheckBox.new()
	chk_auto_signal.text = "Auto-Signal [U]"
	chk_auto_signal.button_pressed = true
	chk_auto_signal.toggled.connect(func(v: bool):
		if rail_ref: rail_ref.auto_signal = v)
	box_signal_opts.add_child(chk_auto_signal)
	opt_signal_type = OptionButton.new()
	opt_signal_type.add_item("Block [C]")
	opt_signal_type.add_item("One-Way [C]")
	opt_signal_type.add_item("Chain [C]")
	opt_signal_type.selected = 1
	opt_signal_type.item_selected.connect(func(i: int):
		if rail_ref: rail_ref.signal_type = i)
	box_signal_opts.add_child(opt_signal_type)

	# 2. Top-Right City Inspector Panel
	hud_city_panel = PanelContainer.new()
	hud_city_panel.visible = false
	hud_city_panel.anchor_left = 1.0
	hud_city_panel.anchor_right = 1.0
	hud_city_panel.offset_left = -280
	hud_city_panel.offset_right = -12
	hud_city_panel.offset_top = 12
	layer.add_child(hud_city_panel)

	var city_vbox := VBoxContainer.new()
	city_vbox.add_theme_constant_override("separation", 6)
	hud_city_panel.add_child(city_vbox)

	hud_city_lbl = Label.new()
	city_vbox.add_child(hud_city_lbl)

	hud_city_actions = VBoxContainer.new()
	hud_city_actions.add_theme_constant_override("separation", 4)
	city_vbox.add_child(hud_city_actions)

	# 3. Floating Track Build Tooltip
	hud_tooltip_panel = PanelContainer.new()
	hud_tooltip_panel.visible = false
	hud_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud_tooltip_panel)

	hud_tooltip_lbl = Label.new()
	hud_tooltip_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_tooltip_panel.add_child(hud_tooltip_lbl)

	# 4. Bottom-Left Telemetry Bar
	var bot_panel := PanelContainer.new()
	bot_panel.anchor_top = 1.0
	bot_panel.anchor_bottom = 1.0
	bot_panel.offset_left = 12
	bot_panel.offset_top = -54
	bot_panel.offset_right = 640
	bot_panel.offset_bottom = -12
	layer.add_child(bot_panel)

	var vbox := VBoxContainer.new()
	bot_panel.add_child(vbox)

	hud_telemetry = Label.new()
	hud_telemetry.text = "Loading Europe 3D Atlas..."
	vbox.add_child(hud_telemetry)

	var hint := Label.new()
	hint.text = "Pan: Drag/WASD  Zoom: Wheel/+/-  Orbit/Tilt: R-Drag/Q/E/F/V  Build: Click/Enter  Tools: I/B/T/N/X/M  Speed: Space/1-4  Help: H"
	hint.modulate = Color(0.75, 0.78, 0.82)
	hint.add_theme_font_size_override("font_size", 11)
	vbox.add_child(hint)

	# 5. Toggleable Controls Help Panel
	hud_help_panel = PanelContainer.new()
	hud_help_panel.visible = false
	hud_help_panel.position = Vector2(12, 92)
	layer.add_child(hud_help_panel)

	var help_lbl := Label.new()
	help_lbl.text = (
		"Controls — Mouse / Touchpad & Keyboard\n"
		+ "• Pan: Left/Middle-Drag, Two-Finger Pan, or hold WASD / Arrows (Shift = faster)\n"
		+ "• Zoom: Scroll Wheel, Touchpad Pinch, or hold + / - / PgUp / PgDn\n"
		+ "• Orbit & Tilt: Right-Drag (X=Orbit, Y=Tilt) or hold Q/E (Orbit), F/V (Tilt Up/Down)  |  R = Reset North & Tilt\n"
		+ "• Build / Select: Left-Click or Enter (at crosshair)  |  Cancel: Right-Click / Esc\n"
		+ "• Tools: I (Inspect), B (Station), T (Track), N (Signals), X (Demolish), M (Lines & Trains)\n"
		+ "• Station Rotate: hold R / Shift+R, Shift+Wheel, or HUD buttons\n"
		+ "• Track Curve: hold , / . (0 = Straight), Shift+Wheel, or HUD buttons  |  L = Double Track\n"
		+ "• Signals: U (Auto-Signal), C (Signal Type)  |  Speed: Space (Pause), 1 (1x), 2 (2x), 4 (4x)\n"
		+ "• Jump: Region dropdown, [ / ] (regions), Tab (cities), Home (overview)"
	)
	hud_help_panel.add_child(help_lbl)

	# 6. Subtle Center Crosshair for Keyboard Mode
	hud_crosshair = Control.new()
	hud_crosshair.visible = false
	hud_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ch_lbl := Label.new()
	ch_lbl.text = "+"
	ch_lbl.position = Vector2(-5, -11)
	ch_lbl.modulate = Color(1.0, 0.94, 0.76, 0.92)
	ch_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_crosshair.add_child(ch_lbl)
	layer.add_child(hud_crosshair)

	# 7. Passenger Lines & Trains Manager Panel [M]
	hud_lines_panel = PanelContainer.new()
	hud_lines_panel.visible = false
	hud_lines_panel.position = Vector2(12, 96)
	layer.add_child(hud_lines_panel)

	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 6)
	hud_lines_panel.add_child(lv)

	var lhdr := HBoxContainer.new()
	lv.add_child(lhdr)
	var ltitle := Label.new()
	ltitle.text = "Passenger Lines & Steam Trains"
	lhdr.add_child(ltitle)
	var lclose := Button.new()
	lclose.text = " X "
	lclose.pressed.connect(func(): hud_lines_panel.visible = false)
	lhdr.add_child(lclose)

	var picker_row := HBoxContainer.new()
	picker_row.add_theme_constant_override("separation", 6)
	lv.add_child(picker_row)

	opt_line_from = OptionButton.new()
	opt_line_from.item_selected.connect(func(_i: int): _update_route_status_label())
	picker_row.add_child(opt_line_from)

	var arrow_lbl := Label.new()
	arrow_lbl.text = " ↔ "
	picker_row.add_child(arrow_lbl)

	opt_line_to = OptionButton.new()
	opt_line_to.item_selected.connect(func(_i: int): _update_route_status_label())
	picker_row.add_child(opt_line_to)

	var btn_launch := Button.new()
	btn_launch.text = "Launch Train (£35k)"
	btn_launch.pressed.connect(_on_launch_train_pressed)
	picker_row.add_child(btn_launch)

	lbl_line_status = Label.new()
	lbl_line_status.text = "Build 2 connected stations to launch a passenger line."
	lbl_line_status.modulate = Color(0.85, 0.88, 0.92)
	lv.add_child(lbl_line_status)

	vbox_trains_list = VBoxContainer.new()
	vbox_trains_list.add_theme_constant_override("separation", 4)
	lv.add_child(vbox_trains_list)


func _refresh_lines_panel() -> void:
	if not rail_ref or not opt_line_from or not opt_line_to:
		return
	var prev_a := opt_line_from.selected
	var prev_b := opt_line_to.selected
	opt_line_from.clear()
	opt_line_to.clear()
	for st in rail_ref.stations:
		var nm: String = String(st["name"])
		opt_line_from.add_item(nm)
		opt_line_to.add_item(nm)
	if rail_ref.stations.size() >= 2:
		opt_line_from.selected = clampi(prev_a if prev_a >= 0 else 0, 0, rail_ref.stations.size() - 1)
		opt_line_to.selected = clampi(prev_b if prev_b >= 0 else 1, 0, rail_ref.stations.size() - 1)
	_update_route_status_label()

	for child in vbox_trains_list.get_children():
		child.queue_free()

	for tr in rail_ref.trains:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		vbox_trains_list.add_child(row)

		var line_name := ""
		for l in rail_ref.lines:
			if int(l["id"]) == int(tr["line_id"]):
				line_name = String(l["name"])
				break

		var st_str := " [WAIT: RED SIGNAL]" if String(tr["state"]) == "WAITING" else (" [LOADING]" if String(tr["state"]) == "LOADING" else "")
		var info := Label.new()
		info.text = "%s (%s)  |  %d/%d pax  |  %.0f km/h%s  |  Earned: %s" % [
			String(tr["name"]), line_name, int(tr["passengers"]), int(tr["capacity"]),
			float(tr["speed_kmh"]), st_str, _format_money(int(tr["revenue"]))]
		if String(tr["state"]) == "WAITING":
			info.modulate = Color(1.0, 0.55, 0.45)
		row.add_child(info)

		var focus_btn := Button.new()
		focus_btn.text = "Focus"
		var tr_ref = tr
		var tr_id: int = int(tr["id"])
		focus_btn.pressed.connect(func():
			following_train_id = -1
			var wp: Vector3 = tr_ref["world_pos"]
			target_pos = Vector3(wp.x, 0.0, wp.z)
			target_distance = 14.0
			_clamp_target_to_map()
			_refresh_lines_panel())
		row.add_child(focus_btn)

		var follow_btn := Button.new()
		var is_following := (following_train_id == tr_id)
		follow_btn.text = "Following" if is_following else "Follow"
		if is_following:
			follow_btn.modulate = Color(0.55, 1.0, 0.65)
		follow_btn.pressed.connect(func():
			if following_train_id == tr_id:
				following_train_id = -1
			else:
				following_train_id = tr_id
				var loco_node = tr_ref.get("loco", null)
				var wp: Vector3 = loco_node.global_position if (loco_node and is_instance_valid(loco_node)) else (tr_ref["world_pos"] as Vector3)
				target_pos = Vector3(wp.x, 0.0, wp.z)
				target_distance = minf(target_distance, 1.35)
				_clamp_target_to_map()
			_refresh_lines_panel())
		row.add_child(follow_btn)


func _update_route_status_label() -> void:
	if not rail_ref or not lbl_line_status:
		return
	if rail_ref.stations.size() < 2:
		lbl_line_status.text = "Build at least 2 connected stations first."
		lbl_line_status.modulate = Color(0.85, 0.85, 0.72)
		return
	var a := opt_line_from.selected
	var b := opt_line_to.selected
	if a < 0 or b < 0 or a == b:
		lbl_line_status.text = "Select two different stations."
		lbl_line_status.modulate = Color(0.85, 0.85, 0.72)
		return
	var ab: Dictionary = rail_ref.find_station_route(a, b)
	var ba: Dictionary = rail_ref.find_station_route(b, a)
	if ab["valid"] and ba["valid"]:
		lbl_line_status.text = "Connected round-trip: %.0f km (auto-signaled)" % float(ab["km"])
		lbl_line_status.modulate = Color(0.48, 0.95, 0.58)
	else:
		lbl_line_status.text = "No valid round-trip rail connection between these stations."
		lbl_line_status.modulate = Color(1.0, 0.45, 0.42)


func _on_launch_train_pressed() -> void:
	if not rail_ref or rail_ref.stations.size() < 2:
		return
	var a := opt_line_from.selected
	var b := opt_line_to.selected
	if a < 0 or b < 0 or a == b:
		return
	# Reuse existing line between A & B if present, else create a new one
	var line_id := 0
	for l in rail_ref.lines:
		if (int(l["st_a"]) == a and int(l["st_b"]) == b) or (int(l["st_a"]) == b and int(l["st_b"]) == a):
			line_id = int(l["id"])
			break
	if line_id == 0:
		var res: Dictionary = rail_ref.create_passenger_line(a, b)
		if not res["ok"]:
			lbl_line_status.text = String(res["reason"])
			lbl_line_status.modulate = Color(1.0, 0.42, 0.42)
			return
		line_id = int(res["line"]["id"])

	var tres: Dictionary = rail_ref.buy_train_for_line(line_id)
	if not tres["ok"]:
		lbl_line_status.text = String(tres["reason"])
		lbl_line_status.modulate = Color(1.0, 0.42, 0.42)
		return
	_refresh_lines_panel()
	_sync_hud_state()
