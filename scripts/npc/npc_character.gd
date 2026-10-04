extends Area3D
class_name NpcCharacter
## Reusable placeholder NPC. Duck-types the Interactable API (same detector as terminals).
## Static data from NpcDefinition; mutable campaign fields from NpcStateSystem.
## On interact: starts DialogueSystem by dialogue_id (no lines authored in this script).

signal interacted(actor: Node)
signal line_spoken(line: String)
signal dialogue_requested(dialogue_id: String, actor: Node)

@export var definition: NpcDefinition
## Fallback exports when no Resource is assigned (editor convenience / tests).
@export var npc_id: String = ""
@export var display_name: String = "NPC"
@export var role: String = "traveler"
@export var enabled: bool = true
@export var dialogue_id: String = ""
@export var linked_quest_id: String = ""
@export var greeting_line: String = ""
@export var interaction_priority: int = 0

var _name_label: Label3D


func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = true
	_apply_definition_to_exports()
	_sync_with_state_system()
	# POISystem calls ViewpointPOI.setup after add_child; defer so get_poi_id is available.
	call_deferred("_sync_spawn_location")
	_cache_nodes()
	_refresh_name_label()
	_connect_narrative_time()
	_refresh_time_availability()


func get_npc_id() -> String:
	_apply_definition_to_exports()
	return npc_id


func get_display_name() -> String:
	_apply_definition_to_exports()
	return display_name


func get_role() -> String:
	_apply_definition_to_exports()
	return role


func is_npc_enabled() -> bool:
	_apply_definition_to_exports()
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null and ns.has_method("is_enabled"):
		return bool(ns.call("is_enabled", get_npc_id()))
	return enabled


func get_dialogue_id() -> String:
	## Contextual pick via DialogueSystem — this scene never inspects rule internals.
	_apply_definition_to_exports()
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg != null:
		if dlg.has_method("resolve_dialogue_for_npc"):
			var by_id := str(dlg.call("resolve_dialogue_for_npc", get_npc_id()))
			if not by_id.is_empty():
				return by_id
		if definition != null and dlg.has_method("resolve_dialogue_from_definition"):
			var from_def := str(dlg.call("resolve_dialogue_from_definition", definition))
			if not from_def.is_empty():
				return from_def
	return dialogue_id


func get_linked_quest_id() -> String:
	_apply_definition_to_exports()
	if not linked_quest_id.is_empty():
		return linked_quest_id
	var qs := get_node_or_null("/root/QuestSystem")
	if qs != null and qs.has_method("find_quest_for_giver"):
		return str(qs.call("find_quest_for_giver", get_npc_id()))
	return ""


func get_greeting_line() -> String:
	_apply_definition_to_exports()
	return greeting_line


func get_presence_mode_name() -> String:
	if definition != null and definition.has_method("get_presence_mode_name"):
		return str(definition.call("get_presence_mode_name"))
	return "STATIC"


func get_interaction_name() -> String:
	return get_display_name()


func get_interaction_prompt() -> String:
	return "E — Falar: %s" % get_display_name()


func is_within_availability_window() -> bool:
	## Data-driven narrative-hour window from NpcDefinition (never system clock).
	_apply_definition_to_exports()
	if definition == null or not definition.has_method("has_availability_window"):
		return true
	if not bool(definition.call("has_availability_window")):
		return true
	var gt := get_node_or_null("/root/GameTimeSystem")
	var hour := 0
	if gt != null and gt.has_method("get_narrative_hour"):
		hour = int(gt.call("get_narrative_hour"))
	elif gt != null and gt.has_method("get_hour_of_day"):
		hour = int(gt.call("get_hour_of_day"))
	if definition.has_method("is_hour_within_availability"):
		return bool(definition.call("is_hour_within_availability", hour))
	return true


func can_interact(_actor: Node = null) -> bool:
	if not is_npc_enabled() or not is_inside_tree() or not is_visible_in_tree():
		return false
	if not is_within_availability_window():
		return false
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null and ns.has_method("get_current_state"):
		if str(ns.call("get_current_state", get_npc_id())) == "UNAVAILABLE":
			return false
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg != null and dlg.has_method("is_active") and bool(dlg.call("is_active")):
		return false
	return not get_dialogue_id().is_empty() or not get_greeting_line().is_empty()


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false

	var started := false
	var id := get_dialogue_id()
	if not id.is_empty():
		var dlg := get_node_or_null("/root/DialogueSystem")
		if dlg != null and dlg.has_method("start_dialogue"):
			_arm_dialogue_movement_lock()
			started = bool(dlg.call("start_dialogue", id, actor))
			if started:
				dialogue_requested.emit(id, actor)
				var text := str(dlg.call("get_current_text")) if dlg.has_method("get_current_text") else id
				set_meta("last_spoken_line", text)
				set_meta("last_interact_message", "NPC %s dialogue=%s" % [get_display_name(), id])
				line_spoken.emit(text)
				_record_talk_state(id)
			else:
				_clear_dialogue_movement_lock()

	if not started:
		# Fallback: one-shot line via DialogueSystem if possible, else meta only.
		var line := get_greeting_line()
		if line.is_empty():
			return false
		var dlg2 := get_node_or_null("/root/DialogueSystem")
		if dlg2 != null and dlg2.has_method("start_from_definition"):
			var fallback := _make_fallback_definition(line)
			_arm_dialogue_movement_lock()
			started = bool(dlg2.call("start_from_definition", fallback, actor))
			if started:
				dialogue_requested.emit(str(fallback.get("id")), actor)
				set_meta("last_spoken_line", line)
				set_meta("last_interact_message", "NPC %s fallback='%s'" % [get_display_name(), line])
				line_spoken.emit(line)
				_record_talk_state(str(fallback.get("id")))
			else:
				_clear_dialogue_movement_lock()
		if not started:
			set_meta("last_spoken_line", line)
			set_meta("last_interact_message", "NPC %s: \"%s\"" % [get_display_name(), line])
			line_spoken.emit(line)
			started = true
			_record_talk_state("")

	set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
	interacted.emit(actor)
	print(
		"Npc %s (%s): dialogue_id=%s (actor=%s)"
		% [get_display_name(), get_role(), get_dialogue_id(), str(actor.name) if actor else "unknown"]
	)
	return started


