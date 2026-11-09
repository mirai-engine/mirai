package host

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

@(private) Marks_Model :: struct {mesh:base.Asset_Id}
@(private) Marks_Held :: struct {list:[dynamic]base.Asset_Id}
@(private) Marks_World :: struct {entities:core.Entities,models:core.Table(Marks_Model),held:Marks_Held}

@(private)
marks_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Marks_World)data
    core.table_init(&w.models,"Marks_Model",allocator)
    w.held.list=make([dynamic]base.Asset_Id,allocator)
    return core.entities_init(&w.entities,allocator)
}

@(private)
marks_destroy :: proc(data:rawptr) {
    w:=cast(^Marks_World)data
    core.table_destroy(&w.models)
    delete(w.held.list)
    core.entities_destroy(&w.entities)
}

// What a World names stays loaded and what it stops naming unloads at the
// next mark: a component, a dynamic array of a storage; once the World goes,
// all of it.
@(test)
what_no_world_names_unloads_at_the_next_mark :: proc(t:^testing.T) {
    root:=fmt.tprintf("%s/mirai-marks-%d",os.get_env("TEMP",context.temp_allocator),os.get_pid())
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove_all(root)
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

    tables:=[1]core.Table_Info{{name="Marks_Model",type=Marks_Model,info=type_info_of(Marks_Model),offset=offset_of(Marks_World,models)}}
    storages:=[1]core.Storage_Info{{name="Marks_Held",type=Marks_Held,info=type_info_of(Marks_Held),offset=offset_of(Marks_World,held)}}
    info:=core.World_Info{entities=offset_of(Marks_World,entities),tables=tables[:],storages=storages[:]}
    info.sizes[.World],info.aligns[.World]=size_of(Marks_World),align_of(Marks_World)
    info.init[.World],info.destroy[.World]=marks_init,marks_destroy
    core.world_info_index(&info)
    defer {core.world_schema_destroy(info.schema);delete(info.tables_by_type);delete(info.storages_by_type)}
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
