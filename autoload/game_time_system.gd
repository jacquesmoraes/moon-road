extends Node
## Three clearly separated time concepts (no lighting / calendar):
## 1) REAL PLAY / TRAVEL TIME — play + travel accumulators for journey/fuel/ETA/offline
## 2) NARRATIVE WORLD TIME — independent 24h clock for NPCs/dialogues/schedules
## 3) SYSTEM CLOCK — machine unix/datetime for save timestamps / offline gap only
##
## JourneySystem / VehicleStateSystem must never read narrative time for km/fuel.
## NPCs/dialogues must never read system clock hour.

signal play_time_changed(total_play_time_seconds: float)
signal travel_time_changed(total_travel_time_seconds: float)
signal traveling_changed(traveling: bool)
signal narrative_time_changed(day_index: int, hour: int, minute: int)

## Speed (m/s) above which MANUAL/CRUISE counts as traveling. Travel Mode always counts.
const MOVING_SPEED_THRESHOLD: float = 0.35
## Ignore absurd frame gaps (debugger pause, hitch) so accumulators stay sane.
const MAX_TICK_SECONDS: float = 0.25
const MINUTES_PER_DAY: int = 24 * 60

## 1 real game minute → this many narrative minutes. Configurable (not a magic constant in logic).
## Default 60 ⇒ 1 real minute = 1 narrative hour.
@export var narrative_time_scale: float = 60.0
## Initial narrative clock when no save (hour 0–23).
@export var narrative_start_hour: int = 8

var current_session_started_at: float = 0.0
var total_play_time_seconds: float = 0.0
var total_travel_time_seconds: float = 0.0
var last_save_timestamp: float = 0.0
var last_exit_timestamp: float = 0.0

## Persistent narrative world clock (independent of play/travel totals).
var narrative_day_index: int = 0
## Fractional minutes past midnight (0 .. 1440). Integer display via getters.
var narrative_minutes_of_day: float = 8.0 * 60.0

var _last_tick_msec: int = 0
var _was_traveling: bool = false
var _vehicle: Node = null
var _occupancy: Node = null
## Cached offline seconds computed at load (or session start if none).
var _offline_seconds_at_session_start: float = 0.0
var _last_emitted_day: int = -1
var _last_emitted_hour: int = -1
var _last_emitted_minute: int = -1


func _ready() -> void:
	_begin_session()
	_normalize_narrative()
	_emit_narrative_if_changed(true)
	set_process(true)
	if not tree_exiting.is_connected(_on_tree_exiting):
		tree_exiting.connect(_on_tree_exiting)


func _process(_delta: float) -> void:
	## FPS-independent via wall-clock ticks (same source as play/travel).
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


## --- Real play / travel ---

func get_total_play_time() -> float:
	return total_play_time_seconds


func get_total_travel_time() -> float:
	return total_travel_time_seconds


func get_current_real_datetime() -> String:
	## System clock only — never feed NPCs/dialogues from this.
	return Time.get_datetime_string_from_system(true)


func get_current_unix_time() -> float:
	return _unix_now()


func get_seconds_since_last_session() -> float:
	if last_exit_timestamp > 0.0:
		return maxf(_unix_now() - last_exit_timestamp, 0.0)
	return maxf(_offline_seconds_at_session_start, 0.0)


func get_session_elapsed_seconds() -> float:
	if current_session_started_at <= 0.0:
		return 0.0
	return maxf(_unix_now() - current_session_started_at, 0.0)


func is_traveling() -> bool:
	_resolve_refs()
	if _occupancy != null and _occupancy.has_method("is_on_foot") and bool(_occupancy.call("is_on_foot")):
		return false
	if _vehicle == null or not is_instance_valid(_vehicle):
		return false
	if _vehicle.has_method("is_parked") and bool(_vehicle.call("is_parked")):
		return false
	if _vehicle.has_method("is_travel_mode") and bool(_vehicle.call("is_travel_mode")):
		return true
	if _vehicle.has_method("get_signed_speed"):
		return absf(float(_vehicle.call("get_signed_speed"))) > MOVING_SPEED_THRESHOLD
	return false


func get_last_save_timestamp() -> float:
	return last_save_timestamp


func get_last_exit_timestamp() -> float:
	return last_exit_timestamp


func get_current_session_started_at() -> float:
	return current_session_started_at


## --- Narrative world clock (independent) ---

func get_narrative_day_index() -> int:
	return narrative_day_index


func get_narrative_hour() -> int:
	return int(floor(narrative_minutes_of_day / 60.0)) % 24


func get_narrative_minute() -> int:
	return int(floor(fposmod(narrative_minutes_of_day, 60.0)))


