extends Resource
class_name WorldRegion
## One logical Earth→Moon journey region. Spans live in data (.tres), not code.
## Extra fields are stubs for future visual / scenery / climate / audio / POI work.

@export var region_id: String = ""
@export var display_name: String = ""
## Inclusive start of this region in journey km.
@export var start_km: float = 0.0
## Exclusive end for mid regions; final region should include total_distance_km.
@export var end_km: float = 0.0

@export_group("Future hooks (stubs)")
## Multiplier for roadside / prop density when scenery listens to regions.
@export var scenery_density_scale: float = 1.0
## Short climate / atmosphere tag (e.g. "warm_clear", "thin_air").
@export var climate_tag: String = ""
## Soft visual hint for sky / grade / fog later — not applied yet.
@export var visual_tint: Color = Color(1.0, 1.0, 1.0, 1.0)
## Ambience / music bed key for a future audio system.
@export var audio_ambience_tag: String = ""
## Allowed point-of-interest type ids for this stretch.
@export var poi_tags: PackedStringArray = []


func contains_km(km: float) -> bool:
	if not is_finite(km):
		return false
	if end_km > start_km:
		# Half-open [start, end) so boundaries belong to the next region,
		# except the very last km of the catalog (handled by WorldRegionSystem).
		return km >= start_km and km < end_km
	return is_equal_approx(km, start_km)


func get_span_km() -> float:
	return maxf(end_km - start_km, 0.0)


func get_progress_at(km: float) -> float:
	var span := get_span_km()
	if span <= 0.0:
		return 0.0
	return clampf((km - start_km) / span, 0.0, 1.0)
