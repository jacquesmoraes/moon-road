extends Node
## Logical NPC relocation between POIs/cities — no continuous physical travel.
## Presence: AT_LOCATION vs TRAVELING. Arrival via narrative time / journey km / flag.
## No per-NPC name branches.
## Peer binds use deferred `_initialize_dependencies` (not autoload order alone).

signal npc_travel_started(
	npc_id: String,
	from_location_id: String,
	destination_location_id: String,
	transition_id: String
)
signal npc_arrived(
	npc_id: String,
	location_id: String,
	transition_id: String
)
signal npc_presence_changed(npc_id: String)
signal init_state_changed(state: String)

const Bootstrap := preload("res://scripts/core/autoload_bootstrap.gd")

## Required: GameTimeSystem + NpcStateSystem. Optional: Journey, GameFlags, SaveSystem.
var _required_paths: PackedStringArray = PackedStringArray([
	"/root/GameTimeSystem",
	"/root/NpcStateSystem",
])

var _init_state: String = Bootstrap.STATE_UNINITIALIZED
var _init_attempts: int = 0


func _ready() -> void:
	call_deferred("_initialize_dependencies")


func get_init_state() -> String:
	return _init_state


func is_system_ready() -> bool:
	return _init_state == Bootstrap.STATE_READY


func _initialize_dependencies() -> void:
	if _init_state == Bootstrap.STATE_READY:
		return
	_set_init_state(Bootstrap.STATE_INITIALIZING)
	_init_attempts += 1

	var gt := get_node_or_null("/root/GameTimeSystem")
	var ns := get_node_or_null("/root/NpcStateSystem")
	var gt_ok := Bootstrap.try_connect(gt, "narrative_time_changed", _on_narrative_time_changed)
	var ns_ok := ns != null

	var journey := get_node_or_null("/root/JourneySystem")
	Bootstrap.try_connect(journey, "distance_changed", _on_journey_distance_changed)
	var flags := get_node_or_null("/root/GameFlags")
	Bootstrap.try_connect(flags, "flag_changed", _on_flag_changed)
	var save := get_node_or_null("/root/SaveSystem")
	Bootstrap.try_connect(save, "load_completed", _on_save_loaded)

	if gt_ok and ns_ok:
		_set_init_state(Bootstrap.STATE_READY)
		refresh_arrivals()
		return

	if _init_attempts >= Bootstrap.DEFAULT_MAX_ATTEMPTS:
		_set_init_state(Bootstrap.STATE_FAILED)
		var missing := Bootstrap.missing_paths(
			get_tree().root if get_tree() != null else self, _required_paths
		)
		push_error(
			"NpcTravelSystem: required peers missing after %d attempts: %s"
			% [_init_attempts, ", ".join(missing)]
		)
		return
	call_deferred("_initialize_dependencies")


func _set_init_state(next: String) -> void:
	if _init_state == next:
		return
	_init_state = next
	init_state_changed.emit(next)


func start_travel(
	npc_id: String,
	destination_location_id: String,
	transition_id: String = "",
	narrative_delay_minutes: int = -1,
	journey_km_min: float = -1.0,
	arrival_flag_id: String = ""
) -> bool:
	## Begin logical travel. Removes presence at current location; does not simulate the road.
	if npc_id.is_empty() or destination_location_id.is_empty():
		push_warning("NpcTravelSystem: start_travel needs npc_id + destination")
		return false
	var ns := _npc_state()
	if ns == null:
		return false
	ns.call("ensure_npc", npc_id)
	if str(ns.call("get_travel_state", npc_id)) == ns.TRAVEL_STATE_TRAVELING:
		# Already traveling — retarget destination / arrival if needed.
		pass
	var from_id := str(ns.call("get_location_id", npc_id))
	ns.call("set_previous_location_id", npc_id, from_id)
	ns.call("set_destination_location_id", npc_id, destination_location_id)
	ns.call("set_travel_state", npc_id, ns.TRAVEL_STATE_TRAVELING)
	ns.call("set_follow_local_schedule", npc_id, false)
	if ns.has_method("set_current_state"):
		ns.call("set_current_state", npc_id, ns.STATE_TRAVELING)
	if not transition_id.is_empty():
		ns.call("set_last_transition_id", npc_id, transition_id)

	ns.call("clear_arrival_conditions", npc_id)
	var any_condition := false
	if narrative_delay_minutes >= 0:
		var arrive_at := _narrative_total_minutes() + narrative_delay_minutes
		ns.call("set_arrival_narrative_total_minutes", npc_id, arrive_at)
		any_condition = true
	if journey_km_min >= 0.0:
		ns.call("set_arrival_journey_km_min", npc_id, journey_km_min)
		any_condition = true
	if not arrival_flag_id.is_empty():
		ns.call("set_arrival_flag_id", npc_id, arrival_flag_id)
		any_condition = true
	if not any_condition:
		# No gate authored → complete on next refresh (brief TRAVELING).
		pass

	npc_travel_started.emit(npc_id, from_id, destination_location_id, transition_id)
	npc_presence_changed.emit(npc_id)
	refresh_arrivals()
	return true


func complete_arrival(npc_id: String) -> bool:
	if npc_id.is_empty():
		return false
	var ns := _npc_state()
	if ns == null:
		return false
	if str(ns.call("get_travel_state", npc_id)) != ns.TRAVEL_STATE_TRAVELING:
		return false
	var dest := str(ns.call("get_destination_location_id", npc_id))
	if dest.is_empty():
		push_warning("NpcTravelSystem: complete_arrival missing destination for %s" % npc_id)
		return false
	var transition_id := str(ns.call("get_last_transition_id", npc_id))
	ns.call("set_location_id", npc_id, dest)
	ns.call("set_travel_state", npc_id, ns.TRAVEL_STATE_AT_LOCATION)
	ns.call("set_destination_location_id", npc_id, "")
	ns.call("clear_arrival_conditions", npc_id)
	ns.call("set_follow_local_schedule", npc_id, false)
	if ns.has_method("set_current_state"):
		# Leave TRAVELING tag; restore DEFAULT for interactable travelers.
		ns.call("set_current_state", npc_id, ns.STATE_DEFAULT)
	npc_arrived.emit(npc_id, dest, transition_id)
	npc_presence_changed.emit(npc_id)
	return true


