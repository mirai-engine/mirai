package destruct

import "base:intrinsics"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import physics "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/jobs"

// What the application derives from the destructibles of a world: the cut of
// each mesh into pieces, the geometry of every piece, and the meshes
// generated for the bodies. None of it is the state of the world, so none is
// copied: it is rebuilt from the components and from the simulation, and
// each world keeps its own.
@(storage,host,by_world,free="cache_free")
Destruct_Cache :: struct {
    epoch:u32,                // of the simulation the entries were made for
    ready:bool,
    pass:u32,
    entries:core.Entity_Map(Entry), // by destructible
    seen:[Watched]core.Seen,  // of what a destructible is made of, and of the groups: what changed is looked at again
    role:core.Network_Role,   // the destructibles were looked at for
    meshes:[dynamic]base.Asset_Id, // generated for the groups, which hold them
    infos:[]physics.Piece_Info,   // the pieces of the destructible being looked at
    marks:[]u32,              // by body slot: equal to mark for the bodies already taken in the pass under way
    group_of:[]i32,           // by body slot: index of its group in this pass
    firsts:[]i32,             // one piece of each body of a destructible
    flat:[]i32,               // piece ids of every group, one after another
    mark:u32,
    groups:[dynamic]Scratch_Group,
    slicer:geom.Slicer,
    halves:[2]geom.Mesh_Buffer,
    merged:geom.Mesh_Buffer,
}

@(private)
Watched :: enum u8 {Destructible,Rigid_Body,Collider,Mesh_Renderer,Groups}

@(private)
Scratch_Group :: struct {
    group:u32,
    body:physics.Body_Handle,
    entity:core.Entity, // that has it already
    debris:bool,
    first,count:int, // in flat
}

// The pieces a mesh is cut into. A job writes it while counter is pending;
// after that it is kept, so making the destructible again costs no new cut.
@(private)
Prepared :: struct {
    key:Prepared_Key,
    source:geom.Mesh_Buffer, // the mesh in the frame of the entity, at its size; empty once cut
    sites:[dynamic][3]f32,
    fracture:geom.Fracture,
    desc:geom.Site_Desc,
    error:geom.Fracture_Error,
    interior:u32,
    anchors:[dynamic]bool,
    clusters:[dynamic]physics.Cluster_Desc,
    cluster_points:[dynamic][3]f32, // of the hulls of the clusters, at the size of the entity
    piece_clusters:[dynamic]i32,
    connection_strength:[dynamic]f32,
    counter:jobs.Counter,
}

// What a cut depends on.
@(private)
Prepared_Key :: struct {
    pieces:u32,
    seed:u64,
    pattern:Destruct_Pattern,
    mesh:base.Asset_Id,
    fracture:base.Asset_Id,
    shape:host.Shape,
    scale:[3]f32,
    interior:u32,
}

// The geometry of a piece: a view of the cut it came from, or its own after a slice.
@(private)
Visual :: struct {
    piece:i32,            // physics.Piece_Info.id
    center:[3]f32,        // of the piece it was made for: a slot that holds another piece is made again
    volume:f32,
    source:i32,           // piece of the fracture; -1 for a half of a slice
    geometry:geom.Mesh_Buffer,
}

@(private)
Entry :: struct {
    prepared:^Prepared,
    visuals:[dynamic]Visual,
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // of the Mesh_Renderer of the groups
    generated:[asset.MESH_MAX_SLOTS]base.Asset_Id,  // of the meshes generated for them
    slots:u32,                                      // material slots of those meshes; the last is the interior
    event:physics.Break_Event,                       // the strongest applied in event_tick: what Fracture tells
    event_tick:u64,
    pass:u32,                                       // the last tick that looked at it
    mirrored:bool,                                  // its groups were drawn from this entry
}

// Frees the memory of the cache and the meshes it made.
cache_destroy :: proc(assets:^host.Assets,job_system:^jobs.Job_System,cache:^Destruct_Cache) {
    cache_reset(assets,job_system,cache)
    cache_free(cache)
}

@(private)
scratch_free :: proc(cache:^Destruct_Cache) {
    delete(cache.infos);delete(cache.marks);delete(cache.group_of);delete(cache.firsts);delete(cache.flat)
    cache.infos,cache.marks,cache.group_of,cache.firsts,cache.flat=nil,nil,nil,nil,nil
}

