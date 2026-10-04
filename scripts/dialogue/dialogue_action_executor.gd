extends RefCounted
class_name DialogueActionExecutor
## Applies DialogueAction resources to the responsible gameplay systems.
## DialogueSystem coordinates when; this service owns the type dispatch.
## Fail-soft: missing systems / ids warn and return false — never crash.

signal action_executed(action: Resource, ok: bool)
signal action_failed(action: Resource, reason: String)


func execute_all(actions: Array) -> void:
	if actions.is_empty():
		return
	for entry in actions:
		if entry == null:
			continue
		execute(entry)


func execute(action: Resource) -> bool:
	if action == null:
		return false
	var type_value := int(action.get("type"))
	var target_id := str(action.get("target_id"))
	var ok := false
	var reason := ""

	match type_value:
		DialogueAction.Type.SET_FLAG:
			ok = _set_flag(target_id, bool(action.get("bool_value")))
			if not ok:
				reason = "set_flag_failed"
		DialogueAction.Type.START_QUEST:
			ok = _start_quest(target_id)
			if not ok:
				reason = "start_quest_failed"
		DialogueAction.Type.COMPLETE_QUEST:
			ok = _complete_quest(target_id)
			if not ok:
				reason = "complete_quest_failed"
		DialogueAction.Type.ADD_ITEM:
			ok = _add_item(target_id, int(action.get("int_value")))
			if not ok:
				reason = "add_item_failed"
		DialogueAction.Type.REMOVE_ITEM:
			ok = _remove_item(target_id, int(action.get("int_value")))
			if not ok:
				reason = "remove_item_failed"
		DialogueAction.Type.SET_WORLD_STATE:
			ok = _set_world_state(
				target_id,
				str(action.get("secondary_id")),
				action
			)
			if not ok:
				reason = "set_world_state_failed"
		DialogueAction.Type.DISCOVER_POI:
			var display := str(action.get("string_value"))
			if display.is_empty():
				display = str(action.get("secondary_id"))
			ok = _discover_poi(target_id, display)
			if not ok:
				reason = "discover_poi_failed"
		DialogueAction.Type.SET_NPC_MET:
			ok = _set_npc_met(target_id, bool(action.get("bool_value")))
			if not ok:
				reason = "set_npc_met_failed"
		DialogueAction.Type.SET_NPC_STATE:
			ok = _set_npc_state(target_id, str(action.get("string_value")))
			if not ok:
				reason = "set_npc_state_failed"
		DialogueAction.Type.SET_NPC_ENABLED:
			ok = _set_npc_enabled(target_id, bool(action.get("bool_value")))
			if not ok:
				reason = "set_npc_enabled_failed"
		DialogueAction.Type.SET_NPC_LOCATION:
			ok = _set_npc_location(
				target_id,
				str(action.get("string_value")),
				str(action.get("secondary_id"))
			)
			if not ok:
				reason = "set_npc_location_failed"
		DialogueAction.Type.START_NPC_TRAVEL:
			ok = _start_npc_travel(action)
			if not ok:
				reason = "start_npc_travel_failed"
		DialogueAction.Type.SET_NPC_FLAG:
			ok = _set_npc_flag(
				target_id, str(action.get("secondary_id")), bool(action.get("bool_value"))
			)
			if not ok:
				reason = "set_npc_flag_failed"
		DialogueAction.Type.ADD_RELATIONSHIP:
			ok = _add_relationship(target_id, int(action.get("int_value")))
			if not ok:
				reason = "add_relationship_failed"
		DialogueAction.Type.SET_RELATIONSHIP:
			ok = _set_relationship(target_id, int(action.get("int_value")))
			if not ok:
				reason = "set_relationship_failed"
		DialogueAction.Type.ADD_REPUTATION:
			ok = _add_reputation(target_id, int(action.get("int_value")))
			if not ok:
				reason = "add_reputation_failed"
		DialogueAction.Type.SET_REPUTATION:
			ok = _set_reputation(target_id, int(action.get("int_value")))
			if not ok:
				reason = "set_reputation_failed"
		_:
			reason = "unknown_type:%d" % type_value
			push_warning("DialogueActionExecutor: %s" % reason)

	action_executed.emit(action, ok)
	if not ok:
		action_failed.emit(action, reason)
	return ok


func _set_flag(flag_id: String, value: bool) -> bool:
	if flag_id.is_empty():
		push_warning("DialogueActionExecutor: SET_FLAG missing target_id")
		return false
	var flags := _node("/root/GameFlags")
	if flags == null or not flags.has_method("set_flag"):
		push_warning("DialogueActionExecutor: GameFlags unavailable")
		return false
	flags.call("set_flag", flag_id, value)
	return true


