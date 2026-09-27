extends CanvasLayer
## Development-only driving HUD. Reads vehicle/journey public data; never controls the vehicle.

@export var vehicle_path: NodePath = NodePath("../PlayerVehicle")
@export var show_fps: bool = true

@onready var _label: Label = $Margin/Panel/Label

var _vehicle: Node3D
var _journey: Node


func _ready() -> void:
	_resolve_vehicle()
	_journey = get_node_or_null("/root/JourneySystem")


func _process(_delta: float) -> void:
	if _vehicle == null or not is_instance_valid(_vehicle):
		_resolve_vehicle()
		if _vehicle == null:
			_label.text = "DrivingDebugHUD: no vehicle"
			return

	if _journey == null:
		_journey = get_node_or_null("/root/JourneySystem")

	var speed_kmh := 0.0
	if _vehicle.has_method("get_speed_kmh"):
		speed_kmh = float(_vehicle.call("get_speed_kmh"))

	var pos := _vehicle.global_position
	var accel := Input.get_action_strength("vehicle_accelerate")
	var brake := Input.get_action_strength("vehicle_brake")
	var steer := Input.get_axis("vehicle_left", "vehicle_right")

	var current_km := 0.0
	var total_km := 384400.0
	var remaining_km := total_km
	var progress := 0.0
	var scale := 1.0
	if _journey != null:
		current_km = float(_journey.call("get_current_distance_km"))
		total_km = float(_journey.call("get_total_distance_km"))
		remaining_km = float(_journey.call("get_remaining_distance_km"))
		progress = float(_journey.call("get_progress_ratio"))
		scale = float(_journey.call("get_physical_to_journey_scale"))

	var lines: PackedStringArray = [
		"DEV HUD",
		"Journey: %s / %s km" % [_format_journey_km(current_km), _format_journey_km(total_km)],
		"Remaining: %s km (%.4f%%)" % [_format_journey_km(remaining_km), progress * 100.0],
		"Phys→Journey scale: %.3f" % scale,
		"Speed: %.1f km/h" % speed_kmh,
		"Pos: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z],
		"Controls: A=%.0f  B=%.0f  Steer=%+.0f" % [accel, brake, steer],
	]

	var recenter := get_tree().current_scene.find_child("WorldOriginRecenter", true, false)
	if recenter != null and recenter.has_method("get_recenter_count"):
		lines.append("Origin recenters: %d" % int(recenter.call("get_recenter_count")))

	if show_fps:
		lines.append("FPS: %d" % Engine.get_frames_per_second())

	_label.text = "\n".join(lines)


func _format_journey_km(km: float) -> String:
	## Matches design-style grouping for large values (384.400); decimals for small sandbox distances.
	if not is_finite(km):
		return "?"
	if km >= 1000.0:
		var whole := int(round(km))
		var digits := str(absi(whole))
		var grouped := ""
		while digits.length() > 3:
			grouped = "." + digits.substr(digits.length() - 3, 3) + grouped
			digits = digits.substr(0, digits.length() - 3)
		var sign := "-" if whole < 0 else ""
		return sign + digits + grouped
	return "%.3f" % km


func _resolve_vehicle() -> void:
	if vehicle_path != NodePath():
		_vehicle = get_node_or_null(vehicle_path) as Node3D
	if _vehicle == null:
		_vehicle = get_tree().current_scene.find_child("PlayerVehicle", true, false) as Node3D
