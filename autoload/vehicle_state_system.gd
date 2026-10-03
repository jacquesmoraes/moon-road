extends Node
## Persistent vehicle attributes / progression — not physics or input.
## PlayerVehicle owns movement; this owns fuel, condition, upgrades, speed caps.
## Single active vehicle for now (starter_car). No garage / swap / visual damage.

signal vehicle_state_changed
signal upgrade_installed(upgrade_id: String)
signal upgrade_removed(upgrade_id: String)
signal fuel_changed(fuel_current: float, fuel_capacity: float)
signal fuel_depleted

const DEFAULT_VEHICLE_ID := "starter_car"
const DEFAULT_DISPLAY_NAME := "Starter Car"
## Matches legacy PlayerVehicle max_speed 24 m/s so feel stays stable.
const DEFAULT_BASE_MAX_SPEED_KMH: float = 86.4
const DEFAULT_FUEL_CAPACITY: float = 100.0
const DEFAULT_CONDITION_MAX: float = 100.0
const DEFAULT_STORAGE_CAPACITY: int = 20
## Base burn rate — game-feel liters per 100 km at reference speed (not a real-world sim).
const DEFAULT_LITERS_PER_100KM: float = 8.0
## Speeds at/below this use the base rate; above adds a simple multiplier.
const DEFAULT_SPEED_CONSUMPTION_REF_KMH: float = 60.0
## Extra burn per full reference-speed step above the reference (e.g. 0.5 → +50% at 120).
const DEFAULT_SPEED_CONSUMPTION_EXTRA: float = 0.5
const DEFAULT_OFFLINE_CRUISE_SPEED_KMH: float = 60.0
const DEFAULT_UPGRADE_CATALOG_PATH := "res://resources/upgrades/default_upgrade_catalog.tres"
const STOPPED_REASON_NONE := ""
const STOPPED_REASON_OUT_OF_FUEL := "OUT_OF_FUEL"
const MS_TO_KMH: float = 3.6
const KM_PER_HOUR_TO_KM_PER_SEC: float = 1.0 / 3600.0

@export_file("*.tres") var upgrade_catalog_path: String = DEFAULT_UPGRADE_CATALOG_PATH

var vehicle_id: String = DEFAULT_VEHICLE_ID
var display_name: String = DEFAULT_DISPLAY_NAME
var fuel_capacity: float = DEFAULT_FUEL_CAPACITY
var fuel_current: float = DEFAULT_FUEL_CAPACITY
var condition_max: float = DEFAULT_CONDITION_MAX
var condition_current: float = DEFAULT_CONDITION_MAX
var storage_capacity: int = DEFAULT_STORAGE_CAPACITY
## Upgrade ids only — never Node refs. Effects resolved from UpgradeCatalog at runtime.
var installed_upgrades: PackedStringArray = PackedStringArray()
var base_max_speed_kmh: float = DEFAULT_BASE_MAX_SPEED_KMH
## Multipliers: cruise assist / economy hooks (efficiency > 1 burns less).
var cruise_speed_modifier: float = 1.0
var efficiency_modifier: float = 1.0

## Fuel economy (configurable).
var liters_per_100km: float = DEFAULT_LITERS_PER_100KM
var speed_consumption_ref_kmh: float = DEFAULT_SPEED_CONSUMPTION_REF_KMH
var speed_consumption_extra: float = DEFAULT_SPEED_CONSUMPTION_EXTRA
## Assumed cruise speed when applying offline travel.
var offline_cruise_speed_kmh: float = DEFAULT_OFFLINE_CRUISE_SPEED_KMH
## Why last offline (or empty-tank) stop happened — empty string if none.
var stopped_reason: String = STOPPED_REASON_NONE
## Snapshot at save: if true, load may apply limited offline travel.
var was_traveling_at_save: bool = false

## upgrade_id → UpgradeData
var _upgrade_by_id: Dictionary = {}


func _ready() -> void:
	_load_upgrade_catalog()
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
	liters_per_100km = DEFAULT_LITERS_PER_100KM
	speed_consumption_ref_kmh = DEFAULT_SPEED_CONSUMPTION_REF_KMH
	speed_consumption_extra = DEFAULT_SPEED_CONSUMPTION_EXTRA
	offline_cruise_speed_kmh = DEFAULT_OFFLINE_CRUISE_SPEED_KMH
	stopped_reason = STOPPED_REASON_NONE
	was_traveling_at_save = false
	vehicle_state_changed.emit()
	fuel_changed.emit(fuel_current, fuel_capacity)


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


func get_fuel_ratio() -> float:
	if fuel_capacity <= 0.0:
		return 0.0
	return clampf(fuel_current / fuel_capacity, 0.0, 1.0)


func has_fuel() -> bool:
	return fuel_current > 0.0001


