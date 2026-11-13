package host

import "base:intrinsics"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:core"
import render "mirai:render"
import "mirai:std/base"

// What the last loads of the application took, for whoever asks where their
// seconds went (profile.load of the editor, the log of the player): the last
// load of each kind, phase by phase, with its assets by kind and the slowest
// of them. A load of a scene or a Play is the current one from when it opens
// until it is resident, or another opens: it gets what happens meanwhile
// wherever it happens (the assets that load at once, the physics and the
// navigation of the ticks, the loop functions), and its phases go to the
// profiler as zones while it records. It is ready once it is the world or the
// document, and resident at the end of the first frame after that which drew
// with nothing it waits for busy (Load_Busy): no asset loaded in the frame,
// none uploading, no pipeline being made, and nothing a library reports
// busy; when a game loop runs, after one of its ticks too. A load in phases
// (engine/scene) and a section count what their jobs do apart (Load_Tally)
// and give it when they end. Phases are timed with the clock of App.step_ns;
// nothing allocates per entity or per asset.

LOAD_SLOWEST :: 16   // assets a load keeps: the slowest
LOAD_FUNCTIONS :: 16 // loop functions a load keeps once it ends: the costliest
LOAD_NAME_BYTES :: 256
LOAD_FUNCTION_BYTES :: 64
LOAD_NO_ZONE :: -1 // the worker of a phase inside a loop function: its own zone holds it

Load_Kind :: enum u8 {
    Scene,   // a scene became the document or the world: scene.open, a scene a game asks for, the start scene of the player
    Play,    // a Play of the editor started from the document
    Section, // a section joined the world
}

Load_State :: enum u8 {
    None,
    Loading,     // not resident yet
    Done,        // resident
    Interrupted, // another load opened before it was resident
    Failed,
}

Load_Phase :: enum u8 {
    Startup,     // the player before its first frame: window, device, the registry of the assets
    Read,        // reading and decompressing the documents
    Instantiate, // making the entities and their components
    Settle,      // settling the tables, propagating transforms, resolving references
    Editor,      // what the editor does with it: runs stopped, its history, its prefabs
    Animations,  // waiting for the .anim the world can play
    World_Copy,  // copying the document for Play
    Plugins,     // what the plugins do to start a Play
    Assets,      // assets given to the renderer on the main thread, read and decoded there when they load at once
    Prepare,     // assets read, decoded or compressed in jobs, summed over the workers
    Physics,     // bodies and their shapes made in the ticks
    Collision,   // of Physics: the collision of meshes built (their trees)
    Nav_Bake,    // the baked navigation read into its meshes
    Nav_Tiles,   // navigation tiles built in jobs, summed over the workers
}

// The phases timed on several job workers at once: their sum can exceed the wall time.
LOAD_PHASES_SUMMED :: bit_set[Load_Phase]{.Prepare,.Nav_Tiles}

// The zone of each phase in the recordings of the profiler.
LOAD_PHASE_ZONES :: [Load_Phase]string{
    .Startup="load.startup",.Read="load.read",.Instantiate="load.instantiate",.Settle="load.settle",
    .Editor="load.editor",.Animations="load.animations",.World_Copy="load.world_copy",.Plugins="load.plugins",
    .Assets="load.assets",.Prepare="load.prepare",.Physics="load.physics",.Collision="load.collision",
    .Nav_Bake="load.nav_bake",.Nav_Tiles="load.nav_tiles",
}

Load_Asset :: enum u8 {Mesh,Texture,Material,Animation,Sound,Interface,Plugin} // Interface: .ui, .font, .strings, .prompts and .sound_set; Plugin: what a plugin reads itself, as a .navmesh

// What a load waits for before it is resident.
Load_Busy :: enum u32 {
    Assets,     // an asset loaded in the frame
    Uploads,    // levels or geometry going to the GPU over frames, or textures and meshes arriving (app_assets_arriving)
    Animations, // the first load of an .anim compresses
    Pipelines,  // pipelines of programs, or the shaders of the project, being made
    Sections,   // sections loading
    Physics,    // bodies that wait for the next tick
    Navigation, // navigation tiles building
}
Load_Busy_Set :: bit_set[Load_Busy;u32]

