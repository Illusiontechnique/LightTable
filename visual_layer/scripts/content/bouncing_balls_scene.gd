extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  BOUNCING BALLS  —  physics sandbox with springs
#
#  • NUM_BALLS balls with velocity, gravity, wall-bounce, ball-ball push-apart
#  • Spring connections drawn as glowing lines between nearby pairs
#  • Touch / hand position grabs the nearest ball and pulls it with a spring
#  • Release: the ball flies with the accumulated velocity (fling)
#  • Audio beat: radial explosion pushes all balls outward from centre
#
#  Springs are drawn via _draw() + queue_redraw() — very efficient (zero nodes).
# ─────────────────────────────────────────────────────────────────────────────

const NUM_BALLS    := 14
const GRAVITY      := 420.0       # px / s²
const WALL_DAMP    := 0.72
const AIR_RES      := 0.9985      # per-frame velocity multiplier
const SPRING_DIST  := 195.0       # max distance to draw a spring
const SPRING_K     := 95.0        # spring stiffness
const REST_LEN     := 125.0       # spring natural length
const GRAB_SPRING  := 0.45        # grab pull strength (0-1 lerp factor)

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _prev_audio : float = 0.0
var _beat_cool  : float = 0.0

# Ball data: {pos, vel, r, col, node (Polygon2D)}
var _balls      : Array = []
var _grabbed    : int   = -1   # index of grabbed ball
var _grab_vel   : Vector2 = Vector2.ZERO   # velocity tracking for fling


func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	for i in range(NUM_BALLS):
		_create_ball(i)

	var t := Label.new()
	t.text = "BOUNCING BALLS"
	t.add_theme_font_size_override("font_size", 28)
	t.modulate = Color(1.0, 0.88, 0.55, 0.75)
	t.position = Vector2(24, 12)
	add_child(t)

	var s := Label.new()
	s.text = "Grab balls · loud sound = explosion"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(1.0, 0.88, 0.55, 0.50)
	s.position = Vector2(24, 48)
	add_child(s)


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.01, 0.01, 0.02, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)


