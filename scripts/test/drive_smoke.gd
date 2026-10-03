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

	if not await _verify_enter_exit_vehicle():
		return

	var counts: Dictionary = _road_manager.call("get_active_kind_counts")
	var elev_counts: Dictionary = _road_manager.call("get_active_elevation_counts")
	print(
		"drive_smoke: OK elapsed=%.1fs TRAVEL_MODE cruise_mean=%.2f span=%.2f max_|lat|=%.2f recenters=%d recycles=%d journey=%.3f kinds=%s elev=%s y_span=%.2f scenery_props=%d active=%d nodes=%d cams=%s cine_swaps=%d cine_modes=%s exit_nodes=%d exit_active=%s poi=SunsetViewpoint cancel=MANUAL parking=OK occupancy=OK onfoot=OK interact=OK viewpoint_terminal=OK npc=OK dialogue=OK inventory=OK crafting=OK save=OK world_state=OK interior=OK pickups=OK quest=OK"
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
		for banned in ["ViewpointTerminal", "WorldItem", "city", "City"]:
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
	if poi_sys == null:
		push_error("drive_smoke: POISystem missing for dialogue test")
		quit(1)
		return false
	if dlg == null:
		push_error("drive_smoke: DialogueSystem autoload missing")
		quit(1)
		return false
	_clear_world_state()

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
	if str(mira.call("get_dialogue_id")) != "mira_quest_offer_01":
		push_error("drive_smoke: Mira dialogue_id should be mira_quest_offer_01")
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
	if str(dlg.call("get_current_id")) != "mira_quest_offer_01":
		push_error("drive_smoke: expected mira_quest_offer_01, got %s" % str(dlg.call("get_current_id")))
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("terminal") < 0:
		push_error("drive_smoke: unexpected Mira offer line 1 text")
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

	# --- Rafa reuses the same DialogueSystem ---
	var rafa_pos: Vector3 = (rafa as Node3D).global_position
	character.global_position = rafa_pos + Vector3(0.0, 0.05, 1.6)
	face = rafa_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _j in range(10):
		await physics_frame

	if not bool(rafa.call("interact", character)):
		push_error("drive_smoke: Rafa interact failed")
		quit(1)
		return false
	await physics_frame
	if not bool(dlg.call("is_active")) or str(dlg.call("get_current_id")) != "rafa_01":
		push_error("drive_smoke: Rafa did not open rafa_01")
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
	var wire: Node = vp.find_child("CopperWirePickup", true, false)
	if scrap == null or wire == null:
		push_error("drive_smoke: ScrapMetalPickup / CopperWirePickup missing on ViewpointPOI")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(scrap) or not InteractionDetector.is_interactable_node(wire):
		push_error("drive_smoke: pickups must duck-type Interactable")
		quit(1)
		return false
	if str(scrap.call("get_item_id")) != "scrap_metal" or str(wire.call("get_item_id")) != "copper_wire":
		push_error("drive_smoke: pickup item_id mismatch")
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

	# Copper wire outside (quantity 2).
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
	print("drive_smoke: world items OK (scrap + copper → inventory, no double-collect)")
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
	var wire: Node = vp.find_child("CopperWirePickup", true, false)
	if mira == null or terminal == null or scrap_a == null or scrap_b == null or wire == null:
		push_error("drive_smoke: quest scene nodes missing")
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

	# Terminal without items should fail.
	if bool(terminal.call("interact", character)):
		push_error("drive_smoke: terminal turn-in succeeded without items")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "OFF":
		push_error("drive_smoke: terminal should stay OFF without items")
		quit(1)
		return false

	# 2) Collect resources (3 scrap + 1 copper).
	for pickup in [scrap_a, scrap_b, wire]:
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
	if int(inv.call("get_quantity", "scrap_metal")) != 0 or int(inv.call("get_quantity", "copper_wire")) != 0:
		push_error("drive_smoke: resources not consumed on turn-in")
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
	if int(inv.call("add_item", "scrap_metal", 3)) != 3:
		push_error("drive_smoke: could not re-add scrap for duplicate check")
		quit(1)
		return false
	# Even with items again, completed quest must not consume/re-complete.
	if bool(qs.call("try_turn_in", "power_the_viewpoint")):
		push_error("drive_smoke: completed quest consumed items again")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 3:
		push_error("drive_smoke: duplicate turn-in changed inventory")
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
