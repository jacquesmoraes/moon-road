extends Node
## Generic gameplay condition evaluator. Queries other systems — never embeds
## quest/NPC-specific branches. DialogueSystem / QuestSystem / NPCs call this API.
## Peer systems are resolved lazily at evaluate-time (no _ready order dependence).
##
## Fail-closed hard rule: missing peer system, empty/invalid id, unknown type → false.
## Never treat "system missing" as "value is false/true" — that opens misconfiguration.

const ConditionDataScript = preload("res://scripts/conditions/condition_data.gd")
const Bootstrap := preload("res://scripts/core/autoload_bootstrap.gd")

signal condition_evaluated(condition: Resource, result: bool)
signal init_state_changed(state: String)

## When true, log every fail-closed miss. When false, log each peer+type once per session.
@export var debug_verbose: bool = false

var _init_state: String = Bootstrap.STATE_UNINITIALIZED
## path → Node|null override for tests (null forces missing peer).
var _peer_overrides: Dictionary = {}
## "peer|type" → true — rate-limit missing-peer warnings.
var _missing_logged: Dictionary = {}


func _ready() -> void:
	_init_state = Bootstrap.STATE_READY
	init_state_changed.emit(_init_state)


func get_init_state() -> String:
	return _init_state


func is_system_ready() -> bool:
	return _init_state == Bootstrap.STATE_READY


## --- Evaluation API ---

func evaluate(condition: Resource) -> bool:
	## null condition = "no gate authored" (vacuous true). Invalid typed data → false.
	if condition == null:
		return true
	var result := _evaluate_typed(condition)
	condition_evaluated.emit(condition, result)
	return result


func evaluate_all(conditions: Array) -> bool:
	## Vacuous truth: empty list passes. Null entries in the list are invalid → false.
	if conditions.is_empty():
		return true
	for entry in conditions:
		if entry == null:
			_log_fail("invalid", "null_entry_in_all", "evaluate_all contains null condition")
			return false
		if not evaluate(entry):
			return false
	return true


func evaluate_any(conditions: Array) -> bool:
	## Empty list fails (no alternative succeeded). Null entries never count as success.
	if conditions.is_empty():
		return false
	for entry in conditions:
		if entry == null:
			continue
		if evaluate(entry):
			return true
	return false


## --- Test / debug peer overrides (not gameplay) ---

func debug_force_peer_missing(path: String) -> void:
	if path.is_empty():
		return
	_peer_overrides[path] = null


func debug_clear_peer_overrides() -> void:
	_peer_overrides.clear()


func debug_clear_missing_log() -> void:
	_missing_logged.clear()


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


## --- Internals ---

func _resolve_peer(path: String) -> Node:
	if _peer_overrides.has(path):
		return _peer_overrides[path] as Node
	return get_node_or_null(path)


func _fail_missing(peer_path: String, type_name: String) -> bool:
	_log_fail(peer_path, type_name, "missing peer → false")
	return false


func _fail_invalid(type_name: String, reason: String) -> bool:
	_log_fail("invalid", type_name, reason)
	return false


func _log_fail(peer_or_scope: String, type_name: String, detail: String) -> void:
	var key := "%s|%s" % [peer_or_scope, type_name]
	if not debug_verbose and _missing_logged.has(key):
		return
	_missing_logged[key] = true
	push_warning("ConditionSystem fail-closed [%s] %s: %s" % [type_name, peer_or_scope, detail])


func _evaluate_typed(condition: Resource) -> bool:
	if not ("type" in condition):
		return _fail_invalid("UNKNOWN", "condition missing type field")
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
			return _fail_invalid("UNKNOWN", "unknown condition type %d" % type_value)


func _eval_flag_equals(flag_id: String, expected: bool) -> bool:
	if flag_id.is_empty():
		return _fail_invalid("FLAG_EQUALS", "empty flag_id")
	var flags := _resolve_peer("/root/GameFlags")
	if flags == null or not flags.has_method("get_flag"):
		return _fail_missing("/root/GameFlags", "FLAG_EQUALS")
	# System present: compare actual stored value (default false if unset).
	return bool(flags.call("get_flag", flag_id, false)) == expected


func _eval_quest_state(quest_id: String, state_name: String) -> bool:
	if quest_id.is_empty():
		return _fail_invalid("QUEST_STATE", "empty quest_id")
	var want := state_name.strip_edges().to_upper()
	if want.is_empty():
		return _fail_invalid("QUEST_STATE", "empty state name")
	var qs := _resolve_peer("/root/QuestSystem")
	if qs == null or not qs.has_method("get_state_name"):
		return _fail_missing("/root/QuestSystem", "QUEST_STATE")
	return str(qs.call("get_state_name", quest_id)).to_upper() == want


