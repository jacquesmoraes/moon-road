extends Node3D
class_name RoadSegment
## Modular road piece: straight/gentle curve × level/climb/descent.
## Local travel starts toward -Z at Entrance; Exit carries end heading + pitch for chaining.

enum Kind {
	STRAIGHT,
	GENTLE_LEFT,
	GENTLE_RIGHT,
}

enum Elevation {
	LEVEL,
	GENTLE_CLIMB,
	GENTLE_DESCENT,
}

@export var kind: Kind = Kind.STRAIGHT:
	set(value):
		kind = value
		if is_node_ready():
			_apply_dimensions()

@export var elevation: Elevation = Elevation.LEVEL:
	set(value):
		elevation = value
		if is_node_ready():
			_apply_dimensions()

@export var length: float = 40.0:
	set(value):
		length = maxf(value, 1.0)
		if is_node_ready():
			_apply_dimensions()

@export var width: float = 10.0:
	set(value):
		width = maxf(value, 1.0)
		if is_node_ready():
			_apply_dimensions()

@export var thickness: float = 0.2:
	set(value):
		thickness = maxf(value, 0.05)
		if is_node_ready():
			_apply_dimensions()

@export var shoulder_width: float = 1.5:
	set(value):
		shoulder_width = maxf(value, 0.0)
		if is_node_ready():
			_apply_dimensions()

@export var show_shoulders: bool = true:
	set(value):
		show_shoulders = value
		if is_node_ready():
			_apply_dimensions()

## Total yaw change (degrees) for gentle curves. Kept mild on purpose.
@export var curve_angle_degrees: float = 18.0:
	set(value):
		curve_angle_degrees = clampf(value, 1.0, 35.0)
		if is_node_ready():
			_apply_dimensions()

## Constant grade (degrees) for climb/descent. Kept mild — no jumps or steep ramps.
@export var elevation_angle_degrees: float = 5.0:
	set(value):
		elevation_angle_degrees = clampf(value, 0.5, 10.0)
		if is_node_ready():
			_apply_dimensions()

@export var curve_subdivisions: int = 12:
	set(value):
		curve_subdivisions = clampi(value, 4, 32)
		if is_node_ready():
			_apply_dimensions()

@onready var _road_mesh: MeshInstance3D = $Roadway/MeshInstance3D
@onready var _road_collision: CollisionShape3D = $Roadway/CollisionShape3D
@onready var _roadway_body: StaticBody3D = $Roadway
@onready var _shoulder_left: MeshInstance3D = $Shoulders/Left
@onready var _shoulder_right: MeshInstance3D = $Shoulders/Right
@onready var _shoulder_left_body: StaticBody3D = $Shoulders/LeftBody
@onready var _shoulder_right_body: StaticBody3D = $Shoulders/RightBody
@onready var _shoulder_left_collision: CollisionShape3D = $Shoulders/LeftBody/CollisionShape3D
@onready var _shoulder_right_collision: CollisionShape3D = $Shoulders/RightBody/CollisionShape3D
@onready var entrance: Marker3D = $Entrance
@onready var exit: Marker3D = $Exit

## Local-space centerline samples: {pos: Vector3, yaw: float, pitch: float}
var _samples: Array[Dictionary] = []


func _ready() -> void:
	_apply_dimensions()


## Rebuild mesh/markers now (safe before _ready finishes). Call before place_after_exit.
func ensure_built() -> void:
	_apply_dimensions()


func get_length() -> float:
	return length


func get_width() -> float:
	return width


func get_kind() -> Kind:
	return kind


func get_kind_name() -> String:
	match kind:
		Kind.GENTLE_LEFT:
			return "gentle_left"
		Kind.GENTLE_RIGHT:
			return "gentle_right"
		_:
			return "straight"


func get_elevation() -> Elevation:
	return elevation


func get_elevation_name() -> String:
	match elevation:
		Elevation.GENTLE_CLIMB:
			return "gentle_climb"
		Elevation.GENTLE_DESCENT:
			return "gentle_descent"
		_:
			return "level"


func is_curved() -> bool:
	return kind != Kind.STRAIGHT


