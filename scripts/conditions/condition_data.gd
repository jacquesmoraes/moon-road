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
	DIALOGUE_SEEN,
	DIALOGUE_COMPLETED,
	DIALOGUE_CHOICE_SELECTED,
	DIALOGUE_COMPLETION_COUNT_MIN,
	NPC_STATE,
	NPC_MET,
	NPC_ENABLED,
	NPC_LOCATION,
}

@export var type: Type = Type.FLAG_EQUALS
## Primary id: flag / quest / item / poi / entity / upgrade / region / dialogue / choice / npc.
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
		Type.DIALOGUE_SEEN:
			return "DIALOGUE_SEEN"
		Type.DIALOGUE_COMPLETED:
			return "DIALOGUE_COMPLETED"
		Type.DIALOGUE_CHOICE_SELECTED:
			return "DIALOGUE_CHOICE_SELECTED"
		Type.DIALOGUE_COMPLETION_COUNT_MIN:
			return "DIALOGUE_COMPLETION_COUNT_MIN"
		Type.NPC_STATE:
			return "NPC_STATE"
		Type.NPC_MET:
			return "NPC_MET"
		Type.NPC_ENABLED:
			return "NPC_ENABLED"
		Type.NPC_LOCATION:
			return "NPC_LOCATION"
		_:
			return "UNKNOWN"
