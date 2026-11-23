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
  Long imported paths keep their text in an `Animation_Path` row and bind by its hash.
- **A field**: a Float or Vector track whose target ends in `@field/<Component>.<field>`
  (`asset.animation_field_target`), after the path of its entity
  (`Lamp/@field/Point_Light.intensity`) or alone for the animated entity. The field is a path of
  `std/serial` into the component (`a.b[2]`, a member of a bit set). A Float track writes a number
  (integers round and clamp), a `bool` or a bit (from a half up); a Vector track, an array of two
  to four floats. The load of the `.anim` lists them (`host.Content_Field`) and `animation_fields`
  (`timeline.odin`) binds each to its table once per binding and writes it after
  `animation_sample`.

### Material values of a rig

A track `@field/Material_Live.<value>` is no field the fixed phase writes: it is a value of the
materials of the meshes of the rig that plays it (`skin.odin`), of slot 0, of a slot
(`@field/Material_Live.<slot>.<value>`) or of every slot (`@field/Material_Live.*.<value>`).
A Float track gives a number and a Vector track a color or a vector, as keyed: a flipbook face
steps its frames with `Step` keys, a glow ramps. `animation_skin` (render phase) writes it to the
`Material_Live` of each mesh of the rig, and of those that share its pose, over what the entity
authors; with a path before `@field` it is the mesh of that name alone. A curve that stops (weight
0) or a clip without it takes the value away, and the component with the last one; a server and a
rollback never write it. A slot past the slots of a material is the problem
`animation.material_field`, more values than the component holds `animation.material_values`.
A modular head reads the curve of the body it follows first (`rig_curve`).

Position, rotation and scale keys are local: in the space of the parent of the entity they move.
A clip that many props share goes on a parent placed in the world and moves its children by name.
The transform of an entity is driven by transform tracks, not by field tracks: the pose is written
after the fields.

A marker with a target is on the entity that target binds, as the tracks of that target are
(`animation_markers`, `animation_bound`). The library only reports it as a marker; a
[cinematic](../../mirai-gameplay/references/cinematics.md#shots-and-actions) makes one on a camera
a shot and one on another actor an action.

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

The clip commands in `Animation_Requests` own playback in Play. Set the initial clip and clock
on `Animation`. Use `play_clip` to select a clip and `animation_command` to control its clock.
Play with `restart` starts over, Resume keeps the current time, and Seek skips the markers before
the destination. Stop rewinds the base clip or releases the clip of a slot.

- A clip over matched locomotion or an additive one plays in slot 0 of the stack, one in a named
  layer in the slot of that layer (`Stack_Playing.clips`); an entity without a `.character` makes
  its stack for it, and a prop that plays its clip alone has none. Each slot plays its own clip,
  of any `.anim`, and `layers_advance` plays them all. A command without clip or layer controls
  the clips the slots play, else the base.
- An action takes its slot from the clip there, which reports Interrupted; a clip cannot take the
  slot of an action that plays (`animation.clip_layer_busy`). Named actions keep their priority
  rules.
- A one-shot with `next_clip` starts that clip from the same source on the tick after it ends; an
  action's `next_clip` plays in its slot, each slot its own, so actions that end in one tick
  chain all of theirs.
- Raw clips report Started, Ended and Interrupted in the same queue as their markers, each slot
  its own (`group` is 1 + the slot). Events name the original clip and .anim even in a joined
  library. The action hash is present for named actions.
- `Animation_Progress` preserves the base clip, clock and time in a save. The editor takes Seek
  for its preview, and Play starts from the component or saved progress.

## Verification

- `std/anim`: `a_keyed_value_is_evaluated_one_way` (every interpolation, ease and loop, hostile
  keys).
- `plugins/animation/runtime`:
  `a_clip_drives_the_transforms_and_the_fields_it_is_bound_to_while_it_moves`,
  `a_field_target_names_its_entity_component_and_field`,
  `material_live_curves_give_the_meshes_of_a_rig_their_look_in_the_render_phase`,
  `a_material_live_field_names_a_slot_and_a_value`,
  `an_additive_clip_over_an_entity_without_a_character_plays_in_the_first_slot_of_its_stack` and
  `each_slot_of_a_stack_plays_its_own_clip_or_action`.
- `plugins/cinematics/runtime`:
  `the_markers_of_a_clip_cut_between_cameras_and_play_actions_while_it_plays`.
