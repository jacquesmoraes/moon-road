extends SceneTree
## Headless smoke: continuous road recycling — stable segment count over a long drive.

const PHASE_ACCEL := 0
const PHASE_CRUISE := 1
const PHASE_DONE := 2

## ~90s at cruise covers multiple recycle cycles (not a literal 15 min, but proves the loop).
const CRUISE_DURATION_SEC := 90.0

var _phase: int = PHASE_ACCEL
var _phase_time: float = 0.0
var _elapsed: float = 0.0
var _vehicle: CharacterBody3D
var _camera_rig: Node3D
var _road_manager: Node
var _max_abs_speed: float = 0.0
var _samples: int = 0
var _camera_follow_ok: bool = false
var _saw_speed_kmh: bool = false
var _max_speed_kmh: float = 0.0
var _journey: Node
var _min_z: float = 9999.0
var _max_abs_x: float = 0.0
var _initial_pool_count: int = 0
var _max_pool_count: int = 0


func _initialize() -> void:
	var err := change_scene_to_file("res://scenes/test/DrivingSandbox.tscn")
	if err != OK:
		push_error("drive_smoke: failed to load DrivingSandbox (%s)" % error_string(err))
		quit(1)
		return

	create_timer(0.4).timeout.connect(_begin)


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

	_road_manager = root.find_child("RoadManager", true, false)
	if _road_manager == null:
		push_error("drive_smoke: RoadManager not found")
		quit(1)
		return

	_initial_pool_count = int(_road_manager.call("get_pool_node_count"))
	_max_pool_count = _initial_pool_count
	if _initial_pool_count < 2:
		push_error("drive_smoke: RoadManager pool too small (%d)" % _initial_pool_count)
		quit(1)
		return

	_journey = root.get_node_or_null("JourneySystem")
	if _journey == null:
		push_error("drive_smoke: JourneySystem autoload missing")
		quit(1)
		return
	_journey.call("reset_journey")

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
		PHASE_ACCEL, PHASE_CRUISE:
			Input.action_press("vehicle_accelerate")
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
		if kmh > 5.0:
			_saw_speed_kmh = true

	var pos := _vehicle.global_position
	_min_z = minf(_min_z, pos.z)
	_max_abs_x = maxf(_max_abs_x, absf(pos.x))

	var pool_now := int(_road_manager.call("get_pool_node_count"))
	_max_pool_count = maxi(_max_pool_count, pool_now)

	if not pos.is_finite() or not _vehicle.velocity.is_finite() or not is_finite(speed):
		push_error("drive_smoke: unstable at t=%.2f pos=%s" % [_elapsed, pos])
		quit(1)
		return

	if pos.y < -2.0:
		push_error("drive_smoke: fell off road at t=%.2f pos=%s" % [_elapsed, pos])
		quit(1)
		return

	if _camera_rig != null and is_instance_valid(_camera_rig):
		var cam_dist := _camera_rig.global_position.distance_to(pos)
		if _elapsed > 1.0 and cam_dist > 1.5 and cam_dist < 20.0:
			_camera_follow_ok = true

	match _phase:
		PHASE_ACCEL:
			if _phase_time >= 3.0:
				_set_phase(PHASE_CRUISE)
		PHASE_CRUISE:
			if _elapsed >= CRUISE_DURATION_SEC:
				_set_phase(PHASE_DONE)


func _finish() -> void:
	if physics_frame.is_connected(_on_physics_frame):
		physics_frame.disconnect(_on_physics_frame)

	Input.action_release("vehicle_accelerate")

	var origin := _vehicle.global_position
	var pool_final := int(_road_manager.call("get_pool_node_count"))
	var active_final := int(_road_manager.call("get_active_segment_count"))
	var recycles := int(_road_manager.call("get_recycle_count"))

	if origin.y < -2.0:
		push_error("drive_smoke: fell off road pos=%s" % origin)
		quit(1)
		return

	if _max_abs_x > 6.0:
		push_error("drive_smoke: left roadway laterally (max |x|=%.2f)" % _max_abs_x)
		quit(1)
		return

	if not _camera_follow_ok or not _saw_speed_kmh:
		push_error("drive_smoke: camera/speed checks failed")
		quit(1)
		return

	if recycles < 5:
		push_error("drive_smoke: expected multiple recycles, got %d (min_z=%.1f)" % [recycles, _min_z])
		quit(1)
		return

	if pool_final != _initial_pool_count or _max_pool_count != _initial_pool_count:
		push_error(
			"drive_smoke: segment pool grew (initial=%d max=%d final=%d)"
			% [_initial_pool_count, _max_pool_count, pool_final]
		)
		quit(1)
		return

	if active_final != _initial_pool_count:
		push_error("drive_smoke: active count drifted (%d vs %d)" % [active_final, _initial_pool_count])
		quit(1)
		return

	var journey_km := float(_journey.call("get_current_distance_km"))
	if journey_km < 0.5:
		push_error("drive_smoke: journey too low after long drive (%.4f)" % journey_km)
		quit(1)
		return

	print(
		"drive_smoke: OK elapsed=%.1fs pos=%s min_z=%.1f recycles=%d pool=%d journey_km=%.3f"
		% [_elapsed, origin, _min_z, recycles, pool_final, journey_km]
	)
	quit(0)
