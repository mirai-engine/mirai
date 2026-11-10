package editor

import "core:encoding/json"
import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor/api"
import ecamera "mirai:engine/camera"
import input "mirai:engine/input"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// What the player of the game of the caller sees: the core.View of its world
// (the camera, where it is and its lens), the mode and the blend of the
// camera of the focused local slot (engine/camera), what that camera follows
// and where entities or world points show on the screen. play.view writes it
// and the traces of play.step and the conditions of play.check read it with
// view, so that a test asserts on what is seen.

API_VIEW_POINTS :: 8

Api_Play_View_Point :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"optional,text,entity,label=An entity by its name or a path Parent/Child or its id or its handle"`,
    point:[3]f32 `mirai:"optional,label=A world point in place of an entity"`,
}

Api_Play_View_Params :: struct {
    points:[API_VIEW_POINTS]Api_Play_View_Point `mirai:"optional,label=Entities or world points to find on the screen"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_View :: struct {
    tick:u64,
    seconds:f64 `mirai:"label=The time of the game"`,
    game_camera:bool `mirai:"label=The view is of a camera of the game; false: of the editor or the default one"`,
    camera:[API_HANDLE_TEXT]u8 `mirai:"text,label=The handle of the camera it is drawn from; empty without one"`,
    name:[64]u8 `mirai:"text,label=Of the camera"`,
    position:[3]f32 `mirai:"label=Of the eye in the world"`,
    rotation_deg:[3]f32 `mirai:"label=In the world in degrees"`,
    forward:[3]f32 `mirai:"label=Where it looks: a unit vector"`,
    fov_deg:f32 `mirai:"label=Vertical field of a perspective"`,
    projection:[16]u8 `mirai:"text,label=Perspective Orthographic or Custom"`,
    size:[2]f32 `mirai:"label=Pixels of what it draws into"`,
    mode:[8]u8 `mirai:"text,label=Of the Camera_Follow of the camera: Follow Orbit or Eyes; empty without one"`,
    preset:[16]u8 `mirai:"text,label=The preset its setup is when it is one"`,
    blend:Api_Play_View_Blend `mirai:"label=How the view comes into its camera or mode from what it showed before"`,
    follow:Api_Play_View_Follow `mirai:"label=What its camera follows"`,
    points:[]Api_Play_View_Shown `mirai:"label=One per point asked for in their order"`,
}
Api_Play_View_Blend :: struct {
    active:bool `mirai:"label=It is coming into the camera or the mode"`,
    progress:f32 `mirai:"label=Share of the time of the blend gone from 0 to 1; 1 when it does not blend"`,
    weight:f32 `mirai:"label=Share of the new view in what is drawn after the ease of the blend; 1 when it does not blend"`,
    seconds:f32 `mirai:"label=How long the blend takes; 0 when it does not blend"`,
}
Api_Play_View_Follow :: struct {
    entity:[API_HANDLE_TEXT]u8 `mirai:"text,label=The handle of what its Camera_Follow follows; empty when it follows nothing"`,
    name:[64]u8 `mirai:"text"`,
    distance:f32 `mirai:"label=Meters from the eye to the origin of that entity"`,
    pivot_distance:f32 `mirai:"label=Meters from the eye to the pivot the camera follows with and turns around"`,
    yaw_deg:f32 `mirai:"label=The yaw it looks with now; 0 until it starts: for an Orbit where it stands around its pivot"`,
    pitch_deg:f32 `mirai:"label=The pitch it looks with now; 0 until it starts: for an Orbit positive above the pivot looking down and for Eyes positive up"`,
}
Api_Play_View_Shown :: struct {
    entity:[API_HANDLE_TEXT]u8 `mirai:"text,label=The handle of the entity; empty for a world point"`,
    name:[64]u8 `mirai:"text"`,
    alive:bool `mirai:"label=A world point or an entity that is there; one that is gone is not on the screen"`,
    world:[3]f32 `mirai:"label=The point it projects: of an entity its middle (the center of mass of a body or the middle of what hangs from it)"`,
    in_front:bool `mirai:"label=Ahead of the eye; behind it pixel and normalized mean nothing"`,
    on_screen:bool `mirai:"label=In front and inside the view"`,
    normalized:[2]f32 `mirai:"label=From the top left of the view: 0 to 1 across and down and 0.5 0.5 its center"`,
    pixel:[2]f32 `mirai:"label=In pixels of size from the top left"`,
    depth:f32 `mirai:"label=Meters ahead of the eye along forward"`,
}

