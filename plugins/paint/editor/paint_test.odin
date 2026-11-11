package paint_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import paint "plugins:paint/runtime"
import "mirai:std/base"
import mm "mirai:std/math"

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
    document:editor.Document,
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
    f.session={app=&f.app,info=test_world_info(w),edit_world=&f.world,assets_root=f.root,headless=true,selection=&f.selection,edits=&f.edits,viewport=&f.viewport,gui=&f.gui,document=&f.document}
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
// vertex under the brush and the colors named by seed.
@(private)
paint_test_stroke :: proc(t:^testing.T,tool:^Paint_Tool,app:^host.App,e:core.Entity,painted:base.Asset_Id,root:string,seed:u64) -> bool {
    stroke:=&tool.stroke
    stroke_free(tool)
    if !testing.expect(t,stroke_load(stroke,app.assets,e,{shape=.Cube},painted,{rotation=1,scale=1},app.allocator)) {return false}
    for &weight in stroke.weights {weight=1}
    delete(stroke.path,app.allocator)
    stroke.id=base.Asset_Id{seed,base.hash_combine(seed,base.name_hash("Painted"))}
    stroke.path=fmt.aprintf("%s/%s/%016x%s",root,FOLDER,stroke.id[0],paint.PAINT_EXTENSION,allocator=app.allocator)
    stroke.active,stroke.dirty=true,true
    return true
}

@(test)
painted_colors_reach_the_disk_at_the_flush_and_go_with_undo_and_cancel :: proc(t:^testing.T) {
    f:Paint_Test
    if !paint_test_open(t,&f,"paint") {return}
    defer paint_test_close(&f)
    root,ref,e,s,world:=f.root,f.ref,f.cube,&f.session,&f.world
    app,edits,selection:=&f.app,&f.edits,&f.selection
    cube:=erender.Mesh_Renderer{shape=.Cube}
    tool:Paint_Tool;tool_ready(&tool);defer paint_tool_free(&tool)
    tool.color,tool.strength=[3]f32{1,0,0},1

    if !paint_test_stroke(t,&tool,app,e,{},root,0x51) {return}
    first,first_path:=tool.stroke.id,fmt.tprintf("%s/%s/%016x%s",root,FOLDER,u64(0x51),paint.PAINT_EXTENSION)
    testing.expect(t,stroke_write(s,&tool,ref,app.assets,app.allocator))
    tool.stroke.dirty=true
    testing.expect(t,stroke_write(s,&tool,ref,app.assets,app.allocator))
    stroke_end(s,&tool,ref,app.assets,app.allocator)
    if !testing.expect(t,history.edits_commit(edits,ref,selection)) {return}
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,core.at(&world.meshes,core.row_of(&world.meshes,e)),cube)
    testing.expect_value(t,core.at(&world.painted,core.row_of(&world.painted,e)).colors,first)
    testing.expect(t,editor.file_exists(s,first_path) && !os.exists(first_path))

    // The next stroke reads the colors the registry holds.
    if !paint_test_stroke(t,&tool,app,e,first,root,0x52) {return}
    testing.expect_value(t,tool.stroke.before[0],u32(0xff0000ff))
    second_path:=fmt.tprintf("%s/%s/%016x%s",root,FOLDER,u64(0x52),paint.PAINT_EXTENSION)
    tool.color=[3]f32{0,0,1}
    testing.expect(t,stroke_write(s,&tool,ref,app.assets,app.allocator))
    testing.expect(t,editor.file_exists(s,second_path))
    stroke_cancel(s,&tool,ref)
    testing.expect(t,!editor.file_exists(s,second_path))
    testing.expect_value(t,core.at(&world.painted,core.row_of(&world.painted,e)).colors,first)
    testing.expect_value(t,edits.cursor,1)

    testing.expect(t,history.undo(edits,ref,selection))
    editor.files_settle(s)
    testing.expect_value(t,core.at(&world.meshes,core.row_of(&world.meshes,e)),cube)
    testing.expect(t,!core.has(&world.painted,e))
    testing.expect(t,!editor.file_exists(s,first_path))
    testing.expect(t,editor.files_flush(s,true) && !os.exists(first_path))
    testing.expect(t,history.redo(edits,ref,selection))
    editor.files_settle(s)
    testing.expect_value(t,core.at(&world.painted,core.row_of(&world.painted,e)).colors,first)
    testing.expect(t,editor.file_exists(s,first_path))
    testing.expect(t,editor.files_flush(s,true) && os.exists(first_path))
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
    testing.expect_value(t,core.at(&f.world.meshes,core.row_of(&f.world.meshes,e)),erender.Mesh_Renderer{shape=.Cube})
    testing.expect_value(t,core.at(&f.world.painted,core.row_of(&f.world.painted,e)),paint.Painted{colors=result.colors})
    path:=fmt.tprintf("%s/%s",f.root,base.text_get(result.path[:]))
    testing.expect(t,editor.file_exists(s,path) && !os.exists(path))

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
    testing.expect_value(t,core.at(&f.world.painted,core.row_of(&f.world.painted,e)).colors,result.colors)
    testing.expect(t,history.undo(&f.edits,f.ref,&f.selection))
    editor.files_settle(s)
    testing.expect_value(t,core.at(&f.world.meshes,core.row_of(&f.world.meshes,e)),erender.Mesh_Renderer{shape=.Cube})
    testing.expect(t,!editor.file_exists(s,path))
    testing.expect(t,editor.files_flush(s,true) && !os.exists(path))
}

