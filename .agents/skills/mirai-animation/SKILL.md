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

- Debugging and verifying animation in real Play (`capture` filmstrip + `debug`,
  `animation.inspect`, `animation.history`, `play.audit`) vs isolated `animation.capture`:
  [debugging cheatsheet](../mirai-agent-api/SKILL.md#debugging-and-verification-cheatsheet).
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
- Sounds and particle births at markers (the cues of the `.character`, `animation.cue.set`, and
  the `Marker_Cue` components of a prop that plays a plain `.anim`):
  [cues](../../../docs/game/audio/cues.md).
- Components and shared data, the one `.character` set:
  [components](references/animation.md#components-and-shared-data);
  playback, outputs and order: [playback](references/animation.md#playback-outputs-and-order);
  [retarget](references/animation.md#retarget) and
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
- An action whose root motion moves its `Character` (a lunge, a vault: `body_move`, not game code),
  or a whole clip that strides or turns it (`animation_physics.Root_Motion_Body`):
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
- Faces: poses that curves weigh (a face capture names them by its curves) and the poses made from
  a clip: [curve poses](references/animation-rigs.md#curve-poses); material values that clips move
  (flipbook faces, glows):
  [`@field/Material_Live`](references/animation-timeline.md#material-values-of-a-rig); a head or
  another part of its own skeleton that follows the body:
  [following](references/animation.md#following-a-rig-of-another-skeleton).
- Supports, clip adaptation and gait without clips (the ground is the `core.World_Query` of
  physics): [configuration](references/animation-grounding.md#configuration),
  [clip adaptation](references/animation-grounding.md#clip-adaptation),
  [gait without clips](references/animation-grounding.md#gait-without-clips) and
  [execution and state](references/animation-grounding.md#execution-and-state).
- Level of detail by distance to the simulation sources (cadence, cosmetic modifiers,
  gameplay-read rigs, dedicated server):
  [level of detail](references/animation-budget.md#level-of-detail-by-distance);
  `Animation_Budget` and parallel execution:
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
  [rigs](../mirai-std/references/anim-rigs.md#chains) and
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
   `animation.clip.edit`), check metrics with `animation.analyze`, preview isolated poses with
   `animation.capture`, and verify real Play locomotion with `capture` filmstrips (`debug:
   ["Skeleton","Collision","Trajectory"]`), `animation.inspect` (`Match`/`Pose`) and
   `animation.history`
   ([cheatsheet](../mirai-agent-api/SKILL.md#debugging-and-verification-cheatsheet)).
3. Change the data in its owner and expose it by name: plain components and storages, requests by
   queue to the writer, no pointers stored between frames.
4. If an asset or a schema changes, version it and update all its consumers, including the demo
   content that `demo/tools/content` writes.
5. Verify as [Verification](#verification) says.

## Character workflow

1. **One set:** a `.character` in `Animation.asset`, over the `.anim` of its clips, holds what
   the character plays and adapts; `animation.character.setup` writes it from the clip names and
   the skeleton body.
2. **Locomotion:** the match clips of the set with the locomotion mode each one serves. With a
   `Character`, `animation_physics` tells it on each tick the mode, the velocity and what its
   locomotion heads to (published on `Locomotion_State`: `desired`, rates, `facing`, `turn_speed`,
   across the up of its `core.Vertical`): the game writes nothing. Without a body but with a
   `core.Motion` (a bodyless `Nav_Agent`), it walks by that Motion and its `Walk` rates
   (`motion_goal`). Otherwise the game calls `match_goal`. Its feet ground only while its
   `Character_State` stands (`animation_grounding`), and a `Root_Motion_Body` makes the root motion
   of its whole animation walk and turn it.
3. **Few clips:** idle and walk are enough; a run or jog widens the range. The rate of a clip
   (`min_rate`..`max_rate` of the set, or of its source: a crouch authored slower than it is
   played, a jog kept below the sprint) covers the velocities between those of its clips and the
   warping of the set stretches the stride to that of the body. A mode without clips of its own
   keeps the clip that is playing; a jump or landing is an `entry` clip of its mode, not a state. A
   livelier turn or start asks for turn or start clips, not transitions.
4. **Gameplay actions:** one request, `play`, by the name of an action of the set. What is added
   to the locomotion (waving, reloading, hitting with the torso) names a layer of the set; what
   takes the whole body (vault, hit received, death, emote) names none and takes the pose from
   the base while the matching goes on under it. Each has its priority, cancellation, entry
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
  names a bone only to override it. A timed span of a clip (a section, a window, a warp window, a
  rule of the matching) is a marker with a duration on the clip, which the set names.
- **One stack, one play, one queue.** What plays over the base is the one stack of layers of the
  set; a moment of the body is one `play` request with one priority rule, in a layer or
  over the whole body; what happens arrives in one `Animation_Events` queue. A game walks, aims,
  acts and reacts with `play`, `stop`, `set`, `look` and that queue. Everything a game asks of the
  animation, including named modifiers and warp targets, goes in `Animation_Requests`.
- **Root motion is a channel of the stack:** each layer gives the root delta of its clips by the
  weight of its pose, over that of the base, and the layers of actions with `body_move` are the
  share that moves the body. Every layer that moves the root moves the root bone of the base.
- **What `play` starts replicates by itself:** the end that decides an entity records each action
  it asks in `Animation_Played`, and the others play it from the tick it started.
- The `Animation` clip and playback fields give the initial clip and clock. The clip request
  queue owns those settings in Play and retains requests while their sources load.
- The runtime does not allocate in a stable frame; the buffers of the program are reserved at load
  and released when it is retired. The database of a set is built at load, per library and
  skeleton (those of the libraries it lists too), within its memory cap.
- Physics is the only writer of the mode and the velocity of a character; animation reads them
  through `match_goal` on each tick and keeps no copy.
- The jumps of the matching and every change of what a slot of the stack plays (an action that
  starts, ends or is interrupted, also over the whole body) are inertial: the new pose shows at
  once, only its clips are evaluated, and its difference from the pose shown decays. Only the
  weight a parameter gives a layer moves over its `fade`.
- The API and its preview evaluate the same runtime as the game. The `previews` panel samples clips
  on its own.
- The API expresses intent with names and defaults: it resolves handles and indices inside the
  plugin, separates targets from influence and activation, and publishes solver details only through
  optional inspection. Character definitions are shared; each rig owns its modifier state.
- The Tracks tool is the one editor of the keys of every clip and keeps only its view; each of its
  gestures is a call of an `animation.*` method.
- Asset edits go through the editor's file history: one step per call, attributed to the AI turn,
  which `history.undo` and `history.redo` undo and redo. Like the other assets, the files are
  written when the step ends.
- Runtime, editor and previews read the assets through the registry (`host.assets_file` by id,
  `asset.registry_read` by path), never the file by its path on disk, and notice a change by the
  registry revision; this way the preview and Play see what a step has not flushed yet.
- The project's `.anim` keeps exact keys, which the editor edits; the editor and the game play
  them compressed into a stream per clip, and a shipped game carries only those streams
  ([storage](../mirai-std/references/anim-storage.md)). A compression is kept in the project
  cache and a first one runs in a job; a scene load and Play wait for those of the `.anim` their
  world's data names, so only an entity outside them (an edit, a preview) does not animate
  meanwhile (a rig holds its rest pose) and nothing is reported
  ([content](../mirai-core/references/host.md#content)). An entity whose sources change to one
  still compressing (a set only code swaps into `library`) plays on what it played, with its
  actions, until it loads.
- How much of a rig runs in a fixed tick goes by its distance to the simulation sources, never
  by a view; clocks, events and root motion run in every tick, and what gameplay reads is posed
  in full ([level of detail](references/animation-budget.md#level-of-detail-by-distance)).
- Skinning runs on the GPU; morphs are deformed in the same pass.
- Another rig drives a pose through one link, `Pose_Source`: a rig of the same skeleton shares
  its finished pose and a part of another (a modular head) follows it by bone name, keeping its
  own animation on the bones only it has. A character of other proportions plays the clips
  itself: they are retargeted onto its skeleton once, when a rig of it first plays them, shared
  by library and skeleton ([retarget](references/animation.md#retarget)); the offline bake writes
  the same mapping. A contact is an IK row with a spatial target, or grounding. A
  face is curves over poses and morphs, with no rig evaluator in the plugin.
- **Pruned/unified surfaces (do not look for or reintroduce):** multi-bone chains use `Multi_IK`
  (no `Chain_IK`), command clips play in layer stack slots (no `Clip_Overlay`), material curves
  are `@field/Material_Live` clip tracks (no `Curve_Material`), retargeting runs on load in
  `Source_Assets` (no per-tick `Chain_Retarget` or `Pose_Source.stage`), and `Distance_Key` and
  `Curve_Drive` do not exist (use `Curve_Pose`, `Pose_Corrective`, clips and morphs).
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
- What is visual (skinning, morphs, rigs, locomotion) is checked with a real Play `capture`
  filmstrip (`debug: ["skeleton","match","bounds","collision","trajectory"]`) and graphics
  validation, plus `render.inspect_entity` (`skinned`, `skin_updated`) and `animation.inspect`
  (`Match`/`Pose`). `animation.capture` is an isolated preview without physics/world; CPU tests
  never vouch for GPU skinning or live locomotion.
