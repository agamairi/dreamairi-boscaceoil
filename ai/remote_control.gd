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
const RELAY_TIMEOUT_MS: int = 15000 # 15 s
const SONG_CHANGED_INTERVAL_MS: int = 100 # <= 10/s
const TRANSPORT_INTERVAL_MS: int = 66 # <= ~15/s

const DEFAULT_TOOLS: Array[String] = [
	"create_song",
	"add_instrument",
	"set_instrument",
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
	"get_transport",
	"set_tempo",
]

const VIEWER_TOOL_ALLOWLIST: Array[String] = [
	"get_song_state",
	"get_transport",
	"play_song",
	"set_tempo",
	"add_notes",
	"remove_notes",
	"create_pattern",
	"set_arrangement",
	"list_instruments",
	"add_instrument",
	"set_instrument",
]

class ClientSlot extends RefCounted:
	var peer: StreamPeerTCP = null
	var role: String = "" # "controller" or "viewer"
	var rx_buffer: PackedByteArray = PackedByteArray()
	var expected_frame_len: int = -1
	var connected_time_ms: int = 0
	var hello_received: bool = false
	
	func is_peer_connected() -> bool:
		return peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED

var bind_address: String = "127.0.0.1"
var hello_timeout_ms: int = DEFAULT_HELLO_TIMEOUT_MS
var relay_timeout_ms: int = RELAY_TIMEOUT_MS
var tools: Array = []
## Advertised export formats. Defaults to ["midi"] always; WAV export is not supported remotely.
var export_formats: Array = []

var _server: TCPServer = null
var _port: int = 0
var _is_listening: bool = false
var _executor: Callable = Callable()
var _handoff: Dictionary = {}
var _secret: String = ""
var _viewer_secret: String = ""
var _ready_file_path: String = ""
var _output_dir: String = ""
var _app_version: String = "1.0"

var _controller: ClientSlot = null
var _viewer: ClientSlot = null
var _pending_clients: Array[ClientSlot] = []

var _pending_relays: Dictionary = {}
var _next_rid: int = 0

var _song_version: int = 0
var _last_song_changed_ms: int = 0
var _song_changed_pending: bool = false

var _has_transport_state: bool = false
var _last_transport_playing: bool = false
var _last_transport_ms: int = 0


## Initializes the RemoteControl server.
## custom_export allows overriding the advertised formats (used by tests; defaults to ["midi"]).
func _init(handoff: Dictionary = {}, executor: Callable = Callable(), custom_tools: Array = [], custom_export: Array = []) -> void:
	_handoff = handoff
	_executor = executor
	_secret = str(_handoff.get("secret", ""))
	_ready_file_path = str(_handoff.get("ready_file", ""))
	_output_dir = str(_handoff.get("output_dir", ""))
	_app_version = str(ProjectSettings.get_setting("application/config/version", "1.0"))
	
	var raw_viewer_secret: String = str(_handoff.get("viewer_secret", ""))
	if raw_viewer_secret.length() == 64 and raw_viewer_secret != _secret:
		var secret_regex := RegEx.new()
		secret_regex.compile("^[0-9a-f]{64}$")
		if secret_regex.search(raw_viewer_secret) != null:
			_viewer_secret = raw_viewer_secret
		else:
			_viewer_secret = ""
	else:
		_viewer_secret = ""
	
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
	if _controller != null:
		_close_slot(_controller, "server stopped")
	if _viewer != null:
		_close_slot(_viewer, "server stopped")
	var pending_copy: Array[ClientSlot] = _pending_clients.duplicate()
	for slot: ClientSlot in pending_copy:
		_close_slot(slot, "server stopped")
	_pending_clients.clear()
	if _server != null and _is_listening:
		_server.stop()
		_is_listening = false


func get_port() -> int:
	return _port


func get_bind_address() -> String:
	return bind_address


func is_client_connected() -> bool:
	return (_controller != null and _controller.is_peer_connected() and _controller.hello_received) or (_viewer != null and _viewer.is_peer_connected() and _viewer.hello_received)


