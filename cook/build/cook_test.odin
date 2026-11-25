package build

import "base:runtime"
import "core:fmt"
import cmath "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import anim "mirai:std/anim"
import mm "mirai:std/math"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"

@(private) WOOD_COLOR :: base.Asset_Id{1,1}
@(private) WOOD_NORMAL :: base.Asset_Id{1,2}
@(private="file") ICON :: base.Asset_Id{1,3}
@(private="file") UNUSED_TEXTURE :: base.Asset_Id{1,4}
@(private="file") BLOCKS :: base.Asset_Id{1,5}
@(private) WOOD :: base.Asset_Id{2,1}
@(private="file") SPARE :: base.Asset_Id{2,2}
@(private="file") LONELY :: base.Asset_Id{2,3}
@(private="file") LOST :: base.Asset_Id{2,4}
@(private) CRATE :: base.Asset_Id{3,1}
@(private="file") MAIN :: base.Asset_Id{4,1}
@(private="file") HUD :: base.Asset_Id{5,1}
@(private="file") PROP :: base.Asset_Id{6,1}
@(private) LAMP :: base.Asset_Id{6,2}
@(private) ABSENT :: base.Asset_Id{9,9}

@(private="file")
Shown :: struct {mesh:base.Asset_Id}
@(private="file")
Picture :: struct {image:base.Asset_Id}

// 8x8 with two levels; opaque unless `alpha`.
@(private)
texture_write :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,flags:asset.Texture_Flags,alpha:=false,format:=asset.Texture_Format.RGBA8) {
    levels:[2][256]u8
    for &level in levels {
        for &value,at in level {value=at%4==3?(alpha?u8(at):255):u8(at*3)}
    }
    mips:[][]u8={levels[0][:],levels[1][:64]}
    if format==.BC1 {mips={levels[0][:32],levels[1][:8]}}
    testing.expect_value(t,asset.texture_save(path,types,{id=id,width=8,height=8,format=format,flags=flags,mips=mips}),asset.Error.None)
}

@(private)
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
@(private)
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

@(private)
cooked_format :: proc(t:^testing.T,types:^asset.Types,path:string) -> (format:asset.Texture_Format,mips:int) {
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,error:=asset.texture_view(&a,types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,asset.blob_verify_hash(&a.blob))
    return view.info.format,len(view.mips)
}