func get_last_spoken_line() -> String:
	return str(get_meta("last_spoken_line", ""))


func _make_fallback_definition(line: String) -> Resource:
	var script: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var def: Resource = script.new() if script != null else Resource.new()
	def.set("id", "fallback_%s" % get_npc_id())
	def.set("speaker_name", get_display_name())
	def.set("text", line)
	def.set("next_dialogue_id", "")
	return def


func _apply_definition_to_exports() -> void:
	if definition == null:
		return
	if not definition.npc_id.is_empty():
		npc_id = definition.npc_id
	if not definition.display_name.is_empty():
		display_name = definition.display_name
	if not definition.role.is_empty():
		role = definition.role
	# Definition.enabled is the authoring default only — runtime uses NpcStateSystem.
	enabled = definition.enabled
	var fallback := ""
	if definition.has_method("get_fallback_dialogue_id"):
		fallback = str(definition.call("get_fallback_dialogue_id"))
	elif "fallback_dialogue_id" in definition and not str(definition.fallback_dialogue_id).is_empty():
		fallback = str(definition.fallback_dialogue_id)
	elif not definition.dialogue_id.is_empty():
		fallback = definition.dialogue_id
	if not fallback.is_empty():
		dialogue_id = fallback
	if "linked_quest_id" in definition and not str(definition.linked_quest_id).is_empty():
		linked_quest_id = str(definition.linked_quest_id)
	if not definition.greeting_line.is_empty():
		greeting_line = definition.greeting_line


func _sync_with_state_system() -> void:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or not ns.has_method("ensure_npc"):
		return
	var id := get_npc_id()
	if id.is_empty():
		return
	ns.call(
		"ensure_npc",
		id,
		{"enabled": enabled, "current_state": "DEFAULT"}
	)
	if ns.has_method("is_enabled"):
		enabled = bool(ns.call("is_enabled", id))
	_sync_spawn_location()


func _sync_spawn_location() -> void:
	## Updates logical location when parented under a POI — skipped if a schedule owns it.
	var id := get_npc_id()
	if id.is_empty():
		return
	var schedules := get_node_or_null("/root/NpcScheduleSystem")
	if schedules != null and schedules.has_method("has_schedule") and bool(schedules.call("has_schedule", id)):
		if schedules.has_method("refresh_npc"):
			schedules.call("refresh_npc", id)
		return
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or not ns.has_method("set_location_id"):
		return
	var location := _resolve_spawn_location_id()
	if not location.is_empty():
		ns.call("set_location_id", id, location)


func _resolve_spawn_location_id() -> String:
	var node: Node = get_parent()
	while node != null:
		if node.has_method("get_poi_id"):
			var poi_id := str(node.call("get_poi_id"))
			if not poi_id.is_empty():
				return poi_id
		node = node.get_parent()
	return ""


func _record_talk_state(started_dialogue_id: String) -> void:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null:
		return
	var id := get_npc_id()
	if id.is_empty():
		return
	if ns.has_method("set_met_player"):
		ns.call("set_met_player", id, true)
	if not started_dialogue_id.is_empty() and ns.has_method("set_last_dialogue_id"):
		ns.call("set_last_dialogue_id", id, started_dialogue_id)


func _cache_nodes() -> void:
	_name_label = get_node_or_null("NameLabel") as Label3D


func _refresh_name_label() -> void:
	if _name_label == null:
		return
	_name_label.text = get_display_name()


func _connect_narrative_time() -> void:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_signal("narrative_time_changed"):
		return
	if not gt.narrative_time_changed.is_connected(_on_narrative_time_changed):
		gt.narrative_time_changed.connect(_on_narrative_time_changed)


func _on_narrative_time_changed(_day_index: int, _hour: int, _minute: int = 0) -> void:
	_refresh_time_availability()


func _refresh_time_availability() -> void:
	## Outside the authored window: hidden + non-interactable.
	## Does not wipe NpcStateSystem persistence — only scene presence/interaction.
	var available := is_within_availability_window()
	visible = available
	monitorable = available
	collision_layer = 8 if available else 0
	if _name_label != null:
		_name_label.visible = available
	var movement := get_node_or_null("NpcMovementController")
	if movement != null:
		if available:
			if bool(get_meta("movement_availability_paused", false)):
				set_meta("movement_availability_paused", false)
				if movement.has_method("snap_to_current_schedule"):
					movement.call("snap_to_current_schedule")
				if movement.has_method("resume_movement"):
					movement.call("resume_movement", "availability")
		elif movement.has_method("pause_movement"):
			set_meta("movement_availability_paused", true)
			movement.call("pause_movement", "availability")


func _arm_dialogue_movement_lock() -> void:
	## Arm before start_dialogue so dialogue_started can pause this NPC only.
	set_meta("movement_dialogue_lock", true)
	var movement := get_node_or_null("NpcMovementController")
	if movement != null and movement.has_method("pause_movement"):
		movement.call("pause_movement", "dialogue")


func _clear_dialogue_movement_lock() -> void:
	set_meta("movement_dialogue_lock", false)
	var movement := get_node_or_null("NpcMovementController")
	if movement != null and movement.has_method("resume_movement"):
		movement.call("resume_movement", "dialogue")
