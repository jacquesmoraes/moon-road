extends Node
## Contextual short NPC lines (barks). Never opens the full conversation UI.
## Selection: conditions → priority → cooldown / anti-repeat → optional weight.
## Dialogue ACTIVE always blocks barking. No per-NPC name branches.

signal bark_requested(npc_id: String, bark_id: String, text: String)
signal bark_suppressed(npc_id: String, reason: String)

const RECENT_BARK_LIMIT: int = 3
## Minimum real seconds between any two barks for the same NPC.
const MIN_GAP_SECONDS: float = 8.0
## Default TIME_INTERVAL spacing when definition omits bark_interval_seconds.
const DEFAULT_INTERVAL_SECONDS: float = 60.0
const TRIGGER_PLAYER_NEARBY := "PLAYER_NEARBY"
const TRIGGER_PLAYER_ENTER_AREA := "PLAYER_ENTER_AREA"
const TRIGGER_TIME_INTERVAL := "TIME_INTERVAL"
const TRIGGER_NPC_STATE_CHANGED := "NPC_STATE_CHANGED"

## npc_id → weak presenter Node (NpcCharacter)
var _presenters: Dictionary = {}
## npc_id → runtime anti-spam state
var _runtime: Dictionary = {}


func _ready() -> void:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null and ns.has_signal("npc_state_changed"):
		if not ns.npc_state_changed.is_connected(_on_npc_state_changed):
			ns.npc_state_changed.connect(_on_npc_state_changed)
	set_process(true)


func register_presenter(npc_id: String, presenter: Node) -> void:
	if npc_id.is_empty() or presenter == null:
		return
	_presenters[npc_id] = presenter
	_ensure_runtime(npc_id)


func unregister_presenter(npc_id: String, presenter: Node = null) -> void:
	if npc_id.is_empty():
		return
	if presenter != null and _presenters.get(npc_id) != presenter:
		return
	_presenters.erase(npc_id)


func try_bark(npc_id: String, trigger: String) -> bool:
	## Pick and show one bark for trigger. Returns true when a bark was shown.
	if npc_id.is_empty():
		return false
	var tag := trigger.strip_edges().to_upper()
	if tag.is_empty():
		return false
	if _dialogue_blocks_bark():
		bark_suppressed.emit(npc_id, "dialogue_active")
		return false
	var presenter: Node = _presenters.get(npc_id, null)
	if presenter == null or not is_instance_valid(presenter):
		_presenters.erase(npc_id)
		return false
	if presenter.has_method("is_npc_enabled") and not bool(presenter.call("is_npc_enabled")):
		return false
	if presenter.has_method("is_within_availability_window"):
		if not bool(presenter.call("is_within_availability_window")):
			return false

	_ensure_runtime(npc_id)
	var runtime: Dictionary = _runtime[npc_id]
	var now := _now_seconds()
	if now - float(runtime.get("last_bark_time", -9999.0)) < MIN_GAP_SECONDS:
		bark_suppressed.emit(npc_id, "min_gap")
		return false

	if tag == TRIGGER_TIME_INTERVAL:
		var interval := _interval_seconds_for(presenter)
		if now - float(runtime.get("last_interval_attempt", -9999.0)) < interval:
			bark_suppressed.emit(npc_id, "interval_gate")
			return false
		runtime["last_interval_attempt"] = now

	var rules := _collect_rules(presenter)
	var chosen := _select_bark(npc_id, rules, tag, now)
	if chosen == null:
		bark_suppressed.emit(npc_id, "no_candidate")
		return false
	return _emit_bark(npc_id, chosen, presenter, now)


func get_last_bark_id(npc_id: String) -> String:
	_ensure_runtime(npc_id)
	return str(_runtime[npc_id].get("last_bark_id", ""))


func get_recent_bark_ids(npc_id: String) -> PackedStringArray:
	_ensure_runtime(npc_id)
	var recent: Array = _runtime[npc_id].get("recent_barks", [])
	var out: PackedStringArray = PackedStringArray()
	for entry in recent:
		out.append(str(entry))
	return out


