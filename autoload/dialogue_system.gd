extends Node
## Data-driven dialogue runner. Autoload — no NPC-specific logic.
## Linear: advance on dialogue_continue via next_dialogue_id.
## Branching: visible choices (↑/↓); confirm only when enable conditions pass.
## Gates → ConditionSystem. Effects → DialogueActionExecutor (never UI).
## Session: IDLE / ACTIVE / INTERRUPTED — interrupt ≠ completed; resume keeps once-guards.

signal dialogue_started(dialogue_id: String)
signal line_changed(def: Resource)
signal choice_selection_changed(index: int)
signal choice_confirmed(choice_id: String, next_dialogue_id: String)
signal dialogue_finished(dialogue_id: String)
signal dialogue_cancelled
signal dialogue_interrupted(reason: String)
signal dialogue_resumed(dialogue_id: String)

const DEFAULT_CATALOG_PATH := "res://resources/dialogue/default_catalog.tres"
const DEFAULT_NPC_CATALOG_PATH := "res://resources/npc/default_npc_catalog.tres"
const MAX_RESOLVE_HOPS: int = 12
const ActionExecutorScript = preload("res://scripts/dialogue/dialogue_action_executor.gd")

## Explicit conversation session states.
const SESSION_IDLE := "IDLE"
const SESSION_ACTIVE := "ACTIVE"
const SESSION_INTERRUPTED := "INTERRUPTED"

## interrupt_dialogue(reason) values.
const REASON_PLAYER_CANCEL := "PLAYER_CANCEL"
const REASON_NPC_UNAVAILABLE := "NPC_UNAVAILABLE"
const REASON_SCENE_UNLOAD := "SCENE_UNLOAD"
const REASON_SYSTEM_EVENT := "SYSTEM_EVENT"

@export_file("*.tres") var catalog_path: String = DEFAULT_CATALOG_PATH
@export_file("*.tres") var npc_catalog_path: String = DEFAULT_NPC_CATALOG_PATH

var _catalog: Resource
var _by_id: Dictionary = {}
## npc_id → NpcDefinition (static authoring; no Node refs).
var _npc_defs: Dictionary = {}
var _session_state: String = SESSION_IDLE
var _current: Resource
var _start_id: String = ""
var _current_line_id: String = ""
var _npc_id: String = ""
var _actor: Node
var _restore_control: bool = false
var _lines_shown: int = 0
var _choice_index: int = 0
var _interrupt_reason: String = ""
## Choice ids confirmed during this conversation (serializable).
var _choices_made: Array[String] = []
var _executor: RefCounted
## Per-conversation once-guards (enter / exit / choice). Cleared on start/cancel.
var _fired_enter: Dictionary = {}
var _fired_exit: Dictionary = {}
var _fired_choice: Dictionary = {}
var _actor_tree_exiting_connected: bool = false


func _ready() -> void:
	_executor = ActionExecutorScript.new()
	_load_catalog()
	_load_npc_catalog()
	set_process_unhandled_input(true)
	var save := get_node_or_null("/root/SaveSystem")
	if save != null and save.has_signal("load_completed"):
		if not save.load_completed.is_connected(_on_save_loaded):
			save.load_completed.connect(_on_save_loaded)


func _unhandled_input(event: InputEvent) -> void:
	if _session_state == SESSION_INTERRUPTED:
		if event.is_action_pressed("dialogue_cancel"):
			cancel_dialogue()
			get_viewport().set_input_as_handled()
		return
	if _session_state != SESSION_ACTIVE:
		return
	if event.is_action_pressed("dialogue_cancel"):
		interrupt_dialogue(REASON_PLAYER_CANCEL)
		get_viewport().set_input_as_handled()
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
	return _session_state == SESSION_ACTIVE


func is_interrupted() -> bool:
	return _session_state == SESSION_INTERRUPTED


func get_session_state() -> String:
	return _session_state


func get_interrupt_reason() -> String:
	return _interrupt_reason


func get_session_npc_id() -> String:
	return _npc_id


func get_session_start_id() -> String:
	return _start_id


func get_choices_made() -> Array[String]:
	return _choices_made.duplicate()


