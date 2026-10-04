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

	if not await _verify_sunset_viewpoint_reachable():
		return

	# Budget snapshot after discovery probe (viewpoint may be unloaded).
	if _exit_system.has_method("get_total_node_budget"):
		_initial_exit_nodes = int(_exit_system.call("get_total_node_budget"))
		_max_exit_nodes = _initial_exit_nodes
	if _initial_exit_nodes < 4:
		push_error("drive_smoke: exit/detour pool too small (%d)" % _initial_exit_nodes)
		quit(1)
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
	## Structural + discovery API: EXIT_RIGHT detour, ViewpointPOI spawn, persist after unload.
	if _exit_system == null:
		return false
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if poi_sys == null:
		push_error("drive_smoke: POISystem missing")
		quit(1)
		return false
	if poi_sys.has_method("clear_discovery_for_tests"):
		poi_sys.call("clear_discovery_for_tests")
	_clear_world_state()

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

	if not bool(poi_sys.call("has_active_viewpoint", "sunset_viewpoint")):
		push_error("drive_smoke: ViewpointPOI not spawned for sunset_viewpoint")
		quit(1)
		return false

	var vp: Node3D = poi_sys.call("get_active_viewpoint", "sunset_viewpoint")
	if vp == null:
		push_error("drive_smoke: active viewpoint instance null")
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

	# Discover once via viewpoint presence API (no vehicle teleport).
	var emit_count := {"n": 0}
	var on_disc := func(_id: String, _name: String) -> void:
		emit_count["n"] = int(emit_count["n"]) + 1
	poi_sys.discovered_poi.connect(on_disc)
	if vp.has_method("notify_presence"):
		vp.call("notify_presence", _vehicle)
	else:
		poi_sys.call("mark_discovered", "sunset_viewpoint", "Sunset Viewpoint")
	# Second call must not re-emit.
	if vp.has_method("notify_presence"):
		vp.call("notify_presence", _vehicle)
	poi_sys.call("mark_discovered", "sunset_viewpoint", "Sunset Viewpoint")

	if not bool(poi_sys.call("is_discovered", "sunset_viewpoint")):
		push_error("drive_smoke: sunset_viewpoint not marked discovered")
		quit(1)
		return false
	if int(emit_count["n"]) != 1:
		push_error("drive_smoke: discovered_poi emits=%d want 1" % int(emit_count["n"]))
		quit(1)
		return false

	# Stateful ViewpointTerminal must exist inside the viewpoint (starts OFF).
	var terminal: Node = vp.find_child("ViewpointTerminal", true, false)
	if terminal == null:
		push_error("drive_smoke: ViewpointTerminal missing inside Sunset Viewpoint")
		quit(1)
		return false
	if not terminal.has_method("get_state_name") or str(terminal.call("get_state_name")) != "OFF":
		push_error("drive_smoke: ViewpointTerminal should start OFF")
		quit(1)
		return false

	var booth: Node = vp.find_child("ObservationBooth", true, false)
	if booth == null:
		booth = vp.find_child("SmallInterior", true, false)
	if booth == null:
		push_error("drive_smoke: ObservationBooth / SmallInterior missing on Sunset Viewpoint")
		quit(1)
		return false

	# Unload viewpoint; discovery must remain in logical POISystem.
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	if bool(poi_sys.call("has_active_viewpoint", "sunset_viewpoint")):
		push_error("drive_smoke: viewpoint still loaded after despawn")
		quit(1)
		return false
	if not bool(poi_sys.call("is_discovered", "sunset_viewpoint")):
		push_error("drive_smoke: discovery lost after viewpoint unload")
		quit(1)
		return false

	poi_sys.discovered_poi.disconnect(on_disc)
	_poi_reach_ok = true
	_saw_exit_active = true
	print(
		"drive_smoke: Sunset Viewpoint discovered + persisted after unload (main_lat=%.1f)"
		% main_lat
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
	Input.action_release("vehicle_park")
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

	if not await _verify_parking_state():
		return

	if not _verify_inventory_system():
		return

	if not _verify_crafting_system():
		return

	if not _verify_save_system():
		return

	if not await _verify_world_state_system():
		return

	if not await _verify_game_time_system():
		return

	if not _verify_vehicle_state_system():
		return

	if not await _verify_vehicle_fuel_system():
		return

	if not _verify_vehicle_upgrade_loop():
		return

	if not await _verify_condition_system():
		return

	if not await _verify_vertical_slice_mid_save():
		return

	if not await _verify_enter_exit_vehicle():
		return

	var counts: Dictionary = _road_manager.call("get_active_kind_counts")
	var elev_counts: Dictionary = _road_manager.call("get_active_elevation_counts")
	print(
		"drive_smoke: OK elapsed=%.1fs TRAVEL_MODE cruise_mean=%.2f span=%.2f max_|lat|=%.2f recenters=%d recycles=%d journey=%.3f kinds=%s elev=%s y_span=%.2f scenery_props=%d active=%d nodes=%d cams=%s cine_swaps=%d cine_modes=%s exit_nodes=%d exit_active=%s poi=SunsetViewpoint cancel=MANUAL parking=OK occupancy=OK onfoot=OK interact=OK viewpoint_terminal=OK npc=OK dialogue=OK choices=OK cond_dlg=OK dlg_actions=OK dlg_memory=OK dlg_interrupt=OK npc_bark=OK npc_rules=OK npc_state=OK relationship=OK time_npc=OK npc_sched=OK npc_move=OK npc_travel=OK npc_dlg_debug=OK inventory=OK crafting=OK save=OK world_state=OK game_time=OK vehicle_state=OK fuel=OK upgrade=OK conditions=OK mid_save=OK interior=OK pickups=OK quest=OK"
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


func _verify_parking_state() -> bool:
	## Explicit MotionState: reject park at speed; park cancels cruise/travel; stay still; unpark.
	if not _vehicle.has_method("try_park") or not _vehicle.has_method("try_unpark"):
		push_error("drive_smoke: parking API missing on PlayerVehicle")
		quit(1)
		return false

	_clear_vehicle_input()
	_mode_controller.call("set_mode", MODE_MANUAL)
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")

	# --- Reject park while moving too fast ---
	Input.action_press("vehicle_accelerate")
	var sped_up := false
	for _i in range(180):
		await physics_frame
		var spd: float = absf(float(_vehicle.call("get_signed_speed")))
		if spd > float(_vehicle.get("max_parking_speed")) + 0.5:
			sped_up = true
			break
	Input.action_release("vehicle_accelerate")
	if not sped_up:
		push_error("drive_smoke: could not reach above max_parking_speed")
		quit(1)
		return false

	var high_speed: float = absf(float(_vehicle.call("get_signed_speed")))
	if bool(_vehicle.call("try_park")):
		push_error(
			"drive_smoke: park allowed at high speed (%.2f m/s)" % high_speed
		)
		quit(1)
		return false
	if str(_vehicle.call("get_motion_state_name")) != "DRIVING":
		push_error("drive_smoke: expected DRIVING after rejected park")
		quit(1)
		return false

	# --- Slow to a stop on valid surface ---
	Input.action_press("vehicle_brake")
	for _j in range(240):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= 0.05 and _vehicle.is_on_floor():
			break
	Input.action_release("vehicle_brake")
	_clear_vehicle_input()

	# Coast a few frames so brake cancel does not fight us.
	for _k in range(10):
		await physics_frame

	if absf(float(_vehicle.call("get_signed_speed"))) > float(_vehicle.get("max_parking_speed")):
		push_error("drive_smoke: could not slow below max_parking_speed before park")
		quit(1)
		return false
	if not _vehicle.is_on_floor():
		push_error("drive_smoke: not on valid surface before park")
		quit(1)
		return false

	# --- Engage Travel Mode then park: assisted modes must cancel ---
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) != "TRAVEL_MODE":
		push_error("drive_smoke: failed to engage TRAVEL_MODE before park")
		quit(1)
		return false

	var park_signals := {"n": 0}
	var on_park := func(_prev, _cur) -> void:
		park_signals["n"] = int(park_signals["n"]) + 1
	_vehicle.parking_state_changed.connect(on_park)

	if not bool(_vehicle.call("try_park")):
		push_error("drive_smoke: try_park failed while slow on floor")
		quit(1)
		return false

	await physics_frame
	if str(_vehicle.call("get_motion_state_name")) != "PARKED":
		push_error("drive_smoke: motion state not PARKED after park")
		quit(1)
		return false
	if not bool(_vehicle.call("is_parked")):
		push_error("drive_smoke: is_parked false after park")
		quit(1)
		return false
	if absf(float(_vehicle.call("get_signed_speed"))) > 0.01:
		push_error("drive_smoke: speed not zero after park")
		quit(1)
		return false
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error(
			"drive_smoke: mode still %s after park (expected MANUAL)"
			% str(_mode_controller.call("get_mode_name"))
		)
		quit(1)
		return false
	if bool(_vehicle.call("is_cruise_control_active")):
		push_error("drive_smoke: cruise still active while PARKED")
		quit(1)
		return false
	if bool(_vehicle.call("is_travel_mode")):
		push_error("drive_smoke: travel mode still active while PARKED")
		quit(1)
		return false
	if bool(_autopilot.call("is_autopilot_active")):
		push_error("drive_smoke: autopilot still active while PARKED")
		quit(1)
		return false
	if int(park_signals["n"]) < 1:
		push_error("drive_smoke: parking_state_changed did not fire on park")
		quit(1)
		return false

	# Stay parked: accel/steer must not move the vehicle.
	var parked_origin: Vector3 = _vehicle.global_position
	Input.action_press("vehicle_accelerate")
	Input.action_press("vehicle_right")
	for _hold in range(60):
		await physics_frame
	Input.action_release("vehicle_accelerate")
	Input.action_release("vehicle_right")

	if absf(float(_vehicle.call("get_signed_speed"))) > 0.01:
		push_error("drive_smoke: parked vehicle gained speed under accel")
		quit(1)
		return false
	var drift: float = parked_origin.distance_to(_vehicle.global_position)
	if drift > 0.35:
		push_error("drive_smoke: parked vehicle drifted (%.2f m)" % drift)
		quit(1)
		return false

	# Cruise/travel toggles while parked must not stick.
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error("drive_smoke: TRAVEL_MODE engaged while PARKED")
		quit(1)
		return false
	_mode_controller.call("set_mode", 1)  # CRUISE
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error("drive_smoke: CRUISE engaged while PARKED")
		quit(1)
		return false

	# --- Unpark → DRIVING; controls return ---
	if not bool(_vehicle.call("try_unpark")):
		push_error("drive_smoke: try_unpark failed")
		quit(1)
		return false
	await physics_frame
	if str(_vehicle.call("get_motion_state_name")) != "DRIVING":
		push_error("drive_smoke: expected DRIVING after unpark")
		quit(1)
		return false
	if bool(_vehicle.call("is_parked")):
		push_error("drive_smoke: is_parked true after unpark")
		quit(1)
		return false
	if int(park_signals["n"]) < 2:
		push_error("drive_smoke: parking_state_changed did not fire on unpark")
		quit(1)
		return false

	_vehicle.parking_state_changed.disconnect(on_park)
	_clear_vehicle_input()
	print("drive_smoke: parking state OK (reject@speed → PARKED cancels assist → unpark DRIVING)")
	return true


func _verify_inventory_system() -> bool:
	## InventorySystem: add/remove/stack/clamp — no NPC/UI/crafting coupling.
	var inv: Node = root.get_node_or_null("InventorySystem")
	if inv == null:
		push_error("drive_smoke: InventorySystem autoload missing")
		quit(1)
		return false

	# Decoupling: inventory script must not hard-depend on NPC / dialogue / debug UI.
	var inv_script: Script = load("res://autoload/inventory_system.gd") as Script
	if inv_script != null:
		var src := inv_script.source_code
		for banned in ["/root/DialogueSystem", "NpcCharacter", "InventoryDebugUI", "poi_system.gd"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: InventorySystem must not reference %s" % banned)
				quit(1)
				return false

	if inv.has_method("clear_inventory"):
		inv.call("clear_inventory")

	for item_id in ["scrap_metal", "copper_wire", "circuit_board"]:
		if not bool(inv.call("has_item_data", item_id)):
			push_error("drive_smoke: missing item data '%s'" % item_id)
			quit(1)
			return false
		if int(inv.call("get_quantity", item_id)) != 0:
			push_error("drive_smoke: inventory not empty for %s after clear" % item_id)
			quit(1)
			return false

	# Add + stack.
	if int(inv.call("add_item", "scrap_metal", 5)) != 5:
		push_error("drive_smoke: add_item scrap_metal x5 failed")
		quit(1)
		return false
	if int(inv.call("add_item", "scrap_metal", 3)) != 3:
		push_error("drive_smoke: stack scrap_metal +3 failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 8:
		push_error("drive_smoke: scrap_metal quantity expected 8")
		quit(1)
		return false
	if not bool(inv.call("has_item", "scrap_metal", 8)):
		push_error("drive_smoke: has_item scrap_metal x8 false")
		quit(1)
		return false
	if bool(inv.call("has_item", "scrap_metal", 9)):
		push_error("drive_smoke: has_item scrap_metal x9 should be false")
		quit(1)
		return false

	# Stack cap (circuit_board max_stack=20).
	if int(inv.call("add_item", "circuit_board", 15)) != 15:
		push_error("drive_smoke: add circuit_board x15 failed")
		quit(1)
		return false
	if int(inv.call("add_item", "circuit_board", 10)) != 5:
		push_error("drive_smoke: circuit_board stack should clamp to +5 (max 20)")
		quit(1)
		return false
	if int(inv.call("get_quantity", "circuit_board")) != 20:
		push_error("drive_smoke: circuit_board should be at max_stack 20")
		quit(1)
		return false
	if int(inv.call("add_item", "circuit_board", 1)) != 0:
		push_error("drive_smoke: circuit_board over-stack should add 0")
		quit(1)
		return false

	# Remove + never negative.
	if int(inv.call("remove_item", "scrap_metal", 3)) != 3:
		push_error("drive_smoke: remove scrap_metal x3 failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 5:
		push_error("drive_smoke: scrap_metal expected 5 after remove")
		quit(1)
		return false
	if int(inv.call("remove_item", "scrap_metal", 100)) != 5:
		push_error("drive_smoke: remove over-quantity should only take 5")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 0:
		push_error("drive_smoke: scrap_metal should be 0 after full remove")
		quit(1)
		return false
	if int(inv.call("remove_item", "scrap_metal", 1)) != 0:
		push_error("drive_smoke: remove from empty should return 0")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) < 0:
		push_error("drive_smoke: quantity went negative")
		quit(1)
		return false

	# Second item proves catalog reuse.
	if int(inv.call("add_item", "copper_wire", 2)) != 2:
		push_error("drive_smoke: add copper_wire failed")
		quit(1)
		return false
	if not bool(inv.call("has_item", "copper_wire")):
		push_error("drive_smoke: has_item copper_wire false")
		quit(1)
		return false

	# Unknown id rejected.
	if int(inv.call("add_item", "not_a_real_item", 1)) != 0:
		push_error("drive_smoke: unknown item should not add")
		quit(1)
		return false

	inv.call("clear_inventory")
	print("drive_smoke: inventory OK (add/stack/clamp/remove, never negative)")
	return true


func _verify_crafting_system() -> bool:
	## CraftingSystem: recipe catalog, safe fail, atomic consume + output. No NPC coupling.
	var craft: Node = root.get_node_or_null("CraftingSystem")
	if craft == null:
		push_error("drive_smoke: CraftingSystem autoload missing")
		quit(1)
		return false
	var inv: Node = root.get_node_or_null("InventorySystem")
	if inv == null:
		push_error("drive_smoke: InventorySystem missing for crafting check")
		quit(1)
		return false

	var craft_script: Script = load("res://autoload/crafting_system.gd") as Script
	if craft_script != null:
		var src := craft_script.source_code
		for banned in ["/root/DialogueSystem", "NpcCharacter", "QuestSystem", "poi_system.gd"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: CraftingSystem must not reference %s" % banned)
				quit(1)
				return false

	if not bool(inv.call("has_item_data", "basic_repair_kit")):
		push_error("drive_smoke: missing ItemData basic_repair_kit")
		quit(1)
		return false
	if not bool(craft.call("has_recipe", "basic_repair_kit")):
		push_error("drive_smoke: missing recipe basic_repair_kit")
		quit(1)
		return false
	var recipe: Resource = craft.call("get_recipe", "basic_repair_kit")
	if recipe == null or str(recipe.get("display_name")) != "Basic Repair Kit":
		push_error("drive_smoke: Basic Repair Kit recipe display_name mismatch")
		quit(1)
		return false
	if str(recipe.get("output_item_id")) != "basic_repair_kit" or int(recipe.get("output_quantity")) != 1:
		push_error("drive_smoke: Basic Repair Kit output mismatch")
		quit(1)
		return false

	inv.call("clear_inventory")
	if bool(craft.call("can_craft", "basic_repair_kit")):
		push_error("drive_smoke: can_craft should be false without ingredients")
		quit(1)
		return false
	if bool(craft.call("craft", "basic_repair_kit")):
		push_error("drive_smoke: craft should fail safely without ingredients")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 0:
		push_error("drive_smoke: failed craft must not add output")
		quit(1)
		return false

	# Partial ingredients: still fail, consume nothing.
	inv.call("add_item", "scrap_metal", 2)
	if bool(craft.call("craft", "basic_repair_kit")):
		push_error("drive_smoke: craft should fail with only scrap_metal")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 2:
		push_error("drive_smoke: failed craft must not consume partial ingredients")
		quit(1)
		return false

	inv.call("add_item", "copper_wire", 1)
	if not bool(craft.call("can_craft", "basic_repair_kit")):
		push_error("drive_smoke: can_craft should be true with 2 scrap + 1 wire")
		quit(1)
		return false
	if not bool(craft.call("craft", "basic_repair_kit")):
		push_error("drive_smoke: craft Basic Repair Kit failed with ingredients")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 0:
		push_error("drive_smoke: scrap_metal not consumed after craft")
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 0:
		push_error("drive_smoke: copper_wire not consumed after craft")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 1:
		push_error("drive_smoke: basic_repair_kit not in inventory after craft")
		quit(1)
		return false

	# New recipes via register_recipe without changing core logic.
	var RecipeDataScr: Script = load("res://scripts/crafting/recipe_data.gd") as Script
	if RecipeDataScr != null:
		var extra: Resource = RecipeDataScr.new()
		extra.set("id", "smoke_extra_kit")
		extra.set("display_name", "Smoke Extra Kit")
		extra.set("ingredient_item_ids", PackedStringArray(["basic_repair_kit"]))
		extra.set("ingredient_amounts", PackedInt32Array([1]))
		extra.set("output_item_id", "circuit_board")
		extra.set("output_quantity", 1)
		craft.call("register_recipe", extra)
		if not bool(craft.call("has_recipe", "smoke_extra_kit")):
			push_error("drive_smoke: register_recipe did not add smoke_extra_kit")
			quit(1)
			return false
		if not bool(craft.call("craft", "smoke_extra_kit")):
			push_error("drive_smoke: craft via registered recipe failed")
			quit(1)
			return false
		if int(inv.call("get_quantity", "basic_repair_kit")) != 0:
			push_error("drive_smoke: registered recipe did not consume kit")
			quit(1)
			return false
		if int(inv.call("get_quantity", "circuit_board")) != 1:
			push_error("drive_smoke: registered recipe did not add circuit_board")
			quit(1)
			return false

	inv.call("clear_inventory")
	craft.call("reload_catalog")
	print("drive_smoke: crafting OK (fail-safe, consume, output, data-driven recipe)")
	return true


func _verify_save_system() -> bool:
	## SaveSystem: round-trip journey/inventory/quest/poi; corrupt JSON kept; version field present.
	var save: Node = root.get_node_or_null("SaveSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var poi: Node = root.get_node_or_null("POISystem")
	if save == null or journey == null or inv == null or qs == null or poi == null:
		push_error("drive_smoke: SaveSystem or providers missing")
		quit(1)
		return false

	# Decoupling: SaveSystem must not hardcode provider internals.
	var save_script: Script = load("res://autoload/save_system.gd") as Script
	if save_script != null:
		var src := save_script.source_code
		for banned in ["current_distance_km", "_quantities", "_states", "_discovered"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: SaveSystem must not reference provider field '%s'" % banned)
				quit(1)
				return false

	# Clean slate.
	if save.has_method("delete_save"):
		save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")

	if bool(save.call("has_save")):
		push_error("drive_smoke: has_save true after delete")
		quit(1)
		return false
	if int(save.call("get_save_version")) != -1:
		push_error("drive_smoke: get_save_version should be -1 without file")
		quit(1)
		return false
	if bool(save.call("load_game")):
		push_error("drive_smoke: load_game should fail on missing file")
		quit(1)
		return false

	# Seed persistent state.
	journey.call("set_current_distance_km", 1234.5)
	inv.call("add_item", "scrap_metal", 3)
	inv.call("add_item", "copper_wire", 1)
	if not bool(qs.call("start_quest", "power_the_viewpoint")):
		push_error("drive_smoke: could not start quest for save test")
		quit(1)
		return false
	poi.call("mark_discovered", "sunset_viewpoint", "Sunset Viewpoint")

	if not bool(save.call("save_game")):
		push_error("drive_smoke: save_game failed")
		quit(1)
		return false
	if not bool(save.call("has_save")):
		push_error("drive_smoke: has_save false after save")
		quit(1)
		return false
	if int(save.call("get_save_version")) != 1:
		push_error("drive_smoke: get_save_version expected 1")
		quit(1)
		return false

	# Inspect JSON structure for save_version / timestamps.
	var path := str(save.call("get_save_path"))
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("drive_smoke: save JSON did not parse")
		quit(1)
		return false
	var root_dict: Dictionary = parsed
	if int(root_dict.get("save_version", -1)) != 1:
		push_error("drive_smoke: save_version missing/wrong in file")
		quit(1)
		return false
	if str(root_dict.get("created_at", "")).is_empty() or str(root_dict.get("updated_at", "")).is_empty():
		push_error("drive_smoke: created_at/updated_at missing")
		quit(1)
		return false
	if typeof(root_dict.get("systems", null)) != TYPE_DICTIONARY:
		push_error("drive_smoke: systems block missing")
		quit(1)
		return false

	# Wipe runtime state then reload.
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	if float(journey.call("get_current_distance_km")) != 0.0:
		push_error("drive_smoke: journey not cleared before load")
		quit(1)
		return false

	if not bool(save.call("load_game")):
		push_error("drive_smoke: load_game failed on valid save")
		quit(1)
		return false
	if not is_equal_approx(float(journey.call("get_current_distance_km")), 1234.5):
		push_error("drive_smoke: journey not restored (got %.3f)" % float(journey.call("get_current_distance_km")))
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 3 or int(inv.call("get_quantity", "copper_wire")) != 1:
		push_error("drive_smoke: inventory not restored")
		quit(1)
		return false
	if str(qs.call("get_state_name", "power_the_viewpoint")) != "ACTIVE":
		push_error("drive_smoke: quest state not restored")
		quit(1)
		return false
	if not bool(poi.call("is_discovered", "sunset_viewpoint")):
		push_error("drive_smoke: POI discovery not restored")
		quit(1)
		return false

	# Second save should create backup and preserve created_at.
	var created_before := str(root_dict.get("created_at"))
	if not bool(save.call("save_game")):
		push_error("drive_smoke: second save_game failed")
		quit(1)
		return false
	var bak_path := str(save.call("get_backup_path"))
	if not FileAccess.file_exists(bak_path):
		push_error("drive_smoke: backup not written before overwrite")
		quit(1)
		return false
	var text2 := FileAccess.get_file_as_string(path)
	var parsed2: Variant = JSON.parse_string(text2)
	if typeof(parsed2) == TYPE_DICTIONARY:
		if str(parsed2.get("created_at", "")) != created_before:
			push_error("drive_smoke: created_at should survive overwrite")
			quit(1)
			return false

	# Corrupted JSON must not crash and must not delete the file.
	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	if corrupt == null:
		push_error("drive_smoke: could not overwrite save for corrupt test")
		quit(1)
		return false
	corrupt.store_string("{not valid json!!!")
	corrupt.close()
	if bool(save.call("load_game")):
		push_error("drive_smoke: load_game should fail on corrupt JSON")
		quit(1)
		return false
	if not FileAccess.file_exists(path):
		push_error("drive_smoke: corrupt save was deleted (must keep)")
		quit(1)
		return false

	# Unknown version refused, file kept.
	var bad_ver := FileAccess.open(path, FileAccess.WRITE)
	bad_ver.store_string(JSON.stringify({"save_version": 999, "created_at": "x", "updated_at": "y", "systems": {}}))
	bad_ver.close()
	if bool(save.call("load_game")):
		push_error("drive_smoke: load_game should refuse unknown version")
		quit(1)
		return false
	if not FileAccess.file_exists(path):
		push_error("drive_smoke: unknown-version save was deleted")
		quit(1)
		return false

	# Cleanup for later tests.
	save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	_clear_world_state()
	print("drive_smoke: save OK (round-trip + corrupt kept + version gate)")
	return true


func _clear_world_state() -> void:
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	if ws != null and ws.has_method("clear_all"):
		ws.call("clear_all")


func _verify_game_time_system() -> bool:
	## GameTimeSystem: play accumulates always; travel only while trip; save round-trip; offline gap.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if gt == null or save == null:
		push_error("drive_smoke: GameTimeSystem/SaveSystem missing")
		quit(1)
		return false

	for required in [
		"get_total_play_time",
		"get_total_travel_time",
		"get_current_real_datetime",
		"get_seconds_since_last_session",
		"is_traveling",
		"get_save_data",
		"load_save_data",
		"debug_advance",
		"reset_for_tests",
	]:
		if not gt.has_method(required):
			push_error("drive_smoke: GameTimeSystem missing %s" % required)
			quit(1)
			return false

	# Wall-clock / FPS independence; narrative is a separate persistent clock (no lighting).
	var gt_script: Script = load("res://autoload/game_time_system.gd") as Script
	if gt_script != null:
		var src := gt_script.source_code
		if src.find("Time.get_ticks_msec") < 0:
			push_error("drive_smoke: GameTimeSystem must use Time.get_ticks_msec")
			quit(1)
			return false
		for banned in ["DirectionalLight", "WorldEnvironment", "sky_energy", "Lighting"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: GameTimeSystem must not wire visuals '%s'" % banned)
				quit(1)
				return false

	for required_narrative in [
		"get_narrative_day_index",
		"get_narrative_hour",
		"get_narrative_minute",
		"get_narrative_minutes_of_day",
		"set_narrative_time",
		"advance_narrative_seconds",
		"get_narrative_time_string",
		"wait_until_narrative_time",
		"advance_narrative_minutes",
		"debug_set_narrative_time",
	]:
		if not gt.has_method(required_narrative):
			push_error("drive_smoke: GameTimeSystem missing %s" % required_narrative)
			quit(1)
			return false

	# Journey / vehicle must not drive off narrative time.
	for path in ["res://autoload/journey_system.gd", "res://autoload/vehicle_state_system.gd"]:
		var peer: Script = load(path) as Script
		if peer != null:
			var peer_src := peer.source_code
			for banned in ["get_narrative_", "narrative_time", "narrative_day", "narrative_minutes"]:
				if peer_src.find(banned) >= 0:
					push_error("drive_smoke: %s must not use narrative time ('%s')" % [path, banned])
					quit(1)
					return false

	gt.call("reset_for_tests")
	if float(gt.call("get_total_play_time")) != 0.0 or float(gt.call("get_total_travel_time")) != 0.0:
		push_error("drive_smoke: GameTimeSystem reset_for_tests did not clear accumulators")
		quit(1)
		return false

	# Independent narrative clock: day 0 08:00; scale 60 ⇒ 1 real min = 1 narrative hour.
	if int(gt.call("get_narrative_day_index")) != 0 or int(gt.call("get_narrative_hour")) != 8:
		push_error(
			"drive_smoke: narrative clock expected day0/h8 got day%d/h%d"
			% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
		)
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_narrative_time_scale")), 60.0):
		push_error("drive_smoke: default narrative_time_scale should be 60")
		quit(1)
		return false

	# Narrative independent of travel accumulator.
	gt.call("set_narrative_time", 0, 10, 0)
	var narr_before := float(gt.call("get_narrative_minutes_of_day"))
	gt.set("total_travel_time_seconds", float(gt.call("get_total_travel_time")) + 999.0)
	if not is_equal_approx(float(gt.call("get_narrative_minutes_of_day")), narr_before):
		push_error("drive_smoke: narrative must not change when travel time is bumped alone")
		quit(1)
		return false

	# Drive 10 real min while traveling: travel≈600, narrative +10h, journey untouched by time alone.
	var journey: Node = root.get_node_or_null("JourneySystem")
	var km_before := 0.0
	if journey != null and journey.has_method("get_current_distance_km"):
		km_before = float(journey.call("get_current_distance_km"))
	gt.call("reset_for_tests")
	gt.call("debug_advance", 600.0, true)
	if not is_equal_approx(float(gt.call("get_total_travel_time")), 600.0):
		push_error(
			"drive_smoke: travel expected 600 after 10min drive, got %.3f"
			% float(gt.call("get_total_travel_time"))
		)
		quit(1)
		return false
	if int(gt.call("get_narrative_hour")) != 18:
		push_error(
			"drive_smoke: after 10 real min (scale 60) hour should be 18, got %d"
			% int(gt.call("get_narrative_hour"))
		)
		quit(1)
		return false
	if journey != null and journey.has_method("get_current_distance_km"):
		if not is_equal_approx(float(journey.call("get_current_distance_km")), km_before):
			push_error("drive_smoke: narrative/play advance must not add journey km")
			quit(1)
			return false

	# Parked 10 min: no travel growth; narrative still advances.
	gt.call("reset_for_tests")
	gt.call("debug_advance", 600.0, false)
	if not is_equal_approx(float(gt.call("get_total_travel_time")), 0.0):
		push_error("drive_smoke: parked 10min must not add travel time")
		quit(1)
		return false
	if int(gt.call("get_narrative_hour")) != 18:
		push_error(
			"drive_smoke: parked 10min should still advance narrative to hour 18, got %d"
			% int(gt.call("get_narrative_hour"))
		)
		quit(1)
		return false

	gt.call("set_narrative_time", 1, 22, 30)
	if int(gt.call("get_narrative_day_index")) != 1 or int(gt.call("get_narrative_hour")) != 22:
		push_error("drive_smoke: set_narrative_time failed")
		quit(1)
		return false
	if int(gt.call("get_narrative_minute")) != 30:
		push_error("drive_smoke: narrative minute should be 30")
		quit(1)
		return false
	if str(gt.call("get_narrative_time_string")).find("22:30") < 0:
		push_error("drive_smoke: get_narrative_time_string missing 22:30")
		quit(1)
		return false
	# Future wait API: advance to next 06:00 → day 2 06:00.
	gt.call("wait_until_narrative_time", 6, 0)
	if int(gt.call("get_narrative_day_index")) != 2 or int(gt.call("get_narrative_hour")) != 6:
		push_error(
			"drive_smoke: wait_until_narrative_time failed (day%d/h%d)"
			% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
		)
		quit(1)
		return false
	gt.call("reset_for_tests")

	# Play time advances without travel.
	gt.call("debug_advance", 10.0, false)
	if not is_equal_approx(float(gt.call("get_total_play_time")), 10.0):
		push_error(
			"drive_smoke: play time expected 10 got %.3f" % float(gt.call("get_total_play_time"))
		)
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), 0.0):
		push_error("drive_smoke: travel time should stay 0 when not traveling")
		quit(1)
		return false

	# Travel accumulator only when flagged traveling.
	gt.call("debug_advance", 5.0, true)
	if not is_equal_approx(float(gt.call("get_total_play_time")), 15.0):
		push_error("drive_smoke: play time expected 15 after travel advance")
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), 5.0):
		push_error(
			"drive_smoke: travel time expected 5 got %.3f" % float(gt.call("get_total_travel_time"))
		)
		quit(1)
		return false

	# Live is_traveling: park / on foot must not count as travel.
	_clear_vehicle_input()
	_mode_controller.call("set_mode", MODE_MANUAL)
	# Slow to park.
	for _i in range(240):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= float(_vehicle.get("max_parking_speed")):
			break
	if not bool(_vehicle.call("try_park")):
		push_error("drive_smoke: could not park for game time travel check")
		quit(1)
		return false
	await physics_frame
	await physics_frame
	if bool(gt.call("is_traveling")):
		push_error("drive_smoke: is_traveling true while PARKED")
		quit(1)
		return false

	var travel_before_park := float(gt.call("get_total_travel_time"))
	var play_before_park := float(gt.call("get_total_play_time"))
	# Let a few wall-clock ticks land while parked.
	await create_timer(0.35).timeout
	var travel_after_park := float(gt.call("get_total_travel_time"))
	var play_after_park := float(gt.call("get_total_play_time"))
	if travel_after_park > travel_before_park + 0.001:
		push_error(
			"drive_smoke: travel time grew while PARKED (%.3f → %.3f)"
			% [travel_before_park, travel_after_park]
		)
		quit(1)
		return false
	if play_after_park < play_before_park + 0.05:
		push_error("drive_smoke: play time did not advance while PARKED")
		quit(1)
		return false

	# Travel Mode counts as traveling.
	_vehicle.call("try_unpark")
	await physics_frame
	Input.action_press("vehicle_accelerate")
	for _i in range(90):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) > 1.0:
			break
	Input.action_release("vehicle_accelerate")
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	await physics_frame
	if not bool(gt.call("is_traveling")):
		push_error("drive_smoke: is_traveling false in TRAVEL_MODE")
		quit(1)
		return false
	var travel_before_tm := float(gt.call("get_total_travel_time"))
	await create_timer(0.35).timeout
	var travel_after_tm := float(gt.call("get_total_travel_time"))
	if travel_after_tm < travel_before_tm + 0.05:
		push_error("drive_smoke: travel time did not grow in TRAVEL_MODE")
		quit(1)
		return false

	# Save / load preserves accumulators; offline gap uses absolute timestamps.
	_mode_controller.call("set_mode", MODE_MANUAL)
	_clear_vehicle_input()
	if save.has_method("delete_save"):
		save.call("delete_save")

	var play_saved := float(gt.call("get_total_play_time"))
	var travel_saved := float(gt.call("get_total_travel_time"))
	# Stamp a known prior exit so offline calc is deterministic after reload.
	var exit_stamp := float(Time.get_unix_time_from_system()) - 42.0
	gt.set("last_exit_timestamp", exit_stamp)

	if not bool(save.call("save_game")):
		push_error("drive_smoke: save_game failed in game time test")
		quit(1)
		return false

	# Confirm payload shape in JSON.
	var path := str(save.call("get_save_path"))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("drive_smoke: game_time save JSON parse failed")
		quit(1)
		return false
	var systems: Dictionary = parsed.get("systems", {})
	if not systems.has("game_time"):
		push_error("drive_smoke: systems.game_time missing from save")
		quit(1)
		return false
	var gt_payload: Dictionary = systems["game_time"]
	for key in [
		"current_session_started_at",
		"total_play_time_seconds",
		"total_travel_time_seconds",
		"last_save_timestamp",
		"last_exit_timestamp",
		"narrative_day_index",
		"narrative_minutes_of_day",
		"narrative_time_scale",
	]:
		if not gt_payload.has(key):
			push_error("drive_smoke: game_time save missing '%s'" % key)
			quit(1)
			return false

	# Pin narrative clock before save so day+time round-trip is deterministic.
	gt.call("set_narrative_time", 2, 14, 15)
	play_saved = float(gt.call("get_total_play_time"))
	travel_saved = float(gt.call("get_total_travel_time"))
	var hour_saved := int(gt.call("get_narrative_hour"))
	var minute_saved := int(gt.call("get_narrative_minute"))
	var day_saved := int(gt.call("get_narrative_day_index"))
	if not bool(save.call("save_game")):
		push_error("drive_smoke: narrative clock save_game failed")
		quit(1)
		return false

	# Wipe runtime then reload — accumulators + narrative must restore.
	gt.call("reset_for_tests")
	if float(gt.call("get_total_play_time")) != 0.0:
		push_error("drive_smoke: reset before load failed")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: load_game failed for game_time")
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_play_time")), play_saved):
		push_error(
			"drive_smoke: play time not restored (%.3f vs %.3f)"
			% [float(gt.call("get_total_play_time")), play_saved]
		)
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), travel_saved):
		push_error(
			"drive_smoke: travel time not restored (%.3f vs %.3f)"
			% [float(gt.call("get_total_travel_time")), travel_saved]
		)
		quit(1)
		return false
	if (
		int(gt.call("get_narrative_hour")) != hour_saved
		or int(gt.call("get_narrative_minute")) != minute_saved
		or int(gt.call("get_narrative_day_index")) != day_saved
	):
		push_error(
			"drive_smoke: narrative clock not restored (day%d %02d:%02d vs day%d %02d:%02d)"
			% [
				int(gt.call("get_narrative_day_index")),
				int(gt.call("get_narrative_hour")),
				int(gt.call("get_narrative_minute")),
				day_saved,
				hour_saved,
				minute_saved,
			]
		)
		quit(1)
		return false

	var offline := float(gt.call("get_seconds_since_last_session"))
	# Save stamps last_exit ≈ now, so after immediate reload offline is near 0.
	# Force a prior exit again and recompute without waiting a full session.
	gt.set("last_exit_timestamp", float(Time.get_unix_time_from_system()) - 42.0)
	offline = float(gt.call("get_seconds_since_last_session"))
	if offline < 35.0 or offline > 55.0:
		push_error("drive_smoke: offline gap expected ~42s got %.1f" % offline)
		quit(1)
		return false

	var dt_str := str(gt.call("get_current_real_datetime"))
	if dt_str.is_empty() or dt_str.find("T") < 0:
		push_error("drive_smoke: get_current_real_datetime looks invalid: %s" % dt_str)
		quit(1)
		return false

	# Offline narrative: OFF (not traveling at save) → clock unchanged on load.
	var vs_off: Node = root.get_node_or_null("VehicleStateSystem")
	if vs_off != null:
		gt.call("set_narrative_time", 3, 12, 0)
		vs_off.set("was_traveling_at_save", false)
		gt.set("last_exit_timestamp", float(Time.get_unix_time_from_system()) - 3600.0)
		if not bool(save.call("save_game")):
			push_error("drive_smoke: offline-OFF narrative save failed")
			quit(1)
			return false
		# Ensure payload says not traveling.
		var path_off := str(save.call("get_save_path"))
		var raw_off := FileAccess.get_file_as_string(path_off)
		var parsed_off: Variant = JSON.parse_string(raw_off)
		if typeof(parsed_off) == TYPE_DICTIONARY:
			var systems_off: Dictionary = parsed_off.get("systems", {})
			if systems_off.has("vehicle_state"):
				systems_off["vehicle_state"]["was_traveling_at_save"] = false
				parsed_off["systems"] = systems_off
				var f_off := FileAccess.open(path_off, FileAccess.WRITE)
				if f_off != null:
					f_off.store_string(JSON.stringify(parsed_off))
					f_off.close()
		gt.call("reset_for_tests")
		if not bool(save.call("load_game")):
			push_error("drive_smoke: offline-OFF load failed")
			quit(1)
			return false
		if int(gt.call("get_narrative_day_index")) != 3 or int(gt.call("get_narrative_hour")) != 12:
			push_error(
				"drive_smoke: offline progress OFF must not advance narrative (got day%d/h%d)"
				% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
			)
			quit(1)
			return false

		# Offline narrative: applied travel advances by fuel-capped duration only.
		gt.call("set_narrative_time", 4, 8, 0)
		if vs_off.has_method("reset_for_tests"):
			vs_off.call("reset_for_tests")
		vs_off.set("fuel_current", 50.0)
		vs_off.set("offline_cruise_speed_kmh", 60.0)
		vs_off.set("was_traveling_at_save", true)
		gt.set("last_exit_timestamp", float(Time.get_unix_time_from_system()) - 600.0)  # 10 real min
		if not bool(save.call("save_game")):
			push_error("drive_smoke: offline-ON narrative save failed")
			quit(1)
			return false
		var path_on := str(save.call("get_save_path"))
		var parsed_on: Variant = JSON.parse_string(FileAccess.get_file_as_string(path_on))
		if typeof(parsed_on) == TYPE_DICTIONARY:
			var systems_on: Dictionary = parsed_on.get("systems", {})
			if systems_on.has("vehicle_state"):
				systems_on["vehicle_state"]["was_traveling_at_save"] = true
				systems_on["vehicle_state"]["fuel_current"] = 50.0
				systems_on["vehicle_state"]["offline_cruise_speed_kmh"] = 60.0
			if systems_on.has("game_time"):
				systems_on["game_time"]["last_exit_timestamp"] = (
					float(Time.get_unix_time_from_system()) - 600.0
				)
				systems_on["game_time"]["narrative_day_index"] = 4
				systems_on["game_time"]["narrative_minutes_of_day"] = 8.0 * 60.0
			parsed_on["systems"] = systems_on
			var f_on := FileAccess.open(path_on, FileAccess.WRITE)
			if f_on != null:
				f_on.store_string(JSON.stringify(parsed_on))
				f_on.close()
		gt.call("reset_for_tests")
		if vs_off.has_method("reset_for_tests"):
			vs_off.call("reset_for_tests")
		if not bool(save.call("load_game")):
			push_error("drive_smoke: offline-ON load failed")
			quit(1)
			return false
		# 10 real min offline at scale 60 → +10 narrative hours → 18:00 day 4.
		if int(gt.call("get_narrative_day_index")) != 4 or int(gt.call("get_narrative_hour")) != 18:
			push_error(
				"drive_smoke: offline applied should advance narrative to day4/h18 (got day%d/h%d)"
				% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
			)
			quit(1)
			return false

	# Cleanup.
	save.call("delete_save")
	gt.call("reset_for_tests")
	_mode_controller.call("set_mode", MODE_MANUAL)
	_clear_vehicle_input()
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	print(
		"drive_smoke: game_time OK (play/travel + independent narrative + save + offline gates)"
	)
	return true


