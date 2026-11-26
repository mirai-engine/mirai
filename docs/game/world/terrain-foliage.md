# Terrain and foliage

Ground is a `Terrain` entity and vegetation a `Pcg_Graph` with a `Foliage` on the same entity:
assets (`.terrain`, `.pcg`) the plugins stream, draw with levels of detail and collide. Add
`"terrain"` and `"foliage"` to `plugins` in `project.mirai` (`foliage` brings `pcg`). Never make
ground or vegetation from cubes, planes or imported meshes placed one by one: they do not stream,
paint, scatter or collide as these do.

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
```

- Kinds: `heightfield` (heights over x and z: hills, valleys, plains) and `volume` (solid and
  air: caves, overhangs and digging, as large as the ground needs). Size is `samples` minus 1
  times `spacing`, centered on `at`. `name` names the entity and its file, which goes beside the
  scene.
- Brushes of `terrain.edit`, the same on both kinds: `raise`, `lower`, `smooth`, `flatten`,
  `set_height`, `noise`, `paint` and `erase` (a layer), and `add` and `carve`, which join or take
  out a `shape` (`sphere`, `capsule` to `to`, `box`). Of a heightfield alone: `ramp` (from `at` to
  `to`), `terrace`, `erode`, `hole`, `fill`, and `tint` (`color`) and `roughness` (0 smooth, 0.5
  as the layers are, 1 rough), painted over the layers. A stroke goes from `at` to `to`; `radius`,
  `strength`, `falloff`, `passes` shape it. A brush the kind lacks or a value out of range
  answers what failed and what to use.
- In game code one call digs whatever ground is under it:
  `terrain.dig(requests, {kind=.Carve, center=point, radius=2, amount=1})` returns what is wrong
  with the brush (`terrain.edit_error_fix` says how to fix it), and what it took out comes in
  `Terrain_Digs`.
- `terrain.layer` adds a material layer (up to 32) or changes the one named `layer` by its
  material (its path or stem; `default` is one without a material); an `automatic` layer covers
  where the slope (degrees) and `height` (metres) are in its ranges, so rock lands on steep faces
  and grass on flat ones with no painting. `detile` (0 to 1) breaks the repeats of a large flat
  layer, `variation` (0 to 1) darkens and brightens it slowly over the world and `far_tiling`
  repeats it larger far away. Layer materials are `.mat`
  assets: import a PBR texture set ([assets](../assets.md)) and give their paths.
- `terrain.sample {entity,at}` reads what is under a point; `terrain.heightmap` imports or exports a
  16-bit PNG; `terrain.resize` changes the samples.
- `Terrain.solid` makes the ground collide (the default of a new one); a character walks on it.

## Vegetation

```sh
$P scene.write '{"entities":[{"name":"Woods","components":{"Pcg_Graph":{"source":"woods/woods.pcg"},
  "Foliage":{"wind":0.5},"Volume":{"shape":"Box","extents":[200,500,200]}}}]}'
$P foliage.query '{"entity":"Woods"}'
```

- The `.pcg` says what grows where: a list of layers, each one mesh or prefab with its density,
  `radius` (trees kept off each other and off rocks), scale, turn and lean, a `ground_rule` of
  slope, height and terrain layers, a field expression of how viable it is where, its distances
  (`impostor_distance` turns it into impostors far away), whether it `collides` and whether it is
  `filler` (what a lower detail thins first). It is an asset a
  [content tool](../assets/content-tool.md) writes, as a generated mesh is; the demo's
  `forest/Woods.pcg` is one.
- The `Pcg_Graph` places its layers around the players in cells, again from its seed; a `Volume`
  on its entity bounds where. `Foliage` draws and collides them: `wind`, `flutter`, `shadows` and
  `rays` for the layers that place a mesh; a prefab draws, sways (`Foliage_Sway` on its root) and
  collides as it is.
- Foliage stands on the terrain by itself and follows it when it is sculpted.
- A `Pcg_Zone` (`pcg "plugins:pcg/runtime"`) with `exclude` on a house with a `Volume`, or on a
  road's `Spline`, keeps the graph out of it, also when it moves.
- Taking a plant out in play is `pcg.pcg_suppress_request` with the instance `foliage.hit_of`
  gives; `foliage.foliage_promote` makes it an entity of its prefab (a tree that falls).
- A `Wind` component (`volume "mirai:engine/volume"`) on any entity makes foliage sway; `wind` on
  the `Foliage` scales it.

## Pitfalls that fail silently

- A `Foliage` without a `Pcg_Graph` on its entity draws nothing (`foliage.graph` says so), and a
  graph without a `Foliage` places but nothing draws it.
- Foliage placed away from the terrain or over a hole has no ground and generates nothing.
- A `ground_rule` with `slope` but no `enabled` is ignored; `layers` none means any layer.
- Past its `weight`, a layer stands as densely as its `layers` weigh there, or at all of its
  density with `whole`.