// What play.view writes; json marshals it with the names of Api_Play_View.
@(private)
Play_View :: struct {
    tick:u64,
    seconds:f64,
    game_camera:bool,
    camera,name:string,
    position,rotation_deg,forward:[3]f32,
    fov_deg:f32,
    projection:string,
    size:[2]f32,
    mode,preset:string,
    blend:struct {active:bool,progress,weight,seconds:f32},
    follow:struct {entity,name:string,distance,pivot_distance,yaw_deg,pitch_deg:f32},
    points:[]Play_View_Shown,
}
@(private)
Play_View_Shown :: struct {
    entity,name:string,
    alive:bool,
    world:[3]f32,
    in_front,on_screen:bool,
    normalized,pixel:[2]f32,
    depth:f32,
}

// A point to find on the screen: an entity (NONE when it is gone or was not
// found) or, without one, a world point.
@(private)
Play_View_Target :: struct {
    entity:core.Entity,
    named:bool,
    point:[3]f32,
}

@(private)
play_view_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="play.view",summary="What the player of the game of the caller sees: the camera and its place, rotation and lens, its mode and the blend into it, what it follows and how far, and where entities or world points show on the screen. The traces of play.step and the conditions of play.check read the same with view.",params=Api_Play_View_Params,result=Api_Play_View,writes_result=true,flags={.Read_Only},run=api_play_view})
}

@(private)
handle_text :: proc(e:core.Entity,allocator:=context.temp_allocator) -> string {
    return e==core.NONE?"":api_handle_text(e,allocator)
}

