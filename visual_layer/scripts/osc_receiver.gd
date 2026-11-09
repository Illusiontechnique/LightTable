extends Node

var peer: PacketPeerUDP
var port: int = 7000
var _remote_host := ""

signal interaction_received(id: int, pos: Vector2, state: String, metadata: Dictionary)
signal remote_command(cmd: Dictionary)
signal hand_skeleton_received(hands: Array)
signal track_mode_changed(mode: String)
signal frame_motion_received(amount: float, points: Array)

func _ready():
	peer = PacketPeerUDP.new()
	var err = peer.bind(port)
	if err != OK:
		push_error("Network Receiver: Error binding on port %d (error %d)" % [port, err])
	else:
		print("Network Receiver: Listening on port ", port)

func _process(_delta):
	while peer.get_available_packet_count() > 0:
		var packet = peer.get_packet()
		var sender_ip = peer.get_packet_ip()
		_parse_json_packet(packet, sender_ip)

func _parse_json_packet(packet: PackedByteArray, sender_ip: String = ""):
	if packet.size() > 65507:
		push_warning("Network Receiver: Oversized UDP packet ignored")
		return
	var json = JSON.new()
	var error = json.parse(packet.get_string_from_utf8())
	if error != OK:
		push_warning("Network Receiver: Invalid JSON packet ignored")
		return
	if typeof(json.data) != TYPE_DICTIONARY:
		push_warning("Network Receiver: Invalid JSON packet ignored")
		return
	var data: Dictionary = json.data
	var packet_type = data.get("type", "")
	match packet_type:
		"interaction":
			if not data.has("id") or not data.has("x") or not data.has("y"):
				return
			var id_value = data.get("id")
			var x_value = data.get("x")
			var y_value = data.get("y")
			if typeof(id_value) != TYPE_INT and typeof(id_value) != TYPE_FLOAT:
				return
			if not is_finite(float(id_value)) or id_value < 0 or id_value > 2147483647 or floor(float(id_value)) != float(id_value):
				return
			var invalid_x = typeof(x_value) != TYPE_INT and typeof(x_value) != TYPE_FLOAT
			var invalid_y = typeof(y_value) != TYPE_INT and typeof(y_value) != TYPE_FLOAT
			if invalid_x or invalid_y:
				return
			if not is_finite(float(x_value)) or not is_finite(float(y_value)):
				return
			if x_value < 0.0 or x_value > 1.0 or y_value < 0.0 or y_value > 1.0:
				return
			var pos = Vector2(float(x_value), float(y_value))
			interaction_received.emit(int(id_value), pos, str(data.get("event", data.get("state", "move"))), data)
		"command":
			if typeof(data.get("cmd", "")) == TYPE_STRING:
				_remote_host = sender_ip
				remote_command.emit(data)
		"hand_skeleton":
			if typeof(data.get("hands", [])) == TYPE_ARRAY:
				hand_skeleton_received.emit(data.get("hands", []))
		"frame_motion":
			var amount = data.get("amount")
			var points = data.get("points")
			if (typeof(amount) != TYPE_INT and typeof(amount) != TYPE_FLOAT) or not is_finite(float(amount)):
				return
			if typeof(points) != TYPE_ARRAY or points.size() > 8:
				return
			var valid_points: Array = []
			for point in points:
				if typeof(point) != TYPE_DICTIONARY:
					return
				var x = point.get("x")
				var y = point.get("y")
				if (typeof(x) != TYPE_INT and typeof(x) != TYPE_FLOAT) or (typeof(y) != TYPE_INT and typeof(y) != TYPE_FLOAT):
					return
				if not is_finite(float(x)) or not is_finite(float(y)) or x < 0.0 or x > 1.0 or y < 0.0 or y > 1.0:
					return
				valid_points.append(Vector2(float(x), float(y)))
			frame_motion_received.emit(clampf(float(amount), 0.0, 1.0), valid_points)
		"track_mode_change":
			if typeof(data.get("mode", "")) == TYPE_STRING:
				track_mode_changed.emit(data.mode)

func send_status(scene_name: String, request_id: String = ""):
	if _remote_host.is_empty() or not peer.is_bound():
		return
	if peer.set_dest_address(_remote_host, 7001) != OK:
		return
	var status := {"type": "godot_status", "scene": scene_name}
	if not request_id.is_empty():
		status["request_id"] = request_id
	peer.put_packet(JSON.stringify(status).to_utf8_buffer())
