extends Node
## Persistent NPC relationship and place/group reputation.
## Two separate maps — never mixed. No romance, no DialogueSystem coupling.
## Values clamped to configurable min/max (default -100..+100).

signal relationship_changed(npc_id: String, value: int, delta: int)
signal reputation_changed(group_id: String, value: int, delta: int)
signal relationships_cleared

@export var min_value: int = -100
@export var max_value: int = 100

## npc_id → int
var _relationships: Dictionary = {}
## group_id (city/community/POI/faction) → int
var _reputations: Dictionary = {}


func get_relationship(npc_id: String) -> int:
	if npc_id.is_empty():
		return 0
	return int(_relationships.get(npc_id, 0))


func set_relationship(npc_id: String, value: int) -> int:
	if npc_id.is_empty():
		return 0
	var previous := get_relationship(npc_id)
	var next := _clamp(value)
	if previous == next and _relationships.has(npc_id):
		return next
	_relationships[npc_id] = next
	relationship_changed.emit(npc_id, next, next - previous)
	return next


func add_relationship(npc_id: String, delta: int) -> int:
	if npc_id.is_empty():
		return 0
	return set_relationship(npc_id, get_relationship(npc_id) + delta)


func get_reputation(group_id: String) -> int:
	if group_id.is_empty():
		return 0
	return int(_reputations.get(group_id, 0))


func set_reputation(group_id: String, value: int) -> int:
	if group_id.is_empty():
		return 0
	var previous := get_reputation(group_id)
	var next := _clamp(value)
	if previous == next and _reputations.has(group_id):
		return next
	_reputations[group_id] = next
	reputation_changed.emit(group_id, next, next - previous)
	return next


func add_reputation(group_id: String, delta: int) -> int:
	if group_id.is_empty():
		return 0
	return set_reputation(group_id, get_reputation(group_id) + delta)


## Optional display helper — not used by gameplay gates.
func get_relationship_tier(npc_id: String) -> String:
	return tier_name(get_relationship(npc_id))


func get_reputation_tier(group_id: String) -> String:
	return tier_name(get_reputation(group_id))


func tier_name(value: int) -> String:
	var v := _clamp(value)
	if v <= -60:
		return "HOSTILE"
	if v <= -20:
		return "UNFRIENDLY"
	if v < 20:
		return "NEUTRAL"
	if v < 60:
		return "FRIENDLY"
	return "TRUSTED"


func reset_for_tests() -> void:
	_relationships.clear()
	_reputations.clear()
	relationships_cleared.emit()


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	return {
		"relationships": _relationships.duplicate(),
		"reputations": _reputations.duplicate(),
		"min_value": min_value,
		"max_value": max_value,
	}


func load_save_data(data: Dictionary) -> void:
	_relationships.clear()
	_reputations.clear()
	if data == null or data.is_empty():
		relationships_cleared.emit()
		return
	if data.has("min_value"):
		min_value = int(data.get("min_value"))
	if data.has("max_value"):
		max_value = int(data.get("max_value"))
	_normalize_clamp_range()
	_load_map(data.get("relationships", {}), _relationships)
	_load_map(data.get("reputations", {}), _reputations)
	relationships_cleared.emit()


func _load_map(raw: Variant, into: Dictionary) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for key in raw.keys():
		var id := str(key)
		if id.is_empty():
			continue
		into[id] = _clamp(int(raw[key]))


func _clamp(value: int) -> int:
	_normalize_clamp_range()
	return clampi(value, min_value, max_value)


func _normalize_clamp_range() -> void:
	if min_value > max_value:
		var tmp := min_value
		min_value = max_value
		max_value = tmp
