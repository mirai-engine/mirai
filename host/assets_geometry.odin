package host

import "core:fmt"
import "core:os"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"

// The primitive a Mesh_Renderer without a mesh asset shows.
Shape :: enum u8 {None,Cube,Sphere,Cylinder,Cone,Capsule,Plane,Prism,Pyramid}

// The geometry a collider is made of.
Collision :: enum u8 {Other,Hull,Mesh}

// Geometry on the CPU for what is not drawn: collision shapes and fracture.
// The renderer keeps the meshes it was given, so this reads the file again or
// builds the primitive again: a transaction.

// The material each slot of a mesh asset came with: what its Mesh_Renderer
// shows in a slot it does not assign.
Assets_Slots :: struct {
    count:u32,
    materials:[asset.MESH_MAX_SLOTS]base.Asset_Id,
}

// Appends the positions and indices of what a Mesh_Renderer shows (the finest
// level of its mesh asset, or its primitive shape) to the buffer. With
// attributes, also the normal, UV and color of every vertex and the material
// slot of every triangle, for a buffer that holds nothing or holds them
// already. slots, when given, receives the slots of the mesh asset (none for
// a primitive), without loading the mesh. a may be nil for a primitive.
// False, with the buffer as it was, when there is no geometry to give.
assets_geometry :: proc(a:^Assets,mesh:base.Asset_Id,shape:Shape,buffer:^geom.Mesh_Buffer,attributes:=false,slots:^Assets_Slots=nil) -> bool {
    if buffer==nil {return false}
    if slots!=nil {slots^={}}
    if mesh=={} {
        built:geom.Mesh_Buffer
        geom.mesh_buffer_init(&built,context.temp_allocator)
        defer geom.mesh_buffer_destroy(&built)
        vertices,indices:=0,0
        switch shape {
        case .None:return false
        case .Cube:vertices,indices=24,36
        case .Sphere:vertices,indices=(geom.SHAPE_SEGMENTS+1)*(geom.SHAPE_RINGS+1),geom.SHAPE_SEGMENTS*geom.SHAPE_RINGS*6
        case .Cylinder:vertices,indices=4*(geom.SHAPE_SEGMENTS+1),geom.SHAPE_SEGMENTS*12
        case .Cone:vertices,indices=4*geom.SHAPE_SEGMENTS+1,geom.SHAPE_SEGMENTS*6
        case .Capsule:vertices,indices=(geom.SHAPE_SEGMENTS+1)*(geom.SHAPE_RINGS+2),geom.SHAPE_SEGMENTS*(geom.SHAPE_RINGS+1)*6
        case .Plane:vertices,indices=4,6
        case .Prism:vertices,indices=18,24
        case .Pyramid:vertices,indices=16,18
        case:return false
        }
        if reserve(&built.positions,vertices)!=nil || reserve(&built.normals,vertices)!=nil ||
            reserve(&built.uvs,vertices)!=nil || reserve(&built.indices,indices)!=nil {return false}
        switch shape {
        case .None:     return false
        case .Cube:     geom.cube_build(&built)
        case .Sphere:   geom.sphere_build(&built)
        case .Cylinder: geom.cylinder_build(&built)
        case .Cone:     geom.cone_build(&built)
        case .Capsule:  geom.capsule_build(&built)
        case .Plane:    geom.plane_build(&built)
        case .Prism:    geom.prism_build(&built)
        case .Pyramid:  geom.pyramid_build(&built)
        }
        return assets_geometry_append(geom.mesh_buffer_view(&built),buffer,attributes)
    }
    if a==nil {return false}
    if assets_mesh_generated(a,mesh) {
        entry:=&a.meshes[a.index[mesh].index]
        if !assets_geometry_append(entry.collision,buffer,attributes) {return false}
        if slots!=nil {slots^={count=entry.slot_count,materials=entry.slot_materials}}
        return true
    }
    file:asset.Asset
    if _,_,ok:=assets_open(a,mesh,.Mesh,&file);!ok {return false}
    defer asset.asset_close(&file)
    view,error:=asset.mesh_view(&file,&a.types)
    if error!=.None || !asset.mesh_check_indices(view) {return false}
    return geometry_of_view(view,buffer,attributes,slots)
}

