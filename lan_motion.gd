extends Node

signal player_changed(player: int)

const FIRST_PORT := 8810
const HANDSHAKE_TIMEOUT := 6000
const HEARTBEAT_TIMEOUT := 5000
const SAMPLE_TIMEOUT := 1400
const INPUT_TIMEOUT := 1400
const MAX_CONNECTIONS := 24
const BUTTON_MASK := 15
const EMPTY_SAMPLE := [null, null, null, null, null, null, null, null, null]
const CLIENT_STATES := ["waiting", "denied", "unsupported", "no_data", "paused", "live"]
const Certificate = preload("res://motion_certificate.gd")

enum Mode { SETUP, SENSOR, SOCKET }

class Pending:
	var tcp: StreamPeerTCP
	var tls: StreamPeerTLS
	var mode: Mode
	var deadline: int
	var request := PackedByteArray()
	var response := PackedByteArray()
	var sent := 0

class Phone:
	var socket: WebSocketPeer
	var deadline: int
	var player := -1
	var state := "waiting"
	var sample: Array = EMPTY_SAMPLE
	var last_sample := 0
	var stick := Vector2.ZERO
	var buttons := 0
	var last_input := 0
	var pose: Variant = null
	var last_pose := 0

var addresses: Array[String] = []
var setup_port := 0
var error := ""
var _setup_page := ""
var _sensor_page := ""
var _certificate := Certificate.new()
var _tls: TLSOptions
var _listeners: Array[TCPServer] = [TCPServer.new(), TCPServer.new(), TCPServer.new()]
var _pending: Array[Pending] = []
var _phones: Array[Phone] = []
var _players: Array[Phone] = [null, null]
var _tokens: Array[String] = []

func _ready() -> void:
	_setup_page = FileAccess.get_file_as_string("res://web/setup.html")
	_sensor_page = FileAccess.get_file_as_string("res://web/sensor.html")
	if _setup_page.is_empty() or _sensor_page.is_empty():
		error = "无法读取手机页面。"
		return
	_tls = _certificate.setup(addresses)
	if _tls == null:
		error = _certificate.error
		return
	for port in range(FIRST_PORT, FIRST_PORT + 15, 3):
		if _listen(port):
			setup_port = port
			break
	if setup_port == 0:
		error = "无法监听局域网端口 8810–8824。"
		return
	var crypto := Crypto.new()
	for player in range(2):
		_tokens.append(crypto.generate_random_bytes(8).hex_encode())

func _listen(port: int) -> bool:
	for index in range(_listeners.size()):
		if _listeners[index].listen(port + index, "0.0.0.0") != OK:
			for listener in _listeners:
				listener.stop()
			return false
	return true

func player_url(address: String, player: int) -> String:
	return "http://%s:%d%s" % [address, setup_port, _player_path(player)]

func _player_path(player: int) -> String:
	return "/%d/%s" % [player + 1, _tokens[player]]

func is_connected_player(player: int) -> bool:
	return _players[player] != null

func player_state(player: int) -> String:
	var phone := _players[player]
	return phone.state if phone != null else "disconnected"

func player_sample(player: int) -> Array:
	var phone := _players[player]
	return phone.sample if phone != null else EMPTY_SAMPLE

func player_stick(player: int) -> Vector2:
	var phone := _players[player]
	return phone.stick if phone != null else Vector2.ZERO

func player_buttons(player: int) -> int:
	var phone := _players[player]
	return phone.buttons if phone != null else 0

func player_pose(player: int) -> Variant:
	var phone := _players[player]
	return phone.pose if phone != null else null

func _process(_delta: float) -> void:
	if setup_port == 0:
		return
	var now := Time.get_ticks_msec()
	_accept(now)
	for index in range(_pending.size() - 1, -1, -1):
		var client := _pending[index]
		if not _poll_pending(client, now):
			_pending.remove_at(index)
	for index in range(_phones.size() - 1, -1, -1):
		var phone := _phones[index]
		if not _poll_phone(phone, now):
			_release(phone)
			phone.socket.close(-1)
			_phones.remove_at(index)