Load_Time :: struct {
    ns:i64,
    count:i64, // what the phase went through: documents, entities, shapes, tiles
}

Load_Assets :: struct {
    count:int,
    failed:int,
    later:int, // finished after the load was ready
    bytes:i64, // of their files
    ns:i64,
}

Load_Asset_Time :: struct {
    id:base.Asset_Id,
    kind:Load_Asset,
    bytes:i64,
    ns:i64,    // its own time: read, decode and upload, in a job and on the main thread, without the assets it loaded inside
    later:bool,
    job:bool,  // part of it ran in a job
}

// What a load did: what a job of a load in phases counts apart, and part of each record.
Load_Tally :: struct {
    phases:[Load_Phase]Load_Time,
    assets:[Load_Asset]Load_Assets,
    slowest:[LOAD_SLOWEST]Load_Asset_Time, // the slowest first
    slowest_count:int,
}

Load_Wait :: struct {
    until_ns:i64, // since it opened: the end of the last frame it was busy
    frames:int,
}

Load_Function :: struct {
    name:[LOAD_FUNCTION_BYTES]u8,
    length:int,
    ns:i64,
}

Load_Record :: struct {
    using tally:Load_Tally,
    id:u64,
    kind:Load_Kind,
    state:Load_State,
    name:[LOAD_NAME_BYTES]u8, // the path of what loaded
    name_length:int,
    failure:[LOAD_NAME_BYTES]u8,
    failure_length:int,
    started:time.Tick,
    ready:bool,
    ready_ns:i64,    // since it opened, until it was the document or the world
    resident_ns:i64, // since it opened, until the end of the first frame with all of it resident
    ended_ns:i64,    // since it opened, until it ended in any state
    ticks:u64,       // App.stats.ticks once ready
    frames:int,      // frames that ended while it loaded
    entities:int,    // of the world once ready
    busy:Load_Busy_Set, // as the last frame left it
    waits:[Load_Busy]Load_Wait,
    functions:[LOAD_FUNCTIONS]Load_Function, // once it ended: the costliest first
    function_count:int,
}

Load_Profile :: struct {
    records:[Load_Kind]Load_Record,
    current:Load_Kind,
    loading:bool, // records[current] is Loading
    next:u64,     // id of the next record
    children:i64, // ns of the assets loaded inside the one that loads at once on the thread of the assets
    loaded:bool,  // an asset loaded in the frame
    reported,reported_busy:u32, // Load_Busy_Set reported in the frame by the libraries, and of them those busy (atomic)
    reports:Load_Busy_Set,      // as the libraries last reported them
    startup_ns:i64, // of the player, for its first record
    // What the loop functions took while the current record loaded, by index of App.info.steps.
    steps_seen:[]u64,
    steps_spent:[]u64,
    logged:[Load_Kind]u64, // the records load_profile_text gave already
}

// Opens the record of a load of kind, which becomes the current one: one of
// another kind still loading is Interrupted, one of the same kind replaced.
// Its id.
load_open :: proc(app:^App,kind:Load_Kind,name:string) -> u64 {
    p:=&app.load_profile
    if p.loading && p.current!=kind {load_close(app,&p.records[p.current],.Interrupted)}
    p.next+=1
    r:=&p.records[kind]
    r^={id=p.next,kind=kind,state=.Loading,started=time.tick_now()}
    r.name_length=copy(r.name[:],name)
    if kind==.Scene && p.startup_ns>0 {
        r.phases[.Startup]={p.startup_ns,1}
        p.startup_ns=0
    }
    p.current,p.loading=kind,true
    p.children,p.loaded=0,false
    load_steps_start(app)
    return r.id
}

// Whether a load is not resident yet: what a loading screen stays up for.
load_under_way :: proc "contextless" (app:^App) -> bool {return app.load_profile.loading}

