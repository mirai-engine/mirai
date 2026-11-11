# std/ai

Package `ai` (`import "mirai:std/ai"`). It depends on `core`, `std/base` and `std/math`. Each file
documents its types and procedures; this holds the contracts that cannot be seen from a single
function.

- The algorithms operate on contexts with capacities fixed at creation (`*_init`) and do not
  allocate afterwards; what does not fit is returned as a state (`Open_Full`, `Output_Full`) or
  counted (`failed`).
- The state of each agent (`Mind`, `Perception_Memory`) is plain, without pointers: it is copied for
  a snapshot.
- A `Nav_Mesh` changes by whole tiles and links, and a `Nav_Volume` by whole zones, in transactions
  of the caller.
- **One way for each thing.** One A* under every space, the navmesh and the volume to find a way,
  the corridor to follow it, ORCA to step aside, the mind to decide, the places to choose where.
  There is no grid search, flow field, steering force or second selector beside them.

## A* search (`search.odin`)

- `Open_Set` is an indexed binary heap of fixed capacity: a node is in it only once and improving
  its cost moves it (`open_push` inserts or lowers the key; `open_pop`, `open_clear`). The capacity
  needed is that of nodes open at the same time, not that of relaxations.
- Nodes are named with `u64` keys. `Search` is the memory of the searches:
  `search_init(&s, {nodes, keyed, open, max_edges, allocator})` (`open` defaults to `nodes`).
  - Dense: the key is the place of the node, less than `nodes` (the portals of a coarse graph).
  - By key (`keyed`): the first `nodes` keys that a search reaches take a place through a hash
    table, so they may be sparse (polygons of a tiled navmesh, planning states). Running out of
    places is `Open_Full`.
  - More than `max(u32)/4` nodes or an open set of more than `max(i32)` make `search_init` fail.
  - It is reused for any space that fits and is not safe across threads. A generation counter
    avoids clearing between searches.
- `search_begin` and `search_step(…, accept, budget)` are the only A* loop; `search_run` runs it
  whole. `neighbors`, `heuristic` and `accept` are constant procedures that are specialized per
  space without indirect calls per node.
  - `accept` hears each step that becomes the best path to a node, with its place and its edge
    (`Edge.data` identifies it), right before its heuristic is requested: this way a space stores
    per place what it needs (where a path enters a polygon, the state of a plan).
  - The heuristic must be consistent for the result to be optimal (zero turns it into Dijkstra).
  - `Search_Status`: `Found`, `No_Path`, `Open_Full`, `Output_Full`, `Invalid` (key out of range or
    `Search` smaller than the space) and `Running` (the budget ran out: continue with
    `search_step`).
  - `search_path` copies the path of the last success and `search_path_to` the path to any reached
    node (the closest to an unreachable goal, for a partial path); `search_cost` gives the cost and
    `search.stats` counts searches, expanded nodes and the peak of the open set.
- `edge_add` writes an edge to the list of a node; those that do not fit are counted in `dropped`.

## Navigation

