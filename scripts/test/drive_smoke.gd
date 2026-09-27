extends SceneTree
## Headless smoke: load sandbox, drive for ~45s with maneuvers, assert stable motion.

const PHASE_ACCEL := 0
const PHASE_TURN_RIGHT := 1
const PHASE_TURN_LEFT := 2
const PHASE_BRAKE := 3
const PHASE_REVERSE_TURN := 4
const PHASE_DONE := 5

var _phase: int = PHASE_ACCEL
var _phase_time: float = 0.0
var _elapsed: float = 0.0
var _vehicle: CharacterBody3D
var _camera_rig: Node3D
var _max_abs_speed: float = 0.0
var _samples: int = 0
var _camera_follow_ok: bool = false
var _saw_speed_kmh: bool = false
var _max_speed_kmh: float = 0.0


func _initialize() -> void:
	var err := change_scene_to_file("res://scenes/test/DrivingSandbox.tscn")
	if err != OK:
		push_error("drive_smoke: failed to load DrivingSandbox (%s)" % error_string(err))
		quit(1)
		return

	create_timer(0.3).timeout.connect(_begin)


func _begin() -> void:
	_vehicle = root.find_child("PlayerVehicle", true, false) as CharacterBody3D
	if _vehicle == null:
		push_error("drive_smoke: PlayerVehicle not found")
		quit(1)
		return

	_camera_rig = root.find_child("VehicleCameraController", true, false) as Node3D
	if _camera_rig == null:
		push_error("drive_smoke: VehicleCameraController not found")
		quit(1)
		return

	_set_phase(PHASE_ACCEL)
	physics_frame.connect(_on_physics_frame)


func _set_phase(phase: int) -> void:
	Input.action_release("vehicle_accelerate")
	Input.action_release("vehicle_brake")
	Input.action_release("vehicle_left")
	Input.action_release("vehicle_right")
	_phase = phase
	_phase_time = 0.0

	match phase:
		PHASE_ACCEL:
			Input.action_press("vehicle_accelerate")
		PHASE_TURN_RIGHT:
			Input.action_press("vehicle_accelerate")
			Input.action_press("vehicle_right")
		PHASE_TURN_LEFT:
			Input.action_press("vehicle_accelerate")
			Input.action_press("vehicle_left")
		PHASE_BRAKE:
			Input.action_press("vehicle_brake")
		PHASE_REVERSE_TURN:
			Input.action_press("vehicle_brake")
			Input.action_press("vehicle_left")
		PHASE_DONE:
			_finish()


func _on_physics_frame() -> void:
	if _vehicle == null or _phase == PHASE_DONE:
		return

	var dt := 1.0 / 60.0
	_elapsed += dt
	_phase_time += dt
	_samples += 1

	var speed := 0.0
	if _vehicle.has_method("get_signed_speed"):
		speed = float(_vehicle.call("get_signed_speed"))
	_max_abs_speed = maxf(_max_abs_speed, absf(speed))

	if _vehicle.has_method("get_speed_kmh"):
		var kmh := absf(float(_vehicle.call("get_speed_kmh")))
		_max_speed_kmh = maxf(_max_speed_kmh, kmh)
		# 10 m/s ~= 36 km/h; require meaningful reading while accelerating.
		if kmh > 5.0:
			_saw_speed_kmh = true

	if not _vehicle.global_position.is_finite() or not _vehicle.velocity.is_finite() or not is_finite(speed):
		push_error("drive_smoke: unstable at t=%.2f pos=%s vel=%s speed=%s" % [_elapsed, _vehicle.global_position, _vehicle.velocity, speed])
		quit(1)
		return

	if _vehicle.global_position.y < -2.0:
		push_error("drive_smoke: fell through world at t=%.2f pos=%s" % [_elapsed, _vehicle.global_position])
		quit(1)
		return

	if _camera_rig != null and is_instance_valid(_camera_rig):
		if not _camera_rig.global_position.is_finite():
			push_error("drive_smoke: camera unstable at t=%.2f pos=%s" % [_elapsed, _camera_rig.global_position])
			quit(1)
			return
		var cam_dist := _camera_rig.global_position.distance_to(_vehicle.global_position)
		# Follow camera should stay near the configured distance/height band, not glued to origin.
		if _elapsed > 1.0 and cam_dist > 1.5 and cam_dist < 20.0:
			_camera_follow_ok = true

	match _phase:
		PHASE_ACCEL:
			if _phase_time >= 3.0:
				_set_phase(PHASE_TURN_RIGHT)
		PHASE_TURN_RIGHT:
			if _phase_time >= 8.0:
				_set_phase(PHASE_TURN_LEFT)
		PHASE_TURN_LEFT:
			if _phase_time >= 10.0:
				_set_phase(PHASE_ACCEL if _elapsed < 35.0 else PHASE_BRAKE)
		PHASE_BRAKE:
			if _phase_time >= 2.0:
				_set_phase(PHASE_REVERSE_TURN)
		PHASE_REVERSE_TURN:
			if _phase_time >= 4.0:
				_set_phase(PHASE_DONE)


func _finish() -> void:
	if physics_frame.is_connected(_on_physics_frame):
		physics_frame.disconnect(_on_physics_frame)

	Input.action_release("vehicle_accelerate")
	Input.action_release("vehicle_brake")
	Input.action_release("vehicle_left")
	Input.action_release("vehicle_right")

	var origin := _vehicle.global_position
	var speed := float(_vehicle.call("get_signed_speed")) if _vehicle.has_method("get_signed_speed") else 0.0
	if _vehicle.global_position.y < -2.0:
		push_error("drive_smoke: fell through world pos=%s" % origin)
		quit(1)
		return

	var moved := origin.distance_to(Vector3(0.0, 0.2, 12.0)) > 5.0 or _max_abs_speed > 1.0
	var stable := origin.is_finite() and _vehicle.velocity.is_finite() and is_finite(speed)

	if not stable:
		push_error("drive_smoke: unstable final state pos=%s vel=%s speed=%s" % [origin, _vehicle.velocity, speed])
		quit(1)
		return

	if not moved:
		push_error("drive_smoke: vehicle did not move enough (pos=%s max_speed=%s)" % [origin, _max_abs_speed])
		quit(1)
		return

	if not _camera_follow_ok:
		push_error("drive_smoke: camera did not follow vehicle in expected range")
		quit(1)
		return

	if not _saw_speed_kmh:
		push_error("drive_smoke: get_speed_kmh never rose above 5 (max=%.2f)" % _max_speed_kmh)
		quit(1)
		return

	var hud := root.find_child("DrivingDebugHUD", true, false)
	if hud == null:
		push_error("drive_smoke: DrivingDebugHUD not found")
		quit(1)
		return

	var hud_label := hud.find_child("Label", true, false) as Label
	if hud_label == null or not ("km/h" in hud_label.text):
		push_error("drive_smoke: HUD label missing km/h text (got: %s)" % (hud_label.text if hud_label else "<null>"))
		quit(1)
		return

	var cam_pos := _camera_rig.global_position if _camera_rig else Vector3.ZERO
	print(
		"drive_smoke: OK elapsed=%.1fs samples=%d pos=%s max_abs_speed=%.2f max_kmh=%.1f cam=%s"
		% [_elapsed, _samples, origin, _max_abs_speed, _max_speed_kmh, cam_pos]
	)
	quit(0)
