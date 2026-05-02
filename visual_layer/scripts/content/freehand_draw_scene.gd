extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  FREEHAND DRAW  —  multi-touch painting canvas
#
#  Each touch leaves a neon brush stroke.  Hue cycles continuously so strokes
#  automatically build a rainbow composition.  Line width responds to drawing
#  speed and audio level.  Audio beats trigger a confetti ink-splatter burst.
#
#  Controls: tap the [CLEAR] button (top-right) to wipe the canvas.
#            tap [MODE] to cycle brush styles: Neon → Chalk → Spray
# ─────────────────────────────────────────────────────────────────────────────

const MAX_TRAIL_PTS := 128
const MIN_DIST      := 3.0
const MODES         := ["NEON", "CHALK", "SPRAY"]

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _hue_clock  : float = 0.0
var _mode_idx   : int   = 0
var _beat_cool  : float = 0.0

# trail_id → {line, glow, pts, head, prev_pos, hue}
var _trails     : Dictionary = {}


func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_add_ui()


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.0, 0.0, 0.0, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)


func _add_ui() -> void:
	var t := Label.new()
	t.text = "DRAW"
	t.add_theme_font_size_override("font_size", 34)
	t.modulate = Color(1.0, 0.88, 0.55)
	t.position = Vector2(24, 14)
	add_child(t)

	var clear_btn := Button.new()
	clear_btn.text                = "CLEAR"
	clear_btn.custom_minimum_size = Vector2(90, 38)
	clear_btn.position            = Vector2(vp_size.x - 110, 12)
	clear_btn.pressed.connect(_clear_canvas)
	add_child(clear_btn)

	var mode_btn := Button.new()
	mode_btn.text                = "MODE: NEON"
	mode_btn.name                = "ModeBtn"
	mode_btn.custom_minimum_size = Vector2(120, 38)
	mode_btn.position            = Vector2(vp_size.x - 240, 12)
	mode_btn.pressed.connect(_cycle_mode)
	add_child(mode_btn)


func _clear_canvas() -> void:
	for id in _trails:
		var tr : Dictionary = _trails[id]
		(tr["line"] as Node2D).queue_free()
		(tr["glow"] as Node2D).queue_free()
	_trails.clear()
	# Wipe any loose paint nodes
	for child in get_children():
		if child is ColorRect and child.name.begins_with("dot_"):
			child.queue_free()


func _cycle_mode() -> void:
	_mode_idx = (_mode_idx + 1) % MODES.size()
	var btn : Button = get_node_or_null("ModeBtn") as Button
	if btn:
		btn.text = "MODE: " + MODES[_mode_idx]


# ─────────────────────────────────────────────────────────────────────────────

func _make_trail(id: int, pos: Vector2, hue: float) -> Dictionary:
	var col : Color = Color.from_hsv(hue, 0.95, 1.0)

	var glow := Line2D.new()
	glow.width          = 22.0
	glow.default_color  = Color(col.r, col.g, col.b, 0.12)
	glow.joint_mode     = Line2D.LINE_JOINT_ROUND
	glow.begin_cap_mode = Line2D.LINE_CAP_ROUND
	glow.end_cap_mode   = Line2D.LINE_CAP_ROUND
	add_child(glow)

	var line := Line2D.new()
	line.width          = 5.0
	line.default_color  = col
	line.joint_mode     = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode   = Line2D.LINE_CAP_ROUND
	add_child(line)

	var pts : Array = []
	for _i in range(MAX_TRAIL_PTS):
		pts.append(pos)

	return {
		"id":       id,
		"line":     line,
		"glow":     glow,
		"pts":      pts,
		"head":     0,
		"prev_pos": pos,
		"hue":      hue,
		"speed":    0.0,
	}


func _stamp_spray(pos: Vector2, hue: float) -> void:
	for _i in range(8):
		var p   := ColorRect.new()
		p.name   = "dot_%d" % randi()
		var sz  : float = randf_range(2, 7)
		p.size         = Vector2(sz, sz)
		p.pivot_offset = p.size * 0.5
		p.color        = Color.from_hsv(fmod(hue + randf_range(-0.05, 0.05), 1.0), 0.9, 1.0, randf_range(0.5, 0.9))
		p.position     = pos + Vector2(randf_range(-30, 30), randf_range(-30, 30)) - p.pivot_offset
		add_child(p)


func _splatter(pos: Vector2) -> void:
	for _i in range(22):
		var p   := ColorRect.new()
		p.name   = "dot_%d" % randi()
		var sz  : float = randf_range(4, 14)
		p.size         = Vector2(sz, sz)
		p.pivot_offset = p.size * 0.5
		p.color        = Color.from_hsv(randf_range(0.0, 1.0), 0.9, 1.0)
		p.position     = pos + Vector2(randf_range(-120, 120), randf_range(-80, 80)) - p.pivot_offset
		p.rotation     = randf_range(0.0, TAU)
		add_child(p)
		var tw := p.create_tween()
		tw.tween_property(p, "modulate:a", 0.0, randf_range(1.2, 2.4))
		tw.tween_callback(p.queue_free)


