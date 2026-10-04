extends Resource
class_name DialogueChoice
## One selectable reply on a DialogueDefinition.
## Visibility / interactability are gated only via ConditionSystem lists —
## DialogueSystem never inspects inventory, quests, or flags itself.

@export var id: String = ""
@export var text: String = ""
## Empty → end dialogue when this choice is confirmed.
@export var next_dialogue_id: String = ""
## Authoring kill-switch: false → choice is hidden.
@export var enabled: bool = true

@export_group("Conditions")
## Hide this choice when the list fails.
@export var show_conditions: Array[Resource] = []
## true = ConditionSystem.evaluate_all; false = evaluate_any.
@export var show_require_all: bool = true
## Choice stays visible but not confirmable when this list fails.
@export var enable_conditions: Array[Resource] = []
@export var enable_require_all: bool = true

@export_group("Actions")
## Run once when this choice is confirmed in the current conversation.
@export var on_choose_actions: Array[DialogueAction] = []
