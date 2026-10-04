extends "res://scripts/test/test_helpers.gd"
## Vehicle smoke: Travel Mode drive, parking, state/fuel/upgrades, enter/exit, interaction.
## Run: godot --path . --headless -s res://scripts/test/vehicle_smoke.gd

const PHASE_ACCEL := 0
const PHASE_ENGAGE_TRAVEL := 1
const PHASE_HOLD_SETTLE := 2
const PHASE_HOLD_SAMPLE := 3
const PHASE_LONG_DRIVE := 4
const PHASE_DONE := 5

const HOLD_SETTLE_SEC := 3.0
const HOLD_SAMPLE_SEC := 6.0
const LONG_DRIVE_TOTAL_SEC := 90.0

var _phase: int = PHASE_ACCEL
var _phase_time: float = 0.0
var _elapsed: float = 0.0
var _samples: int = 0
var _camera_follow_ok: bool = false
var _camera_modes_ok: bool = false
var _camera_mode_names: PackedStringArray = []
var _saw_speed_kmh: bool = false
var _max_speed_kmh: float = 0.0
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
var _initial_exit_nodes: int = 0
var _max_exit_nodes: int = 0
var _saw_exit_active: bool = false
var _exit_active_during_travel: bool = false
var _poi_reach_ok: bool = false

func _initialize() -> void:
	suite_name = "vehicle_smoke"
	start_suite_timeout(360.0)
	if not load_sandbox():
		return
	create_timer(0.5).timeout.connect(_begin)


func _begin() -> void:
	if not resolve_sandbox_nodes(true):
		return
	await await_physics_frames(30)
	_initial_pool_count = int(_road_manager.call("get_pool_node_count"))
	_max_pool_count = _initial_pool_count
	if _scenery.has_method("get_total_prop_count"):
		_initial_scenery_props = int(_scenery.call("get_total_prop_count"))
	if _scenery.has_method("get_node_budget"):
		_initial_scenery_nodes = int(_scenery.call("get_node_budget"))
		_max_scenery_nodes = _initial_scenery_nodes
	if _initial_scenery_props < 8:
		fail("scenery pool too small (%d)" % _initial_scenery_props)
		return
	_journey.call("reset_journey")
	# Match monolithic smoke: snapshot exit budget after viewpoint unload baseline.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if poi_sys != null and poi_sys.has_method("despawn_viewpoint"):
		poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
		await await_physics_frames(4)
	if _exit_system.has_method("get_total_node_budget"):
		_initial_exit_nodes = int(_exit_system.call("get_total_node_budget"))
		_max_exit_nodes = _initial_exit_nodes
	if _initial_exit_nodes < 4:
		fail("exit/detour pool too small (%d)" % _initial_exit_nodes)
		return
	# Exit activity is observed during the long drive via _track_exits.
	# POI reach coverage lives in journey_world_smoke.
	_poi_reach_ok = true
	if _vehicle.has_method("get_cruise_target_speed_ms"):
		_cruise_target_ms = float(_vehicle.call("get_cruise_target_speed_ms"))
	_set_phase(PHASE_ACCEL)
	physics_frame.connect(_on_physics_frame)


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
			_after_travel()


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
				push_error("vehicle_smoke: scenery on roadway lat=%.2f at %s" % [lat, (child as Node3D).global_position])
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
				push_error("vehicle_smoke: scenery pool grew/shrank (%d → %d)" % [_initial_scenery_props, total_props])
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
		push_error("vehicle_smoke: unstable pos=%s" % pos)
		quit(1)
		return
	if _has_road_sample and pos.y < _last_road_y - 2.5:
		push_error("vehicle_smoke: fell through road pos=%s road_y=%.2f" % [pos, _last_road_y])
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


