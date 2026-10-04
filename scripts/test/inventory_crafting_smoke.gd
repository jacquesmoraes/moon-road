extends "res://scripts/test/test_helpers.gd"
## Inventory, crafting, world pickups, workbench.
## Run: godot --path . --headless -s res://scripts/test/inventory_crafting_smoke.gd

func _initialize() -> void:
	suite_name = "inventory_crafting_smoke"
	start_suite_timeout(180.0)
	await _run()

func _run() -> void:
	if not await bootstrap_sandbox(0.5, true):
		return
	var foot := await park_and_exit_to_foot()
	if not bool(foot.get("ok", false)):
		return
	var occupancy: Node = foot["occupancy"]
	var character: CharacterBody3D = foot["character"]
	var foot_cam: Node3D = foot["foot_cam"]
	if not _verify_inventory_system():
		return
	if not _verify_crafting_system():
		return
	if not await _verify_world_items(occupancy, character, foot_cam):
		return
	if not await _verify_workbench(occupancy, character, foot_cam):
		return
	pass_suite("inventory+crafting+world_items+workbench")

func _verify_inventory_system() -> bool:
	## InventorySystem: add/remove/stack/clamp — no NPC/UI/crafting coupling.
	var inv: Node = root.get_node_or_null("InventorySystem")
	if inv == null:
		push_error("inventory_crafting_smoke: InventorySystem autoload missing")
		quit(1)
		return false

	# Decoupling: inventory script must not hard-depend on NPC / dialogue / debug UI.
	var inv_script: Script = load("res://autoload/inventory_system.gd") as Script
	if inv_script != null:
		var src := inv_script.source_code
		for banned in ["/root/DialogueSystem", "NpcCharacter", "InventoryDebugUI", "poi_system.gd"]:
			if src.find(banned) >= 0:
				push_error("inventory_crafting_smoke: InventorySystem must not reference %s" % banned)
				quit(1)
				return false

	if inv.has_method("clear_inventory"):
		inv.call("clear_inventory")

	for item_id in ["scrap_metal", "copper_wire", "circuit_board"]:
		if not bool(inv.call("has_item_data", item_id)):
			push_error("inventory_crafting_smoke: missing item data '%s'" % item_id)
			quit(1)
			return false
		if int(inv.call("get_quantity", item_id)) != 0:
			push_error("inventory_crafting_smoke: inventory not empty for %s after clear" % item_id)
			quit(1)
			return false

	# Add + stack.
	if int(inv.call("add_item", "scrap_metal", 5)) != 5:
		push_error("inventory_crafting_smoke: add_item scrap_metal x5 failed")
		quit(1)
		return false
	if int(inv.call("add_item", "scrap_metal", 3)) != 3:
		push_error("inventory_crafting_smoke: stack scrap_metal +3 failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 8:
		push_error("inventory_crafting_smoke: scrap_metal quantity expected 8")
		quit(1)
		return false
	if not bool(inv.call("has_item", "scrap_metal", 8)):
		push_error("inventory_crafting_smoke: has_item scrap_metal x8 false")
		quit(1)
		return false
	if bool(inv.call("has_item", "scrap_metal", 9)):
		push_error("inventory_crafting_smoke: has_item scrap_metal x9 should be false")
		quit(1)
		return false

	# Stack cap (circuit_board max_stack=20).
	if int(inv.call("add_item", "circuit_board", 15)) != 15:
		push_error("inventory_crafting_smoke: add circuit_board x15 failed")
		quit(1)
		return false
	if int(inv.call("add_item", "circuit_board", 10)) != 5:
		push_error("inventory_crafting_smoke: circuit_board stack should clamp to +5 (max 20)")
		quit(1)
		return false
	if int(inv.call("get_quantity", "circuit_board")) != 20:
		push_error("inventory_crafting_smoke: circuit_board should be at max_stack 20")
		quit(1)
		return false
	if int(inv.call("add_item", "circuit_board", 1)) != 0:
		push_error("inventory_crafting_smoke: circuit_board over-stack should add 0")
		quit(1)
		return false

	# Remove + never negative.
	if int(inv.call("remove_item", "scrap_metal", 3)) != 3:
		push_error("inventory_crafting_smoke: remove scrap_metal x3 failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 5:
		push_error("inventory_crafting_smoke: scrap_metal expected 5 after remove")
		quit(1)
		return false
	if int(inv.call("remove_item", "scrap_metal", 100)) != 5:
		push_error("inventory_crafting_smoke: remove over-quantity should only take 5")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 0:
		push_error("inventory_crafting_smoke: scrap_metal should be 0 after full remove")
		quit(1)
		return false
	if int(inv.call("remove_item", "scrap_metal", 1)) != 0:
		push_error("inventory_crafting_smoke: remove from empty should return 0")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) < 0:
		push_error("inventory_crafting_smoke: quantity went negative")
		quit(1)
		return false

	# Second item proves catalog reuse.
	if int(inv.call("add_item", "copper_wire", 2)) != 2:
		push_error("inventory_crafting_smoke: add copper_wire failed")
		quit(1)
		return false
	if not bool(inv.call("has_item", "copper_wire")):
		push_error("inventory_crafting_smoke: has_item copper_wire false")
		quit(1)
		return false

	# Unknown id rejected.
	if int(inv.call("add_item", "not_a_real_item", 1)) != 0:
		push_error("inventory_crafting_smoke: unknown item should not add")
		quit(1)
		return false

	inv.call("clear_inventory")
	print("inventory_crafting_smoke: inventory OK (add/stack/clamp/remove, never negative)")
	return true



func _verify_crafting_system() -> bool:
	## CraftingSystem: recipe catalog, safe fail, atomic consume + output. No NPC coupling.
	var craft: Node = root.get_node_or_null("CraftingSystem")
	if craft == null:
		push_error("inventory_crafting_smoke: CraftingSystem autoload missing")
		quit(1)
		return false
	var inv: Node = root.get_node_or_null("InventorySystem")
	if inv == null:
		push_error("inventory_crafting_smoke: InventorySystem missing for crafting check")
		quit(1)
		return false

	var craft_script: Script = load("res://autoload/crafting_system.gd") as Script
	if craft_script != null:
		var src := craft_script.source_code
		for banned in ["/root/DialogueSystem", "NpcCharacter", "QuestSystem", "poi_system.gd"]:
			if src.find(banned) >= 0:
				push_error("inventory_crafting_smoke: CraftingSystem must not reference %s" % banned)
				quit(1)
				return false

	if not bool(inv.call("has_item_data", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: missing ItemData basic_repair_kit")
		quit(1)
		return false
	if not bool(craft.call("has_recipe", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: missing recipe basic_repair_kit")
		quit(1)
		return false
	var recipe: Resource = craft.call("get_recipe", "basic_repair_kit")
	if recipe == null or str(recipe.get("display_name")) != "Basic Repair Kit":
		push_error("inventory_crafting_smoke: Basic Repair Kit recipe display_name mismatch")
		quit(1)
		return false
	if str(recipe.get("output_item_id")) != "basic_repair_kit" or int(recipe.get("output_quantity")) != 1:
		push_error("inventory_crafting_smoke: Basic Repair Kit output mismatch")
		quit(1)
		return false

	inv.call("clear_inventory")
	if bool(craft.call("can_craft", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: can_craft should be false without ingredients")
		quit(1)
		return false
	if bool(craft.call("craft", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: craft should fail safely without ingredients")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 0:
		push_error("inventory_crafting_smoke: failed craft must not add output")
		quit(1)
		return false

	# Partial ingredients: still fail, consume nothing.
	inv.call("add_item", "scrap_metal", 2)
	if bool(craft.call("craft", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: craft should fail with only scrap_metal")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 2:
		push_error("inventory_crafting_smoke: failed craft must not consume partial ingredients")
		quit(1)
		return false

	inv.call("add_item", "copper_wire", 1)
	if not bool(craft.call("can_craft", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: can_craft should be true with 2 scrap + 1 wire")
		quit(1)
		return false
	if not bool(craft.call("craft", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: craft Basic Repair Kit failed with ingredients")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 0:
		push_error("inventory_crafting_smoke: scrap_metal not consumed after craft")
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 0:
		push_error("inventory_crafting_smoke: copper_wire not consumed after craft")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 1:
		push_error("inventory_crafting_smoke: basic_repair_kit not in inventory after craft")
		quit(1)
		return false

	# New recipes via register_recipe without changing core logic.
	var RecipeDataScr: Script = load("res://scripts/crafting/recipe_data.gd") as Script
	if RecipeDataScr != null:
		var extra: Resource = RecipeDataScr.new()
		extra.set("id", "smoke_extra_kit")
		extra.set("display_name", "Smoke Extra Kit")
		extra.set("ingredient_item_ids", PackedStringArray(["basic_repair_kit"]))
		extra.set("ingredient_amounts", PackedInt32Array([1]))
		extra.set("output_item_id", "circuit_board")
		extra.set("output_quantity", 1)
		craft.call("register_recipe", extra)
		if not bool(craft.call("has_recipe", "smoke_extra_kit")):
			push_error("inventory_crafting_smoke: register_recipe did not add smoke_extra_kit")
			quit(1)
			return false
		if not bool(craft.call("craft", "smoke_extra_kit")):
			push_error("inventory_crafting_smoke: craft via registered recipe failed")
			quit(1)
			return false
		if int(inv.call("get_quantity", "basic_repair_kit")) != 0:
			push_error("inventory_crafting_smoke: registered recipe did not consume kit")
			quit(1)
			return false
		if int(inv.call("get_quantity", "circuit_board")) != 1:
			push_error("inventory_crafting_smoke: registered recipe did not add circuit_board")
			quit(1)
			return false

	inv.call("clear_inventory")
	craft.call("reload_catalog")
	print("inventory_crafting_smoke: crafting OK (fail-safe, consume, output, data-driven recipe)")
	return true



func _verify_world_items(_occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Collect Scrap Metal (inside booth) + Copper Wire (outside) via Interactable → Inventory.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if poi_sys == null or inv == null:
		push_error("inventory_crafting_smoke: POISystem/InventorySystem missing for pickups")
		quit(1)
		return false

	if inv.has_method("clear_inventory"):
		inv.call("clear_inventory")
	clear_world_state()

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("inventory_crafting_smoke: could not load viewpoint for pickups")
		quit(1)
		return false

	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(12.0, 0.0, -4.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("inventory_crafting_smoke: failed to spawn viewpoint for pickups")
		quit(1)
		return false

	var scrap: Node = vp.find_child("ScrapMetalPickup", true, false)
	var scrap_b: Node = vp.find_child("ScrapMetalPickupB", true, false)
	var scrap_c: Node = vp.find_child("ScrapMetalPickupC", true, false)
	var wire: Node = vp.find_child("CopperWirePickup", true, false)
	if scrap == null or scrap_b == null or scrap_c == null or wire == null:
		push_error("inventory_crafting_smoke: ScrapMetalPickup(A/B/C) / CopperWirePickup missing on ViewpointPOI")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(scrap) or not InteractionDetector.is_interactable_node(wire):
		push_error("inventory_crafting_smoke: pickups must duck-type Interactable")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(scrap_c):
		push_error("inventory_crafting_smoke: outdoor ScrapMetalPickupC must be interactable")
		quit(1)
		return false
	if str(scrap.call("get_item_id")) != "scrap_metal" or str(wire.call("get_item_id")) != "copper_wire":
		push_error("inventory_crafting_smoke: pickup item_id mismatch")
		quit(1)
		return false
	if str(scrap_c.call("get_item_id")) != "scrap_metal" or int(scrap_c.call("get_quantity")) < 1:
		push_error("inventory_crafting_smoke: outdoor scrap_03 should grant scrap_metal")
		quit(1)
		return false
	var scrap_total := (
		int(scrap.call("get_quantity"))
		+ int(scrap_b.call("get_quantity"))
		+ int(scrap_c.call("get_quantity"))
	)
	if scrap_total < 3:
		push_error("inventory_crafting_smoke: viewpoint scrap pickups total %d < quest need 3" % scrap_total)
		quit(1)
		return false
	if int(wire.call("get_quantity")) < 1:
		push_error("inventory_crafting_smoke: copper wire pickup missing quantity")
		quit(1)
		return false
	if bool(scrap.call("is_collected")) or bool(wire.call("is_collected")):
		push_error("inventory_crafting_smoke: pickups should start uncollected")
		quit(1)
		return false

	# Collect scrap inside booth.
	var scrap_pos: Vector3 = (scrap as Node3D).global_position
	character.global_position = scrap_pos + Vector3(0.0, 0.05, 1.2)
	var face := scrap_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _i in range(12):
		await physics_frame

	var before_scrap := int(inv.call("get_quantity", "scrap_metal"))
	if not bool(scrap.call("interact", character)):
		push_error("inventory_crafting_smoke: Scrap Metal collect failed")
		quit(1)
		return false
	await physics_frame
	if int(inv.call("get_quantity", "scrap_metal")) != before_scrap + 2:
		push_error("inventory_crafting_smoke: scrap_metal quantity not updated in inventory")
		quit(1)
		return false
	if not bool(scrap.call("is_collected")):
		push_error("inventory_crafting_smoke: scrap pickup not marked collected")
		quit(1)
		return false
	if (scrap as Node3D).visible:
		push_error("inventory_crafting_smoke: scrap pickup still visible after collect")
		quit(1)
		return false
	var scrap_msg := str(scrap.get_meta("last_interact_message", ""))
	if scrap_msg.find("+2") < 0 or scrap_msg.find("Scrap") < 0:
		push_error("inventory_crafting_smoke: bad scrap feedback '%s'" % scrap_msg)
		quit(1)
		return false
	# Cannot collect twice.
	if bool(scrap.call("can_interact", character)):
		push_error("inventory_crafting_smoke: scrap still interactable after collect")
		quit(1)
		return false
	if bool(scrap.call("interact", character)):
		push_error("inventory_crafting_smoke: scrap collected twice in same session")
		quit(1)
		return false
	var state: Dictionary = scrap.call("get_collected_state")
	if not bool(state.get("collected", false)) or str(state.get("pickup_id", "")) != "poi.sunset_viewpoint.pickup.scrap_01":
		push_error("inventory_crafting_smoke: scrap collected state snapshot invalid")
		quit(1)
		return false

	# Outdoor scrap (quest overflow / discoverability).
	var scrap_c_pos: Vector3 = (scrap_c as Node3D).global_position
	character.global_position = scrap_c_pos + Vector3(0.0, 0.05, 1.2)
	face = scrap_c_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _oc in range(12):
		await physics_frame
	var before_scrap_c := int(inv.call("get_quantity", "scrap_metal"))
	if not bool(scrap_c.call("interact", character)):
		push_error("inventory_crafting_smoke: outdoor Scrap Metal collect failed")
		quit(1)
		return false
	await physics_frame
	if int(inv.call("get_quantity", "scrap_metal")) != before_scrap_c + int(scrap_c.call("get_quantity")):
		push_error("inventory_crafting_smoke: outdoor scrap quantity not applied")
		quit(1)
		return false

	# Copper wire outside near booth entrance.
	var wire_pos: Vector3 = (wire as Node3D).global_position
	character.global_position = wire_pos + Vector3(0.0, 0.05, 1.2)
	face = wire_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-12.0))
	for _j in range(12):
		await physics_frame

	var before_wire := int(inv.call("get_quantity", "copper_wire"))
	if not bool(wire.call("interact", character)):
		push_error("inventory_crafting_smoke: Copper Wire collect failed")
		quit(1)
		return false
	await physics_frame
	if int(inv.call("get_quantity", "copper_wire")) != before_wire + 1:
		push_error("inventory_crafting_smoke: copper_wire quantity expected +1")
		quit(1)
		return false
	if not bool(wire.call("is_collected")) or bool(wire.call("interact", character)):
		push_error("inventory_crafting_smoke: copper wire reusable after collect")
		quit(1)
		return false
	var wire_msg := str(wire.get_meta("last_interact_message", ""))
	if wire_msg.find("+1") < 0:
		push_error("inventory_crafting_smoke: bad copper feedback '%s'" % wire_msg)
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	if inv.has_method("clear_inventory"):
		inv.call("clear_inventory")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("inventory_crafting_smoke: world items OK (booth scrap + outdoor scrap + copper → inventory)")
	return true



func _verify_workbench(_occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Workbench at Sunset Viewpoint opens CraftingDebugUI; craft via UI selection.
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var craft: Node = root.get_node_or_null("CraftingSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if poi_sys == null or craft == null or inv == null:
		push_error("inventory_crafting_smoke: systems missing for workbench check")
		quit(1)
		return false

	inv.call("clear_inventory")
	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(10.0, 0.0, -4.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("inventory_crafting_smoke: viewpoint spawn failed for workbench")
		quit(1)
		return false

	var bench: Node = vp.find_child("Workbench", true, false)
	if bench == null:
		push_error("inventory_crafting_smoke: Workbench missing at Sunset Viewpoint")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(bench):
		push_error("inventory_crafting_smoke: Workbench is not duck-typed interactable")
		quit(1)
		return false

	var ui: Node = root.find_child("CraftingDebugUI", true, false)
	if ui == null:
		push_error("inventory_crafting_smoke: CraftingDebugUI missing from sandbox")
		quit(1)
		return false

	var bench_pos: Vector3 = (bench as Node3D).global_position
	character.global_position = bench_pos + Vector3(0.0, 0.05, 1.5)
	var face := bench_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _i in range(10):
		await physics_frame

	if not bool(bench.call("can_interact", character)):
		push_error("inventory_crafting_smoke: Workbench can_interact false")
		quit(1)
		return false
	if not bool(bench.call("interact", character)):
		push_error("inventory_crafting_smoke: Workbench interact failed")
		quit(1)
		return false
	await physics_frame
	if not bool(ui.call("is_panel_visible")):
		push_error("inventory_crafting_smoke: CraftingDebugUI did not open from Workbench")
		quit(1)
		return false

	# Recipe appears in catalog list used by UI.
	var ids: PackedStringArray = craft.call("get_recipe_ids")
	if not ("basic_repair_kit" in ids):
		push_error("inventory_crafting_smoke: basic_repair_kit missing from recipe ids for UI")
		quit(1)
		return false

	# Craft with resources while UI open.
	inv.call("add_item", "scrap_metal", 2)
	inv.call("add_item", "copper_wire", 1)
	if not bool(craft.call("craft", "basic_repair_kit")):
		push_error("inventory_crafting_smoke: craft via workbench flow failed")
		quit(1)
		return false
	if int(inv.call("get_quantity", "basic_repair_kit")) != 1:
		push_error("inventory_crafting_smoke: workbench craft did not yield kit")
		quit(1)
		return false

	# Close UI via second interact.
	if not bool(bench.call("interact", character)):
		push_error("inventory_crafting_smoke: Workbench close interact failed")
		quit(1)
		return false
	await physics_frame
	if bool(ui.call("is_panel_visible")):
		push_error("inventory_crafting_smoke: CraftingDebugUI still open after close")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	inv.call("clear_inventory")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("inventory_crafting_smoke: workbench OK (interact → UI → craft → close)")
	return true



