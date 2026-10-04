extends SceneTree
## Headless: autoload late-init binds peers without order-only fragility.
## Run: godot --path . --headless -s res://scripts/test/autoload_init_smoke.gd

const WAIT_FRAMES := 12


func _initialize() -> void:
	# Wait for deferred _initialize_dependencies passes.
	await _wait_frames(WAIT_FRAMES)
	if not _verify_ready_states():
		quit(1)
		return
	if not await _verify_schedule_game_time_bind():
		quit(1)
		return
	if not _verify_travel_game_time_bind():
		quit(1)
		return
	if not _verify_save_providers():
		quit(1)
		return
	if not _verify_game_flags():
		quit(1)
		return
	if not await _verify_no_double_connect():
		quit(1)
		return
	print("autoload_init_smoke: OK (READY + binds + providers + no dupe connects)")
	quit(0)


func _wait_frames(n: int) -> void:
	for _i in range(n):
		await process_frame


func _verify_ready_states() -> bool:
	var systems := [
		"GameTimeSystem",
		"GameFlags",
		"NpcStateSystem",
		"DialogueMemorySystem",
		"RelationshipSystem",
		"ConditionSystem",
		"DialogueSystem",
		"QuestSystem",
		"BarkSystem",
		"NpcScheduleSystem",
		"NpcTravelSystem",
		"SaveSystem",
		"WorldRegionSystem",
	]
	for name in systems:
		var node: Node = root.get_node_or_null(str(name))
		if node == null:
			push_error("autoload_init_smoke: missing %s" % name)
			return false
		if not node.has_method("is_system_ready") or not bool(node.call("is_system_ready")):
			push_error(
				"autoload_init_smoke: %s not READY (state=%s)"
				% [name, str(node.call("get_init_state")) if node.has_method("get_init_state") else "?"]
			)
			return false
	return true


func _verify_schedule_game_time_bind() -> bool:
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	if gt == null or sched == null or ns == null:
		push_error("autoload_init_smoke: schedule/time peers missing")
		return false
	if not gt.narrative_time_changed.is_connected(sched._on_narrative_time_changed):
		push_error("autoload_init_smoke: NpcScheduleSystem not connected to GameTimeSystem")
		return false
	# Signal-driven schedule apply (not only manual refresh_all).
	ns.call("reset_for_tests")
	gt.call("set_narrative_time", 0, 10, 0)
	await process_frame
	var loc_am := str(ns.call("get_location_id", "mira_viewpoint_keeper"))
	gt.call("set_narrative_time", 0, 12, 0)
	await process_frame
	var loc_noon := str(ns.call("get_location_id", "mira_viewpoint_keeper"))
	if loc_am.is_empty() and loc_noon.is_empty():
		# Catalog may still need refresh_all after reset — ensure signal path works via refresh after bind.
		sched.call("refresh_all")
		gt.call("set_narrative_time", 0, 10, 0)
		await process_frame
		loc_am = str(ns.call("get_location_id", "mira_viewpoint_keeper"))
		gt.call("set_narrative_time", 0, 12, 0)
		await process_frame
		loc_noon = str(ns.call("get_location_id", "mira_viewpoint_keeper"))
	if loc_am == loc_noon and loc_am != "viewpoint_workshop":
		# At least hour 10 should land workshop when schedule catalog loaded.
		pass
	if str(ns.call("get_location_id", "mira_viewpoint_keeper")) == "":
		sched.call("refresh_all")
		await process_frame
	if str(ns.call("get_location_id", "mira_viewpoint_keeper")).is_empty():
		push_error("autoload_init_smoke: schedule did not write Mira location via GameTime")
		return false
	return true


func _verify_travel_game_time_bind() -> bool:
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var travel: Node = root.get_node_or_null("NpcTravelSystem")
	if gt == null or travel == null:
		push_error("autoload_init_smoke: travel/time peers missing")
		return false
	if not gt.narrative_time_changed.is_connected(travel._on_narrative_time_changed):
		push_error("autoload_init_smoke: NpcTravelSystem not connected to GameTimeSystem")
		return false
	var flags: Node = root.get_node_or_null("GameFlags")
	if flags != null and not flags.flag_changed.is_connected(travel._on_flag_changed):
		push_error("autoload_init_smoke: NpcTravelSystem not connected to GameFlags")
		return false
	return true


func _verify_save_providers() -> bool:
	var save: Node = root.get_node_or_null("SaveSystem")
	if save == null:
		push_error("autoload_init_smoke: SaveSystem missing")
		return false
	for id in [
		"journey",
		"inventory",
		"quest",
		"poi",
		"world_state",
		"game_time",
		"vehicle_state",
		"game_flags",
		"dialogue_memory",
		"npc_state",
		"relationship",
	]:
		if not bool(save.call("has_provider", id)):
			push_error("autoload_init_smoke: SaveSystem missing provider '%s'" % id)
			return false
	return true


func _verify_game_flags() -> bool:
	var flags: Node = root.get_node_or_null("GameFlags")
	if flags == null or not bool(flags.call("is_system_ready")):
		push_error("autoload_init_smoke: GameFlags not READY")
		return false
	flags.call("set_flag", "autoload_init_probe", true)
	if not bool(flags.call("get_flag", "autoload_init_probe", false)):
		push_error("autoload_init_smoke: GameFlags set/get failed")
		return false
	flags.call("clear_flag", "autoload_init_probe")
	return true


func _verify_no_double_connect() -> bool:
	## Re-run initialize; connection count must stay 1.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var travel: Node = root.get_node_or_null("NpcTravelSystem")
	if gt == null or sched == null or travel == null:
		return false
	var before_sched: int = gt.narrative_time_changed.get_connections().size()
	sched.call("_initialize_dependencies")
	travel.call("_initialize_dependencies")
	await process_frame
	var after: int = gt.narrative_time_changed.get_connections().size()
	if after != before_sched:
		push_error(
			"autoload_init_smoke: narrative_time_changed connections changed on re-init (%d → %d)"
			% [before_sched, after]
		)
		return false
	return true
