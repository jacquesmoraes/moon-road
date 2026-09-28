extends Resource
class_name WorldRegionCatalog
## Ordered list of WorldRegion resources covering the Earth→Moon journey.
## Edit regions by changing the .tres entries; WorldRegionSystem just consumes this.

@export var regions: Array[WorldRegion] = []


func get_sorted_regions() -> Array[WorldRegion]:
	var out: Array[WorldRegion] = []
	for region in regions:
		if region != null:
			out.append(region)
	out.sort_custom(func(a: WorldRegion, b: WorldRegion) -> bool:
		return a.start_km < b.start_km
	)
	return out
