extends Node
## Generic gameplay condition evaluator. Queries other systems — never embeds
## quest/NPC-specific branches. DialogueSystem / QuestSystem / NPCs call this API.
## Peer systems are resolved lazily at evaluate-time (no _ready order dependence).

const ConditionDataScript = preload("res://scripts/conditions/condition_data.gd")
const Bootstrap := preload("res://scripts/core/autoload_bootstrap.gd")

signal condition_evaluated(condition: Resource, result: bool)
signal init_state_changed(state: String)

var _init_state: String = Bootstrap.STATE_UNINITIALIZED


func _ready() -> void:
	_init_state = Bootstrap.STATE_READY
	init_state_changed.emit(_init_state)


func get_init_state() -> String:
	return _init_state


func is_system_ready() -> bool:
	return _init_state == Bootstrap.STATE_READY


func evaluate(condition: Resource) -> bool:
	if condition == null:
		return true
	var result := _evaluate_typed(condition)
	condition_evaluated.emit(condition, result)
	return result


func evaluate_all(conditions: Array) -> bool:
	## Vacuous truth: empty list passes.
	if conditions.is_empty():
		return true
	for entry in conditions:
		if entry == null:
			continue
		if not evaluate(entry):
			return false
	return true


func evaluate_any(conditions: Array) -> bool:
	## Empty list fails (no alternative succeeded).
	if conditions.is_empty():
		return false
	for entry in conditions:
		if entry == null:
			continue
		if evaluate(entry):
			return true
	return false


## --- Factory helpers (tests / runtime authoring) ---

func make(type_value: int, key: String = "") -> Resource:
	var c: Resource = ConditionDataScript.new()
	c.set("type", type_value)
	c.set("key", key)
	return c


func make_flag_equals(flag_id: String, expected: bool = true) -> Resource:
	var c := make(ConditionDataScript.Type.FLAG_EQUALS, flag_id)
	c.set("bool_value", expected)
	return c


func make_quest_state(quest_id: String, state_name: String) -> Resource:
	var c := make(ConditionDataScript.Type.QUEST_STATE, quest_id)
	c.set("string_value", state_name.to_upper())
	return c


func make_has_item(item_id: String, amount: int = 1) -> Resource:
	var c := make(ConditionDataScript.Type.HAS_ITEM, item_id)
	c.set("int_value", maxi(amount, 1))
	return c


func make_item_quantity(item_id: String, min_amount: int) -> Resource:
	var c := make(ConditionDataScript.Type.ITEM_QUANTITY, item_id)
	c.set("int_value", maxi(min_amount, 0))
	return c


func make_poi_discovered(poi_id: String) -> Resource:
	return make(ConditionDataScript.Type.POI_DISCOVERED, poi_id)


func make_world_state_equals(entity_id: String, state_key: String, expected: String) -> Resource:
	var c := make(ConditionDataScript.Type.WORLD_STATE_EQUALS, entity_id)
	c.set("secondary_key", state_key)
	c.set("string_value", expected)
	return c


func make_vehicle_has_upgrade(upgrade_id: String) -> Resource:
	return make(ConditionDataScript.Type.VEHICLE_HAS_UPGRADE, upgrade_id)


func make_region_is(region_id: String) -> Resource:
	return make(ConditionDataScript.Type.REGION_IS, region_id)


func make_journey_distance_min(km: float) -> Resource:
	var c := make(ConditionDataScript.Type.JOURNEY_DISTANCE_MIN)
	c.set("float_value", km)
	return c


func make_journey_distance_max(km: float) -> Resource:
	var c := make(ConditionDataScript.Type.JOURNEY_DISTANCE_MAX)
	c.set("float_value", km)
	return c


func make_dialogue_seen(dialogue_id: String) -> Resource:
	return make(ConditionDataScript.Type.DIALOGUE_SEEN, dialogue_id)


func make_dialogue_completed(dialogue_id: String) -> Resource:
	return make(ConditionDataScript.Type.DIALOGUE_COMPLETED, dialogue_id)


func make_dialogue_choice_selected(choice_id: String) -> Resource:
	return make(ConditionDataScript.Type.DIALOGUE_CHOICE_SELECTED, choice_id)


