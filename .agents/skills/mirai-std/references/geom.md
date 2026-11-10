# `std/geom`: geometry processing

A layer 1 package that imports only `core:` and `base:`. It operates on flat slices and writes into
caller buffers. It feeds `physics` (hulls, mass), destruction (slicing and fracture, at cook time
and at run time), `asset` (primitives) and the cooking of colliders and meshes (simplification and
convex decomposition). Each file explains its algorithm in its comments; this holds the contracts
they share.

## Data and memory

- `Plane{normal,d}`: a point is on the plane if `dot(normal,p)==d` and in front if it is greater
  (the sign of `d` is the opposite of that of `math.Plane`).
- `Mesh` is a view with counterclockwise triangles seen from outside and optional per-vertex
  attributes and per-triangle materials. `Mesh_Buffer` is the storage that grows: the operations
  that write a mesh clear it and reuse its memory; the primitives and `hull_append_mesh` append at
  the end. An output slice of another length is not written.
- The single-call operations use `context.temp_allocator` and release it on return with
  `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`, which inside a job also releases
  ([jobs](jobs.md#temporary-memory)). `Slicer`, `Fracture` and `Mesh_Surface_Workspace` keep their
  memory between calls: after the first ones, an operation of the same size does not allocate.
- An operation takes the memory of its caller's allocator before it writes. The tables of the
  package (`Key_Map`, `Point_Set`) grow only when they are reset for the entries they will hold,
  and the slicer, the fracture and the triangulation reserve for a bound computed from their input
  (vertices, split triangles, border edges, sites) and then fill without growing: a write without
  bounds check is inside what was reserved. A new array filled in such a loop gets its bound first.
- Without that memory the operation returns the `Out_Of_Memory` of its error (`polygon_triangulate`
  and `delaunay_triangulate` give no triangles and `polygon_convex_partition` no pieces;
  `mesh_tangents`, `mesh_weld`, `hull_append_mesh`, the built-in shapes and those of `shapes.odin`
  give false and append nothing), leaves its outputs empty and keeps nothing; its
  workspace gives, with memory again, what a new one gives. The temporary allocator is not covered:
  `positions_weld` gives 0 and `mesh_topology` an open mesh without it, and the rest assume it.

## Determinism, precision and tolerance

- **Determinism.** The same input gives byte-for-byte identical output.
  - It uses only IEEE-754 addition, subtraction, multiplication, division, square root and `floor`,
    without the platform libm (the angles of the primitives come from `turn_sincos`, a polynomial
    with exact quadrants; the icosphere uses `math.atan2`, implemented in Odin).
  - Walks have a fixed order, ties are resolved by index and no hash table is iterated. The
    fracture sites come from its own PCG32 that depends only on the seed.
  - Equality across architectures depends on the compiler not contracting `a*b+c` (Odin does not by
    default).
- **Precision.** Coordinates enter and leave as `f32`. The predicates (side of a plane,
  orientation, visibility) and the accumulations (areas, volumes) are evaluated in `f64`, where the
  product of two `f32` is exact. The meshoptimizer ports (simplifier, clusters, partitioning)
  compute in `f32` like the original, to give its same results.
- **Invalid inputs.** Out-of-range indices, streams of another length, NaN, infinities, empty or
  coincident inputs and out-of-range parameters give a named error (`Invalid_Mesh`, `Invalid_Plane`,
  `No_Sites`…) or a defined result; a triangle with an out-of-range index counts as degenerate.
- **Tolerance.** Every tolerance is an absolute distance in the units of the input.
  `tolerance_noise(max_abs)` is the minimum reliable one for coordinates of that magnitude, and each
  operation uses the larger of that floor and the one requested. A point within the tolerance of a
  plane is on it.
- **Topology by position.** Welding, topology and components identify vertices by position:
  attribute seams do not open a surface (`mesh_topology_is_closed` requires a closed 2-manifold;
  `mesh_topology_is_watertight`, only one opposite per half-edge).

## Surface editing (`surface_edit.odin`)

- `mesh_surface_edit` applies a brush (`Sculpt`, `Smooth`, `Flatten`, `Drag`) over the region and
  the complete halo that the caller delivers: it does not look for the rest of the terrain. `Drag`
  applies an explicit rotation around the center; the surface normal induces no turns.
  `lock_boundary` keeps borders and non-manifold edges.
- It keeps indices, UVs, colors and materials. It recomputes the normals of the affected ring
  grouping by position and original normal: it keeps hard seams and two regions with the same halo
  give equal normals. It does not prevent self-intersections or inversions from a large
  displacement.
- `mesh_surface_refine` is **one step of conforming subdivision**: it splits the long edges that
  cross the sphere in all the triangles that share them, also on both sides of a seam, with
  midpoints at the same exact position. It is not isotropic remeshing: it neither collapses nor
  flips, and an edge may still be long after a step.
- An output that shares memory with the input gives `Aliased_Output` without modifying it; the other
  errors leave the output empty.

## Solid booleans (`boolean.odin`)

`mesh_boolean` does union, subtraction or intersection of closed, outward-oriented triangulated
surfaces (an interior cavity has opposite orientation).

- It keeps the attribute seams and the material of each fragment; the new faces of a subtraction
  come from operand B, inverted.
- It is an authoring transaction over the whole solid: it uses temporary memory released on return,
  also with its own temporary allocator, and does not keep a tree between calls. Every error leaves
  the output empty.
- Kernel: an iterative BSP of convex polygons, with intersections, classification and attributes in
  `f64`. The tree of A only classifies what B keeps: the polygons of A that come out are its own,
  cut only by the planes of B, so the planes of a surface that is not flat (a sculpted terrain) do
  not splinter it far from B. Before triangulating it welds positions with fixed representatives,
  closes T-junctions and cancels opposite coincident faces. It checks the topology by positions on
  the inputs and on the output: an output that does not comply gives `Topology` instead of being
  published.
- A zeroed `Boolean_Settings` takes the automatic tolerance and the budgets of `boolean.odin`;
  exceeding them gives `Capacity`. An empty operand is valid; a union that touches only at a point
  or an edge is not manifold and is rejected.
- Limits: validation does not detect all self-intersections, so the inputs must be solids without
  them; the predicates are floating-point with tolerance, not exact arithmetic, and an ambiguous
  contact or a detail smaller than the tolerance may fail explicitly. It does not go through voxels
  or SDF; the BSP may grow quadratically and the budgets bound it.

## Scalar field surfaces (`isosurface.odin`)

- `isosurface` extracts the surface of a region `[low,high)` of a `Scalar_Grid` (values below the
  level are interior) with six tetrahedra per cell in the Kuhn partition: shared faces are split the
  same way, edges are interpolated with ends ordered by index and gradients read the whole grid,
  including the halo of a chunk. Neighboring cells give the same position and normal.
- The values may be a window of the grid (`first`, `extent`): positions are still those of the whole
  grid, so two regions extracted from different windows give the same vertices where they touch. The
  window covers the region and what its gradients read, one step of its level beyond; otherwise,
  `.Invalid_Region`.
- `lod` (up to `ISO_LEVELS_MAX`) extracts one sample out of every 2^k with the level of each face
  and edge that the region shares. Two regions triangulate what they share the same way, so the
  tetrahedra mesh is conforming and the surface closes with any difference of levels, with the same
  normal on each side. Level 0 is the six tetrahedra of each cell.
- The output has three vertices per triangle: `mesh_weld(...,0,...)` when shared indices are needed,
  as in collision (the terrain cooker does it).

## Convex hull (`hull.odin`)

- `hull_build` is a Quickhull from the extreme points; `max_vertices` makes it always grow by the
  farthest point, so a bounded hull stays inside the full one.
- Points within the tolerance of a plane give a flat hull (`hull_is_flat`): two faces back to back,
  without volume. Whoever needs volume discards it (the pieces of a destructible, the parts of
  `mesh_decompose`); the `Hull` collider registers it in `physics` as a mesh, without mass.
- Coplanar triangles are fused into convex polygons; the half-edges (the twin of `e` is `e~1`) are
  the representation of a SAT narrowphase.

## Plane slicing (`slice.odin`)

- `mesh_slice` separates what is in front and behind (either of the two buffers may be `nil`) and
  caps each side. The crossing of an edge depends only on the positions of its ordered ends, so the
  triangles on both sides of a seam get the same point.
- `open_edges` counts cut edges that do not close (the input was open there); `Slicer.sources` gives
  the source triangle of each triangle written, or `SLICE_CAP`.
- Invariant: a closed mesh produces closed parts whose volumes add up to the original except for the
  tolerance times the area of the cut.

## Voronoi fracture (`fracture.odin`)

- Each connected component of a clipped cell is a piece; the pair `(site, chunk)` is its stable
  identity and the pieces are ordered by it. Fewer sites of `sites_generate` are a prefix of more.
- `Fracture.connections` lists the pairs of pieces that touch through their bisector plane; between
  chunks of concave cells the area is an upper bound.
- Each cell clips the whole mesh: the cost grows with sites × triangles. A spatial index of
  triangles does not serve for the first clips: clipping only the nearby ones leaves an open mesh
  whose cuts do not form loops that can be capped.
- To replicate a cut it is enough to transmit the identity of the object, the plane or the
  description of sites and the seed: each machine rebuilds the same pieces.

## Primitives and triangulation

- The `*_build` of `primitives.odin` fit, with their default arguments, in the centered unit cube
  with +Y up, and are closed by position except the plane.
- The shapes of `shapes.odin` (`tube_build`, `lathe_build`, `extrude_build`, `blade_build`,
  `fan_build`, `blob_build`) append to the same `Mesh_Buffer`, closed except the blade, whose
  triangles face their normals; `mesh_buffer_paint` colors what has none yet, `mesh_buffer_place`
  moves a part and `mesh_buffer_flatten` gives every triangle its own vertices.
- `polygon_triangulate` leaves each loop edge in exactly one triangle and always terminates;
  `delaunay_triangulate` omits repeated points and gives no triangles with collinear or non-finite
  points.
- `polygon_convex_partition` merges the triangles of `polygon_triangulate` into convex pieces
  (Hertel-Mehlhorn) without new points: their union is the polygon, and it is fast enough to rebuild
  the colliders of an extruded outline while it is dragged, where `mesh_decompose` is not.
- `polygon_boolean` unites, cuts or intersects two polygons with holes and gives every resulting
  polygon apart (a cut that splits gives two). It snaps to a power-of-two grid exact in `f32`, so a
  result fed back in snaps to the same points and repeated stamping does not degrade; its point
  count is the true outline, which a caller with a capacity reduces itself.

## Simplification (`simplify.odin`)

`simplify` is the only simplifier of the engine: a port of meshoptimizer 1.3's with its same `f32`
arithmetic and its same order, which gives its indices byte for byte. The importer levels, the
`Mesh` collision, the `Mesh` sections of the terrain, the levels that the renderer gives to a
published mesh without levels and the cluster DAG use it.

- **Shape.** That of meshoptimizer: it writes into `destination` (may be `indices`) the indices of
  the mesh with at most `target_index_count`, or those that the topology and `target_error` allow.
  **No vertex is moved or invented**: the indices name vertices of the input.
- **Places and wedges.** Vertices of equal position are wedges of one place; an attribute seam
  separates them and is kept as an outline (a seam place moves only along it). `Permissive` lets
  seams be crossed except at the vertices marked `Protect` in `vertex_lock`; `Lock` on any wedge
  fixes the place; `Priority` makes moving it costlier.
- **Options.** `Lock_Border` (the open border does not move), `Sparse` (the indices are a small part
  of the vertices: the work is that of the part), `Error_Absolute`, `Prune` (loose pieces go away
  whole within the error), `Regularize`, `Regularize_Light`, `Error_Clamped`.
- **Errors.** `result_error` adds position and weighted attributes; `position_error` is only how
  much the surface moved, and is what the levels and the DAG store. Relative to `simplify_scale`
  except with `Error_Absolute`.
- **Memory.** It uses `context.temp_allocator` and releases it on return; it keeps nothing between
  calls.
- A non-finite position or attribute, an out-of-range index or a short `destination` give
  `Invalid_Mesh` or `Invalid_Attributes` without writing.

## Clusters and DAG (`cluster.odin`, `partition.odin`, `cluster_dag.odin`)

- `meshlets_build` is the port of `meshopt_buildMeshletsFlex` and `cluster_bounds` that of
  `meshopt_computeClusterBounds`: they give meshoptimizer's clusters and spheres and cones.
  `spheres_bound` is the sphere around spheres; `meshlet_local_indices`, the local indices.
- `clusters_partition` is that of `meshopt_partitionClusters` with two more ideas: the weight
  between sibling clusters (of the same group of the previous level) is lower than between
  neighbors, so that group borders change from level to level, and small loose pieces are linked
  with the nearest ones in Morton order.
- `cluster_dag_build` follows `clusterlod.h`: clusters of up to `CLUSTER_MAX_TRIANGLES` (128) with
  8-bit local indices and up to `CLUSTER_MAX_VERTICES` (256: with seams, 128 triangles need more
  than 128 vertices, and the renderer draws the same corners per cluster whether full or not);
  groups of `CLUSTER_GROUP_SIZE` simplified to half with their border locked, and `Permissive` where
  seams lock them. A group that does not go below `CLUSTER_SIMPLIFY_STUCK` is a root; its places
  stay locked in all the levels above, because its clusters are drawn next to any of them.
- **Cut contract.** Each `Cluster` carries its cull sphere and cone, `own` (sphere and error with
  which it appears: 0 at level 0) and `parent` (those of its group, shared by all its clusters;
  error `max(f32)` on a root), its group, its level and its submesh. It is drawn where `own`
  projects within the threshold and `parent` does not. The errors are of position and do not go down
  toward the roots, and the sphere of the parent contains its own: every cut is a surface without
  cracks.
- **Submeshes.** A cluster never crosses submeshes: each range of `Cluster_Source.ranges` is
  clustered separately, a vertex of two submeshes is `Invalid_Mesh`, and the outlines between
  submeshes protect themselves.
- `cluster_levels_build` puts discrete levels (skinned meshes, foliage) in the same format: level k
  is group k, its clusters share the sphere of level 0 with the error of level k as `own` and that
  of k+1 as `parent`, and the same cut chooses a whole level.
- Without `optimizeMeshlet` or the *sloppy* fallback of `clusterlod`: a locked group is a root.

## Approximate convex decomposition (`decompose.odin`)

- `mesh_decompose` gives a few convex hulls that represent a non-convex mesh: the collider of a body
  at cook time. It separates islands and cuts the part of highest concavity with the axis-aligned
  plane that leaves the least concavity, up to `concavity` or `max_hulls` (zeros take
  `DECOMPOSE_DEFAULT_*`).
- The cuts are those of `mesh_slice` with caps: the parts of a closed mesh are closed. A bounded
  hull stays inside that of its part and may leave some vertex out. An open mesh is covered all the
  same, with a measure that means less.

## Tangents (`tangents.odin`)

- `corner_tangents` gives one tangent per index with the MikkTSpace convention used by the normal
  map bakers: `w` is the sign of the bitangent, so that `w * cross(normal, tangent)` points up the
  image.
- Mirai counts v downward and MikkTSpace upward: `1 - v` is passed. Without uv or without area, the
  tangent is a perpendicular to the normal and the sign 1.
- It is a port in Odin of `mikktspace.c`, triangles only. `mesh_tangents` repeats a vertex where its
  corners take different tangents (uv seams, mirrored halves), with its skin.

## Outside the package

Not implemented: grid-based *sloppy* simplification, the optimal vertex placement of a collapse
(`meshopt_simplifyWithUpdate`), cluster reordering (`optimizeMeshlet`) and oblique cut planes in the
decomposition.

## Verification

- `shapes_test.odin`: the shapes of props are closed and face outwards; blades, fans and parts.
- `hostile_test.odin` calls each public function with random inputs
  (`-define:GEOM_HOSTILE_ROUNDS=n`; 20,000 with `--release` when changing validation).
- `calls_without_memory_fail_whole_and_their_workspaces_work_again` ends the memory at each request
  of each operation. When changing what an operation reserves, run the package once over a copy
  without `#no_bounds_check` whose `push` and tables assert their room.
- When changing an algorithm, keep the walk order and the tie-breaks: they are part of the
  replication contract.
- `isosurface_regions_of_mixed_levels_join_closed_without_cracks`: regions of random levels close,
  with their volume and one normal per shared vertex; level 0 keeps the triangles and the cost
  (`bench_isosurface`).
  `isosurface_of_a_window_matches_the_whole_grid_and_rejects_regions_that_reach_past_it`: a window
  gives the vertices of the whole grid.
- `simplify_with_a_locked_border_keeps_the_edges_parts_share_at_any_level`,
  `simplify_keeps_the_outline_of_a_seam_of_uvs` and
  `simplify_of_a_sparse_part_is_that_of_the_part_alone`. When touching a port, repeat the
  byte-for-byte comparison with meshoptimizer.
- `cluster_dag_of_a_closed_mesh_cuts_without_cracks_and_is_deterministic` (random cuts without odd
  edges and intact group borders, also with locked groups), `cluster_levels_cut_one_whole_level`
  and, on demo meshes,
  `the_cluster_dag_of_demo_meshes_cuts_without_cracks_with_errors_that_grow` (`cook/import`).
- `surface_edit_test.odin` and `boolean_test.odin`: run their cases in minimal and in speed when
  changing the kernel (the boolean one covers the failure of each allocation with its own temporary
  allocator).
- `tangents_of_a_curved_grid_match_the_reference` compares a curved grid with the tangents of
  `mikktspace.c`.
- Benchmarks, optional with `-define:GEOM_BENCH=true`, `-define:ODIN_TEST_THREADS=1` and without
  other builds or tests on the CPU: `bench_hull`, `bench_fracture`, `bench_simplify`,
  `bench_decompose`, `bench_surface_edit`, `bench_boolean`, `bench_isosurface`, `bench_tangents`,
  `bench_polygon_convex_partition`.
  They are not equivalent to an editor measurement.
