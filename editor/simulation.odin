package editor

import "core:fmt"
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
    for e,i in entities {placed[i]={parent_table!=nil?core.depth_of(core.read(parent_table),e):0,i}}
    slice.sort_by(placed,proc(a,b:Placed) -> bool {return a.depth<b.depth})
    tools_release(s)
    if !history.edits_commit(s.edits,w,s.selection) && s.edits.error!=.No_Change {return false}
    _,edit_ready:=edit_open(s,"Apply simulation")
    if !edit_ready {return false}
    for item in placed {
        e:=entities[item.pose]
        local,ok:=core.local_under(core.read(transforms),core.read(parent_table),entity_parent(w,e),simulation_transform(poses[item.pose]))
        if !ok || !transform_set(s,e,local) {
            history.edits_cancel(s.edits,w)
            return false
        }
    }
    history.edits_end(s.edits)
    if !history.edits_commit(s.edits,w,s.selection) && s.edits.error!=.No_Change {history.edits_cancel(s.edits,w);return false}
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
    p:=providers(s)
    if !p.simulates {return 0,-1,"No plugin simulates bodies: add physics to the plugins of the project"}
    if s.mode!=.Edit {return 0,-1,"Only the document being edited settles: play.stop first"}
    if len(moving)==0 || len(rested)!=len(moving) {return 0,-1,"Give at least one entity to settle"}
    if ticks<1 {return 0,-1,"ticks must be at least 1"}
    if !(s.app.tick_dt>0) {return 0,-1,"The project has no tick rate: set Simulation_Settings.tick_rate"}
    w:=edited_world(s)
    for e,i in moving {
        if !core.alive(core.world_entities(w),e) || !entity_has(w,e,core.Transform) || api_entity_id(w,e)==0 {return 0,i,"is not an entity of the document: it was destroyed or never made"}
        for previous in moving[:i] {if previous==e {return 0,i,"is given twice"}}
    }
    world:=document_copy(s)
    if world==nil {return 0,-1,"The document could not be copied: there is no memory for another world"}
    defer host.app_world_free(s.app,world)
    run:=host.app_world_ref(s.app,world)
    if at,problem=p.simulation.limit(run,s.app,moving);problem!="" {return}
    motions:=core.read(core.world_table_of(run,core.Motion))
    for ran<ticks {
        if !p.simulation.step(run,s.app,s.app.tick_dt) {return ran,-1,"Physics stopped while they fell: engine.diagnostics names what failed"}
        ran+=1
        all:=true
        for e,i in moving {
            motion,made:=core.get(motions,e)
            rested[i]=made && !motion.awake
            all&&=rested[i]
        }
        if all {break}
    }
    poses:=make([]Simulation_Pose,len(moving),context.temp_allocator)
    for e,i in moving {
        t:=entity_world(run,e)
        q:=t.rotation
        poses[i]={api_entity_id(w,e),t.position,{q.x,q.y,q.z,q.w},t.scale}
    }
    if !simulation_apply_poses(s,poses) {return ran,-1,"The poses could not be kept as a step of undo: an edit of the document is open"}
    return ran,-1,""
}

Api_Simulation_Apply_Params :: struct {
    entities:[64]Api_Entity_Text `mirai:"text,entity,label=Existing scene entities whose world transforms are kept"`,
}

@(private)
api_simulation_register :: proc(s:^Session,st:^Api_State) {
    move:=Api_Simulation_Move_Params{rotation={0,0,0,1}}
    api_register(s,st,{name="simulation.move",summary="Drives a body toward a world pose on physics ticks, temporarily kinematic; release restores its authored type once it reaches the target.",params=Api_Simulation_Move_Params,defaults=&move,result=Api_Play_Result,run=api_simulation_move})
    api_register(s,st,{name="simulation.apply",summary="Stops and keeps only the transforms of the given scene entities as one undo step.",params=Api_Simulation_Apply_Params,result=Api_History_Result,run=api_simulation_apply})
}

@(private)
api_simulation_guard :: proc(s:^Session,call:^api.Call) -> bool {
    if simulating(s) {return true}
    api.call_fail(call,api.SERVER_ERROR,"No scene is simulating; play.start with simulate first")
    return false
}

@(private)
api_simulation_apply :: proc(s:^Session,call:^api.Call) {
    if !api_simulation_guard(s,call) {return}
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
