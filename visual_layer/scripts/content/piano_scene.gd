extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  SYNTH PIANO  —  12-key chromatic electric synth with pseudo-3D aesthetics.
#
#  Each key is built from Polygon2D layers:
#    depth_poly  — darker front extrusion (3-D depth illusion)
#    face_poly   — main key surface (dark resting, blazing on press)
#    glow_poly   — full-height white overlay, fades after hit
#    led_rect    — small LED indicator at key top
#    name_lbl    — note name
#
#  Polyphonic additive synthesis: 5 harmonic partials, individual ADSR.
# ─────────────────────────────────────────────────────────────────────────────

const SAMPLE_RATE  := 44100.0
const NOTE_DUR     := 2.20

const NOTE_FREQ := [
	261.63, 277.18, 293.66, 311.13, 329.63, 349.23,
	369.99, 392.00, 415.30, 440.00, 466.16, 493.88
]
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# [freq_mult, amp, decay_rate]
const PARTIALS := [
	[1.0, 0.60, 1.10],
	[2.0, 0.28, 1.55],
	[3.0, 0.14, 2.20],
	[4.0, 0.07, 3.80],
	[6.0, 0.03, 6.00],
]

const NUM_KEYS := 12
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


# ─────────────────────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
#  Housing — background panels and accent strips
# ─────────────────────────────────────────────────────────────────────────────
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
	title.text = "SYNTH  ·  CHROMATIC"
	title.add_theme_font_size_override("font_size", 20)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.modulate = Color(0.45, 0.75, 1.0, 0.82)
	title.position = Vector2(20, 12)
	add_child(title)


# ─────────────────────────────────────────────────────────────────────────────
#  Key construction
# ─────────────────────────────────────────────────────────────────────────────
func _build_keys() -> void:
	for i in range(NUM_KEYS):
		var kx  : float = i * (_key_w + KEY_GAP)
		var ky  : float = _key_top_y
		var kw  : float = _key_w
		var kh  : float = _key_face_h
		_key_left.append(kx)

		var hue : float = float(i) / float(NUM_KEYS)
		var col : Color = Color.from_hsv(hue, 0.80, 0.88)
		_key_colors.append(col)
		_key_states.append(false)

		# ── Depth face (3-D extrusion below key) ──────────────────────
		var depth_p := Polygon2D.new()
		depth_p.polygon = PackedVector2Array([
			Vector2(kx,            ky + kh),
			Vector2(kx + kw,       ky + kh),
			Vector2(kx + kw + SKEW, ky + kh + DEPTH),
			Vector2(kx + SKEW,     ky + kh + DEPTH),
		])
		depth_p.color = Color.from_hsv(hue, 0.70, 0.16)
		add_child(depth_p)
		_depth_poly.append(depth_p)

		# ── Key face (main pressing surface) ──────────────────────────
		var face_p := Polygon2D.new()
		face_p.polygon = PackedVector2Array([
			Vector2(kx,      ky),
			Vector2(kx + kw, ky),
			Vector2(kx + kw, ky + kh),
			Vector2(kx,      ky + kh),
		])
		face_p.color = Color.from_hsv(hue, 0.65, 0.20)
		add_child(face_p)
		_face_poly.append(face_p)

		# ── Highlight strip (top edge) ─────────────────────────────────
		var hi := Polygon2D.new()
		hi.polygon = PackedVector2Array([
			Vector2(kx,      ky),
			Vector2(kx + kw, ky),
			Vector2(kx + kw, ky + 5),
			Vector2(kx,      ky + 5),
		])
		hi.color = Color(1, 1, 1, 0.12)
		add_child(hi)

		# ── Left edge highlight ────────────────────────────────────────
		var lhi := Polygon2D.new()
		lhi.polygon = PackedVector2Array([
			Vector2(kx,     ky),
			Vector2(kx + 3, ky),
			Vector2(kx + 3, ky + kh),
			Vector2(kx,     ky + kh),
		])
		lhi.color = Color(1, 1, 1, 0.07)
		add_child(lhi)

		# ── Glow overlay (flashes on press, full key height incl. depth) ──
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

		# ── LED indicator (small rectangle near top) ───────────────────
		var led := ColorRect.new()
		led.size     = Vector2(kw * 0.35, 7)
		led.position = Vector2(kx + kw * 0.325, ky + 14)
		led.color    = Color.from_hsv(hue, 0.90, 0.28)
		add_child(led)
		_led_rects.append(led)

		# ── Note name label ────────────────────────────────────────────
		var lbl := Label.new()
		lbl.text = NOTE_NAMES[i]
		lbl.add_theme_font_size_override("font_size", int(kw * 0.42))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.size     = Vector2(kw, 36)
		lbl.position = Vector2(kx, ky + kh - 44)
		lbl.modulate = Color(0.7, 0.8, 1.0, 0.50)
		add_child(lbl)
		_name_lbls.append(lbl)


