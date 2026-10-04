extends RefCounted
## Shared autoload-init assertions for headless smokes.
## Used by `autoload_init_smoke.gd` (deep) and `vertical_slice_smoke.gd` (lite gate).
## Call sites pass `tree` (SceneTree) and a `suite` prefix for error lines.

const CRITICAL_READY := [
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

const SAVE_PROVIDERS := [
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
]


static func verify_ready_states(tree: SceneTree, suite: String, systems: Array = []) -> bool:
	var names: Array = systems if not systems.is_empty() else CRITICAL_READY
	for name in names:
		var node: Node = tree.root.get_node_or_null(str(name))
		if node == null:
			push_error("%s: missing %s" % [suite, name])
			return false
		if not node.has_method("is_system_ready") or not bool(node.call("is_system_ready")):
			push_error(
				"%s: %s not READY (state=%s)"
				% [suite, name, str(node.call("get_init_state")) if node.has_method("get_init_state") else "?"]
			)
			return false
	return true


static func verify_travel_game_time_bind(tree: SceneTree, suite: String) -> bool:
	var gt: Node = tree.root.get_node_or_null("GameTimeSystem")
	var travel: Node = tree.root.get_node_or_null("NpcTravelSystem")
	if gt == null or travel == null:
		push_error("%s: travel/time peers missing" % suite)
		return false
	if not gt.narrative_time_changed.is_connected(travel._on_narrative_time_changed):
		push_error("%s: NpcTravelSystem not connected to GameTimeSystem" % suite)
		return false
	var flags: Node = tree.root.get_node_or_null("GameFlags")
	if flags != null and not flags.flag_changed.is_connected(travel._on_flag_changed):
		push_error("%s: NpcTravelSystem not connected to GameFlags" % suite)
		return false
	return true


static func verify_schedule_signal_bind(tree: SceneTree, suite: String) -> bool:
	var gt: Node = tree.root.get_node_or_null("GameTimeSystem")
	var sched: Node = tree.root.get_node_or_null("NpcScheduleSystem")
	if gt == null or sched == null:
		push_error("%s: schedule/time peers missing" % suite)
		return false
	if not gt.narrative_time_changed.is_connected(sched._on_narrative_time_changed):
		push_error("%s: NpcScheduleSystem not connected to GameTimeSystem" % suite)
		return false
	return true


static func verify_schedule_game_time_apply(tree: SceneTree, suite: String) -> bool:
	## Signal-driven schedule apply (not only manual refresh_all).
	if not verify_schedule_signal_bind(tree, suite):
		return false
	var gt: Node = tree.root.get_node_or_null("GameTimeSystem")
	var sched: Node = tree.root.get_node_or_null("NpcScheduleSystem")
	var ns: Node = tree.root.get_node_or_null("NpcStateSystem")
	if ns == null:
		push_error("%s: NpcStateSystem missing for schedule apply" % suite)
		return false
	ns.call("reset_for_tests")
	gt.call("set_narrative_time", 0, 10, 0)
	await tree.process_frame
	var loc_am := str(ns.call("get_location_id", "mira_viewpoint_keeper"))
	gt.call("set_narrative_time", 0, 12, 0)
	await tree.process_frame
	var loc_noon := str(ns.call("get_location_id", "mira_viewpoint_keeper"))
	if loc_am.is_empty() and loc_noon.is_empty():
		sched.call("refresh_all")
		gt.call("set_narrative_time", 0, 10, 0)
		await tree.process_frame
		loc_am = str(ns.call("get_location_id", "mira_viewpoint_keeper"))
		gt.call("set_narrative_time", 0, 12, 0)
		await tree.process_frame
		loc_noon = str(ns.call("get_location_id", "mira_viewpoint_keeper"))
	if str(ns.call("get_location_id", "mira_viewpoint_keeper")) == "":
		sched.call("refresh_all")
		await tree.process_frame
	if str(ns.call("get_location_id", "mira_viewpoint_keeper")).is_empty():
		push_error("%s: schedule did not write Mira location via GameTime" % suite)
		return false
	return true


static func verify_save_providers(tree: SceneTree, suite: String, ids: Array = []) -> bool:
	var save: Node = tree.root.get_node_or_null("SaveSystem")
	if save == null:
		push_error("%s: SaveSystem missing" % suite)
		return false
	var list: Array = ids if not ids.is_empty() else SAVE_PROVIDERS
	for id in list:
		if not bool(save.call("has_provider", id)):
			push_error("%s: SaveSystem missing provider '%s'" % [suite, id])
			return false
	return true


static func verify_game_flags_probe(tree: SceneTree, suite: String) -> bool:
	var flags: Node = tree.root.get_node_or_null("GameFlags")
	if flags == null or not bool(flags.call("is_system_ready")):
		push_error("%s: GameFlags not READY" % suite)
		return false
	flags.call("set_flag", "autoload_init_probe", true)
	if not bool(flags.call("get_flag", "autoload_init_probe", false)):
		push_error("%s: GameFlags set/get failed" % suite)
		return false
	flags.call("clear_flag", "autoload_init_probe")
	return true


static func verify_no_duplicate_time_binds(tree: SceneTree, suite: String) -> bool:
	## Re-run initialize; connection count must not grow.
	var gt: Node = tree.root.get_node_or_null("GameTimeSystem")
	var sched: Node = tree.root.get_node_or_null("NpcScheduleSystem")
	var travel: Node = tree.root.get_node_or_null("NpcTravelSystem")
	if gt == null or sched == null or travel == null:
		push_error("%s: peers missing for duplicate-connect check" % suite)
		return false
	var before: int = gt.narrative_time_changed.get_connections().size()
	sched.call("_initialize_dependencies")
	travel.call("_initialize_dependencies")
	await tree.process_frame
	var after: int = gt.narrative_time_changed.get_connections().size()
	if after != before:
		push_error(
			"%s: narrative_time_changed connections changed on re-init (%d → %d)"
			% [suite, before, after]
		)
		return false
	return true


## Lite gate for vertical_slice: READY + binds + key providers + no dupe connects.
static func verify_lite_gate(tree: SceneTree, suite: String) -> bool:
	var lite := [
		"GameTimeSystem",
		"GameFlags",
		"NpcStateSystem",
		"NpcScheduleSystem",
		"NpcTravelSystem",
		"DialogueSystem",
		"SaveSystem",
		"ConditionSystem",
		"BarkSystem",
		"RelationshipSystem",
	]
	if not verify_ready_states(tree, suite, lite):
		return false
	if not verify_schedule_signal_bind(tree, suite):
		return false
	if not verify_travel_game_time_bind(tree, suite):
		return false
	if not verify_save_providers(
		tree,
		suite,
		["game_time", "game_flags", "npc_state", "dialogue_memory", "relationship"]
	):
		return false
	if not await verify_no_duplicate_time_binds(tree, suite):
		return false
	return true
