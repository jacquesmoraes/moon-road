extends Node
## Logical POI discovery + viewpoint scene spawn/despawn.
## Discovery state lives here — survives viewpoint unload. Independent of UI/art.

signal discovered_poi(poi_id: String, display_name: String)
signal viewpoint_spawned(poi_id: String, instance: Node3D)
signal viewpoint_despawned(poi_id: String)

const DEFAULT_VIEWPOINT_SCENE := "res://scenes/world/ViewpointPOI.tscn"

@export_file("*.tscn") var default_viewpoint_scene_path: String = DEFAULT_VIEWPOINT_SCENE

## poi_id → true once discovered (logical; not tied to scene lifetime).
var _discovered: Dictionary = {}
## poi_id → active ViewpointPOI instance (optional world presence).
var _instances: Dictionary = {}
var _default_scene: PackedScene


func _ready() -> void:
	if not default_viewpoint_scene_path.is_empty():
		_default_scene = load(default_viewpoint_scene_path) as PackedScene


func is_discovered(poi_id: String) -> bool:
	if poi_id.is_empty():
		return false
	return bool(_discovered.get(poi_id, false))


func get_discovered_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	for key in _discovered.keys():
		if bool(_discovered[key]):
			out.append(str(key))
	out.sort()
	return out


func get_discovered_count() -> int:
	return get_discovered_ids().size()


## Marks a POI discovered. Emits [signal discovered_poi] only the first time.
## Returns true if this call newly discovered the POI.
func mark_discovered(poi_id: String, display_name: String = "") -> bool:
	if poi_id.is_empty():
		return false
	if bool(_discovered.get(poi_id, false)):
		return false
	_discovered[poi_id] = true
	var name := display_name if not display_name.is_empty() else poi_id
	discovered_poi.emit(poi_id, name)
	return true


func clear_discovery_for_tests(poi_id: String = "") -> void:
	## Test helper only — clears one or all discovery flags.
	if poi_id.is_empty():
		_discovered.clear()
	else:
		_discovered.erase(poi_id)


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	var ids: PackedStringArray = get_discovered_ids()
	var discovered: Array = []
	for id in ids:
		discovered.append(str(id))
	return {"discovered": discovered}


func load_save_data(data: Dictionary) -> void:
	## Restore discovery quietly (no discovered_poi spam on load).
	_discovered.clear()
	if data == null or data.is_empty():
		return
	var discovered: Variant = data.get("discovered", [])
	if typeof(discovered) == TYPE_ARRAY or typeof(discovered) == TYPE_PACKED_STRING_ARRAY:
		for entry in discovered:
			var poi_id := str(entry)
			if not poi_id.is_empty():
				_discovered[poi_id] = true


func has_active_viewpoint(poi_id: String) -> bool:
	if not _instances.has(poi_id):
		return false
	var node: Node = _instances[poi_id]
	return node != null and is_instance_valid(node)


func get_active_viewpoint(poi_id: String) -> Node3D:
	if not has_active_viewpoint(poi_id):
		return null
	return _instances[poi_id] as Node3D


func get_active_viewpoint_count() -> int:
	var n := 0
	for key in _instances.keys():
		if has_active_viewpoint(str(key)):
			n += 1
	return n


## Instantiates (or moves) a viewpoint scene at [param world_transform], parented under [param parent].
func spawn_viewpoint(
	poi: PointOfInterest,
	world_transform: Transform3D,
	parent: Node,
	viewpoint_scene: PackedScene = null
) -> Node3D:
	if poi == null or poi.poi_id.is_empty() or parent == null:
		return null

	var scene := viewpoint_scene
	if scene == null and poi.viewpoint_scene != null:
		scene = poi.viewpoint_scene
	if scene == null:
		scene = _default_scene
	if scene == null and not default_viewpoint_scene_path.is_empty():
		scene = load(default_viewpoint_scene_path) as PackedScene
	if scene == null:
		push_warning("POISystem: no viewpoint scene for %s" % poi.poi_id)
		return null

	var existing := get_active_viewpoint(poi.poi_id)
	if existing != null:
		if existing.get_parent() != parent:
			existing.reparent(parent, true)
		existing.global_transform = world_transform
		if existing.has_method("setup"):
			existing.call("setup", poi)
		return existing

	var inst := scene.instantiate() as Node3D
	if inst == null:
		return null
	inst.name = "Viewpoint_%s" % poi.poi_id
	parent.add_child(inst)
	inst.global_transform = world_transform
	if inst.has_method("setup"):
		inst.call("setup", poi)
	_instances[poi.poi_id] = inst
	viewpoint_spawned.emit(poi.poi_id, inst)
	return inst


func despawn_viewpoint(poi_id: String) -> void:
	if poi_id.is_empty() or not _instances.has(poi_id):
		return
	var node: Node = _instances[poi_id]
	_instances.erase(poi_id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	viewpoint_despawned.emit(poi_id)


func despawn_all_viewpoints() -> void:
	var ids: Array = _instances.keys()
	for key in ids:
		despawn_viewpoint(str(key))


func apply_origin_shift(offset: Vector3) -> void:
	## No-op when viewpoints are parented under RoadsideExitSystem (shifted with it).
	## Kept for viewpoints parented elsewhere.
	if not offset.is_finite() or offset.length_squared() < 0.0001:
		return
	for key in _instances.keys():
		var node: Node3D = _instances[key] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		# Only shift if not under an exit system that already moved.
		var parent := node.get_parent()
		if parent != null and parent.has_method("apply_origin_shift"):
			continue
		node.global_position -= offset
