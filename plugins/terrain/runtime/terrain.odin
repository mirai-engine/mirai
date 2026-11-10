package terrain

import "base:runtime"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

@(component,far)
Terrain :: struct {
    source:base.Asset_Id `mirai:"kind=.terrain"`,
    revision:u32 `mirai:"readonly,hidden"`, // of its source, as edits leave it: what the undo of the editor gives back with an edit
    solid:bool,
    ground:base.Entity_Id, // of a Volume: the Id of the Heightfield terrain it joins, which leaves the cells under its box to it; 0: none
}
TERRAIN_DEFAULT :: Terrain{solid=true}

@(component)
Terrain_Chunk :: struct {
    owner:core.Entity `mirai:"transient"`,
    coord:[3]i32 `mirai:"transient"`, // of its first chunk
    revision:u32 `mirai:"transient"`,
    lod:Chunk_Lod `mirai:"transient"`, // the level its mesh shows, and of its sides
    depth:u8 `mirai:"transient"`,      // 0: a chunk; above, a node of the quadtree that covers 2^depth chunks a side
    joined:bool `mirai:"transient"`,   // built from a join: a Heightfield chunk with cells a Volume takes, or a Volume chunk in its band; neither displaced nor replaced by a preview
}

@(storage,setting)
Terrain_Settings :: struct {
    sources:u32 `mirai:"advanced"`,
    chunks:u32 `mirai:"advanced"`, // pieces the terrains show, chunks and nodes of their quadtrees: past it, the farthest show coarser nodes
    samples:u32 `mirai:"advanced"`,
    requests:u32 `mirai:"advanced"`, // edits, layer changes and saves a tick can ask for, and digs it reports; past it they are dropped and reported
    lod_distance:f32 `mirai:"unit=m"`,       // level 0 within it of the view, one level more each time it doubles (a Heightfield chunk no coarser than its error allows); 0: a Heightfield takes the coarsest level whose error covers about LOD_PIXELS of the view (others LOD_CHUNKS chunk widths); below 0: every chunk at level 0
    collision_distance:f32 `mirai:"unit=m"`, // chunks farther from the view have no collider; whatever it is, only the nearest that Physics_Settings has room for collide; 0: no distance
    resident_distance:f32 `mirai:"unit=m"`,  // chunks farther from every streaming source (scene.Streaming_Sources) let go of their mesh, collider and pages, and nodes of the quadtree show in their place; 0: every chunk stays
    displacement_distance:f32 `mirai:"unit=m"`, // Heightfield chunks at level 0 within it of the view raise the heights of the textures of their layers (Terrain_Layer.displacement); 0: none
    displacement_detail:u32 `mirai:"max=4,advanced"`, // times a cell of a displaced chunk splits in two along each side
}
TERRAIN_SETTINGS_DEFAULT :: Terrain_Settings{sources=16,chunks=4096,samples=8*1024*1024,requests=256,displacement_distance=32,displacement_detail=3}

@(storage,copy="terrain_data_copy",swap="terrain_data_swap",free="terrain_data_free",reset="terrain_data_reset")
Terrain_Data :: struct {
    entries:[dynamic]Data_Source,
    settings:Terrain_Settings,
    epoch:u32,
    ready:bool,
    samples:u32,
    registry:u64, // the revision of the registry of the assets when the stamps were last compared
    stats:Terrain_Data_Stats,
    // The jobs that read these sources, which go with them when the World is
    // swapped; what changes or frees the sources waits for them first.
    work:[]Work_Slot,
    jobs:^jobs.Job_System, // that runs them; nil: each runs where it is made
    loads:[dynamic]^Source_Load, // the sources read in jobs, until they join entries
    unread:[dynamic]base.Asset_Id, // sources a load could not read: none waits for them until the registry changes
}

// A source read in a job (data_load_begin): its file, its coarse grid and
// what its chunks and nodes reach, apart from the main thread, in memory of
// its own. data_load_end puts it among the sources.
Source_Load :: struct {
    id:base.Asset_Id,
    stamp:File_Stamp,
    path:string,
    entry:Data_Source,
    types:asset.Types, // of the job
    js:^jobs.Job_System,
    ok:bool,
    whole:bool, // a Mesh: read on the main thread (data_load)
    counter:jobs.Counter,
}
Terrain_Data_Stats :: struct {loads,edits,saves,pages_read,pages_left:u64}
Data_Source :: struct {
    id:base.Asset_Id,
    stamp:File_Stamp, // of the file the source was read from
    source:Source,
    change:u32,     // advances with each change of the source: an edit, a layer, a reading of its file
    versions:[]u32, // of each chunk: the change it last took
    quad:Quad,
    nodes:[]u32,     // of each node of the quadtree above the chunks: the last change of a chunk it covers
    ranges:[][2]f32, // of each chunk and node: the lowest and highest point of its samples or sections
    errors:[]Lod_Errors, // of each chunk and node of a Heightfield: how far each level is from its samples
    dirty:[]bool,    // by chunk and node
    pending:[dynamic]u32,
    allocator:runtime.Allocator, // of versions, nodes, ranges, errors and dirty
}

// Where the editor brushes a source, in its space: the chunks of its terrains
// within radius of center over x and z show as chunks, not as the nodes over
// them, so that what a stroke changes shows on them. Radius 0: nowhere.
// While a stroke is held, low and high hold over x and z what it changed so
// far, which is not in Terrain_Data until it is confirmed.
@(storage)
Terrain_Focus :: struct {source:base.Asset_Id,center:[3]f32,radius:f32,stroke:bool,low,high:[2]f32}

Edit_Request :: struct {owner:core.Entity,brush:Brush} // owner none: the terrain the brush touches; the brush is in the world
Save_Request :: struct {owner:core.Entity,path:[512]u8 `mirai:"text"`}
Layer_Request :: struct {owner:core.Entity,change:Layer_Change}
@(storage,queue)
Terrain_Requests :: struct {edits:core.Queue(Edit_Request),saves:core.Queue(Save_Request),layers:core.Queue(Layer_Request)}

