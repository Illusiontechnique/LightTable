extends Node
## Fixed-step, GPU ping-pong wave simulation. Motion frames are projector-aligned.

const MOTION_SIZE := Vector2i(160, 120)
const MOTION_BYTES := 19200
const MOTION_PORT := 4242
const STEP := 1.0 / 60.0
const STALE_SECONDS := 0.3
const SIM_SHADER := preload("res://shaders/water_simulation.gdshader")

@export_enum("128:128", "256:256", "512:512") var simulation_resolution: int = 256
@export_range(0.01, 0.49) var propagation := 0.22
@export_range(0.9, 0.9999) var damping := 0.992
@export_range(0.0, 0.95) var motion_threshold := 0.08
@export_range(0.0, 10.0) var motion_sensitivity := 2.0
@export_range(0.0, 0.5) var impulse_strength := 0.04
@export_range(0.01, 1.0) var max_disturbance := 0.35
@export var motion_edges := false

var motion_image: Image
var motion_texture: ImageTexture
var _zero_texture: ImageTexture
var peer: PacketPeerUDP
var buffers: Array[SubViewport] = []
var materials: Array[ShaderMaterial] = []
var current_index := 0
var accumulator := 0.0
var last_packet_time := -100.0
var packet_count := 0
var invalid_packet_count := 0
var packet_rate := 0.0
var _rate_time := 0.0
var _rate_count := 0
var _pending_motion := false
var test_pattern := 0
var test_time := 0.0
var _single_pending := false
var bind_error := OK
var _warmup_frames := 0


func _ready() -> void:
	motion_image = Image.create(MOTION_SIZE.x, MOTION_SIZE.y, false, Image.FORMAT_L8)
	motion_image.fill(Color.BLACK)
	motion_texture = ImageTexture.create_from_image(motion_image)
	var zero_image := Image.create(1, 1, false, Image.FORMAT_L8)
	zero_image.fill(Color.BLACK)
	_zero_texture = ImageTexture.create_from_image(zero_image)
	_create_buffers()
	peer = PacketPeerUDP.new()
	bind_error = peer.bind(MOTION_PORT, "*", 1048576)
	if bind_error != OK:
		push_error("Water motion receiver could not bind UDP port %d (error %d)" % [MOTION_PORT, bind_error])


func _exit_tree() -> void:
	if peer:
		peer.close()


func _create_buffers() -> void:
	for buffer in buffers:
		buffer.queue_free()
	buffers.clear()
	materials.clear()
	current_index = 0
	accumulator = 0.0
	_warmup_frames = 2
	for i in 2:
		var buffer := SubViewport.new()
		buffer.name = "WaveBuffer%d" % i
		buffer.size = Vector2i(simulation_resolution, simulation_resolution)
		buffer.use_hdr_2d = true
		buffer.transparent_bg = true
		buffer.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		buffer.render_target_update_mode = SubViewport.UPDATE_ONCE
		add_child(buffer)
		var rect := ColorRect.new()
		rect.size = Vector2(simulation_resolution, simulation_resolution)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var material := ShaderMaterial.new()
		material.shader = SIM_SHADER
		material.set_shader_parameter("state_texture", _zero_texture)
		material.set_shader_parameter("motion_texture", motion_texture)
		rect.material = material
		buffer.add_child(rect)
		buffers.append(buffer)
		materials.append(material)


func set_resolution(value: int) -> void:
	if value not in [128, 256, 512]:
		push_warning("Unsupported water simulation resolution: %d" % value)
		return
	if simulation_resolution != value:
		simulation_resolution = value
		_create_buffers()


func get_height_texture() -> Texture2D:
	return buffers[current_index].get_texture()


func set_test_pattern(pattern: int) -> void:
	test_pattern = clampi(pattern, 0, 5)
	test_time = 0.0
	_single_pending = test_pattern == 1
	_pending_motion = false


func _receive_packets(now: float) -> void:
	if bind_error != OK:
		return
	var latest := PackedByteArray()
	var count := 0
	while peer.get_available_packet_count() > 0 and count < 256:
		var data := peer.get_packet()
		count += 1
		if data.size() == MOTION_BYTES:
			latest = data
			packet_count += 1
			_rate_count += 1
		else:
			invalid_packet_count += 1
	if not latest.is_empty():
		motion_image.set_data(MOTION_SIZE.x, MOTION_SIZE.y, false, Image.FORMAT_L8, latest)
		motion_texture.update(motion_image)
		last_packet_time = now
		_pending_motion = true


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() * 0.001
	_receive_packets(now)
	_rate_time += delta
	if _rate_time >= 1.0:
		packet_rate = _rate_count / _rate_time
		_rate_time = 0.0
		_rate_count = 0
	test_time += delta
	if _warmup_frames > 0:
		_warmup_frames -= 1
		return
	accumulator = minf(accumulator + delta, STEP * 2.0)
	if accumulator < STEP:
		return
	# One viewport update per rendered frame avoids sampling an unwritten buffer.
	accumulator -= STEP
	var next := 1 - current_index
	var material := materials[next]
	material.set_shader_parameter("state_texture", buffers[current_index].get_texture())
	material.set_shader_parameter("motion_texture", motion_texture)
	material.set_shader_parameter("texel_size", Vector2.ONE / float(simulation_resolution))
	material.set_shader_parameter("propagation", clampf(propagation, 0.01, 0.49))
	material.set_shader_parameter("damping", clampf(damping, 0.9, 0.9999))
	material.set_shader_parameter("motion_threshold", motion_threshold)
	material.set_shader_parameter("motion_sensitivity", motion_sensitivity)
	material.set_shader_parameter("motion_edges", motion_edges)
	material.set_shader_parameter("impulse_strength", impulse_strength)
	material.set_shader_parameter("max_disturbance", max_disturbance)
	material.set_shader_parameter("motion_enabled", 1.0 if test_pattern == 0 and _pending_motion and now - last_packet_time < STALE_SECONDS else 0.0)
	material.set_shader_parameter("test_pattern", test_pattern)
	material.set_shader_parameter("test_time", test_time)
	var test_impulse := 0.0
	if test_pattern == 1 and _single_pending:
		test_impulse = 0.22
		_single_pending = false
	elif test_pattern >= 2 and test_pattern <= 4:
		test_impulse = 0.025
	material.set_shader_parameter("test_impulse", test_impulse)
	_pending_motion = false
	buffers[next].render_target_update_mode = SubViewport.UPDATE_ONCE
	current_index = next
