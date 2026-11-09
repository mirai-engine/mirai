package asset

import "mirai:std/base"
import "core:math/linalg"
import "mirai:std/geom"
import mm "mirai:std/math"

FRACTURE_VERSION :: 4
FRACTURE_OLDEST :: FRACTURE_VERSION
FRACTURE_CLUSTER_POINTS :: 64 // most points kept of the hull of a cluster

Fracture_Info :: struct {source_mesh:base.Asset_Id}

Fracture_Piece :: struct {
    first_vertex,vertex_count,first_index,index_count:u32,
    cluster:i32, // -1: no hierarchy; otherwise a row of clusters
    anchor:bool,
}

Fracture_Connection :: struct {
    a,b:u32,
    area:f32, // m2
    strength:f32, // N s/m2; zero takes the component's strength
}

Fracture_Cluster :: struct {
    parent:i32, // -1: root; a parent precedes its children
    strength:f32, // N s needed to release the next level
}

// The points of cluster_points whose convex hull a cluster collides as while it is whole.
Fracture_Cluster_Hull :: struct {first_point,point_count:u32}

Fracture_Desc :: struct {
    id:base.Asset_Id,
    source_mesh:base.Asset_Id,
    vertices:[]Vertex,
    indices:[]u32, // local to the piece
    pieces:[]Fracture_Piece,
    connections:[]Fracture_Connection,
    clusters:[]Fracture_Cluster,
    compression:Compression,
}

Fracture_View :: struct {
    info:^Fracture_Info,
    vertices:[]Vertex,
    indices:[]u32,
    pieces:[]Fracture_Piece,
    connections:[]Fracture_Connection,
    clusters:[]Fracture_Cluster,
    cluster_hulls:[]Fracture_Cluster_Hull, // one per cluster, cooked from its pieces
    cluster_points:[][3]f32,
}

fracture_check :: proc(view:Fracture_View) -> bool {
    if !fracture_source_check(view) || len(view.cluster_hulls)!=len(view.clusters) {return false}
    points:u64
    for hull in view.cluster_hulls {
        if u64(hull.first_point)!=points || hull.point_count<4 {return false}
        points+=u64(hull.point_count)
    }
    if points!=u64(len(view.cluster_points)) {return false}
    for point in view.cluster_points {if !finite(point.x,point.y,point.z) {return false}}
    return true
}

// What the author gives: pieces, connections and clusters, without the hulls the cook adds.
fracture_source_check :: proc(view:Fracture_View) -> bool {
    if view.info==nil || len(view.pieces)==0 {return false}
    for cluster,at in view.clusters {
        if cluster.parent < -1 || int(cluster.parent)>=at || !(cluster.strength>0) || !finite(cluster.strength) {return false}
    }
    vertices,indices:u64
    for piece in view.pieces {
        if u64(piece.first_vertex)!=vertices || u64(piece.first_index)!=indices || piece.vertex_count<4 || piece.index_count<12 || piece.index_count%3!=0 {return false}
        vertices+=u64(piece.vertex_count)
        indices+=u64(piece.index_count)
        if vertices>u64(len(view.vertices)) || indices>u64(len(view.indices)) || piece.cluster < -1 || int(piece.cluster)>=len(view.clusters) {return false}
        points,error:=make([][3]f32,int(piece.vertex_count))
        if error!=nil {return false}
        valid:=true
        for vertex,at in view.vertices[piece.first_vertex:][:piece.vertex_count] {
            points[at]=vertex.position
            valid=valid && finite(vertex.position.x,vertex.position.y,vertex.position.z,vertex.uv.x,vertex.uv.y,vertex.uv1.x,vertex.uv1.y) && vertex.material<MESH_MAX_SLOTS
        }
        local:=view.indices[piece.first_index:][:piece.index_count]
        for index in local {valid=valid && index<piece.vertex_count}
        if valid {valid=geom.mesh_is_closed(points,local)}
        delete(points)
        if !valid {return false}
    }
    if vertices!=u64(len(view.vertices)) || indices!=u64(len(view.indices)) {return false}
    for connection,at in view.connections {
        if connection.a>=connection.b || int(connection.b)>=len(view.pieces) || !(connection.area>0) || connection.strength<0 || !finite(connection.area,connection.strength) {return false}
        if at>0 {
            prior:=view.connections[at-1]
            if connection.a<prior.a || connection.a==prior.a && connection.b<=prior.b {return false}
        }
    }
    return true
}

fracture_geometry :: proc(view:Fracture_View,out:^geom.Fracture,scale:=[3]f32{1,1,1}) -> Error {
    if out==nil || !fracture_source_check(view) {return .Invalid}
    for axis in scale {if !(axis>0) || !finite(axis) {return .Invalid}}
    mesh:=&out.mesh
    if reserve(&mesh.positions,len(view.vertices))!=nil || reserve(&mesh.normals,len(view.vertices))!=nil ||
       reserve(&mesh.uvs,len(view.vertices))!=nil || reserve(&mesh.colors,len(view.vertices))!=nil ||
       reserve(&mesh.indices,len(view.indices))!=nil || reserve(&mesh.materials,len(view.indices)/3)!=nil ||
       reserve(&out.pieces,len(view.pieces))!=nil || reserve(&out.connections,len(view.connections))!=nil {return .Out_Of_Memory}
    geom.mesh_buffer_clear(mesh);clear(&out.pieces);clear(&out.connections)
    for vertex in view.vertices {
        append(&mesh.positions,vertex.position*scale)
        append(&mesh.normals,linalg.normalize0(mm.normal_unpack(vertex.normal)/scale))
        append(&mesh.uvs,vertex.uv);append(&mesh.colors,mm.rgba8_unpack(vertex.color))
    }
    append(&mesh.indices,..view.indices)
    for piece,at in view.pieces {
        positions:=mesh.positions[piece.first_vertex:][:piece.vertex_count]
        indices:=mesh.indices[piece.first_index:][:piece.index_count]
        mass:=geom.mesh_mass_properties(positions,indices)
        append(&out.pieces,geom.Fracture_Piece{site=u32(at),first_vertex=piece.first_vertex,vertex_count=piece.vertex_count,
            first_index=piece.first_index,index_count=piece.index_count,volume=abs(mass.volume),center=mass.center})
        for triangle in 0..<len(indices)/3 {append(&mesh.materials,view.vertices[piece.first_vertex+indices[triangle*3]].material)}
    }
    area_scale:=max(scale.x*scale.y,scale.x*scale.z,scale.y*scale.z)
    for connection in view.connections {append(&out.connections,geom.Fracture_Connection{connection.a,connection.b,connection.area*area_scale})}
    return .None
}