func set_at_location(npc_id: String, location_id: String, transition_id: String = "") -> bool:
	## Instant logical place (DialogueAction SET_NPC_LOCATION). Not road travel.
	if npc_id.is_empty():
		return false
	var ns := _npc_state()
	if ns == null:
		return false
	ns.call("ensure_npc", npc_id)
	var previous := str(ns.call("get_location_id", npc_id))
	if previous != location_id:
		ns.call("set_previous_location_id", npc_id, previous)
	ns.call("set_location_id", npc_id, location_id)
	ns.call("set_travel_state", npc_id, ns.TRAVEL_STATE_AT_LOCATION)
	ns.call("set_destination_location_id", npc_id, "")
	ns.call("clear_arrival_conditions", npc_id)
	if not transition_id.is_empty():
		ns.call("set_last_transition_id", npc_id, transition_id)
	npc_presence_changed.emit(npc_id)
	return true


func is_traveling(npc_id: String) -> bool:
	var ns := _npc_state()
	if ns == null or npc_id.is_empty():
		return false
	return str(ns.call("get_travel_state", npc_id)) == ns.TRAVEL_STATE_TRAVELING


func is_at_location(npc_id: String, location_id: String) -> bool:
	var ns := _npc_state()
	if ns == null or npc_id.is_empty() or location_id.is_empty():
		return false
	if str(ns.call("get_travel_state", npc_id)) != ns.TRAVEL_STATE_AT_LOCATION:
		return false
	return str(ns.call("get_location_id", npc_id)) == location_id


func should_spawn_at_poi(
	npc_id: String, poi_id: String, local_location_ids: PackedStringArray = PackedStringArray()
) -> bool:
	## Physical instance belongs here only when AT_LOCATION and location matches POI/markers.
	if npc_id.is_empty():
		return false
	var ns := _npc_state()
	if ns == null:
		return true
	ns.call("ensure_npc", npc_id)
	if ns.has_method("is_enabled") and not bool(ns.call("is_enabled", npc_id)):
		return false
	if str(ns.call("get_travel_state", npc_id)) == ns.TRAVEL_STATE_TRAVELING:
		return false
	var loc := str(ns.call("get_location_id", npc_id))
	if loc.is_empty():
		# Unassigned — allow authored scene placement to bootstrap state.
		return true
	if not poi_id.is_empty() and loc == poi_id:
		return true
	for marker_id in local_location_ids:
		if loc == str(marker_id):
			return true
	return false


func refresh_arrivals() -> void:
	var ns := _npc_state()
	if ns == null or not ns.has_method("get_traveling_npc_ids"):
		return
	var traveling: PackedStringArray = ns.call("get_traveling_npc_ids")
	for npc_id in traveling:
		if _is_arrival_ready(str(npc_id)):
			complete_arrival(str(npc_id))


func reset_for_tests() -> void:
	## Stateless coordinator — arrival checks only.
	refresh_arrivals()


func _is_arrival_ready(npc_id: String) -> bool:
	var ns := _npc_state()
	if ns == null:
		return false
	var narrative_at: int = int(ns.call("get_arrival_narrative_total_minutes", npc_id))
	var journey_min: float = float(ns.call("get_arrival_journey_km_min", npc_id))
	var flag_id := str(ns.call("get_arrival_flag_id", npc_id))
	var any := false
	if narrative_at >= 0:
		any = true
		if _narrative_total_minutes() >= narrative_at:
			return true
	if journey_min >= 0.0:
		any = true
		var journey := get_node_or_null("/root/JourneySystem")
		if journey != null and journey.has_method("get_current_distance_km"):
			if float(journey.call("get_current_distance_km")) >= journey_min:
				return true
	if not flag_id.is_empty():
		any = true
		var flags := get_node_or_null("/root/GameFlags")
		if flags != null and flags.has_method("get_flag") and bool(flags.call("get_flag", flag_id)):
			return true
		if flags != null and flags.has_method("has_flag") and bool(flags.call("has_flag", flag_id)):
			return true
	# No arrival gates → brief TRAVELING, then place at destination.
	return not any


func _narrative_total_minutes() -> int:
	var gt := get_node_or_null("/root/GameTimeSystem")
	if gt == null:
		return 0
	var day := 0
	var minutes := 0
	if gt.has_method("get_narrative_day_index"):
		day = int(gt.call("get_narrative_day_index"))
	if gt.has_method("get_narrative_minutes_of_day"):
		minutes = int(floor(float(gt.call("get_narrative_minutes_of_day"))))
	elif gt.has_method("get_narrative_hour"):
		minutes = int(gt.call("get_narrative_hour")) * 60
	return day * 24 * 60 + minutes


func _on_narrative_time_changed(_day: int, _hour: int, _minute: int = 0) -> void:
	refresh_arrivals()


func _on_journey_distance_changed(_current_km: float, _total_km: float) -> void:
	refresh_arrivals()


func _on_flag_changed(_flag_id: String, _value: bool) -> void:
	refresh_arrivals()


func _on_save_loaded(_path: String = "") -> void:
	call_deferred("refresh_arrivals")


func _npc_state() -> Node:
	return get_node_or_null("/root/NpcStateSystem")
