extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  COLOR TRAILS  —  best used with Color tracker (HSV range)
#
#  Tracks a specific colour (default: orange/skin) and draws a vivid neon trail
#  behind it.  The trail uses a deque of Line2D segments with tapering width
#  and auto-fading alpha.  Multiple simultaneous colour blobs each get their
#  own hue-shifted trail.
#
#  Under the trail, a ghost "wake" is drawn with additive blending to simulate
#  the light-table glow underneath the surface.
# ─────────────────────────────────────────────────────────────────────────────

const TRAIL_SEGMENTS := 64     # points per trail
const TRAIL_DECAY    := 1.4    # alpha fade rate per second
const MIN_DIST       := 5.0    # min pixel movement before new trail point
const MAX_TRAILS     := 8

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0

# trail_id (touch instance id) → trail dict
var _trails : Dictionary = {}

var _palette := [
	Color(0.10, 0.90, 1.00),
	Color(0.95, 0.25, 0.80),
	Color(0.20, 1.00, 0.45),
	Color(1.00, 0.80, 0.05),
	Color(1.00, 0.30, 0.10),
	Color(0.50, 0.30, 1.00),
	Color(0.10, 1.00, 0.85),
	Color(1.00, 0.55, 0.80),
]
var _pal_idx : int = 0

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	vp_size = get_viewport_rect().size
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
	t.text = "COLOR TRAILS"
	t.add_theme_font_size_override("font_size", 34)
	t.modulate = Color(1.0, 0.85, 0.55)
	t.position = Vector2(24, 18)
	add_child(t)
	var s := Label.new()
	s.text = "Color tracker · hold a coloured object to paint neon trails"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(1.0, 0.85, 0.55, 0.75)
	s.position = Vector2(24, 58)
	add_child(s)


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)

# ─────────────────────────────────────────────────────────────────────────────
#  Trail factory
# ─────────────────────────────────────────────────────────────────────────────

func _make_trail(id: int, pos: Vector2) -> Dictionary:
	var col : Color = _palette[_pal_idx % _palette.size()]
	_pal_idx += 1

	# Primary neon line
	var line := Line2D.new()
	line.width          = 8.0
	line.default_color  = col
	line.joint_mode     = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode   = Line2D.LINE_CAP_ROUND
	add_child(line)

	# Soft glow copy (wider, lower alpha)
	var glow := Line2D.new()
	glow.width          = 28.0
	glow.default_color  = Color(col.r, col.g, col.b, 0.18)
	glow.joint_mode     = Line2D.LINE_JOINT_ROUND
	glow.begin_cap_mode = Line2D.LINE_CAP_ROUND
	glow.end_cap_mode   = Line2D.LINE_CAP_ROUND
	add_child(glow)
	move_child(glow, get_child_count() - 2)   # glow behind primary

	# Head dot
	var head_dot := ColorRect.new()
	head_dot.size         = Vector2(20, 20)
	head_dot.pivot_offset = Vector2(10, 10)
	head_dot.color        = Color(1, 1, 1, 0.9)
	head_dot.position     = pos - Vector2(10, 10)
	add_child(head_dot)

	var pts : Array = []
	for _i in range(TRAIL_SEGMENTS):
		pts.append(pos)

	return {
		"id":        id,
		"line":      line,
		"glow":      glow,
		"head_dot":  head_dot,
		"pts":       pts,
		"alphas":    Array(),   # per-point alpha — populated on first point write
		"head":      0,
		"col":       col,
		"active":    true,
		"decay":     1.0,       # global fade when finger lifts
	}


func _remove_trail(id: int) -> void:
	if _trails.has(id):
		var tr : Dictionary = _trails[id]
		tr["line"].queue_free()
		tr["glow"].queue_free()
		tr["head_dot"].queue_free()
		_trails.erase(id)

# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_audio_sm = lerp(_audio_sm, audio_level, delta * 7.0)

	var interactions := get_parent().get_node_or_null("Interactions")
	var active_ids : Dictionary = {}

	if interactions:
		for touch in interactions.get_children():
			var id : int     = touch.get_instance_id()
			var sp : Vector2 = touch.position + touch.pivot_offset
			active_ids[id] = sp

			if not _trails.has(id):
				if _trails.size() < MAX_TRAILS:
					_trails[id] = _make_trail(id, sp)

	# Deactivate lifted trails
	for id in _trails:
		_trails[id]["active"] = active_ids.has(id)

	# Update each trail
	var to_rm : Array = []
	for id in _trails:
		var tr : Dictionary = _trails[id]

		if tr["active"]:
			tr["decay"] = 1.0
			var sp : Vector2 = active_ids[id]
			var head : int   = tr["head"]
			var prev : Vector2 = tr["pts"][(head - 1 + TRAIL_SEGMENTS) % TRAIL_SEGMENTS]

			if sp.distance_to(prev) >= MIN_DIST:
				tr["pts"][head] = sp
				tr["head"]      = (head + 1) % TRAIL_SEGMENTS

			# Move head dot
			var hd : ColorRect = tr["head_dot"]
			hd.position = sp - Vector2(10, 10)
			hd.color    = Color(1, 1, 1, 0.6 + _audio_sm * 0.4)
			hd.visible  = true

		else:
			tr["decay"] = max(0.0, tr["decay"] - delta * TRAIL_DECAY)
			tr["head_dot"].visible = false
			if tr["decay"] <= 0.001:
				to_rm.append(id)
				continue

		# Rebuild line from ring buffer (ordered from oldest to newest)
		var col      : Color = tr["col"]
		var decay    : float = tr["decay"]
		var line     : Line2D = tr["line"]
		var glow     : Line2D = tr["glow"]
		var head_idx : int    = tr["head"]

		line.clear_points()
		glow.clear_points()

		for i in range(TRAIL_SEGMENTS):
			var age_i  : int     = (head_idx - TRAIL_SEGMENTS + i + TRAIL_SEGMENTS) % TRAIL_SEGMENTS
			var pt     : Vector2 = tr["pts"][age_i]
			var frac   : float   = float(i) / float(TRAIL_SEGMENTS - 1)
			# Width and alpha taper toward tail
			var alpha  : float   = pow(frac, 1.4) * decay * (0.55 + _audio_sm * 0.45)
			line.add_point(pt)
			glow.add_point(pt)
			# Set per-point colour via gradient trick: recolour whole line based on speed (audio)
			# (Line2D only supports uniform colour without a gradient resource; use taper via alpha)

		var speed_hue : float = fmod(col.h + _audio_sm * 0.22, 1.0)
		line.default_color = Color.from_hsv(speed_hue, 0.9, 1.0, decay)
		glow.default_color = Color.from_hsv(speed_hue, 0.7, 1.0, decay * 0.22)
		line.width = 6.0 + _audio_sm * 8.0
		glow.width = 22.0 + _audio_sm * 18.0

	for id in to_rm:
		_remove_trail(id)
