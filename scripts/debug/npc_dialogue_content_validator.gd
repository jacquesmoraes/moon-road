extends RefCounted
class_name NpcDialogueContentValidator
## Static content checks for NPC / dialogue catalogs. Headless-safe (no UI).
## Does not mutate gameplay systems. Isolated from ship gameplay paths.

const DEFAULT_DIALOGUE_CATALOG := "res://resources/dialogue/default_catalog.tres"
const DEFAULT_NPC_CATALOG := "res://resources/npc/default_npc_catalog.tres"
const DEFAULT_SCHEDULE_CATALOG := "res://resources/npc/schedules/default_schedule_catalog.tres"

var _issues: Array = []


func validate(
	dialogue_catalog_path: String = DEFAULT_DIALOGUE_CATALOG,
	npc_catalog_path: String = DEFAULT_NPC_CATALOG,
	schedule_catalog_path: String = DEFAULT_SCHEDULE_CATALOG
) -> Dictionary:
	_issues.clear()
	var dialogue_ids: Dictionary = {}
	var npc_ids: Dictionary = {}

	_scan_dialogue_catalog(dialogue_catalog_path, dialogue_ids)
	_scan_npc_catalog(npc_catalog_path, npc_ids, dialogue_ids)
	_scan_schedule_catalog(schedule_catalog_path, npc_ids)

	var by_severity: Dictionary = {}
	for issue in _issues:
		var sev := str(issue.get("severity", "error"))
		by_severity[sev] = int(by_severity.get(sev, 0)) + 1

	return {
		"ok": _issues.is_empty(),
		"issue_count": _issues.size(),
		"issues": _issues.duplicate(true),
		"counts_by_severity": by_severity,
		"dialogue_count": dialogue_ids.size(),
		"npc_count": npc_ids.size(),
	}


func format_report(result: Dictionary) -> String:
	if result.is_empty():
		return "(no report)"
	var lines: PackedStringArray = PackedStringArray()
	lines.append(
		"NPC/Dialogue validation: %s (%d issues, %d npcs, %d dialogues)"
		% [
			"OK" if bool(result.get("ok", false)) else "FAIL",
			int(result.get("issue_count", 0)),
			int(result.get("npc_count", 0)),
			int(result.get("dialogue_count", 0)),
		]
	)
	var issues: Array = result.get("issues", [])
	if issues.is_empty():
		lines.append("  (no issues)")
		return "\n".join(lines)
	for issue in issues:
		lines.append(
			"  [%s] %s — %s"
			% [str(issue.get("severity", "?")), str(issue.get("code", "?")), str(issue.get("message", ""))]
		)
	return "\n".join(lines)


func _scan_dialogue_catalog(path: String, dialogue_ids: Dictionary) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		_add("error", "missing_dialogue_catalog", "Dialogue catalog missing: %s" % path)
		return
	var catalog: Resource = load(path) as Resource
	if catalog == null:
		_add("error", "missing_dialogue_catalog", "Could not load dialogue catalog: %s" % path)
		return
	var entries: Array = []
	if "entries" in catalog:
		var raw: Variant = catalog.get("entries")
		if typeof(raw) == TYPE_ARRAY:
			entries = raw
	var seen: Dictionary = {}
	for entry in entries:
		if entry == null:
			continue
		var dlg_id := str(entry.get("id"))
		if dlg_id.is_empty():
			_add("error", "missing_dialogue_id", "Dialogue entry has empty id")
			continue
		if seen.has(dlg_id):
			_add("error", "duplicate_dialogue_id", "Duplicate dialogue_id '%s'" % dlg_id, dlg_id)
		seen[dlg_id] = true
		dialogue_ids[dlg_id] = entry
	# Second pass: links + actions + conditions (needs full id set).
	for dlg_id in dialogue_ids.keys():
		var entry: Resource = dialogue_ids[dlg_id]
		_check_dialogue_links(entry, dialogue_ids)
		_check_condition_list(entry, "show_conditions", "dialogue:%s" % dlg_id)
		_check_action_list(entry, "on_enter_actions", "dialogue:%s" % dlg_id)
		_check_action_list(entry, "on_exit_actions", "dialogue:%s" % dlg_id)
		var choices: Variant = entry.get("choices") if "choices" in entry else []
		if typeof(choices) == TYPE_ARRAY:
			for choice in choices:
				if choice == null:
					continue
				var choice_id := str(choice.get("id"))
				var next_id := str(choice.get("next_dialogue_id"))
				if not next_id.is_empty() and not dialogue_ids.has(next_id):
					_add(
						"error",
						"choice_missing_dialogue",
						"Choice '%s' on '%s' → missing dialogue '%s'" % [choice_id, dlg_id, next_id],
						dlg_id
					)
				_check_condition_list(choice, "show_conditions", "choice:%s/%s" % [dlg_id, choice_id])
				_check_condition_list(choice, "enable_conditions", "choice:%s/%s" % [dlg_id, choice_id])
				_check_condition_list(choice, "conditions", "choice:%s/%s" % [dlg_id, choice_id])
				_check_action_list(choice, "on_choose_actions", "choice:%s/%s" % [dlg_id, choice_id])


