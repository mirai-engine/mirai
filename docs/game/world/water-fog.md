# Water, fog and haze

## Water

Water is a physics `Fluid_Volume`: bodies float on it, characters swim in it
([character](../character.md)). The `water` plugin draws every volume as water
(add `"water"` to `plugins`; it brings `fog`). Without the plugin the volume still simulates and is
invisible.

```sh
P="mirai rpc --project ."
$P scene.add '{"name":"Sea","position":[0,2,0],"components":{
  "Fluid_Volume":{"shape":"Plane","density":1025},"Water":{},"Fluid_Waves":{}}}'
$P scene.add '{"name":"Breeze","components":{"Wind":{"speed":6,"gusts":0.5}}}'
$P scene.add '{"name":"Pond","position":[30,0,10],"components":{
  "Fluid_Volume":{"shape":"Box","size":[6,1.5,4],"density":1000},"Water":{}}}'
```

- A `Plane` is every point below the height of its entity: put the entity at the water level, and
  sculpt the terrain under that height to make a sea, a lake or a shore. A `Box` (`size` is half
  the extents, times the scale of the entity) is a pool whose top face is the surface; it has no
  waves.
- Density 1000 is fresh water, 1025 the sea; 0 is a dry box, the air of a room under the sea
  (`phys.fluid_volume_dry`, a higher `priority` than the water it cuts).
- `Fluid_Waves` on a plane makes waves, from the `Wind` of the world (a `Wind` entity with no
  `Volume` blows everywhere) and its own trains; bodies float on them and swimmers ride them.
- `Water` changes the look: its `material` (a `.mat`), how it absorbs and scatters light, shafts
  and caustics. A zeroed `Water` is not the default: add it with `{}` (the
  starting value) or copy `water.WATER_DEFAULT`.
- Code: `phys.fluid_volume_sea(1025)`, `phys.fluid_volume_box(half_extents)` and
  `phys.fluid_volume_dry(half_extents)` give a `Fluid_Volume`.

## Fog and haze

`Fog_Volume` (plugin `fog`) is a medium that dims what is behind it and shows the shafts of the
sun and lights through it. With no `Volume` on its entity it fills the world; with one (box or
sphere, `blend`, `priority`) only that place.

```sh
$P scene.add '{"name":"Haze","components":{"Fog_Volume":{"density":0.004,"color":[0.8,0.85,0.9]}}}'
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
- A `Fluid_Volume` with density 0 and `Plane` shape is not made (`physics.fluid`).
- `Fluid_Waves` on a `Box` makes no waves: the problem `physics.fluid_waves`.
- A fog that hides the whole view is a `density` too high: lower it before touching exposure
  ([exposure.md](exposure.md)).