func is_controller_connected() -> bool:
	return _controller != null and _controller.is_peer_connected() and _controller.hello_received


func is_viewer_connected() -> bool:
	return _viewer != null and _viewer.is_peer_connected() and _viewer.hello_received


func send_event(name: String) -> void:
	_broadcast({"event": name})


func notify_song_changed() -> void:
	var now: int = Time.get_ticks_msec()
	if (now - _last_song_changed_ms >= SONG_CHANGED_INTERVAL_MS) and not _song_changed_pending:
		_song_version += 1
		_last_song_changed_ms = now
		_broadcast({"event": "song_changed", "version": _song_version})
	else:
		_song_changed_pending = true


func notify_transport(playing: bool, bar: int, step: int) -> void:
	var state_changed: bool = (not _has_transport_state) or (playing != _last_transport_playing)
	var now: int = Time.get_ticks_msec()
	if state_changed:
		_has_transport_state = true
		_last_transport_playing = playing
		_last_transport_ms = now
		_broadcast({
			"event": "transport",
			"playing": playing,
			"bar": bar,
			"step": step
		})
	elif now - _last_transport_ms >= TRANSPORT_INTERVAL_MS:
		_last_transport_ms = now
		_broadcast({
			"event": "transport",
			"playing": playing,
			"bar": bar,
			"step": step
		})


func _broadcast(dict: Dictionary) -> void:
	if _controller != null and _controller.is_peer_connected() and _controller.hello_received:
		_send_slot_frame(_controller, dict)
	if _viewer != null and _viewer.is_peer_connected() and _viewer.hello_received:
		_send_slot_frame(_viewer, dict)


func _process(_delta: float) -> void:
	poll()


func poll() -> void:
	if not _is_listening:
		return
	
	while _server.is_connection_available():
		var new_peer: StreamPeerTCP = _server.take_connection()
		if _pending_clients.size() >= 16:
			new_peer.disconnect_from_host()
			new_peer.poll()
		else:
			var slot: ClientSlot = ClientSlot.new()
			slot.peer = new_peer
			slot.connected_time_ms = Time.get_ticks_msec()
			_pending_clients.push_back(slot)
	
	var pending_copy: Array[ClientSlot] = _pending_clients.duplicate()
	for slot: ClientSlot in pending_copy:
		if slot in _pending_clients:
			_poll_slot(slot)
	
	if _controller != null:
		_poll_slot(_controller)
	
	if _viewer != null:
		_poll_slot(_viewer)
	
	_check_relay_timeouts()
	_check_song_changed_coalesce()


func _poll_slot(slot: ClientSlot) -> void:
	if slot.peer == null:
		return
	
	slot.peer.poll()
	var status: StreamPeerTCP.Status = slot.peer.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_close_slot(slot, "peer disconnected")
		return
	
	if not slot.hello_received:
		if Time.get_ticks_msec() - slot.connected_time_ms > hello_timeout_ms:
			_close_slot(slot, "hello timeout")
			return
	
	var bytes_avail: int = slot.peer.get_available_bytes()
	if bytes_avail > 0:
		var res: Array = slot.peer.get_data(bytes_avail)
		var err: int = int(res[0])
		var chunk: PackedByteArray = res[1]
		if err != OK:
			_close_slot(slot, "read error %d" % err)
			return
		if chunk.size() > 0:
			slot.rx_buffer.append_array(chunk)
	
	while slot.peer != null:
		if slot.expected_frame_len < 0:
			if slot.rx_buffer.size() < 4:
				break
			var b0: int = slot.rx_buffer[0]
			var b1: int = slot.rx_buffer[1]
			var b2: int = slot.rx_buffer[2]
			var b3: int = slot.rx_buffer[3]
			slot.expected_frame_len = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
			if slot.expected_frame_len < 0 or slot.expected_frame_len > MAX_FRAME_SIZE:
				_close_slot(slot, "oversized frame: %d" % slot.expected_frame_len)
				return
		
		if slot.rx_buffer.size() < 4 + slot.expected_frame_len:
			break
		
		var payload: PackedByteArray = slot.rx_buffer.slice(4, 4 + slot.expected_frame_len)
		slot.rx_buffer = slot.rx_buffer.slice(4 + slot.expected_frame_len)
		slot.expected_frame_len = -1
		
		var json_str: String = payload.get_string_from_utf8()
		var json: JSON = JSON.new()
		var parse_err: Error = json.parse(json_str)
		if parse_err != OK or not (json.data is Dictionary):
			_close_slot(slot, "malformed JSON frame")
			return
		
		var frame: Dictionary = json.data
		_handle_frame_for_slot(slot, frame)


