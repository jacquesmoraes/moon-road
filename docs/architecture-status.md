# TerraLua — Architecture Status

**Branch:** `cursor/godot-project-init-4804`  
**As of:** relationship & reputation (`feat: add relationship and reputation systems`)  
**Engine:** Godot 4.7 Forward Plus

This document describes the **current implemented foundation**, not the full design vision in `GAME_DESIGN.md`.

---

## 1. Autoloads and responsibilities

| Autoload | Owns | Does **not** own |
|----------|------|------------------|
| `JourneySystem` | Logical Earth→Moon distance (km), physical→journey scale | Vehicle physics, road mesh |
| `WorldRegionSystem` | Region band from journey distance | Visuals/audio of regions |
| `POISystem` | Discovery flags + spawn/despawn of viewpoint scenes | Quest/terminal logic |
| `DialogueSystem` | Linear + choice runner; NPC rule resolve (`resolve_dialogue_for_npc`); gates/effects/memory | Action type dispatch, NPC placement |
| `DialogueMemorySystem` | Seen/completed/choice memory + timestamps | Dialogue text, NPC names |
| `NpcStateSystem` | Mutable NPC campaign fields by `npc_id` | Schedules, pathfinding, city travel, Node refs |
| `InventorySystem` | Item quantities by id + catalog | World pickups, UI layout |
| `QuestSystem` | Quest state by id; dialogue_finished → start; turn-in API | Condition evaluation, UI log |
| `CraftingSystem` | Recipes; consume→output via Inventory | Workbench UX beyond debug UI |
| `SaveSystem` | Versioned JSON coordinator + offline hook trigger | Provider internals |
| `WorldStateSystem` | Serializable entity/key bag (terminals, pickups) | Node refs, POI discovery |
| `GameTimeSystem` | Play / travel / offline wall-clock accumulators | Day/night, narrative calendar |
| `VehicleStateSystem` | Persistent car attrs, fuel, upgrades, offline travel apply | CharacterBody3D motion |
| `GameFlags` | Boolean flags by id | Condition evaluation |
| `ConditionSystem` | Evaluate `ConditionData` against other systems | Quest/NPC-specific branches |
| `RelationshipSystem` | Per-NPC relationship + group reputation (−100..+100) | Romance, DialogueSystem coupling, auto grants |

Scene/runtime (not autoloads): `PlayerVehicle`, `DrivingModeController`, `RoadFollowAutopilot`, `RoadManager`, `PlayerOccupancyController`, `Workbench`, interactables, debug HUDs.

---

## 2. Dependency flow (acyclic intent)

```
JourneySystem ← WorldRegionSystem (read distance)
             ← JourneyDistanceReporter (write physical meters)

InventorySystem ← CraftingSystem, QuestSystem, VehicleStateSystem (install consume)
                ← ConditionSystem (HAS_ITEM / ITEM_QUANTITY)

POISystem / WorldStateSystem / VehicleStateSystem / GameFlags / JourneySystem / WorldRegionSystem
    ↑ queried by ConditionSystem (no reverse writes)

DialogueSystem → ConditionSystem (gates + NPC rules) + DialogueActionExecutor (effects) + DialogueMemorySystem (record)
DialogueActionExecutor → GameFlags / QuestSystem / InventorySystem / WorldStateSystem / POISystem / NpcStateSystem / RelationshipSystem
ConditionSystem → DialogueMemorySystem (DIALOGUE_*) + NpcStateSystem (NPC_*) + RelationshipSystem (RELATIONSHIP_*/REPUTATION_*)
NpcCharacter → DialogueSystem.resolve_dialogue_for_npc (no rule internals) + NpcStateSystem (spawn/talk)
NpcDefinition → static authoring: dialogue_rules + fallback_dialogue_id; never mutable campaign fields

QuestSystem → InventorySystem (requirements)
            → DialogueActionExecutor (optional QuestData.on_complete_actions)
            → (legacy) DialogueSystem.dialogue_finished may still start quests if start_dialogue_id set
RelationshipSystem ← executor / conditions only (never DialogueSystem)

GameTimeSystem ← VehicleStateSystem.get_save_data (was_traveling snapshot)
SaveSystem → all providers; after load may call VehicleStateSystem.apply_offline_travel
VehicleStateSystem → JourneySystem (offline distance add only)
```