func _check_dialogue_links(entry: Resource, dialogue_ids: Dictionary) -> void:
	var dlg_id := str(entry.get("id"))
	var next_id := str(entry.get("next_dialogue_id")) if "next_dialogue_id" in entry else ""
	if not next_id.is_empty() and not dialogue_ids.has(next_id):
		_add(
			"error",
			"missing_next_dialogue_id",
			"Dialogue '%s' next_dialogue_id '%s' missing" % [dlg_id, next_id],
			dlg_id
		)
	var fallback := str(entry.get("fallback_dialogue_id")) if "fallback_dialogue_id" in entry else ""
	if not fallback.is_empty() and not dialogue_ids.has(fallback):
		_add(
			"error",
			"missing_dialogue_id",
			"Dialogue '%s' fallback_dialogue_id '%s' missing" % [dlg_id, fallback],
			dlg_id
		)


func _scan_npc_catalog(path: String, npc_ids: Dictionary, dialogue_ids: Dictionary) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		_add("error", "missing_npc_catalog", "NPC catalog missing: %s" % path)
		return
	var catalog: Resource = load(path) as Resource
	if catalog == null:
		_add("error", "missing_npc_catalog", "Could not load NPC catalog: %s" % path)
		return
	var entries: Array = []
	if "entries" in catalog:
		var raw: Variant = catalog.get("entries")
		if typeof(raw) == TYPE_ARRAY:
			entries = raw
	var seen: Dictionary = {}
	for entry in entries:
		if entry == null:
			continue
		var npc_id := str(entry.get("npc_id"))
		if npc_id.is_empty():
			_add("error", "missing_npc_id", "NpcDefinition has empty npc_id")
			continue
		if seen.has(npc_id):
			_add("error", "duplicate_npc_id", "Duplicate npc_id '%s'" % npc_id, npc_id)
		seen[npc_id] = true
		npc_ids[npc_id] = entry
		var fallback := ""
		if entry.has_method("get_fallback_dialogue_id"):
			fallback = str(entry.call("get_fallback_dialogue_id"))
		else:
			fallback = str(entry.get("fallback_dialogue_id"))
			if fallback.is_empty():
				fallback = str(entry.get("dialogue_id"))
		if fallback.is_empty():
			_add(
				"warning",
				"missing_dialogue_id",
				"NPC '%s' has empty fallback_dialogue_id" % npc_id,
				npc_id
			)
		elif not dialogue_ids.has(fallback):
			_add(
				"error",
				"missing_dialogue_id",
				"NPC '%s' fallback_dialogue_id '%s' missing" % [npc_id, fallback],
				npc_id
			)
		if "dialogue_rules" in entry:
			var rules: Variant = entry.get("dialogue_rules")
			if typeof(rules) == TYPE_ARRAY:
				for rule in rules:
					if rule == null:
						continue
					var rule_dlg := str(rule.get("dialogue_id"))
					var rule_id := str(rule.get("id"))
					if rule_dlg.is_empty():
						_add(
							"error",
							"missing_dialogue_id",
							"NPC '%s' rule '%s' has empty dialogue_id" % [npc_id, rule_id],
							npc_id
						)
					elif not dialogue_ids.has(rule_dlg):
						_add(
							"error",
							"missing_dialogue_id",
							"NPC '%s' rule '%s' → missing dialogue '%s'" % [npc_id, rule_id, rule_dlg],
							npc_id
						)
					_check_condition_list(rule, "conditions", "npc_rule:%s/%s" % [npc_id, rule_id])
		if "bark_rules" in entry:
			var barks: Variant = entry.get("bark_rules")
			if typeof(barks) == TYPE_ARRAY:
				for bark in barks:
					if bark == null:
						continue
					_check_condition_list(
						bark, "conditions", "bark:%s/%s" % [npc_id, str(bark.get("id"))]
					)


