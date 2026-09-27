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

Tune feel on the `PlayerVehicle` node: `acceleration`, `braking`, `max_speed`, `steering_strength`, `drag`, plus cruise `cruise_target_speed_kmh`, `cruise_speed_deadzone`, `cruise_control_gain`.

### Driving states (`DrivingModeController`)

| Mode | Speed | Steering |
|------|-------|----------|
| `MANUAL` | player | player |
| `CRUISE` | hold target km/h | player |
| `TRAVEL_MODE` | hold target km/h | `RoadFollowAutopilot` road-center |

Travel Mode enables cruise + road-follow together. Cancel immediately with V/T toggle, X/Esc, brake, or manual steer. No cinematic camera suite yet — chase cam stays as-is.

`RoadFollowAutopilot` only steers (`set_steer_override`); the mode controller owns when it is on.

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
- Driving modes: `DrivingModeController` — MANUAL / CRUISE / TRAVEL_MODE
- Vehicle: cruise speed hold + `RoadFollowAutopilot` (steering under Travel Mode)
- Camera: `VehicleCameraController` — smooth third-person follow (no Travel Mode cinematics yet)
- Journey: `JourneySystem` + distance reporter
- Road: `RoadSegment` + `RoadManager` (fixed pool recycle)
- World: `WorldOriginRecenter`
- Dev HUD: full debug, or minimal essentials in Travel Mode
- Empty entry: `scenes/core/Main.tscn`
- Not implemented yet: Travel Mode cinematic cameras, curved procedural roads, fuel, damage, upgrades, final UI, inventory, save, quests
