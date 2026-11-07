package importer

import "mirai:asset"
import "mirai:std/geom"

// Collision data of a mesh, made when it is imported and stored in its asset
// as asset.Collider rows: what a body is given instead of the geometry that
// is drawn.

Collision :: enum u8 {
    None,
    Hull,   // one convex hull of up to COLLISION_HULL_VERTICES vertices
    Pieces, // convex hulls that together stand for a mesh that is not convex (geom.mesh_decompose)
    Mesh,   // the triangles of the surface welded by position, simplified to COLLISION_MESH_SHARE of them
    Exact,  // the triangles of the surface welded by position, all of them: geometry made to collide (a clip)
}

COLLISION_HULL_VERTICES :: 32
COLLISION_MESH_SHARE :: 0.25
COLLISION_MESH_MIN_TRIANGLES :: 64 // a surface with fewer is stored as it is

Mesh_Collision :: struct {
    colliders:[]asset.Collider,
    points:   [][3]f32,
    indices:  []u32, // of a Mesh collider, relative to its first point
}

// The colliders of a surface, in the space of the mesh. hulls: the most
// pieces of Pieces; 0 is geom.DECOMPOSE_DEFAULT_HULLS. ok is false, with
// nothing, for a surface no collider of that kind can be made of: one
// without volume for a hull, one without triangles. Everything returned is
// in `allocator`.
mesh_collision :: proc(vertices:[]asset.Vertex,indices:[]u32,kind:Collision,hulls:=0,allocator:=context.allocator) -> (collision:Mesh_Collision,ok:bool) {
    if kind==.None {return {},true}
    if len(indices)<3 {return}
    temp:=context.temp_allocator
    // The surface alone: the vertices that attributes split are one point.
    positions:=make([]geom.Vec3,len(vertices),temp)
    for vertex,at in vertices {positions[at]=vertex.position}
    weld:=make([]u32,len(vertices),temp)
    geom.positions_weld(positions,0,weld)
    row:=make([]u32,len(vertices),temp)
    points:=make([dynamic]geom.Vec3,0,len(vertices),temp)
    for representative,at in weld {
        if int(representative)==at {
            row[at]=u32(len(points))
            append(&points,positions[at])
        }
    }
    surface:=make([dynamic]u32,0,len(indices),temp)
    for t in 0..<len(indices)/3 {
        a,b,c:=row[weld[indices[t*3]]],row[weld[indices[t*3+1]]],row[weld[indices[t*3+2]]]
        if a!=b && b!=c && c!=a {append(&surface,a,b,c)}
    }
    if len(surface)==0 {return}

    colliders:=make([dynamic]asset.Collider,allocator)
    out_points:=make([dynamic][3]f32,allocator)
    out_indices:=make([dynamic]u32,allocator)
    hull_add :: proc(colliders:^[dynamic]asset.Collider,out_points:^[dynamic][3]f32,hull:geom.Hull) {
        append(colliders,asset.Collider{kind=.Hull,rotation=1,first_point=u32(len(out_points)),point_count=u32(len(hull.vertices))})
        append(out_points,..hull.vertices)
    }
    switch kind {
    case .None:
    case .Hull:
        hull,failed:=geom.hull_build(points[:],{max_vertices=COLLISION_HULL_VERTICES},temp)
        if failed==.None {hull_add(&colliders,&out_points,hull)}
    case .Pieces:
        parts,failed:=geom.mesh_decompose({positions=points[:],indices=surface[:]},{max_hulls=hulls,max_hull_vertices=COLLISION_HULL_VERTICES},temp)
        if failed==.None {
            for hull in parts.hulls {hull_add(&colliders,&out_points,hull)}
        }
    case .Mesh,.Exact:
        kept:=surface[:]
        if kind==.Mesh {
            triangles:=len(surface)/3
            target:=triangles>=COLLISION_MESH_MIN_TRIANGLES?max(int(f32(triangles)*COLLISION_MESH_SHARE),COLLISION_MESH_MIN_TRIANGLES):triangles
            simplified:=make([]u32,len(surface),temp)
            result,failed:=geom.simplify(simplified,surface[:],points[:],target*3,max(f32))
            kept=simplified[:result.index_count] if failed==.None else nil
        }
        if len(kept)>0 {
            // The points the triangles that remain use, in their order.
            used:=make([]u32,len(points),temp)
            for &at in used {at=max(u32)}
            point_count:u32
            for index in kept {
                if used[index]==max(u32) {
                    used[index]=point_count
                    point_count+=1
                    append(&out_points,points[index])
                }
                append(&out_indices,used[index])
            }
            append(&colliders,asset.Collider{kind=.Mesh,rotation=1,point_count=point_count,index_count=u32(len(kept))})
        }
    }
    if len(colliders)==0 {
        delete(colliders);delete(out_points);delete(out_indices)
        return
    }
    return {colliders[:],out_points[:],out_indices[:]},true
}
