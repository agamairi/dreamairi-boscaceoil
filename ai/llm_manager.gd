###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Manages LLM providers — auto-detection, factory, connection caching.
class_name LLMManager extends RefCounted

signal provider_changed(provider: LLMProvider)
signal connection_status_changed(connected: bool, message: String)

var active_provider: LLMProvider = null
var _connection_cache: Dictionary = {}


func auto_detect_provider() -> LLMProvider:
	# 1. Ollama (local, no key needed).
	var ollama := OllamaProvider.new()
	ollama.base_url = _get_setting("ai_base_url", "http://localhost:11434")
	if await ollama.test_connection():
		var models := await ollama.get_available_models()
		if not models.is_empty():
			ollama.model = _get_setting("ai_model", models[0])
			active_provider = ollama
			connection_status_changed.emit(true, "Connected to Ollama (%s)" % ollama.model)
			provider_changed.emit(active_provider)
			return active_provider

	# 2. API key providers.
	for entry: Array in [
		["ai_api_key_openai", "gpt-4o-mini", "openai"],
		["ai_api_key_openrouter", "anthropic/claude-3.5-sonnet", "openrouter"],
		["ai_api_key_gemini", "gemini-2.0-flash", "gemini"],
	]:
		var key := _get_setting(entry[0], "")
		if key.is_empty():
			continue
		var p := create_provider(entry[2])
		if p == null:
			continue
		p.api_key = key
		p.model = _get_setting("ai_model", entry[1])
		if await p.test_connection():
			active_provider = p
			connection_status_changed.emit(true, "Connected to %s (%s)" % [p.provider_name, p.model])
			provider_changed.emit(active_provider)
			return active_provider

	connection_status_changed.emit(false, "No LLM provider available")
	return null


func create_provider(type: String) -> LLMProvider:
	var p: LLMProvider = null
	match type.to_lower():
		"ollama":
			p = OllamaProvider.new()
			p.base_url = _get_setting("ai_base_url", "http://localhost:11434")
		"openai":
			p = OpenAIProvider.new()
			p.api_key = _get_setting("ai_api_key_openai", "")
		"openrouter":
			p = OpenRouterProvider.new()
			p.api_key = _get_setting("ai_api_key_openrouter", "")
		"gemini":
			p = GeminiProvider.new()
			p.api_key = _get_setting("ai_api_key_gemini", "")
		_:
			push_error("LLMManager: Unknown provider type '%s'" % type)
			return null
	p.model = _get_setting("ai_model", "")
	p.temperature = _get_setting_float("ai_temperature", 0.7)
	return p


func activate_provider(type: String) -> bool:
	var p := create_provider(type)
	if p == null:
		return false
	if await p.test_connection():
		if p.model.is_empty():
			var models := await p.get_available_models()
			if not models.is_empty():
				p.model = models[0]
		active_provider = p
		_connection_cache[type] = true
		connection_status_changed.emit(true, "Connected to %s (%s)" % [p.provider_name, p.model])
		provider_changed.emit(active_provider)
		return true
	_connection_cache[type] = false
	connection_status_changed.emit(false, "Failed to connect to %s" % type)
	return false


func _get_setting(key: String, default_value: String) -> String:
	if not Controller or not Controller.settings_manager:
		return default_value
	return Controller.settings_manager.get_ai_setting(key, default_value)


func _get_setting_float(key: String, default_value: float) -> float:
	var val := _get_setting(key, str(default_value))
	return val.to_float() if val.is_valid_float() else default_value
