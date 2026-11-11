# Terrain and foliage

Ground is a `Terrain` entity and vegetation a `Foliage` entity: assets (`.terrain`, `.foliage`)
the plugins stream, draw with levels of detail and collide. Add `"terrain"` and `"foliage"` to
`plugins` in `project.mirai`. Never make ground or vegetation from cubes, planes or imported
meshes placed one by one: they do not stream, paint, scatter or collide as these do.

Name what you make: later calls find it by that name, so one `batch` file builds a
whole scene, with no ids to pass between calls ([whole-scene.md](../assets/whole-scene.md)).

## Ground

```sh
P="mirai rpc --project ."
$P terrain.create '{"name":"Hills","samples":257,"spacing":2,"height_scale":60}'
# from a heightmap of the project: '{"name":"Hills","heightmap":"assets/hills.png"}'
$P terrain.edit '{"entity":"Hills","brush":"noise","at":[256,0,256],"radius":200,"scale":40}'
$P terrain.edit '{"entity":"Hills","brush":"flatten","at":[0,0,0],"radius":12}'
$P terrain.layer '{"entity":"Hills","material":"hills/grass.mat","tiling":4}'
$P terrain.layer '{"entity":"Hills","material":"hills/rock.mat","automatic":true,"slope":[35,90]}'
$P asset.save '{"all":true}'; $P scene.save '{}'
```

- Kinds: `heightfield` (heights over x and z: hills, valleys, plains) and `volume` (solid and
  air: caves, overhangs and digging, as large as the ground needs). Size is `samples` minus 1
  times `spacing`. `name` names the entity and its file, which goes beside the scene.
- Brushes of `terrain.edit`, the same on both kinds: `raise`, `lower`, `smooth`, `flatten`,
  `set_height`, `noise`, `paint` and `erase` (a layer), and `add` and `carve`, which join or take
  out a `shape` (`sphere`, `capsule` to `to`, `box`). Of a heightfield alone: `ramp` (from `at` to
  `to`), `terrace`, `erode`, `hole`, `fill`. A stroke goes from `at` to `to`; `radius`,
  `strength`, `falloff`, `passes` shape it. A brush the kind lacks or a value out of range
  answers what failed and what to use.
- In game code one call digs whatever ground is under it:
  `terrain.dig(requests, {kind=.Carve, center=point, radius=2, amount=1})` returns what is wrong
  with the brush (`terrain.edit_error_fix` says how to fix it), and what it took out comes in
  `Terrain_Digs`.
- `terrain.layer` adds a material layer (up to four) or changes the one named `layer` by its
  material (its path or stem; `default` is one without a material); an `automatic` layer covers
  where the slope (degrees) and `height` (metres) are in its ranges, so rock lands on steep faces
  and grass on flat ones with no painting. Layer materials are `.mat`
  assets: import a PBR texture set ([assets](../assets.md)) and give their paths.
- `terrain.sample {entity,at}` reads what is under a point; `terrain.heightmap` imports or exports a
  16-bit PNG; `terrain.resize` changes the samples.
- `Terrain.solid` makes the ground collide (the default of a new one); a character walks on it.

## Vegetation

```sh
$P foliage.create '{"name":"Woods"}'
$P foliage.type_add '{"entity":"Woods","mesh":"meshes/pine.mesh","name":"pine","density":0.05,
  "scale":[0.8,1.4],"yaw":360,"align":0.3,"rule":true,"slope":[0,30],"wind":0.5}'
$P foliage.paint '{"entity":"Woods","mode":"generate","at":[256,0,256],"radius":200}'
```

- `foliage.type_add` makes a type from a `.mesh` with the settings given (its name, by default that
  of the mesh, names it in the other methods); `type_set` changes only the fields it names
  (`describe` lists them): how dense, how large, turned and leaned it is, a `rule` that confines
  it by slope, height and terrain layers, its distances, `wind` and shadow.
- `mode`: `generate` turns on the generator of the cells under the ring (large radii cover a
  whole terrain; `ungenerate` off), `paint` and `erase` place or remove manual instances (a
  `ground_only` paint stays on the terrain), `reapply` redoes scale and turn. `foliage.place` puts
  one instance, `foliage.query` lists types and instances.
- Foliage stands on the terrain by itself and follows it when it is sculpted.
  Far away it becomes impostors; collision is per type.
- A `Wind` component (`volume "mirai:engine/volume"`) on any entity makes foliage sway; `wind` on
  a type scales it.

## Pitfalls that fail silently

- Nothing shows after `foliage.create`: it has no types until `type_add`, and no instances until
  `generate` or `paint` has run over the area.
- Foliage placed away from the terrain or over a hole has no ground and generates nothing.
- A `rule` with `slope` but no `rule: true` is ignored; `layers` 0 means any layer.
