# Layered actions

An `.action` asset (`Animation.actions`) names actions with sections and windows, played in layers
over the body. `animation.character.setup` writes gestures; `animation.action.set` edits them.

```odin
anim.action_fire(actions,e,"Reload")                // actions:^anim.Action_Requests
anim.action_section(actions,e,"Combo","Second")     // move a playing action to a section
anim.action_cancel(actions,e,"Reload")
t,section,ok:=anim.action_playing(runtime,e,"Reload")  // runtime:core.Ref(anim.Action_Runtime)
for ev in runtime.events.items {if ev.kind==.Window_Begin && ev.window==base.name_hash("Hit") {...}}
```

Event kinds: `Started`, `Completed`, `Interrupted`, `Section`, `Window_Begin`, `Window_End`; names
arrive as `base.name_hash`. An action with a root and `body_move` moves its `Character` itself.

## Pitfalls

- `action_fire` on a layer that `animation_play` left with a clip fails (`ReservedLayer`):
  `animation_stop` frees it; weight 0 does not.
- Actions that share a layer must agree on `over`, `mode`, `curves` and root policy.
- A rejected fire is a problem of the entity (`animation.action_*`); see `engine.diagnostics`.
- Many actions with many windows in one tick overflow the event queue
  (`animation.action_events`): fire fewer or use fewer windows.
