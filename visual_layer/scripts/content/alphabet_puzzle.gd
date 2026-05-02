extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  ALPHABET  —  Touch A → Z in order.
#  Aurora background + soft-edge vignette.  ABC-song note per correct touch.
# ─────────────────────────────────────────────────────────────────────────────

const SAMPLE_RATE := 44100.0
const NOTE_DUR_S  := 0.55   # seconds of sound per note

# ABC-song melody — one frequency per letter A–Z
const NOTE_FREQS := [
	523.25, 523.25, 783.99, 783.99, 880.00, 880.00, 783.99,  # A B C D E F G
	698.46, 698.46, 659.25, 659.25, 587.33, 587.33, 523.25,  # H I J K L M N
	783.99, 783.99, 698.46, 698.46, 659.25, 659.25, 587.33,  # O P Q R S T U
	783.99, 783.99, 698.46, 659.25, 523.25,                   # V W X Y Z
]

const GREY := Color(0.28, 0.28, 0.36, 0.72)

const LIT_PALETTE := [
	Color(0.28, 0.92, 1.00),   # cyan
	Color(0.60, 0.42, 1.00),   # violet
	Color(0.22, 1.00, 0.62),   # mint
	Color(1.00, 0.48, 0.85),   # pink
	Color(1.00, 0.90, 0.28),   # gold
	Color(0.48, 1.00, 0.80),   # seafoam
]

# Four rows matching the ABC-song phrases
const ROWS := [
	["A","B","C","D","E","F","G"],
	["H","I","J","K","L","M","N"],
	["O","P","Q","R","S","T","U"],
	["V","W","X","Y","Z"],
]

# Aurora band params [base_y_norm, half_height_norm, hue°, drift_speed, wave_amp_norm]
const AURORA_BANDS := [
	[0.16, 0.14, 162.0, 0.38, 0.052],
	[0.34, 0.11, 188.0, 0.53, 0.040],
	[0.06, 0.13, 270.0, 0.30, 0.060],
	[0.46, 0.10, 205.0, 0.46, 0.036],
]

var vp_size: Vector2
var _next_idx: int = 0
var _labels: Array  = []    # Label per letter (26)
var _lit: Array     = []    # bool per letter
var _glow_t: Array  = []    # seconds since lit (drives pulse animation)
var _prev_touch_on: Dictionary = {}  # touch_id → letter_idx last frame

var _aurora_t: float = 0.0
var _hud: Label
var _done: bool = false

var _voice: AudioStreamPlayer
var _note_queue: Array = []   # [{freq, total, remaining, phase}]


# ─────────────────────────────────────────────────────────────────────────────
#  Ready
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	vp_size = get_viewport_rect().size
	_setup_voice()
	_build_letters()
	_build_hud()


# ─────────────────────────────────────────────────────────────────────────────
#  Audio  —  sine-wave note bursts fed into AudioStreamGenerator
# ─────────────────────────────────────────────────────────────────────────────
func _setup_voice() -> void:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate      = SAMPLE_RATE
	stream.buffer_length = NOTE_DUR_S + 0.12
	_voice = AudioStreamPlayer.new()
	_voice.stream    = stream
	_voice.volume_db = -6.0
	add_child(_voice)
	_voice.play()


func _queue_note(freq: float) -> void:
	_note_queue.append({
		"freq":      freq,
		"total":     int(SAMPLE_RATE * NOTE_DUR_S),
		"remaining": int(SAMPLE_RATE * NOTE_DUR_S),
		"phase":     0.0,
	})


func _fill_audio() -> void:
	var pb := _voice.get_stream_playback() as AudioStreamGeneratorPlayback
	if not pb:
		return
	var to_fill := pb.get_frames_available()
	for _i in to_fill:
		var s := 0.0
		for note in _note_queue:
			if note["remaining"] <= 0:
				continue
			var elapsed := float(note["total"] - note["remaining"]) / SAMPLE_RATE
			var env: float = exp(-elapsed * 3.2) * min(1.0, elapsed * 60.0)
			note["phase"] += TAU * note["freq"] / SAMPLE_RATE
			if note["phase"] > TAU:
				note["phase"] -= TAU
			s += (sin(note["phase"]) * 0.65 + sin(note["phase"] * 2.0) * 0.18) * env * 0.44
			note["remaining"] -= 1
		pb.push_frame(Vector2(s, s))
	_note_queue = _note_queue.filter(func(n): return n["remaining"] > 0)


# ─────────────────────────────────────────────────────────────────────────────
#  Letter grid  —  4 rows (7 / 7 / 7 / 5), centred
# ─────────────────────────────────────────────────────────────────────────────
func _build_letters() -> void:
	var font_sz := int(vp_size.x * 0.072)
	var cell_w  := vp_size.x / 8.0
	var cell_h  := vp_size.y / 5.5
	var start_y := vp_size.y * 0.15

	for row_i in ROWS.size():
		var row   : Array = ROWS[row_i]
		var row_w := row.size() * cell_w
		var ox    := (vp_size.x - row_w) * 0.5
		var cy    := start_y + row_i * cell_h

		for col_i in row.size():
			var lbl := Label.new()
			lbl.text = row[col_i]
			lbl.add_theme_font_size_override("font_size", font_sz)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
			lbl.size     = Vector2(cell_w, cell_h)
			lbl.position = Vector2(ox + col_i * cell_w, cy - cell_h * 0.5)
			lbl.modulate = GREY
			add_child(lbl)
			_labels.append(lbl)
			_lit.append(false)
			_glow_t.append(0.0)


