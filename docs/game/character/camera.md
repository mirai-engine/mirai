# Camera of a player

The camera is an entity with `render.Camera` and `cam.Camera_Follow`; the body names it in
`inp.Drivable.camera`. `Camera_Follow` has no target by default: it follows the body whose
`Drivable.camera` is this entity, so one prefab works for every player.

## First person

`Camera_Follow{mode=.Eyes,offset={0,1.6,0}}` on a child of the body (the prefab of
[character](../character.md#body)), with the body's `move_relative_to=.Look`. The camera looks where
the body looks; `Camera.own_hidden` leaves the head of that body out of its view.

## Third person

```json
{"method":"scene.write","params":{"root":"Player view","merge":true,"entities":[{
 "components":{"Camera_Follow":{"mode":"Orbit","offset":[0,1.6,0],"distance":4.5,"pitch":0.3,
 "min_pitch":-0.4,"max_pitch":1.2,"aim":true}}}]}}
```

`Orbit` keeps the camera out of walls with a probe; `offset` is the pivot, over the feet; the
pitches are radians (the sign is below); `aim` makes it look where the body looks, as a shooter.

- Shooter, the body turns with the look: `aim=true` and the body's `move_relative_to=.Look`.
- Free orbit, the body turns toward its movement: `turn=true` (the player's `look` action turns
  the camera), `recenter` seconds to swing back behind a moving body, and `.Camera` on the body.
- Over the shoulder, smoothing, dead zones and fading the body up close are more fields of
  `Camera_Follow`. `.Follow` keeps `offset` from the body; `look_at` faces it.

## The sign of pitch

| Where | Positive `pitch` |
| --- | --- |
| `Orbit` `Camera_Follow.pitch` (start) | camera above the pivot, looking down |
| `Eyes` `Camera_Follow.pitch` (start) | looks up |
| `inp.Move_Input.look_pitch` | looks up |

An `aim` Orbit shows the body's look with the opposite sign: looking up lowers the Orbit's
pitch. `min_pitch` and `max_pitch` use the sign of the mode; both 0 means almost straight up and
down. Angles are radians.

## Change the view

```odin
cam.camera_mode(changes,camera,.Third_Person) // in a fixed step, changes:^cam.Camera_Changes
```

- `camera_mode(changes,camera,preset or setup,blend)`: presets `Isometric`, `Top_Down`, `Side`,
  `First_Person`, `Third_Person`, `Aim`. For a setup of your own: `setup:=cam.camera_preset(.Aim)`,
  change `setup.follow`, pass `setup`. Asking for the mode it has does nothing, so it may repeat.
- A character whose camera changes mode uses `move_relative_to=.View`.
- Aim as a second camera: a `cam.Camera_Activation` (its `action`, set in the inspector) on a
  camera that follows the same body; players see through it while they hold the action.
- `cam.camera_override(requests,owner,seat,camera)` shows another camera (a cutscene, a security
  feed) until `cam.camera_override_remove(requests,owner)`.
- `cam.camera_look(input,camera,yaw,pitch)` in `^cam.Camera_Input` turns an Orbit from code.

## Pitfalls that fail silently

- `Camera.fov` is vertical, in radians (`70*mm.RAD_PER_DEG`).
- A `Camera_Follow` that asks for a mode it cannot take is a problem of the camera
  (`camera.mode_*`): `engine.diagnostics`.
