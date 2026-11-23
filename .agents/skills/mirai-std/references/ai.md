# std/ai

Package `ai` (`import "mirai:std/ai"`), depending only on `core`, `std/base`, and `std/math`.

- Fixed-capacity contexts (`*_init`), zero allocations afterward; overflow returns `Open_Full` /
  `Output_Full` or increments `failed`.
- Agent state (`Mind`, `Perception_Memory`, `Nav_Corridor`) is plain POD, copyable for snapshots.
- `Nav_Mesh` mutates by whole tiles/links and `Nav_Volume` by whole zones in caller transactions.
- **One primitive per job:** one A*, navmesh/volume pathing, corridor following, ORCA avoidance,
  mind decisions, and places selection (no grid search, flow fields, steering forces, or FSM/BT).

## A* search (`search.odin`)

- `Open_Set`: fixed-capacity indexed binary heap (`open_push` inserts/decreases key, `open_pop`,
  `open_clear`); sized for simultaneous open nodes, not relaxations.
- `Search`: `u64` keys, generation-stamped (no clear between runs), single-threaded, reusable.
  `search_init(&s, {nodes, keyed, open, max_edges, allocator})` fails if `nodes > max(u32)/4` or
  `open > max(i32)`. Dense uses key as slot; `keyed` hash-maps sparse keys (overflow: `Open_Full`).
- `search_begin` + `search_step(..., accept, budget)` (or `search_run`): compile-time specialized
  `neighbors`, `heuristic` (consistent for optimality; 0 = Dijkstra), and `accept` (called when a
  relaxation wins, before `heuristic`). `edge_add` counts overflow in `dropped`.
- `Search_Status`: `Found`, `No_Path`, `Open_Full`, `Output_Full`, `Invalid`, `Running`. Read with
  `search_path`, `search_path_to` (partial), `search_cost`, and `search.stats`.

```odin
s: ai.Search
assert(ai.search_init(&s, {nodes = 256, keyed = true, max_edges = 16}))
defer ai.search_destroy(&s)
status := ai.search_run(&s, start_key, goal_key, &graph, graph_neighbors, graph_heuristic)
path: [64]u64
if status == .Found { n, _ := ai.search_path(&s, path[:]); _ = n }
```

## Navigation

Tiled navmesh (`nav_build_tile` or `nav_tile_from_triangles`), `+Y` up, CCW polygons from above
(queries are winding-independent).

- **Tiled mesh (`nav_mesh.odin`):** `Nav_Mesh` (`nav_mesh_init`) stores XZ tiles and links with
  zero-alloc add/replace/remove (overflow increments `failed`). `Nav_Ref` carries slot + generation
  so replaced tiles/removed links expire (`nav_ref_valid`, `nav_poly_of`, `nav_link_of`,
  `nav_ref_flip`). `nav_mesh_add_tile` takes ownership, stitches border overlaps within `climb`,
  and attaches links; `nav_mesh_copy` preserves refs. `nav_mesh_add_link` stores `Nav_Need` and
  `owner` (`nav_mesh_remove_links_of`); one-way links also record arrival for reverse searches.
  Spatial query: `nav_box_polys`.

### Queries (`nav_query.odin`)

- `Nav_Filter`: per-area cost/m (0 = 1), `excluded` bitmask, and `can: Nav_Need` (zero filter
  crosses no links).
- `Nav_Query` (keyed `Search`): `nav_path_begin`/`nav_path_step(budget)`/`nav_path_finish` or
  `nav_find_path`. Enters portals nearest the straight line to `end`; returns `partial` on
  `No_Path`/`Open_Full`; validates against mid-search mesh edits.
- **Many-to-one & multi-target:** `nav_costs` + `nav_cost_to` measure one start to many ends via
  Dijkstra. `nav_toward_begin` + `nav_toward_reach(ref, budget)` + `nav_toward_path` run one
  reverse search from a shared goal for all followers (walks one-way links in reverse).