// Edits a terrain with a brush in the world, on the next tick. owner: the
// terrain to edit; none: the one the brush touches. What it took out comes in
// Terrain_Digs.
dig :: proc(requests:^Terrain_Requests,brush:Brush,owner:=core.NONE) {
    if brush.alpha!=nil {core.refuse(&requests.edits);return}
    core.offer(&requests.edits,Edit_Request{owner,brush})
}
// Sets layer index of the source of a terrain, or adds one with index equal to its count.
request_layer :: proc(requests:^Terrain_Requests,owner:core.Entity,index:int,layer:Terrain_Layer) {
    core.offer(&requests.layers,Layer_Request{owner,{index=u32(max(index,0)),layer=layer}})
}
// Takes layer index away from the source of a terrain; what it covered goes to the others.
request_layer_remove :: proc(requests:^Terrain_Requests,owner:core.Entity,index:int) {
    core.offer(&requests.layers,Layer_Request{owner,{index=u32(max(index,0)),remove=true}})
}
request_save :: proc(requests:^Terrain_Requests,owner:core.Entity,path:string="") {
    if len(path)>=512 {core.refuse(&requests.saves);return}
    request:=Save_Request{owner=owner}
    asset.text_set(request.path[:],path)
    core.offer(&requests.saves,request)
}

// The room of the requests of a tick, and what did not fit in it.
@(step="input fixed",loops="game editor",stage="begin")
terrain_requests_serve :: proc(requests:^Terrain_Requests,digs:^Terrain_Digs,settings:Terrain_Settings,problems:^core.Problems) {
    capacity,setting:=int(settings.requests),"Terrain_Settings.requests"
    core.queue_serve(&requests.edits,capacity,problems,"terrain.requests","terrain edits",setting,"a game edits with a brush without an alpha")
    core.queue_serve(&requests.layers,capacity,problems,"terrain.requests","terrain layer changes",setting)
    core.queue_serve(&requests.saves,capacity,problems,"terrain.requests","terrain saves",setting,"a save names a path shorter than 512 bytes")
    core.queue_serve(&digs.digs,capacity,problems,"terrain.requests","terrain digs of a tick",setting)
}

// A brush of the world as the terrain at place reads it, and the other way.
brush_local :: proc(brush:Brush,place:mm.Transform) -> Brush {
    return brush_placed(brush,linalg.inverse(mm.transform_matrix(place)),mm.quat_inverse(place.rotation),1/max(abs(place.scale.x),1e-6))
}
brush_world :: proc(brush:Brush,place:mm.Transform) -> Brush {
    return brush_placed(brush,mm.transform_matrix(place),place.rotation,max(abs(place.scale.x),1e-6))
}
@(private)
brush_placed :: proc(brush:Brush,to:matrix[4,4]f32,rotation:quaternion128,factor:f32) -> (moved:Brush) {
    moved=brush
    c,d,n:=brush.center,brush.delta,brush.normal
    moved.center=(to*[4]f32{c.x,c.y,c.z,1}).xyz
    moved.delta=(to*[4]f32{d.x,d.y,d.z,0}).xyz
    moved.normal=linalg.normalize0((to*[4]f32{n.x,n.y,n.z,0}).xyz)
    moved.target=(to*[4]f32{c.x,brush.target,c.z,1}).y
    moved.rotation=rotation*brush.rotation
    moved.radius*=factor
    moved.extent*=factor
    moved.blend*=factor
    moved.interval*=factor
    moved.scale*=factor
    moved.max_edge*=factor
    #partial switch brush.kind {
    case .Raise,.Lower,.Noise: moved.amount*=factor
    }
    return
}

// What an edit of a world that plays took out of a terrain: what stopped
// being solid in a Volume, or what a Heightfield lowered. terrain keeps
// nothing of it: a game gives it back as it likes (an inventory, points,
// dust, pieces that fly out).
Terrain_Dig :: struct {
    owner:core.Entity,
    source:base.Asset_Id,
    center:[3]f32 `mirai:"unit=m"`,      // in the world: the middle of what it took
    radius:f32 `mirai:"unit=m"`,         // from center to about the farthest of it
    volume:f32,                          // cubic metres
    layers:[LAYERS_MAX]f32,              // cubic metres of each layer; without layers, all of it is the first
    materials:[LAYERS_MAX]base.Asset_Id, // of those layers; without layers, the material of the source
}

// What the edits of dig and the replays of the tick took out, in
// their order. terrain_replay empties it at the start of each tick of a world
// that plays.
@(storage,events)
Terrain_Digs :: struct {digs:core.Queue(Terrain_Dig)}

// The dig of the last edit of the source of entry, if it took something out.
@(private)
dig_push :: proc(digs:^Terrain_Digs,owner:core.Entity,entry:^Data_Source,worlds:core.Read(core.World_Transform)) {
    s:=&entry.source
    d:=s.dug
    if !(d.volume>0) {return}
    place:=mm.TRANSFORM_IDENTITY
    if world,found:=core.get(worlds,owner);found {place=world.transform}
    scale:=max(abs(place.scale.x),abs(place.scale.y),abs(place.scale.z))
    dig:=Terrain_Dig{owner=owner,source=entry.id,volume=d.volume,layers=d.layers}
    dig.center=mm.transform_point(place,d.sum/d.volume)
    dig.radius=(linalg.length(d.high-d.low)*0.5+s.cell)*scale
    for i in 0..<int(s.layer_count) {dig.materials[i]=s.layers[i].material}
    core.offer(&digs.digs,dig)
}