## Debug snapshot: last bark, recent ids, cooldown remaining (seconds), gap remaining.
func get_bark_debug_state(npc_id: String) -> Dictionary:
	if npc_id.is_empty():
		return {}
	_ensure_runtime(npc_id)
	var runtime: Dictionary = _runtime[npc_id]
	var now := _now_seconds()
	var last_time := float(runtime.get("last_bark_time", -9999.0))
	var gap_left := maxf(MIN_GAP_SECONDS - (now - last_time), 0.0)
	var cool_raw: Dictionary = runtime.get("bark_cooldowns", {})
	var cooldowns: Dictionary = {}
	for key in cool_raw.keys():
		var until := float(cool_raw[key])
		var left := maxf(until - now, 0.0)
		if left > 0.0:
			cooldowns[str(key)] = snappedf(left, 0.1)
	return {
		"last_bark_id": str(runtime.get("last_bark_id", "")),
		"recent_bark_ids": get_recent_bark_ids(npc_id),
		"min_gap_remaining": snappedf(gap_left, 0.1),
		"active_cooldowns": cooldowns,
		"has_presenter": _presenters.has(npc_id)
			and _presenters.get(npc_id) != null
			and is_instance_valid(_presenters.get(npc_id)),
	}


func reset_for_tests(npc_id: String = "") -> void:
	if npc_id.is_empty():
		_runtime.clear()
		return
	_runtime.erase(npc_id)


func _process(_delta: float) -> void:
	## TIME_INTERVAL ticks for registered presenters (gated; no spam).
	var now := _now_seconds()
	for npc_id in _presenters.keys():
		var id := str(npc_id)
		var presenter: Node = _presenters.get(id, null)
		if presenter == null or not is_instance_valid(presenter):
			_presenters.erase(id)
			continue
		if presenter.has_method("is_bark_player_nearby") and not bool(presenter.call("is_bark_player_nearby")):
			continue
		_ensure_runtime(id)
		var runtime: Dictionary = _runtime[id]
		var interval := _interval_seconds_for(presenter)
		if now - float(runtime.get("last_interval_attempt", -9999.0)) < interval:
			continue
		try_bark(id, TRIGGER_TIME_INTERVAL)


func _emit_bark(npc_id: String, bark: Resource, presenter: Node, now: float) -> bool:
	var bark_id := str(bark.get("id"))
	var text := str(bark.get("text"))
	if bark_id.is_empty() or text.is_empty():
		return false
	var runtime: Dictionary = _runtime[npc_id]
	runtime["last_bark_id"] = bark_id
	runtime["last_bark_time"] = now
	var cooldowns: Dictionary = runtime.get("bark_cooldowns", {})
	cooldowns[bark_id] = now + maxf(float(bark.get("cooldown_seconds")), 0.0)
	runtime["bark_cooldowns"] = cooldowns
	var recent: Array = runtime.get("recent_barks", [])
	recent.append(bark_id)
	while recent.size() > RECENT_BARK_LIMIT:
		recent.pop_front()
	runtime["recent_barks"] = recent
	_runtime[npc_id] = runtime

	if presenter.has_method("display_bark"):
		presenter.call("display_bark", text, bark_id)
	bark_requested.emit(npc_id, bark_id, text)
	return true


func _select_bark(npc_id: String, rules: Array, trigger: String, now: float) -> Resource:
	var runtime: Dictionary = _runtime[npc_id]
	var last_id := str(runtime.get("last_bark_id", ""))
	var recent: Array = runtime.get("recent_barks", [])
	var cooldowns: Dictionary = runtime.get("bark_cooldowns", {})
	var cond_sys := get_node_or_null("/root/ConditionSystem")

	var best_priority := -2147483648
	var pool: Array = []
	var found := false

	for entry in rules:
		if entry == null:
			continue
		if "enabled" in entry and not bool(entry.get("enabled")):
			continue
		var bark_id := str(entry.get("id"))
		var text := str(entry.get("text"))
		if bark_id.is_empty() or text.is_empty():
			continue
		if entry.has_method("supports_trigger"):
			if not bool(entry.call("supports_trigger", trigger)):
				continue
		elif not _supports_trigger_fallback(entry, trigger):
			continue
		var cool_until := float(cooldowns.get(bark_id, -1.0))
		if cool_until > now:
			continue
		if not _conditions_pass(cond_sys, entry):
			continue
		var priority := int(entry.get("priority"))
		if not found or priority > best_priority:
			found = true
			best_priority = priority
			pool = [entry]
		elif priority == best_priority:
			pool.append(entry)

	if pool.is_empty():
		return null

	# Prefer candidates that are not the last bark / not in recent when alternatives exist.
	var filtered: Array = []
	for entry in pool:
		var bark_id := str(entry.get("id"))
		if bark_id == last_id:
			continue
		if recent.has(bark_id):
			continue
		filtered.append(entry)
	if filtered.is_empty():
		filtered = pool
	return _weighted_pick(filtered)


