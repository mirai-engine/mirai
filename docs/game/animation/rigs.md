# IK, feet, warping, sockets, retarget, mirror

Operations are modifiers of the `.character` the rig plays (`Animation.asset`); a rig with no
clips of its own (a rope, a tail) plays a set without clips. Game code does not edit the set: it
aims and weighs the operations it names. `animation.character.setup` writes look-at, hands and
feet; `animation.modifier.set` and `animation.inspect` part `Modifiers` edit and list the rest.
Legs and pelvis come from the skeleton body; a row names a bone only to override it.

## Aim an operation

Use `anim.look` for the head ([four calls](../animation.md#four-calls)). Use `anim.modifier`
to target a named operation or change its influence.

```odin
anim.modifier(requests,{rig=e,kind=.IK,target=anim.spatial_bone(other,"hand_r"),
    weight=1,enabled=true,goal=true},"left_hand")
anim.modifier(requests,{rig=e,kind=.IK,fade=.2},"left_hand")
```

- Build the target with `spatial_point`, `spatial_entity`, `spatial_bone` or `spatial_socket`.
  Entity, bone and socket targets follow what they name.
- A goal supplies a spatial target, spring force or grounding contact. An influence request
  adjusts weight and activation independently of the goal. A fade uses the current influence.
- For Multi IK or Spline IK goals, pass the effector or control name after the operation name.
- `animation.inspect` part `Modifiers` lists the names and reports the last request that failed.

## Feet on the ground

Grounding adapts the pose to the ground that physics queries; it needs the `physics` plugin and a
set with a grounding row. Turn it off in the air:

```odin
anim.modifier(requests,{rig=e,kind=.Grounding,weight=1 if state.standing else 0,
    enabled=true,goal=true},"grounding")
// state:phys.Character_State of the entity
```

## Warp a move to a target

A warp window of the set warps the root motion over the span of its name on the clip that plays
(a marker with a duration, written once on the clip). Give a window a target and the move ends
there, by stretching the stride and the root delta:

```odin
anim.motion_target(requests,e,"Reach",anim.spatial_point(spot))  // a warp window of the set
anim.play_clip(requests,e,"stride",.2,loop=false)
```

- The body moves by the warped delta (`body_move` on a `Character`, or the root-motion recipe in
  [props.md](props.md#root-motion)); a collision can stop it short of the target.
- A goal persists until replaced. A warp corrects what a clip nearly covers: far targets slide.

## Bones, sockets and held objects

- A held object has the `Bone_Attachment` component: `rig` (the character), `socket` (a name in
  the skeleton, `base.text_set(att.socket[:],"hand_r")`) or `bone`
  (`att.bone=anim.bone_ref("hand_r")`), and `offset`. Author sockets with `skeleton.socket.set`.
- A weapon drawn from the hip to the hand: its `Bone_Attachment` says where it rests (`"hip"`), and
  `anim.attach(requests,sword,"hand_r",0.1)` moves it to another socket of the skeleton of its rig
  over a blend of 0 to `anim.ATTACH_BLEND_MAX` (0.2 s; 0 at once), from where it was and following
  the hand as it moves; `anim.attach(requests,sword,"",0.1)` puts it back where it rests. Asking
  for where it is does nothing, so a game may ask every tick from its own state. An ability holds
  it in the hand while a window with `attach` is open through `abilities.Ability_Held`.
- `Pose_Source{rig}` on another mesh is the one way another rig drives a pose: at stage
  `Finished` (armor, a head) it shares or follows that rig's finished pose; at stage `Sampled` a
  character of other proportions plays its sampled animation by bone names, or by the
  `retarget_chains` of its set where the topology differs. Bones without a correspondence keep
  their own pose.
- A hand or foot on a contact is an IK row with a spatial target; feet on the ground are
  grounding.
- `animation_bone_transform(playback.ptr,rig,anim.bone_ref("head"))` reads a bone in the world;
  `animation_pose(requests,rig,anim.bone_ref("tail"),local)` overrides one bone's local pose.
- A bone name is a path, a unique short name, or `@hand_l`-style body part that works across
  skeletons with a saved body (`skeleton.body.detect`, `skeleton.body.set`).

## Retarget and mirror

- Clips for another skeleton: `animation.retarget.bake` writes an `.anim` for the destination by
  the same mapping as a live `Pose_Source` of stage `Sampled`, with the feet that stand locked to
  the ground; the result is a plain `.anim`. `crotch_floor` keeps the hips of a body of other
  proportions off the floor while the source crouches (both skeletons need a saved body).
- `Animation.mirror=true` swaps left and right (bone names must say the side) and reflects root
  motion; without sided names the entity plays unmirrored with the problem `animation.mirror`.

## Many characters

Far from the players a rig costs less by itself, alike on the server and on every client: the
project settings `Animation_Budget_Config` leave out its grounding, springs, twists and
correctives past `cosmetic_distance` (25 m) from every simulation source (the bodies the seats
drive and each `Streaming_Source`), and past twice `cadence_near` (20 m) pose it and search its
matching once every `distance / cadence_near` ticks, at most every `cadence_slowest` (0.25 s).
Its clock, markers, events and root motion run in every tick, and between two poses it holds the
last one. A rig that follows another (`Pose_Source`, an attached rig) is posed on the ticks of
that one. Gameplay that reads a pose gets it in full at any distance: a rig with a
`Bone_Attachment`, a bone pose asked of it, a field its curves write, or a rig a library reads
with `animation_read` in each tick (a `Ragdoll` does). A dedicated server poses only those.
`cadence_near` and `cosmetic_distance` at 0 pose every rig in full.

`Animation_Budget` (`period`, `significance`) on a rig presents its palette at most every
`period` frames. Use a larger period for distant or minor characters.

## Pitfalls

- A goal whose target entity has no transform, or whose rig did not sample last tick, leaves the
  operation unapplied for that tick without an error at the call.
- `Look`, `IK` and `Grounding` do nothing if the set of the rig holds no such operation.
- A `@part` name on a skeleton with no saved body is a problem of the entity.
