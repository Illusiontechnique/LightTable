extends Node2D

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  SYNTH PIANO  â€”  12-key chromatic electric synth with pseudo-3D aesthetics.
#
#  Each key is built from Polygon2D layers:
#    depth_poly  â€” darker front extrusion (3-D depth illusion)
#    face_poly   â€” main key surface (dark resting, blazing on press)
#    glow_poly   â€” full-height white overlay, fades after hit
#    led_rect    â€” small LED indicator at key top
#    name_lbl    â€” note name
#
#  Polyphonic additive synthesis: 5 harmonic partials, individual ADSR.
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

const SAMPLE_RATE  := 44100.0
const NOTE_DUR     := 2.20

const NOTE_FREQ := [
	261.63, 293.66, 329.63, 349.23, 392.00, 440.00, 493.88, 523.25
]
const NOTE_NAMES := ["C", "D", "E", "F", "G", "A", "B", "C"]

# [freq_mult, amp, decay_rate]  -- Rich warm professional piano
const PARTIALS := [
	[1.0,  0.80, 1.40],
	[2.0,  0.42, 2.80],
	[3.0,  0.18, 4.40],
	[4.0,  0.10, 7.80],
	[5.0,  0.06, 11.0],
	[6.0,  0.03, 14.5],
]

const NUM_KEYS := 8
const KEY_GAP  := 5
const DEPTH    := 26    # 3-D extrusion depth (px)
const SKEW     := 8     # horizontal skew of depth face (px, suggests perspective)

var vp_size     : Vector2
var audio_level : float = 0.0

# Key geometry (computed in _ready)
var _key_left   : Array = []   # float: left-edge x of each key
var _key_top_y  : float = 0.0
var _key_face_h : float = 0.0
var _key_w      : float = 0.0

# Per-key nodes
var _face_poly  : Array = []   # Polygon2D  key surface
var _depth_poly : Array = []   # Polygon2D  3-D depth face
var _glow_poly  : Array = []   # Polygon2D  press glow overlay
var _led_rects  : Array = []   # ColorRect  LED indicator
var _name_lbls  : Array = []   # Label      note name

var _key_states : Array = []
var _key_colors : Array = []

var _active_lbl : Label
var _active_t   : float = 0.0

