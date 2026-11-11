# A whole scene through the API

A scene and a prefab are files of `assets/`, the source of the game, as a `.ui` is: an agent
writes them through the API, a person in the editor, and nothing writes over what either saved.
Terrain, foliage and sea go in one `--batch` file of JSON lines, one line per call, each finding
what it needs by name ([terrain-foliage](../world/terrain-foliage.md)):

```json
{"method":"scene.open","params":{"path":"arena/main.scene"}}
{"method":"terrain.create","params":{"name":"Island","samples":257,"spacing":1,"at":[0,0,0],"heightmap":"source/island.png","height_scale":40}}
{"method":"terrain.layer","params":{"entity":"Island","material":"island/sand.mat","tiling":6}}
{"method":"terrain.layer","params":{"entity":"Island","material":"island/grass.mat","automatic":true,"height":[2.6,40],"slope":[0,42],"softness":[6,1.2]}}
{"method":"foliage.create","params":{"name":"Plants"}}
{"method":"foliage.type_add","params":{"entity":"Plants","mesh":"island/palm.mesh","name":"palm","density":0.007,"scale":[0.8,1.25],"align":0.15,"rule":true,"slope":[0,28],"ground_height":[0.9,6.5]}}
{"method":"foliage.paint","params":{"entity":"Plants","mode":"generate","at":[0,0,0],"radius":82}}
{"method":"scene.add","params":{"name":"Sea","components":{"Fluid_Volume":{"shape":"Plane","density":1025},"Water":{},"Fluid_Waves":{}}}}
{"method":"scene.write","params":{"entities":[{"name":"Hut","prefab":"island/hut.prefab","position":[4,3,-2]}]}}
{"method":"asset.save","params":{"all":true}}
{"method":"scene.save","params":{}}
```

`scene.save` with a new `path` writes another scene.

```sh
mirai rpc --project . --batch island.jsonl
```

- Hills come from a heightmap of the project (a 16-bit PNG, `terrain.heightmap` exports the format)
  or from brushes (`terrain.edit`: `noise`, `raise`, `ramp`...), in the same file.
- A generated mesh or material (a palm, the sand) is an asset a [content tool](content-tool.md)
  wrote; its path or id is what a layer and a type name. The tool runs before this file; it never
  writes a scene.
- `scene.write` with `prefab` places a linked instance of that `.prefab`, as the document of
  [a scene as text](text-sources.md#a-scene) does; what the line leaves out stays as the prefab
  gives it, and what it says of the children of the prefab, by their names, the instance holds.
- The file is the recipe of a first version: to change the scene later, edit what it made
  (`scene.set`, `terrain.layer`, `foliage.type_set`) and save, as with any scene.

## As a file of text

`mirai scene` reads and writes a scene or a prefab as one nested document, with no editor running,
against the components of the game as it was built (`mirai build editor . --dev` first):

```sh
mirai scene read arena/main.scene --out source/arena/main.scene.json
mirai scene write source
mirai scene check
```

The document, with presets, placed prefabs and how entities are matched:
[text-sources.md](text-sources.md#a-scene).
