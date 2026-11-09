extends Node2D

@onready var receiver = $NetworkReceiver
@onready var background = $Background
@onready var interaction_container = $Interactions
@onready var dev_dashboard = $UI/DevDashboard
@onready var cam_preview_panel = $UI/DevDashboard/HSplit/CamPreview
@onready var output_preview_panel = $UI/DevDashboard/HSplit/OutputPreview
@onready var console_panel = $UI/DevDashboard/Console
@onready var log_text = $UI/DevDashboard/Console/LogText
@onready var cam_rect = $UI/DevDashboard/HSplit/CamPreview/VBox/CamRect
@onready var hand_points_container = $UI/DevDashboard/HSplit/CamPreview/VBox/CamRect/HandPoints
@onready var sim_toggle = $UI/DevDashboard/HSplit/CamPreview/VBox/Controls/VBox/SimBox/SimToggle

var active_scene = null
var simulation_mode = true
var scene_list: Array = []      # [{name, path}]
var current_scene_index: int = -1
var hand_skeleton_overlay: Node2D = null
var cursor_draw_layer: Node2D = null
var world_env: WorldEnvironment = null
var quality_hud_label: Label = null
var fps_hud_label: Label = null
var _fps_update_timer: float = 0.0
var cursor_radius: float = 65.0
var audio_input_floor := 0.01
var audio_input_ceiling := 0.18
var audio_raw_level := 0.0
var audio_level := 0.0
var welcome_overlay: Control
var welcome_status_label: Label
var welcome_timer := 0.0
var audio_meter_bar: ProgressBar
var audio_meter_label: Label
var audio_floor_label: Label
var audio_ceiling_label: Label
var audio_floor_slider: HSlider
var audio_ceiling_slider: HSlider
var console_toggle_button: Button
var console_visible := true
var active_scene_label := "Not confirmed"
var shortcuts_panel: PanelContainer
const SIMULATION_ID := -1
const INTERACTION_TIMEOUT := 1.0
var _interaction_seen: Dictionary = {}
var frame_motion_amount := 0.0
var _frame_motion_received_at := 0.0

# Simple interaction visualizer (circles that appear at hand positions)
func _ready():
	var err = receiver.interaction_received.connect(_on_interaction_received)
	if err != OK:
		log_message("Error connecting signal!")
	receiver.remote_command.connect(_on_remote_command)
	receiver.hand_skeleton_received.connect(_on_hand_skeleton_received)
	receiver.frame_motion_received.connect(_on_frame_motion_received)
	receiver.track_mode_changed.connect(_on_track_mode_changed)
	LTQuality.quality_changed.connect(_on_quality_changed)

	# Hand skeleton overlay (drawn above content, below UI)
	hand_skeleton_overlay = Node2D.new()
	hand_skeleton_overlay.set_script(load("res://scripts/hand_skeleton_overlay.gd"))
	hand_skeleton_overlay.name = "HandSkeletonOverlay"
	add_child(hand_skeleton_overlay)
	move_child(hand_skeleton_overlay, get_child_count() - 2) # just below $UI
	
	sim_toggle.toggled.connect(_on_sim_toggled)
	
	# Scene Selection Buttons
	setup_scene_buttons()
	setup_audio_ui()
	setup_audio_sensor()
	apply_cinematic_ui()
	set_console_visible(true)
	show_welcome_screen()
	_setup_cursor_draw_layer()
	_setup_world_environment()
	_setup_quality_hud()
	_setup_shortcuts_panel()

	# Dev Dashboard toggle
	dev_dashboard.visible = true # Start with dashboard for dev
	dev_dashboard.modulate = Color(1, 1, 1, 0.82)
	log_message("System Ready.")

func _process(delta):
	var now := Time.get_ticks_msec() * 0.001
	for id in _interaction_seen.keys():
		if now - _interaction_seen[id] > INTERACTION_TIMEOUT:
			_on_interaction_received(id, Vector2.ZERO, "exit")
	if now - _frame_motion_received_at > 0.5:
		frame_motion_amount = 0.0
	if active_scene and active_scene.has_method("set_motion_amount"):
		active_scene.call("set_motion_amount", frame_motion_amount)
	welcome_timer += delta
	update_audio_sensor()
	if active_scene and active_scene.has_method("set_audio_level"):
		active_scene.call("set_audio_level", audio_level)
	if welcome_overlay and is_instance_valid(welcome_overlay) and welcome_timer > 2.75:
		dismiss_welcome_screen()
	# FPS counter — update ~4x/sec to stay readable
	_fps_update_timer += delta
	if _fps_update_timer >= 0.25:
		_fps_update_timer = 0.0
		var fps := Engine.get_frames_per_second()
		if fps_hud_label:
			fps_hud_label.text = str(fps) + " fps"
			if fps >= 55:
				fps_hud_label.modulate = Color(0.40, 1.00, 0.55)
			elif fps >= 30:
				fps_hud_label.modulate = Color(1.00, 0.85, 0.30)
			else:
				fps_hud_label.modulate = Color(1.00, 0.35, 0.30)

