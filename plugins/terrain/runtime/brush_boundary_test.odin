package terrain

import "core:testing"
import "mirai:std/geom"

@(test)
bounded_volume_brushes_preserve_air_margin_and_can_remove_and_restore_all_material :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Volume,{17,17,17},1,8));defer source_destroy(&source)
    n:=[3]int{int(source.samples.x),int(source.samples.y),int(source.samples.z)}
    before:=make([]f32,n.x*n.y*n.z);defer delete(before)
    for z in 0..<n.z {for y in 0..<n.y {for x in 0..<n.x {before[x+n.x*(y+n.y*z)]=source_value(&source,{x,y,z})}}}
    part:Chunk_Mesh;chunk_mesh_init(&part);defer chunk_mesh_destroy(&part)
    combined,welded:geom.Mesh_Buffer;geom.mesh_buffer_init(&combined);geom.mesh_buffer_init(&welded)
    defer geom.mesh_buffer_destroy(&combined);defer geom.mesh_buffer_destroy(&welded)
    for kind in ([5]Brush_Kind{.Add,.Carve,.Add,.Smooth,.Flatten}) {
        testing.expect(t,source_edit(&source,{kind=kind,center={},radius=30,amount=1}).changed)
        boundary_ok:=true
        for z in 0..<int(source.samples.z) {for y in 0..<int(source.samples.y) {for x in 0..<int(source.samples.x) {
            if x!=0 && y!=0 && z!=0 && x!=int(source.samples.x)-1 && y!=int(source.samples.y)-1 && z!=int(source.samples.z)-1 {continue}
            boundary_ok=boundary_ok && source_value(&source,{x,y,z})==before[x+n.x*(y+n.y*z)] && source_value(&source,{x,y,z})>0
        }}}
        testing.expect(t,boundary_ok,"the outer sample layer remains unchanged air under a brush larger than the whole source")
        geom.mesh_buffer_clear(&combined)
        chunks:=chunk_counts(&source)
        for i in 0..<chunks.x*chunks.y*chunks.z {
            testing.expect(t,chunk_build(&source,chunk_coord(&source,i),&part))
            chunk_in_terrain(&part)
            offset:=u32(len(combined.positions))
            append(&combined.positions,..part.geometry.positions[:])
            for index in part.geometry.indices {append(&combined.indices,index+offset)}
        }
        if kind==.Carve {
            testing.expect_value(t,len(combined.indices),0)
            for z in 0..<n.z {for y in 0..<n.y {for x in 0..<n.x {testing.expect(t,source_value(&source,{x,y,z})>0)}}}
        } else {
            testing.expect(t,len(combined.indices)>0,"adding bounded material keeps a visible closed surface")
            geom.mesh_weld(geom.mesh_buffer_view(&combined),0,&welded)
            testing.expect(t,geom.mesh_topology_is_closed(geom.mesh_topology(welded.positions[:],welded.indices[:],by_position=false)))
        }
    }
}
