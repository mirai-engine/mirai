package editor

import "core:encoding/json"
import "core:fmt"
import "mirai:core"
import "mirai:editor/api"
import ecamera "mirai:engine/camera"
import render "mirai:engine/render"
import input "mirai:engine/input"
import mm "mirai:std/math"
import "mirai:std/serial"

Play_Player_Entity :: struct {
    entity,id,name:string,
    position,rotation_deg,scale,world_position:[3]f32,
}

Api_Play_Player_Params :: struct {
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Play_Player_Snapshot :: struct {
    available:bool,
    tick:u64,
    seconds:f64,
    seat,body,camera:Play_Player_Entity,
}

@(private)
play_player_entity :: proc(w:core.World_Ref,e:core.Entity) -> (value:Play_Player_Entity) {
    if !core.alive(core.world_entities(w),e) {return}
    value.entity=api_handle_text(e)
    if id:=api_entity_id(w,e);id!=0 {value.id=fmt.tprintf("0x%016x",u64(id))}
    value.name=entity_name(w,e)
    local:=entity_local(w,e)
    value.position,value.scale=local.position,local.scale
    value.rotation_deg=mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD
    value.world_position=entity_world(w,e).position
    return
}

play_player_snapshot :: proc(w:core.World_Ref) -> (value:Play_Player_Snapshot) {
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
    if cameras:=core.world_table_of(w,render.Camera);value.camera.entity=="" && cameras!=nil {
        value.camera=play_player_entity(w,ecamera.body_camera(core.Ref(core.Hierarchy){core.world_storage_of(w,core.Hierarchy)},cameras,body))
    }
    return
}

@(private)
api_play_player :: proc(s:^Session,call:^api.Call) {
    r,_:=api_play_run(s,call,api.call_params(call,Api_Play_Player_Params).player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,API_NO_GAME);return}
    bytes,error:=json.marshal(play_player_snapshot(core.world_ref(r.world,s.info)),{},call.allocator)
    if error!=nil {api.call_fail(call,api.INTERNAL_ERROR,"The player snapshot could not be serialized");return}
    serial.text_write_raw(call.out,string(bytes))
}
