# Clips on props, layers, curves and root motion

For entities that no `.match` drives: a door, a lift, a pickup, a light, a cutscene, a scripted
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

## Play, layer, seek

```odin
// animations:^core.Table(anim.Animation), requests:^anim.Animation_Requests
if a:=core.get(animations,door);a!=nil {
    anim.animation_play(a,"open",.2,loop=false)          // layer 0: cross-fades from the clip
    anim.animation_play(a,"wave",layer=1,over="@upper_body",weight=1)  // layers 1 to 3
    anim.animation_weight(a,1,.5)                        // weight of a layer, reached over its fade
    anim.animation_stop(a,1,.2)                          // fades a layer out and frees it
    a.speed=-1                                           // backwards
}
anim.animation_command(requests,door,.Play)              // from its start, in the next tick
anim.animation_command(requests,door,.Pause)             // .Resume goes on; .Stop rewinds
anim.animation_seek(requests,door,0.5)                   // jumps there, skipping markers
```

- The commands are the same for a door, a lift and a cutscene, from any step: they need no
  `^core.Table(anim.Animation)`. `Animation.playing` in the scene says whether it starts by itself,
  and a command holds until your code changes that field: a step that owns the `Animation` writes
  `a.playing` and seeks, and asks with commands only for entities it does not write;
  `anim.animation_playing(playback.ptr,door)` says what the clip does now.

- `over` names a bone (its branch) or a body region (`@upper_body`, `@arm_l`) that the skeleton
  maps; `mode=.Additive` with `reference` adds what a clip changes over a reference pose (an emote
  over a stand); `mesh_space=true` keeps an Override branch's turn whatever the base turns above.
- Layer 0 is the entity's own clip; actions use layers 1 to 3.

## Read progress, curves and markers

```odin
// playback:core.Ref(anim.Playback)
t,duration,ended,ok:=anim.animation_progress(playback.ptr,e)
glow:=anim.animation_curve(playback.ptr,e,"pulse")       // Float curve of the clip, by name
```

- `animation_vector` reads a Vector curve; `animation_bone_transform(playback.ptr,rig,bone)`
  gives a finished bone pose in the world.
- A marker the clip crosses arrives in `Animation_Events.items` (`entity`, `marker` as
  `base.name_hash`, `fraction` of the tick); for a clip that blends several, `event_policy`
  picks which markers fire. Count arrivals by a marker of the clip, not by elapsed time.
- Parameters of an `.agraph` are set by name: `anim.animation_parameter(a,"Mood",.5)`.

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
    if event.entity==intro && event.marker==base.name_hash("door_slam") {slam()}
}
```

- In a network game the server commands the clip and every client follows it.
- What the clip moved is the game's again when the clip ends.

## Root motion

`Animation.root_motion` is `Extract` (the clip's root movement is reported per tick) or `In_Place`
(reported too, and the root bone is held at its reference so the pose stays on the entity). A
`Character` whose `.action` has `body_move` is moved by the engine and the game does not convert
root motion. Any other body moves itself:

```odin
if d,ok:=anim.animation_root_delta(playback.ptr,e);ok {
    if root:=core.free(transforms,e);root!=nil {
        root.position+=mm.quat_rotate(root.rotation,d.translation*root.scale)
        root.rotation=linalg.normalize(root.rotation*d.rotation)
    }
}
```

- Run it in a `fixed` step after `animation_sample`:
  `@(step="fixed",stage="apply",after="animation_sample")`.
- A body owned by physics is never written directly: ask physics, or use `body_move`.
- A seek gives no displacement, and every source blended must share the root bone or the
  evaluation is rejected (a problem of the entity).

## Pitfalls

- `animation_play` on layer 0 keeps the entity's `loop`; pass `loop=false` for a one-shot and
  test `ended` only for a clip that does not loop.
- A clip name the asset lacks is a problem of the entity, not an error at the call.
- Changing `Animation.library` restarts the program; it replaces clips by name.
- A `.blend` as `Animation.asset` fails: it lives under an `Additive` of an `.agraph`.
