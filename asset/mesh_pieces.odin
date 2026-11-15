package asset

import "core:fmt"
import "core:os"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/serial"

// What a mesh asset stores of the colliders of its source: nothing, shapes
// (hulls, boxes, spheres, capsules) or a collision mesh, which wins.
Stored_Collision :: enum u8 {None,Shapes,Mesh}

mesh_collision_stored :: proc(view:Mesh_View) -> (stored:Stored_Collision) {
    for collider in view.colliders {
        if collider.kind==.Mesh && collider.index_count>0 {return .Mesh}
        if collider.kind!=.Mesh && (collider.kind!=.Hull || collider.point_count>=3) {stored=.Shapes}
    }
    return
}

// The convex pieces of a mesh file that stores no colliders, kept in a folder
// of the cache by the content of the file: a file of this kind and version,
// whose id is its key.
COLLISION_PIECES_KIND :: Fourcc(u32('P')|u32('C')<<8|u32('E')<<16|u32('S')<<24)
COLLISION_PIECES_VERSION :: 1 // raise it when mesh_collision_pieces gives other pieces for the same mesh
COLLISION_PIECES_EXTENSION :: ".pieces"

// Appends the convex pieces that a moving body of a mesh file without
// colliders of its source collides as: a decomposition of the triangles of
// its finest level (geom.mesh_decompose). points receives the points of each
// piece one after another, in mesh space, and sizes how many each has. A
// cooked mesh carries them (Mesh_View.piece_points); else the first time it
// decomposes, and keeps the pieces in folder, then reads them from there.
// Without a folder (a shipped game) nothing is decomposed. False, with both
// as they were, for a mesh that stores colliders or of which no piece is had.
mesh_collision_pieces :: proc(file:^Asset,types:^Types,folder:string,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32) -> bool {
    if points==nil || sizes==nil {return false}
    view,error:=mesh_view(file,types)
    if error!=.None || !mesh_check_indices(view) || mesh_collision_stored(view)!=.None {return false}
    held_points,held_sizes:=len(points),len(sizes)
    if len(view.piece_sizes)>0 {
        if append(points,..view.piece_points)!=len(view.piece_points) || append(sizes,..view.piece_sizes)!=len(view.piece_sizes) {
            base.truncate(points,held_points)
            base.truncate(sizes,held_sizes)
            return false
        }
        return true
    }
    if folder=="" {return false}
    key:=base.hash_combine(file.blob.header.content_hash,u64(COLLISION_PIECES_VERSION)<<16|u64(MESH_VERSION))|1
    id:=base.Asset_Id{key,u64(COLLISION_PIECES_VERSION)}
    path:=fmt.tprintf("%s/%016x%s",folder,key,COLLISION_PIECES_EXTENSION)
    {
        cached:Asset
        if asset_load(&cached,path,context.temp_allocator)==.None {
            defer asset_close(&cached)
            header:=cached.blob.header
            if header.kind==COLLISION_PIECES_KIND && header.kind_version==COLLISION_PIECES_VERSION && header.id==id && blob_verify_hash(&cached.blob) {
                kept_points,points_error:=asset_rows(&cached,types,"points","",[3]f32)
                kept_sizes,sizes_error:=asset_rows(&cached,types,"sizes","",u32)
                total:=0
                for size in kept_sizes {total+=int(size)}
                if points_error==.None && sizes_error==.None && total==len(kept_points) {
                    if append(points,..kept_points)!=len(kept_points) || append(sizes,..kept_sizes)!=len(kept_sizes) {
                        base.truncate(points,held_points)
                        base.truncate(sizes,held_sizes)
                        return false
                    }
                    return len(kept_sizes)>0
                }
            }
        }
    }
    // The surface alone: the vertices that attributes split are one point.
    vertices:=make([dynamic]Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    made_points:=make([dynamic][3]f32,context.temp_allocator)
    made_sizes:=make([dynamic]u32,context.temp_allocator)
    if mesh_level_decode(view.geometry,0,&vertices,&indices) && len(indices)>0 {
        positions:=make([]geom.Vec3,len(vertices),context.temp_allocator)
        for vertex,at in vertices {positions[at]=vertex.position}
        weld:=make([]u32,len(positions),context.temp_allocator)
        geom.positions_weld(positions,0,weld)
        row:=make([]u32,len(positions),context.temp_allocator)
        welded:=make([dynamic]geom.Vec3,0,len(positions),context.temp_allocator)
        for representative,at in weld {
            if int(representative)==at {
                row[at]=u32(len(welded))
                append(&welded,positions[at])
            }
        }
        triangles:=make([dynamic]u32,0,len(indices),context.temp_allocator)
        for t in 0..<len(indices)/3 {
            a,b,c:=row[weld[indices[t*3]]],row[weld[indices[t*3+1]]],row[weld[indices[t*3+2]]]
            if a!=b && b!=c && c!=a {append(&triangles,a,b,c)}
        }
        if len(triangles)>0 {
            if parts,failed:=geom.mesh_decompose({positions=welded[:],indices=triangles[:]},{},context.temp_allocator);failed==.None {
                for hull in parts.hulls {
                    if len(hull.vertices)<3 {continue}
                    append(&made_points,..hull.vertices)
                    append(&made_sizes,u32(len(hull.vertices)))
                }
            }
        }
    }
    // Kept even without pieces: a mesh of which none can be made is not decomposed again.
    if os.is_dir(folder) || os.make_directory_all(folder)==nil {
        doc:Document
        document_init(&doc,COLLISION_PIECES_KIND,id,context.temp_allocator)
        doc.kind_version=COLLISION_PIECES_VERSION
        _,points_error:=document_put(&doc,types,"points",made_points[:])
        _,sizes_error:=document_put(&doc,types,"sizes",made_sizes[:])
        if points_error==.None && sizes_error==.None {
            if bytes,bytes_error:=document_bytes(&doc,context.temp_allocator);bytes_error==.None {_=serial.file_write_atomic(path,bytes)}
        }
    }
    if len(made_sizes)==0 {return false}
    if append(points,..made_points[:])!=len(made_points) || append(sizes,..made_sizes[:])!=len(made_sizes) {
        base.truncate(points,held_points)
        base.truncate(sizes,held_sizes)
        return false
    }
    return true
}
