extends Node2D

var balloons = []
var colors = [Color(0.15, 1.0, 0.95), Color(1.0, 0.24, 0.78), Color(1.0, 0.92, 0.2), Color(0.45, 0.95, 0.3), Color(0.95, 0.55, 1.0)]

func _ready():
	add_header()
	add_dark_backdrop()
	for i in range(10):
		spawn_balloon()

func add_header():
	var title = Label.new()
	title.text = "BALLOONS / POP THEM"
	title.add_theme_font_size_override("font_size", 34)
	title.modulate = Color(1, 1, 1)
	title.position = Vector2(24, 18)
	add_child(title)

	var subtitle = Label.new()
	subtitle.text = "dark stage / vivid balloons / pop animation"
	subtitle.add_theme_font_size_override("font_size", 15)
	subtitle.modulate = Color(0.85, 0.92, 1.0, 0.85)
	subtitle.position = Vector2(24, 56)
	add_child(subtitle)

func add_dark_backdrop():
	var backdrop = ColorRect.new()
	backdrop.color = Color(0.02, 0.02, 0.04, 1.0)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	move_child(backdrop, 0)

func spawn_balloon():
	var balloon_root = Node2D.new()
	balloon_root.name = "Balloon_%d" % balloons.size()
	balloon_root.position = Vector2(randf_range(100, 1100), randf_range(760, 960))
	balloon_root.scale = Vector2(randf_range(0.9, 1.2), randf_range(1.0, 1.35))
	add_child(balloon_root)

	var body = Polygon2D.new()
	body.color = colors[randi() % colors.size()]
	body.polygon = build_oval_polygon(28, 36, 28)
	body.modulate = Color(1, 1, 1, 0.98)
	balloon_root.add_child(body)

	var highlight = Polygon2D.new()
	highlight.color = Color(1, 1, 1, 0.2)
	highlight.polygon = PackedVector2Array([Vector2(-10, -18), Vector2(-5, -24), Vector2(-2, 8), Vector2(-8, 10)])
	highlight.position = Vector2(-7, -5)
	balloon_root.add_child(highlight)

	var knot = Polygon2D.new()
	knot.color = Color(0.08, 0.08, 0.1, 0.95)
	knot.polygon = PackedVector2Array([Vector2(-4, 0), Vector2(4, 0), Vector2(3, 8), Vector2(-3, 8)])
	knot.position = Vector2(0, 40)
	balloon_root.add_child(knot)

	var string = Line2D.new()
	string.add_point(Vector2(0, 44))
	string.add_point(Vector2(0, 112))
	string.width = 2.0
	string.default_color = Color(1, 1, 1, 0.72)
	balloon_root.add_child(string)

	balloons.append({
		"node": balloon_root,
		"speed": randf_range(35, 110),
		"sway": randf_range(0.7, 2.2),
		"phase": randf_range(0.0, TAU),
		"radius": 45.0
	})

func build_oval_polygon(radius_x: float, radius_y: float, points_count: int) -> PackedVector2Array:
	var points = PackedVector2Array()
	for i in range(points_count):
		var angle = TAU * float(i) / float(points_count)
		points.append(Vector2(cos(angle) * radius_x, sin(angle) * radius_y))
	return points

func _process(delta):
	var interactions = get_parent().get_node("Interactions")
	var time_now = Time.get_ticks_msec() / 1000.0
	
	for i in range(balloons.size() - 1, -1, -1):
		var b = balloons[i]
		b.node.position.y -= b.speed * delta
		b.node.position.x += sin(time_now * b.sway + b.phase) * 10.0 * delta
		b.node.rotation = sin(time_now * 0.9 + b.phase) * 0.04
		b.node.scale.y = 1.0 + sin(time_now * 2.0 + b.phase) * 0.02
		
		# Reset if off screen
		if b.node.position.y < -150:
			b.node.position.y = 920
			b.node.position.x = randf_range(100, 1000)
		
		# Check for pop
		if interactions:
			for touch in interactions.get_children():
				if b.node.global_position.distance_to(touch.global_position) < b.radius:
					pop_balloon(i)
					break

func pop_balloon(index):
	var b = balloons[index]
	create_pop_flash(b.node.global_position)
	# Simple pop effect: expansion and fade
	var tween = create_tween()
	tween.tween_property(b.node, "scale", b.node.scale * Vector2(1.25, 1.45), 0.06)
	tween.tween_property(b.node, "scale", b.node.scale * Vector2(2.0, 2.2), 0.08)
	tween.parallel().tween_property(b.node, "modulate:a", 0.0, 0.12)
	tween.tween_callback(b.node.queue_free)
	balloons.remove_at(index)
	
	# Respawn after a delay
	get_tree().create_timer(1.0).timeout.connect(spawn_balloon)

func create_pop_flash(pos: Vector2):
	var flash = Line2D.new()
	flash.default_color = Color(1.0, 1.0, 1.0, 0.85)
	flash.width = 4.0
	for i in range(24):
		var angle = TAU * float(i) / 24.0
		flash.add_point(Vector2(cos(angle), sin(angle)) * 4.0)
	flash.closed = true
	flash.position = pos
	add_child(flash)

	var flash_tween = create_tween()
	flash_tween.tween_property(flash, "scale", Vector2(5, 5), 0.12)
	flash_tween.parallel().tween_property(flash, "modulate:a", 0.0, 0.12)
	flash_tween.tween_callback(flash.queue_free)
