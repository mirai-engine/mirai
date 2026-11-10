# The action set: layers and actions

An `.action` asset (`Animation.actions`) is what plays over the base of an entity, its `.match` or
its clip. It has a stack of **layers**, in order, and the **actions** `anim.play` asks for by name.
`animation.character.setup` writes gestures; `animation.action.set` writes any set (its `layers`
and `actions` rows say every field), and `animation.inspect` part `Actions` shows what plays.

- A layer plays by itself a clip, or the `space` of a `.blend` (aim offsets, additive poses),
  over a branch (`over`: a bone or `@upper_body`, `@arm_l`) or the whole pose, replacing
  (`Override`) or adding (`Additive`) over the layers before it.
- `anim.set(requests,e,"<layer name>",w)` is its weight; `anim.set(requests,e,"<axis name>",v)`
  moves the place its space is sampled at. Two clips mixed by a value are a layer whose weight
  is that value.
- An action plays its clip once in its `layer`, crossfading over what the layer plays, or over
  the whole body when it names none. It ends at `exit` (a share of its clip), at `exit_marker`,
  or with its last section; `entry` says where it starts.

```odin
anim.play(requests,e,"Combo")              // from its first section
anim.play(requests,e,"Combo","Second")     // while it plays: moves it to that section
t,section,ok:=anim.action_playing(runtime,e,"Combo")  // runtime:core.Ref(anim.Action_Runtime)
```

Sections chain parts of the clip (`next`); windows are named spans of it that arrive as
`Span_Begin` and `Span_End` events, `name` the window ([events](../animation.md#one-event-loop)).

## Pitfalls

- A parameter that names no layer and no axis of the set is a problem of the entity
  (`animation.parameter`).
- An action with `root_motion` takes the whole body, or an `Override` layer without `over`.
- Many actions with many windows in one tick overflow the event queue
  (`animation.events_lost`): play fewer or use fewer windows.
