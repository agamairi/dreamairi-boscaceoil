###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## OpenAI LLM provider.
class_name OpenAIProvider extends LLMProvider


func _init() -> void:
	provider_name = "OpenAI"
	base_url = "https://api.openai.com/v1"


func send_message(messages: Array, tools: Array) -> Dictionary:
	var url := "%s/chat/completions" % base_url
	var payload := {"model": model, "messages": _format_messages(messages), "temperature": temperature} as Dictionary
	if not tools.is_empty():
		payload["tools"] = _format_tools(tools)

	var result: Dictionary = await _http_request(url, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if result.has("error"):
		return {"error": result["error"]}
	if result["status_code"] != 200:
		return {"error": "OpenAI status %d: %s" % [result["status_code"], result["body"]]}

	var data: Variant = _parse_json(result["body"])
	if data == null:
		return {"error": "Failed to parse OpenAI response"}

	var choices: Array = data.get("choices", [])
	if choices.is_empty():
		return {"error": "No choices in OpenAI response"}

	var msg: Dictionary = choices[0].get("message", {})
	var response := {"content": "" if msg.get("content") == null else str(msg.get("content", "")), "tool_calls": [] as Array}

	if msg.has("tool_calls"):
		for tc: Dictionary in msg["tool_calls"]:
			var fd: Dictionary = tc.get("function", {})
			var args: Variant = _parse_json(fd.get("arguments", "{}"))
			response["tool_calls"].push_back({
				"id": tc.get("id", "call_%s" % str(randi())),
				"name": fd.get("name", ""),
				"arguments": args if args != null else {},
			})
	return response


func test_connection() -> bool:
	var result: Dictionary = await _http_request("%s/models" % base_url, HTTPClient.METHOD_GET)
	return not result.has("error") and result.get("status_code", 0) == 200


func get_available_models() -> Array[String]:
	var result: Dictionary = await _http_request("%s/models" % base_url, HTTPClient.METHOD_GET)
	if result.has("error"):
		return []
	var data: Variant = _parse_json(result.get("body", ""))
	if data == null:
		return []
	var models: Array[String] = []
	for m: Dictionary in data.get("data", []):
		var id: String = m.get("id", "")
		if not id.is_empty() and id.contains("gpt"):
			models.push_back(id)
	models.sort()
	return models


func _format_tools(tools: Array) -> Array:
	var out: Array = []
	for t: Dictionary in tools:
		out.push_back({"type": "function", "function": {"name": t.get("name", ""), "description": t.get("description", ""), "parameters": t.get("parameters", {})}})
	return out


func _format_messages(messages: Array) -> Array:
	var out: Array = []
	for msg: Dictionary in messages:
		var entry := {"role": msg.get("role", "user")} as Dictionary
		if msg.has("content") and msg["content"] != null:
			entry["content"] = msg["content"]
		elif not msg.has("tool_calls"):
			entry["content"] = ""
		if msg.has("tool_calls"):
			entry["tool_calls"] = []
			for tc: Dictionary in msg["tool_calls"]:
				entry["tool_calls"].push_back({"id": tc.get("id", "call_%s" % str(randi())), "type": "function", "function": {"name": tc.get("name", ""), "arguments": JSON.stringify(tc.get("arguments", {}))}})
		if msg.get("role", "") == "tool":
			entry["tool_call_id"] = msg.get("tool_call_id", "")
			entry["content"] = msg.get("content", "")
		out.push_back(entry)
	return out
