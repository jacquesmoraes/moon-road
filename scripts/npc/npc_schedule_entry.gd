extends Resource
class_name NpcScheduleEntry
## One daily window in an NpcScheduleData. Hours use narrative world time.
## start_hour inclusive, end_hour exclusive (0–24). Cross-midnight when start > end
## (e.g. 22 → 6). Empty state = do not overwrite NpcState.current_state.

@export var start_hour: int = 0
@export var end_hour: int = 24
@export var location_id: String = ""
@export var state: String = ""
@export var activity_id: String = ""
@export var enabled: bool = true


func contains_hour(hour_of_day: int) -> bool:
	if not enabled:
		return false
	var hour := posmod(hour_of_day, 24)
	var start := clampi(start_hour, 0, 23)
	var end := clampi(end_hour, 0, 24)
	if start == end:
		return true
	if start < end:
		return hour >= start and hour < end
	# Wrap across midnight (e.g. 22 → 6).
	return hour >= start or hour < end
