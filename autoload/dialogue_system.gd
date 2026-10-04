extends Node
## Data-driven dialogue runner. Autoload — no NPC-specific logic.
## Linear: advance on dialogue_continue via next_dialogue_id.
## Branching: visible choices (↑/↓); confirm only when enable conditions pass.
## Gates → ConditionSystem. Effects → DialogueActionExecutor (never UI).

signal dialogue_started(dialogue_id: String)
signal line_changed(def: Resource)
signal choice_selection_changed(index: int)
signal choice_confirmed(choice_id: String, next_dialogue_id: String)
signal dialogue_finished(dialogue_id: String)
signal dialogue_cancelled

const DEFAULT_CATALOG_PATH := "res://resources/dialogue/default_catalog.tres"
const MAX_RESOLVE_HOPS: int = 12
const ActionExecutorScript = preload("res://scripts/dialogue/dialogue_action_executor.gd")

@export_file("*.tres") var catalog_path: String = DEFAULT_CATALOG_PATH

var _catalog: Resource
var _by_id: Dictionary = {}
var _active: bool = false
var _current: Resource
var _start_id: String = ""
var _actor: Node
var _restore_control: bool = false
var _lines_shown: int = 0
var _choice_index: int = 0
var _executor: RefCounted
## Per-conversation once-guards (enter / exit / choice). Cleared on start.
var _fired_enter: Dictionary = {}
var _fired_exit: Dictionary = {}
var _fired_choice: Dictionary = {}


func _ready() -> void:
	_executor = ActionExecutorScript.new()
	_load_catalog()
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if not get_visible_choices().is_empty():
		if event.is_action_pressed("ui_up"):
			select_previous_choice()
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("ui_down"):
			select_next_choice()
			get_viewport().set_input_as_handled()
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


func get_choice_index() -> int:
	return _choice_index


func has_dialogue(dialogue_id: String) -> bool:
	_ensure_index()
	return _by_id.has(dialogue_id)


func get_dialogue(dialogue_id: String) -> Resource:
	_ensure_index()
	return _by_id.get(dialogue_id, null)


## Choices that pass show_conditions (may still be unselectable).
func get_visible_choices() -> Array:
	if _current == null:
		return []
	var raw: Variant = _current.get("choices")
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for entry in raw:
		if entry == null:
			continue
		if not _choice_passes_show(entry):
			continue
		out.append(entry)
	return out


## Visible choices that can be confirmed (enable_conditions pass).
func get_available_choices() -> Array:
	var out: Array = []
	for entry in get_visible_choices():
		if _choice_passes_enable(entry):
			out.append(entry)
	return out


func has_available_choices() -> bool:
	return not get_available_choices().is_empty()


func has_visible_choices() -> bool:
	return not get_visible_choices().is_empty()


func is_choice_enabled(choice: Variant) -> bool:
	if choice == null:
		return false
	return _choice_passes_enable(choice)


func is_selected_choice_enabled() -> bool:
	var visible := get_visible_choices()
	if visible.is_empty():
		return false
	var idx := clampi(_choice_index, 0, visible.size() - 1)
	return _choice_passes_enable(visible[idx])


func select_next_choice() -> void:
	var choices := get_visible_choices()
	if choices.is_empty():
		return
	_choice_index = (_choice_index + 1) % choices.size()
	choice_selection_changed.emit(_choice_index)


func select_previous_choice() -> void:
	var choices := get_visible_choices()
	if choices.is_empty():
		return
	_choice_index = (_choice_index - 1 + choices.size()) % choices.size()
	choice_selection_changed.emit(_choice_index)


func set_choice_index(index: int) -> void:
	var choices := get_visible_choices()
	if choices.is_empty():
		_choice_index = 0
		return
	_choice_index = clampi(index, 0, choices.size() - 1)
	choice_selection_changed.emit(_choice_index)


