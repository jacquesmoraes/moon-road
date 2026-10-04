extends Resource
class_name QuestData
## Lightweight quest definition. States live in QuestSystem by quest_id.

enum State {
	INACTIVE,
	ACTIVE,
	COMPLETED,
}

@export var quest_id: String = ""
@export var display_name: String = "Quest"
@export var description: String = ""
## NPC that offers / updates dialogue for this quest.
@export var giver_npc_id: String = ""
## Dialogue sequence start id — finishing it activates the quest.
@export var start_dialogue_id: String = ""
@export var active_dialogue_id: String = ""
@export var completed_dialogue_id: String = ""
## Parallel arrays: item_id[i] needs amounts[i].
@export var required_item_ids: PackedStringArray = []
@export var required_amounts: PackedInt32Array = []
## Interactable that consumes requirements and completes (e.g. viewpoint terminal).
@export var turn_in_target: String = "viewpoint_terminal"
## DialogueAction resources run via DialogueActionExecutor on successful complete.
@export var on_complete_actions: Array = []


func get_requirements() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := mini(required_item_ids.size(), required_amounts.size())
	for i in range(n):
		var id := str(required_item_ids[i])
		var amt := int(required_amounts[i])
		if id.is_empty() or amt <= 0:
			continue
		out.append({"item_id": id, "amount": amt})
	return out


static func state_name(state: State) -> String:
	match state:
		State.ACTIVE:
			return "ACTIVE"
		State.COMPLETED:
			return "COMPLETED"
		_:
			return "INACTIVE"