// The record of kind is the document or the world now, with its entities
// (-1: those of App.world). Again while it loads, it is ready later.
load_ready :: proc(app:^App,kind:Load_Kind,entities:=-1) {
    p:=&app.load_profile
    r:=&p.records[kind]
    if r.state!=.Loading {return}
    r.ready=true
    r.ready_ns=time.duration_nanoseconds(time.tick_since(r.started))
    r.ticks=app.stats.ticks
    r.entities=entities
    if entities<0 {r.entities=app.info!=nil && app.world!=nil?core.world_entities(app_world_ref(app,app.world)).alive:0}
}

// The load of kind did not happen, and why.
load_fail :: proc(app:^App,kind:Load_Kind,why:string) {
    r:=&app.load_profile.records[kind]
    if r.state!=.Loading {return}
    r.failure_length=copy(r.failure[:],why)
    load_close(app,r,.Failed)
}

// The player measured how long it took to start before its first frame.
load_startup :: proc(app:^App,ns:i64) {app.load_profile.startup_ns=ns}

Load_Scope :: struct {
    start:time.Tick,
    zone:base.Profile_Scope,
    phase:Load_Phase,
}

// A phase timed until load_phase_end, a zone on the ring of worker while the
// profiler records (PROFILE_MAIN on the main thread, LOAD_NO_ZONE inside a
// loop function). Any thread.
load_phase_begin :: proc "contextless" (app:^App,phase:Load_Phase,worker:=PROFILE_MAIN) -> (scope:Load_Scope) {
    scope.phase=phase
    if worker!=LOAD_NO_ZONE && profile_active(app) {
        zones:=LOAD_PHASE_ZONES
        scope.zone=base.profile_begin(&app.profiler.profile,worker,zones[phase])
    }
    scope.start=time.tick_now()
    return
}

// Ends a phase, which went through count, into tally, or the current load
// without one. Any thread.
load_phase_end :: proc "contextless" (app:^App,scope:Load_Scope,count:=0,tally:^Load_Tally=nil) {
    ns:=time.duration_nanoseconds(time.tick_since(scope.start))
    base.profile_end(scope.zone)
    load_phase_add(app,scope.phase,ns,count,tally)
}

// A phase measured elsewhere, as a job measures what it did.
load_phase_add :: proc "contextless" (app:^App,phase:Load_Phase,ns:i64,count:=0,tally:^Load_Tally=nil) {
    t:=tally if tally!=nil else load_current(app)
    if t==nil {return}
    intrinsics.atomic_add(&t.phases[phase].ns,ns)
    intrinsics.atomic_add(&t.phases[phase].count,i64(count))
}

// A library reports whether what it does for the loads goes on, each time it
// runs: what it reports stays until it reports again. Any thread.
load_report :: proc "contextless" (app:^App,busy:Load_Busy,on:bool) {
    p:=&app.load_profile
    bit:=transmute(u32)Load_Busy_Set{busy}
    intrinsics.atomic_or(&p.reported,bit)
    if on {intrinsics.atomic_or(&p.reported_busy,bit)}
}

// The tally of the current load; nil while none loads.
load_current :: proc "contextless" (app:^App) -> ^Load_Tally {
    p:=&app.load_profile
    return &p.records[p.current].tally if p.loading else nil
}

Load_Asset_Scope :: struct {
    start:time.Tick,
    outer:i64,
}

// Around an asset that loads on the thread of the assets: its own time comes
// without that of the assets it loads inside. p may be nil.
load_asset_begin :: proc(p:^Load_Profile) -> Load_Asset_Scope {
    if p==nil {return {}}
    scope:=Load_Asset_Scope{time.tick_now(),p.children}
    p.children=0
    return scope
}

