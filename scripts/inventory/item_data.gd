extends Resource
class_name ItemData
## Static item definition. Inventory stores quantities by id — never scene refs.

enum Category {
	RESOURCE,
	COMPONENT,
	TOOL,
	CONSUMABLE,
	QUEST,
}

@export var id: String = ""
@export var display_name: String = "Item"
@export var description: String = ""
@export var stackable: bool = true
## Cap for stackable items. Non-stackable items are treated as max_stack = 1.
@export var max_stack: int = 99
@export var category: Category = Category.RESOURCE


func get_category_name() -> String:
	match category:
		Category.COMPONENT:
			return "COMPONENT"
		Category.TOOL:
			return "TOOL"
		Category.CONSUMABLE:
			return "CONSUMABLE"
		Category.QUEST:
			return "QUEST"
		_:
			return "RESOURCE"


func get_effective_max_stack() -> int:
	if not stackable:
		return 1
	return maxi(max_stack, 1)
