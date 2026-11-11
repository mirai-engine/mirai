package scene

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:slice"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"

// A scene loads in phases, each where it does not hold the frame up. Jobs
// read and decompress its documents a round at a time: the main thread finds
// in the registry the files a round asks for (the scenes its With_Document
// references name and the prefabs its instances follow) and the next round
// reads them; the last one instantiates the scene in a World of its own,
// which the application does not read meanwhile. Then jobs read and decode
// the meshes, textures and materials it names that are not loaded, and the
// main thread gives them to the renderer, its part of the budget of the loads
// in each frame (host.Load_Budget): a texture larger than the bytes of a
// frame with its small levels, and the others over the frames that follow,
// and a mesh larger than them with all its geometry over those frames, which
// the load waits for, as for the first load of the .anim it can play
// (host.content_animations_start). What the jobs read is freed in jobs
// (host.app_assets_release). Between two frames that World trades its
// contents with the world, or joins it under the reference of a section.
// Scene_Loading and Section_Loading tell a loading screen how far it got.
// Without job threads the jobs run where they are asked, and load and
// replace, for whoever needs the scene at once (the editor, tests, agents),
// do every phase in the call.

// A load prepares its assets in at most this share of the job workers: the
// others are free for the work of the frames meanwhile.
LOAD_WORKERS_SHARE :: 4

Load_Phase :: enum u8 {
    Idle,
    Reading, // the documents, and instantiating them, in jobs
    Warming, // the assets the scene uses, read in jobs and given to the renderer a part of each frame
    Waiting, // a section: what the libraries prepare of the assets it names (Load_Waits)
}

// How far the load of a scene is, for a loading screen.
@(storage,keep)
Scene_Loading :: struct {
    phase:Load_Phase,
    scene:base.Asset_Id,
    done,total:int, // documents read of those found so far while Reading, assets given to the renderer while Warming
}

// How far the sections of the world loading apart are: one item each.
@(storage)
Section_Loading :: struct {
    items:[SECTION_LOADS]Section_Progress,
    count:int,
}

Section_Progress :: struct {
    entity:core.Entity, // of the Scene_Reference
    loading:Scene_Loading,
}

// The scene the world is, and how many times a scene replaced it: what a
// network session compares and follows.
@(storage,keep)
Scene_Root :: struct {
    scene:base.Asset_Id,
    changes:u32,
}

// Marks the World w is about to become as the scene id.
@(private)
root_set :: proc(w:core.World_Ref,id:base.Asset_Id) {
    if root:=core.world_storage_of(w,Scene_Root);root!=nil {root.scene,root.changes=id,root.changes+1}
}

// The load under way of the application: one at a time.
@(storage,host)
Scene_Loads :: struct {job:^Load_Job}

Load_Job :: struct {
    app:^host.App,
    request:Scene_Request,
    root:base.Asset_Id,
    salt:base.Entity_Id, // a section: the Id of its reference
    cooked:bool,
    far:bool, // only what draws a far form of its own, kept (far_keep), and what that names
    gated:bool, // a section: it waits for the libraries before it ends (Load_Phase.Waiting)
    whole:bool, // nothing on the screen to keep smooth: it has the job workers and the frames (host.assets_load_whole)
    passes:int, // frames it waited
    ready:bool, // a frame passed in which no library waited for what it names
    phase:Load_Phase,
    // Reading, in rounds: what the main thread found for a round, and what the round asked for that it has to find.
    queue:[dynamic]host.Assets_Source,
    wanted:[dynamic]base.Asset_Id,
    documents:map[base.Asset_Id]^asset.Asset, // nil: asked for, and not there or not readable
    asked:int, // documents given to the rounds
    read:int,  // of them, those a round is done with: written by the job
    types:asset.Types, // of the jobs: those of the assets are of the main thread
    world:rawptr,      // the World it instantiates in
    report:Report,
    error:Error,
    counter:jobs.Counter,
    names:[dynamic]base.Asset_Id, // what the World names, once instantiated
    animations:[dynamic]base.Asset_Id, // the .anim it can play: it ends once they are loaded
    // Warming.
    limits:host.Assets_Limits,
    items:[]Load_Item, // the meshes, textures and materials it names that are not loaded, each after what it takes
    next:int,          // the next item a job prepares
    taken:int,         // items given to the assets
    budget:u64,        // its id in the budget of the loads
    pieces:asset.Piece_Decoders, // the pieces of a large chunk decode at once on the job workers
    // What it did, for the records of the loads: what its jobs write while Reading, the main thread after.
    tally:host.Load_Tally,
    record:u64, // the record it opened (host.load_open); 0: a section or a far form
    started:time.Tick,
}