func apply_cinematic_ui():
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.03, 0.05, 0.08, 0.88)
	panel_style.corner_radius_top_left = 18
	panel_style.corner_radius_top_right = 18
	panel_style.corner_radius_bottom_left = 18
	panel_style.corner_radius_bottom_right = 18
	panel_style.border_width_left = 1
	panel_style.border_width_top = 1
	panel_style.border_width_right = 1
	panel_style.border_width_bottom = 1
	panel_style.border_color = Color(0.20, 0.88, 1.0, 0.55)
	panel_style.shadow_color = Color(0.0, 0.7, 1.0, 0.2)
	panel_style.shadow_size = 8

	cam_preview_panel.add_theme_stylebox_override("panel", panel_style)
	output_preview_panel.add_theme_stylebox_override("panel", panel_style)
	console_panel.add_theme_stylebox_override("panel", panel_style)

	cam_rect.color = Color(0.0, 0.0, 0.0, 1.0)
	log_text.modulate = Color(0.92, 0.98, 1.0, 1.0)
	cam_preview_panel.modulate = Color(0.95, 0.99, 1.0, 1.0)
	output_preview_panel.modulate = Color(0.95, 0.99, 1.0, 1.0)

func create_dashboard_section(parent: VBoxContainer, title_text: String, accent: Color) -> VBoxContainer:
	var card = PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var card_style = StyleBoxFlat.new()
	card_style.bg_color = Color(0.015, 0.02, 0.03, 0.94)
	card_style.corner_radius_top_left = 14
	card_style.corner_radius_top_right = 14
	card_style.corner_radius_bottom_left = 14
	card_style.corner_radius_bottom_right = 14
	card_style.border_width_left = 1
	card_style.border_width_top = 1
	card_style.border_width_right = 1
	card_style.border_width_bottom = 1
	card_style.border_color = accent
	card_style.shadow_color = Color(accent.r, accent.g, accent.b, 0.12)
	card_style.shadow_size = 4
	card_style.content_margin_left = 14
	card_style.content_margin_top = 12
	card_style.content_margin_right = 14
	card_style.content_margin_bottom = 14
	card.add_theme_stylebox_override("panel", card_style)
	parent.add_child(card)

	var content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	card.add_child(content)

	var heading = Label.new()
	heading.text = title_text
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 13)
	heading.modulate = accent
	content.add_child(heading)

	return content

func add_instruction_overlay():
	show_welcome_screen()

func setup_audio_ui():
	var btn_container = $UI/DevDashboard/HSplit/CamPreview/VBox/Controls/VBox
	btn_container.add_theme_constant_override("separation", 12)

	var audio_section = create_dashboard_section(btn_container, "AUDIO SENSOR", Color(0.8, 0.95, 1.0, 0.75))

	var audio_label = Label.new()
	audio_label.text = "Mic input / normalized drive"
	audio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	audio_label.modulate = Color(0.8, 0.95, 1.0)
	audio_section.add_child(audio_label)

	audio_meter_label = Label.new()
	audio_meter_label.text = "Mic: initializing..."
	audio_meter_label.modulate = Color(0.9, 0.98, 1.0)
	audio_section.add_child(audio_meter_label)

	audio_meter_bar = ProgressBar.new()
	audio_meter_bar.min_value = 0.0
	audio_meter_bar.max_value = 1.0
	audio_meter_bar.value = 0.0
	audio_meter_bar.show_percentage = false
	audio_meter_bar.custom_minimum_size = Vector2(0, 18)
	audio_section.add_child(audio_meter_bar)

	var range_section = create_dashboard_section(btn_container, "MIC RANGE", Color(1.0, 0.85, 0.45, 0.75))

	audio_floor_label = Label.new()
	audio_floor_label.text = "Floor: " + str(snapped(audio_input_floor, 0.001))
	audio_floor_label.modulate = Color(0.9, 0.95, 1.0)
	range_section.add_child(audio_floor_label)

	audio_floor_slider = HSlider.new()
	audio_floor_slider.min_value = 0.0
	audio_floor_slider.max_value = 1.0
	audio_floor_slider.step = 0.001
	audio_floor_slider.value = audio_input_floor
	audio_floor_slider.custom_minimum_size = Vector2(0, 20)
	audio_floor_slider.value_changed.connect(_on_audio_floor_changed)
	range_section.add_child(audio_floor_slider)

	audio_ceiling_label = Label.new()
	audio_ceiling_label.text = "Ceiling: " + str(snapped(audio_input_ceiling, 0.001))
	audio_ceiling_label.modulate = Color(0.9, 0.95, 1.0)
	range_section.add_child(audio_ceiling_label)

	audio_ceiling_slider = HSlider.new()
	audio_ceiling_slider.min_value = 0.0
	audio_ceiling_slider.max_value = 1.0
	audio_ceiling_slider.step = 0.001
	audio_ceiling_slider.value = audio_input_ceiling
	audio_ceiling_slider.custom_minimum_size = Vector2(0, 20)
	audio_ceiling_slider.value_changed.connect(_on_audio_ceiling_changed)
	range_section.add_child(audio_ceiling_slider)

	var reset_range_btn = Button.new()
	reset_range_btn.text = "Reset Mic Range"
	reset_range_btn.custom_minimum_size = Vector2(0, 34)
	reset_range_btn.pressed.connect(_reset_audio_range)
	range_section.add_child(reset_range_btn)

	var view_section = create_dashboard_section(btn_container, "VIEW", Color(0.82, 0.72, 1.0, 0.75))

	console_toggle_button = Button.new()
	console_toggle_button.custom_minimum_size = Vector2(0, 34)
	console_toggle_button.pressed.connect(toggle_console_visibility)
	view_section.add_child(console_toggle_button)
	refresh_console_toggle_label()

	var console_hint = Label.new()
	console_hint.text = "Press C to show or hide the console"
	console_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	console_hint.modulate = Color(0.82, 0.86, 1.0, 0.85)
	view_section.add_child(console_hint)

