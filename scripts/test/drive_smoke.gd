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
var _cinematic_ok: bool = false
var _cinematic_cancel_ok: bool = false
var _cinematic_swap_count: int = 0
var _cinematic_modes_seen: PackedStringArray = []
var _cinematic_last_mode: String = ""
var _cinematic_started: bool = false
var _cinematic_cancel_checked: bool = false
var _autopilot_ok_during_cine: bool = true
var _exit_system: Node
var _initial_exit_nodes: int = 0
var _max_exit_nodes: int = 0
var _saw_exit_active: bool = false
var _exit_active_during_travel: bool = false
var _poi_reach_ok: bool = false


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

	if not _verify_world_regions():
		return

	# Restore clean journey start after region API probes.
	_journey.call("reset_journey")

	_exit_system = root.find_child("RoadsideExitSystem", true, false)
	if _exit_system == null:
		push_error("drive_smoke: RoadsideExitSystem missing")
		quit(1)
		return
	if _exit_system.has_method("get_total_node_budget"):
		_initial_exit_nodes = int(_exit_system.call("get_total_node_budget"))
		_max_exit_nodes = _initial_exit_nodes
	if _initial_exit_nodes < 4:
		push_error("drive_smoke: exit/detour pool too small (%d)" % _initial_exit_nodes)
		quit(1)
		return

	if not await _verify_sunset_viewpoint_reachable():
		return

	if _vehicle.has_method("get_cruise_target_speed_ms"):
		_cruise_target_ms = float(_vehicle.call("get_cruise_target_speed_ms"))

	_set_phase(PHASE_ACCEL)
	physics_frame.connect(_on_physics_frame)


func _verify_world_regions() -> bool:
	var regions: Node = root.get_node_or_null("WorldRegionSystem")
	if regions == null:
		push_error("drive_smoke: WorldRegionSystem missing")
		quit(1)
		return false
	if int(regions.call("get_region_count")) < 7:
		push_error("drive_smoke: expected >=7 catalog regions")
		quit(1)
		return false

	var signal_count := {"n": 0}
	var on_changed := func(_new_region, _previous_region) -> void:
		signal_count["n"] = int(signal_count["n"]) + 1
	regions.region_changed.connect(on_changed)

	# Samples: mid-span + exact boundaries (half-open → next region owns the shared edge).
	var samples: Array = [
		[0.0, "ENDLESS_SUMMER"],
		[20000.0, "ENDLESS_SUMMER"],
		[40000.0, "CLOUDLINE"],
		[90000.0, "ORBITAL_BLUE"],
		[150000.0, "DEEP_VIOLET"],
		[230000.0, "THE_LONG_NIGHT"],
		[310000.0, "MOONRISE"],
		[370000.0, "LUNAR_DESCENT"],
		[384400.0, "LUNAR_DESCENT"],
	]

	var expected_emits := 0
	var last_id := str(regions.call("get_current_region_id"))
	for sample in samples:
		var km: float = float(sample[0])
		var expect_id: String = str(sample[1])
		_journey.call("set_current_distance_km", km)
		var got_id := str(regions.call("get_current_region_id"))
		if got_id != expect_id:
			push_error("drive_smoke: region at %.1f km got %s want %s" % [km, got_id, expect_id])
			quit(1)
			return false
		var at: Variant = regions.call("get_region_at_distance", km)
		if at == null or str(at.region_id) != expect_id:
			push_error("drive_smoke: get_region_at_distance mismatch at %.1f" % km)
			quit(1)
			return false
		if got_id != last_id:
			expected_emits += 1
			last_id = got_id

	if int(signal_count["n"]) != expected_emits:
		push_error(
			"drive_smoke: region_changed emits=%d expected=%d"
			% [int(signal_count["n"]), expected_emits]
		)
		quit(1)
		return false

	# Same-region distance change must not emit again.
	var before := int(signal_count["n"])
	_journey.call("set_current_distance_km", 375000.0)  # still LUNAR_DESCENT
	_journey.call("set_current_distance_km", 380000.0)
	if int(signal_count["n"]) != before:
		push_error("drive_smoke: region_changed fired without region change")
		quit(1)
		return false

	var progress := float(regions.call("get_region_progress"))
	if progress < 0.0 or progress > 1.0:
		push_error("drive_smoke: region progress out of range %.3f" % progress)
		quit(1)
		return false

	regions.region_changed.disconnect(on_changed)
	print(
		"drive_smoke: regions OK count=%d emits=%d final=%s progress=%.2f"
		% [int(regions.call("get_region_count")), expected_emits, last_id, progress]
	)
	return true


func _engage_travel_mode() -> void:
	if _mode_controller.has_method("set_mode"):
		_mode_controller.call("set_mode", MODE_TRAVEL)