@(private)
Load_Item :: struct {
    prepared:host.Assets_Prepared,
    ready:bool, // a job prepared it
}

// Starts loading the scene id. nil, with the error, when it cannot start.
load_begin :: proc(app:^host.App,id:base.Asset_Id,request:Scene_Request={},salt:base.Entity_Id=0,far:=false) -> (job:^Load_Job,error:Error) {
    a:=app.assets
    if a==nil {return nil,.No_Assets}
    file,found:=asset.registry_find(&a.registry,id)
    if !found {return nil,.Not_Found}
    if file.kind!=asset.KIND_SCENE {return nil,.Invalid}
    // What the jobs write is of the heap, which any thread can use.
    heap:=runtime.heap_allocator()
    no_job:runtime.Allocator_Error
    if job,no_job=new(Load_Job,heap);no_job!=nil {return nil,.Out_Of_Memory}
    job^={app=app,request=request,root=id,salt=salt,cooked=a.indexed,far=far,phase=.Reading,started=time.tick_now()}
    if salt==0 && !far {job.record=host.load_open(app,.Scene,file.path)}
    job.queue=make([dynamic]host.Assets_Source,heap)
    job.wanted=make([dynamic]base.Asset_Id,heap)
    job.documents=make(map[base.Asset_Id]^asset.Asset,heap)
    job.names=make([dynamic]base.Asset_Id,heap)
    job.animations=make([dynamic]base.Asset_Id,heap)
    asset.types_init(&job.types,heap)
    source,known:=host.assets_source(a,id,heap)
    if !known {
        load_free(job)
        return nil,.Not_Found
    }
    job.world=host.app_world_create(app)
    if job.world==nil {
        host.assets_source_free(&source)
        load_free(job)
        return nil,.Out_Of_Memory
    }
    host.app_assets_building(app,job.world,true)
    _=schema_of(host.app_world_ref(app,job.world))
    job.documents[id]=nil
    append(&job.queue,source)
    job.asked=1
    load_run(job,load_read)
    return job,.None
}

load_free :: proc(job:^Load_Job) {
    if job==nil {return}
    // The jobs that prepare its assets take no other; the one that runs ends.
    intrinsics.atomic_store(&job.next,len(job.items))
    if jobs.pending(&job.counter) {jobs.wait(&job.app.jobs,jobs.OWNER,&job.counter)}
    if job.world!=nil {
        host.app_assets_building(job.app,job.world,false)
        host.app_world_free(job.app,job.world)
    }
    if job.budget!=0 {host.assets_load_close(job.app.assets,job.budget)}
    // A far form has no record: what it took counts in the current load.
    if job.far {host.load_job_merge(job.app,&job.tally)}
    heap:=runtime.heap_allocator()
    for &source in job.queue {host.assets_source_free(&source)}
    delete(job.queue);delete(job.wanted)
    for _,document in job.documents {
        if document==nil {continue}
        host.app_assets_release_file(job.app,document)
        free(document,heap)
    }
    delete(job.documents)
    for &item in job.items {host.app_assets_release(job.app,&item.prepared)}
    asset.piece_decoders_destroy(&job.pieces)
    delete(job.items,heap);delete(job.names);delete(job.animations)
    asset.types_destroy(&job.types)
    free(job,heap)
}