func is_out_of_fuel() -> bool:
	return not has_fuel()


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


func get_liters_per_100km() -> float:
	return liters_per_100km


func get_stopped_reason() -> String:
	return stopped_reason


func clear_stopped_reason() -> void:
	stopped_reason = STOPPED_REASON_NONE
	vehicle_state_changed.emit()


func install_upgrade(upgrade_id: String) -> bool:
	## Install by id only (no inventory consume). Used by tests / already-owned modules.
	if upgrade_id.is_empty():
		return false
	_ensure_upgrade_index()
	var data: Resource = get_upgrade_data(upgrade_id)
	if has_upgrade(upgrade_id):
		# Non-stackable (default) — refuse duplicates so effects never double.
		if data == null or not bool(data.get("stackable")):
			return false
	installed_upgrades.append(upgrade_id)
	upgrade_installed.emit(upgrade_id)
	vehicle_state_changed.emit()
	return true


func can_install_from_inventory(upgrade_id: String) -> bool:
	return get_install_block_reason(upgrade_id).is_empty()


func get_install_block_reason(upgrade_id: String) -> String:
	if upgrade_id.is_empty():
		return "empty_id"
	_ensure_upgrade_index()
	var data: Resource = get_upgrade_data(upgrade_id)
	if data == null:
		return "unknown_upgrade"
	if has_upgrade(upgrade_id) and not bool(data.get("stackable")):
		return "already_installed"
	var item_id := str(data.call("get_item_id")) if data.has_method("get_item_id") else upgrade_id
	var inv := get_node_or_null("/root/InventorySystem")
	if inv == null:
		return "no_inventory"
	if not bool(inv.call("has_item", item_id, 1)):
		return "missing_item"
	return ""


## Consumes the matching inventory item, then installs. Atomic on success.
func install_upgrade_from_inventory(upgrade_id: String) -> bool:
	var reason := get_install_block_reason(upgrade_id)
	if not reason.is_empty():
		push_warning("VehicleStateSystem: install blocked '%s' (%s)" % [upgrade_id, reason])
		return false
	var data: Resource = get_upgrade_data(upgrade_id)
	var item_id := str(data.call("get_item_id")) if data.has_method("get_item_id") else upgrade_id
	var inv := get_node_or_null("/root/InventorySystem")
	var removed: int = int(inv.call("remove_item", item_id, 1))
	if removed < 1:
		push_warning("VehicleStateSystem: could not consume '%s' for install" % item_id)
		return false
	if not install_upgrade(upgrade_id):
		# Roll back item if install somehow failed after consume.
		inv.call("add_item", item_id, 1)
		return false
	print("VehicleStateSystem: installed '%s' (consumed %s)" % [upgrade_id, item_id])
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


func get_upgrade_data(upgrade_id: String) -> Resource:
	_ensure_upgrade_index()
	return _upgrade_by_id.get(upgrade_id, null)


func get_upgrade_ids() -> PackedStringArray:
	_ensure_upgrade_index()
	var ids: PackedStringArray = []
	for key in _upgrade_by_id.keys():
		ids.append(str(key))
	ids.sort()
	return ids


func register_upgrade(data: Resource) -> void:
	if data == null:
		return
	var key := str(data.get("id"))
	if key.is_empty():
		return
	_upgrade_by_id[key] = data


func get_upgrade_max_speed_bonus_kmh() -> float:
	## Sum of max_speed_bonus_kmh from installed UpgradeData (runtime — not baked).
	_ensure_upgrade_index()
	var bonus := 0.0
	for upgrade_id in installed_upgrades:
		var data: Resource = get_upgrade_data(str(upgrade_id))
		if data == null:
			continue
		bonus += float(data.get("max_speed_bonus_kmh"))
	return bonus


func get_upgrade_efficiency_multiplier() -> float:
	## Product of efficiency_multiplier from installed upgrades.
	_ensure_upgrade_index()
	var product := 1.0
	for upgrade_id in installed_upgrades:
		var data: Resource = get_upgrade_data(str(upgrade_id))
		if data == null:
			continue
		var mult := float(data.get("efficiency_multiplier"))
		if mult > 0.0:
			product *= mult
	return product


func get_effective_max_speed() -> float:
	## base * cruise_mod + Σ upgrade max_speed_bonus_kmh (never double-applied on load).
	var mod := maxf(cruise_speed_modifier, 0.0)
	var bonus := get_upgrade_max_speed_bonus_kmh()
	return maxf(base_max_speed_kmh * mod + bonus, 0.0)


func get_effective_max_speed_ms() -> float:
	return get_effective_max_speed() / MS_TO_KMH


func get_effective_efficiency_modifier() -> float:
	return maxf(efficiency_modifier, 0.01) * maxf(get_upgrade_efficiency_multiplier(), 0.01)


