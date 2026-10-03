extends Node3D
class_name VehicleCameraController
## Multi-mode vehicle camera + optional Travel Mode cinematic director.
## Does not affect vehicle physics, autopilot, journey, or road systems.

enum CameraMode {
	FOLLOW,
	FAR,
	HOOD,
	PASSENGER,
	WINDOW,
}

signal mode_changed(mode: CameraMode)
signal cinematic_changed(active: bool)

@export var target_path: NodePath
@export var mode: CameraMode = CameraMode.FOLLOW:
	set(value):
		if mode == value:
			return
		var previous := mode
		mode = value
		_on_mode_changed(previous)

@export_group("FOLLOW (default chase)")
@export var follow_distance: float = 7.5
@export var follow_height: float = 3.2
@export var follow_smoothing: float = 5.5
@export var follow_rotation_speed: float = 3.2
@export var follow_fov: float = 70.0

@export_group("FAR")
@export var far_distance: float = 16.0
@export var far_height: float = 6.5
@export var far_smoothing: float = 4.0
@export var far_rotation_speed: float = 2.4
@export var far_fov: float = 85.0

@export_group("HOOD")
@export var hood_offset: Vector3 = Vector3(0.0, 1.05, -1.35)
@export var hood_look: Vector3 = Vector3(0.0, 1.0, -12.0)
@export var hood_smoothing: float = 14.0
@export var hood_fov: float = 78.0

@export_group("PASSENGER")
@export var passenger_offset: Vector3 = Vector3(0.42, 1.2, 0.15)
@export var passenger_look: Vector3 = Vector3(0.2, 1.05, -14.0)
@export var passenger_smoothing: float = 12.0
@export var passenger_fov: float = 70.0

@export_group("WINDOW")
@export var window_offset: Vector3 = Vector3(0.95, 1.25, 0.1)
@export var window_look: Vector3 = Vector3(14.0, 1.4, -4.0)
@export var window_smoothing: float = 10.0
@export var window_fov: float = 82.0

@export_group("Cinematic (Travel Mode)")
@export var cinematic_min_duration: float = 8.0
@export var cinematic_max_duration: float = 25.0
@export var cinematic_transition_duration: float = 2.0
## HOOD shots use a shorter hold so they don't linger.
@export var cinematic_hood_max_duration: float = 10.0
@export var cinematic_weight_follow: float = 1.0
@export var cinematic_weight_far: float = 1.0
@export var cinematic_weight_hood: float = 0.35
@export var cinematic_weight_passenger: float = 0.5
@export var cinematic_weight_window: float = 0.5
@export var cinematic_allowed_modes: Array[CameraMode] = [
	CameraMode.FOLLOW,
	CameraMode.FAR,
	CameraMode.HOOD,
	CameraMode.PASSENGER,
	CameraMode.WINDOW,
]

## Legacy alias kept for existing scenes / README knobs.
@export var rotation_speed: float = 3.2:
	set(value):
		rotation_speed = value
		follow_rotation_speed = value

const LOOK_AT_HEIGHT: float = 1.0
const MODE_CYCLE: Array[CameraMode] = [
	CameraMode.FOLLOW,
	CameraMode.FAR,
	CameraMode.HOOD,
	CameraMode.PASSENGER,
	CameraMode.WINDOW,
]

@onready var _camera: Camera3D = $Camera3D

var _target: Node3D
var _smoothed_yaw: float = 0.0
var _initialized: bool = false

var _cinematic_active: bool = false
var _shot_timer: float = 0.0
var _shot_hold: float = 12.0
var _blend_time: float = 0.0
var _blending: bool = false
var _blend_from_mode: CameraMode = CameraMode.FOLLOW
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	follow_rotation_speed = rotation_speed
	_rng.randomize()

	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		_target = get_parent() as Node3D

	call_deferred("_detach_to_scene_root")

	if _camera:
		_camera.current = true
		_apply_fov(mode)


