extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition


func _press_key(app: Node, key: Key, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	event.echo = echo
	app._input(event)


func _run() -> void:
	var app = load("res://scenes/main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	if not _check(not app.shortcuts_panel.visible, "Shortcut list must start hidden"):
		return
	_press_key(app, KEY_SPACE)
	if not _check(app.shortcuts_panel.visible, "Space must show shortcuts"):
		return
	_press_key(app, KEY_SPACE, true)
	if not _check(app.shortcuts_panel.visible, "Key repeat must not toggle shortcuts"):
		return
	_press_key(app, KEY_SPACE)
	if not _check(not app.shortcuts_panel.visible, "Space must hide shortcuts"):
		return
	var skeleton_visible: bool = app.hand_skeleton_overlay.show_skeleton
	_press_key(app, KEY_Y)
	if not _check(app.hand_skeleton_overlay.show_skeleton != skeleton_visible, "Y must toggle skeleton"):
		return
	_press_key(app, KEY_Y)
	if not _check(app.hand_skeleton_overlay.show_skeleton == skeleton_visible, "Y must toggle skeleton back"):
		return
	var pointers_visible: bool = app.cursor_draw_layer.show_cursors
	_press_key(app, KEY_T)
	if not _check(app.cursor_draw_layer.show_cursors != pointers_visible, "T must toggle pointers"):
		return
	_press_key(app, KEY_T)
	var receiver = app.get_node("NetworkReceiver")
	var interactions = app.get_node("Interactions")
	receiver._parse_json_packet(JSON.stringify({
		"type": "interaction", "id": 1.5, "x": 0.3, "y": 0.4
	}).to_utf8_buffer())
	if not _check(interactions.get_child_count() == 0, "Fractional interaction IDs must be rejected"):
		return
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
	app._on_interaction_received(app.SIMULATION_ID, Vector2.ZERO, "exit")
	if not _check(app.load_content_scene("res://scripts/content/menu_scene.gd"), "Menu failed to load"):
		return
	var menu = app.active_scene
	var menu_pos: Vector2 = menu._card_rects[0].get_center() / app.get_viewport_rect().size
	app._on_interaction_received(app.SIMULATION_ID, menu_pos, "move")
	menu._process(0.1)
	var mouse_hold: float = menu._card_holds[0]
	app._on_interaction_received(app.SIMULATION_ID, Vector2.ZERO, "exit")
	menu._card_holds[0] = 0.0
	packet["x"] = menu_pos.x
	packet["y"] = menu_pos.y
	receiver._parse_json_packet(JSON.stringify(packet).to_utf8_buffer())
	menu._process(0.1)
	if not _check(mouse_hold > 0.0 and is_equal_approx(menu._card_holds[0], mouse_hold),
			"Camera and mouse must activate the same menu card"):
		return
	menu._card_holds[0] = 0.0
	menu._process(2.19)
	if not _check(not menu._nav_lock, "Menu must not select before 2.2 seconds"):
		return
	menu._process(0.02)
	if not _check(menu._nav_lock, "Menu must select after 2.2 seconds"):
		return

	if not _check(app.load_content_scene("res://scripts/content/water_scene.gd"), "Water failed to load"):
		return
	var water = app.active_scene
	if not _check(water.simulation.bind_error == OK, "Water binary motion port must bind"):
		return
	_press_key(water, KEY_F3)
	if not _check(water.debug_panel.visible, "F3 must show water debug controls"):
		return
	_press_key(water, KEY_3)
	if not _check(water.simulation.test_pattern == 3, "Key 3 must select multiple-point test"):
		return
	_press_key(water, KEY_0)
	if not _check(water.simulation.test_pattern == 0, "Key 0 must restore live motion"):
		return
	var sender := PacketPeerUDP.new()
	sender.set_dest_address("127.0.0.1", 4242)
	var frame := PackedByteArray()
	frame.resize(19200)
	frame.fill(40)
	sender.put_packet(frame)
	frame.fill(90)
	sender.put_packet(frame)
	sender.put_packet(PackedByteArray([1, 2, 3]))
	await create_timer(0.1).timeout
	water.simulation._receive_packets(Time.get_ticks_msec() * 0.001)
	if not _check(water.simulation.packet_count >= 2 and water.simulation.invalid_packet_count >= 1,
			"Binary motion receiver must accept exact frames and reject invalid packets"):
		return
	if not _check(water.simulation.motion_image.get_data()[0] == 90, "Receiver must retain the latest valid frame"):
		return
	receiver._parse_json_packet(JSON.stringify({
		"type": "frame_motion", "amount": 0.2,
		"points": [{"x": 0.25, "y": 0.5}, {"x": 0.75, "y": 0.5}]
	}).to_utf8_buffer())
	app._on_interaction_received(1, Vector2(0.5, 0.5), "move")
	if not _check(not water.has_method("on_frame_motion"), "Water must not use hand or JSON point ripples"):
		return
	water.simulation.set_test_pattern(3)
	if not _check(water.simulation.test_pattern == 3, "Water test patterns must be selectable"):
		return
	sender.close()
	if not _check(app.load_content_scene("res://scripts/content/water_scene.gd"), "Water must reload"):
		return
	if not _check(app.active_scene.simulation.bind_error == OK, "Water reload must release and rebind UDP"):
		return
	if not _check(app.load_content_scene("res://scripts/content/spinner_scene.gd"), "Spinner failed to load"):
		return
	app._process(0.016)
	if not _check(is_equal_approx(app.active_scene.motion_amount, 0.2), "Spinner must receive motion amount"):
		return
	if not _check(app.active_scene.spinners.has(-1), "Motion alone must create a spinner"):
		return
	print("Interaction and frame-motion integration checks passed")
	app.queue_free()
	await process_frame
	quit(0)
