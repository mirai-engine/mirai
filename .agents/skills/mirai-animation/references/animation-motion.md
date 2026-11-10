# Warping

The warping of the `.character` an entity plays: root motion windows, pose adaptation and
distance→time curves, without components per window, foot or operation. Math:
[std/anim](../../mirai-std/references/anim-motion.md).

## Definitions and state

- `Motion_Profile` is the warping part of the set; `Character_Assets` caches the set by full id
  and revision and keeps the definitions immutable between evaluations.
- A warp window (`Motion_Window`) corrects toward its target over the span of its name on the
  clip that leads the root (a marker with a duration on the clip, written once): axes in rig
  space, translation and rotation separately and intersected with the root that produced the
  delta. Retiming the clip moves the window with it; changing the target does not touch the
  definition.
- `Pose_Warp_Profile` warps the pelvis, spine and legs of the body of the skeleton:
  `orientation` turns the pelvis compensating the spine and `stride` scales the stride from each
  hip. The IK carries the flexion
  plane of the already-turned source pose to the new axis, without poles. A stride of one or an
  angle of zero leave the pose exact. It is applied before grounding and the constraints, after
  physics publishes the place of the actor. Below `MOTION_WARP_FADE_SPEED` of the body or of its
  clip it fades out with that speed, so a body that slows to a stop keeps the pose of the clip
  without the stride shrinking to its minimum on the way.
- A distance (`Motion_Distance`) is strictly monotonic keys of a clip. `motion_distance_time` gives
  clip and time without advancing the world; `motion_play_distance` and `animation_distance` enqueue
  that time for the active clip, without choosing another.

Advance by distance:

- It keeps events and root motion of the traversed interval. `distance_request_check` validates
  player, active clip, time, direction and clock before consuming; the API and the tick share the
  validator.
- Over locomotion it advances the clock of the clip that plays, and those in phase with it follow.
  A dominant action accepts the time if its interval is continuous.
- A regressive time asks for `seek=true`: it is a discontinuity, without events or root motion of
  what was skipped.

`Motion_Runtime` (of the world, copied for Play and rollback):

- Flat rows per rig with targets, resolved references and diagnostics. It is discovered from
  the `core.changes` of `Animation`: it looks only at the rows written since. `motion_prepare`
  resolves references when the set, revision or bind changes and compacts the instances that no
  longer play one; its index checks the generational handle.
- A failed reservation keeps the requests and does not keep what it saw of `Animation`.

## Requests and order

- `motion_target` enqueues by window name a [spatial target](animation-rigs.md#spatial-targets)
  that `motion_resolve_targets` places every tick before the rigs sample: a bone or socket reads the
  pose of the previous tick. If what it names is missing, the target stops being used and its last
  position does not remain. `motion_locomotion` delivers the velocity reached in world space
  (`source_velocity` is a manual mode for clips without root motion; zero uses the sampled delta).
- Goals persist until replaced, turned off or the set is removed; one accepted before the first
  tick is used after the bind of that tick. `motion_take_requests` does not change definitions.
- The source of the movement is captured before correcting the root delta, so that stride and
  orientation compare what was animated with what was reached.
- `motion_apply_root` corrects the delta before `physics_step`, with the clock of the leading clip
  and its remaining movement to the end of the window, from where the actor is in that tick. The
  translation is skewed (`std/anim` `root_motion_warp`): the linear map that takes the remaining
  movement to the target moves the delta, so each step carries the share of the correction that
  its movement is of what is left on the axes of the window (the bob of a hip the window does not
  warp does not count) and a step in which the clip stands still moves nothing; only a
  window whose clip does not move spreads it by time. The weight of the window is multiplied by the
  effective contribution of that clock (`Motion_Clock`; that of a dominant action is given by
  `action_clock`), or by that of the base; a zero contribution keeps the delta. An inactive action
  clock with a clip is a discontinuous section: it extracts by segments and does not warp that step.
- Prefixes and corrections pass between the space of the window and that of the rig keeping their
  axes under turns and uneven scale; if a step crosses several windows, they are processed by time
  even if the set lists them in another order.
- The controller consumes the delta through requests to physics, the only writer of the body's
  transform.

Limits of the correction:

- Windows go forward: seek, pause and zero velocity or dt leave the delta without warping; a
  negative velocity or a step of more than one duration keep the original movement and publish
  `Unsupported_Clock`.
- With several blended sources or weights below one the influence is partial; it does not guarantee
  arriving if the controller limits the delta by collision.
- `motion_apply_pose` modifies only the pose of the rig; grounding and IK adjust it afterwards.
- `motion_inspect` gives active window, error, source velocity and expected remaining error: what
  was requested, not that physics reached the endpoint.

## Authoring and control API

- `animation.motion.set` receives the warp, windows and distances of a `.character` as arrays and
  derives the quantities; on a `path` that has one it replaces its warping and keeps the rest of
  the set, the id and, on an error, the previous file. `animation.motion.distance` queries a time
  without touching clocks. Distance failures give the path of the invalid keys.
- `motion`, `locomotion` and `distance` of
  [`animation.request`](animation-authoring.md#per-instance-control-and-preview) require Play or
  Simulation. A target must be declared by a window of the set, and `distance` validates track
  and clock before enqueuing. The `locomote` intent uses the `locomote` window.
- `animation.inspect` part `Motion` shows state and targets of the rig.

## Verification

- `plugins/animation/runtime`:
  - `motion_discovers_changed_profiles_retries_first_targets_and_compacts_instances_in_world_copies`
    (discovery, copies and lack of memory).
  - `motion_warp_test.odin`: windows over the spans of the clip, monotonic curves, endpoint,
    targets, seek and reverse, action clock, prefixes with turns and uneven scale, several windows
    per step, bind by name, bone replacement and generational recycling.
  - `distance_test.odin` and `distance_integration_test.odin`: requests, capacity, stable memory and
    the tick with advance by distance; an independent source of a program is not accelerated.
  - `discovery_bench_test.odin`: optional preparation together with actions.
- `plugins/animation/editor` (with `-collection:plugins=<root>/plugins`):
  `authoring_motion_test.odin` covers counts derived from JSON, defaults, identity, errors with
  path, inverted distance, forward/seek requests and rejection of transient controls in Edit.
- The demo includes an [integrated tour](../../mirai-gameplay/references/animation-gallery.md) with
  a physics controller; the visual correction requires a build and a run.
