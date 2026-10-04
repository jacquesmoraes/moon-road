# TerraLua — Hardening Pass Status

**Branch:** `cursor/godot-project-init-4804`  
**Scope:** Autoload late-init, fail-closed conditions, domain smoke split, docs/test workflow — **no new features**.  
**Engine:** Godot 4.7 Forward Plus

Companion: [`architecture-status.md`](architecture-status.md) § Hardening Pass · [`testing.md`](testing.md).

## Legend

| Tag | Meaning |
|-----|---------|
| **READY** | Covered by smoke; safe for the vertical slice |
| **KNOWN_RISK** | Works, but has an explicit limitation / footgun |
| **DEFERRED** | Out of this pass; tracked for later |

---

## READY

| Area | Evidence |
|------|----------|
| Autoload deferred init (`UNINITIALIZED`→`READY`) | `autoload_init_smoke` + vertical lite gate |
| Idempotent signal binds (no duplicate connects) | re-init connection count stable |
| SaveSystem provider registration | all providers present in init smoke |
| ConditionSystem fail-closed (missing peer / invalid / unknown) | `poi_worldstate_smoke` conditions |
| Narrative world time (independent of journey) | `journey_world_smoke` + NPC time windows |
| NPC schedules (signal + save) | `npc_smoke` |
| Traveling NPCs (logical relocate / arrive) | `npc_smoke` |
| Bark cooldown / dialogue block | `npc_smoke` |
| Dialogue interrupt / resume (no dup once-guards) | `dialogue_smoke` |
| Relationship + reputation | `npc_smoke` |
| Vehicle upgrades (non-stack install) | `vehicle_smoke` |
| Fuel burn / idle / empty / offline cap | `vehicle_smoke` + vertical mid-save |
| Offline progress (fuel-limited) | vertical_slice mid-save |
| Domain suite isolation (subprocess orchestrator) | `drive_smoke` / `run_tests.*` |
| Headless clean startup | `--quit-after` no ERROR/WARNING |

---

## KNOWN_RISK

| Risk | Notes |
|------|-------|
| Occupancy / vehicle pose not in save | Reload restores logical state; sandbox pose resets |
| Offline rewrite on load | Intentional; re-read disk after load if inspecting file |
| Fail-closed vs “value false” | Missing peer → `false`; present peer with unset flag + `FLAG_EQUALS false` can be `true` |
| Travel Mode stays on main road | Exit/POI is player-steered; not auto-detour |
| Expected smoke warnings | Condition fail-closed probes, unknown item id, craft missing ingredients, corrupt-save parse — not production faults |
| Long `vehicle_smoke` (~90s Travel) | Slowest suite; use domain suite for most regressions |

---

## DEFERRED

| Item | Why deferred |
|------|----------------|
| CI wiring for `run_tests.*` | Explicitly out of this pass |
| Persist occupancy / parking snapshot | Design follow-up |
| Full offline policy UI (GAME_DESIGN §8) | Feature work |
| Gas / service stop POI | Next systems list |
| NPC final animation / avoidance | Content / feel pass |
| Quest log UI / dialogue tree editor | Tooling later |

---

## Test matrix (Hardening close-out)

| Check | Result |
|-------|--------|
| Headless startup (`--quit-after`) | PASS — no ERROR/WARNING |
| `autoload_init_smoke` | PASS |
| `vehicle_smoke` | PASS |
| `journey_world_smoke` | PASS |
| `save_smoke` | PASS |
| `inventory_crafting_smoke` | PASS |
| `dialogue_smoke` | PASS |
| `npc_smoke` | PASS |
| `poi_worldstate_smoke` | PASS |
| `vertical_slice_smoke` | PASS |
| Full `drive_smoke` / `./run_tests.sh` | PASS — `passed=9 failed=0` |

No failing suites hidden. Domain regressions are detectable without the full orchestrator.
