extends Node

var server: UDPServer
var port: int = 7000

signal interaction_received(id: int, pos: Vector2, state: String)

func _ready():
	server = UDPServer.new()
	var err = server.listen(port)
	if err != OK:
		print("Network Receiver: Error listening on port ", port)
	else:
		print("Network Receiver: Listening on port ", port)

func _process(_delta):
	server.poll()
	if server.is_connection_available():
		var peer = server.take_connection()
		var packet = peer.get_packet()
		_parse_json_packet(packet)

func _parse_json_packet(packet: PackedByteArray):
	var json_string = packet.get_string_from_utf8()
	var json = JSON.new()
	var error = json.parse(json_string)
	if error == OK:
		var data = json.data
		if data.has("type") and data["type"] == "interaction":
			var pos = Vector2(data["x"], data["y"])
			interaction_received.emit(int(data["id"]), pos, data["state"])