func _start_quest(quest_id: String) -> bool:
	if quest_id.is_empty():
		push_warning("DialogueActionExecutor: START_QUEST missing target_id")
		return false
	var qs := _node("/root/QuestSystem")
	if qs == null or not qs.has_method("start_quest"):
		push_warning("DialogueActionExecutor: QuestSystem unavailable")
		return false
	# Already active/completed is a soft success (idempotent enough for dialogue).
	if qs.has_method("is_inactive") and not bool(qs.call("is_inactive", quest_id)):
		return true
	return bool(qs.call("start_quest", quest_id))


func _complete_quest(quest_id: String) -> bool:
	if quest_id.is_empty():
		push_warning("DialogueActionExecutor: COMPLETE_QUEST missing target_id")
		return false
	var qs := _node("/root/QuestSystem")
	if qs == null or not qs.has_method("complete_quest"):
		push_warning("DialogueActionExecutor: QuestSystem unavailable")
		return false
	if qs.has_method("is_completed") and bool(qs.call("is_completed", quest_id)):
		return true
	return bool(qs.call("complete_quest", quest_id))


func _add_item(item_id: String, amount: int) -> bool:
	if item_id.is_empty():
		push_warning("DialogueActionExecutor: ADD_ITEM missing target_id")
		return false
	var inv := _node("/root/InventorySystem")
	if inv == null or not inv.has_method("add_item"):
		push_warning("DialogueActionExecutor: InventorySystem unavailable")
		return false
	var added: int = int(inv.call("add_item", item_id, maxi(amount, 1)))
	if added <= 0:
		push_warning("DialogueActionExecutor: ADD_ITEM added 0 for '%s'" % item_id)
		return false
	return true


func _remove_item(item_id: String, amount: int) -> bool:
	if item_id.is_empty():
		push_warning("DialogueActionExecutor: REMOVE_ITEM missing target_id")
		return false
	var inv := _node("/root/InventorySystem")
	if inv == null or not inv.has_method("remove_item"):
		push_warning("DialogueActionExecutor: InventorySystem unavailable")
		return false
	var removed: int = int(inv.call("remove_item", item_id, maxi(amount, 1)))
	if removed <= 0:
		push_warning("DialogueActionExecutor: REMOVE_ITEM removed 0 for '%s'" % item_id)
		return false
	return true


func _set_world_state(entity_id: String, key: String, action: Resource) -> bool:
	if entity_id.is_empty() or key.is_empty():
		push_warning("DialogueActionExecutor: SET_WORLD_STATE needs target_id + secondary_id")
		return false
	var ws := _node("/root/WorldStateSystem")
	if ws == null:
		push_warning("DialogueActionExecutor: WorldStateSystem unavailable")
		return false
	var string_value := str(action.get("string_value"))
	if not string_value.is_empty():
		if not ws.has_method("set_value"):
			return false
		return bool(ws.call("set_value", entity_id, key, string_value))
	if ws.has_method("set_flag"):
		return bool(ws.call("set_flag", entity_id, key, bool(action.get("bool_value"))))
	if ws.has_method("set_value"):
		return bool(ws.call("set_value", entity_id, key, bool(action.get("bool_value"))))
	return false


func _discover_poi(poi_id: String, display_name: String) -> bool:
	if poi_id.is_empty():
		push_warning("DialogueActionExecutor: DISCOVER_POI missing target_id")
		return false
	var poi := _node("/root/POISystem")
	if poi == null or not poi.has_method("mark_discovered"):
		push_warning("DialogueActionExecutor: POISystem unavailable")
		return false
	# Already discovered counts as success.
	if poi.has_method("is_discovered") and bool(poi.call("is_discovered", poi_id)):
		return true
	poi.call("mark_discovered", poi_id, display_name)
	return true


func _set_npc_met(npc_id: String, value: bool) -> bool:
	if npc_id.is_empty():
		push_warning("DialogueActionExecutor: SET_NPC_MET missing target_id")
		return false
	var ns := _node("/root/NpcStateSystem")
	if ns == null or not ns.has_method("set_met_player"):
		push_warning("DialogueActionExecutor: NpcStateSystem unavailable")
		return false
	ns.call("set_met_player", npc_id, value)
	return true


func _set_npc_state(npc_id: String, state_tag: String) -> bool:
	if npc_id.is_empty() or state_tag.strip_edges().is_empty():
		push_warning("DialogueActionExecutor: SET_NPC_STATE needs target_id + string_value")
		return false
	var ns := _node("/root/NpcStateSystem")
	if ns == null or not ns.has_method("set_current_state"):
		push_warning("DialogueActionExecutor: NpcStateSystem unavailable")
		return false
	ns.call("set_current_state", npc_id, state_tag)
	return true


