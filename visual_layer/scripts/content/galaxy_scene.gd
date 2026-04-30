extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  GALAXY  —  deep-space gravity well sandbox
#
#  Background: 300 static stars with independent twinkle rates, plus 4 large
#  soft nebula blobs drawn in _draw().
#
#  Touch creates a gravity well.  Particles spawn nearby and immediately
#  receive a tangential "orbital" velocity so they spiral into orbit.
#  Particle trails are short Line2D ring-buffers.  Old particles fade out.
#
#  Multiple simultaneous touch points = multiple competing gravity wells.
# ─────────────────────────────────────────────────────────────────────────────

const MAX_PARTICLES  := 280
const PARTICLE_LIFE  := 5.5
const TRAIL_LEN      := 12
const GRAV_STRENGTH  := 18000.0
const MIN_GRAV_DIST  := 28.0

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _time       : float = 0.0

# Stars: [{pos, alpha, twinkle_speed, twinkle_phase, size}]
var _stars      : Array = []

# Nebula blobs: [{pos, radius, col}]  — drawn in _draw()
var _nebulae    : Array = []

# Particles: [{pos, vel, life, col, trail_node (Line2D), trail_pts, trail_head}]
var _particles  : Array = []

# Active gravity wells from touch: [Vector2, ...]
var _wells      : Array = []


func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_gen_stars(300)
	_gen_nebulae()

	var t := Label.new()
	t.text = "GALAXY"
	t.add_theme_font_size_override("font_size", 28)
	t.modulate = Color(0.7, 0.85, 1.0, 0.65)
	t.position = Vector2(24, 12)
	add_child(t)

	var s := Label.new()
	s.text = "Touch to create gravity wells · particles orbit your hands"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(0.7, 0.85, 1.0, 0.45)
	s.position = Vector2(24, 48)
	add_child(s)


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.00, 0.00, 0.02, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)


func _gen_stars(n: int) -> void:
	for _i in range(n):
		_stars.append({
			"pos":    Vector2(randf_range(0, vp_size.x), randf_range(0, vp_size.y)),
			"alpha":  randf_range(0.3, 1.0),
			"speed":  randf_range(0.4, 2.2),
			"phase":  randf_range(0.0, TAU),
			"size":   randf_range(0.8, 2.5),
		})


func _gen_nebulae() -> void:
	var nebula_defs : Array = [
		[Vector2(0.20, 0.30), 260.0, Color(0.40, 0.12, 0.80, 0.055)],
		[Vector2(0.75, 0.65), 310.0, Color(0.10, 0.40, 1.00, 0.050)],
		[Vector2(0.55, 0.18), 200.0, Color(0.80, 0.20, 0.60, 0.045)],
		[Vector2(0.30, 0.75), 240.0, Color(0.10, 0.65, 0.90, 0.040)],
	]
	for nd in nebula_defs:
		_nebulae.append({
			"pos":    vp_size * nd[0],
			"radius": nd[1],
			"col":    nd[2],
		})


# ─────────────────────────────────────────────────────────────────────────────

func _draw() -> void:
	# Nebulae (multi-pass soft circles)
	for nb in _nebulae:
		var nc : Color = nb["col"]
		for layer in range(5):
			var f   : float = 1.0 - float(layer) / 5.0
			var col : Color = Color(nc.r, nc.g, nc.b, nc.a * f * 0.7)
			draw_circle(nb["pos"], nb["radius"] * f, col)

	# Stars
	for st in _stars:
		var a : float = clamp(st["alpha"], 0.0, 1.0)
		draw_circle(st["pos"], st["size"], Color(1, 1, 1, a))

	# Gravity well indicators
	for w in _wells:
		var wp : Vector2 = w
		draw_arc(wp, 22.0, 0.0, TAU, 32, Color(1, 0.85, 0.4, 0.30), 1.5)
		draw_arc(wp,  8.0, 0.0, TAU, 16, Color(1, 0.85, 0.4, 0.55), 1.0)


# ─────────────────────────────────────────────────────────────────────────────

func _spawn_particle(well_pos: Vector2) -> void:
	if _particles.size() >= MAX_PARTICLES:
		return

	# Spawn at a random offset from the well
	var angle   : float   = randf_range(0.0, TAU)
	var dist    : float   = randf_range(55.0, 160.0)
	var spawn   : Vector2 = well_pos + Vector2(cos(angle), sin(angle)) * dist

	# Orbital velocity: perpendicular to the radius vector, scaled by distance
	var to_well : Vector2 = well_pos - spawn
	var orbital : Vector2 = to_well.orthogonal().normalized() * sqrt(GRAV_STRENGTH / max(dist, 10.0)) * 0.85

	var hue  : float = randf_range(0.55, 0.85)  # blue-violet-pink spectrum
	var col  : Color = Color.from_hsv(hue + _audio_sm * 0.25, 0.85, 1.0)

	# Trail Line2D
	var trail := Line2D.new()
	trail.width         = 1.6
	trail.default_color = Color(col.r, col.g, col.b, 0.55)
	add_child(trail)
	for _j in range(TRAIL_LEN):
		trail.add_point(spawn)

	_particles.append({
		"pos":         spawn,
		"vel":         orbital,
		"life":        PARTICLE_LIFE * randf_range(0.7, 1.3),
		"max_life":    PARTICLE_LIFE,
		"col":         col,
		"trail":       trail,
		"trail_head":  0,
	})


# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_audio_sm = lerp(_audio_sm, audio_level, delta * 6.0)
	_time    += delta

	# Twinkle stars
	for st in _stars:
		st["alpha"] = 0.55 + sin(_time * st["speed"] + st["phase"]) * 0.45

	# Gather gravity wells from touches
	_wells.clear()
	var interactions := get_parent().get_node_or_null("Interactions")
	if interactions:
		for touch in interactions.get_children():
			var tp : Vector2 = touch.position + touch.pivot_offset
			_wells.append(tp)
			# Spawn particles at each active well
			var rate : int = 2 + int(_audio_sm * 4.0)
			for _i in range(rate):
				_spawn_particle(tp)

	# ── Update particles ───────────────────────────────────────────────
	var dead : Array = []

	for i in _particles.size():
		var p : Dictionary = _particles[i]
		p["life"] -= delta

		if p["life"] <= 0.0:
			dead.append(i)
			(p["trail"] as Node2D).queue_free()
			continue

		var pos : Vector2 = p["pos"]
		var vel : Vector2 = p["vel"]

		# Gravity from all wells
		for w in _wells:
			var wp  : Vector2 = w
			var diff : Vector2 = wp - pos
			var d    : float   = max(diff.length(), MIN_GRAV_DIST)
			vel += diff.normalized() * (GRAV_STRENGTH / (d * d)) * delta

		# Very mild damping to keep orbits stable
		vel *= (1.0 - delta * 0.04)
		pos += vel * delta

		# Wrap at screen edges
		pos.x = fmod(pos.x + vp_size.x, vp_size.x)
		pos.y = fmod(pos.y + vp_size.y, vp_size.y)

		p["pos"] = pos
		p["vel"] = vel

		# Update trail ring buffer
		var th  : int    = p["trail_head"]
		var trl : Line2D = p["trail"] as Line2D
		trl.set_point_position(th, pos)
		p["trail_head"] = (th + 1) % TRAIL_LEN

		# Fade based on life
		var frac : float = p["life"] / p["max_life"]
		var col  : Color = p["col"]
		trl.default_color = Color(col.r, col.g, col.b, frac * 0.65)

		_particles[i] = p

	for i in range(dead.size() - 1, -1, -1):
		_particles.remove_at(dead[i])

	queue_redraw()
