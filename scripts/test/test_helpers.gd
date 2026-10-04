extends SceneTree
## Shared helpers for headless domain smoke suites.
## Domain suites: `extends "res://scripts/test/test_helpers.gd"`
## Run a suite: godot --path . --headless -s res://scripts/test/<suite>_smoke.gd

const MODE_TRAVEL := 2
const MODE_MANUAL := 0
const MODE_CRUISE := 1
const SANDBOX_SCENE := "res://scenes/test/DrivingSandbox.tscn"
const DEFAULT_TIMEOUT_SEC := 300.0

var suite_name: String = "smoke"
var _vehicle: CharacterBody3D
var _mode_controller: Node
var _autopilot: Node
var _camera_rig: Node3D
var _road_manager: Node
var _recenter: Node
var _journey: Node
var _scenery: Node
var _exit_system: Node
var _timeout_sec: float = DEFAULT_TIMEOUT_SEC
var _timed_out: bool = false


func fail(msg: String) -> void:
	push_error("%s: %s" % [suite_name, msg])
	_cleanup_before_quit()
	quit(1)


func pass_suite(detail: String = "") -> void:
	if detail.is_empty():
		print("%s: OK" % suite_name)
	else:
		print("%s: OK %s" % [suite_name, detail])
	_cleanup_before_quit()
	quit(0)


func _cleanup_before_quit() -> void:
	clear_vehicle_input()
	cleanup_save_files()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func await_physics_frames(n: int = 1) -> void:
	for _i in range(n):
		await physics_frame


func await_process_frames(n: int = 1) -> void:
	for _i in range(n):
		await process_frame


func start_suite_timeout(seconds: float = DEFAULT_TIMEOUT_SEC) -> void:
	_timeout_sec = seconds
	create_timer(_timeout_sec).timeout.connect(_on_suite_timeout)


func _on_suite_timeout() -> void:
	if _timed_out:
		return
	_timed_out = true
	push_error("%s: TIMEOUT after %.0fs" % [suite_name, _timeout_sec])
	_cleanup_before_quit()
	quit(1)


func load_sandbox() -> bool:
	seed(4804)
	var err := change_scene_to_file(SANDBOX_SCENE)
	if err != OK:
		fail("failed to load DrivingSandbox (%s)" % error_string(err))
		return false
	return true


func resolve_sandbox_nodes(require_scenery_exit: bool = true) -> bool:
	_vehicle = root.find_child("PlayerVehicle", true, false) as CharacterBody3D
	if _vehicle == null:
		fail("PlayerVehicle not found")
		return false
	_mode_controller = _vehicle.get_node_or_null("DrivingModeController")
	if _mode_controller == null:
		fail("DrivingModeController not found")
		return false
	_autopilot = _vehicle.get_node_or_null("RoadFollowAutopilot")
	if _autopilot == null:
		_autopilot = root.find_child("RoadFollowAutopilot", true, false)
	if _autopilot == null:
		fail("RoadFollowAutopilot not found")
		return false
	_camera_rig = root.find_child("VehicleCameraController", true, false) as Node3D
	_road_manager = root.find_child("RoadManager", true, false)
	_recenter = root.find_child("WorldOriginRecenter", true, false)
	if _road_manager == null or _recenter == null or _camera_rig == null:
		fail("missing RoadManager/WorldOriginRecenter/camera")
		return false
	_journey = root.get_node_or_null("JourneySystem")
	if _journey == null:
		fail("JourneySystem missing")
		return false
	_scenery = root.find_child("RoadsideScenery", true, false)
	_exit_system = root.find_child("RoadsideExitSystem", true, false)
	if require_scenery_exit:
		if _scenery == null:
			fail("RoadsideScenery not found")
			return false
		if _exit_system == null:
			fail("RoadsideExitSystem missing")
			return false
	return true


func clear_vehicle_input() -> void:
	Input.action_release("vehicle_accelerate")
	Input.action_release("vehicle_brake")
	Input.action_release("vehicle_left")
	Input.action_release("vehicle_right")
	Input.action_release("vehicle_cruise_toggle")
	Input.action_release("vehicle_autopilot_toggle")
	Input.action_release("vehicle_autopilot_cancel")
	Input.action_release("vehicle_travel_mode_toggle")
	Input.action_release("vehicle_travel_mode_cancel")
	Input.action_release("vehicle_camera_cinematic_toggle")
	Input.action_release("vehicle_park")
	Input.action_release("player_exit_vehicle")
	Input.action_release("player_enter_vehicle")
	Input.action_release("player_move_forward")
	Input.action_release("player_move_backward")
	if InputMap.has_action("player_move_back"):
		Input.action_release("player_move_back")
	Input.action_release("player_move_left")
	Input.action_release("player_move_right")
	Input.action_release("player_run")
	Input.action_release("player_interact")
	if InputMap.has_action("dialogue_continue"):
		Input.action_release("dialogue_continue")
	if InputMap.has_action("dialogue_cancel"):
		Input.action_release("dialogue_cancel")


func clear_world_state() -> void:
	var ws: Node = root.get_node_or_null("WorldStateSystem")
	if ws != null and ws.has_method("clear_all"):
		ws.call("clear_all")