func _handle_frame_for_slot(slot: ClientSlot, frame: Dictionary) -> void:
	var op: String = str(frame.get("op", ""))
	
	if not slot.hello_received:
		if op != "hello":
			_close_slot(slot, "non-hello first frame: %s" % op)
			return
		_handle_hello(slot, frame)
		return
	
	var req_id: Variant = frame.get("id", null)
	match op:
		"ping":
			var reply: Dictionary = {"ok": true, "result": {}}
			if req_id != null:
				reply["id"] = req_id
			_send_slot_frame(slot, reply)
		
		"shutdown":
			if slot.role != "controller":
				var reply: Dictionary = {"ok": false, "error": "shutdown not allowed for viewer"}
				if req_id != null:
					reply["id"] = req_id
				_send_slot_frame(slot, reply)
				return
			
			var reply: Dictionary = {"ok": true, "result": {}}
			if req_id != null:
				reply["id"] = req_id
			_send_slot_frame(slot, reply)
			shutdown_requested.emit()
		
		"tool":
			var tool_name: String = str(frame.get("name", ""))
			if slot.role == "viewer" and not (tool_name in VIEWER_TOOL_ALLOWLIST):
				var reply: Dictionary = {
					"ok": true,
					"result": {"error": "tool not allowed for viewer"}
				}
				if req_id != null:
					reply["id"] = req_id
				_send_slot_frame(slot, reply)
				return
			
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
			_send_slot_frame(slot, reply)
		
		"relay":
			var action: String = str(frame.get("action", ""))
			if action != "save" and action != "rate":
				var reply: Dictionary = {"ok": false, "error": "unknown action: %s" % action}
				if req_id != null:
					reply["id"] = req_id
				_send_slot_frame(slot, reply)
				return
			
			if _controller == null or not _controller.is_peer_connected() or not _controller.hello_received:
				var reply: Dictionary = {"ok": false, "error": "no_controller"}
				if req_id != null:
					reply["id"] = req_id
				_send_slot_frame(slot, reply)
				return
			
			_next_rid += 1
			var rid: int = _next_rid
			var relay_args: Dictionary = {}
			if frame.get("args") is Dictionary:
				relay_args = frame.get("args")
			
			_pending_relays[rid] = {
				"id": req_id,
				"viewer": slot,
				"created_ms": Time.get_ticks_msec(),
			}
			
			var forward_event: Dictionary = {
				"event": "relay_request",
				"rid": rid,
				"action": action,
				"args": relay_args,
			}
			_send_slot_frame(_controller, forward_event)
		
		"relay_result":
			if slot.role != "controller":
				return
			
			var rid: int = int(frame.get("rid", -1))
			if not _pending_relays.has(rid):
				return
			
			var relay_info: Dictionary = _pending_relays[rid]
			_pending_relays.erase(rid)
			
			var target_slot: ClientSlot = relay_info.get("viewer")
			var orig_id: Variant = relay_info.get("id")
			var is_ok: bool = bool(frame.get("ok", false))
			
			var viewer_reply: Dictionary = {
				"ok": is_ok,
			}
			if orig_id != null:
				viewer_reply["id"] = orig_id
			if frame.has("result"):
				viewer_reply["result"] = frame.get("result")
			if frame.has("error"):
				viewer_reply["error"] = frame.get("error")
			
			if target_slot != null and target_slot.is_peer_connected():
				_send_slot_frame(target_slot, viewer_reply)
		
		_:
			var reply: Dictionary = {"ok": false, "error": "unknown op: %s" % op}
			if req_id != null:
				reply["id"] = req_id
			_send_slot_frame(slot, reply)


