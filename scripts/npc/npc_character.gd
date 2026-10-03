extends Area3D
class_name NpcCharacter
## Reusable placeholder NPC. Duck-types the Interactable API (same detector as terminals).
## Data comes from NpcDefinition — not hardcoded on PlayerCharacter.
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
@export var greeting_line: String = ""
@export var interaction_priority: int = 0

var _name_label: Label3D


func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = true
	_apply_definition_to_exports()
	_cache_nodes()
	_refresh_name_label()


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
	return enabled


func get_dialogue_id() -> String:
	_apply_definition_to_exports()
	return dialogue_id


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


func can_interact(_actor: Node = null) -> bool:
	if not is_npc_enabled() or not is_inside_tree() or not is_visible_in_tree():
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
			started = bool(dlg.call("start_dialogue", id, actor))
			if started:
				dialogue_requested.emit(id, actor)
				var text := str(dlg.call("get_current_text")) if dlg.has_method("get_current_text") else id
				set_meta("last_spoken_line", text)
				set_meta("last_interact_message", "NPC %s dialogue=%s" % [get_display_name(), id])
				line_spoken.emit(text)

	if not started:
		# Fallback: one-shot line via DialogueSystem if possible, else meta only.
		var line := get_greeting_line()
		if line.is_empty():
			return false
		var dlg2 := get_node_or_null("/root/DialogueSystem")
		if dlg2 != null and dlg2.has_method("start_from_definition"):
			var fallback := _make_fallback_definition(line)
			started = bool(dlg2.call("start_from_definition", fallback, actor))
			if started:
				dialogue_requested.emit(str(fallback.get("id")), actor)
				set_meta("last_spoken_line", line)
				set_meta("last_interact_message", "NPC %s fallback='%s'" % [get_display_name(), line])
				line_spoken.emit(line)
		if not started:
			set_meta("last_spoken_line", line)
			set_meta("last_interact_message", "NPC %s: \"%s\"" % [get_display_name(), line])
			line_spoken.emit(line)
			started = true

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
	enabled = definition.enabled
	if not definition.dialogue_id.is_empty():
		dialogue_id = definition.dialogue_id
	if not definition.greeting_line.is_empty():
		greeting_line = definition.greeting_line


func _cache_nodes() -> void:
	_name_label = get_node_or_null("NameLabel") as Label3D


func _refresh_name_label() -> void:
	if _name_label == null:
		return
	_name_label.text = get_display_name()
