package build

import "base:runtime"
import "core:fmt"
import cmath "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import lz_optimal "mirai:cook/compressor/lz"
import anim "mirai:std/anim"
import mm "mirai:std/math"
import "mirai:std/base"
import "mirai:std/jobs"

@(private="file") WOOD_COLOR :: base.Asset_Id{1,1}
@(private="file") WOOD_NORMAL :: base.Asset_Id{1,2}
@(private="file") ICON :: base.Asset_Id{1,3}
@(private="file") UNUSED_TEXTURE :: base.Asset_Id{1,4}
@(private="file") BLOCKS :: base.Asset_Id{1,5}
@(private="file") WOOD :: base.Asset_Id{2,1}
@(private="file") SPARE :: base.Asset_Id{2,2}
@(private="file") LONELY :: base.Asset_Id{2,3}
@(private="file") LOST :: base.Asset_Id{2,4}
@(private="file") CRATE :: base.Asset_Id{3,1}
@(private="file") MAIN :: base.Asset_Id{4,1}
@(private="file") HUD :: base.Asset_Id{5,1}
@(private="file") PROP :: base.Asset_Id{6,1}
@(private="file") ABSENT :: base.Asset_Id{9,9}

@(private="file")
Shown :: struct {mesh:base.Asset_Id}
@(private="file")
Picture :: struct {image:base.Asset_Id}

// 8x8 with two levels; opaque unless `alpha`.
@(private="file")
texture_write :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,flags:asset.Texture_Flags,alpha:=false,format:=asset.Texture_Format.RGBA8) {
    levels:[2][256]u8
    for &level in levels {
        for &value,at in level {value=at%4==3?(alpha?u8(at):255):u8(at*3)}
    }
    mips:[][]u8={levels[0][:],levels[1][:64]}
    if format==.BC1 {mips={levels[0][:32],levels[1][:8]}}
    testing.expect_value(t,asset.texture_save(path,types,{id=id,width=8,height=8,format=format,flags=flags,mips=mips}),asset.Error.None)
}

@(private="file")
material_write :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,color,normal:base.Asset_Id) {
    info:=asset.MATERIAL_DEFAULTS
    info.maps.base_color.texture,info.maps.normal.texture=color,normal
    testing.expect_value(t,asset.material_save(path,types,{id=id,info=info}),asset.Error.None)
}

// A scene (or a prefab, or an interface) whose one entity names an asset.
@(private="file")
scene_write :: proc(t:^testing.T,types:^asset.Types,path:string,kind:asset.Fourcc,id,named:base.Asset_Id) {
    if kind==asset.KIND_UI {
        doc:asset.Document
        asset.document_init(&doc,kind,id)
        defer asset.document_destroy(&doc)
        pictures:=[1]Picture{{named}}
        _,put:=asset.document_put(&doc,types,"pictures",pictures[:])
        testing.expect_value(t,put,asset.Error.None)
        testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
        return
    }
    scene:asset.Scene
    asset.scene_init(&scene,types,id)
    defer asset.scene_destroy(&scene)
    asset.scene_entity_add(&scene,1,0,"thing")
    shown:=Shown{named}
    asset.scene_set(&scene,1,"Shown",&shown)
    testing.expect_value(t,asset.scene_save(&scene,path),asset.Error.None)
}

