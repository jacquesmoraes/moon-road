extends Node3D
class_name RoadsideExitSystem
## Places short lateral exits + fixed-pool detours off the main RoadManager road.
## Autopilot / Travel Mode keep using RoadManager.sample_road (main only).
## Manual driving can peel onto the detour collision. Node count is bounded.

signal exit_activated(exit_id: String, poi_name: String)
signal exit_deactivated(exit_id: String)
signal poi_reached(poi_id: String, poi_name: String)

@export var road_manager_path: NodePath = NodePath("../RoadManager")
@export var segment_scene: PackedScene
@export var target_path: NodePath = NodePath("../PlayerVehicle")
@export var definitions: Array[RoadsideExitDefinition] = []
## How close (m) the player must be to the POI marker to count as reached.
@export var poi_reach_distance: float = 8.0

var _road_manager: Node
var _target: Node3D
## exit_id → fixed runtime slot
var _slots: Dictionary = {}
var _bootstrapped: bool = false
var _last_recycle_seen: int = -1
var _reached_pois: Dictionary = {}


func _ready() -> void:
	_resolve_refs()
	call_deferred("_bootstrap")


func _physics_process(_delta: float) -> void:
	if not _bootstrapped:
		return
	_resolve_refs()
	_sync_exits_to_main_road()
	_check_poi_reach()


func get_active_exit_count() -> int:
	var n := 0
	for key in _slots.keys():
		var slot: Dictionary = _slots[key]
		if bool(slot.get("active", false)):
			n += 1
	return n


func get_total_node_budget() -> int:
	## Fixed upper bound: this root + per-slot (ramp + segments + poi).
	var n := 1
	for key in _slots.keys():
		var slot: Dictionary = _slots[key]
		n += 1  # ramp
		n += (slot.get("segments", []) as Array).size()
		n += 1  # poi marker
	return n


func get_detour_segment_count() -> int:
	var n := 0
	for key in _slots.keys():
		n += ( _slots[key].get("segments", []) as Array).size()
	return n


func is_exit_active(exit_id: String = "") -> bool:
	if exit_id.is_empty():
		return get_active_exit_count() > 0
	if not _slots.has(exit_id):
		return false
	return bool(_slots[exit_id].get("active", false))


func get_active_poi_name() -> String:
	for key in _slots.keys():
		var slot: Dictionary = _slots[key]
		if not bool(slot.get("active", false)):
			continue
		var def: RoadsideExitDefinition = slot.get("definition")
		if def != null and def.poi != null and not def.poi.display_name.is_empty():
			return def.poi.display_name
		if def != null:
			return def.exit_id
	return ""


func get_poi_global_position(exit_id: String = "") -> Vector3:
	for key in _slots.keys():
		if not exit_id.is_empty() and str(key) != exit_id:
			continue
		var slot: Dictionary = _slots[key]
		if not bool(slot.get("active", false)):
			continue
		var poi_node: Node3D = slot.get("poi_node")
		if poi_node != null and is_instance_valid(poi_node):
			return poi_node.global_position
	return Vector3.ZERO


func was_poi_reached(poi_id: String) -> bool:
	return bool(_reached_pois.get(poi_id, false))


func apply_origin_shift(offset: Vector3) -> void:
	if not offset.is_finite() or offset.length_squared() < 0.0001:
		return
	global_position -= offset


func _bootstrap() -> void:
	if segment_scene == null:
		push_error("RoadsideExitSystem: segment_scene is not set")
		return
	_resolve_refs()
	for def in definitions:
		if def == null or def.exit_id.is_empty():
			continue
		_slots[def.exit_id] = _create_slot(def)
	_bootstrapped = true
	_sync_exits_to_main_road()


func _create_slot(def: RoadsideExitDefinition) -> Dictionary:
	var count := maxi(def.detour_segment_count, 1)
	var segments: Array[Node3D] = []
	for i in count:
		var seg := segment_scene.instantiate() as Node3D
		seg.name = "%s_Detour_%d" % [def.exit_id, i]
		add_child(seg)
		if seg.has_method("set"):
			seg.set("length", def.detour_segment_length)
			seg.set("width", def.detour_width)
			seg.set("show_shoulders", true)
			seg.set("shoulder_width", 1.0)
		if seg.has_method("set_kind"):
			# First piece curves gently toward the exit side; rest stay straight.
			if i == 0:
				seg.call(
					"set_kind",
					1 if def.side == RoadsideExitDefinition.ExitSide.EXIT_LEFT else 2
				)
				if seg.get("curve_angle_degrees") != null:
					seg.set("curve_angle_degrees", 22.0)
			else:
				seg.call("set_kind", 0)
		if seg.has_method("set_elevation"):
			seg.call("set_elevation", 0)
		if seg.has_method("ensure_built"):
			seg.call("ensure_built")
		segments.append(seg)

	var ramp := _make_ramp_node("%s_Ramp" % def.exit_id)
	add_child(ramp)

	var poi_node := _make_poi_marker(def)
	add_child(poi_node)

	_park_slot_nodes(ramp, segments, poi_node)

	return {
		"definition": def,
		"segments": segments,
		"ramp": ramp,
		"poi_node": poi_node,
		"active": false,
		"host": null,
	}


