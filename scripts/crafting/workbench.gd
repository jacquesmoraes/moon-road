extends Area3D
class_name Workbench
## Placeholder craft station. Opens CraftingDebugUI; does not own recipe logic.
## Duck-types Interactable. No NPC coupling.

signal interacted(actor: Node)
signal craft_ui_opened
signal craft_ui_closed

@export var interaction_name: String = "Workbench"
@export var interaction_prompt: String = "E — Usar: Workbench"
@export var enabled: bool = true
@export var interaction_priority: int = 2

var _model: Node3D
var _label: Label3D


func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = true
	_model = get_node_or_null("Model") as Node3D
	_label = get_node_or_null("NameLabel") as Label3D
	if _label != null:
		_label.text = interaction_name


func get_interaction_name() -> String:
	return interaction_name


func get_interaction_prompt() -> String:
	if interaction_prompt.is_empty():
		return "E — Usar: %s" % interaction_name
	return interaction_prompt


func can_interact(_actor: Node = null) -> bool:
	return enabled and is_inside_tree() and is_visible_in_tree()


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false
	var ui := _craft_ui()
	if ui == null:
		print("Workbench: CraftingDebugUI missing")
		set_meta("last_interact_message", "No crafting UI")
		return false
	if ui.has_method("is_panel_visible") and bool(ui.call("is_panel_visible")):
		if ui.has_method("close"):
			ui.call("close")
		craft_ui_closed.emit()
		set_meta("last_interact_message", "Crafting closed")
	else:
		if ui.has_method("open_for_workbench"):
			ui.call("open_for_workbench", self)
		elif ui.has_method("open"):
			ui.call("open")
		craft_ui_opened.emit()
		set_meta("last_interact_message", "Crafting opened")
	set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
	interacted.emit(actor)
	print("Workbench: toggled crafting UI (actor=%s)" % (str(actor.name) if actor else "unknown"))
	return true


func _craft_ui() -> Node:
	if get_tree() == null:
		return null
	for node in get_tree().get_nodes_in_group("crafting_debug_ui"):
		if node != null:
			return node
	if get_tree().current_scene != null:
		return get_tree().current_scene.find_child("CraftingDebugUI", true, false)
	return null