A single navmesh, tiled; it is built by the [tile building](#tile-building-nav_buildodin) or by
`nav_tile_from_triangles` (one polygon per given triangle, without a tree). Y is up; polygons go
counterclockwise seen from above, and the queries do not depend on the winding.

### Tiled mesh (`nav_mesh.odin`)

- `Nav_Mesh` (`nav_mesh_init` with origin, tile width, step and capacities of tiles, links and
  connections) stores tiles in a grid over XZ and links. Adding, replacing or removing a tile or a
  link does not allocate: the capacities are reserved at creation and what does not fit is counted
  in `failed`.
- `Nav_Ref` names a polygon or a link by its place and its generation: a replaced tile or a removed
  link expires its references (`nav_ref_valid`, `nav_poly_of`, `nav_link_of`) instead of naming
  something else. A link has a direction: `nav_ref_flip` is the same one crossed the other way.
- `nav_mesh_add_tile` takes the data (it releases it when replaced or removed), joins its edges with
  the neighboring tiles where the edges overlap within the step and rests the links whose ends fall
  in it. `nav_mesh_copy` copies everything, with the same references.
- A link (`nav_mesh_add_link`) joins two points of the surface: type, direction, area whose cost it
  pays per meter, extra cost, what it requires (`Nav_Need`: climb, width, drop, abilities) and owner
  (`nav_mesh_remove_links_of`). Its ends rest on the nearest polygon within its radius as soon as it
  exists and are released when the tile leaves. A one-way link is known at its end too, as an
  arrival that leads nowhere: a search toward a point walks the links against their way.
- `nav_box_polys` walks the polygons whose boxes touch a box, through the tree of each tile.

### Queries (`nav_query.odin`)

- `Nav_Filter`: cost per meter of each area (0 counts as 1), excluded areas and what the agent can
  do (`can`); a link that requires more is not taken. A zeroed filter crosses no links.
- `Nav_Query` is the memory of the path searches: a `Search` by key whose capacity bounds the
  polygons that a search reaches.
- `nav_path_begin`, `nav_path_step(budget)` and `nav_path_finish` search in slices; `nav_find_path`,
  all at once. A* enters each polygon through the point of its portal closest to the straight line
  toward the end; the cost is that walk times the cost of the area. Without a path, the path to the
  reached polygon closest to the end (`partial`). The mesh may change between slices: what expires
  leads nowhere and the finished path is validated.
- `nav_costs` measures from one start toward many ends with a single search without heuristic, until
  the requested polygons are closed; `nav_cost_to` walks the steps it took to one and counts the
  cost as A* toward that end. The polygons may not be those A* chooses: close to its cost, never
  below the straight line.
- **One search for all who go to the same end.** `nav_toward_begin` starts the same search from the
  end, against the way agents walk: across the same polygons at the same cost, and along each link
  that arrives. `nav_toward_reach(ref, budget)` expands it, in slices, as far as the polygon of one
  of them and `nav_toward_path` reads its way from there in the order it is walked: the search
  costs what the farthest asks, and each one after it only its path.
- `nav_straight_path` pulls the path taut with the funnel and cuts at each link: corners with
  `Start`, `End` and `Link` (the start of a link, with its reference). Past a node no longer
  valid it ends on the last valid polygon, without `End`.
- `nav_path_straighten` removes, in one pass, each bend of the pulled path that a raycast skips at
  no more cost than the bend: the ray's polygons replace the bend's. A ray never crosses an area
  dearer than the stretch it replaces, so a path does not cut through what A* went around; the
  path is pulled again and stays as it was if that costs more.
- `nav_find_nearest`, `nav_poly_height` (through the detail mesh), `nav_closest_point_on_poly`,
  `nav_move_along_surface` (moving without crossing walls or links), `nav_raycast` (over the surface
  seen from above), `nav_random_point`, `nav_random_point_around` and `nav_distance_to_wall`.
- `Nav_Boundary` holds the edges of the mesh around an agent that lead to nothing the filter
  walks, nearest first and with the surface to their right: the walls of
  [avoidance](#avoidance-between-agents-avoidanceodin). `nav_boundary_update` gathers them within
  twice the reach asked and keeps them while they cover it: until the agent went on past them or a
  tile they come from was built again (Detour's local boundary), so a walker does not walk the
  polygons around it every tick.

### Corridor (`nav_corridor.odin`)

- `Nav_Corridor` is the path an agent follows, flat and of fixed capacity: what exceeds it, at
  `nav_corridor_set` or when `nav_corridor_move` adds to its front, is cut (`cut`) and the
  target stays on the last polygon, to plan again before it.
- `nav_corridor_set` takes a planned path and straightens it once (`nav_path_straighten`); the
  corridor is not straightened again while it is followed.
- Each tick: `nav_corridor_move` takes the start to where the agent is (what it walked off the path
  is added ahead) and `nav_corridor_corners` gives the next corners up to the first link.
  `nav_corridor_move_target` slides the end after a target that moves, over the surface from the
  last polygon (Detour's moving target): no search while nothing walls it off.
- `nav_corridor_cross` crosses the link at the front and leaves the agent at its end;
  `nav_corridor_valid` says whether the first steps still exist and the filter walks them.

### Jump and drop links (`nav_links.odin`)

- `nav_jump_links` samples the walls of a tile and searches outward for the highest surface within
  what the class jumps (height and width) and falls: near and lower than a step is `Drop`, the rest
  `Jump`. A second pass jumps over the floor that the probes find first and searches for a `Jump` to
  another surface: from roof to roof over the street of a gap, where the first pass gives only the
  drop to the street. The samples of a wall whose arrivals follow each other are one link, from the
  middle one. `clear`, from the caller, accepts the arc or not.
- `nav_jump_point` is the ballistic arc of a link: its top is `NAV_JUMP_CLEARANCE` above the highest
  end for a jump and at the exit for a drop, the same with any gravity. Whoever checks the arc and
  whoever crosses it use the same one.

### Volume (`nav_volume*.odin`)

For what flies or swims: the free space of a medium, in zones of a 3D grid.

- `Nav_Volume` (`nav_volume_init` with origin, voxel, layers and zone capacity) stores zones
  (`Nav_Volume_Data`), cubes of `NAV_VOLUME_BLOCK`·2^layers voxels per side. Each is a sparse
  octree: the root is the zone and a node splits into eight only where free and blocked voxels mix,
  down to blocks of 4×4×4 that are the bits of a `u64`. Open space is one large node. Adding,
  replacing or removing a zone does not allocate; `nav_volume_copy` copies everything.
- A `Nav_Ref` with `NAV_REF_VOLUME` names a free node (with its layer) or a free voxel, with the
  generation of its zone: rebuilding it expires its references, like a tile.
- The points are the center of the agent: `nav_volume_build` leaves free a voxel whose center falls
  in some box of the medium (`spaces`) and whose box, enlarged by `half` (half the agent size on
  each axis), touches no triangle. The result does not depend on the order of the triangles;
  with nothing free it is `Empty`.
- `nav_volume_find`, `nav_volume_find_nearest`, `nav_volume_raycast` (whether a segment crosses
  only free cells; it skips whole large nodes), `nav_volume_random_point_around` and
  `nav_volume_portal` (the center of the face between two cells).
- `nav_volume_path_begin`, `nav_volume_path_step` and `nav_volume_path_finish` search with the same
  keyed A* as the navmesh: from a cell to those of its faces, which are the neighbor of its size,
  the larger one that contains it or the free cells of a split neighbor that touch the face. It is
  entered through the point of the face toward the end; without a path, `partial` as in the
  navmesh.
- An agent follows a `Nav_Corridor` of cells (`nav_volume_corridor_set`): each tick
  `nav_volume_corridor_steer` gives the farthest of its next portals, or the target, that it sees in
  a straight line, and releases the passed cells; if it sees none, it plans again.
  `nav_volume_straight_path` pulls a whole path taut, to draw it or return it.

### Links between the mesh and a volume (`nav_space_link.odin`)

For what walks and swims, or walks and flies: a path over the mesh of one class and the volume of
another.

- A `Nav_Space_Link` joins a point of the surface with one of the free space, in one direction or in
  both, with a cost and a type of the caller. `nav_shore_links` gathers those of the shores within a
  box: where a polygon of another area borders one of the water area, one every `spacing` meters,
  from a little inside the dry polygon to a little beyond the edge, raised.
- `Nav_Medium_Query` is the memory of a `Nav_Volume_Query` (its search, its points and its
  candidates) with the mesh, its filter and the links that fit in `NAV_QUERY_SPACE_LINKS`. At the
  start (`nav_medium_path_begin`) each link rests its ends on a polygon and on a cell; those that do
  not rest both do not enter. Start and goal may be in either.
- A single A*: a polygon or a link of the mesh is expanded as in `Nav_Query` (`nav_mesh_edges`, the
  same procedure) and a cell as in the volume; additionally, a polygon leads to the cell of each
  link that leaves from it, and a cell to the polygon of the two-way ones. The heuristic weighs like
  that of each space. `nav_medium_path_finish` gives polygons, links and cells, or the partial path
  like the others.
- `nav_medium_first_part` cuts the path where it changes space and gives the link that crosses
  there, in the order in which it is crossed.

### Coarse graph (`nav_coarse.odin`)

How the regions of a mesh or of a volume (the sections of a world) are joined, to move what is
where the mesh or the volume is not loaded.

- `Nav_Coarse` stores per region (a key of the caller; 0 is outside every region) its portals and,
  between each two of them, the length of the path over the surface with up to
  `NAV_COARSE_CORNERS` corners. What belongs to each region is one block of each array, in the order
  of the regions: removing one shifts the following ones.
- `nav_coarse_build_region` rebuilds a region from the mesh: the crossings of the edge of its box (a
  polygon with its center inside and its neighbor, or the end of a link, outside), walked by tile
  coordinate, sorted and merged into a portal when they go to the same outside region
  (`region_of`) at less than `NAV_PORTAL_MERGE`; then the path with the query between each two,
  once per pair. It is a transaction that allocates; it returns whether something did not fit.
- `nav_coarse_build_region_volume` does the same from a `Nav_Volume`: a crossing is the middle of
  where a free cell touches a face of the box and the free space continues on the other side; they
  are merged at less than half the size of the box (a free face is crossed from any side), and the
  path between two portals is that of the volume, pulled taut.
- `Nav_Coarse_Build` builds a region in steps to spread it across ticks: `nav_coarse_begin_region`
  gathers the crossings of the mesh at the start; `nav_coarse_begin_region_volume` walks the edge of
  the volume one zone per step. Then each step searches paths between pairs of portals up to a
  budget of expanded nodes. The previous region stays in the graph until the last step, which puts
  the new one in its place; the build stores no pointers and each step receives the mesh or the
  volume. `nav_coarse_build_region` and `nav_coarse_build_region_volume` do all the steps at once.
- When a region is rebuilt, the portals it had toward the `kept` regions (the far ones, whose mesh
  is not there to show them again) are kept if no new one faces that region near them, in the place
  where they were.
- A portal toward a region the graph knows takes as its twin the one of that region that faces it,
  the closest. An unknown region (the outside one) is crossed in a straight line between the
  portals that face it.
- `nav_coarse_route` searches with the dense A* of `search` (one node per portal and two more, the
  heuristic is the distance) and returns the points to walk after the start, with the corners of
  the paths of the known regions, ending at the goal. `Output_Full` with what fits.
- `nav_coarse_copy`, `nav_coarse_remove` and `nav_coarse_merge` (adds the regions it does not have,
  as when reading a bake). A graph whose blocks or indices do not close (a damaged file) is not
  walked: `Invalid`.

## Tile building (`nav_build*.odin`)

`nav_build_tile(config, coord, input, &scratch, &out, allocator)` builds a navmesh tile
(`Nav_Tile_Data`, contract in `nav_tile.odin`) from triangles in world space, with any orientation.
It is a rewrite in Odin of Recast and of the tile closing of Detour
([license](../../../../THIRD_PARTY_NOTICES.md#adapted-code)).

- **What it receives.** The triangles that touch `nav_tile_rect(config, coord)` (the XZ square of
  the tile, with y open) enlarged by `nav_build_margin(config)`: the agent radius and three cells.
  The border is voxelized like the tile and stays out of the result, so two neighboring tiles see
  the same voxels along the side they share.
- **Memory.** `Nav_Build_Scratch` is the memory of a builder, one per thread
  (`nav_build_scratch_init`, `nav_build_scratch_destroy`). Building is a transaction that may make
  it grow; rebuilding tiles of the same size does not allocate in it again. The result is a single
  block allocated with `allocator`, with `poly_links` at zero and `hash` for the caller; `out` is
  overwritten without releasing what it had.
- **Statuses.** `Empty`: nothing walkable in the tile. `Invalid`: non-positive or non-finite sizes,
  slope outside [0, π/2), negative region areas, a tile that with its borders exceeds
  `NAV_BUILD_MAX_CELLS` or is outside the `i32` range, indices out of range or not a multiple of
  three, `triangle_areas` of another length, areas or volumes of more than `NAV_AREA_MAX` or eight
  points, and an uninitialized scratch. `Too_Large`: more vertices, polygons or regions than 16-bit
  indices. `Out_Of_Memory`: an allocation failed; the scratch stays usable.
- **Degenerate input.** A triangle with a non-finite coordinate is skipped. A volume with fewer than
  three points or with a non-finite value marks nothing. The heights of a tile count in 16-bit cells
  from the lowest geometry that touches it: what is higher is clipped.
- **Units.** The radius is rounded up to cells, the height too and the step down; `max_edge_error`
  is converted to cells. Heights use a global grid from y = 0 (`origin.y` does not count) and the XZ
  positions are `origin + global cell × cell_size`, computed the same in all tiles.
- **Walkable.** A triangle not steeper than `agent_max_slope`, with `triangle_areas` (if any)
  nonzero; one that is not blocks. Steps greater than `agent_climb`, ceilings lower than
  `agent_height`, edges with a drop greater than a step and voxels whose reachable neighbors differ
  by more than a step (narrow-tread stairs) are removed; then it is eroded by the radius from walls,
  edges and what is blocked.
- **Volumes.** They are marked before erosion: a `NAV_AREA_BLOCKED` volume is an obstacle and the
  radius moves away from it. They mark the voxels whose floor is between `min_y` and `max_y` and
  whose column has its center inside; the last one wins.
- **Regions.** A watershed over the distance to the walls. Islands smaller than `min_region_area`
  are discarded unless they touch the tile edge (their size is not known from a single one); regions
  smaller than `merge_region_area` are merged into a neighbor.
- **Polygons.** Convex, of 3 to `NAV_VERTS_PER_POLY` vertices, counterclockwise seen from above:
  the right-hand normal points to +Y. A side on the tile edge is a portal toward that side even if
  the neighbor has no surface there: the mesh joins them by overlap. Where both tiles have surface,
  their portals have the same vertices, except when a vertex between two regions on the edge cannot
  be removed (rare).
- **Heights.** Those of the top of the voxels: up to one `cell_height` above a flat floor and more
  on slopes. The detail mesh departs at most `detail_max_error` from those voxels (not from the
  triangles). It samples every `detail_sample_distance`, at least one cell; in a large polygon the
  step grows so as not to exceed a maximum of samples per axis, and the detail vertices of a polygon
  have a cap. Its triangles go in the same direction as the polygons.
- **Again from its field.** A build asked for a `Nav_Tile_Field` keeps in it the walkable spans its
  triangles gave, before the volumes mark them. `nav_build_tile_again` builds the tile from that
  field with other volumes, without triangles: byte for byte the tile the triangles give with those
  volumes. A field of another grid, or whose spans do not stand one over the other, is `Invalid`.
- **Determinism.** The same configuration and input give the same bytes in the block: ties are
  broken by index and nothing depends on the order of a hash table. Another platform may round
  differently.

## Avoidance between agents (`avoidance.odin`)

- `avoid_velocity(self, preferred, max_speed, neighbors, horizon, dt, walls, wall_horizon)`
  applies ORCA, with `neighbors []Avoid_Agent(N)`: a single code for N=2 (disks on the plane) and
  N=3 (spheres in a volume). Each neighbor forbids a half-space of velocities that would bring the
  two together before `horizon` seconds, and each agent takes half of the change; toward one that
  `ignores` it (it does not step aside: a player, a moving body), all of it, at its real velocity.
- **Walls come first.** On the plane, each `Avoid_Wall` (a segment, walked on the side to its
  right) forbids the velocities that cross it before `wall_horizon` seconds, as the edges of the
  obstacles of RVO2 do. An agent on a wall may not move into it; at the corner of two walls that
  turns away from it, only the one the preferred velocity breaks least holds, as either side is
  walked. A wall the agent is behind is none of its own.
- It returns the allowed velocity closest to the preferred one (an incremental linear program that
  drops a dimension over the edge of the violated constraint), without exceeding `max_speed`. If
  none remains, the one that violates the neighbors least: the walls stay as they are.
- Agents that already overlap are separated in one step `dt`.
- Only the `AVOID_MAX_NEIGHBORS` nearest neighbors and the first `AVOID_MAX_WALLS` walls count.
- Whoever moves the agent moves it at the velocity returned, speed included: a faster body is not
  where the others, and the walls, were told it would be.

## Decisions: minds (`mind.odin`)

A single way of deciding: on each tick the game's `think` proposes the actions it can do now, each
with a score, and the highest wins; each action is a procedure with `Enter`, `Update` and `Exit`.
There is no node graph to build or other framework: no state machines, no behavior trees, no HTN,
no GOAP. What those models gave is written this way, without implementing them on top:
[instead of FSM, trees, HTN and GOAP](#instead-of-fsm-trees-htn-and-goap).

### The mind and the tick

- `Mind` is the plain state of an agent, with the same layout for any enum of actions (values from 0
  to less than `MIRAI_MIND_ACTIONS`): it is copied with the world for a snapshot or a rollback, and
  `behavior` stores it in `Mind_Agent`, inspects it and presents it without knowing the enum.
- `mind_tick(&mind, &ACTS, think, &ctx)`: `ACTS` is an `[Enum]proc(^Act(Enum)) -> Status`, one per
  value. An enum with negative values or outside the capacity does not compile; an action without a
  procedure fails on entry (the world generator rejects it earlier, when it builds a mind).
- `think` calls `propose(t, action, score)`; a score of 0 or less, or one that is not finite, does
  not propose. The highest wins and, in a tie, the first proposed.
- The running action is worth its proposal plus `keep`, or its `commit` if greater: what scores only
  slightly more does not interrupt it and two scores that cross do not oscillate. What scores more
  interrupts it in the same tick (`Aborted`); one that nobody proposes and has no commit does too.
- `commit(a, score)` makes the action worth at least that until it exits: an attack that finishes, a
  trip to an object, a jump. What must interrupt it proposes more (stun, die).
- An action that ends asks for `think` again in the same tick, over what changed, and the best one
  enters; it may be itself again, unless it failed.
- `Mind_Context` is what the caller gives: `user` (the context of the mind), `tick`, `dt`, `keep`,
  `holder` (the agent, owner of its reservations), `reservations` and `lease`.
  `behavior.minds_tick` fills all of it.
- Deterministic within a configuration, without allocating: copying the minds and the world
  halfway gives the same future.

### Actions

- Each `Enter` has exactly one `Exit` with its cause (`Success`, `Failure`, `Aborted`): there the
  action releases what it requested (stopping navigation, stopping looking). The reservation of the
  frame is released by the mind.
- `a.memory` is `MIRAI_MIND_WORDS` words zeroed on entry. The stages order the work in code:
  `stage`, `next_stage`, `elapsed`, `stage_elapsed`, `after`.
- `steps(a, x, y, z)` runs other actions of the same mind as steps, one after the other, the next
  in the same tick in which the previous one ends: `Success` when the last ends, `Failure` on the
  first that fails. A step has no steps; the list is the same on each tick.
- `mind_since` and `mind_ready` give the seconds since an action exited: cooldowns. A mind counts
  in ticks (`Mind_Context.tick` and `dt`): `after` and `mind_ready` last the same at any tick
  rate.

### Reservations: attack tokens and objects

- `Reservations` counts who holds each key (a target and which of its reservations: 0 is an attack
  token, an offer of a smart object another). `token_take(a, target, limit)` and
  `claim(a, target, which, limit, priority)` take it for the frame that asks for it, which has
  only one: another releases the previous one, and its `Exit` releases it.
- Priority: without room, a claim of a higher priority displaces the live holder of the lowest
  priority below it that is not in use; `claim_use` (`reserve_use`) marks a holder in use, and
  then nobody displaces it. Equal priorities never displace. The displaced holder is not
  notified: `reserve_holds` is false for it.
- The mind renews the lease of what it holds on each tick; whoever stops running loses it `lease`
  ticks later (far agents, until their next decision). `think` reads without taking with
  `reserve_free(t, target, N)` (`reserve_open` from outside a think); `reserve_count` and
  `reserve_holds` say who holds what. Without room it adds to
  `failed`.

### Trace

- The mind stores the best proposals of its last decision (`proposals`, from highest to lowest) and
  its last exits with the cause and the action that interrupted them (`mind_exit_trace`).
  `mind_running` gives the running action and step as numbers, what is presented; `mind_doing`, as
  enum values.

### Instead of FSM, trees, HTN and GOAP

What those models gave, with a mind:

- **A state of a machine** (patrol, chase): an action that runs while `think` proposes it.
  **Transitions with conditions** are scores; the running one wins by `keep`.
- **An event that takes over** (damage, stun): a field of the game component that is written by
  whoever causes it; `think` proposes the reaction with a higher score than the rest and the action
  consumes it on entry.
- **Hierarchical states, the phases of a boss:** a datum (the health) that changes what is
  proposed; what belongs to the next phase scores higher than that of the previous one.
- **`Sequence`:** `steps`, or stages within an action. **`Selector` with priorities:** fixed scores
  in that order.
- **`Parallel`:** an action that does two things in its `Update` (move and aim); what is continuous
  is a service (perception, navigation).
- **`Repeat`, a loop:** the action that ends enters again in the same tick if it keeps being
  proposed, or its stages come back.
- **Decorators and cooldowns:** `mind_ready` and `commit`. **Blackboard and facts:** the game
  components, which `think` reads.
- **HTN** (combos, methods): `steps` with the list that the action chooses on entry.
- **GOAP** (getting ammo to shoot): a smart object; `think` proposes going if one is open, and the
  action reserves it, goes and uses it.
- **Utility AI:** it is the model; `consideration.odin` gives the curves if they are needed.

## Influence maps (`influence.odin`)

- `Influence_Grid` covers the ground (x and z) with value layers and the cover of each cell;
  `influence_init` reserves once and nothing allocates afterwards.
- A pass stamps the sources (`influence_stamp`, while no other runs) and takes each cell to the
  highest of its sources and of its neighbors from the previous pass, `falloff` less per meter, a
  `blend` of the path. `influence_spread` advances at most the cells it receives: the cost of a tick
  is bounded and what is read is the last finished pass.
- `influence_sample` interpolates among the four nearest cells; outside it is 0.
- Cover is eight directions per cell that the caller measures and writes (`influence_cover_set`);
  `influence_cover` gives 1 if the direction toward someone is covered, 0.5 if only a neighbor and
  0 if none or unmeasured.

## Considerations (`consideration.odin`)

- A `Consideration` reads one input, rescales it and maps it through a `Response` curve to 0..1.
  `score_considerations` is the product of those of a choice with the compensation for count, times
  its weight; a zero vetoes it and a choice without considerations is worth its weight.
- It uses only arithmetic: the scores do not depend on the platform.
- They score the places of a query; an agent chooses what to do with a
  [mind](#decisions-minds-mindodin), which takes the score of each proposal from the game.

## Perception and places (`perception.odin`, `places.odin`)

- `Perception_Memory` stores observations of fixed capacity: subject (a handle of the caller),
  position, senses of the last instant, confidence and instants. `memory_perceive` raises it;
  `memory_forget` lowers it to zero `forget` seconds after the last time and removes what was
  forgotten; `memory_remove` removes a subject immediately (one that no longer exists). When full, a
  new subject replaces the least certain one if it is more so. It is plain: it is copied with the
  agent.
- `sight_in_cone` says whether a point is in the cone and range of a gaze; what blocks it belongs to
  the caller.
- `places_rings` and `places_grid` arrange candidates around a point; `places_mesh`, the mesh points
  joined to a polygon without leaving a radius of the center: a grid over each reached polygon, or
  its middle if none falls on it, in the order in which they are reached. `places_best` scores each
  one with its considerations over the inputs that the caller measured for it and stores the best
  in order; one that scores zero never stays.

## Verification

- `mirai test std/ai` runs `mind_test.odin`: the zombie, the boss and a tactical bot of the demo
  tick by tick (chase, bites, attacks that end, reactions in the same tick, combos as steps, tokens
  and a shared ammo box), that do not oscillate, the trace, the lease of a reservation, the
  priority of claims and their use, that a copy
  gives the same future without allocating and hostile states and proposals; and
  `influence_test.odin`: passes within the budget, falloff per meter, cover and hostile inputs.
- `bench_minds` (`-define:MIRAI_BENCH=true`) measures the tick of 1000 zombies; `bench_navmesh`,
  the followers of one end by a search each and by one toward it; `bench_nav_build_tile`, a tile
  with an obstacle from its triangles and from its field; `bench_avoidance`, ORCA with walls.
- `nav_volume_test.odin`: free zone only far from the enlarged obstacles, the same one with any
  order of triangles, a path that passes under a wall between zones without crossing it, corridor
  following, expired references, nearest free point, no allocations and hostile calls.
  `avoidance_test.odin` covers ORCA in 2D and in 3D, a mover that does not step aside, a crowd
  that meets in a corridor without crossing its walls and the corners of walls.
- `nav_mesh_test.odin`: one search toward an end that gives every follower the way its own search
  does, over one-way and two-way links, and the walls near a point, kept while they cover it.
  `nav_build_test.odin`: a tile built again from its field, equal to the one its triangles give,
  and damaged fields.
- `nav_space_link_test.odin`: a path that leaves the mesh through a link, passes under a wall
  through the volume and returns to the mesh through another, the return, a one-way link and a start
  in the volume.
- `nav_coarse_test.odin`: a portal toward each neighboring region with its path, rebuilding a region
  identically, a route through the middle regions with one the graph does not know, removing and
  merging a region again, the path between two portals that goes around a wall with its corners, and
  the portals of a volume region with the path under a wall, also built in steps.
