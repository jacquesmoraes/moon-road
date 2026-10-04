# TerraLua — Architecture Status

**Branch:** `cursor/godot-project-init-4804`  
**As of:** contextual NPC barks (`feat: add contextual npc bark system`)  
**Engine:** Godot 4.7 Forward Plus

This document describes the **current implemented foundation**, not the full design vision in `GAME_DESIGN.md`.

---

## 1. Autoloads and responsibilities

| Autoload | Owns | Does **not** own |
|----------|------|------------------|
| `JourneySystem` | Logical Earth→Moon distance (km), physical→journey scale | Vehicle physics, road mesh, narrative clock |
| `WorldRegionSystem` | Region band from journey distance | Visuals/audio of regions |
| `POISystem` | Discovery flags + spawn/despawn of viewpoint scenes | Quest/terminal logic |
| `DialogueSystem` | Linear + choice runner; session IDLE/ACTIVE/INTERRUPTED; interrupt/resume/cancel; NPC rule resolve | Action type dispatch, NPC placement |
| `DialogueMemorySystem` | Seen/completed/choice memory + timestamps (completed ≠ interrupted) | Dialogue text, NPC names |
| `BarkSystem` | Short non-interactive NPC lines; priority/cooldown/weight; trigger gates | DialogueUI, audio/voice, movement lock |
| `NpcStateSystem` | Mutable NPC campaign fields by `npc_id` (incl. travel_state / destination / arrival gates) | Pathfinding, Node refs, schedule resolution |
| `NpcScheduleSystem` | Resolve daily routine from narrative hour → write location/state/schedule_id | Physical NPC movement, pathfinding, cross-city travel |
| `NpcTravelSystem` | Logical TRAVELING ↔ AT_LOCATION; arrival via narrative / journey km / flag; POI spawn gate | Continuous road travel, vehicles, encounters |
| *(scene)* `NpcMovementController` | Walk NPC → Marker3D via `NavigationAgent3D`; pause/resume; snap on load | Dialogue text, schedule authorship, persistence |
| `InventorySystem` | Item quantities by id + catalog | World pickups, UI layout |
| `QuestSystem` | Quest state by id; dialogue_finished → start; turn-in API | Condition evaluation, UI log |
| `CraftingSystem` | Recipes; consume→output via Inventory | Workbench UX beyond debug UI |
| `SaveSystem` | Versioned JSON coordinator + offline hook trigger | Provider internals |
| `WorldStateSystem` | Serializable entity/key bag (terminals, pickups) | Node refs, POI discovery |
| `GameTimeSystem` | **Three clocks:** play/travel · narrative world · system timestamps | Lighting, art, calendar, journey km |
| `VehicleStateSystem` | Persistent car attrs, fuel, upgrades, offline travel apply | CharacterBody3D motion, narrative clock |
| `GameFlags` | Boolean flags by id | Condition evaluation |
| `ConditionSystem` | Evaluate `ConditionData` against other systems | Quest/NPC-specific branches |
| `RelationshipSystem` | Per-NPC relationship + group reputation (−100..+100) | Romance, DialogueSystem coupling, auto grants |

Scene/runtime (not autoloads): `PlayerVehicle`, `DrivingModeController`, `RoadFollowAutopilot`, `RoadManager`, `PlayerOccupancyController`, `Workbench`, interactables, debug HUDs.

---

## 2. Three time concepts (`GameTimeSystem`)

| Clock | Purpose | Drives NPCs? | Drives journey/fuel? |
|-------|---------|--------------|----------------------|
| **Real play / travel** | `total_play_time_seconds`, `total_travel_time_seconds` | No | Yes (ETA / offline window / travel stats) |
| **Narrative world** | Persistent `narrative_day_index` + `narrative_minutes_of_day` × `narrative_time_scale` | Yes | **Never** |
| **System clock** | Unix/datetime for save stamps + offline gap | **Never** | Only to measure offline seconds |

**Narrative advance while running:** every session tick (drive, park, explore, talk) advances narrative via  
`narrative_minutes += (real_seconds / 60) × narrative_time_scale`  
Default scale **60** ⇒ 1 real minute = 1 narrative hour. Configurable export — not a magic constant in logic.

**API:** `get_narrative_day_index` / `hour` / `minute` / `minutes_of_day`, `set_narrative_time`, `advance_narrative_seconds`, `get_narrative_time_string`, future `wait_until_narrative_time` / `advance_narrative_minutes`.

**Offline:** narrative advances only when SaveSystem actually applies offline travel (fuel-capped applied seconds). If offline progress is OFF (`was_traveling_at_save` false), narrative does **not** move while closed.

