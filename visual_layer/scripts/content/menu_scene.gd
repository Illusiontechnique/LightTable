extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN MENU  —  Two-level grid browser:  Category page → Scene page.
#
#  Interaction:  hover a hand over any card and hold still for HOLD_TIME
#  seconds.  A glowing circular arc fills around the card centre as you hold,
#  matching the mechanic used in Talk Back.  Release early to cancel.
#
#  Flow:
#    1. Category page  — 2 × 2 grid of coloured category cards.
#    2. Scene page     — row(s) of scene cards for that category, plus a Back
#                        card that returns to the category page.
#    3. Selecting a scene card calls main.load_content_scene() and exits.
# ─────────────────────────────────────────────────────────────────────────────

const HOLD_TIME   : float = 1.2   # seconds to fill the arc and trigger select
const DECAY_RATE  : float = 3.0   # how fast hold resets when hand leaves
const GAP         : float = 28.0  # pixel gap between cards
const CARD_CORNER : int   = 22    # border-radius on each card

const CATEGORIES : Array = [
	{
		"name"  : "Art & Drawing",
		"color" : Color(1.00, 0.50, 0.82),
		"scenes": [
			{"name": "Draw",         "path": "res://scripts/content/freehand_draw_scene.gd"},
			{"name": "Blob Painter", "path": "res://scripts/content/blob_painter_scene.gd"},
			{"name": "Color Trails", "path": "res://scripts/content/color_trails_scene.gd"},
			{"name": "Edge Reveal",  "path": "res://scripts/content/edge_reveal_scene.gd"},
		]
	},
	{
		"name"  : "Play",
		"color" : Color(0.45, 1.00, 0.65),
		"scenes": [
			{"name": "Balloons",       "path": "res://scripts/content/balloons_scene.gd"},
			{"name": "Bouncing Balls", "path": "res://scripts/content/bouncing_balls_scene.gd"},
			{"name": "Bug",            "path": "res://scripts/content/bug_scene.gd"},
			{"name": "Spinner",        "path": "res://scripts/content/spinner_scene.gd"},
		]
	},
	{
		"name"  : "Learn",
		"color" : Color(0.40, 0.82, 1.00),
		"scenes": [
			{"name": "Talk Back", "path": "res://scripts/content/talk_back_scene.gd"},
			{"name": "Alphabet",  "path": "res://scripts/content/alphabet_puzzle.gd"},
			{"name": "Piano",     "path": "res://scripts/content/piano_scene.gd"},
		]
	},
	{
		"name"  : "Nature",
		"color" : Color(0.38, 1.00, 0.75),
		"scenes": [
			{"name": "Water",    "path": "res://scripts/content/water_scene.gd"},
			{"name": "Galaxy",   "path": "res://scripts/content/galaxy_scene.gd"},
			{"name": "Elements", "path": "res://scripts/content/elements_scene.gd"},
		]
	},
]

# ─── runtime state ────────────────────────────────────────────────────────────

var vp_size   : Vector2
var _nav_lock : bool = false

# Per-card data — rebuilt completely on every page transition.
var _card_rects   : Array = []   # Rect2        — hit area
var _card_colors  : Array = []   # Color         — base accent
var _card_holds   : Array = []   # float 0..HOLD_TIME
var _card_actions : Array = []   # Callable      — fired on selection
var _card_styles  : Array = []   # StyleBoxFlat  — live-updated for glow

# Persistent UI nodes (survive page transitions)
var _title_lbl    : Label
var _subtitle_lbl : Label
var _card_container : Node2D   # cleared between pages
var _arc_layer      : Node2D   # drawn on top of all cards (z_index 20)


# ─── lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_add_header()

	_card_container = Node2D.new()
	_card_container.name = "CardContainer"
	add_child(_card_container)

	# Arc overlay rendered above all card panels.
	# draw_* calls happen via the 'draw' signal so they use _arc_layer's canvas.
	_arc_layer = Node2D.new()
	_arc_layer.name    = "ArcLayer"
	_arc_layer.z_index = 20
	_arc_layer.draw.connect(_draw_arcs)
	add_child(_arc_layer)

	_build_category_page()


func set_audio_level(_lvl: float) -> void:
	pass

func set_quality_level(_l: int) -> void:
	pass


# ─── static layout helpers ────────────────────────────────────────────────────

