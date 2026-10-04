extends Node3D
class_name ViewpointPOI
## Reusable explorável viewpoint placeholder.
## Flat stop + observation marker + discover Area3D. Replace meshes with final art later.

signal presence_entered(poi_id: String)
signal presence_exited(poi_id: String)

@export var poi: PointOfInterest
## Half-extents of the discover / bounds volume (meters).
@export var area_extents: Vector3 = Vector3(8.0, 3.0, 10.0)
@export var platform_size: Vector3 = Vector3(14.0, 0.25, 12.0)

var _poi_id: String = ""
var _display_name: String = ""
var _built: bool = false

@onready var _entrance: Marker3D = $Entrance
@onready var _car_area: Marker3D = $CarArea
@onready var _observation: Marker3D = $ObservationPoint
@onready var _discover_area: Area3D = $DiscoverArea
@onready var _platform: StaticBody3D = $Platform
@onready var _sign_root: Node3D = $Sign


func _ready() -> void:
	_ensure_built()
	if poi != null:
		setup(poi)
	if _discover_area != null:
		if not _discover_area.body_entered.is_connected(_on_body_entered):
			_discover_area.body_entered.connect(_on_body_entered)
		if not _discover_area.body_exited.is_connected(_on_body_exited):
			_discover_area.body_exited.connect(_on_body_exited)
	call_deferred("_apply_npc_presence_gates")
	var travel := get_node_or_null("/root/NpcTravelSystem")
	if travel != null and travel.has_signal("npc_presence_changed"):
		if not travel.npc_presence_changed.is_connected(_on_npc_presence_changed):
			travel.npc_presence_changed.connect(_on_npc_presence_changed)


func setup(poi_resource: PointOfInterest) -> void:
	poi = poi_resource
	if poi != null:
		_poi_id = poi.poi_id
		_display_name = poi.display_name if not poi.display_name.is_empty() else poi.poi_id
	_ensure_built()
	_update_sign_label()


func get_poi_id() -> String:
	return _poi_id


func get_display_name() -> String:
	return _display_name


func get_entrance_global_transform() -> Transform3D:
	_ensure_built()
	return _entrance.global_transform if _entrance else global_transform


func get_car_area_global_position() -> Vector3:
	_ensure_built()
	return _car_area.global_position if _car_area else global_position


func get_observation_global_position() -> Vector3:
	_ensure_built()
	return _observation.global_position if _observation else global_position + Vector3(0, 1.5, -4)


func get_local_npc_location_ids() -> PackedStringArray:
	## poi_id + Destinations marker names this stop can host.
	_ensure_built()
	var ids: PackedStringArray = PackedStringArray()
	if not _poi_id.is_empty():
		ids.append(_poi_id)
	var destinations := get_node_or_null("Destinations")
	if destinations != null:
		for child in destinations.get_children():
			if child is Marker3D:
				ids.append(str(child.name))
	return ids


func _apply_npc_presence_gates() -> void:
	## Spawn/keep NPC nodes only when logical state says they belong here.
	var travel := get_node_or_null("/root/NpcTravelSystem")
	if travel == null or not travel.has_method("should_spawn_at_poi"):
		return
	var local_ids := get_local_npc_location_ids()
	var to_remove: Array[Node] = []
	for child in get_children():
		if child == null or not child.has_method("get_npc_id"):
			continue
		var npc_id := str(child.call("get_npc_id"))
		if npc_id.is_empty():
			continue
		if not bool(travel.call("should_spawn_at_poi", npc_id, _poi_id, local_ids)):
			to_remove.append(child)
	for node in to_remove:
		node.queue_free()


func _on_npc_presence_changed(_npc_id: String) -> void:
	_apply_npc_presence_gates()


## Test / systems helper: treat [param body] as present inside the discover volume.
func notify_presence(body: Node3D) -> void:
	_try_discover(body)


func _on_body_entered(body: Node3D) -> void:
	if not _is_player_body(body):
		return
	presence_entered.emit(_poi_id)
	_try_discover(body)