func _finish_travel() -> bool:
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
		push_error("vehicle_smoke: expected TRAVEL_MODE, got %s" % mode_name)
		quit(1)
		return false

	if not bool(_vehicle.call("is_travel_mode")):
		push_error("vehicle_smoke: vehicle.is_travel_mode false")
		quit(1)
		return false

	if not bool(_autopilot.call("is_autopilot_active")):
		push_error("vehicle_smoke: autopilot inactive under Travel Mode")
		quit(1)
		return false

	if not bool(_vehicle.call("is_cruise_control_active")):
		push_error("vehicle_smoke: cruise inactive under Travel Mode")
		quit(1)
		return false

	if _cruise_speed_count < 60:
		push_error("vehicle_smoke: not enough cruise samples")
		quit(1)
		return false

	var mean_speed := _cruise_speed_sum / float(_cruise_speed_count)
	var speed_span := _cruise_speed_max - _cruise_speed_min
	if absf(mean_speed - _cruise_target_ms) > 1.25:
		push_error("vehicle_smoke: cruise mean off target (%.2f vs %.2f)" % [mean_speed, _cruise_target_ms])
		quit(1)
		return false
	if speed_span > 2.5:
		push_error("vehicle_smoke: cruise oscillation too high (span=%.2f)" % speed_span)
		quit(1)
		return false

	# Lane-keeping uses centerline lateral (world X is not meaningful once curves appear).
	if _sample_abs_lateral_max > 2.5 or _max_abs_lateral > 3.5:
		push_error(
			"vehicle_smoke: left lane center too far (sample|lat|=%.2f max|lat|=%.2f)"
			% [_sample_abs_lateral_max, _max_abs_lateral]
		)
		quit(1)
		return false

	if not _camera_follow_ok or not _saw_speed_kmh:
		push_error("vehicle_smoke: camera/speed checks failed")
		quit(1)
		return false

	if not _camera_modes_ok:
		push_error("vehicle_smoke: camera mode cycle failed (%s)" % [_camera_mode_names])
		quit(1)
		return false

	if _camera_rig.has_method("get_mode_name") and str(_camera_rig.call("get_mode_name")) != "FOLLOW":
		# Cinematic may have left a non-FOLLOW mode; that is fine after cancel.
		pass

	if not _cinematic_ok or not _cinematic_started:
		push_error("vehicle_smoke: cinematic failed to activate under Travel Mode")
		quit(1)
		return false

	if _cinematic_swap_count < 2 or _cinematic_modes_seen.size() < 2:
		push_error(
			"vehicle_smoke: cinematic swaps insufficient (swaps=%d modes=%s)"
			% [_cinematic_swap_count, ",".join(_cinematic_modes_seen)]
		)
		quit(1)
		return false

	if not _cinematic_cancel_ok:
		push_error("vehicle_smoke: cinematic cancel failed")
		quit(1)
		return false

	if not _autopilot_ok_during_cine:
		push_error("vehicle_smoke: autopilot disrupted by cinematic camera")
		quit(1)
		return false

	# Curves + elevation reduce net planar drift vs pure -Z; still require recentering.
	if recycles < 5 or recenters < 1:
		push_error("vehicle_smoke: recycle/recenter counts too low (r=%d c=%d)" % [recycles, recenters])
		quit(1)
		return false

	if planar >= recenter_distance or pool_final != _initial_pool_count or _max_pool_count != _initial_pool_count:
		push_error("vehicle_smoke: recenter/pool invariant failed")
		quit(1)
		return false

	if not _saw_active_scenery:
		push_error("vehicle_smoke: no active roadside scenery observed")
		quit(1)
		return false

	var scenery_props_final := int(_scenery.call("get_total_prop_count"))
	var scenery_nodes_final := int(_scenery.call("get_node_budget"))
	if scenery_props_final != _initial_scenery_props:
		push_error("vehicle_smoke: scenery prop pool changed (%d → %d)" % [_initial_scenery_props, scenery_props_final])
		quit(1)
		return false
	if scenery_nodes_final > _initial_scenery_nodes:
		push_error("vehicle_smoke: scenery nodes grew (%d → %d)" % [_initial_scenery_nodes, scenery_nodes_final])
		quit(1)
		return false
	if _max_scenery_nodes > _initial_scenery_nodes:
		push_error("vehicle_smoke: scenery node budget grew during run")
		quit(1)
		return false

	if _journey_mid < 0.0 or journey_km <= _journey_mid:
		push_error("vehicle_smoke: journey did not keep increasing")
		quit(1)
		return false

	if not _saw_straight or not _saw_gentle_left or not _saw_gentle_right:
		push_error(
			"vehicle_smoke: missing segment kinds (straight=%s left=%s right=%s)"
			% [_saw_straight, _saw_gentle_left, _saw_gentle_right]
		)
		quit(1)
		return false

	if not _saw_level or not _saw_climb or not _saw_descent:
		push_error(
			"vehicle_smoke: missing elevation (level=%s climb=%s descent=%s)"
			% [_saw_level, _saw_climb, _saw_descent]
		)
		quit(1)
		return false

	var elev_span := _max_vehicle_y - _min_vehicle_y
	if elev_span < 1.0:
		push_error("vehicle_smoke: elevation span too small (%.2f)" % elev_span)
		quit(1)
		return false

	# Immediate cancel path: Travel Mode → MANUAL via API.
	_mode_controller.call("set_mode", MODE_MANUAL)
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error("vehicle_smoke: cancel did not return to MANUAL")
		quit(1)
		return false
	if bool(_autopilot.call("is_autopilot_active")):
		push_error("vehicle_smoke: autopilot still active after cancel")
		quit(1)
		return false
	if bool(_vehicle.call("is_cruise_control_active")):
		push_error("vehicle_smoke: cruise still active after cancel")
		quit(1)
		return false

	# Leaving Travel Mode must also clear cinematic if somehow still on.
	if _camera_rig.has_method("is_cinematic_active") and bool(_camera_rig.call("is_cinematic_active")):
		# Process may need a frame; force cancel then assert.
		_camera_rig.call("set_cinematic_active", false)
		if bool(_camera_rig.call("is_cinematic_active")):
			push_error("vehicle_smoke: cinematic still active after Travel cancel")
			quit(1)
			return false

	if not _saw_exit_active:
		push_error("vehicle_smoke: Sunset Viewpoint exit never activated")
		quit(1)
		return false

	if _max_exit_nodes > _initial_exit_nodes:
		push_error(
			"vehicle_smoke: exit/detour nodes grew (%d → %d)"
			% [_initial_exit_nodes, _max_exit_nodes]
		)
		quit(1)
		return false

	var exit_nodes_final := int(_exit_system.call("get_total_node_budget"))
	if exit_nodes_final != _initial_exit_nodes:
		push_error(
			"vehicle_smoke: exit node budget changed (%d → %d)"
			% [_initial_exit_nodes, exit_nodes_final]
		)
		quit(1)
		return false

	# Travel Mode stayed on main road (low lateral) even while an exit existed nearby.
	if _exit_active_during_travel and _max_abs_lateral > 3.5:
		push_error(
			"vehicle_smoke: Travel Mode drifted toward exit (max|lat|=%.2f)" % _max_abs_lateral
		)
		quit(1)
		return false

	# POI reach asserted in journey_world_smoke (not this suite).

	var counts: Dictionary = _road_manager.call("get_active_kind_counts")
	var elev_counts: Dictionary = _road_manager.call("get_active_elevation_counts")
	print(
		"vehicle_smoke: travel OK elapsed=%.1fs TRAVEL_MODE cruise_mean=%.2f span=%.2f max_|lat|=%.2f recenters=%d recycles=%d journey=%.3f kinds=%s elev=%s y_span=%.2f scenery_props=%d active=%d nodes=%d cams=%s cine_swaps=%d cine_modes=%s exit_nodes=%d exit_active=%s cancel=MANUAL"
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
	# Travel segment OK — domain verifies continue in _run_post_travel.
	return true



func _run_post_travel() -> void:
	if not await _verify_parking_state():
		return
	if not _verify_vehicle_state_system():
		return
	if not await _verify_vehicle_fuel_system():
		return
	if not _verify_vehicle_upgrade_loop():
		return
	if not await _verify_enter_exit_vehicle():
		return
	# Re-exit for interaction checks (enter/exit left us IN_VEHICLE).
	var foot := await park_and_exit_to_foot()
	if not bool(foot.get("ok", false)):
		return
	if not await _verify_interaction_system(foot["occupancy"], foot["character"], foot["foot_cam"]):
		return
	pass_suite(
		"travel+parking+vehicle_state+fuel+upgrade+enter_exit+interact"
	)

func _verify_parking_state() -> bool:
	## Explicit MotionState: reject park at speed; park cancels cruise/travel; stay still; unpark.
	if not _vehicle.has_method("try_park") or not _vehicle.has_method("try_unpark"):
		push_error("vehicle_smoke: parking API missing on PlayerVehicle")
		quit(1)
		return false

	clear_vehicle_input()
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
		push_error("vehicle_smoke: could not reach above max_parking_speed")
		quit(1)
		return false

	var high_speed: float = absf(float(_vehicle.call("get_signed_speed")))
	if bool(_vehicle.call("try_park")):
		push_error(
			"vehicle_smoke: park allowed at high speed (%.2f m/s)" % high_speed
		)
		quit(1)
		return false
	if str(_vehicle.call("get_motion_state_name")) != "DRIVING":
		push_error("vehicle_smoke: expected DRIVING after rejected park")
		quit(1)
		return false

	# --- Slow to a stop on valid surface ---
	Input.action_press("vehicle_brake")
	for _j in range(240):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= 0.05 and _vehicle.is_on_floor():
			break
	Input.action_release("vehicle_brake")
	clear_vehicle_input()

	# Coast a few frames so brake cancel does not fight us.
	for _k in range(10):
		await physics_frame

	if absf(float(_vehicle.call("get_signed_speed"))) > float(_vehicle.get("max_parking_speed")):
		push_error("vehicle_smoke: could not slow below max_parking_speed before park")
		quit(1)
		return false
	if not _vehicle.is_on_floor():
		push_error("vehicle_smoke: not on valid surface before park")
		quit(1)
		return false

	# --- Engage Travel Mode then park: assisted modes must cancel ---
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) != "TRAVEL_MODE":
		push_error("vehicle_smoke: failed to engage TRAVEL_MODE before park")
		quit(1)
		return false

	var park_signals := {"n": 0}
	var on_park := func(_prev, _cur) -> void:
		park_signals["n"] = int(park_signals["n"]) + 1
	_vehicle.parking_state_changed.connect(on_park)

	if not bool(_vehicle.call("try_park")):
		push_error("vehicle_smoke: try_park failed while slow on floor")
		quit(1)
		return false

	await physics_frame
	if str(_vehicle.call("get_motion_state_name")) != "PARKED":
		push_error("vehicle_smoke: motion state not PARKED after park")
		quit(1)
		return false
	if not bool(_vehicle.call("is_parked")):
		push_error("vehicle_smoke: is_parked false after park")
		quit(1)
		return false
	if absf(float(_vehicle.call("get_signed_speed"))) > 0.01:
		push_error("vehicle_smoke: speed not zero after park")
		quit(1)
		return false
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error(
			"vehicle_smoke: mode still %s after park (expected MANUAL)"
			% str(_mode_controller.call("get_mode_name"))
		)
		quit(1)
		return false
	if bool(_vehicle.call("is_cruise_control_active")):
		push_error("vehicle_smoke: cruise still active while PARKED")
		quit(1)
		return false
	if bool(_vehicle.call("is_travel_mode")):
		push_error("vehicle_smoke: travel mode still active while PARKED")
		quit(1)
		return false
	if bool(_autopilot.call("is_autopilot_active")):
		push_error("vehicle_smoke: autopilot still active while PARKED")
		quit(1)
		return false
	if int(park_signals["n"]) < 1:
		push_error("vehicle_smoke: parking_state_changed did not fire on park")
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
		push_error("vehicle_smoke: parked vehicle gained speed under accel")
		quit(1)
		return false
	var drift: float = parked_origin.distance_to(_vehicle.global_position)
	if drift > 0.35:
		push_error("vehicle_smoke: parked vehicle drifted (%.2f m)" % drift)
		quit(1)
		return false

	# Cruise/travel toggles while parked must not stick.
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error("vehicle_smoke: TRAVEL_MODE engaged while PARKED")
		quit(1)
		return false
	_mode_controller.call("set_mode", 1)  # CRUISE
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) != "MANUAL":
		push_error("vehicle_smoke: CRUISE engaged while PARKED")
		quit(1)
		return false

	# --- Unpark → DRIVING; controls return ---
	if not bool(_vehicle.call("try_unpark")):
		push_error("vehicle_smoke: try_unpark failed")
		quit(1)
		return false
	await physics_frame
	if str(_vehicle.call("get_motion_state_name")) != "DRIVING":
		push_error("vehicle_smoke: expected DRIVING after unpark")
		quit(1)
		return false
	if bool(_vehicle.call("is_parked")):
		push_error("vehicle_smoke: is_parked true after unpark")
		quit(1)
		return false
	if int(park_signals["n"]) < 2:
		push_error("vehicle_smoke: parking_state_changed did not fire on unpark")
		quit(1)
		return false

	_vehicle.parking_state_changed.disconnect(on_park)
	clear_vehicle_input()
	print("vehicle_smoke: parking state OK (reject@speed → PARKED cancels assist → unpark DRIVING)")
	return true