func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.02, 0.02, 0.08, 1.0)
	bg.size     = vp_size
	bg.position = Vector2.ZERO
	add_child(bg)
	move_child(bg, 0)


func _add_header() -> void:
	_title_lbl = Label.new()
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_lbl.add_theme_font_size_override("font_size", int(vp_size.y * 0.065))
	_title_lbl.size     = Vector2(vp_size.x, vp_size.y * 0.10)
	_title_lbl.position = Vector2(0.0, vp_size.y * 0.022)
	_title_lbl.modulate = Color(0.35, 0.95, 1.0)
	add_child(_title_lbl)

	_subtitle_lbl = Label.new()
	_subtitle_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_lbl.add_theme_font_size_override("font_size", int(vp_size.y * 0.028))
	_subtitle_lbl.size     = Vector2(vp_size.x, vp_size.y * 0.055)
	_subtitle_lbl.position = Vector2(0.0, vp_size.y * 0.110)
	_subtitle_lbl.modulate = Color(0.75, 0.88, 1.0, 0.78)
	add_child(_subtitle_lbl)


# ─── card management ──────────────────────────────────────────────────────────

func _clear_cards() -> void:
	for child in _card_container.get_children():
		child.queue_free()
	_card_rects.clear()
	_card_colors.clear()
	_card_holds.clear()
	_card_actions.clear()
	_card_styles.clear()
	_nav_lock = false


func _add_card(rect: Rect2, base_col: Color, label_text: String) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color                   = Color(base_col.r * 0.18, base_col.g * 0.18, base_col.b * 0.18, 0.93)
	style.corner_radius_top_left     = CARD_CORNER
	style.corner_radius_top_right    = CARD_CORNER
	style.corner_radius_bottom_left  = CARD_CORNER
	style.corner_radius_bottom_right = CARD_CORNER
	style.border_width_left   = 2
	style.border_width_top    = 2
	style.border_width_right  = 2
	style.border_width_bottom = 2
	style.border_color = Color(base_col.r, base_col.g, base_col.b, 0.45)
	style.shadow_color = Color(base_col.r, base_col.g, base_col.b, 0.20)
	style.shadow_size  = 12
	_card_styles.append(style)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.size     = rect.size
	panel.position = rect.position
	_card_container.add_child(panel)

	var fs  : int = int(min(rect.size.x * 0.14, rect.size.y * 0.18))
	var lbl := Label.new()
	lbl.text                 = label_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", fs)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.93))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.60))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.size     = rect.size - Vector2(16.0, 16.0)
	lbl.position = rect.position + Vector2(8.0, 8.0)
	_card_container.add_child(lbl)


# ─── page builders ────────────────────────────────────────────────────────────

func _build_category_page() -> void:
	_clear_cards()
	_title_lbl.text    = "LIGHT TABLE"
	_subtitle_lbl.text = "Choose a Category  —  hover and hold to select"

	var cols   : int   = 2
	var rows   : int   = 2
	var area_w : float = vp_size.x * 0.78
	var area_h : float = vp_size.y * 0.68
	var card_w : float = (area_w - GAP * (cols - 1)) / float(cols)
	var card_h : float = (area_h - GAP * (rows - 1)) / float(rows)
	var ox     : float = (vp_size.x - area_w) * 0.5
	var oy     : float = vp_size.y * 0.195

	for i in range(CATEGORIES.size()):
		var col  : int   = i % cols
		var row  : int   = i / cols
		var rect : Rect2 = Rect2(ox + col * (card_w + GAP), oy + row * (card_h + GAP), card_w, card_h)
		_card_rects.append(rect)
		_card_colors.append(CATEGORIES[i]["color"])
		_card_holds.append(0.0)
		_card_actions.append(_open_category.bind(i))
		_add_card(rect, CATEGORIES[i]["color"], CATEGORIES[i]["name"])