// Runs a phase of the load in a job, or here without job threads.
@(private)
load_run :: proc(job:^Load_Job,phase:proc(job:^Load_Job,worker:int)) {
    if jobs.worker_count(&job.app.jobs)>1 {jobs.run(&job.app.jobs,jobs.OWNER,phase,job,&job.counter)} else {phase(job,jobs.OWNER)}
}

// The documents of the load, as instantiate reads them.
@(private)
load_documents :: proc(job:^Load_Job) -> Documents {
    open :: proc(user:rawptr,id:base.Asset_Id) -> ^asset.Asset {
        job:=(^Load_Job)(user)
        return job.documents[id] or_else nil
    }
    return {job,open,&job.types,job.cooked}
}

// A round: reads the documents of the queue and asks for what they bring
// that was not asked for; the last one, which asks for nothing, instantiates
// the scene and lists what its World names.
@(private)
load_read :: proc(job:^Load_Job,worker:int) {
    context.allocator=runtime.heap_allocator()
    reading:=host.load_phase_begin(job.app,.Read,worker)
    exhausted:=false
    for &source in job.queue {
        document,no_document:=new(asset.Asset)
        if no_document!=nil || host.assets_source_open(&source,document)!=.None {
            exhausted||=no_document!=nil
            free(document)
            intrinsics.atomic_add(&job.read,1)
            continue
        }
        job.documents[source.id]=document
        intrinsics.atomic_add(&job.read,1)
        // What it brings: the prefabs its instances follow and the scenes its references load with it.
        view,view_error:=asset.scene_view(document,&job.types)
        if view_error!=.None {continue}
        for instance in view.instances {load_want(job,instance.prefab)}
        for &component in view.components {
            if component.name!="Scene_Reference" {continue}
            index,_:=asset.types_index(&job.types,Scene_Reference)
            values:=make([]Scene_Reference,len(component.entities),context.temp_allocator)
            if asset.scene_component_read(document,&component,&job.types.schema,index,mem.slice_to_bytes(values))!=.None {continue}
            for reference in values {
                if reference.rule==.With_Document && reference.state!=.Unloaded {load_want(job,reference.scene)}
            }
        }
    }
    documents_read:=len(job.queue)
    for &source in job.queue {host.assets_source_free(&source)}
    clear(&job.queue)
    host.load_phase_end(job.app,reading,documents_read,&job.tally)
    if exhausted {
        job.error=.Out_Of_Memory
        return
    }
    if job.documents[job.root]==nil {
        job.error=.Corrupt
        return
    }
    if len(job.wanted)>0 {return}
    w:=host.app_world_ref(job.app,job.world)
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    documents:=load_documents(job)
    root,error:=current(documents,job.documents[job.root],&resolved)
    if error!=.None {
        job.error=error
        return
    }
    making:=host.load_phase_begin(job.app,.Instantiate,worker)
    // One store per value until odin-lang/Odin#7937
    report,instantiated:=instantiate(w,root,&job.types,{documents=documents,salt=job.salt})
    host.load_phase_end(job.app,making,core.world_entities(w).alive,&job.tally)
    job.report=report
    job.error=instantiated
    if job.error!=.None {return}
    settling:=host.load_phase_begin(job.app,.Settle,worker)
    core.world_settle(w)
    if job.far {far_keep(w)}
    host.world_asset_ids(w,&job.names)
    host.load_phase_end(job.app,settling,0,&job.tally)
}

@(private)
load_want :: proc(job:^Load_Job,id:base.Asset_Id) {
    if id=={} || id in job.documents {return}
    job.documents[id]=nil
    append(&job.wanted,id)
}

