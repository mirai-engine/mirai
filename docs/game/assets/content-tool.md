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
id_of :: proc(kind,name:string) -> base.Asset_Id {
    return base.asset_id_named(fmt.tprintf("%s\x1fgame_content\x1f%s",kind,name))
}
main :: proc() {
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    os.make_directory_all("assets/textures")
    // ... write assets; on any error set failed
    if failed {os.exit(1)}
}
```

- An id from `base.asset_id_named` is the same on every run: write the id constants of what code
  uses (`PLAYER_PREFAB :: base.Asset_Id{...}`) once and make the tool use them.
- Every `*_save(path,&types,desc)` returns `asset.Error`; `.None` is success. Print the path on
  success and the error on failure, and exit 1 if any failed.
- The tool writes the same bytes twice: do not add time or random numbers to what it writes.

## Texture

```odin
pixels:=make([]u8,64*64*4,context.temp_allocator) // RGBA8, rows from the top
// fill pixels
err:=asset.texture_save("assets/textures/badge.tex",&types,
    {id=id_of("texture","badge"),width=64,height=64,format=.RGBA8,flags={.Srgb},mips={pixels}})
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
err:=asset.sound_set_save("assets/sounds/steps.sound_set",&types,
    {id=id_of("sound_set","steps"),info=info})
```

`Sound_Set_Info` also has `volume_min`, `volume_max`, `pitch_min`, `pitch_max`, `no_repeat`
and a `weight` per sound. A set that is invalid returns `.Invalid`.

## Prefab and scene

```odin
s:asset.Scene
asset.scene_init(&s,&types,asset.KIND_PREFAB,PLAYER_PREFAB) // KIND_SCENE for a scene
defer asset.scene_destroy(&s)
root:=asset.scene_new_id(&s)
asset.scene_entity_add(&s,root,0,"Player")             // id, parent (0: none), name
s.info.root=root                                       // a prefab has exactly one root
asset.scene_set(&s,root,"Transform",&core.Transform{{0,0,0},1,{1,1,1}})
asset.scene_set(&s,root,"Collider",&phys.collider_character())
asset.scene_save(&s,"assets/prefabs/Player.prefab")
```

- A component is named by its type name as a string; the value is a pointer to the same struct
  the game declares. Check the name and fields with `engine.describe`.
- References to assets inside components are `base.Asset_Id` values: use the ids above.
- A `Spawn_Point` names a prefab id, a `UI_Screen` a `.ui`, an `Audio_Source` a `.sound`: each
  field is an id you wrote or imported. `asset.scene_get` reads a component back.

## Import

A tool can import art too, with the function `mirai import` calls:

```odin
report,error:=sources.import_source("source/models/crate.glb","assets/models/crate",{root="."})
```

`sources` is `mirai:cook/import/sources`. It writes the settings beside the source unless
`no_save=true`, and repeats earlier ids, so a tool and `mirai import` give the same assets.

## Pitfalls that fail silently

- Write assets first, then prefabs, then scenes: a scene names the ids the earlier ones return.
- A prefab needs `s.info.root`; without it the prefab has no root entity.
- Rerunning the tool rewrites the same files: after it, call `asset.reload` in an open editor.
