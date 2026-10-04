# TerraLua — Testing

Headless smoke suites for the Godot vertical slice. No CI yet — run locally with the scripts below or raw `godot` commands.

## Requirements

| Item | Value |
|------|--------|
| Engine | **Godot 4.7+** (Forward Plus) |
| Project root | Folder containing `project.godot` |
| Executable | `godot` on `PATH`, or set `GODOT_BIN` / pass `-GodotBin` / `--godot` |

Optional repro helper (not part of full regression): `scripts/test/vehicle_halt_repro.gd`.

## Quick start

From the repo root:

```powershell
# Windows PowerShell — full regression
.\run_tests.ps1

# One suite
.\run_tests.ps1 -Suite dialogue_smoke

# Custom Godot path (no hardcoded machine paths in repo)
$env:GODOT_BIN = "C:\Path\To\Godot_v4.7-stable_win64.exe"
.\run_tests.ps1
# or:
.\run_tests.ps1 -GodotBin "C:\Path\To\Godot_v4.7-stable_win64.exe"
```

```bash
# Linux / macOS — full regression
./run_tests.sh

# One suite
./run_tests.sh dialogue_smoke

# Custom Godot path
export GODOT_BIN=/path/to/godot
./run_tests.sh
# or:
./run_tests.sh --godot /path/to/godot dialogue_smoke
```

List suite ids: `.\run_tests.ps1 -List` / `./run_tests.sh --list`.

## Full regression

`drive_smoke.gd` orchestrates **isolated subprocesses** (one SceneTree per suite). Suites do not share process state and have no required order.

```bash
godot --path . --headless -s res://scripts/test/drive_smoke.gd
# Expect: drive_smoke: SUMMARY passed=9 failed=0
#         drive_smoke: OK suites=…
```

Same via runners: `.\run_tests.ps1` / `./run_tests.sh` (default = all).

## Domain suites

| Suite id | Script | Coverage (summary) |
|----------|--------|--------------------|
| `autoload_init_smoke` | `scripts/test/autoload_init_smoke.gd` | Deferred READY binds, providers, no dupe connects |
| `vehicle_smoke` | `scripts/test/vehicle_smoke.gd` | Travel Mode drive, parking, vehicle state/fuel/upgrades, enter/exit, interaction |
| `journey_world_smoke` | `scripts/test/journey_world_smoke.gd` | World regions, Sunset Viewpoint reach, game time |
| `save_smoke` | `scripts/test/save_smoke.gd` | Save round-trip, corrupt keep, version gate |
| `inventory_crafting_smoke` | `scripts/test/inventory_crafting_smoke.gd` | Inventory, crafting, world pickups, workbench |
| `dialogue_smoke` | `scripts/test/dialogue_smoke.gd` | Choices, conditions, actions, memory, interrupt, system pass |
| `npc_smoke` | `scripts/test/npc_smoke.gd` | Foundation → barks/rules/state/relationship/time/schedules/move/travel/debug |
| `poi_worldstate_smoke` | `scripts/test/poi_worldstate_smoke.gd` | World state, viewpoint terminal, conditions, interior, side quest |
| `vertical_slice_smoke` | `scripts/test/vertical_slice_smoke.gd` | Autoload init probe + mid-save cross-system |

Shared helpers: `scripts/test/test_helpers.gd` (sandbox load, physics awaits, input clear, autoload reset, save cleanup, road snap, timeouts).

Raw one-suite example:

```bash
godot --path . --headless -s res://scripts/test/dialogue_smoke.gd
```

## Structure

```
scripts/test/
  test_helpers.gd          # shared SceneTree base
  *_smoke.gd               # domain suites (extends helpers or SceneTree)
  drive_smoke.gd           # full regression orchestrator
  vehicle_halt_repro.gd    # optional debug repro (not in full suite list)
run_tests.ps1              # Windows runner
run_tests.sh               # Unix runner
docs/testing.md            # this file
```

Each domain suite:

1. Boots `DrivingSandbox` (when needed) in its own process
2. Resets autoloads / save files for isolation
3. Runs named verifies
4. Prints a final summary and quits

## Output convention

- Progress / OK lines: `print("<suite>: …")` — e.g. `dialogue_smoke: OK …`
- Failures: `push_error("<suite>: …")` then `quit(1)`
- Orchestrator: `drive_smoke: >>> <suite>`, `<<< … OK|FAILED`, then `SUMMARY passed=N failed=M total=9`
- Success of full run: `drive_smoke: OK suites=…`

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Suite or full regression passed |
| `nonzero` | Failure (assertion, missing nodes, timeout, or Godot missing / bad args from shell runners) |

Shell runners exit with the Godot process exit code. If Godot cannot be found, they print a clear error and exit `127` (Unix) / `1` (Windows) without invoking a broken path.

## Resolving the Godot executable

Order of preference:

1. CLI flag: `-GodotBin` (PowerShell) / `--godot` (bash)
2. Environment variable: `GODOT_BIN`
3. `godot` on `PATH` (`Get-Command godot` / `command -v godot`)

Do **not** commit machine-specific absolute paths. On Windows:

```powershell
$env:GODOT_BIN = "C:\Godot\Godot_v4.7-stable_win64.exe"
```

## How to add a test

1. Prefer extending `scripts/test/test_helpers.gd` for sandbox suites (`extends "res://scripts/test/test_helpers.gd"`).
2. New domain file: `scripts/test/<domain>_smoke.gd` with `_initialize()` → run verifies → `pass_suite(...)` / `fail(...)` (or `quit(0)` / `quit(1)`).
3. Clear suite name on every error/OK line (`suite_name = "…"`).
4. Reset autoloads / delete save in setup or teardown so the suite is order-independent.
5. Register the suite in:
   - `scripts/test/drive_smoke.gd` → `SUITES`
   - `run_tests.ps1` / `run_tests.sh` suite lists
   - The table in this doc
6. Keep domain suites focused; put cross-system flows in `vertical_slice_smoke.gd`, not every unit assertion.
7. Run the new suite alone, then full regression via `./run_tests.sh` or `.\run_tests.ps1`.

## Related docs

| Doc | Role |
|-----|------|
| [`README.md`](../README.md) | Project overview + short test pointer |
| [`docs/GAME_DESIGN.md`](GAME_DESIGN.md) | Product vision (canonical) |
| [`docs/architecture-status.md`](architecture-status.md) | Implemented architecture |
| [`docs/dialogue-npc-system-status.md`](dialogue-npc-system-status.md) | Dialogue & NPC pass status |