**Rule of thumb:** autoloads may *read* peers via `get_node_or_null`; they must not create hard cycles at `_ready`. ConditionSystem is a pure query façade.

---

## 3. Persisted data (`user://savegame.json`)

Header: `save_version` (1), `created_at`, `updated_at`.

| Provider key | Payload highlights |
|--------------|-------------------|
| `journey` | `current_distance_km` |
| `inventory` | `quantities` {item_id→count} |
| `quest` | `states` {quest_id→ACTIVE\|COMPLETED} |
| `poi` | `discovered` [poi_id…] |
| `world_state` | `entities` {entity_id→{key→value}} |
| `game_time` | play/travel totals, session/save/exit unix stamps |
| `vehicle_state` | fuel, condition, upgrades[], speed/economy fields, `was_traveling_at_save`, `stopped_reason` |
| `game_flags` | `flags` {id→bool} |
| `dialogue_memory` | `dialogues` {id→seen/counts/timestamps}, `choices` {id→count} |
| `npc_state` | `npcs` {npc_id→enabled/met_player/current_state/location/schedule/last_dialogue/custom_flags} |
| `relationship` | `relationships` {npc_id→int}, `reputations` {group_id→int}, clamp bounds |

**Not persisted:** vehicle transform/velocity, road pool, camera mode, dialogue UI, occupancy pose (sandbox respawns), NPC Node instances.

**Offline:** if `was_traveling_at_save` and offline seconds > 0, SaveSystem applies fuel-capped journey progress once, then rewrites the save so a second load cannot double-apply.

---

## 4. Important id conventions

| Domain | Pattern / examples |
|--------|--------------------|
| POI | `sunset_viewpoint` |
| WorldState terminal | `poi.<poi_id>.terminal.<name>` → `powered` |
| WorldState pickup | `poi.<poi_id>.pickup.<name>` → `collected` |
| Quest | `power_the_viewpoint` |
| Items / upgrades / recipes | `cruise_module_mk1`, `scrap_metal`, … |
| Dialogue | `mira_intro`, `mira_returning`, `mira_quest_done_01`, … |
| NpcDialogueRule | `mira_quest_done` / `mira_quest_active` / `mira_returning` (priority + conditions) |
| Reputation groups | `sunset_viewpoint` (example community/POI id) |
| DialogueChoice | `accept_help`, `refuse_help`, `moon_yes`, `buy_part`, … |
| DialogueAction | `SET_FLAG` / `START_QUEST` / `ADD_ITEM` / … via `target_id` + value fields |
| Dialogue memory | conversation start id (`rafa_01`); choice ids (`rafa_far`, `rafa_pass`) |
| NPC ids | `mira_viewpoint_keeper`, `rafa_road_traveler` |
| NPC state tags | `DEFAULT`, `BUSY`, `UNAVAILABLE`, `TRAVELING`, `QUEST_RELATED` (extensible strings) |
| Flags | `npc.mira.met`, `slice_mid_marker`, … |
| Regions | `CLOUDLINE`, `ENDLESS_SUMMER`, … |

---

## 5. Signals (selected)