# ─────────────────────────────────────────────────────────────────────────────
#  Active-note display in the top panel
# ─────────────────────────────────────────────────────────────────────────────
func _add_display() -> void:
	_active_lbl = Label.new()
	_active_lbl.text = "—"
	_active_lbl.add_theme_font_size_override("font_size", int(_key_top_y * 0.70))
	_active_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_active_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_active_lbl.size     = Vector2(vp_size.x, _key_top_y - 6)
	_active_lbl.position = Vector2(0, 4)
	_active_lbl.modulate = Color(0.35, 0.65, 1.0, 0.45)
	add_child(_active_lbl)


# ─────────────────────────────────────────────────────────────────────────────
#  Audio voices
# ─────────────────────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
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

		# ── Visuals ───────────────────────────────────────────────────
		var hue  : float    = float(i) / float(NUM_KEYS)
		var fp   : Polygon2D = _face_poly[i]  as Polygon2D
		var dp   : Polygon2D = _depth_poly[i] as Polygon2D
		var gp   : Polygon2D = _glow_poly[i]  as Polygon2D
		var led  : ColorRect = _led_rects[i]  as ColorRect

		if pressed:
			fp.color  = Color.from_hsv(hue, 1.0, 1.0)
			dp.color  = Color.from_hsv(hue, 0.82, 0.58)
			led.color = Color.from_hsv(hue, 0.95, 1.0)
			if not was_pressed:
				gp.color.a = 0.55
		else:
			fp.color  = Color.from_hsv(hue, 0.65, 0.20)
			dp.color  = Color.from_hsv(hue, 0.70, 0.16)
			led.color = Color.from_hsv(hue, 0.90, 0.28)

		# Glow fade
		if gp.color.a > 0.0:
			gp.color.a = max(0.0, gp.color.a - delta * 2.8)

	# Active display fade
	if _active_t <= 0.0:
		_active_lbl.text    = "—"
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
			var sample : float = 0.0
			var freq   : float = v["freq"]

			for j in range(PARTIALS.size()):
				var p_cfg  : Array = PARTIALS[j]
				var p_amp  : float = float(p_cfg[1])
				var p_dec  : float = float(p_cfg[2])
				var ps     : Array = v["partial"][j]
				if ps[1] < 0.0001:
					continue

				sample += sin(ps[0]) * ps[1]
				ps[0] += TAU * freq * float(p_cfg[0]) / SAMPLE_RATE
				if ps[0] > TAU:
					ps[0] -= TAU

				if v["held"]:
					ps[1] = max(0.0, ps[1] - (p_amp * p_dec * 0.8) / SAMPLE_RATE)
				else:
					ps[1] = max(0.0, ps[1] - (p_amp * p_dec * 5.5) / SAMPLE_RATE)

			sample = clamp(sample * 0.22, -1.0, 1.0)
			playback.push_frame(Vector2(sample, sample))

		_voices[i] = v
#
#  Sound synthesis:  polyphonic additive synthesis, 5 harmonic partials with
#  individual ADSR envelopes that mimic a struck string:
#    • Very fast attack (1–2 ms)
#    • Exponential decay into a long sustain
#    • Smooth release when the key is lifted
#  Each partial decays at a different rate (higher partials die faster),
#  which gives the natural "bright at onset, mellow over time" piano timbre.
# ─────────────────────────────────────────────────────────────────────────────

const SAMPLE_RATE  := 44100.0
const NOTE_DUR     := 2.20      # seconds a key stays "ringing" if held

