extends Resource
class_name BarkData
## Short non-interactive NPC line. Selected by BarkSystem — never opens DialogueUI.

const TRIGGER_PLAYER_NEARBY := "PLAYER_NEARBY"
const TRIGGER_PLAYER_ENTER_AREA := "PLAYER_ENTER_AREA"
const TRIGGER_TIME_INTERVAL := "TIME_INTERVAL"
const TRIGGER_NPC_STATE_CHANGED := "NPC_STATE_CHANGED"

@export var id: String = ""
@export_multiline var text: String = ""
## Higher wins. Ties use weight among equal priority.
@export var priority: int = 0
## Per-bark cooldown after this id is spoken (real seconds).
@export var cooldown_seconds: float = 45.0
## ConditionData entries. Empty = always eligible when enabled.
@export var conditions: Array = []
@export var require_all: bool = true
## Relative chance among equal-priority candidates (must be > 0).
@export var weight: float = 1.0
@export var enabled: bool = true
## Which triggers may fire this bark. Empty = PLAYER_NEARBY + PLAYER_ENTER_AREA.
@export var triggers: PackedStringArray = PackedStringArray([
	TRIGGER_PLAYER_NEARBY,
	TRIGGER_PLAYER_ENTER_AREA,
])


func supports_trigger(trigger: String) -> bool:
	var tag := trigger.strip_edges().to_upper()
	if tag.is_empty():
		return false
	if triggers.is_empty():
		return (
			tag == TRIGGER_PLAYER_NEARBY
			or tag == TRIGGER_PLAYER_ENTER_AREA
		)
	for entry in triggers:
		if str(entry).strip_edges().to_upper() == tag:
			return true
	return false


func get_weight() -> float:
	return maxf(weight, 0.0001)
