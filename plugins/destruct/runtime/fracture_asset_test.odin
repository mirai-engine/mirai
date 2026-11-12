package destruct

import "mirai:asset"
import "core:math/linalg"
import "core:testing"
import "mirai:std/serial"
import "mirai:std/geom"
import mm "mirai:std/math"

@(private="file")
Test_Fracture :: struct {
    info:Fracture_Info,
    vertices:[8]asset.Vertex,
    indices:[24]u32,
    pieces:[2]Fracture_Piece,
    connections:[1]Fracture_Connection,
    clusters:[1]Fracture_Cluster,
}

@(private="file")
test_fracture :: proc(s:^Test_Fracture) -> Fracture_Desc {
    tetra:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    triangles:=[12]u32{0,2,1,0,1,3,0,3,2,1,2,3}
    for part in 0..<2 {
        for point,at in tetra {s.vertices[part*4+at]={position=point+[3]f32{f32(part)*1.1,0,0},color=0xffffffff}}
        copy(s.indices[part*12:][:12],triangles[:])
        s.pieces[part]={u32(part*4),4,u32(part*12),12,0,part==0}
    }
    s.info.source_mesh={42,3}
    s.connections[0]={0,1,0.1,30}
    s.clusters[0]={-1,100}
    return {id={42,2},source_mesh=s.info.source_mesh,vertices=s.vertices[:],indices=s.indices[:],pieces=s.pieces[:],connections=s.connections[:],clusters=s.clusters[:],compression=.Stream}
}

@(test)
fracture_preserves_authored_geometry_proximity_graph_and_clusters :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    storage:Test_Fracture
    desc:=test_fracture(&storage)
    doc:asset.Document
    if !testing.expect_value(t,fracture_document(&doc,&types,desc),asset.Error.None) {return}
    defer asset.document_destroy(&doc)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None)
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&a,serial.writer_bytes(&writer)),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,error:=fracture_view(&a,&types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect_value(t,view.info.source_mesh,desc.source_mesh)
    testing.expect_value(t,view.vertices[7],desc.vertices[7])
    testing.expect_value(t,view.pieces[0].anchor,true)
    testing.expect_value(t,view.connections[0].strength,f32(30))
    testing.expect_value(t,view.clusters[0].strength,f32(100))
    testing.expect_value(t,a.blob.header.kind,FRACTURE_KIND)
    // The cook gives the cluster the hull of both pieces: the corners of the two tetrahedra it spans.
    testing.expect_value(t,len(view.cluster_hulls),1)
    testing.expect_value(t,view.cluster_hulls[0],Fracture_Cluster_Hull{0,u32(len(view.cluster_points))})
    lo,hi:=view.cluster_points[0],view.cluster_points[0]
    for point in view.cluster_points {lo,hi=linalg.min(lo,point),linalg.max(hi,point)}
    testing.expect(t,lo==[3]f32{0,0,0} && abs(hi.x-2.1)<1e-5 && hi.y==1 && hi.z==1)
    testing.expect(t,len(view.cluster_points)>=5 && len(view.cluster_points)<=8)
}

@(test)
fracture_refuses_cluster_hulls_out_of_range_short_or_not_finite :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    storage:Test_Fracture
    desc:=test_fracture(&storage)
    points:=[5][3]f32{{0,0,0},{2.1,0,0},{0,1,0},{0,0,1},{2.1,1,1}}
    hulls:=[1]Fracture_Cluster_Hull{{0,5}}
    view:=Fracture_View{&storage.info,desc.vertices,desc.indices,desc.pieces,desc.connections,desc.clusters,hulls[:],points[:]}
    testing.expect(t,fracture_check(view))
    hulls[0]={1,4}
    testing.expect(t,!fracture_check(view))
    hulls[0]={0,4}
    testing.expect(t,!fracture_check(view),"every point belongs to a cluster")
    view.cluster_points=points[:4]
    testing.expect(t,fracture_check(view))
    hulls[0]={0,3}
    view.cluster_points=points[:3]
    testing.expect(t,!fracture_check(view),"a hull has four points at least")
    hulls[0]={0,5}
    view.cluster_points=points[:]
    points[4].y=transmute(f32)u32(0x7fc00000)
    testing.expect(t,!fracture_check(view))
    view.cluster_hulls=nil
    testing.expect(t,!fracture_check(view))
}

@(test)
fracture_cook_refuses_a_cluster_without_pieces :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    storage:Test_Fracture
    desc:=test_fracture(&storage)
    clusters:=[2]Fracture_Cluster{{-1,100},{0,50}}
    desc.clusters=clusters[:]
    doc:asset.Document
    testing.expect_value(t,fracture_document(&doc,&types,desc),asset.Error.Invalid)
}