## Confirms the highlighted choice when it is enabled; no-op if disabled.
func confirm_choice() -> void:
	if not _active or _current == null:
		return
	var visible := get_visible_choices()
	if visible.is_empty():
		return
	_choice_index = clampi(_choice_index, 0, visible.size() - 1)
	var choice: Variant = visible[_choice_index]
	if not _choice_passes_enable(choice):
		return
	var choice_id := str(choice.get("id"))
	var next_id := str(choice.get("next_dialogue_id"))
	_fire_choice_actions(choice)
	_fire_exit_actions(_current)
	_memory_record_choice(choice_id)
	choice_confirmed.emit(choice_id, next_id)
	if next_id.is_empty():
		end_dialogue(true)
		return
	_goto_dialogue_id(next_id)


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

	var resolved := _resolve_showable_line(def)
	if resolved == null:
		push_warning("DialogueSystem: no showable line for '%s'" % dialogue_id)
		return false

	_actor = actor
	_start_id = dialogue_id
	_lines_shown = 0
	_choice_index = 0
	_fired_enter.clear()
	_fired_exit.clear()
	_fired_choice.clear()
	_active = true
	_lock_actor(true)
	_present_line(resolved)
	if not _active:
		# Presented line redirected to an empty dead-end and ended.
		return false
	_memory_record_started(dialogue_id)
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
	# Selectable choices: continue confirms the current highlight.
	if has_available_choices():
		confirm_choice()
		return
	# Visible but all disabled → leave the choice UI via next / end (safe escape).
	if has_visible_choices():
		_leave_choice_line_without_selection()
		return
	var next_id := str(_current.get("next_dialogue_id"))
	if next_id.is_empty():
		end_dialogue(true)
		return
	_fire_exit_actions(_current)
	_goto_dialogue_id(next_id)


func end_dialogue(completed: bool = true) -> void:
	if not _active:
		return
	if completed:
		_fire_exit_actions(_current)
	var finished_id := _start_id
	_active = false
	_current = null
	_choice_index = 0
	_lock_actor(false)
	_actor = null
	_start_id = ""
	_fired_enter.clear()
	_fired_exit.clear()
	_fired_choice.clear()
	if completed:
		# Interrupted / cancelled conversations must NOT count as completed.
		_memory_record_completed(finished_id)
		dialogue_finished.emit(finished_id)
	else:
		dialogue_cancelled.emit()


func reload_catalog() -> void:
	_by_id.clear()
	_load_catalog()


func _leave_choice_line_without_selection() -> void:
	## All visible choices are disabled: prefer line fallback, then next, then end.
	_fire_exit_actions(_current)
	var fallback := str(_current.get("fallback_dialogue_id")) if _current != null else ""
	if not fallback.is_empty():
		_goto_dialogue_id(fallback)
		return
	var next_id := str(_current.get("next_dialogue_id")) if _current != null else ""
	if not next_id.is_empty():
		_goto_dialogue_id(next_id)
		return
	end_dialogue(true)


func _goto_dialogue_id(dialogue_id: String) -> void:
	if dialogue_id.is_empty():
		end_dialogue(true)
		return
	_ensure_index()
	var nxt: Resource = _by_id.get(dialogue_id, null)
	if nxt == null:
		push_warning("DialogueSystem: missing dialogue_id '%s'" % dialogue_id)
		end_dialogue(true)
		return
	var resolved := _resolve_showable_line(nxt)
	if resolved == null:
		end_dialogue(true)
		return
	_present_line(resolved)


func _present_line(def: Resource) -> void:
	_current = def
	_lines_shown += 1
	_choice_index = 0

	# Authored choices but none visible → fallback or end (avoid empty dead-end UI).
	if _has_authored_choices(def) and get_visible_choices().is_empty():
		var fallback := str(def.get("fallback_dialogue_id"))
		var self_id := str(def.get("id"))
		# Do not fire enter on a line that never actually displays.
		if not fallback.is_empty() and fallback != self_id:
			_goto_dialogue_id(fallback)
			return
		end_dialogue(true)
		return

	_fire_enter_actions(def)
	_choice_index = _first_selectable_visible_index()
	line_changed.emit(def)
	if has_visible_choices():
		choice_selection_changed.emit(_choice_index)


func _fire_enter_actions(def: Resource) -> void:
	if def == null or _executor == null:
		return
	var line_id := str(def.get("id"))
	if line_id.is_empty() or _fired_enter.has(line_id):
		return
	_fired_enter[line_id] = true
	_executor.call("execute_all", _read_actions(def, "on_enter_actions"))


func _fire_exit_actions(def: Resource) -> void:
	if def == null or _executor == null:
		return
	var line_id := str(def.get("id"))
	if line_id.is_empty() or _fired_exit.has(line_id):
		return
	_fired_exit[line_id] = true
	_executor.call("execute_all", _read_actions(def, "on_exit_actions"))


func _fire_choice_actions(choice: Variant) -> void:
	if choice == null or _executor == null or _current == null:
		return
	var line_id := str(_current.get("id"))
	var choice_id := str(choice.get("id"))
	var key := "%s::%s" % [line_id, choice_id]
	if _fired_choice.has(key):
		return
	_fired_choice[key] = true
	_executor.call("execute_all", _read_actions(choice, "on_choose_actions"))


