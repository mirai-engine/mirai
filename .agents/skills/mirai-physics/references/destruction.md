# Destruction: current behavior

The `plugins/destruct/runtime/fracture` package implements convex pieces, connections and cluster
levels on the public API of the solver: a `Fracture` holds destructibles, pieces and connections,
and each piece is a shape of a body of the `sim.World`, with a hull of its own and the label of its
slot. The [public API](engine-destruct.md) connects them with entities, materials, requests,
queries and networking. There is no load, bending or structural stress solver.

## With the world

- Each call receives the `Fracture` and the `sim.World` that it fractures; the `Fracture` keeps no
  pointers to the world and is copied separately (`fracture_copy`), always together with it.
- `fracture_update(f,w)` runs once after each `world_step`: it reads the hits of the step
  (`world_events(w).hit`, from shapes with `hits`), applies impact damage, removes debris and
  expired groups and leaves its events in `fracture_events(f)`.
- Piece shapes are created and destroyed without recomputing mass; at the end of each change
  `body_mass_update` recomputes it once per body, keeping the velocity of the material.
- A piece slot rebuilds its hull under the same handle (`hull_rebuild`) so that repeating a cut
  after a copy gives the same state. `fracture_copy` with `geometry` also takes the hulls of the
  slots (the destination world took those of the source); without it, when restoring the same
  world, it keeps them.

## Construction

