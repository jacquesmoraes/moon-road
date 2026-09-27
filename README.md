# TerraLua

Godot 4.x 3D project scaffold for a long road-trip game from Earth to the Moon.

This repository currently contains **project structure only** — no gameplay systems yet.

## Requirements

- [Godot 4.7+](https://godotengine.org/download) (Forward Plus)

## Run

1. Open this folder in the Godot editor (`project.godot`).
2. Press **F5** (or Play). Development main scene is currently `scenes/test/DrivingSandbox.tscn` (lit ground + scale refs; no vehicle yet). Production entry remains `scenes/core/Main.tscn`.

Headless smoke check:

```bash
godot --path . --headless --quit-after 2
godot --path . --headless --scene res://scenes/test/DrivingSandbox.tscn --quit-after 3
```

## Layout (`res://`)

| Path | Purpose |
|------|---------|
| `scenes/{core,player,vehicles,road,world,ui,test}` | Scenes by domain |
| `scripts/{core,player,vehicles,road,world,ui}` | GDScript by domain |
| `resources/{vehicles,road,world}` | Shared resources / configs |
| `assets/{models,materials,textures,audio}` | Art and audio |
| `autoload/` | Future autoload scripts (none registered yet) |
| `data/` | Static data files |

Empty directories keep a `.gdkeep` placeholder so Git tracks them.

## Notes

- Dev main (temporary): `scenes/test/DrivingSandbox.tscn` — ground, sky, lighting, scale refs for future vehicle work
- Empty entry: `scenes/core/Main.tscn`
- Minimal sandbox: `scenes/test/TestSandbox.tscn`
- No vehicle, road, inventory, save, quest, procedural, or UI systems yet.