func setup_audio_sensor():
	ProjectSettings.set_setting("audio/driver/enable_input", true)
	var error_code = AudioServer.set_input_device_active(true)
	if error_code == OK:
		audio_meter_label.text = "Mic: active"
		log_message("Audio input enabled.")
	else:
		audio_meter_label.text = "Mic: unavailable"
		log_message("Audio input could not be enabled.")

func show_welcome_screen():
	if welcome_overlay and is_instance_valid(welcome_overlay):
		welcome_overlay.queue_free()

	welcome_overlay = Control.new()
	welcome_overlay.name = "WelcomeScreen"
	welcome_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	welcome_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	welcome_overlay.z_index = 100

	var backdrop = ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, 0.96)
	welcome_overlay.add_child(backdrop)

	var card = PanelContainer.new()
	card.custom_minimum_size = Vector2(760, 420)
	card.anchor_left = 0.5
	card.anchor_top = 0.5
	card.anchor_right = 0.5
	card.anchor_bottom = 0.5
	card.offset_left = -380
	card.offset_top = -210
	card.offset_right = 380
	card.offset_bottom = 210

	var card_style = StyleBoxFlat.new()
	card_style.bg_color = Color(0.03, 0.05, 0.08, 0.94)
	card_style.corner_radius_top_left = 22
	card_style.corner_radius_top_right = 22
	card_style.corner_radius_bottom_left = 22
	card_style.corner_radius_bottom_right = 22
	card_style.border_width_left = 1
	card_style.border_width_top = 1
	card_style.border_width_right = 1
	card_style.border_width_bottom = 1
	card_style.border_color = Color(0.2, 0.9, 1.0, 0.75)
	card_style.shadow_color = Color(0.0, 0.7, 1.0, 0.25)
	card_style.shadow_size = 10
	card.add_theme_stylebox_override("panel", card_style)
	welcome_overlay.add_child(card)

	var content = VBoxContainer.new()
	content.anchor_right = 1.0
	content.anchor_bottom = 1.0
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 10)
	card.add_child(content)

	var title = Label.new()
	title.text = "LIGHT TABLE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.modulate = Color(0.35, 0.95, 1.0)
	content.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "cinematic interactive projection"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.modulate = Color(0.95, 0.95, 1.0, 0.9)
	content.add_child(subtitle)

	welcome_status_label = Label.new()
	welcome_status_label.text = "Loading sensors"
	welcome_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	welcome_status_label.add_theme_font_size_override("font_size", 20)
	welcome_status_label.modulate = Color(1.0, 0.85, 0.45)
	content.add_child(welcome_status_label)

	var help = RichTextLabel.new()
	help.bbcode_enabled = true
	help.fit_content = true
	help.scroll_active = false
	help.text = "[center][color=white]TAB[/color] dashboard   [color=white]← →[/color] scenes   [color=white]T[/color] pointers   [color=white]H[/color] skeleton\n[color=white]↑ ↓[/color] quality tier   [color=white]ESC[/color] quit   [color=white]Click[/color] or wait to enter[/center]"
	content.add_child(help)

	# ── Remote access info ────────────────────────────────────────────
	var sep := HSeparator.new()
	sep.modulate = Color(1.0, 1.0, 1.0, 0.15)
	content.add_child(sep)

	# Read PIN from remote_config.json if present
	var pin_str  : String = "----"
	var cfg_path : String = ProjectSettings.globalize_path("res://") + "../remote_config.json"
	var cfg_file := FileAccess.open(cfg_path, FileAccess.READ)
	if cfg_file:
		var j := JSON.new()
		j.parse(cfg_file.get_as_text())
		if j.data is Dictionary and j.data.has("pin"):
			pin_str = str(j.data["pin"])

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	content.add_child(row)

	# QR code placeholder — loaded 1.5 s later (Python needs time to start)
	var qr_rect := TextureRect.new()
	qr_rect.custom_minimum_size = Vector2(90, 90)
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_rect.modulate = Color(1.0, 1.0, 1.0, 0.92)
	row.add_child(qr_rect)
	var qr_abs : String = ProjectSettings.globalize_path("res://") + "assets/remote_qr.png"
	var qr_img := Image.new()
	if qr_img.load(qr_abs) == OK:
		qr_rect.texture = ImageTexture.create_from_image(qr_img)

	var info_col := VBoxContainer.new()
	info_col.alignment = BoxContainer.ALIGNMENT_CENTER
	info_col.add_theme_constant_override("separation", 6)
	row.add_child(info_col)

	var url_lbl := Label.new()
	url_lbl.text = "http://%s:5000" % _get_lan_ip()
	url_lbl.add_theme_font_size_override("font_size", 17)
	url_lbl.modulate = Color(0.55, 1.0, 0.88, 0.95)
	info_col.add_child(url_lbl)

	var pin_lbl := Label.new()
	pin_lbl.text = "PIN: %s" % pin_str
	pin_lbl.add_theme_font_size_override("font_size", 17)
	pin_lbl.modulate = Color(1.0, 0.85, 0.45, 0.90)
	info_col.add_child(pin_lbl)

	$UI.add_child(welcome_overlay)
	welcome_timer = 0.0

