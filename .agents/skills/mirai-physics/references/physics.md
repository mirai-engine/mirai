# Physics: current behavior

The solver (`plugins/physics/runtime/sim`, package `mirai_physics`) is a rigid body library that
depends only on `std/base`, `std/math` and `std/spatial`. SI units, Y up, right-handed. Types,
constants and parameters: `types.odin` and the comments of each file.

## World and memory

- `world_init(&w,desc)` reserves everything according to `World_Desc`: capacities (bodies, shapes,
  contacts, joints, hulls, meshes, heightfields, events, characters, fluids, breakables, pieces,
  bonds, [static changes](#static-collision)), gravity, `substeps` (4 by default) and
  stiffness parameters. The pools of [what breaks](destruction.md#with-the-world) wait for the
  first breakable.
- `world_desc_default()` gives the initial values; `world_destroy` frees; `world_step(&w,dt)`
  advances one tick.
- `Body_Handle`, `Shape_Handle` and `Joint_Handle` are `distinct` generational handles. Zero is null
  and a stale handle is rejected; public functions ignore invalid handles.
- Slots are reused in LIFO order, which is part of the state.

## Bodies and shapes

- `Body_Type`: `Static`, `Kinematic`, `Dynamic`.
- `Body_Desc` sets pose, velocities, damping, gravity scale, sleep threshold, per-axis locks
  (`Lock_Linear_*`, `Lock_Angular_*`), `bullet`, `sleep_disabled` and `asleep`.
- A body falls with the world gravity or, with `Own_Gravity`, with its own
  (`world_set_body_gravity`, `body_gravity`); the gravity scale multiplies either one.
- Mass, center and inertia come from the shapes (`density` in kg/m³). A dynamic without mass
  receives 1 kg. `body_set_mass_properties` sets them by hand.
- 3×3 matrices are inverted with a tolerance relative to their scale: a 1 mm steel ball spins and a
  joint holds a 1e8 kg block.
- Forces (`body_apply_force*`, `body_apply_torque`) accumulate until the step; impulses change the
  velocity at once. `body_set_kinematic_target` gives a kinematic the velocity that takes it to a
  pose in one step, so that it pushes and carries. `body_set_transform` teleports; `body_set_type`
  discards the body's contacts.

### Area forces

- `world_apply_area` (force, impulse or velocity change; radial from the center of the area, where
  a negative intensity attracts, or along a vector) applies to dynamics and returns the amount
  applied and the validity of the request.
- The model has no shape for an area: `Area` is a box of the world that bounds it, which may have
  no end, and a `weight` callback that says how much of it a point is in (0 outside, up to 1).
  The integration gives `volume.weight` of a `Volume`, so the region is tested in one place.
- It walks the spatial tree with the query filter and deduplicates compound bodies in preallocated
  scratch. The center of mass sets direction and weight; the force produces no torque.
- `Radial_Falloff` are the curves of Chaos fields over that weight, from the edge (0) to the inside
  (1), and `Weight_Range` takes them from `min` to `max` like Chaos `MinRange`/`MaxRange`; outside
  the area the weight is zero.
- `Field_Noise` multiplies the weight by gradient noise (`noise_perlin3`) in the frame of the
  volume: a pure function of position and seed, stateless, the same with any number of workers.
- A curve outside the enum, a non-finite range or a negative `scale` invalidate the request. A
  radial impulse on a character uses `character_launch`: it leaves the ground in that tick.

### Geometry

- `Geometry` joins primitives (`Sphere`, `Capsule` and `Cylinder` on the local Y axis, `Box`) and
  handles of hulls, meshes and heightfields. A body admits several shapes with their local
  transform; the order of `Shape_Type` decides shape A of a contact.
- `hull_create` receives faces as counterclockwise loops seen from outside, validates that it is
  closed and convex and derives half-edges, planes and mass. Building the hull from points is not
  part of this package.
- **Convex radius** (as in Jolt): a box, cylinder or hull collides as its core, the shape shrunk by
  the radius, inflated by the radius. Faces stay where they are and edges are rounded; size, box,
  mass and debug draw are those of the unrounded shape. A box and a cylinder receive it in
  `Shape_Desc.convex_radius`, smaller than their smallest half-axis or radius; a hull, when built
  (its core is its planes moved inward, with `std/geom`), smaller than the distance from the center
  of mass to its nearest face. A negative or non-finite value rejects the shape; zero is the shape
  with sharp edges, at no added cost.
- `mesh_create` builds the BVH and marks flat or concave internal edges as non-colliding.
  **Triangles collide only by their front**, also for [bullets](#bullets): what arrives from behind
  a face passes through it. A thin wall that must stop from both sides carries two opposite layers
  or volume; a floor or a terrain, only its top face. That way what ended up behind a face comes out
  through the front instead of getting trapped.
- A contact with an edge or a vertex whose edges do not collide is taken by the neighbor, which sees
  it on its face. If neither takes it (over a ridge that is too flat, the point falls on the edge
  they share), it counts against the plane of the face, in the direction no other contact covers.
- `heightfield_create` copies a grid of heights by rows, with the sample `(column,row)` at
  `cell × (column, height, row)` and the diagonal between `(column+1,row)` and `(column,row+1)`;
  contacts and queries walk the nearby cells without storing triangles. `holes` cells have no
  surface for contacts, rays, sweeps or drawing, and their edges with the neighbors stay active.
- `Mesh_Desc.disabled_edges` and `Heightfield_Desc.disabled_borders` only deactivate seams that the
  neighbor makes flat or concave (`mesh_edge_active` is the criterion): they do not suppress convex
  ridges or real borders.
- Meshes and heightfields are freed when no shape references them; exhausting their slots returns a
  null handle and adds `geometry_capacity_exhausted`. `mesh_geometry` and `heightfield_geometry`
  lend the geometry, read-only, until it is freed.

### Filters

- `Filter{layers,block,overlap,group}`: the shape belongs to `layers` and blocks the categories of
  `block`, only detects those of `overlap` and ignores the rest. A pair takes the weaker response of
  the two (`Ignore` < `Overlap` < `Block`, `filter_response`).
- Shapes of the same non-null `group` (for the engine, an entity) never meet.
- A pair that overlaps is an `Overlap` contact: without manifold, without response and without
  waking the other body. A bullet that crosses it inside the step reports it anyway
  ([bullets](#bullets)).
- `shape_set_filter` discards the contacts of the shape; they meet again in the next step.
- Combined friction: geometric mean. Restitution and rolling resistance: maximum.

### Contact rules

They live in `Shape_Desc`, in `Shape` and in the flags of `Contact` (inside the snapshot).
`shape_set_surface` changes them without rebuilding the shape or its contacts.

- `surface_speed` (shape frame): how its surface moves under what it carries. Friction brings the
  relative velocity of the surfaces to zero: a belt drags what rests on it up to its velocity. The
  ground of a [character](character.md#ground-probe) adds it.
- `one_way`: the shape blocks only what arrives from the side of its local +Y.
  - A contact that starts with the normal too inclined with respect to that side (`ONE_WAY_COS`) or
    deeper than the bodies approached in the last step is left as `Pass`: without manifold,
    response or events while they keep touching. Turning it off returns those pairs to the solver.
  - A bullet that comes from behind or already passes through it does not stop; queries see it like
    any shape.
- `dominance`: between two dynamics, the body with more dominance counts as infinite mass: it pushes
  the other and is not braked by it. Against statics and kinematics nothing changes.
- `rolling_resistance` (the coefficient times the radius): in the relaxation, an angular impulse
  against the relative spin bounded by the resistance times the normal impulse, with warm start. It
  stops a rolling ball and holds it on a slope of `atan(resistance/radius)`; with the rotation axes
  locked it has no effect.

Push rules, of the world and not of a shape:

- `world_set_push_rules` replaces the world's `Push_Rule{a,b,force}`; it rejects, without changing
  anything, a rule without layers on one side or with a force that is not positive and finite.
- A contact between two dynamics whose shapes belong one to `a` and the other to `b` bounds its
  normal impulse in each substep to `force × h`, distributed among its points; with several rules
  the smallest applies. The bodies pass through each other pushing and, when they stop pushing, the
  same contact separates them.
- Without a rule the contact is rigid; against statics and kinematics it is never bounded. They live
  in `World_State`: they enter the snapshot and `world_hash`.

### Twins and cuts

They take part of a shape out of the world and put a body in two places, as an opening that leads
elsewhere requires (`twin.odin`). They live in `World_State`: they enter the snapshot and
`world_hash`.

- `world_set_cuts` replaces the cuts (`Cut{body,shape,region}`, up to `CUT_CAPACITY`). Inside the
  oriented box `region` the shape, or without it each shape of the body except the copies of its
  twin, is not there: its contact points there do not count, and rays, sweeps and `closest_shape` do
  not touch it there; overlaps do. The same cuts change nothing; others wake the bodies they name.
- `body_set_twin(body,through,point,normal)` gives a non-static body a twin (up to
  `TWIN_CAPACITY`): copies of its shapes where `through` takes it, which collide only in front of
  the plane. They follow their shapes (filter, surface, size; they are made and go away with them)
  and do not count for mass, CCD or fluids. `body_clear_twin` removes it, and so does destroying the
  body or making it static; the same values change nothing.
- A contact of a copy is solved in the frame of its body: its manifold is there, as if what it
  touched were on this side, and the impulse returns to the body. The other side feels it where the
  copy is: if it moves, its velocity turns at the contact, which is solved loose, in order; against
  static it does not change color. Contact and hit events give point and normal in the world, where
  the copy touched, and queries hit the copies as they do the body.
- A [bullet](#bullets) does not sweep against the copies or against a shape whose cut touches its
  sweep: contacts decide there.

## Step

`world_step` runs: movement of [characters](character.md), new pairs (broad phase), narrow phase,
awake bodies, character constraints, colors and island unions, preparation, substeps, restitution,
impulse storage, final poses, bullets, tree, ground of the characters, events, broken joints, sleep
and hits of shapes with `hits`. [Destruction](destruction.md) reads them after the step, never
inside.

- **Broad phase.** Two dynamic AABB trees (static and moving) with fattened boxes; only shapes
  created or that left their box look for pairs.
  - The existence of a pair is checked in the contact list of the body with fewer contacts; there is
    no hash table.
  - Workers take room for batches of pairs in a buffer of `contact_capacity`. If it is not enough,
    the broad phase runs again on the calling thread and what does not fit waits for the next step:
    which pairs are created does not depend on the workers.
  - A contact is destroyed when the fattened boxes stop overlapping.
- **Narrow phase.** One routine per unordered pair of types: closed forms between spheres,
  capsules and cylinder-sphere; 15-axis SAT for box-box; SAT with Gauss map pruning and axis cache
  for hulls and box-hull; GJK (plus SAT when the core penetrates) for sphere and capsule against
  hull. Faces are clipped and the manifold is reduced to `MANIFOLD_MAX_POINTS`, halfway between the
  surfaces, with a feature id and speculative distance.
  - Rounded box and hull run the SAT between cores and inflate the manifold; if their points end up
    farther than their separation (corners or parallel edges as the closest thing), GJK gives the
    normal of the rounding.
  - Cylinder against capsule, box, hull, cylinder and triangle (`collide_convex`): GJK between cores
    with the cylinder shrunk and inflated by `CONVEX_MARGIN`, so that a shallow contact does not
    need EPA, and points from clipping the support faces along the normal. Resting on a face that
    holds its lowest points, it takes that face without GJK; against a triangle, GJK sees only the
    part inside its box.
- **Axis cache** (`Contact.sat`): the axis of the last full search, reused if the hulls are still
  separated by it or if the face is still supported within `LINEAR_SLOP` of the depth of that
  search. The depth is not updated on a hit: a slow drift ends in another search.
- **Meshes.** Each triangle is a two-face hull, against which a rounded shape collides as its
  inflated core. Contacts from the back and on non-colliding edges are discarded; points are grouped
  by normal into several manifolds per contact (the extras in a `Manifold_Block`).
- **Warm starting.** Impulses are inherited by feature id or, if it changed, by position on shape A
  (`MATCH_DISTANCE`).
- **Solver (soft step).** Per substep: integrates velocities (with an implicit gyroscopic term),
  applies warm start, solves with bias, integrates positions and relaxes without bias.
  - Contacts are soft springs, stiffer against statics, with limited correction velocity. Raising
    `contact_hertz` destabilizes the pyramid and the character; the cap is a quarter of the substep
    frequency.
  - Friction is a 2D impulse at the center of pressure plus torsion, in the relaxation. Restitution
    is applied at the end to the points that arrived fast. A body that leaves a deep overlap stops
    at its resting place without bouncing.
- **Colors and lanes.** Each step joints and manifolds are colored (`GRAPH_COLORS`). Those that
  touch statics use the last colors and are solved at the end; those that find no color, serially
  and in order before the colors. `Contact_Block(N)` and `Joint_Block(N)` are SoA blocks of N lanes
  with `core:simd`: those of one color go four at a time, those without color in blocks of one lane
  by the same code, without copies, and an empty lane gives null impulses. `SixDOF` and the angular
  drives of `Spherical` go to the scalar solver (`joint_solve`) before the lanes of their color.
- **Islands and sleep.** Islands (`island.odin`) persist and are snapshot state.
  - A touching contact or a joint between two awake dynamics joins their islands at once (the
    smaller enters the larger). A kinematic is an island of its own, a static has none and a
    character joins none.
  - A constraint that goes away only adds to `Island.removed`, and the island splits before
    sleeping: the candidates at once and, of the others, the one of the stillest body each step, so
    that what rests sleeps apart from what moves.
  - An island sleeps when all its bodies have been under their threshold for `TIME_TO_SLEEP`, and
    wakes whole: when an awake dynamic or a moving kinematic touches it, when neighboring joints,
    shapes or bodies change and through the functions that apply forces or velocities.
  - `body_rest` leaves a dynamic asleep in a pose, only in a new island and without waking what it
    touches (a rest pose known by another route, such as a server's state).
  - `bodies_group` groups with union-find the awake bodies joined by touching contacts and joints:
    what a push on one could reach. `body_group` gives it until the next step; 0 if the body was not
    awake.
- **Internal flags.** `Character`: the capsule of a character, whose speculative contacts and box
  extend by what it travels in a step. `Debris`: a debris piece, which only forms pairs with
  statics, emits no events and queries skip.

### Bullets

An awake dynamic with `bullet` looks for its impacts inside the step (`ccd.odin`).

- Only what moved is swept: the awake ones enter with their swept box in a scratch tree; sleeping
  and static ones are met in the world trees. It uses the relative trajectory and the rotation of
  both bodies, also against other bullets.
- The step is resolved in passes (at most `CCD_MAX_IMPACTS`): each looks in parallel for the first
  impact of the active bullets in what remains of the step, and they are accepted in order of time
  and slot.
  - A bullet stopped by a static sweeps in the next pass the rest of the step from the impact pose
    with the velocity of its response: it bounces between two walls or runs down a corridor without
    losing time.
  - After an impact against a moving body, or if the bullet is joined by joints to another dynamic,
    it does not continue: the target and the trimmed links (the neighbors by joints, not the whole
    island) lose their remaining time, Jolt's *time stealing*.
  - An impact against the trajectory of a target that another impact stopped earlier has no
    response: the bullet searches again against where the target ended up.
- At the impact pose it responds with masses, friction and restitution from scratch (what the step
  already applied is in the velocities) and stores the sum for warm start. A contact can respond in
  several passes; two bullets that meet respond once. Response, waking of the target and event
  happen in the tick.
- If the sweep starts inside the CCD margin, it looks for the real surface: a separation or a
  previous rest does not stop it again at time zero. A bullet that resumes searches against half the
  separation it had (`CCD_RESUME_KEEP`): no impact leaves it touching what the next pass would no
  longer see.
- Meshes and heightfields are one-sided, as for their contacts ([geometry](#geometry)). Joints and
  other contacts resolve their new velocities in the next tick.

### Bullets and overlaps

The same sweep looks for the convex shapes that only overlap with the bullet and that it was not
touching at the start of the step, up to `CCD_OVERLAP_CAPACITY` per bullet and step (those that do
not fit add to `Stats.ccd_overlaps_dropped`). Those it reaches before stopping and does not keep
touching at the end emit `overlap_begin` and `overlap_end` in that step, on both sides and with
`crossed`: a trigger thinner than what the bullet travels is not lost. If it ends inside, the next
step reports the entry as usual.

## Fluids

Water is not simulated: it is an analytic volume with a queryable surface, deterministic and inside
the snapshot; the [`water`](../../mirai-world/references/water.md) plugin draws it.

- `fluid_create`, `fluid_set` and `fluid_destroy` (`Fluid_Desc`): a `Plane` (everything below the
  height of its position, an ocean), a `Box` rotated only in yaw whose top face is the surface (a
  lake, a pool), or a `Path` (a river): the samples of a curve that `fluid_create` and `fluid_set`
  copy, each with its width and its height as depth, level across, ending at its ends. Density,
  current (in the frame of the box, or of the path: -Z along it toward its end) and priority. The
  integration takes a path from `Fluid_Path`, which the plugin of its source writes (a `Spline` of
  `shapes`): physics never samples a curve itself.
  - With zero density it is a dry box: it removes the lowest-priority fluid where it is (a base
    under the sea). Flooding a room is raising the floor of its air with `fluid_set`.
  - A fluid does not overlap another one, nor a dry box another dry box; where they would, the one
    with the highest priority decides for the whole body.
  - Creating, changing or removing a fluid wakes the bodies it reached and those it reaches.
  - Fluids are a block of the snapshot. The scratch of the step is reserved with the first fluid
    (or when restoring a world that has them): a world without fluids neither has it nor pays for
    it.
- **A single surface query.** `fluid_surface_at` (private) is the only place that knows the shape of
  the surface: the height and the normal over (x, z), with the waves of the plane at the world's
  time. All readers follow it.
  - **Waves** (`Fluid_Desc.waves`, of a plane or a box): a sum of
    Gerstner waves (`fluid_waves.odin`). The time is `world_time`, the seconds the world advanced,
    which go in the snapshot: a rollback returns to the same waves. `wave_terms` gives each wave at
    a time, with the phase reduced in f64 from a nearby origin (near the world center or far, early
    or late, the same precision); `wave_point` takes a point of the still surface to where the water
    that rests there is, and `wave_surface` returns with Newton from (x, z) to that point. The
    inclination (`steepness`) is clipped so that the sum of k·A does not pass `WAVE_FOLD`: the
    surface never folds and Newton converges. The water shaders evaluate their twin in Slang on the
    same terms.
  - What the crests reach enters the box of the volume (`fluid_bounds`), and so does what the slope
    of a box raises and lowers.
  - `fluid_sample(w,point)` gives over it the height, the normal, the current and the density at the
    point: the surface over a wet point, the one below for a dry one, or the underside of the water
    (normal downward) for a point under all of it.
  - In the column of a point there can be a pool over the sea: the one that contains it decides,
    otherwise the nearest below and otherwise the nearest above. Dry boxes split the column into
    spans.
  - `fluids_overlap` lists, without allocating, the volumes that touch a box; `fluid_bounds` gives
    that of one (a plane reaches endlessly sideways and downward).
  - Whoever draws a volume reads its surface with `fluid_surface` (in the integration,
    `Fluid_Info.top` is the still surface and `desc.waves` its waves, which it evaluates with
    `wave_terms` at `fluid_time`) and whether a point is in it, without subtracting dry boxes, with
    `fluid_holds`: it does not repeat the shape or the priority rule.
  - **`Fluid_Waves`** (integration, replicated) on the entity of a `Fluid` in a `Plane` describes
    its waves: its own (amplitude, length and heading from the front of the entity) and those of the
    world's `Wind` where the volume is, a Pierson-Moskowitz sea in the waves that remain free, with
    its significant height from `wind`; `spread`, `steepness`, `speed` and `seed` are the artistic
    options. Changing the wind or the component redoes the waves of the volume. On a box it is a
    `physics.fluid_waves` problem.
- **Bodies.** In each substep, in the velocity integration, for each awake dynamic whose box swept
  by its velocity of the step touches a fluid:
  - The surface of a body in a step is the plane tangent to the waves over its center, at the start
    of the step: its waves lift it and tilt it.
  - Submerged volume and its center, exact per shape: boxes and hulls clipped by the planes of the
    surface and of the walls of a box, with dry boxes subtracted; spheres, capsules and vertical
    cylinders in closed form between horizontal planes; a tilted capsule, as spheres on its axis; a
    sphere or a cylinder that cuts a wall, as a polyhedron of the same volume.
  - Buoyancy ρ V g at the submerged center, with the body's gravity: its gravity scale also scales
    its buoyancy, and floating or sinking depends only on the densities.
  - Waterline damping: a pressure against the vertical velocity of each point of the area that cuts
    the surface, of the size that gives the vertical oscillation of a floating body
    `FLUID_DAMPING_RATIO`.
  - Drag ½ ρ Cd A |v − u| (v − u) relative to the current, with the area that the submerged part
    shows to the flow (exact for boxes and hulls; for curved shapes, that of the whole shape times
    the submerged fraction), and an angular drag of the submerged volume. Both are implicit, with
    the speed at the start of the substep: a body reaches its exact terminal velocity.
  - `Shape_Desc.drag` (Cd) is the only new parameter per shape; zero takes the measured value of the
    shape (`CD_SPHERE`...). `shape_set_drag` changes it. A zero-density shape displaces no fluid;
    meshes and heightfields neither.
  - A body that floats without touching anything does not sleep while buoyancy and weight are more
    unbalanced than its sleep threshold allows in `TIME_TO_SLEEP`: it does not freeze mid-sway.
- Characters: their body, not their capsule, in the fluid ([character](character.md#in-a-fluid)).

## Joints

`Joint_Desc` carries type, bodies and a frame per body whose X axis is the hinge, slide or twist
axis; `joint_frames` computes them from an anchor and an axis in the world. Types: `Fixed`,
`Spherical` (cone, twist and angular drives), `Revolute` and `Prismatic` (limit, motor, spring),
`Distance` (rigid, spring or tension-only rope) and `SixDOF`.

- `SixDOF` configures each linear and angular axis (`Joint_Axis`). Translation is measured in frame
  A; angular coordinates are the vector of the relative principal rotation, with branch at π, not
  Euler angles. `Spherical` admits those drives on free axes and keeps its limits. The axes are a
  block of their own of the snapshot (`World.joint_axes`) that a joint without axes does not walk.
- `joint_configuration_error` rejects before creating state, also a motor or spring incompatible
  with the type. `joint_set_axes` changes targets and budgets without erasing the warm start;
  changing motion, drive flags or limits resets the impulse of that axis. `joint_drive_pose`
  validates atomically, and `Disabled` suspends the drives keeping limits and targets.
- On exceeding `break_force` or `break_torque` the joint is destroyed at the end of the step with a
  `Joint_Break_Event`.
- Limits are rigid velocity constraints; only the correction of a violation is soft. A motor of any
  force stops at the limit.

## GJK

`gjk.odin`: distance, linear cast, penetration (EPA) and time of impact between two
`Proxy{points,radius,disc}`, the hull of the points swept by a disc in the local XZ plane (a
cylinder if the points are on Y) and inflated by `radius`. The support of the disc is continuous:
the simplex and the polytope keep their points and duplicates are compared by position.
`shape_proxy` gives the core and the radius of each convex shape; `query_proxy`, that of a query
geometry.

## Snapshot and determinism

- The state is the arrays of `state_arrays` (bodies, shapes, contacts, joints and their axes,
  islands, manifold blocks, characters, fluids, breakables, pieces, bonds), the two trees and
  `World_State`, which also stores gravity, the push rules, twins and cuts. A new state array is
  added to `state_arrays`, with its counter in `World_State`. `world_hash` hashes that state.
- `world_state_copy(&dst,&src)` makes `dst` what `src` is; stepping both repeats the same steps bit
  for bit. A snapshot is a world kept with `world_kept_init` (pools sized to what `src` uses, never
  stepped) that takes a copy and gives it back. It returns the bytes written.
- Each pool keeps a stamp per chunk of 64 slots: whoever writes a slot stamps its chunk (`stamp`,
  the `*_get` accessors; `*_read` only reads). Two worlds of one timeline, a kept world and the one
  it mirrors, copy only the chunks whose stamps differ; any other pair copies everything. A step
  where nothing moved writes nothing, so its copy writes nothing.
- A world put back keeps the hulls its piece slots own (newer geometry that a repeated cut rebuilds
  under the same handle); slots used after its copy go back to zero, so generations repeat.
- `dst` fails unchanged on other capacities, trees that do not fit, a world never made and, unless
  it is a kept world, shapes that name hulls, meshes or heightfields it does not have alive or a
  hull rebuilt since the copy (`hull_rebuild` and `hull_set_mass` change the revision of the slot,
  which a kept world records).
- Outside the state: the shared geometry, the events, the geometry of the manifolds, recomputed in
  the next step, and the [static change log](#static-collision), which a copy that wrote anything
  restarts for all its readers.
- The result does not change with the number of workers.

## Queries

Without allocation, on caller buffers, with a `Query_Filter`.

- By channel (`objects` at zero) the query is one more shape of `filter`: each shape meets it with
  the weaker response of the two. By object type (`objects` non-null) it sees the shapes of those
  categories without looking at their responses, and all of them block it. Those of the same `group`
  are ignored.
- What only overlaps is reported if `overlaps` asks for it; debris, if `debris` asks for it.
  `QUERY_FILTER_DEFAULT` is the channel of category 0 blocking all.
- `ray_cast_closest` and `ray_cast_any` see only what blocks. `ray_cast_all` sorts by distance: by
  channel it ends at the first impact that blocks, with what only overlaps before it; by object type
  it returns all. With more impacts than capacity it keeps the nearest ones.
- `shape_cast_*` follow the same rules for a convex shape that translates without rotating; a hull
  keeps its convex radius. A ray against a rounded shape is the cast of a point against its inflated
  core, exact on the edges.
- `overlap_shape` and `overlap_aabb` report what blocks and, if asked, what overlaps; `closest_*`,
  only what blocks. A query that starts inside a shape returns fraction 0 and null normal.

### Static collision

What whoever builds from the level needs, like the navmesh, without allocating.

- `shapes_triangles(w,box,vertices,indices,filter,shapes) -> (vertices,indices,complete)` writes in
  world space the triangles of the shapes of static bodies whose box touches `box` and that block
  the filter: what a query with it would block, never a sensor (a shape that blocks no category) nor
  one that only overlaps.
  - Three indices per triangle in `vertices`, counterclockwise seen from outside, or from the side
    a mesh or a heightfield collides with. `shapes`, if not empty, receives the shape of each
    triangle and limits how many fit.
  - Boxes and hulls give their faces as a fan, with their size and without the rounding of the
    convex radius.
  - Spheres, capsules and cylinders are tessellated with `TRIANGLE_SEGMENTS` segments around the
    axis and `TRIANGLE_BANDS` bands per quarter turn of each cap: the vertices are on the surface
    and the facets stay inside by at most `radius × (1 − cos(π/TRIANGLE_SEGMENTS))`. The caps and
    flat sides are exact.
  - From a mesh, the triangles whose box touches `box`; from a heightfield, the cells whose box
    touches it, without the holes and split by the diagonal of the model.
  - The pose is that of the body times the local transform of the shape. The model has no scale: it
    is in the geometry of the shape.
  - A convex shape enters whole; the triangles of a mesh and the cells of a heightfield, one at a
    time. `complete` is false when the next one did not fit, and what was written stays. An invalid
    box gives nothing.
  - It only reads the world: several threads can call it at once while nobody changes it.
- **Change log.** A ring of `World_Desc.static_change_capacity` world boxes, with a counter that
  only grows, notes where static collision changed:
  - a shape created or destroyed on a static body, or a static shape whose filter changes
    (`shape_set_filter` with another filter): the box of the shape;
  - a static body moved (`body_set_transform`: where it was and where it ended up), destroyed, or
    that becomes static or stops being so (`body_set_type`): the box of all its shapes.

  It notes every static shape, also sensors; the step notes nothing, because it does not move
  statics.
- `static_changes(w,since,out) -> (next,count,overflow)` copies into `out` what was noted since the
  cursor `since`, from oldest to newest, and gives the cursor of the next read. Each reader keeps
  its own, zero at the start; a read that fills `out` leaves the rest for the next one.
  - `overflow`, without writing anything and with `next` at the newest: the reader fell behind more
    than the ring, its cursor is not from this log, or since then a state copy wrote into the world
    (`world_state_copy`). The reader takes everything as changed.
  - It is scratch: it is not in the state copy or in `world_hash` and the simulation does not read
    it, so it changes no result.

## Events and diagnostics

- `world_events` returns slices valid until the next step; `overlap_begin`/`overlap_end` go one per
  side, with `crossed` when a bullet crossed it in the step. Destroying shapes or bodies outside the
  step emits no end events. A contact or overlap event carries in `users` the user data of its
  bodies and shapes, which may be gone when it is read; `breaks` lists
  [what broke](destruction.md#reading-and-replay).
- `body_contacts` lists the contacts of an awake body, with the normal impulse of each point and the
  velocity with which they approached before solving it (`approach`). `world_stats` gives counts and
  exhausted capacities; `world_profile`, the time per stage.

## Parallelism

`World_Desc.parallel_for` and `worker_count`; with a null `parallel_for` everything runs on the
calling thread, and `parallel_user` stays in `context.user_ptr` during the call. Small stages run
inline. What a parallel stage does not distribute without depending on the workers (pairs that do
not fit, uncolored constraints, shared consequences) runs on the calling thread, in order.

## `std/spatial`

- Boxes are `math.Aabb` of `std/math`; `std/spatial` adds area, center, rays and sweeps.
- `Dynamic_Tree`: AABB tree with insertion by area cost and rotations, and iterators without
  allocation. A proxy that is not a live leaf of the tree is ignored: reads give zero and changes do
  nothing. Its nodes carry stamps by chunk (`std/base` `chunk_stamp`), and `dynamic_tree_copy`
  takes the chunks whose stamps differ.
- `Bvh`: static SAH BVH with bins and flat nodes; its queries deliver one leaf per call.

## Debug draw

- `world_debug_draw(&w,&out,flags,region,layers)` writes into the `Debug_Draw{lines,points}` buffers
  what `flags` asks for (`Shapes`, `Bounds`, `Contacts`, `Joints`, `Centers`, `Fluids`) for what
  `region` touches (box at zero: the whole world). `Shapes` and `Bounds` are those of the shapes of
  any of the categories of `layers` (`Filter.layers`; all by default). It does not allocate or
  depend on the renderer; the editor's Collision mode draws it.
- `Debug_Line{a,b,kind}` carries a `Debug_Kind` from which whoever draws takes the color: static,
  kinematic, dynamic awake or asleep, trigger (a shape that blocks no category), character, debris,
  box, joint, center, fluid, dry box.
- `Fluids`: the edges of fluid and dry boxes, and a grid over the surface of a plane in the region
  (without region, around its position), in spans that follow its height.
- Shapes: edges of boxes, hulls and meshes, three circles of a sphere, the outline of a capsule, the
  two caps and four generatrices of a cylinder and the grid of a heightfield (meshes and
  heightfields only in the region). Rounded shapes are drawn with their size, without rounding.
- `Debug_Point` gives position, normal from A to B, separation and impulse of each point of a
  touching contact.
- What does not fit is counted in `lines_dropped` and `points_dropped`.
- `shape_debug_draw(&w,handle,&out,region) -> bool` draws a single shape in its world pose, resets
  the counters and returns `false` with an invalid or stale handle. With region at zero, a mesh
  stops walking triangles when the buffer fills and counts the remaining lines; a hull does the
  same with its edges.

## Known limits

- Soft contacts yield under an uneven load: a tilted tower of boxes falls before its static limit.
- No simplex cache (GJK) or axis cache for box-box. A proxy with a disc starts GJK cold and its time
  of impact uses only the normal axis.
- A cylinder that collides edge against a sharp edge sees it rounded by `CONVEX_MARGIN`. Among many
  triangles or in disordered piles it costs several times what a sphere does.
- No vehicles or dedicated wheel joint: bodies, joints and queries allow building them from
  gameplay, but they do not include tires or transmission.
- No deformable bodies, cloth or simulated fluids: water is an analytic volume ([fluids](#fluids))
  with a flat surface, without waves. A chain of bodies or a rope with `Distance` is still a rigid
  body system.
- Meshes and heightfields do not collide with each other and contribute no mass.
- Debug draw does not draw the copies of a [twin](#twins-and-cuts), and the points of their contacts
  stay in the body frame. Between the copies of two twins, the contact is solved in the body frame
  of shape A.
