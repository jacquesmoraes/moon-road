extends Resource
class_name NpcDialogueRule
## One contextual dialogue option for an NPC. Evaluated by DialogueSystem —
## conditions go through ConditionSystem only (no quest/NPC ifs here).

@export var id: String = ""
@export var dialogue_id: String = ""
## Higher wins. Ties break by authored array index (lower index wins).
@export var priority: int = 0
## ConditionData entries. Empty = always eligible when enabled.
@export var conditions: Array = []
@export var require_all: bool = true
@export var enabled: bool = true
