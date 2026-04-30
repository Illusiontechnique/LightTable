extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  ELEMENTS  —  four elemental zones: Wind / Fire / Water / Earth
#  Touch inside a zone spawns that element's particle system.
#  Audio intensity increases spawn rate and particle energy.
# ─────────────────────────────────────────────────────────────────────────────

const MAX_PARTICLES := 500

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _particles  : Array = []
var _zones      : Array = []   # [{name, rect, col}]


func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_build_zones()


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.0, 0.0, 0.0, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)


func _build_zones() -> void:
	var hw : float = vp_size.x * 0.5
	var hh : float = vp_size.y * 0.5

	var defs : Array = [
		["WIND",  Rect2(0,  0,  hw, hh), Color(0.40, 0.70, 1.00), Color(0.40, 0.70, 1.00, 0.06)],
		["FIRE",  Rect2(hw, 0,  hw, hh), Color(1.00, 0.45, 0.05), Color(1.00, 0.45, 0.05, 0.07)],
		["WATER", Rect2(0,  hh, hw, hh), Color(0.10, 0.80, 1.00), Color(0.10, 0.80, 1.00, 0.06)],
		["EARTH", Rect2(hw, hh, hw, hh), Color(0.40, 0.82, 0.22), Color(0.40, 0.82, 0.22, 0.06)],
	]

	for d in defs:
		var r    : Rect2  = d[1]
		var col  : Color  = d[2]
		var glow : Color  = d[3]

		var bg2 := ColorRect.new()
		bg2.color    = glow
		bg2.position = r.position
		bg2.size     = r.size
		add_child(bg2)

		# Zone name label (large, dim)
		var lbl := Label.new()
		lbl.text = d[0]
		lbl.add_theme_font_size_override("font_size", 64)
		lbl.modulate = Color(col.r, col.g, col.b, 0.13)
		# Bottom-left of each zone
		lbl.position = r.position + Vector2(18, r.size.y - 88)
		add_child(lbl)

		# Icon / element symbol (top-centre of zone)
		var icon := Label.new()
		var symbols : Array = ["≋", "🔥", "〜", "◼"]
		icon.text = symbols[_zones.size()]
		icon.add_theme_font_size_override("font_size", 40)
		icon.modulate = Color(col.r, col.g, col.b, 0.50)
		icon.position = r.position + Vector2(r.size.x * 0.5 - 22, 18)
		add_child(icon)

		_zones.append({"name": d[0], "rect": r, "col": col})

	# Dividers
	for pts in [
		[Vector2(0, hh), Vector2(vp_size.x, hh)],
		[Vector2(hw, 0), Vector2(hw, vp_size.y)],
	]:
		var ln := Line2D.new()
		ln.add_point(pts[0])
		ln.add_point(pts[1])
		ln.width         = 1.5
		ln.default_color = Color(1, 1, 1, 0.10)
		add_child(ln)

	# Title
	var t := Label.new()
	t.text = "ELEMENTS"
	t.add_theme_font_size_override("font_size", 28)
	t.modulate = Color(1, 1, 1, 0.55)
	t.position = Vector2(vp_size.x * 0.5 - 70, 10)
	add_child(t)


# ─────────────────────────────────────────────────────────────────────────────

func _zone_at(pos: Vector2) -> String:
	for z in _zones:
		var r : Rect2 = z["rect"]
		if r.has_point(pos):
			return z["name"]
	return ""


