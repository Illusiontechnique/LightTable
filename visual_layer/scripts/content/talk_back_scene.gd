extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  TALK BACK  —  alphabet grid that plays a musical tone when touched
#
#  A-Z are laid out in a 7×4 grid.  Each letter is mapped to a chromatic note
#  across two octaves (A=C4 → Z=A5).  Touching a tile:
#    1. Bounces the tile with a spring animation
#    2. Plays a two-harmonic sine tone with ADSR envelope
#    3. Shows the letter large in the center panel with an associated word
#
#  Polyphonic: multiple letters can ring simultaneously.
# ─────────────────────────────────────────────────────────────────────────────

const SAMPLE_RATE : float = 44100.0

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

# Chromatic scale starting at C4 = 261.63 Hz
const C4 : float = 261.63
const SEMITONE : float = 1.05946309436  # 2^(1/12)

var vp_size      : Vector2
var audio_level  : float = 0.0

var _tiles       : Array = []   # [{bg, label, letter, col, base_pos}]
var _voices      : Array = []   # one AudioStreamPlayer per tile (for poly)

var _center_lbl  : Label
var _word_lbl    : Label
var _center_hide : float = 0.0  # countdown to hide center display

var _cooldowns   : Array = []   # per-tile press cooldown


func _ready() -> void:
	vp_size = get_viewport_rect().size
	_add_backdrop()
	_build_grid()
	_build_center_display()


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)


func _add_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color    = Color(0.0, 0.0, 0.0, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)

	var t := Label.new()
	t.text = "TALK BACK"
	t.add_theme_font_size_override("font_size", 28)
	t.modulate = Color(1.0, 0.85, 0.55, 0.75)
	t.position = Vector2(24, 12)
	add_child(t)


func _letter_freq(idx: int) -> float:
	return C4 * pow(SEMITONE, float(idx))


func _build_grid() -> void:
	const COLS   := 7
	const ROWS   := 4
	const TILE_W := 110.0
	const TILE_H := 90.0
	const PAD    := 8.0

	var total_w : float = COLS * (TILE_W + PAD) - PAD
	var total_h : float = ROWS * (TILE_H + PAD) - PAD
	var ox      : float = (vp_size.x - total_w) * 0.5
	var oy      : float = (vp_size.y - total_h) * 0.5 + 20.0

	for i in range(LETTERS.size()):
		var col_i : int   = i % COLS
		var row_i : int   = i / COLS
		var hue   : float = float(i) / float(LETTERS.size())
		var col   : Color = Color.from_hsv(hue, 0.70, 0.82)

		var base_pos := Vector2(ox + col_i * (TILE_W + PAD), oy + row_i * (TILE_H + PAD))

		# Tile background
		var tile := ColorRect.new()
		tile.size         = Vector2(TILE_W, TILE_H)
		tile.pivot_offset = Vector2(TILE_W * 0.5, TILE_H * 0.5)
		tile.position     = base_pos
		tile.color        = col
		add_child(tile)

		# Subtle highlight strip
		var hi := ColorRect.new()
		hi.size     = Vector2(TILE_W, 5)
		hi.position = Vector2(0, 0)
		hi.color    = Color(1, 1, 1, 0.20)
		tile.add_child(hi)

		# Letter label centred in tile
		var lbl := Label.new()
		lbl.text                 = LETTERS[i]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		lbl.size                 = Vector2(TILE_W, TILE_H)
		lbl.position             = Vector2.ZERO
		lbl.add_theme_font_size_override("font_size", 42)
		lbl.modulate = Color(0, 0, 0, 0.80)
		tile.add_child(lbl)

		_tiles.append({
			"tile":     tile,
			"letter":   LETTERS[i],
			"col":      col,
			"base_pos": base_pos,
			"pressed":  false,
		})
		_cooldowns.append(0.0)
		_voices.append(null)


