---
name: mirai-physics
description: Modify, use and verify Mirai physics - the `physics` plugin (the
  `plugins/physics/runtime/sim` solver with bodies, joints, queries, character, breakable bodies and
  snapshots, the `plugins/physics/runtime` integration with character locomotion, and its editor
  part) and the `destruct` plugin, which makes a `Destructible` a breakable body. Use when changing
  the solver, breaking things, writing gameplay with bodies and characters (walk, jump, fly, swim,
  `Character`, `Walk`, `Swim`), working with buoyancy and drag of `Fluid`s, with `Force_Field`s,
  `Strain_Field`s and area forces (the drawn water
  is in `mirai-world`) or changing how the simulation is reflected in entities.
---

# Mirai physics

Physics is a first-party plugin that a project activates. Its solver
(`plugins/physics/runtime/sim`, package `mirai_physics`, imports only `std/*`) is the model and
does not know what an entity is. The integration (`plugins/physics/runtime`) uses it on the world
tables and is the only package that imports it. The game and the other plugins, `destruct` among
them, use the public API of the integration, never the solver. It shares `core` tables with
networking ([networking](../mirai-networking/SKILL.md)).

## Map

- Bodies, shapes, step, joints, queries, snapshot, debug draw →
  [bodies and shapes](references/physics.md#bodies-and-shapes), [step](references/physics.md#step),
  [joints](references/physics.md#joints), [queries](references/physics.md#queries),
  [snapshot](references/physics.md#snapshot-and-determinism) and
  [debug draw](references/physics.md#debug-draw)
- `std/spatial` → [physics.md#stdspatial](references/physics.md#stdspatial)
- Water: fluid volumes, buoyancy, drag and the surface query →
  [physics.md#fluids](references/physics.md#fluids); the character in a fluid →
  [character.md#in-a-fluid](references/character.md#in-a-fluid); `Fluid`, `fluid_at`,
  `fluids_in` → [engine.md](references/engine.md#components)
- Physical character (capsule, support, `Character_Move`) →
  [data and lifecycle](references/character.md#data-and-lifecycle),
  [the body](references/character.md#the-body) and [step](references/character.md#step);
  its own vertical (walking around a planet, `core.Vertical`) →
  [character.md#the-vertical](references/character.md#the-vertical)
- Walk, jump, fly, swim, layered movements, seat control, game modes →
  [engine.md#locomotion](references/engine.md#locomotion); at normal speed in slow motion
  (`core.Own_Pace`) → [engine.md#own-pace](references/engine.md#own-pace)
- Breakable bodies of the solver (pieces, bonds, clusters, damage, cut, state, copy) and their
  facade `physics.breakable_*` → [with the world](references/destruction.md#with-the-world),
  [construction](references/destruction.md#construction),
  [damage and fields](references/destruction.md#damage-and-fields),
  [removal](references/destruction.md#removal), [cut](references/destruction.md#cut) and
  [reading and replay](references/destruction.md#reading-and-replay)
- `Rigid_Body`, `Collider`, `Character`, `Joint`, requests, queries, pose targets, proxies →
  [components](references/engine.md#components),
  [collider fields](references/engine.md#collider-fields),
  [binding and world step](references/engine.md#binding-and-world-step),
  [requests](references/engine.md#requests) and [queries](references/engine.md#queries)
- Categories and presets declared in code, sensors, `Collision_Settings` and pushes →
  [collision](references/engine.md#collision-categories-and-presets)
- Solver push rules (pairs that yield) →
  [physics.md#contact-rules](references/physics.md#contact-rules)
- A body in two places and shapes cut by boxes (`Body_Twin`, `Collider_Cuts`, the portals) →
  [physics.md#twins-and-cuts](references/physics.md#twins-and-cuts)
- `Destructible` in the data world, requests, reflection, networking →
  [components](references/engine-destruct.md#components),
  [configuration and setup](references/engine-destruct.md#configuration-and-setup),
  [requests and movement](references/engine-destruct.md#requests-and-movement),
  [reflection, queries and events](references/engine-destruct.md#reflection-queries-and-events)
  and [network](references/engine-destruct.md#network)
- Breaking or digging terrain (craters, debris, pieces with physics per material): not `destruct`
  → [what can be dug](../mirai-world/references/terrain.md#what-digging-leaves)
- Bodies a library makes from its own data (the cells of a foliage, what breaks), the capacities
  of the simulation, who may import the solver → [owned bodies](references/engine.md#owned-bodies)
- `core.place` on a body → [engine.md#requests](references/engine.md#requests);
  `core.World_Queries` (cameras, feet) → [engine.md#queries](references/engine.md#queries)
- Editor part (collider preset, collision settings, `physics.collision.*` API, Simulate, Collision
  view modes) → [engine.md#editor-part](references/engine.md#editor-part)

## Workflow

1. Locate the step stage (`world_step` in `plugins/physics/runtime/sim/solver.odin` runs them in
   order) and its file:
   - `contact.odin`: pairs and narrow phase. `collide.odin`, `gjk.odin`, `mesh.odin`: contact
     geometry.
   - `solver.odin`: colors, stage order. `island.odin`: persistent islands, splitting and sleep.
   - `contact_solver.odin` and `joint_lanes.odin`: contacts and joints in lanes.
   - `joint.odin`, `ccd.odin`, `radial.odin` (volume forces and falloff), `query.odin`,
     `snapshot.odin`.
   - `fluid.odin` (volumes and surface query) and `fluid_load.odin` (buoyancy, damping and drag
     per substep).
   - `character.odin`: support, ground probe at the end of the step, constraint and push.
   - `breakable.odin` (pools, pieces, bonds, regrouping, cut and the end of the step),
     `breakable_damage.odin` (regions, clusters, removal) and `breakable_state.odin` (the state
     without geometry).
   - `debug_draw.odin`: lines and points for a debug view.
2. Decide whether the new data is **state** or **scratch**.
   - State: lives in `Body`, `Shape`, `Contact`, `Joint`, `Joint_Axes`, `Island`, `Manifold_Block`,
     `Character`, `Breakable`, `Piece`, `Bond`, `World_State` or the trees, and enters the snapshot
     through `snapshot_blocks`.
   - Scratch: lives in `Step`, `World.manifolds` or the events and is rebuilt every step.
3. Write the test next to the code (`*_test.odin`, name as a sentence) and run only the affected
   ones.
4. If the behavior changed, update the reference of the topic.

## Invariants

- **Own implementation in Odin.** `physics` is implemented from scratch in Odin. Jolt guides the
  architecture and the collision algorithms; Box2D v3 and Box3D, the substepped soft-constraint
  solver and the data design; Chaos, cluster destruction and the physical character.
- **Determinism.** The same state and the same calls give the same result in the same binary, with
  any number of workers: nothing depends on addresses or thread arrival order, new pairs are sorted
  before creating contacts, parallel stages write only to their own element and shared consequences
  (events, waking, destroying contacts) are applied afterwards, in index order.
- **Everything that influences a future step is in the snapshot.** A cache that changes the path of
  the narrow phase is state. On restore, slots used after the snapshot go back to zero so that
  generations repeat.
- State structs without padding or pointers, with `#assert(size_of(...))`: they are copied and
  hashed in blocks.
- **No allocation in the step.** Memory is reserved in `world_init` according to `World_Desc`; an
  exhausted capacity returns a null handle and adds to `Stats`. Shared geometries (`hull_create`,
  `mesh_create`, `heightfield_create`) are transactions that allocate.
- The box and triangle topology tables are `@(rodata)`.
- Shape A of a contact is the one with the greater type (`Shape_Type`); the narrow phase has one
  routine per unordered pair. Manifolds are expressed in the frame of shape A and the normal goes
  from A to B.
- The solver has no game rules: the character is supported, climbs steps and pushes according to
  the `Character_Move` it receives, and whoever writes it decides walking, jumping or flying. Its
  ground is the one from the end of the previous step, probed again only if it became stale; its
  moves run in parallel and their consequences on other bodies are applied afterwards, in slot
  order. The character constraint does not keep impulses between steps.
- What breaks is state of the world: no package outside the solver holds a part of a breakable, so
  a snapshot, a restore and a copy cannot take the bodies without it. Its pools are made with the
  first breakable: a world that breaks nothing holds none.
- A break event carries no geometry, and applying it to a world in the same state gives the same
  state. One limited to the body of a piece does not depend on where the other bodies are: it is the
  one that travels over the network.
- The frame of each body of a breakable is the frame of the breakable: the shapes of its pieces
  have an identity local transform.
- Breaking changes bodies and shapes at the end of `world_step`, once its hits are gathered, or
  between steps, never in the middle of the solver. An event of a step carries the user data its
  bodies and shapes had when it was raised: a break may end them before the event is read.

### Library invariants

- Rows are the authority on what exists; the simulation, on the pose of what has a body. Whoever
  moves a body sends a request to `Body_Requests`; whoever teleports it uses `core.place`; whoever
  imposes the pose of another owner writes `core.Pose_Target`; whoever owns a body of another
  library uses proxies. Nobody writes the `Transform` of a body.
- Only the physics plugin imports the solver: `mirai check` refuses the import in any other
  package of the engine, tests and tools included, and in a game. A library makes static collision
  of its own with the owned bodies of the integration, and what breaks with its breakables.
- A Character's body and its look both face -Z.
- A character moves only through its `Character_Move`: locomotion writes it and, in a game mode,
  the step of that mode writes it first, to which locomotion only adds the layered movements.
- A tool that moves bodies uses `manipulation_target`/`manipulation_end`; a preview that only needs
  physics uses `step_world`
  ([requests](references/engine.md#requests),
  [step outside the loop](references/engine.md#physics-step-outside-the-loop)). Do not duplicate
  the step or write poses outside the owner.
- Changes of configuration, motors, axes and target pose of joints go through `Joint_Requests`;
  `physics_step` writes `Joint` and `Joint_State`. The world rotation is converted to the frames
  after reconciling them.
- Proxies accept the same forces, manipulation and constraints; whoever owns the body removes it
  before destroying it.
- Everything that influences a future step is in a table (`core.Motion`, `Character_State`,
  `Character_Move`, `Character`, `Joint_State`, `Destructible_State`) or in the snapshot of
  `Physics_State`: this allows copying the world for rollback and saves. The reflection of
  destruction always comes from the simulation state, never from the event that changed it.
- `physics_step` and `destruct_step` are simulation: they run in `fixed` and repeat in a network
  correction.
- What the simulation rejects (a body, a shape, a joint, a destructible, a request) is a
  [problem](../mirai-core/references/core.md#problems) of the entity with the cause and the field
  of `Physics_Settings` that fixes it; `Physics_State.stats` and `Destruct_Cache.stats` count only
  what was created and removed.
- Collision belongs to the `Collider`: `Character` and `Destructible` do not repeat shape, surface
  or filter. Categories and presets are named ids declared in code; `Collision_Settings` says per
  preset only what differs from the defaults, and the solver only sees a bit `Filter`. A collision
  change re-filters the shape, never rebuilds it. How a kind of actor collides is its preset, named
  by the `Collider` of its prefab, not code that rewrites colliders at run time
  ([kinds of actors](references/engine.md#collision-categories-and-presets)).

## Verification

- Packages: `plugins/physics/runtime/sim` (the solver), `std/spatial`, `plugins/physics/runtime`,
  `plugins/physics/editor`, `plugins/destruct/runtime` and `plugins/destruct_multiplayer/runtime`.
  Run only the `*_test.odin` of the touched topic.
  - Solver: `ccd*`, `contact_rules`, `joint`, `six_dof`, `radial`, `character`,
    `mesh`, `query`, `static` (triangles and change log of static collision),
    `debug_draw`, `world` (stacks and pyramid), `snapshot`, `snapshot_fuzz`, `fluid`,
    `collide`, `gjk`, `cylinder` and `convex_radius` (shapes and rounding); `solver` (overflowed
    pairs, inertia, islands, uncolored constraints); `far` (the same scene 20 km from the origin);
    `breakable`, `breakable_damage`, `breakable_state` and `breakable_world` (what a step, a
    snapshot and a copy do with what breaks).
  - Integration: `collision`, `forces`, `geometry`, `joints`, `manipulation`, `reload`,
    `static`, `teleport`, `fluids`, `sync` (sealed rows against the full reconciliation),
    `breakables` (the facade, its copies and `strain_area`);
    locomotion: `locomotion` (walk, jump, coyote, layers, flight, swimming, modes),
    `locomotion_moves` (crouch, slide, mantle, tactical sprint, ledge jump), `planet` (own
    vertical: walking, jumping and rollback on a planet, crossing fields) and `locomotion_seat`
    (seat control, relative forward). Editor: `collision`, `api_collision`, `colliders`,
    `view_mode`. `destruct`: `integration`. `geometry_test` does not need a GPU. Grounding with real
    bodies: `demo/game/grounding_physics_test.odin`.
- Twins and cuts: the tests of `plugins/portals/runtime` (half crossed, walls of any collider, the
  twin that leaves, snapshot).
- A change in step, contacts, solver, CCD, joints or characters keeps determinism:
  `snapshot_test`, `snapshot_fuzz_test`, `worker_threads_give_the_same_result_as_one_thread`
  (`bench_test`) and the worker tests of `solver_test`.
- `.fracture`: [assets](../mirai-assets/SKILL.md). Debug draw and selection:
  [editor](../mirai-editor/SKILL.md#verification). Gameplay and networking:
  [engine.md#verification](references/engine.md#verification).
- Measurements (the table goes in the final report of the task):

  ```sh
  mirai test plugins/physics/runtime/sim bench_steps bench_snapshot bench_characters \
    bench_ccd bench_shapes bench_fluids --release -define:PHYSICS_BENCH=true
  mirai test plugins/physics/runtime/sim bench_wall bench_destruct --release \
    -define:PHYSICS_BENCH=true
  mirai test plugins/physics/runtime/sim bench_colors bench_friction bench_sleep --release \
    -define:PHYSICS_BENCH=true
  mirai test std/spatial --release -define:SPATIAL_BENCH=true
  ```

  The `physics` scenario of `scripts/bench_compare.py` compares CCD with an isolated base.
