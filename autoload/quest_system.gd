extends Node
## Minimal quest runner. Stores state by quest_id. No quest log UI / branching / fail states.
## Hooks: dialogue_finished → may start a quest; ViewpointTerminal asks try_turn_in.

signal quest_started(quest_id: String)
signal quest_completed(quest_id: String)
signal quest_state_changed(quest_id: String, state_name: String)
signal turn_in_failed(quest_id: String, reason: String)

const DEFAULT_CATALOG_PATH := "res://resources/quest/default_quest_catalog.tres"
const QuestDataScript = preload("res://scripts/quest/quest_data.gd")

@export_file("*.tres") var catalog_path: String = DEFAULT_CATALOG_PATH

var _by_id: Dictionary = {}
## quest_id → QuestData.State int
var _states: Dictionary = {}


func _ready() -> void:
	_load_catalog()
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg != null and dlg.has_signal("dialogue_finished"):
		if not dlg.dialogue_finished.is_connected(_on_dialogue_finished):
			dlg.dialogue_finished.connect(_on_dialogue_finished)


func has_quest(quest_id: String) -> bool:
	_ensure_index()
	return _by_id.has(quest_id)


func get_quest(quest_id: String) -> Resource:
	_ensure_index()
	return _by_id.get(quest_id, null)


func get_state(quest_id: String) -> int:
	if quest_id.is_empty():
		return QuestDataScript.State.INACTIVE
	return int(_states.get(quest_id, QuestDataScript.State.INACTIVE))


func get_state_name(quest_id: String) -> String:
	return QuestDataScript.state_name(get_state(quest_id) as QuestDataScript.State)


func is_inactive(quest_id: String) -> bool:
	return get_state(quest_id) == QuestDataScript.State.INACTIVE


func is_active(quest_id: String) -> bool:
	return get_state(quest_id) == QuestDataScript.State.ACTIVE


func is_completed(quest_id: String) -> bool:
	return get_state(quest_id) == QuestDataScript.State.COMPLETED


func start_quest(quest_id: String) -> bool:
	if quest_id.is_empty() or not has_quest(quest_id):
		return false
	if not is_inactive(quest_id):
		return false
	_set_state(quest_id, QuestDataScript.State.ACTIVE)
	quest_started.emit(quest_id)
	print("QuestSystem: started '%s'" % quest_id)
	return true


func complete_quest(quest_id: String) -> bool:
	if quest_id.is_empty() or not has_quest(quest_id):
		return false
	if is_completed(quest_id):
		return false
	if not is_active(quest_id):
		return false
	_set_state(quest_id, QuestDataScript.State.COMPLETED)
	quest_completed.emit(quest_id)
	print("QuestSystem: completed '%s'" % quest_id)
	return true


## Resolve which dialogue an NPC should open for a linked quest.
func get_dialogue_for_quest(quest_id: String, fallback_dialogue_id: String = "") -> String:
	var data: Resource = get_quest(quest_id)
	if data == null:
		return fallback_dialogue_id
	match get_state(quest_id):
		QuestDataScript.State.ACTIVE:
			var active_id := str(data.get("active_dialogue_id"))
			return active_id if not active_id.is_empty() else fallback_dialogue_id
		QuestDataScript.State.COMPLETED:
			var done_id := str(data.get("completed_dialogue_id"))
			return done_id if not done_id.is_empty() else fallback_dialogue_id
		_:
			var start_id := str(data.get("start_dialogue_id"))
			return start_id if not start_id.is_empty() else fallback_dialogue_id


func find_quest_for_giver(npc_id: String) -> String:
	_ensure_index()
	if npc_id.is_empty():
		return ""
	for key in _by_id.keys():
		var data: Resource = _by_id[key]
		if data != null and str(data.get("giver_npc_id")) == npc_id:
			return str(key)
	return ""


func has_required_items(quest_id: String) -> bool:
	var inv := get_node_or_null("/root/InventorySystem")
	if inv == null or not inv.has_method("has_item"):
		return false
	var data: Resource = get_quest(quest_id)
	if data == null:
		return false
	var reqs: Array = data.call("get_requirements") if data.has_method("get_requirements") else []
	for req in reqs:
		var item_id := str(req.get("item_id", ""))
		var amount := int(req.get("amount", 0))
		if not bool(inv.call("has_item", item_id, amount)):
			return false
	return true


## Consumes required items once. Returns false if missing / already completed / inactive.
func try_consume_requirements(quest_id: String) -> bool:
	if not is_active(quest_id):
		return false
	if not has_required_items(quest_id):
		return false
	var inv := get_node_or_null("/root/InventorySystem")
	if inv == null or not inv.has_method("remove_item"):
		return false
	var data: Resource = get_quest(quest_id)
	var reqs: Array = data.call("get_requirements") if data.has_method("get_requirements") else []
	for req in reqs:
		var item_id := str(req.get("item_id", ""))
		var amount := int(req.get("amount", 0))
		var removed: int = int(inv.call("remove_item", item_id, amount))
		if removed < amount:
			# Should not happen after has_required_items; bail safely.
			return false
	return true


## Terminal turn-in: consume + complete. Idempotent if already completed.
func try_turn_in(quest_id: String) -> bool:
	if quest_id.is_empty():
		turn_in_failed.emit(quest_id, "empty_id")
		return false
	if is_completed(quest_id):
		turn_in_failed.emit(quest_id, "already_completed")
		return false
	if not is_active(quest_id):
		turn_in_failed.emit(quest_id, "not_active")
		return false
	if not has_required_items(quest_id):
		turn_in_failed.emit(quest_id, "missing_items")
		return false
	if not try_consume_requirements(quest_id):
		turn_in_failed.emit(quest_id, "consume_failed")
		return false
	return complete_quest(quest_id)


func reset_quest(quest_id: String) -> void:
	## Test helper.
	if quest_id.is_empty():
		return
	_states[quest_id] = QuestDataScript.State.INACTIVE
	quest_state_changed.emit(quest_id, "INACTIVE")


func reset_all() -> void:
	_states.clear()


func register_quest(data: Resource) -> void:
	if data == null:
		return
	var key := str(data.get("quest_id"))
	if key.is_empty():
		return
	_by_id[key] = data


func _on_dialogue_finished(dialogue_id: String) -> void:
	_ensure_index()
	for key in _by_id.keys():
		var data: Resource = _by_id[key]
		if data == null:
			continue
		if str(data.get("start_dialogue_id")) == dialogue_id and is_inactive(str(key)):
			start_quest(str(key))
			return


func _set_state(quest_id: String, state: int) -> void:
	_states[quest_id] = state
	quest_state_changed.emit(quest_id, get_state_name(quest_id))


func _ensure_index() -> void:
	if not _by_id.is_empty():
		return
	_load_catalog()


func _load_catalog() -> void:
	var catalog: Resource = null
	if not catalog_path.is_empty() and ResourceLoader.exists(catalog_path):
		catalog = load(catalog_path)
	if catalog != null and catalog.has_method("build_index"):
		var built: Dictionary = catalog.call("build_index")
		for key in built.keys():
			_by_id[str(key)] = built[key]
	elif catalog != null and "entries" in catalog:
		for entry in catalog.entries:
			if entry == null:
				continue
			var key := str(entry.get("quest_id"))
			if not key.is_empty():
				_by_id[key] = entry