# ─────────────────────────────────────────────────────────────────────────────
# Weighted 3-point average (1/4, 1/2, 1/4) applied to the ring buffer.
# Gives smooth Bézier-like curves without adding extra points.
func _smooth_pts(pts: Array, start: int, count: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	var n := pts.size()
	for j in range(count):
		var p0 : Vector2 = pts[(start + j - 1 + n) % n]
		var p1 : Vector2 = pts[(start + j)         % n]
		var p2 : Vector2 = pts[(start + j + 1)     % n]
		result.append((p0 + p1 * 2.0 + p2) * 0.25)
	return result

# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_audio_sm  = lerp(_audio_sm, audio_level, delta * 7.0)
	_hue_clock = fmod(_hue_clock + delta * 0.12, 1.0)
	_beat_cool -= delta

	# Beat detection → splatter
	if _audio_sm > 0.70 and _beat_cool <= 0.0:
		_splatter(vp_size * 0.5 + Vector2(randf_range(-200, 200), randf_range(-150, 150)))
		_beat_cool = 0.40

	var interactions := get_parent().get_node_or_null("Interactions")
	var active_ids   : Dictionary = {}

	if interactions:
		for touch in interactions.get_children():
			var id  : int     = touch.get_instance_id()
			var sp  : Vector2 = touch.position + touch.pivot_offset
			active_ids[id] = sp

			var trail_hue : float = fmod(_hue_clock + float(id) * 0.31, 1.0)

			match _mode_idx:
				0:  # NEON — smooth Line2D trails
					if not _trails.has(id):
						_trails[id] = _make_trail(id, sp, trail_hue)
					var tr : Dictionary = _trails[id]
					var prev : Vector2 = tr["prev_pos"]
					var moved : float  = sp.distance_to(prev)
					var head : int = tr["head"]
					if moved >= MIN_DIST:
						tr["speed"] = moved / delta
						tr["pts"][head] = sp
						head = (head + 1) % MAX_TRAIL_PTS
						tr["head"] = head
						tr["prev_pos"] = sp
						tr["hue"] = trail_hue
						_trails[id] = tr
					# Rebuild smoothed Line2D from ring buffer (oldest → newest)
					var line : Line2D = tr["line"] as Line2D
					var glow : Line2D = tr["glow"] as Line2D
					var spts := _smooth_pts(tr["pts"], head % MAX_TRAIL_PTS, MAX_TRAIL_PTS)
					var w : float = 4.0 + clamp(float(tr["speed"]) / 400.0, 0.0, 8.0) + _audio_sm * 7.0
					line.width = w
					glow.width = w * 4.5
					line.default_color = Color.from_hsv(trail_hue, 0.95, 1.0)
					glow.default_color = Color.from_hsv(trail_hue, 0.8, 1.0, 0.12)
					line.clear_points()
					glow.clear_points()
					for p in spts:
						line.add_point(p)
						glow.add_point(p)
				1:  # CHALK — dashed / rough
					if not _trails.has(id):
						_trails[id] = _make_trail(id, sp, trail_hue)
					var tr2 : Dictionary = _trails[id]
					var prev2 : Vector2 = tr2["prev_pos"]
					var line2 : Line2D = tr2["line"] as Line2D
					var glow2 : Line2D = tr2["glow"] as Line2D
					if sp.distance_to(prev2) >= MIN_DIST * 2:
						tr2["head"] = (tr2["head"] + 1) % MAX_TRAIL_PTS
						tr2["pts"][tr2["head"]] = sp
						tr2["prev_pos"] = sp
						_trails[id] = tr2
					var h : int = tr2["head"]
					var spts2 := _smooth_pts(tr2["pts"], (h + 1) % MAX_TRAIL_PTS, MAX_TRAIL_PTS)
					line2.width = 9.0 + _audio_sm * 5.0
					glow2.width = 14.0
					line2.default_color = Color.from_hsv(trail_hue, 0.30, 0.95, 0.70)
					glow2.default_color = Color(1, 1, 1, 0.04)
					line2.clear_points()
					glow2.clear_points()
					for p in spts2:
						line2.add_point(p + Vector2(randf_range(-1.5, 1.5), randf_range(-1.5, 1.5)))
						glow2.add_point(p)
				2:  # SPRAY
					_stamp_spray(sp, trail_hue)

	# Remove trails for lifted fingers
	var to_rm : Array = []
	for id in _trails:
		if not active_ids.has(id):
			to_rm.append(id)
	for id in to_rm:
		var tr : Dictionary = _trails[id]
		(tr["line"] as Node2D).queue_free()
		(tr["glow"] as Node2D).queue_free()
		_trails.erase(id)
