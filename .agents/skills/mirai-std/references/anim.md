# std/anim

Package `mirai_anim` (`import lib "mirai:std/anim"`). It animates values, transforms and skeletons
over caller buffers and delivers poses and palettes to the upper layers, without ECS or GPU. It
depends on `core:`, `std/base` and `std/math`.

- It uses `math.Ease` for the curves. The
  [UI animation](../../mirai-ui/references/ui.md#game-interfaces) stores these keys and reads them
  with `track_evaluate`, in a library of its own: its nodes are not entities.
- The definition (`Library`) is created with capacities, prepared at load or authoring time, and is
  shared and immutable during playback. The temporal state (`Player`, `Fader`,
  `Inertial_State`, `Spring_Joint_State`) is plain and copyable; the solvers receive caller buffers.
  Playback does not allocate.
- Creation and [resident compression](anim-storage.md) are explicit transactions; what is rejected
  returns its cause (`Clip_Error`) or `false`, and poses count in `failed`.
- The [body map, the metrics and the editing verbs](anim-body.md) work on sampled clips (`Frames`).

## Loops (`loop.odin`)

- `Loop` and `loop_time` define the timeline of a playback: one pass is one duration and the
  ping-pong walks the odd ones backwards.

## Tracks, keys and clips (`track.odin`, `clip.odin`)

- `Keyframe` is the only key of the engine and `track_evaluate` the only reader of a keyed value:
  clips, the cinematics they play and the animations of an interface store and read the same.
- The interpolation and easing of a `Keyframe` say how the value arrives at it from the previous
  one; the comment of `Keyframe` defines the tangents of `Cubic` (Hermite). Outside the keys the
  track holds its value; a NaN time gives the first one.
- In `Rotation`, `Cubic` is Shoemake's spherical spline (`squad`): it passes through each key, the
  turning speed does not jump and it does not use the slopes. `Cubic_Spline` is glTF's: it keeps the
  imported tangents per component.
- Each track of a clip points to a `target` (`name_hash` of the node, bone or material), a property
  and a `slot` that distinguishes several `Float`/`Vector` of the same target. `clip_add` copies the
  data and rejects with `Clip_Error`. The duration is the time of the last key or marker.
- `clip_evaluate` evaluates keys and sampled tracks with the same contract
  ([storage](anim-storage.md)).

## Playback and events (`player.odin`)

- `Player.time` is reduced to a period so as not to lose precision; a negative speed plays
  backwards.
- `player_advance` writes the crossed markers in the order in which they were crossed, with the
  fraction of the advance at which each one was crossed. A marker is crossed when passing it in the
  direction of playback: in `Loop` those at the start and the end fire once per pass and in
  `Ping_Pong` the turn counts once. Passes of more than `MAX_PASSES_PER_ADVANCE` are counted as
  discarded.

## Blending (`pose.odin`)

- `Pose` accumulates per (target, property, slot) the weighted sum of the samples and their total
  weight; the value is the weighted average, and a total weight below 1 allows blending toward a
  base pose with `saturate(weight)`. A new entry without room is counted in `pose.failed` and the
  function returns `false` so that the caller reports it.
- `Fader` does the cross-fades (rules in the comment of `fader_play`): a fade started during
  another does not change the pose at that instant.
- **Additives.** `pose_blend_additive` adds what the clip changes with respect to the pose at a
  reference time of a reference clip (by default its own; a target the reference clip lacks is
  measured from its own), over what the others blend: a value is added and a rotation is composed
  afterwards. `pose_bone` turns what a pose blends for a target into the local transform of its
  bone, each channel from the rest by its weight.
- **By bone.** Whoever plays clips on a fixed list of bones says once, by track of the library,
  which bone each track moves (−1: none): `bones_blend`, `bones_fader_blend` and
  `bones_blend_additive` accumulate one `Bone_Blend` per bone through that table, with the values
  of `pose_blend`, `fader_blend` and `pose_blend_additive`, without a search by name or a capacity
  to run out of; `bone_transform` is the `pose_bone` of a bone. `Pose` stays for targets that are
  not such a list (any entity, property or slot).
- **Root motion** (`root.odin`). `clip_root_motion` gives how much the root target moved and turned
  between two positions of the timeline, in clip space; a `Loop` adds a whole pass for each lap.

## Blend spaces (`blend_space.odin`)

- `Blend_Space` (1D or 2D) is a shared definition, immutable in use: points of the parameter space,
  without clips or engine dependencies. The [plugin's `.blend`
  format](../../mirai-animation/references/animation.md#composition-graphs-and-additive-spaces)
  associates each point with a clip and normalizes the units of its axes; the plugin uses it only
  for aim offsets and additives, not for locomotion.
- `blend_space_prepare` is a transaction: it copies the points, orders segments in 1D and
  triangulates in 2D (convex hull, sample insertion and Delaunay flips); a failure releases
  everything.
- Up to `BLEND_MAX_SAMPLES` finite samples (at least three in 2D). In 1D X cannot repeat and Y does
  not participate; in 2D positions cannot repeat nor all lie on a line. Segments and triangles
  (counterclockwise) reference the original indices, which correspond to the clips.
- `blend_space_validate` verifies points, indices, orientation, 1D continuity and 2D coverage
  without crossings or overlaps. It is for load or authoring time: a definition built from
  serialized data is validated before being published.
- `blend_space_sample` does not allocate and gives up to three samples with non-negative weights
  that sum to one. In 1D it interpolates the two neighbors and holds the ends; in 2D it uses
  barycentric weights and, outside the hull, projects onto the nearest segment. Non-finite inputs or
  broken topology fail safely, but it does not replace validation. The caller keeps the clocks and
  combines the poses.

## Skeletal pose (`skeleton.odin`)

`Skeleton` is an immutable view of the caller: parents precede their children, `-1` is a root and
`names` stores the identity of the targets of the tracks. `skeleton_validate` requires arrays of
equal length, at least one bone, finite transforms and unit quaternions. No procedure allocates.

- `skeleton_bind` resolves the tracks of the clip per bone once (`-1`: use the reference), and
  `skeleton_sample` writes a dense pose without searching by names.
- `pose_world` composes the hierarchy with `math.transform_compose` and receives only what the
  composition needs: it validates sizes, earlier parents, root and TRS in the same pass.
  `skeleton_world` also validates the definition. There is no mode without validations.
- `skeleton_palette` multiplies each global pose by its inverse bind; the space of the mesh instance
  belongs to the consumer. `skeleton_socket` composes an offset with a bone.
- `pose_hierarchy_prepare` validates the topology and fills the child and sibling links; the
  resulting `Pose_Hierarchy` lends the two buffers, which stay alive and immutable (changing parents
  requires preparing again). `pose_world_branch` recomposes a bone and its descendants even if they
  are interleaved with other branches, without recursion; it requires the world outside the branch
  to be up to date and the other local poses not to have changed. It does not replace full
  synchronization when other branches change.
- `pose_layer` blends two poses with per-bone weights (`pose_mask_branch` creates the mask of a
  branch); `pose_additive` applies deltas with respect to an explicit pose.
- The output buffers may coincide exactly with an input, never partially overlap. A short buffer, an
  invalid index, a non-unit quaternion or a non-finite number return `false`, and the output of a
  failed call is discarded: it may have been left partly written.

## Mirroring (`mirror.odin`)

- `mirror_name` gives the name of the other side (`thigh_l`, `hand.L`, `Bip01 L Thigh`, `LeftArm`);
  the pairing of bones by name is done by the consumer.
- The pairs are mutual and roots are paired with themselves: they keep their transform and define
  the mirror space. `mirror_prepare` deduces the plane and a per-bone correction for rigs whose
  sides use different axes.
- `pose_mirror` keeps the scale, mirroring twice returns the pose and `out` may be `local`. The
  loose `mirror_*` reflect values such as a root delta.

## Sync and curves (`sync.odin`, `clip.odin`, `root.odin`)

- `sync_phase` gives at which point of its cycle a clip is (between which markers and at what
  fraction); `sync_time` translates it to the time of another clip by the markers of equal
  identity.
- `fader_root_motion` gives the root motion of the next advance with the weights at mid-advance. The
  consumer asks its physics controller for that displacement and decides which channels to remove
  from the pose.
- [Inertialization and motion adaptation](anim-motion.md). Named clocks, events, transition
  policies and layers: [animation plugin](../../mirai-animation/references/animation.md).

## Adaptation (`ik.odin`, `retarget.odin`, `follow.odin`)

- `two_bone_ik` receives three transforms in the same space, target and pole. It keeps the lengths
  also with intermediate weight, clamps targets out of reach, keeps the rotation of the end and
  gives `reached` apart from numeric success. `skeleton_ik` applies it to a direct parent-child
  chain and recomposes the pose.
- `two_bone_pole_from_pose` gives a pole that keeps the bend when the target changes: it transports
  the direction of the knee through the minimal rotation of the root→end axis toward root→target and
  leaves it at one chain length, so that raising the target does not invert the knee. An almost
  straight chain uses a stable axis of the joint.
- `pose_ik_apply` applies an already computed `IK_Result` over the global pose and recomposes the
  branch of the root with the contract of `pose_world_branch`: it reuses a candidate that the
  consumer already checked, without solving it again or dirty flags.
- `look_at` orients a local axis with limited angle and weight; `rotation_limit` limits swing and
  twist with respect to a reference.
- `foot_plant` holds a contact anchor given by the consumer and releases it past a distance;
  `pelvis_offset` gives the limited vertical displacement that allows the feet to rest. Detecting
  the ground and the grips belongs to the gameplay integration.
- `retarget_prepare` receives correspondences by index and both reference poses and prepares per
  destination bone the orientation offset, the change of basis and the scale. `retarget_pose` keeps
  the length of the destination bones; translations are kept, copied or scaled
  (`Retarget_Translation`), and a source index `-1` keeps the reference. The work buffers and the
  references do not overlap the output. It does not infer names or solve full-body IK.
- `follow_prepare` pairs the bones of a follower skeleton with those of a leader by name, or by path
  where a name repeats in either; `follow_pose` gives each paired bone the leader's pose: its local
  transform as is when its parent is paired with the leader's parent, else its place in the world
  carried under its own parent. Unpaired bones keep their local transform under a parent that now
  moves (`follow.odin`).
- `Pose_Accumulator` sums the poses of a bone so that their order does not matter:
  `pose_accumulate` adds a full pose by weight (rotations on one side) and `pose_delta_accumulate`
  an additive one by a weight clamped to 0..1 (a delta in the space of the parent of the bone, its
  scale a factor, as a face's poses are stored: translations summed, rotations by their
  logarithms, scales multiplied). `pose_accumulated_apply` blends the bone to the average of the
  full poses by their total, normalized past 1, and adds the additive ones over it.
- [Chains and modifiers](anim-rigs.md): retarget between chains of different topology, Multi IK,
  twist and springs. The definition is shared among characters; each parallel evaluation receives
  its state and its scratch.

## Procedural without clips (`procedural.odin`, `chain_ik.odin`)

They need no `Library` or clips: they are `contextless`, do not allocate and use plain states.
Points, normals, targets and global poses go in the same space; `std/anim` makes no physics queries:
the consumer delivers contacts and transforms of the live supports.

- **Contacts.** `Surface_Contact.support` 0 is fixed ground; another value is a moving support whose
  transform arrives in a batch of `Surface_Support` with unique IDs and invertible scales. The
  anchor stores a local point and normal; an absent support releases it and returns `false`.
- **Feet.** `foot_placement_update` plants with a valid contact and a force greater than half,
  follows the platform and blends its weight. `replant_distance` (not greater than
  `release_distance`) avoids toggling at the limit. `offset` stores the correction with respect to
  the animation: on release, the target accompanies `animated` while its weight falls, instead of
  staying at the absolute anchor. The normal describes the support, without forcing the rotation of
  the animated foot to be removed.
- **Gait.** `gait_update` coordinates as many legs as it receives: the phases of each leg and
  `swing_fraction` open the step windows and `max_swinging` limits the simultaneous ones. A foot
  stays fixed until `step_distance` and `max_distance` releases a distant support; on release, the
  target follows the `desired` reference as with the feet. The phase advances when moving or when
  correcting a deviation; a started step ends even if the actor stops and `dt=0` evaluates without
  starting steps. The defaults are `GAIT_CONFIG_DEFAULT` and `GAIT_LEG_DEFAULT`; a zeroed
  configuration is not valid. `gait_step_position` is the trajectory of the step: zero vertical
  velocity at the ends, maximum at mid-step and a landing that follows its support.
- **Body.** `limb_height_range` gives the heights over `up` that leave the target within reach of
  the limb (`false` if none); the consumer intersects those of the legs after smoothing, without
  moving anchors or stretching segments. `gait_body_target` adapts the height and orientation of the
  body to the supports, with local vertical axis Y, and limits the correction; legs in flight or
  with an inactive anchor are excluded even if their weight keeps decaying.
- **Chain IK.** `chain_ik` is FABRIK on positions with a fixed root, an optional pole and per-joint
  bend limits (between straight and π); it reports residual, iterations and `reached`, without
  guaranteeing convergence with constraints. `out` may be exactly `points`. `skeleton_chain_ik`
  applies it over a parent-child chain: it keeps local translations, weights rotations and
  recomposes siblings and descendants. For two segments the analytic `skeleton_ik` is preferred.

Integration order: base or sampled pose, support queries, gait and planting, body adjustment, IK and
orientation of ends, sockets and palette. Do not sample the pose again after the procedural. There
is no physical balance solver, self-collision between legs or full-body IK.

## Verification

`mirai test std/anim` with the file of the touched area. Rigs, motion and storage have their own
section: [rigs](anim-rigs.md#verification), [motion](anim-motion.md#verification),
[storage](anim-storage.md#verification).

- Follow and pose deltas in any order, with hostile inputs: `follow_test.odin`.
- Hostile cases: `ANIM_HOSTILE_ROUNDS` (skeletons and solvers), `ANIM_BLEND_HOSTILE_ROUNDS` (blend
  spaces) and `ANIM_PROCEDURAL_HOSTILE_ROUNDS`; when changing validation or memory, `--release` and
  20000.
- The blend by bone against a `Pose`, with tracks in other orders, missing or of another slot:
  `bones_blend_what_a_pose_blends_for_their_targets`.
- Benchmarks, optional with `-define:MIRAI_BENCH=true`: `bench_skeletal_two_clips_layer`,
  `bench_bones_blend_against_pose`, `bench_blend_space_sampling`,
  `bench_procedural_gait_and_chain`.
