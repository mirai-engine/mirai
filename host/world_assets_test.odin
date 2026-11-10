package host

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

@(private) Marks_Model :: struct {mesh:base.Asset_Id}
@(private) Marks_Held :: struct {list:[dynamic]base.Asset_Id}
@(private) Marks_World :: struct {using world:core.Test_World,models:core.Table(Marks_Model),held:Marks_Held}

// What a World names stays loaded and what it stops naming unloads at the
// next mark: a component, a dynamic array of a storage; once the World goes,
// all of it.
@(test)
what_no_world_names_unloads_at_the_next_mark :: proc(t:^testing.T) {
    root:=base.test_folder(t,"marks")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{{position={0,0,0},normal=mm.normal_pack({0,1,0})},{position={1,0,0},normal=mm.normal_pack({0,1,0})},{position={0,0,1},normal=mm.normal_pack({0,1,0})}}
    meshes:=[3]base.Asset_Id{{0x6d61726b,1},{0x6d61726b,2},{0x6d61726b,3}}
    for id,i in meshes {
        testing.expect_value(t,mesh_save_test(fmt.tprintf("%s/m%d.mesh",root,i),&types,id,vertices[:],{0,2,1}),asset.Error.None)
    }
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=8})) {return}
    defer assets_destroy(&assets)
    testing.expect(t,assets_scan(&assets))
    for id in meshes {_=assets_mesh(&assets,id)}
    for id in meshes {testing.expect(t,assets_loaded(&assets,id))}

    info,described:=core.test_info(t,Marks_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    app:=App{info=&info,assets=&assets,allocator=context.allocator}
    app.worlds=make([dynamic]World_Slot)
    defer delete(app.worlds)
    defer assets_marks_free(&app.asset_marks)
    w:=cast(^Marks_World)app_world_create(&app)
    if !testing.expect(t,w!=nil) {return}
    model:=core.create(&w.entities)
    core.add(&w.models,model,Marks_Model{meshes[0]})
    core.table_settle(&w.models,&w.entities)
    append(&w.held.list,meshes[1])

    app.seconds=1
    testing.expect_value(t,app_assets_mark(&app),1)
    testing.expect(t,assets_loaded(&assets,meshes[0]) && assets_loaded(&assets,meshes[1]) && !assets_loaded(&assets,meshes[2]))
    // Too soon, and nothing changed: it does not mark again.
    app.seconds+=0.1
    testing.expect_value(t,app_assets_mark(&app),0)
    core.destroy(&w.entities,model)
    core.table_settle(&w.models,&w.entities)
    app.seconds+=ASSETS_MARK_SECONDS
    testing.expect_value(t,app_assets_mark(&app),1)
    testing.expect(t,!assets_loaded(&assets,meshes[0]) && assets_loaded(&assets,meshes[1]))
    app_world_free(&app,w)
    app.seconds+=ASSETS_MARK_SECONDS
    testing.expect_value(t,app_assets_mark(&app),1)
    testing.expect(t,!assets_loaded(&assets,meshes[1]))
}
