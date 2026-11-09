# Content tool: write assets from code

A content tool is a program of the project (`tools/content`, an `odin run` target) that writes
the generated assets of a game from code, so the same bytes come out every run and the game can be
rebuilt from source. Use it for what no art source holds: procedural textures, generated sounds,
sets of sounds and meshes made from code. Art files go through `mirai import`
([assets](../assets.md#import)); a scene and a prefab are files of `assets/`, written through the
API or in the editor, never by a tool ([whole-scene](whole-scene.md)). The command that runs a
tool is at the top of the project's `tools/content/main.odin`; run it from the project folder.

## Skeleton

```odin
PROJECT :: "game_content"
main :: proc() {
    c:asset.Content
    asset.content_init(&c,PROJECT)
    defer asset.content_destroy(&c)
    os.make_directory_all("assets/textures")
    // ... write assets
    if c.failed {os.exit(1)}
}
```

- `asset.content_id(PROJECT,kind,name)` is the same on every run, so what the tool writes keeps
  naming the same assets.
- Every `*_save(path,&c.types,desc)` returns `asset.Error`: pass it to
  `asset.content_check(&c,path,error)`, which prints the path or the error and sets `c.failed`.
- The tool writes the same bytes twice: do not add time or random numbers to what it writes.

## Texture

```odin
pixels:=make([]u8,64*64*4,context.temp_allocator) // RGBA8, rows from the top
// fill pixels
err:=asset.texture_save("assets/textures/badge.tex",&c.types,
    {id=asset.content_id(PROJECT,"texture","badge"),width=64,height=64,format=.RGBA8,
     flags={.Srgb},mips={pixels}})
```

- `flags={.Srgb}` for color; leave it off for data maps; `.Normal_Map` for normals.
- `mips` is level 0 first; one level is valid.

## Sound

Write the WAV into `source/sounds/` and import it, so the `.sound` is what `mirai import` makes:

```odin
report,error:=importer.import_sound("source/sounds/hum.wav","assets/sounds",{},{root="."})
if error.code!=.None {fmt.eprintln(error.message);return}
defer importer.report_destroy(&report)
hum:=report.assets[0].id // random the first time, kept after
```

- Write the WAV only when its bytes differ from the file on disk, so an unchanged source is
  imported as the same file.
- The id an import returns is random: read it with `asset.list`; never in a constant.

## Sound set

```odin
info:=asset.SOUND_SET_DEFAULTS
info.sounds[0],info.sounds[1]={sound=step_a},{sound=step_b}
err:=asset.sound_set_save("assets/sounds/steps.sound_set",&c.types,
    {id=asset.content_id(PROJECT,"sound_set","steps"),info=info})
```

`Sound_Set_Info` also has `volume_min`, `volume_max`, `pitch_min`, `pitch_max`, `no_repeat`
and a `weight` per sound. A set that is invalid returns `.Invalid`.

## Import

A tool can import art too, with the function `mirai import` calls:

```odin
report,error:=sources.import_source("source/models/crate.glb","assets/models/crate",{root="."})
```

`sources` is `mirai:cook/import/sources`. It writes the settings beside the source unless
`no_save=true`, and repeats earlier ids, so a tool and `mirai import` give the same assets.

## Pitfalls that fail silently

- Materials a terrain layer names can be written in the tool too:
  `info:=asset.MATERIAL_DEFAULTS;info.maps.base_color.texture=tex`, then
  `asset.material_save(path,&c.types,{id=...,info=info})`; the maps are `base_color`,
  `metallic_roughness`, `normal`, `emission` and `occlusion`.
- Rerunning the tool rewrites the same files: an open editor picks them up at its next call.
