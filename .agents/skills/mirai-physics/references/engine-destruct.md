# Plugin `destruct`

It is imported as `destruct "plugins:destruct/runtime"` and depends on the `physics` plugin, of
which it knows the integration alone. It connects the
[breakable bodies of the solver](destruction.md) with entities, materials, requests and queries;
networking is the automatic bridge `destruct_multiplayer` ([network](#network)). Body physics is in
[physics](engine.md); integration verification is in [engine.md](engine.md#verification). Fields
and defaults: `components.odin` (`destructible()`).

An entity with `Mesh_Renderer` and `Destructible` uses a pre-authored
[.fracture source](../../mirai-assets/references/kinds.md#fracture) or generates Voronoi when the
simulation starts. A breakable is a body that can break: its pieces replace the entity's
`Collider`, of any kind, and its `Rigid_Body` says how it moves; neither is required.

- Without a `Collider` its pieces take the surface and collision of `COLLIDER_DEFAULT`; without a
  `Rigid_Body` it is dynamic. Of a kinematic or static `Rigid_Body` the body it is made as is
  kinematic, and every piece falls with its `gravity_scale`; the rest of the `Rigid_Body` is not
  read.
- Until the breakable is made, physics makes a body of the `Collider` and the `Rigid_Body` as for
  any entity; making the breakable ends it, and the entity becomes a proxy of its body.

- Each piece has a convex hull; the bonds and clusters determine which bodies detach. A whole
  cluster collides with the hull cooked in its source.
- The piece shapes live in the simulation from the moment it is prepared. On breaking, each group
  moves to a new body with the shapes of its pieces; fragments have no `Collider` of their own.
- All pieces take density, friction, restitution and collision from the entity's `Collider`.
- The game uses the public helpers, without manipulating the `sim.World`.
- A terrain is not a destructible: what is dug from it goes out through `terrain.Terrain_Digs`, and
  its pieces with physics are per-layer prefabs of `terrain_debris`
  ([what can be dug](../../mirai-world/references/terrain.md#what-digging-leaves)).

## Components

- `Destructible`: Voronoi (`pieces`, `seed`, `pattern`, `anchored`) or a `.fracture` source, and the
  parameters of [`Breakable_Desc`](destruction.md#construction) that are not those of a body.
- `Destructible_State`: what this library stores of the destructible.
- `Destructible_Group`: the entity of a detached body or of the root group, with the mesh generated
  for its pieces: the one place that says which entity a group is. Physics writes its `Transform`,
  as a proxy of the body.

## Configuration and setup

- `impact_damage` enables automatic contact damage ([damage](destruction.md#damage-and-fields));
  disabling it keeps colliders and explicit damage, strain and cut requests, without requiring an
  artificially high threshold. Passive clients disable it: the server decides breakage.
- Only what changed is looked at (`core.changes` of `Destructible`, `Rigid_Body`, `Collider` and
  `Mesh_Renderer`). A change of the `Destructible` or the `Rigid_Body`, of the surface of the
  `Collider`, or of the mesh, shape or scale the pieces were cut for rebuilds it intact; one of the
  collision of the `Collider` re-filters all pieces without rebuilding. The breakable is the
  reference: nothing keeps a copy of what it was made from.
- With `.fracture`, geometry, anchors and clusters come from the source (its hull points scale with
  the entity) and the `Mesh_Renderer` still gives materials and intact exterior mesh. A source with
  a `source_mesh` different from the `Mesh_Renderer` is rejected.
- Voronoi is computed as a transaction in a job, with a key of mesh, shape, pieces, seed, pattern,
  scale, interior slot and source; while it is pending, `waiting` is active.
- `destruct_step` runs `fixed` after `physics_step`, whose step already damaged the breakables
  with its hits (`physics.breakable_events`). A destructible is a breakable of `Physics_State`, with
  the capacities of `Physics_Settings` (`breakables`, `pieces`, `bonds`): what it became is copied,
  swapped and reset with the simulation. The step creates the breakables and the
  proxies of their pieces in the simulation, writes `Mesh_Renderer` and `Tint` of the group entities
  and gives them `Parent` with `core.Commands`. It publishes each new group that is not debris, with
  its Id, in `Destruct_Events.grouped`.
- A failure is a `destruct.*` problem of the destructible
  ([problems](../../mirai-core/references/core.md#problems)), with the cause and the fix, and it is
  not retried until what it is made of changes. What the simulation did not give it in a tick is
  also one, with the field to raise:
  - `destruct.events`: break events that did not fit in those of a step
    (`Physics_Settings.events`): they were applied, and not told to the game or sent to clients.
  - `destruct.capacity`: a breakage or a cut without room in `Physics_Settings`. A destructible
    keeps the cut, expired or removed pieces until it is destroyed
    ([limit](destruction.md#known-limits)).
- A copy of `Physics_State` keeps strain, cluster levels and removal policies with the bodies and
  their geometry.
- `Destruct_Cache` is derived (`host,by_world`, not copied): on changing epoch it rebuilds geometry,
  cuts and meshes without modifying the simulation, reusing the group entities of the restored
  world. `destruct_release` releases it when its world is freed. A scene removal also ends the
  breakable whose state component has already disappeared.

## Requests and movement

`Destruct_Requests` receives `damage`, `strain` (breaks without impulse), `weaken` (accumulates
without breaking), `slice` (deactivates the cluster hierarchy and continues on the piece graph)
and `remove`. Strain that lasts in a region is a `Strain_Field` on an entity with a `Volume`
([damage](destruction.md#damage-and-fields)): it goes through `physics.strain_area`, and what it
breaks comes back as events of the step like the impacts.

- `remove` asks to remove a detached group and returns `Remove_Error` (group zero is retained). It
  removes body, proxy, entity and mesh with the same `Remove` event as the automatic policies. A
  server replicates non-cosmetic removal; a client only removes its local debris.
- A request prior to the creation of the body waits while a valid configuration exists or its setup
  is still pending, and is applied once when it becomes ready; it is not consumed while the
  simulation is stopped, and the entity's removal or a failure discards it. Damage can be requested
  in the same tick in which the destructible is created.
- A request on the root reaches its non-cosmetic bodies; on a `Destructible_Group`, only its body;
  on what is not part of a destructible, nothing. That way the game requests `damage` on the entity
  it hit without finding out what it is. The operation generates one event per body so that the
  network can express it in its local frame.
- The passive client discards requests and contact damage, except `Remove` of its debris.

Proxies and movement:

- Root and groups are registered as proxies also offline: they accept `Body_Requests`, manipulation
  and `Joint` like other bodies. `body_of(root)` gives the retained body and `body_of(fragment)`
  that of the fragment; `raycast`, overlaps and contacts name the fragment hit, or the root if it
  is the retained one. `owner(view,e)` gives the destructible of which `e` is a part, or `NONE`.
- A joint follows the proxy entity and its retained group; it does not look for the piece that
  contains its anchor.
- A kinematic destructible moves as any kinematic body, with `physics.move_kinematic` on its entity:
  the anchors stay in that body and the released pieces are dynamic.
- The game does not write the `Transform` of a destructible or of its groups: physics writes them.

## Reflection, queries and events

- A different physical revision redoes the reflection from the pieces of the breakable. Intact, the
  original mesh is drawn; broken, `Drawn_Elsewhere` is added and a mesh generated per body with the
  material slots of its pieces. Group zero hangs from the root with inverse scale; detached ones are
  world roots. Each removal drops the proxy before destroying its entity and frees its mesh.
- Queries (`pieces`, `clusters`, `groups`) receive `destruct.Destruct_View`, a
  [parameter group](../../mirai-core/references/generator.md#parameter-groups) with the physics
  state and the tables of states and groups; they return the total and write up to the capacity
  given (an empty `out` measures).
- `Group_Info.remaining_ticks` reads the physical removal date
  ([removal](destruction.md#removal)); a reached date stays so on a passive client until `Remove`
  arrives.
- Physics decides when a fragment ceases to exist; its fade belongs to the game or to a
  presentation plugin (`render.Tint.color.a`). For a fade before a removal by time, the game reads
  `remaining_ticks` without duplicating age or timer; for a life that gameplay decides,
  `removal_lifetime=0`, `remove_on_sleep=false` and `remove` at the end. Group zero never takes
  part.
- `piece_geometry` copies, in a transaction, the visual geometry of a piece in the frame of the body
  (world vertex = `group.position + rotate(group.rotation,vertex)`, without adding
  `Piece_Info.center`). It feeds the
  [portable cache](../../mirai-plugins/references/physics-cache.md); it does not export a solver
  snapshot.
- `Destruct_Events.fractured` publishes, after `destruct_step`, the strongest operation that
  detached pieces. A rollback publishes it again: a reaction that leaves the `World` (a sound) goes
  through a sink that respects `core.Time.resimulating`.
- `Destruct_Events.applied` lists each fracture applied in the tick with its entity: it is what a
  game that counts hits reads, without crossing `Destructible` with `Destructible_Group`.

## Network

`destruct` does not know the network: it reads the role of `core.Network` (a client is passive),
publishes in `Destruct_Events.applied` each fracture it applied and accepts repeating fractures and
states received through its requests. The `destruct_multiplayer` bridge (`fracture.odin`), active
with `destruct`, `multiplayer` and `physics`, carries them from one end to the other; the
[multiplayer contract](../../mirai-networking/references/multiplayer.md) defines authority and body
rollback.

- The server decides damage and removal. The root needs a stable `core.Id` and both ends the same
  fracture source: a destructible without Id cannot pair its events.
- Fractures are an
  [operation journal](../../mirai-networking/references/multiplayer.md#operation-journal) keyed by
  the root's `Id`: each event of `Destruct_Events.applied` is an operation in the local frame of its
  body, the last of a root in a tick with its `physics.breakable_check`, and its one part is the
  state without geometry (`physics.breakable_state_write`; empty: as created), a base. Every late
  fracture asks to go back to its tick.
- Non-cosmetic groups receive the `Id` from `core.id_new` from a state derived from the root's Id
  and `group`, the same at each end. If the root has `Replicate`, the bridge gives each group of
  `Destruct_Events.grouped` its `Replicate` and the server publishes it as an authoritative body
  with inherited audience and priority; the client asks to adopt it with
  `multiplayer.adopt(&adoptions, id, e)` and the network binds it to its replica at the end of the
  tick. Debris is local.
- A destructible without Id cannot pair its events between ends.
- The journal lives in `Destruct_Net`, one per world like the session.
- The server offers the state of what is broken to each connection that enters its world
  (`Entered`: on arrival and after each scene change, a loaded save between them).
- Clients keep `removal_lifetime` to query their dates, internally disable their non-cosmetic
  automatic removal and follow the server's `Remove`.
- `destruct_net_receive` hands what arrived to the journal; `destruct_net_follow` (on the client)
  replays what the journal hands; `destruct_net_send` (after `destruct_step`) publishes what was
  applied and serves the states.
- Tests (`plugins/destruct_multiplayer/runtime`):
  `a_correction_that_goes_back_before_a_fracture_applies_it_where_it_was_first_applied`,
  `a_fracture_of_a_tick_the_client_simulated_asks_to_go_back_and_is_applied_at_its_tick`,
  `a_connection_that_enters_the_world_gets_the_state_of_what_is_broken` and
  `a_scene_that_replaces_the_world_forgets_its_logs_and_the_server_sends_what_is_broken`.
- Topology, levels and remaining life travel in the state; poses and velocities, as bodies. The
  `.physics_cache` format is independent of this replication.
- Tests: `plugins/destruct_multiplayer/runtime/fracture_test.odin`.
