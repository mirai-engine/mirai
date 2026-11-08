# Terrain and foliage

Ground is a `Terrain` entity and vegetation a `Foliage` entity: assets (`.terrain`, `.foliage`)
the plugins stream, draw with levels of detail and collide. Add `"terrain"` and `"foliage"` to
`plugins` in `project.mirai`. Never make ground or vegetation from cubes, planes or imported
meshes placed one by one: they do not stream, paint, scatter or collide as these do.

Needs an open session (`mirai session start .`); each call is an undo step and stays in memory
until saved. `mirai rpc --project . describe terrain.create` lists every parameter. `ID` is the
`id` the `create` call returned.

## Ground

```sh
P="mirai rpc --project ."
$P terrain.create '{"kind":"heightfield","samples":257,"spacing":2,"height_scale":60}'
# -> {"id":ID,...}; from a heightmap: '{"kind":"heightfield","heightmap":"source/hills.png"}'
$P terrain.edit '{"id":ID,"brush":"noise","at":[256,0,256],"radius":200,"scale":40}'
$P terrain.edit '{"id":ID,"brush":"flatten","at":[0,0,0],"radius":12}'
$P terrain.layer '{"id":ID,"material":"<asset id of a .mat>","tiling":4}'
$P terrain.layer '{"id":ID,"material":"<rock .mat>","automatic":true,"slope":[35,90]}'
$P asset.save '{"all":true}'; $P scene.save '{}'
```

- Kinds: `heightfield` (heights over x and z: hills, valleys, plains), `mesh` (a 3D terrain: caves
  and overhangs) and `volume` (solid and air: digging). Size is `samples` minus 1 times `spacing`.
- Brushes of `terrain.edit`: `raise`, `lower`, `smooth`, `flatten`, `set_height`, `ramp` (from `at`
  to `to`), `terrace`, `noise`, `erode`, `paint` and `erase` (a layer), `hole`, `fill`. A stroke
  goes from `at` to `to`; `radius`, `strength`, `falloff`, `passes` shape it.
- `terrain.layer` adds a material layer (up to four) or changes the one at `index`; an
  `automatic` layer covers where the slope (degrees) and `height` (metres) are in its ranges, so
  rock lands on steep faces and grass on flat ones with no painting. Layer materials are `.mat`
  assets: import a PBR texture set ([assets](../assets.md)) and read the ids
  with `asset.list`.
- `terrain.sample {id,at}` reads what is under a point; `terrain.heightmap` imports or exports a
  16-bit PNG; `terrain.resize` changes the samples.
- `Terrain.solid` makes the ground collide (the default of a new one); a character walks on it.

## Vegetation

```sh
$P foliage.create '{}'                                      # -> {"id":ID}
$P foliage.type_add '{"id":ID,"mesh":"<asset id of a .mesh>"}'   # -> {"type":N}
$P foliage.type_set '{"id":ID,"type":N,"name":"pine","density":0.05,
  "scale":[0.8,1.4],"yaw":360,"align":0.3,"rule":true,"slope":[0,30],"wind":0.5}'
$P foliage.paint '{"id":ID,"mode":"generate","at":[256,0,256],"radius":200}'
```

- `foliage.type_add` makes a type from a `.mesh`; `type_set` changes only the fields it names
  (`describe` lists them): how dense, how large, turned and leaned it is, a `rule` that confines
  it by slope, height and terrain layers, its distances, `wind` and shadow.
- `mode`: `generate` turns on the generator of the cells under the ring (large radii cover a
  whole terrain; `ungenerate` off), `paint` and `erase` place or remove manual instances (a
  `ground_only` paint stays on the terrain), `reapply` redoes scale and turn. `foliage.place` puts
  one instance, `foliage.query` lists types and instances.
- Foliage stands on the terrain by itself (`foliage_terrain`) and follows it when it is sculpted.
  Far away it becomes impostors; collision is per type.
- A `Wind` component (`volume`) on any entity makes foliage sway; `wind` on a type scales it.

## Pitfalls that fail silently

- Nothing shows after `foliage.create`: it has no types until `type_add`, and no instances until
  `generate` or `paint` has run over the area.
- Foliage placed away from the terrain or over a hole has no ground and generates nothing.
- Unsaved terrain and foliage are lost with the session: `asset.save` and `scene.save`.
- A `rule` with `slope` but no `rule: true` is ignored; `layers` 0 means any layer.
