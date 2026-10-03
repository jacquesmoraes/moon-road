extends CanvasLayer
## Development-only driving HUD. Reads vehicle/journey/occupancy public data; never controls them.
## In TRAVEL_MODE, shows only essential contemplative readouts.

@export var vehicle_path: NodePath = NodePath("../PlayerVehicle")
@export var occupancy_path: NodePath = NodePath("../PlayerOccupancyController")
@export var show_fps: bool = true

@onready var _label: Label = $Margin/Panel/Label

var _vehicle: Node3D
var _occupancy: Node
var _journey: Node
var _regions: Node
var _exits: Node


func _ready() -> void:
	_resolve_vehicle()
	_resolve_occupancy()
	_journey = get_node_or_null("/root/JourneySystem")
	_regions = get_node_or_null("/root/WorldRegionSystem")
	_resolve_exits()


func _process(_delta: float) -> void:
	if _vehicle == null or not is_instance_valid(_vehicle):
		_resolve_vehicle()
		if _vehicle == null:
			_label.text = "DrivingDebugHUD: no vehicle"
			return

	if _occupancy == null or not is_instance_valid(_occupancy):
		_resolve_occupancy()

	if _journey == null:
		_journey = get_node_or_null("/root/JourneySystem")
	if _regions == null:
		_regions = get_node_or_null("/root/WorldRegionSystem")
	if _exits == null:
		_resolve_exits()

	if _occupancy != null and _occupancy.has_method("is_on_foot") and bool(_occupancy.call("is_on_foot")):
		_label.text = "\n".join(_build_on_foot_lines())
		return

	var travel_mode := false
	if _vehicle.has_method("is_travel_mode"):
		travel_mode = bool(_vehicle.call("is_travel_mode"))

	if travel_mode:
		_label.text = "\n".join(_build_travel_mode_lines())
	else:
		_label.text = "\n".join(_build_full_lines())


func _build_on_foot_lines() -> PackedStringArray:
	var char_node: Node3D = null
	if _occupancy != null and _occupancy.has_method("get_character"):
		char_node = _occupancy.call("get_character") as Node3D
	var pos := char_node.global_position if char_node != null else Vector3.ZERO
	var can_enter := false
	if _occupancy != null and _occupancy.has_method("can_enter_vehicle"):
		can_enter = bool(_occupancy.call("can_enter_vehicle"))
	var speed := 0.0
	var running := false
	if char_node != null:
		if char_node.has_method("get_planar_speed"):
			speed = float(char_node.call("get_planar_speed"))
		if char_node.has_method("is_running"):
			running = bool(char_node.call("is_running"))
	var cam_mode := "THIRD_PERSON"
	if _occupancy != null and _occupancy.has_method("get_on_foot_camera"):
		var foot_cam: Node = _occupancy.call("get_on_foot_camera")
		if foot_cam != null and foot_cam.has_method("get_view_mode_name"):
			cam_mode = str(foot_cam.call("get_view_mode_name"))
	var lines: PackedStringArray = [
		"ON FOOT",
		"Occupancy: %s" % _format_occupancy(),
		"Vehicle: %s (stays put)" % _format_motion_state(),
		"Speed: %.1f m/s%s" % [speed, "  RUN" if running else ""],
		"Pos: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z],
		"Walk: WASD · Run: Shift · Look: mouse",
		"%s" % _format_on_foot_e_hint(char_node, can_enter),
		"Camera: %s (on-foot)" % cam_mode,
	]
	if show_fps:
		lines.append("FPS: %d" % Engine.get_frames_per_second())
	return lines


func _build_travel_mode_lines() -> PackedStringArray:
	var speed_kmh := 0.0
	if _vehicle.has_method("get_speed_kmh"):
		speed_kmh = float(_vehicle.call("get_speed_kmh"))

	var current_km := 0.0
	var remaining_km := 384400.0
	if _journey != null:
		current_km = float(_journey.call("get_current_distance_km"))
		remaining_km = float(_journey.call("get_remaining_distance_km"))

	var target_kmh := 0.0
	if _vehicle.has_method("get_cruise_target_speed_kmh"):
		target_kmh = float(_vehicle.call("get_cruise_target_speed_kmh"))

	var lines: PackedStringArray = [
		"TRAVEL MODE",
		"Occupancy: %s" % _format_occupancy(),
		"Motion: %s" % _format_motion_state(),
		"Region: %s" % _format_region_name(),
		"Journey: %s km" % _format_journey_km(current_km),
		"Remaining: %s km" % _format_journey_km(remaining_km),
		"Speed: %.0f / %.0f km/h" % [speed_kmh, target_kmh],
		"Camera: %s (M cine · F / Shift+F)" % _format_camera_mode(),
		"Cancel: V / T / X / Esc / brake / steer",
	]
	return lines


