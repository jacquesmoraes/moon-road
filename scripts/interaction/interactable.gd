extends Area3D
class_name Interactable
## Base for world interactables (terminals, doors, benches, shops, NPCs later).
## Detectors should duck-type (can_interact / interact / prompts) — not depend on this class alone.

signal interacted(actor: Node)

@export var interaction_name: String = "Object"
@export var interaction_prompt: String = "E — Interagir"
@export var enabled: bool = true
## Optional max range hint for UI; detector uses its own volume.
@export var interaction_priority: int = 0

func _ready() -> void:
	# Dedicated interactable layer (bit 3 → value 8) so detectors can mask cleanly.
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


func can_interact(actor: Node = null) -> bool:
	if not enabled or not is_inside_tree():
		return false
	if not visible_in_tree():
		return false
	return _can_interact(actor)


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false
	_on_interact(actor)
	interacted.emit(actor)
	return true


## Override in subclasses for extra gates (locked doors, out of stock, etc.).
func _can_interact(_actor: Node) -> bool:
	return true


## Override in subclasses for the actual effect.
func _on_interact(_actor: Node) -> void:
	pass
