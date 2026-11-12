package physics

import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

collision_edge_active :: proc "contextless" (normal,a,b,opposite:[3]f32) -> bool {
    return sim.mesh_edge_active(normal,a,b,opposite)
}

@(private)
mesh_geometry_equal :: proc(a,b:sim.Mesh) -> bool {
    return sliced_equal(a.vertices,b.vertices) && sliced_equal(a.triangles,b.triangles) && sliced_equal(a.flags,b.flags)
}

// Whether the shape of a Mesh or Heightfield collider is what it would make now, where it would put it.
@(private)
collider_geometry_unchanged :: proc(s:^Sync,l:^Link,e:core.Entity,collider:Collider,scale:[3]f32,relative:=mm.TRANSFORM_IDENTITY) -> bool {
    static,_:=core.get(s.statics,e)
    w:=&s.state.world
    origin:=collider.center*scale
    #partial switch collider.kind {
    case .Mesh:
        actual:=sim.mesh_geometry(w,l.mesh)
        built:=mesh_cached(s.app,s.meshes,static.mesh,static.shape,scale)
        if actual==nil || built==nil || !mesh_geometry_equal(actual^,built^) {return false}
    case .Heightfield:
        actual:=sim.heightfield_geometry(w,l.heightfield)
        field,found:=host.assets_heightfield(s.app.assets,static.mesh)
        if actual==nil || !found || actual.columns!=field.columns || actual.rows!=field.rows || actual.cell!=field.cell*scale || !sliced_equal(actual.heights,field.heights) || !sliced_equal(actual.disabled_borders,field.disabled_borders) || !sliced_equal(actual.holes,field.holes) {return false}
        origin+=field.origin*scale
    case:
        return false
    }
    return !pose_differs(sim.shape_local_transform(w,l.shape),{relative.position+mm.quat_rotate(relative.rotation,origin),relative.rotation})
}

// The convex radius of a collider at the scale of its entity: the smallest axis of the scale shrinks it.
@(private)
collider_round :: proc "contextless" (collider:Collider,scale:[3]f32) -> f32 {
    return collider.convex_radius*min(abs(scale.x),abs(scale.y),abs(scale.z))
}

// Whether a scale mirrors: an odd number of negative axes turns a surface inside out.
@(private)
inside_out :: proc "contextless" (scale:[3]f32) -> bool {return ((scale.x<0)!=(scale.y<0))!=(scale.z<0)}

// Whether the rounding of a collider leaves its shape a core: below the smallest half extent of a box and the
// radius and half height of a cylinder at the scale of the entity. A hull finds out when it is built.
@(private)
collider_round_fits :: proc "contextless" (collider:Collider,scale:[3]f32) -> bool {
    round:=collider_round(collider,scale)
    if !(round>=0 && round<max(f32)) {return false}
    if round==0 {return true}
    smallest:=max(f32)
    size:=collider.size*linalg.abs(scale)
    #partial switch collider.kind {
    case .Box:
        smallest=min(size.x,size.y,size.z)
    case .Cylinder:
        smallest=min(collider.size.x*max(abs(scale.x),abs(scale.z)),size.y)
    }
    // A shape without size is refused as such, not for its rounding.
    return !(smallest>0) || round<smallest
}

// The triangles of what a Mesh_Renderer shows at a scale, built for the
// simulation. The application builds each one once and every world that needs
// it copies it into its simulation.
@(storage,host,free="collider_meshes_destroy")
Collider_Meshes :: struct {
    entries:[dynamic]Collider_Mesh,
    built:u64,
    structure:u64,
}

@(private)
Collider_Mesh :: struct {
    mesh:base.Asset_Id,
    shape:host.Shape,
    scale:[3]f32,
    size,time:i64, // of the file of the mesh when it was read
    generated:bool,
    built:sim.Mesh,
}

@(private)
collider_meshes_prune :: proc(meshes:^Collider_Meshes,assets:^host.Assets) {
    structure:=assets!=nil?assets.structure:0
    if meshes.structure==structure {return}
    meshes.structure=structure
    for index:=len(meshes.entries)-1;index>=0;index-=1 {
        entry:=&meshes.entries[index]
        if !entry.generated || host.assets_mesh_generated(assets,entry.mesh) {continue}
        sim.mesh_release(&entry.built,context.allocator)
        ordered_remove(&meshes.entries,index)
    }
}