// Advances a load by its part of the frame (host.Load_Budget); with all, to
// its end, waiting for its jobs. True once it is done, with or without an
// error: load_end or section_load_end takes it.
load_step :: proc(job:^Load_Job,all:=false) -> bool {
    app,a:=job.app,job.app.assets
    start:=time.tick_now()
    taken:=0
    defer if !all {host.assets_load_spend(a,time.duration_seconds(time.tick_since(start)),taken)}
    for {
        if job.phase==.Reading && jobs.pending(&job.counter) {
            if !all {return false}
            jobs.wait(&app.jobs,jobs.OWNER,&job.counter)
        }
        if job.error!=.None {return true}
        switch job.phase {
        case .Reading:
            if len(job.wanted)==0 {
                load_named(job)
                continue
            }
            for id in job.wanted {
                file,found:=asset.registry_find(&a.registry,id)
                if !found || file.kind!=asset.KIND_SCENE {continue}
                if source,known:=host.assets_source(a,id,runtime.heap_allocator());known {
                    append(&job.queue,source)
                    job.asked+=1
                }
            }
            clear(&job.wanted)
            load_run(job,load_read)
        case .Warming:
            return load_warm(job,all,start,&taken)
        case .Waiting:
            if !all && !job.ready {return false}
            job.phase=.Idle
            return true
        case .Idle:
            return true
        }
    }
}

// The World is instantiated: what reads it on this thread does, and the
// assets it names that are not loaded, with what they take, are read in jobs:
// also what the other assets it names take, as the meshes of a foliage
// source or of a prefab, but not what a scene of several roots takes, which
// is a section of its own.
@(private)
load_named :: proc(job:^Load_Job) {
    app,a:=job.app,job.app.assets
    host.app_assets_building(app,job.world,false)
    w:=host.app_world_ref(app,job.world)
    settling:=host.load_phase_begin(app,.Settle)
    propagate(w,app)
    references_resolve(w)
    host.load_phase_end(app,settling,0,&job.tally)
    // Textures, then materials, which take them, then meshes, which take materials.
    kinds:=[3]asset.Fourcc{asset.KIND_TEXTURE,asset.KIND_MATERIAL,asset.KIND_MESH}
    lists:[3][dynamic]base.Asset_Id
    for &list in lists {list=make([dynamic]base.Asset_Id,context.temp_allocator)}
    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    pending:=make([dynamic]base.Asset_Id,context.temp_allocator)
    append(&pending,..job.names[:])
    for len(pending)>0 {
        id:=pop(&pending)
        if id in seen {continue}
        seen[id]=true
        file,found:=asset.registry_find(&a.registry,id)
        if !found || host.assets_loaded(a,id) || file.kind==asset.KIND_SCENE && !asset.registry_prefab(file) {continue}
        for kind,at in kinds {if file.kind==kind {append(&lists[at],id)}}
        append(&pending,..asset.registry_dependencies(&a.registry,file))
    }
    count:=len(lists[0])+len(lists[1])+len(lists[2])
    items,no_items:=make([]Load_Item,count,runtime.heap_allocator())
    if no_items!=nil {
        job.error=.Out_Of_Memory
        return
    }
    job.items=items
    count=0
    for list in lists {
        for id in list {
            if source,known:=host.assets_source(a,id,runtime.heap_allocator());known {
                job.items[count].prepared.source=source
                count+=1
            }
        }
    }
    job.items=job.items[:count]
    host.content_animations_start(app,job.names[:],&job.animations)
    // A section loads ahead, far away: its textures come with their smallest
    // levels, and the frames that sample them ask for the others.
    job.limits=host.assets_limits(a,tail=job.salt!=0)
    job.phase=.Warming
    job.budget=host.assets_load_open(a)
    if job.whole {host.assets_load_whole(a,job.budget)}
    if workers:=jobs.worker_count(&app.jobs);workers>1 {
        asset.piece_decoders_init(&job.pieces,&app.jobs,runtime.heap_allocator())
        share:=workers if job.whole else max(workers/LOAD_WORKERS_SHARE,1)
        for _ in 0..<min(share,count) {jobs.run(&app.jobs,jobs.OWNER,load_prepare,job,&job.counter)}
    }
}