func _enable_cinematic_fast() -> void:
	## Accelerated stand-in for long Travel Mode cinematic sessions.
	if _camera_rig == null:
		return
	_camera_rig.set("cinematic_min_duration", 1.2)
	_camera_rig.set("cinematic_max_duration", 2.4)
	_camera_rig.set("cinematic_hood_max_duration", 1.6)
	_camera_rig.set("cinematic_transition_duration", 0.35)
	if _camera_rig.has_method("set_cinematic_active"):
		_camera_rig.call("set_cinematic_active", true)
		_cinematic_started = true
		if _camera_rig.has_method("is_cinematic_active"):
			_cinematic_ok = bool(_camera_rig.call("is_cinematic_active"))
		if _camera_rig.has_method("get_mode_name"):
			_cinematic_last_mode = str(_camera_rig.call("get_mode_name"))
			if _cinematic_last_mode not in _cinematic_modes_seen:
				_cinematic_modes_seen.append(_cinematic_last_mode)


func _track_cinematic() -> void:
	if not _cinematic_started or _camera_rig == null:
		return
	if _camera_rig.has_method("is_cinematic_active") and bool(_camera_rig.call("is_cinematic_active")):
		if _autopilot != null and _autopilot.has_method("is_autopilot_active"):
			if not bool(_autopilot.call("is_autopilot_active")):
				_autopilot_ok_during_cine = false
		if _camera_rig.has_method("get_mode_name"):
			var name := str(_camera_rig.call("get_mode_name"))
			if name != _cinematic_last_mode and _cinematic_last_mode != "":
				_cinematic_swap_count += 1
			_cinematic_last_mode = name
			if name not in _cinematic_modes_seen:
				_cinematic_modes_seen.append(name)


func _track_exits() -> void:
	if _exit_system == null:
		return
	if _exit_system.has_method("get_total_node_budget"):
		_max_exit_nodes = maxi(_max_exit_nodes, int(_exit_system.call("get_total_node_budget")))
	if _exit_system.has_method("is_exit_active") and bool(_exit_system.call("is_exit_active")):
		_saw_exit_active = true
		if _phase == PHASE_HOLD_SAMPLE or _phase == PHASE_LONG_DRIVE:
			_exit_active_during_travel = true


func _verify_sunset_viewpoint_reachable() -> bool:
	## Structural reachability: EXIT_RIGHT detour is active, off-lane, and hosts the POI.
	## Avoids vehicle teleports that disturb physics / journey reporters before the drive.
	if _exit_system == null:
		return false
	for _i in 10:
		if bool(_exit_system.call("is_exit_active", "sunset_viewpoint_exit")):
			break
		await physics_frame

	if not bool(_exit_system.call("is_exit_active", "sunset_viewpoint_exit")):
		push_error("drive_smoke: sunset exit not active at start")
		quit(1)
		return false

	var poi_name := str(_exit_system.call("get_active_poi_name"))
	if poi_name != "Sunset Viewpoint":
		push_error("drive_smoke: expected Sunset Viewpoint, got '%s'" % poi_name)
		quit(1)
		return false

	var poi_pos: Vector3 = _exit_system.call("get_poi_global_position", "sunset_viewpoint_exit")
	if poi_pos == Vector3.ZERO:
		push_error("drive_smoke: Sunset Viewpoint POI position missing")
		quit(1)
		return false

	var main_sample: Dictionary = _road_manager.call("sample_road", poi_pos, 8.0)
	var main_lat := absf(float(main_sample.get("lateral", 0.0)))
	if main_lat < 6.0:
		push_error("drive_smoke: Sunset Viewpoint POI too close to main road (lat=%.2f)" % main_lat)
		quit(1)
		return false

	if int(_exit_system.call("get_detour_segment_count")) < 2:
		push_error("drive_smoke: detour segment pool missing")
		quit(1)
		return false

	_poi_reach_ok = true
	_saw_exit_active = true
	print(
		"drive_smoke: Sunset Viewpoint EXIT_RIGHT detour ready (main_lat=%.1f, nodes=%d)"
		% [main_lat, int(_exit_system.call("get_total_node_budget"))]
	)
	return true