// Frees the meshes. The generated world has no destructor for a storage, so whoever owns the application calls it.
collider_meshes_destroy :: proc(meshes:^Collider_Meshes) {
    for &entry in meshes.entries {sim.mesh_release(&entry.built,context.allocator)}
    delete(meshes.entries)
    meshes^={}
}

// The built mesh of a collider, made now when the application does not have
// it or its file changed. nil when it cannot be made: the caller builds one of its own.
@(private)
mesh_cached :: proc(app:^host.App,meshes:^Collider_Meshes,mesh:base.Asset_Id,shape:host.Shape,scale:[3]f32) -> ^sim.Mesh {
    size,time:i64
    generated:=host.assets_mesh_generated(app.assets,mesh)
    if mesh!={} {
        if app.assets==nil {return nil}
        if !generated {
            file,found:=asset.registry_find(&app.assets.registry,mesh)
            if !found {return nil}
            size,time=file.size,file.time
        }
    }
    shape:=mesh=={}?shape:host.Shape.None
    entry:^Collider_Mesh
    for &known in meshes.entries {
        if known.mesh!=mesh || known.shape!=shape || known.scale!=scale {continue}
        if known.size==size && known.time==time {return known.built.triangles!=nil?&known.built:nil}
        sim.mesh_release(&known.built,context.allocator)
        entry=&known
        break
    }
    if entry==nil {
        if append(&meshes.entries,Collider_Mesh{})!=1 {return nil}
        entry=&meshes.entries[len(meshes.entries)-1]
    }
    entry^={mesh=mesh,shape=shape,scale=scale,size=size,time=time,generated=generated}
    building:=host.load_phase_begin(app,.Collision,host.LOAD_NO_ZONE)
    defer host.load_phase_end(app,building,1)
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer,context.temp_allocator)
    _,found:=host.assets_collision(app.assets,mesh,shape,.Mesh,&buffer)
    for &position in buffer.positions {position*=scale}
    disabled:=host.assets_mesh_disabled_edges(app.assets,mesh)
    if !found || !sim.mesh_build(&entry.built,{buffer.positions[:],buffer.indices[:],disabled,inside_out(scale)},context.allocator) {
        // Kept empty: what cannot be built is not tried again for every entity that shows it.
        entry.built={}
        return nil
    }
    meshes.built+=1
    return &entry.built
}

// What a slot of geometry of the simulation was made from. Colliders made from the same (kind, mesh or
// shape, scale and rounding, of the same file) share the slot: the simulation counts the shapes that use
// it and frees it with the last one. Plain data in Physics_State, copied with the simulation.
@(private)
Geometry_Source :: struct {
    generation:u32, // of the slot it was made in; another generation: the slot holds something else
    kind:Collider_Kind,
    shape:host.Shape,
    mesh:base.Asset_Id,
    scale:[3]f32,
    round:f32,
    size,time:i64, // of the file of the mesh, as Collider_Mesh; zero for a generated one
    piece:u32, // of a hull made of convex pieces, from 1; 0 for the whole collider
}

@(private)
geometry_source_same :: proc "contextless" (a,b:Geometry_Source) -> bool {
    return a.kind==b.kind && a.shape==b.shape && a.mesh==b.mesh && a.scale==b.scale && a.round==b.round && a.size==b.size && a.time==b.time && a.piece==b.piece
}

// What the geometry of a collider is made from. False when the file of its mesh is unknown: then it is not
// shared.
@(private)
geometry_source_of :: proc(assets:^host.Assets,kind:Collider_Kind,static:render.Mesh_Renderer,scale:[3]f32,round:f32) -> (source:Geometry_Source,ok:bool) {
    source={kind=kind,shape=static.mesh=={}?static.shape:.None,mesh=static.mesh,scale=scale,round=round}
    if static.mesh!={} && !host.assets_mesh_generated(assets,static.mesh) {
        if assets==nil {return}
        file,found:=asset.registry_find(&assets.registry,static.mesh)
        if !found {return}
        source.size,source.time=file.size,file.time
    }
    return source,true
}