func get_narrative_minutes_of_day() -> float:
	return narrative_minutes_of_day


func get_narrative_time_scale() -> float:
	return narrative_time_scale


func get_narrative_time_string() -> String:
	return "Day %d %02d:%02d" % [get_narrative_day_index(), get_narrative_hour(), get_narrative_minute()]


## Compatibility aliases used by older call sites / smoke helpers.
func get_day_index() -> int:
	return get_narrative_day_index()


func get_hour_of_day() -> int:
	return get_narrative_hour()


func set_narrative_time(day_index: int, hour: int, minute: int = 0) -> void:
	narrative_day_index = maxi(day_index, 0)
	var h := clampi(hour, 0, 23)
	var m := clampi(minute, 0, 59)
	narrative_minutes_of_day = float(h * 60 + m)
	_emit_narrative_if_changed(true)


func set_narrative_time_scale(scale: float) -> void:
	narrative_time_scale = maxf(scale, 0.0)


## Advance narrative from real game seconds: 1 real minute → narrative_time_scale narrative minutes.
## Does NOT touch play/travel totals, journey km, or fuel.
func advance_narrative_seconds(real_seconds: float) -> void:
	if not is_finite(real_seconds) or real_seconds <= 0.0:
		return
	var scale := maxf(narrative_time_scale, 0.0)
	var narrative_minutes := (real_seconds / 60.0) * scale
	_add_narrative_minutes(narrative_minutes)


func advance_narrative_minutes(minutes: float) -> void:
	## Future sleep/motel helper — advances world clock only.
	if not is_finite(minutes) or minutes <= 0.0:
		return
	_add_narrative_minutes(minutes)


func wait_until_narrative_time(hour: int, minute: int = 0) -> void:
	## Future sleep/motel API (no UI). Advances forward to the next matching clock time.
	var target := clampi(hour, 0, 23) * 60 + clampi(minute, 0, 59)
	var current := int(floor(narrative_minutes_of_day))
	var delta := target - current
	if delta <= 0:
		delta += MINUTES_PER_DAY
	_add_narrative_minutes(float(delta))


func format_duration(seconds: float) -> String:
	var s := int(floor(maxf(seconds, 0.0)))
	var h := s / 3600
	var m := (s % 3600) / 60
	var sec := s % 60
	if h > 0:
		return "%dh %02dm %02ds" % [h, m, sec]
	return "%dm %02ds" % [m, sec]


## Test / debug — advance play (+ optional travel) and narrative as if the game ran.
func debug_advance(seconds: float, traveling: bool = false) -> void:
	if not is_finite(seconds) or seconds <= 0.0:
		return
	_apply_play(seconds)
	if traveling:
		_apply_travel(seconds)
	advance_narrative_seconds(seconds)


## Test / debug — set narrative without touching play/travel.
func debug_set_narrative_time(day_index: int, hour_of_day: int, minute: int = 0) -> void:
	set_narrative_time(day_index, hour_of_day, minute)


func debug_advance_narrative_hours(hours: float) -> void:
	if not is_finite(hours) or hours == 0.0:
		return
	_add_narrative_minutes(hours * 60.0)


func reset_for_tests() -> void:
	total_play_time_seconds = 0.0
	total_travel_time_seconds = 0.0
	last_save_timestamp = 0.0
	last_exit_timestamp = 0.0
	_offline_seconds_at_session_start = 0.0
	_was_traveling = false
	narrative_time_scale = 60.0
	narrative_day_index = 0
	narrative_minutes_of_day = float(clampi(narrative_start_hour, 0, 23) * 60)
	_last_emitted_day = -1
	_last_emitted_hour = -1
	_last_emitted_minute = -1
	_begin_session()
	_emit_narrative_if_changed(true)


## --- SaveSystem provider API ---

func get_save_data() -> Dictionary:
	last_save_timestamp = _unix_now()
	last_exit_timestamp = last_save_timestamp
	return {
		"current_session_started_at": current_session_started_at,
		"total_play_time_seconds": total_play_time_seconds,
		"total_travel_time_seconds": total_travel_time_seconds,
		"last_save_timestamp": last_save_timestamp,
		"last_exit_timestamp": last_exit_timestamp,
		"narrative_day_index": narrative_day_index,
		"narrative_minutes_of_day": narrative_minutes_of_day,
		"narrative_time_scale": narrative_time_scale,
		"narrative_start_hour": narrative_start_hour,
		# Mirrored readouts for save inspection / older tools.
		"narrative_hour": get_narrative_hour(),
		"narrative_minute": get_narrative_minute(),
	}


