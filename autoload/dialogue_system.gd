extends Node
## Data-driven linear dialogue runner. Autoload — no NPC-specific logic.
## Looks up DialogueDefinition by id; advances on dialogue_continue.
## Future: conditions, choices, flags, quests can hook start/advance without rewriting NPCs.

signal dialogue_started(dialogue_id: String)
signal line_changed(def: Resource)
signal dialogue_finished(dialogue_id: String)
signal dialogue_cancelled

const DEFAULT_CATALOG_PATH := "res://resources/dialogue/default_catalog.tres"

@export_file("*.tres") var catalog_path: String = DEFAULT_CATALOG_PATH

var _catalog: Resource
var _by_id: Dictionary = {}
var _active: bool = false
var _current: Resource
var _start_id: String = ""
var _actor: Node
var _restore_control: bool = false
var _lines_shown: int = 0


func _ready() -> void:
	_load_catalog()
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event.is_action_pressed("dialogue_continue"):
		advance()
		get_viewport().set_input_as_handled()


func is_active() -> bool:
	return _active


func get_current() -> Resource:
	return _current


func get_current_id() -> String:
	if _current == null:
		return ""
	return str(_current.get("id"))


func get_current_speaker() -> String:
	if _current == null:
		return ""
	return str(_current.get("speaker_name"))


func get_current_text() -> String:
	if _current == null:
		return ""
	return str(_current.get("text"))


func get_lines_shown() -> int:
	return _lines_shown


func has_dialogue(dialogue_id: String) -> bool:
	_ensure_index()
	return _by_id.has(dialogue_id)


func get_dialogue(dialogue_id: String) -> Resource:
	_ensure_index()
	return _by_id.get(dialogue_id, null)


## Extension point: first entry whose ConditionData passes (null condition = always).
## entries: Array of ConditionalDialogue / Dictionary {dialogue_id, condition}.
func resolve_dialogue_id(entries: Array) -> String:
	var cond_sys := get_node_or_null("/root/ConditionSystem")
	for entry in entries:
		if entry == null:
			continue
		var dlg_id := ""
		var condition: Resource = null
		if typeof(entry) == TYPE_DICTIONARY:
			dlg_id = str(entry.get("dialogue_id", ""))
			var raw: Variant = entry.get("condition", null)
			if raw is Resource:
				condition = raw
		elif entry is Resource:
			dlg_id = str(entry.get("dialogue_id"))
			var raw_c: Variant = entry.get("condition")
			if raw_c is Resource:
				condition = raw_c
		if dlg_id.is_empty():
			continue
		if condition == null:
			return dlg_id
		if cond_sys != null and cond_sys.has_method("evaluate"):
			if bool(cond_sys.call("evaluate", condition)):
				return dlg_id
		# Without ConditionSystem, only ungated entries resolve.
	return ""


## Registers / replaces a definition at runtime (tests, optional local overrides).
func register_dialogue(def: Resource) -> void:
	if def == null:
		return
	var key := str(def.get("id"))
	if key.is_empty():
		return
	_by_id[key] = def


func start_dialogue(dialogue_id: String, actor: Node = null) -> bool:
	if dialogue_id.is_empty():
		return false
	if _active:
		end_dialogue(false)
	_ensure_index()
	var def: Resource = _by_id.get(dialogue_id, null)
	if def == null:
		push_warning("DialogueSystem: unknown dialogue_id '%s'" % dialogue_id)
		return false

	_actor = actor
	_start_id = dialogue_id
	_lines_shown = 0
	_active = true
	_lock_actor(true)
	_show_line(def)
	dialogue_started.emit(dialogue_id)
	return true


## Starts from a Resource directly (also indexes it). Useful for one-off / tests.
func start_from_definition(def: Resource, actor: Node = null) -> bool:
	if def == null:
		return false
	register_dialogue(def)
	return start_dialogue(str(def.get("id")), actor)


func advance() -> void:
	if not _active or _current == null:
		return
	var next_id := str(_current.get("next_dialogue_id"))
	if next_id.is_empty():
		end_dialogue(true)
		return
	_ensure_index()
	var nxt: Resource = _by_id.get(next_id, null)
	if nxt == null:
		push_warning("DialogueSystem: missing next_dialogue_id '%s'" % next_id)
		end_dialogue(true)
		return
	_show_line(nxt)


func end_dialogue(completed: bool = true) -> void:
	if not _active:
		return
	var finished_id := _start_id
	_active = false
	_current = null
	_lock_actor(false)
	_actor = null
	_start_id = ""
	if completed:
		dialogue_finished.emit(finished_id)
	else:
		dialogue_cancelled.emit()


func reload_catalog() -> void:
	_by_id.clear()
	_load_catalog()


func _show_line(def: Resource) -> void:
	_current = def
	_lines_shown += 1
	# Reserved hooks: required_flags / set_flags_on_show / choice_ids — unused for now.
	line_changed.emit(def)


func _lock_actor(lock: bool) -> void:
	if _actor == null or not is_instance_valid(_actor):
		return
	if lock:
		_restore_control = true
		if _actor.has_method("is_control_enabled"):
			_restore_control = bool(_actor.call("is_control_enabled"))
		if _actor.has_method("set_control_enabled"):
			_actor.call("set_control_enabled", false)
		# Ensure detector is off even if actor API differs.
		if _actor.has_method("get_interaction_detector"):
			var det: Node = _actor.call("get_interaction_detector")
			if det != null and det.has_method("set_detector_active"):
				det.call("set_detector_active", false)
	else:
		if _restore_control and _actor.has_method("set_control_enabled"):
			_actor.call("set_control_enabled", true)
		_restore_control = false


func _ensure_index() -> void:
	if not _by_id.is_empty():
		return
	_load_catalog()


func _load_catalog() -> void:
	_catalog = null
	if not catalog_path.is_empty() and ResourceLoader.exists(catalog_path):
		_catalog = load(catalog_path)
	if _catalog != null and _catalog.has_method("build_index"):
		var built: Dictionary = _catalog.call("build_index")
		for key in built.keys():
			_by_id[str(key)] = built[key]
	elif _catalog != null and "entries" in _catalog:
		for entry in _catalog.entries:
			if entry == null:
				continue
			var key := str(entry.get("id"))
			if not key.is_empty():
				_by_id[key] = entry