func _on_body_exited(body: Node3D) -> void:
	if not _is_player_body(body):
		return
	presence_exited.emit(_poi_id)


func _try_discover(_body: Node3D) -> void:
	if _poi_id.is_empty():
		return
	var sys := get_node_or_null("/root/POISystem")
	if sys != null and sys.has_method("mark_discovered"):
		sys.call("mark_discovered", _poi_id, _display_name)


func _is_player_body(body: Node) -> bool:
	if body == null:
		return false
	if body is CharacterBody3D:
		return true
	if str(body.name).contains("PlayerVehicle"):
		return true
	if body.has_method("get_speed_kmh"):
		return true
	return false


func _ensure_built() -> void:
	if _built:
		_resolve_nodes()
		return
	_resolve_nodes()
	_build_placeholders()
	_built = true


func _resolve_nodes() -> void:
	if _entrance == null:
		_entrance = get_node_or_null("Entrance") as Marker3D
	if _car_area == null:
		_car_area = get_node_or_null("CarArea") as Marker3D
	if _observation == null:
		_observation = get_node_or_null("ObservationPoint") as Marker3D
	if _discover_area == null:
		_discover_area = get_node_or_null("DiscoverArea") as Area3D
	if _platform == null:
		_platform = get_node_or_null("Platform") as StaticBody3D
	if _sign_root == null:
		_sign_root = get_node_or_null("Sign") as Node3D


func _build_placeholders() -> void:
	## All meshes are clearly temporary — swap this scene's art later without logic changes.
	if _entrance == null:
		_entrance = Marker3D.new()
		_entrance.name = "Entrance"
		add_child(_entrance)
	_entrance.position = Vector3(0.0, 0.1, 6.0)

	if _car_area == null:
		_car_area = Marker3D.new()
		_car_area.name = "CarArea"
		add_child(_car_area)
	_car_area.position = Vector3(0.0, 0.1, 1.0)

	if _observation == null:
		_observation = Marker3D.new()
		_observation.name = "ObservationPoint"
		add_child(_observation)
	_observation.position = Vector3(0.0, 1.4, -4.5)

	_build_platform()
	_build_navigation_region()
	_build_destinations()
	_build_discover_area()
	_build_sign()
	_build_bounds_visual()


func _build_platform() -> void:
	if _platform == null:
		_platform = StaticBody3D.new()
		_platform.name = "Platform"
		add_child(_platform)

	var col := _platform.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null:
		col = CollisionShape3D.new()
		col.name = "CollisionShape3D"
		_platform.add_child(col)
	var shape := BoxShape3D.new()
	shape.size = platform_size
	col.shape = shape
	col.position = Vector3(0.0, -platform_size.y * 0.5, 0.0)

	var mesh := _platform.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh == null:
		mesh = MeshInstance3D.new()
		mesh.name = "MeshInstance3D"
		_platform.add_child(mesh)
	var box := BoxMesh.new()
	box.size = platform_size
	mesh.mesh = box
	mesh.position = col.position
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.36, 0.34, 1)
	mesh.material_override = mat


func _build_navigation_region() -> void:
	## Flat navmesh over the platform for basic NPC walks (no complex avoidance).
	var region := get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if region == null:
		region = NavigationRegion3D.new()
		region.name = "NavigationRegion3D"
		add_child(region)
	var nav_mesh := NavigationMesh.new()
	var half_x := platform_size.x * 0.5
	var half_z := platform_size.z * 0.5
	var y := 0.05
	nav_mesh.vertices = PackedVector3Array([
		Vector3(-half_x, y, -half_z),
		Vector3(half_x, y, -half_z),
		Vector3(half_x, y, half_z),
		Vector3(-half_x, y, half_z),
	])
	nav_mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav_mesh.agent_radius = 0.35
	nav_mesh.agent_height = 1.6
	nav_mesh.agent_max_climb = 0.3
	region.navigation_mesh = nav_mesh


