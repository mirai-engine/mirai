# Camera of a player

The camera of a body is the entity with `render.Camera` under it (its first in the hierarchy),
with a `cam.Camera_Follow`. `Camera_Follow` has no target by default: it follows the body it hangs
from, so one prefab works for every player. What the camera does also says where the player walks:
forward is where it looks.

## First person

`Camera_Follow{mode=.Eyes,offset={0,1.6,0}}` on a child of the body (the prefab of
[character](../character.md#body)). The look action turns the body's look within `min_pitch` and
`max_pitch`, the camera looks where the body looks, and the body walks that way;
`Camera.own_hidden` leaves the head of that body out of its view.

## Third person

```json
{"method":"scene.write","params":{"root":"Player view","merge":true,"entities":[{
 "components":{"Camera_Follow":{"mode":"Orbit","offset":[0,1.6,0],"distance":4.5,"pitch":0.3,
 "min_pitch":-0.4,"max_pitch":1.2,"aim":true}}}]}}
```

`Orbit` keeps the camera out of walls with a probe; `offset` is the pivot, over the feet; the
pitches are radians (the sign is below); `aim` makes it look where the body looks, as a shooter.

- Shooter, the body turns with the look: `aim=true`.
- Free orbit, the body turns toward its movement: `turn=true` (the `look` action of the player who
  drives it turns the camera; with several players, each one's own), `recenter` seconds to swing
  back behind a moving body.
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
- Aim as a second camera: a `cam.Camera_Activation` (its `action`, set in the inspector) on a
  camera that follows the same body; players see through it while they hold the action, and
  `cam.aim(sight,body)` gives the ray of the camera they see through.
- `cam.camera_override(requests,owner,seat,camera,blend={seconds,ease})` shows another camera (a
  security feed) until `cam.camera_override_remove(requests,owner)`; asked again with another
  camera, the view cuts or blends to it. A cutscene does not call it: the markers of its clip on
  cameras are its shots ([a cutscene](../animation/props.md#a-cutscene)).
- `cam.camera_look(input,camera,yaw,pitch)` in `^cam.Camera_Input` turns an Orbit from code.

## Shake the view by keys

A swing or a landing moves the view the same way every time: a `cam.Shake_Sequence` is one track
of the keys every animation uses (`std/anim` `Keyframe`, with their ease, interpolation and
slopes), whose value is pitch, yaw, roll and the radians added to the vertical field of view.

```odin
nod:cam.Shake_Sequence
nod.keys[0]={time=0,value={}}
nod.keys[1]={time=0.08,value={0.06,0,0.02,0},ease=.Quad_Out}
nod.keys[2]={time=0.3,value={},interpolation=.Cubic}
nod.count,nod.length,nod.scale,nod.blend_out=3,0.3,1,0.1
cam.camera_shake(shakes,camera,nod) // shakes:^cam.Camera_Shakes
```

`rate`, `blend_in` and `blend_out` play it faster and fade it; `single` with an `id` restarts the
one that plays instead of adding another.

## Pitfalls that fail silently

- `Camera.fov` is vertical, in radians (`70*mm.RAD_PER_DEG`).
- A `Camera_Follow` that asks for a mode it cannot take is a problem of the camera
  (`camera.mode_*`): `engine.diagnostics`.
