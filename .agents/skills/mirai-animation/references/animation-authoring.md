# Animation authoring by code and API

The plugin builds, requests and edits animation through JSON-RPC/MCP methods, without a visual
window (the dedicated window is pending). Methods and common errors: [API](animation-api.md); fields
and defaults: `mirai rpc describe animation.`; transport, ids and errors:
[agent API](../../mirai-agent-api/references/api.md); evaluation: [animation](animation.md).

## Intent first

Whoever does not know animation declares what they want; keys and tables are left for fine work.

1. `skeleton.body.detect`: the body of the skeleton (correct it with `skeleton.body.set`).
2. `animation.character.setup`: locomotion, look-at, feet, hands and gestures from that body.
3. `animation.request`: `locomote`, `look`, `reach`, `gesture` and any per-instance control.
4. `animation.preview` tests the same fields on a copy; `animation.capture` shows it in images.
5. `animation.clip.edit` changes whole clips with verbs; `animation.analyze` measures them and
   proposes fixes as verbs.

Intent works on the clips that exist: it does not generate or capture motion or search clip
libraries.

## Files and history

- `dry_run` (in every `create`, `set`, `patch`, bake and edit) validates and answers without
  writing.
- `path` is relative to the assets folder. `create` does not overwrite; `set` on a path that has one
  replaces it keeping its id (`replaced:true`) and validates the whole definition before publishing. The files use the [asset
  container](../../mirai-assets/references/formats.md), without opaque JSON.