@(private)
names :: proc(report:^Cook_Report) -> (kept,dropped:string) {
    b:=strings.builder_make(context.temp_allocator)
    for file in report.files {fmt.sbprintf(&b,"%s ",file.path)}
    kept=strings.clone(strings.to_string(b),context.temp_allocator)
    strings.builder_reset(&b)
    for file in report.dropped {fmt.sbprintf(&b,"%s ",file.path)}
    return kept,strings.to_string(b)
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
    // Two files with one id, as a copy made outside the editor has: which one is the asset depends on the machine.
    testing.expect(t,os.remove(manifest)==nil)
    copy:=fmt.tprintf("%s/materials/wood copy.mat",assets)
    wood,_:=os.read_entire_file(fmt.tprintf("%s/materials/wood.mat",assets),context.temp_allocator)
    testing.expect(t,os.write_entire_file(copy,wood)==nil)
    twins:=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expectf(t,twins.error==.Duplicate_Id && strings.contains(twins.detail,"materials/wood.mat") && strings.contains(twins.detail,"materials/wood copy.mat") && !os.exists(output),"%v %s",twins.error,twins.detail)
    testing.expect(t,os.remove(copy)==nil)
    // An output that cannot be a folder.
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/blocked",folder),"a file")==nil)
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
    testing.expect(t,base.make_directory_all(fmt.tprintf("%s/scenes/main.scene",output))==nil)
    testing.expect(t,base.make_directory_all(fmt.tprintf("%s/textures/wood_normal.tex",output))==nil)
    testing.expect_value(t,os.write_entire_file(manifest,`{"textures":"keep"}`),nil)
    halfway:=cook_assets({assets=assets,output=output,manifest=manifest,
        allocator=context.temp_allocator})
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
    testing.expect(t,base.make_directory_all(fmt.tprintf("%s/brushes",plugin))==nil)
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

@(private)
glow_prefab_write :: proc(t:^testing.T,types:^asset.Types,path:string,range:f32) -> (lamp:asset.Scene) {
    asset.scene_init(&lamp,types,LAMP)
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
    _,placed:=asset.scene_instantiate(&level,&lamp,LAMP,0)
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
    testing.expect(t,report.error==.None && len(report.missing)==1 && report.missing[0].id==LAMP && report.scenes_resolved==0)
    testing.expect_value(t,glow_range(t,&types,fmt.tprintf("%s/scenes/level.scene",output)),f32(1))
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

@(private="file") Far_Test_Renderer :: struct {mesh:base.Asset_Id}
@(private="file") Far_Test_Reference :: struct {scene:base.Asset_Id}

// A game that streams sections ships the far mesh of each scene a section
// references beside it, which its runtime shows and does not make; one that
// does not stream ships none.
@(test)
a_cook_writes_the_far_mesh_of_each_scene_a_section_references :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-far")
    if folder=="" {return}
    WORLD :: base.Asset_Id{0xfa,0x10}
    ROOM :: base.Asset_Id{0xfa,0x11}
    SHEET :: base.Asset_Id{0xfa,0x12}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets:=fmt.tprintf("%s/assets",folder)
    testing.expect(t,base.make_directory_all(fmt.tprintf("%s/rooms",assets))==nil)
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for z in 0..=8 {for x in 0..=8 {append(&vertices,asset.Vertex{position={f32(x),0,f32(z)},normal=mm.normal_pack({0,1,0}),color=0xffffffff,tangent=mm.tangent_pack({1,0,0},1)})}}
    for z in 0..<u32(8) {for x in 0..<u32(8) {a:=z*9+x;append(&indices,a,a+9,a+1,a+1,a+9,a+10)}}
    g:asset.Mesh_Geometry
    testing.expect(t,asset.mesh_build_dag({vertices=vertices[:]},indices[:],&g,context.temp_allocator))
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/rooms/sheet.mesh",assets),&types,{id=SHEET,geometry=g}),asset.Error.None)
    room:asset.Scene;asset.scene_init(&room,&types,ROOM)
    asset.scene_entity_add(&room,1,0,"Floor")
    asset.scene_set(&room,1,"Mesh_Renderer",&Far_Test_Renderer{SHEET})
    testing.expect_value(t,asset.scene_save(&room,fmt.tprintf("%s/rooms/room.scene",assets)),asset.Error.None)
    asset.scene_destroy(&room)
    world:asset.Scene;asset.scene_init(&world,&types,WORLD)
    asset.scene_entity_add(&world,1,0,"Room")
    asset.scene_set(&world,1,"Scene_Reference",&Far_Test_Reference{ROOM})
    testing.expect_value(t,asset.scene_save(&world,fmt.tprintf("%s/world.scene",assets)),asset.Error.None)
    asset.scene_destroy(&world)

    for streams in ([]bool{true,false}) {
        output:=fmt.tprintf("%s/game-%v/assets",folder,streams)
        report:=cook_assets({assets=assets,output=output,far=streams,quick=true,allocator=context.temp_allocator})
        if !testing.expect_value(t,report.error,Cook_Error.None) {return}
        path:=fmt.tprintf("%s/rooms/room.far.mesh",output)
        testing.expect_value(t,report.far_meshes,streams?1:0)
        testing.expect_value(t,os.exists(path),streams)
        if !streams {continue}
        shipped:asset.Registry
        asset.registry_init(&shipped,output,"",context.temp_allocator)
        defer asset.registry_destroy(&shipped)
        testing.expect_value(t,asset.registry_load(&shipped,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
        file,found:=asset.registry_find(&shipped,asset.far_mesh_id(ROOM))
        testing.expect(t,found && file.kind==asset.KIND_MESH && file.path=="rooms/room.far.mesh","the index lists it by the id the runtime asks for")
        // A cook that keeps keys makes it again only when what it is made of changed.
        keys:=fmt.tprintf("%s/game.cook",folder)
        for reused in ([]int{0,len(report.files)}) {
            again:=cook_assets({assets=assets,output=output,far=true,quick=true,keys=keys,allocator=context.temp_allocator})
            testing.expect(t,again.error==.None && again.far_meshes==1 && again.reused==reused,"a far mesh made of what it was is kept")
        }
    }
}

@(private="file") Pieces_Test_Renderer :: struct {mesh:base.Asset_Id}
@(private="file") Pieces_Test_Collider :: struct {kind:enum u8 {Box,Sphere,Capsule,Cylinder,Hull,Mesh,Heightfield,External,Auto}}
@(private="file") Pieces_Test_Body :: struct {type:enum u32 {Static,Kinematic,Dynamic}}

// A mesh without colliders of its source that a scene moves with an Auto
// Collider ships with the convex pieces it collides as, which a game without
// a cache reads; one only a still body shows ships as it is.
@(test)
a_cook_ships_the_convex_pieces_of_a_mesh_a_body_moves :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-pieces")
    if folder=="" {return}
    LEVEL :: base.Asset_Id{0xc0,0x10}
    MOVED :: base.Asset_Id{0xc0,0x11}
    STILL :: base.Asset_Id{0xc0,0x12}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets:=fmt.tprintf("%s/assets",folder)
    testing.expect(t,base.make_directory_all(assets)==nil)
    // An L of two boxes: not convex.
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for part in 0..<2 {
        low:=part==0?[3]f32{0,0,0}:[3]f32{0,1,0}
        high:=part==0?[3]f32{3,1,1}:[3]f32{1,3,1}
        first:=u32(len(vertices))
        for corner in 0..<8 {append(&vertices,asset.Vertex{position={corner&1!=0?high.x:low.x,corner&2!=0?high.y:low.y,corner&4!=0?high.z:low.z},color=0xffffffff})}
        faces:=[36]u32{0,2,1,1,2,3, 4,5,6,5,7,6, 0,1,4,1,5,4, 2,6,3,3,6,7, 0,4,2,2,4,6, 1,3,5,3,7,5}
        for index in faces {append(&indices,first+index)}
    }
    g:asset.Mesh_Geometry
    if !testing.expect(t,asset.mesh_build({vertices=vertices[:]},indices[:],nil,&g,context.temp_allocator)) {return}
    for id,name in ([2]base.Asset_Id{MOVED,STILL}) {
        testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/%s.mesh",assets,name==0?"moved":"still"),&types,{id=id,geometry=g}),asset.Error.None)
    }
    level:asset.Scene;asset.scene_init(&level,&types,LEVEL)
    for mesh,at in ([2]base.Asset_Id{MOVED,STILL}) {
        e:=base.Entity_Id(at+1)
        asset.scene_entity_add(&level,e,0,"Prop")
        asset.scene_set(&level,e,"Mesh_Renderer",&Pieces_Test_Renderer{mesh})
        asset.scene_set(&level,e,"Collider",&Pieces_Test_Collider{.Auto})
    }
    asset.scene_set(&level,1,"Rigid_Body",&Pieces_Test_Body{.Dynamic})
    testing.expect_value(t,asset.scene_save(&level,fmt.tprintf("%s/level.scene",assets)),asset.Error.None)
    asset.scene_destroy(&level)

    output:=fmt.tprintf("%s/game/assets",folder)
    report:=cook_assets({assets=assets,output=output,quick=true,collision_cache=fmt.tprintf("%s/collision",folder),allocator=context.temp_allocator})
    if !testing.expect_value(t,report.error,Cook_Error.None) {return}
    for name,at in ([2]string{"moved","still"}) {
        cooked:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&cooked,fmt.tprintf("%s/%s.mesh",output,name)),asset.Error.None) {return}
        defer asset.asset_close(&cooked)
        view,error:=asset.mesh_view(&cooked,&types)
        testing.expect_value(t,error,asset.Error.None)
        if at==0 {
            testing.expectf(t,len(view.piece_sizes)>=2,"the mesh a body moves ships its pieces: %d",len(view.piece_sizes))
            points:=make([dynamic][3]f32,context.temp_allocator)
            sizes:=make([dynamic]u32,context.temp_allocator)
            testing.expect(t,asset.mesh_collision_pieces(&cooked,&types,"",&points,&sizes) && len(sizes)==len(view.piece_sizes),"a game without a cache reads them")
        } else {
            testing.expect_value(t,len(view.piece_sizes),0)
        }
    }
}

