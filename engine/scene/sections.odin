package scene

import "core:math/linalg"
import "core:slice"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// Sections that load when they are asked: each Scene_Reference says what it
// should be (section_state) and holds what it loaded (loaded); scene_sections
// brings one to the other, loading apart in a job a few at a time and dropping
// what is no longer wanted. The game asks through Section_Requests; with a
// network the server asks and the state travels with the reference. Nothing
// settles while it goes through the references: what it adds, removes and
// destroys settles once it ends.

SECTION_LOADS :: 4 // sections loading apart at once, by World
SECTION_FAR_LOADS :: 2 // sections whose far forms load apart at once, by World

Section_Request :: struct {
    entity:core.Entity, // of a Scene_Reference
    state:Section_State,
    streamed:bool, // what the streaming of this end wants of a Spatial one, not what the game asks
}

@(storage,queue)
Section_Requests :: struct {queue:core.Queue(Section_Request)}

// Asks the section of e to be loaded and on, loaded and off, or not loaded.
section_request :: proc(r:^Section_Requests,e:core.Entity,state:Section_State) {
    core.push(&r.queue,Section_Request{e,state,false})
}

// What the streaming of this end wants of the Spatial section of e.
section_stream :: proc(r:^Section_Requests,e:core.Entity,state:Section_State) {
    core.push(&r.queue,Section_Request{e,state,true})
}

// What the editor shows of a section in its view, over what it is asked or
// streamed: not an edit, not saved and not replicated, and a copy of the
// world (Play) starts without it. Only the editor writes it.
Section_View :: struct {
    entity:core.Entity, // of a Scene_Reference
    state:Section_State,
}

@(storage,copy=false)
Section_Views :: struct {items:[dynamic]Section_View}

// What the section of reference e is to be in this world: what a view of the
// editor shows of it, or else section_state.
section_wanted :: proc "contextless" (views:^Section_Views,e:core.Entity,reference:Scene_Reference) -> Section_State {
    if views!=nil {for v in views.items {if v.entity==e {return v.state}}}
    return section_state(reference)
}

// Shows the section of e in the view as state, or as it is asked again when
// shown is false.
section_view :: proc(views:^Section_Views,e:core.Entity,state:Section_State,shown:=true) {
    for v,i in views.items {
        if v.entity!=e {continue}
        if shown {views.items[i].state=state} else {unordered_remove(&views.items,i)}
        return
    }
    if shown {append(&views.items,Section_View{e,state})}
}

Section_Load :: struct {
    job:^Load_Job,
    entity:core.Entity,
}

// The sections a World loads apart, which go when it is freed. A scene that
// replaces the world (Scene_Root.changes) takes those begun before: their
// entities are of the world that was.
@(storage,host,by_world,free="section_loads_free")
Section_Loads :: struct {
    items:[SECTION_LOADS]Section_Load,
    far:[SECTION_FAR_LOADS]Section_Load, // of the far forms of sections that are not loaded (far_load_begin)
    cancelled:[dynamic]^Load_Job, // loads no longer wanted whose jobs still run: freed once they end
    root:u32, // Scene_Root.changes when they began
}

section_loads_free :: proc(loads:^Section_Loads) {
    for l in loads.items {load_free(l.job)}
    for l in loads.far {load_free(l.job)}
    for job in loads.cancelled {load_free(job)}
    delete(loads.cancelled)
    loads^={}
}

// Takes a load from its place without waiting for its jobs: they stop at
// their next step, and the load goes once they end. Without memory to keep
// it meanwhile, it waits for them.
@(private)
load_cancel :: proc(loads:^Section_Loads,l:^Section_Load) {
    job:=l.job
    l^={}
    if job==nil {return}
    load_stop(job)
    if jobs.pending(&job.counter) {
        if _,no_room:=append(&loads.cancelled,job);no_room==nil {return}
    }
    load_free(job)
}

// A section to load: those a source stands in first, then by how near the
// sources come to their boxes, then by Id, whatever the order of the table.
@(private)
Section_Candidate :: struct {
    near:f32, // m from the box to the nearest source, or where its motion takes it
    holds:bool, // a source stands in its box
    id:base.Entity_Id,
    entity:core.Entity,
}

