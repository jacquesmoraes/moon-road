extends Resource
class_name RecipeCatalog
## Flat registry of RecipeData keyed by id.

@export var entries: Array[RecipeData] = []


func build_index() -> Dictionary:
	var out: Dictionary = {}
	for entry in entries:
		if entry == null:
			continue
		var key := str(entry.id)
		if key.is_empty():
			continue
		out[key] = entry
	return out
