package streaming_editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"
import streaming "plugins:streaming/runtime"

@(private="file") Far_Test_Renderer :: struct {mesh:base.Asset_Id}

// The editor makes the far mesh of a scene once, into the far cache of the
// project, which its registry lists by what the scene is made of: a second
// session, or a game of the project that is not cooked, finds it and makes
// none; a mesh of the scene that changes asks for another.
@(test)
a_far_mesh_is_made_once_into_the_cache_and_found_by_the_next_session :: proc(t:^testing.T) {
    ROOM :: base.Asset_Id{0xfa,0x21}
    SHEET :: base.Asset_Id{0xfa,0x22}
    root:=base.test_folder(t,"far-cache")
    if root=="" {return}
    assets:=project.path(root,"assets",allocator=context.temp_allocator)
    cache:=project.cache_path(root,project.FAR_CACHE,allocator=context.temp_allocator)
    for folder in ([]string{assets,cache}) {if !testing.expect(t,os.make_directory_all(folder)==nil) {return}}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    sheet :: proc(t:^testing.T,types:^asset.Types,path:string,side:int) {
        vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
        indices:=make([dynamic]u32,context.temp_allocator)
        row:=u32(side+1)
        for z in 0..=side {for x in 0..=side {append(&vertices,asset.Vertex{position={f32(x),0,f32(z)},normal=mm.normal_pack({0,1,0}),color=0xffffffff,tangent=mm.tangent_pack({1,0,0},1)})}}
        for z in 0..<u32(side) {for x in 0..<u32(side) {a:=z*row+x;append(&indices,a,a+row,a+1,a+1,a+row,a+row+1)}}
        g:asset.Mesh_Geometry
        testing.expect(t,asset.mesh_build_dag({vertices=vertices[:]},indices[:],&g,context.temp_allocator))
        testing.expect_value(t,asset.mesh_save(path,types,{id=SHEET,geometry=g}),asset.Error.None)
    }
    sheet(t,&types,fmt.tprintf("%s/sheet.mesh",assets),8)
    room:asset.Scene;asset.scene_init(&room,&types,ROOM)
    asset.scene_entity_add(&room,1,0,"Floor")
    asset.scene_set(&room,1,"Mesh_Renderer",&Far_Test_Renderer{SHEET})
    testing.expect_value(t,asset.scene_save(&room,fmt.tprintf("%s/room.scene",assets)),asset.Error.None)
    asset.scene_destroy(&room)

    // A session: what it makes, and the key of the scene it made it of.
    session :: proc(t:^testing.T,root,assets,cache:string,scene:base.Asset_Id) -> (made:int,key:u64,found:bool) {
        a:host.Assets
        mounts:=[1]asset.Registry_Mount{{folder=cache,prefix=project.FAR_PREFIX}}
        if !testing.expect(t,host.assets_init(&a,{root=assets,capacity=16,mounts=mounts[:]})) {return}
        defer host.assets_destroy(&a)
        app:=host.App{assets=&a,root=root,allocator=context.allocator}
        defer host.app_assets_releases_stop(&app)
        key=asset.far_key(&a.registry,scene)
        meshes:=streaming.Streaming_Far{}
        defer delete(meshes.scenes)
        append(&meshes.scenes,streaming.Far_Mesh{scene=scene,key=key})
        builds:Far_Builds
        defer far_builds_free(&builds)
        problems:core.Problems
        for _ in 0..<16 {
            streaming_far_build(&app,core.ref(&meshes),&builds,&problems)
            made=max(made,len(builds.tried))
        }
        _,found=asset.registry_find(&a.registry,asset.far_cache_id(key))
        testing.expect_value(t,problems.count,0)
        return
    }
    made,key,found:=session(t,root,assets,cache,ROOM)
    testing.expect(t,made==1 && found,"the first session makes it, and its registry lists it")
    made,_,found=session(t,root,assets,cache,ROOM)
    testing.expect(t,made==0 && found,"the next finds it and makes none")
    sheet(t,&types,fmt.tprintf("%s/sheet.mesh",assets),12)
    changed:u64
    made,changed,found=session(t,root,assets,cache,ROOM)
    testing.expect(t,changed!=key && made==1 && found,"a mesh that changed makes another")
}
