# Presentation rate and numeric jobs

## Animation_Budget

`Animation_Budget` goes on the rig that has `Animation` (its meshes with `Pose_Source` read that
policy): `period` is the minimum of render frames between palette updates and `significance` its
priority. `period` 0, the default, is automatic: each mesh waits, in seconds, while its pose moves
on screen less than the eye tells from a continuous motion (`budget_interval`, from the pixels of
`core.View` its bounds cover), and updates before the next frame would pass that wait, so fewer
frames a second never make it wait longer.
`Animation_Budget_Config` is the project configuration: `max_palette_updates` at 0 leaves all
palettes eligible and, otherwise, limits how many meshes are updated per frame (each mesh may have
other joints and another space); `job_grain` is how many jobs a range takes and `parallel` uses the
application's scheduler.

## Selection

- The priority combines how much of its wait each palette waited and its significance, with the
  entity index for ties; the growing wait prevents a lower priority from being left unpresented.
- New, reloaded, rebound or Edit-evaluated palettes are forced even if the limit has already been
  consumed.
- A palette that does not meet the period or is left outside the limit keeps its previous output;
  the external placement of the mesh keeps being updated.
- `Budget_Runtime` (world state, copyable for Play and snapshots) stores the last update per slot
  and generation, the selection and the `evaluated` and `throttled` statistics.
- `budget_select` receives candidates, frame, its seconds and configuration: it rejects invalid
  periods or significances and repeated slots in linear time; a frame that goes backwards resets
  the ages; it sorts by priority only when the limit excludes eligible palettes. Stable frames reuse
  the buffers that `budget_prepare` sizes.
- The automatic period is presentation only, like the rest: the world after the same ticks does not
  depend on it, so replays and seeks match. It does not test visibility.
- It only reduces the presentation rate: clocks, curves, events, actions, root motion, grounding,
  constraints and sockets are evaluated on every fixed tick. The full palette is computed; bones are
  not removed or LODs chosen.

## Parallel execution

`animation_skin` prepares assets, meshes and GPU on the owner thread, builds one `Pose_Palette_Work`
per palette (parents, previous and current poses, joints, mesh space and exclusive buffers, without
names or reference pose) and calls `pose_palette_batch`.

- The same path serves with zero workers, with `parallel=false` or with the scheduler; without
  chosen palettes there are no jobs and with up to `job_grain` it computes on the owner thread.
- Each job interpolates TRS, composes the global pose with `pose_world` (validating parents and TRS
  in the same pass) and converts the joints to skin matrices.
- `Palette_Workspace` keeps the memory ranges already checked: each call compares address, length
  and access of the buffers and only sorts and checks exclusivity when something changed or the
  previous check failed. Every overlap where some access writes is rejected, also in budget subsets.
- Workers do not load assets, do not allocate, do not access the world and do not write the GPU;
  each job publishes only its buffers and `ok`, and an invalid preparation clears all the `ok`
  first. After the barrier of [std/jobs](../../mirai-std/references/jobs.md), the owner thread
  uploads the valid palettes and publishes the draws.
- An invalid input or upload does not publish that draw and is a problem of the entity
  (`animation.skin_*`); an out-of-range policy turns the budget off that frame and is
  `animation.budget_policy` of the rig.
- Capacity changes or reloads may allocate; the stable path reuses jobs, scratch and palettes.

`animation_sample` blends the poses of the tick the same way, between two passes of the owner
thread: the first advances the clocks, events, actions and layers of each entity in order and the
last takes pose requests, root motion and warping.

- A pose job blends the clips, layers and program of its entities and samples their curves: it
  writes only the state of each entity and the scratch of its job (`Pose_Scratch`, sized when
  bindings are built), reads the libraries and the transforms of the tick, and does not allocate,
  touch requests or events, or report: what it could not do (`Pose_Faults`) is reported after the
  barrier, in the order of the entities.
- Each entity is independent, so the poses do not depend on `job_grain`, on the workers or on
  `parallel`.

## Verification

- `rig_poses_do_not_depend_on_how_their_jobs_are_split` (`skeleton_test.odin`): the same poses on
  the owner thread and in jobs of two grains, without allocations in a stable tick;
  `poses_by_track_match_the_pose_each_track_gives_by_name` (`pose_tracks_test.odin`): the blend
  by bone against each track found by name, under cross-fades, masks and additive layers.
- `budget_test.odin` (`plugins/animation/runtime`): automatic wait by size and frame rate, period,
  priority, limit, forced update, frame
  going backwards, sparse slots, copies without allocations, identical poses and palettes with zero
  and two workers, rejection of aliases and invalid inputs, and workspace intact on a growth
  failure; `the_automatic_period_leaves_the_simulation_as_it_is` (`skin_test.odin`, GPU).
- `world_poses_validate_topology_values_and_aliases_without_a_reference_skeleton` (`std/anim`):
  size, topology, TRS, overflow and aliases of the public composition, including `pose_world`.
- `skeletal_instances_use_independent_dense_poses_and_eighth_influence`: preparation, batch, upload
  and readback with independent poses, with [graphics validation](../../mirai-rendering/SKILL.md).
