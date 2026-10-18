## Loopback TCP server allowing external processes (such as the DreamAiri Godot
## editor plugin) to drive the live composition over a framed JSON protocol.
##
## Note on export formats: export_formats defaults to ["midi"] only. Remote WAV
## rendering is not supported and must be done by the user via File > Export in the app.
class_name RemoteControl extends Node

signal shutdown_requested()
signal client_connected()
signal client_disconnected()

const MAX_FRAME_SIZE: int = 4 * 1024 * 1024 # 4 MiB
const DEFAULT_HELLO_TIMEOUT_MS: int = 5000

const DEFAULT_TOOLS: Array[String] = [
	"create_song",
	"add_instrument",
	"remove_instrument",
	"create_pattern",
	"add_notes",
	"remove_notes",
	"set_arrangement",
	"set_effect",
	"get_song_state",
	"play_song",
	"list_instruments",
	"snapshot",
	"load_song",
	"save_song",
	"export_song",
]

var bind_address: String = "127.0.0.1"
var hello_timeout_ms: int = DEFAULT_HELLO_TIMEOUT_MS
var tools: Array = []
## Advertised export formats. Defaults to ["midi"] always; WAV export is not supported remotely.
var export_formats: Array = []

var _server: TCPServer = null
var _port: int = 0
var _is_listening: bool = false
var _executor: Callable = Callable()
var _handoff: Dictionary = {}
var _secret: String = ""
var _ready_file_path: String = ""
var _output_dir: String = ""
var _app_version: String = "1.0"

var _client: StreamPeerTCP = null
var _client_connected_time_ms: int = 0
var _hello_received: bool = false
var _rx_buffer: PackedByteArray = PackedByteArray()
var _expected_frame_len: int = -1


## Initializes the RemoteControl server.
## custom_export allows overriding the advertised formats (used by tests; defaults to ["midi"]).
func _init(handoff: Dictionary = {}, executor: Callable = Callable(), custom_tools: Array = [], custom_export: Array = []) -> void:
	_handoff = handoff
	_executor = executor
	_secret = str(_handoff.get("secret", ""))
	_ready_file_path = str(_handoff.get("ready_file", ""))
	_output_dir = str(_handoff.get("output_dir", ""))
	_app_version = str(ProjectSettings.get_setting("application/config/version", "1.0"))
	
	if not custom_tools.is_empty():
		tools = custom_tools.duplicate()
	else:
		tools = DEFAULT_TOOLS.duplicate()
	
	if not custom_export.is_empty():
		export_formats = custom_export.duplicate()
	else:
		export_formats = ["midi"]
	
	_server = TCPServer.new()


func _ready() -> void:
	if not _is_listening:
		start()


func _exit_tree() -> void:
	stop()


func start() -> Error:
	if _is_listening:
		return OK
	
	var err: Error = _server.listen(0, bind_address)
	if err != OK:
		printerr("RemoteControl: failed to bind TCPServer to %s (error %d)" % [bind_address, err])
		return err
	
	_port = _server.get_local_port()
	_is_listening = true
	_write_ready_file()
	return OK


func stop() -> void:
	if _client != null:
		_close_client("server stopped")
	if _server != null and _is_listening:
		_server.stop()
		_is_listening = false


func get_port() -> int:
	return _port


func get_bind_address() -> String:
	return bind_address


func is_client_connected() -> bool:
	return _client != null and _client.get_status() == StreamPeerTCP.STATUS_CONNECTED and _hello_received


func send_event(name: String) -> void:
	if _client == null or _client.get_status() != StreamPeerTCP.STATUS_CONNECTED or not _hello_received:
		return
	_send_frame({"event": name})


func _process(_delta: float) -> void:
	poll()


func poll() -> void:
	if not _is_listening:
		return
	
	# Check for incoming connection
	if _server.is_connection_available():
		var new_peer: StreamPeerTCP = _server.take_connection()
		if _client != null and _client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			# Reject second concurrent client
			new_peer.disconnect_from_host()
			new_peer.poll()
		else:
			# Accept new client
			_client = new_peer
			_client.poll()
			_rx_buffer.clear()
			_expected_frame_len = -1
			_hello_received = false
			_client_connected_time_ms = Time.get_ticks_msec()
			client_connected.emit()
	
	if _client == null:
		return
	
	_client.poll()
	var status: StreamPeerTCP.Status = _client.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_client = null
		_rx_buffer.clear()
		_expected_frame_len = -1
		_hello_received = false
		client_disconnected.emit()
		return
	
	if not _hello_received:
		if Time.get_ticks_msec() - _client_connected_time_ms > hello_timeout_ms:
			_close_client("hello timeout")
			return
	
	var bytes_avail: int = _client.get_available_bytes()
	if bytes_avail > 0:
		var res: Array = _client.get_data(bytes_avail)
		var err: int = int(res[0])
		var chunk: PackedByteArray = res[1]
		if err != OK:
			_close_client("read error %d" % err)
			return
		if chunk.size() > 0:
			_rx_buffer.append_array(chunk)
	
	while _client != null:
		if _expected_frame_len < 0:
			if _rx_buffer.size() < 4:
				break
			var b0: int = _rx_buffer[0]
			var b1: int = _rx_buffer[1]
			var b2: int = _rx_buffer[2]
			var b3: int = _rx_buffer[3]
			_expected_frame_len = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
			if _expected_frame_len < 0 or _expected_frame_len > MAX_FRAME_SIZE:
				_close_client("oversized frame: %d" % _expected_frame_len)
				return
		
		if _rx_buffer.size() < 4 + _expected_frame_len:
			break
		
		var payload: PackedByteArray = _rx_buffer.slice(4, 4 + _expected_frame_len)
		_rx_buffer = _rx_buffer.slice(4 + _expected_frame_len)
		_expected_frame_len = -1
		
		var json_str: String = payload.get_string_from_utf8()
		var json := JSON.new()
		var parse_err: Error = json.parse(json_str)
		if parse_err != OK or not (json.data is Dictionary):
			_close_client("malformed JSON frame")
			return
		
		var frame: Dictionary = json.data
		_handle_frame(frame)


