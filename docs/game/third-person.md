---
name: third-person
description: A worked third-person game from plugins to a test - plugins, settings, player prefab
  with orbit camera and jump, scene, rules with respawn and the test that plays it.
---

# A third-person game

`mirai new <folder> --template game` plays already: floor, spawn point, sky and sun, main menu,
pause, settings and HUD. Follow these steps; then [rules-test.md](third-person/rules-test.md)
(rules, the test). Links are only for what a step does not cover.

## 1. Plugins and settings

`project.mirai`: add `"terrain","foliage","water","fog"` to the `plugins` the game already has.
Remove a plugin only after its imports are gone from `game/` and `tools/`. `settings.mirai` stays:
`Spawn_Settings.players` gives each player a body at the `Spawn_Point` (its `players` on), with no
spawn or camera code. A sunny scene needs no exposure setting and no fog: `render.SKY_DEFAULT` and
a 100000 lux sun are a clear day, auto exposure meters it.

## 2. The player

`assets/player/Player.scene` is the source of the player, as the scene and each `.ui` are: change
it through the API or the editor, and nothing writes over it. With the session open:

```sh
P="mirai rpc --project ."
$P scene.open '{"path":"player/Player.scene"}'
$P scene.write '{"root":"Player","merge":true,"entities":[{
  "components":{
    "Drivable":{"move_relative_to":"Camera"},"Character":{"turn_speed":12},
    "Walk":{"max_speed":7,"air_control":0.55,"coyote_time":0.13,
            "jump_height":1.9,"jump_rise":0.11,"jump_cut":0.42}},
  "children":[
    {"name":"Player view","components":{
      "Camera":{"fov":1.2217,"near":0.05,"active":true},"Audio_Listener":{},
      "Camera_Follow":{"offset":[0,1.5,0],"distance":5,"pitch":0.3,"min_pitch":-0.3,"max_pitch":1.2,
                       "turn":true,"recenter":1.5}}},
    {"name":"Body","position":[0,0.9,0],"scale":[0.6,0.9,0.6],
     "components":{"Mesh_Renderer":{"shape":"Capsule"},"Material_Values":{"color":[0.9,0.45,0.25,1]}}}]}]}'
$P scene.save '{}'
```

One `scene.write` with `merge` changes the fields it names of `Player` and of the child named
`Player view`, makes `Body`, which no child is named yet, and leaves the rest of the prefab as it
is.

W goes where the camera looks and the body turns toward its movement. `Camera_Follow` starts as the
orbit camera, with a probe that keeps it out of walls; `pitch` is in radians and positive is above;
the look action turns it and it swings back behind. Variable jump: hold or tap.

Move, jump, look and menu have their keys already. Your own actions:
[actions-seats.md](character/actions-seats.md). Other cameras: [camera.md](character/camera.md).

## 3. The scene

`assets/arena/main.scene` is a file of the project too. A Sea plane is everything under its
height ([water-fog.md](world/water-fog.md)):

```sh
$P scene.open '{"path":"arena/main.scene"}'
$P scene.write '{"merge":true,"entities":[{"name":"Sea","position":[0,-1,0],"components":{
  "Volume":{"shape":"Plane"},"Fluid":{"density":1025},"Water":{},"Fluid_Waves":{}}}]}'
$P scene.save '{}'
```

Hills and trees in one `--batch` file: [whole-scene.md](assets/whole-scene.md). A moving platform
or a zone: [platforms-triggers.md](character/platforms-triggers.md).
