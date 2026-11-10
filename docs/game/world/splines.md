# Splines: roads, paths and rivers

A road, a path and a river are one thing: a `Shape` of kind `Spline` (plugin `shapes`), a line of
points that lies on the ground. What it is comes from what its entity has:

| It is | The entity has |
| --- | --- |
| A road, a path, a trail | `Shape` (`Spline`) with the `material` of its surface |
| A river, a stream | `Shape` (`Spline`) and a `Fluid`; `water` draws it |

```sh
P="mirai rpc --project ."
$P scene.write '{"merge":true,"entities":[
  {"name":"Road","components":{"Shape":{"kind":"Spline","material":"surfaces/cobblestone/Cobblestone.mat",
    "uv_scale":0.5,"point_count":3,"loop_count":1,"loops":[3],
    "points":[[0,0],[8,-10],[0,-24]],"widths":[3,3,4],"heights":[0.04,0.04,0.04]}}},
  {"name":"Creek","position":[30,0,0],"components":{"Fluid":{"current":[0,0,-1.5]},
    "Shape":{"kind":"Spline","point_count":3,"loop_count":1,"loops":[3],
      "points":[[0,0],[6,-10],[0,-20]],"widths":[3,3,4],"heights":[1,1,1.2]}}}]}'
```

- `points` are in the plane of the entity seen from above: `[x, z]` of its frame; the curve goes
  through each of them, smooth, and ends at the first and the last. `point_count` is how many,
  and `loops` holds that one count.
- Each point has a width (`widths`, in metres from side to side) and a height (`heights`): how
  far over the ground that point lies. A road lies a few centimetres over it; a river is that deep.
- The spline lies on the ground under it (the terrain); where there is none, on the plane of its
  entity. It lies again by itself when the ground or the entity moves.
- A road follows the ground across too, and does not collide: what walks on it walks on the
  ground. Its texture runs along it, `uv_scale` repeats per metre.
- A river is level across, its `current` in the frame of the path (`-z` flows toward its last
  point), and floats and drifts what falls in it: [water](water-fog.md#water).
- In the editor: Create has a Spline card, and the Corners mode of the Shapes tool (key K, then
  2) drags, inserts (double click on the line) and removes (Ctrl click) its points; the panel
  shows the width and height of the last point taken. Through the API, `shapes.corner` does the
  same at world points and `scene.inspect` with `include_runtime` gives the points back.

## Pitfalls that fail silently

- A spline of one point, or a point without width: nothing is drawn, the problem `shapes.invalid`.
- A river whose points have no height has no water: `physics.fluid_path`.
- A spline with its entity far under or over the terrain still lies on it: the entity places
  only where it is seen from above.