func is_sloped() -> bool:
	return elevation != Elevation.LEVEL


func get_turn_angle() -> float:
	match kind:
		Kind.GENTLE_LEFT:
			return deg_to_rad(curve_angle_degrees)
		Kind.GENTLE_RIGHT:
			return deg_to_rad(-curve_angle_degrees)
		_:
			return 0.0


func get_elevation_angle() -> float:
	match elevation:
		Elevation.GENTLE_CLIMB:
			return deg_to_rad(elevation_angle_degrees)
		Elevation.GENTLE_DESCENT:
			return deg_to_rad(-elevation_angle_degrees)
		_:
			return 0.0


func get_entrance_global_transform() -> Transform3D:
	return entrance.global_transform


func get_exit_global_transform() -> Transform3D:
	return exit.global_transform


## World-space travel direction at segment mid (planar, for recycle / steering helpers).
func get_travel_direction() -> Vector3:
	var sample := sample_centerline(0.5)
	var forward: Vector3 = sample.get("forward", Vector3.FORWARD)
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return Vector3.FORWARD
	return forward.normalized()


## World-space right at segment mid (planar).
func get_right_direction() -> Vector3:
	var sample := sample_centerline(0.5)
	var right: Vector3 = sample.get("right", Vector3.RIGHT)
	right.y = 0.0
	if right.length_squared() < 0.0001:
		return Vector3.RIGHT
	return right.normalized()


## Sample centerline at normalized t in [0, 1].
func sample_centerline(t: float) -> Dictionary:
	return sample_at_distance(clampf(t, 0.0, 1.0) * length)


## Sample centerline at arc distance from entrance.
func sample_at_distance(distance_from_entrance: float) -> Dictionary:
	_ensure_samples()
	var dist := clampf(distance_from_entrance, 0.0, length)
	var t := dist / length if length > 0.0001 else 0.0
	var local := _sample_local_at_distance(dist)
	var local_pos: Vector3 = local["pos"]
	var yaw: float = float(local["yaw"])
	var pitch: float = float(local.get("pitch", 0.0))
	var forward_local := _forward_from_yaw_pitch(yaw, pitch)
	var right_local := Vector3(cos(yaw), 0.0, -sin(yaw))
	var world_pos := global_transform * local_pos
	var forward := global_transform.basis * forward_local
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	else:
		forward = Vector3.FORWARD
	var right := global_transform.basis * right_local
	right.y = 0.0
	if right.length_squared() > 0.0001:
		right = right.normalized()
	else:
		right = Vector3.RIGHT
	var forward_planar := Vector3(forward.x, 0.0, forward.z)
	if forward_planar.length_squared() > 0.0001:
		forward_planar = forward_planar.normalized()
	else:
		forward_planar = Vector3.FORWARD
	return {
		"point": world_pos,
		"forward": forward_planar,
		"forward_3d": forward,
		"right": right,
		"t": t,
		"distance": dist,
		"yaw": yaw,
		"pitch": pitch,
		"elevation": get_elevation_name(),
	}


