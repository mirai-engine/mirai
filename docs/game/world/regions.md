# Regions: a Volume and what happens in it

A place of the world where something happens is one entity with two components: a `Volume`
(`mirai:engine/volume`), which says where, and the component of what happens there. No other
component has a shape, a size or a priority of its own.

```sh
P="mirai rpc --project ."
$P scene.add '{"name":"Low gravity room","position":[0,3,0],"components":{
  "Volume":{"shape":"Box","extents":[5,3,5],"blend":1,"priority":1},"Gravity":{"acceleration":2}}}'
$P scene.add '{"name":"Lift","position":[8,2,0],"components":{
  "Volume":{"shape":"Box","extents":[1,2,1]},"Force_Field":{"force":400,"along":[0,1,0]}}}'
$P scene.add '{"name":"Sea","components":{"Volume":{"shape":"Plane"},"Fluid":{"density":1025}}}'
```

## The Volume

- `shape`: `Box` (`extents` is half its size on each axis), `Sphere` (`extents[0]` is its radius),
  `Plane` (everything under the entity; its up, +Y, says where under is) or `Unbounded` (the whole
  world). Box and sphere scale with the entity, and all turn with it.
- `blend`: metres inside the border over which its weight rises from 0 to 1. `priority`: the
  higher goes on top; among equals the smaller volume wins. `mode`: `Replace` what is below, or
  `Add` to it.
- In code: `volume.box(half)`, `volume.sphere(radius)`, `volume.plane()` and `volume.world()`, each
  with optional `blend` and `priority`.
- The editor draws the selected `Volume` whatever is in it.

## What can happen in it

- `Gravity`, `Wind`, `Audio_Reverb`, `View_Volume`, `Fog_Volume`: the value rules there, blended
  and by priority, in any shape. Without a `Volume` it rules the whole world.
- `phys.Fluid`: water, where bodies float and characters swim ([water](water-fog.md)); density 0
  is a dry box. A `Plane` or a `Box`; without one, the problem `physics.fluid`.
- `phys.Force_Field`: pushes the bodies there each tick, in any shape. Without a `Volume` it
  pushes everywhere.
- `destruct.Strain_Field`: strains the destructibles there each tick. A `Box` or a `Sphere`;
  without one, the problem `destruct.strain_field`.
- `Environment_Trigger`: turns on a sky and a sun when the player's body enters, in any shape.
  Without a `Volume` it is on from the start.
- `nav.Nav_Bounds`, `nav.Nav_Area`, `nav.Nav_Obstacle`: where navmeshes are made, an area with a
  cost, a blocker ([ai](../ai.md)). A `Box`; without one, the problem `navigation.volume`.
- `foliage.Foliage_Bender`: leans the grass around a body. A `Sphere`; without one, the problem
  `foliage.bender_volume`.

Several of them on one entity share its `Volume`: a `Force_Field` and a `Strain_Field` make a
field that pushes and breaks.

## A force for one tick

A blast, a gust or a pull is the same region without an entity:

```odin
import volume "mirai:engine/volume"
import phys "plugins:physics/runtime"

// bodies:^phys.Body_Requests. 35 m/s away from the point, fading to nothing 4 m from it.
phys.apply_area(bodies,volume.sphere(4,blend=4),{position=point},35,impulse=true,velocity_change=true)
// 200 N along +X on what is in a box turned as `pose`.
phys.apply_area(bodies,volume.box({2,1,2}),pose,200,along={1,0,0})
```

- The strength is newtons; with `impulse` newton seconds, and with `velocity_change` metres per
  second whatever the mass. Negative pulls toward the center.
- Without `along` it pushes away from the center of the volume, and along the up of a `Plane`.
- A body gets the strength times the weight of the volume where its center of mass is: 1 inside,
  rising over `blend` from the border. `falloff` bends that rise, `range` and `noise` scale it;
  `filter` chooses the collision categories.

## Asking a region yourself

```odin
v,pose,ok:=volume.placed(volumes,worlds,e)   // the Volume of e where it is
inside:=ok && volume.holds(v,pose,point)
weight:=volume.weight(v,pose,point)          // 0 outside, 1 inside, between over its blend
meets:=volume.overlaps(v,pose,box)           // a box of the world
```

`volume.at` gives a zone value at a point with every volume applied; `volume.wind_at` the wind.

## Pitfalls that fail silently

- An `Unbounded` volume with extents rules everywhere: the problem `volume.unbounded_extents`.
- A `Plane` whose entity is at the wrong height: everything below it is in the region.
- An area request with a volume without size, or values that are not finite, does nothing: the
  problem `physics.request_area`.
- A sphere with `blend` 0 pushes with full strength up to its border; give it `blend` equal to its
  radius for a blast that fades.
