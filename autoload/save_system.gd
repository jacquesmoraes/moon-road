extends Node
## Central disk save/load coordinator. Does not own system internals —
## registered providers expose get_save_data() / load_save_data(data).
## No autosave, multi-slots, cloud, or encryption.

signal save_completed(path: String)
signal load_completed(path: String)
signal save_failed(reason: String)
signal load_failed(reason: String)

const SAVE_VERSION: int = 1
const SAVE_PATH := "user://savegame.json"
const BACKUP_PATH := "user://savegame.json.bak"

## system_id → Node (autoload / provider).
var _providers: Dictionary = {}
var _created_at: String = ""


func _ready() -> void:
	_register_default_providers()
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	## Temporary debug: F5 save, F9 load, F6 delete.
	if event.is_action_pressed("save_debug_save"):
		var ok := save_game()
		print("SaveSystem debug: save %s (%s)" % ["OK" if ok else "FAIL", SAVE_PATH])
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("save_debug_load"):
		var ok := load_game()
		print("SaveSystem debug: load %s" % ("OK" if ok else "FAIL"))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("save_debug_delete"):
		var ok := delete_save()
		print("SaveSystem debug: delete %s" % ("OK" if ok else "FAIL"))
		get_viewport().set_input_as_handled()


func register_provider(system_id: String, node: Node) -> void:
	if system_id.is_empty() or node == null:
		return
	_providers[system_id] = node


func get_save_path() -> String:
	return SAVE_PATH


func get_backup_path() -> String:
	return BACKUP_PATH


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func get_save_version() -> int:
	## Reads version from disk without applying. -1 if missing/invalid.
	if not has_save():
		return -1
	var parsed := _read_and_parse(SAVE_PATH)
	if parsed.is_empty():
		return -1
	if not parsed.has("save_version"):
		return -1
	return int(parsed.get("save_version", -1))


func save_game() -> bool:
	_register_default_providers()
	var now := _now_iso()
	if _created_at.is_empty():
		# Preserve original created_at when overwriting an existing valid save.
		if has_save():
			var existing := _read_and_parse(SAVE_PATH)
			if not existing.is_empty() and existing.has("created_at"):
				_created_at = str(existing.get("created_at"))
		if _created_at.is_empty():
			_created_at = now

	var systems: Dictionary = {}
	for system_id in _providers.keys():
		var node: Node = _providers[system_id]
		if node == null or not is_instance_valid(node):
			continue
		if not node.has_method("get_save_data"):
			push_warning("SaveSystem: provider '%s' missing get_save_data()" % system_id)
			continue
		var payload: Variant = node.call("get_save_data")
		if typeof(payload) != TYPE_DICTIONARY:
			push_warning("SaveSystem: provider '%s' get_save_data() must return Dictionary" % system_id)
			continue
		systems[str(system_id)] = payload

	var root: Dictionary = {
		"save_version": SAVE_VERSION,
		"created_at": _created_at,
		"updated_at": now,
		"systems": systems,
	}

	if has_save():
		if not _write_backup():
			# Backup failure is non-fatal — still attempt primary write.
			push_warning("SaveSystem: backup before overwrite failed")

	var text := JSON.stringify(root, "\t")
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		var reason := "write_open_failed:%s" % error_string(FileAccess.get_open_error())
		save_failed.emit(reason)
		push_warning("SaveSystem: %s" % reason)
		return false
	file.store_string(text)
	file.close()
	save_completed.emit(SAVE_PATH)
	print("SaveSystem: saved → %s (v%d)" % [SAVE_PATH, SAVE_VERSION])
	return true


func load_game() -> bool:
	_register_default_providers()
	if not has_save():
		var reason := "missing_file"
		load_failed.emit(reason)
		push_warning("SaveSystem: load failed (%s)" % reason)
		return false

	var parsed := _read_and_parse(SAVE_PATH)
	if parsed.is_empty():
		# Corrupted / invalid JSON — do NOT delete the file.
		var reason := "invalid_or_corrupted"
		load_failed.emit(reason)
		push_warning("SaveSystem: load failed (%s) — file kept at %s" % [reason, SAVE_PATH])
		return false

	if not parsed.has("save_version"):
		load_failed.emit("missing_version")
		push_warning("SaveSystem: load failed (missing_version) — file kept")
		return false

	var version := int(parsed.get("save_version", -1))
	if version != SAVE_VERSION:
		# Unknown / unsupported version — refuse without deleting.
		var reason := "unknown_version:%d" % version
		load_failed.emit(reason)
		push_warning("SaveSystem: load failed (%s) — file kept" % reason)
		return false

	_created_at = str(parsed.get("created_at", ""))
	var systems: Dictionary = parsed.get("systems", {})
	if typeof(systems) != TYPE_DICTIONARY:
		load_failed.emit("invalid_systems_block")
		push_warning("SaveSystem: load failed (invalid_systems_block) — file kept")
		return false

	for system_id in _providers.keys():
		var node: Node = _providers[system_id]
		if node == null or not is_instance_valid(node):
			continue
		if not node.has_method("load_save_data"):
			push_warning("SaveSystem: provider '%s' missing load_save_data()" % system_id)
			continue
		var payload: Variant = systems.get(str(system_id), {})
		if typeof(payload) != TYPE_DICTIONARY:
			payload = {}
		node.call("load_save_data", payload)

	load_completed.emit(SAVE_PATH)
	print("SaveSystem: loaded ← %s (v%d)" % [SAVE_PATH, version])
	return true


func delete_save() -> bool:
	## Explicit debug/test delete. Never called automatically on corruption.
	var dir := DirAccess.open("user://")
	var removed_main := true
	var removed_bak := true
	if dir != null:
		if dir.file_exists("savegame.json"):
			removed_main = dir.remove("savegame.json") == OK
		if dir.file_exists("savegame.json.bak"):
			removed_bak = dir.remove("savegame.json.bak") == OK
	else:
		removed_main = false
		removed_bak = false
	_created_at = ""
	if not has_save():
		print("SaveSystem: save deleted")
		return removed_main and removed_bak
	push_warning("SaveSystem: delete_save could not remove %s" % SAVE_PATH)
	return false


func _register_default_providers() -> void:
	_try_register("journey", "/root/JourneySystem")
	_try_register("inventory", "/root/InventorySystem")
	_try_register("quest", "/root/QuestSystem")
	_try_register("poi", "/root/POISystem")
	_try_register("world_state", "/root/WorldStateSystem")


func _try_register(system_id: String, path: String) -> void:
	if _providers.has(system_id) and _providers[system_id] != null and is_instance_valid(_providers[system_id]):
		return
	var node := get_node_or_null(path)
	if node != null:
		_providers[system_id] = node


func _write_backup() -> bool:
	var text := FileAccess.get_file_as_string(SAVE_PATH)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return false
	var bak := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
	if bak == null:
		return false
	bak.store_string(text)
	bak.close()
	return true


func _read_and_parse(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


func _now_iso() -> String:
	return Time.get_datetime_string_from_system(true)
