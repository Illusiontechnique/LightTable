extends Node2D

@export var key_width = 80
@export var white_keys = 12
@export var base_freq = 261.63 # Middle C

func _ready():
	setup_piano()

func setup_piano():
	# Create white keys
	for i in range(white_keys):
		var key = ColorRect.new()
		key.name = "Key_" + str(i)
		key.size = Vector2(key_width - 2, 400)
		key.position = Vector2(i * key_width, 200)
		key.color = Color.WHITE
		add_child(key)
		
		# Add a label for the note
		var label = Label.new()
		label.text = get_note_name(i)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = Vector2(0, 350)
		label.size = Vector2(key_width, 30)
		label.modulate = Color.BLACK
		key.add_child(label)

func _process(_delta):
	# Check interactions from the main script (via parent or global)
	# For now, we'll assume the main script passes interactions down or we check the 'Interactions' container
	var interactions = get_parent().get_node("Interactions")
	if not interactions: return
	
	for key in get_children():
		if not key is ColorRect: continue
		
		var pressed = false
		for touch in interactions.get_children():
			if key.get_global_rect().has_point(touch.global_position):
				pressed = true
				break
		
		if pressed:
			key.color = Color.AQUAMARINE
			# In a real app, we'd trigger an AudioStreamPlayer here
		else:
			key.color = Color.WHITE

func get_note_name(index):
	var notes = ["C", "D", "E", "F", "G", "A", "B"]
	return notes[index % 7] + str(4 + index / 7)
