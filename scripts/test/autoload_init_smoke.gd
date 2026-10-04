extends SceneTree
## Headless: autoload late-init binds peers without order-only fragility.
## Run: godot --path . --headless -s res://scripts/test/autoload_init_smoke.gd

const AutoloadChecks = preload("res://scripts/test/autoload_checks.gd")
const WAIT_FRAMES := 12
const SUITE := "autoload_init_smoke"


func _initialize() -> void:
	# Wait for deferred _initialize_dependencies passes.
	await _wait_frames(WAIT_FRAMES)
	if not AutoloadChecks.verify_ready_states(self, SUITE):
		quit(1)
		return
	if not await AutoloadChecks.verify_schedule_game_time_apply(self, SUITE):
		quit(1)
		return
	if not AutoloadChecks.verify_travel_game_time_bind(self, SUITE):
		quit(1)
		return
	if not AutoloadChecks.verify_save_providers(self, SUITE):
		quit(1)
		return
	if not AutoloadChecks.verify_game_flags_probe(self, SUITE):
		quit(1)
		return
	if not await AutoloadChecks.verify_no_duplicate_time_binds(self, SUITE):
		quit(1)
		return
	print("%s: OK (READY + binds + providers + no dupe connects)" % SUITE)
	quit(0)


func _wait_frames(n: int) -> void:
	for _i in range(n):
		await process_frame