// The meshes of the pieces of the terrains of a world: each world keeps its
// own. Each terrain keeps a mesh per chunk and node of the quadtree of its
// source (Resident_Source), at the levels its views ask for; the data of a
// source is one for every terrain that shows it.
@(storage,host,by_world,free="terrain_resident_free")
Terrain_Resident :: struct {
    called:u64, // the frame of its last call, plus one
    epoch:u32,
    assets:^host.Assets,
    sources:[dynamic]Resident_Source,
    owners:[dynamic]Resident_Owner,
    ready:bool,
    pass:u32,
    gc_stamps:[6]u64,
    shown:[3]u64, // the versions of Terrain, Tint and Material_Override after the owners last showed their chunks
    stats:Terrain_Resident_Stats,
    lod_view:[3]f32,  // where the view was at the last evaluation of levels
    lod_stamp:[5]u64, // the version of the transforms, the revision of the streaming sources, the count of owners, marks, the version of the colliders
    marks:u64,        // advances when what the levels are chosen from changes: a page, a source, a chunk that empties or fills
    lod_distances:[3]f32, // of Terrain_Settings then
    focus:Terrain_Focus,  // then
    room:Collider_Room,
    cut:bool,               // what the owners show is to be chosen again: the cuts or what is built changed
    splits:[dynamic]Split,  // room for a node of every owner: the order of the budget and of the colliders
    border:Piece_Border,    // of a node, while its pages are looked for
    picking:bool,           // chunks without a collider keep their triangles on the CPU: while the world does not play, for the picking of the editor
}
// stale: results of jobs whose chunk changed while they ran; starved: chunks
// shown without the collider Physics_Settings had no slot for.
Terrain_Resident_Stats :: struct {built,reused,released,stale,starved,evicted:u64,meshes:u32}
Resident_Chunk :: struct {
    mesh:base.Asset_Id,
    revision:u32,
    built,wanted:Chunk_Key, // what the mesh shows, and what the owners ask for
    distance:f32,           // to the nearest view of its owners, at the last evaluation
    reach:f32,              // its distance over the resident distance of the nearest viewer: resident up to 1
    pixels,spacing:f32,     // of the view a metre of its error, and between its samples, covers (Owner_Node)
    resident:bool,          // a piece an owner wants, or a root of a streamed source: wanted with a mesh
    visible:bool,           // an owner shows it
    urgent:bool,            // an owner wants it where nothing shows
    shown:bool,             // what it built is published: a mesh, or none for an empty chunk
    working:bool,           // a job builds it
}
// A piece is built again when its level, its border or its collider changes.
// border: a hash of the levels of the border of a node (Piece_Border).
Chunk_Key :: struct {lod:Chunk_Lod,collision:bool,border:u64,join:u64} // join: what it builds from its joins (join_cut_key, Terrain_Join.hash), 0 none
Resident_Source :: struct {
    id:base.Asset_Id,
    owner:core.Entity,       // the terrain whose pieces these are
    quad:Quad,
    chunks:[]Resident_Chunk, // by node: the chunks, then the nodes of the quadtree
    levels:[]u8,             // by chunk: the level it shows or would show (Border_Levels)
    deep:[]bool,             // by chunk: it shows well within the reach of a viewer
    changed:[dynamic]u32,    // nodes published or let go since the owner last showed them
    dirty:[]bool,            // by node: in pending
    pending:[dynamic]u32,    // nodes whose mesh may show something else than what is wanted
    pages:[]bool,            // of a paged source, by page of its heights: those a resident chunk reads
    leave:bool,              // a chunk was let go: pages may leave with it
    override:render.Material_Override, // of its layers
    override_info:Source_Info,         // the layers it was made from
    override_assets:[2]u64,            // and the revision and structure of the assets
    join:Terrain_Join,
}
Resident_Owner :: struct {
    entity:core.Entity,
    source:base.Asset_Id,
    quad:Quad,
    chunks:[]core.Entity, // by node: the entity that shows it, NONE while it does not
    nodes:[]Owner_Node,   // by node: what this terrain wants and shows of it
    changed:[dynamic]u32, // nodes it began or stopped showing since it last published
    materials:[render.MATERIAL_SLOTS]base.Asset_Id, // its chunks show, chunk_materials
    tint:render.Tint,
    override:render.Material_Override,
    solid:bool,
    far:bool,  // of a section that is not loaded (scene.Far_Kept): its far form alone, without colliders
    pass:u32,
    full:bool, // shows every chunk again, not only the changed ones
}
// A node as one terrain sees it. The pieces it wants (cut) cover its source
// once: the roots, and the children of each node it opens. What it shows
// (visible) follows them as they are built: a region keeps what it showed
// until all that replaces it is.
Owner_Node :: struct {
    distance,reach:f32, // from its views and viewers, as Resident_Chunk
    pixels:f32,         // of the view a metre of its error covers
    spacing:f32,        // of the view a metre between its samples covers, at the angle it is seen
    resident:bool,      // a chunk it needs as a chunk: near its viewers, or with a collider (resident_needed)
    want:bool,          // a node that would open: a chunk under it is resident, or the view is nearer than its level reaches
    open:bool,          // its children are wanted in its place
    cut:bool,           // wanted as a piece
    visible:bool,       // shown
    covering:bool,      // it or a node above it is shown
    covered:bool,       // what it covers is shown
    can:bool,           // what it covers can show as wanted
    collide:bool,       // a chunk that takes a collider
    pass:u32,           // of the call that last showed it: once a call
}
// Something an owner may open, or a chunk that may collide, in order.
@(private)
Split :: struct {near,far:f32,depth:i32,owner,node:u32}

// What the registry of the assets records of the file of a source: it
// differs once the file changes, on disk or in the memory of the registry
// (an edit, undo, Save, Discard, a recovery).
File_Stamp :: struct {size,time:i64,found:bool}

terrain_stamp :: proc(a:^host.Assets,id:base.Asset_Id) -> File_Stamp {
    file,found:=asset.registry_find(&a.registry,id)
    if !found {return {}}
    return {file.size,file.time,true}
}

terrain_file :: proc(a:^host.Assets,id:base.Asset_Id,allocator:=context.temp_allocator) -> (path:string,found:bool) {
    file:=asset.registry_find(&a.registry,id) or_return
    return asset.registry_file_path(&a.registry,file.path,allocator),true
}

