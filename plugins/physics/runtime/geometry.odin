package physics

import "base:intrinsics"
import "base:runtime"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"
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
        built,_:=mesh_cached(s,static.mesh,static.shape,scale)
        if actual==nil || built==nil || !mesh_geometry_equal(actual^,built^) {return false}
    case .Heightfield:
        actual:=sim.heightfield_geometry(w,l.heightfield)
        field,found:=host.assets_heightfield(s.app.assets,static.mesh)
        if actual==nil || !found || actual.columns!=field.columns || actual.rows!=field.rows || actual.cell!=field.cell*scale || !sliced_equal(actual.heights,field.heights) || !sliced_equal(actual.disabled_borders,field.disabled_borders) || !sliced_equal(actual.holes,field.holes) {return false}
        if !sliced_equal(actual.surfaces,heightfield_surfaces(field)) || !sliced_equal(actual.cell_surfaces,field.surfaces) {return false}
        origin+=field.origin*scale
    case:
        return false
    }
    return !pose_differs(sim.shape_local_transform(w,l.shape),{relative.position+mm.quat_rotate(relative.rotation,origin),relative.rotation})
}

// The surfaces of the simulation are the materials of the cells: the material is what a hit names.
@(private)
heightfield_surfaces :: proc "contextless" (field:host.Assets_Heightfield) -> []sim.Surface {
    return transmute([]sim.Surface)field.materials
}
#assert(size_of(sim.Surface)==size_of(base.Asset_Id))

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

// What colliders are made from, shared by every world of the application:
// the collision a mesh file gives each kind of collider (Hull or Mesh, and
// the convex pieces of an Auto one that moves), read once, and the trees of
// Mesh colliders at each scale. The libraries whose owned bodies collide as
// meshes (foliage) ask it too (owned_hulls). A file is read and its
// trees are built in jobs (a tick reads no file and builds no tree of a file):
// the bodies that wait for them are made in a later tick. What a generated
// mesh or a primitive gives comes from memory, in the tick that asks.
// Plain shared data: no world holds it, so a rollback or a copy reads the
// same; a tick that resimulates waits for the job instead of waiting a tick.
@(storage,host,shared,free="collider_meshes_destroy")
Collider_Meshes :: struct {
    entries:map[Collider_Mesh_Key]^Collider_Mesh,
    files:map[Mesh_File_Key]^Mesh_File,
    built:u64,
    structure:u64,
    js:^jobs.Job_System, // of the jobs it started
    counter:jobs.Counter,
}

@(private)
Collider_Mesh_Key :: struct {
    mesh:base.Asset_Id,
    shape:host.Shape,
    scale:[3]f32,
}

@(private)
Collider_Mesh :: struct {
    scale:[3]f32,
    size,time:i64, // of the file of the mesh when it was read
    generated:bool,
    from:^Mesh_File, // of a mesh file: what its job builds from
    ready:bool,      // built: written by its job
    built:sim.Mesh,
    allocator:mem.Allocator,
}

@(private)
Mesh_File_Key :: struct {
    mesh:base.Asset_Id,
    kind:host.Collision, // Hull or Mesh
    decomposed:bool,     // of a Hull: the pieces of assets_collision_pieces_file
}

// The collision of a mesh file for a kind of collider, as assets_collision and
// assets_collision_hulls give it, unscaled; decomposed, the convex pieces of
// assets_collision_pieces_file instead.
@(private)
Mesh_File :: struct {
    size,time:i64, // of the file when it was asked for
    kind:host.Collision,
    decomposed:bool,
    cache:string, // App.collision_cache, of a decomposed one
    source:host.Assets_Source,
    ready:bool, // the job is done: written by it
    stored:host.Stored_Collision, // what the file stores of the colliders of its source
    found:bool, // geometry holds what assets_collision gives
    geometry:geom.Mesh_Buffer,
    pieces:bool, // a Hull: piece_points and piece_sizes hold the convex pieces of assets_collision_hulls, or of assets_collision_pieces_file when decomposed
    piece_points:[dynamic]geom.Vec3,
    piece_sizes:[dynamic]u32,
}

