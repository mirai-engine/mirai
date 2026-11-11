package editor

import "core:math"
import "core:slice"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

Simulation_Pose :: struct {
    id:base.Entity_Id,
    position:[3]f32,
    rotation:[4]f32,
    scale:[3]f32,
}

simulating :: proc "contextless" (s:^Session) -> bool {return s.mode==.Simulate || s.mode==.Simulation_Paused}

simulation_start :: proc(s:^Session) -> bool {return run_find(s,0)==nil && play_start(s,true)}

// Applies world poses to the document as one transaction, including under selected parents.
simulation_apply_poses :: proc(s:^Session,poses:[]Simulation_Pose) -> bool {
    if s.mode!=.Edit || len(poses)==0 {return false}
    w:=edited_world(s)
    tools_release(s)
    if !history.edits_commit(s.edits,w,s.selection) && s.edits.error!=.No_Change {return false}
    _,edit_ready:=edit_open(s,"Apply simulation")
    if !edit_ready {return false}
    if !poses_write(s,poses) {
        history.edits_cancel(s.edits,w)
        return false
    }
    history.edits_end(s.edits)
    if !history.edits_commit(s.edits,w,s.selection) && s.edits.error!=.No_Change {history.edits_cancel(s.edits,w);return false}
    return true
}

// Writes world poses into the edit that is open, parents first; nothing when one is not valid.
@(private)
poses_write :: proc(s:^Session,poses:[]Simulation_Pose) -> bool {
    w:=edited_world(s)
    entities:=make([]core.Entity,len(poses),context.temp_allocator)
    for pose,i in poses {
        e:=api_entity(w,pose.id)
        if e==core.NONE || !core.has(core.world_table_of(w,core.Transform),e) {return false}
        for previous in poses[:i] {if previous.id==pose.id {return false}}
        if !simulation_pose_valid(pose) {return false}
        entities[i]=e
    }
    // Parents before children: each pose is put under what its parents are once theirs are written.
    transforms,parent_table:=core.world_table_of(w,core.Transform),core.world_table_of(w,core.Parent)
    Placed :: struct {depth,pose:int}
    placed:=make([]Placed,len(poses),context.temp_allocator)
    for e,i in entities {placed[i]={parent_table!=nil?core.depth_of(parent_table,e):0,i}}
    slice.sort_by(placed,proc(a,b:Placed) -> bool {return a.depth<b.depth})
    for item in placed {
        e:=entities[item.pose]
        local,ok:=core.local_under(transforms,parent_table,entity_parent(w,e),simulation_transform(poses[item.pose]))
        if !ok || !transform_set(s,e,local) {return false}
    }
    return true
}

@(private)
simulation_transform :: proc "contextless" (pose:Simulation_Pose) -> mm.Transform {
    q:=pose.rotation
    return {pose.position,quaternion(x=q.x,y=q.y,z=q.z,w=q.w),pose.scale}
}

@(private)
simulation_pose_valid :: proc "contextless" (pose:Simulation_Pose) -> bool {
    for value in pose.position {if math.is_nan(value) || math.is_inf(value) {return false}}
    for value in pose.rotation {if math.is_nan(value) || math.is_inf(value) {return false}}
    for value in pose.scale {if math.is_nan(value) || math.is_inf(value) {return false}}
    q:=pose.rotation
    return pose.id!=0 && abs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1)<0.001
}

// Between frames: keeps existing entities' poses and discards the running copy.
simulation_apply :: proc(s:^Session,ids:[]base.Entity_Id) -> bool {
    if !simulating(s) || len(ids)==0 || len(ids)>64 {return false}
    w:=shown_world(s)
    poses:=make([]Simulation_Pose,len(ids),context.temp_allocator)
    for id,i in ids {
        e:=api_entity(w,id)
        if e==core.NONE || api_entity(edited_world(s),id)==core.NONE {return false}
        t:=entity_world(w,e)
        q:=t.rotation
        poses[i]={id,t.position,{q.x,q.y,q.z,q.w},t.scale}
        if !simulation_pose_valid(poses[i]) {return false}
        for previous in ids[:i] {if previous==id {return false}}
    }
    play_stop(s,true)
    return simulation_apply_poses(s,poses)
}

// A Simulate limited to moving, from Edit: on a copy of the document they alone move and every
// other body is still, tick after tick of the project's rate, until all rest or ticks run out;
// then their world poses are applied to the document as one undo step. rested, by index of
// moving, says which came to rest. A problem says what failed and how to fix it, with nothing
// applied; at is the index in moving it is about, -1 for none.
simulate_until_rest :: proc(s:^Session,moving:[]core.Entity,ticks:int,rested:[]bool) -> (ran,at:int,problem:string) {
    if ticks<1 {return 0,-1,"ticks must be at least 1"}
    if len(rested)!=len(moving) {return 0,-1,"Give a rested for each entity"}
    world:rawptr
    if world,at,problem=settle_begin(s,moving);problem!="" {return}
    defer host.app_world_free(s.app,world)
    for ran<ticks {
        all,ok:=settle_tick(s,world,moving,rested)
        if !ok {return ran,-1,"Physics stopped while they fell: engine.diagnostics names what failed"}
        ran+=1
        if all {break}
    }
    if !simulation_apply_poses(s,settle_poses(s,world,moving)) {return ran,-1,"The poses could not be kept as a step of undo: an edit of the document is open"}
    return ran,-1,""
}

