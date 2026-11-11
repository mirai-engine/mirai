package editor

import "mirai:core"
import "mirai:editor/api"
import ecamera "mirai:engine/camera"
import render "mirai:engine/render"
import input "mirai:engine/input"
import "mirai:std/base"
import mm "mirai:std/math"

Api_Play_Player_Params :: struct {
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}
Api_Play_Player_Result :: struct {
    available:bool `mirai:"label=Whether a local seat has focus; without one the rest is empty"`,
    tick:u64,
    seconds:f64 `mirai:"label=The time of the game"`,
    seat:Api_Play_Player_Entity `mirai:"optional,label=The focused local seat"`,
    body:Api_Play_Player_Entity `mirai:"optional,label=The body the seat drives"`,
    camera:Api_Play_Player_Entity `mirai:"optional,label=The camera the view shows; that of the body when the view names none"`,
}
Api_Play_Player_Entity :: struct {
    entity:core.Entity `mirai:"label=The handle"`,
    id:base.Entity_Id `mirai:"optional,label=The id; omitted for an entity without one"`,
    name:[64]u8 `mirai:"text"`,
    position:[3]f32 `mirai:"label=Local to the parent"`,
    rotation_deg:[3]f32 `mirai:"label=Local to the parent in degrees"`,
    scale:[3]f32,
    world_position:[3]f32,
}

@(private)
play_player_entity :: proc(w:core.World_Ref,e:core.Entity) -> (value:Api_Play_Player_Entity) {
    if !core.alive(core.world_entities(w),e) {return}
    value.entity,value.id=e,api_entity_id(w,e)
    base.text_set(value.name[:],entity_name(w,e))
    local:=entity_local(w,e)
    value.position,value.scale=local.position,local.scale
    value.rotation_deg=mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD
    value.world_position=entity_world(w,e).position
    return
}

play_player_snapshot :: proc(w:core.World_Ref) -> (value:Api_Play_Player_Result) {
    if w.data==nil {return}
    if time:=core.world_storage_of(w,core.Time);time!=nil {value.tick,value.seconds=time.tick,time.seconds}
    players:=core.world_storage_of(w,input.Seats)
    seats:=core.world_table_of(w,input.Seat)
    if players==nil || seats==nil {return}
    player:=input.focused(players,seats)
    if !core.alive(core.world_entities(w),player) {return}
    value.available=true
    value.seat=play_player_entity(w,player)
    if shown:=core.world_storage_of(w,render.View_Camera);shown!=nil {value.camera=play_player_entity(w,shown.entity)}
    body:=input.body_of(seats,player)
    value.body=play_player_entity(w,body)
    if cameras:=core.world_table_of(w,render.Camera);value.camera.entity==core.NONE && cameras!=nil {
        value.camera=play_player_entity(w,ecamera.body_camera(core.Ref(core.Hierarchy){core.world_storage_of(w,core.Hierarchy)},cameras,body))
    }
    return
}

@(private)
api_play_player :: proc(s:^Session,call:^api.Call) {
    r,_:=api_play_run(s,call,api.call_params(call,Api_Play_Player_Params).player)
    if r==nil {api_no_game(call);return}
    api.call_result(call,Api_Play_Player_Result)^=play_player_snapshot(core.world_ref(r.world,s.info))
}
