extends Node2D

const SIMULATION := preload("res://scripts/water_simulation.gd")
const SURFACE_SHADER := preload("res://shaders/water_surface.gdshader")
const DEBUG_SHADER := preload("res://shaders/water_height_debug.gdshader")
const TEST_NAMES := ["Live camera", "Single impulse", "Moving point", "Multiple points", "Continuous stroke", "No-motion decay"]

@export var deep_color := Color(0.025, 0.22, 0.30)
@export var light_color := Color(0.18, 0.58, 0.64)
@export var background_texture: Texture2D
@export_range(0.0, 0.1) var refraction_strength := 0.025

var simulation: Node
var water_surface: ColorRect
var water_material: ShaderMaterial
var debug_panel: PanelContainer
var debug_status: Label
var height_preview: TextureRect
var audio_level := 0.0
var wave_intensity := 3.5
var ambient_strength := 0.018


func _ready() -> void:
	simulation = SIMULATION.new()
	simulation.name = "WaterSimulation"
	add_child(simulation)
	water_surface = ColorRect.new()
	water_surface.name = "WaterSurface"
	water_surface.size = get_viewport_rect().size
	water_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	water_material = ShaderMaterial.new()
	water_material.shader = SURFACE_SHADER
	water_material.set_shader_parameter("deep_color", deep_color)
	water_material.set_shader_parameter("light_color", light_color)
	water_material.set_shader_parameter("use_background", background_texture != null)
	water_material.set_shader_parameter("background_texture", background_texture)
	water_material.set_shader_parameter("refraction_strength", refraction_strength)
	water_surface.material = water_material
	add_child(water_surface)
	get_viewport().size_changed.connect(_resize_surface)
	_create_debug_panel()


func _resize_surface() -> void:
	water_surface.size = get_viewport_rect().size


func set_audio_level(level: float) -> void:
	audio_level = clampf(level, 0.0, 1.0)


func _process(_delta: float) -> void:
	water_material.set_shader_parameter("height_texture", simulation.get_height_texture())
	water_material.set_shader_parameter("texel_size", Vector2.ONE / float(simulation.simulation_resolution))
	water_material.set_shader_parameter("wave_intensity", wave_intensity)
	water_material.set_shader_parameter("ambient_strength", ambient_strength + audio_level * 0.006)
	if debug_panel.visible:
		height_preview.texture = simulation.get_height_texture()
		debug_status.text = "Mode: %s   UDP: %.1f packets/s (%d invalid)\nGrid: %d x %d   FPS: %d   %s" % [
			TEST_NAMES[simulation.test_pattern], simulation.packet_rate, simulation.invalid_packet_count,
			simulation.simulation_resolution, simulation.simulation_resolution, Engine.get_frames_per_second(),
			"Listening on 4242" if simulation.bind_error == OK else "UDP bind failed",
		]


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F3:
		debug_panel.visible = not debug_panel.visible
		get_viewport().set_input_as_handled()
	elif event.keycode >= KEY_0 and event.keycode <= KEY_5 and debug_panel.visible:
		simulation.set_test_pattern(event.keycode - KEY_0)
		get_viewport().set_input_as_handled()


func _create_debug_panel() -> void:
	debug_panel = PanelContainer.new()
	debug_panel.name = "WaterDebug"
	debug_panel.position = Vector2(20, 20)
	debug_panel.custom_minimum_size = Vector2(490, 0)
	debug_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.04, 0.07, 0.93)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	debug_panel.add_theme_stylebox_override("panel", style)
	add_child(debug_panel)
	var layout := VBoxContainer.new()
	debug_panel.add_child(layout)
	var title := Label.new()
	title.text = "WATER DEBUG  |  F3: toggle  |  0-5: test mode"
	layout.add_child(title)
	debug_status = Label.new()
	layout.add_child(debug_status)
	var previews := HBoxContainer.new()
	layout.add_child(previews)
	_add_preview(previews, "Motion intensity", simulation.motion_texture, null)
	height_preview = _add_preview(previews, "Heightfield (grey = calm)", simulation.get_height_texture(), DEBUG_SHADER)
	var resolution_row := HBoxContainer.new()
	layout.add_child(resolution_row)
	var resolution_label := Label.new()
	resolution_label.text = "Simulation grid"
	resolution_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resolution_row.add_child(resolution_label)
	var selector := OptionButton.new()
	for size in [128, 256, 512]:
		selector.add_item(str(size), size)
	selector.select(1)
	selector.item_selected.connect(func(index: int): simulation.set_resolution(selector.get_item_id(index)))
	resolution_row.add_child(selector)
	var colors := HBoxContainer.new()
	layout.add_child(colors)
	for entry in [["Deep color", deep_color, "deep_color"], ["Light color", light_color, "light_color"]]:
		var color_label := Label.new()
		color_label.text = entry[0]
		colors.add_child(color_label)
		var picker := ColorPickerButton.new()
		picker.color = entry[1]
		picker.custom_minimum_size = Vector2(70, 28)
		picker.color_changed.connect(_set_water_color.bind(entry[2]))
		colors.add_child(picker)
	_add_slider(layout, "Motion sensitivity", 0.0, 10.0, 0.1, simulation.motion_sensitivity, func(v): simulation.motion_sensitivity = v)
	_add_slider(layout, "Impulse strength", 0.0, 0.2, 0.002, simulation.impulse_strength, func(v): simulation.impulse_strength = v)
	_add_slider(layout, "Motion threshold", 0.0, 0.95, 0.01, simulation.motion_threshold, func(v): simulation.motion_threshold = v)
	_add_slider(layout, "Propagation", 0.01, 0.49, 0.01, simulation.propagation, func(v): simulation.propagation = v)
	_add_slider(layout, "Damping", 0.9, 0.999, 0.001, simulation.damping, func(v): simulation.damping = v)
	_add_slider(layout, "Max disturbance", 0.01, 1.0, 0.01, simulation.max_disturbance, func(v): simulation.max_disturbance = v)
	_add_slider(layout, "Wave intensity", 0.0, 10.0, 0.1, wave_intensity, func(v): wave_intensity = v)
	_add_slider(layout, "Ambient strength", 0.0, 0.1, 0.002, ambient_strength, func(v): ambient_strength = v)


func _add_preview(parent: Control, title: String, texture: Texture2D, shader: Shader) -> TextureRect:
	var column := VBoxContainer.new()
	parent.add_child(column)
	var label := Label.new()
	label.text = title
	column.add_child(label)
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(220, 130)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = texture
	if shader:
		var material := ShaderMaterial.new()
		material.shader = shader
		preview.material = material
	column.add_child(preview)
	return preview


func _add_slider(parent: Control, title: String, low: float, high: float, step: float, value: float, callback: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 150
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(callback)
	row.add_child(slider)


func _set_water_color(color: Color, parameter: String) -> void:
	water_material.set_shader_parameter(parameter, color)