// A live slot made from the same source: hulls, then meshes (a flat hull is one), then heightfields, in the
// order of Physics_State.geometry.
@(private)
geometry_shared :: proc(state:^Physics_State,source:Geometry_Source) -> (geometry:sim.Geometry,ok:bool) {
    w:=&state.world
    hulls,meshes:=len(w.hulls),len(w.meshes)
    for &known,at in state.sources {
        if known.generation==0 || !geometry_source_same(known,source) {continue}
        switch {
        case at<hulls:
            if w.hulls[at].generation!=known.generation {continue}
            return sim.Hull_Handle(base.handle_make(u32(at),known.generation)),true
        case at<hulls+meshes:
            if w.meshes[at-hulls].generation!=known.generation {continue}
            return sim.Mesh_Handle(base.handle_make(u32(at-hulls),known.generation)),true
        case:
            if w.heightfields[at-hulls-meshes].generation!=known.generation {continue}
            return sim.Heightfield_Handle(base.handle_make(u32(at-hulls-meshes),known.generation)),true
        }
    }
    return
}

// Writes down what a slot was made from. Without memory the slot is only not shared.
@(private)
geometry_remember :: proc(state:^Physics_State,geometry:sim.Geometry,source:Geometry_Source) {
    w:=&state.world
    total:=len(w.hulls)+len(w.meshes)+len(w.heightfields)
    if len(state.sources)!=total && (resize(&state.sources,total)!=nil || resize(&state.source_stamps,base.chunks_of(total))!=nil) {return}
    at:=-1
    handle:base.Handle
    #partial switch g in geometry {
    case sim.Hull_Handle:        handle=base.Handle(g);at=int(base.handle_index(handle))
    case sim.Mesh_Handle:        handle=base.Handle(g);at=len(w.hulls)+int(base.handle_index(handle))
    case sim.Heightfield_Handle: handle=base.Handle(g);at=len(w.hulls)+len(w.meshes)+int(base.handle_index(handle))
    }
    if handle=={} || at<0 || at>=total {return}
    known:=source
    known.generation=base.handle_generation(handle)
    state.sources[at]=known
    slot_stamp(state,state.source_stamps[:],at)
}

// Collision geometry of the Mesh_Renderer, scaled and copied into the simulation; a hull rounded by
// `round`. A collider made from what another one already has takes its slot.
@(private)
collider_geometry :: proc(s:^Sync,l:^Link,kind:Collider_Kind,e:core.Entity,scale:[3]f32,round:f32) -> (geometry:sim.Geometry,origin:[3]f32,failure:Shape_Failure) {
    static,has_mesh:=core.get(s.statics,e)
    if !has_mesh {return {},{},.No_Mesh}
    source,shareable:=geometry_source_of(s.app.assets,kind,static,scale,round)
    if kind==.Heightfield {
        field,found:=host.assets_heightfield(s.app.assets,static.mesh)
        if !found {return {},{},.No_Heightfield}
        if scale.x<0 || scale.y<0 || scale.z<0 {return {},{},.Mirrored_Heightfield}
        origin=field.origin*scale
        for value in origin {if value-value!=0 {return {},{},.No_Heightfield}}
    }
    if shareable {
        if shared,found:=geometry_shared(s.state,source);found {
            #partial switch g in shared {
            case sim.Hull_Handle:        l.hull=g
            case sim.Mesh_Handle:        l.mesh=g
            case sim.Heightfield_Handle: l.heightfield=g
            }
            return shared,origin,.None
        }
    }
    geometry,failure=collider_geometry_make(s,l,kind,static,scale,round)
    if failure==.None && shareable {geometry_remember(s.state,geometry,source)}
    return geometry,origin,failure
}

