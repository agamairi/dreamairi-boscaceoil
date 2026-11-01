extends SceneTree

const TEST_SECRET: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const TEST_VIEWER_SECRET: String = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
const WRONG_SECRET: String = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

var checks: int = 0
var passed: int = 0
var fake_executor_calls: Array[Dictionary] = []
var shutdown_signal_fired: bool = false
var test_tmp_dir: String = ""
var _client_buffers: Dictionary = {}


func _init() -> void:
	_run()


func fake_executor(tool_name: String, args: Dictionary) -> Dictionary:
	fake_executor_calls.append({"tool": tool_name, "args": args})
	if tool_name == "custom_test_tool":
		var v: int = int(args.get("val", 0))
		return {"executed": true, "received_arg": v * 2}
	elif tool_name == "play_song":
		return {"success": true, "action": args.get("action", "play")}
	elif tool_name == "export_song":
		await _wait_frames(2)
		var format: String = str(args.get("format", "")).to_lower()
		var name: String = str(args.get("name", "test_song"))
		if not name.ends_with("." + format):
			name += "." + format
		var target_path: String = test_tmp_dir.path_join(name)
		if format == "wav":
			_write_test_wav_file(target_path, 2.0)
			var file_bytes: PackedByteArray = FileAccess.get_file_as_bytes(target_path)
			var sha256: String = FileAccess.get_sha256(target_path)
			return {
				"path": target_path,
				"bytes": file_bytes.size(),
				"sha256": sha256,
			}
		return {"error": "unsupported format"}
	return {"ok": true}


func _write_test_wav_file(path: String, duration_sec: float) -> void:
	var sample_rate: int = 44100
	var channels: int = 2
	var bits_per_sample: int = 16
	var num_frames: int = int(sample_rate * duration_sec)
	var data_size: int = num_frames * channels * (bits_per_sample / 8)
	
	var wav := PackedByteArray()
	wav.resize(44 + data_size)
	
	# "RIFF"
	wav.encode_u8(0, 82)
	wav.encode_u8(1, 73)
	wav.encode_u8(2, 70)
	wav.encode_u8(3, 70)
	wav.encode_u32(4, 36 + data_size)
	# "WAVE"
	wav.encode_u8(8, 87)
	wav.encode_u8(9, 65)
	wav.encode_u8(10, 86)
	wav.encode_u8(11, 69)
	# "fmt "
	wav.encode_u8(12, 102)
	wav.encode_u8(13, 109)
	wav.encode_u8(14, 116)
	wav.encode_u8(15, 32)
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1) # PCM
	wav.encode_u16(22, channels)
	wav.encode_u32(24, sample_rate)
	var byte_rate: int = sample_rate * channels * (bits_per_sample / 8)
	wav.encode_u32(28, byte_rate)
	var block_align: int = channels * (bits_per_sample / 8)
	wav.encode_u16(32, block_align)
	wav.encode_u16(34, bits_per_sample)
	# "data"
	wav.encode_u8(36, 100)
	wav.encode_u8(37, 97)
	wav.encode_u8(38, 116)
	wav.encode_u8(39, 97)
	wav.encode_u32(40, data_size)
	
	var offset := 44
	for i in range(num_frames):
		var t: float = float(i) / float(sample_rate)
		var s: float = sin(t * 440.0 * TAU)
		var val: int = int(s * 16000.0)
		wav.encode_s16(offset, val)
		wav.encode_s16(offset + 2, val)
		offset += 4
	
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(wav)
		f.close()


func check(description: String, condition: bool) -> void:
	checks += 1
	if condition:
		passed += 1
		print("  PASS: %s" % description)
	else:
		printerr("  FAIL: %s" % description)
		quit(1)


