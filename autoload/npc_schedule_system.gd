extends Node
## Resolves data-driven daily NPC routines from narrative world time.
## Updates NpcStateSystem location / state / schedule_id — does not move Nodes.
## No per-NPC branches. Never reads system clock or travel time.

signal npc_schedule_changed(
	npc_id: String,
	location_id: String,
	state: String,
	activity_id: String,
	schedule_id: String
)

const DEFAULT_CATALOG_PATH := "res://resources/npc/schedules/default_schedule_catalog.tres"

@export var catalog_path: String = DEFAULT_CATALOG_PATH

## npc_id → NpcScheduleData
var _schedules: Dictionary = {}
## npc_id → last applied fingerprint (schedule|location|state|activity)
var _last_applied: Dictionary = {}
## npc_id → activity_id (runtime; not required in NpcState)
var _active_activity: Dictionary = {}


func _ready() -> void:
	reload_catalog()
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt != null and gt.has_signal("narrative_time_changed"):
		if not gt.narrative_time_changed.is_connected(_on_narrative_time_changed):
			gt.narrative_time_changed.connect(_on_narrative_time_changed)
	var save := get_node_or_null("/root/SaveSystem")
	if save != null and save.has_signal("load_completed"):
		if not save.load_completed.is_connected(_on_save_loaded):
			save.load_completed.connect(_on_save_loaded)
	# Initial resolve after peers are ready.
	call_deferred("refresh_all")


func reload_catalog(path: String = "") -> void:
	_schedules.clear()
	_last_applied.clear()
	_active_activity.clear()
	var load_path := path if not path.is_empty() else catalog_path
	if load_path.is_empty():
		return
	var catalog: Resource = load(load_path) as Resource
	if catalog == null:
		push_warning("NpcScheduleSystem: could not load catalog %s" % load_path)
		return
	var list: Array = catalog.get("schedules") if "schedules" in catalog else []
	for item in list:
		register_schedule(item as Resource)


func register_schedule(data: Resource) -> void:
	if data == null:
		return
	var npc_id := str(data.get("npc_id")) if "npc_id" in data else ""
	var schedule_id := str(data.get("schedule_id")) if "schedule_id" in data else ""
	if npc_id.is_empty() or schedule_id.is_empty():
		return
	if "enabled" in data and not bool(data.get("enabled")):
		return
	_schedules[npc_id] = data


func has_schedule(npc_id: String) -> bool:
	return not npc_id.is_empty() and _schedules.has(npc_id)


func get_schedule(npc_id: String) -> Resource:
	if not has_schedule(npc_id):
		return null
	return _schedules[npc_id] as Resource


func get_active_activity_id(npc_id: String) -> String:
	return str(_active_activity.get(npc_id, ""))


func get_active_location_id(npc_id: String) -> String:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null and ns.has_method("get_location_id"):
		return str(ns.call("get_location_id", npc_id))
	return ""


func get_active_state(npc_id: String) -> String:
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null and ns.has_method("get_current_state"):
		return str(ns.call("get_current_state", npc_id))
	return ""


func resolve_active_entry(npc_id: String, hour_of_day: int = -1) -> Resource:
	var data := get_schedule(npc_id)
	if data == null:
		return null
	var hour := hour_of_day
	if hour < 0:
		hour = _narrative_hour()
	if data.has_method("resolve_entry"):
		return data.call("resolve_entry", hour) as Resource
	return null


func refresh_npc(npc_id: String) -> void:
	if npc_id.is_empty() or not _schedules.has(npc_id):
		return
	_apply_for_npc(npc_id, _narrative_hour())


func refresh_all() -> void:
	var hour := _narrative_hour()
	for npc_id in _schedules.keys():
		_apply_for_npc(str(npc_id), hour)


func reset_for_tests() -> void:
	_last_applied.clear()
	_active_activity.clear()
	reload_catalog()
	refresh_all()


func _on_narrative_time_changed(_day: int, hour: int, _minute: int = 0) -> void:
	for npc_id in _schedules.keys():
		_apply_for_npc(str(npc_id), hour)


func _on_save_loaded(_path: String = "") -> void:
	## Re-resolve against loaded narrative clock so logical routine matches current hour.
	call_deferred("refresh_all")


func _apply_for_npc(npc_id: String, hour: int) -> void:
	var data: Resource = _schedules.get(npc_id) as Resource
	if data == null:
		return
	var ns := get_node_or_null("/root/NpcStateSystem")
	if ns != null:
		if ns.has_method("ensure_npc"):
			ns.call("ensure_npc", npc_id)
		# Travelers mid-relocation / after leaving a POI must not be yanked by local routines.
		if ns.has_method("get_travel_state") and str(ns.call("get_travel_state", npc_id)) == "TRAVELING":
			return
		if ns.has_method("follows_local_schedule") and not bool(ns.call("follows_local_schedule", npc_id)):
			return

	var schedule_id := str(data.get("schedule_id"))
	var entry: Resource = null
	if data.has_method("resolve_entry"):
		entry = data.call("resolve_entry", hour) as Resource

	var location_id := ""
	var state := ""
	var activity_id := ""
	if entry != null:
		location_id = str(entry.get("location_id"))
		state = str(entry.get("state"))
		activity_id = str(entry.get("activity_id"))
	else:
		location_id = str(data.get("fallback_location_id"))
		state = str(data.get("fallback_state"))
		activity_id = str(data.get("fallback_activity_id"))

	# Emit only when logical activity changes (not every narrative minute).
	var logical := "%s|%s|%s|%s" % [schedule_id, location_id, state, activity_id]
	var previous_logical := str(_last_applied.get(npc_id, ""))
	_active_activity[npc_id] = activity_id

	if ns != null:
		if ns.has_method("set_schedule_id"):
			ns.call("set_schedule_id", npc_id, schedule_id)
		if not location_id.is_empty() and ns.has_method("set_location_id"):
			ns.call("set_location_id", npc_id, location_id)
		# Empty state = leave NpcState.current_state alone (dialogue overrides stay).
		if not state.is_empty() and ns.has_method("set_current_state"):
			ns.call("set_current_state", npc_id, state)

	if logical != previous_logical:
		_last_applied[npc_id] = logical
		npc_schedule_changed.emit(npc_id, location_id, state, activity_id, schedule_id)
	else:
		_last_applied[npc_id] = logical


func _narrative_hour() -> int:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt != null and gt.has_method("get_narrative_hour"):
		return int(gt.call("get_narrative_hour"))
	if gt != null and gt.has_method("get_hour_of_day"):
		return int(gt.call("get_hour_of_day"))
	return 0