func dismiss_welcome_screen():
	if welcome_overlay and is_instance_valid(welcome_overlay):
		var fade = create_tween()
		fade.tween_property(welcome_overlay, "modulate:a", 0.0, 0.45)
		fade.tween_callback(welcome_overlay.queue_free)
		fade.tween_callback(func():
			if active_scene == null:
				load_content_scene("res://scripts/content/menu_scene.gd"))
		welcome_overlay = null
		welcome_status_label = null

func _get_lan_ip() -> String:
	for addr in IP.get_local_addresses():
		if addr.count(".") == 3 and not addr.begins_with("127.") and not addr.begins_with("169."):
			return addr
	return "localhost"

func update_audio_sensor():
	if AudioServer.get_input_frames_available() < 64:
		audio_raw_level = lerp(audio_raw_level, 0.0, 0.08)
		audio_level = lerp(audio_level, 0.0, 0.08)
		if audio_meter_bar:
			audio_meter_bar.value = audio_level
		if audio_meter_label:
			audio_meter_label.text = "Mic raw: " + str(snapped(audio_raw_level, 0.001)) + " | norm: " + str(snapped(audio_level, 0.001))
		return

	var frames = AudioServer.get_input_frames(256)
	if frames.is_empty():
		audio_raw_level = lerp(audio_raw_level, 0.0, 0.08)
		audio_level = lerp(audio_level, 0.0, 0.08)
		if audio_meter_bar:
			audio_meter_bar.value = audio_level
		if audio_meter_label:
			audio_meter_label.text = "Mic raw: " + str(snapped(audio_raw_level, 0.001)) + " | norm: " + str(snapped(audio_level, 0.001))
		return

	var total_energy := 0.0
	for sample in frames:
		total_energy += abs(sample.x) + abs(sample.y)

	var raw_level = clamp((total_energy / float(frames.size())) * 0.9, 0.0, 1.0)
	audio_raw_level = lerp(audio_raw_level, raw_level, 0.25)
	var ceiling = max(audio_input_ceiling, audio_input_floor + 0.001)
	var normalized_level = clamp(inverse_lerp(audio_input_floor, ceiling, audio_raw_level), 0.0, 1.0)
	audio_level = lerp(audio_level, normalized_level, 0.25)
	if audio_meter_bar:
		audio_meter_bar.value = audio_level
	if audio_meter_label:
		audio_meter_label.text = "Mic raw: " + str(snapped(audio_raw_level, 0.001)) + " | norm: " + str(snapped(audio_level, 0.001))
	if audio_floor_label:
		audio_floor_label.text = "Floor: " + str(snapped(audio_input_floor, 0.001))
	if audio_ceiling_label:
		audio_ceiling_label.text = "Ceiling: " + str(snapped(audio_input_ceiling, 0.001))

func _on_audio_floor_changed(value: float):
	audio_input_floor = clamp(value, 0.0, 0.999)
	if audio_input_floor >= audio_input_ceiling:
		audio_input_ceiling = min(1.0, audio_input_floor + 0.01)
		if audio_ceiling_slider:
			audio_ceiling_slider.value = audio_input_ceiling
	if audio_floor_label:
		audio_floor_label.text = "Floor: " + str(snapped(audio_input_floor, 0.001))

func _on_audio_ceiling_changed(value: float):
	audio_input_ceiling = clamp(value, 0.001, 1.0)
	if audio_input_ceiling <= audio_input_floor:
		audio_input_floor = max(0.0, audio_input_ceiling - 0.01)
		if audio_floor_slider:
			audio_floor_slider.value = audio_input_floor
	if audio_ceiling_label:
		audio_ceiling_label.text = "Ceiling: " + str(snapped(audio_input_ceiling, 0.001))

