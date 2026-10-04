extends Node
class_name NpcMovementController
## Physical walk between POI markers via NavigationAgent3D.
## Separate from dialogue, schedule data, definition, and persistence.
## Schedule only supplies location_id; this node resolves markers and moves.

const DestinationResolver := preload("res://scripts/npc/npc_destination_resolver.gd")

signal destination_started(location_id: String)
signal destination_reached(location_id: String)
signal destination_failed(location_id: String)

@export var max_speed: float = 2.8
@export var acceleration: float = 10.0
@export var rotation_speed: float = 12.0
@export var arrival_distance: float = 0.4
@export var enabled: bool = true

var _agent: NavigationAgent3D
var _body: Node3D
## reason → true (dialogue / availability / manual)
var _pause_reasons: Dictionary = {}
var _desired_location_id: String = ""
var _active_location_id: String = ""
var _arrived: bool = true
var _current_speed: float = 0.0
var _target_position: Vector3 = Vector3.ZERO
var _has_target: bool = false
var _schedule: Node = null
var _dialogue: Node = null


func _ready() -> void:
	_body = get_parent() as Node3D
	_ensure_agent()
	_configure_agent()
	_schedule = get_node_or_null("/root/NpcScheduleSystem")
	_dialogue = get_node_or_null("/root/DialogueSystem")
	_connect_signals()
	set_physics_process(true)
	call_deferred("_bootstrap")


func _ensure_agent() -> void:
	## NavigationAgent3D must parent under a Node3D (the NPC body), not this Node.
	if _body != null:
		_agent = _body.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	if _agent == null:
		_agent = get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	if _agent != null and _body != null and _agent.get_parent() != _body:
		_agent.reparent(_body)
	if _agent == null and _body != null:
		_agent = NavigationAgent3D.new()
		_agent.name = "NavigationAgent3D"
		_body.add_child(_agent)


func _configure_agent() -> void:
	if _agent == null:
		return
	_agent.path_desired_distance = maxf(arrival_distance * 0.6, 0.15)
	_agent.target_desired_distance = maxf(arrival_distance, 0.25)
	_agent.avoidance_enabled = false
	_agent.radius = 0.35
	_agent.height = 1.6
	_agent.max_speed = max_speed


func _connect_signals() -> void:
	if _schedule != null and _schedule.has_signal("npc_schedule_changed"):
		if not _schedule.npc_schedule_changed.is_connected(_on_schedule_changed):
			_schedule.npc_schedule_changed.connect(_on_schedule_changed)
	if _dialogue != null:
		if _dialogue.has_signal("dialogue_started") and not _dialogue.dialogue_started.is_connected(_on_dialogue_started):
			_dialogue.dialogue_started.connect(_on_dialogue_started)
		if _dialogue.has_signal("dialogue_resumed") and not _dialogue.dialogue_resumed.is_connected(_on_dialogue_resumed):
			_dialogue.dialogue_resumed.connect(_on_dialogue_resumed)
		if _dialogue.has_signal("dialogue_finished") and not _dialogue.dialogue_finished.is_connected(_on_dialogue_finished):
			_dialogue.dialogue_finished.connect(_on_dialogue_finished)
		if _dialogue.has_signal("dialogue_cancelled") and not _dialogue.dialogue_cancelled.is_connected(_on_dialogue_cancelled):
			_dialogue.dialogue_cancelled.connect(_on_dialogue_cancelled)
		if _dialogue.has_signal("dialogue_interrupted") and not _dialogue.dialogue_interrupted.is_connected(_on_dialogue_interrupted):
			_dialogue.dialogue_interrupted.connect(_on_dialogue_interrupted)


func _bootstrap() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	## On POI load/reload: snap to current schedule location (no catch-up path).
	var location := _resolve_logical_location_id()
	if not location.is_empty():
		go_to_location(location, true)


func get_desired_location_id() -> String:
	return _desired_location_id


func get_active_location_id() -> String:
	return _active_location_id


func is_paused() -> bool:
	return not _pause_reasons.is_empty()


func is_moving() -> bool:
	return enabled and not is_paused() and _has_target and not _arrived and _current_speed > 0.05


func has_arrived() -> bool:
	return _arrived


func pause_movement(reason: String = "manual") -> void:
	var key := reason if not reason.is_empty() else "manual"
	_pause_reasons[key] = true
	_current_speed = 0.0


func resume_movement(reason: String = "manual") -> void:
	var key := reason if not reason.is_empty() else "manual"
	_pause_reasons.erase(key)
	if is_paused():
		return
	if not _desired_location_id.is_empty() and not _arrived:
		go_to_location(_desired_location_id, false)
	elif not _desired_location_id.is_empty() and _active_location_id != _desired_location_id:
		go_to_location(_desired_location_id, false)


