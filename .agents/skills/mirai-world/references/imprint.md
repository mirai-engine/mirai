# Footprints on the ground: the `imprint` plugin

`plugins/imprint` (`Runtime`, `Shaders`; depends on `vfx` and `physics`): snow, mud and sand that
keep where bodies pass, with real displacement that the raster and all rays see. It is the second
of the three deformation mechanisms of the engine.

## The field

- A [`vfx`](vfx.md#grids-and-stages) grid named `imprint` (`IMPRINT_GRID`), flat along y, with
  `follow_view`: its region follows what the view looks at and wraps in place, a clipmap of the
  ground around the camera whose cells enter clean. It is no other machinery: the grid, the stage
  and the channel are those of `vfx`, as for the `fluids` plugin (which lives in the mirai-fluids
  repository).
- A `Particle_Emitter` whose effect runs the `Imprint` program (`shaders/imprint.slang`) with a
  silent `Particle_Channel` `stamps` (`CHANNEL_STAMPS`), and a `Particle_World_Texture` of layer 0,
  which carries it to the vertices and the materials.
- Layer 0: `x` meters above the ground's rest (below 0 what was stepped on; above 0 an edge or
  what a fluid left), `y` how much it was pressed (0 to 1), `z` how much a fluid wetted it.
- The `stamp` stage sinks each stamp of the step to its depth, never upward, and raises the `berm`
  part of that depth in an edge around it, only over what was not stepped on. The ground returns
  to rest at `recover` meters per second and loses what was pressed by `compaction_fade`. With a
  `fluid` grid of `fluids` in the world, its density raises the ground `fluid_deposit` meters per
  second (negative: it undercuts it) and wets it.
- Before stamping, each cell steeper than `repose` (meters per meter) against the mean of its four
  neighbors slides `relax` of the excess, like sand and snow past their angle of repose: the walls
  of a footprint stay, smoothed, and without steps between cells that the vertices would sample as
  boiling. It reads the previous copy of the grid, so it does not depend on the order of the
  cells, and with `relax` up to 1 it does not oscillate.

## Stamps

`Imprint_Stamp` on the entity of a body (`bottom`: how far below its entity it touches). Each
fixed tick `imprint_stamps` looks with a physics ray for what is under its bottom, without the
body of its entity: the colliders are the ground at rest, so a body resting presses its whole
`depth` (`stamp_press`), one at `reach` from the ground nothing, and with no ground below it does
not stamp. Without `stride` it stamps a furrow from where it was on the previous tick; with
`stride`, an oval footprint of `length` every `stride` meters, alternating sides at half of
`gait` (`stride_print`). It counts what it stamps in `Imprint_Steps.pressed`.

## What is drawn

- `Imprint_Ground` on an entity: its mesh and those of the entities below (`DEPTH` levels: the
  chunks of a terrain, without `terrain` knowing of the plugin) are drawn, while the field's
  region reaches its box, by a deformable copy (`deformable_create`) that replaces the instance
  (`replace_source`). The copy's box is the rest box grown by `depth_max` and `rise_max` along the
  world's up: culling knows it from the first frame.
- `imprint_displace.comp.slang`, in the `Geometry` stage, moves each vertex along the world's up by
  the field filtered with a tent two vertex spacings wide on each side (the spacing comes from the
  mesh's box and its vertices, as in a grid), limited to `depth_max` and `rise_max` and taken to
  zero at the edges of the region, and gives it the normal of the slope of a tent twice as wide.
  Sampled at a point, a footprint smaller than the triangles would sink a single vertex (a pit
  with the shape of its fan that jumps from vertex to vertex) and the wall of a furrow would make a
  sawtooth. The normal is drawn linear between vertices: one that turns within few triangles
  across the wall stops facing the sun following their diagonals, in a sawtooth. The renderer
  refits its BLAS and keeps the previous position: shadows, reflections, GI and motion vectors
  follow the footprints.
- The stage reads the world texture that the steps of the previous frame left, in its place in the
  table (`vfx.world_texture_place`).
- **Which frames write.** A new copy or one with another place (another region, another mesh), a
  vertex buffer made anew, for `SETTLE` seconds after the last stamp, and every `REFRESH` frames
  what only returns to rest; with `live`, every frame (a fluid that deposits without stamps).
- The `Imprint_Surface` Surface program adds to the normal the slope finer than `mesh_spacing`
  (the scale that the vertex normals carry) and tints and smooths what is pressed and what is
  wet. It goes in a mesh's material: a terrain's layer material blends the textures of its layers
  without running their programs, so on a terrain the footprints are seen through the vertices.
- Physics does not see the footprints: the collider stays at rest. A game that sinks a character
  reads the field back (the `vfx` grid reads), as presentation.

## Scene

An entity with the `imprint` grid (cells of 2 to 10 cm, `follow_view`), its emitter with
`Imprint`, the `stamps` channel and the world texture; the terrain or the ground mesh with
`Imprint_Ground` and a material with `Imprint_Surface`; the bodies with `Imprint_Stamp`. The
`snow` scene of the `fluid-ninja` project builds them.

A terrain chooses its level by the error of its heights at rest: flat, it takes coarse levels
even near the camera and the footprints end up in triangles of tens of centimeters. With
`Imprint_Ground` on a terrain, `Terrain_Settings.lod_distance` covers the field's region (half of
its side plus how far the view moves away from its center) so that it is at level 0.

## Verification

- `mirai test plugins/imprint/runtime`: a stamp presses less the higher it is; a step leaves
  alternating footprints every `stride`.
- In the editor, with validation: with a body rolling on the ground, `capture` shows the
  furrow with its shadow and its edge; `profile.capture` gives the time of `imprint` in the
  `Geometry` stage.
