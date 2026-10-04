extends "res://scripts/test/test_helpers.gd"
## World state, viewpoint terminal, conditions, small interior, side quest.
## Run: godot --path . --headless -s res://scripts/test/poi_worldstate_smoke.gd

func _initialize() -> void:
	suite_name = "poi_worldstate_smoke"
	start_suite_timeout(240.0)
	await _run()

func _run() -> void:
	if not await bootstrap_sandbox(0.5, true):
		return
	var foot := await park_and_exit_to_foot()
	if not bool(foot.get("ok", false)):
		return
	var occupancy: Node = foot["occupancy"]
	var character: CharacterBody3D = foot["character"]
	var foot_cam: Node3D = foot["foot_cam"]
	if not await _verify_world_state_system():
		return
	if not await _verify_viewpoint_terminal(occupancy, character, foot_cam):
		return
	if not await _verify_condition_system():
		return
	if not await _verify_small_interior(occupancy, character, foot_cam):
		return
	if not await _verify_side_quest(occupancy, character, foot_cam):
		return
	pass_suite("world_state+viewpoint_terminal+condition+small_interior+side_quest")

func _verify_world_state_system() -> bool:
	## WorldStateSystem: terminal + pickup survive despawn and save/load. No Node refs.
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if ws == null or save == null or poi_sys == null or inv == null:
		push_error("poi_worldstate_smoke: WorldStateSystem/SaveSystem/POI/Inventory missing")
		quit(1)
		return false

	var ws_script: Script = load("res://autoload/world_state_system.gd") as Script
	if ws_script != null:
		var src := ws_script.source_code
		for banned in ["ViewpointTerminal", "WorldItem", "CitySystem"]:
			if src.find(banned) >= 0:
				push_error("poi_worldstate_smoke: WorldStateSystem must not reference %s" % banned)
				quit(1)
				return false

	const TERM_ID := "poi.sunset_viewpoint.terminal.main"
	const PICK_ID := "poi.sunset_viewpoint.pickup.scrap_01"

	clear_world_state()
	inv.call("clear_inventory")
	save.call("delete_save")

	# Reject Node values.
	if bool(ws.call("set_value", "test.entity", "bad", self)):
		push_error("poi_worldstate_smoke: WorldStateSystem must reject Node values")
		quit(1)
		return false

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, Vector3(20.0, 0.0, -8.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("poi_worldstate_smoke: viewpoint spawn failed for world state")
		quit(1)
		return false

	var terminal: Node = vp.find_child("ViewpointTerminal", true, false)
	var scrap: Node = vp.find_child("ScrapMetalPickup", true, false)
	if terminal == null or scrap == null:
		push_error("poi_worldstate_smoke: terminal/scrap missing for world state")
		quit(1)
		return false
	if str(terminal.get("world_state_id")) != TERM_ID:
		push_error("poi_worldstate_smoke: terminal world_state_id mismatch")
		quit(1)
		return false
	if str(scrap.call("get_pickup_id")) != PICK_ID:
		push_error("poi_worldstate_smoke: scrap pickup_id mismatch (expected convention id)")
		quit(1)
		return false

	# Power + collect → world flags.
	terminal.call("force_state", 1)  # PowerState.ON
	if not bool(ws.call("get_flag", TERM_ID, "powered", false)):
		push_error("poi_worldstate_smoke: powered flag not written on terminal ON")
		quit(1)
		return false
	if not bool(scrap.call("interact", null)):
		push_error("poi_worldstate_smoke: scrap collect failed for world state")
		quit(1)
		return false
	if not bool(ws.call("get_flag", PICK_ID, "collected", false)):
		push_error("poi_worldstate_smoke: collected flag not written on pickup")
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
		push_error("poi_worldstate_smoke: terminal/scrap missing after respawn")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "ON":
		push_error("poi_worldstate_smoke: terminal not ON after scene reload")
		quit(1)
		return false
	if not bool(scrap.call("is_collected")):
		push_error("poi_worldstate_smoke: scrap not collected after scene reload")
		quit(1)
		return false
	if bool(scrap.call("can_interact", null)):
		push_error("poi_worldstate_smoke: collected scrap still interactable after reload")
		quit(1)
		return false

	# Disk round-trip.
	if not bool(save.call("save_game")):
		push_error("poi_worldstate_smoke: save_game failed in world state test")
		quit(1)
		return false
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	clear_world_state()
	inv.call("clear_inventory")
	if bool(ws.call("get_flag", TERM_ID, "powered", false)):
		push_error("poi_worldstate_smoke: world state not cleared before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("poi_worldstate_smoke: load_game failed in world state test")
		quit(1)
		return false
	if not bool(ws.call("get_flag", TERM_ID, "powered", false)):
		push_error("poi_worldstate_smoke: powered flag not restored from save")
		quit(1)
		return false
	if not bool(ws.call("get_flag", PICK_ID, "collected", false)):
		push_error("poi_worldstate_smoke: collected flag not restored from save")
		quit(1)
		return false

	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	terminal = vp.find_child("ViewpointTerminal", true, false)
	scrap = vp.find_child("ScrapMetalPickup", true, false)
	if str(terminal.call("get_state_name")) != "ON" or not bool(scrap.call("is_collected")):
		push_error("poi_worldstate_smoke: scene after save/load did not restore terminal/pickup")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	save.call("delete_save")
	clear_world_state()
	inv.call("clear_inventory")
	print("poi_worldstate_smoke: world_state OK (reload + save round-trip terminal/pickup)")
	return true



func _verify_viewpoint_terminal(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Terminal starts OFF and refuses to power without an active quest turn-in.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	if poi_sys == null:
		push_error("poi_worldstate_smoke: POISystem missing for viewpoint terminal")
		quit(1)
		return false
	if qs != null and qs.has_method("reset_all"):
		qs.call("reset_all")
	clear_world_state()

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("poi_worldstate_smoke: could not load sunset viewpoint resources")
		quit(1)
		return false

	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(-6.0, 0.0, -4.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("poi_worldstate_smoke: failed to spawn viewpoint for terminal test")
		quit(1)
		return false

	var terminal: Node = vp.find_child("ViewpointTerminal", true, false)
	if terminal == null or not (terminal is Node3D):
		push_error("poi_worldstate_smoke: ViewpointTerminal not found after spawn")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "OFF":
		push_error("poi_worldstate_smoke: ViewpointTerminal expected OFF at spawn")
		quit(1)
		return false
	if not bool(terminal.call("can_interact", character)):
		push_error("poi_worldstate_smoke: ViewpointTerminal should allow interact while OFF")
		quit(1)
		return false

	# Without quest / items, interact must fail and stay OFF.
	if bool(terminal.call("interact", character)):
		push_error("poi_worldstate_smoke: terminal powered without quest turn-in")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "OFF":
		push_error("poi_worldstate_smoke: terminal left OFF expected after rejected interact")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("poi_worldstate_smoke: viewpoint terminal OK (gated OFF without quest)")
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
		push_error("poi_worldstate_smoke: ConditionSystem/GameFlags/SaveSystem missing")
		quit(1)
		return false

	# No quest-specific branching inside ConditionSystem.
	var cond_script: Script = load("res://autoload/condition_system.gd") as Script
	if cond_script != null:
		var src := cond_script.source_code
		for banned in ["power_the_viewpoint", "mira_quest", "Mira"]:
			if src.find(banned) >= 0:
				push_error("poi_worldstate_smoke: ConditionSystem must not hardcode '%s'" % banned)
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
	clear_world_state()

	# FLAG_EQUALS
	flags.call("set_flag", "smoke_flag_a", true)
	if not bool(cond.call("evaluate", cond.call("make_flag_equals", "smoke_flag_a", true))):
		push_error("poi_worldstate_smoke: FLAG_EQUALS true failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_flag_equals", "smoke_flag_a", false))):
		push_error("poi_worldstate_smoke: FLAG_EQUALS expected false should fail")
		quit(1)
		return false
	# Unset flag + expected false = true (system present, value false).
	if not bool(cond.call("evaluate", cond.call("make_flag_equals", "never_set_smoke_flag", false))):
		push_error("poi_worldstate_smoke: FLAG_EQUALS false should pass when flag unset (system present)")
		quit(1)
		return false

	# Fail-closed: missing peer ≠ "value is false/true".
	if cond.has_method("debug_force_peer_missing"):
		cond.call("debug_clear_missing_log")
		cond.call("debug_force_peer_missing", "/root/GameFlags")
		if bool(cond.call("evaluate", cond.call("make_flag_equals", "smoke_flag_a", false))):
			push_error("poi_worldstate_smoke: FLAG_EQUALS false must be false when GameFlags missing")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_flag_equals", "smoke_flag_a", true))):
			push_error("poi_worldstate_smoke: FLAG_EQUALS true must be false when GameFlags missing")
			quit(1)
			return false
		cond.call("debug_clear_peer_overrides")

		var ns_cond: Node = root.get_node_or_null("NpcStateSystem")
		if ns_cond != null:
			cond.call("debug_force_peer_missing", "/root/NpcStateSystem")
			if bool(cond.call("evaluate", cond.call("make_npc_met", "mira_viewpoint_keeper", false))):
				push_error("poi_worldstate_smoke: NPC_MET false must be false when NpcStateSystem missing")
				quit(1)
				return false
			if bool(cond.call("evaluate", cond.call("make_npc_enabled", "mira_viewpoint_keeper", true))):
				push_error("poi_worldstate_smoke: NPC_ENABLED true must be false when NpcStateSystem missing")
				quit(1)
				return false
			cond.call("debug_clear_peer_overrides")
			# System present: expected false/true vs actual values.
			ns_cond.call("reset_for_tests")
			if not bool(cond.call("evaluate", cond.call("make_npc_met", "mira_viewpoint_keeper", false))):
				push_error("poi_worldstate_smoke: NPC_MET false should pass when unmet (system present)")
				quit(1)
				return false
			if not bool(cond.call("evaluate", cond.call("make_npc_enabled", "mira_viewpoint_keeper", true))):
				push_error("poi_worldstate_smoke: NPC_ENABLED true should pass by default (system present)")
				quit(1)
				return false

	# Nonexistent / empty ids → false.
	if bool(cond.call("evaluate", cond.call("make_flag_equals", "", true))):
		push_error("poi_worldstate_smoke: empty flag_id must fail closed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_quest_state", "no_such_quest_zzz", "ACTIVE"))):
		push_error("poi_worldstate_smoke: nonexistent quest id must fail closed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_has_item", "no_such_item_zzz", 1))):
		push_error("poi_worldstate_smoke: nonexistent item id must fail closed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_dialogue_seen", "no_such_dialogue_zzz"))):
		push_error("poi_worldstate_smoke: nonexistent dialogue id must fail closed")
		quit(1)
		return false

	# Invalid / unknown type → false.
	var bogus: Resource = cond.call("make", -999, "x")
	if bool(cond.call("evaluate", bogus)):
		push_error("poi_worldstate_smoke: unknown condition type must fail closed")
		quit(1)
		return false

	# Empty ALL / ANY semantics; null entry in ALL fails.
	if not bool(cond.call("evaluate_all", [])):
		push_error("poi_worldstate_smoke: evaluate_all([]) must be true")
		quit(1)
		return false
	if bool(cond.call("evaluate_any", [])):
		push_error("poi_worldstate_smoke: evaluate_any([]) must be false")
		quit(1)
		return false
	if bool(cond.call("evaluate_all", [null])):
		push_error("poi_worldstate_smoke: evaluate_all([null]) must be false")
		quit(1)
		return false
	if bool(cond.call("evaluate_any", [null])):
		push_error("poi_worldstate_smoke: evaluate_any([null]) must be false")
		quit(1)
		return false
	# null condition resource alone remains vacuous true (no gate authored).
	if not bool(cond.call("evaluate", null)):
		push_error("poi_worldstate_smoke: evaluate(null) must stay vacuous true")
		quit(1)
		return false

	# QUEST_STATE
	if qs != null:
		if bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "COMPLETED"))):
			push_error("poi_worldstate_smoke: QUEST_STATE COMPLETED should be false initially")
			quit(1)
			return false
		qs.call("start_quest", "power_the_viewpoint")
		if not bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"))):
			push_error("poi_worldstate_smoke: QUEST_STATE ACTIVE failed")
			quit(1)
			return false

	# HAS_ITEM / ITEM_QUANTITY
	if inv != null:
		inv.call("add_item", "scrap_metal", 3)
		if not bool(cond.call("evaluate", cond.call("make_has_item", "scrap_metal", 1))):
			push_error("poi_worldstate_smoke: HAS_ITEM failed")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_item_quantity", "scrap_metal", 3))):
			push_error("poi_worldstate_smoke: ITEM_QUANTITY >=3 failed")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_item_quantity", "scrap_metal", 4))):
			push_error("poi_worldstate_smoke: ITEM_QUANTITY >=4 should fail")
			quit(1)
			return false

	# POI_DISCOVERED
	if poi != null:
		if poi.has_method("clear_discovery_for_tests"):
			poi.call("clear_discovery_for_tests")
		if bool(cond.call("evaluate", cond.call("make_poi_discovered", "sunset_viewpoint"))):
			push_error("poi_worldstate_smoke: POI_DISCOVERED should be false after clear")
			quit(1)
			return false
		poi.call("mark_discovered", "sunset_viewpoint", "Sunset Viewpoint")
		if not bool(cond.call("evaluate", cond.call("make_poi_discovered", "sunset_viewpoint"))):
			push_error("poi_worldstate_smoke: POI_DISCOVERED failed")
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
			push_error("poi_worldstate_smoke: WORLD_STATE_EQUALS failed")
			quit(1)
			return false

	# VEHICLE_HAS_UPGRADE
	if vs != null:
		if bool(cond.call("evaluate", cond.call("make_vehicle_has_upgrade", "cruise_module_mk1"))):
			push_error("poi_worldstate_smoke: VEHICLE_HAS_UPGRADE should be false after reset")
			quit(1)
			return false
		vs.call("install_upgrade", "cruise_module_mk1")
		if not bool(cond.call("evaluate", cond.call("make_vehicle_has_upgrade", "cruise_module_mk1"))):
			push_error("poi_worldstate_smoke: VEHICLE_HAS_UPGRADE failed")
			quit(1)
			return false

	# REGION_IS
	if regions != null:
		var region_id := str(regions.call("get_current_region_id"))
		if region_id.is_empty():
			push_error("poi_worldstate_smoke: current region id empty")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_region_is", region_id))):
			push_error("poi_worldstate_smoke: REGION_IS failed for %s" % region_id)
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_region_is", "NOT_A_REAL_REGION"))):
			push_error("poi_worldstate_smoke: REGION_IS should fail for unknown region")
			quit(1)
			return false

	# JOURNEY_DISTANCE_MIN / MAX
	if journey != null:
		journey.call("set_current_distance_km", 50.0)
		if not bool(cond.call("evaluate", cond.call("make_journey_distance_min", 40.0))):
			push_error("poi_worldstate_smoke: JOURNEY_DISTANCE_MIN failed")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_journey_distance_min", 60.0))):
			push_error("poi_worldstate_smoke: JOURNEY_DISTANCE_MIN 60 should fail at 50")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_journey_distance_max", 60.0))):
			push_error("poi_worldstate_smoke: JOURNEY_DISTANCE_MAX failed")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_journey_distance_max", 40.0))):
			push_error("poi_worldstate_smoke: JOURNEY_DISTANCE_MAX 40 should fail at 50")
			quit(1)
			return false

	# NARRATIVE_* conditions (world clock — never system/play hour).
	var gt_cond: Node = root.get_node_or_null("GameTimeSystem")
	if gt_cond != null and gt_cond.has_method("set_narrative_time"):
		gt_cond.call("set_narrative_time", 1, 10, 0)
		if not bool(cond.call("evaluate", cond.call("make_narrative_hour_min", 8))):
			push_error("poi_worldstate_smoke: NARRATIVE_HOUR_MIN 8 should pass at hour 10")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_narrative_hour_max", 17))):
			push_error("poi_worldstate_smoke: NARRATIVE_HOUR_MAX 17 should pass at hour 10")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_narrative_hour_min", 18))):
			push_error("poi_worldstate_smoke: NARRATIVE_HOUR_MIN 18 should fail at hour 10")
			quit(1)
			return false
		if not bool(cond.call("evaluate", cond.call("make_narrative_day_min", 1))):
			push_error("poi_worldstate_smoke: NARRATIVE_DAY_MIN 1 should pass on day 1")
			quit(1)
			return false
		if bool(cond.call("evaluate", cond.call("make_narrative_day_max", 0))):
			push_error("poi_worldstate_smoke: NARRATIVE_DAY_MAX 0 should fail on day 1")
			quit(1)
			return false
		# Cross-midnight range 22:00–06:00.
		gt_cond.call("set_narrative_time", 0, 23, 0)
		if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
			push_error("poi_worldstate_smoke: NARRATIVE_TIME_RANGE 22–6 should pass at 23:00")
			quit(1)
			return false
		gt_cond.call("set_narrative_time", 0, 3, 0)
		if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
			push_error("poi_worldstate_smoke: NARRATIVE_TIME_RANGE 22–6 should pass at 03:00")
			quit(1)
			return false
		gt_cond.call("set_narrative_time", 0, 12, 0)
		if bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
			push_error("poi_worldstate_smoke: NARRATIVE_TIME_RANGE 22–6 should fail at 12:00")
			quit(1)
			return false
		gt_cond.call("reset_for_tests")

	# ALL / ANY composites
	var pass_a: Resource = cond.call("make_flag_equals", "smoke_flag_a", true)
	var pass_b: Resource = cond.call("make_journey_distance_min", 10.0)
	var fail_c: Resource = cond.call("make_flag_equals", "missing_flag", true)
	if not bool(cond.call("evaluate_all", [pass_a, pass_b])):
		push_error("poi_worldstate_smoke: evaluate_all should pass")
		quit(1)
		return false
	if bool(cond.call("evaluate_all", [pass_a, fail_c])):
		push_error("poi_worldstate_smoke: evaluate_all should fail when one fails")
		quit(1)
		return false
	if not bool(cond.call("evaluate_all", [])):
		push_error("poi_worldstate_smoke: evaluate_all empty should be true")
		quit(1)
		return false
	if not bool(cond.call("evaluate_any", [fail_c, pass_a])):
		push_error("poi_worldstate_smoke: evaluate_any should pass if one passes")
		quit(1)
		return false
	if bool(cond.call("evaluate_any", [fail_c])):
		push_error("poi_worldstate_smoke: evaluate_any should fail when all fail")
		quit(1)
		return false
	if bool(cond.call("evaluate_any", [])):
		push_error("poi_worldstate_smoke: evaluate_any empty should be false")
		quit(1)
		return false

	# Flags persist via SaveSystem.
	flags.call("set_flag", "persist_me", true)
	flags.call("set_flag", "persist_false", false)
	if save.has_method("delete_save"):
		save.call("delete_save")
	if not bool(save.call("save_game")):
		push_error("poi_worldstate_smoke: save_game failed for flags")
		quit(1)
		return false
	flags.call("reset_for_tests")
	if bool(flags.call("has_flag", "persist_me")):
		push_error("poi_worldstate_smoke: flags should clear on reset")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("poi_worldstate_smoke: load_game failed for flags")
		quit(1)
		return false
	if not bool(flags.call("get_flag", "persist_me", false)):
		push_error("poi_worldstate_smoke: persist_me flag not restored")
		quit(1)
		return false
	if bool(flags.call("get_flag", "persist_false", true)):
		push_error("poi_worldstate_smoke: persist_false should restore as false")
		quit(1)
		return false

	# Mira contextual dialogue via priority rules when quest COMPLETED.
	if qs != null:
		qs.call("reset_all")
		qs.call("start_quest", "power_the_viewpoint")
		qs.call("complete_quest", "power_the_viewpoint")
		if not bool(cond.call("evaluate", cond.call("make_quest_state", "power_the_viewpoint", "COMPLETED"))):
			push_error("poi_worldstate_smoke: QUEST_STATE COMPLETED after complete_quest")
			quit(1)
			return false

	var mira_def: Resource = load("res://resources/npc/mira_viewpoint_keeper.tres")
	if mira_def == null or not ("dialogue_rules" in mira_def):
		push_error("poi_worldstate_smoke: Mira missing dialogue_rules")
		quit(1)
		return false
	if (mira_def.dialogue_rules as Array).is_empty():
		push_error("poi_worldstate_smoke: Mira dialogue_rules empty")
		quit(1)
		return false
	if dlg == null or not dlg.has_method("resolve_dialogue_for_npc"):
		push_error("poi_worldstate_smoke: DialogueSystem.resolve_dialogue_for_npc missing")
		quit(1)
		return false
	dlg.call("register_npc_definition", mira_def)
	var resolved := str(dlg.call("resolve_dialogue_for_npc", "mira_viewpoint_keeper"))
	if resolved != "mira_quest_done_01":
		push_error("poi_worldstate_smoke: expected mira_quest_done_01 from NPC rules, got %s" % resolved)
		quit(1)
		return false

	# Live NPC in scene (if present) should also report completed dialogue.
	var mira: Node = root.find_child("Mira", true, false)
	if mira != null and mira.has_method("get_dialogue_id"):
		if str(mira.call("get_dialogue_id")) != "mira_quest_done_01":
			push_error(
				"poi_worldstate_smoke: Mira get_dialogue_id should be mira_quest_done_01 when COMPLETED (got %s)"
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
	clear_world_state()
	print("poi_worldstate_smoke: conditions OK (types + ALL/ANY + flags save + Mira COMPLETED gate)")
	return true



func _verify_small_interior(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Walk-in Observation Booth: enter, interact inside, exit; parked car stays put.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if poi_sys == null:
		push_error("poi_worldstate_smoke: POISystem missing for interior test")
		quit(1)
		return false
	clear_world_state()

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("poi_worldstate_smoke: could not load viewpoint resources for interior")
		quit(1)
		return false

	var parked_origin: Vector3 = _vehicle.global_position
	var recenter_before: int = int(_recenter.call("get_recenter_count")) if _recenter != null else 0
	# Keep the platform clear of the parked car so collision does not disturb the stop.
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(14.0, 0.0, -6.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("poi_worldstate_smoke: failed to spawn viewpoint for interior")
		quit(1)
		return false

	var booth: Node3D = vp.find_child("ObservationBooth", true, false) as Node3D
	if booth == null:
		booth = vp.find_child("SmallInterior", true, false) as Node3D
	if booth == null or not booth.has_method("get_interior_stand_position"):
		push_error("poi_worldstate_smoke: ObservationBooth missing methods")
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
		push_error("poi_worldstate_smoke: player not detected inside ObservationBooth")
		quit(1)
		return false
	if int(enter_signals["n"]) < 1:
		push_error("poi_worldstate_smoke: player_entered_interior did not fire")
		quit(1)
		return false
	if foot_cam.has_method("is_interior_active") and not bool(foot_cam.call("is_interior_active")):
		push_error("poi_worldstate_smoke: on-foot camera not in interior mode")
		quit(1)
		return false

	# Interact with Observation Log inside.
	var obs_log: Node = booth.call("get_observation_log")
	if obs_log == null or not obs_log.has_method("interact"):
		push_error("poi_worldstate_smoke: ObservationLog missing inside booth")
		quit(1)
		return false
	if not bool(obs_log.call("interact", character)):
		push_error("poi_worldstate_smoke: ObservationLog interact failed")
		quit(1)
		return false
	if int(obs_log.get_meta("interact_count", 0)) < 1:
		push_error("poi_worldstate_smoke: ObservationLog interact_count not updated")
		quit(1)
		return false

	# Walk out.
	character.global_position = booth.call("get_doorway_exterior_position")
	for _j in range(16):
		await physics_frame
	if bool(booth.call("is_player_inside")):
		push_error("poi_worldstate_smoke: player still inside after walking out")
		quit(1)
		return false
	if int(exit_signals["n"]) < 1:
		push_error("poi_worldstate_smoke: player_exited_interior did not fire")
		quit(1)
		return false
	if foot_cam.has_method("is_interior_active") and bool(foot_cam.call("is_interior_active")):
		push_error("poi_worldstate_smoke: camera still in interior mode outdoors")
		quit(1)
		return false

	# Parked car must remain parked; absolute move is OK only if origin recentered.
	var recenter_after: int = int(_recenter.call("get_recenter_count")) if _recenter != null else 0
	if not bool(_vehicle.call("is_parked")):
		push_error("poi_worldstate_smoke: vehicle left PARKED during interior explore")
		quit(1)
		return false
	if recenter_after == recenter_before:
		if parked_origin.distance_to(_vehicle.global_position) > 0.5:
			push_error("poi_worldstate_smoke: parked vehicle drifted without origin recenter")
			quit(1)
			return false

	booth.player_entered_interior.disconnect(on_enter)
	booth.player_exited_interior.disconnect(on_exit)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("poi_worldstate_smoke: small interior OK (walk-in → interact → walk-out, car stayed)")
	return true



func _verify_side_quest(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Power the Viewpoint: Mira offer → ACTIVE → gather → terminal turn-in → COMPLETED once.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	if poi_sys == null or dlg == null or inv == null or qs == null:
		push_error("poi_worldstate_smoke: missing systems for side quest")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	clear_world_state()
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
		push_error("poi_worldstate_smoke: viewpoint spawn failed for quest")
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
		push_error("poi_worldstate_smoke: quest scene nodes missing")
		quit(1)
		return false
	var quest_scrap_available := (
		int(scrap_a.call("get_quantity"))
		+ int(scrap_b.call("get_quantity"))
		+ int(scrap_c.call("get_quantity"))
	)
	if quest_scrap_available < 3 or int(wire.call("get_quantity")) < 1:
		push_error(
			"poi_worldstate_smoke: viewpoint collectibles insufficient for quest (scrap=%d wire=%d)"
			% [quest_scrap_available, int(wire.call("get_quantity"))]
		)
		quit(1)
		return false

	if str(qs.call("get_state_name", "power_the_viewpoint")) != "INACTIVE":
		push_error("poi_worldstate_smoke: quest should start INACTIVE")
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
		push_error("poi_worldstate_smoke: Mira offer interact failed")
		quit(1)
		return false
	await physics_frame
	# Advance offer sequence to completion.
	while bool(dlg.call("is_active")):
		dlg.call("advance")
		await physics_frame
	if not bool(qs.call("is_active", "power_the_viewpoint")):
		push_error("poi_worldstate_smoke: quest not ACTIVE after Mira offer")
		quit(1)
		return false
	if rel_quest != null and int(rel_quest.call("get_relationship", "mira_viewpoint_keeper")) != 5:
		push_error(
			"poi_worldstate_smoke: accept_help should grant +5 Mira relationship (got %d)"
			% int(rel_quest.call("get_relationship", "mira_viewpoint_keeper"))
		)
		quit(1)
		return false

	# Terminal without items should fail.
	if bool(terminal.call("interact", character)):
		push_error("poi_worldstate_smoke: terminal turn-in succeeded without items")
		quit(1)
		return false
	if str(terminal.call("get_state_name")) != "OFF":
		push_error("poi_worldstate_smoke: terminal should stay OFF without items")
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
			push_error("poi_worldstate_smoke: quest pickup collect failed (%s)" % pickup.name)
			quit(1)
			return false
		await physics_frame

	if not bool(qs.call("has_required_items", "power_the_viewpoint")):
		push_error(
			"poi_worldstate_smoke: missing required items after pickups (scrap=%d wire=%d)"
			% [int(inv.call("get_quantity", "scrap_metal")), int(inv.call("get_quantity", "copper_wire"))]
		)
		quit(1)
		return false
	# Quest consumes only 3 scrap + 1 wire; outdoor scrap leaves overflow.
	if int(inv.call("get_quantity", "scrap_metal")) < 3:
		push_error("poi_worldstate_smoke: expected ≥3 scrap after collecting all viewpoint pickups")
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
		push_error("poi_worldstate_smoke: terminal quest turn-in failed")
		quit(1)
		return false
	await physics_frame
	if str(terminal.call("get_state_name")) != "ON":
		push_error("poi_worldstate_smoke: terminal not ON after turn-in")
		quit(1)
		return false
	if not bool(qs.call("is_completed", "power_the_viewpoint")):
		push_error("poi_worldstate_smoke: quest not COMPLETED after turn-in")
		quit(1)
		return false
	if int(completed_n["n"]) < 1:
		push_error("poi_worldstate_smoke: quest_completed signal missing")
		quit(1)
		return false
	if rel_quest != null and int(rel_quest.call("get_reputation", "sunset_viewpoint")) != 10:
		push_error(
			"poi_worldstate_smoke: quest complete should grant +10 sunset_viewpoint reputation (got %d)"
			% int(rel_quest.call("get_reputation", "sunset_viewpoint"))
		)
		quit(1)
		return false
	# Quest need is 3 scrap + 1 wire; outdoor scrap leaves overflow.
	if int(inv.call("get_quantity", "scrap_metal")) != quest_scrap_available - 3:
		push_error(
			"poi_worldstate_smoke: scrap not consumed correctly on turn-in (left=%d expected=%d)"
			% [int(inv.call("get_quantity", "scrap_metal")), quest_scrap_available - 3]
		)
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 0:
		push_error("poi_worldstate_smoke: copper wire not consumed on turn-in")
		quit(1)
		return false

	# 4) Re-interact must not duplicate reward/consumption.
	if bool(terminal.call("interact", character)):
		push_error("poi_worldstate_smoke: terminal interacted again after COMPLETED")
		quit(1)
		return false
	if not bool(qs.call("try_turn_in", "power_the_viewpoint")):
		pass  # expected false
	else:
		push_error("poi_worldstate_smoke: try_turn_in succeeded twice")
		quit(1)
		return false
	var scrap_before_dup := int(inv.call("get_quantity", "scrap_metal"))
	if int(inv.call("add_item", "scrap_metal", 3)) != 3:
		push_error("poi_worldstate_smoke: could not re-add scrap for duplicate check")
		quit(1)
		return false
	# Even with items again, completed quest must not consume/re-complete.
	if bool(qs.call("try_turn_in", "power_the_viewpoint")):
		push_error("poi_worldstate_smoke: completed quest consumed items again")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != scrap_before_dup + 3:
		push_error("poi_worldstate_smoke: completed quest altered scrap after duplicate try_turn_in")
		quit(1)
		return false

	qs.quest_completed.disconnect(on_done)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	inv.call("clear_inventory")
	qs.call("reset_all")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("poi_worldstate_smoke: side quest OK (offer → gather → turn-in → COMPLETED once)")
	return true