// Reads the source of a terrain as the registry of the assets holds it: what
// its memory keeps unsaved, or the file. paged leaves the pages of a
// Heightfield or Volume on disk in the file, read when needed; one only the
// memory of the registry holds is read whole.
terrain_read :: proc(s:^Source,a:^host.Assets,id:base.Asset_Id,allocator:=context.allocator,editable:=true,paged:=false) -> bool {
    if paged {
        record,found:=asset.registry_find(&a.registry,id)
        if !found || record.kind!=KIND {return false}
        if _,held:=asset.registry_memory_find(&a.registry,record.path);!held {
            path:=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
            front:asset.Asset
            if asset.asset_load_front(&front,path,a.allocator)!=.None {return false}
            defer asset.asset_close(&front)
            info,error:=asset.asset_row(&front,&a.types,"terrain",Source_Info)
            if error!=.None || info==nil {return false}
            if info.kind!=.Mesh {
                loaded,ok:=source_read(s,&front,&a.types,allocator,editable,path)
                return ok && loaded==id
            }
        }
    }
    file:asset.Asset
    if host.assets_file(a,id,KIND,&file)!=.None {return false}
    defer asset.asset_close(&file)
    loaded,ok:=source_read(s,&file,&a.types,allocator,editable)
    return ok && loaded==id
}
terrain_source :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id) -> ^Source {
    for &entry in data.entries {if entry.id==id {return &entry.source}}
    return nil
}

// The height of the surface of a Heightfield source at a local point x,z,
// over the triangles its collider has. ok is false for another kind, outside
// the source, or where its page is not in memory: there no chunk is resident.
terrain_height :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,x,z:f32) -> (height:f32,ok:bool) {
    s:=terrain_source(data,id)
    if s==nil {return}
    return source_height_held(s,x,z)
}

// The change of the data of every source of a world: it advances with each
// edit, layer, reading of a file and page that comes into memory.
terrain_data_change :: proc(data:core.Ref(Terrain_Data)) -> (change:u64) {
    for &entry in data.entries {change+=u64(entry.change)}
    return change+u64(data.epoch)<<32
}

// The change of the data of a source: it advances with each edit, layer and
// reading of its file. 0 for a source that is not loaded.
terrain_change :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id) -> u32 {
    for &entry in data.entries {if entry.id==id {return entry.change}}
    return 0
}

// The local box of the chunks of a source that changed after change since
// (terrain_change); changed false when none did. A source loaded again after
// since was let go starts its changes anew: while its change is below since
// it counts as changed whole.
terrain_changed :: proc(data:core.Ref(Terrain_Data),id:base.Asset_Id,since:u32) -> (low,high:[3]f32,changed:bool) {
    for &entry in data.entries {
        if entry.id!=id {continue}
        s:=&entry.source
        anew:=entry.change<since
        for version,index in entry.versions {
            if version<=since && !anew {continue}
            from,to:[3]f32
            if s.kind==.Mesh {
                if index>=len(s.mesh_chunks) {continue}
                from,to=s.mesh_chunks[index].low,s.mesh_chunks[index].high
            } else {
                a,b,valid:=chunk_region(s,chunk_coord(s,index))
                if !valid {continue}
                origin:=source_origin(s)
                from=origin+[3]f32{f32(a.x),f32(a.y),f32(a.z)}*s.cell
                to=origin+[3]f32{f32(b.x),f32(b.y),f32(b.z)}*s.cell
                if s.kind==.Heightfield {from.y,to.y=-HEIGHT_LIMIT,HEIGHT_LIMIT}
            }
            if !changed {low,high,changed=from,to,true;continue}
            for axis in 0..<3 {low[axis]=min(low[axis],from[axis]);high[axis]=max(high[axis],to[axis])}
        }
    }
    return
}

@(private)
data_find :: proc(data:^Terrain_Data,id:base.Asset_Id) -> ^Data_Source {
    for &entry in data.entries {if entry.id==id {return &entry}}
    return nil
}
@(private)
data_entry_free :: proc(entry:^Data_Source) {
    source_destroy(&entry.source)
    allocator:=entry.allocator if entry.allocator.procedure!=nil else context.allocator
    delete(entry.versions,allocator);delete(entry.nodes,allocator);delete(entry.ranges,allocator);delete(entry.errors,allocator);delete(entry.dirty,allocator);delete(entry.pending)
    entry^={}
}
terrain_data_free :: proc(data:^Terrain_Data) {
    work_wait(data,nil)
    for load in data.loads {data_load_free(load)}
    delete(data.loads);delete(data.unread)
    for &entry in data.entries {data_entry_free(&entry)}
    delete(data.entries)
    work_free(data)
    data^={}
}
// The sources of a World whose entities were all replaced, as loading a scene
// does: read again from the assets. The epoch tells the resident meshes.
terrain_data_reset :: proc(data:^Terrain_Data) {
    epoch:=data.epoch+1;if epoch==0 {epoch=1}
    terrain_data_free(data)
    data.epoch=epoch
}
terrain_data_copy :: proc(dst,src:^Terrain_Data) -> bool {
    if dst==src {return true}
    work_wait(dst,nil)
    dst.ready=false
    if reserve(&dst.entries,max(len(src.entries),int(src.settings.sources)))!=nil {return false}
    for &entry in dst.entries[min(len(dst.entries),len(src.entries)):] {data_entry_free(&entry)}
    if resize(&dst.entries,len(src.entries))!=nil {return false}
    dst.samples=0
    for &entry,i in src.entries {
        target:=&dst.entries[i]
        if !data_source_copy(&target.source,&entry.source) || !data_chunks_copy(target,&entry) {return false}
        target.id,target.stamp,target.change=entry.id,entry.stamp,entry.change
        dst.samples+=u32(source_cost(&target.source))
    }
    epoch:=max(dst.epoch,src.epoch)+1;if epoch==0 {epoch=1}
    dst.settings,dst.ready,dst.stats,dst.epoch,dst.registry=src.settings,src.ready,src.stats,epoch,src.registry
    return true
}

