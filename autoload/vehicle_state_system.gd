extends Node
## Persistent vehicle attributes / progression — not physics or input.
## PlayerVehicle owns movement; this owns fuel, condition, upgrades, speed caps.
## Single active vehicle for now (starter_car). No garage / swap / visual damage.

signal vehicle_state_changed
signal upgrade_installed(upgrade_id: String)
signal upgrade_removed(upgrade_id: String)

const DEFAULT_VEHICLE_ID := "starter_car"
const DEFAULT_DISPLAY_NAME := "Starter Car"
## Matches legacy PlayerVehicle max_speed 24 m/s so feel stays stable.
const DEFAULT_BASE_MAX_SPEED_KMH: float = 86.4
const DEFAULT_FUEL_CAPACITY: float = 100.0
const DEFAULT_CONDITION_MAX: float = 100.0
const DEFAULT_STORAGE_CAPACITY: int = 20
const MS_TO_KMH: float = 3.6

var vehicle_id: String = DEFAULT_VEHICLE_ID
var display_name: String = DEFAULT_DISPLAY_NAME
var fuel_capacity: float = DEFAULT_FUEL_CAPACITY
var fuel_current: float = DEFAULT_FUEL_CAPACITY
var condition_max: float = DEFAULT_CONDITION_MAX
var condition_current: float = DEFAULT_CONDITION_MAX
var storage_capacity: int = DEFAULT_STORAGE_CAPACITY
## Upgrade ids only — never Node refs.
var installed_upgrades: PackedStringArray = PackedStringArray()
var base_max_speed_kmh: float = DEFAULT_BASE_MAX_SPEED_KMH
## Multipliers reserved for future systems (fuel economy, cruise assist, etc.).
var cruise_speed_modifier: float = 1.0
var efficiency_modifier: float = 1.0


func _ready() -> void:
	reset_to_defaults()


func reset_to_defaults() -> void:
	vehicle_id = DEFAULT_VEHICLE_ID
	display_name = DEFAULT_DISPLAY_NAME
	fuel_capacity = DEFAULT_FUEL_CAPACITY
	fuel_current = DEFAULT_FUEL_CAPACITY
	condition_max = DEFAULT_CONDITION_MAX
	condition_current = DEFAULT_CONDITION_MAX
	storage_capacity = DEFAULT_STORAGE_CAPACITY
	installed_upgrades = PackedStringArray()
	base_max_speed_kmh = DEFAULT_BASE_MAX_SPEED_KMH
	cruise_speed_modifier = 1.0
	efficiency_modifier = 1.0
	vehicle_state_changed.emit()


func reset_for_tests() -> void:
	reset_to_defaults()


func get_vehicle_id() -> String:
	return vehicle_id


func get_display_name() -> String:
	return display_name


func get_fuel_current() -> float:
	return fuel_current


func get_fuel_capacity() -> float:
	return fuel_capacity


func get_condition_current() -> float:
	return condition_current


func get_condition_max() -> float:
	return condition_max


func get_storage_capacity() -> int:
	return storage_capacity


func get_installed_upgrades() -> PackedStringArray:
	return installed_upgrades.duplicate()


func get_base_max_speed_kmh() -> float:
	return base_max_speed_kmh


func get_cruise_speed_modifier() -> float:
	return cruise_speed_modifier


func get_efficiency_modifier() -> float:
	return efficiency_modifier


func install_upgrade(upgrade_id: String) -> bool:
	if upgrade_id.is_empty():
		return false
	if has_upgrade(upgrade_id):
		return false
	installed_upgrades.append(upgrade_id)
	upgrade_installed.emit(upgrade_id)
	vehicle_state_changed.emit()
	return true


func has_upgrade(upgrade_id: String) -> bool:
	if upgrade_id.is_empty():
		return false
	for id in installed_upgrades:
		if str(id) == upgrade_id:
			return true
	return false


