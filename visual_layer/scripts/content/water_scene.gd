extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  Water Scene
#  Drives the stylised water shader with:
#    • Up to 8 simultaneous touch ripples (velocity-aware spawning)
#    • Audio-reactive wave energy
#    • Correct aspect-ratio compensation passed to the shader
# ─────────────────────────────────────────────────────────────────────────────

const MAX_RIPPLES     := 8
const RIPPLE_LIFETIME := 3.2    # seconds before a ripple fades out completely
const MOVE_THRESHOLD  := 14.0   # pixels moved before a travel ripple is spawned

var water_surface  : ColorRect
var water_material : ShaderMaterial

# Active ripple ring-buffer.  Each entry: { pos: Vector2, age: float, strength: float }
var active_ripples : Array = []

# touch ID → last known pixel position (for velocity-based ripple spawning)
var prev_positions : Dictionary = {}

# Audio
var audio_level   : float = 0.0
var _audio_smooth : float = 0.0

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	var vp_size := get_viewport_rect().size

	# Dark ocean backdrop — explicit size since parent is Node2D (anchors don't apply)
	var bg := ColorRect.new()
	bg.color = Color(0.01, 0.03, 0.10)
	bg.position = Vector2.ZERO
	bg.size = vp_size
	add_child(bg)
	move_child(bg, 0)

	# Full-screen water shader surface
	water_surface = ColorRect.new()
	water_surface.name = "WaterSurface"
	water_surface.position = Vector2.ZERO
	water_surface.size = vp_size
	water_material = ShaderMaterial.new()
	water_material.shader = load("res://assets/shaders/water.gdshader")
	water_surface.material = water_material
	add_child(water_surface)

	# Re-size on window resize
	get_viewport().size_changed.connect(_on_viewport_size_changed)

	# Prime the aspect ratio before the first frame
	_update_aspect()

	# UI labels
	_label("WATER",                                        36, Color(0.80, 1.00, 1.00),       Vector2(24, 18))
	_label("Touch the surface · audio drives wave energy", 15, Color(0.70, 0.90, 1.00, 0.80), Vector2(24, 64))


func _label(text: String, size: int, col: Color, pos: Vector2) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.modulate = col
	l.position = pos
	add_child(l)


func _update_aspect() -> void:
	var vp := get_viewport_rect().size
	if vp.y > 0.0:
		water_material.set_shader_parameter("aspect_ratio", vp.x / vp.y)


func _on_viewport_size_changed() -> void:
	var vp := get_viewport_rect().size
	water_surface.size = vp
	# Resize bg too (first child)
	if get_child_count() > 0 and get_child(0) is ColorRect:
		get_child(0).size = vp

# ─────────────────────────────────────────────────────────────────────────────

func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func spawn_ripple(uv_pos: Vector2, strength: float) -> void:
	if active_ripples.size() >= MAX_RIPPLES:
		active_ripples.pop_front()   # drop oldest to make room
	active_ripples.append({
		"pos":      uv_pos,
		"age":      0.0,
		"strength": clamp(strength, 0.1, 2.0),
	})

# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	var vp := get_viewport_rect().size

	# ── Aspect ratio (update each frame in case of resize) ─────────────
	if vp.y > 0.0:
		water_material.set_shader_parameter("aspect_ratio", vp.x / vp.y)

	# ── Audio smoothing (low-pass) ──────────────────────────────────────
	_audio_smooth = lerp(_audio_smooth, audio_level, delta * 6.0)
	water_material.set_shader_parameter("audio_level", _audio_smooth)

	# ── Age ripples and expire old ones ────────────────────────────────
	for r in active_ripples:
		r["age"] += delta
	active_ripples = active_ripples.filter(func(r): return r["age"] < RIPPLE_LIFETIME)

	# ── Build uniform array (always 8 elements; inactive slots use age=-1) ──
	var arr : Array = []
	for r in active_ripples:
		arr.append(Vector4(r["pos"].x, r["pos"].y, r["age"], r["strength"]))
	while arr.size() < MAX_RIPPLES:
		arr.append(Vector4(0.0, 0.0, -1.0, 0.0))
	water_material.set_shader_parameter("ripples",      arr)
	water_material.set_shader_parameter("ripple_count", active_ripples.size())

	# ── Touch interactions ──────────────────────────────────────────────
	var interactions := get_parent().get_node_or_null("Interactions")
	if not interactions:
		return

	var current : Dictionary = {}

	for touch in interactions.get_children():
		var id  : int     = touch.get_instance_id()
		# indicator.position = screen_pos - pivot_offset, so add pivot to get actual centre
		var screen_pos : Vector2 = touch.position + touch.pivot_offset
		var uv         : Vector2 = clamp(screen_pos / vp, Vector2(0.01, 0.01), Vector2(0.99, 0.99))
		current[id] = true

		if not prev_positions.has(id):
			# Finger just landed — strong initial splash
			spawn_ripple(uv, 1.3 + _audio_smooth * 0.6)
		else:
			var moved : float = screen_pos.distance_to(prev_positions[id])
			if moved > MOVE_THRESHOLD:
				# Moving finger — lighter trail ripples, strength from speed + audio
				spawn_ripple(uv, 0.45 + moved / 100.0 + _audio_smooth * 0.3)

		prev_positions[id] = screen_pos

	# Clean up IDs for fingers that have lifted
	var to_remove : Array = []
	for id in prev_positions:
		if not current.has(id):
			to_remove.append(id)
	for id in to_remove:
		prev_positions.erase(id)
