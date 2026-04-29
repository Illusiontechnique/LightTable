extends Node2D

var audio_level := 0.0
var bug_x := 140.0
var bug_y := 790.0
var travel_left := 120.0
var travel_right := 1800.0

var bug_root: Node2D
var bug_body: Polygon2D
var bug_head: Polygon2D
var bug_track: Line2D
var status_label: Label
var background_layers: Array = []
var star_nodes: Array = []

func _ready():
	add_stage()
	build_parallax()
	build_track()
	build_bug()
	add_caption()

func add_stage():
	var bg = ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var moon = Polygon2D.new()
	moon.color = Color(0.15, 0.3, 0.42, 0.18)
	moon.polygon = build_circle_polygon(110.0, 36)
	moon.position = Vector2(1560, 150)
	add_child(moon)

	var title = Label.new()
	title.text = "BUG WALK / RUN"
	title.add_theme_font_size_override("font_size", 34)
	title.modulate = Color(0.55, 0.95, 1.0)
	title.position = Vector2(24, 18)
	add_child(title)

func add_caption():
	status_label = Label.new()
	status_label.text = "Speak to make the bug run"
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.modulate = Color(1.0, 0.86, 0.35)
	status_label.position = Vector2(24, 58)
	add_child(status_label)

func build_parallax():
	for i in range(16):
		var star = ColorRect.new()
		star.size = Vector2(2 + randi() % 4, 2 + randi() % 4)
		star.color = Color(0.55, 0.9, 1.0, 0.2 + randf() * 0.4)
		star.position = Vector2(randf_range(0, 1920), randf_range(40, 320))
		add_child(star)
		star_nodes.append({"node": star, "speed": randf_range(4.0, 18.0), "base_y": star.position.y, "phase": randf_range(0.0, TAU)})

	for i in range(4):
		var hill = Polygon2D.new()
		hill.color = Color(0.03 + i * 0.02, 0.04 + i * 0.02, 0.08 + i * 0.03, 1.0)
		hill.polygon = PackedVector2Array([
			Vector2(-260, 1080), Vector2(0, 720 - i * 26), Vector2(220, 1080)
		])
		hill.position = Vector2(i * 520.0 - 260.0, 0)
		add_child(hill)
		background_layers.append({"node": hill, "speed": 18.0 + i * 8.0, "base_y": 0.0})

func build_track():
	bug_track = Line2D.new()
	bug_track.width = 5.0
	bug_track.default_color = Color(0.2, 0.95, 1.0, 0.55)
	bug_track.add_point(Vector2(travel_left, bug_y + 30))
	bug_track.add_point(Vector2(travel_right, bug_y + 30))
	add_child(bug_track)

func build_bug():
	bug_root = Node2D.new()
	bug_root.position = Vector2(bug_x, bug_y)
	add_child(bug_root)

	bug_body = Polygon2D.new()
	bug_body.color = Color(0.2, 1.0, 0.55)
	bug_body.polygon = build_oval_polygon(34, 18, 24)
	bug_root.add_child(bug_body)

	bug_head = Polygon2D.new()
	bug_head.color = Color(0.95, 0.97, 1.0)
	bug_head.modulate = Color(1, 1, 1, 0.92)
	bug_head.polygon = build_oval_polygon(12, 10, 20)
	bug_head.position = Vector2(38, -1)
	bug_root.add_child(bug_head)

	var glow = Polygon2D.new()
	glow.color = Color(0.2, 1.0, 0.9, 0.25)
	glow.polygon = build_oval_polygon(48, 26, 24)
	glow.position = Vector2(-2, 0)
	bug_root.add_child(glow)

	for side in [-1, 1]:
		for leg_index in range(3):
			var leg = Line2D.new()
			leg.width = 3.0
			leg.default_color = Color(0.86, 1.0, 0.96, 0.8)
			var x_offset = -12 + leg_index * 10
			var y_offset = -6 + leg_index * 7
			leg.add_point(Vector2(x_offset, y_offset))
			leg.add_point(Vector2(x_offset + side * 20, y_offset + 16))
			leg.add_point(Vector2(x_offset + side * 32, y_offset + 26))
			bug_root.add_child(leg)

	var antenna_left = Line2D.new()
	antenna_left.width = 2.0
	antenna_left.default_color = Color(0.9, 1.0, 1.0, 0.65)
	antenna_left.add_point(Vector2(42, -4))
	antenna_left.add_point(Vector2(56, -22))
	antenna_left.add_point(Vector2(66, -20))
	bug_root.add_child(antenna_left)

	var antenna_right = Line2D.new()
	antenna_right.width = 2.0
	antenna_right.default_color = Color(0.9, 1.0, 1.0, 0.65)
	antenna_right.add_point(Vector2(42, 4))
	antenna_right.add_point(Vector2(56, 22))
	antenna_right.add_point(Vector2(66, 20))
	bug_root.add_child(antenna_right)

func set_audio_level(level: float):
	audio_level = clamp(level, 0.0, 1.0)

func _process(delta):
	var t = Time.get_ticks_msec() / 1000.0
	var pace = lerp(34.0, 280.0, pow(audio_level, 1.15))
	bug_x += pace * delta
	if bug_x > travel_right:
		bug_x = travel_left

	bug_root.position = Vector2(bug_x, bug_y + sin(t * 3.4) * 2.0)
	bug_root.rotation = sin(t * 0.8) * 0.02

	var gait = lerp(1.1, 5.4, audio_level)
	bug_body.scale = Vector2(1.0 + sin(t * gait) * 0.06, 1.0 - sin(t * gait) * 0.03)
	bug_head.scale = Vector2(1.0 + sin(t * gait * 1.2) * 0.04, 1.0 - sin(t * gait * 1.2) * 0.02)

	for child in bug_root.get_children():
		if child is Line2D and child.width >= 3.0:
			child.rotation = sin(t * gait * 1.2 + child.get_index()) * 0.42
		elif child is Line2D:
			child.rotation = sin(t * gait * 0.7) * 0.18

	for star in star_nodes:
		var node = star.node
		node.position.x -= star.speed * delta * (0.8 + audio_level * 0.8)
		node.position.y = star.base_y + sin(t * 0.5 + star.phase) * 3.0
		if node.position.x < -40:
			node.position.x = 1960

	for layer in background_layers:
		var node = layer.node
		node.position.x -= layer.speed * delta * (0.45 + audio_level * 0.4)
		if node.position.x < -520:
			node.position.x += 2080

	if status_label:
		status_label.text = "RUN" if audio_level > 0.38 else "WALK"

func build_oval_polygon(radius_x: float, radius_y: float, points_count: int) -> PackedVector2Array:
	var points = PackedVector2Array()
	for i in range(points_count):
		var angle = TAU * float(i) / float(points_count)
		points.append(Vector2(cos(angle) * radius_x, sin(angle) * radius_y))
	return points

func build_circle_polygon(radius: float, points_count: int) -> PackedVector2Array:
	return build_oval_polygon(radius, radius, points_count)