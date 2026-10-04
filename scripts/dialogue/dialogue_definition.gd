extends Resource
class_name DialogueDefinition
## One line of dialogue. Chain with next_dialogue_id for linear talk, or
## author choices[] for a branching reply list (zero or more).
## show_conditions gate whether this line can appear (via ConditionSystem).

@export var id: String = ""
@export var speaker_name: String = ""
@export var text: String = ""
## Empty → end of sequence after this line (when no visible choices).
@export var next_dialogue_id: String = ""
## Branching replies. When any are selectable, continue confirms the selection
## instead of following next_dialogue_id.
@export var choices: Array[DialogueChoice] = []

@export_group("Conditions")
## Hide / skip this line when the list fails.
@export var show_conditions: Array[Resource] = []
## true = ConditionSystem.evaluate_all; false = evaluate_any.
@export var show_require_all: bool = true
## Used when this line fails show_conditions, or when all choices are hidden.
@export var fallback_dialogue_id: String = ""

@export_group("Future (unused)")
## Reserved: set when the line is shown.
@export var set_flags_on_show: PackedStringArray = []


func has_choices() -> bool:
	return not choices.is_empty()


func is_terminal() -> bool:
	return next_dialogue_id.is_empty() and choices.is_empty()
