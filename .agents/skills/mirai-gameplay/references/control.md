# Seats, cameras and movement

Control splits across three packages:
- `engine/input` (`inp`): seats, actions, sole writer of `Seat.body` (`Seat_Requests`), and
  `Move_Input` (shared by camera, networking, replay).
- `engine/camera` (`cam`): seat cameras, following cameras, transitions, `camera_drive`, sole
  writer of `render.View_Camera`, `Camera_Follow`, and camera lenses (`Camera_Requests`,
  `Camera_Changes`, `Camera_Input`).
- `spawn` plugin: [spawn points](#spawn-points) and player bodies.

A **seat** (`Seat{slot, remote, body}`) is a player — local (`seat_local`) or of another end
(`remote`, set by the network) — and exists even without a body. For AI steering, see
[locomotion](../../mirai-physics/references/engine.md#what-drives-it).

## Seats

`input_seats` (`fixed`, `input`) creates local seats and updates tick actions.

- **Local count**: `Run_Players` (`keep`; Play selector or `--players`, default 1; 0 on a
  dedicated server unless `--players n`). Reuses scene seats per slot or spawns them at runtime.
- **Devices**: keyboard/mouse go to `Seats.focus`; 1 local player gets all gamepads, multiple get
  gamepad `i` -> slot `i`.
- **State**: `Seat` replicates with game children (`peer`, `player`, `body` stay `local`).
  `Seat_States` holds tick state (`seat_feed` local, `seat_receive` remote); `Frame_Actions`
  holds per-slot presentation actions.
- **Holds**: `inp.hold(r, seat, action, value, ticks)` / `inp.let_go` in `^inp.Hold_Requests`
  inject action input by action id (tests, `play.input`). `input_holds` (`fixed`, `begin`)
  applies them for whole ticks before devices; they obey contexts/blocks/re-arming, skip
  `Frame_Actions`, and reject remote seats (`input.hold_remote_seat`).

## Actions

Declare actions as `@(actions)` `u8` enums (lowercase member names) with sibling defaults
`<enum>_defaults() -> [E]inp.Action_Bindings` or `<ENUM>_DEFAULTS` (generator registers via
`core.Actions_Info.defaults` into `inp.Action`, engine -> plugins -> game; structs holding
`[E]Action_Bindings` are rejected). See [named ids](../../mirai-core/references/core.md#named-ids).

```odin
@(actions)
Action :: enum u8 { Use, Aim, Save }

MENU_CTX :: inp.Input_Context(1)

action_defaults :: proc "contextless" () -> [Action]inp.Action_Bindings {
    k :: inp.binding_key; p :: inp.binding_gamepad_button
    return {
        .Use  = inp.action_default(.Button, k(.E), p(.West)),
        .Aim  = inp.action_default(.Button, inp.binding_mouse_button(.Right)),
        .Save = inp.action_default_in(MENU_CTX, .Button,
            inp.binding_chord(k(.S), inp.code_key(.Left_Control))),
    }
}
```

- **Reading**: pass `inp.Input_Of(E)` (generator
  [parameter group](../../mirai-core/references/generator.md#parameter-groups)) for focused seat
  (`inp.pressed(in, .Use)`, `down`, `released`, `tapped`, `holding`, `value`, `vector`), body
  (`inp.pressed(in, body, .Use)`), or seat (`inp.seat_pressed(in, seat, .Use)`). Presentation:
  `inp.Frame_Input_Of(E)` / `inp.slot_frame_state`. Dynamic `inp.Action`: `inp.action_of`,
  `inp.action`, `seat_action`, `body_action`.
- **Scale & rates**: `scale` applies after dead zone. In mouse-axis actions (`Look`), non-mouse
  bindings are rates per second; look travels/replays as per-tick delta.
- **Settings & rebuild**: `inp.Input_Settings` in `settings.mirai`
  ([settings](../../mirai-projects/references/projects.md#project-settings)) overrides defaults
  (`input_settings_put`/`input_settings_remove`). `input_map_build` rebuilds on revision change.
  Problems: `input.settings` (refused by `settings.set` via `input_settings_problem`),
  `input.action_unbound`, `input.default_*`. `input.get` lists entries.
- **Renaming**: rename enum member in code, rebuild, then run `names.rename` on `Action` (updates
  `Input_Settings` and project documents; refuses if old remains or new is absent; `names.create`
  cannot declare actions).
- **Re-arming & blocks**: switching body/focus or releasing a block re-arms held buttons (context
  change re-arms newly pressed buttons; losing keyboard fires `released`; axes keep moving).
  `inp.input_block(r, owner, seat, mask)` / `input_unblock(r, owner)` (`seat=NONE` = all local;
  1 block/owner; applied in `input_drive` to `Seat_State.blocked`).

### Contexts

`inp.Input_Context` (`@(names)`, `< CONTEXT_CAPACITY`; always in `CONTEXT_BASE`, `CONTEXT_ALWAYS`
reserved) groups bindings via `action_default_in` or `"context"` in `Input_Settings`.

- `inp.input_context_enter(r, owner, seat, ctx, modal)` / `inp.input_context_leave(r, owner)` in
  `^inp.Context_Requests` apply in `input_contexts` (`fixed`, `begin`) into `Seat_State.contexts`.
  One per owner, LIFO stack, auto-removed when owner dies.
- **Capture**: higher contexts steal matching codes (gamepad-specific matches all-gamepads);
  `modal` steals all inputs below. `Frame_Actions` follow seat contexts without re-arming.
- `UI_Screen` with `input_context` enters while active (`Modal` enters modal instead of full
  block; see [gui](libraries.md#gui)). Evaluated only where devices live.

### Chords

`inp.binding_chord(binding, inp.code_key(.Left_Control))` (JSON `"chord": ["Left_Control"]`, up to
`CHORD_CAPACITY`) requires chord modifiers held; active longer chords capture inputs from shorter
or unchorded bindings.

## Driving

- `^inp.Seat_Requests` (`drive`, `release`, `focus`, blocks) apply in `input_drive` (`fixed`,
  `input`). Released bodies zero move/buttons and keep look. Invalid requests make no partial
  changes and report problems (`input.body_taken`, `body_gone`, `server_decides`).
- **Forward**: `camera_drive` (`fixed`, `input`, after `camera_select` + `input_drive`) writes
  `Move_Input` from seat actions in the `core.Vertical` frame (+ `Vertical.turn`) toward the
  seat's tick view (`input.Seat_View`: `camera_blend` writes `Slot_Views` as it draws,
  `input_seats` gives it to the seat, the network to remote seats), never camera transforms.
  Look-with-body cameras (`Eyes`, aiming `Orbit`, body camera without `Camera_Follow`) turn body
  look, from the view when the seat comes from an `Apart` camera; others face movement along the
  view; no camera uses world `-Z`.
- **1:1 index**: `body_of` reads `Seat`; `seat_of` reads `core.Ref(inp.Seats)`. `Seats` is
  derived (reset on load); dead owners/seats auto-clean. AI and scripts write the `Move_Input` of
  bodies no seat drives with `move_set` (`world_velocity` for m/s) and drop it with
  `move_release`; seated bodies are the seat's.

```odin
@(step="fixed")
swap_body :: proc(
    seats:^core.Table(inp.Seat,.Read), actions:inp.Input_Of(Action),
    seat_req:^inp.Seat_Requests, cam_req:^cam.Camera_Requests,
    cam_chg:^cam.Camera_Changes, cam_state:core.Ref(cam.Cameras),
    target, shared_cam, body_cam:core.Entity,
) {
    seat := core.entity_at(seats, 0)
    if inp.seat_pressed(actions, seat, .Use) { inp.drive(seat_req, seat, target) }
    if inp.seat_pressed(actions, seat, .Aim) {
        if cam.camera_overriding(cam_state, seat) {
            cam.camera_override_remove(cam_req, seat)
        } else {
            cam.camera_override(cam_req, seat, seat, shared_cam, blend={seconds=0.5})
        }
        cam.camera_mode(cam_chg, body_cam, .Third_Person)
    }
}
```

## Spawn points

`spawn` plugin manages `Spawn_Point{prefab, players}` (`players=true` for seats, `false` for game
spawns; disabled points skipped; round-robin when `point=NONE`). Prefab order: request `path` ->
point `prefab` -> `Spawn_Settings.prefab` (seats only).

- `^spawn.Spawn_Requests` (`spawn.spawn(r, seat, path="", point=NONE)`, `spawn.respawn(r, body,
  point=NONE)` using [`core.place`](../../mirai-core/references/core.md#requested-places)) run in
  `spawn_step` (`fixed`, `input`) before `input_drive`, so spawned bodies drive the same tick.
- Seat bodies are `transient` + `Seat_Body` (auto-destroyed by `spawn_seat_bodies` when seat
  leaves); game spawns (`seat=NONE`) keep `Id`. Auto-spawn runs whenever `Spawn_Settings.prefab`
  or any player point names a prefab (retrying after `SPAWN_RETRY`).
- **Editor Play**: with no player point, spawns at `scene.Play_Origin`; `Play_Origin.asked` places
  player 1's first body there (`Spawning.asked_given`) and emits `Spawned_At_Origin`
  (`spawn_physics` rests collider on ground).
- **Problems & limits**: `SPAWN_CAPACITY`/tick (`spawn.spawns_full`), `spawn.no_spawn_point`,
  `scene.spawn`, `spawn.client_spawn` (clients never spawn). Replicated prefabs receive their
  seat's connection as `owner` (see
  [replicated entities](../../mirai-networking/references/multiplayer.md#what-the-game-declares)).
  Collision presets live on the prefab's `Collider`
  ([presets](../../mirai-physics/references/engine.md#collision-categories-and-presets)).

```odin
spawn.spawn(spawn_req, seat)                          // next player point or project prefab
spawn.spawn(spawn_req, core.NONE, "ai/Zombie.scene")  // game entity at non-player point
spawn.respawn(spawn_req, body)                        // reset body to next point
inp.hold(hold_req, seat, inp.action_of(actions, .Use), {1, 0}, ticks=2)
```

## Cameras

- `camera_selected` picks latest valid override else `body_camera` (first `render.Camera` on/under
  body). `cam.aim(sight, body)` returns the seen camera's ray.
- **Free camera**: in editor Play (`Play_Origin`), if player 1 has no body and scene has no active
  `Camera`, `camera_free` spawns a flying camera; gone permanently once player 1 drives a body
  (never in shipped builds).
- **Overrides & activation**: `camera_override`/`camera_override_remove` (`Camera_Requests`;
  failures report `camera.*`) settle in `camera_select` (`fixed`, `input`); `Cameras` is derived.
  `Camera_Activation{action, blend}` (`Aim` preset) overrides while holding `action`.
- **Views & transitions**: `camera_blend` (`late`, `end`) writes `Camera_Views`, `input.Slot_Views`
  and
  `render.View_Camera` (`posed` preserves temporal history; no blend marks `cut`). Transitions
  track moving bodies, orbit around pivots, dolly-zoom between perspective and ortho, and set
  `core.View.focus` at orbit pivot for
  [GI](../../mirai-rendering/references/gi.md#probe-volume). Split-screen uses `camera_local_views`
  (`host.app_player_rect`, `host.app_views_set`,
  [Play](../../mirai-editor/references/editor.md#play)).

### Following cameras

`Camera_Follow` (`locks="core.Transform"`; runtime `Camera_Follow_State`; `target=NONE` resolves
to driven ancestor/root/focused player; writing its transform elsewhere triggers `core.fail`).

| Mode | Behavior |
| --- | --- |
| `Follow` | Smoothed pivot at `offset` (`half_life`, `up_half_life`), optional `look_at`, `dead_zone`, `look_ahead`/`look_ahead_max` |
| `Orbit` | Orbits pivot at `distance`/`shoulder` (`yaw`/`pitch`/`min_pitch`/`max_pitch`), `look_up_offset`/`look_down_offset`, `Spring_Arm` probe (`probe_radius` via [`core.World_Queries`](../../mirai-core/references/core.md#world-queries), `pull_grace`/`pull_time`/`return_delay`/`return_time`/`arm_margin`, `engine/camera/rigs.odin` also has `Follow`/`Orbit`/`Shake`), `hide_within` fades `<2x` and hides `<1x`; `aim` follows `Move_Input` look, else `turn`/`recenter`/`camera_look` |
| `Eyes` | First-person at `offset` following `Move_Input` look |

- **Own body**: `camera_blend` writes `render.View_Bodies`; lens `own_hidden` hides layers
  (`HEAD_LAYER`, `Skin_Part` in
  [animation](../../mirai-animation/references/animation.md#components-and-shared-data))
  upon blend arrival only. Other views, shadows, reflections, and mirrors draw the full body.
- **Vertical & queues**: offsets/orbit/look use
  [`core.Vertical`](../../mirai-core/references/core.md). `Camera_Input` is per-frame (`late`);
  `Camera_Requests` is per-tick (`fixed`).
- **Modes**: `Camera_Setup{follow, lens}` and `CAMERA_PRESETS` via
  `camera_mode(&Camera_Changes, camera, preset_or_setup, blend)` (idempotent; preserves target and
  free orbit look; failures report `camera.mode_*`). Preview:
  [camera preview](../../mirai-editor/references/editor.md#camera-preview).

## Networking

- Server decides driving and spawning (`owner` from the `multiplayer.Net_Seat` of the seat);
  `Seat.body` replicates. A client makes no seats: it plays at the replica it owns, slot 0, and
  the others are `remote`
  ([authority](../../mirai-networking/references/multiplayer.md#authority-and-players)).
- `input` has no net dependency: clients only drive `core.owned` bodies (`input.server_decides`),
  drop unowned ones; `spawn` rejects client spawns (`spawn.client_spawn`).
- Clients send only slot 0 `inp.Remote_Actions` with its `Seat_View` (`seat_remote` -> server
  `seat_receive`); bindings stay client-local; other peers receive only `Move_Input`.
- Disconnected seats wait disabled; on timeout they are removed and `spawn` destroys `Seat_Body`.
  Rollback restores `Seats`, `Seat`, `Seat_States` with the world.

## Verification

- `mirai test engine/input` (`input_test.odin`, `seats_test.odin`, `holds_test.odin`,
  `remote_test.odin`).
- `mirai test editor renaming_an_action_follows_the_code_in_input_settings
  the_bindings_are_set_as_settings_and_refused_with_the_fix`.
- `mirai test plugins/spawn/runtime` and `mirai test engine/camera` (`rigs_test.odin`,
  `drive_test.odin`).
- Integration: [control scene](demo.md#control) headless with input script, and dedicated server +
  client.
