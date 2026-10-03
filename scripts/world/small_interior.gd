extends Node3D
class_name SmallInterior
## Reusable single-room interior (observation booth / shelter / tech room).
## Enter/exit by walking through the doorway — no loading screen, no teleport.
## Placeholders only; swap meshes later without changing the volume/API.

signal player_entered_interior(body: Node3D)
signal player_exited_interior(body: Node3D)

const InteriorVolumeScript = preload("res://scripts/world/interior_volume.gd")
const ObservationLogScript = preload("res://scripts/interaction/observation_log.gd")

@export var room_size: Vector3 = Vector3(5.0, 2.8, 5.0)
@export var wall_thickness: float = 0.2
@export var doorway_width: float = 1.3
@export var doorway_height: float = 2.2
@export var building_title: String = "Observation Booth"

var _built: bool = false
var _volume: Area3D
var _log: Node


func _ready() -> void:
	_ensure_built()
	if _volume != null:
		if _volume.has_signal("player_entered") and not _volume.player_entered.is_connected(_on_player_entered):
			_volume.player_entered.connect(_on_player_entered)
		if _volume.has_signal("player_exited") and not _volume.player_exited.is_connected(_on_player_exited):
			_volume.player_exited.connect(_on_player_exited)


func is_player_inside() -> bool:
	return _volume != null and _volume.has_method("is_player_inside") and bool(_volume.call("is_player_inside"))


func get_interior_volume() -> Area3D:
	_ensure_built()
	return _volume


func get_observation_log() -> Node:
	_ensure_built()
	return _log


func get_doorway_exterior_position() -> Vector3:
	return global_position + Vector3(0.0, 0.05, room_size.z * 0.5 + 1.2)


func get_interior_stand_position() -> Vector3:
	return global_position + Vector3(0.0, 0.05, 0.2)


func _on_player_entered(body: Node3D) -> void:
	player_entered_interior.emit(body)


func _on_player_exited(body: Node3D) -> void:
	player_exited_interior.emit(body)


func _ensure_built() -> void:
	if _built:
		_resolve_refs()
		return
	_build_room()
	_resolve_refs()
	_built = true


func _resolve_refs() -> void:
	_volume = get_node_or_null("InteriorVolume") as Area3D
	_log = get_node_or_null("ObservationLog")


func _build_room() -> void:
	var half := room_size * 0.5
	var t := wall_thickness

	_add_box_collider(
		"Floor",
		Vector3(room_size.x + t * 2.0, t, room_size.z + t * 2.0),
		Vector3(0.0, -t * 0.5, 0.0),
		Color(0.32, 0.30, 0.28, 1)
	)
	_add_box_collider(
		"Ceiling",
		Vector3(room_size.x + t * 2.0, t, room_size.z + t * 2.0),
		Vector3(0.0, room_size.y + t * 0.5, 0.0),
		Color(0.28, 0.27, 0.26, 1)
	)
	_add_box_collider(
		"WallBack",
		Vector3(room_size.x + t * 2.0, room_size.y, t),
		Vector3(0.0, half.y, -half.z - t * 0.5),
		Color(0.40, 0.36, 0.32, 1)
	)
	_add_box_collider(
		"WallLeft",
		Vector3(t, room_size.y, room_size.z),
		Vector3(-half.x - t * 0.5, half.y, 0.0),
		Color(0.38, 0.35, 0.31, 1)
	)
	_add_box_collider(
		"WallRight",
		Vector3(t, room_size.y, room_size.z),
		Vector3(half.x + t * 0.5, half.y, 0.0),
		Color(0.38, 0.35, 0.31, 1)
	)

	var side_w := (room_size.x - doorway_width) * 0.5
	if side_w > 0.05:
		_add_box_collider(
			"WallFrontLeft",
			Vector3(side_w, room_size.y, t),
			Vector3(-half.x + side_w * 0.5, half.y, half.z + t * 0.5),
			Color(0.42, 0.38, 0.33, 1)
		)
		_add_box_collider(
			"WallFrontRight",
			Vector3(side_w, room_size.y, t),
			Vector3(half.x - side_w * 0.5, half.y, half.z + t * 0.5),
			Color(0.42, 0.38, 0.33, 1)
		)
	var lintel_h := maxf(room_size.y - doorway_height, 0.2)
	_add_box_collider(
		"WallFrontLintel",
		Vector3(doorway_width, lintel_h, t),
		Vector3(0.0, doorway_height + lintel_h * 0.5, half.z + t * 0.5),
		Color(0.42, 0.38, 0.33, 1)
	)

	if get_node_or_null("InteriorVolume") == null:
		var vol: Area3D = InteriorVolumeScript.new()
		vol.name = "InteriorVolume"
		add_child(vol)
		var shape := CollisionShape3D.new()
		shape.name = "CollisionShape3D"
		var box := BoxShape3D.new()
		box.size = Vector3(room_size.x - 0.4, room_size.y - 0.3, room_size.z - 0.5)
		shape.shape = box
		shape.position = Vector3(0.0, half.y, -0.1)
		vol.add_child(shape)

	if get_node_or_null("InteriorLight") == null:
		var light := OmniLight3D.new()
		light.name = "InteriorLight"
		light.light_color = Color(1.0, 0.92, 0.78, 1)
		light.light_energy = 1.6
		light.omni_range = 7.0
		light.position = Vector3(0.0, room_size.y - 0.35, 0.0)
		add_child(light)

	if get_node_or_null("ObservationLog") == null:
		var log: Area3D = ObservationLogScript.new()
		log.name = "ObservationLog"
		log.position = Vector3(0.0, 0.0, -half.z + 0.55)
		add_child(log)
		_build_log_visual(log)

	if get_node_or_null("TitleLabel") == null:
		var title := Label3D.new()
		title.name = "TitleLabel"
		title.text = building_title
		title.font_size = 42
		title.pixel_size = 0.01
		title.position = Vector3(0.0, doorway_height + 0.35, half.z + t + 0.05)
		title.modulate = Color(0.9, 0.85, 0.7, 1)
		add_child(title)


func _build_log_visual(log: Node3D) -> void:
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var sphere := SphereShape3D.new()
	sphere.radius = 0.9
	col.shape = sphere
	col.position = Vector3(0.0, 1.0, 0.0)
	log.add_child(col)

	var pedestal := MeshInstance3D.new()
	pedestal.name = "Pedestal"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.25
	cyl.bottom_radius = 0.3
	cyl.height = 0.9
	pedestal.mesh = cyl
	pedestal.position = Vector3(0.0, 0.45, 0.0)
	var ped_mat := StandardMaterial3D.new()
	ped_mat.albedo_color = Color(0.25, 0.22, 0.2, 1)
	pedestal.material_override = ped_mat
	log.add_child(pedestal)

	var book := MeshInstance3D.new()
	book.name = "Book"
	var box := BoxMesh.new()
	box.size = Vector3(0.45, 0.08, 0.35)
	book.mesh = box
	book.position = Vector3(0.0, 0.95, 0.0)
	var book_mat := StandardMaterial3D.new()
	book_mat.albedo_color = Color(0.55, 0.28, 0.18, 1)
	book.material_override = book_mat
	log.add_child(book)


func _add_box_collider(wall_name: String, size: Vector3, pos: Vector3, color: Color) -> void:
	if get_node_or_null(wall_name) != null:
		return
	var body := StaticBody3D.new()
	body.name = wall_name
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	body.position = pos

	var mesh := MeshInstance3D.new()
	mesh.name = "MeshInstance3D"
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	body.add_child(mesh)
