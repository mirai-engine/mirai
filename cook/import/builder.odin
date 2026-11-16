package importer

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// Collects the triangles of one mesh as an indexed vertex buffer: equal
// vertices are shared, and the triangles of each material slot end up in a
// contiguous range of the index buffer.
Mesh_Builder :: struct {
    r:^Reader,
    vertices:[dynamic]asset.Vertex,
    skin:[dynamic]asset.Skin_Vertex,
    sources:[dynamic]Vertex_Source, // one per vertex
    skinned:bool,
    slots:[dynamic]Imported_Slot,
    slot_indices:[dynamic][dynamic]u32,
    lookup:map[Vertex_Key]u32,
    has_uv1:bool, // the mesh has a second set of texture coordinates of its own
    untangent:bool, // some corner came without a tangent
    faces:u32,      // triangles added
    // What builder_morph made, in the out allocator of the reader, and the
    // MikkTSpace tangents of the corners at rest it compares a shape with.
    morphs:[dynamic]asset.Morph_Target,
    morph_deltas:[dynamic]asset.Morph_Delta,
    rest_tangents:[][4]f32,
}

// What a vertex was made of besides its attributes: the morph vertex of the
// source it moves with, the face whose normal it follows (0: none), and
// whether the source stated its tangent.
@(private)
Vertex_Source :: struct {
    morph,face:u32,
    stated:bool,
}

@(private)
Vertex_Key :: struct {
    vertex:asset.Vertex,
    skin:asset.Skin_Vertex,
    source:Vertex_Source,
}

// A corner of a triangle as the source states it, in its Source_Space.
Corner :: struct {
    position:[3]f32,
    normal:[3]f32, // unit length
    uv,uv1:[2]f32,
    has_uv:bool,   // without it, uv is 0
    has_uv1:bool,  // without it, uv1 is uv
    color:u32,     // rgba8
    tangent:[4]f32, // xyz along u, w the sign of the bitangent sign * cross(normal, tangent), as glTF states them
    has_tangent:bool, // without it, MikkTSpace makes one
    morph:u32,      // 1 + the morph vertex it moves with (Morph_Shape); 0: it does not morph
    flat:bool,      // normal is that of its face, which a morph turns
}

// A morph target as a source states it, in its Source_Space: what weight 1
// adds to each morph vertex the corners name (Corner.morph).
Morph_Shape :: struct {
    name:string,
    weight:f32,         // without animation or override
    positions:[][3]f32, // one per morph vertex
    normals:[][3]f32,   // one per morph vertex, or none: the normal of a flat corner follows its face, the others stay
    tangents:[][3]f32,  // one per morph vertex, or none; read where the source states the tangent
}

builder_init :: proc(b:^Mesh_Builder,r:^Reader,skinned:=false) {
    b^={r=r,skinned=skinned}
    b.vertices.allocator=context.temp_allocator
    b.skin.allocator=context.temp_allocator
    b.sources.allocator=context.temp_allocator
    b.morphs.allocator=r.out
    b.morph_deltas.allocator=r.out
    b.slots.allocator=context.temp_allocator
    b.slot_indices.allocator=context.temp_allocator
    b.lookup.allocator=context.temp_allocator
}

builder_triangles :: proc(b:^Mesh_Builder) -> int {
    count:=0
    for indices in b.slot_indices {count+=len(indices)/3}
    return count
}

// The row of the slot with this source id, added with its label and material the first time.
builder_slot :: proc(b:^Mesh_Builder,id:u32,label:string,material:int) -> (row:int,ok:bool) {
    for slot,at in b.slots {
        if slot.id==id {return at,true}
    }
    if len(b.slots)>=asset.MESH_MAX_SLOTS {return 0,fail(b.r,.Limit,"the mesh uses more than %d material slots",asset.MESH_MAX_SLOTS)}
    name:=label if label!="" else fmt.aprintf("Slot %d",id,allocator=b.r.out)
    append(&b.slots,Imported_Slot{id=id,label=own(b.r,name),material=material})
    append(&b.slot_indices,make([dynamic]u32,context.temp_allocator))
    return len(b.slots)-1,true
}