- A `set` over an existing asset replaces the whole file and the last one wins
  ([concurrency](../../mirai-agent-api/references/api.md#concurrency-transactions-and-undo)). The
  response is built before writing; if it does not fit, nothing is written.
- Each write is a step of the [editor history](../../mirai-editor/SKILL.md) with the rest of the
  call (`character.setup` writes assets and components in a single one): `history.undo/redo` apply
  it only if the file is still as the step left it, and the review of an AI turn lists it in
  `changed_files` and reverts it.
- Publishing leaves the asset in the registry unsaved: `asset.save` writes it, `asset.discard`
  returns to what was saved and a created asset (also by `character.setup`, `request`, a clip verb
  or a bake) exists only in the registry until saved. Runtime, preview, Play and inspectors read it
  from there. Editing a shared asset affects its consumers when they reload; what is requested in
  Play/Simulation is not saved.
- A validation fails with `data.path/code/expected/actual/fix`, and `fix` says how to correct it
  (which method creates what is missing, which values the field admits). The parser rejects unknown
  fields, arrays out of capacity and non-finite values before the handler; an unknown enum or bit
  set lists its members.

## Skeleton body

- `skeleton.body.detect` stores in the `.skeleton` the parts and the up of the body
  ([detection](../../mirai-std/references/anim-body.md#body-map-bodyodin)) and returns the
  confidence of each part, those that are missing and a `fix`. Import already detects it. Without
  one stored, `animation.clip.edit`, `animation.analyze`, `animation.character.setup` and
  `ragdoll.setup` detect it in memory for the call and leave the `.skeleton` as it is.
- `skeleton.body.set` sets parts by hand: they stay `manual` and survive detection and reimport.
  A rig faces -Z and the `.skeleton` stores no forward: the import turns a rig whose body faces
  another axis, and `front` of `asset.import` states it for one the import does not turn
  ([front](../../mirai-imports/references/imports.md#front)). An unknown bone suggests those with
  a similar name.

## Clips: verbs and metrics

- `animation.analyze` measures a clip (travel, contacts, sliding, penetration, jerk, seam, limits)
  and proposes `fixes`, each with the verb that fixes it
  ([metrics](../../mirai-std/references/anim-body.md#metrics-metricsodin)).
- `animation.clip.edit` applies verbs in order
  ([contracts](../../mirai-std/references/anim-body.md#editing-verbs-editodin-edit_bodyodin))
  and writes a new clip with the metrics before and after. It resamples to `rate` and keeps curves,
  root and markers, which the time verbs move; `loop` `Auto` decides by the seam whether it is a
  cycle. Without edits it copies the clip with its keys as they are.
- The clip goes into `asset` (named with ` edited`), or into the `.anim` at `path`: a new one, or
  an existing one whose bone tracks name bones of the same skeleton (`Other_Skeleton` otherwise),
  keeping its name; `replace` overwrites a clip of the same name. That is how a library is built
  from clips chosen from another, without importing the source again.
- A verb without what it needs fails with the path of the field (`edits[0].direction`) and its
  `fix`.

## Character

`animation.character.setup` builds a character from the saved body of the skeleton of its rig (or a
detected unsaved one) and a clip library (by default, the one it plays). With `skeleton` instead of
`entity` it needs `library`, only writes the assets and returns them, and changes no entity.

- It classifies the clips by the words of their name: idle, stand, walk, jog, run and sprint serve
  the walking mode (with start, stop, turn or pivot they do not loop); fall, air or a looping jump,
  falling; jump or takeoff are the entry of falling and land that of walking; swim and fly or hover
  serve swimming and flying. The number of each mode comes from the project's `Locomotion_Mode`
  type with names: without the physics plugin it fails with `Missing_Plugin`; a clip whose mode the
  project lacks is named in the detail. In-place clips that are neither locomotion nor jumps are
  gestures.
- `clips` limits the classification to the clips it names. More locomotion clips than a `.match`
  takes, or more gestures than an `.action` takes, fail with `Capacity`, their counts and a `fix`:
  no clip is left out silently.
- A clip travels at the speed measured from its feet
  ([metrics](../../mirai-std/references/anim-body.md#metrics-metricsodin)); `speeds` sets that of a
  locomotion clip by hand and the `.match` keeps it.
- `blends` puts [blends](animation.md#locomotion-by-motion-matching) in the `.match`: 2 to
  `MATCH_BLEND` looping locomotion clips of one mode and one duration (within a row), as the eight
  directions of a set, and samples, each with `MATCH_BLEND` `weights` (one per clip in order, 0
  past them, a positive sum) and an optional `speed`. Its clips leave the `.match` as clips of their
  own, and the result lists each blend with its mode and samples. A clip that is not locomotion, a
  size, sum or weight out of place, no samples or clips of different durations fail with their
  path and a `fix`.
- `min_rate`, `max_rate` and `trajectory_direction`, when given, replace those defaults of the
  `.match`: the rates a clip plays at to follow the body, and the weight of where the trajectory
  faces (0 for a body that never turns, as one that walks sideways). `rates` (per clip) and the
  `min_rate` and `max_rate` of a blend replace those rates for that source: a crouch authored at
  1.5 m/s and played at 2.25 m/s needs up to 1.5, which would let a jog beat the sprint.
  `landing_marker` (empty: no landing) and `landing_rates` replace those of the
  [landing](animation.md#landing).
- Capabilities (`want`): locomotion (a `.match` with those clips and a warping `.motion`; the
  `Animation` stays `In_Place` when a clip of its library has a root and `animation_physics` moves
  it; its loops keep their phase and a
  body that does not move, also against a wall, plays the loops that do not travel), look-at and hands (off until
  requested), feet (grounding: needs physics) and gestures (`.action` on the upper body and per arm,
  in layers 1 to 3). The IK pole of each arm is a fixed point of the world: with the character
  turned the elbows do not follow it. Idle and walk are enough: the locomotion is `Ready`, and
  beyond the walk velocity the warping stretches the stride.
- It writes the assets and assigns `Animation` and `Pose_Modifiers` of the rig; existing files ask
  for `replace`, which keeps their ids. With locomotion, `Animation` is left without a clip or
  previous parameters.
- A clip turned sideways inside (a root joint rotated about up, as a 2.5D game does) travels to the
  side; `animation.clip.edit` with `Face_Rest` turns it back to the rest facing of the body, which
  the `Character` then turns. The body faces where the joint that carries the pelvis does, so a
  turn split between it and the joints above (a stop that turns toward a camera) goes whole.
- With the body saved in the `.skeleton`, the assets name
  [parts and regions](animation.md#components-and-shared-data) (`@head`, `@upper_body`) and
  serve another skeleton with a body; with a detected unsaved one they name bones. The warping spine
  always names bones.
- It returns the state of each capability (`Ready`, `Partial`, `Missing`) with its `fix` and the
  chosen clips with their velocities.

## Clips and timeline

- `animation.clip.create` adds a clip to the `.anim` at `path`, new or not. Its result gives the id that the following calls use; duplicate names are rejected.
  `clip.set` changes name and root without touching tracks or markers.
- `animation.track.set` creates, replaces or removes a whole track by `(target,property,slot)`, with
  the clip by name and the destination by canonical path or curve name. `key.set` replaces
  the key of a track at `time` or inserts one in order; `marker.set` changes a marker by `name`
  (`at` the time among several of the name, `add` one more). Both work on tracks longer than the
  capacity of `track.set`.
- Times in seconds; keys and markers keep the order of the clip. `Rotation` is a finite, non-zero
  XYZW quaternion
  ([tracks](../../mirai-std/references/anim.md#tracks-keys-and-clips-trackodin-clipodin)). Curves
  are tracks over a name, without ECS components.

## Inspection

- `animation.asset.inspect` reads any definition (`.anim`, `.skeleton`, `.pose`, `.blend`,
  `.agraph`, `.motion`, `.action`) by sections and paged tables.
- `animation.inspect` reads an instance by parts (rig with the mirrored pair of each bone, graph,
  modifiers, actions, motion and morphs; `diagnostics` adds solver and fades). A part that does not
  apply answers `{available:false, code, reason}` without failing the call; a graph that does not
  evaluate gives `Program_Error`. `entity` also takes, in Play or Simulate, the handle
  `play.inspect` gives, the only name of an entity the game made.
- `animation.inspect` part `Match` lists the clips of the database and the candidates of its last
  forced search with their costs per feature, then the best row of each clip it left out with its
  `reason`: why a jump or a start chose its clip, or never picks one, is read there. The tick keeps
  only that search's request; inspect searches it again to note them.
- `animation.inspect` part `Pose` (only when asked, with `names`) places bones and sockets in the
  world and in the space of the entity from the pose its rig ended its last tick with: a pose,
  socket or root-motion problem is read as numbers, in a paused Play after `play.step`, instead of
  by captures. A bone is named by path, by a name no other bone has or as a part of its body
  (`@hand_r`), and a socket by its name; a name the skeleton lacks fails the call.

## Skeletons, sockets and profiles

- The skeleton defines paths, hierarchy, reference, sockets and body. The skin is the static link of
  the mesh ([assets](../../mirai-assets/references/formats.md#asset-types)): these methods do not
  edit joints or weights.
- `skeleton.create` asks for parents before children, by canonical path (empty is a root;
  identity TRS if omitted); `skeleton.bone.set` addresses a bone by `path`.
  `skeleton.bone.set` changes name and reference, not path or parent. `skeleton.bone.add` adds a
  bone under a parent (by path) after the others, so meshes and indices keep theirs; with `clips`,
  the tracks of those `.anim` whose target ends in a node of the bone's name under another path take
  its path and drive it (a bone the clips of another skeleton animate, such as a weapon attach bone
  the body does not weight). Removing or reparenting a bone is creating another skeleton.
- Sockets belong to the shared skeleton, not to a clip or to the equipped entity, which carries
  `Bone_Attachment` with its own offset.
- `pose.profile.set` replaces or appends the row with the key of its value (bone, name, curve and
  bone, from and to: `engine.describe` lists them per table), or removes it. Targets are written
  as `Spatial_Target` without an entity (`{"position":[x,y,z]}`,
  `{"kind":"Socket","socket":"grip"}`); the entity arrives with the `goals` of `animation.request`.
  The definition stores bones and configuration; targets and fades belong to the instance. The
  quantities come from the lists, without counters or padding. Types: [rigs](animation-rigs.md) and
  [grounding](animation-grounding.md).
- `pose.profile.poses` makes the `curve_poses` of a face from a clip with a frame per pose (as
  faces and pose assets are exported): each pose is the frame at its time measured from `base`, a
  row per bone that moves past `tolerance`, and replaces the rows of its curve; with `full` each
  row keeps the frame of its bone. Without `poses`, each marker of the clip is a pose of its name.
  A Float curve of the clip with a value at the frame of a pose is a drive from the pose's curve to
  it (what a pose asset carries, such as the ARKit remap), and replaces the drives from that pose.
  Other drives and curve materials are rows of `pose.profile.set`
  ([curve poses](animation-rigs.md#curve-poses-and-drives)).
- `animation.retarget.bake` bakes a new `.anim` from animation, source and destination skeletons and
  profile ([bake](animation-rigs.md#bake)).

## Motion matching, graphs and additive spaces

- The `.match` is written by `animation.character.setup` ([character](#character));
  `animation.asset.inspect` describes it with its clips, the names of its modes and its entry, the
  clips and samples of each blend, and
  for each already loaded skeleton the rows, the bytes and the error of its database.
- `animation.blend_space.set` builds the geometry of an aim offset or
  additive from axes and samples; `sample` gives clips and weights at a position without advancing
  the world. Each clip exists in the `.anim` of its sample or of the blend space; two axes with the
  same name, duplicate positions and degenerate geometry are rejected. A `.blend` as the asset of
  `animation.play` is `Additive_Space`.
- `animation.graph.set` receives the whole graph with unique names per
  table: nodes in any order (the editor orders dependencies), without indices, sentinels or
  `*_count`, and its `output`. A `Blend_Space` that is not the `right` of an `Additive` is
  `Additive_Only`, with where it ended up and how to fix it.
- Only Clip/Blend_Space sources accept `sync_*` and `mirror` ([mirroring](animation.md#mirroring));
  a source rejects Additive curves because it has no second input. A Clip node without `animation`
  uses the library of the graph; a blend space, its own ([multiple
  sources](animation.md#multiple-sources)).
- `animation.graph.patch` changes the present fields of nodes and parameters in one transaction. It
  validates the whole graph; a failure writes nothing.
- Semantics and evaluation limits: [locomotion](animation.md#locomotion-by-motion-matching) and
  [composition](animation.md#composition-graphs-and-additive-spaces).

## Per-instance control and preview

`animation.play` assigns the playback (asset, clip, layers 1 to 3) and adds `Animation` if missing.
An Additive layer takes `reference_clip`, a clip of the asset whose pose at `reference` its clip
is added over ([layers](animation.md#playback-outputs-and-order)); on another layer or mode it is
`Not_Additive`, and a clip the asset lacks `Missing_Clip`. Everything else that is asked of an
instance is `animation.request`, with the fields of `animation.preview`:

- Controls: stop and seek, parameters, `plays` (`match_play` with clip, mode and the options of
  `Match_Play_Options`), actions, targets and controls of modifiers, targets of warping windows,
  locomotion, distance and the control of a `Keyframe_Path`.
- Intents, which write to those same queues:
  - `locomote`: the forward velocity of the orientation and stride warping (asks for the `.motion`)
    and, with root motion, the target of the `locomote` window. It does not move the body, which
    belongs to its controller (root delta or `Move_Input`), nor does it plan paths.
  - `look` and `reach`: target and fade of the head's Look or of the IK that ends at the hand;
    requesting them turns the operation on even if the profile stores it off.
  - `gesture`: fires or cancels the action of a gesture.
- In Edit only `stop`, `parameters` and Play/Pause/Speed of `sequence` are valid, as an undo step;
  everything else asks for Play or Simulation and the `fix` proposes `animation.preview` with the
  same fields.
- What an intent lacks (no Look in the profile, no gesture) fails with the method that creates it.
  The result lists what was applied.
- A parameter is named as in the graph or in an axis of its blend spaces (case-sensitive): it is
  valid only with an `.agraph`; those of a graph respect its range and those of an axis are
  projected to the edge. `Animation.library` changes the library that `inspect` and `preview` also
  use.

`goals` and `controls`:

- A control does not change targets or contact: `weight` is a multiplier independent of the
  definition, the target and the component, and `enabled=false` with a fade fades out before turning
  off. `Limit`, `Twist`, `Chain_Retarget` and `Corrective` have only controls.
- A goal of IK, Look, Chain/Multi/Spline IK or Follow requires `target` in the space of what it
  names (`World` by default; `Entity`, `Bone` or `Socket` with its `entity`, the rig for bones and
  sockets); Multi IK names its effector and Spline IK its control. A field that does not correspond
  to the kind is rejected with its path.
- Operations are named as `animation.inspect` part `Modifiers` lists them: IK and Contact by the
  path of `end`, Look and Limit by `bone`, Grounding by `body`, the others by their name. An
  ambiguous name fails without enqueuing; the target follows its operation if the profile is read
  again.
- Chain_Retarget uses `Animation.retarget` and `Animation.source`; the others,
  `Pose_Modifiers.profile`. In Edit the defaults are edited with `pose.profile.set`.
- The Grounding diagnostic gives residual and angular error against the active targets of the final
  pose, locked legs and `reached`; it does not consider the thickness of the mesh.
- Solvers: [rigs](animation-rigs.md); actions: [actions](animation-actions.md); `.motion`, warping
  and distance: [motion](animation-motion.md).

`animation.preview` clones the world and applies the fields of `request`, with `time`, `ticks` and
`dt` instead of stop, seek and sequence; `plays` and actions can be scheduled per tick. It returns
paged local poses, the program and, with `trace`, per tick the leaves and layers with their
effective weights, markers, curves, root, what the matching touches, actions, problems and the last
modifier request that did not find its destination; `trace_truncated` says whether pages remained
or the budget ran out. `program` and `trace` are always present. Everything is released with the
copy: it touches no document, renderer or displayed world. `animation.capture`
([previews](../../mirai-plugins/references/previews.md)) shows the same copy in images.

`animation.pose.bake` bakes the final pose of an entity between `start` and `end` into a clip:

- It runs like `preview`, on a copy without gameplay or physics and with its fields: an intent (a
  `look`) ends up baked. The last interval falls at `end`.
- Each animated bone or node gives position, rotation and scale tracks even if no source animates
  it; also the composed curves, the correctives and the weights of [morphs](animation-morphs.md)
  (`"<path>/@morph/<target>"`). Crossed markers fall where they were crossed.
- `root_motion` `Preserve` stores the root and its metadata; `In_Place` fixes it at its reference. A
  change of root bone in the range, or a problem of the evaluation, fails without publishing, with
  its code.

`animation.sequence.*` configures, captures and tests the sequence of a `Keyframe_Path`
([sequences](animation-sequence.md)); in Edit it is a scene transaction and its control is
`sequence` of `animation.request`.

## Verification

The authoring tests invoke `api.method_execute` with real files and typed schemas, in
`plugins/animation/editor` (with `-collection:plugins=<root>/plugins`):

- `body_api_test.odin`, `clip_edit_test.odin`, `setup_test.odin`, `request_test.odin` and
  `inspect_test.odin`: body, verbs with metrics, character recipe, intents and inspectors, over a
  rig with mesh and body.
- `program_api_test.odin`: graphs named without order, `dry_run`, revision and controls through
  `animation.request`; `authoring_patch_test.odin`: fields and transitions with `feel`.
- `authoring_actions_test.odin`, `authoring_constraints_test.odin`, `preview_trace_test.odin`,
  `source_authoring_test.odin`, `pose_bake_test.odin` and `morph_api_test.odin`.
- The file history is tested in the editor (`editor/edits_files_test.odin`).

In an open build: `engine.describe`, create sources in a test folder, inspect them with
`mirai asset` and evaluate a copy with `animation.preview` or `animation.capture`. CPU tests do not
prove the image: graphics paths require a build, a run and validation of the GPU API.