func _weighted_pick(candidates: Array) -> Resource:
	if candidates.is_empty():
		return null
	if candidates.size() == 1:
		return candidates[0] as Resource
	var total := 0.0
	for entry in candidates:
		var w := 1.0
		if entry != null and entry.has_method("get_weight"):
			w = float(entry.call("get_weight"))
		elif entry != null:
			w = maxf(float(entry.get("weight")), 0.0001)
		total += w
	var roll := randf() * total
	var acc := 0.0
	for entry in candidates:
		var w := 1.0
		if entry != null and entry.has_method("get_weight"):
			w = float(entry.call("get_weight"))
		elif entry != null:
			w = maxf(float(entry.get("weight")), 0.0001)
		acc += w
		if roll <= acc:
			return entry as Resource
	return candidates[candidates.size() - 1] as Resource


func _conditions_pass(cond_sys: Node, bark: Resource) -> bool:
	var conditions: Array = []
	var raw: Variant = bark.get("conditions")
	if typeof(raw) == TYPE_ARRAY:
		conditions = raw
	if conditions.is_empty():
		return true
	if cond_sys == null:
		return false
	var require_all := true
	if "require_all" in bark:
		require_all = bool(bark.get("require_all"))
	if require_all:
		if cond_sys.has_method("evaluate_all"):
			return bool(cond_sys.call("evaluate_all", conditions))
		for entry in conditions:
			if entry == null:
				continue
			if not bool(cond_sys.call("evaluate", entry)):
				return false
		return true
	if cond_sys.has_method("evaluate_any"):
		return bool(cond_sys.call("evaluate_any", conditions))
	for entry in conditions:
		if entry == null:
			continue
		if bool(cond_sys.call("evaluate", entry)):
			return true
	return false


func _collect_rules(presenter: Node) -> Array:
	if presenter == null:
		return []
	if presenter.has_method("get_bark_rules"):
		var rules: Variant = presenter.call("get_bark_rules")
		if typeof(rules) == TYPE_ARRAY:
			return rules
	var definition: Resource = null
	if "definition" in presenter:
		definition = presenter.get("definition") as Resource
	if definition != null and "bark_rules" in definition:
		var raw: Variant = definition.get("bark_rules")
		if typeof(raw) == TYPE_ARRAY:
			return raw
	return []


func _interval_seconds_for(presenter: Node) -> float:
	if presenter != null and presenter.has_method("get_bark_interval_seconds"):
		return maxf(float(presenter.call("get_bark_interval_seconds")), MIN_GAP_SECONDS)
	if presenter != null and "definition" in presenter:
		var definition: Resource = presenter.get("definition") as Resource
		if definition != null and "bark_interval_seconds" in definition:
			return maxf(float(definition.get("bark_interval_seconds")), MIN_GAP_SECONDS)
	return DEFAULT_INTERVAL_SECONDS


func _supports_trigger_fallback(entry: Resource, trigger: String) -> bool:
	var raw: Variant = entry.get("triggers")
	if typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		var arr: PackedStringArray = raw
		if arr.is_empty():
			return trigger == TRIGGER_PLAYER_NEARBY or trigger == TRIGGER_PLAYER_ENTER_AREA
		for t in arr:
			if str(t).to_upper() == trigger:
				return true
		return false
	if typeof(raw) == TYPE_ARRAY:
		if (raw as Array).is_empty():
			return trigger == TRIGGER_PLAYER_NEARBY or trigger == TRIGGER_PLAYER_ENTER_AREA
		for t in raw:
			if str(t).to_upper() == trigger:
				return true
		return false
	return trigger == TRIGGER_PLAYER_NEARBY or trigger == TRIGGER_PLAYER_ENTER_AREA


func _dialogue_blocks_bark() -> bool:
	var dlg := get_node_or_null("/root/DialogueSystem")
	if dlg != null and dlg.has_method("is_active") and bool(dlg.call("is_active")):
		return true
	return false


func _on_npc_state_changed(npc_id: String, _field: String, _value: Variant) -> void:
	if npc_id.is_empty() or not _presenters.has(npc_id):
		return
	try_bark(npc_id, TRIGGER_NPC_STATE_CHANGED)


func _ensure_runtime(npc_id: String) -> void:
	if _runtime.has(npc_id):
		return
	var now := _now_seconds()
	_runtime[npc_id] = {
		"last_bark_id": "",
		"last_bark_time": -9999.0,
		# Wait a full interval before the first automatic TIME_INTERVAL tick.
		"last_interval_attempt": now,
		"recent_barks": [],
		"bark_cooldowns": {},
	}


func _now_seconds() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
