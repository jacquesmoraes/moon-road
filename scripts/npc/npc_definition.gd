extends Resource
class_name NpcDefinition
## Static authoring data for a world NPC. Mutable campaign fields live in NpcStateSystem.
## Dialogue selection uses dialogue_rules + fallback_dialogue_id (priority resolve).

enum PresenceMode {
	STATIC, ## Stays at a placed transform / fixed POI.
	LOCAL_SCHEDULE, ## Day cycle via NpcScheduleSystem inside one POI/area.
	TRAVELER, ## Logical relocation between locations (NpcTravelSystem).
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

## Inclusive narrative hour start (0–23). Negative = always available (no window).
@export var available_hour_min: int = -1
## Exclusive narrative hour end (0–24). Negative = always available.
## Example Mira 08:00–18:00 → min=8, max=18 (present for hours 8..17).
@export var available_hour_max: int = -1

## --- Legacy fields (kept for older resources; prefer dialogue_rules) ---
## Alias for fallback_dialogue_id when fallback is empty.
@export var dialogue_id: String = ""
## Legacy first-match gates. Ignored when dialogue_rules is non-empty.
@export var conditional_dialogues: Array = []


func get_presence_mode_name() -> String:
	match presence_mode:
		PresenceMode.LOCAL_SCHEDULE:
			return "LOCAL_SCHEDULE"
		PresenceMode.TRAVELER:
			return "TRAVELER"
		_:
			return "STATIC"


func get_fallback_dialogue_id() -> String:
	if not fallback_dialogue_id.is_empty():
		return fallback_dialogue_id
	return dialogue_id


func has_availability_window() -> bool:
	return available_hour_min >= 0 and available_hour_max >= 0


func is_hour_within_availability(hour_of_day: int) -> bool:
	if not has_availability_window():
		return true
	var hour := posmod(hour_of_day, 24)
	var start := clampi(available_hour_min, 0, 23)
	var end := clampi(available_hour_max, 0, 24)
	if start == end:
		return true
	if start < end:
		return hour >= start and hour < end
	# Wrap across midnight (e.g. 22 → 6).
	return hour >= start or hour < end
