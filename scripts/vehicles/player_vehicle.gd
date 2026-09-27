extends CharacterBody3D
## Arcade-style player vehicle. Light feel, not a physics sim.
## Assisted driving state lives in DrivingModeController (MANUAL / CRUISE / TRAVEL_MODE).

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

## Signed forward speed along local -Z (positive = forward).
var _speed: float = 0.0
## Legacy flag kept in sync by DrivingModeController / set_cruise_control_active.
var _cruise_active: bool = false
var _steer_override_enabled: bool = false
var _steer_override: float = 0.0
var _mode_controller: Node

const GRAVITY: float = 24.0
const REVERSE_SPEED_FACTOR: float = 0.4
const STEER_SPEED_REF: float = 8.0
const MS_TO_KMH: float = 3.6


func _ready() -> void:
	_mode_controller = get_node_or_null("DrivingModeController")


func _physics_process(delta: float) -> void:
	# Cruise / travel toggles are owned by DrivingModeController when present.
	if _mode_controller == null and Input.is_action_just_pressed("vehicle_cruise_toggle"):
		_toggle_cruise_control()

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


func _toggle_cruise_control() -> void:
	if _cruise_active:
		_cruise_active = false
		return
	if get_cruise_target_speed_ms() <= 0.05:
		return
	_cruise_active = true


func _wants_speed_hold() -> bool:
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
	if active:
		if get_cruise_target_speed_ms() <= 0.05:
			_cruise_active = false
			return
		_cruise_active = true
	else:
		_cruise_active = false


func set_steer_override(value: float, enabled: bool) -> void:
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
	if _mode_controller != null and _mode_controller.has_method("is_travel_mode"):
		return bool(_mode_controller.call("is_travel_mode"))
	return false
