---
name: mirai-std
description: Mirai standard library for games, with the packages `std/base`, `std/jobs`, `std/math`,
  `std/anim` (clips, poses, motion matching, inertialization, IK), `std/ai` (A*, tiled navmesh, flow
  fields, steering, utility), `std/input`, `std/geom`, `std/spatial` and `std/subprocess`. Use when
  changing, extending or consuming any of those packages; enemies and NPCs that decide are in
  `mirai-world`.
---

# Mirai standard library

## Map

- Budgeted allocators, handles, fixed-capacity containers, hashing, identities, radix sort and
  profile zones: [allocators](references/base.md#allocators-allocodin),
  [handles](references/base.md#handles-handle_poolodin),
  [containers](references/base.md#containers),
  [hashing, identities and randomness](references/base.md#hashing-identities-and-randomness),
  [radix sort](references/base.md#radix-sort-sortodin) and
  [profile zones](references/base.md#profile-zones-profileodin).
- Work-stealing scheduler and `parallel_for` (a loop function spreads its work with
  them): [workers](references/jobs.md#workers),
  [tasks and counters](references/jobs.md#tasks-and-counters),
  [parallel_for](references/jobs.md#parallel_for),
  [temporary memory](references/jobs.md#temporary-memory) and
  [without threads](references/jobs.md#without-threads).
- Transforms and TRS composition, Euler, cameras, shapes and intersections, scalars, easing, curves,
  random, noise, color and quantization:
  [transform](references/math.md#transform-and-trs-composition-transformodin-typesodin),
  [cameras](references/math.md#cameras-cameraodin),
  [shapes](references/math.md#shapes-and-queries-shapesodin-rayodin-overlapodin-closestodin-cullodin),
  [scalars](references/math.md#scalars-scalarodin),
  [deterministic functions](references/math.md#deterministic-functions-deterministicodin),
  [easing and curves](references/math.md#easing-and-curves-easeodin-curveodin),
  [random and noise](references/math.md#random-and-noise-randomodin-noiseodin) and
  [color](references/math.md#color-and-quantization-colorodin-quantizeodin).
- Tweens, clips, additive blend spaces, poses, blending, IK and retarget:
  [tweens](references/anim.md#tweens-tweenodin-loopodin),
  [clips](references/anim.md#tracks-keys-and-clips-trackodin-clipodin),
  [playback](references/anim.md#playback-and-events-playerodin),
  [blending](references/anim.md#blending-poseodin),
  [blend spaces](references/anim.md#blend-spaces-blend_spaceodin),
  [skeleton](references/anim.md#skeletal-pose-skeletonodin),
  [adaptation](references/anim.md#adaptation-ikodin-retargetodin-followodin) and
  [procedural](references/anim.md#procedural-without-clips-proceduralodin-chain_ikodin).
  - Compressed and cooked clips: [error](references/anim-storage.md#error),
    [sampling](references/anim-storage.md#sampling), [stream](references/anim-storage.md#stream),
    [bit rates](references/anim-storage.md#bit-rates) and
    [access](references/anim-storage.md#access).
  - Motion matching, inertialization, warping and distance to time:
    [matching](references/anim-motion.md#motion-matching-matchingodin),
    [inertialization](references/anim-motion.md#inertialization),
    [warping](references/anim-motion.md#orientation-and-stride-warping) and
    [distance to time](references/anim-motion.md#distance-to-time).
  - Chains, Multi IK, springs, twist, reach with stretch, spline, aiming with an up axis and pose
    samples: [retarget](references/anim-rigs.md#retarget-between-chains),
    [IK](references/anim-rigs.md#ik-with-several-targets),
    [springs](references/anim-rigs.md#springs), [twist](references/anim-rigs.md#twist-distribution)
    and [reach](references/anim-rigs.md#reach-spline-aiming-and-pose-samples-rig_shapesodin).
  - Body map, clip metrics and editing verbs:
    [body](references/anim-body.md#body-map-bodyodin),
    [metrics](references/anim-body.md#metrics-metricsodin) and
    [editing verbs](references/anim-body.md#editing-verbs-editodin-edit_bodyodin).
- A*, grids, flow fields, steering and utility: [A*](references/ai.md#a-search-searchodin),
  [grid](references/ai.md#grid-and-flow-fields-gridodin-flowfieldodin),
  [flow fields](references/ai.md#flow-fields-flowfieldodin),
  [steering](references/ai.md#steering-steeringodin) and
  [utility](references/ai.md#utility-utilityodin).
  - Tiled navmesh, queries, corridor and jump and drop links:
    [navigation](references/ai.md#navigation); its construction from triangles:
    [tiles](references/ai.md#tile-building-nav_buildodin); the volume for what flies or
    swims: [sparse octree](references/ai.md#volume-nav_volumeodin); how the regions of a mesh are
    joined: [coarse graph](references/ai.md#coarse-graph-nav_coarseodin).
  - How an agent decides (scored proposals, actions with Enter, Update and Exit, steps, commit,
    tokens and reservations, trace): [minds](references/ai.md#decisions-minds-mindodin); what to
    use where FSMs, behavior trees, HTN or GOAP were used:
    [equivalences](references/ai.md#instead-of-fsm-trees-htn-and-goap). They are not implemented.
  - Threat, allies and cover over a grid with bounded cost:
    [influence maps](references/ai.md#influence-maps-influenceodin).
  - Perception memory and place queries:
    [perception](references/ai.md#perception-and-places-perceptionodin-placesodin).
- Input actions and device types: [actions](references/input.md#actions-inputodin) and
  [devices](references/input.md#devices-devicesodin). The rules of a game
  (inventories, dialogues, timers, statistics) are not in `std`.
- Meshes, MikkTSpace tangents, convex hull, slicing, fracture, triangulation and convex partition
  of polygons, simplification (meshoptimizer port), clusters and their level DAG, and convex
  decomposition: [data and memory](references/geom.md#data-and-memory),
  [determinism](references/geom.md#determinism-precision-and-tolerance),
  [surface editing](references/geom.md#surface-editing-surface_editodin),
  [booleans](references/geom.md#solid-booleans-booleanodin),
  [isosurface](references/geom.md#scalar-field-surfaces-isosurfaceodin),
  [hull](references/geom.md#convex-hull-hullodin),
  [slicing](references/geom.md#plane-slicing-sliceodin),
  [fracture](references/geom.md#voronoi-fracture-fractureodin),
  [triangulation](references/geom.md#primitives-and-triangulation),
  [simplification](references/geom.md#simplification-simplifyodin),
  [clusters](references/geom.md#clusters-and-dag-clusterodin-partitionodin-cluster_dagodin),
  [decomposition](references/geom.md#approximate-convex-decomposition-decomposeodin) and
  [tangents](references/geom.md#tangents-tangentsodin).
- Uniform grid, spatial hash and octree: [contract](references/spatial.md#common-contract),
  [grid](references/spatial.md#grid-uniform-grid-and-spatial-hash),
  [octree](references/spatial.md#octree-loose-octree) and
  [which to use](references/spatial.md#which-to-use). The AABB tree and the
  BVH are in [physics](../mirai-physics/references/physics.md#stdspatial).
- Streams, schemas, hashes, import and migration of values (`std/serial`):
  [std/serial](../mirai-assets/references/serial.md#stdserial).
- What the structure of a `.ui` is judged by (`std/ui_format`):
  [interface](../mirai-assets/references/kinds.md#interface).
- Child processes without console windows: [API](references/subprocess.md#api) and
  [Windows](references/subprocess.md#windows).

## Workflow

1. Before adding something, check whether `core:` already does it with the contract of Mirai
   (explicit capacity, no hidden growth, plain data): use it or wrap it and implement only what is
   missing. `odin root` shows the installation whose `core/`, `base/` and `vendor/` the compiler
   uses.
2. Each piece goes in its own file of the package, with its tests in `*_test.odin` named as
   sentences, including the cases of exhausted capacity and of use before initialization.
3. A new hot path carries its measurement in `bench_test.odin`; an optimization without a measured
   improvement is reverted.
4. When changing a behavior, update the reference of the package.

## Invariants

- State lives in the structure that the caller initializes with capacity and allocator, or over
  memory that the caller hands over (`*_init_buffer`).
- Stable paths do not grow: an insertion without room returns `false`, `nil` or handle 0 and adds to
  `failed` (`Usage` in containers, `Alloc_Stats` in allocators). Creation and destruction, the
  explicit growths of `Hash_Map` and `Region` and geometry processing are transactions
  ([base](references/base.md), [geom](references/geom.md)).
- A zeroed structure is safe: its operations fail without accessing memory. The tests cover it for
  each container.
- No public function terminates the process or hangs because of what it receives
  ([AGENTS.md](../../../AGENTS.md#principles)). Sizes that overflow, alignments that are not a power
  of two, indices and handles out of range, short buffers, NaN and infinities give an error or a
  defined result, which the package reference gives. Validations go at the entry of the function,
  outside the loops.
- **No game rules in the standard library.** `std` has algorithms and structures that the engine
  uses; it brings no inventories, dialogues, waves, sequences, objectives, timers, statistics,
  console, localization or procedural generation: a game writes them with
  [game data](../mirai-core/references/core.md#game-data).
- **One mind, no FSM, BT, HTN or GOAP.** AI decides with a single model in `std/ai`, the mind
  ([minds](references/ai.md#decisions-minds-mindodin)): on each tick the game's `think` proposes
  scored actions, the highest wins, and actions are procedures with `Enter`, `Update` and `Exit`;
  what the agent knows lives in its components, and the scenario is used through smart objects and
  influence maps in `behavior`.
- In `anim`, `ai` and `input`:
  - The shared definitions (`Library`, `Match_Database`, `Utility`, `Navmesh`, `Input`) are created
    with fixed capacities and do not change when used.
  - The state of what is played or decided (`Player`, `Fader`, `Inertial_State`, `Mind`,
    `Action_State`) is plain, without pointers or slices, and is copied for snapshots.
- Containers and allocators are not safe across threads, except `Spsc_Queue` (one producer and one
  consumer) and the profile zones (one ring per thread).
- `Handle(0)` is null. A released handle never becomes valid again, not even after
  `handle_pool_clear`.
- The `std/math` package is declared `mirai_math` because Odin requires unique package names and
  `core:math` already uses `math`. It is imported as `import "mirai:std/math"`; a file that also
  needs `core:math` gives another name to one of the two.
- TRS composition is `transform_compose`: do not replace it with a product of affine matrices
  (it introduces shear) or reorder it (it is not associative: the world is composed from the root).
- Conventions: right-handed, Y up, radians, column vectors; everything looks toward −Z; inverted
  depth from 1 (near) to 0 (far); Euler is applied X, then Y, then Z.
- What a seed reproduces (`Rng`, distributions, lattice noise, Euler to quaternion) uses only
  arithmetic, square root and the software functions of `core` (`sincos`, `ln`, `atan2`), never
  `sin`, `cos`, `pow` or `exp`, which depend on the C library of each platform.
- Odin's `min`, `max` and `clamp` on floats pay to order NaN: on hot paths use comparison and
  selection (`float_min`, `vec3_min` in `shapes.odin`).
- The values of `Ease` and the format of `normal_pack`, `quat_pack`, `rgba8_pack` and the hex texts
  of identities are stored or replicated data: do not change them without versioning their
  consumers. `transform_test.odin` and `packed_normals_match_the_legacy_vertex` pin them: if they
  fail, a contract changed.

## Odin notes

- In `fmt.*printf` and `fmt.sbprintf`, a literal brace is written `{{` or `}}`.
- To generate code, JSON or Slang, plain `strings.write_string` is preferable.

## Verification

- `mirai test std/<package>` of the affected package; if the change is limited to one file, only its
  tests. `std/base` also with `-vet` if it changes.
- After touching memory or threads, repeat `std/base` with `-define:MIRAI_PROFILE=false`, and with
  `--release` only if a failure may depend on optimization.
- The `hostile_test.odin` of each package except `subprocess` calls its public functions with random
  inputs from `base.Hostile` and holds every result to its contract: a reference model, the
  documented range, a structure unchanged by what it refused, nothing left allocated
  (`-define:<PACKAGE>_HOSTILE_ROUNDS=n`, e.g. `BASE_HOSTILE_ROUNDS`). After touching a validation
  or a path with `#no_bounds_check`, repeat them with `--release` and 20000 rounds, and once over a
  copy of the package without `#no_bounds_check`.
- `random_values_repeat_for_a_seed` and `lattice_noise_is_bounded_smooth_and_repeatable` pin exact
  values recorded on Windows x86-64: if they fail on another platform, reproducibility broke, not
  the test.
- Cases and flags per area: [jobs](references/jobs.md#verification),
  [anim](references/anim.md#verification), [ai](references/ai.md#verification),
  [geom](references/geom.md#verification), [spatial](references/spatial.md#verification),
  [subprocess](references/subprocess.md#verification).