func _build_hud() -> void:
	_hud = Label.new()
	_hud.text = "Touch   A   first"
	_hud.add_theme_font_size_override("font_size", 30)
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.modulate = Color(1.0, 1.0, 1.0, 0.80)
	_hud.size     = Vector2(vp_size.x, 60)
	_hud.position = Vector2(0, vp_size.y * 0.89)
	add_child(_hud)


# ─────────────────────────────────────────────────────────────────────────────
#  Aurora background + vignette  —  drawn every frame via _draw()
# ─────────────────────────────────────────────────────────────────────────────
func _draw() -> void:
	# 1. Deep-space base
	draw_rect(Rect2(Vector2.ZERO, vp_size), Color(0.01, 0.015, 0.04, 1.0))

	# 2. Aurora bands — two gradient quads each (transparent→peak, peak→transparent)
	for band in AURORA_BANDS:
		var base_y : float = band[0]
		var h_half : float = band[1]
		var hue    : float = band[2] / 360.0
		var speed  : float = band[3]
		var amp    : float = band[4]

		var wave  := sin(_aurora_t * speed + base_y * 10.0) * amp
		var cy    := (base_y + wave) * vp_size.y
		var bh    := h_half * vp_size.y
		var alpha := 0.15 + 0.07 * sin(_aurora_t * speed * 1.4 + base_y * 6.0)

		var c_peak  := Color.from_hsv(hue, 0.82, 1.00, alpha)
		var c_clear := Color(0.0, 0.0, 0.0, 0.0)

		# Upper half: transparent → peak
		draw_polygon(
			PackedVector2Array([
				Vector2(0,         cy - bh),
				Vector2(vp_size.x, cy - bh),
				Vector2(vp_size.x, cy),
				Vector2(0,         cy),
			]),
			PackedColorArray([c_clear, c_clear, c_peak, c_peak])
		)
		# Lower half: peak → transparent
		draw_polygon(
			PackedVector2Array([
				Vector2(0,         cy),
				Vector2(vp_size.x, cy),
				Vector2(vp_size.x, cy + bh),
				Vector2(0,         cy + bh),
			]),
			PackedColorArray([c_peak, c_peak, c_clear, c_clear])
		)

	# 3. Soft-edge vignette
	_draw_vignette()


func _draw_vignette() -> void:
	var w  := vp_size.x
	var h  := vp_size.y
	var fh := h * 0.22   # vertical fade depth
	var fw := w * 0.14   # horizontal fade depth
	var vk := Color(0.0, 0.0, 0.0, 0.80)
	var vd := Color(0.0, 0.0, 0.0, 0.0)

	# Top
	draw_polygon(
		PackedVector2Array([Vector2(0,0),    Vector2(w,0),    Vector2(w,fh),   Vector2(0,fh)]),
		PackedColorArray([vk, vk, vd, vd])
	)
	# Bottom
	draw_polygon(
		PackedVector2Array([Vector2(0,h-fh), Vector2(w,h-fh), Vector2(w,h),    Vector2(0,h)]),
		PackedColorArray([vd, vd, vk, vk])
	)
	# Left
	draw_polygon(
		PackedVector2Array([Vector2(0,0),    Vector2(fw,0),   Vector2(fw,h),   Vector2(0,h)]),
		PackedColorArray([vk, vd, vd, vk])
	)
	# Right
	draw_polygon(
		PackedVector2Array([Vector2(w-fw,0), Vector2(w,0),    Vector2(w,h),    Vector2(w-fw,h)]),
		PackedColorArray([vd, vk, vk, vd])
	)


# ─────────────────────────────────────────────────────────────────────────────
#  Main loop
# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_aurora_t += delta
	queue_redraw()
	_fill_audio()

	# Pulse animation on lit letters
	for i in _labels.size():
		if not _lit[i]:
			continue
		_glow_t[i] += delta
		var pulse := 1.0 + 0.10 * sin(_glow_t[i] * 3.8)
		var base: Color = LIT_PALETTE[i % LIT_PALETTE.size()]
		_labels[i].modulate = Color(base.r * pulse, base.g * pulse, base.b * pulse, 1.0)

	if _done:
		return

	_check_touches()


func _check_touches() -> void:
	var interactions := get_parent().get_node_or_null("Interactions")
	if not interactions:
		return

	var hit_radius := vp_size.x * 0.048
	var current_map: Dictionary = {}

	for touch in interactions.get_children():
		var tp: Vector2 = touch.global_position
		var best  := -1
		var bdist := hit_radius

		for i in _labels.size():
			var lbl    := _labels[i] as Label
			var center := lbl.global_position + lbl.size * 0.5
			var d: float = tp.distance_to(center)
			if d < bdist:
				bdist = d
				best  = i

		current_map[touch.name] = best

		# Trigger only on the first frame a touch lands on the correct next letter
		var prev: int = _prev_touch_on.get(touch.name, -1)
		if best == _next_idx and prev != _next_idx and not _lit[best]:
			_light_letter(_next_idx)

	_prev_touch_on = current_map


func _light_letter(idx: int) -> void:
	_lit[idx]    = true
	_glow_t[idx] = 0.0
	var freq_f : float = NOTE_FREQS[idx]
	_queue_note(freq_f)
	get_tree().create_timer(0.22).timeout.connect(func(): _queue_note(freq_f))
	get_tree().create_timer(0.44).timeout.connect(func(): _queue_note(freq_f))
	_next_idx = idx + 1

	if _next_idx >= _labels.size():
		_done = true
		_hud.text = "🎉  You know your ABCs!  🎉"
		_hud.add_theme_font_size_override("font_size", 38)
		_hud.modulate = Color(1.0, 0.92, 0.35, 1.0)
	else:
		_hud.text = "Now touch   " + _labels[_next_idx].text


func set_audio_level(_level: float) -> void:
	pass

func set_quality_level(_level: int) -> void:
	pass
