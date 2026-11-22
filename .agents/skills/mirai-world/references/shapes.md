# Shapes

Plugin `shapes` (`Runtime`, `Editor`; depends on `physics`): editable polygon + brush solids,
`volume.Spline` ribbons ([docs](../../../../docs/game/world/splines.md)), and curved mesh
[bends](#bends).

## Source and derived

- `Shape` is the sole saved source: a local XY polygon with holes extruded along local Z by `depth`
  (centered), followed in sibling order by direct child `Shape_Brush` entities (with `core.Id`;
  unit box/sphere/cylinder scaled by positive local `Transform`, union/subtract/intersect). A
  leading cut/intersect before any additive geometry is skipped and reports `shapes.first_brush`.
  Caps anchor UVs by local XY; sides and bevels anchor along each edge.
- **Bevel** (`bevel`, `bevel_profile`: `Round`, `Chamfer`, `Points`): insets caps and drops rims by
  `bevel`, clamping/halving to prevent inversion or overlap (dropped if impossible; `bevel == 0`
  skips profile). Visual only — collision uses the unbeveled prism.
- Derived mesh and collider live on one unsaved child (`Shape_Part`, `core.Parent`, `Mesh_Renderer`,
  `physics.Collider`, no `core.Id`). `shapes_update` (`fixed frame`, game+editor, before
  `physics_prepare`) rebuilds dirty shapes in parallel (`std/jobs`). Brush dirtiness compares cached
  brush records (not world `Transform` tables); clean worlds do zero work/allocation.
- `Shapes_Cache` (`host, by_world`, `shapes_release`) owns per-world generated meshes keyed by
  source + ordered brushes (catches rollback). Failures report `shapes.<cause>` and keep prior
  mesh.

## Static and dynamic

- Without `Rigid_Body`: static `Mesh` collider with coplanar interior edges disabled.
- With `Rigid_Body`: `Hull` convex pieces (`shape_pieces_build`,
  `Mesh_Generate_Options.hull_points`: exact partition for union-only solids, else approximate
  decomposition).
- A `physics.Collider` on the source entity forwards filter/surface to the child when `External`;
  any other kind collides in place of the shape (child draws only). Child copies `Material_Values`;
  `uv_scale` sets repeats/metre.

## Splines

A `volume.Spline` with a `material` builds a derived `Shape_Part` ribbon (`spline_sample`,
`spline_lay`, u across, v along in metres, no collider). Rebuilds only when `Spline`,
`Transform`/`Parent`, or overlapping `core.Ground_Queries.changed` (`volume.spline_under`) changes.
Both `Shape` and drawn `Spline` on one entity draws `Shape` and reports `shapes.both`.

## Bends

- `Bend` + `Mesh_Renderer` maps a mesh along a cubic Hermite curve (`start`/`end` + tangents,
  `forward`/`mesh_up`, `range`, `roll`, `scale`, `offset`, `smooth`; straight tangent past `range`)
  onto a derived `Shape_Part` child while marking the source `Drawn_Elsewhere`.
- Normals follow the bend derivative, tangents rebuild, UV2 persists, negative-scale triangles
  rewind. Collides only with `External` `Collider` (`Mesh` static / `Hull` dynamic); non-External
  mesh-reading colliders report `shapes.bend_collider`. Rebuilds on component/material changes or
  mesh file header hash change; `bend_place` evaluates a point.

## Editing

All local-XY ops are atomic (keep old value on error). `shape_outline_set`, `shape_combine`, and
`shape_stamp` normalize winding (outline CCW, holes CW), drop duplicate/collinear points, and refuse
overflow with `Too_Many_Points` or `Too_Many_Loops` (no silent simplification). `shape_combine`
places the largest polygon first (empty -> shape gone, unchanged). Vertex ops (`shape_vertex_move`,
`shape_vertex_insert`, `shape_vertex_remove`) refuse crossings/inversions (`Self_Intersecting`) and
keep >= 3 points/loop.

### Strokes

- `Shape_Stroke` (`shape_stroke_begin`, `shape_stroke_to`, `shape_stroke_area`) sweeps a simple
  (convex or concave) brush loop using sleeve-fit path simplification (tolerance in plane units) so
  results are frame-rate independent.
- `Shape_Edit` (`shape_edit_begin`, `shape_edit_piece`, `shape_edit_to`, `shape_edit_next`) applies
  a stroke to coplanar shapes against their base snapshots (add joins first hit or creates a piece;
  cut splits/deletes across all hit pieces; capacity overflow freezes at last valid state). Craters
  and runtime digging belong to `Volume` terrain or `destruct`, not Solid brushes.

```odin
// Stamp or cut a Shape in local XY and handle split polygons.
brush := make([dynamic]geom.Vec2, context.temp_allocator)
shapes.stamp_points(.Circle, {0.5, 0}, 0.4, 0, &brush)
out: geom.Polygon_Set
geom.polygon_set_init(&out, context.temp_allocator)
if shapes.shape_stamp(&shape, brush[:], .Difference, &out) == .None {
    for i in 1..<len(out.polygon_loops) {
        piece := shape
        if shapes.shape_outline_set(&piece, &out, i) == .None { /* spawn split entity */ }
    }
}
```

```odin
// Drive a live coplanar drag stroke across scene shapes.
edit: shapes.Shape_Edit
defer shapes.shape_edit_free(&edit)
err := shapes.shape_edit_begin(
    &edit, plane, true, .Square, 0.5, 0, 0.02, shapes.SHAPE_DEFAULT,
)
if err == .None {
    shapes.shape_edit_piece(&edit, e, world_xform, shape)
    _ = shapes.shape_edit_to(&edit, {0, 0})
    _ = shapes.shape_edit_to(&edit, {2, 0})
    idx := 0
    for piece in shapes.shape_edit_next(&edit, &idx) { /* create, update, or destroy piece */ }
}
```

## Shapes tool

Shortcut **K** (`plugins/shapes/editor/`). Works on the last selected shape's XY plane (`z = 0`) or
world `z = 0`; W/E/R lend to gizmo.

- **1 Stamp**: `Stamp_Kind`, size, angle, Add/Cut (X), material; drag runs `Shape_Edit`.
- **2 Corners**: edits `Shape` polygon, `Spline` XZ points (min 2), or `Volume` `Outline` loop
  (min 3); drag moves, double-click inserts, Ctrl+click/Delete removes.
- **3 Brush**: places box/sphere/cylinder on `editor.pick_point` (X cycles op, Alt picks/selects
  contributing brush).
- One undo step per gesture; Escape cancels. API: `shapes.stamp` (world points, 0 tolerance) and
  `shapes.corner` (1 undo step each); brushes use scene methods.

```sh
mirai rpc shapes.stamp '{"kind":"Square","size":1.5,"points":[[0,0,0],[3,0,0]]}'
mirai rpc shapes.corner '{"entity":"Wall_1","op":"Move","at":[1.5,1.5,0],"to":[2.0,1.5,0]}'
```

## Verification

- `mirai test plugins/shapes/runtime`: stamping (merge/hole/split/vanish/capacity), strokes
  (`stroke_test.odin`, `bench_stroke_combine` with `--release -define:SHAPES_BENCH=true`), vertex
  edits, closed meshes + disabled seams, bevels, convex hulls, step lifecycle (no `Id`, brushes,
  rollback, zero-alloc idle, spline ribbons), and bends (`bend_test.odin`).
- `mirai test plugins/shapes/editor`: stroke/split/Escape/corner/brush undo steps, `shapes.stamp`,
  `shapes.corner`, spline corner editing, and brush ray hits.
