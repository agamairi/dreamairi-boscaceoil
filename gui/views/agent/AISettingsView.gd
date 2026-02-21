###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## AI Settings — provider, API keys, model, temperature.
extends VBoxContainer

@onready var _provider_option: OptionButton = $ProviderRow/ProviderOption
@onready var _api_key_input: LineEdit = $ApiKeyRow/ApiKeyInput
@onready var _base_url_input: LineEdit = $BaseUrlRow/BaseUrlInput
@onready var _model_option: OptionButton = $ModelRow/ModelOption
@onready var _test_button: Button = $ButtonRow/TestButton
@onready var _auto_detect_button: Button = $ButtonRow/AutoDetectButton
@onready var _status_label: Label = $StatusRow/StatusLabel
@onready var _max_turns_spin: SpinBox = $TuningRow/MaxTurnsSpin
@onready var _temperature_slider: HSlider = $TempRow/TemperatureSlider
@onready var _temperature_label: Label = $TempRow/TemperatureValue


func _ready() -> void:
	_provider_option.clear()
	for item: String in ["Auto Detect", "Ollama", "OpenAI", "OpenRouter", "Gemini"]:
		_provider_option.add_item(item)
	_provider_option.item_selected.connect(_on_provider_selected)
	_api_key_input.secret = true
	_api_key_input.placeholder_text = "API Key (not needed for Ollama)"
	_api_key_input.text_changed.connect(_on_api_key_changed)
	_base_url_input.placeholder_text = "http://localhost:11434"
	_base_url_input.text_changed.connect(func(t: String) -> void: Controller.settings_manager.set_ai_setting("ai_base_url", t))
	_model_option.item_selected.connect(_on_model_selected)
	_test_button.pressed.connect(_on_test)
	_auto_detect_button.pressed.connect(_on_auto_detect)
	_max_turns_spin.min_value = 5; _max_turns_spin.max_value = 100; _max_turns_spin.step = 1; _max_turns_spin.value = 20
	_max_turns_spin.value_changed.connect(func(v: float) -> void:
		Controller.settings_manager.set_ai_setting("ai_max_turns", str(int(v)))
		if Controller.agent_executor: Controller.agent_executor.max_turns = int(v)
	)
	_temperature_slider.min_value = 0.0; _temperature_slider.max_value = 1.0; _temperature_slider.step = 0.05; _temperature_slider.value = 0.7
	_temperature_slider.value_changed.connect(func(v: float) -> void:
		_temperature_label.text = "%.2f" % v
		Controller.settings_manager.set_ai_setting("ai_temperature", str(v))
		if Controller.llm_manager and Controller.llm_manager.active_provider: Controller.llm_manager.active_provider.temperature = v
	)
	_temperature_label.text = "0.70"
	_load_settings()
	_set_status("Ready", Color(0.6, 0.6, 0.6))


func _on_provider_selected(index: int) -> void:
	Controller.settings_manager.set_ai_setting("ai_provider", _provider_option.get_item_text(index).to_lower())
	_api_key_input.editable = index >= 2
	_api_key_input.placeholder_text = "API Key required" if index >= 2 else "Not needed for Ollama"


func _on_model_selected(index: int) -> void:
	var model_name: String = _model_option.get_item_text(index)
	Controller.settings_manager.set_ai_setting("ai_model", model_name)
	if Controller.llm_manager and Controller.llm_manager.active_provider:
		Controller.llm_manager.active_provider.model = model_name


func _on_api_key_changed(text: String) -> void:
	match _provider_option.selected:
		2: Controller.settings_manager.set_ai_setting("ai_api_key_openai", text)
		3: Controller.settings_manager.set_ai_setting("ai_api_key_openrouter", text)
		4: Controller.settings_manager.set_ai_setting("ai_api_key_gemini", text)


func _on_test() -> void:
	_set_status("Testing...", Color(0.8, 0.8, 0.3))
	var type: String = ["auto", "ollama", "openai", "openrouter", "gemini"][_provider_option.selected]
	if type == "auto":
		_on_auto_detect()
		return
	if await Controller.llm_manager.activate_provider(type):
		_set_status("Connected!", Color(0.3, 0.9, 0.3))
		_populate_models()
	else:
		_set_status("Connection failed", Color(1.0, 0.3, 0.3))


func _on_auto_detect() -> void:
	_set_status("Auto-detecting...", Color(0.8, 0.8, 0.3))
	var p := await Controller.llm_manager.auto_detect_provider()
	if p:
		_set_status("Connected to %s (%s)" % [p.provider_name, p.model], Color(0.3, 0.9, 0.3))
		_populate_models()
		match p.provider_name:
			"Ollama": _provider_option.selected = 1
			"OpenAI": _provider_option.selected = 2
			"OpenRouter": _provider_option.selected = 3
			"Gemini": _provider_option.selected = 4
	else:
		_set_status("No provider found", Color(1.0, 0.3, 0.3))


func _populate_models() -> void:
	_model_option.clear()
	if not Controller.llm_manager or not Controller.llm_manager.active_provider:
		return
	var models := await Controller.llm_manager.active_provider.get_available_models()
	for m: String in models:
		_model_option.add_item(m)
	var current := Controller.llm_manager.active_provider.model
	for i in _model_option.item_count:
		if _model_option.get_item_text(i) == current:
			_model_option.selected = i
			break


func _set_status(text: String, color: Color) -> void:
	if _status_label:
		_status_label.text = text
		_status_label.add_theme_color_override("font_color", color)


func _load_settings() -> void:
	match Controller.settings_manager.get_ai_setting("ai_provider", "auto"):
		"ollama": _provider_option.selected = 1
		"openai": _provider_option.selected = 2
		"openrouter": _provider_option.selected = 3
		"gemini": _provider_option.selected = 4
		_: _provider_option.selected = 0
	_base_url_input.text = Controller.settings_manager.get_ai_setting("ai_base_url", "http://localhost:11434")
	var mt := Controller.settings_manager.get_ai_setting("ai_max_turns", "20")
	_max_turns_spin.value = mt.to_int() if mt.is_valid_int() else 20
	var tv := Controller.settings_manager.get_ai_setting("ai_temperature", "0.7")
	var tf := tv.to_float() if tv.is_valid_float() else 0.7
	_temperature_slider.value = tf
	_temperature_label.text = "%.2f" % tf