func _build_full_lines() -> PackedStringArray:
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

	var exit_hint := ""
	if _format_motion_state() == "PARKED":
		exit_hint = " · E exit"

	var lines: PackedStringArray = [
		"DEV HUD",
		"Occupancy: %s" % _format_occupancy(),
		"Motion: %s (P park/unpark%s)" % [_format_motion_state(), exit_hint],
		"Mode: %s" % _format_driving_mode(),
		"Region: %s (%.0f%%)" % [_format_region_name(), _format_region_progress() * 100.0],
		"Exit/POI: %s" % _format_exit_poi(),
		"Camera: %s (M cine · F / Shift+F)" % _format_camera_mode(),
		"Journey: %s / %s km" % [_format_journey_km(current_km), _format_journey_km(total_km)],
		"Remaining: %s km (%.4f%%)" % [_format_journey_km(remaining_km), progress * 100.0],
		"Phys→Journey scale: %.3f" % scale,
		"Speed: %.1f km/h" % speed_kmh,
		"Cruise: %s" % _format_cruise_state(),
		"Autopilot: %s" % _format_autopilot_state(),
		"Pos: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z],
		"Controls: A=%.0f  B=%.0f  Steer=%+.0f" % [accel, brake, steer],
		"Save: F5 save · F9 load · F6 delete",
	]

	var recenter := get_tree().current_scene.find_child("WorldOriginRecenter", true, false)
	if recenter != null and recenter.has_method("get_recenter_count"):
		lines.append("Origin recenters: %d" % int(recenter.call("get_recenter_count")))

	if show_fps:
		lines.append("FPS: %d" % Engine.get_frames_per_second())

	return lines


func _format_on_foot_e_hint(char_node: Node3D, can_enter: bool) -> String:
	## E is shared: interactables win when focused; else enter vehicle.
	if char_node != null and char_node.has_method("has_interaction_focus"):
		if bool(char_node.call("has_interaction_focus")):
			var prompt := ""
			if char_node.has_method("get_interaction_prompt"):
				prompt = str(char_node.call("get_interaction_prompt"))
			if prompt.is_empty():
				prompt = "E — Interagir"
			return "Interact: %s" % prompt
	if can_enter:
		return "Enter: E (in range) · Interact when facing objects"
	return "Enter: E (near vehicle) · Interact: E on objects"


func _format_occupancy() -> String:
	if _occupancy == null:
		return "IN_VEHICLE"
	if _occupancy.has_method("get_state_name"):
		return str(_occupancy.call("get_state_name"))
	return "IN_VEHICLE"


func _format_motion_state() -> String:
	if _vehicle == null:
		return "n/a"
	if _vehicle.has_method("get_motion_state_name"):
		return str(_vehicle.call("get_motion_state_name"))
	if _vehicle.has_method("is_parked") and bool(_vehicle.call("is_parked")):
		return "PARKED"
	return "DRIVING"


func _format_driving_mode() -> String:
	if _vehicle == null:
		return "n/a"
	if _vehicle.has_method("get_driving_mode_name"):
		return str(_vehicle.call("get_driving_mode_name"))
	return "MANUAL"


func _format_region_name() -> String:
	if _regions != null and _regions.has_method("get_current_region_name"):
		var name := str(_regions.call("get_current_region_name"))
		if not name.is_empty():
			return name
	return "n/a"


func _format_region_progress() -> float:
	if _regions != null and _regions.has_method("get_region_progress"):
		return float(_regions.call("get_region_progress"))
	return 0.0


func _format_exit_poi() -> String:
	if _exits == null:
		return "none"
	var discovered := ""
	var poi_sys := get_node_or_null("/root/POISystem")
	if poi_sys != null and poi_sys.has_method("is_discovered"):
		if bool(poi_sys.call("is_discovered", "sunset_viewpoint")):
			discovered = " · discovered"
	if _exits.has_method("is_exit_active") and bool(_exits.call("is_exit_active")):
		var name := ""
		if _exits.has_method("get_active_poi_name"):
			name = str(_exits.call("get_active_poi_name"))
		if name.is_empty():
			name = "exit"
		return "%s (steer right onto ramp)%s" % [name, discovered]
	if not discovered.is_empty():
		return "Sunset Viewpoint%s" % discovered
	return "none nearby"


func _format_camera_mode() -> String:
	var cam := get_tree().current_scene.find_child("VehicleCameraController", true, false)
	if cam == null:
		return "FOLLOW"
	if cam.has_method("get_cinematic_label"):
		return str(cam.call("get_cinematic_label"))
	if cam.has_method("get_mode_name"):
		return str(cam.call("get_mode_name"))
	return "FOLLOW"


func _format_cruise_state() -> String:
	if _vehicle == null:
		return "n/a"
	var active := false
	var target_kmh := 0.0
	if _vehicle.has_method("is_cruise_control_active"):
		active = bool(_vehicle.call("is_cruise_control_active"))
	if _vehicle.has_method("get_cruise_target_speed_kmh"):
		target_kmh = float(_vehicle.call("get_cruise_target_speed_kmh"))
	if active:
		return "ON  target %.0f km/h" % target_kmh
	return "OFF  target %.0f km/h" % target_kmh


func _format_autopilot_state() -> String:
	if _vehicle == null:
		return "n/a"
	var autopilot := _vehicle.get_node_or_null("RoadFollowAutopilot")
	if autopilot == null and get_tree().current_scene != null:
		autopilot = get_tree().current_scene.find_child("RoadFollowAutopilot", true, false)
	if autopilot == null or not autopilot.has_method("is_autopilot_active"):
		return "n/a"
	return "ON" if bool(autopilot.call("is_autopilot_active")) else "OFF"


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


func _resolve_occupancy() -> void:
	if occupancy_path != NodePath():
		_occupancy = get_node_or_null(occupancy_path)
	if _occupancy == null and get_tree().current_scene != null:
		_occupancy = get_tree().current_scene.find_child("PlayerOccupancyController", true, false)


func _resolve_exits() -> void:
	if get_tree() == null or get_tree().current_scene == null:
		return
	_exits = get_tree().current_scene.find_child("RoadsideExitSystem", true, false)
