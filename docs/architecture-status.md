# TerraLua — Architecture Status

**Branch:** `cursor/godot-project-init-4804`  
**As of:** fail-closed conditions (`fix: enforce fail-closed gameplay conditions`)  
**Engine:** Godot 4.7 Forward Plus

This document describes the **current implemented foundation**, not the full design vision in `GAME_DESIGN.md`.  
Pass status detail: [`docs/dialogue-npc-system-status.md`](dialogue-npc-system-status.md).

---

## 1. Autoloads and responsibilities

### Autoload init (order-robust)

Autoloads must **not** assume peers exist in `_ready()`. Pattern:

1. `_ready()` → local setup only (catalogs, no peer binds) → `call_deferred("_initialize_dependencies")`
2. `_initialize_dependencies()` binds peers with idempotent `is_connected` / `AutoloadBootstrap.try_connect`
3. Finite deferred retries (max 8) — never infinite per-frame loops
4. Explicit state: `UNINITIALIZED` → `INITIALIZING` → `READY` / `FAILED` via `get_init_state()` / `is_system_ready()`
5. No scene Node lookups during global init

Helper: `scripts/core/autoload_bootstrap.gd`

**Required vs optional (signal binds):**

| System | Required peers | Optional peers |
|--------|----------------|----------------|
| `NpcScheduleSystem` | `GameTimeSystem` | `SaveSystem` (load refresh) |
| `NpcTravelSystem` | `GameTimeSystem`, `NpcStateSystem` | `JourneySystem`, `GameFlags`, `SaveSystem` |
| `WorldRegionSystem` | `JourneySystem` (live updates) | — |
| `DialogueSystem` | — (catalogs only) | `SaveSystem` (cancel session on load) |
| `QuestSystem` | — | `DialogueSystem` (`dialogue_finished`) |
| `BarkSystem` | — | `NpcStateSystem` (state-change barks) |
| `SaveSystem` | providers discovered deferred | warns if some missing after retries |
| `ConditionSystem` / `GameFlags` / `NpcState` / `Relationship` / `GameTime` / `DialogueMemory` | none at init | peers resolved lazily at use |

`project.godot` order prefers foundations first (`GameTime` / `GameFlags` / state bags before consumers, `SaveSystem` last) to reduce retries — **code must still work if order changes**.

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
- Hotkeys: F5/F9/F6 save debug; I inventory; **F10** NPC/Dialogues debug; Workbench CraftingDebugUI (Tab Install)
- Narrative debug: **F7** +1h · **Shift+F7** +6h · **F8** 08:00 · **Shift+F8** 22:00 (HUD shows Day + HH:MM + scale)
- `DrivingDebugHUD` play/travel + world clock lines
- `NpcDialogueDebugUI` (`scripts/debug/npc_dialogue_debug_ui.gd`) — sandbox CanvasLayer only; start any `dialogue_id`, inspect rules/memory/barks, mutate test state, reset NPC/dialogue data without wiping save
- `NpcDialogueContentValidator` (`scripts/debug/npc_dialogue_content_validator.gd`) — RefCounted headless checks (missing/duplicate ids, schedule fallback, unknown conditions/actions); smoke runs `validate()`
- Placeholder NPC meshes, procedural road, no final art
- Offline travel is a **minimal hook** (cruise speed × time, fuel cap) — not the full design offline policy
- Narrative clock is logical only (no lighting/sky)
- NPC POI walks use flat `NavigationRegion3D` + markers (no crowds, vehicles, inter-city nav, final anim)
- No gas stations, garage, multi-vehicle, quest log UI, dialogue tree editor

---

## 8. Vertical slice (what works today)

Start sandbox → drive / Travel Mode on pooled road → reach Sunset Viewpoint exit → park → exit vehicle → talk to Mira (`met_player`) → accept quest → collect scrap/wire → enter Observation Booth → power terminal (turn-in) → complete quest → (optional) Mira `mira_quest_done_01` → `mira_moon_ask` choices → talk to Rafa (`rafa_far` → `BUSY`) → craft Cruise Module Mk I → install at Workbench → +10 km/h effective max → drive burns fuel → F5 save → load restores journey/inventory/quest/POI/world/vehicle/fuel/upgrades/flags/time/dialogue memory/NPC state without duplication → limited offline progress respects fuel (+ narrative when applied).

