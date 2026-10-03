extends Area3D
class_name ObservationLog
## Simple interior interactable (duck-typed Interactable API). Placeholder note/log.

signal interacted(actor: Node)

@export var interaction_name: String = "Observation Log"
@export var interaction_prompt: String = "E — Interagir: Observation Log"
@export var enabled: bool = true
@export var interaction_priority: int = 0
@export var log_message: String = "ObservationLog: horizon notes recorded"


func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = true


func get_interaction_name() -> String:
	return interaction_name


func get_interaction_prompt() -> String:
	if interaction_prompt.is_empty():
		return "E — Interagir: %s" % interaction_name
	return interaction_prompt


func can_interact(_actor: Node = null) -> bool:
	return enabled and is_inside_tree() and is_visible_in_tree()


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false
	var actor_name := str(actor.name) if actor != null else "unknown"
	var msg := "%s (actor=%s)" % [log_message, actor_name]
	print(msg)
	set_meta("last_interact_message", msg)
	set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
	interacted.emit(actor)
	return true