fracture_document :: proc(doc:^Document,types:^Types,desc:Fracture_Desc,allocator:=context.allocator) -> Error {
    info:=Fracture_Info{desc.source_mesh}
    view:=Fracture_View{info=&info,vertices=desc.vertices,indices=desc.indices,pieces=desc.pieces,connections=desc.connections,clusters=desc.clusters}
    if !fracture_source_check(view) {return .Invalid}
    hulls:=make([dynamic]Fracture_Cluster_Hull)
    points:=make([dynamic][3]f32)
    defer {delete(hulls);delete(points)}
    fracture_cluster_hulls(view,&hulls,&points) or_return
    view.cluster_hulls,view.cluster_points=hulls[:],points[:]
    if !fracture_check(view) {return .Invalid}
    document_init(doc,KIND_FRACTURE,desc.id,allocator)
    doc.kind_version=FRACTURE_VERSION
    error:=fracture_tables(doc,types,view,desc.compression)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
fracture_tables :: proc(doc:^Document,types:^Types,view:Fracture_View,compression:Compression) -> Error {
    document_put_row(doc,types,"fracture",view.info) or_return
    document_put(doc,types,"pieces",view.pieces) or_return
    document_put(doc,types,"connections",view.connections) or_return
    document_put(doc,types,"clusters",view.clusters) or_return
    document_put(doc,types,"cluster_hulls",view.cluster_hulls) or_return
    document_put(doc,types,"cluster_points",view.cluster_points) or_return
    document_put(doc,types,"vertices",view.vertices,{.Bulk},compression,MESH_BULK_ALIGNMENT) or_return
    document_put(doc,types,"indices",view.indices,{.Bulk},compression,MESH_BULK_ALIGNMENT) or_return
    return .None
}

fracture_save :: proc(path:string,types:^Types,desc:Fracture_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    fracture_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

fracture_view :: proc(a:^Asset,types:^Types) -> (view:Fracture_View,error:Error) {
    kind_check(a,KIND_FRACTURE,FRACTURE_OLDEST,FRACTURE_VERSION) or_return
    view.info=asset_row(a,types,"fracture",Fracture_Info) or_return
    view.pieces=asset_rows(a,types,"pieces","",Fracture_Piece) or_return
    view.connections=asset_rows(a,types,"connections","",Fracture_Connection) or_return
    view.clusters=asset_rows(a,types,"clusters","",Fracture_Cluster) or_return
    view.cluster_hulls=asset_rows(a,types,"cluster_hulls","",Fracture_Cluster_Hull) or_return
    view.cluster_points=asset_rows(a,types,"cluster_points","",[3]f32) or_return
    view.vertices=asset_rows(a,types,"vertices","",Vertex) or_return
    view.indices=asset_rows(a,types,"indices","",u32) or_return
    if !fracture_check(view) {return {},.Corrupt}
    return view,.None
}

// The hull of every cluster: the convex hull of the pieces under it, at most FRACTURE_CLUSTER_POINTS of
// its points. A cluster takes the full hulls of its children, which follow it, so each piece is read once.
@(private="file")
fracture_cluster_hulls :: proc(view:Fracture_View,hulls:^[dynamic]Fracture_Cluster_Hull,points:^[dynamic][3]f32) -> Error {
    gathered:=make([][dynamic][3]f32,len(view.clusters))
    defer {
        for &cluster in gathered {delete(cluster)}
        delete(gathered)
    }
    for piece in view.pieces {
        if piece.cluster<0 {continue}
        for vertex in view.vertices[piece.first_vertex:][:piece.vertex_count] {append(&gathered[piece.cluster],vertex.position)}
    }
    #reverse for cluster,at in view.clusters {
        full,error:=geom.hull_build(gathered[at][:])
        defer geom.hull_destroy(&full)
        if error!=.None || geom.hull_is_flat(full) {return .Invalid}
        clear(&gathered[at])
        append(&gathered[at],..full.vertices)
        if cluster.parent>=0 {append(&gathered[cluster.parent],..full.vertices)}
    }
    for cluster in gathered {
        hull,error:=geom.hull_build(cluster[:],{max_vertices=FRACTURE_CLUSTER_POINTS})
        defer geom.hull_destroy(&hull)
        if error!=.None || geom.hull_is_flat(hull) {return .Invalid}
        append(hulls,Fracture_Cluster_Hull{u32(len(points)),u32(len(hull.vertices))})
        append(points,..hull.vertices)
    }
    return .None
}
