package terrain

import "base:runtime"
import "core:slice"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"

// Builds of chunks and readings of pages run in std/jobs. A job reads the
// live source: whatever changes or frees it (an edit, a reading of its file,
// a copy of the World over it) waits for the jobs that read it. Each keeps
// the epoch of the data, the source, the chunk or page and the change it
// read; a result whose chunk changed meanwhile is let go. A result is taken
// by the next call of terrain_update of the phase that made it, which waits
// for it if it has not ended: when it shows does not depend on the threads.
// A chunk that shows nothing yet and is needed now is taken in the call that
// made it.

Work_Kind :: enum u8 {None,Build,Page}

Work_Slot :: struct {
    counter:jobs.Counter,
    kind:Work_Kind,
    urgent:bool,      // taken in the call that made it
    patient:bool,     // Build: taken once it ended, without waiting for it
    reads:bool,       // its job reads the source: what writes the source waits for it
    phase:core.Phase, // of the call that made it
    epoch:u32,        // of the data then
    source:^Source,
    id:base.Asset_Id,
    owner:core.Entity, // Build: the terrain whose piece it is
    index:int,        // of the chunk or node, or the id of the page in its grid
    version:u32,      // Build: the change of the chunk or node it read
    key:Chunk_Key,
    limits:host.Assets_Limits, // Build: of the assets its mesh goes to
    ok:bool,
    mesh:Chunk_Mesh,  // Build
    border:Piece_Border, // Build of a node: its border as it was asked for
    join:Chunk_Join,     // Build: what it reads of the joins of its terrain, its cuts in cuts
    cuts:[dynamic]Join_Cut,
    grid:Grid_Kind,   // Page
    block:Page_Block, // Page: the block it reads, its own borrowed
    file:string,      // Page: borrowed from the source
    read:Page_Reader, // Page: room for a block and its decoder
    page:[]u8,        // Page: the values it decodes, until they go to the grid (shared_make)
    band:f32,         // Page of a Volume: how far its distances may reach
    allocator:runtime.Allocator,      // of the slot
}

// Of every slot, at most this share runs jobs that can wait: the rest stays
// for chunks that cannot.
@(private) WORK_SLOTS_MIN :: 16
@(private) WORK_SLOTS_MAX :: 32

// The slots of the data, made the first time a world of it runs its jobs, and
// the job system its jobs run on: none for a single thread, where each runs
// when it is made.
@(private)
work_ready :: proc(data:^Terrain_Data,job_system:^jobs.Job_System,allocator:runtime.Allocator) -> bool {
    workers:=jobs.worker_count(job_system)
    data.jobs=workers>1?job_system:nil
    if len(data.work)>0 {return true}
    slots,error:=make([]Work_Slot,clamp(2*workers,WORK_SLOTS_MIN,WORK_SLOTS_MAX),allocator)
    if error!=nil {return false}
    for &slot in slots {
        chunk_mesh_init(&slot.mesh,allocator);slot.allocator=allocator
        for i in 0..<4 {slot.border.sides[i]=make([dynamic]u8,allocator);slot.border.corners[i]=make([dynamic]u8,allocator)}
    }
    data.work=slots
    return true
}

@(private)
work_free :: proc(data:^Terrain_Data) {
    for &slot in data.work {
        chunk_mesh_destroy(&slot.mesh)
        piece_border_destroy(&slot.border)
        delete(slot.cuts)
        page_reader_destroy(&slot.read,slot.allocator)
        shared_free(slot.page)
    }
    if len(data.work)>0 {delete(data.work,data.work[0].allocator)}
    data.work=nil
}

// Waits for the jobs that read source, or every one for nil.
@(private)
work_wait :: proc(data:^Terrain_Data,source:^Source) {
    for &slot in data.work {
        if slot.kind==.None || source!=nil && (!slot.reads || slot.source!=source && slot.join.ground!=source) || !jobs.pending(&slot.counter) {continue}
        jobs.wait(data.jobs,jobs.OWNER,&slot.counter)
    }
}

// Whether a slot holds a job or a result over source, nil for any.
@(private)
work_busy :: proc(data:^Terrain_Data,source:^Source) -> bool {
    for &slot in data.work {if slot.kind!=.None && (source==nil || slot.source==source || slot.join.ground==source) {return true}}
    return false
}

// A free slot; urgent may take any, the others leave half of them free.
@(private)
work_slot :: proc(data:^Terrain_Data,urgent:bool) -> ^Work_Slot {
    used:=0
    for &slot in data.work {if slot.kind!=.None && !slot.urgent {used+=1}}
    if !urgent && 2*used>=len(data.work) {return nil}
    for &slot in data.work {if slot.kind==.None {return &slot}}
    return nil
}

@(private)
work_start :: proc(data:^Terrain_Data,slot:^Work_Slot) {
    if data.jobs==nil {work_run(slot,jobs.OWNER);return}
    jobs.run(data.jobs,jobs.OWNER,work_run,slot,&slot.counter)
}

