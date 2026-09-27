# TerraLua

Godot 4.x 3D project for a long road-trip game from Earth to the Moon.

Current slice: **drivable placeholder vehicle** in a lit development sandbox. No fuel, road, UI, or other gameplay systems yet.

## Requirements

- [Godot 4.7+](https://godotengine.org/download) (Forward Plus)

## Run

1. Open this folder in the Godot editor (`project.godot`).
2. Press **F5** (or Play). Dev main scene: `scenes/test/DrivingSandbox.tscn`.

### Drive controls

| Action | Keys |
|--------|------|
| `vehicle_accelerate` | W / Up |
| `vehicle_brake` (brake / reverse; cancels cruise) | S / Down |
| `vehicle_left` | A / Left |
| `vehicle_right` | D / Right |
| `vehicle_cruise_toggle` | C |
| `vehicle_autopilot_toggle` | T |
| `vehicle_autopilot_cancel` | X / Esc |

Tune feel on the `PlayerVehicle` node: `acceleration`, `braking`, `max_speed`, `steering_strength`, `drag`, plus cruise `cruise_target_speed_kmh`, `cruise_speed_deadzone`, `cruise_control_gain`.

Road-follow autopilot (`RoadFollowAutopilot`): samples `RoadManager.sample_road()` (centerline lateral + look-ahead). Enables cruise for speed and steers via `set_steer_override`. Cancel with X/Esc, brake, or manual steer.

### Camera (third-person follow)

On `VehicleCameraController` (inside `PlayerVehicle.tscn`):

| Export | Role |
|--------|------|
| `follow_distance` | How far behind the car |
| `follow_height` | How high above the car |
| `follow_smoothing` | Position catch-up (higher = snappier) |
| `rotation_speed` | How fast the chase yaw follows turns (higher = snappier) |

Camera logic lives in `scripts/vehicles/vehicle_camera_controller.gd` (not in the vehicle script) so more modes can be added later.

### Dev HUD

`DrivingDebugHUD` (top-left debug labels): journey `current / 384.400 km`, remaining, speed km/h, position, controls, optional FPS. Reads `JourneySystem` + vehicle public APIs only.

### Journey (logical distance)

Autoload `JourneySystem` (`autoload/journey_system.gd`) stores Earth→Moon progress (`total_distance_km = 384400`).

**Units**

- Godot world space: **1 unit = 1 physical meter**
- Physical km = meters / 1000
- Journey km (narrative) = physical km × `physical_to_journey_scale`

**Scale** (on the `JourneySystem` autoload node): `physical_to_journey_scale` default `1.0` means 1 physical km of scene travel → 1 journey km. Changing it only affects logical progress, not car physics.

`JourneyDistanceReporter` on the vehicle reports physical meters only (`add_physical_distance_meters`); conversion lives solely in `JourneySystem`.

### Road segments

`scenes/road/RoadSegment.tscn` — modular straight piece (primitives). Exports: `length`, `width`, `thickness`, `shoulder_width`, `show_shoulders`. Markers `Entrance` (+Z) and `Exit` (−Z).

`RoadManager` (`scripts/road/road_manager.gd`) in DrivingSandbox keeps a **fixed pool** of segments around the player: recycles the rearmost segment to the front (`place_after_exit`). Knobs: `active_segment_count`, `segment_length`, `recycle_behind_distance`, `initial_first_center_z`. No infinite Node growth; no JourneySystem / UI coupling.

`WorldOriginRecenter` (`scripts/world/world_origin_recenter.gd`) shifts vehicle, road pool, and follow camera when planar distance from origin exceeds `recenter_distance` (sandbox default 500). Journey keeps using position deltas (`notify_origin_shifted`); vehicle velocity is preserved.

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
- Vehicle: cruise + `RoadFollowAutopilot` (road-center steering; not Travel Mode)
- Camera: `VehicleCameraController` — smooth third-person follow
- Journey: `JourneySystem` + distance reporter
- Road: `RoadSegment` + `RoadManager` (fixed pool recycle)
- World: `WorldOriginRecenter`
- Dev HUD: journey / cruise / autopilot / debug readouts
- Empty entry: `scenes/core/Main.tscn`
- Not implemented yet: Travel Mode camera suite, curved procedural roads, fuel, damage, upgrades, final UI, inventory, save, quests