func make_dialogue_completion_count_min(dialogue_id: String, min_count: int) -> Resource:
	var c := make(ConditionDataScript.Type.DIALOGUE_COMPLETION_COUNT_MIN, dialogue_id)
	c.set("int_value", maxi(min_count, 0))
	return c


func make_npc_state(npc_id: String, state_tag: String) -> Resource:
	var c := make(ConditionDataScript.Type.NPC_STATE, npc_id)
	c.set("string_value", state_tag.to_upper())
	return c


func make_npc_met(npc_id: String, expected: bool = true) -> Resource:
	var c := make(ConditionDataScript.Type.NPC_MET, npc_id)
	c.set("bool_value", expected)
	return c


func make_npc_enabled(npc_id: String, expected: bool = true) -> Resource:
	var c := make(ConditionDataScript.Type.NPC_ENABLED, npc_id)
	c.set("bool_value", expected)
	return c


func make_npc_location(npc_id: String, location_id: String) -> Resource:
	var c := make(ConditionDataScript.Type.NPC_LOCATION, npc_id)
	c.set("string_value", location_id)
	return c


func make_npc_travel_state(npc_id: String, travel_state: String) -> Resource:
	var c := make(ConditionDataScript.Type.NPC_TRAVEL_STATE, npc_id)
	c.set("string_value", travel_state.to_upper())
	return c


func make_npc_destination(npc_id: String, destination_location_id: String) -> Resource:
	var c := make(ConditionDataScript.Type.NPC_DESTINATION, npc_id)
	c.set("string_value", destination_location_id)
	return c


func make_npc_at_location(npc_id: String, location_id: String) -> Resource:
	var c := make(ConditionDataScript.Type.NPC_AT_LOCATION, npc_id)
	c.set("string_value", location_id)
	return c


func make_relationship_min(npc_id: String, min_value: int) -> Resource:
	var c := make(ConditionDataScript.Type.RELATIONSHIP_MIN, npc_id)
	c.set("int_value", min_value)
	return c


func make_relationship_max(npc_id: String, max_value: int) -> Resource:
	var c := make(ConditionDataScript.Type.RELATIONSHIP_MAX, npc_id)
	c.set("int_value", max_value)
	return c


func make_reputation_min(group_id: String, min_value: int) -> Resource:
	var c := make(ConditionDataScript.Type.REPUTATION_MIN, group_id)
	c.set("int_value", min_value)
	return c


func make_reputation_max(group_id: String, max_value: int) -> Resource:
	var c := make(ConditionDataScript.Type.REPUTATION_MAX, group_id)
	c.set("int_value", max_value)
	return c


func make_narrative_hour_min(hour: int) -> Resource:
	var c := make(ConditionDataScript.Type.NARRATIVE_HOUR_MIN)
	c.set("int_value", clampi(hour, 0, 23))
	return c


func make_narrative_hour_max(hour: int) -> Resource:
	var c := make(ConditionDataScript.Type.NARRATIVE_HOUR_MAX)
	c.set("int_value", clampi(hour, 0, 23))
	return c


func make_narrative_day_min(day_index: int) -> Resource:
	var c := make(ConditionDataScript.Type.NARRATIVE_DAY_MIN)
	c.set("int_value", maxi(day_index, 0))
	return c


func make_narrative_day_max(day_index: int) -> Resource:
	var c := make(ConditionDataScript.Type.NARRATIVE_DAY_MAX)
	c.set("int_value", maxi(day_index, 0))
	return c


func make_narrative_time_range(start_hour: int, end_hour: int) -> Resource:
	## Inclusive start hour, exclusive end hour. Cross-midnight supported (e.g. 22→6).
	var c := make(ConditionDataScript.Type.NARRATIVE_TIME_RANGE)
	c.set("int_value", clampi(start_hour, 0, 23) * 60)
	c.set("float_value", float(clampi(end_hour, 0, 23) * 60))
	return c


## Retired aliases — map to narrative world clock (never play/system time).
func make_time_hour_min(hour: int) -> Resource:
	return make_narrative_hour_min(hour)


func make_time_hour_max(hour: int) -> Resource:
	return make_narrative_hour_max(hour)


func make_day_index_min(day_index: int) -> Resource:
	return make_narrative_day_min(day_index)


