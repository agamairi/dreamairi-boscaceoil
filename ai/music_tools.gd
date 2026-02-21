###################################################
# Part of Bosca Ceoil Blue                        #
# Copyright (c) 2025 Yuri Sizov and contributors  #
# Provided under MIT                              #
###################################################

## Defines and executes all music tools available to the AI agent.
class_name MusicTools extends RefCounted

var tool_definitions: Array = []
var call_log: Array[Dictionary] = []


func _init() -> void:
	_register_tools()


func _register_tools() -> void:
	tool_definitions = [
		{"name": "create_song", "description": "Create a new song. Resets everything.", "parameters": {"type": "object", "properties": {"bpm": {"type": "integer", "description": "BPM (10-450)", "default": 120}, "pattern_size": {"type": "integer", "description": "Notes per pattern (1-32)", "default": 16}, "key": {"type": "integer", "description": "Key 0-11 (0=C)", "default": 0}, "scale": {"type": "integer", "description": "Scale 0-22", "default": 0}}, "required": []}},

		{"name": "add_instrument", "description": "Add an instrument. Returns index. Use list_instruments to find names.", "parameters": {"type": "object", "properties": {"category": {"type": "string", "description": "Category (MIDI, CHIPTUNE, DRUMKIT, etc.)"}, "name": {"type": "string", "description": "Instrument name"}}, "required": ["category", "name"]}},

		{"name": "remove_instrument", "description": "Remove an instrument by index.", "parameters": {"type": "object", "properties": {"instrument_index": {"type": "integer"}}, "required": ["instrument_index"]}},

		{"name": "create_pattern", "description": "Create empty pattern for an instrument. Returns pattern index.", "parameters": {"type": "object", "properties": {"instrument_index": {"type": "integer"}, "key": {"type": "integer", "default": 0}, "scale": {"type": "integer", "default": 0}}, "required": ["instrument_index"]}},

		{"name": "add_notes", "description": "Add notes to a pattern. note=MIDI value (60=middle C), position=step (0-based), length=duration in steps.", "parameters": {"type": "object", "properties": {"pattern_index": {"type": "integer"}, "notes": {"type": "array", "items": {"type": "object", "properties": {"note": {"type": "integer"}, "position": {"type": "integer"}, "length": {"type": "integer", "default": 1}}, "required": ["note", "position"]}}}, "required": ["pattern_index", "notes"]}},

		{"name": "remove_notes", "description": "Remove notes from a pattern by value and position.", "parameters": {"type": "object", "properties": {"pattern_index": {"type": "integer"}, "notes": {"type": "array", "items": {"type": "object", "properties": {"note": {"type": "integer"}, "position": {"type": "integer"}}, "required": ["note", "position"]}}}, "required": ["pattern_index", "notes"]}},

		{"name": "set_arrangement", "description": "Place patterns on timeline. Use -1 to clear a slot.", "parameters": {"type": "object", "properties": {"entries": {"type": "array", "items": {"type": "object", "properties": {"bar": {"type": "integer"}, "channel": {"type": "integer", "description": "0-7"}, "pattern_index": {"type": "integer"}}, "required": ["bar", "channel", "pattern_index"]}}}, "required": ["entries"]}},

		{"name": "set_effect", "description": "Set global effect. 0=None,1=Delay,2=Chorus,3=Reverb,4=Distortion,5=LowBoost,6=Compressor,7=HighPass.", "parameters": {"type": "object", "properties": {"effect": {"type": "integer"}, "power": {"type": "integer", "default": 50}}, "required": ["effect"]}},

		{"name": "get_song_state", "description": "Returns full song state for verification.", "parameters": {"type": "object", "properties": {}, "required": []}},

		{"name": "play_song", "description": "Start or stop playback.", "parameters": {"type": "object", "properties": {"action": {"type": "string", "enum": ["play", "stop"]}}, "required": ["action"]}},

		{"name": "export_song", "description": "Export to wav or midi.", "parameters": {"type": "object", "properties": {"format": {"type": "string", "enum": ["wav", "midi"]}, "filename": {"type": "string"}}, "required": ["format"]}},

		{"name": "list_instruments", "description": "List available instruments, optionally filtered by category.", "parameters": {"type": "object", "properties": {"category": {"type": "string"}}, "required": []}},
	]