- **Funnel & surface:** `nav_straight_path` pulls path taut, cutting at links (`Start`/`End`/`Link`
  corners); `nav_path_straighten` shortcuts bends via raycast without crossing costlier areas.
  Surface queries: `nav_find_nearest`, `nav_poly_height`, `nav_closest_point_on_poly`,
  `nav_move_along_surface`, `nav_raycast`, `nav_random_point`, `nav_random_point_around`,
  `nav_distance_to_wall`.
- `Nav_Boundary` (`nav_boundary_update`) caches unwalkable wall edges within 2× reach (surface on
  right, nearest first) for [avoidance](#avoidance-between-agents-avoidanceodin) until agent leaves
  coverage or a tile rebuilds.
- **Corridor (`nav_corridor.odin`):** Fixed-capacity `Nav_Corridor` straightens once on
  `nav_corridor_set` (sets `cut` if truncated), tracks agent via `nav_corridor_move`, slides moving
  targets via `nav_corridor_move_target`, yields corners up to next link via
  `nav_corridor_corners`, crosses links via `nav_corridor_cross`, and validates via
  `nav_corridor_valid`.
- **Jump/drop links (`nav_links.odin`):** `nav_jump_links` probes tile walls for `Drop`/`Jump`
  (second pass jumps gaps roof-to-roof), filtered by caller `clear`; `nav_jump_point` evaluates the
  shared ballistic arc (`NAV_JUMP_CLEARANCE`).

```odin
q: ai.Nav_Query; assert(ai.nav_query_init(&q, 1024)); defer ai.nav_query_destroy(&q)
filter := ai.Nav_Filter{can = ai.NAV_CAN_ALL}
refs: [64]ai.Nav_Ref
n, status, _ := ai.nav_find_path(&q, &mesh, s_ref, e_ref, start, end, &filter, refs[:])
corridor: ai.Nav_Corridor
if status == .Found {
    ai.nav_corridor_reset(&corridor, s_ref, start)
    ai.nav_corridor_set(&corridor, &mesh, &filter, end, refs[:n])
    ai.nav_corridor_move(&corridor, &mesh, &filter, agent_pos)
    corners: [4]ai.Nav_Corner
    _ = ai.nav_corridor_corners(&corridor, &mesh, corners[:])
}
```

### Volume (`nav_volume*.odin`)

3D sparse octree zones (`NAV_VOLUME_BLOCK * 2^layers` voxels/side; 4×4×4 leaf `u64` bitmasks) for
flying/swimming agents (`Nav_Volume`, `nav_volume_init`, `nav_volume_copy`, zero-alloc zone edits).

- `Nav_Ref` with `NAV_REF_VOLUME` carries zone generation. `nav_volume_build` marks voxels inside
  `spaces` clear of triangles inflated by `half` (triangle-order independent; `Empty` if none
  free).
- Queries: `nav_volume_find`, `nav_volume_find_nearest`, `nav_volume_raycast`,
  `nav_volume_random_point_around`, `nav_volume_portal`, sliced A* (`nav_volume_path_begin`/
  `step`/`finish`), and corridor steering (`nav_volume_corridor_set`, `nav_volume_corridor_steer`,
  `nav_volume_straight_path`).
- **Mesh-volume links (`nav_space_link.odin`):** `Nav_Space_Link` / `nav_shore_links` bridge dry
  mesh and volume; `Nav_Medium_Query` (`NAV_QUERY_SPACE_LINKS`) runs one unified A* across both,
  split at the transition by `nav_medium_first_part`.

### Coarse graph (`nav_coarse.odin`)

Cross-region routing over unloaded sections (`Nav_Coarse`, region key `0` = outside): stores
portals and intra-region path lengths + up to `NAV_COARSE_CORNERS` corners.

- `nav_coarse_build_region` / `nav_coarse_build_region_volume` (or time-sliced `Nav_Coarse_Build`
  via `nav_coarse_begin_region*`) merge border crossings (`NAV_PORTAL_MERGE`), compute portal-pair
  paths, preserve portals to unloaded `kept` regions, and swap atomically on finish.
- `nav_coarse_route` runs dense A* (straight-line across unknown regions; `Output_Full` if short).
  Corrupted indices return `Invalid`. Helpers: `nav_coarse_copy`, `nav_coarse_remove`,
  `nav_coarse_merge`.

## Tile building (`nav_build*.odin`)

Odin rewrite of Recast + Detour tile closing ([license][notices]).
`nav_build_tile(config, coord, input, &scratch, &out, allocator, field=nil)` builds a single-block
`Nav_Tile_Data` (`nav_tile.odin`) deterministically (platform rounding aside) from triangles
touching `nav_tile_rect(config, coord)` expanded by `nav_build_margin(config)` (radius + 3 cells).

- **Scratch & statuses:** `Nav_Build_Scratch` (one per thread, `nav_build_scratch_init`/`destroy`)
  reuses allocations across same-size tiles; `out` is overwritten without freeing. Returns `Built`,
  `Empty`, `Invalid` (bad sizes/slope/indices/volumes, `> NAV_BUILD_MAX_CELLS`, uninitialized
  scratch), `Too_Large` (16-bit overflow), or `Out_Of_Memory` (scratch stays usable).
- **Pipeline:** global height grid from `y = 0` (`origin.y` ignored); non-finite triangles skipped;
  filter slope (`agent_max_slope`), climb, ceiling, ledge drops -> mark volumes (last wins;
  `NAV_AREA_BLOCKED` acts as obstacle before erosion) -> erode by radius -> watershed regions
  (`min_region_area`, `merge_region_area`) -> CCW convex polygons (3..`NAV_VERTS_PER_POLY`) +
  detail mesh (`detail_max_error`, `detail_sample_distance`).
- **Rebuild from field:** pass `field: ^Nav_Tile_Field` to capture pre-volume walkable spans;
  `nav_build_tile_again` rebuilds byte-identical tiles for changed volumes without re-voxelizing.

## Avoidance between agents (`avoidance.odin`)

`avoid_velocity(self, preferred, max_speed, neighbors, horizon, dt, walls, wall_horizon)` runs
N-dimensional ORCA (`N = 2` disks, `N = 3` spheres; up to `AVOID_MAX_NEIGHBORS` nearest and
`AVOID_MAX_WALLS` walls).

- Reciprocal 50/50 split with cooperating neighbors; 100% avoidance around `ignores = true` agents;
  overlapping agents separate in one `dt`.
- **Walls first (2D):** `Avoid_Wall` (walkable side on right; agent behind wall ignores it) forbids
  crossing within `wall_horizon` (hard constraints even when neighbor planes are infeasible).
- Callers must apply the returned speed as well as direction so neighbor predictions stay valid.

```odin
self := ai.Avoid_Agent(2){position = pos, velocity = vel, radius = 0.4}
next_vel := ai.avoid_velocity(self, desired_vel, max_speed, neighbors, 2.0, dt, walls, 0.5)
```

## Decisions: minds (`mind.odin`)

Every tick `think` proposes actions with scores (`propose(t, action, score)`; `<= 0` or non-finite
ignored; ties keep first); highest wins. Each action is a `proc(^Act(Enum)) -> Status` handling
`Enter`, `Update`, and `Exit`.

- **Hysteresis & commit:** Running action scores `proposal + keep` or `commit(a, score)` (max of
  both). Higher scores abort it same tick (`Aborted`); unproposed + uncommitted aborts. Exiting
  actions re-run `think` immediately (failed action excluded from immediate re-entry). `decide =
  false` ticks the running action without re-thinking until it exits.
- **State & cadence:** `Mind` is layout-identical POD for any enum in `0..<MIRAI_MIND_ACTIONS` (32
  by default, at most the 32 bits of `exited`; each value costs 8 bytes of `ended`; `a.memory` has
  `MIRAI_MIND_WORDS` zeroed on `Enter`; `stage`, `next_stage`, `elapsed`, `stage_elapsed`, `after`,
  `mind_since`, `mind_ready` count in ticks). `steps(a, x, y, z)` runs sub-actions sequentially (no
  nested steps). Distance throttling uses stateless `cadence_period` / `cadence_due`
  (`cadence.odin`). `mind_clear` forgets a state without calling its procedures, releasing its
  frames' reservations (a state of an enum that cannot run its `Exit`).
- **Reservations:** `Reservations` tracks attack tokens (`what = 0`) and smart-object claims via
  `token_take` / `claim(a, target, which, limit, priority)`. One reservation per frame, renewed
  every tick (`lease` expiry), auto-released on `Exit`. Higher priority displaces lowest unused
  holder (`claim_use`/`reserve_use` locks against displacement; check `reserve_holds`/`claim_held`;
  read in `think` via `reserve_free`).
- **Trace:** `Mind.proposals` (top scores), `mind_exit_trace`, `mind_running`, `mind_doing`.

```odin
Bot_Act :: enum u8 { Idle, Attack }
BOT_ACTS := [Bot_Act]proc(^ai.Act(Bot_Act)) -> ai.Status{
    .Idle = act_idle, .Attack = act_attack,
}

bot_think :: proc(t: ^ai.Think(Bot_Act)) {
    ai.propose(t, .Idle, 0.1)
    if ai.mind_ready(t.mind, .Attack, t.tick, t.dt, 1.5) &&
       ai.reserve_free(t, target_id, 2) {
        ai.propose(t, .Attack, 0.8)
    }
}
act_attack :: proc(a: ^ai.Act(Bot_Act)) -> ai.Status {
    if a.phase == .Enter {
        if !ai.token_take(a, target_id, 2) { return .Failure }
        ai.commit(a, 1.0)
    }
    return ai.after(a, 0.6)
}
```

### Instead of FSM, trees, HTN and GOAP

| Pattern | Mind equivalent |
| --- | --- |
| FSM state / transitions | Proposed action / scores + `keep` hysteresis |
| Interrupt event (hit/stun) | Component field read by `think` at higher score, consumed on `Enter` |
| Boss phases / HFSM | Health/state shifts proposed action scores |
| `Sequence` / `Selector` | `steps` or `stage`s / ordered scores |
| `Parallel` / `Repeat` | Action does both in `Update` (or service) / re-proposed on exit |
| Cooldown / Blackboard | `mind_ready` + `commit` / game components |
| HTN / GOAP / Utility | `steps` chosen on `Enter` / smart-object claim / `consideration.odin` |

## Influence maps (`influence.odin`)

`Influence_Grid` (`influence_init`, zero allocs after): `influence_stamp` writes sources,
`influence_spread(budget)` propagates `max(source, neighbor - falloff/m)` blended by `blend` in
bounded slices; `influence_sample` bilinearly reads last completed pass (0 outside). 8-direction
cover (`influence_cover_set`): `influence_cover` returns `1` (covered), `0.5` (adjacent), or `0`.

## Considerations (`consideration.odin`)

`Consideration` rescales one input through a `Response` curve to `0..1`. `score_considerations`
multiplies curves with count compensation × weight (0 vetoes; empty = weight); `score_product`
bounds partial evaluations assuming unmeasured inputs = 1. Pure arithmetic (platform-independent).

## Perception and places (`perception.odin`, `places.odin`)

- `Perception_Memory` (fixed-capacity POD): `memory_perceive` (ignores older timestamps; evicts
  lowest confidence when full), `memory_forget` (decays to 0 over `forget` s), `memory_remove`.
  `sight_in_cone` checks FOV/range (caller runs LOS).
- Candidate generation: `places_rings`, `places_grid`, `places_mesh` (reachable within radius).
  `places_best` scores candidates with considerations and keeps top non-zero results in order.

## Verification

- `mirai test std/ai`: `mind_test.odin`, `influence_test.odin`, `nav_volume_test.odin`,
  `avoidance_test.odin`, `nav_mesh_test.odin`, `nav_build_test.odin`, `nav_space_link_test.odin`,
  `nav_coarse_test.odin`.
- Benchmarks (`-define:MIRAI_BENCH=true`): `bench_minds`, `bench_navmesh`, `bench_nav_build_tile`,
  `bench_avoidance`.

[notices]: ../../../../THIRD_PARTY_NOTICES.md#adapted-code