func _circle_pts(r: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var a : float = TAU * float(i) / float(n)
		pts.append(Vector2(cos(a) * r, sin(a) * r))
	return pts


func _create_ball(i: int) -> void:
	var hue : float = float(i) / float(NUM_BALLS)
	var col : Color = Color.from_hsv(hue, 0.82, 1.0)
	var r   : float = randf_range(18, 38)

	var node := Polygon2D.new()
	node.polygon  = _circle_pts(r, 28)
	node.color    = col
	node.position = Vector2(randf_range(r + 40, vp_size.x - r - 40),
	                        randf_range(r + 80, vp_size.y * 0.55))
	add_child(node)

	# Faux-3D highlight
	var hi := Polygon2D.new()
	hi.polygon  = _circle_pts(r * 0.32, 14)
	hi.color    = Color(1, 1, 1, 0.35)
	hi.position = Vector2(-r * 0.28, -r * 0.30)
	node.add_child(hi)

	# Rim shadow
	var rim := Polygon2D.new()
	rim.polygon  = _circle_pts(r * 0.40, 14)
	rim.color    = Color(0, 0, 0, 0.22)
	rim.position = Vector2(r * 0.22, r * 0.24)
	node.add_child(rim)

	_balls.append({
		"pos":  node.position,
		"vel":  Vector2(randf_range(-140, 140), randf_range(-80, 80)),
		"r":    r,
		"col":  col,
		"node": node,
	})


# ─────────────────────────────────────────────────────────────────────────────
#  Spring + connection drawing
# ─────────────────────────────────────────────────────────────────────────────

func _draw() -> void:
	for i in _balls.size():
		var a  : Dictionary = _balls[i]
		var pa : Vector2    = a["pos"]
		for j in range(i + 1, _balls.size()):
			var b  : Dictionary = _balls[j]
			var pb : Vector2    = b["pos"]
			var d  : float      = pa.distance_to(pb)
			if d < SPRING_DIST:
				var t   : float = 1.0 - d / SPRING_DIST
				var col : Color = Color(0.45, 0.75, 1.0, t * 0.40)
				draw_line(pa, pb, col, 1.8)

	# Grab line
	if _grabbed >= 0:
		var gb : Dictionary = _balls[_grabbed]
		draw_circle(gb["pos"], gb["r"] + 6.0, Color(1, 1, 1, 0.12))


# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_prev_audio = _audio_sm
	_audio_sm   = lerp(_audio_sm, audio_level, delta * 7.0)
	_beat_cool -= delta

	# Loud beat → radial explosion
	if _audio_sm > 0.65 and _prev_audio < 0.45 and _beat_cool <= 0.0:
		var ctr : Vector2 = vp_size * 0.5
		for bi in _balls.size():
			var b : Dictionary = _balls[bi]
			var dir : Vector2  = (b["pos"] - ctr).normalized()
			b["vel"] += dir * _audio_sm * 900.0
			_balls[bi] = b
		_beat_cool = 0.35

	# Grab: find nearest ball to first touch
	var interactions := get_parent().get_node_or_null("Interactions")
	var grab_pos     : Vector2 = Vector2(-99999, -99999)
	var has_touch    : bool    = false

	if interactions and interactions.get_child_count() > 0:
		has_touch = true
		var touch = interactions.get_child(0)
		grab_pos  = touch.position + touch.pivot_offset

		if _grabbed < 0:
			# Pick nearest ball
			var best_d : float = 80.0
			var best_i : int   = -1
			for bi in _balls.size():
				var b : Dictionary = _balls[bi]
				var d : float      = (b["pos"] as Vector2).distance_to(grab_pos)
				if d < best_d:
					best_d = d
					best_i = bi
			_grabbed = best_i

	if not has_touch:
		if _grabbed >= 0:
			# Fling on release
			var gb : Dictionary = _balls[_grabbed]
			gb["vel"] += _grab_vel * 1.4
			_balls[_grabbed] = gb
		_grabbed  = -1
		_grab_vel = Vector2.ZERO

	# ── Physics update ─────────────────────────────────────────────────
	for i in _balls.size():
		var b   : Dictionary = _balls[i]
		var pos : Vector2    = b["pos"]
		var vel : Vector2    = b["vel"]
		var r   : float      = b["r"]

		if i == _grabbed and has_touch:
			# Soft spring toward grab_pos
			var prev_pos : Vector2 = pos
			pos = pos.lerp(grab_pos, GRAB_SPRING)
			_grab_vel = (pos - prev_pos) / delta
			vel = vel * 0.55
		else:
			# Gravity + air resistance
			vel.y += GRAVITY * delta
			vel   *= AIR_RES

			# Spring forces from other balls
			for j in _balls.size():
				if j == i:
					continue
				var o     : Dictionary = _balls[j]
				var diff  : Vector2    = o["pos"] - pos
				var dist  : float      = diff.length()
				if dist < SPRING_DIST and dist > 2.0:
					var force : float = SPRING_K * (dist - REST_LEN)
					vel += diff.normalized() * force * delta

			# Ball-ball push-apart collision
			for j in _balls.size():
				if j == i:
					continue
				var o2    : Dictionary = _balls[j]
				var diff2 : Vector2    = o2["pos"] - pos
				var dist2 : float      = diff2.length()
				var min_d : float      = r + o2["r"]
				if dist2 < min_d and dist2 > 0.01:
					var pen : float = (min_d - dist2) * 0.5
					pos -= diff2.normalized() * pen
					vel  = vel.reflect(diff2.normalized()) * WALL_DAMP

			pos += vel * delta

		# Wall bounce
		if pos.x - r < 0.0:
			pos.x = r;         vel.x =  abs(vel.x) * WALL_DAMP
		elif pos.x + r > vp_size.x:
			pos.x = vp_size.x - r; vel.x = -abs(vel.x) * WALL_DAMP
		if pos.y - r < 0.0:
			pos.y = r;         vel.y =  abs(vel.y) * WALL_DAMP
		elif pos.y + r > vp_size.y:
			pos.y = vp_size.y - r; vel.y = -abs(vel.y) * WALL_DAMP

		b["pos"]  = pos
		b["vel"]  = vel
		var nd : Node2D = b["node"] as Node2D
		nd.position = pos

		# Color pulse from audio
		if _audio_sm > 0.1:
			var col : Color = b["col"]
			nd.modulate = Color(1.0 + _audio_sm * 0.5, 1.0 + _audio_sm * 0.3, 1.0, 1.0)
		else:
			nd.modulate = Color(1, 1, 1, 1)

		_balls[i] = b

	queue_redraw()
