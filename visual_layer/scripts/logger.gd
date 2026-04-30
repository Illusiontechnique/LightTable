extends Node

# ─────────────────────────────────────────────────────────────────────────────
#  Logger — autoload singleton
#
#  Writes structured log lines to  user://logs/YYYY-MM-DD.log
#  On startup, any log file older than 7 days is deleted automatically.
#
#  Usage anywhere in the project:
#      Logger.info("System ready")
#      Logger.warn("Calibration data missing")
#      Logger.error("Shader failed to load")
#      Logger.event("scene_load", {"scene": "water", "fps": Engine.get_frames_per_second()})
#
#  Read recent logs at runtime:
#      var lines = Logger.read_recent(3)   # last 3 days, returns Array[String]
# ─────────────────────────────────────────────────────────────────────────────

const MAX_AGE_DAYS  := 7
const LOG_DIR       := "user://logs"

var _log_file  : FileAccess = null
var _today_path : String    = ""

# ── Startup ───────────────────────────────────────────────────────────────────

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(LOG_DIR)
	_purge_old_logs()
	_open_today()
	info("=== LightTable session start ===")
	var ver : Dictionary = Engine.get_version_info()
	info("Godot %s | OS: %s | renderer: %s" % [
		ver.get("string", "?"),
		OS.get_name(),
		RenderingServer.get_video_adapter_name(),
	])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		info("=== session end ===")
		if _log_file:
			_log_file.close()
			_log_file = null

# ── Public API ────────────────────────────────────────────────────────────────

func info(msg: String) -> void:
	_write("INFO ", msg)

func warn(msg: String) -> void:
	_write("WARN ", msg)

func error(msg: String) -> void:
	_write("ERROR", msg)

## Log a named event with an optional dict of key/value metadata.
func event(name: String, meta: Dictionary = {}) -> void:
	var parts := PackedStringArray()
	for k in meta:
		parts.append("%s=%s" % [k, str(meta[k])])
	_write("EVENT", "[%s] %s" % [name, " | ".join(parts)])

## Return all log lines from the last `days` days as an Array[String].
## Newest entries are last.
func read_recent(days: int = 7) -> Array:
	var out : Array = []
	for i in range(days - 1, -1, -1):
		var date : Dictionary = Time.get_date_dict_from_unix_time(
			int(Time.get_unix_time_from_system()) - i * 86400
		)
		var path : String = _path_for(date)
		if not FileAccess.file_exists(path):
			continue
		var f : FileAccess = FileAccess.open(path, FileAccess.READ)
		if not f:
			continue
		while not f.eof_reached():
			var line : String = f.get_line()
			if line.strip_edges() != "":
				out.append(line)
		f.close()
	return out

## Print the last `lines` log lines to the Godot output (handy for quick review).
func dump(lines: int = 40) -> void:
	var all : Array = read_recent(MAX_AGE_DAYS)
	var start : int = max(0, all.size() - lines)
	for i in range(start, all.size()):
		print(all[i])

# ── Internals ─────────────────────────────────────────────────────────────────

func _write(level: String, msg: String) -> void:
	# Roll file at midnight
	var now_date : Dictionary = Time.get_date_dict_from_unix_time(int(Time.get_unix_time_from_system()))
	var current_path : String = _path_for(now_date)
	if current_path != _today_path:
		_open_today()

	var ts   : String = Time.get_time_string_from_system()
	var line : String = "[%s][%s] %s" % [ts, level, msg]

	print(line)

	if _log_file:
		_log_file.store_line(line)
		_log_file.flush()


func _open_today() -> void:
	if _log_file:
		_log_file.close()
	var date : Dictionary = Time.get_date_dict_from_unix_time(int(Time.get_unix_time_from_system()))
	_today_path = _path_for(date)
	_log_file = FileAccess.open(_today_path, FileAccess.READ_WRITE)
	if not _log_file:
		# File doesn't exist yet — create it
		_log_file = FileAccess.open(_today_path, FileAccess.WRITE)
	if _log_file:
		_log_file.seek_end()   # append mode


func _path_for(date: Dictionary) -> String:
	return "%s/%04d-%02d-%02d.log" % [LOG_DIR, date["year"], date["month"], date["day"]]


func _purge_old_logs() -> void:
	var cutoff : int = int(Time.get_unix_time_from_system()) - MAX_AGE_DAYS * 86400
	var dir : DirAccess = DirAccess.open(LOG_DIR)
	if not dir:
		return
	dir.list_dir_begin()
	var fname : String = dir.get_next()
	while fname != "":
		if fname.ends_with(".log"):
			var full : String = LOG_DIR + "/" + fname
			var modified : int = int(FileAccess.get_modified_time(full))
			if int(modified) < cutoff:
				dir.remove(fname)
				print("[Logger] Purged old log: ", fname)
		fname = dir.get_next()
	dir.list_dir_end()
