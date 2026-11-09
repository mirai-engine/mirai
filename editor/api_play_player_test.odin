package editor

import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:std/serial"

@(private="file")
Player_Inspect_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    bodies:core.Table(input.Drivable),
    seats:core.Table(input.Seat),
    players:input.Seats,
    shown:render.View_Camera,
    time:core.Time,
}

@(private="file")
player_inspect_init :: proc(w:^Player_Inspect_World) {
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.names,"Name")
    core.table_init(&w.transforms,"Transform");core.table_init(&w.bodies,"Drivable")
    core.table_init(&w.seats,"Seat")
}

@(private="file")
player_inspect_free :: proc(w:^Player_Inspect_World) {
    core.table_destroy(&w.ids);core.table_destroy(&w.names)
    core.table_destroy(&w.transforms);core.table_destroy(&w.bodies)
    core.table_destroy(&w.seats)
    core.entities_destroy(&w.entities)
}

@(test)
play_player_reads_the_live_seat_without_changing_the_document :: proc(t:^testing.T) {
    edited,running:Player_Inspect_World
    player_inspect_init(&edited);defer player_inspect_free(&edited)
    player_inspect_init(&running);defer player_inspect_free(&running)
    tables:=[5]core.Table_Info{
        {type=core.Id,info=type_info_of(core.Id),offset=offset_of(Player_Inspect_World,ids)},
        {type=core.Name,info=type_info_of(core.Name),offset=offset_of(Player_Inspect_World,names)},
        {type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Player_Inspect_World,transforms)},
        {type=input.Drivable,info=type_info_of(input.Drivable),offset=offset_of(Player_Inspect_World,bodies)},
        {type=input.Seat,info=type_info_of(input.Seat),offset=offset_of(Player_Inspect_World,seats)},
    }
    storages:=[3]core.Storage_Info{
        {type=input.Seats,offset=offset_of(Player_Inspect_World,players)},
        {type=render.View_Camera,offset=offset_of(Player_Inspect_World,shown)},
        {type=core.Time,offset=offset_of(Player_Inspect_World,time)},
    }
    info:=core.World_Info{entities=offset_of(Player_Inspect_World,entities),tables=tables[:],storages=storages[:]}
    seat:=core.create(&running.entities)
    body:=core.create(&running.entities)
    camera:=core.create(&running.entities)
    core.add(&running.ids,seat,core.Id{7})
    core.add(&running.names,seat,core.name_make("Player"))
    core.add(&running.names,body,core.name_make("Driven body"))
    core.add(&running.transforms,body,core.Transform{position={4,5,6},rotation=1,scale={1,1,1}})
    core.add(&running.transforms,camera,core.Transform{position={8,9,10},rotation=1,scale={1,1,1}})
    core.add(&running.bodies,body,input.Drivable{seat,camera})
    core.table_settle(&running.ids,&running.entities);core.table_settle(&running.names,&running.entities)
    core.add(&running.seats,seat,input.Seat{})
    core.table_settle(&running.transforms,&running.entities);core.table_settle(&running.bodies,&running.entities)
    core.table_settle(&running.seats,&running.entities)
    core.entities_settle(&running.entities)
    running.players.local_count,running.shown.entity=1,camera
    running.time.tick,running.time.seconds=9,1.5
    session:=Session{mode=.Play,info=&info,edit_world=&edited}
    session.runs[0]={world=&running}
    version:=running.bodies.version
    value:=play_player_snapshot(core.world_ref(&running,&info))
    testing.expect(t,value.available && value.tick==9 && value.seconds==1.5)
    testing.expect_value(t,value.seat.id,"0x0000000000000007")
    testing.expect_value(t,value.seat.name,"Player")
    testing.expect(t,value.body.entity!="" && value.body.id=="")
    testing.expect_value(t,value.body.position,([3]f32{4,5,6}))
    testing.expect_value(t,value.camera.position,([3]f32{8,9,10}))
    testing.expect_value(t,running.bodies.version,version)
    testing.expect_value(t,edited.entities.alive,0)
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    method:=api.Method{params_id=Api_Play_Player_Params}
    params:Api_Play_Player_Params
    call:=api.Call{method=&method,params=&params,out=&out,allocator=context.temp_allocator}
    api_play_player(&session,&call)
    testing.expect(t,!call.failed)
    testing.expect(t,strings.contains(string(serial.writer_bytes(&out)),`"name":"Driven body"`))
    running.players.local_count=0
    value=play_player_snapshot(core.world_ref(&running,&info))
    testing.expect(t,!value.available && value.tick==9)
    session.runs[0]={}
    api_play_player(&session,&call)
    testing.expect(t,call.failed)
}
