# Splines: roads, paths and rivers

A road, a path and a river are one thing: a `Spline` (`engine/volume`), a line of points that
lies on the ground. What it is comes from what its entity has, as a `Volume` is a region and
what happens in it is another component:

| It is | The entity has |
| --- | --- |
| A road, a path, a trail | `Spline` with the `material` of its surface (plugin `shapes` draws it) |
| A river, a stream | `Spline` and a `Fluid` (plugin `physics`); `water` draws it |
| A route that nothing draws (a patrol) | `Spline` alone |

```sh
P="mirai rpc --project ."
$P scene.write '{"merge":true,"entities":[
  {"name":"Road","components":{"Spline":{"material":"surfaces/cobblestone/Cobblestone.mat","count":3,
    "points":[{"position":[0,0,0],"width":3,"height":0.04},{"position":[8,0,-10],"width":3,"height":0.04},
      {"position":[0,0,-24],"width":4,"height":0.04}]}}},
  {"name":"Creek","position":[30,0,0],"components":{"Fluid":{"current":[0,0,-1.5]},
    "Spline":{"count":3,"points":[{"position":[0,0,0],"width":3,"height":1},
      {"position":[6,0,-10],"width":3,"height":1},{"position":[0,0,-20],"width":4,"height":1.2}]}}}]}'
```

- `points` are in the frame of the entity; the curve goes through each of them, smooth, and ends
  at the first and the last. `count` is how many.
- Each point has a width (in metres from side to side) and a height: how far over the ground that
  point lies. A road lies a few centimetres over it; a river is that deep.
- The spline lies on the ground under it (the terrain); where there is none, where its points
  are. It lies again by itself when the ground or the entity moves.
- A road follows the ground across too, and does not collide: what walks on it walks on the
  ground. Its texture runs along it in metres; the `uv_scale` of its material sets how often it
  repeats.
- A river is level across, its `current` in the frame of the path (`-z` flows toward its last
  point), and floats and drifts what falls in it: [water](water-fog.md#water). Give it no
  `material`.
- In the editor: Create has a Spline card, a selected spline shows its points, and the Corners
  mode of the Shapes tool (key K, then 2) drags, inserts (double click on the line) and removes
  (Ctrl click) them; the panel shows the width and height of the last point taken. Through the
  API, `shapes.corner` does the same at world points.

## Pitfalls that fail silently

- A spline of one point, or a point without width: no road is drawn, the problem
  `shapes.invalid`; no river is made, the problem `physics.fluid_path`.
- A spline without a material and without a `Fluid` draws nothing: it is a route for code.
- A spline on an entity that also has a `Shape` is not drawn: the problem `shapes.both`.
- A spline with its entity far under or over the terrain still lies on it: the entity places
  only where it is seen from above.