// main.scene -> crate.mesh -> wood.mat -> wood_color.tex, wood_normal.tex.
// hud.ui -> icon.tex. prop.scene -> crate.mesh. spare.mat -> blocks.tex,
// lonely.mat -> unused.tex and lost.mat -> a texture that is no file: nothing
// names them. notes.txt is no asset.
@(private="file")
project_write :: proc(t:^testing.T,types:^asset.Types,assets:string) {
    for folder in ([]string{"textures","materials","models","scenes","ui","prefabs"}) {os.make_directory_all(fmt.tprintf("%s/%s",assets,folder))}
    texture_write(t,types,fmt.tprintf("%s/textures/wood_color.tex",assets),WOOD_COLOR,{.Srgb})
    texture_write(t,types,fmt.tprintf("%s/textures/wood_normal.tex",assets),WOOD_NORMAL,{.Normal_Map})
    texture_write(t,types,fmt.tprintf("%s/textures/icon.tex",assets),ICON,{.Srgb},true)
    texture_write(t,types,fmt.tprintf("%s/textures/unused.tex",assets),UNUSED_TEXTURE,{.Srgb},true)
    texture_write(t,types,fmt.tprintf("%s/textures/blocks.tex",assets),BLOCKS,{.Srgb},false,.BC1)
    material_write(t,types,fmt.tprintf("%s/materials/wood.mat",assets),WOOD,WOOD_COLOR,WOOD_NORMAL)
    material_write(t,types,fmt.tprintf("%s/materials/spare.mat",assets),SPARE,BLOCKS,{})
    material_write(t,types,fmt.tprintf("%s/materials/lonely.mat",assets),LONELY,UNUSED_TEXTURE,{})
    material_write(t,types,fmt.tprintf("%s/materials/lost.mat",assets),LOST,ABSENT,{})
    corners:=[3]asset.Vertex{{position={0,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,0,1},color=0xffffffff}}
    slots:=[1]asset.Material_Slot{{id=1,material=WOOD}}
    geometry:asset.Mesh_Geometry
    testing.expect(t,asset.mesh_build({vertices=corners[:]},{0,2,1},nil,&geometry,context.temp_allocator))
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/models/crate.mesh",assets),types,{id=CRATE,geometry=geometry,slots=slots[:]}),asset.Error.None)
    scene_write(t,types,fmt.tprintf("%s/scenes/main.scene",assets),asset.KIND_SCENE,MAIN,CRATE)
    scene_write(t,types,fmt.tprintf("%s/prefabs/prop.scene",assets),asset.KIND_SCENE,PROP,CRATE)
    scene_write(t,types,fmt.tprintf("%s/ui/hud.ui",assets),asset.KIND_UI,HUD,ICON)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/notes.txt",assets),"not an asset")==nil)
}

@(private="file")
cooked_format :: proc(t:^testing.T,types:^asset.Types,path:string) -> (format:asset.Texture_Format,mips:int) {
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,error:=asset.texture_view(&a,types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,asset.blob_verify_hash(&a.blob))
    return view.info.format,len(view.mips)
}

@(private="file")
names :: proc(report:^Cook_Report) -> (kept,dropped:string) {
    b:=strings.builder_make(context.temp_allocator)
    for file in report.files {fmt.sbprintf(&b,"%s ",file.path)}
    kept=strings.clone(strings.to_string(b),context.temp_allocator)
    strings.builder_reset(&b)
    for file in report.dropped {fmt.sbprintf(&b,"%s ",file.path)}
    return kept,strings.to_string(b)
}

