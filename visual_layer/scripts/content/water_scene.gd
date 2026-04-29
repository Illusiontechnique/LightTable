extends Node2D

@onready var water_shader_material = ShaderMaterial.new()

func _ready():
	# Water Surface with customized Shader
	var surface = ColorRect.new()
	surface.name = "WaterSurface"
	surface.size = get_viewport_rect().size
	
	var mat = ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/water.gdshader")
	surface.material = mat
	add_child(surface)
	
	# Add some "Bottom" detail for the distortion to act on
	var background = ColorRect.new()
	background.size = surface.size
	background.color = Color(0.0, 0.2, 0.4) # Darker deep water
	add_child(background)
	move_child(background, 0)

func setup_particles():
	# Fallback: Instead of complex shaders, we'll spawn "Ripple" sprites that fade out
	pass

func _process(_delta):
	var interactions = get_parent().get_node("Interactions")
	if not interactions: return
	
	for touch in interactions.get_children():
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