// A job: prepares the items no other job took yet.
@(private)
load_prepare :: proc(job:^Load_Job,worker:int) {
    context.allocator=runtime.heap_allocator()
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    decoder,no_decoder:=new(asset.Decoder)
    defer free(decoder)
    lent:=decoder if no_decoder==nil && asset.decoder_init(decoder)==.None else nil
    defer if decoder!=nil {asset.decoder_destroy(decoder)}
    if lent!=nil && job.pieces.decoders!=nil {lent.pieces,lent.worker=&job.pieces,worker}
    for {
        at:=intrinsics.atomic_add(&job.next,1)
        if at>=len(job.items) {return}
        host.assets_prepare(&job.items[at].prepared,job.limits,&types,lent)
        intrinsics.atomic_store(&job.items[at].ready,true)
    }
}

// Gives the assets what the jobs prepared, in order, while the part of the
// frame of the load lasts: its seconds, and its bytes for the renderer.
@(private)
load_warm :: proc(job:^Load_Job,all:bool,start:time.Tick,taken:^int) -> bool {
    app,a:=job.app,job.app.assets
    threads:=jobs.worker_count(&app.jobs)>1
    if all && jobs.pending(&job.counter) {jobs.wait(&app.jobs,jobs.OWNER,&job.counter)}
    share:host.Load_Share
    if !all {share=host.assets_load_share(a,app.stats.frames,job.budget)}
    first:=true
    defer if !first {host.assets_commit(a)}
    for job.taken<len(job.items) {
        // Its first asset of the frame goes if its bytes fit, whatever the time: every load moves in every frame.
        if !all && !first && time.duration_seconds(time.tick_since(start))>=share.seconds {return false}
        item:=&job.items[job.taken]
        if !intrinsics.atomic_load(&item.ready) {
            if threads {return false}
            host.assets_prepare(&item.prepared,job.limits,&job.types)
            item.ready=true
        }
        cost:=host.assets_prepared_cost(&item.prepared,over_frames=!all)
        // Alone, the frame is its own for its first asset whatever it takes.
        if !all && !(first && share.alone) && taken^+cost>share.bytes {
            if first {host.assets_load_alone(a,job.budget)}
            return false
        }
        if !host.app_assets_take(app,&item.prepared,over_frames=!all,tally=&job.tally) {return false}
        job.taken+=1
        taken^+=cost
        first=false
    }
    // The jobs that prepared it are done before what they read goes.
    if jobs.pending(&job.counter) {jobs.wait(&app.jobs,jobs.OWNER,&job.counter)}
    // The levels of the textures and the geometry of the meshes that go over frames are there before it ends.
    if !all && host.app_assets_uploading(app) {return false}
    // Nothing it can play holds a rest pose while its .anim compresses.
    if host.content_animations_pending(app,job.animations[:],wait=all) {return false}
    if job.gated && !all {
        job.phase=.Waiting
        return false
    }
    job.phase=.Idle
    return true
}

// The assets the libraries still prepare for the loads of a World that wait
// for them (Load_Phase.Waiting): a load ends once a frame passed in which
// none of what it names was named here. A library names them in each frame
// until they are ready (load_wait).
@(storage,queue)
Load_Waits :: struct {assets:core.Queue(base.Asset_Id)}

load_wait :: proc(waits:^Load_Waits,id:base.Asset_Id) {if waits!=nil {core.push(&waits.assets,id)}}

// What the loads of sections of a World that wait for the libraries name, appended to out.
loads_waiting :: proc(loads:^Section_Loads,out:^[dynamic]base.Asset_Id) {
    if loads==nil {return}
    for l in loads.items {if l.job!=nil && l.job.phase==.Waiting {append(out,..l.job.names[:])}}
    for l in loads.far {if l.job!=nil && l.job.phase==.Waiting {append(out,..l.job.names[:])}}
}

