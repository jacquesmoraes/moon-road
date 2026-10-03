extends Resource
class_name NpcDefinition
## Data for a world NPC. Lives outside PlayerCharacter and the POI autoload.
## Ready for static, routine, and traveling presence later — behavior hooks stay empty for now.

enum PresenceMode {
	STATIC, ## Stays at a placed transform (default foundation).
	ROUTINE, ## Future: schedule / day cycle at a location.
	TRAVELING, ## Future: moves along the road / between stops.
}

@export var npc_id: String = ""
@export var display_name: String = "NPC"
@export var role: String = "traveler"
@export var enabled: bool = true
@export var presence_mode: PresenceMode = PresenceMode.STATIC
## Default / fallback dialogue id. QuestSystem may override via linked_quest_id.
@export var dialogue_id: String = ""
## If set, dialogue resolves from QuestSystem state for this quest.
@export var linked_quest_id: String = ""
## Condition-gated dialogue overrides (checked before quest helper). First match wins.
@export var conditional_dialogues: Array = []
## Legacy one-liner fallback when dialogue_id is empty (prefer dialogue_id).
@export var greeting_line: String = ""


func get_presence_mode_name() -> String:
	match presence_mode:
		PresenceMode.ROUTINE:
			return "ROUTINE"
		PresenceMode.TRAVELING:
			return "TRAVELING"
		_:
			return "STATIC"
