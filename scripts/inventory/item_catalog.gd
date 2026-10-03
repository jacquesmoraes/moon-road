extends Resource
class_name ItemCatalog
## Flat registry of ItemData keyed by id.

@export var entries: Array[ItemData] = []


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
