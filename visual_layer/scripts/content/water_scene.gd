extends Node2D

@onready var water_shader_material = ShaderMaterial.new()

func _ready():
	# Simple ColorRect to act as the water surface
	var surface = ColorRect.new()
	surface.name = "WaterSurface"
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	surface.color = Color(0.1, 0.4, 0.8, 0.6)
	add_child(surface)
	
	# Create a basic ripple shader string
	var shader = Shader.new()
	shader.code = """
shader_type canvas_item;

uniform vec2 mouse_pos;
uniform float mouse_pressed;
uniform float time;

void fragment() {
    vec2 uv = SCREEN_UV;
    float dist = distance(uv, mouse_pos);
    float ripple = sin(dist * 50.0 - time * 5.0) * 0.01;
    COLOR = texture(SCREEN_TEXTURE, uv + ripple);
    COLOR.b += 0.1;
}
"""
	# Note: Built-in shaders are tricky via script without assets, 
	# so we'll use a particle-based approach for ripples instead for better MVP compatibility.
	setup_particles()

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
	for i in range(33):
		var angle = deg_to_rad(i * 360.0 / 32.0)
		r.add_point(Vector2(cos(angle), sin(angle)))
	
	r.closed = true
	r.width = 2.0
	r.default_color = Color(1, 1, 1, 0.5)
	r.position = pos
	add_child(r)
	
	var tween = create_tween()
	tween.tween_property(r, "scale", Vector2(10, 10), 1.0)
	tween.parallel().tween_property(r, "modulate:a", 0.0, 1.0)
	tween.tween_callback(r.queue_free)
