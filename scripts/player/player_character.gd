extends CharacterBody3D
class_name PlayerCharacter
## On-foot locomotion. Visual lives under Model — swap meshes later without changing control.
## Movement is camera-relative; look/orbit lives in OnFootCameraController (not vehicle cam).

signal control_enabled_changed(enabled: bool)

@export_group("Movement")
@export var walk_speed: float = 3.2
@export var run_speed: float = 6.5
@export var acceleration: float = 22.0
@export var deceleration: float = 28.0
@export var turn_speed: float = 12.0
@export var gravity: float = 28.0
## Small ledge height the body may step onto when blocked (meters).
@export var max_step_height: float = 0.4
@export var step_forward_distance: float = 0.28

@export_group("Refs")
## On-foot camera (preferred). Falls back to any Node3D with get_look_yaw().
@export var camera_path: NodePath

var _control_enabled: bool = false
var _camera: Node3D
var _active_collision_layer: int = 4


func _ready() -> void:
	_active_collision_layer = collision_layer if collision_layer != 0 else 4
	floor_snap_length = 0.2
	floor_max_angle = deg_to_rad(50.0)
	floor_constant_speed = true
	_resolve_camera()
	if not _control_enabled:
		_apply_active_state(false)


func _physics_process(delta: float) -> void:
	if not _control_enabled:
		velocity = Vector3.ZERO
		return

	# Frame-rate independent vertical integration.
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

	var wish := _read_camera_relative_wish()
	var running := Input.is_action_pressed("player_run")
	var target_speed := run_speed if running else walk_speed
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if wish.length_squared() > 0.0001:
		wish = wish.normalized()
		var target_yaw := atan2(-wish.x, -wish.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, 1.0 - exp(-turn_speed * delta))
		var desired := wish * target_speed
		horizontal = horizontal.move_toward(desired, acceleration * delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, deceleration * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	var before := global_position
	move_and_slide()

	# Try a short step-up when a low obstacle blocks planar motion.
	if (
		is_on_floor()
		and wish.length_squared() > 0.0001
		and horizontal.length_squared() > 0.01
		and global_position.distance_squared_to(before) < 0.00005
	):
		_try_step_up(wish.normalized(), delta)


func is_control_enabled() -> bool:
	return _control_enabled


func is_running() -> bool:
	return (
		_control_enabled
		and Input.is_action_pressed("player_run")
		and _planar_speed() > walk_speed * 0.6
	)


func get_planar_speed() -> float:
	return _planar_speed()


func set_control_enabled(enabled: bool) -> void:
	if enabled == _control_enabled:
		_apply_active_state(enabled)
		return
	_control_enabled = enabled
	_apply_active_state(enabled)
	control_enabled_changed.emit(enabled)


func activate_at(global_xform: Transform3D) -> void:
	global_transform = global_xform
	velocity = Vector3.ZERO
	visible = true
	set_control_enabled(true)


func deactivate() -> void:
	velocity = Vector3.ZERO
	set_control_enabled(false)
	visible = false


## Used by OnFootCameraController / occupancy to bind look source.
func set_camera_ref(camera: Node3D) -> void:
	_camera = camera
	if camera != null and is_instance_valid(camera):
		camera_path = get_path_to(camera) if camera.is_inside_tree() and is_inside_tree() else camera_path


func get_look_yaw() -> float:
	_resolve_camera()
	if _camera != null and is_instance_valid(_camera):
		if _camera.has_method("get_look_yaw"):
			return float(_camera.call("get_look_yaw"))
		return _camera.global_rotation.y
	return rotation.y


func _apply_active_state(active: bool) -> void:
	set_physics_process(active)
	if active:
		collision_layer = _active_collision_layer
		collision_mask = 3  # world + vehicle
		visible = true
	else:
		collision_layer = 0
		collision_mask = 0
		velocity = Vector3.ZERO


func _read_camera_relative_wish() -> Vector3:
	# Prefer explicit backward action name; keep legacy alias working.
	var back_strength := Input.get_action_strength("player_move_backward")
	if back_strength <= 0.0 and InputMap.has_action("player_move_back"):
		back_strength = Input.get_action_strength("player_move_back")
	var forward_strength := Input.get_action_strength("player_move_forward")
	var input_x := Input.get_axis("player_move_left", "player_move_right")
	var input_z := back_strength - forward_strength
	var local := Vector3(input_x, 0.0, input_z)
	if local.length_squared() < 0.0001:
		return Vector3.ZERO

	var yaw := get_look_yaw()
	var basis := Basis(Vector3.UP, yaw)
	return basis * local


func _try_step_up(wish_dir: Vector3, _delta: float) -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return

	var from := global_position + Vector3(0.0, 0.1, 0.0)
	var to := from + wish_dir * step_forward_distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return

	var step_from := to + Vector3(0.0, max_step_height, 0.0)
	var step_to := to + Vector3(0.0, -0.05, 0.0)
	var down := PhysicsRayQueryParameters3D.create(step_from, step_to)
	down.collision_mask = collision_mask
	down.exclude = [get_rid()]
	var floor_hit := space.intersect_ray(down)
	if floor_hit.is_empty():
		return

	var land: Vector3 = floor_hit.get("position", Vector3.ZERO)
	var rise := land.y - global_position.y
	if rise <= 0.02 or rise > max_step_height:
		return

	# Clearance check at landing height.
	var head_from := land + Vector3(0.0, 0.15, 0.0)
	var head_to := land + Vector3(0.0, 1.7, 0.0)
	var head_q := PhysicsRayQueryParameters3D.create(head_from, head_to)
	head_q.collision_mask = collision_mask
	head_q.exclude = [get_rid()]
	if not space.intersect_ray(head_q).is_empty():
		return

	global_position = land + Vector3(0.0, 0.02, 0.0)
	velocity.y = 0.0
	move_and_slide()


func _planar_speed() -> float:
	return Vector3(velocity.x, 0.0, velocity.z).length()


func _resolve_camera() -> void:
	if _camera != null and is_instance_valid(_camera):
		return
	if camera_path != NodePath():
		_camera = get_node_or_null(camera_path) as Node3D
	if _camera == null and get_tree() != null and get_tree().current_scene != null:
		_camera = get_tree().current_scene.find_child("OnFootCameraController", true, false) as Node3D
