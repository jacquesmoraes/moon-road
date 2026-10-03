extends Node
## Crafting foundation — recipes by id. Uses InventorySystem only (no NPC coupling).
## No craft time, quality, tech tree, or auto-craft.

signal craft_succeeded(recipe_id: String, output_item_id: String, output_quantity: int)
signal craft_failed(recipe_id: String, reason: String)

const DEFAULT_CATALOG_PATH := "res://resources/crafting/default_recipe_catalog.tres"

@export_file("*.tres") var catalog_path: String = DEFAULT_CATALOG_PATH

var _by_id: Dictionary = {}


func _ready() -> void:
	_load_catalog()


func has_recipe(recipe_id: String) -> bool:
	_ensure_index()
	return _by_id.has(recipe_id)


func get_recipe(recipe_id: String) -> Resource:
	_ensure_index()
	return _by_id.get(recipe_id, null)


func get_recipe_ids() -> PackedStringArray:
	_ensure_index()
	var ids: PackedStringArray = []
	for key in _by_id.keys():
		ids.append(str(key))
	ids.sort()
	return ids


func get_all_recipes() -> Array:
	_ensure_index()
	var out: Array = []
	for key in get_recipe_ids():
		out.append(_by_id[key])
	return out


func register_recipe(data: Resource) -> void:
	if data == null:
		return
	var key := str(data.get("id"))
	if key.is_empty():
		return
	_by_id[key] = data


func can_craft(recipe_id: String) -> bool:
	return _validate_craft(recipe_id).is_empty()


func get_craft_block_reason(recipe_id: String) -> String:
	return _validate_craft(recipe_id)


## Consumes ingredients only when all are present, then adds the output. Atomic.
func craft(recipe_id: String) -> bool:
	var reason := _validate_craft(recipe_id)
	if not reason.is_empty():
		craft_failed.emit(recipe_id, reason)
		print("CraftingSystem: craft failed '%s' (%s)" % [recipe_id, reason])
		return false

	var recipe: Resource = get_recipe(recipe_id)
	var inv := _inventory()
	var ingredients: Array = recipe.call("get_ingredients") if recipe.has_method("get_ingredients") else []
	for req in ingredients:
		var item_id := str(req.get("item_id", ""))
		var amount := int(req.get("amount", 0))
		var removed: int = int(inv.call("remove_item", item_id, amount))
		if removed < amount:
			craft_failed.emit(recipe_id, "consume_failed")
			return false

	var out_id := str(recipe.get("output_item_id"))
	var out_qty := maxi(int(recipe.get("output_quantity")), 1)
	var added: int = int(inv.call("add_item", out_id, out_qty))
	if added < out_qty:
		# Extremely unlikely after validation; report failure (ingredients already gone).
		craft_failed.emit(recipe_id, "output_add_failed")
		return false

	craft_succeeded.emit(recipe_id, out_id, out_qty)
	print("CraftingSystem: crafted '%s' → +%d %s" % [recipe_id, out_qty, out_id])
	return true


func _validate_craft(recipe_id: String) -> String:
	if recipe_id.is_empty():
		return "empty_id"
	var recipe: Resource = get_recipe(recipe_id)
	if recipe == null:
		return "unknown_recipe"
	var inv := _inventory()
	if inv == null:
		return "no_inventory"
	var out_id := str(recipe.get("output_item_id"))
	var out_qty := maxi(int(recipe.get("output_quantity")), 1)
	if out_id.is_empty() or not bool(inv.call("has_item_data", out_id)):
		return "unknown_output"
	var ingredients: Array = recipe.call("get_ingredients") if recipe.has_method("get_ingredients") else []
	if ingredients.is_empty():
		return "no_ingredients"
	for req in ingredients:
		var item_id := str(req.get("item_id", ""))
		var amount := int(req.get("amount", 0))
		if not bool(inv.call("has_item_data", item_id)):
			return "unknown_ingredient"
		if not bool(inv.call("has_item", item_id, amount)):
			return "missing_ingredients"
	# Ensure output fits in stack.
	var data: Resource = inv.call("get_item_data", out_id)
	var max_stack := 99
	if data != null and data.has_method("get_effective_max_stack"):
		max_stack = int(data.call("get_effective_max_stack"))
	var current := int(inv.call("get_quantity", out_id))
	if current + out_qty > max_stack:
		return "output_full"
	return ""


func _inventory() -> Node:
	return get_node_or_null("/root/InventorySystem")


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