const NOTE_FREQ := [
	261.63, 277.18, 293.66, 311.13, 329.63, 349.23,
	369.99, 392.00, 415.30, 440.00, 466.16, 493.88
]
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Harmonic partial: [freq_mult, amp, decay_rate]
# decay_rate = how quickly that partial fades (higher = faster)
const PARTIALS := [
	[1.0,  0.60, 1.10],
	[2.0,  0.28, 1.55],
	[3.0,  0.14, 2.20],
	[4.0,  0.07, 3.80],
	[6.0,  0.03, 6.00],
]

const KEY_W    := 88     # key width (incl. gap)
const KEY_GAP  := 5
const KEY_H    := 460
const NUM_KEYS := 12

var vp_size    : Vector2
var audio_level : float = 0.0

var _key_nodes  : Array = []
var _key_glow   : Array = []    # Label glow overlays
var _key_states : Array = []
var _key_colors : Array = []    # resting rainbow colours

var _voices : Array = []   # one voice per key

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_stage()
	_setup_voices()
	_build_keys()


func _add_stage() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.0, 0.0, 0.0, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = get_viewport_rect().size
	add_child(bg)
	move_child(bg, 0)

	var t := Label.new()
	t.text = "PIANO"
	t.add_theme_font_size_override("font_size", 34)
	t.modulate = Color(0.9, 0.95, 1.0)
	t.position = Vector2(24, 18)
	add_child(t)

	var s := Label.new()
	s.text = "Touch the keys · polyphonic · rainbow"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(0.8, 0.9, 1.0, 0.8)
	s.position = Vector2(24, 56)
	add_child(s)


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)

# ─────────────────────────────────────────────────────────────────────────────
#  Keys
# ─────────────────────────────────────────────────────────────────────────────

func _build_keys() -> void:
	var total_w : float = NUM_KEYS * KEY_W - KEY_GAP
	var start_x : float = (vp_size.x - total_w) * 0.5
	var start_y : float = (vp_size.y - KEY_H) * 0.5 + 20.0

	for i in range(NUM_KEYS):
		# Rainbow resting colour: vivid, dark-stage friendly
		var hue   : float = float(i) / float(NUM_KEYS)
		var col   : Color = Color.from_hsv(hue, 0.70, 0.88)
		_key_colors.append(col)

		# Key body
		var key := ColorRect.new()
		key.size     = Vector2(KEY_W - KEY_GAP, KEY_H)
		key.position = Vector2(start_x + i * KEY_W, start_y)
		key.color    = col
		add_child(key)
		_key_nodes.append(key)
		_key_states.append(false)

		# Subtle top highlight strip
		var hi := ColorRect.new()
		hi.size     = Vector2(KEY_W - KEY_GAP, 6)
		hi.position = Vector2(0, 0)
		hi.color    = Color(1, 1, 1, 0.22)
		key.add_child(hi)

		# Note label at bottom of key
		var lbl := Label.new()
		lbl.text = NOTE_NAMES[i]
		lbl.add_theme_font_size_override("font_size", 20)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.size     = Vector2(KEY_W - KEY_GAP, 32)
		lbl.position = Vector2(0, KEY_H - 38)
		lbl.modulate = Color(0, 0, 0, 0.7)
		key.add_child(lbl)

		# Glow flash node (full-key white overlay, fades on hit)
		var glow := ColorRect.new()
		glow.size     = Vector2(KEY_W - KEY_GAP, KEY_H)
		glow.position = Vector2(0, 0)
		glow.color    = Color(1, 1, 1, 0.0)
		key.add_child(glow)
		_key_glow.append(glow)

# ─────────────────────────────────────────────────────────────────────────────
#  Audio
# ─────────────────────────────────────────────────────────────────────────────

