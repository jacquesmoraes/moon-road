extends Resource
class_name NpcScheduleData
## Data-driven daily routine for one NPC (narrative hours only).
## Future: multiple schedules per NPC selected by flags/quests/day/city — not yet.

@export var schedule_id: String = ""
@export var npc_id: String = ""
@export var enabled: bool = true
## Ordered windows; first matching enabled entry wins.
@export var entries: Array = [] ## Array of NpcScheduleEntry
## Used when no entry matches the current narrative hour.
@export var fallback_location_id: String = ""
@export var fallback_state: String = ""
@export var fallback_activity_id: String = ""
## Reserved for future schedule selection (flags/quests/day/city). Unused for now.
@export var selection_tags: PackedStringArray = []


func get_schedule_id() -> String:
	return schedule_id


func get_npc_id() -> String:
	return npc_id


func resolve_entry(hour_of_day: int) -> Resource:
	## Returns the first enabled NpcScheduleEntry containing hour, or null.
	if not enabled:
		return null
	for item in entries:
		if item == null:
			continue
		if not (item is Resource):
			continue
		if item.has_method("contains_hour") and bool(item.call("contains_hour", hour_of_day)):
			return item as Resource
	return null
