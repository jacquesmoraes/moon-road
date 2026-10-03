extends CharacterBody3D
## Arcade-style player vehicle. Light feel, not a physics sim.
## Assisted driving state lives in DrivingModeController (MANUAL / CRUISE / TRAVEL_MODE).
## Motion state is DRIVING / PARKED (explicit — not scattered booleans).

enum MotionState {
	DRIVING,
	PARKED,
}

signal parking_state_changed(previous_state: MotionState, current_state: MotionState)

@export var acceleration: float = 18.0
@export var braking: float = 32.0
@export var max_speed: float = 24.0
@export var steering_strength: float = 2.4
@export var drag: float = 5.0

## Target hold speed for cruise / travel mode (km/h). Clamped to max_speed in m/s.
@export var cruise_target_speed_kmh: float = 60.0
## Speed error (m/s) inside which cruise holds without correcting.
@export var cruise_speed_deadzone: float = 0.25
## How aggressively cruise maps speed error → throttle/brake (higher = snappier).
@export var cruise_control_gain: float = 0.85

@export_group("Parking")
## Max |signed speed| (m/s) allowed to enter PARKED.
@export var max_parking_speed: float = 1.5
## When true, park requires CharacterBody3D floor contact (road, viewpoint pad, lots).
@export var require_valid_surface: bool = true

## Signed forward speed along local -Z (positive = forward).
var _speed: float = 0.0
## Legacy flag kept in sync by DrivingModeController / set_cruise_control_active.
var _cruise_active: bool = false
var _steer_override_enabled: bool = false
var _steer_override: float = 0.0
var _mode_controller: Node
var _motion_state: MotionState = MotionState.DRIVING
## False while the player is on foot (occupancy). Parked physics still run.
var _manual_control_enabled: bool = true

const GRAVITY: float = 24.0
const REVERSE_SPEED_FACTOR: float = 0.4
const STEER_SPEED_REF: float = 8.0
const MS_TO_KMH: float = 3.6


func _ready() -> void:
	_mode_controller = get_node_or_null("DrivingModeController")


func _unhandled_input(event: InputEvent) -> void:
	if not _manual_control_enabled:
		return
	if event.is_action_pressed("vehicle_park"):
		toggle_park()
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	# Cruise / travel toggles are owned by DrivingModeController when present.
	if (
		_manual_control_enabled
		and _motion_state == MotionState.DRIVING
		and _mode_controller == null
		and Input.is_action_just_pressed("vehicle_cruise_toggle")
	):
		_toggle_cruise_control()

	if _motion_state == MotionState.PARKED:
		_update_parked(delta)
		return

	# On foot: never drive even if somehow left in DRIVING.
	if not _manual_control_enabled:
		_speed = 0.0
		velocity = Vector3.ZERO
		move_and_slide()
		return

	var accel_input := Input.get_action_strength("vehicle_accelerate")
	var brake_input := Input.get_action_strength("vehicle_brake")
	var steer_input := (
		_steer_override
		if _steer_override_enabled
		else Input.get_axis("vehicle_left", "vehicle_right")
	)

	_apply_longitudinal(accel_input, brake_input, delta)
	_apply_steering(steer_input, delta)

	var forward := -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	else:
		forward = Vector3.FORWARD

	if is_on_floor():
		# Follow gentle road grades instead of pushing horizontally into the slope.
		var floor_n := get_floor_normal()
		var along := floor_n.cross(forward.cross(floor_n))
		if along.length_squared() > 0.0001:
			along = along.normalized()
			if along.dot(forward) < 0.0:
				along = -along
			velocity = along * _speed
		else:
			velocity = Vector3(forward.x, 0.0, forward.z) * _speed
	else:
		velocity.x = forward.x * _speed
		velocity.z = forward.z * _speed
		velocity.y -= GRAVITY * delta

	move_and_slide()

	if not is_finite(_speed) or not velocity.is_finite():
		push_error("PlayerVehicle became unstable; resetting motion.")
		_speed = 0.0
		velocity = Vector3.ZERO
		_cruise_active = false
		if _mode_controller != null and _mode_controller.has_method("set_mode"):
			_mode_controller.call("set_mode", 0)  # MANUAL


func _update_parked(_delta: float) -> void:
	## Hold the parked world pose. Do not freefall or slope-slide — the player left the
	## car here (validated by can_park). Origin recenter still moves us explicitly.
	_speed = 0.0
	_steer_override = 0.0
	_steer_override_enabled = false
	velocity = Vector3.ZERO


func toggle_park() -> void:
	if _motion_state == MotionState.PARKED:
		try_unpark()
	else:
		try_park()


## Attempts to enter PARKED. Returns true on success.
func try_park() -> bool:
	if _motion_state == MotionState.PARKED:
		return true
	if not _manual_control_enabled:
		return false
	if not can_park():
		return false
	_set_motion_state(MotionState.PARKED)
	return true


## Leaves PARKED and returns to DRIVING. Returns true on success.
func try_unpark() -> bool:
	if _motion_state == MotionState.DRIVING:
		return true
	# Stay PARKED while the player is outside the vehicle.
	if not _manual_control_enabled:
		return false
	_set_motion_state(MotionState.DRIVING)
	return true


func can_park() -> bool:
	if not _manual_control_enabled:
		return false
	if absf(_speed) > maxf(max_parking_speed, 0.0):
		return false
	if require_valid_surface and not is_on_floor():
		return false
	return true


func is_parked() -> bool:
	return _motion_state == MotionState.PARKED


func is_driving() -> bool:
	return _motion_state == MotionState.DRIVING


func get_motion_state() -> MotionState:
	return _motion_state


