# Content tool: write assets from code

The content tool of a project is the package `tools/content` (a `package main`) that writes what
the game makes from code: tables of game data, scenes and prefabs laid out by rules, procedural
textures, generated sounds and meshes. `mirai content <project>` builds it the way the tests of
the project build (the engine and plugin libraries, its game, the generated world, its attributes
and defines) and runs it in the root of the project; what goes after `--` reaches it as its
arguments. An unchanged tool compiles nothing, and an unchanged run writes nothing. A tool that
does not compile does not stop the editor from building; `mirai check <project>` checks it.

Art files go through `mirai import` ([assets](../assets.md#import)); a scene edited by hand goes
through `scene.write` or the editor ([whole-scene](whole-scene.md)), and one the tool writes is
checked the same way and stays editable; the next run writes it over.

## Skeleton

```odin
package main

import "core:os"
import "mirai:cook/content"
import game "project:game"
import world "generated:editor_world"

main :: proc() {
    w:content.Writer
    if !content.open(&w,world.info()) {os.exit(1)}
    content.records_write(&w,"data/weapons.records",[]content.Row(game.Weapon){
        {"pistol",{damage=8,fire=content.action(&w,game.Combat_Action.Fire)}},
    })
    content.scene_write(&w,"arena/crates.scene",`{"entities":[{"name":"Crate","prefab":"props/crate.scene"}]}`)
    os.exit(content.close(&w))
}
```

- The tool imports the game (`project:game`) and the world generated for the project
  (`generated:editor_world`): the record types, components, `@(names)` constants and `@(actions)`
  enums of the game are its own names, never numbers or strings repeated by hand.
- A call that fails says so with the file and line of the tool, as the compiler says an error, and
  `close` returns 1; a file that already holds what a call writes is left untouched. Run it twice:
  the second run says `0 written` (no time or random numbers in what it writes).

## Tables of game data

`content.records_write(&w,path,rows)` makes the table at `path` (under `assets/`, `.records`
added when missing) hold those rows of the record type, in that order, and no others:

- The type is one a `.records` declares (`mirai records create`, [records](../core/records.md)),
  whose struct the build generates into `game/`. A new table holds rows of it beside the one that
  declares it. A row keeps its id by its name; a new row takes an id made from its name.
- `content.record(&w,game.Ammo,"data/ammo.records","shell")` is the `core.Record` of a row of
  another table (write that one first); `content.action(&w,game.Combat_Action.Fire)` the input
  action of a member of an `@(actions)` enum, which the file keeps by its name.
- Rows as text (a spreadsheet): `content.table_write(&w,path,type,names,values)`, as `records.set`.

## Scenes and prefabs

`content.scene_write(&w,path,document)` makes the scene or prefab at `path` say what the document
declares: the document of `mirai scene` and `scene.write` ([text-sources](text-sources.md#a-scene)),
validated by the same code. `content.component(&w,value)` writes a component as that document
takes it, and `content.transform(value)` a `core.Transform` as entity keys, its rotation whole:

```odin
crate:=content.component(&w,game.Crate{weight=3})
place:=content.transform({position={2,0,4},rotation=tilt,scale={1,1,1}})
content.scene_write(&w,"arena/crates.scene",fmt.tprintf(`{{"entities":[{{"name":"Crate",%s,"components":{{"Crate":%s}}}}]}}`,place,crate))
```

## Texture

```odin
pixels:=make([]u8,64*64*4,context.temp_allocator) // RGBA8, rows from the top
// fill pixels
content.check(&w,"assets/hud/badge.tex",asset.texture_save("assets/hud/badge.tex",&w.types,
    {id=content.id(&w,"texture","badge"),width=64,height=64,format=.RGBA8,flags={.Srgb},mips={pixels}}))
```

- Every `asset.*_save(path,&w.types,desc)` (texture, material, mesh, sound set, animation...)
  returns `asset.Error`: `content.check(&w,path,error)` counts the file or says the error.
- `content.id(&w,kind,name)` is the same on every run. `flags={.Srgb}` for color, `.Normal_Map`
  for normals; `mips` is level 0 first. `content.mesh(&w,path,&buffer)`: [props](props.md).

## Sound

Write the WAV into the assets, where the sound goes, and import it, so the `.sound` is what
`mirai import` makes:

```odin
content.source_write(&w,"assets/arena/hum.wav",wav)   // written only when its bytes changed
report,imported:=content.import_source(&w,"assets/arena/hum.wav") // as mirai import does
if !imported {return}
defer importer.report_destroy(&report)
hum:=report.assets[0].id // random the first time, kept after
```

- `importer` is `mirai:cook/import`; write the WAV only when its bytes differ. An import's id is
  random once, then kept by the source's package: read it with `asset.list`, never a constant. The
  WAV, `packages.mirai` and `packages/` are kept by the project's history; the `.sound` is built
  from them. Sets: `asset.sound_set_save` ([audio](../audio.md#sets)). Art imports the same way.

## What is not supported

- Raw `odin build` or `odin run` in a project: its collections, attributes and defines come from
  `mirai content`, `mirai test` and `mirai build`, against the libraries of the engine.
- Scripts that wrap the API to write content (a Python loop of `mirai rpc` calls): what the tool
  needs is a procedure of `content`, `asset` or the game.
- Text patches over assets (`sed`, `perl -i` on a `.scene` or a `.records`): a file is changed
  through its document (`mirai scene write`, `mirai records write`), the API or this tool.

## Pitfalls that fail silently

- Materials a terrain layer names: `info:=asset.MATERIAL_DEFAULTS`, its `maps` (`base_color`,
  `metallic_roughness`, `normal`, `emission`, `occlusion`), then `asset.material_save`.
- A masked material (`info.alpha_mode=.Mask`) is cut by its mask map, `info.maps.mask`: the alpha
  of its texture times `opacity`, against `alpha_cutoff`; without a texture there, the alpha of
  `base_color`. Leaves, grates and fences declare it whether or not a Surface program shades
  them: a program never cuts a material, and one that sets `s.alpha` on a masked one is an error
  of that material (`engine.diagnostics` says it).
- An edit made in the editor to a table or scene the tool writes is overwritten the next time the
  tool runs: change the tool instead. An open editor picks up what a run wrote at its next call.
