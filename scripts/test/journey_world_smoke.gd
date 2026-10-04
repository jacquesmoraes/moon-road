extends "res://scripts/test/test_helpers.gd"
## Journey/world smoke: regions, Sunset Viewpoint reach, game time.
## Run: godot --path . --headless -s res://scripts/test/journey_world_smoke.gd

func _initialize() -> void:
	suite_name = "journey_world_smoke"
	start_suite_timeout(240.0)
	await _run()


func _run() -> void:
	if not await bootstrap_sandbox(0.5, true):
		return
	_journey.call("reset_journey")
	if not _verify_world_regions():
		return
	_journey.call("reset_journey")
	if not await _verify_sunset_viewpoint_reachable():
		return
	if not await _verify_game_time_system():
		return
	pass_suite("world_regions+sunset_viewpoint+game_time")

func _verify_world_regions() -> bool:
	var regions: Node = root.get_node_or_null("WorldRegionSystem")
	if regions == null:
		push_error("journey_world_smoke: WorldRegionSystem missing")
		quit(1)
		return false
	if int(regions.call("get_region_count")) < 7:
		push_error("journey_world_smoke: expected >=7 catalog regions")
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
			push_error("journey_world_smoke: region at %.1f km got %s want %s" % [km, got_id, expect_id])
			quit(1)
			return false
		var at: Variant = regions.call("get_region_at_distance", km)
		if at == null or str(at.region_id) != expect_id:
			push_error("journey_world_smoke: get_region_at_distance mismatch at %.1f" % km)
			quit(1)
			return false
		if got_id != last_id:
			expected_emits += 1
			last_id = got_id

	if int(signal_count["n"]) != expected_emits:
		push_error(
			"journey_world_smoke: region_changed emits=%d expected=%d"
			% [int(signal_count["n"]), expected_emits]
		)
		quit(1)
		return false

	# Same-region distance change must not emit again.
	var before := int(signal_count["n"])
	_journey.call("set_current_distance_km", 375000.0)  # still LUNAR_DESCENT
	_journey.call("set_current_distance_km", 380000.0)
	if int(signal_count["n"]) != before:
		push_error("journey_world_smoke: region_changed fired without region change")
		quit(1)
		return false

	var progress := float(regions.call("get_region_progress"))
	if progress < 0.0 or progress > 1.0:
		push_error("journey_world_smoke: region progress out of range %.3f" % progress)
		quit(1)
		return false

	regions.region_changed.disconnect(on_changed)
	print(
		"journey_world_smoke: regions OK count=%d emits=%d final=%s progress=%.2f"
		% [int(regions.call("get_region_count")), expected_emits, last_id, progress]
	)
	return true