- `JourneySystem.distance_changed`
- `WorldRegionSystem.region_changed`
- `POISystem.discovered_poi`
- `DialogueSystem.dialogue_started` / `line_changed` / `choice_selection_changed` / `choice_confirmed` / `dialogue_finished`
- `QuestSystem.quest_started` / `quest_completed` / `quest_state_changed`
- `InventorySystem.inventory_changed`
- `CraftingSystem.craft_succeeded` / `craft_failed`
- `SaveSystem.save_completed` / `load_completed` / `save_failed` / `load_failed`
- `VehicleStateSystem.upgrade_installed` / `fuel_changed` / `fuel_depleted`
- `GameTimeSystem.play_time_changed` / `travel_time_changed` / `traveling_changed`
- `GameFlags.flag_changed`
- `NpcStateSystem.npc_state_changed` / `npc_met_player` / `npc_states_cleared`
- `RelationshipSystem.relationship_changed` / `reputation_changed` / `relationships_cleared`
- `PlayerVehicle.parking_state_changed`
- `DrivingModeController.mode_changed`

---

## 6. Temporary / debug surfaces

- Dev main: `scenes/test/DrivingSandbox.tscn`
- Hotkeys: F5/F9/F6 save debug; I inventory; Workbench CraftingDebugUI (Tab Install)
- `DrivingDebugHUD` time/fuel/vehicle lines
- Placeholder NPC meshes, procedural road, no final art
- Offline travel is a **minimal hook** (cruise speed × time, fuel cap) — not the full design offline policy
- No gas stations, garage, multi-vehicle, day/night, quest log UI, dialogue choices

---

## 7. Vertical slice (what works today)

Start sandbox → drive / Travel Mode on pooled road → reach Sunset Viewpoint exit → park → exit vehicle → talk to Mira (`met_player`) → accept quest → collect scrap/wire → enter Observation Booth → power terminal (turn-in) → complete quest → (optional) Mira `mira_quest_done_01` → `mira_moon_ask` choices → talk to Rafa (`rafa_far` → `BUSY`) → craft Cruise Module Mk I → install at Workbench → +10 km/h effective max → drive burns fuel → F5 save → load restores journey/inventory/quest/POI/world/vehicle/fuel/upgrades/flags/time/dialogue memory/NPC state without duplication → limited offline progress respects fuel.

Smoke entry: `godot --path . --headless -s res://scripts/test/drive_smoke.gd`  
Look for `relationship=OK`, `npc_rules=OK`, `npc_state=OK`, `quest=OK`, and the full `drive_smoke: OK …` line.

---

## 8. Known risks

1. **Occupancy / vehicle pose not in save** — reload respawns sandbox defaults; logical progression persists, physical placement does not.
2. **Offline rewrite on load** — intentional; tools that inspect the file immediately after load should re-read disk.
3. **Dictionary provider registration** — save/load now uses explicit `_provider_order()`; keep new providers listed there.
4. **Travel Mode + detours** — autopilot stays on main road; exit is player-steered (blocking “auto POI” behavior).
5. **ConditionSystem empty catalogs / missing peers** — evaluations fail closed (return false) when systems/ids missing.
6. **Non-stackable upgrades** — install refuses duplicates; effects summed from catalog at runtime (safe on reload).

---

## 9. Recommended next systems (design order)

1. **Gas / service stop POI** — refuel interaction (fuel is already functional).
2. **Offline policy UI** — expose capped offline window from GAME_DESIGN §8.
3. **NPC schedules / routines** — `current_schedule_id` is persisted; no runtime yet.
4. **Quest log + more ConditionSystem gates** on NPCs/lines.
5. **Vehicle condition / wear** — fields exist; no drain yet.
6. **Region-driven atmosphere** — WorldRegionSystem already tracks bands.
7. **Persist occupancy or last parking snapshot** if seamless reopen becomes required.
8. Art / audio pass — only after more gameplay loops stabilize.

---

## 10. Doc map

| Doc | Role |
|-----|------|
| `README.md` | How to run, controls, feature summaries |
| `docs/GAME_DESIGN.md` | Product vision (Portuguese) |
| `docs/architecture-status.md` | This file — implemented architecture |
| Store copy | `/cursor/stores/…/docs/architecture-status.md` |