func _build_center_display() -> void:
	# Central floating display
	var panel := ColorRect.new()
	panel.name     = "CenterPanel"
	panel.color    = Color(0.06, 0.06, 0.08, 0.88)
	panel.size     = Vector2(260, 160)
	panel.position = Vector2(vp_size.x * 0.5 - 130, vp_size.y * 0.5 - 80)
	panel.visible  = false
	add_child(panel)

	_center_lbl = Label.new()
	_center_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_lbl.size                 = Vector2(260, 100)
	_center_lbl.position             = Vector2(0, 10)
	_center_lbl.add_theme_font_size_override("font_size", 80)
	panel.add_child(_center_lbl)

	_word_lbl = Label.new()
	_word_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_word_lbl.size                 = Vector2(260, 40)
	_word_lbl.position             = Vector2(0, 112)
	_word_lbl.add_theme_font_size_override("font_size", 20)
	_word_lbl.modulate = Color(0.9, 0.9, 1.0, 0.85)
	panel.add_child(_word_lbl)


# ─────────────────────────────────────────────────────────────────────────────
#  Synthesis
# ─────────────────────────────────────────────────────────────────────────────

func _play_letter_tone(idx: int) -> void:
	# Clean up old voice for this slot
	if _voices[idx] != null and is_instance_valid(_voices[idx]):
		(_voices[idx] as Node).queue_free()

	var player := AudioStreamPlayer.new()
	var stream := AudioStreamGenerator.new()
	stream.mix_rate      = SAMPLE_RATE
	stream.buffer_length = 0.75
	player.stream    = stream
	player.volume_db = -6.0
	add_child(player)
	player.play()
	_voices[idx] = player

	var pb   : AudioStreamGeneratorPlayback = player.get_stream_playback()
	var freq : float                        = _letter_freq(idx)
	var n    : int                          = int(SAMPLE_RATE * 0.65)
	var ph1  : float = 0.0
	var ph2  : float = 0.0
	var ph3  : float = 0.0

	for i in range(n):
		var t   : float = float(i) / SAMPLE_RATE
		# ADSR: fast attack (5ms), decay to 0.55, long release
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

	get_tree().create_timer(0.8).timeout.connect(player.queue_free)


func _activate_tile(idx: int) -> void:
	var td : Dictionary = _tiles[idx]
	var col : Color = td["col"]

	# Bounce animation
	var tile : ColorRect = td["tile"] as ColorRect
	var base : Vector2   = td["base_pos"]
	var tw := create_tween()
	tw.tween_property(tile, "scale", Vector2(1.25, 1.25), 0.07)
	tw.parallel().tween_property(tile, "modulate", Color(2.2, 2.2, 2.2), 0.07)
	tw.tween_property(tile, "scale", Vector2(1.0, 1.0), 0.14).set_trans(Tween.TRANS_ELASTIC)
	tw.parallel().tween_property(tile, "modulate", Color(1.0, 1.0, 1.0), 0.12)

	# Center display
	var panel : ColorRect = get_node_or_null("CenterPanel") as ColorRect
	if panel:
		panel.visible = true
		_center_lbl.text    = td["letter"]
		_center_lbl.modulate = Color(col.r * 1.5, col.g * 1.5, col.b * 1.5)
		_word_lbl.text       = WORDS[idx]
		_center_hide = 1.8

	_play_letter_tone(idx)
	_cooldowns[idx] = 0.30


# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_center_hide -= delta
	var panel : ColorRect = get_node_or_null("CenterPanel") as ColorRect
	if panel:
		panel.visible = (_center_hide > 0.0)

	var interactions := get_parent().get_node_or_null("Interactions")

	for i in range(_tiles.size()):
		_cooldowns[i] = max(0.0, _cooldowns[i] - delta)

		if _cooldowns[i] > 0.0:
			continue

		var td  : Dictionary = _tiles[i]
		var tile : ColorRect = td["tile"] as ColorRect
		var pressed : bool   = false

		if interactions:
			for touch in interactions.get_children():
				var tp : Vector2 = touch.position + touch.pivot_offset
				if tile.get_global_rect().has_point(tp):
					pressed = true
					break

		if pressed and not td["pressed"]:
			_activate_tile(i)

		td["pressed"] = pressed
		_tiles[i] = td
