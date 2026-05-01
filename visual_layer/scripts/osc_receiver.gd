extends Node

var peer : PacketPeerUDP
var port: int = 7000

signal interaction_received(id: int, pos: Vector2, state: String)
signal remote_command(cmd: Dictionary)
signal hand_skeleton_received(hands: Array)

func _ready():
	peer = PacketPeerUDP.new()
	var err = peer.bind(port)
	if err != OK:
		print("Network Receiver: Error binding on port ", port)
	else:
		print("Network Receiver: Listening on port ", port)

func _process(_delta):
	while peer.get_available_packet_count() > 0:
		_parse_json_packet(peer.get_packet())

func _parse_json_packet(packet: PackedByteArray):
	var json_string = packet.get_string_from_utf8()
	var json = JSON.new()
	var error = json.parse(json_string)
	if error == OK:
		var data = json.data
		if data.has("type"):
			if data["type"] == "interaction":
				var pos = Vector2(data["x"], data["y"])
				interaction_received.emit(int(data["id"]), pos, data["state"])
			elif data["type"] == "command":
				remote_command.emit(data)
			elif data["type"] == "hand_skeleton":
				hand_skeleton_received.emit(data["hands"])

