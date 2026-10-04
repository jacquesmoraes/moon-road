extends Resource
class_name DialogueAction
## Declarative gameplay effect. Executed by DialogueActionExecutor —
## no scripts/eval in resources.

enum Type {
	SET_FLAG,
	START_QUEST,
	COMPLETE_QUEST,
	ADD_ITEM,
	REMOVE_ITEM,
	SET_WORLD_STATE,
	DISCOVER_POI,
}

@export var type: Type = Type.SET_FLAG
## flag / quest / item / poi / world-state entity id
@export var target_id: String = ""
## World-state key (SET_WORLD_STATE) or optional POI display name.
@export var secondary_id: String = ""
@export var string_value: String = ""
@export var int_value: int = 1
@export var bool_value: bool = true


func get_type_name() -> String:
	match type:
		Type.SET_FLAG:
			return "SET_FLAG"
		Type.START_QUEST:
			return "START_QUEST"
		Type.COMPLETE_QUEST:
			return "COMPLETE_QUEST"
		Type.ADD_ITEM:
			return "ADD_ITEM"
		Type.REMOVE_ITEM:
			return "REMOVE_ITEM"
		Type.SET_WORLD_STATE:
			return "SET_WORLD_STATE"
		Type.DISCOVER_POI:
			return "DISCOVER_POI"
		_:
			return "UNKNOWN"
