extends CharacterBody3D
## Arcade-style player vehicle. Light feel, not a physics sim.

@export var acceleration: float = 18.0
@export var braking: float = 32.0
@export var max_speed: float = 24.0
@export var steering_strength: float = 2.4
@export var drag: float = 5.0

## Target hold speed for cruise control (km/h). Clamped to max_speed in m/s.
@export var cruise_target_speed_kmh: float = 60.0
## Speed error (m/s) inside which cruise holds without correcting.
@export var cruise_speed_deadzone: float = 0.25
## How aggressively cruise maps speed error → throttle/brake (higher = snappier).
@export var cruise_control_gain: float = 0.85

## Signed forward speed along local -Z (positive = forward).
var _speed: float = 0.0
var _cruise_active: bool = false
var _steer_override_enabled: bool = false
var _steer_override: float = 0.0

const GRAVITY: float = 24.0
const REVERSE_SPEED_FACTOR: float = 0.4
const STEER_SPEED_REF: float = 8.0
const MS_TO_KMH: float = 3.6


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("vehicle_cruise_toggle"):
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

	velocity.x = forward.x * _speed
	velocity.z = forward.z * _speed

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	move_and_slide()

	if not is_finite(_speed) or not velocity.is_finite():
		push_error("PlayerVehicle became unstable; resetting motion.")
		_speed = 0.0
		velocity = Vector3.ZERO
		_cruise_active = false


func _toggle_cruise_control() -> void:
	if _cruise_active:
		_cruise_active = false
		return
	# Cruise only engages for forward travel toward a positive target.
	if get_cruise_target_speed_ms() <= 0.05:
		return
	_cruise_active = true


func _apply_longitudinal(accel_input: float, brake_input: float, delta: float) -> void:
	# Manual brake always cancels cruise, then applies normal braking/reverse.
	if brake_input > 0.0:
		if _cruise_active:
			_cruise_active = false
		if _speed > 0.15:
			_speed -= braking * brake_input * delta
			if _speed < 0.0:
				_speed = 0.0
		else:
			_speed -= acceleration * REVERSE_SPEED_FACTOR * brake_input * delta
		_clamp_speed()
		return

	# Cruise holds target when the player is not manually accelerating.
	if _cruise_active and accel_input <= 0.0:
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

	# Inside deadzone: hold speed (skip drag so we don't oscillate around the set point).
	if absf(error) <= cruise_speed_deadzone:
		return

	if error > 0.0:
		var throttle := clampf(error * cruise_control_gain, 0.0, 1.0)
		_speed += acceleration * throttle * delta
	else:
		# Smooth settle down to target (still gentler than full manual braking).
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

	# Stronger turn as speed rises; weak near standstill (no spin-in-place).
	var speed_factor := clampf(absf(_speed) / STEER_SPEED_REF, 0.0, 1.0)
	var yaw := -steer_input * steering_strength * speed_factor * signf(_speed) * delta
	rotate_y(yaw)


func get_signed_speed() -> float:
	return _speed


## Speed in km/h (signed: negative while reversing). Assumes 1 world unit = 1 meter.
func get_speed_kmh() -> float:
	return _speed * MS_TO_KMH


func is_cruise_control_active() -> bool:
	return _cruise_active


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


## Used by RoadFollowAutopilot. When enabled, replaces manual steer axis.
func set_steer_override(value: float, enabled: bool) -> void:
	_steer_override = clampf(value, -1.0, 1.0)
	_steer_override_enabled = enabled


func is_steer_override_enabled() -> bool:
	return _steer_override_enabled
