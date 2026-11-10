package editor

import "core:fmt"
import "core:strings"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"

// profile.load: where the seconds of the last loads went (host.Load_Profile),
// phase by phase, by kind of asset and by the waits after it was ready.

Profile_Load_Kind :: enum u8 {All,Scene,Play,Section}

Api_Profile_Load_Params :: struct {
    kind:Profile_Load_Kind `mirai:"optional,label=Which load; All: the last of each kind there was"`,
    top:int `mirai:"optional,min=1,max=16,clamp,label=Slowest assets and loop functions of each load"`,
}

Profile_Load_Phase_Out :: struct {name:string,ms:f64,count:i64,summed:bool}
Profile_Load_Assets_Out :: struct {kind:string,count,failed,after_ready:int,mb,ms:f64}
Profile_Load_Asset_Out :: struct {asset,kind:string,mb,ms:f64,after_ready,in_job:bool}
Profile_Load_Function_Out :: struct {name:string,ms:f64}
Profile_Load_Wait_Out :: struct {what:string,until_ms:f64,frames:int}
Profile_Load_Out :: struct {
    kind,state,name,failure:string,
    ready_ms,resident_ms,elapsed_ms:f64,
    frames,entities:int,
    waiting:[]string,
    phases:[]Profile_Load_Phase_Out,
    assets:[]Profile_Load_Assets_Out,
    slowest:[]Profile_Load_Asset_Out,
    functions:[]Profile_Load_Function_Out,
    waits:[]Profile_Load_Wait_Out,
    notes:[]string,
}
Profile_Loads_Out :: struct {loads:[]Profile_Load_Out}

Api_Profile_Load_Phase :: struct {
    name:host.Load_Phase,
    ms:f32,
    count:int `mirai:"label=What it went through: documents for Read, entities for Instantiate and World_Copy, bodies made or let go for Physics, meshes for Collision, tiles for Nav_Bake and Nav_Tiles"`,
    summed:bool `mirai:"label=Timed on several job workers at once: it can exceed the wall time"`,
}
Api_Profile_Load_Assets :: struct {
    kind:host.Load_Asset `mirai:"label=Interface: ui, font, strings, prompts and sound sets; Plugin: what a plugin reads itself, as a navmesh"`,
    count,failed:int,
    after_ready:int `mirai:"label=Finished after the load was ready: loaded on demand in the frames after it, or in jobs"`,
    mb:f32 `mirai:"label=MiB of their files"`,
    ms:f32 `mirai:"label=Their own time, on the main thread and in jobs"`,
}
Api_Profile_Load_Asset :: struct {
    asset:[API_PATH_BYTES]u8 `mirai:"text"`,
    kind:host.Load_Asset,
    mb:f32,
    ms:f32 `mirai:"label=Its own time: read, decode and give to the renderer, without the assets it loaded inside"`,
    after_ready:bool,
    in_job:bool `mirai:"label=Part of it was read or decoded or compressed in a job"`,
}
Api_Profile_Load_Function :: struct {
    name:[PROFILE_NAME_BYTES]u8 `mirai:"text"`,
    ms:f32 `mirai:"label=In all the frames while it loaded"`,
}
Api_Profile_Load_Wait :: struct {
    what:host.Load_Busy,
    until_ms:f32 `mirai:"label=Since it began: the end of the last frame it was busy"`,
    frames:int `mirai:"label=Frames it was busy"`,
}
Api_Profile_Load :: struct {
    kind:host.Load_Kind,
    state:host.Load_State `mirai:"label=Loading: not resident yet, ask again; Interrupted: another load began first"`,
    name:[API_PATH_BYTES]u8 `mirai:"text,label=Path of the scene"`,
    failure:[API_PATH_BYTES]u8 `mirai:"text,label=Why it failed"`,
    ready_ms:f32 `mirai:"label=Since it began, until it was the document or the world; 0 while not"`,
    resident_ms:f32 `mirai:"label=Since it began, until the end of the first frame after it was ready that drew with nothing busy"`,
    elapsed_ms:f32 `mirai:"label=Since it began, until it ended or now"`,
    frames:int `mirai:"label=Frames while it loaded"`,
    entities:int,
    waiting:[]host.Load_Busy `mirai:"label=While Loading: what the last frame was busy with"`,
    phases:[]Api_Profile_Load_Phase `mirai:"label=The costliest first; Collision is part of Physics; Physics Collision Nav_Bake and Nav_Tiles happen in the ticks, inside physics_step and navigation_build"`,
    assets:[]Api_Profile_Load_Assets `mirai:"label=By kind, the costliest first"`,
    slowest:[]Api_Profile_Load_Asset `mirai:"label=The slowest assets, the slowest first"`,
    functions:[]Api_Profile_Load_Function `mirai:"label=The loop functions that cost the most while it loaded; none for a section"`,
    waits:[]Api_Profile_Load_Wait `mirai:"label=What it waited for before it was resident, the one that ended last first"`,
    notes:[][PROFILE_NOTE_BYTES]u8 `mirai:"text,label=How to read it and what to look at first"`,
}
Api_Profile_Loads :: struct {
    loads:[]Api_Profile_Load,
}