@(test)
a_cook_ships_what_the_scenes_and_the_roots_reach_as_the_runtime_loads_it :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-reach")
    if folder=="" {return}
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    project_write(t,&types,assets)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)

    // Without cook.mirai the scenes and the prefabs are the roots.
    report:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,dropped:=names(&report)
    testing.expect_value(t,kept,"materials/wood.mat models/crate.mesh prefabs/prop.scene scenes/main.scene textures/wood_color.tex textures/wood_normal.tex ")
    testing.expect_value(t,dropped,"materials/lonely.mat materials/lost.mat materials/spare.mat notes.txt textures/blocks.tex textures/icon.tex textures/unused.tex ui/hud.ui ")
    testing.expect(t,report.roots==2 && len(report.missing)==0 && report.removed==0)
    for file in report.dropped {testing.expect(t,file.asset==(file.path!="notes.txt") && file.bytes>0)}
    testing.expect_value(t,report.textures_compressed,2)
    color,color_mips:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_color.tex",output))
    normal,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_normal.tex",output))
    testing.expect(t,color==.BC7 && normal==.BC5 && color_mips==2,"a texture is compressed by its use, level by level")
    total:i64
    for file in report.files {
        testing.expect(t,file.bytes>0 && file.source_bytes>0 && (file.compressed==(file.kind==asset.KIND_TEXTURE)))
        total+=file.bytes
    }
    testing.expect(t,report.output_bytes>total && report.source_bytes>report.output_bytes,"the size is that of the files and the index")
    testing.expect(t,!os.exists(fmt.tprintf("%s/notes.txt",output)) && !os.exists(fmt.tprintf("%s/ui",output)))
    // Any other asset is the same document, compressed for shipping.
    source,_:=os.read_entire_file(fmt.tprintf("%s/models/crate.mesh",assets),context.temp_allocator)
    shipped,_:=os.read_entire_file(fmt.tprintf("%s/models/crate.mesh",output),context.temp_allocator)
    repacked,repack_error:=asset.document_repack(source,lz_optimal.SHIP,context.temp_allocator)
    testing.expect(t,len(source)>0 && repack_error==.None && string(repacked)==string(shipped))

    // The index is what a scan of the output finds.
    indexed,scanned:asset.Registry
    asset.registry_init(&indexed,output);defer asset.registry_destroy(&indexed)
    asset.registry_init(&scanned,output);defer asset.registry_destroy(&scanned)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    testing.expect_value(t,asset.registry_scan(&scanned),asset.Error.None)
    testing.expect_value(t,len(indexed.files),6)
    testing.expect_value(t,len(scanned.files),6)
    for file,at in indexed.files {testing.expect(t,file.path==scanned.files[at].path && file.id==scanned.files[at].id && file.size==scanned.files[at].size && file.time==scanned.files[at].time)}
    crate,found:=asset.registry_find(&indexed,CRATE)
    testing.expect(t,found && len(asset.registry_dependencies(&indexed,crate))==1)

    // Roots by path, by folder and by id; a texture only an interface shows stays as it is.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/spare.mat","ui/","00000000000000020000000000000004","notes.txt"]}`)==nil)
    report=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,dropped=names(&report)
    testing.expect_value(t,kept,"materials/lost.mat materials/spare.mat materials/wood.mat models/crate.mesh notes.txt prefabs/prop.scene scenes/main.scene textures/blocks.tex textures/icon.tex textures/wood_color.tex textures/wood_normal.tex ui/hud.ui ")
    testing.expect_value(t,dropped,"materials/lonely.mat textures/unused.tex ")
    testing.expect_value(t,report.roots,6)
    testing.expect(t,len(report.missing)==1 && report.missing[0].path=="materials/lost.mat" && report.missing[0].id==ABSENT,"a dependency that is no file is reported")
    icon,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/icon.tex",output))
    blocks,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/blocks.tex",output))
    testing.expect(t,icon==.RGBA8 && blocks==.BC1 && report.textures_compressed==2)
    summary:=cook_summary(&report,context.temp_allocator)
    testing.expect(t,strings.contains(summary,"assets: 12 of 14 files from 6 roots") && strings.contains(summary,"2 textures compressed") && strings.contains(summary,"  textures/unused.tex (") && strings.contains(summary,"missing: materials/lost.mat depends on 00000000000000090000000000000009"),summary)

    // A root that is no longer one: its files leave the output.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["ui/hud.ui"],"textures":"keep"}`)==nil)
    report=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    testing.expect_value(t,report.removed,4)
    testing.expect(t,!os.exists(fmt.tprintf("%s/materials/spare.mat",output)) && !os.exists(fmt.tprintf("%s/notes.txt",output)) && os.is_file(fmt.tprintf("%s/ui/hud.ui",output)))
    testing.expect_value(t,report.textures_compressed,0)
    kept_color,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_color.tex",output))
    testing.expect_value(t,kept_color,asset.Texture_Format.RGBA8)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    testing.expect_value(t,len(indexed.files),8)

    // A dedicated server leaves behind what is only shown or heard, without missing it.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/spare.mat","ui/","00000000000000020000000000000004","notes.txt"]}`)==nil)
    server:=fmt.tprintf("%s/server/assets",folder)
    report=cook_assets({assets=assets,output=server,manifest=manifest,server=true,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,_=names(&report)
    testing.expect_value(t,kept,"materials/lost.mat materials/spare.mat materials/wood.mat models/crate.mesh notes.txt prefabs/prop.scene scenes/main.scene ")
    testing.expect(t,len(report.missing)==1 && report.missing[0].id==ABSENT,"a texture a material names is not missing on a server")
    testing.expect(t,!os.exists(fmt.tprintf("%s/textures",server)) && !os.exists(fmt.tprintf("%s/ui",server)))
    summary=cook_summary(&report,context.temp_allocator)
    testing.expect(t,strings.contains(summary,"only shown or heard, which a dedicated server does not ship:\n  textures/blocks.tex") && strings.contains(summary,"that nothing reaches:\n  materials/lonely.mat"),summary)
}

@(test)
a_cook_that_cannot_be_what_was_asked_says_why :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-errors")
    if folder=="" {return}
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)
    missing:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect(t,missing.error==.Assets_Missing && !os.exists(output))
    project_write(t,&types,assets)
    for text in ([]string{"{","[]",`{"roots":"ui/"}`,`{"roots":[1]}`,`{"roots":[""]}`,`{"textures":"small"}`,`{"quality":3}`}) {
        testing.expect(t,os.write_entire_file(manifest,text)==nil)
        report:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
        testing.expectf(t,report.error==.Manifest_Invalid && report.detail!="" && !os.exists(output),"%s: %v %s",text,report.error,report.detail)
    }
    for root in ([]string{"scenes/other.scene","nothing/","00000000000000090000000000000009","materials"}) {
        testing.expect(t,os.write_entire_file(manifest,strings.concatenate({`{"roots":["ui/hud.ui","`,root,`"]}`},context.temp_allocator))==nil)
        report:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
        testing.expectf(t,report.error==.Root_Missing && report.detail==root && !os.exists(output),"%s: %v %s",root,report.error,report.detail)
    }
    // An output that cannot be a folder.
    testing.expect(t,os.remove(manifest)==nil && os.write_entire_file(fmt.tprintf("%s/blocked",folder),"a file")==nil)
    blocked:=cook_assets({assets=assets,output=fmt.tprintf("%s/blocked/assets",folder),allocator=context.temp_allocator})
    testing.expect_value(t,blocked.error,Cook_Error.Write_Failed)
    // A project without scenes or roots ships an empty folder with its index.
    empty:=fmt.tprintf("%s/empty/assets",folder)
    os.make_directory_all(empty)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/readme.txt",empty),"nothing here")==nil)
    bare:=cook_assets({assets=empty,output=output,allocator=context.temp_allocator})
    testing.expect(t,bare.error==.None && len(bare.files)==0 && len(bare.dropped)==1 && os.is_file(fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)))
    // A cook that fails halfway leaves no index, not the one before over the files it rewrote.
    // Of two files that cannot be written, the first by path is the one it names, as a cook on one thread does.
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/scenes/main.scene",output))==nil)
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/textures/wood_normal.tex",output))==nil)
    halfway:=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expect(t,halfway.error==.Write_Failed && halfway.detail=="scenes/main.scene" && !os.exists(fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),halfway.detail)
}

