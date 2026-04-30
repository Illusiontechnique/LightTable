extends Node2D

# ─────────────────────────────────────────────────────────────────────────────
#  EDGE REVEAL  —  best used with Edge / Canny tracker
#
#  The screen starts completely dark.  As the edge tracker detects outlines,
#  those positions are "remembered" and the canvas builds up an ever-growing
#  luminous skeleton drawing that persists.
#
#  Think of it as a slow-exposure photograph: the longer you hold an object
#  over the table, the more completely its edges get etched into the canvas.
#
#  Touch / hand positions additionally spawn a radial "torch" that illuminates
#  a disk of the etched image, giving a spotlight-reveal effect.
#
#  Pressing 'r' / sending a clear interaction clears the canvas (handled via
#  audio threshold: very loud sound = wipe + restart with a burst animation).
# ─────────────────────────────────────────────────────────────────────────────

const CANVAS_W   := 1920
const CANVAS_H   := 1080
const MARK_RADIUS := 5       # pixels stamped per detection point
const FADE_SPEED  := 0.012   # how fast marks fade per second (slow intentionally)
const MAX_MARKS   := 1200    # ring-buffer cap

var vp_size     : Vector2
var audio_level : float = 0.0
var _audio_sm   : float = 0.0
var _wipe_cool  : float = 0.0

# Ring-buffer of glowing marks: each entry { pos: Vector2, alpha: float, col: Color }
var _marks     : Array = []
var _mark_idx  : int   = 0

# Active spotlight torches from touch (id → Node2D circle)
var _torches   : Dictionary = {}

# Canvas image we draw marks onto and display via Sprite2D
# (avoids spawning thousands of nodes)
var _canvas    : Image
var _texture   : ImageTexture
var _sprite    : Sprite2D
var _dirty     : bool  = false

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	vp_size = get_viewport_rect().size

	# Black backdrop
	var bg := ColorRect.new()
	bg.color    = Color(0.0, 0.0, 0.0, 1.0)
	bg.position = Vector2.ZERO
	bg.size     = vp_size
	add_child(bg)
	move_child(bg, 0)

	# Persistent canvas (Image → ImageTexture → Sprite2D for GPU blit)
	_canvas  = Image.create(CANVAS_W, CANVAS_H, false, Image.FORMAT_RGBA8)
	_canvas.fill(Color(0, 0, 0, 0))
	_texture = ImageTexture.create_from_image(_canvas)
	_sprite  = Sprite2D.new()
	_sprite.texture = _texture
	_sprite.position = vp_size * 0.5
	_sprite.scale    = vp_size / Vector2(CANVAS_W, CANVAS_H)
	add_child(_sprite)

	# UI
	var t := Label.new()
	t.text = "EDGE REVEAL"
	t.add_theme_font_size_override("font_size", 34)
	t.modulate = Color(0.85, 1.0, 0.85)
	t.position = Vector2(24, 18)
	add_child(t)
	var s := Label.new()
	s.text = "Edge / Canny tracker · outlines etch into the canvas · loud sound = wipe"
	s.add_theme_font_size_override("font_size", 15)
	s.modulate = Color(0.85, 1.0, 0.85, 0.75)
	s.position = Vector2(24, 58)
	add_child(s)


func set_audio_level(level: float) -> void:
	audio_level = clamp(level, 0.0, 1.0)

# ─────────────────────────────────────────────────────────────────────────────

func _stamp(cx: int, cy: int, col: Color) -> void:
	var r : int = MARK_RADIUS
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy <= r * r:
				var px : int = clamp(cx + dx, 0, CANVAS_W - 1)
				var py : int = clamp(cy + dy, 0, CANVAS_H - 1)
				var existing : Color = _canvas.get_pixel(px, py)
				var blended  : Color = existing.lerp(col, 0.45)
				_canvas.set_pixel(px, py, blended)
	_dirty = true


func _wipe_canvas() -> void:
	_canvas.fill(Color(0, 0, 0, 0))
	_dirty = true
	# Burst of white dots
	for _i in range(60):
		var pos := Vector2(randf_range(0, CANVAS_W), randf_range(0, CANVAS_H))
		_stamp(int(pos.x), int(pos.y), Color(1, 1, 1, 0.6))

# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	var prev_audio : float = _audio_sm
	_audio_sm  = lerp(_audio_sm, audio_level, delta * 6.0)
	_wipe_cool -= delta

	# Loud sound → wipe
	if _audio_sm > 0.75 and (prev_audio < 0.55) and _wipe_cool <= 0.0:
		_wipe_canvas()
		_wipe_cool = 2.5

	# ── Slowly fade canvas ─────────────────────────────────────────────
	# (Only if something is on it — fade entire image by scaling alpha pixel-wise
	#  is expensive; instead we track alpha in our mark buffer and re-draw.)
	# We fade the entire canvas image by drawing a semi-transparent black rect.
	# In Godot 4, Image has fill_rect with blend — approximate with a global fade:
	var fade_amt : float = FADE_SPEED * delta
	if fade_amt > 0.0:
		# Modulate sprite alpha to simulate fade (not pixel-perfect but cheap)
		_sprite.modulate.a = clamp(_sprite.modulate.a, 0.0, 1.0)
		# Actual pixel fade on the image (done in batches to stay cheap)
		# We do a full sweep only every ~10 frames
		if Engine.get_process_frames() % 10 == 0:
			var fade_col := Color(0.0, 0.0, 0.0, fade_amt * 10.0)
			for py in range(0, CANVAS_H, 2):
				for px in range(0, CANVAS_W, 2):
					var c : Color = _canvas.get_pixel(px, py)
					if c.a > 0.005:
						c.a = max(0.0, c.a - fade_amt * 10.0)
						_canvas.set_pixel(px, py, c)
			_dirty = true

	# ── Gather touches → spotlight torches ────────────────────────────
	var interactions := get_parent().get_node_or_null("Interactions")
	var active_ids   : Dictionary = {}

	if interactions:
		for touch in interactions.get_children():
			var id  : int     = touch.get_instance_id()
			var sp  : Vector2 = touch.position + touch.pivot_offset
			active_ids[id] = sp

			# Stamp a glowing mark at the touch position
			var cx : int = int(sp.x / vp_size.x * CANVAS_W)
			var cy : int = int(sp.y / vp_size.y * CANVAS_H)
			# Hue from position
			var hue : float = fmod(sp.x / vp_size.x + _audio_sm * 0.3, 1.0)
			var col : Color = Color.from_hsv(hue, 0.6, 1.0, 0.75 + _audio_sm * 0.25)
			_stamp(cx, cy, col)

			# Torch node
			if not _torches.has(id):
				var torch := ColorRect.new()
				torch.size         = Vector2(120, 120)
				torch.pivot_offset = Vector2(60, 60)
				torch.color        = Color(1.0, 0.95, 0.8, 0.08)
				add_child(torch)
				_torches[id] = torch
			var tr : ColorRect = _torches[id]
			tr.position = sp - Vector2(60, 60)
			var tr_size : float = 80.0 + _audio_sm * 80.0
			tr.size         = Vector2(tr_size * 2.0, tr_size * 2.0)
			tr.pivot_offset = Vector2(tr_size, tr_size)

	# Remove stale torches
	var to_rm : Array = []
	for id in _torches:
		if not active_ids.has(id):
			to_rm.append(id)
	for id in to_rm:
		_torches[id].queue_free()
		_torches.erase(id)

	# ── Upload texture if dirty ────────────────────────────────────────
	if _dirty:
		_texture.update(_canvas)
		_dirty = false
