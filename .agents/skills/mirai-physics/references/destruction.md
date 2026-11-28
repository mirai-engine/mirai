# Breakable bodies: current behavior

The solver (`breakable*.odin` in `plugins/physics/runtime/sim`) implements breakable bodies: convex
pieces, the bonds that hold them and cluster levels. A breakable, its pieces and its bonds are
pools of the `World`, and each piece is a shape of a body, with a hull of its own and the label of
its slot. Other plugins reach them through the facade of the integration (`physics.breakable_*`,
`plugins/physics/runtime/breakables.odin`), which has the names and the rules of the solver; the
[`destruct` plugin](engine-destruct.md) connects them with entities, materials, requests, queries
and networking. There is no load, bending or structural stress solver.

## With the world

- The pools are made with the first breakable, with `World_Desc.breakable_capacity`,
  `piece_capacity` and `bond_capacity`: a world that breaks nothing holds none. They are state:
  `world_state_copy` and `world_hash` take them with the bodies, and a kept world holds what its
  source uses of them. An operation on a breakable stamps the slots of all its pieces and bonds.
- `world_step` ends with the breakables: it reads the hits of the step (`world_events(w).hit`,
  from shapes with `hits`), applies impact damage, removes debris and expired groups and lists what
  it did in `world_events(w).breaks`. A break happens in the step of its hit.
- A break may end a shape or a body that an event of the same step names: the contact and overlap
  events carry the user data their bodies and shapes had when they were raised (`Event_Users`).
- Piece shapes are created and destroyed without recomputing mass; at the end of each change
  `body_mass_update` recomputes it once per body, keeping the velocity of the material.
- A piece slot rebuilds its hull under the same handle (`hull_rebuild`) so that repeating a cut
  after a restore gives the same state. The hull and the origin of each slot are geometry, outside
  the snapshot: a restore keeps them, and `world_state_copy` takes them from its source, whose
  hulls the destination already holds.

## Construction