// Frees the memory of the cache when the application ends: its meshes go with the assets.
cache_free :: proc(cache:^Destruct_Cache) {
    core.entity_map_destroy(&cache.entries);delete(cache.groups);delete(cache.meshes)
    scratch_free(cache)
    if cache.ready {
        geom.slicer_destroy(&cache.slicer)
        for &half in cache.halves {geom.mesh_buffer_destroy(&half)}
        geom.mesh_buffer_destroy(&cache.merged)
    }
    cache^={}
}

// What the cache derived for a World that is freed goes with it.
@(step="release")
destruct_release :: proc(cache:^Destruct_Cache,assets:^host.Assets,job_system:^jobs.Job_System) {
    if cache!=nil {cache_reset(assets,job_system,cache)}
}

// Releases what the cache derived, for a simulation that was replaced: every destructible is looked at again.
@(private)
cache_reset :: proc(assets:^host.Assets,job_system:^jobs.Job_System,cache:^Destruct_Cache) {
    for &entry in cache.entries.values {entry_release(job_system,&entry)}
    core.entity_map_clear(&cache.entries)
    #reverse for mesh in cache.meshes {mesh_release(assets,cache,mesh)}
    cache.seen={}
}

// Scratch for the pieces and the bodies a simulation holds, reserved once for each size of it.
@(private)
cache_make :: proc(cache:^Destruct_Cache,room:physics.Breakable_Room) -> bool {
    pieces,bodies:=max(room.pieces,1),max(room.bodies,1)
    if cache.ready && len(cache.infos)==pieces && len(cache.marks)==bodies {return true}
    scratch_free(cache)
    infos,infos_error:=make([]physics.Piece_Info,pieces)
    marks,marks_error:=make([]u32,bodies)
    group_of,group_error:=make([]i32,bodies)
    firsts,firsts_error:=make([]i32,pieces)
    flat,flat_error:=make([]i32,pieces)
    if infos_error!=nil || marks_error!=nil || group_error!=nil || firsts_error!=nil || flat_error!=nil || reserve(&cache.groups,bodies)!=nil {
        delete(infos);delete(marks);delete(group_of);delete(firsts);delete(flat)
        return false
    }
    cache.infos,cache.marks,cache.group_of,cache.firsts,cache.flat=infos,marks,group_of,firsts,flat
    cache.mark=0
    if !cache.ready {
        geom.slicer_init(&cache.slicer)
        for &half in cache.halves {geom.mesh_buffer_init(&half)}
        geom.mesh_buffer_init(&cache.merged)
        cache.ready=true
    }
    return true
}

@(private)
entry_find :: proc(cache:^Destruct_Cache,e:core.Entity) -> ^Entry {
    return cache==nil?nil:core.entity_map_get(&cache.entries,e)
}

// The entry of a destructible; a new one for one that has none. nil without memory for it.
@(private)
entry_take :: proc(cache:^Destruct_Cache,e:core.Entity) -> ^Entry {
    if entry:=core.entity_map_get(&cache.entries,e);entry!=nil {return entry}
    entry,_:=core.entity_map_put(&cache.entries,e,Entry{})
    return entry
}

@(private)
visuals_release :: proc(entry:^Entry) {
    for &visual in entry.visuals {geom.mesh_buffer_destroy(&visual.geometry)}
    clear(&entry.visuals)
}

// Releases a mesh generated for a group.
@(private)
mesh_release :: proc(assets:^host.Assets,cache:^Destruct_Cache,mesh:base.Asset_Id) {
    if mesh=={} {return}
    for id,at in cache.meshes {
        if id!=mesh {continue}
        unordered_remove(&cache.meshes,at)
        if assets!=nil {host.assets_mesh_release(assets,mesh)}
        return
    }
}

@(private)
prepared_release :: proc(job_system:^jobs.Job_System,entry:^Entry) {
    p:=entry.prepared
    if p==nil {return}
    jobs.wait(job_system,jobs.OWNER,&p.counter)
    geom.mesh_buffer_destroy(&p.source)
    delete(p.sites)
    geom.fracture_destroy(&p.fracture)
    delete(p.anchors);delete(p.clusters);delete(p.cluster_points);delete(p.piece_clusters);delete(p.connection_strength)
    free(p)
    entry.prepared=nil
}

// Ends an entry: its geometry and its cut. Taking it out of the cache is the caller's.
@(private)
entry_release :: proc(job_system:^jobs.Job_System,entry:^Entry) {
    visuals_release(entry)
    delete(entry.visuals)
    prepared_release(job_system,entry)
    entry^={}
}