func _evaluate_typed(condition: Resource) -> bool:
	var type_value := int(condition.get("type"))
	var key := str(condition.get("key"))
	match type_value:
		ConditionDataScript.Type.FLAG_EQUALS:
			return _eval_flag_equals(key, bool(condition.get("bool_value")))
		ConditionDataScript.Type.QUEST_STATE:
			return _eval_quest_state(key, str(condition.get("string_value")))
		ConditionDataScript.Type.HAS_ITEM:
			return _eval_has_item(key, maxi(int(condition.get("int_value")), 1))
		ConditionDataScript.Type.ITEM_QUANTITY:
			return _eval_item_quantity(key, maxi(int(condition.get("int_value")), 0))
		ConditionDataScript.Type.POI_DISCOVERED:
			return _eval_poi_discovered(key)
		ConditionDataScript.Type.WORLD_STATE_EQUALS:
			return _eval_world_state_equals(
				key, str(condition.get("secondary_key")), str(condition.get("string_value"))
			)
		ConditionDataScript.Type.VEHICLE_HAS_UPGRADE:
			return _eval_vehicle_has_upgrade(key)
		ConditionDataScript.Type.REGION_IS:
			return _eval_region_is(key)
		ConditionDataScript.Type.JOURNEY_DISTANCE_MIN:
			return _eval_journey_min(float(condition.get("float_value")))
		ConditionDataScript.Type.JOURNEY_DISTANCE_MAX:
			return _eval_journey_max(float(condition.get("float_value")))
		ConditionDataScript.Type.DIALOGUE_SEEN:
			return _eval_dialogue_seen(key)
		ConditionDataScript.Type.DIALOGUE_COMPLETED:
			return _eval_dialogue_completed(key)
		ConditionDataScript.Type.DIALOGUE_CHOICE_SELECTED:
			return _eval_dialogue_choice_selected(key)
		ConditionDataScript.Type.DIALOGUE_COMPLETION_COUNT_MIN:
			return _eval_dialogue_completion_count_min(key, maxi(int(condition.get("int_value")), 0))
		ConditionDataScript.Type.NPC_STATE:
			return _eval_npc_state(key, str(condition.get("string_value")))
		ConditionDataScript.Type.NPC_MET:
			return _eval_npc_met(key, bool(condition.get("bool_value")))
		ConditionDataScript.Type.NPC_ENABLED:
			return _eval_npc_enabled(key, bool(condition.get("bool_value")))
		ConditionDataScript.Type.NPC_LOCATION:
			return _eval_npc_location(key, str(condition.get("string_value")))
		ConditionDataScript.Type.NPC_TRAVEL_STATE:
			return _eval_npc_travel_state(key, str(condition.get("string_value")))
		ConditionDataScript.Type.NPC_DESTINATION:
			return _eval_npc_destination(key, str(condition.get("string_value")))
		ConditionDataScript.Type.NPC_AT_LOCATION:
			return _eval_npc_at_location(key, str(condition.get("string_value")))
		ConditionDataScript.Type.RELATIONSHIP_MIN:
			return _eval_relationship_min(key, int(condition.get("int_value")))
		ConditionDataScript.Type.RELATIONSHIP_MAX:
			return _eval_relationship_max(key, int(condition.get("int_value")))
		ConditionDataScript.Type.REPUTATION_MIN:
			return _eval_reputation_min(key, int(condition.get("int_value")))
		ConditionDataScript.Type.REPUTATION_MAX:
			return _eval_reputation_max(key, int(condition.get("int_value")))
		ConditionDataScript.Type.NARRATIVE_HOUR_MIN:
			return _eval_narrative_hour_min(int(condition.get("int_value")))
		ConditionDataScript.Type.NARRATIVE_HOUR_MAX:
			return _eval_narrative_hour_max(int(condition.get("int_value")))
		ConditionDataScript.Type.NARRATIVE_DAY_MIN:
			return _eval_narrative_day_min(int(condition.get("int_value")))
		ConditionDataScript.Type.NARRATIVE_DAY_MAX:
			return _eval_narrative_day_max(int(condition.get("int_value")))
		ConditionDataScript.Type.NARRATIVE_TIME_RANGE:
			return _eval_narrative_time_range(
				int(condition.get("int_value")), float(condition.get("float_value"))
			)
		_:
			push_warning("ConditionSystem: unknown condition type %d" % type_value)
			return false


func _eval_flag_equals(flag_id: String, expected: bool) -> bool:
	var flags := get_node_or_null("/root/GameFlags")
	if flags == null:
		return expected == false
	if flags.has_method("get_flag"):
		return bool(flags.call("get_flag", flag_id, false)) == expected
	return false