@(private)
candidate_before :: proc(a,b:Section_Candidate) -> bool {
    if a.holds!=b.holds {return a.holds}
    if a.near!=b.near {return a.near<b.near}
    return a.id<b.id || a.id==b.id && a.entity<b.entity
}

@(step="frame",loops="game editor")
scene_sections :: proc(
    world:core.World_Ref,app:^host.App,references:^core.Table(Scene_Reference),requests:^Section_Requests,
    sources:core.Ref(Streaming_Sources),worlds:^core.Table(core.World_Transform,.Read),ids:^core.Table(core.Id,.Read),
    loads:^Section_Loads,loading:^Section_Loading,root:core.Ref(Scene_Root),views:core.Ref(Section_Views),waits:^Load_Waits,stays:^Section_Stays,problems:^core.Problems,
) {
    waited:=core.take(&waits.assets) if waits!=nil else nil
    staying:=core.take(&stays.queue) if stays!=nil else nil
    joined:[SECTION_LOADS]core.Entity
    if u:=core.world_storage_of(world,Unresolved_References);u!=nil {clear(&u.resolved)}
    for r in core.take(&requests.queue) {
        reference:=core.edit(references,r.entity)
        if reference==nil {
            core.report(problems,r.entity,"scene.section","a section state was asked of an entity without Scene_Reference; ask it of the entity that references the scene")
            continue
        }
        if r.streamed {reference.streamed=r.state} else {reference.state=r.state}
        reference.failed={}
    }
    if loads!=nil {
        for i:=len(loads.cancelled)-1;i>=0;i-=1 {
            if jobs.pending(&loads.cancelled[i].counter) {continue}
            load_free(loads.cancelled[i])
            unordered_remove(&loads.cancelled,i)
        }
        changes:=root.ptr!=nil?root.ptr.changes:0
        if loads.root!=changes {
            for &l in loads.items {load_cancel(loads,&l)}
            for &l in loads.far {load_cancel(loads,&l)}
            loads.root=changes
        }
        loads_waits_settle(loads,waited)
        // The loads that ended join their sections.
        for &l,i in loads.items {
            if l.job==nil || !load_step(l.job) {continue}
            job,e:=l.job,l.entity
            l={}
            if !core.alive(core.world_entities(world),e) {
                load_free(job)
                continue
            }
            scene:=job.root
            report,error:=section_load_end(job,world,e)
            if error!=.None {section_failed(world,app.assets,references,e,scene,error,problems)}
            else {joined[i]=e}
            if error==.None && report.missing>0 {
                core.report(problems,e,"scene.section","%d scenes this section loads with are not there, and stay empty; put their files back, or take out the references that name them",report.missing)
            }
        }
        for &l in loads.far {
            if l.job==nil || !load_step(l.job) {continue}
            job,e:=l.job,l.entity
            l={}
            if !core.alive(core.world_entities(world),e) {
                load_free(job)
                continue
            }
            far_load_end(job,world,e)
        }
    }
    es:=core.world_entities(world)
    dormants:=core.world_table_of(world,Dormant)
    documents:=assets_documents(app.assets)
    // What a section dropped above it this frame destroyed or left dormant waits.
    waits_drop :: proc(es:^core.Entities,dormants:^core.Table(Dormant),e:core.Entity) -> bool {
        return !core.alive(es,e) || dormants!=nil && core.raw_added(core.raw(dormants),type_info_of(Dormant),e)!=nil
    }
    candidates:=make([dynamic]Section_Candidate,context.temp_allocator)
    nears:=[SECTION_LOADS]f32{0..<SECTION_LOADS=max(f32)} // of the sections loading: the place a source that stands in another takes
    holding:[SECTION_LOADS]bool
    for row in 0..<core.count(references) {
        e:=core.entity_at(references,row)
        if waits_drop(es,dormants,e) {continue}
        reference:=core.at(references,row)
        state:=section_wanted(views.ptr,e,reference)
        slot:=-1
        if loads!=nil {for l,i in loads.items {if l.job!=nil && l.entity==e {slot=i}}}
        // What joined in this frame hangs from it once the frame settles: it goes, or turns off, in the next.
        stay:=reference.loaded==reference.scene && (slice.contains(staying,e) || slice.contains(joined[:],e))
        switch {
        case state==.Unloaded || reference.rule!=.With_Document && reference.loaded!={} && reference.loaded!=reference.scene:
            if slot>=0 {load_cancel(loads,&loads.items[slot])}
            if reference.loaded=={} || stay {break}
            section_drop(world,documents,e)
        case reference.loaded=={} && loads!=nil && reference.failed!=reference.scene && reference.scene!={}:
            pose,_:=core.get(worlds,e)
            near,holds:=section_near(sources.ptr,reference,pose.transform)
            if slot<0 {
                id,_:=core.get(ids,e)
                append(&candidates,Section_Candidate{near,holds,id.value,e})
                break
            }
            nears[slot],holding[slot]=near,holds
            if holds {load_whole(loads.items[slot].job)}
        }
        reference=core.at(references,row)
        // Loaded and off: what hangs from it under Disabled; on, without it.
        if held:=state==.Loaded;reference.loaded!={} && held!=reference.held && !(held && stay) {
            if section_hold(world,e,held)!=.None {
                core.report(problems,e,"scene.memory","out of memory to tell what this section turned on from what changed in it: a save holds it all as changed; free memory")
            }
            core.edit_at(references,row).held=held
        }
    }
    slice.sort_by(candidates[:],candidate_before)
    for c in candidates {
        free:=-1
        for l,i in loads.items {if l.job==nil {free=i;break}}
        // A source stands in it: the load farthest from the sources that stands in none gives it its place.
        if free<0 && c.holds {
            for _,i in loads.items {if !holding[i] && (free<0 || nears[i]>nears[free]) {free=i}}
            if free>=0 {load_cancel(loads,&loads.items[free])}
        }
        if free<0 {break}
        job,error:=section_load_begin(app,world,c.entity)
        if error!=.None {
            reference,_:=core.get(references,c.entity)
            section_failed(world,app.assets,references,c.entity,reference.scene,error,problems)
            continue
        }
        // With libraries to wait for, it joins once what they prepare of it is ready.
        job.gated=waits!=nil
        if c.holds {load_whole(job)}
        loads.items[free]={job,c.entity}
        nears[free],holding[free]=c.near,c.holds
    }
    // Not loaded nor loading: what draws a far form of its own shows, read from its scene apart.
    for row in 0..<core.count(references) {
        if loads==nil {break}
        e:=core.entity_at(references,row)
        reference:=core.at(references,row)
        if reference.loaded!={} || reference.far==reference.scene || waits_drop(es,dormants,e) {continue}
        loading:=false
        for l in loads.items {loading||=l.job!=nil && l.entity==e}
        free:=-1
        for l,i in loads.far {if l.job==nil {free=i;break}}
        if loading || free<0 {continue}
        job,_:=far_load_begin(app,world,e)
        if job!=nil {job.gated=waits!=nil}
        // A load without jobs to wait for shows in this frame.
        if job!=nil && load_step(job) {far_load_end(job,world,e)} else if job!=nil {loads.far[free]={job,e}}
    }
    if records_look(world)!=.None {
        core.report(problems,core.NONE,"scene.memory","out of memory to follow what changes in the sections: they are looked at again next frame; free memory")
    }
    if loads!=nil && loading!=nil {sections_progress(loading,loads)}
    // What loads with the world is resident once its sections joined.
    busy:=false
    if loads!=nil {
        for l in loads.items {busy||=l.job!=nil}
        for l in loads.far {busy||=l.job!=nil}
    }
    host.load_report(app,.Sections,busy)
}

