# `std/geom`: geometry processing

Layer 1 package importing only `core:` and `base:`; operates on flat slices and caller buffers for
`physics`, destruction, `asset` primitives, and mesh/collider cooking.

## Data and memory

- `Plane{normal, d}`: on plane when `dot(normal, p) == d`, front when `>` (opposite sign of `d` to
  `math.Plane`).
- `Mesh` is a CCW-outward view with optional normals/UVs/colors/materials; `Mesh_Buffer` grows and
  reuses capacity (most ops clear it; primitives and `hull_append_mesh` append; mismatched
  attribute lengths are rejected).
- Single-call ops guard `context.temp_allocator` with `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`
  ([jobs](jobs.md#temporary-memory)). `Slicer`, `Fracture`, and `Mesh_Surface_Workspace` reuse
  memory across calls (zero allocs once warmed).
- Tables (`Key_Map`, `Point_Set`) and hot workspaces reserve exact upper bounds before filling so
  `#no_bounds_check` stays in bounds.
- On OOM: returns `Out_Of_Memory` (or empty/`false` for `polygon_triangulate`,
  `delaunay_triangulate`, `polygon_convex_partition`, `mesh_tangents`, `mesh_weld`,
  `hull_append_mesh`, `primitives.odin`/`shapes.odin`), clears outputs, and leaves workspaces
  reusable once memory returns (`positions_weld` returns 0 and `mesh_topology` open on temp OOM).

## Determinism, precision and tolerance

- **Deterministic:** identical inputs yield byte-identical outputs (IEEE-754 `+ - * / sqrt floor`,
  `turn_sincos`, Odin `math.atan2`, index tie-breaks, no hash iteration, `base.Rng` seeds; assumes
  no FMA contraction).
- **Precision:** `f32` I/O; predicates and area/volume sums run in `f64` (meshoptimizer ports use
  `f32` to match upstream byte-for-byte).
- **Validation & tolerance:** NaN/Inf, out-of-range indices, length mismatches, or bad params
  return typed errors (`Invalid_Mesh`, `Invalid_Plane`, `No_Sites`...). Tolerances are absolute
  distances floored at `tolerance_noise(max_abs)`.
- **Position topology:** welding/topology match vertices by position, ignoring attribute seams
  (`mesh_topology_is_closed`: closed 2-manifold; `mesh_topology_is_watertight`: 1 opposite per
  half-edge).

## Surface editing (`surface_edit.odin`)

- `mesh_surface_edit` applies `Sculpt`, `Smooth`, `Flatten`, or `Drag` (explicit `rotation` around
  `center`) over the caller-supplied region + halo (`lock_boundary` freezes borders/non-manifold
  edges). Preserves indices/UVs/colors/materials; recomputes affected normals by `(position,
  original_normal)` to preserve hard seams; does not prevent self-intersections.
- `mesh_surface_refine` performs one conforming subdivision pass across seams (no flips/collapses).
- Errors (`Invalid_Mesh`, `Invalid_Brush`, `Budget_Exceeded`, `Out_Of_Memory`) clear output;
  overlapping input/output returns `Aliased_Output` untouched.

## Solid booleans (`boolean.odin`)

`mesh_boolean(a, b, op, out, settings={})` computes `Union`, `Subtract`, or `Intersect` on closed,
outward-oriented solids (cavities inverted), keeping seams and materials (subtraction caps invert
B).

- Iterative `f64` BSP (A's tree classifies B only, preventing non-planar A from splintering
  itself), position-welding, T-junction closing, opposite-face cancellation, and closed-manifold
  output check (fails with `Topology` rather than publishing bad geometry; errors `Invalid_Mesh`,
  `Invalid_Settings`, `Not_Closed`, `No_Volume`, `Capacity`, `Out_Of_Memory` clear `out`).
- Zero `Boolean_Settings` uses default tolerance and budgets. Point/edge-only unions are rejected;
  inputs must be self-intersection-free.

```odin
out: geom.Mesh_Buffer
geom.mesh_buffer_init(&out); defer geom.mesh_buffer_destroy(&out)
if err := geom.mesh_boolean(mesh_a, mesh_b, .Subtract, &out); err != .None { return }
```

## Scalar field surfaces (`isosurface.odin`)

- `isosurface(g, low, high, out, isolevel=0, lod={})` extracts `[low, high)` (values `< isolevel`
  are interior) via 6-tetrahedron Kuhn cells so neighbor chunks share identical vertices and
  normals. Supports windowed grids (`first`, `extent` must cover region + 1 LOD step for gradients,
  else `Invalid_Region`; bad grid gives `Invalid_Grid`).
- `Iso_Lod` (`level <= ISO_LEVELS_MAX`, plus per-face/edge levels) produces crack-free conforming
  meshes across mixed LODs. Emits unshared triangle soups; call `mesh_weld(..., 0, ...)` for shared
  indices.

## Convex hull (`hull.odin`)

`hull_build` runs Quickhull (`max_vertices` selects farthest points so bounded hulls stay inside
the full hull). Coplanar points produce a zero-volume flat hull (`hull_is_flat`, discarded by
destruction/`mesh_decompose`, registered as mesh in physics). Coplanar faces merge into convex
polygons with SAT half-edges (twin of `e` is `e ~ 1`).

## Plane slicing (`slice.odin`)

`mesh_slice(s, mesh, plane, front, back, options={})` splits and caps closed meshes (`front` or
`back` may be `nil`). Ordered-endpoint intersection keeps seams identical; `open_edges` counts
uncapped open cuts; `Slicer.sources` maps triangles to source index or `SLICE_CAP`. Closed inputs
conserve volume within `tolerance * cap_area`.

```odin
s: geom.Slicer; geom.slicer_init(&s); defer geom.slicer_destroy(&s)
front, back: geom.Mesh_Buffer
geom.mesh_buffer_init(&front); defer geom.mesh_buffer_destroy(&front)
geom.mesh_buffer_init(&back); defer geom.mesh_buffer_destroy(&back)
res, err := geom.mesh_slice(&s, mesh, {normal = {0, 1, 0}, d = 0}, &front, &back)
_ = res; _ = err
```

## Voronoi fracture (`fracture.odin`)

`mesh_fracture` clips each cell into connected pieces ordered by stable `(site, chunk)` identity
(fewer sites from `sites_generate` are a prefix of more). `Fracture.connections` lists touching
pairs and shared area (upper bound on concave chunks). Cost scales with `sites * triangles` (full
mesh per cell to keep cuts closed). Replicate deterministically by sending entity + plane or
`Site_Desc` + seed.

```odin
sites: [12]geom.Vec3
geom.sites_generate(sites[:], {pattern = .Radial, seed = 42, lo = lo, hi = hi, center = hit})
f: geom.Fracture; geom.fracture_init(&f); defer geom.fracture_destroy(&f)
if geom.mesh_fracture(&f, mesh, sites[:], {interior_material = 1}) == .None {
    for i in 0..<len(f.pieces) { _ = geom.fracture_piece_mesh(&f, i) }
}
```

## Primitives and triangulation

- `primitives.odin` (`*_build`): centered unit cube, `+Y` up, closed by position except plane.
- `shapes.odin` (`tube_build`, `lathe_build`, `extrude_build`, `blade_build`, `fan_build`,
  `blob_build`): append to `Mesh_Buffer` (closed except `blade_build`), plus `mesh_buffer_paint`,
  `mesh_buffer_place`, `mesh_buffer_flatten`.
- `polygon_triangulate` (always terminates), `delaunay_triangulate` (deduplicates, rejects
  collinear/non-finite), `polygon_convex_partition` (Hertel-Mehlhorn, real-time fast), and
  `polygon_boolean` (power-of-two `f32`-exact grid snapping so repeated stamps never drift).

## Simplification (`simplify.odin`)

Exact `f32` port of meshoptimizer 1.3 (never invents/moves vertices; indices name input vertices;
temp memory freed on return; invalid input returns `Invalid_Mesh` / `Invalid_Attributes`).

- Equal positions form wedges of one place; seams preserve outlines unless `Permissive` (except
  `Protect` in `vertex_lock`; `Lock` freezes place; `Priority` penalizes collapse).
- `Simplify_Options`: `Lock_Border`, `Sparse`, `Error_Absolute`, `Prune`, `Regularize`,
  `Regularize_Light`, `Permissive`, `Error_Clamped`. `position_error` excludes attribute error
  (used by LODs/DAG); relative to `simplify_scale` unless `Error_Absolute`.

```odin
dst := make([]u32, len(indices)); defer delete(dst)
res, err := geom.simplify(dst, indices, positions, len(indices)/2, 0.01, {.Lock_Border})
_ = res; _ = err
```

## Clusters and DAG (`cluster.odin`, `partition.odin`, `cluster_dag.odin`)

- Ports of `meshopt_buildMeshletsFlex` (`meshlets_build`), `meshopt_computeClusterBounds`
  (`cluster_bounds`), `meshopt_partitionClusters` (`clusters_partition`, down-weighting sibling
  clusters and Morton-linking small loose pieces), and `meshopt_optimizeMeshletLevel`
  (`meshlet_optimize`).
- `cluster_dag_build`: up to `CLUSTER_MAX_TRIANGLES` (128) / `CLUSTER_MAX_VERTICES` (256), groups
  of `CLUSTER_GROUP_SIZE` simplified to half with locked group borders -> `Permissive` -> relaxed
  `Protect` if still above `CLUSTER_SIMPLIFY_STUCK` (attribute error capped by
  `CLUSTER_ERROR_EDGE_LIMIT` × longest edge, position error uncapped); still stuck becomes a root
  whose places stay locked above. No sloppy fallback. A level of one cluster of more than
  `CLUSTER_ROOT_TRIANGLES` (32) is simplified too, so a mesh of one cluster (grass clump, small
  prop) gets coarser levels and every root is that small.
- **Cut contract:** draw cluster where `own` projects within threshold and `parent` does not (`own`
  error 0 at level 0, `parent` error `max(f32)` at root; monotonic errors and nested spheres give
  crack-free cuts). Clusters never span submeshes (`Cluster_Source.ranges`; shared submesh vertex
  is `Invalid_Mesh`). `cluster_levels_build` encodes discrete LODs in the same format.
- **Islands (`cluster_islands.odin`):** Aggregate foliage/cards (`Cluster_Source.islands`,
  `island_indices`) prune instead of simplifying (`islands_reduce`: coarsen rungs, halve survivors,
  grow area up to `islands_clouds` bound, error over `ISLAND_PIXELS`, keep last island per class;
  emits transition scale/drop rank in `Cluster_Dag.made`).

```odin
dag: geom.Cluster_Dag; defer geom.cluster_dag_destroy(&dag)
err := geom.cluster_dag_build(&dag, {positions = positions, indices = indices})
_ = err
```

## Approximate convex decomposition (`decompose.odin`)

`mesh_decompose` splits islands and recursively cuts the highest-concavity part with axis-aligned
`mesh_slice` planes until `concavity` or `max_hulls` (`DECOMPOSE_DEFAULT_*`). Closed inputs yield
closed parts; bounded hulls stay inside their part.

## Tangents (`tangents.odin`)

Odin port of `mikktspace.c` (triangles only; flips V as `1 - v` for Mirai's downward V).
`corner_tangents` outputs tangent + bitangent sign `w`; `mesh_tangents` splits vertices at
UV/mirror seams (preserving skin).

Not implemented: sloppy grid simplification, `meshopt_simplifyWithUpdate`, oblique decomposition
planes.

## Verification

- `mirai test std/geom`: `shapes_test.odin`, `surface_edit_test.odin`, `boolean_test.odin`,
  `hostile_test.odin` (`-define:GEOM_HOSTILE_ROUNDS=n`, 20,000 on validation changes).
- Key invariants:
  - `calls_without_memory_fail_whole_and_their_workspaces_work_again`
  - `isosurface_regions_of_mixed_levels_join_closed_without_cracks`
  - `isosurface_of_a_window_matches_the_whole_grid_and_rejects_regions_that_reach_past_it`
  - `simplify_with_a_locked_border_keeps_the_edges_parts_share_at_any_level`
  - `simplify_keeps_the_outline_of_a_seam_of_uvs`
  - `simplify_of_a_sparse_part_is_that_of_the_part_alone`
  - `cluster_dag_of_a_closed_mesh_cuts_without_cracks_and_is_deterministic`
  - `meshlet_optimize_keeps_each_triangle_and_reuses_vertices_sooner`
  - `cluster_levels_cut_one_whole_level`
  - `a_lone_cluster_is_simplified_into_coarser_levels`
  - `tangents_of_a_curved_grid_match_the_reference`
  - `cook/import`: `the_cluster_dag_of_demo_meshes_cuts_without_cracks_with_errors_that_grow`
- Benchmarks (`-define:GEOM_BENCH=true -define:ODIN_TEST_THREADS=1`): `bench_hull`,
  `bench_fracture`, `bench_simplify`, `bench_decompose`, `bench_surface_edit`, `bench_boolean`,
  `bench_isosurface`, `bench_tangents`, `bench_polygon_convex_partition`.