terrain_data_swap :: proc(a,b:^Terrain_Data) {
    if a==b {return}
    epoch:=max(a.epoch,b.epoch)+1;if epoch==0 {epoch=1}
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    slice.ptr_swap_non_overlapping(a,b,size_of(Terrain_Data))
    a.epoch,b.epoch=epoch,epoch
}
// The chunks and nodes of the quadtree of the source of entry, every one
// pending, and the heights each reaches: a Heightfield reads every page once
// for them and for its coarse grid.
@(private)
data_chunks_allocate :: proc(entry:^Data_Source,allocator:runtime.Allocator,js:^jobs.Job_System=nil,worker:=jobs.OWNER) -> bool {
    entry.allocator=allocator
    entry.quad=quad_of(&entry.source)
    chunks,total:=entry.quad.first[1],quad_total(&entry.quad)
    error:runtime.Allocator_Error
    entry.versions,error=make([]u32,chunks,allocator)
    if error!=nil {return false}
    entry.nodes,error=make([]u32,total-chunks,allocator)
    if error!=nil {return false}
    entry.ranges,error=make([][2]f32,total,allocator)
    if error!=nil {return false}
    entry.errors,error=make([]Lod_Errors,entry.source.kind==.Heightfield?total:0,allocator)
    if error!=nil {return false}
    entry.dirty,error=make([]bool,total,allocator)
    if error!=nil {return false}
    entry.pending,error=make([dynamic]u32,0,total,allocator)
    if error!=nil {return false}
    for &version in entry.versions {version=entry.change}
    for &version in entry.nodes {version=entry.change}
    for i in 0..<total {entry.dirty[i]=true;append(&entry.pending,u32(i))}
    if !source_coarse_build(&entry.source,entry.ranges[:chunks],entry.errors[:min(chunks,len(entry.errors))],js,worker) {return false}
    data_ranges(entry)
    data_errors(entry)
    return true
}

// Starts reading a source in a job: nil when it is not a file the job can
// read alone (one the memory of the registry holds), which data_load reads.
@(private)
data_load_begin :: proc(data:^Terrain_Data,a:^host.Assets,id:base.Asset_Id) -> ^Source_Load {
    if load:=data_loading(data,id);load!=nil {return load}
    record,found:=asset.registry_find(&a.registry,id)
    if !found || record.kind!=KIND {return nil}
    if _,held:=asset.registry_memory_find(&a.registry,record.path);held {return nil}
    heap:=runtime.heap_allocator()
    load,allocation_error:=new(Source_Load,heap)
    if allocation_error!=nil {return nil}
    load.id,load.stamp,load.js=id,terrain_stamp(a,id),data.jobs
    load.path=asset.registry_file_path(&a.registry,record.path,heap)
    asset.types_init(&load.types,heap)
    if data.loads==nil {data.loads=make([dynamic]^Source_Load,heap)}
    if _,append_error:=append(&data.loads,load);append_error!=nil {
        data_load_free(load)
        return nil
    }
    if data.jobs!=nil {jobs.run(data.jobs,jobs.OWNER,source_load_job,load,&load.counter)} else {source_load_job(load,jobs.OWNER)}
    return load
}

@(private)
data_loading :: proc(data:^Terrain_Data,id:base.Asset_Id) -> ^Source_Load {
    for load in data.loads {if load.id==id {return load}}
    return nil
}

// A job: the source of a load, its coarse grid and its chunks, in memory of its own.
@(private)
source_load_job :: proc(load:^Source_Load,worker:int) {
    context.allocator=runtime.heap_allocator()
    front:asset.Asset
    if asset.asset_load_front(&front,load.path,context.allocator)!=.None {return}
    defer asset.asset_close(&front)
    info,error:=asset.asset_row(&front,&load.types,"terrain",Source_Info)
    if error!=.None || info==nil {return}
    if info.kind==.Mesh {load.whole=true;return}
    id,read:=source_read(&load.entry.source,&front,&load.types,context.allocator,true,load.path)
    if !read || id!=load.id {return}
    load.entry.id,load.entry.stamp,load.entry.change=load.id,load.stamp,1
    load.ok=data_chunks_allocate(&load.entry,context.allocator,load.js,worker)
}

// Puts what a load read among the sources, waiting for its job; nil when it
// could not be read or does not fit. Frees the load.
@(private)
data_load_end :: proc(data:^Terrain_Data,load:^Source_Load,a:^host.Assets,problems:^core.Problems,terrains:^core.Table(Terrain)) -> (entry:^Data_Source) {
    if jobs.pending(&load.counter) {jobs.wait(load.js,jobs.OWNER,&load.counter)}
    for held,i in data.loads {if held==load {ordered_remove(&data.loads,i);break}}
    defer data_load_free(load)
    e:=source_owner(core.read(terrains),load.id)
    switch {
    case load.whole: entry=data_load(data,a,load.id,problems,e)
    case !load.ok: source_unread(problems,e,a,load.id)
    case len(data.entries)>=int(data.settings.sources):
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,e,"terrain.sources_full","terrain source %s is not loaded: %d sources are, as many as Terrain_Settings.sources allows; raise it, or share fewer sources among more terrains",host.assets_name(a,load.id,&name),data.settings.sources)
    case !data_fits(data,nil,source_cost(&load.entry.source),problems,e,a,load.id):
    case:
        if _,err:=append(&data.entries,load.entry);err!=nil {source_memory(problems,e,a,load.id);break}
        data.samples+=u32(source_cost(&load.entry.source))
        load.entry={}
        data.stats.loads+=1
        entry=&data.entries[len(data.entries)-1]
    }
    if entry==nil {
        if data.unread==nil {data.unread=make([dynamic]base.Asset_Id,runtime.heap_allocator())}
        append(&data.unread,load.id)
        return
    }
    for shared,index in terrains.values[:core.count(terrains)] {if shared.source==entry.id && shared.revision!=entry.source.revision {core.at(terrains,index).revision=entry.source.revision}}
    return
}