func can_resume() -> bool:
	if _session_state != SESSION_INTERRUPTED:
		return false
	if _current_line_id.is_empty() and _current == null:
		return false
	_ensure_index()
	var line_id := _current_line_id
	if line_id.is_empty() and _current != null:
		line_id = str(_current.get("id"))
	return not line_id.is_empty() and _by_id.has(line_id)


func get_current() -> Resource:
	return _current


func get_current_id() -> String:
	if _current != null:
		return str(_current.get("id"))
	return _current_line_id


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
	if _session_state != SESSION_ACTIVE or _current == null:
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
	if not choice_id.is_empty():
		_choices_made.append(choice_id)
	_memory_record_choice(choice_id)
	choice_confirmed.emit(choice_id, next_id)
	if next_id.is_empty():
		end_dialogue(true)
		return
	_goto_dialogue_id(next_id)


## Extension point: first entry whose ConditionData passes (null condition = always).
## entries: Array of ConditionalDialogue / Dictionary {dialogue_id, condition}.
## Prefer resolve_dialogue_for_npc / NpcDialogueRule for new authoring.
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


## Pick the best dialogue for an NPC by npc_id (catalog lookup).
## Rules: drop disabled / failing conditions → highest priority → lower index on ties.
func resolve_dialogue_for_npc(npc_id: String) -> String:
	if npc_id.is_empty():
		return ""
	_ensure_npc_index()
	var def: Resource = _npc_defs.get(npc_id, null)
	if def == null:
		return ""
	return resolve_dialogue_from_definition(def)


## Same priority resolve using an NpcDefinition resource directly (tests / scene defs).
func resolve_dialogue_from_definition(definition: Resource) -> String:
	if definition == null:
		return ""
	var fallback := ""
	if definition.has_method("get_fallback_dialogue_id"):
		fallback = str(definition.call("get_fallback_dialogue_id"))
	else:
		fallback = str(definition.get("fallback_dialogue_id"))
		if fallback.is_empty():
			fallback = str(definition.get("dialogue_id"))

	var rules: Array = []
	if "dialogue_rules" in definition:
		var raw_rules: Variant = definition.get("dialogue_rules")
		if typeof(raw_rules) == TYPE_ARRAY:
			rules = raw_rules

	if not rules.is_empty():
		var picked := _pick_best_dialogue_rule(rules)
		if not picked.is_empty():
			return picked
		return fallback

	# Legacy: first-match ConditionalDialogue list.
	if "conditional_dialogues" in definition:
		var legacy: Variant = definition.get("conditional_dialogues")
		if typeof(legacy) == TYPE_ARRAY and not (legacy as Array).is_empty():
			var gated := resolve_dialogue_id(legacy as Array)
			if not gated.is_empty():
				return gated
	return fallback


func register_npc_definition(definition: Resource) -> void:
	if definition == null:
		return
	var key := str(definition.get("npc_id"))
	if key.is_empty():
		return
	_npc_defs[key] = definition


func get_npc_definition(npc_id: String) -> Resource:
	_ensure_npc_index()
	return _npc_defs.get(npc_id, null)


func reload_npc_catalog() -> void:
	_npc_defs.clear()
	_load_npc_catalog()


func _pick_best_dialogue_rule(rules: Array) -> String:
	var cond_sys := get_node_or_null("/root/ConditionSystem")
	var best_id := ""
	var best_priority := -2147483648
	var best_index := 2147483647
	var found := false

	for i in rules.size():
		var rule: Variant = rules[i]
		if rule == null:
			continue
		if not bool(rule.get("enabled")):
			continue
		var dlg_id := str(rule.get("dialogue_id"))
		if dlg_id.is_empty():
			continue
		var conditions: Array = []
		var raw_c: Variant = rule.get("conditions")
		if typeof(raw_c) == TYPE_ARRAY:
			conditions = raw_c
		var require_all := true
		if "require_all" in rule:
			require_all = bool(rule.get("require_all"))
		if not _rule_conditions_pass(cond_sys, conditions, require_all):
			continue
		var priority := int(rule.get("priority"))
		# Highest priority wins; ties → lower authored index (deterministic).
		if not found or priority > best_priority or (priority == best_priority and i < best_index):
			found = true
			best_priority = priority
			best_index = i
			best_id = dlg_id
	return best_id