func cleanup_save_files() -> void:
	var save: Node = root.get_node_or_null("SaveSystem")
	if save != null and save.has_method("delete_save"):
		save.call("delete_save")


func reset_autoloads_for_tests() -> void:
	## Best-effort isolation reset — each suite starts from a clean sandbox process too.
	var save: Node = root.get_node_or_null("SaveSystem")
	if save != null and save.has_method("delete_save"):
		save.call("delete_save")
	if _journey != null and _journey.has_method("reset_journey"):
		_journey.call("reset_journey")
	var inv: Node = root.get_node_or_null("InventorySystem")
	if inv != null and inv.has_method("clear_inventory"):
		inv.call("clear_inventory")
	var qs: Node = root.get_node_or_null("QuestSystem")
	if qs != null and qs.has_method("reset_all"):
		qs.call("reset_all")
	var poi: Node = root.get_node_or_null("POISystem")
	if poi != null and poi.has_method("clear_discovery_for_tests"):
		poi.call("clear_discovery_for_tests")
	clear_world_state()
	for name in [
		"VehicleStateSystem",
		"GameFlags",
		"GameTimeSystem",
		"NpcStateSystem",
		"DialogueMemorySystem",
		"RelationshipSystem",
		"BarkSystem",
	]:
		var node: Node = root.get_node_or_null(name)
		if node != null and node.has_method("reset_for_tests"):
			node.call("reset_for_tests")
	clear_vehicle_input()


func choice_ids(choices: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for entry in choices:
		if entry == null:
			continue
		out.append(str(entry.get("id")))
	return out


func ensure_in_vehicle_manual() -> bool:
	var occupancy: Node = root.find_child("PlayerOccupancyController", true, false)
	if occupancy != null and occupancy.has_method("is_on_foot") and bool(occupancy.call("is_on_foot")):
		occupancy.call("try_enter_vehicle")
		await await_physics_frames(2)
	clear_vehicle_input()
	_mode_controller.call("set_mode", MODE_MANUAL)
	if _vehicle.has_method("try_unpark"):
		_vehicle.call("try_unpark")
	await await_physics_frames(2)
	return true


func park_and_exit_to_foot() -> Dictionary:
	## Returns {ok, occupancy, character, foot_cam} after a clean park→exit.
	var result := {"ok": false, "occupancy": null, "character": null, "foot_cam": null}
	var occupancy: Node = root.find_child("PlayerOccupancyController", true, false)
	var character: CharacterBody3D = root.find_child("PlayerCharacter", true, false) as CharacterBody3D
	var foot_cam: Node3D = root.find_child("OnFootCameraController", true, false) as Node3D
	if occupancy == null or character == null or foot_cam == null:
		fail("occupancy/character/foot camera missing for on-foot setup")
		return result
	await ensure_in_vehicle_manual()
	# Settle onto the road: brief accel then brake so is_on_floor() is reliable.
	Input.action_press("vehicle_accelerate")
	for _a in range(20):
		await physics_frame
		if _vehicle.is_on_floor() and absf(float(_vehicle.call("get_signed_speed"))) > 0.2:
			break
	Input.action_release("vehicle_accelerate")
	Input.action_press("vehicle_brake")
	for _j in range(240):
		await physics_frame
		if absf(float(_vehicle.call("get_signed_speed"))) <= 0.05 and _vehicle.is_on_floor():
			break
	Input.action_release("vehicle_brake")
	clear_vehicle_input()
	await await_physics_frames(12)
	if not _vehicle.is_on_floor():
		fail(
			"vehicle not on floor before park (speed=%.3f)"
			% absf(float(_vehicle.call("get_signed_speed")))
		)
		return result
	if not bool(_vehicle.call("try_park")):
		fail(
			"park failed before on-foot setup (speed=%.3f on_floor=%s state=%s)"
			% [
				absf(float(_vehicle.call("get_signed_speed"))),
				str(_vehicle.is_on_floor()),
				str(_vehicle.call("get_motion_state_name")) if _vehicle.has_method("get_motion_state_name") else "?",
			]
		)
		return result
	if str(occupancy.call("get_state_name")) == "ON_FOOT":
		result["ok"] = true
		result["occupancy"] = occupancy
		result["character"] = character
		result["foot_cam"] = foot_cam
		return result
	if not bool(occupancy.call("try_exit_vehicle")):
		fail("try_exit_vehicle failed for on-foot setup")
		return result
	await await_physics_frames(2)
	if str(occupancy.call("get_state_name")) != "ON_FOOT":
		fail("expected ON_FOOT after setup exit")
		return result
	result["ok"] = true
	result["occupancy"] = occupancy
	result["character"] = character
	result["foot_cam"] = foot_cam
	return result


func bootstrap_sandbox(wait_sec: float = 0.5, require_scenery_exit: bool = true) -> bool:
	if not load_sandbox():
		return false
	await get_tree_timer(wait_sec)
	if not resolve_sandbox_nodes(require_scenery_exit):
		return false
	# Let CharacterBody3D contact the road before suite setup.
	await await_physics_frames(30)
	reset_autoloads_for_tests()
	return true


func get_tree_timer(sec: float) -> Signal:
	return create_timer(sec).timeout