func _make_ramp_node(node_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = node_name

	var body := StaticBody3D.new()
	body.name = "RampBody"
	root.add_child(body)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(7.0, 0.25, 12.0)
	col.shape = shape
	col.position = Vector3(0.0, -0.05, 0.0)
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(7.0, 0.18, 12.0)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.42, 0.22, 1)
	mesh.material_override = mat
	mesh.position = Vector3(0.0, 0.02, 0.0)
	root.add_child(mesh)

	return root


func _make_poi_marker(def: RoadsideExitDefinition) -> Node3D:
	var root := Node3D.new()
	root.name = "%s_POI" % def.exit_id

	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.35
	cyl.bottom_radius = 0.55
	cyl.height = 3.2
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.45, 0.15, 1)
	mesh.material_override = mat
	mesh.position = Vector3(0.0, 1.6, 0.0)
	root.add_child(mesh)

	var plaque := MeshInstance3D.new()
	var board := BoxMesh.new()
	board.size = Vector3(2.4, 1.0, 0.12)
	plaque.mesh = board
	var board_mat := StandardMaterial3D.new()
	board_mat.albedo_color = Color(0.15, 0.12, 0.1, 1)
	plaque.material_override = board_mat
	plaque.position = Vector3(0.0, 2.6, 0.0)
	root.add_child(plaque)

	return root


func _sync_exits_to_main_road() -> void:
	if _road_manager == null or not _road_manager.has_method("get_active_segments"):
		return

	var recycle := 0
	if _road_manager.has_method("get_recycle_count"):
		recycle = int(_road_manager.call("get_recycle_count"))
	var recycle_changed := recycle != _last_recycle_seen
	_last_recycle_seen = recycle

	var active_segments: Array = _road_manager.call("get_active_segments")
	for key in _slots.keys():
		var slot: Dictionary = _slots[key]
		var def: RoadsideExitDefinition = slot.get("definition")
		if def == null:
			continue
		var host := _find_host(active_segments, def.appear_at_sequence)
		if host != null:
			var prev_host: Node3D = slot.get("host")
			var needs_place := (
				not bool(slot.get("active", false))
				or prev_host != host
				or recycle_changed
			)
			slot["host"] = host
			slot["active"] = true
			if needs_place:
				_place_detour(slot, host)
				if prev_host != host or not bool(slot.get("emitted_active", false)):
					var poi_name := def.poi.display_name if def.poi != null else str(key)
					exit_activated.emit(str(key), poi_name)
					slot["emitted_active"] = true
		else:
			_deactivate_slot(str(key), slot)


func _find_host(active_segments: Array, sequence: int) -> Node3D:
	for seg in active_segments:
		if seg == null or not is_instance_valid(seg):
			continue
		if not (seg is Node3D):
			continue
		if (seg as Node3D).has_meta("road_sequence_index"):
			if int((seg as Node3D).get_meta("road_sequence_index")) == sequence:
				return seg as Node3D
	return null


func _deactivate_slot(exit_id: String, slot: Dictionary) -> void:
	if not bool(slot.get("active", false)):
		slot["host"] = null
		return
	slot["active"] = false
	slot["host"] = null
	slot["emitted_active"] = false
	var ramp: Node3D = slot.get("ramp")
	var segments: Array = slot.get("segments", [])
	var poi_node: Node3D = slot.get("poi_node")
	_park_slot_nodes(ramp, segments, poi_node)
	exit_deactivated.emit(exit_id)