@(private="file") Retarget_Test_Renderer :: struct {mesh:base.Asset_Id}
@(private="file") Retarget_Test_Animation :: struct {asset,library:base.Asset_Id}

// An .anim a scene plays on a mesh of a skeleton it was not made on ships its retarget onto that
// skeleton beside it, the cooked .anim of asset.animation_retarget_id, which a shipped game reads
// instead of retargeting; played on its own skeleton it needs none, and a cook of the same files
// keeps the one written before.
@(private="file") RETARGET_LEVEL :: base.Asset_Id{0xc1,0x10}
@(private="file") RETARGET_SOURCE :: base.Asset_Id{0xc1,0x11}
@(private="file") RETARGET_TARGET :: base.Asset_Id{0xc1,0x12}
@(private="file") RETARGET_CLIPS :: base.Asset_Id{0xc1,0x13}

// Two skeletons of other names and lengths, a skinned mesh of each (rig0.mesh, rig1.mesh) and an
// .anim made on the first (kick.anim), in folder/assets.
@(private="file")
retarget_cook_assets :: proc(t:^testing.T,folder:string,types:^asset.Types) -> (assets:string,ok:bool) {
    SOURCE,TARGET,CLIPS :: RETARGET_SOURCE,RETARGET_TARGET,RETARGET_CLIPS
    MESHES:=[2]base.Asset_Id{{0xc1,0x14},{0xc1,0x15}}
    assets=fmt.tprintf("%s/assets",folder)
    testing.expect(t,base.make_directory_all(assets)==nil)
    // The source names its bones otherwise than the target and is shorter: they pair by the parts
    // of the body both mark.
    Bone :: struct {name:string,parent:i32,at:mm.Vec3,part:anim.Body_Part}
    skeletons:=[2][4]Bone{
        {{"Hips",-1,{0,1,0},.Pelvis},{"LeftUpLeg",0,{.1,0,0},.Hip_L},{"LeftLeg",1,{0,-.45,0},.Knee_L},{"LeftFoot",2,{0,-.45,0},.Foot_L}},
        {{"pelvis",-1,{0,.8,0},.Pelvis},{"thigh_l",0,{.08,0,0},.Hip_L},{"calf_l",1,{0,-.36,0},.Knee_L},{"foot_l",2,{0,-.36,0},.Foot_L}},
    }
    for rows,i in skeletons {
        bones:[4]asset.Skeleton_Bone
        parts:[4]asset.Skeleton_Body_Part
        path:string
        for row,b in rows {
            path=row.name if row.parent<0 else fmt.tprintf("%s/%s",path,row.name)
            bones[b]={parent=row.parent,translation=row.at,rotation=1,scale={1,1,1},target=base.name_hash(path)}
            base.text_set(bones[b].name[:],row.name);base.text_set(bones[b].path[:],path)
            parts[b]={part=row.part,confidence=1};base.text_set(parts[b].bone[:],path)
        }
        body:=asset.Skeleton_Body{up={0,1,0},confidence=1}
        testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/skeleton%d.skeleton",assets,i),types,{id=SOURCE if i==0 else TARGET,bones=bones[:],body=&body,body_parts=parts[:]}),asset.Error.None)
        vertices:=[3]asset.Vertex{{position={-1,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
        skin:[3]asset.Skin_Vertex
        for &v in skin {v.weights[0]=255}
        joints:=[1]asset.Rig_Joint{{node=0,inverse_bind=1}}
        desc:=asset.Mesh_Desc{id=MESHES[i],skeleton=SOURCE if i==0 else TARGET,joints=joints[:]}
        if !testing.expect(t,asset.mesh_build({vertices=vertices[:],skin=skin[:]},{0,1,2},nil,&desc.geometry,context.temp_allocator)) {return}
        testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/rig%d.mesh",assets,i),types,desc),asset.Error.None)
    }
    bend:=[3]anim.Keyframe{{time=0,value=anim.quat_vec4(1)},{time=.5,value=anim.quat_vec4(mm.quat_axis_angle({1,0,0},.8))},{time=1,value=anim.quat_vec4(1)}}
    tracks:=[1]asset.Animation_Track_Desc{{target="Hips/LeftUpLeg/LeftLeg",property=.Rotation,keys=bend[:]}}
    clips:=[1]asset.Animation_Clip_Desc{{name="kick",tracks=tracks[:],skeleton=SOURCE}}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/kick.anim",assets),types,{id=CLIPS,clips=clips[:]}),asset.Error.None)
    return assets,true
}

// The cooked retarget of kick.anim onto the target in a cook, as it ships and reads back.
@(private="file")
retarget_cook_check :: proc(t:^testing.T,report:^Cook_Report,output:string,types:^asset.Types,reused:bool,loc:=#caller_location) {
    testing.expectf(t,report.retargets==1 && len(report.unretargeted)==0,"%d retargets, %v",report.retargets,report.unretargeted,loc=loc)
    text:[base.ASSET_ID_TEXT]u8
    path:=fmt.tprintf("kick.%s.anim",base.asset_id_format(RETARGET_TARGET,text[:]))
    written:=false
    for file in report.files {
        if file.path!=path {continue}
        written=true
        testing.expectf(t,file.id==asset.animation_retarget_id(RETARGET_CLIPS,RETARGET_TARGET) && file.reused==reused,"%v",file,loc=loc)
    }
    testing.expectf(t,written,"%s is not written",path,loc=loc)
    cooked:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&cooked,fmt.tprintf("%s/%s",output,path)),asset.Error.None,loc=loc) {return}
    defer asset.asset_close(&cooked)
    view,error:=asset.animation_view(&cooked,types)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return}
    testing.expect(t,len(view.clips)==1 && view.clips[0].skeleton==RETARGET_TARGET && view.clips[0].stream_bytes>0,"its clip is compressed on the target",loc=loc)
}

