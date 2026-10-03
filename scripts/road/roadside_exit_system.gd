extends Node3D
class_name RoadsideExitSystem
## Places short lateral exits + fixed-pool detours off the main RoadManager road.
## Spawns explorável ViewpointPOI scenes via POISystem at detour ends.
## Autopilot / Travel Mode keep using RoadManager.sample_road (main only).

signal exit_activated(exit_id: String, poi_name: String)
signal exit_deactivated(exit_id: String)
signal poi_reached(poi_id: String, poi_name: String)

@export var road_manager_path: NodePath = NodePath("../RoadManager")
@export var segment_scene: PackedScene
@export var target_path: NodePath = NodePath("../PlayerVehicle")
@export var definitions: Array[RoadsideExitDefinition] = []
@export var viewpoint_scene: PackedScene

var _road_manager: Node
var _target: Node3D
var _poi_system: Node
## exit_id → fixed runtime slot
var _slots: Dictionary = {}
var _bootstrapped: bool = false
var _last_recycle_seen: int = -1


func _ready() -> void:
	_resolve_refs()
	call_deferred("_bootstrap")


func _physics_process(_delta: float) -> void:
	if not _bootstrapped:
		return
	_resolve_refs()
	_sync_exits_to_main_road()


func get_active_exit_count() -> int:
	var n := 0
	for key in _slots.keys():
		if bool(_slots[key].get("active", false)):
			n += 1
	return n


func get_total_node_budget() -> int:
	var n := 1
	for key in _slots.keys():
		var slot: Dictionary = _slots[key]
		n += 1
		n += (slot.get("segments", []) as Array).size()
	if _poi_system != null and _poi_system.has_method("get_active_viewpoint_count"):
		n += int(_poi_system.call("get_active_viewpoint_count"))
	return n


func get_detour_segment_count() -> int:
	var n := 0
	for key in _slots.keys():
		n += (_slots[key].get("segments", []) as Array).size()
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
		var def: RoadsideExitDefinition = slot.get("definition")
		if def != null and def.poi != null and _poi_system != null:
			var vp: Node3D = _poi_system.call("get_active_viewpoint", def.poi.poi_id)
			if vp != null:
				if vp.has_method("get_car_area_global_position"):
					return vp.call("get_car_area_global_position")
				return vp.global_position
	return Vector3.ZERO


func was_poi_reached(poi_id: String) -> bool:
	if _poi_system != null and _poi_system.has_method("is_discovered"):
		return bool(_poi_system.call("is_discovered", poi_id))
	return false


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
			seg.call("set_kind", 0)
		if seg.has_method("set_elevation"):
			seg.call("set_elevation", 0)
		if seg.has_method("ensure_built"):
			seg.call("ensure_built")
		segments.append(seg)

	var ramp := _make_ramp_node("%s_Ramp" % def.exit_id)
	add_child(ramp)
	_park_slot_nodes(ramp, segments)

	return {
		"definition": def,
		"segments": segments,
		"ramp": ramp,
		"active": false,
		"host": null,
	}


func _make_ramp_node(node_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(5.5, 0.12, 10.0)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.42, 0.22, 1)
	mesh.material_override = mat
	mesh.position = Vector3(0.0, 0.04, 0.0)
	root.add_child(mesh)
	return root


func _sync_exits_to_main_road() -> void:
	if _road_manager == null or not _road_manager.has_method("get_active_segments"):
		return

	if _road_manager.has_method("get_recycle_count"):
		_last_recycle_seen = int(_road_manager.call("get_recycle_count"))

	var active_segments: Array = _road_manager.call("get_active_segments")
	for key in _slots.keys():
		var slot: Dictionary = _slots[key]
		var def: RoadsideExitDefinition = slot.get("definition")
		if def == null:
			continue
		var host := _find_host(active_segments, def.appear_at_sequence)
		if host != null:
			var prev_host: Node3D = slot.get("host")
			var needs_place := not bool(slot.get("active", false)) or prev_host != host
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
		if seg == null or not is_instance_valid(seg) or not (seg is Node3D):
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
	_park_slot_nodes(slot.get("ramp"), slot.get("segments", []))
	var def: RoadsideExitDefinition = slot.get("definition")
	if def != null and def.poi != null and _poi_system != null:
		_poi_system.call("despawn_viewpoint", def.poi.poi_id)
	exit_deactivated.emit(exit_id)


