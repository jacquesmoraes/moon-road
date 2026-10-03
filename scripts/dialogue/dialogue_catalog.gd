extends Resource
class_name DialogueCatalog
## Flat registry of DialogueDefinition entries keyed by id.
## Author sequences by linking next_dialogue_id across entries.

@export var entries: Array[DialogueDefinition] = []


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
