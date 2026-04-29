extends Node2D

var letters = ["A", "B", "C", "D", "E"]
var puzzle_items = []

func _ready():
	setup_puzzle()

func setup_puzzle():
	for i in range(letters.size()):
		var letter = letters[i]
		
		# Create Outline (Target)
		var outline = Label.new()
		outline.text = letter
		outline.add_theme_font_size_override("font_size", 120)
		outline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		outline.position = Vector2(200 + i * 200, 200)
		outline.modulate = Color(1, 1, 1, 0.2) # Ghostly outline
		add_child(outline)
		
		# Create Draggable Piece
		var piece = Label.new()
		piece.text = letter
		piece.add_theme_font_size_override("font_size", 120)
		piece.position = Vector2(200 + i * 200, 600)
		piece.modulate = Color.GOLD
		piece.name = "Piece_" + letter
		add_child(piece)
		
		puzzle_items.append({"piece": piece, "target": outline, "solved": false})

func _process(_delta):
	var interactions = get_parent().get_node("Interactions")
	if not interactions: return
	
	for item in puzzle_items:
		if item.solved: continue
		
		for touch in interactions.get_children():
			var dist = touch.global_position.distance_to(item.piece.global_position + (item.piece.size / 2))
			if dist < 100:
				# Magnetically snap piece to interaction
				item.piece.global_position = touch.global_position - (item.piece.size / 2)
				
				# Check if near target
				var target_dist = item.piece.global_position.distance_to(item.target.global_position)
				if target_dist < 50:
					item.piece.global_position = item.target.global_position
					item.piece.modulate = Color.GREEN
					item.solved = true
					break
