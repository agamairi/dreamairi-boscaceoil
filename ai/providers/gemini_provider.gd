###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Google Gemini LLM provider — native function calling format.
class_name GeminiProvider extends LLMProvider


func _init() -> void:
	provider_name = "Gemini"
	base_url = "https://generativelanguage.googleapis.com/v1beta"


func send_message(messages: Array, tools: Array) -> Dictionary:
	var url := "%s/models/%s:generateContent?key=%s" % [base_url, model, api_key]
	var payload := {"contents": _format_messages(messages), "generationConfig": {"temperature": temperature}} as Dictionary
	if not tools.is_empty():
		payload["tools"] = [{"functionDeclarations": _format_tools(tools)}]

	var result: Dictionary = await _http_request(url, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if result.has("error"):
		return {"error": result["error"]}
	if result["status_code"] != 200:
		return {"error": "Gemini status %d: %s" % [result["status_code"], result["body"]]}

	var data: Variant = _parse_json(result["body"])
	if data == null:
		return {"error": "Failed to parse Gemini response"}

	var candidates: Array = data.get("candidates", [])
	if candidates.is_empty():
		return {"error": "No candidates in Gemini response"}

	var parts: Array = candidates[0].get("content", {}).get("parts", [])
	var text_parts := ""
	var tool_calls: Array = []

	for part: Dictionary in parts:
		if part.has("text"):
			text_parts += part["text"]
		elif part.has("functionCall"):
			var fc: Dictionary = part["functionCall"]
			tool_calls.push_back({"id": "call_%s" % str(randi()), "name": fc.get("name", ""), "arguments": fc.get("args", {})})

	return {"content": text_parts, "tool_calls": tool_calls}


func test_connection() -> bool:
	var result: Dictionary = await _http_request("%s/models?key=%s" % [base_url, api_key], HTTPClient.METHOD_GET)
	return not result.has("error") and result.get("status_code", 0) == 200


func get_available_models() -> Array[String]:
	var result: Dictionary = await _http_request("%s/models?key=%s" % [base_url, api_key], HTTPClient.METHOD_GET)
	if result.has("error"):
		return []
	var data: Variant = _parse_json(result.get("body", ""))
	if data == null:
		return []
	var models: Array[String] = []
	for m: Dictionary in data.get("models", []):
		var n: String = m.get("name", "")
		if not n.is_empty():
			var short := n.get_file() if n.contains("/") else n
			if short.contains("gemini"):
				models.push_back(short)
	models.sort()
	return models


func _format_tools(tools: Array) -> Array:
	var out: Array = []
	for t: Dictionary in tools:
		out.push_back({"name": t.get("name", ""), "description": t.get("description", ""), "parameters": t.get("parameters", {})})
	return out


func _format_messages(messages: Array) -> Array:
	var out: Array = []
	for msg: Dictionary in messages:
		var role: String = msg.get("role", "user")
		match role:
			"system":
				out.push_back({"role": "user", "parts": [{"text": msg.get("content", "")}]})
				continue
			"assistant":
				role = "model"
			"tool":
				out.push_back({"role": "function", "parts": [{"functionResponse": {"name": msg.get("name", "tool_result"), "response": {"result": msg.get("content", "")}}}]})
				continue

		var parts: Array = []
		if msg.has("content") and msg["content"] is String and not msg["content"].is_empty():
			parts.push_back({"text": msg["content"]})
		if msg.has("tool_calls"):
			for tc: Dictionary in msg["tool_calls"]:
				parts.push_back({"functionCall": {"name": tc.get("name", ""), "args": tc.get("arguments", {})}})
		if not parts.is_empty():
			out.push_back({"role": role, "parts": parts})
	return out