@(private)
collider_meshes_prune :: proc(meshes:^Collider_Meshes,assets:^host.Assets) {
    structure:=assets!=nil?assets.structure:0
    if meshes.structure==structure {return}
    meshes.structure=structure
    gone:=make([dynamic]Collider_Mesh_Key,context.temp_allocator)
    for key,entry in meshes.entries {
        if entry.generated && !host.assets_mesh_generated(assets,key.mesh) {append(&gone,key)}
    }
    for key in gone {
        collider_mesh_free(meshes.entries[key])
        delete_key(&meshes.entries,key)
    }
}

// Frees the meshes, once the jobs under way end. The generated world has no destructor for a storage, so
// whoever owns the application calls it.
collider_meshes_destroy :: proc(meshes:^Collider_Meshes) {
    if meshes.js!=nil && jobs.pending(&meshes.counter) {jobs.wait(meshes.js,jobs.OWNER,&meshes.counter)}
    for _,entry in meshes.entries {collider_mesh_free(entry)}
    for _,file in meshes.files {mesh_file_free(file)}
    delete(meshes.entries)
    delete(meshes.files)
    meshes^={}
}

@(private="file")
collider_mesh_free :: proc(entry:^Collider_Mesh) {
    sim.mesh_release(&entry.built,entry.allocator)
    free(entry,runtime.heap_allocator())
}

@(private="file")
mesh_file_free :: proc(file:^Mesh_File) {
    host.assets_source_free(&file.source)
    delete(file.cache,runtime.heap_allocator())
    geom.mesh_buffer_destroy(&file.geometry)
    delete(file.piece_points)
    delete(file.piece_sizes)
    free(file,runtime.heap_allocator())
}

// The size and time of the file of a mesh asset; false for one that is not a file: a generated mesh, a
// primitive or an id the registry does not have.
@(private)
mesh_file_version :: proc(app:^host.App,mesh:base.Asset_Id) -> (size,time:i64,ok:bool) {
    if app==nil || app.assets==nil || mesh=={} || host.assets_mesh_generated(app.assets,mesh) {return}
    file:=asset.registry_find(&app.assets.registry,mesh) or_return
    return file.size,file.time,true
}

// Whether a job runs where it is asked for: without job threads, and while the tick resimulates.
@(private="file")
jobs_inline :: proc(s:^Sync) -> bool {return s.resimulating || jobs.worker_count(&s.app.jobs)<=1}

// The collision a mesh file gives a kind of collider, read in a job the first
// time and again when its file changes. waiting: the job has not ended; nil
// without waiting when it is no file or cannot be read.
@(private)
mesh_file :: proc(s:^Sync,mesh:base.Asset_Id,kind:host.Collision,decomposed:=false) -> (file:^Mesh_File,waiting:bool) {
    return mesh_file_of(s.meshes,s.app,jobs_inline(s),mesh,kind,decomposed)
}

// mesh_file for whoever steps without a Sync; inline: the job runs where it is asked for.
@(private)
mesh_file_of :: proc(meshes:^Collider_Meshes,app:^host.App,inline:bool,mesh:base.Asset_Id,kind:host.Collision,decomposed:bool) -> (file:^Mesh_File,waiting:bool) {
    if meshes==nil || app==nil {return}
    size,time,is_file:=mesh_file_version(app,mesh)
    if !is_file {return}
    key:=Mesh_File_Key{mesh,kind,decomposed}
    if known,found:=meshes.files[key];found {
        if !intrinsics.atomic_load(&known.ready) {
            if !inline {return nil,true}
            jobs.wait(meshes.js,jobs.OWNER,&meshes.counter)
        }
        if known.size==size && known.time==time {return known,false}
        // A tree may still be built from it.
        if jobs.pending(&meshes.counter) {
            if !inline {return nil,true}
            jobs.wait(meshes.js,jobs.OWNER,&meshes.counter)
        }
        mesh_file_free(known)
        delete_key(&meshes.files,key)
    }
    made,error:=new(Mesh_File,runtime.heap_allocator())
    if error!=nil {return}
    made.size,made.time,made.kind,made.decomposed=size,time,kind,decomposed
    if decomposed {
        cloned:runtime.Allocator_Error
        if made.cache,cloned=strings.clone(app.collision_cache,runtime.heap_allocator());cloned!=nil {
            free(made,runtime.heap_allocator())
            return
        }
    }
    source,found:=host.assets_source(app.assets,mesh,runtime.heap_allocator())
    if !found {
        delete(made.cache,runtime.heap_allocator())
        free(made,runtime.heap_allocator())
        return
    }
    made.source=source
    if _,error=map_insert(&meshes.files,key,made);error!=nil {
        mesh_file_free(made)
        return
    }
    if inline {
        mesh_file_read(made,jobs.OWNER)
        return made,false
    }
    meshes.js=&app.jobs
    jobs.run(meshes.js,jobs.OWNER,.Background,mesh_file_read,made,&meshes.counter)
    return nil,true
}