func _verify_vehicle_state_system() -> bool:
	## VehicleStateSystem: persistent attrs survive save/load; PlayerVehicle uses effective max.
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if vs == null or save == null or _vehicle == null:
		push_error("vehicle_smoke: VehicleStateSystem/SaveSystem/PlayerVehicle missing")
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
			push_error("vehicle_smoke: VehicleStateSystem missing %s" % required)
			quit(1)
			return false

	# No physics fields in persistence payload.
	var vs_script: Script = load("res://autoload/vehicle_state_system.gd") as Script
	if vs_script != null:
		var src := vs_script.source_code
		for banned in ["velocity", "transform", "global_position", "CharacterBody3D"]:
			if src.find(banned) >= 0:
				push_error("vehicle_smoke: VehicleStateSystem must not store physics field '%s'" % banned)
				quit(1)
				return false

	vs.call("reset_for_tests")
	if str(vs.call("get_vehicle_id")) != "starter_car":
		push_error("vehicle_smoke: default vehicle_id should be starter_car")
		quit(1)
		return false

	var base_kmh := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(base_kmh, 86.4):
		push_error("vehicle_smoke: starter effective max expected 86.4 km/h got %.2f" % base_kmh)
		quit(1)
		return false

	# PlayerVehicle must consult VehicleState for the cap.
	if not _vehicle.has_method("get_effective_max_speed_ms"):
		push_error("vehicle_smoke: PlayerVehicle missing get_effective_max_speed_ms")
		quit(1)
		return false
	var vehicle_ms := float(_vehicle.call("get_effective_max_speed_ms"))
	var expected_ms := base_kmh / 3.6
	if not is_equal_approx(vehicle_ms, expected_ms):
		push_error(
			"vehicle_smoke: PlayerVehicle max_ms %.3f != VehicleState %.3f"
			% [vehicle_ms, expected_ms]
		)
		quit(1)
		return false

	# Modifier changes effective speed and is reflected by the vehicle.
	vs.call("set_cruise_speed_modifier", 1.25)
	var boosted := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(boosted, 86.4 * 1.25):
		push_error("vehicle_smoke: cruise_speed_modifier not applied to effective max")
		quit(1)
		return false
	if not is_equal_approx(float(_vehicle.call("get_effective_max_speed_ms")), boosted / 3.6):
		push_error("vehicle_smoke: PlayerVehicle did not pick up boosted VehicleState max")
		quit(1)
		return false

	# Upgrade API — ids only, persist later.
	if not bool(vs.call("install_upgrade", "engine_tune_1")):
		push_error("vehicle_smoke: install_upgrade failed")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", "engine_tune_1")):
		push_error("vehicle_smoke: has_upgrade false after install")
		quit(1)
		return false
	if bool(vs.call("install_upgrade", "engine_tune_1")):
		push_error("vehicle_smoke: duplicate install_upgrade should fail")
		quit(1)
		return false
	vs.call("install_upgrade", "cargo_rack_1")
	vs.call("set_fuel_current", 42.5)
	vs.call("set_condition_current", 77.0)

	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("vehicle_smoke: save_game failed in vehicle_state test")
		quit(1)
		return false

	var path := str(save.call("get_save_path"))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("vehicle_smoke: vehicle_state save JSON parse failed")
		quit(1)
		return false
	var systems: Dictionary = parsed.get("systems", {})
	if not systems.has("vehicle_state"):
		push_error("vehicle_smoke: systems.vehicle_state missing")
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
			push_error("vehicle_smoke: vehicle_state save missing '%s'" % key)
			quit(1)
			return false
	# Must not persist runtime physics.
	for banned in ["velocity", "transform", "position", "rotation", "speed"]:
		if payload.has(banned):
			push_error("vehicle_smoke: vehicle_state must not persist '%s'" % banned)
			quit(1)
			return false

	var upgrades_saved: Array = payload.get("installed_upgrades", [])
	if upgrades_saved.size() != 2:
		push_error("vehicle_smoke: expected 2 upgrades in save, got %d" % upgrades_saved.size())
		quit(1)
		return false

	# Wipe and reload.
	vs.call("reset_for_tests")
	if bool(vs.call("has_upgrade", "engine_tune_1")):
		push_error("vehicle_smoke: upgrade survived reset_for_tests")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("vehicle_smoke: load_game failed for vehicle_state")
		quit(1)
		return false
	if str(vs.call("get_vehicle_id")) != "starter_car":
		push_error("vehicle_smoke: vehicle_id not restored")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", "engine_tune_1")) or not bool(vs.call("has_upgrade", "cargo_rack_1")):
		push_error("vehicle_smoke: upgrades not restored")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_fuel_current")), 42.5):
		push_error("vehicle_smoke: fuel_current not restored")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_condition_current")), 77.0):
		push_error("vehicle_smoke: condition_current not restored")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_cruise_speed_modifier")), 1.25):
		push_error("vehicle_smoke: cruise_speed_modifier not restored")
		quit(1)
		return false
	if not is_equal_approx(float(_vehicle.call("get_effective_max_speed_ms")), (86.4 * 1.25) / 3.6):
		push_error("vehicle_smoke: PlayerVehicle effective max not restored from VehicleState")
		quit(1)
		return false

	if not bool(vs.call("remove_upgrade", "engine_tune_1")):
		push_error("vehicle_smoke: remove_upgrade failed")
		quit(1)
		return false
	if bool(vs.call("has_upgrade", "engine_tune_1")):
		push_error("vehicle_smoke: has_upgrade true after remove")
		quit(1)
		return false

	# Cleanup — restore defaults so later drive feel stays stable.
	save.call("delete_save")
	vs.call("reset_for_tests")
	print(
		"vehicle_smoke: vehicle_state OK (attrs + upgrades + effective max + save round-trip)"
	)
	return true