func _scan_schedule_catalog(path: String, npc_ids: Dictionary) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		# Schedules optional for some prototypes — warn only.
		_add("warning", "missing_schedule_catalog", "Schedule catalog missing: %s" % path)
		return
	var catalog: Resource = load(path) as Resource
	if catalog == null:
		_add("warning", "missing_schedule_catalog", "Could not load schedule catalog: %s" % path)
		return
	var schedules: Array = []
	if "schedules" in catalog:
		var raw: Variant = catalog.get("schedules")
		if typeof(raw) == TYPE_ARRAY:
			schedules = raw
	for schedule in schedules:
		if schedule == null:
			continue
		var schedule_id := str(schedule.get("schedule_id"))
		var npc_id := str(schedule.get("npc_id"))
		var fallback_loc := str(schedule.get("fallback_location_id"))
		if fallback_loc.is_empty():
			_add(
				"error",
				"schedule_without_fallback",
				"Schedule '%s' (npc '%s') missing fallback_location_id" % [schedule_id, npc_id],
				schedule_id
			)
		var entries: Array = []
		if "entries" in schedule:
			var raw_e: Variant = schedule.get("entries")
			if typeof(raw_e) == TYPE_ARRAY:
				entries = raw_e
		for entry in entries:
			if entry == null:
				continue
			if "enabled" in entry and not bool(entry.get("enabled")):
				continue
			var loc := str(entry.get("location_id"))
			if loc.is_empty():
				_add(
					"error",
					"empty_required_location_id",
					"Schedule '%s' entry has empty location_id" % schedule_id,
					schedule_id
				)


func _check_condition_list(owner: Variant, property: String, context: String) -> void:
	if owner == null or not (property in owner):
		return
	var raw: Variant = owner.get(property)
	if typeof(raw) != TYPE_ARRAY:
		return
	for cond in raw:
		if cond == null:
			continue
		var type_name := ""
		if cond.has_method("get_type_name"):
			type_name = str(cond.call("get_type_name"))
		else:
			type_name = "UNKNOWN"
		if type_name.is_empty() or type_name == "UNKNOWN":
			_add(
				"error",
				"invalid_unknown_condition",
				"Unknown/invalid condition on %s" % context,
				context
			)


func _check_action_list(owner: Variant, property: String, context: String) -> void:
	if owner == null or not (property in owner):
		return
	var raw: Variant = owner.get(property)
	if typeof(raw) != TYPE_ARRAY:
		return
	for action in raw:
		if action == null:
			continue
		var type_name := ""
		if action.has_method("get_type_name"):
			type_name = str(action.call("get_type_name"))
		else:
			type_name = "UNKNOWN"
		if type_name.is_empty() or type_name == "UNKNOWN":
			_add(
				"error",
				"unknown_action_type",
				"Unknown action type on %s" % context,
				context
			)


func _add(severity: String, code: String, message: String, id: String = "") -> void:
	_issues.append({
		"severity": severity,
		"code": code,
		"message": message,
		"id": id,
	})
