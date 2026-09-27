extends Node3D
class_name RoadManager
## Keeps a fixed pool of straight RoadSegments around the player. Recycles the
## rearmost segment to the front — no unbounded Node growth. No UI / Journey deps.

@export var target_path: NodePath = NodePath("../PlayerVehicle")
@export var segment_scene: PackedScene
@export var active_segment_count: int = 8
@export var segment_length: float = 40.0
## Recycle when a segment's center is this many meters behind the player (along +Z vs travel -Z).
@export var recycle_behind_distance: float = 80.0
@export var initial_first_center_z: float = 0.0

var _target: Node3D
## Ordered rear → front (decreasing world Z while traveling toward -Z).
var _active: Array[Node3D] = []
var _recycle_count: int = 0
var _bootstrapped: bool = false


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


## Shift all pooled segments by -[param offset] (world origin recentering).
func apply_origin_shift(offset: Vector3) -> void:
	if not offset.is_finite() or offset.length_squared() < 0.0001:
		return
	for child in get_children():
		if child is Node3D:
			(child as Node3D).global_position -= offset


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

	var count := maxi(active_segment_count, 2)
	for i in count:
		var seg := _spawn_segment()
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
	if seg.has_method("set") and segment_length > 0.0:
		seg.set("length", segment_length)
	return seg


func _place_after(segment: Node3D, previous: Node3D) -> void:
	if segment.has_method("place_after_exit") and previous.has_method("get_exit_global_transform"):
		segment.call("place_after_exit", previous.call("get_exit_global_transform"))
		return
	var length := segment_length
	if previous.has_method("get_length"):
		length = float(previous.call("get_length"))
	segment.global_position = previous.global_position + Vector3(0.0, 0.0, -length)


func _recycle_as_needed() -> void:
	## Move rear segments to the front while they remain far behind the player.
	var guard := 0
	while _active.size() >= 2 and guard < _active.size():
		guard += 1
		var rear: Node3D = _active[0]
		var behind := rear.global_position.z - _target.global_position.z
		if behind < recycle_behind_distance:
			break

		var front: Node3D = _active[_active.size() - 1]
		_active.remove_at(0)
		_place_after(rear, front)
		_active.append(rear)
		_recycle_count += 1
