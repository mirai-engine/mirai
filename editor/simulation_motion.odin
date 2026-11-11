package editor

import "mirai:core"
import "mirai:editor/api"
import "mirai:std/base"
import mm "mirai:std/math"

// A body can be driven without changing the Rigid_Body saved in the scene.
simulation_body_target :: proc(s:^Session,e:core.Entity,position:[3]f32,rotation:mm.Quat=1) -> bool {
    if !simulating(s) || !finite3(position) {return false}
    q:=rotation
    length:=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w
    if length-length!=0 || abs(length-1)>0.001 {return false}
    w:=shown_world(s)
    p:=providers(s)
    if !p.simulates || p.simulation.owner(w,e)!=e {return false}
    return p.simulation.move(w,e,position,rotation)
}

simulation_body_release :: proc(s:^Session,e:core.Entity) -> bool {
    if !simulating(s) {return false}
    w:=shown_world(s)
    p:=providers(s)
    if !p.simulates || p.simulation.owner(w,e)!=e {return false}
    return p.simulation.release(w,e)
}

Api_Simulation_Move_Params :: struct {
    entity:Api_Entity_Text `mirai:"text,entity"`,
    position:[3]f32,
    rotation:[4]f32 `mirai:"optional"`,
    release:bool `mirai:"optional,label=Let the body go"`,
}

@(private)
api_simulation_move :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Simulation_Move_Params)
    e,named:=api_call_entity(call,shown_world(s),params.entity[:],game=true)
    if !named {return}
    q:=params.rotation
    if !simulation_body_target(s,e,params.position,quaternion(x=q.x,y=q.y,z=q.z,w=q.w)) {
        api.call_fail(call,api.INVALID_PARAMS,"Give a body's entity and a finite pose; compound children and characters are not independent bodies")
        return
    }
    if params.release {simulation_body_release(s,e)}
    api_play_result(s,call,run_find(s,0))
}
