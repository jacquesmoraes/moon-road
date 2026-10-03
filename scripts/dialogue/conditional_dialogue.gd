extends Resource
class_name ConditionalDialogue
## Extension point: show dialogue_id when condition passes (or always if condition is null).

@export var condition: Resource ## ConditionData
@export var dialogue_id: String = ""
