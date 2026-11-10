# Timelines

A timeline is the clip of an `Animation`: the one way to move a value over time. A door, a lift, a
light that dims and the cameras and actors of a
[cinematic](../../mirai-gameplay/references/cinematics.md) are all an `.anim` whose tracks hold the
keys of [std/anim](../../mirai-std/references/anim.md#tracks-keys-and-clips-trackodin-clipodin).
There is no other keyed component, and interfaces play the same keys on their nodes
([ui](../../mirai-ui/references/ui.md)).

## What a track drives

On an entity that poses no skeleton, each track of the clip is bound by the text of its target
(`bind`, `anim.odin`):

- **No target**: the entity that has the `Animation`.
- **A name**: the entity below it with that `Name`, or with that path in its `Animation_Target`
  (what an importer gives a rigid node).
- **An entity anywhere**: one whose `Animation_Target.animation` names the animated entity, called
  by its `path` (its `Name` when the path is empty). The reference is an `Entity` field: scenes,
  prefabs and saves remap it. An entity has one `Animation_Target`: one clip moves it.
- **A field**: a Float or Vector track whose target ends in `@field/<Component>.<field>`
  (`asset.animation_field_target`), after the path of its entity
  (`Lamp/@field/Point_Light.intensity`) or alone for the animated entity. The field is a path of
  `std/serial` into the component (`a.b[2]`, a member of a bit set). A Float track writes a number
  (integers round and clamp), a `bool` or a bit (from a half up); a Vector track, an array of two
  to four floats. The load of the `.anim` lists them (`host.Content_Field`) and `animation_fields`
  (`timeline.odin`) binds each to its table once per binding and writes it after
  `animation_sample`.

Position, rotation and scale keys are local: in the space of the parent of the entity they move.
A clip that many props share goes on a parent placed in the world and moves its children by name.
The transform of an entity is driven by transform tracks, not by field tracks: the pose is written
after the fields.

## When it writes

- A clip writes what it drives on the ticks it moves: while it plays, when it is sought, when its
  weight changes, while it fades or a layer plays, and on the tick it starts. A clip that does not
  move (paused, stopped, ended) writes nothing: what it moved stays where it left it, for whoever
  else moves it. A rig always poses its skeleton.
- A value equal to the one the entity has is not written.
- An entity whose `Transform` another component owns (a body) is not written: the place the track
  gives it, in the world, is asked of its owner through
  [`core.Places`](../../mirai-core/references/core.md#requested-places), which a physics body takes
  as a teleport. A platform that carries characters still moves with `phys.move_kinematic`.
- What a field track cannot write (no such entity, component or field, or a field a track of its
  kind does not write) is a problem of the animated entity (`animation.field_*`) and is left out.

## Commands

`Animation_Requests.timeline` is the one queue that plays, pauses, resumes, stops, reverses and
seeks a clip: `animation_command(requests, entity, command, time, speed)` and `animation_seek`.
`animation_sample` takes them. `Play` starts from the start (the end, backwards) at `speed`;
`Resume` goes on at `speed` from where it is; `Stop` returns to the start and waits; `Seek` jumps
without firing the markers it skips.

- `Animation.playing` and `speed` say only how the clip starts when its entity starts to play;
  from then on its playback keeps whether it plays and at what speed, and only commands change
  them. `animation_playing` says what the clip does, and `Animation_Progress` keeps time, speed and
  whether it plays for a saved game, which `progress_resume` asks back with commands.
- The editor, which does not play, takes only `Seek`: its previews seek.
- A command for an entity that plays nothing is the problem `animation.command`.

## Verification

- `std/anim`: `a_keyed_value_is_evaluated_one_way` (every interpolation, ease and loop, hostile
  keys).
- `plugins/animation/runtime`:
  `a_clip_drives_the_transforms_and_the_fields_it_is_bound_to_while_it_moves`,
  `a_field_target_names_its_entity_component_and_field`.
- `plugins/cinematics/runtime`: `a_viewer_shows_the_shots_of_a_clip_while_it_plays`.