// How near the sources, and where their motion takes them, come to the box
// of a section at pose, in meters, and whether one stands in it; max(f32)
// without sources.
section_near :: proc "contextless" (sources:^Streaming_Sources,reference:Scene_Reference,pose:mm.Transform) -> (near:f32,holds:bool) {
    near=max(f32)
    if sources==nil {return}
    half:=reference.extents*linalg.abs(pose.scale)
    inverse:=mm.quat_inverse(pose.rotation)
    for source in sources.items[:sources.count] {
        for point,i in ([2][3]f32{source.position,source.ahead}) {
            d:=box_distance(-half,half,mm.quat_rotate(inverse,point-pose.position))
            if d<near {near=d}
            holds||=i==0 && d==0
        }
    }
    return
}

// A load that a source stands in has the job workers and the frames.
@(private)
load_whole :: proc(job:^Load_Job) {
    job.whole=true
    if job.budget!=0 {host.assets_load_whole(job.app.assets,job.budget)}
}

// Whether the sections to load whose boxes hold a point of the world are
// loaded, or did not load: what a loading screen, a lift or a vehicle that
// slows before what is not there waits for.
ready_at :: proc(references:^core.Table(Scene_Reference,$A),worlds:^core.Table(core.World_Transform,$B),point:[3]f32) -> bool {
    for row in 0..<core.count(references) {
        r:=core.at(references,row)
        if section_state(r)==.Unloaded || r.scene=={} || r.loaded==r.scene || r.failed==r.scene {continue}
        if pose,placed:=core.get(worlds,core.entity_at(references,row));placed && section_holds(r,pose.transform,point) {return false}
    }
    return true
}

