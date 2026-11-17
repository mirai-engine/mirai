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

A mesh that must be seen and not stop light (a sky dome, a card of glow, a shell around a lamp)
turns off `Mesh_Renderer.shadows`. A `Mesh_Renderer` starts from `render.MESH_RENDERER_DEFAULT`,
a cube that casts shadows, or a literal names its `shape` and `shadows`.

In the editor and through the API the same values are the entity's own in the material box of the
inspector, `material.instance.set`; `material.instance.apply` writes them into the material.

## A light that throws a pattern

Colored light through a window, the stripes of blinds or a logo on a wall come from a light that
projects a texture: the `texture` of a `Spot_Light` or a `Rect_Light` names a `.tex`, and its
color multiplies the light where each part of it falls.

```json
{"method":"scene.write","params":{"entities":[
 {"name":"Window light","components":{"Spot_Light":{"intensity":1000000,"range":30,
  "angle":0.4,"texture":"church/rose_window.tex"}}}]}}
```

- A spot lays its texture across its cone as a slide in a projector: seen from behind the light,
  looking along its -Z, the image is upright with its width along +X of the entity; the circle
  of the cone is inscribed in it. Turning the entity about its -Z turns the pattern. The pattern
  is as sharp as its texture however far it falls, as sunlight through a window: put the spot
  outside the window and aim it along the sun.
- A rectangle shows its texture across its face, seen from the side it lights: a surface near it
  takes the color of the part in front of it, a far one the mix of all of it. A window of stained
  glass is a `Rect_Light` the size of the window with its picture.
- What the light lights takes the pattern: surfaces, a fog it crosses (shafts of the colors of the
  window), and the light that bounces from them.
- A light without a texture costs what it did; one with a texture reads it once for each point it
  lights.
