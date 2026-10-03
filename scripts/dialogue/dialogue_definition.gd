extends Resource
class_name DialogueDefinition
## One line of dialogue. Chain with next_dialogue_id for short linear sequences.
## No choices / branching yet — reserved fields stay empty for later flags & quests.

@export var id: String = ""
@export var speaker_name: String = ""
@export var text: String = ""
## Empty → end of sequence after this line.
@export var next_dialogue_id: String = ""

@export_group("Future (unused)")
## Reserved: gate this line on world/quest flags.
@export var required_flags: PackedStringArray = []
## Reserved: set when the line is shown.
@export var set_flags_on_show: PackedStringArray = []
## Reserved: choice option ids (branching later).
@export var choice_ids: PackedStringArray = []


func is_terminal() -> bool:
	return next_dialogue_id.is_empty()