// What a body a seat drives does while it stands where a section it is to
// have is not loaded (ready_at). Hold: it is held where it is, with
// Section_Held, until the section joins: the library that simulates it does
// not move it, and it is drawn and animated at rest. Free: it goes on, for a
// game that keeps its player in a loading zone of its own (a lift, a
// corridor, a screen) or slows it before what is not there, by ready_at ahead
// of it.
Section_Wait :: enum u8 {Hold,Free}

@(storage,setting)
Section_Settings :: struct {
    wait:Section_Wait,
}

// Holds each body a seat drives that stands where a section it is to have is
// not loaded, as Section_Settings.wait says, and lets it go once where it
// stands now is, also after a place moved it. Only where the body is decided:
// not one another end of the network moves. The rows on of Section_Held are
// those it holds: what a section holds is off with them.
@(step="frame",loops="game",after="scene_sections")
scene_holds :: proc(
    references:^core.Table(Scene_Reference,.Read),worlds:^core.Table(core.World_Transform,.Read),seats:^core.Table(input.Seat,.Read),remotes:^core.Table(core.Remote,.Read),
    marks:^core.Table(Section_Held),settings:Section_Settings,
) {
    for row:=core.count(marks)-1;row>=0;row-=1 {
        body:=core.entity_at(marks,row)
        at,placed:=core.get(worlds,body)
        if settings.wait==.Hold && placed && !ready_at(references,worlds,at.position) {continue}
        core.remove(marks,body)
    }
    if settings.wait!=.Hold {return}
    for row in 0..<core.count(seats) {
        body:=core.at(seats,row).body
        at,placed:=core.get(worlds,body)
        if !placed || core.has(marks,body) || !core.owned(remotes,body) || ready_at(references,worlds,at.position) {continue}
        core.add(marks,body,Section_Held{})
    }
}

// A section that did not load says why, and is not tried again until it is
// asked again; one whose scene is inside itself names the scenes around it.
@(private)
section_failed :: proc(w:core.World_Ref,assets:^host.Assets,references:^core.Table(Scene_Reference),e:core.Entity,scene:base.Asset_Id,error:Error,problems:^core.Problems) {
    if reference:=core.edit(references,e);reference!=nil {reference.failed=scene}
    if error==.Cycle {
        path:=make([dynamic]base.Asset_Id,context.temp_allocator)
        append(&path,..section_path(w,e))
        append(&path,scene)
        core.report(problems,e,"scene.section","the section did not load: its scene is inside itself (%s); take out the reference that closes the loop, or move what both share to a scene of its own",path_text(assets,path[:]))
        return
    }
    core.report(problems,e,"scene.section","the section did not load: %s; %s",error_text(error),load_fix(error))
}

// Drops the section of e: what changed stays dormant (section_unload), or,
// when the world has no sections, everything that hangs from it goes.
@(private)
section_drop :: proc(w:core.World_Ref,documents:Documents,e:core.Entity) {
    if ok,_:=section_unload(w,documents,e);ok {return}
    if hierarchy:=core.world_storage_of(w,core.Hierarchy);hierarchy!=nil {
        for child:=core.first_child(core.ref(hierarchy),e);child!=core.NONE;child=core.next_sibling(core.ref(hierarchy),child) {core.world_destroy_tree(w,child)}
    }
    if references:=core.world_table_of(w,Scene_Reference);references!=nil {
        if reference:=(^Scene_Reference)(core.raw_edit(core.raw(references),type_info_of(Scene_Reference),e));reference!=nil {reference.loaded,reference.held,reference.far={},false,{}}
    }
}

