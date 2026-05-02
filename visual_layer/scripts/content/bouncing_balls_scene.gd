extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  BOUNCING BALLS  —  Top-down Air Hockey / Physics Sandbox
#
#  • Physics: 14 balls with top-down friction (no gravity).
#  • Interaction: Touch/Hand positions REPELS balls (kick force).
#  • Goals: Top and Bottom "Holes". Balls that enter are "scored" and removed.
#  • Scoring: Track goals per profile if available.
#  • Play Again: 1-second hold timer to reset the table.
# ─────────────────────────────────────────────────────────────────────────────

const NUM_BALLS    := 14
const FRICTION     := 0.985     # Per-frame velocity multiplier
const WALL_DAMP    := 0.88
const KICK_RADIUS  := 180.0     # Cursor repulsion radius (px)
const KICK_FORCE   := 1600.0    # Cursor repulsion strength
const GOAL_SIZE    := 220.0     # Width of the goal holes
const HOLD_TIME    := 1.0       # Reset timer duration

var vp_size     : Vector2
var audio_level : float = 0.0

var _balls      : Array = []
var _goals_count: int   = 0
var _reset_hold : float = 0.0
var _reset_zone : Rect2

var _score_lbl  : Label
var _hint_lbl   : Label
var _reset_btn_bg: ColorRect
var _reset_btn_lbl: Label

func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_add_goals_visuals()
	_build_ui()
	_reset_game()

func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)

func set_quality_level(_l: int) -> void:
	pass

func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.01, 0.02, 0.05, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)

	# Center line
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.05)
	line.size = Vector2(vp_size.x, 2)
	line.position = Vector2(0, vp_size.y * 0.5 - 1)
	add_child(line)

func _add_goals_visuals() -> void:
	# Goal areas at top and bottom
	for y_pos in [0.0, vp_size.y - 12.0]:
		var g := ColorRect.new()
		g.color = Color(0.12, 0.25, 0.45, 0.4)
		g.size = Vector2(GOAL_SIZE, 12)
		g.position = Vector2(vp_size.x * 0.5 - GOAL_SIZE * 0.5, y_pos)
		add_child(g)

func _build_ui() -> void:
	_score_lbl = Label.new()
	_score_lbl.add_theme_font_size_override("font_size", 42)
	_score_lbl.modulate = Color(0.3, 0.7, 1.0, 0.6)
	_score_lbl.text = "0"
	_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_lbl.size = Vector2(100, 60)
	_score_lbl.position = (vp_size * 0.5) - Vector2(50, 30)
	add_child(_score_lbl)

	_hint_lbl = Label.new()
	_hint_lbl.text = "Goal! Score by kicking balls into the blue zones"
	_hint_lbl.add_theme_font_size_override("font_size", 18)
	_hint_lbl.modulate = Color(0.3, 0.7, 1.0, 0.4)
	_hint_lbl.position = Vector2(24, 24)
	add_child(_hint_lbl)

	# Reset button (hidden until some goals are made)
	_reset_btn_bg = ColorRect.new()
	_reset_btn_bg.color = Color(0.1, 0.2, 0.3, 0.8)
	_reset_btn_bg.size = Vector2(200, 70)
	_reset_zone = Rect2(vp_size.x - 220, vp_size.y - 90, 200, 70)
	_reset_btn_bg.position = _reset_zone.position
	_reset_btn_bg.visible = false
	add_child(_reset_btn_bg)

	_reset_btn_lbl = Label.new()
	_reset_btn_lbl.text = "HOLD TO RESET"
	_reset_btn_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reset_btn_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_reset_btn_lbl.size = _reset_btn_bg.size
	_reset_btn_lbl.position = Vector2.ZERO
	_reset_btn_bg.add_child(_reset_btn_lbl)

func _reset_game() -> void:
	_goals_count = 0
	_score_lbl.text = "0"
	_reset_btn_bg.visible = false
	for b in _balls:
		if b["node"] and is_instance_valid(b["node"]): 
			b["node"].queue_free()
	_balls.clear()
	
	for i in range(NUM_BALLS):
		_create_ball(i)

