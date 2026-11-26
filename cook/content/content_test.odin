package content

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/records"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:store"

// A writer with the types alone, as a test makes one: no project.
@(private="file")
writer_test :: proc(w:^Writer,name:string) {
    w.name,w.started=name,time.now()
    asset.types_init(&w.types)
}

@(test)
a_mesh_buffer_is_written_as_a_mesh_with_the_colors_of_its_parts :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"content-mesh")
    w:Writer
    writer_test(&w,"content_test")
    defer asset.types_destroy(&w.types)
    m:geom.Mesh_Buffer
    geom.mesh_buffer_init(&m,context.temp_allocator)
    trunk:=[2]geom.Vec3{{0,0,0},{0,2,0}}
    geom.tube_build(&m,trunk[:],{0.2,0.1})
    geom.mesh_buffer_paint(&m,{0.4,0.2,0.1,1})
    geom.fan_build(&m,{0,2,0},5,{length=1,width=0.3,rise=0.2,droop=0.5,belly=0.3})
    path:=fmt.tprintf("%s/woods/palm.mesh",folder)
    made:=mesh(&w,path,&m)
    testing.expect(t,!w.failed && w.written==1)
    testing.expect_value(t,made,asset.content_id("content_test","mesh",path))
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if !testing.expect_value(t,error,nil) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,data),asset.Error.None) {return}
    defer asset.asset_close(&file)
    view,viewed:=asset.mesh_view(&file,&w.types)
    if !testing.expect_value(t,viewed,asset.Error.None) {return}
    testing.expect(t,.Has_Colors in view.flags,"the paint of a part keeps the colors of its vertices")
    testing.expect(t,view.info.triangle_count>=cast(u32)(len(m.indices)/3),"the mesh keeps its triangles")

    // The same mesh again leaves its file as it is.
    w.started=time.now()
    mesh(&w,path,&m)
    testing.expect(t,!w.failed && w.written==1 && w.unchanged==1,"a file that holds its bytes is not written")

    // What is not a mesh says so and writes nothing.
    empty:geom.Mesh_Buffer
    geom.mesh_buffer_init(&empty,context.temp_allocator)
    other:=fmt.tprintf("%s/woods/none.mesh",folder)
    mesh(&w,other,&empty)
    testing.expect(t,w.failed && !os.exists(other))
}

// What the writer writes with the codecs of a project is the file the cook's
// repack writes of it, the same chunks compressed the same way: a mesh and a
// table of game data.
@(test)
what_the_writer_writes_is_what_the_repack_of_the_cook_writes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"content-repack")
    w:Writer
    writer_test(&w,"content_test")
    defer asset.types_destroy(&w.types)
    w.types.codecs=.Compressed
    m:geom.Mesh_Buffer
    geom.mesh_buffer_init(&m)
    // Enough clusters that the tables of the mesh shrink when compressed.
    geom.icosphere_build(&m,1,5)
    path:=fmt.tprintf("%s/ball.mesh",folder)
    mesh(&w,path,&m)
    if !testing.expect(t,!w.failed) {return}
    e:records.Edit
    if !testing.expect_value(t,records.create({7,7},fmt.tprintf("%s/items.records",folder),"","Item",&e),"") {return}
    defer records.destroy(&e)
    column:asset.Records_Column
    base.text_set(column.name[:],"stack")
    column.kind=.Int
    if !testing.expect_value(t,records.column_add(&e,nil,column),"") {return}
    for name in ([]string{"sword","shield","potion"}) {
        row:=make([]u8,records.row_size(&e))
        copy(row,e.defaults)
        testing.expect(t,records.row_put(&e,records.id_of_name(name,e.ids[:]),name,row))
    }
    table,problem:=records.file_bytes(&e,&w.types)
    if !testing.expect_value(t,problem,"") {return}
    saved,_:=os.read_entire_file(path,context.temp_allocator)
    for bytes,what in ([2][]u8{saved,table}) {
        repacked,error:=asset.document_repack(bytes,.Fast,.Compressed)
        testing.expect_value(t,error,asset.Error.None)
        testing.expectf(t,string(bytes)==string(repacked),"%s: the writer and a repack write other bytes (%d and %d)",what==0?"mesh":"records",len(bytes),len(repacked))
    }
}

// A transform goes to the document of a scene as the keys of its entity, its
// rotation whole.
@(test)
a_transform_is_written_as_the_keys_of_its_entity :: proc(t:^testing.T) {
    testing.expect_value(t,transform(core.Transform{position={1,2.5,-3},rotation=quaternion(w=0.5,x=0.5,y=-0.5,z=0.5),scale={1,1,2}}),`"position":[1,2.5,-3],"rotation":[0.5,-0.5,0.5,0.5],"scale":[1,1,2]`)
}

// Images of one name in two folders, imported by a tool in one run: each is
// pinned in packages.mirai under its folder, as mirai import pins it, and the
// registry of the tool lists both built textures.
@(test)
a_tool_imports_images_of_one_name_in_two_folders_as_two_pins :: proc(t:^testing.T) {
    root:=base.test_folder(t,"content-import")
    if root=="" {return}
    w:Writer
    writer_test(&w,"content_test")
    defer asset.types_destroy(&w.types)
    w.root,w.assets_root=root,fmt.tprintf("%s/assets",root)
    os.make_directory_all(w.assets_root)
    asset.registry_init(&w.registry,w.assets_root)
    defer asset.registry_destroy(&w.registry)
    opened,store_error:=store.open(fmt.tprintf("%s/store",root))
    if !testing.expect_value(t,store_error,store.Error.None) {return}
    w.store,w.stored=opened,true
    defer store.close(&w.store)
    data,_:=os.read_entire_file(#directory+"/../../demo/assets/surfaces/bricks/bricks_color.png",context.temp_allocator)
    if !testing.expect(t,len(data)>0) {return}
    for folder in ([]string{"fx_a","fx_b"}) {
        path:=fmt.tprintf("%s/%s/spark.png",w.assets_root,folder)
        testing.expect(t,source_write(&w,path,data))
        report,imported:=import_source(&w,path)
        if !testing.expectf(t,imported,"%s imports",path) {return}
        importer.report_destroy(&report)
    }
    testing.expect(t,!w.failed)
    list,_,list_error:=asset.packages_load(root,context.temp_allocator)
    if !testing.expectf(t,list_error==.None && len(list.packages)==2,"two pins: %v %v",list_error,list.packages) {return}
    testing.expect(t,list.packages[0].id!=list.packages[1].id && list.packages[0].folder=="fx_a" && list.packages[1].folder=="fx_b")
    for p in list.packages {
        text:[base.ASSET_ID_TEXT]u8
        manifest:=fmt.tprintf("%s/packages/%s.mirai",root,base.asset_id_format(p.id,text[:]))
        testing.expectf(t,os.exists(manifest),"%s is written",manifest)
    }
    resolved,resolve_error:=asset.packages_resolve(&w.store,root,&list,context.temp_allocator)
    if !testing.expect_value(t,resolve_error,asset.Error.None) {return}
    built:=0
    for listed in resolved.listed {
        if (listed.path=="fx_a/spark.tex" || listed.path=="fx_b/spark.tex") && listed.state==.Built {built+=1}
    }
    testing.expectf(t,built==2,"both are built: %v",resolved.listed)
    for path in ([]string{"fx_a/spark.tex","fx_b/spark.tex"}) {
        _,listed:=asset.registry_find_path(&w.registry,path)
        testing.expectf(t,listed,"the registry of the tool lists %s",path)
    }
}
