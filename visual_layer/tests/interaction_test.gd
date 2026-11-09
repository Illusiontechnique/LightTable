extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition


func _run() -> void:
	var app = load("res://scenes/main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var receiver = app.get_node("NetworkReceiver")
	var interactions = app.get_node("Interactions")
	var packet := {
		"type": "interaction", "id": 99, "x": 0.3, "y": 0.4,
		"state": "enter", "tracker": "MediaPipe Hands"
	}
	receiver._parse_json_packet(JSON.stringify(packet).to_utf8_buffer())
	app._on_interaction_received(app.SIMULATION_ID, Vector2(0.3, 0.4), "move")
	if not _check(interactions.get_child_count() == 2, "Camera ID 99 must not collide with simulation"):
		return
	var camera = interactions.get_node("99")
	var mouse = interactions.get_node(str(app.SIMULATION_ID))
	if not _check(camera.position == mouse.position, "Mouse and camera must use the same coordinates"):
		return
	packet["state"] = "exit"
	receiver._parse_json_packet(JSON.stringify(packet).to_utf8_buffer())
	packet["state"] = "enter"
	receiver._parse_json_packet(JSON.stringify(packet).to_utf8_buffer())
	if not _check(interactions.has_node("99"), "Immediate re-entry must create a usable node"):
		return
	app._interaction_seen[99] = Time.get_ticks_msec() * 0.001 - 2.0
	app._process(0.016)
	if not _check(not interactions.has_node("99"), "Stale camera input must expire"):
		return

	if not _check(app.load_content_scene("res://scripts/content/water_scene.gd"), "Water failed to load"):
		return
	var water = app.active_scene
	receiver._parse_json_packet(JSON.stringify({
		"type": "frame_motion", "amount": 0.2,
		"points": [{"x": 0.25, "y": 0.5}, {"x": 0.75, "y": 0.5}]
	}).to_utf8_buffer())
	if not _check(water.active_ripples.size() == 2, "Frame-motion points must create water ripples"):
		return
	app._on_interaction_received(1, Vector2(0.5, 0.5), "move")
	water._process(0.016)
	if not _check(water.active_ripples.size() == 2, "Hand or mouse points must not affect water"):
		return
	receiver._parse_json_packet(JSON.stringify({
		"type": "frame_motion", "amount": 0.1, "points": [{"x": 2, "y": 0.5}]
	}).to_utf8_buffer())
	if not _check(water.active_ripples.size() == 2, "Invalid frame-motion coordinates must be rejected"):
		return
	if not _check(app.load_content_scene("res://scripts/content/spinner_scene.gd"), "Spinner failed to load"):
		return
	app._process(0.016)
	if not _check(is_equal_approx(app.active_scene.motion_amount, 0.2), "Spinner must receive motion amount"):
		return
	print("Interaction and frame-motion integration checks passed")
	app.queue_free()
	await process_frame
	quit(0)
