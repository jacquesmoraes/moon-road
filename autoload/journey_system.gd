extends Node
## Logical journey distance (Earth → Moon). Independent of scene, vehicle, road, camera, UI.
##
## Units:
## - Godot world space: 1 unit = 1 physical meter (project convention).
## - Physical km: meters / 1000.
## - Journey km: narrative distance shown to the player (Earth → Moon total).
##
## Conversion (only place this scale is applied):
##   journey_km += physical_km * physical_to_journey_scale
## where physical_to_journey_scale = 1.0 means 1 physical km → 1 journey km.

signal distance_changed(current_km: float, total_km: float)

@export var total_distance_km: float = 384400.0
## Logical km gained per physical km traveled in the scene. Does not affect vehicle physics.
@export var physical_to_journey_scale: float = 1.0

var current_distance_km: float = 0.0

const METERS_PER_KM: float = 1000.0


func add_distance(km: float) -> void:
	## Adds already-converted journey kilometers (logical). Prefer add_physical_distance_meters from world travel.
	if not is_finite(km) or km <= 0.0:
		return
	var previous := current_distance_km
	current_distance_km = minf(current_distance_km + km, maxf(total_distance_km, 0.0))
	if not is_equal_approx(previous, current_distance_km):
		distance_changed.emit(current_distance_km, total_distance_km)


func add_physical_distance_meters(meters: float) -> void:
	## Scene travel in physical meters → journey km via physical_to_journey_scale.
	if not is_finite(meters) or meters <= 0.0:
		return
	var physical_km := meters / METERS_PER_KM
	add_distance(physical_km * maxf(physical_to_journey_scale, 0.0))


func physical_km_to_journey_km(physical_km: float) -> float:
	if not is_finite(physical_km):
		return 0.0
	return physical_km * maxf(physical_to_journey_scale, 0.0)


func get_physical_to_journey_scale() -> float:
	return physical_to_journey_scale


func set_physical_to_journey_scale(scale: float) -> void:
	if not is_finite(scale):
		return
	physical_to_journey_scale = maxf(scale, 0.0)


func get_current_distance_km() -> float:
	return current_distance_km


func get_total_distance_km() -> float:
	return total_distance_km


func get_remaining_distance_km() -> float:
	return maxf(total_distance_km - current_distance_km, 0.0)


func get_progress_ratio() -> float:
	if total_distance_km <= 0.0:
		return 0.0
	return clampf(current_distance_km / total_distance_km, 0.0, 1.0)


func set_current_distance_km(km: float) -> void:
	if not is_finite(km):
		return
	current_distance_km = clampf(km, 0.0, maxf(total_distance_km, 0.0))
	distance_changed.emit(current_distance_km, total_distance_km)


func reset_journey() -> void:
	current_distance_km = 0.0
	distance_changed.emit(current_distance_km, total_distance_km)