func _eval_quest_state(quest_id: String, state_name: String) -> bool:
	var qs := get_node_or_null("/root/QuestSystem")
	if qs == null or quest_id.is_empty():
		return false
	var want := state_name.strip_edges().to_upper()
	if want.is_empty():
		return false
	if qs.has_method("get_state_name"):
		return str(qs.call("get_state_name", quest_id)).to_upper() == want
	return false


func _eval_has_item(item_id: String, amount: int) -> bool:
	var inv := get_node_or_null("/root/InventorySystem")
	if inv == null or item_id.is_empty():
		return false
	if inv.has_method("has_item"):
		return bool(inv.call("has_item", item_id, amount))
	return false


func _eval_item_quantity(item_id: String, min_amount: int) -> bool:
	var inv := get_node_or_null("/root/InventorySystem")
	if inv == null or item_id.is_empty():
		return false
	if inv.has_method("get_quantity"):
		return int(inv.call("get_quantity", item_id)) >= min_amount
	return false


func _eval_poi_discovered(poi_id: String) -> bool:
	var poi := get_node_or_null("/root/POISystem")
	if poi == null or poi_id.is_empty():
		return false
	if poi.has_method("is_discovered"):
		return bool(poi.call("is_discovered", poi_id))
	return false


func _eval_world_state_equals(entity_id: String, state_key: String, expected: String) -> bool:
	var ws := get_node_or_null("/root/WorldStateSystem")
	if ws == null or entity_id.is_empty() or state_key.is_empty():
		return false
	if not ws.has_method("get_value"):
		return false
	var value: Variant = ws.call("get_value", entity_id, state_key, null)
	if value == null:
		return false
	return str(value) == expected


func _eval_vehicle_has_upgrade(upgrade_id: String) -> bool:
	var vs := get_node_or_null("/root/VehicleStateSystem")
	if vs == null or upgrade_id.is_empty():
		return false
	if vs.has_method("has_upgrade"):
		return bool(vs.call("has_upgrade", upgrade_id))
	return false


func _eval_region_is(region_id: String) -> bool:
	var regions := get_node_or_null("/root/WorldRegionSystem")
	if regions == null or region_id.is_empty():
		return false
	if regions.has_method("get_current_region_id"):
		return str(regions.call("get_current_region_id")) == region_id
	return false


func _eval_journey_min(km: float) -> bool:
	var journey := get_node_or_null("/root/JourneySystem")
	if journey == null or not journey.has_method("get_current_distance_km"):
		return false
	return float(journey.call("get_current_distance_km")) >= km


func _eval_journey_max(km: float) -> bool:
	var journey := get_node_or_null("/root/JourneySystem")
	if journey == null or not journey.has_method("get_current_distance_km"):
		return false
	return float(journey.call("get_current_distance_km")) <= km


func _eval_dialogue_seen(dialogue_id: String) -> bool:
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory == null or dialogue_id.is_empty() or not memory.has_method("has_seen_dialogue"):
		return false
	return bool(memory.call("has_seen_dialogue", dialogue_id))


func _eval_dialogue_completed(dialogue_id: String) -> bool:
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory == null or dialogue_id.is_empty() or not memory.has_method("has_completed_dialogue"):
		return false
	return bool(memory.call("has_completed_dialogue", dialogue_id))


func _eval_dialogue_choice_selected(choice_id: String) -> bool:
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory == null or choice_id.is_empty() or not memory.has_method("has_selected_choice"):
		return false
	return bool(memory.call("has_selected_choice", choice_id))


func _eval_dialogue_completion_count_min(dialogue_id: String, min_count: int) -> bool:
	var memory := get_node_or_null("/root/DialogueMemorySystem")
	if memory == null or dialogue_id.is_empty() or not memory.has_method("get_times_completed"):
		return false
	return int(memory.call("get_times_completed", dialogue_id)) >= min_count


func _eval_npc_state(npc_id: String, state_tag: String) -> bool:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty() or not ns.has_method("get_current_state"):
		return false
	var want := state_tag.strip_edges().to_upper()
	if want.is_empty():
		return false
	return str(ns.call("get_current_state", npc_id)).to_upper() == want