---

## 3. Dependency flow (acyclic intent)

```
JourneySystem ← WorldRegionSystem (read distance)
             ← JourneyDistanceReporter (write physical meters)

InventorySystem ← CraftingSystem, QuestSystem, VehicleStateSystem (install consume)
                ← ConditionSystem (HAS_ITEM / ITEM_QUANTITY)

POISystem / WorldStateSystem / VehicleStateSystem / GameFlags / JourneySystem / WorldRegionSystem
    ↑ queried by ConditionSystem (no reverse writes)

DialogueSystem → ConditionSystem (gates + NPC rules) + DialogueActionExecutor (effects) + DialogueMemorySystem (record)
DialogueActionExecutor → GameFlags / QuestSystem / InventorySystem / WorldStateSystem / POISystem / NpcStateSystem / NpcTravelSystem / RelationshipSystem
ConditionSystem → DialogueMemorySystem (DIALOGUE_*) + NpcStateSystem (NPC_*) + RelationshipSystem (RELATIONSHIP_*/REPUTATION_*)
                → GameTimeSystem narrative API only (NARRATIVE_*) + NpcTravelSystem (NPC_AT_LOCATION)
NpcCharacter → DialogueSystem.resolve_dialogue_for_npc + BarkSystem presenter + NpcStateSystem + narrative hour window
NpcDefinition → static: dialogue_rules + bark_rules + fallback + presence_mode + available_hour_*
BarkSystem → ConditionSystem + DialogueSystem.is_active block; Label3D via NpcCharacter.display_bark
NpcScheduleSystem → GameTimeSystem (narrative hour) → NpcStateSystem (location/state/schedule_id); skips TRAVELING / follow_local_schedule=false
NpcScheduleData / NpcScheduleEntry → authored windows; catalog by npc_id (future: flags/quests selection)
NpcTravelSystem → NpcStateSystem travel fields; listens narrative / journey / flags; gates ViewpointPOI NPC spawn
NpcMovementController → NpcScheduleSystem / NpcStateSystem (location_id) → NpcDestinationResolver (Marker3D)
                         → NavigationAgent3D on NPC body; pauses on dialogue / availability

QuestSystem → InventorySystem (requirements)
            → DialogueActionExecutor (optional QuestData.on_complete_actions)
RelationshipSystem ← executor / conditions only (never DialogueSystem)

GameTimeSystem ← VehicleStateSystem.get_save_data (was_traveling snapshot)
SaveSystem → all providers; after load may call VehicleStateSystem.apply_offline_travel
           → then GameTimeSystem.apply_offline_narrative_progress(applied_seconds)
VehicleStateSystem → JourneySystem (offline distance add only) — never narrative
```

**Rule of thumb:** autoloads may *read* peers via `get_node_or_null`; they must not create hard cycles at `_ready`. ConditionSystem is a pure query façade.

---

## 4. Persisted data (`user://savegame.json`)

Header: `save_version` (1), `created_at`, `updated_at`.

| Provider key | Payload highlights |
|--------------|-------------------|
| `journey` | `current_distance_km` |
| `inventory` | `quantities` {item_id→count} |
| `quest` | `states` {quest_id→ACTIVE\|COMPLETED} |
| `poi` | `discovered` [poi_id…] |
| `world_state` | `entities` {entity_id→{key→value}} |
| `game_time` | play/travel totals, session/save/exit stamps, **`narrative_day_index` / `narrative_minutes_of_day` / `narrative_time_scale`** |
| `vehicle_state` | fuel, condition, upgrades[], speed/economy fields, `was_traveling_at_save`, `stopped_reason` |
| `game_flags` | `flags` {id→bool} |
| `dialogue_memory` | `dialogues` {id→seen/counts/timestamps}, `choices` {id→count} |
| `npc_state` | `npcs` {npc_id→enabled/met/current_state/location/previous/travel_state/destination/arrival_*/transition/follow_local_schedule/schedule/last_dialogue/flags} |
| `relationship` | `relationships` {npc_id→int}, `reputations` {group_id→int}, clamp bounds |

**Not persisted:** vehicle transform/velocity, road pool, camera mode, dialogue UI, occupancy pose (sandbox respawns), NPC Node instances.

**Offline:** if `was_traveling_at_save` and offline seconds > 0, SaveSystem applies fuel-capped journey progress once, advances narrative by applied duration, then rewrites the save so a second load cannot double-apply.

---

## 5. Important id conventions