func _handle_frame(frame: Dictionary) -> void:
	var op: String = str(frame.get("op", ""))
	
	if not _hello_received:
		if op != "hello":
			_close_client("non-hello first frame: %s" % op)
			return
		_handle_hello(frame)
		return
	
	var req_id: Variant = frame.get("id", null)
	match op:
		"ping":
			var reply: Dictionary = {"ok": true, "result": {}}
			if req_id != null:
				reply["id"] = req_id
			_send_frame(reply)
		
		"shutdown":
			var reply: Dictionary = {"ok": true, "result": {}}
			if req_id != null:
				reply["id"] = req_id
			_send_frame(reply)
			shutdown_requested.emit()
		
		"tool":
			var tool_name: String = str(frame.get("name", ""))
			var args: Dictionary = {}
			if frame.get("args") is Dictionary:
				args = frame.get("args")
			
			var result: Dictionary = {}
			if _executor.is_valid():
				var exec_res: Variant = _executor.call(tool_name, args)
				if exec_res is Dictionary:
					result = exec_res
				else:
					result = {"error": "Invalid executor response"}
			else:
				result = {"error": "No executor configured"}
			
			var reply: Dictionary = {"ok": true, "result": result}
			if req_id != null:
				reply["id"] = req_id
			_send_frame(reply)
		
		_:
			var reply: Dictionary = {"ok": false, "error": "unknown op: %s" % op}
			if req_id != null:
				reply["id"] = req_id
			_send_frame(reply)


func _handle_hello(frame: Dictionary) -> void:
	var client_protocol: int = int(frame.get("protocol", 0))
	if client_protocol != 1:
		_send_frame({"ok": false, "error": "unsupported protocol: %d" % client_protocol})
		_close_client("unsupported protocol")
		return
	
	var client_secret: String = str(frame.get("secret", ""))
	if not constant_time_compare(client_secret, _secret):
		_send_frame({"ok": false, "error": "invalid secret"})
		_close_client("invalid secret")
		return
	
	_hello_received = true
	var reply: Dictionary = {
		"ok": true,
		"protocol": 1,
		"app_version": _app_version,
		"tools": tools,
		"export": export_formats,
	}
	_send_frame(reply)


func _send_frame(dict: Dictionary) -> Error:
	if _client == null or _client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return ERR_CONNECTION_ERROR
	
	var json_str: String = JSON.stringify(dict)
	var payload: PackedByteArray = json_str.to_utf8_buffer()
	var payload_len: int = payload.size()
	if payload_len > MAX_FRAME_SIZE:
		printerr("RemoteControl: outgoing frame exceeds 4 MiB: %d" % payload_len)
		return ERR_OUT_OF_MEMORY
	
	var header: PackedByteArray = PackedByteArray()
	header.resize(4)
	header[0] = (payload_len >> 24) & 0xff
	header[1] = (payload_len >> 16) & 0xff
	header[2] = (payload_len >> 8) & 0xff
	header[3] = payload_len & 0xff
	
	var err: Error = _client.put_data(header)
	if err != OK:
		return err
	err = _client.put_data(payload)
	return err


func _close_client(_reason: String = "") -> void:
	if _client != null:
		_client.disconnect_from_host()
		_client.poll()
		_client = null
	_rx_buffer.clear()
	_expected_frame_len = -1
	_hello_received = false
	client_disconnected.emit()


func _write_ready_file() -> void:
	if _ready_file_path.is_empty():
		return
	var dir: String = _ready_file_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	
	var data: Dictionary = {
		"port": _port,
		"pid": OS.get_process_id(),
		"app_version": _app_version,
	}
	var json_str: String = JSON.stringify(data)
	var tmp_path: String = _ready_file_path + ".tmp.%d" % OS.get_process_id()
	var file: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		printerr("RemoteControl: failed to open ready file for writing: %s" % tmp_path)
		return
	file.store_string(json_str)
	file.flush()
	file.close()
	
	var err: Error = DirAccess.rename_absolute(tmp_path, _ready_file_path)
	if err != OK:
		var cp_err: Error = DirAccess.copy_absolute(tmp_path, _ready_file_path)
		if cp_err == OK:
			DirAccess.remove_absolute(tmp_path)
		else:
			printerr("RemoteControl: failed to move ready file to %s (error %d)" % [_ready_file_path, err])


static func constant_time_compare(a: String, b: String) -> bool:
	var a_bytes: PackedByteArray = a.to_utf8_buffer()
	var b_bytes: PackedByteArray = b.to_utf8_buffer()
	var diff: int = a_bytes.size() ^ b_bytes.size()
	var min_len: int = mini(a_bytes.size(), b_bytes.size())
	for i in min_len:
		diff |= (a_bytes[i] ^ b_bytes[i])
	return diff == 0