@(private="file")
builder_vertex :: proc(b:^Mesh_Builder,vertex:asset.Vertex,skin:asset.Skin_Vertex,source:Vertex_Source) -> u32 {
    key:=Vertex_Key{vertex,skin,source}
    if found,exists:=b.lookup[key];exists {return found}
    index:=u32(len(b.vertices))
    append(&b.vertices,vertex)
    append(&b.sources,source)
    if b.skinned {append(&b.skin,skin)}
    b.lookup[key]=index
    return index
}

// Adds a triangle to a slot, turned to the engine's space: positions,
// normals and texture coordinates, and the order of its corners when the
// space of the source is mirrored. The flat corners of a face that morphs
// are its own: another face may turn otherwise.
builder_triangle :: proc(b:^Mesh_Builder,slot:int,corners:[3]Corner,skin:[3]asset.Skin_Vertex={}) {
    indices:=&b.slot_indices[slot]
    space,basis:=b.r.space,b.r.basis
    order:=[3]int{0,2,1} if basis.mirrored else {0,1,2}
    b.faces+=1
    for k in order {
        corner:=corners[k]
        uv:[2]f32
        if corner.has_uv {uv=space_uv(space,corner.uv)}
        uv1:=uv
        if corner.has_uv1 {uv1=space_uv(space,corner.uv1)}
        position,normal:=corner.position,corner.normal
        if !basis.identity {position,normal=space_point(basis,position),space_direction(basis,normal)}
        vertex:=asset.Vertex{position=position,normal=mm.normal_pack(normal),uv=uv,color=corner.color,material=u32(slot),uv1=uv1}
        if corner.has_tangent {
            // A mirrored space and a v that starts at the other end each turn the side of the bitangent.
            along:=corner.tangent.xyz if basis.identity else space_direction(basis,corner.tangent.xyz)
            sign:=corner.tangent.w
            if basis.mirrored {sign=-sign}
            if space.v_origin==.Bottom {sign=-sign}
            vertex.tangent=mm.tangent_pack(along,sign)
        } else {
            b.untangent=true
        }
        source:=Vertex_Source{morph=corner.morph,stated=corner.has_tangent}
        if corner.flat && corner.morph!=0 {source.face=b.faces}
        append(indices,builder_vertex(b,vertex,skin[k],source))
    }
}

// n made unit length, or flat when it has none.
normal_of :: proc(n:[3]f32,flat:[3]f32) -> [3]f32 {
    length:=linalg.length(n)
    if length>1e-6 && length-length==0 {return n/length}
    return flat
}

face_normal :: proc(a,b,c:[3]f32,fallback:[3]f32) -> [3]f32 {
    n:=linalg.cross(b-a,c-a)
    length:=linalg.length(n)
    if length>1e-20 {return n/length}
    return fallback
}

