extends Node
## Persistent memory of dialogue conversations and choices.
## DialogueSystem events record automatically; ConditionSystem queries this API.
## Seen = started at least once. Completed = finished successfully (not cancelled).

signal dialogue_seen(dialogue_id: String)
signal dialogue_completed(dialogue_id: String, times_completed: int)
signal choice_selected(choice_id: String, count: int)
signal memory_cleared

## dialogue_id → Dictionary payload
var _dialogues: Dictionary = {}
## choice_id → Dictionary payload
var _choices: Dictionary = {}


func has_seen_dialogue(dialogue_id: String) -> bool:
	if dialogue_id.is_empty():
		return false
	var entry: Dictionary = _dialogues.get(dialogue_id, {})
	return bool(entry.get("seen", false)) or int(entry.get("times_completed", 0)) > 0


func has_completed_dialogue(dialogue_id: String) -> bool:
	return get_times_completed(dialogue_id) > 0


func get_times_completed(dialogue_id: String) -> int:
	if dialogue_id.is_empty():
		return 0
	var entry: Dictionary = _dialogues.get(dialogue_id, {})
	return maxi(int(entry.get("times_completed", 0)), 0)


func has_selected_choice(choice_id: String) -> bool:
	return get_choice_count(choice_id) > 0


func get_choice_count(choice_id: String) -> int:
	if choice_id.is_empty():
		return 0
	var entry: Dictionary = _choices.get(choice_id, {})
	return maxi(int(entry.get("count", 0)), 0)


func get_last_completed_unix(dialogue_id: String) -> float:
	if dialogue_id.is_empty():
		return 0.0
	var entry: Dictionary = _dialogues.get(dialogue_id, {})
	return float(entry.get("last_completed_unix", 0.0))


func get_last_completed_play_time(dialogue_id: String) -> float:
	if dialogue_id.is_empty():
		return 0.0
	var entry: Dictionary = _dialogues.get(dialogue_id, {})
	return float(entry.get("last_completed_play_time", 0.0))


## --- Recording API (called by DialogueSystem) ---

func record_dialogue_started(dialogue_id: String) -> void:
	if dialogue_id.is_empty():
		return
	var entry: Dictionary = _dialogues.get(dialogue_id, {}).duplicate(true)
	var first := not bool(entry.get("seen", false))
	entry["seen"] = true
	entry["times_started"] = int(entry.get("times_started", 0)) + 1
	entry["last_started_unix"] = _unix_now()
	_dialogues[dialogue_id] = entry
	if first:
		dialogue_seen.emit(dialogue_id)


func record_dialogue_completed(dialogue_id: String) -> void:
	if dialogue_id.is_empty():
		return
	# Completing implies seen (e.g. edge cases).
	var entry: Dictionary = _dialogues.get(dialogue_id, {}).duplicate(true)
	entry["seen"] = true
	var times := int(entry.get("times_completed", 0)) + 1
	entry["times_completed"] = times
	entry["last_completed_unix"] = _unix_now()
	entry["last_completed_play_time"] = _play_time_now()
	_dialogues[dialogue_id] = entry
	dialogue_completed.emit(dialogue_id, times)


func record_choice_selected(choice_id: String, dialogue_id: String = "") -> void:
	if choice_id.is_empty():
		return
	var entry: Dictionary = _choices.get(choice_id, {}).duplicate(true)
	var count := int(entry.get("count", 0)) + 1
	entry["count"] = count
	entry["last_selected_unix"] = _unix_now()
	if not dialogue_id.is_empty():
		entry["last_dialogue_id"] = dialogue_id
	_choices[choice_id] = entry
	choice_selected.emit(choice_id, count)


func reset_for_tests() -> void:
	_dialogues.clear()
	_choices.clear()
	memory_cleared.emit()


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	return {
		"dialogues": _dialogues.duplicate(true),
		"choices": _choices.duplicate(true),
	}


func load_save_data(data: Dictionary) -> void:
	_dialogues.clear()
	_choices.clear()
	if data == null or data.is_empty():
		memory_cleared.emit()
		return
	var dialogues: Variant = data.get("dialogues", {})
	if typeof(dialogues) == TYPE_DICTIONARY:
		for key in dialogues.keys():
			var dialogue_id := str(key)
			if dialogue_id.is_empty():
				continue
			var raw: Variant = dialogues[key]
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			_dialogues[dialogue_id] = (raw as Dictionary).duplicate(true)
	var choices: Variant = data.get("choices", {})
	if typeof(choices) == TYPE_DICTIONARY:
		for key in choices.keys():
			var choice_id := str(key)
			if choice_id.is_empty():
				continue
			var raw_c: Variant = choices[key]
			if typeof(raw_c) != TYPE_DICTIONARY:
				continue
			_choices[choice_id] = (raw_c as Dictionary).duplicate(true)
	memory_cleared.emit()


func _unix_now() -> float:
	return float(Time.get_unix_time_from_system())


func _play_time_now() -> float:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt != null and gt.has_method("get_total_play_time"):
		return float(gt.call("get_total_play_time"))
	return 0.0