`breakable_create(w,desc)` is a transaction that allocates and returns a handle and a
`Breakable_Error`. It accepts a closed mesh and Voronoi sites, or a `^geom.Fracture` with
geometry and graph already prepared; the
[.fracture asset](../../mirai-assets/references/kinds.md#fracture) stores pieces, connections,
anchors and hierarchy before loading a scene. The fields of `Breakable_Desc` are commented in
`breakable.odin`:

- Density, friction, restitution, gravity and filter are kept by the detached bodies;
  `breakable_set_filter` changes the filter of all pieces without rebuilding them.
- A positive `bond_strength` replaces the general one in its bond.
  `impact_damage=false` keeps collisions and explicit damage.
- `anchors` (local boxes) and `piece_anchors` (a mark per piece) add up. Without anchors the initial
  body is dynamic; with anchors, static, or kinematic with `kinematic`, which keeps the anchored
  groups and detaches the others as dynamic.
- `piece_clusters` and `clusters`: parents precede their children, `-1` means no parent and each
  cluster has descendants. A cluster names in `cluster_points` (at least four, breakable frame)
  the points of its hull; without points, that of its pieces is used.
- `passive_removal` keeps the dates of non-cosmetic groups, but only a `Remove` event removes them:
  it is the policy of clients.
- `user_data` is the authoring identity of the breakable; each body has its own, modifiable.

Topology:

- Each piece occupies a slot, a hull and, outside a whole cluster, a shape; a hull without volume is
  discarded. Creation asks for a shape for each piece even if whole clusters use a single one.
- Each cluster with a hull occupies a piece slot and one more hull (`piece_capacity` counts them). A
  hull that does not contain the center of mass of its pieces is omitted and the cluster collides
  as its pieces.
- Bonds come from shared Voronoi faces or from an explicit graph, even with separated pieces.
- A failure leaves no live bodies, shapes, pieces or bonds.
- A removed piece (the original of a cut, an expired debris, a removed group) keeps its slot, its
  hull and its place in the list until the breakable is destroyed: the state without geometry
  and the network events name pieces by that place and redo a half by cutting its mother.
- `breakable_destroy` removes all bodies; `breakable_find(w,user_data)` is useful for cleaning
  up when the component has already disappeared.

## Cluster hierarchy

- Clusters occupy tagged records of the bond pool (`bond_capacity` counts both). Leaves
  store their direct cluster; a normal bond belongs to the common ancestor of its ends.
- Only a root or a cluster whose parent already broke receives damage; they are traversed from the
  children toward the parents, so breaking the parent does not also damage the children in that hit.
  On reaching its absolute threshold it releases the bonds of its level and the graph
  regroups: the root becomes cluster bodies and, with later hits, leaf bodies. Weaken accumulates
  strain without releasing.
- A cluster is whole while it has not broken and all its pieces remain in one body. The highest
  whole one collides with a single shape: its hull, with the volume, center of mass and inertia of
  its pieces, so the body's mass does not change when it breaks. Once broken, its whole children or
  the pieces replace it.
- The shape of a cluster names one of its pieces, the one an impact names in its event;
  `Piece_Info.shape` is the shape the piece collides with.
- There are no stresses between clusters. A cut breaks all clusters of the breakable, and their
  pieces go back to their shapes before being cut.

## Damage and fields

- `break_apply(w,event)` is the one door for what is asked of a breakable: a `Damage` strains and
  launches what comes off with its impulse, a `Weaken` adds strain without breaking, on every body
  (`piece=-1`) or on the body of one piece. Strain and impulse are independent.
- The `Break_Region` of a `Damage` or `Weaken` is a sphere or an oriented box that weighs as a
  [`Volume`](../../mirai-gameplay/references/libraries.md#volume) does: 1 inside, rising from the
  border over `blend` meters. It is in the event so that another end repeats it; damage evaluates
  it at the centers of bonds and of cluster pieces. An `Impact` has no region: it strains the
  bonds of the piece it hit by their area, or the cluster that piece is whole in. A body that
  touches several pieces raises a hit on each, so the contacts are the size of the impact.
- `breakables_strain` gives a region to every breakable a `Query_Filter` meets, body by body except
  debris and `ignore_body`, and lists the event of each body it reached with those of the step.
  The integration applies there what `physics.strain_area` asked, once the step of the tick ran.
- Each bond accumulates strain up to `strength * area`, saturating at the largest f32.
- A crack runs along the bond graph: in the same event, the strain a bond that breaks holds
  beyond its threshold, times `propagation`, goes to the unbroken bonds of its two pieces by their
  area, in waves until none breaks. 1, the default, is a brittle material that keeps the strain it
  is given; a material that should not crack through gives less as data. It is a function of the
  event and the state, so a replayed event cracks alike: `propagation` is authored on both ends
  and nothing more travels.
- With `impact_damage`, per contact only the points that approached fast and accumulated at least
  `damage_threshold` of normal impulse do damage: they are parameters of the breakage model, not
  energy. A resting load does not break by its weight; debris receives no damage.
- After breaking, the connected groups are traversed per body:
  - In anchored bodies the groups with anchors remain; without anchors, the one with the greatest
    volume. The others receive dynamic bodies with inherited pose, velocity and surface.
  - The explicit impulse is distributed by volume and spatial weight among what is detached. A
    contact impact gives it to the group of the piece it hit, and only when detaching from static:
    the solver already hit the dynamic.
  - If bodies are missing, it keeps the broken bonds and retries detaching in a later event.
- `Strain_Field` on an entity with a box or sphere
  [`Volume`](../../mirai-gameplay/references/libraries.md#volume) is persistent strain
  (`strain_fields_step`): each tick it asks `physics.strain_area` for its strain in that volume,
  rising over its own `blend`. A client asks for none; another shape is the
  `destruct.strain_field` problem, since the region of a break travels as a box or a sphere.

## Removal

- Debris collides only with statics and with what both block: it does not push characters or
  dynamics, does not overlap with anything and emits no contacts, sleep or waking. Queries omit it
  except with `Query_Filter.debris`. Its expiration is local to each world.
- A detached non-cosmetic group keeps its expiration date and can be removed when it falls asleep;
  the initial group cannot. The step only reviews broken breakables.
- Removal emits `Remove` with a representative piece and is replayed in another world. Passive
  clients do not remove non-cosmetic groups by themselves and follow the server.
- The state for late join keeps the remaining ticks of life and distinguishes unlimited life.
- A `Remove` event asked of `break_apply` removes only the detached body of its piece; the
  initial group, removed pieces and stale handles are refused.
- `breakable_body_remaining_ticks` gives the ticks until the first expiration of the pieces of a
  body and `expires`: zero with `expires=true` is a reached date; `expires=false`, unlimited life or
  no date.

## Cut

- A `Slice` event cuts by the plane through its point, whose normal is its vector, and allocates.
  - A crossed piece receives two hulls and leaves its original `Gone`; the sides regroup without
    impulse. Bonds between sides break and the others pass to the corresponding half.
  - It needs two slots and two hulls per cut piece, and shapes for the pieces of whole clusters; if
    they are not enough, it does not cut.
  - A half without volume keeps the whole piece on the side of its center. Anchor boxes are
    evaluated on the new hulls.
- A cut deactivates the cluster hierarchy of the breakable and continues with its piece graph.
- Physics cuts the convex hull; the renderer cuts the geometry with its interior material. In a
  non-convex piece the two surfaces can differ.
- Halves inherit group and expiration date; the one retained in an already detached body keeps its
  remaining life, and those that detach to a new body take the policy of that group. A cut by itself
  does not remove live volume or expire the retained group.

## Reading and replay

`breakable_pieces` and the other reads (`bonds`, `clusters`) return the total and write up
to the capacity of `out`. Pieces include the removed ones and the originals of a cut, in order:
original fracture and then halves, front first. `id` is a local slot; the ordinal in the list and
`group` (zero for the initial body, and the revision that created each detached group) coincide
between worlds that applied the same events. Positions and planes of `Piece_Info` are in the local
frame of the body.

- `breakable_check` summarizes group and flags of pieces and breakage of bonds and
  clusters, without poses, strain or cosmetic expiration.
- `breakable_shortfall` says, since the last step began, the events that did not fit and the
  capacities that denied what a breakage or a cut needed.
- `breakable_of(w,body)` gives the breakable a body is of and one of its pieces on it.

Events:

- A `Break_Event` with `piece=-1` reaches the whole breakable; `break_apply` returns it with its
  tick, and repeats it in an equivalent world. `world_events(w).breaks` gathers the impacts and
  removals of the last step and the regions of `breakables_strain` since.
- The hits and the break events of a step share `event_capacity`. A break event that does not fit
  was applied and is not listed: it counts in `breakable_shortfall` and in `Stats`. A hit that does
  not fit does no damage and counts with the events of the solver.

State without geometry (`breakable_state_size/write/apply`):

- It includes cuts, group, flags, cluster and remaining life of each piece, and area, strain,
  strength and parent of bonds and clusters. Debris is written as removed, since it is of each
  world, unless `debris` asks for it, as a recording of the same world does.
- The receiver creates the same source, with the same clusters and their hulls. Applying the state
  works in place, broken or not: the cuts both share stay, the others are undone and the missing
  ones repeated; the body of a group both have stays with its pose and velocity, bodies of groups
  the state lacks go, and a new group starts in the frame of the breakable at rest. The writer
  supplies the poses afterwards. Only repeating a cut allocates.
- `breakable_state_version` changes with every change of what it writes except passing time
  (strain, breakage, cut, removal, expiry, an applied state): a recording writes the state again
  only when it changes.
- A failure can leave the destination partially changed and requires destroying it.

Poses and playback (`breakable_poses/poses_apply/poses_blend`):

- `Breakable_Pose` is the pose, velocities and `remaining` steps of one body, named by its
  `group`. `breakable_poses` lists every body, the one it was created as first.
- `breakable_poses_apply` places each body by group (a static one stays) and sets the remaining
  life of a group that expires (`max` leaves it as it is); a body without a pose stays as it is.
  Hand-made poses start from `breakable_poses`: a zero `remaining` expires the group at once.
- `hold` keeps it held until a call without it: each body that is not static, and those it makes
  meanwhile, takes one `body_hold` (kinematic at rest), takes no hits and does not expire, so the
  next poses move them. Let go, each has its own type again with the velocities of the poses,
  unless another hold (a section, a manipulation) still keeps it kinematic. The hold travels in
  copies of the state.
- `breakable_poses_blend` gives the poses between two lists at `t` by group (slerp, `remaining`
  interpolated): a recording kept at a lower rate plays back at every step.
- A playback of a recording applies each state where it changed and the poses of every step,
  held, and lets go with the last poses. Going back does not allocate; going forward through a
  cut repeats it.

Copy and memory:

- The hull slot of a cluster is a `Piece` outside the list, named by its cluster record. Hulls are
  geometry of the world, not state: a snapshot is valid while the slot is not reused with other
  geometry.
- Construction, cutting and repeating a cut of an applied state allocate. Damage, fields,
  hierarchy, regrouping, removal, poses and the rest of applying a state use reserved scratch.
- The [portable cache](../../mirai-plugins/references/physics-cache.md) stores geometry and poses,
  allows reverse playback without resimulating and does not depend on those slots.

## Known limits

- A long-lived breakable runs out of slots or hulls (removed pieces keep theirs): the cut or
  breakage that does not fit does not happen and `breakable_shortfall` reports it.
- A whole cluster fills the gaps and concavities between its pieces.
- The areas and centers moved by a cut are approximate.
- Scaling a `.fracture` unevenly multiplies the areas by the largest product of two axes
  (bonds do not store a normal); negative scales are taken in absolute value.
- Pieces can get jammed between immobile neighbors.
- A request to several bodies distributes the complete impulse within each one.
- No load transfer, plastic deformation, cloth, soft volume or stress-based fracture; fields and
  clusters do not provide them.
