###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## The agentic loop: PLAN → TOOLS → VERIFY → ITERATE.
## Uses await for async LLM calls to keep the UI responsive.
class_name AgentExecutor extends RefCounted

signal step_started(step_number: int, phase: String)
signal step_completed(step_number: int, phase: String)
signal tool_called(tool_name: String, arguments: Dictionary, result: Dictionary)
signal agent_message(content: String)
signal agent_finished(final_message: String)
signal agent_error(error: String)

enum AgentState { IDLE, PLANNING, EXECUTING, VERIFYING, DONE, ERROR }

var state: AgentState = AgentState.IDLE
var max_turns: int = 20
var conversation: Array = []
var music_tools: MusicTools = MusicTools.new()
var current_turn: int = 0
var _running: bool = false
## Track whether the agent has made any actual tool calls this session.
var _has_called_tools: bool = false


func send_message(user_message: String) -> void:
	if _running:
		agent_error.emit("Agent is already running")
		return
	_running = true
	current_turn = 0
	_has_called_tools = false

	if conversation.is_empty():
		conversation.push_back({"role": "system", "content": AgentSystemPrompt.build()})
	conversation.push_back({"role": "user", "content": user_message})
	_run_agent_loop()


func reset_conversation() -> void:
	conversation.clear()
	current_turn = 0
	state = AgentState.IDLE
	_has_called_tools = false


func is_running() -> bool:
	return _running


func _run_agent_loop() -> void:
	var provider := Controller.llm_manager.active_provider
	if provider == null:
		state = AgentState.ERROR
		_running = false
		agent_error.emit("No LLM provider configured. Open AI Settings.")
		return

	while current_turn < max_turns and _running:
		current_turn += 1
		state = AgentState.PLANNING if current_turn == 1 else AgentState.EXECUTING
		step_started.emit(current_turn, "Planning" if current_turn == 1 else "Executing")

		var response: Dictionary = await provider.send_message(conversation, music_tools.tool_definitions)
		if response.has("error"):
			state = AgentState.ERROR
			_running = false
			agent_error.emit("LLM error: %s" % response["error"])
			return

		var content: String = response.get("content", "")
		var tool_calls: Array = response.get("tool_calls", [])

		if not content.is_empty():
			agent_message.emit(content)

		if tool_calls.is_empty():
			# If the LLM just returned text without calling tools on the first turn,
			# nudge it to actually use tools.
			if not _has_called_tools and current_turn <= 2:
				conversation.push_back({"role": "assistant", "content": content})
				conversation.push_back({"role": "user", "content": "You must use the tool functions to create the music. Start by calling create_song, then add_instrument, create_pattern, add_notes, and set_arrangement. Call the tools now."})
				step_completed.emit(current_turn, "Re-prompting to use tools")
				continue

			state = AgentState.DONE
			_running = false
			step_completed.emit(current_turn, "Done")
			agent_finished.emit(content)
			return

		var assistant_msg := {"role": "assistant"} as Dictionary
		if not content.is_empty():
			assistant_msg["content"] = content
		assistant_msg["tool_calls"] = tool_calls
		conversation.push_back(assistant_msg)

		state = AgentState.EXECUTING
		for tc: Dictionary in tool_calls:
			var tool_name: String = tc.get("name", "")
			var tool_args: Dictionary = tc.get("arguments", {})
			var tool_id: String = tc.get("id", "")

			step_started.emit(current_turn, "Tool: %s" % tool_name)
			var result := music_tools.execute(tool_name, tool_args)
			tool_called.emit(tool_name, tool_args, result)
			_has_called_tools = true

			conversation.push_back({"role": "tool", "content": JSON.stringify(result), "tool_call_id": tool_id, "name": tool_name})

			# Notify UI to refresh after state-changing tools.
			_refresh_ui(tool_name)

		step_completed.emit(current_turn, "Tools executed")

		if tool_calls[-1].get("name", "") == "get_song_state":
			state = AgentState.VERIFYING

	state = AgentState.DONE
	_running = false
	agent_finished.emit("Reached maximum turns (%d)." % max_turns)


## Emit Controller signals to force the main UI to refresh.
func _refresh_ui(tool_name: String) -> void:
	match tool_name:
		"create_song":
			# Don't emit song_loaded — that triggers Main._edit_current_song()
			# which reconnects signals and causes errors. Instead, emit individual
			# change signals that safely refresh the UI panels.
			Controller.song_bpm_changed.emit()
			Controller.song_sizes_changed.emit()
			Controller.song_instrument_changed.emit()
			Controller.song_pattern_changed.emit()
		"add_instrument":
			Controller.song_instrument_created.emit()
			Controller.song_instrument_changed.emit()
		"remove_instrument":
			Controller.song_instrument_changed.emit()
		"create_pattern":
			Controller.song_pattern_created.emit()
			Controller.song_pattern_changed.emit()
		"add_notes", "remove_notes":
			Controller.song_pattern_changed.emit()
		"set_arrangement":
			Controller.song_sizes_changed.emit()
		"set_effect":
			Controller.song_effect_changed.emit()
		"play_song":
			pass # Playback handles its own UI.