// Makes the hulls of a Hull collider whose mesh has several convex pieces, or of the sensor of an outline
// (zone_collider): the first in l.hull, the others in a run of Physics_State.pieces, each of a mesh shared as
// a whole collider is. pieces is false when the mesh has fewer than two: the collider is then one hull of all
// its points. On a failure the caller releases what was made.
@(private)
collider_pieces_make :: proc(s:^Sync,l:^Link,e:core.Entity,scale:[3]f32,round:f32) -> (pieces:bool,failure:Shape_Failure) {
    points:=make([dynamic]geom.Vec3,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    static,has_mesh:=core.get(s.statics,e)
    source:Geometry_Source
    shareable:=false
    // A Hull without a Collider is the sensor of an outline zone (zone_collider).
    if !core.has(s.colliders,e) {
        zone,_:=core.get(s.volumes,e)
        if !zone_pieces(volume.spline_outline(s.splines,e),zone.extents.y,&points,&sizes) {return true,.Hull}
    } else {
        if !has_mesh || !host.assets_collision_hulls(s.app.assets,static.mesh,static.shape,&points,&sizes) || len(sizes)<2 {return}
        source,shareable=geometry_source_of(s.app.assets,.Hull,static,scale,round)
    }
    run,taken:=pieces_take(s.state,len(sizes)-1)
    if !taken {return true,.Geometry_Budget}
    l.pieces=run
    from:=0
    for size,at in sizes {
        if int(size)>len(points)-from {return true,.Hull}
        piece:=points[from:][:size]
        from+=int(size)
        source.piece=u32(at+1)
        hull:sim.Hull_Handle
        if shareable {
            if shared,found:=geometry_shared(s.state,source);found {hull,_=shared.(sim.Hull_Handle)}
        }
        if hull=={} {
            for &point in piece {point*=scale}
            made:sim.Geometry
            if made,failure=hull_make(&s.state.world,piece,round);failure!=.None {return true,failure}
            solid:bool
            if hull,solid=made.(sim.Hull_Handle);!solid {
                // A piece without volume is not a part of a body.
                if mesh,is_mesh:=made.(sim.Mesh_Handle);is_mesh {sim.mesh_destroy(&s.state.world,mesh)}
                return true,.Hull
            }
            if shareable {geometry_remember(s.state,hull,source)}
        }
        if at==0 {l.hull=hull} else {s.state.pieces[run.first+u32(at)-1].hull=hull}
    }
    return true,.None
}

// A free run of count entries of Physics_State.pieces, made at the end when none is.
@(private)
pieces_take :: proc(state:^Physics_State,count:int) -> (run:Piece_Run,ok:bool) {
    if count<=0 {return {},true}
    free:=0
    for piece,at in state.pieces {
        if piece!={} {free=0;continue}
        free+=1
        if free==count {return {u32(at+1-count),u32(count)},true}
    }
    first:=len(state.pieces)-free
    if first+count>int(max(u32)) || resize(&state.pieces,first+count)!=nil {return}
    return {u32(first),u32(count)},true
}

// The pieces after the first of a link; none when its run is not one of the state.
@(private)
pieces_of :: proc "contextless" (state:^Physics_State,l:^Link) -> []Piece {
    first,count:=int(l.pieces.first),int(l.pieces.count)
    if count==0 || first>len(state.pieces)-count {return nil}
    return state.pieces[first:][:count]
}

// Makes the geometry of a collider in a slot of its own.
@(private)
collider_geometry_make :: proc(s:^Sync,l:^Link,kind:Collider_Kind,static:render.Mesh_Renderer,scale:[3]f32,round:f32) -> (geometry:sim.Geometry,failure:Shape_Failure) {
    w:=&s.state.world
    made:bool
    if kind==.Heightfield {
        field,_:=host.assets_heightfield(s.app.assets,static.mesh)
        l.heightfield,made=sim.heightfield_create(w,{field.heights,field.columns,field.rows,field.cell*scale,field.disabled_borders,field.holes})
        if !made {return {},.Geometry_Budget}
        return l.heightfield,.None
    }
    if kind==.Mesh {
        if built:=mesh_cached(s.app,s.meshes,static.mesh,static.shape,scale);built!=nil {
            l.mesh,made=sim.mesh_create_copy(w,built)
            if !made {return {},.Geometry_Budget}
            return l.mesh,.None
        }
    }
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer,context.temp_allocator)
    if _,found:=host.assets_collision(s.app.assets,static.mesh,static.shape,kind==.Mesh?.Mesh:.Hull,&buffer);!found {return {},.No_Geometry}
    for &position in buffer.positions {position*=scale}
    if kind==.Mesh {
        l.mesh,made=sim.mesh_create(w,{buffer.positions[:],buffer.indices[:],host.assets_mesh_disabled_edges(s.app.assets,static.mesh),inside_out(scale)})
        if !made {return {},.Geometry_Budget}
        return l.mesh,.None
    }
    geometry,failure=hull_make(w,buffer.positions[:],round)
    #partial switch g in geometry {
    case sim.Hull_Handle: l.hull=g
    case sim.Mesh_Handle: l.mesh=g
    }
    return
}

