# Animation actions

`Animation.actions` references a shared `.action`. Gameplay sends requests and consumes their
lifecycle; the runtime plays each action in one of layers 1 to 3 over the `.anim` that the player
uses directly or as the source of a program. The component keeps its configuration: the evaluation
blends a local copy of its description.

## Profile and authoring

`Action_Profile` has definitions, sections and windows over an `info.animation` library.

- Each action names clip (of another `.anim` with `animation`, [multiple
  sources](animation.md#multiple-sources)), layer, `over` branch, Override/Additive mode, curve
  policy, root, weight, positive speed, fades, priority and cancellation.
- `clock` is `Own` (default: the entity's own time, slowed or sped up with its `core.Own_Pace`)
  or `World`: the action plays at its speed in world time while its entity is dilated, as a clip
  whose play rate makes up for a slow motion (a charge that plays at full speed while its
  character is slowed). Windows of an ability that follow it count `World` time too.
- Action names are unique and those of sections and windows, within their action.
- Actions that share a layer must have the same `over`, `mode`, `reference`, `curves`,
  `mesh_space`, `root_motion`, `body_move` and `body_vertical`, so that the outgoing fade keeps the
  policy of its channel.
- A combo whose parts chain pose to pose is one clip cut in sections: the game jumps to the next
  part with Section when the current one reaches its end section, so nothing crossfades.
- `animation.action.set` (with `path` or `asset`) resolves names and derives quantities. The `next`
  of a section links another of the same clip, regardless of row order, and empty completes the
  action. Without sections the whole clip is played; with them it starts at the first of the action
  or at the one Fire asks for. The ranges, in seconds, are positive and fall inside the clip. Files
  and history: [authoring](animation-authoring.md#files-and-history).

## Requests and lifecycle

`action_fire`, `action_cancel` and `action_section` write to `Action_Requests`; the equivalent API
asks for Play/Simulation.

- The layer of an action is reserved by leaving `Animation.layers[layer-1].clip=0`: Fire rejects a
  layer that the component occupies (`ReservedLayer`). A pose of `animation_play` faded to
  `animation_weight(…, 0)` keeps its clip to come back to, so it still occupies the layer;
  `animation_stop(animation, layer, fade)` fades it out and frees the layer in the same tick, and the
  action cross-fades from what is fading.
- Fire replaces the action of the layer if its priority reaches the active one and the active one
  allows it: Allow cancels immediately, Finish_Section defers the cancellation until the section
  ends and Deny rejects.
- Section repositions an active action in its named section and closes and reopens windows.
- A rejected request is a problem of its entity (`animation.action_*`) that says how to fix it; an
  event that does not fit is `animation.action_events`.

`Action_Runtime.events` is cleared every tick and carries Started, Completed, Interrupted, Section,
Window_Begin and Window_End, with hashes that the API returns as names. To ask what an action is
doing instead of following its events, `action_playing(runtime, entity, name)` (with a read-only
`core.Ref(Action_Runtime)`) gives its time and section hash while it plays, from Fire until it
completes or is interrupted (not while it fades out).

- An advance that crosses a whole window emits Begin and End; an exit or interruption closes the
  open ones. Jumps only process played intervals.
- Sections advance by segments; the player advances only once through those intervals and
  `layers_advance` carries fades and outgoing clips. Markers use the player's filters.
- When it ends, the layer fades to zero and returns to the description of the component. Removing or
  changing the profile, or a new revision of it, interrupts the active action (Interrupted) and its
  layer fades in the `fade_out` of that action, like any other interruption: the slot keeps what it
  last requested and does not depend on the new profile while it fades out.
- An action is what is added to the locomotion in a layer; what takes the whole body over a `.match`
  is `match_play` ([locomotion](animation.md#locomotion-by-motion-matching)).

Discovery and memory:

- It is discovered by the `layout/version` stamp of `Animation`: without writes it does not walk the
  table. The ticks prepare only the states with a profile or a pending fade; an index per entity and
  generation resolves requests and sampling in constant time and is updated when compacting.
- Plans and states are copied with the world without pointers to the host cache, whose indices check
  the full id.
- Preparing may allocate on load or reload; stable ticks reuse capacity. If it cannot be prepared,
  the request queue stays and the stamp is not confirmed; an OOM when preparing a plan keeps the
  previous plan and state and the requests of that entity wait, also before the first bind.

## Root and movement

- Extract and In_Place ask for a full-body Override layer without `over`, root metadata and a
  resolved bone; bone and channels must be consistent with the base, the outgoing clips and the
  other active root actions. An incompatibility interrupts the action and records a failure.
- An entity with `Animation.source` is a retarget destination: actions with a root are requested
  from the source rig, and Fire on the destination returns `UnsupportedPolicy`.
- Extract adds the played segments and blends with the base delta by the weight of layer, component
  and fade. In_Place delivers the delta and removes only its contribution to the internal root,
  without moving the gameplay transform; partial, it leaves the movement of the base that it does
  not cover. The layers blend both policies with the weights of the pose, also on exit.
- **An action moves its body by its root motion only with `body_move`** (Additive or Override, with
  `root_motion`; In_Place keeps the pose on a moving body). `animation_body_motion` gives the share
  of the root delta of the tick that those actions have, not what the base keeps, mirrored and
  warped with the root, with the mix of the one with the most share; a finishing slot keeps the
  policy it was fired with. With physics, `animation_physics` makes it a one-tick layered move of
  that mix for its `Character`, in the body's own time and across its up unless `body_vertical`,
  except while it mantles (the climb has its own). A game does not convert root motion itself.
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

- `actions_test.odin`: roundtrip, invalid references and policies, windows and sections,
  cancellation, copies, queues, weighted extraction, clocks and distance.
- `actions_retry_a_first_fire_when_profile_preparation_has_no_memory`.
- `action_playing_answers_while_an_action_plays_and_animation_stop_frees_a_layer_that_weight_zero_keeps`:
  the query through Fire, Section and Cancel, and a layer that weight 0 keeps and `animation_stop`
  frees.
- `actions_discover_changed_components_retry_requests_and_compact_generational_rows_through_world_copies`:
  discovery by stamp, lack of memory and generational recycling.
- `discovery_bench_test.odin` (with `MIRAI_BENCH`): optional preparation without stable allocations.
- `an_action_that_moves_its_body_gives_it_its_share_of_the_root_delta`: Fire, the share without the
  base and an action without `body_move`.

`plugins/animation_physics/runtime`:
`the_root_motion_of_an_action_that_moves_its_body_moves_its_character_for_one_tick` (mix,
own time, vertical about `core.Vertical`, no move while mantling).

`plugins/animation/editor` (with `-collection:plugins=<root>/plugins`):
`authoring_actions_test.odin` covers real JSON, defaults, names and preservation of asset and
history on failures.

In an open build, Fire, Cancel and Section (`actions` or `gesture` of `animation.request`) are
observed with `animation.inspect` part `Actions` and the preview with trace; the image requires GPU
execution.