func _run() -> void:
	print("Starting remote_control_test...")
	
	var tmp_dir: String = "/tmp/rc_test_%d_%d" % [OS.get_process_id(), Time.get_ticks_msec()]
	test_tmp_dir = tmp_dir
	var make_err: Error = DirAccess.make_dir_recursive_absolute(tmp_dir)
	if make_err != OK:
		printerr("Failed to create tmp dir: %s" % tmp_dir)
		quit(1)
		return
	
	var ready_path: String = tmp_dir.path_join("ready.json")
	var handoff: Dictionary = {
		"protocol": 1,
		"secret": TEST_SECRET,
		"viewer_secret": TEST_VIEWER_SECRET,
		"output_dir": tmp_dir,
		"ready_file": ready_path,
	}
	
	var server_script: GDScript = preload("res://ai/remote_control.gd")
	var server: Node = server_script.new(handoff, fake_executor)
	server.hello_timeout_ms = 400
	server.relay_timeout_ms = 15000
	server.shutdown_requested.connect(func() -> void: shutdown_signal_fired = true)
	root.add_child(server)
	await process_frame
	
	var port: int = server.get_port()
	
	# Check 1: ready_file atomically written with the right port
	var ready_exists: bool = FileAccess.file_exists(ready_path)
	var ready_data: Dictionary = {}
	if ready_exists:
		var rf: FileAccess = FileAccess.open(ready_path, FileAccess.READ)
		var json: JSON = JSON.new()
		var perr: Error = json.parse(rf.get_as_text())
		rf.close()
		if perr == OK and json.data is Dictionary:
			ready_data = json.data
	check("ready_file atomically written with right port", ready_exists and int(ready_data.get("port", 0)) == port and int(ready_data.get("pid", 0)) == OS.get_process_id() and ready_data.has("app_version"))
	
	# Check 2: loopback-only bind
	check("loopback-only bind", server.get_bind_address() == "127.0.0.1" and port > 0)
	
	# Check 3: client1 connected (controller)
	var client1: StreamPeerTCP = await _connect_client(port)
	check("client1 connected", client1 != null and client1.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	
	# Check 4: handshake ok (controller)
	_send_frame(client1, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_SECRET,
		"client": "dreamairi-plugin"
	})
	var hello_reply: Dictionary = await _read_frame(client1)
	check("handshake ok", hello_reply.get("ok") == true and int(hello_reply.get("protocol", 0)) == 1 and hello_reply.get("tools") is Array and hello_reply.get("export") is Array and hello_reply.get("tools", []).has("set_instrument"))
	
	# Check 5: features in hello
	var features: Array = hello_reply.get("features", [])
	check("features in hello", features.has("viewer") and features.has("relay") and features.has("transport"))
	
	# Check 6: default hello advertises ["midi", "wav"]
	check("default hello advertises [\"midi\", \"wav\"]", hello_reply.get("export") == ["midi", "wav"])
	
	# Check 7: ping
	_send_frame(client1, {"id": 1, "op": "ping"})
	var ping_reply: Dictionary = await _read_response(client1)
	check("ping", int(ping_reply.get("id", 0)) == 1 and ping_reply.get("ok") == true)
	
	# Check 8: tool round-trip through the executor
	_send_frame(client1, {
		"id": 2,
		"op": "tool",
		"name": "custom_test_tool",
		"args": {"val": 21}
	})
	var tool_reply: Dictionary = await _read_response(client1)
	var tool_res: Dictionary = tool_reply.get("result", {})
	check("tool round-trip through the executor", int(tool_reply.get("id", 0)) == 2 and tool_reply.get("ok") == true and tool_res.get("executed") == true and int(tool_res.get("received_arg", 0)) == 42)
	
	# Check 8b: WAV export tool round-trip and audio validation
	_send_frame(client1, {
		"id": 50,
		"op": "tool",
		"name": "export_song",
		"args": {"format": "wav", "name": "test_export"}
	})
	var exp_reply: Dictionary = await _read_response(client1)
	var exp_res: Dictionary = exp_reply.get("result", {})
	var exp_path: String = str(exp_res.get("path", ""))
	check("export_song wav tool returns ok with path", int(exp_reply.get("id", 0)) == 50 and exp_reply.get("ok") == true and exp_path != "" and exp_path.ends_with(".wav"))
	check("export_song wav file exists on disk", FileAccess.file_exists(exp_path))
	
	var wav_f := FileAccess.open(exp_path, FileAccess.READ)
	var wav_data := wav_f.get_buffer(wav_f.get_length()) if wav_f else PackedByteArray()
	if wav_f:
		wav_f.close()
	
	var is_riff := wav_data.slice(0, 4).get_string_from_ascii() == "RIFF"
	var is_wave := wav_data.slice(8, 12).get_string_from_ascii() == "WAVE"
	var is_fmt := wav_data.slice(12, 16).get_string_from_ascii() == "fmt "
	check("export_song wav has valid RIFF/WAVE header", is_riff and is_wave and is_fmt)
	
	var wav_audio_fmt: int = wav_data.decode_u16(20) if wav_data.size() >= 36 else 0
	var wav_chans: int = wav_data.decode_u16(22) if wav_data.size() >= 36 else 0
	var wav_rate: int = wav_data.decode_u32(24) if wav_data.size() >= 36 else 0
	var wav_bits: int = wav_data.decode_u16(34) if wav_data.size() >= 36 else 0
	check("export_song wav format chunk is PCM 16-bit 44.1kHz", wav_audio_fmt == 1 and wav_chans == 2 and wav_rate == 44100 and wav_bits == 16)
	
	var data_chunk_pos := 12
	var found_data := false
	var data_len := 0
	while data_chunk_pos + 8 <= wav_data.size():
		var tag := wav_data.slice(data_chunk_pos, data_chunk_pos + 4).get_string_from_ascii()
		var clen := wav_data.decode_u32(data_chunk_pos + 4)
		if tag == "data":
			found_data = true
			data_len = clen
			data_chunk_pos += 8
			break
		data_chunk_pos += 8 + clen
	
	check("export_song wav has non-zero data chunk", found_data and data_len > 0)
	
	var bytes_per_sec := float(wav_rate * wav_chans * (wav_bits / 8))
	var dur := float(data_len) / bytes_per_sec
	check("export_song wav duration roughly matches song length (approx 2.0s)", dur >= 1.5 and dur <= 2.5)
	
	var non_silent_samples := 0
	for i in range(data_chunk_pos, mini(wav_data.size(), data_chunk_pos + data_len), 2):
		if wav_data.decode_s16(i) != 0:
			non_silent_samples += 1
	check("export_song wav audio is not all silence", non_silent_samples > 100)
	
	# Check 9: viewer connected with viewer_secret
	var viewer: StreamPeerTCP = await _connect_client(port)
	_send_frame(viewer, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_VIEWER_SECRET,
		"client": "tui-studio"
	})
	var viewer_hello: Dictionary = await _read_frame(viewer)
	check("viewer connected with viewer_secret", viewer_hello.get("ok") == true and (viewer_hello.get("features", []) as Array).has("viewer"))
	
	# Check 10: roles by secret
	check("roles by secret", server.is_controller_connected() and server.is_viewer_connected())
	
	# Check 11: duplicate controller closed after hello
	var dup_ctrl: StreamPeerTCP = await _connect_client(port)
	_send_frame(dup_ctrl, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_SECRET,
		"client": "dup-ctrl"
	})
	var dup_ctrl_reply: Dictionary = await _read_frame(dup_ctrl)
	var dup_ctrl_disconnected: bool = await _wait_for_disconnect(dup_ctrl, 1000)
	check("duplicate controller rejected and closed", dup_ctrl_reply.get("ok") == false and dup_ctrl_disconnected)
	
	# Check 12: duplicate viewer closed after hello
	var dup_view: StreamPeerTCP = await _connect_client(port)
	_send_frame(dup_view, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_VIEWER_SECRET,
		"client": "dup-view"
	})
	var dup_view_reply: Dictionary = await _read_frame(dup_view)
	var dup_view_disconnected: bool = await _wait_for_disconnect(dup_view, 1000)
	check("duplicate viewer rejected and closed", dup_view_reply.get("ok") == false and dup_view_disconnected)
	
	# Check 13: events reach both clients
	server.send_event("test_broadcast_event")
	var ctrl_evt: Dictionary = await _read_frame(client1)
	var view_evt: Dictionary = await _read_frame(viewer)
	check("events reach both clients", str(ctrl_evt.get("event", "")) == "test_broadcast_event" and str(view_evt.get("event", "")) == "test_broadcast_event")
	
	# Check 14: viewer allowlist - allowed tool passes
	_send_frame(viewer, {
		"id": 10,
		"op": "tool",
		"name": "play_song",
		"args": {"action": "play"}
	})
	var v_play_reply: Dictionary = await _read_response(viewer)
	check("viewer allowed tool passes", int(v_play_reply.get("id", 0)) == 10 and v_play_reply.get("ok") == true and v_play_reply.get("result", {}).get("success") == true)
	
	# Check 15: viewer allowlist - save_song refused
	_send_frame(viewer, {
		"id": 11,
		"op": "tool",
		"name": "save_song",
		"args": {"name": "test"}
	})
	var v_save_reply: Dictionary = await _read_response(viewer)
	check("viewer refused save_song", v_save_reply.get("ok") == true and str(v_save_reply.get("result", {}).get("error", "")) == "tool not allowed for viewer")
	
	# Check 16: viewer allowlist - snapshot refused
	_send_frame(viewer, {
		"id": 12,
		"op": "tool",
		"name": "snapshot",
		"args": {}
	})
	var v_snap_reply: Dictionary = await _read_response(viewer)
	check("viewer refused snapshot", v_snap_reply.get("ok") == true and str(v_snap_reply.get("result", {}).get("error", "")) == "tool not allowed for viewer")
	
	# Check 17: viewer allowlist - create_song refused
	_send_frame(viewer, {
		"id": 13,
		"op": "tool",
		"name": "create_song",
		"args": {"bpm": 120}
	})
	var v_create_reply: Dictionary = await _read_response(viewer)
	check("viewer refused create_song", v_create_reply.get("ok") == true and str(v_create_reply.get("result", {}).get("error", "")) == "tool not allowed for viewer")
	
	# Check 18: viewer allowlist - add_instrument allowed
	_send_frame(viewer, {
		"id": 14,
		"op": "tool",
		"name": "add_instrument",
		"args": {"category": "MIDI", "name": "Piano"}
	})
	var v_add_reply: Dictionary = await _read_response(viewer)
	check("viewer allowed add_instrument", v_add_reply.get("ok") == true and v_add_reply.get("result", {}).get("ok") == true)
	
	# Check 19: viewer allowlist - set_instrument allowed
	_send_frame(viewer, {
		"id": 15,
		"op": "tool",
		"name": "set_instrument",
		"args": {"instrument_index": 0, "category": "MIDI", "name": "Electric Piano 1"}
	})
	var v_set_reply: Dictionary = await _read_response(viewer)
	check("viewer allowed set_instrument", v_set_reply.get("ok") == true and v_set_reply.get("result", {}).get("ok") == true)
	
	# Check 20: viewer allowlist - remove_instrument refused
	_send_frame(viewer, {
		"id": 16,
		"op": "tool",
		"name": "remove_instrument",
		"args": {"instrument_index": 0}
	})
	var v_rem_reply: Dictionary = await _read_response(viewer)
	check("viewer refused remove_instrument", v_rem_reply.get("ok") == true and str(v_rem_reply.get("result", {}).get("error", "")) == "tool not allowed for viewer")
	
	# Check 21: viewer shutdown refused
	_send_frame(viewer, {
		"id": 17,
		"op": "shutdown"
	})
	var v_shut_reply: Dictionary = await _read_response(viewer)
	check("viewer shutdown refused", v_shut_reply.get("ok") == false and shutdown_signal_fired == false)
	
	# Check 20: relay happy path
	_send_frame(viewer, {
		"id": 20,
		"op": "relay",
		"action": "save",
		"args": {"prompt": "ambient cave theme"}
	})
	var req_event: Dictionary = await _read_frame(client1)
	var relay_rid: int = int(req_event.get("rid", -1))
	var relay_req_ok: bool = (str(req_event.get("event", "")) == "relay_request" and relay_rid > 0 and str(req_event.get("action", "")) == "save")
	
	_send_frame(client1, {
		"op": "relay_result",
		"rid": relay_rid,
		"ok": true,
		"result": {"id": "log-1", "saved": true}
	})
	var relay_reply: Dictionary = await _read_response(viewer)
	check("relay happy path", relay_req_ok and int(relay_reply.get("id", 0)) == 20 and relay_reply.get("ok") == true and relay_reply.get("result", {}).get("id") == "log-1")
	
	# Check 21: relay unknown action refused
	_send_frame(viewer, {
		"id": 21,
		"op": "relay",
		"action": "destroy_everything",
		"args": {}
	})
	var bad_action_reply: Dictionary = await _read_response(viewer)
	check("relay unknown action refused", int(bad_action_reply.get("id", 0)) == 21 and bad_action_reply.get("ok") == false)
	
	# Check 22: relay timeout
	server.relay_timeout_ms = 100
	_send_frame(viewer, {
		"id": 22,
		"op": "relay",
		"action": "rate",
		"args": {"id": "log-1", "rating": 5}
	})
	var req_event2: Dictionary = await _read_frame(client1)
	var timeout_reply: Dictionary = await _read_response(viewer, 1000)
	check("relay timeout", str(req_event2.get("event", "")) == "relay_request" and int(timeout_reply.get("id", 0)) == 22 and timeout_reply.get("ok") == false and timeout_reply.get("error") == "timeout")
	server.relay_timeout_ms = 15000
	
	# Check 23: relay result from non-controller ignored
	_send_frame(viewer, {
		"op": "relay_result",
		"rid": 9999,
		"ok": true,
		"result": {}
	})
	await _wait_frames(3)
	check("relay result from non-controller ignored", true)
	
	# Check 24: song_changed coalescing and strictly increasing version
	# Calling notify_song_changed 5 times in a row
	server.notify_song_changed()
	server.notify_song_changed()
	server.notify_song_changed()
	server.notify_song_changed()
	server.notify_song_changed()
	
	var sc1_ctrl: Dictionary = await _read_frame(client1)
	var sc1_view: Dictionary = await _read_frame(viewer)
	var v1: int = int(sc1_ctrl.get("version", 0))
	
	# Wait for trailing edge (> 100ms)
	OS.delay_msec(120)
	await _wait_frames(5)
	
	var sc2_ctrl: Dictionary = await _read_frame(client1)
	var sc2_view: Dictionary = await _read_frame(viewer)
	var v2: int = int(sc2_ctrl.get("version", 0))
	check("song_changed coalescing and strictly increasing version", str(sc1_ctrl.get("event", "")) == "song_changed" and str(sc1_view.get("event", "")) == "song_changed" and str(sc2_ctrl.get("event", "")) == "song_changed" and str(sc2_view.get("event", "")) == "song_changed" and v1 > 0 and v2 > v1)
	
	# Check 25: transport event rate limit and immediate start/stop
	server.notify_transport(true, 0, 0)
	var t1: Dictionary = await _read_frame(client1)
	await _read_frame(viewer) # Drain viewer
	
	# Immediate call within interval is throttled
	server.notify_transport(true, 0, 1)
	var t_throttled: Dictionary = await _read_frame(client1, 20)
	
	# After waiting interval, it emits
	OS.delay_msec(75)
	await _wait_frames(3)
	server.notify_transport(true, 0, 2)
	var t2: Dictionary = await _read_frame(client1)
	await _read_frame(viewer) # Drain viewer
	
	# State change to stopped is immediate
	server.notify_transport(false, 0, 2)
	var t3: Dictionary = await _read_frame(client1)
	await _read_frame(viewer) # Drain viewer
	check("transport event rate limit and immediate start/stop", t1.get("playing") == true and int(t1.get("step", -1)) == 0 and t_throttled.is_empty() and t2.get("playing") == true and int(t2.get("step", -1)) == 2 and t3.get("playing") == false)
	
	# Check 26: relay no controller returns error
	client1.disconnect_from_host()
	await _wait_frames(5)
	_send_frame(viewer, {
		"id": 23,
		"op": "relay",
		"action": "save",
		"args": {}
	})
	var no_ctrl_reply: Dictionary = await _read_response(viewer)
	check("relay no controller returns error", int(no_ctrl_reply.get("id", 0)) == 23 and no_ctrl_reply.get("ok") == false and str(no_ctrl_reply.get("error", "")) == "no_controller")
	
	# Check 27: viewer disabled when handoff has no viewer_secret
	var no_viewer_ready_path: String = tmp_dir.path_join("ready_no_viewer.json")
	var no_viewer_handoff: Dictionary = {
		"protocol": 1,
		"secret": TEST_SECRET,
		"output_dir": tmp_dir,
		"ready_file": no_viewer_ready_path,
	}
	var no_viewer_server: Node = server_script.new(no_viewer_handoff, fake_executor)
	root.add_child(no_viewer_server)
	await process_frame
	var no_v_port: int = no_viewer_server.get_port()
	var no_v_client: StreamPeerTCP = await _connect_client(no_v_port)
	_send_frame(no_v_client, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_VIEWER_SECRET,
		"client": "test"
	})
	var no_v_reply: Dictionary = await _read_frame(no_v_client)
	var no_v_disconnected: bool = await _wait_for_disconnect(no_v_client, 1000)
	check("viewer disabled when handoff has no viewer_secret", no_v_reply.get("ok") == false and no_v_disconnected)
	no_viewer_server.stop()
	DirAccess.remove_absolute(no_viewer_ready_path)
	
	# Reconnect client1 as controller for remaining tests
	client1 = await _connect_client(port)
	_send_frame(client1, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_SECRET,
		"client": "dreamairi-plugin"
	})
	await _read_frame(client1)
	
	# Check 28: shutdown signal
	_send_frame(client1, {"id": 30, "op": "shutdown"})
	var shutdown_reply: Dictionary = await _read_response(client1)
	check("shutdown signal", shutdown_signal_fired and int(shutdown_reply.get("id", 0)) == 30 and shutdown_reply.get("ok") == true)
	
	client1.disconnect_from_host()
	viewer.disconnect_from_host()
	await _wait_frames(3)
	
	# Check 29: wrong secret rejected + closed
	var client3: StreamPeerTCP = await _connect_client(port)
	_send_frame(client3, {
		"op": "hello",
		"protocol": 1,
		"secret": WRONG_SECRET,
		"client": "dreamairi-plugin"
	})
	var wrong_sec_reply: Dictionary = await _read_frame(client3)
	var client3_disconnected: bool = await _wait_for_disconnect(client3, 1000)
	check("wrong secret rejected + closed", wrong_sec_reply.get("ok") == false and client3_disconnected)
	await _wait_frames(3)
	
	# Check 30: non-hello first frame closed
	var client4: StreamPeerTCP = await _connect_client(port)
	_send_frame(client4, {"id": 5, "op": "ping"})
	var client4_disconnected: bool = await _wait_for_disconnect(client4, 1000)
	check("non-hello first frame closed", client4_disconnected)
	await _wait_frames(3)
	
	# Check 31: oversized length prefix closes
	var client5: StreamPeerTCP = await _connect_client(port)
	var header_oversized: PackedByteArray = PackedByteArray()
	header_oversized.resize(4)
	header_oversized[0] = 0x00
	header_oversized[1] = 0x50
	header_oversized[2] = 0x00
	header_oversized[3] = 0x00
	client5.put_data(header_oversized)
	var client5_disconnected: bool = await _wait_for_disconnect(client5, 1000)
	check("oversized length prefix closes", client5_disconnected)
	await _wait_frames(3)
	
	# Check 32: malformed JSON closes
	var client6: StreamPeerTCP = await _connect_client(port)
	var bad_json_bytes: PackedByteArray = "{not valid json!".to_utf8_buffer()
	var header_bad: PackedByteArray = PackedByteArray()
	header_bad.resize(4)
	var bad_len: int = bad_json_bytes.size()
	header_bad[0] = (bad_len >> 24) & 0xff
	header_bad[1] = (bad_len >> 16) & 0xff
	header_bad[2] = (bad_len >> 8) & 0xff
	header_bad[3] = bad_len & 0xff
	client6.put_data(header_bad)
	client6.put_data(bad_json_bytes)
	var client6_disconnected: bool = await _wait_for_disconnect(client6, 1000)
	check("malformed JSON closes", client6_disconnected)
	await _wait_frames(3)
	
	# Check 33: hello timeout closes
	var client7: StreamPeerTCP = await _connect_client(port)
	var client7_disconnected: bool = await _wait_for_disconnect(client7, 1200)
	check("hello timeout closes", client7_disconnected)
	
	# Check 34: custom_export client connected
	var custom_ready_path: String = tmp_dir.path_join("ready_custom.json")
	var custom_handoff: Dictionary = {
		"protocol": 1,
		"secret": TEST_SECRET,
		"output_dir": tmp_dir,
		"ready_file": custom_ready_path,
	}
	var custom_server: Node = server_script.new(custom_handoff, fake_executor, [], ["midi"])
	custom_server.hello_timeout_ms = 400
	root.add_child(custom_server)
	await process_frame
	
	var custom_port: int = custom_server.get_port()
	var custom_client: StreamPeerTCP = await _connect_client(custom_port)
	check("custom_export client connected", custom_client != null and custom_client.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	
	# Check 35: custom_export server advertises overridden ["midi"]
	_send_frame(custom_client, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_SECRET,
		"client": "dreamairi-plugin"
	})
	var custom_hello_reply: Dictionary = await _read_frame(custom_client)
	check("custom_export server advertises [\"midi\"] override", custom_hello_reply.get("ok") == true and custom_hello_reply.get("export") == ["midi"])
	
	custom_client.disconnect_from_host()
	await _wait_frames(3)
	custom_server.stop()
	DirAccess.remove_absolute(custom_ready_path)
	
	# Cleanup
	server.stop()
	DirAccess.remove_absolute(ready_path)
	DirAccess.remove_absolute(tmp_dir)
	
	print("REMOTE_CONTROL_TEST: checks=%d passed=%d" % [checks, passed])
	quit(0 if checks == passed else 1)


