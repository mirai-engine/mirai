# Rigs and chain modifiers

The tables `twist`, `springs`, `multi_ik`, `spline_ik`, `follow` and `curve_poses` extend the
[modifiers of the `.character`](animation.md#components-and-shared-data): they are rows of a shared
definition, without components per operation. A `.character` of another `CHARACTER_VERSION` is
rejected and written again. Math: [std/anim](../../mirai-std/references/anim-rigs.md).

Each row has a name, a weight and an activation; the name is unique in its table and is what an
instance controls and inspects. The defaults are the `*_DEFAULT` constants of each type; bones are
named with `Bone_Ref`.

## Spatial targets

`Spatial_Target` is the target of IK, Look, each effector of Multi IK, each control of
Spline IK, Follow and each [warping](animation-motion.md#requests-and-order) window; there is no
other way to name it.

- `kind`: `World`, `Entity` (in the space of `entity`), `Bone` (a bone of the rig `entity`) or
  `Socket` (a socket of its skeleton), with position, rotation and scale in that space.
- The set stores kind, bone or socket and transformation in `Spatial_Definition`. The entity
  arrives with the instance target. Build targets with `spatial_point`, `spatial_entity`,
  `spatial_bone` and `spatial_socket`.
- Bone and socket read the pose that their rig sampled in this tick (`Playing.sampled`; the warping,
  that of the previous one), with the root in the world of its entity. The path to the bone is
  resolved once per bind and skeleton; sampling afterwards does not allocate.
- A target that is not found (entity without a transform, unsampled rig, bone or socket that the
  skeleton does not have) leaves the operation unapplied that tick and remains as `Missing_Target`
  in `modifier_request_error`.

## Operations

- **Spline IK**: the chain over a cubic Bézier of four targets, with `up` as the axis it keeps and
  `twist` distributed. With all controls `World`, the profile checks that the curve has length; if
  it is shorter than the chain, the chain continues straight and the residual remains in `end`.
- **Follow**: takes a bone to its target in position, rotation and scale (each optional); with
  `keep_world`, when the target changes it keeps the place of the bone as an offset, without jumps.
- **Twist**: distributes the animated twist of a source, outside the chain, among the bones of the
  chain; without quantities it distributes uniformly and, with them, one per bone.
- **Spring**: Verlet with explicit spherical collisions in the evaluation space; pose and force
  arrive as data, without querying physics. It resets when the bind or configuration changes, when
  deactivated, when reaching zero weight or when passing the teleport distance.
- **Multi IK**: the one solver of chains past two bones (a reach, a tail, a spine, a body of
  several limbs): a subtree with joints (stiffness, preferred pose, limits about axes) and named
  effectors with independent weights of position and rotation. The root is resolved by name, not
  as an index of a skeleton, and its translation is `Fixed` or `Translate`. Without joints every
  bone from each effector up to the root is one, of default settings. It diagnoses residual,
  angular error and convergence.
  - Per effector, `use_pole` bends its chain toward `pole`, a point of the world: a straight chain
    first turns its joints a little toward it, and each iteration turns the chain about the line
    from its top joint to the effector, which keeps the effector in place, until its bend faces
    the pole; a turn that the limits of the top joint clamp waits, so the pole never fights them.
  - `reach` (`soft_distance`, `max_stretch`) softens the approach to full extension and stretches
    the bones below the top joint past it, before the solve; the residual is measured from that
    softened goal. Its stretch blends by the weight of the operation as the rest of the pose.
  - A goal that names no effector is for the one effector of an operation that has one.
  - Near full extension a long chain takes more iterations than the default to settle (the
    playground's reach of nine bones uses 64).

## Curve poses

The face of a character is poses that Float curves weigh, as a pose asset of other engines, over
its body animation; no solver evaluates it.

- **Curve pose**: a row per bone of a pose (`curve`, `bone`, `delta`): at the value of its curve,
  from 0 to 1, the bone moves by `delta` over its pose, in the space of its parent with its scale a
  factor. With `full` the row is the transform of the bone itself: the full poses of a bone blend by
  their weights, normalized past 1 so that only they count, before the additive ones (a pose library
  of hands or props). The additive poses of a bone are summed (rotations by their logarithms) and
  applied once, so the order of the rows does not change the pose. A curve can name a pose, a
  phoneme or a shape of a bend; `animation.modifier.poses` makes the rows from the frames of a clip.
  A curve names its pose directly: a face capture (ARKit) names its poses by its 52 curves.
- The curves come from the animation of the rig (clips, layers, actions, programs). A rig that
  follows a [leader](animation.md#following-a-rig-of-another-skeleton) (a modular head) reads the
  curve of its leader while the leader animates it and its own otherwise (`rig_curve`), so the
  face a body plays poses the head; its morphs read its own curves first and the leader's where
  its own do not play ([morphs](animation-morphs.md#weights)). The poses move the bones before the
  other operations of the profile.
- Each row keeps where its curve was found among the curves of the rig and of its leader, so a
  stable tick finds it at once and searches by halves only when the curves change place.
- A material value of a face (a flipbook frame, a blush) is a track of its clip, not a row:
  [`@field/Material_Live`](animation-timeline.md#material-values-of-a-rig).
- A face of a rig evaluator or of a control rig is baked to curves and poses or to morphs: the
  plugin has
  no rig evaluator, no curve expressions and no pose-space correctives: a bend that needs a shape
  takes it from `Twist` and morph targets the clip keys.

The capacities are fixed contracts, not growing per frame: a path that does not form a parent-child
chain, a topology that is too long or an incompatible target is a bind failure or a residual.

## Order and state

- Order: removal of root motion, the follow of a leader, curve poses, grounding, IK/look-at, Multi
  IK, twist, springs, Spline IK, Follow and, at the end, limits and attachments.
- Each world owns its `Modifier_Runtime`, indexed by generational entity. A row keeps bindings,
  influence, overrides and solver state for one rig. It reads definitions from the shared character
  content by asset identity and revision. A rig without modifiers or attachments takes no row.
- Creating or retiring a rig leaves the other rigs' bindings and history intact. A changed profile
  prepares only its rig, carrying requests forward by name. Changing an attachment refreshes its
  bone or socket binding.
- Each solver keeps only the indices and scratch it uses. A stable tick reuses them.
- Multi IK with weight one keeps the global pose of the solver; partial weights blend and recompose.
  Disabling springs resets their state only once.

## Requests and diagnostics

- `modifier` queues a `Modifier_Request` addressed by rig, kind and name. The string arguments
  hash operation and effector names at the call boundary. The queue stores compact identifiers
  and resolves them against the rig's current character set.
- With `goal` set, a request supplies the target, spring force or grounding contact. Otherwise
  it adjusts the operation's influence independently of its goal. Multi IK and Spline IK name
  the effector or control whose target changes. Replacing a target leaves the others in place.
- A request follows its name when rows are reordered. A missing name, missing effector or
  unresolved target is reflected in `modifier_request_error`.
- `animation.inspect` part `Modifiers` lists the operations by name and kind, with influence,
  effectors and the last request error; `diagnostics` adds fade and solver. API contract:
  [control](animation-authoring.md#per-instance-control-and-preview).
- `animation_rig_diagnostic` gives validity, residual (in springs, length error), angular error,
  iterations and `reached`; twist gives only validity. Look reports the angular error
  of the aim and how far it passes from the target at its distance. An unreachable effector can
  still give a valid evaluation.

## Bake

`animation.retarget.bake` maps as the [retarget on load](animation.md#retarget) does
(`lib.retarget_map`): each bone by the bone of its name (or path), else by the part of the body both
`.skeleton`s mark, the spine by its share of the chain; unpaired bones keep their rest.

- It prepares the correspondences of `std/anim` once and resamples the destination poses, keeping
  translations and scales of the destination.
- Where both bodies have both legs, the feet of the destination are locked to the ground with the
  clip edit `Lock_Feet` over the frames the feet of the source stand, if any: a mapping cannot keep
  them by itself when the limbs have other proportions. Whether the bake loops is decided on the
  source.
- `crotch_floor` (both skeletons with a body of pelvis, hips and feet, or the bake fails) raises
  the pelvis while the source crouches so the hips keep the share of their rest height over the
  feet that the hips of the source keep, and turns the legs so the feet stay
  (`retarget_crotch_pose`). It only raises: a body of longer legs keeps what the mapping gave.
- Float/Vector curves, slots and markers keep their keys.
- The root motion bone is remapped by its pair; without one, the bake turns off the root flags
  instead of choosing a root by proximity.
- The new `.anim` has its own identity and is published with the editor's asset transaction; it does
  not modify the sources.

## Verification

`plugins/animation/runtime` (repeat with `--release` only if a failure may depend on optimization):

- `rig_profiles_roundtrip_typed_operations_and_reject_invalid_capacities` and the cases of
  `rig_shapes_test.odin` (spline, spatial targets, Follow, aligned IK, Look with an up axis,
  targets by name after reordering the set, curve poses, versions other than this one refused)
- Curve poses over a follower that reads its leader's curves and its own without them, full poses
  in any order of the rows and curves renamed in place: `follow_test.odin`
- `multi_ik_and_spring_modifiers_reuse_bind_buffers_copy_snapshots_and_retire_controls` (a Multi
  IK without joints, its pole, and its goal without an effector name)
- `multi_ik_modifiers_accept_named_goals_keep_effectors_independent_and_clone_solver_scratch`
- `modifier_controls_preserve_targets_and_fade_independently_through_world_copies` and
  `discovery_test.odin` for live rig state across unrelated despawns and spawns.
- Also: `modifier_requests_*`, `rotation_limits_*`, `shared_profiles_*`,
  `rig_goal_persistence_*`, `profile_reload_allocation_failure_*`, `rigs_without_operations_*`,
  `rig_operations_preserve_*` and `multi_ik_full_and_partial_weights_*`.
- Math: `std/anim/rigs_test.odin` (Multi IK with pole and reach on a chain of nine, the pole
  yielding to hinges, hostile poles and reaches).
- `bench_rig_dispatch_and_multi_ik_scaling` (with `MIRAI_BENCH`).

`plugins/animation/editor` (with `-collection:plugins=<root>/plugins`):

- `baking_pairs_bones_by_name_once_and_preserves_curves_markers_and_root_metadata`,
  `baking_pairs_differently_named_skeletons_by_their_bodies_and_preserves_curves_markers_and_root`,
  `baking_rejects_skeletons_that_pair_no_bone_and_allocation_failure_without_publishing` and
  `baking_a_walk_onto_a_shorter_body_keeps_its_feet_from_sliding_more_than_the_source`.
- `rig_modifier_api_discovers_named_operations_and_effectors_of_the_character`.
- `curve_poses_are_made_from_the_frames_of_a_clip_and_replace_those_of_their_curves`.

The CPU cases verify neither the GPU nor the visual quality of a model: that requires a build and a
run of the editor or the player.
