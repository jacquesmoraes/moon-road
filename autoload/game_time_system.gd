extends Node
## Central real-time / play-time / travel-time foundation.
## Wall-clock based (Time.get_ticks_msec) — not FPS-coupled, not narrative journey time.
##
## Separates:
## 1) real system time (unix / datetime)
## 2) accumulated play time (any active session)
## 3) accumulated travel time (in-vehicle trip only)
## 4) offline gap (now − last_exit_timestamp)

signal play_time_changed(total_play_time_seconds: float)
signal travel_time_changed(total_travel_time_seconds: float)
signal traveling_changed(traveling: bool)

## Speed (m/s) above which MANUAL/CRUISE counts as traveling. Travel Mode always counts.
const MOVING_SPEED_THRESHOLD: float = 0.35
## Ignore absurd frame gaps (debugger pause, hitch) so accumulators stay sane.
const MAX_TICK_SECONDS: float = 0.25

var current_session_started_at: float = 0.0
var total_play_time_seconds: float = 0.0
var total_travel_time_seconds: float = 0.0
var last_save_timestamp: float = 0.0
var last_exit_timestamp: float = 0.0

var _last_tick_msec: int = 0
var _was_traveling: bool = false
var _vehicle: Node = null
var _occupancy: Node = null
## Cached offline seconds computed at load (or session start if none).
var _offline_seconds_at_session_start: float = 0.0


func _ready() -> void:
	_begin_session()
	set_process(true)
	# Capture exit stamp for offline calc next launch (in-memory until next save).
	if not tree_exiting.is_connected(_on_tree_exiting):
		tree_exiting.connect(_on_tree_exiting)


func _process(_delta: float) -> void:
	var now_msec := Time.get_ticks_msec()
	if _last_tick_msec <= 0:
		_last_tick_msec = now_msec
		return
	var dt := float(now_msec - _last_tick_msec) / 1000.0
	_last_tick_msec = now_msec
	if dt <= 0.0:
		return
	if dt > MAX_TICK_SECONDS:
		dt = MAX_TICK_SECONDS
	_accumulate(dt)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stamp_exit()


func _on_tree_exiting() -> void:
	_stamp_exit()


func _begin_session() -> void:
	current_session_started_at = _unix_now()
	_last_tick_msec = Time.get_ticks_msec()
	_offline_seconds_at_session_start = 0.0
	if last_exit_timestamp > 0.0:
		_offline_seconds_at_session_start = maxf(_unix_now() - last_exit_timestamp, 0.0)


func get_total_play_time() -> float:
	return total_play_time_seconds


func get_total_travel_time() -> float:
	return total_travel_time_seconds


func get_current_real_datetime() -> String:
	return Time.get_datetime_string_from_system(true)


func get_current_unix_time() -> float:
	return _unix_now()


func get_seconds_since_last_session() -> float:
	## Prefer live calc from last_exit; fall back to value captured at session/load.
	if last_exit_timestamp > 0.0:
		return maxf(_unix_now() - last_exit_timestamp, 0.0)
	return maxf(_offline_seconds_at_session_start, 0.0)


func get_session_elapsed_seconds() -> float:
	if current_session_started_at <= 0.0:
		return 0.0
	return maxf(_unix_now() - current_session_started_at, 0.0)


func is_traveling() -> bool:
	_resolve_refs()
	# Exploring on foot / POI — never travel time.
	if _occupancy != null and _occupancy.has_method("is_on_foot") and bool(_occupancy.call("is_on_foot")):
		return false
	if _vehicle == null or not is_instance_valid(_vehicle):
		return false
	if _vehicle.has_method("is_parked") and bool(_vehicle.call("is_parked")):
		return false
	# Travel Mode counts even at tiny speed (cruise hold).
	if _vehicle.has_method("is_travel_mode") and bool(_vehicle.call("is_travel_mode")):
		return true
	# MANUAL / CRUISE: only while actually moving.
	if _vehicle.has_method("get_signed_speed"):
		return absf(float(_vehicle.call("get_signed_speed"))) > MOVING_SPEED_THRESHOLD
	return false


func get_last_save_timestamp() -> float:
	return last_save_timestamp


func get_last_exit_timestamp() -> float:
	return last_exit_timestamp


func get_current_session_started_at() -> float:
	return current_session_started_at


func format_duration(seconds: float) -> String:
	var s := int(floor(maxf(seconds, 0.0)))
	var h := s / 3600
	var m := (s % 3600) / 60
	var sec := s % 60
	if h > 0:
		return "%dh %02dm %02ds" % [h, m, sec]
	return "%dm %02ds" % [m, sec]


## Test helper — advances accumulators without waiting on wall clock.
func debug_advance(seconds: float, traveling: bool = false) -> void:
	if not is_finite(seconds) or seconds <= 0.0:
		return
	_apply_play(seconds)
	if traveling:
		_apply_travel(seconds)


func reset_for_tests() -> void:
	total_play_time_seconds = 0.0
	total_travel_time_seconds = 0.0
	last_save_timestamp = 0.0
	last_exit_timestamp = 0.0
	_offline_seconds_at_session_start = 0.0
	_was_traveling = false
	_begin_session()


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	last_save_timestamp = _unix_now()
	# Checkpoint exit stamp so offline calc works even if process is killed after save.
	last_exit_timestamp = last_save_timestamp
	return {
		"current_session_started_at": current_session_started_at,
		"total_play_time_seconds": total_play_time_seconds,
		"total_travel_time_seconds": total_travel_time_seconds,
		"last_save_timestamp": last_save_timestamp,
		"last_exit_timestamp": last_exit_timestamp,
	}


func load_save_data(data: Dictionary) -> void:
	if data == null or data.is_empty():
		_begin_session()
		return
	total_play_time_seconds = maxf(float(data.get("total_play_time_seconds", 0.0)), 0.0)
	total_travel_time_seconds = maxf(float(data.get("total_travel_time_seconds", 0.0)), 0.0)
	last_save_timestamp = maxf(float(data.get("last_save_timestamp", 0.0)), 0.0)
	last_exit_timestamp = maxf(float(data.get("last_exit_timestamp", 0.0)), 0.0)
	# New session clock — do not reuse previous session start as "now".
	_begin_session()
	play_time_changed.emit(total_play_time_seconds)
	travel_time_changed.emit(total_travel_time_seconds)


func _accumulate(dt: float) -> void:
	_apply_play(dt)
	var traveling := is_traveling()
	if traveling != _was_traveling:
		_was_traveling = traveling
		traveling_changed.emit(traveling)
	if traveling:
		_apply_travel(dt)


func _apply_play(dt: float) -> void:
	total_play_time_seconds += dt
	play_time_changed.emit(total_play_time_seconds)


func _apply_travel(dt: float) -> void:
	total_travel_time_seconds += dt
	travel_time_changed.emit(total_travel_time_seconds)


func _stamp_exit() -> void:
	last_exit_timestamp = _unix_now()


func _unix_now() -> float:
	return float(Time.get_unix_time_from_system())


func _resolve_refs() -> void:
	if _vehicle != null and is_instance_valid(_vehicle):
		pass
	else:
		_vehicle = null
		if get_tree() != null and get_tree().current_scene != null:
			_vehicle = get_tree().current_scene.find_child("PlayerVehicle", true, false)
	if _occupancy != null and is_instance_valid(_occupancy):
		pass
	else:
		_occupancy = null
		if get_tree() != null and get_tree().current_scene != null:
			_occupancy = get_tree().current_scene.find_child("PlayerOccupancyController", true, false)