func _rule_conditions_pass(cond_sys: Node, conditions: Array, require_all: bool) -> bool:
	if conditions.is_empty():
		return true
	if cond_sys == null:
		return false
	if require_all:
		if cond_sys.has_method("evaluate_all"):
			return bool(cond_sys.call("evaluate_all", conditions))
		for entry in conditions:
			if entry == null:
				continue
			if not bool(cond_sys.call("evaluate", entry)):
				return false
		return true
	if cond_sys.has_method("evaluate_any"):
		return bool(cond_sys.call("evaluate_any", conditions))
	for entry in conditions:
		if entry == null:
			continue
		if bool(cond_sys.call("evaluate", entry)):
			return true
	return false


func _load_npc_catalog() -> void:
	_npc_defs.clear()
	if npc_catalog_path.is_empty():
		return
	var catalog: Resource = load(npc_catalog_path) as Resource
	if catalog == null:
		push_warning("DialogueSystem: could not load NPC catalog '%s'" % npc_catalog_path)
		return
	var entries: Variant = catalog.get("entries")
	if typeof(entries) != TYPE_ARRAY:
		return
	for entry in entries:
		register_npc_definition(entry)


func _ensure_npc_index() -> void:
	if not _npc_defs.is_empty():
		return
	_load_npc_catalog()


## Registers / replaces a definition at runtime (tests, optional local overrides).
func register_dialogue(def: Resource) -> void:
	if def == null:
		return
	var key := str(def.get("id"))
	if key.is_empty():
		return
	_by_id[key] = def


func start_dialogue(dialogue_id: String, actor: Node = null, npc_id: String = "") -> bool:
	if dialogue_id.is_empty():
		return false
	# Fresh start replaces any open / interrupted session (not completed).
	if _session_state == SESSION_ACTIVE or _session_state == SESSION_INTERRUPTED:
		cancel_dialogue()
	_ensure_index()
	var def: Resource = _by_id.get(dialogue_id, null)
	if def == null:
		push_warning("DialogueSystem: unknown dialogue_id '%s'" % dialogue_id)
		return false

	var resolved := _resolve_showable_line(def)
	if resolved == null:
		push_warning("DialogueSystem: no showable line for '%s'" % dialogue_id)
		return false

	_bind_actor(actor, npc_id)
	_start_id = dialogue_id
	_lines_shown = 0
	_choice_index = 0
	_interrupt_reason = ""
	_choices_made.clear()
	_fired_enter.clear()
	_fired_exit.clear()
	_fired_choice.clear()
	_session_state = SESSION_ACTIVE
	_lock_actor(true)
	_present_line(resolved)
	if _session_state != SESSION_ACTIVE:
		# Presented line redirected to an empty dead-end and ended.
		return false
	_memory_record_started(dialogue_id)
	dialogue_started.emit(dialogue_id)
	return true


## Starts from a Resource directly (also indexes it). Useful for one-off / tests.
func start_from_definition(def: Resource, actor: Node = null, npc_id: String = "") -> bool:
	if def == null:
		return false
	register_dialogue(def)
	return start_dialogue(str(def.get("id")), actor, npc_id)


func advance() -> void:
	if _session_state != SESSION_ACTIVE or _current == null:
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


## Pause conversation without completing. Keeps once-guards + line for resume.
func interrupt_dialogue(reason: String = REASON_SYSTEM_EVENT) -> bool:
	if _session_state != SESSION_ACTIVE:
		return false
	var tag := reason.strip_edges().to_upper()
	if tag.is_empty():
		tag = REASON_SYSTEM_EVENT
	_interrupt_reason = tag
	if _current != null:
		_current_line_id = str(_current.get("id"))
	_session_state = SESSION_INTERRUPTED
	_lock_actor(false)
	_unbind_actor_tree_signal()
	# Drop Node refs on unload / unavailable — keep serializable ids only.
	if tag == REASON_SCENE_UNLOAD or tag == REASON_NPC_UNAVAILABLE:
		_actor = null
	dialogue_interrupted.emit(tag)
	return true


