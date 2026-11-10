# Swimming and the surface of the water

Water is a `phys.Fluid` in the `Volume` of its entity: an analytic volume with a surface that
physics answers for, the same one bodies float on and characters swim in. The `water` plugin draws
it (scene authoring: [world](../world.md)).

## A character that swims

Add `Swim` to the character prefab beside `Walk`; it starts from `phys.SWIM_DEFAULT` (`speed`,
`acceleration`, `depth`, `surface_offset`):

```json
{"method":"scene.write","params":{"root":"Player","merge":true,"entities":[{"components":{"Swim":{}}}]}}
```

- Walking or falling, it starts swimming where the water over the ground exceeds `Swim.depth`
  (over the feet when there is no ground) and walks again where it does not. No game code.
- On the surface it moves flat with its head `surface_offset` above the water; underwater it goes
  along the look, with `move` and the current. `jump` on the surface climbs out onto a ledge.
- Without `Walk` it never leaves swimming (a fish). A mode without its component is the problem
  `locomotion.mode_component`.
- `phys.Character.density` is the body's density in the fluid (a person floats; 0: no buoyancy).

## What it is in now

`core.Read(phys.Character_State)` of the character: `submersion` (0 to 1 of the body under the
surface), `head_depth` (m of the top of the head under the surface, negative above it), `depth`
(m of fluid over the feet), `fluid` (flags `In_Fluid`, `Underwater`) and `fluid_velocity`. Ending a
run when it falls in: [the rules of a game](../third-person/rules-test.md#the-rules).

## The surface at a point

```odin
// physics:core.Ref(phys.Physics_State); found is false with no simulation yet or no fluid there
sample,volume,found:=phys.fluid_at(physics,at)
under:=sample.density>0              // 0 above the surface and inside a dry box
// sample.height: world y of the surface; also sample.normal, sample.current;
// volume is the entity of the Fluid
```

`phys.fluid_at` includes the waves at the world's time, so a boat or a splash follows the drawn
sea. `phys.fluids_in(physics,box,out)` lists the volumes that touch a box and
`phys.fluid_bodies(physics,out)` the awake bodies in a fluid with their submerged volume, for
splashes and wakes (presentation only).

## Floating things

A dynamic body with a `Collider` floats by density against the volume's: `Collider.density`
below `Fluid.density` (1000 fresh, 1025 sea) floats. `Rigid_Body.gravity_scale` scales
buoyancy too. A volume's `current` carries what is in it.

## Pitfalls that fail silently

- No `Swim` on the prefab: the character wades and walks on the bottom.
- A dry box (a `Fluid` of density 0 in a `Box` volume) removes the fluid of lower `priority`
  inside it, the air of a base under the sea. Two fluids that meet at the same priority are the
  problem `physics.fluid_overlap`.
