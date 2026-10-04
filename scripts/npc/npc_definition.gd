extends Resource
class_name NpcDefinition
## Static authoring data for a world NPC. Mutable campaign fields live in NpcStateSystem.
## Dialogue selection uses dialogue_rules + fallback_dialogue_id (priority resolve).

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
## Used when no dialogue_rule matches (or rules list is empty).
@export var fallback_dialogue_id: String = ""
## Priority-ranked contextual rules (NpcDialogueRule). Highest valid priority wins.
@export var dialogue_rules: Array = []
## Optional quest link for turn-in / helpers — not used for dialogue picking.
@export var linked_quest_id: String = ""
## Legacy one-liner fallback when no dialogue resolves (prefer fallback_dialogue_id).
@export var greeting_line: String = ""

## --- Legacy fields (kept for older resources; prefer dialogue_rules) ---
## Alias for fallback_dialogue_id when fallback is empty.
@export var dialogue_id: String = ""
## Legacy first-match gates. Ignored when dialogue_rules is non-empty.
@export var conditional_dialogues: Array = []


func get_presence_mode_name() -> String:
	match presence_mode:
		PresenceMode.ROUTINE:
			return "ROUTINE"
		PresenceMode.TRAVELING:
			return "TRAVELING"
		_:
			return "STATIC"


func get_fallback_dialogue_id() -> String:
	if not fallback_dialogue_id.is_empty():
		return fallback_dialogue_id
	return dialogue_id