## Project a world point onto the entrance→exit centerline (polyline / arc).
## Returns: point, t (0..1), lateral (m, + = right of center), forward, right, on_segment.
func project_on_centerline(world_pos: Vector3) -> Dictionary:
	_ensure_samples()
	var best_dist_sq := INF
	var best_t := 0.0
	var best_point := entrance.global_position
	var best_forward := get_travel_direction()
	var best_right := get_right_direction()
	var best_pitch := 0.0
	var accum := 0.0

	for i in range(_samples.size() - 1):
		var a_local: Vector3 = _samples[i]["pos"]
		var b_local: Vector3 = _samples[i + 1]["pos"]
		var a := global_transform * a_local
		var b := global_transform * b_local
		var ab := b - a
		ab.y = 0.0
		var seg_len := ab.length()
		var to_p := world_pos - a
		to_p.y = 0.0
		var u := 0.0
		if seg_len > 0.0001:
			u = clampf(to_p.dot(ab) / (seg_len * seg_len), 0.0, 1.0)
		var point := a.lerp(b, u)
		var d := world_pos - point
		d.y = 0.0
		var d_sq := d.length_squared()
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			var yaw_a: float = float(_samples[i]["yaw"])
			var yaw_b: float = float(_samples[i + 1]["yaw"])
			var pitch_a: float = float(_samples[i].get("pitch", 0.0))
			var pitch_b: float = float(_samples[i + 1].get("pitch", 0.0))
			var yaw := lerpf(yaw_a, yaw_b, u)
			best_pitch = lerpf(pitch_a, pitch_b, u)
			var forward_local := _forward_from_yaw_pitch(yaw, best_pitch)
			var right_local := Vector3(cos(yaw), 0.0, -sin(yaw))
			best_forward = global_transform.basis * forward_local
			best_forward.y = 0.0
			if best_forward.length_squared() > 0.0001:
				best_forward = best_forward.normalized()
			best_right = global_transform.basis * right_local
			best_right.y = 0.0
			if best_right.length_squared() > 0.0001:
				best_right = best_right.normalized()
			best_point = point
			var along := accum + u * seg_len
			best_t = clampf(along / length, 0.0, 1.0) if length > 0.0001 else 0.0
		accum += seg_len

	var lateral_vec := world_pos - best_point
	lateral_vec.y = 0.0
	var lateral := lateral_vec.dot(best_right)
	return {
		"point": best_point,
		"t": best_t,
		"lateral": lateral,
		"forward": best_forward,
		"right": best_right,
		"pitch": best_pitch,
		"on_segment": best_t > 0.0 and best_t < 1.0,
		"elevation": get_elevation_name(),
	}


## World transform that places this segment's Entrance on [param previous_exit].
## Aligns position, yaw, and pitch so height/grade continue across the joint.
func place_after_exit(previous_exit: Transform3D) -> void:
	var entrance_local := entrance.transform
	global_transform = previous_exit * entrance_local.affine_inverse()


func set_kind(new_kind: Kind) -> void:
	kind = new_kind


func set_elevation(new_elevation: Elevation) -> void:
	elevation = new_elevation


func _apply_dimensions() -> void:
	if not is_inside_tree():
		return
	_resolve_nodes()
	if _road_mesh == null or entrance == null or exit == null:
		return

	_rebuild_samples()
	_apply_markers()
	_build_road_mesh()
	_build_shoulder_meshes()


func _resolve_nodes() -> void:
	if _road_mesh == null:
		_road_mesh = get_node_or_null("Roadway/MeshInstance3D") as MeshInstance3D
	if _road_collision == null:
		_road_collision = get_node_or_null("Roadway/CollisionShape3D") as CollisionShape3D
	if _roadway_body == null:
		_roadway_body = get_node_or_null("Roadway") as StaticBody3D
	if _shoulder_left == null:
		_shoulder_left = get_node_or_null("Shoulders/Left") as MeshInstance3D
	if _shoulder_right == null:
		_shoulder_right = get_node_or_null("Shoulders/Right") as MeshInstance3D
	if _shoulder_left_body == null:
		_shoulder_left_body = get_node_or_null("Shoulders/LeftBody") as StaticBody3D
	if _shoulder_right_body == null:
		_shoulder_right_body = get_node_or_null("Shoulders/RightBody") as StaticBody3D
	if _shoulder_left_collision == null:
		_shoulder_left_collision = get_node_or_null("Shoulders/LeftBody/CollisionShape3D") as CollisionShape3D
	if _shoulder_right_collision == null:
		_shoulder_right_collision = get_node_or_null("Shoulders/RightBody/CollisionShape3D") as CollisionShape3D
	if entrance == null:
		entrance = get_node_or_null("Entrance") as Marker3D
	if exit == null:
		exit = get_node_or_null("Exit") as Marker3D


func _ensure_samples() -> void:
	if _samples.is_empty():
		_rebuild_samples()


func _forward_from_yaw_pitch(yaw: float, pitch: float) -> Vector3:
	## Positive pitch = uphill while traveling toward local -Z.
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