@(private)
data_load_free :: proc(load:^Source_Load) {
    if jobs.pending(&load.counter) {jobs.wait(load.js,jobs.OWNER,&load.counter)}
    heap:=runtime.heap_allocator()
    data_entry_free(&load.entry)
    asset.types_destroy(&load.types)
    delete(load.path,heap)
    free(load,heap)
}

// The version of what node i of entry shows: of its chunk, or of the last
// changed chunk under it.
@(private)
data_version :: #force_inline proc "contextless" (entry:^Data_Source,i:int) -> u32 {
    chunks:=len(entry.versions)
    return i<chunks?entry.versions[i]:entry.nodes[i-chunks]
}

// The errors of the nodes of a Heightfield, from the chunks up.
@(private)
data_errors :: proc(entry:^Data_Source) {
    q:=&entry.quad
    if len(entry.errors)!=quad_total(q) {return}
    for d in 1..=q.depth {for i in q.first[d]..<q.first[d+1] {node_errors_measure(&entry.source,q,entry.errors,i)}}
}

// After an edit of the inclusive region of samples low..high: the chunks it
// touched measure their levels again where their pages are in memory, and
// the errors of the nodes above grow with what changed.
@(private)
data_errors_edit :: proc(entry:^Data_Source,low,high:[3]int) {
    s:=&entry.source
    q:=&entry.quad
    if len(entry.errors)!=quad_total(q) {return}
    first,last:=chunk_range(s,{changed=true,low=low,high=high})
    for z in first.z..=last.z {for x in first.x..=last.x {
        index:=chunk_index(s,{i32(x),0,i32(z)})
        a,b,ok:=chunk_region(s,{i32(x),0,i32(z)})
        if index<0 || !ok || !source_region_held(s,a,b) {continue}
        chunk_errors_measure(s,{s=s},{x,z},&entry.errors[index])
    }}
    for d in 1..=q.depth {
        for z in first.z>>uint(d)..=last.z>>uint(d) {for x in first.x>>uint(d)..=last.x>>uint(d) {
            if node:=quad_index(q,d,{x,z});node>=0 {node_errors_measure(s,q,entry.errors,node,{low.xz,high.xz})}
        }}
    }
}

// The ranges of the nodes from those of their children, and of the chunks of
// a Mesh from its sections; a Volume chunk spans its region.
@(private)
data_ranges :: proc(entry:^Data_Source) {
    s:=&entry.source
    q:=&entry.quad
    if s.kind==.Mesh {for i in 0..<min(q.first[1],len(s.mesh_chunks)) {entry.ranges[i]={s.mesh_chunks[i].low.y,s.mesh_chunks[i].high.y}}}
    if s.kind==.Volume {for &range in entry.ranges {range={-HEIGHT_LIMIT,HEIGHT_LIMIT}}}
    for d in 1..=q.depth {for i in q.first[d]..<q.first[d+1] {
        range:=[2]f32{max(f32),-max(f32)}
        for c in quad_children(q,i) {if c>=0 {range={min(range.x,entry.ranges[c].x),max(range.y,entry.ranges[c].y)}}}
        entry.ranges[i]=range
    }}
}
@(private)
data_ready :: proc(data:^Terrain_Data,settings:Terrain_Settings,allocator:=context.allocator) -> bool {
    if data.ready {return true}
    settings:=settings
    if settings.sources==0 {settings.sources=TERRAIN_SETTINGS_DEFAULT.sources}
    if settings.chunks==0 {settings.chunks=TERRAIN_SETTINGS_DEFAULT.chunks}
    if settings.samples==0 {settings.samples=TERRAIN_SETTINGS_DEFAULT.samples}
    entries,error:=make([dynamic]Data_Source,0,int(settings.sources),allocator)
    if error!=nil {return false}
    data.settings,data.entries,data.ready=settings,entries,true
    return true
}
// Every chunk of the inclusive region of samples of change, or the sections a
// Mesh change marked, takes the next change of the source.
// The nodes above take it too, and the heights the chunks and nodes reach
// follow the samples.
@(private)
data_mark :: proc(entry:^Data_Source,change:Change) {
    entry.change+=1
    if change.mesh {
        for dirty,index in entry.source.mesh_changed {if dirty {data_mark_chunk(entry,index);data_mark_nodes(entry,index)}}
        data_ranges(entry)
        return
    }
    low,high:=chunk_range(&entry.source,change)
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        if index:=chunk_index(&entry.source,{i32(x),i32(y),i32(z)});index>=0 {data_mark_chunk(entry,index);data_mark_nodes(entry,index)}
    }}}
    data_ranges(entry)
}
// A chunk takes the change of the source: a page that came into memory marks
// only the chunks, whose build reads it.
@(private)
data_mark_chunk :: #force_inline proc(entry:^Data_Source,index:int) {
    entry.versions[index]=entry.change
    if !entry.dirty[index] {entry.dirty[index]=true;append(&entry.pending,u32(index))}
}
@(private)
data_mark_nodes :: proc(entry:^Data_Source,index:int) {
    q:=&entry.quad
    chunks:=q.first[1]
    for at:=quad_parent(q,index);at>=0;at=quad_parent(q,at) {
        entry.nodes[at-chunks]=entry.change
        if !entry.dirty[at] {entry.dirty[at]=true;append(&entry.pending,u32(at))}
    }
}
@(private)
data_mark_all :: proc(entry:^Data_Source) {
    if entry.source.kind==.Mesh {
        for &dirty in entry.source.mesh_changed {dirty=true}
        data_mark(entry,{changed=true,mesh=true})
        return
    }
    s:=&entry.source
    data_mark(entry,{changed=true,high={int(s.samples.x)-1,int(s.samples.y)-1,int(s.samples.z)-1}})
}
// The first terrain of a source: the entity a problem of the source is reported on.
@(private)
source_owner :: proc(terrains:core.Read(Terrain),id:base.Asset_Id) -> core.Entity {
    for value,row in terrains.table.values[:core.count(terrains)] {if value.source==id {return core.entity_at(terrains,row)}}
    return core.NONE
}

