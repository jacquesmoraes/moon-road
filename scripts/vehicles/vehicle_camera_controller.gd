extends Node3D
class_name VehicleCameraController
## Smooth third-person follow camera. Modes can be added later without touching vehicle code.

enum Mode {
	THIRD_PERSON_FOLLOW,
	# Future: COCKPIT, CINEMATIC, ...
}

@export var mode: Mode = Mode.THIRD_PERSON_FOLLOW
@export var target_path: NodePath
@export var follow_distance: float = 7.5
@export var follow_height: float = 3.2
@export var follow_smoothing: float = 5.5
@export var rotation_speed: float = 3.2

const LOOK_AT_HEIGHT: float = 1.0

@onready var _camera: Camera3D = $Camera3D

var _target: Node3D
var _smoothed_yaw: float = 0.0
var _initialized: bool = false


func _ready() -> void:
	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		_target = get_parent() as Node3D

	# Leave the vehicle hierarchy so we don't inherit frame-to-frame local jitter.
	call_deferred("_detach_to_scene_root")

	if _camera:
		_camera.current = true


func _detach_to_scene_root() -> void:
	var scene := get_tree().current_scene
	if scene != null and get_parent() != scene:
		reparent(scene, true)


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return

	match mode:
		Mode.THIRD_PERSON_FOLLOW:
			_update_third_person_follow(delta)


func _update_third_person_follow(delta: float) -> void:
	var target_pos := _target.global_position
	var target_yaw := _target.global_rotation.y

	if not _initialized:
		_smoothed_yaw = target_yaw
		global_position = _desired_camera_position(target_pos, _smoothed_yaw)
		_look_at_target(target_pos)
		_initialized = true
		return

	# Lag yaw behind the vehicle so sharp steering doesn't whip the camera.
	var yaw_t := _exp_weight(rotation_speed, delta)
	_smoothed_yaw = lerp_angle(_smoothed_yaw, target_yaw, yaw_t)

	var desired := _desired_camera_position(target_pos, _smoothed_yaw)
	var pos_t := _exp_weight(follow_smoothing, delta)
	global_position = global_position.lerp(desired, pos_t)

	_look_at_target(target_pos)


func _desired_camera_position(target_pos: Vector3, yaw: float) -> Vector3:
	# Godot forward is -Z; behind the car is +local Z on the yaw plane.
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	return target_pos + back * follow_distance + Vector3.UP * follow_height


func _look_at_target(target_pos: Vector3) -> void:
	var look_point := target_pos + Vector3.UP * LOOK_AT_HEIGHT
	if look_point.distance_squared_to(global_position) < 0.0001:
		return
	look_at(look_point, Vector3.UP)


func _exp_weight(speed: float, delta: float) -> float:
	return 1.0 - exp(-maxf(speed, 0.0) * delta)


func get_camera() -> Camera3D:
	return _camera
