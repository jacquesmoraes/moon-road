extends CanvasLayer
class_name CraftingDebugUI
## Minimal recipe picker for Workbench. Calls CraftingSystem — owns no craft logic.

@onready var _root: Control = $Root
@onready var _list: Label = $Root/Panel/Margin/VBox/ListLabel
@onready var _status: Label = $Root/Panel/Margin/VBox/StatusLabel
@onready var _hint: Label = $Root/Panel/Margin/VBox/HintLabel

var _crafting: Node
var _inventory: Node
var _visible_panel: bool = false
var _selected_index: int = 0
var _recipe_ids: PackedStringArray = []
var _workbench: Node = null


func _ready() -> void:
	layer = 93
	add_to_group("crafting_debug_ui")
	_crafting = get_node_or_null("/root/CraftingSystem")
	_inventory = get_node_or_null("/root/InventorySystem")
	if _crafting != null:
		if _crafting.has_signal("craft_succeeded") and not _crafting.craft_succeeded.is_connected(_on_craft_succeeded):
			_crafting.craft_succeeded.connect(_on_craft_succeeded)
		if _crafting.has_signal("craft_failed") and not _crafting.craft_failed.is_connected(_on_craft_failed):
			_crafting.craft_failed.connect(_on_craft_failed)
	if _inventory != null and _inventory.has_signal("inventory_changed"):
		if not _inventory.inventory_changed.is_connected(_on_inventory_changed):
			_inventory.inventory_changed.connect(_on_inventory_changed)
	_set_panel_visible(false)
	set_process_unhandled_input(true)


func is_panel_visible() -> bool:
	return _visible_panel


func open_for_workbench(bench: Node = null) -> void:
	_workbench = bench
	_set_panel_visible(true)


func open() -> void:
	_set_panel_visible(true)


func close() -> void:
	_set_panel_visible(false)
	_workbench = null


func _unhandled_input(event: InputEvent) -> void:
	if not _visible_panel:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("inventory_debug_toggle"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_up") or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_UP):
		_move_selection(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_down") or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_DOWN):
		_move_selection(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_accept") or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_C):
		_try_craft_selected()
		get_viewport().set_input_as_handled()
		return


func _set_panel_visible(show_panel: bool) -> void:
	_visible_panel = show_panel
	if _root != null:
		_root.visible = show_panel
	if show_panel:
		_refresh_ids()
		_refresh()
		if _status != null:
			_status.text = "Select a recipe, then Enter/C to craft."


func _move_selection(delta: int) -> void:
	if _recipe_ids.is_empty():
		_selected_index = 0
		_refresh()
		return
	_selected_index = wrapi(_selected_index + delta, 0, _recipe_ids.size())
	_refresh()


func _try_craft_selected() -> void:
	if _crafting == null:
		_crafting = get_node_or_null("/root/CraftingSystem")
	if _crafting == null or _recipe_ids.is_empty():
		if _status != null:
			_status.text = "No recipes."
		return
	_selected_index = clampi(_selected_index, 0, _recipe_ids.size() - 1)
	var recipe_id := str(_recipe_ids[_selected_index])
	_crafting.call("craft", recipe_id)
	_refresh()


func _on_craft_succeeded(recipe_id: String, output_item_id: String, output_quantity: int) -> void:
	if not _visible_panel:
		return
	if _status != null:
		_status.text = "Crafted +%d %s (%s)" % [output_quantity, output_item_id, recipe_id]
	_refresh()


func _on_craft_failed(recipe_id: String, reason: String) -> void:
	if not _visible_panel:
		return
	if _status != null:
		_status.text = "Failed: %s (%s)" % [reason, recipe_id]
	_refresh()


func _on_inventory_changed(_item_id: String, _quantity: int) -> void:
	if _visible_panel:
		_refresh()


func _refresh_ids() -> void:
	if _crafting == null:
		_crafting = get_node_or_null("/root/CraftingSystem")
	_recipe_ids = PackedStringArray()
	if _crafting != null and _crafting.has_method("get_recipe_ids"):
		_recipe_ids = _crafting.call("get_recipe_ids")
	if _selected_index >= _recipe_ids.size():
		_selected_index = maxi(_recipe_ids.size() - 1, 0)


func _refresh() -> void:
	_refresh_ids()
	if _list == null:
		return
	if _crafting == null:
		_list.text = "(CraftingSystem missing)"
		return
	if _recipe_ids.is_empty():
		_list.text = "(no recipes)"
		return

	var lines: PackedStringArray = []
	for i in range(_recipe_ids.size()):
		var recipe_id := str(_recipe_ids[i])
		var recipe: Resource = _crafting.call("get_recipe", recipe_id)
		var title := recipe_id
		var ingredients_txt := ""
		var can := false
		if recipe != null:
			if "display_name" in recipe and not str(recipe.get("display_name")).is_empty():
				title = str(recipe.get("display_name"))
			if recipe.has_method("get_ingredients"):
				var parts: PackedStringArray = []
				for req in recipe.call("get_ingredients"):
					parts.append("%sx %s" % [int(req.get("amount", 0)), str(req.get("item_id", ""))])
				ingredients_txt = ", ".join(parts)
			var out_id := str(recipe.get("output_item_id"))
			var out_qty := int(recipe.get("output_quantity"))
			can = bool(_crafting.call("can_craft", recipe_id))
			var marker := ">" if i == _selected_index else " "
			var ready := "OK" if can else "need"
			lines.append("%s %s → +%d %s  [%s]" % [marker, title, out_qty, out_id, ready])
			if not ingredients_txt.is_empty():
				lines.append("    %s" % ingredients_txt)
		else:
			lines.append("%s %s" % [">" if i == _selected_index else " ", recipe_id])
	_list.text = "\n".join(lines)
	if _hint != null:
		_hint.text = "↑↓ select · Enter/C craft · Esc close"
