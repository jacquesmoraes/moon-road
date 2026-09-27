extends SceneTree
## Headless smoke: drive straight along modular road segments; assert stable joints.

const PHASE_ACCEL := 0
const PHASE_CRUISE := 1
const PHASE_DONE := 2

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
var _journey: Node
var _min_z: float = 9999.0
var _max_abs_x: float = 0.0


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

	var road := root.find_child("Road", true, false)
	if road == null or road.get_child_count() < 3:
		push_error("drive_smoke: expected several RoadSegment instances under Road")
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

	if not pos.is_finite() or not _vehicle.velocity.is_finite() or not is_finite(speed):
		push_error("drive_smoke: unstable at t=%.2f pos=%s vel=%s speed=%s" % [_elapsed, pos, _vehicle.velocity, speed])
		quit(1)
		return

	if pos.y < -2.0:
		push_error("drive_smoke: fell off road at t=%.2f pos=%s" % [_elapsed, pos])
		quit(1)
		return

	if _camera_rig != null and is_instance_valid(_camera_rig):
		if not _camera_rig.global_position.is_finite():
			push_error("drive_smoke: camera unstable at t=%.2f pos=%s" % [_elapsed, _camera_rig.global_position])
			quit(1)
			return
		var cam_dist := _camera_rig.global_position.distance_to(pos)
		if _elapsed > 1.0 and cam_dist > 1.5 and cam_dist < 20.0:
			_camera_follow_ok = true

	match _phase:
		PHASE_ACCEL:
			if _phase_time >= 3.0:
				_set_phase(PHASE_CRUISE)
		PHASE_CRUISE:
			# Stay on the 12×40 m strip (~480 m). Stop before the end.
			if _elapsed >= 16.0 or pos.z < -380.0:
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

	if origin.y < -2.0:
		push_error("drive_smoke: fell off road pos=%s" % origin)
		quit(1)
		return

	if not origin.is_finite() or not _vehicle.velocity.is_finite() or not is_finite(speed):
		push_error("drive_smoke: unstable final state pos=%s vel=%s speed=%s" % [origin, _vehicle.velocity, speed])
		quit(1)
		return

	# Crossed multiple 40 m joints while staying near lane center.
	if _min_z > -90.0:
		push_error("drive_smoke: did not cross enough segments (min_z=%.1f)" % _min_z)
		quit(1)
		return

	if _max_abs_x > 6.0:
		push_error("drive_smoke: left roadway laterally (max |x|=%.2f)" % _max_abs_x)
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
	if hud_label == null or not ("km/h" in hud_label.text) or not ("Journey:" in hud_label.text):
		push_error("drive_smoke: HUD label missing journey/km/h text (got: %s)" % (hud_label.text if hud_label else "<null>"))
		quit(1)
		return

	var journey_km := float(_journey.call("get_current_distance_km"))
	if journey_km < 0.05:
		push_error("drive_smoke: journey distance too low (%.6f km)" % journey_km)
		quit(1)
		return

	var saved_scale := float(_journey.call("get_physical_to_journey_scale"))
	_journey.call("set_physical_to_journey_scale", 1.0)
	_journey.call("reset_journey")
	_journey.call("add_physical_distance_meters", 1000.0)
	var at_1x := float(_journey.call("get_current_distance_km"))
	_journey.call("reset_journey")
	_journey.call("set_physical_to_journey_scale", 2.5)
	_journey.call("add_physical_distance_meters", 1000.0)
	var at_2_5x := float(_journey.call("get_current_distance_km"))
	_journey.call("set_physical_to_journey_scale", saved_scale)
	_journey.call("set_current_distance_km", journey_km)

	if absf(at_1x - 1.0) > 0.001 or absf(at_2_5x - 2.5) > 0.001:
		push_error("drive_smoke: scale check failed (1.0→%.3f, 2.5→%.3f)" % [at_1x, at_2_5x])
		quit(1)
		return

	print(
		"drive_smoke: OK elapsed=%.1fs samples=%d pos=%s min_z=%.1f max_|x|=%.2f max_kmh=%.1f journey_km=%.6f"
		% [_elapsed, _samples, origin, _min_z, _max_abs_x, _max_speed_kmh, journey_km]
	)
	quit(0)
