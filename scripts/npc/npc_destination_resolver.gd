extends RefCounted
class_name NpcDestinationResolver
## Resolves schedule location_id → Marker3D in the current POI/scene.
## Looks under a Destinations node first, then any Marker3D named as the id.

const DESTINATIONS_NODE := "Destinations"


static func find_marker(from_node: Node, location_id: String) -> Marker3D:
	if from_node == null or location_id.is_empty():
		return null
	var root := _find_search_root(from_node)
	if root == null:
		return null
	var destinations := root.get_node_or_null(DESTINATIONS_NODE)
	if destinations != null:
		var direct := destinations.get_node_or_null(location_id) as Marker3D
		if direct != null:
			return direct
		for child in destinations.get_children():
			if child is Marker3D and str(child.name) == location_id:
				return child as Marker3D
			if child is Marker3D and child.has_meta("location_id"):
				if str(child.get_meta("location_id")) == location_id:
					return child as Marker3D
	# Fallback: deep search by node name.
	var found := root.find_child(location_id, true, false)
	if found is Marker3D:
		return found as Marker3D
	return null


static func find_global_position(from_node: Node, location_id: String) -> Variant:
	## Returns Vector3 on success, null when missing (fail-safe).
	var marker := find_marker(from_node, location_id)
	if marker == null:
		return null
	return marker.global_position


static func _find_search_root(from_node: Node) -> Node:
	## Prefer the ViewpointPOI (or similar) that owns a Destinations child.
	var node: Node = from_node
	while node != null:
		if node.get_node_or_null(DESTINATIONS_NODE) != null:
			return node
		if node.has_method("get_poi_id"):
			return node
		node = node.get_parent()
	if from_node.get_tree() != null:
		return from_node.get_tree().current_scene
	return from_node
