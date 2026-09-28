extends SceneTree
## Headless smoke: Travel Mode on mixed curves + gentle elevation.

const PHASE_ACCEL := 0
const PHASE_ENGAGE_TRAVEL := 1
const PHASE_HOLD_SETTLE := 2
const PHASE_HOLD_SAMPLE := 3
const PHASE_LONG_DRIVE := 4
const PHASE_DONE := 5

## DrivingModeController.Mode.TRAVEL_MODE
const MODE_TRAVEL := 2
const MODE_MANUAL := 0

const HOLD_SETTLE_SEC := 3.0
const HOLD_SAMPLE_SEC := 6.0
const LONG_DRIVE_TOTAL_SEC := 90.0

var _phase: int = PHASE_ACCEL
var _phase_time: float = 0.0
var _elapsed: float = 0.0
var _vehicle: CharacterBody3D
var _mode_controller: Node
var _autopilot: Node
var _camera_rig: Node3D
var _road_manager: Node
var _recenter: Node
var _samples: int = 0
var _camera_follow_ok: bool = false
var _camera_modes_ok: bool = false
var _camera_mode_names: PackedStringArray = []
var _saw_speed_kmh: bool = false
var _max_speed_kmh: float = 0.0
var _journey: Node
var _max_planar: float = 0.0
var _initial_pool_count: int = 0
var _max_pool_count: int = 0
var _journey_mid: float = -1.0
var _cruise_speed_sum: float = 0.0
var _cruise_speed_count: int = 0
var _cruise_speed_min: float = 9999.0
var _cruise_speed_max: float = -9999.0
var _cruise_target_ms: float = 0.0
var _sample_abs_lateral_max: float = 0.0
var _max_abs_lateral: float = 0.0
var _saw_gentle_left: bool = false
var _saw_gentle_right: bool = false
var _saw_straight: bool = false
var _saw_level: bool = false
var _saw_climb: bool = false
var _saw_descent: bool = false
var _min_vehicle_y: float = 9999.0
var _max_vehicle_y: float = -9999.0
var _max_height_above_road: float = 0.0
var _last_road_y: float = 0.0
var _has_road_sample: bool = false
var _scenery: Node
var _initial_scenery_props: int = 0
var _max_scenery_nodes: int = 0
var _initial_scenery_nodes: int = 0
var _saw_active_scenery: bool = false
var _max_scenery_on_road: float = 0.0


func _initialize() -> void:
	# Deterministic mixed-kind sequence for CI-style smoke.
	seed(4804)
	var err := change_scene_to_file("res://scenes/test/DrivingSandbox.tscn")
	if err != OK:
		push_error("drive_smoke: failed to load DrivingSandbox (%s)" % error_string(err))
		quit(1)
		return

	create_timer(0.5).timeout.connect(_begin)


func _begin() -> void:
	_vehicle = root.find_child("PlayerVehicle", true, false) as CharacterBody3D
	if _vehicle == null:
		push_error("drive_smoke: PlayerVehicle not found")
		quit(1)
		return

	_mode_controller = _vehicle.get_node_or_null("DrivingModeController")
	if _mode_controller == null:
		push_error("drive_smoke: DrivingModeController not found")
		quit(1)
		return

	_autopilot = _vehicle.get_node_or_null("RoadFollowAutopilot")
	if _autopilot == null:
		_autopilot = root.find_child("RoadFollowAutopilot", true, false)
	if _autopilot == null:
		push_error("drive_smoke: RoadFollowAutopilot not found")
		quit(1)
		return

	_camera_rig = root.find_child("VehicleCameraController", true, false) as Node3D
	_road_manager = root.find_child("RoadManager", true, false)
	_recenter = root.find_child("WorldOriginRecenter", true, false)
	if _road_manager == null or _recenter == null or _camera_rig == null:
		push_error("drive_smoke: missing RoadManager/WorldOriginRecenter/camera")
		quit(1)
		return

	_initial_pool_count = int(_road_manager.call("get_pool_node_count"))
	_max_pool_count = _initial_pool_count

	_scenery = root.find_child("RoadsideScenery", true, false)
	if _scenery == null:
		push_error("drive_smoke: RoadsideScenery not found")
		quit(1)
		return
	if _scenery.has_method("get_total_prop_count"):
		_initial_scenery_props = int(_scenery.call("get_total_prop_count"))
	if _scenery.has_method("get_node_budget"):
		_initial_scenery_nodes = int(_scenery.call("get_node_budget"))
		_max_scenery_nodes = _initial_scenery_nodes
	if _initial_scenery_props < 8:
		push_error("drive_smoke: scenery pool too small (%d)" % _initial_scenery_props)
		quit(1)
		return

	_journey = root.get_node_or_null("JourneySystem")
	if _journey == null:
		push_error("drive_smoke: JourneySystem missing")
		quit(1)
		return
	_journey.call("reset_journey")

	if _vehicle.has_method("get_cruise_target_speed_ms"):
		_cruise_target_ms = float(_vehicle.call("get_cruise_target_speed_ms"))

	_set_phase(PHASE_ACCEL)
	physics_frame.connect(_on_physics_frame)


