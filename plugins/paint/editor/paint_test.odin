package paint_editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import paint "plugins:paint/runtime"
import "mirai:std/base"

@(private)
@(test_world)
Paint_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    meshes:core.Table(erender.Mesh_Renderer),
    painted:core.Table(paint.Painted),
}

// A cube with Id 7 in a world of its own, with its assets under a folder that goes with the test.
@(private)
Paint_Test :: struct {
    root:string,
    assets:host.Assets,
    world:Paint_Test_World,
    ref:core.World_Ref,
    cube:core.Entity,
    app:host.App,
    selection:history.Selection,
    edits:history.Edits,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    session:editor.Session,
}

@(private)
paint_test_open :: proc(t:^testing.T,f:^Paint_Test,name:string) -> bool {
    f.root=base.test_folder(t,name)
    if f.root=="" || !testing.expect(t,host.assets_init(&f.assets,{root=f.root,capacity=16})) {return false}
    w:=&f.world
    if !test_world_init(t,w) {
        host.assets_destroy(&f.assets)
        return false
    }
    f.ref=test_world_ref(w)
    f.cube=core.create(&w.entities)
    core.add(&w.ids,f.cube,core.Id{value=7})
    core.add(&w.meshes,f.cube,erender.Mesh_Renderer{shape=.Cube})
    core.world_settle(f.ref)
    f.app={allocator=context.allocator,assets=&f.assets}
    history.edits_reset(&f.edits,f.ref)
    f.session={app=&f.app,info=test_world_info(w),edit_world=&f.world,assets_root=f.root,headless=true,selection=&f.selection,edits=&f.edits,viewport=&f.viewport,gui=&f.gui}
    return true
}

@(private)
paint_test_close :: proc(f:^Paint_Test) {
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    test_world_destroy(&f.world)
    host.assets_destroy(&f.assets)
}

// Begins a stroke on the cube as stroke_begin does after its pick, with every
// vertex under the brush and the copy named by seed.
@(private)
paint_test_stroke :: proc(t:^testing.T,tool:^Paint_Tool,app:^host.App,e:core.Entity,source:erender.Mesh_Renderer,root:string,seed:u64) -> bool {
    stroke:=&tool.stroke
    stroke_free(tool)
    if !testing.expect(t,stroke_load(stroke,app.assets,e,source,{rotation=1,scale=1},app.allocator)) {return false}
    for &weight in stroke.weights {weight=1}
    delete(stroke.path,app.allocator)
    stroke.id=base.Asset_Id{seed,base.hash_combine(seed,base.name_hash("Painted"))}
    stroke.path=fmt.aprintf("%s/%s/%016x.mesh",root,FOLDER,stroke.id[0],allocator=app.allocator)
    stroke.active,stroke.dirty=true,true
    return true
}

@(test)
painted_copies_stay_in_memory_until_saved_and_go_with_undo_and_cancel :: proc(t:^testing.T) {
    f:Paint_Test
    if !paint_test_open(t,&f,"paint") {return}
    defer paint_test_close(&f)
    root,ref,e,s,world:=f.root,f.ref,f.cube,&f.session,&f.world
    app,edits,selection:=&f.app,&f.edits,&f.selection
    cube:=erender.Mesh_Renderer{shape=.Cube}
    tool:Paint_Tool;tool_ready(&tool);defer paint_tool_free(&tool)
    tool.color,tool.strength=[3]f32{1,0,0},1

    if !paint_test_stroke(t,&tool,app,e,cube,root,0x51) {return}
    first,first_path:=tool.stroke.id,fmt.tprintf("%s/%s/%016x.mesh",root,FOLDER,u64(0x51))
    testing.expect(t,stroke_write(s,&tool,ref,app.assets,app.allocator))
    tool.stroke.dirty=true
    testing.expect(t,stroke_write(s,&tool,ref,app.assets,app.allocator))
    stroke_end(s,&tool,ref,app.assets,app.allocator)
    if !testing.expect(t,history.edits_commit(edits,ref,selection)) {return}
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,core.at(&world.meshes,core.row_of(&world.meshes,e)).mesh,first)
    testing.expect(t,editor.file_exists(s,first_path) && !os.exists(first_path))
    testing.expect(t,editor.asset_unsaved(s,first))

    // The next stroke reads the unsaved copy.
    painted:=core.at(&world.meshes,core.row_of(&world.meshes,e))
    if !paint_test_stroke(t,&tool,app,e,painted,root,0x52) {return}
    testing.expect_value(t,tool.stroke.before[0],u32(0xff0000ff))
    second_path:=fmt.tprintf("%s/%s/%016x.mesh",root,FOLDER,u64(0x52))
    tool.color=[3]f32{0,0,1}
    testing.expect(t,stroke_write(s,&tool,ref,app.assets,app.allocator))
    testing.expect(t,editor.file_exists(s,second_path))
    stroke_cancel(s,&tool,ref)
    testing.expect(t,!editor.file_exists(s,second_path))
    testing.expect_value(t,core.at(&world.meshes,core.row_of(&world.meshes,e)).mesh,first)
    testing.expect_value(t,edits.cursor,1)

    testing.expect(t,history.undo(edits,ref,selection))
    editor.files_settle(s)
    testing.expect_value(t,core.at(&world.meshes,core.row_of(&world.meshes,e)),cube)
    testing.expect(t,!core.has(&world.painted,e))
    testing.expect(t,!editor.file_exists(s,first_path))
    testing.expect_value(t,len(editor.assets_unsaved(s)),0)
    testing.expect(t,history.redo(edits,ref,selection))
    editor.files_settle(s)
    testing.expect_value(t,core.at(&world.meshes,core.row_of(&world.meshes,e)).mesh,first)
    testing.expect(t,editor.file_exists(s,first_path))
    saved,written:=editor.assets_save_all(s)
    testing.expect(t,written && saved==1 && os.exists(first_path))
    testing.expect_value(t,len(editor.assets_unsaved(s)),0)
}