func load_save_data(data: Dictionary) -> void:
	if data == null or data.is_empty():
		_begin_session()
		_emit_narrative_if_changed(true)
		return
	total_play_time_seconds = maxf(float(data.get("total_play_time_seconds", 0.0)), 0.0)
	total_travel_time_seconds = maxf(float(data.get("total_travel_time_seconds", 0.0)), 0.0)
	last_save_timestamp = maxf(float(data.get("last_save_timestamp", 0.0)), 0.0)
	last_exit_timestamp = maxf(float(data.get("last_exit_timestamp", 0.0)), 0.0)

	if data.has("narrative_time_scale"):
		narrative_time_scale = maxf(float(data.get("narrative_time_scale")), 0.0)
	elif data.has("narrative_minutes_per_real_minute"):
		# Migrate previous play-derived scale field.
		narrative_time_scale = maxf(float(data.get("narrative_minutes_per_real_minute")), 0.0)

	if data.has("narrative_start_hour"):
		narrative_start_hour = clampi(int(data.get("narrative_start_hour")), 0, 23)

	if data.has("narrative_day_index") and data.has("narrative_minutes_of_day"):
		narrative_day_index = maxi(int(data.get("narrative_day_index")), 0)
		narrative_minutes_of_day = clampf(float(data.get("narrative_minutes_of_day")), 0.0, float(MINUTES_PER_DAY) - 0.0001)
	elif data.has("narrative_day_index") and data.has("narrative_hour_of_day"):
		# Migrate previous derived-hour payload.
		narrative_day_index = maxi(int(data.get("narrative_day_index")), 0)
		narrative_minutes_of_day = float(clampi(int(data.get("narrative_hour_of_day")), 0, 23) * 60)
	else:
		narrative_day_index = 0
		narrative_minutes_of_day = float(clampi(narrative_start_hour, 0, 23) * 60)

	_normalize_narrative()
	_begin_session()
	play_time_changed.emit(total_play_time_seconds)
	travel_time_changed.emit(total_travel_time_seconds)
	_emit_narrative_if_changed(true)


## Called by SaveSystem only when offline progress is actually applied (capped seconds).
func apply_offline_narrative_progress(applied_real_seconds: float) -> void:
	advance_narrative_seconds(applied_real_seconds)


func _accumulate(dt: float) -> void:
	_apply_play(dt)
	var traveling := is_traveling()
	if traveling != _was_traveling:
		_was_traveling = traveling
		traveling_changed.emit(traveling)
	if traveling:
		_apply_travel(dt)
	# World clock advances whenever the game is running (drive, park, explore, talk).
	advance_narrative_seconds(dt)


func _apply_play(dt: float) -> void:
	total_play_time_seconds += dt
	play_time_changed.emit(total_play_time_seconds)


func _apply_travel(dt: float) -> void:
	total_travel_time_seconds += dt
	travel_time_changed.emit(total_travel_time_seconds)


func _add_narrative_minutes(minutes: float) -> void:
	if not is_finite(minutes) or minutes == 0.0:
		return
	var total := narrative_minutes_of_day + minutes
	if total >= 0.0:
		var days_fwd := int(floor(total / float(MINUTES_PER_DAY)))
		narrative_day_index += days_fwd
		narrative_minutes_of_day = fposmod(total, float(MINUTES_PER_DAY))
	else:
		# Negative wait/debug — step backward across midnight.
		while total < 0.0:
			total += float(MINUTES_PER_DAY)
			narrative_day_index = maxi(narrative_day_index - 1, 0)
		narrative_minutes_of_day = total
	_emit_narrative_if_changed(false)


func _normalize_narrative() -> void:
	narrative_day_index = maxi(narrative_day_index, 0)
	if narrative_minutes_of_day < 0.0 or narrative_minutes_of_day >= float(MINUTES_PER_DAY):
		var days := int(floor(narrative_minutes_of_day / float(MINUTES_PER_DAY)))
		narrative_day_index = maxi(narrative_day_index + days, 0)
		narrative_minutes_of_day = fposmod(narrative_minutes_of_day, float(MINUTES_PER_DAY))


func _emit_narrative_if_changed(force: bool) -> void:
	var day := get_narrative_day_index()
	var hour := get_narrative_hour()
	var minute := get_narrative_minute()
	if (
		force
		or day != _last_emitted_day
		or hour != _last_emitted_hour
		or minute != _last_emitted_minute
	):
		_last_emitted_day = day
		_last_emitted_hour = hour
		_last_emitted_minute = minute
		narrative_time_changed.emit(day, hour, minute)


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