`destructible_create(f,w,desc)` is a transaction that allocates and returns a handle and a
`Destructible_Error`. It accepts a closed mesh and Voronoi sites, or a `^geom.Fracture` with
geometry and graph already prepared; the
[.fracture asset](../../mirai-assets/references/kinds.md#fracture) stores pieces, connections,
anchors and hierarchy before loading a scene. The fields of `Destructible_Desc` are commented in
`fracture.odin`:

- Density, friction, restitution, gravity and filter are kept by the detached bodies;
  `destructible_set_filter` changes the filter of all pieces without rebuilding them.
- A positive `connection_strength` replaces the general one in its connection.
  `impact_damage=false` keeps collisions and explicit damage.
- `anchors` (local boxes) and `piece_anchors` (a mark per piece) add up. Without anchors the initial
  body is dynamic; with anchors, static, or kinematic with `kinematic`, which keeps the anchored
  groups and detaches the others as dynamic.
- `piece_clusters` and `clusters`: parents precede their children, `-1` means no parent and each
  cluster has descendants. A cluster names in `cluster_points` (at least four, destructible frame)
  the points of its hull; without points, that of its pieces is used.
- `passive_removal` keeps the dates of non-cosmetic groups, but only a `Remove` event removes them:
  it is the policy of clients.
- `user_data` is the authoring identity of the destructible; each body has its own, modifiable.

Topology:

- Each piece occupies a slot, a hull and, outside a whole cluster, a shape; a hull without volume is
  discarded. Creation asks for a shape for each piece even if whole clusters use a single one.
- Each cluster with a hull occupies a piece slot and one more hull (`Desc.pieces` counts them). A
  hull that does not contain the center of mass of its pieces is omitted and the cluster collides
  as its pieces.
- Connections come from shared Voronoi faces or from an explicit graph, even with separated pieces.
- A failure leaves no live bodies, shapes, pieces or connections.
- A removed piece (the original of a cut, an expired debris, a removed group) keeps its slot, its
  hull and its place in the list until the destructible is destroyed: the state without geometry
  and the network events name pieces by that place and redo a half by cutting its mother.
- `destructible_destroy` removes all bodies; `destructible_find(f,user_data)` is useful for cleaning
  up when the component has already disappeared.

## Cluster hierarchy

- Clusters occupy tagged records of the connection pool (`connection_capacity` counts both). Leaves
  store their direct cluster; a normal connection belongs to the common ancestor of its ends.
- Only a root or a cluster whose parent already broke receives damage; they are traversed from the
  children toward the parents, so breaking the parent does not also damage the children in that hit.
  On reaching its absolute threshold it releases the connections of its level and the graph
  regroups: the root becomes cluster bodies and, with later hits, leaf bodies. Weaken accumulates
  strain without releasing.
- A cluster is whole while it has not broken and all its pieces remain in one body. The highest
  whole one collides with a single shape: its hull, with the volume, center of mass and inertia of
  its pieces, so the body's mass does not change when it breaks. Once broken, its whole children or
  the pieces replace it.
- The shape of a cluster names one of its pieces, the one an impact names in its event;
  `Piece_Info.shape` is the shape the piece collides with.
- There are no stresses between clusters. A cut breaks all clusters of the destructible, and their
  pieces go back to their shapes before being cut.

## Damage and fields

- `destructible_damage` (the strain is the magnitude of the impulse), `destructible_strain` (breaks
  without launching) and `destructible_weaken` (adds strain without breaking or launching); the
  `_body` variants are limited to the body of a piece.
- `destructible_field_body` accepts a `Destruct_Region` (sphere or oriented box) with any
  `Radial_Falloff` curve, with the same `radial_weight` and `box_weight` as the model's forces and
  without `Weight_Range` or noise. Damage evaluates centers of connections and of cluster pieces;
  forces, centers of mass of bodies. Damage and impulse are independent.
- Each connection accumulates strain up to `strength * area`, saturating at the largest f32.
- With `impact_damage`, per contact only the points that approached fast and accumulated at least
  `damage_threshold` of normal impulse do damage: they are parameters of the breakage model, not
  energy. A resting load does not break by its weight; debris receives no damage.
- After breaking, the connected groups are traversed per body:
  - In anchored bodies the groups with anchors remain; without anchors, the one with the greatest
    volume. The others receive dynamic bodies with inherited pose, velocity and surface.
  - The explicit impulse is distributed by volume and spatial weight among what is detached. A
    contact impact distributes it only when detaching from static: the solver already hit the
    dynamic.
  - If bodies are missing, it keeps the broken connections and retries detaching in a later event.
- `Strain_Field` on an entity with a box or sphere
  [`Volume`](../../mirai-gameplay/references/libraries.md#volume) is persistent strain through the
  public API (`strain_fields_step`): each tick it asks `field_strain` of every destructible its
  filter sees, with the region of the volume, constant without blend and linear with it. A client
  asks for none; another shape is the `destruct.strain_field` problem.

## Removal

- Debris collides only with statics and with what both block: it does not push characters or
  dynamics, does not overlap with anything and emits no contacts, sleep or waking. Queries omit it
  except with `Query_Filter.debris`. Its expiration is local to each world.
- A detached non-cosmetic group keeps its expiration date and can be removed when it falls asleep;
  the initial group cannot. The step only reviews broken destructibles.
- Removal emits `Remove` with a representative piece and is replayed in another world. Passive
  clients do not remove non-cosmetic groups by themselves and follow the server.
- The state for late join keeps the remaining ticks of life and distinguishes unlimited life.
- `destructible_remove_body` returns the same `Remove` and removes only the detached body of that
  piece; it rejects the initial group, removed pieces and stale handles.
- `destructible_body_remaining_ticks` gives the ticks until the first expiration of the pieces of a
  body and `expires`: zero with `expires=true` is a reached date; `expires=false`, unlimited life or
  no date.

## Cut

- `destructible_slice` and `_body` cut by a world plane and allocate.
  - A crossed piece receives two hulls and leaves its original `Gone`; the sides regroup without
    impulse. Connections between sides break and the others pass to the corresponding half.
  - It needs two slots and two hulls per cut piece, and shapes for the pieces of whole clusters; if
    they are not enough, it does not cut.
  - A half without volume keeps the whole piece on the side of its center. Anchor boxes are
    evaluated on the new hulls.
- A cut deactivates the cluster hierarchy of the destructible and continues with its piece graph.
- Physics cuts the convex hull; the renderer cuts the geometry with its interior material. In a
  non-convex piece the two surfaces can differ.
- Halves inherit group and expiration date; the one retained in an already detached body keeps its
  remaining life, and those that detach to a new body take the policy of that group. A cut by itself
  does not remove live volume or expire the retained group.

## Reading and replay

`destructible_pieces` and the other reads (`connections`, `clusters`) return the total and write up
to the capacity of `out`. Pieces include the removed ones and the originals of a cut, in order:
original fracture and then halves, front first. `id` is a local slot; the ordinal in the list and
`group` (zero for the initial body, and the revision that created each detached group) coincide
between worlds that applied the same events. Positions and planes of `Piece_Info` are in the local
frame of the body.

- `destructible_check` summarizes group and flags of pieces and breakage of connections and
  clusters, without poses, strain or cosmetic expiration.
- `destructible_shortfall` says, since the last step began, the events that did not fit and the
  capacities that denied what a breakage or a cut needed.

Events:

- A `Fracture_Event` with `piece=-1` reaches the whole destructible; `fracture_event_apply`
  replays the operation in an equivalent world. `fracture_events(f)` gathers impacts and removals of
  the last step; explicit requests return their event.
- `event_capacity` impacts fit per step: the damage of the excess is not applied and an event that
  does not fit is not published; both count in `destructible_shortfall` and in `Stats`.

State without geometry (`destructible_state_size/write/apply`):

- It includes cuts, group, flags, cluster and remaining life of each piece, and area, strain,
  strength and parent of connections and clusters. Debris is written as removed.
- The receiver creates the same intact source, with the same clusters and their hulls. Applying the
  state repeats the cuts, rebuilds bodies at rest and restores levels; the sender supplies the poses
  afterwards.
- A failure can leave the destination partially changed and requires destroying it.

Copy and memory:

- The hull slot of a cluster is a `Piece` outside the list, named by its cluster record. Hulls live
  in the world, not in the `Fracture`: a copy is valid while the slot is not reused with other
  geometry.
- Construction, cutting and applying state allocate. Damage, fields, hierarchy, regrouping and
  removal use reserved scratch.
- The [portable cache](../../mirai-plugins/references/physics-cache.md) stores geometry and poses,
  allows reverse playback without resimulating and does not depend on those slots.

## Known limits

- A long-lived destructible runs out of slots or hulls (removed pieces keep theirs): the cut or
  breakage that does not fit does not happen and `destructible_shortfall` reports it.
- A whole cluster fills the gaps and concavities between its pieces.
- The areas and centers moved by a cut are approximate.
- Scaling a `.fracture` unevenly multiplies the areas by the largest product of two axes
  (connections do not store a normal); negative scales are taken in absolute value.
- Pieces can get jammed between immobile neighbors.
- A request to several bodies distributes the complete impulse within each one.
- No load transfer, plastic deformation, cloth, soft volume or stress-based fracture; fields and
  clusters do not provide them.
