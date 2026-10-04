extends Node
## Persistent campaign state for NPCs, keyed by npc_id.
## NpcDefinition remains static authoring data — this stores mutable runtime fields.
## No Node references. Survives scene unload via SaveSystem.

signal npc_state_changed(npc_id: String, field: String, value: Variant)
signal npc_met_player(npc_id: String)
signal npc_states_cleared

## Suggested extensible state tags (stored as strings, not a rigid enum).
const STATE_DEFAULT := "DEFAULT"
const STATE_BUSY := "BUSY"
const STATE_UNAVAILABLE := "UNAVAILABLE"
const STATE_TRAVELING := "TRAVELING"
const STATE_QUEST_RELATED := "QUEST_RELATED"

## npc_id → Dictionary payload
var _states: Dictionary = {}


func has_npc(npc_id: String) -> bool:
	return not npc_id.is_empty() and _states.has(npc_id)


func ensure_npc(npc_id: String, defaults: Dictionary = {}) -> void:
	if npc_id.is_empty() or _states.has(npc_id):
		return
	_states[npc_id] = _default_payload(defaults)


func get_state_payload(npc_id: String) -> Dictionary:
	if npc_id.is_empty():
		return {}
	ensure_npc(npc_id)
	return (_states[npc_id] as Dictionary).duplicate(true)


func is_enabled(npc_id: String) -> bool:
	ensure_npc(npc_id)
	return bool(_states[npc_id].get("enabled", true))


func set_enabled(npc_id: String, value: bool) -> void:
	if npc_id.is_empty():
		return
	ensure_npc(npc_id)
	var entry: Dictionary = _states[npc_id]
	if bool(entry.get("enabled", true)) == value:
		return
	entry["enabled"] = value
	_states[npc_id] = entry
	npc_state_changed.emit(npc_id, "enabled", value)


func has_met_player(npc_id: String) -> bool:
	if npc_id.is_empty() or not _states.has(npc_id):
		return false
	return bool(_states[npc_id].get("met_player", false))


func set_met_player(npc_id: String, value: bool = true) -> void:
	if npc_id.is_empty():
		return
	ensure_npc(npc_id)
	var entry: Dictionary = _states[npc_id]
	var previous := bool(entry.get("met_player", false))
	if previous == value:
		return
	entry["met_player"] = value
	_states[npc_id] = entry
	npc_state_changed.emit(npc_id, "met_player", value)
	if value:
		npc_met_player.emit(npc_id)


func get_current_state(npc_id: String) -> String:
	ensure_npc(npc_id)
	return str(_states[npc_id].get("current_state", STATE_DEFAULT))


func set_current_state(npc_id: String, state_tag: String) -> void:
	if npc_id.is_empty():
		return
	var tag := state_tag.strip_edges().to_upper()
	if tag.is_empty():
		tag = STATE_DEFAULT
	ensure_npc(npc_id)
	var entry: Dictionary = _states[npc_id]
	if str(entry.get("current_state", STATE_DEFAULT)) == tag:
		return
	entry["current_state"] = tag
	_states[npc_id] = entry
	npc_state_changed.emit(npc_id, "current_state", tag)


func get_location_id(npc_id: String) -> String:
	ensure_npc(npc_id)
	return str(_states[npc_id].get("current_location_id", ""))


func set_location_id(npc_id: String, location_id: String) -> void:
	if npc_id.is_empty():
		return
	ensure_npc(npc_id)
	var entry: Dictionary = _states[npc_id]
	var next := str(location_id)
	if str(entry.get("current_location_id", "")) == next:
		return
	entry["current_location_id"] = next
	_states[npc_id] = entry
	npc_state_changed.emit(npc_id, "current_location_id", next)


func get_schedule_id(npc_id: String) -> String:
	ensure_npc(npc_id)
	return str(_states[npc_id].get("current_schedule_id", ""))


func set_schedule_id(npc_id: String, schedule_id: String) -> void:
	## Written by NpcScheduleSystem when a routine is active.
	if npc_id.is_empty():
		return
	ensure_npc(npc_id)
	var entry: Dictionary = _states[npc_id]
	var next := str(schedule_id)
	if str(entry.get("current_schedule_id", "")) == next:
		return
	entry["current_schedule_id"] = next
	_states[npc_id] = entry
	npc_state_changed.emit(npc_id, "current_schedule_id", next)


