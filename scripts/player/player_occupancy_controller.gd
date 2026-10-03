extends Node
class_name PlayerOccupancyController
## Single source of truth for player presence: IN_VEHICLE vs ON_FOOT.
## Owns enter/exit flow; does not recreate the vehicle or wipe its parked state.
## Switches between VehicleCameraController and OnFootCameraController (no shared cam logic).

enum OccupancyState {
	IN_VEHICLE,
	ON_FOOT,
}

signal occupancy_changed(previous_state: OccupancyState, current_state: OccupancyState)

@export var vehicle_path: NodePath = NodePath("../PlayerVehicle")
@export var character_path: NodePath = NodePath("../PlayerCharacter")
@export var vehicle_camera_path: NodePath = NodePath("../VehicleCameraController")
@export var on_foot_camera_path: NodePath = NodePath("../OnFootCameraController")
@export var recenter_path: NodePath = NodePath("../WorldOriginRecenter")
## Max planar distance from vehicle origin to allow re-enter (meters).
@export var enter_distance: float = 3.5
## Fallback local offset from vehicle if DriverExitMarker is missing (left / driver side).
@export var exit_offset: Vector3 = Vector3(-1.85, 0.05, 0.25)

var _state: OccupancyState = OccupancyState.IN_VEHICLE
var _vehicle: Node3D
var _character: Node3D
var _vehicle_camera: Node3D
var _on_foot_camera: Node3D
var _recenter: Node


func _ready() -> void:
	_resolve_refs()
	_apply_in_vehicle(false)


func _unhandled_input(event: InputEvent) -> void:
	# Exit / enter share E by default; gate on occupancy so only one path runs.
	if (
		_state == OccupancyState.IN_VEHICLE
		and event.is_action_pressed("player_exit_vehicle")
	):
		try_exit_vehicle()
		get_viewport().set_input_as_handled()
		return
	if (
		_state == OccupancyState.ON_FOOT
		and event.is_action_pressed("player_enter_vehicle")
	):
		try_enter_vehicle()
		get_viewport().set_input_as_handled()
		return


func get_state() -> OccupancyState:
	return _state


func get_state_name() -> String:
	match _state:
		OccupancyState.ON_FOOT:
			return "ON_FOOT"
		_:
			return "IN_VEHICLE"


func is_in_vehicle() -> bool:
	return _state == OccupancyState.IN_VEHICLE


func is_on_foot() -> bool:
	return _state == OccupancyState.ON_FOOT


func can_exit_vehicle() -> bool:
	_resolve_refs()
	if _state != OccupancyState.IN_VEHICLE or _vehicle == null:
		return false
	if _vehicle.has_method("is_parked") and not bool(_vehicle.call("is_parked")):
		return false
	if _vehicle.has_method("get_signed_speed") and absf(float(_vehicle.call("get_signed_speed"))) > 0.05:
		return false
	return true


func can_enter_vehicle() -> bool:
	_resolve_refs()
	if _state != OccupancyState.ON_FOOT or _vehicle == null or _character == null:
		return false
	if _vehicle.has_method("is_parked") and not bool(_vehicle.call("is_parked")):
		return false
	var delta := _character.global_position - _vehicle.global_position
	delta.y = 0.0
	return delta.length() <= maxf(enter_distance, 0.5)


func try_exit_vehicle() -> bool:
	if not can_exit_vehicle():
		return false
	_set_state(OccupancyState.ON_FOOT)
	return true


func try_enter_vehicle() -> bool:
	if not can_enter_vehicle():
		return false
	_set_state(OccupancyState.IN_VEHICLE)
	return true


func get_vehicle() -> Node3D:
	_resolve_refs()
	return _vehicle


func get_character() -> Node3D:
	_resolve_refs()
	return _character


func get_on_foot_camera() -> Node3D:
	_resolve_refs()
	return _on_foot_camera


func get_vehicle_camera() -> Node3D:
	_resolve_refs()
	return _vehicle_camera


func _set_state(next: OccupancyState) -> void:
	if next == _state:
		return
	var previous := _state
	_state = next
	match _state:
		OccupancyState.ON_FOOT:
			_apply_on_foot()
		OccupancyState.IN_VEHICLE:
			_apply_in_vehicle(true)
	occupancy_changed.emit(previous, _state)