Full regression: `godot --path . --headless -s res://scripts/test/drive_smoke.gd` (orchestrates isolated domain suites).  
Look for `drive_smoke: SUMMARY passed=9 failed=0` and `drive_smoke: OK suites=…`.  
Domain suites: `autoload_init_smoke`, `vehicle_smoke`, `journey_world_smoke`, `save_smoke`, `inventory_crafting_smoke`, `dialogue_smoke`, `npc_smoke`, `poi_worldstate_smoke`, `vertical_slice_smoke` under `scripts/test/` (shared `test_helpers.gd`).

### NPC / dialogue debug tools

| Piece | Role |
|-------|------|
| `NpcDialogueDebugUI` | F10 panel — list NPCs, inspect + mutate, start dialogue remotely |
| `NpcDialogueContentValidator` | Catalog scan — missing/duplicate ids, bad links, schedule/condition/action issues |
| DialogueSystem helpers | `get_registered_npc_ids`, `get_dialogue_ids_for_npc`, `inspect_npc_dialogue_rules` |
| DialogueMemory helpers | `get_seen_dialogue_ids`, `get_completed_dialogue_ids`, `get_choice_history_ids` |
| BarkSystem helper | `get_bark_debug_state` (last/recent/cooldowns) |

**Isolation:** gameplay autoloads and `NpcCharacter` / `DialogueUI` do not reference the debug panel or validator. Reset clears memory/NPC state/barks/linked quests/`npc.*`+`debug.*` flags only — journey/inventory/vehicle untouched.

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

## 8b. Dialogue & NPC System — implemented capabilities

Scale rule: **dozens/hundreds of NPCs and dialogues via Resources** — add `.tres` + catalog entries; do not edit central autoload scripts per character.

### Resources

| Resource | Role |
|----------|------|
| `DialogueDefinition` | Line text, next/fallback, show conditions, enter/exit actions, choices |
| `DialogueChoice` | Choice text, next id, show/enable conditions, on_choose actions |
| `DialogueAction` | Declarative effect type + target fields (no scripts in resources) |
| `DialogueCatalog` | Flat dialogue registry |
| `NpcDefinition` | Static authoring: id, presence_mode, dialogue_rules, bark_rules, availability hours |
| `NpcDefinitionCatalog` | Flat NPC registry |
| `NpcDialogueRule` | Priority + conditions → dialogue_id |
| `NpcScheduleData` / `NpcScheduleEntry` | Daily narrative-hour windows → location/state/activity |
| `BarkData` | Short line: triggers, priority, cooldown, conditions, weight |
| `ConditionData` | Typed gate for ConditionSystem |

### Autoloads / scene controllers

| System | Responsibility |
|--------|----------------|
| `DialogueSystem` | Runner + session + NPC rule resolve |
| `DialogueMemorySystem` | Seen/completed/choice memory |
| `DialogueActionExecutor` | Action type dispatch |
| `ConditionSystem` | Pure evaluation façade |
| `NpcStateSystem` | Mutable campaign fields by npc_id |
| `NpcScheduleSystem` | Narrative hour → logical location/state |
| `NpcTravelSystem` | Logical TRAVELING ↔ AT_LOCATION |
| `NpcMovementController` | NavigationAgent walk to markers; pause on dialogue |
| `RelationshipSystem` | Per-NPC relationship + group reputation |
| `BarkSystem` | Non-interactive short lines |
| `GameTimeSystem` | Narrative clock (drives availability/schedules) |
| `QuestSystem` | Quest state; optional start on dialogue_finished |

### Dialogue resolve flow

1. `NpcCharacter.interact` → `DialogueSystem.resolve_dialogue_for_npc(npc_id)`  
2. Drop disabled / failing `NpcDialogueRule` conditions → highest `priority` (ties → lower index)  
3. Else `fallback_dialogue_id`  
4. `start_dialogue` → showable line (line `show_conditions` + fallback hops)  
5. Choices: show vs enable via ConditionSystem; confirm runs choice actions + next id  