var _camera_modes_ok: bool = false
var _camera_mode_names: PackedStringArray = []


func _engage_travel_mode() -> void:
	if _mode_controller.has_method("set_mode"):
		_mode_controller.call("set_mode", MODE_TRAVEL)


func _cycle_all_camera_modes() -> void:
	if _camera_rig == null or not _camera_rig.has_method("set_mode"):
		return
	_camera_mode_names.clear()
	# CameraMode: FOLLOW=0, FAR=1, HOOD=2, PASSENGER=3, WINDOW=4
	for m in range(5):
		_camera_rig.call("set_mode", m)
		if _camera_rig.has_method("get_mode_name"):
			_camera_mode_names.append(str(_camera_rig.call("get_mode_name")))
	_camera_rig.call("set_mode", 0)  # back to FOLLOW for distance checks
	_camera_modes_ok = _camera_mode_names.size() == 5
	for expected in ["FOLLOW", "FAR", "HOOD", "PASSENGER", "WINDOW"]:
		if expected not in _camera_mode_names:
			_camera_modes_ok = false
			break


func _set_phase(phase: int) -> void:
	Input.action_release("vehicle_accelerate")
	Input.action_release("vehicle_brake")
	Input.action_release("vehicle_left")
	Input.action_release("vehicle_right")
	Input.action_release("vehicle_cruise_toggle")
	Input.action_release("vehicle_autopilot_toggle")
	Input.action_release("vehicle_autopilot_cancel")
	Input.action_release("vehicle_travel_mode_toggle")
	Input.action_release("vehicle_travel_mode_cancel")
	_phase = phase
	_phase_time = 0.0

	match phase:
		PHASE_ACCEL:
			Input.action_press("vehicle_accelerate")
		PHASE_ENGAGE_TRAVEL:
			_engage_travel_mode()
			_cycle_all_camera_modes()
		PHASE_HOLD_SETTLE, PHASE_HOLD_SAMPLE, PHASE_LONG_DRIVE:
			_engage_travel_mode()
			# Keep FOLLOW for lane/camera-distance smoke checks.
			if _camera_rig != null and _camera_rig.has_method("set_mode"):
				_camera_rig.call("set_mode", 0)
		PHASE_DONE:
			_finish()