@(test)
a_cook_ships_every_asset_of_an_active_plugin_under_its_prefix :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-plugins")
    if folder=="" {return}
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    project_write(t,&types,assets)
    plugin:=fmt.tprintf("%s/project/plugins/probe/assets",folder)
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/brushes",plugin))==nil)
    BRUSH :: base.Asset_Id{7,1}
    material_write(t,&types,fmt.tprintf("%s/brushes/soft.mat",plugin),BRUSH,WOOD_COLOR,{})
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/readme.txt",plugin),"for the code of the plugin")==nil)

    report:=cook_assets({assets=assets,output=output,plugins={{path=plugin,prefix="plugins/probe"}},allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,_:=names(&report)
    testing.expect_value(t,kept,"materials/wood.mat models/crate.mesh plugins/probe/brushes/soft.mat plugins/probe/readme.txt prefabs/prop.scene scenes/main.scene textures/wood_color.tex textures/wood_normal.tex ")
    testing.expect(t,os.is_file(fmt.tprintf("%s/plugins/probe/brushes/soft.mat",output)) && os.is_file(fmt.tprintf("%s/plugins/probe/readme.txt",output)))
    indexed:asset.Registry
    asset.registry_init(&indexed,output);defer asset.registry_destroy(&indexed)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    brush,found:=asset.registry_find(&indexed,BRUSH)
    testing.expect(t,found && brush.path=="plugins/probe/brushes/soft.mat")

    // In a project, the registry sees the folder of the plugin under the same path.
    mounted:asset.Registry
    asset.registry_init(&mounted,assets);defer asset.registry_destroy(&mounted)
    asset.registry_mount(&mounted,plugin,"plugins/probe")
    testing.expect_value(t,asset.registry_scan(&mounted),asset.Error.None)
    seen,in_project:=asset.registry_find(&mounted,BRUSH)
    testing.expect(t,in_project && seen.path=="plugins/probe/brushes/soft.mat")
    testing.expect_value(t,asset.registry_file_path(&mounted,seen.path,context.temp_allocator),fmt.tprintf("%s/brushes/soft.mat",plugin))
    testing.expect_value(t,asset.registry_file_path(&mounted,"scenes/main.scene",context.temp_allocator),fmt.tprintf("%s/scenes/main.scene",assets))
}

@(private="file")
Glow :: struct {range:f32}

@(private="file")
glow_prefab_write :: proc(t:^testing.T,types:^asset.Types,path:string,range:f32) -> (lamp:asset.Scene) {
    asset.scene_init(&lamp,types,PROP)
    lamp.doc.flags+={.Prefab}
    asset.scene_entity_add(&lamp,1,0,"Lamp")
    asset.scene_entity_add(&lamp,2,1,"Bulb")
    glow:=Glow{range}
    asset.scene_set(&lamp,2,"Glow",&glow)
    testing.expect_value(t,asset.scene_save(&lamp,path),asset.Error.None)
    return
}

@(private="file")
glow_range :: proc(t:^testing.T,types:^asset.Types,path:string) -> f32 {
    level:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&level,types,path),asset.Error.None) {return -1}
    defer asset.scene_destroy(&level)
    for root in asset.scene_instance_roots(&level) {
        members,_:=asset.scene_instance_members(&level,root)
        for member in members {
            if member.source!=2 {continue}
            glow,_:=asset.scene_get(&level,member.entity,"Glow",Glow)
            return glow.range
        }
    }
    return -1
}

