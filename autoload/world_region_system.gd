extends Node
## Logical region along the Earth→Moon journey.
## Reads JourneySystem distance only — does not modify journey math, road, scenery, or UI.

signal region_changed(new_region: WorldRegion, previous_region: WorldRegion)

const DEFAULT_CATALOG_PATH := "res://resources/world/world_region_catalog.tres"

@export_file("*.tres") var catalog_path: String = DEFAULT_CATALOG_PATH

var _catalog: WorldRegionCatalog
var _regions: Array[WorldRegion] = []
var _current: WorldRegion
var _journey: Node


func _ready() -> void:
	_load_catalog()
	_journey = get_node_or_null("/root/JourneySystem")
	if _journey != null and _journey.has_signal("distance_changed"):
		_journey.distance_changed.connect(_on_journey_distance_changed)
	_reevaluate(_current_journey_km(), true)


func reload_catalog() -> void:
	_load_catalog()
	_reevaluate(_current_journey_km(), true)


func get_current_region() -> WorldRegion:
	return _current


func get_current_region_id() -> String:
	return _current.region_id if _current != null else ""


func get_current_region_name() -> String:
	if _current == null:
		return ""
	if not _current.display_name.is_empty():
		return _current.display_name
	return _current.region_id


func get_region_progress() -> float:
	if _current == null:
		return 0.0
	return _current.get_progress_at(_current_journey_km())


func get_region_at_distance(km: float) -> WorldRegion:
	return _find_region(km)


func get_region_count() -> int:
	return _regions.size()


func get_regions() -> Array[WorldRegion]:
	return _regions.duplicate()


func _on_journey_distance_changed(current_km: float, _total_km: float) -> void:
	_reevaluate(current_km, true)


func _reevaluate(km: float, emit_on_change: bool) -> void:
	var next := _find_region(km)
	var previous := _current
	if _same_region(previous, next):
		_current = next
		return
	_current = next
	if emit_on_change:
		region_changed.emit(next, previous)


func _find_region(km: float) -> WorldRegion:
	if _regions.is_empty() or not is_finite(km):
		return null

	# Prefer half-open membership; last region also accepts its end_km (Moon arrival).
	var last: WorldRegion = _regions[_regions.size() - 1]
	for region in _regions:
		if region.contains_km(km):
			return region
	if last != null and km >= last.start_km and km <= last.end_km:
		return last

	# Fallback: clamp to nearest catalog edge.
	if km < _regions[0].start_km:
		return _regions[0]
	return last


func _same_region(a: WorldRegion, b: WorldRegion) -> bool:
	if a == b:
		return true
	if a == null or b == null:
		return false
	if not a.region_id.is_empty() or not b.region_id.is_empty():
		return a.region_id == b.region_id
	return a.display_name == b.display_name and is_equal_approx(a.start_km, b.start_km)


func _current_journey_km() -> float:
	if _journey != null and _journey.has_method("get_current_distance_km"):
		return float(_journey.call("get_current_distance_km"))
	return 0.0


func _load_catalog() -> void:
	_regions.clear()
	_catalog = null
	if catalog_path.is_empty():
		return
	var loaded := load(catalog_path)
	_catalog = loaded as WorldRegionCatalog
	if _catalog == null:
		push_warning("WorldRegionSystem: failed to load catalog at %s" % catalog_path)
		return
	_regions = _catalog.get_sorted_regions()
