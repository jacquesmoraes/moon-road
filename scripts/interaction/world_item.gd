extends Area3D
class_name WorldItem
## Collectible world pickup. Duck-types Interactable; stores item_id + quantity.
## On collect: InventorySystem.add_item → deactivate. Collected state is queryable for future saves.
## No loot tables, respawn, or animation.

signal collected(item_id: String, quantity: int, display_name: String)
signal interact_failed(reason: String)

## Stable id for future persistence (defaults to node name if empty).
@export var pickup_id: String = ""
@export var item_id: String = ""
@export var quantity: int = 1
@export var enabled: bool = true
@export var interaction_priority: int = 0
@export var interaction_name_override: String = ""

var _collected: bool = false
var _model: Node3D
var _label: Label3D


func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = true
	if pickup_id.is_empty():
		pickup_id = str(name)
	_model = get_node_or_null("Model") as Node3D
	_label = get_node_or_null("NameLabel") as Label3D
	_refresh_label()
	if _collected:
		_apply_collected_visuals()


func get_pickup_id() -> String:
	return pickup_id if not pickup_id.is_empty() else str(name)


func get_item_id() -> String:
	return item_id


func get_quantity() -> int:
	return maxi(quantity, 1)


func is_collected() -> bool:
	return _collected


## Snapshot for a future save system — clear collected flag semantics.
func get_collected_state() -> Dictionary:
	return {
		"pickup_id": get_pickup_id(),
		"item_id": item_id,
		"collected": _collected,
	}


func apply_collected_state(collected_flag: bool) -> void:
	## Future load path: restore without granting items again.
	_collected = collected_flag
	if _collected:
		_apply_collected_visuals()
	else:
		_restore_active_visuals()


func get_interaction_name() -> String:
	if not interaction_name_override.is_empty():
		return interaction_name_override
	var data := _item_data()
	if data != null and "display_name" in data:
		var n := str(data.get("display_name"))
		if not n.is_empty():
			return n
	return item_id if not item_id.is_empty() else "Item"


func get_interaction_prompt() -> String:
	if _collected:
		return ""
	return "E — Coletar: %s" % get_interaction_name()


func can_interact(_actor: Node = null) -> bool:
	if _collected or not enabled:
		return false
	if not is_inside_tree() or not is_visible_in_tree():
		return false
	if item_id.is_empty() or quantity <= 0:
		return false
	var inv := _inventory()
	if inv == null or not inv.has_method("has_item_data"):
		return false
	return bool(inv.call("has_item_data", item_id))


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false
	var inv := _inventory()
	if inv == null or not inv.has_method("add_item"):
		interact_failed.emit("no_inventory")
		return false

	var want := get_quantity()
	var added: int = int(inv.call("add_item", item_id, want))
	if added <= 0:
		interact_failed.emit("inventory_full")
		print("WorldItem: could not add %s (inventory full or unknown)" % item_id)
		return false

	_collected = true
	_apply_collected_visuals()

	var display := get_interaction_name()
	var feedback := "+%d %s" % [added, display]
	print("WorldItem: collected %s (pickup_id=%s)" % [feedback, get_pickup_id()])
	set_meta("last_interact_message", feedback)
	set_meta("last_added_quantity", added)
	set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
	collected.emit(item_id, added, display)
	_notify_feedback(feedback)
	return true


func _notify_feedback(message: String) -> void:
	if get_tree() == null:
		return
	for node in get_tree().get_nodes_in_group("pickup_feedback"):
		if node != null and node.has_method("show_pickup_message"):
			node.call("show_pickup_message", message)
			return


func _inventory() -> Node:
	return get_node_or_null("/root/InventorySystem")


func _item_data() -> Resource:
	var inv := _inventory()
	if inv != null and inv.has_method("get_item_data"):
		return inv.call("get_item_data", item_id)
	return null


func _refresh_label() -> void:
	if _label == null:
		return
	_label.text = get_interaction_name()


func _apply_collected_visuals() -> void:
	visible = false
	monitorable = false
	collision_layer = 0
	if _model != null:
		_model.visible = false


func _restore_active_visuals() -> void:
	visible = true
	monitorable = true
	collision_layer = 8
	if _model != null:
		_model.visible = true