@(test)
a_cook_brings_the_prefab_instances_of_what_it_ships_up_to_date :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-resolve")
    if folder=="" {return}
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    for inside in ([]string{"prefabs","scenes"}) {os.make_directory_all(fmt.tprintf("%s/%s",assets,inside))}
    lamp_path,level_path:=fmt.tprintf("%s/prefabs/lamp.scene",assets),fmt.tprintf("%s/scenes/level.scene",assets)
    lamp:=glow_prefab_write(t,&types,lamp_path,1)
    level:asset.Scene;asset.scene_init(&level,&types,MAIN);defer asset.scene_destroy(&level)
    _,placed:=asset.scene_instantiate(&level,&lamp,PROP,0)
    testing.expect_value(t,placed,asset.Error.None)
    testing.expect_value(t,asset.scene_save(&level,level_path),asset.Error.None)
    asset.scene_destroy(&lamp)
    report:=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.scenes_resolved==0)

    // The prefab changes after the scene was saved: the shipped scene follows it, the one of the project stays.
    lamp=glow_prefab_write(t,&types,lamp_path,4)
    asset.scene_destroy(&lamp)
    report=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.scenes_resolved==1)
    for file in report.files {testing.expect_value(t,file.resolved,file.path=="scenes/level.scene")}
    testing.expect_value(t,glow_range(t,&types,fmt.tprintf("%s/scenes/level.scene",output)),f32(4))
    testing.expect_value(t,glow_range(t,&types,level_path),f32(1))

    // The prefab an instance places is a dependency of its scene: the scenes are the roots of this cook,
    // which reaches it through them, and a cook whose prefab is gone says so and ships the scene as it is.
    reached:=false
    for file in report.files {reached||=file.path=="prefabs/lamp.scene"}
    testing.expect(t,report.error==.None && reached && len(report.missing)==0)
    testing.expect_value(t,os.remove(lamp_path),nil)
    report=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && len(report.missing)==1 && report.missing[0].id==PROP && report.scenes_resolved==0)
    testing.expect_value(t,glow_range(t,&types,fmt.tprintf("%s/scenes/level.scene",output)),f32(1))
}

