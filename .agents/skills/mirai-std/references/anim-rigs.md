# Skeletal chains and modifiers

Extends [std/anim](anim.md) with procedures without ECS or allocations: the caller delivers poses,
prepared indices and all the buffers, with the common TRS composition. A failure returns `false` and
partial outputs are discarded. The operations validate the definition on entry; their internal
recompositions use `pose_world`, which validates parents and current transforms without walking
names or the reference again.

## Retarget between chains

- `skeleton_chain` resolves a `root`→`end` chain of parent-child indices into a caller buffer,
  shared by the runtime bind and the editor bake. A nonexistent path, a one-bone chain or
  insufficient capacity fail.
- `chain_retarget_prepare` receives both skeletons, their chains and their global reference poses,
  and prepares each destination bone by the normalized accumulated rest distance: it interpolates
  the orientation between two source bones and keeps the offset of the destination reference. The
  chains may have a different number of bones, all of positive length.
- `chain_retarget_pose` applies those correspondences over the destination local pose: it keeps
  translations and scales, converts each orientation with respect to the current parent and blends
  by weight; bones outside the chain stay as they were. The caller removes the external placement of
  the actor when preparing and when sampling the source. Contact targets are applied afterwards with
  IK.

## IK with several targets

`multi_ik` solves several effectors over a tree with iterative CCD and optional root correction,
without clips or an assumed human rig.

- `Multi_IK.root` delimits the subtree: `Fixed` keeps its translation and `Translate` lets it move
  up to `max_root_translation`. A stiffness of one prevents the correction.
- Only the enumerated joints rotate; each may have a preferred orientation (a bias before each pass)
  and a swing/twist limit relative to the rest. The orientation of an effector respects the limit
  and the stiffness of its bone if it is enumerated.
- The result gives the largest position residual, the largest angular error, the iterations, one
  residual per effector and `reached`, which requires both tolerances. An incompatible target gives
  a valid solution with `reached=false`; it is not a physical solver nor does it guarantee global
  convergence.
- The membership of each effector in the subtree is checked on entry; the walk ends at the root and
  preserves its ancestors and the siblings of the subtree.

## Springs

- `spring_chain_update` integrates with damped Verlet (force, gravity and attraction to the animated
  pose) and then projects lengths, bend limits and spherical collisions; the root stays anchored to
  the first animated point.
- `max_step` splits the dt into substeps, with a cap; an input that exceeds it fails.
  `reset_distance` resets the chain on a root jump, and the initial evaluation or one after a
  teleport reports `reset`. `dt=0` initializes or queries without simulating.
- `Spring_Result.residual` is the length error after the collisions: incompatible constraints leave
  it nonzero.
- The state is plain and is copied for replay; collisions, points and forces go in the same global
  space. `skeleton_chain_from_points` passes the simulated shape to rotations of the chain, keeping
  local translations, lengths and the global orientation of the end.

## Twist distribution

- `twist_angle` extracts the local twist with respect to a reference and an axis (a null axis
  fails).
- `skeleton_twist` distributes that twist over a chain different from the source with non-negative
  weights that are normalized: each bone takes the accumulated fraction in global space,
  compensating the twist of its parent. The source keeps its pose and cannot be in the chain; local
  translations and scales are kept.

## Reach, spline, aiming and pose samples (`rig_shapes.odin`)

- `chain_reach` adjusts the target and the scale of a chain: past the extension minus
  `soft_distance`, the reach approaches the extension with a smooth curve instead of stopping dead,
  and what is missing is covered by stretching up to `max_stretch`. `skeleton_chain_ik(..., reach)`
  and `two_bone_ik(..., reach)` apply it and put the stretch in the local translations: one reach
  for every chain, so a leg near full extension does not snap its knee.
- `spline_chain` puts the points of the chain on a cubic Bézier (`SPLINE_SEGMENTS` segments) and
  continues straight if the curve ends; `skeleton_spline_ik` orients each bone toward the next,
  keeps `up` and distributes `twist` by distance.
- `aim_at` is `look_at` that also turns the `up` axis toward `world_up` around the line from the
  bone to where its ray passes, which keeps an offset ray on the target.
- `pose_sample_weights` weighs rotation samples by angular closeness (inverse of the square,
  normalized; an exact sample weighs 1) and rejects repeated or non-unit samples.

## Verification

- `mirai test std/anim` with the affected cases of `rigs_test.odin` and `rig_shapes_test.odin`.
- The hostile rig cases are repeated with `ANIM_RIG_HOSTILE_ROUNDS=20000` after changing validation
  or memory.
- `multi_ik_validates_reference_and_current_pose_before_iterating_without_joint_corrections`: the
  solver rejects an invalid reference, current pose and actor transform even without joints.
- The integration and the stable allocations are verified in
  [plugin rigs](../../mirai-animation/references/animation-rigs.md).