// A stroke over one of two entities of a mesh of levels paints the vertices
// of every level of it, the mesh stays as it was and the other entity
// keeps the colors of the mesh.
@(test)
a_stroke_paints_every_level_of_a_mesh_two_entities_share :: proc(t:^testing.T) {
    f:Paint_Test
    if !paint_test_open(t,&f,"paint-levels") {return}
    defer paint_test_close(&f)
    CELLS :: 24
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for z in 0..=CELLS {for x in 0..=CELLS {
        p:=[3]f32{f32(x)/CELLS-0.5,0.05*math.sin(f32(x)*0.7)*math.cos(f32(z)*0.5),f32(z)/CELLS-0.5}
        append(&vertices,asset.Vertex{position=p,normal=mm.normal_pack({0,1,0}),uv={p.x,p.z},color=0xffffffff,tangent=mm.tangent_pack({1,0,0},1)})
    }}
    for z in 0..<u32(CELLS) {for x in 0..<u32(CELLS) {
        a:=z*(CELLS+1)+x
        append(&indices,a,a+CELLS+1,a+1,a+1,a+CELLS+1,a+CELLS+2)
    }}
    g:asset.Mesh_Geometry
    if !testing.expect(t,asset.mesh_build_dag({vertices=vertices[:]},indices[:],&g,context.temp_allocator) && len(g.levels)>1) {return}
    mesh:=base.Asset_Id{0x6c657665,0x6c73}
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/levels.mesh",f.root),&f.assets.types,{id=mesh,geometry=g}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    w:=&f.world
    shown:=erender.Mesh_Renderer{mesh=mesh}
    other:=core.create(&w.entities)
    core.add(&w.ids,other,core.Id{value=8})
    core.add(&w.meshes,f.cube,shown)
    core.add(&w.meshes,other,shown)
    core.world_settle(f.ref)

    params:=Stroke_Params{radius=10,strength=1,color={0,1,0}};copy(params.entity[:],"0000000000000007")
    result:Stroke_Result
    method:=api.Method{params_id=Stroke_Params,result_id=Stroke_Result}
    call:=api.Call{method=&method,params=&params,result=&result,raw=`{"entity":"0000000000000007","points":[[0,0,0]]}`,allocator=context.temp_allocator}
    api_stroke(&f.session,&call)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    level0:=0
    for c in g.clusters[:g.levels[0].cluster_count] {level0+=int(asset.cluster_vertex_count(c))}
    testing.expect_value(t,result.vertices,u32(len(g.vertices)))
    testing.expectf(t,int(result.changed)==len(g.vertices) && level0<len(g.vertices),"every vertex of every level: %d of %d, %d in level 0",result.changed,len(g.vertices),level0)
    testing.expect_value(t,core.at(&w.meshes,core.row_of(&w.meshes,f.cube)),shown)
    testing.expect_value(t,core.at(&w.meshes,core.row_of(&w.meshes,other)),shown)
    testing.expect(t,core.has(&w.painted,f.cube) && !core.has(&w.painted,other))
}

