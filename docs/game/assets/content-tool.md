# Content tool: write assets from code

A content tool is a program of the project (`tools/content`, an `odin run` target) that writes
the assets of a game from code, so the same bytes come out every run and the game can be rebuilt
from source. Use it for what no art source holds: procedural textures, generated sounds, sound
sets, interfaces, prefabs and scenes. Art files go through `mirai import` instead
([assets](../assets.md#import)). The command that runs a tool is at the top of the project's
`tools/content/main.odin`; run it from the project folder.

## Map

- Skeleton and ids: [Skeleton](#skeleton). Texture: [Texture](#texture).
- Sound from a generated WAV: [Sound](#sound). Several sounds as one: [Sound set](#sound-set).
- Prefab and scene: [Prefab and scene](#prefab-and-scene).
- Importing art from the tool: [Import](#import).

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
  naming the same assets. Game code names a prefab or a scene by its path, not by this id.
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
- The id an import returns is random: put it in the scene in the same run, or read it with
  `asset.list`; never in a constant.

## Sound set

```odin
info:=asset.SOUND_SET_DEFAULTS
info.sounds[0],info.sounds[1]={sound=step_a},{sound=step_b}
err:=asset.sound_set_save("assets/sounds/steps.sound_set",&c.types,
    {id=asset.content_id(PROJECT,"sound_set","steps"),info=info})
```

`Sound_Set_Info` also has `volume_min`, `volume_max`, `pitch_min`, `pitch_max`, `no_repeat`
and a `weight` per sound. A set that is invalid returns `.Invalid`.

## Prefab and scene

```odin
b:asset.Scene_Builder
asset.builder_init(&b,&c,asset.KIND_PREFAB,PLAYER_PREFAB) // KIND_SCENE for a scene
defer asset.builder_destroy(&b)
root:=asset.builder_entity(&b,"Player")
eyes:=asset.builder_entity(&b,"Eyes",{position={0,1.6,0}},root)
asset.builder_set(&b,root,phys.collider_character())
asset.builder_save(&b,"assets/prefabs/Player.prefab")
```

- `builder_entity` also writes the `Transform`: a rotation or a scale left out is the identity.
  The entity without a parent of a prefab is its root.
- `builder_set` takes the component from the type of the value, the struct the game declares.
- The first error is printed, naming the entity and the component; `builder_save` then writes
  nothing and `c.failed` is set.
- References to assets inside components are `base.Asset_Id` values: use the ids above.
- A `Spawn_Point` names a prefab id, a `UI_Screen` a `.ui`, an `Audio_Source` a `.sound`: each
  field is an id you wrote or imported. `asset.scene_get` on `b.scene` reads a component back.

## Import

A tool can import art too, with the function `mirai import` calls:

```odin
report,error:=sources.import_source("source/models/crate.glb","assets/models/crate",{root="."})
```

`sources` is `mirai:cook/import/sources`. It writes the settings beside the source unless
`no_save=true`, and repeats earlier ids, so a tool and `mirai import` give the same assets.

## Pitfalls that fail silently

- Write assets first, then prefabs, then scenes: a scene names the ids the earlier ones return.
- Rerunning the tool rewrites the same files: an open editor picks them up at its next call.
