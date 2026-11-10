# Water, fog and haze

## Water

Water is a physics `Fluid` in the `Volume` of its entity ([regions](regions.md)): bodies float on
it, characters swim in it ([character](../character.md)). The `water` plugin draws every fluid as
water (add `"water"` to `plugins`; it brings `fog`). Without the plugin the fluid still simulates
and is invisible.

```sh
P="mirai rpc --project ."
$P scene.add '{"name":"Sea","position":[0,2,0],"components":{
  "Volume":{"shape":"Plane"},"Fluid":{"density":1025},"Water":{},"Fluid_Waves":{}}}'
$P scene.add '{"name":"Breeze","components":{"Wind":{"speed":6,"gusts":0.5}}}'
$P scene.add '{"name":"Pond","position":[30,0,10],"components":{
  "Volume":{"shape":"Box","extents":[6,1.5,4]},"Fluid":{"density":1000},"Water":{}}}'
```

- A `Plane` volume is every point below the height of its entity: put the entity at the water
  level, and sculpt the terrain under that height to make a sea, a lake or a shore. A `Box` volume
  (`extents` is half its size, times the scale of the entity) is a pool whose top face is the
  surface; it has no waves. A fluid stays level: only the yaw of the entity turns it.
- Density 1000 is fresh water, 1025 the sea; 0 is a dry box, the air of a room under the sea: give
  its `Volume` a higher `priority` than that of the water it cuts.
- `Fluid_Waves` on a plane makes waves, from the `Wind` of the world (a `Wind` entity with no
  `Volume` blows everywhere) and its own trains; bodies float on them and swimmers ride them.
- `Water` changes the look: its `material` (a `.mat`), how it absorbs and scatters light, shafts
  and caustics. A zeroed `Water` is not the default: add it with `{}` (the
  starting value) or copy `water.WATER_DEFAULT`.
- Code: `phys.Fluid{density=1025}` with `volume.plane()` is a sea, `phys.FLUID_DEFAULT` with
  `volume.box(half)` a pool, and `phys.Fluid{}` with `volume.box(half,priority=1)` a dry box.

## Fog and haze

`Fog_Volume` (plugin `fog`) is a medium that dims what is behind it and shows the shafts of the
sun and lights through it. With a `Volume` on its entity (box or sphere, `blend`, `priority`) it
stays in that place. **With no `Volume` it fills the world and the sky too**: the sky is infinitely
far, so even a small density replaces it with the color of the fog, a milky gray over a clear day.
For a clear day leave fog out; for haze near the ground give it a `Volume` with `falloff`, as
below.

```sh
$P scene.add '{"name":"Valley mist","position":[0,0,0],"components":{
  "Volume":{"shape":"Box","extents":[100,8,100]},"Fog_Volume":{"density":0.03,"falloff":0.2,
  "variable":true,"wisp_size":20,"drift":[0.5,0,0.2]}}}'
```

- `density` is per metre, about the share of light stopped by each metre; the starting value is a
  heavy fog, and haze is a fraction of it. `anisotropy` above 0 scatters forward: the sun glows
  seen through it. `falloff` thins it with height over the base of its `Volume`: ground mist.
- `variable` makes wisps and banks that drift and change by themselves; `density` is their mean.

## Pitfalls that fail silently

- A `Plane` with the entity at the wrong height: everything below it is water, even a cellar.
- A `Fluid` without a `Volume`, in a sphere or the whole world, or with density 0 in a `Plane`, is
  not made (`physics.fluid`). Two fluids that meet at the same `priority`: `physics.fluid_overlap`.
- `Fluid_Waves` on a `Box` makes no waves: the problem `physics.fluid_waves`.
- A fog that hides the whole view is a `density` too high: lower it before touching exposure
  ([exposure.md](exposure.md)).
