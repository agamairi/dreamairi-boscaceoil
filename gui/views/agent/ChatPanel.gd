###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Chat panel — messages + input.
extends VBoxContainer

@onready var _message_display: RichTextLabel = $MessageScroll/MessageDisplay
@onready var _input_field: LineEdit = $InputBar/InputField
@onready var _send_button: Button = $InputBar/SendButton
@onready var _clear_button: Button = $InputBar/ClearButton


func _ready() -> void:
	_send_button.pressed.connect(_submit_message)
	_clear_button.pressed.connect(_on_clear)
	_input_field.text_submitted.connect(func(_t: String) -> void: _submit_message())
	_message_display.bbcode_enabled = true
	_message_display.scroll_following = true
	_message_display.text = ""
	_sys("AI Music Agent ready. Type a message to begin.")


func _on_clear() -> void:
	_message_display.text = ""
	if Controller.agent_executor:
		Controller.agent_executor.reset_conversation()
	_sys("Conversation cleared.")


func _submit_message() -> void:
	var text := _input_field.text.strip_edges()
	if text.is_empty():
		return
	_input_field.text = ""
	add_user_message(text)
	if Controller.agent_executor:
		if Controller.agent_executor.is_running():
			add_error_message("Agent is still processing.")
			return
		Controller.agent_executor.send_message(text)
	else:
		add_error_message("Agent not initialized.")


func add_user_message(text: String) -> void:
	_message_display.push_color(Color(0.4, 0.8, 1.0))
	_message_display.push_bold()
	_message_display.add_text("You: ")
	_message_display.pop(); _message_display.pop()
	_message_display.add_text(text + "\n\n")


func add_agent_message(text: String) -> void:
	_message_display.push_color(Color(0.6, 1.0, 0.6))
	_message_display.push_bold()
	_message_display.add_text("Agent: ")
	_message_display.pop(); _message_display.pop()
	_message_display.add_text(text + "\n\n")


func add_tool_call(tool_name: String, arguments: Dictionary, result: Dictionary) -> void:
	_message_display.push_color(Color(0.7, 0.7, 0.7))
	_message_display.push_italics()
	var icon := "✓" if result.get("success", false) else "✗"
	var summary: String = result.get("message", result.get("error", ""))
	_message_display.add_text("  %s %s(%s) → %s\n" % [icon, tool_name, _summarize(arguments), summary])
	_message_display.pop(); _message_display.pop()


func add_error_message(text: String) -> void:
	_message_display.push_color(Color(1.0, 0.4, 0.4))
	_message_display.push_bold()
	_message_display.add_text("Error: ")
	_message_display.pop(); _message_display.pop()
	_message_display.add_text(text + "\n\n")


func _sys(text: String) -> void:
	_message_display.push_color(Color(0.5, 0.5, 0.6))
	_message_display.push_italics()
	_message_display.add_text(text + "\n")
	_message_display.pop(); _message_display.pop()


func _summarize(args: Dictionary) -> String:
	if args.is_empty():
		return ""
	var parts: PackedStringArray = []
	for key: String in args:
		var val: Variant = args[key]
		if val is Array:
			parts.push_back("%s=[%d]" % [key, val.size()])
		elif val is Dictionary:
			parts.push_back("%s={...}" % key)
		else:
			var s := str(val)
			parts.push_back("%s=%s" % [key, s.substr(0, 20) + "..." if s.length() > 20 else s])
	return ", ".join(parts)
