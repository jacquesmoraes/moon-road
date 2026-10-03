extends Resource
class_name RoadsideExitDefinition
## Data for one lateral exit off the main road into a short fixed detour.

enum ExitSide {
	EXIT_LEFT,
	EXIT_RIGHT,
}

@export var exit_id: String = ""
@export var side: ExitSide = ExitSide.EXIT_RIGHT
## Main-road sequence index (RoadManager spawn order) that hosts this exit.
@export var appear_at_sequence: int = 3
## Normalized distance along the host segment centerline [0..1] where the exit peels off.
@export var along_t: float = 0.45
@export var detour_segment_count: int = 3
@export var detour_segment_length: float = 28.0
@export var detour_width: float = 7.0
## How sharply the ramp turns off the main road (degrees from travel forward).
@export var peel_angle_degrees: float = 70.0
@export var poi: PointOfInterest
