extends Node2D
## Replaces raw ColorRect interaction indicators with glowing cursors + radius rings.
## main.gd calls update_cursor() each frame; stale entries auto-expire.

var positions:     Dictionary = {}   # id(int) → {pos: Vector2, t: float}
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

func update_cursor(id: int, pos: Vector2) -> void:
	positions[id] = {"pos": pos, "t": Time.get_ticks_msec() * 0.001}

func clear_all() -> void:
	positions.clear()

func _draw() -> void:
	if not show_cursors:
		return
	for id in positions:
		_draw_cursor(positions[id]["pos"])

func _draw_cursor(p: Vector2) -> void:
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