func _detach_to_scene_root() -> void:
	var scene := get_tree().current_scene
	if scene != null and get_parent() != scene:
		reparent(scene, true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("vehicle_camera_cinematic_toggle"):
		toggle_cinematic()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("vehicle_camera_next"):
		if _cinematic_active:
			set_cinematic_active(false)
		cycle_mode(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("vehicle_camera_previous"):
		if _cinematic_active:
			set_cinematic_active(false)
		cycle_mode(-1)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return

	if _cinematic_active and not _is_travel_mode():
		set_cinematic_active(false)

	if _cinematic_active:
		_update_cinematic(delta)

	if _blending:
		_update_blend(delta)
		return

	_update_mode_pose(mode, delta, true)


func get_mode() -> CameraMode:
	return mode


func get_mode_name() -> String:
	return _mode_label(mode)


func is_cinematic_active() -> bool:
	return _cinematic_active


func get_cinematic_label() -> String:
	if _cinematic_active:
		return "CINEMATIC→%s" % get_mode_name()
	return get_mode_name()


func set_mode(new_mode: CameraMode) -> void:
	mode = new_mode


func cycle_mode(direction: int = 1) -> void:
	var idx := MODE_CYCLE.find(mode)
	if idx < 0:
		idx = 0
	var step := 1 if direction >= 0 else -1
	idx = (idx + step) % MODE_CYCLE.size()
	if idx < 0:
		idx += MODE_CYCLE.size()
	mode = MODE_CYCLE[idx]


func toggle_cinematic() -> void:
	if _cinematic_active:
		set_cinematic_active(false)
		return
	if not _is_travel_mode():
		return
	set_cinematic_active(true)


func set_cinematic_active(active: bool) -> void:
	if active == _cinematic_active:
		return
	if active and not _is_travel_mode():
		return
	_cinematic_active = active
	_blending = false
	if _cinematic_active:
		_begin_shot(true)
	cinematic_changed.emit(_cinematic_active)


func get_camera() -> Camera3D:
	return _camera


func get_follow_target() -> Node3D:
	return _target


## Retarget chase/rigged poses (vehicle while driving, character while on foot).
func set_follow_target(target: Node3D) -> void:
	_target = target
	_initialized = false
	_blending = false
	if _cinematic_active:
		set_cinematic_active(false)
	if _target != null and is_instance_valid(_target):
		_smoothed_yaw = _target.global_rotation.y


## Origin recenter already shifts global_position; poses are recomputed from the live target.
func notify_origin_shifted(_offset: Vector3) -> void:
	pass


func _on_mode_changed(previous: CameraMode) -> void:
	if _cinematic_active and previous != mode:
		_start_blend(previous, mode)
	else:
		_blending = false
		_initialized = false
		_apply_fov(mode)
	mode_changed.emit(mode)


func _update_cinematic(delta: float) -> void:
	if _blending:
		return
	_shot_timer += delta
	if _shot_timer >= _shot_hold:
		_begin_shot(false)


func _begin_shot(initial: bool) -> void:
	## First shot holds the current mode; later shots pick a weighted alternative.
	var next: CameraMode = mode if initial else _pick_weighted_mode(mode)
	_shot_hold = _roll_shot_duration(next)
	_shot_timer = 0.0
	if next == mode:
		if initial:
			_apply_fov(mode)
		return
	mode = next


func _pick_weighted_mode(avoid: CameraMode) -> CameraMode:
	var allowed: Array[CameraMode] = []
	var weights: Array[float] = []
	var source: Array = cinematic_allowed_modes
	if source.is_empty():
		source = MODE_CYCLE
	for m in source:
		var cm: CameraMode = m as CameraMode
		var w := _weight_for(cm)
		if w <= 0.0:
			continue
		# Prefer not repeating the current shot when alternatives exist.
		if cm == avoid and source.size() > 1:
			continue
		allowed.append(cm)
		weights.append(w)
	if allowed.is_empty():
		# Fall back including avoid.
		for m in source:
			var cm2: CameraMode = m as CameraMode
			var w2 := _weight_for(cm2)
			if w2 > 0.0:
				allowed.append(cm2)
				weights.append(w2)
	if allowed.is_empty():
		return CameraMode.FOLLOW
	var total := 0.0
	for w in weights:
		total += w
	var r := _rng.randf() * total
	for i in allowed.size():
		r -= weights[i]
		if r <= 0.0:
			return allowed[i]
	return allowed[allowed.size() - 1]


func _weight_for(m: CameraMode) -> float:
	match m:
		CameraMode.FOLLOW:
			return maxf(cinematic_weight_follow, 0.0)
		CameraMode.FAR:
			return maxf(cinematic_weight_far, 0.0)
		CameraMode.HOOD:
			return maxf(cinematic_weight_hood, 0.0)
		CameraMode.PASSENGER:
			return maxf(cinematic_weight_passenger, 0.0)
		CameraMode.WINDOW:
			return maxf(cinematic_weight_window, 0.0)
	return 0.0


func _roll_shot_duration(m: CameraMode) -> float:
	var lo := minf(cinematic_min_duration, cinematic_max_duration)
	var hi := maxf(cinematic_min_duration, cinematic_max_duration)
	if m == CameraMode.HOOD:
		hi = minf(hi, maxf(cinematic_hood_max_duration, lo))
	return _rng.randf_range(lo, hi)


func _start_blend(from_mode: CameraMode, to_mode: CameraMode) -> void:
	_blend_from_mode = from_mode
	_blend_time = 0.0
	_blending = cinematic_transition_duration > 0.05
	_initialized = true
	if not _blending:
		_apply_fov(to_mode)


func _update_blend(delta: float) -> void:
	_blend_time += delta
	var dur := maxf(cinematic_transition_duration, 0.05)
	var t := clampf(_blend_time / dur, 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)  # smoothstep

	# Advance chase yaw while blending so FOLLOW/FAR ends stay current.
	_tick_chase_yaw(delta, mode)
	_tick_chase_yaw(delta, _blend_from_mode)

	var from_pose := _compute_desired_pose(_blend_from_mode)
	var to_pose := _compute_desired_pose(mode)
	global_position = from_pose["pos"].lerp(to_pose["pos"], t)
	var look := (from_pose["look"] as Vector3).lerp(to_pose["look"] as Vector3, t)
	_look_at_world(look)
	if _camera:
		_camera.fov = lerpf(float(from_pose["fov"]), float(to_pose["fov"]), t)

	if t >= 1.0:
		_blending = false
		_apply_fov(mode)


func _update_mode_pose(m: CameraMode, delta: float, apply_smoothing: bool) -> void:
	match m:
		CameraMode.FOLLOW:
			_update_chase(
				delta,
				follow_distance,
				follow_height,
				follow_smoothing if apply_smoothing else 999.0,
				follow_rotation_speed
			)
		CameraMode.FAR:
			_update_chase(
				delta,
				far_distance,
				far_height,
				far_smoothing if apply_smoothing else 999.0,
				far_rotation_speed
			)
		CameraMode.HOOD:
			_update_rigged(
				delta,
				hood_offset,
				hood_look,
				hood_smoothing if apply_smoothing else 999.0
			)
		CameraMode.PASSENGER:
			_update_rigged(
				delta,
				passenger_offset,
				passenger_look,
				passenger_smoothing if apply_smoothing else 999.0
			)
		CameraMode.WINDOW:
			_update_rigged(
				delta,
				window_offset,
				window_look,
				window_smoothing if apply_smoothing else 999.0
			)


func _compute_desired_pose(m: CameraMode) -> Dictionary:
	var target_pos := _target.global_position
	match m:
		CameraMode.FOLLOW:
			return {
				"pos": _chase_position(target_pos, _smoothed_yaw, follow_distance, follow_height),
				"look": target_pos + Vector3.UP * LOOK_AT_HEIGHT,
				"fov": follow_fov,
			}
		CameraMode.FAR:
			return {
				"pos": _chase_position(target_pos, _smoothed_yaw, far_distance, far_height),
				"look": target_pos + Vector3.UP * LOOK_AT_HEIGHT,
				"fov": far_fov,
			}
		CameraMode.HOOD:
			return {
				"pos": _target.global_transform * hood_offset,
				"look": _target.global_transform * hood_look,
				"fov": hood_fov,
			}
		CameraMode.PASSENGER:
			return {
				"pos": _target.global_transform * passenger_offset,
				"look": _target.global_transform * passenger_look,
				"fov": passenger_fov,
			}
		CameraMode.WINDOW:
			return {
				"pos": _target.global_transform * window_offset,
				"look": _target.global_transform * window_look,
				"fov": window_fov,
			}
	return {
		"pos": global_position,
		"look": target_pos + Vector3.UP * LOOK_AT_HEIGHT,
		"fov": follow_fov,
	}


func _tick_chase_yaw(delta: float, m: CameraMode) -> void:
	if m != CameraMode.FOLLOW and m != CameraMode.FAR:
		return
	var yaw_speed := follow_rotation_speed if m == CameraMode.FOLLOW else far_rotation_speed
	var yaw_t := _exp_weight(yaw_speed, delta)
	_smoothed_yaw = lerp_angle(_smoothed_yaw, _target.global_rotation.y, yaw_t)


func _apply_fov(m: CameraMode) -> void:
	if _camera == null:
		return
	_camera.fov = float(_compute_desired_pose(m)["fov"])


func _update_chase(
	delta: float,
	distance: float,
	height: float,
	pos_smoothing: float,
	yaw_speed: float
) -> void:
	var target_pos := _target.global_position
	var target_yaw := _target.global_rotation.y

	if not _initialized:
		_smoothed_yaw = target_yaw
		global_position = _chase_position(target_pos, _smoothed_yaw, distance, height)
		_look_at_world(target_pos + Vector3.UP * LOOK_AT_HEIGHT)
		_initialized = true
		return

	var yaw_t := _exp_weight(yaw_speed, delta)
	_smoothed_yaw = lerp_angle(_smoothed_yaw, target_yaw, yaw_t)

	var desired := _chase_position(target_pos, _smoothed_yaw, distance, height)
	var pos_t := _exp_weight(pos_smoothing, delta)
	global_position = global_position.lerp(desired, pos_t)
	_look_at_world(target_pos + Vector3.UP * LOOK_AT_HEIGHT)


func _update_rigged(
	delta: float,
	local_offset: Vector3,
	local_look: Vector3,
	pos_smoothing: float
) -> void:
	var xf := _target.global_transform
	var desired := xf * local_offset
	var look_point := xf * local_look

	if not _initialized:
		global_position = desired
		_look_at_world(look_point)
		_smoothed_yaw = _target.global_rotation.y
		_initialized = true
		return

	var pos_t := _exp_weight(pos_smoothing, delta)
	global_position = global_position.lerp(desired, pos_t)
	_look_at_world(look_point)


func _chase_position(target_pos: Vector3, yaw: float, distance: float, height: float) -> Vector3:
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	return target_pos + back * distance + Vector3.UP * height


func _look_at_world(look_point: Vector3) -> void:
	if look_point.distance_squared_to(global_position) < 0.0001:
		return
	look_at(look_point, Vector3.UP)


func _exp_weight(speed: float, delta: float) -> float:
	return 1.0 - exp(-maxf(speed, 0.0) * delta)


func _is_travel_mode() -> bool:
	if _target != null and _target.has_method("is_travel_mode"):
		return bool(_target.call("is_travel_mode"))
	return false


func _mode_label(m: CameraMode) -> String:
	match m:
		CameraMode.FAR:
			return "FAR"
		CameraMode.HOOD:
			return "HOOD"
		CameraMode.PASSENGER:
			return "PASSENGER"
		CameraMode.WINDOW:
			return "WINDOW"
		_:
			return "FOLLOW"
