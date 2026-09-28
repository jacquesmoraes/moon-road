# TerraLua

Godot 4.x 3D project for a long road-trip game from Earth to the Moon.

Current slice: **Travel Mode** — contemplative autopilot so the car can drive the road while you leave the game running. Sandbox still has no fuel, cinematic cameras, or final UI.

## Requirements

- [Godot 4.7+](https://godotengine.org/download) (Forward Plus)

## Run

1. Open this folder in the Godot editor (`project.godot`).
2. Press **F5** (or Play). Dev main scene: `scenes/test/DrivingSandbox.tscn`.

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
| `vehicle_camera_next` / `vehicle_camera_previous` | F / Shift+F |

Tune feel on the `PlayerVehicle` node: `acceleration`, `braking`, `max_speed`, `steering_strength`, `drag`, plus cruise `cruise_target_speed_kmh`, `cruise_speed_deadzone`, `cruise_control_gain`.

### Driving states (`DrivingModeController`)

| Mode | Speed | Steering |
|------|-------|----------|
| `MANUAL` | player | player |
| `CRUISE` | hold target km/h | player |
| `TRAVEL_MODE` | hold target km/h | `RoadFollowAutopilot` road-center |

Travel Mode enables cruise + road-follow together. Cancel immediately with V/T toggle, X/Esc, brake, or manual steer. No cinematic camera suite yet — chase cam stays as-is.

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

Camera never touches vehicle physics. Works in MANUAL / CRUISE / TRAVEL_MODE. Origin recenter shifts the rig with the world. No auto/cinematic switching yet.

### Dev HUD

`DrivingDebugHUD` (top-left): full debug in MANUAL/CRUISE (mode, journey, cruise, autopilot, pos, controls, FPS). In **TRAVEL_MODE** it shrinks to essentials — Travel Mode label, journey km, remaining, speed/target, cancel hint.

### Journey (logical distance)

Autoload `JourneySystem` (`autoload/journey_system.gd`) stores Earth→Moon progress (`total_distance_km = 384400`).

**Units**

- Godot world space: **1 unit = 1 physical meter**
- Physical km = meters / 1000
- Journey km (narrative) = physical km × `physical_to_journey_scale`

**Scale** (on the `JourneySystem` autoload node): `physical_to_journey_scale` default `1.0` means 1 physical km of scene travel → 1 journey km. Changing it only affects logical progress, not car physics.

`JourneyDistanceReporter` on the vehicle reports physical meters only (`add_physical_distance_meters`); conversion lives solely in `JourneySystem`.

### Road segments

`scenes/road/RoadSegment.tscn` — modular piece with curve kinds **`straight`**, **`gentle_left`**, **`gentle_right`** and elevation **`level`**, **`gentle_climb`**, **`gentle_descent`**. Arc length = `length` (default 40 m); curves turn `curve_angle_degrees` (default 18°); grades use `elevation_angle_degrees` (default 5°). Markers `Entrance` / `Exit` carry position, heading, **and pitch** so the next segment aligns in height and grade.

`RoadManager` keeps a **fixed pool** around the player: recycles the rearmost segment to the front via `place_after_exit`. After `start_straight_count` opening straight/level pieces, recycled segments pick weighted random curve + elevation. `sample_road` / centerline follow arcs and grades. Recycle distance is along the rear segment’s forward (planar).

Knobs: `active_segment_count`, `segment_length`, `recycle_behind_distance`, `curve_angle_degrees`, `elevation_angle_degrees`, kind/elevation weights. Pooling, origin recenter, and JourneySystem stay unchanged.

`WorldOriginRecenter` (`scripts/world/world_origin_recenter.gd`) shifts vehicle, road pool, and follow camera when planar distance from origin exceeds `recenter_distance` (sandbox default 500). Journey keeps using position deltas (`notify_origin_shifted`); vehicle velocity is preserved.

### Roadside scenery

`RoadsideScenery` (`scripts/world/roadside_scenery.gd`) — fixed pools of placeholder props (rocks, posts, signs, distant “mountains”). Decorates each `RoadSegment` from a deterministic `(world_seed, sequence_index)` RNG; clears and reuses the same props when the segment is recycled. Placement is offset past road width + shoulders + `roadside_clearance` (never on the roadway). Density knobs: `rocks_per_segment`, `posts_per_segment`, `signs_per_segment`, `mountains_per_segment`, `mountain_chance`, near/far lateral ranges.

Props parent under each segment’s `SceneryAnchor`, so origin recenter moves them with the road. Node count stays bounded to the pool size.

```bash
godot --path . --headless --quit-after 3
godot --path . --headless -s res://scripts/test/drive_smoke.gd
```

## Layout (`res://`)

| Path | Purpose |
|------|---------|
| `scenes/{core,player,vehicles,road,world,ui,test}` | Scenes by domain |
| `scripts/{core,player,vehicles,road,world,ui,test}` | GDScript by domain |
| `resources/{vehicles,road,world}` | Shared resources / configs |
| `assets/{models,materials,textures,audio}` | Art and audio |
| `autoload/` | Autoload scripts (`JourneySystem`) |
| `data/` | Static data files |

Empty directories keep a `.gdkeep` placeholder so Git tracks them.

## Notes

- Dev main: `scenes/test/DrivingSandbox.tscn` — road pool, recenter, `PlayerVehicle`, `DrivingDebugHUD`
- Driving modes: `DrivingModeController` — MANUAL / CRUISE / TRAVEL_MODE
- Vehicle: cruise speed hold + `RoadFollowAutopilot` (steering under Travel Mode)
- Camera: `VehicleCameraController` — FOLLOW / FAR / HOOD / PASSENGER / WINDOW (no auto-cine yet)
- Journey: `JourneySystem` + distance reporter
- Road: `RoadSegment` curve × elevation kinds + `RoadManager` pool recycle
- World: `WorldOriginRecenter` + `RoadsideScenery` (pooled procedural props)
- Dev HUD: full debug, or minimal essentials in Travel Mode
- Empty entry: `scenes/core/Main.tscn`
- Not implemented yet: Travel Mode cinematic cameras, sharper/procedural roads, final art, fuel, damage, upgrades, final UI, inventory, save, quests
