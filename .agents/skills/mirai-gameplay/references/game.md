# Write a game

How a game is written is in [the docs games read](../../../../docs/game/core.md), with a whole
third-person game in [third-person](../../../../docs/game/third-person.md); this page keeps what
an engine developer needs besides. A game is an Odin package with components, storages and
functions; the [generator](../../mirai-core/references/generator.md) reads the attributes and
writes the world.
Live examples: [`templates/empty/game`](../../../../templates/empty/game/game.odin) (one component
and one function), [`templates/game/game`](../../../../templates/game/game/game.odin) (playable) and
[`demo/game`](../../../../demo/game).

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
- **Play a clip or a cinematic**: `anim.animation_command` in `^anim.Animation_Requests`
  (`animation_timeline`, plugin `animation`).
- **Change scene**: `scene.request(&r, id)`, `request_path` or `request_restart` in
  `^scene.Scene_Requests` (`scene_requests`); the result arrives in `scene.Scene_Results`.
- **Instantiate a prefab**: `scene.spawn(spawner, path_or_id, at)`, which gives the root.
- **Save or load**: `save.request_save(&r, "slot")`, `request_load`, `request_delete` in
  `^save.Save_Requests` (`saves_serve`).
- **Send a network message**: `multiplayer.send(&outbox, time, value)` with a struct
  `@(net_message)` in `^multiplayer.Net_Outbox` (`net_tick_tail`); it does not queue while a
  rollback replays the tick.

Events the libraries emit: `phys.Physics_Events` (`contact_begin`, `overlap_begin`, `sleep`,
`joint_break`...), `destruct.Destruct_Events`, `gui.UI_Events`, `anim.Animation_Events`,
`save.Save_Results`, `scene.Scene_Results`, `net.Net_Events`. They
are cleared and filled once per tick or frame; those of the frame (`Save_Results`, `Scene_Results`)
are read in a `frame` step, the others with `core.Ref(...)` in the same tick,
in a function that runs after the emitting one: those of physics and destruction in the `react`
stage ([order](../../mirai-core/references/generator.md#order)), those of animation with
`stage="react",after="animation_advance"`.

Scenes, prefabs and input: [scene](libraries.md#scene) and [input](libraries.md#input); a player's
actions are read from the seat that drives the body, with its blocks ([control](control.md)).

## Game code style rules

- One file per topic.
- Gameplay constants with a name (`WALK_SPEED`); units in the name or in the tag (`unit=m`).
- Only `core`, `host`, `engine/*`, the `runtime` parts of the active plugins
  (`plugins:physics/runtime`, `plugins:multiplayer/runtime`...), `ui`, `audio`, `asset`,
  `platform` (for the mouse) and `std/*` are imported.
