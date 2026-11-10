package editor

import "core:math/linalg"
import "mirai:core"
import "mirai:editor/api"
import ecamera "mirai:engine/camera"
import input "mirai:engine/input"
import "mirai:std/base"
import mm "mirai:std/math"

// look_at of play.step: every tick it turns what the player sees through
// toward an entity, followed where it moves, or a point, by the look its camera
// takes: an Orbit camera is asked to turn (its turn is its own), and one that
// looks where its body looks (Eyes, aiming) through the look action of the seat.

Api_Play_Look_At :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=What it looks at: the entity by its name or a path Parent/Child or its id or its handle followed where it moves (its middle); in place of position"`,
    position:[3]f32 `mirai:"optional,label=What it looks at: a point of the world; in place of entity"`,
}

@(private)
Api_Look :: struct {
    entity:core.Entity, // NONE: point
    point:[3]f32,
    action:input.Action, // the look of the seat, for what does not turn as an Orbit
}

// What look_at asks of the game that plays; ok is false after failing the
// call. raw is its JSON; delta says the step moves the mouse.
@(private)
api_look_read :: proc(s:^Session,call:^api.Call,w:core.World_Ref,p:^Api_Play_Look_At,raw:string,timeline:[]Api_Step_Input) -> (look:Api_Look,ok:bool) {
    for step in timeline {
        if step.mouse_delta!={} {api.call_fail(call,api.INVALID_PARAMS,"look_at turns the view by itself: leave mouse_delta out of the step");return}
    }
    values:[2]string
    api.object_values(call.allocator,raw,{"entity","position"},values[:])
    if (values[0]!="")==(values[1]!="") {
        api.call_fail(call,api.INVALID_PARAMS,`look_at: name what it looks at with entity, a name of the game, or position, a point [x, y, z]; give one`)
        return
    }
    if values[0]!="" {
        e,wrong:=api_entity_select(w,base.text_get(p.entity[:]),"look_at.entity",true,call.allocator)
        if wrong!="" {api.call_fail(call,api.INVALID_PARAMS,wrong);return}
        look.entity=e
    } else {
        if !rpc_finite(p.position.x) || !rpc_finite(p.position.y) || !rpc_finite(p.position.z) {api.call_fail(call,api.INVALID_PARAMS,"look_at.position takes three finite numbers");return}
        look.point=p.position
    }
    problem:=api_look_problem(s,w,&look)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    return look,true
}

// Why the view of w cannot be turned; finds the look action of the seat when it needs it.
@(private)
api_look_problem :: proc(s:^Session,w:core.World_Ref,look:^Api_Look) -> string {
    seen:=core.world_storage_of(w,core.View)
    if seen==nil {return "look_at turns what the player sees, and this game has no view"}
    follows:=core.world_table_of(w,ecamera.Camera_Follow)
    if follows==nil {return "look_at turns a camera with a Camera_Follow, and this game has none"}
    follow,found:=core.get(follows,seen.camera)
    if !found {return "look_at turns a camera with a Camera_Follow, and the player sees through one without it; move that one with the game"}
    switch {
    case follow.mode==.Follow:
        return "look_at turns an Orbit or an Eyes camera, and the player sees through a Follow one, which looks as its target goes"
    case follow.mode==.Orbit && !follow.aim:
        if core.world_storage_of(w,ecamera.Camera_Input)==nil {return "this game has no Camera_Input to turn its camera with"}
        return ""
    }
    m,requests:=core.world_storage_of(w,input.Input_Map),core.world_storage_of(w,input.Hold_Requests)
    actions:=core.actions_of(s.info,input.Look_Action)
    if m==nil || requests==nil || actions==nil {return "look_at turns the look of a seat through its look action, and this game has none"}
    look.action=input.Action(actions.base)+input.Action(input.Look_Action.Look)
    if m.declared&input.action_bit(look.action)==0 {return "look_at turns the look of a seat through its look action, and this game binds none: bind Look in input.mirai"}
    return ""
}

// Turns the view for the tick that comes; "" or why it cannot.
@(private)
api_look_steer :: proc(s:^Session,r:^Run,look:^Api_Look) -> string {
    w:=run_ref(s,r)
    point:=look.point
    if look.entity!=core.NONE {
        if !core.alive(core.world_entities(w),look.entity) {return "look_at: the entity it looks at is gone"}
        point=api_entity_middle(w,look.entity)
    }
    if problem:=api_look_problem(s,w,look);problem!="" {return problem}
    seen:=core.world_storage_of(w,core.View)
    follows:=core.world_table_of(w,ecamera.Camera_Follow)
    follow,_:=core.get(follows,seen.camera)
    seat,body:=play_focused(w)
    if follow.mode==.Orbit && !follow.aim {
        up:=mm.QUAT_IDENTITY
        if verticals:=core.world_table_of(w,core.Vertical);verticals!=nil {
            target:=follow.target
            if drivables:=core.world_table_of(w,input.Drivable);drivables!=nil {target=ecamera.follow_target(seen.camera,follow.target,drivables,seat)}
            up=core.vertical_of(verticals,target)
        }
        // Not started yet: it has no pivot to look from until its first frame.
        ecamera.camera_look_toward(core.world_storage_of(w,ecamera.Camera_Input),seen.camera,follow,point,up)
        return ""
    }
    if body==core.NONE {return ""}
    to:=point-seen.position
    if linalg.length(to)<1e-4 {return ""}
    want:=look_yaw_pitch(linalg.normalize(to))
    now:=look_yaw_pitch(core.view_forward(seen^))
    value:=[2]f32{mm.angle_wrap(now.x-want.x)/input.LOOK_SPEED,(want.y-now.y)/input.LOOK_SPEED}
    if value!={} {input.hold(core.world_storage_of(w,input.Hold_Requests),seat,look.action,value,1)}
    return ""
}

// The yaw about up and the pitch up from level of a direction.
@(private)
look_yaw_pitch :: proc(direction:[3]f32) -> [2]f32 {
    return {mm.yaw_of_direction(direction),linalg.asin(clamp(direction.y,-1,1))}
}
