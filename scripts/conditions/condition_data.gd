extends Resource
class_name ConditionData
## Data-driven gameplay condition. Evaluated by ConditionSystem — no quest/NPC ifs here.

enum Type {
	FLAG_EQUALS,
	QUEST_STATE,
	HAS_ITEM,
	ITEM_QUANTITY,
	POI_DISCOVERED,
	WORLD_STATE_EQUALS,
	VEHICLE_HAS_UPGRADE,
	REGION_IS,
	JOURNEY_DISTANCE_MIN,
	JOURNEY_DISTANCE_MAX,
}

@export var type: Type = Type.FLAG_EQUALS
## Primary id: flag / quest / item / poi / entity / upgrade / region.
@export var key: String = ""
## Secondary id when needed (e.g. WorldState key).
@export var secondary_key: String = ""
@export var string_value: String = ""
@export var int_value: int = 0
@export var float_value: float = 0.0
@export var bool_value: bool = true


func get_type_name() -> String:
	match type:
		Type.FLAG_EQUALS:
			return "FLAG_EQUALS"
		Type.QUEST_STATE:
			return "QUEST_STATE"
		Type.HAS_ITEM:
			return "HAS_ITEM"
		Type.ITEM_QUANTITY:
			return "ITEM_QUANTITY"
		Type.POI_DISCOVERED:
			return "POI_DISCOVERED"
		Type.WORLD_STATE_EQUALS:
			return "WORLD_STATE_EQUALS"
		Type.VEHICLE_HAS_UPGRADE:
			return "VEHICLE_HAS_UPGRADE"
		Type.REGION_IS:
			return "REGION_IS"
		Type.JOURNEY_DISTANCE_MIN:
			return "JOURNEY_DISTANCE_MIN"
		Type.JOURNEY_DISTANCE_MAX:
			return "JOURNEY_DISTANCE_MAX"
		_:
			return "UNKNOWN"
