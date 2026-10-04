#!/usr/bin/env bash
# Run TerraLua headless smoke suites (full regression or one suite).
# Usage:
#   ./run_tests.sh
#   ./run_tests.sh dialogue_smoke
#   ./run_tests.sh --list
#   GODOT_BIN=/path/to/godot ./run_tests.sh
#   ./run_tests.sh --godot /path/to/godot dialogue_smoke
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

declare -A SUITES=(
  [autoload_init_smoke]="res://scripts/test/autoload_init_smoke.gd"
  [vehicle_smoke]="res://scripts/test/vehicle_smoke.gd"
  [journey_world_smoke]="res://scripts/test/journey_world_smoke.gd"
  [save_smoke]="res://scripts/test/save_smoke.gd"
  [inventory_crafting_smoke]="res://scripts/test/inventory_crafting_smoke.gd"
  [dialogue_smoke]="res://scripts/test/dialogue_smoke.gd"
  [npc_smoke]="res://scripts/test/npc_smoke.gd"
  [poi_worldstate_smoke]="res://scripts/test/poi_worldstate_smoke.gd"
  [vertical_slice_smoke]="res://scripts/test/vertical_slice_smoke.gd"
)
FULL_REGRESSION="res://scripts/test/drive_smoke.gd"

SUITE_ORDER=(
  autoload_init_smoke
  vehicle_smoke
  journey_world_smoke
  save_smoke
  inventory_crafting_smoke
  dialogue_smoke
  npc_smoke
  poi_worldstate_smoke
  vertical_slice_smoke
)

usage() {
  cat <<'EOF'
Usage: ./run_tests.sh [--godot PATH] [--list] [SUITE]

  (no suite)     Full regression via drive_smoke.gd
  SUITE          One of the domain suite ids (see --list)
  --godot PATH   Godot executable (overrides GODOT_BIN / PATH)
  --list         Print suite ids and exit
  -h, --help     Show this help

Godot resolution: --godot > $GODOT_BIN > `godot` on PATH
See docs/testing.md
EOF
}

list_suites() {
  echo "Available suites (omit SUITE for full regression via drive_smoke):"
  for name in "${SUITE_ORDER[@]}"; do
    printf '  %-28s %s\n' "$name" "${SUITES[$name]}"
  done
}

GODOT_EXPLICIT=""
SUITE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --godot)
      [[ $# -ge 2 ]] || { echo "ERROR: --godot requires a path" >&2; exit 1; }
      GODOT_EXPLICIT="$2"
      shift 2
      ;;
    --list)
      list_suites
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$SUITE_ARG" ]]; then
        echo "ERROR: unexpected extra argument: $1" >&2
        exit 1
      fi
      SUITE_ARG="$1"
      shift
      ;;
  esac
done

resolve_godot() {
  # Prints path on stdout; returns nonzero without exiting (safe under $()).
  if [[ -n "$GODOT_EXPLICIT" ]]; then
    if [[ ! -x "$GODOT_EXPLICIT" && ! -f "$GODOT_EXPLICIT" ]]; then
      echo "ERROR: Godot executable not found at --godot path: $GODOT_EXPLICIT" >&2
      return 1
    fi
    echo "$GODOT_EXPLICIT"
    return 0
  fi
  if [[ -n "${GODOT_BIN:-}" ]]; then
    if [[ ! -e "$GODOT_BIN" ]]; then
      echo "ERROR: GODOT_BIN is set but file not found: $GODOT_BIN" >&2
      return 1
    fi
    echo "$GODOT_BIN"
    return 0
  fi
  if command -v godot >/dev/null 2>&1; then
    command -v godot
    return 0
  fi
  cat >&2 <<'EOF'
ERROR: Godot executable not found.

Install Godot 4.7+ and either:
  1) Add `godot` to PATH, or
  2) export GODOT_BIN=/path/to/godot, or
  3) pass --godot /path/to/godot

See docs/testing.md
EOF
  return 127
}

if [[ ! -f "$ROOT/project.godot" ]]; then
  echo "ERROR: project.godot not found in $ROOT — run from the repo root." >&2
  exit 1
fi

set +e
GODOT="$(resolve_godot)"
resolve_rc=$?
set -e
if [[ "$resolve_rc" -ne 0 || -z "$GODOT" ]]; then
  exit "$resolve_rc"
fi
SCRIPT="$FULL_REGRESSION"
LABEL="full regression (drive_smoke)"

if [[ -n "$SUITE_ARG" ]]; then
  key="$SUITE_ARG"
  if [[ "$key" == *.gd ]]; then
    key="$(basename "$key" .gd)"
  fi
  if [[ "$key" == res://* ]]; then
    SCRIPT="$key"
    LABEL="$key"
  elif [[ -n "${SUITES[$key]+x}" ]]; then
    SCRIPT="${SUITES[$key]}"
    LABEL="$key"
  else
    echo "ERROR: Unknown suite '$SUITE_ARG'." >&2
    list_suites >&2
    exit 1
  fi
fi

echo "run_tests: godot=$GODOT"
echo "run_tests: project=$ROOT"
echo "run_tests: running $LABEL"
echo "run_tests: $GODOT --path . --headless -s $SCRIPT"

set +e
"$GODOT" --path "$ROOT" --headless -s "$SCRIPT"
code=$?
set -e

if [[ "$code" -ne 0 ]]; then
  echo "run_tests: FAILED (exit=$code)" >&2
  exit "$code"
fi
echo "run_tests: OK"
exit 0
