extends CharacterBody3D
class_name PlayerCharacter
## Simple on-foot placeholder. Visual lives under Model — swap meshes later without changing control.

signal control_enabled_changed(enabled: bool)

@export var move_speed: float = 4.5
@export var acceleration: float = 18.0
@export var turn_speed: float = 10.0
## When set, horizontal movement aligns to this camera's yaw (VehicleCameraController).
@export var camera_path: NodePath

const GRAVITY: float = 24.0

var _control_enabled: bool = false
var _camera: Node3D
## Collision layer used while active (world interactions). Restored on activate.
var _active_collision_layer: int = 4


func _ready() -> void:
	_active_collision_layer = collision_layer if collision_layer != 0 else 4
	_resolve_camera()
	# Start dormant until PlayerOccupancyController activates on exit.
	if not _control_enabled:
		_apply_active_state(false)


func _physics_process(delta: float) -> void:
	if not _control_enabled:
		velocity = Vector3.ZERO
		return

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	var move := _read_move_vector()
	if move.length_squared() > 0.0001:
		move = move.normalized()
		var target_yaw := atan2(-move.x, -move.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))
		var desired := move * move_speed
		velocity.x = move_toward(velocity.x, desired.x, acceleration * delta)
		velocity.z = move_toward(velocity.z, desired.z, acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)

	move_and_slide()


func is_control_enabled() -> bool:
	return _control_enabled


func set_control_enabled(enabled: bool) -> void:
	if enabled == _control_enabled:
		_apply_active_state(enabled)
		return
	_control_enabled = enabled
	_apply_active_state(enabled)
	control_enabled_changed.emit(enabled)


## Place near the driver door and enable on-foot control.
func activate_at(global_xform: Transform3D) -> void:
	global_transform = global_xform
	velocity = Vector3.ZERO
	visible = true
	set_control_enabled(true)


## Hide and freeze without freeing — ready for a later visual swap / re-exit.
func deactivate() -> void:
	velocity = Vector3.ZERO
	set_control_enabled(false)
	visible = false


func _apply_active_state(active: bool) -> void:
	set_physics_process(active)
	if active:
		collision_layer = _active_collision_layer
		collision_mask = 1
		visible = true
	else:
		collision_layer = 0
		collision_mask = 0
		velocity = Vector3.ZERO


func _read_move_vector() -> Vector3:
	var input_x := Input.get_axis("player_move_left", "player_move_right")
	var input_z := Input.get_axis("player_move_forward", "player_move_back")
	var local := Vector3(input_x, 0.0, input_z)
	if local.length_squared() < 0.0001:
		return Vector3.ZERO

	var yaw := rotation.y
	if _camera == null or not is_instance_valid(_camera):
		_resolve_camera()
	if _camera != null and is_instance_valid(_camera):
		yaw = _camera.global_rotation.y

	var basis := Basis(Vector3.UP, yaw)
	# Camera looks down -Z; stick forward should walk into the view direction.
	return (basis * Vector3(local.x, 0.0, local.z))


func _resolve_camera() -> void:
	if camera_path != NodePath():
		_camera = get_node_or_null(camera_path) as Node3D
	if _camera == null and get_tree() != null and get_tree().current_scene != null:
		_camera = get_tree().current_scene.find_child("VehicleCameraController", true, false) as Node3D