func _verify_sunset_viewpoint_reachable() -> bool:
	## Structural + discovery API: EXIT_RIGHT detour, ViewpointPOI spawn, persist after unload.
	if _exit_system == null:
		return false
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if poi_sys == null:
		push_error("journey_world_smoke: POISystem missing")
		quit(1)
		return false
	if poi_sys.has_method("clear_discovery_for_tests"):
		poi_sys.call("clear_discovery_for_tests")
	clear_world_state()

	for _i in 10:
		if bool(_exit_system.call("is_exit_active", "sunset_viewpoint_exit")):
			break
		await physics_frame

	if not bool(_exit_system.call("is_exit_active", "sunset_viewpoint_exit")):
		push_error("journey_world_smoke: sunset exit not active at start")
		quit(1)
		return false

	var poi_name := str(_exit_system.call("get_active_poi_name"))
	if poi_name != "Sunset Viewpoint":
		push_error("journey_world_smoke: expected Sunset Viewpoint, got '%s'" % poi_name)
		quit(1)
		return false

	if not bool(poi_sys.call("has_active_viewpoint", "sunset_viewpoint")):
		push_error("journey_world_smoke: ViewpointPOI not spawned for sunset_viewpoint")
		quit(1)
		return false

	var vp: Node3D = poi_sys.call("get_active_viewpoint", "sunset_viewpoint")
	if vp == null:
		push_error("journey_world_smoke: active viewpoint instance null")
		quit(1)
		return false

	var poi_pos: Vector3 = _exit_system.call("get_poi_global_position", "sunset_viewpoint_exit")
	if poi_pos == Vector3.ZERO:
		push_error("journey_world_smoke: Sunset Viewpoint POI position missing")
		quit(1)
		return false

	var main_sample: Dictionary = _road_manager.call("sample_road", poi_pos, 8.0)
	var main_lat := absf(float(main_sample.get("lateral", 0.0)))
	if main_lat < 6.0:
		push_error("journey_world_smoke: Sunset Viewpoint POI too close to main road (lat=%.2f)" % main_lat)
		quit(1)
		return false

	if int(_exit_system.call("get_detour_segment_count")) < 2:
		push_error("journey_world_smoke: detour segment pool missing")
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
		push_error("journey_world_smoke: sunset_viewpoint not marked discovered")
		quit(1)
		return false
	if int(emit_count["n"]) != 1:
		push_error("journey_world_smoke: discovered_poi emits=%d want 1" % int(emit_count["n"]))
		quit(1)
		return false

	# Stateful ViewpointTerminal must exist inside the viewpoint (starts OFF).
	var terminal: Node = vp.find_child("ViewpointTerminal", true, false)
	if terminal == null:
		push_error("journey_world_smoke: ViewpointTerminal missing inside Sunset Viewpoint")
		quit(1)
		return false
	if not terminal.has_method("get_state_name") or str(terminal.call("get_state_name")) != "OFF":
		push_error("journey_world_smoke: ViewpointTerminal should start OFF")
		quit(1)
		return false

	var booth: Node = vp.find_child("ObservationBooth", true, false)
	if booth == null:
		booth = vp.find_child("SmallInterior", true, false)
	if booth == null:
		push_error("journey_world_smoke: ObservationBooth / SmallInterior missing on Sunset Viewpoint")
		quit(1)
		return false

	# Unload viewpoint; discovery must remain in logical POISystem.
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	if bool(poi_sys.call("has_active_viewpoint", "sunset_viewpoint")):
		push_error("journey_world_smoke: viewpoint still loaded after despawn")
		quit(1)
		return false
	if not bool(poi_sys.call("is_discovered", "sunset_viewpoint")):
		push_error("journey_world_smoke: discovery lost after viewpoint unload")
		quit(1)
		return false

	poi_sys.discovered_poi.disconnect(on_disc)
	_poi_reach_ok = true
	_saw_exit_active = true
	print(
		"journey_world_smoke: Sunset Viewpoint discovered + persisted after unload (main_lat=%.1f)"
		% main_lat
	)
	return true