| Domain | Pattern / examples |
|--------|--------------------|
| POI | `sunset_viewpoint` |
| WorldState terminal | `poi.<poi_id>.terminal.<name>` → `powered` |
| WorldState pickup | `poi.<poi_id>.pickup.<name>` → `collected` |
| Quest | `power_the_viewpoint` |
| Items / upgrades / recipes | `cruise_module_mk1`, `scrap_metal`, … |
| Dialogue | `mira_intro`, `mira_returning`, `mira_time_day`, `mira_time_night`, `mira_quest_done_01`, … |
| NpcDialogueRule | `mira_quest_done` / `mira_quest_active` / `mira_time_day` / `mira_time_night` / `mira_returning` |
| NPC availability | `available_hour_min`/`max` on `NpcDefinition` (Mira 8–18 exclusive end) |
| NPC schedules | `mira_daily`, `rafa_roadside` — entries with start/end hour, location, state, activity |
| NPC presence | `STATIC` / `LOCAL_SCHEDULE` / `TRAVELER` on `NpcDefinition` |
| NPC travel | `AT_LOCATION` / `TRAVELING`; destination e.g. `debug_waystation` (logical); transition `rafa_leave_viewpoint` |
| POI destinations | Marker3D under `Destinations/` — `viewpoint_workshop`, `viewpoint_diner`, `viewpoint_home`, … |
| Conditions (time) | `NARRATIVE_HOUR_MIN/MAX`, `NARRATIVE_DAY_MIN/MAX`, `NARRATIVE_TIME_RANGE` |
| Reputation groups | `sunset_viewpoint` |
| DialogueChoice | `accept_help`, `refuse_help`, `moon_yes`, `buy_part`, … |
| DialogueAction | `SET_FLAG` / `START_QUEST` / `ADD_ITEM` / … via `target_id` + value fields |
| Dialogue memory | conversation start id (`rafa_01`); choice ids (`rafa_far`, `rafa_pass`) |
| NPC ids | `mira_viewpoint_keeper`, `rafa_road_traveler` |
| NPC state tags | `DEFAULT`, `BUSY`, `UNAVAILABLE`, `TRAVELING`, `QUEST_RELATED` (extensible strings) |
| Flags | `npc.mira.met`, `slice_mid_marker`, … |
| Regions | `CLOUDLINE`, `ENDLESS_SUMMER`, … |

---

## 6. Signals (selected)

- `JourneySystem.distance_changed`
- `WorldRegionSystem.region_changed`
- `POISystem.discovered_poi`
- `DialogueSystem.dialogue_started` / `line_changed` / `choice_selection_changed` / `choice_confirmed` / `dialogue_finished` / `dialogue_cancelled` / `dialogue_interrupted` / `dialogue_resumed`
- `QuestSystem.quest_started` / `quest_completed` / `quest_state_changed`
- `InventorySystem.inventory_changed`
- `CraftingSystem.craft_succeeded` / `craft_failed`
- `SaveSystem.save_completed` / `load_completed` / `save_failed` / `load_failed`
- `VehicleStateSystem.upgrade_installed` / `fuel_changed` / `fuel_depleted`
- `GameTimeSystem.play_time_changed` / `travel_time_changed` / `traveling_changed` / `narrative_time_changed(day, hour, minute)`
- `GameFlags.flag_changed`
- `NpcStateSystem.npc_state_changed` / `npc_met_player` / `npc_states_cleared`
- `NpcScheduleSystem.npc_schedule_changed(npc_id, location_id, state, activity_id, schedule_id)`
- `NpcTravelSystem.npc_travel_started` / `npc_arrived` / `npc_presence_changed`
- `NpcMovementController.destination_started` / `destination_reached` / `destination_failed`
- `RelationshipSystem.relationship_changed` / `reputation_changed` / `relationships_cleared`
- `PlayerVehicle.parking_state_changed`
- `DrivingModeController.mode_changed`

---

## 7. Temporary / debug surfaces

- Dev main: `scenes/test/DrivingSandbox.tscn`
- Hotkeys: F5/F9/F6 save debug; I inventory; Workbench CraftingDebugUI (Tab Install)
- Narrative debug: **F7** +1h · **Shift+F7** +6h · **F8** 08:00 · **Shift+F8** 22:00 (HUD shows Day + HH:MM + scale)
- `DrivingDebugHUD` play/travel + world clock lines
- Placeholder NPC meshes, procedural road, no final art
- Offline travel is a **minimal hook** (cruise speed × time, fuel cap) — not the full design offline policy
- Narrative clock is logical only (no lighting/sky)
- NPC POI walks use flat `NavigationRegion3D` + markers (no crowds, vehicles, inter-city nav, final anim)
- No gas stations, garage, multi-vehicle, quest log UI

