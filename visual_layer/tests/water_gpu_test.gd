extends SceneTree

const SIMULATION := preload("res://scripts/water_simulation.gd")


func _init() -> void:
	call_deferred("_run")


func _measure(image: Image) -> Dictionary:
	var total := 0.0
	var maximum := 0.0
	var outer := 0.0
	var middle := Vector2(image.get_width(), image.get_height()) * 0.5
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var value := absf(image.get_pixel(x, y).r)
			if not is_finite(value):
				return {"finite": false}
			total += value
			maximum = maxf(maximum, value)
			if Vector2(x, y).distance_to(middle) > 20.0:
				outer += value
	return {"finite": true, "total": total, "max": maximum, "outer": outer}

func _peak_near(image: Image, center: Vector2, radius: int = 12) -> float:
	var maximum := 0.0
	var pixel := center * Vector2(image.get_width(), image.get_height())
	for y in range(maxi(0, int(pixel.y) - radius), mini(image.get_height(), int(pixel.y) + radius)):
		for x in range(maxi(0, int(pixel.x) - radius), mini(image.get_width(), int(pixel.x) + radius)):
			maximum = maxf(maximum, absf(image.get_pixel(x, y).r))
	return maximum

func _reset(simulation: Node) -> void:
	simulation.set_test_pattern(0)
	simulation.set_resolution(256)
	simulation.set_resolution(128)
	for i in 6:
		await process_frame


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("GPU water test requires a real rendering display driver, not --headless")
		quit(2)
		return
	var simulation = SIMULATION.new()
	simulation.simulation_resolution = 128
	root.add_child(simulation)
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var initial := _measure(simulation.get_height_texture().get_image())
	if initial["max"] > 0.00001:
		push_error("Simulation must initialize to calm water")
		quit(1)
		return
	simulation.set_test_pattern(1)
	var samples := {}
	for i in range(3600):
		await process_frame
		if i in [20, 100, 3599]:
			await RenderingServer.frame_post_draw
			samples[i] = _measure(simulation.get_height_texture().get_image())
			print("water_gpu_step ", i, ": ", samples[i])
	for i in samples:
		if not samples[i].get("finite", false):
			push_error("Non-finite simulation state")
			quit(1)
			return
	if samples[20]["max"] < 0.00001 or samples[100]["outer"] < 0.00001:
		push_error("Impulse did not propagate through the GPU heightfield")
		quit(1)
		return
	if samples[3599]["max"] >= samples[20]["max"]:
		push_error("Heightfield did not decay over time")
		quit(1)
		return
	await _reset(simulation)
	simulation.set_test_pattern(3)
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var multiple := simulation.get_height_texture().get_image()
	var a := _peak_near(multiple, Vector2(0.28, 0.36))
	var b := _peak_near(multiple, Vector2(0.72, 0.64))
	print("multiple GPU peaks: ", a, ", ", b)
	if minf(a, b) < 0.001:
		push_error("Multiple test disturbances did not reach both locations")
		quit(1)
		return
	var multi_peak := maxf(a, b)
	simulation.set_test_pattern(5)
	for i in 600:
		await process_frame
	await RenderingServer.frame_post_draw
	if _measure(simulation.get_height_texture().get_image())["max"] >= multi_peak:
		push_error("No-motion test did not decay")
		quit(1)
		return
	await _reset(simulation)
	var image := Image.create(160, 120, false, Image.FORMAT_L8)
	image.fill(Color.BLACK)
	image.fill_rect(Rect2i(25, 30, 12, 12), Color.WHITE)
	image.fill_rect(Rect2i(105, 75, 12, 12), Color.WHITE)
	var sender := PacketPeerUDP.new()
	sender.set_dest_address("127.0.0.1", 4242)
	sender.put_packet(image.get_data())
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	var network_image := simulation.get_height_texture().get_image()
	a = _peak_near(network_image, Vector2(31.0 / 160.0, 36.0 / 120.0))
	b = _peak_near(network_image, Vector2(111.0 / 160.0, 81.0 / 120.0))
	print("UDP GPU peaks: ", a, ", ", b)
	sender.close()
	if minf(a, b) < 0.001:
		push_error("Binary UDP motion did not disturb both GPU locations")
		quit(1)
		return
	await _reset(simulation)
	await RenderingServer.frame_post_draw
	var reset_image := _measure(simulation.get_height_texture().get_image())
	if reset_image["max"] > 0.00001:
		push_error("Resizing must reset the heightfield even with a nonzero motion texture")
		quit(1)
		return
	for pattern in [2, 4]:
		simulation.set_test_pattern(pattern)
		for i in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		if _measure(simulation.get_height_texture().get_image())["max"] < 0.001:
			push_error("Moving point or stroke did not disturb the GPU heightfield")
			quit(1)
			return
	for resolution in [256, 512]:
		simulation.set_test_pattern(0)
		simulation.set_resolution(resolution)
		for i in 6:
			await process_frame
		simulation.set_test_pattern(1)
		for i in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		var grid_image := simulation.get_height_texture().get_image()
		if grid_image.get_width() != resolution or _peak_near(grid_image, Vector2(0.5, 0.5)) < 0.001:
			push_error("Water grid %d did not propagate an impulse" % resolution)
			quit(1)
			return
	print("GPU wave propagation and decay checks passed")
	simulation.queue_free()
	await process_frame
	var scene := Node2D.new()
	scene.set_script(load("res://scripts/content/water_scene.gd"))
	root.add_child(scene)
	scene.simulation.set_test_pattern(3)
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var surface := root.get_texture().get_image()
	var sample := surface.get_pixel(surface.get_width() / 2, surface.get_height() / 2)
	if not is_finite(sample.r) or sample.g < 0.05:
		push_error("Water presentation did not render a visible finite color")
		quit(1)
		return
	var screenshot := OS.get_environment("LIGHTTABLE_WATER_TEST_SCREENSHOT")
	if not screenshot.is_empty():
		surface.save_png(screenshot)
	print("GPU water presentation rendered: ", sample)
	scene.queue_free()
	quit(0)
