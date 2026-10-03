extends Resource
class_name DialogueDefinition
## One line of dialogue. Chain with next_dialogue_id for linear talk, or
## author choices[] for a branching reply list (zero or more).

@export var id: String = ""
@export var speaker_name: String = ""
@export var text: String = ""
## Empty → end of sequence after this line (when no available choices).
@export var next_dialogue_id: String = ""
## Branching replies. When any are available, continue confirms the selection
## instead of following next_dialogue_id.
@export var choices: Array[DialogueChoice] = []

@export_group("Future (unused)")
## Reserved: gate this line on world/quest flags.
@export var required_flags: PackedStringArray = []
## Reserved: set when the line is shown.
@export var set_flags_on_show: PackedStringArray = []


func has_choices() -> bool:
	return not choices.is_empty()


func is_terminal() -> bool:
	return next_dialogue_id.is_empty() and choices.is_empty()
