extends Node
## Player inventory — quantities by item id. No UI / NPC / shop coupling.
## Future systems (loot, shops, recipes) call the same add/remove/has/get API.

signal inventory_changed(item_id: String, quantity: int)
signal inventory_cleared

const DEFAULT_CATALOG_PATH := "res://resources/inventory/default_item_catalog.tres"

@export_file("*.tres") var catalog_path: String = DEFAULT_CATALOG_PATH

## item_id → quantity (never negative).
var _quantities: Dictionary = {}
var _by_id: Dictionary = {}


func _ready() -> void:
	_load_catalog()


func add_item(item_id: String, amount: int = 1) -> int:
	## Adds up to stack limit. Returns how many were actually added (0 if none).
	if item_id.is_empty() or amount <= 0:
		return 0
	_ensure_index()
	var data: Resource = _by_id.get(item_id, null)
	if data == null:
		push_warning("InventorySystem: unknown item_id '%s'" % item_id)
		return 0

	var max_stack := 99
	if data.has_method("get_effective_max_stack"):
		max_stack = int(data.call("get_effective_max_stack"))
	elif "max_stack" in data:
		max_stack = maxi(int(data.get("max_stack")), 1)
		if "stackable" in data and not bool(data.get("stackable")):
			max_stack = 1

	var current := get_quantity(item_id)
	var room := maxi(max_stack - current, 0)
	var added := mini(amount, room)
	if added <= 0:
		return 0
	_quantities[item_id] = current + added
	inventory_changed.emit(item_id, int(_quantities[item_id]))
	return added


func remove_item(item_id: String, amount: int = 1) -> int:
	## Removes up to available quantity. Never goes negative. Returns how many removed.
	if item_id.is_empty() or amount <= 0:
		return 0
	var current := get_quantity(item_id)
	if current <= 0:
		return 0
	var removed := mini(amount, current)
	var next_qty := current - removed
	if next_qty <= 0:
		_quantities.erase(item_id)
		inventory_changed.emit(item_id, 0)
	else:
		_quantities[item_id] = next_qty
		inventory_changed.emit(item_id, next_qty)
	return removed


func has_item(item_id: String, amount: int = 1) -> bool:
	if amount <= 0:
		return true
	return get_quantity(item_id) >= amount


func get_quantity(item_id: String) -> int:
	if item_id.is_empty():
		return 0
	return maxi(int(_quantities.get(item_id, 0)), 0)


func get_all_quantities() -> Dictionary:
	## Shallow copy: item_id → quantity.
	return _quantities.duplicate()


func get_item_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for key in _quantities.keys():
		if get_quantity(str(key)) > 0:
			ids.append(str(key))
	ids.sort()
	return ids


func get_item_data(item_id: String) -> Resource:
	_ensure_index()
	return _by_id.get(item_id, null)


func has_item_data(item_id: String) -> bool:
	_ensure_index()
	return _by_id.has(item_id)


func register_item(data: Resource) -> void:
	if data == null:
		return
	var key := str(data.get("id"))
	if key.is_empty():
		return
	_by_id[key] = data


func clear_inventory() -> void:
	_quantities.clear()
	inventory_cleared.emit()


func reload_catalog() -> void:
	_by_id.clear()
	_load_catalog()


func _ensure_index() -> void:
	if not _by_id.is_empty():
		return
	_load_catalog()


func _load_catalog() -> void:
	var catalog: Resource = null
	if not catalog_path.is_empty() and ResourceLoader.exists(catalog_path):
		catalog = load(catalog_path)
	if catalog != null and catalog.has_method("build_index"):
		var built: Dictionary = catalog.call("build_index")
		for key in built.keys():
			_by_id[str(key)] = built[key]
	elif catalog != null and "entries" in catalog:
		for entry in catalog.entries:
			if entry == null:
				continue
			var key := str(entry.get("id"))
			if not key.is_empty():
				_by_id[key] = entry
