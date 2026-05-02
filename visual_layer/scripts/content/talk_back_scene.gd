extends Node2D

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  TALK BACK  â€”  Browse Aâ€“Z one letter at a time.
#
#  Each letter is shown large with its example word.
#  Navigation: hold your hand inside the LEFT or RIGHT zone for 1 second to
#  move to the previous / next letter.  Loops A â†’ Z â†’ A.
#  A gentle countdown arc fills as you hold.
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

const SAMPLE_RATE : float = 44100.0
const HOLD_TIME   : float = 1.0    # seconds to hold before navigating

const LETTERS : Array = [
	"A","B","C","D","E","F","G",
	"H","I","J","K","L","M","N",
	"O","P","Q","R","S","T","U",
	"V","W","X","Y","Z",
]

const WORDS : Array = [
	"Apple","Balloon","Cat","Dog","Elephant","Fish","Goat",
	"Hat","Ice","Jar","Kite","Lion","Moon","Nest",
	"Orange","Piano","Queen","Rain","Sun","Tree","Umbrella",
	"Vine","Water","Xray","Yellow","Zebra",
]

const C4      : float = 261.63
const SEMITONE: float = 1.05946309436

var vp_size     : Vector2
var audio_level : float = 0.0

var _current_idx : int   = 0
var _left_hold   : float = 0.0
var _right_hold  : float = 0.0
var _nav_lock    : bool  = false

var _left_zone  : Rect2
var _right_zone : Rect2

var _letter_lbl : Label
var _word_lbl   : Label
var _index_lbl  : Label
var _left_bg    : ColorRect
var _right_bg   : ColorRect
var _left_hint  : Label
var _right_hint : Label

var _voice : AudioStreamPlayer = null


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_build_center()
	_build_nav_zones()
	_show(_current_idx)


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func set_quality_level(_l: int) -> void:
	pass


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.02, 0.02, 0.07, 1.0)
	bg.size     = vp_size
	bg.position = Vector2.ZERO
	add_child(bg)
	move_child(bg, 0)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _build_center() -> void:
	var zone_w : float = vp_size.x * 0.20

	_letter_lbl = Label.new()
	_letter_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_letter_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_letter_lbl.add_theme_font_size_override("font_size", int(vp_size.y * 0.44))
	_letter_lbl.size     = Vector2(vp_size.x - zone_w * 2.0, vp_size.y * 0.56)
	_letter_lbl.position = Vector2(zone_w, vp_size.y * 0.08)
	add_child(_letter_lbl)

	_word_lbl = Label.new()
	_word_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_word_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_word_lbl.add_theme_font_size_override("font_size", int(vp_size.y * 0.086))
	_word_lbl.size     = Vector2(vp_size.x - zone_w * 2.0, vp_size.y * 0.14)
	_word_lbl.position = Vector2(zone_w, vp_size.y * 0.67)
	add_child(_word_lbl)

	_index_lbl = Label.new()
	_index_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_index_lbl.add_theme_font_size_override("font_size", 22)
	_index_lbl.modulate = Color(0.6, 0.65, 0.80, 0.70)
	_index_lbl.size     = Vector2(vp_size.x - zone_w * 2.0, 36)
	_index_lbl.position = Vector2(zone_w, vp_size.y * 0.88)
	add_child(_index_lbl)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _build_nav_zones() -> void:
	var zone_w : float = vp_size.x * 0.20
	var zone_h : float = vp_size.y * 0.60
	var zone_y : float = (vp_size.y - zone_h) * 0.5

	_left_zone  = Rect2(0,                   zone_y, zone_w, zone_h)
	_right_zone = Rect2(vp_size.x - zone_w,  zone_y, zone_w, zone_h)

	_left_bg = ColorRect.new()
	_left_bg.color    = Color(0.08, 0.14, 0.30, 0.42)
	_left_bg.size     = Vector2(zone_w, zone_h)
	_left_bg.position = Vector2(0, zone_y)
	add_child(_left_bg)

	_right_bg = ColorRect.new()
	_right_bg.color    = Color(0.08, 0.14, 0.30, 0.42)
	_right_bg.size     = Vector2(zone_w, zone_h)
	_right_bg.position = Vector2(vp_size.x - zone_w, zone_y)
	add_child(_right_bg)

	_left_hint = Label.new()
	_left_hint.text = "< Prev"
	_left_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_left_hint.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_left_hint.add_theme_font_size_override("font_size", int(zone_w * 0.42))
	_left_hint.size     = Vector2(zone_w, zone_h)
	_left_hint.position = Vector2(0, zone_y)
	_left_hint.modulate = Color(0.65, 0.80, 1.0, 0.65)
	add_child(_left_hint)

	_right_hint = Label.new()
	_right_hint.text = "Next >"
	_right_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_right_hint.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_right_hint.add_theme_font_size_override("font_size", int(zone_w * 0.42))
	_right_hint.size     = Vector2(zone_w, zone_h)
	_right_hint.position = Vector2(vp_size.x - zone_w, zone_y)
	_right_hint.modulate = Color(0.65, 0.80, 1.0, 0.65)
	add_child(_right_hint)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _show(idx: int) -> void:
	var hue : float = float(idx) / 26.0
	var col : Color = Color.from_hsv(hue, 0.88, 1.00)
	_letter_lbl.text     = LETTERS[idx]
	_letter_lbl.modulate = col
	_word_lbl.text       = WORDS[idx]
	_word_lbl.modulate   = Color(col.r * 0.75 + 0.25, col.g * 0.75 + 0.25, col.b * 0.75 + 0.25, 0.90)
	_index_lbl.text      = str(idx + 1) + "  /  26"
	_play_tone(idx)


