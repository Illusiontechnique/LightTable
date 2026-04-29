extends Node2D

var balloons = []
var colors = [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.PURPLE]

func _ready():
	for i in range(10):
		spawn_balloon()

func spawn_balloon():
	var b = ColorRect.new()
	b.size = Vector2(80, 100)
	# Make it look like a balloon (rounded-ish)
	b.color = colors[randi() % colors.size()]
	b.position = Vector2(randf_range(100, 1000), 800)
	add_child(b)
	
	# Add a string
	var line = Line2D.new()
	line.add_point(Vector2(40, 100))
	line.add_point(Vector2(40, 150))
	line.width = 2.0
	b.add_child(line)
	
	balloons.append({"node": b, "speed": randf_range(50, 150)})

func _process(delta):
	var interactions = get_parent().get_node("Interactions")
	
	for i in range(balloons.size() - 1, -1, -1):
		var b = balloons[i]
		b.node.position.y -= b.speed * delta
		
		# Reset if off screen
		if b.node.position.y < -150:
			b.node.position.y = 900
			b.node.position.x = randf_range(100, 1000)
		
		# Check for pop
		if interactions:
			for touch in interactions.get_children():
				if b.node.get_global_rect().has_point(touch.global_position):
					pop_balloon(i)
					break

func pop_balloon(index):
	var b = balloons[index]
	# Simple pop effect: expansion and fade
	var tween = create_tween()
	tween.tween_property(b.node, "scale", Vector2(2, 2), 0.1)
	tween.parallel().tween_property(b.node, "modulate:a", 0.0, 0.1)
	tween.tween_callback(b.node.queue_free)
	balloons.remove_at(index)
	
	# Respawn after a delay
	get_tree().create_timer(1.0).timeout.connect(spawn_balloon)