func execute(tool_name: String, arguments: Dictionary) -> Dictionary:
	var result: Dictionary
	var t0 := Time.get_ticks_msec()

	match tool_name:
		"create_song": result = _create_song(arguments)
		"add_instrument": result = _add_instrument(arguments)
		"remove_instrument": result = _remove_instrument(arguments)
		"create_pattern": result = _create_pattern(arguments)
		"add_notes": result = _add_notes(arguments)
		"remove_notes": result = _remove_notes(arguments)
		"set_arrangement": result = _set_arrangement(arguments)
		"set_effect": result = _set_effect(arguments)
		"get_song_state": result = _get_song_state(arguments)
		"play_song": result = _play_song(arguments)
		"export_song": result = _export_song(arguments)
		"list_instruments": result = _list_instruments(arguments)
		_: result = {"error": "Unknown tool: %s" % tool_name}

	call_log.push_back({"tool": tool_name, "arguments": arguments, "result": result, "elapsed_ms": Time.get_ticks_msec() - t0, "timestamp": Time.get_datetime_string_from_system()})
	return result


func _create_song(args: Dictionary) -> Dictionary:
	Controller.io_manager.create_new_song()
	var song := Controller.current_song
	if not song:
		return {"error": "Failed to create song"}
	song.bpm = args.get("bpm", 120)
	song.pattern_size = args.get("pattern_size", 16)
	if not song.patterns.is_empty():
		song.patterns[0].key = args.get("key", 0)
		song.patterns[0].scale = args.get("scale", 0)
	song.mark_dirty()
	Controller.music_player.update_driver_bpm()
	return {"success": true, "message": "Created song: %d BPM, %d steps" % [song.bpm, song.pattern_size]}


