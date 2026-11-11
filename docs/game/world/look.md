# The look of one entity

`render.Material_Values` is what one entity shows of its materials: a color, a light and values
by name. The material file does not change, nor any other entity that shows it.

```odin
import "mirai:core"
import "mirai:engine/render"

// Heats an entity: redder, glowing, and rougher in its first material.
heat :: proc(looks:^core.Table(render.Material_Values),e:core.Entity,amount:f32) {
    values,has:=core.get(looks,e)
    if !has {values=render.MATERIAL_VALUES_DEFAULT}
    values.color={1,1-0.5*amount,1-0.5*amount,1}
    values.emission={40*amount,4*amount,0}
    render.material_value(&values,"roughness",0.4+0.5*amount)
    core.add(looks,e,values)
}
```

- `color` multiplies the base color of every material of the entity; an alpha below 1 fades it.
  `emission` is light added to them, in nits.
- `material_value(&values,name,value,slot)` gives one value to the material of a slot of the mesh
  (0 when omitted): a number, or up to four in braces (`{1,0,0,0}` is red). The name is a
  parameter of the Surface program of that material, or a value of the standard model:
  `base_color`, `opacity`, `metallic`, `roughness`, `emission`. `material_value_drop` takes it
  away, and the one of the material shows again. Slots that show the same material share it.
- An entity holds up to 16 values. It returns false past that, for a slot the mesh cannot have or
  for a value that is not finite.
- Start from what the entity has or from `render.MATERIAL_VALUES_DEFAULT`, never from `{}`: a
  zero color is black and its zero alpha hides the entity.
- An entity that already has the component is changed in place:
  `render.material_value(core.edit(looks,e),"dissolve",t)`, in a function that writes the table.

## What it costs

A color and its alpha, a light, a program parameter and a value of the standard model are a few
bytes the entity holds: change them every frame on a thousand entities. A texture takes a copy of
the material that the entities giving the same share: set it once, do not animate it on many
entities. To show another material, change `Mesh_Renderer.materials`.

In the editor and through the API the same values are the entity's own in the material box of the
inspector, `material.instance.set`; `material.instance.apply` writes them into the material.
