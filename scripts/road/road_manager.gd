extends Node3D
class_name RoadManager
## Keeps a fixed pool of RoadSegments (straight + gentle curves) around the player.
## Recycles the rearmost segment to the front — no unbounded Node growth.

@export var target_path: NodePath = NodePath("../PlayerVehicle")
@export var segment_scene: PackedScene
@export var active_segment_count: int = 8
@export var segment_length: float = 40.0
## Recycle when the player has traveled this far past the rear segment mid-point.
@export var recycle_behind_distance: float = 80.0
@export var initial_first_center_z: float = 0.0
## First N segments stay straight so the sandbox spawn is predictable.
@export var start_straight_count: int = 2
@export var randomize_segment_kinds: bool = true
## Relative weights for random kinds after the opening straights.
@export var weight_straight: float = 0.45
@export var weight_gentle_left: float = 0.275
@export var weight_gentle_right: float = 0.275
@export var curve_angle_degrees: float = 18.0

var _target: Node3D
## Ordered rear → front along the road chain.
var _active: Array[Node3D] = []
var _recycle_count: int = 0
var _bootstrapped: bool = false
var _spawn_index: int = 0


func _ready() -> void:
	_resolve_target()
	call_deferred("_bootstrap")


func _physics_process(_delta: float) -> void:
	if not _bootstrapped:
		return
	if _target == null or not is_instance_valid(_target):
		_resolve_target()
		if _target == null:
			return
	_recycle_as_needed()


func get_active_segment_count() -> int:
	return _active.size()


func get_pool_node_count() -> int:
	return get_child_count()


func get_recycle_count() -> int:
	return _recycle_count


## Active segments ordered rear → front.
func get_active_segments() -> Array[Node3D]:
	return _active.duplicate()


## Kind name histogram for the active pool (smoke / debug).
func get_active_kind_counts() -> Dictionary:
	var counts := {"straight": 0, "gentle_left": 0, "gentle_right": 0}
	for seg in _active:
		if seg == null or not is_instance_valid(seg):
			continue
		var name := "straight"
		if seg.has_method("get_kind_name"):
			name = str(seg.call("get_kind_name"))
		if counts.has(name):
			counts[name] = int(counts[name]) + 1
		else:
			counts[name] = 1
	return counts


## Sample roadway near [param world_pos] with a look-ahead point along the centerline.
func sample_road(world_pos: Vector3, look_ahead_distance: float = 12.0) -> Dictionary:
	var best: Node3D = null
	var best_score := INF
	var best_proj: Dictionary = {}
	var best_idx := -1

	for i in _active.size():
		var seg: Node3D = _active[i]
		if seg == null or not is_instance_valid(seg):
			continue
		if not seg.has_method("project_on_centerline"):
			continue
		var proj: Dictionary = seg.call("project_on_centerline", world_pos)
		var lateral: float = absf(float(proj.get("lateral", 999.0)))
		var t: float = float(proj.get("t", 0.5))
		var along_penalty := 0.0 if (t >= 0.0 and t <= 1.0) else absf(t - clampf(t, 0.0, 1.0)) * 100.0
		var score := lateral + along_penalty
		if score < best_score:
			best_score = score
			best = seg
			best_proj = proj
			best_idx = i

	if best == null:
		return {}

	var forward: Vector3 = best_proj.get("forward", Vector3.FORWARD)
	var point: Vector3 = best_proj.get("point", world_pos)
	var look := _look_ahead_from(best_idx, float(best_proj.get("t", 0.0)), maxf(look_ahead_distance, 0.0))
	if not look.is_empty():
		forward = look.get("forward", forward)
		var look_at: Vector3 = look.get("point", point + forward * look_ahead_distance)
		return {
			"segment": best,
			"point": point,
			"lateral": float(best_proj.get("lateral", 0.0)),
			"forward": forward,
			"look_at": look_at,
			"t": float(best_proj.get("t", 0.0)),
			"kind": best.call("get_kind_name") if best.has_method("get_kind_name") else "straight",
		}

	return {
		"segment": best,
		"point": point,
		"lateral": float(best_proj.get("lateral", 0.0)),
		"forward": forward,
		"look_at": point + forward * look_ahead_distance,
		"t": float(best_proj.get("t", 0.0)),
		"kind": best.call("get_kind_name") if best.has_method("get_kind_name") else "straight",
	}


## Shift all pooled segments by -[param offset] (world origin recentering).
func apply_origin_shift(offset: Vector3) -> void:
	if not offset.is_finite() or offset.length_squared() < 0.0001:
		return
	for child in get_children():
		if child is Node3D:
			(child as Node3D).global_position -= offset


