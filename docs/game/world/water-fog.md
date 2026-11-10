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
  {"name":"Creek","position":[30,0,-10],"components":{
    "Fluid":{"density":1000,"current":[0,0,-1.5]},"Water":{},
    "Shape":{"kind":"Spline","point_count":3,"loop_count":1,"loops":[3],
      "points":[[0,0],[6,-10],[0,-20]],"widths":[3,3,4],"heights":[1,1,1.2]}}}]}'
```

- A `Plane` volume is every point below the height of its entity, to the horizon: a sea. A `Box`
  volume (`extents` is half its size, times the scale of the entity) is water that ends at its
  walls, with its top face as the surface: a lake whose box fills its basin up to the water level,
  or a pool. Only its surface is drawn: the ground or a basin around it are its walls.
- A river is a `Fluid` on a `Spline` ([splines](splines.md), plugin `shapes`) instead of a `Volume`:
  the spline lies on the ground, and its water is the `height` of each point deep over it and as
  wide as the point, level across. The `current` of the `Fluid` is in the frame of the path: `-z`
  flows toward its last point, and what floats drifts with it. It ends at its first and last point.
  Where it runs into a lake or the sea, the one the physics takes there by `priority` is drawn (a
  `Volume` on the river gives only its priority).
- Density 1000 is fresh water, 1025 the sea; 0 is a dry box, the air of a room under the sea: give
  its `Volume` a higher `priority` than that of the water it cuts.
- `Fluid_Waves` makes waves on a sea, from the `Wind` of the world (a `Wind` with no
  `Volume` blows everywhere) and its own trains; bodies float on them and swimmers ride them.
- `Water` changes the look: its `material` (a `.mat`), how it absorbs and scatters light, shafts
  and caustics. Through the API, `{}` adds it at its starting value, `water.WATER_DEFAULT`.
- Code: `phys.Fluid{density=1025}` with `volume.plane()` is a sea, `phys.FLUID_DEFAULT` with
  `volume.box(half)` a pool, and `phys.Fluid{}` with `volume.box(half,priority=1)` a dry box.

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
  lake in the mountains is a `Box`, not a `Plane`.
- A `Fluid` without a `Volume`, in a sphere or the whole world, or with density 0 in a `Plane`, is
  not made (`physics.fluid`). Two fluids that meet at the same `priority`: `physics.fluid_overlap`.
- `Fluid_Waves` on a `Box` or a river makes no waves: the problem `physics.fluid_waves`.
- A river whose points have no width or no height, or sit at the same place seen from above, is
  not made (`physics.fluid_path`); one with too many points for its water says `shapes.spline`.
- A fog that hides the whole view is a `density` too high: lower it before touching exposure
  ([exposure.md](exposure.md)).