// Ends the scope of an asset: into tally, or the current load without one.
// worker_ns is what a job did of it. False when nothing loaded (stale, or
// loaded meanwhile): the scope only counts as time inside the one around it.
load_asset_end :: proc(p:^Load_Profile,scope:Load_Asset_Scope,id:base.Asset_Id,kind:Load_Asset,bytes:i64,failed:bool,worker_ns:=i64(0),tally:^Load_Tally=nil,loaded:=true) {
    if p==nil {return}
    total:=time.duration_nanoseconds(time.tick_since(scope.start))
    own:=max(total-p.children,0)
    p.children=scope.outer+total
    if loaded {load_asset_done(p,id,kind,bytes,own,worker_ns,failed,tally)}
}

// An asset that loaded, not in a scope: own is what the thread that loads
// it did, which counts in phase, worker_ns what a job did. Into tally, or the
// current load without one.
load_asset_done :: proc(p:^Load_Profile,id:base.Asset_Id,kind:Load_Asset,bytes,own,worker_ns:i64,failed:bool,tally:^Load_Tally=nil,phase:=Load_Phase.Assets) {
    if p==nil {return}
    p.loaded=true
    t:=tally
    later:=false
    if t==nil && p.loading {
        t=&p.records[p.current].tally
        later=p.records[p.current].ready
    }
    if t==nil {return}
    load_tally_asset(t,{id=id,kind=kind,bytes=bytes,ns=own+worker_ns,later=later,job=worker_ns>0},failed)
    load_phase_add_tally(t,phase,own)
    if worker_ns>0 {load_phase_add_tally(t,.Prepare,worker_ns)}
}

// An asset that loaded, into a tally.
load_tally_asset :: proc(t:^Load_Tally,item:Load_Asset_Time,failed:bool) {
    k:=&t.assets[item.kind]
    k.count+=1
    k.bytes+=item.bytes
    k.ns+=item.ns
    if item.later {k.later+=1}
    if failed {k.failed+=1}
    load_slowest_insert(t,item)
}

// What a tally holds, added to another.
load_tally_merge :: proc(into,from:^Load_Tally) {
    for &phase,at in into.phases {
        phase.ns+=from.phases[at].ns
        phase.count+=from.phases[at].count
    }
    for &k,at in into.assets {
        k.count+=from.assets[at].count
        k.failed+=from.assets[at].failed
        k.later+=from.assets[at].later
        k.bytes+=from.assets[at].bytes
        k.ns+=from.assets[at].ns
    }
    for item in from.slowest[:from.slowest_count] {load_slowest_insert(into,item)}
}

@(private="file")
load_slowest_insert :: proc(t:^Load_Tally,item:Load_Asset_Time) {
    at:=t.slowest_count
    for at>0 && t.slowest[at-1].ns<item.ns {at-=1}
    if at>=LOAD_SLOWEST {return}
    copy(t.slowest[at+1:],t.slowest[at:LOAD_SLOWEST-1])
    t.slowest[at]=item
    t.slowest_count=min(t.slowest_count+1,LOAD_SLOWEST)
}

// A load in phases (engine/scene) is the world now, with its entities, or
// failed (why): the record it opened takes what its jobs did, when it is
// still that one; else the current load does.
load_job_end :: proc(app:^App,record:u64,tally:^Load_Tally,entities:int,why:="") {
    p:=&app.load_profile
    r:=&p.records[.Scene]
    if record==0 || r.id!=record || r.state!=.Loading {
        load_job_merge(app,tally)
        return
    }
    load_tally_merge(&r.tally,tally)
    if why!="" {load_fail(app,.Scene,why)} else {load_ready(app,.Scene,entities)}
}

// What the jobs of a load that has no record of its own did, into the current load.
load_job_merge :: proc(app:^App,tally:^Load_Tally) {
    p:=&app.load_profile
    if p.loading {load_tally_merge(&p.records[p.current].tally,tally)}
}