func _eval_has_item(item_id: String, amount: int) -> bool:
	if item_id.is_empty():
		return _fail_invalid("HAS_ITEM", "empty item_id")
	var inv := _resolve_peer("/root/InventorySystem")
	if inv == null or not inv.has_method("has_item"):
		return _fail_missing("/root/InventorySystem", "HAS_ITEM")
	return bool(inv.call("has_item", item_id, amount))


func _eval_item_quantity(item_id: String, min_amount: int) -> bool:
	if item_id.is_empty():
		return _fail_invalid("ITEM_QUANTITY", "empty item_id")
	var inv := _resolve_peer("/root/InventorySystem")
	if inv == null or not inv.has_method("get_quantity"):
		return _fail_missing("/root/InventorySystem", "ITEM_QUANTITY")
	return int(inv.call("get_quantity", item_id)) >= min_amount


func _eval_poi_discovered(poi_id: String) -> bool:
	if poi_id.is_empty():
		return _fail_invalid("POI_DISCOVERED", "empty poi_id")
	var poi := _resolve_peer("/root/POISystem")
	if poi == null or not poi.has_method("is_discovered"):
		return _fail_missing("/root/POISystem", "POI_DISCOVERED")
	return bool(poi.call("is_discovered", poi_id))


func _eval_world_state_equals(entity_id: String, state_key: String, expected: String) -> bool:
	if entity_id.is_empty() or state_key.is_empty():
		return _fail_invalid("WORLD_STATE_EQUALS", "empty entity_id or state_key")
	var ws := _resolve_peer("/root/WorldStateSystem")
	if ws == null or not ws.has_method("get_value"):
		return _fail_missing("/root/WorldStateSystem", "WORLD_STATE_EQUALS")
	var value: Variant = ws.call("get_value", entity_id, state_key, null)
	if value == null:
		return false
	return str(value) == expected


func _eval_vehicle_has_upgrade(upgrade_id: String) -> bool:
	if upgrade_id.is_empty():
		return _fail_invalid("VEHICLE_HAS_UPGRADE", "empty upgrade_id")
	var vs := _resolve_peer("/root/VehicleStateSystem")
	if vs == null or not vs.has_method("has_upgrade"):
		return _fail_missing("/root/VehicleStateSystem", "VEHICLE_HAS_UPGRADE")
	return bool(vs.call("has_upgrade", upgrade_id))


func _eval_region_is(region_id: String) -> bool:
	if region_id.is_empty():
		return _fail_invalid("REGION_IS", "empty region_id")
	var regions := _resolve_peer("/root/WorldRegionSystem")
	if regions == null or not regions.has_method("get_current_region_id"):
		return _fail_missing("/root/WorldRegionSystem", "REGION_IS")
	return str(regions.call("get_current_region_id")) == region_id


func _eval_journey_min(km: float) -> bool:
	var journey := _resolve_peer("/root/JourneySystem")
	if journey == null or not journey.has_method("get_current_distance_km"):
		return _fail_missing("/root/JourneySystem", "JOURNEY_DISTANCE_MIN")
	return float(journey.call("get_current_distance_km")) >= km


func _eval_journey_max(km: float) -> bool:
	var journey := _resolve_peer("/root/JourneySystem")
	if journey == null or not journey.has_method("get_current_distance_km"):
		return _fail_missing("/root/JourneySystem", "JOURNEY_DISTANCE_MAX")
	return float(journey.call("get_current_distance_km")) <= km


func _eval_dialogue_seen(dialogue_id: String) -> bool:
	if dialogue_id.is_empty():
		return _fail_invalid("DIALOGUE_SEEN", "empty dialogue_id")
	var memory := _resolve_peer("/root/DialogueMemorySystem")
	if memory == null or not memory.has_method("has_seen_dialogue"):
		return _fail_missing("/root/DialogueMemorySystem", "DIALOGUE_SEEN")
	return bool(memory.call("has_seen_dialogue", dialogue_id))


func _eval_dialogue_completed(dialogue_id: String) -> bool:
	if dialogue_id.is_empty():
		return _fail_invalid("DIALOGUE_COMPLETED", "empty dialogue_id")
	var memory := _resolve_peer("/root/DialogueMemorySystem")
	if memory == null or not memory.has_method("has_completed_dialogue"):
		return _fail_missing("/root/DialogueMemorySystem", "DIALOGUE_COMPLETED")
	return bool(memory.call("has_completed_dialogue", dialogue_id))


