extends Area3D
class_name InteractionDetector
## Finds nearby interactables in front of the player. Owns focus + player_interact input.
## Duck-types targets (no hard dependency on concrete Interactable subclasses).
## Does not contain per-object logic — only discovery, ranking, and dispatch.

signal focus_changed(previous: Node, current: Node)
signal interacted(target: Node)

@export var actor_path: NodePath = NodePath("..")
## Prefer targets within this forward cone (degrees from facing). 180 = full sphere.
@export var front_cone_degrees: float = 120.0
@export var max_focus_distance: float = 2.4

var _actor: Node3D
var _focus: Node
var _overlaps: Array[Node] = []


func _ready() -> void:
	monitoring = true
	monitorable = false
	collision_layer = 0
	# Interactable layer (8).
	collision_mask = 8
	if not area_entered.is_connected(_on_area_entered):
		area_entered.connect(_on_area_entered)
	if not area_exited.is_connected(_on_area_exited):
		area_exited.connect(_on_area_exited)
	_resolve_actor()
	set_physics_process(false)


func _physics_process(_delta: float) -> void:
	_refresh_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_detector_active():
		return
	if not event.is_action_pressed("player_interact"):
		return
	if _focus == null:
		return
	if try_interact():
		get_viewport().set_input_as_handled()


func set_detector_active(active: bool) -> void:
	set_physics_process(active)
	monitoring = active
	visible = active
	if not active:
		_set_focus(null)
		_overlaps.clear()


func is_detector_active() -> bool:
	return is_physics_processing()


func get_focus() -> Node:
	return _focus


func has_focus() -> bool:
	return _focus != null and is_instance_valid(_focus) and _duck_can_interact(_focus, _actor)


func get_focus_prompt() -> String:
	if not has_focus():
		return ""
	return _duck_prompt(_focus)


func try_interact() -> bool:
	if not has_focus():
		return false
	var target := _focus
	if _duck_interact(target, _actor):
		interacted.emit(target)
		return true
	return false


## Static duck-type helpers — usable by UI / occupancy without importing subclasses.
static func is_interactable_node(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return node.has_method("can_interact") and node.has_method("interact")


func _is_detector_active() -> bool:
	if not is_physics_processing():
		return false
	_resolve_actor()
	if _actor != null and _actor.has_method("is_control_enabled"):
		return bool(_actor.call("is_control_enabled"))
	return _actor != null


func _on_area_entered(area: Area3D) -> void:
	_register_candidate(area)


func _on_area_exited(area: Area3D) -> void:
	_unregister_candidate(area)


func _register_candidate(node: Node) -> void:
	var target := _resolve_interactable(node)
	if target == null:
		return
	if not _overlaps.has(target):
		_overlaps.append(target)
	_refresh_focus()


func _unregister_candidate(node: Node) -> void:
	var target := _resolve_interactable(node)
	if target == null:
		target = node
	_overlaps.erase(target)
	if _focus == target:
		_set_focus(null)
	_refresh_focus()


func _resolve_interactable(node: Node) -> Node:
	if is_interactable_node(node):
		return node
	if node.get_parent() != null and is_interactable_node(node.get_parent()):
		return node.get_parent()
	return null


func _refresh_focus() -> void:
	# Drop invalid / no-longer-valid entries.
	var alive: Array[Node] = []
	for n in _overlaps:
		if n != null and is_instance_valid(n) and _duck_can_interact(n, _actor):
			alive.append(n)
	_overlaps = alive

	var best: Node = null
	var best_score := -INF
	for n in _overlaps:
		var score := _score_candidate(n)
		if score > best_score:
			best_score = score
			best = n
	if best != null and best_score < 0.0:
		best = null
	_set_focus(best)


func _score_candidate(node: Node) -> float:
	if _actor == null or not (node is Node3D):
		return -1.0
	var target := node as Node3D
	var to := target.global_position - _actor.global_position
	var planar := Vector3(to.x, 0.0, to.z)
	var dist := planar.length()
	if dist > max_focus_distance:
		return -1.0

	var forward := -_actor.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var dir := planar.normalized() if dist > 0.05 else forward
	var dot := forward.dot(dir)
	var min_dot := cos(deg_to_rad(clampf(front_cone_degrees, 1.0, 180.0) * 0.5))
	if dot < min_dot:
		return -1.0

	var priority := 0.0
	if "interaction_priority" in node:
		priority = float(node.get("interaction_priority"))
	# Higher priority, more frontal, closer → better.
	return priority * 10.0 + dot * 2.0 - dist


func _set_focus(next: Node) -> void:
	if next == _focus:
		return
	var prev := _focus
	_focus = next
	focus_changed.emit(prev, _focus)


func _duck_can_interact(node: Node, actor: Node) -> bool:
	if not is_interactable_node(node):
		return false
	return bool(node.call("can_interact", actor))


func _duck_interact(node: Node, actor: Node) -> bool:
	if not is_interactable_node(node):
		return false
	return bool(node.call("interact", actor))


func _duck_prompt(node: Node) -> String:
	if node.has_method("get_interaction_prompt"):
		return str(node.call("get_interaction_prompt"))
	if "interaction_prompt" in node:
		var p := str(node.get("interaction_prompt"))
		if not p.is_empty():
			return p
	if "interaction_name" in node:
		return "E — Interagir: %s" % str(node.get("interaction_name"))
	return "E — Interagir"


func _resolve_actor() -> void:
	if actor_path != NodePath():
		_actor = get_node_or_null(actor_path) as Node3D
	if _actor == null:
		_actor = get_parent() as Node3D