func _circle_pts(r: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var a : float = TAU * float(i) / float(n)
		pts.append(Vector2(cos(a) * r, sin(a) * r))
	return pts


# ── Spawn helpers ─────────────────────────────────────────────────────────────

func _spawn_fire(pos: Vector2, extra: int) -> void:
	for _i in range(3 + extra):
		if _particles.size() >= MAX_PARTICLES:
			return
		var p   := ColorRect.new()
		var sz  : float = randf_range(5, 16)
		p.size         = Vector2(sz * randf_range(0.6, 1.0), sz * randf_range(1.8, 3.2))
		p.pivot_offset = p.size * 0.5
		p.color        = Color.from_hsv(randf_range(0.0, 0.09), 1.0, 1.0)
		p.position     = pos - p.pivot_offset + Vector2(randf_range(-22, 22), randf_range(-5, 5))
		add_child(p)
		_particles.append({
			"node":     p,
			"type":     "fire",
			"vel":      Vector2(randf_range(-25, 25), randf_range(-200, -90)),
			"life":     1.0,
			"max_life": 1.0,
		})


func _spawn_wind(pos: Vector2, extra: int) -> void:
	for _i in range(2 + extra):
		if _particles.size() >= MAX_PARTICLES:
			return
		var p := ColorRect.new()
		p.size         = Vector2(randf_range(22, 72), randf_range(2, 5))
		p.pivot_offset = p.size * 0.5
		p.color        = Color(0.60, 0.85, 1.0, 0.9)
		p.position     = pos - p.pivot_offset + Vector2(randf_range(-50, 10), randf_range(-28, 28))
		add_child(p)
		_particles.append({
			"node":     p,
			"type":     "wind",
			"vel":      Vector2(randf_range(220, 480), randf_range(-18, 18)),
			"life":     0.55,
			"max_life": 0.55,
		})


func _spawn_water(pos: Vector2) -> void:
	if _particles.size() >= MAX_PARTICLES:
		return
	var ring := Line2D.new()
	var r    : float = randf_range(8, 18)
	for i in range(33):
		var a : float = TAU * float(i) / 32.0
		ring.add_point(Vector2(cos(a), sin(a)) * r)
	ring.closed        = true
	ring.width         = randf_range(2.0, 4.5)
	ring.default_color = Color(0.20, 0.85, 1.0, 0.85)
	ring.position      = pos + Vector2(randf_range(-12, 12), randf_range(-12, 12))
	add_child(ring)
	_particles.append({
		"node":     ring,
		"type":     "water",
		"vel":      Vector2.ZERO,
		"growth":   randf_range(65, 150),
		"life":     1.3,
		"max_life": 1.3,
	})


func _spawn_earth(pos: Vector2, extra: int) -> void:
	for _i in range(3 + extra):
		if _particles.size() >= MAX_PARTICLES:
			return
		var p := Polygon2D.new()
		var r : float = randf_range(4, 10)
		p.polygon  = _circle_pts(r, randi_range(4, 7))
		p.color    = Color.from_hsv(randf_range(0.22, 0.32), randf_range(0.55, 0.80), randf_range(0.38, 0.70))
		p.position = pos + Vector2(randf_range(-25, 25), randf_range(-8, 8))
		p.rotation = randf_range(0.0, TAU)
		add_child(p)
		_particles.append({
			"node":     p,
			"type":     "earth",
			"vel":      Vector2(randf_range(-55, 55), randf_range(-95, -25)),
			"life":     1.6,
			"max_life": 1.6,
		})


# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_audio_sm = lerp(_audio_sm, audio_level, delta * 6.0)
	var extra : int = int(_audio_sm * 4.0)

	var interactions := get_parent().get_node_or_null("Interactions")
	if interactions:
		for touch in interactions.get_children():
			var tp : Vector2 = touch.position + touch.pivot_offset
			match _zone_at(tp):
				"FIRE":  _spawn_fire(tp, extra)
				"WIND":  _spawn_wind(tp, extra)
				"WATER": _spawn_water(tp)
				"EARTH": _spawn_earth(tp, extra)

	# ── Update & cull particles ────────────────────────────────────────
	var dead : Array = []

	for i in _particles.size():
		var p : Dictionary = _particles[i]
		p["life"] -= delta
		if p["life"] <= 0.0:
			dead.append(i)
			(p["node"] as Node2D).queue_free()
			continue

		var frac : float = clamp(p["life"] / p["max_life"], 0.0, 1.0)
		var node : Node2D = p["node"] as Node2D
		var vel  : Vector2 = p["vel"]

		match p["type"]:
			"fire":
				node.position += vel * delta
				vel.x          *= 0.96
				vel.y          -= 30.0 * delta
				p["vel"]        = vel
				(node as ColorRect).color = Color.from_hsv(0.07 * frac, 1.0, 1.0, frac)
				node.rotation  += delta * randf_range(1.0, 2.5)
			"wind":
				node.position   += vel * delta
				vel.x           += 90.0 * delta
				p["vel"]         = vel
				(node as ColorRect).color.a = frac * 0.85
			"water":
				var growth : float = p["growth"]
				var sc     : float = 1.0 + (1.0 - frac) * growth * 0.04
				node.scale = Vector2(sc, sc)
				(node as Line2D).default_color.a = frac * 0.75
			"earth":
				node.position += vel * delta
				vel.y         += 300.0 * delta
				p["vel"]       = vel
				node.rotation += delta * 2.5
				(node as Polygon2D).color.a = frac

		_particles[i] = p

	for i in range(dead.size() - 1, -1, -1):
		_particles.remove_at(dead[i])