func _eval_dialogue_choice_selected(choice_id: String) -> bool:
	if choice_id.is_empty():
		return _fail_invalid("DIALOGUE_CHOICE_SELECTED", "empty choice_id")
	var memory := _resolve_peer("/root/DialogueMemorySystem")
	if memory == null or not memory.has_method("has_selected_choice"):
		return _fail_missing("/root/DialogueMemorySystem", "DIALOGUE_CHOICE_SELECTED")
	return bool(memory.call("has_selected_choice", choice_id))


func _eval_dialogue_completion_count_min(dialogue_id: String, min_count: int) -> bool:
	if dialogue_id.is_empty():
		return _fail_invalid("DIALOGUE_COMPLETION_COUNT_MIN", "empty dialogue_id")
	var memory := _resolve_peer("/root/DialogueMemorySystem")
	if memory == null or not memory.has_method("get_times_completed"):
		return _fail_missing("/root/DialogueMemorySystem", "DIALOGUE_COMPLETION_COUNT_MIN")
	return int(memory.call("get_times_completed", dialogue_id)) >= min_count


func _eval_npc_state(npc_id: String, state_tag: String) -> bool:
	if npc_id.is_empty():
		return _fail_invalid("NPC_STATE", "empty npc_id")
	var want := state_tag.strip_edges().to_upper()
	if want.is_empty():
		return _fail_invalid("NPC_STATE", "empty state tag")
	var ns := _resolve_peer("/root/NpcStateSystem")
	if ns == null or not ns.has_method("get_current_state"):
		return _fail_missing("/root/NpcStateSystem", "NPC_STATE")
	return str(ns.call("get_current_state", npc_id)).to_upper() == want


func _eval_npc_met(npc_id: String, expected: bool) -> bool:
	if npc_id.is_empty():
		return _fail_invalid("NPC_MET", "empty npc_id")
	var ns := _resolve_peer("/root/NpcStateSystem")
	if ns == null or not ns.has_method("has_met_player"):
		return _fail_missing("/root/NpcStateSystem", "NPC_MET")
	return bool(ns.call("has_met_player", npc_id)) == expected


func _eval_npc_enabled(npc_id: String, expected: bool) -> bool:
	if npc_id.is_empty():
		return _fail_invalid("NPC_ENABLED", "empty npc_id")
	var ns := _resolve_peer("/root/NpcStateSystem")
	if ns == null or not ns.has_method("is_enabled"):
		return _fail_missing("/root/NpcStateSystem", "NPC_ENABLED")
	return bool(ns.call("is_enabled", npc_id)) == expected


func _eval_npc_location(npc_id: String, location_id: String) -> bool:
	if npc_id.is_empty() or location_id.is_empty():
		return _fail_invalid("NPC_LOCATION", "empty npc_id or location_id")
	var ns := _resolve_peer("/root/NpcStateSystem")
	if ns == null or not ns.has_method("get_location_id"):
		return _fail_missing("/root/NpcStateSystem", "NPC_LOCATION")
	return str(ns.call("get_location_id", npc_id)) == location_id


func _eval_npc_travel_state(npc_id: String, travel_state: String) -> bool:
	if npc_id.is_empty():
		return _fail_invalid("NPC_TRAVEL_STATE", "empty npc_id")
	var want := travel_state.strip_edges().to_upper()
	if want.is_empty():
		return _fail_invalid("NPC_TRAVEL_STATE", "empty travel_state")
	var ns := _resolve_peer("/root/NpcStateSystem")
	if ns == null or not ns.has_method("get_travel_state"):
		return _fail_missing("/root/NpcStateSystem", "NPC_TRAVEL_STATE")
	return str(ns.call("get_travel_state", npc_id)).to_upper() == want


func _eval_npc_destination(npc_id: String, destination_location_id: String) -> bool:
	if npc_id.is_empty() or destination_location_id.is_empty():
		return _fail_invalid("NPC_DESTINATION", "empty npc_id or destination")
	var ns := _resolve_peer("/root/NpcStateSystem")
	if ns == null or not ns.has_method("get_destination_location_id"):
		return _fail_missing("/root/NpcStateSystem", "NPC_DESTINATION")
	return str(ns.call("get_destination_location_id", npc_id)) == destination_location_id