func _track_road_sample() -> void:
	if _road_manager == null or not _road_manager.has_method("sample_road"):
		return
	var sample: Dictionary = _road_manager.call("sample_road", _vehicle.global_position, 14.0)
	if sample.is_empty():
		return
	var lateral := absf(float(sample.get("lateral", 0.0)))
	_max_abs_lateral = maxf(_max_abs_lateral, lateral)
	if _phase == PHASE_HOLD_SAMPLE:
		_sample_abs_lateral_max = maxf(_sample_abs_lateral_max, lateral)

	var point: Vector3 = sample.get("point", _vehicle.global_position)
	_last_road_y = point.y
	_has_road_sample = true
	_max_height_above_road = maxf(_max_height_above_road, _vehicle.global_position.y - point.y)

	var kind := str(sample.get("kind", ""))
	match kind:
		"straight":
			_saw_straight = true
		"gentle_left":
			_saw_gentle_left = true
		"gentle_right":
			_saw_gentle_right = true

	var elev := str(sample.get("elevation", ""))
	match elev:
		"level":
			_saw_level = true
		"gentle_climb":
			_saw_climb = true
		"gentle_descent":
			_saw_descent = true

	if _road_manager.has_method("get_active_kind_counts"):
		var counts: Dictionary = _road_manager.call("get_active_kind_counts")
		if int(counts.get("straight", 0)) > 0:
			_saw_straight = true
		if int(counts.get("gentle_left", 0)) > 0:
			_saw_gentle_left = true
		if int(counts.get("gentle_right", 0)) > 0:
			_saw_gentle_right = true

	if _road_manager.has_method("get_active_elevation_counts"):
		var elev_counts: Dictionary = _road_manager.call("get_active_elevation_counts")
		if int(elev_counts.get("level", 0)) > 0:
			_saw_level = true
		if int(elev_counts.get("gentle_climb", 0)) > 0:
			_saw_climb = true
		if int(elev_counts.get("gentle_descent", 0)) > 0:
			_saw_descent = true


func _track_scenery_clearance() -> void:
	## Sample a few active props via segment anchors; none may sit on the roadway.
	if _road_manager == null or not _road_manager.has_method("get_active_segments"):
		return
	var segs: Array = _road_manager.call("get_active_segments")
	for seg in segs:
		if seg == null or not is_instance_valid(seg):
			continue
		var anchor = seg.get_node_or_null("SceneryAnchor")
		if anchor == null:
			continue
		for child in anchor.get_children():
			if not (child is Node3D):
				continue
			if not seg.has_method("project_on_centerline"):
				continue
			var proj: Dictionary = seg.call("project_on_centerline", (child as Node3D).global_position)
			var lat := absf(float(proj.get("lateral", 0.0)))
			_max_scenery_on_road = maxf(_max_scenery_on_road, 0.0 if lat >= 6.0 else (6.0 - lat))
			if lat < 5.5:
				push_error("drive_smoke: scenery on roadway lat=%.2f at %s" % [lat, (child as Node3D).global_position])
				quit(1)
				return


func _on_physics_frame() -> void:
	if _vehicle == null or _phase == PHASE_DONE:
		return

	var dt := 1.0 / 60.0
	_elapsed += dt
	_phase_time += dt
	_samples += 1

	var speed := float(_vehicle.call("get_signed_speed")) if _vehicle.has_method("get_signed_speed") else 0.0
	if _vehicle.has_method("get_speed_kmh"):
		var kmh := absf(float(_vehicle.call("get_speed_kmh")))
		_max_speed_kmh = maxf(_max_speed_kmh, kmh)
		if kmh > 5.0:
			_saw_speed_kmh = true

	var pos := _vehicle.global_position
	_max_planar = maxf(_max_planar, Vector3(pos.x, 0.0, pos.z).length())
	_min_vehicle_y = minf(_min_vehicle_y, pos.y)
	_max_vehicle_y = maxf(_max_vehicle_y, pos.y)
	_max_pool_count = maxi(_max_pool_count, int(_road_manager.call("get_pool_node_count")))
	if _scenery != null:
		if _scenery.has_method("get_node_budget"):
			_max_scenery_nodes = maxi(_max_scenery_nodes, int(_scenery.call("get_node_budget")))
		if _scenery.has_method("get_active_prop_count") and int(_scenery.call("get_active_prop_count")) > 0:
			_saw_active_scenery = true
		if _scenery.has_method("get_total_prop_count"):
			var total_props := int(_scenery.call("get_total_prop_count"))
			if total_props != _initial_scenery_props:
				push_error("drive_smoke: scenery pool grew/shrank (%d → %d)" % [_initial_scenery_props, total_props])
				quit(1)
				return
	_track_road_sample()
	_track_scenery_clearance()

	if _elapsed >= LONG_DRIVE_TOTAL_SEC * 0.5 and _journey_mid < 0.0:
		_journey_mid = float(_journey.call("get_current_distance_km"))

	if _phase == PHASE_HOLD_SAMPLE:
		_cruise_speed_sum += speed
		_cruise_speed_count += 1
		_cruise_speed_min = minf(_cruise_speed_min, speed)
		_cruise_speed_max = maxf(_cruise_speed_max, speed)

	# Fall-through check relative to road surface (absolute Y drops on descents).
	if not pos.is_finite():
		push_error("drive_smoke: unstable pos=%s" % pos)
		quit(1)
		return
	if _has_road_sample and pos.y < _last_road_y - 2.5:
		push_error("drive_smoke: fell through road pos=%s road_y=%.2f" % [pos, _last_road_y])
		quit(1)
		return

	if _camera_rig != null:
		var cam_dist := _camera_rig.global_position.distance_to(pos)
		if _elapsed > 1.0 and cam_dist > 1.5 and cam_dist < 20.0:
			_camera_follow_ok = true

	match _phase:
		PHASE_ACCEL:
			if _phase_time >= 2.5:
				_set_phase(PHASE_ENGAGE_TRAVEL)
		PHASE_ENGAGE_TRAVEL:
			if _phase_time >= 0.1:
				_set_phase(PHASE_HOLD_SETTLE)
		PHASE_HOLD_SETTLE:
			if _phase_time >= HOLD_SETTLE_SEC:
				_set_phase(PHASE_HOLD_SAMPLE)
		PHASE_HOLD_SAMPLE:
			if _phase_time >= HOLD_SAMPLE_SEC:
				_set_phase(PHASE_LONG_DRIVE)
		PHASE_LONG_DRIVE:
			if _elapsed >= LONG_DRIVE_TOTAL_SEC:
				_set_phase(PHASE_DONE)