func get_last_dialogue_id(npc_id: String) -> String:
	ensure_npc(npc_id)
	return str(_states[npc_id].get("last_dialogue_id", ""))


func set_last_dialogue_id(npc_id: String, dialogue_id: String) -> void:
	if npc_id.is_empty():
		return
	ensure_npc(npc_id)
	var entry: Dictionary = _states[npc_id]
	var next := str(dialogue_id)
	if str(entry.get("last_dialogue_id", "")) == next:
		return
	entry["last_dialogue_id"] = next
	_states[npc_id] = entry
	npc_state_changed.emit(npc_id, "last_dialogue_id", next)


func get_custom_flag(npc_id: String, flag_id: String, default_value: bool = false) -> bool:
	if npc_id.is_empty() or flag_id.is_empty() or not _states.has(npc_id):
		return default_value
	var flags: Variant = _states[npc_id].get("custom_flags", {})
	if typeof(flags) != TYPE_DICTIONARY:
		return default_value
	return bool(flags.get(flag_id, default_value))


func set_custom_flag(npc_id: String, flag_id: String, value: bool = true) -> void:
	if npc_id.is_empty() or flag_id.is_empty():
		return
	ensure_npc(npc_id)
	var entry: Dictionary = _states[npc_id]
	var flags: Dictionary = {}
	var raw: Variant = entry.get("custom_flags", {})
	if typeof(raw) == TYPE_DICTIONARY:
		flags = (raw as Dictionary).duplicate(true)
	if flags.has(flag_id) and bool(flags[flag_id]) == value:
		return
	flags[flag_id] = value
	entry["custom_flags"] = flags
	_states[npc_id] = entry
	npc_state_changed.emit(npc_id, "custom_flags.%s" % flag_id, value)


func reset_for_tests(npc_id: String = "") -> void:
	if npc_id.is_empty():
		_states.clear()
		npc_states_cleared.emit()
		return
	_states.erase(npc_id)


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	return {"npcs": _states.duplicate(true)}


func load_save_data(data: Dictionary) -> void:
	_states.clear()
	if data == null or data.is_empty():
		npc_states_cleared.emit()
		return
	var raw: Variant = data.get("npcs", {})
	if typeof(raw) != TYPE_DICTIONARY:
		npc_states_cleared.emit()
		return
	for key in raw.keys():
		var npc_id := str(key)
		if npc_id.is_empty():
			continue
		var payload: Variant = raw[key]
		if typeof(payload) != TYPE_DICTIONARY:
			continue
		_states[npc_id] = _normalize_payload(payload as Dictionary)
	npc_states_cleared.emit()


func _default_payload(defaults: Dictionary = {}) -> Dictionary:
	return {
		"enabled": bool(defaults.get("enabled", true)),
		"met_player": bool(defaults.get("met_player", false)),
		"current_state": str(defaults.get("current_state", STATE_DEFAULT)).to_upper(),
		"current_location_id": str(defaults.get("current_location_id", "")),
		"current_schedule_id": str(defaults.get("current_schedule_id", "")),
		"last_dialogue_id": str(defaults.get("last_dialogue_id", "")),
		"custom_flags": {},
	}


func _normalize_payload(raw: Dictionary) -> Dictionary:
	var out := _default_payload()
	if raw.has("enabled"):
		out["enabled"] = bool(raw.get("enabled"))
	if raw.has("met_player"):
		out["met_player"] = bool(raw.get("met_player"))
	if raw.has("current_state"):
		var tag := str(raw.get("current_state")).strip_edges().to_upper()
		out["current_state"] = tag if not tag.is_empty() else STATE_DEFAULT
	if raw.has("current_location_id"):
		out["current_location_id"] = str(raw.get("current_location_id"))
	if raw.has("current_schedule_id"):
		out["current_schedule_id"] = str(raw.get("current_schedule_id"))
	if raw.has("last_dialogue_id"):
		out["last_dialogue_id"] = str(raw.get("last_dialogue_id"))
	var flags: Variant = raw.get("custom_flags", {})
	if typeof(flags) == TYPE_DICTIONARY:
		var cleaned: Dictionary = {}
		for fk in flags.keys():
			var flag_id := str(fk)
			if flag_id.is_empty():
				continue
			cleaned[flag_id] = bool(flags[fk])
		out["custom_flags"] = cleaned
	return out