// The build of a chunk or a node, from its source as it is now; a node of a
// Heightfield takes a copy of its border.
@(private)
work_build :: proc(data:^Terrain_Data,slot:^Work_Slot,entry:^Data_Source,owner:core.Entity,index:int,key:Chunk_Key,urgent:bool,phase:core.Phase,limits:host.Assets_Limits,border:^Piece_Border=nil,join:^Terrain_Join=nil) -> bool {
    // Before the slot is taken: without room for the border it stays free.
    if border!=nil {for i in 0..<4 {
        if resize(&slot.border.sides[i],len(border.sides[i]))!=nil || resize(&slot.border.corners[i],len(border.corners[i]))!=nil {return false}
        copy(slot.border.sides[i][:],border.sides[i][:])
        copy(slot.border.corners[i][:],border.corners[i][:])
    }}
    slot.owner=owner
    slot.kind,slot.urgent,slot.phase,slot.epoch,slot.limits=.Build,urgent,phase,data.epoch,limits
    slot.source,slot.id,slot.index,slot.version,slot.key,slot.ok=&entry.source,entry.id,index,data_version(entry,index),key,false
    slot.patient,slot.reads=piece_levels(&entry.source,&entry.quad,index),true
    slot.join={}
    clear(&slot.cuts)
    if join!=nil && key.join!=0 {
        if join.ground!={} {
            if ground:=data_find(data,join.ground);ground!=nil && ground.source.kind==.Heightfield {slot.join={ground=&ground.source,offset=join.offset,lift=join.lift}}
        } else {append(&slot.cuts,..join.cuts[:])}
    }
    slot.join.cuts=slot.cuts[:]
    work_start(data,slot)
    return true
}

// The reading of page index of a grid of a source from its block. False
// without memory for its values.
@(private)
work_page :: proc(data:^Terrain_Data,slot:^Work_Slot,entry:^Data_Source,grid:Grid_Kind,index:int,phase:core.Phase) -> bool {
    s:=&entry.source
    if slot.read.block==nil && !page_reader_init(&slot.read,slot.allocator) {return false}
    block:Page_Block
    size,count:=4,0
    switch grid {
    case .Heights: block=grid_block(&s.heights,index);_,count=grid_page_extent(&s.heights,index)
    case .Weights: block=grid_block(&s.weights,index);_,count=grid_page_extent(&s.weights,index)
    case .Holes: block,size=grid_block(&s.holes,index),1;_,count=grid_page_extent(&s.holes,index)
    case .Distances: block=grid_block(&s.distances,index);_,count=grid_page_extent(&s.distances,index)
    }
    made:bool
    if slot.page,made=shared_make(u8,count*size,s.allocator);!made {return false}
    slot.band=s.cell*SDF_BAND_CELLS
    slot.kind,slot.urgent,slot.patient,slot.reads,slot.phase,slot.epoch=.Page,false,false,true,phase,data.epoch
    slot.source,slot.id,slot.index,slot.grid,slot.block,slot.file,slot.ok=s,entry.id,index,grid,block,s.file,false
    work_start(data,slot)
    return true
}

// Whether a job reads page index of a grid of source.
@(private)
work_reading :: proc(data:^Terrain_Data,source:^Source,grid:Grid_Kind,index:int) -> bool {
    for &slot in data.work {if slot.kind==.Page && slot.source==source && slot.grid==grid && slot.index==index {return true}}
    return false
}

@(private)
work_run :: proc(slot:^Work_Slot,worker:int) {
    switch slot.kind {
    case .None:
    case .Build:
        if !slot.reads {chunk_render_prepare(.Volume,&slot.mesh,slot.limits,true);return}
        s:=slot.source
        q:=quad_of(s)
        if slot.index<q.first[1] {
            slot.ok=chunk_build(s,chunk_coord(s,slot.index),&slot.mesh,slot.key.collision,slot.key.lod,slot.join)
        } else {
            slot.ok=node_build(s,&q,slot.index,slot.key.lod,&slot.border,&slot.mesh,slot.join)
        }
        if slot.ok && !slot.patient {chunk_render_prepare(s.kind,&slot.mesh,slot.limits)}
    case .Page:
        slot.ok=page_load(slot.block,slot.file,&slot.read,slot.page)
        if !slot.ok {break}
        switch slot.grid {
        case .Heights: slot.ok=page_valid(slice.reinterpret([]f32,slot.page),height_valid)
        case .Weights: slot.ok=page_valid(slice.reinterpret([]Weights,slot.page),weights_full)
        case .Holes: slot.ok=page_valid(slot.page,hole_valid)
        case .Distances: slot.ok=distances_within(slice.reinterpret([]f32,slot.page),slot.band)
        }
    }
}

// Whether a piece shows in the levels of its clusters: a node of a Volume.
@(private)
piece_levels :: #force_inline proc "contextless" (s:^Source,q:^Quad,index:int) -> bool {return s.kind==.Volume && index>=q.first[1]}

// Lets go of what a slot holds; it is free again.
@(private)
work_release :: proc(slot:^Work_Slot) {
    shared_free(slot.page)
    slot.page=nil
    slot.kind,slot.source,slot.file=.None,nil,""
    slot.join={}
}

// Whether a slot is to be taken now: in the next call of the phase that made
// it, after waiting for its job if it has not ended.
@(private)
work_due :: proc(data:^Terrain_Data,slot:^Work_Slot,phase:core.Phase) -> bool {
    if slot.kind==.None || slot.phase!=phase && !slot.urgent {return false}
    // A node of a Volume, which builds the surface of many chunks, is taken
    // once it ended, and its levels are a job of their own that reads no
    // source: an edit does not wait for them.
    for {
        if jobs.pending(&slot.counter) {
            if slot.patient && !slot.urgent {return false}
            jobs.wait(data.jobs,jobs.OWNER,&slot.counter)
        }
        if !slot.patient || !slot.reads || !slot.ok {return true}
        slot.reads=false
        work_start(data,slot)
    }
}