// A job: reads the collision of a mesh file.
@(private="file")
mesh_file_read :: proc(file:^Mesh_File,worker:int) {
    context.allocator=runtime.heap_allocator()
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    defer intrinsics.atomic_store(&file.ready,true)
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    opened:asset.Asset
    if host.assets_source_open(&file.source,&opened)!=.None {return}
    defer asset.asset_close(&opened)
    if view,error:=asset.mesh_view(&opened,&types);error==.None {file.stored=host.assets_collision_stored(view)}
    geom.mesh_buffer_init(&file.geometry)
    if file.decomposed {
        file.piece_points=make([dynamic]geom.Vec3)
        file.piece_sizes=make([dynamic]u32)
        file.pieces=host.assets_collision_pieces_file(&opened,&types,file.cache,&file.piece_points,&file.piece_sizes)
        return
    }
    _,file.found=host.assets_collision_file(&opened,&types,file.kind,&file.geometry)
    // A Hull keeps only the points its hull is made of: any scale maps the
    // hull of the points to the hull of the scaled points, and the tick that
    // builds it at a scale goes through fewer.
    if file.kind==.Hull && file.found {
        // Without memory for it, every point stays.
        if hull,error:=geom.hull_build(file.geometry.positions[:],{},context.temp_allocator);error==.None && !geom.hull_is_flat(hull) {
            if kept,no_memory:=make([dynamic]geom.Vec3,0,len(hull.sources));no_memory==nil {
                for source in hull.sources {append(&kept,file.geometry.positions[source])}
                delete(file.geometry.positions)
                file.geometry.positions=kept
            }
        }
    }
    if file.kind==.Hull {
        file.piece_points=make([dynamic]geom.Vec3)
        file.piece_sizes=make([dynamic]u32)
        file.pieces=host.assets_collision_hulls_file(&opened,&types,&file.piece_points,&file.piece_sizes)
    }
}

// Appends the geometry a collider of one kind is made of, as host.assets_collision gives it: of a mesh
// file, what its job read. False when there is none, or its file is still being read.
@(private)
collision_geometry :: proc(s:^Sync,mesh:base.Asset_Id,shape:host.Shape,kind:host.Collision,buffer:^geom.Mesh_Buffer) -> bool {
    file,waiting:=mesh_file(s,mesh,kind)
    if waiting {return false}
    if file==nil {
        _,found:=host.assets_collision(s.app.assets,mesh,shape,kind,buffer)
        return found
    }
    if !file.found {return false}
    first:=u32(len(buffer.positions))
    if append(&buffer.positions,..file.geometry.positions[:])!=len(file.geometry.positions) || reserve(&buffer.indices,len(buffer.indices)+len(file.geometry.indices))!=nil {return false}
    for index in file.geometry.indices {append(&buffer.indices,first+index)}
    return true
}