// Files cooked at once on many workers are the files and the report of a
// cook on one: textures of one content share their blocks in the cache, and
// scenes resolve against the same prefab.
@(test)
a_cook_on_many_workers_writes_what_a_cook_on_one_does :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-workers")
    if folder=="" {return}
    assets:=fmt.tprintf("%s/project/assets",folder)
    project_write(t,&types,assets)
    for at in 0..<16 {
        texture_write(t,&types,fmt.tprintf("%s/textures/tile_%02d.tex",assets,at),{8,u64(at)},{.Srgb},at%2==1)
        material_write(t,&types,fmt.tprintf("%s/materials/tile_%02d.mat",assets,at),{10,u64(at)},{8,u64(at)},{})
    }
    lamp_path:=fmt.tprintf("%s/prefabs/lamp.scene",assets)
    lamp:=glow_prefab_write(t,&types,lamp_path,1)
    for at in 0..<6 {
        level:asset.Scene;asset.scene_init(&level,&types,{11,u64(at)})
        _,placed:=asset.scene_instantiate(&level,&lamp,PROP,0)
        testing.expect_value(t,placed,asset.Error.None)
        testing.expect_value(t,asset.scene_save(&level,fmt.tprintf("%s/scenes/level_%d.scene",assets,at)),asset.Error.None)
        asset.scene_destroy(&level)
    }
    asset.scene_destroy(&lamp)
    lamp=glow_prefab_write(t,&types,lamp_path,4)
    asset.scene_destroy(&lamp)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/"]}`)==nil)

    cook :: proc(folder,assets,manifest,name:string,threads:int) -> Cook_Report {
        js:jobs.Job_System
        if !jobs.system_init(&js,{threads=threads,allocator=runtime.heap_allocator()}) {return {error=.Write_Failed}}
        defer jobs.system_destroy(&js)
        return cook_assets({assets=assets,output=fmt.tprintf("%s/%s",folder,name),manifest=manifest,texture_cache=fmt.tprintf("%s/%s_cache",folder,name),worker={system=&js},allocator=context.temp_allocator})
    }
    one:=cook(folder,assets,manifest,"one",0)
    many:=cook(folder,assets,manifest,"many",7)
    testing.expectf(t,one.error==.None && many.error==.None,"%v %s, %v %s",one.error,one.detail,many.error,many.detail)
    testing.expect(t,one.textures_compressed>8 && one.scenes_resolved==6,"textures to compress and scenes to resolve")
    testing.expect(t,len(one.files)==len(many.files) && len(one.dropped)==len(many.dropped) && len(one.missing)==len(many.missing))
    testing.expect(t,one.roots==many.roots && one.textures_compressed==many.textures_compressed && one.scenes_resolved==many.scenes_resolved && one.output_bytes==many.output_bytes && one.source_bytes==many.source_bytes)
    for file,at in one.files {
        if at>=len(many.files) {break}
        other:=many.files[at]
        testing.expectf(t,file.path==other.path && file.id==other.id && file.kind==other.kind && file.bytes==other.bytes && file.compressed==other.compressed && file.resolved==other.resolved,"%s against %s",file.path,other.path)
        written,_:=os.read_entire_file(fmt.tprintf("%s/one/%s",folder,file.path),context.temp_allocator)
        again,_:=os.read_entire_file(fmt.tprintf("%s/many/%s",folder,other.path),context.temp_allocator)
        testing.expectf(t,len(written)>0 && slice.equal(written,again),"%s is not the same",file.path)
    }
    for file,at in one.dropped {
        if at<len(many.dropped) {testing.expect_value(t,many.dropped[at].path,file.path)}
    }
    for lost,at in one.missing {
        if at<len(many.missing) {testing.expect(t,many.missing[at].path==lost.path && many.missing[at].id==lost.id)}
    }
    // A quick cook writes the same files, a little larger, and each reads back as the asset it was.
    quick:=cook_assets({assets=assets,output=fmt.tprintf("%s/quick",folder),manifest=manifest,quick=true,allocator=context.temp_allocator})
    testing.expectf(t,quick.error==.None && len(quick.files)==len(one.files) && quick.output_bytes>=one.output_bytes,"%v %s: %d against %d bytes",quick.error,quick.detail,quick.output_bytes,one.output_bytes)
}

