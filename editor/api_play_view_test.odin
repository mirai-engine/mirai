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

@(private)
@(test_world)
View_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    seats:core.Table(input.Seat),
    lenses:core.Table(erender.Camera),
    follows:core.Table(ecamera.Camera_Follow),
    following:core.Table(ecamera.Camera_Follow_State),
    players:input.Seats,
    view:core.View,
    views:ecamera.Camera_Views,
    time:core.Time,
    cameras:ecamera.Cameras,
    activations:core.Table(ecamera.Camera_Activation),
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
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    seat,body,camera:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.names,body,core.name_make("Hero"))
    core.add(&w.names,camera,core.name_make("Hero camera"))
    core.add(&w.transforms,body,core.Transform{position={0,2,-4},rotation=1,scale={1,1,1}})
    core.add(&w.transforms,camera,core.Transform{position={0,2,6},rotation=1,scale={1,1,1}})
    core.add(&w.seats,seat,input.Seat{body=body})
    core.add(&w.lenses,camera,erender.Camera{fov=60*math.RAD_PER_DEG})
    core.add(&w.follows,camera,ecamera.CAMERA_FOLLOW_DEFAULT)
    state:=ecamera.Camera_Follow_State{ready=true,looking={0.5,-0.25}}
    state.pivot.position={0,2,-1}
    core.add(&w.following,camera,state)
    test_world_settle(&w)
    w.players.local_count=1
    w.view={position={0,2,6},rotation=1,fov=60*math.RAD_PER_DEG,near=0.1,size={1600,900},camera=camera}
    w.views.slots[0]={camera=camera,blending=true,blend={seconds=0.5,ease=.Linear},elapsed=0.125}
    w.time.tick,w.time.seconds=30,0.5
    ref:=test_world_ref(&w)
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
    s:=Session{info=test_world_info(&w)}
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
    testing.expect(t,strings.contains(wrong,"choose one subject") && strings.contains(wrong,"view"),wrong)
    call:=api.Call{allocator=context.temp_allocator}
    p:=Api_Play_Trace{view=true,every=1}
    copy(p.entity[:],"Hero")
    copy(p.fields[0][:],"points[0].depth");copy(p.fields[1][:],"blend.progress")
    trace:Api_Trace
    testing.expect_value(t,api_trace_read(&s,&call,ref,&p,`{"view":true,"entity":"Hero","fields":["",""]}`,1,&trace),"")
    table,_:=serial.text_encode(api_trace_table(&s,&trace),.Line,context.temp_allocator,sparse=true)
    written:=api.json_compact(string(table))
    testing.expect(t,strings.contains(written,`{"view":true,"field":"points[0].depth"}`) && strings.contains(written,`"values":[10,0.25]`),written)
}

// Who chose the camera of the focused player: the body of its seat, the
// latest override that stands for it or an activation whose action it holds;
// the modifiers that camera plays; and the spring arm of an Orbit, pulled in
// by what is in the way, with the body it leaves out of the view.
@(test)
play_view_says_who_drives_the_camera_and_how_its_arm_stands :: proc(t:^testing.T) {
    w:View_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    seat,body,camera,director,shot,aim:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.names,body,core.name_make("Hero"))
    core.add(&w.names,director,core.name_make("Director"))
    core.add(&w.names,aim,core.name_make("Aim camera"))
    core.add(&w.seats,seat,input.Seat{body=body})
    for lens in ([3]core.Entity{camera,shot,aim}) {core.add(&w.lenses,lens,erender.Camera{fov=60*math.RAD_PER_DEG})}
    core.add(&w.follows,camera,ecamera.CAMERA_FOLLOW_DEFAULT)
    core.add(&w.activations,aim,ecamera.CAMERA_ACTIVATION_DEFAULT)
    state:=ecamera.Camera_Follow_State{ready=true}
    state.arm=ecamera.spring_arm_make(4)
    state.arm.current,state.arm.blocked=2.5,0.3
    state.side=ecamera.spring_arm_make(0.5)
    state.modifiers[1]={modifier={id=7,fov=10*math.RAD_PER_DEG,distance=1,offset={0,-0.5,0}},weight=0.5,asked=true}
    state.modifiers[3]={modifier={id=9,roll=0.1},weight=0.2}
    core.add(&w.following,camera,state)
    test_world_settle(&w)
    w.players.local_count=1
    w.view={position={0,2,6},rotation=1,fov=60*math.RAD_PER_DEG,near=0.1,size={1600,900},camera=camera}
    w.views.slots[0]={camera=camera,fade=1}
    ref:=test_world_ref(&w)
    Case :: struct {overrides:[]ecamera.Camera_Override,kind,owner:string,order:f64,standing:f64}
    cases:=[]Case{
        {nil,"Default","Hero",0,0},
        {{{owner=director,seat=seat,camera=shot,order=5,active=true},{owner=director,seat=body,camera=shot,order=8,active=true}},"Override","Director",5,1},
        {{{owner=director,seat=seat,camera=shot,order=5,active=true},{owner=aim,seat=seat,camera=aim,order=6,active=true}},"Activation","Aim camera",6,2},
    }
    for c in cases {
        w.cameras={}
        copy(w.cameras.overrides[:],c.overrides)
        text,problem:=play_view_json(ref,nil)
        testing.expect_value(t,problem,"")
        api_result_shape_expect(t,text,Api_Play_View)
        authority,_:=view_json(t,text)["authority"].(json.Object)
        testing.expect_value(t,authority["kind"].(json.String) or_else "",c.kind)
        testing.expect_value(t,authority["owner_name"].(json.String) or_else "",c.owner)
        testing.expect_value(t,view_number(authority["order"] or_else json.Integer(0)),c.order)
        testing.expect_value(t,view_number(authority["overrides"]),c.standing)
    }
    text,_:=play_view_json(ref,nil)
    v:=view_json(t,text)
    authority,_:=v["authority"].(json.Object)
    modifiers,_:=authority["modifiers"].(json.Array)
    if testing.expect_value(t,len(modifiers),2) {
        asked,_:=modifiers[0].(json.Object)
        released,_:=modifiers[1].(json.Object)
        testing.expect(t,view_number(asked["id"])==7 && view_number(asked["weight"])==0.5 && abs(view_number(asked["fov_deg"])-10)<1e-3 && view_number(asked["distance"])==1)
        testing.expect(t,!(asked["released"].(json.Boolean) or_else true) && (released["released"].(json.Boolean) or_else false) && view_number(released["id"])==9)
    }
    arm,_:=v["arm"].(json.Object)
    testing.expect(t,view_number(arm["desired"])==4 && view_number(arm["current"])==2.5 && view_number(arm["side_current"])==0.5,text)
    testing.expect(t,(arm["blocked"].(json.Boolean) or_else false) && abs(view_number(arm["blocked_seconds"])-0.3)<1e-6,text)
    testing.expect(t,(arm["body_hidden"].(json.Boolean) or_else false) && view_number(arm["body_fade"])==1,text)
    // What a condition reads with view.
    s:=Session{info=test_world_info(&w)}
    conditions:=[2]Api_Play_Condition{{view=true,compare=.Equal},{view=true,compare=.Below,number=3}}
    copy(conditions[0].field[:],"authority.kind");copy(conditions[0].text[:],"Activation")
    copy(conditions[1].field[:],"arm.current")
    reads:[2]Api_Condition_Read
    passed,wrong:=api_conditions_read(&s,ref,conditions[:],reads[:],"conditions")
    testing.expect_value(t,wrong,"")
    testing.expectf(t,passed,"%v",reads)
}