// Appends the convex pieces of a Hull collider, as host.assets_collision_hulls gives them, or decomposed,
// as host.assets_collision_pieces_file does: of a mesh file, what its job read. False when it has none, or
// its file is still being read.
@(private)
collision_hulls :: proc(s:^Sync,mesh:base.Asset_Id,shape:host.Shape,points:^[dynamic]geom.Vec3,sizes:^[dynamic]u32,decomposed:=false) -> bool {
    file,waiting:=mesh_file(s,mesh,.Hull,decomposed)
    if waiting {return false}
    if file==nil {return host.assets_collision_hulls(s.app.assets,mesh,shape,points,sizes)}
    if !file.pieces {return false}
    return append(points,..file.piece_points[:])==len(file.piece_points) && append(sizes,..file.piece_sizes[:])==len(file.piece_sizes)
}

// What an Auto collider of an entity is made as, by what its mesh stores of the colliders of its source and
// whether its body moves: Mesh for a collision mesh it stores, Hull for the shapes it stores (one piece
// each), else Mesh for its own triangles while it stays still and, while it moves, Auto: the convex pieces
// of a decomposition of them (collision_hulls decomposed). A generated mesh or a primitive that moves is a
// Hull: of its pieces, or of all its points. waiting: the file of its mesh is still being read.
@(private)
auto_kind :: proc(s:^Sync,e:core.Entity,moving:bool) -> (kind:Collider_Kind,waiting:bool) {
    static,has_mesh:=core.get(s.statics,e)
    if !has_mesh {return .Hull,false}
    file:^Mesh_File
    if file,waiting=mesh_file(s,static.mesh,.Hull);waiting {return}
    stored:=file!=nil?file.stored:host.Stored_Collision.None
    if file==nil && static.mesh!={} {
        // The pieces a generated mesh was given are its shapes.
        points:=make([dynamic]geom.Vec3,context.temp_allocator)
        sizes:=make([dynamic]u32,context.temp_allocator)
        if host.assets_collision_hulls(s.app.assets,static.mesh,static.shape,&points,&sizes) {stored=.Shapes}
    }
    switch {
    case stored==.Mesh:  return .Mesh,false
    case stored==.Shapes:return .Hull,false
    case !moving:        return .Mesh,false
    case file!=nil:      return .Auto,false
    }
    return .Hull,false
}

// Whether a Hull, Mesh or Auto collider of an entity waits for what a job reads or builds of its mesh file:
// its body is made, or made again, in a later tick. It asks for what is missing. An Auto one is as auto_kind
// resolved it: still Auto, the convex pieces of its mesh.
@(private)
collider_geometry_waits :: proc(s:^Sync,e:core.Entity,collider:Collider,scale:[3]f32) -> bool {
    if collider.kind!=.Hull && collider.kind!=.Mesh && collider.kind!=.Auto || !core.has(s.colliders,e) {return false}
    static,has_mesh:=core.get(s.statics,e)
    if !has_mesh || static.mesh=={} {return false}
    file,waiting:=mesh_file(s,static.mesh,collider.kind==.Mesh?.Mesh:.Hull,collider.kind==.Auto)
    if waiting || file==nil || collider.kind!=.Mesh || !file.found {return waiting}
    _,waiting=mesh_cached(s,static.mesh,static.shape,scale)
    return waiting
}