func _finish() -> void:
	if physics_frame.is_connected(_on_physics_frame):
		physics_frame.disconnect(_on_physics_frame)

	Input.action_release("vehicle_accelerate")

	var origin := _vehicle.global_position
	var pool_final := int(_road_manager.call("get_pool_node_count"))
	var recycles := int(_road_manager.call("get_recycle_count"))
	var recenters := int(_recenter.call("get_recenter_count"))
	var journey_km := float(_journey.call("get_current_distance_km"))
	var planar := Vector3(origin.x, 0.0, origin.z).length()
	var recenter_distance := float(_recenter.get("recenter_distance"))

	var mode_name := str(_mode_controller.call("get_mode_name"))
	if mode_name != "TRAVEL_MODE":
		push_error("drive_smoke: expected TRAVEL_MODE, got %s" % mode_name)
		quit(1)
		return

	if not bool(_vehicle.call("is_travel_mode")):
		push_error("drive_smoke: vehicle.is_travel_mode false")
		quit(1)
		return

	if not bool(_autopilot.call("is_autopilot_active")):
		push_error("drive_smoke: autopilot inactive under Travel Mode")
		quit(1)
		return

	if not bool(_vehicle.call("is_cruise_control_active")):
		push_error("drive_smoke: cruise inactive under Travel Mode")
		quit(1)
		return

	if _cruise_speed_count < 60:
		push_error("drive_smoke: not enough cruise samples")
		quit(1)
		return

	var mean_speed := _cruise_speed_sum / float(_cruise_speed_count)
	var speed_span := _cruise_speed_max - _cruise_speed_min
	if absf(mean_speed - _cruise_target_ms) > 1.25:
		push_error("drive_smoke: cruise mean off target (%.2f vs %.2f)" % [mean_speed, _cruise_target_ms])
		quit(1)
		return
	if speed_span > 2.5:
		push_error("drive_smoke: cruise oscillation too high (span=%.2f)" % speed_span)
		quit(1)
		return

	# Lane-keeping uses centerline lateral (world X is not meaningful once curves appear).
	if _sample_abs_lateral_max > 2.5 or _max_abs_lateral > 3.5:
		push_error(
			"drive_smoke: left lane center too far (sample|lat|=%.2f max|lat|=%.2f)"
			% [_sample_abs_lateral_max, _max_abs_lateral]
		)
		quit(1)
		return

	if not _camera_follow_ok or not _saw_speed_kmh:
		push_error("drive_smoke: camera/speed checks failed")
		quit(1)
		return

	if not _camera_modes_ok:
		push_error("drive_smoke: camera mode cycle failed (%s)" % [_camera_mode_names])
		quit(1)
		return

	if _camera_rig.has_method("get_mode_name") and str(_camera_rig.call("get_mode_name")) != "FOLLOW":
		push_error("drive_smoke: expected FOLLOW after cycle")
		quit(1)
		return

	# Curves + elevation reduce net planar drift vs pure -Z; still require recentering.
	if recycles < 5 or recenters < 1:
		push_error("drive_smoke: recycle/recenter counts too low (r=%d c=%d)" % [recycles, recenters])
		quit(1)
		return

	if planar >= recenter_distance or pool_final != _initial_pool_count or _max_pool_count != _initial_pool_count:
		push_error("drive_smoke: recenter/pool invariant failed")
		quit(1)
		return

	if not _saw_active_scenery:
		push_error("drive_smoke: no active roadside scenery observed")
		quit(1)
		return

	var scenery_props_final := int(_scenery.call("get_total_prop_count"))
	var scenery_nodes_final := int(_scenery.call("get_node_budget"))
	if scenery_props_final != _initial_scenery_props:
		push_error("drive_smoke: scenery prop pool changed (%d → %d)" % [_initial_scenery_props, scenery_props_final])
		quit(1)
		return
	if scenery_nodes_final > _initial_scenery_nodes:
		push_error("drive_smoke: scenery nodes grew (%d → %d)" % [_initial_scenery_nodes, scenery_nodes_final])
		quit(1)
		return
	if _max_scenery_nodes > _initial_scenery_nodes:
		push_error("drive_smoke: scenery node budget grew during run")
		quit(1)
		return

	if _journey_mid < 0.0 or journey_km <= _journey_mid:
		push_error("drive_smoke: journey did not keep increasing")
		quit(1)
		return

	if not _saw_straight or not _saw_gentle_left or not _saw_gentle_right:
		push_error(
			"drive_smoke: missing segment kinds (straight=%s left=%s right=%s)"
			% [_saw_straight, _saw_gentle_left, _saw_gentle_right]
		)
		quit(1)
		return

	if not _saw_level or not _saw_climb or not _saw_descent:
		push_error(
			"drive_smoke: missing elevation (level=%s climb=%s descent=%s)"
			% [_saw_level, _saw_climb, _saw_descent]
		)
		quit(1)
		return

	var elev_span := _max_vehicle_y - _min_vehicle_y
	if elev_span < 1.0:
		push_error("drive_smoke: elevation span too small (%.2f)" % elev_span)
		quit(1)
		return

	# Immediate cancel path: Travel Mode → MANUAL via API.
	_mode_controller.call("set_mode", MODE_MANUAL)
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error("drive_smoke: cancel did not return to MANUAL")
		quit(1)
		return
	if bool(_autopilot.call("is_autopilot_active")):
		push_error("drive_smoke: autopilot still active after cancel")
		quit(1)
		return
	if bool(_vehicle.call("is_cruise_control_active")):
		push_error("drive_smoke: cruise still active after cancel")
		quit(1)
		return

	var counts: Dictionary = _road_manager.call("get_active_kind_counts")
	var elev_counts: Dictionary = _road_manager.call("get_active_elevation_counts")
	print(
		"drive_smoke: OK elapsed=%.1fs TRAVEL_MODE cruise_mean=%.2f span=%.2f max_|lat|=%.2f recenters=%d recycles=%d journey=%.3f kinds=%s elev=%s y_span=%.2f scenery_props=%d active=%d nodes=%d cams=%s cancel=MANUAL"
		% [
			_elapsed,
			mean_speed,
			speed_span,
			_max_abs_lateral,
			recenters,
			recycles,
			journey_km,
			counts,
			elev_counts,
			elev_span,
			scenery_props_final,
			int(_scenery.call("get_active_prop_count")),
			scenery_nodes_final,
			",".join(_camera_mode_names),
		]
	)
	quit(0)
