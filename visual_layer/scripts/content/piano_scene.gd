extends Node2D

@export var key_width = 80
@export var white_keys = 12
@export var base_freq = 261.63 # Middle C

func _ready():
	setup_piano()
	add_header()

func add_header():
	var backdrop = ColorRect.new()
	backdrop.color = Color(0.06, 0.06, 0.08, 1.0)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	move_child(backdrop, 0)

	var title = Label.new()
	title.text = "PIANO / TOUCH KEYS"
	title.add_theme_font_size_override("font_size", 34)
	const SAMPLE_RATE := 44100.0
	const NOTE_DURATION := 0.36

	var note_frequencies = [261.63, 277.18, 293.66, 311.13, 329.63, 349.23, 369.99, 392.00, 415.30, 440.00, 466.16, 493.88]
	var note_names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	var key_nodes: Array = []
	var key_states: Array = []
	var voices: Array = []

	title.modulate = Color(0.95, 0.95, 1.0)
		add_stage()
	title.position = Vector2(24, 18)
		setup_audio()

	func add_stage():
		var backdrop = ColorRect.new()
		backdrop.color = Color(0.02, 0.02, 0.04, 1.0)
		backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(backdrop)
		move_child(backdrop, 0)

		var title = Label.new()
		title.text = "PIANO / SYNTH KEYS"
		title.add_theme_font_size_override("font_size", 34)
		title.modulate = Color(0.9, 0.95, 1.0)
		title.position = Vector2(24, 18)
		add_child(title)

		var subtitle = Label.new()
		subtitle.text = "Tap the keys with your hand or mouse"
		subtitle.add_theme_font_size_override("font_size", 15)
		subtitle.modulate = Color(0.8, 0.9, 1.0, 0.8)
		subtitle.position = Vector2(24, 56)
		add_child(subtitle)
	add_child(title)

func setup_piano():
	# Create white keys
	for i in range(white_keys):
		var key = ColorRect.new()
			key.size = Vector2(key_width - 6, 420)
			key.position = Vector2(80 + i * key_width, 250)
			key.color = Color(0.92, 0.92, 0.96)
		key.color = Color.WHITE
			key_nodes.append(key)
			key_states.append(false)
		add_child(key)
		
		# Add a label for the note
			label.text = note_names[i]
		label.text = get_note_name(i)
			label.position = Vector2(0, 365)
		label.position = Vector2(0, 350)
		label.size = Vector2(key_width, 30)
		label.modulate = Color.BLACK

	func setup_audio():
		for i in range(note_frequencies.size()):
			var player = AudioStreamPlayer.new()
			var stream = AudioStreamGenerator.new()
			stream.mix_rate = SAMPLE_RATE
			stream.buffer_length = 0.2
			player.stream = stream
			player.volume_db = -10.0
			add_child(player)
			player.play()

			voices.append({
				"player": player,
				"playback": player.get_stream_playback() as AudioStreamGeneratorPlayback,
				"freq": note_frequencies[i],
				"phase": 0.0,
				"remaining": 0.0,
				"envelope": 0.0
			})
		key.add_child(label)

func _process(_delta):
	# Check interactions from the main script (via parent or global)
		var interactions = get_parent().get_node_or_null("Interactions")
	var interactions = get_parent().get_node("Interactions")
	if not interactions: return
		for i in range(key_nodes.size()):
			var key = key_nodes[i]
			var pressed = false
			for touch in interactions.get_children():
				if key.get_global_rect().has_point(touch.global_position):
					pressed = true
					break

			if pressed and not key_states[i]:
				trigger_note(i)
			key_states[i] = pressed
			key.color = Color(0.18, 0.86, 1.0) if pressed else Color(0.92, 0.92, 0.96)

		update_audio()

	func trigger_note(index: int):
		var voice = voices[index]
		voice.remaining = NOTE_DURATION
		voice.envelope = 1.0
		voice.phase = 0.0
		voices[index] = voice

	func update_audio():
		for i in range(voices.size()):
			var voice = voices[i]
			var playback: AudioStreamGeneratorPlayback = voice.playback
			if playback == null:
				continue

			var frames_to_push = mini(playback.get_frames_available(), 512)
			for _frame in range(frames_to_push):
				var env = 0.0
				if voice.remaining > 0.0:
					voice.remaining -= 1.0 / SAMPLE_RATE
					var note_progress = clamp(1.0 - (voice.remaining / NOTE_DURATION), 0.0, 1.0)
					env = pow(1.0 - note_progress, 1.7)
					if env < 0.02:
						env = 0.02
				else:
					voice.envelope = move_toward(voice.envelope, 0.0, 0.03)
					env = voice.envelope

				var sample = piano_sample(voice.phase, voice.freq, env)
				playback.push_frame(Vector2(sample, sample))
				voice.phase += TAU * voice.freq / SAMPLE_RATE
				if voice.phase > TAU:
					voice.phase -= TAU

			voices[i] = voice

	func piano_sample(phase: float, freq: float, env: float) -> float:
		var fundamental = sin(phase)
		var second = sin(phase * 2.0) * 0.35
		var third = sin(phase * 3.0) * 0.18
		var attack = exp(-fmod(Time.get_ticks_msec() / 1000.0 * freq, 1.0) * 2.0)
		return (fundamental * 0.65 + second + third) * env * 0.18 * attack
	return notes[index % 7] + str(4 + index / 7)