@(test)
a_cook_ships_animations_sampled_on_the_rest_pose_of_their_skeleton :: proc(t:^testing.T) {
    RIG :: base.Asset_Id{7,1}
    CLIPS :: base.Asset_Id{7,2}
    STAGE :: base.Asset_Id{7,3}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-animations")
    if folder=="" {return}
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    for sub in ([]string{"models","scenes"}) {os.make_directory_all(fmt.tprintf("%s/%s",assets,sub))}
    // Bones in centimeters under a root that scales them to meters.
    bones:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={.01,.01,.01}},{parent=0,translation={0,100,0},rotation=1,scale={1,1,1}}}
    base.text_set(bones[0].name[:],"root");base.text_set(bones[0].path[:],"root");bones[0].target=base.name_hash("root")
    base.text_set(bones[1].name[:],"arm");base.text_set(bones[1].path[:],"root/arm");bones[1].target=base.name_hash("root/arm")
    testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/models/rig.skeleton",assets),&types,{id=RIG,bones=bones[:]}),asset.Error.None)
    keys:[61]anim.Keyframe
    for &key,k in keys {key={time=f32(k)/30,value=anim.quat_vec4(quaternion(w=cmath.cos(f32(k)*.05),x=cmath.sin(f32(k)*.05),y=0,z=0))}}
    tracks:=[1]asset.Animation_Track_Desc{{target="root/arm",property=.Rotation,keys=keys[:]}}
    clips:=[1]asset.Animation_Clip_Desc{{name="swing",tracks=tracks[:],skeleton=RIG}}
    path:=fmt.tprintf("%s/models/arm.anim",assets)
    testing.expect_value(t,asset.animation_save(path,&types,{id=CLIPS,clips=clips[:]}),asset.Error.None)
    scene_write(t,&types,fmt.tprintf("%s/scenes/stage.scene",assets),asset.KIND_SCENE,STAGE,CLIPS)

    report:=cook_assets({assets=assets,output=output,manifest=fmt.tprintf("%s/project/%s",folder,COOK_FILE),allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,_:=names(&report)
    testing.expect_value(t,kept,"models/arm.anim models/rig.skeleton scenes/stage.scene ")
    testing.expect_value(t,report.animations_compressed,1)
    shipped:asset.Asset
    testing.expect_value(t,asset.asset_load(&shipped,fmt.tprintf("%s/models/arm.anim",output)),asset.Error.None)
    defer asset.asset_close(&shipped)
    view,error:=asset.animation_view(&shipped,&types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,len(view.tracks)==1 && view.tracks[0].encoding==.Sampled && len(view.keys)==0 && view.clips[0].skeleton==RIG)
    lib:anim.Library
    testing.expect(t,anim.library_init(&lib,asset.animation_library_desc(view)))
    defer anim.library_destroy(&lib)
    testing.expect_value(t,asset.animation_clips_add(view,&lib),anim.Clip(1))
    // The arm swings 100 cm out from a root at 0.01: a point 3 cm from it moves within 0.1 mm.
    for step in 0..=240 {
        time:=f32(step)/120
        exact:=anim.vec4_quat(anim.track_evaluate(keys[:],.Rotation,time))
        played:=anim.vec4_quat(anim.clip_evaluate(&lib,anim.clip_tracks(&lib,1)[0],time))
        moved:=mm.quat_rotate(exact,{0,.03,0})-mm.quat_rotate(played,{0,.03,0})
        testing.expect(t,cmath.sqrt(moved.x*moved.x+moved.y*moved.y+moved.z*moved.z)<=anim.COMPRESS_DEFAULT.precision*1.05)
    }
}
