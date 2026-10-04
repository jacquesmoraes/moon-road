extends Resource
class_name ConditionData
## Data-driven gameplay condition. Evaluated by ConditionSystem — no quest/NPC ifs here.
## ConditionSystem is fail-closed: missing peers / empty ids / unknown type → false.

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
	RELATIONSHIP_MIN,
	RELATIONSHIP_MAX,
	REPUTATION_MIN,
	REPUTATION_MAX,
	## Narrative world clock (GameTimeSystem) — never system/play/travel clock.
	NARRATIVE_HOUR_MIN,
	NARRATIVE_HOUR_MAX,
	NARRATIVE_DAY_MIN,
	NARRATIVE_DAY_MAX,
	NARRATIVE_TIME_RANGE,
	## Logical traveler relocation (NpcTravelSystem / NpcStateSystem).
	NPC_TRAVEL_STATE,
	NPC_DESTINATION,
	NPC_AT_LOCATION,
}

@export var type: Type = Type.FLAG_EQUALS
## Primary id: flag / quest / item / poi / entity / upgrade / region / dialogue / choice / npc / group.
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
		Type.RELATIONSHIP_MIN:
			return "RELATIONSHIP_MIN"
		Type.RELATIONSHIP_MAX:
			return "RELATIONSHIP_MAX"
		Type.REPUTATION_MIN:
			return "REPUTATION_MIN"
		Type.REPUTATION_MAX:
			return "REPUTATION_MAX"
		Type.NARRATIVE_HOUR_MIN:
			return "NARRATIVE_HOUR_MIN"
		Type.NARRATIVE_HOUR_MAX:
			return "NARRATIVE_HOUR_MAX"
		Type.NARRATIVE_DAY_MIN:
			return "NARRATIVE_DAY_MIN"
		Type.NARRATIVE_DAY_MAX:
			return "NARRATIVE_DAY_MAX"
		Type.NARRATIVE_TIME_RANGE:
			return "NARRATIVE_TIME_RANGE"
		Type.NPC_TRAVEL_STATE:
			return "NPC_TRAVEL_STATE"
		Type.NPC_DESTINATION:
			return "NPC_DESTINATION"
		Type.NPC_AT_LOCATION:
			return "NPC_AT_LOCATION"
		_:
			return "UNKNOWN"