func _read_actions(owner: Variant, property: String) -> Array:
	if owner == null or not (property in owner):
		return []
	var raw: Variant = owner.get(property)
	if typeof(raw) != TYPE_ARRAY:
		return []
	return raw


func _memory_record_started(dialogue_id: String) -> void:
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory != null and memory.has_method("record_dialogue_started"):
		memory.call("record_dialogue_started", dialogue_id)


func _memory_record_completed(dialogue_id: String) -> void:
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory != null and memory.has_method("record_dialogue_completed"):
		memory.call("record_dialogue_completed", dialogue_id)


func _memory_record_choice(choice_id: String) -> void:
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory == null or not memory.has_method("record_choice_selected"):
		return
	memory.call("record_choice_selected", choice_id, _start_id)


func _first_selectable_visible_index() -> int:
	var visible := get_visible_choices()
	for i in range(visible.size()):
		if _choice_passes_enable(visible[i]):
			return i
	return 0


func _has_authored_choices(def: Resource) -> bool:
	if def == null:
		return false
	var raw: Variant = def.get("choices")
	return typeof(raw) == TYPE_ARRAY and not raw.is_empty()


func _resolve_showable_line(def: Resource) -> Resource:
	## Follow fallback_dialogue_id while show_conditions fail. Guards loops / hops.
	var current := def
	var seen: Dictionary = {}
	var hops := 0
	while current != null and hops < MAX_RESOLVE_HOPS:
		hops += 1
		var key := str(current.get("id"))
		if key.is_empty():
			return null
		if seen.has(key):
			push_warning("DialogueSystem: show_conditions fallback loop at '%s'" % key)
			return null
		seen[key] = true
		if _line_passes_show(current):
			return current
		var fallback := str(current.get("fallback_dialogue_id"))
		if fallback.is_empty():
			return null
		_ensure_index()
		current = _by_id.get(fallback, null)
		if current == null:
			push_warning("DialogueSystem: missing fallback_dialogue_id '%s'" % fallback)
			return null
	push_warning("DialogueSystem: show_conditions resolve exceeded hop limit")
	return null


func _line_passes_show(def: Resource) -> bool:
	if def == null:
		return false
	var conditions: Array = _read_condition_list(def, "show_conditions")
	var require_all := bool(def.get("show_require_all")) if "show_require_all" in def else true
	return _passes_conditions(conditions, require_all)


func _choice_passes_show(choice: Variant) -> bool:
	if choice == null:
		return false
	if "enabled" in choice and not bool(choice.get("enabled")):
		return false
	var conditions: Array = _read_condition_list(choice, "show_conditions")
	# Legacy field from earlier choice gating.
	if conditions.is_empty():
		conditions = _read_condition_list(choice, "conditions")
	var require_all := true
	if "show_require_all" in choice:
		require_all = bool(choice.get("show_require_all"))
	return _passes_conditions(conditions, require_all)


func _choice_passes_enable(choice: Variant) -> bool:
	if choice == null:
		return false
	if not _choice_passes_show(choice):
		return false
	var conditions: Array = _read_condition_list(choice, "enable_conditions")
	var require_all := true
	if "enable_require_all" in choice:
		require_all = bool(choice.get("enable_require_all"))
	return _passes_conditions(conditions, require_all)


func _read_condition_list(owner: Variant, property: String) -> Array:
	if owner == null or not (property in owner):
		return []
	var raw: Variant = owner.get(property)
	if typeof(raw) != TYPE_ARRAY:
		return []
	return raw


func _passes_conditions(conditions: Array, require_all: bool) -> bool:
	## Empty list always passes. Non-empty lists require ConditionSystem.
	if conditions.is_empty():
		return true
	var cond_sys := get_node_or_null("/root/ConditionSystem")
	if cond_sys == null:
		return false
	if require_all:
		if cond_sys.has_method("evaluate_all"):
			return bool(cond_sys.call("evaluate_all", conditions))
		return false
	if cond_sys.has_method("evaluate_any"):
		return bool(cond_sys.call("evaluate_any", conditions))
	return false


func _lock_actor(lock: bool) -> void:
	if _actor == null or not is_instance_valid(_actor):
		return
	if lock:
		_restore_control = true
		if _actor.has_method("is_control_enabled"):
			_restore_control = bool(_actor.call("is_control_enabled"))
		if _actor.has_method("set_control_enabled"):
			_actor.call("set_control_enabled", false)
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
