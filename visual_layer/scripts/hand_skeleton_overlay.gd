extends Node2D

# MediaPipe HAND_CONNECTIONS (21 landmarks, 0-indexed)
const CONNECTIONS: Array = [
	[0,1],[1,2],[2,3],[3,4],           # thumb
	[0,5],[5,6],[6,7],[7,8],           # index
	[5,9],[9,10],[10,11],[11,12],      # middle
	[9,13],[13,14],[14,15],[15,16],    # ring
	[13,17],[0,17],[17,18],[18,19],[19,20]  # pinky + palm edge
]

var show_skeleton: bool = true
var hands_data: Array = []  # Array of Array[{x,y}] — raw 0-1 normalized per hand

var _time: float = 0.0
var _no_data_timer: float = 0.0
const NO_DATA_TIMEOUT := 0.25  # seconds without a packet → clear skeleton

func _process(delta: float) -> void:
	_time += delta
	_no_data_timer += delta
	if _no_data_timer > NO_DATA_TIMEOUT:
		hands_data = []
	if show_skeleton:
		queue_redraw()

func update_hands(raw_hands: Array) -> void:
	hands_data = raw_hands
	_no_data_timer = 0.0

func _draw() -> void:
	if not show_skeleton or hands_data.is_empty():
		return

	var vp := get_viewport_rect().size

	for hand in hands_data:
		if hand.size() < 21:
			continue

		for ci in CONNECTIONS.size():
			var ai: int = CONNECTIONS[ci][0]
			var bi: int = CONNECTIONS[ci][1]

			var a_raw = hand[ai]
			var b_raw = hand[bi]
			var a_pos := Vector2(float(a_raw["x"]), float(a_raw["y"])) * vp
			var b_pos := Vector2(float(b_raw["x"]), float(b_raw["y"])) * vp

			# Flowing gradient: phase advances slowly over time;
			# each connection is offset so the colour "flows" from
			# wrist (low idx → blue-purple) toward fingertips (pink).
			var phase: float = fmod(_time * 0.18 + ci * (0.45 / float(CONNECTIONS.size())), 1.0)
			# Map phase into the blue → purple → pink hue band (0.55–0.95)
			var hue: float  = 0.55 + phase * 0.40
			var col := Color.from_hsv(hue, 0.88, 1.0, 0.38)

			draw_line(a_pos, b_pos, col, 2.5, true)

		for i in hand.size():
			var landmark = hand[i]
			var landmark_pos := Vector2(float(landmark["x"]), float(landmark["y"])) * vp
			var radius := 7.0 if i == 8 else 4.0
			var color := Color(1.0, 0.88, 0.25, 0.95) if i == 8 else Color(0.35, 0.9, 1.0, 0.85)
			draw_circle(landmark_pos, radius, color)