func _build_destinations() -> void:
	## Schedule location_id → Marker3D. Logical ids only; art can move markers later.
	var root := get_node_or_null("Destinations") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "Destinations"
		add_child(root)
	var spots := {
		"viewpoint_workshop": Vector3(4.5, 0.05, -2.5),
		"viewpoint_diner": Vector3(-4.0, 0.05, 2.0),
		"viewpoint_home": Vector3(-5.0, 0.05, -4.0),
		"roadside_pullout": Vector3(-1.2, 0.05, 3.5),
		"roadside_camp": Vector3(5.0, 0.05, 4.0),
	}
	for location_id in spots.keys():
		var marker := root.get_node_or_null(str(location_id)) as Marker3D
		if marker == null:
			marker = Marker3D.new()
			marker.name = str(location_id)
			root.add_child(marker)
		marker.position = spots[location_id] as Vector3
		marker.set_meta("location_id", str(location_id))


func _build_discover_area() -> void:
	if _discover_area == null:
		_discover_area = Area3D.new()
		_discover_area.name = "DiscoverArea"
		add_child(_discover_area)
	_discover_area.monitoring = true
	_discover_area.monitorable = false
	_discover_area.collision_layer = 0
	# Detect vehicle (layer bit 1 → value 2) and on-foot character (layer bit 2 → value 4).
	_discover_area.collision_mask = 2 | 4

	var col := _discover_area.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null:
		col = CollisionShape3D.new()
		col.name = "CollisionShape3D"
		_discover_area.add_child(col)
	var shape := BoxShape3D.new()
	shape.size = area_extents * 2.0
	col.shape = shape
	col.position = Vector3(0.0, area_extents.y * 0.5, 0.0)


func _build_sign() -> void:
	if _sign_root == null:
		_sign_root = Node3D.new()
		_sign_root.name = "Sign"
		add_child(_sign_root)
	_sign_root.position = Vector3(-4.5, 0.0, -3.0)

	var post := _sign_root.get_node_or_null("Post") as MeshInstance3D
	if post == null:
		post = MeshInstance3D.new()
		post.name = "Post"
		_sign_root.add_child(post)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.08
	cyl.bottom_radius = 0.1
	cyl.height = 2.4
	post.mesh = cyl
	post.position = Vector3(0.0, 1.2, 0.0)
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = Color(0.25, 0.2, 0.15, 1)
	post.material_override = post_mat

	var board := _sign_root.get_node_or_null("Board") as MeshInstance3D
	if board == null:
		board = MeshInstance3D.new()
		board.name = "Board"
		_sign_root.add_child(board)
	var box := BoxMesh.new()
	box.size = Vector3(2.6, 1.1, 0.1)
	board.mesh = box
	board.position = Vector3(0.0, 2.5, 0.0)
	var board_mat := StandardMaterial3D.new()
	board_mat.albedo_color = Color(0.12, 0.1, 0.08, 1)
	board.material_override = board_mat


func _build_bounds_visual() -> void:
	## Thin wireframe-ish corner posts so the logical area is obvious in-engine.
	var bounds := get_node_or_null("BoundsVisual") as Node3D
	if bounds == null:
		bounds = Node3D.new()
		bounds.name = "BoundsVisual"
		add_child(bounds)
	var corners := [
		Vector3(-area_extents.x, 0.0, -area_extents.z),
		Vector3(area_extents.x, 0.0, -area_extents.z),
		Vector3(-area_extents.x, 0.0, area_extents.z),
		Vector3(area_extents.x, 0.0, area_extents.z),
	]
	for i in corners.size():
		var name := "Corner_%d" % i
		var mesh := bounds.get_node_or_null(name) as MeshInstance3D
		if mesh == null:
			mesh = MeshInstance3D.new()
			mesh.name = name
			bounds.add_child(mesh)
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.06
		cyl.bottom_radius = 0.06
		cyl.height = area_extents.y
		mesh.mesh = cyl
		mesh.position = corners[i] + Vector3(0.0, area_extents.y * 0.5, 0.0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.55, 0.2, 1)
		mesh.material_override = mat


func _update_sign_label() -> void:
	## Placeholder only — no Label3D dependency required for discovery.
	pass