func _basis_from_yaw_pitch(yaw: float, pitch: float) -> Basis:
	var forward := _forward_from_yaw_pitch(yaw, pitch)
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var up := right.cross(forward)
	if up.length_squared() < 0.0001:
		up = Vector3.UP
	else:
		up = up.normalized()
	right = forward.cross(up)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	# Godot basis columns = X/Y/Z axes; local -Z is forward.
	return Basis(right, up, -forward)


func _rebuild_samples() -> void:
	_samples.clear()
	var divisions := maxi(curve_subdivisions, 2)
	var alpha := get_turn_angle()
	var grade := get_elevation_angle()
	var raw: Array[Dictionary] = []
	var pos := Vector3.ZERO
	var ds := length / float(divisions)
	raw.append({"pos": pos, "yaw": 0.0, "pitch": grade})
	for i in range(divisions):
		var s0 := float(i) * ds
		var s1 := float(i + 1) * ds
		var y0 := alpha * s0 / length
		var y1 := alpha * s1 / length
		var fwd0 := _forward_from_yaw_pitch(y0, grade)
		var fwd1 := _forward_from_yaw_pitch(y1, grade)
		pos += (fwd0 + fwd1) * 0.5 * ds
		raw.append({"pos": pos, "yaw": y1, "pitch": grade})

	# Center the chord so the segment origin stays near the geometric middle.
	var start: Vector3 = raw[0]["pos"]
	var end: Vector3 = raw[raw.size() - 1]["pos"]
	var center := (start + end) * 0.5
	for sample in raw:
		var p: Vector3 = sample["pos"]
		# Keep relative elevation; bias so top surface sits near thickness*0.5 at mid-chord.
		sample["pos"] = Vector3(p.x - center.x, p.y - center.y + thickness * 0.5, p.z - center.z)

	_samples = raw


func _sample_local_at_distance(dist: float) -> Dictionary:
	_ensure_samples()
	if _samples.is_empty():
		return {"pos": Vector3(0.0, thickness * 0.5, 0.0), "yaw": 0.0, "pitch": 0.0}
	if _samples.size() == 1 or dist <= 0.0:
		return _samples[0].duplicate()
	if dist >= length:
		return _samples[_samples.size() - 1].duplicate()

	var target := dist
	var accum := 0.0
	for i in range(_samples.size() - 1):
		var a: Vector3 = _samples[i]["pos"]
		var b: Vector3 = _samples[i + 1]["pos"]
		var seg_len := a.distance_to(b)
		if accum + seg_len >= target or i == _samples.size() - 2:
			var u := 0.0 if seg_len < 0.0001 else clampf((target - accum) / seg_len, 0.0, 1.0)
			var yaw := lerpf(float(_samples[i]["yaw"]), float(_samples[i + 1]["yaw"]), u)
			var pitch := lerpf(
				float(_samples[i].get("pitch", 0.0)),
				float(_samples[i + 1].get("pitch", 0.0)),
				u
			)
			return {"pos": a.lerp(b, u), "yaw": yaw, "pitch": pitch}
		accum += seg_len
	return _samples[_samples.size() - 1].duplicate()


func _apply_markers() -> void:
	if _samples.is_empty():
		return
	var start: Dictionary = _samples[0]
	var end: Dictionary = _samples[_samples.size() - 1]
	# Markers carry yaw + height only. Grade lives in mesh/collision so place_after
	# preserves climb/descent delta-Y without double-applying pitch to the basis.
	entrance.transform = Transform3D(
		_basis_from_yaw_pitch(float(start["yaw"]), 0.0),
		start["pos"] as Vector3
	)
	exit.transform = Transform3D(
		_basis_from_yaw_pitch(float(end["yaw"]), 0.0),
		end["pos"] as Vector3
	)


func _build_road_mesh() -> void:
	var half := width * 0.5
	var mesh := _make_strip_mesh(-half, half)
	_road_mesh.mesh = mesh
	if _road_mesh.material_override == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.22, 0.22, 0.24, 1)
		_road_mesh.material_override = mat
	# Prefer road over shoulders if any edge still shares a plane.
	_road_mesh.sorting_offset = 0.0

	_rebuild_box_colliders(_roadway_body, _road_collision, width, 0.0)


