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
| `vehicle_brake` (brake / reverse) | S / Down |
| `vehicle_left` | A / Left |
| `vehicle_right` | D / Right |

Tune feel on the `PlayerVehicle` node: `acceleration`, `braking`, `max_speed`, `steering_strength`, `drag`.

### Camera (third-person follow)

On `VehicleCameraController` (inside `PlayerVehicle.tscn`):

| Export | Role |
|--------|------|
| `follow_distance` | How far behind the car |
| `follow_height` | How high above the car |
| `follow_smoothing` | Position catch-up (higher = snappier) |
| `rotation_speed` | How fast the chase yaw follows turns (higher = snappier) |

Camera logic lives in `scripts/vehicles/vehicle_camera_controller.gd` (not in the vehicle script) so more modes can be added later.

### Headless checks

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
| `autoload/` | Future autoload scripts (none registered yet) |
| `data/` | Static data files |

Empty directories keep a `.gdkeep` placeholder so Git tracks them.

## Notes

- Dev main: `scenes/test/DrivingSandbox.tscn` — ground, sky, lighting, scale refs, `PlayerVehicle`
- Vehicle: `scenes/vehicles/PlayerVehicle.tscn` + `scripts/vehicles/player_vehicle.gd` (arcade `CharacterBody3D`, primitives only)
- Camera: `scripts/vehicles/vehicle_camera_controller.gd` — smooth third-person follow (`VehicleCameraController`)
- Empty entry: `scenes/core/Main.tscn`
- Not implemented yet: multi-camera switching, cockpit, cinematic, infinite road, fuel, damage, upgrades, inventory, save, quests, UI
