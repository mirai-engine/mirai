# Transform sequences

`Keyframe_Path` is a short local sequence of poses of an entity; for reusable content, several
tracks, markers or blending, clips are used (`.anim` played by `Animation`). Both use `std/anim` and
the common transform: do not activate both as writers of the same transform.

## Keyframe_Path

- It stores its frames inline (`lib.Transform_Frame`, up to its fixed capacity), without a
  controller, external clips or dynamic state in the component; `keyframe_path_default()` gives two
  identity poses. Math: [std/anim](../../mirai-std/references/anim.md#transform-sequences).
- The first pose is placed at the start (its `duration` is not used); each following one takes
  `duration` seconds from the previous one and waits `hold` before continuing. `Linear` interpolates
  position and scale with rotation slerp, `Step` keeps the previous pose until arriving and `Ease`
  reshapes each segment.
- The loop jumps to the start: for a continuous circuit, the last pose repeats the first one.
  `Ping_Pong` walks the timeline in both directions, waits included.
- `relative=false`: poses local to the parent (the default, to capture the gizmo). `relative=true`:
  offsets over the transform that the entity had at start; changing the speed does not recapture the
  origin and removing and re-adding the component starts a new instance.

## Runtime

- `keyframe_path_advance` evaluates in `fixed`. `Keyframe_Path_Playback` stores origin, time,
  completion and stamp, copyable for Play and rollback; `keyframe_path_progress` queries it and the
  game reacts to the end with its `ended`.
- It does not rewrite an identical transform and skips sequences that are paused, finished or with
  zero speed that did not change and have no requests. It respects the owner of the transform
  through `core.free`. Stable execution does not allocate; adding or removing entities or components
  is a transaction.
- `keyframe_path_request` enqueues in a fixed queue: Play and Pause keep the time, Restart returns
  to the start (or to the end with negative speed), Seek searches without advancing that tick and
  Speed changes the speed, also to the reverse. It returns `false` with a null entity, non-finite
  numbers, an invalid kind or a full queue.

## Inspector and API

- Details shows the parameters and one frame at a time (`Frame`, `Add`, `Remove`), with the
  inspector's per-gesture undo. `Capture pose` stores the current transform, also what was moved
  with the gizmo; `Copy source` takes the pose of another entity in the space of the owner's parent.
- To capture relative offsets, `Reference` is an entity different from the captured origin, with an
  invertible scale. The origin of a gizmo is not inferred nor is the mode of the sequence converted;
  the reference is tool state and the component stores only the pose.
- `animation.sequence.set`, `.frame.set` and `.preview` share implementation with the runtime and
  the editor transactions; the control is `sequence` of
  [`animation.request`](animation-authoring.md#per-instance-control-and-preview). `.preview` returns
  a pose without touching the scene; configuring and capturing are one undo step, and an invalid
  capture keeps scene and history.

## Verification

- `std/anim`: `transform_sequences_preserve_holds_easing_quaternion_arcs_and_reverse_time`,
  `transform_sequences_reject_invalid_input_and_bound_zero_length_loops`.
- `plugins/animation/runtime`:
  `animate_sequences_pause_seek_restart_reverse_and_skip_unchanged_transforms`,
  `animate_request_capacity_and_invalid_frames_do_not_write_transforms` (with null allocators).
- `plugins/animation/editor`:
  `sequence_capture_converts_parent_space_and_is_one_undoable_api_transaction`.
- Dragging the gizmo and capturing is tested by the user; contracts, captures and UI inspection, by
  API.
