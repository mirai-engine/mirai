# Layers and actions

The layers and actions of the `.character` an entity plays are the one stack of what it plays
over its base (the locomotion of the set, or the clip of `Animation.clip` when the set has no
match clips) and the actions `play` asks for by name. Gameplay
sends requests and consumes one event queue; the component keeps its configuration.

## The layer stack

`Action_Profile.layers` are the layers of the stack, in order; each goes over the base and the
layers before it. `Playing.asked` holds what each slot plays in a tick (`stack_asks`, then the
actions over it), and `layers_advance`, `pose_layers` and the curves read only that.

- A layer plays by itself a clip (`clip`, of another `.anim` with `animation`, [multiple
  sources](animation.md#multiple-sources)) or a [space](animation.md#additive-spaces) of the
  set, or nothing until an action plays in it.
- `over` limits it to the branch of a bone or to a part or region of the body (`@upper_body`);
  empty is the whole pose. `mode` is Override (each channel its clips animate goes to their value
  by the weight) or Additive (it adds what they change from the pose at `reference` seconds of
  `reference_clip`; none: of each clip itself). A target the reference clip does not move is
  measured from the layer's own clip. With `mesh_space`, an Override layer blends the rotations of
  its branch in the space of the rig: it keeps the turn its clip gives it whatever the base turns
  above it.
- `sync` keeps the phase of its clip on that of the base, by markers when both have them.
- **A parameter is a name of the set.** The name of a layer is its weight, from 0 to 1, reached
  over its `fade`; the name of an axis of its space is where the space is sampled, clamped to the
  range of the axis. `set` stores it in the state of the entity until set again (it is copied with
  the world, not saved); one that names nothing is the problem `animation.parameter` and is
  dropped. Two clips mixed by a value are a layer whose weight is that value.
- Slot 0 is the whole body, for the actions that name no layer; slot n is layer n-1.
- The stack composes over any base: over locomotion the layers go over the matched pose after its
  inertial transition, so an aim space adds over the walk the search plays.
- What a layer cannot play is a problem of the entity that names the layer (`animation.layer_clip`,
  `layer_bone`, `layer_reference`, `layer_space`).

## Profile and authoring

The actions of a set are layers, definitions and sections over the `.anim` of the set.

- Each action names its clip, the `layer` it plays in (empty: the whole body), root, weight,
  positive speed, fades, priority and cancellation, where it starts (`entry`: at its start, at
  the time of the base clip, or at the phase of its markers) and where it ends (`exit`, a share of
  its clip, or `exit_marker`; with sections, its last one).
- `clock` is `Own` (default: the entity's own time, slowed or sped up with its `core.Own_Pace`)
  or `World`: the action plays at its speed in world time while its entity is dilated, as a clip
  whose play rate makes up for a slow motion (a charge that plays at full speed while its
  character is slowed). Windows of an ability that follow it count `World` time too.
- Layer and action names are unique, and those of sections within their action.
- **Spans live on the clip.** A section is the span of its name on the clip of its action (a
  marker with a duration, `animation.marker.set`), and the other spans of that clip are its
  windows: the set names spans, never seconds, so retiming a clip keeps its sections and windows.
  A section whose span the clip lacks is the problem `animation.action_section`.
- A combo whose parts chain pose to pose is one clip cut in sections: the game jumps to the next
  part with `play` and the section when the current one reaches its end section, so nothing
  crossfades.
- `animation.action.set` resolves names and derives quantities. The `next` of a section links
  another of the same clip, regardless of row order, and empty ends the action. Without sections
  the clip is played to its exit; with them it starts at the first of the action or at the one
  `play` asks for. Files and history: [authoring](animation-authoring.md#files-and-history).

## Requests and lifecycle

`play`, `stop`, `set` and `look` write to `Animation_Requests`; the equivalent API asks for
Play/Simulation. `animation_sample` serves them.

- **One priority rule.** `play` takes the slot of its action if nothing plays there, or if its
  priority reaches the one playing and that one allows it: Allow gives way at once, Finish_Section
  defers until its section ends and Deny refuses. `stop` ends an action by the same policy. The
  slots are independent: an action in a layer plays whatever the whole body does.
- `play` with a section of an action that plays moves it there, closing and reopening windows,
  without starting it again.
- **In a layer** an action crossfades over what the layer plays (`fade_in`), at its weight, and
  when it ends the layer goes back to what it plays by itself over `fade_out`.
- **Over the whole body of locomotion** it is the clip of the program: it leaves the search through
  an inertial transition of `fade_in`, the action keeps its clock (sections, exit, markers), and
  when it ends the search takes the rig back in the mode the body is in, through `fade_out`. It
  does not depend on the locomotion mode: physics writes the mode, and the action goes on through
  its changes. Over a clip it is a layer under the others, over the whole pose.
- A rejected request is a problem of its entity (`animation.action_*`) that says how to fix it; an
  event that does not fit is `animation.events_lost`.

**One event log.** `Animation_Events` gives each reader what is new to it and carries, in the order
they
happened, Marker (of any clip; `action` says which action played it), Started, Ended,
Interrupted, Section, Span_Begin and Span_End (the windows), with hashes that the API returns as
names. To ask what an action is doing instead of following its events, `action_playing(runtime,
entity, name)` (with a read-only `core.Ref(Action_Runtime)`) gives its time and section hash while
it plays, from `play` until it ends or is interrupted (not while it fades out).

- An advance that crosses a whole window emits Begin and End; an exit or interruption closes the
  open ones. Jumps only process played intervals.
- Sections advance by segments; the player advances only once through those intervals and
  `layers_advance` carries fades and outgoing clips. Markers use the player's filters.
- Removing or changing the set, or a new revision of it, interrupts the active actions
  (Interrupted) and their layers fade in the `fade_out` of each, like any other interruption: the
  slot keeps the speed, fade and body policy it was played with while it fades out.

Discovery and memory:

- It is discovered from the `core.changes` of `Animation`: it looks only at the rows written since.
  The ticks prepare only the states with a set or a pending fade; an index per entity and
  generation resolves requests and sampling in constant time and is updated when compacting.
- Plans and states are copied with the world without pointers to the host cache, whose indices check
  the full id. A plan resolves once the slot of each action and what each layer asks for by itself.
- Preparing may allocate on load or reload; stable ticks reuse capacity. If it cannot be prepared,
  the request queue stays and what it saw of `Animation` is not kept; an OOM when preparing a plan
  keeps the previous plan and state and the requests of that entity wait, also before the first
  bind.

## Root and movement

- Extract and In_Place ask for the whole body, or an Override layer without `over`, root metadata
  and a resolved bone. In a layer, bone and channels must be consistent with the base, the
  outgoing clips and the other active root actions; an incompatibility interrupts the action and
  reports why.
- A rig that takes the sampled pose of another (`Pose_Source` of stage `Sampled`) shows what its
  source plays: its actions are asked of the source rig.
- In a layer, Extract adds the played segments and blends with the base delta by the weight of
  layer, component and fade. In_Place delivers the delta and removes only its contribution to the
  internal root, without moving the gameplay transform; partial, it leaves the movement of the
  base that it does not cover. The layers blend both policies with the weights of the pose, also
  on exit. Over the whole body of locomotion the root delta is that of the program, by the policy
  of the action, or of the component when the action has none.
- **Any action moves its body by its root motion with `body_move`** (Additive or Override, with
  `root_motion`; In_Place keeps the pose on a moving body), in a layer or over the whole body.
  `animation_body_motion` gives the share of the root delta of the tick that those actions have,
  not what the base keeps, mirrored and warped with the root, with the mix of the one with the
  most share; a finishing slot keeps the policy it was played with. With physics,
  `animation_physics` makes it a one-tick layered move of that mix for its `Character`, in the
  body's own time and across its up unless `body_vertical`, with the force that reaches it in that
  tick for the mass of the body, except while it mantles (the climb has its own). A game does not
  convert root motion itself, and passes no locomotion mode.
- `action_clock` gives the `Motion_Clock` of the dominant root when it reaches at least half the
  weight, for [motion warping](animation-motion.md). A discontinuous jump of section, or an action
  that ends or cancels while fading its root, suspends the warp without applying a window of the
  base to that delta.
- Advance by distance modifies only the matching active clip: the positive advance drives its clock
  and crosses contiguous sections; a discontinuity or an out-of-range time is rejected before
  changing anything. An explicit seek within the section repositions without markers, windows or
  root delta. It does not start actions or choose another section.

## Verification

`plugins/animation/runtime`:

- `actions_test.odin`: roundtrip of layers and actions, the table of what a set refuses, windows and
  sections as spans of the clip in one queue, cancellation, copies, queues, weighted extraction,
  clocks and distance; the query through play, section and stop; discovery by stamp, lack of memory
  and generational recycling.
- `matching_test.odin`, over the locomotion of a `.character`:
  `an_aim_offset_adds_over_the_matched_pose_and_an_action_plays_over_both`,
  `a_play_gives_way_by_priority_and_cancel_policy_and_tells_each_change_once`,
  `a_whole_body_action_enters_at_its_start_time_or_phase_and_ends_at_its_exit_or_marker`,
  `a_whole_body_action_goes_on_when_the_body_changes_mode_and_stop_ends_it`,
  `a_whole_body_action_blends_inertially_from_the_last_pose_and_stable_ticks_do_not_allocate` and
  `the_root_motion_of_a_whole_body_action_moves_the_body`.
- `runtime_test.odin`, `skeleton_test.odin`: layers by weight, branch,
  region, additive reference and space of the rig, on the owner thread and in jobs.
- `discovery_bench_test.odin` and `program_bench_test.odin` (with `MIRAI_BENCH`): optional
  preparation without stable allocations, and the cost of a pose by base and layers.
- `an_action_that_moves_its_body_gives_it_its_share_of_the_root_delta`: a play, the share without
  the base and an action without `body_move`.

`plugins/animation_physics/runtime`:
`the_root_motion_of_an_action_that_moves_its_body_moves_its_character_for_one_tick` (mix,
own time, vertical about `core.Vertical`, no move while mantling).

`plugins/animation/editor` (with `-collection:plugins=<root>/plugins`):
`authoring_actions_test.odin` covers real JSON, defaults, names and preservation of asset and
history on failures.

In an open build, plays, stops and parameters (`actions`, `gesture` and `parameters` of
`animation.request`) are observed with `animation.inspect` part `Actions` and the preview with
trace; the image requires GPU execution.