func _build_shoulder_meshes() -> void:
	var has_shoulders := show_shoulders and shoulder_width > 0.001
	_shoulder_left.visible = has_shoulders
	_shoulder_right.visible = has_shoulders
	_shoulder_left_body.visible = has_shoulders
	_shoulder_right_body.visible = has_shoulders
	_shoulder_left_body.collision_layer = 1 if has_shoulders else 0
	_shoulder_right_body.collision_layer = 1 if has_shoulders else 0

	_shoulder_left.position = Vector3.ZERO
	_shoulder_right.position = Vector3.ZERO
	_shoulder_left_body.position = Vector3.ZERO
	_shoulder_right_body.position = Vector3.ZERO
	_shoulder_left_body.rotation = Vector3.ZERO
	_shoulder_right_body.rotation = Vector3.ZERO

	if not has_shoulders:
		_shoulder_left.mesh = null
		_shoulder_right.mesh = null
		_clear_extra_collision(_shoulder_left_body, _shoulder_left_collision)
		_clear_extra_collision(_shoulder_right_body, _shoulder_right_collision)
		_shoulder_left_collision.shape = null
		_shoulder_right_collision.shape = null
		return

	var half_road := width * 0.5
	# Signed lateral edges: shoulders sit OUTSIDE the roadway (no coplanar overlap).
	var left_mesh := _make_strip_mesh(-(half_road + shoulder_width), -half_road)
	var right_mesh := _make_strip_mesh(half_road, half_road + shoulder_width)
	_shoulder_left.mesh = left_mesh
	_shoulder_right.mesh = right_mesh

	if _shoulder_left.material_override == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.45, 0.4, 0.32, 1)
		_shoulder_left.material_override = mat
		_shoulder_right.material_override = mat

	# Sink shoulders a hair so the shared edge with the road doesn't z-fight.
	const SHOULDER_SINK := 0.02
	_shoulder_left.position = Vector3(0.0, -SHOULDER_SINK, 0.0)
	_shoulder_right.position = Vector3(0.0, -SHOULDER_SINK, 0.0)
	_shoulder_left.sorting_offset = -1.0
	_shoulder_right.sorting_offset = -1.0

	var shoulder_center := half_road + shoulder_width * 0.5
	_rebuild_box_colliders(_shoulder_left_body, _shoulder_left_collision, shoulder_width, -shoulder_center)
	_rebuild_box_colliders(_shoulder_right_body, _shoulder_right_collision, shoulder_width, shoulder_center)
	_shoulder_left_body.position = Vector3(0.0, -SHOULDER_SINK, 0.0)
	_shoulder_right_body.position = Vector3(0.0, -SHOULDER_SINK, 0.0)


func _clear_extra_collision(body: StaticBody3D, keep: CollisionShape3D) -> void:
	if body == null:
		return
	var to_remove: Array[Node] = []
	for child in body.get_children():
		if child is CollisionShape3D and child != keep:
			to_remove.append(child)
	for child in to_remove:
		body.remove_child(child)
		child.free()


## Convex box chain along the centerline — reliable for CharacterBody3D (unlike trimesh).
func _rebuild_box_colliders(
	body: StaticBody3D,
	primary: CollisionShape3D,
	collider_width: float,
	lateral_offset: float
) -> void:
	_ensure_samples()
	_clear_extra_collision(body, primary)
	if _samples.size() < 2 or primary == null:
		return

	var piece_count := _samples.size() - 1
	for i in range(piece_count):
		var a: Dictionary = _samples[i]
		var b: Dictionary = _samples[i + 1]
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		var yaw := lerpf(float(a["yaw"]), float(b["yaw"]), 0.5)
		var pitch := lerpf(float(a.get("pitch", 0.0)), float(b.get("pitch", 0.0)), 0.5)
		var mid := pa.lerp(pb, 0.5)
		var basis := _basis_from_yaw_pitch(yaw, pitch)
		var right := basis.x
		mid += right * lateral_offset
		# Shift from top-surface sample down to box center along local up.
		mid -= basis.y * (thickness * 0.5)
		# Generous overlap so CharacterBody rides the grade without hitting box ends.
		var seg_len := maxf(pa.distance_to(pb) * 1.2, 0.5)

		var shape := BoxShape3D.new()
		shape.size = Vector3(collider_width, thickness, seg_len)

		var col: CollisionShape3D
		if i == 0:
			col = primary
			col.shape = shape
		else:
			col = CollisionShape3D.new()
			col.shape = shape
			body.add_child(col)

		col.transform = Transform3D(basis, mid)


