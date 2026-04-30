extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  BALLOONS  —  faux-3D balloons with synthesized pop sounds + confetti
#
#  Each balloon is 6 Polygon2D layers:
#    shadow → ambient base → lit face → rim glow → specular → specular dot
#  This stacking with offsets gives the illusion of a sphere lit from upper-left.
#
#  Pop sound: white-noise burst + low-frequency "thud" sine, ~80 ms, fast decay.
# ─────────────────────────────────────────────────────────────────────────────

const SAMPLE_RATE : float = 44100.0
const COLORS : Array = [
	Color(0.10, 0.92, 1.00),
	Color(1.00, 0.22, 0.80),
	Color(1.00, 0.90, 0.15),
	Color(0.40, 0.95, 0.30),
	Color(0.95, 0.50, 1.00),
	Color(1.00, 0.45, 0.10),
	Color(0.40, 0.55, 1.00),
]

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _balloons   : Array = []
var _pop_count  : int   = 0
var _pop_label  : Label

func _ready() -> void:
	vp_size = get_viewport_rect().size
	var bg := ColorRect.new()
	bg.color    = Color(0.02, 0.02, 0.04, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)

	var t := Label.new()
	t.text = "BALLOONS"
	t.add_theme_font_size_override("font_size", 34)
	t.modulate = Color(1.0, 0.92, 0.55)
	t.position = Vector2(24, 18)
	add_child(t)

	var s := Label.new()
	s.text = "Pop the balloons · faux-3D · synthesized sound"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(1.0, 0.92, 0.55, 0.65)
	s.position = Vector2(24, 56)
	add_child(s)

	# Pop counter — top-right
	_pop_label = Label.new()
	_pop_label.text = "POPS: 0"
	_pop_label.add_theme_font_size_override("font_size", 42)
	_pop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pop_label.modulate = Color(1.0, 0.92, 0.55, 0.92)
	_pop_label.size = Vector2(vp_size.x - 24, 60)
	_pop_label.position = Vector2(0, 18)
	add_child(_pop_label)

	for _i in range(10):
		_spawn_balloon()


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func _oval(rx: float, ry: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var a : float = TAU * float(i) / float(n)
		pts.append(Vector2(cos(a) * rx, sin(a) * ry))
	return pts


func _spawn_balloon() -> void:
	if _balloons.size() >= 12:
		return
	var col : Color = COLORS[randi() % COLORS.size()]
	var sc  : float = randf_range(0.85, 1.30)
	var root := Node2D.new()
	root.position = Vector2(randf_range(90, vp_size.x - 90), vp_size.y + randf_range(20, 80))
	root.scale    = Vector2(sc, sc)
	add_child(root)

	# Layer 1: drop shadow
	var shadow := Polygon2D.new()
	shadow.color   = Color(0, 0, 0, 0.28)
	shadow.polygon = _oval(28, 36, 32)
	shadow.position = Vector2(11, 14)
	root.add_child(shadow)

	# Layer 2: ambient base (dark)
	var base := Polygon2D.new()
	base.color   = Color(col.r * 0.42, col.g * 0.42, col.b * 0.42, 1.0)
	base.polygon = _oval(28, 38, 32)
	root.add_child(base)

	# Layer 3: lit face (main colour, offset toward upper-left light)
	var lit := Polygon2D.new()
	lit.color   = col
	lit.polygon = _oval(23, 31, 32)
	lit.position = Vector2(-5, -7)
	root.add_child(lit)

	# Layer 4: rim glow (lower-right edge, cool rim light)
	var rim := Polygon2D.new()
	rim.color   = Color(col.r * 0.65, col.g * 0.65, min(col.b * 1.5, 1.0), 0.30)
	rim.polygon = _oval(10, 13, 16)
	rim.position = Vector2(15, 17)
	root.add_child(rim)

	# Layer 5: specular highlight blob
	var spec := Polygon2D.new()
	spec.color   = Color(1, 1, 1, 0.58)
	spec.polygon = _oval(7, 9, 16)
	spec.position = Vector2(-13, -17)
	root.add_child(spec)

	# Layer 6: hard specular dot
	var dot := Polygon2D.new()
	dot.color   = Color(1, 1, 1, 0.90)
	dot.polygon = _oval(3, 3.5, 10)
	dot.position = Vector2(-16, -22)
	root.add_child(dot)

	# Knot
	var knot := Polygon2D.new()
	knot.color   = Color(col.r * 0.50, col.g * 0.50, col.b * 0.50, 1.0)
	knot.polygon = PackedVector2Array([
		Vector2(-4, 0), Vector2(4, 0),
		Vector2(3, 10), Vector2(0, 7), Vector2(-3, 10)
	])
	knot.position = Vector2(0, 41)
	root.add_child(knot)

	# String — curved with midpoint wobble
	var str_line := Line2D.new()
	str_line.add_point(Vector2(0, 50))
	str_line.add_point(Vector2(randf_range(-18, 18), 86))
	str_line.add_point(Vector2(randf_range(-8, 8), 122))
	str_line.width         = 1.6
	str_line.default_color = Color(1, 1, 1, 0.50)
	root.add_child(str_line)

	_balloons.append({
		"node":    root,
		"col":     col,
		"sc":      sc,
		"speed":   randf_range(42, 115),
		"sway":    randf_range(0.6, 2.1),
		"phase":   randf_range(0.0, TAU),
		"radius":  43.0 * sc,
		"popping": false,
	})


# ─────────────────────────────────────────────────────────────────────────────
#  Pop sound synthesis
# ─────────────────────────────────────────────────────────────────────────────

func _play_pop(pitch: float) -> void:
	var player := AudioStreamPlayer.new()
	var stream := AudioStreamGenerator.new()
	stream.mix_rate      = SAMPLE_RATE
	stream.buffer_length = 0.14
	player.stream    = stream
	player.volume_db = 3.5
	add_child(player)
	player.play()

	var pb   : AudioStreamGeneratorPlayback = player.get_stream_playback()
	var n    : int   = int(SAMPLE_RATE * 0.10)
	var ph   : float = 0.0
	var freq : float = 110.0 * pitch

	for i in range(n):
		var t     : float = float(i) / SAMPLE_RATE
		var env   : float = exp(-t * 55.0)
		var noise : float = randf_range(-1.0, 1.0)
		var thud  : float = sin(ph) * exp(-t * 22.0) * 0.78
		var s     : float = (noise * 0.45 + thud) * env * 0.95
		pb.push_frame(Vector2(s, s))
		ph += TAU * freq / SAMPLE_RATE
		if ph > TAU:
			ph -= TAU

	get_tree().create_timer(0.18).timeout.connect(player.queue_free)


# ─────────────────────────────────────────────────────────────────────────────
#  Confetti burst
# ─────────────────────────────────────────────────────────────────────────────

func _confetti(pos: Vector2, col: Color) -> void:
	for _i in range(22):
		var p   := ColorRect.new()
		var w   : float = randf_range(4, 11)
		var h   : float = randf_range(5, 16)
		p.size         = Vector2(w, h)
		p.pivot_offset = Vector2(w * 0.5, h * 0.5)
		p.color        = Color.from_hsv(fmod(col.h + randf_range(-0.22, 0.22), 1.0), 0.9, 1.0)
		p.position     = pos - p.pivot_offset
		p.rotation     = randf_range(0.0, TAU)
		add_child(p)
		var vel : Vector2 = Vector2(randf_range(-1.0, 1.0), randf_range(-1.8, 0.0)).normalized() * randf_range(80, 290)
		var tw  := p.create_tween()
		tw.tween_property(p, "position", p.position + vel * 0.52, 0.52)
		tw.parallel().tween_property(p, "rotation",  p.rotation + randf_range(-PI * 3, PI * 3), 0.52)
		tw.parallel().tween_property(p, "modulate:a", 0.0, 0.52)
		tw.tween_callback(p.queue_free)


func _pop_balloon(idx: int) -> void:
	var b : Dictionary = _balloons[idx]
	if b["popping"]:
		return
	b["popping"] = true
	_balloons[idx] = b

	_play_pop(randf_range(0.7, 1.65))
	_confetti(b["node"].global_position, b["col"])

	_pop_count += 1
	if _pop_label:
		_pop_label.text = "POPS: %d" % _pop_count

	var sc : float = b["sc"]
	var tw := (b["node"] as Node2D).create_tween()
	tw.tween_property(b["node"], "scale", Vector2(sc * 2.2, sc * 2.2), 0.06)
	tw.parallel().tween_property(b["node"], "modulate", Color(2.8, 2.8, 2.8, 1.0), 0.05)
	tw.tween_property(b["node"], "modulate:a", 0.0, 0.10)
	tw.tween_callback(b["node"].queue_free)

	_balloons.remove_at(idx)
	get_tree().create_timer(randf_range(0.6, 1.8)).timeout.connect(_spawn_balloon)


# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_audio_sm = lerp(_audio_sm, audio_level, delta * 5.0)
	var t : float = Time.get_ticks_msec() / 1000.0

	var interactions := get_parent().get_node_or_null("Interactions")

	for i in range(_balloons.size() - 1, -1, -1):
		var b : Dictionary = _balloons[i]
		if b["popping"]:
			continue

		var sc    : float = b["sc"]
		var pulse : float = 1.0 + sin(t * 2.6 + b["phase"]) * 0.022

		(b["node"] as Node2D).scale      = Vector2(sc * pulse, sc * (pulse + 0.014))
		(b["node"] as Node2D).position.y -= (b["speed"] + _audio_sm * 38.0) * delta
		(b["node"] as Node2D).position.x += sin(t * b["sway"] + b["phase"]) * 20.0 * delta
		(b["node"] as Node2D).rotation    = sin(t * 0.85 + b["phase"]) * 0.06

		if (b["node"] as Node2D).position.y < -165.0:
			(b["node"] as Node2D).position.y = vp_size.y + 60.0
			(b["node"] as Node2D).position.x = randf_range(90, vp_size.x - 90)

		if interactions:
			for touch in interactions.get_children():
				var tp : Vector2 = touch.position + touch.pivot_offset
				if (b["node"] as Node2D).global_position.distance_to(tp) < b["radius"]:
					_pop_balloon(i)
					break
