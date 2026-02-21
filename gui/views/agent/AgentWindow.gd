###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Floating AI agent window.
extends Window

@onready var _chat_panel: Control = $Main/HSplit/ChatPanel
@onready var _status_panel: Control = $Main/HSplit/RightSide/StatusPanel
@onready var _tabs: TabContainer = $Main/HSplit/RightSide/Tabs

var _agent_executor: AgentExecutor = null


func _ready() -> void:
	close_requested.connect(hide)
	title = "AI Music Agent"
	min_size = Vector2i(500, 400)
	size = Vector2i(700, 600)
	if get_parent() is Window:
		var pw: Window = get_parent() as Window
		position = pw.position + Vector2i((pw.size.x - size.x) / 2, (pw.size.y - size.y) / 2)

	_agent_executor = Controller.agent_executor
	if _agent_executor:
		_agent_executor.agent_message.connect(_on_agent_message)
		_agent_executor.tool_called.connect(_on_tool_called)
		_agent_executor.agent_finished.connect(_on_agent_finished)
		_agent_executor.agent_error.connect(_on_agent_error)
		_agent_executor.step_started.connect(_on_step_started)


func toggle() -> void:
	visible = not visible
	if visible:
		grab_focus()


func _on_agent_message(content: String) -> void:
	if _chat_panel:
		_chat_panel.add_agent_message(content)


func _on_tool_called(tool_name: String, arguments: Dictionary, result: Dictionary) -> void:
	if _chat_panel:
		_chat_panel.add_tool_call(tool_name, arguments, result)
	var logs := _tabs.get_child(0) if _tabs and _tabs.get_child_count() > 0 else null
	if logs and logs.has_method("add_log_entry"):
		logs.add_log_entry(tool_name, arguments, result)


func _on_agent_finished(final_message: String) -> void:
	if _status_panel:
		_status_panel.set_state("Done")
	if not final_message.is_empty() and _chat_panel:
		_chat_panel.add_agent_message(final_message)


func _on_agent_error(error: String) -> void:
	if _status_panel:
		_status_panel.set_state("Error")
	if _chat_panel:
		_chat_panel.add_error_message(error)


func _on_step_started(step_number: int, phase: String) -> void:
	if _status_panel:
		_status_panel.set_state("%s (step %d)" % [phase, step_number])
