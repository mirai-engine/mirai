# IK, feet, warping, sockets, retarget, mirror

Operations are modifiers of the `.character` the rig plays (`Animation.asset`); a rig with no
clips of its own (a rope, a tail) plays a set without clips. Game code does not edit the set: it
aims and weighs the operations it names. `animation.character.setup` writes look-at, hands and
feet; `animation.modifier.set` and `animation.inspect` part `Modifiers` edit and list the rest.
Legs and pelvis come from the skeleton body; a row names a bone only to override it.

## Aim an operation

To look at something, `anim.look` is enough ([four calls](../animation.md#four-calls)). The
other operations take a goal:

```odin
// requests:^anim.Animation_Requests
anim.modifier_goal(requests,{rig=e,kind=.IK,target=anim.spatial_bone(other,"hand_r"),weight=1,
    enabled=true})
anim.modifier_control(requests,{rig=e,kind=.IK,weight=0,enabled=false,fade=.2})  // fade out
```

- `target` builders: `spatial_point(p)`, `spatial_entity(entity)`, `spatial_bone(rig,"bone")`,
  `spatial_socket(rig,"socket")`; each takes an optional offset transform. An `Entity` target
  follows its entity; a point must be sent again when it moves.
- `kind` is one of `Modifier_Kind` (`IK`, `Look`, `Grounding`, `Chain_IK`, `Spline_IK`, `Spring`,
  `Follow`, ...). `slot` indexes the operations of that kind (0 is the first); `name` picks
  one instead (`base.text_set(goal.name[:],"left_hand")`); `effector` picks one of a `Multi_IK`.
- `modifier_goal` sets where; `modifier_control` sets an independent weight and fade. Both persist
  per operation until replaced.
- `animation.inspect` part `Modifiers` lists the operations and the last request that failed.

## Feet on the ground

Grounding adapts the pose to the ground that physics queries; it needs the `physics` plugin and a
set with a grounding row. Turn it off in the air:

```odin
anim.modifier_goal(requests,{rig=e,kind=.Grounding,weight=1 if state.standing else 0,enabled=true})
// state:phys.Character_State of the entity
```

## Warp a move to a target

A warp window of the set warps the root motion over the span of its name on the clip that plays
(a marker with a duration, written once on the clip). Give a window a target and the move ends
there, by stretching the stride and the root delta:

```odin
anim.motion_target(requests,e,"Reach",anim.spatial_point(spot))  // a warp window of the set
anim.animation_clip(a,"stride",.2,loop=false)
```

- The body moves by the warped delta (`body_move` on a `Character`, or the root-motion recipe in
  [props.md](props.md#root-motion)); a collision can stop it short of the target.
- A goal persists until replaced. A warp corrects what a clip nearly covers: far targets slide.

## Bones, sockets and held objects

- A held object has the `Bone_Attachment` component: `rig` (the character), `socket` (a name in
  the skeleton, `base.text_set(att.socket[:],"hand_r")`) and `offset`. Sockets are authored with
  `skeleton.socket.set`.
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
  the same mapping as a live `Pose_Source` of stage `Sampled`; the result is a plain `.anim`.
- `Animation.mirror=true` swaps left and right (bone names must say the side) and reflects root
  motion; without sided names the entity plays unmirrored with the problem `animation.mirror`.

## Many characters

`Animation_Budget` (`period`, `significance`, `enabled`) on a rig presents its palette every
`period` frames: simulation and events still run every tick. Use a larger period for distant
or minor characters.

## Pitfalls

- A goal whose target entity has no transform, or whose rig did not sample last tick, leaves the
  operation unapplied for that tick without an error at the call.
- `Look`, `IK` and `Grounding` do nothing if the set of the rig holds no such operation.
- A `@part` name on a skeleton with no saved body is a problem of the entity.