func _accept(now: int) -> void:
	for mode in range(_listeners.size()):
		var listener := _listeners[mode]
		for attempt in range(5):
			if not listener.is_connection_available():
				break
			var tcp := listener.take_connection()
			if tcp == null:
				break
			if _pending.size() >= MAX_CONNECTIONS:
				tcp.disconnect_from_host()
				continue
			tcp.set_no_delay(true)
			var client := Pending.new()
			client.tcp = tcp
			client.mode = mode as Mode
			client.deadline = now + HANDSHAKE_TIMEOUT
			if mode != Mode.SETUP:
				client.tls = StreamPeerTLS.new()
				if client.tls.accept_stream(tcp, _tls) != OK:
					continue
			_pending.append(client)

func _poll_pending(client: Pending, now: int) -> bool:
	if now > client.deadline:
		return false
	var stream: StreamPeer = client.tcp
	if client.tls != null:
		client.tls.poll()
		var status := client.tls.get_status()
		if status == StreamPeerTLS.STATUS_HANDSHAKING:
			return true
		if status != StreamPeerTLS.STATUS_CONNECTED:
			return false
		stream = client.tls
	else:
		client.tcp.poll()
		if client.tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return false

	if client.mode == Mode.SOCKET:
		if _phones.size() < MAX_CONNECTIONS:
			var phone := Phone.new()
			phone.socket = WebSocketPeer.new()
			phone.socket.inbound_buffer_size = 4096
			phone.socket.max_queued_packets = 32
			if phone.socket.accept_stream(stream) == OK:
				phone.deadline = now + HANDSHAKE_TIMEOUT
				_phones.append(phone)
		return false
	if client.response.is_empty():
		var available := stream.get_available_bytes()
		if available == 0:
			return true
		if client.request.size() + available > 8192:
			return false
		var received := stream.get_partial_data(available)
		if received[0] != OK:
			return false
		client.request.append_array(received[1])
		var request := client.request.get_string_from_utf8()
		if not request.contains("\r\n\r\n"):
			return true
		client.response = _http_response(request.get_slice("\r\n", 0), client.mode)
	var written := stream.put_partial_data(client.response.slice(client.sent))
	if written[0] != OK:
		return false
	client.sent += int(written[1])
	return client.sent < client.response.size()

func _http_response(line: String, mode: Mode) -> PackedByteArray:
	var fields := line.split(" ", false)
	if fields.size() == 3 and fields[0] == "GET":
		var path := fields[1].get_slice("?", 0)
		if mode == Mode.SETUP and path == "/motion.mobileconfig":
			return _response("200 OK", "application/x-apple-aspen-config", _certificate.profile,
				"Content-Disposition: attachment; filename=godot-phone-motion.mobileconfig\r\n")
		if mode == Mode.SETUP and path == "/motion.crt":
			return _response("200 OK", "application/x-x509-ca-cert", _certificate.der,
				"Content-Disposition: attachment; filename=godot-phone-motion.crt\r\n")
		for player in range(2):
			if path != _player_path(player):
				continue
			var config := JSON.stringify({
				"player": player + 1, "token": _tokens[player], "setupPort": setup_port,
				"httpsPort": setup_port + 1, "socketPort": setup_port + 2
			})
			var page := _setup_page if mode == Mode.SETUP else _sensor_page
			return _response("200 OK", "text/html; charset=utf-8",
				page.replace("__CONFIG__", config).to_utf8_buffer())
	return _response("404 Not Found", "text/plain; charset=utf-8",
		"请扫描 Godot 屏幕上的玩家二维码。".to_utf8_buffer())

func _response(status: String, mime: String, body: PackedByteArray,
		extra := "") -> PackedByteArray:
	var header := ("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n" +
		"Connection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n" +
		"X-Content-Type-Options: nosniff\r\n%s\r\n") % [status, mime, body.size(), extra]
	return header.to_utf8_buffer() + body