// The loads that wait, once a frame: ready when a frame passed in which no
// library named what they name.
@(private)
loads_waits_settle :: proc(loads:^Section_Loads,waited:[]base.Asset_Id) {
    settle :: proc(job:^Load_Job,waited:[]base.Asset_Id) {
        if job==nil || job.phase!=.Waiting {return}
        named:=false
        for id in waited {if slice.contains(job.names[:],id) {named=true;break}}
        if job.passes>0 && !named {job.ready=true}
        job.passes+=1
    }
    for l in loads.items {settle(l.job,waited)}
    for l in loads.far {settle(l.job,waited)}
}

// What the world has once a load is done: what it read, in place of what it
// held, or as it was after an error. What has core.Keep passes with what
// hangs from it, and with the fields it waits for. Frees the load.
load_end :: proc(job:^Load_Job,w:core.World_Ref) -> (report:Report,error:Error) {
    defer load_free(job)
    defer host.load_job_end(job.app,job.record,&job.tally,core.world_entities(w).alive if error==.None else 0,error_text(error))
    if job.error!=.None {return job.report,job.error}
    if w.info!=job.app.info || w.place!=.World {return job.report,.Invalid}
    loaded:=host.app_world_ref(job.app,job.world)
    // The run goes on in the World that loaded: its requests, its clock, its settings, and what keeps across scenes.
    if !core.world_run_copy(loaded,w) {return job.report,.Out_Of_Memory}
    if keeps:=core.world_table_of(w,core.Keep);keeps!=nil && core.count(keeps)>0 {
        kept:=make([]core.Entity,core.count(keeps),context.temp_allocator)
        for &e,i in kept {e=core.entity_at(keeps,i)}
        made:[dynamic]core.Entity
        defer delete(made)
        if !core.world_union(loaded,w,core.NONE,&made,kept) {return job.report,.Out_Of_Memory}
        from,to:=core.world_storage_of(w,Unresolved_References),core.world_storage_of(loaded,Unresolved_References)
        if from!=nil && to!=nil {
            for item in from.items {
                index:=core.entity_index(item.entity)
                if !core.alive(core.world_entities(w),item.entity) || index>=len(made) || made[index]==core.NONE {continue}
                moved:=item
                moved.entity=made[index]
                append(&to.items,moved)
            }
        }
        core.world_settle(loaded)
    }
    root_set(loaded,job.root)
    core.world_swap(w.info,w.data,job.world)
    // A swap moves the versions of the tables on: the records look at them
    // after it. One without memory for it stays asked for: scene_sections
    // looks again, and reports it.
    _=records_look(w)
    return job.report,.None
}

// Starts loading the scene of the Scene_Reference of e, to hang from it:
// what the streaming of sections asks. A scene that holds the section is a
// Cycle (section_path names them).
section_load_begin :: proc(app:^host.App,w:core.World_Ref,e:core.Entity) -> (job:^Load_Job,error:Error) {
    references:=core.world_table_of(w,Scene_Reference)
    ids:=core.world_table_of(w,core.Id)
    if references==nil || ids==nil {return nil,.Invalid}
    reference:=(^Scene_Reference)(core.raw_find(core.raw(references),type_info_of(Scene_Reference),e))
    if reference==nil {return nil,.Invalid}
    if slice.contains(section_path(w,e),reference.scene) {return nil,.Cycle}
    return load_begin(app,reference.scene,{},core.id_of(core.read(ids),e))
}

