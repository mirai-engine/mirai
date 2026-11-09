# Motion matching, inertial transitions and motion adaptation

Functions of `std/anim` over caller buffers; they neither allocate nor store pointers in the
temporal state. The world integration and the authoring are in
[the motion profile](../../mirai-animation/references/animation-motion.md).

## Motion matching (`matching.odin`)

- `Match_Database` is a shared definition: one row of features per frame of each clip at `rate` rows
  per second (position and velocity of the feet, velocity of the hips, velocity of the body, where
  it was `MATCH_PAST` seconds before, position and direction of the trajectory at `MATCH_HORIZON`),
  in the frame of the character (its place on the ground and its facing, -Z forward), normalized per
  type so that each type weighs what its weight says. The present and the past say what the body
  did, the future what it is asked for: a body held still that is asked to walk is not a walk.
  `match_database_build` is a load transaction: it rejects with `Memory_Limit` a database larger
  than its cap (`match_database_bytes` estimates it before allocating) and leaves the database empty
  on any error.
- An in-place clip travels at the velocity with which its feet push; one with a root, at that of its
  root. `Match_Clip.speed`, when positive, replaces that speed: an in-place clip keeps the direction
  its feet push, or, when they do not push (a jump), goes where its body faces at its first frame,
  never along the noise of its supports. A loop continues in its following passes and one without a
  loop retains its ends.
- A `Match_Clip` is one clip or a blended sample of up to `MATCH_BLEND`: the clips with a weight
  (`match_clip_duration` refuses those that do not loop, last more than a row apart, or weights out
  of 0..1) are sampled at the same share of their durations and mixed as the program mixes the
  leaves of a group (`pose_blend`, then `pose_bone` from the rest), so its rows, speed and travel
  are those of the blended pose. Its `Match_Range` keeps the clips and the weights as shares of 1,
  which the player plays together. Its `rates`, when set, replace the `min_rate`..`max_rate` of
  the request for that range (`match_range_rates`).
- `match_trajectory` predicts the trajectory with the acceleration and braking of the locomotion and
  the turn at its rate: the same numbers that move the body. A wall normal takes out of the
  velocity and of the desired one what goes into the wall, so a body pushing against it stands and
  one along it slides. The past point comes from a `Match_Trail`, how far the body went in each of
  its last spans of time, whatever the tick (the time it does not hold went at the pace of the
  oldest span); without a trail the body went at its velocity.
- `match_search` gives the lowest-cost row among the clips of the requested modes and the rate at
  which its clip plays (the trajectory is scaled per clip, so a few clips cover the velocities
  between theirs). The query is taken to the rate of each clip (the velocities of its pose, by the
  rate at which it sounds over that of the clip) and velocities and trajectory positions weigh the
  square of the rate: the cost is of what the body does, and a slow clip does not pay more than one
  at its own rate. It leaves out the tail of a clip without a loop (`match_tail`: its last horizon,
  or `MATCH_TAIL_MIN` seconds of one shorter than that, keeping its first row), the rows of the
  clip that plays within `span` seconds of its row (around the seam of a loop; all of them with
  `whole`), and those of `Match_Recent` the rig played in the `span` seconds before it left them.
  With `filter_stationary`, a clip that is not an entry plays only if it stands (`MATCH_STILL`)
  when the body does and travels when it moves. The entry clips (`entry`) are searched only in their
  first `MATCH_ENTRY_SPAN` seconds and only with `Match_Request.entry`; the continuous search leaves
  them out. With `Match_Candidates` it also notes the best row of each clip, least cost first, with
  its cost per kind of feature, and gives the same row: each clip is bounded by its own best row.
  The clips it leaves out follow, each by its best row and its `Match_Reject`. That walks every
  clip whole, so only inspection asks for it, never the tick.
- An event (a landing): `match_database_build` keeps per row the seconds to the next marker of the
  event in its clip, and a request with `event` searches only the rows in its window
  (`match_event_window`: the marker is reached at a rate of `event_rates` within half a row, and
  not further than `event_from`), scored as usual and given at that rate; entry or not, without tail
  or stationary filter unless it enters.
- The database keeps per mode which have entry clips, clips with the event, clips that stand and
  clips that travel, so a tick asks them without walking its clips.
- A database of more than `MATCH_LINEAR_ROWS` rows stores the minimum and maximum of its features
  per runs of rows, small and large; the search skips a run whose bound does not improve the best
  row found and gives the same row as the full walk. Without bounds, the walk is linear with
  `f32x4`. It does not allocate.

## Inertialization

- `Inertial_State` is plain; `[]Inertial_Bone` and `[]Inertial_Curve` store the offset and the
  residual velocity per bone or curve and are sized when preparing the rig.