func _circle_pts(r: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var a : float = TAU * float(i) / float(n)
		pts.append(Vector2(cos(a) * r, sin(a) * r))
	return pts

func _create_ball(i: int) -> void:
	var hue : float = float(i) / float(NUM_BALLS)
	var col : Color = Color.from_hsv(hue, 0.75, 0.95)
	var r   : float = randf_range(22, 36)

	var node := Polygon2D.new()
	node.polygon  = _circle_pts(r, 24)
	node.color    = col
	node.position = Vector2(randf_range(r + 40, vp_size.x - r - 40),
							randf_range(vp_size.y * 0.3, vp_size.y * 0.7))
	add_child(node)

	# Shine
	var hi := Polygon2D.new()
	hi.polygon  = _circle_pts(r * 0.35, 12)
	hi.color    = Color(1, 1, 1, 0.3)
	hi.position = Vector2(-r * 0.3, -r * 0.3)
	node.add_child(hi)

	_balls.append({
		"pos":  node.position,
		"vel":  Vector2(randf_range(-150, 150), randf_range(-150, 150)),
		"r":    r,
		"col":  col,
		"node": node,
		"scored": false
	})

func _process(delta: float) -> void:
	var interactions := get_parent().get_node_or_null("Interactions")
	var touch_positions : Array = []
	var is_resetting := false

	if interactions:
		for touch in interactions.get_children():
			var tp = touch.global_position + touch.pivot_offset
			touch_positions.append(tp)
			if _reset_btn_bg.visible and _reset_zone.has_point(tp):
				is_resetting = true

	if is_resetting:
		_reset_hold += delta
		if _reset_hold >= HOLD_TIME:
			_reset_game()
			_reset_hold = 0.0
	else:
		_reset_hold = max(0.0, _reset_hold - delta * 2.0)

	# Logic pass
	for i in range(_balls.size()):
		var b = _balls[i]
		if b["scored"]: continue

		var pos : Vector2 = b["pos"]
		var vel : Vector2 = b["vel"]
		var r   : float   = b["r"]

		# Friction
		vel *= (1.0 - (1.0 - FRICTION) * delta * 60.0)
		
		# Cursor kick
		for tp in touch_positions:
			var diff := pos - tp
			var dist := diff.length()
			if dist < KICK_RADIUS and dist > 1.0:
				var strength := (1.0 - dist / KICK_RADIUS) * KICK_FORCE
				vel += diff.normalized() * strength * delta

		pos += vel * delta

		# Boundaries & Goals
		var in_goal_x = (pos.x > vp_size.x * 0.5 - GOAL_SIZE * 0.5) and (pos.x < vp_size.x * 0.5 + GOAL_SIZE * 0.5)
		
		# Top Wall / Goal
		if pos.y - r < 0:
			if in_goal_x:
				_score_goal(i)
				continue
			else:
				pos.y = r; vel.y = abs(vel.y) * WALL_DAMP
		# Bottom Wall / Goal
		elif pos.y + r > vp_size.y:
			if in_goal_x:
				_score_goal(i)
				continue
			else:
				pos.y = vp_size.y - r; vel.y = -abs(vel.y) * WALL_DAMP
		
		# Side Walls
		if pos.x - r < 0:
			pos.x = r; vel.x = abs(vel.x) * WALL_DAMP
		elif pos.x + r > vp_size.x:
			pos.x = vp_size.x - r; vel.x = -abs(vel.x) * WALL_DAMP

		b["pos"] = pos
		b["vel"] = vel
		b["node"].position = pos
		_balls[i] = b

	# Collisions
	for i in range(_balls.size()):
		var bi = _balls[i]
		if bi["scored"]: continue
		for j in range(i + 1, _balls.size()):
			var bj = _balls[j]
			if bj["scored"]: continue
			
			var diff := bj["pos"] - bi["pos"]
			var dist := diff.length()
			var min_d := bi["r"] + bj["r"]
			if dist < min_d and dist > 0.1:
				var n := diff / dist
				var pen := (min_d - dist) * 0.5
				bi["pos"] -= n * pen
				bj["pos"] += n * pen
				
				var v_rel := bj["vel"] - bi["vel"]
				var v_sep := v_rel.dot(n)
				if v_sep < 0:
					var imp := -1.8 * v_sep * 0.5
					bi["vel"] -= n * imp
					bj["vel"] += n * imp
					_spawn_bang(bi["pos"] + n * bi["r"], bi["col"])

	queue_redraw()

func _score_goal(idx: int) -> void:
	var b = _balls[idx]
	b["scored"] = true
	_goals_count += 1
	_score_lbl.text = str(_goals_count)
	
	# Entrance effect
	var tween := get_tree().create_tween()
	tween.tween_property(b["node"], "scale", Vector2.ZERO, 0.3)
	tween.finished.connect(b["node"].queue_free)
	
	_reset_btn_bg.visible = true

func _spawn_bang(at: Vector2, col: Color) -> void:
	var bang := Polygon2D.new()
	bang.polygon  = _circle_pts(1, 8)
	bang.position = at
	bang.color    = col
	bang.modulate.a = 0.8
	add_child(bang)
	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(bang, "scale", Vector2(40, 40), 0.25)
	tween.tween_property(bang, "modulate:a", 0.0, 0.25)
	tween.finished.connect(bang.queue_free)

func _draw() -> void:
	# Reset timer bar
	if _reset_hold > 0.001:
		var pct = _reset_hold / HOLD_TIME
		var r = _reset_zone
		draw_rect(Rect2(r.position.x, r.position.y + r.size.y - 5, r.size.x * pct, 5), Color(0.32, 0.8, 1.0))
