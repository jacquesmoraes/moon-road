extends "res://scripts/test/test_helpers.gd"
## High-level cross-system vertical slice (mid-save + autoload readiness gate).
## Deep autoload coverage lives in autoload_init_smoke.gd (shared AutoloadChecks).
## Run: godot --path . --headless -s res://scripts/test/vertical_slice_smoke.gd

const AutoloadChecks = preload("res://scripts/test/autoload_checks.gd")


func _initialize() -> void:
	suite_name = "vertical_slice_smoke"
	start_suite_timeout(180.0)
	await _run()


func _run() -> void:
	if not await bootstrap_sandbox(0.5, true):
		return
	for _i in range(8):
		await physics_frame
	if not await AutoloadChecks.verify_lite_gate(self, suite_name):
		quit(1)
		return
	print("%s: autoload_init OK (READY + Schedule/Travel↔GameTime + Save providers)" % suite_name)
	if not await _verify_vertical_slice_mid_save():
		return
	pass_suite("autoload_init+mid_save")


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
		push_error("vertical_slice_smoke: systems missing for mid-save vertical slice")
		quit(1)
		return false

	# Clean slate.
	save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	clear_world_state()
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
		push_error("vertical_slice_smoke: mid-save seed upgrade speed wrong")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"))):
		push_error("vertical_slice_smoke: mid-save seed quest not ACTIVE")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_poi_discovered", "sunset_viewpoint"))):
		push_error("vertical_slice_smoke: mid-save seed POI not discovered")
		quit(1)
		return false

	if not bool(save.call("save_game")):
		push_error("vertical_slice_smoke: mid-save save_game failed")
		quit(1)
		return false

	# Mutate runtime aggressively (simulates closing the game).
	journey.call("set_current_distance_km", 0.0)
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	clear_world_state()
	vs.call("reset_for_tests")
	flags.call("reset_for_tests")
	gt.call("reset_for_tests")

	if not bool(save.call("load_game")):
		push_error("vertical_slice_smoke: mid-save load_game failed")
		quit(1)
		return false

	# --- Assert restore without loss ---
	if not is_equal_approx(float(journey.call("get_current_distance_km")), 2500.0):
		push_error("vertical_slice_smoke: mid-save journey not restored")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 2:
		push_error("vertical_slice_smoke: mid-save scrap not restored")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 1:
		push_error("vertical_slice_smoke: mid-save repair kit not restored")
		quit(1)
		return false
	if str(qs.call("get_state_name", "power_the_viewpoint")) != "ACTIVE":
		push_error("vertical_slice_smoke: mid-save quest not ACTIVE after load")
		quit(1)
		return false
	if not bool(poi.call("is_discovered", "sunset_viewpoint")):
		push_error("vertical_slice_smoke: mid-save POI discovery lost")
		quit(1)
		return false
	if not bool(ws.call("get_flag", "poi.sunset_viewpoint.pickup.scrap_01", "collected", false)):
		push_error("vertical_slice_smoke: mid-save collected pickup flag lost")
		quit(1)
		return false
	if bool(ws.call("get_value", "poi.sunset_viewpoint.terminal.main", "powered", true)):
		push_error("vertical_slice_smoke: mid-save terminal should stay unpowered")
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_fuel_current")), 55.0):
		push_error("vertical_slice_smoke: mid-save fuel not restored")
		quit(1)
		return false
	if not bool(vs.call("has_upgrade", "cruise_module_mk1")):
		push_error("vertical_slice_smoke: mid-save upgrade lost")
		quit(1)
		return false
	# No duplicated upgrade effect / id.
	var ups: PackedStringArray = vs.call("get_installed_upgrades")
	var up_count := 0
	for id in ups:
		if str(id) == "cruise_module_mk1":
			up_count += 1
	if up_count != 1:
		push_error("vertical_slice_smoke: mid-save upgrade duplicated (count=%d)" % up_count)
		quit(1)
		return false
	if not is_equal_approx(float(vs.call("get_effective_max_speed")), expected_speed):
		push_error("vertical_slice_smoke: mid-save effective speed duplicated/wrong")
		quit(1)
		return false
	if not bool(flags.call("get_flag", "slice_mid_marker", false)):
		push_error("vertical_slice_smoke: mid-save game flag lost")
		quit(1)
		return false
	if float(gt.call("get_total_play_time")) < play_before + 14.5:
		push_error("vertical_slice_smoke: mid-save play time not restored")
		quit(1)
		return false
	if not is_equal_approx(float(gt.call("get_total_travel_time")), travel_before + 3.0):
		push_error("vertical_slice_smoke: mid-save travel time not restored")
		quit(1)
		return false

	# Second load must not duplicate inventory / upgrades.
	if not bool(save.call("load_game")):
		push_error("vertical_slice_smoke: mid-save second load failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 2:
		push_error("vertical_slice_smoke: mid-save second load duplicated inventory")
		quit(1)
		return false
	ups = vs.call("get_installed_upgrades")
	up_count = 0
	for id in ups:
		if str(id) == "cruise_module_mk1":
			up_count += 1
	if up_count != 1 or not is_equal_approx(float(vs.call("get_effective_max_speed")), expected_speed):
		push_error("vertical_slice_smoke: mid-save second load duplicated upgrade effect")
		quit(1)
		return false

	# --- Offline progress capped by fuel; applies once ---
	journey.call("set_current_distance_km", 100.0)
	vs.call("set_fuel_current", 1.0)  # ~12.5 km at 60 km/h / 8 L/100km
	vs.set("offline_cruise_speed_kmh", 60.0)
	vs.set("was_traveling_at_save", true)
	gt.set("last_exit_timestamp", float(Time.get_unix_time_from_system()) - 3600.0)
	if not bool(save.call("save_game")):
		push_error("vertical_slice_smoke: offline mid-save save failed")
		quit(1)
		return false
	# Force traveling intent into the file even if live is_traveling was false at save.
	var path := str(save.call("get_save_path"))
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("vertical_slice_smoke: could not patch save for offline test")
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
		push_error("vertical_slice_smoke: offline mid-save load failed")
		quit(1)
		return false
	var after_offline_km := float(journey.call("get_current_distance_km"))
	# Journey was 100 in save + up to ~12.5 offline.
	if after_offline_km < 110.0 or after_offline_km > 113.0:
		push_error(
			"vertical_slice_smoke: offline fuel cap distance unexpected (got %.3f, want ~112.5)"
			% after_offline_km
		)
		quit(1)
		return false
	if float(vs.call("get_fuel_current")) > 0.001:
		push_error("vertical_slice_smoke: offline should empty fuel when capped")
		quit(1)
		return false
	if str(vs.call("get_stopped_reason")) != "OUT_OF_FUEL":
		push_error("vertical_slice_smoke: offline stop reason should be OUT_OF_FUEL")
		quit(1)
		return false

	# Reload again — must not advance a second time (was_traveling cleared + rewritten).
	var km_once := after_offline_km
	if not bool(save.call("load_game")):
		push_error("vertical_slice_smoke: offline second load failed")
		quit(1)
		return false
	if not is_equal_approx(float(journey.call("get_current_distance_km")), km_once):
		push_error(
			"vertical_slice_smoke: offline progress applied twice (%.3f → %.3f)"
			% [km_once, float(journey.call("get_current_distance_km"))]
		)
		quit(1)
		return false

	# Travel Mode still engages after restore (road path intact).
	clear_vehicle_input()
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
		push_error("vertical_slice_smoke: Travel Mode should still work after mid-save slice")
		quit(1)
		return false
	_mode_controller.call("set_mode", MODE_MANUAL)
	clear_vehicle_input()

	# Cleanup
	save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	clear_world_state()
	vs.call("reset_for_tests")
	flags.call("reset_for_tests")
	if gt.has_method("reset_for_tests"):
		gt.call("reset_for_tests")
	print(
		"vertical_slice_smoke: mid_save OK (persist all systems + offline once + Travel Mode)"
	)
	return true