func _look_ahead_from(seg_idx: int, t: float, look_ahead: float) -> Dictionary:
	if seg_idx < 0 or seg_idx >= _active.size():
		return {}
	var remaining := look_ahead
	var idx := seg_idx
	var local_t := clampf(t, 0.0, 1.0)

	while remaining > 0.0 and idx < _active.size():
		var seg: Node3D = _active[idx]
		var seg_len := segment_length
		if seg.has_method("get_length"):
			seg_len = float(seg.call("get_length"))
		var dist_on_seg := local_t * seg_len
		var left_on_seg := seg_len - dist_on_seg
		if remaining <= left_on_seg or idx == _active.size() - 1:
			if seg.has_method("sample_at_distance"):
				return seg.call("sample_at_distance", dist_on_seg + minf(remaining, left_on_seg))
			break
		remaining -= left_on_seg
		idx += 1
		local_t = 0.0

	var last: Node3D = _active[_active.size() - 1]
	if last.has_method("sample_centerline"):
		return last.call("sample_centerline", 1.0)
	return {}


func _resolve_target() -> void:
	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null and get_tree().current_scene != null:
		_target = get_tree().current_scene.find_child("PlayerVehicle", true, false) as Node3D


func _bootstrap() -> void:
	if segment_scene == null:
		push_error("RoadManager: segment_scene is not set")
		return

	for child in get_children():
		child.queue_free()
	_active.clear()
	_recycle_count = 0
	_spawn_index = 0

	var count := maxi(active_segment_count, 2)
	for i in count:
		var seg := _spawn_segment()
		_configure_segment(seg, _spawn_index)
		_spawn_index += 1
		if i == 0:
			seg.global_position = Vector3(0.0, 0.0, initial_first_center_z)
		else:
			var prev: Node3D = _active[i - 1]
			_place_after(seg, prev)
		_active.append(seg)

	_bootstrapped = true


func _spawn_segment() -> Node3D:
	var seg := segment_scene.instantiate() as Node3D
	add_child(seg)
	return seg


func _configure_segment(segment: Node3D, sequence_index: int) -> void:
	if segment.has_method("set") and segment_length > 0.0:
		segment.set("length", segment_length)
	if segment.get("curve_angle_degrees") != null:
		segment.set("curve_angle_degrees", curve_angle_degrees)

	var kind_value := 0  # STRAIGHT
	if sequence_index >= start_straight_count and randomize_segment_kinds:
		kind_value = _pick_random_kind()
	if segment.has_method("set_kind"):
		segment.call("set_kind", kind_value)
	elif segment.get("kind") != null:
		segment.set("kind", kind_value)

	# Markers must match kind before place_after_exit (bootstrap may run pre-_ready).
	if segment.has_method("ensure_built"):
		segment.call("ensure_built")


func _pick_random_kind() -> int:
	var w_s := maxf(weight_straight, 0.0)
	var w_l := maxf(weight_gentle_left, 0.0)
	var w_r := maxf(weight_gentle_right, 0.0)
	var total := w_s + w_l + w_r
	if total <= 0.0001:
		return 0
	var r := randf() * total
	if r < w_s:
		return 0  # STRAIGHT
	r -= w_s
	if r < w_l:
		return 1  # GENTLE_LEFT
	return 2  # GENTLE_RIGHT


func _place_after(segment: Node3D, previous: Node3D) -> void:
	if segment.has_method("place_after_exit") and previous.has_method("get_exit_global_transform"):
		segment.call("place_after_exit", previous.call("get_exit_global_transform"))
		return
	var length := segment_length
	if previous.has_method("get_length"):
		length = float(previous.call("get_length"))
	segment.global_position = previous.global_position + Vector3(0.0, 0.0, -length)


func _recycle_as_needed() -> void:
	var guard := 0
	while _active.size() >= 2 and guard < _active.size():
		guard += 1
		var rear: Node3D = _active[0]
		if not _is_rear_far_behind(rear):
			break

		var front: Node3D = _active[_active.size() - 1]
		_active.remove_at(0)
		_configure_segment(rear, _spawn_index)
		_spawn_index += 1
		_place_after(rear, front)
		_active.append(rear)
		_recycle_count += 1


func _is_rear_far_behind(rear: Node3D) -> bool:
	## Player has traveled this far past the rear segment along its local centerline.
	if rear.has_method("sample_centerline"):
		var mid: Dictionary = rear.call("sample_centerline", 0.5)
		var forward: Vector3 = mid.get("forward", Vector3.FORWARD)
		var mid_point: Vector3 = mid.get("point", rear.global_position)
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			forward = forward.normalized()
			var behind := (_target.global_position - mid_point).dot(forward)
			return behind >= recycle_behind_distance

	# Fallback for pre-curve segments: world +Z behind while traveling -Z.
	var behind_z := rear.global_position.z - _target.global_position.z
	return behind_z >= recycle_behind_distance