func _verify_vehicle_fuel_system() -> bool:
	## Fuel: distance burn, idle no burn, speed factor, empty cancels assist, offline cap, save.
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	if vs == null or save == null or journey == null or _vehicle == null:
		push_error("vehicle_smoke: VehicleState/Save/Journey/Vehicle missing for fuel test")
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
			push_error("vehicle_smoke: VehicleStateSystem missing fuel API %s" % required)
			quit(1)
			return false

	vs.call("reset_for_tests")
	journey.call("reset_journey")

	# Speed factor: high speed burns more than low for same distance.
	var low := float(vs.call("estimate_consumption_liters", 10.0, 40.0))
	var high := float(vs.call("estimate_consumption_liters", 10.0, 120.0))
	if high <= low:
		push_error("vehicle_smoke: high speed should burn more fuel than low (%.4f vs %.4f)" % [high, low])
		quit(1)
		return false

	# Efficiency modifier reduces burn.
	vs.call("set_efficiency_modifier", 2.0)
	var efficient := float(vs.call("estimate_consumption_liters", 10.0, 60.0))
	vs.call("set_efficiency_modifier", 1.0)
	var base_burn := float(vs.call("estimate_consumption_liters", 10.0, 60.0))
	if efficient >= base_burn:
		push_error("vehicle_smoke: efficiency_modifier should reduce fuel burn")
		quit(1)
		return false

	# Driving consumes; parked does not.
	vs.call("set_liters_per_100km", 50.0)
	vs.call("set_fuel_current", 50.0)
	if not await snap_vehicle_to_road():
		push_error("vehicle_smoke: could not snap vehicle to road before fuel drive")
		quit(1)
		return false
	clear_vehicle_input()
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
			push_error("vehicle_smoke: driving did not consume fuel")
			quit(1)
			return false
	if fuel_after_drive >= 50.0:
		push_error("vehicle_smoke: driving did not consume fuel from full tank")
		quit(1)
		return false

	# Stopped — fuel must not keep draining (brake to rest; park if possible).
	# After the long Travel drive the vehicle may sit on a descent; allow a longer stop.
	_mode_controller.call("set_mode", MODE_MANUAL)
	clear_vehicle_input()
	Input.action_press("vehicle_brake")
	for _i in range(720):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= 0.05 and _vehicle.is_on_floor():
			break
	Input.action_release("vehicle_brake")
	clear_vehicle_input()
	for _i in range(15):
		await physics_frame

	if absf(float(_vehicle.call("get_signed_speed"))) > float(_vehicle.get("max_parking_speed")):
		push_error(
			"vehicle_smoke: could not slow for fuel idle check (speed=%.2f on_floor=%s)"
			% [absf(float(_vehicle.call("get_signed_speed"))), str(_vehicle.is_on_floor())]
		)
		quit(1)
		return false
	if _vehicle.is_on_floor() and _vehicle.has_method("try_park"):
		_vehicle.call("try_park")

	var fuel_stopped := float(vs.call("get_fuel_current"))
	await create_timer(0.4).timeout
	var fuel_still := float(vs.call("get_fuel_current"))
	if absf(fuel_still - fuel_stopped) > 0.001:
		push_error(
			"vehicle_smoke: fuel changed while stopped (%.4f → %.4f)" % [fuel_stopped, fuel_still]
		)
		quit(1)
		return false

	# Empty fuel: cancel assist, no accel progress.
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	await physics_frame
	vs.call("set_fuel_current", 0.0)
	if not bool(vs.call("is_out_of_fuel")):
		push_error("vehicle_smoke: is_out_of_fuel false at 0 fuel")
		quit(1)
		return false
	_mode_controller.call("set_mode", MODE_TRAVEL)
	await physics_frame
	await physics_frame
	if str(_mode_controller.call("get_mode_name")) == "TRAVEL_MODE":
		push_error("vehicle_smoke: Travel Mode should cancel / refuse when out of fuel")
		quit(1)
		return false

	Input.action_press("vehicle_accelerate")
	var speed_before := absf(float(_vehicle.call("get_signed_speed")))
	for _i in range(60):
		await physics_frame
	Input.action_release("vehicle_accelerate")
	var speed_after := absf(float(_vehicle.call("get_signed_speed")))
	if speed_after > speed_before + 1.0:
		push_error("vehicle_smoke: empty fuel should not accelerate (%.2f → %.2f)" % [speed_before, speed_after])
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
		push_error("vehicle_smoke: offline empty should set OUT_OF_FUEL (got '%s')" % reason)
		quit(1)
		return false
	if applied <= 0.0 or applied > 12.6:
		push_error("vehicle_smoke: offline distance should be fuel-capped (~12.5), got %.3f" % applied)
		quit(1)
		return false
	if float(vs.call("get_fuel_current")) > 0.001:
		push_error("vehicle_smoke: fuel should be ~0 after offline OUT_OF_FUEL")
		quit(1)
		return false
	if not is_equal_approx(float(journey.call("get_current_distance_km")), applied):
		push_error("vehicle_smoke: journey not advanced by offline fuel-capped distance")
		quit(1)
		return false

	# Within-fuel offline: full desired distance, no stop reason.
	vs.call("reset_for_tests")
	journey.call("reset_journey")
	vs.call("set_fuel_current", 50.0)
	var ok_offline := vs.call("apply_offline_travel", 600.0, 60.0) as Dictionary  # 10 km
	if str(ok_offline.get("stopped_reason", "x")) != "":
		push_error("vehicle_smoke: offline within fuel should have empty stopped_reason")
		quit(1)
		return false
	if not is_equal_approx(float(ok_offline.get("distance_applied_km", 0.0)), 10.0):
		push_error("vehicle_smoke: offline within fuel should apply full 10 km")
		quit(1)
		return false

	# Save / load preserves fuel + stopped_reason.
	vs.call("set_fuel_current", 33.3)
	vs.set("stopped_reason", "OUT_OF_FUEL")
	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("vehicle_smoke: save_game failed in fuel test")
		quit(1)
		return false
	vs.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("vehicle_smoke: load_game failed in fuel test")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_fuel_current")), 33.3):
		push_error("vehicle_smoke: fuel_current not restored after save/load")
		quit(1)
		return false
	if str(vs.call("get_stopped_reason")) != "OUT_OF_FUEL":
		push_error("vehicle_smoke: stopped_reason not restored")
		quit(1)
		return false

	# add_fuel restores and clears OUT_OF_FUEL reason.
	var added := float(vs.call("add_fuel", 10.0))
	if added <= 0.0:
		push_error("vehicle_smoke: add_fuel failed")
		quit(1)
		return false
	if str(vs.call("get_stopped_reason")) == "OUT_OF_FUEL":
		push_error("vehicle_smoke: add_fuel should clear OUT_OF_FUEL")
		quit(1)
		return false

	# Cleanup.
	save.call("delete_save")
	vs.call("reset_for_tests")
	journey.call("reset_journey")
	_mode_controller.call("set_mode", MODE_MANUAL)
	clear_vehicle_input()
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	print(
		"vehicle_smoke: fuel OK (drive burn + park idle + speed factor + empty + offline + save)"
	)
	return true