// What a section load leaves. Before what it loaded joins the world under
// the reference e, what the section left dormant takes its place there
// (sleepers_apply) and, asked loaded and off, it is held; then e takes what
// it loaded, its unbounded volumes rule in its box, its fields that wait for
// other sections wait in the world, and it and each section that loaded with
// it get their record. A section that loaded with it whose scene holds e is a
// Cycle. Frees the load.
section_load_end :: proc(job:^Load_Job,w:core.World_Ref,e:core.Entity) -> (report:Report,error:Error) {
    defer load_free(job)
    defer section_record(job,error)
    if job.error!=.None {return job.report,job.error}
    references:=core.world_table_of(w,Scene_Reference)
    if references==nil || core.raw_find(core.raw(references),type_info_of(Scene_Reference),e)==nil {return job.report,.Invalid}
    reference:=(^Scene_Reference)(core.raw_find(core.raw(references),type_info_of(Scene_Reference),e))^
    apart:=host.app_world_ref(job.app,job.world)
    around:=section_path(w,e)
    inner:=core.world_table_of(apart,Scene_Reference)
    if inner!=nil {
        for row in 0..<core.raw_count(core.raw(inner)) {
            r:=(^Scene_Reference)(core.raw_value(core.raw(inner),type_info_of(Scene_Reference),row))
            if r.loaded!={} && slice.contains(around,r.scene) {return job.report,.Cycle}
        }
    }
    locals:=apart_locals(apart)
    sleepers:=sleepers_apply(w,apart,e)
    held:=section_wanted(core.world_storage_of(w,Section_Views),e,reference)==.Loaded
    if held {apart_hold(apart)}
    core.world_settle(apart)
    // The tables the union stamps: those apart has rows of, and Parent, which hangs its roots from e.
    fresh:=make([]bool,len(w.info.tables),context.temp_allocator)
    for &info,at in w.info.tables {
        if info.place!=apart.place {continue}
        if t:=core.world_table_at(apart,&info);t!=nil && (core.raw_count(t)>0 || info.type==core.Parent && core.world_entities(apart).alive>0) {fresh[at]=true}
    }
    // The section each entity of apart is of: e's (none), or one that loaded with it.
    apart_es:=core.world_entities(apart)
    of:=make([]core.Entity,len(apart_es.generation),context.temp_allocator)
    if apart_parents:=core.world_table_of(apart,core.Parent);apart_parents!=nil && inner!=nil {
        for generation,index in apart_es.generation {
            x:=core.entity_make(index,generation)
            if index==0 || !core.alive(apart_es,x) {continue}
            parent,_:=core.get(apart_parents,x)
            of[index]=core.ancestor_with(core.read(apart_parents),core.read(inner),parent.entity)
        }
    }
    made:[dynamic]core.Entity
    defer delete(made)
    if !core.world_union(w,apart,e,&made) {return job.report,.Invalid}
    joined :: proc(made:[]core.Entity,e:core.Entity) -> core.Entity {
        index:=core.entity_index(e)
        return e!=core.NONE && index<len(made)?made[index]:core.NONE
    }
    sleepers_join(w,e,&sleepers,made[:],held)
    if r:=(^Scene_Reference)(core.raw_edit(core.raw(references),type_info_of(Scene_Reference),e));r!=nil {r.loaded,r.held=job.root,held}
    from,to:=core.world_storage_of(apart,Unresolved_References),core.world_storage_of(w,Unresolved_References)
    if from!=nil && to!=nil {
        for item in from.items {
            moved:=item
            moved.entity=joined(made[:],item.entity)
            if moved.entity!=core.NONE {append(&to.items,moved)}
        }
    }
    // Records, each with the shapes of its entities as they joined: of each section that loaded with it, and its own.
    record_fill :: proc(record:^Section_Record,apart:core.World_Ref,section:core.Entity,of,made:[]core.Entity,fresh:[]bool,took:[]core.Entity) -> bool {
        no_fresh:runtime.Allocator_Error
        if record.fresh,no_fresh=slice.clone(fresh);no_fresh!=nil {return false}
        es:=core.world_entities(apart)
        mine:=make([dynamic]core.Entity,context.temp_allocator)
        into:=make([dynamic]core.Entity,context.temp_allocator)
        for generation,index in es.generation {
            x:=core.entity_make(index,generation)
            if index==0 || !core.alive(es,x) || of[index]!=section || x==section {continue}
            append(&mine,x)
            append(&into,made[index])
        }
        shapes_take(apart,&record.shapes,mine[:],into[:])
        record.shaped=true
        for x in took {if of[core.entity_index(x)]==section {append(&record.changed,made[core.entity_index(x)])}}
        return true
    }
    recorded:=true
    if inners:=core.world_storage_of(apart,Section_Records);inners!=nil {
        for &record in inners.items {
            added,listed:=records_add(w,joined(made[:],record.reference),record.locals)
            recorded&&=listed && (added==nil || record_fill(added,apart,record.reference,of,made[:],fresh,sleepers.took[:]))
        }
    }
    own,listed:=records_add(w,e,locals)
    recorded&&=listed && (own==nil || record_fill(own,apart,core.NONE,of,made[:],fresh,sleepers.took[:]))
    return job.report,.None if recorded else .Out_Of_Memory
}