func add_fuel(liters: float) -> float:
	## Adds fuel up to capacity. Returns liters actually added.
	if not is_finite(liters) or liters <= 0.0 or fuel_capacity <= 0.0:
		return 0.0
	var before := fuel_current
	fuel_current = minf(fuel_current + liters, fuel_capacity)
	var added := fuel_current - before
	if added > 0.0:
		if stopped_reason == STOPPED_REASON_OUT_OF_FUEL:
			stopped_reason = STOPPED_REASON_NONE
		fuel_changed.emit(fuel_current, fuel_capacity)
		vehicle_state_changed.emit()
	return added


func consume_fuel(liters: float) -> float:
	## Removes fuel (never below 0). Returns liters actually consumed.
	if not is_finite(liters) or liters <= 0.0:
		return 0.0
	var before := fuel_current
	fuel_current = maxf(fuel_current - liters, 0.0)
	var used := before - fuel_current
	if used > 0.0:
		fuel_changed.emit(fuel_current, fuel_capacity)
		vehicle_state_changed.emit()
		if before > 0.0001 and fuel_current <= 0.0001:
			stopped_reason = STOPPED_REASON_OUT_OF_FUEL
			fuel_depleted.emit()
	return used


func get_speed_consumption_factor(speed_kmh: float) -> float:
	## Simple curve: 1.0 at/below reference; rises linearly above it.
	var speed := maxf(speed_kmh, 0.0)
	var ref := maxf(speed_consumption_ref_kmh, 1.0)
	if speed <= ref:
		return 1.0
	var over_ratio := (speed - ref) / ref
	return 1.0 + maxf(speed_consumption_extra, 0.0) * over_ratio


func estimate_consumption_liters(distance_km: float, speed_kmh: float) -> float:
	## liters = (km/100) * L/100km * speed_factor / effective_efficiency
	if not is_finite(distance_km) or distance_km <= 0.0:
		return 0.0
	var rate := maxf(liters_per_100km, 0.0)
	var factor := get_speed_consumption_factor(speed_kmh)
	var efficiency := get_effective_efficiency_modifier()
	return (distance_km / 100.0) * rate * factor / efficiency


func get_max_travel_km_for_fuel(speed_kmh: float) -> float:
	## How far current fuel can take us at the given speed (before hitting empty).
	if fuel_current <= 0.0:
		return 0.0
	var per_km := estimate_consumption_liters(1.0, speed_kmh)
	if per_km <= 0.0000001:
		return INF
	return fuel_current / per_km


func consume_for_distance_km(distance_km: float, speed_kmh: float) -> float:
	## Consume for a physical/logical travel segment. Returns liters used.
	return consume_fuel(estimate_consumption_liters(distance_km, speed_kmh))


func apply_distance_with_fuel(desired_km: float, speed_kmh: float) -> Dictionary:
	## Caps travel by remaining fuel. Never drives fuel below zero mid-step.
	## Returns { distance_applied_km, fuel_consumed, stopped_reason }.
	var result := {
		"distance_applied_km": 0.0,
		"fuel_consumed": 0.0,
		"stopped_reason": STOPPED_REASON_NONE,
	}
	if not is_finite(desired_km) or desired_km <= 0.0:
		return result
	if not has_fuel():
		result["stopped_reason"] = STOPPED_REASON_OUT_OF_FUEL
		stopped_reason = STOPPED_REASON_OUT_OF_FUEL
		return result

	var max_km := get_max_travel_km_for_fuel(speed_kmh)
	var applied := desired_km
	var reason := STOPPED_REASON_NONE
	if is_finite(max_km) and desired_km > max_km + 0.0000001:
		applied = maxf(max_km, 0.0)
		reason = STOPPED_REASON_OUT_OF_FUEL

	var used := consume_for_distance_km(applied, speed_kmh)
	if reason == STOPPED_REASON_OUT_OF_FUEL:
		# Land exactly on empty so offline never "stops after zero".
		if fuel_current > 0.0:
			used += consume_fuel(fuel_current)
		stopped_reason = STOPPED_REASON_OUT_OF_FUEL

	result["distance_applied_km"] = applied
	result["fuel_consumed"] = used
	result["stopped_reason"] = reason
	return result


