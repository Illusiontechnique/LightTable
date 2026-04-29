extends Node2D

@onready var receiver = $NetworkReceiver
@onready var interaction_container = $Interactions

var simulation_mode = true

# Simple interaction visualizer (circles that appear at hand positions)
func _ready():
	receiver.interaction_received.connect(_on_interaction_received)

func _input(event):
	# Mouse simulation for testing without camera hardware
	if simulation_mode and event is InputEventMouse:
		var normalized_pos = event.position / get_viewport_rect().size
		var state = "move"
		if event is InputEventMouseButton:
			state = "press" if event.pressed else "release"
		
		# Simulate a single hand (ID 99 for simulation)
		_on_interaction_received(99, normalized_pos, state)

func _on_interaction_received(id: int, pos: Vector2, state: String):
	# Map normalized 0-1 to screen size
	var screen_pos = pos * get_viewport_rect().size
	
	var indicator = interaction_container.get_node_or_null(str(id))
	if not indicator:
		indicator = ColorRect.new()
		indicator.name = str(id)
		indicator.size = Vector2(40, 40)
		indicator.pivot_offset = Vector2(20, 20)
		interaction_container.add_child(indicator)
	
	indicator.position = screen_pos - indicator.pivot_offset
	# Pulse effect or color change on interaction could be added here