// Positions of a polygon as triangles of its corners. Fails for a polygon without area.
polygon_triangulate :: proc(r:^Reader,points:[][3]f32,out:^[dynamic][3]int,scratch:^[dynamic][2]f32,result:^[dynamic]u32) -> bool {
    count:=len(points)
    if count<3 {return false}
    normal:[3]f32
    for p,i in points {
        q:=points[(i+1)%count]
        normal+=[3]f32{(p.y-q.y)*(p.z+q.z),(p.z-q.z)*(p.x+q.x),(p.x-q.x)*(p.y+q.y)}
    }
    axis:=0
    if abs(normal.y)>abs(normal[axis]) {axis=1}
    if abs(normal.z)>abs(normal[axis]) {axis=2}
    if abs(normal[axis])<1e-9 || normal[axis]-normal[axis]!=0 {return false}
    if count==3 {
        append(out,[3]int{0,1,2})
        return true
    }
    u,v:=(axis+1)%3,(axis+2)%3
    if normal[axis]<0 {u,v=v,u}
    if count==4 {
        convex:=true
        for i in 0..<4 {
            a,b,c:=points[i],points[(i+1)%4],points[(i+2)%4]
            cross:=(b[u]-a[u])*(c[v]-b[v])-(b[v]-a[v])*(c[u]-b[u])
            if cross<=1e-12 {convex=false;break}
        }
        if convex {
            append(out,[3]int{0,1,2},[3]int{0,2,3})
            return true
        }
    }
    clear(scratch);clear(result)
    for p in points {append(scratch,[2]f32{p[u],p[v]})}
    loops:=[1]int{count}
    // std/geom works in scratch memory of its own, which is released after each polygon.
    saved:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&r.polygon_arena)
    geom.polygon_triangulate(scratch[:],loops[:],result)
    context.temp_allocator=saved
    mem.dynamic_arena_free_all(&r.polygon_arena)
    for at:=0;at+2<len(result);at+=3 {append(out,[3]int{int(result[at]),int(result[at+1]),int(result[at+2])})}
    return len(result)>=3
}

// The tangents of the corners that came without one: MikkTSpace over the
// mesh, each slot with the uvs its normal map reads. A vertex whose corners
// take different tangents is split, with its skin.
@(private="file")
builder_tangents :: proc(b:^Mesh_Builder) {
    if !b.untangent {return}
    count:=len(b.vertices)
    positions:=make([][3]f32,count,context.temp_allocator)
    normals:=make([][3]f32,count,context.temp_allocator)
    uvs:=make([][2]f32,count,context.temp_allocator)
    for vertex,i in b.vertices {
        positions[i],normals[i],uvs[i]=vertex.position,mm.normal_unpack(vertex.normal),vertex.uv
        material:=b.slots[vertex.material].material
        if material>=0 && b.r.materials[material].info.maps.normal.uv_set==1 {uvs[i]=vertex.uv1}
    }
    total:=0
    for list in b.slot_indices {total+=len(list)}
    indices:=make([]u32,total,context.temp_allocator)
    at:=0
    for list in b.slot_indices {at+=copy(indices[at:],list[:])}
    corners:=make([][4]f32,total,context.temp_allocator)
    if !geom.corner_tangents(positions,normals,uvs,indices,corners) {
        fail(b.r,.Limit,"MikkTSpace could not make the tangents of a mesh of %d triangles",total/3)
        return
    }
    vertices,skin,sources:=b.vertices,b.skin,b.sources
    b.vertices=make([dynamic]asset.Vertex,0,count,context.temp_allocator)
    b.skin=make([dynamic]asset.Skin_Vertex,0,len(skin),context.temp_allocator)
    b.sources=make([dynamic]Vertex_Source,0,count,context.temp_allocator)
    clear(&b.lookup)
    at=0
    for &list in b.slot_indices {
        for &index in list {
            vertex:=vertices[index]
            if vertex.tangent==0 {vertex.tangent=mm.tangent_pack(corners[at].xyz,corners[at].w)}
            index=builder_vertex(b,vertex,skin[index] if b.skinned else {},sources[index])
            at+=1
        }
    }
}

// The MikkTSpace tangents of the corners of the mesh, in the order of its
// indices, with these positions and normals and the uvs each slot's normal
// map reads.
@(private="file")
builder_corner_tangents :: proc(b:^Mesh_Builder,mesh:Imported_Mesh,positions,normals:[][3]f32,corners:[][4]f32) -> bool {
    uvs:=make([][2]f32,len(mesh.vertices),context.temp_allocator)
    for vertex,i in mesh.vertices {
        uvs[i]=vertex.uv
        material:=b.slots[vertex.material].material
        if material>=0 && b.r.materials[material].info.maps.normal.uv_set==1 {uvs[i]=vertex.uv1}
    }
    return geom.corner_tangents(positions,normals,uvs,mesh.indices,corners)
}