// The finest level of a mesh file, as assets_geometry gives it.
@(private="file")
geometry_of_view :: proc(view:asset.Mesh_View,buffer:^geom.Mesh_Buffer,attributes:=false,slots:^Assets_Slots=nil) -> bool {
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    if !asset.mesh_level_decode(view.geometry,0,&vertices,&indices) || len(indices)==0 {return false}
    if !assets_geometry_reserve(buffer,len(vertices),len(indices),attributes) {return false}
    first:=u32(len(buffer.positions))
    for vertex in vertices {append(&buffer.positions,vertex.position)}
    for index in indices {append(&buffer.indices,first+index)}
    if attributes {
        for vertex in vertices {
            append(&buffer.normals,mm.normal_unpack(vertex.normal))
            append(&buffer.uvs,vertex.uv)
            append(&buffer.colors,mm.rgba8_unpack(vertex.color))
        }
        for triangle in 0..<len(indices)/3 {append(&buffer.materials,vertices[indices[triangle*3]].material)}
    }
    if slots!=nil {
        held:=view.slots[:min(len(view.slots),asset.MESH_MAX_SLOTS)]
        slots.count=u32(len(held))
        for slot,at in held {slots.materials[at]=slot.material}
    }
    return true
}

@(private="file")
assets_geometry_reserve :: proc(buffer:^geom.Mesh_Buffer,vertices,indices:int,attributes:bool) -> bool {
    if !geom.mesh_is_valid(geom.mesh_buffer_view(buffer)) || vertices<0 || indices<0 ||
        len(buffer.positions)>int(max(u32))-vertices || len(buffer.indices)>max(int)-indices {return false}
    count:=len(buffer.positions)
    if attributes {
        if len(buffer.normals)!=count || len(buffer.uvs)!=count || len(buffer.materials)!=len(buffer.indices)/3 {return false}
    } else if len(buffer.normals)>0 || len(buffer.uvs)>0 || len(buffer.colors)>0 || len(buffer.materials)>0 {return false}
    if reserve(&buffer.positions,count+vertices)!=nil || reserve(&buffer.indices,len(buffer.indices)+indices)!=nil {return false}
    if attributes {
        if reserve(&buffer.normals,count+vertices)!=nil || reserve(&buffer.uvs,count+vertices)!=nil ||
            reserve(&buffer.colors,count+vertices)!=nil || reserve(&buffer.materials,(len(buffer.indices)+indices)/3)!=nil {return false}
        for _ in len(buffer.colors)..<count {append(&buffer.colors,geom.Vec4{1,1,1,1})}
    }
    return true
}

@(private="file")
assets_geometry_append :: proc(source:geom.Mesh,buffer:^geom.Mesh_Buffer,attributes:bool) -> bool {
    if len(source.indices)==0 || !geom.mesh_is_valid(source) {return false}
    if attributes && (len(source.normals)!=len(source.positions) || len(source.uvs)!=len(source.positions)) {return false}
    if !assets_geometry_reserve(buffer,len(source.positions),len(source.indices),attributes) {return false}
    first:=u32(len(buffer.positions))
    append(&buffer.positions,..source.positions)
    for index in source.indices {append(&buffer.indices,first+index)}
    if attributes {
        append(&buffer.normals,..source.normals);append(&buffer.uvs,..source.uvs)
        if len(source.colors)>0 {append(&buffer.colors,..source.colors)} else {
            for _ in source.positions {append(&buffer.colors,geom.Vec4{1,1,1,1})}
        }
        if len(source.materials)>0 {append(&buffer.materials,..source.materials)} else {
            for _ in 0..<len(source.indices)/3 {append(&buffer.materials,0)}
        }
    }
    return true
}

