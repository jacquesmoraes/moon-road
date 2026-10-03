extends Node
class_name WorldOriginRecenter
## Shifts active subject + companions (vehicle, on-foot character, road, camera)
## so the player stays near world origin.
## Logical journey distance is unaffected (reporter uses deltas + shift notification).

signal recentered(offset: Vector3, count: int)

@export var target_path: NodePath = NodePath("../PlayerVehicle")
@export var road_manager_path: NodePath = NodePath("../RoadManager")
@export var exit_system_path: NodePath = NodePath("../RoadsideExitSystem")
## Extra Node3Ds always shifted with the origin (e.g. parked vehicle while on foot).
@export var companion_paths: Array[NodePath] = []
## Recenter when planar distance from origin exceeds this (meters / world units).
@export var recenter_distance: float = 1000.0
@export var enabled: bool = true
@export var shift_scale_refs: bool = true

var _target: Node3D
var _road_manager: Node
var _exit_system: Node
var _companions: Array[Node3D] = []
var _recenter_count: int = 0


func _ready() -> void:
	_resolve_nodes()


func _physics_process(_delta: float) -> void:
	if not enabled:
		return
	if _target == null or not is_instance_valid(_target):
		_resolve_nodes()
		if _target == null:
			return

	var pos := _target.global_position
	if not pos.is_finite():
		return

	var planar := Vector3(pos.x, 0.0, pos.z)
	if planar.length() < maxf(recenter_distance, 1.0):
		return

	_apply_shift(planar)


func get_recenter_count() -> int:
	return _recenter_count


## Occupancy swaps the distance-check subject (vehicle ↔ on-foot character).
func set_recenter_target(node: Node3D) -> void:
	_target = node


func get_recenter_target() -> Node3D:
	return _target


func _resolve_nodes() -> void:
	if _target == null or not is_instance_valid(_target):
		if target_path != NodePath():
			_target = get_node_or_null(target_path) as Node3D
		if _target == null and get_tree().current_scene != null:
			_target = get_tree().current_scene.find_child("PlayerVehicle", true, false) as Node3D

	if road_manager_path != NodePath():
		_road_manager = get_node_or_null(road_manager_path)
	if _road_manager == null and get_tree().current_scene != null:
		_road_manager = get_tree().current_scene.find_child("RoadManager", true, false)

	if exit_system_path != NodePath():
		_exit_system = get_node_or_null(exit_system_path)
	if _exit_system == null and get_tree().current_scene != null:
		_exit_system = get_tree().current_scene.find_child("RoadsideExitSystem", true, false)

	_companions.clear()
	for path in companion_paths:
		var n := get_node_or_null(path) as Node3D
		if n != null:
			_companions.append(n)
	# Always keep vehicle + character coherent across origin shifts when present.
	if get_tree().current_scene != null:
		for name in ["PlayerVehicle", "PlayerCharacter"]:
			var found := get_tree().current_scene.find_child(name, true, false) as Node3D
			if found != null and not _companions.has(found):
				_companions.append(found)


func _apply_shift(offset: Vector3) -> void:
	if offset.length_squared() < 0.0001:
		return

	_resolve_nodes()

	var shifted: Array[Node3D] = []
	_shift_body(_target, offset, shifted)

	for companion in _companions:
		_shift_body(companion, offset, shifted)

	if _road_manager != null and _road_manager.has_method("apply_origin_shift"):
		_road_manager.call("apply_origin_shift", offset)
	elif _road_manager != null:
		for child in _road_manager.get_children():
			if child is Node3D:
				(child as Node3D).global_position -= offset

	if _exit_system != null and _exit_system.has_method("apply_origin_shift"):
		_exit_system.call("apply_origin_shift", offset)
	elif _exit_system is Node3D:
		(_exit_system as Node3D).global_position -= offset

	var poi_sys := get_node_or_null("/root/POISystem")
	if poi_sys != null and poi_sys.has_method("apply_origin_shift"):
		poi_sys.call("apply_origin_shift", offset)

	var camera := get_tree().current_scene.find_child("VehicleCameraController", true, false) as Node3D
	if camera != null:
		camera.global_position -= offset
		if camera.has_method("notify_origin_shifted"):
			camera.call("notify_origin_shifted", offset)

	if shift_scale_refs:
		var refs := get_tree().current_scene.find_child("ScaleRefs", true, false) as Node3D
		if refs != null:
			refs.global_position -= offset

	# Keep journey delta tracking coherent (do not count the teleport as travel).
	for body in shifted:
		if body == null:
			continue
		for child in body.get_children():
			if child.has_method("notify_origin_shifted"):
				child.call("notify_origin_shifted", offset)

	_recenter_count += 1
	recentered.emit(offset, _recenter_count)


func _shift_body(node: Node3D, offset: Vector3, shifted: Array[Node3D]) -> void:
	if node == null or not is_instance_valid(node):
		return
	if shifted.has(node):
		return
	var saved_velocity := Vector3.ZERO
	var had_velocity := false
	if node is CharacterBody3D:
		saved_velocity = (node as CharacterBody3D).velocity
		had_velocity = true
	node.global_position -= offset
	if had_velocity:
		(node as CharacterBody3D).velocity = saved_velocity
	shifted.append(node)
