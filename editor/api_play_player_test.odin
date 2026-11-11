package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Player_Inspect_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    seats:core.Table(input.Seat),
    players:input.Seats,
    shown:render.View_Camera,
    time:core.Time,
}

@(test)
play_player_reads_the_live_seat_without_changing_the_document :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Player_Inspect_World,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    edited,running:Player_Inspect_World
    if !testing.expect(t,core.world_init(&info,.World,&edited,context.allocator) && core.world_init(&info,.World,&running,context.allocator)) {return}
    defer {core.world_destroy(&info,.World,&edited);core.world_destroy(&info,.World,&running)}
    seat:=core.create(&running.entities)
    body:=core.create(&running.entities)
    camera:=core.create(&running.entities)
    core.add(&running.ids,seat,core.Id{7})
    core.add(&running.names,seat,core.name_make("Player"))
    core.add(&running.names,body,core.name_make("Driven body"))
    core.add(&running.transforms,body,core.Transform{position={4,5,6},rotation=1,scale={1,1,1}})
    core.add(&running.transforms,camera,core.Transform{position={8,9,10},rotation=1,scale={1,1,1}})
    core.add(&running.seats,seat,input.Seat{body=body})
    core.settle(&info,&running,nil)
    running.players.local_count,running.shown.entity=1,camera
    running.time.tick,running.time.seconds=9,1.5
    session:=Session{mode=.Play,info=&info,edit_world=&edited}
    session.runs[0]={world=&running}
    version:=running.seats.version
    value:=play_player_snapshot(core.world_ref(&running,&info))
    testing.expect(t,value.available && value.tick==9 && value.seconds==1.5)
    testing.expect_value(t,value.seat.id,base.Entity_Id(7))
    testing.expect_value(t,base.text_get(value.seat.name[:]),"Player")
    testing.expect(t,value.body.entity!=core.NONE && value.body.id==0)
    testing.expect_value(t,value.body.position,([3]f32{4,5,6}))
    testing.expect_value(t,value.camera.position,([3]f32{8,9,10}))
    testing.expect_value(t,running.seats.version,version)
    testing.expect_value(t,edited.entities.alive,0)
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    method:=api.Method{params_id=Api_Play_Player_Params,result_id=Api_Play_Player_Result}
    params:Api_Play_Player_Params
    result:Api_Play_Player_Result
    call:=api.Call{method=&method,params=&params,result=&result,out=&out,allocator=context.temp_allocator}
    api_play_player(&session,&call)
    testing.expect(t,!call.failed && base.text_get(result.body.name[:])=="Driven body")
    running.players.local_count=0
    value=play_player_snapshot(core.world_ref(&running,&info))
    testing.expect(t,!value.available && value.tick==9)
    session.runs[0]={}
    api_play_player(&session,&call)
    testing.expect(t,call.failed)
}
