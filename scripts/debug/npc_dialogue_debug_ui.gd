extends CanvasLayer
class_name NpcDialogueDebugUI
## Dev-only NPC / dialogue inspector. Sandbox-only — not ship gameplay.
## Reads autoloads; mutates test state via public APIs. No dialogue tree editor.

const ValidatorScript = preload("res://scripts/debug/npc_dialogue_content_validator.gd")

const NPC_STATES := ["DEFAULT", "BUSY", "UNAVAILABLE", "TRAVELING", "QUEST_RELATED"]
const DEBUG_FLAG_ID := "debug.npc_dialogue_panel"

enum FocusPane { NPCS, DIALOGUES, MUTATORS }

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/TitleLabel
@onready var _body: Label = $Root/Panel/Margin/VBox/Scroll/BodyLabel
@onready var _status: Label = $Root/Panel/Margin/VBox/StatusLabel
@onready var _hint: Label = $Root/Panel/Margin/VBox/HintLabel

var _visible_panel: bool = false
var _npc_ids: PackedStringArray = []
var _dialogue_ids: PackedStringArray = []
var _npc_index: int = 0
var _dialogue_index: int = 0
var _focus: FocusPane = FocusPane.NPCS
var _validation_report: String = ""
var _validation_result: Dictionary = {}
var _status_text: String = ""


func _ready() -> void:
	layer = 94
	add_to_group("npc_dialogue_debug_ui")
	_set_panel_visible(false)
	set_process_unhandled_input(true)


func toggle() -> void:
	_set_panel_visible(not _visible_panel)


func open() -> void:
	_set_panel_visible(true)


func close() -> void:
	_set_panel_visible(false)


func is_panel_visible() -> bool:
	return _visible_panel


func get_selected_npc_id() -> String:
	if _npc_ids.is_empty():
		return ""
	return str(_npc_ids[clampi(_npc_index, 0, _npc_ids.size() - 1)])


func select_npc_id(npc_id: String) -> bool:
	_npc_ids = _collect_npc_ids()
	var idx := _npc_ids.find(npc_id)
	if idx < 0:
		return false
	_npc_index = idx
	_dialogue_ids = _dialogues_for_selected_npc()
	_dialogue_index = 0
	_refresh()
	return true


func select_dialogue_id(dialogue_id: String) -> bool:
	_dialogue_ids = _dialogues_for_selected_npc()
	var idx := _dialogue_ids.find(dialogue_id)
	if idx < 0:
		# Allow starting any catalog id even if not listed on the NPC.
		var dlg := get_node_or_null("/root/DialogueSystem")
		if dlg != null and dlg.has_method("has_dialogue") and bool(dlg.call("has_dialogue", dialogue_id)):
			var expanded := PackedStringArray()
			for existing in _dialogue_ids:
				expanded.append(str(existing))
			expanded.append(dialogue_id)
			_dialogue_ids = expanded
			_dialogue_index = _dialogue_ids.size() - 1
			_refresh()
			return true
		return false
	_dialogue_index = idx
	_refresh()
	return true


func get_selected_dialogue_id() -> String:
	if _dialogue_ids.is_empty():
		return ""
	return str(_dialogue_ids[clampi(_dialogue_index, 0, _dialogue_ids.size() - 1)])


func get_validation_report_text() -> String:
	return _validation_report


func get_last_validation_result() -> Dictionary:
	return _validation_result.duplicate(true)


func run_validation() -> Dictionary:
	var validator: RefCounted = ValidatorScript.new()
	_validation_result = validator.call("validate")
	_validation_report = str(validator.call("format_report", _validation_result))
	_status_text = "Validation: %s (%d issues)" % [
		"OK" if bool(_validation_result.get("ok", false)) else "FAIL",
		int(_validation_result.get("issue_count", 0)),
	]
	_refresh()
	return _validation_result.duplicate(true)


func clear_validation_report() -> void:
	_validation_report = ""
	_validation_result = {}
	_status_text = "Validation report cleared"
	_refresh()