### Conditions / actions / memory

- **Conditions:** flags, quest, items, POI, world state, vehicle, region, journey, dialogue memory, NPC fields, relationship/reputation, narrative time, travel presence. **Fail-closed** if peer missing (never open via expected-false defaults). `evaluate_all([])=true`, `evaluate_any([])=false`; no NOT operator.  
- **Actions:** SET_FLAG, quest start/complete, items, world/POI, SET_NPC_*, relationship/reputation, START_NPC_TRAVEL.  
- **Memory:** start→seen; finish→completed; cancel/interrupt≠completed; choices on confirm.  

### NPC state, schedules, movement, travel, barks

- **State:** enabled / met / current_state / location / travel fields / schedule_id / custom flags (persisted).  
- **Schedules:** data windows; skip when TRAVELING or `follow_local_schedule=false`.  
- **Movement:** Marker3D destinations; pause during ACTIVE dialogue; snap on load.  
- **Travel:** logical leave/arrive; gates POI spawn (no duplicate traveler).  
- **Barks:** Label3D; blocked while dialogue ACTIVE; cooldown + conditions.  

### Authoring / debug tools

- F10 `NpcDialogueDebugUI` (sandbox): inspect, start dialogue remotely, mutate test state, validate.  
- `NpcDialogueContentValidator`: missing/duplicate ids, bad links, schedule fallback, unknown condition/action.  
- No visual dialogue tree editor.

### Persisted (save) vs session-only

| Persisted | Session-only |
|-----------|----------------|
| dialogue_memory, npc_state, relationship, game_flags, game_time narrative, quests | ACTIVE/INTERRUPTED dialogue session, bark runtime cooldowns, NavigationAgent pose |

### Known limits (this pass)

No portraits/VO/localization/cinematics/facial/romance/crowds/quest log UI/tree editor. Traveler second city is logical-only (`debug_waystation`). See status report for READY/PARTIAL/NOT_IMPLEMENTED.

---

## 9. Known risks

1. **Occupancy / vehicle pose not in save** — reload respawns sandbox defaults; logical progression persists, physical placement does not.
2. **Offline rewrite on load** — intentional; tools that inspect the file immediately after load should re-read disk.
3. **Dictionary provider registration** — save/load now uses explicit `_provider_order()`; keep new providers listed there.
4. **Travel Mode + detours** — autopilot stays on main road; exit is player-steered (blocking “auto POI” behavior).
5. **ConditionSystem fail-closed** — missing peer / empty or unknown id / unknown type → `false`. Do not confuse with “value is false” when the peer **is** present (e.g. unset flag + `FLAG_EQUALS false` is true).
6. **Non-stackable upgrades** — install refuses duplicates; effects summed from catalog at runtime (safe on reload).

---

## 10. Recommended next systems (design order)

Dialogue & NPC System Pass is **closed** (data-driven foundation + smoke). Next priorities:

1. **Gas / service stop POI** — refuel interaction (fuel is already functional).
2. **Offline policy UI** — expose capped offline window from GAME_DESIGN §8.
3. **Second physical city/POI** — travelers already land on logical ids (`debug_waystation`).
4. **NPC animation + avoidance** — walk/snap/pause exist; final anim next.
5. **Quest log UI** — more content gates can stay data-driven.
6. **Vehicle condition / wear** — fields exist; no drain yet.
7. **Region-driven atmosphere** — WorldRegionSystem already tracks bands.
8. **Persist occupancy or last parking snapshot** if seamless reopen becomes required.
9. Art / audio / localization — after more gameplay loops stabilize.

---

## 11. Doc map

| Doc | Role |
|-----|------|
| `README.md` | How to run, controls, feature summaries |
| `docs/GAME_DESIGN.md` | Product vision (Portuguese) |
| `docs/architecture-status.md` | This file — implemented architecture |
| `docs/dialogue-npc-system-status.md` | Dialogue/NPC pass READY/PARTIAL/NOT_IMPLEMENTED |
| Store copy | `/cursor/stores/…/docs/` |