// Appends the geometry a collider of one kind is made of for what a
// Mesh_Renderer shows: the points of a hull (.Hull, no indices) or the
// triangles of a surface (.Mesh). A mesh asset that stores colliders gives
// them instead of the geometry it is drawn with:
//
//   the asset stores        a .Hull takes            a .Mesh takes
//   shapes                  the points of all        their hulls, as triangles
//   a collision mesh        its points               its triangles
//   nothing                 the vertices of level 0  the triangles of level 0
//
// Shapes are hulls, boxes, spheres and capsules; a sphere or a capsule is
// the hull of COLLIDER_SHAPE_SEGMENTS around its axis. A Hull collider takes
// them one by one from assets_collision_hulls; the points of all are what it
// takes where it cannot.
//
// stored: the geometry is that of the colliders of the asset. ok is false,
// with the buffer as it was, when there is no geometry to give.
assets_collision :: proc(a:^Assets,mesh:base.Asset_Id,shape:Shape,kind:Collision,buffer:^geom.Mesh_Buffer) -> (stored,ok:bool) {
    if kind==.Other || mesh=={} || a==nil {return false,assets_geometry(a,mesh,shape,buffer)}
    if assets_mesh_generated(a,mesh) {return true,assets_geometry(a,mesh,shape,buffer)}
    file:asset.Asset
    if _,_,opened:=assets_open(a,mesh,.Mesh,&file);!opened {return}
    defer asset.asset_close(&file)
    return assets_collision_file(&file,&a.types,kind,buffer)
}

// assets_collision of the open file of a mesh asset (Hull or Mesh), on any
// thread with types of its own: what a job reads (assets_source_open).
assets_collision_file :: proc(file:^asset.Asset,types:^asset.Types,kind:Collision,buffer:^geom.Mesh_Buffer) -> (stored,ok:bool) {
    view,error:=asset.mesh_view(file,types)
    if error!=.None || !asset.mesh_check_indices(view) {return}
    surface,shapes:=-1,0
    for collider,at in view.colliders {
        if collider.kind==.Mesh && surface<0 && collider.index_count>0 {surface=at}
        if collider.kind!=.Mesh && (collider.kind!=.Hull || collider.point_count>=3) {shapes+=1}
    }
    switch {
    case surface>=0:
        collider:=view.colliders[surface]
        first:=u32(len(buffer.positions))
        append(&buffer.positions,..view.collision_points[collider.first_point:][:collider.point_count])
        if kind==.Mesh {
            for index in view.collision_indices[collider.first_index:][:collider.index_count] {append(&buffer.indices,first+index)}
        }
        return true,true
    case shapes>0:
        positions,indices:=len(buffer.positions),len(buffer.indices)
        points:=make([dynamic]geom.Vec3,context.temp_allocator)
        for collider in view.colliders {
            if collider.kind==.Mesh || collider.kind==.Hull && collider.point_count<3 {continue}
            clear(&points)
            collider_points(view,collider,&points)
            if kind==.Hull {
                append(&buffer.positions,..points[:])
                continue
            }
            hull,failed:=geom.hull_build(points[:],{},context.temp_allocator)
            if failed==.None {geom.hull_append_mesh(hull,buffer)}
        }
        if len(buffer.positions)>positions && (kind==.Hull || len(buffer.indices)>indices) {return true,true}
        base.truncate(&buffer.positions,positions)
        base.truncate(&buffer.indices,indices)
    }
    return false,geometry_of_view(view,buffer)
}

// What a mesh asset stores of the colliders of its source: nothing, shapes
// (hulls, boxes, spheres, capsules) or a collision mesh, which wins.
Stored_Collision :: enum u8 {None,Shapes,Mesh}

assets_collision_stored :: proc(view:asset.Mesh_View) -> (stored:Stored_Collision) {
    for collider in view.colliders {
        if collider.kind==.Mesh && collider.index_count>0 {return .Mesh}
        if collider.kind!=.Mesh && (collider.kind!=.Hull || collider.point_count>=3) {stored=.Shapes}
    }
    return
}

// Whether a mesh asset stores colliders of its source: what a placed mesh
// collides with. False for a generated mesh, a primitive or a mesh that does
// not read.
assets_mesh_collides :: proc(a:^Assets,mesh:base.Asset_Id) -> bool {
    if a==nil || mesh=={} || assets_mesh_generated(a,mesh) {return false}
    file:asset.Asset
    if _,_,opened:=assets_open(a,mesh,.Mesh,&file);!opened {return false}
    defer asset.asset_close(&file)
    view,error:=asset.mesh_view(&file,&a.types)
    return error==.None && asset.mesh_check_indices(view) && assets_collision_stored(view)!=.None
}