func _poll_phone(phone: Phone, now: int) -> bool:
	var socket := phone.socket
	socket.poll()
	match socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			for packet_index in range(mini(socket.get_available_packet_count(), 32)):
				var packet := socket.get_packet()
				if not socket.was_string_packet() or packet.size() > 768:
					return false
				var message: Variant = JSON.parse_string(packet.get_string_from_utf8())
				if message is not Dictionary:
					return false
				if phone.player < 0:
					if not _join(phone, message, now):
						socket.close(1008, "join rejected")
						phone.deadline = now + 800
						return true
				else:
					_receive(phone, message, now)
		WebSocketPeer.STATE_CLOSING:
			_release(phone)
		WebSocketPeer.STATE_CLOSED:
			return false
	if phone.player >= 0:
		if phone.state == "live" and now - phone.last_sample > SAMPLE_TIMEOUT:
			_set_state(phone, "no_data")
		if now - phone.last_input > INPUT_TIMEOUT:
			_set_input(phone, Vector2.ZERO, 0)
		if now - phone.last_pose > SAMPLE_TIMEOUT and phone.pose != null:
			_set_pose(phone, null)
	return now <= phone.deadline

func _join(phone: Phone, message: Dictionary, now: int) -> bool:
	var seat: Variant = message.get("player")
	if message.get("type") != "join" or (seat != 1 and seat != 2):
		return false
	var player := int(seat) - 1
	if message.get("token") != _tokens[player]:
		return false
	if _players[player] != null:
		phone.socket.send_text('{"type":"busy"}')
		return false
	phone.player = player
	phone.deadline = now + HEARTBEAT_TIMEOUT
	_players[player] = phone
	phone.socket.send_text('{"type":"joined"}')
	player_changed.emit(player)
	return true

func _receive(phone: Phone, message: Dictionary, now: int) -> void:
	match message.get("type"):
		"pose":
			var angles: Variant = message.get("angles")
			if angles == null:
				_set_pose(phone, null)
				return
			if angles is not Array or angles.size() != 3:
				return
			for angle: Variant in angles:
				if not _is_number(angle) or absf(angle) > 360.0:
					return
			phone.deadline = now + HEARTBEAT_TIMEOUT
			phone.last_pose = now
			_set_pose(phone, Vector3(angles[0], angles[1], angles[2]))
		"input":
			var x: Variant = message.get("x")
			var y: Variant = message.get("y")
			var buttons: Variant = message.get("buttons")
			if not _is_number(x) or not _is_number(y) or not _is_number(buttons):
				return
			if absf(x) > 1.0 or absf(y) > 1.0 or buttons < 0 or buttons > BUTTON_MASK \
					or buttons != int(buttons):
				return
			phone.deadline = now + HEARTBEAT_TIMEOUT
			phone.last_input = now
			_set_input(phone, Vector2(x, y).limit_length(), int(buttons))
		"status":
			var state: Variant = message.get("state")
			if state not in CLIENT_STATES:
				return
			phone.deadline = now + HEARTBEAT_TIMEOUT
			if state != "live":
				_set_state(phone, state)
			if state == "paused":
				_set_pose(phone, null)
		"sample":
			var values: Variant = message.get("values")
			if values is not Array or values.size() != EMPTY_SAMPLE.size():
				return
			var has_data := false
			for value: Variant in values:
				if value == null:
					continue
				if not _is_number(value):
					return
				has_data = true
			if not has_data:
				return
			phone.deadline = now + HEARTBEAT_TIMEOUT
			phone.last_sample = now
			phone.state = "live"
			phone.sample = values
			player_changed.emit(phone.player)

func _is_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

func _set_pose(phone: Phone, pose: Variant) -> void:
	if phone.pose == pose:
		return
	phone.pose = pose
	player_changed.emit(phone.player)

func _set_input(phone: Phone, stick: Vector2, buttons: int) -> void:
	if phone.stick == stick and phone.buttons == buttons:
		return
	phone.stick = stick
	phone.buttons = buttons
	player_changed.emit(phone.player)

func _set_state(phone: Phone, state: String) -> void:
	if phone.state == state:
		return
	phone.state = state
	phone.sample = EMPTY_SAMPLE
	player_changed.emit(phone.player)

func _release(phone: Phone) -> void:
	if phone.player < 0:
		return
	var player := phone.player
	_players[player] = null
	phone.player = -1
	player_changed.emit(player)