// The material slots of the meshes of the pieces: those of the mesh of the
// entity and one more, the last, for the faces the fracture opens.
@(private)
slots_of :: proc(assets:^host.Assets,d:Destructible,mesh:base.Asset_Id) -> (slots,interior:u32,generated:[asset.MESH_MAX_SLOTS]base.Asset_Id) {
    slots=1
    if mesh!={} && assets!=nil {
        if found:=host.assets_mesh(assets,mesh);found!=nil && found.slot_count>0 {
            slots=found.slot_count
            generated=found.slot_materials
        }
    }
    interior=min(slots,asset.MESH_MAX_SLOTS-1)
    generated[interior]=d.interior!={}?d.interior:generated[0]
    return
}

// Starts cutting the mesh of a destructible into pieces. The geometry is
// read here; the cut runs as a job, which a thread of the application takes or
// whoever waits for its counter runs. False when there is no geometry to cut.
@(private)
prepare_start :: proc(assets:^host.Assets,job_system:^jobs.Job_System,entry:^Entry,d:Destructible,static:render.Mesh_Renderer,scale:[3]f32,interior:u32) -> bool {
    p:=entry.prepared
    if p==nil {
        allocated,error:=new(Prepared)
        if error!=nil {return false}
        p=allocated
        geom.mesh_buffer_init(&p.source)
        p.sites=make([dynamic][3]f32)
        geom.fracture_init(&p.fracture)
        p.anchors=make([dynamic]bool)
        p.clusters=make([dynamic]physics.Cluster_Desc)
        p.cluster_points=make([dynamic][3]f32)
        p.piece_clusters=make([dynamic]i32)
        p.connection_strength=make([dynamic]f32)
        entry.prepared=p
    } else {
        // The job of what it was cut from before may still be writing.
        jobs.wait(job_system,jobs.OWNER,&p.counter)
    }
    p.key,p.error={},.None
    clear(&p.anchors);clear(&p.clusters);clear(&p.cluster_points);clear(&p.piece_clusters);clear(&p.connection_strength)
    geom.mesh_buffer_clear(&p.source)
    if d.fracture!={} {
        if !prepare_authored(assets,p,d,static,scale,interior) {p.error=.Invalid_Mesh;return false}
        return true
    }
    if !host.assets_geometry(assets,static.mesh,static.shape,&p.source,true) {p.error=.Invalid_Mesh;return false}
    for &position in p.source.positions {position*=scale}
    for &normal in p.source.normals {normal=linalg.normalize0(normal/scale)}
    lo,hi:=geom.mesh_bounds(p.source.positions[:])
    if resize(&p.sites,int(d.pieces))!=nil {p.error=.Invalid_Mesh;return false}
    p.desc={pattern=geom.Site_Pattern(d.pattern),seed=d.seed,lo=lo,hi=hi,center=0.5*(lo+hi)}
    p.interior=interior
    p.key={pieces=d.pieces,seed=d.seed,pattern=d.pattern,mesh=static.mesh,shape=static.shape,scale=scale,interior=interior}
    jobs.run(job_system,jobs.OWNER,prepare_job,p,&p.counter)
    // Without other threads nobody would cut them while the ticks go on.
    if jobs.worker_count(job_system)==1 {jobs.wait(job_system,jobs.OWNER,&p.counter)}
    return true
}

@(private)
prepare_job :: proc(p:^Prepared,worker:int) {
    geom.sites_generate(p.sites[:],p.desc)
    p.error=geom.mesh_fracture(&p.fracture,geom.mesh_buffer_view(&p.source),p.sites[:],{interior_material=p.interior})
    geom.mesh_buffer_clear(&p.source)
}

@(private)
prepared_pending :: proc(p:^Prepared) -> bool {return jobs.pending(&p.counter)}

@(private)
visual_find :: proc(entry:^Entry,piece:i32) -> ^Visual {
    for &visual in entry.visuals {
        if visual.piece==piece {return &visual}
    }
    return nil
}

@(private)
visual_mesh :: proc(entry:^Entry,visual:^Visual) -> geom.Mesh {
    if visual.source>=0 && entry.prepared!=nil {
        if int(visual.source)>=len(entry.prepared.fracture.pieces) {return {}}
        return geom.fracture_piece_mesh(&entry.prepared.fracture,int(visual.source))
    }
    return geom.mesh_buffer_view(&visual.geometry)
}

