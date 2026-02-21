###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Ollama LLM provider — local instance.
class_name OllamaProvider extends LLMProvider


func _init() -> void:
	provider_name = "Ollama"
	base_url = "http://localhost:11434"


func send_message(messages: Array, tools: Array) -> Dictionary:
	var url := "%s/api/chat" % base_url
	var payload := {
		"model": model,
		"messages": _format_messages(messages),
		"stream": false,
		"options": {"temperature": temperature},
	}
	if not tools.is_empty():
		payload["tools"] = _format_tools(tools)

	var result: Dictionary = await _http_request(url, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if result.has("error"):
		return {"error": result["error"]}
	if result["status_code"] != 200:
		return {"error": "Ollama status %d: %s" % [result["status_code"], result["body"]]}

	var data: Variant = _parse_json(result["body"])
	if data == null:
		return {"error": "Failed to parse Ollama response"}

	var msg: Dictionary = data.get("message", {})
	var response := {"content": msg.get("content", ""), "tool_calls": [] as Array}

	if msg.has("tool_calls"):
		for tc: Dictionary in msg["tool_calls"]:
			var fd: Dictionary = tc.get("function", {})
			response["tool_calls"].push_back({
				"id": "call_%s" % str(randi()),
				"name": fd.get("name", ""),
				"arguments": fd.get("arguments", {}),
			})
	return response


func test_connection() -> bool:
	var result: Dictionary = await _http_request("%s/api/tags" % base_url, HTTPClient.METHOD_GET)
	return not result.has("error") and result.get("status_code", 0) == 200


func get_available_models() -> Array[String]:
	var result: Dictionary = await _http_request("%s/api/tags" % base_url, HTTPClient.METHOD_GET)
	if result.has("error"):
		return []
	var data: Variant = _parse_json(result.get("body", ""))
	if data == null:
		return []
	var models: Array[String] = []
	for m: Dictionary in data.get("models", []):
		var n: String = m.get("name", "")
		if not n.is_empty():
			models.push_back(n)
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
		if msg.has("content"):
			entry["content"] = msg["content"]
		if msg.has("tool_calls"):
			entry["tool_calls"] = []
			for tc: Dictionary in msg["tool_calls"]:
				entry["tool_calls"].push_back({"function": {"name": tc.get("name", ""), "arguments": tc.get("arguments", {})}})
		if msg.get("role", "") == "tool":
			entry["content"] = msg.get("content", "")
		out.push_back(entry)
	return out
