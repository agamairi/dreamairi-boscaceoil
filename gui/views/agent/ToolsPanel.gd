###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Tools panel — lists available tools.
extends VBoxContainer

@onready var _tools_list: RichTextLabel = $ToolsScroll/ToolsList


func _ready() -> void:
	_tools_list.bbcode_enabled = true
	var tools := MusicTools.new()
	_tools_list.text = ""
	_tools_list.push_bold()
	_tools_list.push_color(Color(0.7, 0.85, 1.0))
	_tools_list.add_text("Available Tools (%d)\n\n" % tools.tool_definitions.size())
	_tools_list.pop(); _tools_list.pop()

	for td: Dictionary in tools.tool_definitions:
		_tools_list.push_color(Color(0.4, 0.9, 0.7))
		_tools_list.push_bold()
		_tools_list.add_text(td.get("name", ""))
		_tools_list.pop(); _tools_list.pop()
		_tools_list.add_text("\n")
		_tools_list.push_color(Color(0.6, 0.6, 0.7))
		_tools_list.add_text("  %s\n\n" % td.get("description", ""))
		_tools_list.pop()
