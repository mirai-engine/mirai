package asset

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/geom"
import "mirai:std/base"

@(test)
a_mesh_buffer_is_written_as_a_mesh_with_the_colors_of_its_parts :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"content-mesh")
    c:Content
    content_init(&c,"content_test")
    defer content_destroy(&c)
    m:geom.Mesh_Buffer
    geom.mesh_buffer_init(&m,context.temp_allocator)
    trunk:=[2]geom.Vec3{{0,0,0},{0,2,0}}
    geom.tube_build(&m,trunk[:],{0.2,0.1})
    geom.mesh_buffer_paint(&m,{0.4,0.2,0.1,1})
    geom.fan_build(&m,{0,2,0},5,{length=1,width=0.3,rise=0.2,droop=0.5,belly=0.3})
    path:=fmt.tprintf("%s/woods/palm.mesh",folder)
    id:=content_mesh(&c,path,&m)
    testing.expect(t,!c.failed)
    testing.expect_value(t,id,content_id("content_test","mesh",path))
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if !testing.expect_value(t,error,nil) {return}
    file:Asset
    if !testing.expect_value(t,asset_open(&file,data),Error.None) {return}
    defer asset_close(&file)
    view,viewed:=mesh_view(&file,&c.types)
    if !testing.expect_value(t,viewed,Error.None) {return}
    testing.expect(t,.Has_Colors in view.flags,"the paint of a part keeps the colors of its vertices")
    testing.expect(t,view.info.triangle_count>=cast(u32)(len(m.indices)/3),"the mesh keeps its triangles")

    // What is not a mesh says so and writes nothing.
    empty:geom.Mesh_Buffer
    geom.mesh_buffer_init(&empty,context.temp_allocator)
    other:=fmt.tprintf("%s/woods/none.mesh",folder)
    content_mesh(&c,other,&empty)
    testing.expect(t,c.failed && !os.exists(other))
}
