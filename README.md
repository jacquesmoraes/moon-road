# TerraLua

Godot 4.x 3D project for a long road-trip game from Earth to the Moon.

Current slice: **vertical-slice integration** — mid-flow save/load, offline-once, architecture docs. See [`docs/architecture-status.md`](docs/architecture-status.md).

## Requirements

- [Godot 4.7+](https://godotengine.org/download) (Forward Plus)

## Run

1. Open this folder in the Godot editor (`project.godot`).
2. Press **Play** (editor F5). Dev main scene: `scenes/test/DrivingSandbox.tscn`.
   In-game **F5/F9/F6** are temporary save debug hotkeys (not the editor Play shortcut).

### Drive controls

| Action | Keys |
|--------|------|
| `vehicle_accelerate` | W / Up |
| `vehicle_brake` (cancels assisted modes) | S / Down |
| `vehicle_left` / `vehicle_right` | A·D / arrows (steer cancels Travel Mode) |
| `vehicle_cruise_toggle` | C — MANUAL↔CRUISE; from Travel Mode drops to CRUISE |
| `vehicle_travel_mode_toggle` | V — enter/exit Travel Mode |
| `vehicle_autopilot_toggle` | T — Travel Mode shortcut (same as V while mode controller is present) |
| `vehicle_travel_mode_cancel` / `vehicle_autopilot_cancel` | X / Esc |
| `vehicle_camera_next` / `vehicle_camera_previous` | F / Shift+F (cancels cinematic, then cycles) |
| `vehicle_camera_cinematic_toggle` | M — Travel Mode only: toggle automatic cinematic camera |
| `vehicle_park` | P — toggle `DRIVING` ↔ `PARKED` (only parks when slow enough + on floor) |
| `player_exit_vehicle` | E — leave a **PARKED** vehicle (on foot) |
| `player_enter_vehicle` | E — re-enter when near the parked vehicle |
| `player_move_forward` / `backward` / `left` / `right` | WASD / arrows — camera-relative walk |
| `player_run` | Shift — run while on foot |
| `player_interact` | E — world interact when focused; else enter vehicle (see Occupancy) |
| `dialogue_continue` | Space / E / Enter — advance or close active dialogue |
| `inventory_debug_toggle` | I — show/hide debug inventory panel |
| `save_debug_save` | F5 — write `user://savegame.json` |
| `save_debug_load` | F9 — load save (keeps file if corrupt) |
| `save_debug_delete` | F6 — delete save + backup |

Workbench: walk up at Sunset Viewpoint, **E** opens CraftingDebugUI (↑↓ select, Enter/C craft, **Tab** Install mode, Esc or E again to close).

Tune feel on the `PlayerVehicle` node: `acceleration`, `braking`, `max_speed`, `steering_strength`, `drag`, plus cruise `cruise_target_speed_kmh`, `cruise_speed_deadzone`, `cruise_control_gain`, and parking `max_parking_speed`, `require_valid_surface`.

On-foot feel on `PlayerCharacter`: `walk_speed`, `run_speed`, `acceleration`, `deceleration`, `gravity`, `max_step_height`.

### Interaction (`Interactable` + `InteractionDetector`)

Reusable world-object interaction — terminals, logs, and NPCs share the same detector.

| Piece | Role |
|-------|------|
| `Interactable` | Base Area3D API: `interaction_name`, `interaction_prompt`, `can_interact()`, `interact(actor)` |
| `InteractionDetector` | Child Area3D on the character; duck-types targets (no concrete-class dependency) |
| `InteractionPromptUI` | Bottom-center debug prompt when focused |
| `TestTerminal` | Sample object — prints a log message on interact |
| `ViewpointTerminal` | Sunset Viewpoint console — **one-shot OFF→ON** (session state, color + light + label) |
| `Npc` / `NpcDefinition` | Placeholder person — data Resource + temporary spoken line |

**E key UX:** On foot, a focused interactable wins (`player_interact`). If none, E enters the parked vehicle. In vehicle (parked), E still exits. Prompt only shows while a valid object is in range/front cone. During dialogue, movement is locked and `dialogue_continue` advances lines.

**ViewpointTerminal choice:** one-shot **ON** (not a toggle). First successful interact powers it; `can_interact` becomes false; `powered` persists in `WorldStateSystem` across unload/save.

### NPCs + Dialogue (`DialogueSystem`)

Data-driven linear talk — no choices, branching, VO, or quests yet.

| Piece | Role |
|-------|------|
| `DialogueDefinition` | `id`, `speaker_name`, `text`, `next_dialogue_id` (+ reserved flags/choices) |
| `DialogueCatalog` | Flat registry (`resources/dialogue/default_catalog.tres`) |
| `DialogueSystem` | Autoload — start / advance / end; locks on-foot control; `resolve_dialogue_id` for condition gates |
| `DialogueUI` | Placeholder bottom dialogue box |
| `ConditionalDialogue` | `condition` + `dialogue_id` — first match wins |
| `NpcDefinition.dialogue_id` | Fallback / offer line id |
| `NpcDefinition.conditional_dialogues` | ConditionSystem-gated overrides |

**Authoring:** create `.tres` lines, chain with `next_dialogue_id`, add them to the catalog, set the NPC's `dialogue_id`. **Mira** uses a `QUEST_STATE` gate: when `power_the_viewpoint` is `COMPLETED`, she opens `mira_quest_done_01` via ConditionSystem (before the quest helper). **Rafa** stays linear (`rafa_01`→`rafa_02`).

### Conditions + flags (`ConditionSystem` / `GameFlags`)

Generic gate layer — no quest/NPC-specific ifs inside ConditionSystem.

| Piece | Role |
|-------|------|
| `ConditionData` | Typed condition resource (`FLAG_EQUALS`, `QUEST_STATE`, `HAS_ITEM`, …) |
| `ConditionSystem` | `evaluate` / `evaluate_all` / `evaluate_any` |
| `GameFlags` | `set_flag` / `get_flag` / `has_flag` — persisted via SaveSystem |

Extension points: `DialogueSystem.resolve_dialogue_id(entries)`, NPC `conditional_dialogues`, QuestSystem completed path also consults ConditionSystem.

### Save (`SaveSystem`)

Versioned JSON at `user://savegame.json`. SaveSystem only coordinates — each system owns its payload via `get_save_data()` / `load_save_data(data)`.

| Piece | Role |
|-------|------|
| `save_version` / `created_at` / `updated_at` | Header on every file |
| Providers | `JourneySystem`, `InventorySystem`, `QuestSystem`, `POISystem`, `WorldStateSystem`, `GameTimeSystem`, `VehicleStateSystem`, `GameFlags` |
| API | `save_game`, `load_game`, `has_save`, `delete_save`, `get_save_version` |
| Backup | `user://savegame.json.bak` before overwrite |
| Debug | **F5** save · **F9** load · **F6** delete |

Corrupt / unknown-version files are refused and **kept** (never auto-deleted). No autosave, multi-slots, cloud, or encryption.

### Game time (`GameTimeSystem`)

Central real-time foundation — not narrative journey distance, not a day/night cycle.

| Clock | Meaning |
|-------|---------|
| Real system time | Wall clock (`Time.get_unix_time_from_system` / datetime string) |
| Play time | Accumulates whenever a session is running |
| Travel time | Only while an actual trip is happening |
| Offline | `now − last_exit_timestamp` between sessions |

Travel detection: in vehicle, not parked, and either Travel Mode **or** `|speed| > 0.35 m/s`. Parked / on-foot POI explore do **not** count.

Persisted via SaveSystem (`systems.game_time`): `current_session_started_at`, `total_play_time_seconds`, `total_travel_time_seconds`, `last_save_timestamp`, `last_exit_timestamp`. Clock uses `Time.get_ticks_msec` (FPS-independent). Dev HUD shows `Time: play · travel · TRAVELING|idle`.

### Vehicle state (`VehicleStateSystem`)

Persistent car attributes / progression — separate from `PlayerVehicle` physics and input.

| Field | Role |
|-------|------|
| `vehicle_id` / `display_name` | Active vehicle identity (default `starter_car`) |
| `fuel_*` / `condition_*` | Capacity + current — fuel burns with travel |
| `storage_capacity` | Cargo slots (effects later) |
| `installed_upgrades` | Upgrade **ids** only (never Nodes) |
| `base_max_speed_kmh` | Authoritative speed cap |
| `cruise_speed_modifier` / `efficiency_modifier` | Speed / economy multipliers |
| `liters_per_100km` | Base burn rate (game-feel, not a real sim) |

API: `install_upgrade` / `install_upgrade_from_inventory` / `has_upgrade` / `remove_upgrade` / `get_effective_max_speed()` (km/h = `base * cruise_mod + Σ upgrade bonuses`); fuel: `add_fuel` / `consume_fuel` / `get_fuel_ratio` / `apply_offline_travel`. Effects come from `UpgradeData` modifiers at runtime (not baked into base on install — no duplicate on reload). Workbench UI: **Tab** toggles Craft / Install. Not included: multi-vehicle, garage, swap, visual damage, gas stations.

### Vehicle upgrades (`UpgradeData` + catalog)

| Piece | Role |
|-------|------|
| `UpgradeData` | `id`, `display_name`, `description`, `category`, `item_id`, `stackable`, `max_speed_bonus_kmh`, `efficiency_multiplier` |
| `UpgradeCatalog` | `resources/upgrades/default_upgrade_catalog.tres` |
| First upgrade | **Cruise Module Mk I** — `+10 km/h` (`cruise_module_mk1`) |
| Recipe | 2 Scrap Metal + 1 Copper Wire + 1 Circuit Board → module |
| Install | Workbench panel → Tab → Install (consumes item) |

### World state (`WorldStateSystem`)

Logical bag of serializable flags by `entity_id` — survives scene unload. No Node refs, no city logic. POI discovery stays in `POISystem`.

| Convention | Example |
|------------|---------|
| `poi.<id>.terminal.<name>` | `poi.sunset_viewpoint.terminal.main` (`powered`) |
| `poi.<id>.pickup.<name>` | `poi.sunset_viewpoint.pickup.scrap_01` (`collected`) |

API: `set_value` / `get_value` / `has_value` / `clear_entity` / `set_flag`. ViewpointTerminal + WorldItem read/write on interact and restore in `_ready`.

### Crafting (`CraftingSystem` + `RecipeData`)

Data-driven recipes over `InventorySystem`. No tech tree, craft time, quality, or auto-craft.

| Piece | Role |
|-------|------|
| `RecipeData` | `id`, `display_name`, ingredient ids/amounts, `output_item_id`, `output_quantity` |
| `RecipeCatalog` | Registers recipes (`resources/crafting/default_recipe_catalog.tres`) |
| `CraftingSystem` | Autoload: `can_craft`, `craft` (atomic consume → add) |
| `Workbench` | Interactable placeholder; opens debug craft UI |
| `CraftingDebugUI` | Select recipe (↑↓), craft (Enter/C), Esc to close |

Test recipe **Basic Repair Kit**: 2 Scrap Metal + 1 Copper Wire → 1 Basic Repair Kit (`TOOL`). **Cruise Module Mk I**: 2 Scrap + 1 Wire + 1 Circuit Board → installable upgrade. Workbench sits at Sunset Viewpoint (**Tab** Craft/Install). Crafting does not couple to NPCs or quests — add recipes via `.tres` / `register_recipe`.

### Quests (`QuestSystem`)

Lightweight foundation — states `INACTIVE` / `ACTIVE` / `COMPLETED` by `quest_id`.

| Piece | Role |
|-------|------|
| `QuestData` | Requirements, dialogue ids per state, giver NPC, turn-in target |
| `QuestSystem` | Autoload; starts on offer dialogue finish; `try_turn_in` consumes items |
| `power_the_viewpoint` | Mira asks for 3 Scrap Metal + 1 Copper Wire; terminal turn-in powers ON |

No quest log UI, branching, or fail states yet.

### World pickups (`WorldItem`)

Physical collectibles using the shared Interactable detector + InventorySystem.

| Piece | Role |
|-------|------|
| `WorldItem` | `item_id` + `quantity`; collect → add to inventory → deactivate |
| `pickup_id` / `get_collected_state()` | Clear collected flag for future persistence |
| `PickupFeedbackUI` | Debug toast e.g. `+1 Scrap Metal` |

Sunset Viewpoint: **Scrap Metal** inside the Observation Booth, **Copper Wire** (x2) just outside. No loot tables, respawn, or animation.

### Inventory (`InventorySystem` + `ItemData`)

Decoupled bag of item ids — no weight, equipment, or drag-drop UI.

| Piece | Role |
|-------|------|
| `ItemData` | `id`, `display_name`, `description`, `stackable`, `max_stack`, `category` |
| Categories | `RESOURCE`, `COMPONENT`, `TOOL`, `CONSUMABLE`, `QUEST` |
| `ItemCatalog` | Registers definitions (`resources/inventory/default_item_catalog.tres`) |
| `InventorySystem` | Autoload: `add_item`, `remove_item`, `has_item`, `get_quantity` |
| `InventoryDebugUI` | Dev panel listing contents (**I** to toggle) |

Test items: `scrap_metal`, `copper_wire`, `circuit_board`, `basic_repair_kit`, `cruise_module_mk1`. Inventory stores quantities by id only — used by pickups, quests, crafting, and upgrade install. Does not depend on NPC, dialogue, quest, or the debug UI.

### Small interiors (`SmallInterior`)

Reusable single-room building used as the **Observation Booth** on Sunset Viewpoint.

| Piece | Role |
|-------|------|
| `SmallInterior` | Floor / walls / ceiling / doorway gap + light |
| `InteriorVolume` | Detects walk-in / walk-out; tightens on-foot camera |
| `ObservationLog` | Interactable inside the booth |

**Enter/exit:** walk through the open doorway — no teleport, no loading screen. On-foot camera uses shorter follow distance indoors and raycasts against walls to reduce clipping. Parked car is untouched.

Detection: Area3D proximity + forward cone ranking (stable, simple). NPCs/doors/benches/shops/items duck-type the same Interactable methods.

### Occupancy (`PlayerOccupancyController`)

Single controller for player presence — not scattered booleans.

| State | Behavior |
|-------|----------|
| `IN_VEHICLE` | Vehicle manual control + **VehicleCameraController** |
| `ON_FOOT` | `PlayerCharacter` + **OnFootCameraController**; vehicle stays `PARKED` with control disabled |

Exit only when `PARKED` (and nearly stopped). Re-enter within `enter_distance` (default 3.5 m). Vehicle node is never destroyed/recreated during the swap. Character visual lives under `Model/` for a later art swap. Not included: door anims, inventory, interactions, stamina, jump, crouch, combat.

### On-foot camera (`OnFootCameraController`)

Dedicated rig — **does not reuse** vehicle hood/passenger/cinematic logic.

| Mode | Status |
|------|--------|
| `THIRD_PERSON` | Default — smooth orbit follow + mouse look |
| `FIRST_PERSON` | Enum + offsets ready; swap via `set_view_mode` later |

Mouse look while on foot (Esc releases capture). Occupancy toggles `set_active` between vehicle and on-foot cameras.

### Motion state (`PlayerVehicle`)

Orthogonal to assisted driving modes. Single enum — not scattered booleans.

| State | Behavior |
|-------|----------|
| `DRIVING` | Normal accel / brake / steer (and cruise / Travel Mode when engaged) |
| `PARKED` | Speed forced to 0; accel and steering disabled; Cruise + Travel Mode cancelled |

Park only when `|speed| ≤ max_parking_speed` (default 1.5 m/s) and, if `require_valid_surface`, the vehicle is on a floor (road, viewpoint pad, future lots). Signal: `parking_state_changed`. Unpark (P again) returns to `DRIVING` (blocked while on foot). No handbrake VFX yet.

### Driving assistance (`DrivingModeController`)

| Mode | Speed | Steering |
|------|-------|----------|
| `MANUAL` | player | player |
| `CRUISE` | hold target km/h | player |
| `TRAVEL_MODE` | hold target km/h | `RoadFollowAutopilot` road-center |

Travel Mode enables cruise + road-follow together. Cancel immediately with V/T toggle, X/Esc, brake, or manual steer. While Travel Mode is on, press **M** for cinematic camera (auto shot cycling). Parking forces `MANUAL` and refuses cruise/travel until unparked.

`RoadFollowAutopilot` only steers (`set_steer_override`); the mode controller owns when it is on.

### Camera modes

`VehicleCameraController` — single detached rig, default **FOLLOW** (same chase feel as before).

| Mode | Feel |
|------|------|
| `FOLLOW` | Third-person behind/above |
| `FAR` | Farther chase, wider FOV |
| `HOOD` | Near hood, locked to vehicle |
| `PASSENGER` | Passenger seat, road ahead |
| `WINDOW` | Right-side window / landscape |

| Action | Keys |
|--------|------|
| `vehicle_camera_next` | F |
| `vehicle_camera_previous` | Shift+F |
| `vehicle_camera_cinematic_toggle` | M (Travel Mode only) |

**Cinematic (Travel Mode)** — director layer over the five modes (not a sixth mode). Weighted auto-cycle: FOLLOW/FAR more often, PASSENGER/WINDOW occasional, HOOD short holds. Each shot lasts a random duration (`cinematic_min_duration`–`cinematic_max_duration`, default 8–25 s; HOOD capped by `cinematic_hood_max_duration`). Swaps use a smooth live-pose blend (`cinematic_transition_duration`, default 2 s) — no hard cuts. Allowed modes: `cinematic_allowed_modes`.

- **M** toggles cinematic on/off instantly (enable only while Travel Mode is active).
- **F / Shift+F** cancel cinematic immediately, then cycle manually.
- Leaving Travel Mode also clears cinematic.
- Camera never touches vehicle physics, autopilot, JourneySystem, or RoadManager. Origin recenter stays stable because blends recompute desired poses from the live vehicle transform.

### Dev HUD

`DrivingDebugHUD` (top-left): full debug in MANUAL/CRUISE (**Occupancy**, **Motion: DRIVING/PARKED**, mode, **region**, journey, camera, cruise, autopilot, pos, controls, FPS). **ON_FOOT** HUD is minimal (walk / enter hints). In **TRAVEL_MODE** it shrinks to essentials — Travel Mode label, occupancy, motion, **region name**, journey km, remaining, speed/target, camera (incl. `CINEMATIC→MODE`), cancel hint.

### Journey (logical distance)

Autoload `JourneySystem` (`autoload/journey_system.gd`) stores Earth→Moon progress (`total_distance_km = 384400`).

**Units**

- Godot world space: **1 unit = 1 physical meter**
- Physical km = meters / 1000
- Journey km (narrative) = physical km × `physical_to_journey_scale`

**Scale** (on the `JourneySystem` autoload node): `physical_to_journey_scale` default `1.0` means 1 physical km of scene travel → 1 journey km. Changing it only affects logical progress, not car physics.

`JourneyDistanceReporter` on the vehicle reports physical meters only (`add_physical_distance_meters`); conversion lives solely in `JourneySystem`.

### World regions (logical)

Autoload `WorldRegionSystem` maps `JourneySystem.current_distance_km` → a data-driven `WorldRegion`. Independent of UI, scenery, and road systems — the HUD only *reads* the current name.

| region_id | Span (journey km) |
|-----------|-------------------|
| `ENDLESS_SUMMER` | 0 – 40000 |
| `CLOUDLINE` | 40000 – 90000 |
| `ORBITAL_BLUE` | 90000 – 150000 |
| `DEEP_VIOLET` | 150000 – 230000 |
| `THE_LONG_NIGHT` | 230000 – 310000 |
| `MOONRISE` | 310000 – 370000 |
| `LUNAR_DESCENT` | 370000 – 384400 |

**Edit regions without code:** change `.tres` under `resources/world/regions/`, or the list in `resources/world/world_region_catalog.tres`. Spans / names / future stubs (`scenery_density_scale`, `climate_tag`, `visual_tint`, `audio_ambience_tag`, `poi_tags`) live in those resources — not in `JourneySystem`.

API: `get_current_region()`, `get_current_region_name()`, `get_region_progress()`, `get_region_at_distance(km)`. Signal `region_changed` fires **only** when the region identity actually changes (half-open spans; final region includes its end km).

### Road segments

`scenes/road/RoadSegment.tscn` — modular piece with curve kinds **`straight`**, **`gentle_left`**, **`gentle_right`** and elevation **`level`**, **`gentle_climb`**, **`gentle_descent`**. Arc length = `length` (default 40 m); curves turn `curve_angle_degrees` (default 18°); grades use `elevation_angle_degrees` (default 5°). Markers `Entrance` / `Exit` carry position, heading, **and pitch** so the next segment aligns in height and grade.

`RoadManager` keeps a **fixed pool** around the player: recycles the rearmost segment to the front via `place_after_exit`. After `start_straight_count` opening straight/level pieces, recycled segments pick weighted random curve + elevation. `sample_road` / centerline follow arcs and grades. Recycle distance is along the rear segment’s forward (planar).

Roadway collision is a **concave strip** (top/bottom only) matching the mesh — not a box chain (box end-faces used to halt the car mid-accel). Shoulder meshes are visual-only. Detour mouths sit fully outside the main lane so spur colliders never wedge Travel Mode.

Knobs: `active_segment_count`, `segment_length`, `recycle_behind_distance`, `curve_angle_degrees`, `elevation_angle_degrees`, kind/elevation weights. Pooling, origin recenter, and JourneySystem stay unchanged.

`WorldOriginRecenter` (`scripts/world/world_origin_recenter.gd`) shifts vehicle, road pool, and follow camera when planar distance from origin exceeds `recenter_distance` (sandbox default 500). Journey keeps using position deltas (`notify_origin_shifted`); vehicle velocity is preserved.

### Roadside scenery

`RoadsideScenery` (`scripts/world/roadside_scenery.gd`) — fixed pools of placeholder props (rocks, posts, signs, distant “mountains”). Decorates each `RoadSegment` from a deterministic `(world_seed, sequence_index)` RNG; clears and reuses the same props when the segment is recycled. Placement is offset past road width + shoulders + `roadside_clearance` (never on the roadway). Density knobs: `rocks_per_segment`, `posts_per_segment`, `signs_per_segment`, `mountains_per_segment`, `mountain_chance`, near/far lateral ranges.

Props parent under each segment’s `SceneryAnchor`, so origin recenter moves them with the road. Node count stays bounded to the pool size.

### Roadside exits & short detours

`RoadsideExitSystem` places lateral exits (`EXIT_LEFT` / `EXIT_RIGHT`) off a main-road host into a **fixed-length secondary stretch**. At the spur end, autoload **`POISystem`** instantiates reusable `ViewpointPOI` (`scenes/world/ViewpointPOI.tscn`): entrance, car pad, observation point, discover Area3D, placeholder sign/bounds.

Example: **Sunset Viewpoint** (`resources/world/exits/sunset_viewpoint_exit.tres`).

**How to test**
1. MANUAL → 4th main segment → steer **right** onto the brown ramp.
2. Drive onto the flat pad (orange corner posts).
3. POI discovers once (`POISystem.discovered_poi` / HUD shows discovered).
4. Return to the main road; when the host recycles the viewpoint unloads — discovery stays in memory.

**Discovery API (`POISystem`)**
| API | Role |
|-----|------|
| `is_discovered(poi_id)` | Logical flag (survives unload) |
| `mark_discovered(poi_id, name)` | First call only emits |
| `discovered_poi` | Signal |
| `spawn_viewpoint` / `despawn_viewpoint` | World presence |

Edit exits under `resources/world/exits/`. Replace `ViewpointPOI` meshes later without changing discovery.

```bash
godot --path . --headless --quit-after 3
godot --path . --headless -s res://scripts/test/drive_smoke.gd
# Expect: … mid_save=OK … conditions=OK … fuel=OK … upgrade=OK … drive_smoke: OK
```

Architecture snapshot: [`docs/architecture-status.md`](docs/architecture-status.md).

## Layout (`res://`)

| Path | Purpose |
|------|---------|
| `scenes/{core,player,vehicles,road,world,ui,test}` | Scenes by domain |
| `scripts/{core,player,vehicles,road,world,ui,test}` | GDScript by domain |
| `resources/{vehicles,road,world}` | Shared resources / configs |
| `assets/{models,materials,textures,audio}` | Art and audio |
| `autoload/` | Autoload scripts (… `VehicleStateSystem`, `GameFlags`, `ConditionSystem`) |
| `data/` | Static data files |

Empty directories keep a `.gdkeep` placeholder so Git tracks them.

## Notes

- Dev main: `scenes/test/DrivingSandbox.tscn` — road pool, recenter, `PlayerVehicle`, `DrivingDebugHUD`
- Motion: `PlayerVehicle` — DRIVING / PARKED (`vehicle_park`, `parking_state_changed`)
- Occupancy: `PlayerOccupancyController` — IN_VEHICLE / ON_FOOT + `PlayerCharacter` (walk/run)
- Interaction: `Interactable` + `InteractionDetector` + `TestTerminal` / `ViewpointTerminal` (stateful OFF→ON)
- NPCs: `NPC.tscn` + `NpcDefinition` (Mira / Rafa at Sunset Viewpoint)
- Dialogue: `DialogueSystem` + `ConditionalDialogue` gates + `DialogueUI`
- Conditions: `ConditionSystem` + `GameFlags` (persist)
- Inventory: `InventorySystem` + `ItemData` catalog + `InventoryDebugUI` (I to toggle)
- Crafting: `CraftingSystem` + `RecipeData` + Workbench + `CraftingDebugUI`
- Save: `SaveSystem` → `user://savegame.json` (F5/F9/F6 debug)
- Game time: `GameTimeSystem` (play / travel / offline; HUD debug)
- Vehicle state: `VehicleStateSystem` (`starter_car` attrs / upgrades / fuel; drives max speed)
- Upgrades: `UpgradeData` + Cruise Module Mk I (+10 km/h via Workbench Install)
- World state: `WorldStateSystem` (terminal powered / pickup collected)
- Pickups: `WorldItem` at Sunset Viewpoint (Scrap Metal / Copper Wire) + `PickupFeedbackUI`
- Quests: `QuestSystem` + `power_the_viewpoint` (Mira → terminal)
- Crafting recipe: Basic Repair Kit at Sunset Viewpoint workbench
- Interiors: `SmallInterior` Observation Booth (walk-in doorway) + `ObservationLog`
- On-foot camera: `OnFootCameraController` — THIRD_PERSON (FIRST_PERSON-ready)
- Driving modes: `DrivingModeController` — MANUAL / CRUISE / TRAVEL_MODE
- Vehicle: cruise speed hold + `RoadFollowAutopilot` (steering under Travel Mode)
- Camera: `VehicleCameraController` — FOLLOW / FAR / HOOD / PASSENGER / WINDOW + Travel Mode cinematic director
- Journey: `JourneySystem` + distance reporter
- Regions: `WorldRegionSystem` + `resources/world/world_region_catalog.tres`
- Road: `RoadSegment` curve × elevation kinds + `RoadManager` pool recycle
- World: `WorldOriginRecenter` + `RoadsideScenery` + `RoadsideExitSystem` + `POISystem` / `ViewpointPOI`
- Dev HUD: full debug, or minimal essentials in Travel Mode
- Empty entry: `scenes/core/Main.tscn`
- Not implemented yet: quest log UI, dialogue choices/branching, NPC routines/pathfinding, weight/equipment UI, region-driven visuals/audio, multi-intersections/cities/traffic/GPS, craft time/quality/tech tree, autosave/multi-slot, final art, gas stations, damage visuals, garage/multi-vehicle, full offline sim caps, final UI
