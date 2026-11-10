# Clips on props, curves and root motion

For entities that no `.match` drives: a door, a lift, a pickup, a scripted creature.
`Animation.asset` may be a `.anim` (a library of clips); the field `clip` picks one.

## Play and seek

```odin
// animations:^core.Table(anim.Animation), requests:^anim.Animation_Requests
if a:=core.get(animations,door);a!=nil {
    anim.animation_clip(a,"open",.2,loop=false)          // cross-fades from the clip it played
    a.playing=false                                      // pause; speed < 0 plays backwards
}
anim.animation_seek(requests,door,0)                     // next tick, skipping markers
```

What plays over the clip (a wave over the arm, a mix by a value, an action) is a layer or an
action of an action set, as for a character: [actions.md](actions.md).

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
- Changing `Animation.library` restarts the `.match`; it replaces clips by name.
- A `.blend` as `Animation.asset` fails: it is the `space` of a layer of an action set.
