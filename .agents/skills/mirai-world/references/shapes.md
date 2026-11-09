# Shapes

`shapes` (`Runtime` and `Editor`; depends on `physics`) makes editable solids for any game: level
blockout, and games where players stamp squares, circles, stars and other shapes onto flat outlines to add or
cut material, drag vertices, and make pieces static or physical.

## Source and derived

- The `Shape` of an entity is the source and the only thing a scene saves. An **Outline** is a
  polygon with holes in the local XY plane of the entity, its outline first and then its holes,
  extruded along local Z by `depth` and centered on the entity. A **Solid** is made of its
  brushes, each added to what the brushes before it made or cut from it.
- The texture is anchored in the local plane: caps by position, and each side and bevel band
  along its own direction, so an edit elsewhere on the outline does not slide what it kept.
- A **bevel** (`bevel`, `bevel_profile`) rounds or cuts the front and back rims of an Outline:
  its caps are inset by `bevel` and its rims fall by `bevel` along Z, following a Round
  (tangent to the cap and the side), Chamfer or Points profile (a polyline from the cap to the side
  that never turns back). Each loop is inset along the bisectors of its corners, with a miter
  limit. Where a corner, an edge, a gap across the shape or the depth is smaller than the bevel,
  the inset there is clamped so the cap keeps part of it; a band that would turn over or cap edges
  that would meet halve the insets of their points, and a bevel that still does not fit is left
  out, never drawn crossed. The fall is the same along the whole rim, so where an inset is
  clamped the profile is steeper. A bevel of 0 builds the shape as without one.
- A **brush** is an entity with `Shape_Brush` (kind and `subtract`) and `core.Id`, a direct child
  of the Solid: source saved with the scene, so selection, the gizmo, undo, the inspector, the
  outliner, prefabs and the API work on it as on any entity. Its local `Transform` places, turns
  and scales a primitive of one meter in the frame of the solid (a box of side 1, a sphere and a
  cylinder of diameter 1, the cylinder 1 tall along Y): its scale is its full size and must be
  positive. Brushes apply in sibling order; what cuts before the first brush that adds has
  nothing to cut, is left out and reported as `shapes.first_brush`. A brush has no mesh or
  collider of its own, and a `Shape_Brush` that is not under a Solid does nothing.
- The mesh and the collider live on one derived child with `Shape_Part`, a `core.Parent` to the
  shape, `Mesh_Renderer` and `physics.Collider`, and no `core.Id`: `scene.capture` leaves it out
  and the step makes it again. The step finds that child among the children of the shape, creates
  it with `core.Commands` when it is missing, destroys any second one, and destroys it when the
  `Shape` goes.
- `shapes_update` (`fixed frame`, game and editor loops, before `physics_prepare`) rebuilds only
  the shapes whose `Shape`, `Rigid_Body` or `Collider` changed, or one of whose brushes changed,
  came, went or moved among its siblings, all of them in parallel in `std/jobs`, and generates
  their meshes between the jobs and the end of the step.
- Brush changes are found by comparing every brush with what the cache kept of it (its parent,
  the brush before it among the siblings, kind, `subtract` and local `Transform`), not by reading
  the `Transform` changes of the world: the work is per brush, and with the `Shape_Brush` table
  and the cache empty there is none. A world of Outlines in which nothing changed returns before
  any work or allocation; the key of what each mesh was made from includes the brushes in order,
  so a mark that changes nothing builds nothing.
- `Shapes_Cache` is `@(storage,host,by_world)`: each world keeps the ids of the meshes it
  generated and releases one when its shape changes or goes, and all of them in
  `@(step="release")`. A copied world (Play, rollback) finds the children of its shapes, makes its
  own meshes and never releases those of another world. A rollback that brings back an older
  source is caught by the key of the source each mesh was made from.
- A shape that cannot be built reports a `shapes.<cause>` problem that says what failed and how to
  fix it, and keeps the mesh it had.

## Static and dynamic

- Without a `Rigid_Body` on the shape entity the child collides as a `Mesh` collider over the
  generated mesh, joined by position, with the edges between coplanar triangles disabled so a
  character does not catch on the seams of a flat face.