func _place_detour(slot: Dictionary, host: Node3D) -> void:
	var def: RoadsideExitDefinition = slot.get("definition")
	var segments: Array = slot.get("segments", [])
	var ramp: Node3D = slot.get("ramp")
	var poi_node: Node3D = slot.get("poi_node")
	if def == null or segments.is_empty() or host == null:
		return
	if not host.has_method("sample_centerline"):
		return

	var sample: Dictionary = host.call("sample_centerline", clampf(def.along_t, 0.05, 0.95))
	var point: Vector3 = sample.get("point", host.global_position)
	var forward: Vector3 = sample.get("forward", Vector3.FORWARD)
	var right: Vector3 = sample.get("right", Vector3.RIGHT)
	forward.y = 0.0
	right.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	if right.length_squared() > 0.0001:
		right = right.normalized()

	var side_sign := -1.0 if def.side == RoadsideExitDefinition.ExitSide.EXIT_LEFT else 1.0
	var host_half := 5.0
	if host.has_method("get_width"):
		host_half = float(host.call("get_width")) * 0.5

	# Mouth sits at the roadway edge, slightly ahead so the ramp is approachable.
	var mouth := point + right * side_sign * (host_half + 0.4) + forward * 2.0
	mouth.y = point.y

	var peel := deg_to_rad(def.peel_angle_degrees) * side_sign
	var exit_forward := forward.rotated(Vector3.UP, peel)
	if exit_forward.length_squared() < 0.0001:
		exit_forward = right * side_sign
	exit_forward = exit_forward.normalized()

	var mouth_basis := _basis_looking_along(exit_forward)
	var mouth_xf := Transform3D(mouth_basis, mouth)

	# Ramp bridges main edge → first detour entrance.
	if ramp != null:
		ramp.visible = true
		_set_collision_enabled(ramp, true)
		var ramp_mid := mouth + exit_forward * 6.0 - right * side_sign * 0.5
		ramp_mid.y = mouth.y
		ramp.global_transform = Transform3D(mouth_basis, ramp_mid)

	var first: Node3D = segments[0]
	_set_segment_visible(first, true)
	if first.has_method("place_after_exit"):
		# place_after_exit expects previous Exit marker transform; synthesize entrance pose.
		first.call("place_after_exit", mouth_xf)
	else:
		first.global_transform = mouth_xf

	for i in range(1, segments.size()):
		var prev: Node3D = segments[i - 1]
		var seg: Node3D = segments[i]
		_set_segment_visible(seg, true)
		if seg.has_method("place_after_exit") and prev.has_method("get_exit_global_transform"):
			seg.call("place_after_exit", prev.call("get_exit_global_transform"))

	if poi_node != null:
		poi_node.visible = true
		var last: Node3D = segments[segments.size() - 1]
		if last.has_method("sample_centerline"):
			var end_sample: Dictionary = last.call("sample_centerline", 0.85)
			var poi_pos: Vector3 = end_sample.get("point", last.global_position)
			var poi_right: Vector3 = end_sample.get("right", Vector3.RIGHT)
			poi_pos += poi_right * side_sign * 3.5
			poi_pos.y = float(end_sample.get("point", last.global_position).y)
			poi_node.global_position = poi_pos
		else:
			poi_node.global_position = last.global_position + Vector3(side_sign * 4.0, 0.0, 0.0)


func _park_slot_nodes(ramp: Node3D, segments: Array, poi_node: Node3D) -> void:
	var park := Vector3(0.0, -500.0, 0.0)
	if ramp != null:
		ramp.visible = false
		_set_collision_enabled(ramp, false)
		ramp.global_position = park
	for seg in segments:
		if seg == null or not is_instance_valid(seg):
			continue
		_set_segment_visible(seg as Node3D, false)
		(seg as Node3D).global_position = park + Vector3(0.0, -10.0, float(segments.find(seg)) * 50.0)
	if poi_node != null:
		poi_node.visible = false
		poi_node.global_position = park


func _set_segment_visible(seg: Node3D, on: bool) -> void:
	seg.visible = on
	for child in seg.get_children():
		if child is CollisionObject3D:
			(child as CollisionObject3D).collision_layer = 1 if on else 0
			(child as CollisionObject3D).collision_mask = 1 if on else 0
		_set_collision_enabled(child, on)


func _set_collision_enabled(node: Node, on: bool) -> void:
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 1 if on else 0
		(node as CollisionObject3D).collision_mask = 1 if on else 0
	for child in node.get_children():
		_set_collision_enabled(child, on)


func _basis_looking_along(forward: Vector3) -> Basis:
	var f := forward
	f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	else:
		f = f.normalized()
	# Godot: local -Z is forward. Basis columns = X (right), Y (up), Z (-forward).
	var right := f.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := right.cross(f).normalized()
	return Basis(right, up, -f)


func _check_poi_reach() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	for key in _slots.keys():
		var slot: Dictionary = _slots[key]
		if not bool(slot.get("active", false)):
			continue
		var def: RoadsideExitDefinition = slot.get("definition")
		if def == null or def.poi == null:
			continue
		var poi_id := def.poi.poi_id
		if poi_id.is_empty() or bool(_reached_pois.get(poi_id, false)):
			continue
		var poi_node: Node3D = slot.get("poi_node")
		if poi_node == null:
			continue
		var d := _target.global_position.distance_to(poi_node.global_position)
		if d <= poi_reach_distance:
			_reached_pois[poi_id] = true
			poi_reached.emit(poi_id, def.poi.display_name)


func _resolve_refs() -> void:
	if road_manager_path != NodePath():
		_road_manager = get_node_or_null(road_manager_path)
	if _road_manager == null and get_tree() != null and get_tree().current_scene != null:
		_road_manager = get_tree().current_scene.find_child("RoadManager", true, false)

	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null and get_tree() != null and get_tree().current_scene != null:
		_target = get_tree().current_scene.find_child("PlayerVehicle", true, false) as Node3D
