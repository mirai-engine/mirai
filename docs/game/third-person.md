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
`Spawn_Settings.players` gives each player a body at the `Spawn_Point`, with no spawn or camera
code. A sunny scene needs no exposure setting and no fog: `render.SKY_DEFAULT` and a 100000 lux sun
are a clear day, auto exposure meters it.

## 2. The player

Replace `write_player` in `tools/content/main.odin` and run the tool with `mirai content`:

```odin
write_player :: proc(c:^asset.Content) {
    b:asset.Scene_Builder
    asset.builder_init(&b,c,asset.KIND_PREFAB,PLAYER_PREFAB_ID)
    defer asset.builder_destroy(&b)
    root:=asset.builder_entity(&b,"Player")
    character:=phys.character_default()
    character.move_relative_to=.Camera   // W goes where the camera looks
    character.turn_speed=12              // the body turns toward its movement
    asset.builder_set(&b,root,character)
    walk:=phys.WALK_DEFAULT
    walk.max_speed,walk.air_control,walk.coyote_time=7,0.55,0.13
    walk.jump_height,walk.jump_rise,walk.jump_cut=1.9,0.11,0.42 // variable height: hold or tap
    asset.builder_set(&b,root,walk)
    asset.builder_set(&b,root,phys.collider_character())
    asset.builder_set(&b,root,game.Player{})
    body:=asset.builder_entity(&b,"Body",{position={0,0.9,0},scale={0.6,0.9,0.6}},root)
    asset.builder_set(&b,body,render.Mesh_Renderer{shape=.Capsule})
    asset.builder_set(&b,body,render.Tint{color={0.9,0.45,0.25,1}})
    view:=asset.builder_entity(&b,"Player view",{},root)
    asset.builder_set(&b,view,render.Camera{fov=game.VIEW_FOV,near=0.05,active=true})
    asset.builder_set(&b,view,audio.Audio_Listener{})
    follow:=cam.CAMERA_FOLLOW_DEFAULT    // Orbit; a probe keeps it out of walls
    follow.offset,follow.distance={0,1.5,0},5
    follow.pitch,follow.min_pitch,follow.max_pitch=0.3,-0.3,1.2 // radians; positive is above
    follow.turn,follow.recenter=true,1.5 // the look action turns it; it swings back behind
    asset.builder_set(&b,view,follow)
    asset.builder_set(&b,root,inp.Drivable{camera=core.Entity(view)})
    asset.builder_save(&b,"assets/prefabs/Player.prefab")
}
```

Move, jump, look and menu have their keys already. Your own actions:
[actions-seats.md](character/actions-seats.md). Other cameras: [camera.md](character/camera.md).

## 3. The scene

The content tool is the source of `assets/scenes/main.scene`: change `write_scene` in
`tools/content/main.odin` and run the tool again. A run rewrites the scene, so an edit made through
the API or the editor is lost at the next run. A Sea plane is everything under its height
([water-fog.md](world/water-fog.md)); with `water "plugins:water/runtime"` imported, before
`asset.builder_save`:

```odin
water.builder_sea(&b,"Sea",height=-1)
```

Hills and trees in the same tool: [whole-scene.md](assets/whole-scene.md). A moving platform or a
zone: [platforms-triggers.md](character/platforms-triggers.md).