@(private)
api_profile_load :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Profile_Load_Params)
    Asked :: struct {kind:Profile_Load_Kind}
    asked:=Asked{p.kind}
    loading :: proc(s:^Session,user:rawptr) -> bool {
        kind:=(^Asked)(user).kind
        for one in host.Load_Kind {
            if kind!=.All && int(kind)-1!=int(one) {continue}
            if summary,found:=host.load_summary(s.app,one,1);found && summary.state==.Loading {return true}
        }
        return false
    }
    api_settle(s,&asked,loading)
    context.allocator=context.temp_allocator
    loads:=make([dynamic]Profile_Load_Out)
    manual:=false
    if st:=api_state(s);st!=nil {manual=st.manual}
    for kind in host.Load_Kind {
        if p.kind!=.All && int(p.kind)-1!=int(kind) {continue}
        summary,found:=host.load_summary(s.app,kind,p.top)
        if found {append(&loads,profile_load_out(s,summary,manual))}
    }
    if len(loads)==0 {
        what:=p.kind==.All?"":fmt.tprintf("%v ",p.kind)
        api.call_failf(call,api.SERVER_ERROR,"No %sload yet: scene.open, play.start or a section that loads makes one",what)
        return
    }
    api_profile_write(call,Profile_Loads_Out{loads[:]})
}

@(private)
profile_load_out :: proc(s:^Session,l:host.Load_Summary,manual:bool) -> (out:Profile_Load_Out) {
    out.kind,out.state=fmt.tprint(l.kind),fmt.tprint(l.state)
    out.name,out.failure=strings.clone(l.name),strings.clone(l.failure)
    out.ready_ms,out.resident_ms,out.elapsed_ms=profile_ms(l.ready_ms),profile_ms(l.resident_ms),profile_ms(l.elapsed_ms)
    out.frames,out.entities=l.frames,l.entities
    waiting:=make([dynamic]string)
    for busy in l.waiting {append(&waiting,fmt.tprint(busy))}
    out.waiting=waiting[:]
    phases:=make([]Profile_Load_Phase_Out,len(l.phases))
    for phase,i in l.phases {phases[i]={fmt.tprint(phase.phase),profile_ms(phase.ms),phase.count,phase.summed}}
    out.phases=phases
    assets:=make([]Profile_Load_Assets_Out,len(l.assets))
    for k,i in l.assets {assets[i]={fmt.tprint(k.kind),k.count,k.failed,k.later,profile_mb(k.bytes),profile_ms(k.ms)}}
    out.assets=assets
    slowest:=make([]Profile_Load_Asset_Out,len(l.slowest))
    for item,i in l.slowest {
        text:[base.ASSET_ID_TEXT]u8
        name:=strings.clone(host.assets_name(s.app.assets,item.id,&text))
        slowest[i]={name,fmt.tprint(item.kind),profile_mb(item.bytes),profile_ms(host.load_ms(item.ns)),item.later,item.job}
    }
    out.slowest=slowest
    functions:=make([]Profile_Load_Function_Out,len(l.functions))
    for f,i in l.functions {functions[i]={strings.clone(f.name),profile_ms(f.ms)}}
    out.functions=functions
    waits:=make([]Profile_Load_Wait_Out,len(l.waits))
    for w,i in l.waits {waits[i]={fmt.tprint(w.busy),profile_ms(w.until_ms),w.frames}}
    out.waits=waits
    out.notes=profile_load_notes(l,manual)
    return
}

@(private)
profile_mb :: proc(bytes:i64) -> f64 {return profile_ms(f64(bytes)/(1<<20))}

// What to know before reading a load, and where its time went.
@(private)
profile_load_notes :: proc(l:host.Load_Summary,manual:bool) -> []string {
    notes:=make([dynamic]string)
    switch l.state {
    case .Loading:
        if !l.ready {
            append(&notes,fmt.tprintf("Not ready after %.0f ms: its documents are still read, instantiated or given their assets in jobs; ask again",l.elapsed_ms))
        } else {
            waiting:=strings.builder_make()
            for busy in l.waiting {
                if strings.builder_len(waiting)>0 {strings.write_string(&waiting,", ")}
                fmt.sbprint(&waiting,busy)
            }
            what:=strings.to_string(waiting)
            if what=="" {what="a frame that draws (and, when a game plays, one of its ticks)"}
            append(&notes,fmt.tprintf("Ready at %.0f ms and not resident after %.0f ms: waiting for %s; ask again",l.ready_ms,l.elapsed_ms,what))
        }
        if manual {append(&notes,"Manual editor: frames run only when asked (engine.step, editor.input, profile.capture with advance), and residency is decided at the end of a frame")}
    case .Done:
        if len(l.waits)>0 {
            last:=l.waits[0]
            append(&notes,fmt.tprintf("Resident at %.0f ms, %.0f ms after it was ready; what ended last was %v, busy until %.0f ms",l.resident_ms,l.resident_ms-l.ready_ms,last.busy,last.until_ms))
        } else if l.kind!=.Section {
            append(&notes,fmt.tprintf("Resident at %.0f ms, at the end of the first frame after it was ready",l.resident_ms))
        }
    case .Interrupted:
        append(&notes,"Interrupted: another load began before it was resident, so its numbers stop there")
    case .Failed:
        append(&notes,fmt.tprintf("Failed: %s",l.failure))
    case .None:
    }
    largest:host.Load_Phase_Summary
    found:=false
    for phase in l.phases {
        if phase.summed {continue}
        largest,found=phase,true
        break
    }
    if found {append(&notes,fmt.tprintf("The costliest phase is %v, %.0f ms",largest.phase,largest.ms))}
    if len(l.assets)>0 {
        k:=l.assets[0]
        append(&notes,fmt.tprintf("Of the assets, the %v took the most: %d files, %.0f ms",k.kind,k.count,k.ms))
    }
    for phase in l.phases {
        if !phase.summed {continue}
        append(&notes,"Prepare and Nav_Tiles are summed over the job workers: compare them with each other, not with the wall time")
        break
    }
    if len(l.functions)>0 {append(&notes,"functions are the loop functions of the frames while it loaded: the physics, collision and navigation phases are part of physics_step and navigation_build")}
    if l.kind==.Section {append(&notes,"A section counts what its own load did until it joined the world; it also counts in the scene or Play that was loading then")}
    return notes[:]
}