func _setup_voices() -> void:
	for i in range(NUM_KEYS):
		var player := AudioStreamPlayer.new()
		var stream := AudioStreamGenerator.new()
		stream.mix_rate    = SAMPLE_RATE
		stream.buffer_length = 0.25
		player.stream      = stream
		player.volume_db   = -8.0
		add_child(player)
		player.play()

		# Per-partial state: [phase, envelope_amp]
		var partial_states : Array = []
		for p in PARTIALS:
			partial_states.append([0.0, 0.0])   # [phase, amp]

		_voices.append({
			"player":    player,
			"playback":  player.get_stream_playback() as AudioStreamGeneratorPlayback,
			"freq":      NOTE_FREQ[i],
			"partial":   partial_states,
			"remaining": 0.0,   # time left in note
			"held":      false,
			"release":   false, # fading out after key lifted
			"rel_env":   0.0,   # global release envelope
		})

# ─────────────────────────────────────────────────────────────────────────────

func _trigger_note(idx: int) -> void:
	var v : Dictionary = _voices[idx]
	v["remaining"] = NOTE_DUR
	v["held"]      = true
	v["release"]   = false
	v["rel_env"]   = 1.0
	# Reset all partial phases & envelopes to full
	for j in range(PARTIALS.size()):
		v["partial"][j][0] = 0.0
		v["partial"][j][1] = float(PARTIALS[j][1])
	_voices[idx] = v


func _release_note(idx: int) -> void:
	var v : Dictionary = _voices[idx]
	v["held"]    = false
	v["release"] = true
	_voices[idx] = v

# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	var interactions := get_parent().get_node_or_null("Interactions")

	# ── Key hit detection ──────────────────────────────────────────────
	for i in range(NUM_KEYS):
		var key     : ColorRect = _key_nodes[i]
		var pressed : bool      = false

		if interactions:
			for touch in interactions.get_children():
				if key.get_global_rect().has_point(touch.global_position + touch.pivot_offset):
					pressed = true
					break

		var was_pressed : bool = _key_states[i]

		if pressed and not was_pressed:
			_trigger_note(i)
		elif not pressed and was_pressed:
			_release_note(i)

		_key_states[i] = pressed

		# ── Visuals ──────────────────────────────────────────────────
		var hue      : float = float(i) / float(NUM_KEYS)
		if pressed:
			# Bright saturated version while held
			key.color = Color.from_hsv(hue, 1.0, 1.0)
			key.position.y = _key_nodes[i].position.y + 5.0 * (1.0 if pressed else 0.0)
		else:
			key.color = _key_colors[i]

		# Glow flash decays
		var glow : ColorRect = _key_glow[i]
		if glow.color.a > 0.0:
			glow.color.a = max(0.0, glow.color.a - delta * 4.5)
		if pressed and not was_pressed:
			glow.color.a = 0.65

	# ── Audio synthesis ────────────────────────────────────────────────
	_update_audio(delta)


func _update_audio(delta: float) -> void:
	for i in range(_voices.size()):
		var v        : Dictionary                  = _voices[i]
		var playback : AudioStreamGeneratorPlayback = v["playback"]
		if playback == null:
			continue

		var frames : int = mini(playback.get_frames_available(), 512)

		for _f in range(frames):
			var sample : float = 0.0
			var freq   : float = v["freq"]
			var any_active : bool = false

			# ── Per-partial synthesis ────────────────────────────────
			for j in range(PARTIALS.size()):
				var p_cfg  : Array = PARTIALS[j]
				var p_mult : float = float(p_cfg[0])
				var p_amp  : float = float(p_cfg[1])
				var p_dec  : float = float(p_cfg[2])
				var ps     : Array = v["partial"][j]   # [phase, amp]

				if ps[1] < 0.0001:
					continue
				any_active = true

				# Sine oscillator for this partial
				sample += sin(ps[0]) * ps[1]

				# Advance phase
				ps[0] += TAU * freq * p_mult / SAMPLE_RATE
				if ps[0] > TAU:
					ps[0] -= TAU

				# Decay envelope: held → slow natural decay; released → fast release
				if v["held"]:
					ps[1] = max(0.0, ps[1] - (p_amp * p_dec * 0.8) / SAMPLE_RATE)
				else:
					ps[1] = max(0.0, ps[1] - (p_amp * p_dec * 5.5) / SAMPLE_RATE)

			# Apply a global soft limiter
			sample = clamp(sample * 0.22, -1.0, 1.0)

			playback.push_frame(Vector2(sample, sample))

		_voices[i] = v
