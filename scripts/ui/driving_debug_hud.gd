extends CanvasLayer
## Development-only driving HUD. Reads vehicle public data; never controls the vehicle.

@export var vehicle_path: NodePath = NodePath("../PlayerVehicle")
@export var show_fps: bool = true

@onready var _label: Label = $Margin/Panel/Label

var _vehicle: Node3D


func _ready() -> void:
	_resolve_vehicle()


func _process(_delta: float) -> void:
	if _vehicle == null or not is_instance_valid(_vehicle):
		_resolve_vehicle()
		if _vehicle == null:
			_label.text = "DrivingDebugHUD: no vehicle"
			return

	var speed_kmh := 0.0
	if _vehicle.has_method("get_speed_kmh"):
		speed_kmh = float(_vehicle.call("get_speed_kmh"))

	var pos := _vehicle.global_position
	var accel := Input.get_action_strength("vehicle_accelerate")
	var brake := Input.get_action_strength("vehicle_brake")
	var steer := Input.get_axis("vehicle_left", "vehicle_right")

	var lines: PackedStringArray = [
		"DEV HUD",
		"Speed: %.1f km/h" % speed_kmh,
		"Pos: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z],
		"Controls: A=%.0f  B=%.0f  Steer=%+.0f" % [accel, brake, steer],
	]
	if show_fps:
		lines.append("FPS: %d" % Engine.get_frames_per_second())

	_label.text = "\n".join(lines)


func _resolve_vehicle() -> void:
	if vehicle_path != NodePath():
		_vehicle = get_node_or_null(vehicle_path) as Node3D
	if _vehicle == null:
		_vehicle = get_tree().current_scene.find_child("PlayerVehicle", true, false) as Node3D
