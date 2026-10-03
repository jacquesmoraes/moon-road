extends Node
class_name DrivingModeController
## Single source of truth for driving assistance state.
## MANUAL → player drives; CRUISE → speed hold only; TRAVEL_MODE → cruise + road-follow.

enum Mode {
	MANUAL,
	CRUISE,
	TRAVEL_MODE,
}

signal mode_changed(previous_mode: Mode, current_mode: Mode)

@export var vehicle_path: NodePath
## Sibling RoadFollowAutopilot when this node is a child of PlayerVehicle.
@export var autopilot_path: NodePath = NodePath("../RoadFollowAutopilot")

var _mode: Mode = Mode.MANUAL
var _vehicle: Node
var _autopilot: Node


func _ready() -> void:
	_resolve_refs()
	# Autopilot must not own cruise/mode — this controller does.
	if _autopilot != null and _autopilot.get("enable_cruise_when_active") != null:
		_autopilot.set("enable_cruise_when_active", false)


func _physics_process(_delta: float) -> void:
	_resolve_refs()

	if _vehicle != null and _vehicle.has_method("is_manual_control_enabled"):
		if not bool(_vehicle.call("is_manual_control_enabled")):
			# Player on foot: keep assisted modes off; ignore toggles.
			if _mode != Mode.MANUAL:
				set_mode(Mode.MANUAL)
			return

	if _vehicle != null and _vehicle.has_method("is_parked") and bool(_vehicle.call("is_parked")):
		# Parked: keep assisted modes off; ignore cruise / travel toggles.
		if _mode != Mode.MANUAL:
			set_mode(Mode.MANUAL)
		return

	# One combined toggle so dual-bound actions cannot flip twice in one frame.
	# vehicle_autopilot_toggle remains a Travel Mode shortcut when this controller is present.
	if (
		Input.is_action_just_pressed("vehicle_travel_mode_toggle")
		or Input.is_action_just_pressed("vehicle_autopilot_toggle")
	):
		if _mode == Mode.TRAVEL_MODE:
			set_mode(Mode.MANUAL)
		else:
			set_mode(Mode.TRAVEL_MODE)

	if (
		Input.is_action_just_pressed("vehicle_travel_mode_cancel")
		or Input.is_action_just_pressed("vehicle_autopilot_cancel")
	):
		if _mode == Mode.TRAVEL_MODE:
			set_mode(Mode.MANUAL)

	if Input.is_action_just_pressed("vehicle_cruise_toggle"):
		_handle_cruise_toggle()

	if _mode == Mode.MANUAL:
		return

	# Immediate cancel on brake (all assisted modes).
	if Input.get_action_strength("vehicle_brake") > 0.1:
		set_mode(Mode.MANUAL)
		return

	# Travel Mode also cancels on manual steer.
	if _mode == Mode.TRAVEL_MODE and absf(Input.get_axis("vehicle_left", "vehicle_right")) > 0.1:
		set_mode(Mode.MANUAL)


func get_mode() -> Mode:
	return _mode


func get_mode_name() -> String:
	match _mode:
		Mode.MANUAL:
			return "MANUAL"
		Mode.CRUISE:
			return "CRUISE"
		Mode.TRAVEL_MODE:
			return "TRAVEL_MODE"
	return "MANUAL"


func is_manual() -> bool:
	return _mode == Mode.MANUAL


func is_cruise() -> bool:
	return _mode == Mode.CRUISE


func is_travel_mode() -> bool:
	return _mode == Mode.TRAVEL_MODE


## True when vehicle should hold cruise target speed (CRUISE or TRAVEL_MODE).
func is_speed_hold_active() -> bool:
	if _vehicle != null and _vehicle.has_method("is_parked") and bool(_vehicle.call("is_parked")):
		return false
	return _mode == Mode.CRUISE or _mode == Mode.TRAVEL_MODE


func set_mode(mode: Mode) -> void:
	_resolve_refs()
	if (
		mode != Mode.MANUAL
		and _vehicle != null
		and _vehicle.has_method("is_parked")
		and bool(_vehicle.call("is_parked"))
	):
		mode = Mode.MANUAL
	if mode == _mode:
		_apply_mode_effects()
		return
	var previous := _mode
	_mode = mode
	_apply_mode_effects()
	mode_changed.emit(previous, _mode)


func _handle_cruise_toggle() -> void:
	match _mode:
		Mode.TRAVEL_MODE:
			# Drop autopilot but keep speed hold.
			set_mode(Mode.CRUISE)
		Mode.CRUISE:
			set_mode(Mode.MANUAL)
		Mode.MANUAL:
			set_mode(Mode.CRUISE)


func _apply_mode_effects() -> void:
	if _vehicle == null:
		return

	match _mode:
		Mode.MANUAL:
			if _vehicle.has_method("set_cruise_control_active"):
				_vehicle.call("set_cruise_control_active", false)
			if _autopilot != null and _autopilot.has_method("set_autopilot_active"):
				_autopilot.call("set_autopilot_active", false)
		Mode.CRUISE:
			if _vehicle.has_method("set_cruise_control_active"):
				_vehicle.call("set_cruise_control_active", true)
			if _autopilot != null and _autopilot.has_method("set_autopilot_active"):
				_autopilot.call("set_autopilot_active", false)
		Mode.TRAVEL_MODE:
			if _vehicle.has_method("set_cruise_control_active"):
				_vehicle.call("set_cruise_control_active", true)
			if _autopilot != null and _autopilot.has_method("set_autopilot_active"):
				_autopilot.call("set_autopilot_active", true)


func _resolve_refs() -> void:
	if vehicle_path != NodePath():
		_vehicle = get_node_or_null(vehicle_path)
	if _vehicle == null:
		_vehicle = get_parent()

	if autopilot_path != NodePath():
		_autopilot = get_node_or_null(autopilot_path)
	if _autopilot == null and _vehicle != null:
		_autopilot = _vehicle.get_node_or_null("RoadFollowAutopilot")
