extends Control

# Crisp cartographic railway-map overlay projected over the 3D terrain when zoomed out,
# allowing 3D tracks, stations, signals & trains to stay at sleek true-to-satellite fine scale!

var cam_ref: Camera3D = null
var rail_ref: Node3D = null
var world_ref: Node3D = null
var cam_dist: float = 40.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func setup(cam: Camera3D, rail: Node3D, world: Node3D) -> void:
	cam_ref = cam
	rail_ref = rail
	world_ref = world


func update_overlay(dist: float) -> void:
	cam_dist = dist
	visible = (cam_dist > 3.5 and rail_ref != null and cam_ref != null)
	if visible:
		queue_redraw()


func _draw() -> void:
	if not visible or cam_ref == null or rail_ref == null:
		return

	# Smooth cross-fade from micro-scale 3D (cam_dist <= 3.5) to crisp cartographic atlas overlay (cam_dist >= 10)
	var alpha := clampf((cam_dist - 3.5) / 6.5, 0.0, 0.94)
	if alpha <= 0.01:
		return

	var vp_size := get_viewport_rect().size
	var casing_col := Color(0.10, 0.12, 0.15, alpha * 0.85)
	var rail_col := Color(0.97, 0.92, 0.78, alpha)
	var dbl_col := Color(1.0, 0.82, 0.36, alpha)
	var tun_col := Color(0.95, 0.72, 0.28, alpha * 0.55)

	# 1. Cartographic Railway Tracks
	for e in rail_ref.edges.values():
		if e.get("internal", false):
			continue
		var pts: Array = e["pts"]
		var n := pts.size()
		if n < 2:
			continue
		var is_dbl: bool = int(e.get("direction", 0)) != 0
		var t_en: int = int(e.get("t_entry", -1))
		var t_ex: int = int(e.get("t_exit", -1))
		var step := 1 if n <= 24 else 2
		var prev_s := Vector2.ZERO
		var has_prev := false

		var i := 0
		while i < n:
			var p3: Vector3 = (pts[i] as Vector3) + Vector3(0.0, 0.04, 0.0)
			if cam_ref.is_position_behind(p3):
				has_prev = false
			else:
				var sp := cam_ref.unproject_position(p3)
				if has_prev:
					var in_vp := (sp.x > -80.0 and sp.x < vp_size.x + 80.0 and sp.y > -80.0 and sp.y < vp_size.y + 80.0) \
						or (prev_s.x > -80.0 and prev_s.x < vp_size.x + 80.0 and prev_s.y > -80.0 and prev_s.y < vp_size.y + 80.0)
					if in_vp:
						var in_tun := (t_en != -1 and i >= t_en and i <= t_ex)
						if in_tun:
							if (i / step) % 2 == 0:
								draw_line(prev_s, sp, tun_col, 2.0, true)
						else:
							draw_line(prev_s, sp, casing_col, 4.4 if is_dbl else 3.6, true)
							draw_line(prev_s, sp, dbl_col if is_dbl else rail_col, 2.0 if is_dbl else 1.6, true)
				prev_s = sp
				has_prev = true
			if i == n - 1:
				break
			i = mini(n - 1, i + step)

	# 2. Cartographic Station Markers
	for st in rail_ref.stations:
		var sp2: Vector2 = st["pos"]
		var wy: float = world_ref.sample_world_y(sp2.x, sp2.y) if world_ref else 0.0
		var p3 := Vector3(sp2.x, maxf(0.0, wy) + 0.08, sp2.y)
		if cam_ref.is_position_behind(p3):
			continue
		var s := cam_ref.unproject_position(p3)
		if s.x < -30.0 or s.x > vp_size.x + 30.0 or s.y < -30.0 or s.y > vp_size.y + 30.0:
			continue
		draw_circle(s, 6.2, Color(0.10, 0.12, 0.15, alpha * 0.92))
		draw_circle(s, 4.6, Color(0.98, 0.96, 0.92, alpha))
		draw_circle(s, 2.8, Color(0.86, 0.22, 0.18, alpha))

	# 3. Live Moving Train Markers
	for tr in rail_ref.trains:
		var wp: Vector3 = tr.get("world_pos", Vector3.ZERO)
		if wp == Vector3.ZERO or cam_ref.is_position_behind(wp):
			continue
		var s := cam_ref.unproject_position(wp + Vector3(0.0, 0.08, 0.0))
		if s.x < -20.0 or s.x > vp_size.x + 20.0 or s.y < -20.0 or s.y > vp_size.y + 20.0:
			continue
		var st_str := String(tr.get("state", "RUNNING"))
		var col := Color(0.28, 0.92, 0.45, alpha)
		if st_str == "WAITING":
			col = Color(1.0, 0.30, 0.24, alpha)
		elif st_str == "LOADING":
			col = Color(1.0, 0.82, 0.28, alpha)
		draw_circle(s, 5.2, Color(0.08, 0.10, 0.12, alpha * 0.92))
		draw_circle(s, 3.6, col)