// The view of w with where targets show, as JSON; problem when the game has no view.
@(private)
play_view_json :: proc(w:core.World_Ref,targets:[]Play_View_Target,allocator:=context.temp_allocator) -> (text:string,problem:string) {
    seen:=core.world_storage_of(w,core.View)
    if seen==nil {return "","This game has no view: its world does not take core.View"}
    v:Play_View
    if t:=core.world_storage_of(w,core.Time);t!=nil {v.tick,v.seconds=t.tick,t.seconds}
    entities:=core.world_entities(w)
    camera:=seen.camera
    if !core.alive(entities,camera) {camera=core.NONE}
    v.game_camera=camera!=core.NONE
    v.camera,v.name=handle_text(camera,allocator),camera!=core.NONE?entity_name(w,camera):""
    v.position,v.forward=seen.position,core.view_forward(seen^)
    v.rotation_deg=mm.quat_to_euler(seen.rotation)*mm.DEG_PER_RAD
    v.fov_deg=seen.fov*mm.DEG_PER_RAD
    v.projection=fmt.aprint(seen.projection,allocator=allocator)
    v.size=seen.size
    v.blend.progress,v.blend.weight=1,1
    follows:=core.world_table_of(w,ecamera.Camera_Follow)
    if follows!=nil && camera!=core.NONE {
        if follow,found:=core.get(follows,camera);found {
            v.mode=fmt.aprint(follow.mode,allocator=allocator)
            if lenses:=core.world_table_of(w,erender.Camera);lenses!=nil {
                if preset,is:=ecamera.camera_preset_of(core.read(follows),core.read(lenses),camera);is {v.preset=fmt.aprint(preset,allocator=allocator)}
            }
            player:=core.NONE
            state,seats:=core.world_storage_of(w,input.Seats),core.world_table_of(w,input.Seat)
            if state!=nil && seats!=nil {player=input.focused(state,core.read(seats))}
            target:=follow.target
            if drivables:=core.world_table_of(w,input.Drivable);drivables!=nil {target=ecamera.follow_target(camera,follow.target,core.read(drivables),player)}
            if core.alive(entities,target) {
                v.follow.entity,v.follow.name=handle_text(target,allocator),entity_name(w,target)
                v.follow.distance=linalg.length(entity_world(w,target).position-seen.position)
            }
            if follow.state.ready {
                v.follow.pivot_distance=linalg.length(follow.state.pivot.position-seen.position)
                v.follow.yaw_deg,v.follow.pitch_deg=follow.looking.x*mm.DEG_PER_RAD,follow.looking.y*mm.DEG_PER_RAD
            }
        }
    }
    if views:=core.world_storage_of(w,ecamera.Camera_Views);views!=nil {
        slot:=0
        if state:=core.world_storage_of(w,input.Seats);state!=nil {slot=clamp(state.focus,0,clamp(state.local_count,1,input.LOCAL_CAPACITY)-1)}
        if slotted:=views.slots[slot];slotted.blending && slotted.blend.seconds>0 {
            v.blend.active,v.blend.seconds=true,slotted.blend.seconds
            v.blend.progress=clamp(slotted.elapsed/slotted.blend.seconds,0,1)
            v.blend.weight=mm.ease_apply(slotted.blend.ease,v.blend.progress)
        }
    }
    v.points=make([]Play_View_Shown,len(targets),allocator)
    size:=[2]f32{max(seen.size.x,1),max(seen.size.y,1)}
    for target,i in targets {
        shown:=&v.points[i]
        point:=target.point
        if target.named {
            if !core.alive(entities,target.entity) {continue}
            shown.entity,shown.name=handle_text(target.entity,allocator),entity_name(w,target.entity)
            point=api_entity_middle(w,target.entity)
        }
        shown.alive,shown.world=true,point
        pixel,depth,front:=core.view_project(seen^,point)
        shown.depth,shown.in_front=depth,front
        if !front {continue}
        shown.pixel,shown.normalized=pixel,pixel/size
        shown.on_screen=shown.normalized.x>=0 && shown.normalized.x<=1 && shown.normalized.y>=0 && shown.normalized.y<=1
    }
    bytes,error:=json.marshal(v,{},allocator)
    if error!=nil {return "","the view could not be written as JSON"}
    return string(bytes),""
}

// The points of play.view, checked; raw is the JSON of the array.
@(private)
api_view_targets :: proc(w:core.World_Ref,points:[]Api_Play_View_Point,raw:string,allocator:=context.temp_allocator) -> (targets:[]Play_View_Target,problem:string) {
    items:=make([]string,len(points),allocator)
    count:=api_list_items(raw,items)
    targets=make([]Play_View_Target,count,allocator)
    for &target,i in targets {
        p:=&points[i]
        values:[1]string
        api.object_values(allocator,items[i],{"point"},values[:])
        entity:=base.text_get(p.entity[:])
        switch {
        case int(entity!="")+int(values[0]!="")!=1:
            return nil,fmt.tprintf("points[%d]: give entity or a world point",i)
        case values[0]!="":
            if !rpc_finite(p.point.x) || !rpc_finite(p.point.y) || !rpc_finite(p.point.z) {return nil,fmt.tprintf("points[%d].point takes three finite numbers",i)}
            target.point=p.point
        case:
            target.named=true
            wrong:string
            if target.entity,wrong=api_entity_select(w,entity,fmt.tprintf("points[%d]",i),true,allocator);wrong!="" {return nil,wrong}
        }
    }
    return targets,""
}

@(private)
api_play_view :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_View_Params)
    r,_:=api_play_run(s,call,p.player)
    if r==nil {api_no_game(call);return}
    w:=run_ref(s,r)
    values:[1]string
    api.object_values(call.allocator,call.raw,{"points"},values[:])
    targets,problem:=api_view_targets(w,p.points[:],values[0],call.allocator)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    text,failed:=play_view_json(w,targets,call.allocator)
    if failed!="" {api.call_fail(call,api.SERVER_ERROR,failed);return}
    serial.text_write_raw(call.out,text)
}