func _place_detour(slot: Dictionary, host: Node3D) -> void:
	var def: RoadsideExitDefinition = slot.get("definition")
	var segments: Array = slot.get("segments", [])
	var ramp: Node3D = slot.get("ramp")
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

	var mouth := point + right * side_sign * (host_half + 4.0) + forward * 1.0
	mouth.y = point.y

	var peel := deg_to_rad(def.peel_angle_degrees) * side_sign
	var exit_forward := forward.rotated(Vector3.UP, peel)
	if exit_forward.length_squared() < 0.0001:
		exit_forward = right * side_sign
	exit_forward = exit_forward.normalized()

	var mouth_basis := _basis_looking_along(exit_forward)
	var mouth_xf := Transform3D(mouth_basis, mouth)

	if ramp != null:
		ramp.visible = true
		var ramp_mid := point + right * side_sign * (host_half + 2.0) + forward * 1.0 + exit_forward * 4.0
		ramp_mid.y = mouth.y
		ramp.global_transform = Transform3D(mouth_basis, ramp_mid)

	var first: Node3D = segments[0]
	_set_segment_visible(first, true)
	if first.has_method("place_after_exit"):
		first.call("place_after_exit", mouth_xf)
	else:
		first.global_transform = mouth_xf

	for i in range(1, segments.size()):
		var prev: Node3D = segments[i - 1]
		var seg: Node3D = segments[i]
		_set_segment_visible(seg, true)
		if seg.has_method("place_after_exit") and prev.has_method("get_exit_global_transform"):
			seg.call("place_after_exit", prev.call("get_exit_global_transform"))

	_spawn_viewpoint_at_detour_end(slot, side_sign)


func _spawn_viewpoint_at_detour_end(slot: Dictionary, side_sign: float) -> void:
	var def: RoadsideExitDefinition = slot.get("definition")
	var segments: Array = slot.get("segments", [])
	if def == null or def.poi == null or segments.is_empty() or _poi_system == null:
		return
	var last: Node3D = segments[segments.size() - 1]
	var basis := last.global_transform.basis
	var pos := last.global_position
	if last.has_method("sample_centerline"):
		var end_sample: Dictionary = last.call("sample_centerline", 0.92)
		pos = end_sample.get("point", pos)
		var fwd: Vector3 = end_sample.get("forward", -last.global_transform.basis.z)
		fwd.y = 0.0
		if fwd.length_squared() > 0.0001:
			basis = _basis_looking_along(fwd.normalized())
		var end_right: Vector3 = end_sample.get("right", Vector3.RIGHT)
		pos += end_right * side_sign * 2.0
	var xf := Transform3D(basis, pos)
	var scene := viewpoint_scene
	if scene == null and def.poi.viewpoint_scene != null:
		scene = def.poi.viewpoint_scene
	var vp: Node3D = _poi_system.call("spawn_viewpoint", def.poi, xf, self, scene)
	if vp != null and not vp.has_meta("exit_poi_signal_hooked"):
		vp.set_meta("exit_poi_signal_hooked", true)
		# Forward first-time discovery for listeners that still use poi_reached.
		var sys := _poi_system
		if sys != null and sys.has_signal("discovered_poi"):
			if not sys.discovered_poi.is_connected(_on_poi_discovered):
				sys.discovered_poi.connect(_on_poi_discovered)


func _on_poi_discovered(poi_id: String, display_name: String) -> void:
	poi_reached.emit(poi_id, display_name)


func _park_slot_nodes(ramp: Node3D, segments: Array) -> void:
	var park := Vector3(0.0, -800.0, 0.0)
	if ramp != null:
		ramp.visible = false
		_disable_collision_tree(ramp)
		ramp.global_position = park
	for i in segments.size():
		var seg: Node3D = segments[i]
		if seg == null or not is_instance_valid(seg):
			continue
		seg.visible = false
		_disable_collision_tree(seg)
		seg.global_position = park + Vector3(float(i) * 80.0, -20.0, 0.0)


func _set_segment_visible(seg: Node3D, on: bool) -> void:
	seg.visible = on
	if on:
		_enable_collision_tree(seg)
	else:
		_disable_collision_tree(seg)


func _disable_collision_tree(node: Node) -> void:
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 0
		(node as CollisionObject3D).collision_mask = 0
	for child in node.get_children():
		_disable_collision_tree(child)


func _enable_collision_tree(node: Node) -> void:
	if node is CollisionObject3D:
		(node as CollisionObject3D).collision_layer = 1
		(node as CollisionObject3D).collision_mask = 1
	for child in node.get_children():
		_enable_collision_tree(child)


func _basis_looking_along(forward: Vector3) -> Basis:
	var f := forward
	f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	else:
		f = f.normalized()
	var right := f.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := right.cross(f).normalized()
	return Basis(right, up, -f)


func _resolve_refs() -> void:
	if road_manager_path != NodePath():
		_road_manager = get_node_or_null(road_manager_path)
	if _road_manager == null and get_tree() != null and get_tree().current_scene != null:
		_road_manager = get_tree().current_scene.find_child("RoadManager", true, false)

	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null and get_tree() != null and get_tree().current_scene != null:
		_target = get_tree().current_scene.find_child("PlayerVehicle", true, false) as Node3D

	_poi_system = get_node_or_null("/root/POISystem")
