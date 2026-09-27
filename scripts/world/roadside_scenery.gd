extends Node3D
class_name RoadsideScenery
## Fixed-pool procedural roadside props. Decorates RoadSegments; recycles with them.
## Deterministic per (world_seed, sequence_index). Never places on the roadway.

enum PropType {
	ROCK,
	POST,
	SIGN,
	MOUNTAIN,
}

@export var road_manager_path: NodePath = NodePath("../RoadManager")
@export var enabled: bool = true
## Global seed mixed with each segment's sequence index for deterministic layouts.
@export var world_seed: int = 4804

@export_group("Density (per segment)")
@export var rocks_per_segment: int = 4
@export var posts_per_segment: int = 3
@export var signs_per_segment: int = 1
@export var mountains_per_segment: int = 1
## Chance [0..1] to place each mountain slot (still pooled).
@export var mountain_chance: float = 0.55

@export_group("Placement")
## Clearance beyond road half-width + shoulders before near props can spawn.
@export var roadside_clearance: float = 2.5
@export var near_lateral_min: float = 8.0
@export var near_lateral_max: float = 22.0
@export var mountain_lateral_min: float = 45.0
@export var mountain_lateral_max: float = 110.0
@export var along_margin: float = 0.12

var _road_manager: Node
var _pool_root: Node3D
var _rock_pool: Array[Node3D] = []
var _post_pool: Array[Node3D] = []
var _sign_pool: Array[Node3D] = []
var _mountain_pool: Array[Node3D] = []
## segment instance_id → props currently attached
var _segment_props: Dictionary = {}
var _bootstrapped: bool = false
var _decorate_count: int = 0


func _ready() -> void:
	_pool_root = Node3D.new()
	_pool_root.name = "PropPool"
	add_child(_pool_root)
	call_deferred("_bootstrap_with_manager")


func get_total_prop_count() -> int:
	return (
		_rock_pool.size()
		+ _post_pool.size()
		+ _sign_pool.size()
		+ _mountain_pool.size()
	)


func get_active_prop_count() -> int:
	var n := 0
	for key in _segment_props.keys():
		n += (_segment_props[key] as Array).size()
	return n


func get_pool_child_count() -> int:
	return _pool_root.get_child_count() if _pool_root else 0


func get_decorate_count() -> int:
	return _decorate_count


func get_node_budget() -> int:
	## Fixed upper bound across pool + active props (props may be reparented onto segments).
	var n := 2  # this node + PropPool
	for pool in [_rock_pool, _post_pool, _sign_pool, _mountain_pool]:
		for prop in pool:
			if prop != null and is_instance_valid(prop):
				n += 1 + _count_descendants(prop)
	return n


func clear_segment(segment: Node3D) -> void:
	if segment == null:
		return
	var id := segment.get_instance_id()
	if not _segment_props.has(id):
		_strip_anchor(segment)
		return
	var props: Array = _segment_props[id]
	for prop in props:
		if prop != null and is_instance_valid(prop):
			_return_to_pool(prop)
	_segment_props.erase(id)
	_strip_anchor(segment)


func decorate_segment(segment: Node3D, sequence_index: int) -> void:
	if not enabled or segment == null or not is_instance_valid(segment):
		return
	_ensure_pools()
	clear_segment(segment)

	var rng := RandomNumberGenerator.new()
	rng.seed = _mix_seed(world_seed, sequence_index)

	var road_half := 5.0
	var shoulder := 1.5
	if segment.has_method("get_width"):
		road_half = float(segment.call("get_width")) * 0.5
	if segment.get("shoulder_width") != null:
		shoulder = float(segment.get("shoulder_width"))
	var min_lateral := road_half + shoulder + roadside_clearance
	var near_min := maxf(near_lateral_min, min_lateral)
	var near_max := maxf(near_lateral_max, near_min + 0.5)

	var anchor := _ensure_anchor(segment)
	var attached: Array[Node3D] = []

	for _i in rocks_per_segment:
		var prop := _take_prop(_rock_pool)
		if prop == null:
			break
		_place_near(prop, segment, anchor, rng, near_min, near_max)
		attached.append(prop)

	for _i in posts_per_segment:
		var prop := _take_prop(_post_pool)
		if prop == null:
			break
		_place_near(prop, segment, anchor, rng, near_min, near_max)
		attached.append(prop)

	for _i in signs_per_segment:
		var prop := _take_prop(_sign_pool)
		if prop == null:
			break
		_place_near(prop, segment, anchor, rng, near_min, minf(near_max, near_min + 6.0))
		attached.append(prop)

	for _i in mountains_per_segment:
		if rng.randf() > mountain_chance:
			continue
		var prop := _take_prop(_mountain_pool)
		if prop == null:
			break
		_place_far(prop, segment, anchor, rng)
		attached.append(prop)

	_segment_props[segment.get_instance_id()] = attached
	_decorate_count += 1