// Adds a morph target to a mesh of builder_finish: the deltas of the vertices
// it moves, in the engine's space. A flat corner's normal follows its face. A
// tangent the source stated takes shape.tangents; the others take what
// MikkTSpace makes of the shape at weight 1, against what it makes at rest.
builder_morph :: proc(b:^Mesh_Builder,mesh:^Imported_Mesh,shape:Morph_Shape) -> bool {
    r:=b.r
    basis:=r.basis
    count:=len(shape.positions)
    if len(b.morphs)>=asset.MESH_MAX_MORPHS {return fail(r,.Limit,"mesh %s has more than %d morph targets",mesh.name,asset.MESH_MAX_MORPHS)}
    if shape.name=="" || len(shape.name)>=64 {return fail(r,.Limit,"mesh %s: a morph target name must have 1 to 63 bytes: %q",mesh.name,shape.name)}
    for &other in b.morphs {if base.text_get(other.name[:])==shape.name {return fail(r,.Malformed,"mesh %s has two morph targets named %s; give them distinct names",mesh.name,shape.name)}}
    if shape.weight-shape.weight!=0 {return fail(r,.Malformed,"mesh %s: the weight of morph target %s is not finite",mesh.name,shape.name)}
    if len(shape.normals)!=0 && len(shape.normals)!=count || len(shape.tangents)!=0 && len(shape.tangents)!=count {return fail(r,.Malformed,"mesh %s: morph target %s states normals or tangents for another number of vertices than positions",mesh.name,shape.name)}
    for value,i in shape.positions {
        normal:=shape.normals[i] if len(shape.normals)>0 else {}
        tangent:=shape.tangents[i] if len(shape.tangents)>0 else {}
        if !finite3(value) || !finite3(normal) || !finite3(tangent) {return fail(r,.Malformed,"mesh %s: morph target %s has a delta that is not finite",mesh.name,shape.name)}
    }
    vertices:=mesh.vertices
    if len(b.sources)!=len(vertices) {return fail(r,.Malformed,"mesh %s: morph targets need the mesh as builder_finish made it",mesh.name)}
    deltas:=make([]asset.Morph_Delta,len(vertices),context.temp_allocator)
    moved:=false
    for source,v in b.sources {
        if source.morph==0 {continue}
        at:=int(source.morph)-1
        if at>=count {return fail(r,.Malformed,"mesh %s: morph target %s has no delta for a vertex of the mesh",mesh.name,shape.name)}
        delta:=&deltas[v]
        delta.position=space_point(basis,shape.positions[at])
        if source.face==0 && len(shape.normals)>0 {delta.normal=space_direction(basis,shape.normals[at])}
        if source.stated && len(shape.tangents)>0 {delta.tangent=space_direction(basis,shape.tangents[at])}
        moved ||= delta.position!={} || delta.normal!={}
    }
    // A flat face takes the normal of its shape; one that keeps it moves no normal.
    for at:=0;at+2<len(mesh.indices);at+=3 {
        triangle:=mesh.indices[at:][:3]
        if b.sources[triangle[0]].face==0 {continue}
        rest,shaped:[3][3]f32
        for vertex,k in triangle {rest[k]=vertices[vertex].position;shaped[k]=rest[k]+deltas[vertex].position}
        before:=face_normal(rest[0],rest[1],rest[2],mm.normal_unpack(vertices[triangle[0]].normal))
        after:=face_normal(shaped[0],shaped[1],shaped[2],before)
        for vertex in triangle {
            if b.sources[vertex].face==0 {continue}
            deltas[vertex].normal=after-mm.normal_unpack(vertices[vertex].normal) if after!=before else {}
        }
    }
    if moved && !builder_morph_tangents(b,mesh^,deltas) {return false}
    target:=asset.Morph_Target{weight=shape.weight,first=u32(len(b.morph_deltas))}
    base.text_set(target.name[:],shape.name)
    for &delta,v in deltas {
        if delta.position=={} && delta.normal=={} && delta.tangent=={} {continue}
        delta.vertex=u32(v)
        append(&b.morph_deltas,delta)
    }
    target.count=u32(len(b.morph_deltas))-target.first
    append(&b.morphs,target)
    mesh.morphs,mesh.morph_deltas=b.morphs[:],b.morph_deltas[:]
    return true
}

