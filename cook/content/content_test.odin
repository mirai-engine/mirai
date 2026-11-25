package content

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:cook/records"
import "mirai:std/base"
import "mirai:std/geom"

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