@(test)
a_cook_ships_the_retarget_of_an_animation_a_scene_plays_on_another_skeleton :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-retarget")
    if folder=="" {return}
    MESHES:=[2]base.Asset_Id{{0xc1,0x14},{0xc1,0x15}}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets,made:=retarget_cook_assets(t,folder,&types)
    if !made {return}
    level:asset.Scene;asset.scene_init(&level,&types,RETARGET_LEVEL)
    for mesh,at in MESHES {
        e:=base.Entity_Id(at+1)
        asset.scene_entity_add(&level,e,0,"Rig")
        asset.scene_set(&level,e,"Mesh_Renderer",&Retarget_Test_Renderer{mesh})
        asset.scene_set(&level,e,"Animation",&Retarget_Test_Animation{asset=RETARGET_CLIPS})
    }
    testing.expect_value(t,asset.scene_save(&level,fmt.tprintf("%s/level.scene",assets)),asset.Error.None)
    asset.scene_destroy(&level)

    output:=fmt.tprintf("%s/game/assets",folder)
    keys:=fmt.tprintf("%s/keys.bin",folder)
    for pass in 0..<2 {
        report:=cook_assets({assets=assets,output=output,keys=keys,quick=true,allocator=context.temp_allocator})
        if !testing.expect_value(t,report.error,Cook_Error.None) {return}
        retarget_cook_check(t,&report,output,&types,pass==1)
    }
}

