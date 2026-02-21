###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Logs panel — tool call history.
extends VBoxContainer

@onready var _log_display: RichTextLabel = $LogScroll/LogDisplay


func _ready() -> void:
	_log_display.bbcode_enabled = true
	_log_display.scroll_following = true
	_log_display.text = ""


func add_log_entry(tool_name: String, _arguments: Dictionary, result: Dictionary) -> void:
	var ok: bool = result.get("success", false)
	var ts := Time.get_datetime_string_from_system().substr(11, 8)
	_log_display.push_color(Color(0.5, 0.5, 0.5))
	_log_display.add_text("[%s] " % ts)
	_log_display.pop()
	_log_display.push_color(Color(0.4, 0.9, 0.4) if ok else Color(1.0, 0.4, 0.4))
	_log_display.push_bold()
	_log_display.add_text(tool_name)
	_log_display.pop(); _log_display.pop()
	_log_display.add_text("\n")
	_log_display.push_color(Color(0.5, 0.5, 0.6))
	_log_display.add_text("  → %s\n\n" % result.get("message", result.get("error", "")))
	_log_display.pop()
