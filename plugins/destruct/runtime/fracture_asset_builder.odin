package destruct

import "mirai:asset"
import "core:math/linalg"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

Fracture_Builder :: struct {
    vertices:[dynamic]asset.Vertex,
    indices:[dynamic]u32,
    pieces:[dynamic]Fracture_Piece,
    connections:[dynamic]Fracture_Connection,
    clusters:[dynamic]Fracture_Cluster,
}

fracture_builder_init :: proc(b:^Fracture_Builder,allocator:=context.allocator) {
    b.vertices=make([dynamic]asset.Vertex,allocator);b.indices=make([dynamic]u32,allocator)
    b.pieces=make([dynamic]Fracture_Piece,allocator);b.connections=make([dynamic]Fracture_Connection,allocator)
    b.clusters=make([dynamic]Fracture_Cluster,allocator)
}

fracture_builder_destroy :: proc(b:^Fracture_Builder) {
    delete(b.vertices);delete(b.indices);delete(b.pieces);delete(b.connections);delete(b.clusters)
    b^={}
}

fracture_piece_add :: proc(b:^Fracture_Builder,mesh:geom.Mesh,pose:=mm.TRANSFORM_IDENTITY,cluster:i32=-1,anchor:=false) -> (piece:u32,error:asset.Error) {
    if !geom.mesh_is_valid(mesh) || !geom.mesh_is_closed(mesh.positions,mesh.indices) || cluster < -1 || int(cluster)>=len(b.clusters) {return 0,.Invalid}
    if !asset.finite(pose.position.x,pose.position.y,pose.position.z,pose.scale.x,pose.scale.y,pose.scale.z,pose.rotation.x,pose.rotation.y,pose.rotation.z,pose.rotation.w) ||
       pose.scale.x<=0 || pose.scale.y<=0 || pose.scale.z<=0 {return 0,.Invalid}
    if u64(len(b.vertices))+u64(len(mesh.indices))>u64(max(u32)) || u64(len(b.indices))+u64(len(mesh.indices))>u64(max(u32)) {return 0,.Invalid}
    if reserve(&b.vertices,len(b.vertices)+len(mesh.indices))!=nil || reserve(&b.indices,len(b.indices)+len(mesh.indices))!=nil || reserve(&b.pieces,len(b.pieces)+1)!=nil {return 0,.Out_Of_Memory}
    rotation:=pose.rotation==0?mm.QUAT_IDENTITY:linalg.normalize(pose.rotation)
    corners,failed:=make([][4]f32,len(mesh.indices),context.temp_allocator)
    if failed!=nil || !geom.corner_tangents(mesh.positions,mesh.normals,mesh.uvs,mesh.indices,corners) {return 0,.Out_Of_Memory}
    first_vertex,first_index:=u32(len(b.vertices)),u32(len(b.indices))
    for triangle in 0..<len(mesh.indices)/3 {
        a,c,d:=mesh.positions[mesh.indices[triangle*3]],mesh.positions[mesh.indices[triangle*3+1]],mesh.positions[mesh.indices[triangle*3+2]]
        face:=linalg.normalize0(linalg.cross(c-a,d-a))
        for corner in 0..<3 {
            index:=mesh.indices[triangle*3+corner]
            normal:=len(mesh.normals)>0?mesh.normals[index]:face
            vertex:=asset.Vertex{position=pose.position+mm.quat_rotate(rotation,mesh.positions[index]*pose.scale),
                normal=mm.normal_pack(mm.quat_rotate(rotation,linalg.normalize0(normal/pose.scale))),color=0xffffffff}
            tangent:=corners[triangle*3+corner]
            vertex.tangent=mm.tangent_pack(mm.quat_rotate(rotation,linalg.normalize0(tangent.xyz*pose.scale)),tangent.w)
            if len(mesh.uvs)>0 {vertex.uv=mesh.uvs[index]}
            if len(mesh.colors)>0 {vertex.color=mm.rgba8_pack(mesh.colors[index])}
            if len(mesh.materials)>0 {vertex.material=mesh.materials[triangle]}
            append(&b.vertices,vertex);append(&b.indices,u32(triangle*3+corner))
        }
    }
    piece=u32(len(b.pieces))
    append(&b.pieces,Fracture_Piece{first_vertex,u32(len(mesh.indices)),first_index,u32(len(mesh.indices)),cluster,anchor})
    return piece,.None
}