// A section joined the world, or failed to (why): its record, whole, and what
// its jobs did, also into the current load.
load_section :: proc(app:^App,name:string,started:time.Tick,tally:^Load_Tally,entities:int,why:="") {
    p:=&app.load_profile
    load_job_merge(app,tally)
    p.next+=1
    r:=&p.records[.Section]
    r^={id=p.next,kind=.Section,started=started,ready=why=="",entities=entities}
    r.tally=tally^
    r.name_length=copy(r.name[:],name)
    r.failure_length=copy(r.failure[:],why)
    r.ended_ns=time.duration_nanoseconds(time.tick_since(started))
    r.ready_ns=r.ended_ns if r.ready else 0
    r.resident_ns=r.ready_ns
    r.state=.Done if r.ready else .Failed
}

// At the end of each frame: what the current load waits for, and its end
// once a frame drew with all of it resident.
load_profile_frame :: proc(app:^App,drawn:bool) {
    p:=&app.load_profile
    reported:=transmute(Load_Busy_Set)intrinsics.atomic_exchange(&p.reported,0)
    busy_reported:=transmute(Load_Busy_Set)intrinsics.atomic_exchange(&p.reported_busy,0)
    p.reports=p.reports-reported+busy_reported
    loaded:=p.loaded
    p.loaded=false
    if !p.loading {return}
    r:=&p.records[p.current]
    r.frames+=1
    load_steps_add(app)
    busy:=p.reports
    if loaded {busy+={.Assets}}
    if app_assets_uploading(app) || app_assets_arriving(app)>0 {busy+={.Uploads}}
    if render.renderer_pipelines_pending(app.renderer) || len(app.shaders.loads)>0 {busy+={.Pipelines}}
    if load_animations_pending(app) {busy+={.Animations}}
    now:=time.duration_nanoseconds(time.tick_since(r.started))
    for b in busy {
        r.waits[b].until_ns=now
        r.waits[b].frames+=1
    }
    r.busy=busy
    // A game loop that runs shows the world once it ticked: what its fixed phase makes comes then.
    ticked:=app.played_count==0 || app.stats.ticks>r.ticks
    if busy=={} && r.ready && ticked && (drawn || app.renderer==nil) {
        r.resident_ns=now
        load_close(app,r,.Done)
    }
}

@(private="file")
load_animations_pending :: proc(app:^App) -> bool {
    c:=app.content
    if c==nil {return false}
    for &entry in c.animations {if entry.load!=nil {return true}}
    return false
}

@(private)
load_close :: proc(app:^App,r:^Load_Record,state:Load_State) {
    p:=&app.load_profile
    r.state=state
    r.ended_ns=time.duration_nanoseconds(time.tick_since(r.started))
    if p.loading && &p.records[p.current]==r {
        p.loading=false
        load_steps_add(app)
        load_functions_keep(app,r)
    }
}

// The time of the loop functions starts counting for the current record.
@(private="file")
load_steps_start :: proc(app:^App) {
    p:=&app.load_profile
    n:=len(app.step_ns)
    if len(p.steps_seen)!=n {
        delete(p.steps_seen,app.allocator)
        delete(p.steps_spent,app.allocator)
        p.steps_seen,p.steps_spent=nil,nil
        if n==0 {return}
        seen,a:=make([]u64,n,app.allocator)
        spent,b:=make([]u64,n,app.allocator)
        if a!=nil || b!=nil {
            delete(seen,app.allocator)
            delete(spent,app.allocator)
            return
        }
        p.steps_seen,p.steps_spent=seen,spent
    }
    copy(p.steps_seen,app.step_ns)
    slice.zero(p.steps_spent)
}

// What the loop functions took since the last look. Whoever reads App.step_ns
// clears it between frames: what it holds then counts whole.
@(private="file")
load_steps_add :: proc(app:^App) {
    p:=&app.load_profile
    if len(p.steps_seen)!=len(app.step_ns) {return}
    for ns,i in app.step_ns {
        p.steps_spent[i]+=ns-p.steps_seen[i] if ns>=p.steps_seen[i] else ns
        p.steps_seen[i]=ns
    }
}