func reset_npc_dialogue_test_data() -> void:
	## Clears NPC/dialogue test state only — not journey/inventory/vehicle/full save.
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg != null and dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	var bark := get_node_or_null("/root/BarkSystem")
	if bark != null and bark.has_method("reset_for_tests"):
		bark.call("reset_for_tests")
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null and ns.has_method("reset_for_tests"):
		ns.call("reset_for_tests")
	var rel := get_node_or_null("/root/RelationshipSystem")
	if rel != null and rel.has_method("reset_for_tests"):
		rel.call("reset_for_tests")
	var schedule := get_node_or_null("/root/NpcScheduleSystem")
	if schedule != null and schedule.has_method("reset_for_tests"):
		schedule.call("reset_for_tests")
	var travel := get_node_or_null("/root/NpcTravelSystem")
	if travel != null and travel.has_method("reset_for_tests"):
		travel.call("reset_for_tests")
	# Linked quests only (not a full save wipe).
	var quests := get_node_or_null("/root/QuestSystem")
	var npc_catalog_npc_ids := _collect_npc_ids()
	if quests != null:
		for npc_id in npc_catalog_npc_ids:
			var def: Resource = null
			if dlg != null and dlg.has_method("get_npc_definition"):
				def = dlg.call("get_npc_definition", npc_id)
			if def == null:
				continue
			var qid := str(def.get("linked_quest_id"))
			if not qid.is_empty() and quests.has_method("reset_quest"):
				quests.call("reset_quest", qid)
	var flags := get_node_or_null("/root/GameFlags")
	if flags != null and flags.has_method("get_all_flags") and flags.has_method("clear_flag"):
		var all: Dictionary = flags.call("get_all_flags")
		for key in all.keys():
			var flag_id := str(key)
			if flag_id.begins_with("npc.") or flag_id.begins_with("debug."):
				flags.call("clear_flag", flag_id)
	_status_text = "Reset NPC/dialogue test data (save/journey/inventory untouched)"
	_refresh()


func start_selected_dialogue() -> bool:
	var dialogue_id := get_selected_dialogue_id()
	if dialogue_id.is_empty():
		_status_text = "No dialogue selected"
		_refresh()
		return false
	return start_dialogue_id(dialogue_id)


