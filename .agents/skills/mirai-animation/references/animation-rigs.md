# Rigs and chain modifiers

The tables `chain_ik`, `twist`, `springs`, `multi_ik`, `retarget_chains`, `spline_ik`,
`correctives`, `follow`, `curve_poses`, `curve_drives` and `curve_materials` extend the [modifiers
of the `.character`](animation.md#components-and-shared-data): they are rows of a shared definition,
without components per operation. A `.character` of another `CHARACTER_VERSION` is rejected and
written again. Math: [std/anim](../../mirai-std/references/anim-rigs.md).

Each row has a name, a weight and an activation; the name is unique in its table and is what an
instance controls and inspects. The defaults are the `*_DEFAULT` constants of each type; bones are
named with `Bone_Ref`.

## Spatial targets

`Spatial_Target` is the target of IK, Look, Chain IK, each effector of Multi IK, each control of
Spline IK, Follow and each [warping](animation-motion.md#requests-and-order) window; there is no
other way to name it.

- `kind`: `World`, `Entity` (in the space of `entity`), `Bone` (a bone of the rig `entity`) or
  `Socket` (a socket of its skeleton), with position, rotation and scale in that space.
- The set stores kind, bone or socket and transformation; the entity belongs to the instance and
  arrives with the target. A set accepts `Entity`, `Bone` and `Socket` without an entity; an
  instance needs one (`spatial_target_valid`). `spatial_point`, `spatial_entity`, `spatial_bone`,
  etc. build them.
- Bone and socket read the pose that their rig sampled in this tick (`Playing.sampled`; the warping,
  that of the previous one), with the root in the world of its entity. The path to the bone is
  resolved once per bind and skeleton; sampling afterwards does not allocate.
- A target that is not found (entity without a transform, unsampled rig, bone or socket that the
  skeleton does not have) leaves the operation unapplied that tick and remains as `Missing_Target`
  in `modifier_request_error`.

## Operations

- **Chain IK**: FABRIK from `root` to `end`, with pole, iterations, tolerance, flexion limits and
  reach: `soft_distance` smooths the arrival at full extension and `max_stretch` allows stretching
  those meters, distributed by the weight of each bone.
- **Spline IK**: the chain over a cubic Bézier of four targets, with `up` as the axis it keeps and
  `twist` distributed. With all controls `World`, the profile checks that the curve has length; if
  it is shorter than the chain, the chain continues straight and the residual remains in `end`.
- **Corrective**: rotation samples of the `driver` bone (that of the animation, before the other
  operations), weighted by the inverse of the square of the angular distance. Each gives a delta of
  `bone` (with `apply_pose`) and a value that is added to the Float curve `curve`: it moves the
  morph target of that name of the rig's mesh ([morphs](animation-morphs.md)) and is read with
  `animation_corrective_curve`. Two samples of the same rotation are rejected.
- **Follow**: takes a bone to its target in position, rotation and scale (each optional); with
  `keep_world`, when the target changes it keeps the place of the bone as an offset, without jumps.
- **Twist**: distributes the animated twist of a source, outside the chain, among the bones of the
  chain; without quantities it distributes uniformly and, with them, one per bone.
- **Spring**: Verlet with explicit spherical collisions in the evaluation space; pose and force
  arrive as data, without querying physics. It resets when the bind or configuration changes, when
  deactivated, when reaching zero weight or when passing the teleport distance.
- **Multi IK**: a subtree with joints (stiffness, preferred pose, limits) and named effectors with
  independent weights of position and rotation. The root is resolved by name, not as an index of a
  skeleton, and its translation is `Fixed` or `Translate`. It diagnoses residual, angular error and
  convergence.
- **Chain Retarget**: pairs of semantic chains of the destination's set, applied to the sampled
  pose its `Pose_Source` of stage `Sampled` takes, where the bone names do not pair. It admits
  different topologies, keeps translations and scale of the destination and separates the
  placement of both actors.

## Curve poses and drives

The face of a character is poses that Float curves weigh, as a pose asset of other engines, over
its body animation; no solver evaluates it.

- **Curve pose**: a row per bone of a pose (`curve`, `bone`, `delta`): at the value of its curve,
  from 0 to 1, the bone moves by `delta` over its pose, in the space of its parent with its scale a
  factor. With `full` the row is the transform of the bone itself: the full poses of a bone blend by
  their weights, normalized past 1 so that only they count, before the additive ones (a pose library
  of hands or props). The additive poses of a bone are summed (rotations by their logarithms) and
  applied once, so the order of the rows does not change the pose. A curve can name a pose, a
  phoneme or a corrective; `animation.modifier.poses` makes the rows from the frames of a clip.
- **Curve drive**: `to` receives what it reads of `from` (with `combine`, the product, least or
  most of `from` and `with`: a combination shape that two curves bring together), times `scale`
  plus `offset`, clamped to `low`..`high` with `clamp`; `mode` adds it, replaces the curve or keeps
  the most, and `weight` blends from the curve before. Rows apply in order: the 52 curves of a
  face capture (ARKit) become the curves of the poses of a face, and a curve named
  as a morph target of the mesh moves it ([morphs](animation-morphs.md)). There are no free
  expressions.
- The curves come from the animation of the rig (clips, layers, actions, programs) and, in a
  follower, from its [leader](animation.md#following-a-rig-of-another-skeleton). The drives make
  the final curves of the rig (`Playing.driven`), which lookups and morphs read; the poses move the
  bones before the other operations of the profile.
- The final curves of a rig are laid out once, when its curves, its leader's, its profile or its
  skeleton change: its own, its leader's and those its drives write, each once in `curve_order`
  (name hash, property, slot), with where each curve and each drive goes. A tick only copies values
  by those places; curve materials take their names hashed and their curves found by the tick, so
  the drawing searches nothing.
- **Curve material**: a value of the material of the meshes of the rig (`parameter`: a value of the
  material or of its program, in `slot` or in every slot) is `offset` plus `scale` times the
  curve, rounded to multiples of `step` when it is positive: the frame of a flipbook face, a
  switch, a blush. `animation_skin` draws it over the `Material_Values` of each mesh of the rig
  (the rig and those that share its pose) without writing the component, whose writers stay the
  game and the editor; past the capacity of the component it is the problem
  `animation.curve_material`.
- Each distinct material value is a derived material of the renderer, freed when no drawing uses
  it: a stepped curve costs a few; one that changes in every frame makes one per frame and mesh,
  which suits a few characters, not crowds (there are no per-instance parameters in the shader).
- A face of a rig evaluator or of a control rig is baked to curves and poses or to morphs: the
  plugin has
  no rig evaluator. Poses driven by bone rotations are correctives (inverse distance), not an RBF
  solver.

The capacities are fixed contracts, not growing per frame: a path that does not form a parent-child
chain, a topology that is too long or an incompatible target is a bind failure or a residual.

## Order and state

- Order: retarget of bones and chains (from `Playing.sampled`, before their constraints), removal of
  root motion, the follow of a leader, curve drives and curve poses, grounding, IK/look-at, Chain
  IK, Multi IK, twist, springs, Spline IK, correctives, Follow and, at the end, limits and
  attachments.
- `Modifier_Runtime` stores tables, bindings and spring state; `core.value_copy` copies it for Play
  and rollback and the assets stay shared. The rows are not components nor another owner of
  transforms.
- Each solver has its own plain state struct with the common header `Rig_Binding` and only its
  indices and scratch: Chain IK does not reserve Multi IK joints.
- Preparation stamps configurations, attachments, `Animation`, rigs and the registry revision:
  without changes it walks nothing. A write of `Animation` looks only at `source` and `retarget` of
  the stamped rows; a registry revision compares the definitions used. It rebuilds only if something
  relevant changed and, without memory, keeps what was published. A test that simulates a reload by
  touching a cache also bumps `host.Assets.revision`.
- The operations of a rig are a contiguous block in each table, pointed to by the generational index
  of `core.Table`: evaluating, naming and diagnosing walks only that block. A rig without operations
  prepares no scratch.
- Multi IK with weight one keeps the global pose of the solver; partial weights blend and recompose.
  Disabling springs resets their state only once.

## Requests and diagnostics

- `Modifier_Kind` includes these kinds, and `modifier_control` gives them independent weights and
  fades. `modifier_named_slot`, `modifier_control_named` and `modifier_goal_named` resolve names
  from the prepared runtime and reject ambiguous ones without allocating; code that knows the
  profile may use the prepared indices.
- A named target or control (and `effector_name` in Multi IK) finds its operation again when the
  profile is read again; one by slot follows it only if it keeps its name. A name that is no longer
  there gives `Missing_Operation` or `Missing_Effector` in `modifier_request_error`.
- `Modifier_Goal.target` replaces the target of Chain IK, Spline IK (per control) and Follow; in
  Multi IK `effector` chooses the effector and keeps the others. In Spring, `position` is an
  external force. Twist, Chain Retarget and Corrective have only weight and activation. None of this
  changes the shared definition.
- `animation.inspect` part `Modifiers` lists the operations by name and kind, with influence,
  effectors and the last request error; `diagnostics` adds fade and solver. API contract:
  [control](animation-authoring.md#per-instance-control-and-preview).
- `animation_rig_diagnostic` gives validity, residual (in springs, length error), angular error,
  iterations and `reached`; twist and retarget give only validity. IK and Look store it in
  `Animation_Constraints`, which resolves it: in Look, the angular error of the aim and as residual
  how far it passes from the target at its distance. An unreachable effector does not make a
  numerically good evaluation invalid.

## Bake

`animation.retarget.bake` maps as a live `Pose_Source` of stage `Sampled` does: each bone by the
bone of its name (or path), or by the `retarget_chains` of the destination's `.character` where the
topology differs.

- It prepares the correspondences of `std/anim` once and resamples the destination poses. Chains
  keep translations and scales of the destination.
- Float/Vector curves, slots and markers keep their keys.
- The root motion bone is remapped by name or by exact chain correspondence; if it corresponds
  exactly to no destination, the bake turns off the root flags instead of choosing an intermediate
  root by proximity.
- The new `.anim` has its own identity and is published with the editor's asset transaction; it does
  not modify the sources.

## Verification

`plugins/animation/runtime` (repeat with `--release` only if a failure may depend on optimization):

- `rig_profiles_roundtrip_typed_operations_and_reject_invalid_capacities` and the cases of
  `rig_shapes_test.odin` (spline, correctives, spatial targets, Follow, aligned IK, Look with an up
  axis, targets by name after reordering the set, curve poses and drives)
- Curve drives and poses over a follower, combinations, full poses in any order of the rows, the
  final curves laid out again only when they change, and curve materials: `follow_test.odin`
- `chain_and_spring_modifiers_reuse_bind_buffers_copy_snapshots_and_retire_controls`
- `semantic_retarget_bindings_ignore_actor_placement_and_replay_without_allocations`
- `multi_ik_modifiers_accept_named_goals_keep_effectors_independent_and_clone_solver_scratch`
- `modifier_controls_preserve_targets_and_fade_independently_through_world_copies`
- Also: `modifier_control_requests_*`, `rotation_limits_*`, `shared_profiles_*`,
  `rig_goal_persistence_*`, `profile_reload_allocation_failure_*`, `rigs_without_operations_*`,
  `rig_operations_preserve_*` and `multi_ik_full_and_partial_weights_*`.
- Math: `std/anim/rigs_test.odin`.
- `bench_rig_dispatch_and_multi_ik_scaling` (with `MIRAI_BENCH`).

`plugins/animation/editor` (with `-collection:plugins=<root>/plugins`):

- `baking_without_chains_pairs_bones_by_name_once_and_preserves_curves_markers_and_root_metadata`
  and the two `baking_semantic_chains_*`.
- `rig_modifier_api_discovers_named_operations_effectors_and_retarget_chains_of_the_character`.
- `curve_poses_are_made_from_the_frames_of_a_clip_and_replace_those_of_their_curves`.

The CPU cases verify neither the GPU nor the visual quality of a model: that requires a build and a
run of the editor or the player.