func _apply_on_foot() -> void:
	_resolve_refs()
	if _vehicle != null and _vehicle.has_method("set_manual_control_enabled"):
		_vehicle.call("set_manual_control_enabled", false)

	var exit_xf := _compute_exit_transform()
	if _character != null:
		if _character.has_method("activate_at"):
			_character.call("activate_at", exit_xf)
		else:
			_character.global_transform = exit_xf
			_character.visible = true
		if _on_foot_camera != null and _character.has_method("set_camera_ref"):
			_character.call("set_camera_ref", _on_foot_camera)

	# Disable vehicle cam; enable dedicated on-foot cam (do not reuse car shot logic).
	if _vehicle_camera != null:
		if _vehicle_camera.has_method("set_cinematic_active"):
			_vehicle_camera.call("set_cinematic_active", false)
		var vcam: Camera3D = null
		if _vehicle_camera.has_method("get_camera"):
			vcam = _vehicle_camera.call("get_camera") as Camera3D
		if vcam != null:
			vcam.current = false

	if _on_foot_camera != null:
		if _on_foot_camera.has_method("set_follow_target") and _character != null:
			_on_foot_camera.call("set_follow_target", _character)
		if _on_foot_camera.has_method("set_active"):
			_on_foot_camera.call("set_active", true)

	if _recenter != null and _recenter.has_method("set_recenter_target") and _character != null:
		_recenter.call("set_recenter_target", _character)


func _apply_in_vehicle(from_foot: bool) -> void:
	_resolve_refs()

	if _on_foot_camera != null and _on_foot_camera.has_method("set_active"):
		_on_foot_camera.call("set_active", false)

	if _character != null:
		if _character.has_method("deactivate"):
			_character.call("deactivate")
		else:
			_character.visible = false

	if _vehicle != null and _vehicle.has_method("set_manual_control_enabled"):
		_vehicle.call("set_manual_control_enabled", true)

	if _vehicle_camera != null:
		if _vehicle_camera.has_method("set_follow_target") and _vehicle != null:
			_vehicle_camera.call("set_follow_target", _vehicle)
		if from_foot and _vehicle_camera.has_method("set_mode"):
			_vehicle_camera.call("set_mode", 0)  # FOLLOW
		var vcam: Camera3D = null
		if _vehicle_camera.has_method("get_camera"):
			vcam = _vehicle_camera.call("get_camera") as Camera3D
		if vcam != null:
			vcam.current = true

	if _recenter != null and _recenter.has_method("set_recenter_target") and _vehicle != null:
		_recenter.call("set_recenter_target", _vehicle)


func _compute_exit_transform() -> Transform3D:
	if _vehicle == null:
		return Transform3D.IDENTITY

	var marker := _vehicle.get_node_or_null("DriverExitMarker") as Marker3D
	var xf: Transform3D
	if marker != null:
		xf = marker.global_transform
	else:
		xf = _vehicle.global_transform * Transform3D(Basis.IDENTITY, exit_offset)

	xf.basis = Basis(Vector3.UP, _vehicle.global_rotation.y)
	return xf


func _resolve_refs() -> void:
	if vehicle_path != NodePath():
		_vehicle = get_node_or_null(vehicle_path) as Node3D
	if _vehicle == null and get_tree() != null and get_tree().current_scene != null:
		_vehicle = get_tree().current_scene.find_child("PlayerVehicle", true, false) as Node3D

	if character_path != NodePath():
		_character = get_node_or_null(character_path) as Node3D
	if _character == null and get_tree() != null and get_tree().current_scene != null:
		_character = get_tree().current_scene.find_child("PlayerCharacter", true, false) as Node3D

	if vehicle_camera_path != NodePath():
		_vehicle_camera = get_node_or_null(vehicle_camera_path) as Node3D
	if _vehicle_camera == null and get_tree() != null and get_tree().current_scene != null:
		_vehicle_camera = get_tree().current_scene.find_child("VehicleCameraController", true, false) as Node3D

	if on_foot_camera_path != NodePath():
		_on_foot_camera = get_node_or_null(on_foot_camera_path) as Node3D
	if _on_foot_camera == null and get_tree() != null and get_tree().current_scene != null:
		_on_foot_camera = get_tree().current_scene.find_child("OnFootCameraController", true, false) as Node3D

	if recenter_path != NodePath():
		_recenter = get_node_or_null(recenter_path)
	if _recenter == null and get_tree() != null and get_tree().current_scene != null:
		_recenter = get_tree().current_scene.find_child("WorldOriginRecenter", true, false)