func _verify_vehicle_upgrade_loop() -> bool:
	## Full loop: craft Cruise Module Mk I → install → effective speed → save/load once.
	var vs: Node = root.get_node_or_null("VehicleStateSystem")
	var craft: Node = root.get_node_or_null("CraftingSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if vs == null or craft == null or inv == null or save == null:
		push_error("vehicle_smoke: systems missing for upgrade loop")
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
		push_error("vehicle_smoke: cruise_module_mk1 recipe missing")
		quit(1)
		return false
	if not bool(inv.call("has_item_data", UPGRADE_ID)):
		push_error("vehicle_smoke: cruise_module_mk1 item missing from catalog")
		quit(1)
		return false
	if vs.call("get_upgrade_data", UPGRADE_ID) == null:
		push_error("vehicle_smoke: cruise_module_mk1 UpgradeData missing")
		quit(1)
		return false

	var base_speed := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(base_speed, 86.4):
		push_error("vehicle_smoke: base effective max expected 86.4 got %.2f" % base_speed)
		quit(1)
		return false

	# Gather test ingredients (same pool as world pickups / crafting smoke).
	inv.call("add_item", "scrap_metal", 2)
	inv.call("add_item", "copper_wire", 1)
	inv.call("add_item", "circuit_board", 1)
	if not bool(craft.call("can_craft", RECIPE_ID)):
		push_error("vehicle_smoke: should be able to craft cruise module with test items")
		quit(1)
		return false
	if not bool(craft.call("craft", RECIPE_ID)):
		push_error("vehicle_smoke: craft cruise_module_mk1 failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", UPGRADE_ID)) != 1:
		push_error("vehicle_smoke: crafted module not in inventory")
		quit(1)
		return false

	# Effects come from UpgradeData modifiers — not the display name.
	var data: Resource = vs.call("get_upgrade_data", UPGRADE_ID)
	var bonus := float(data.get("max_speed_bonus_kmh"))
	if not is_equal_approx(bonus, 10.0):
		push_error("vehicle_smoke: expected +10 km/h bonus on Cruise Module Mk I")
		quit(1)
		return false

	if not bool(vs.call("can_install_from_inventory", UPGRADE_ID)):
		push_error("vehicle_smoke: can_install_from_inventory false before install")
		quit(1)
		return false
	if not bool(vs.call("install_upgrade_from_inventory", UPGRADE_ID)):
		push_error("vehicle_smoke: install_upgrade_from_inventory failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", UPGRADE_ID)) != 0:
		push_error("vehicle_smoke: install did not consume module item")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", UPGRADE_ID)):
		push_error("vehicle_smoke: upgrade not marked installed")
		quit(1)
		return false

	var boosted := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(boosted, base_speed + bonus):
		push_error(
			"vehicle_smoke: effective max expected %.1f got %.1f" % [base_speed + bonus, boosted]
		)
		quit(1)
		return false
	if not is_equal_approx(float(_vehicle.call("get_effective_max_speed_kmh")), boosted):
		push_error("vehicle_smoke: PlayerVehicle did not pick up upgrade max speed")
		quit(1)
		return false

	# Non-stackable: cannot install again even with another module.
	inv.call("add_item", UPGRADE_ID, 1)
	if bool(vs.call("install_upgrade_from_inventory", UPGRADE_ID)):
		push_error("vehicle_smoke: duplicate non-stackable install should fail")
		quit(1)
		return false
	if int(inv.call("get_quantity", UPGRADE_ID)) != 1:
		push_error("vehicle_smoke: failed duplicate install should not consume item")
		quit(1)
		return false
	# Speed must not double.
	if not is_equal_approx(float(vs.call("get_effective_max_speed")), boosted):
		push_error("vehicle_smoke: effective speed changed after refused reinstall")
		quit(1)
		return false

	# Persist ids only — reload must not duplicate the bonus.
	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("vehicle_smoke: save_game failed in upgrade loop")
		quit(1)
		return false
	vs.call("reset_for_tests")
	inv.call("clear_inventory")
	if float(vs.call("get_effective_max_speed")) != 86.4:
		push_error("vehicle_smoke: reset should clear upgrade bonus")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("vehicle_smoke: load_game failed in upgrade loop")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", UPGRADE_ID)):
		push_error("vehicle_smoke: upgrade id not restored")
		quit(1)
		return false
	var restored := float(vs.call("get_effective_max_speed"))
	if not is_equal_approx(restored, base_speed + bonus):
		push_error("vehicle_smoke: effective speed not restored (got %.2f)" % restored)
		quit(1)
		return false
	# Count installed once — summing catalog effects must not double on load.
	var installed: PackedStringArray = vs.call("get_installed_upgrades")
	var count := 0
	for id in installed:
		if str(id) == UPGRADE_ID:
			count += 1
	if count != 1:
		push_error("vehicle_smoke: upgrade id duplicated after load (count=%d)" % count)
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_upgrade_max_speed_bonus_kmh")), bonus):
		push_error("vehicle_smoke: upgrade bonus duplicated after load")
		quit(1)
		return false

	save.call("delete_save")
	vs.call("reset_for_tests")
	inv.call("clear_inventory")
	print(
		"vehicle_smoke: upgrade OK (craft → install +10 km/h → persist once, no duplicate)"
	)
	return true