- The bevel is drawn only: what collides is the unbeveled prism of the Outline, in both cases.
  Its flat faces keep their seams disabled and its convex pieces stay those of the polygon, and a
  look of the rims changes nothing in the simulation.
- With a `Rigid_Body` the child's collider is a `Hull` made of convex pieces, each a shape of that
  body (`Mesh_Generate_Options.hull_points`): the convex partition of an Outline extruded into
  prisms; the brushes of a Solid, each placed, when none subtracts, else an approximate
  decomposition of its mesh. `shape_pieces_build` computes them.
- A `physics.Collider` the game puts on the shape entity gives every field of the derived collider
  but `kind`, `size` and `center` (a preview shape that must not collide is a sensor that meets
  nothing). It must be of kind `External`, so physics makes no shape of its own from it; any other
  kind is reported.

## Editing

- The editing procedures work in the local XY of the shape and change only the `Shape` they get,
  and only when they succeed. The caller decides the entities: when a stamp splits a shape, it
  makes a shape entity for each other polygon of the set with `shape_outline_set`.
- `shape_outline_set`, `shape_combine` and `shape_stamp` (`shape_combine` with one loop)
  leave the outline counter-clockwise and the holes clockwise, and drop only repeated points and
  points exactly on the line of their neighbors. A polygon that still has more points or loops
  than a `Shape` holds is refused with `Too_Many_Points` or `Too_Many_Loops` and the shape keeps
  its value: nothing is simplified behind the caller.
- `shape_combine` puts the polygon of largest area first in its set and makes the shape that
  one; with no polygon left the shape is gone and keeps its value; it fails before changing the
  shape when some polygon would not fit.

### Strokes

- A drag is one `Shape_Stroke`: the brush (a simple loop around 0, convex or not) swept along the
  path of the pointer, its area one polygon with holes in the units of the plane
  (`shape_stroke_begin`, `shape_stroke_to`, `shape_stroke_area`).
- The path is simplified as it comes: a point nearer than the tolerance to the last one kept is
  left out, and a kept point becomes a corner only when no line from the last corner passes
  within the tolerance of every point kept since (a sleeve fit). The caller gives the tolerance as
  a few pixels of the screen in plane units at the current zoom, so the shake of a hand goes
  where it happens; the same path read at any rate gives the same area within the tolerance.
- The area is the union of the convex hulls of each convex piece of the brush at both ends of each
  segment, so a concave brush keeps its dents. The segments before the last corner stay united,
  so a point costs two booleans per piece at most.
- **Edits.** `Shape_Edit` applies a stroke to the Outline shapes of a plane, without entities of
  its own, so the editor tool and a game share it: the caller begins it with the stamp, the plane,
  add or cut and what a new shape starts from (`shape_edit_begin`), gives it the shapes it may
  change as pieces with their entity and world placement (`shape_edit_piece`, refused off the
  plane), moves it with each point (`shape_edit_to`), and writes the pieces that changed
  (`shape_edit_next`): it makes an entity for a piece without one (a copy of `from` when it
  split from a given shape), takes away the entity of a piece that is `gone` and writes the
  `Shape` of the others.
- **Base snapshot.** Each change of the area combines the shape of a piece as it was given with
  the whole area: a shape never gathers the junctions of the pieces of a drag, its vertices
  outside the area stay as they were, and the result does not depend on the frame rate. Adding
  goes into the first given piece the area joins at the first point, or a new piece there; cutting
  goes out of every given piece it has reached. The polygons past the first of a result go, in
  order, to the pieces split from it, which keep their entities while the edit lasts.
- A combination past capacity is refused: the pieces keep the last result that fit, the stroke
  stops growing there, and the caller tells the player.
- Craters, digging and many hits during play belong to a `Volume` terrain or to `destruct`, not
  to Solid brushes: each brush rebuilds the whole Solid.
- Vertices are indices into the points of all loops, and an edge is named by its first vertex. A
  vertex move, insertion or removal that would make edges cross or touch, take a hole out of the
  outline or into another, or turn a loop inside out is refused with `Self_Intersecting`; a loop
  keeps at least three points.

