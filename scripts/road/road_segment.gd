extends Node3D
class_name RoadSegment
## Modular straight road piece. Place so Exit of one aligns with Entrance of the next.
## Local +Z = entrance side, local -Z = exit / travel direction (matches Godot vehicle forward).

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

@onready var _road_mesh: MeshInstance3D = $Roadway/MeshInstance3D
@onready var _road_collision: CollisionShape3D = $Roadway/CollisionShape3D
@onready var _shoulder_left: MeshInstance3D = $Shoulders/Left
@onready var _shoulder_right: MeshInstance3D = $Shoulders/Right
@onready var _shoulder_left_body: StaticBody3D = $Shoulders/LeftBody
@onready var _shoulder_right_body: StaticBody3D = $Shoulders/RightBody
@onready var _shoulder_left_collision: CollisionShape3D = $Shoulders/LeftBody/CollisionShape3D
@onready var _shoulder_right_collision: CollisionShape3D = $Shoulders/RightBody/CollisionShape3D
@onready var entrance: Marker3D = $Entrance
@onready var exit: Marker3D = $Exit


func _ready() -> void:
	_ensure_unique_meshes()
	_apply_dimensions()


func _ensure_unique_meshes() -> void:
	## Instanced scenes share sub-resources; duplicate so per-segment size edits stay local.
	if _road_mesh.mesh:
		_road_mesh.mesh = _road_mesh.mesh.duplicate()
	if _road_collision.shape:
		_road_collision.shape = _road_collision.shape.duplicate()
	if _shoulder_left.mesh:
		_shoulder_left.mesh = _shoulder_left.mesh.duplicate()
	if _shoulder_right.mesh:
		_shoulder_right.mesh = _shoulder_right.mesh.duplicate()
	if _shoulder_left_collision.shape:
		_shoulder_left_collision.shape = _shoulder_left_collision.shape.duplicate()
	if _shoulder_right_collision.shape:
		_shoulder_right_collision.shape = _shoulder_right_collision.shape.duplicate()


func get_length() -> float:
	return length


func get_width() -> float:
	return width


func get_entrance_global_transform() -> Transform3D:
	return entrance.global_transform


func get_exit_global_transform() -> Transform3D:
	return exit.global_transform


## World transform that places this segment's Entrance on [param previous_exit].
func place_after_exit(previous_exit: Transform3D) -> void:
	var entrance_local := entrance.transform
	global_transform = previous_exit * entrance_local.affine_inverse()


func _apply_dimensions() -> void:
	if _road_mesh == null:
		return

	var road_box := _road_mesh.mesh as BoxMesh
	if road_box == null:
		road_box = BoxMesh.new()
		_road_mesh.mesh = road_box
	road_box.size = Vector3(width, thickness, length)

	var road_shape := _road_collision.shape as BoxShape3D
	if road_shape == null:
		road_shape = BoxShape3D.new()
		_road_collision.shape = road_shape
	road_shape.size = Vector3(width, thickness, length)

	entrance.position = Vector3(0.0, thickness * 0.5, length * 0.5)
	exit.position = Vector3(0.0, thickness * 0.5, -length * 0.5)

	var has_shoulders := show_shoulders and shoulder_width > 0.001
	_shoulder_left.visible = has_shoulders
	_shoulder_right.visible = has_shoulders
	_shoulder_left_body.visible = has_shoulders
	_shoulder_right_body.visible = has_shoulders
	_shoulder_left_body.collision_layer = 1 if has_shoulders else 0
	_shoulder_right_body.collision_layer = 1 if has_shoulders else 0

	if not has_shoulders:
		return

	var shoulder_box_size := Vector3(shoulder_width, thickness, length)
	var left_mesh := _shoulder_left.mesh as BoxMesh
	if left_mesh == null:
		left_mesh = BoxMesh.new()
		_shoulder_left.mesh = left_mesh
	left_mesh.size = shoulder_box_size

	var right_mesh := _shoulder_right.mesh as BoxMesh
	if right_mesh == null:
		right_mesh = BoxMesh.new()
		_shoulder_right.mesh = right_mesh
	right_mesh.size = shoulder_box_size

	var left_shape := _shoulder_left_collision.shape as BoxShape3D
	if left_shape == null:
		left_shape = BoxShape3D.new()
		_shoulder_left_collision.shape = left_shape
	left_shape.size = shoulder_box_size

	var right_shape := _shoulder_right_collision.shape as BoxShape3D
	if right_shape == null:
		right_shape = BoxShape3D.new()
		_shoulder_right_collision.shape = right_shape
	right_shape.size = shoulder_box_size

	var offset_x := (width + shoulder_width) * 0.5
	_shoulder_left.position = Vector3(-offset_x, 0.0, 0.0)
	_shoulder_right.position = Vector3(offset_x, 0.0, 0.0)
	_shoulder_left_body.position = Vector3(-offset_x, 0.0, 0.0)
	_shoulder_right_body.position = Vector3(offset_x, 0.0, 0.0)
