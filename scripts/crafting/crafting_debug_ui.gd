extends CanvasLayer
class_name CraftingDebugUI
## Workbench debug panel: Craft recipes or Install vehicle upgrades.
## Calls CraftingSystem / VehicleStateSystem — owns no craft/install logic.

enum PanelMode { CRAFT, INSTALL }

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Panel/Margin/VBox/TitleLabel
@onready var _list: Label = $Root/Panel/Margin/VBox/ListLabel
@onready var _status: Label = $Root/Panel/Margin/VBox/StatusLabel
@onready var _hint: Label = $Root/Panel/Margin/VBox/HintLabel

var _crafting: Node
var _inventory: Node
var _vehicle_state: Node
var _visible_panel: bool = false
var _selected_index: int = 0
var _recipe_ids: PackedStringArray = []
var _upgrade_ids: PackedStringArray = []
var _workbench: Node = null
var _mode: PanelMode = PanelMode.CRAFT


func _ready() -> void:
	layer = 93
	add_to_group("crafting_debug_ui")
	_crafting = get_node_or_null("/root/CraftingSystem")
	_inventory = get_node_or_null("/root/InventorySystem")
	_vehicle_state = get_node_or_null("/root/VehicleStateSystem")
	if _crafting != null:
		if _crafting.has_signal("craft_succeeded") and not _crafting.craft_succeeded.is_connected(_on_craft_succeeded):
			_crafting.craft_succeeded.connect(_on_craft_succeeded)
		if _crafting.has_signal("craft_failed") and not _crafting.craft_failed.is_connected(_on_craft_failed):
			_crafting.craft_failed.connect(_on_craft_failed)
	if _inventory != null and _inventory.has_signal("inventory_changed"):
		if not _inventory.inventory_changed.is_connected(_on_inventory_changed):
			_inventory.inventory_changed.connect(_on_inventory_changed)
	if _vehicle_state != null and _vehicle_state.has_signal("vehicle_state_changed"):
		if not _vehicle_state.vehicle_state_changed.is_connected(_on_vehicle_state_changed):
			_vehicle_state.vehicle_state_changed.connect(_on_vehicle_state_changed)
	_set_panel_visible(false)
	set_process_unhandled_input(true)


func is_panel_visible() -> bool:
	return _visible_panel


func open_for_workbench(bench: Node = null) -> void:
	_workbench = bench
	_mode = PanelMode.CRAFT
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
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_toggle_mode()
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
	if event.is_action_pressed("ui_accept") or (event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_C or event.keycode == KEY_I)):
		if _mode == PanelMode.INSTALL or (event is InputEventKey and event.keycode == KEY_I):
			_try_install_selected()
		else:
			_try_craft_selected()
		get_viewport().set_input_as_handled()
		return


func _toggle_mode() -> void:
	if _mode == PanelMode.CRAFT:
		_mode = PanelMode.INSTALL
	else:
		_mode = PanelMode.CRAFT
	_selected_index = 0
	_refresh()
	if _status != null:
		_status.text = (
			"Install mode — select an upgrade module."
			if _mode == PanelMode.INSTALL
			else "Craft mode — select a recipe."
		)


func _set_panel_visible(show_panel: bool) -> void:
	_visible_panel = show_panel
	if _root != null:
		_root.visible = show_panel
	if show_panel:
		_refresh_ids()
		_refresh()
		if _status != null:
			_status.text = "Tab: Craft/Install · Enter craft or install."


func _move_selection(delta: int) -> void:
	var ids := _active_ids()
	if ids.is_empty():
		_selected_index = 0
		_refresh()
		return
	_selected_index = wrapi(_selected_index + delta, 0, ids.size())
	_refresh()


func _active_ids() -> PackedStringArray:
	return _upgrade_ids if _mode == PanelMode.INSTALL else _recipe_ids


func _try_craft_selected() -> void:
	if _mode == PanelMode.INSTALL:
		_try_install_selected()
		return
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


func _try_install_selected() -> void:
	if _vehicle_state == null:
		_vehicle_state = get_node_or_null("/root/VehicleStateSystem")
	if _vehicle_state == null:
		if _status != null:
			_status.text = "VehicleStateSystem missing."
		return
	_refresh_upgrade_ids()
	if _upgrade_ids.is_empty():
		if _status != null:
			_status.text = "No installable upgrades in inventory."
		return
	_selected_index = clampi(_selected_index, 0, _upgrade_ids.size() - 1)
	var upgrade_id := str(_upgrade_ids[_selected_index])
	if not bool(_vehicle_state.call("install_upgrade_from_inventory", upgrade_id)):
		var reason := ""
		if _vehicle_state.has_method("get_install_block_reason"):
			reason = str(_vehicle_state.call("get_install_block_reason", upgrade_id))
		if _status != null:
			_status.text = "Install failed: %s" % (reason if not reason.is_empty() else upgrade_id)
	else:
		if _status != null:
			_status.text = "Installed %s" % upgrade_id
	_refresh()