func _reset_audio_range():
	audio_input_floor = 0.01
	audio_input_ceiling = 0.18
	if audio_floor_slider:
		audio_floor_slider.value = audio_input_floor
	if audio_ceiling_slider:
		audio_ceiling_slider.value = audio_input_ceiling
	if audio_floor_label:
		audio_floor_label.text = "Floor: " + str(snapped(audio_input_floor, 0.001))
	if audio_ceiling_label:
		audio_ceiling_label.text = "Ceiling: " + str(snapped(audio_input_ceiling, 0.001))

func setup_scene_buttons():
	var btn_container = $UI/DevDashboard/HSplit/CamPreview/VBox/Controls/VBox
	btn_container.add_theme_constant_override("separation", 12)
	
	# Add Camera Control Buttons
	var hardware_section = create_dashboard_section(btn_container, "HARDWARE", Color(0.65, 0.95, 1.0, 0.75))

	var restart_cam_btn = Button.new()
	restart_cam_btn.text = "Restart CV Layer"
	restart_cam_btn.custom_minimum_size = Vector2(0, 34)
	restart_cam_btn.pressed.connect(_on_restart_cam_pressed)
	hardware_section.add_child(restart_cam_btn)

	var welcome_btn = Button.new()
	welcome_btn.text = "Show Welcome"
	welcome_btn.custom_minimum_size = Vector2(0, 34)
	welcome_btn.pressed.connect(show_welcome_screen)
	hardware_section.add_child(welcome_btn)

	var clear_btn = Button.new()
	clear_btn.text = "Toggle Pointers  [T]"
	clear_btn.custom_minimum_size = Vector2(0, 34)
	clear_btn.pressed.connect(func():
		if cursor_draw_layer:
			cursor_draw_layer.show_cursors = !cursor_draw_layer.show_cursors)
	hardware_section.add_child(clear_btn)

	var cursor_section = create_dashboard_section(btn_container, "CURSORS", Color(0.45, 1.0, 0.88, 0.75))

	var radius_lbl := Label.new()
	radius_lbl.text = "Collision Radius: " + str(int(cursor_radius))
	radius_lbl.modulate = Color(0.85, 0.98, 1.0)
	cursor_section.add_child(radius_lbl)

	var radius_slider := HSlider.new()
	radius_slider.min_value = 12.0
	radius_slider.max_value = 220.0
	radius_slider.step = 1.0
	radius_slider.value = cursor_radius
	radius_slider.custom_minimum_size = Vector2(0, 20)
	radius_slider.value_changed.connect(func(v: float):
		cursor_radius = v
		radius_lbl.text = "Collision Radius: " + str(int(v))
		if cursor_draw_layer:
			cursor_draw_layer.radius = v)
	cursor_section.add_child(radius_slider)

	var quality_section = create_dashboard_section(btn_container, "QUALITY", Color(0.88, 0.65, 1.0, 0.75))

	var qual_lbl := Label.new()
	qual_lbl.text = LTQuality.level_name()
	qual_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qual_lbl.modulate = LTQuality.level_color()
	quality_section.add_child(qual_lbl)
	LTQuality.quality_changed.connect(func(l: int):
		qual_lbl.text = LTQuality.level_name()
		qual_lbl.modulate = LTQuality.level_color())

	var qual_btns := HBoxContainer.new()
	qual_btns.add_theme_constant_override("separation", 6)
	quality_section.add_child(qual_btns)

	var q_down := Button.new()
	q_down.text = "▼ Lower"
	q_down.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q_down.custom_minimum_size = Vector2(0, 30)
	q_down.pressed.connect(LTQuality.step_down)
	qual_btns.add_child(q_down)

	var q_up := Button.new()
	q_up.text = "▲ Higher"
	q_up.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q_up.custom_minimum_size = Vector2(0, 30)
	q_up.pressed.connect(LTQuality.step_up)
	qual_btns.add_child(q_up)

	var qual_hint := Label.new()
	qual_hint.text = "↑ / ↓ keys cycle quality"
	qual_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qual_hint.modulate = Color(0.82, 0.86, 1.0, 0.75)
	quality_section.add_child(qual_hint)

	var scene_section = create_dashboard_section(btn_container, "SCENES", Color(1.0, 0.88, 0.55, 0.75))
	
	var scenes = {
		"Menu":           "res://scripts/content/menu_scene.gd",
		"Water":          "res://scripts/content/water_scene.gd",
		"Balloons":       "res://scripts/content/balloons_scene.gd",
		"Bouncing Balls": "res://scripts/content/bouncing_balls_scene.gd",
		"Elements":       "res://scripts/content/elements_scene.gd",
		"Galaxy":         "res://scripts/content/galaxy_scene.gd",
		"Draw":           "res://scripts/content/freehand_draw_scene.gd",
		"Talk Back":      "res://scripts/content/talk_back_scene.gd",
		"Spinner":        "res://scripts/content/spinner_scene.gd",
		"Blob Painter":   "res://scripts/content/blob_painter_scene.gd",
		"Color Trails":   "res://scripts/content/color_trails_scene.gd",
		"Edge Reveal":    "res://scripts/content/edge_reveal_scene.gd",
		"Piano":          "res://scripts/content/piano_scene.gd",
		"Alphabet":       "res://scripts/content/alphabet_puzzle.gd",
		"Bug":            "res://scripts/content/bug_scene.gd",
	}

	scene_list.clear()
	for s_name in scenes:
		scene_list.append({"name": s_name, "path": scenes[s_name]})

	for s_name in scenes:
		var btn = Button.new()
		btn.text = s_name
		btn.custom_minimum_size = Vector2(0, 34)
		btn.pressed.connect(load_content_scene.bind(scenes[s_name]))
		scene_section.add_child(btn)

