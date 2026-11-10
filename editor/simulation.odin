package editor

import "core:fmt"
import "core:math"
import "core:slice"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
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
