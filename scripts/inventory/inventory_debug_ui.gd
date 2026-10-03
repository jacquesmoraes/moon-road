extends CanvasLayer
class_name InventoryDebugUI
## Dev-only inventory viewer. Reads InventorySystem — never owns item logic.

@onready var _root: Control = $Root
@onready var _list: Label = $Root/Panel/Margin/VBox/ListLabel
@onready var _hint: Label = $Root/Panel/Margin/VBox/HintLabel

var _inventory: Node
var _visible_panel: bool = false


func _ready() -> void:
	layer = 92
	_inventory = get_node_or_null("/root/InventorySystem")
	if _inventory != null and _inventory.has_signal("inventory_changed"):
		if not _inventory.inventory_changed.is_connected(_on_inventory_changed):
			_inventory.inventory_changed.connect(_on_inventory_changed)
	if _inventory != null and _inventory.has_signal("inventory_cleared"):
		if not _inventory.inventory_cleared.is_connected(_on_inventory_cleared):
			_inventory.inventory_cleared.connect(_on_inventory_cleared)
	_set_panel_visible(false)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory_debug_toggle"):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	_set_panel_visible(not _visible_panel)


func is_panel_visible() -> bool:
	return _visible_panel


func _set_panel_visible(show_panel: bool) -> void:
	_visible_panel = show_panel
	if _root != null:
		_root.visible = show_panel
	if show_panel:
		_refresh()


func _on_inventory_changed(_item_id: String, _quantity: int) -> void:
	if _visible_panel:
		_refresh()


func _on_inventory_cleared() -> void:
	if _visible_panel:
		_refresh()


func _refresh() -> void:
	if _inventory == null:
		_inventory = get_node_or_null("/root/InventorySystem")
	if _list == null:
		return
	if _inventory == null:
		_list.text = "(InventorySystem missing)"
		return

	var ids: PackedStringArray = []
	if _inventory.has_method("get_item_ids"):
		ids = _inventory.call("get_item_ids")
	if ids.is_empty():
		_list.text = "(empty)"
		return

	var lines: PackedStringArray = []
	for item_id in ids:
		var qty := int(_inventory.call("get_quantity", item_id))
		var name := str(item_id)
		var cat := "?"
		var data: Resource = null
		if _inventory.has_method("get_item_data"):
			data = _inventory.call("get_item_data", item_id)
		if data != null:
			if "display_name" in data and not str(data.get("display_name")).is_empty():
				name = str(data.get("display_name"))
			if data.has_method("get_category_name"):
				cat = str(data.call("get_category_name"))
		lines.append("%s  x%d  [%s]" % [name, qty, cat])
	_list.text = "\n".join(lines)
	if _hint != null:
		_hint.text = "I — close debug inventory"
