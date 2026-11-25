# Plugin `navigation`

Automatic navmeshes, 3D air/water volumes, and agents (`plugins/navigation`, `Runtime` + `Editor`;
depends on `physics`). Core algorithms live in
[std/ai](../../mirai-std/references/ai.md#navigation).

## Meshes

- One navmesh per `Navigation_Settings` class (`radius`, `height`, `climb`, `max_slope`,
  `jump_up`, `jump_across`, `drop`, `collision` preset under `Collision_Settings`). Custom or sensor
  presets block nothing and report `navigation.class`. Changing class/build sizes rebuilds all.
- `Navigation` (world storage) copies with the world (`uid`, `revision`, `navigation_copy_kept`);
  `Navigation_Builds` (host, per-world) discards jobs for stale `uid`.
- `navigation_build` (`fixed`, `react`, game+editor, `server`):
  - **Bounds & input**: upright prism of bounded `Nav_Bounds` `Volume` (missing/unbounded reports
    `navigation.volume`), else static blocking collision AABB. Reads blocking
    `phys.static_triangles` only (includes terrain and foliage; excludes dynamic/kinematic/
    characters/sensors).
  - **Dirtying & residency**: marks tiles on `phys.static_changes`, `Nav_Area`, `Nav_Obstacle`,
    bounds, or `nav_rebuild` (log overflow marks all). Tiles overlapping
    `core.Ground_Query.unloaded` or far sections stay `unloaded` (keep existing/baked data). In
    Play, fully covered columns/zones drop (`dropped`) and reload from `Navigation_Bake` `.navmesh`
    in one read when back; editor keeps all tiles.
  - **Jobs & carving**: order-independent triangle hash skips unchanged tiles; empty tiles skip
    jobs. Queue priority: cached gate carves > waiting agents > nearest [simulation sources][src].
  - **Navmesh reach** (Play only): with `Navigation_Settings.resident > 0` (around each simulation
    source) or any `Nav_Source` (its own `distance`, 0 takes `resident`), tiles no agent wants wait
    until a source comes within reach; built tiles stay. No reach, a `Nav_Source` reaching
    everywhere (both 0), or the editor: everything builds, so bakes stay whole. Tiles on the
    straight way of a waiting or partial agent build anywhere.
    Cached heightfields (`NAV_FIELDS`) let `Nav_Area`/`Nav_Obstacle`-only dirty tiles recarve
    without revoxelizing (`Build_Stats.carved`). Clean ticks skip all work.
- **Areas & obstacles**: `Nav_Area_Kind` (`AREA_BLOCKED`, `AREA_WALKABLE`, `AREA_WATER`, + game
  ids); `Nav_Area` marks surface costs (`Nav_Agent.avoid` excludes). `Nav_Obstacle` (`Volume` prism
  or `Collider` AABB) enters ORCA while moving, carves after `settle` s (`settle == 0` carves
  cached tiles immediately).

[src]: ../../mirai-gameplay/references/libraries.md#sources-and-residency

## Air and water volumes

- `space = .Air` builds a [sparse octree](../../mirai-std/references/ai.md#volume-nav_volumeodin)
  from `Nav_Bounds{air=true}` minus static collision inflated by `(radius, height/2)` (default
  `Flier`; no air bounds = no volume).
- `space = .Water` builds from `Fluid` water boxes/planes (`phys.fluids_in`) minus dry boxes and
  collision (default `Swimmer`). Fluid edits dirty touched zones.
- Voxel = `min(radius, height/2) / 4`, zone = 64³ voxels. Zones share the tile dirty/hash/job/bake
  pipeline; areas and obstacles mark tiles only.

## Links

- `Nav_Link` joins entity to local `end` or `target` across all classes (`LINK_JUMP`, `LINK_DROP`,
  `LINK_CLIMB`, `LINK_LADDER`, `LINK_DOOR`, `LINK_FLY`, + game kinds; `LINK_SWIM` is synthesized at
  shores). `LINK_FLY` bridges surface to air (takeoff/landing).
- Authored links start enabled; toggling keeps attachments/refs; disabled links block planning and
  new crossings. Shared `capacity` spans classes and directions, released on finish/stop/teleport/
  removal. Jump/drop arcs validate against static collision (`navigation.link_arc`).
- Generated links (`LINK_OWNER_GENERATED`) are opt-in per class via jump/drop limits (default
  `Human` generates none), validated by capsule arc, and rebuilt on nearby tile edits.

## Agents

- `Nav_Agent` with a `Character` needs a capsule collider: picks smallest fitting class of its
  collider preset (falling back to Default, or explicit `class`). Dual-space agents (Walk +
  Fly/Swim) search mesh + volume across shores/`LINK_FLY`; deep water ground is `AREA_WATER`
  (blocked without `Swim`).
- **Bodyless** (`Nav_Agent` without `Character`, crowd walkers): one concept, same requests, paths,
  avoidance and links. Takes the named surface class or the smallest Default one (its radius and
  height); walks only. `agents_walk` moves it: avoided velocity at `Walk` acceleration/braking,
  `nav_corridor_move` (`nav_move_along_surface`) clamps it to the mesh at detail height, yaw turns
  at `Walk.turn_speed`; writes `Transform` (`core.world_set`, never `core.place`) and
  `core.Motion`. Jump/drop links follow the analytic `jump_launch` arc, climb/ladder a line;
  manual links wait as usual. Moved by anything else (game `core.place`), it replans from there.
  Its height is the detail mesh's, which quantizes up to one `cell_height` above flat ground.
- Requests via `Nav_Requests` (`nav_move_to`, `nav_follow`, `nav_stop`, `nav_look_at`,
  `nav_look_along`, `nav_crossing_done`, `nav_crossing_skip` that puts it at the end of the link);
  derived `Nav_Path` (navigation sole writer) and
  `Nav_Events` report status; removing `Nav_Agent` cleans route/path/drive. Volume and coarse
  scratch allocate lazily.
- **Shared follow**: 2+ matching walkers following one target share a reverse `Follow_Tree` search;
  target excluded from ORCA; corridor end slides with target until blocked.
- `navigation_agents` (`fixed`, `apply`, `server`): slices A* within `path_iterations`/tick;
  parallel ORCA within `NAV_AGENT_HORIZON` and `avoidance_reach` from sources with navmesh wall
  half-planes (`NAV_AGENT_WALL_HORIZON`) prioritized over neighbors, other `Character`s (players)
  and obstacles; neighbor scratch is sized for all agents + characters + obstacles before
  gathering (else `navigation.memory`); writes the velocity of the
  `input.Move_Input` of its body (`world_velocity`), keeping its buttons, and drops it
  (`input.move_release`) when it stops; a seated body only with `Nav_Agent.seated`.
- **Replanning & errors**: replans on invalid corridor, `core.place` teleport, off-level
  (`> climb + 0.5m`), or stuck (retries before `navigation.blocked`; agents queued behind movers
  wait). Held still by what never steps aside (a player) it replans every `2*NAV_BLOCKED` without
  failing. Airborne off-mesh waits to land instead of `navigation.off_mesh`. Partial paths wait
  while tiles build, then emit `Arrived_Partial`. A goal on tiles still building
  (`Class_Mesh.pending`) is no wait: the agent paths to the edge of what is built along its
  straight way (`edge_toward`, `Nav_Route.edge`, partial), waits there without arriving and
  replans as tiles publish.
- **Flight & swim**: 3D capsule center, straight-line fast path, 3D sphere ORCA; flight requests
  `MODE_FLYING`, swim lets physics own mode.
- **Crossings** (`MODE_NAV_LINK`, claimed every tick by `navigation_crossing` before
  `locomotion_prepare`, gated by `Nav_Crossings.count`; a crossing that ends or is dropped stops
  claiming and the character falls back to its walk): Jump/Drop launch ballistically,
  Climb/Ladder move linearly; Door/game/`Nav_Agent.manual` wait for `nav_crossing_done`;
  `passthrough` suspends collision (a ghost that rays still hit) while the game moves the
  character and restores on finish/cancel. Overrun replans. `nav_crossing_target` gives the ends
  of the link and the facing across it while `Crossing`, for the warp of a clip (`Nav_Path` stays
  at 64 bytes); `nav_crossing_skip` within `NAV_CROSS_REACHED` of the end goes on from there
  instead of placing the agent.

```odin
// Command an agent and finish manual door crossings in a fixed step.
navigation.nav_move_to(nav_requests, agent, target_pos)
for ev in nav_events.items {
    if ev.kind == .Crossing && ev.manual && ev.link == navigation.LINK_DOOR {
        // Open door or play transition, then release the agent:
        navigation.nav_crossing_done(nav_requests, ev.entity)
    }
}
```

## Sections

`Nav_Sections` tracks `Scene_Reference.extents` (loaded+enabled = here; unloaded = far unless
contained by a loaded section), any number of them: its lists are regathered in place when
references change and grow only then (no memory: `navigation.memory`, the rest unseen).

- Fully far tiles/zones drop with generated links; border tiles touching a loaded section remain
  `unloaded`. Columns covered from above by loaded sections build normally. Returning sections
  re-mark and stitch into the shared grid (`nav_mesh_add_tile`).
- **Coarse graph** (`Class_Mesh.coarse`): stores section boundary portals and portal-to-portal
  paths, rebuilt incrementally (`NAV_COARSE_EXPANDED` nodes/tick) on settle. Paths entering a far
  section stop at the entry portal (`Nav_Path.through`) and hand off to
  [the far field](#the-far-field).

## The far field

Zero configuration. Moving agents (`Waiting`/`Moving`/`Crossing`) get `scene.Roaming` so unloading
keeps them under root. Agents in far regions or at a `through` portal receive `Nav_Far` +
`core.Disabled`, stepping every `NAV_FAR_PERIOD` fixed server ticks along the coarse graph via
`core.place`. `nav_far_decide` runs mind/perceiver without rays (`Nav_Far.spare` carries unused
distance). Returning to a loaded section re-enables the agent on the nearest mesh/volume point with
zeroed velocity (`phys.set_velocity`). Fully deterministic in fixed-step table order.

## Baking

`Navigation_Bake` names a `.navmesh` (tiles, hashes, generated links, volumes, coarse graph).
Section bakes store overlapping tiles; parent scene stores remainder + full coarse graph. `nav.bake`
creates the component+file (1 undo step) and auto-rewrites on settle. Version mismatch or
corruption reports `navigation.bake` and rebuilds whole.

## Editor and API

- Inspection modes: `navigation`, `navigation.<class>`, `navigation.<class>.collision` (within
  `NAV_VIEW_COLLISION_REACH`).
- API: `nav.status`, `nav.build`, `nav.bake`, `nav.inspect`, `nav.path`, `nav.agent`, `nav.move`.
  `play.step` `drive` routes through `editor.Route_Provider`.

```sh
mirai rpc nav.status --wait-until 'ready == true'
mirai rpc nav.bake
mirai rpc nav.path '{"from":[0,0,0],"to":[20,0,12]}'
mirai rpc nav.agent '{"entity":"Guard_1"}'
```

## Verification

- `mirai test plugins/navigation/runtime`: box build, source-ordered builds, incremental rebuilds,
  blocked areas, generated/authored links + arc occlusion, world copy, class selection, ballistic
  launch, `.navmesh` bake, 3D cave flight + ORCA, amphibian shore swim, walk+fly `LINK_FLY`, seated
  drive, crowd patrol + off-level + mid-jump replan, shared `Follow_Tree`, heightfield recarving,
  idle crossing gate, unloaded terrain/bounds residency + bake reload, stable link toggles, shared
  capacity, ghosted `passthrough`, collider-only gates, close following, partial arrival, teleport/
  cleanup, crowd queuing, lazy scratch, deterministic parallel avoidance, nonblocking publish,
  sections (stitching, drop/reload, far travel/arrival/requests/flight, column overlap), and
  bodyless agents (stairs/ramp detail height + `Motion`, stepping around players, crowd scratch
  without memory, jump arc and manual skip).
- `mirai test std/ai`: coarse graph build and traversal.
- `mirai test plugins/navigation/editor`: far `nav.agent` and `play.step` `drive`.
- Demo session: `nav.status` settled, `nav.path`, Play `nav.agent`, and `Swarm` air arena.