func go_to_location(location_id: String, snap: bool = false) -> bool:
	## Fail-safe: missing marker keeps logical state; returns false.
	_desired_location_id = location_id
	if not enabled or _body == null or location_id.is_empty():
		return false
	var pos: Variant = DestinationResolver.find_global_position(_body, location_id)
	if typeof(pos) != TYPE_VECTOR3:
		destination_failed.emit(location_id)
		return false
	_target_position = pos as Vector3
	_has_target = true
	_active_location_id = location_id
	if snap:
		_snap_to(_target_position)
		_arrived = true
		_current_speed = 0.0
		if _agent_ready():
			_agent.target_position = _body.global_position
		destination_reached.emit(location_id)
		return true
	if is_paused():
		# Keep desired target; do not walk away mid-dialogue / while hidden.
		_arrived = false
		return true
	_arrived = false
	if _agent_ready():
		_agent.target_position = _target_position
	destination_started.emit(location_id)
	return true


func snap_to_current_schedule() -> bool:
	var location := _resolve_logical_location_id()
	if location.is_empty():
		return false
	return go_to_location(location, true)


func _physics_process(delta: float) -> void:
	if not enabled or _body == null or not _has_target:
		return
	if is_paused() or _arrived:
		_current_speed = move_toward(_current_speed, 0.0, acceleration * delta)
		return

	var to_target := _target_position - _body.global_position
	to_target.y = 0.0
	var dist := to_target.length()
	if dist <= arrival_distance:
		_finish_arrival()
		return

	var next := _target_position
	if _agent_ready() and not _agent.is_navigation_finished():
		next = _agent.get_next_path_position()
	var to_next := next - _body.global_position
	to_next.y = 0.0
	if to_next.length_squared() < 0.0001:
		_finish_arrival()
		return
	var direction := to_next.normalized()
	_current_speed = move_toward(_current_speed, max_speed, acceleration * delta)
	var approach := clampf(dist / maxf(arrival_distance * 3.0, 0.5), 0.25, 1.0)
	var step := direction * _current_speed * approach * delta
	if step.length() > dist:
		step = direction * dist
	_body.global_position += Vector3(step.x, 0.0, step.z)
	_face_direction(direction, delta)


func _agent_ready() -> bool:
	return (
		_agent != null
		and _agent.is_inside_tree()
		and _agent.get_parent() is Node3D
	)


func _finish_arrival() -> void:
	_snap_to(_target_position)
	_arrived = true
	_current_speed = 0.0
	if _agent_ready():
		_agent.target_position = _body.global_position
	destination_reached.emit(_active_location_id)


func _snap_to(pos: Vector3) -> void:
	if _body == null:
		return
	_body.global_position = Vector3(pos.x, _body.global_position.y, pos.z)


func _face_direction(direction: Vector3, delta: float) -> void:
	if _body == null or direction.length_squared() < 0.0001:
		return
	var target_basis := Basis.looking_at(direction, Vector3.UP)
	var current := _body.global_transform.basis
	var blended := current.slerp(target_basis, clampf(rotation_speed * delta, 0.0, 1.0))
	_body.global_transform = Transform3D(blended, _body.global_position)


func _on_schedule_changed(
	npc_id: String,
	location_id: String,
	_state: String,
	_activity_id: String,
	_schedule_id: String
) -> void:
	if npc_id.is_empty() or npc_id != _npc_id():
		return
	if location_id.is_empty():
		return
	go_to_location(location_id, false)


func _on_dialogue_started(_dialogue_id: String) -> void:
	if _body != null and bool(_body.get_meta("movement_dialogue_lock", false)):
		pause_movement("dialogue")


func _on_dialogue_resumed(_dialogue_id: String) -> void:
	if _body != null and bool(_body.get_meta("movement_dialogue_lock", false)):
		pause_movement("dialogue")


func _on_dialogue_finished(_dialogue_id: String) -> void:
	_release_dialogue_pause()


func _on_dialogue_cancelled() -> void:
	## cancel_dialogue / end_dialogue(false) — resume walk.
	_release_dialogue_pause()


func _on_dialogue_interrupted(_reason: String) -> void:
	## Interrupt returns control; walk may resume until dialogue resumes.
	_release_dialogue_pause()


func _release_dialogue_pause() -> void:
	if _body == null:
		return
	if not bool(_body.get_meta("movement_dialogue_lock", false)) and not _pause_reasons.has("dialogue"):
		return
	_body.set_meta("movement_dialogue_lock", false)
	resume_movement("dialogue")


func _resolve_logical_location_id() -> String:
	var id := _npc_id()
	if id.is_empty():
		return ""
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null and ns.has_method("get_location_id"):
		var loc := str(ns.call("get_location_id", id))
		if not loc.is_empty():
			return loc
	if _schedule != null and _schedule.has_method("get_active_location_id"):
		return str(_schedule.call("get_active_location_id", id))
	return ""


func _npc_id() -> String:
	if _body != null and _body.has_method("get_npc_id"):
		return str(_body.call("get_npc_id"))
	return ""