// The tangent deltas of the vertices whose tangent MikkTSpace made: where
// the corners of a vertex take another tangent on the shape, the mean of
// what they take there, less the tangent of the vertex.
@(private="file")
builder_morph_tangents :: proc(b:^Mesh_Builder,mesh:Imported_Mesh,deltas:[]asset.Morph_Delta) -> bool {
    made:=false
    for source in b.sources {made ||= !source.stated}
    if !made {return true}
    count:=len(mesh.vertices)
    positions:=make([][3]f32,count,context.temp_allocator)
    normals:=make([][3]f32,count,context.temp_allocator)
    for vertex,i in mesh.vertices {positions[i],normals[i]=vertex.position,mm.normal_unpack(vertex.normal)}
    if b.rest_tangents==nil {
        b.rest_tangents=make([][4]f32,len(mesh.indices),context.temp_allocator)
        if !builder_corner_tangents(b,mesh,positions,normals,b.rest_tangents) {return fail(b.r,.Limit,"MikkTSpace could not make the tangents of mesh %s",mesh.name)}
    }
    for &position,i in positions {
        position+=deltas[i].position
        normals[i]=normal_of(normals[i]+deltas[i].normal,normals[i])
    }
    corners:=make([][4]f32,len(mesh.indices),context.temp_allocator)
    if !builder_corner_tangents(b,mesh,positions,normals,corners) {return fail(b.r,.Limit,"MikkTSpace could not make the tangents of a morph target of mesh %s",mesh.name)}
    sums:=make([][3]f32,count,context.temp_allocator)
    turned:=make([]bool,count,context.temp_allocator)
    for vertex,at in mesh.indices {
        if b.sources[vertex].stated {continue}
        sums[vertex]+=corners[at].xyz
        rest:=b.rest_tangents[at]
        turned[vertex] ||= abs(corners[at].x-rest.x)>1e-6 || abs(corners[at].y-rest.y)>1e-6 || abs(corners[at].z-rest.z)>1e-6
    }
    for vertex,i in mesh.vertices {
        if !turned[i] {continue}
        length:=linalg.length(sums[i])
        if !(length>1e-6) {continue}
        tangent,_:=mm.tangent_unpack(vertex.tangent)
        deltas[i].tangent=sums[i]/length-tangent
    }
    return true
}

// Lays the index buffer out by slot and returns the mesh.
builder_finish :: proc(b:^Mesh_Builder,name:string) -> Imported_Mesh {
    r:=b.r
    builder_tangents(b)
    mesh:=Imported_Mesh{name=own(r,name),skeleton=-1}
    total:=0
    for indices in b.slot_indices {total+=len(indices)}
    all_indices:=make([]u32,total,r.out)
    submeshes:=make([dynamic]Submesh,context.temp_allocator)
    at:=0
    for indices,slot in b.slot_indices {
        if len(indices)==0 {continue}
        first:=at
        copy(all_indices[at:],indices[:])
        at+=len(indices)
        append(&submeshes,Submesh{first_index=u32(first),index_count=u32(len(indices)),slot=u32(slot)})
    }
    mesh.vertices=own_slice(r,b.vertices[:])
    mesh.indices=all_indices
    mesh.skin=own_slice(r,b.skin[:])
    mesh.submeshes=own_slice(r,submeshes[:])
    mesh.slots=own_slice(r,b.slots[:])
    for vertex in b.vertices {
        if vertex.color!=WHITE {mesh.flags+={.Has_Colors};break}
    }
    if b.has_uv1 {mesh.flags+={.Has_Uv1}}
    mesh.bounds_min,mesh.bounds_max=asset.mesh_bounds(mesh.vertices)
    return mesh
}