func _bootstrap_with_manager() -> void:
	_resolve_manager()
	_ensure_pools()
	_bootstrapped = true
	# RoadManager owns decorate/clear calls on place + recycle.


func _resolve_manager() -> void:
	if road_manager_path != NodePath():
		_road_manager = get_node_or_null(road_manager_path)
	if _road_manager == null and get_tree().current_scene != null:
		_road_manager = get_tree().current_scene.find_child("RoadManager", true, false)


func _ensure_pools() -> void:
	if not _rock_pool.is_empty():
		return
	var segments := 8
	if _road_manager != null and _road_manager.get("active_segment_count") != null:
		segments = maxi(int(_road_manager.get("active_segment_count")), 2)

	_fill_pool(_rock_pool, PropType.ROCK, segments * maxi(rocks_per_segment, 0), "Rock")
	_fill_pool(_post_pool, PropType.POST, segments * maxi(posts_per_segment, 0), "Post")
	_fill_pool(_sign_pool, PropType.SIGN, segments * maxi(signs_per_segment, 0), "Sign")
	_fill_pool(_mountain_pool, PropType.MOUNTAIN, segments * maxi(mountains_per_segment, 0), "Mountain")


func _fill_pool(pool: Array[Node3D], type: PropType, count: int, prefix: String) -> void:
	for i in count:
		var prop := _make_prop(type)
		prop.name = "%s_%d" % [prefix, i]
		prop.visible = false
		_pool_root.add_child(prop)
		pool.append(prop)


func _make_prop(type: PropType) -> Node3D:
	var root := Node3D.new()
	root.set_meta("prop_type", type)
	match type:
		PropType.ROCK:
			_add_mesh(root, _box_mesh(Vector3(1.4, 0.9, 1.1)), Color(0.42, 0.38, 0.34), Vector3(0, 0.45, 0))
			_add_mesh(root, _box_mesh(Vector3(0.8, 0.55, 0.7)), Color(0.35, 0.32, 0.3), Vector3(0.45, 0.28, 0.15))
		PropType.POST:
			_add_mesh(root, _cyl_mesh(0.08, 1.6), Color(0.55, 0.4, 0.22), Vector3(0, 0.8, 0))
		PropType.SIGN:
			_add_mesh(root, _cyl_mesh(0.06, 2.0), Color(0.5, 0.5, 0.48), Vector3(0, 1.0, 0))
			_add_mesh(root, _box_mesh(Vector3(1.2, 0.7, 0.08)), Color(0.75, 0.55, 0.2), Vector3(0, 1.85, 0))
		PropType.MOUNTAIN:
			_add_mesh(root, _prism_approx(18.0, 28.0), Color(0.32, 0.36, 0.34), Vector3(0, 0, 0))
			_add_mesh(root, _prism_approx(10.0, 16.0), Color(0.4, 0.42, 0.4), Vector3(6.0, 0, -4.0))
	return root


func _box_mesh(size: Vector3) -> Mesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _cyl_mesh(radius: float, height: float) -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = 8
	return m


func _prism_approx(base: float, height: float) -> Mesh:
	## Placeholder "mountain": tall tapered box (no final art).
	var m := BoxMesh.new()
	m.size = Vector3(base, height, base * 0.85)
	return m


