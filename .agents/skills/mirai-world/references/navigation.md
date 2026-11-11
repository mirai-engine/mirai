# Plugin `navigation`

Automatic navmesh and agents that walk on it, and volumes they fly through
(`plugins/navigation`, `Runtime` and `Editor`; depends on `physics`). The algorithms belong to
[std/ai](../../mirai-std/references/ai.md#navigation).

## Meshes

- There is one navmesh per `Navigation_Settings` class: size (radius, height), step, slope and
  what the links generated for it can ask for (jump up and across, drop). Changing a class or a
  build size rebuilds everything.
- A class's `collision` is the collision preset of its agents' colliders. Its mesh is made of the
  static collision that blocks a collider of that preset under `Collision_Settings`: a clip that
  blocks only players is not in the zombies' mesh, and one that blocks only zombies is. Default:
  what blocks the Default category. A change of the class or of what its preset is in
  `Collision_Settings` rebuilds it; a bake made of other collision is not read for it. Custom or
  a sensor preset blocks nothing: the class has no mesh and `navigation.class` says why.
- `Navigation` (world storage) holds the meshes and is copied with the world: Play starts with
  the document's mesh. `Navigation_Builds` (per world, application) holds the jobs and what
  follows the entities; a new copy is recognized by `Navigation.uid` and discards what was being
  built for another.
- **Every change of a mesh, a volume or a coarse graph moves `Navigation.revision`**, also across
  a reset. The uid and the revision of the `Navigation` they were built in say whose meshes a copy
  holds, until its own revision moves: the copy a history keeps (`navigation_copy_kept`) takes
  them again only when it holds those of another, also after the world went back to a copy, and
  copies the marks of the tiles, the settings and the counts every time.
- It builds by itself, in `navigation_build` (`fixed`, `react`, game and editor, `server`):
  - **Where.** Inside the `Nav_Bounds`; with none, in the box of all the static collision
    (`phys.static_bounds`). The box of a `Nav_Bounds`, a `Nav_Area` or a `Nav_Obstacle` is the
    [`Volume`](../../mirai-gameplay/references/libraries.md#volume) of its entity, a `Box` taken
    upright where the entity is (`box_half`); without one, the `navigation.volume` problem, and
    the navigation does not see it.
  - **What.** The physics static collision (`phys.static_triangles`) that blocks the agents of the
    class (above), without dynamic or kinematic bodies, characters or sensors; the arcs of the
    generated links are checked against the same collision. Terrain and foliage enter
    because they publish their shapes in the same physics world.
  - **When.** A tile is marked when a box of the physics change log (`phys.static_changes`)
    touches it, a `Nav_Area` or obstacle that changed, the bounds or `nav_rebuild`. A log that
    fell behind (another simulation, a copied world) marks everything.
  - **Residency.** The ground names the boxes where its static collision is not loaded
    ([`core.Ground_Query.unloaded`](../../mirai-core/references/core.md#ground): the chunks of a
    solid terrain without a collider), and the sections away theirs. A marked tile or zone that
    reads one is left `unloaded`: it keeps what it has, built before or baked, and is built when it
    loads; a search that finds no surface waits for it. In a running world (`Time.playing`), when
    those boxes change, the tiles (with all the heights of their column) and zones whose input they
    cover between them are dropped like those of a far section, with their mark and their generated
    links, and count in `dropped`. `Navigation_Builds` remembers which ones and the hash they had,
    which the coarse graph keeps counting; when the boxes stop covering one, it comes back from the
    `.navmesh` of each `Navigation_Bake` of the world, one read of each file for all those that come
    back, and is marked: the build finds it equal or builds what the bake did not have. The edited
    world keeps everything: the editor rewrites the `.navmesh` from its meshes.
    The box of a far section counts the same ([sections](#sections)). Without `Nav_Bounds`, those
    boxes are added to that of the collision: dropping colliders does not take tiles away.
  - **How.** The input of each marked tile is collected on the loop thread and hashed, whatever
    the order of its triangles, so a bake holds in a world that added its shapes in another order;
    if the hash is that of the tile it has, it is not built. A tile with no input at all is empty
    without a job. If not, a job builds it and the tile is published
    on a later tick only if nobody marked it again. Publishing does not allocate; a replaced tile
    expires its references.
  - **Carving.** A build from the collision leaves the heightfield of its tile with
    `Navigation_Builds`, which keeps those of the last `NAV_FIELDS` tiles. A tile marked only by a
    `Nav_Area` or an obstacle since its build began is built again from that heightfield
    ([std/ai](../../mirai-std/references/ai.md#tile-building-nav_buildodin)): its collision is
    neither gathered nor voxelized, and the tile and its hash are those the collision would give.
    Any other mark (the change log of the physics, the bounds, `nav_rebuild`, what loads) has the
    collision read again. `Build_Stats.carved` counts them.
  - **Nothing to do.** A tick in which no table, mark or build changed goes through none of them.
- **Areas.** `Nav_Area_Kind` is a named id (`AREA_BLOCKED`, `AREA_WALKABLE` and the game's).
  `Nav_Area` marks its area on the surface inside its box; the cost per meter of each area is in
  the settings and an agent excludes areas with `Nav_Agent.avoid`.
- **Obstacles.** `Nav_Obstacle` is a box that agents avoid while it moves; still for `settle`
  seconds, it blocks the surface under it until it moves. In the editor, not running, it is
  still.

## Air and water volumes

- A class with `space` `Air` has no navmesh but a volume
  ([sparse octree](../../mirai-std/references/ai.md#volume-nav_volumeodin)): the free space of
  the `Nav_Bounds` with `air`, without the static collision enlarged by its radius and half its
  height. The sky has no edge: without air bounds there is no volume. The settings bring the
  `Flier` class with the size of `collider_character()`.
- A class with `space` `Water` builds its volume the same way, from the water of the
  `Fluid`s (`phys.fluids_in`): the box of each water box and, of a plane, the part of each
  bound of the surface (or of the static collision) under its surface. Dry boxes stay solid,
  enlarged like the collision. Creating, moving or removing a fluid changes those boxes, and the
  zones they touch are rebuilt. The settings bring the `Swimmer` class.
- The voxel is a quarter of the smaller of the radius and half the height, and a zone is 64 voxels
  per side: a larger class builds coarser zones.
- Zones follow the tiles' path: they are marked by the physics change log, the air bounds and
  `nav_rebuild`; they are collected and hashed, jobs build them and they are published if nobody
  marked them again. Areas and obstacles only mark tiles. The bake stores them.

## Links

- `Nav_Link` joins its entity with `end` (in its frame) or with `target`, in all classes. Its type
  (`LINK_JUMP`, `LINK_DROP`, `LINK_CLIMB`, `LINK_LADDER`, `LINK_DOOR` or one of the game's) says
  what it requires: jump and drop by their geometry, abilities (`Nav_Ability`) by type and by
  their own.
- The arc of a jump or drop `Nav_Link` is checked with physics like that of a generated one, with
  the capsule of each class: the class it does not fit does not have it, or has it in the
  direction that fits, and the `navigation.link_arc` problem says so. It is checked again when the
  static collision changes over it.
- **Between the mesh and a volume.** A `LINK_FLY` `Nav_Link` is a takeoff: it goes from the
  ground, at its entity, to the air, at its end; in both directions it also lands. It is not a
  mesh link: those that walk and those that fly take it. `LINK_SWIM` is not placed: it is the type
  of the shores that an amphibian's search joins by itself ([agents](#agents)).
- Generated ones come out of the walls of each tile of a class that jumps or drops
  (`ai.nav_jump_links`), with an arc that a capsule of the class travels free according to
  physics; that of a drop first leaves the edge and then falls, and lands at least two diameters
  from the wall. They are rebuilt when a tile within reach of a jump changes, also those of a tile
  waiting for its collision, from what it keeps. Their owner is `LINK_OWNER_GENERATED` with the
  tile coordinate.
- A link requires what it measures; A* discards it for an agent that cannot cross it, which goes
  around or does not arrive.

## Agents

- `Nav_Agent` goes on an entity with `Character` and a capsule collider. Its class is the
  smallest that contains its capsule and that does not climb more or walk steeper than its
  `Character`; with a `Fly`, the smallest air class that contains it while it flies, and with a
  `Swim`, that of the water while it swims (both always, without `Walk`).
  With none, the `navigation.agent_class` problem says what radius and height are missing.
- **Two spaces.** With a `Walk`, one that swims or flies has the surface class while physics has
  it walking and that of the water or air while it swims or flies; `Nav_Path.partner` is the class
  of the other space. Its path is a search over the mesh of one and the volume of the other,
  joined by shores (where a polygon borders the ground under deep water, near the path, round
  trip) or by takeoffs; under water the ground is not walked, it swims through the volume. Its
  corridor reaches the crossing: there it goes to `Crossing` with the crossing's type, asks to fly
  on takeoff or to fall on landing, goes toward the other side until physics changes its mode and
  its class (a takeoff, to the point in the air it leads to, away from the ground), and plans the
  rest from there. Without crossings nearby, each space searches alone, and physics decides the
  mode all the same.
- The ground under water deeper than what is waded (`Swim.depth` of `SWIM_DEFAULT`) is of the
  `AREA_WATER` area: an agent without `Swim` does not step on it; one that swims crosses it, and
  swims there.
- What it crosses comes from its components: jump height from `Walk.jump_height`, width from
  `Walk.max_speed` times the time in the air, drop from `Nav_Agent.drop` (or its class's) and its
  abilities.
- It is asked through `Nav_Requests`: `nav_move_to`, `nav_follow`, `nav_stop`, `nav_look_at`,
  `nav_look_along`, `nav_crossing_done`. `Nav_Path`, which navigation adds and only navigation
  writes, says what it is doing; `Nav_Events` reports arrivals, failures and crossings.
- **Followers of one target.** Several walkers of a class that walk and cross the same and follow
  the same entity read their paths from one search toward it
  ([std/ai](../../mirai-std/references/ai.md#queries-nav_queryodin)): the first plans its own way,
  the second starts the shared search, and it starts again when the target moved on, no more often
  than a follower plans again, or the mesh changed. One it does not reach (cut off, or beyond what
  the search holds) searches its own way. Those that fly, swim or cross between spaces, and a way
  into a far section, search alone.
- `navigation_agents` (`fixed`, `apply`, `server`): searches paths in portions in arrival order
  within `path_iterations` per tick, moves the corridor to where the body is, goes to the next
  corner, steps aside from the others with ORCA (characters that do not navigate and obstacles
  enter as neighbors that do not step aside) and writes the `Move_Input`, unless a seat drives the
  body: toward its velocity, at the share of the speed of its `Walk`, `Fly` or `Swim` that the
  velocity asks. It turns at the `turn_speed` of its `Character` and adds the turn of the ground.
- **Neighbors as far as the horizon.** An agent gathers those it may meet within
  `NAV_AGENT_HORIZON` at its speed and theirs, from the cells around its own in blocks that grow
  until they hold that reach, or as many neighbors nearer than the block as ORCA counts.
- **Seated** (`Nav_Agent.seated`, click to move): a body a seat drives walks while its path is
  `Moving` or `Crossing`, after the seat wrote its `Move_Input` in the tick: navigation replaces
  the move and the look, and keeps the seat's buttons and the turn of the ground it added. Idle,
  arrived or failed, the seat moves it again.
- **Stepping aside without leaving the navmesh.** The edges of its navmesh that one that walks
  could reach within `NAV_AGENT_WALL_HORIZON` are walls of its ORCA program, ahead of its
  neighbors: no velocity it chooses crosses them, and toward an edge it slides along it. Without
  that, those that gather at the start of a link (a staircase, a drop) push each other off a
  platform. One that is
  still far from the level of its corridor (more than its `climb` and half a meter: pushed,
  fallen, placed elsewhere) searches again from where it is, instead of walking against the wall
  toward a corner above.
- **Planning on the way.** While its path is searched (`Waiting`), one that walks goes on along
  the corridor it has, from whose first polygon the search starts. It plans again when a step
  ahead stops being valid.
- **Searching in the air.** A request cuts the crossing in progress and searches in the same tick.
  If the body is not standing on the ground (it falls, or jumps between roofs) and there is no
  navmesh within its reach, the search waits for it to be standing instead of failing with
  `navigation.off_mesh`.
- **Flight.** An air agent plans and steps aside through the center of its capsule: its goal is
  where that center goes (the nearest free one, for a point on the ground). If it sees it in a
  straight line it goes without searching; if not, it follows its corridor toward the farthest
  portal it sees and, pushed out of free space, returns to its first cell. It asks for
  `MODE_FLYING`, looks level and writes `move.y`, brakes in time for its `Fly.acceleration` and
  steps aside with ORCA in three axes, with the neighbors as spheres. Those that walk step aside
  only from the neighbors at their height.
- **Swimming.** A water agent goes the same as one of the air, at the speed of its `Swim`, without
  asking for the mode: swimming is decided by physics.
- **Crossing.** On reaching the start of a link it goes to `Crossing`. `Jump` and `Drop` are
  crossed by the `MODE_NAV_LINK` locomotion mode with a ballistic launch that lands at the end, by
  the same arc that generation checked; `Climb` and `Ladder`, along the link without gravity
  (`navigation_crossing`, before `locomotion_step`, which looks at the paths only while
  `Nav_Crossings` counts an agent crossing). `Door`, the game's types and those of
  `Nav_Agent.manual` wait for `nav_crossing_done`. A crossing that does not land in time plans
  again.

## Sections

`Nav_Sections` gathers on each build tick the sections with a box (`Scene_Reference.extents`),
streaming or manual ([scenes](../../mirai-gameplay/references/libraries.md#scene)).

- **Here and far.** A section is here while it is loaded and enabled. One that is not, is far,
  unless the box of one that is here contains its own (two versions of the same place, a section
  inside another). A point is far if it falls in a far box and in none of those here.
- **Tiles that come and go.** When the sections change, the tiles and zones whose box is covered
  between them by the far boxes and that do not touch one that is here are dropped, with their
  mark and their generated links. Those at the border, which touch a section that is here, are
  kept: their input reads what is not there and they are left `unloaded`, unbuilt. A tile reads
  all the heights of its column: it does not wait for a far section that, seen from above, is
  covered by sections that are here (another floor of the column, as in a pit), and is built with
  what is there. What a returning section covers is marked, and what its bake did not bring or
  what changed is built.
- **Stitching.** The tiles of all sections are in the same world grid: `nav_mesh_add_tile` joins
  their portals with the neighbors, whether they come from the bake of one section or another, or
  from a build.
- **Coarse graph.** For each class, `Class_Mesh.coarse`
  ([std/ai](../../mirai-std/references/ai.md#coarse-graph-nav_coarseodin)) stores how sections are
  joined: portals where the mesh, or the free space of an air or water class, crosses the box of
  each one, with the outside region (the `Id` of the reference of the smallest box that contains
  what is outside; 0 outside every box), and the path between each two portals of a section. The
  region of a section here is rebuilt when its tiles or zones settle with other hashes than they
  had, keeping its portals toward the far sections; that of a far section is kept, and a section
  without zones of a class has no region of it. One is rebuilt at a time and over several ticks
  (`NAV_COARSE_EXPANDED` search nodes per tick, the edge of a volume one zone at a time): the
  previous one serves until the new one finishes, and it starts again if its zones, its tiles or
  the sections change. It is only looked at when a tile, a zone or a section changed, or while a
  region is under way.
- **Paths that enter a far section.** If the goal is far or the coarse graph route between two
  regions passes through a far section, the agent searches its path only up to the portal where
  the route enters (`Nav_Path.through`), in the mesh or in the volume; there it continues
  [far](#the-far-field).

## The far field

It needs no component or configuration.

- **Roaming.** An agent with somewhere to go (`Waiting`, `Moving` or `Crossing`) has
  `scene.Roaming`, which navigation sets and clears each tick: when its section unloads it is not
  left asleep but hanging from the root. What moves a mind's plan counts because its actions
  request paths ([behavior](behavior.md#minds)). What has nowhere to go is left asleep like any
  entity that changed.
- **Going far.** In `navigation_agents`, an agent that moves and is where there are only far
  sections, or reached the portal of a `through` path, receives `Nav_Far` and `core.Disabled`:
  without body, mesh or animation. Its route goes from where it is to its goal through the coarse
  graph of its class, at the speed of its mode: one that flies or swims, through its medium and
  through the air or water; without a route in the graph, straight to the goal.
- **Coarse simulation.** Every `NAV_FAR_PERIOD` fixed ticks, on the server, it advances along its
  route and is placed with `core.place` (its `Transform` is free while it is disabled). A follower
  rebuilds the route if its target moved away; a cut route is rebuilt when it ends. On reaching
  the goal it is left `Arrived`, disabled. `Nav_Requests` to a far agent change its goal or stop
  it.
- **Deciding far.** Its mind decides, and its `Perceiver` perceives without rays, on the tick
  after each step (`nav_far_decide`), with what the step left ([behavior](behavior.md#minds)).
  What it asks goes in the next step, which also walks what was left over from the previous one on
  reaching the end of its route (`Nav_Far.spare`): deciding costs it no time.
- **Coming back.** When the sections change and on each step, a disabled agent whose point is no
  longer far, and whose route does not enter a far section, comes back: to the nearest point of
  the mesh or of the free space of its volume (it waits while it is built), enabled, with its body
  still (`phys.set_velocity`), `Arrived` with its event or `Waiting` to plan again. Which section
  it hangs from is decided by streaming.
- **Determinism.** Everything runs on the fixed step, in table order and without address hashes:
  the same world gives the same routes on the server and when resimulating.

## Baking

- `Navigation_Bake`, a component of an entity of a scene (`nav.bake` creates the entity the first
  time), names the `.navmesh` of that scene: tiles, hashes, generated links, zones of the air and
  water classes and the coarse graph. Each one in the world puts into the meshes what its file has
  and they do not when its row appears: that of the scene when it loads, that of a section when it
  loads.
- The `.navmesh` of a section stores the tiles and zones that touch its box; that of the scene
  that contains it, those that the boxes of its sections do not cover and the whole coarse graph.
  Those at the border are in both and are read once.
- `nav.bake` makes it next to the scene, or the scene of the section edited in its world, in an
  undo step and in the memory of the registry; afterwards the editor rewrites in memory that of
  each `Navigation_Bake` of the edited world every time the meshes settle. Only saving the scene
  writes it to disk (its field is `owned`).
- A world that loads the scene starts with those tiles and only builds those that changed. A file
  from another version or a damaged one is the `navigation.bake` problem and the mesh is built
  whole.

## Editor and API

- **Navigation** inspection modes (`navigation`, `navigation.<class>`): polygons by area, walls,
  edges between tiles, links with their arc and the corridor and corners of the selected agents.
  For an air class, its zones and the free nodes larger than a block, and the corridor cells and
  the tightened path of the selected agents.
- `navigation.<class>.collision`, for a surface class: what its mesh is made of, within
  `NAV_VIEW_COLLISION_REACH` of the camera; the colliders that block its agents bright and those
  that block only others dim.
- `nav.status`, `nav.build`, `nav.bake`, `nav.inspect`, `nav.path`, `nav.agent`
  (`engine.describe` gives their schemas); the four read ones also cover the volume, and
  `nav.status` counts the tiles waiting for their collision (`unloaded`), those that left with
  their section or, in a running world, with the unloaded terrain (`dropped`) and the regions and
  portals of the coarse graph.
- The `drive` of `play.step` takes its next point from this plugin (`editor.Route_Provider`),
  by the class of its body and what it can cross, so it goes around what the meshes go around
  and, where they end, by itself. In a game just started it waits a moment for the meshes.

## Verification

- `mirai test plugins/navigation/runtime`: building around a box, rebuilding only the tiles that a
  change touched, blocked areas, generated links between roofs and their arc closed by a wall, a
  staircase `Nav_Link`, the arc of a jump `Nav_Link` covered by a roof, the world copy, an agent's
  class, the launch that lands, reading a `.navmesh` and two agents that fly through a U-shaped
  cave, passing under its wall and stepping aside from each other; an amphibian that enters the
  water through the shore, crosses it swimming and exits, and one that walks and flies that takes
  off and lands through `LINK_FLY` `Nav_Link`s; a seated agent that walks while its seat drives
  it, beside one that is not seated and stays; six that patrol together over a staircase, a drop
  and a fence that the game crosses without falling off the platform, and one that is taken out of
  its level and climbs back, and one that is asked for another destination in the middle of a
  jump; eight that follow a runner by one search toward it; tiles that an area or an obstacle
  changes, built again from their heightfields and equal to those the collision gives; the
  crossing of links that looks at no path while none crosses; the tiles waiting for unloaded
  collision, with and without `Nav_Bounds`, and those of the
  unloaded terrain, which are dropped in a running world, kept in the edited one and come back
  from their bake without being built. Sections: the bakes of two that stitch at their border,
  the tiles of one that leaves and comes back with its bake, nothing to do without changes, an
  agent that crosses an unloaded section far away and appears in the next, one that arrives far
  away and appears when its section loads, one that receives requests far away, one that flies far
  away along the air path of the unloaded section and the tiles over a far section in a column.
  `mirai test std/ai` builds and walks the coarse graph. `mirai test plugins/navigation/editor`
  says what an agent does far away (`nav.agent`) and the next point of a drive; the unloaded boxes
  of a terrain are tested in [terrain](terrain.md#verification).
- In a demo session: `nav.status` until no tiles are left waiting, `nav.path` between two points
  and, in Play, `nav.agent` of an agent that walks; the `Swarm` arena for the air.
