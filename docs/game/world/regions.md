# Regions: a Volume and what happens in it

A place of the world where something happens is one entity with two components: a `Volume`
(`mirai:engine/volume`), which says where and is only a shape, and the component of what happens
there, which keeps its own numbers. No other component has a shape or a size of its own.

```sh
P="mirai rpc --project ."
$P scene.write '{"entities":[
  {"name":"Low gravity room","position":[0,3,0],"components":{
    "Volume":{"shape":"Box","extents":[5,3,5]},
    "Gravity":{"acceleration":2,"zone":{"blend":1,"priority":1}}}},
  {"name":"Lift","position":[8,2,0],"components":{
    "Volume":{"shape":"Box","extents":[1,2,1]},"Force_Field":{"force":400,"along":[0,1,0]}}},
  {"name":"Sea","components":{"Volume":{"shape":"Plane"},"Fluid":{"density":1025}}}]}'
```

## The Volume

- `shape`: `Box` (`extents` is half its size on each axis), `Sphere` (`extents[0]` is its radius),
  `Plane` (everything under the entity; its up, +Y, says where under is) or `Unbounded` (the whole
  world; under a streamed section, the box of that section). Box and sphere scale with the entity,
  and all turn with it.
- In code: `volume.box(half)`, `volume.sphere(radius)`, `volume.plane()` and `volume.world()`.
- The editor draws the selected `Volume` whatever is in it.

## What can happen in it

- `Gravity`, `Wind`, `Audio_Reverb`, `View_Volume`, `Fog_Volume`, `Lens_Volume`: the value rules
  there, in any shape but a fog, which needs an end. Its `zone` says how it meets the others:
  `blend`, metres inside the border over which its weight rises from 0 to 1; `priority`, the
  higher goes on top and among equals the smaller volume wins; `mode`, `Replace` what is below or
  `Add` to it. Without a `Volume` it rules the whole world.
- `phys.Fluid`: water, where bodies float and characters swim ([water](water-fog.md)); density 0
  is a dry box, and its `priority` decides where fluids meet. A `Plane` or a `Box`; without one,
  the problem `physics.fluid`.
- `phys.Force_Field`: pushes the bodies there each tick, rising over its `blend`, in any shape.
  Without a `Volume` it pushes everywhere.
- `destruct.Strain_Field`: strains the destructibles there each tick. A `Box` or a `Sphere`;
  without one, the problem `destruct.strain_field`.
- `nav.Nav_Bounds`, `nav.Nav_Area`, `nav.Nav_Obstacle`: where navmeshes are made, an area with a
  cost, a blocker ([ai](../ai.md)). A `Box` or a `Sphere`; without one, the problem
  `navigation.volume`.
- `foliage.Foliage_Bender`: leans the grass around a body, as far as its volume reaches.

Several of them on one entity share its `Volume`: a `Force_Field` and a `Strain_Field` make a
field that pushes and breaks.

## Something went in

With the plugin `physics`, a `Box` or `Sphere` volume on an entity without a `Collider` reports the
bodies that go in and out of it, as `phys.Physics_Events.overlap_begin` and `overlap_end` with the
zone as `event.collider` ([triggers](../character/platforms-triggers.md#trigger-zones)). What
entering does is game code on that event; a sky that changes in a passage:

```odin
@(component) Sky_Zone :: struct {sky,sun:core.Entity, seconds:f32}

@(step="fixed",stage="react")
game_sky_zones :: proc(zones:^core.Table(Sky_Zone,.Read),seats:^core.Table(input.Seat,.Read),
                       events:core.Ref(phys.Physics_Events),requests:^render.Environment_Requests) {
    for event in events.overlap_begin.items {
        zone:=core.get(zones,event.collider) or_continue
        if input.seat_of(seats,event.other)==core.NONE {continue}
        render.activate(requests,zone.sky,zone.sun,zone.seconds)
    }
}
```

## A force for one tick

A blast, a gust or a pull is the same region without an entity:

```odin
import volume "mirai:engine/volume"
import phys "plugins:physics/runtime"

// bodies:^phys.Body_Requests. 35 m/s away from the point, fading to nothing 4 m from it.
phys.apply_area(bodies,volume.sphere(4),{position=point},35,impulse=true,velocity_change=true,
               blend=4)
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
zones:=volume.Where{volumes,worlds,parents,sections} // the tables a step receives
v,pose,ok:=volume.placed(zones,e)                    // the Volume of e where it is
inside:=ok && volume.holds(v,pose,point)
weight:=volume.weight(v,pose,point,blend)            // 0 outside, 1 inside, between over blend
meets:=volume.overlaps(v,pose,box)                   // a box of the world
```

`volume.at` gives a zone value at a point with every volume applied; `volume.wind_at` the wind.

## Pitfalls that fail silently

- An `Unbounded` volume with extents rules everywhere: the problem `volume.unbounded_extents`.
- A `Plane` whose entity is at the wrong height: everything below it is in the region.
- An area request with a volume without size, or values that are not finite, does nothing: the
  problem `physics.request_area`.
- A sphere with `blend` 0 pushes with full strength up to its border; give it `blend` equal to its
  radius for a blast that fades.
- A `Volume` on an entity that has a `Collider` reports nothing by itself: the collider is the
  shape the physics sees there.