// The record of a section load that ended (host.load_section).
@(private)
section_record :: proc(job:^Load_Job,error:Error) {
    a:=job.app.assets
    name:string
    if file,found:=asset.registry_find(&a.registry,job.root);found {name=file.path}
    entities:=core.world_entities(host.app_world_ref(job.app,job.world)).alive if job.world!=nil else 0
    host.load_section(job.app,name,job.started,&job.tally,entities,error_text(error))
}

// The Ids of its scene that a section load brought of its own: not those of
// the sections that loaded with it.
@(private)
apart_locals :: proc(apart:core.World_Ref) -> []base.Entity_Id {
    locals:=make([dynamic]base.Entity_Id,context.temp_allocator)
    members:=core.world_table_of(apart,Section_Member)
    parents:=core.world_table_of(apart,core.Parent)
    references:=core.world_table_of(apart,Scene_Reference)
    if members==nil {return nil}
    for row in 0..<core.raw_count(core.raw(members)) {
        x:=core.raw(members).entities[row]
        if parents!=nil && references!=nil {
            parent,placed:=core.get(parents,x)
            if placed && core.ancestor_with(core.read(parents),core.read(references),parent.entity)!=core.NONE {continue}
        }
        append(&locals,(^Section_Member)(core.raw_value(core.raw(members),type_info_of(Section_Member),row)).local)
    }
    return locals[:]
}

// A section that loads asked loaded and off joins off: what hangs from its
// reference under Disabled, with Section_Held.
@(private)
apart_hold :: proc(apart:core.World_Ref) {
    parents:=core.world_table_of(apart,core.Parent)
    disabled:=core.world_table_of(apart,core.Disabled)
    marks:=core.world_table_of(apart,Section_Held)
    if disabled==nil || marks==nil {return}
    es:=core.world_entities(apart)
    for generation,index in es.generation {
        x:=core.entity_make(index,generation)
        if index==0 || !core.alive(es,x) || parents!=nil && core.raw_row(core.raw(parents),x)>=0 || core.raw_row(core.raw(disabled),x)>=0 {continue}
        core.add(disabled,x,core.Disabled{})
        core.add(marks,x,Section_Held{})
    }
}

// What a loading screen shows of a load.
load_progress :: proc(job:^Load_Job) -> Scene_Loading {
    if job==nil {return {}}
    switch job.phase {
    case .Reading:
        // What a round that ended asked for counts once it is not running.
        total:=job.asked
        if !jobs.pending(&job.counter) {total+=len(job.wanted)}
        return {phase=.Reading,scene=job.root,done=intrinsics.atomic_load(&job.read),total=total}
    case .Warming: return {phase=.Warming,scene=job.root,done=job.taken,total=len(job.items)}
    case .Waiting: return {phase=.Waiting,scene=job.root,done=job.taken,total=len(job.items)}
    case .Idle:
    }
    return {phase=.Idle,scene=job.root}
}

// How far the sections of the world loading apart are.
@(private)
sections_progress :: proc(loading:^Section_Loading,loads:^Section_Loads) {
    loading^={}
    for l in loads.items {
        if l.job==nil {continue}
        loading.items[loading.count]={l.entity,load_progress(l.job)}
        loading.count+=1
    }
}