@(private="file")
load_functions_keep :: proc(app:^App,r:^Load_Record) {
    p:=&app.load_profile
    r.function_count=0
    if app.info==nil || len(p.steps_spent)!=len(app.info.steps) {return}
    top:[LOAD_FUNCTIONS]int
    count:=load_functions_top(p.steps_spent,top[:])
    for index,i in top[:count] {
        f:=&r.functions[i]
        f.length=copy(f.name[:],app.info.steps[index].name)
        f.ns=i64(p.steps_spent[index])
    }
    r.function_count=count
}

// The indices of the costliest functions of spent, the costliest first.
@(private="file")
load_functions_top :: proc(spent:[]u64,top:[]int) -> (count:int) {
    for ns,i in spent {
        if ns==0 {continue}
        at:=count
        for at>0 && spent[top[at-1]]<ns {at-=1}
        if at>=len(top) {continue}
        copy(top[at+1:],top[at:len(top)-1])
        top[at]=i
        count=min(count+1,len(top))
    }
    return
}

load_profile_destroy :: proc(app:^App) {
    p:=&app.load_profile
    delete(p.steps_seen,app.allocator)
    delete(p.steps_spent,app.allocator)
    p^={}
}

// ---------------------------------------------------------------- summary

Load_Phase_Summary :: struct {phase:Load_Phase,ms:f64,count:i64,summed:bool}
Load_Assets_Summary :: struct {kind:Load_Asset,using totals:Load_Assets,ms:f64}
Load_Function_Summary :: struct {name:string,ms:f64}
Load_Wait_Summary :: struct {busy:Load_Busy,until_ms:f64,frames:int}

// A record as whoever answers about it reads it: phases, kinds of asset and
// waits that took time, the costliest first, and the loop functions that
// ran meanwhile (live while it loads).
Load_Summary :: struct {
    id:u64,
    kind:Load_Kind,
    state:Load_State,
    name,failure:string,
    ready:bool,
    ready_ms,resident_ms,elapsed_ms:f64,
    frames,entities:int,
    waiting:Load_Busy_Set,
    phases:[]Load_Phase_Summary,
    assets:[]Load_Assets_Summary,
    slowest:[]Load_Asset_Time,
    functions:[]Load_Function_Summary,
    waits:[]Load_Wait_Summary,
}

load_ms :: proc "contextless" (ns:i64) -> f64 {return f64(ns)/1e6}

// The summary of the last load of kind, with at most top slowest assets and
// functions; false when there was none. Strings point into the record and the
// steps: read it before the next frame.
load_summary :: proc(app:^App,kind:Load_Kind,top:int,allocator:=context.allocator) -> (out:Load_Summary,ok:bool) {
    p:=&app.load_profile
    r:=&p.records[kind]
    if r.state==.None {return}
    context.allocator=allocator
    out.id,out.kind,out.state=r.id,r.kind,r.state
    out.name=string(r.name[:r.name_length])
    out.failure=string(r.failure[:r.failure_length])
    out.ready,out.ready_ms,out.resident_ms=r.ready,load_ms(r.ready_ns),load_ms(r.resident_ns)
    out.elapsed_ms=load_ms(r.ended_ns if r.state!=.Loading else time.duration_nanoseconds(time.tick_since(r.started)))
    out.frames,out.entities=r.frames,r.entities
    if r.state==.Loading {out.waiting=r.busy}
    phases:=make([dynamic]Load_Phase_Summary)
    for t,phase in r.phases {
        if t.ns>0 || t.count>0 {append(&phases,Load_Phase_Summary{phase,load_ms(t.ns),t.count,phase in LOAD_PHASES_SUMMED})}
    }
    slice.sort_by(phases[:],proc(a,b:Load_Phase_Summary) -> bool {return a.ms>b.ms})
    out.phases=phases[:]
    assets:=make([dynamic]Load_Assets_Summary)
    for k,kind in r.assets {
        if k.count>0 {append(&assets,Load_Assets_Summary{kind,k,load_ms(k.ns)})}
    }
    slice.sort_by(assets[:],proc(a,b:Load_Assets_Summary) -> bool {return a.ms>b.ms})
    out.assets=assets[:]
    out.slowest=r.slowest[:min(r.slowest_count,max(top,0))]
    functions:=make([dynamic]Load_Function_Summary)
    if r.state==.Loading && p.loading && p.current==kind {
        load_steps_add(app)
        if app.info!=nil && len(p.steps_spent)==len(app.info.steps) {
            indices:[LOAD_FUNCTIONS]int
            count:=load_functions_top(p.steps_spent,indices[:])
            for index in indices[:min(count,top)] {append(&functions,Load_Function_Summary{app.info.steps[index].name,load_ms(i64(p.steps_spent[index]))})}
        }
    } else {
        for &f in r.functions[:min(r.function_count,top)] {append(&functions,Load_Function_Summary{string(f.name[:f.length]),load_ms(f.ns)})}
    }
    out.functions=functions[:]
    waits:=make([dynamic]Load_Wait_Summary)
    for w,busy in r.waits {
        if w.frames>0 {append(&waits,Load_Wait_Summary{busy,load_ms(w.until_ns),w.frames})}
    }
    slice.sort_by(waits[:],proc(a,b:Load_Wait_Summary) -> bool {return a.until_ms>b.until_ms})
    out.waits=waits[:]
    return out,true
}

