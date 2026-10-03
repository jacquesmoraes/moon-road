extends Resource
class_name DialogueChoice
## One selectable reply on a DialogueDefinition. No effects / flags / skill checks yet.
## Optional conditions gate visibility via ConditionSystem.evaluate_all.

@export var id: String = ""
@export var text: String = ""
## Empty → end dialogue when this choice is confirmed.
@export var next_dialogue_id: String = ""
@export var enabled: bool = true
## ConditionData resources; empty = always available (when enabled).
@export var conditions: Array[Resource] = []
