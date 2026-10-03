extends Resource
class_name QuestCatalog
## Flat registry of QuestData keyed by quest_id.

@export var entries: Array[QuestData] = []


func build_index() -> Dictionary:
	var out: Dictionary = {}
	for entry in entries:
		if entry == null:
			continue
		var key := str(entry.quest_id)
		if key.is_empty():
			continue
		out[key] = entry
	return out
