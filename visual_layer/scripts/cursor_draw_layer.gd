extends Node2D
## Replaces raw ColorRect interaction indicators with glowing cursors + radius rings.
## main.gd calls update_cursor() each frame; stale entries auto-expire.

var positions:     Dictionary = {}   # id(int) → {pos: Vector2, t: float, meta: Dict}
var radius:        float = 65.0
var show_cursors:  bool  = true

const STALE_SEC := 0.40

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() * 0.001
	var stale := []
	for id in positions.keys():
		if now - positions[id]["t"] > STALE_SEC:
			stale.append(id)
	for id in stale:
		positions.erase(id)
	queue_redraw()

func update_cursor(id: int, pos: Vector2, metadata: Dictionary = {}) -> void:
	positions[id] = {"pos": pos, "t": Time.get_ticks_msec() * 0.001, "meta": metadata}

func remove_cursor(id: int) -> void:
	positions.erase(id)

func clear_all() -> void:
	positions.clear()

func _draw() -> void:
	if not show_cursors:
		return
	for id in positions:
		var d = positions[id]
		_draw_cursor(d["pos"], d["meta"])

func _draw_cursor(p: Vector2, meta: Dictionary) -> void:
	# Hide dev pointers if "pointers" is false in meta
	if meta.has("pointers") and not meta["pointers"]:
		return
		
	var is_hand = meta.has("tracker") and meta["tracker"] == "Hands"

	# Pointers: Shape of hands for Hands tracker, small arrow for others
	if is_hand:
		_draw_hand_icon(p)
	else:
		_draw_arrow_icon(p)

	# Original dev squares / rings logic below
	# Outer collision radius — double-ring soft glow
	draw_arc(p, radius,       0.0, TAU, 72, Color(0.20, 0.90, 1.0, 0.22), 1.5, true)
	draw_arc(p, radius - 5.0, 0.0, TAU, 72, Color(0.20, 0.90, 1.0, 0.07), 4.0, true)
	# Soft wide halo
	draw_circle(p, 28.0, Color(0.10, 0.75, 1.0, 0.06))
	# Mid glow
	draw_circle(p, 13.0, Color(0.15, 0.90, 1.0, 0.18))
	# Core dot
	draw_circle(p,  5.5, Color(0.45, 1.00, 1.0, 0.92))
	# Core ring
	draw_arc(p, 9.5, 0.0, TAU, 28, Color(0.50, 1.0, 1.0, 0.70), 1.3, true)

func _draw_hand_icon(p: Vector2) -> void:
	var hand_col = Color(0.8, 0.9, 1.0, 0.5)
	var size = 20.0
	# Simple 5-finger palm representation
	draw_circle(p, size * 0.6, hand_col) # Palm
	for i in range(5):
		var angle = -PI/2 + (i - 2) * 0.4
		var f_pos = p + Vector2(cos(angle), sin(angle)) * size
		draw_line(p, f_pos, hand_col, 4.0, true)
		draw_circle(f_pos, 3.0, hand_col)

func _draw_arrow_icon(p: Vector2) -> void:
	var arrow_col = Color(1.0, 1.0, 1.0, 0.6)
	var pts = PackedVector2Array([
		p,
		p + Vector2(0, 15),
		p + Vector2(10, 10),
		p
	])
	draw_colored_polygon(pts, arrow_col)
	draw_polyline(pts, Color(0,0,0,0.5), 1.0, true)
	# Outer collision radius — double-ring soft glow
	draw_arc(p, radius,       0.0, TAU, 72, Color(0.20, 0.90, 1.0, 0.22), 1.5, true)
	draw_arc(p, radius - 5.0, 0.0, TAU, 72, Color(0.20, 0.90, 1.0, 0.07), 4.0, true)
	# Soft wide halo
	draw_circle(p, 28.0, Color(0.10, 0.75, 1.0, 0.06))
	# Mid glow
	draw_circle(p, 13.0, Color(0.15, 0.90, 1.0, 0.18))
	# Core dot
	draw_circle(p,  5.5, Color(0.45, 1.00, 1.0, 0.92))
	# Core ring
	draw_arc(p, 9.5, 0.0, TAU, 28, Color(0.50, 1.0, 1.0, 0.70), 1.3, true)