func _add_mesh(parent: Node3D, mesh: Mesh, color: Color, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mi.material_override = mat
	parent.add_child(mi)


func _take_prop(pool: Array[Node3D]) -> Node3D:
	for prop in pool:
		if prop.get_parent() == _pool_root:
			return prop
	return null


func _return_to_pool(prop: Node3D) -> void:
	if prop.get_parent() != null:
		prop.get_parent().remove_child(prop)
	_pool_root.add_child(prop)
	prop.visible = false
	prop.transform = Transform3D.IDENTITY


func _ensure_anchor(segment: Node3D) -> Node3D:
	var anchor := segment.get_node_or_null("SceneryAnchor") as Node3D
	if anchor == null:
		anchor = Node3D.new()
		anchor.name = "SceneryAnchor"
		segment.add_child(anchor)
	return anchor


func _strip_anchor(segment: Node3D) -> void:
	var anchor := segment.get_node_or_null("SceneryAnchor")
	if anchor == null:
		return
	for child in anchor.get_children():
		if child is Node3D:
			_return_to_pool(child as Node3D)


func _place_near(
	prop: Node3D,
	segment: Node3D,
	anchor: Node3D,
	rng: RandomNumberGenerator,
	lat_min: float,
	lat_max: float
) -> void:
	var t := rng.randf_range(along_margin, 1.0 - along_margin)
	var side := -1.0 if rng.randf() < 0.5 else 1.0
	var lateral := side * rng.randf_range(lat_min, lat_max)
	var yaw_jitter := rng.randf_range(-0.4, 0.4)
	var scale := rng.randf_range(0.75, 1.35)
	_attach_at(prop, segment, anchor, t, lateral, yaw_jitter, scale)


func _place_far(
	prop: Node3D,
	segment: Node3D,
	anchor: Node3D,
	rng: RandomNumberGenerator
) -> void:
	var t := rng.randf_range(0.15, 0.85)
	var side := -1.0 if rng.randf() < 0.5 else 1.0
	var lateral := side * rng.randf_range(mountain_lateral_min, mountain_lateral_max)
	var yaw_jitter := rng.randf_range(-0.2, 0.2)
	var scale := rng.randf_range(0.85, 1.4)
	_attach_at(prop, segment, anchor, t, lateral, yaw_jitter, scale)


func _attach_at(
	prop: Node3D,
	segment: Node3D,
	anchor: Node3D,
	t: float,
	lateral: float,
	yaw_jitter: float,
	uniform_scale: float
) -> void:
	if not segment.has_method("sample_centerline"):
		return
	var sample: Dictionary = segment.call("sample_centerline", t)
	var point: Vector3 = sample.get("point", segment.global_position)
	var right: Vector3 = sample.get("right", Vector3.RIGHT)
	right.y = 0.0
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var forward: Vector3 = sample.get("forward", Vector3.FORWARD)
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()

	# Stay off the roadway: lateral already includes clearance beyond shoulders.
	var world_pos := point + right * lateral
	# Sit on approximate ground at road height (placeholders; no terrain collider).
	world_pos.y = point.y

	if prop.get_parent() != null:
		prop.get_parent().remove_child(prop)
	anchor.add_child(prop)
	prop.global_position = world_pos
	# Face roughly along the road with jitter.
	var basis := Basis.looking_at(forward, Vector3.UP)
	prop.global_transform = Transform3D(basis.rotated(Vector3.UP, yaw_jitter), world_pos)
	prop.scale = Vector3.ONE * uniform_scale
	prop.visible = true

	# Final safety: if somehow inside roadway band, shove outward.
	var road_half := 5.0
	if segment.has_method("get_width"):
		road_half = float(segment.call("get_width")) * 0.5
	var shoulder := 1.5
	if segment.get("shoulder_width") != null:
		shoulder = float(segment.get("shoulder_width"))
	var min_lat := road_half + shoulder + roadside_clearance
	var proj: Dictionary = segment.call("project_on_centerline", prop.global_position)
	var lat_now := float(proj.get("lateral", 0.0))
	if absf(lat_now) < min_lat:
		var push := signf(lat_now) if absf(lat_now) > 0.01 else (1.0 if lateral >= 0.0 else -1.0)
		prop.global_position = point + right * (push * min_lat)


func _mix_seed(base: int, sequence_index: int) -> int:
	## Stable mix — same segment index always yields the same decoration layout.
	var x := base * 374761393 + sequence_index * 668265263
	x = (x ^ (x >> 13)) * 1274126177
	return x


func _count_descendants(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		n += 1 + _count_descendants(child)
	return n