---

## 8. Vertical slice (what works today)

Start sandbox → drive / Travel Mode on pooled road → reach Sunset Viewpoint exit → park → exit vehicle → talk to Mira (`met_player`) → accept quest → collect scrap/wire → enter Observation Booth → power terminal (turn-in) → complete quest → (optional) Mira `mira_quest_done_01` → `mira_moon_ask` choices → talk to Rafa (`rafa_far` → `BUSY`) → craft Cruise Module Mk I → install at Workbench → +10 km/h effective max → drive burns fuel → F5 save → load restores journey/inventory/quest/POI/world/vehicle/fuel/upgrades/flags/time/dialogue memory/NPC state without duplication → limited offline progress respects fuel (+ narrative when applied).

Smoke entry: `godot --path . --headless -s res://scripts/test/drive_smoke.gd`  
Look for `npc_bark=OK`, `dlg_interrupt=OK`, `npc_travel=OK`, `npc_move=OK`, and the full `drive_smoke: OK …` line.

### NPC barks (`BarkSystem`)

Short lines on `SpeechLabel` (Label3D) — never DialogueUI, never locks movement.  
`BarkData`: id/text/priority/cooldown/conditions/weight/enabled/triggers.  
Triggers: `PLAYER_NEARBY`, `PLAYER_ENTER_AREA`, `TIME_INTERVAL` (gated), `NPC_STATE_CHANGED`.  
Anti-spam: per-bark cooldown, min gap, `last_bark_id` + recent ring. Active dialogue blocks all barks.

### Dialogue session (interrupt / resume)

| State | Meaning |
|-------|---------|
| `IDLE` | No conversation |
| `ACTIVE` | Running; input locked; once-guards live |
| `INTERRUPTED` | Paused; **not** completed; serializable ids kept; Node actor may be cleared |

API: `interrupt_dialogue(reason)`, `resume_dialogue(actor)`, `cancel_dialogue()`.  
Reasons: `PLAYER_CANCEL`, `NPC_UNAVAILABLE`, `SCENE_UNLOAD`, `SYSTEM_EVENT`.  
Input: `dialogue_cancel` (Esc) → interrupt while ACTIVE; cancel while INTERRUPTED.  
Resume re-presents the latest line **without** re-firing enter/exit/choice once-guards.  
If resume is impossible → `cancel_dialogue()`; next interact uses contextual NPC resolve.

**Save note:** active/interrupted conversations are **session-only** and are cleared on load. Disk save does not persist mid-talk state; after load, talk starts a fresh contextual dialogue.

---

## 9. Known risks

1. **Occupancy / vehicle pose not in save** — reload respawns sandbox defaults; logical progression persists, physical placement does not.
2. **Offline rewrite on load** — intentional; tools that inspect the file immediately after load should re-read disk.
3. **Dictionary provider registration** — save/load now uses explicit `_provider_order()`; keep new providers listed there.
4. **Travel Mode + detours** — autopilot stays on main road; exit is player-steered (blocking “auto POI” behavior).
5. **ConditionSystem empty catalogs / missing peers** — evaluations fail closed (return false) when systems/ids missing.
6. **Non-stackable upgrades** — install refuses duplicates; effects summed from catalog at runtime (safe on reload).

---

## 10. Recommended next systems (design order)

1. **Gas / service stop POI** — refuel interaction (fuel is already functional).
2. **Offline policy UI** — expose capped offline window from GAME_DESIGN §8.
3. **NPC animation + richer nav** — basic walk/snap/pause + logical traveler relocation exist; final anim / avoidance next.
4. **Second physical city/POI** — travelers can already land on logical ids (`debug_waystation`); add a real stop scene.
5. **Quest log + more ConditionSystem gates** on NPCs/lines.
6. **Vehicle condition / wear** — fields exist; no drain yet.
7. **Region-driven atmosphere** — WorldRegionSystem already tracks bands.
8. **Persist occupancy or last parking snapshot** if seamless reopen becomes required.
9. Art / audio pass — only after more gameplay loops stabilize.

---

## 11. Doc map

| Doc | Role |
|-----|------|
| `README.md` | How to run, controls, feature summaries |
| `docs/GAME_DESIGN.md` | Product vision (Portuguese) |
| `docs/architecture-status.md` | This file — implemented architecture |
| Store copy | `/cursor/stores/…/docs/architecture-status.md` |