// Turns off what hangs from the reference e (held) or turns on what it turned
// off, its dormant entities and tombstones aside, and what hangs from it and
// draws a far form of its own, which stays on. Turning it on stamps the
// rows it turns on: its record takes what changed until then and looks again
// past them once that settles. Out_Of_Memory when it could not list those
// rows: they count as changes.
@(private)
section_hold :: proc(world:core.World_Ref,e:core.Entity,held:bool) -> Error {
    hierarchy:=core.world_storage_of(world,core.Hierarchy)
    disabled:=core.world_table_of(world,core.Disabled)
    marks:=core.world_table_of(world,Section_Held)
    parents:=core.world_table_of(world,core.Parent)
    dormants:=core.world_table_of(world,Dormant)
    tombstones:=core.world_table_of(world,Tombstone)
    if hierarchy==nil || disabled==nil || marks==nil || parents==nil {return .None}
    h:=core.ref(hierarchy)
    fars:=far_tables(world)
    turned:=make([dynamic]core.Entity,context.temp_allocator)
    for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {
        if row_has(dormants,child) || row_has(tombstones,child) || far_has(fars,child) && !row_has(marks,child) {continue}
        marked:=row_has(marks,child)
        switch {
        case held && !marked && !row_has(disabled,child):
            core.add(disabled,child,core.Disabled{})
            core.add(marks,child,Section_Held{})
        case !held && marked:
            core.remove(disabled,child)
            core.remove(marks,child)
            append(&turned,child)
        }
    }
    records:=core.world_storage_of(world,Section_Records)
    record:=records_find(records,e)
    if held || record==nil {return .None}
    content:=make([dynamic]core.Entity,context.temp_allocator)
    section_content(world,e,&content)
    records_fold(world,record,content[:])
    // What turns on: what hangs from what it turned on with nothing else off above it.
    on:=make([dynamic]core.Entity,context.temp_allocator)
    if !core.entity_off(core.world_entities(world),e) {
        for x in content {
            at,off:=x,false
            for {
                parent,_:=core.get(parents,at)
                if parent.entity==e {
                    off||=!slice.contains(turned[:],at)
                    break
                }
                if parent.entity==core.NONE {off=true;break}
                off||=row_has(disabled,at)
                at=parent.entity
            }
            if !off {append(&on,x)}
        }
    }
    // The tables in which it has rows that turn on: the next settle stamps them.
    delete(record.fresh)
    fresh,no_fresh:=make([]bool,len(world.info.tables))
    record.fresh=fresh
    for &info,at in world.info.tables {
        if info.place!=world.place || no_fresh!=nil {continue}
        t:=core.world_table_at(world,&info)
        for x in on {
            if row:=core.raw_row(t,x);row>=0 && !t.off[row] {record.fresh[at]=true;break}
        }
    }
    if !record.look {
        record.look=true
        records.looks+=1
    }
    return .Out_Of_Memory if no_fresh!=nil else .None
}


// What the section of reference e holds of its own scene, parents before
// children: not what sleeps, roams or is of a section inside it.
@(private)
section_content :: proc(w:core.World_Ref,e:core.Entity,out:^[dynamic]core.Entity) {
    hierarchy:=core.world_storage_of(w,core.Hierarchy)
    if hierarchy==nil {return}
    h:=core.ref(hierarchy)
    references:=core.world_table_of(w,Scene_Reference)
    dormants:=core.world_table_of(w,Dormant)
    tombstones:=core.world_table_of(w,Tombstone)
    roaming:=core.world_table_of(w,Roaming)
    stack:=make([dynamic]core.Entity,context.temp_allocator)
    for child:=core.first_child(h,e);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    for len(stack)>0 {
        x:=pop(&stack)
        if row_has(dormants,x) || row_has(tombstones,x) || row_has(roaming,x) {continue}
        append(out,x)
        if row_has(references,x) {continue}
        for child:=core.first_child(h,x);child!=core.NONE;child=core.next_sibling(h,child) {append(&stack,child)}
    }
}
