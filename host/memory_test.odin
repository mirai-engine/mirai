package host

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// What the assets, the content, a UI context and the marks of the Worlds ask
// their allocator for, with the memory ending at each request in turn: the
// call answers that it failed, nothing is left allocated and no asset a World
// names unloads; with memory enough it goes through.
@(test)
host_calls_without_memory_fail_whole :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-memory")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{{position={0,0,0},normal=mm.normal_pack({0,1,0})},{position={1,0,0},normal=mm.normal_pack({0,1,0})},{position={0,0,1},normal=mm.normal_pack({0,1,0})}}
    meshes:=[2]base.Asset_Id{{0x6c6f776d,1},{0x6c6f776d,2}}
    for id,i in meshes {
        testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/m%d.mesh",root,i),&types,id,vertices[:],{0,2,1}),asset.Error.None)
    }
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=8})) {return}
    defer assets_destroy(&assets)

    info,described:=test_info(t,Marks_World)
    if !described {return}
    defer test_info_destroy(&info)

    Call :: enum {Assets_Init,Content,Ui_Context,Marks}
    for call in Call {
        done,refused:=false,false
        for served in 0..<1024 {
            tracking:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracking,context.allocator)
            allocation:=World_Create_Allocation{owner=mem.tracking_allocator(&tracking),remaining=max(int)}
            limited:=runtime.Allocator{world_create_allocator,&allocation}
            ok:bool
            switch call {
            case .Assets_Init:
                a:Assets
                allocation.remaining=served
                ok=assets_init(&a,{root=root,capacity=8,allocator=limited})
                allocation.remaining=max(int)
                if ok {assets_destroy(&a)}
            case .Content:
                app:=App{assets=&assets,allocator=limited}
                allocation.remaining=served
                ok=app_content(&app)!=nil
                allocation.remaining=max(int)
                testing.expectf(t,ok==(app.content!=nil),"%d requests served: the content or none",served)
                app_content_destroy(&app)
            case .Ui_Context:
                app:=App{allocator=limited,density=1}
                allocation.remaining=served
                ctx:=app_ui_context_create(&app)
                allocation.remaining=max(int)
                ok=ctx!=nil
                app_ui_context_destroy(&app,ctx)
            case .Marks:
                for id in meshes {_=assets_mesh(&assets,id)}
                app:=App{info=&info,assets=&assets,allocator=limited,seconds=1}
                app.worlds=make([dynamic]World_Slot,limited)
                w:=cast(^Marks_World)app_world_create(&app)
                if !testing.expect(t,w!=nil) {return}
                model:=core.create(&w.entities)
                core.add(&w.models,model,Marks_Model{meshes[0]})
                core.table_settle(&w.models,&w.entities)
                append(&w.held.list,meshes[0])
                allocation.remaining=served
                unloaded:=app_assets_mark(&app,true)
                allocation.remaining=max(int)
                marks:=&app.asset_marks
                ok=marks.info==&info && !marks.pending && len(marks.worlds)==len(app.worlds)
                testing.expectf(t,assets_loaded(&assets,meshes[0]),"%d requests served: what a World names stays loaded",served)
                testing.expectf(t,assets_loaded(&assets,meshes[1])==!ok && unloaded==(ok?1:0),"%d requests served: nothing unloads before every World is marked",served)
                app_world_free(&app,w)
                assets_marks_free(marks)
                delete(app.worlds)
            }
            testing.expectf(t,len(tracking.allocation_map)==0 && len(tracking.bad_free_array)==0,"%v with %d requests served: %d left allocated",call,served,len(tracking.allocation_map))
            mem.tracking_allocator_destroy(&tracking)
            if done=ok;done {break}
            refused=true
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",call)
    }
}
