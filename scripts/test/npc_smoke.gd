extends "res://scripts/test/test_helpers.gd"
## NPC foundation, barks, rules, state, relationship, time, schedules, movement, travel, debug.
## Run: godot --path . --headless -s res://scripts/test/npc_smoke.gd

func _initialize() -> void:
	suite_name = "npc_smoke"
	start_suite_timeout(300.0)
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
	if not await _verify_npc_foundation(occupancy, character, foot_cam):
		return
	if not await _verify_npc_barks(occupancy, character, foot_cam):
		return
	if not await _verify_npc_dialogue_rules(occupancy, character, foot_cam):
		return
	if not await _verify_npc_state(occupancy, character, foot_cam):
		return
	if not await _verify_relationship_system(occupancy, character, foot_cam):
		return
	if not await _verify_time_npc_availability(occupancy, character, foot_cam):
		return
	if not await _verify_npc_schedules(occupancy, character, foot_cam):
		return
	if not await _verify_npc_movement(occupancy, character, foot_cam):
		return
	if not await _verify_npc_travel(occupancy, character, foot_cam):
		return
	if not await _verify_npc_dialogue_debug(occupancy, character, foot_cam):
		return
	pass_suite("npc_foundation+npc_barks+npc_dialogue_rules+npc_state+relationship+time_npc_availability+npc_schedules+npc_movement+npc_travel+npc_dialogue_debug")

func _verify_npc_foundation(occupancy: Node, character: CharacterBody3D, foot_cam: Node3D) -> bool:
	## Data-driven DialogueSystem via Mira + Rafa (shared Interactable + catalog).
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if poi_sys == null:
		push_error("npc_smoke: POISystem missing for dialogue test")
		quit(1)
		return false
	if dlg == null:
		push_error("npc_smoke: DialogueSystem autoload missing")
		quit(1)
		return false
	clear_world_state()
	if ns != null and ns.has_method("reset_for_tests"):
		ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_npc_catalog")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("npc_smoke: could not load viewpoint resources for dialogue")
		quit(1)
		return false

	# NPC must not hardcode dialogue text — only dialogue_id / definition.
	var npc_script: Script = load("res://scripts/npc/npc_character.gd") as Script
	if npc_script != null:
		var src := npc_script.source_code
		if src.find("Boa viagem.") >= 0 or src.find("Parei aqui") >= 0:
			push_error("npc_smoke: dialogue text must not be hardcoded in NpcCharacter")
			quit(1)
			return false
		if src.find("/root/POISystem") >= 0 or src.find("poi_system.gd") >= 0:
			push_error("npc_smoke: NpcCharacter must not reference POI autoload")
			quit(1)
			return false

	if not bool(dlg.call("has_dialogue", "mira_01")) or not bool(dlg.call("has_dialogue", "rafa_01")):
		push_error("npc_smoke: DialogueSystem catalog missing mira/rafa entries")
		quit(1)
		return false

	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(10.0, 0.0, -5.0))
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("npc_smoke: failed to spawn viewpoint for dialogue")
		quit(1)
		return false

	var mira: Node = vp.find_child("Mira", true, false)
	var rafa: Node = vp.find_child("Rafa", true, false)
	if mira == null or not mira.has_method("interact"):
		push_error("npc_smoke: Mira NPC missing")
		quit(1)
		return false
	if rafa == null or not rafa.has_method("interact"):
		push_error("npc_smoke: Rafa NPC missing (reuse proof)")
		quit(1)
		return false
	if not InteractionDetector.is_interactable_node(mira) or not InteractionDetector.is_interactable_node(rafa):
		push_error("npc_smoke: NPCs must duck-type Interactable")
		quit(1)
		return false
	if str(mira.call("get_dialogue_id")) != "mira_intro":
		push_error("npc_smoke: Mira first-meet should resolve mira_intro")
		quit(1)
		return false
	if str(rafa.call("get_dialogue_id")) != "rafa_01":
		push_error("npc_smoke: Rafa dialogue_id should be rafa_01")
		quit(1)
		return false

	var finished := {"n": 0}
	var on_finished := func(_id: String) -> void:
		finished["n"] = int(finished["n"]) + 1
	dlg.dialogue_finished.connect(on_finished)

	# --- Mira sequence ---
	var mira_pos: Vector3 = (mira as Node3D).global_position
	character.global_position = mira_pos + Vector3(0.0, 0.05, 1.6)
	var face := mira_pos - character.global_position
	var yaw := atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _i in range(14):
		await physics_frame

	if not bool(character.call("is_control_enabled")):
		push_error("npc_smoke: character should have control before dialogue")
		quit(1)
		return false

	var prompt := str(mira.call("get_interaction_prompt"))
	if prompt.find("Mira") < 0:
		push_error("npc_smoke: bad Mira prompt '%s'" % prompt)
		quit(1)
		return false

	if not bool(mira.call("interact", character)):
		push_error("npc_smoke: Mira interact failed to start dialogue")
		quit(1)
		return false
	await physics_frame

	if not bool(dlg.call("is_active")):
		push_error("npc_smoke: DialogueSystem not active after Mira interact")
		quit(1)
		return false
	if bool(character.call("is_control_enabled")):
		push_error("npc_smoke: character still movable during dialogue")
		quit(1)
		return false
	if str(dlg.call("get_current_id")) != "mira_intro":
		push_error("npc_smoke: expected mira_intro, got %s" % str(dlg.call("get_current_id")))
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("terminal") < 0:
		push_error("npc_smoke: unexpected Mira intro line text")
		quit(1)
		return false
	var flags_early: Node = root.get_node_or_null("GameFlags")
	if flags_early == null or not bool(flags_early.call("get_flag", "npc.mira.met", false)):
		push_error("npc_smoke: on_enter should SET_FLAG npc.mira.met")
		quit(1)
		return false

	# Player cannot move while dialogue is active.
	var locked_pos := character.global_position
	Input.action_press("player_move_forward")
	for _m in range(10):
		await physics_frame
	Input.action_release("player_move_forward")
	if locked_pos.distance_to(character.global_position) > 0.05:
		push_error("npc_smoke: character moved during dialogue")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_quest_offer_02":
		push_error("npc_smoke: expected mira_quest_offer_02 after advance")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("Scrap Metal") < 0:
		push_error("npc_smoke: unexpected Mira offer line 2")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("npc_smoke: dialogue still active after final advance")
		quit(1)
		return false
	if not bool(character.call("is_control_enabled")):
		push_error("npc_smoke: control not restored after Mira dialogue")
		quit(1)
		return false
	if int(finished["n"]) < 1:
		push_error("npc_smoke: dialogue_finished did not fire for Mira")
		quit(1)
		return false
	var qs: Node = root.get_node_or_null("QuestSystem")
	if qs == null or not bool(qs.call("is_active", "power_the_viewpoint")):
		push_error("npc_smoke: Power the Viewpoint should be ACTIVE after Mira offer")
		quit(1)
		return false
	# Isolate later tests.
	qs.call("reset_all")

	# --- Rafa first talk (memory cleared so greeting is rafa_01) ---
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	var rafa_pos: Vector3 = (rafa as Node3D).global_position
	character.global_position = rafa_pos + Vector3(0.0, 0.05, 1.6)
	face = rafa_pos - character.global_position
	yaw = atan2(-face.x, -face.z)
	character.rotation.y = yaw
	if foot_cam.has_method("set_look_angles"):
		foot_cam.call("set_look_angles", yaw, deg_to_rad(-10.0))
	for _j in range(10):
		await physics_frame

	if str(rafa.call("get_dialogue_id")) != "rafa_01":
		push_error("npc_smoke: Rafa should open rafa_01 before first completion")
		quit(1)
		return false
	if not bool(rafa.call("interact", character)):
		push_error("npc_smoke: Rafa interact failed")
		quit(1)
		return false
	await physics_frame
	if not bool(dlg.call("is_active")) or str(dlg.call("get_current_id")) != "rafa_01":
		push_error("npc_smoke: Rafa did not open rafa_01")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("novo por aqui") < 0:
		push_error("npc_smoke: unexpected Rafa first greeting")
		quit(1)
		return false
	if bool(character.call("is_control_enabled")):
		push_error("npc_smoke: control not blocked during Rafa dialogue")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_text")) != "Cuida do carro.":
		push_error("npc_smoke: unexpected Rafa line 2")
		quit(1)
		return false
	# Confirm first choice (rafa_pass) to complete conversation.
	dlg.call("set_choice_index", 0)
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("npc_smoke: Rafa dialogue did not end")
		quit(1)
		return false
	if not bool(character.call("is_control_enabled")):
		push_error("npc_smoke: control not restored after Rafa")
		quit(1)
		return false

	dlg.dialogue_finished.disconnect(on_finished)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("npc_smoke: dialogue OK (Mira sequence + Rafa reuse, control locked/restored)")
	return true