// The convex pieces of a mesh file that stores no colliders, kept in a folder
// of the cache (App.collision_cache) by the content of the file: a file of
// this kind and version, whose id is its key.
COLLISION_PIECES_KIND :: asset.Fourcc(u32('P')|u32('C')<<8|u32('E')<<16|u32('S')<<24)
COLLISION_PIECES_VERSION :: 1 // raise it when assets_collision_pieces_file gives other pieces for the same mesh
COLLISION_PIECES_EXTENSION :: ".pieces"

// Appends the convex pieces that a moving body of a mesh file without
// colliders of its source collides as: a decomposition of the triangles of
// its finest level (geom.mesh_decompose). points receives the points of each
// piece one after another, in mesh space, and sizes how many each has. The
// first time it decomposes, and keeps the pieces in folder ("" keeps them
// nowhere); then it reads them from there. False, with both as they were,
// for a mesh that stores colliders or of which no piece can be made.
assets_collision_pieces_file :: proc(file:^asset.Asset,types:^asset.Types,folder:string,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32) -> bool {
    if points==nil || sizes==nil {return false}
    view,error:=asset.mesh_view(file,types)
    if error!=.None || !asset.mesh_check_indices(view) || assets_collision_stored(view)!=.None {return false}
    held_points,held_sizes:=len(points),len(sizes)
    key:=base.hash_combine(file.blob.header.content_hash,u64(COLLISION_PIECES_VERSION)<<16|u64(asset.MESH_VERSION))|1
    id:=base.Asset_Id{key,u64(COLLISION_PIECES_VERSION)}
    path:=folder!=""?fmt.tprintf("%s/%016x%s",folder,key,COLLISION_PIECES_EXTENSION):""
    if path!="" {
        cached:asset.Asset
        if asset.asset_load(&cached,path,context.temp_allocator)==.None {
            defer asset.asset_close(&cached)
            header:=cached.blob.header
            if header.kind==COLLISION_PIECES_KIND && header.kind_version==COLLISION_PIECES_VERSION && header.id==id && asset.blob_verify_hash(&cached.blob) {
                kept_points,points_error:=asset.asset_rows(&cached,types,"points","",[3]f32)
                kept_sizes,sizes_error:=asset.asset_rows(&cached,types,"sizes","",u32)
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
    surface:geom.Mesh_Buffer
    geom.mesh_buffer_init(&surface,context.temp_allocator)
    made_points:=make([dynamic][3]f32,context.temp_allocator)
    made_sizes:=make([dynamic]u32,context.temp_allocator)
    if geometry_of_view(view,&surface) {
        weld:=make([]u32,len(surface.positions),context.temp_allocator)
        geom.positions_weld(surface.positions[:],0,weld)
        row:=make([]u32,len(surface.positions),context.temp_allocator)
        welded:=make([dynamic]geom.Vec3,0,len(surface.positions),context.temp_allocator)
        for representative,at in weld {
            if int(representative)==at {
                row[at]=u32(len(welded))
                append(&welded,surface.positions[at])
            }
        }
        triangles:=make([dynamic]u32,0,len(surface.indices),context.temp_allocator)
        for t in 0..<len(surface.indices)/3 {
            a,b,c:=row[weld[surface.indices[t*3]]],row[weld[surface.indices[t*3+1]]],row[weld[surface.indices[t*3+2]]]
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
    if path!="" && (os.is_dir(folder) || os.make_directory_all(folder)==nil) {
        doc:asset.Document
        asset.document_init(&doc,COLLISION_PIECES_KIND,id,context.temp_allocator)
        doc.kind_version=COLLISION_PIECES_VERSION
        _,points_error:=asset.document_put(&doc,types,"points",made_points[:])
        _,sizes_error:=asset.document_put(&doc,types,"sizes",made_sizes[:])
        if points_error==.None && sizes_error==.None {
            if bytes,bytes_error:=asset.document_bytes(&doc,context.temp_allocator);bytes_error==.None {_=serial.file_write_atomic(path,bytes)}
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

COLLIDER_SHAPE_SEGMENTS :: 12

// Appends the convex pieces a Hull collider of what a Mesh_Renderer shows is
// made of, each a hull of its own: those a generated mesh was given
// (Mesh_Generate_Options.hull_points), or the shapes a mesh asset stores
// without a collision mesh. points receives the points of every piece one
// after another, in mesh space, and sizes how many each has. False, with both
// as they were, when the mesh has no pieces: the collider is then one hull of
// what assets_collision gives.
assets_collision_hulls :: proc(a:^Assets,mesh:base.Asset_Id,shape:Shape,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32) -> bool {
    if a==nil || mesh=={} || points==nil || sizes==nil {return false}
    held_points,held_sizes:=len(points),len(sizes)
    defer if len(sizes)==held_sizes {
        base.truncate(points,held_points)
    }
    if assets_mesh_generated(a,mesh) {
        entry:=&a.meshes[a.index[mesh].index]
        if len(entry.hull_sizes)==0 {return false}
        if append(points,..entry.hull_points)!=len(entry.hull_points) || append(sizes,..entry.hull_sizes)!=len(entry.hull_sizes) {
            base.truncate(sizes,held_sizes)
            return false
        }
        return true
    }
    file:asset.Asset
    if _,_,opened:=assets_open(a,mesh,.Mesh,&file);!opened {return false}
    defer asset.asset_close(&file)
    return assets_collision_hulls_file(&file,&a.types,points,sizes)
}

// assets_collision_hulls of the open file of a mesh asset, on any thread with
// types of its own.
assets_collision_hulls_file :: proc(file:^asset.Asset,types:^asset.Types,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32) -> bool {
    if points==nil || sizes==nil {return false}
    held_points,held_sizes:=len(points),len(sizes)
    defer if len(sizes)==held_sizes {
        base.truncate(points,held_points)
    }
    view,error:=asset.mesh_view(file,types)
    if error!=.None || !asset.mesh_check_indices(view) {return false}
    for collider in view.colliders {
        if collider.kind==.Mesh && collider.index_count>0 {return false}
    }
    for collider in view.colliders {
        if collider.kind==.Mesh || collider.kind==.Hull && collider.point_count<3 {continue}
        from:=len(points)
        collider_points(view,collider,points)
        made:=len(points)-from
        valid:=made>=3
        for point in points[from:] {
            for value in point {valid=valid && value-value==0}
        }
        if !valid || append(sizes,u32(made))!=1 {
            base.truncate(sizes,held_sizes)
            return false
        }
    }
    return len(sizes)>held_sizes
}

// The points a stored collider other than a collision mesh is the hull of.
@(private="file")
collider_points :: proc(view:asset.Mesh_View,collider:asset.Collider,out:^[dynamic]geom.Vec3) {
    place :: proc(collider:asset.Collider,out:^[dynamic]geom.Vec3,from:int) {
        for &point in out[from:] {point=collider.center+mm.quat_rotate(collider.rotation,point)}
    }
    from:=len(out)
    switch collider.kind {
    case .Hull: append(out,..view.collision_points[collider.first_point:][:collider.point_count])
    case .Box:
        for corner in 0..<8 {
            append(out,collider.size*{corner&1!=0?1:-1,corner&2!=0?1:-1,corner&4!=0?1:-1})
        }
        place(collider,out,from)
    case .Sphere,.Capsule:
        shape:geom.Mesh_Buffer
        geom.mesh_buffer_init(&shape,context.temp_allocator)
        radius:=collider.size.x
        if collider.kind==.Sphere {
            geom.sphere_build(&shape,radius,COLLIDER_SHAPE_SEGMENTS,COLLIDER_SHAPE_SEGMENTS/2)
        } else {
            geom.capsule_build(&shape,radius,2*(collider.size.y+radius),COLLIDER_SHAPE_SEGMENTS,COLLIDER_SHAPE_SEGMENTS/4)
        }
        append(out,..shape.positions[:])
        place(collider,out,from)
    case .Mesh:
    }
}