func load_content_scene(script_path: String):
	if not ResourceLoader.exists(script_path):
		log_message("Scene load failed; resource not found: " + script_path)
		return false
	var scene_script = load(script_path) as GDScript
	if scene_script == null or not scene_script.can_instantiate():
		log_message("Scene load failed: " + script_path)
		return false
	if active_scene:
		remove_child(active_scene)
		active_scene.queue_free()
	
	var new_node = Node2D.new()
	new_node.name = "ContentScene"
	new_node.set_script(scene_script)
	add_child(new_node)
	move_child(new_node, 0) # Keep it behind UI
	active_scene = new_node
	background.visible = false

	# Notify new scene of current quality level
	if active_scene.has_method("set_quality_level"):
		active_scene.call("set_quality_level", LTQuality.level)

	# Track current index for arrow-key cycling
	current_scene_index = -1
	for i in scene_list.size():
		if scene_list[i]["path"] == script_path:
			current_scene_index = i
			break

	if current_scene_index >= 0:
		_show_scene_title(scene_list[current_scene_index]["name"])
		active_scene_label = scene_list[current_scene_index]["name"]
	else:
		active_scene_label = script_path.get_file()

	log_message("Loaded Scene: " + script_path)
	LTLog.event("scene_load", {"scene": script_path, "fps": Engine.get_frames_per_second()})
	return true

func _show_scene_title(scene_name: String) -> void:
	var existing := get_node_or_null("SceneTitleOverlay")
	if existing:
		existing.queue_free()
	var vp := get_viewport_rect().size
	var lbl := Label.new()
	lbl.name = "SceneTitleOverlay"
	lbl.text = scene_name
	lbl.add_theme_font_size_override("font_size", 88)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.15, 0.35, 0.95))
	lbl.add_theme_constant_override("outline_size", 5)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.size     = vp
	lbl.position = Vector2.ZERO
	lbl.z_index  = 60
	$UI.add_child(lbl)
	get_tree().create_timer(2.5).timeout.connect(func():
		if is_instance_valid(lbl):
			var tw := create_tween()
			tw.tween_property(lbl, "modulate:a", 0.0, 0.7)
			tw.tween_callback(lbl.queue_free)
	)

func _on_restart_cam_pressed():
	log_message("Restarting CV Layer...")
	# Send a special command via UDP to Python to quit
	var packet = JSON.stringify({"type": "command", "cmd": "quit"}).to_utf8_buffer()
	receiver.peer.put_packet(packet)
	
	# Wait a moment for it to close, then re-launch
	get_tree().create_timer(1.0).timeout.connect(func():
		var output = []
		OS.execute("cmd.exe", ["/c", "start /b .venv\\Scripts\\python.exe cv_layer/main.py"], output)
		log_message("CV Layer Launch Command Sent.")
	)

func _on_sim_toggled(button_pressed):
	simulation_mode = button_pressed
	if not button_pressed:
		_on_interaction_received(SIMULATION_ID, Vector2.ZERO, "exit")
	log_message("Simulation Mode: " + str(button_pressed))

func log_message(msg: String):
	log_text.append_text("\n[color=gray]" + Time.get_time_string_from_system() + "[/color] " + msg)
	LTLog.info(msg)

func _setup_shortcuts_panel() -> void:
	shortcuts_panel = PanelContainer.new()
	shortcuts_panel.name = "ShortcutsPanel"
	shortcuts_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shortcuts_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	shortcuts_panel.offset_left = -440
	shortcuts_panel.offset_right = -20
	shortcuts_panel.offset_top = 20
	shortcuts_panel.offset_bottom = 300
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.05, 0.08, 0.94)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	shortcuts_panel.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 20)
	label.text = "KEYBOARD SHORTCUTS\n\nSpace  Show / hide this list\nT  Show / hide pointers\nY  Show / hide hand skeleton\nLeft / Right  Previous / next scene\nUp / Down  Increase / decrease quality\nTab  Show / hide dashboard\nC  Show / hide console\nF3  Water debug and test modes\nEsc  Quit"
	shortcuts_panel.add_child(label)
	shortcuts_panel.visible = false
	$UI.add_child(shortcuts_panel)