fracture_cluster_add :: proc(b:^Fracture_Builder,parent:i32,strength:f32) -> (cluster:i32,error:asset.Error) {
    if parent < -1 || int(parent)>=len(b.clusters) || !(strength>0) || !asset.finite(strength) {return -1,.Invalid}
    if reserve(&b.clusters,len(b.clusters)+1)!=nil {return -1,.Out_Of_Memory}
    cluster=i32(len(b.clusters));append(&b.clusters,Fracture_Cluster{parent,strength})
    return cluster,.None
}

@(private="file")
fracture_triangles_near :: proc(a,b:mm.Triangle,distance:f32) -> bool {
    first:=[3]mm.Vec3{a.a,a.b,a.c};second:=[3]mm.Vec3{b.a,b.b,b.c}
    limit:=distance*distance
    for point in first {delta:=point-mm.closest_point_triangle(point,b);if linalg.dot(delta,delta)<=limit {return true}}
    for point in second {delta:=point-mm.closest_point_triangle(point,a);if linalg.dot(delta,delta)<=limit {return true}}
    for point,edge in first {
        to:=first[(edge+1)%3]
        if fraction,_,hit:=mm.ray_triangle({point,to-point},b);hit && fraction<=1 {return true}
        for other,other_edge in second {
            end:=second[(other_edge+1)%3]
            p,q,_,_:=mm.closest_segment_segment({point,to},{other,end})
            delta:=p-q
            if linalg.dot(delta,delta)<=limit {return true}
        }
    }
    for point,edge in second {
        if fraction,_,hit:=mm.ray_triangle({point,second[(edge+1)%3]-point},a);hit && fraction<=1 {return true}
    }
    return false
}

fracture_connect_proximity :: proc(b:^Fracture_Builder,distance,area:f32,strength:f32=0) -> asset.Error {
    if distance<0 || !(area>0) || strength<0 || !asset.finite(distance,area,strength) {return .Invalid}
    bounds,error:=make([]mm.Aabb,len(b.pieces))
    if error!=nil {return .Out_Of_Memory}
    defer delete(bounds)
    for piece,at in b.pieces {
        if u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(b.vertices)) || u64(piece.first_index)+u64(piece.index_count)>u64(len(b.indices)) || piece.vertex_count==0 || piece.index_count%3!=0 {return .Invalid}
        vertices:=b.vertices[piece.first_vertex:][:piece.vertex_count]
        low,high:=asset.mesh_bounds(vertices)
        bounds[at]={low,high}
        for index in b.indices[piece.first_index:][:piece.index_count] {if index>=piece.vertex_count {return .Invalid}}
    }
    count:=u64(len(b.pieces))
    if count>u64(max(u32)) || count*(count-1)/2>u64(max(int)) {return .Invalid}
    needed:=int(count*(count-1)/2) if count>0 else 0
    if reserve(&b.connections,needed)!=nil {return .Out_Of_Memory}
    clear(&b.connections)
    for a in 0..<len(b.pieces) {
        for c in a+1..<len(b.pieces) {
            gap:=linalg.max(linalg.max(bounds[a].min-bounds[c].max,bounds[c].min-bounds[a].max),mm.Vec3{})
            if linalg.dot(gap,gap)>distance*distance {continue}
            first,second:=b.pieces[a],b.pieces[c]
            ai:=b.indices[first.first_index:][:first.index_count]
            bi:=b.indices[second.first_index:][:second.index_count]
            found:=false
            for ta in 0..<len(ai)/3 {
                at:=first.first_vertex
                triangle:=mm.Triangle{b.vertices[at+ai[ta*3]].position,b.vertices[at+ai[ta*3+1]].position,b.vertices[at+ai[ta*3+2]].position}
                for tb in 0..<len(bi)/3 {
                    bt:=second.first_vertex
                    other:=mm.Triangle{b.vertices[bt+bi[tb*3]].position,b.vertices[bt+bi[tb*3+1]].position,b.vertices[bt+bi[tb*3+2]].position}
                    if fracture_triangles_near(triangle,other,distance) {found=true;break}
                }
                if found {break}
            }
            if found {append(&b.connections,Fracture_Connection{u32(a),u32(c),area,strength})}
        }
    }
    return .None
}

fracture_builder_desc :: proc(b:^Fracture_Builder,id:base.Asset_Id,source_mesh:base.Asset_Id={}) -> Fracture_Desc {
    return {id=id,source_mesh=source_mesh,vertices=b.vertices[:],indices=b.indices[:],pieces=b.pieces[:],connections=b.connections[:],clusters=b.clusters[:],compression=.LZ}
}
