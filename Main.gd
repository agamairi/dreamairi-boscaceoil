###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

extends MarginContainer

const REMOTE_CONTROL_SCRIPT := preload("res://ai/remote_control.gd")

var _default_window_title: String = ""
var _remote_control: RemoteControl = null
var _remote_music_tools: MusicTools = null

@onready var _pattern_editor: Control = %PatternEditor
@onready var _locked_indicator: Control = %LockedIndicator
@onready var _highlight_manager: CanvasLayer = %HighlightManager
@onready var _agent_window: Window = $AgentWindow


func _enter_tree() -> void:
	Controller.window_manager.register_window()
	
	_default_window_title = get_window().title


func _ready() -> void:
	Controller.window_manager.restore_window()
	
	_pattern_editor.visible = true
	_locked_indicator.visible = false
	Controller.io_manager.initialize_song()
	_edit_current_song()
	
	if not Engine.is_editor_hint():
		if Controller.settings_manager.is_first_time():
			Controller.show_welcome_message()
		
		Controller.song_loaded.connect(_edit_current_song)
		Controller.song_saved.connect(_update_window_title)
		Controller.song_saved.connect(_on_song_saved_event)
		
		Controller.controls_locked.connect(_show_locked_indicator)
		Controller.controls_unlocked.connect(_hide_locked_indicator)
		
		Controller.help_manager.highlight_requested.connect(_set_highlighted_node)
		Controller.help_manager.highlight_cleared.connect(_clear_highlighted_node)
		
		_init_remote_control()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _remote_control:
			_remote_control.send_event("closing")


func _init_remote_control() -> void:
	var handoff_path := ""
	var user_args := OS.get_cmdline_user_args()
	for i in user_args.size():
		if user_args[i] == "--dreamairi-handoff" and i + 1 < user_args.size():
			handoff_path = user_args[i + 1]
			break
	if handoff_path.is_empty():
		var cmd_args := OS.get_cmdline_args()
		for i in cmd_args.size():
			if cmd_args[i] == "--dreamairi-handoff" and i + 1 < cmd_args.size():
				handoff_path = cmd_args[i + 1]
				break
	
	if handoff_path.is_empty():
		return
	
	if not FileAccess.file_exists(handoff_path):
		printerr("Main: handoff file does not exist: %s" % handoff_path)
		return
	
	var file := FileAccess.open(handoff_path, FileAccess.READ)
	if file == null:
		printerr("Main: failed to open handoff file: %s" % handoff_path)
		return
	var content := file.get_as_text()
	file.close()
	
	# Delete handoff file immediately after reading
	DirAccess.remove_absolute(handoff_path)
	
	var json := JSON.new()
	var parse_err: Error = json.parse(content)
	if parse_err != OK or not (json.data is Dictionary):
		printerr("Main: malformed JSON in handoff file: %s" % handoff_path)
		return
	var handoff: Dictionary = json.data
	
	# Validate protocol == 1
	var protocol: int = int(handoff.get("protocol", 0))
	if protocol != 1:
		printerr("Main: unsupported protocol version %d in handoff" % protocol)
		return
	
	# Validate secret is 64 lowercase hex
	var secret: String = str(handoff.get("secret", ""))
	if secret.length() != 64:
		printerr("Main: invalid secret length in handoff")
		return
	var secret_regex := RegEx.new()
	secret_regex.compile("^[0-9a-f]{64}$")
	if secret_regex.search(secret) == null:
		printerr("Main: secret must be 64 lowercase hex characters")
		return
	
	# Validate and ensure output_dir exists
	var output_dir: String = str(handoff.get("output_dir", ""))
	if output_dir.is_empty():
		printerr("Main: missing output_dir in handoff")
		return
	if not DirAccess.dir_exists_absolute(output_dir):
		var make_err: Error = DirAccess.make_dir_recursive_absolute(output_dir)
		if make_err != OK:
			printerr("Main: failed to create output_dir %s (error %d)" % [output_dir, make_err])
			return
	
	MusicTools.output_dir = output_dir
	
	if Controller.agent_executor and Controller.agent_executor.music_tools:
		_remote_music_tools = Controller.agent_executor.music_tools
	else:
		_remote_music_tools = MusicTools.new()
	
	_remote_control = REMOTE_CONTROL_SCRIPT.new(handoff, _execute_remote_tool)
	_remote_control.shutdown_requested.connect(_on_remote_shutdown)
	add_child(_remote_control)
	
	Controller.song_loaded.connect(_on_remote_song_changed)
	Controller.song_sizes_changed.connect(_on_remote_song_changed)
	Controller.song_bpm_changed.connect(_on_remote_song_changed)
	Controller.song_effect_changed.connect(_on_remote_song_changed)
	Controller.song_swing_changed.connect(_on_remote_song_changed)
	Controller.song_pattern_created.connect(_on_remote_song_changed)
	Controller.song_pattern_changed.connect(_on_remote_song_changed)
	Controller.song_instrument_created.connect(_on_remote_song_changed)
	Controller.song_instrument_changed.connect(_on_remote_song_changed)
	
	if Controller.music_player:
		Controller.music_player.playback_started.connect(_on_remote_transport_changed)
		Controller.music_player.playback_stopped.connect(_on_remote_transport_changed)
		Controller.music_player.playback_paused.connect(_on_remote_transport_changed)
		Controller.music_player.playback_tick.connect(_on_remote_transport_changed)
		Controller.music_player.playback_bar_changed.connect(_on_remote_transport_changed)


