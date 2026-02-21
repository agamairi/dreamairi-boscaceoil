###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Status panel — agent state, provider, controls.
extends VBoxContainer

@onready var _state_label: Label = $StateRow/StateValue
@onready var _provider_label: Label = $ProviderRow/ProviderValue
@onready var _step_label: Label = $StepRow/StepValue
@onready var _play_button: Button = $Controls/PlayButton
@onready var _stop_button: Button = $Controls/StopButton


func _ready() -> void:
	_play_button.pressed.connect(func() -> void:
		if not Controller.music_player.is_playing():
			Controller.music_player.start_playback()
	)
	_stop_button.pressed.connect(func() -> void:
		if Controller.music_player.is_playing():
			Controller.music_player.stop_playback()
	)
	set_state("Idle")
	_update_provider()
	if Controller.llm_manager:
		Controller.llm_manager.provider_changed.connect(func(_p: LLMProvider) -> void: _update_provider())


func set_state(text: String) -> void:
	if _state_label:
		_state_label.text = text
	if _step_label and Controller.agent_executor:
		_step_label.text = "%d / %d" % [Controller.agent_executor.current_turn, Controller.agent_executor.max_turns]


func _update_provider() -> void:
	if not _provider_label:
		return
	if Controller.llm_manager and Controller.llm_manager.active_provider:
		var p := Controller.llm_manager.active_provider
		_provider_label.text = "%s (%s)" % [p.provider_name, p.model]
	else:
		_provider_label.text = "Not connected"