func apply_offline_travel(elapsed_seconds: float, speed_kmh: float = -1.0) -> Dictionary:
	## Minimal offline progress hook: advance JourneySystem only as far as fuel allows.
	## Does not invent a full offline sim (caps, events, etc. come later).
	var result := {
		"distance_applied_km": 0.0,
		"fuel_consumed": 0.0,
		"stopped_reason": STOPPED_REASON_NONE,
		"elapsed_seconds": maxf(elapsed_seconds, 0.0),
	}
	if not is_finite(elapsed_seconds) or elapsed_seconds <= 0.0:
		return result

	var speed := speed_kmh
	if speed < 0.0:
		speed = offline_cruise_speed_kmh
	speed = maxf(speed, 0.0)
	var desired_km := speed * elapsed_seconds * KM_PER_HOUR_TO_KM_PER_SEC
	var applied_info := apply_distance_with_fuel(desired_km, speed)
	result["distance_applied_km"] = float(applied_info.get("distance_applied_km", 0.0))
	result["fuel_consumed"] = float(applied_info.get("fuel_consumed", 0.0))
	result["stopped_reason"] = str(applied_info.get("stopped_reason", STOPPED_REASON_NONE))

	var journey := get_node_or_null("/root/JourneySystem")
	if journey != null and journey.has_method("add_distance"):
		var travel_km := float(result["distance_applied_km"])
		if travel_km > 0.0:
			journey.call("add_distance", travel_km)
	return result


func set_fuel_current(value: float) -> void:
	fuel_current = clampf(value, 0.0, maxf(fuel_capacity, 0.0))
	if fuel_current > 0.0001 and stopped_reason == STOPPED_REASON_OUT_OF_FUEL:
		stopped_reason = STOPPED_REASON_NONE
	fuel_changed.emit(fuel_current, fuel_capacity)
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


func set_efficiency_modifier(value: float) -> void:
	efficiency_modifier = maxf(value, 0.01)
	vehicle_state_changed.emit()


func set_liters_per_100km(value: float) -> void:
	liters_per_100km = maxf(value, 0.0)
	vehicle_state_changed.emit()


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	## Attributes / progression only — never pose, motion, or control runtime.
	var upgrades: Array = []
	for id in installed_upgrades:
		upgrades.append(str(id))
	var traveling := false
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt != null and gt.has_method("is_traveling"):
		traveling = bool(gt.call("is_traveling"))
	was_traveling_at_save = traveling
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
		"liters_per_100km": liters_per_100km,
		"speed_consumption_ref_kmh": speed_consumption_ref_kmh,
		"speed_consumption_extra": speed_consumption_extra,
		"offline_cruise_speed_kmh": offline_cruise_speed_kmh,
		"stopped_reason": stopped_reason,
		"was_traveling_at_save": was_traveling_at_save,
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
	efficiency_modifier = maxf(float(data.get("efficiency_modifier", 1.0)), 0.01)
	liters_per_100km = maxf(float(data.get("liters_per_100km", DEFAULT_LITERS_PER_100KM)), 0.0)
	speed_consumption_ref_kmh = maxf(
		float(data.get("speed_consumption_ref_kmh", DEFAULT_SPEED_CONSUMPTION_REF_KMH)), 1.0
	)
	speed_consumption_extra = maxf(
		float(data.get("speed_consumption_extra", DEFAULT_SPEED_CONSUMPTION_EXTRA)), 0.0
	)
	offline_cruise_speed_kmh = maxf(
		float(data.get("offline_cruise_speed_kmh", DEFAULT_OFFLINE_CRUISE_SPEED_KMH)), 0.0
	)
	stopped_reason = str(data.get("stopped_reason", STOPPED_REASON_NONE))
	was_traveling_at_save = bool(data.get("was_traveling_at_save", false))
	installed_upgrades = PackedStringArray()
	var raw_upgrades: Variant = data.get("installed_upgrades", [])
	if typeof(raw_upgrades) == TYPE_ARRAY or typeof(raw_upgrades) == TYPE_PACKED_STRING_ARRAY:
		for entry in raw_upgrades:
			var uid := str(entry)
			if uid.is_empty() or has_upgrade(uid):
				continue
			installed_upgrades.append(uid)
	fuel_changed.emit(fuel_current, fuel_capacity)
	vehicle_state_changed.emit()


func reload_upgrade_catalog() -> void:
	_upgrade_by_id.clear()
	_load_upgrade_catalog()


func _ensure_upgrade_index() -> void:
	if not _upgrade_by_id.is_empty():
		return
	_load_upgrade_catalog()


func _load_upgrade_catalog() -> void:
	var catalog: Resource = null
	if not upgrade_catalog_path.is_empty() and ResourceLoader.exists(upgrade_catalog_path):
		catalog = load(upgrade_catalog_path)
	if catalog != null and catalog.has_method("build_index"):
		var built: Dictionary = catalog.call("build_index")
		for key in built.keys():
			_upgrade_by_id[str(key)] = built[key]
	elif catalog != null and "entries" in catalog:
		for entry in catalog.entries:
			if entry == null:
				continue
			var key := str(entry.get("id"))
			if not key.is_empty():
				_upgrade_by_id[key] = entry
