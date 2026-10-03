extends Resource
class_name UpgradeCatalog
## Flat registry of UpgradeData keyed by id.

@export var entries: Array = []


func build_index() -> Dictionary:
	var out: Dictionary = {}
	for entry in entries:
		if entry == null:
			continue
		var key := str(entry.get("id"))
		if key.is_empty():
			continue
		out[key] = entry
	return out