// The built mesh of a Mesh collider at a scale: of a mesh file, built in a
// job from what its job read; of a generated mesh or a primitive, made now.
// nil when it cannot be made, or while it waits for a job: then waiting.
@(private)
mesh_cached :: proc(s:^Sync,mesh:base.Asset_Id,shape:host.Shape,scale:[3]f32) -> (built:^sim.Mesh,waiting:bool) {
    meshes:=s.meshes
    file:^Mesh_File
    size,time,is_file:=mesh_file_version(s.app,mesh)
    generated:=host.assets_mesh_generated(s.app.assets,mesh)
    if mesh!={} {
        if s.app.assets==nil || !generated && !is_file {return}
        if is_file {
            file,waiting=mesh_file(s,mesh,.Mesh)
            if waiting || file==nil || !file.found {return}
        }
    }
    key:=Collider_Mesh_Key{mesh,mesh=={}?shape:host.Shape.None,scale}
    if known,found:=meshes.entries[key];found {
        if !intrinsics.atomic_load(&known.ready) {
            if !jobs_inline(s) {return nil,true}
            jobs.wait(meshes.js,jobs.OWNER,&meshes.counter)
        }
        if known.size==size && known.time==time {return known.built.triangles!=nil?&known.built:nil,false}
        collider_mesh_free(known)
        delete_key(&meshes.entries,key)
    }
    entry,error:=new(Collider_Mesh,runtime.heap_allocator())
    if error!=nil {return}
    entry^={scale=scale,size=size,time=time,generated=generated,from=file,allocator=context.allocator}
    if _,error=map_insert(&meshes.entries,key,entry);error!=nil {
        free(entry,runtime.heap_allocator())
        return
    }
    building:=host.load_phase_begin(s.app,.Collision,host.LOAD_NO_ZONE)
    defer host.load_phase_end(s.app,building,1)
    meshes.built+=1
    if file!=nil {
        entry.allocator=runtime.heap_allocator()
        if !jobs_inline(s) {
            meshes.js=&s.app.jobs
            jobs.run(meshes.js,jobs.OWNER,.Background,collider_mesh_build,entry,&meshes.counter)
            return nil,true
        }
        collider_mesh_build(entry,jobs.OWNER)
    } else {
        buffer:geom.Mesh_Buffer
        geom.mesh_buffer_init(&buffer,context.temp_allocator)
        _,found:=host.assets_collision(s.app.assets,mesh,shape,.Mesh,&buffer)
        for &position in buffer.positions {position*=scale}
        disabled:=host.assets_mesh_disabled_edges(s.app.assets,mesh)
        // Kept empty when it cannot be built: it is not tried again for every entity that shows it.
        if !found || !sim.mesh_build(&entry.built,{buffer.positions[:],buffer.indices[:],disabled,inside_out(scale)},entry.allocator) {entry.built={}}
        entry.ready=true
    }
    return entry.built.triangles!=nil?&entry.built:nil,false
}

// A job: builds the tree of a Mesh collider of a mesh file at the scale of its key.
@(private="file")
collider_mesh_build :: proc(entry:^Collider_Mesh,worker:int) {
    context.allocator=runtime.heap_allocator()
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    defer intrinsics.atomic_store(&entry.ready,true)
    scale:=entry.scale
    from:=entry.from.geometry
    positions:=make([]geom.Vec3,len(from.positions),context.temp_allocator)
    for position,at in from.positions {positions[at]=position*scale}
    if !sim.mesh_build(&entry.built,{positions,from.indices[:],nil,inside_out(scale)},entry.allocator) {entry.built={}}
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
// a whole collider is; decomposed, the pieces of collision_hulls decomposed (an Auto collider that moves).
// pieces is false when the mesh has fewer than two: the collider is then one hull of all its points. On a
// failure the caller releases what was made.
@(private)
collider_pieces_make :: proc(s:^Sync,l:^Link,e:core.Entity,scale:[3]f32,round:f32,decomposed:=false) -> (pieces:bool,failure:Shape_Failure) {
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
        if !has_mesh || !collision_hulls(s,static.mesh,static.shape,&points,&sizes,decomposed) || len(sizes)<2 {return}
        source,shareable=geometry_source_of(s.app.assets,decomposed?.Auto:.Hull,static,scale,round)
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
        l.heightfield,made=sim.heightfield_create(w,{field.heights,field.columns,field.rows,field.cell*scale,field.disabled_borders,field.holes,heightfield_surfaces(field),field.surfaces})
        if !made {return {},.Geometry_Budget}
        return l.heightfield,.None
    }
    if kind==.Mesh {
        if built,_:=mesh_cached(s,static.mesh,static.shape,scale);built!=nil {
            l.mesh,made=sim.mesh_create_copy(w,built)
            if !made {return {},.Geometry_Budget}
            return l.mesh,.None
        }
    }
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer,context.temp_allocator)
    if !collision_geometry(s,static.mesh,static.shape,kind==.Mesh?.Mesh:.Hull,&buffer) {return {},.Mesh_Unreadable}
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