var _voices : Array = []


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _ready() -> void:
	vp_size      = get_viewport_rect().size
	_key_w       = (vp_size.x - (NUM_KEYS - 1) * KEY_GAP) / float(NUM_KEYS)
	_key_top_y   = vp_size.y * 0.22
	_key_face_h  = vp_size.y * 0.62
	_add_housing()
	_setup_voices()
	_build_keys()
	_add_display()


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func set_quality_level(_l: int) -> void:
	pass


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  Housing â€” background panels and accent strips
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _add_housing() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.03, 0.03, 0.05, 1.0)
	bg.size     = vp_size
	bg.position = Vector2.ZERO
	add_child(bg)
	move_child(bg, 0)

	# Top panel
	var top := ColorRect.new()
	top.color    = Color(0.06, 0.07, 0.11, 1.0)
	top.size     = Vector2(vp_size.x, _key_top_y - 2)
	top.position = Vector2.ZERO
	add_child(top)

	# Accent line below top panel
	var acc := ColorRect.new()
	acc.color    = Color(0.18, 0.55, 1.0, 0.85)
	acc.size     = Vector2(vp_size.x, 2)
	acc.position = Vector2(0, _key_top_y - 2)
	add_child(acc)

	# Bottom panel
	var bot_y : float = _key_top_y + _key_face_h + DEPTH + 4
	var bot := ColorRect.new()
	bot.color    = Color(0.05, 0.06, 0.09, 1.0)
	bot.size     = Vector2(vp_size.x, vp_size.y - bot_y)
	bot.position = Vector2(0, bot_y)
	add_child(bot)

	var acc2 := ColorRect.new()
	acc2.color    = Color(0.18, 0.55, 1.0, 0.55)
	acc2.size     = Vector2(vp_size.x, 2)
	acc2.position = Vector2(0, bot_y)
	add_child(acc2)

	var title := Label.new()
	title.text = "ELECTRIC PIANO"
	title.add_theme_font_size_override("font_size", 20)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.modulate = Color(0.45, 0.75, 1.0, 0.82)
	title.position = Vector2(20, 12)
	add_child(title)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  Key construction
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _build_keys() -> void:
	for i in range(NUM_KEYS):
		var kx  : float = i * (_key_w + KEY_GAP)
		var ky  : float = _key_top_y
		var kw  : float = _key_w
		var kh  : float = _key_face_h
		_key_left.append(kx)

		var hue : float = float(i) / float(NUM_KEYS)
		_key_colors.append(Color.from_hsv(hue, 0.95, 1.0))
		_key_states.append(false)

		# â”€â”€ Depth face (3-D extrusion below key) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		var depth_p := Polygon2D.new()
		depth_p.polygon = PackedVector2Array([
			Vector2(kx,            ky + kh),
			Vector2(kx + kw,       ky + kh),
			Vector2(kx + kw + SKEW, ky + kh + DEPTH),
			Vector2(kx + SKEW,     ky + kh + DEPTH),
		])
		depth_p.color = Color(0.42, 0.40, 0.38)
		add_child(depth_p)
		_depth_poly.append(depth_p)

		# â”€â”€ Key face (main pressing surface) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		var face_p := Polygon2D.new()
		face_p.polygon = PackedVector2Array([
			Vector2(kx,      ky),
			Vector2(kx + kw, ky),
			Vector2(kx + kw, ky + kh),
			Vector2(kx,      ky + kh),
		])
		face_p.color = Color(0.92, 0.90, 0.86)
		add_child(face_p)
		_face_poly.append(face_p)

		# â”€â”€ Highlight strip (top edge) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		var hi := Polygon2D.new()
		hi.polygon = PackedVector2Array([
			Vector2(kx,      ky),
			Vector2(kx + kw, ky),
			Vector2(kx + kw, ky + 5),
			Vector2(kx,      ky + 5),
		])
		hi.color = Color(1, 1, 1, 0.12)
		add_child(hi)

		# â”€â”€ Left edge highlight â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		var lhi := Polygon2D.new()
		lhi.polygon = PackedVector2Array([
			Vector2(kx,     ky),
			Vector2(kx + 3, ky),
			Vector2(kx + 3, ky + kh),
			Vector2(kx,     ky + kh),
		])
		lhi.color = Color(1, 1, 1, 0.07)
		add_child(lhi)

		# â”€â”€ Glow overlay (flashes on press, full key height incl. depth) â”€â”€
		var glow_p := Polygon2D.new()
		glow_p.polygon = PackedVector2Array([
			Vector2(kx,      ky),
			Vector2(kx + kw, ky),
			Vector2(kx + kw, ky + kh + DEPTH),
			Vector2(kx,      ky + kh + DEPTH),
		])
		glow_p.color = Color(1, 1, 1, 0.0)
		add_child(glow_p)
		_glow_poly.append(glow_p)

		# â”€â”€ LED indicator (small rectangle near top) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		var led := ColorRect.new()
		led.size     = Vector2(kw * 0.35, 7)
		led.position = Vector2(kx + kw * 0.325, ky + 14)
		led.color    = Color(0.55, 0.53, 0.50)
		add_child(led)
		_led_rects.append(led)

		# â”€â”€ Note name label â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		var lbl := Label.new()
		lbl.text = NOTE_NAMES[i]
		lbl.add_theme_font_size_override("font_size", int(kw * 0.42))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.size     = Vector2(kw, 36)
		lbl.position = Vector2(kx, ky + kh - 44)
		lbl.modulate = Color(0.25, 0.25, 0.35, 0.80)
		add_child(lbl)
		_name_lbls.append(lbl)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  Active-note display in the top panel
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _add_display() -> void:
	_active_lbl = Label.new()
	_active_lbl.text = "-"
	_active_lbl.add_theme_font_size_override("font_size", int(_key_top_y * 0.70))
	_active_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_active_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_active_lbl.size     = Vector2(vp_size.x, _key_top_y - 6)
	_active_lbl.position = Vector2(0, 4)
	_active_lbl.modulate = Color(0.35, 0.65, 1.0, 0.45)
	add_child(_active_lbl)


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#  Audio voices
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _setup_voices() -> void:
	for i in range(NUM_KEYS):
		var player := AudioStreamPlayer.new()
		var stream := AudioStreamGenerator.new()
		stream.mix_rate      = SAMPLE_RATE
		stream.buffer_length = 0.25
		player.stream    = stream
		player.volume_db = -8.0
		add_child(player)
		player.play()

		var partial_states : Array = []
		for _p in PARTIALS:
			partial_states.append([0.0, 0.0])   # [phase, amp]

		_voices.append({
			"player":    player,
			"playback":  player.get_stream_playback() as AudioStreamGeneratorPlayback,
			"freq":      NOTE_FREQ[i],
			"partial":   partial_states,
			"held":      false,
			"release":   false,
		})