@(private)
source_unread :: proc(problems:^core.Problems,e:core.Entity,a:^host.Assets,id:base.Asset_Id) {
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,e,"terrain.source_unread","terrain source %s cannot be read: it is not in the assets, is not a .terrain or is damaged; set Terrain.source to a .terrain of the assets, or save the source again from the editor",host.assets_name(a,id,&name))
}

@(private)
source_memory :: proc(problems:^core.Problems,e:core.Entity,a:^host.Assets,id:base.Asset_Id) {
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,e,"terrain.memory","out of memory for terrain source %s or its chunks; it is tried again in the next frame: free memory, or make the source smaller",host.assets_name(a,id,&name))
}

// Whether a source of cost samples or vertices fits with the loaded ones,
// without replaced; else a problem of e says what it needs. The pieces it
// shows are kept within Terrain_Settings.chunks as it shows them.
@(private)
data_fits :: proc(data:^Terrain_Data,replaced:^Data_Source,cost:int,problems:^core.Problems,e:core.Entity,a:^host.Assets,id:base.Asset_Id) -> bool {
    samples:=int(data.samples)+cost
    if replaced!=nil {samples-=source_cost(&replaced.source)}
    if samples<=int(data.settings.samples) {return true}
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,e,"terrain.budget","terrain source %s does not fit: with the loaded ones it needs %d samples or vertices, and Terrain_Settings.samples allows %d; raise it, or make the source smaller",host.assets_name(a,id,&name),samples,data.settings.samples)
    return false
}

@(private)
data_load :: proc(data:^Terrain_Data,a:^host.Assets,id:base.Asset_Id,problems:^core.Problems,e:core.Entity) -> ^Data_Source {
    if len(data.entries)>=int(data.settings.sources) {
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,e,"terrain.sources_full","terrain source %s is not loaded: %d sources are, as many as Terrain_Settings.sources allows; raise it, or share fewer sources among more terrains",host.assets_name(a,id,&name),data.settings.sources)
        return nil
    }
    entry:=Data_Source{id=id,stamp=terrain_stamp(a,id),change=1}
    if !terrain_read(&entry.source,a,id,a.allocator,paged=true) {source_destroy(&entry.source);source_unread(problems,e,a,id);return nil}
    if !data_chunks_allocate(&entry,a.allocator,data.jobs) {data_entry_free(&entry);source_memory(problems,e,a,id);return nil}
    if !data_fits(data,nil,source_cost(&entry.source),problems,e,a,id) {data_entry_free(&entry);return nil}
    if _,err:=append(&data.entries,entry);err!=nil {data_entry_free(&entry);source_memory(problems,e,a,id);return nil}
    data.samples+=u32(source_cost(&entry.source))
    data.stats.loads+=1
    return &data.entries[len(data.entries)-1]
}
// Reads a source again; what fails keeps the one read before and is a
// problem of the first of terrains that shows it. The jobs that read it ended.
@(private)
data_reload :: proc(data:^Terrain_Data,entry:^Data_Source,a:^host.Assets,problems:^core.Problems,terrains:core.Read(Terrain)) -> bool {
    entry.stamp=terrain_stamp(a,entry.id)
    if !entry.stamp.found {return false}
    owner:=source_owner(terrains,entry.id)
    next:Source
    if !terrain_read(&next,a,entry.id,a.allocator,paged=true) {source_destroy(&next);source_unread(problems,owner,a,entry.id);return false}
    shape_changed:=next.kind!=entry.source.kind || next.samples!=entry.source.samples || next.cell!=entry.source.cell || next.chunk_cells!=entry.source.chunk_cells || next.mesh_origin!=entry.source.mesh_origin
    // Comparing gives next only pages of the source it replaces: it fits as they did.
    if !data_fits(data,entry,source_cost(&next),problems,owner,a,entry.id) {source_destroy(&next);return false}
    change:Change
    if !shape_changed {
        ok:bool
        if change,ok=source_compare(&next,&entry.source);!ok {
            source_destroy(&next);source_memory(problems,owner,a,entry.id)
            // What the comparison took away from the source is read again.
            data_mark_all(entry)
            return false
        }
    }
    before:=source_cost(&entry.source)
    if shape_changed {
        replacement:=Data_Source{id=entry.id,stamp=entry.stamp,change=entry.change+1,source=next}
        if !data_chunks_allocate(&replacement,a.allocator,data.jobs) {data_entry_free(&replacement);source_memory(problems,owner,a,entry.id);return false}
        data_entry_free(entry);entry^=replacement
    } else {
        source_destroy(&entry.source);entry.source=next
        // A page that does not read leaves its part of the coarse grid as the samples it holds.
        chunks:=entry.quad.first[1]
        if !source_coarse_build(&entry.source,entry.ranges[:chunks],entry.errors[:min(chunks,len(entry.errors))],data.jobs) {source_unread(problems,owner,a,entry.id)}
        data_ranges(entry)
        data_errors(entry)
        if change.changed {data_mark(entry,change)}
    }
    data.samples=u32(int(data.samples)-before+source_cost(&entry.source))
    data.stats.loads+=1
    return true
}