func _handle_hello(slot: ClientSlot, frame: Dictionary) -> void:
	var client_protocol: int = int(frame.get("protocol", 0))
	if client_protocol != 1:
		_send_slot_frame(slot, {"ok": false, "error": "unsupported protocol: %d" % client_protocol})
		_close_slot(slot, "unsupported protocol")
		return
	
	var client_secret: String = str(frame.get("secret", ""))
	var match_controller: bool = constant_time_compare(client_secret, _secret)
	var match_viewer: bool = false
	if not _viewer_secret.is_empty():
		match_viewer = constant_time_compare(client_secret, _viewer_secret)
	else:
		var _dummy: bool = constant_time_compare(client_secret, "")
	
	if match_controller:
		if _controller != null and _controller.is_peer_connected():
			_send_slot_frame(slot, {"ok": false, "error": "controller role already occupied"})
			_close_slot(slot, "controller role already occupied")
			return
		_pending_clients.erase(slot)
		slot.role = "controller"
		slot.hello_received = true
		_controller = slot
		_send_hello_reply(slot)
		client_connected.emit()
	elif match_viewer:
		if _viewer != null and _viewer.is_peer_connected():
			_send_slot_frame(slot, {"ok": false, "error": "viewer role already occupied"})
			_close_slot(slot, "viewer role already occupied")
			return
		_pending_clients.erase(slot)
		slot.role = "viewer"
		slot.hello_received = true
		_viewer = slot
		_send_hello_reply(slot)
		client_connected.emit()
	else:
		_send_slot_frame(slot, {"ok": false, "error": "invalid secret"})
		_close_slot(slot, "invalid secret")
		return


func _send_hello_reply(slot: ClientSlot) -> void:
	var reply: Dictionary = {
		"ok": true,
		"protocol": 1,
		"app_version": _app_version,
		"tools": tools,
		"export": export_formats,
		"features": ["viewer", "relay", "transport"],
	}
	_send_slot_frame(slot, reply)


func _send_slot_frame(slot: ClientSlot, dict: Dictionary) -> Error:
	if slot == null or slot.peer == null or slot.peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
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
	
	var err: Error = slot.peer.put_data(header)
	if err != OK:
		return err
	err = slot.peer.put_data(payload)
	if err == OK:
		slot.peer.poll()
	return err


func _close_slot(slot: ClientSlot, _reason: String = "") -> void:
	var was_authenticated: bool = slot.hello_received
	slot.hello_received = false
	
	if slot.peer != null:
		slot.peer.disconnect_from_host()
		slot.peer.poll()
		slot.peer = null
	slot.rx_buffer.clear()
	slot.expected_frame_len = -1
	
	if slot == _controller:
		_controller = null
		if was_authenticated:
			client_disconnected.emit()
	elif slot == _viewer:
		_viewer = null
		if was_authenticated:
			client_disconnected.emit()
	else:
		_pending_clients.erase(slot)


func _check_relay_timeouts() -> void:
	if _pending_relays.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	var timed_out_rids: Array[int] = []
	for rid: int in _pending_relays:
		var info: Dictionary = _pending_relays[rid]
		var created_ms: int = int(info.get("created_ms", 0))
		if now - created_ms > relay_timeout_ms:
			timed_out_rids.push_back(rid)
	
	for rid: int in timed_out_rids:
		var info: Dictionary = _pending_relays[rid]
		_pending_relays.erase(rid)
		var target_slot: ClientSlot = info.get("viewer")
		var orig_id: Variant = info.get("id")
		if target_slot != null and target_slot.is_peer_connected():
			var reply: Dictionary = {"ok": false, "error": "timeout"}
			if orig_id != null:
				reply["id"] = orig_id
			_send_slot_frame(target_slot, reply)


func _check_song_changed_coalesce() -> void:
	if not _song_changed_pending:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_song_changed_ms >= SONG_CHANGED_INTERVAL_MS:
		_song_version += 1
		_last_song_changed_ms = now
		_song_changed_pending = false
		_broadcast({"event": "song_changed", "version": _song_version})


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