func _on_craft_succeeded(recipe_id: String, output_item_id: String, output_quantity: int) -> void:
	if not _visible_panel:
		return
	if _status != null:
		_status.text = "Crafted +%d %s (%s) — Tab→Install" % [output_quantity, output_item_id, recipe_id]
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


func _on_vehicle_state_changed() -> void:
	if _visible_panel:
		_refresh()


func _refresh_ids() -> void:
	_refresh_recipe_ids()
	_refresh_upgrade_ids()


func _refresh_recipe_ids() -> void:
	if _crafting == null:
		_crafting = get_node_or_null("/root/CraftingSystem")
	_recipe_ids = PackedStringArray()
	if _crafting != null and _crafting.has_method("get_recipe_ids"):
		_recipe_ids = _crafting.call("get_recipe_ids")
	if _mode == PanelMode.CRAFT and _selected_index >= _recipe_ids.size():
		_selected_index = maxi(_recipe_ids.size() - 1, 0)


func _refresh_upgrade_ids() -> void:
	if _vehicle_state == null:
		_vehicle_state = get_node_or_null("/root/VehicleStateSystem")
	_upgrade_ids = PackedStringArray()
	if _vehicle_state == null or not _vehicle_state.has_method("get_upgrade_ids"):
		return
	var all_ids: PackedStringArray = _vehicle_state.call("get_upgrade_ids")
	for upgrade_id in all_ids:
		# Show catalog upgrades that are either installable or already installed.
		var show := false
		if _vehicle_state.has_method("can_install_from_inventory"):
			show = bool(_vehicle_state.call("can_install_from_inventory", upgrade_id))
		if not show and _vehicle_state.has_method("has_upgrade"):
			show = bool(_vehicle_state.call("has_upgrade", upgrade_id))
		# Also show if the item is in inventory (even if blocked) so player sees "already installed".
		if not show and _inventory != null:
			var data: Resource = _vehicle_state.call("get_upgrade_data", upgrade_id)
			if data != null:
				var item_id := str(data.call("get_item_id")) if data.has_method("get_item_id") else upgrade_id
				show = bool(_inventory.call("has_item", item_id, 1)) or bool(
					_vehicle_state.call("has_upgrade", upgrade_id)
				)
		if show:
			_upgrade_ids.append(str(upgrade_id))
	if _mode == PanelMode.INSTALL and _selected_index >= _upgrade_ids.size():
		_selected_index = maxi(_upgrade_ids.size() - 1, 0)


func _refresh() -> void:
	_refresh_ids()
	if _title != null:
		_title.text = (
			"Install upgrades (debug)" if _mode == PanelMode.INSTALL else "Crafting (debug)"
		)
	if _list == null:
		return
	if _mode == PanelMode.INSTALL:
		_refresh_install_list()
	else:
		_refresh_craft_list()
	if _hint != null:
		_hint.text = "Tab mode · ↑↓ select · Enter/C craft · I install · Esc close"


func _refresh_craft_list() -> void:
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
			var can := bool(_crafting.call("can_craft", recipe_id))
			var marker := ">" if i == _selected_index else " "
			var ready := "OK" if can else "need"
			lines.append("%s %s → +%d %s  [%s]" % [marker, title, out_qty, out_id, ready])
			if not ingredients_txt.is_empty():
				lines.append("    %s" % ingredients_txt)
		else:
			lines.append("%s %s" % [">" if i == _selected_index else " ", recipe_id])
	_list.text = "\n".join(lines)


func _refresh_install_list() -> void:
	if _vehicle_state == null:
		_list.text = "(VehicleStateSystem missing)"
		return
	if _upgrade_ids.is_empty():
		_list.text = "(no modules in inventory / installed)"
		return
	var lines: PackedStringArray = []
	var max_kmh := 0.0
	if _vehicle_state.has_method("get_effective_max_speed"):
		max_kmh = float(_vehicle_state.call("get_effective_max_speed"))
	lines.append("Effective max: %.1f km/h" % max_kmh)
	for i in range(_upgrade_ids.size()):
		var upgrade_id := str(_upgrade_ids[i])
		var data: Resource = _vehicle_state.call("get_upgrade_data", upgrade_id)
		var title := upgrade_id
		var bonus := 0.0
		var installed := bool(_vehicle_state.call("has_upgrade", upgrade_id))
		var can := bool(_vehicle_state.call("can_install_from_inventory", upgrade_id))
		if data != null:
			if "display_name" in data and not str(data.get("display_name")).is_empty():
				title = str(data.get("display_name"))
			bonus = float(data.get("max_speed_bonus_kmh"))
		var marker := ">" if i == _selected_index else " "
		var state := "INSTALLED" if installed else ("OK" if can else "need")
		lines.append("%s %s  +%.0f km/h  [%s]" % [marker, title, bonus, state])
	_list.text = "\n".join(lines)
