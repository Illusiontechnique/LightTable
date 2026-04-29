extends Node2D

@onready var receiver = $NetworkReceiver
@onready var interaction_container = $Interactions
@onready var dev_dashboard = $UI/DevDashboard
@onready var log_text = $UI/DevDashboard/Console/LogText
@onready var cam_rect = $UI/DevDashboard/HSplit/CamPreview/VBox/CamRect
@onready var hand_points_container = $UI/DevDashboard/HSplit/CamPreview/VBox/CamRect/HandPoints
@onready var sim_toggle = $UI/DevDashboard/HSplit/CamPreview/VBox/Controls/VBox/SimBox/SimToggle

var active_scene = null
var simulation_mode = true

# Simple interaction visualizer (circles that appear at hand positions)
func _ready():
	var err = receiver.interaction_received.connect(_on_interaction_received)
	if err != OK:
		log_message("Error connecting signal!")
	
	sim_toggle.toggled.connect(_on_sim_toggled)
	
	# Add Instruction Overlay
	add_instruction_overlay()
	
	# Scene Selection Buttons
	setup_scene_buttons()
	
	# Dev Dashboard toggle
	dev_dashboard.visible = true # Start with dashboard for dev
	log_message("System Ready. Press Load Water to begin.")

func add_instruction_overlay():
	var panel = PanelContainer.new()
	panel.name = "WelcomeBox"
	panel.modulate.a = 0.9
	panel.position = Vector2(50, 50)
	panel.size = Vector2(350, 200)
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.corner_radius_top_left = 10
	style.corner_radius_bottom_right = 10
	panel.add_theme_stylebox_override("panel", style)
	
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = "[center][b][color=aqua]LIGHT TABLE v1.0[/color][/b][/center]\n\n" + \
				 "[color=yellow]TAB[/color] - Toggle Dev/Projector Mode\n" + \
				 "[color=yellow]ESC[/color] - Exit Application\n\n" + \
				 "1. Click [b]Load Water[/b]\n" + \
				 "2. Calibrate Cam (TL, TR, BR, BL)\n" + \
				 "3. Move hands to interact!"
	
	panel.add_child(label)
	$UI.add_child(panel)

func setup_scene_buttons():
	var btn_container = $UI/DevDashboard/HSplit/CamPreview/VBox/Controls/VBox
	
	# Add Camera Control Buttons
	var camera_label = Label.new()
	camera_label.text = "-- HARDWARE --"
	camera_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn_container.add_child(camera_label)

	var restart_cam_btn = Button.new()
	restart_cam_btn.text = "Restart CV Layer"
	restart_cam_btn.pressed.connect(_on_restart_cam_pressed)
	btn_container.add_child(restart_cam_btn)

	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	btn_container.add_child(spacer)

	var scene_label = Label.new()
	scene_label.text = "-- SCENES --"
	scene_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn_container.add_child(scene_label)
	
	var scenes = {
		"Water": "res://scripts/content/water_scene.gd",
		"Piano": "res://scripts/content/piano_scene.gd",
		"Alphabet": "res://scripts/content/alphabet_puzzle.gd",
		"Balloons": "res://scripts/content/balloons_scene.gd"
	}
	
	for s_name in scenes:
		var btn = Button.new()
		btn.text = "Load " + s_name
		btn.pressed.connect(load_content_scene.bind(scenes[s_name]))
		btn_container.add_child(btn)

func load_content_scene(script_path: String):
	if active_scene:
		active_scene.queue_free()
	
	var new_node = Node2D.new()
	new_node.name = "ContentScene"
	new_node.set_script(load(script_path))
	add_child(new_node)
	move_child(new_node, 0) # Keep it behind UI
	active_scene = new_node
	log_message("Loaded Scene: " + script_path)

func _on_restart_cam_pressed():
	log_message("Restarting CV Layer...")
	# Send a special command via UDP to Python to quit
	var packet = JSON.stringify({"type": "command", "cmd": "quit"}).to_utf8_buffer()
	receiver.socket.put_packet(packet)
	
	# Wait a moment for it to close, then re-launch
	get_tree().create_timer(1.0).timeout.connect(func():
		var output = []
		OS.execute("cmd.exe", ["/c", "start /b .venv\\Scripts\\python.exe cv_layer/main.py"], output)
		log_message("CV Layer Launch Command Sent.")
	)

func _on_sim_toggled(button_pressed):
	simulation_mode = button_pressed
	log_message("Simulation Mode: " + str(button_pressed))

func log_message(msg: String):
	log_text.append_text("\n[color=gray]" + Time.get_time_string_from_system() + "[/color] " + msg)

func _input(event):
	if event.is_action_pressed("ui_cancel"): # ESC key
		get_tree().quit()

	if event.is_action_pressed("ui_focus_next"): # TAB key
		dev_dashboard.visible = !dev_dashboard.visible
		if dev_dashboard.visible:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

	# Mouse simulation for testing without camera hardware
	if simulation_mode and event is InputEventMouse:
		# Use the Right side panel (Projected Canvas) relative position
		var output_panel = $UI/DevDashboard/HSplit/OutputPreview
		if dev_dashboard.visible:
			if output_panel.get_global_rect().has_point(event.position):
				var local_pos = event.position - output_panel.global_position
				var normalized_pos = local_pos / output_panel.size
				_on_interaction_received(99, normalized_pos, "move")
		else:
			var normalized_pos = event.position / get_viewport_rect().size
			_on_interaction_received(99, normalized_pos, "move")

func _on_interaction_received(id: int, pos: Vector2, state: String):
	# Map normalized 0-1 to screen size
	var screen_pos = pos * get_viewport_rect().size
	
	# Update main visual indicator
	var indicator = interaction_container.get_node_or_null(str(id))
	if not indicator:
		indicator = ColorRect.new()
		indicator.name = str(id)
		indicator.size = Vector2(40, 40)
		indicator.pivot_offset = Vector2(20, 20)
		indicator.color = Color(0, 1, 1, 0.5)
		interaction_container.add_child(indicator)
	
	indicator.position = screen_pos - indicator.pivot_offset
	
	# Update Dev Dashboard Point Preview
	var dev_point = hand_points_container.get_node_or_null(str(id))
	if not dev_point:
		dev_point = ColorRect.new()
		dev_point.name = str(id)
		dev_point.size = Vector2(10, 10)
		dev_point.color = Color.RED
		hand_points_container.add_child(dev_point)
	
	dev_point.position = pos * cam_rect.size - Vector2(5, 5)
	
	if id != 99 and state == "press": # Only log non-simulated real events
		log_message("Interaction Start: ID " + str(id))
