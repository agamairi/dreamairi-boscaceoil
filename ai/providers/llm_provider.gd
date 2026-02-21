###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Base class for all LLM providers. Each provider implements the
## send_message / test_connection / get_available_models interface.
class_name LLMProvider extends RefCounted

signal request_completed(response: Dictionary)
signal request_failed(error: String)

## Provider display name.
var provider_name: String = ""
## Base URL for the API endpoint.
var base_url: String = ""
## API key (empty for local providers like Ollama).
var api_key: String = ""
## Model identifier.
var model: String = ""
## Request timeout in seconds.
var timeout: float = 120.0
## Temperature for generation.
var temperature: float = 0.7


## Send a chat completion request with tools.
## Returns: Dictionary with {content: String, tool_calls: Array} or {error: String}
func send_message(_messages: Array, _tools: Array) -> Dictionary:
	push_error("LLMProvider.send_message() must be overridden.")
	return {"error": "Not implemented"}


## Test whether the provider is reachable.
func test_connection() -> bool:
	push_error("LLMProvider.test_connection() must be overridden.")
	return false


## List models available on this provider.
func get_available_models() -> Array[String]:
	push_error("LLMProvider.get_available_models() must be overridden.")
	return []


# -- HTTP helpers --------------------------------------------------------------

func _http_request(url: String, method: int = HTTPClient.METHOD_POST, body: String = "", extra_headers: Dictionary = {}) -> Dictionary:
	var uri := url
	var scheme := "http"
	var host := ""
	var port := -1
	var path := "/"

	if uri.begins_with("https://"):
		scheme = "https"
		uri = uri.substr(8)
	elif uri.begins_with("http://"):
		uri = uri.substr(7)

	var path_start := uri.find("/")
	if path_start >= 0:
		path = uri.substr(path_start)
		uri = uri.substr(0, path_start)

	var port_start := uri.find(":")
	if port_start >= 0:
		host = uri.substr(0, port_start)
		port = uri.substr(port_start + 1).to_int()
	else:
		host = uri
		port = 443 if scheme == "https" else 80

	var use_tls := (scheme == "https")

	var client := HTTPClient.new()
	var err: int

	if use_tls:
		err = client.connect_to_host(host, port, TLSOptions.client())
	else:
		err = client.connect_to_host(host, port)

	if err != OK:
		return {"error": "Failed to connect to %s:%d (error %d)" % [host, port, err]}

	var elapsed := 0.0
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		OS.delay_msec(100)
		elapsed += 0.1
		if elapsed > timeout:
			return {"error": "Connection timeout after %.0fs" % timeout}

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"error": "Connection failed (status %d)" % client.get_status()}

	var headers := PackedStringArray()
	headers.push_back("Content-Type: application/json")
	if not api_key.is_empty():
		headers.push_back("Authorization: Bearer %s" % api_key)
	for key: String in extra_headers:
		headers.push_back("%s: %s" % [key, extra_headers[key]])

	err = client.request(method, path, headers, body)
	if err != OK:
		return {"error": "Request failed (error %d)" % err}

	elapsed = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		OS.delay_msec(100)
		elapsed += 0.1
		if elapsed > timeout:
			return {"error": "Request timeout after %.0fs" % timeout}

	if not client.has_response():
		return {"error": "No response received"}

	var status_code := client.get_response_code()
	var response_body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			response_body.append_array(chunk)
		else:
			OS.delay_msec(50)

	return {"status_code": status_code, "body": response_body.get_string_from_utf8()}


func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("LLMProvider: JSON parse error at line %d: %s" % [json.get_error_line(), json.get_error_message()])
		return null
	return json.data


func _format_tools(tools: Array) -> Array:
	return tools


func _format_messages(messages: Array) -> Array:
	return messages