## Resume from latest safe line. Re-present does not re-fire once-guards.
func resume_dialogue(actor: Node = null) -> bool:
	if _session_state != SESSION_INTERRUPTED:
		return false
	if not can_resume():
		cancel_dialogue()
		return false
	_ensure_index()
	var line_id := _current_line_id
	if line_id.is_empty() and _current != null:
		line_id = str(_current.get("id"))
	var def: Resource = _by_id.get(line_id, null)
	if def == null:
		cancel_dialogue()
		return false
	if actor != null:
		_bind_actor(actor, _npc_id)
	elif _actor == null or not is_instance_valid(_actor):
		# Need a live actor to restore control lock; without one, end safely.
		cancel_dialogue()
		return false
	else:
		_connect_actor_tree_exiting()
	_interrupt_reason = ""
	_session_state = SESSION_ACTIVE
	_lock_actor(true)
	_represent_current_line(def)
	dialogue_resumed.emit(_start_id)
	return true


## Abort without completing. Clears session; next talk uses contextual resolve.
func cancel_dialogue() -> void:
	if _session_state == SESSION_IDLE:
		return
	_lock_actor(false)
	_unbind_actor_tree_signal()
	_clear_session_runtime()
	dialogue_cancelled.emit()


func end_dialogue(completed: bool = true) -> void:
	## completed=true → finished; false → cancel_dialogue (never marks completed).
	if completed:
		if _session_state != SESSION_ACTIVE:
			return
		_fire_exit_actions(_current)
		var finished_id := _start_id
		_lock_actor(false)
		_unbind_actor_tree_signal()
		_clear_session_runtime()
		_memory_record_completed(finished_id)
		dialogue_finished.emit(finished_id)
		return
	cancel_dialogue()


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
	_current_line_id = str(def.get("id")) if def != null else ""
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


func _represent_current_line(def: Resource) -> void:
	## Resume path: same line, no lines_shown bump, once-guards already set.
	_current = def
	_current_line_id = str(def.get("id")) if def != null else ""
	_choice_index = clampi(_choice_index, 0, maxi(get_visible_choices().size() - 1, 0))
	if get_visible_choices().is_empty():
		_choice_index = 0
	else:
		_choice_index = clampi(_choice_index, 0, get_visible_choices().size() - 1)
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


func _bind_actor(actor: Node, npc_id: String = "") -> void:
	_unbind_actor_tree_signal()
	_actor = actor
	_npc_id = str(npc_id)
	if _npc_id.is_empty() and actor != null and is_instance_valid(actor) and actor.has_method("get_npc_id"):
		_npc_id = str(actor.call("get_npc_id"))
	_connect_actor_tree_exiting()


func _connect_actor_tree_exiting() -> void:
	_unbind_actor_tree_signal()
	if _actor == null or not is_instance_valid(_actor):
		return
	if not _actor.tree_exiting.is_connected(_on_actor_tree_exiting):
		_actor.tree_exiting.connect(_on_actor_tree_exiting)
	_actor_tree_exiting_connected = true


func _unbind_actor_tree_signal() -> void:
	if _actor != null and is_instance_valid(_actor) and _actor_tree_exiting_connected:
		if _actor.tree_exiting.is_connected(_on_actor_tree_exiting):
			_actor.tree_exiting.disconnect(_on_actor_tree_exiting)
	_actor_tree_exiting_connected = false


func _on_actor_tree_exiting() -> void:
	## Scene unload / free while talking — interrupt with ids only (no Node keep).
	if _session_state == SESSION_ACTIVE:
		interrupt_dialogue(REASON_SCENE_UNLOAD)


func _clear_session_runtime() -> void:
	_session_state = SESSION_IDLE
	_current = null
	_current_line_id = ""
	_choice_index = 0
	_actor = null
	_npc_id = ""
	_start_id = ""
	_interrupt_reason = ""
	_choices_made.clear()
	_fired_enter.clear()
	_fired_exit.clear()
	_fired_choice.clear()
	_lines_shown = 0


func _on_save_loaded(_path: String = "") -> void:
	## Active/interrupted conversations are session-only — not restored from disk.
	if _session_state != SESSION_IDLE:
		cancel_dialogue()


func notify_npc_unavailable(npc_id: String) -> void:
	## POI/NPC systems call when a speaker leaves; interrupt if that conversation is open.
	if npc_id.is_empty() or _npc_id != npc_id:
		return
	if _session_state == SESSION_ACTIVE:
		interrupt_dialogue(REASON_NPC_UNAVAILABLE)


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