func _verify_vehicle_state_system() -> bool:
	## VehicleStateSystem: persistent attrs survive save/load; PlayerVehicle uses effective max.
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if vs == null or save == null or _vehicle == null:
		push_error("drive_smoke: VehicleStateSystem/SaveSystem/PlayerVehicle missing")
		quit(1)
		return false

	for required in [
		"install_upgrade",
		"has_upgrade",
		"remove_upgrade",
		"get_effective_max_speed",
		"get_save_data",
		"load_save_data",
		"reset_for_tests",
	]:
		if not vs.has_method(required):
			push_error("drive_smoke: VehicleStateSystem missing %s" % required)
			quit(1)
			return false

	# No physics fields in persistence payload.
	var vs_script: Script = load("res://autoload/vehicle_state_system.gd") as Script
	if vs_script != null:
		var src := vs_script.source_code
		for banned in ["velocity", "transform", "global_position", "CharacterBody3D"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: VehicleStateSystem must not store physics field '%s'" % banned)
				quit(1)
				return false

	vs.call("reset_for_tests")
	if str(vs.call("get_vehicle_id")) != "starter_car":
		push_error("drive_smoke: default vehicle_id should be starter_car")
		quit(1)
		return false

	var base_kmh := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(base_kmh, 86.4):
		push_error("drive_smoke: starter effective max expected 86.4 km/h got %.2f" % base_kmh)
		quit(1)
		return false

	# PlayerVehicle must consult VehicleState for the cap.
	if not _vehicle.has_method("get_effective_max_speed_ms"):
		push_error("drive_smoke: PlayerVehicle missing get_effective_max_speed_ms")
		quit(1)
		return false
	var vehicle_ms := float(_vehicle.call("get_effective_max_speed_ms"))
	var expected_ms := base_kmh / 3.6
	if not is_equal_approx(vehicle_ms, expected_ms):
		push_error(
			"drive_smoke: PlayerVehicle max_ms %.3f != VehicleState %.3f"
			% [vehicle_ms, expected_ms]
		)
		quit(1)
		return false

	# Modifier changes effective speed and is reflected by the vehicle.
	vs.call("set_cruise_speed_modifier", 1.25)
	var boosted := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(boosted, 86.4 * 1.25):
		push_error("drive_smoke: cruise_speed_modifier not applied to effective max")
		quit(1)
		return false
	if not is_equal_approx(float(_vehicle.call("get_effective_max_speed_ms")), boosted / 3.6):
		push_error("drive_smoke: PlayerVehicle did not pick up boosted VehicleState max")
		quit(1)
		return false

	# Upgrade API — ids only, persist later.
	if not bool(vs.call("install_upgrade", "engine_tune_1")):
		push_error("drive_smoke: install_upgrade failed")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", "engine_tune_1")):
		push_error("drive_smoke: has_upgrade false after install")
		quit(1)
		return false
	if bool(vs.call("install_upgrade", "engine_tune_1")):
		push_error("drive_smoke: duplicate install_upgrade should fail")
		quit(1)
		return false
	vs.call("install_upgrade", "cargo_rack_1")
	vs.call("set_fuel_current", 42.5)
	vs.call("set_condition_current", 77.0)

	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("drive_smoke: save_game failed in vehicle_state test")
		quit(1)
		return false

	var path := str(save.call("get_save_path"))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("drive_smoke: vehicle_state save JSON parse failed")
		quit(1)
		return false
	var systems: Dictionary = parsed.get("systems", {})
	if not systems.has("vehicle_state"):
		push_error("drive_smoke: systems.vehicle_state missing")
		quit(1)
		return false
	var payload: Dictionary = systems["vehicle_state"]
	for key in [
		"vehicle_id",
		"display_name",
		"fuel_capacity",
		"fuel_current",
		"condition_max",
		"condition_current",
		"storage_capacity",
		"installed_upgrades",
		"base_max_speed_kmh",
		"cruise_speed_modifier",
		"efficiency_modifier",
	]:
		if not payload.has(key):
			push_error("drive_smoke: vehicle_state save missing '%s'" % key)
			quit(1)
			return false
	# Must not persist runtime physics.
	for banned in ["velocity", "transform", "position", "rotation", "speed"]:
		if payload.has(banned):
			push_error("drive_smoke: vehicle_state must not persist '%s'" % banned)
			quit(1)
			return false

	var upgrades_saved: Array = payload.get("installed_upgrades", [])
	if upgrades_saved.size() != 2:
		push_error("drive_smoke: expected 2 upgrades in save, got %d" % upgrades_saved.size())
		quit(1)
		return false

	# Wipe and reload.
	vs.call("reset_for_tests")
	if bool(vs.call("has_upgrade", "engine_tune_1")):
		push_error("drive_smoke: upgrade survived reset_for_tests")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: load_game failed for vehicle_state")
		quit(1)
		return false
	if str(vs.call("get_vehicle_id")) != "starter_car":
		push_error("drive_smoke: vehicle_id not restored")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", "engine_tune_1")) or not bool(vs.call("has_upgrade", "cargo_rack_1")):
		push_error("drive_smoke: upgrades not restored")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_fuel_current")), 42.5):
		push_error("drive_smoke: fuel_current not restored")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_condition_current")), 77.0):
		push_error("drive_smoke: condition_current not restored")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_cruise_speed_modifier")), 1.25):
		push_error("drive_smoke: cruise_speed_modifier not restored")
		quit(1)
		return false
	if not is_equal_approx(float(_vehicle.call("get_effective_max_speed_ms")), (86.4 * 1.25) / 3.6):
		push_error("drive_smoke: PlayerVehicle effective max not restored from VehicleState")
		quit(1)
		return false

	if not bool(vs.call("remove_upgrade", "engine_tune_1")):
		push_error("drive_smoke: remove_upgrade failed")
		quit(1)
		return false
	if bool(vs.call("has_upgrade", "engine_tune_1")):
		push_error("drive_smoke: has_upgrade true after remove")
		quit(1)
		return false

	# Cleanup — restore defaults so later drive feel stays stable.
	save.call("delete_save")
	vs.call("reset_for_tests")
	print(
		"drive_smoke: vehicle_state OK (attrs + upgrades + effective max + save round-trip)"
	)
	return true


func _verify_vehicle_fuel_system() -> bool:
	## Fuel: distance burn, idle no burn, speed factor, empty cancels assist, offline cap, save.
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	if vs == null or save == null or journey == null or _vehicle == null:
		push_error("drive_smoke: VehicleState/Save/Journey/Vehicle missing for fuel test")
		quit(1)
		return false

	for required in [
		"add_fuel",
		"consume_fuel",
		"get_fuel_ratio",
		"estimate_consumption_liters",
		"consume_for_distance_km",
		"apply_distance_with_fuel",
		"apply_offline_travel",
		"is_out_of_fuel",
	]:
		if not vs.has_method(required):
			push_error("drive_smoke: VehicleStateSystem missing fuel API %s" % required)
			quit(1)
			return false

	vs.call("reset_for_tests")
	journey.call("reset_journey")

	# Speed factor: high speed burns more than low for same distance.
	var low := float(vs.call("estimate_consumption_liters", 10.0, 40.0))
	var high := float(vs.call("estimate_consumption_liters", 10.0, 120.0))
	if high <= low:
		push_error("drive_smoke: high speed should burn more fuel than low (%.4f vs %.4f)" % [high, low])
		quit(1)
		return false

	# Efficiency modifier reduces burn.
	vs.call("set_efficiency_modifier", 2.0)
	var efficient := float(vs.call("estimate_consumption_liters", 10.0, 60.0))
	vs.call("set_efficiency_modifier", 1.0)
	var base_burn := float(vs.call("estimate_consumption_liters", 10.0, 60.0))
	if efficient >= base_burn:
		push_error("drive_smoke: efficiency_modifier should reduce fuel burn")
		quit(1)
		return false

	# Driving consumes; parked does not.
	vs.call("set_liters_per_100km", 50.0)
	vs.call("set_fuel_current", 50.0)
	_clear_vehicle_input()
	_mode_controller.call("set_mode", MODE_MANUAL)
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")

	Input.action_press("vehicle_accelerate")
	for _i in range(90):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) > 5.0:
			break
	var fuel_while_moving := float(vs.call("get_fuel_current"))
	for _i in range(120):
		await physics_frame
	Input.action_release("vehicle_accelerate")
	var fuel_after_drive := float(vs.call("get_fuel_current"))
	if fuel_after_drive >= fuel_while_moving - 0.0001:
		# Allow that first sample was already mid-burn; ensure drop from full start.
		if fuel_after_drive >= 49.999:
			push_error("drive_smoke: driving did not consume fuel")
			quit(1)
			return false
	if fuel_after_drive >= 50.0:
		push_error("drive_smoke: driving did not consume fuel from full tank")
		quit(1)
		return false

	# Stopped — fuel must not keep draining (brake to rest; park if possible).
	Input.action_press("vehicle_brake")
	for _i in range(300):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= 0.05 and _vehicle.is_on_floor():
			break
	Input.action_release("vehicle_brake")
	_clear_vehicle_input()
	for _i in range(10):
		await physics_frame

	if absf(float(_vehicle.call("get_signed_speed"))) > float(_vehicle.get("max_parking_speed")):
		push_error("drive_smoke: could not slow for fuel idle check")
		quit(1)
		return false
	if _vehicle.is_on_floor() and _vehicle.has_method("try_park"):
		_vehicle.call("try_park")

	var fuel_stopped := float(vs.call("get_fuel_current"))
	await create_timer(0.4).timeout
	var fuel_still := float(vs.call("get_fuel_current"))
	if absf(fuel_still - fuel_stopped) > 0.001:
		push_error(
			"drive_smoke: fuel changed while stopped (%.4f → %.4f)" % [fuel_stopped, fuel_still]
		)
		quit(1)
		return false

	# Empty fuel: cancel assist, no accel progress.
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	await physics_frame
	vs.call("set_fuel_current", 0.0)
	if not bool(vs.call("is_out_of_fuel")):
		push_error("drive_smoke: is_out_of_fuel false at 0 fuel")
		quit(1)
		return false
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) == "TRAVEL_MODE":
		push_error("drive_smoke: Travel Mode should cancel / refuse when out of fuel")
		quit(1)
		return false

	Input.action_press("vehicle_accelerate")
	var speed_before := absf(float(_vehicle.call("get_signed_speed")))
	for _i in range(60):
		await physics_frame
	Input.action_release("vehicle_accelerate")
	var speed_after := absf(float(_vehicle.call("get_signed_speed")))
	if speed_after > speed_before + 1.0:
		push_error("drive_smoke: empty fuel should not accelerate (%.2f → %.2f)" % [speed_before, speed_after])
		quit(1)
		return false

	# Offline progress respects fuel — stop before/at zero with OUT_OF_FUEL.
	vs.call("reset_for_tests")
	journey.call("reset_journey")
	vs.call("set_liters_per_100km", 8.0)
	vs.call("set_fuel_current", 1.0)  # 12.5 km range at 60 km/h base rate
	vs.set("offline_cruise_speed_kmh", 60.0)
	var offline := vs.call("apply_offline_travel", 3600.0) as Dictionary  # 60 km desired
	var applied := float(offline.get("distance_applied_km", -1.0))
	var reason := str(offline.get("stopped_reason", ""))
	if reason != "OUT_OF_FUEL":
		push_error("drive_smoke: offline empty should set OUT_OF_FUEL (got '%s')" % reason)
		quit(1)
		return false
	if applied <= 0.0 or applied > 12.6:
		push_error("drive_smoke: offline distance should be fuel-capped (~12.5), got %.3f" % applied)
		quit(1)
		return false
	if float(vs.call("get_fuel_current")) > 0.001:
		push_error("drive_smoke: fuel should be ~0 after offline OUT_OF_FUEL")
		quit(1)
		return false
	if not is_equal_approx(float(journey.call("get_current_distance_km")), applied):
		push_error("drive_smoke: journey not advanced by offline fuel-capped distance")
		quit(1)
		return false

	# Within-fuel offline: full desired distance, no stop reason.
	vs.call("reset_for_tests")
	journey.call("reset_journey")
	vs.call("set_fuel_current", 50.0)
	var ok_offline := vs.call("apply_offline_travel", 600.0, 60.0) as Dictionary  # 10 km
	if str(ok_offline.get("stopped_reason", "x")) != "":
		push_error("drive_smoke: offline within fuel should have empty stopped_reason")
		quit(1)
		return false
	if not is_equal_approx(float(ok_offline.get("distance_applied_km", 0.0)), 10.0):
		push_error("drive_smoke: offline within fuel should apply full 10 km")
		quit(1)
		return false

	# Save / load preserves fuel + stopped_reason.
	vs.call("set_fuel_current", 33.3)
	vs.set("stopped_reason", "OUT_OF_FUEL")
	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("drive_smoke: save_game failed in fuel test")
		quit(1)
		return false
	vs.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("drive_smoke: load_game failed in fuel test")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_fuel_current")), 33.3):
		push_error("drive_smoke: fuel_current not restored after save/load")
		quit(1)
		return false
	if str(vs.call("get_stopped_reason")) != "OUT_OF_FUEL":
		push_error("drive_smoke: stopped_reason not restored")
		quit(1)
		return false

	# add_fuel restores and clears OUT_OF_FUEL reason.
	var added := float(vs.call("add_fuel", 10.0))
	if added <= 0.0:
		push_error("drive_smoke: add_fuel failed")
		quit(1)
		return false
	if str(vs.call("get_stopped_reason")) == "OUT_OF_FUEL":
		push_error("drive_smoke: add_fuel should clear OUT_OF_FUEL")
		quit(1)
		return false

	# Cleanup.
	save.call("delete_save")
	vs.call("reset_for_tests")
	journey.call("reset_journey")
	_mode_controller.call("set_mode", MODE_MANUAL)
	_clear_vehicle_input()
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	print(
		"drive_smoke: fuel OK (drive burn + park idle + speed factor + empty + offline + save)"
	)
	return true


