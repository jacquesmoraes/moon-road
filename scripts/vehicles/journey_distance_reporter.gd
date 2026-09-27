extends Node
## Feeds JourneySystem from physical travel. One-way: vehicle/scene → journey. No reverse deps.

@export var target_path: NodePath
@export var meters_per_world_unit: float = 1.0
@export var enabled: bool = true

var _target: Node3D
var _journey: Node
var _last_position: Vector3 = Vector3.ZERO
var _has_last_position: bool = false


func _ready() -> void:
	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		_target = get_parent() as Node3D
	_journey = get_node_or_null("/root/JourneySystem")


func _physics_process(_delta: float) -> void:
	if not enabled or _target == null or not is_instance_valid(_target):
		return
	if _journey == null:
		_journey = get_node_or_null("/root/JourneySystem")
	if _journey == null:
		return

	var pos := _target.global_position
	if not pos.is_finite():
		return

	if not _has_last_position:
		_last_position = pos
		_has_last_position = true
		return

	var delta_xz := Vector3(pos.x - _last_position.x, 0.0, pos.z - _last_position.z)
	_last_position = pos

	var meters := delta_xz.length() * meters_per_world_unit
	if meters <= 0.00001:
		return

	_journey.call("add_distance", meters / 1000.0)
