# IK, look-at, feet, warping, sockets, retarget, mirror

Operations live in a `.pose` profile that the rig activates with the `Pose_Modifiers` component
(`profile`, `weight`, `enabled`). Game code does not edit the profile: it aims and weighs the
operations it names. `animation.character.setup` writes look-at, hands and feet; `pose.profile.set`
and `animation.inspect` part `Modifiers` list and edit the rest.

## Aim an operation

```odin
// goals:^anim.Modifier_Requests
anim.modifier_goal(goals,{rig=e,kind=.Look,target=anim.spatial_entity(player),weight=1,
    enabled=true})
anim.modifier_goal(goals,{rig=e,kind=.IK,target=anim.spatial_bone(other,"hand_r"),weight=1,
    enabled=true})
anim.modifier_control(goals,{rig=e,kind=.IK,weight=0,enabled=false,fade=.2})  // fade out
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
profile with a grounding table. Turn it off in the air:

```odin
anim.modifier_goal(goals,{rig=e,kind=.Grounding,weight=1 if state.standing else 0,enabled=true})
// state:phys.Character_State of the entity
```

## Warp a move to a target

A `.motion` asset (`Animation.motion`) names windows over a clip's root motion. Give a window a
target and the move ends there, by stretching the stride and the root delta:

```odin
// motion:^anim.Motion_Requests
anim.motion_target(motion,e,"Reach",anim.spatial_point(spot))  // window name of the .motion
anim.animation_play(a,"stride",.2,loop=false)
```

- The body moves by the warped delta (`body_move` on a `Character`, or the root-motion recipe in
  [props.md](props.md#root-motion)); a collision can stop it short of the target.
- A goal persists until replaced. A warp corrects what a clip nearly covers: far targets slide.

## Bones, sockets and held objects

- A held object has the `Bone_Attachment` component: `rig` (the character), `socket` (a name in
  the skeleton, `base.text_set(att.socket[:],"hand_r")`) and `offset`. Sockets are authored with
  `skeleton.socket.set`.
- `Pose_Source{rig}` on another mesh (a head, armor) shares or follows that rig's finished pose.
- `animation_bone_transform(playback.ptr,rig,anim.bone_ref("head"))` reads a bone in the world;
  `animation_pose(requests,rig,anim.bone_ref("tail"),local)` overrides one bone's local pose.
- A bone name is a path, a unique short name, or `@hand_l`-style body part that works across
  skeletons with a saved body (`skeleton.body.detect`, `skeleton.body.set`).

## Retarget and mirror

- Clips for another skeleton: `animation.retarget.bake` writes an `.anim` for the destination from
  a `.pose` profile; the result is a plain `.anim`.
- Live: set `Animation.source` (the source rig's entity) and `Animation.retarget` (a `.pose`);
  bones without a correspondence keep their rest pose.
- `Animation.mirror=true` swaps left and right (bone names must say the side) and reflects root
  motion; without sided names the entity plays unmirrored with the problem `animation.mirror`.

## Many characters

`Animation_Budget` (`period`, `significance`, `enabled`) on a rig presents its palette every
`period` frames: simulation and events still run every tick. Use a larger period for distant
or minor characters.

## Pitfalls

- A goal whose target entity has no transform, or whose rig did not sample last tick, leaves the
  operation unapplied for that tick without an error at the call.
- `Look`, `IK` and `Grounding` do nothing if the rig has no `Pose_Modifiers` with a profile that
  holds that operation.
- A `@part` name on a skeleton with no saved body is a problem of the entity.