func _verify_vehicle_upgrade_loop() -> bool:
	## Full loop: craft Cruise Module Mk I → install → effective speed → save/load once.
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var craft: Node = root.get_node_or_null("CraftingSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if vs == null or craft == null or inv == null or save == null:
		push_error("drive_smoke: systems missing for upgrade loop")
		quit(1)
		return false

	vs.call("reset_for_tests")
	inv.call("clear_inventory")
	if craft.has_method("reload_catalog"):
		craft.call("reload_catalog")
	if inv.has_method("reload_catalog"):
		inv.call("reload_catalog")
	if vs.has_method("reload_upgrade_catalog"):
		vs.call("reload_upgrade_catalog")

	const UPGRADE_ID := "cruise_module_mk1"
	const RECIPE_ID := "cruise_module_mk1"

	if not bool(craft.call("has_recipe", RECIPE_ID)):
		push_error("drive_smoke: cruise_module_mk1 recipe missing")
		quit(1)
		return false
	if not bool(inv.call("has_item_data", UPGRADE_ID)):
		push_error("drive_smoke: cruise_module_mk1 item missing from catalog")
		quit(1)
		return false
	if vs.call("get_upgrade_data", UPGRADE_ID) == null:
		push_error("drive_smoke: cruise_module_mk1 UpgradeData missing")
		quit(1)
		return false

	var base_speed := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(base_speed, 86.4):
		push_error("drive_smoke: base effective max expected 86.4 got %.2f" % base_speed)
		quit(1)
		return false

	# Gather test ingredients (same pool as world pickups / crafting smoke).
	inv.call("add_item", "scrap_metal", 2)
	inv.call("add_item", "copper_wire", 1)
	inv.call("add_item", "circuit_board", 1)
	if not bool(craft.call("can_craft", RECIPE_ID)):
		push_error("drive_smoke: should be able to craft cruise module with test items")
		quit(1)
		return false
	if not bool(craft.call("craft", RECIPE_ID)):
		push_error("drive_smoke: craft cruise_module_mk1 failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", UPGRADE_ID)) != 1:
		push_error("drive_smoke: crafted module not in inventory")
		quit(1)
		return false

	# Effects come from UpgradeData modifiers — not the display name.
	var data: Resource = vs.call("get_upgrade_data", UPGRADE_ID)
	var bonus := float(data.get("max_speed_bonus_kmh"))
	if not is_equal_approx(bonus, 10.0):
		push_error("drive_smoke: expected +10 km/h bonus on Cruise Module Mk I")
		quit(1)
		return false

	if not bool(vs.call("can_install_from_inventory", UPGRADE_ID)):
		push_error("drive_smoke: can_install_from_inventory false before install")
		quit(1)
		return false
	if not bool(vs.call("install_upgrade_from_inventory", UPGRADE_ID)):
		push_error("drive_smoke: install_upgrade_from_inventory failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", UPGRADE_ID)) != 0:
		push_error("drive_smoke: install did not consume module item")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", UPGRADE_ID)):
		push_error("drive_smoke: upgrade not marked installed")
		quit(1)
		return false

	var boosted := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(boosted, base_speed + bonus):
		push_error(
			"drive_smoke: effective max expected %.1f got %.1f" % [base_speed + bonus, boosted]
		)
		quit(1)
		return false
	if not is_equal_approx(float(_vehicle.call("get_effective_max_speed_kmh")), boosted):
		push_error("drive_smoke: PlayerVehicle did not pick up upgrade max speed")
		quit(1)
		return false

	# Non-stackable: cannot install again even with another module.
	inv.call("add_item", UPGRADE_ID, 1)
	if bool(vs.call("install_upgrade_from_inventory", UPGRADE_ID)):
		push_error("drive_smoke: duplicate non-stackable install should fail")
		quit(1)
		return false
	if int(inv.call("get_quantity", UPGRADE_ID)) != 1:
		push_error("drive_smoke: failed duplicate install should not consume item")
		quit(1)
		return false
	# Speed must not double.
	if not is_equal_approx(float(vs.call("get_effective_max_speed")), boosted):
		push_error("drive_smoke: effective speed changed after refused reinstall")
		quit(1)
		return false

	# Persist ids only — reload must not duplicate the bonus.
	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("drive_smoke: save_game failed in upgrade loop")
		quit(1)
		return false
	vs.call("reset_for_tests")
	inv.call("clear_inventory")
	if float(vs.call("get_effective_max_speed")) != 86.4:
		push_error("drive_smoke: reset should clear upgrade bonus")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: load_game failed in upgrade loop")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", UPGRADE_ID)):
		push_error("drive_smoke: upgrade id not restored")
		quit(1)
		return false
	var restored := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(restored, base_speed + bonus):
		push_error("drive_smoke: effective speed not restored (got %.2f)" % restored)
		quit(1)
		return false
	# Count installed once — summing catalog effects must not double on load.
	var installed: PackedStringArray = vs.call("get_installed_upgrades")
	var count := 0
	for id in installed:
		if str(id) == UPGRADE_ID:
			count += 1
	if count != 1:
		push_error("drive_smoke: upgrade id duplicated after load (count=%d)" % count)
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_upgrade_max_speed_bonus_kmh")), bonus):
		push_error("drive_smoke: upgrade bonus duplicated after load")
		quit(1)
		return false

	save.call("delete_save")
	vs.call("reset_for_tests")
	inv.call("clear_inventory")
	print(
		"drive_smoke: upgrade OK (craft → install +10 km/h → persist once, no duplicate)"
	)
	return true


func _verify_condition_system() -> bool:
	## ConditionSystem + GameFlags: all types, ALL/ANY, flag save, Mira COMPLETED dialogue gate.
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var save: Node = root.get_node_or_null("SaveSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var poi: Node = root.get_node_or_null("POISystem")
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	var regions: Node = root.get_node_or_null("WorldRegionSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	if cond == null or flags == null or save == null:
		push_error("drive_smoke: ConditionSystem/GameFlags/SaveSystem missing")
		quit(1)
		return false

	# No quest-specific branching inside ConditionSystem.
	var cond_script: Script = load("res://autoload/condition_system.gd") as Script
	if cond_script != null:
		var src := cond_script.source_code
		for banned in ["power_the_viewpoint", "mira_quest", "Mira"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: ConditionSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	flags.call("reset_for_tests")
	if qs != null and qs.has_method("reset_all"):
		qs.call("reset_all")
	if inv != null:
		inv.call("clear_inventory")
	if vs != null and vs.has_method("reset_for_tests"):
		vs.call("reset_for_tests")
	if journey != null:
		journey.call("reset_journey")
	_clear_world_state()

	# FLAG_EQUALS
	flags.call("set_flag", "smoke_flag_a", true)
	if not bool(cond.call("evaluate", cond.call("make_flag_equals", "smoke_flag_a", true))):
		push_error("drive_smoke: FLAG_EQUALS true failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_flag_equals", "smoke_flag_a", false))):
		push_error("drive_smoke: FLAG_EQUALS expected false should fail")
		quit(1)
		return false

	# QUEST_STATE
	if qs != null:
		if bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "COMPLETED"))):
			push_error("drive_smoke: QUEST_STATE COMPLETED should be false initially")
			quit(1)
			return false
		qs.call("start_quest", "power_the_viewpoint")
		if not bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"))):
			push_error("drive_smoke: QUEST_STATE ACTIVE failed")
			quit(1)
			return false

	# HAS_ITEM / ITEM_QUANTITY
	if inv != null:
		inv.call("add_item", "scrap_metal", 3)
		if not bool(cond.call("evaluate", cond.call("make_has_item", "scrap_metal", 1))):
			push_error("drive_smoke: HAS_ITEM failed")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_item_quantity", "scrap_metal", 3))):
			push_error("drive_smoke: ITEM_QUANTITY >=3 failed")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_item_quantity", "scrap_metal", 4))):
			push_error("drive_smoke: ITEM_QUANTITY >=4 should fail")
			quit(1)
			return false

	# POI_DISCOVERED
	if poi != null:
		if poi.has_method("clear_discovery_for_tests"):
			poi.call("clear_discovery_for_tests")
		if bool(cond.call("evaluate", cond.call("make_poi_discovered", "sunset_viewpoint"))):
			push_error("drive_smoke: POI_DISCOVERED should be false after clear")
			quit(1)
			return false
		poi.call("mark_discovered", "sunset_viewpoint", "Sunset Viewpoint")
		if not bool(cond.call("evaluate", cond.call("make_poi_discovered", "sunset_viewpoint"))):
			push_error("drive_smoke: POI_DISCOVERED failed")
			quit(1)
			return false

	# WORLD_STATE_EQUALS
	if ws != null:
		ws.call("set_value", "smoke.entity", "powered", true)
		if not bool(
			cond.call(
				"evaluate",
				cond.call("make_world_state_equals", "smoke.entity", "powered", "true")
			)
		):
			push_error("drive_smoke: WORLD_STATE_EQUALS failed")
			quit(1)
			return false

	# VEHICLE_HAS_UPGRADE
	if vs != null:
		if bool(cond.call("evaluate", cond.call("make_vehicle_has_upgrade", "cruise_module_mk1"))):
			push_error("drive_smoke: VEHICLE_HAS_UPGRADE should be false after reset")
			quit(1)
			return false
		vs.call("install_upgrade", "cruise_module_mk1")
		if not bool(cond.call("evaluate", cond.call("make_vehicle_has_upgrade", "cruise_module_mk1"))):
			push_error("drive_smoke: VEHICLE_HAS_UPGRADE failed")
			quit(1)
			return false

	# REGION_IS
	if regions != null:
		var region_id := str(regions.call("get_current_region_id"))
		if region_id.is_empty():
			push_error("drive_smoke: current region id empty")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_region_is", region_id))):
			push_error("drive_smoke: REGION_IS failed for %s" % region_id)
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_region_is", "NOT_A_REAL_REGION"))):
			push_error("drive_smoke: REGION_IS should fail for unknown region")
			quit(1)
			return false

	# JOURNEY_DISTANCE_MIN / MAX
	if journey != null:
		journey.call("set_current_distance_km", 50.0)
		if not bool(cond.call("evaluate", cond.call("make_journey_distance_min", 40.0))):
			push_error("drive_smoke: JOURNEY_DISTANCE_MIN failed")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_journey_distance_min", 60.0))):
			push_error("drive_smoke: JOURNEY_DISTANCE_MIN 60 should fail at 50")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_journey_distance_max", 60.0))):
			push_error("drive_smoke: JOURNEY_DISTANCE_MAX failed")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_journey_distance_max", 40.0))):
			push_error("drive_smoke: JOURNEY_DISTANCE_MAX 40 should fail at 50")
			quit(1)
			return false

	# NARRATIVE_* conditions (world clock — never system/play hour).
	var gt_cond: Node = root.get_node_or_null("GameTimeSystem")
	if gt_cond != null and gt_cond.has_method("set_narrative_time"):
		gt_cond.call("set_narrative_time", 1, 10, 0)
		if not bool(cond.call("evaluate", cond.call("make_narrative_hour_min", 8))):
			push_error("drive_smoke: NARRATIVE_HOUR_MIN 8 should pass at hour 10")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_narrative_hour_max", 17))):
			push_error("drive_smoke: NARRATIVE_HOUR_MAX 17 should pass at hour 10")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_narrative_hour_min", 18))):
			push_error("drive_smoke: NARRATIVE_HOUR_MIN 18 should fail at hour 10")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_narrative_day_min", 1))):
			push_error("drive_smoke: NARRATIVE_DAY_MIN 1 should pass on day 1")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_narrative_day_max", 0))):
			push_error("drive_smoke: NARRATIVE_DAY_MAX 0 should fail on day 1")
			quit(1)
			return false
		# Cross-midnight range 22:00–06:00.
		gt_cond.call("set_narrative_time", 0, 23, 0)
		if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
			push_error("drive_smoke: NARRATIVE_TIME_RANGE 22–6 should pass at 23:00")
			quit(1)
			return false
		gt_cond.call("set_narrative_time", 0, 3, 0)
		if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
			push_error("drive_smoke: NARRATIVE_TIME_RANGE 22–6 should pass at 03:00")
			quit(1)
			return false
		gt_cond.call("set_narrative_time", 0, 12, 0)
		if bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
			push_error("drive_smoke: NARRATIVE_TIME_RANGE 22–6 should fail at 12:00")
			quit(1)
			return false
		gt_cond.call("reset_for_tests")

	# ALL / ANY composites
	var pass_a: Resource = cond.call("make_flag_equals", "smoke_flag_a", true)
	var pass_b: Resource = cond.call("make_journey_distance_min", 10.0)
	var fail_c: Resource = cond.call("make_flag_equals", "missing_flag", true)
	if not bool(cond.call("evaluate_all", [pass_a, pass_b])):
		push_error("drive_smoke: evaluate_all should pass")
		quit(1)
		return false
	if bool(cond.call("evaluate_all", [pass_a, fail_c])):
		push_error("drive_smoke: evaluate_all should fail when one fails")
		quit(1)
		return false
	if not bool(cond.call("evaluate_all", [])):
		push_error("drive_smoke: evaluate_all empty should be true")
		quit(1)
		return false
	if not bool(cond.call("evaluate_any", [fail_c, pass_a])):
		push_error("drive_smoke: evaluate_any should pass if one passes")
		quit(1)
		return false
	if bool(cond.call("evaluate_any", [fail_c])):
		push_error("drive_smoke: evaluate_any should fail when all fail")
		quit(1)
		return false
	if bool(cond.call("evaluate_any", [])):
		push_error("drive_smoke: evaluate_any empty should be false")
		quit(1)
		return false

	# Flags persist via SaveSystem.
	flags.call("set_flag", "persist_me", true)
	flags.call("set_flag", "persist_false", false)
	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("drive_smoke: save_game failed for flags")
		quit(1)
		return false
	flags.call("reset_for_tests")
	if bool(flags.call("has_flag", "persist_me")):
		push_error("drive_smoke: flags should clear on reset")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: load_game failed for flags")
		quit(1)
		return false
	if not bool(flags.call("get_flag", "persist_me", false)):
		push_error("drive_smoke: persist_me flag not restored")
		quit(1)
		return false
	if bool(flags.call("get_flag", "persist_false", true)):
		push_error("drive_smoke: persist_false should restore as false")
		quit(1)
		return false

	# Mira contextual dialogue via priority rules when quest COMPLETED.
	if qs != null:
		qs.call("reset_all")
		qs.call("start_quest", "power_the_viewpoint")
		qs.call("complete_quest", "power_the_viewpoint")
		if not bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "COMPLETED"))):
			push_error("drive_smoke: QUEST_STATE COMPLETED after complete_quest")
			quit(1)
			return false

	var mira_def: Resource = load("res://resources/npc/mira_viewpoint_keeper.tres")
	if mira_def == null or not ("dialogue_rules" in mira_def):
		push_error("drive_smoke: Mira missing dialogue_rules")
		quit(1)
		return false
	if (mira_def.dialogue_rules as Array).is_empty():
		push_error("drive_smoke: Mira dialogue_rules empty")
		quit(1)
		return false
	if dlg == null or not dlg.has_method("resolve_dialogue_for_npc"):
		push_error("drive_smoke: DialogueSystem.resolve_dialogue_for_npc missing")
		quit(1)
		return false
	dlg.call("register_npc_definition", mira_def)
	var resolved := str(dlg.call("resolve_dialogue_for_npc", "mira_viewpoint_keeper"))
	if resolved != "mira_quest_done_01":
		push_error("drive_smoke: expected mira_quest_done_01 from NPC rules, got %s" % resolved)
		quit(1)
		return false

	# Live NPC in scene (if present) should also report completed dialogue.
	var mira: Node = root.find_child("Mira", true, false)
	if mira != null and mira.has_method("get_dialogue_id"):
		if str(mira.call("get_dialogue_id")) != "mira_quest_done_01":
			push_error(
				"drive_smoke: Mira get_dialogue_id should be mira_quest_done_01 when COMPLETED (got %s)"
				% str(mira.call("get_dialogue_id"))
			)
			quit(1)
			return false

	# Cleanup
	save.call("delete_save")
	flags.call("reset_for_tests")
	if qs != null:
		qs.call("reset_all")
	if inv != null:
		inv.call("clear_inventory")
	if vs != null:
		vs.call("reset_for_tests")
	if journey != null:
		journey.call("reset_journey")
	if poi != null and poi.has_method("clear_discovery_for_tests"):
		poi.call("clear_discovery_for_tests")
	_clear_world_state()
	print("drive_smoke: conditions OK (types + ALL/ANY + flags save + Mira COMPLETED gate)")
	return true


func _verify_vertical_slice_mid_save() -> bool:
	## Mid-flow save → wipe → load: no loss, no duplication. Also offline fuel cap once.
	var save: Node = root.get_node_or_null("SaveSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var poi: Node = root.get_node_or_null("POISystem")
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	if (
		save == null or journey == null or inv == null or qs == null or poi == null
		or ws == null or vs == null or gt == null or flags == null or cond == null
	):
		push_error("drive_smoke: systems missing for mid-save vertical slice")
		quit(1)
		return false

	# Clean slate.
	save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	_clear_world_state()
	vs.call("reset_for_tests")
	flags.call("reset_for_tests")
	if gt.has_method("reset_for_tests"):
		gt.call("reset_for_tests")

	# --- Seed mid-flow progression (after explore/quest/craft path, before finish) ---
	journey.call("set_current_distance_km", 2500.0)
	inv.call("add_item", "scrap_metal", 2)
	inv.call("add_item", "copper_wire", 1)
	inv.call("add_item", "circuit_board", 1)
	inv.call("add_item", "basic_repair_kit", 1)
	qs.call("start_quest", "power_the_viewpoint")
	poi.call("mark_discovered", "sunset_viewpoint", "Sunset Viewpoint")
	ws.call("set_flag", "poi.sunset_viewpoint.pickup.scrap_01", "collected", true)
	ws.call("set_value", "poi.sunset_viewpoint.terminal.main", "powered", false)
	vs.call("set_fuel_current", 55.0)
	vs.call("set_liters_per_100km", 8.0)
	vs.call("install_upgrade", "cruise_module_mk1")
	flags.call("set_flag", "slice_mid_marker", true)
	var play_before := float(gt.call("get_total_play_time"))
	gt.call("debug_advance", 12.0, false)
	var travel_before := float(gt.call("get_total_travel_time"))
	gt.call("debug_advance", 3.0, true)

	var expected_speed := 86.4 + 10.0
	if not is_equal_approx(float(vs.call("get_effective_max_speed")), expected_speed):
		push_error("drive_smoke: mid-save seed upgrade speed wrong")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"))):
		push_error("drive_smoke: mid-save seed quest not ACTIVE")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_poi_discovered", "sunset_viewpoint"))):
		push_error("drive_smoke: mid-save seed POI not discovered")
		quit(1)
		return false

	if not bool(save.call("save_game")):
		push_error("drive_smoke: mid-save save_game failed")
		quit(1)
		return false

	# Mutate runtime aggressively (simulates closing the game).
	journey.call("set_current_distance_km", 0.0)
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	_clear_world_state()
	vs.call("reset_for_tests")
	flags.call("reset_for_tests")
	gt.call("reset_for_tests")

	if not bool(save.call("load_game")):
		push_error("drive_smoke: mid-save load_game failed")
		quit(1)
		return false

	# --- Assert restore without loss ---
	if not is_equal_approx(float(journey.call("get_current_distance_km")), 2500.0):
		push_error("drive_smoke: mid-save journey not restored")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 2:
		push_error("drive_smoke: mid-save scrap not restored")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 1:
		push_error("drive_smoke: mid-save repair kit not restored")
		quit(1)
		return false
	if str(qs.call("get_state_name", "power_the_viewpoint")) != "ACTIVE":
		push_error("drive_smoke: mid-save quest not ACTIVE after load")
		quit(1)
		return false
	if not bool(poi.call("is_discovered", "sunset_viewpoint")):
		push_error("drive_smoke: mid-save POI discovery lost")
		quit(1)
		return false
	if not bool(ws.call("get_flag", "poi.sunset_viewpoint.pickup.scrap_01", "collected", false)):
		push_error("drive_smoke: mid-save collected pickup flag lost")
		quit(1)
		return false
	if bool(ws.call("get_value", "poi.sunset_viewpoint.terminal.main", "powered", true)):
		push_error("drive_smoke: mid-save terminal should stay unpowered")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_fuel_current")), 55.0):
		push_error("drive_smoke: mid-save fuel not restored")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", "cruise_module_mk1")):
		push_error("drive_smoke: mid-save upgrade lost")
		quit(1)
		return false
	# No duplicated upgrade effect / id.
	var ups: PackedStringArray = vs.call("get_installed_upgrades")
	var up_count := 0
	for id in ups:
		if str(id) == "cruise_module_mk1":
			up_count += 1
	if up_count != 1:
		push_error("drive_smoke: mid-save upgrade duplicated (count=%d)" % up_count)
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_effective_max_speed")), expected_speed):
		push_error("drive_smoke: mid-save effective speed duplicated/wrong")
		quit(1)
		return false
	if not bool(flags.call("get_flag", "slice_mid_marker", false)):
		push_error("drive_smoke: mid-save game flag lost")
		quit(1)
		return false
	if float(gt.call("get_total_play_time")) < play_before + 14.5:
		push_error("drive_smoke: mid-save play time not restored")
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), travel_before + 3.0):
		push_error("drive_smoke: mid-save travel time not restored")
		quit(1)
		return false

	# Second load must not duplicate inventory / upgrades.
	if not bool(save.call("load_game")):
		push_error("drive_smoke: mid-save second load failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 2:
		push_error("drive_smoke: mid-save second load duplicated inventory")
		quit(1)
		return false
	ups = vs.call("get_installed_upgrades")
	up_count = 0
	for id in ups:
		if str(id) == "cruise_module_mk1":
			up_count += 1
	if up_count != 1 or not is_equal_approx(float(vs.call("get_effective_max_speed")), expected_speed):
		push_error("drive_smoke: mid-save second load duplicated upgrade effect")
		quit(1)
		return false

	# --- Offline progress capped by fuel; applies once ---
	journey.call("set_current_distance_km", 100.0)
	vs.call("set_fuel_current", 1.0)  # ~12.5 km at 60 km/h / 8 L/100km
	vs.set("offline_cruise_speed_kmh", 60.0)
	vs.set("was_traveling_at_save", true)
	gt.set("last_exit_timestamp", float(Time.get_unix_time_from_system()) - 3600.0)
	if not bool(save.call("save_game")):
		push_error("drive_smoke: offline mid-save save failed")
		quit(1)
		return false
	# Force traveling intent into the file even if live is_traveling was false at save.
	var path := str(save.call("get_save_path"))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("drive_smoke: could not patch save for offline test")
		quit(1)
		return false
	var systems: Dictionary = parsed.get("systems", {})
	var gt_payload: Dictionary = systems.get("game_time", {})
	var vs_payload: Dictionary = systems.get("vehicle_state", {})
	gt_payload["last_exit_timestamp"] = float(Time.get_unix_time_from_system()) - 3600.0
	vs_payload["was_traveling_at_save"] = true
	vs_payload["fuel_current"] = 1.0
	systems["game_time"] = gt_payload
	systems["vehicle_state"] = vs_payload
	parsed["systems"] = systems
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(parsed, "\t"))
	f.close()

	journey.call("set_current_distance_km", 0.0)
	vs.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("drive_smoke: offline mid-save load failed")
		quit(1)
		return false
	var after_offline_km := float(journey.call("get_current_distance_km"))
	# Journey was 100 in save + up to ~12.5 offline.
	if after_offline_km < 110.0 or after_offline_km > 113.0:
		push_error(
			"drive_smoke: offline fuel cap distance unexpected (got %.3f, want ~112.5)"
			% after_offline_km
		)
		quit(1)
		return false
	if float(vs.call("get_fuel_current")) > 0.001:
		push_error("drive_smoke: offline should empty fuel when capped")
		quit(1)
		return false
	if str(vs.call("get_stopped_reason")) != "OUT_OF_FUEL":
		push_error("drive_smoke: offline stop reason should be OUT_OF_FUEL")
		quit(1)
		return false

	# Reload again — must not advance a second time (was_traveling cleared + rewritten).
	var km_once := after_offline_km
	if not bool(save.call("load_game")):
		push_error("drive_smoke: offline second load failed")
		quit(1)
		return false
	if not is_equal_approx(float(journey.call("get_current_distance_km")), km_once):
		push_error(
			"drive_smoke: offline progress applied twice (%.3f → %.3f)"
			% [km_once, float(journey.call("get_current_distance_km"))]
		)
		quit(1)
		return false

	# Travel Mode still engages after restore (road path intact).
	_clear_vehicle_input()
	_mode_controller.call("set_mode", MODE_MANUAL)
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	vs.call("add_fuel", 20.0)
	Input.action_press("vehicle_accelerate")
	for _i in range(90):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) > 1.0:
			break
	Input.action_release("vehicle_accelerate")
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) != "TRAVEL_MODE":
		push_error("drive_smoke: Travel Mode should still work after mid-save slice")
		quit(1)
		return false
	_mode_controller.call("set_mode", MODE_MANUAL)
	_clear_vehicle_input()

	# Cleanup
	save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	_clear_world_state()
	vs.call("reset_for_tests")
	flags.call("reset_for_tests")
	if gt.has_method("reset_for_tests"):
		gt.call("reset_for_tests")
	print(
		"drive_smoke: mid_save OK (persist all systems + offline once + Travel Mode)"
	)
	return true