func _navigate(dir: int) -> void:
	_current_idx = (_current_idx + dir + LETTERS.size()) % LETTERS.size()
	_show(_current_idx)
	_left_hold  = 0.0
	_right_hold = 0.0
	_nav_lock   = true
	get_tree().create_timer(0.55).timeout.connect(func(): _nav_lock = false)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  Audio
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _play_tone(idx: int) -> void:
	if _voice and is_instance_valid(_voice):
		_voice.queue_free()
	var player := AudioStreamPlayer.new()
	var stream := AudioStreamGenerator.new()
	stream.mix_rate      = SAMPLE_RATE
	stream.buffer_length = 0.70
	player.stream    = stream
	player.volume_db = -6.0
	add_child(player)
	player.play()
	_voice = player

	var pb   : AudioStreamGeneratorPlayback = player.get_stream_playback()
	var freq : float = C4 * pow(SEMITONE, float(idx))
	var n    : int   = int(SAMPLE_RATE * 0.60)
	var ph1  : float = 0.0
	var ph2  : float = 0.0
	var ph3  : float = 0.0

	for i in range(n):
		var t   : float = float(i) / SAMPLE_RATE
		var env : float
		if t < 0.005:
			env = t / 0.005
		elif t < 0.08:
			env = lerp(1.0, 0.55, (t - 0.005) / 0.075)
		else:
			env = 0.55 * exp(-(t - 0.08) * 3.2)
		var s : float = (sin(ph1) * 0.65 + sin(ph2) * 0.28 + sin(ph3) * 0.10) * env * 0.30
		pb.push_frame(Vector2(s, s))
		ph1 += TAU * freq / SAMPLE_RATE
		ph2 += TAU * freq * 2.0 / SAMPLE_RATE
		ph3 += TAU * freq * 3.0 / SAMPLE_RATE
		if ph1 > TAU: ph1 -= TAU
		if ph2 > TAU: ph2 -= TAU
		if ph3 > TAU: ph3 -= TAU

	get_tree().create_timer(0.75).timeout.connect(player.queue_free)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  Countdown arc overlay
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _draw() -> void:
	var arc_r : float = _left_zone.size.x * 0.36

	if _left_hold > 0.001:
		var lc  : Vector2 = _left_zone.get_center()
		var pct : float   = _left_hold / HOLD_TIME
		draw_arc(lc, arc_r, -PI * 0.5, -PI * 0.5 + TAU * pct, 48,
				Color(0.45, 0.80, 1.0, 0.90), 7.0, true)

	if _right_hold > 0.001:
		var rc  : Vector2 = _right_zone.get_center()
		var pct : float   = _right_hold / HOLD_TIME
		draw_arc(rc, arc_r, -PI * 0.5, -PI * 0.5 + TAU * pct, 48,
				Color(1.0, 0.65, 0.35, 0.90), 7.0, true)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _process(delta: float) -> void:
	var interactions := get_parent().get_node_or_null("Interactions")
	var in_left  : bool = false
	var in_right : bool = false

	if interactions and not _nav_lock:
		for touch in interactions.get_children():
			var tp : Vector2 = touch.global_position
			if _left_zone.has_point(tp):
				in_left = true
			if _right_zone.has_point(tp):
				in_right = true

	if in_left:
		_left_hold = min(_left_hold + delta, HOLD_TIME)
		if _left_hold >= HOLD_TIME:
			_navigate(-1)
	else:
		_left_hold = max(0.0, _left_hold - delta * 3.0)

	if in_right:
		_right_hold = min(_right_hold + delta, HOLD_TIME)
		if _right_hold >= HOLD_TIME:
			_navigate(1)
	else:
		_right_hold = max(0.0, _right_hold - delta * 3.0)

	# Zone glow feedback
	_left_bg.color  = Color(0.08 + _left_hold * 0.18,  0.14, 0.30 + _left_hold * 0.28, 0.42 + _left_hold  * 0.38)
	_right_bg.color = Color(0.08 + _right_hold * 0.18, 0.14, 0.30 + _right_hold * 0.28, 0.42 + _right_hold * 0.38)
	_left_hint.modulate  = Color(0.65 + _left_hold  * 0.35, 0.80, 1.0, 0.65 + _left_hold  * 0.35)
	_right_hint.modulate = Color(0.65 + _right_hold * 0.35, 0.80, 1.0, 0.65 + _right_hold * 0.35)

	queue_redraw()