func _trigger_note(idx: int) -> void:
	var v : Dictionary = _voices[idx]
	v["held"]    = true
	v["release"] = false
	for j in range(PARTIALS.size()):
		v["partial"][j][0] = 0.0
		v["partial"][j][1] = float(PARTIALS[j][1])
	_voices[idx] = v


func _release_note(idx: int) -> void:
	var v : Dictionary = _voices[idx]
	v["held"]    = false
	v["release"] = true
	_voices[idx] = v


# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _process(delta: float) -> void:
	var interactions := get_parent().get_node_or_null("Interactions")
	_active_t -= delta

	for i in range(NUM_KEYS):
		var key_rect := Rect2(_key_left[i], _key_top_y, _key_w, _key_face_h)
		var pressed  : bool = false

		if interactions:
			for touch in interactions.get_children():
				if key_rect.has_point(touch.global_position + touch.pivot_offset):
					pressed = true
					break

		var was_pressed : bool = _key_states[i]

		if pressed and not was_pressed:
			_trigger_note(i)
			_active_lbl.text    = NOTE_NAMES[i]
			_active_lbl.modulate = Color.from_hsv(float(i) / float(NUM_KEYS), 1.0, 1.0, 1.0)
			_active_t = 2.0
		elif not pressed and was_pressed:
			_release_note(i)

		_key_states[i] = pressed

		# â”€â”€ Visuals â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		var hue  : float    = float(i) / float(NUM_KEYS)
		var fp   : Polygon2D = _face_poly[i]  as Polygon2D
		var dp   : Polygon2D = _depth_poly[i] as Polygon2D
		var gp   : Polygon2D = _glow_poly[i]  as Polygon2D
		var led  : ColorRect = _led_rects[i]  as ColorRect

		if pressed:
			fp.color  = Color.from_hsv(hue, 0.90, 1.0)
			dp.color  = Color.from_hsv(hue, 0.80, 0.65)
			led.color = Color.from_hsv(hue, 0.85, 1.0)
			if not was_pressed:
				gp.color.a = 0.65
		else:
			fp.color  = Color(0.92, 0.90, 0.86)
			dp.color  = Color(0.42, 0.40, 0.38)
			led.color = Color(0.55, 0.53, 0.50)

		# Glow fade
		if gp.color.a > 0.0:
			gp.color.a = max(0.0, gp.color.a - delta * 2.8)

	# Active display fade
	if _active_t <= 0.0:
		_active_lbl.text    = "-"
		_active_lbl.modulate = Color(0.35, 0.65, 1.0, 0.45)

	_update_audio(delta)


func _update_audio(_delta: float) -> void:
	for i in range(_voices.size()):
		var v        : Dictionary                    = _voices[i]
		var playback : AudioStreamGeneratorPlayback  = v["playback"]
		if playback == null:
			continue

		var frames : int = mini(playback.get_frames_available(), 512)
		for _f in range(frames):
			var sample_f : float = 0.0
			var freq_f   : float = v["freq"]

			for j in range(PARTIALS.size()):
				var p_cfg  : Array = PARTIALS[j]
				var p_amp_f  : float = float(p_cfg[1])
				var p_dec_f  : float = float(p_cfg[2])
				var ps_v     : Array = v["partial"][j]
				if ps_v[1] < 0.0001:
					continue

				sample_f += sin(ps_v[0]) * ps_v[1]
				ps_v[0] += TAU * freq_f * float(p_cfg[0]) / SAMPLE_RATE
				if ps_v[0] > TAU:
					ps_v[0] -= TAU

				if v["held"]:
					ps_v[1] = max(0.0, ps_v[1] - (p_amp_f * p_dec_f * 0.45) / SAMPLE_RATE)
				else:
					ps_v[1] = max(0.0, ps_v[1] - (p_amp_f * p_dec_f * 4.5) / SAMPLE_RATE)

			sample_f = clamp(sample_f * 0.35, -1.0, 1.0)
			playback.push_frame(Vector2(sample_f, sample_f))

		_voices[i] = v