func _open_category(idx: int) -> void:
	_clear_cards()
	var cat    : Dictionary = CATEGORIES[idx]
	var scenes : Array      = cat["scenes"]
	_title_lbl.text    = cat["name"]
	_subtitle_lbl.text = "Choose an Activity  —  hover and hold to select"

	var n     : int = scenes.size()
	var total : int = n + 1                          # scene cards + back card
	var cols  : int = min(total, 4)
	var rows  : int = int(ceil(float(total) / float(cols)))
	var area_w : float = vp_size.x * 0.82
	var area_h : float = vp_size.y * 0.65
	var card_w : float = (area_w - GAP * (cols - 1)) / float(cols)
	var card_h : float = (area_h - GAP * (rows - 1)) / float(rows)
	var ox     : float = (vp_size.x - area_w) * 0.5
	var oy     : float = vp_size.y * 0.195

	# Scene cards
	for i in range(n):
		var col  : int   = i % cols
		var row  : int   = i / cols
		var rect : Rect2 = Rect2(ox + col * (card_w + GAP), oy + row * (card_h + GAP), card_w, card_h)
		var path : String = scenes[i]["path"]
		_card_rects.append(rect)
		_card_colors.append(cat["color"])
		_card_holds.append(0.0)
		_card_actions.append(_launch_scene.bind(path))
		_add_card(rect, cat["color"], scenes[i]["name"])

	# Back card — placed at the next grid position after the last scene card
	var bc    : int   = n % cols
	var br    : int   = n / cols
	var brect : Rect2 = Rect2(ox + bc * (card_w + GAP), oy + br * (card_h + GAP), card_w, card_h)
	var bcol  : Color = Color(0.50, 0.52, 0.65)
	_card_rects.append(brect)
	_card_colors.append(bcol)
	_card_holds.append(0.0)
	_card_actions.append(_build_category_page)
	_add_card(brect, bcol, "< Back")


func _launch_scene(path: String) -> void:
	var main := get_parent()
	if main and main.has_method("load_content_scene"):
		main.call("load_content_scene", path)


# ─── interaction loop ─────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _nav_lock:
		_arc_layer.queue_redraw()
		return

	var interactions := get_parent().get_node_or_null("Interactions")
	var pts : Array = []
	if interactions:
		for c in interactions.get_children():
			pts.append(c.global_position)

	for i in range(_card_rects.size()):
		var hovered : bool = false
		for pt in pts:
			if _card_rects[i].has_point(pt):
				hovered = true
				break

		if hovered:
			_card_holds[i] = min(_card_holds[i] + delta, HOLD_TIME)
			if _card_holds[i] >= HOLD_TIME:
				_select_card(i)
				return
		else:
			_card_holds[i] = max(0.0, _card_holds[i] - delta * DECAY_RATE)

		# Live glow: card brightens as hold accumulates
		var pct  : float = _card_holds[i] / HOLD_TIME
		var base : Color = _card_colors[i]
		var mix  : float = 0.18 + 0.42 * pct
		if i < _card_styles.size():
			_card_styles[i].bg_color     = Color(base.r * mix, base.g * mix, base.b * mix, 0.93)
			_card_styles[i].border_color = Color(base.r, base.g, base.b, 0.45 + 0.55 * pct)

	_arc_layer.queue_redraw()


func _select_card(idx: int) -> void:
	_nav_lock = true
	# Full-bright flash on the selected card
	if idx < _card_styles.size():
		_card_styles[idx].bg_color     = _card_colors[idx]
		_card_styles[idx].border_color = Color(1.0, 1.0, 1.0, 1.0)
	var action: Callable = _card_actions[idx]
	get_tree().create_timer(0.30).timeout.connect(
		func():
			if is_instance_valid(self):
				action.call()
	)


# ─── arc drawing (rendered by _arc_layer via its 'draw' signal) ───────────────

func _draw_arcs() -> void:
	for i in range(_card_rects.size()):
		if _card_holds[i] < 0.002:
			continue
		var rect   : Rect2   = _card_rects[i]
		var center : Vector2 = rect.get_center()
		var r      : float   = min(rect.size.x, rect.size.y) * 0.28
		var pct    : float   = _card_holds[i] / HOLD_TIME
		var col    : Color   = _card_colors[i]
		# Dim background ring so the fill arc reads clearly
		_arc_layer.draw_arc(center, r, 0.0, TAU, 64,
			Color(col.r * 0.25, col.g * 0.25, col.b * 0.25, 0.40), 10.0, true)
		# Fill arc (clockwise from 12-o'clock)
		_arc_layer.draw_arc(center, r, -PI * 0.5, -PI * 0.5 + TAU * pct, 64,
			Color(col.r, col.g, col.b, 0.95), 10.0, true)