@(test)
fracture_refuses_bad_piece_ranges_indices_cluster_cycles_and_connections :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    storage:Test_Fracture
    desc:=test_fracture(&storage)
    view:=Fracture_View{info=&storage.info,vertices=desc.vertices,indices=desc.indices,pieces=desc.pieces,connections=desc.connections,clusters=desc.clusters}
    testing.expect(t,fracture_source_check(view))
    testing.expect(t,!fracture_check(view),"a cluster needs its cooked hull")
    storage.pieces[1].first_vertex=max(u32)
    testing.expect(t,!fracture_source_check(view))
    storage.pieces[1].first_vertex=4
    storage.indices[23]=4
    testing.expect(t,!fracture_source_check(view))
    storage.indices[23]=3
    storage.clusters[0].parent=0
    testing.expect(t,!fracture_source_check(view))
    storage.clusters[0].parent=-1
    storage.connections[0].b=2
    testing.expect(t,!fracture_source_check(view))
    storage.connections[0].b=1
    storage.vertices[0].position.x=transmute(f32)u32(0x7fc00000)
    testing.expect(t,!fracture_source_check(view))
}

// A file cut anywhere does not open; one with damaged bytes opens or not,
// and its view either holds together or is refused.
@(test)
fracture_reader_refuses_every_truncated_prefix_and_survives_damaged_bytes :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    storage:Test_Fracture
    doc:asset.Document
    if !testing.expect_value(t,fracture_document(&doc,&types,test_fracture(&storage)),asset.Error.None) {return}
    defer asset.document_destroy(&doc)
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None)
    data:=serial.writer_bytes(&writer)
    for length in 0..<len(data) {
        a:asset.Asset
        testing.expect(t,asset.asset_open(&a,data[:length])!=.None)
        asset.asset_close(&a)
    }
    damaged:=make([]u8,len(data),context.temp_allocator)
    state:=u64(0x9e3779b97f4a7c15)
    for round in 0..<400 {
        copy(damaged,data)
        state=state*6364136223846793005+1442695040888963407
        damaged[int((state>>33)%u64(len(damaged)))]=u8(state>>24)
        a:asset.Asset
        if asset.asset_open(&a,damaged)!=.None {continue}
        if view,error:=fracture_view(&a,&types);error==.None {testing.expectf(t,fracture_check(view),"round %d",round)}
        asset.asset_close(&a)
    }
}

@(test)
fracture_builder_preserves_attributes_and_cooks_exact_gap_proximity :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    for _ in 0..<len(cube.indices)/3 {append(&cube.materials,1)}
    for _ in cube.positions {append(&cube.colors,{.2,.5,.8,1})}
    b:Fracture_Builder;fracture_builder_init(&b);defer fracture_builder_destroy(&b)
    root,error:=fracture_cluster_add(&b,-1,150)
    testing.expect_value(t,error,asset.Error.None)
    _,error=fracture_piece_add(&b,geom.mesh_buffer_view(&cube),cluster=root,anchor=true)
    testing.expect_value(t,error,asset.Error.None)
    _,error=fracture_piece_add(&b,geom.mesh_buffer_view(&cube),{{1.06,0,0},1,{1,1,1}},cluster=root)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,fracture_connect_proximity(&b,.04,.5,12),asset.Error.None)
    testing.expect_value(t,len(b.connections),0)
    testing.expect_value(t,fracture_connect_proximity(&b,.07,.5,12),asset.Error.None)
    testing.expect_value(t,len(b.connections),1)
    testing.expect_value(t,b.connections[0],Fracture_Connection{0,1,.5,12})
    info:=Fracture_Info{}
    view:=Fracture_View{info=&info,vertices=b.vertices[:],indices=b.indices[:],pieces=b.pieces[:],connections=b.connections[:],clusters=b.clusters[:]}
    f:geom.Fracture;geom.fracture_init(&f);defer geom.fracture_destroy(&f)
    testing.expect_value(t,fracture_geometry(view,&f,{2,1,.5}),asset.Error.None)
    testing.expect_value(t,f.mesh.positions[36],b.vertices[36].position*[3]f32{2,1,.5})
    testing.expect_value(t,f.mesh.materials[0],u32(1))
    testing.expect(t,abs(f.mesh.colors[0].g-.5)<.005)
    testing.expect_value(t,f.connections[0].area,f32(1))
    testing.expect_value(t,fracture_connect_proximity(&b,-1,.5),asset.Error.Invalid)
    testing.expect_value(t,fracture_geometry(view,&f,{-1,1,1}),asset.Error.Invalid)
}
