extends Node3D
class_name VehicleCameraController
## Multi-mode vehicle camera. Does not affect vehicle physics or driving modes.
## Detached from the vehicle hierarchy so origin recentering only shifts world pose.

enum CameraMode {
	FOLLOW,
	FAR,
	HOOD,
	PASSENGER,
	WINDOW,
}

signal mode_changed(mode: CameraMode)

@export var target_path: NodePath
@export var mode: CameraMode = CameraMode.FOLLOW:
	set(value):
		if mode == value:
			return
		mode = value
		_on_mode_changed()

@export_group("FOLLOW (default chase)")
@export var follow_distance: float = 7.5
@export var follow_height: float = 3.2
@export var follow_smoothing: float = 5.5
@export var follow_rotation_speed: float = 3.2
@export var follow_fov: float = 70.0

@export_group("FAR")
@export var far_distance: float = 16.0
@export var far_height: float = 6.5
@export var far_smoothing: float = 4.0
@export var far_rotation_speed: float = 2.4
@export var far_fov: float = 85.0

@export_group("HOOD")
@export var hood_offset: Vector3 = Vector3(0.0, 1.05, -1.35)
@export var hood_look: Vector3 = Vector3(0.0, 1.0, -12.0)
@export var hood_smoothing: float = 14.0
@export var hood_fov: float = 78.0

@export_group("PASSENGER")
@export var passenger_offset: Vector3 = Vector3(0.42, 1.2, 0.15)
@export var passenger_look: Vector3 = Vector3(0.2, 1.05, -14.0)
@export var passenger_smoothing: float = 12.0
@export var passenger_fov: float = 70.0

@export_group("WINDOW")
@export var window_offset: Vector3 = Vector3(0.95, 1.25, 0.1)
@export var window_look: Vector3 = Vector3(14.0, 1.4, -4.0)
@export var window_smoothing: float = 10.0
@export var window_fov: float = 82.0

## Legacy alias kept for existing scenes / README knobs.
@export var rotation_speed: float = 3.2:
	set(value):
		rotation_speed = value
		follow_rotation_speed = value

const LOOK_AT_HEIGHT: float = 1.0
const MODE_CYCLE: Array[CameraMode] = [
	CameraMode.FOLLOW,
	CameraMode.FAR,
	CameraMode.HOOD,
	CameraMode.PASSENGER,
	CameraMode.WINDOW,
]

@onready var _camera: Camera3D = $Camera3D

var _target: Node3D
var _smoothed_yaw: float = 0.0
var _initialized: bool = false


func _ready() -> void:
	# Keep scene-export alias in sync with FOLLOW rotation.
	follow_rotation_speed = rotation_speed

	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		_target = get_parent() as Node3D

	# Leave the vehicle hierarchy so we don't inherit frame-to-frame local jitter.
	call_deferred("_detach_to_scene_root")

	if _camera:
		_camera.current = true
		_apply_fov()


func _detach_to_scene_root() -> void:
	var scene := get_tree().current_scene
	if scene != null and get_parent() != scene:
		reparent(scene, true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("vehicle_camera_next"):
		cycle_mode(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("vehicle_camera_previous"):
		cycle_mode(-1)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return

	match mode:
		CameraMode.FOLLOW:
			_update_chase(delta, follow_distance, follow_height, follow_smoothing, follow_rotation_speed)
		CameraMode.FAR:
			_update_chase(delta, far_distance, far_height, far_smoothing, far_rotation_speed)
		CameraMode.HOOD:
			_update_rigged(delta, hood_offset, hood_look, hood_smoothing)
		CameraMode.PASSENGER:
			_update_rigged(delta, passenger_offset, passenger_look, passenger_smoothing)
		CameraMode.WINDOW:
			_update_rigged(delta, window_offset, window_look, window_smoothing)


func get_mode() -> CameraMode:
	return mode


func get_mode_name() -> String:
	match mode:
		CameraMode.FAR:
			return "FAR"
		CameraMode.HOOD:
			return "HOOD"
		CameraMode.PASSENGER:
			return "PASSENGER"
		CameraMode.WINDOW:
			return "WINDOW"
		_:
			return "FOLLOW"


func set_mode(new_mode: CameraMode) -> void:
	mode = new_mode


func cycle_mode(direction: int = 1) -> void:
	var idx := MODE_CYCLE.find(mode)
	if idx < 0:
		idx = 0
	var step := 1 if direction >= 0 else -1
	idx = (idx + step) % MODE_CYCLE.size()
	if idx < 0:
		idx += MODE_CYCLE.size()
	mode = MODE_CYCLE[idx]


func get_camera() -> Camera3D:
	return _camera


## Origin recenter already shifts global_position; keep chase yaw continuous.
func notify_origin_shifted(_offset: Vector3) -> void:
	pass


func _on_mode_changed() -> void:
	_initialized = false
	_apply_fov()
	mode_changed.emit(mode)


func _apply_fov() -> void:
	if _camera == null:
		return
	_camera.fov = _fov_for_mode(mode)


func _fov_for_mode(m: CameraMode) -> float:
	match m:
		CameraMode.FAR:
			return far_fov
		CameraMode.HOOD:
			return hood_fov
		CameraMode.PASSENGER:
			return passenger_fov
		CameraMode.WINDOW:
			return window_fov
		_:
			return follow_fov


func _update_chase(
	delta: float,
	distance: float,
	height: float,
	pos_smoothing: float,
	yaw_speed: float
) -> void:
	var target_pos := _target.global_position
	var target_yaw := _target.global_rotation.y

	if not _initialized:
		_smoothed_yaw = target_yaw
		global_position = _chase_position(target_pos, _smoothed_yaw, distance, height)
		_look_at_world(target_pos + Vector3.UP * LOOK_AT_HEIGHT)
		_initialized = true
		return

	var yaw_t := _exp_weight(yaw_speed, delta)
	_smoothed_yaw = lerp_angle(_smoothed_yaw, target_yaw, yaw_t)

	var desired := _chase_position(target_pos, _smoothed_yaw, distance, height)
	var pos_t := _exp_weight(pos_smoothing, delta)
	global_position = global_position.lerp(desired, pos_t)
	_look_at_world(target_pos + Vector3.UP * LOOK_AT_HEIGHT)


func _update_rigged(
	delta: float,
	local_offset: Vector3,
	local_look: Vector3,
	pos_smoothing: float
) -> void:
	var xf := _target.global_transform
	var desired := xf * local_offset
	var look_point := xf * local_look

	if not _initialized:
		global_position = desired
		_look_at_world(look_point)
		_smoothed_yaw = _target.global_rotation.y
		_initialized = true
		return

	var pos_t := _exp_weight(pos_smoothing, delta)
	global_position = global_position.lerp(desired, pos_t)
	_look_at_world(look_point)


func _chase_position(target_pos: Vector3, yaw: float, distance: float, height: float) -> Vector3:
	# Godot forward is -Z; behind the car is +local Z on the yaw plane.
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	return target_pos + back * distance + Vector3.UP * height


func _look_at_world(look_point: Vector3) -> void:
	if look_point.distance_squared_to(global_position) < 0.0001:
		return
	look_at(look_point, Vector3.UP)


func _exp_weight(speed: float, delta: float) -> float:
	return 1.0 - exp(-maxf(speed, 0.0) * delta)
