extends Node3D
class_name OnFootCameraController
## Dedicated on-foot camera — separate from VehicleCameraController.
## Default THIRD_PERSON; FIRST_PERSON ready for a future swap without rewriting occupancy.

enum ViewMode {
	THIRD_PERSON,
	FIRST_PERSON,
}

signal view_mode_changed(mode: ViewMode)
signal active_changed(active: bool)

@export var target_path: NodePath
@export var view_mode: ViewMode = ViewMode.THIRD_PERSON:
	set(value):
		if view_mode == value:
			return
		view_mode = value
		_initialized = false
		view_mode_changed.emit(view_mode)

@export_group("Third person")
@export var follow_distance: float = 4.2
@export var follow_height: float = 1.65
@export var follow_smoothing: float = 10.0
@export var look_at_height: float = 1.35
@export var fov_third: float = 70.0
## Pull camera in when a wall sits between pivot and desired pose.
@export var collision_avoidance: bool = true
@export var collision_margin: float = 0.25
@export var collision_mask: int = 1

@export_group("Interior (small rooms)")
@export var interior_follow_distance: float = 1.75
@export var interior_follow_height: float = 1.35

@export_group("First person (future)")
@export var first_person_offset: Vector3 = Vector3(0.0, 1.55, 0.12)
@export var fov_first: float = 78.0

@export_group("Look")
@export var mouse_sensitivity: float = 0.12
@export var min_pitch_deg: float = -55.0
@export var max_pitch_deg: float = 55.0
@export var capture_mouse_when_active: bool = true

@onready var _camera: Camera3D = $Camera3D

var _target: Node3D
var _active: bool = false
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(-12.0)
var _initialized: bool = false
var _interior_active: bool = false
var _interior_distance: float = 1.75
var _interior_height: float = 1.35
var _exterior_follow_distance: float = 4.2
var _exterior_follow_height: float = 1.65


func _ready() -> void:
	_exterior_follow_distance = follow_distance
	_exterior_follow_height = follow_height
	_interior_distance = interior_follow_distance
	_interior_height = interior_follow_height
	_resolve_target()
	if _camera:
		_camera.current = false
	set_process(false)
	set_process_unhandled_input(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity * 0.01
		_pitch -= motion.relative.y * mouse_sensitivity * 0.01
		_pitch = clampf(_pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_viewport().set_input_as_handled()
	elif (
		event is InputEventMouseButton
		and (event as InputEventMouseButton).pressed
		and capture_mouse_when_active
		and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _active:
		return
	if _target == null or not is_instance_valid(_target):
		_resolve_target()
		if _target == null:
			return
	_update_pose(delta)


func is_active() -> bool:
	return _active


func set_active(active: bool) -> void:
	if active == _active:
		if active:
			_make_current()
		return
	_active = active
	set_process(active)
	set_process_unhandled_input(active)
	if active:
		_resolve_target()
		_snap_from_target()
		_make_current()
		if capture_mouse_when_active:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		_interior_active = false
		if _camera:
			_camera.current = false
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	active_changed.emit(_active)


func set_follow_target(target: Node3D) -> void:
	_target = target
	_initialized = false
	if _active:
		_snap_from_target()


func get_follow_target() -> Node3D:
	return _target


func get_view_mode() -> ViewMode:
	return view_mode


func get_view_mode_name() -> String:
	match view_mode:
		ViewMode.FIRST_PERSON:
			return "FIRST_PERSON"
		_:
			return "THIRD_PERSON"


func set_view_mode(mode: ViewMode) -> void:
	view_mode = mode


## Horizontal look yaw used by PlayerCharacter for camera-relative walk.
func get_look_yaw() -> float:
	return _yaw


func get_look_pitch() -> float:
	return _pitch


func set_look_angles(yaw: float, pitch: float = deg_to_rad(-12.0)) -> void:
	_yaw = yaw
	_pitch = clampf(pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
	_initialized = false


## Called by InteriorVolume when the player walks into / out of a small room.
func set_interior_active(active: bool, distance: float = -1.0, height: float = -1.0) -> void:
	_interior_active = active
	if distance > 0.0:
		_interior_distance = distance
	if height > 0.0:
		_interior_height = height
	_initialized = false


func is_interior_active() -> bool:
	return _interior_active


func get_camera() -> Camera3D:
	return _camera


func notify_origin_shifted(_offset: Vector3) -> void:
	if _active:
		_initialized = false


func _make_current() -> void:
	if _camera:
		_camera.current = true


func _snap_from_target() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	_yaw = _target.global_rotation.y
	_pitch = deg_to_rad(-12.0)
	_initialized = false
	_update_pose(1.0)


func _update_pose(delta: float) -> void:
	match view_mode:
		ViewMode.FIRST_PERSON:
			_update_first_person(delta)
		_:
			_update_third_person(delta)


func _effective_follow_distance() -> float:
	return _interior_distance if _interior_active else _exterior_follow_distance


func _effective_follow_height() -> float:
	return _interior_height if _interior_active else _exterior_follow_height


func _update_third_person(delta: float) -> void:
	var pivot := _target.global_position + Vector3(0.0, look_at_height, 0.0)
	var dist := _effective_follow_distance()
	var height := _effective_follow_height()
	var orbit := Vector3(
		sin(_yaw) * cos(_pitch),
		sin(_pitch),
		cos(_yaw) * cos(_pitch)
	)
	var desired := pivot + orbit * dist + Vector3(0.0, height - look_at_height, 0.0)
	desired = _avoid_wall_clip(pivot, desired)

	if _initialized:
		var t := 1.0 - exp(-follow_smoothing * delta)
		global_position = global_position.lerp(desired, t)
	else:
		global_position = desired

	var look_basis := Basis.looking_at(pivot - global_position, Vector3.UP)
	global_transform.basis = look_basis
	if _camera:
		_camera.fov = fov_third
		_camera.rotation = Vector3.ZERO
	_initialized = true


func _avoid_wall_clip(pivot: Vector3, desired: Vector3) -> Vector3:
	if not collision_avoidance:
		return desired
	var space := get_world_3d().direct_space_state if get_world_3d() != null else null
	if space == null:
		return desired
	var query := PhysicsRayQueryParameters3D.create(pivot, desired)
	query.collision_mask = collision_mask
	query.exclude = []
	if _target != null:
		query.exclude = [_target.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return desired
	var hit_pos: Vector3 = hit.get("position", desired)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	return hit_pos + normal * collision_margin


func _update_first_person(delta: float) -> void:
	var desired := _target.global_transform * first_person_offset
	if _initialized:
		var t := 1.0 - exp(-follow_smoothing * delta)
		global_position = global_position.lerp(desired, t)
	else:
		global_position = desired
	rotation = Vector3(_pitch, _yaw, 0.0)
	if _camera:
		_camera.fov = fov_first
		_camera.rotation = Vector3.ZERO
	_initialized = true


func _resolve_target() -> void:
	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null and get_tree() != null and get_tree().current_scene != null:
		_target = get_tree().current_scene.find_child("PlayerCharacter", true, false) as Node3D
