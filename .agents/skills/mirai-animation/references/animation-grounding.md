# Supports and procedural locomotion

`Foot_Grounding` is the `grounding` row of the `.character` a rig plays (none while its `count` is
0): it
joins the [procedural functions of `std/anim`](../../mirai-std/references/anim.md) with the ground
of the world, over the dense pose of the rig. `Animated` adapts the pose of clips, blends or
retarget; `Procedural` walks without `Animation`, clips or per-bone entities.

The ground is the `core.World_Query` of the world
([world queries](../../mirai-core/references/core.md#world-queries)): rays, the current place
of a support and whether an entity has a body. It is provided by the library that simulates (the
`physics` plugin, with its [queries](../../mirai-physics/references/engine.md#queries)); without
it, or before it is ready, no foot rests and the pose stays intact without error, for authoring and
the preview.

## Configuration

- Start from `FOOT_GROUNDING_DEFAULT` and `GROUNDED_LEG_DEFAULT`; the zero value is safe but does
  not configure a valid gait.
- Up to 16 legs; `count` sets how many entries of `legs` are evaluated.
- The definition is edited in the Grounding table of the set
  ([modifier authoring](animation-authoring.md#skeletons-sockets-and-profiles)).
- The rig is the entity that plays the set. There is one grounding definition per set and an
  independent state per rig.
- The global contact is modified with `Modifier_Goal{kind=.Grounding}` requests;
  `Modifier_Control{kind=.Grounding}` changes influence or activation with an independent fade,
  without touching that contact.
- Each leg is a direct chain of three internal bones, hip, knee and foot, with its toe as the
  contact: the first two legs are those of the body of the skeleton (`@hip_l`, `@knee_l`,
  `@foot_l`, `@toe_l` and their right side); a `Bone_Ref` in `hip`, `knee`, `foot` or
  `contact_bone` overrides the part, and a leg past the body (a spider) names its bones.
- `body` (empty: the pelvis of the body) is the bone that is adjusted before the IK. The containing
  root of the actor is not moved to correct supports.

Parameters:

- **`up`, `trace_above`, `trace_below`**: vertical in the frame of the rig (normalized when
  evaluating; a rig that its character tilts around a planet rests the feet according to its up) and
  reach of the ray above and below the foot of the initial pose.

- **`minimum_ground_dot`**: admissible slope, dot product of normal and vertical.
- **`collision_mask`**: bit mask of the [categories][cat] on which the feet rest.
  - With physics, the probes query the channel of category 0 blocking only those categories: a
    collider that does not block them, like a trigger, is not ground.
  - The body of the rig or of the first ancestor that owns one is ignored (`ground_ignore`).
- **`sole_height`, `foot_up`, `max_tilt` (per leg)**: `sole_height` is the distance between contact
  and foot bone.
  - `Procedural`: `foot_up` is aligned with the normal.
  - `Animated`: the clip's twist is kept and the change of ground plane is applied.
  - `max_tilt` limits that correction in radians (π/2 by default).
- **`contact_bone`, `contact_offset`, `contact_height`, `plant_speed` (per leg)**, in `Animated`:
  - `contact_bone`: optional contact point (e.g. metatarsus); it must be the foot or a descendant.
    Without a reference `foot` with `sole_height` is used.
  - `contact_offset`: its rest height above the root plane.
  - `contact_height` and `plant_speed`: limit the animated height and the speed relative to the
    support to allow planting.
- **`max_distance` (per leg)**
  - `Animated`: maximum distance between the animated contact point and the queried surface,
    including its clearance; it discards distant lower planes.
  - `Procedural`: maximum reach of the support relative to its reference.
- **`pole_offset` (per leg)**: displacement of the pole oriented by the rotation of the actor.
  `Animated`: it is added to the pole that keeps the source flexion. `Procedural`: it starts from
  the initial knee. Zero keeps the automatic plane.
- **`contact`, `global_contact`**: contact strength per leg and multiplier of the whole, in [0,1].
  `global_contact=0` releases all supports (e.g. when jumping).
- **`weight`, `blend_time`, `enabled`**: final influence; blend duration of the planting, the
  adaptation to the terrain and the body correction; activation. Disabling releases the support
  state.
- **`adjust_body`, `body_height`, `max_drop`, `max_rise`, `max_tilt`**: optional body adjustment;
  height above the plane of the foot targets, maximum drop and rise, and maximum turn in radians.

Units:

- Lengths in world units, durations in seconds.
- A leg stretches only by its `reach` (soft distance and stretch, as a chain); without it an
  out-of-reach target keeps the lengths and may leave a residual.
- Scales follow the common TRS contract of Mirai.

## Clip adaptation

Planting (`Animated`):

- A foot is planted when its animated contact is less than `contact_height` above its rest plane and
  its velocity, measured relative to the physical support (with its turns, without subtracting the
  displacement of the actor), does not exceed `plant_speed`; on the first sampling only the height
  counts. The effective contact (leg times global) must exceed 0.5. A low foot that advances in
  swing is released; one on a platform is held.
- `release_distance` releases a foot too far from its animated pose and `replant_distance` (less
  than or equal) lets it plant again. When releasing it a displacement relative to the animation is
  blended: the foot advances and rises from that tick.

Target and orientation:

- The target keeps the height of the contact above the root plane and the twist of the clip; the
  correction takes the vertical plane to that of the ground around the contact, without flattening
  the heel and metatarsus roll (`max_tilt` limits it).
- With a contact other than the ankle both points are checked, and the foot rises if either
  penetrates an admissible surface.
- The adaptation (`alignment`) is weighted by the planting: a released foot keeps its source height.
  It lowers smoothed with `blend_time`, follows the anchor horizontally and rises from that tick;
  losing the contact fades it with the same duration, following the animated pose, and a ray loss of
  one or two ticks does not discard it.
- With an internal adaptation weight of zero and positive requested strengths, a heel clearance
  check raises the target without planting or resetting `alignment`. Requested zeros in contact or
  influence keep their semantics.
- With influence and strengths at full, if the target ended out of reach or the internal IK is
  partial, the resolved foot is checked and up to three bounded corrections raise it to a walkable
  surface with the same IK and pole. A partial influence keeps its blend and may leave the
  penetration of the source; zero leaves the pose intact.
- Contact points are tested, not the volume of the sole or the segments of the leg.

Clip velocity and pelvis:

- The velocity of the clip must correspond to the physical displacement: planting does not correct
  an incompatible gait. The velocity parameter of the Clip node changes the time, not the amplitude
  of the stride; another stride asks for other clips or an additional adaptation.
- The pelvis is compensated with the feet of the initial pose and their targets, weighted by
  influence and planting and limited by `max_drop`/`max_rise`. Only the active anchors move it: a
  foot in flight may query the floor below an edge without dragging the body. It does not use
  `body_height` or tilt the pelvis of the clip.
- Detection by height and velocity does not replace the jump signal: `global_contact=0` during the
  flight avoids premature contacts near an obstacle.

## Gait without clips

In `Procedural`:

- Each leg has its `phase` in the cycle and its step (distance, height, duration); the phase
  advances only if the actor moves or a support deviates. A leg takes a step when it exceeds its
  distance and enters its phase window, without exceeding `max_swinging` at once; a started step
  ends even if the actor stops. `prediction` advances the queries by the planar velocity of the
  actor.
- The foot follows a smooth trajectory until its landing on a physical contact; during the step its
  current place is also queried and the target is raised to keep `sole_height` (the arc may cross
  the front of a step). It is not a path planner.
- The blend of the planting is applied to the target before the IK (interpolating separately the
  twists of the two segments may sink the foot). `weight` regulates the IK; the strength of the
  planting (`legs[i].weight`) also weights the body and the twist of the foot. A stable support asks
  for an active anchor, without swing and at full strength.
- With a gait strength of zero before replanting and a valid contact, the clearance of the reference
  is corrected with the authoring IK without reactivating the anchor or starting a step.

Contact corrections, with positive gait strength and requested contact:

- **Obstructed chain.** After adjusting the body, the hip→knee and knee→foot lines of the candidate
  chain are queried. If the first intersection is walkable, a support is tried there and adopted
  only if it is reached without stretching with both segments free, replacing the anchor and
  cancelling the step; if it is not walkable, a pole toward its normal is tried to bend the knee
  away from the obstacle. A clean posture keeps target and pole.
- **Unreachable support.** If a support stops being reachable even with the body adjustment, a few
  bounded bisections look for the viable contact closest to the previous anchor; it may move the
  foot suddenly on a descent or a turn and does not guarantee finding a support in discontinuous
  geometry. Without a candidate the previous target remains with its residual.
- **Blocked.** Without a walkable, reachable and free support the target is kept and
  `Grounding_Record.blocked` marks the leg; the mask may be zero with a residual if lengths or
  limits prevent reaching. In `Animated`, a shin that crosses geometry does not become a contact:
  segments are looked at only in the diagnostics (`grounding_limb_hit`).

Body:

- Height and orientation come from the planes of the supported legs, without those in flight or with
  an inactive anchor; `body_height` is measured from the foot targets. After smoothing, the height
  is limited by the reach of each leg (the vertical of its hip against a sphere of the length of the
  leg at its target) and by `max_drop`/`max_rise`. If the limits are incompatible, an infeasible
  target keeps its residual: weights are not lowered to hide it.
- The animated pole keeps the flexion of the pose recomposed after the body adjustment
  ([`two_bone_pole_from_pose`](../../mirai-std/references/anim.md#adaptation-ikodin-retargetodin-followodin)):
  raising the foot does not invert the plane when passing near the source knee.
- It is geometric adaptation, not physical balance or full-body IK; the game moves the actor.

## Execution and state

- It runs after physics; within animation, after the retarget and the removal of root motion from
  the pose and before the manual constraints and the sockets. Chain: supports, foot height, body,
  support corrections, two-segment IK and foot orientation.
- Each leg queries its support with a ray; the other rays are only for a contact other than the
  ankle, a procedural foot in flight, the reference with zero strength or a correction. All respect
  mask, exclusion of the actor, slope and reach.
- After adjusting the body the whole pose is recomposed; then each correction recomposes only its
  branch (body, leg, foot) before the next leg, also with overlapping chains, with the [prepared
  composition of `std/anim`](../../mirai-std/references/anim.md#skeletal-pose-skeletonodin).
- A support stores the id that the ground gives to its support (with physics, the generational
  handle of the body) and point and normal in its space: it follows platforms, also when landing a
  step. A retired body stops being a support. Colliders are not deformed from the visual pose.
- `Grounding_Runtime` belongs to the world and is copied with it; its records are plain and the
  topology of each binding lives in its own buffer, without views or pointers. Changing the binding
  or the set of configurations prepares again in a transaction; changing weights or strengths reuses
  the memory. Removing a component compacts its links; a lack of memory keeps the previous state.
- Rig problems: `animation.grounding_config`, `grounding_bones`, `grounding_solve` (with the leg and
  the step) and `animation.memory`.

## Verification

`demo/game/grounding_physics_test.odin` (`mirai test demo/game`, which has `animation` and
`physics`), against a real simulation and its `World_Query` (repeat with `--release` only if a
failure may depend on optimization). It covers slopes, platforms, procedural steps, spiders, replay
and lack of memory.

- `grounding_queries_real_slopes_places_both_feet_and_releases_when_jumping`
- `grounding_procedural_pose_follows_platform_replays_clones_and_allocates_nothing_when_stable`
- `eight_legged_grounding_walks_without_animation_clips_or_per_leg_entities`
- `grounding_prepared_hierarchies_rebind_atomically_repack_rigs_and_replay_copied_worlds`
- `grounding_configuration_retires_removed_rigs_and_retries_out_of_memory`

With their own flags:

- `bench_grounding_pose_recomposition_scaling` (`grounding_physics_bench_test.odin`, in the same
  package) with `MIRAI_BENCH=true`, Speed, `ODIN_TEST_THREADS=1` and a free CPU.
- `imported_mirai_avatar_walk_and_land_preserve_contact_phases_and_animated_foot_roll_on_slopes`
  with `MIRAI_AVATAR_TEST=true` and the generated local Mirai assets; `MIRAI_AVATAR_TRACE=true`
  prints the ankle and metatarsus sampling of the first walking ticks.

These CPU tests do not replace the run and visual review of the gallery and Mirai.

[cat]: ../../mirai-physics/references/engine.md#collision-categories-and-presets
