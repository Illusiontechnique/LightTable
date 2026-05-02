extends Node2D

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  BOUNCING BALLS  â€”  physics sandbox
#
#  â€¢ 14 balls with gravity, wall-bounce, proper elastic ball-ball collisions
#  â€¢ Touch/hand position REPELS nearby balls (kick, not grab)
#  â€¢ Soft connection lines drawn between nearby pairs (visual only)
#  â€¢ Audio beat: radial explosion from centre
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

const NUM_BALLS    := 14
const GRAVITY      := 380.0
const WALL_DAMP    := 0.78
const AIR_RES      := 0.9988     # per-frame velocity multiplier
const CONNECT_DIST := 195.0      # max distance to draw a connection line
const KICK_RADIUS  := 160.0      # cursor repulsion radius  (px)
const KICK_FORCE   := 1400.0     # cursor repulsion strength (px/sÂ² at edge)

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _prev_audio : float = 0.0
var _beat_cool  : float = 0.0

# Ball data: {pos, vel, r, col, node (Polygon2D)}
var _balls      : Array = []


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
	s.text = "Your hands repel the balls Â· loud sound = explosion"
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
	node.position = Vector2(randf_range(r + 60, vp_size.x - r - 60),
	                        randf_range(r + 80, vp_size.y * 0.50))
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
		"vel":  Vector2(randf_range(-180, 180), randf_range(-100, 100)),
		"r":    r,
		"col":  col,
		"node": node,
	})


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  Connection-line drawing (visual only)
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

func _draw() -> void:
	for i in _balls.size():
		var a  : Dictionary = _balls[i]
		var pa : Vector2    = a["pos"]
		for j in range(i + 1, _balls.size()):
			var b  : Dictionary = _balls[j]
			var pb : Vector2    = b["pos"]
			var d  : float      = pa.distance_to(pb)
			if d < CONNECT_DIST:
				var t   : float = 1.0 - d / CONNECT_DIST
				draw_line(pa, pb, Color(0.45, 0.75, 1.0, t * 0.35), 1.6)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

func _process(delta: float) -> void:
	_prev_audio = _audio_sm
	_audio_sm   = lerp(_audio_sm, audio_level, delta * 7.0)
	_beat_cool -= delta

	# Loud beat â†’ radial explosion from centre
	if _audio_sm > 0.65 and _prev_audio < 0.45 and _beat_cool <= 0.0:
		var ctr : Vector2 = vp_size * 0.5
		for bi in _balls.size():
			var b   : Dictionary = _balls[bi]
			var dir : Vector2    = (b["pos"] - ctr).normalized()
			b["vel"] += dir * _audio_sm * 900.0
			_balls[bi] = b
		_beat_cool = 0.35

	# Collect touch positions
	var touch_positions : Array = []
	var interactions := get_parent().get_node_or_null("Interactions")
	if interactions:
		for touch in interactions.get_children():
			touch_positions.append(touch.position + touch.pivot_offset)

	# â”€â”€ Pass 1: gravity, air resistance, cursor kick, wall bounce â”€â”€â”€â”€â”€â”€
	for i in _balls.size():
		var b   : Dictionary = _balls[i]
		var pos : Vector2    = b["pos"]
		var vel : Vector2    = b["vel"]
		var r   : float      = b["r"]

		vel.y += GRAVITY * delta
		vel   *= AIR_RES

		# Cursor repulsion
		for tp in touch_positions:
			var diff : Vector2 = pos - tp
			var dist : float   = diff.length()
			if dist < KICK_RADIUS and dist > 1.0:
				var strength : float = (1.0 - dist / KICK_RADIUS) * KICK_FORCE
				vel += diff.normalized() * strength * delta

		pos += vel * delta

		# Wall bounce
		if pos.x - r < 0.0:
			pos.x = r;                 vel.x = abs(vel.x) * WALL_DAMP
		elif pos.x + r > vp_size.x:
			pos.x = vp_size.x - r;    vel.x = -abs(vel.x) * WALL_DAMP
		if pos.y - r < 0.0:
			pos.y = r;                 vel.y = abs(vel.y) * WALL_DAMP
		elif pos.y + r > vp_size.y:
			pos.y = vp_size.y - r;    vel.y = -abs(vel.y) * WALL_DAMP

		b["pos"] = pos
		b["vel"] = vel
		_balls[i] = b

	# â”€â”€ Pass 2: elastic ball-ball collisions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	for i in _balls.size():
		for j in range(i + 1, _balls.size()):
			var bi   : Dictionary = _balls[i]
			var bj   : Dictionary = _balls[j]
			var diff : Vector2    = bj["pos"] - bi["pos"]
			var dist : float      = diff.length()
			var min_d : float     = bi["r"] + bj["r"]
			if dist >= min_d or dist < 0.01:
				continue

			# Separate
			var n   : Vector2 = diff / dist
			var pen : float   = (min_d - dist) * 0.5
			bi["pos"] -= n * pen
			bj["pos"] += n * pen

			# Equal-mass elastic velocity exchange along normal
			var v1n : float = bi["vel"].dot(n)
			var v2n : float = bj["vel"].dot(n)
			if v1n > v2n:   # approaching
				bi["vel"] += n * (v2n - v1n) * WALL_DAMP
				bj["vel"] += n * (v1n - v2n) * WALL_DAMP

			_balls[i] = bi
			_balls[j] = bj

	# â”€â”€ Update node positions & colours â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	for i in _balls.size():
		var b  : Dictionary = _balls[i]
		var nd : Node2D     = b["node"] as Node2D
		nd.position = b["pos"]
		if _audio_sm > 0.1:
			nd.modulate = Color(1.0 + _audio_sm * 0.5, 1.0 + _audio_sm * 0.3, 1.0, 1.0)
		else:
			nd.modulate = Color(1, 1, 1, 1)

	queue_redraw()