## Build a roadway strip between signed lateral edges (negative = left of center).
## Example: road = (-half, +half); left shoulder = (-half-sw, -half).
func _make_strip_mesh(left_edge: float, right_edge: float) -> ArrayMesh:
	_ensure_samples()
	if _samples.size() < 2:
		return null
	if right_edge < left_edge:
		var tmp := left_edge
		left_edge = right_edge
		right_edge = tmp

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Tiny lengthwise inset so adjacent segment end-caps don't share a coplanar face.
	const JOINT_INSET := 0.02
	var total_len := 0.0
	for i in range(_samples.size() - 1):
		total_len += (_samples[i]["pos"] as Vector3).distance_to(_samples[i + 1]["pos"] as Vector3)
	var inset_start := JOINT_INSET
	var inset_end := maxf(total_len - JOINT_INSET, inset_start + 0.01)

	var accum := 0.0
	for i in range(_samples.size() - 1):
		var a: Dictionary = _samples[i]
		var b: Dictionary = _samples[i + 1]
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		var piece_len := pa.distance_to(pb)
		var piece_start := accum
		var piece_end := accum + piece_len
		accum = piece_end

		# Skip pieces wholly outside the inset range; trim pieces that cross inset bounds.
		if piece_end <= inset_start or piece_start >= inset_end:
			continue
		var u0 := 0.0
		var u1 := 1.0
		if piece_len > 0.0001:
			u0 = clampf((inset_start - piece_start) / piece_len, 0.0, 1.0)
			u1 = clampf((inset_end - piece_start) / piece_len, 0.0, 1.0)
		if u1 - u0 < 0.0001:
			continue

		var yaw_a: float = float(a["yaw"])
		var yaw_b: float = float(b["yaw"])
		var pitch_a: float = float(a.get("pitch", 0.0))
		var pitch_b: float = float(b.get("pitch", 0.0))
		var yaw0 := lerpf(yaw_a, yaw_b, u0)
		var yaw1 := lerpf(yaw_a, yaw_b, u1)
		var pitch0 := lerpf(pitch_a, pitch_b, u0)
		var pitch1 := lerpf(pitch_a, pitch_b, u1)
		var basis_a := _basis_from_yaw_pitch(yaw0, pitch0)
		var basis_b := _basis_from_yaw_pitch(yaw1, pitch1)
		pa = pa.lerp(pb, u0)
		pb = (a["pos"] as Vector3).lerp(b["pos"] as Vector3, u1)
		var right_a := basis_a.x
		var right_b := basis_b.x
		var up_a := basis_a.y
		var up_b := basis_b.y

		var a_l := pa + right_a * left_edge
		var a_r := pa + right_a * right_edge
		var b_l := pb + right_b * left_edge
		var b_r := pb + right_b * right_edge
		var a_lb := a_l - up_a * thickness
		var a_rb := a_r - up_a * thickness
		var b_lb := b_l - up_b * thickness
		var b_rb := b_r - up_b * thickness

		_add_quad(st, a_l, b_l, b_r, a_r, up_a)
		_add_quad(st, a_rb, b_rb, b_lb, a_lb, -up_a)
		_add_quad(st, a_lb, b_lb, b_l, a_l, -right_a)
		_add_quad(st, a_r, b_r, b_rb, a_rb, right_a)

	st.generate_normals()
	return st.commit()


func _add_quad(
	st: SurfaceTool,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	normal: Vector3
) -> void:
	var n := normal.normalized()
	st.set_normal(n)
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)
