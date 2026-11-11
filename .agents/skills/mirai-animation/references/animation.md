# Animation

`animation` is an optional plugin with Runtime and Editor; it is activated in `project.mirai` and
imported as `anim "plugins:animation/runtime"`. Math:
[`std/anim`](../../mirai-std/references/anim.md); bind:
[assets](../../mirai-assets/references/formats.md); imported hierarchy:
[imports](../../mirai-imports/references/imports.md#skinned-meshes). The code plays clips, drives
locomotion by motion matching and plays over it the [layers and actions](animation-actions.md) at
the game's request, all of one `.character` set; there is no state machine or graph ([what replaces
them](#what-replaces-the-state-machine)). The [authoring by API](animation-authoring.md) edits
everything with names and history.

## Components and shared data

Components (`@(component)` of `plugins/animation/runtime`):

- **`Animation`**: an `.anim` (a clip of it) or a `.character` and playback; alternative library,
  mirroring and root motion.
  **`Animation_Progress`** stores where its clip is ([storages](#storages)).
- **`Pose_Source`**: the one link by which another rig drives a pose. At stage `Finished` another
  mesh shares the evaluated pose of a rig of its skeleton or, with a skeleton of its own,
  [follows it](#following-a-rig-of-another-skeleton); at stage `Sampled` a character of other
  proportions [plays its sampled pose](#offline-and-live-retarget).
- **`Bone_Attachment`**: on each equipped object, references a socket of the skeleton.
- **`Animation_Budget`** ([budget](animation-budget.md)) and **`Morph_Weights`**
  ([morphs](animation-morphs.md)).
- **`Animation_Target`**: internal identity of an imported rigid destination, hidden in the
  inspector; the visible name of the entity may change without losing it.
- **`Skin_Part`**: a bone of the skinned mesh, with what hangs from it, is a part in those layers. A
  camera that does not draw them, or that leaves them out of its player's body (`own_hidden`), draws
  it collapsed onto the bone; the other views, the shadow and the reflections draw it whole. It is
  the head of a single-mesh character seen from its eyes ([own
  body](../../mirai-gameplay/references/control.md#following-cameras)).

Rigs:

- A rig is the entity with `Mesh_Renderer` whose mesh references a `.skeleton`, without a
  `Pose_Source` to a rig of that skeleton; it does not need `Animation` for a procedural pose. Each
  rig has its own pose even if it shares mesh, skeleton, clips and set.
- The skin (weights, joints and inverse binds of the `.mesh`) is a static link; `Pose_Source`
  references a dynamic pose and stores neither weights nor bones. The prefab creates no entities per
  bone.
- The list of rigs is reviewed when meshes, `Pose_Source` or the asset registry change; its revision
  changes only if the entities or their skeletons changed. An unrelated reload does not rebuild
  constraints or reset springs.

The `.character` set:

- One asset holds what a character plays and adapts, as typed tables: its locomotion (match info,
  clips and blend samples), the stack of layers, the actions and their sections, the aim and
  additive spaces with their samples, the warp of the pose and the warp windows, distance tracks,
  and the modifiers (IK, Look, limits, grounding, rigs, curve poses). `Animation.asset` names it;
  it names the `.anim` of its clips, and a set of only modifiers (a rope) names none. It is shared
  by every character of its body and creates no components per row.
- Limbs and pelvis are those of the body of the `.skeleton`: no table names them again, and a
  `Bone_Ref` in a row only overrides the part. A section, an action window or a warp window is a
  span of the clip (a marker with a duration), named by the set, never seconds in the set.

Shared assets:

- Skeletons, skins and sets are read through the registry with `host.assets_file`, like the `.anim`:
  an asset a step has not flushed yet is seen like one on disk.
- Each cache looks at the registry only when `assets_stamp` advances and rereads the file whose
  registry entry changed.

Bones and modifiers:

- `Bone_Ref` accepts a canonical path or a unique short name; an invalid or ambiguous reference does
  not select the root. `animation_bone_bind` gives a `Bone_Handle` that a new revision of the rig
  invalidates.
- A `Bone_Ref` that starts with `@` names a part of the
  [body](../../mirai-std/references/anim-body.md#body-map-bodyodin) that the `.skeleton` stores
  (`@hand_l`, `@knee_r`), not a bone: the same set serves skeletons with other names. In the `over`
  of a layer it also names a region (`@upper_body`, `@arm_l`), which wins over the part of the same
  name (`@head`). It is resolved when binding the rig: correcting the body with `skeleton.body.set`
  binds it again. A skeleton without a body, or without that part, gives the consumer's problem with
  how to give it the body.
- The modifiers of the set (`Pose_Profile`; `mirai asset` inspects it) are typed tables of IK, Look,
  limits, [grounding](animation-grounding.md) and the operations of [rigs](animation-rigs.md); the
  per-entity routing fields are transient. A contact (a hand on a ledge) is an IK row with a spatial
  target held in the world; the ground is grounding. The last bone of an IK keeps what its `hold`
  says: its rotation in the world (a foot), relative to the joint (a hand in line with its forearm)
  or that of the target, and its `reach` softens and stretches it as a chain's. Look aims the ray
  from its `offset` (the eyes of a head, the muzzle of a held gun), not from the bone; with
  `use_up` it turns the `up` axis of the bone toward `world_up`.
- A target is a [`Spatial_Target`](animation-rigs.md#spatial-targets). No operation gives
  physical balance or self-collision of the character.

Targets and controls:

- `modifier_goal` changes the target of an operation of an instance through `Animation_Requests`;
  `modifier_control` regulates an independent influence multiplier, with a smoothstep fade from the
  current influence. They are chosen by name or slot
  ([rigs](animation-rigs.md#requests-and-diagnostics)).
- A control keeps targets, poles, hits, strengths and contact. Deactivating fades to zero and then
  turns the solver off (grounding releases its supports); zero weight with `enabled` keeps the state
  and the input pose; repeating the same control does not restart the fade.
- Controls and targets persist per operation (and effector) while the operation exists, and the bind
  applies them again even if their fade has ended.
- The queues reject non-finite values and excess capacity. Stable requests and fades do not
  allocate, do not resolve bones again and do not walk the controls of other rigs.
- An OOM when loading or reloading sets or skeletons keeps the previous runtime, does not
  publish empty tables and retries.

### Following a rig of another skeleton

A mesh whose `Pose_Source` of stage `Finished` names a rig of another skeleton (a head with the
neck of the body and the bones of its face) is a rig of its own that follows it: `Rig.leader`.

- Its bones take the finished pose of the rig's bones of their name (after its constraints, IK and
  grounding), or of their path where a name repeats; the bones only it has keep its own animation,
  its `Animation` and its set, under the parents that now move. The pairs are made when either
  binds its skeleton, never per tick.
- The curves that the leader animates replace those of the follower's animation; the others stay.
  Its morphs read the follower's curves (`source_kind` `Own`).
- In `animation_finish` a follower goes after its leader, which may follow another, in one pass:
  `rigs_update` orders the followers by how many leaders are above them when the rigs change
  (`Playback.follow_order`), and a loop goes last and is the problem `animation.follow_rig`.
  Skeletons without a common name are `animation.follow_bones`.
  The finished pose of a leader in the world is made once per tick for all of its followers
  (`Playing.world_final`).
- Its own set applies after the follow: [curve poses](animation-rigs.md#curve-poses-and-drives)
  of its face, its sockets and its rigs. It lies where its leader is in the world: its entity may
  sit anywhere.

Sockets:

- `Skeleton_Socket` (name, bone and local TRS) lives in the `.skeleton`; each equipped object
  carries its `Bone_Attachment` and its instance offset is composed after the shared one. Imports
  create sockets for rigid objects attached to bones.

## Locomotion by motion matching

The locomotion of a character is the match of its `.character` in `Animation.asset`; there is no
state machine or locomotion blend space.

The match of the set (`Match_Profile`):

- Clips of an `.anim` library ([multiple sources](#multiple-sources)), each with the locomotion
  modes it serves (bit `m` for mode `m`: the values of physics' `Locomotion_Mode`) and, if it starts
  a mode (jump, landing), the `entry` mark. An entry clip does not loop. `speed`, when positive, is
  the one the clip travels at instead of the one measured from its feet. `mirror` `Both` also
  searches its rows with left and right swapped (a left turn or a left-foot start gives the right
  one), `Only` only those; a picked mirrored row plays the clips of its source reflected
  ([mirroring](#mirroring)), its root motion and warping clock with them. A mirror on a skeleton
  whose bones do not name their sides is the problem `animation.match_mirror`.
- A source with `blend` is a blend (the motion matching form of a sampled blend space): its clip and
  those of `blend` loop and are in phase, whatever their durations. Each `Match_Sample` of it
  (weights per clip, as shares of their sum, and an optional `speed`) is a range of rows of its own,
  measured from the pose the program blends of those clips at its weights over the mean of their
  durations by weight; when the search picks one, the program plays those clips together,
  synchronized in a `Weighted` group at its weights and the rate of matching, each at the same
  share of its own duration. Jumps between samples or clips are ordinary transitions. A blend that
  names a clip the library lacks is the problem `animation.match_blend` with the clip.
- The feature database (`std/anim/matching.odin`: feet, hips, the velocity of the body, where it was
  1/3 s before and the trajectory at 1/3, 2/3 and 1 s in the frame of the character, normalized per
  type) is built at load, the first time a rig of that skeleton asks for it, per library and
  skeleton, and lives in `Character_Assets`. `memory` is its cap: a larger database is not built and
  is the problem `animation.match_memory`.
- The search is linear and SIMD on a small database; past `MATCH_LINEAR_ROWS` rows the database
  stores bounds per runs of rows and the search skips those that cannot improve. It chooses by
  itself.

Per tick:

- `match_goal` says the mode, the velocity of the body, the desired one with its acceleration and
  braking, where it turns, the wall it leans on and when it lands ([landing](#landing)). With
  physics, the automatic plugin
  `animation_physics` says it for each `Character` with `Animation` (the `Character` is the only
  writer of the mode, and its `Character_State` of the wall; animation keeps no copy) and asks for
  the warping of the set while it walks: the game writes no locomotion code. The model
  on the `Character`'s entity faces its -Z, as the body does
  ([facing](../../mirai-physics/SKILL.md#library-invariants)): it is not turned by hand. Without
  physics, the game calls `match_goal` with what moves its rig.
- While a `Character` mantles, `animation_physics` gives the warp window `mantle` of the set the
  target `mantle_to` and drives the climb with the root motion of the tick: a climb clip with a
  root and a span `mantle` climbs as the clip does and lands on the ledge.
- With `lag` (for a body that stops or starts harder than its clips; off by default and in
  `animation.character.setup`), the root of the pose follows the body by a critically damped spring
  of `lag_half_life`: a change of velocity the body makes at once the root takes in over the
  half-life, never farther than `lag` from the body nor into the wall of the goal. It returns onto
  the body only while the pose walks, at most `MATCH_LAG_CLOSE` of the speed of its clip, so a pose
  that stands holds its offset instead of sliding its feet. The bones right under the rig move by
  that offset after layers and warping. Matching,
  the rate of a loop and the stride warping follow the velocity of that root. With `lag` 0 the root
  stays on the body.
- Every `interval` (0: every tick) it searches the lowest-cost row among the clips of the mode; a
  clip that travels is compared with the trajectory scaled by the rate at which it would play
  (`min_rate`..`max_rate`, those of its `Match_Source` when it has them), so a few clips cover the
  velocities between theirs. The trajectory does
  not go into the wall of the goal. It jumps only if it saves `bias` over continuing, and not
  sooner than `hold` after the last jump unless something forces it. It does not jump to rows of
  the clip that plays within `reselect` seconds of its row (around the seam of a loop), nor to
  those played in the `reselect` seconds before the rig left them; with `keep_loop_phase`, to no
  row of the loop that plays. A clip without a loop that ends, or that enters its last trajectory
  window, is left whole, because its still pose, or its tail again, would win all the searches.
- With `stationary_speed`, a root slower than it plays only the clips that stand and a faster one
  those that travel, loops or not (entry clips are not filtered); a loop that does not move as the
  root does searches in that tick, without waiting for the interval, the hold or the bias, while a
  clip that plays once goes on until it ends or a search leaves it. Only a loop follows the speed
  of the root with its rate; a clip that plays once (a jump, a landing) keeps its own.
- Entering a mode that has entry clips searches only among their starts; without them, among the
  clips of the mode. An entry clip does not take part in the continuous search, except to keep
  playing it.
- With nothing of the database playing (the first search, a swapped library, a mode the clip that
  plays does not serve), the search asks for the feet the rig has and how they and its hips move
  with the body, from the pose of the last two ticks, not for the mean of the database.
- Every jump enters through an inertial transition of `blend` seconds: it captures pose and
  velocity and evaluates only the target with decaying offsets, so the target keeps its own motion
  (its planted feet). The capture is of the boundary before the new advance, before the layers of
  the stack; a tick with zero dt leaves it pending.
- A weapon's clips are an `.anim` with the clips of the set under the same names in
  `Animation.library`: changing it keeps the body, the lag and the mode, searches the new clips in
  that tick and enters the one it picks through the same inertial transition (`blend`). The data of
  the entity or its weapon names that library (a component field, `kind=.anim`), so it loads with
  the scene and Play and is cooked; a library still compressing when it is swapped in takes over
  once loaded, and meanwhile the entity plays on the library it had, with its actions.
- `animation_match` says which clip plays, its rate, its mode, whether a whole-body action covers
  the search (`forced`) and how many searches and jumps it made.

A whole-body action (`play` of an action that names no layer: vault, hit, death) fades in over the
search, which goes on under it in the mode the body is in, and fades out when it ends
([requests and lifecycle](animation-actions.md#requests-and-lifecycle)).

### Landing

A jump lands on time with no game code: its clips carry the marker `landing_marker` of the set
at first contact, and `animation_physics` gives `time_to_land` of the goal: while the
`Character` falls and the clips of that mode carry the marker (`Animation_Match.landing_modes`), it
asks physics where its arc lands (`character_landing`).

- With a time to land and clips of the mode that have the marker, every search (on entering the
  mode, and each `interval` in the air) weighs only the rows in the window of the landing: their
  next marker is reached at a rate of `landing_rates` within half a row, and in the air not further
  than that of the row playing (the arc only goes on). It plays the chosen one at that rate:
  entering, the entry starts first, then (off a ledge, a short fall) any row of the clips of the
  mode, entry or not. A body whose velocity changes in the air moves to the clip that fits, its
  marker still on time.
- Each tick the rate follows the time to land physics gives; the clip searches again only when no
  landing rate reaches its marker. One that passes its marker in the air matches again, and plays
  on unless a row fits better by `bias`. Without a marker or a prediction it matches as before.
- A clip at or past its marker when the body changes mode plays on in the new mode, its tail
  bound only by the clip: until it ends or a periodic search leaves it.

## Additive spaces

A space of the set: aim offsets or additive poses placed on one or two axes, named by the `space`
of a layer ([the layer stack](animation-actions.md#the-layer-stack)); a layer that names a space
the set lacks is the problem `animation.layer_space`.

- Each axis has a name and a finite range; the authoring points use those units and are normalized
  per axis. 1D interpolates two neighbors and 2D a triangle (`blend_space_prepare`); outside the
  hull it is projected to the edge. Duplicate points, degenerate geometry and invalid axes are
  rejected. Buffers: [std/anim](../../mirai-std/references/anim.md).
- The parameter with the name of each axis (`set`) gives X and Y; `blend_sample` queries weights
  from code. The layer blends the clips of the place by their weights, each looping at its speed
  on the clock of the layer; they fire no markers.

Program buffers:

- The program of a set reserves its players and the room of its pose when it binds or
  reloads, and the ticks reuse it. World copies have their own buffers. Clocks, matching and
  inertialization belong to the player and are copied with the world; the definition, its
  geometry and the matching database belong to the shared asset.
- A failed reservation keeps the previous output and retries on the next tick.

## What replaces the state machine

What used to be a state or a transition has its owner:

| Before | Now |
| --- | --- |
| Locomotion states (idle, walk, run, fall, swim) | Modes of the set's match, read from physics |
| Transition by velocity or by ground | The matching search; a mode searches its entry clips |
| Jump or landing state | `entry` clip of the mode (falling, walking) |
| State of a whole-body action (vault, death, emote) | `play` of an action without a layer |
| Layer of an action (wave, reload, upper-body hit) | `play` of an action in a layer of the set |
| Locomotion blend space (velocity, direction) | Match clips and blends sampled by weights |
| Aim offset, breathing, lean | Additive layer of the set: a space or a clip, by `set` |
| Blend of two clips by a value (a mood) | A layer whose weight is that value (`set`) |
| Animation graph of layers, blends and additives | The stack of layers of the set |
| State trigger or event | `play`, and `Animation_Events` |
| Waiting for an animation to finish | Ended of its action |
| Game logic by states (AI, menus) | Game data and its functions; AI, in `std/ai` |

### A game with a handful of authored clips

Motion matching does not need a motion capture database: a port of a game whose characters have
one clip per thing (idle, walk, run, an attack, a death, a scripted entry) maps each clip to its
owner and keeps no clip choice in game code.

- **Locomotion.** `animation.character.setup` with the library classifies idle, walk, run and
  sprint by their names (a prefix such as `ai_zombie_base_walk_v1` still has `walk`). Three
  clips cover every speed between theirs through the rates of the set. An in-place clip
  travels at the speed its feet push at; one whose feet slide (a shamble) gets its speed from
  `speeds`. A skeleton from another engine needs its body first (`skeleton.body.detect`, or
  `skeleton.body.set` for the feet and hips it does not recognize). The game sets how fast the
  body goes (`Walk.max_speed`, which a `Nav_Agent` walks at too), never which clip plays: a
  faster gait (a round that makes enemies run) is a higher speed, and the search moves to the run.
- **Variants of one character.** A crawler or a heavy enemy with other clips under the same names
  is another `.anim` in `Animation.library`, which the data of the entity names.
- **Whole-body moments.** An attack, a death, a rise from the ground or an entry through a window
  is an action without a layer, with its exit at the end or at a marker and a priority: the death
  above the attack, the attack above nothing. An entry aligned to a place (a window, a board) is
  one with `body_move` and [root motion directed at a
  target](../../mirai-std/references/anim-motion.md#root-motion-directed-at-a-target).
  The game reacts to `Animation_Events` (Ended, Interrupted and the markers of the clip, such as
  the hit of an attack or a footstep), not to which clip it asked for.
- **Upper-body moments.** A reload, a swing while walking or a hit reaction over the legs is an
  action in a layer of the set.
- **Props.** A board, a door or a lever that only plays its clips is not a character:
  `animation_clip` of the clip is enough, and its markers arrive in `Animation_Events` all the same.

## Playback, outputs and order

`Animation` plays an `.anim` or a `.character`.

- `library` replaces the clips of a set with another `.anim` with clips of the same names: a set
  serves characters with their own clips, and its locomotion, layers, actions and warping use
  it. An
  explicit `animation` does not change and over a direct `.anim` it is not evaluated. Changing it
  restarts the program; an absent clip is `Missing_Clip`.
- Over `.anim`, an empty clip chooses the first. The defaults are `ANIMATION_DEFAULT`.
- **What the editor plays is preview.** While the world does not play (Edit), clips sought by the
  Tracks head, the actions a timeline drives and the editor's previews live only in derived
  storages and queues, never in a component: a save or a Duplicate holds none of it. On the first
  tick that plays, as in the copy Play starts from, `animation_requests_serve` starts every clip
  again from its component, drops every action and the plays, seeks and distances left queued.
- What plays over the base is the stack of the set
  ([the layer stack](animation-actions.md#the-layer-stack)); `animation_clip` changes the clip of
  the component.

### Multiple sources

An entity blends clips of several `.anim`: the `animation` of a match source, of a sample of a
space, of a layer, of an action or of a distance track of the set names the `.anim` of its clip;
empty takes that of the set or `library`.

- The `.anim` of the asset is the main source and its clips keep their name; `source_clip_name`
  names that of another source in the library that joins them. Two clips that coincide after joining
  give `Invalid_Asset`.
- `Source_Assets` prepares one library per set of sources, shared by entities and worlds. A tick
  without asset changes reuses the plan without reading them; it is joined again when the file or
  the generation of a source changes. Without memory or with invalid sources the published library
  stays.
- A marker carries the `.anim` of its clip in `animation`. `animation_playing_content` gives the
  library that an entity plays; `source_clip_source` and `source_clip_label`, the `.anim` and the
  name of one of its clips.

### Storages

- `Playback` (world storage): clocks, fades, program and dense pose buffers; curves and root delta
  per player. It is derived: clearing the world (loading a scene or a save) starts it over, like the
  other animation storages.
- A state knows which of its bindings each track of its content moves (`Track_Map`), paired when
  its bindings are built and shared by the states bound alike to that content: clips and layers
  blend by bone ([by bone](../../mirai-std/references/anim.md#blending-poseodin)), never by the
  name of a target, for rigs and for the entities an `Animation` moves by name alike.
- `Animation_Progress` is written only by `animation_sample` while the game runs: a stored save
  keeps the time of the clip and, when loaded, an entity without state in `Playback` asks for
  `animation_seek` there.
- The runtimes of modifiers, constraints, grounding, field tracks, actions, motion and budget are
  copied for Play and rollback.
- Definitions of skeletons and sets, and programs, live in application caches, like `Skin_Runtime`;
  `Skin_Instances` stores the GPU meshes that each world deforms and `animation_skin_release`
  releases them when that world is freed.

Order in `fixed`:

- `animation_sample` (`apply`): prepares sets and requests, samples programs, clips, actions,
  layers and overrides, and extracts and adapts root motion, before physics (`simulate`). It
  advances the clocks of every entity in order, then blends their poses
  ([in jobs](animation-budget.md#parallel-execution)), then takes what follows each pose in order.
- Between the two, `animation_physics` turns root motion into layered moves of the `Character`: the
  root delta of a climb and the body motion of the actions with
  [`body_move`](animation-actions.md#root-and-movement); another controller reads
  `animation_root_delta`.
- `animation_advance` (`react`): takes updated targets and applies retarget, root removal, pose
  adaptation, grounding, IK/look-at, rigs and limits; then consumes the final physical
  poses and updates attachments. It uses the current physical placement of the actor and keeps the
  external root: physics remains the only writer of body transforms.

Root motion:

- `Animation.root_motion` is None, Extract or In_Place; the clip stores the bone and channels of its
  root. `Playing.root` is the root of the stack in the tick and `animation_root_delta` its
  translation and rotation; In_Place also leaves those channels of the bone at the reference, clip
  by clip as the fader blends them (`Pose_Lock`), or after the pose of a program: a clip with root
  motion that fades out under one without it does not carry the root along, and the one without it
  keeps its own. A root bound to the entity keeps, at the finish, where the owner of its Transform
  put it. The layers blend theirs over it
  ([root and movement](animation-actions.md#root-and-movement)).
- The clips a program blends with a root must coincide in bone and channels: otherwise,
  `Incompatible_Root` rejects the evaluation. Loops, reversal and fades use the extraction of
  `std/anim`; inertialization corrects the delta with the decaying offset. A seek gives no
  displacement.
- Target windows, warping and advance by distance: [motion](animation-motion.md).

Queries and events:

- `animation_curve` and `animation_vector` query a curve by name after programs and layers, with
  defaults in contributions without a track; after `animation_advance`, with those of its leader and
  its curve drives (`playing_curves`).
- `Animation_Events` brings the markers with weight, source, group, `.anim` and `fraction` (where in
  the advance of the tick it was crossed). Dominant emits the greatest contribution, Weighted
  filters by `event_threshold` and Always leaves all the positive ones; zero weight does not emit.
  Synchronized sources emit through the leader.
- `animation_progress`, `animation_seek`, `animation_pose` (local override) and
  `animation_bone_transform` (finished global pose). Actions: [actions](animation-actions.md).

World poses:

- `animation_sample_pose` copies into a caller buffer the world sample of the tick, before physics
  and constraints; it returns count and revision even if capacity is missing.
- `animation_pose_final` enqueues a world pose for the end of the tick: after adaptation, grounding,
  IK, rigs and limits, before sockets. The weight blends the original pose with the requested one
  only once and the result passes to local under the already-updated parent, in hierarchy order
  (translating parent and child with the same weight keeps their distance). Zero weight ignores the
  request and the last request of each bone wins. An expired handle or a bone that the rig does not
  have are the problems `animation.final_pose_binding` and `animation.final_pose_bone`.
- Request procs return nothing: `animation_requests_serve` keeps the room of `Animation_Settings`
  and reports what was dropped or refused. `animation_requests_reserve` keeps more final poses
  than that for a library that sends one per bone, as
  [Ragdoll](../../mirai-plugins/references/ragdoll.md) does.

Editor and skinning:

- `preview` advances the animation with the frame time; turning it off returns to the start.
  `animation_evaluate` runs with `core.world_run` the `fixed` steps of `anim` and `core` (sampling,
  advance, morphs and transforms), without gameplay. A fixture that builds its `World_Info` by hand
  gives its `steps` and its `order`, like `pose_bake_test.odin`.
- Load, bind and configuration changes are transactions; stable ticks reuse memory. Writes respect
  `core.free` and the owner of the transform.
- `animation_skin` interpolates the last two local poses and recomposes the palette, which it reuses
  if pose, mesh and parent did not change; it creates, updates and releases the meshes deformed by
  `engine/render`. A mesh not drawn in the last frame (new, or shown again after `Hidden`) shows
  the pose and weights of the tick until the next one, not an interpolation from a tick it was not
  drawn in: a weapon shown the tick its action starts is not drawn in its rest pose. With
  `Skin_Part`, the deformed copy is created with the part and each palette
  collapses its joints onto the bone: changing the bone creates the copy again, changing its layers
  does not.
- The copy is the mesh the renderer draws its entity with, not another instance
  ([posed mesh](../../mirai-rendering/references/scene.md#visual-instances)): `render_sync` places,
  tints, hides and outlines it as any mesh, and the skin only gives its palette and its weights.
  Curve materials are the `Material_Live` of each mesh of the rig while their curve plays: over
  what the entity authors, never saved.
- A rig whose palette leaves each vertex at its bind (`palette_at_bind`) is drawn with the world's
  shared mesh: a still character or one without animation copies no geometry or BLAS. The copy is
  created the first time the palette leaves the bind and stays until the rig goes away; with morphs,
  from the start. A copy larger than
  what one frame uploads goes
  [over several frames](../../mirai-rendering/references/scene.md#geometry-over-several-frames): the
  entity is not drawn (no shadow, rays or outline) until it went up whole and appears already posed,
  without `Hidden` or anything the game does.
- Shared bind geometry; palette, output, history and BLAS per deformed instance, with the
  [GPU contract](../../mirai-rendering/references/scene.md#gpu-skinning) of all the passes.
  `Draw_Offset` moves the drawing without touching the simulation. Frequency and parallelism:
  [budget](animation-budget.md).

## Offline and live retarget

- One mapping serves both: each destination bone takes the source bone of its name, or of its path
  where a name repeats (`std/anim` `follow_prepare`), and, where the topologies differ, the
  `retarget_chains` of the destination's set pair semantic chains with the destination's lengths.
  Bones without a correspondence keep the reference; the external root stays outside the map.
- Offline, `animation_editor.retarget_bake` writes an `.anim` for the destination skeleton from
  validated views by that mapping ([bake](animation-rigs.md#bake)). The `.anim` stays editable; the
  [resident storage](../../mirai-std/references/anim-storage.md) compresses it at load.
- Live, a `Pose_Source` of stage `Sampled` names the source rig. The correspondences are prepared
  when the bind, the source or the set changes, and the sampled pose of the source is read before
  its constraints.

## Mirroring

- `Animation.mirror` mirrors the whole pose of the rig after layers and actions, with its root
  delta.
- It requires a rig with a `.skeleton`; without it, the entity has the problem `animation.mirror`.
- When loading the `.skeleton` each bone is paired with the one on the other side through
  [`mirror_name`](../../mirai-std/references/anim.md#mirroring-mirrorodin) (`thigh_l`, `hand.L`,
  `LeftArm`, `Bip01 L Thigh`); without a side, or with an absent, ambiguous or non-mutual pair, with
  itself. `animation.inspect` part `Rig` reports the pair.
- The bind deduces the lateral plane and the axis correction of each pair from the reference pose
  and reserves its buffers: mirroring in a tick does not allocate. A reference that does not allow
  it leaves the rig without mirroring.
- Motion warping reads the reflected root motion of a mirrored clock; markers and curves do not
  change side.

## Problems

What the plugin cannot do in a tick is a problem of the entity in
[`core.Problems`](../../mirai-core/references/core.md#problems), with an `animation.*` code and a
message that says how to fix it; `engine.diagnostics` lists them and `animation.inspect`
(`diagnostics`) and `animation.preview` bring those of the instance.

- Assets that cannot be read (`Animation.asset`, `library`, the skeleton or the mesh of a rig),
  with the path and the cause: `animation.asset`, `program_asset`, `skeleton`, `skin_mesh`...
- Data that does not apply: a clip, a layer, a bone, a socket or a parameter that do not exist
  (`animation.clip`, `layer_clip`, `layer_bone`, `pose_bone`, `attachment_socket`,
  `parameter`, `match_clip`, `layer_space`), a matching database that is not built
  (`match_database`, `match_memory`, `match_blend`, `match_mirror`), operations of a set that are
  not bound or not resolved (`rig_*`, `constraint_*`, `grounding_*`, `retarget_*`, `motion_*`,
  `morph_*`) and rejected requests (`action_*`, `modifier_*`, `distance`, `match_goal`).
- A rig that cannot follow its leader (`follow_rig`, `follow_bones`, `follow_pose`), curve poses
  of bones its skeleton lacks or with curves that are not finite (`curve_pose_bone`,
  `curve_pose_value`) and curve materials past the capacity of the `Material_Values`
  (`curve_material`).
- Lost markers or events (`markers_lost`, `events_lost`) and lack of memory
  (`animation.memory`: the entity keeps its last pose and retries).
- `Playback.stats.skipped` counts writes skipped because another component owns the transform: it is
  a statistic, not a failure.

## Verification

`plugins/animation/runtime`; repeat with `--release` only if a failure may depend on optimization.

- `program_test.odin`: the program of a set under the layers: weighted clips, curves, root
  motion, shared phase, copies and null allocators.
- `character_test.odin`: a set round-trips every part, rejects invalid references and ranges,
  samples its spaces without allocations, reloads on change and keeps its previous version when
  memory runs out.
- The stack over the locomotion (aim offsets, actions in layers and over the whole body, priority,
  events once each, root motion that moves the body): [actions](animation-actions.md#verification).
- `matching_walks_mirai_avatar_with_its_feet_planted_without_pose_jumps_and_follows_the_stick`
  (`matching_test.odin`, with the demo assets): Mirai through its `.character` on the same route;
  foot sliding, pose jumps, response and cost per tick. In `std/anim`:
  `match_database_finds_each_frame_by_its_features_and_the_clip_a_trajectory_asks_for` and
  `match_trajectory_follows_a_walk_that_accelerates_brakes_and_turns_at_its_rates`.
- Sources that load in a job (`source_content_test.odin`):
  `an_animation_that_compresses_in_a_job_plays_once_it_is_ready_without_problems` and
  `a_library_that_compresses_in_a_job_keeps_what_plays_until_it_is_ready`.
- By name:
  - `direct_clip_weights_preserve_zero_full_and_partial_trs_without_allocations`
    (`runtime_test.odin`)
- Body parts and regions (`skeleton_test.odin`):
  - `body_labels_name_the_parts_and_regions_the_skeleton_keeps`
  - `layers_play_over_a_region_of_the_body_without_stable_allocations`
  - `body_labels_of_a_skeleton_without_body_say_how_to_give_it_one`
  - `skeleton_bone_find_takes_a_path_a_unique_name_or_a_part_of_the_body`
- Retarget (`constraints_test.odin`): `taking_a_sampled_pose_*`, dense rigs paired by name then
  path, external root, proportions and actor placement without stable allocations.
- `follow_test.odin`: a head of its own skeleton follows the body and its curves pose its face
  without stable allocations; shared bones over the body's wherever both entities sit, own bones,
  leader curves, drives and poses, loops, missing names and values that are not finite;
  `followers_finish_after_their_leaders_in_the_order_found_once`: chains and loops of followers.
- Rigs, actions, motion, budget, grounding, authoring and storage: their references.
- `rigs_at_the_bind_pose_share_their_mesh_until_a_pose_leaves_it` (`skin_bind_test.odin`, GPU): rigs
  at the bind without copies, the copy of the one that is posed and that of one with curve
  materials.
- CPU tests do not vouch for the visual integration: compile and run the project; GPU skinning
  requires graphics validation.