// The hull of points in a slot of its own, rounded by round; a flat one is a mesh of its polygon.
@(private)
hull_make :: proc(w:^sim.World,points:[]geom.Vec3,round:f32) -> (geometry:sim.Geometry,failure:Shape_Failure) {
    made:bool
    built,error:=geom.hull_build(points,{max_vertices=COLLIDER_HULL_VERTICES},context.temp_allocator)
    if error!=.None {return {},.Hull}
    if geom.hull_is_flat(built) {
        // A polygon has no volume: it collides as a mesh of its triangles and adds no mass.
        triangles:[3*(COLLIDER_HULL_VERTICES-2)]u32
        corners:=len(built.vertices)
        for i in 1..<corners-1 {triangles[3*(i-1)+1],triangles[3*(i-1)+2]=u32(i),u32(i+1)}
        mesh:sim.Mesh_Handle
        mesh,made=sim.mesh_create(w,{vertices=built.vertices,indices=triangles[:3*(corners-2)]})
        if !made {return {},.Geometry_Budget}
        return mesh,.None
    }
    if len(built.vertices)>255 || len(built.faces)>255 || len(built.face_vertices)>255 {return {},.Hull}
    counts:[255]u8
    indices:[255]u8
    used:=0
    for face,at in built.faces {
        counts[at]=u8(face.vertex_count)
        for vertex in built.face_vertices[face.first_vertex:][:face.vertex_count] {
            indices[used]=u8(vertex)
            used+=1
        }
    }
    desc:=sim.Hull_Desc{built.vertices,counts[:len(built.faces)],indices[:used]}
    hull:sim.Hull_Handle
    hull,made=sim.hull_create(w,desc,round)
    if !made && round>0 {
        // Without the rounding it builds: the radius leaves it no core.
        if sharp,built_sharp:=sim.hull_create(w,desc);built_sharp {
            sim.hull_destroy(w,sharp)
            return {},.Convex_Radius
        }
    }
    if !made {return {},.Geometry_Budget}
    return hull,.None
}

// Releases geometry after its shape is gone: the slot goes with the last shape that uses it, and stays for
// the others.
@(private)
geometry_release :: proc(s:^Sync,l:^Link) {
    w:=&s.state.world
    if l.hull!={} {sim.hull_destroy(w,l.hull)}
    if l.mesh!={} {sim.mesh_destroy(w,l.mesh)}
    if l.heightfield!={} {sim.heightfield_destroy(w,l.heightfield)}
    for &piece in pieces_of(s.state,l) {
        if piece.hull!={} {sim.hull_destroy(w,piece.hull)}
        piece={}
    }
    l.hull,l.mesh={},{}
    l.heightfield={}
    l.pieces={}
}



// The convex pieces of the column over an outline (geom.polygon_convex_partition), each from half under the
// loop to half over it, as the points of their hulls in the frame of the entity. False for a loop that
// does not split.
@(private)
zone_pieces :: proc(outline:[]mm.Path_Point,half:f32,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32) -> bool {
    loop:=make([]geom.Vec2,len(outline),context.temp_allocator)
    for p,i in outline {loop[i]={p.position.x,p.position.z}}
    indices:=make([dynamic]u32,context.temp_allocator)
    counts:=make([dynamic]u32,context.temp_allocator)
    if geom.polygon_convex_partition(loop,{len(loop)},&indices,&counts)<=0 {return false}
    first:=0
    for count in counts {
        for index in indices[first:][:count] {
            p:=loop[index]
            append(points,geom.Vec3{p.x,-half,p.y},geom.Vec3{p.x,half,p.y})
        }
        append(sizes,2*count)
        first+=int(count)
    }
    return true
}