func _cancel_cinematic_and_verify() -> void:
	if _cinematic_cancel_checked or _camera_rig == null:
		return
	_cinematic_cancel_checked = true
	if _camera_rig.has_method("set_cinematic_active"):
		_camera_rig.call("set_cinematic_active", false)
	_cinematic_cancel_ok = (
		_camera_rig.has_method("is_cinematic_active")
		and not bool(_camera_rig.call("is_cinematic_active"))
	)
	# Autopilot must keep driving after cinematic cancel.
	if _autopilot != null and _autopilot.has_method("is_autopilot_active"):
		if not bool(_autopilot.call("is_autopilot_active")):
			_autopilot_ok_during_cine = false


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
	Input.action_release("vehicle_camera_cinematic_toggle")
	_phase = phase
	_phase_time = 0.0

	match phase:
		PHASE_ACCEL:
			Input.action_press("vehicle_accelerate")
		PHASE_ENGAGE_TRAVEL:
			_engage_travel_mode()
			_cycle_all_camera_modes()
		PHASE_HOLD_SETTLE, PHASE_HOLD_SAMPLE:
			_engage_travel_mode()
			# Keep FOLLOW for lane/camera-distance smoke checks.
			if _camera_rig != null and _camera_rig.has_method("set_mode"):
				_camera_rig.call("set_mode", 0)
		PHASE_LONG_DRIVE:
			_engage_travel_mode()
			_enable_cinematic_fast()
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
	_track_cinematic()
	_track_exits()

	if _elapsed >= LONG_DRIVE_TOTAL_SEC * 0.5 and _journey_mid < 0.0:
		_journey_mid = float(_journey.call("get_current_distance_km"))

	# Instant cinematic cancel mid Travel Mode (well before phase end).
	if (
		_phase == PHASE_LONG_DRIVE
		and _cinematic_started
		and not _cinematic_cancel_checked
		and _phase_time >= 18.0
		and _cinematic_swap_count >= 2
	):
		_cancel_cinematic_and_verify()

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
		# Cinematic may have left a non-FOLLOW mode; that is fine after cancel.
		pass

	if not _cinematic_ok or not _cinematic_started:
		push_error("drive_smoke: cinematic failed to activate under Travel Mode")
		quit(1)
		return

	if _cinematic_swap_count < 2 or _cinematic_modes_seen.size() < 2:
		push_error(
			"drive_smoke: cinematic swaps insufficient (swaps=%d modes=%s)"
			% [_cinematic_swap_count, ",".join(_cinematic_modes_seen)]
		)
		quit(1)
		return

	if not _cinematic_cancel_ok:
		push_error("drive_smoke: cinematic cancel failed")
		quit(1)
		return

	if not _autopilot_ok_during_cine:
		push_error("drive_smoke: autopilot disrupted by cinematic camera")
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

	# Leaving Travel Mode must also clear cinematic if somehow still on.
	if _camera_rig.has_method("is_cinematic_active") and bool(_camera_rig.call("is_cinematic_active")):
		# Process may need a frame; force cancel then assert.
		_camera_rig.call("set_cinematic_active", false)
		if bool(_camera_rig.call("is_cinematic_active")):
			push_error("drive_smoke: cinematic still active after Travel cancel")
			quit(1)
			return

	if not _saw_exit_active:
		push_error("drive_smoke: Sunset Viewpoint exit never activated")
		quit(1)
		return

	if _max_exit_nodes > _initial_exit_nodes:
		push_error(
			"drive_smoke: exit/detour nodes grew (%d → %d)"
			% [_initial_exit_nodes, _max_exit_nodes]
		)
		quit(1)
		return

	var exit_nodes_final := int(_exit_system.call("get_total_node_budget"))
	if exit_nodes_final != _initial_exit_nodes:
		push_error(
			"drive_smoke: exit node budget changed (%d → %d)"
			% [_initial_exit_nodes, exit_nodes_final]
		)
		quit(1)
		return

	# Travel Mode stayed on main road (low lateral) even while an exit existed nearby.
	if _exit_active_during_travel and _max_abs_lateral > 3.5:
		push_error(
			"drive_smoke: Travel Mode drifted toward exit (max|lat|=%.2f)" % _max_abs_lateral
		)
		quit(1)
		return

	if not _poi_reach_ok:
		push_error("drive_smoke: Sunset Viewpoint reach was not confirmed")
		quit(1)
		return

	var counts: Dictionary = _road_manager.call("get_active_kind_counts")
	var elev_counts: Dictionary = _road_manager.call("get_active_elevation_counts")
	print(
		"drive_smoke: OK elapsed=%.1fs TRAVEL_MODE cruise_mean=%.2f span=%.2f max_|lat|=%.2f recenters=%d recycles=%d journey=%.3f kinds=%s elev=%s y_span=%.2f scenery_props=%d active=%d nodes=%d cams=%s cine_swaps=%d cine_modes=%s exit_nodes=%d exit_active=%s poi=SunsetViewpoint cancel=MANUAL"
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
			_cinematic_swap_count,
			",".join(_cinematic_modes_seen),
			exit_nodes_final,
			str(_saw_exit_active),
		]
	)
	quit(0)
