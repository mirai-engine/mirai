package terrain

import "core:math"
import "mirai:std/geom"

// The surface of a Volume as a Mesh source: the static form of what was dug,
// which keeps no field. Its triangles are those of level 0 of its chunks,
// welded; its layers, and over each sample of the Mesh the weights of the
// Volume at the top of the surface of that column. Admits dst=src: dst changes only once the Mesh is
// made. False for a Volume without surface or past what a Mesh holds.
source_convert_volume :: proc(dst,src:^Source,allocator:=context.allocator) -> bool {
    if src.kind!=.Volume || !source_valid(src.info) || !source_samples_held(src) {return false}
    high:=[3]int{int(src.samples.x)-1,int(src.samples.y)-1,int(src.samples.z)-1}
    samples:=make([dynamic]f32,allocator)
    defer delete(samples)
    grid:geom.Scalar_Grid
    surface,ok:=chunk_volume_window(src,{},high,0,&samples,&grid)
    if !ok || !surface {return false}
    extracted,welded:geom.Mesh_Buffer
    geom.mesh_buffer_init(&extracted,allocator);defer geom.mesh_buffer_destroy(&extracted)
    geom.mesh_buffer_init(&welded,allocator);defer geom.mesh_buffer_destroy(&welded)
    if geom.isosurface(grid,{},high,&extracted)!=.None {return false}
    if !geom.mesh_weld(geom.mesh_buffer_view(&extracted),0,&welded) {return false}
    if len(welded.indices)==0 || len(welded.indices)/3>MESH_TRIANGLES_MAX {return false}
    revision:=src.revision
    layers:=src.info
    origin:=source_origin(src)
    cell:=src.cell
    mesh:Source
    defer source_destroy(&mesh)
    if !source_from_mesh(&mesh,geom.mesh_buffer_view(&welded),cell,int(src.chunk_cells),nil,allocator) {return false}
    mesh.revision=revision
    mesh.layer_count,mesh.layers=layers.layer_count,layers.layers
    for z in 0..<int(mesh.samples.z) {for x in 0..<int(mesh.samples.x) {
        at:=mesh.mesh_origin+[3]f32{f32(x),0,f32(z)}*cell
        column:=clamp(int(math.round((at.x-origin.x)/cell)),0,int(src.samples.x)-1)
        row:=clamp(int(math.round((at.z-origin.z)/cell)),0,int(src.samples.z)-1)
        at.y=volume_column_top(src,column,row)
        if !grid_put(&mesh.weights,{x,0,z},weights_quantize(source_weights_at(src,at),int(layers.layer_count)),allocator) {return false}
    }}
    source_destroy(dst)
    dst^=mesh
    mesh={}
    return true
}
