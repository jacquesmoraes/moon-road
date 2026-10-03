extends Area3D
class_name InteriorVolume
## Detects the on-foot player inside a small interior and notifies the on-foot camera.
## Walk-in / walk-out — no teleport, no loading screen.

signal player_entered(body: Node3D)
signal player_exited(body: Node3D)

@export var camera_path: NodePath
@export var interior_follow_distance: float = 1.75
@export var interior_follow_height: float = 1.35

var _camera: Node
var _inside_count: int = 0


func _ready() -> void:
	monitoring = true
	monitorable = false
	collision_layer = 0
	# On-foot character layer bit (value 4).
	collision_mask = 4
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not body_exited.is_connected(_on_body_exited):
		body_exited.connect(_on_body_exited)
	_resolve_camera()


func is_player_inside() -> bool:
	return _inside_count > 0


func _on_body_entered(body: Node3D) -> void:
	if not _is_player(body):
		return
	_inside_count += 1
	if _inside_count == 1:
		_apply_camera(true)
		player_entered.emit(body)


func _on_body_exited(body: Node3D) -> void:
	if not _is_player(body):
		return
	_inside_count = maxi(_inside_count - 1, 0)
	if _inside_count == 0:
		_apply_camera(false)
		player_exited.emit(body)


func _apply_camera(inside: bool) -> void:
	_resolve_camera()
	if _camera == null:
		return
	if _camera.has_method("set_interior_active"):
		_camera.call("set_interior_active", inside, interior_follow_distance, interior_follow_height)


func _is_player(body: Node) -> bool:
	if body == null:
		return false
	if str(body.name) == "PlayerCharacter":
		return true
	if body.has_method("is_control_enabled"):
		return true
	return body is CharacterBody3D and body.collision_layer & 4 != 0


func _resolve_camera() -> void:
	if camera_path != NodePath():
		_camera = get_node_or_null(camera_path)
	if _camera == null and get_tree() != null and get_tree().current_scene != null:
		_camera = get_tree().current_scene.find_child("OnFootCameraController", true, false)
