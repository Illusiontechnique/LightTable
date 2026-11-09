extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  MOTION SPINNER  —  best used with Motion Detection or Blob tracker
#
#  Motion / touch energy accumulates into spinner wheels.  Each unique touch ID
#  drives its own spinner.  Multiple spinners orbit around a central attractor.
#  Audio energy adds a pulse to every spinner's radius and glow.
#
#  Visual language:
#    • Mandala-style N-armed spinner geometry (Line2D spokes + arc segments)
#    • Trails rendered as a ring of fading Line2D points
#    • Colour shifts with angular velocity (hue = speed)
#    • When untouched, spinners slowly coast and decay back to idle
# ─────────────────────────────────────────────────────────────────────────────

const MAX_SPINNERS     := 6
const SPOKE_COUNT      := 12     # arms per spinner
const TRAIL_LEN        := 48     # ghost positions per spinner
const IDLE_DECAY       := 0.92   # per-frame angular velocity decay
const AUDIO_PULSE      := 0.28   # how much audio pumps the radius

var vp_size     : Vector2
var audio_level : float = 0.0
var motion_amount : float = 0.0
var _audio_sm   : float = 0.0

# Dictionary: touch_id → spinner dict
var spinners    : Dictionary = {}

# Pool of base colours cycling through (vivid palette, dark-stage friendly)
var _palette := [
	Color(0.10, 0.90, 1.00),   # cyan
	Color(0.85, 0.20, 1.00),   # violet
	Color(0.15, 1.00, 0.55),   # neon green
	Color(1.00, 0.35, 0.10),   # ember orange
	Color(1.00, 0.92, 0.12),   # gold
	Color(0.90, 0.10, 0.55),   # hot pink
]
var _palette_idx : int = 0

# Central attractor — slowly drifts around screen
var _attractor   : Vector2
var _att_target  : Vector2
var _att_timer   : float = 0.0

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	vp_size    = get_viewport_rect().size
	_attractor = vp_size * 0.5
	_att_target = _attractor
	_add_backdrop()
	_add_labels()


func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.0, 0.0, 0.0, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)


func _add_labels() -> void:
	var t := Label.new()
	t.text = "MOTION SPINNER"
	t.add_theme_font_size_override("font_size", 34)
	t.modulate = Color(0.75, 1.0, 1.0)
	t.position = Vector2(24, 18)
	add_child(t)
	var s := Label.new()
	s.text = "Motion detection · move fast to spin · audio pulses the geometry"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(0.7, 0.9, 1.0, 0.75)
	s.position = Vector2(24, 58)
	add_child(s)

# ─────────────────────────────────────────────────────────────────────────────
#  Spinner factory
# ─────────────────────────────────────────────────────────────────────────────

func _make_spinner(id: int, pos: Vector2) -> Dictionary:
	var base_col : Color = _palette[_palette_idx % _palette.size()]
	_palette_idx += 1

	var root := Node2D.new()
	root.position = pos
	add_child(root)

	# Build spokes
	var spokes : Array = []
	for i in range(SPOKE_COUNT):
		var l := Line2D.new()
		l.width = 2.5
		l.default_color = base_col
		l.add_point(Vector2.ZERO)
		l.add_point(Vector2(0, -80))
		root.add_child(l)
		spokes.append(l)

	# Outer arc ring (polygon approximation)
	var ring := Polygon2D.new()
	ring.color = Color(base_col.r, base_col.g, base_col.b, 0.12)
	var pts := PackedVector2Array()
	for i in range(33):
		var a : float = TAU * float(i) / 32.0
		pts.append(Vector2(cos(a), sin(a)) * 86.0)
	ring.polygon = pts
	root.add_child(ring)

	# Trail — ring of small dots
	var trail_pts : Array = []
	var trail_nodes : Array = []
	for i in range(TRAIL_LEN):
		var d := ColorRect.new()
		d.size = Vector2(5, 5)
		d.pivot_offset = Vector2(2.5, 2.5)
		d.color = Color(base_col.r, base_col.g, base_col.b, 0.0)
		add_child(d)    # direct child of scene so it lags behind spinner root
		trail_nodes.append(d)
		trail_pts.append(pos)

	return {
		"id":          id,
		"root":        root,
		"spokes":      spokes,
		"ring":        ring,
		"trail_nodes": trail_nodes,
		"trail_pts":   trail_pts,
		"trail_head":  0,
		"pos":         pos,
		"angle":       0.0,
		"omega":       0.0,     # angular velocity (rad/s)
		"radius":      80.0,
		"base_col":    base_col,
		"last_pos":    pos,
		"orbit_angle": randf_range(0.0, TAU),
		"orbit_speed": randf_range(0.18, 0.42) * (1.0 if randf() > 0.5 else -1.0),
		"orbit_r":     randf_range(90.0, 260.0),
	}


func _remove_spinner(id: int) -> void:
	if spinners.has(id):
		var sp : Dictionary = spinners[id]
		sp["root"].queue_free()
		for d in sp["trail_nodes"]:
			d.queue_free()
		spinners.erase(id)

# ─────────────────────────────────────────────────────────────────────────────

func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)

func set_motion_amount(amount: float) -> void:
	motion_amount = clampf(amount, 0.0, 1.0)
	if motion_amount > 0.01 and spinners.is_empty():
		spinners[-1] = _make_spinner(-1, vp_size * 0.5)
		spinners[-1]["omega"] = 0.1

# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_audio_sm = lerp(_audio_sm, audio_level, delta * 7.0)

	# ── Drift attractor to a new random position every 6 s ─────────────
	_att_timer -= delta
	if _att_timer <= 0.0:
		_att_timer   = 5.5 + randf() * 3.0
		_att_target  = Vector2(
			randf_range(vp_size.x * 0.2, vp_size.x * 0.8),
			randf_range(vp_size.y * 0.2, vp_size.y * 0.8),
		)
	_attractor = _attractor.lerp(_att_target, delta * 0.35)

	# ── Gather current touches ──────────────────────────────────────────
	var interactions := get_parent().get_node_or_null("Interactions")
	var active_ids : Dictionary = {}

	if interactions:
		for touch in interactions.get_children():
			var id  : int     = touch.get_instance_id()
			var sp  : Vector2 = touch.position + touch.pivot_offset
			active_ids[id] = sp

			if not spinners.has(id):
				if spinners.size() < MAX_SPINNERS:
					spinners[id] = _make_spinner(id, sp)

	# ── Remove spinners for lifted touches (after coast) ───────────────
	# We keep them coasting — only remove if omega is near zero
	var to_remove : Array = []
	for id in spinners:
		if not active_ids.has(id):
			var sp_d : Dictionary = spinners[id]
			if abs(sp_d["omega"]) < 0.02:
				to_remove.append(id)
	for id in to_remove:
		_remove_spinner(id)

	# ── Update each spinner ─────────────────────────────────────────────
	for id in spinners:
		var sp   : Dictionary = spinners[id]
		var root : Node2D     = sp["root"]
		sp["omega"] += motion_amount * 8.0 * delta

		# --- Position: orbit around attractor if no active touch -------
		if active_ids.has(id):
			var raw_pos : Vector2 = active_ids[id]
			var moved   : float   = raw_pos.distance_to(sp["last_pos"])
			# Angular velocity proportional to movement speed
			sp["omega"] += moved * 4.5 * delta
			sp["last_pos"] = raw_pos
			# Smoothly pull root toward touch
			sp["pos"] = sp["pos"].lerp(raw_pos, delta * 8.0)
		else:
			# Coast + decay
			sp["omega"] *= pow(IDLE_DECAY, delta * 60.0)
			# Orbit the attractor while coasting
			sp["orbit_angle"] += sp["orbit_speed"] * delta
			var orb_r : float = sp["orbit_r"] * (1.0 + _audio_sm * 0.35)
			var target_pos := _attractor + Vector2(
				cos(sp["orbit_angle"]) * orb_r,
				sin(sp["orbit_angle"]) * orb_r * 0.55,
			)
			sp["pos"] = sp["pos"].lerp(target_pos, delta * 1.8)

		# Cap omega to avoid insane speed
		sp["omega"] = clamp(sp["omega"], -30.0, 30.0)

		# --- Integrate angle -------------------------------------------
		sp["angle"] += sp["omega"] * delta

		# --- Audio radius pulse ----------------------------------------
		sp["radius"] = 80.0 + _audio_sm * 60.0 * AUDIO_PULSE

		# --- Colour: hue shifts with speed ─────────────────────────────
		var speed_t : float = clamp(abs(sp["omega"]) / 15.0, 0.0, 1.0)
		var hue     : float = fmod(sp["base_col"].h + speed_t * 0.35, 1.0)
		var sat     : float = 0.55 + speed_t * 0.45
		var val     : float = 0.7  + speed_t * 0.3
		var live_col := Color.from_hsv(hue, sat, val)

		# --- Update root position & rotation ---------------------------
		root.position = sp["pos"]
		root.rotation  = sp["angle"]

		# --- Update spokes geometry ------------------------------------
		var r : float = sp["radius"]
		var spoke_alpha : float = 0.25 + speed_t * 0.75
		for i in range(SPOKE_COUNT):
			var spoke : Line2D = sp["spokes"][i]
			var spoke_angle : float = TAU * float(i) / float(SPOKE_COUNT)
			var tip := Vector2(cos(spoke_angle), sin(spoke_angle)) * r
			spoke.set_point_position(1, tip)
			# Sub-spoke flare: widen at tip when spinning fast
			spoke.width = 1.5 + speed_t * 3.5
			spoke.default_color = Color(live_col.r, live_col.g, live_col.b, spoke_alpha)

		# Outer ring pulse
		sp["ring"].color = Color(live_col.r, live_col.g, live_col.b, 0.06 + speed_t * 0.18 + _audio_sm * 0.12)

		# --- Trail ring of dots ----------------------------------------
		var head : int = sp["trail_head"]
		sp["trail_pts"][head] = sp["pos"]
		sp["trail_head"] = (head + 1) % TRAIL_LEN

		for i in range(TRAIL_LEN):
			var age_i : int    = (sp["trail_head"] - i - 1 + TRAIL_LEN) % TRAIL_LEN
			var dot   : ColorRect = sp["trail_nodes"][age_i]
			var tp    : Vector2   = sp["trail_pts"][age_i]
			var fade  : float     = float(TRAIL_LEN - i) / float(TRAIL_LEN)
			fade = pow(fade, 1.8)
			dot.position = tp - Vector2(2.5, 2.5)
			dot.color    = Color(live_col.r, live_col.g, live_col.b, fade * 0.55 * (0.4 + speed_t * 0.6))
