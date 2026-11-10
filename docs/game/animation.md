---
name: animation
description: Animate characters and objects from game code - locomotion by motion matching, play
  and stop actions, aim offsets and layer weights by name, look-at, one event loop, root motion,
  clips on props, IK, retarget, mirror.
---

# Game animation

Add `"animation"` to `plugins` in `project.mirai`; `animation_physics` (automatic with `physics`)
feeds each `Character`. Import `anim "plugins:animation/runtime"`. Animation is data on an entity
plus requests queued from a `fixed` step; what is invalid or full shows in `engine.diagnostics`.

## Map

- Walk, jump, swim, fall: [Locomotion](#locomotion).
- Vault, hit, death, reload, wave, aim, look, and reacting to them: [Four calls](#four-calls)
  and [One event loop](#one-event-loop).
- The action set, its layers, sections and windows: [actions.md](animation/actions.md).
- A door, a lift or a light moved by a clip, a cutscene with cameras and shots, curves, root
  motion of a body that is not a `Character`: [props.md](animation/props.md).
- IK, feet on the ground, warp to a target, held objects, retarget, mirror, distant characters:
  [rigs.md](animation/rigs.md). Importing clips: [assets](assets.md); AI: [ai](ai.md).

## Locomotion

An entity with `Character`, a mesh with a skeleton and `Animation.asset` set to a `.match` walks,
jumps and swims with no game code: physics tells the match the mode and velocity.
`animation.character.setup` (editor API) writes it from the clip names (idle, walk, run, sprint,
fall, jump, land, swim); check it with `animation.inspect` part `Match`. The game sets how fast
the body goes (`Walk.max_speed`), never which clip plays: a faster gait is a higher speed.
Without a `Character` (a scripted walker) a `fixed` step tells the match what the body does,
velocity in world axes and m/s (the model faces -Z):

```odin
anim.match_goal(requests,{rig=e,mode=u16(locomotion.MODE_WALKING), // ^anim.Animation_Requests
    velocity=w.velocity,desired=w.velocity,facing=w.facing})
```

## Four calls

Everything a character does over its locomotion goes through `^anim.Animation_Requests`, by the
names its action set (`Animation.actions`, an `.action`) gives its actions and layers. There are
no states, transitions, triggers, graphs or locomotion blend spaces.

```odin
anim.play(requests,e,"Vault")              // an action: a clip once, in its layer or whole body
anim.stop(requests,e,"Reload")             // ends it early, as its cancel policy allows
anim.set(requests,e,"aim_yaw",yaw)         // an axis of an aim space, or the weight of a layer
anim.look(requests,e,anim.spatial_entity(target))   // the head turns to it; weight 0 lets go
```

- An action without a layer takes the whole body: over a `.match` it leaves the search and comes
  back by an inertial blend, in any locomotion mode. One in a layer plays over a part of the body
  while it walks. With `root_motion` and `body_move` its clip moves the `Character` (a lunge).
- `set` stays until set again; past the range of an axis it is the end of the range.
- `look` needs a `Look` in the pose profile (`animation.character.setup` writes one).

## One event loop

React to results, not to a state, in a `fixed` step:

```odin
for ev in events.items {                   // events:core.Ref(anim.Animation_Events)
    switch ev.kind {                       // ev.entity: whose
    case .Marker: if ev.name==base.name_hash("hit") {...}        // a marker of a clip
    case .Started,.Section,.Span_Begin,.Span_End:                // ev.action, ev.name
    case .Ended: if ev.action==base.name_hash("Death") {...}     // it played to its end
    case .Interrupted:                                           // stopped, or replaced
    }
}
```

## Pitfalls

- With a `Character`, never call `match_goal`: physics does.
- A `play` of lower priority than the action in its slot, or over one that does not allow it, is
  refused (`animation.action_busy`); wait for its `Ended`.
- Events live one tick; compare names by hash. A rejected request is a problem (`animation.*`).
- Edits made through the API stay unsaved until `asset.save`.