func _execute_remote_tool(tool_name: String, args: Dictionary) -> Dictionary:
	var result: Dictionary = _remote_music_tools.execute(tool_name, args)
	if not result.has("error") and Controller.agent_executor:
		Controller.agent_executor._refresh_ui(tool_name)
	return result


func _on_song_saved_event() -> void:
	if _remote_control:
		_remote_control.send_event("song_saved")


func _on_remote_song_changed() -> void:
	if _remote_control:
		_remote_control.notify_song_changed()


func _on_remote_transport_changed() -> void:
	if _remote_control:
		var is_playing: bool = false
		var step: int = 0
		if Controller.music_player:
			is_playing = Controller.music_player.is_playing()
			step = maxi(0, Controller.music_player.get_pattern_time())
		var bar: int = 0
		if Controller.current_song and Controller.current_song.arrangement:
			bar = Controller.current_song.arrangement.current_bar_idx
		_remote_control.notify_transport(is_playing, bar, step)


func _on_remote_shutdown() -> void:
	if DisplayServer.get_name() == "headless":
		if _remote_control:
			_remote_control.send_event("closing")
		get_tree().quit()
		return

	# Ask for confirmation before quitting if there are unsaved edits so work is not lost.
	if Controller.current_song and Controller.current_song.is_dirty():
		Controller.io_manager.check_song_on_exit()
		return

	if _remote_control:
		_remote_control.send_event("closing")
	get_tree().quit()


func _shortcut_input(event: InputEvent) -> void:
	if event.is_action_pressed("bosca_toggle_ai", false, true):
		_toggle_agent_window()
		get_viewport().set_input_as_handled()


func _toggle_agent_window() -> void:
	if _agent_window:
		_agent_window.toggle()


# Window decorations.

func _edit_current_song() -> void:
	if Engine.is_editor_hint():
		return
	
	_update_window_title()
	if Controller.current_song:
		Controller.current_song.song_changed.connect(_update_window_title)


func _update_window_title() -> void:
	if Engine.is_editor_hint():
		return
	
	if not Controller.current_song:
		get_window().title = _default_window_title
		return
	
	var song_name := "<New Song>" if Controller.current_song.filename.is_empty() else Controller.current_song.filename.get_file()
	var song_dirty := "* " if Controller.current_song.is_dirty() else ""
	
	get_window().title = "%s%s - %s" % [ song_dirty, song_name, _default_window_title ]


# Editor locking.

func _show_locked_indicator(message: String) -> void:
	_pattern_editor.visible = false
	_locked_indicator.message = message
	_locked_indicator.visible = true


func _hide_locked_indicator() -> void:
	_pattern_editor.visible = true
	_locked_indicator.visible = false


# Node highlighting.

func _set_highlighted_node(rect_getter: Callable) -> void:
	if rect_getter.is_valid():
		_highlight_manager.highlight_rect_getter = rect_getter
	else:
		_highlight_manager.highlight_rect_getter = Callable()
	
	_highlight_manager.update_highlight()


func _clear_highlighted_node() -> void:
	_highlight_manager.highlight_rect_getter = Callable()
	
	_highlight_manager.update_highlight()