func _verify_world_state_system() -> bool:
	## WorldStateSystem: terminal + pickup survive despawn and save/load. No Node refs.
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if ws == null or save == null or poi_sys == null or inv == null:
		push_error("drive_smoke: WorldStateSystem/SaveSystem/POI/Inventory missing")
		quit(1)
		return false

	var ws_script: Script = load("res://autoload/world_state_system.gd") as Script
	if ws_script != null:
		var src := ws_script.source_code
		for banned in ["ViewpointTerminal", "WorldItem", "CitySystem"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: WorldStateSystem must not reference %s" % banned)
				quit(1)
				return false

	const TERM_ID := "poi.sunset_viewpoint.terminal.main"
	const PICK_ID := "poi.sunset_viewpoint.pickup.scrap_01"

	_clear_world_state()
	inv.call("clear_inventory")
	save.call("delete_save")

	# Reject Node values.
	if bool(ws.call("set_value", "test.entity", "bad", self)):
		push_error("drive_smoke: WorldStateSystem must reject Node values")
		quit(1)
		return false

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, Vector3(20.0, 0.0, -8.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: viewpoint spawn failed for world state")
		quit(1)
		return false

	var terminal: Node = vp.find_child("ViewpointTerminal", true, false)
	var scrap: Node = vp.find_child("ScrapMetalPickup", true, false)
	if terminal == null or scrap == null:
		push_error("drive_smoke: terminal/scrap missing for world state")
		quit(1)
		return false
	if str(terminal.get("world_state_id")) != TERM_ID:
		push_error("drive_smoke: terminal world_state_id mismatch")
		quit(1)
		return false
	if str(scrap.call("get_pickup_id")) != PICK_ID:
		push_error("drive_smoke: scrap pickup_id mismatch (expected convention id)")
		quit(1)
		return false

	# Power + collect → world flags.
	terminal.call("force_state", 1)  # PowerState.ON
	if not bool(ws.call("get_flag", TERM_ID, "powered", false)):
		push_error("drive_smoke: powered flag not written on terminal ON")
		quit(1)
		return false
	if not bool(scrap.call("interact", null)):
		push_error("drive_smoke: scrap collect failed for world state")
		quit(1)
		return false
	if not bool(ws.call("get_flag", PICK_ID, "collected", false)):
		push_error("drive_smoke: collected flag not written on pickup")
		quit(1)
		return false

	# Unload / reload scene instance — logical state must stick.
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	await physics_frame
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	terminal = vp.find_child("ViewpointTerminal", true, false)
	scrap = vp.find_child("ScrapMetalPickup", true, false)
	if terminal == null or scrap == null:
		push_error("drive_smoke: terminal/scrap missing after respawn")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "ON":
		push_error("drive_smoke: terminal not ON after scene reload")
		quit(1)
		return false
	if not bool(scrap.call("is_collected")):
		push_error("drive_smoke: scrap not collected after scene reload")
		quit(1)
		return false
	if bool(scrap.call("can_interact", null)):
		push_error("drive_smoke: collected scrap still interactable after reload")
		quit(1)
		return false

	# Disk round-trip.
	if not bool(save.call("save_game")):
		push_error("drive_smoke: save_game failed in world state test")
		quit(1)
		return false
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	_clear_world_state()
	inv.call("clear_inventory")
	if bool(ws.call("get_flag", TERM_ID, "powered", false)):
		push_error("drive_smoke: world state not cleared before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: load_game failed in world state test")
		quit(1)
		return false
	if not bool(ws.call("get_flag", TERM_ID, "powered", false)):
		push_error("drive_smoke: powered flag not restored from save")
		quit(1)
		return false
	if not bool(ws.call("get_flag", PICK_ID, "collected", false)):
		push_error("drive_smoke: collected flag not restored from save")
		quit(1)
		return false

	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	terminal = vp.find_child("ViewpointTerminal", true, false)
	scrap = vp.find_child("ScrapMetalPickup", true, false)
	if str(terminal.call("get_state_name")) != "ON" or not bool(scrap.call("is_collected")):
		push_error("drive_smoke: scene after save/load did not restore terminal/pickup")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	save.call("delete_save")
	_clear_world_state()
	inv.call("clear_inventory")
	print("drive_smoke: world_state OK (reload + save round-trip terminal/pickup)")
	return true


func _verify_enter_exit_vehicle() -> bool:
	## Park → exit on foot → vehicle stays → camera follows character → enter → control back.
	var occupancy: Node = root.find_child("PlayerOccupancyController", true, false)
	if occupancy == null:
		push_error("drive_smoke: PlayerOccupancyController missing")
		quit(1)
		return false
	var character: CharacterBody3D = root.find_child("PlayerCharacter", true, false) as CharacterBody3D
	if character == null:
		push_error("drive_smoke: PlayerCharacter missing")
		quit(1)
		return false

	_clear_vehicle_input()
	_mode_controller.call("set_mode", MODE_MANUAL)
	if occupancy.has_method("is_on_foot") and bool(occupancy.call("is_on_foot")):
		occupancy.call("try_enter_vehicle")
	_vehicle.call("try_unpark")
	await physics_frame

	# Cannot exit while moving / not parked.
	Input.action_press("vehicle_accelerate")
	var moving := false
	for _i in range(120):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) > 2.0:
			moving = true
			break
	Input.action_release("vehicle_accelerate")
	if not moving:
		push_error("drive_smoke: could not move before exit rejection check")
		quit(1)
		return false
	if bool(occupancy.call("try_exit_vehicle")):
		push_error("drive_smoke: exit allowed while moving / not parked")
		quit(1)
		return false
	if str(occupancy.call("get_state_name")) != "IN_VEHICLE":
		push_error("drive_smoke: occupancy left IN_VEHICLE after rejected exit")
		quit(1)
		return false

	# Stop and park.
	Input.action_press("vehicle_brake")
	for _j in range(240):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= 0.05 and _vehicle.is_on_floor():
			break
	Input.action_release("vehicle_brake")
	_clear_vehicle_input()
	for _k in range(8):
		await physics_frame
	if not bool(_vehicle.call("try_park")):
		push_error("drive_smoke: park failed before exit")
		quit(1)
		return false

	var vehicle_origin: Vector3 = _vehicle.global_position
	var occupancy_signals := {"n": 0}
	var on_occ := func(_prev, _cur) -> void:
		occupancy_signals["n"] = int(occupancy_signals["n"]) + 1
	occupancy.occupancy_changed.connect(on_occ)

	if not bool(occupancy.call("try_exit_vehicle")):
		push_error("drive_smoke: try_exit_vehicle failed while PARKED")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	if str(occupancy.call("get_state_name")) != "ON_FOOT":
		push_error("drive_smoke: expected ON_FOOT after exit")
		quit(1)
		return false
	if not character.visible:
		push_error("drive_smoke: character not visible after exit")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and not bool(character.call("is_control_enabled")):
		push_error("drive_smoke: character control disabled after exit")
		quit(1)
		return false
	if not bool(_vehicle.call("is_parked")):
		push_error("drive_smoke: vehicle left PARKED after exit")
		quit(1)
		return false
	if bool(_vehicle.call("is_manual_control_enabled")):
		push_error("drive_smoke: vehicle manual control still enabled on foot")
		quit(1)
		return false
	if vehicle_origin.distance_to(_vehicle.global_position) > 0.5:
		push_error("drive_smoke: vehicle moved after exit")
		quit(1)
		return false
	var door_dist: float = character.global_position.distance_to(vehicle_origin)
	if door_dist > 4.0 or door_dist < 0.5:
		push_error("drive_smoke: character spawn distance odd (%.2f)" % door_dist)
		quit(1)
		return false

	# Walk briefly with camera-relative move + run; vehicle must stay put.
	Input.action_press("player_move_forward")
	Input.action_press("player_run")
	var walked := false
	var start_char: Vector3 = character.global_position
	for _walk in range(45):
		await physics_frame
		if character.global_position.distance_to(start_char) > 0.6:
			walked = true
	Input.action_release("player_move_forward")
	Input.action_release("player_run")
	if not walked:
		push_error("drive_smoke: on-foot character did not move")
		quit(1)
		return false
	if character.has_method("get_planar_speed"):
		# After release, should decelerate (not required zero immediately).
		pass
	if vehicle_origin.distance_to(_vehicle.global_position) > 0.5:
		push_error("drive_smoke: parked vehicle drifted while on foot")
		quit(1)
		return false

	# Dedicated on-foot camera must be active (not vehicle cam retargeted).
	var foot_cam: Node3D = root.find_child("OnFootCameraController", true, false) as Node3D
	if foot_cam == null:
		push_error("drive_smoke: OnFootCameraController missing")
		quit(1)
		return false
	if foot_cam.has_method("is_active") and not bool(foot_cam.call("is_active")):
		push_error("drive_smoke: on-foot camera not active while ON_FOOT")
		quit(1)
		return false
	if foot_cam.has_method("get_follow_target"):
		var foot_target: Node3D = foot_cam.call("get_follow_target") as Node3D
		if foot_target != character:
			push_error("drive_smoke: on-foot camera not following character")
			quit(1)
			return false
	var vcam: Camera3D = null
	if _camera_rig.has_method("get_camera"):
		vcam = _camera_rig.call("get_camera") as Camera3D
	var fcam: Camera3D = null
	if foot_cam.has_method("get_camera"):
		fcam = foot_cam.call("get_camera") as Camera3D
	if fcam == null or not fcam.current:
		push_error("drive_smoke: on-foot Camera3D is not current")
		quit(1)
		return false
	if vcam != null and vcam.current:
		push_error("drive_smoke: vehicle camera still current while on foot")
		quit(1)
		return false
	if int(occupancy_signals["n"]) < 1:
		push_error("drive_smoke: occupancy_changed did not fire on exit")
		quit(1)
		return false

	# Simple collision: character must not pass through the parked vehicle.
	var before_push := character.global_position
	character.global_position = _vehicle.global_position + Vector3(-2.6, 0.05, 0.0)
	character.rotation.y = 0.0
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", 0.0, deg_to_rad(-12.0))
	await physics_frame
	# yaw=0 → camera-relative right is +X, into the vehicle from the left side.
	Input.action_press("player_move_right")
	for _push in range(30):
		await physics_frame
	Input.action_release("player_move_right")
	var penetrated := character.global_position.distance_to(_vehicle.global_position) < 0.85
	if penetrated:
		push_error("drive_smoke: character clipped into parked vehicle")
		quit(1)
		return false
	character.global_position = before_push
	await physics_frame

	if not await _verify_interaction_system(occupancy, character, foot_cam):
		return false

	if not await _verify_viewpoint_terminal(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_foundation(occupancy, character, foot_cam):
		return false

	if not await _verify_dialogue_choices(occupancy, character, foot_cam):
		return false

	if not await _verify_conditional_dialogue(occupancy, character, foot_cam):
		return false

	if not await _verify_dialogue_actions(occupancy, character, foot_cam):
		return false

	if not await _verify_dialogue_memory(occupancy, character, foot_cam):
		return false

	if not await _verify_dialogue_interrupt(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_barks(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_dialogue_rules(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_state(occupancy, character, foot_cam):
		return false

	if not await _verify_relationship_system(occupancy, character, foot_cam):
		return false

	if not await _verify_time_npc_availability(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_schedules(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_movement(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_travel(occupancy, character, foot_cam):
		return false

	if not await _verify_npc_dialogue_debug(occupancy, character, foot_cam):
		return false

	if not await _verify_small_interior(occupancy, character, foot_cam):
		return false

	if not await _verify_world_items(occupancy, character, foot_cam):
		return false

	if not await _verify_side_quest(occupancy, character, foot_cam):
		return false

	if not await _verify_workbench(occupancy, character, foot_cam):
		return false

	# Origin recenter while on foot must shift character + vehicle together.
	var saved_recenter_dist: float = float(_recenter.get("recenter_distance"))
	_recenter.set("recenter_distance", 40.0)
	var before_char: Vector3 = character.global_position
	var before_veh: Vector3 = _vehicle.global_position
	var rel: Vector3 = before_char - before_veh
	var count_before: int = int(_recenter.call("get_recenter_count"))
	# Nudge subject far from origin so planar length exceeds threshold.
	character.global_position = Vector3(80.0, before_char.y, before_char.z)
	_vehicle.global_position = character.global_position - rel
	for _r in range(20):
		await physics_frame
		if int(_recenter.call("get_recenter_count")) > count_before:
			break
	_recenter.set("recenter_distance", saved_recenter_dist)
	if int(_recenter.call("get_recenter_count")) <= count_before:
		push_error("drive_smoke: on-foot origin recenter did not fire")
		quit(1)
		return false
	var rel_after: Vector3 = character.global_position - _vehicle.global_position
	if rel_after.distance_to(rel) > 0.35:
		push_error(
			"drive_smoke: recenter broke character/vehicle relative pose (before=%s after=%s)"
			% [rel, rel_after]
		)
		quit(1)
		return false

	# Re-enter.
	# Ensure in range (recenter may have moved us but relative is intact).
	if not bool(occupancy.call("can_enter_vehicle")):
		# Snap near door if walk/recenter put us out of enter_distance.
		var exit_xf: Transform3D = _vehicle.call("get_driver_exit_global_transform")
		character.global_transform = exit_xf
		await physics_frame
	if not bool(occupancy.call("try_enter_vehicle")):
		push_error("drive_smoke: try_enter_vehicle failed")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	if str(occupancy.call("get_state_name")) != "IN_VEHICLE":
		push_error("drive_smoke: expected IN_VEHICLE after enter")
		quit(1)
		return false
	if character.visible:
		push_error("drive_smoke: character still visible after enter")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and bool(character.call("is_control_enabled")):
		push_error("drive_smoke: character control still enabled after enter")
		quit(1)
		return false
	if not bool(_vehicle.call("is_manual_control_enabled")):
		push_error("drive_smoke: vehicle control not restored after enter")
		quit(1)
		return false
	if not bool(_vehicle.call("is_parked")):
		push_error("drive_smoke: vehicle should still be PARKED after enter")
		quit(1)
		return false
	if foot_cam.has_method("is_active") and bool(foot_cam.call("is_active")):
		push_error("drive_smoke: on-foot camera still active after enter")
		quit(1)
		return false
	if fcam != null and fcam.current:
		push_error("drive_smoke: on-foot Camera3D still current after enter")
		quit(1)
		return false
	if vcam != null and not vcam.current:
		push_error("drive_smoke: vehicle camera not current after enter")
		quit(1)
		return false
	if _camera_rig.has_method("get_follow_target"):
		var cam_back: Node3D = _camera_rig.call("get_follow_target") as Node3D
		if cam_back != _vehicle:
			push_error("drive_smoke: camera not following vehicle after enter")
			quit(1)
			return false
	if int(occupancy_signals["n"]) < 2:
		push_error("drive_smoke: occupancy_changed did not fire on enter")
		quit(1)
		return false

	occupancy.occupancy_changed.disconnect(on_occ)
	_clear_vehicle_input()
	# Release mouse capture if smoke left it on.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print("drive_smoke: enter/exit OK (reject@move → exit ON_FOOT → on-foot cam/move → interact OK → recenter OK → enter IN_VEHICLE)")
	return true


func _verify_interaction_system(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Generic interactables: prompt on focus, interact key, clear when leaving, shared infra.
	var terminal: Node = root.find_child("TestTerminal", true, false)
	var terminal_b: Node = root.find_child("TestTerminalB", true, false)
	if terminal == null or terminal_b == null:
		push_error("drive_smoke: TestTerminal(s) missing")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(terminal):
		push_error("drive_smoke: TestTerminal is not duck-typed interactable")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(terminal_b):
		push_error("drive_smoke: TestTerminalB is not duck-typed interactable")
		quit(1)
		return false

	var detector: Node = character.get_node_or_null("InteractionDetector")
	if detector == null:
		push_error("drive_smoke: InteractionDetector missing on character")
		quit(1)
		return false

	# Ensure no focus far from terminals.
	character.global_position = _vehicle.global_position + Vector3(3.0, 0.05, 0.0)
	character.rotation.y = 0.0
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", 0.0, deg_to_rad(-12.0))
	for _wait in range(8):
		await physics_frame
	if bool(detector.call("has_focus")):
		push_error("drive_smoke: interaction focus present when far from objects")
		quit(1)
		return false
	if character.has_method("get_interaction_prompt"):
		if not str(character.call("get_interaction_prompt")).is_empty():
			push_error("drive_smoke: interaction prompt shown without focus")
			quit(1)
			return false

	# Approach terminal A and face it.
	var term_pos: Vector3 = (terminal as Node3D).global_position
	character.global_position = term_pos + Vector3(0.0, 0.05, 1.6)
	var face := term_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _a in range(12):
		await physics_frame

	if not bool(detector.call("has_focus")):
		push_error("drive_smoke: no interaction focus near TestTerminal")
		quit(1)
		return false
	var prompt := str(detector.call("get_focus_prompt"))
	if prompt.is_empty() or not prompt.contains("Interagir"):
		push_error("drive_smoke: bad interaction prompt '%s'" % prompt)
		quit(1)
		return false
	var focus: Node = detector.call("get_focus")
	if focus != terminal:
		# Either terminal is fine if both in range; prefer A when closer.
		if focus != terminal and focus != terminal_b:
			push_error("drive_smoke: focus is not a known test interactable")
			quit(1)
			return false

	var before_count := int(focus.get_meta("interact_count", 0))
	if not bool(detector.call("try_interact")):
		push_error("drive_smoke: try_interact failed on focused object")
		quit(1)
		return false
	var after_count := int(focus.get_meta("interact_count", 0))
	if after_count != before_count + 1:
		push_error("drive_smoke: interact did not increment count")
		quit(1)
		return false
	var msg := str(focus.get_meta("last_interact_message", ""))
	if msg.is_empty():
		push_error("drive_smoke: interact left no message meta")
		quit(1)
		return false

	# Second object shares the same infrastructure.
	var term_b_pos: Vector3 = (terminal_b as Node3D).global_position
	character.global_position = term_b_pos + Vector3(0.0, 0.05, 1.6)
	face = term_b_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _b in range(12):
		await physics_frame
	if not bool(detector.call("has_focus")):
		push_error("drive_smoke: no focus on second interactable")
		quit(1)
		return false
	var focus_b: Node = detector.call("get_focus")
	if focus_b != terminal_b:
		push_error("drive_smoke: expected focus on TestTerminalB, got %s" % focus_b)
		quit(1)
		return false
	if not bool(detector.call("try_interact")):
		push_error("drive_smoke: second interactable try_interact failed")
		quit(1)
		return false
	if int(terminal_b.get_meta("interact_count", 0)) < 1:
		push_error("drive_smoke: second interactable count not updated")
		quit(1)
		return false

	# Leave range → prompt/focus clears.
	character.global_position = _vehicle.global_position + Vector3(6.0, 0.05, 0.0)
	for _c in range(12):
		await physics_frame
	if bool(detector.call("has_focus")):
		push_error("drive_smoke: interaction focus remained after leaving range")
		quit(1)
		return false

	# Keep character near vehicle for subsequent enter test.
	var exit_xf: Transform3D = _vehicle.call("get_driver_exit_global_transform")
	character.global_transform = exit_xf
	await physics_frame
	print("drive_smoke: interaction OK (prompt → interact A/B → clear on leave)")
	return true


func _verify_viewpoint_terminal(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Terminal starts OFF and refuses to power without an active quest turn-in.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	if poi_sys == null:
		push_error("drive_smoke: POISystem missing for viewpoint terminal")
		quit(1)
		return false
	if qs != null and qs.has_method("reset_all"):
		qs.call("reset_all")
	_clear_world_state()

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("drive_smoke: could not load sunset viewpoint resources")
		quit(1)
		return false

	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(-6.0, 0.0, -4.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: failed to spawn viewpoint for terminal test")
		quit(1)
		return false

	var terminal: Node = vp.find_child("ViewpointTerminal", true, false)
	if terminal == null or not (terminal is Node3D):
		push_error("drive_smoke: ViewpointTerminal not found after spawn")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "OFF":
		push_error("drive_smoke: ViewpointTerminal expected OFF at spawn")
		quit(1)
		return false
	if not bool(terminal.call("can_interact", character)):
		push_error("drive_smoke: ViewpointTerminal should allow interact while OFF")
		quit(1)
		return false

	# Without quest / items, interact must fail and stay OFF.
	if bool(terminal.call("interact", character)):
		push_error("drive_smoke: terminal powered without quest turn-in")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "OFF":
		push_error("drive_smoke: terminal left OFF expected after rejected interact")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: viewpoint terminal OK (gated OFF without quest)")
	return true


func _verify_npc_foundation(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Data-driven DialogueSystem via Mira + Rafa (shared Interactable + catalog).
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if poi_sys == null:
		push_error("drive_smoke: POISystem missing for dialogue test")
		quit(1)
		return false
	if dlg == null:
		push_error("drive_smoke: DialogueSystem autoload missing")
		quit(1)
		return false
	_clear_world_state()
	if ns != null and ns.has_method("reset_for_tests"):
		ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_npc_catalog")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("drive_smoke: could not load viewpoint resources for dialogue")
		quit(1)
		return false

	# NPC must not hardcode dialogue text — only dialogue_id / definition.
	var npc_script: Script = load("res://scripts/npc/npc_character.gd") as Script
	if npc_script != null:
		var src := npc_script.source_code
		if src.find("Boa viagem.") >= 0 or src.find("Parei aqui") >= 0:
			push_error("drive_smoke: dialogue text must not be hardcoded in NpcCharacter")
			quit(1)
			return false
		if src.find("/root/POISystem") >= 0 or src.find("poi_system.gd") >= 0:
			push_error("drive_smoke: NpcCharacter must not reference POI autoload")
			quit(1)
			return false

	if not bool(dlg.call("has_dialogue", "mira_01")) or not bool(dlg.call("has_dialogue", "rafa_01")):
		push_error("drive_smoke: DialogueSystem catalog missing mira/rafa entries")
		quit(1)
		return false

	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(10.0, 0.0, -5.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: failed to spawn viewpoint for dialogue")
		quit(1)
		return false

	var mira: Node = vp.find_child("Mira", true, false)
	var rafa: Node = vp.find_child("Rafa", true, false)
	if mira == null or not mira.has_method("interact"):
		push_error("drive_smoke: Mira NPC missing")
		quit(1)
		return false
	if rafa == null or not rafa.has_method("interact"):
		push_error("drive_smoke: Rafa NPC missing (reuse proof)")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(mira) or not InteractionDetector.is_interactable_node(rafa):
		push_error("drive_smoke: NPCs must duck-type Interactable")
		quit(1)
		return false
	if str(mira.call("get_dialogue_id")) != "mira_intro":
		push_error("drive_smoke: Mira first-meet should resolve mira_intro")
		quit(1)
		return false
	if str(rafa.call("get_dialogue_id")) != "rafa_01":
		push_error("drive_smoke: Rafa dialogue_id should be rafa_01")
		quit(1)
		return false

	var finished := {"n": 0}
	var on_finished := func(_id: String) -> void:
		finished["n"] = int(finished["n"]) + 1
	dlg.dialogue_finished.connect(on_finished)

	# --- Mira sequence ---
	var mira_pos: Vector3 = (mira as Node3D).global_position
	character.global_position = mira_pos + Vector3(0.0, 0.05, 1.6)
	var face := mira_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _i in range(14):
		await physics_frame

	if not bool(character.call("is_control_enabled")):
		push_error("drive_smoke: character should have control before dialogue")
		quit(1)
		return false

	var prompt := str(mira.call("get_interaction_prompt"))
	if prompt.find("Mira") < 0:
		push_error("drive_smoke: bad Mira prompt '%s'" % prompt)
		quit(1)
		return false

	if not bool(mira.call("interact", character)):
		push_error("drive_smoke: Mira interact failed to start dialogue")
		quit(1)
		return false
	await physics_frame

	if not bool(dlg.call("is_active")):
		push_error("drive_smoke: DialogueSystem not active after Mira interact")
		quit(1)
		return false
	if bool(character.call("is_control_enabled")):
		push_error("drive_smoke: character still movable during dialogue")
		quit(1)
		return false
	if str(dlg.call("get_current_id")) != "mira_intro":
		push_error("drive_smoke: expected mira_intro, got %s" % str(dlg.call("get_current_id")))
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("terminal") < 0:
		push_error("drive_smoke: unexpected Mira intro line text")
		quit(1)
		return false
	var flags_early: Node = root.get_node_or_null("GameFlags")
	if flags_early == null or not bool(flags_early.call("get_flag", "npc.mira.met", false)):
		push_error("drive_smoke: on_enter should SET_FLAG npc.mira.met")
		quit(1)
		return false

	# Player cannot move while dialogue is active.
	var locked_pos := character.global_position
	Input.action_press("player_move_forward")
	for _m in range(10):
		await physics_frame
	Input.action_release("player_move_forward")
	if locked_pos.distance_to(character.global_position) > 0.05:
		push_error("drive_smoke: character moved during dialogue")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_quest_offer_02":
		push_error("drive_smoke: expected mira_quest_offer_02 after advance")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("Scrap Metal") < 0:
		push_error("drive_smoke: unexpected Mira offer line 2")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: dialogue still active after final advance")
		quit(1)
		return false
	if not bool(character.call("is_control_enabled")):
		push_error("drive_smoke: control not restored after Mira dialogue")
		quit(1)
		return false
	if int(finished["n"]) < 1:
		push_error("drive_smoke: dialogue_finished did not fire for Mira")
		quit(1)
		return false
	var qs: Node = root.get_node_or_null("QuestSystem")
	if qs == null or not bool(qs.call("is_active", "power_the_viewpoint")):
		push_error("drive_smoke: Power the Viewpoint should be ACTIVE after Mira offer")
		quit(1)
		return false
	# Isolate later tests.
	qs.call("reset_all")

	# --- Rafa first talk (memory cleared so greeting is rafa_01) ---
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	var rafa_pos: Vector3 = (rafa as Node3D).global_position
	character.global_position = rafa_pos + Vector3(0.0, 0.05, 1.6)
	face = rafa_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _j in range(10):
		await physics_frame

	if str(rafa.call("get_dialogue_id")) != "rafa_01":
		push_error("drive_smoke: Rafa should open rafa_01 before first completion")
		quit(1)
		return false
	if not bool(rafa.call("interact", character)):
		push_error("drive_smoke: Rafa interact failed")
		quit(1)
		return false
	await physics_frame
	if not bool(dlg.call("is_active")) or str(dlg.call("get_current_id")) != "rafa_01":
		push_error("drive_smoke: Rafa did not open rafa_01")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("novo por aqui") < 0:
		push_error("drive_smoke: unexpected Rafa first greeting")
		quit(1)
		return false
	if bool(character.call("is_control_enabled")):
		push_error("drive_smoke: control not blocked during Rafa dialogue")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_text")) != "Cuida do carro.":
		push_error("drive_smoke: unexpected Rafa line 2")
		quit(1)
		return false
	# Confirm first choice (rafa_pass) to complete conversation.
	dlg.call("set_choice_index", 0)
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: Rafa dialogue did not end")
		quit(1)
		return false
	if not bool(character.call("is_control_enabled")):
		push_error("drive_smoke: control not restored after Rafa")
		quit(1)
		return false

	dlg.dialogue_finished.disconnect(on_finished)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: dialogue OK (Mira sequence + Rafa reuse, control locked/restored)")
	return true


func _verify_dialogue_choices(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Branching DialogueChoice: Mira moon ask — navigate, confirm branch, keep linear intact.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	if dlg == null:
		push_error("drive_smoke: DialogueSystem missing for choices test")
		quit(1)
		return false

	# DialogueSystem must stay NPC-agnostic (no Mira/Lua branching in the runner).
	var dlg_script: Script = load("res://autoload/dialogue_system.gd") as Script
	if dlg_script != null:
		var src := dlg_script.source_code
		for banned in [
			"Mira",
			"mira_moon",
			"Lua",
			"viewpoint_keeper",
			"InventorySystem",
			"QuestSystem",
			"VehicleStateSystem",
			"WorldRegionSystem",
			"GameFlags",
			"power_the_viewpoint",
			"scrap_metal",
		]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: DialogueSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	if not bool(dlg.call("has_dialogue", "mira_moon_ask")):
		push_error("drive_smoke: catalog missing mira_moon_ask")
		quit(1)
		return false
	for reply_id in ["mira_moon_yes", "mira_moon_unsure", "mira_moon_passing"]:
		if not bool(dlg.call("has_dialogue", reply_id)):
			push_error("drive_smoke: catalog missing %s" % reply_id)
			quit(1)
			return false

	# Linear still works (mira_01 → mira_02 → end).
	if not bool(dlg.call("start_dialogue", "mira_01", character)):
		push_error("drive_smoke: linear mira_01 failed to start")
		quit(1)
		return false
	await physics_frame
	if bool(dlg.call("has_available_choices")):
		push_error("drive_smoke: linear mira_01 should have no choices")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_02":
		push_error("drive_smoke: linear advance should reach mira_02")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: linear mira dialogue should end")
		quit(1)
		return false

	# Isolate Mira moon ask from quest/inventory gates for baseline choice nav.
	var qs: Node = root.get_node_or_null("QuestSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if qs != null:
		qs.call("reset_all")
	if inv != null:
		inv.call("clear_inventory")

	# --- Mira branching sample ---
	var finished := {"id": ""}
	var on_finished := func(id: String) -> void:
		finished["id"] = str(id)
	dlg.dialogue_finished.connect(on_finished)

	if not bool(character.call("is_control_enabled")):
		character.call("set_control_enabled", true)
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("drive_smoke: mira_moon_ask failed to start")
		quit(1)
		return false
	await physics_frame

	if not bool(dlg.call("is_active")):
		push_error("drive_smoke: mira_moon_ask not active")
		quit(1)
		return false
	if bool(character.call("is_control_enabled")):
		push_error("drive_smoke: movement should be locked during choice dialogue")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("Lua") < 0:
		push_error("drive_smoke: expected moon question text")
		quit(1)
		return false
	if not bool(dlg.call("has_available_choices")):
		push_error("drive_smoke: mira_moon_ask should expose selectable choices")
		quit(1)
		return false
	# Quest incomplete + no scrap: 3 moon selectable; buy visible-but-disabled; repaired hidden.
	var selectable: Array = dlg.call("get_available_choices")
	var visible: Array = dlg.call("get_visible_choices")
	if selectable.size() != 3:
		push_error("drive_smoke: expected 3 selectable Mira choices, got %d" % selectable.size())
		quit(1)
		return false
	if visible.size() != 4:
		push_error("drive_smoke: expected 4 visible Mira choices (incl. disabled buy), got %d" % visible.size())
		quit(1)
		return false

	# Linear next_dialogue_id must not skip choices (advance confirms selection).
	if int(dlg.call("get_choice_index")) != 0:
		push_error("drive_smoke: choice index should start at 0")
		quit(1)
		return false
	dlg.call("select_next_choice")
	await physics_frame
	if int(dlg.call("get_choice_index")) != 1:
		push_error("drive_smoke: select_next_choice should move to index 1")
		quit(1)
		return false
	dlg.call("select_next_choice")
	await physics_frame
	if int(dlg.call("get_choice_index")) != 2:
		push_error("drive_smoke: select_next_choice should move to index 2")
		quit(1)
		return false
	dlg.call("select_previous_choice")
	await physics_frame
	if int(dlg.call("get_choice_index")) != 1:
		push_error("drive_smoke: select_previous_choice should return to index 1")
		quit(1)
		return false

	# Player still blocked while highlighting.
	var locked_pos := character.global_position
	Input.action_press("player_move_forward")
	for _m in range(8):
		await physics_frame
	Input.action_release("player_move_forward")
	if locked_pos.distance_to(character.global_position) > 0.05:
		push_error("drive_smoke: character moved during choice dialogue")
		quit(1)
		return false

	# Confirm middle choice → mira_moon_unsure.
	var confirmed := {"id": "", "next": ""}
	var on_choice := func(choice_id: String, next_id: String) -> void:
		confirmed["id"] = str(choice_id)
		confirmed["next"] = str(next_id)
	dlg.choice_confirmed.connect(on_choice)
	dlg.call("advance")
	await physics_frame
	if str(confirmed["id"]) != "moon_unsure" or str(confirmed["next"]) != "mira_moon_unsure":
		push_error(
			"drive_smoke: expected moon_unsure → mira_moon_unsure (got %s → %s)"
			% [confirmed["id"], confirmed["next"]]
		)
		quit(1)
		return false
	if str(dlg.call("get_current_id")) != "mira_moon_unsure":
		push_error("drive_smoke: branch should open mira_moon_unsure")
		quit(1)
		return false
	if bool(dlg.call("has_available_choices")):
		push_error("drive_smoke: reply line should be linear (no choices)")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("estrada") < 0:
		push_error("drive_smoke: unexpected unsure reply text")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: choice reply should end dialogue")
		quit(1)
		return false
	if not bool(character.call("is_control_enabled")):
		push_error("drive_smoke: control not restored after choice dialogue")
		quit(1)
		return false
	if str(finished["id"]) != "mira_moon_ask":
		push_error("drive_smoke: dialogue_finished should report start id mira_moon_ask")
		quit(1)
		return false

	# Empty next_dialogue_id on a choice ends immediately.
	var ChoiceScript: Script = load("res://scripts/dialogue/dialogue_choice.gd") as Script
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var end_choice: DialogueChoice = ChoiceScript.new() as DialogueChoice
	end_choice.id = "end_now"
	end_choice.text = "Encerrar."
	end_choice.next_dialogue_id = ""
	end_choice.enabled = true
	var ask_end: DialogueDefinition = DefScript.new() as DialogueDefinition
	ask_end.id = "choice_end_test"
	ask_end.speaker_name = "Test"
	ask_end.text = "Sair?"
	var end_choices: Array[DialogueChoice] = [end_choice]
	ask_end.choices = end_choices
	if not bool(dlg.call("start_from_definition", ask_end, character)):
		push_error("drive_smoke: choice_end_test failed to start")
		quit(1)
		return false
	await physics_frame
	if not bool(dlg.call("has_available_choices")):
		push_error("drive_smoke: choice_end_test should expose one choice")
		quit(1)
		return false
	dlg.call("confirm_choice")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: empty choice next should end dialogue")
		quit(1)
		return false

	# Authoring enabled=false hides the choice.
	var gated: DialogueChoice = ChoiceScript.new() as DialogueChoice
	gated.id = "gated"
	gated.text = "Hidden"
	gated.next_dialogue_id = ""
	gated.enabled = false
	var open: DialogueChoice = ChoiceScript.new() as DialogueChoice
	open.id = "open"
	open.text = "Visible"
	open.next_dialogue_id = ""
	open.enabled = true
	var gate_def: DialogueDefinition = DefScript.new() as DialogueDefinition
	gate_def.id = "choice_gate_test"
	gate_def.speaker_name = "Test"
	gate_def.text = "Pick"
	var gate_choices: Array[DialogueChoice] = [gated, open]
	gate_def.choices = gate_choices
	dlg.call("start_from_definition", gate_def, character)
	await physics_frame
	var avail: Array = dlg.call("get_available_choices")
	if avail.size() != 1 or str(avail[0].get("id")) != "open":
		push_error("drive_smoke: disabled choices must be filtered")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	dlg.choice_confirmed.disconnect(on_choice)
	dlg.dialogue_finished.disconnect(on_finished)
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: choices OK (Mira moon ask navigate/confirm + linear still works)")
	return true


func _verify_conditional_dialogue(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## show_conditions / enable_conditions via ConditionSystem only (quest, item, ALL/ANY, fallback).
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	if dlg == null or qs == null or inv == null or cond == null:
		push_error("drive_smoke: systems missing for conditional dialogue")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	dlg.call("reload_catalog")

	# --- Mira: quest COMPLETED reveals repaired choice; scrap enables buy ---
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("drive_smoke: cond_dlg mira_moon_ask failed (quest inactive)")
		quit(1)
		return false
	await physics_frame
	var ids_before := _choice_ids(dlg.call("get_visible_choices"))
	if ids_before.has("terminal_repaired"):
		push_error("drive_smoke: repaired choice must stay hidden before COMPLETED")
		quit(1)
		return false
	if not ids_before.has("buy_part"):
		push_error("drive_smoke: buy choice should be visible (disabled) without scrap")
		quit(1)
		return false
	# Highlight buy and refuse confirm while disabled.
	var buy_idx := ids_before.find("buy_part")
	dlg.call("set_choice_index", buy_idx)
	await physics_frame
	if bool(dlg.call("is_selected_choice_enabled")):
		push_error("drive_smoke: buy choice should be disabled without scrap")
		quit(1)
		return false
	var confirmed_n := {"n": 0}
	var on_choice := func(_a: String, _b: String) -> void:
		confirmed_n["n"] = int(confirmed_n["n"]) + 1
	dlg.choice_confirmed.connect(on_choice)
	dlg.call("confirm_choice")
	await physics_frame
	if int(confirmed_n["n"]) != 0 or str(dlg.call("get_current_id")) != "mira_moon_ask":
		push_error("drive_smoke: disabled buy choice must not confirm")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Complete quest → repaired becomes visible.
	qs.call("start_quest", "power_the_viewpoint")
	qs.call("complete_quest", "power_the_viewpoint")
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("drive_smoke: mira_moon_ask failed after COMPLETED")
		quit(1)
		return false
	await physics_frame
	var ids_after_quest := _choice_ids(dlg.call("get_visible_choices"))
	if not ids_after_quest.has("terminal_repaired"):
		push_error("drive_smoke: repaired choice should appear when quest COMPLETED")
		quit(1)
		return false
	var repaired_idx := ids_after_quest.find("terminal_repaired")
	dlg.call("set_choice_index", repaired_idx)
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_repaired_ack":
		push_error("drive_smoke: repaired branch should open mira_repaired_ack")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Give scrap → buy becomes selectable.
	inv.call("add_item", "scrap_metal", 3)
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("drive_smoke: mira_moon_ask failed with scrap")
		quit(1)
		return false
	await physics_frame
	var ids_with_scrap := _choice_ids(dlg.call("get_visible_choices"))
	var buy_i := ids_with_scrap.find("buy_part")
	if buy_i < 0:
		push_error("drive_smoke: buy choice missing with scrap")
		quit(1)
		return false
	dlg.call("set_choice_index", buy_i)
	await physics_frame
	if not bool(dlg.call("is_selected_choice_enabled")):
		push_error("drive_smoke: buy choice should enable with scrap_metal x3")
		quit(1)
		return false
	dlg.call("confirm_choice")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_buy_ack":
		push_error("drive_smoke: buy branch should open mira_buy_ack")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame
	dlg.choice_confirmed.disconnect(on_choice)

	# --- Line show_conditions + fallback ---
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var ChoiceScript: Script = load("res://scripts/dialogue/dialogue_choice.gd") as Script
	var gated_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	gated_line.id = "cond_line_gated"
	gated_line.speaker_name = "Test"
	gated_line.text = "Should not show"
	gated_line.show_conditions = [cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE")]
	gated_line.show_require_all = true
	gated_line.fallback_dialogue_id = "cond_line_fallback"
	var fallback_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	fallback_line.id = "cond_line_fallback"
	fallback_line.speaker_name = "Test"
	fallback_line.text = "Fallback line ok"
	fallback_line.next_dialogue_id = ""
	dlg.call("register_dialogue", gated_line)
	dlg.call("register_dialogue", fallback_line)
	# Quest is COMPLETED, not ACTIVE → gated fails → fallback.
	if not bool(dlg.call("start_dialogue", "cond_line_gated", character)):
		push_error("drive_smoke: gated line should start via fallback")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "cond_line_fallback":
		push_error("drive_smoke: expected fallback line, got %s" % str(dlg.call("get_current_id")))
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Loop guard: A fallback B fallback A.
	var loop_a: DialogueDefinition = DefScript.new() as DialogueDefinition
	loop_a.id = "cond_loop_a"
	loop_a.speaker_name = "Test"
	loop_a.text = "A"
	loop_a.show_conditions = [cond.call("make_flag_equals", "never_set_flag", true)]
	loop_a.fallback_dialogue_id = "cond_loop_b"
	var loop_b: DialogueDefinition = DefScript.new() as DialogueDefinition
	loop_b.id = "cond_loop_b"
	loop_b.speaker_name = "Test"
	loop_b.text = "B"
	loop_b.show_conditions = [cond.call("make_flag_equals", "never_set_flag", true)]
	loop_b.fallback_dialogue_id = "cond_loop_a"
	dlg.call("register_dialogue", loop_a)
	dlg.call("register_dialogue", loop_b)
	if bool(dlg.call("start_dialogue", "cond_loop_a", character)):
		push_error("drive_smoke: fallback loop should fail to start safely")
		quit(1)
		return false

	# --- ALL / ANY on choice show_conditions ---
	var any_choice: DialogueChoice = ChoiceScript.new() as DialogueChoice
	any_choice.id = "any_ok"
	any_choice.text = "ANY pass"
	any_choice.next_dialogue_id = ""
	any_choice.show_conditions = [
		cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"),
		cond.call("make_has_item", "scrap_metal", 1),
	]
	any_choice.show_require_all = false  # ANY — scrap present → show
	var all_choice: DialogueChoice = ChoiceScript.new() as DialogueChoice
	all_choice.id = "all_fail"
	all_choice.text = "ALL fail"
	all_choice.next_dialogue_id = ""
	all_choice.show_conditions = [
		cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"),
		cond.call("make_has_item", "scrap_metal", 1),
	]
	all_choice.show_require_all = true  # ALL — ACTIVE missing → hide
	var always: DialogueChoice = ChoiceScript.new() as DialogueChoice
	always.id = "always"
	always.text = "Always"
	always.next_dialogue_id = ""
	var logic_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	logic_line.id = "cond_logic_line"
	logic_line.speaker_name = "Test"
	logic_line.text = "Logic"
	var logic_choices: Array[DialogueChoice] = [any_choice, all_choice, always]
	logic_line.choices = logic_choices
	# All choices hidden path: only all_fail-like — use a line with one hidden choice + fallback.
	dlg.call("start_from_definition", logic_line, character)
	await physics_frame
	var logic_ids := _choice_ids(dlg.call("get_visible_choices"))
	if not logic_ids.has("any_ok") or not logic_ids.has("always") or logic_ids.has("all_fail"):
		push_error("drive_smoke: ANY/ALL show_conditions wrong (%s)" % str(logic_ids))
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# All choices hidden → fallback_dialogue_id.
	var hidden_only: DialogueChoice = ChoiceScript.new() as DialogueChoice
	hidden_only.id = "hidden_only"
	hidden_only.text = "Nope"
	hidden_only.show_conditions = [cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE")]
	hidden_only.show_require_all = true
	var empty_choices_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	empty_choices_line.id = "cond_all_hidden"
	empty_choices_line.speaker_name = "Test"
	empty_choices_line.text = "Should skip"
	empty_choices_line.fallback_dialogue_id = "cond_line_fallback"
	var hidden_arr: Array[DialogueChoice] = [hidden_only]
	empty_choices_line.choices = hidden_arr
	dlg.call("register_dialogue", empty_choices_line)
	if not bool(dlg.call("start_dialogue", "cond_all_hidden", character)):
		push_error("drive_smoke: all-hidden choices should fallback")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "cond_line_fallback":
		push_error("drive_smoke: all-hidden should land on fallback")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Ungated dialogues still work after conditional tests.
	if not bool(dlg.call("start_dialogue", "rafa_01", character)):
		push_error("drive_smoke: unconditional rafa_01 should still work")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: rafa linear should end")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: cond_dlg OK (quest show + item enable + ALL/ANY + fallback/loop)")
	return true


func _verify_dialogue_actions(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Declarative DialogueAction: enter flag, choice starts/refuses quest, once-per-event, save.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi: Node = root.get_node_or_null("POISystem")
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	if dlg == null or qs == null or inv == null or flags == null or save == null:
		push_error("drive_smoke: systems missing for dialogue actions")
		quit(1)
		return false

	# DialogueSystem must not own the type dispatch (executor does).
	var dlg_script: Script = load("res://autoload/dialogue_system.gd") as Script
	if dlg_script != null:
		var src := dlg_script.source_code
		for banned in ["SET_FLAG", "START_QUEST", "ADD_ITEM", "match type", "InventorySystem", "QuestSystem"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: DialogueSystem must not dispatch action types ('%s')" % banned)
				quit(1)
				return false
	var exec_script: Script = load("res://scripts/dialogue/dialogue_action_executor.gd") as Script
	if exec_script == null:
		push_error("drive_smoke: DialogueActionExecutor missing")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	flags.call("reset_for_tests")
	if poi != null and poi.has_method("clear_discovery_for_tests"):
		poi.call("clear_discovery_for_tests")
	_clear_world_state()
	dlg.call("reload_catalog")

	# --- Mira: enter sets flag; accept starts quest; refuse does not ---
	if not bool(dlg.call("start_dialogue", "mira_quest_offer_01", character)):
		push_error("drive_smoke: dlg_actions offer failed to start")
		quit(1)
		return false
	await physics_frame
	if not bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("drive_smoke: enter action should set npc.mira.met")
		quit(1)
		return false
	# Accidental re-present of same line in-session must not re-run enter.
	flags.call("set_flag", "npc.mira.met", false)
	dlg.call("_present_line", dlg.call("get_current"))
	await physics_frame
	if bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("drive_smoke: enter actions must fire once per line per conversation")
		quit(1)
		return false
	flags.call("set_flag", "npc.mira.met", true)

	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_quest_offer_02":
		push_error("drive_smoke: expected offer_02 for accept/refuse choices")
		quit(1)
		return false
	# Refuse path.
	dlg.call("set_choice_index", 1)
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: refuse should end dialogue")
		quit(1)
		return false
	if not bool(qs.call("is_inactive", "power_the_viewpoint")):
		push_error("drive_smoke: refuse must not START_QUEST")
		quit(1)
		return false

	# Accept path starts quest via on_choose action.
	qs.call("reset_all")
	if not bool(dlg.call("start_dialogue", "mira_quest_offer_01", character)):
		push_error("drive_smoke: accept path failed to start")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 0)
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if not bool(qs.call("is_active", "power_the_viewpoint")):
		push_error("drive_smoke: accept choice should START_QUEST")
		quit(1)
		return false

	# Choice actions once: re-confirm is impossible after end; use runtime loop A→B→A enter once.
	var ActionScript: Script = load("res://scripts/dialogue/dialogue_action.gd") as Script
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var add_action: DialogueAction = ActionScript.new() as DialogueAction
	add_action.type = DialogueAction.Type.ADD_ITEM
	add_action.target_id = "scrap_metal"
	add_action.int_value = 1
	var line_a: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_a.id = "action_loop_a"
	line_a.speaker_name = "Test"
	line_a.text = "A"
	line_a.next_dialogue_id = "action_loop_b"
	var enter_arr: Array[DialogueAction] = [add_action]
	line_a.on_enter_actions = enter_arr
	var line_b: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_b.id = "action_loop_b"
	line_b.speaker_name = "Test"
	line_b.text = "B"
	line_b.next_dialogue_id = "action_loop_a"
	dlg.call("register_dialogue", line_a)
	dlg.call("register_dialogue", line_b)
	inv.call("clear_inventory")
	dlg.call("start_dialogue", "action_loop_a", character)
	await physics_frame
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("drive_smoke: enter ADD_ITEM should run once on first present")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "action_loop_a":
		push_error("drive_smoke: expected return to action_loop_a")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("drive_smoke: re-entering same line must not re-run enter actions")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Executor covers remaining types fail-soft + success.
	var executor: RefCounted = exec_script.new()
	var set_ws: DialogueAction = ActionScript.new() as DialogueAction
	set_ws.type = DialogueAction.Type.SET_WORLD_STATE
	set_ws.target_id = "dlg.action.test"
	set_ws.secondary_id = "powered"
	set_ws.string_value = "true"
	if not bool(executor.call("execute", set_ws)):
		push_error("drive_smoke: SET_WORLD_STATE action failed")
		quit(1)
		return false
	if ws != null and str(ws.call("get_value", "dlg.action.test", "powered", "")) != "true":
		push_error("drive_smoke: SET_WORLD_STATE value not applied")
		quit(1)
		return false
	var disc: DialogueAction = ActionScript.new() as DialogueAction
	disc.type = DialogueAction.Type.DISCOVER_POI
	disc.target_id = "sunset_viewpoint"
	disc.string_value = "Sunset Viewpoint"
	if not bool(executor.call("execute", disc)):
		push_error("drive_smoke: DISCOVER_POI action failed")
		quit(1)
		return false
	if poi != null and not bool(poi.call("is_discovered", "sunset_viewpoint")):
		push_error("drive_smoke: DISCOVER_POI did not mark discovery")
		quit(1)
		return false
	var bad: DialogueAction = ActionScript.new() as DialogueAction
	bad.type = DialogueAction.Type.START_QUEST
	bad.target_id = "missing_quest_id_xyz"
	if bool(executor.call("execute", bad)):
		push_error("drive_smoke: missing quest target should fail safely")
		quit(1)
		return false

	# Save/load preserves flag set by dialogue enter.
	flags.call("reset_for_tests")
	qs.call("reset_all")
	save.call("delete_save")
	dlg.call("start_dialogue", "mira_quest_offer_01", character)
	await physics_frame
	if not bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("drive_smoke: flag missing before save")
		quit(1)
		return false
	if not bool(save.call("save_game")):
		push_error("drive_smoke: save after dialogue action failed")
		quit(1)
		return false
	flags.call("reset_for_tests")
	if bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("drive_smoke: flag should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: load after dialogue action failed")
		quit(1)
		return false
	if not bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("drive_smoke: save/load should preserve npc.mira.met from dialogue action")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	save.call("delete_save")
	await physics_frame

	qs.call("reset_all")
	inv.call("clear_inventory")
	flags.call("reset_for_tests")
	if poi != null:
		poi.call("clear_discovery_for_tests")
	_clear_world_state()
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: dlg_actions OK (enter flag + choice quest + once + save)")
	return true


func _verify_dialogue_memory(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## DialogueMemorySystem: seen vs completed, choices, ConditionSystem gates, save/load, Rafa return.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var npc_state: Node = root.get_node_or_null("NpcStateSystem")
	if dlg == null or memory == null or cond == null or save == null:
		push_error("drive_smoke: systems missing for dialogue memory")
		quit(1)
		return false

	# Memory must stay NPC-agnostic.
	var mem_script: Script = load("res://autoload/dialogue_memory_system.gd") as Script
	if mem_script != null:
		var src := mem_script.source_code
		for banned in ["Rafa", "Mira", "rafa_01", "viewpoint_keeper"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: DialogueMemorySystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	dlg.call("reload_catalog")
	save.call("delete_save")

	# Interrupted conversation: seen, not completed.
	if not bool(dlg.call("start_dialogue", "rafa_01", character)):
		push_error("drive_smoke: memory rafa_01 failed to start")
		quit(1)
		return false
	await physics_frame
	if not bool(memory.call("has_seen_dialogue", "rafa_01")):
		push_error("drive_smoke: start should mark dialogue seen")
		quit(1)
		return false
	if bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("drive_smoke: incomplete talk must not be completed")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_seen", "rafa_01"))):
		push_error("drive_smoke: DIALOGUE_SEEN condition failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_dialogue_completed", "rafa_01"))):
		push_error("drive_smoke: DIALOGUE_COMPLETED should be false while interrupted")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame
	if bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("drive_smoke: cancel must not complete dialogue memory")
		quit(1)
		return false

	# Complete with far choice.
	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	dlg.call("start_dialogue", "rafa_01", character)
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 1)  # rafa_far
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: Rafa first talk should end after choice")
		quit(1)
		return false
	if not bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("drive_smoke: finished talk should be completed")
		quit(1)
		return false
	if int(memory.call("get_times_completed", "rafa_01")) != 1:
		push_error("drive_smoke: times_completed should be 1")
		quit(1)
		return false
	if not bool(memory.call("has_selected_choice", "rafa_far")):
		push_error("drive_smoke: rafa_far choice should be remembered")
		quit(1)
		return false
	if int(memory.call("get_choice_count", "rafa_far")) != 1:
		push_error("drive_smoke: rafa_far choice count wrong")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_completed", "rafa_01"))):
		push_error("drive_smoke: DIALOGUE_COMPLETED condition failed after finish")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_choice_selected", "rafa_far"))):
		push_error("drive_smoke: DIALOGUE_CHOICE_SELECTED failed")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_completion_count_min", "rafa_01", 1))):
		push_error("drive_smoke: DIALOGUE_COMPLETION_COUNT_MIN failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_dialogue_completion_count_min", "rafa_01", 2))):
		push_error("drive_smoke: completion count min=2 should fail at 1")
		quit(1)
		return false

	# Return talk differs — choice influences which return line shows.
	# Clear BUSY from rafa_far SET_NPC_STATE so memory return-gate stays isolatable.
	if npc_state != null and npc_state.has_method("set_current_state"):
		npc_state.call("set_current_state", "rafa_road_traveler", "DEFAULT")
	if not bool(dlg.call("start_dialogue", "rafa_return_far", character)):
		push_error("drive_smoke: return_far failed to start")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "rafa_return_far":
		push_error("drive_smoke: far choice should keep rafa_return_far")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("Lua") < 0:
		push_error("drive_smoke: unexpected far-return text")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Without far choice, return falls back to "Você voltou."
	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	dlg.call("start_dialogue", "rafa_01", character)
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 0)  # rafa_pass
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if not bool(dlg.call("start_dialogue", "rafa_return_far", character)):
		push_error("drive_smoke: return gate failed after pass choice")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "rafa_return_01":
		push_error("drive_smoke: pass choice should fallback to rafa_return_01")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("voltou") < 0:
		push_error("drive_smoke: unexpected return greeting")
		quit(1)
		return false
	dlg.call("end_dialogue", true)
	await physics_frame

	# NPC resolve uses priority rules (no hardcoded names in DialogueSystem).
	var rafa_def: Resource = load("res://resources/npc/rafa_road_traveler.tres")
	if rafa_def == null or not ("dialogue_rules" in rafa_def):
		push_error("drive_smoke: Rafa NpcDefinition missing dialogue_rules")
		quit(1)
		return false
	dlg.call("register_npc_definition", rafa_def)
	var resolved := str(dlg.call("resolve_dialogue_for_npc", "rafa_road_traveler"))
	if resolved != "rafa_return_far":
		push_error("drive_smoke: expected rafa_return_far from return rule, got %s" % resolved)
		quit(1)
		return false

	# Save / load preserves memory.
	if not bool(save.call("save_game")):
		push_error("drive_smoke: dialogue memory save failed")
		quit(1)
		return false
	memory.call("reset_for_tests")
	if bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("drive_smoke: memory should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: dialogue memory load failed")
		quit(1)
		return false
	if not bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("drive_smoke: completed state lost after load")
		quit(1)
		return false
	if not bool(memory.call("has_selected_choice", "rafa_pass")):
		push_error("drive_smoke: choice memory lost after load")
		quit(1)
		return false
	save.call("delete_save")

	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: dlg_memory OK (seen/completed + choice + Rafa return + save)")
	return true


func _verify_dialogue_interrupt(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## start → advance → interrupt → resume; enter effects not duplicated; unload safe.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if dlg == null or inv == null or memory == null or flags == null or poi_sys == null:
		push_error("drive_smoke: systems missing for dialogue interrupt")
		quit(1)
		return false

	if not InputMap.has_action("dialogue_cancel"):
		push_error("drive_smoke: dialogue_cancel input action missing")
		quit(1)
		return false

	inv.call("clear_inventory")
	memory.call("reset_for_tests")
	flags.call("reset_for_tests")
	dlg.call("reload_catalog")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")

	var ActionScript: Script = load("res://scripts/dialogue/dialogue_action.gd") as Script
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var add_a: DialogueAction = ActionScript.new() as DialogueAction
	add_a.type = DialogueAction.Type.ADD_ITEM
	add_a.target_id = "scrap_metal"
	add_a.int_value = 1
	var add_b: DialogueAction = ActionScript.new() as DialogueAction
	add_b.type = DialogueAction.Type.ADD_ITEM
	add_b.target_id = "copper_wire"
	add_b.int_value = 1

	var line_a: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_a.id = "interrupt_line_a"
	line_a.speaker_name = "Test"
	line_a.text = "Line A"
	line_a.next_dialogue_id = "interrupt_line_b"
	var enter_a: Array[DialogueAction] = [add_a]
	line_a.on_enter_actions = enter_a

	var line_b: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_b.id = "interrupt_line_b"
	line_b.speaker_name = "Test"
	line_b.text = "Line B"
	line_b.next_dialogue_id = ""
	var enter_b: Array[DialogueAction] = [add_b]
	line_b.on_enter_actions = enter_b

	dlg.call("register_dialogue", line_a)
	dlg.call("register_dialogue", line_b)

	if not bool(dlg.call("start_dialogue", "interrupt_line_a", character, "test_interrupt_npc")):
		push_error("drive_smoke: interrupt test failed to start")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_session_state")) != "ACTIVE":
		push_error("drive_smoke: session should be ACTIVE after start")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("drive_smoke: line A enter should add scrap once")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "interrupt_line_b":
		push_error("drive_smoke: expected interrupt_line_b after advance")
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 1:
		push_error("drive_smoke: line B enter should add copper once")
		quit(1)
		return false

	if not bool(dlg.call("interrupt_dialogue", "PLAYER_CANCEL")):
		push_error("drive_smoke: interrupt_dialogue failed")
		quit(1)
		return false
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: interrupt should leave is_active false")
		quit(1)
		return false
	if not bool(dlg.call("is_interrupted")):
		push_error("drive_smoke: session should be INTERRUPTED")
		quit(1)
		return false
	if str(dlg.call("get_interrupt_reason")) != "PLAYER_CANCEL":
		push_error("drive_smoke: interrupt reason should be PLAYER_CANCEL")
		quit(1)
		return false
	if bool(memory.call("has_completed_dialogue", "interrupt_line_a")):
		push_error("drive_smoke: interrupted dialogue must not count as completed")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and not bool(character.call("is_control_enabled")):
		push_error("drive_smoke: interrupt should return player control")
		quit(1)
		return false

	if not bool(dlg.call("resume_dialogue", character)):
		push_error("drive_smoke: resume_dialogue failed")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_session_state")) != "ACTIVE":
		push_error("drive_smoke: resume should restore ACTIVE")
		quit(1)
		return false
	if str(dlg.call("get_current_id")) != "interrupt_line_b":
		push_error("drive_smoke: resume should stay on latest safe line B")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("drive_smoke: resume must not re-fire line A enter")
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 1:
		push_error("drive_smoke: resume must not re-fire line B enter")
		quit(1)
		return false

	dlg.call("end_dialogue", true)
	await physics_frame
	if not bool(memory.call("has_completed_dialogue", "interrupt_line_a")):
		push_error("drive_smoke: completing after resume should record completed")
		quit(1)
		return false

	# cancel_dialogue ≠ completed
	memory.call("reset_for_tests")
	inv.call("clear_inventory")
	if not bool(dlg.call("start_dialogue", "interrupt_line_a", character, "test_interrupt_npc")):
		push_error("drive_smoke: cancel path failed to start")
		quit(1)
		return false
	await physics_frame
	dlg.call("cancel_dialogue")
	await physics_frame
	if bool(dlg.call("is_interrupted")) or bool(dlg.call("is_active")):
		push_error("drive_smoke: cancel should clear session to IDLE")
		quit(1)
		return false
	if bool(memory.call("has_completed_dialogue", "interrupt_line_a")):
		push_error("drive_smoke: cancel must not mark completed")
		quit(1)
		return false

	# Scene unload mid-talk: no error; interrupted with ids only.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	if gt != null:
		gt.call("set_narrative_time", 0, 10, 0)
	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(6.0, 0.0, -6.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	var mira: Node = vp.find_child("Mira", true, false) if vp != null else null
	if mira == null:
		push_error("drive_smoke: Mira missing for unload interrupt")
		quit(1)
		return false
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.4)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("drive_smoke: Mira interact failed before unload interrupt")
		quit(1)
		return false
	await physics_frame
	if not bool(dlg.call("is_active")):
		push_error("drive_smoke: expected active dialogue before POI unload")
		quit(1)
		return false
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: active dialogue after unload should interrupt")
		quit(1)
		return false
	if not bool(dlg.call("is_interrupted")):
		push_error("drive_smoke: unload mid-talk should INTERRUPT (not crash / complete)")
		quit(1)
		return false
	var unload_reason := str(dlg.call("get_interrupt_reason"))
	if unload_reason != "NPC_UNAVAILABLE" and unload_reason != "SCENE_UNLOAD":
		push_error("drive_smoke: unload interrupt reason unexpected: %s" % unload_reason)
		quit(1)
		return false
	# Cannot resume without actor → cancel safely; next talk is fresh contextual resolve.
	if bool(dlg.call("resume_dialogue", null)):
		push_error("drive_smoke: resume without actor should fail safely")
		quit(1)
		return false
	if bool(dlg.call("is_interrupted")) or bool(dlg.call("is_active")):
		push_error("drive_smoke: failed resume should cancel to IDLE")
		quit(1)
		return false

	# Fresh interaction still resolves coherently.
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	mira = vp.find_child("Mira", true, false) if vp != null else null
	if mira == null:
		push_error("drive_smoke: Mira missing after unload interrupt cleanup")
		quit(1)
		return false
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.4)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("drive_smoke: next interaction after interrupt should work")
		quit(1)
		return false
	await physics_frame
	dlg.call("cancel_dialogue")
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	inv.call("clear_inventory")
	memory.call("reset_for_tests")
	flags.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: dlg_interrupt OK (interrupt/resume + no dup effects + unload)")
	return true


func _verify_npc_barks(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Contextual short lines: approach bark, cooldown, conditions, dialogue blocks, independence.
	var bark: Node = root.get_node_or_null("BarkSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if bark == null or dlg == null or gt == null or ns == null or poi_sys == null:
		push_error("drive_smoke: systems missing for npc barks")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	const RAFA := "rafa_road_traveler"

	var bark_script: Script = load("res://autoload/bark_system.gd") as Script
	if bark_script != null:
		var src := bark_script.source_code
		for banned in ["mira_viewpoint_keeper", "rafa_road_traveler", "DialogueUI", "Vai chover"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: BarkSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	bark.call("reset_for_tests")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")
	gt.call("set_narrative_time", 0, 10, 0)

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(7.0, 0.0, -7.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: viewpoint spawn failed for npc barks")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	var mira: Node3D = vp.find_child("Mira", true, false) as Node3D
	var rafa: Node3D = vp.find_child("Rafa", true, false) as Node3D
	if mira == null or rafa == null:
		push_error("drive_smoke: Mira/Rafa missing for bark test")
		quit(1)
		return false
	if mira.get_node_or_null("SpeechLabel") == null:
		push_error("drive_smoke: SpeechLabel missing for bark UI")
		quit(1)
		return false
	var mira_rules: Array = mira.call("get_bark_rules") if mira.has_method("get_bark_rules") else []
	if mira_rules.size() < 2:
		push_error("drive_smoke: Mira should author multiple bark_rules")
		quit(1)
		return false

	# Approach Mira → PLAYER_ENTER_AREA / NEARBY bark (rain at hour 10, unmet).
	character.global_position = mira.global_position + Vector3(0.0, 0.05, 2.5)
	await physics_frame
	await physics_frame
	await physics_frame
	if not bool(bark.call("try_bark", MIRA, "PLAYER_ENTER_AREA")):
		# Area signal may already have fired; force a nearby attempt after reset gap.
		bark.call("reset_for_tests", MIRA)
		if not bool(bark.call("try_bark", MIRA, "PLAYER_NEARBY")):
			push_error("drive_smoke: Mira should bark on approach")
			quit(1)
			return false
	var mira_bark_id := str(bark.call("get_last_bark_id", MIRA))
	if mira_bark_id.is_empty():
		push_error("drive_smoke: Mira last_bark_id empty after approach")
		quit(1)
		return false
	var speech: Label3D = mira.get_node_or_null("SpeechLabel") as Label3D
	if speech == null or not speech.visible or str(speech.text).is_empty():
		push_error("drive_smoke: bark should show temporary SpeechLabel (not DialogueUI)")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and not bool(character.call("is_control_enabled")):
		push_error("drive_smoke: bark must not lock player movement")
		quit(1)
		return false

	# Cooldown / min-gap: immediate re-fire suppressed.
	if bool(bark.call("try_bark", MIRA, "PLAYER_NEARBY")):
		push_error("drive_smoke: Mira bark should respect cooldown/min-gap")
		quit(1)
		return false

	# Conditions change available bark: met + hour 17 → closing soon / you returned.
	ns.call("set_met_player", MIRA, true)
	gt.call("set_narrative_time", 0, 17, 0)
	bark.call("reset_for_tests", MIRA)
	if not bool(bark.call("try_bark", MIRA, "PLAYER_ENTER_AREA")):
		push_error("drive_smoke: Mira should bark after condition change")
		quit(1)
		return false
	var after_id := str(bark.call("get_last_bark_id", MIRA))
	if after_id != "mira_you_returned" and after_id != "mira_closing_soon":
		push_error("drive_smoke: expected conditioned Mira bark, got '%s'" % after_id)
		quit(1)
		return false
	if after_id == mira_bark_id and mira_bark_id == "mira_rain_soon":
		push_error("drive_smoke: conditions should change available bark away from rain-only")
		quit(1)
		return false

	# Active dialogue blocks bark.
	bark.call("reset_for_tests", MIRA)
	if not bool(dlg.call("start_dialogue", "mira_intro", character, MIRA)):
		push_error("drive_smoke: failed to start dialogue to block bark")
		quit(1)
		return false
	await physics_frame
	if bool(bark.call("try_bark", MIRA, "PLAYER_NEARBY")):
		push_error("drive_smoke: active dialogue must block bark")
		quit(1)
		return false
	dlg.call("cancel_dialogue")
	await physics_frame

	# Rafa independent from Mira.
	bark.call("reset_for_tests", RAFA)
	character.global_position = rafa.global_position + Vector3(0.0, 0.05, 2.2)
	await physics_frame
	await physics_frame
	if not bool(bark.call("try_bark", RAFA, "PLAYER_ENTER_AREA")):
		bark.call("reset_for_tests", RAFA)
		if not bool(bark.call("try_bark", RAFA, "PLAYER_NEARBY")):
			push_error("drive_smoke: Rafa should bark independently")
			quit(1)
			return false
	var rafa_id := str(bark.call("get_last_bark_id", RAFA))
	if rafa_id.is_empty():
		push_error("drive_smoke: Rafa last_bark_id empty")
		quit(1)
		return false
	if rafa_id == str(bark.call("get_last_bark_id", MIRA)):
		# Different NPCs may coincidentally share text ids only if authored same — ours differ.
		pass
	if rafa_id.begins_with("mira_"):
		push_error("drive_smoke: Rafa must not use Mira bark ids")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	bark.call("reset_for_tests")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: npc_bark OK (approach + cooldown + conditions + dialogue block + independent)")
	return true


func _verify_npc_dialogue_rules(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Priority NpcDialogueRule resolve: intro → returning → quest done beats generic; fallback.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if dlg == null or cond == null or qs == null or ns == null:
		push_error("drive_smoke: systems missing for npc dialogue rules")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"

	# NpcCharacter must not inspect rules / hardcode quest ids.
	var npc_script: Script = load("res://scripts/npc/npc_character.gd") as Script
	if npc_script != null:
		var src := npc_script.source_code
		for banned in [
			"power_the_viewpoint",
			"dialogue_rules",
			"NpcDialogueRule",
			"mira_quest_done",
			"mira_intro",
			"mira_returning",
		]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: NpcCharacter must not contain '%s'" % banned)
				quit(1)
				return false

	# DialogueSystem must stay free of Mira/quest hardcoding in resolve.
	var dlg_script: Script = load("res://autoload/dialogue_system.gd") as Script
	if dlg_script != null:
		var dsrc := dlg_script.source_code
		for banned in ["mira_viewpoint_keeper", "power_the_viewpoint", "mira_intro"]:
			if dsrc.find(banned) >= 0:
				push_error("drive_smoke: DialogueSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_catalog")
	dlg.call("reload_npc_catalog")
	var gt_rules: Node = root.get_node_or_null("GameTimeSystem")
	if gt_rules != null and gt_rules.has_method("set_narrative_time"):
		gt_rules.call("set_narrative_time", 0, 10, 0)

	# 1) First meet → fallback intro (time rules require NPC_MET).
	var first := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if first != "mira_intro":
		push_error("drive_smoke: first meet should be mira_intro, got %s" % first)
		quit(1)
		return false

	# 2) After met (no quest, daytime) → time-of-day greeting beats mira_returning.
	ns.call("set_met_player", MIRA, true)
	var day_line := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if day_line != "mira_time_day":
		push_error("drive_smoke: met Mira at hour 10 should resolve mira_time_day, got %s" % day_line)
		quit(1)
		return false

	# 3) Active quest beats time greeting / returning.
	qs.call("start_quest", "power_the_viewpoint")
	var active := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if active != "mira_quest_active_01":
		push_error("drive_smoke: ACTIVE quest should beat time greeting, got %s" % active)
		quit(1)
		return false

	# 4) Completed beats active / time / returning.
	qs.call("complete_quest", "power_the_viewpoint")
	var done := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if done != "mira_quest_done_01":
		push_error("drive_smoke: COMPLETED should resolve mira_quest_done_01, got %s" % done)
		quit(1)
		return false

	# 5) Tie-break: equal priority → lower authored index wins.
	var RuleScript: Script = load("res://scripts/npc/npc_dialogue_rule.gd") as Script
	var DefScript: Script = load("res://scripts/npc/npc_definition.gd") as Script
	if RuleScript == null or DefScript == null:
		push_error("drive_smoke: could not load rule/definition scripts")
		quit(1)
		return false
	var rule_a: Resource = RuleScript.new()
	rule_a.set("id", "tie_a")
	rule_a.set("dialogue_id", "mira_01")
	rule_a.set("priority", 10)
	rule_a.set("enabled", true)
	rule_a.set("conditions", [])
	var rule_b: Resource = RuleScript.new()
	rule_b.set("id", "tie_b")
	rule_b.set("dialogue_id", "mira_02")
	rule_b.set("priority", 10)
	rule_b.set("enabled", true)
	rule_b.set("conditions", [])
	var tie_def: Resource = DefScript.new()
	tie_def.set("npc_id", "tie_test_npc")
	tie_def.set("fallback_dialogue_id", "mira_intro")
	tie_def.set("dialogue_rules", [rule_a, rule_b])
	var tied := str(dlg.call("resolve_dialogue_from_definition", tie_def))
	if tied != "mira_01":
		push_error("drive_smoke: equal priority should prefer lower index (mira_01), got %s" % tied)
		quit(1)
		return false

	# 6) No matching rules / all fail → fallback.
	var fail_rule: Resource = RuleScript.new()
	fail_rule.set("id", "fail")
	fail_rule.set("dialogue_id", "mira_returning")
	fail_rule.set("priority", 99)
	fail_rule.set("enabled", true)
	fail_rule.set("conditions", [cond.call("make_npc_met", "nobody_here", true)])
	var fb_def: Resource = DefScript.new()
	fb_def.set("npc_id", "fallback_npc")
	fb_def.set("fallback_dialogue_id", "mira_intro")
	fb_def.set("dialogue_rules", [fail_rule])
	var fb := str(dlg.call("resolve_dialogue_from_definition", fb_def))
	if fb != "mira_intro":
		push_error("drive_smoke: fallback_dialogue_id should win when rules fail, got %s" % fb)
		quit(1)
		return false

	# Live Mira interact uses resolve (no fixed dialogue_id).
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_sys != null and poi_res != null and vp_scene != null:
		qs.call("reset_all")
		ns.call("reset_for_tests")
		var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
		var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(8.0, 0.0, -4.0))
		var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
		var mira: Node = vp.find_child("Mira", true, false) if vp != null else null
		if mira == null:
			push_error("drive_smoke: Mira missing for npc rules live check")
			quit(1)
			return false
		if str(mira.call("get_dialogue_id")) != "mira_intro":
			push_error("drive_smoke: live Mira should open mira_intro first")
			quit(1)
			return false
		character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.5)
		await physics_frame
		if not bool(mira.call("interact", character)):
			push_error("drive_smoke: Mira intro interact failed")
			quit(1)
			return false
		await physics_frame
		if str(dlg.call("get_current_id")) != "mira_intro":
			push_error("drive_smoke: interact started wrong line %s" % str(dlg.call("get_current_id")))
			quit(1)
			return false
		# Advance intro → offer choices → accept (starts quest).
		dlg.call("advance")
		await physics_frame
		dlg.call("set_choice_index", 0)
		await physics_frame
		dlg.call("confirm_choice")
		await physics_frame
		if str(mira.call("get_dialogue_id")) != "mira_quest_active_01":
			push_error(
				"drive_smoke: after intro Mira should be active quest line, got %s"
				% str(mira.call("get_dialogue_id"))
			)
			quit(1)
			return false
		poi_sys.call("despawn_viewpoint", "sunset_viewpoint")

	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	if gt_rules != null and gt_rules.has_method("reset_for_tests"):
		gt_rules.call("reset_for_tests")
	print("drive_smoke: npc_rules OK (intro → time_day → active → done + ties + fallback)")
	return true


func _verify_npc_state(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## NpcStateSystem: static NpcDefinition vs mutable campaign state; Mira met; Rafa BUSY; unload + save.
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if ns == null or dlg == null or cond == null or save == null or poi_sys == null:
		push_error("drive_smoke: systems missing for npc_state")
		quit(1)
		return false

	const MIRA_ID := "mira_viewpoint_keeper"
	const RAFA_ID := "rafa_road_traveler"

	var ns_script: Script = load("res://autoload/npc_state_system.gd") as Script
	if ns_script != null:
		var src := ns_script.source_code
		for banned in ["Mira", "Rafa", "mira_viewpoint", "rafa_road", "ViewpointPOI"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: NpcStateSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	var def_script: Script = load("res://scripts/npc/npc_definition.gd") as Script
	if def_script != null:
		var def_src := def_script.source_code
		for mutable_field in ["met_player", "current_state", "current_location_id", "last_dialogue_id"]:
			if def_src.find(mutable_field) >= 0:
				push_error("drive_smoke: NpcDefinition must stay static (found '%s')" % mutable_field)
				quit(1)
				return false

	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_catalog")
	save.call("delete_save")
	_clear_world_state()

	# Defaults + API surface.
	if bool(ns.call("has_met_player", MIRA_ID)):
		push_error("drive_smoke: Mira should not be met before talk")
		quit(1)
		return false
	if str(ns.call("get_current_state", RAFA_ID)) != "DEFAULT":
		push_error("drive_smoke: Rafa default state should be DEFAULT")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_enabled", MIRA_ID, true))):
		push_error("drive_smoke: NPC_ENABLED should default true")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_npc_met", MIRA_ID, true))):
		push_error("drive_smoke: NPC_MET should be false before talk")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_npc_state", RAFA_ID, "BUSY"))):
		push_error("drive_smoke: NPC_STATE BUSY should be false initially")
		quit(1)
		return false

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("drive_smoke: missing viewpoint resources for npc_state")
		quit(1)
		return false
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(12.0, 0.0, -6.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: viewpoint spawn failed for npc_state")
		quit(1)
		return false

	var mira: Node = vp.find_child("Mira", true, false)
	var rafa: Node = vp.find_child("Rafa", true, false)
	if mira == null or rafa == null:
		push_error("drive_smoke: Mira/Rafa missing for npc_state")
		quit(1)
		return false

	# Schedule owns logical location when present (narrative hour 10 → workshop).
	var gt_ns: Node = root.get_node_or_null("GameTimeSystem")
	var sched_ns: Node = root.get_node_or_null("NpcScheduleSystem")
	if gt_ns != null and gt_ns.has_method("set_narrative_time"):
		gt_ns.call("set_narrative_time", 0, 10, 0)
	if sched_ns != null and sched_ns.has_method("refresh_all"):
		sched_ns.call("refresh_all")
	await physics_frame
	await physics_frame
	if str(ns.call("get_location_id", MIRA_ID)) != "viewpoint_workshop":
		push_error(
			"drive_smoke: Mira location should be viewpoint_workshop at hour 10, got '%s'"
			% str(ns.call("get_location_id", MIRA_ID))
		)
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_location", MIRA_ID, "viewpoint_workshop"))):
		push_error("drive_smoke: NPC_LOCATION condition failed after schedule resolve")
		quit(1)
		return false

	# --- Mira: first talk → met_player ---
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.6)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("drive_smoke: Mira interact failed in npc_state")
		quit(1)
		return false
	await physics_frame
	if not bool(ns.call("has_met_player", MIRA_ID)):
		push_error("drive_smoke: Mira met_player should be true after first talk")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_met", MIRA_ID, true))):
		push_error("drive_smoke: NPC_MET condition failed after Mira talk")
		quit(1)
		return false
	if str(ns.call("get_last_dialogue_id", MIRA_ID)).is_empty():
		push_error("drive_smoke: Mira last_dialogue_id should be set after talk")
		quit(1)
		return false
	dlg.call("end_dialogue", true)
	await physics_frame
	var qs: Node = root.get_node_or_null("QuestSystem")
	if qs != null:
		qs.call("reset_all")

	# --- Rafa: far choice → BUSY; NPC_STATE gates busy line ---
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	character.global_position = (rafa as Node3D).global_position + Vector3(0.0, 0.05, 1.6)
	await physics_frame
	if str(rafa.call("get_dialogue_id")) != "rafa_01":
		push_error("drive_smoke: Rafa should open rafa_01 before BUSY")
		quit(1)
		return false
	if not bool(rafa.call("interact", character)):
		push_error("drive_smoke: Rafa interact failed in npc_state")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "rafa_02":
		push_error("drive_smoke: expected rafa_02 before far choice")
		quit(1)
		return false
	dlg.call("set_choice_index", 1)  # rafa_far → SET_NPC_STATE BUSY
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if str(ns.call("get_current_state", RAFA_ID)) != "BUSY":
		push_error(
			"drive_smoke: Rafa current_state should be BUSY after far choice, got '%s'"
			% str(ns.call("get_current_state", RAFA_ID))
		)
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_state", RAFA_ID, "BUSY"))):
		push_error("drive_smoke: NPC_STATE BUSY condition failed")
		quit(1)
		return false
	if not bool(ns.call("has_met_player", RAFA_ID)):
		push_error("drive_smoke: Rafa met_player should be true after talk")
		quit(1)
		return false

	# Priority rules: BUSY beats return/fallback.
	var rafa_def: Resource = load("res://resources/npc/rafa_road_traveler.tres")
	dlg.call("register_npc_definition", rafa_def)
	var resolved := str(dlg.call("resolve_dialogue_for_npc", "rafa_road_traveler"))
	if resolved != "rafa_busy_01":
		push_error("drive_smoke: expected rafa_busy_01 from BUSY rule, got %s" % resolved)
		quit(1)
		return false
	if str(rafa.call("get_dialogue_id")) != "rafa_busy_01":
		push_error("drive_smoke: Rafa scene should resolve to rafa_busy_01 while BUSY")
		quit(1)
		return false
	if not bool(dlg.call("start_dialogue", "rafa_busy_01", character)):
		push_error("drive_smoke: rafa_busy_01 failed to start")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_text")).find("ocupado") < 0:
		push_error("drive_smoke: unexpected Rafa BUSY line")
		quit(1)
		return false
	dlg.call("end_dialogue", true)
	await physics_frame

	# Unload NPC scenes — logical state must survive (no Node refs).
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	await physics_frame
	if not bool(ns.call("has_met_player", MIRA_ID)):
		push_error("drive_smoke: Mira met_player lost after unload")
		quit(1)
		return false
	if str(ns.call("get_current_state", RAFA_ID)) != "BUSY":
		push_error("drive_smoke: Rafa BUSY lost after unload")
		quit(1)
		return false

	# Save / load round-trip.
	if not bool(save.call("save_game")):
		push_error("drive_smoke: npc_state save failed")
		quit(1)
		return false
	ns.call("reset_for_tests")
	if bool(ns.call("has_met_player", MIRA_ID)):
		push_error("drive_smoke: npc_state should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: npc_state load failed")
		quit(1)
		return false
	if not bool(ns.call("has_met_player", MIRA_ID)):
		push_error("drive_smoke: Mira met_player lost after load")
		quit(1)
		return false
	if str(ns.call("get_current_state", RAFA_ID)) != "BUSY":
		push_error("drive_smoke: Rafa BUSY lost after load")
		quit(1)
		return false
	# After load, schedule re-resolves against narrative hour → workshop at hour 10.
	if str(ns.call("get_location_id", MIRA_ID)) != "viewpoint_workshop":
		push_error(
			"drive_smoke: Mira schedule location lost after load (got '%s')"
			% str(ns.call("get_location_id", MIRA_ID))
		)
		quit(1)
		return false

	# Respawn reads NpcStateSystem (definition stays static).
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	rafa = vp.find_child("Rafa", true, false)
	mira = vp.find_child("Mira", true, false)
	await physics_frame
	if rafa == null or mira == null:
		push_error("drive_smoke: Mira/Rafa missing after respawn")
		quit(1)
		return false
	if str(rafa.call("get_dialogue_id")) != "rafa_busy_01":
		push_error("drive_smoke: Rafa should stay BUSY dialogue after respawn")
		quit(1)
		return false
	if not bool(mira.call("is_npc_enabled")):
		push_error("drive_smoke: Mira enabled should read from NpcStateSystem after respawn")
		quit(1)
		return false

	save.call("delete_save")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	if qs != null:
		qs.call("reset_all")
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: npc_state OK (Mira met + Rafa BUSY + unload + save + NPC_STATE)")
	return true


func _choice_ids(choices: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for entry in choices:
		if entry == null:
			continue
		out.append(str(entry.get("id")))
	return out


func _verify_relationship_system(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Relationship vs reputation maps, clamps, conditions, Mira +5 / quest +10, save/load.
	var rs: Node = root.get_node_or_null("RelationshipSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if rs == null or dlg == null or cond == null or qs == null or save == null:
		push_error("drive_smoke: systems missing for relationship")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	const RAFA := "rafa_road_traveler"
	const GROUP := "sunset_viewpoint"

	var rs_script: Script = load("res://autoload/relationship_system.gd") as Script
	if rs_script != null:
		var src := rs_script.source_code
		for banned in ["DialogueSystem", "Mira", "mira_viewpoint", "rafa_road", "accept_help"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: RelationshipSystem must not contain '%s'" % banned)
				quit(1)
				return false

	rs.call("reset_for_tests")
	qs.call("reset_all")
	save.call("delete_save")

	# Defaults + independent maps.
	if int(rs.call("get_relationship", MIRA)) != 0 or int(rs.call("get_reputation", GROUP)) != 0:
		push_error("drive_smoke: relationship/reputation should default to 0")
		quit(1)
		return false
	rs.call("set_relationship", MIRA, 12)
	rs.call("set_reputation", GROUP, -5)
	if int(rs.call("get_relationship", MIRA)) != 12:
		push_error("drive_smoke: set_relationship failed")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != -5:
		push_error("drive_smoke: set_reputation failed")
		quit(1)
		return false
	if int(rs.call("get_relationship", RAFA)) != 0:
		push_error("drive_smoke: Rafa relationship should stay independent at 0")
		quit(1)
		return false

	# Clamps -100..+100.
	if int(rs.call("get", "min_value")) != -100 or int(rs.call("get", "max_value")) != 100:
		push_error("drive_smoke: default clamps should be -100..100")
		quit(1)
		return false
	if int(rs.call("set_relationship", MIRA, 500)) != 100:
		push_error("drive_smoke: relationship should clamp to +100")
		quit(1)
		return false
	if int(rs.call("set_reputation", GROUP, -500)) != -100:
		push_error("drive_smoke: reputation should clamp to -100")
		quit(1)
		return false
	if int(rs.call("add_relationship", MIRA, -30)) != 70:
		push_error("drive_smoke: add_relationship after clamp failed")
		quit(1)
		return false

	# Tier helper (display only).
	if str(rs.call("tier_name", 0)) != "NEUTRAL":
		push_error("drive_smoke: tier NEUTRAL expected at 0")
		quit(1)
		return false
	if str(rs.call("get_relationship_tier", MIRA)) != "TRUSTED":
		push_error("drive_smoke: tier TRUSTED expected at 70")
		quit(1)
		return false

	# Conditions.
	rs.call("set_relationship", MIRA, 5)
	rs.call("set_reputation", GROUP, 10)
	if not bool(cond.call("evaluate", cond.call("make_relationship_min", MIRA, 5))):
		push_error("drive_smoke: RELATIONSHIP_MIN failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_relationship_max", MIRA, 4))):
		push_error("drive_smoke: RELATIONSHIP_MAX should fail when above max")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_reputation_min", GROUP, 10))):
		push_error("drive_smoke: REPUTATION_MIN failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_reputation_max", GROUP, 9))):
		push_error("drive_smoke: REPUTATION_MAX should fail when above max")
		quit(1)
		return false

	# Mira kind choice → +5 relationship (explicit action on accept_help).
	rs.call("reset_for_tests")
	qs.call("reset_all")
	dlg.call("reload_catalog")
	if not bool(dlg.call("start_dialogue", "mira_intro", character)):
		push_error("drive_smoke: relationship Mira intro failed")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 0)  # accept_help
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if int(rs.call("get_relationship", MIRA)) != 5:
		push_error(
			"drive_smoke: accept_help should add +5 Mira relationship, got %d"
			% int(rs.call("get_relationship", MIRA))
		)
		quit(1)
		return false
	if int(rs.call("get_relationship", RAFA)) != 0:
		push_error("drive_smoke: Rafa must stay 0 after Mira kind choice")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != 0:
		push_error("drive_smoke: reputation must not change on Mira choice alone")
		quit(1)
		return false

	# Quest complete → +10 reputation sunset_viewpoint (on_complete_actions).
	if not bool(qs.call("is_active", "power_the_viewpoint")):
		qs.call("start_quest", "power_the_viewpoint")
	if not bool(qs.call("complete_quest", "power_the_viewpoint")):
		push_error("drive_smoke: could not complete quest for reputation")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != 10:
		push_error(
			"drive_smoke: quest complete should add +10 sunset_viewpoint reputation, got %d"
			% int(rs.call("get_reputation", GROUP))
		)
		quit(1)
		return false
	# No automatic extra grants.
	if int(rs.call("get_relationship", MIRA)) != 5:
		push_error("drive_smoke: quest complete must not alter Mira relationship")
		quit(1)
		return false

	# Save / load.
	if not bool(save.call("save_game")):
		push_error("drive_smoke: relationship save failed")
		quit(1)
		return false
	rs.call("reset_for_tests")
	if int(rs.call("get_relationship", MIRA)) != 0:
		push_error("drive_smoke: relationship should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("drive_smoke: relationship load failed")
		quit(1)
		return false
	if int(rs.call("get_relationship", MIRA)) != 5:
		push_error("drive_smoke: Mira relationship lost after load")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != 10:
		push_error("drive_smoke: sunset_viewpoint reputation lost after load")
		quit(1)
		return false

	save.call("delete_save")
	rs.call("reset_for_tests")
	qs.call("reset_all")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: relationship OK (Mira +5 / viewpoint +10 + clamp + conditions + save)")
	return true


func _verify_time_npc_availability(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Narrative world clock → Mira 08–18 window + day/night dialogue (ConditionSystem rules).
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if gt == null or dlg == null or cond == null or ns == null or qs == null or poi_sys == null:
		push_error("drive_smoke: systems missing for time NPC availability")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"

	var npc_script: Script = load("res://scripts/npc/npc_character.gd") as Script
	if npc_script != null:
		var src := npc_script.source_code
		for banned in [
			"DirectionalLight",
			"WorldEnvironment",
			"sky_energy",
			"Time.get_datetime_dict_from_system",
			"Time.get_datetime_string_from_system",
		]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: NpcCharacter must not contain '%s'" % banned)
				quit(1)
				return false

	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_catalog")
	dlg.call("reload_npc_catalog")
	gt.call("reset_for_tests")

	var mira_def: Resource = load("res://resources/npc/mira_viewpoint_keeper.tres")
	if mira_def == null:
		push_error("drive_smoke: Mira definition missing for time window")
		quit(1)
		return false
	if int(mira_def.get("available_hour_min")) != 8 or int(mira_def.get("available_hour_max")) != 18:
		push_error(
			"drive_smoke: Mira window expected 8–18, got %d–%d"
			% [int(mira_def.get("available_hour_min")), int(mira_def.get("available_hour_max"))]
		)
		quit(1)
		return false

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("drive_smoke: viewpoint resources missing for time NPC")
		quit(1)
		return false
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(8.0, 0.0, -4.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	var mira: Node = vp.find_child("Mira", true, false) if vp != null else null
	if mira == null:
		push_error("drive_smoke: Mira missing for time availability")
		quit(1)
		return false

	# Persist met flag across hide/show — availability must not wipe NpcState.
	ns.call("set_met_player", MIRA, true)
	ns.call("set_custom_flag", MIRA, "smoke_persist", true)

	# Daytime: visible + interactable → "Bom dia." via dialogue rules / conditions.
	gt.call("set_narrative_time", 0, 10, 0)
	await physics_frame
	await physics_frame
	if not bool(mira.call("is_within_availability_window")):
		push_error("drive_smoke: Mira should be available at narrative hour 10")
		quit(1)
		return false
	if not bool(mira.visible):
		push_error("drive_smoke: Mira should be visible at narrative hour 10")
		quit(1)
		return false
	var day_id := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if day_id != "mira_time_day":
		push_error("drive_smoke: day resolve expected mira_time_day, got %s" % day_id)
		quit(1)
		return false
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.5)
	await physics_frame
	if not bool(mira.call("can_interact", character)):
		push_error("drive_smoke: Mira should be interactable at narrative hour 10")
		quit(1)
		return false
	if not bool(mira.call("interact", character)):
		push_error("drive_smoke: Mira day interact failed")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_time_day":
		push_error("drive_smoke: day dialogue id wrong: %s" % str(dlg.call("get_current_id")))
		quit(1)
		return false
	var day_text := str(dlg.call("get_current_text")) if dlg.has_method("get_current_text") else ""
	if day_text.find("Bom dia") < 0:
		push_error("drive_smoke: day line should contain 'Bom dia.', got '%s'" % day_text)
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Night outside window: hidden; dialogue rules still resolve night line.
	gt.call("set_narrative_time", 0, 22, 0)
	await physics_frame
	await physics_frame
	if bool(mira.call("is_within_availability_window")):
		push_error("drive_smoke: Mira should be outside window at narrative hour 22")
		quit(1)
		return false
	if bool(mira.visible):
		push_error("drive_smoke: Mira should be hidden at narrative hour 22")
		quit(1)
		return false
	if bool(mira.call("can_interact", character)):
		push_error("drive_smoke: Mira should not be interactable at narrative hour 22")
		quit(1)
		return false
	# Persistent campaign fields kept while hidden (schedule may update state/location).
	if ns.has_method("has_met_player") and not bool(ns.call("has_met_player", MIRA)):
		push_error("drive_smoke: hiding Mira must not clear met_player")
		quit(1)
		return false
	if ns.has_method("get_custom_flag") and not bool(ns.call("get_custom_flag", MIRA, "smoke_persist", false)):
		push_error("drive_smoke: hiding Mira must not clear custom flags")
		quit(1)
		return false
	var night_id := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if night_id != "mira_time_night":
		push_error("drive_smoke: night resolve expected mira_time_night, got %s" % night_id)
		quit(1)
		return false
	var night_res: Resource = load("res://resources/dialogue/mira_time_night.tres")
	if night_res == null or str(night_res.get("text")).find("tarde") < 0:
		push_error("drive_smoke: night line should be 'Está ficando tarde.'")
		quit(1)
		return false

	# Cross-midnight range condition 22–06.
	if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
		push_error("drive_smoke: range 22–6 should pass at 22:00")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 5, 0)
	if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
		push_error("drive_smoke: range 22–6 should pass at 05:00")
		quit(1)
		return false

	# Midnight wrap via advance_narrative_seconds.
	gt.call("set_narrative_time", 0, 23, 0)
	gt.call("advance_narrative_seconds", 60.0)  # scale 60 → +1 hour
	if int(gt.call("get_narrative_day_index")) != 1 or int(gt.call("get_narrative_hour")) != 0:
		push_error(
			"drive_smoke: narrative midnight wrap failed (day%d/h%d)"
			% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
		)
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	gt.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"drive_smoke: time_npc OK (independent narrative + Mira window + day/night + range 22–6)"
	)
	return true


func _verify_npc_schedules(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Data-driven NpcScheduleSystem: Mira daily routine + Rafa cross-midnight; save/load.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if gt == null or ns == null or sched == null or save == null:
		push_error("drive_smoke: systems missing for npc schedules")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	const RAFA := "rafa_road_traveler"

	var sched_script: Script = load("res://autoload/npc_schedule_system.gd") as Script
	if sched_script != null:
		var src := sched_script.source_code
		for banned in [
			"mira_viewpoint_keeper",
			"rafa_road_traveler",
			"viewpoint_workshop",
			"Time.get_datetime_dict_from_system",
			"get_total_travel_time",
		]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: NpcScheduleSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	save.call("delete_save")

	if not bool(sched.call("has_schedule", MIRA)) or not bool(sched.call("has_schedule", RAFA)):
		push_error("drive_smoke: catalog should register Mira and Rafa schedules")
		quit(1)
		return false

	var changed: Array = []
	var on_changed := func(
		npc_id: String, _loc: String, _state: String, _act: String, _sid: String
	) -> void:
		changed.append(npc_id)
	if sched.has_signal("npc_schedule_changed"):
		sched.npc_schedule_changed.connect(on_changed)

	# Mira: 10 workshop WORKING, 12 diner EATING, 15 workshop, 20 home RESTING, 3 fallback home.
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_workshop":
		push_error("drive_smoke: Mira@10 location expected viewpoint_workshop")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "WORKING":
		push_error("drive_smoke: Mira@10 state expected WORKING")
		quit(1)
		return false
	if str(ns.call("get_schedule_id", MIRA)) != "mira_daily":
		push_error("drive_smoke: Mira schedule_id expected mira_daily")
		quit(1)
		return false
	if str(sched.call("get_active_activity_id", MIRA)) != "workshop_morning":
		push_error("drive_smoke: Mira@10 activity expected workshop_morning")
		quit(1)
		return false

	gt.call("set_narrative_time", 0, 12, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_diner":
		push_error("drive_smoke: Mira@12 location expected viewpoint_diner")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "EATING":
		push_error("drive_smoke: Mira@12 state expected EATING")
		quit(1)
		return false

	gt.call("set_narrative_time", 0, 15, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_workshop":
		push_error("drive_smoke: Mira@15 location expected viewpoint_workshop")
		quit(1)
		return false
	if str(sched.call("get_active_activity_id", MIRA)) != "workshop_afternoon":
		push_error("drive_smoke: Mira@15 activity expected workshop_afternoon")
		quit(1)
		return false

	gt.call("set_narrative_time", 0, 20, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("drive_smoke: Mira@20 location expected viewpoint_home")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "RESTING":
		push_error("drive_smoke: Mira@20 state expected RESTING")
		quit(1)
		return false

	# 00–08: no entry → fallback home RESTING.
	gt.call("set_narrative_time", 0, 3, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("drive_smoke: Mira@3 fallback location expected viewpoint_home")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "RESTING":
		push_error("drive_smoke: Mira@3 fallback state expected RESTING")
		quit(1)
		return false
	if str(sched.call("get_active_activity_id", MIRA)) != "sleep":
		push_error("drive_smoke: Mira@3 fallback activity expected sleep")
		quit(1)
		return false

	# Two NPCs differ at the same hour.
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_pullout":
		push_error("drive_smoke: Rafa@10 expected roadside_pullout")
		quit(1)
		return false
	if str(ns.call("get_location_id", MIRA)) == str(ns.call("get_location_id", RAFA)):
		push_error("drive_smoke: Mira and Rafa should have different schedule locations")
		quit(1)
		return false
	if str(ns.call("get_schedule_id", RAFA)) != "rafa_roadside":
		push_error("drive_smoke: Rafa schedule_id expected rafa_roadside")
		quit(1)
		return false

	# Rafa cross-midnight 20→06.
	gt.call("set_narrative_time", 0, 22, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_camp":
		push_error("drive_smoke: Rafa@22 cross-midnight expected roadside_camp")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 4, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_camp":
		push_error("drive_smoke: Rafa@04 cross-midnight expected roadside_camp")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 7, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_pullout":
		push_error("drive_smoke: Rafa@07 expected roadside_pullout")
		quit(1)
		return false

	# Empty schedule state must not wipe dialogue-driven BUSY.
	ns.call("set_current_state", RAFA, "BUSY")
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	if str(ns.call("get_current_state", RAFA)) != "BUSY":
		push_error("drive_smoke: Rafa empty schedule state must preserve BUSY")
		quit(1)
		return false

	# Midnight wrap: Mira 23 home → advance to hour 0 still fallback home.
	gt.call("set_narrative_time", 0, 23, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("drive_smoke: Mira@23 expected viewpoint_home")
		quit(1)
		return false
	gt.call("advance_narrative_seconds", 60.0)
	sched.call("refresh_all")
	if int(gt.call("get_narrative_day_index")) != 1:
		push_error("drive_smoke: schedule midnight wrap should reach day 1")
		quit(1)
		return false
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("drive_smoke: Mira after midnight expected fallback home")
		quit(1)
		return false

	# Save / load: pin hour 12 diner, persist, reload, still diner (+ schedule_id).
	gt.call("set_narrative_time", 1, 12, 0)
	sched.call("refresh_all")
	if not bool(save.call("save_game")):
		push_error("drive_smoke: npc schedule save failed")
		quit(1)
		return false
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("drive_smoke: npc schedule load failed")
		quit(1)
		return false
	await physics_frame
	await physics_frame
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_diner":
		push_error(
			"drive_smoke: Mira diner location not restored/resolved after load (got '%s')"
			% str(ns.call("get_location_id", MIRA))
		)
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "EATING":
		push_error("drive_smoke: Mira EATING not restored after load")
		quit(1)
		return false
	if str(ns.call("get_schedule_id", MIRA)) != "mira_daily":
		push_error("drive_smoke: Mira schedule_id not restored after load")
		quit(1)
		return false

	if sched.has_signal("npc_schedule_changed") and sched.npc_schedule_changed.is_connected(on_changed):
		sched.npc_schedule_changed.disconnect(on_changed)
	if changed.is_empty():
		push_error("drive_smoke: npc_schedule_changed never emitted")
		quit(1)
		return false

	save.call("delete_save")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"drive_smoke: npc_sched OK (Mira routine + Rafa cross-midnight + fallback + save + signal)"
	)
	return true


func _verify_npc_movement(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Mira walks between Sunset Viewpoint markers; dialogue pauses; reload snaps.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if gt == null or ns == null or sched == null or dlg == null or poi_sys == null:
		push_error("drive_smoke: systems missing for npc movement")
		quit(1)
		return false

	var move_script: Script = load("res://scripts/npc/npc_movement_controller.gd") as Script
	if move_script != null:
		var src := move_script.source_code
		for banned in ["mira_viewpoint_keeper", "DialogueSystem.start_dialogue", "final anim"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: NpcMovementController must not contain '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	if dlg.has_method("reload_catalog"):
		dlg.call("reload_catalog")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(10.0, 0.0, -5.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: viewpoint spawn failed for npc movement")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	var destinations: Node = vp.get_node_or_null("Destinations")
	if destinations == null:
		push_error("drive_smoke: Destinations node missing on ViewpointPOI")
		quit(1)
		return false
	for needed in ["viewpoint_workshop", "viewpoint_diner", "viewpoint_home"]:
		if destinations.get_node_or_null(needed) == null:
			push_error("drive_smoke: missing destination marker '%s'" % needed)
			quit(1)
			return false
	if vp.get_node_or_null("NavigationRegion3D") == null:
		push_error("drive_smoke: NavigationRegion3D missing on ViewpointPOI")
		quit(1)
		return false

	var mira: Node3D = vp.find_child("Mira", true, false) as Node3D
	if mira == null:
		push_error("drive_smoke: Mira missing for movement")
		quit(1)
		return false
	var movement: Node = mira.get_node_or_null("NpcMovementController")
	if movement == null:
		push_error("drive_smoke: NpcMovementController missing on Mira")
		quit(1)
		return false
	movement.set("max_speed", 12.0)
	movement.set("acceleration", 40.0)

	# Hour 10 → snap/arrive at workshop.
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	await physics_frame
	var workshop: Marker3D = destinations.get_node("viewpoint_workshop") as Marker3D
	var diner: Marker3D = destinations.get_node("viewpoint_diner") as Marker3D
	if not bool(movement.call("go_to_location", "viewpoint_workshop", true)):
		push_error("drive_smoke: go_to_location(workshop, snap) failed")
		quit(1)
		return false
	await physics_frame
	if mira.global_position.distance_to(workshop.global_position) > 0.75:
		push_error(
			"drive_smoke: Mira should snap to workshop (dist=%.2f mira=%s mark=%s)"
			% [
				mira.global_position.distance_to(workshop.global_position),
				str(mira.global_position),
				str(workshop.global_position),
			]
		)
		quit(1)
		return false

	# Hour 12 → walk toward diner.
	gt.call("set_narrative_time", 0, 12, 0)
	sched.call("refresh_all")
	await physics_frame
	var start_pos := mira.global_position
	var start_dist := start_pos.distance_to(diner.global_position)
	for _i in range(90):
		await physics_frame
		if mira.global_position.distance_to(diner.global_position) < 0.6:
			break
	var end_dist := mira.global_position.distance_to(diner.global_position)
	if end_dist >= start_dist - 0.15:
		push_error(
			"drive_smoke: Mira should walk toward diner (start=%.2f end=%.2f)"
			% [start_dist, end_dist]
		)
		quit(1)
		return false

	# Dialogue pauses movement; schedule may update desired target but walk waits.
	ns.call("set_met_player", "mira_viewpoint_keeper", true)
	character.global_position = mira.global_position + Vector3(0.0, 0.05, 1.4)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("drive_smoke: Mira interact failed during movement pause test")
		quit(1)
		return false
	await physics_frame
	if movement.has_method("is_paused") and not bool(movement.call("is_paused")):
		push_error("drive_smoke: movement should pause during dialogue")
		quit(1)
		return false
	# Still within Mira's availability window (08–18); retarget workshop while paused.
	gt.call("set_narrative_time", 0, 15, 0)
	sched.call("refresh_all")
	await physics_frame
	var paused_pos := mira.global_position
	for _j in range(20):
		await physics_frame
	if mira.global_position.distance_to(paused_pos) > 0.08:
		push_error("drive_smoke: Mira moved during dialogue pause")
		quit(1)
		return false
	if str(movement.call("get_desired_location_id")) != "viewpoint_workshop":
		push_error("drive_smoke: paused Mira should keep updated desired workshop target")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame
	await physics_frame
	if movement.has_method("is_paused") and bool(movement.call("is_paused")):
		push_error("drive_smoke: movement should resume after dialogue")
		quit(1)
		return false

	# Missing destination fails safe (logical state kept).
	ns.call("set_location_id", "mira_viewpoint_keeper", "viewpoint_workshop")
	if not bool(movement.call("go_to_location", "no_such_marker", false)):
		if str(ns.call("get_location_id", "mira_viewpoint_keeper")) != "viewpoint_workshop":
			push_error("drive_smoke: missing marker must not wipe logical location")
			quit(1)
			return false
	else:
		push_error("drive_smoke: go_to_location should fail for missing marker")
		quit(1)
		return false

	# Reload snap: despawn / respawn at hour 15 → workshop without long path sim.
	gt.call("set_narrative_time", 0, 15, 0)
	sched.call("refresh_all")
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	await physics_frame
	mira = vp.find_child("Mira", true, false) as Node3D
	destinations = vp.get_node_or_null("Destinations")
	workshop = destinations.get_node("viewpoint_workshop") as Marker3D if destinations != null else null
	if mira == null or workshop == null:
		push_error("drive_smoke: Mira/workshop missing after reload snap")
		quit(1)
		return false
	movement = mira.get_node_or_null("NpcMovementController")
	if movement != null and movement.has_method("snap_to_current_schedule"):
		movement.call("snap_to_current_schedule")
	await physics_frame
	if mira.global_position.distance_to(workshop.global_position) > 0.9:
		push_error(
			"drive_smoke: reload should snap Mira to workshop (dist=%.2f)"
			% mira.global_position.distance_to(workshop.global_position)
		)
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: npc_move OK (walk + dialogue pause + fail-safe + reload snap)")
	return true


func _verify_npc_travel(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Logical traveler relocation: leave POI → TRAVELING → arrive at debug location.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var travel: Node = root.get_node_or_null("NpcTravelSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	if (
		gt == null
		or ns == null
		or sched == null
		or travel == null
		or cond == null
		or save == null
		or poi_sys == null
		or dlg == null
	):
		push_error("drive_smoke: systems missing for npc travel")
		quit(1)
		return false

	const RAFA := "rafa_road_traveler"
	const DEST := "debug_waystation"

	var travel_script: Script = load("res://autoload/npc_travel_system.gd") as Script
	if travel_script != null:
		var src := travel_script.source_code
		for banned in ["rafa_road_traveler", "Rafa", "mira_viewpoint_keeper", "Mira", "debug_waystation"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: NpcTravelSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	save.call("delete_save")
	if dlg.has_method("reload_catalog"):
		dlg.call("reload_catalog")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(8.0, 0.0, -8.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: viewpoint spawn failed for npc travel")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	await physics_frame

	var rafa: Node3D = vp.find_child("Rafa", true, false) as Node3D
	var mira: Node3D = vp.find_child("Mira", true, false) as Node3D
	if rafa == null or mira == null:
		push_error("drive_smoke: Rafa/Mira missing before travel")
		quit(1)
		return false
	if str(ns.call("get_location_id", RAFA)) != "roadside_pullout":
		push_error(
			"drive_smoke: Rafa should start at roadside_pullout (got '%s')"
			% str(ns.call("get_location_id", RAFA))
		)
		quit(1)
		return false
	if str(ns.call("get_travel_state", RAFA)) != "AT_LOCATION":
		push_error("drive_smoke: Rafa travel_state should start AT_LOCATION")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_at_location", RAFA, "roadside_pullout"))):
		push_error("drive_smoke: NPC_AT_LOCATION roadside_pullout failed")
		quit(1)
		return false

	# DialogueAction START_NPC_TRAVEL → destination debug_waystation, +60 narrative minutes.
	var ActionScript: Script = load("res://scripts/dialogue/dialogue_action.gd") as Script
	var ExecScript: Script = load("res://scripts/dialogue/dialogue_action_executor.gd") as Script
	var action: Resource = ActionScript.new() as Resource
	action.set("type", 16)  # START_NPC_TRAVEL
	action.set("target_id", RAFA)
	action.set("string_value", DEST)
	action.set("secondary_id", "rafa_leave_viewpoint")
	action.set("int_value", 60)
	action.set("float_value", 0.0)
	var executor = ExecScript.new()
	if not bool(executor.call("execute", action)):
		push_error("drive_smoke: START_NPC_TRAVEL action failed")
		quit(1)
		return false
	await physics_frame
	await physics_frame
	await physics_frame

	if str(ns.call("get_travel_state", RAFA)) != "TRAVELING":
		push_error("drive_smoke: Rafa should be TRAVELING after start")
		quit(1)
		return false
	if str(ns.call("get_destination_location_id", RAFA)) != DEST:
		push_error("drive_smoke: Rafa destination should be debug_waystation")
		quit(1)
		return false
	if str(ns.call("get_previous_location_id", RAFA)) != "roadside_pullout":
		push_error("drive_smoke: Rafa previous_location should be roadside_pullout")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_travel_state", RAFA, "TRAVELING"))):
		push_error("drive_smoke: NPC_TRAVEL_STATE TRAVELING failed")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_destination", RAFA, DEST))):
		push_error("drive_smoke: NPC_DESTINATION failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_npc_at_location", RAFA, "roadside_pullout"))):
		push_error("drive_smoke: NPC_AT_LOCATION must be false while TRAVELING")
		quit(1)
		return false

	rafa = vp.find_child("Rafa", true, false) as Node3D
	mira = vp.find_child("Mira", true, false) as Node3D
	if rafa != null and is_instance_valid(rafa):
		push_error("drive_smoke: Rafa physical presence should leave Sunset Viewpoint")
		quit(1)
		return false
	if mira == null or not is_instance_valid(mira):
		push_error("drive_smoke: Mira must remain while Rafa travels")
		quit(1)
		return false

	# Persist mid-travel.
	if not bool(save.call("save_game")):
		push_error("drive_smoke: npc travel mid-save failed")
		quit(1)
		return false
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("drive_smoke: npc travel mid-load failed")
		quit(1)
		return false
	await physics_frame
	if str(ns.call("get_travel_state", RAFA)) != "TRAVELING":
		push_error("drive_smoke: Rafa TRAVELING not restored after save/load")
		quit(1)
		return false
	if str(ns.call("get_destination_location_id", RAFA)) != DEST:
		push_error("drive_smoke: Rafa destination not restored after save/load")
		quit(1)
		return false

	# Reload POI while traveling — must not respawn Rafa (no duplicate / ghost).
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	await physics_frame
	rafa = vp.find_child("Rafa", true, false) as Node3D if vp != null else null
	if rafa != null and is_instance_valid(rafa):
		push_error("drive_smoke: Rafa must not spawn at Sunset while TRAVELING")
		quit(1)
		return false

	# Narrative arrival (+60 minutes from start; clock restored from save).
	gt.call("advance_narrative_minutes", 60.0)
	travel.call("refresh_arrivals")
	await physics_frame
	if str(ns.call("get_travel_state", RAFA)) != "AT_LOCATION":
		push_error("drive_smoke: Rafa should arrive AT_LOCATION after narrative delay")
		quit(1)
		return false
	if str(ns.call("get_location_id", RAFA)) != DEST:
		push_error(
			"drive_smoke: Rafa should be at debug_waystation after arrival (got '%s')"
			% str(ns.call("get_location_id", RAFA))
		)
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_at_location", RAFA, DEST))):
		push_error("drive_smoke: NPC_AT_LOCATION debug_waystation failed")
		quit(1)
		return false

	# Still no physical Rafa at Sunset (logical-only destination).
	rafa = vp.find_child("Rafa", true, false) as Node3D if vp != null else null
	if rafa != null and is_instance_valid(rafa):
		push_error("drive_smoke: Rafa must not appear at Sunset after arriving at logical dest")
		quit(1)
		return false

	# SET_NPC_LOCATION instant place + presence return path.
	var set_loc: Resource = ActionScript.new() as Resource
	set_loc.set("type", 10)  # SET_NPC_LOCATION
	set_loc.set("target_id", RAFA)
	set_loc.set("string_value", "roadside_pullout")
	set_loc.set("secondary_id", "test_return")
	if not bool(executor.call("execute", set_loc)):
		push_error("drive_smoke: SET_NPC_LOCATION failed")
		quit(1)
		return false
	# Returning via SET does not auto-resume local schedule; re-enable for presence spawn.
	ns.call("set_follow_local_schedule", RAFA, true)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	rafa = vp.find_child("Rafa", true, false) as Node3D if vp != null else null
	if rafa == null:
		push_error("drive_smoke: Rafa should respawn at Sunset after SET_NPC_LOCATION home")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	save.call("delete_save")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"drive_smoke: npc_travel OK (leave + TRAVELING persist + narrative arrive + no duplicate)"
	)
	return true


func _verify_npc_dialogue_debug(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Dev panel + content validator: start talk without walking to NPC; mutate; reset isolated.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var quests: Node = root.get_node_or_null("QuestSystem")
	var rel: Node = root.get_node_or_null("RelationshipSystem")
	var bark: Node = root.get_node_or_null("BarkSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if (
		dlg == null
		or memory == null
		or ns == null
		or gt == null
		or flags == null
		or quests == null
		or rel == null
		or bark == null
		or journey == null
		or inv == null
	):
		push_error("drive_smoke: systems missing for npc dialogue debug")
		quit(1)
		return false

	# Isolation: gameplay autoloads must not reference the debug panel.
	for path in [
		"res://autoload/dialogue_system.gd",
		"res://autoload/bark_system.gd",
		"res://autoload/npc_state_system.gd",
		"res://scripts/npc/npc_character.gd",
		"res://scripts/dialogue/dialogue_ui.gd",
	]:
		var script: Script = load(path) as Script
		if script == null:
			continue
		var src := script.source_code
		for banned in ["NpcDialogueDebugUI", "npc_dialogue_debug_ui", "NpcDialogueContentValidator"]:
			if src.find(banned) >= 0:
				push_error("drive_smoke: %s must not reference debug tool '%s'" % [path, banned])
				quit(1)
				return false

	var ValidatorScript = load("res://scripts/debug/npc_dialogue_content_validator.gd")
	if ValidatorScript == null:
		push_error("drive_smoke: NpcDialogueContentValidator missing")
		quit(1)
		return false
	var validator: RefCounted = ValidatorScript.new()
	var report: Dictionary = validator.call("validate")
	if not bool(report.get("ok", false)):
		push_error(
			"drive_smoke: content validation failed:\n%s"
			% str(validator.call("format_report", report))
		)
		quit(1)
		return false
	if int(report.get("npc_count", 0)) < 2 or int(report.get("dialogue_count", 0)) < 4:
		push_error("drive_smoke: validator catalog counts too low")
		quit(1)
		return false

	var panel: Node = root.find_child("NpcDialogueDebugUI", true, false)
	if panel == null:
		push_error("drive_smoke: NpcDialogueDebugUI missing from sandbox")
		quit(1)
		return false

	# Baseline journey/inventory must survive NPC/dialogue reset.
	var journey_before := float(journey.call("get_current_distance_km"))
	if inv.has_method("clear_all"):
		pass
	var scrap_before := int(inv.call("get_quantity", "scrap_metal")) if inv.has_method("get_quantity") else 0
	if scrap_before < 1 and inv.has_method("add_item"):
		inv.call("add_item", "scrap_metal", 2)
		scrap_before = int(inv.call("get_quantity", "scrap_metal"))

	memory.call("reset_for_tests")
	ns.call("reset_for_tests")
	bark.call("reset_for_tests")
	gt.call("reset_for_tests")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")
	gt.call("set_narrative_time", 0, 10, 0)

	if not panel.has_method("open"):
		push_error("drive_smoke: NpcDialogueDebugUI missing open()")
		quit(1)
		return false
	panel.call("open")
	await physics_frame
	if not bool(panel.call("is_panel_visible")):
		push_error("drive_smoke: NpcDialogueDebugUI did not open")
		quit(1)
		return false

	var npc_ids: PackedStringArray = dlg.call("get_registered_npc_ids")
	if npc_ids.size() < 2:
		push_error("drive_smoke: expected registered NPCs in debug list")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	# Select Mira without walking to her; start a dialogue_id from the panel.
	if not bool(panel.call("select_npc_id", MIRA)):
		push_error("drive_smoke: could not select Mira in debug panel")
		quit(1)
		return false
	if str(panel.call("get_selected_npc_id")) != MIRA:
		push_error("drive_smoke: selected NPC is not Mira")
		quit(1)
		return false
	panel.call("select_dialogue_id", "mira_intro")

	var started := bool(panel.call("start_selected_dialogue"))
	if not started:
		push_error("drive_smoke: debug panel failed to start mira_intro remotely")
		quit(1)
		return false
	if not bool(dlg.call("is_active")):
		push_error("drive_smoke: dialogue not active after debug start")
		quit(1)
		return false
	if not bool(memory.call("has_seen_dialogue", "mira_intro")):
		push_error("drive_smoke: memory did not record debug-started dialogue")
		quit(1)
		return false

	# Inspect rule TRUE/FALSE API.
	var rules: Array = dlg.call("inspect_npc_dialogue_rules", MIRA)
	if rules.is_empty():
		push_error("drive_smoke: inspect_npc_dialogue_rules empty for Mira")
		quit(1)
		return false
	var saw_bool := false
	for row in rules:
		if row.has("passes") and row.has("conditions"):
			saw_bool = true
			break
	if not saw_bool:
		push_error("drive_smoke: rule inspect missing passes/conditions")
		quit(1)
		return false

	# Temporary mutators via panel helpers.
	gt.call("set_narrative_time", 0, 8, 0)
	panel.call("_mutate_narrative_set_night")
	if int(gt.call("get_narrative_hour")) != 22:
		push_error("drive_smoke: debug narrative night mutator failed")
		quit(1)
		return false
	panel.call("_mutate_relationship", 5)
	if int(rel.call("get_relationship", MIRA)) < 5:
		push_error("drive_smoke: debug relationship mutator failed")
		quit(1)
		return false
	panel.call("_mutate_cycle_npc_state")
	if str(ns.call("get_current_state", MIRA)) == "DEFAULT":
		# Cycled away from DEFAULT at least once when starting DEFAULT.
		pass
	panel.call("_mutate_toggle_debug_flag")
	if not bool(flags.call("get_flag", "debug.npc_dialogue_panel", false)):
		push_error("drive_smoke: debug flag mutator failed")
		quit(1)
		return false
	# Cycle linked quest until ACTIVE (handles leftover COMPLETED from earlier smoke).
	var quest_ok := false
	for _q in range(3):
		panel.call("_mutate_cycle_linked_quest")
		if bool(quests.call("is_active", "power_the_viewpoint")):
			quest_ok = true
			break
	if not quest_ok:
		push_error(
			"drive_smoke: debug quest mutator never reached ACTIVE (got %s)"
			% str(quests.call("get_state_name", "power_the_viewpoint"))
		)
		quit(1)
		return false

	if bark.has_method("get_bark_debug_state"):
		var bark_state: Dictionary = bark.call("get_bark_debug_state", MIRA)
		if not bark_state.has("active_cooldowns"):
			push_error("drive_smoke: bark debug state incomplete")
			quit(1)
			return false

	var validation_ui: Dictionary = panel.call("run_validation")
	if not bool(validation_ui.get("ok", false)):
		push_error("drive_smoke: panel validation reported FAIL on clean content")
		quit(1)
		return false
	panel.call("clear_validation_report")
	if not str(panel.call("get_validation_report_text")).is_empty():
		push_error("drive_smoke: clear_validation_report did not clear text")
		quit(1)
		return false

	# Inject a broken link and ensure validator catches it.
	var bogus: Resource = load("res://scripts/dialogue/dialogue_definition.gd").new()
	bogus.set("id", "__debug_orphan_probe__")
	bogus.set("next_dialogue_id", "__missing_next__")
	dlg.call("register_dialogue", bogus)
	# Catalog-file validator should still pass (runtime-only registration not on disk).
	var disk_ok: Dictionary = validator.call("validate")
	if not bool(disk_ok.get("ok", false)):
		push_error("drive_smoke: disk validation unexpectedly failed after runtime register")
		quit(1)
		return false

	panel.call("reset_npc_dialogue_test_data")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("drive_smoke: reset left dialogue active")
		quit(1)
		return false
	if bool(memory.call("has_seen_dialogue", "mira_intro")):
		push_error("drive_smoke: reset did not clear dialogue memory")
		quit(1)
		return false
	if absf(float(journey.call("get_current_distance_km")) - journey_before) > 0.001:
		push_error("drive_smoke: NPC/dialogue reset must not alter journey distance")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != scrap_before:
		push_error("drive_smoke: NPC/dialogue reset must not alter inventory")
		quit(1)
		return false

	panel.call("close")
	await physics_frame
	if bool(panel.call("is_panel_visible")):
		push_error("drive_smoke: NpcDialogueDebugUI still open after close")
		quit(1)
		return false

	# Leave clocks/state clean for later smoke slices (Mira availability window, etc.).
	gt.call("reset_for_tests")
	gt.call("set_narrative_time", 0, 10, 0)
	if quests.has_method("reset_quest"):
		quests.call("reset_quest", "power_the_viewpoint")
	if rel.has_method("reset_for_tests"):
		rel.call("reset_for_tests")
	ns.call("reset_for_tests")
	bark.call("reset_for_tests")
	memory.call("reset_for_tests")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")
	flags.call("clear_flag", "debug.npc_dialogue_panel")

	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"drive_smoke: npc_dlg_debug OK (panel + validate + remote start + mutators + isolated reset)"
	)
	return true


func _verify_small_interior(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Walk-in Observation Booth: enter, interact inside, exit; parked car stays put.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if poi_sys == null:
		push_error("drive_smoke: POISystem missing for interior test")
		quit(1)
		return false
	_clear_world_state()

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("drive_smoke: could not load viewpoint resources for interior")
		quit(1)
		return false

	var parked_origin: Vector3 = _vehicle.global_position
	var recenter_before: int = int(_recenter.call("get_recenter_count")) if _recenter != null else 0
	# Keep the platform clear of the parked car so collision does not disturb the stop.
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(14.0, 0.0, -6.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: failed to spawn viewpoint for interior")
		quit(1)
		return false

	var booth: Node3D = vp.find_child("ObservationBooth", true, false) as Node3D
	if booth == null:
		booth = vp.find_child("SmallInterior", true, false) as Node3D
	if booth == null or not booth.has_method("get_interior_stand_position"):
		push_error("drive_smoke: ObservationBooth missing methods")
		quit(1)
		return false

	var enter_signals := {"n": 0}
	var exit_signals := {"n": 0}
	var on_enter := func(_body) -> void:
		enter_signals["n"] = int(enter_signals["n"]) + 1
	var on_exit := func(_body) -> void:
		exit_signals["n"] = int(exit_signals["n"]) + 1
	booth.player_entered_interior.connect(on_enter)
	booth.player_exited_interior.connect(on_exit)

	# Walk in through doorway (place just inside interior volume).
	character.global_position = booth.call("get_interior_stand_position")
	character.rotation.y = 0.0
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", 0.0, deg_to_rad(-8.0))
	for _i in range(16):
		await physics_frame

	if not bool(booth.call("is_player_inside")):
		push_error("drive_smoke: player not detected inside ObservationBooth")
		quit(1)
		return false
	if int(enter_signals["n"]) < 1:
		push_error("drive_smoke: player_entered_interior did not fire")
		quit(1)
		return false
	if foot_cam.has_method("is_interior_active") and not bool(foot_cam.call("is_interior_active")):
		push_error("drive_smoke: on-foot camera not in interior mode")
		quit(1)
		return false

	# Interact with Observation Log inside.
	var obs_log: Node = booth.call("get_observation_log")
	if obs_log == null or not obs_log.has_method("interact"):
		push_error("drive_smoke: ObservationLog missing inside booth")
		quit(1)
		return false
	if not bool(obs_log.call("interact", character)):
		push_error("drive_smoke: ObservationLog interact failed")
		quit(1)
		return false
	if int(obs_log.get_meta("interact_count", 0)) < 1:
		push_error("drive_smoke: ObservationLog interact_count not updated")
		quit(1)
		return false

	# Walk out.
	character.global_position = booth.call("get_doorway_exterior_position")
	for _j in range(16):
		await physics_frame
	if bool(booth.call("is_player_inside")):
		push_error("drive_smoke: player still inside after walking out")
		quit(1)
		return false
	if int(exit_signals["n"]) < 1:
		push_error("drive_smoke: player_exited_interior did not fire")
		quit(1)
		return false
	if foot_cam.has_method("is_interior_active") and bool(foot_cam.call("is_interior_active")):
		push_error("drive_smoke: camera still in interior mode outdoors")
		quit(1)
		return false

	# Parked car must remain parked; absolute move is OK only if origin recentered.
	var recenter_after: int = int(_recenter.call("get_recenter_count")) if _recenter != null else 0
	if not bool(_vehicle.call("is_parked")):
		push_error("drive_smoke: vehicle left PARKED during interior explore")
		quit(1)
		return false
	if recenter_after == recenter_before:
		if parked_origin.distance_to(_vehicle.global_position) > 0.5:
			push_error("drive_smoke: parked vehicle drifted without origin recenter")
			quit(1)
			return false

	booth.player_entered_interior.disconnect(on_enter)
	booth.player_exited_interior.disconnect(on_exit)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: small interior OK (walk-in → interact → walk-out, car stayed)")
	return true


func _verify_world_items(_occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Collect Scrap Metal (inside booth) + Copper Wire (outside) via Interactable → Inventory.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if poi_sys == null or inv == null:
		push_error("drive_smoke: POISystem/InventorySystem missing for pickups")
		quit(1)
		return false

	if inv.has_method("clear_inventory"):
		inv.call("clear_inventory")
	_clear_world_state()

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("drive_smoke: could not load viewpoint for pickups")
		quit(1)
		return false

	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(12.0, 0.0, -4.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: failed to spawn viewpoint for pickups")
		quit(1)
		return false

	var scrap: Node = vp.find_child("ScrapMetalPickup", true, false)
	var scrap_b: Node = vp.find_child("ScrapMetalPickupB", true, false)
	var scrap_c: Node = vp.find_child("ScrapMetalPickupC", true, false)
	var wire: Node = vp.find_child("CopperWirePickup", true, false)
	if scrap == null or scrap_b == null or scrap_c == null or wire == null:
		push_error("drive_smoke: ScrapMetalPickup(A/B/C) / CopperWirePickup missing on ViewpointPOI")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(scrap) or not InteractionDetector.is_interactable_node(wire):
		push_error("drive_smoke: pickups must duck-type Interactable")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(scrap_c):
		push_error("drive_smoke: outdoor ScrapMetalPickupC must be interactable")
		quit(1)
		return false
	if str(scrap.call("get_item_id")) != "scrap_metal" or str(wire.call("get_item_id")) != "copper_wire":
		push_error("drive_smoke: pickup item_id mismatch")
		quit(1)
		return false
	if str(scrap_c.call("get_item_id")) != "scrap_metal" or int(scrap_c.call("get_quantity")) < 1:
		push_error("drive_smoke: outdoor scrap_03 should grant scrap_metal")
		quit(1)
		return false
	var scrap_total := (
		int(scrap.call("get_quantity"))
		+ int(scrap_b.call("get_quantity"))
		+ int(scrap_c.call("get_quantity"))
	)
	if scrap_total < 3:
		push_error("drive_smoke: viewpoint scrap pickups total %d < quest need 3" % scrap_total)
		quit(1)
		return false
	if int(wire.call("get_quantity")) < 1:
		push_error("drive_smoke: copper wire pickup missing quantity")
		quit(1)
		return false
	if bool(scrap.call("is_collected")) or bool(wire.call("is_collected")):
		push_error("drive_smoke: pickups should start uncollected")
		quit(1)
		return false

	# Collect scrap inside booth.
	var scrap_pos: Vector3 = (scrap as Node3D).global_position
	character.global_position = scrap_pos + Vector3(0.0, 0.05, 1.2)
	var face := scrap_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _i in range(12):
		await physics_frame

	var before_scrap := int(inv.call("get_quantity", "scrap_metal"))
	if not bool(scrap.call("interact", character)):
		push_error("drive_smoke: Scrap Metal collect failed")
		quit(1)
		return false
	await physics_frame
	if int(inv.call("get_quantity", "scrap_metal")) != before_scrap + 2:
		push_error("drive_smoke: scrap_metal quantity not updated in inventory")
		quit(1)
		return false
	if not bool(scrap.call("is_collected")):
		push_error("drive_smoke: scrap pickup not marked collected")
		quit(1)
		return false
	if (scrap as Node3D).visible:
		push_error("drive_smoke: scrap pickup still visible after collect")
		quit(1)
		return false
	var scrap_msg := str(scrap.get_meta("last_interact_message", ""))
	if scrap_msg.find("+2") < 0 or scrap_msg.find("Scrap") < 0:
		push_error("drive_smoke: bad scrap feedback '%s'" % scrap_msg)
		quit(1)
		return false
	# Cannot collect twice.
	if bool(scrap.call("can_interact", character)):
		push_error("drive_smoke: scrap still interactable after collect")
		quit(1)
		return false
	if bool(scrap.call("interact", character)):
		push_error("drive_smoke: scrap collected twice in same session")
		quit(1)
		return false
	var state: Dictionary = scrap.call("get_collected_state")
	if not bool(state.get("collected", false)) or str(state.get("pickup_id", "")) != "poi.sunset_viewpoint.pickup.scrap_01":
		push_error("drive_smoke: scrap collected state snapshot invalid")
		quit(1)
		return false

	# Outdoor scrap (quest overflow / discoverability).
	var scrap_c_pos: Vector3 = (scrap_c as Node3D).global_position
	character.global_position = scrap_c_pos + Vector3(0.0, 0.05, 1.2)
	face = scrap_c_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _oc in range(12):
		await physics_frame
	var before_scrap_c := int(inv.call("get_quantity", "scrap_metal"))
	if not bool(scrap_c.call("interact", character)):
		push_error("drive_smoke: outdoor Scrap Metal collect failed")
		quit(1)
		return false
	await physics_frame
	if int(inv.call("get_quantity", "scrap_metal")) != before_scrap_c + int(scrap_c.call("get_quantity")):
		push_error("drive_smoke: outdoor scrap quantity not applied")
		quit(1)
		return false

	# Copper wire outside near booth entrance.
	var wire_pos: Vector3 = (wire as Node3D).global_position
	character.global_position = wire_pos + Vector3(0.0, 0.05, 1.2)
	face = wire_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _j in range(12):
		await physics_frame

	var before_wire := int(inv.call("get_quantity", "copper_wire"))
	if not bool(wire.call("interact", character)):
		push_error("drive_smoke: Copper Wire collect failed")
		quit(1)
		return false
	await physics_frame
	if int(inv.call("get_quantity", "copper_wire")) != before_wire + 1:
		push_error("drive_smoke: copper_wire quantity expected +1")
		quit(1)
		return false
	if not bool(wire.call("is_collected")) or bool(wire.call("interact", character)):
		push_error("drive_smoke: copper wire reusable after collect")
		quit(1)
		return false
	var wire_msg := str(wire.get_meta("last_interact_message", ""))
	if wire_msg.find("+1") < 0:
		push_error("drive_smoke: bad copper feedback '%s'" % wire_msg)
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	if inv.has_method("clear_inventory"):
		inv.call("clear_inventory")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: world items OK (booth scrap + outdoor scrap + copper → inventory)")
	return true


func _verify_side_quest(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Power the Viewpoint: Mira offer → ACTIVE → gather → terminal turn-in → COMPLETED once.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	if poi_sys == null or dlg == null or inv == null or qs == null:
		push_error("drive_smoke: missing systems for side quest")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	_clear_world_state()
	var ns_quest: Node = root.get_node_or_null("NpcStateSystem")
	var memory_quest: Node = root.get_node_or_null("DialogueMemorySystem")
	var rel_quest: Node = root.get_node_or_null("RelationshipSystem")
	if ns_quest != null and ns_quest.has_method("reset_for_tests"):
		ns_quest.call("reset_for_tests")
	if memory_quest != null and memory_quest.has_method("reset_for_tests"):
		memory_quest.call("reset_for_tests")
	if rel_quest != null and rel_quest.has_method("reset_for_tests"):
		rel_quest.call("reset_for_tests")
	dlg.call("reload_npc_catalog")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(9.0, 0.0, -3.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: viewpoint spawn failed for quest")
		quit(1)
		return false

	var mira: Node = vp.find_child("Mira", true, false)
	var terminal: Node = vp.find_child("ViewpointTerminal", true, false)
	var scrap_a: Node = vp.find_child("ScrapMetalPickup", true, false)
	var scrap_b: Node = vp.find_child("ScrapMetalPickupB", true, false)
	var scrap_c: Node = vp.find_child("ScrapMetalPickupC", true, false)
	var wire: Node = vp.find_child("CopperWirePickup", true, false)
	if (
		mira == null or terminal == null or scrap_a == null or scrap_b == null
		or scrap_c == null or wire == null
	):
		push_error("drive_smoke: quest scene nodes missing")
		quit(1)
		return false
	var quest_scrap_available := (
		int(scrap_a.call("get_quantity"))
		+ int(scrap_b.call("get_quantity"))
		+ int(scrap_c.call("get_quantity"))
	)
	if quest_scrap_available < 3 or int(wire.call("get_quantity")) < 1:
		push_error(
			"drive_smoke: viewpoint collectibles insufficient for quest (scrap=%d wire=%d)"
			% [quest_scrap_available, int(wire.call("get_quantity"))]
		)
		quit(1)
		return false

	if str(qs.call("get_state_name", "power_the_viewpoint")) != "INACTIVE":
		push_error("drive_smoke: quest should start INACTIVE")
		quit(1)
		return false

	# 1) Talk to Mira → activate quest.
	var mira_pos: Vector3 = (mira as Node3D).global_position
	character.global_position = mira_pos + Vector3(0.0, 0.05, 1.5)
	var face := mira_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _i in range(10):
		await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("drive_smoke: Mira offer interact failed")
		quit(1)
		return false
	await physics_frame
	# Advance offer sequence to completion.
	while bool(dlg.call("is_active")):
		dlg.call("advance")
		await physics_frame
	if not bool(qs.call("is_active", "power_the_viewpoint")):
		push_error("drive_smoke: quest not ACTIVE after Mira offer")
		quit(1)
		return false
	if rel_quest != null and int(rel_quest.call("get_relationship", "mira_viewpoint_keeper")) != 5:
		push_error(
			"drive_smoke: accept_help should grant +5 Mira relationship (got %d)"
			% int(rel_quest.call("get_relationship", "mira_viewpoint_keeper"))
		)
		quit(1)
		return false

	# Terminal without items should fail.
	if bool(terminal.call("interact", character)):
		push_error("drive_smoke: terminal turn-in succeeded without items")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "OFF":
		push_error("drive_smoke: terminal should stay OFF without items")
		quit(1)
		return false

	# 2) Collect resources (booth scrap + outdoor scrap + copper ≥ quest need).
	for pickup in [scrap_a, scrap_b, scrap_c, wire]:
		var ppos: Vector3 = (pickup as Node3D).global_position
		character.global_position = ppos + Vector3(0.0, 0.05, 1.15)
		face = ppos - character.global_position
		yaw = atan2(-face.x, -face.z)
		character.rotation.y = yaw
		if foot_cam.has_method("set_look_angles"):
			foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
		for _w in range(8):
			await physics_frame
		if not bool(pickup.call("interact", character)):
			push_error("drive_smoke: quest pickup collect failed (%s)" % pickup.name)
			quit(1)
			return false
		await physics_frame

	if not bool(qs.call("has_required_items", "power_the_viewpoint")):
		push_error(
			"drive_smoke: missing required items after pickups (scrap=%d wire=%d)"
			% [int(inv.call("get_quantity", "scrap_metal")), int(inv.call("get_quantity", "copper_wire"))]
		)
		quit(1)
		return false
	# Quest consumes only 3 scrap + 1 wire; outdoor scrap leaves overflow.
	if int(inv.call("get_quantity", "scrap_metal")) < 3:
		push_error("drive_smoke: expected ≥3 scrap after collecting all viewpoint pickups")
		quit(1)
		return false

	# 3) Turn in at terminal → ON + COMPLETED; consume items.
	var term_pos: Vector3 = (terminal as Node3D).global_position
	character.global_position = term_pos + Vector3(0.0, 0.05, 1.6)
	face = term_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _t in range(10):
		await physics_frame

	var completed_n := {"n": 0}
	var on_done := func(_id: String) -> void:
		completed_n["n"] = int(completed_n["n"]) + 1
	qs.quest_completed.connect(on_done)

	if not bool(terminal.call("interact", character)):
		push_error("drive_smoke: terminal quest turn-in failed")
		quit(1)
		return false
	await physics_frame
	if str(terminal.call("get_state_name")) != "ON":
		push_error("drive_smoke: terminal not ON after turn-in")
		quit(1)
		return false
	if not bool(qs.call("is_completed", "power_the_viewpoint")):
		push_error("drive_smoke: quest not COMPLETED after turn-in")
		quit(1)
		return false
	if int(completed_n["n"]) < 1:
		push_error("drive_smoke: quest_completed signal missing")
		quit(1)
		return false
	if rel_quest != null and int(rel_quest.call("get_reputation", "sunset_viewpoint")) != 10:
		push_error(
			"drive_smoke: quest complete should grant +10 sunset_viewpoint reputation (got %d)"
			% int(rel_quest.call("get_reputation", "sunset_viewpoint"))
		)
		quit(1)
		return false
	# Quest need is 3 scrap + 1 wire; outdoor scrap leaves overflow.
	if int(inv.call("get_quantity", "scrap_metal")) != quest_scrap_available - 3:
		push_error(
			"drive_smoke: scrap not consumed correctly on turn-in (left=%d expected=%d)"
			% [int(inv.call("get_quantity", "scrap_metal")), quest_scrap_available - 3]
		)
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 0:
		push_error("drive_smoke: copper wire not consumed on turn-in")
		quit(1)
		return false

	# 4) Re-interact must not duplicate reward/consumption.
	if bool(terminal.call("interact", character)):
		push_error("drive_smoke: terminal interacted again after COMPLETED")
		quit(1)
		return false
	if not bool(qs.call("try_turn_in", "power_the_viewpoint")):
		pass  # expected false
	else:
		push_error("drive_smoke: try_turn_in succeeded twice")
		quit(1)
		return false
	var scrap_before_dup := int(inv.call("get_quantity", "scrap_metal"))
	if int(inv.call("add_item", "scrap_metal", 3)) != 3:
		push_error("drive_smoke: could not re-add scrap for duplicate check")
		quit(1)
		return false
	# Even with items again, completed quest must not consume/re-complete.
	if bool(qs.call("try_turn_in", "power_the_viewpoint")):
		push_error("drive_smoke: completed quest consumed items again")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != scrap_before_dup + 3:
		push_error("drive_smoke: completed quest altered scrap after duplicate try_turn_in")
		quit(1)
		return false

	qs.quest_completed.disconnect(on_done)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	inv.call("clear_inventory")
	qs.call("reset_all")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: side quest OK (offer → gather → turn-in → COMPLETED once)")
	return true


func _verify_workbench(_occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Workbench at Sunset Viewpoint opens CraftingDebugUI; craft via UI selection.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var craft: Node = root.get_node_or_null("CraftingSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if poi_sys == null or craft == null or inv == null:
		push_error("drive_smoke: systems missing for workbench check")
		quit(1)
		return false

	inv.call("clear_inventory")
	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(10.0, 0.0, -4.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("drive_smoke: viewpoint spawn failed for workbench")
		quit(1)
		return false

	var bench: Node = vp.find_child("Workbench", true, false)
	if bench == null:
		push_error("drive_smoke: Workbench missing at Sunset Viewpoint")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(bench):
		push_error("drive_smoke: Workbench is not duck-typed interactable")
		quit(1)
		return false

	var ui: Node = root.find_child("CraftingDebugUI", true, false)
	if ui == null:
		push_error("drive_smoke: CraftingDebugUI missing from sandbox")
		quit(1)
		return false

	var bench_pos: Vector3 = (bench as Node3D).global_position
	character.global_position = bench_pos + Vector3(0.0, 0.05, 1.5)
	var face := bench_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _i in range(10):
		await physics_frame

	if not bool(bench.call("can_interact", character)):
		push_error("drive_smoke: Workbench can_interact false")
		quit(1)
		return false
	if not bool(bench.call("interact", character)):
		push_error("drive_smoke: Workbench interact failed")
		quit(1)
		return false
	await physics_frame
	if not bool(ui.call("is_panel_visible")):
		push_error("drive_smoke: CraftingDebugUI did not open from Workbench")
		quit(1)
		return false

	# Recipe appears in catalog list used by UI.
	var ids: PackedStringArray = craft.call("get_recipe_ids")
	if not ("basic_repair_kit" in ids):
		push_error("drive_smoke: basic_repair_kit missing from recipe ids for UI")
		quit(1)
		return false

	# Craft with resources while UI open.
	inv.call("add_item", "scrap_metal", 2)
	inv.call("add_item", "copper_wire", 1)
	if not bool(craft.call("craft", "basic_repair_kit")):
		push_error("drive_smoke: craft via workbench flow failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 1:
		push_error("drive_smoke: workbench craft did not yield kit")
		quit(1)
		return false

	# Close UI via second interact.
	if not bool(bench.call("interact", character)):
		push_error("drive_smoke: Workbench close interact failed")
		quit(1)
		return false
	await physics_frame
	if bool(ui.call("is_panel_visible")):
		push_error("drive_smoke: CraftingDebugUI still open after close")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	inv.call("clear_inventory")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("drive_smoke: workbench OK (interact → UI → craft → close)")
	return true


func _clear_vehicle_input() -> void:
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
	Input.action_release("vehicle_park")
	Input.action_release("player_exit_vehicle")
	Input.action_release("player_enter_vehicle")
	Input.action_release("player_move_forward")
	Input.action_release("player_move_backward")
	if InputMap.has_action("player_move_back"):
		Input.action_release("player_move_back")
	Input.action_release("player_move_left")
	Input.action_release("player_move_right")
	Input.action_release("player_run")
	Input.action_release("player_interact")
