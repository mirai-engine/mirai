# Ragdolls and physical animation

The optional `ragdoll` plugin depends on `animation` and `physics`. Its Runtime
(`rag "plugins:ragdoll/runtime"`) uses the public bodies, colliders, joints and requests of
[physics](../../mirai-physics/references/engine.md); it has no other solver. Its editor part
(`plugins/ragdoll/editor`) provides the [`ragdoll.setup`](#setup-by-api) method.

## Components

- `Ragdoll` goes on the rig (start from `RAGDOLL_DEFAULT`): `Animated` (kinematic bodies that
  follow the current clip sample), `Simulated` (free dynamic), `Driven` (dynamic with pose motors)
  or `Disabled` (releases control). Zero frequency or torque disables the drives without removing
  limits or anchors.
- Each dynamic body has `Ragdoll_Bone{rig,bone,offset}`, with a rigid scale-one `offset` in the
  bone's space; colliders and masses use the normal components. A child uses `Joint.target`
  toward another body of the same ragdoll; the constraints stay active in free simulation and the
  root moves freely.
- The definitions are stored as a scene or prefab. `ragdoll_bind` binds existing bodies as a
  transaction: it validates all entries before adding components.

## Setup by API

`ragdoll.setup` builds the ragdoll of a rig from the
[skeleton body](../../mirai-animation/references/animation-authoring.md#skeleton-body)
of its `.skeleton`, like the one the demo's ragdoll station builds by hand; one that stores none
is detected in memory for the call and the `.skeleton` does not change.

- The rig is the entity with `Animation` whose `Mesh_Renderer` shows a skeletal mesh; a skin with
  `Pose_Source` leads to its rig. A body that cannot be detected, or one without a pelvis, which
  is the root, fails and the `fix` asks for `skeleton.body.set`.
- On the document, also while a game plays. It validates rig, skeleton, scale, joints and masses before writing; bodies,
  components and the rig's `Ragdoll` (from `RAGDOLL_DEFAULT`, with `mode`) enter a single undo
  step, or nothing remains. The ragdoll the rig had leaves in that same step.
- One body per part: pelvis, spine and chest (the chain between pelvis and neck split at its
  first bone and the middle one; with a single bone, chest only), head, arms, forearms, hands,
  thighs, legs and feet. Neck, clavicles and fingers have no body: they follow the animated pose
  relative to their parent.
- The bodies go at the scene root, in the rest pose under the rig's transform, centered on their
  segment toward the next part with +Y along and +X to the left of the body. The body takes the
  scale of its bone so that `Ragdoll_Bone.offset` stays rigid: a bone with non-uniform scale
  fails.
- The skeleton comes from the file of the mesh that the rig shows. `Ragdoll_Bone.bone` names the
  bone by its name if the skeleton has it only once, and otherwise by its path: the clip that the
  rig plays can come from another skeleton with other paths and the same names.
- Colliders: box in pelvis, spine, chest, hands and feet; sphere in the head; capsule in the
  limbs, or sphere if the segment is shorter than its diameter. The measurements are proportions
  of the bones' height along the body's up. `group` is the rig: the bodies do not collide with
  each other or with the rig's colliders.
- `mass` is distributed by volume; without it each body weighs like water. Each joint is `SixDOF`
  because `Driven` only moves `SixDOF` and `Spherical`: hinge (elbows and knees) limits only the
  flexion axis and locks the other two; swing-twist (shoulders, hips, neck, spine, wrists, ankles)
  limits all three. The frame's X axis goes along the child body and Y is the flexion one (elbows
  forward, knees backward); both frames are given explicitly (`auto_target` off), so they do not
  depend on where the bodies are when the joint is created.
- A rig with `Ragdoll` or with bound bodies fails unless `replace`, which removes in the same step
  the bodies whose `Ragdoll_Bone.rig` is the rig, with what hangs from them. A body that contains
  the rig, or that the scene does not let be removed (member of a prefab, another section), fails
  without changes.

## State and errors

- `Ragdoll_State` exposes the per-body error and a bone binding tied to the skeleton's revision;
  changing rig, path or revision invalidates it.
- An invalid configuration, a missing bone, a removed body or removing `Ragdoll` release the
  manipulation and the motors. On leaving `Animated`, the body keeps mass, properties and the
  kinematic velocity of the last step.
- A `Driven` child also validates the binding and offset of its parent: if its path does not
  resolve, it suspends its drives with `Missing_Bone`, without reusing the previous handle.
- `set_joint_world_rotation` converts the world orientation with the frames that physics has just
  reconciled, from the first tick; the plugin does not duplicate those frames.
- What fails is a `ragdoll.*` [problem](../../mirai-core/references/core.md#problems) of the
  body, or of the world without memory or with an invalid `Ragdoll_Settings.max_bones`.

## Order and memory

- `ragdoll_prepare` (`simulate` stage, after `animation_sample` and before `physics_prepare`) is
  the sole writer of the auxiliary rows: it creates them, takes the animated sample and queues
  movements or drives.
- After physics, `ragdoll_pose` (`react` stage, before `animation_advance`) queues the world
  physical poses, which `animation_advance` applies before sockets and skinning in the same tick.
  The plugin never writes the `animation` buffers or the body transforms.
- It resolves paths only when the binding changes. `Ragdoll_Runtime.pose` is reused between rigs
  up to `Ragdoll_Settings.max_bones`; the initial reservations are transactions and stable steps do
  not allocate.

## Verification

- `plugins/ragdoll/runtime` with `-collection:plugins=plugins`; `--release` only if a failure may depend on optimization.
- `plugins/ragdoll/editor` (no GPU), for `ragdoll.setup`:
  `ragdoll_setup_builds_a_body_and_limited_joint_per_part_of_a_humanoid_in_one_step_of_undo`,
  `ragdoll_setup_finds_a_body_the_skeleton_does_not_store_and_leaves_the_skeleton_as_it_is` and
  `ragdoll_setup_replaces_the_ragdoll_of_a_rig_in_one_step_of_undo`. In a session,
  `ragdoll.setup` on a character with a body and Simulate: it falls whole, with no bodies
  exploding.
- `plugins/animation/runtime`:
  `final_world_poses_update_skin_and_sockets_in_the_same_tick_without_stable_allocations` and
  `partial_final_world_poses_blend_once_and_do_not_stretch_a_translated_chain`.
- The ragdoll station of `scenes/physics.scene` alternates Animated, Driven and Simulated until
  the first E, which then changes the mode; interaction and graphics validation in
  [the demo](../../mirai-gameplay/references/demo.md).
