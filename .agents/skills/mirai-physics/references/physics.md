# Physics: current behavior

Solver (`plugins/physics/runtime/sim`, package `mirai_physics`) depends only on `std/base`,
`std/math`, `std/spatial`. SI units, +Y up, right-handed. Types/constants: `types.odin`.

## World and memory

- `world_init(&w, desc)` preallocates all pools per `World_Desc` (default `world_desc_default()`,
  `substeps = 4`); [breakable](destruction.md#with-the-world) pools allocate lazily on first
  breakable. `world_destroy` frees; `world_step(&w, dt)` advances one tick.
- `Body_Handle`, `Shape_Handle`, `Joint_Handle` are generational (0 = null; stale handles
  ignored). LIFO slot reuse is snapshot state.

## Bodies and shapes

- `Body_Type`: `Static`, `Kinematic`, `Dynamic`. `Body_Desc` sets pose, velocities, damping,
  `gravity_scale`, `sleep_threshold`, axis `locks` (`Lock_Linear_*`/`Lock_Angular_*`), `bullet`,
  `sleep_disabled`, `asleep`. `Own_Gravity` (`world_set_body_gravity`/`body_gravity`) overrides
  world gravity (both scaled by `gravity_scale`).
- Mass/CoM/inertia derive from shape `density` (kg/m³; massless dynamic gets 1 kg;
  `body_set_mass_properties`; static has none and is not walked). All creators/setters reject
  non-finite inputs unchanged. 3x3 inversion uses scale-relative tolerance.
- `body_apply_force*`/`torque` accumulate until step; impulses apply immediately;
  `body_set_kinematic_target` computes 1-step velocity; `body_set_transform` teleports;
  `body_set_type` discards contacts.

```odin
w: phys.World
assert(phys.world_init(&w, phys.world_desc_default()))
defer phys.world_destroy(&w)

floor := phys.body_create(&w, {type = .Static})
_ = phys.shape_create(&w, floor, {
    geometry = phys.Box{{10, 0.5, 10}}, friction = 0.6, filter = phys.FILTER_DEFAULT,
})
bdesc := phys.BODY_DESC_DEFAULT
bdesc.position = {0, 3, 0}
box := phys.body_create(&w, bdesc)
sdesc := phys.SHAPE_DESC_DEFAULT
sdesc.geometry = phys.Box{{0.5, 0.5, 0.5}}
_ = phys.shape_create(&w, box, sdesc)

phys.world_step(&w, 1.0 / 60.0)
if hit, ok := phys.ray_cast_closest(&w, {0, 5, 0}, {0, -10, 0}); ok {
    _ = hit.point
}
```

### Area forces

`world_apply_area` applies force/impulse, or with `per_mass` acceleration/velocity change scaled
by each body's mass (radial—negative attracts—or
directional) to dynamics at CoM (no torque) using `Area` (AABB + `weight` callback in `[0,1]`,
e.g. `volume.weight`), query filter, compound dedup, `Radial_Falloff`, `Weight_Range`, and
stateless `Field_Noise` (`noise_perlin3`). Invalid curve/range or negative `scale` rejects.
Radial impulse on characters uses `character_launch`.

### Geometry

- `Geometry` union: `Sphere`, `Capsule`/`Cylinder` (local Y), `Box`, `Hull_Handle`,
  `Mesh_Handle`, `Heightfield_Handle`. `Shape_Type` order picks shape A.
- `hull_create`: validates CCW closed convex faces, builds half-edges/planes/mass.
- **Convex radius:** boxes, cylinders (`Shape_Desc.convex_radius` < min half-axis/radius) and
  hulls (`hull_create`, core shrunk inward via `std/geom`, < CoM-to-face distance) collide as
  inflated cores without changing nominal size, mass, AABB or debug draw; negative/non-finite
  rejected; 0 = sharp at zero cost.