// What differs between next, read again, and s, of the same shape: the
// region of samples, or the sections of a Mesh it marks. Pages of next in
// their blocks take the values s holds of the same block. ok is false
// without memory.
@(private)
source_compare :: proc(next,s:^Source) -> (change:Change,ok:bool) {
    if next.kind==.Mesh {
        change.mesh=true
        for &chunk,i in next.mesh_chunks {if !mesh_equal(&chunk.geometry,&s.mesh_chunks[i].geometry) {next.mesh_changed[i]=true;change.changed=true}}
        if change.changed {
            geometry_changed,allocated:=mesh_selection(next)
            if !allocated {return}
            copy(geometry_changed,next.mesh_changed)
            mesh_mark_halo(next,s.mesh_chunks,geometry_changed)
        }
        whole:=len(next.slots)!=len(s.slots) || layers_reshape(next.info,s.info)
        if !whole {for value,i in next.slots {if value!=s.slots[i] {whole=true;break}}}
        if whole {
            for &dirty in next.mesh_changed {dirty=true}
            change.changed=true
        } else if low,high,differ:=grid_diff(&next.weights,&s.weights);differ {
            change.changed=mesh_mark_weights(next,low.xz,high.xz) || change.changed
        }
        return change,true
    }
    last:=[3]int{int(next.samples.x)-1,int(next.samples.y)-1,int(next.samples.z)-1}
    change.low=last
    widen :: proc(change:^Change,low,high:[3]int) {
        if !change.changed {change.low,change.high=low,high} else {
            for axis in 0..<3 {change.low[axis]=min(change.low[axis],low[axis]);change.high[axis]=max(change.high[axis],high[axis])}
        }
        change.changed=true
    }
    writer:Page_Writer
    if !page_writer_init(&writer,context.temp_allocator) {return}
    defer page_writer_destroy(&writer)
    low,high,differ:=grid_take(&next.heights,&s.heights,&writer,true)
    if differ {widen(&change,low,high)}
    if len(next.holes.pages)!=len(s.holes.pages) {
        widen(&change,{},{last.x,0,last.z})
    } else if low,high,differ=grid_take(&next.holes,&s.holes,&writer,false);differ {
        widen(&change,low,high+{1,0,1})
    }
    if low,high,differ=grid_take(&next.distances,&s.distances,&writer,false);differ {widen(&change,low,high)}
    if layers_reshape(next.info,s.info) {
        widen(&change,{},last)
    } else if low,high,differ=grid_take(&next.weights,&s.weights,&writer,false);differ {
        if next.kind==.Volume {widen(&change,low,high)} else {widen(&change,{low.x,0,low.z},{high.x,last.y,high.z})}
    }
    return change,true
}

// The meshes of the terrains of a World that is freed go with it.
@(step="release")
terrain_release :: proc(resident:^Terrain_Resident,app:^host.App) {
    if resident==nil {return}
    context.allocator=app.allocator
    stats:=resident.stats
    terrain_resident_free(resident)
    resident.stats=stats
}

terrain_resident_free :: proc(resident:^Terrain_Resident) {
    for &source in resident.sources {resident_source_free(resident,&source)}
    for &owner in resident.owners {resident_owner_free(&owner)}
    delete(resident.sources);delete(resident.owners);delete(resident.splits)
    piece_border_destroy(&resident.border)
    resident^={}
}
@(private)
resident_owner_free :: proc(owner:^Resident_Owner) {
    delete(owner.chunks);delete(owner.nodes);delete(owner.changed)
}
@(private)
resident_source_free :: proc(resident:^Terrain_Resident,source:^Resident_Source) {
    for chunk in source.chunks {
        if chunk.mesh=={} || resident.assets==nil {continue}
        host.assets_mesh_release(resident.assets,chunk.mesh)
        resident.stats.released+=1;resident.stats.meshes-=1
    }
    delete(source.chunks);delete(source.levels);delete(source.deep);delete(source.changed);delete(source.pages);delete(source.dirty);delete(source.pending)
    delete(source.join.cuts)
    source^={}
}
// The pieces of the source of entry for terrain e: what it shows of it,
// built at the levels it asks for. Made again when the quadtree changes.
@(private)
resident_source :: proc(resident:^Terrain_Resident,entry:^Data_Source,e:core.Entity,problems:^core.Problems) -> ^Resident_Source {
    found:=resident_source_find(resident,entry.id,e)
    count,chunks:=quad_total(&entry.quad),entry.quad.first[1]
    if found!=nil && found.quad==entry.quad && len(found.chunks)==count {return found}
    next:=Resident_Source{id=entry.id,owner=e,quad=entry.quad}
    allocator:=resident.assets.allocator
    e0,e1,e2,e3,e4,e5:runtime.Allocator_Error
    next.chunks,e0=make([]Resident_Chunk,count,allocator)
    next.levels,e1=make([]u8,chunks,allocator)
    next.deep,e2=make([]bool,chunks,allocator)
    next.changed,e3=make([dynamic]u32,0,count,allocator)
    next.dirty,e4=make([]bool,count,allocator)
    next.pending,e5=make([dynamic]u32,0,count,allocator)
    if e0!=nil || e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil || found==nil && append(&resident.sources,Resident_Source{})!=1 {
        delete(next.chunks,allocator);delete(next.levels,allocator);delete(next.deep,allocator);delete(next.changed)
        delete(next.dirty,allocator);delete(next.pending)
        source_memory(problems,e,resident.assets,entry.id)
        return nil
    }
    for &chunk in next.chunks[:chunks] {chunk.wanted.collision=true}
    for i in 0..<count {next.dirty[i]=true;append(&next.pending,u32(i))}
    if found==nil {found=&resident.sources[len(resident.sources)-1]} else {resident_source_free(resident,found)}
    found^=next
    // Its owner shows the pieces of the new count from the start.
    for &owner in resident.owners {if owner.entity==e && owner.source==entry.id {owner.full=true}}
    resident.marks+=1
    return found
}

@(private)
resident_source_find :: proc(resident:^Terrain_Resident,id:base.Asset_Id,owner:core.Entity) -> ^Resident_Source {
    for &source in resident.sources {if source.id==id && source.owner==owner {return &source}}
    return nil
}

@(private)
source_pending :: #force_inline proc(source:^Resident_Source,index:int) {
    if !source.dirty[index] {source.dirty[index]=true;append(&source.pending,u32(index))}
}

// What changed of the data of each source, by chunk and node, goes to the
// pieces of every terrain that shows it.
@(private)
data_pending_spread :: proc(data:^Terrain_Data,resident:^Terrain_Resident) {
    for &entry in data.entries {
        if len(entry.pending)==0 {continue}
        for &source in resident.sources {
            if source.id!=entry.id || len(source.dirty)!=len(entry.dirty) {continue}
            for index in entry.pending {source_pending(&source,int(index))}
        }
        for index in entry.pending {entry.dirty[index]=false}
        clear(&entry.pending)
    }
}
