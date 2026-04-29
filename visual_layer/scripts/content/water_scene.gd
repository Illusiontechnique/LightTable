extends Node2D

@onready var water_shader_material = ShaderMaterial.new()

func _ready():
	# Simple ColorRect to act as the water surface
	var surface = ColorRect.new()
	surface.name = "WaterSurface"
	surface.size = get_viewport_rect().size
	surface.color = Color(0.1, 0.4, 0.8, 0.4) # Semi-transparent blue
	add_child(surface)
	
	setup_particles()

func setup_particles():

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
