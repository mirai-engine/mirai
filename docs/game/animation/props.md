# Clips on props, curves and root motion

For entities that no `.character` drives: a door, a lift, a pickup, a light, a cutscene, a scripted
creature. `Animation.asset` may be a `.anim` (a library of clips); the field `clip` picks one. A
clip is the one way to move a value over time: there is no other keyed component.

## What a clip moves

The target of each track says what it drives, by text:

| Target | Drives |
| --- | --- |
| empty | the entity with the `Animation` |
| `Leaf` | the entity below it named `Leaf` |
| `Guard` | an entity anywhere with `Animation_Target{path="Guard", animation=<the animated one>}` |
| `Lamp/@field/Point_Light.intensity` | that field of that component of `Lamp` (`@field/...` alone: of the animated entity) |

- Position, Rotation and Scale tracks are local to the parent of what they move: put the
  `Animation` on a parent placed in the world and move its children by name, and one clip serves
  every door of the game.
- A Float track writes a number, a `bool` or a member of a bit set (from 0.5 up); a Vector track a
  vector or a color. A track that names something the game lacks is a problem of the entity.
- A clip writes only while it moves. Paused, stopped or ended it leaves what it drove where it is,
  free for the game to move.
- Make the clip with the editor API: `animation.clip.create` (`path`, `name`), then one
  `animation.track.set` per track (`target`, `property`, `keys` with `time`, `value`, `ease`,
  `interpolation`), and assign it with `animation.play`. A hold is two keys with the same value.

## Play and seek

```odin
// requests:^anim.Animation_Requests
anim.animation_command(requests,door,.Play)              // opens: from its start, in the next tick
anim.animation_command(requests,door,.Resume,speed=-1)   // closes from where it is
anim.animation_command(requests,door,.Pause)             // .Stop rewinds and waits
anim.animation_seek(requests,door,0.5)                   // jumps there, skipping markers
```

- The commands are the same for a door, a lift and a cutscene, from any step. `Animation.playing`
  and `speed` in the scene only say whether it starts by itself, and at what speed; once the world
  plays, only commands change it. `anim.animation_playing(playback.ptr,door)` says what it does now.
- Another clip of the same `.anim` is `anim.animation_clip(core.edit(animations,e),"close")`: it
  cross-fades into it from its start and plays as the last command said.
- What plays over the clip (a wave over the arm, a mix by a value, an action) is a layer or an
  action of a `.character` over that `.anim`, as for a character: [actions.md](actions.md).

## Read progress, curves and markers

```odin
// playback:core.Ref(anim.Playback)
t,duration,ended,ok:=anim.animation_progress(playback.ptr,e)
glow:=anim.animation_curve(playback.ptr,e,"pulse")       // Float curve of the clip, by name
```

- `animation_vector` reads a Vector curve; `animation_bone_transform(playback.ptr,rig,bone)`
  gives a finished bone pose in the world.
- A marker the clip crosses arrives in `Animation_Events.items` as a `Marker` event (`entity`,
  `name` as `base.name_hash`, `fraction` of the tick); for a clip that blends several,
  `event_policy` picks which markers fire. Count arrivals by a marker of the clip, not by
  elapsed time.

## A cutscene

A cinematic is a clip with shots (plugin `cinematics`, which needs `animation`): the entity with
the `Animation` also has a `Cinematic`; each camera or actor out of it has an `Animation_Target`
that names it; a `Cinematic_Shot` says from which time of the clip a camera is seen and how long it
blends in; and a `Cinematic_Viewer` on one more camera shows it to a seat, with the seat's actions
blocked (`block_mask`). The editor API builds it: `cinematics.add` with part `Timeline`, `Shot` and
`Actor`, and the animation methods for its keys.

```odin
anim.animation_command(requests,intro,.Play)             // as any clip
// cinematics:core.Read(cine.Cinematic), events:core.Ref(anim.Animation_Events)
if c,ok:=core.get(cinematics,intro);ok && c.status==.Completed {start_the_level()}
for event in events.items {
    if event.entity==intro && event.name==base.name_hash("door_slam") {slam()}  // a .Marker
}
```

- In a network game the server commands the clip and every client follows it.
- What the clip moved is the game's again when the clip ends.

## Root motion

`Animation.root_motion` is `Extract` (the clip's root movement is reported per tick) or `In_Place`
(reported too, and the root bone is held at its reference so the pose stays on the entity). A
`Character` that plays an action with `body_move` is moved by the engine and the game does not
convert root motion. Any other body moves itself:

```odin
if d,ok:=anim.animation_root_delta(playback.ptr,e);ok {
    if root:=core.free(transforms,e);root!=nil {
        root.position+=mm.quat_rotate(root.rotation,d.translation*root.scale)
        root.rotation=linalg.normalize(root.rotation*d.rotation)
    }
}
```

- Run it in a `fixed` step of the stage of `animation_sample`, `@(step="fixed",stage="apply")`:
  reading `anim.Playback` puts it after the sampling.
- A body owned by physics is never written directly: ask physics, or use `body_move`.
- A seek gives no displacement, and every source blended must share the root bone or the
  evaluation is rejected (a problem of the entity).

## Pitfalls

- `animation_clip` keeps the entity's `loop`; pass `loop=false` for a one-shot and test `ended`
  only for a clip that does not loop.
- A clip name the asset lacks is a problem of the entity, not an error at the call.
- Changing `Animation.library` restarts the locomotion of the set; it replaces clips by name.
