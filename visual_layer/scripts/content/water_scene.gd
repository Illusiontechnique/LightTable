extends Node2D

@onready var water_surface := ColorRect.new()
@onready var water_material := ShaderMaterial.new()
var ripple_center := Vector2(0.5, 0.5)
var audio_level := 0.0

func _ready():
	var backdrop = ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 1.0)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	move_child(backdrop, 0)

	water_surface.name = "WaterSurface"
	water_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	water_material.shader = load("res://assets/shaders/water.gdshader")
	water_surface.material = water_material
	add_child(water_surface)

	var title = Label.new()
	title.text = "WATER / RIPPLE"
	title.add_theme_font_size_override("font_size", 34)
	title.modulate = Color(0.85, 1.0, 1.0)
	title.position = Vector2(24, 18)
	add_child(title)

	var hint = Label.new()
	hint.text = "Move the mouse or hands over the canvas"
	hint.add_theme_font_size_override("font_size", 16)
	hint.modulate = Color(0.8, 0.9, 1.0, 0.85)
	hint.position = Vector2(24, 62)
	add_child(hint)

	var energy = Label.new()
	energy.name = "EnergyLabel"
	energy.text = "Audio energy drives ripple intensity"
	energy.add_theme_font_size_override("font_size", 15)
	energy.modulate = Color(1.0, 0.9, 0.55, 0.9)
	energy.position = Vector2(24, 92)
	add_child(energy)

func set_audio_level(level: float):
	audio_level = clamp(level, 0.0, 1.0)

func setup_particles():
	# Fallback: Instead of complex shaders, we'll spawn "Ripple" sprites that fade out
	pass

func _process(_delta):
	var interactions = get_parent().get_node("Interactions")
	if not interactions: return

	water_material.set_shader_parameter("ripple_center", ripple_center)
	water_material.set_shader_parameter("ripple_strength", 0.25 + audio_level * 0.55)
	
	for touch in interactions.get_children():
		ripple_center = touch.position / get_viewport_rect().size
		# Spawn small expanding circles to simulate ripples
		create_ripple(touch.position)

func create_ripple(pos):
	var r = Line2D.new()
	r.points = PackedVector2Array()
	# Create a simple circle
	for i in range(33):
		var angle = deg_to_rad(i * 360.0 / 32.0)
		r.add_point(Vector2(cos(angle), sin(angle)) * 10.0)
	
	r.closed = true
	r.width = 3.0
	r.default_color = Color(1, 1, 1, 0.8) # Bright white for visibility on blue
	r.position = pos
	add_child(r)
	
	var tween = create_tween()
	# Fast expand and fade out
	tween.tween_property(r, "scale", Vector2(15, 15), 0.8).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(r, "modulate:a", 0.0, 0.8)
	tween.tween_callback(r.queue_free)
