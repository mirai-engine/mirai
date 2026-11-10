---
name: mirai-animation
description: Mirai animation - the `animation` plugin (`plugins/animation/runtime` and
  `plugins/animation/editor`) and the `animation_physics` bridge, with `.anim` clips and their
  markers and spans, skeletons, skinning, the one character animation set `.character` (locomotion
  by motion matching with `match_goal` and inertialization, the layers over the matched pose and the
  actions of `play`, `stop`, `set`, `look`, aim offsets and additive spaces, warping, IK, look,
  grounding and rigs), root motion, retarget, mirroring, morph targets, budget, clips that move
  props and fields, authoring by intent and by API, and the auto-rig of a character with no
  skeleton. Use when animating characters or objects, building the locomotion or the actions of a
  character, porting a character's or a weapon's motion and events from another engine's data,
  looking for a state machine, an animation graph or a locomotion blend space (they do not exist),
  touching those packages or their assets, or diagnosing a pose, a skinning or a clip.
---

# Mirai animation

`animation` is an optional plugin (runtime and editor) over the math of `std/anim`. The runtime
evaluates poses in the game loop; the editor edits the assets through the API with names and
history, and its preview evaluates the same runtime over a copy of the world. With physics, the
automatic plugin `animation_physics` feeds the locomotion of each `Character`.

## Map