// A flat grid of cells with its vertices and triangles in order, or backwards.
@(private)
paint_grid_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,backwards:bool) -> bool {
    CELLS :: 4
    LAST :: (CELLS+1)*(CELLS+1)-1
    slot :: proc(v:u32,backwards:bool) -> u32 {return LAST-v if backwards else v}
    vertices:=make([]asset.Vertex,LAST+1,context.temp_allocator)
    for z in 0..=u32(CELLS) {for x in 0..=u32(CELLS) {
        p:=[3]f32{f32(x)/CELLS-0.5,0,f32(z)/CELLS-0.5}
        vertices[slot(z*(CELLS+1)+x,backwards)]=asset.Vertex{position=p,normal=mm.normal_pack({0,1,0}),uv={p.x,p.z},color=0xffffffff,tangent=mm.tangent_pack({1,0,0},1)}
    }}
    triangles:=make([dynamic][3]u32,context.temp_allocator)
    for z in 0..<u32(CELLS) {for x in 0..<u32(CELLS) {
        a:=z*(CELLS+1)+x
        append(&triangles,[3]u32{a,a+CELLS+1,a+1},[3]u32{a+1,a+CELLS+1,a+CELLS+2})
    }}
    indices:=make([dynamic]u32,context.temp_allocator)
    for k in 0..<len(triangles) {
        corners:=triangles[len(triangles)-1-k].yzx if backwards else triangles[k]
        for v in corners {append(&indices,slot(v,backwards))}
    }
    g:asset.Mesh_Geometry
    return asset.mesh_build_dag({vertices=vertices},indices[:],&g,context.temp_allocator) && asset.mesh_save(path,types,{id=id,geometry=g})==.None
}

// A painted mesh imported again with its vertices in another order keeps its
// colors on the same places: the editor fits the .paint to it and writes it.
@(test)
paint_follows_its_mesh_imported_again_with_its_vertices_in_another_order :: proc(t:^testing.T) {
    f:Paint_Test
    if !paint_test_open(t,&f,"paint-fit") {return}
    defer paint_test_close(&f)
    w,a:=&f.world,&f.assets
    mesh:=base.Asset_Id{0x67726964,0x6669}
    first:=fmt.tprintf("%s/grid.mesh",f.root)
    if !testing.expect(t,paint_grid_save(first,&a.types,mesh,false) && host.assets_scan(a)) {return}
    shown:=erender.Mesh_Renderer{mesh=mesh}
    core.add(&w.meshes,f.cube,shown)
    core.world_settle(f.ref)
    params:=Stroke_Params{radius=0.4,strength=1,color={0,1,0}};copy(params.entity[:],"0000000000000007")
    params.points[0]={-0.5,0,-0.5}
    result:Stroke_Result
    method:=api.Method{params_id=Stroke_Params,result_id=Stroke_Result}
    call:=api.Call{method=&method,params=&params,result=&result,raw=`{"entity":"0000000000000007","points":[[-0.5,0,-0.5]]}`,allocator=context.temp_allocator}
    api_stroke(&f.session,&call)
    if !testing.expectf(t,!call.failed,"%s",call.error.message) {return}
    before:Canvas
    if !testing.expect(t,canvas_load(&before,a,shown,result.colors)) {return}
    defer canvas_destroy(&before)

    if !testing.expect(t,os.remove(first)==nil && paint_grid_save(fmt.tprintf("%s/grid_again.mesh",f.root),&a.types,mesh,true) && host.assets_scan(a)) {return}
    fit:Paint_Fit;defer paint_fit_free(&fit)
    tool:Paint_Tool
    paint_fit(&f.session,&fit,&tool,core.read(&w.meshes),core.read(&w.painted),a)
    record,_:=asset.registry_find(&a.registry,mesh)
    file:asset.Asset
    if !testing.expect_value(t,host.assets_file(a,result.colors,paint.PAINT_KIND,&file),asset.Error.None) {return}
    defer asset.asset_close(&file)
    after,error:=paint.paint_view(&file,&a.types)
    if !testing.expect_value(t,error,asset.Error.None) || !testing.expect_value(t,len(after.colors),len(before.colors)) {return}
    testing.expect_value(t,after.mesh,record.content_hash)
    moved,painted:=0,0
    for p,at in after.positions {
        if p!=before.positions[at] {moved+=1}
        if after.colors[at]!=0xffffffff {painted+=1}
        for q,was in before.positions {
            if q!=p {continue}
            testing.expectf(t,after.colors[at]==before.colors[was],"the vertex at %v keeps its color",p)
            break
        }
    }
    testing.expectf(t,moved>0 && painted>0 && painted<len(after.colors),"%d vertices moved and %d of %d are painted",moved,painted,len(after.colors))
    testing.expect(t,editor.files_flush(&f.session,true))
    written:asset.Asset
    if !testing.expect_value(t,host.assets_file(a,result.colors,paint.PAINT_KIND,&written),asset.Error.None) {return}
    defer asset.asset_close(&written)
    fitted,_:=paint.paint_view(&written,&a.types)
    testing.expect_value(t,fitted.mesh,record.content_hash)
}