func _eval_npc_met(npc_id: String, expected: bool) -> bool:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty() or not ns.has_method("has_met_player"):
		return expected == false
	return bool(ns.call("has_met_player", npc_id)) == expected


func _eval_npc_enabled(npc_id: String, expected: bool) -> bool:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty() or not ns.has_method("is_enabled"):
		return expected == true
	return bool(ns.call("is_enabled", npc_id)) == expected


func _eval_npc_location(npc_id: String, location_id: String) -> bool:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty() or location_id.is_empty():
		return false
	if not ns.has_method("get_location_id"):
		return false
	return str(ns.call("get_location_id", npc_id)) == location_id


func _eval_npc_travel_state(npc_id: String, travel_state: String) -> bool:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty() or not ns.has_method("get_travel_state"):
		return false
	var want := travel_state.strip_edges().to_upper()
	if want.is_empty():
		return false
	return str(ns.call("get_travel_state", npc_id)).to_upper() == want


func _eval_npc_destination(npc_id: String, destination_location_id: String) -> bool:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty() or destination_location_id.is_empty():
		return false
	if not ns.has_method("get_destination_location_id"):
		return false
	return str(ns.call("get_destination_location_id", npc_id)) == destination_location_id


func _eval_npc_at_location(npc_id: String, location_id: String) -> bool:
	var travel := get_node_or_null("/root/NpcTravelSystem")
	if travel != null and travel.has_method("is_at_location"):
		return bool(travel.call("is_at_location", npc_id, location_id))
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns == null or npc_id.is_empty() or location_id.is_empty():
		return false
	if ns.has_method("get_travel_state") and str(ns.call("get_travel_state", npc_id)) != "AT_LOCATION":
		return false
	if not ns.has_method("get_location_id"):
		return false
	return str(ns.call("get_location_id", npc_id)) == location_id


func _eval_relationship_min(npc_id: String, min_value: int) -> bool:
	var rs := get_node_or_null("/root/RelationshipSystem")
	if rs == null or npc_id.is_empty() or not rs.has_method("get_relationship"):
		return false
	return int(rs.call("get_relationship", npc_id)) >= min_value


func _eval_relationship_max(npc_id: String, max_value: int) -> bool:
	var rs := get_node_or_null("/root/RelationshipSystem")
	if rs == null or npc_id.is_empty() or not rs.has_method("get_relationship"):
		return false
	return int(rs.call("get_relationship", npc_id)) <= max_value


func _eval_reputation_min(group_id: String, min_value: int) -> bool:
	var rs := get_node_or_null("/root/RelationshipSystem")
	if rs == null or group_id.is_empty() or not rs.has_method("get_reputation"):
		return false
	return int(rs.call("get_reputation", group_id)) >= min_value


func _eval_reputation_max(group_id: String, max_value: int) -> bool:
	var rs := get_node_or_null("/root/RelationshipSystem")
	if rs == null or group_id.is_empty() or not rs.has_method("get_reputation"):
		return false
	return int(rs.call("get_reputation", group_id)) <= max_value


func _eval_narrative_hour_min(hour: int) -> bool:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_hour"):
		return false
	return int(gt.call("get_narrative_hour")) >= clampi(hour, 0, 23)


func _eval_narrative_hour_max(hour: int) -> bool:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_hour"):
		return false
	return int(gt.call("get_narrative_hour")) <= clampi(hour, 0, 23)


func _eval_narrative_day_min(day_index: int) -> bool:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_day_index"):
		return false
	return int(gt.call("get_narrative_day_index")) >= maxi(day_index, 0)


func _eval_narrative_day_max(day_index: int) -> bool:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_day_index"):
		return false
	return int(gt.call("get_narrative_day_index")) <= maxi(day_index, 0)


func _eval_narrative_time_range(start_minutes: int, end_minutes: float) -> bool:
	## Minutes-of-day window. Cross-midnight when start > end (e.g. 22:00–06:00).
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_minutes_of_day"):
		return false
	var now := float(gt.call("get_narrative_minutes_of_day"))
	var start_m := float(posmod(start_minutes, 24 * 60))
	var end_m := fposmod(end_minutes, 24.0 * 60.0)
	if is_equal_approx(start_m, end_m):
		return true
	if start_m < end_m:
		return now >= start_m and now < end_m
	return now >= start_m or now < end_m