// Notes the geometry of a piece of the cut: kept when the slot still holds the piece it was made for.
// False without memory to note it.
@(private)
visual_source :: proc(entry:^Entry,piece:physics.Piece_Info) -> bool {
    visual:=visual_find(entry,piece.id)
    if visual!=nil && visual.center==piece.center && visual.volume==piece.volume {return true}
    if visual==nil {
        if _,err:=append(&entry.visuals,Visual{piece=piece.id});err!=nil {return false}
        visual=&entry.visuals[len(entry.visuals)-1]
        geom.mesh_buffer_init(&visual.geometry)
    }
    visual.center,visual.volume,visual.source=piece.center,piece.volume,piece.source
    return true
}

// visual_source for the pieces of the cut of an entity, which is told when one found no memory.
@(private)
visuals_source :: proc(problems:^core.Problems,e:core.Entity,entry:^Entry,pieces:[]physics.Piece_Info) {
    noted:=true
    for piece in pieces {
        if piece.source>=0 && !visual_source(entry,piece) {noted=false}
    }
    if !noted {core.report(problems,e,"destruct.memory","out of memory for the geometry of the pieces of its Destructible: they collide, and are not drawn; free memory")}
}

// The geometry of a half: the geometry of the piece it was cut from, cut by the same plane.
@(private)
visual_cut :: proc(cache:^Destruct_Cache,entry:^Entry,piece:physics.Piece_Info) -> bool {
    if visual:=visual_find(entry,piece.id);visual!=nil && visual.center==piece.center && visual.volume==piece.volume {return true}
    parent:=visual_find(entry,piece.parent)
    if parent==nil {return false}
    _,error:=geom.mesh_slice(&cache.slicer,visual_mesh(entry,parent),geom.Plane{piece.cut_normal,piece.cut_offset},&cache.halves[0],&cache.halves[1],{cap_material=entry.slots-1})
    half:=&cache.halves[piece.front?0:1]
    if error!=.None || len(half.indices)==0 {return false}
    visual:=visual_find(entry,piece.id)
    if visual==nil {
        if _,err:=append(&entry.visuals,Visual{piece=piece.id});err!=nil {return false}
        visual=&entry.visuals[len(entry.visuals)-1]
        geom.mesh_buffer_init(&visual.geometry)
    }
    g:=&visual.geometry
    geom.mesh_buffer_clear(g)
    _,no_positions:=append(&g.positions,..half.positions[:])
    _,no_normals:=append(&g.normals,..half.normals[:])
    _,no_uvs:=append(&g.uvs,..half.uvs[:])
    _,no_colors:=append(&g.colors,..half.colors[:])
    _,no_indices:=append(&g.indices,..half.indices[:])
    _,no_materials:=append(&g.materials,..half.materials[:])
    if no_positions!=nil || no_normals!=nil || no_uvs!=nil || no_colors!=nil || no_indices!=nil || no_materials!=nil {
        geom.mesh_buffer_clear(g)
        return false
    }
    visual.center,visual.volume,visual.source=piece.center,piece.volume,-1
    return true
}

// A mesh with the geometry of the pieces of a body, generated for the renderer:
// none and true when they have no geometry, false when it was not made.
@(private)
group_mesh_make :: proc(assets:^host.Assets,cache:^Destruct_Cache,entry:^Entry,members:[]i32) -> (id:base.Asset_Id,ok:bool) {
    if assets==nil {return}
    m:=&cache.merged
    geom.mesh_buffer_clear(m)
    for piece in members {
        visual:=visual_find(entry,piece)
        if visual==nil {continue}
        mesh:=visual_mesh(entry,visual)
        first:=u32(len(m.positions))
        append(&m.positions,..mesh.positions)
        append(&m.normals,..mesh.normals)
        append(&m.uvs,..mesh.uvs)
        append(&m.colors,..mesh.colors)
        for index in mesh.indices {append(&m.indices,first+index)}
        append(&m.materials,..mesh.materials)
    }
    // Pieces without geometry have their own problem: no mesh is wanted.
    if len(m.indices)==0 {return {},true}
    // A stream that not every piece brought is left out.
    if len(m.normals)!=len(m.positions) {clear(&m.normals)}
    if len(m.uvs)!=len(m.positions) {clear(&m.uvs)}
    if len(m.colors)!=len(m.positions) {clear(&m.colors)}
    if len(m.materials)*3!=len(m.indices) {clear(&m.materials)}
    id,ok=host.assets_mesh_generate(assets,geom.mesh_buffer_view(m),entry.generated[:entry.slots])
    if _,err:=append(&cache.meshes,id);ok && err!=nil {
        host.assets_mesh_release(assets,id)
        return {},false
    }
    return
}
