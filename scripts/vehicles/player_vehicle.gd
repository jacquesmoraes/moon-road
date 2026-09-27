extends CharacterBody3D
## Arcade-style player vehicle. Light feel, not a physics sim.

@export var acceleration: float = 18.0
@export var braking: float = 32.0
@export var max_speed: float = 24.0
@export var steering_strength: float = 2.4
@export var drag: float = 5.0

## Signed forward speed along local -Z (positive = forward).
var _speed: float = 0.0

const GRAVITY: float = 24.0
const REVERSE_SPEED_FACTOR: float = 0.4
const STEER_SPEED_REF: float = 8.0


func _physics_process(delta: float) -> void:
	var accel_input := Input.get_action_strength("vehicle_accelerate")
	var brake_input := Input.get_action_strength("vehicle_brake")
	var steer_input := Input.get_axis("vehicle_left", "vehicle_right")

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


func _apply_longitudinal(accel_input: float, brake_input: float, delta: float) -> void:
	if accel_input > 0.0:
		_speed += acceleration * accel_input * delta
	elif brake_input > 0.0:
		if _speed > 0.15:
			_speed -= braking * brake_input * delta
			if _speed < 0.0:
				_speed = 0.0
		else:
			_speed -= acceleration * REVERSE_SPEED_FACTOR * brake_input * delta
	else:
		var drag_step := drag * delta
		if absf(_speed) <= drag_step:
			_speed = 0.0
		else:
			_speed -= signf(_speed) * drag_step

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
