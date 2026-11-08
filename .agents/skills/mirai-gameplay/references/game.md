# Write a game

A game is an Odin package with components, storages and functions; the
[generator](../../mirai-core/references/generator.md) reads the attributes and writes the world.
Live examples: [`templates/empty/game`](../../../../templates/empty/game/game.odin) (one component
and one function), [`templates/game/game`](../../../../templates/game/game/game.odin) (playable) and
[`demo/game`](../../../../demo/game).

## One function

```odin
package game

import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"

@(component)
Spinner :: struct {speed:f32 `mirai:"unit=rad/s"`}

@(step="fixed")
game_spin :: proc(spinners:core.Read(Spinner),transforms:^core.Table(core.Transform),
                  actions:core.Ref(inp.Actions),time:core.Time) {
    for row in 0..<core.count(spinners) {
        local:=core.free(transforms,core.entity_at(spinners,row))
        if local==nil {continue}
        spin:=mm.quat_axis_angle({0,1,0},core.at(spinners,row).speed*time.dt)
        local.rotation=spin*local.rotation
    }
}
```

- Walking a component is walking its rows (`core.count`, `core.at`, `core.entity_at`); per entity,
  `core.get` and `core.has`.
- `Transform` is `shared`: several functions write it with `core.free(transforms, e)`, which gives
  `nil` on the rows owned by another library (a body, a following camera). To move something that
  physics owns, `phys.set_velocity` or an impulse; to teleport or place any entity without knowing
  who owns its `Transform`, only
  [`core.place`](../../mirai-core/references/core.md#requested-places).
- Function names are unique across the whole world: they carry the package prefix (`game_spin`).

## Entities and components

- `core.create` gives a handle immediately; its components appear for the next function.
  `core.destroy_tree` with a `core.Ref(core.Hierarchy)` also destroys what hangs from it
  ([hierarchy queries](../../mirai-core/references/core.md#queries)).
- To create an entity with components of tables that the function does not write, receive
  `core.Commands` (used by `scene.spawn`, `spawn.spawn` and the dog of `demo/game/control.odin`).
  An existing row is changed with `^core.Table(T)` if the function is its writer, or with a request
  to its library.
- References to other entities are `core.Entity` fields; scenes and saves store them as `Id`.
- An entity is identity, `Transform`, hierarchy (`Parent`) and whatever is added to it. A preset is
  a prefab, not a stored type.

## Requests and events

Libraries talk to each other through queues in storages
([core](../../mirai-core/references/core.md#queues-and-references)). Each request goes to the queue
of its owner and is taken by the function in parentheses:

- **Move a body**: `phys.set_velocity(&requests, e, v)`, `apply_impulse`, `move_kinematic`,
  `launch` in `^phys.Body_Requests` (`physics_step`); teleport it with `core.place(placer, ...)`
  in `^core.Places` (`physics_places`).
- **Layered moves and mode of a character** (dash, wind; swimming): `phys.add_move`,
  `remove_moves`, `set_mode` in `^phys.Locomotion_Requests` (`locomotion_step`).
- **Damage or cut**: `destruct.damage(&r, e, point, radius, impulse)`, `slice` in
  `^destruct.Destruct_Requests` (`destruct_step`).
- **Drive a body, block actions**: `inp.drive`, `release`, `swap`, `focus`,
  `input_block` in `^inp.Seat_Requests` (`input_drive`).
- **Change camera**: `camera.camera_override` in `^camera.Camera_Requests` (`camera_select`).
- **Change the mode of a camera**: `camera.camera_mode` in `^camera.Camera_Changes`
  (`camera_follow`), with a preset or a `Camera_Setup` and a transition.
- **Make a body appear**: `spawn.spawn`, `respawn` in `^spawn.Spawn_Requests`
  (`spawn_step`, plugin `spawn`).
- **Play a cinematic**: `cinematics.cinematic_play` and its companions in
  `^cinematics.Cinematic_Requests` (`cinematic_advance`, plugin `cinematics`).
- **Change scene**: `scene.request(&r, id)`, `request_path` or `request_restart` in `^scene.Scene_Requests`
  (`scene_requests`); the result arrives in `scene.Scene_Results`.
- **Instantiate a prefab**: `scene.request_spawn(spawns, path, at)` in `^scene.Spawns`
  (`scene_spawns`), or `scene.spawn(spawner, path, at)` for the root.
- **Save or load**: `save.request_save(&r, "slot")`, `request_load`, `request_delete` in
  `^save.Save_Requests` (`saves_serve`).
- **Send a network message**: `net.send(&outbox, time, value)` with a struct
  `@(net_message)` in `^net.Net_Outbox` (`net_tick_tail`); it does not queue while a rollback
  replays the tick.

Events the libraries emit: `phys.Physics_Events` (`contact_begin`, `overlap_begin`, `sleep`,
`joint_break`...), `destruct.Destruct_Events`, `gui.UI_Events`, `anim.Animation_Events`,
`cinematics.Cinematic_Events`, `save.Save_Results`, `scene.Scene_Results`, `net.Net_Events`. They
are cleared and filled once per tick or frame; those of the frame (`Save_Results`, `Scene_Results`)
are read in a `frame` step, the others with `core.Ref(...)` in the same tick,
in a function that runs after the emitting one: those of physics and destruction in the `react`
stage ([order](../../mirai-core/references/generator.md#order)), those of animation with
`stage="react",after="animation_advance"`.

Scenes, prefabs and input: [scene](libraries.md#scene) and [input](libraries.md#input); a player's
actions are read from the seat that drives the body, with its blocks ([control](control.md)).

## Playable template

`templates/game/game/game.odin` defines:

- The game's actions and their default bindings (`Game_Actions`), next to those of locomotion.
- The prefab's character is a `Character` with `Walk`, relative to its look direction: the seat's
  actions pass to its `Move_Input` (the player of this machine; on the server, that of each
  connection).
- `game_hit` (`fixed`, `server`): with the action of the seat that drives each player
  (`inp.pressed(players, body, HIT)`), `phys.raycast` from the eyes and `destruct.damage` on what
  it touches. `game_play` counts the hits through `Destruct_Events.applied` on all ends;
  `game_saves` (`frame`) requests save and load and shows their results.

There is no spawn or camera code: `Spawn_Settings` with `"players": true` and the scene's
`Spawn_Point` give a character (`Player.prefab`, with `Replicate`) to the player of this machine
and to each connection, and the prefab's camera is a `Camera_Follow` in `Eyes` mode.

## Game code style rules

- One file per topic.
- Gameplay constants with a name (`WALK_SPEED`); units in the name or in the tag (`unit=m`).
- Only `core`, `host`, `engine/*`, the `runtime` parts of the active plugins
  (`plugins:physics/runtime`, `plugins:multiplayer/runtime`...), `ui`, `audio`, `asset`,
  `platform` (for the mouse) and `std/*` are imported.