@(test)
paint_api_strokes_along_points_and_clears_as_steps_of_undo :: proc(t:^testing.T) {
    f:Paint_Test
    if !paint_test_open(t,&f,"paint-api") {return}
    defer paint_test_close(&f)
    s,e:=&f.session,f.cube
    stroke_method:=api.Method{params_id=Stroke_Params,result_id=Stroke_Result}
    clear_method:=api.Method{params_id=Clear_Params,result_id=Clear_Result}

    // Along an edge of the cube the brush paints the vertices of its two corners and no other.
    params:=Stroke_Params{radius=0.3,strength=1,color={0,1,0}};copy(params.entity[:],"0000000000000007")
    params.points[0],params.points[1]={0.5,0.5,0.5},{0.5,0.5,-0.5}
    result:Stroke_Result
    call:=api.Call{method=&stroke_method,params=&params,result=&result,raw=`{"entity":"0000000000000007","points":[[0.5,0.5,0.5],[0.5,0.5,-0.5]]}`,allocator=context.temp_allocator}
    api_stroke(s,&call)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    testing.expect_value(t,result.vertices,u32(24))
    testing.expect_value(t,result.changed,u32(6))
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect_value(t,core.at(&f.world.meshes,core.row_of(&f.world.meshes,e)).mesh,result.mesh)
    testing.expect_value(t,core.at(&f.world.painted,core.row_of(&f.world.painted,e)),paint.Painted{shape=.Cube})
    path:=fmt.tprintf("%s/%s",f.root,base.text_get(result.path[:]))
    testing.expect(t,editor.file_exists(s,path) && !os.exists(path))
    testing.expect(t,editor.asset_unsaved(s,result.mesh))

    // Away from the mesh nothing is painted and no step is made.
    params.points[0]={10,10,10}
    far:Stroke_Result
    away:=api.Call{method=&stroke_method,params=&params,result=&far,raw=`{"entity":"0000000000000007","points":[[10,10,10]]}`,allocator=context.temp_allocator}
    api_stroke(s,&away)
    testing.expect(t,away.failed && away.error.code==api.INVALID_PARAMS)
    testing.expect_value(t,f.edits.cursor,1)

    clear_params:Clear_Params
    copy(clear_params.entities[0][:],"0000000000000007")
    cleared:Clear_Result
    clear:=api.Call{method=&clear_method,params=&clear_params,result=&cleared,allocator=context.temp_allocator}
    api_clear(s,&clear)
    if !testing.expectf(t,!clear.failed,"%s",clear.error.message) {return}
    testing.expect_value(t,cleared.cleared,u32(1))
    testing.expect_value(t,f.edits.cursor,2)
    testing.expect_value(t,core.at(&f.world.meshes,core.row_of(&f.world.meshes,e)),erender.Mesh_Renderer{shape=.Cube})
    testing.expect(t,!core.has(&f.world.painted,e))
    again:=api.Call{method=&clear_method,params=&clear_params,result=&cleared,allocator=context.temp_allocator}
    api_clear(s,&again)
    testing.expect(t,again.failed && again.error.code==api.INVALID_PARAMS)
    testing.expect_value(t,f.edits.cursor,2)

    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    testing.expect_value(t,core.at(&f.world.meshes,core.row_of(&f.world.meshes,e)).mesh,result.mesh)
    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    editor.files_settle(s)
    testing.expect_value(t,core.at(&f.world.meshes,core.row_of(&f.world.meshes,e)),erender.Mesh_Renderer{shape=.Cube})
    testing.expect(t,!editor.file_exists(s,path))
}
