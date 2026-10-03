extends Node
## Lightweight persistent boolean flags. ConditionSystem reads these for FLAG_EQUALS.
## No quest/NPC-specific keys — callers choose flag ids.

signal flag_changed(flag_id: String, value: bool)
signal flags_cleared

## flag_id → bool
var _flags: Dictionary = {}


func set_flag(flag_id: String, value: bool = true) -> void:
	if flag_id.is_empty():
		return
	var previous: Variant = _flags.get(flag_id, null)
	_flags[flag_id] = value
	if previous == null or bool(previous) != value:
		flag_changed.emit(flag_id, value)


func get_flag(flag_id: String, default_value: bool = false) -> bool:
	if flag_id.is_empty():
		return default_value
	if not _flags.has(flag_id):
		return default_value
	return bool(_flags[flag_id])


func has_flag(flag_id: String) -> bool:
	## True when the flag exists and is true (common gameplay check).
	if flag_id.is_empty():
		return false
	return bool(_flags.get(flag_id, false))


func flag_exists(flag_id: String) -> bool:
	## True if the key was ever set (even to false).
	if flag_id.is_empty():
		return false
	return _flags.has(flag_id)


func clear_flag(flag_id: String) -> void:
	if flag_id.is_empty():
		return
	if _flags.erase(flag_id):
		flag_changed.emit(flag_id, false)


func clear_all() -> void:
	_flags.clear()
	flags_cleared.emit()


func get_all_flags() -> Dictionary:
	return _flags.duplicate()


func reset_for_tests() -> void:
	clear_all()


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	var flags: Dictionary = {}
	for key in _flags.keys():
		flags[str(key)] = bool(_flags[key])
	return {"flags": flags}


func load_save_data(data: Dictionary) -> void:
	_flags.clear()
	if data == null or data.is_empty():
		flags_cleared.emit()
		return
	var raw: Variant = data.get("flags", {})
	if typeof(raw) != TYPE_DICTIONARY:
		flags_cleared.emit()
		return
	for key in raw.keys():
		var fid := str(key)
		if fid.is_empty():
			continue
		_flags[fid] = bool(raw[key])
	flags_cleared.emit()
	for key in _flags.keys():
		flag_changed.emit(str(key), bool(_flags[key]))
