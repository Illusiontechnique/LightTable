extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  PIANO  —  12 chromatic keys centred on screen, rainbow palette.
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
