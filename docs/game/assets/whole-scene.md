# A whole scene from a content tool

A [content tool](content-tool.md) writes a scene with the terrain, foliage and sea it shows, in
one run: there is no second step through the API, and nothing rewrites what the API made. Each
plugin adds its part to `asset.Scene_Builder`, a procedure that writes its asset and adds its
entity.

```odin
b:asset.Scene_Builder
asset.builder_init(&b,&c,asset.KIND_SCENE,asset.content_id(PROJECT,"scene","island"))
defer asset.builder_destroy(&b)
terrain.builder_terrain(&b,"Island",{file="assets/island/ground.terrain",samples=257,
    spacing=1,height=island_height,layers={{material=sand,tiling=6},
    {material=grass,automatic=true,height={2.6,40},slope={0,42},softness={6,1.2}}}})
foliage.builder_foliage(&b,"Plants",{file="assets/island/plants.foliage",
    generate={{at={0,0,0},radius=82}},
    types={{name="palm",mesh=palm,density=0.007,scale={0.8,1.25},align=0.15,
        rule=true,slope={0,28},ground_height={0.9,6.5},casts_shadow=true}}})
water.builder_sea(&b,"Sea")
asset.builder_save(&b,"assets/island/island.scene")
```

- `height` is a proc of x and z from the center of the terrain, the same a game can read as its
  ground truth; or `heights` with its rows, or neither for flat.
- A layer's `material` and a type's `mesh` are ids of what the tool wrote or imported before.
  Field names follow `terrain.layer` and `foliage.type_add`, angles in degrees.
- In a `foliage.Type_Desc`, a field left out takes the value of `foliage.type_add`, and `align`,
  `wind`, `yaw`, `tilt`, `weight`, `fade_distance` and `cull_distance` take 0 only when given.
- `water.builder_sea(&b,"Sea",look=look)` takes a `water.WATER_DEFAULT` with its colors changed,
  and `waves` a `phys.FLUID_WAVES_DEFAULT`.
- `file` paths are the tool's: a folder of the theme of the scene, created when missing, never a
  folder of kinds. The same code gives the same bytes every run.
- Materials a layer names can be written with `asset.material_save` in the tool too.
- Run the tool again rather than editing the scene through the API: running it rewrites the
  scene, so keep what you edit in the tool.
