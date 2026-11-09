---
name: mirai-std
description: Mirai standard library for games, with the packages std/base, jobs, math, anim (clips,
  poses, motion matching, inertialization, IK), ai (minds, navigation, influence), input, geom,
  spatial and subprocess. Use when changing, extending or consuming any of those packages, or when
  deciding how an enemy or an NPC thinks.
---

# Mirai standard library

## Map

- Budgeted allocators, handles, fixed-capacity containers, hashing, identities, radix sort and
  profile zones: [std/base](references/base.md).
- Work-stealing scheduler, `parallel_for` and task graphs (`host` uses them to give threads to the
  loop): [std/jobs](references/jobs.md).
- Transforms and TRS composition, Euler, cameras, shapes and intersections, scalars, easing, curves,
  random, noise, color and quantization: [std/math](references/math.md).
- Tweens, clips, additive blend spaces, poses, blending, IK and retarget:
  [std/anim](references/anim.md).
  - Compressed and cooked clips: [anim-storage](references/anim-storage.md).
  - Motion matching, inertialization, warping and distance to time:
    [anim-motion](references/anim-motion.md).
  - Chains, Multi IK, springs, twist, reach with stretch, spline, aiming with an up axis and pose
    samples: [anim-rigs](references/anim-rigs.md).
  - Body map, clip metrics and editing verbs: [anim-body](references/anim-body.md).
- A*, grids, flow fields, steering and utility: [std/ai](references/ai.md).
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
- Input actions and device types: [std/input](references/input.md). The rules of a game
  (inventories, dialogues, timers, statistics) are not in `std`.
- Meshes, MikkTSpace tangents, convex hull, slicing, fracture, triangulation and convex partition
  of polygons, simplification (meshoptimizer port), clusters and their level DAG, and convex
  decomposition: [std/geom](references/geom.md).
- Uniform grid, spatial hash and octree: [std/spatial](references/spatial.md). The AABB tree and the
  BVH are in [physics](../mirai-physics/references/physics.md#stdspatial).
- Streams, schemas, hashes, import and migration of values (`std/serial`):
  [std/serial](../mirai-assets/references/serial.md).
- Child processes without console windows: [std/subprocess](references/subprocess.md).

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
  inputs and only requires that they return (`-define:<PACKAGE>_HOSTILE_ROUNDS=n`, e.g.
  `BASE_HOSTILE_ROUNDS`). After touching a validation or a path with `#no_bounds_check`, repeat them
  with `--release` and 20000 rounds, and once over a copy of the package without `#no_bounds_check`.
- `random_values_repeat_for_a_seed` and `lattice_noise_is_bounded_smooth_and_repeatable` pin exact
  values recorded on Windows x86-64: if they fail on another platform, reproducibility broke, not
  the test.
- Cases and flags per area: [jobs](references/jobs.md#verification),
  [anim](references/anim.md#verification), [ai](references/ai.md#verification),
  [geom](references/geom.md#verification), [spatial](references/spatial.md#verification),
  [subprocess](references/subprocess.md#verification).
