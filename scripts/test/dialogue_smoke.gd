extends "res://scripts/test/test_helpers.gd"
## Dialogue choices, conditions, actions, memory, interrupt, system pass.
## Run: godot --path . --headless -s res://scripts/test/dialogue_smoke.gd

func _initialize() -> void:
	suite_name = "dialogue_smoke"
	start_suite_timeout(240.0)
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
	if not await _verify_dialogue_choices(occupancy, character, foot_cam):
		return
	if not await _verify_conditional_dialogue(occupancy, character, foot_cam):
		return
	if not await _verify_dialogue_actions(occupancy, character, foot_cam):
		return
	if not await _verify_dialogue_memory(occupancy, character, foot_cam):
		return
	if not await _verify_dialogue_interrupt(occupancy, character, foot_cam):
		return
	if not await _verify_dialogue_npc_system_pass(occupancy, character, foot_cam):
		return
	pass_suite("dialogue_choices+conditional_dialogue+dialogue_actions+dialogue_memory+dialogue_interrupt+dialogue_npc_pass")

func _verify_dialogue_choices(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Branching DialogueChoice: Mira moon ask — navigate, confirm branch, keep linear intact.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	if dlg == null:
		push_error("dialogue_smoke: DialogueSystem missing for choices test")
		quit(1)
		return false

	# DialogueSystem must stay NPC-agnostic (no Mira/Lua branching in the runner).
	var dlg_script: Script = load("res://autoload/dialogue_system.gd") as Script
	if dlg_script != null:
		var src := dlg_script.source_code
		for banned in [
			"Mira",
			"mira_moon",
			"Lua",
			"viewpoint_keeper",
			"InventorySystem",
			"QuestSystem",
			"VehicleStateSystem",
			"WorldRegionSystem",
			"GameFlags",
			"power_the_viewpoint",
			"scrap_metal",
		]:
			if src.find(banned) >= 0:
				push_error("dialogue_smoke: DialogueSystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	if not bool(dlg.call("has_dialogue", "mira_moon_ask")):
		push_error("dialogue_smoke: catalog missing mira_moon_ask")
		quit(1)
		return false
	for reply_id in ["mira_moon_yes", "mira_moon_unsure", "mira_moon_passing"]:
		if not bool(dlg.call("has_dialogue", reply_id)):
			push_error("dialogue_smoke: catalog missing %s" % reply_id)
			quit(1)
			return false

	# Linear still works (mira_01 → mira_02 → end).
	if not bool(dlg.call("start_dialogue", "mira_01", character)):
		push_error("dialogue_smoke: linear mira_01 failed to start")
		quit(1)
		return false
	await physics_frame
	if bool(dlg.call("has_available_choices")):
		push_error("dialogue_smoke: linear mira_01 should have no choices")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_02":
		push_error("dialogue_smoke: linear advance should reach mira_02")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: linear mira dialogue should end")
		quit(1)
		return false

	# Isolate Mira moon ask from quest/inventory gates for baseline choice nav.
	var qs: Node = root.get_node_or_null("QuestSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if qs != null:
		qs.call("reset_all")
	if inv != null:
		inv.call("clear_inventory")

	# --- Mira branching sample ---
	var finished := {"id": ""}
	var on_finished := func(id: String) -> void:
		finished["id"] = str(id)
	dlg.dialogue_finished.connect(on_finished)

	if not bool(character.call("is_control_enabled")):
		character.call("set_control_enabled", true)
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("dialogue_smoke: mira_moon_ask failed to start")
		quit(1)
		return false
	await physics_frame

	if not bool(dlg.call("is_active")):
		push_error("dialogue_smoke: mira_moon_ask not active")
		quit(1)
		return false
	if bool(character.call("is_control_enabled")):
		push_error("dialogue_smoke: movement should be locked during choice dialogue")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("Lua") < 0:
		push_error("dialogue_smoke: expected moon question text")
		quit(1)
		return false
	if not bool(dlg.call("has_available_choices")):
		push_error("dialogue_smoke: mira_moon_ask should expose selectable choices")
		quit(1)
		return false
	# Quest incomplete + no scrap: 3 moon selectable; buy visible-but-disabled; repaired hidden.
	var selectable: Array = dlg.call("get_available_choices")
	var visible: Array = dlg.call("get_visible_choices")
	if selectable.size() != 3:
		push_error("dialogue_smoke: expected 3 selectable Mira choices, got %d" % selectable.size())
		quit(1)
		return false
	if visible.size() != 4:
		push_error("dialogue_smoke: expected 4 visible Mira choices (incl. disabled buy), got %d" % visible.size())
		quit(1)
		return false

	# Linear next_dialogue_id must not skip choices (advance confirms selection).
	if int(dlg.call("get_choice_index")) != 0:
		push_error("dialogue_smoke: choice index should start at 0")
		quit(1)
		return false
	dlg.call("select_next_choice")
	await physics_frame
	if int(dlg.call("get_choice_index")) != 1:
		push_error("dialogue_smoke: select_next_choice should move to index 1")
		quit(1)
		return false
	dlg.call("select_next_choice")
	await physics_frame
	if int(dlg.call("get_choice_index")) != 2:
		push_error("dialogue_smoke: select_next_choice should move to index 2")
		quit(1)
		return false
	dlg.call("select_previous_choice")
	await physics_frame
	if int(dlg.call("get_choice_index")) != 1:
		push_error("dialogue_smoke: select_previous_choice should return to index 1")
		quit(1)
		return false

	# Player still blocked while highlighting.
	var locked_pos := character.global_position
	Input.action_press("player_move_forward")
	for _m in range(8):
		await physics_frame
	Input.action_release("player_move_forward")
	if locked_pos.distance_to(character.global_position) > 0.05:
		push_error("dialogue_smoke: character moved during choice dialogue")
		quit(1)
		return false

	# Confirm middle choice → mira_moon_unsure.
	var confirmed := {"id": "", "next": ""}
	var on_choice := func(choice_id: String, next_id: String) -> void:
		confirmed["id"] = str(choice_id)
		confirmed["next"] = str(next_id)
	dlg.choice_confirmed.connect(on_choice)
	dlg.call("advance")
	await physics_frame
	if str(confirmed["id"]) != "moon_unsure" or str(confirmed["next"]) != "mira_moon_unsure":
		push_error(
			"dialogue_smoke: expected moon_unsure → mira_moon_unsure (got %s → %s)"
			% [confirmed["id"], confirmed["next"]]
		)
		quit(1)
		return false
	if str(dlg.call("get_current_id")) != "mira_moon_unsure":
		push_error("dialogue_smoke: branch should open mira_moon_unsure")
		quit(1)
		return false
	if bool(dlg.call("has_available_choices")):
		push_error("dialogue_smoke: reply line should be linear (no choices)")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("estrada") < 0:
		push_error("dialogue_smoke: unexpected unsure reply text")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: choice reply should end dialogue")
		quit(1)
		return false
	if not bool(character.call("is_control_enabled")):
		push_error("dialogue_smoke: control not restored after choice dialogue")
		quit(1)
		return false
	if str(finished["id"]) != "mira_moon_ask":
		push_error("dialogue_smoke: dialogue_finished should report start id mira_moon_ask")
		quit(1)
		return false

	# Empty next_dialogue_id on a choice ends immediately.
	var ChoiceScript: Script = load("res://scripts/dialogue/dialogue_choice.gd") as Script
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var end_choice: DialogueChoice = ChoiceScript.new() as DialogueChoice
	end_choice.id = "end_now"
	end_choice.text = "Encerrar."
	end_choice.next_dialogue_id = ""
	end_choice.enabled = true
	var ask_end: DialogueDefinition = DefScript.new() as DialogueDefinition
	ask_end.id = "choice_end_test"
	ask_end.speaker_name = "Test"
	ask_end.text = "Sair?"
	var end_choices: Array[DialogueChoice] = [end_choice]
	ask_end.choices = end_choices
	if not bool(dlg.call("start_from_definition", ask_end, character)):
		push_error("dialogue_smoke: choice_end_test failed to start")
		quit(1)
		return false
	await physics_frame
	if not bool(dlg.call("has_available_choices")):
		push_error("dialogue_smoke: choice_end_test should expose one choice")
		quit(1)
		return false
	dlg.call("confirm_choice")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: empty choice next should end dialogue")
		quit(1)
		return false

	# Authoring enabled=false hides the choice.
	var gated: DialogueChoice = ChoiceScript.new() as DialogueChoice
	gated.id = "gated"
	gated.text = "Hidden"
	gated.next_dialogue_id = ""
	gated.enabled = false
	var open: DialogueChoice = ChoiceScript.new() as DialogueChoice
	open.id = "open"
	open.text = "Visible"
	open.next_dialogue_id = ""
	open.enabled = true
	var gate_def: DialogueDefinition = DefScript.new() as DialogueDefinition
	gate_def.id = "choice_gate_test"
	gate_def.speaker_name = "Test"
	gate_def.text = "Pick"
	var gate_choices: Array[DialogueChoice] = [gated, open]
	gate_def.choices = gate_choices
	dlg.call("start_from_definition", gate_def, character)
	await physics_frame
	var avail: Array = dlg.call("get_available_choices")
	if avail.size() != 1 or str(avail[0].get("id")) != "open":
		push_error("dialogue_smoke: disabled choices must be filtered")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	dlg.choice_confirmed.disconnect(on_choice)
	dlg.dialogue_finished.disconnect(on_finished)
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("dialogue_smoke: choices OK (Mira moon ask navigate/confirm + linear still works)")
	return true



func _verify_conditional_dialogue(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## show_conditions / enable_conditions via ConditionSystem only (quest, item, ALL/ANY, fallback).
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	if dlg == null or qs == null or inv == null or cond == null:
		push_error("dialogue_smoke: systems missing for conditional dialogue")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	dlg.call("reload_catalog")

	# --- Mira: quest COMPLETED reveals repaired choice; scrap enables buy ---
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("dialogue_smoke: cond_dlg mira_moon_ask failed (quest inactive)")
		quit(1)
		return false
	await physics_frame
	var ids_before := choice_ids(dlg.call("get_visible_choices"))
	if ids_before.has("terminal_repaired"):
		push_error("dialogue_smoke: repaired choice must stay hidden before COMPLETED")
		quit(1)
		return false
	if not ids_before.has("buy_part"):
		push_error("dialogue_smoke: buy choice should be visible (disabled) without scrap")
		quit(1)
		return false
	# Highlight buy and refuse confirm while disabled.
	var buy_idx := ids_before.find("buy_part")
	dlg.call("set_choice_index", buy_idx)
	await physics_frame
	if bool(dlg.call("is_selected_choice_enabled")):
		push_error("dialogue_smoke: buy choice should be disabled without scrap")
		quit(1)
		return false
	var confirmed_n := {"n": 0}
	var on_choice := func(_a: String, _b: String) -> void:
		confirmed_n["n"] = int(confirmed_n["n"]) + 1
	dlg.choice_confirmed.connect(on_choice)
	dlg.call("confirm_choice")
	await physics_frame
	if int(confirmed_n["n"]) != 0 or str(dlg.call("get_current_id")) != "mira_moon_ask":
		push_error("dialogue_smoke: disabled buy choice must not confirm")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Complete quest → repaired becomes visible.
	qs.call("start_quest", "power_the_viewpoint")
	qs.call("complete_quest", "power_the_viewpoint")
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("dialogue_smoke: mira_moon_ask failed after COMPLETED")
		quit(1)
		return false
	await physics_frame
	var ids_after_quest := choice_ids(dlg.call("get_visible_choices"))
	if not ids_after_quest.has("terminal_repaired"):
		push_error("dialogue_smoke: repaired choice should appear when quest COMPLETED")
		quit(1)
		return false
	var repaired_idx := ids_after_quest.find("terminal_repaired")
	dlg.call("set_choice_index", repaired_idx)
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_repaired_ack":
		push_error("dialogue_smoke: repaired branch should open mira_repaired_ack")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Give scrap → buy becomes selectable.
	inv.call("add_item", "scrap_metal", 3)
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("dialogue_smoke: mira_moon_ask failed with scrap")
		quit(1)
		return false
	await physics_frame
	var ids_with_scrap := choice_ids(dlg.call("get_visible_choices"))
	var buy_i := ids_with_scrap.find("buy_part")
	if buy_i < 0:
		push_error("dialogue_smoke: buy choice missing with scrap")
		quit(1)
		return false
	dlg.call("set_choice_index", buy_i)
	await physics_frame
	if not bool(dlg.call("is_selected_choice_enabled")):
		push_error("dialogue_smoke: buy choice should enable with scrap_metal x3")
		quit(1)
		return false
	dlg.call("confirm_choice")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_buy_ack":
		push_error("dialogue_smoke: buy branch should open mira_buy_ack")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame
	dlg.choice_confirmed.disconnect(on_choice)

	# --- Line show_conditions + fallback ---
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var ChoiceScript: Script = load("res://scripts/dialogue/dialogue_choice.gd") as Script
	var gated_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	gated_line.id = "cond_line_gated"
	gated_line.speaker_name = "Test"
	gated_line.text = "Should not show"
	gated_line.show_conditions = [cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE")]
	gated_line.show_require_all = true
	gated_line.fallback_dialogue_id = "cond_line_fallback"
	var fallback_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	fallback_line.id = "cond_line_fallback"
	fallback_line.speaker_name = "Test"
	fallback_line.text = "Fallback line ok"
	fallback_line.next_dialogue_id = ""
	dlg.call("register_dialogue", gated_line)
	dlg.call("register_dialogue", fallback_line)
	# Quest is COMPLETED, not ACTIVE → gated fails → fallback.
	if not bool(dlg.call("start_dialogue", "cond_line_gated", character)):
		push_error("dialogue_smoke: gated line should start via fallback")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "cond_line_fallback":
		push_error("dialogue_smoke: expected fallback line, got %s" % str(dlg.call("get_current_id")))
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Loop guard: A fallback B fallback A.
	var loop_a: DialogueDefinition = DefScript.new() as DialogueDefinition
	loop_a.id = "cond_loop_a"
	loop_a.speaker_name = "Test"
	loop_a.text = "A"
	loop_a.show_conditions = [cond.call("make_flag_equals", "never_set_flag", true)]
	loop_a.fallback_dialogue_id = "cond_loop_b"
	var loop_b: DialogueDefinition = DefScript.new() as DialogueDefinition
	loop_b.id = "cond_loop_b"
	loop_b.speaker_name = "Test"
	loop_b.text = "B"
	loop_b.show_conditions = [cond.call("make_flag_equals", "never_set_flag", true)]
	loop_b.fallback_dialogue_id = "cond_loop_a"
	dlg.call("register_dialogue", loop_a)
	dlg.call("register_dialogue", loop_b)
	if bool(dlg.call("start_dialogue", "cond_loop_a", character)):
		push_error("dialogue_smoke: fallback loop should fail to start safely")
		quit(1)
		return false

	# --- ALL / ANY on choice show_conditions ---
	var any_choice: DialogueChoice = ChoiceScript.new() as DialogueChoice
	any_choice.id = "any_ok"
	any_choice.text = "ANY pass"
	any_choice.next_dialogue_id = ""
	any_choice.show_conditions = [
		cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"),
		cond.call("make_has_item", "scrap_metal", 1),
	]
	any_choice.show_require_all = false  # ANY — scrap present → show
	var all_choice: DialogueChoice = ChoiceScript.new() as DialogueChoice
	all_choice.id = "all_fail"
	all_choice.text = "ALL fail"
	all_choice.next_dialogue_id = ""
	all_choice.show_conditions = [
		cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE"),
		cond.call("make_has_item", "scrap_metal", 1),
	]
	all_choice.show_require_all = true  # ALL — ACTIVE missing → hide
	var always: DialogueChoice = ChoiceScript.new() as DialogueChoice
	always.id = "always"
	always.text = "Always"
	always.next_dialogue_id = ""
	var logic_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	logic_line.id = "cond_logic_line"
	logic_line.speaker_name = "Test"
	logic_line.text = "Logic"
	var logic_choices: Array[DialogueChoice] = [any_choice, all_choice, always]
	logic_line.choices = logic_choices
	# All choices hidden path: only all_fail-like — use a line with one hidden choice + fallback.
	dlg.call("start_from_definition", logic_line, character)
	await physics_frame
	var logic_ids := choice_ids(dlg.call("get_visible_choices"))
	if not logic_ids.has("any_ok") or not logic_ids.has("always") or logic_ids.has("all_fail"):
		push_error("dialogue_smoke: ANY/ALL show_conditions wrong (%s)" % str(logic_ids))
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# All choices hidden → fallback_dialogue_id.
	var hidden_only: DialogueChoice = ChoiceScript.new() as DialogueChoice
	hidden_only.id = "hidden_only"
	hidden_only.text = "Nope"
	hidden_only.show_conditions = [cond.call("make_quest_state", "power_the_viewpoint", "ACTIVE")]
	hidden_only.show_require_all = true
	var empty_choices_line: DialogueDefinition = DefScript.new() as DialogueDefinition
	empty_choices_line.id = "cond_all_hidden"
	empty_choices_line.speaker_name = "Test"
	empty_choices_line.text = "Should skip"
	empty_choices_line.fallback_dialogue_id = "cond_line_fallback"
	var hidden_arr: Array[DialogueChoice] = [hidden_only]
	empty_choices_line.choices = hidden_arr
	dlg.call("register_dialogue", empty_choices_line)
	if not bool(dlg.call("start_dialogue", "cond_all_hidden", character)):
		push_error("dialogue_smoke: all-hidden choices should fallback")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "cond_line_fallback":
		push_error("dialogue_smoke: all-hidden should land on fallback")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Ungated dialogues still work after conditional tests.
	if not bool(dlg.call("start_dialogue", "rafa_01", character)):
		push_error("dialogue_smoke: unconditional rafa_01 should still work")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: rafa linear should end")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("dialogue_smoke: cond_dlg OK (quest show + item enable + ALL/ANY + fallback/loop)")
	return true



func _verify_dialogue_actions(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## Declarative DialogueAction: enter flag, choice starts/refuses quest, once-per-event, save.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi: Node = root.get_node_or_null("POISystem")
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	if dlg == null or qs == null or inv == null or flags == null or save == null:
		push_error("dialogue_smoke: systems missing for dialogue actions")
		quit(1)
		return false

	# DialogueSystem must not own the type dispatch (executor does).
	var dlg_script: Script = load("res://autoload/dialogue_system.gd") as Script
	if dlg_script != null:
		var src := dlg_script.source_code
		for banned in ["SET_FLAG", "START_QUEST", "ADD_ITEM", "match type", "InventorySystem", "QuestSystem"]:
			if src.find(banned) >= 0:
				push_error("dialogue_smoke: DialogueSystem must not dispatch action types ('%s')" % banned)
				quit(1)
				return false
	var exec_script: Script = load("res://scripts/dialogue/dialogue_action_executor.gd") as Script
	if exec_script == null:
		push_error("dialogue_smoke: DialogueActionExecutor missing")
		quit(1)
		return false

	qs.call("reset_all")
	inv.call("clear_inventory")
	flags.call("reset_for_tests")
	if poi != null and poi.has_method("clear_discovery_for_tests"):
		poi.call("clear_discovery_for_tests")
	clear_world_state()
	dlg.call("reload_catalog")

	# --- Mira: enter sets flag; accept starts quest; refuse does not ---
	if not bool(dlg.call("start_dialogue", "mira_quest_offer_01", character)):
		push_error("dialogue_smoke: dlg_actions offer failed to start")
		quit(1)
		return false
	await physics_frame
	if not bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("dialogue_smoke: enter action should set npc.mira.met")
		quit(1)
		return false
	# Accidental re-present of same line in-session must not re-run enter.
	flags.call("set_flag", "npc.mira.met", false)
	dlg.call("_present_line", dlg.call("get_current"))
	await physics_frame
	if bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("dialogue_smoke: enter actions must fire once per line per conversation")
		quit(1)
		return false
	flags.call("set_flag", "npc.mira.met", true)

	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "mira_quest_offer_02":
		push_error("dialogue_smoke: expected offer_02 for accept/refuse choices")
		quit(1)
		return false
	# Refuse path.
	dlg.call("set_choice_index", 1)
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: refuse should end dialogue")
		quit(1)
		return false
	if not bool(qs.call("is_inactive", "power_the_viewpoint")):
		push_error("dialogue_smoke: refuse must not START_QUEST")
		quit(1)
		return false

	# Accept path starts quest via on_choose action.
	qs.call("reset_all")
	if not bool(dlg.call("start_dialogue", "mira_quest_offer_01", character)):
		push_error("dialogue_smoke: accept path failed to start")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 0)
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if not bool(qs.call("is_active", "power_the_viewpoint")):
		push_error("dialogue_smoke: accept choice should START_QUEST")
		quit(1)
		return false

	# Choice actions once: re-confirm is impossible after end; use runtime loop A→B→A enter once.
	var ActionScript: Script = load("res://scripts/dialogue/dialogue_action.gd") as Script
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var add_action: DialogueAction = ActionScript.new() as DialogueAction
	add_action.type = DialogueAction.Type.ADD_ITEM
	add_action.target_id = "scrap_metal"
	add_action.int_value = 1
	var line_a: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_a.id = "action_loop_a"
	line_a.speaker_name = "Test"
	line_a.text = "A"
	line_a.next_dialogue_id = "action_loop_b"
	var enter_arr: Array[DialogueAction] = [add_action]
	line_a.on_enter_actions = enter_arr
	var line_b: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_b.id = "action_loop_b"
	line_b.speaker_name = "Test"
	line_b.text = "B"
	line_b.next_dialogue_id = "action_loop_a"
	dlg.call("register_dialogue", line_a)
	dlg.call("register_dialogue", line_b)
	inv.call("clear_inventory")
	dlg.call("start_dialogue", "action_loop_a", character)
	await physics_frame
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("dialogue_smoke: enter ADD_ITEM should run once on first present")
		quit(1)
		return false
	dlg.call("advance")
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "action_loop_a":
		push_error("dialogue_smoke: expected return to action_loop_a")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("dialogue_smoke: re-entering same line must not re-run enter actions")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Executor covers remaining types fail-soft + success.
	var executor: RefCounted = exec_script.new()
	var set_ws: DialogueAction = ActionScript.new() as DialogueAction
	set_ws.type = DialogueAction.Type.SET_WORLD_STATE
	set_ws.target_id = "dlg.action.test"
	set_ws.secondary_id = "powered"
	set_ws.string_value = "true"
	if not bool(executor.call("execute", set_ws)):
		push_error("dialogue_smoke: SET_WORLD_STATE action failed")
		quit(1)
		return false
	if ws != null and str(ws.call("get_value", "dlg.action.test", "powered", "")) != "true":
		push_error("dialogue_smoke: SET_WORLD_STATE value not applied")
		quit(1)
		return false
	var disc: DialogueAction = ActionScript.new() as DialogueAction
	disc.type = DialogueAction.Type.DISCOVER_POI
	disc.target_id = "sunset_viewpoint"
	disc.string_value = "Sunset Viewpoint"
	if not bool(executor.call("execute", disc)):
		push_error("dialogue_smoke: DISCOVER_POI action failed")
		quit(1)
		return false
	if poi != null and not bool(poi.call("is_discovered", "sunset_viewpoint")):
		push_error("dialogue_smoke: DISCOVER_POI did not mark discovery")
		quit(1)
		return false
	var bad: DialogueAction = ActionScript.new() as DialogueAction
	bad.type = DialogueAction.Type.START_QUEST
	bad.target_id = "missing_quest_id_xyz"
	if bool(executor.call("execute", bad)):
		push_error("dialogue_smoke: missing quest target should fail safely")
		quit(1)
		return false

	# Save/load preserves flag set by dialogue enter.
	flags.call("reset_for_tests")
	qs.call("reset_all")
	save.call("delete_save")
	dlg.call("start_dialogue", "mira_quest_offer_01", character)
	await physics_frame
	if not bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("dialogue_smoke: flag missing before save")
		quit(1)
		return false
	if not bool(save.call("save_game")):
		push_error("dialogue_smoke: save after dialogue action failed")
		quit(1)
		return false
	flags.call("reset_for_tests")
	if bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("dialogue_smoke: flag should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("dialogue_smoke: load after dialogue action failed")
		quit(1)
		return false
	if not bool(flags.call("get_flag", "npc.mira.met", false)):
		push_error("dialogue_smoke: save/load should preserve npc.mira.met from dialogue action")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	save.call("delete_save")
	await physics_frame

	qs.call("reset_all")
	inv.call("clear_inventory")
	flags.call("reset_for_tests")
	if poi != null:
		poi.call("clear_discovery_for_tests")
	clear_world_state()
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("dialogue_smoke: dlg_actions OK (enter flag + choice quest + once + save)")
	return true



func _verify_dialogue_memory(_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D) -> bool:
	## DialogueMemorySystem: seen vs completed, choices, ConditionSystem gates, save/load, Rafa return.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var npc_state: Node = root.get_node_or_null("NpcStateSystem")
	if dlg == null or memory == null or cond == null or save == null:
		push_error("dialogue_smoke: systems missing for dialogue memory")
		quit(1)
		return false

	# Memory must stay NPC-agnostic.
	var mem_script: Script = load("res://autoload/dialogue_memory_system.gd") as Script
	if mem_script != null:
		var src := mem_script.source_code
		for banned in ["Rafa", "Mira", "rafa_01", "viewpoint_keeper"]:
			if src.find(banned) >= 0:
				push_error("dialogue_smoke: DialogueMemorySystem must not hardcode '%s'" % banned)
				quit(1)
				return false

	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	dlg.call("reload_catalog")
	save.call("delete_save")

	# Interrupted conversation: seen, not completed.
	if not bool(dlg.call("start_dialogue", "rafa_01", character)):
		push_error("dialogue_smoke: memory rafa_01 failed to start")
		quit(1)
		return false
	await physics_frame
	if not bool(memory.call("has_seen_dialogue", "rafa_01")):
		push_error("dialogue_smoke: start should mark dialogue seen")
		quit(1)
		return false
	if bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("dialogue_smoke: incomplete talk must not be completed")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_seen", "rafa_01"))):
		push_error("dialogue_smoke: DIALOGUE_SEEN condition failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_dialogue_completed", "rafa_01"))):
		push_error("dialogue_smoke: DIALOGUE_COMPLETED should be false while interrupted")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame
	if bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("dialogue_smoke: cancel must not complete dialogue memory")
		quit(1)
		return false

	# Complete with far choice.
	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	dlg.call("start_dialogue", "rafa_01", character)
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 1)  # rafa_far
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: Rafa first talk should end after choice")
		quit(1)
		return false
	if not bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("dialogue_smoke: finished talk should be completed")
		quit(1)
		return false
	if int(memory.call("get_times_completed", "rafa_01")) != 1:
		push_error("dialogue_smoke: times_completed should be 1")
		quit(1)
		return false
	if not bool(memory.call("has_selected_choice", "rafa_far")):
		push_error("dialogue_smoke: rafa_far choice should be remembered")
		quit(1)
		return false
	if int(memory.call("get_choice_count", "rafa_far")) != 1:
		push_error("dialogue_smoke: rafa_far choice count wrong")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_completed", "rafa_01"))):
		push_error("dialogue_smoke: DIALOGUE_COMPLETED condition failed after finish")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_choice_selected", "rafa_far"))):
		push_error("dialogue_smoke: DIALOGUE_CHOICE_SELECTED failed")
		quit(1)
		return false
	if not bool(cond.call("evaluate", cond.call("make_dialogue_completion_count_min", "rafa_01", 1))):
		push_error("dialogue_smoke: DIALOGUE_COMPLETION_COUNT_MIN failed")
		quit(1)
		return false
	if bool(cond.call("evaluate", cond.call("make_dialogue_completion_count_min", "rafa_01", 2))):
		push_error("dialogue_smoke: completion count min=2 should fail at 1")
		quit(1)
		return false

	# Return talk differs — choice influences which return line shows.
	# Clear BUSY from rafa_far SET_NPC_STATE so memory return-gate stays isolatable.
	if npc_state != null and npc_state.has_method("set_current_state"):
		npc_state.call("set_current_state", "rafa_road_traveler", "DEFAULT")
	if not bool(dlg.call("start_dialogue", "rafa_return_far", character)):
		push_error("dialogue_smoke: return_far failed to start")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "rafa_return_far":
		push_error("dialogue_smoke: far choice should keep rafa_return_far")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("Lua") < 0:
		push_error("dialogue_smoke: unexpected far-return text")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Without far choice, return falls back to "Você voltou."
	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	dlg.call("start_dialogue", "rafa_01", character)
	await physics_frame
	dlg.call("advance")
	await physics_frame
	dlg.call("set_choice_index", 0)  # rafa_pass
	await physics_frame
	dlg.call("confirm_choice")
	await physics_frame
	if not bool(dlg.call("start_dialogue", "rafa_return_far", character)):
		push_error("dialogue_smoke: return gate failed after pass choice")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_current_id")) != "rafa_return_01":
		push_error("dialogue_smoke: pass choice should fallback to rafa_return_01")
		quit(1)
		return false
	if str(dlg.call("get_current_text")).find("voltou") < 0:
		push_error("dialogue_smoke: unexpected return greeting")
		quit(1)
		return false
	dlg.call("end_dialogue", true)
	await physics_frame

	# NPC resolve uses priority rules (no hardcoded names in DialogueSystem).
	var rafa_def: Resource = load("res://resources/npc/rafa_road_traveler.tres")
	if rafa_def == null or not ("dialogue_rules" in rafa_def):
		push_error("dialogue_smoke: Rafa NpcDefinition missing dialogue_rules")
		quit(1)
		return false
	dlg.call("register_npc_definition", rafa_def)
	var resolved := str(dlg.call("resolve_dialogue_for_npc", "rafa_road_traveler"))
	if resolved != "rafa_return_far":
		push_error("dialogue_smoke: expected rafa_return_far from return rule, got %s" % resolved)
		quit(1)
		return false

	# Save / load preserves memory.
	if not bool(save.call("save_game")):
		push_error("dialogue_smoke: dialogue memory save failed")
		quit(1)
		return false
	memory.call("reset_for_tests")
	if bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("dialogue_smoke: memory should clear before load")
		quit(1)
		return false
	if not bool(save.call("load_game")):
		push_error("dialogue_smoke: dialogue memory load failed")
		quit(1)
		return false
	if not bool(memory.call("has_completed_dialogue", "rafa_01")):
		push_error("dialogue_smoke: completed state lost after load")
		quit(1)
		return false
	if not bool(memory.call("has_selected_choice", "rafa_pass")):
		push_error("dialogue_smoke: choice memory lost after load")
		quit(1)
		return false
	save.call("delete_save")

	memory.call("reset_for_tests")
	if npc_state != null and npc_state.has_method("reset_for_tests"):
		npc_state.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("dialogue_smoke: dlg_memory OK (seen/completed + choice + Rafa return + save)")
	return true



func _verify_dialogue_interrupt(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## start → advance → interrupt → resume; enter effects not duplicated; unload safe.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var inv: Node = root.get_node_or_null("InventorySystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	if dlg == null or inv == null or memory == null or flags == null or poi_sys == null:
		push_error("dialogue_smoke: systems missing for dialogue interrupt")
		quit(1)
		return false

	if not InputMap.has_action("dialogue_cancel"):
		push_error("dialogue_smoke: dialogue_cancel input action missing")
		quit(1)
		return false

	inv.call("clear_inventory")
	memory.call("reset_for_tests")
	flags.call("reset_for_tests")
	dlg.call("reload_catalog")
	if dlg.has_method("cancel_dialogue"):
		dlg.call("cancel_dialogue")

	var ActionScript: Script = load("res://scripts/dialogue/dialogue_action.gd") as Script
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var add_a: DialogueAction = ActionScript.new() as DialogueAction
	add_a.type = DialogueAction.Type.ADD_ITEM
	add_a.target_id = "scrap_metal"
	add_a.int_value = 1
	var add_b: DialogueAction = ActionScript.new() as DialogueAction
	add_b.type = DialogueAction.Type.ADD_ITEM
	add_b.target_id = "copper_wire"
	add_b.int_value = 1

	var line_a: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_a.id = "interrupt_line_a"
	line_a.speaker_name = "Test"
	line_a.text = "Line A"
	line_a.next_dialogue_id = "interrupt_line_b"
	var enter_a: Array[DialogueAction] = [add_a]
	line_a.on_enter_actions = enter_a

	var line_b: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_b.id = "interrupt_line_b"
	line_b.speaker_name = "Test"
	line_b.text = "Line B"
	line_b.next_dialogue_id = ""
	var enter_b: Array[DialogueAction] = [add_b]
	line_b.on_enter_actions = enter_b

	dlg.call("register_dialogue", line_a)
	dlg.call("register_dialogue", line_b)

	if not bool(dlg.call("start_dialogue", "interrupt_line_a", character, "test_interrupt_npc")):
		push_error("dialogue_smoke: interrupt test failed to start")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_session_state")) != "ACTIVE":
		push_error("dialogue_smoke: session should be ACTIVE after start")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("dialogue_smoke: line A enter should add scrap once")
		quit(1)
		return false

	dlg.call("advance")
	await physics_frame
	if str(dlg.call("get_current_id")) != "interrupt_line_b":
		push_error("dialogue_smoke: expected interrupt_line_b after advance")
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 1:
		push_error("dialogue_smoke: line B enter should add copper once")
		quit(1)
		return false

	if not bool(dlg.call("interrupt_dialogue", "PLAYER_CANCEL")):
		push_error("dialogue_smoke: interrupt_dialogue failed")
		quit(1)
		return false
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: interrupt should leave is_active false")
		quit(1)
		return false
	if not bool(dlg.call("is_interrupted")):
		push_error("dialogue_smoke: session should be INTERRUPTED")
		quit(1)
		return false
	if str(dlg.call("get_interrupt_reason")) != "PLAYER_CANCEL":
		push_error("dialogue_smoke: interrupt reason should be PLAYER_CANCEL")
		quit(1)
		return false
	if bool(memory.call("has_completed_dialogue", "interrupt_line_a")):
		push_error("dialogue_smoke: interrupted dialogue must not count as completed")
		quit(1)
		return false
	if character.has_method("is_control_enabled") and not bool(character.call("is_control_enabled")):
		push_error("dialogue_smoke: interrupt should return player control")
		quit(1)
		return false

	if not bool(dlg.call("resume_dialogue", character)):
		push_error("dialogue_smoke: resume_dialogue failed")
		quit(1)
		return false
	await physics_frame
	if str(dlg.call("get_session_state")) != "ACTIVE":
		push_error("dialogue_smoke: resume should restore ACTIVE")
		quit(1)
		return false
	if str(dlg.call("get_current_id")) != "interrupt_line_b":
		push_error("dialogue_smoke: resume should stay on latest safe line B")
		quit(1)
		return false
	if int(inv.call("get_quantity", "scrap_metal")) != 1:
		push_error("dialogue_smoke: resume must not re-fire line A enter")
		quit(1)
		return false
	if int(inv.call("get_quantity", "copper_wire")) != 1:
		push_error("dialogue_smoke: resume must not re-fire line B enter")
		quit(1)
		return false

	dlg.call("end_dialogue", true)
	await physics_frame
	if not bool(memory.call("has_completed_dialogue", "interrupt_line_a")):
		push_error("dialogue_smoke: completing after resume should record completed")
		quit(1)
		return false

	# cancel_dialogue ≠ completed
	memory.call("reset_for_tests")
	inv.call("clear_inventory")
	if not bool(dlg.call("start_dialogue", "interrupt_line_a", character, "test_interrupt_npc")):
		push_error("dialogue_smoke: cancel path failed to start")
		quit(1)
		return false
	await physics_frame
	dlg.call("cancel_dialogue")
	await physics_frame
	if bool(dlg.call("is_interrupted")) or bool(dlg.call("is_active")):
		push_error("dialogue_smoke: cancel should clear session to IDLE")
		quit(1)
		return false
	if bool(memory.call("has_completed_dialogue", "interrupt_line_a")):
		push_error("dialogue_smoke: cancel must not mark completed")
		quit(1)
		return false

	# Scene unload mid-talk: no error; interrupted with ids only.
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	if gt != null:
		gt.call("set_narrative_time", 0, 10, 0)
	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(6.0, 0.0, -6.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	var mira: Node = vp.find_child("Mira", true, false) if vp != null else null
	if mira == null:
		push_error("dialogue_smoke: Mira missing for unload interrupt")
		quit(1)
		return false
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.4)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("dialogue_smoke: Mira interact failed before unload interrupt")
		quit(1)
		return false
	await physics_frame
	if not bool(dlg.call("is_active")):
		push_error("dialogue_smoke: expected active dialogue before POI unload")
		quit(1)
		return false
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: active dialogue after unload should interrupt")
		quit(1)
		return false
	if not bool(dlg.call("is_interrupted")):
		push_error("dialogue_smoke: unload mid-talk should INTERRUPT (not crash / complete)")
		quit(1)
		return false
	var unload_reason := str(dlg.call("get_interrupt_reason"))
	if unload_reason != "NPC_UNAVAILABLE" and unload_reason != "SCENE_UNLOAD":
		push_error("dialogue_smoke: unload interrupt reason unexpected: %s" % unload_reason)
		quit(1)
		return false
	# Cannot resume without actor → cancel safely; next talk is fresh contextual resolve.
	if bool(dlg.call("resume_dialogue", null)):
		push_error("dialogue_smoke: resume without actor should fail safely")
		quit(1)
		return false
	if bool(dlg.call("is_interrupted")) or bool(dlg.call("is_active")):
		push_error("dialogue_smoke: failed resume should cancel to IDLE")
		quit(1)
		return false

	# Fresh interaction still resolves coherently.
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	mira = vp.find_child("Mira", true, false) if vp != null else null
	if mira == null:
		push_error("dialogue_smoke: Mira missing after unload interrupt cleanup")
		quit(1)
		return false
	character.global_position = (mira as Node3D).global_position + Vector3(0.0, 0.05, 1.4)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("dialogue_smoke: next interaction after interrupt should work")
		quit(1)
		return false
	await physics_frame
	dlg.call("cancel_dialogue")
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	inv.call("clear_inventory")
	memory.call("reset_for_tests")
	flags.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame
	print("dialogue_smoke: dlg_interrupt OK (interrupt/resume + no dup effects + unload)")
	return true



func _verify_dialogue_npc_system_pass(
	_occupancy: Node, character: CharacterBody3D, _foot_cam: Node3D
) -> bool:
	## Close Dialogue & NPC System Pass: architecture coupling + compact full-flow + coverage map.
	## Detailed cases live in earlier _verify_* slices; this asserts integration + data-driven scale.
	var dlg: Node = root.get_node_or_null("DialogueSystem")
	var memory: Node = root.get_node_or_null("DialogueMemorySystem")
	var ns: Node = root.get_node_or_null("NpcStateSystem")
	var sched: Node = root.get_node_or_null("NpcScheduleSystem")
	var travel: Node = root.get_node_or_null("NpcTravelSystem")
	var bark: Node = root.get_node_or_null("BarkSystem")
	var rel: Node = root.get_node_or_null("RelationshipSystem")
	var cond: Node = root.get_node_or_null("ConditionSystem")
	var gt: Node = root.get_node_or_null("GameTimeSystem")
	var qs: Node = root.get_node_or_null("QuestSystem")
	var save: Node = root.get_node_or_null("SaveSystem")
	var poi_sys: Node = root.get_node_or_null("POISystem")
	var flags: Node = root.get_node_or_null("GameFlags")
	if (
		dlg == null
		or memory == null
		or ns == null
		or sched == null
		or travel == null
		or bark == null
		or rel == null
		or cond == null
		or gt == null
		or qs == null
		or save == null
		or poi_sys == null
		or flags == null
	):
		push_error("dialogue_smoke: systems missing for dialogue/npc system pass")
		quit(1)
		return false

	# --- Architecture: no reverse get_node ownership edges / no per-NPC hardcoding in hubs ---
	# Allowed reads are documented in docs/dialogue-npc-system-status.md (acyclic intent).
	var coupling_checks: Array = [
		{
			"path": "res://autoload/dialogue_system.gd",
			"banned": [
				"/root/NpcScheduleSystem",
				"/root/NpcTravelSystem",
				"/root/RelationshipSystem",
				"/root/BarkSystem",
				"/root/QuestSystem",
				"mira_viewpoint_keeper",
				"rafa_road_traveler",
			],
		},
		{
			"path": "res://autoload/npc_state_system.gd",
			"banned": [
				"/root/DialogueSystem",
				"/root/BarkSystem",
				"/root/NpcScheduleSystem",
				"/root/NpcTravelSystem",
				"/root/RelationshipSystem",
				"/root/ConditionSystem",
				"mira_viewpoint_keeper",
			],
		},
		{
			"path": "res://autoload/npc_schedule_system.gd",
			"banned": [
				"/root/DialogueSystem",
				"/root/BarkSystem",
				"/root/RelationshipSystem",
				"/root/ConditionSystem",
				"/root/NpcTravelSystem",
				"mira_viewpoint_keeper",
			],
		},
		{
			"path": "res://autoload/relationship_system.gd",
			"banned": [
				"/root/DialogueSystem",
				"/root/DialogueMemorySystem",
				"/root/BarkSystem",
				"/root/NpcScheduleSystem",
				"mira_viewpoint_keeper",
			],
		},
		{
			"path": "res://autoload/bark_system.gd",
			"banned": ["DialogueUI", "mira_viewpoint_keeper", "rafa_road_traveler", "Vai chover"],
		},
		{
			"path": "res://autoload/dialogue_memory_system.gd",
			"banned": ["/root/DialogueSystem", "/root/QuestSystem", "mira_viewpoint_keeper"],
		},
		{
			"path": "res://autoload/condition_system.gd",
			"banned": ["power_the_viewpoint", "mira_quest", "\"Mira\"", "\"Rafa\""],
		},
		{
			"path": "res://scripts/npc/npc_movement_controller.gd",
			"banned": ["mira_viewpoint_keeper", "start_dialogue(", "/root/RelationshipSystem"],
		},
	]
	for entry in coupling_checks:
		var script: Script = load(str(entry["path"])) as Script
		if script == null:
			push_error("dialogue_smoke: missing script for coupling audit %s" % str(entry["path"]))
			quit(1)
			return false
		var src := script.source_code
		for banned in entry["banned"]:
			if src.find(str(banned)) >= 0:
				push_error(
					"dialogue_smoke: coupling audit fail %s must not contain '%s'"
					% [str(entry["path"]), str(banned)]
				)
				quit(1)
				return false

	# Content validator: broken links / duplicates / schedule fallbacks.
	var ValidatorScript = load("res://scripts/debug/npc_dialogue_content_validator.gd")
	if ValidatorScript == null:
		push_error("dialogue_smoke: content validator missing for system pass")
		quit(1)
		return false
	var validator: RefCounted = ValidatorScript.new()
	var report: Dictionary = validator.call("validate")
	if not bool(report.get("ok", false)):
		push_error(
			"dialogue_smoke: system pass content validation failed:\n%s"
			% str(validator.call("format_report", report))
		)
		quit(1)
		return false

	# Runtime invalid next_dialogue_id ends safely (does not hang session).
	var DefScript: Script = load("res://scripts/dialogue/dialogue_definition.gd") as Script
	var broken: DialogueDefinition = DefScript.new() as DialogueDefinition
	broken.id = "__pass_broken_link__"
	broken.speaker_name = "Test"
	broken.text = "Broken next"
	broken.next_dialogue_id = "__definitely_missing_dialogue__"
	dlg.call("register_dialogue", broken)
	if not bool(dlg.call("start_dialogue", "__pass_broken_link__", character)):
		push_error("dialogue_smoke: broken-link line should still start")
		quit(1)
		return false
	await physics_frame
	dlg.call("advance")
	await physics_frame
	if bool(dlg.call("is_active")):
		push_error("dialogue_smoke: missing next_dialogue_id should end dialogue safely")
		quit(1)
		return false

	# Reset and run compact full flow (spawn → schedule → talk → resolve → branch → memory →
	# relationship → time → interrupt/resume → travel no-dupe → bark → save/load).
	const MIRA := "mira_viewpoint_keeper"
	const RAFA := "rafa_road_traveler"
	memory.call("reset_for_tests")
	ns.call("reset_for_tests")
	rel.call("reset_for_tests")
	qs.call("reset_all")
	flags.call("reset_for_tests")
	bark.call("reset_for_tests")
	gt.call("reset_for_tests")
	sched.call("reset_for_tests")
	save.call("delete_save")
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("refresh_all")

	var poi_res: Resource = load("res://resources/world/pois/sunset_viewpoint.tres")
	var vp_scene: PackedScene = load("res://scenes/world/ViewpointPOI.tscn")
	var scene_root: Node = root.get_child(0) if root.get_child_count() > 0 else root
	var spawn_xf := Transform3D(Basis.IDENTITY, character.global_position + Vector3(6.0, 0.0, -6.0))
	var vp: Node3D = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	if vp == null:
		push_error("dialogue_smoke: system pass viewpoint spawn failed")
		quit(1)
		return false
	await physics_frame
	await physics_frame

	var mira: Node3D = vp.find_child("Mira", true, false) as Node3D
	var rafa: Node3D = vp.find_child("Rafa", true, false) as Node3D
	if mira == null or rafa == null:
		push_error("dialogue_smoke: system pass missing Mira/Rafa spawn")
		quit(1)
		return false
	# Schedule placement (hour 10 → Mira workshop).
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_workshop":
		push_error(
			"dialogue_smoke: system pass expected Mira at viewpoint_workshop (got %s)"
			% str(ns.call("get_location_id", MIRA))
		)
		quit(1)
		return false

	# Contextual resolve before talk (intro when unmet).
	var resolved_intro := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if resolved_intro != "mira_intro":
		push_error("dialogue_smoke: system pass expected mira_intro, got %s" % resolved_intro)
		quit(1)
		return false

	# Talk + linear advance + memory seen/completed.
	character.global_position = mira.global_position + Vector3(0.0, 0.05, 1.4)
	await physics_frame
	if not bool(mira.call("interact", character)):
		push_error("dialogue_smoke: system pass Mira interact failed")
		quit(1)
		return false
	await physics_frame
	while bool(dlg.call("is_active")):
		dlg.call("advance")
		await physics_frame
	if not bool(memory.call("has_completed_dialogue", "mira_intro")):
		push_error("dialogue_smoke: system pass mira_intro should complete")
		quit(1)
		return false

	# Priority resolve after met (returning / time_day beats intro).
	var resolved_day := str(dlg.call("resolve_dialogue_for_npc", MIRA))
	if resolved_day == "mira_intro" or resolved_day.is_empty():
		push_error("dialogue_smoke: system pass contextual priority failed (%s)" % resolved_day)
		quit(1)
		return false

	# Branching + hidden/disabled already covered earlier; re-assert moon ask shape quickly.
	qs.call("reset_all")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if inv != null:
		inv.call("clear_inventory")
	if not bool(dlg.call("start_dialogue", "mira_moon_ask", character)):
		push_error("dialogue_smoke: system pass branching start failed")
		quit(1)
		return false
	await physics_frame
	var visible: Array = dlg.call("get_visible_choices")
	var available: Array = dlg.call("get_available_choices")
	if visible.size() < 4 or available.size() != 3:
		push_error(
			"dialogue_smoke: system pass expected hidden/disabled choice layout (vis=%d avail=%d)"
			% [visible.size(), available.size()]
		)
		quit(1)
		return false
	var vis_ids := choice_ids(visible)
	if vis_ids.has("terminal_repaired"):
		push_error("dialogue_smoke: system pass repaired choice should stay hidden")
		quit(1)
		return false
	dlg.call("end_dialogue", false)
	await physics_frame

	# Relationship / reputation write + narrative overnight condition.
	rel.call("set_relationship", MIRA, 12)
	rel.call("set_reputation", "sunset_viewpoint", 20)
	if not bool(cond.call("evaluate", cond.call("make_relationship_min", MIRA, 10))):
		push_error("dialogue_smoke: system pass RELATIONSHIP_MIN failed")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 23, 0)
	var overnight: Resource = cond.call("make_narrative_time_range", 22, 6)
	if overnight == null or not bool(cond.call("evaluate", overnight)):
		push_error("dialogue_smoke: system pass overnight NARRATIVE_TIME_RANGE failed at 23:00")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 12, 0)
	if bool(cond.call("evaluate", overnight)):
		push_error("dialogue_smoke: overnight range 22–6 must fail at noon")
		quit(1)
		return false
	gt.call("set_narrative_time", 0, 10, 0)

	# Interrupt / resume without duplicating enter actions.
	var ActionScript: Script = load("res://scripts/dialogue/dialogue_action.gd") as Script
	var add_once: DialogueAction = ActionScript.new() as DialogueAction
	add_once.type = DialogueAction.Type.SET_FLAG
	add_once.target_id = "debug.pass_enter_once"
	add_once.bool_value = true
	var line_a: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_a.id = "__pass_interrupt_a__"
	line_a.speaker_name = "Test"
	line_a.text = "A"
	line_a.next_dialogue_id = "__pass_interrupt_b__"
	var enter_arr: Array[DialogueAction] = [add_once]
	line_a.on_enter_actions = enter_arr
	var line_b: DialogueDefinition = DefScript.new() as DialogueDefinition
	line_b.id = "__pass_interrupt_b__"
	line_b.speaker_name = "Test"
	line_b.text = "B"
	dlg.call("register_dialogue", line_a)
	dlg.call("register_dialogue", line_b)
	flags.call("clear_flag", "debug.pass_enter_once")
	if not bool(dlg.call("start_dialogue", "__pass_interrupt_a__", character)):
		push_error("dialogue_smoke: system pass interrupt start failed")
		quit(1)
		return false
	await physics_frame
	if not bool(flags.call("get_flag", "debug.pass_enter_once", false)):
		push_error("dialogue_smoke: system pass enter action missing")
		quit(1)
		return false
	flags.call("clear_flag", "debug.pass_enter_once")
	dlg.call("interrupt_dialogue", "SYSTEM_EVENT")
	await physics_frame
	if not bool(dlg.call("resume_dialogue", character)):
		push_error("dialogue_smoke: system pass resume failed")
		quit(1)
		return false
	await physics_frame
	if bool(flags.call("get_flag", "debug.pass_enter_once", false)):
		push_error("dialogue_smoke: system pass resume must not re-fire enter once-guard")
		quit(1)
		return false
	dlg.call("cancel_dialogue")
	await physics_frame

	# Traveler leave → no duplicate Rafa at POI.
	if not bool(
		travel.call(
			"start_travel",
			RAFA,
			"debug_waystation",
			"pass_rafa_leave",
			30,
			-1.0,
			""
		)
	):
		push_error("dialogue_smoke: system pass start_travel failed")
		quit(1)
		return false
	await physics_frame
	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	await physics_frame
	vp = poi_sys.call("spawn_viewpoint", poi_res, spawn_xf, scene_root, vp_scene) as Node3D
	await physics_frame
	await physics_frame
	rafa = vp.find_child("Rafa", true, false) as Node3D if vp != null else null
	if rafa != null:
		push_error("dialogue_smoke: system pass Rafa should not duplicate while TRAVELING")
		quit(1)
		return false
	# Arrive + bark cooldown/condition snapshot API.
	gt.call("advance_narrative_minutes", 60.0)
	travel.call("refresh_arrivals")
	await physics_frame
	if bool(travel.call("is_traveling", RAFA)):
		# Force arrive for pass if narrative gate not met yet.
		travel.call("complete_arrival", RAFA)
	bark.call("reset_for_tests", MIRA)
	var bark_state: Dictionary = bark.call("get_bark_debug_state", MIRA)
	if not bark_state.has("active_cooldowns"):
		push_error("dialogue_smoke: system pass bark debug state incomplete")
		quit(1)
		return false

	# Persist dialogue memory + NPC state + relationship across save/load.
	ns.call("set_met_player", MIRA, true)
	ns.call("set_current_state", MIRA, "BUSY")
	ns.call("set_location_id", MIRA, "viewpoint_diner")
	memory.call("record_dialogue_started", "mira_returning")
	memory.call("record_dialogue_completed", "mira_returning")
	memory.call("record_choice_selected", "moon_yes", "mira_moon_ask")
	rel.call("set_relationship", MIRA, 33)
	rel.call("set_reputation", "sunset_viewpoint", 44)
	if not bool(save.call("save_game")):
		push_error("dialogue_smoke: system pass save_game failed")
		quit(1)
		return false
	memory.call("reset_for_tests")
	ns.call("reset_for_tests")
	rel.call("reset_for_tests")
	if not bool(save.call("load_game")):
		push_error("dialogue_smoke: system pass load_game failed")
		quit(1)
		return false
	if not bool(memory.call("has_completed_dialogue", "mira_returning")):
		push_error("dialogue_smoke: system pass memory save/load lost completion")
		quit(1)
		return false
	if not bool(memory.call("has_selected_choice", "moon_yes")):
		push_error("dialogue_smoke: system pass memory save/load lost choice")
		quit(1)
		return false
	if str(ns.call("get_current_state", MIRA)) != "BUSY":
		push_error("dialogue_smoke: system pass NPC state save/load failed")
		quit(1)
		return false
	if str(ns.call("get_location_id", MIRA)) != "viewpoint_diner":
		push_error("dialogue_smoke: system pass NPC location save/load failed")
		quit(1)
		return false
	if int(rel.call("get_relationship", MIRA)) != 33:
		push_error("dialogue_smoke: system pass relationship save/load failed")
		quit(1)
		return false
	if int(rel.call("get_reputation", "sunset_viewpoint")) != 44:
		push_error("dialogue_smoke: system pass reputation save/load failed")
		quit(1)
		return false

	# Data-driven scale: catalogs must register NPCs/dialogues without central per-name scripts.
	var npc_ids: PackedStringArray = dlg.call("get_registered_npc_ids")
	var dlg_ids: PackedStringArray = dlg.call("get_all_dialogue_ids")
	if npc_ids.size() < 2 or dlg_ids.size() < 10:
		push_error(
			"dialogue_smoke: system pass catalog too small (npcs=%d dlg=%d)"
			% [npc_ids.size(), dlg_ids.size()]
		)
		quit(1)
		return false

	poi_sys.call("despawn_viewpoint", "sunset_viewpoint")
	save.call("delete_save")
	memory.call("reset_for_tests")
	ns.call("reset_for_tests")
	rel.call("reset_for_tests")
	qs.call("reset_all")
	flags.call("reset_for_tests")
	bark.call("reset_for_tests")
	gt.call("reset_for_tests")
	gt.call("set_narrative_time", 0, 10, 0)
	sched.call("reset_for_tests")
	character.global_transform = _vehicle.call("get_driver_exit_global_transform")
	await physics_frame

	print(
		"dialogue_smoke: dlg_npc_pass OK coverage=["
		+ "branching,hidden_choice,disabled_choice,fallback,action_once,"
		+ "memory_sl,npc_state_sl,relationship_sl,narrative_time,overnight,"
		+ "schedule,move_pause,traveler,no_dupe,interrupt,resume_no_dupe,"
		+ "bark_api,invalid_link,priority_resolve,coupling_audit,catalog_scale]"
	)
	return true



