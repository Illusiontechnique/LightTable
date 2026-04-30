extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  BLOB PAINTER  —  best used with Blob tracker
#
#  Each blob leaves a fluid ink trail of filled circles that slowly fades.
#  Colour is determined by position on the canvas (hue map).
#  Blob size from CV drives the brush radius.
#  Audio level adds a "splatter" burst of extra dots on beats.
# ─────────────────────────────────────────────────────────────────────────────

const MAX_INK_DOTS := 600    # total dots before oldest is recycled
const FADE_RATE    := 0.18   # alpha lost per second

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _prev_audio : float = 0.0
var _beat_cool  : float = 0.0

# Ring-buffer of ink dots (ColorRect nodes)
var _dots    : Array  = []
var _dot_idx : int    = 0
var _dot_ages: Array  = []   # current alpha per slot

# Per-touch last position for distance gating
var _prev_touch : Dictionary = {}

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_add_labels()
	# Pre-allocate dot pool
	for i in range(MAX_INK_DOTS):
		var d := ColorRect.new()
		d.size       = Vector2(1, 1)
		d.position   = Vector2(-20, -20)
		d.pivot_offset = Vector2(0.5, 0.5)
		d.color      = Color(0, 0, 0, 0)
		d.visible    = false
		add_child(d)
		_dots.append(d)
		_dot_ages.append(0.0)


func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.0, 0.0, 0.0, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)


func _add_labels() -> void:
	var t := Label.new()
	t.text = "BLOB PAINTER"
	t.add_theme_font_size_override("font_size", 34)
	t.modulate = Color(1.0, 0.9, 0.75)
	t.position = Vector2(24, 18)
	add_child(t)
	var s := Label.new()
	s.text = "Blob tracker · hand / object paints the canvas · audio splatters"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(1.0, 0.9, 0.75, 0.75)
	s.position = Vector2(24, 58)
	add_child(s)

# ─────────────────────────────────────────────────────────────────────────────

func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func _stamp_dot(pos: Vector2, radius: float, col: Color) -> void:
	var d   : ColorRect = _dots[_dot_idx]
	var r   : float     = max(2.0, radius)
	d.size          = Vector2(r * 2.0, r * 2.0)
	d.pivot_offset  = Vector2(r, r)
	d.position      = pos - Vector2(r, r)
	d.color         = col
	d.visible       = true
	_dot_ages[_dot_idx] = col.a
	_dot_idx = (_dot_idx + 1) % MAX_INK_DOTS


func _pos_to_color(pos: Vector2, alpha: float) -> Color:
	var hue : float = fmod(pos.x / vp_size.x + pos.y / vp_size.y * 0.5, 1.0)
	return Color.from_hsv(hue, 0.85, 1.0, alpha)

# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_audio_sm   = lerp(_audio_sm,   audio_level, delta * 8.0)
	_beat_cool -= delta

	# Beat detection: sudden audio rise triggers splatter
	var audio_rise : float = _audio_sm - _prev_audio
	_prev_audio = _audio_sm
	if audio_rise > 0.08 and _beat_cool <= 0.0:
		_beat_cool = 0.35
		_do_splatter()

	# ── Fade all dots ──────────────────────────────────────────────────
	for i in range(MAX_INK_DOTS):
		if _dot_ages[i] > 0.0:
			_dot_ages[i] = max(0.0, _dot_ages[i] - FADE_RATE * delta)
			var d : ColorRect = _dots[i]
			d.color.a = _dot_ages[i]
			if _dot_ages[i] <= 0.0:
				d.visible = false

	# ── Paint from touches ─────────────────────────────────────────────
	var interactions := get_parent().get_node_or_null("Interactions")
	if not interactions:
		return

	var active : Dictionary = {}
	for touch in interactions.get_children():
		var id  : int     = touch.get_instance_id()
		var sp  : Vector2 = touch.position + touch.pivot_offset
		active[id] = true

		var gate : float = 8.0   # pixels before new dot
		if _prev_touch.has(id):
			if sp.distance_to(_prev_touch[id]) < gate:
				continue
		_prev_touch[id] = sp

		var base_r   : float = 14.0 + _audio_sm * 22.0
		var col_full : Color = _pos_to_color(sp, 0.82 + _audio_sm * 0.18)
		_stamp_dot(sp, base_r, col_full)

		# Surrounding soft halo
		for _i in range(3):
			var offset := Vector2(randf_range(-base_r, base_r), randf_range(-base_r, base_r))
			_stamp_dot(sp + offset, base_r * 0.45, _pos_to_color(sp, 0.28))

	# Prune lifted touches
	var to_rm : Array = []
	for id in _prev_touch:
		if not active.has(id):
			to_rm.append(id)
	for id in to_rm:
		_prev_touch.erase(id)


func _do_splatter() -> void:
	# Scatter dots at random positions weighted toward screen centre
	var cx : float = vp_size.x * 0.5
	var cy : float = vp_size.y * 0.5
	for _i in range(18):
		var spread  : float   = randf_range(80.0, 500.0)
		var angle   : float   = randf_range(0.0, TAU)
		var pos     : Vector2 = Vector2(cx + cos(angle) * spread, cy + sin(angle) * spread)
		var r       : float   = randf_range(4.0, 24.0)
		_stamp_dot(pos, r, _pos_to_color(pos, randf_range(0.4, 0.9)))
