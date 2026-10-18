extends SceneTree

const TEST_SECRET: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const WRONG_SECRET: String = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

var checks: int = 0
var passed: int = 0
var fake_executor_calls: Array[Dictionary] = []
var shutdown_signal_fired: bool = false


func _init() -> void:
	_run()


func fake_executor(tool_name: String, args: Dictionary) -> Dictionary:
	fake_executor_calls.append({"tool": tool_name, "args": args})
	if tool_name == "custom_test_tool":
		var v: int = int(args.get("val", 0))
		return {"executed": true, "received_arg": v * 2}
	return {"ok": true}


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
	var make_err: Error = DirAccess.make_dir_recursive_absolute(tmp_dir)
	if make_err != OK:
		printerr("Failed to create tmp dir: %s" % tmp_dir)
		quit(1)
		return
	
	var ready_path: String = tmp_dir.path_join("ready.json")
	var handoff: Dictionary = {
		"protocol": 1,
		"secret": TEST_SECRET,
		"output_dir": tmp_dir,
		"ready_file": ready_path,
	}
	
	var server_script: GDScript = preload("res://ai/remote_control.gd")
	var server: Node = server_script.new(handoff, fake_executor)
	server.hello_timeout_ms = 400
	server.shutdown_requested.connect(func() -> void: shutdown_signal_fired = true)
	root.add_child(server)
	await process_frame
	
	var port: int = server.get_port()
	
	# Check 1: ready_file atomically written with the right port
	var ready_exists: bool = FileAccess.file_exists(ready_path)
	var ready_data: Dictionary = {}
	if ready_exists:
		var rf: FileAccess = FileAccess.open(ready_path, FileAccess.READ)
		var json := JSON.new()
		var perr: Error = json.parse(rf.get_as_text())
		rf.close()
		if perr == OK and json.data is Dictionary:
			ready_data = json.data
	check("ready_file atomically written with right port", ready_exists and int(ready_data.get("port", 0)) == port and int(ready_data.get("pid", 0)) == OS.get_process_id() and ready_data.has("app_version"))
	
	# Check 2: loopback-only bind
	check("loopback-only bind", server.get_bind_address() == "127.0.0.1" and port > 0)
	
	# Check 3: handshake ok
	var client1: StreamPeerTCP = await _connect_client(port)
	check("client1 connected", client1 != null and client1.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	
	_send_frame(client1, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_SECRET,
		"client": "dreamairi-plugin"
	})
	var hello_reply: Dictionary = await _read_frame(client1)
	check("handshake ok", hello_reply.get("ok") == true and int(hello_reply.get("protocol", 0)) == 1 and hello_reply.get("tools") is Array and hello_reply.get("export") is Array)
	check("default hello advertises exactly [\"midi\"]", hello_reply.get("export") == ["midi"])
	
	# Check 4: ping
	_send_frame(client1, {"id": 1, "op": "ping"})
	var ping_reply: Dictionary = await _read_frame(client1)
	check("ping", int(ping_reply.get("id", 0)) == 1 and ping_reply.get("ok") == true)
	
	# Check 5: tool round-trip through the executor
	_send_frame(client1, {
		"id": 2,
		"op": "tool",
		"name": "custom_test_tool",
		"args": {"val": 21}
	})
	var tool_reply: Dictionary = await _read_frame(client1)
	var tool_res: Dictionary = tool_reply.get("result", {})
	check("tool round-trip through the executor", int(tool_reply.get("id", 0)) == 2 and tool_reply.get("ok") == true and tool_res.get("executed") == true and int(tool_res.get("received_arg", 0)) == 42)
	
	# Check 6: send_event
	server.send_event("test_event_name")
	var event_frame: Dictionary = await _read_frame(client1)
	check("send_event", str(event_frame.get("event", "")) == "test_event_name")
	
	# Check 7: second client rejected while first connected
	var client2: StreamPeerTCP = await _connect_client(port)
	var client2_disconnected: bool = await _wait_for_disconnect(client2, 1000)
	# Verify client 1 is still connected and operational
	_send_frame(client1, {"id": 3, "op": "ping"})
	var ping2_reply: Dictionary = await _read_frame(client1)
	check("second client rejected while first connected", client2_disconnected and ping2_reply.get("ok") == true)
	
	# Check 8: shutdown signal
	_send_frame(client1, {"id": 4, "op": "shutdown"})
	var shutdown_reply: Dictionary = await _read_frame(client1)
	check("shutdown signal", shutdown_signal_fired and int(shutdown_reply.get("id", 0)) == 4 and shutdown_reply.get("ok") == true)
	
	client1.disconnect_from_host()
	await _wait_frames(3)
	
	# Check 9: wrong secret rejected + closed
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
	
	# Check 10: non-hello first frame closed
	var client4: StreamPeerTCP = await _connect_client(port)
	_send_frame(client4, {"id": 5, "op": "ping"})
	var client4_disconnected: bool = await _wait_for_disconnect(client4, 1000)
	check("non-hello first frame closed", client4_disconnected)
	await _wait_frames(3)
	
	# Check 11: oversized length prefix closes
	var client5: StreamPeerTCP = await _connect_client(port)
	# Send length prefix of 5 MiB = 5242880
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
	
	# Check 12: malformed JSON closes
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
	
	# Check 13: hello timeout closes
	var client7: StreamPeerTCP = await _connect_client(port)
	# Wait for server's hello_timeout_ms (400ms) to trigger close
	var client7_disconnected: bool = await _wait_for_disconnect(client7, 1200)
	check("hello timeout closes", client7_disconnected)
	
	# Check 14: custom_export server advertises both ["midi", "wav"]
	var custom_ready_path: String = tmp_dir.path_join("ready_custom.json")
	var custom_handoff: Dictionary = {
		"protocol": 1,
		"secret": TEST_SECRET,
		"output_dir": tmp_dir,
		"ready_file": custom_ready_path,
	}
	var custom_server: Node = server_script.new(custom_handoff, fake_executor, [], ["midi", "wav"])
	custom_server.hello_timeout_ms = 400
	root.add_child(custom_server)
	await process_frame
	
	var custom_port: int = custom_server.get_port()
	var custom_client: StreamPeerTCP = await _connect_client(custom_port)
	check("custom_export client connected", custom_client != null and custom_client.get_status() == StreamPeerTCP.STATUS_CONNECTED)
	
	_send_frame(custom_client, {
		"op": "hello",
		"protocol": 1,
		"secret": TEST_SECRET,
		"client": "dreamairi-plugin"
	})
	var custom_hello_reply: Dictionary = await _read_frame(custom_client)
	check("custom_export server advertises [\"midi\", \"wav\"]", custom_hello_reply.get("ok") == true and custom_hello_reply.get("export") == ["midi", "wav"])
	
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
	var buf: PackedByteArray = PackedByteArray()
	var expected_len: int = -1
	
	while Time.get_ticks_msec() - start_ms < timeout_ms:
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var avail: int = client.get_available_bytes()
		if avail > 0:
			var res: Array = client.get_data(avail)
			if int(res[0]) == OK and (res[1] as PackedByteArray).size() > 0:
				buf.append_array(res[1])
		
		if expected_len < 0 and buf.size() >= 4:
			expected_len = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3]
		
		if expected_len >= 0 and buf.size() >= 4 + expected_len:
			var payload: PackedByteArray = buf.slice(4, 4 + expected_len)
			var json := JSON.new()
			if json.parse(payload.get_string_from_utf8()) == OK and json.data is Dictionary:
				return json.data
			return {}
		await process_frame
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