func _verify_game_time_system() -> bool:
	## GameTimeSystem: play accumulates always; travel only while trip; save round-trip; offline gap.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if gt == null or save == null:
		push_error("journey_world_smoke: GameTimeSystem/SaveSystem missing")
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
			push_error("journey_world_smoke: GameTimeSystem missing %s" % required)
			quit(1)
			return false

	# Wall-clock / FPS independence; narrative is a separate persistent clock (no lighting).
	var gt_script: Script = load("res://autoload/game_time_system.gd") as Script
	if gt_script != null:
		var src := gt_script.source_code
		if src.find("Time.get_ticks_msec") < 0:
			push_error("journey_world_smoke: GameTimeSystem must use Time.get_ticks_msec")
			quit(1)
			return false
		for banned in ["DirectionalLight", "WorldEnvironment", "sky_energy", "Lighting"]:
			if src.find(banned) >= 0:
				push_error("journey_world_smoke: GameTimeSystem must not wire visuals '%s'" % banned)
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
			push_error("journey_world_smoke: GameTimeSystem missing %s" % required_narrative)
			quit(1)
			return false

	# Journey / vehicle must not drive off narrative time.
	for path in ["res://autoload/journey_system.gd", "res://autoload/vehicle_state_system.gd"]:
		var peer: Script = load(path) as Script
		if peer != null:
			var peer_src := peer.source_code
			for banned in ["get_narrative_", "narrative_time", "narrative_day", "narrative_minutes"]:
				if peer_src.find(banned) >= 0:
					push_error("journey_world_smoke: %s must not use narrative time ('%s')" % [path, banned])
					quit(1)
					return false

	gt.call("reset_for_tests")
	if float(gt.call("get_total_play_time")) != 0.0 or float(gt.call("get_total_travel_time")) != 0.0:
		push_error("journey_world_smoke: GameTimeSystem reset_for_tests did not clear accumulators")
		quit(1)
		return false

	# Independent narrative clock: day 0 08:00; scale 60 ⇒ 1 real min = 1 narrative hour.
	if int(gt.call("get_narrative_day_index")) != 0 or int(gt.call("get_narrative_hour")) != 8:
		push_error(
			"journey_world_smoke: narrative clock expected day0/h8 got day%d/h%d"
			% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
		)
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_narrative_time_scale")), 60.0):
		push_error("journey_world_smoke: default narrative_time_scale should be 60")
		quit(1)
		return false

	# Narrative independent of travel accumulator.
	gt.call("set_narrative_time", 0, 10, 0)
	var narr_before := float(gt.call("get_narrative_minutes_of_day"))
	gt.set("total_travel_time_seconds", float(gt.call("get_total_travel_time")) + 999.0)
	if not is_equal_approx(float(gt.call("get_narrative_minutes_of_day")), narr_before):
		push_error("journey_world_smoke: narrative must not change when travel time is bumped alone")
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
			"journey_world_smoke: travel expected 600 after 10min drive, got %.3f"
			% float(gt.call("get_total_travel_time"))
		)
		quit(1)
		return false
	if int(gt.call("get_narrative_hour")) != 18:
		push_error(
			"journey_world_smoke: after 10 real min (scale 60) hour should be 18, got %d"
			% int(gt.call("get_narrative_hour"))
		)
		quit(1)
		return false
	if journey != null and journey.has_method("get_current_distance_km"):
		if not is_equal_approx(float(journey.call("get_current_distance_km")), km_before):
			push_error("journey_world_smoke: narrative/play advance must not add journey km")
			quit(1)
			return false

	# Parked 10 min: no travel growth; narrative still advances.
	gt.call("reset_for_tests")
	gt.call("debug_advance", 600.0, false)
	if not is_equal_approx(float(gt.call("get_total_travel_time")), 0.0):
		push_error("journey_world_smoke: parked 10min must not add travel time")
		quit(1)
		return false
	if int(gt.call("get_narrative_hour")) != 18:
		push_error(
			"journey_world_smoke: parked 10min should still advance narrative to hour 18, got %d"
			% int(gt.call("get_narrative_hour"))
		)
		quit(1)
		return false

	gt.call("set_narrative_time", 1, 22, 30)
	if int(gt.call("get_narrative_day_index")) != 1 or int(gt.call("get_narrative_hour")) != 22:
		push_error("journey_world_smoke: set_narrative_time failed")
		quit(1)
		return false
	if int(gt.call("get_narrative_minute")) != 30:
		push_error("journey_world_smoke: narrative minute should be 30")
		quit(1)
		return false
	if str(gt.call("get_narrative_time_string")).find("22:30") < 0:
		push_error("journey_world_smoke: get_narrative_time_string missing 22:30")
		quit(1)
		return false
	# Future wait API: advance to next 06:00 → day 2 06:00.
	gt.call("wait_until_narrative_time", 6, 0)
	if int(gt.call("get_narrative_day_index")) != 2 or int(gt.call("get_narrative_hour")) != 6:
		push_error(
			"journey_world_smoke: wait_until_narrative_time failed (day%d/h%d)"
			% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
		)
		quit(1)
		return false
	gt.call("reset_for_tests")

	# Play time advances without travel.
	gt.call("debug_advance", 10.0, false)
	if not is_equal_approx(float(gt.call("get_total_play_time")), 10.0):
		push_error(
			"journey_world_smoke: play time expected 10 got %.3f" % float(gt.call("get_total_play_time"))
		)
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), 0.0):
		push_error("journey_world_smoke: travel time should stay 0 when not traveling")
		quit(1)
		return false

	# Travel accumulator only when flagged traveling.
	gt.call("debug_advance", 5.0, true)
	if not is_equal_approx(float(gt.call("get_total_play_time")), 15.0):
		push_error("journey_world_smoke: play time expected 15 after travel advance")
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), 5.0):
		push_error(
			"journey_world_smoke: travel time expected 5 got %.3f" % float(gt.call("get_total_travel_time"))
		)
		quit(1)
		return false

	# Live is_traveling: park / on foot must not count as travel.
	clear_vehicle_input()
	_mode_controller.call("set_mode", MODE_MANUAL)
	# Slow to park.
	for _i in range(240):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= float(_vehicle.get("max_parking_speed")):
			break
	if not bool(_vehicle.call("try_park")):
		push_error("journey_world_smoke: could not park for game time travel check")
		quit(1)
		return false
	await physics_frame
	await physics_frame
	if bool(gt.call("is_traveling")):
		push_error("journey_world_smoke: is_traveling true while PARKED")
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
			"journey_world_smoke: travel time grew while PARKED (%.3f → %.3f)"
			% [travel_before_park, travel_after_park]
		)
		quit(1)
		return false
	if play_after_park < play_before_park + 0.05:
		push_error("journey_world_smoke: play time did not advance while PARKED")
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
		push_error("journey_world_smoke: is_traveling false in TRAVEL_MODE")
		quit(1)
		return false
	var travel_before_tm := float(gt.call("get_total_travel_time"))
	await create_timer(0.35).timeout
	var travel_after_tm := float(gt.call("get_total_travel_time"))
	if travel_after_tm < travel_before_tm + 0.05:
		push_error("journey_world_smoke: travel time did not grow in TRAVEL_MODE")
		quit(1)
		return false

	# Save / load preserves accumulators; offline gap uses absolute timestamps.
	_mode_controller.call("set_mode", MODE_MANUAL)
	clear_vehicle_input()
	if save.has_method("delete_save"):
		save.call("delete_save")

	var play_saved := float(gt.call("get_total_play_time"))
	var travel_saved := float(gt.call("get_total_travel_time"))
	# Stamp a known prior exit so offline calc is deterministic after reload.
	var exit_stamp := float(Time.get_unix_time_from_system()) - 42.0
	gt.set("last_exit_timestamp", exit_stamp)

	if not bool(save.call("save_game")):
		push_error("journey_world_smoke: save_game failed in game time test")
		quit(1)
		return false

	# Confirm payload shape in JSON.
	var path := str(save.call("get_save_path"))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("journey_world_smoke: game_time save JSON parse failed")
		quit(1)
		return false
	var systems: Dictionary = parsed.get("systems", {})
	if not systems.has("game_time"):
		push_error("journey_world_smoke: systems.game_time missing from save")
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
			push_error("journey_world_smoke: game_time save missing '%s'" % key)
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
		push_error("journey_world_smoke: narrative clock save_game failed")
		quit(1)
		return false

	# Wipe runtime then reload — accumulators + narrative must restore.
	gt.call("reset_for_tests")
	if float(gt.call("get_total_play_time")) != 0.0:
		push_error("journey_world_smoke: reset before load failed")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("journey_world_smoke: load_game failed for game_time")
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_play_time")), play_saved):
		push_error(
			"journey_world_smoke: play time not restored (%.3f vs %.3f)"
			% [float(gt.call("get_total_play_time")), play_saved]
		)
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), travel_saved):
		push_error(
			"journey_world_smoke: travel time not restored (%.3f vs %.3f)"
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
			"journey_world_smoke: narrative clock not restored (day%d %02d:%02d vs day%d %02d:%02d)"
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
		push_error("journey_world_smoke: offline gap expected ~42s got %.1f" % offline)
		quit(1)
		return false

	var dt_str := str(gt.call("get_current_real_datetime"))
	if dt_str.is_empty() or dt_str.find("T") < 0:
		push_error("journey_world_smoke: get_current_real_datetime looks invalid: %s" % dt_str)
		quit(1)
		return false

	# Offline narrative: OFF (not traveling at save) → clock unchanged on load.
	var vs_off: Node = root.get_node_or_null("VehicleStateSystem")
	if vs_off != null:
		gt.call("set_narrative_time", 3, 12, 0)
		vs_off.set("was_traveling_at_save", false)
		gt.set("last_exit_timestamp", float(Time.get_unix_time_from_system()) - 3600.0)
		if not bool(save.call("save_game")):
			push_error("journey_world_smoke: offline-OFF narrative save failed")
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
			push_error("journey_world_smoke: offline-OFF load failed")
			quit(1)
			return false
		if int(gt.call("get_narrative_day_index")) != 3 or int(gt.call("get_narrative_hour")) != 12:
			push_error(
				"journey_world_smoke: offline progress OFF must not advance narrative (got day%d/h%d)"
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
			push_error("journey_world_smoke: offline-ON narrative save failed")
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
			push_error("journey_world_smoke: offline-ON load failed")
			quit(1)
			return false
		# 10 real min offline at scale 60 → +10 narrative hours → 18:00 day 4.
		if int(gt.call("get_narrative_day_index")) != 4 or int(gt.call("get_narrative_hour")) != 18:
			push_error(
				"journey_world_smoke: offline applied should advance narrative to day4/h18 (got day%d/h%d)"
				% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
			)
			quit(1)
			return false

	# Cleanup.
	save.call("delete_save")
	gt.call("reset_for_tests")
	_mode_controller.call("set_mode", MODE_MANUAL)
	clear_vehicle_input()
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	print(
		"journey_world_smoke: game_time OK (play/travel + independent narrative + save + offline gates)"
	)
	return true



