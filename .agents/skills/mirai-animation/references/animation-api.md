# Animation API methods

`animation.*` and `skeleton.*` live in `plugins/animation/editor` (`animation.capture` in
`previews`). Schemas: `mirai rpc describe animation.` / `skeleton.`. Flows:
[animation-authoring.md](animation-authoring.md); general API rules:
[methods.md](../../mirai-agent-api/references/methods.md).

- **Intent layer:** `skeleton.body.detect/set`, `animation.character.setup`, `animation.request`,
  `animation.clip.edit`, `animation.analyze`.
- **Verification layer:** `animation.inspect` (`Match`/`Pose`/`Actions`), `animation.history`,
  `animation.asset.inspect`, isolated `animation.preview`/`animation.capture`, and real-Play
  `capture` filmstrips (`debug: ["Skeleton","Bounds","Collision","Trajectory"]`).
- **Expert layer:** `animation.clip.*`, `track.set`, `key.set`, `key.capture`, `marker.set`,
  `skeleton.*`, `animation.action.set`, `space.set`, `motion.set`, `modifier.set`, `pose.bake`,
  `retarget.bake`, morphs and [timelines](animation-timeline.md).

```bash
# Analyze clip issues + get fix verbs, preview isolated, then inspect real Play pose & matching
mirai rpc --project . animation.analyze '{"asset":"anims/hero.anim","clip":"walk"}'
mirai rpc --project . animation.capture '{"entity":"Player","seconds":1.0,"frames":6}'
mirai rpc --project . animation.inspect '{"entity":"Player","parts":["Match","Pose"]}'
mirai rpc --project . animation.history '{"entity":"Player","from":0,"to":60,"every":5}'
```

## Common errors

- Requesting parameters, targets, actions or intents in Edit -> requires Play/Simulate (`fix`
  suggests `animation.preview`).
- Using `animation.capture` to debug physics/grounding -> it is an isolated preview without physics
  or world collision; use `capture` filmstrips (`debug`) in Play instead.
- Expecting disk writes mid-call -> assets flush at step end.
- Passing numeric indices/slots/counts -> API uses names and derives counts from lists.
- Expecting `locomote` to move the body -> the physics/game controller moves it.
- Looking for FSMs, graphs or transitions -> use `.character` motion matching, layers and actions
  ([what replaces the FSM](animation.md#what-replaces-the-state-machine)).
- Playing a match clip via `actions` -> add an action entry via `animation.action.set` first.
- Putting section/window seconds in `.character` -> author timed markers (`animation.marker.set`
  with `duration`) on the clip and reference by name.
- Exceeding `animation.track.set` capacity -> use `animation.key.set` per key.
- `Capacity` in `animation.character.setup` -> pass `clips` subset; test edits with `dry_run:true`.
- Copying clips between same-skeleton `.anim` libraries -> call `animation.clip.edit` with empty
  `edits` and target `path` instead of reimporting.