func _verify_enter_exit_vehicle() -> bool:
	## Park → exit on foot → vehicle stays → camera follows character → enter → control back.
	var occupancy: Node = root.find_child("PlayerOccupancyController", true, false)
	if occupancy == null:
		push_error("vehicle_smoke: PlayerOccupancyController missing")
		quit(1)
		return false
	var character: CharacterBody3D = root.find_child("PlayerCharacter", true, false) as CharacterBody3D
	if character == null:
		push_error("vehicle_smoke: PlayerCharacter missing")
		quit(1)
		return false

	clear_vehicle_input()
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
		push_error("vehicle_smoke: could not move before exit rejection check")
		quit(1)
		return false
	if bool(occupancy.call("try_exit_vehicle")):
		push_error("vehicle_smoke: exit allowed while moving / not parked")
		quit(1)
		return false
	if str(occupancy.call("get_state_name")) != "IN_VEHICLE":
		push_error("vehicle_smoke: occupancy left IN_VEHICLE after rejected exit")
		quit(1)
		return false

	# Stop and park.
	Input.action_press("vehicle_brake")
	for _j in range(240):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= 0.05 and _vehicle.is_on_floor():
			break
	Input.action_release("vehicle_brake")
	clear_vehicle_input()
	for _k in range(8):
		await physics_frame
	if not bool(_vehicle.call("try_park")):
		push_error("vehicle_smoke: park failed before exit")
		quit(1)
		return false

	var vehicle_origin: Vector3 = _vehicle.global_position
	var occupancy_signals := {"n": 0}
	var on_occ := func(_prev, _cur) -> void:
		occupancy_signals["n"] = int(occupancy_signals["n"]) + 1
	occupancy.occupancy_changed.connect(on_occ)

	if not bool(occupancy.call("try_exit_vehicle")):
		push_error("vehicle_smoke: try_exit_vehicle failed while PARKED")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	if str(occupancy.call("get_state_name")) != "ON_FOOT":
		push_error("vehicle_smoke: expected ON_FOOT after exit")
		quit(1)
		return false
	if not character.visible:
		push_error("vehicle_smoke: character not visible after exit")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and not bool(character.call("is_control_enabled")):
		push_error("vehicle_smoke: character control disabled after exit")
		quit(1)
		return false
	if not bool(_vehicle.call("is_parked")):
		push_error("vehicle_smoke: vehicle left PARKED after exit")
		quit(1)
		return false
	if bool(_vehicle.call("is_manual_control_enabled")):
		push_error("vehicle_smoke: vehicle manual control still enabled on foot")
		quit(1)
		return false
	if vehicle_origin.distance_to(_vehicle.global_position) > 0.5:
		push_error("vehicle_smoke: vehicle moved after exit")
		quit(1)
		return false
	var door_dist: float = character.global_position.distance_to(vehicle_origin)
	if door_dist > 4.0 or door_dist < 0.5:
		push_error("vehicle_smoke: character spawn distance odd (%.2f)" % door_dist)
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
		push_error("vehicle_smoke: on-foot character did not move")
		quit(1)
		return false
	if character.has_method("get_planar_speed"):
		# After release, should decelerate (not required zero immediately).
		pass
	if vehicle_origin.distance_to(_vehicle.global_position) > 0.5:
		push_error("vehicle_smoke: parked vehicle drifted while on foot")
		quit(1)
		return false

	# Dedicated on-foot camera must be active (not vehicle cam retargeted).
	var foot_cam: Node3D = root.find_child("OnFootCameraController", true, false) as Node3D
	if foot_cam == null:
		push_error("vehicle_smoke: OnFootCameraController missing")
		quit(1)
		return false
	if foot_cam.has_method("is_active") and not bool(foot_cam.call("is_active")):
		push_error("vehicle_smoke: on-foot camera not active while ON_FOOT")
		quit(1)
		return false
	if foot_cam.has_method("get_follow_target"):
		var foot_target: Node3D = foot_cam.call("get_follow_target") as Node3D
		if foot_target != character:
			push_error("vehicle_smoke: on-foot camera not following character")
			quit(1)
			return false
	var vcam: Camera3D = null
	if _camera_rig.has_method("get_camera"):
		vcam = _camera_rig.call("get_camera") as Camera3D
	var fcam: Camera3D = null
	if foot_cam.has_method("get_camera"):
		fcam = foot_cam.call("get_camera") as Camera3D
	if fcam == null or not fcam.current:
		push_error("vehicle_smoke: on-foot Camera3D is not current")
		quit(1)
		return false
	if vcam != null and vcam.current:
		push_error("vehicle_smoke: vehicle camera still current while on foot")
		quit(1)
		return false
	if int(occupancy_signals["n"]) < 1:
		push_error("vehicle_smoke: occupancy_changed did not fire on exit")
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
		push_error("vehicle_smoke: character clipped into parked vehicle")
		quit(1)
		return false
	character.global_position = before_push
	await physics_frame

	# Domain verifies (interaction/dialogue/NPC/POI/…) run in dedicated suites.

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
		push_error("vehicle_smoke: on-foot origin recenter did not fire")
		quit(1)
		return false
	var rel_after: Vector3 = character.global_position - _vehicle.global_position
	if rel_after.distance_to(rel) > 0.35:
		push_error(
			"vehicle_smoke: recenter broke character/vehicle relative pose (before=%s after=%s)"
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
		push_error("vehicle_smoke: try_enter_vehicle failed")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	if str(occupancy.call("get_state_name")) != "IN_VEHICLE":
		push_error("vehicle_smoke: expected IN_VEHICLE after enter")
		quit(1)
		return false
	if character.visible:
		push_error("vehicle_smoke: character still visible after enter")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and bool(character.call("is_control_enabled")):
		push_error("vehicle_smoke: character control still enabled after enter")
		quit(1)
		return false
	if not bool(_vehicle.call("is_manual_control_enabled")):
		push_error("vehicle_smoke: vehicle control not restored after enter")
		quit(1)
		return false
	if not bool(_vehicle.call("is_parked")):
		push_error("vehicle_smoke: vehicle should still be PARKED after enter")
		quit(1)
		return false
	if foot_cam.has_method("is_active") and bool(foot_cam.call("is_active")):
		push_error("vehicle_smoke: on-foot camera still active after enter")
		quit(1)
		return false
	if fcam != null and fcam.current:
		push_error("vehicle_smoke: on-foot Camera3D still current after enter")
		quit(1)
		return false
	if vcam != null and not vcam.current:
		push_error("vehicle_smoke: vehicle camera not current after enter")
		quit(1)
		return false
	if _camera_rig.has_method("get_follow_target"):
		var cam_back: Node3D = _camera_rig.call("get_follow_target") as Node3D
		if cam_back != _vehicle:
			push_error("vehicle_smoke: camera not following vehicle after enter")
			quit(1)
			return false
	if int(occupancy_signals["n"]) < 2:
		push_error("vehicle_smoke: occupancy_changed did not fire on enter")
		quit(1)
		return false

	occupancy.occupancy_changed.disconnect(on_occ)
	clear_vehicle_input()
	# Release mouse capture if smoke left it on.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print("vehicle_smoke: enter/exit OK (reject@move → exit ON_FOOT → on-foot cam/move → recenter OK → enter IN_VEHICLE)")
	return true


func _verify_interaction_system(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Generic interactables: prompt on focus, interact key, clear when leaving, shared infra.
	var terminal: Node = root.find_child("TestTerminal", true, false)
	var terminal_b: Node = root.find_child("TestTerminalB", true, false)
	if terminal == null or terminal_b == null:
		push_error("vehicle_smoke: TestTerminal(s) missing")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(terminal):
		push_error("vehicle_smoke: TestTerminal is not duck-typed interactable")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(terminal_b):
		push_error("vehicle_smoke: TestTerminalB is not duck-typed interactable")
		quit(1)
		return false

	var detector: Node = character.get_node_or_null("InteractionDetector")
	if detector == null:
		push_error("vehicle_smoke: InteractionDetector missing on character")
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
		push_error("vehicle_smoke: interaction focus present when far from objects")
		quit(1)
		return false
	if character.has_method("get_interaction_prompt"):
		if not str(character.call("get_interaction_prompt")).is_empty():
			push_error("vehicle_smoke: interaction prompt shown without focus")
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
		push_error("vehicle_smoke: no interaction focus near TestTerminal")
		quit(1)
		return false
	var prompt := str(detector.call("get_focus_prompt"))
	if prompt.is_empty() or not prompt.contains("Interagir"):
		push_error("vehicle_smoke: bad interaction prompt '%s'" % prompt)
		quit(1)
		return false
	var focus: Node = detector.call("get_focus")
	if focus != terminal:
		# Either terminal is fine if both in range; prefer A when closer.
		if focus != terminal and focus != terminal_b:
			push_error("vehicle_smoke: focus is not a known test interactable")
			quit(1)
			return false

	var before_count := int(focus.get_meta("interact_count", 0))
	if not bool(detector.call("try_interact")):
		push_error("vehicle_smoke: try_interact failed on focused object")
		quit(1)
		return false
	var after_count := int(focus.get_meta("interact_count", 0))
	if after_count != before_count + 1:
		push_error("vehicle_smoke: interact did not increment count")
		quit(1)
		return false
	var msg := str(focus.get_meta("last_interact_message", ""))
	if msg.is_empty():
		push_error("vehicle_smoke: interact left no message meta")
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
		push_error("vehicle_smoke: no focus on second interactable")
		quit(1)
		return false
	var focus_b: Node = detector.call("get_focus")
	if focus_b != terminal_b:
		push_error("vehicle_smoke: expected focus on TestTerminalB, got %s" % focus_b)
		quit(1)
		return false
	if not bool(detector.call("try_interact")):
		push_error("vehicle_smoke: second interactable try_interact failed")
		quit(1)
		return false
	if int(terminal_b.get_meta("interact_count", 0)) < 1:
		push_error("vehicle_smoke: second interactable count not updated")
		quit(1)
		return false

	# Leave range → prompt/focus clears.
	character.global_position = _vehicle.global_position + Vector3(6.0, 0.05, 0.0)
	for _c in range(12):
		await physics_frame
	if bool(detector.call("has_focus")):
		push_error("vehicle_smoke: interaction focus remained after leaving range")
		quit(1)
		return false

	# Keep character near vehicle for subsequent enter test.
	var exit_xf: Transform3D = _vehicle.call("get_driver_exit_global_transform")
	character.global_transform = exit_xf
	await physics_frame
	print("vehicle_smoke: interaction OK (prompt → interact A/B → clear on leave)")
	return true



func _after_travel() -> void:
	if not await _finish_travel():
		return
	await _run_post_travel()