// A record that ended and was not given yet, as lines of text for a log (the
// player prints them); "" when there is none.
load_profile_text :: proc(app:^App,top:int,allocator:=context.allocator) -> string {
    p:=&app.load_profile
    b:=strings.builder_make(allocator)
    for kind in Load_Kind {
        r:=&p.records[kind]
        if r.state==.None || r.state==.Loading || p.logged[kind]==r.id {continue}
        p.logged[kind]=r.id
        s,_:=load_summary(app,kind,top,context.temp_allocator)
        name:=s.name if s.name!="" else "(unnamed)"
        switch s.state {
        case .Done:        fmt.sbprintf(&b,"mirai: load %v %s: ready at %.0f ms, resident at %.0f ms, %d entities\n",s.kind,name,s.ready_ms,s.resident_ms,s.entities)
        case .Failed:      fmt.sbprintf(&b,"mirai: load %v %s failed after %.0f ms: %s\n",s.kind,name,s.elapsed_ms,s.failure)
        case .Interrupted: fmt.sbprintf(&b,"mirai: load %v %s interrupted after %.0f ms\n",s.kind,name,s.elapsed_ms)
        case .None,.Loading:
        }
        if len(s.phases)>0 {
            strings.write_string(&b,"  phases:")
            for phase in s.phases {fmt.sbprintf(&b," %v %.0f ms%s",phase.phase,phase.ms,phase.summed?" (summed)":"")}
            strings.write_byte(&b,'\n')
        }
        if len(s.assets)>0 {
            strings.write_string(&b,"  assets:")
            for k in s.assets {fmt.sbprintf(&b," %v %d (%.1f MB) %.0f ms",k.kind,k.count,f64(k.bytes)/(1<<20),k.ms)}
            strings.write_byte(&b,'\n')
        }
        if len(s.slowest)>0 {
            strings.write_string(&b,"  slowest:")
            for item in s.slowest {
                text:[base.ASSET_ID_TEXT]u8
                fmt.sbprintf(&b," %s %.0f ms",assets_name(app.assets,item.id,&text),load_ms(item.ns))
            }
            strings.write_byte(&b,'\n')
        }
        if len(s.functions)>0 {
            strings.write_string(&b,"  functions:")
            for f in s.functions {fmt.sbprintf(&b," %s %.0f ms",f.name,f.ms)}
            strings.write_byte(&b,'\n')
        }
        if len(s.waits)>0 {
            strings.write_string(&b,"  waited for:")
            for w in s.waits {fmt.sbprintf(&b," %v until %.0f ms",w.busy,w.until_ms)}
            strings.write_byte(&b,'\n')
        }
    }
    return strings.to_string(b)
}

@(private="file")
load_phase_add_tally :: proc "contextless" (t:^Load_Tally,phase:Load_Phase,ns:i64) {
    intrinsics.atomic_add(&t.phases[phase].ns,ns)
}