func _input(event):
	if event.is_action_pressed("ui_cancel"): # ESC key
		get_tree().quit()

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_C:
		toggle_console_visibility()

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		if cursor_draw_layer:
			cursor_draw_layer.show_cursors = !cursor_draw_layer.show_cursors

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		shortcuts_panel.visible = !shortcuts_panel.visible
		get_viewport().set_input_as_handled()

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_UP:
		LTQuality.step_up()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_DOWN:
		LTQuality.step_down()

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_Y:
		if hand_skeleton_overlay:
			hand_skeleton_overlay.show_skeleton = !hand_skeleton_overlay.show_skeleton
			hand_skeleton_overlay.queue_redraw()

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_LEFT:
		if scene_list.size() > 0:
			current_scene_index = posmod(current_scene_index - 1, scene_list.size())
			load_content_scene(scene_list[current_scene_index]["path"])

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_RIGHT:
		if scene_list.size() > 0:
			current_scene_index = posmod(current_scene_index + 1, scene_list.size())
			load_content_scene(scene_list[current_scene_index]["path"])

	if welcome_overlay and event is InputEventMouseButton and event.pressed:
		dismiss_welcome_screen()

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
				_on_interaction_received(SIMULATION_ID, normalized_pos, "move")
			else:
				_on_interaction_received(SIMULATION_ID, Vector2.ZERO, "exit")
		else:
			var normalized_pos = event.position / get_viewport_rect().size
			_on_interaction_received(SIMULATION_ID, normalized_pos, "move")

func toggle_console_visibility():
	set_console_visible(not console_visible)

func set_console_visible(visible_state: bool):
	console_visible = visible_state
	if console_panel:
		console_panel.visible = visible_state
	refresh_console_toggle_label()

func refresh_console_toggle_label():
	if console_toggle_button:
		console_toggle_button.text = "Hide Console" if console_visible else "Show Console"

func _on_clear_interactions_pressed():
	_interaction_seen.clear()
	for c in interaction_container.get_children():
		c.queue_free()
	for point in hand_points_container.get_children():
		point.queue_free()
	if cursor_draw_layer:
		cursor_draw_layer.clear_all()

# ─── Phone web remote commands ────────────────────────────────────────────────
func _on_remote_command(cmd: Dictionary) -> void:
	var c : String = cmd.get("cmd", "")
	if c != "status_request":
		print("[Remote] cmd=", c, " data=", cmd)
	match c:
		"status_request":
			pass
		"load_scene":
			var script : String = cmd.get("script", "")
			if script != "":
				if load_content_scene(script):
					log_message("Remote: loaded " + cmd.get("scene", script))
		"set_audio":
			var fl : float = float(cmd.get("floor",   audio_input_floor))
			var cl : float = float(cmd.get("ceiling", audio_input_ceiling))
			_on_audio_floor_changed(fl)
			_on_audio_ceiling_changed(cl)
			if audio_floor_slider:
				audio_floor_slider.value = fl
			if audio_ceiling_slider:
				audio_ceiling_slider.value = cl
			log_message("Remote: mic floor=%.3f ceiling=%.3f" % [fl, cl])
		"clear_cursors":
			_on_clear_interactions_pressed()
			log_message("Remote: cursors cleared")
	receiver.send_status(active_scene_label, str(cmd.get("request_id", "")))

func _on_interaction_received(id: int, pos: Vector2, state: String, metadata: Dictionary = {}):
	if state == "exit":
		_interaction_seen.erase(id)
		var old_indicator = interaction_container.get_node_or_null(str(id))
		if old_indicator:
			interaction_container.remove_child(old_indicator)
			old_indicator.queue_free()
		var old_point = hand_points_container.get_node_or_null(str(id))
		if old_point:
			hand_points_container.remove_child(old_point)
			old_point.queue_free()
		if cursor_draw_layer:
			cursor_draw_layer.remove_cursor(id)
		return
	if id != SIMULATION_ID:
		_interaction_seen[id] = Time.get_ticks_msec() * 0.001

	# Map normalized 0-1 to screen size
	var screen_pos = pos * get_viewport_rect().size
	
	# Position tracker node (invisible; scenes query this for touch location)
	var indicator = interaction_container.get_node_or_null(str(id))
	if not indicator:
		indicator = ColorRect.new()
		indicator.name = str(id)
		indicator.size = Vector2(40, 40)
		indicator.pivot_offset = Vector2(20, 20)
		indicator.color = Color(0, 0, 0, 0)  # invisible — cursor_draw_layer handles visuals
		interaction_container.add_child(indicator)

	indicator.position = screen_pos - indicator.pivot_offset

	# Glowing cursor + collision radius ring
	if cursor_draw_layer:
		cursor_draw_layer.update_cursor(id, screen_pos, metadata)
	
	# Update Dev Dashboard Point Preview
	var dev_point = hand_points_container.get_node_or_null(str(id))
	if not dev_point:
		dev_point = ColorRect.new()
		dev_point.name = str(id)
		dev_point.size = Vector2(10, 10)
		dev_point.color = Color.RED
		hand_points_container.add_child(dev_point)
	
	dev_point.position = pos * cam_rect.size - Vector2(5, 5)
	
	if id != SIMULATION_ID and state == "enter":
		log_message("Interaction Enter: ID " + str(id))
		LTLog.event("touch", {"id": id, "x": snapped(pos.x, 0.001), "y": snapped(pos.y, 0.001)})