func remove_upgrade(upgrade_id: String) -> bool:
	if upgrade_id.is_empty():
		return false
	var next := PackedStringArray()
	var removed := false
	for id in installed_upgrades:
		if str(id) == upgrade_id:
			removed = true
			continue
		next.append(str(id))
	if not removed:
		return false
	installed_upgrades = next
	upgrade_removed.emit(upgrade_id)
	vehicle_state_changed.emit()
	return true


func get_effective_max_speed() -> float:
	## Authoritative max speed in km/h. Upgrade *effects* not fully wired yet —
	## modifiers apply; upgrade ids are persisted for future effect tables.
	var mod := maxf(cruise_speed_modifier, 0.0)
	return maxf(base_max_speed_kmh * mod, 0.0)


func get_effective_max_speed_ms() -> float:
	return get_effective_max_speed() / MS_TO_KMH


func set_fuel_current(value: float) -> void:
	fuel_current = clampf(value, 0.0, maxf(fuel_capacity, 0.0))
	vehicle_state_changed.emit()


func set_condition_current(value: float) -> void:
	condition_current = clampf(value, 0.0, maxf(condition_max, 0.0))
	vehicle_state_changed.emit()


func set_base_max_speed_kmh(value: float) -> void:
	base_max_speed_kmh = maxf(value, 0.0)
	vehicle_state_changed.emit()


func set_cruise_speed_modifier(value: float) -> void:
	cruise_speed_modifier = maxf(value, 0.0)
	vehicle_state_changed.emit()


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	## Attributes / progression only — never pose, motion, or control runtime.
	var upgrades: Array = []
	for id in installed_upgrades:
		upgrades.append(str(id))
	return {
		"vehicle_id": vehicle_id,
		"display_name": display_name,
		"fuel_capacity": fuel_capacity,
		"fuel_current": fuel_current,
		"condition_max": condition_max,
		"condition_current": condition_current,
		"storage_capacity": storage_capacity,
		"installed_upgrades": upgrades,
		"base_max_speed_kmh": base_max_speed_kmh,
		"cruise_speed_modifier": cruise_speed_modifier,
		"efficiency_modifier": efficiency_modifier,
	}


func load_save_data(data: Dictionary) -> void:
	if data == null or data.is_empty():
		reset_to_defaults()
		return
	vehicle_id = str(data.get("vehicle_id", DEFAULT_VEHICLE_ID))
	if vehicle_id.is_empty():
		vehicle_id = DEFAULT_VEHICLE_ID
	display_name = str(data.get("display_name", DEFAULT_DISPLAY_NAME))
	if display_name.is_empty():
		display_name = DEFAULT_DISPLAY_NAME
	fuel_capacity = maxf(float(data.get("fuel_capacity", DEFAULT_FUEL_CAPACITY)), 0.0)
	fuel_current = clampf(float(data.get("fuel_current", fuel_capacity)), 0.0, fuel_capacity)
	condition_max = maxf(float(data.get("condition_max", DEFAULT_CONDITION_MAX)), 0.0)
	condition_current = clampf(
		float(data.get("condition_current", condition_max)), 0.0, condition_max
	)
	storage_capacity = maxi(int(data.get("storage_capacity", DEFAULT_STORAGE_CAPACITY)), 0)
	base_max_speed_kmh = maxf(
		float(data.get("base_max_speed_kmh", DEFAULT_BASE_MAX_SPEED_KMH)), 0.0
	)
	cruise_speed_modifier = maxf(float(data.get("cruise_speed_modifier", 1.0)), 0.0)
	efficiency_modifier = maxf(float(data.get("efficiency_modifier", 1.0)), 0.0)
	installed_upgrades = PackedStringArray()
	var raw_upgrades: Variant = data.get("installed_upgrades", [])
	if typeof(raw_upgrades) == TYPE_ARRAY or typeof(raw_upgrades) == TYPE_PACKED_STRING_ARRAY:
		for entry in raw_upgrades:
			var uid := str(entry)
			if uid.is_empty() or has_upgrade(uid):
				continue
			installed_upgrades.append(uid)
	vehicle_state_changed.emit()
