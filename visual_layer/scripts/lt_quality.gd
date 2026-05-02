extends Node
## Global quality tier autoload.
## Access via LTQuality.level, LTQuality.step_up(), LTQuality.step_down()
## 0 = PERFORMANCE  |  1 = BALANCED  |  2 = FULL BEAUTY

var level: int = 1

const LEVEL_NAMES  : Array = ["PERFORMANCE", "BALANCED", "FULL BEAUTY"]
const LEVEL_COLORS : Array = [
	Color(0.55, 0.90, 0.55),   # green
	Color(1.00, 0.85, 0.35),   # amber
	Color(0.40, 0.95, 1.00),   # cyan
]

signal quality_changed(new_level: int)

func set_level(l: int) -> void:
	level = clamp(l, 0, 2)
	quality_changed.emit(level)

func step_up()   -> void: set_level(level + 1)
func step_down() -> void: set_level(level - 1)

func level_name()  -> String: return LEVEL_NAMES[level]
func level_color() -> Color:  return LEVEL_COLORS[level]

## 0.4 / 1.0 / 2.0 — multiply particle counts by this
func particle_scale() -> float:
	match level:
		0: return 0.40
		1: return 1.00
		2: return 2.00
	return 1.0
