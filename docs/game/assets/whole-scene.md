# A whole scene through the API

A scene is a file of `assets/`, the source of the game, as a `.ui` is: an agent writes it through
the API, a person in the editor, and nothing writes over what either saved. A prefab is a scene
whose kind is Prefab, with one root.
Terrain, foliage and sea go in one file, the params of one `batch`: its calls run in order, each
finding what it needs by name ([terrain-foliage](../world/terrain-foliage.md)), and it stops at the
first that fails. `"transaction":true` makes what they edit of the scene one step of undo:

```json
{"transaction": true, "calls": [
{"method":"scene.open","params":{"path":"arena/main.scene"}},
{"method":"terrain.create","params":{"name":"Island","samples":257,"spacing":1,"at":[0,0,0],"heightmap":"assets/island/island.png","height_scale":40}},
{"method":"terrain.layer","params":{"entity":"Island","material":"island/sand.mat","tiling":6}},
{"method":"terrain.layer","params":{"entity":"Island","material":"island/grass.mat","automatic":true,"height":[2.6,40],"slope":[0,42],"softness":[6,1.2]}},
{"method":"foliage.create","params":{"name":"Plants"}},
{"method":"foliage.type_add","params":{"entity":"Plants","mesh":"island/palm.mesh","name":"palm","density":0.007,"scale":[0.8,1.25],"align":0.15,"rule":true,"slope":[0,28],"ground_height":[0.9,6.5]}},
{"method":"foliage.paint","params":{"entity":"Plants","mode":"generate","at":[0,0,0],"radius":82}},
{"method":"scene.write","params":{"entities":[{"name":"Sea","components":{"Volume":{"shape":"Plane"},"Fluid":{"density":1025},"Water":{},"Fluid_Waves":{}}},{"name":"Hut","prefab":"island/hut.scene","position":[4,3,-2]}]}},
{"method":"asset.save","params":{"all":true}},
{"method":"scene.save","params":{}}
]}
```

`scene.save` with a new `path` writes another scene.

```sh
mirai rpc --project . batch --file island.json
```

- Hills come from a heightmap of the project (a 16-bit PNG, `terrain.heightmap` exports the format)
  or from brushes (`terrain.edit`: `noise`, `raise`, `ramp`...), in the same file.
- A generated mesh or material (a palm, the sand) is an asset a [content tool](content-tool.md)
  wrote; its path or id is what a layer and a type name. The tool runs before this file; it never
  writes a scene.
- `scene.write` is how entities are made and changed, with the document of
  [a scene as text](text-sources.md#a-scene); what the call does not name stays. An
  entity with `prefab` is a linked instance of that one-root `.scene`: what the call leaves out
  stays as the prefab gives it, and what it says of the children of the prefab, by their names,
  the instance holds.
- A param that is exactly `"$N"` or `"$N.path"` takes what call N answered, or a field of it:
  `"root":"$7.id"` is the entity call 7 made.
- The file is the recipe of a first version: to change the scene later, edit what it made
  (`scene.write`, `terrain.layer`, `foliage.type_set`) and save, as with any scene.

## As a file of text

`mirai scene` reads and writes a scene as one nested document, with no editor running,
against the components of the game as it was built (`mirai build editor .` first):

```sh
mirai scene read arena/main.scene --out main.json
mirai scene write arena/main.scene main.json
mirai scene check
```

The document, with presets, placed prefabs and how entities are matched:
[text-sources.md](text-sources.md#a-scene).
