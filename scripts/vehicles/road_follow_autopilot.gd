extends Node
class_name RoadFollowAutopilot
## Keeps the vehicle centered on RoadManager segments. Not a generic pathfinder.
## Enables cruise for speed; steers via vehicle steer override. Cancel anytime via input.

@export var vehicle_path: NodePath
@export var road_manager_path: NodePath = NodePath("../../RoadManager")
@export var look_ahead_distance: float = 14.0
@export var lateral_gain: float = 0.28
@export var heading_gain: float = 1.35
@export var pursuit_gain: float = 1.1
@export var enable_cruise_when_active: bool = true

var _vehicle: Node3D
var _road_manager: Node
var _active: bool = false


func _ready() -> void:
	_resolve_refs()


func _physics_process(_delta: float) -> void:
	if Input.is_action_just_pressed("vehicle_autopilot_toggle"):
		set_autopilot_active(not _active)
	if Input.is_action_just_pressed("vehicle_autopilot_cancel"):
		set_autopilot_active(false)

	if not _active:
		return

	# Immediate cancel on manual intervene.
	if (
		Input.get_action_strength("vehicle_brake") > 0.1
		or absf(Input.get_axis("vehicle_left", "vehicle_right")) > 0.1
	):
		set_autopilot_active(false)
		return

	if _vehicle == null or not is_instance_valid(_vehicle):
		_resolve_refs()
		if _vehicle == null:
			set_autopilot_active(false)
			return
	if _road_manager == null or not is_instance_valid(_road_manager):
		_resolve_refs()
		if _road_manager == null:
			return

	var sample: Dictionary = _road_manager.call("sample_road", _vehicle.global_position, look_ahead_distance)
	if sample.is_empty():
		return

	var steer: float = _compute_steer(sample)
	if _vehicle.has_method("set_steer_override"):
		_vehicle.call("set_steer_override", steer, true)


func is_autopilot_active() -> bool:
	return _active


func set_autopilot_active(active: bool) -> void:
	_resolve_refs()
	if active == _active:
		if active and _vehicle != null and _vehicle.has_method("set_steer_override"):
			_vehicle.call("set_steer_override", 0.0, true)
		return

	_active = active
	if _vehicle == null:
		_active = false
		return

	if _active:
		if enable_cruise_when_active and _vehicle.has_method("set_cruise_control_active"):
			_vehicle.call("set_cruise_control_active", true)
		if _vehicle.has_method("set_steer_override"):
			_vehicle.call("set_steer_override", 0.0, true)
	else:
		if _vehicle.has_method("set_steer_override"):
			_vehicle.call("set_steer_override", 0.0, false)


func _compute_steer(sample: Dictionary) -> float:
	var lateral: float = float(sample.get("lateral", 0.0))
	var road_forward: Vector3 = sample.get("forward", Vector3.FORWARD) as Vector3
	var look_at: Vector3 = sample.get("look_at", _vehicle.global_position) as Vector3

	var vehicle_forward: Vector3 = -_vehicle.global_transform.basis.z
	vehicle_forward.y = 0.0
	if vehicle_forward.length_squared() < 0.0001:
		vehicle_forward = Vector3.FORWARD
	else:
		vehicle_forward = vehicle_forward.normalized()

	road_forward.y = 0.0
	if road_forward.length_squared() > 0.0001:
		road_forward = road_forward.normalized()

	# Positive cross.y => road forward is to the right of vehicle forward => steer right.
	var heading_err: float = vehicle_forward.x * road_forward.z - vehicle_forward.z * road_forward.x

	var to_look: Vector3 = look_at - _vehicle.global_position
	to_look.y = 0.0
	var pursuit: float = 0.0
	if to_look.length_squared() > 0.0001:
		to_look = to_look.normalized()
		var vehicle_right: Vector3 = _vehicle.global_transform.basis.x
		vehicle_right.y = 0.0
		if vehicle_right.length_squared() > 0.0001:
			vehicle_right = vehicle_right.normalized()
			pursuit = vehicle_right.dot(to_look)

	# lateral > 0 => right of center => steer left (negative).
	var steer: float = (-lateral * lateral_gain) + (heading_err * heading_gain) + (pursuit * pursuit_gain)
	return clampf(steer, -1.0, 1.0)


func _resolve_refs() -> void:
	if vehicle_path != NodePath():
		_vehicle = get_node_or_null(vehicle_path) as Node3D
	if _vehicle == null:
		_vehicle = get_parent() as Node3D

	if road_manager_path != NodePath():
		_road_manager = get_node_or_null(road_manager_path)
	if _road_manager == null and get_tree().current_scene != null:
		_road_manager = get_tree().current_scene.find_child("RoadManager", true, false)
