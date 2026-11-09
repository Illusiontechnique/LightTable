extends Node2D

const SIMULATION := preload("res://scripts/water_simulation.gd")
const EFFECT_SHADER := preload("res://shaders/edge_rainbow.gdshader")

var simulation: Node
var effect: ColorRect
var effect_material: ShaderMaterial
var audio_level := 0.0
var audio_smooth := 0.0


func _ready() -> void:
	simulation = SIMULATION.new()
	simulation.name = "EdgeEchoSimulation"
	simulation.motion_edges = true
	simulation.propagation = 0.28
	simulation.damping = 0.987
	simulation.impulse_strength = 0.08
	add_child(simulation)
	effect = ColorRect.new()
	effect.size = get_viewport_rect().size
	effect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	effect_material = ShaderMaterial.new()
	effect_material.shader = EFFECT_SHADER
	effect_material.set_shader_parameter("motion_texture", simulation.motion_texture)
	effect.material = effect_material
	add_child(effect)
	get_viewport().size_changed.connect(_resize)


func _resize() -> void:
	effect.size = get_viewport_rect().size


func uses_point_cursors() -> bool:
	return false


func set_audio_level(level: float) -> void:
	audio_level = clampf(level, 0.0, 1.0)


func _process(delta: float) -> void:
	audio_smooth = lerpf(audio_smooth, audio_level, 1.0 - exp(-delta * 5.0))
	effect_material.set_shader_parameter("height_texture", simulation.get_height_texture())
	effect_material.set_shader_parameter("audio_level", audio_smooth)
	var now := Time.get_ticks_msec() * 0.001
	effect_material.set_shader_parameter(
		"motion_visible", 1.0 if now - simulation.last_packet_time < simulation.STALE_SECONDS else 0.0
	)
