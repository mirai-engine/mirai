# Water, fog and haze

## Water

Water is a physics `Fluid` in the `Volume` of its entity ([regions](regions.md)): bodies float on
it, characters swim in it ([character](../character.md)). The `water` plugin draws every fluid as
water (add `"water"` to `plugins`; it brings `fog`). Without the plugin the fluid still simulates
and is invisible.

```sh
P="mirai rpc --project ."
$P scene.write '{"merge":true,"entities":[
  {"name":"Sea","position":[0,2,0],"components":{
    "Volume":{"shape":"Plane"},"Fluid":{"density":1025},"Water":{},"Fluid_Waves":{}}},
  {"name":"Breeze","components":{"Wind":{"speed":6,"gusts":0.5}}},
  {"name":"Pond","position":[30,0,10],"components":{
    "Volume":{"shape":"Box","extents":[6,1.5,4]},"Fluid":{"density":1000},"Water":{}}},
  {"name":"Lake","position":[-40,1,0],"components":{
    "Volume":{"shape":"Outline","extents":[0,2,0]},"Fluid":{"density":1000},"Water":{},
    "Spline":{"count":5,"points":[{"position":[0,0,0]},{"position":[24,0,-4]},
      {"position":[30,0,10]},{"position":[12,0,8]},{"position":[4,0,20]}]}}},
  {"name":"Creek","position":[30,0,-10],"components":{
    "Fluid":{"density":1000},"Water":{},
    "Spline":{"count":3,"points":[{"position":[0,0,0],"width":3,"height":1,"speed":1.5},
      {"position":[6,0,-10],"width":3,"height":1,"speed":2.5},
      {"position":[0,0,-20],"width":4,"height":1.2,"speed":1}]}}}]}'
```

- A `Plane` volume is every point below the height of its entity, to the horizon: a sea. An
  `Outline` volume is a lake: the water over the loop of the points of the `Spline` of its entity
  (their `x` and `z`, straight from each to the next and from the last back to the first), from
  `extents.y` under the entity to `extents.y` over it, the top being the surface. Put the points
  on the shore, under the hills around it: what is outside the loop is dry, a cave beside the lake
  too. A `Box` volume (`extents` is half its size, times the scale of the entity) is the same with
  a rectangle: a pool. Only the surface is drawn: the ground or a basin around it are its walls.
- A river is a `Fluid` on a `Spline` ([splines](splines.md)) instead of a `Volume`:
  each point lies on the ground, and its water is the `height` of the point deep over it and as
  wide as the point, level across, flowing toward the last point at the `speed` of the point; what
  floats drifts with it. Its surface never rises from the first point to the last. The `current`
  of the `Fluid` adds a flow across (`x`, to its right) and up; its `z` stays 0. It ends at its
  first and last point. A body in two waters at once, across the mouth of a river, floats in both.
  Where it runs into a lake or the sea, the one the physics takes there by the `priority` of each
  `Fluid` is drawn.
- Density 1000 is fresh water, 1025 the sea; 0 is a dry box, the air of a room under the sea: give
  its `Fluid` a higher `priority` than that of the water it cuts.
- `Fluid_Waves` makes waves on a sea or a lake, from the `Wind` of the world (a `Wind` with no
  `Volume` blows everywhere) and its own trains; bodies float on them and swimmers ride them.
- `Water` changes the look: its `material` (a `.mat`), how it absorbs and scatters light, shafts
  and caustics. Through the API, `{}` adds it at its starting value, `water.WATER_DEFAULT`.
- Code: `phys.Fluid{density=1025}` with `volume.plane()` is a sea, `phys.FLUID_DEFAULT` with
  `volume.outline(depth)` and a `volume.Spline` a lake, with `volume.box(half)` a pool, and
  `phys.Fluid{priority=1}` with `volume.box(half)` a dry box.

## Fog and haze

`Fog_Volume` (plugin `fog`) is a medium that dims what is behind it and shows the shafts of the
sun and lights through it, in the `Volume` of its entity: a box, a sphere or everything under a
plane (`blend`, `priority`). Particles and smoke behind it are fogged as the scene is. The haze
over the whole world, out to the sky, is not a fog: it is the air of the `Sky` (raise its `mie`
for a hazier day). A `Fog_Volume` without a `Volume`, or with one of shape `Unbounded`, fills
nothing (`fog.volume`).

```sh
$P scene.write '{"merge":true,"entities":[{"name":"Valley mist","position":[0,0,0],"components":{
  "Volume":{"shape":"Box","extents":[100,8,100]},"Fog_Volume":{"density":0.03,"falloff":0.2,
  "variable":true,"wisp_size":20,"drift":[0.5,0,0.2]}}}]}'
```

- `density` is per metre, about the share of light stopped by each metre; the starting value is a
  heavy fog, and haze is a fraction of it. `anisotropy` above 0 scatters forward: the sun glows
  seen through it. `falloff` thins it with height over the base of its `Volume`: ground mist.
- `variable` makes wisps and banks that drift and change by themselves; `density` is their mean.

## Pitfalls that fail silently

- A `Plane` with the entity at the wrong height: everything below it is water, even a cellar. A
  lake in the mountains is an `Outline`, not a `Plane`.
- A `Fluid` without a `Volume`, in a sphere or the whole world, or with density 0 in a `Plane`, is
  not made (`physics.fluid`); an `Outline` without a `Spline` of 3 to 64 points that close some
  area holds nothing (`volume.outline`). Two fluids that meet at the same `priority`:
  `physics.fluid_overlap`.
- `Fluid_Waves` on a river makes no waves: the problem `physics.fluid_waves`.
- A fog, a wind on particles and grass, a gravity on particles: the shaders take no `Outline`
  (a fog in one is `fog.volume`); give them a `Box`, a `Sphere` or a `Plane`.

- A river whose points have no width or no height, or sit at the same place seen from above, or
  whose `Fluid` has a `current` along it (`z`), is not made (`physics.fluid_path`).
- A fog that hides the whole view is a `density` too high: lower it before touching exposure
  ([exposure.md](exposure.md)).
