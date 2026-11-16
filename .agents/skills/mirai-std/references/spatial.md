# `std/spatial`: grid, spatial hash and octree

A layer 1 package that imports only `std/math`. The dynamic AABB tree and the BVH, which physics
uses, are in [physics](../../mirai-physics/references/physics.md#stdspatial); here are the cell
structures, which `grid.odin` and `octree.odin` describe in their headers.

## Common contract

- They store boxes with a `user:u64`, are created with fixed capacities and return an `i32` index
  per item. An insertion without room, or of an invalid box, returns `false` and adds to
  `stats.insert_failures`; a zeroed structure fails without touching memory.
- An index that is not of a live item is ignored: reads give zero and writes do nothing.
- Queries are allocation-free iterators, like those of the trees: the structure does not change when
  queried, the iterator is a caller struct and several can run from different threads. Each item
  comes out once. A ray walks the segment `origin + t·translation` up to `max_fraction`, which the
  caller may lower during the walk to cut it short.

## `Grid`: uniform grid and spatial hash

- Each item is linked from all the cells that its box reaches: inserting or moving costs its cells
  and a query those of its volume. With `bounds` it is a uniform grid (what leaves the box is taken
  into its border cells); with `buckets` it is an unbounded spatial hash.
- **Once per item.** A query delivers an item only in the first cell of the query that the item
  reaches; a ray, in the first of its walk (the walk only advances on each axis, so the cells of an
  item it crosses are consecutive). They are integer comparisons: there are no marks in the
  structure.
- **Order.** A query walks the cells by x, then y, then z. A ray walks the cells in the order in
  which the segment crosses them (DDA): items come out from near to far per cell.
- In a hash, a query that covers many more cells than lists walks the items: the cost is bounded by
  the capacity.

## `Octree`: loose octree

- The level of an item depends on its size, never on the planes it crosses: it descends through the
  octant of its center as long as it fits in half the cell, and what a node stores is inside its
  cell enlarged to double. A box with its center outside the cube stays at the root.
- Without nodes to split, the leaf stays whole and adds to `stats.split_failures`.
- **Order.** The items of a node come out before those of its octants, and a ray takes first the
  octant in which the segment enters earlier.

## Which to use

- Many objects of similar size that all move every tick, in a bounded world: uniform grid. Without a
  bound: spatial hash.
- Very different sizes or a very uneven distribution, with few updates: octree. Its queries visit
  the enlarged cells of each level and cost quite a bit more than those of the grid.
- Overlapping pairs, swept queries (`sweep`) and snapshots for rollback: the dynamic AABB tree. The
  grid and the octree have no sweep or snapshot.

## Verification

- `grid_test.odin` compares each structure with a flat list over thousands of random operations with
  a fixed seed: same items, once each, and `*_validate` accepts every state.
- Benchmark `benchmark_grids_and_octree_with_ten_thousand_items`: with `--release`,
  `-define:SPATIAL_BENCH=true` and `-define:ODIN_TEST_THREADS=1`.
