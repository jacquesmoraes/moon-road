extends Resource
class_name UpgradeData
## Data-driven vehicle upgrade definition. Effects are numeric modifiers —
## never branched on display name. VehicleState sums these at runtime.

enum Category {
	ENGINE,
	CRUISE,
	FUEL,
	STORAGE,
	SUSPENSION,
	COSMETIC,
	OTHER,
}

@export var id: String = ""
@export var display_name: String = "Upgrade"
@export var description: String = ""
@export var category: Category = Category.OTHER
## Inventory item consumed on install. Defaults to same as id when empty.
@export var item_id: String = ""
## When false, install_upgrade refuses a second copy.
@export var stackable: bool = false

@export_group("Effects")
## Added to effective max / cruise / travel speed (km/h).
@export var max_speed_bonus_kmh: float = 0.0
## Multiplies VehicleState.efficiency_modifier (>1 = better economy).
@export var efficiency_multiplier: float = 1.0


func get_item_id() -> String:
	if item_id.is_empty():
		return id
	return item_id


func get_category_name() -> String:
	match category:
		Category.ENGINE:
			return "ENGINE"
		Category.CRUISE:
			return "CRUISE"
		Category.FUEL:
			return "FUEL"
		Category.STORAGE:
			return "STORAGE"
		Category.SUSPENSION:
			return "SUSPENSION"
		Category.COSMETIC:
			return "COSMETIC"
		_:
			return "OTHER"