- `inertial_capture` receives the previous, current and target poses (and optionally the previous
  target), their curves, `dt` and the duration.
  - `current` is the last already-blended output: capturing from it interrupts a fade without
    jumping to an earlier pose.
  - The residual velocity is the one observed in the output minus that of the target. The rotation
    one comes from the residual logarithm with aligned hemispheres: it keeps continuity when output
    and target turn on different axes or cross 180°.
  - Without a previous target, the target is still; with an almost-zero `dt` the velocities are
    zero, and with zero duration the target is taken.
- Each channel of a bone (position, the logarithm of the short arc of the rotation, scale) keeps the
  direction of its offset; only its length closes. The capture keeps of the residual velocity its
  part along the offset, drops it when it heads away from the target, and ends a fast approach
  before the duration, at five times the length over the speed: the offset never overshoots.
- `inertial_pose_apply` adds to the target offsets whose length follows a fifth-degree polynomial
  from the length and its speed to zero length, speed and acceleration, with the least initial
  acceleration that keeps it from crossing zero. A mask of weights regulates each bone (zero leaves
  the target exact). `inertial_curves_apply` does the same with floats and `filtered` leaves a curve
  at the target.
- A capture that interrupts an unfinished transition keeps what that one left undone as its
  deficit; when that one had interrupted another too, the new duration gives the deficit up, so
  transitions that follow each other tick after tick do not pile up offsets. Finishing a transition
  clears the deficit.
- Applying before advancing keeps the capture pose exactly, and the target is evaluated on each tick
  without continuing to evaluate the outgoing clip.
- Each output may coincide exactly with its target, not partially overlap. NaN, infinities,
  incompatible sizes, invalid states or overflows return `false`; the output may be left partly
  written, but the capture state is published only after validating and computing.

## Root motion directed at a target

`root_motion_warp` receives `actor` and `target` in world space, and `delta` and `remaining` (the
original movement from the start of the step to the end of the window) in the local space of the
rig; `fraction` is the part of the remaining time that this step consumes.

- It computes the expected endpoint of the original movement and distributes its error toward the
  target, over the channels and axes chosen by `Root_Warp`.
- A zero weight or fraction keeps the original delta exactly; with both at one, the active axes
  reach the target if the consumer applies the delta (physics may prevent it).
- It takes into account the scale of the actor, whose axes cannot be collapsed. It only corrects
  data: it does not write the position of the actor or query physics.

## Orientation and stride warping

- `orientation_warp_angle` gives the signed angle between two directions projected on the plane
  perpendicular to `up`, limited. `stride_warp_scale` gives the limited velocity ratio (one with an
  almost-zero source velocity). Degenerate directions, negative velocities, invalid ranges and
  non-finite values fail.
- `pose_warp` receives the mutable local pose and a separate global buffer:
  - It turns the pelvis and distributes the inverse compensation over the spine.
  - The stride scales the projection of each foot with respect to its own hip over the direction of
    travel, keeping the separation that comes from the pelvis.
  - The pole of the knee comes from the source flexion plane ([common pole](anim.md)), without
    configuring another plane.
  - It keeps the lengths and the world rotation of each foot after the pelvis turn.
  - An effective stride of one skips the IK; if the angle is also zero, or with zero weight, the
    local pose stays exact.
  - The limbs share no bones and the local and global buffers do not overlap. It is a pose
    adaptation, not a physical balance solver.

## Distance to time

- `Distance_Key` uses seconds and the distance units of the caller. `distance_track_validate`
  requires at least two keys, strictly increasing non-negative time and strictly monotonic
  distance: a plateau would make the inversion ambiguous.
- `distance_to_time` finds the segment by bisection and interpolates in `f64`; outside the range it
  gives the time of the nearest end.

## Verification

- `mirai test std/anim` with the affected cases of `inertial_test.odin`, `warp_test.odin` and
  `matching_test.odin`:
  `match_database_finds_each_frame_by_its_features_and_the_clip_a_trajectory_asks_for`,
  `match_search_skips_runs_by_their_bounds_and_enters_a_mode_by_its_entry_clips`,
  `match_search_leaves_out_rows_near_the_playing_one_across_a_loop_seam_and_those_just_left`,
  `match_trajectory_follows_a_walk_that_accelerates_brakes_and_turns_at_its_rates`,
  `inertial_offsets_never_overshoot_and_drop_a_velocity_that_heads_away_from_the_target`,
  and `transitions_that_interrupt_each_other_give_up_the_time_the_one_before_left_undone`.
- The hostile cases accept `ANIM_INERTIAL_HOSTILE_ROUNDS` and `ANIM_WARP_HOSTILE_ROUNDS`; when
  changing validations or state, repeat them with `--release` and 20000 rounds.
- Pose and stride warp are run with null allocators: e.g.
  `pose_warp_preserves_identity_and_rotates_the_source_knee_planes_without_ik` and
  `pose_stride_warp_scales_each_foot_from_its_hip_and_preserves_the_source_knee_side`.
