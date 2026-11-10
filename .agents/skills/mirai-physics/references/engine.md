# Plugin `physics`: the integration

The solver (`plugins/physics/runtime/sim`, package `mirai_physics`; [physics](physics.md),
[character](character.md)) does not know the data world; the plugin library
(`plugins/physics/runtime`) connects it with the tables, in the same dynamic library. A game or
another plugin imports `phys "plugins:physics/runtime"`, never the solver.
Destruction is the [destruct](engine-destruct.md) plugin; the [editor part](#editor-part) is
`plugins/physics/editor`. Fields, defaults and constructors (`collider_*`, `joint_*`,
`character_default`) are in `components.odin` and in `engine.describe`.

Rows are the authority on **what exists** (`Rigid_Body`, `Collider`, `Character`, `Joint`); the
simulation (`sim.World`), on **the pose** of every entity with a body. `Rigid_Body` and `Character`
own the `Transform` (`locks="core.Transform"`): the game moves through requests. A lone or compound
`Collider` follows the transform of its entity.

## Components

- `Rigid_Body`: `type` (`Static`, `Kinematic`, `Dynamic`; constants
  `RIGID_BODY_DYNAMIC|KINEMATIC|STATIC`), `mass` (0: comes from the density of the colliders),
  damping, `gravity_scale`, per-axis `locks` and `bullet`.
- `Collider`: shape, surface and collision of the entity ([fields](#collider-fields)). Constructors
  `collider_box|sphere|capsule|cylinder|hull|mesh|heightfield|fracture` and
  `collider_character(radius,height)`.
- `Character`: moves the entity's `Capsule` `Collider` like the solver's
  [physical character](character.md), which supports itself, climbs steps and pushes.
  - Its `Transform` is the position of the feet and the rotation, whose +Y is its
    [vertical](character.md#the-vertical) and whose -Z faces the yaw of its move, its look; the
    capsule rests on the feet (the controller sets its `center` and its surface).
  - `up_speed` (degrees per second): how fast its vertical turns toward the opposite of its
    gravity, to walk around a planet; with 0 it stays fixed. Changing it does not recreate the
    character.
  - From the capsule it takes radius, height (`2 × (X + Y)` with the scale) and collision; `mass`
    zero takes it from its density. It only stores physical settings: walking, jumping and flying
    belong to [locomotion](#locomotion).
  - Changing the capsule size, `mass` or `step_height` recreates the character; changing its
    collision only changes the filter.
  - `push_force` (N): cap of the traction passed to a dynamic it leans against
    ([push](character.md#push)); zero uses all the traction. Changing it does not recreate the
    character.
  - `density` (kg/m³): that of its body in a fluid ([in a fluid](character.md#in-a-fluid)); the
    `drag` of its capsule is the `Cd` of its body.
  - `character_default()` (an 80 kg human) goes with `collider_character()`.
  - Without a capsule the character is not created and it is the entity's
    `physics.character_capsule` problem; without room in `Physics_Settings.characters`,
    `physics.characters`.
- `Character_Move` (`shared`): the `sim.Character_Move` that drives the character from the next step
  (ground and air drive, launch, yaw and flags). Locomotion writes it, or in a game mode the step of
  that mode and then locomotion, and `physics_step` hands it to the solver. Without it, the
  character stays where it is.
- `Character_State` and `core.Motion`: what the last step left. `Character_State` says whether it is
  supported and the ground that the end of the step found (walkable, distance, normal, velocity and
  `ground_turn`), which is the one the next step will use, the normal of the wall it leans on
  (`wall_normal`, zero without one), and how much it is in a fluid (`fluid`, `submersion`,
  `head_depth`, `depth` and the current), and its `velocity`. Only the simulation writes them; a
  save
  restores them. Whoever writes the `Character_Move` adds `ground_turn` (how much the ground turned
  the character) to the yaw every step.
- `core.Vertical`: the vertical frame of each character, for whoever reads it outside physics (the
  camera that follows it, the game). `physics_verticals` writes it (`fixed`, after `physics_step`)
  from the solver state, which is the owner; it is `transient`: a character that is rebuilt takes
  the frame of its rotation.
- A turned-off `Rigid_Body`, `Collider` or `Character` (by itself or with its entity,
  [turned off](../../mirai-core/references/core.md#disabled-entities)) leaves the simulation like a
  removed one (in batches, see [binding](#binding-and-world-step)), but keeps its values and its
  `core.Motion`: on turning on, the body is rebuilt where its `Transform` is and with that velocity.
  While it is off it does not own the `Transform`.
- `Fluid`: water or another fluid in the
  [`Volume`](../../mirai-gameplay/references/libraries.md#volume) of its entity
  ([fluids](physics.md#fluids)): a `Plane` (below the height of the entity) or a
  `Box` (its extents times the scale), with density and current in the frame of the entity; with
  zero density, a dry box over the fluids of lower `Volume.priority`. The entity's yaw turns the
  box and its current; the blend and the mode of the `Volume` do nothing to a fluid. It is
  `replicated`: a flood that the server decides reaches the clients.
- `Force_Field`: a force that lasts on the bodies in the `Volume` of its entity (any shape; without
  one, the whole world). `force_fields_step` (`fixed`, before `physics_prepare`) asks `apply_area`
  for it each tick while it is on; its `along` turns with the entity. The editor part draws where
  a selected one pushes (`force_field_preview`).
- `Joint`, `Joint_State`: joins the body of the entity with that of `target` (or with the world if
  it is `NONE`). Types `Fixed`, `Spherical`, `Revolute`, `Prismatic`, `Distance`, `SixDOF`, with
  limits, drives, motor, spring and breaking. The configuration, the captured frames and the
  breaking are replicated. Constructors: `joint_fixed|spherical|revolute|prismatic|distance|sixdof`.
- `Body_Twin` and `Collider_Cuts`: the [twin and the cuts](physics.md#twins-and-cuts) as rows that
  another library (the portals) writes.
  - `Body_Twin` gives the body of its entity (`Rigid_Body`, `Character` or proxy) a second place:
    copies of its colliders where `through` takes it, which collide in front of the plane of `point`
    and `normal` and push the body back.
  - `Collider_Cuts` removes from contacts and queries what of its collider is in its boxes; of all
    the colliders of the body if the entity has one of its own.
  - `physics_twins` (`fixed`, between `physics_places` and `physics_step`) takes them to the
    simulation: a body that the step rebuilds receives them in the next tick. Without room or with
    non-finite values, `physics.twin` or `physics.cuts`.

## `Collider` fields

- Without a body of its own or of an ancestor, the collider is static. A compound body can have
  surfaces with different frictions. The graphic material does not determine friction or bounce;
  there is no physical material asset.
- The capsule of a `Character` has zero friction: its drives move it, with `traction_force` as the
  cap, and the friction of the ground does not define how much it slips.
- `COLLIDER_DEFAULT` (also when adding it from the inspector) uses the `Default` preset without
  group: a door with a new collider blocks everything. The inspector shows all fields, also those
  that do not correspond to the `kind`. Adding a `Character` or a `Destructible` (editor or API)
  adds `collider_character()` or `collider_fracture()` if the entity has no collider.
- `kind`: `Hull`, `Mesh` and `Heightfield` read the entity's `Mesh_Renderer`; `External` leaves the
  shape to another plugin (`destruct`, for the pieces), which takes surface and collision from this
  collider. `Mesh` and `Heightfield` contribute no mass and are for static geometry: nothing rejects
  a dynamic with them, but that case has no coverage.
- A `Hull` whose mesh has several convex pieces (`host.assets_collision_hulls`: those of a generated
  mesh, or the shapes a `.mesh` stores without a collision mesh) is one shape per piece on the same
  body, with the collider's surface, filter and density; otherwise it is the hull of all the points.
  It fits in the hull budget whole or not at all.
- `size` is multiplied by the absolute world scale: the sphere takes the largest; capsule and
  cylinder, the largest of XZ for the radius and Y for the height.
- `convex_radius` rounds the edges of `Box`, `Cylinder` or `Hull` without changing their size
  ([geometry](physics.md#geometry)) and is scaled by the smallest axis. It must stay below the
  smallest half-axis, the radius and half the height of the cylinder, or the distance from the hull
  center to its nearest face; otherwise the shape is not created (`physics.convex_radius`).
- `friction` is combined by geometric mean and `restitution` by maximum. `density` gives mass and
  inertia except for `Rigid_Body.mass > 0`, which sets the total mass; collision does not change
  mass: a child trigger that must not weigh uses zero density.
- `preset`, `sensor`, `belongs` and `collides`: the [collision](#collision-categories-and-presets);
  with a preset that is not `Custom` the last three are not used.
- `group`: entity. Colliders with the same `group` never meet (ragdoll, vehicle, projectile and
  whoever fired it). As a reference, it is remapped in prefabs, scenes, saves and network.
- `drag` (from 0): the `Cd` of the shape in a fluid; zero takes the measured value of its `kind`. It
  is applied without rebuilding the shape, like the surface.
- `surface_speed` (m/s, entity frame), `one_way` (+Y of the entity) and `dominance`: the
  [contact rules](physics.md#contact-rules) of the shape. A belt carries bodies and characters at
  its velocity without moving.
  - Changing them does not rebuild the shape or discard its contacts: synchronization applies them
    with `shape_set_surface`, also to the capsule of a `Character`.

`Heightfield` uses the compact descriptor that `host.assets_heightfield` delivers for a generated
mesh: it copies the heights without triangles or BVH and keeps the diagonal of the model, which the
drawing must use the same way. It does not admit two surfaces at the same XZ coordinate (a cave
requires `Mesh`); through the `holes` cells one falls into a cave modeled separately. Generated
meshes can carry `disabled_edges` and heightfields `disabled_borders`, cooking metadata that
suppresses edges shared between chunks ([physics](physics.md#geometry)); `collision_edge_active`
exposes the criterion to classify with neighboring geometry.

## Collision: categories and presets

- A collider **belongs** to categories (`belongs`) and **collides with** categories (`collides`).
  Two colliders meet when each belongs to a category the other collides with
  ([filters](physics.md#filters)).
- They block unless one is a **sensor**, which blocks nothing and reports what overlaps it among
  the categories of its `collides`: a zone that only sees the player collides only with `player`.
- What a collider is comes from its **preset**, shared by the colliders that name it, or from its
  fields with `Custom`. Changing a preset in the settings changes all its colliders.
- Categories (`Collision_Category`, whose value is the bit in `Collision_Layers`) and presets
  (`Collision_Preset`, with `PRESET_CUSTOM` as the last value) are named ids declared in code
  (`core/names.odin`): the engine declares the base ones and the game its own
  (`CATEGORY_PLAYER :: physics.Collision_Category(1)`). A category has no settings.
- Text, inspector and API name them; the data store the number: renaming does not touch what is
  saved and changing the number of a constant changes what it means. From code it is written by
  value: `collider.preset=PRESET_TRIGGER`, or `collision_custom` with `collision_layers(...)`.
- **A kind of actor is a preset.** When the player, the enemies and the clips that block only one
  of them collide differently, the game declares a category and a preset per kind
  (`PRESET_ENEMY :: physics.Collision_Preset(2)`), writes what each preset is once in
  `Collision_Settings` (`settings.mirai`, or `physics.collision.set`), and the `Collider` of each
  prefab names its preset: in the inspector, with `asset set` on the prefab, or in the tool that
  writes it. A spawned prefab (the player of a spawn point, an enemy) then collides as its kind
  with no game code, and the navmesh class of those agents names the same preset
  ([navigation](../../mirai-world/references/navigation.md#meshes)). A step that rewrites
  `belongs`/`collides` of a `Collider` at run time to give it its kind is a workaround: change the
  prefab instead.

`Collision_Settings` (project settings storage, flat and copyable) has an entry only per value that
differs from its defaults:

- `presets`: without an entry, a preset is the `Default` category colliding with all; the initial
  value makes `Trigger` a sensor that sees all.
- `pushes`: pairs of categories whose dynamics yield to each other with at most `force`
  ([push rules](physics.md#contact-rules)) and pass through each other, like teammates or a crowd.
- An entry for a value that no code declares is not rejected: `physics_step` reports the first one,
  with how many there are (`physics.collision_settings`). An undeclared preset in a collider is
  `physics.collision` and keeps its number; a push that does not apply, `physics.collision_push`.
- `collision_filter` resolves preset, own collision and group into the bit `Filter` that the solver
  sees. A collision change (preset, sensor, masks, group or settings) re-filters the shape
  (`shape_set_filter`, `character_set_filter`, `breakable_set_filter`), never rebuilds it.
- `collision_off` leaves the collider colliding with nothing; queries pass through it. Over the
  network the `Collider` travels whole
  ([multiplayer](../../mirai-networking/references/multiplayer.md#what-another-library-simulates)).

Overlaps:

- `overlap_begin` and `overlap_end`, one per side; not one per tick of permanence. Static–static
  pairs are omitted; a static zone detects a player even if still.
- They are evaluated when at least one body is awake. A zone that appears over a sleeping dynamic
  body or an idle `Character` may not emit an entry until it wakes. Gameplay keeps its occupants
  if it needs to know who is still inside.
- A `bullet` that crosses a trigger in one tick emits both events in that tick, with `crossed`:
  whoever counts occupants processes the `overlap_begin` before the `overlap_end`. A body that is
  not a bullet and travels in one tick more than the thickness of the trigger and its own can cross
  it without events.

## Binding and world step

- A `Collider` with `Rigid_Body` is on the entity's body. Without it, on that of the nearest
  ancestor that has one (in the relative pose it has) or, if no ancestor has one, on a static body
  of its own. A compound body has several shapes; its children with a collider are not separate
  bodies.
- `Physics_Settings` (storage) sets the capacities when the simulation world is created; zero takes
  the value of the package. Gravity is a component ([gravity](#gravity)). `hulls`, `meshes` and
  `heightfields` budget the resident geometry (the defaults of `sim.world_desc_default` leave room
  for a terrain of hundreds of chunks, one per slot); `events`, the events of each type per tick;
  `breakables`, `pieces` and `bonds`, [what breaks](destruction.md#with-the-world), whose pools
  are made with the first breakable.
- `Physics_State` (storage with its own `copy`/`swap`/`free`) holds the `sim.World` and the
  entity → body and entity → joint links in two `core.Entity_Map`: dense, the size of what the
  simulation has and not of the entity indices. The link of another generation of an index is
  released before taking its place; without memory for the links, synchronization waits for the next
  tick (`physics.memory`). Copying it (rollback, Play) copies the simulation state block by block
  (`sim.world_state_copy`) with its hulls, meshes and heightfields. The copy that keeps a history
  (`state_copy_kept`, the storage's `copy_kept`) is a kept world (`sim.world_kept_init`): its pools
  have what the original uses with margin and its `desc` the capacities of the original, with which
  the world that is copied back is made; it never advances. What each geometry slot has is told by
  `Physics_State.geometry`: the generation and an XXH3 hash of its geometry, computed once per
  generation in each world and copied with it. A slot is copied when they differ, also if two worlds
  have equal generations with different geometry; otherwise it is not compared. Without memory the
  copy returns `false`; copying and swapping raise `epoch`, which invalidates the caches that depend
  on the simulation (destructibles, the editor's collider view). It is derived
  (`reset="state_reset"`): clearing the world (loading a scene or a save) discards the simulation,
  raises `epoch` and the next step rebuilds it from the rows. It is `shared`: destruction makes its
  pieces in it.
- Colliders made of the same thing (type, mesh or generated shape, scale and rounding, from the same
  file) share a geometry slot: the simulation counts the shapes that use it and frees it with the
  last. What each slot made is stored in `Physics_State.sources`, flat data copied with the
  simulation; a slot of another generation is no longer shared.
- `Collider_Meshes` (host) stores the collision geometry per mesh, built once per application. The
  retained CPU geometry of generated meshes admits `Mesh`; the cache removes its entries on freeing
  the asset, when the asset structure changes.

`physics_prepare` (`fixed`, before `physics_places` and `physics_step`) creates the simulation if it
does not exist, so that whatever asks something of its bodies in the tick already finds them, and
gives the [world queries](#queries). `physics_step` (`fixed`, `simulate` stage), in order:

1. Empties the events.
2. Reconciles the links with the rows (creates, rebuilds what changed, frees what lost its
   component). Only if one of these inputs changed:
   - the version of a table the bodies come from (`Rigid_Body`, `Collider`, `Character`,
     `Mesh_Renderer`, `Parent`, `Transform`);
   - the asset structure;
   - the world epoch (`Physics_State.synced`);
   - `Collision_Settings` (compared with the copy in `Physics_State.collision`).

   The poses that the step itself writes do not count as a change. If since the last reconciliation
   only `Transform` values changed, it walks only the bodies of the rows sealed since the end of the
   previous tick and what hangs from them in the `Hierarchy`, in the order in which the full
   reconciliation reaches them, which leaves all the others the same. It is full after a copy or a
   swap (`epoch`), with a cycle in the hierarchy, with a body or character that could not be made,
   or if something else that it reads from each body changed (`Time.playing`, the layout of
   `core.Motion` or `Character_State`, the bodies of the simulation, the assets revision).

   A tick creates or releases at most `BODIES_PER_TICK` bodies, compound shapes and characters,
   first what does not move: what a section brings or takes away in a settle arrives or leaves in
   the following ticks, and a dynamic body waits for the ground it would cross. It is a count and
   not a time, so that rollback resimulates the same. While something waits, the reconciliation
   repeats in the next tick; a request to a body that is still waiting is the
   `physics.request_body` problem.
3. Applies `Body_Requests` and `Joint_Requests`; creates, adjusts and removes joints. Before that,
   in both loops and only if their rows, volumes, poses or the epoch changed, it takes each `Fluid`
   to a simulation fluid in the `Volume` of its entity (`Physics_State.fluids`). One that cannot
   be made is the `physics.fluid` problem (no `Volume` or one that is not a plane or a box, a dry
   plane, a box without size) or `physics.fluids` (`Physics_Settings.fluids`); two fluids or two
   dry boxes that meet at the same priority, `physics.fluid_overlap`.
4. Hands the `Character_Move` to the characters.
5. **Advances the simulation** with `time.dt` (only if `Time.playing`, with the application's
   threads) and writes the poses into `Transform` and the states into `core.Motion` and
   `Character_State`: of the bodies the step moved or woke, of what the reconciliation, a request
   or a pose target addressed in the tick, of the proxies and of the characters. The rows of a
   body that sleeps already say so and are not looked at.
6. Forwards the events.

In the editor loop nothing is simulated: bodies follow the `World_Transform` of their entity.

Rejections and geometry:

- What the simulation rejects is a [problem](../../mirai-core/references/core.md#problems) of the
  entity, with the cause and the field of `Physics_Settings` that fixes it: `physics.bodies`,
  `shapes`, `geometry_budget`, `collider_mesh` (without `Mesh_Renderer`), `collider_geometry` (the
  mesh has no collision geometry), `collider_heightfield`, `collider_hull` and `world` (the
  simulation could not be created). A rejected shape frees the geometry created for it and is not
  retried until the collider changes.
- Removing or changing the collider releases its physical geometry, which goes away with the last
  shape that uses it; a snapshot has a copy of its own.
- Generated IDs are immutable: other asset changes do not rebuild their colliders. An already
  resident collider can continue and resimulate from its copy after the generated asset is freed; a
  new entity needs a live asset to build it.
- Changing a generated ID for another with exactly the same geometry keeps the shape and the
  contacts, including the warm start impulses.
  - It compares `Mesh` (vertices, triangles and flags) or `Heightfield` (heights, cell, segments,
    holes and origin) during that transaction, with equal collider, scale and relative pose.
  - It allows recreating derived assets after copying `Terrain_Data` without altering
    resimulation. The stable path does not compare geometry.
- `collider_ready(state,entity)` queries whether a valid shape exists.
- `geometry_budget(state,kind)` returns `(used,capacity)` for `Hull`, `Mesh` and `Heightfield` (zero
  for primitives or an uninitialized world).
  - Capacities are set before creating the world; changing them afterwards does not enlarge it.
  - Replacing the ID of the same collider first frees its previous geometry: it can reuse the slot
    with the budget full.
  - More colliders than slots leave shapes absent (`physics.geometry_budget`); whoever publishes
    terrain checks budget and readiness to communicate it.

## Gravity

Bodies fall with the `Gravity` of
[`engine/volume`](../../mirai-gameplay/references/libraries.md#volume), which defines the value per
zone; `gravity.odin` applies it to the simulation.

- The world gravity is that of the unbounded fields that pull downward: a field toward a center has
  no value far from a place and is left out. Whoever needs that of a place (a navigation or behavior
  jump) uses that of its entity.
- `physics_step` applies it after making the bodies of the tick, so a body born in a room without
  gravity does not fall in its first tick. Fields are combined again only when they change
  ([index](../../mirai-gameplay/references/libraries.md#volume)). Without bounded fields or fields
  toward a center all fall with the world's and no body asks; otherwise, each awake dynamic takes
  that of its center in the world's workers (`sim.world_set_body_gravity`), and when the fields
  change also the sleeping ones, which wake if theirs changed.
- `gravity` gives the world's; `gravity_of_entity`, the one the body of an entity feels. The
  character takes its length from it for its jumps, and its vertical turns toward the opposite
  ([vertical](character.md#the-vertical)). Particles fall with the same fields
  ([vfx](../../mirai-world/references/vfx.md#game)).
- Pushing is not gravity: a force in newtons that weighs the mass (a fan, an explosion) is a
  `Force_Field` or an area request ([requests](#requests)).

## Requests

`^phys.Body_Requests` is taken at the start of the next step:

- `move_kinematic` gives the body the velocity that takes it to the pose in one tick, and pushes
  what it touches. On a character `set_velocity` replaces its own velocity and `apply_impulse`
  adds impulse / mass.
- **Teleporting is only `core.place`**
  ([requested places](../../mirai-core/references/core.md#requested-places)), also for the game:
  `physics_places` takes the requests on an entity with `Rigid_Body`, `Character` or proxy and
  leaves the rest to `core.places_drop`. That way spawn, portals and cinematics place without
  caring about physics. It is a jump: the drawing does not interpolate the path (`core.jump`,
  [transform and hierarchy](../../mirai-core/references/core.md#transform-and-hierarchy)).
- A request that does nothing (non-finite values, without a body of its own, kinematic or
  manipulation of a character) is a `physics.request_*` problem of its entity.
- Forces: `apply_force` and `apply_torque` accumulate during one tick. The area one, `apply_area`,
  takes a `volume.Volume` and the pose it is placed at: a force, an impulse or a velocity change
  on every body whose center of mass is in it, away from its center (along the up of a plane) or
  along a direction of the world, weighted by `volume.weight` through the model's
  [area forces](physics.md#area-forces). It also affects characters (an impulse is a `launch`) and
  proxies. A volume without size or values that are not finite are the `physics.request_area`
  problem.
- `strain_area` strains the [breakables](destruction.md#damage-and-fields) its filter meets in a
  box or sphere `volume.Volume` placed at a pose, once the step of the tick ran, with or without
  breaking them (`weakening`); what it did is in `breakable_events` with the hits of the step.

Manipulation:

- `manipulation_target` moves a body temporarily as kinematic without modifying its `Rigid_Body`,
  also a collider without that component or a proxy. It chases the pose in fixed steps and transmits
  velocity to contacts: a large jump needs several ticks because of the solver's velocity limits.
  Afterwards it stays held at the pose reached.
- `manipulation_end` releases it on reaching the pending destination and restores authoring type
  and mass (or the previous type of the proxy); it sets the velocity to zero except with
  `preserve_velocity` (animation-to-simulation transition). With `dt=0`, placing and releasing are
  immediate and without contacts.
- Requests go to the owner that `manipulation_owner` gives (the ancestor of a compound collider;
  `NONE` for characters) and their poses are in its world frame: they do not move a child shape
  separately. Two proxies of the same body share a hold and the last request wins. The hold is
  copied with `Physics_State`.

`^phys.Joint_Requests` (configuration, drives, world rotation, axes, motor, `repair_joint`):

- `physics_step` is the writer of `Joint`: gameplay creates the component in a recipe and sends
  requests to change it during the simulation.
- The target pose of a drive is in the local frames of the joint ([joints](physics.md#joints)); the
  world variant receives the rotation of both bodies and uses the newly reconciled frames.
- The queue is applied in order and reconciles each change before the next (`Configure`,
  `World_Rotation` and `Disable` end up suspended), also in the first tick and after repairing.
- `joint_sixdof` starts with its six axes locked; activating drives frees them and keeps the
  `Limited` ones. A zero budget keeps the drives; `set_joint_drive_enabled(false)` suspends them.
- An invalid request does not mutate the configuration (`physics.joint_request`); without capacity,
  `physics.joints`. `Joint_State.error` says why a joint is missing and `broken` prevents
  recreating it until `repair_joint`. Repeating targets or budgets keeps the warm start.

## Locomotion

Locomotion (`locomotion.odin`, `locomotion_seat.odin`) walks, jumps, falls and flies a `Character`
through its `input.Move_Input` ([engine/input](../../mirai-gameplay/references/control.md)), which
the seat, the game, an AI or the network writes. The solver only sees the `Character_Move` that it
writes.

- `Character` is the only component of the character: what the solver reads, the mode, how a seat
  drives it and the `transient` state of locomotion (jump, coyote, layered movements). It is
  `replicated`: each end runs the same locomotion from the same state.
- `Move_Input` and `Character_Move` do not go in prefabs or scenes: `locomotion_step` adds them
  while the character plays. The network replicates the `Move_Input` if the body has it when its
  object is created, at the end of the tick: a character that a client drives appears before the
  `simulate` stage (as `spawn` does), not through a `react` or `end` command.
- `locomotion_step` (`fixed`, `simulate` stage: after whoever writes the `Move_Input`, before
  physics) takes the requests and writes every tick the `Character_Move` of each `Character` with
  `locomotion_move`, a pure function of the input, the state, the `Character_State` that the
  previous step left, the frame of its [vertical](character.md#the-vertical), the velocity of
  `core.Motion` and gravity. The look turns around the up of that frame; ground, jump and air are
  measured along it. It writes the two drives: the step chooses the ground or air one according to
  the support it finds, so leaving an edge already moves as in the air even if locomotion saw it
  supported.
  - Walking (with `Walk`): velocity over the ground plane relative to it, with acceleration or
    braking. Holding the `sprint` action (or always, with `Walk.sprint_default`, Fortnite's
    "Sprint by Default"; the action then only asks for a `Tactical_Sprint`) raises the top speed
    to `sprint_speed` while the move points within 60° of where it looks, and moving back loses
    `backward_slowdown` of it; both apply in the air as well.
  - Jumping: the edge of the `jump` action among the buttons of the `Move_Input`, supported or
    during the coyote time after leaving an edge, gives the `launch` that reaches `Walk.jump_height`
    and makes `MODE_FALLING` the mode. While the button stays down, for up to `Walk.jump_rise`, each
    tick tops the speed up back to the one it jumped with (as Unreal's `JumpMaxHoldTime`), until it
    is let go or something stops the rise; a ledge jump is not lengthened.
  - Tactical sprint (with `Tactical_Sprint`, `locomotion_moves.odin`): sprinting forward on the
    ground with `min_energy` starts it (`Character.sprint_active`, energy left by
    `tactical_energy`). Its top speed and jump speed grow exponentially to their multipliers over
    `speed_ramp` and `jump_ramp` (`tactical_boost`), which also the animation bridge reads; the
    acceleration multiplier acts only on the ground. Energy is spent per second (not in the air with
    `pause_falling`), per jump and per slide start, and comes back `recharge_delay` after it was
    last spent. It ends without energy, going down in the air past `fall_grace`
    (`Character.fall_time`: a jump still rising does not count), crouched, sliding or out of
    walking and falling, as soon as sprint is let go, or after `grace` with sprint held and the move
    off forward; back within `grace` it keeps its ramp.
    Without energy it sprints as `Walk` says.
  - Ledge jump (with `Ledge_Jump`): standing at `min_speed` for `min_time`, `locomotion_step`
    checks the ground ahead before the move (`ledge_drop_ahead`, own rule): a sphere almost as
    wide as the capsule meets nothing for `reach` along the velocity over the ground, and a ray
    down from there meets no ground within `min_drop` under the feet. Then `ledge_ready` is set,
    and a jump adds `added_speed` along that velocity (clamped to `max_speed` across the up) and
    `up_speed` over the jump's rise. `ledge_jumping` lasts until it stands again; meanwhile air
    control steers without slowing it below its speed. It costs no tactical energy.
  - Mantle (with `Mantle`): `ledge_find` looks for the top just past the face, so a top thinner
    than the capsule (a built wall) counts, and puts the feet a radius past the face or in the
    middle of a narrower top. An `Override` layered move takes the climb off its own way for its
    `time` (the root motion of the climb's clip: `animation_physics` warps it onto `mantle_to`
    through the warp window `mantle` of its `.character`); the tick it ends it stops and falls.
  - In the air: control bounded by `Walk.air_control`; it does not climb ground that is too steep.
  - Flying (`MODE_FLYING`, with `Fly`): velocity on the three axes according to yaw and pitch,
    `Airborne` and without gravity; it lasts until another mode is requested.
  - Swimming (`MODE_SWIMMING`, with `Swim`): walking or falling it enters where the water over the
    ground within reach (without ground, over the feet) exceeds `Swim.depth`, and leaves walking
    where it does not exceed it, the same measure in both directions; never in the middle of an
    `Override` movement. Without `Walk` it does not leave the mode: a fish out of water keeps
    swimming.
    - On the surface (head out and not going down) it moves horizontally with `Float`, which holds
      the head `surface_offset` above the water.
    - Underwater it goes on the three axes according to yaw and pitch, with `move.y`; still, it
      brakes horizontally and what buoyancy has over weight lifts or sinks it slowly. The current is
      added to its target like a belt.
    - `jump` on the surface climbs out: an `Override` layered movement takes the feet to the surface
      at the jump speed of `Walk`, which then raises them `jump_height`, and the mode becomes
      falling. An `Override` removes `Float`.
  - A mode without the component that parameterizes it, requested or the one it starts with, is the
    `locomotion.mode_component` problem: the character falls if it has `Walk` and otherwise stays
    still.
- The mode is a `Locomotion_Mode`, a type with names
  ([named ids](../../mirai-core/references/core.md#named-ids)): the engine declares
  `MODE_FALLING`, `MODE_WALKING`, `MODE_FLYING` and `MODE_SWIMMING`, and the game its own as
  constants of the type (`MODE_CLIMB :: physics.Locomotion_Mode(16)`). `Character.mode` is the mode
  it starts with, chosen in the inspector by name, and afterwards the mode it is in; it is changed
  with `set_mode` in `Locomotion_Requests`.
- An entity can use the modes whose components it has: `Walk` for walking and falling, `Fly` for
  flying, `Swim` for swimming, the component of a game mode (`Climb{speed}`) for its own. Each mode
  constant says its component with `@(name_requires="Walk")`, and the inspector offers only the
  modes whose component the entity has.
- Layered movements (`Layered_Move`): `add_move` and `remove_moves` enqueue in
  `Locomotion_Requests`; they last their `ticks`. `Additive` adds its velocity to that of the two
  drives (wind, belt) and its `force` to theirs, to follow a velocity that changes faster than
  traction (root motion); `Override` replaces it on the three axes, without gravity or ground
  (dash). The locomotion counts as its own only the velocity the additive ones did not put in the
  body (`additive_delivered`): one held back by a wall or by its force does not turn into the walk
  going the other way.
  The root motion of an action that moves its body arrives as one of them
  ([actions](../../mirai-animation/references/animation-actions.md#root-and-movement)).
  A request to an entity without `Character`, without ticks or with the array full is the
  `locomotion.request` problem.
- A game mode (climbing) is a step of its own that walks the entities with its component and, while
  they are in its mode, writes the `Character_Move` every tick before `locomotion_step`; this adds
  the layered movements to it (`layers_apply`, public) and does not compute the move. Entering and
  leaving the mode is requesting it with `set_mode`.

### Own pace

A `Character` with `core.Own_Pace` walks, jumps and swims in its own time, `pace_of` times that of
the world ([own pace](../../mirai-core/references/core.md#core-storages)).

- `locomotion_move_paced` takes to own time the velocity (by the pace of the previous move,
  `Character.pace`), that of the ground and that of the fluid, calls `locomotion_move` with
  `dt * pace` and returns the move in world time (`move_paced`): drives and `launch` by the pace,
  forces by its square and `Character_Move.pace`, with which the solver scales gravity, adhesion and
  push.
- When the pace changes, a `launch` keeps the own velocity it had (along the ground if supported):
  it neither brakes nor shoots off when slow motion starts.
- A layered movement lasts its `ticks` of own time. A game mode writes its `Character_Move` in its
  own time (with `dt * pace_of` and the velocity of `core.Motion` over `Character.pace`), and
  `locomotion_step` takes it to the world's.
- The seat turns toward the movement at `turn_speed` of own time; mouse look does not depend on
  time.

### Seat control

- The seat that drives a `Character` writes its `Move_Input` with `locomotion_seat` (`fixed`,
  `input`): the `move` and `look` actions (`Axis2`) give the movement and the look, and the buttons
  are the `Button` actions that the seat has pressed, by id; a button that the game declares
  (crouch) reaches a mode of its own this way without mapping code. It adds `ground_turn` to it.
- `move_relative_to` says what forward is:
  - `Look`: where it looks; the look turns `LOOK_SPEED` radians per unit of the action and the pitch
    stays within `pitch_limit` (first person, camera behind that follows the look).
  - `Camera`: where the camera of its `Drivable` looks, and the body turns toward the movement at
    `turn_speed` (orbiting camera).
  - `World`: the world -Z, turning the same (top-down view).
  - Both give the heading transverse to the character's up, in the frame of its vertical.

  - `Game`: the game writes the `Move_Input` (click to move, the animation gallery).
  - `View`: according to the camera through which its seat sees (`camera_selected`; without it, that
    of its `Drivable`): like `Look` while it looks with the body (`Eyes`, or an `Orbit` with `aim`),
    like `Camera` but looking where the camera looks if it has `facing` (aiming), and like `Camera`
    otherwise. For a body whose camera changes mode or that aims with another
    ([modes](../../mirai-gameplay/references/control.md#modes)).
- A player's sensitivity is the scale of their `look` bindings. `move`, `jump` and `sprint`
  belong to `physics` (`Walk_Action`) and `look` to `engine/input` (`Look_Action`)
  ([actions](../../mirai-gameplay/references/control.md#actions)).
- Without a seat, before `locomotion_step` takes its initial look or where another end decides
  (`core.Remote`), it does not touch it: what an AI or the network wrote stays. If `input.mirai`
  gives `move` or `look` another type, it is the `locomotion.seat_action` problem.
- A step that adjusts what it wrote runs with `after="locomotion_seat"`; a portal turns only the
  look of the traveler that drives its tip.

## Physics step outside the loop

`step_world(w, app, dt)` runs `physics_prepare` and `physics_step` on a `core.World_Ref` with
`core.world_run`: the same binding and settle of the generated world, without gameplay, network or
other phases. `dt` zero only reconciles bodies, shapes and requests. Whoever builds a temporary
preview decides which bodies it leaves dynamic and discards or confirms its results.

## Events (`Physics_Events`)

They are emptied and filled every step, with queues reserved when the world is prepared; they are
read in a function of the `react` stage ([order](../../mirai-core/references/generator.md#order)).
`a`, `b`, `entity` and `other` are the entities of the bodies; `collider_*`, those of the colliders
that touched, which distinguish head, foot or weapon of the same body. `NONE` is a body without an
entity; the detached ones of a destructible name their group entity, and the root group, the owner.

## Queries

On `core.Ref(Physics_State)`, with a `Query_Filter` and `ignore` (entity whose body is omitted). A
`Hit` carries body entity, `collider`, point, normal, distance, `overlap` (does not block the
query), body and shape. A query that starts inside a shape gives distance zero and null normal.
Without simulation (`!ready`) it returns nothing.

- `raycast(physics, origin, direction, max=1000, ignore, filter) -> (Hit, ok)`: the nearest impact
  that blocks. The direction does not need a particular length.
- `raycast_all(physics, origin, direction, hits, max, ignore, filter) -> int`: rules of the model's
  `ray_cast_all` ([queries](physics.md#queries)). It writes up to `QUERY_HIT_CAPACITY` (64), the
  nearest.
- `sweep(physics, shape, position, rotation, direction, max, ignore, filter) -> (Hit, ok)`: the
  first shape that blocks a `Sphere`, `Capsule`, `Cylinder` (both on the Y axis of the rotation) or
  `Box` that translates without turning (cameras, thick bullets, checking whether a character fits).
- `sweep_all(...)`: like `raycast_all` for the translating shape.
- `overlap_sphere`, `overlap_box`, `overlap_capsule`, `overlap_cylinder -> (count, complete)`:
  entities that touch the volume, each once. `complete` is false if more than `OVERLAP_CAPACITY`
  (256) shapes touch it or more entities than fit.
- `closest_point(physics, point, max, ignore, filter) -> (Closest, ok)`: the nearest point of what
  blocks, with entity, collider, normal toward the point and distance.
- `body_bounds(physics, entity) -> (box, ok)`: the box of the shapes of the body, without the copies
  of its twin. `collider_raycast(physics, entity, origin, direction, max) -> (Hit, ok)`: the ray
  against the collider of the entity alone, without its collision or its cuts: where its shape is.
- `fluid_at(physics, point) -> (Fluid_Sample, entity, ok)`: the physics surface query
  ([fluids](physics.md#fluids)) that rendering, interaction and navigation read: height and normal
  of the surface, current and density at the point, and the fluid's entity.
- `fluids_in(physics, box, out) -> int`: the fluids and dry boxes that touch a box, with their
  description in the world and their box, without allocating.
- `fluid_bodies(physics, out) -> int`: the awake bodies that the last step found in a fluid, with
  their submerged volume and that of the whole body, their center, their velocity, the height of the
  surface and its reach, without allocating. It is presentation (splashes, wakes): none of that
  returns to the simulation.

Static collision, to gather the level (a navmesh), without allocating:

- `static_triangles(physics, box, vertices, indices, filter, colliders) -> (vertices, indices,
  complete)`: the world triangles of the static collision that the box touches and `filter` blocks,
  by the rules of the model's `shapes_triangles` ([static collision](physics.md#static-collision)):
  without dynamics, kinematics, characters or sensors, and with the scale of each entity. With
  `Query_Filter{filter=collision_filter(...)}` of a character's collider it is what blocks it.
  `colliders`, if not empty, receives the entity of the `Collider` of each triangle and limits how
  many fit. Without simulation it returns zero and complete.
- `static_changes(physics, since, boxes) -> (next, count, overflow)`: the boxes where static
  collision changed since the cursor, with the rules of the model's log. `Static_Cursor` also
  carries the simulation epoch: if it was made again, copied or swapped (Play, a network
  correction, loading a save), the reader overflows and takes everything as changed. The zero
  cursor read nothing; without simulation it returns the same cursor.

Filters:

- `QUERY_FILTER_DEFAULT` hits every collider that collides with something, without sensors.
  `query_hits(layers,overlaps)` hits what belongs to those categories as a collider that collided
  with them would: a camera ray that passes through glass does not include its category.
  `Query_Filter{objects=layers}` also sees sensors and shapes that collide with nothing
  (explosions, damage zones); `Query_Filter{filter=collision_filter(...)}` queries as that collider.
- What looks at the world without knowing physics (a camera arm, the feet of
  [grounding](../../mirai-animation/references/animation-grounding.md)) uses the `core` contract
  `World_Queries`/`world_query`, which `physics_prepare` fills with `query_of`. Without the plugin
  nothing collides.
- `collider_debug_draw` draws the real shape of an entity, also inside the compound body of an
  ancestor ([model drawing](physics.md#debug-draw)); `collider_bounds` gives its world box, which
  the [editor preview](../../mirai-editor/references/panels.md#previews) uses when the full drawing
  does not fit.

## Owned bodies

A library that makes collision from its own data, as `foliage` does for the instances of its
cells, makes static bodies of its own in the simulation (`owned.odin`) instead of entities.

- It declares a `Body_Owner` and makes each body with `owned_body_create`, with the entity its
  hits name and its own index of the body, and each shape with `owned_shape_create` from a
  primitive `Collider`, a pose in the frame of the body and its own index of the shape. What is
  not made says why: no room in `Physics_Settings`, or no memory.
- It keeps the handles in a storage of the world, so a copy for Play or a rollback carries them
  with the simulation, and moves and ends them itself (`owned_body_place`, `owned_body_destroy`,
  `owned_shape_destroy`): physics never makes, moves or ends an owned body.
- `owned_body_of` and `owned_shape_user` say from the body and the shape of a `Hit` whose they are
  and which ones, without the owner searching its own lists.
- `body_info` reads any body of the simulation: of an entity, of a hit, owned or of a breakable.
- What breaks is made with `breakable_create` and read, damaged, cut and ended with the other
  `breakable_*` of `breakables.odin`, which are those of the [solver](destruction.md) on a
  `Physics_State`: its state is the simulation's, so the library keeps only its handle in a table.
  Its bodies name the entity it was made for until `breakable_body_name` gives them one.
- A bake or a test that simulates without a world makes the simulation with `state_make` and
  advances it with `simulate`, which applies only the requests of areas.
- A cache outside the world that keeps bodies asks `simulation_replaced` whether they are still
  of this simulation. `settings_capacities` gives the capacities a world is made with, for a
  library that shares them out, as `terrain` does with the colliders of its chunks.

## For networking and saves

Physics does not know the network: both share `core` tables.

- **`core.Motion`**, which only physics writes: velocities, center of mass, step group and whether
  it is awake, of each dynamic or kinematic body, character and proxy. The group
  (`sim.bodies_group`) is computed only where there is a `core.Pose_Target`, which is what reads it.
  A save restores it: a body or a character that is rebuilt takes its velocity from there.
- **`core.Pose_Target`**, the pose that another owner requests (the network): `physics_pose_targets`
  (`targets.odin`; `fixed`, at the start of the tick) takes it for the entities that physics moves,
  without knowing who requested it; a body made for a target takes its velocities and, if it
  follows, follows it from the first step.
  - A new `placed` puts the body in the pose, with those velocities (`rest` makes it sleep there); a
    character takes the rotation (its up and its yaw, `character_set_rotation`) and no angular
    velocity.
  - With `follow`, a body that is not a character goes toward its pose every step as kinematic, with
    the velocity that makes it arrive, so it pushes what it touches, until it stops following and
    recovers its type and velocity.
  - With `follow`, a character stays at its pose after every step, with the velocity of the target
    (`step_followed`), and does not walk by its `Character_Move`: neither its step nor what it
    touches moves it away from what the other owner shows. It does not push like a kinematic body:
    what it touches moves aside by itself.
  - Following and manipulation are two sources of the same hold (`Link.hold`): the first that takes
    the body makes it kinematic and stores its type, the last that releases it gives it back, and
    the target's pose goes before that of manipulation. While the target continues,
    `manipulation_target` stores the destination without moving the body and `manipulation_end`
    releases the manipulation without changing its type or velocity; when following ends, a
    manipulation that is still requested holds it.
  - A body that is not yet made receives the pose in its `Transform` and the velocities in
    `core.Motion`, from where it takes them when made. An entity with a parent is left to the
    parent.
- **`core.Simulation_Hash`**: with `core.Sync_Check.on`, the step leaves the simulation hash to
  compare two runs.
- **Proxy** (`proxies.odin`): `proxy_set/proxy_pose/proxy_written` make an entity represent a body
  that another library owns.
  - It accepts requests, places, manipulation, constraints and pose targets like a body of its own.
  - `proxy_remove` removes the link and its joints, restores a pending hold and never destroys the
    external body; its owner calls it before ending it.
  - Replacing the body of a proxy invalidates its joints so they are rebuilt against the new
    handle.
  - Joints follow the group entity during a split; they do not look for the piece that contains
    their anchor point.
- `local_of` converts a world pose to local under the parents.

Joints over the network:

- `Collider`, `Joint` and `Joint_State` are `@(component,replicated)`: they travel as configuration
  and logical state; solver handles and internal impulses are not transmitted.
- Physics rebuilds a joint when its configuration (`joint_frames_same`), its bodies, its scale or
  what it took from `Joint_State` (the captured frames and the length) change, whoever writes it;
  updating only motors or drives keeps the joint and its impulses.
- The frames of an entity with `core.Pose_Target` are those that the owner that places it (the
  server) took: when rebuilt, physics does not capture them again.

## Editor part

`plugins/physics/editor` gives the editor what belongs to physics through its
[providers](../../mirai-editor/references/extensions.md): the preset of a `Collider` and
`Collision_Settings` in the inspector, the `physics.collision.*` methods of the API, the `Collider`
that accompanies a new `Character`, the bodies that Simulate drags with the gizmo, the wireframes of
the selection's colliders, the `collision` and `collision.<category>` view modes, and the fluids of
the world that is seen (box edges and a grid over the sea), editing and in Play: nothing else shows
them while no plugin draws them. Without the plugin none of that appears.

- Category masks are shown by name like every named id; creating or renaming one writes code and
  builds the game.
- With a preset, `sensor`, `belongs` and `collides` show the preset's values and are editable: the
  first change turns the collider into `Custom` with the preset's values and that change, in one
  step (`collision_preset_customize`). Choosing `Custom` stores the preset's values without
  changing them.
- The settings list categories, presets, pushes and the entries of undeclared values, with a button
  that removes them.

## Changing these libraries

The [library invariants](../SKILL.md#library-invariants) apply. A contract change of
`Physics_State` or of the entity-body link updates `destruct` and `destruct_multiplayer` in the
same task; one of the queries, `core.World_Query`.

## Verification

- Gameplay: the `templates/game` template without a window, with frame limit and capture
  ([player arguments](../../mirai-core/references/host.md#the-player)), its destructible wall (`hit`
  by input script) and the `destruction` and `control` scenes of the demo. Look at the capture and
  the log; what was run goes in the task report.
- With networking, the
  [multiplayer integration](../../mirai-networking/references/multiplayer.md#verification). The
  per-file tests are in [the skill](../SKILL.md#verification).
