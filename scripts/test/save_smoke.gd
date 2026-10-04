extends "res://scripts/test/test_helpers.gd"
## SaveSystem round-trip, corrupt keep, version gate.
## Run: godot --path . --headless -s res://scripts/test/save_smoke.gd

func _initialize() -> void:
	suite_name = "save_smoke"
	start_suite_timeout(120.0)
	await _run()

func _run() -> void:
	if not await bootstrap_sandbox(0.5, true):
		return
	if not _verify_save_system():
		return
	pass_suite("save")

func _verify_save_system() -> bool:
	## SaveSystem: round-trip journey/inventory/quest/poi; corrupt JSON kept; version field present.
	var save: Node = root.get_node_or_null("SaveSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var poi: Node = root.get_node_or_null("POISystem")
	if save == null or journey == null or inv == null or qs == null or poi == null:
		push_error("save_smoke: SaveSystem or providers missing")
		quit(1)
		return false

	# Decoupling: SaveSystem must not hardcode provider internals.
	var save_script: Script = load("res://autoload/save_system.gd") as Script
	if save_script != null:
		var src := save_script.source_code
		for banned in ["current_distance_km", "_quantities", "_states", "_discovered"]:
			if src.find(banned) >= 0:
				push_error("save_smoke: SaveSystem must not reference provider field '%s'" % banned)
				quit(1)
				return false

	# Clean slate.
	if save.has_method("delete_save"):
		save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")

	if bool(save.call("has_save")):
		push_error("save_smoke: has_save true after delete")
		quit(1)
		return false
	if int(save.call("get_save_version")) != -1:
		push_error("save_smoke: get_save_version should be -1 without file")
		quit(1)
		return false
	if bool(save.call("load_game")):
		push_error("save_smoke: load_game should fail on missing file")
		quit(1)
		return false

	# Seed persistent state.
	journey.call("set_current_distance_km", 1234.5)
	inv.call("add_item", "scrap_metal", 3)
	inv.call("add_item", "copper_wire", 1)
	if not bool(qs.call("start_quest", "power_the_viewpoint")):
		push_error("save_smoke: could not start quest for save test")
		quit(1)
		return false
	poi.call("mark_discovered", "sunset_viewpoint", "Sunset Viewpoint")

	if not bool(save.call("save_game")):
		push_error("save_smoke: save_game failed")
		quit(1)
		return false
	if not bool(save.call("has_save")):
		push_error("save_smoke: has_save false after save")
		quit(1)
		return false
	if int(save.call("get_save_version")) != 1:
		push_error("save_smoke: get_save_version expected 1")
		quit(1)
		return false

	# Inspect JSON structure for save_version / timestamps.
	var path := str(save.call("get_save_path"))
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("save_smoke: save JSON did not parse")
		quit(1)
		return false
	var root_dict: Dictionary = parsed
	if int(root_dict.get("save_version", -1)) != 1:
		push_error("save_smoke: save_version missing/wrong in file")
		quit(1)
		return false
	if str(root_dict.get("created_at", "")).is_empty() or str(root_dict.get("updated_at", "")).is_empty():
		push_error("save_smoke: created_at/updated_at missing")
		quit(1)
		return false
	if typeof(root_dict.get("systems", null)) != TYPE_DICTIONARY:
		push_error("save_smoke: systems block missing")
		quit(1)
		return false

	# Wipe runtime state then reload.
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	if float(journey.call("get_current_distance_km")) != 0.0:
		push_error("save_smoke: journey not cleared before load")
		quit(1)
		return false

	if not bool(save.call("load_game")):
		push_error("save_smoke: load_game failed on valid save")
		quit(1)
		return false
	if not is_equal_approx(float(journey.call("get_current_distance_km")), 1234.5):
		push_error("save_smoke: journey not restored (got %.3f)" % float(journey.call("get_current_distance_km")))
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 3 or int(inv.call("get_quantity", "copper_wire")) != 1:
		push_error("save_smoke: inventory not restored")
		quit(1)
		return false
	if str(qs.call("get_state_name", "power_the_viewpoint")) != "ACTIVE":
		push_error("save_smoke: quest state not restored")
		quit(1)
		return false
	if not bool(poi.call("is_discovered", "sunset_viewpoint")):
		push_error("save_smoke: POI discovery not restored")
		quit(1)
		return false

	# Second save should create backup and preserve created_at.
	var created_before := str(root_dict.get("created_at"))
	if not bool(save.call("save_game")):
		push_error("save_smoke: second save_game failed")
		quit(1)
		return false
	var bak_path := str(save.call("get_backup_path"))
	if not FileAccess.file_exists(bak_path):
		push_error("save_smoke: backup not written before overwrite")
		quit(1)
		return false
	var text2 := FileAccess.get_file_as_string(path)
	var parsed2: Variant = JSON.parse_string(text2)
	if typeof(parsed2) == TYPE_DICTIONARY:
		if str(parsed2.get("created_at", "")) != created_before:
			push_error("save_smoke: created_at should survive overwrite")
			quit(1)
			return false

	# Corrupted JSON must not crash and must not delete the file.
	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	if corrupt == null:
		push_error("save_smoke: could not overwrite save for corrupt test")
		quit(1)
		return false
	corrupt.store_string("{not valid json!!!")
	corrupt.close()
	if bool(save.call("load_game")):
		push_error("save_smoke: load_game should fail on corrupt JSON")
		quit(1)
		return false
	if not FileAccess.file_exists(path):
		push_error("save_smoke: corrupt save was deleted (must keep)")
		quit(1)
		return false

	# Unknown version refused, file kept.
	var bad_ver := FileAccess.open(path, FileAccess.WRITE)
	bad_ver.store_string(JSON.stringify({"save_version": 999, "created_at": "x", "updated_at": "y", "systems": {}}))
	bad_ver.close()
	if bool(save.call("load_game")):
		push_error("save_smoke: load_game should refuse unknown version")
		quit(1)
		return false
	if not FileAccess.file_exists(path):
		push_error("save_smoke: unknown-version save was deleted")
		quit(1)
		return false

	# Cleanup for later tests.
	save.call("delete_save")
	journey.call("reset_journey")
	inv.call("clear_inventory")
	qs.call("reset_all")
	poi.call("clear_discovery_for_tests")
	clear_world_state()
	print("save_smoke: save OK (round-trip + corrupt kept + version gate)")
	return true