// The copy a Simulate limited to moving runs on, which the caller frees with host.app_world_free;
// nil with the problem otherwise, as simulate_until_rest says it.
settle_begin :: proc(s:^Session,moving:[]core.Entity) -> (world:rawptr,at:int,problem:string) {
    p:=providers(s)
    if !p.simulates {return nil,-1,"No plugin simulates bodies: add physics to the plugins of the project"}
    if s.mode!=.Edit {return nil,-1,"Only the document being edited settles: play.stop first"}
    if len(moving)==0 {return nil,-1,"Give at least one entity to settle"}
    if !(s.app.tick_dt>0) {return nil,-1,"The project has no tick rate: set Simulation_Settings.tick_rate"}
    w:=edited_world(s)
    for e,i in moving {
        if !core.alive(core.world_entities(w),e) || !entity_has(w,e,core.Transform) || api_entity_id(w,e)==0 {return nil,i,"is not an entity of the document: it was destroyed or never made"}
        for previous in moving[:i] {if previous==e {return nil,i,"is given twice"}}
    }
    world=document_copy(s)
    if world==nil {return nil,-1,"The document could not be copied: there is no memory for another world"}
    if at,problem=p.simulation.limit(host.app_world_ref(s.app,world),s.app,moving);problem!="" {
        host.app_world_free(s.app,world)
        return nil,at,problem
    }
    return world,-1,""
}

// The last of moving, which the document made after settle_begin copied it, moves in the copy
// too, with the same handle and rows; the others go on as they were.
settle_add :: proc(s:^Session,world:rawptr,moving:[]core.Entity) -> (at:int,problem:string) {
    if len(moving)==0 {return -1,"Give at least one entity to settle"}
    at=len(moving)-1
    w,run:=edited_world(s),host.app_world_ref(s.app,world)
    e:=moving[at]
    if !core.alive(core.world_entities(w),e) || api_entity_id(w,e)==0 {return at,"is not an entity of the document: it was destroyed or never made"}
    if core.create(core.world_entities(run))!=e {return at,"was not the next entity the document made after the copy"}
    for &t in s.info.tables {
        if t.place!=.World {continue}
        if value:=core.raw_find(core.world_table_at(w,&t),t.info,e);value!=nil {core.raw_add(core.world_table_at(run,&t),t.info,e,value)}
    }
    core.world_settle(run)
    return providers(s).simulation.limit(run,s.app,moving)
}

// One tick of the copy at the project's rate: which of moving rest, and whether all do. False when
// physics stopped.
settle_tick :: proc(s:^Session,world:rawptr,moving:[]core.Entity,rested:[]bool) -> (all,ok:bool) {
    run:=host.app_world_ref(s.app,world)
    if !providers(s).simulation.step(run,s.app,s.app.tick_dt) {return}
    motions:=core.world_table_of(run,core.Motion)
    all=true
    for e,i in moving {
        motion,made:=core.get(motions,e)
        rested[i]=made && !motion.awake
        all&&=rested[i]
    }
    return all,true
}

// The poses moving have in the copy, written into the edit of the document that is open: what a
// gesture shows while it lasts.
settle_write :: proc(s:^Session,world:rawptr,moving:[]core.Entity) -> bool {
    return s.edits.open && poses_write(s,settle_poses(s,world,moving))
}

@(private)
settle_poses :: proc(s:^Session,world:rawptr,moving:[]core.Entity) -> []Simulation_Pose {
    w,run:=edited_world(s),host.app_world_ref(s.app,world)
    poses:=make([]Simulation_Pose,len(moving),context.temp_allocator)
    for e,i in moving {
        t:=entity_world(run,e)
        q:=t.rotation
        poses[i]={api_entity_id(w,e),t.position,{q.x,q.y,q.z,q.w},t.scale}
    }
    return poses
}

Api_Simulation_Apply_Params :: struct {
    entities:[64]Api_Entity_Text `mirai:"text,entity,label=Existing scene entities whose world transforms are kept"`,
}

@(private)
api_simulation_register :: proc(s:^Session,st:^Api_State) {
    move:=Api_Simulation_Move_Params{rotation={0,0,0,1}}
    api_register(s,st,{name="simulation.move",summary="Drives a body toward a world pose on physics ticks: a dynamic body is pulled by a spring of bounded force and keeps colliding, a static or kinematic one moves there as kinematic. release lets go: a pulled body at once, keeping its velocity, another once it reaches the target.",params=type_info_of(Api_Simulation_Move_Params),defaults=&move,result=type_info_of(Api_Play_Result),can=simulation_can,run=api_simulation_move})
    api_register(s,st,{name="simulation.apply",summary="Stops and keeps only the transforms of the given scene entities as one undo step.",params=type_info_of(Api_Simulation_Apply_Params),result=type_info_of(Api_History_Result),can=simulation_can,run=api_simulation_apply})
}

@(private)
simulation_can :: proc(s:^Session) -> string {return "" if simulating(s) else "No scene is simulating; play.start with simulate first"}

@(private)
api_simulation_apply :: proc(s:^Session,call:^api.Call) {
    if _,own:=api_play_run(s,call);!own {api_play_refused(call);return}
    params:=api.call_params(call,Api_Simulation_Apply_Params)
    ids:[len(params.entities)]base.Entity_Id
    entities,named:=api_call_entities(call,shown_world(s),params.entities[:],"entities",call.allocator,true)
    if !named {return}
    if len(entities)>len(ids) {
        api.call_failf(call,api.INVALID_PARAMS,"entities: at most %d at once",len(ids))
        return
    }
    count:=len(entities)
    for e,i in entities {ids[i]=api_entity_id(shown_world(s),e)}
    if !simulation_apply(s,ids[:count]) {
        api.call_fail(call,api.INVALID_PARAMS,"Give distinct entities that exist in both the document and the simulation")
        return
    }
    api.call_result(call,Api_History_Result)^={history.edits_undo_count(s.edits),history.edits_redo_count(s.edits),0}
}
