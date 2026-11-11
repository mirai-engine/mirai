---
name: character
description: Player and character control in a Mirai game - Character, Walk (speed, jump, jump_cut,
  sprint), input actions, seats, Camera_Follow pitch, spawn points, platforms, triggers, swimming.
---

# Game character

A player is a seat (`inp.Seat`) that drives a body (`inp.Drivable`); a body that walks is a physics
`Character`. Plugins `physics` and `spawn` in `project.mirai`. Imports: `phys
"plugins:physics/runtime"`, `inp "mirai:engine/input"`, `cam "mirai:engine/camera"`.

## Map

- A whole third-person game, prefab, camera and rules: [third-person](third-person.md).
- The prefab of a walking body: [Body](#body). Speed, jump, sprint, crouch: [Walk](#walk).
- Your own actions, reading them, who drives what: [actions-seats.md](character/actions-seats.md).
- First or third person, changing view, the sign of `pitch`: [camera.md](character/camera.md).
- Lifts, moving floors, trigger zones, who is inside:
  [platforms-triggers.md](character/platforms-triggers.md).
- Water, swimming, the surface at a point: [swimming.md](character/swimming.md).
- Enemies: [ai](ai.md); clips following the speed:
  [animation](animation.md); online:
  [networking](networking.md).

## Body

No spawn or camera code: `settings.mirai` has `{"Spawn_Settings":{"players":true}}`, the scene a
`spawn.Spawn_Point{prefab=PLAYER_PREFAB_ID,players=true}` entity (an `Asset_Id`), and the prefab
the pieces of [a whole player](third-person.md#2-the-player), a file of `assets/` written through
the API; a body and a camera both face -Z, so the eyes child needs no turn. For a first-person view:

```json
{"method":"scene.write","params":{"root":"Player","merge":true,"entities":[{
 "components":{"Drivable":{"move_relative_to":"Look"}},
 "children":[{"name":"Player view",
   "components":{"Camera_Follow":{"mode":"Eyes","offset":[0,1.6,0]}}}]}]}}
```

`move_relative_to` of the body's `Drivable` says what forward is for the seat: `Look` (first
person), `Camera` (a camera that orbits), `World` (seen from above), `View` (the camera may change
mode), `Game` (your code writes the `inp.Move_Input`). Turning toward the move goes at the
`turn_speed` of its `Character`.

## Walk

A walker is a `Character` and a `Walk` of the `locomotion` plugin, which the project enables
(`import locomotion "plugins:locomotion/runtime"`); it starts walking, and a game that starts it
flying or swimming asks `locomotion.set_mode`. Start from `locomotion.WALK_DEFAULT`, then set
`max_speed`, `jump_height` and the rest (`component.list` on `Walk`: sprint, air control, coyote
time, crouch). A held jump keeps rising for `jump_rise`.
**`jump_cut`** is the share of its upward speed a jump keeps when the button is let go while
rising: `0.4` lets a tap make a short hop, `1` or `0` keeps all of it, and a ledge jump is never
cut. Locomotion does the rest from the seat's actions: the game sets how fast (`max_speed`), it
does not steer by writing a velocity. A launch, such as a jump pad, works on a `Character`:
`phys.set_velocity(requests,e,v)` replaces its velocity and `phys.apply_impulse(requests,e,impulse)`
adds to it, with `requests:^phys.Body_Requests`. Flying and swimming are components too
(`locomotion.Fly`, `locomotion.Swim`).

## Pitfalls that fail silently

- A `Character` with no `Collider` is the problem `physics.character_capsule` in
  `engine.diagnostics`.
- A `Camera_Follow` owns the `Transform` of its entity; do not write it. The player sees through
  the `Drivable.camera` of the body its seat drives; `Camera.active` is only the fallback.
- A `Spawn_Point` with no `prefab` only places bodies the game gives, and one with `players` off
  never gives a seat its body: it is for enemies ([prefabs](core/prefabs.md#at-spawn-points)).
