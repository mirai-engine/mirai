# Low-poly props from code

A prop is a `geom.Mesh_Buffer` built in a few calls in the [content tool](content-tool.md):
every `geom.*_build` appends to the buffer, parts merge into one mesh, each part is painted
with one color and `asset.content_mesh` writes the `.mesh`. No OBJ, no import.

A palm and a bush:

```odin
palm_mesh :: proc(c:^asset.Content) -> base.Asset_Id {
    m:geom.Mesh_Buffer
    geom.mesh_buffer_init(&m,context.temp_allocator)
    trunk:=[3]geom.Vec3{{0,0,0},{0.3,3.5,0.1},{1.1,7.2,0.3}}
    geom.tube_build(&m,trunk[:],{0.32,0.14},sides=7,rings=8)
    geom.mesh_buffer_paint(&m,{0.42,0.30,0.18,1})
    geom.fan_build(&m,trunk[2],10,{length=4.6,width=1.1,rise=1.6,droop=4,belly=0.25,fold=0.06},seed=5)
    geom.mesh_buffer_paint(&m,{0.20,0.52,0.14,1})
    geom.mesh_buffer_flatten(&m)                           // cut facets instead of smooth shading
    return asset.content_mesh(c,"assets/island/palm.mesh",&m)
}

bush_mesh :: proc(c:^asset.Content) -> base.Asset_Id {
    m:geom.Mesh_Buffer
    geom.mesh_buffer_init(&m,context.temp_allocator)
    for i in 0..<3 {
        at:=len(m.positions)
        geom.blob_build(&m,{0.9,0.75,0.9},subdivisions=1,lumps=0.22,seed=u32(i+1))
        geom.mesh_buffer_place(&m,at,{f32(i)*0.7-0.7,0.6+f32(i%2)*0.25,0.3*f32(i-1)})
    }
    geom.mesh_buffer_paint(&m,{0.16,0.46,0.16,1})
    geom.mesh_buffer_flatten(&m)
    return asset.content_mesh(c,"assets/island/bush.mesh",&m)
}
```

Put them in the scene as foliage types ([whole-scene.md](whole-scene.md)) or
on an entity with `render.Mesh_Renderer{mesh=palm_mesh(c)}`. The asset folder is the theme of what
it belongs to (`assets/island/`), never its kind.

| Call | Makes |
| --- | --- |
| `tube_build(m,path,radius,sides,rings)` | A tapered, bent trunk through the points of `path` |
| `lathe_build(m,profile,segments)` | A jar, a post, a mushroom: `profile` is radius and height |
| `extrude_build(m,outline,depth)` | A sign or a plank: a polygon in X and Y, thick along Z |
| `blade_build(m,root,direction,blade)` | One leaf or blade of grass, both faces |
| `fan_build(m,root,count,blade,splay,seed)` | A palm crown or a tuft (`splay` 0 up, 1 level) |
| `blob_build(m,radius,subdivisions,lumps,seed)` | A lumpy rock or bush |

- `cube_build`, `sphere_build`, `icosphere_build`, `cylinder_build`, `cone_build`, `capsule_build`
  and `plane_build` take the same buffer.
- `mesh_buffer_paint(m,color)` colors what was built since the last paint.
- Parts built at the origin are moved with `mesh_buffer_place(m,first,at,turn,size)`.
- `asset.content_mesh(c,path,&m,material)` gives the mesh a `.mat`; without one the
  mesh shows its colors on the default material. Its id is the same on every run.
- A mesh that foliage scatters: the red of its colors weighs how far the wind moves each vertex,
  so give a stiff prop `wind=0`.
