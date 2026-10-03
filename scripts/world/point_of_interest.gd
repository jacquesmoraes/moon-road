extends Resource
class_name PointOfInterest
## Placeholder POI reached via a roadside exit / short detour. No final art yet.

@export var poi_id: String = ""
@export var display_name: String = ""
@export var poi_type: String = "viewpoint"
@export var description: String = ""
## Optional override scene. Empty → POISystem default ViewpointPOI.
@export var viewpoint_scene: PackedScene