func start_dialogue_id(dialogue_id: String) -> bool:
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg == null or not dlg.has_method("start_dialogue"):
		_status_text = "DialogueSystem missing"
		_refresh()
		return false
	var npc_id := get_selected_npc_id()
	var actor := _find_npc_actor(npc_id)
	var ok := bool(dlg.call("start_dialogue", dialogue_id, actor, npc_id))
	_status_text = ("Started '%s'" % dialogue_id) if ok else ("Failed to start '%s'" % dialogue_id)
	_refresh()
	return ok


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("npc_dialogue_debug_toggle"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not _visible_panel:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		match key:
			KEY_TAB:
				_cycle_focus(1 if not event.shift_pressed else -1)
				get_viewport().set_input_as_handled()
			KEY_UP:
				_move_selection(-1)
				get_viewport().set_input_as_handled()
			KEY_DOWN:
				_move_selection(1)
				get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				start_selected_dialogue()
				get_viewport().set_input_as_handled()
			KEY_V:
				run_validation()
				get_viewport().set_input_as_handled()
			KEY_C:
				clear_validation_report()
				get_viewport().set_input_as_handled()
			KEY_X:
				reset_npc_dialogue_test_data()
				get_viewport().set_input_as_handled()
			KEY_H:
				_mutate_narrative_hour(1)
				get_viewport().set_input_as_handled()
			KEY_N:
				_mutate_narrative_set_night()
				get_viewport().set_input_as_handled()
			KEY_M:
				_mutate_narrative_set_morning()
				get_viewport().set_input_as_handled()
			KEY_F:
				_mutate_toggle_debug_flag()
				get_viewport().set_input_as_handled()
			KEY_Q:
				_mutate_cycle_linked_quest()
				get_viewport().set_input_as_handled()
			KEY_R:
				_mutate_relationship(5)
				get_viewport().set_input_as_handled()
			KEY_S:
				_mutate_cycle_npc_state()
				get_viewport().set_input_as_handled()
			KEY_L:
				_mutate_cycle_location()
				get_viewport().set_input_as_handled()
			_:
				pass


func _set_panel_visible(show_panel: bool) -> void:
	_visible_panel = show_panel
	if _root != null:
		_root.visible = show_panel
	if show_panel:
		_refresh()


func _cycle_focus(delta: int) -> void:
	var next := int(_focus) + delta
	var count := 3
	next = posmod(next, count)
	_focus = next as FocusPane
	_refresh()


func _move_selection(delta: int) -> void:
	match _focus:
		FocusPane.NPCS:
			if _npc_ids.is_empty():
				return
			_npc_index = posmod(_npc_index + delta, _npc_ids.size())
			_dialogue_ids = _dialogues_for_selected_npc()
			_dialogue_index = 0
		FocusPane.DIALOGUES:
			if _dialogue_ids.is_empty():
				return
			_dialogue_index = posmod(_dialogue_index + delta, _dialogue_ids.size())
		FocusPane.MUTATORS:
			pass
	_refresh()


func _refresh() -> void:
	_npc_ids = _collect_npc_ids()
	if _npc_ids.is_empty():
		_npc_index = 0
	else:
		_npc_index = clampi(_npc_index, 0, _npc_ids.size() - 1)
	_dialogue_ids = _dialogues_for_selected_npc()
	if _dialogue_ids.is_empty():
		_dialogue_index = 0
	else:
		_dialogue_index = clampi(_dialogue_index, 0, _dialogue_ids.size() - 1)

	if _title != null:
		_title.text = "NPC / Dialogues (debug)"
	if _body != null:
		_body.text = "\n".join(_build_body_lines())
	if _status != null:
		_status.text = _status_text if not _status_text.is_empty() else "Ready"
	if _hint != null:
		_hint.text = (
			"F10 close · Tab focus · ↑↓ select · Enter start dialogue · "
			+ "V validate · C clear report · X reset test data · "
			+ "H +1h · M morning · N night · F flag · Q quest · R rel+5 · S state · L location"
		)


func _build_body_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	var npc_id := get_selected_npc_id()
	var focus_name := "NPCS"
	match _focus:
		FocusPane.DIALOGUES:
			focus_name = "DIALOGUES"
		FocusPane.MUTATORS:
			focus_name = "MUTATORS"
		_:
			focus_name = "NPCS"

	lines.append("Focus: %s" % focus_name)
	lines.append("")
	lines.append("— NPCs —")
	if _npc_ids.is_empty():
		lines.append("  (none registered)")
	else:
		for i in range(_npc_ids.size()):
			var mark := ">" if i == _npc_index and _focus == FocusPane.NPCS else " "
			var id := str(_npc_ids[i])
			var name := id
			var dlg := get_node_or_null("/root/DialogueSystem")
			if dlg != null and dlg.has_method("get_npc_definition"):
				var def: Resource = dlg.call("get_npc_definition", id)
				if def != null and not str(def.get("display_name")).is_empty():
					name = "%s (%s)" % [str(def.get("display_name")), id]
			lines.append("%s %s" % [mark, name])

	lines.append("")
	lines.append("— Selected NPC —")
	if npc_id.is_empty():
		lines.append("  (none)")
	else:
		lines.append_array(_npc_detail_lines(npc_id))

	lines.append("")
	lines.append("— Dialogues for NPC —")
	if _dialogue_ids.is_empty():
		lines.append("  (none)")
	else:
		for i in range(_dialogue_ids.size()):
			var dmark := ">" if i == _dialogue_index and _focus == FocusPane.DIALOGUES else " "
			lines.append("%s %s" % [dmark, str(_dialogue_ids[i])])

	lines.append("")
	lines.append("— Rule conditions —")
	lines.append_array(_rule_condition_lines(npc_id))

	lines.append("")
	lines.append("— DialogueMemory —")
	lines.append_array(_memory_lines())

	lines.append("")
	lines.append("— Bark / cooldowns —")
	lines.append_array(_bark_lines(npc_id))

	lines.append("")
	lines.append("— Validation —")
	if _validation_report.is_empty():
		lines.append("  (press V to run)")
	else:
		for row in _validation_report.split("\n"):
			lines.append("  %s" % row)

	return lines


func _npc_detail_lines(npc_id: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var ns := get_node_or_null("/root/NpcStateSystem")
	var rel := get_node_or_null("/root/RelationshipSystem")
	var schedule := get_node_or_null("/root/NpcScheduleSystem")
	var travel := get_node_or_null("/root/NpcTravelSystem")
	var gt := get_node_or_null("/root/GameTimeSystem")
	var dlg := get_node_or_null("/root/DialogueSystem")
	var flags := get_node_or_null("/root/GameFlags")
	var quests := get_node_or_null("/root/QuestSystem")

	var state := "?"
	var location := "?"
	var travel_state := "?"
	var dest := ""
	var schedule_id := ""
	var activity := ""
	var relationship := 0
	if ns != null:
		if ns.has_method("ensure_npc"):
			ns.call("ensure_npc", npc_id)
		state = str(ns.call("get_current_state", npc_id)) if ns.has_method("get_current_state") else "?"
		location = str(ns.call("get_location_id", npc_id)) if ns.has_method("get_location_id") else "?"
		travel_state = str(ns.call("get_travel_state", npc_id)) if ns.has_method("get_travel_state") else "?"
		dest = str(ns.call("get_destination_location_id", npc_id)) if ns.has_method("get_destination_location_id") else ""
		schedule_id = str(ns.call("get_schedule_id", npc_id)) if ns.has_method("get_schedule_id") else ""
	if schedule != null:
		if schedule_id.is_empty() and schedule.has_method("get_schedule"):
			var sch: Resource = schedule.call("get_schedule", npc_id)
			if sch != null:
				schedule_id = str(sch.get("schedule_id"))
		if schedule.has_method("get_active_activity_id"):
			activity = str(schedule.call("get_active_activity_id", npc_id))
	if rel != null and rel.has_method("get_relationship"):
		relationship = int(rel.call("get_relationship", npc_id))
	var resolved := ""
	if dlg != null and dlg.has_method("resolve_dialogue_for_npc"):
		resolved = str(dlg.call("resolve_dialogue_for_npc", npc_id))
	var narrative := "?"
	if gt != null and gt.has_method("get_narrative_time_string"):
		narrative = str(gt.call("get_narrative_time_string"))

	lines.append("  state: %s" % state)
	lines.append("  location: %s" % (location if not location.is_empty() else "(empty)"))
	lines.append("  relationship: %d" % relationship)
	lines.append("  schedule: %s  activity: %s" % [
		schedule_id if not schedule_id.is_empty() else "(none)",
		activity if not activity.is_empty() else "-",
	])
	var traveling := false
	if travel != null and travel.has_method("is_traveling"):
		traveling = bool(travel.call("is_traveling", npc_id))
	lines.append(
		"  travel: %s%s"
		% [travel_state, (" → %s" % dest) if traveling and not dest.is_empty() else ""]
	)
	lines.append("  resolved dialogue: %s" % (resolved if not resolved.is_empty() else "(none)"))
	lines.append("  narrative time: %s" % narrative)

	if flags != null and flags.has_method("get_flag"):
		lines.append(
			"  flag %s: %s" % [DEBUG_FLAG_ID, str(bool(flags.call("get_flag", DEBUG_FLAG_ID, false)))]
		)
	if quests != null and dlg != null and dlg.has_method("get_npc_definition"):
		var def: Resource = dlg.call("get_npc_definition", npc_id)
		if def != null:
			var qid := str(def.get("linked_quest_id"))
			if not qid.is_empty() and quests.has_method("get_state_name"):
				lines.append("  linked quest %s: %s" % [qid, str(quests.call("get_state_name", qid))])
	return lines


func _rule_condition_lines(npc_id: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg == null or npc_id.is_empty() or not dlg.has_method("inspect_npc_dialogue_rules"):
		lines.append("  (n/a)")
		return lines
	var rows: Array = dlg.call("inspect_npc_dialogue_rules", npc_id)
	if rows.is_empty():
		lines.append("  (no rules — fallback only)")
		return lines
	for row in rows:
		var pass_tag := "TRUE" if bool(row.get("passes", false)) else "FALSE"
		var enabled := "on" if bool(row.get("enabled", true)) else "off"
		lines.append(
			"  [%s] p=%d %s → %s (%s)"
			% [pass_tag, int(row.get("priority", 0)), str(row.get("rule_id", "")), str(row.get("dialogue_id", "")), enabled]
		)
		var conds: Array = row.get("conditions", [])
		if conds.is_empty():
			lines.append("      (no conditions)")
		else:
			for cond in conds:
				var cr := "TRUE" if bool(cond.get("result", false)) else "FALSE"
				var key := str(cond.get("key", ""))
				lines.append(
					"      %s  %s%s"
					% [cr, str(cond.get("type", "?")), (" key=%s" % key) if not key.is_empty() else ""]
				)
	return lines


func _memory_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory == null:
		lines.append("  (DialogueMemorySystem missing)")
		return lines
	var seen: PackedStringArray = memory.call("get_seen_dialogue_ids") if memory.has_method("get_seen_dialogue_ids") else PackedStringArray()
	var completed: PackedStringArray = memory.call("get_completed_dialogue_ids") if memory.has_method("get_completed_dialogue_ids") else PackedStringArray()
	var choices: PackedStringArray = memory.call("get_choice_history_ids") if memory.has_method("get_choice_history_ids") else PackedStringArray()
	lines.append("  seen: %s" % (", ".join(seen) if not seen.is_empty() else "(none)"))
	if completed.is_empty():
		lines.append("  completed: (none)")
	else:
		var parts: PackedStringArray = PackedStringArray()
		for cid in completed:
			var times := int(memory.call("get_times_completed", cid))
			parts.append("%s×%d" % [cid, times])
		lines.append("  completed: %s" % ", ".join(parts))
	if choices.is_empty():
		lines.append("  choices: (none)")
	else:
		var cparts: PackedStringArray = PackedStringArray()
		for ch in choices:
			var count := int(memory.call("get_choice_count", ch))
			cparts.append("%s×%d" % [ch, count])
		lines.append("  choices: %s" % ", ".join(cparts))
	return lines


func _bark_lines(npc_id: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var bark := get_node_or_null("/root/BarkSystem")
	if bark == null or npc_id.is_empty():
		lines.append("  (n/a)")
		return lines
	if not bark.has_method("get_bark_debug_state"):
		lines.append("  last: %s" % str(bark.call("get_last_bark_id", npc_id)))
		return lines
	var state: Dictionary = bark.call("get_bark_debug_state", npc_id)
	lines.append("  last: %s" % str(state.get("last_bark_id", "")))
	var recent: PackedStringArray = state.get("recent_bark_ids", PackedStringArray())
	lines.append("  recent: %s" % (", ".join(recent) if not recent.is_empty() else "(none)"))
	lines.append("  min_gap_left: %.1fs" % float(state.get("min_gap_remaining", 0.0)))
	var cool: Dictionary = state.get("active_cooldowns", {})
	if cool.is_empty():
		lines.append("  cooldowns: (none)")
	else:
		var parts: PackedStringArray = PackedStringArray()
		for key in cool.keys():
			parts.append("%s=%.1fs" % [str(key), float(cool[key])])
		lines.append("  cooldowns: %s" % ", ".join(parts))
	lines.append("  presenter: %s" % ("yes" if bool(state.get("has_presenter", false)) else "no"))
	return lines


func _collect_npc_ids() -> PackedStringArray:
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg != null and dlg.has_method("get_registered_npc_ids"):
		return dlg.call("get_registered_npc_ids")
	return PackedStringArray()


func _dialogues_for_selected_npc() -> PackedStringArray:
	var npc_id := get_selected_npc_id()
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg == null or npc_id.is_empty():
		return PackedStringArray()
	if dlg.has_method("get_dialogue_ids_for_npc"):
		return dlg.call("get_dialogue_ids_for_npc", npc_id)
	return PackedStringArray()


func _find_npc_actor(npc_id: String) -> Node:
	if npc_id.is_empty():
		return null
	var tree := get_tree()
	if tree == null:
		return null
	# Dev-only lookup — walk scene for matching get_npc_id (no gameplay coupling).
	var stack: Array = [tree.current_scene if tree.current_scene != null else tree.root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node == null:
			continue
		if node.has_method("get_npc_id") and str(node.call("get_npc_id")) == npc_id:
			return node
		for child in node.get_children():
			stack.append(child)
	return null


func _mutate_narrative_hour(hours: int) -> void:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null:
		return
	if gt.has_method("debug_advance_narrative_hours"):
		gt.call("debug_advance_narrative_hours", float(hours))
	elif gt.has_method("advance_narrative_minutes"):
		gt.call("advance_narrative_minutes", float(hours) * 60.0)
	_status_text = "Narrative +%dh → %s" % [
		hours,
		str(gt.call("get_narrative_time_string")) if gt.has_method("get_narrative_time_string") else "?",
	]
	_refresh()


func _mutate_narrative_set_morning() -> void:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_method("set_narrative_time"):
		return
	var day := int(gt.call("get_narrative_day_index")) if gt.has_method("get_narrative_day_index") else 0
	gt.call("set_narrative_time", day, 8, 0)
	_status_text = "Narrative set morning 08:00"
	_refresh()


func _mutate_narrative_set_night() -> void:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_method("set_narrative_time"):
		return
	var day := int(gt.call("get_narrative_day_index")) if gt.has_method("get_narrative_day_index") else 0
	gt.call("set_narrative_time", day, 22, 0)
	_status_text = "Narrative set night 22:00"
	_refresh()


func _mutate_toggle_debug_flag() -> void:
	var flags := get_node_or_null("/root/GameFlags")
	if flags == null:
		return
	var current := bool(flags.call("get_flag", DEBUG_FLAG_ID, false))
	flags.call("set_flag", DEBUG_FLAG_ID, not current)
	_status_text = "Flag %s = %s" % [DEBUG_FLAG_ID, str(not current)]
	_refresh()


func _mutate_cycle_linked_quest() -> void:
	var npc_id := get_selected_npc_id()
	var dlg := get_node_or_null("/root/DialogueSystem")
	var quests := get_node_or_null("/root/QuestSystem")
	if dlg == null or quests == null or npc_id.is_empty():
		return
	var def: Resource = dlg.call("get_npc_definition", npc_id)
	if def == null:
		return
	var qid := str(def.get("linked_quest_id"))
	if qid.is_empty():
		_status_text = "No linked_quest_id on NPC"
		_refresh()
		return
	var name := str(quests.call("get_state_name", qid))
	match name:
		"INACTIVE":
			quests.call("start_quest", qid)
		"ACTIVE":
			quests.call("complete_quest", qid)
		_:
			if quests.has_method("reset_quest"):
				quests.call("reset_quest", qid)
	_status_text = "Quest %s → %s" % [qid, str(quests.call("get_state_name", qid))]
	_refresh()


func _mutate_relationship(delta: int) -> void:
	var npc_id := get_selected_npc_id()
	var rel := get_node_or_null("/root/RelationshipSystem")
	if rel == null or npc_id.is_empty():
		return
	var current := int(rel.call("get_relationship", npc_id))
	var next := current + delta
	if rel.has_method("set_relationship"):
		rel.call("set_relationship", npc_id, next)
	elif rel.has_method("add_relationship"):
		rel.call("add_relationship", npc_id, delta)
	_status_text = "Relationship %s → %d" % [
		npc_id,
		int(rel.call("get_relationship", npc_id)),
	]
	_refresh()


func _mutate_cycle_npc_state() -> void:
	var npc_id := get_selected_npc_id()
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty():
		return
	ns.call("ensure_npc", npc_id)
	var current := str(ns.call("get_current_state", npc_id))
	var idx := NPC_STATES.find(current)
	idx = 0 if idx < 0 else (idx + 1) % NPC_STATES.size()
	ns.call("set_current_state", npc_id, NPC_STATES[idx])
	_status_text = "NPC state → %s" % NPC_STATES[idx]
	_refresh()


func _mutate_cycle_location() -> void:
	var npc_id := get_selected_npc_id()
	var ns := get_node_or_null("/root/NpcStateSystem")
	var schedule := get_node_or_null("/root/NpcScheduleSystem")
	var travel := get_node_or_null("/root/NpcTravelSystem")
	if ns == null or npc_id.is_empty():
		return
	var locations: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	if schedule != null and schedule.has_method("get_schedule"):
		var sch: Resource = schedule.call("get_schedule", npc_id)
		if sch != null:
			var fallback := str(sch.get("fallback_location_id"))
			if not fallback.is_empty() and not seen.has(fallback):
				seen[fallback] = true
				locations.append(fallback)
			var entries: Variant = sch.get("entries")
			if typeof(entries) == TYPE_ARRAY:
				for entry in entries:
					if entry == null:
						continue
					var loc := str(entry.get("location_id"))
					if loc.is_empty() or seen.has(loc):
						continue
					seen[loc] = true
					locations.append(loc)
	# Common traveler debug destination.
	if not seen.has("debug_waystation"):
		locations.append("debug_waystation")
	if locations.is_empty():
		locations.append("sunset_viewpoint")
	ns.call("ensure_npc", npc_id)
	var current := str(ns.call("get_location_id", npc_id))
	var idx := locations.find(current)
	idx = 0 if idx < 0 else (idx + 1) % locations.size()
	var next_loc := str(locations[idx])
	if travel != null and travel.has_method("set_at_location"):
		travel.call("set_at_location", npc_id, next_loc, "debug_panel")
	else:
		ns.call("set_location_id", npc_id, next_loc)
	_status_text = "NPC location → %s" % next_loc
	_refresh()