- Animating an uploaded or generated character or animal that arrives without a rig (template rig at
  import and Mesh2Motion clips):
  [auto-rig](references/animation-autorig.md#animating-a-character-that-arrives-without-a-rig).
- Building a character (locomotion, jumps, actions) or replacing what used to be a state machine:
  [workflow](#character-workflow) and
  [what replaces the FSM](references/animation.md#what-replaces-the-state-machine).
- Motion matching (the locomotion of the `.character`, modes, entry clips, `match_goal`):
  [locomotion](references/animation.md#locomotion-by-motion-matching), a jump that lands on time
  by its marker: [landing](references/animation.md#landing); its search and features:
  [anim-motion](../mirai-std/references/anim-motion.md#motion-matching-matchingodin).
- Layers over the base, masks, additives, parameters by name and aim offsets (the layers and
  spaces of the `.character`):
  [the layer stack](references/animation-actions.md#the-layer-stack) and
  [additive spaces](references/animation.md#additive-spaces).
- Components and shared data, the one `.character` set:
  [components](references/animation.md#components-and-shared-data);
  playback, outputs and order: [playback](references/animation.md#playback-outputs-and-order);
  [retarget](references/animation.md#offline-and-live-retarget) and
  [mirroring](references/animation.md#mirroring); why an entity does not animate (asset, clip,
  bone, set, request or memory): [problems](references/animation.md#problems).
- Authoring by intent (body, character, requests, clip verbs, analysis, capture):
  [intent first](references/animation-authoring.md#intent-first),
  [files and history](references/animation-authoring.md#files-and-history),
  [skeleton body](references/animation-authoring.md#skeleton-body),
  [clip verbs and metrics](references/animation-authoring.md#clips-verbs-and-metrics),
  [character](references/animation-authoring.md#character) and
  [inspection](references/animation-authoring.md#inspection).
- Authoring by API (clips, skeletons, sockets, the tables of a `.character`, control and
  per-instance preview): [clips and timeline](references/animation-authoring.md#clips-and-timeline),
  [skeletons](references/animation-authoring.md#skeletons-sockets-and-profiles),
  [matching and spaces](references/animation-authoring.md#motion-matching-and-additive-spaces) and
  [per-instance control](references/animation-authoring.md#per-instance-control-and-preview).
- Placing, moving and easing keys by hand in the editor, keying from the gizmo, a track for a
  field of an entity: [Tracks tool](references/animation-authoring.md#tracks-tool).
- `animation.*` and `skeleton.*` methods and their common errors:
  [methods](references/animation-api.md#animation-api-methods) and
  [common errors](references/animation-api.md#common-errors).
- Actions (`play`, `stop`, sections, windows, priority, cancellation, the event queue):
  [profile and authoring](references/animation-actions.md#profile-and-authoring) and
  [requests and lifecycle](references/animation-actions.md#requests-and-lifecycle); warping:
  [definitions](references/animation-motion.md#definitions-and-state),
  [requests and order](references/animation-motion.md#requests-and-order) and
  [authoring and control API](references/animation-motion.md#authoring-and-control-api).
- An action whose root motion moves its `Character` (a lunge, a vault: `body_move`, not game code):
  [root and movement](references/animation-actions.md#root-and-movement).
- Rigs, spatial targets and chain modifiers:
  [spatial targets](references/animation-rigs.md#spatial-targets),
  [operations](references/animation-rigs.md#operations),
  [order and state](references/animation-rigs.md#order-and-state),
  [requests and diagnostics](references/animation-rigs.md#requests-and-diagnostics) and
  [bake](references/animation-rigs.md#bake).
- Morph targets, `Morph_Weights` and their deformation:
  [weights](references/animation-morphs.md#weights),
  [runtime](references/animation-morphs.md#runtime), [API](references/animation-morphs.md#api) and
  [deformation](references/animation-morphs.md#deformation).
- Faces: poses that curves weigh, drives from a face capture (ARKit), material values that curves
  move (flipbook faces) and the poses made from a clip:
  [curve poses](references/animation-rigs.md#curve-poses-and-drives); a head or another part
  of its own skeleton that follows the body:
  [following](references/animation.md#following-a-rig-of-another-skeleton).
- Supports, clip adaptation and gait without clips (the ground is the `core.World_Query` of
  physics): [configuration](references/animation-grounding.md#configuration),
  [clip adaptation](references/animation-grounding.md#clip-adaptation),
  [gait without clips](references/animation-grounding.md#gait-without-clips) and
  [execution and state](references/animation-grounding.md#execution-and-state).
- `Animation_Budget` and parallel execution:
  [budget](references/animation-budget.md#animation_budget) and
  [parallel execution](references/animation-budget.md#parallel-execution).
- A prop, a field of a component or an entity anywhere moved by a clip, and the one queue that
  plays, pauses, stops and seeks it:
  [what a track drives](references/animation-timeline.md#what-a-track-drives),
  [when it writes](references/animation-timeline.md#when-it-writes) and
  [commands](references/animation-timeline.md#commands).
- Math and storage of `std/anim`:
  [clips](../mirai-std/references/anim.md#tracks-keys-and-clips-trackodin-clipodin),
  [pose](../mirai-std/references/anim.md#blending-poseodin),
  [skeleton](../mirai-std/references/anim.md#skeletal-pose-skeletonodin),
  [adaptation](../mirai-std/references/anim.md#adaptation-ikodin-retargetodin-followodin),
  [body](../mirai-std/references/anim-body.md#body-map-bodyodin),
  [inertialization](../mirai-std/references/anim-motion.md#inertialization),
  [rigs](../mirai-std/references/anim-rigs.md#retarget-between-chains) and
  [storage](../mirai-std/references/anim-storage.md#sampling).
- The physics that writes the mode and the velocity (`Character`, `Walk`, `Swim`, `Fly`):
  [mirai-physics](../mirai-physics/SKILL.md).
- Use from a game and tour of features:
  [animation gallery](../mirai-gameplay/references/animation-gallery.md#animation-gallery); demo
  scenes and generated content:
  [generated content](../mirai-gameplay/references/demo.md#generated-content).
- An entity that animates at its own pace in slow motion (`core.Own_Pace`):
  [own pace](../mirai-core/references/core.md#core-storages).
- Animation documents of the editor:
  [previews](../mirai-plugins/references/previews.md#animation-document).
- Importing skeletons and clips:
  [skinned meshes](../mirai-imports/references/imports.md#skinned-meshes),
  [glTF clips](../mirai-imports/references/imports.md#gltf-clips) and
  [FBX](../mirai-imports/references/imports.md#fbx); bringing a character's motion and events from
  another engine's data: [porting](#porting-a-character-from-another-engine).

## Workflow

1. Locate the layer: pure math in `std/anim`; components, storages and loop steps in
   `plugins/animation/runtime`; what physics reads in `plugins/animation_physics`; authoring, API
   and preview in `plugins/animation/editor`.
2. To animate a character, declare the intent (`animation.character.setup`, `animation.request`,
   `animation.clip.edit`) and look at the result with `animation.analyze` and `animation.capture`
   before touching keys.
3. Change the data in its owner and expose it by name: plain components and storages, requests by
   queue to the writer, no pointers stored between frames.
4. If an asset or a schema changes, version it and update all its consumers, including the demo
   content that `tools/demo_content` writes.
5. Verify as [Verification](#verification) says.

## Character workflow

1. **One set:** a `.character` in `Animation.asset`, over the `.anim` of its clips, holds what
   the character plays and adapts; `animation.character.setup` writes it from the clip names and
   the skeleton body.
2. **Locomotion:** the match clips of the set with the physics mode each one serves. With a
   `Character`, `animation_physics` tells it on each tick the mode, the velocity and the request:
   the game writes nothing. Without physics, the game calls `match_goal`.
3. **Few clips:** idle and walk are enough; a run or jog widens the range. The rate of a clip
   (`min_rate`..`max_rate` of the set, or of its source: a crouch authored slower than it is
   played, a jog kept below the sprint) covers the velocities between those of its clips and the
   warping of the set stretches the stride to that of the body. A mode without clips of its own
   keeps the clip that is playing; a jump or landing is an `entry` clip of its mode, not a state. A
   livelier turn or start asks for turn or start clips, not transitions.
4. **Gameplay actions:** one request, `play`, by the name of an action of the set. What is added
   to the locomotion (waving, reloading, hitting with the torso) names a layer of the set; what
   takes the whole body (vault, hit received, death, emote) names none, leaves the search by
   inertialization and the matching resumes by itself. Each has its priority, cancellation, entry
   and exit; its sections and windows are spans of its clip. The game reacts to
   `Animation_Events`, not to a state.
5. **On top of the pose:** the layers of the set, over the matched pose: an aim offset is an
   Additive layer over a space of the set, moved with `set` by the name of its axis; `look`, IK
   and grounding are modifiers of the set.
6. **No FSM is needed:** the mode is decided by physics, the clip is chosen by the search, actions
   bring their own priority, exit and events, and the game logic lives in its data and functions.
   If a task seems to ask for animation states or a graph, the table
   [what replaces the FSM](references/animation.md#what-replaces-the-state-machine) says what
   to use; a state machine is not added to the engine or to the game.

## Porting a character from another engine

Adapt the source's data to these features instead of rebuilding its runtime:

1. **Events:** the notifies of its clips (footsteps, foley, hit windows) go in the glTF as
   `extras.markers`, which the import keeps on the clips; the game reads `Animation_Events`. A blend
   of several clips that the source plays as one sample (a blend space) takes
   `Animation.event_policy` `Dominant`.
2. **More motion for a character imported before:** import the file of clips with the `skeleton`
   setting ([imports](../mirai-imports/references/imports.md)): it writes only the `.anim`, bound to
   that skeleton.
3. **Traversal warped to a target** (a climb onto a ledge): the clip keeps its root and a span of
   the name the consumer uses (`mantle` for the physics mantle), and the set a warp window of that
   name; the root motion moves the body.
4. **What the source's animation graph does at run time** (a bone locked to another while a curve
   is on, layered arms, an additive composed of several) is baked into the clips when it only
   depends on the clip; a layer or an action of the set when it depends on the game.
5. Values come from the source's data; where its runtime decides something its data does not
   keep, say so next to the value the game takes.

## Invariants

- **Locomotion is motion matching, without a state machine.** The clips of the set are searched
  in the mode that physics writes; there is no state machine, animation graph or locomotion blend
  space.
- **Two authored kinds.** A character animates from `.anim` clips and one `.character` set, shared
  by every character of its body. Limbs and pelvis are named once, in the `.skeleton` body; a table
  names a bone only to override it. A timed span of a clip (a section, a window, a warp window) is
  a marker with a duration on the clip, which the set names.
- **One stack, one play, one queue.** What plays over the base is the one stack of layers of the
  set; a moment of the body is one `play` request with one priority rule, in a layer or
  over the whole body; what happens arrives in one `Animation_Events` queue. A game walks, aims,
  acts and reacts with `play`, `stop`, `set`, `look` and that queue.
- The runtime does not allocate in a stable frame; the buffers of the program are reserved at load
  and released when it is retired. The database of a set is built at load, per library and
  skeleton, within its memory cap.
- Physics is the only writer of the mode and the velocity of a character; animation reads them
  through `match_goal` on each tick and keeps no copy.
- The transitions of the matching are inertial (its jumps, and a whole-body action entering and
  leaving it); the crossfade is left for the layers and the actions in them.
- The API and its preview evaluate the same runtime as the game. The `previews` panel samples clips
  on its own.
- The API expresses intent with names and defaults: it resolves handles and indices inside the
  plugin, separates targets from influence and activation, and publishes solver details only through
  optional inspection.
- The Tracks tool is the one editor of the keys of every clip and keeps only its view; each of its
  gestures is a call of an `animation.*` method.
- Asset edits go through the editor's file history: one step per call, attributed to the AI turn,
  which `history.undo` and `history.redo` undo and redo. They stay in memory unsaved like the other
  assets: the disk does not change until saved and a created asset exists only in the registry.
- Runtime, editor and previews read the assets through the registry (`host.assets_file` by id,
  `asset.registry_read` by path), never the file by its path on disk, and notice a change by the
  registry revision; this way the preview and Play see what is unsaved.
- The project's `.anim` keeps exact keys, which the editor edits; the editor and the game play
  them compressed into a stream per clip, and a shipped game carries only those streams
  ([storage](../mirai-std/references/anim-storage.md)). A compression is kept in the project
  cache and a first one runs in a job; a scene load and Play wait for those of the `.anim` their
  world's data names, so only an entity outside them (an edit, a preview) does not animate
  meanwhile (a rig holds its rest pose) and nothing is reported
  ([content](../mirai-core/references/host.md#content)). An entity whose sources change to one
  still compressing (a set only code swaps into `library`) plays on what it played, with its
  actions, until it loads.
- Skinning runs on the GPU; morphs are deformed in the same pass.
- Another rig drives a pose through one link, `Pose_Source`: at stage Finished a rig of the same
  skeleton shares the pose and a part of another follows it by bone name, keeping its own
  animation on the bones only it has; at stage Sampled a character of other proportions plays the
  sampled pose by bone names, or by the chains of its set where the topology differs. The offline
  bake prepares the same mapping. A contact is an IK row with a spatial target, or grounding. A
  face is curves over poses and morphs, with no rig evaluator in the plugin.
- What the runtime cannot do is a problem of the entity (`core.report` with an `animation.*` code
  and how to fix it), never a counter ([problems](references/animation.md#problems)). The functions
  and helpers receive `^core.Problems`; `Constraint_Inputs` and `Grounding_Inputs` carry it.

## Verification

- Types: `mirai check plugins/animation/runtime`, `plugins/animation/editor` (with
  `-collection:plugins=plugins`), `plugins/animation_physics/runtime` and `std/anim` according to
  what was touched.
- Tests: the cases of the Verification section of each reference in the Map, with `mirai test`;
  `--release` only if a failure may depend on optimization. Matching: `matching_test.odin` of the
  runtime (the
  demo's Mirai: skating, pose jumps, response and cost), `character_test.odin` (the set) and
  `std/anim/matching_test.odin`.
- API methods: generate and compile the demo editor and check them with `mirai rpc describe` and a
  real call.
- What is visual (skinning, morphs, rigs, locomotion) is checked with a capture with graphics
  validation, with real physics for locomotion; CPU tests do not vouch for the GPU integration.
