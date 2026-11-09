package editor

import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import ecamera "mirai:engine/camera"
import input "mirai:engine/input"
import erender "mirai:engine/render"
import "mirai:std/serial"

@(private="file")
View_World :: struct {
    entities:core.Entities,
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    bodies:core.Table(input.Drivable),
    seats:core.Table(input.Seat),
    lenses:core.Table(erender.Camera),
    follows:core.Table(ecamera.Camera_Follow),
    players:input.Seats,
    view:core.View,
    views:ecamera.Camera_Views,
    time:core.Time,
}

@(private="file")
view_json :: proc(t:^testing.T,text:string) -> json.Object {
    value,error:=json.parse(transmute([]u8)text,allocator=context.temp_allocator)
    testing.expect_value(t,error,json.Error.None)
    object,_:=value.(json.Object)
    return object
}

@(private="file")
view_number :: proc(value:json.Value) -> f64 {
    #partial switch v in value {
    case json.Float:   return f64(v)
    case json.Integer: return f64(v)
    }
    return math.nan_f64()
}

// What the player sees: the camera of the view with its place and lens, the
// mode and the blend of the focused slot, how far it is from what it follows
// and where entities and world points show on the screen; the same document
// is what a condition and a trace read with view.
@(test)
play_view_says_what_the_player_sees_and_where_things_show_on_the_screen :: proc(t:^testing.T) {
    w:View_World
    core.entities_init(&w.entities)
    core.table_init(&w.names,"Name");core.table_init(&w.transforms,"Transform");core.table_init(&w.parents,"Parent")
    core.table_init(&w.bodies,"Drivable");core.table_init(&w.seats,"Seat")
    core.table_init(&w.lenses,"Camera");core.table_init(&w.follows,"Camera_Follow")
    defer {
        core.table_destroy(&w.names);core.table_destroy(&w.transforms);core.table_destroy(&w.parents)
        core.table_destroy(&w.bodies);core.table_destroy(&w.seats)
        core.table_destroy(&w.lenses);core.table_destroy(&w.follows)
        core.entities_destroy(&w.entities)
    }
    tables:=[7]core.Table_Info{
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(View_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(View_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(View_World,parents)},
        {name="Drivable",type=input.Drivable,info=type_info_of(input.Drivable),offset=offset_of(View_World,bodies)},
        {name="Seat",type=input.Seat,info=type_info_of(input.Seat),offset=offset_of(View_World,seats)},
        {name="Camera",type=erender.Camera,info=type_info_of(erender.Camera),offset=offset_of(View_World,lenses)},
        {name="Camera_Follow",type=ecamera.Camera_Follow,info=type_info_of(ecamera.Camera_Follow),offset=offset_of(View_World,follows)},
    }
    storages:=[4]core.Storage_Info{
        {type=input.Seats,offset=offset_of(View_World,players)},
        {type=core.View,offset=offset_of(View_World,view)},
        {type=ecamera.Camera_Views,offset=offset_of(View_World,views)},
        {type=core.Time,offset=offset_of(View_World,time)},
    }
    info:=core.World_Info{entities=offset_of(View_World,entities),tables=tables[:],storages=storages[:]}
    seat,body,camera:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.names,body,core.name_make("Hero"))
    core.add(&w.names,camera,core.name_make("Hero camera"))
    core.add(&w.transforms,body,core.Transform{position={0,2,-4},rotation=1,scale={1,1,1}})
    core.add(&w.transforms,camera,core.Transform{position={0,2,6},rotation=1,scale={1,1,1}})
    core.add(&w.bodies,body,input.Drivable{seat,camera})
    core.add(&w.seats,seat,input.Seat{})
    core.add(&w.lenses,camera,erender.Camera{fov=60*math.RAD_PER_DEG})
    follow:=ecamera.CAMERA_FOLLOW_DEFAULT
    follow.state.ready,follow.state.pivot.position=true,{0,2,-1}
    follow.looking={0.5,-0.25}
    core.add(&w.follows,camera,follow)
    core.table_settle(&w.names,&w.entities);core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.bodies,&w.entities);core.table_settle(&w.seats,&w.entities)
    core.table_settle(&w.lenses,&w.entities);core.table_settle(&w.follows,&w.entities)
    core.entities_settle(&w.entities)
    w.players.local_count=1
    w.view={position={0,2,6},rotation=1,fov=60*math.RAD_PER_DEG,near=0.1,size={1600,900},camera=camera}
    w.views.slots[0]={camera=camera,blending=true,blend={seconds=0.5,ease=.Linear},elapsed=0.125}
    w.time.tick,w.time.seconds=30,0.5
    ref:=core.world_ref(&w,&info)
    targets:=[3]Play_View_Target{{entity=body,named=true},{point={0,2,10}},{point={20,2,-4}}}
    text,problem:=play_view_json(ref,targets[:])
    testing.expect_value(t,problem,"")
    api_result_shape_expect(t,text,Api_Play_View)
    v:=view_json(t,text)
    testing.expect(t,v["game_camera"].(json.Boolean) or_else false)
    testing.expect_value(t,v["name"].(json.String) or_else "","Hero camera")
    testing.expect_value(t,v["mode"].(json.String) or_else "","Orbit")
    testing.expect(t,abs(view_number(v["fov_deg"])-60)<1e-3)
    blend,_:=v["blend"].(json.Object)
    testing.expect(t,blend["active"].(json.Boolean) or_else false)
    testing.expect(t,abs(view_number(blend["progress"])-0.25)<1e-6 && abs(view_number(blend["weight"])-0.25)<1e-6,"a quarter of a linear blend")
    followed,_:=v["follow"].(json.Object)
    testing.expect_value(t,followed["name"].(json.String) or_else "","Hero")
    testing.expect(t,abs(view_number(followed["distance"])-10)<1e-4 && abs(view_number(followed["pivot_distance"])-7)<1e-4,"the body its camera follows without a target, and its pivot")
    testing.expect(t,abs(view_number(followed["yaw_deg"])-0.5*math.DEG_PER_RAD)<1e-3 && abs(view_number(followed["pitch_deg"])+0.25*math.DEG_PER_RAD)<1e-3,"where it looks now, not where it started")
    points,_:=v["points"].(json.Array)
    if !testing.expect_value(t,len(points),3) {return}
    ahead,_:=points[0].(json.Object)
    normalized,_:=ahead["normalized"].(json.Array)
    pixel,_:=ahead["pixel"].(json.Array)
    testing.expect(t,len(normalized)==2 && abs(view_number(normalized[0])-0.5)<1e-4 && abs(view_number(normalized[1])-0.5)<1e-4,"straight ahead is the center")
    testing.expect(t,len(pixel)==2 && abs(view_number(pixel[0])-800)<1e-2 && abs(view_number(pixel[1])-450)<1e-2)
    testing.expect(t,(ahead["on_screen"].(json.Boolean) or_else false) && abs(view_number(ahead["depth"])-10)<1e-4)
    behind,_:=points[1].(json.Object)
    testing.expect(t,!(behind["in_front"].(json.Boolean) or_else true) && !(behind["on_screen"].(json.Boolean) or_else true),"behind the eye")
    aside,_:=points[2].(json.Object)
    across,_:=aside["normalized"].(json.Array)
    testing.expect(t,(aside["in_front"].(json.Boolean) or_else false) && !(aside["on_screen"].(json.Boolean) or_else true) && view_number(across[0])>1,"off the right edge")

    // Conditions and traces read the same document with view.
    s:=Session{info=&info}
    conditions:=[4]Api_Play_Condition{{view=true,compare=.At_Most,number=7.5},{view=true,compare=.Above,number=0.45},{view=true,compare=.Equal},{view=true,compare=.Gone}}
    copy(conditions[0].field[:],"follow.pivot_distance")
    copy(conditions[1].entity[:],"Hero");copy(conditions[1].field[:],"points.0.normalized.0")
    copy(conditions[2].field[:],"mode");copy(conditions[2].text[:],"Orbit")
    copy(conditions[3].entity[:],"Nobody")
    reads:[4]Api_Condition_Read
    passed,wrong:=api_conditions_read(&s,ref,conditions[:],reads[:],"conditions")
    testing.expect_value(t,wrong,"")
    testing.expectf(t,passed,"%v",reads)
    testing.expect_value(t,reads[3].value,"null")
    refused:=Api_Play_Condition{view=true}
    copy(refused.storage[:],"Time")
    _,wrong=api_condition_read(&s,ref,&refused)
    testing.expect(t,strings.contains(wrong,"leave storage and component out"),wrong)
    call:=api.Call{allocator=context.temp_allocator}
    p:=Api_Play_Trace{view=true,every=1}
    copy(p.entity[:],"Hero")
    copy(p.fields[0][:],"points[0].depth");copy(p.fields[1][:],"blend.progress")
    trace:Api_Trace
    testing.expect_value(t,api_trace_read(&s,&call,ref,&p,`{"view":true,"entity":"Hero","fields":["",""]}`,1,&trace),"")
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    api_trace_write(&s,&out,&trace)
    written:=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(written,`{"view":true,"field":"points[0].depth"}`) && strings.contains(written,`"values":[10,0.25]`),written)
}
