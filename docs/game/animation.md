---
name: animation
description: Animate characters and objects from game code - play clips, locomotion by motion
  matching, whole-body moves, layered actions, root motion, events, IK, look-at, retarget, mirror.
---

# Game animation

Add `"animation"` to `plugins` in `project.mirai`; `animation_physics` (automatic with `physics`)
feeds each `Character`. Import `anim "plugins:animation/runtime"`. Animation is data on an entity
plus requests queued from a `fixed` step; what is invalid or full shows in `engine.diagnostics`.

## Map

- Walk, jump, swim, fall: [Locomotion](#locomotion).
- Vault, hit received, death, emote (whole body): [Whole-body moves](#whole-body-moves).
- Reload, wave, swing while walking (part of the body): [actions.md](animation/actions.md).
- A door or prop that plays a clip, layers, curves, root motion of a body that is not a
  `Character`: [props.md](animation/props.md).
- IK, look-at, feet on the ground, warp to a target, held objects, retarget, mirror, distant
  characters: [rigs.md](animation/rigs.md).
- Importing clips: [assets](assets.md); AI: [ai](ai.md).

## Locomotion

An entity with `Character`, a mesh with a skeleton and `Animation.asset` set to a `.match` walks,
jumps and swims with no game code: physics tells the match the mode and velocity.
`animation.character.setup` (editor API) writes it from the clip names (idle, walk, run, sprint,
fall, jump, land, swim); check it with `animation.inspect` part `Match`. The game sets how fast
the body goes (`Walk.max_speed`), never which clip plays: a faster gait is a higher speed.
Without a `Character` (a scripted walker) the step tells the match what the body does:

```odin
@(step="fixed",before="animation_sample")
walkers :: proc(items:core.Read(Walker),requests:^anim.Animation_Requests) {
    for row in 0..<core.count(items) {
        w:=core.at(items,row)   // velocity in world axes, m/s; the model faces -Z
        anim.match_goal(requests,{rig=core.entity_at(items,row),mode=u16(phys.MODE_WALKING),
            velocity=w.velocity,desired=w.velocity,facing=w.facing})
    }
}
```

## Whole-body moves

`match_play` plays a clip of the match's library, then gives the body back to the match.

```odin
opts:=anim.MATCH_PLAY_OPTIONS_DEFAULT   // fade .15, returns at the end (phase 1)
opts.priority=2                         // a higher priority beats a lower one
anim.match_play(requests,e,"death",u16(phys.MODE_WALKING),opts)
anim.match_stop(requests,e)             // gives the body back early
```

Options also take `marker`, `phase`, `entry` and `wait`. React to results, not to a state, in a
`fixed` step after `animation_sample`:

```odin
for play in events.plays.items {        // events:core.Ref(anim.Animation_Events)
    if play.entity==e && play.kind==.Finished && play.clip==base.name_hash("death") {...}
}
for m in events.items {if m.entity==e && m.marker==base.name_hash("hit") {...}} // clip markers
```

## No state machines

There are no states, transitions, triggers or locomotion blend spaces: the mode comes from
physics, the clip from the match search, moments from `match_play`, partial moves from actions;
aim offsets and additives are a `.blend` under an `Additive` of an `.agraph`.

## Pitfalls

- A literal for `match_play` options drops the defaults (`phase` 0: the clip ends at once): copy
  `MATCH_PLAY_OPTIONS_DEFAULT` and change fields.
- With a `Character`, never call `match_goal`: physics does. A lower `priority` than the move
  playing is refused (`animation.match_busy`); use `wait`.
- Events live one tick: read them in a `fixed` step; compare names by hash. Rejected requests
  are problems of the entity (`animation.*`): see `engine.diagnostics`.
- Edits made through the API stay unsaved until `asset.save`.