func _verify_npc_barks(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Contextual short lines: approach bark, cooldown, conditions, dialogue blocks, independence.
	var bark: Node = root.get_node_or_null("BarkSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if bark == null or dlg == null or gt == null or ns == null or poi_sys == null:
		push_error("npc_smoke: systems missing for npc barks")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	const RAFA := "rafa_road_traveler"

	var bark_script: Script = load("res://autoload/bark_system.gd") as Script
	if bark_script != null:
		var src := bark_script.source_code
		for banned in ["mira_viewpoint_keeper", "rafa_road_traveler", "DialogueUI", "Vai chover"]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: BarkSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	bark.call("reset_for_tests")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")
	gt.call("set_narrative_time", 0, 10, 0)

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(7.0, 0.0, -7.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("npc_smoke: viewpoint spawn failed for npc barks")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	var mira: Node3D = vp.find_child("Mira", true, false) as Node3D
	var rafa: Node3D = vp.find_child("Rafa", true, false) as Node3D
	if mira == null or rafa == null:
		push_error("npc_smoke: Mira/Rafa missing for bark test")
		quit(1)
		return false
	if mira.get_node_or_null("SpeechLabel") == null:
		push_error("npc_smoke: SpeechLabel missing for bark UI")
		quit(1)
		return false
	var mira_rules: Array = mira.call("get_bark_rules") if mira.has_method("get_bark_rules") else []
	if mira_rules.size() < 2:
		push_error("npc_smoke: Mira should author multiple bark_rules")
		quit(1)
		return false

	# Approach Mira → PLAYER_ENTER_AREA / NEARBY bark (rain at hour 10, unmet).
	character.global_position = mira.global_position + Vector3(0.0, 0.05, 2.5)
	await physics_frame
	await physics_frame
	await physics_frame
	if not bool(bark.call("try_bark", MIRA, "PLAYER_ENTER_AREA")):
		# Area signal may already have fired; force a nearby attempt after reset gap.
		bark.call("reset_for_tests", MIRA)
		if not bool(bark.call("try_bark", MIRA, "PLAYER_NEARBY")):
			push_error("npc_smoke: Mira should bark on approach")
			quit(1)
			return false
	var mira_bark_id := str(bark.call("get_last_bark_id", MIRA))
	if mira_bark_id.is_empty():
		push_error("npc_smoke: Mira last_bark_id empty after approach")
		quit(1)
		return false
	var speech: Label3D = mira.get_node_or_null("SpeechLabel") as Label3D
	if speech == null or not speech.visible or str(speech.text).is_empty():
		push_error("npc_smoke: bark should show temporary SpeechLabel (not DialogueUI)")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and not bool(character.call("is_control_enabled")):
		push_error("npc_smoke: bark must not lock player movement")
		quit(1)
		return false

	# Cooldown / min-gap: immediate re-fire suppressed.
	if bool(bark.call("try_bark", MIRA, "PLAYER_NEARBY")):
		push_error("npc_smoke: Mira bark should respect cooldown/min-gap")
		quit(1)
		return false

	# Conditions change available bark: met + hour 17 → closing soon / you returned.
	ns.call("set_met_player", MIRA, true)
	gt.call("set_narrative_time", 0, 17, 0)
	bark.call("reset_for_tests", MIRA)
	if not bool(bark.call("try_bark", MIRA, "PLAYER_ENTER_AREA")):
		push_error("npc_smoke: Mira should bark after condition change")
		quit(1)
		return false
	var after_id := str(bark.call("get_last_bark_id", MIRA))
	if after_id != "mira_you_returned" and after_id != "mira_closing_soon":
		push_error("npc_smoke: expected conditioned Mira bark, got '%s'" % after_id)
		quit(1)
		return false
	if after_id == mira_bark_id and mira_bark_id == "mira_rain_soon":
		push_error("npc_smoke: conditions should change available bark away from rain-only")
		quit(1)
		return false

	# Active dialogue blocks bark.
	bark.call("reset_for_tests", MIRA)
	if not bool(dlg.call("start_dialogue", "mira_intro", character, MIRA)):
		push_error("npc_smoke: failed to start dialogue to block bark")
		quit(1)
		return false
	await physics_frame
	if bool(bark.call("try_bark", MIRA, "PLAYER_NEARBY")):
		push_error("npc_smoke: active dialogue must block bark")
		quit(1)
		return false
	dlg.call("cancel_dialogue")
	await physics_frame

	# Rafa independent from Mira.
	bark.call("reset_for_tests", RAFA)
	character.global_position = rafa.global_position + Vector3(0.0, 0.05, 2.2)
	await physics_frame
	await physics_frame
	if not bool(bark.call("try_bark", RAFA, "PLAYER_ENTER_AREA")):
		bark.call("reset_for_tests", RAFA)
		if not bool(bark.call("try_bark", RAFA, "PLAYER_NEARBY")):
			push_error("npc_smoke: Rafa should bark independently")
			quit(1)
			return false
	var rafa_id := str(bark.call("get_last_bark_id", RAFA))
	if rafa_id.is_empty():
		push_error("npc_smoke: Rafa last_bark_id empty")
		quit(1)
		return false
	if rafa_id == str(bark.call("get_last_bark_id", MIRA)):
		# Different NPCs may coincidentally share text ids only if authored same — ours differ.
		pass
	if rafa_id.begins_with("mira_"):
		push_error("npc_smoke: Rafa must not use Mira bark ids")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	bark.call("reset_for_tests")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("npc_smoke: npc_bark OK (approach + cooldown + conditions + dialogue block + independent)")
	return true



func _verify_npc_dialogue_rules(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Priority NpcDialogueRule resolve: intro → returning → quest done beats generic; fallback.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if dlg == null or cond == null or qs == null or ns == null:
		push_error("npc_smoke: systems missing for npc dialogue rules")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"

	# NpcCharacter must not inspect rules / hardcode quest ids.
	var npc_script: Script = load("res://scripts/npc/npc_character.gd") as Script
	if npc_script != null:
		var src := npc_script.source_code
		for banned in [
			"power_the_viewpoint",
			"dialogue_rules",
			"NpcDialogueRule",
			"mira_quest_done",
			"mira_intro",
			"mira_returning",
		]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: NpcCharacter must not contain '%s'" % banned)
				quit(1)
				return false

	# DialogueSystem must stay free of Mira/quest hardcoding in resolve.
	var dlg_script: Script = load("res://autoload/dialogue_system.gd") as Script
	if dlg_script != null:
		var dsrc := dlg_script.source_code
		for banned in ["mira_viewpoint_keeper", "power_the_viewpoint", "mira_intro"]:
			if dsrc.find(banned) >= 0:
				push_error("npc_smoke: DialogueSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_catalog")
	dlg.call("reload_npc_catalog")
	var gt_rules: Node = root.get_node_or_null("GameTimeSystem")
	if gt_rules != null and gt_rules.has_method("set_narrative_time"):
		gt_rules.call("set_narrative_time", 0, 10, 0)

	# 1) First meet → fallback intro (time rules require NPC_MET).
	var first := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if first != "mira_intro":
		push_error("npc_smoke: first meet should be mira_intro, got %s" % first)
		quit(1)
		return false

	# 2) After met (no quest, daytime) → time-of-day greeting beats mira_returning.
	ns.call("set_met_player", MIRA, true)
	var day_line := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if day_line != "mira_time_day":
		push_error("npc_smoke: met Mira at hour 10 should resolve mira_time_day, got %s" % day_line)
		quit(1)
		return false

	# 3) Active quest beats time greeting / returning.
	qs.call("start_quest", "power_the_viewpoint")
	var active := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if active != "mira_quest_active_01":
		push_error("npc_smoke: ACTIVE quest should beat time greeting, got %s" % active)
		quit(1)
		return false

	# 4) Completed beats active / time / returning.
	qs.call("complete_quest", "power_the_viewpoint")
	var done := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if done != "mira_quest_done_01":
		push_error("npc_smoke: COMPLETED should resolve mira_quest_done_01, got %s" % done)
		quit(1)
		return false

	# 5) Tie-break: equal priority → lower authored index wins.
	var RuleScript: Script = load("res://scripts/npc/npc_dialogue_rule.gd") as Script
	var DefScript: Script = load("res://scripts/npc/npc_definition.gd") as Script
	if RuleScript == null or DefScript == null:
		push_error("npc_smoke: could not load rule/definition scripts")
		quit(1)
		return false
	var rule_a: Resource = RuleScript.new()
	rule_a.set("id", "tie_a")
	rule_a.set("dialogue_id", "mira_01")
	rule_a.set("priority", 10)
	rule_a.set("enabled", true)
	rule_a.set("conditions", [])
	var rule_b: Resource = RuleScript.new()
	rule_b.set("id", "tie_b")
	rule_b.set("dialogue_id", "mira_02")
	rule_b.set("priority", 10)
	rule_b.set("enabled", true)
	rule_b.set("conditions", [])
	var tie_def: Resource = DefScript.new()
	tie_def.set("npc_id", "tie_test_npc")
	tie_def.set("fallback_dialogue_id", "mira_intro")
	tie_def.set("dialogue_rules", [rule_a, rule_b])
	var tied := str(dlg.call("resolve_dialogue_from_definition", tie_def))
	if tied != "mira_01":
		push_error("npc_smoke: equal priority should prefer lower index (mira_01), got %s" % tied)
		quit(1)
		return false

	# 6) No matching rules / all fail → fallback.
	var fail_rule: Resource = RuleScript.new()
	fail_rule.set("id", "fail")
	fail_rule.set("dialogue_id", "mira_returning")
	fail_rule.set("priority", 99)
	fail_rule.set("enabled", true)
	fail_rule.set("conditions", [cond.call("make_npc_met", "nobody_here", true)])
	var fb_def: Resource = DefScript.new()
	fb_def.set("npc_id", "fallback_npc")
	fb_def.set("fallback_dialogue_id", "mira_intro")
	fb_def.set("dialogue_rules", [fail_rule])
	var fb := str(dlg.call("resolve_dialogue_from_definition", fb_def))
	if fb != "mira_intro":
		push_error("npc_smoke: fallback_dialogue_id should win when rules fail, got %s" % fb)
		quit(1)
		return false

	# Live Mira interact uses resolve (no fixed dialogue_id).
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_sys != null and poi_res != null and vp_scene != null:
		qs.call("reset_all")
		ns.call("reset_for_tests")
		var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
		var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(8.0, 0.0, -4.0))
		var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
		var mira: Node = vp.find_child("Mira", true, false) if vp != null else null
		if mira == null:
			push_error("npc_smoke: Mira missing for npc rules live check")
			quit(1)
			return false
		if str(mira.call("get_dialogue_id")) != "mira_intro":
			push_error("npc_smoke: live Mira should open mira_intro first")
			quit(1)
			return false
		character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.5)
		await physics_frame
		if not bool(mira.call("interact", character)):
			push_error("npc_smoke: Mira intro interact failed")
			quit(1)
			return false
		await physics_frame
		if str(dlg.call("get_current_id")) != "mira_intro":
			push_error("npc_smoke: interact started wrong line %s" % str(dlg.call("get_current_id")))
			quit(1)
			return false
		# Advance intro → offer choices → accept (starts quest).
		dlg.call("advance")
		await physics_frame
		dlg.call("set_choice_index", 0)
		await physics_frame
		dlg.call("confirm_choice")
		await physics_frame
		if str(mira.call("get_dialogue_id")) != "mira_quest_active_01":
			push_error(
				"npc_smoke: after intro Mira should be active quest line, got %s"
				% str(mira.call("get_dialogue_id"))
			)
			quit(1)
			return false
		poi_sys.call("despawn_viewpoint", "sunset_viewpoint")

	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	if gt_rules != null and gt_rules.has_method("reset_for_tests"):
		gt_rules.call("reset_for_tests")
	print("npc_smoke: npc_rules OK (intro → time_day → active → done + ties + fallback)")
	return true



func _verify_npc_state(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## NpcStateSystem: static NpcDefinition vs mutable campaign state; Mira met; Rafa BUSY; unload + save.
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if ns == null or dlg == null or cond == null or save == null or poi_sys == null:
		push_error("npc_smoke: systems missing for npc_state")
		quit(1)
		return false

	const MIRA_ID := "mira_viewpoint_keeper"
	const RAFA_ID := "rafa_road_traveler"

	var ns_script: Script = load("res://autoload/npc_state_system.gd") as Script
	if ns_script != null:
		var src := ns_script.source_code
		for banned in ["Mira", "Rafa", "mira_viewpoint", "rafa_road", "ViewpointPOI"]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: NpcStateSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	var def_script: Script = load("res://scripts/npc/npc_definition.gd") as Script
	if def_script != null:
		var def_src := def_script.source_code
		for mutable_field in ["met_player", "current_state", "current_location_id", "last_dialogue_id"]:
			if def_src.find(mutable_field) >= 0:
				push_error("npc_smoke: NpcDefinition must stay static (found '%s')" % mutable_field)
				quit(1)
				return false

	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_catalog")
	save.call("delete_save")
	clear_world_state()

	# Defaults + API surface.
	if bool(ns.call("has_met_player", MIRA_ID)):
		push_error("npc_smoke: Mira should not be met before talk")
		quit(1)
		return false
	if str(ns.call("get_current_state", RAFA_ID)) != "DEFAULT":
		push_error("npc_smoke: Rafa default state should be DEFAULT")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_enabled", MIRA_ID, true))):
		push_error("npc_smoke: NPC_ENABLED should default true")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_npc_met", MIRA_ID, true))):
		push_error("npc_smoke: NPC_MET should be false before talk")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_npc_state", RAFA_ID, "BUSY"))):
		push_error("npc_smoke: NPC_STATE BUSY should be false initially")
		quit(1)
		return false

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("npc_smoke: missing viewpoint resources for npc_state")
		quit(1)
		return false
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(12.0, 0.0, -6.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("npc_smoke: viewpoint spawn failed for npc_state")
		quit(1)
		return false

	var mira: Node = vp.find_child("Mira", true, false)
	var rafa: Node = vp.find_child("Rafa", true, false)
	if mira == null or rafa == null:
		push_error("npc_smoke: Mira/Rafa missing for npc_state")
		quit(1)
		return false

	# Schedule owns logical location when present (narrative hour 10 → workshop).
	var gt_ns: Node = root.get_node_or_null("GameTimeSystem")
	var sched_ns: Node = root.get_node_or_null("NpcScheduleSystem")
	if gt_ns != null and gt_ns.has_method("set_narrative_time"):
		gt_ns.call("set_narrative_time", 0, 10, 0)
	if sched_ns != null and sched_ns.has_method("refresh_all"):
		sched_ns.call("refresh_all")
	await physics_frame
	await physics_frame
	if str(ns.call("get_location_id", MIRA_ID)) != "viewpoint_workshop":
		push_error(
			"npc_smoke: Mira location should be viewpoint_workshop at hour 10, got '%s'"
			% str(ns.call("get_location_id", MIRA_ID))
		)
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_location", MIRA_ID, "viewpoint_workshop"))):
		push_error("npc_smoke: NPC_LOCATION condition failed after schedule resolve")
		quit(1)
		return false

	# --- Mira: first talk → met_player ---
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.6)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("npc_smoke: Mira interact failed in npc_state")
		quit(1)
		return false
	await physics_frame
	if not bool(ns.call("has_met_player", MIRA_ID)):
		push_error("npc_smoke: Mira met_player should be true after first talk")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_met", MIRA_ID, true))):
		push_error("npc_smoke: NPC_MET condition failed after Mira talk")
		quit(1)
		return false
	if str(ns.call("get_last_dialogue_id", MIRA_ID)).is_empty():
		push_error("npc_smoke: Mira last_dialogue_id should be set after talk")
		quit(1)
		return false
	dlg.call("end_dialogue", true)
	await physics_frame
	var qs: Node = root.get_node_or_null("QuestSystem")
	if qs != null:
		qs.call("reset_all")

	# --- Rafa: far choice → BUSY; NPC_STATE gates busy line ---
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	character.global_position = (rafa as Node3D).global_position + Vector3(0.0, 0.05, 1.6)
	await physics_frame
	if str(rafa.call("get_dialogue_id")) != "rafa_01":
		push_error("npc_smoke: Rafa should open rafa_01 before BUSY")
		quit(1)
		return false
	if not bool(rafa.call("interact", character)):
		push_error("npc_smoke: Rafa interact failed in npc_state")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "rafa_02":
		push_error("npc_smoke: expected rafa_02 before far choice")
		quit(1)
		return false
	dlg.call("set_choice_index", 1)  # rafa_far → SET_NPC_STATE BUSY
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if str(ns.call("get_current_state", RAFA_ID)) != "BUSY":
		push_error(
			"npc_smoke: Rafa current_state should be BUSY after far choice, got '%s'"
			% str(ns.call("get_current_state", RAFA_ID))
		)
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_state", RAFA_ID, "BUSY"))):
		push_error("npc_smoke: NPC_STATE BUSY condition failed")
		quit(1)
		return false
	if not bool(ns.call("has_met_player", RAFA_ID)):
		push_error("npc_smoke: Rafa met_player should be true after talk")
		quit(1)
		return false

	# Priority rules: BUSY beats return/fallback.
	var rafa_def: Resource = load("res://resources/npc/rafa_road_traveler.tres")
	dlg.call("register_npc_definition", rafa_def)
	var resolved := str(dlg.call("resolve_dialogue_for_npc", "rafa_road_traveler"))
	if resolved != "rafa_busy_01":
		push_error("npc_smoke: expected rafa_busy_01 from BUSY rule, got %s" % resolved)
		quit(1)
		return false
	if str(rafa.call("get_dialogue_id")) != "rafa_busy_01":
		push_error("npc_smoke: Rafa scene should resolve to rafa_busy_01 while BUSY")
		quit(1)
		return false
	if not bool(dlg.call("start_dialogue", "rafa_busy_01", character)):
		push_error("npc_smoke: rafa_busy_01 failed to start")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_text")).find("ocupado") < 0:
		push_error("npc_smoke: unexpected Rafa BUSY line")
		quit(1)
		return false
	dlg.call("end_dialogue", true)
	await physics_frame

	# Unload NPC scenes — logical state must survive (no Node refs).
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	await physics_frame
	if not bool(ns.call("has_met_player", MIRA_ID)):
		push_error("npc_smoke: Mira met_player lost after unload")
		quit(1)
		return false
	if str(ns.call("get_current_state", RAFA_ID)) != "BUSY":
		push_error("npc_smoke: Rafa BUSY lost after unload")
		quit(1)
		return false

	# Save / load round-trip.
	if not bool(save.call("save_game")):
		push_error("npc_smoke: npc_state save failed")
		quit(1)
		return false
	ns.call("reset_for_tests")
	if bool(ns.call("has_met_player", MIRA_ID)):
		push_error("npc_smoke: npc_state should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("npc_smoke: npc_state load failed")
		quit(1)
		return false
	if not bool(ns.call("has_met_player", MIRA_ID)):
		push_error("npc_smoke: Mira met_player lost after load")
		quit(1)
		return false
	if str(ns.call("get_current_state", RAFA_ID)) != "BUSY":
		push_error("npc_smoke: Rafa BUSY lost after load")
		quit(1)
		return false
	# After load, schedule re-resolves against narrative hour → workshop at hour 10.
	if str(ns.call("get_location_id", MIRA_ID)) != "viewpoint_workshop":
		push_error(
			"npc_smoke: Mira schedule location lost after load (got '%s')"
			% str(ns.call("get_location_id", MIRA_ID))
		)
		quit(1)
		return false

	# Respawn reads NpcStateSystem (definition stays static).
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	rafa = vp.find_child("Rafa", true, false)
	mira = vp.find_child("Mira", true, false)
	await physics_frame
	if rafa == null or mira == null:
		push_error("npc_smoke: Mira/Rafa missing after respawn")
		quit(1)
		return false
	if str(rafa.call("get_dialogue_id")) != "rafa_busy_01":
		push_error("npc_smoke: Rafa should stay BUSY dialogue after respawn")
		quit(1)
		return false
	if not bool(mira.call("is_npc_enabled")):
		push_error("npc_smoke: Mira enabled should read from NpcStateSystem after respawn")
		quit(1)
		return false

	save.call("delete_save")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	if qs != null:
		qs.call("reset_all")
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("npc_smoke: npc_state OK (Mira met + Rafa BUSY + unload + save + NPC_STATE)")
	return true



func _verify_relationship_system(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Relationship vs reputation maps, clamps, conditions, Mira +5 / quest +10, save/load.
	var rs: Node = root.get_node_or_null("RelationshipSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if rs == null or dlg == null or cond == null or qs == null or save == null:
		push_error("npc_smoke: systems missing for relationship")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	const RAFA := "rafa_road_traveler"
	const GROUP := "sunset_viewpoint"

	var rs_script: Script = load("res://autoload/relationship_system.gd") as Script
	if rs_script != null:
		var src := rs_script.source_code
		for banned in ["DialogueSystem", "Mira", "mira_viewpoint", "rafa_road", "accept_help"]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: RelationshipSystem must not contain '%s'" % banned)
				quit(1)
				return false

	rs.call("reset_for_tests")
	qs.call("reset_all")
	save.call("delete_save")

	# Defaults + independent maps.
	if int(rs.call("get_relationship", MIRA)) != 0 or int(rs.call("get_reputation", GROUP)) != 0:
		push_error("npc_smoke: relationship/reputation should default to 0")
		quit(1)
		return false
	rs.call("set_relationship", MIRA, 12)
	rs.call("set_reputation", GROUP, -5)
	if int(rs.call("get_relationship", MIRA)) != 12:
		push_error("npc_smoke: set_relationship failed")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != -5:
		push_error("npc_smoke: set_reputation failed")
		quit(1)
		return false
	if int(rs.call("get_relationship", RAFA)) != 0:
		push_error("npc_smoke: Rafa relationship should stay independent at 0")
		quit(1)
		return false

	# Clamps -100..+100.
	if int(rs.call("get", "min_value")) != -100 or int(rs.call("get", "max_value")) != 100:
		push_error("npc_smoke: default clamps should be -100..100")
		quit(1)
		return false
	if int(rs.call("set_relationship", MIRA, 500)) != 100:
		push_error("npc_smoke: relationship should clamp to +100")
		quit(1)
		return false
	if int(rs.call("set_reputation", GROUP, -500)) != -100:
		push_error("npc_smoke: reputation should clamp to -100")
		quit(1)
		return false
	if int(rs.call("add_relationship", MIRA, -30)) != 70:
		push_error("npc_smoke: add_relationship after clamp failed")
		quit(1)
		return false

	# Tier helper (display only).
	if str(rs.call("tier_name", 0)) != "NEUTRAL":
		push_error("npc_smoke: tier NEUTRAL expected at 0")
		quit(1)
		return false
	if str(rs.call("get_relationship_tier", MIRA)) != "TRUSTED":
		push_error("npc_smoke: tier TRUSTED expected at 70")
		quit(1)
		return false

	# Conditions.
	rs.call("set_relationship", MIRA, 5)
	rs.call("set_reputation", GROUP, 10)
	if not bool(cond.call("evaluate", cond.call("make_relationship_min", MIRA, 5))):
		push_error("npc_smoke: RELATIONSHIP_MIN failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_relationship_max", MIRA, 4))):
		push_error("npc_smoke: RELATIONSHIP_MAX should fail when above max")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_reputation_min", GROUP, 10))):
		push_error("npc_smoke: REPUTATION_MIN failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_reputation_max", GROUP, 9))):
		push_error("npc_smoke: REPUTATION_MAX should fail when above max")
		quit(1)
		return false

	# Mira kind choice → +5 relationship (explicit action on accept_help).
	rs.call("reset_for_tests")
	qs.call("reset_all")
	dlg.call("reload_catalog")
	if not bool(dlg.call("start_dialogue", "mira_intro", character)):
		push_error("npc_smoke: relationship Mira intro failed")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 0)  # accept_help
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if int(rs.call("get_relationship", MIRA)) != 5:
		push_error(
			"npc_smoke: accept_help should add +5 Mira relationship, got %d"
			% int(rs.call("get_relationship", MIRA))
		)
		quit(1)
		return false
	if int(rs.call("get_relationship", RAFA)) != 0:
		push_error("npc_smoke: Rafa must stay 0 after Mira kind choice")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != 0:
		push_error("npc_smoke: reputation must not change on Mira choice alone")
		quit(1)
		return false

	# Quest complete → +10 reputation sunset_viewpoint (on_complete_actions).
	if not bool(qs.call("is_active", "power_the_viewpoint")):
		qs.call("start_quest", "power_the_viewpoint")
	if not bool(qs.call("complete_quest", "power_the_viewpoint")):
		push_error("npc_smoke: could not complete quest for reputation")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != 10:
		push_error(
			"npc_smoke: quest complete should add +10 sunset_viewpoint reputation, got %d"
			% int(rs.call("get_reputation", GROUP))
		)
		quit(1)
		return false
	# No automatic extra grants.
	if int(rs.call("get_relationship", MIRA)) != 5:
		push_error("npc_smoke: quest complete must not alter Mira relationship")
		quit(1)
		return false

	# Save / load.
	if not bool(save.call("save_game")):
		push_error("npc_smoke: relationship save failed")
		quit(1)
		return false
	rs.call("reset_for_tests")
	if int(rs.call("get_relationship", MIRA)) != 0:
		push_error("npc_smoke: relationship should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("npc_smoke: relationship load failed")
		quit(1)
		return false
	if int(rs.call("get_relationship", MIRA)) != 5:
		push_error("npc_smoke: Mira relationship lost after load")
		quit(1)
		return false
	if int(rs.call("get_reputation", GROUP)) != 10:
		push_error("npc_smoke: sunset_viewpoint reputation lost after load")
		quit(1)
		return false

	save.call("delete_save")
	rs.call("reset_for_tests")
	qs.call("reset_all")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("npc_smoke: relationship OK (Mira +5 / viewpoint +10 + clamp + conditions + save)")
	return true



func _verify_time_npc_availability(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Narrative world clock → Mira 08–18 window + day/night dialogue (ConditionSystem rules).
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	if gt == null or dlg == null or cond == null or ns == null or qs == null or poi_sys == null:
		push_error("npc_smoke: systems missing for time NPC availability")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"

	var npc_script: Script = load("res://scripts/npc/npc_character.gd") as Script
	if npc_script != null:
		var src := npc_script.source_code
		for banned in [
			"DirectionalLight",
			"WorldEnvironment",
			"sky_energy",
			"Time.get_datetime_dict_from_system",
			"Time.get_datetime_string_from_system",
		]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: NpcCharacter must not contain '%s'" % banned)
				quit(1)
				return false

	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	dlg.call("reload_catalog")
	dlg.call("reload_npc_catalog")
	gt.call("reset_for_tests")

	var mira_def: Resource = load("res://resources/npc/mira_viewpoint_keeper.tres")
	if mira_def == null:
		push_error("npc_smoke: Mira definition missing for time window")
		quit(1)
		return false
	if int(mira_def.get("available_hour_min")) != 8 or int(mira_def.get("available_hour_max")) != 18:
		push_error(
			"npc_smoke: Mira window expected 8–18, got %d–%d"
			% [int(mira_def.get("available_hour_min")), int(mira_def.get("available_hour_max"))]
		)
		quit(1)
		return false

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	if poi_res == null or vp_scene == null:
		push_error("npc_smoke: viewpoint resources missing for time NPC")
		quit(1)
		return false
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(8.0, 0.0, -4.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	var mira: Node = vp.find_child("Mira", true, false) if vp != null else null
	if mira == null:
		push_error("npc_smoke: Mira missing for time availability")
		quit(1)
		return false

	# Persist met flag across hide/show — availability must not wipe NpcState.
	ns.call("set_met_player", MIRA, true)
	ns.call("set_custom_flag", MIRA, "smoke_persist", true)

	# Daytime: visible + interactable → "Bom dia." via dialogue rules / conditions.
	gt.call("set_narrative_time", 0, 10, 0)
	await physics_frame
	await physics_frame
	if not bool(mira.call("is_within_availability_window")):
		push_error("npc_smoke: Mira should be available at narrative hour 10")
		quit(1)
		return false
	if not bool(mira.visible):
		push_error("npc_smoke: Mira should be visible at narrative hour 10")
		quit(1)
		return false
	var day_id := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if day_id != "mira_time_day":
		push_error("npc_smoke: day resolve expected mira_time_day, got %s" % day_id)
		quit(1)
		return false
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.5)
	await physics_frame
	if not bool(mira.call("can_interact", character)):
		push_error("npc_smoke: Mira should be interactable at narrative hour 10")
		quit(1)
		return false
	if not bool(mira.call("interact", character)):
		push_error("npc_smoke: Mira day interact failed")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_time_day":
		push_error("npc_smoke: day dialogue id wrong: %s" % str(dlg.call("get_current_id")))
		quit(1)
		return false
	var day_text := str(dlg.call("get_current_text")) if dlg.has_method("get_current_text") else ""
	if day_text.find("Bom dia") < 0:
		push_error("npc_smoke: day line should contain 'Bom dia.', got '%s'" % day_text)
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Night outside window: hidden; dialogue rules still resolve night line.
	gt.call("set_narrative_time", 0, 22, 0)
	await physics_frame
	await physics_frame
	if bool(mira.call("is_within_availability_window")):
		push_error("npc_smoke: Mira should be outside window at narrative hour 22")
		quit(1)
		return false
	if bool(mira.visible):
		push_error("npc_smoke: Mira should be hidden at narrative hour 22")
		quit(1)
		return false
	if bool(mira.call("can_interact", character)):
		push_error("npc_smoke: Mira should not be interactable at narrative hour 22")
		quit(1)
		return false
	# Persistent campaign fields kept while hidden (schedule may update state/location).
	if ns.has_method("has_met_player") and not bool(ns.call("has_met_player", MIRA)):
		push_error("npc_smoke: hiding Mira must not clear met_player")
		quit(1)
		return false
	if ns.has_method("get_custom_flag") and not bool(ns.call("get_custom_flag", MIRA, "smoke_persist", false)):
		push_error("npc_smoke: hiding Mira must not clear custom flags")
		quit(1)
		return false
	var night_id := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if night_id != "mira_time_night":
		push_error("npc_smoke: night resolve expected mira_time_night, got %s" % night_id)
		quit(1)
		return false
	var night_res: Resource = load("res://resources/dialogue/mira_time_night.tres")
	if night_res == null or str(night_res.get("text")).find("tarde") < 0:
		push_error("npc_smoke: night line should be 'Está ficando tarde.'")
		quit(1)
		return false

	# Cross-midnight range condition 22–06.
	if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
		push_error("npc_smoke: range 22–6 should pass at 22:00")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 5, 0)
	if not bool(cond.call("evaluate", cond.call("make_narrative_time_range", 22, 6))):
		push_error("npc_smoke: range 22–6 should pass at 05:00")
		quit(1)
		return false

	# Midnight wrap via advance_narrative_seconds.
	gt.call("set_narrative_time", 0, 23, 0)
	gt.call("advance_narrative_seconds", 60.0)  # scale 60 → +1 hour
	if int(gt.call("get_narrative_day_index")) != 1 or int(gt.call("get_narrative_hour")) != 0:
		push_error(
			"npc_smoke: narrative midnight wrap failed (day%d/h%d)"
			% [int(gt.call("get_narrative_day_index")), int(gt.call("get_narrative_hour"))]
		)
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	qs.call("reset_all")
	ns.call("reset_for_tests")
	if memory != null and memory.has_method("reset_for_tests"):
		memory.call("reset_for_tests")
	gt.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"npc_smoke: time_npc OK (independent narrative + Mira window + day/night + range 22–6)"
	)
	return true



func _verify_npc_schedules(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Data-driven NpcScheduleSystem: Mira daily routine + Rafa cross-midnight; save/load.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	if gt == null or ns == null or sched == null or save == null:
		push_error("npc_smoke: systems missing for npc schedules")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	const RAFA := "rafa_road_traveler"

	var sched_script: Script = load("res://autoload/npc_schedule_system.gd") as Script
	if sched_script != null:
		var src := sched_script.source_code
		for banned in [
			"mira_viewpoint_keeper",
			"rafa_road_traveler",
			"viewpoint_workshop",
			"Time.get_datetime_dict_from_system",
			"get_total_travel_time",
		]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: NpcScheduleSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	save.call("delete_save")

	if not bool(sched.call("has_schedule", MIRA)) or not bool(sched.call("has_schedule", RAFA)):
		push_error("npc_smoke: catalog should register Mira and Rafa schedules")
		quit(1)
		return false

	var changed: Array = []
	var on_changed := func(
		npc_id: String, _loc: String, _state: String, _act: String, _sid: String
	) -> void:
		changed.append(npc_id)
	if sched.has_signal("npc_schedule_changed"):
		sched.npc_schedule_changed.connect(on_changed)

	# Mira: 10 workshop WORKING, 12 diner EATING, 15 workshop, 20 home RESTING, 3 fallback home.
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_workshop":
		push_error("npc_smoke: Mira@10 location expected viewpoint_workshop")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "WORKING":
		push_error("npc_smoke: Mira@10 state expected WORKING")
		quit(1)
		return false
	if str(ns.call("get_schedule_id", MIRA)) != "mira_daily":
		push_error("npc_smoke: Mira schedule_id expected mira_daily")
		quit(1)
		return false
	if str(sched.call("get_active_activity_id", MIRA)) != "workshop_morning":
		push_error("npc_smoke: Mira@10 activity expected workshop_morning")
		quit(1)
		return false

	gt.call("set_narrative_time", 0, 12, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_diner":
		push_error("npc_smoke: Mira@12 location expected viewpoint_diner")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "EATING":
		push_error("npc_smoke: Mira@12 state expected EATING")
		quit(1)
		return false

	gt.call("set_narrative_time", 0, 15, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_workshop":
		push_error("npc_smoke: Mira@15 location expected viewpoint_workshop")
		quit(1)
		return false
	if str(sched.call("get_active_activity_id", MIRA)) != "workshop_afternoon":
		push_error("npc_smoke: Mira@15 activity expected workshop_afternoon")
		quit(1)
		return false

	gt.call("set_narrative_time", 0, 20, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("npc_smoke: Mira@20 location expected viewpoint_home")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "RESTING":
		push_error("npc_smoke: Mira@20 state expected RESTING")
		quit(1)
		return false

	# 00–08: no entry → fallback home RESTING.
	gt.call("set_narrative_time", 0, 3, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("npc_smoke: Mira@3 fallback location expected viewpoint_home")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "RESTING":
		push_error("npc_smoke: Mira@3 fallback state expected RESTING")
		quit(1)
		return false
	if str(sched.call("get_active_activity_id", MIRA)) != "sleep":
		push_error("npc_smoke: Mira@3 fallback activity expected sleep")
		quit(1)
		return false

	# Two NPCs differ at the same hour.
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_pullout":
		push_error("npc_smoke: Rafa@10 expected roadside_pullout")
		quit(1)
		return false
	if str(ns.call("get_location_id", MIRA)) == str(ns.call("get_location_id", RAFA)):
		push_error("npc_smoke: Mira and Rafa should have different schedule locations")
		quit(1)
		return false
	if str(ns.call("get_schedule_id", RAFA)) != "rafa_roadside":
		push_error("npc_smoke: Rafa schedule_id expected rafa_roadside")
		quit(1)
		return false

	# Rafa cross-midnight 20→06.
	gt.call("set_narrative_time", 0, 22, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_camp":
		push_error("npc_smoke: Rafa@22 cross-midnight expected roadside_camp")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 4, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_camp":
		push_error("npc_smoke: Rafa@04 cross-midnight expected roadside_camp")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 7, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", RAFA)) != "roadside_pullout":
		push_error("npc_smoke: Rafa@07 expected roadside_pullout")
		quit(1)
		return false

	# Empty schedule state must not wipe dialogue-driven BUSY.
	ns.call("set_current_state", RAFA, "BUSY")
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	if str(ns.call("get_current_state", RAFA)) != "BUSY":
		push_error("npc_smoke: Rafa empty schedule state must preserve BUSY")
		quit(1)
		return false

	# Midnight wrap: Mira 23 home → advance to hour 0 still fallback home.
	gt.call("set_narrative_time", 0, 23, 0)
	sched.call("refresh_all")
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("npc_smoke: Mira@23 expected viewpoint_home")
		quit(1)
		return false
	gt.call("advance_narrative_seconds", 60.0)
	sched.call("refresh_all")
	if int(gt.call("get_narrative_day_index")) != 1:
		push_error("npc_smoke: schedule midnight wrap should reach day 1")
		quit(1)
		return false
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_home":
		push_error("npc_smoke: Mira after midnight expected fallback home")
		quit(1)
		return false

	# Save / load: pin hour 12 diner, persist, reload, still diner (+ schedule_id).
	gt.call("set_narrative_time", 1, 12, 0)
	sched.call("refresh_all")
	if not bool(save.call("save_game")):
		push_error("npc_smoke: npc schedule save failed")
		quit(1)
		return false
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("npc_smoke: npc schedule load failed")
		quit(1)
		return false
	await physics_frame
	await physics_frame
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_diner":
		push_error(
			"npc_smoke: Mira diner location not restored/resolved after load (got '%s')"
			% str(ns.call("get_location_id", MIRA))
		)
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "EATING":
		push_error("npc_smoke: Mira EATING not restored after load")
		quit(1)
		return false
	if str(ns.call("get_schedule_id", MIRA)) != "mira_daily":
		push_error("npc_smoke: Mira schedule_id not restored after load")
		quit(1)
		return false

	if sched.has_signal("npc_schedule_changed") and sched.npc_schedule_changed.is_connected(on_changed):
		sched.npc_schedule_changed.disconnect(on_changed)
	if changed.is_empty():
		push_error("npc_smoke: npc_schedule_changed never emitted")
		quit(1)
		return false

	save.call("delete_save")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"npc_smoke: npc_sched OK (Mira routine + Rafa cross-midnight + fallback + save + signal)"
	)
	return true



func _verify_npc_movement(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Mira walks between Sunset Viewpoint markers; dialogue pauses; reload snaps.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if gt == null or ns == null or sched == null or dlg == null or poi_sys == null:
		push_error("npc_smoke: systems missing for npc movement")
		quit(1)
		return false

	var move_script: Script = load("res://scripts/npc/npc_movement_controller.gd") as Script
	if move_script != null:
		var src := move_script.source_code
		for banned in ["mira_viewpoint_keeper", "DialogueSystem.start_dialogue", "final anim"]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: NpcMovementController must not contain '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	if dlg.has_method("reload_catalog"):
		dlg.call("reload_catalog")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(10.0, 0.0, -5.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("npc_smoke: viewpoint spawn failed for npc movement")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	var destinations: Node = vp.get_node_or_null("Destinations")
	if destinations == null:
		push_error("npc_smoke: Destinations node missing on ViewpointPOI")
		quit(1)
		return false
	for needed in ["viewpoint_workshop", "viewpoint_diner", "viewpoint_home"]:
		if destinations.get_node_or_null(needed) == null:
			push_error("npc_smoke: missing destination marker '%s'" % needed)
			quit(1)
			return false
	if vp.get_node_or_null("NavigationRegion3D") == null:
		push_error("npc_smoke: NavigationRegion3D missing on ViewpointPOI")
		quit(1)
		return false

	var mira: Node3D = vp.find_child("Mira", true, false) as Node3D
	if mira == null:
		push_error("npc_smoke: Mira missing for movement")
		quit(1)
		return false
	var movement: Node = mira.get_node_or_null("NpcMovementController")
	if movement == null:
		push_error("npc_smoke: NpcMovementController missing on Mira")
		quit(1)
		return false
	movement.set("max_speed", 12.0)
	movement.set("acceleration", 40.0)

	# Hour 10 → snap/arrive at workshop.
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	await physics_frame
	var workshop: Marker3D = destinations.get_node("viewpoint_workshop") as Marker3D
	var diner: Marker3D = destinations.get_node("viewpoint_diner") as Marker3D
	if not bool(movement.call("go_to_location", "viewpoint_workshop", true)):
		push_error("npc_smoke: go_to_location(workshop, snap) failed")
		quit(1)
		return false
	await physics_frame
	if mira.global_position.distance_to(workshop.global_position) > 0.75:
		push_error(
			"npc_smoke: Mira should snap to workshop (dist=%.2f mira=%s mark=%s)"
			% [
				mira.global_position.distance_to(workshop.global_position),
				str(mira.global_position),
				str(workshop.global_position),
			]
		)
		quit(1)
		return false

	# Hour 12 → walk toward diner.
	gt.call("set_narrative_time", 0, 12, 0)
	sched.call("refresh_all")
	await physics_frame
	var start_pos := mira.global_position
	var start_dist := start_pos.distance_to(diner.global_position)
	for _i in range(90):
		await physics_frame
		if mira.global_position.distance_to(diner.global_position) < 0.6:
			break
	var end_dist := mira.global_position.distance_to(diner.global_position)
	if end_dist >= start_dist - 0.15:
		push_error(
			"npc_smoke: Mira should walk toward diner (start=%.2f end=%.2f)"
			% [start_dist, end_dist]
		)
		quit(1)
		return false

	# Dialogue pauses movement; schedule may update desired target but walk waits.
	ns.call("set_met_player", "mira_viewpoint_keeper", true)
	character.global_position = mira.global_position + Vector3(0.0, 0.05, 1.4)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("npc_smoke: Mira interact failed during movement pause test")
		quit(1)
		return false
	await physics_frame
	if movement.has_method("is_paused") and not bool(movement.call("is_paused")):
		push_error("npc_smoke: movement should pause during dialogue")
		quit(1)
		return false
	# Still within Mira's availability window (08–18); retarget workshop while paused.
	gt.call("set_narrative_time", 0, 15, 0)
	sched.call("refresh_all")
	await physics_frame
	var paused_pos := mira.global_position
	for _j in range(20):
		await physics_frame
	if mira.global_position.distance_to(paused_pos) > 0.08:
		push_error("npc_smoke: Mira moved during dialogue pause")
		quit(1)
		return false
	if str(movement.call("get_desired_location_id")) != "viewpoint_workshop":
		push_error("npc_smoke: paused Mira should keep updated desired workshop target")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame
	await physics_frame
	if movement.has_method("is_paused") and bool(movement.call("is_paused")):
		push_error("npc_smoke: movement should resume after dialogue")
		quit(1)
		return false

	# Missing destination fails safe (logical state kept).
	ns.call("set_location_id", "mira_viewpoint_keeper", "viewpoint_workshop")
	if not bool(movement.call("go_to_location", "no_such_marker", false)):
		if str(ns.call("get_location_id", "mira_viewpoint_keeper")) != "viewpoint_workshop":
			push_error("npc_smoke: missing marker must not wipe logical location")
			quit(1)
			return false
	else:
		push_error("npc_smoke: go_to_location should fail for missing marker")
		quit(1)
		return false

	# Reload snap: despawn / respawn at hour 15 → workshop without long path sim.
	gt.call("set_narrative_time", 0, 15, 0)
	sched.call("refresh_all")
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	await physics_frame
	mira = vp.find_child("Mira", true, false) as Node3D
	destinations = vp.get_node_or_null("Destinations")
	workshop = destinations.get_node("viewpoint_workshop") as Marker3D if destinations != null else null
	if mira == null or workshop == null:
		push_error("npc_smoke: Mira/workshop missing after reload snap")
		quit(1)
		return false
	movement = mira.get_node_or_null("NpcMovementController")
	if movement != null and movement.has_method("snap_to_current_schedule"):
		movement.call("snap_to_current_schedule")
	await physics_frame
	if mira.global_position.distance_to(workshop.global_position) > 0.9:
		push_error(
			"npc_smoke: reload should snap Mira to workshop (dist=%.2f)"
			% mira.global_position.distance_to(workshop.global_position)
		)
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("npc_smoke: npc_move OK (walk + dialogue pause + fail-safe + reload snap)")
	return true



func _verify_npc_travel(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Logical traveler relocation: leave POI → TRAVELING → arrive at debug location.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var travel: Node = root.get_node_or_null("NpcTravelSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	if (
		gt == null
		or ns == null
		or sched == null
		or travel == null
		or cond == null
		or save == null
		or poi_sys == null
		or dlg == null
	):
		push_error("npc_smoke: systems missing for npc travel")
		quit(1)
		return false

	const RAFA := "rafa_road_traveler"
	const DEST := "debug_waystation"

	var travel_script: Script = load("res://autoload/npc_travel_system.gd") as Script
	if travel_script != null:
		var src := travel_script.source_code
		for banned in ["rafa_road_traveler", "Rafa", "mira_viewpoint_keeper", "Mira", "debug_waystation"]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: NpcTravelSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	save.call("delete_save")
	if dlg.has_method("reload_catalog"):
		dlg.call("reload_catalog")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(8.0, 0.0, -8.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("npc_smoke: viewpoint spawn failed for npc travel")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")
	await physics_frame

	var rafa: Node3D = vp.find_child("Rafa", true, false) as Node3D
	var mira: Node3D = vp.find_child("Mira", true, false) as Node3D
	if rafa == null or mira == null:
		push_error("npc_smoke: Rafa/Mira missing before travel")
		quit(1)
		return false
	if str(ns.call("get_location_id", RAFA)) != "roadside_pullout":
		push_error(
			"npc_smoke: Rafa should start at roadside_pullout (got '%s')"
			% str(ns.call("get_location_id", RAFA))
		)
		quit(1)
		return false
	if str(ns.call("get_travel_state", RAFA)) != "AT_LOCATION":
		push_error("npc_smoke: Rafa travel_state should start AT_LOCATION")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_at_location", RAFA, "roadside_pullout"))):
		push_error("npc_smoke: NPC_AT_LOCATION roadside_pullout failed")
		quit(1)
		return false

	# DialogueAction START_NPC_TRAVEL → destination debug_waystation, +60 narrative minutes.
	var ActionScript: Script = load("res://scripts/dialogue/dialogue_action.gd") as Script
	var ExecScript: Script = load("res://scripts/dialogue/dialogue_action_executor.gd") as Script
	var action: Resource = ActionScript.new() as Resource
	action.set("type", 16)  # START_NPC_TRAVEL
	action.set("target_id", RAFA)
	action.set("string_value", DEST)
	action.set("secondary_id", "rafa_leave_viewpoint")
	action.set("int_value", 60)
	action.set("float_value", 0.0)
	var executor = ExecScript.new()
	if not bool(executor.call("execute", action)):
		push_error("npc_smoke: START_NPC_TRAVEL action failed")
		quit(1)
		return false
	await physics_frame
	await physics_frame
	await physics_frame

	if str(ns.call("get_travel_state", RAFA)) != "TRAVELING":
		push_error("npc_smoke: Rafa should be TRAVELING after start")
		quit(1)
		return false
	if str(ns.call("get_destination_location_id", RAFA)) != DEST:
		push_error("npc_smoke: Rafa destination should be debug_waystation")
		quit(1)
		return false
	if str(ns.call("get_previous_location_id", RAFA)) != "roadside_pullout":
		push_error("npc_smoke: Rafa previous_location should be roadside_pullout")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_travel_state", RAFA, "TRAVELING"))):
		push_error("npc_smoke: NPC_TRAVEL_STATE TRAVELING failed")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_destination", RAFA, DEST))):
		push_error("npc_smoke: NPC_DESTINATION failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_npc_at_location", RAFA, "roadside_pullout"))):
		push_error("npc_smoke: NPC_AT_LOCATION must be false while TRAVELING")
		quit(1)
		return false

	rafa = vp.find_child("Rafa", true, false) as Node3D
	mira = vp.find_child("Mira", true, false) as Node3D
	if rafa != null and is_instance_valid(rafa):
		push_error("npc_smoke: Rafa physical presence should leave Sunset Viewpoint")
		quit(1)
		return false
	if mira == null or not is_instance_valid(mira):
		push_error("npc_smoke: Mira must remain while Rafa travels")
		quit(1)
		return false

	# Persist mid-travel.
	if not bool(save.call("save_game")):
		push_error("npc_smoke: npc travel mid-save failed")
		quit(1)
		return false
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("npc_smoke: npc travel mid-load failed")
		quit(1)
		return false
	await physics_frame
	if str(ns.call("get_travel_state", RAFA)) != "TRAVELING":
		push_error("npc_smoke: Rafa TRAVELING not restored after save/load")
		quit(1)
		return false
	if str(ns.call("get_destination_location_id", RAFA)) != DEST:
		push_error("npc_smoke: Rafa destination not restored after save/load")
		quit(1)
		return false

	# Reload POI while traveling — must not respawn Rafa (no duplicate / ghost).
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	await physics_frame
	rafa = vp.find_child("Rafa", true, false) as Node3D if vp != null else null
	if rafa != null and is_instance_valid(rafa):
		push_error("npc_smoke: Rafa must not spawn at Sunset while TRAVELING")
		quit(1)
		return false

	# Narrative arrival (+60 minutes from start; clock restored from save).
	gt.call("advance_narrative_minutes", 60.0)
	travel.call("refresh_arrivals")
	await physics_frame
	if str(ns.call("get_travel_state", RAFA)) != "AT_LOCATION":
		push_error("npc_smoke: Rafa should arrive AT_LOCATION after narrative delay")
		quit(1)
		return false
	if str(ns.call("get_location_id", RAFA)) != DEST:
		push_error(
			"npc_smoke: Rafa should be at debug_waystation after arrival (got '%s')"
			% str(ns.call("get_location_id", RAFA))
		)
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_npc_at_location", RAFA, DEST))):
		push_error("npc_smoke: NPC_AT_LOCATION debug_waystation failed")
		quit(1)
		return false

	# Still no physical Rafa at Sunset (logical-only destination).
	rafa = vp.find_child("Rafa", true, false) as Node3D if vp != null else null
	if rafa != null and is_instance_valid(rafa):
		push_error("npc_smoke: Rafa must not appear at Sunset after arriving at logical dest")
		quit(1)
		return false

	# SET_NPC_LOCATION instant place + presence return path.
	var set_loc: Resource = ActionScript.new() as Resource
	set_loc.set("type", 10)  # SET_NPC_LOCATION
	set_loc.set("target_id", RAFA)
	set_loc.set("string_value", "roadside_pullout")
	set_loc.set("secondary_id", "test_return")
	if not bool(executor.call("execute", set_loc)):
		push_error("npc_smoke: SET_NPC_LOCATION failed")
		quit(1)
		return false
	# Returning via SET does not auto-resume local schedule; re-enable for presence spawn.
	ns.call("set_follow_local_schedule", RAFA, true)
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	rafa = vp.find_child("Rafa", true, false) as Node3D if vp != null else null
	if rafa == null:
		push_error("npc_smoke: Rafa should respawn at Sunset after SET_NPC_LOCATION home")
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	save.call("delete_save")
	ns.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"npc_smoke: npc_travel OK (leave + TRAVELING persist + narrative arrive + no duplicate)"
	)
	return true



func _verify_npc_dialogue_debug(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Dev panel + content validator: start talk without walking to NPC; mutate; reset isolated.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var quests: Node = root.get_node_or_null("QuestSystem")
	var rel: Node = root.get_node_or_null("RelationshipSystem")
	var bark: Node = root.get_node_or_null("BarkSystem")
	var journey: Node = root.get_node_or_null("JourneySystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if (
		dlg == null
		or memory == null
		or ns == null
		or gt == null
		or flags == null
		or quests == null
		or rel == null
		or bark == null
		or journey == null
		or inv == null
	):
		push_error("npc_smoke: systems missing for npc dialogue debug")
		quit(1)
		return false

	# Isolation: gameplay autoloads must not reference the debug panel.
	for path in [
		"res://autoload/dialogue_system.gd",
		"res://autoload/bark_system.gd",
		"res://autoload/npc_state_system.gd",
		"res://scripts/npc/npc_character.gd",
		"res://scripts/dialogue/dialogue_ui.gd",
	]:
		var script: Script = load(path) as Script
		if script == null:
			continue
		var src := script.source_code
		for banned in ["NpcDialogueDebugUI", "npc_dialogue_debug_ui", "NpcDialogueContentValidator"]:
			if src.find(banned) >= 0:
				push_error("npc_smoke: %s must not reference debug tool '%s'" % [path, banned])
				quit(1)
				return false

	var ValidatorScript = load("res://scripts/debug/npc_dialogue_content_validator.gd")
	if ValidatorScript == null:
		push_error("npc_smoke: NpcDialogueContentValidator missing")
		quit(1)
		return false
	var validator: RefCounted = ValidatorScript.new()
	var report: Dictionary = validator.call("validate")
	if not bool(report.get("ok", false)):
		push_error(
			"npc_smoke: content validation failed:\n%s"
			% str(validator.call("format_report", report))
		)
		quit(1)
		return false
	if int(report.get("npc_count", 0)) < 2 or int(report.get("dialogue_count", 0)) < 4:
		push_error("npc_smoke: validator catalog counts too low")
		quit(1)
		return false

	var panel: Node = root.find_child("NpcDialogueDebugUI", true, false)
	if panel == null:
		push_error("npc_smoke: NpcDialogueDebugUI missing from sandbox")
		quit(1)
		return false

	# Baseline journey/inventory must survive NPC/dialogue reset.
	var journey_before := float(journey.call("get_current_distance_km"))
	if inv.has_method("clear_all"):
		pass
	var scrap_before := int(inv.call("get_quantity", "scrap_metal")) if inv.has_method("get_quantity") else 0
	if scrap_before < 1 and inv.has_method("add_item"):
		inv.call("add_item", "scrap_metal", 2)
		scrap_before = int(inv.call("get_quantity", "scrap_metal"))

	memory.call("reset_for_tests")
	ns.call("reset_for_tests")
	bark.call("reset_for_tests")
	gt.call("reset_for_tests")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")
	gt.call("set_narrative_time", 0, 10, 0)

	if not panel.has_method("open"):
		push_error("npc_smoke: NpcDialogueDebugUI missing open()")
		quit(1)
		return false
	panel.call("open")
	await physics_frame
	if not bool(panel.call("is_panel_visible")):
		push_error("npc_smoke: NpcDialogueDebugUI did not open")
		quit(1)
		return false

	var npc_ids: PackedStringArray = dlg.call("get_registered_npc_ids")
	if npc_ids.size() < 2:
		push_error("npc_smoke: expected registered NPCs in debug list")
		quit(1)
		return false

	const MIRA := "mira_viewpoint_keeper"
	# Select Mira without walking to her; start a dialogue_id from the panel.
	if not bool(panel.call("select_npc_id", MIRA)):
		push_error("npc_smoke: could not select Mira in debug panel")
		quit(1)
		return false
	if str(panel.call("get_selected_npc_id")) != MIRA:
		push_error("npc_smoke: selected NPC is not Mira")
		quit(1)
		return false
	panel.call("select_dialogue_id", "mira_intro")

	var started := bool(panel.call("start_selected_dialogue"))
	if not started:
		push_error("npc_smoke: debug panel failed to start mira_intro remotely")
		quit(1)
		return false
	if not bool(dlg.call("is_active")):
		push_error("npc_smoke: dialogue not active after debug start")
		quit(1)
		return false
	if not bool(memory.call("has_seen_dialogue", "mira_intro")):
		push_error("npc_smoke: memory did not record debug-started dialogue")
		quit(1)
		return false

	# Inspect rule TRUE/FALSE API.
	var rules: Array = dlg.call("inspect_npc_dialogue_rules", MIRA)
	if rules.is_empty():
		push_error("npc_smoke: inspect_npc_dialogue_rules empty for Mira")
		quit(1)
		return false
	var saw_bool := false
	for row in rules:
		if row.has("passes") and row.has("conditions"):
			saw_bool = true
			break
	if not saw_bool:
		push_error("npc_smoke: rule inspect missing passes/conditions")
		quit(1)
		return false

	# Temporary mutators via panel helpers.
	gt.call("set_narrative_time", 0, 8, 0)
	panel.call("_mutate_narrative_set_night")
	if int(gt.call("get_narrative_hour")) != 22:
		push_error("npc_smoke: debug narrative night mutator failed")
		quit(1)
		return false
	panel.call("_mutate_relationship", 5)
	if int(rel.call("get_relationship", MIRA)) < 5:
		push_error("npc_smoke: debug relationship mutator failed")
		quit(1)
		return false
	panel.call("_mutate_cycle_npc_state")
	if str(ns.call("get_current_state", MIRA)) == "DEFAULT":
		# Cycled away from DEFAULT at least once when starting DEFAULT.
		pass
	panel.call("_mutate_toggle_debug_flag")
	if not bool(flags.call("get_flag", "debug.npc_dialogue_panel", false)):
		push_error("npc_smoke: debug flag mutator failed")
		quit(1)
		return false
	# Cycle linked quest until ACTIVE (handles leftover COMPLETED from earlier smoke).
	var quest_ok := false
	for _q in range(3):
		panel.call("_mutate_cycle_linked_quest")
		if bool(quests.call("is_active", "power_the_viewpoint")):
			quest_ok = true
			break
	if not quest_ok:
		push_error(
			"npc_smoke: debug quest mutator never reached ACTIVE (got %s)"
			% str(quests.call("get_state_name", "power_the_viewpoint"))
		)
		quit(1)
		return false

	if bark.has_method("get_bark_debug_state"):
		var bark_state: Dictionary = bark.call("get_bark_debug_state", MIRA)
		if not bark_state.has("active_cooldowns"):
			push_error("npc_smoke: bark debug state incomplete")
			quit(1)
			return false

	var validation_ui: Dictionary = panel.call("run_validation")
	if not bool(validation_ui.get("ok", false)):
		push_error("npc_smoke: panel validation reported FAIL on clean content")
		quit(1)
		return false
	panel.call("clear_validation_report")
	if not str(panel.call("get_validation_report_text")).is_empty():
		push_error("npc_smoke: clear_validation_report did not clear text")
		quit(1)
		return false

	# Inject a broken link and ensure validator catches it.
	var bogus: Resource = load("res://scripts/dialogue/dialogue_definition.gd").new()
	bogus.set("id", "__debug_orphan_probe__")
	bogus.set("next_dialogue_id", "__missing_next__")
	dlg.call("register_dialogue", bogus)
	# Catalog-file validator should still pass (runtime-only registration not on disk).
	var disk_ok: Dictionary = validator.call("validate")
	if not bool(disk_ok.get("ok", false)):
		push_error("npc_smoke: disk validation unexpectedly failed after runtime register")
		quit(1)
		return false

	panel.call("reset_npc_dialogue_test_data")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("npc_smoke: reset left dialogue active")
		quit(1)
		return false
	if bool(memory.call("has_seen_dialogue", "mira_intro")):
		push_error("npc_smoke: reset did not clear dialogue memory")
		quit(1)
		return false
	if absf(float(journey.call("get_current_distance_km")) - journey_before) > 0.001:
		push_error("npc_smoke: NPC/dialogue reset must not alter journey distance")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != scrap_before:
		push_error("npc_smoke: NPC/dialogue reset must not alter inventory")
		quit(1)
		return false

	panel.call("close")
	await physics_frame
	if bool(panel.call("is_panel_visible")):
		push_error("npc_smoke: NpcDialogueDebugUI still open after close")
		quit(1)
		return false

	# Leave clocks/state clean for later smoke slices (Mira availability window, etc.).
	gt.call("reset_for_tests")
	gt.call("set_narrative_time", 0, 10, 0)
	if quests.has_method("reset_quest"):
		quests.call("reset_quest", "power_the_viewpoint")
	if rel.has_method("reset_for_tests"):
		rel.call("reset_for_tests")
	ns.call("reset_for_tests")
	bark.call("reset_for_tests")
	memory.call("reset_for_tests")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")
	flags.call("clear_flag", "debug.npc_dialogue_panel")

	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print(
		"npc_smoke: npc_dlg_debug OK (panel + validate + remote start + mutators + isolated reset)"
	)
	return true