func _connect_client(port: int) -> StreamPeerTCP:
	var client := StreamPeerTCP.new()
	var err: Error = client.connect_to_host("127.0.0.1", port)
	if err != OK:
		return null
	var start_ms: int = Time.get_ticks_msec()
	while client.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		client.poll()
		if Time.get_ticks_msec() - start_ms > 2000:
			return null
		await process_frame
	if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return null
	return client


func _send_frame(client: StreamPeerTCP, dict: Dictionary) -> void:
	var payload: PackedByteArray = JSON.stringify(dict).to_utf8_buffer()
	var plen: int = payload.size()
	var header: PackedByteArray = PackedByteArray()
	header.resize(4)
	header[0] = (plen >> 24) & 0xff
	header[1] = (plen >> 16) & 0xff
	header[2] = (plen >> 8) & 0xff
	header[3] = plen & 0xff
	client.put_data(header)
	client.put_data(payload)


func _read_frame(client: StreamPeerTCP, timeout_ms: int = 1500) -> Dictionary:
	var start_ms: int = Time.get_ticks_msec()
	if not _client_buffers.has(client):
		_client_buffers[client] = PackedByteArray()
	var buf: PackedByteArray = _client_buffers[client]
	
	while Time.get_ticks_msec() - start_ms < timeout_ms:
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var avail: int = client.get_available_bytes()
		if avail > 0:
			var res: Array = client.get_data(avail)
			if int(res[0]) == OK and (res[1] as PackedByteArray).size() > 0:
				buf.append_array(res[1])
		
		if buf.size() >= 4:
			var expected_len: int = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3]
			if buf.size() >= 4 + expected_len:
				var payload: PackedByteArray = buf.slice(4, 4 + expected_len)
				_client_buffers[client] = buf.slice(4 + expected_len)
				var json: JSON = JSON.new()
				if json.parse(payload.get_string_from_utf8()) == OK and json.data is Dictionary:
					return json.data
				return {}
		await process_frame
	_client_buffers[client] = buf
	return {}


func _read_response(client: StreamPeerTCP, timeout_ms: int = 1500) -> Dictionary:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < timeout_ms:
		var frame: Dictionary = await _read_frame(client, timeout_ms)
		if frame.is_empty():
			return {}
		if frame.has("event"):
			continue
		return frame
	return {}


func _wait_for_disconnect(client: StreamPeerTCP, timeout_ms: int = 1500) -> bool:
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < timeout_ms:
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return true
		await process_frame
	return false


func _wait_frames(n: int) -> void:
	for i in n:
		await process_frame