## Shapes tool

Editor tool (shortcut **K**, `plugins/shapes/editor/`). The camera stays free; the tool works on
the plane of the shape selected last (its local XY at z = 0) or, with no shape selected, on the
plane z = 0 of the world. W, E and R lend the scene to the gizmo and the selection; a mode takes
it back.

- **Stamp** (1): a kind of `Stamp_Kind` (square, circle, triangle, star, heart...), size, angle, Add or Cut (X) and the material of new
  shapes. A press and its drag are one stroke, its tolerance two points of the window on the plane
  under the pointer. The stroke is a `Shape_Edit` given the Outline shapes of the plane when it
  begins, and writes what changed each frame through the edits of the step. Adding joins the first of them the
  stamp touches at the press, the selected one first, or makes a shape entity there (`Id`,
  `Transform` at the press, `Shape` of `depth` 1); the whole stroke goes into that shape.
  Cutting takes the area out of every Outline shape of the plane it reaches: each other polygon
  of a split is a copy of its entity (`entities_duplicate`) with that outline, and a shape cut
  away whole is deleted.
- **Corners** (2): the selected Outline shows its loops and corners. A drag moves a corner, a
  double click on an edge inserts one, Ctrl+click or Delete removes the one under the pointer; a
  click elsewhere selects the shape under it. An edit the shape refuses does not apply.
- **Brush** (3): a box, sphere or cylinder brush, added or cut, shown as lines on the surface
  under the pointer (`editor.pick_point`), its Y along the normal and turned by the angle around
  it: an added brush rests on the surface and a cut one is centered on it; over nothing, on the
  plane of the selected Solid or the plane z = 0 of the world. A click makes it the last child of
  the Solid hit, else of the selected one (or of the Solid of a selected brush); with neither, an
  added brush makes a Solid entity at the point with it. **Alt** shows the brush of the Solid under
  the pointer that makes the surface there, and Alt+click selects it: W, E and R then move, turn
  and scale it with the editor's gizmo, and 3 goes back to placing.
- Undo: a press-drag-release, a corner drag, an insertion, a removal and a brush (with the Solid
  it makes) are one step each, opened by their first change; Escape cancels a stroke or a drag.
- `shapes.stamp` (world points of a stroke, kept with no tolerance, the plane of a shape or of
  the world) and
  `shapes.corner` (move, insert or remove at world points) are the same edits by API, one step
  per call; an error leaves nothing. Brushes are entities: the scene methods add, place and remove
  them.

## Verification

`mirai test plugins/shapes/runtime`: stamping (merge, hole, split, vanish, a long drag that stays
within capacity, a polygon past capacity refused), strokes (`stroke_test.odin`: a shaky straight
drag is one segment, the area does not depend on how often the pointer is read, hostile brushes,
points, planes and pieces; edits: an add outside every shape makes one new piece, vertices
outside the area stay, a cut splits into pieces that keep their entities, a covered shape is gone,
a piece given late is cut by the whole area, a stroke past capacity keeps the last result;
`bench_stroke_combine` with `--release -define:SHAPES_BENCH=true`), vertex edits that are
refused, closed meshes that face out with their seams disabled, bevels (a square with holes, a
triangle, a circle, an L, thin and shallow shapes and random stars: closed, normals that agree,
within the unbeveled collider, front faces that neither turn over nor overlap; invalid profiles
refused; bevel 0 ignores the profile; the key follows the bevel), convex pieces of bodies, and the
step (one child without `Id`, regeneration and release, a copied world, removal; a Solid of brush
children with a hole that follows a moved, reordered and removed brush; a piece per added brush;
Outlines that neither build nor allocate while nothing changes).

`mirai test plugins/shapes/editor`: a stroke is one step that undo and redo take back and forth,
a cut that splits makes a second shape entity and undo restores one, Escape puts back every shape
a cut stroke changed, a corner drag is
one step and a crossing move does not apply, `shapes.stamp` and `shapes.corner` as steps, a brush
placed on a surface as one step and a child with `Id` (and a new Solid with it), and where a ray
meets each brush primitive.
Gestures with the pointer are tested by the user.
