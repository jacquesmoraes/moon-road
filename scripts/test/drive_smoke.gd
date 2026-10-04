extends SceneTree
## Compatibility full-regression runner — launches domain smoke suites as isolated subprocesses.
## Run: godot --path . --headless -s res://scripts/test/drive_smoke.gd
##
## Individual suites (no order dependence; each boots its own sandbox):
##   godot --path . --headless -s res://scripts/test/autoload_init_smoke.gd
##   godot --path . --headless -s res://scripts/test/vehicle_smoke.gd
##   godot --path . --headless -s res://scripts/test/journey_world_smoke.gd
##   godot --path . --headless -s res://scripts/test/save_smoke.gd
##   godot --path . --headless -s res://scripts/test/inventory_crafting_smoke.gd
##   godot --path . --headless -s res://scripts/test/dialogue_smoke.gd
##   godot --path . --headless -s res://scripts/test/npc_smoke.gd
##   godot --path . --headless -s res://scripts/test/poi_worldstate_smoke.gd
##   godot --path . --headless -s res://scripts/test/vertical_slice_smoke.gd

const SUITES: PackedStringArray = [
	"res://scripts/test/autoload_init_smoke.gd",
	"res://scripts/test/vehicle_smoke.gd",
	"res://scripts/test/journey_world_smoke.gd",
	"res://scripts/test/save_smoke.gd",
	"res://scripts/test/inventory_crafting_smoke.gd",
	"res://scripts/test/dialogue_smoke.gd",
	"res://scripts/test/npc_smoke.gd",
	"res://scripts/test/poi_worldstate_smoke.gd",
	"res://scripts/test/vertical_slice_smoke.gd",
]


func _initialize() -> void:
	var exe := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var passed: PackedStringArray = []
	var failed: PackedStringArray = []
	print("drive_smoke: full regression — %d isolated suites" % SUITES.size())
	for suite_path in SUITES:
		var suite_name := suite_path.get_file().get_basename()
		print("drive_smoke: >>> %s" % suite_name)
		var args: PackedStringArray = [
			"--path", project_path,
			"--headless",
			"-s", suite_path,
		]
		var output: Array = []
		var exit_code: int = OS.execute(exe, args, output, true, false)
		for line in output:
			print(str(line).rstrip("\r\n"))
		if exit_code == 0:
			passed.append(suite_name)
			print("drive_smoke: <<< %s OK" % suite_name)
		else:
			failed.append(suite_name)
			push_error("drive_smoke: <<< %s FAILED (exit=%d)" % [suite_name, exit_code])
	print(
		"drive_smoke: SUMMARY passed=%d failed=%d total=%d"
		% [passed.size(), failed.size(), SUITES.size()]
	)
	if not failed.is_empty():
		push_error("drive_smoke: failed suites: %s" % ", ".join(failed))
		quit(1)
		return
	print(
		"drive_smoke: OK suites=%s"
		% ",".join(passed)
	)
	quit(0)