- `mesh_create`: sanitizes degenerate/duplicate triangles, builds BVH, suppresses flat/concave
  internal edges (`disabled_edges` obeys `mesh_edge_active`), `inside_out` flips winding.
  **Front-face only** (including [bullets](#bullets)): back-side penetrations exit cleanly.
- `heightfield_create`: row-major heights at `cell * (col, h, row)`, diagonal `(c+1,r)-(c,r+1)`,
  `holes`, `disabled_borders`, `surfaces` + `cell_surfaces` (128-bit `Surface` reported on
  `Ray_Hit.surface`, contacts, hits; `world_set_surface_rules` overrides friction/restitution in
  state).
- Shared geometries free at 0 refs; capacity overflow returns null and increments
  `geometry_capacity_exhausted`. `mesh_geometry`/`heightfield_geometry` lend read-only views.

### Filters

- `Filter{layers, block, overlap, group}`: weaker response wins (`Ignore < Overlap < Block`,
  `filter_response`). Equal nonzero `group` never collides. `Overlap` has no manifold/response/
  wake (still reported by [bullets](#bullets)). `shape_set_filter` discards contacts.
- Friction combines by geometric mean; restitution and rolling resistance by max.

### Contact rules

In `Shape_Desc`/`Shape`/snapshot `Contact` flags; `shape_set_surface` updates in place:

- `surface_speed` (shape frame): conveyor target speed (added to
  [character ground](character.md#ground-probe)).
- `one_way`: blocks only from local +Y (`ONE_WAY_COS` and approach depth; others stay `Pass`
  without manifold/events; bullets skip behind; queries see normally).
- `dominance`: higher value acts as infinite mass vs lower-dominance dynamics only.
- `rolling_resistance` (coeff * radius): warm-started relaxation torque; holds on slope
  `atan(r/R)`; ignored with locked rotation.
- **Push rules** (`world_set_push_rules`, `Push_Rule{a,b,force}` in `World_State`): bounds
  dynamic-dynamic normal impulse per substep to `force * h` (min across matching rules); rejects
  empty layers or non-positive/non-finite force atomically. Rigid against statics/kinematics.

### Twins and cuts

Portal support (`twin.odin`, in `World_State` snapshot and `world_hash`):

- `world_set_cuts` (`Cut{body,shape,region}`, <= `CUT_CAPACITY`): removes contact points, rays,
  sweeps and `closest_shape` inside oriented box `region` (overlaps stay); wakes affected
  bodies.
- `body_set_twin(body, through, point, normal)` / `body_clear_twin` (non-static, <=
  `TWIN_CAPACITY`): mirrors shapes through `through`, colliding only in front of the plane; no
  mass/CCD/fluids; solved in body frame (impulses return to body, dynamic others rotate velocity
  serially, events/queries report world copy pose). [Bullets](#bullets) skip twin copies and cut
  shapes.

## Step

`world_step`: [characters](character.md) -> broad phase -> narrow phase -> awake -> char
constraints -> colors & islands -> prep -> substeps -> restitution -> impulse store -> final
poses -> bullets -> tree -> char ground -> events -> broken joints -> sleep -> hits (read by
[destruction](destruction.md) after step).

- **Broad phase:** static + moving fattened AABB trees; pair dedup on shorter body contact list;
  parallel batch buffer (`contact_capacity`, deterministic serial fallback on overflow);
  `world_rebuild_static` rebuilds static tree at 50% dirty (tracked in tree state).
- **Narrow phase:** closed forms, 15-axis box-box SAT, Gauss-map + axis-cache hull SAT
  (`Contact.sat`, `LINEAR_SLOP`), GJK+SAT/EPA (`collide_convex`, `CONVEX_MARGIN` for cylinders),
  rounded core SAT + GJK fallback; `MANIFOLD_MAX_POINTS`; carried manifolds (`Contact.relative`,
  `Stats.carried_contacts`; bypassed for overlaps/one-way/chars/twins/cuts); meshes group into
  `Manifold_Block`s; warm start by feature id or `MATCH_DISTANCE`.
- **Soft-step solver:** per substep: velocity integrate (implicit gyroscopic) -> warm start ->
  biased solve -> position integrate -> unbiased relaxation (2D CoP friction + torsion).
  `contact_hertz` capped at quarter substep freq; restitution applied once at end (no deep-
  overlap bounce).
- **Colors & lanes:** `GRAPH_COLORS` (statics last, uncolored serial first); 4-wide `core:simd`
  `Contact_Block(N)`/`Joint_Block(N)` (general joints run scalar `joint_solve` before color
  lanes). Step walks awake-body and moved-shape lists (snapshot state), never whole pools.
- **Islands & sleep (`island.odin`):** persistent snapshot state; join on touching contact/joint
  (kinematic = own island, static/char = none); `Island.removed` triggers splits before sleep;
  sleep speed includes half step displacement speed; sleeps after `TIME_TO_SLEEP`; `body_rest`
  places asleep without waking neighbors; `bodies_group`/`body_group` groups awake chains.
  Internal flags: `Character`, `Debris` (statics only, no events, skipped by queries).

### Bullets

Fast awake dynamics moving > `CCD_SAFETY` of min extent sweep vs statics (`CCD_CORE` CoM sphere
if starting touching). `bullet` adds dynamic/bullet passes (`ccd.odin`, <= `CCD_MAX_IMPACTS`):

- Sweeps moved bodies in a scratch tree with relative translation + rotation; accepts impacts by
  time then slot. Static hits bounce and continue (`CCD_RESUME_KEEP`); moving/jointed hits apply
  time stealing to target and direct joint neighbors; invalidated targets re-sweep.
- Responds at impact pose (friction/restitution, stored for warm start), wakes target, emits
  event in tick; one-sided [geometry](#geometry).

### Bullets and overlaps

CCD sweep detects convex overlaps not touching at tick start (statics only unless `bullet`, <=
`CCD_OVERLAP_CAPACITY`, overflow in `Stats.ccd_overlaps_dropped`): passed-through thin triggers
emit `overlap_begin` + `overlap_end` with `crossed`.

## Fluids

Analytic water volumes in snapshot (drawn by [`water`](../../mirai-world/references/water.md)):

- `fluid_create`/`set`/`destroy` (`Fluid_Desc`): `Plane` (ocean), `Prism` (polygon column of
  `depth`), `Path` (monotone-y `math.path_at` river in `World.fluid_paths`; terrain ground-
  snapped on `core.Ground_Queries.changed`). Zero-density `Prism` is a dry cutout subtracting
  lower-priority fluids; highest priority wins; wakes reached bodies; lazy step scratch.
- **Surface & waves:** single `fluid_spot` query; Gerstner waves (`Fluid_Desc.waves`,
  `world_time` in snapshot, f64 phase reduction, `wave_terms`/`wave_point`/`wave_surface`,
  `WAVE_FOLD` cap, Slang twin). Public queries: `fluid_sample`, `fluids_overlap`,
  `fluid_bounds`, `fluid_surface`, `fluid_holds`. Integration `Fluid_Waves` generates
  Pierson-Moskowitz waves from `Wind` (`physics.fluid_waves` on river); overlapping fluids
  report `physics.fluid_overlap` (`fluids_meet`).
- **Buoyancy & drag:** bodies sample up to 2 fluids (`fluid_find`), use tangent wave plane per
  step, exact clipped submerged volume/CoB (`prism_walls`), buoyancy `ρ V g` (scaled by
  `gravity_scale`), waterline damping (`FLUID_DAMPING_RATIO`), and implicit linear/angular drag
  (`Shape_Desc.drag` / `CD_SPHERE`..., `shape_set_drag`; 0-density/meshes/heightfields displace
  nothing). Unbalanced floaters stay awake. Characters: [character](character.md#in-a-fluid).

## Joints

`Joint_Desc` defines frames (`joint_frames` aligns X to world axis) and six `Joint_Axis` entries
(`Free`/`Locked`/`Limited` + `Position`/`Velocity`/`Disabled` drive). No explicit joint kinds:

- 2-3 limited linear axes share a distance limit (driven by first); limited Y+Z angular axes
  share a cone. `joint_kernel_of` selects SIMD lane kernels (`Fixed`, `Revolute`, `Prismatic`,
  `Spherical`, `Distance`) or scalar `General`. Axes live in `World.joint_axes` (snapshot).
- `joint_configuration_error` validates upfront; `joint_set_axes` preserves warm start on
  target/budget edits (resets axis on motion/limit/flag change, all on kernel change);
  `joint_drive_pose` validates atomically and frees driven locked axes. `break_force`/
  `break_torque` emit `Joint_Break_Event`. Limits are rigid in velocity, soft in violation
  recovery.

```odin
fa, fb := phys.joint_frames(&w, body_a, body_b, anchor, {0, 1, 0})
jdesc := phys.Joint_Desc{
    body_a = body_a, body_b = body_b, frame_a = fa, frame_b = fb,
    linear = {{motion = .Locked}, {motion = .Locked}, {motion = .Locked}},
    angular = {{motion = .Free}, {motion = .Locked}, {motion = .Locked}},
}
joint := phys.joint_create(&w, jdesc)
```

## GJK

`gjk.odin`: distance, linear cast, EPA penetration and TOI on `Proxy{points, radius, disc}`
(continuous disc support in local XZ). Built via `shape_proxy`/`query_proxy`.

## Snapshot and determinism

- State = `state_arrays` + both trees + `World_State` (gravity, push/surface rules, twins,
  cuts). New state arrays go in `state_arrays` + `World_State` counter. `world_hash` hashes all
  state; `world_diff` pinpoints first field divergence. Worker-count invariant.
- `world_state_copy(&dst, &src)` + `world_kept_init` (trimmed snapshot world, never stepped)
  copy only modified 64-slot chunks (`*_get` stamps, `*_read` read-only) within the same lineage
  (idle step copies 0 bytes). Restore keeps piece hulls and zeros newer slots so generations
  repeat.
- Fails unchanged on capacity/tree mismatch, uninitialized world, missing shared geometry, or
  rebuilt hull revision (`hull_rebuild`/`hull_set_mass`). Outside state: shared geometry,
  events, manifold geometry, and [static change log](#static-collision) (restarted on write).

```odin
kept: phys.World
assert(phys.world_kept_init(&kept, &w, context.allocator))
defer phys.world_destroy(&kept)

_, _ = phys.world_state_copy(&kept, &w)
h0 := phys.world_hash(&w)
phys.world_step(&w, 1.0 / 60.0)
_, _ = phys.world_state_copy(&w, &kept)
assert(phys.world_hash(&w) == h0)
```

## Queries

Zero-alloc on caller buffers using `Query_Filter` (`filter`, `include_sensors`, `debris`,
`ignore_body`, `ignore_user_data`—falls back to shape user data on shared static body):

- `ray_cast_closest`/`ray_cast_any` (blockers), `ray_cast_all` (distance-sorted up to first
  blocker, keeps nearest on overflow), `shape_cast_*` (translating convex; rounded ray = point
  cast on inflated core), `overlap_shape`/`overlap_aabb`, `closest_*` (blockers only). Starting
  inside yields fraction 0 and zero normal.

### Static collision

- `shapes_triangles(w, box, vertices, indices, filter, shapes) -> (verts, idx, complete)`:
  read-only, thread-safe, zero-alloc world-space CCW triangles of blocking static shapes (never
  sensors; unrounded box/hull fans; spheres/capsules/cylinders use `TRIANGLE_SEGMENTS`/
  `TRIANGLE_BANDS`). `complete = false` if buffer fills.
- **Change log:** ring of `static_change_capacity` world AABBs for blocking static shape/body
  create, destroy, move, filter/type change (scratch—not in snapshot/hash). `static_bounds`/
  `static_bounds_update` caches total static AABB. `static_changes(w, since, out) -> (next,
  count, overflow)` returns `overflow` on ring wrap, foreign cursor, or `world_state_copy`.

## Events and diagnostics

- `world_events`: slices valid until next step (`overlap_begin`/`end` per side with `crossed`,
  `users` snapshot of body/shape user data, `breaks`
  ([reading](destruction.md#reading-and-replay))). Destroying outside step emits no end events.
- `body_contacts` (awake body contacts + `approach`), `world_stats`, `world_profile`.

## Parallelism

`World_Desc.parallel_for`, `worker_count`, `parallel_user` (in `context.user_ptr`); `nil` runs
serially inline. Overflowed pairs, uncolored constraints and shared side effects run serially in
deterministic order.

## `std/spatial`

- `math.Aabb` + `std/spatial` surface area, center, rays, sweeps.
- `Dynamic_Tree`: SAH-rotated AABB tree, zero-alloc iterators, `dynamic_tree_rebuild` (binned
  SAH), `dynamic_tree_copy` (chunk-stamped via `std/base` `chunk_stamp`); stale proxies ignored.
- `Bvh`: flat static binned SAH BVH, one leaf per iterator step.

## Debug draw

`world_debug_draw(&w, &out, flags, region, layers)` writes `Debug_Draw{lines, points}`
(`Shapes`/`Bounds`/`Contacts`/`Joints`/`Centers`/`Fluids`, zero-alloc, renderer-independent;
`Debug_Line` with `Debug_Kind`, `Debug_Point`, `lines_dropped`/`points_dropped`). `region` at
zero draws whole world; rounded shapes draw unrounded. `shape_debug_draw` draws one shape
(`false` on stale handle).

## Known limits

- Soft contacts yield under uneven tall loads; no GJK simplex cache or box-box axis cache (disc
  proxy starts cold, normal-only TOI).
- Cylinder edge contacts round by `CONVEX_MARGIN` and cost more in dense triangle/pile scenes.
- No vehicles, wheel joints, deformables, cloth or simulated fluids (analytic [fluids](#fluids)
  only). Meshes/heightfields do not collide with each other and add no mass.
- Debug draw omits [twin](#twins-and-cuts) copies (contact points stay in body frame); twin-twin
  contacts solve in shape A's body frame.
