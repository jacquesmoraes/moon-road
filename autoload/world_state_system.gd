extends Node
## Logical persistent world flags by entity_id. No Node refs, no city-specific logic.
## Scene instances read/write here; SaveSystem serializes the bag.
##
## Id convention (dot-separated):
##   poi.<poi_id>.terminal.<name>     e.g. poi.sunset_viewpoint.terminal.main
##   poi.<poi_id>.pickup.<name>       e.g. poi.sunset_viewpoint.pickup.scrap_01

signal value_changed(entity_id: String, key: String, value: Variant)
signal entity_cleared(entity_id: String)
signal world_state_cleared

## entity_id → { key → serializable value }
var _entities: Dictionary = {}


func set_value(entity_id: String, key: String, value: Variant) -> bool:
	if entity_id.is_empty() or key.is_empty():
		return false
	if not _is_serializable(value):
		push_warning(
			"WorldStateSystem: rejected non-serializable value for %s.%s (%s)"
			% [entity_id, key, type_string(typeof(value))]
		)
		return false
	if not _entities.has(entity_id):
		_entities[entity_id] = {}
	var bag: Dictionary = _entities[entity_id]
	bag[key] = _sanitize(value)
	_entities[entity_id] = bag
	value_changed.emit(entity_id, key, bag[key])
	return true


func get_value(entity_id: String, key: String, default_value: Variant = null) -> Variant:
	if entity_id.is_empty() or key.is_empty():
		return default_value
	if not _entities.has(entity_id):
		return default_value
	var bag: Dictionary = _entities[entity_id]
	if not bag.has(key):
		return default_value
	return bag[key]


func has_value(entity_id: String, key: String) -> bool:
	if entity_id.is_empty() or key.is_empty():
		return false
	if not _entities.has(entity_id):
		return false
	return (_entities[entity_id] as Dictionary).has(key)


func clear_entity(entity_id: String) -> void:
	if entity_id.is_empty():
		return
	if _entities.erase(entity_id):
		entity_cleared.emit(entity_id)


func set_flag(entity_id: String, flag: String, value: bool = true) -> bool:
	return set_value(entity_id, flag, value)


func get_flag(entity_id: String, flag: String, default_value: bool = false) -> bool:
	return bool(get_value(entity_id, flag, default_value))


func has_flag(entity_id: String, flag: String) -> bool:
	return has_value(entity_id, flag)


func get_entity_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for key in _entities.keys():
		ids.append(str(key))
	ids.sort()
	return ids


func get_entity_keys(entity_id: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if not _entities.has(entity_id):
		return out
	for key in (_entities[entity_id] as Dictionary).keys():
		out.append(str(key))
	out.sort()
	return out


func clear_all() -> void:
	_entities.clear()
	world_state_cleared.emit()


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	## Deep-ish copy of serializable entity bags only.
	var entities: Dictionary = {}
	for entity_id in _entities.keys():
		var bag: Dictionary = _entities[entity_id]
		var copy: Dictionary = {}
		for key in bag.keys():
			var value: Variant = bag[key]
			if _is_serializable(value):
				copy[str(key)] = _sanitize(value)
		if not copy.is_empty():
			entities[str(entity_id)] = copy
	return {"entities": entities}


func load_save_data(data: Dictionary) -> void:
	clear_all()
	if data == null or data.is_empty():
		return
	var entities: Variant = data.get("entities", {})
	if typeof(entities) != TYPE_DICTIONARY:
		return
	for entity_id_raw in entities.keys():
		var entity_id := str(entity_id_raw)
		if entity_id.is_empty():
			continue
		var bag_raw: Variant = entities[entity_id_raw]
		if typeof(bag_raw) != TYPE_DICTIONARY:
			continue
		for key_raw in bag_raw.keys():
			var key := str(key_raw)
			set_value(entity_id, key, bag_raw[key_raw])


func _is_serializable(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return true
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
			return _is_serializable_array(value)
		TYPE_DICTIONARY:
			return _is_serializable_dict(value)
		_:
			return false


func _is_serializable_array(value: Variant) -> bool:
	for item in value:
		if not _is_serializable(item):
			return false
	return true


func _is_serializable_dict(value: Dictionary) -> bool:
	for key in value.keys():
		# JSON object keys must be strings.
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			return false
		if not _is_serializable(value[key]):
			return false
	return true


func _sanitize(value: Variant) -> Variant:
	## Normalize Packed* arrays to Array for stable JSON round-trip.
	match typeof(value):
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
			var out: Array = []
			for item in value:
				out.append(item)
			return out
		TYPE_ARRAY:
			var out_a: Array = []
			for item in value:
				out_a.append(_sanitize(item))
			return out_a
		TYPE_DICTIONARY:
			var out_d: Dictionary = {}
			for key in value.keys():
				out_d[str(key)] = _sanitize(value[key])
			return out_d
		_:
			return value