func _eval_npc_at_location(npc_id: String, location_id: String) -> bool:
	if npc_id.is_empty() or location_id.is_empty():
		return _fail_invalid("NPC_AT_LOCATION", "empty npc_id or location_id")
	var travel := _resolve_peer("/root/NpcTravelSystem")
	if travel != null and travel.has_method("is_at_location"):
		return bool(travel.call("is_at_location", npc_id, location_id))
	# Fallback requires NpcStateSystem — missing either path → false.
	var ns := _resolve_peer("/root/NpcStateSystem")
	if ns == null:
		return _fail_missing("/root/NpcStateSystem", "NPC_AT_LOCATION")
	if ns.has_method("get_travel_state") and str(ns.call("get_travel_state", npc_id)) != "AT_LOCATION":
		return false
	if not ns.has_method("get_location_id"):
		return _fail_missing("/root/NpcStateSystem", "NPC_AT_LOCATION")
	return str(ns.call("get_location_id", npc_id)) == location_id


func _eval_relationship_min(npc_id: String, min_value: int) -> bool:
	if npc_id.is_empty():
		return _fail_invalid("RELATIONSHIP_MIN", "empty npc_id")
	var rs := _resolve_peer("/root/RelationshipSystem")
	if rs == null or not rs.has_method("get_relationship"):
		return _fail_missing("/root/RelationshipSystem", "RELATIONSHIP_MIN")
	return int(rs.call("get_relationship", npc_id)) >= min_value


func _eval_relationship_max(npc_id: String, max_value: int) -> bool:
	if npc_id.is_empty():
		return _fail_invalid("RELATIONSHIP_MAX", "empty npc_id")
	var rs := _resolve_peer("/root/RelationshipSystem")
	if rs == null or not rs.has_method("get_relationship"):
		return _fail_missing("/root/RelationshipSystem", "RELATIONSHIP_MAX")
	return int(rs.call("get_relationship", npc_id)) <= max_value


func _eval_reputation_min(group_id: String, min_value: int) -> bool:
	if group_id.is_empty():
		return _fail_invalid("REPUTATION_MIN", "empty group_id")
	var rs := _resolve_peer("/root/RelationshipSystem")
	if rs == null or not rs.has_method("get_reputation"):
		return _fail_missing("/root/RelationshipSystem", "REPUTATION_MIN")
	return int(rs.call("get_reputation", group_id)) >= min_value


func _eval_reputation_max(group_id: String, max_value: int) -> bool:
	if group_id.is_empty():
		return _fail_invalid("REPUTATION_MAX", "empty group_id")
	var rs := _resolve_peer("/root/RelationshipSystem")
	if rs == null or not rs.has_method("get_reputation"):
		return _fail_missing("/root/RelationshipSystem", "REPUTATION_MAX")
	return int(rs.call("get_reputation", group_id)) <= max_value


func _eval_narrative_hour_min(hour: int) -> bool:
	var gt := _resolve_peer("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_hour"):
		return _fail_missing("/root/GameTimeSystem", "NARRATIVE_HOUR_MIN")
	return int(gt.call("get_narrative_hour")) >= clampi(hour, 0, 23)


func _eval_narrative_hour_max(hour: int) -> bool:
	var gt := _resolve_peer("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_hour"):
		return _fail_missing("/root/GameTimeSystem", "NARRATIVE_HOUR_MAX")
	return int(gt.call("get_narrative_hour")) <= clampi(hour, 0, 23)


func _eval_narrative_day_min(day_index: int) -> bool:
	var gt := _resolve_peer("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_day_index"):
		return _fail_missing("/root/GameTimeSystem", "NARRATIVE_DAY_MIN")
	return int(gt.call("get_narrative_day_index")) >= maxi(day_index, 0)


func _eval_narrative_day_max(day_index: int) -> bool:
	var gt := _resolve_peer("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_day_index"):
		return _fail_missing("/root/GameTimeSystem", "NARRATIVE_DAY_MAX")
	return int(gt.call("get_narrative_day_index")) <= maxi(day_index, 0)


func _eval_narrative_time_range(start_minutes: int, end_minutes: float) -> bool:
	## Minutes-of-day window. Cross-midnight when start > end (e.g. 22:00–06:00).
	var gt := _resolve_peer("/root/GameTimeSystem")
	if gt == null or not gt.has_method("get_narrative_minutes_of_day"):
		return _fail_missing("/root/GameTimeSystem", "NARRATIVE_TIME_RANGE")
	var now := float(gt.call("get_narrative_minutes_of_day"))
	var start_m := float(posmod(start_minutes, 24 * 60))
	var end_m := fposmod(end_minutes, 24.0 * 60.0)
	if is_equal_approx(start_m, end_m):
		return true
	if start_m < end_m:
		return now >= start_m and now < end_m
	return now >= start_m or now < end_m