func _add_instrument(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	if song.instruments.size() >= Song.MAX_INSTRUMENT_COUNT:
		return {"error": "Max instruments reached"}
	var cat: String = args.get("category", "")
	var req_name: String = args.get("name", "")
	var voice_data: VoiceManager.VoiceData = _find_voice(cat, req_name)
	if voice_data == null:
		return {"error": "Instrument not found: %s / %s. Use list_instruments to see available names." % [cat, req_name]}
	var inst: Instrument
	if voice_data.category == "DRUMKIT":
		inst = DrumkitInstrument.new(voice_data)
	else:
		inst = SingleVoiceInstrument.new(voice_data)
	song.add_instrument(inst)
	var idx := song.instruments.size() - 1
	Controller.edit_instrument(idx)
	song.mark_dirty()
	return {"success": true, "instrument_index": idx, "message": "Added '%s' (matched '%s') at index %d" % [req_name, voice_data.name, idx]}


## Fuzzy instrument lookup: exact match → substring match → first in category.
func _find_voice(category: String, name: String) -> VoiceManager.VoiceData:
	# 1. Exact match.
	var exact := Controller.voice_manager.get_voice_data(category, name)
	if exact:
		return exact

	# 2. Case-insensitive substring match across all voices in category.
	var name_lower := name.to_lower()
	var cats := Controller.voice_manager.get_categories()
	var search_cats: Array[String] = []
	for c: String in cats:
		if category.is_empty() or c.to_lower() == category.to_lower():
			search_cats.push_back(c)

	var best_match: VoiceManager.VoiceData = null
	var first_in_cat: VoiceManager.VoiceData = null
	for c: String in search_cats:
		var subs := Controller.voice_manager.get_sub_categories(c)
		for sub: VoiceManager.SubCategory in subs:
			for voice: VoiceManager.VoiceData in sub.voices:
				if first_in_cat == null:
					first_in_cat = voice
				if voice.name.to_lower().contains(name_lower) or name_lower.contains(voice.name.to_lower()):
					best_match = voice
					break
			if best_match:
				break
		if best_match:
			break

	if best_match:
		return best_match

	# 3. Fallback: first instrument in the category.
	return first_in_cat


func _remove_instrument(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	var idx: int = args.get("instrument_index", -1)
	if idx < 0 or idx >= song.instruments.size():
		return {"error": "Invalid instrument index"}
	if song.instruments.size() <= 1:
		return {"error": "Cannot remove last instrument"}
	song.remove_instrument(idx)
	song.mark_dirty()
	return {"success": true, "message": "Removed instrument %d" % idx}


func _create_pattern(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	if song.patterns.size() >= Song.MAX_PATTERN_COUNT:
		return {"error": "Max patterns reached"}
	var inst_idx: int = args.get("instrument_index", 0)
	if inst_idx < 0 or inst_idx >= song.instruments.size():
		return {"error": "Invalid instrument index"}
	var pattern := Pattern.new()
	pattern.instrument_idx = inst_idx
	pattern.key = args.get("key", 0)
	pattern.scale = args.get("scale", 0)
	song.add_pattern(pattern)
	var pat_idx := song.patterns.size() - 1
	Controller.edit_pattern(pat_idx)
	song.mark_dirty()
	return {"success": true, "pattern_index": pat_idx, "message": "Created pattern %d" % pat_idx}


func _add_notes(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	var pat_idx: int = args.get("pattern_index", 0)
	if pat_idx < 0 or pat_idx >= song.patterns.size():
		return {"error": "Invalid pattern index"}
	var pattern := song.patterns[pat_idx]
	var added := 0
	for nd: Variant in args.get("notes", []):
		var d: Dictionary = _coerce_note_dict(nd)
		if d.is_empty():
			continue
		var pos: int = d.get("position", 0)
		if pos >= 0 and pos < song.pattern_size and d.get("note", -1) >= 0:
			pattern.add_note(d["note"], pos, maxi(d.get("length", 1), 1))
			added += 1
	song.mark_dirty()
	return {"success": true, "added_count": added, "message": "Added %d notes to pattern %d" % [added, pat_idx]}


func _remove_notes(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	var pat_idx: int = args.get("pattern_index", 0)
	if pat_idx < 0 or pat_idx >= song.patterns.size():
		return {"error": "Invalid pattern index"}
	var pattern := song.patterns[pat_idx]
	var removed := 0
	for nd: Variant in args.get("notes", []):
		var d: Dictionary = _coerce_note_dict(nd)
		if d.is_empty():
			continue
		pattern.remove_note(d.get("note", 0), d.get("position", 0))
		removed += 1
	song.mark_dirty()
	return {"success": true, "removed_count": removed, "message": "Removed %d notes from pattern %d" % [removed, pat_idx]}


func _set_arrangement(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	var placed := 0
	for e: Variant in args.get("entries", []):
		var d: Dictionary = _coerce_entry_dict(e)
		if d.is_empty():
			continue
		var bar: int = d.get("bar", 0)
		var ch: int = d.get("channel", 0)
		var pi: int = d.get("pattern_index", -1)
		if bar >= 0 and bar < Arrangement.BAR_NUMBER and ch >= 0 and ch < Arrangement.CHANNEL_NUMBER:
			if pi < 0:
				song.arrangement.clear_pattern(bar, ch)
			else:
				song.arrangement.set_pattern(bar, ch, pi)
			placed += 1
	song.mark_dirty()
	return {"success": true, "placed_count": placed, "message": "Set %d arrangement entries" % placed}


func _set_effect(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	song.global_effect = args.get("effect", 0)
	song.global_effect_power = args.get("power", 50)
	Controller.music_player.update_driver_effects()
	song.mark_dirty()
	return {"success": true, "message": "Set effect %d power %d" % [song.global_effect, song.global_effect_power]}


func _get_song_state(_args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}

	var insts: Array = []
	for i in song.instruments.size():
		var inst := song.instruments[i]
		insts.push_back({"index": i, "name": inst.name, "category": inst.category, "type": "drumkit" if inst.type == Instrument.InstrumentType.INSTRUMENT_DRUMKIT else "single", "volume": inst.volume})

	var pats: Array = []
	for i in song.patterns.size():
		var pat := song.patterns[i]
		var notes: Array = []
		for n in pat.note_amount:
			var note := pat.notes[n]
			if note.x >= 0:
				notes.push_back({"note": note.x, "position": note.y, "length": note.z})
		pats.push_back({"index": i, "instrument_index": pat.instrument_idx, "key": pat.key, "key_name": Note.get_note_name(pat.key), "scale": pat.scale, "scale_name": Scale.get_scale_name(pat.scale), "note_count": pat.note_amount, "notes": notes})

	var arr: Array = []
	for bar in song.arrangement.timeline_length:
		for ch in Arrangement.CHANNEL_NUMBER:
			var pi := song.arrangement.get_pattern(bar, ch)
			if pi >= 0:
				arr.push_back({"bar": bar, "channel": ch, "pattern_index": pi})

	return {"success": true, "message": "%d instruments, %d patterns, %d arrangement entries" % [insts.size(), pats.size(), arr.size()], "bpm": song.bpm, "pattern_size": song.pattern_size, "instruments": insts, "patterns": pats, "arrangement": arr, "global_effect": song.global_effect, "global_effect_power": song.global_effect_power}


func _play_song(args: Dictionary) -> Dictionary:
	if args.get("action", "play") == "play":
		if not Controller.music_player.is_playing():
			Controller.music_player.start_playback()
		return {"success": true, "message": "Playback started"}
	else:
		if Controller.music_player.is_playing():
			Controller.music_player.stop_playback()
		return {"success": true, "message": "Playback stopped"}


func _export_song(args: Dictionary) -> Dictionary:
	var song := Controller.current_song
	if not song:
		return {"error": "No song loaded"}
	return {"success": true, "message": "Export requested as %s. Use File > Export." % args.get("format", "wav").to_upper()}


func _list_instruments(args: Dictionary) -> Dictionary:
	var filter: String = args.get("category", "")
	var cats := Controller.voice_manager.get_categories()
	var out: Array = []
	for cat: String in cats:
		if not filter.is_empty() and cat.to_lower() != filter.to_lower():
			continue
		var subs := Controller.voice_manager.get_sub_categories(cat)
		for sub: VoiceManager.SubCategory in subs:
			for voice: VoiceManager.VoiceData in sub.voices:
				out.push_back({"category": cat, "name": voice.name, "index": voice.index})
	var cat_list: Array = []
	for c: String in (cats if filter.is_empty() else PackedStringArray([filter])):
		cat_list.push_back(c)
	return {"success": true, "message": "Found %d instruments" % out.size(), "instrument_count": out.size(), "instruments": out, "categories": cat_list}


## Coerce a note entry from either a Dictionary or Array [note, position, length?] into a Dictionary.
func _coerce_note_dict(v: Variant) -> Dictionary:
	if v is Dictionary:
		return v as Dictionary
	if v is Array:
		var a: Array = v as Array
		if a.size() >= 2:
			var d := {"note": int(a[0]), "position": int(a[1])}
			if a.size() >= 3:
				d["length"] = int(a[2])
			return d
	return {}


## Coerce an arrangement entry from either a Dictionary or Array [bar, channel, pattern_index] into a Dictionary.
func _coerce_entry_dict(v: Variant) -> Dictionary:
	if v is Dictionary:
		return v as Dictionary
	if v is Array:
		var a: Array = v as Array
		if a.size() >= 3:
			return {"bar": int(a[0]), "channel": int(a[1]), "pattern_index": int(a[2])}
	return {}