func get_motion_state_name() -> String:
	match _motion_state:
		MotionState.PARKED:
			return "PARKED"
		_:
			return "DRIVING"


## Occupancy: disable while ON_FOOT so WASD / park do not affect the parked car.
func set_manual_control_enabled(enabled: bool) -> void:
	_manual_control_enabled = enabled
	if not _manual_control_enabled:
		_cruise_active = false
		_steer_override = 0.0
		_steer_override_enabled = false
		if _mode_controller != null and _mode_controller.has_method("set_mode"):
			_mode_controller.call("set_mode", 0)  # MANUAL


func is_manual_control_enabled() -> bool:
	return _manual_control_enabled


## World-space transform for spawning the on-foot character (DriverExitMarker).
func get_driver_exit_global_transform() -> Transform3D:
	var marker := get_node_or_null("DriverExitMarker") as Node3D
	if marker != null:
		return marker.global_transform
	return global_transform * Transform3D(Basis.IDENTITY, Vector3(-1.85, 0.05, 0.25))


func _set_motion_state(state: MotionState) -> void:
	if state == _motion_state:
		return
	var previous := _motion_state
	_motion_state = state
	if _motion_state == MotionState.PARKED:
		_enter_parked()
	parking_state_changed.emit(previous, _motion_state)


func _enter_parked() -> void:
	_speed = 0.0
	velocity = Vector3.ZERO
	_cruise_active = false
	_steer_override = 0.0
	_steer_override_enabled = false
	# Cancel assisted modes immediately — Cruise / Travel must not stay active.
	if _mode_controller != null and _mode_controller.has_method("set_mode"):
		_mode_controller.call("set_mode", 0)  # MANUAL


func _toggle_cruise_control() -> void:
	if _motion_state == MotionState.PARKED:
		return
	if _cruise_active:
		_cruise_active = false
		return
	if get_cruise_target_speed_ms() <= 0.05:
		return
	_cruise_active = true


func _wants_speed_hold() -> bool:
	if _motion_state == MotionState.PARKED:
		return false
	if _mode_controller != null and _mode_controller.has_method("is_speed_hold_active"):
		return bool(_mode_controller.call("is_speed_hold_active"))
	return _cruise_active


func _apply_longitudinal(accel_input: float, brake_input: float, delta: float) -> void:
	if brake_input > 0.0:
		_cruise_active = false
		if _speed > 0.15:
			_speed -= braking * brake_input * delta
			if _speed < 0.0:
				_speed = 0.0
		else:
			_speed -= acceleration * REVERSE_SPEED_FACTOR * brake_input * delta
		_clamp_speed()
		return

	if _wants_speed_hold() and accel_input <= 0.0:
		_apply_cruise_hold(delta)
		_clamp_speed()
		return

	if accel_input > 0.0:
		_speed += acceleration * accel_input * delta
	else:
		var drag_step := drag * delta
		if absf(_speed) <= drag_step:
			_speed = 0.0
		else:
			_speed -= signf(_speed) * drag_step

	_clamp_speed()


func _apply_cruise_hold(delta: float) -> void:
	var target_ms := get_cruise_target_speed_ms()
	var error := target_ms - _speed

	if absf(error) <= cruise_speed_deadzone:
		return

	if error > 0.0:
		var throttle := clampf(error * cruise_control_gain, 0.0, 1.0)
		_speed += acceleration * throttle * delta
	else:
		var brake_str := clampf(-error * cruise_control_gain, 0.15, 1.0)
		_speed -= braking * 0.65 * brake_str * delta
		if _speed < 0.0:
			_speed = 0.0


func _clamp_speed() -> void:
	var min_speed := -max_speed * REVERSE_SPEED_FACTOR
	_speed = clampf(_speed, min_speed, max_speed)


func _apply_steering(steer_input: float, delta: float) -> void:
	if is_zero_approx(steer_input) or is_zero_approx(_speed):
		return

	var speed_factor := clampf(absf(_speed) / STEER_SPEED_REF, 0.0, 1.0)
	var yaw := -steer_input * steering_strength * speed_factor * signf(_speed) * delta
	rotate_y(yaw)


func get_signed_speed() -> float:
	return _speed


func get_speed_kmh() -> float:
	return _speed * MS_TO_KMH


func is_cruise_control_active() -> bool:
	return _wants_speed_hold()


func get_cruise_target_speed_kmh() -> float:
	return cruise_target_speed_kmh


func get_cruise_target_speed_ms() -> float:
	return clampf(cruise_target_speed_kmh / MS_TO_KMH, 0.0, max_speed)


func set_cruise_control_active(active: bool) -> void:
	if _motion_state == MotionState.PARKED:
		_cruise_active = false
		return
	if active:
		if get_cruise_target_speed_ms() <= 0.05:
			_cruise_active = false
			return
		_cruise_active = true
	else:
		_cruise_active = false


func set_steer_override(value: float, enabled: bool) -> void:
	if _motion_state == MotionState.PARKED:
		_steer_override = 0.0
		_steer_override_enabled = false
		return
	_steer_override = clampf(value, -1.0, 1.0)
	_steer_override_enabled = enabled


func is_steer_override_enabled() -> bool:
	return _steer_override_enabled


func get_driving_mode_name() -> String:
	if _mode_controller != null and _mode_controller.has_method("get_mode_name"):
		return str(_mode_controller.call("get_mode_name"))
	if _wants_speed_hold():
		return "CRUISE"
	return "MANUAL"


func is_travel_mode() -> bool:
	if _motion_state == MotionState.PARKED:
		return false
	if _mode_controller != null and _mode_controller.has_method("is_travel_mode"):
		return bool(_mode_controller.call("is_travel_mode"))
	return false