// A pair only code plays together, declared in cook.mirai, ships its retarget with the animation
// and the mesh it names, though no scene names them.
@(test)
a_cook_ships_the_retarget_cook_mirai_declares :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-retarget-declared")
    if folder=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    assets,made:=retarget_cook_assets(t,folder,&types)
    if !made {return}
    manifest:=fmt.tprintf("%s/cook.mirai",folder)
    testing.expect(t,os.write_entire_file(manifest,transmute([]u8)string(`{"retargets":[["kick.anim","rig1.mesh"]]}`))==nil)
    output:=fmt.tprintf("%s/game/assets",folder)
    report:=cook_assets({assets=assets,output=output,manifest=manifest,quick=true,allocator=context.temp_allocator})
    if !testing.expect_value(t,report.error,Cook_Error.None) {return}
    retarget_cook_check(t,&report,output,&types,false)
    for path in ([3]string{"kick.anim","rig1.mesh","skeleton1.skeleton"}) {
        testing.expectf(t,os.exists(fmt.tprintf("%s/%s",output,path)),"%s ships",path)
    }
    // One it cannot find fails the cook by its name.
    testing.expect(t,os.write_entire_file(manifest,transmute([]u8)string(`{"retargets":[["kick.anim","gone.mesh"]]}`))==nil)
    failed:=cook_assets({assets=assets,output=output,manifest=manifest,quick=true,allocator=context.temp_allocator})
    testing.expectf(t,failed.error==.Root_Missing && strings.contains(failed.detail,"gone.mesh"),"%v %s",failed.error,failed.detail)
}