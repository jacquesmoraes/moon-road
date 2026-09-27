extends Node
## Logical journey distance (Earth → Moon). Independent of scene, vehicle, road, camera, UI.

signal distance_changed(current_km: float, total_km: float)

@export var total_distance_km: float = 384400.0

var current_distance_km: float = 0.0


func add_distance(km: float) -> void:
	if not is_finite(km) or km <= 0.0:
		return
	var previous := current_distance_km
	current_distance_km = minf(current_distance_km + km, maxf(total_distance_km, 0.0))
	if not is_equal_approx(previous, current_distance_km):
		distance_changed.emit(current_distance_km, total_distance_km)


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