func _on_track_mode_changed(mode: String):
	log_message("Tracking Mode: " + mode)
	_show_mode_toast(mode)

func _show_mode_toast(text: String):
	var toast = Label.new()
	toast.text = "MODE: " + text.to_upper()
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast.add_theme_font_size_override("font_size", 42)
	toast.modulate = Color(0.4, 0.8, 1.0, 1.0)
	toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	$UI.add_child(toast)
	
	var tw = create_tween()
	tw.tween_property(toast, "scale", Vector2(1.2, 1.2), 0.1)
	tw.parallel().tween_property(toast, "modulate:a", 1.0, 0.1)
	tw.tween_interval(1.0)
	tw.tween_property(toast, "modulate:a", 0.0, 0.5)
	tw.tween_callback(toast.queue_free)

func _on_hand_skeleton_received(hands: Array) -> void:
	if hand_skeleton_overlay:
		hand_skeleton_overlay.update_hands(hands)

func _on_frame_motion_received(amount: float, points: Array) -> void:
	frame_motion_amount = amount
	_frame_motion_received_at = Time.get_ticks_msec() * 0.001
	if active_scene and active_scene.has_method("on_frame_motion"):
		active_scene.call("on_frame_motion", amount, points)


# ─── Cursor draw layer ────────────────────────────────────────────────────────

func _setup_cursor_draw_layer() -> void:
	cursor_draw_layer = Node2D.new()
	cursor_draw_layer.set_script(load("res://scripts/cursor_draw_layer.gd"))
	cursor_draw_layer.name = "CursorDrawLayer"
	cursor_draw_layer.radius = cursor_radius
	add_child(cursor_draw_layer)
	move_child(cursor_draw_layer, get_child_count() - 2)  # just below $UI


# ─── World Environment / post-process glow ────────────────────────────────────

func _setup_world_environment() -> void:
	var env := Environment.new()
	env.background_mode  = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	env.glow_enabled     = true
	env.glow_normalized  = false
	env.glow_intensity   = 1.0
	env.glow_strength    = 1.2
	env.glow_bloom       = 0.12
	env.glow_blend_mode  = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 0.65
	env.glow_hdr_scale     = 1.5
	env.set_glow_level(0, true)
	env.set_glow_level(1, true)
	env.set_glow_level(2, true)

	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


# ─── Quality HUD badge ────────────────────────────────────────────────────────

func _setup_quality_hud() -> void:
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 9
	hud_layer.name  = "QualityHUD"
	add_child(hud_layer)

	var hud_root := Control.new()
	hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(hud_root)

	quality_hud_label = Label.new()
	quality_hud_label.anchor_left   = 1.0
	quality_hud_label.anchor_top    = 1.0
	quality_hud_label.anchor_right  = 1.0
	quality_hud_label.anchor_bottom = 1.0
	quality_hud_label.offset_left   = -220
	quality_hud_label.offset_top    = -40
	quality_hud_label.offset_right  = -12
	quality_hud_label.offset_bottom = -10
	quality_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	quality_hud_label.add_theme_font_size_override("font_size", 13)
	quality_hud_label.text     = "Q: " + LTQuality.level_name()
	quality_hud_label.modulate = LTQuality.level_color()
	hud_root.add_child(quality_hud_label)

	fps_hud_label = Label.new()
	fps_hud_label.anchor_left   = 1.0
	fps_hud_label.anchor_top    = 1.0
	fps_hud_label.anchor_right  = 1.0
	fps_hud_label.anchor_bottom = 1.0
	fps_hud_label.offset_left   = -220
	fps_hud_label.offset_top    = -62
	fps_hud_label.offset_right  = -12
	fps_hud_label.offset_bottom = -42
	fps_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps_hud_label.add_theme_font_size_override("font_size", 13)
	fps_hud_label.text     = "-- fps"
	fps_hud_label.modulate = Color(0.70, 0.85, 1.0, 0.80)
	hud_root.add_child(fps_hud_label)


# ─── Quality change handler ───────────────────────────────────────────────────

func _on_quality_changed(level: int) -> void:
	if world_env:
		var env := world_env.environment
		match level:
			0:
				env.glow_enabled = false
			1:
				env.glow_enabled   = true
				env.glow_intensity = 0.85
				env.glow_bloom     = 0.10
				env.set_glow_level(0, true)
				env.set_glow_level(1, true)
				env.set_glow_level(2, false)
				env.set_glow_level(3, false)
			2:
				env.glow_enabled   = true
				env.glow_intensity = 1.80
				env.glow_bloom     = 0.28
				env.set_glow_level(0, true)
				env.set_glow_level(1, true)
				env.set_glow_level(2, true)
				env.set_glow_level(3, true)

	if quality_hud_label:
		quality_hud_label.text     = "Q: " + LTQuality.level_name()
		quality_hud_label.modulate = LTQuality.level_color()

	# Notify active scene
	if active_scene and active_scene.has_method("set_quality_level"):
		active_scene.call("set_quality_level", level)

	log_message("Quality: " + LTQuality.level_name())