func _set_npc_enabled(npc_id: String, value: bool) -> bool:
	if npc_id.is_empty():
		push_warning("DialogueActionExecutor: SET_NPC_ENABLED missing target_id")
		return false
	var ns := _node("/root/NpcStateSystem")
	if ns == null or not ns.has_method("set_enabled"):
		push_warning("DialogueActionExecutor: NpcStateSystem unavailable")
		return false
	ns.call("set_enabled", npc_id, value)
	return true


func _set_npc_location(npc_id: String, location_id: String, transition_id: String = "") -> bool:
	if npc_id.is_empty():
		push_warning("DialogueActionExecutor: SET_NPC_LOCATION missing target_id")
		return false
	var travel := _node("/root/NpcTravelSystem")
	if travel != null and travel.has_method("set_at_location"):
		return bool(travel.call("set_at_location", npc_id, location_id, transition_id))
	var ns := _node("/root/NpcStateSystem")
	if ns == null or not ns.has_method("set_location_id"):
		push_warning("DialogueActionExecutor: NpcStateSystem unavailable")
		return false
	ns.call("set_location_id", npc_id, location_id)
	return true


func _start_npc_travel(action: Resource) -> bool:
	var npc_id := str(action.get("target_id"))
	var destination := str(action.get("string_value"))
	if npc_id.is_empty() or destination.is_empty():
		push_warning("DialogueActionExecutor: START_NPC_TRAVEL needs target_id + string_value destination")
		return false
	var travel := _node("/root/NpcTravelSystem")
	if travel == null or not travel.has_method("start_travel"):
		push_warning("DialogueActionExecutor: NpcTravelSystem unavailable")
		return false
	var transition_id := str(action.get("secondary_id"))
	var narrative_delay := int(action.get("int_value"))
	# int_value default on DialogueAction is 1 — treat as minutes when >= 0; use -1 to skip.
	# Authors set int_value explicitly for delay; 0 = arrive on next refresh.
	var journey_km := float(action.get("float_value"))
	var arrival_flag := ""
	# Optional: secondary_id "flag:<id>" means arrival flag; transition_id empty then.
	if transition_id.begins_with("flag:"):
		arrival_flag = transition_id.substr(5)
		transition_id = ""
	if journey_km <= 0.0:
		journey_km = -1.0
	return bool(
		travel.call(
			"start_travel",
			npc_id,
			destination,
			transition_id,
			narrative_delay,
			journey_km,
			arrival_flag
		)
	)


func _set_npc_flag(npc_id: String, flag_id: String, value: bool) -> bool:
	if npc_id.is_empty() or flag_id.is_empty():
		push_warning("DialogueActionExecutor: SET_NPC_FLAG needs target_id + secondary_id")
		return false
	var ns := _node("/root/NpcStateSystem")
	if ns == null or not ns.has_method("set_custom_flag"):
		push_warning("DialogueActionExecutor: NpcStateSystem unavailable")
		return false
	ns.call("set_custom_flag", npc_id, flag_id, value)
	return true


func _add_relationship(npc_id: String, delta: int) -> bool:
	if npc_id.is_empty():
		push_warning("DialogueActionExecutor: ADD_RELATIONSHIP missing target_id")
		return false
	var rs := _node("/root/RelationshipSystem")
	if rs == null or not rs.has_method("add_relationship"):
		push_warning("DialogueActionExecutor: RelationshipSystem unavailable")
		return false
	rs.call("add_relationship", npc_id, delta)
	return true


func _set_relationship(npc_id: String, value: int) -> bool:
	if npc_id.is_empty():
		push_warning("DialogueActionExecutor: SET_RELATIONSHIP missing target_id")
		return false
	var rs := _node("/root/RelationshipSystem")
	if rs == null or not rs.has_method("set_relationship"):
		push_warning("DialogueActionExecutor: RelationshipSystem unavailable")
		return false
	rs.call("set_relationship", npc_id, value)
	return true


func _add_reputation(group_id: String, delta: int) -> bool:
	if group_id.is_empty():
		push_warning("DialogueActionExecutor: ADD_REPUTATION missing target_id")
		return false
	var rs := _node("/root/RelationshipSystem")
	if rs == null or not rs.has_method("add_reputation"):
		push_warning("DialogueActionExecutor: RelationshipSystem unavailable")
		return false
	rs.call("add_reputation", group_id, delta)
	return true


func _set_reputation(group_id: String, value: int) -> bool:
	if group_id.is_empty():
		push_warning("DialogueActionExecutor: SET_REPUTATION missing target_id")
		return false
	var rs := _node("/root/RelationshipSystem")
	if rs == null or not rs.has_method("set_reputation"):
		push_warning("DialogueActionExecutor: RelationshipSystem unavailable")
		return false
	rs.call("set_reputation", group_id, value)
	return true


func _node(path: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null(path)
