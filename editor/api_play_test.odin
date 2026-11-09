package editor

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import img "mirai:cook/image"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import gpu "mirai:render"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") Probe_Health :: struct {points:f32,target:core.Entity}
@(private="file") Probe_State :: enum u8 {Waiting,Playing,Won}
@(private="file") Probe_Score :: struct {points:int,state:Probe_State,seen:core.Seen}
@(private="file") Probe_Ping :: struct {entity:core.Entity,amount:int}
@(private="file") Probe_Pings :: struct {queue:core.Queue(Probe_Ping)}
@(private="file") PROBE_MOVE :: input.Action(0)
@(private="file") PROBE_JUMP :: input.Action(2)

// A game whose tick adds a point to its score, and what its pings push.
@(private="file")
Probe_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    health:core.Table(Probe_Health),
    seats:core.Table(input.Seat),
    drivables:core.Table(input.Drivable),
    moves:core.Table(input.Move_Input),
    players:input.Seats,
    bindings:input.Input_Map,
    holds:input.Hold_Requests,
    time:core.Time,
    frame:core.Frame_Time,
    input:core.Input,
    places:core.Places,
    jumps:core.Jumps,
    score:Probe_Score,
    pings:Probe_Pings,
    problems:core.Problems,
    view:core.View,
    quit_at:int, // the points at which the game asks to quit; 0: never
}
@(private="file") Probe_Editor :: struct {api:Api}

@(private="file")
probe_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Probe_World)data
    w^={}
    core.entities_init(&w.entities,allocator)
    core.table_init(&w.ids,"Id",allocator);core.table_init(&w.names,"Name",allocator)
    core.table_init(&w.transforms,"Transform",allocator);core.table_init(&w.parents,"Parent",allocator)
    core.table_init(&w.health,"Probe_Health",allocator)
    core.table_init(&w.seats,"Seat",allocator)
    core.table_init(&w.drivables,"Drivable",allocator);core.table_init(&w.moves,"Move_Input",allocator)
    w.holds.queue.items=make([dynamic]input.Hold_Request,allocator)
    w.places.queue.items=make([dynamic]core.Place_Request,allocator)
    w.jumps.queue.items=make([dynamic]core.Jump,allocator)
    w.pings.queue.items=make([dynamic]Probe_Ping,allocator)
    return true
}

@(private="file")
probe_free :: proc(data:rawptr) {
    w:=cast(^Probe_World)data
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents);core.table_destroy(&w.health);core.table_destroy(&w.seats)
    core.table_destroy(&w.drivables);core.table_destroy(&w.moves)
    delete(w.holds.queue.items)
    delete(w.places.queue.items);delete(w.jumps.queue.items);delete(w.pings.queue.items)
    core.entities_destroy(&w.entities)
}

@(private="file")
probe_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Probe_World)dst,cast(^Probe_World)src
    if !core.entities_copy(&d.entities,&s.entities) || !core.table_copy(&d.ids,&s.ids) || !core.table_copy(&d.names,&s.names) || !core.table_copy(&d.transforms,&s.transforms) || !core.table_copy(&d.parents,&s.parents) || !core.table_copy(&d.health,&s.health) || !core.table_copy(&d.seats,&s.seats) || !core.table_copy(&d.drivables,&s.drivables) || !core.table_copy(&d.moves,&s.moves) {return false}
    d.time,d.input,d.score=s.time,s.input,s.score
    d.view,d.quit_at=s.view,s.quit_at
    d.players,d.bindings=s.players,s.bindings
    return true
}

@(private="file")
probe_swap :: proc(a,b:rawptr) {
    x,y:=cast(^Probe_World)a,cast(^Probe_World)b
    x.entities,y.entities=y.entities,x.entities
    core.table_swap(&x.ids,&y.ids);core.table_swap(&x.names,&y.names);core.table_swap(&x.transforms,&y.transforms)
    core.table_swap(&x.parents,&y.parents);core.table_swap(&x.health,&y.health);core.table_swap(&x.seats,&y.seats)
    core.table_swap(&x.drivables,&y.drivables);core.table_swap(&x.moves,&y.moves)
    x.view,y.view=y.view,x.view;x.quit_at,y.quit_at=y.quit_at,x.quit_at
    x.time,y.time=y.time,x.time;x.input,y.input=y.input,x.input;x.score,y.score=y.score,x.score
    x.players,y.players=y.players,x.players;x.bindings,y.bindings=y.bindings,x.bindings
}

@(private="file")
probe_settle :: proc(data,shared,editor:rawptr) {
    w:=cast(^Probe_World)data
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities)
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.health,&w.entities);core.table_settle(&w.seats,&w.entities)
    core.table_settle(&w.drivables,&w.entities);core.table_settle(&w.moves,&w.entities)
    core.entities_settle(&w.entities)
}

// The seats take their holds and the devices of the tick, as engine/input runs them.
@(private="file")
probe_tick :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Probe_World)data
    input.input_holds(&w.seats,&w.holds,w.time,nil)
    for row in 0..<core.count(&w.seats) {
        input.seat_feed(core.at(&w.seats,row),&w.input,&w.bindings,false)
    }
    w.score.points+=1
    for ping in core.take(&w.pings.queue) {w.score.points+=ping.amount}
    if w.score.points>=10 {w.score.state=.Won}
    if w.quit_at>0 && w.score.points==w.quit_at {host.app_exit(cast(^host.App)app,0)}
    // A driven body walks by the move action until a wall at x 6, and the jump
    // action drops it 5 meters.
    if core.count(&w.drivables)==0 {return}
    hero:=w.drivables.entities[0]
    seat:=w.drivables.values[0].seat
    move:=input.seat_action(core.read(&w.seats),seat,PROBE_MOVE)
    core.get(&w.moves,hero).move={move.vector.x,0,-move.vector.y}
    place:=core.get(&w.transforms,hero)
    place.position.x=clamp(place.position.x+move.vector.x,-100,6)
    if input.seat_action(core.read(&w.seats),seat,PROBE_JUMP).pressed {place.position.y-=5}
}

@(private="file")
Probe :: struct {
    p:^platform.Platform,
    tables:[8]core.Table_Info,
    storages:[13]core.Storage_Info,
    names:[2]core.Name_Info,
    info:core.World_Info,
    app:host.App,
    data:rawptr,
    hero,foe,seat:core.Entity,
    edits:Edits,
    selection:Selection,
    viewport:Viewport,
    gui:Editor_Ui,
    document:Document,
    build:Build_State,
    editor:Probe_Editor,
    s:Session,
    out:serial.Writer,
}

@(private="file")
probe_open :: proc(t:^testing.T,f:^Probe) -> bool {
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=0.1,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) || f.p==nil {return false}
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Probe_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Probe_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Probe_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Probe_World,parents)},
        {name="Probe_Health",type=Probe_Health,info=type_info_of(Probe_Health),offset=offset_of(Probe_World,health),game=true},
        {name="Seat",type=input.Seat,info=type_info_of(input.Seat),offset=offset_of(Probe_World,seats)},
        {name="Drivable",type=input.Drivable,info=type_info_of(input.Drivable),offset=offset_of(Probe_World,drivables)},
        {name="Move_Input",type=input.Move_Input,info=type_info_of(input.Move_Input),offset=offset_of(Probe_World,moves)},
    }
    f.storages={
        {type=Api,info=type_info_of(Api),place=.Editor},
        {name="Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Probe_World,time)},
        {name="Input",type=core.Input,info=type_info_of(core.Input),offset=offset_of(Probe_World,input)},
        {name="Frame_Time",type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Probe_World,frame)},
        {name="Places",type=core.Places,info=type_info_of(core.Places),offset=offset_of(Probe_World,places)},
        {name="Jumps",type=core.Jumps,info=type_info_of(core.Jumps),offset=offset_of(Probe_World,jumps)},
        {name="Probe_Score",type=Probe_Score,info=type_info_of(Probe_Score),offset=offset_of(Probe_World,score)},
        {name="Probe_Pings",type=Probe_Pings,info=type_info_of(Probe_Pings),offset=offset_of(Probe_World,pings)},
        {name="Seats",type=input.Seats,info=type_info_of(input.Seats),offset=offset_of(Probe_World,players)},
        {name="Input_Map",type=input.Input_Map,info=type_info_of(input.Input_Map),offset=offset_of(Probe_World,bindings)},
        {name="Hold_Requests",type=input.Hold_Requests,info=type_info_of(input.Hold_Requests),offset=offset_of(Probe_World,holds)},
        {name="Problems",type=core.Problems,info=type_info_of(core.Problems),offset=offset_of(Probe_World,problems)},
        {name="View",type=core.View,info=type_info_of(core.View),offset=offset_of(Probe_World,view)},
    }
    f.names={{type=input.Action,value=i64(PROBE_MOVE),name="move"},{type=input.Action,value=i64(PROBE_JUMP),name="jump"}}
    f.info={tables=f.tables[:],storages=f.storages[:],names=f.names[:],copy=probe_copy,swap=probe_swap,settle=probe_settle,entities=offset_of(Probe_World,entities)}
    f.info.sizes[.World],f.info.aligns[.World]=size_of(Probe_World),align_of(Probe_World)
    f.info.init[.World],f.info.destroy[.World]=probe_init,probe_free
    f.info.loops[.Game][.Fixed]=probe_tick
    f.app={info=&f.info,platform=f.p,allocator=context.allocator,tick_dt=1.0/60,max_ticks=8}
    f.data=host.app_world_create(&f.app)
    world:=cast(^Probe_World)f.data
    f.hero,f.foe=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,f.hero,core.Id{1});core.add(&world.ids,f.foe,core.Id{2})
    core.add(&world.names,f.hero,core.name_make("Hero"));core.add(&world.names,f.foe,core.name_make("Foe"))
    core.add(&world.transforms,f.hero,core.Transform{{1,0,0},1,{1,1,1}})
    core.add(&world.transforms,f.foe,core.Transform{{5,0,0},1,{1,1,1}})
    core.add(&world.health,f.hero,Probe_Health{points=3})
    f.seat=core.create(&world.entities)
    core.add(&world.seats,f.seat,input.Seat{})
    world.players.local_count=1
    input.input_map_action(&world.bindings,PROBE_MOVE,.Axis2)
    input.input_map_action(&world.bindings,PROBE_JUMP,.Button)
    input.input_map_bind(&world.bindings,PROBE_JUMP,input.binding_key(.Space))
    probe_settle(f.data,nil,nil)
    f.viewport={orbit=ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    f.s={app=&f.app,info=&f.info,edit_world=f.data,editor_world=&f.editor,edits=&f.edits,selection=&f.selection,viewport=&f.viewport,gui=&f.gui,document=&f.document,build=&f.build}
    edits_reset(&f.edits,edited_world(&f.s))
    f.document.saved=edits_state(&f.edits)
    if !testing.expect(t,api_open(&f.s,0,true)==.None) {return false}
    api_state(&f.s).poll_temp=context.temp_allocator
    serial.writer_init(&f.out)
    return testing.expect(t,play_start(&f.s))
}

@(private="file")
probe_close :: proc(f:^Probe) {
    serial.writer_destroy(&f.out)
    runs_stop(&f.s)
    api_close(&f.s)
    edits_free(&f.edits)
    delete(f.selection.entities)
    delete(f.s.edit_selection.entities)
    host.app_world_scratch_free(&f.app)
    host.app_world_free(&f.app,f.data)
    delete(f.app.worlds)
    platform.destroy(f.p)
}

@(private="file")
probe_call :: proc(f:^Probe,name,params:string) -> (error:api.Error,text:string) {
    st:=api_state(&f.s)
    base.arena_reset(&st.server.scratch);serial.writer_reset(&f.out)
    error,_=api.method_execute(&st.server,api.method_find(&st.server,name),params,&f.out)
    return error,string(serial.writer_bytes(&f.out))
}

@(test)
the_game_that_plays_is_changed_and_read_by_its_storages_and_conditions :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    running:=cast(^Probe_World)run_find(&f.s,0).world
    hero:=fmt.tprintf("%016x",u64(f.hero))
    // Storages of the game, by name.
    error,text:=probe_call(f,"play.inspect",`{"storage":"Probe_*","limit":1}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"storages":{"Probe_Score":{"points": 0, "state": "Waiting", "seen": {"version": 0, "gone": 0}}`),text)
    error,_=probe_call(f,"play.inspect",`{"storage":"Score"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    // A component and a teleport, without the document.
    error,text=probe_call(f,"play.set",strings.concatenate({`{"entity":"`,hero,`","position":[4,5,6],"components":{"Probe_Health":{"target":"`,fmt.tprintf("%016x",u64(f.foe)),`"}}}`},context.temp_allocator))
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"teleported": true`),text)
    health,_:=core.get(core.read(&running.health),f.hero)
    testing.expect_value(t,health,Probe_Health{points=3,target=f.foe})
    testing.expect_value(t,entity_world(run_ref(&f.s,run_find(&f.s,0)),f.hero).position,[3]f32{4,5,6})
    testing.expect_value(t,len(running.jumps.queue.items),1)
    testing.expect_value(t,entity_local(edited_world(&f.s),f.hero).position,[3]f32{1,0,0})
    // A failure changes nothing.
    error,_=probe_call(f,"play.set",strings.concatenate({`{"entity":"`,hero,`","position":[9,9,9],"components":{"Probe_Health":{"points":"many"}}}`},context.temp_allocator))
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect_value(t,entity_world(run_ref(&f.s,run_find(&f.s,0)),f.hero).position,[3]f32{4,5,6})
    error,_=probe_call(f,"play.set",`{"entity":"00000000000000ff","position":[0,0,0]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    // Requests pushed to a queue, read by the next tick.
    error,text=probe_call(f,"play.push",strings.concatenate({`{"storage":"Probe_Pings","items":[{"entity":"`,hero,`","amount":4},{"amount":2}]}`},context.temp_allocator))
    testing.expect_value(t,error.code,0)
    testing.expect_value(t,len(running.pings.queue.items),2)
    error,_=probe_call(f,"play.push",`{"storage":"Probe_Score","items":[{}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    probe_tick(running,nil,nil,nil)
    testing.expect_value(t,running.score.points,7)
    // Conditions, as assertions.
    error,text=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"points","compare":"At_Least","number":7},{"entity":"Hero","component":"Probe_Health","field":"points","compare":"Below","number":3},{"entity":"Hero","field":"world_position.1","compare":"Equal","number":5},{"storage":"Probe_Score","field":"state","compare":"Equal","text":"Waiting"},{"entity":"Nobody","compare":"Gone"}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.has_prefix(text,`{"passed":false`),text)
    testing.expect(t,strings.contains(text,`"results":[{"passed":true,"value":7},{"passed":false,"value":3},{"passed":true,"value":5},{"passed":true,"value":"Waiting"},{"passed":true,"value":null}]`),text)
    error,_=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"lives","compare":"Equal","number":1}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,"points") && strings.contains(error.message,"state"),error.message)
    error,_=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"state","compare":"Below","text":"Won"}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

@(test)
play_set_takes_an_entity_by_its_name_and_a_parameter_it_does_not_know_is_refused_by_name :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    placed :: proc(f:^Probe) -> [3]f32 {return entity_world(run_ref(&f.s,run_find(&f.s,0)),f.hero).position}
    error,text:=probe_call(f,"play.set",`{"entity":"Hero","position":[7,8,9]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,fmt.tprintf("%016x",u64(f.hero))),text)
    testing.expect_value(t,placed(f),[3]f32{7,8,9})
    refused:=[?]struct{method,params,says:string}{
        {"play.set",`{"entity":"Nobody","position":[0,0,0]}`,"Nobody"},
        {"play.set",`{"position":[0,0,0]}`,"entity: it must be the name of an entity"},
        {"play.set",`{"entity":"Hero","position":[0,0,0],"speed":3}`,"speed"},
        {"play.check",`{"conditions":[{"storage":"Probe_Score"}],"speed":3}`,"speed"},
    }
    for c in refused {
        wrong,_:=probe_call(f,c.method,c.params)
        testing.expectf(t,wrong.code==api.INVALID_PARAMS && strings.contains(wrong.message,c.says),"%s: %v",c.params,wrong)
    }
    testing.expect_value(t,placed(f),[3]f32{7,8,9})
}

@(test)
play_get_reads_one_value_of_an_entity_as_play_inspect_and_play_check_name_it :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    hero:=fmt.tprintf("%016x",u64(f.hero))
    start:=(cast(^Probe_World)run_find(&f.s,0).world).time.tick
    testing.expect(t,probe_steps(f,2),"two ticks")
    error,text:=probe_call(f,"play.get",`{"entity":"Hero","field":"Transform.position"}`)
    testing.expect_value(t,error.code,0)
    api_result_shape_expect(t,text,Api_Play_Get_Result)
    parsed,_:=json.parse_string(text,allocator=context.temp_allocator)
    result,_:=parsed.(json.Object)
    testing.expect_value(t,result["entity"].(json.String),hero)
    testing.expect_value(t,u64(result["tick"].(json.Float)),start+2)
    position,_:=result["value"].(json.Array)
    testing.expect(t,len(position)==3 && position[0].(json.Float)==1 && position[1].(json.Float)==0,text)
    read:=[?]struct{params,value:string}{
        {strings.concatenate({`{"entity":"`,hero,`","field":"Probe_Health.points"}`},context.temp_allocator),`"value":3`},
        {`{"entity":"Hero","field":"world_position[0]"}`,`"value":1`},
        {`{"entity":"Foe","field":"position.0"}`,`"value":5`},
        {`{"entity":"Hero","field":"name"}`,`"value":"Hero"`},
    }
    for c in read {
        error,text=probe_call(f,"play.get",c.params)
        testing.expectf(t,error.code==0 && strings.contains(text,c.value),"%s: %v %s",c.params,error,text)
    }
    refused:=[?]struct{params,says:string}{
        {`{"entity":"Foe","field":"Probe_Health.points"}`,"no Probe_Health"},
        {`{"entity":"Hero","field":"Probe_Health.lives"}`,"points"},
        {`{"entity":"Hero","field":"nothing"}`,"world_position"},
        {`{"entity":"Nobody","field":"world_position"}`,"Nobody"},
        {`{"entity":"Hero"}`,"field"},
        {`{"field":"world_position"}`,"entity"},
        {`{"entity":"Hero","field":"world_position","speed":3}`,"speed"},
    }
    for c in refused {
        wrong,_:=probe_call(f,"play.get",c.params)
        testing.expectf(t,wrong.code==api.INVALID_PARAMS && strings.contains(wrong.message,c.says),"%s: %v",c.params,wrong)
    }
}

@(test)
a_step_gives_the_run_the_pointer_the_gamepads_and_the_text_of_its_ui :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    r:=run_find(&f.s,0)
    step:=Api_Step_Input{ticks=1,keys={.Enter},buttons={.Left},mouse_position={120,80},placed=true,text="go"}
    step.gamepads[1]={connected=true,down={.South}}
    step.gamepads[1].axes[.Left_X]=0.5
    play_pause(&f.s,true)
    api_step_tick(&f.s,0,0,&step,0)
    testing.expect(t,r.pointer_set && r.pointer==[2]f32{120,80})
    testing.expect(t,.Left in r.ui.pressed && r.ui.clicks==1 && r.ui.pointer==[2]f32{120,80})
    testing.expect_value(t,string(r.ui.text[:r.ui.text_count]),"go")
    platform.frame_begin(f.p)
    play_input_update(&f.s)
    game_frame(&f.s)
    running:=cast(^Probe_World)r.world
    testing.expect_value(t,running.input.mouse_position,[2]f32{120,80})
    testing.expect(t,running.input.gamepads[1].connected && .South in running.input.gamepads[1].pressed)
    testing.expect_value(t,running.input.gamepads[1].axes[.Left_X],f32(0.5))
    testing.expect(t,running.input.device.gamepad && running.input.device.slot==1 || .Enter in running.input.keys_pressed)
    testing.expect(t,r.ui.pressed=={} && r.ui.text_count==0 && .Left in r.ui.down,"the edges of the UI last one tick")
    // The next step holds what it held: no edges.
    step.placed,step.text=false,""
    api_step_tick(&f.s,0,0,&step,1)
    testing.expect(t,r.ui.pressed=={} && r.pointer==[2]f32{120,80})
    testing.expect(t,.South not_in r.input.gamepads[1].pressed && .South in r.input.gamepads[1].down)
    // Run until a condition: met before running runs nothing.
    error,_:=probe_call(f,"play.step",`{"until":[{"storage":"Probe_Score","field":"points","compare":"At_Least","number":0}]}`)
    testing.expect_value(t,error.code,0)
    error,_=probe_call(f,"play.step",`{"until":[{"storage":"Probe_Score","field":"nothing"}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    error,_=probe_call(f,"play.step",`{"gamepads":[{"slot":1},{"slot":1}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    error,_=probe_call(f,"play.step",`{"text":"tab\t"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

// Actions held by name reach the seat from the next tick play.step runs, for
// their ticks or until released; what does not fit the action or the seat is
// refused with what to give instead, and changes nothing.
@(test)
play_input_holds_actions_of_a_seat_by_name_for_the_ticks_that_run :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    running:=cast(^Probe_World)run_find(&f.s,0).world
    read:=core.read(&running.seats)
    // One tick as play.step runs it, without the frame of a window.
    step :: proc(f:^Probe) {
        held:=Api_Step_Input{ticks=1}
        api_step_tick(&f.s,0,0,&held,0)
        platform.frame_begin(f.p)
        play_input_update(&f.s)
        game_frame(&f.s)
    }
    play_pause(&f.s,true)
    refused:=[?]struct{params,says:string}{
        {`{"actions":[{"name":"jmp"}]}`,"move, jump"},
        {`{"actions":[{"name":"jump","value":1}]}`,"Button"},
        {`{"actions":[{"name":"move","value":1}]}`,"Axis2"},
        {`{"actions":[{"name":"move","vector":[0,0]}]}`,"not both 0"},
        {`{"actions":[{"name":"jump"}],"slot":2}`,"slot 2"},
        {`{}`,"release_all"},
    }
    for c in refused {
        error,_:=probe_call(f,"play.input",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
    testing.expect_value(t,len(running.holds.queue.items),0)
    error,text:=probe_call(f,"play.input",`{"actions":[{"name":"jump","ticks":1},{"name":"move","vector":[0,1]}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,fmt.tprintf(`"%016x"`,u64(f.seat))) && strings.contains(text,`"queued": 2`),text)
    testing.expect(t,!input.seat_action(read,f.seat,PROBE_JUMP).down,"nothing acts before the next tick")
    step(f)
    testing.expect(t,input.seat_action(read,f.seat,PROBE_JUMP).pressed)
    testing.expect_value(t,input.seat_action(read,f.seat,PROBE_MOVE).vector,[2]f32{0,1})
    step(f)
    testing.expect(t,input.seat_action(read,f.seat,PROBE_JUMP).released && input.seat_action(read,f.seat,PROBE_MOVE).down,"jump for one tick, move until released")
    error,_=probe_call(f,"play.input",`{"release_all":true}`)
    testing.expect_value(t,error.code,0)
    step(f)
    testing.expect(t,input.seat_action(read,f.seat,PROBE_MOVE).released)
}

// A frame of the editor as a step runs it, without the window.
@(private="file")
probe_frame :: proc(s:^Session) -> bool {
    platform.frame_begin(s.app.platform)
    play_input_update(s)
    game_frame(s)
    return true
}

// What the game of a run took in each tick and the tick of each sample.
@(private="file")
Probe_Seen :: struct {
    keys,pressed,released:[64]core.Keys,
    deltas:[64][2]f32,
    ticks:[64]u64,
    seat:core.Entity, // whose jump it reads
    jumps:[64]input.Action_State,
    count:int,
}

@(private="file")
probe_seen :: proc(s:^Session,data:rawptr,w:core.World_Ref,ran:int) -> string {
    seen:=cast(^Probe_Seen)data
    given:=core.world_storage_of(w,core.Input)
    seen.keys[seen.count],seen.deltas[seen.count]=given.keys_down,given.mouse_delta
    seen.pressed[seen.count],seen.released[seen.count]=given.keys_pressed,given.keys_released
    if seats:=core.world_table_of(w,input.Seat);seats!=nil && seen.seat!=core.NONE {seen.jumps[seen.count]=input.seat_action(core.read(seats),seen.seat,PROBE_JUMP)}
    seen.ticks[seen.count]=core.world_storage_of(w,core.Time).tick
    seen.count+=1
    return ""
}

@(test)
a_step_holds_each_segment_for_its_ticks_in_order_with_its_edges_at_its_first :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    seen:=new(Probe_Seen,context.temp_allocator)
    seen.seat=f.seat
    timeline:=[]Api_Step_Input{{ticks=2,keys={.Space},mouse_delta={3,0}},{ticks=1},{ticks=1,tap_keys={.Space}},{ticks=1,keys={.Enter}}}
    run:=Api_Step_Run{timeline=timeline,sampler={every=1,take=probe_seen,data=seen}}
    ran,_,problem:=api_step_run(&f.s,&run,probe_frame)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,ran,5)
    testing.expect_value(t,seen.count,5)
    testing.expect(t,slice.equal(seen.keys[:5],[]core.Keys{{.Space},{.Space},{},{},{.Enter}}),"each segment for its ticks in order")
    testing.expect(t,seen.deltas[0]==[2]f32{1.5,0} && seen.deltas[1]==[2]f32{1.5,0} && seen.deltas[2]=={},"the motion is spread over the ticks of its segment")
    testing.expect(t,.Space in seen.pressed[3] && .Space in seen.released[3] && .Space not_in seen.keys[3],"a tap is pressed and released inside its tick, never down")
    // The keys reach the action as those of a person: a hold of two ticks, and a tap shorter than a tick.
    j:=seen.jumps
    testing.expect(t,j[0].pressed && j[1].down && !j[1].pressed && j[2].released && j[2].released_held==2,"held two ticks")
    testing.expect(t,j[3].pressed && j[3].released && j[3].tapped && !j[3].down,"tapped inside one tick")
    testing.expect(t,!j[4].down && !j[4].pressed,"let go")
    // A hold given in seconds is the nearest whole ticks, and at least one.
    call:=api.Call{allocator=context.temp_allocator}
    given:[API_STEP_SEGMENTS]Api_Play_Segment
    given[0].seconds,given[1].seconds=0.8,0.001
    held,read:=api_segments_read(&call,given[:],`[{"seconds":0.8},{"seconds":0.001}]`,1.0/60)
    testing.expect(t,read && len(held)==2 && held[0].ticks==48 && held[1].ticks==1,call.error.message)
    error:api.Error
    refused:=[?]struct{params,says:string}{
        {`{"segments":[{"ticks":1}],"keys":["Space"]}`,"keys goes inside each of segments"},
        {`{"segments":[{"ticks":3000},{"ticks":1000}]}`,"segments run 4000 ticks"},
        {`{"segments":[]}`,"segments is empty"},
        {`{"segments":[{"ticks":1,"text":"a\tb"}]}`,"segments[0].text"},
        {`{"segments":[{"ticks":1,"seconds":0.5}]}`,"both say how long"},
        {`{"segments":[{"seconds":0}]}`,"segments[0].seconds takes"},
        {`{"segments":[{"keys":["Space"]}]}`,"or seconds"},
        {`{"segments":[{"ticks":1,"keys":["Space"],"tap_keys":["Space"]}]}`,"held or tapped"},
        {`{"segments":[{"ticks":1,"gamepads":[{"slot":0,"buttons":["South"],"tapped":["South"]}]}]}`,"held or tapped"},
        {`{"seconds":100}`,"seconds takes"},
        {`{"ticks":2,"seconds":1}`,"both say how long"},
    }
    for c in refused {
        error,_=probe_call(f,"play.step",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
}

// The devices play.input schedules play out over the ticks the next steps
// run, one tick at a time and through the path of real input: a tap shorter
// than a tick, a press of 0.05 s and a hold of 0.8 s reach the action as a
// person's, and nothing is held after them.
@(test)
play_input_schedules_the_devices_of_a_person_that_the_next_steps_play_tick_by_tick :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    error,text:=probe_call(f,"play.input",`{"segments":[{"ticks":1,"tap_keys":["Space"]},{"ticks":2},{"seconds":0.05,"keys":["Space"]},{"ticks":2},{"seconds":0.8,"keys":["Space"]},{"ticks":1}]}`)
    testing.expect(t,error.code==0 && strings.contains(text,`"scripted": 57`),text)
    testing.expect(t,play_paused(&f.s),"the Play of the user waits for the steps")
    refused:=[?]struct{method,params,says:string}{
        {"play.step",`{"keys":["Space"]}`,"play.input scheduled 57 more ticks"},
        {"play.step",`{"segments":[{"ticks":1,"tap_keys":["Enter"]}]}`,"play.input scheduled"},
        {"play.input",`{"segments":[{"ticks":1}],"slot":0}`,"slot names the seat of actions"},
    }
    for c in refused {
        error,_=probe_call(f,c.method,c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s %s: %v",c.method,c.params,error)
    }
    // One tick per step, looking at the game between them.
    seen:=new(Probe_Seen,context.temp_allocator)
    seen.seat=f.seat
    for tick in 0..<58 {
        run:=Api_Step_Run{timeline=[]Api_Step_Input{{ticks=1}},sampler={every=1,take=probe_seen,data=seen}}
        ran,_,problem:=api_step_run(&f.s,&run,probe_frame)
        if !testing.expectf(t,ran==1 && problem=="","tick %d: %s",tick,problem) {return}
        if tick==9 {
            error,text=probe_call(f,"play.status",`{}`)
            testing.expect(t,strings.contains(text,`"scripted": 47`),text)
        }
    }
    j:=seen.jumps
    testing.expect(t,j[0].pressed && j[0].released && j[0].tapped && !j[0].down,"a tap inside the first tick")
    testing.expect(t,!j[1].down && !j[2].down)
    testing.expect(t,j[3].pressed && j[5].down && j[5].held_ticks==3 && j[6].released && j[6].tapped && j[6].released_held==3,"0.05 s is three ticks, a tap")
    testing.expect(t,j[8].pressed && !j[36].holding && j[37].hold_started && j[55].holding,"0.8 s holds past the hold threshold")
    testing.expect(t,j[56].released && !j[56].tapped && j[56].released_held==48,"let go after 48 ticks")
    testing.expect(t,!j[57].down && !j[57].pressed && seen.keys[57]=={},"nothing is held after the segments")
    error,text=probe_call(f,"play.status",`{}`)
    testing.expect(t,strings.contains(text,`"scripted": 0`),text)
    // Segments replace what is left, and release_all drops them.
    error,text=probe_call(f,"play.input",`{"segments":[{"ticks":5,"keys":["Space"]}]}`)
    testing.expect(t,strings.contains(text,`"scripted": 5`),text)
    error,text=probe_call(f,"play.input",`{"release_all":true}`)
    testing.expect(t,error.code==0 && strings.contains(text,`"scripted": 0`),text)
}

@(test)
a_trace_reads_a_row_before_the_first_tick_every_some_ticks_and_after_the_last :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    r:=run_find(&f.s,0)
    running:=cast(^Probe_World)r.world
    call:=api.Call{allocator=context.temp_allocator,out=&f.out}
    p:=Api_Play_Trace{every=2}
    copy(p.entity[:],"Hero")
    copy(p.fields[0][:],"world_position[0]")
    copy(p.fields[1][:],"components.Probe_Health.points")
    trace:Api_Trace
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&p,`{"entity":"Hero","fields":["",""]}`,5,&trace),"")
    score:=Api_Play_Trace{every=2}
    copy(score.storage[:],"Probe_Score")
    copy(score.fields[0][:],"points")
    scores:Api_Trace
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&score,`{"fields":[""]}`,5,&scores),"")
    // Both traces sample at the same ticks; the run takes one sampler.
    both :: proc(s:^Session,data:rawptr,w:core.World_Ref,ran:int) -> string {
        traces:=cast(^[2]^Api_Trace)data
        if problem:=api_trace_take(s,traces[0],w,ran);problem!="" {return problem}
        return api_trace_take(s,traces[1],w,ran)
    }
    traces:=[2]^Api_Trace{&trace,&scores}
    run:=Api_Step_Run{timeline=[]Api_Step_Input{{ticks=5}},sampler={every=2,take=both,data=&traces}}
    start,points:=running.time.tick,running.score.points
    ran,_,problem:=api_step_run(&f.s,&run,probe_frame)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,ran,5)
    rows:=[4]u64{0,2,4,5}
    expected:=strings.builder_make(context.temp_allocator)
    for at,i in rows {fmt.sbprintf(&expected,`%s{{"tick":%d,"values":[%d]}}`,i>0?",":"",start+at,points+int(at))}
    testing.expect_value(t,string(serial.writer_bytes(&scores.rows)),strings.to_string(expected))
    testing.expect(t,strings.has_suffix(string(serial.writer_bytes(&trace.rows)),fmt.tprintf(`{{"tick":%d,"values":[1,3]}}`,start+5)),string(serial.writer_bytes(&trace.rows)))
    serial.writer_reset(&f.out)
    api_play_step_write(&f.s,&call,r,ran,false,&trace)
    text:=string(serial.writer_bytes(&f.out))
    testing.expect(t,strings.contains(text,fmt.tprintf(`"columns":[{{"entity":"0x%016x","name":"Hero","field":"world_position[0]"}}`,u64(f.hero))),text)
    api_result_shape_expect(t,text,Api_Play_Step_Result)
    refused:=[?]struct{params,says:string}{
        {`{"trace":{"storage":"Probe_Score","fields":["lives"]}}`,"it has"},
        {`{"trace":{"fields":["points"]}}`,"name what it reads"},
        {`{"trace":{"storage":"Probe_Score","fields":[]}}`,"trace.fields is empty"},
        {`{"ticks":3600,"trace":{"storage":"Probe_Score","fields":["points"]}}`,"give every 15 or more"},
        {`{"trace":{"entity":"Hero","fields":["components.Nothing.x"]}}`,"Nothing"},
    }
    for c in refused {
        error,_:=probe_call(f,"play.step",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
}

@(test)
a_filmstrip_cell_comes_before_the_first_tick_and_every_every_ticks_around_its_entity :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    r:=run_find(&f.s,0)
    running:=cast(^Probe_World)r.world
    call:=api.Call{allocator=context.temp_allocator,raw=`{"every":3,"count":4,"segments":[{"ticks":2,"keys":["Space"]},{"ticks":7}],"follow":"Hero"}`}
    p:=Api_Capture_Params{dt=HEADLESS_DT,seconds=-1,frames=1,every=3,count=4,size={64,32}}
    p.segments[0]={ticks=2,keys={.Space}}
    p.segments[1]={ticks=7}
    copy(p.follow[:],"Hero")
    strip,ok:=api_filmstrip_read(&f.s,&call,r,true,&p)
    testing.expect(t,ok && strip!=nil && strip.follow==f.hero,call.error.message)
    if strip==nil {return}
    testing.expect_value(t,len(strip.run.timeline),2)
    testing.expect(t,strip.run.timeline[0].keys=={.Space} && strip.run.timeline[1].ticks==7 && strip.run.timeline[1].keys=={},"the segments as they are")
    testing.expect(t,slice.equal(strip.ticks,[]int{0,3,6,9}),"a cell before the first tick and every 3")
    // The cells without the GPU: what each one sees.
    seen:Probe_Seen
    strip.run.sampler.take,strip.run.sampler.data=probe_seen,&seen
    start:=running.time.tick
    probe_seen(&f.s,&seen,run_ref(&f.s,r),0)
    ran,_,problem:=api_step_run(&f.s,&strip.run,probe_frame)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,ran,9)
    testing.expect_value(t,running.time.tick,start+9)
    // Where the entity shows and the cell around it, kept beside the image when it is far off.
    camera:=core.View{position={0,0,10},rotation=1,fov=90*math.RAD_PER_DEG,near=0.1}
    at,shown:=api_view_project(camera,{100,50,200,100},{0,0,0})
    testing.expect(t,shown && abs(at.x-200)<1e-3 && abs(at.y-100)<1e-3,"the centre of the view")
    at,shown=api_view_project(camera,{100,50,200,100},{5,0,0})
    testing.expect(t,shown && abs(at.x-225)<1e-3,"a quarter of the half width to the right")
    _,shown=api_view_project(camera,{100,50,200,100},{0,0,20})
    testing.expect(t,!shown,"behind the camera")
    testing.expect_value(t,api_filmstrip_region({225,100},{64,32},{400,300}),img.Region{193,84,64,32})
    testing.expect_value(t,api_filmstrip_region({1e9,-1e9},{64,32},{400,300}),img.Region{432,-48,64,32})
    testing.expect_value(t,api_filmstrip_region({f32(math.nan_f32()),0},{64,32},{400,300}),img.Region{168,134,64,32})
    // The answer beside the image is JSON a client reads: its grid and each cell's tick and place.
    cells:=[2]Api_Filmstrip_Cell{{tick=3,at={1,2},seen=true},{tick=6}}
    sheet:=img.Sheet{image={width=128,height=32},columns=2,rows=1,tile={64,32}}
    answer:=api_filmstrip_result("strip.png",sheet,cells[:],true,context.temp_allocator,Api_Capture_Seen{textures_pending=1})
    parsed,parse_error:=json.parse_string(answer,allocator=context.temp_allocator)
    testing.expectf(t,parse_error==.None,"the answer is not JSON: %s",answer)
    if object,is:=parsed.(json.Object);is {
        grid,listed:=object["cell"].(json.Array);testing.expect(t,listed && len(grid)==2,answer)
        taken,_:=object["cells"].(json.Array);testing.expect(t,len(taken)==2,answer)
        testing.expect(t,strings.contains(answer,`"textures_pending":1`),answer)
    }
    api_result_shape_expect(t,answer,Api_Capture_Result)
    complete:=api_filmstrip_result("strip.png",sheet,cells[:],true,context.temp_allocator,Api_Capture_Seen{instances_drawn=4})
    testing.expect(t,!strings.contains(complete,"instances_drawn") && !strings.contains(complete,"textures_pending"),complete)
    // Segments say how long it runs: nothing else is padded or refused.
    spread:=[?]struct{given,every,count:int,ticks:[]int}{
        {30,0,4,{0,10,20,30}},
        {32,0,4,{0,11,21,32}},
        {3,0,10,{0,1,2,3}},
        {7,0,1,{0}},
        {32,10,0,{0,10,20,30}},
        {8,3,4,{0,3,6}},
        {9,3,2,{0,3}},
        {-1,3,4,{0,3,6,9}},
    }
    for c in spread {testing.expectf(t,slice.equal(api_filmstrip_ticks(c.given,c.every,c.count,64,context.temp_allocator),c.ticks),"%v",c)}
    testing.expect_value(t,len(api_filmstrip_ticks(3600,1,0,64,context.temp_allocator)),64)
    evenly:=api.Call{allocator=context.temp_allocator,raw=`{"count":3,"segments":[{"ticks":5}]}`}
    even:=Api_Capture_Params{dt=HEADLESS_DT,seconds=-1,frames=1,count=3,size={64,32}}
    even.segments[0]={ticks=5}
    testing.expect(t,api_filmstrip_spread(&evenly,&even),"a count with segments is a filmstrip")
    from_count,given_count:=api_filmstrip_read(&f.s,&evenly,r,true,&even)
    testing.expect(t,given_count && from_count!=nil && slice.equal(from_count.ticks,[]int{0,3,5}),evenly.error.message)
    long:=api.Call{allocator=context.temp_allocator,raw=`{"every":3,"count":2,"segments":[{"ticks":5}]}`}
    longer:=Api_Capture_Params{dt=HEADLESS_DT,seconds=-1,frames=1,every=3,count=2,size={64,32}}
    longer.segments[0]={ticks=5}
    from_every,given_every:=api_filmstrip_read(&f.s,&long,r,true,&longer)
    testing.expect(t,given_every && from_every!=nil && api_timeline_ticks(from_every.run.timeline)==5 && slice.equal(from_every.ticks,[]int{0,3}),long.error.message)
    refused:=[?]struct{params,says:string}{
        {`{"count":4}`,"count is of a filmstrip"},
        {`{"ui":true,"count":4}`,"count is of a filmstrip"}, // ui is a field of the capture, whatever it draws
        {`{"every":3}`,"count: give the cells"},
        {`{"every":100,"count":64}`,"lower every or count"},
        {`{"every":3,"count":4,"follow":"Nobody"}`,"names no entity"},
        {`{"every":3,"count":2,"follow":"Hero","region":[0,0,10,10]}`,"not both"},
        {`{"every":3,"count":2,"size":[100,100]}`,"give follow"},
        {`{"every":3,"count":2,"region":[0,0,0,10]}`,"region takes"},
        {`{"ui":true,"width":64}`,"size the image alone"},
        {`{"every":3,"count":2,"width":64}`,"size one image"},
    }
    for c in refused {
        error,_:=probe_call(f,"capture",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
}

// Steps the run of the user ticks times, sampling every tick into trace when given.
@(private="file")
probe_steps :: proc(f:^Probe,ticks:int,trace:^Api_Trace=nil) -> bool {
    run:=Api_Step_Run{timeline=[]Api_Step_Input{{ticks=ticks}}}
    if trace!=nil {run.sampler={every=1,take=api_trace_take,data=trace}}
    ran,_,problem:=api_step_run(&f.s,&run,probe_frame)
    return ran==ticks && problem==""
}

@(private="file")
PROBE_HISTORY_TRACE :: `{"entity":"Hero","fields":["world_position[0]","components.Probe_Health.points"]}`

@(test)
the_history_reads_what_a_live_trace_read_and_a_rewound_run_steps_the_same_again :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    settings:=PLAY_HISTORY_DEFAULT
    f.s.play_history=&settings
    r:=run_find(&f.s,0)
    running:=cast(^Probe_World)r.world
    // The hero moves with the score, so that its position says each tick.
    f.info.loops[.Game][.Fixed]=proc(data,shared,editor,app:rawptr) {
        probe_tick(data,shared,editor,app)
        w:=cast(^Probe_World)data
        w.transforms.values[0].position.x=f32(w.score.points)
    }
    testing.expect(t,probe_steps(f,1))
    r.history.interval=4
    call:=api.Call{allocator=context.temp_allocator,out=&f.out}
    p:=Api_Play_Trace{every=1}
    copy(p.entity[:],"Hero")
    copy(p.fields[0][:],"world_position[0]")
    copy(p.fields[1][:],"components.Probe_Health.points")
    live:Api_Trace
    start:=running.time.tick
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&p,PROBE_HISTORY_TRACE,12,&live),"")
    testing.expect(t,probe_steps(f,12,&live))
    rows:=strings.clone(string(serial.writer_bytes(&live.rows)),context.temp_allocator)
    newest,points:=running.time.tick,running.score.points
    // The same rows from the past, and the game where it was.
    error,text:=probe_call(f,"play.history",fmt.tprintf(`{{"from":%d,"to":%d,"trace":%s}}`,start,newest,PROBE_HISTORY_TRACE))
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,fmt.tprintf(`"rows":[%s]}}`,rows)),text)
    api_result_shape_expect(t,text,Api_Play_History_Result)
    testing.expect(t,running.time.tick==newest && running.score.points==points && r.history.at==r.history.serial)
    // Every other tick from tick 7 on.
    error,text=probe_call(f,"play.history",`{"from":7,"trace":{"entity":"Hero","fields":["world_position[0]"],"every":2}}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"rows":[{"tick":7,"values":[7]},{"tick":9,"values":[9]},{"tick":11,"values":[11]},{"tick":13,"values":[13]}]`),text)
    // Rewound to tick 5, the run steps the same ticks again.
    error,_=probe_call(f,"play.seek",`{"tick":5}`)
    testing.expect_value(t,error.code,0)
    again:Api_Trace
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&p,PROBE_HISTORY_TRACE,8,&again),"")
    testing.expect(t,probe_steps(f,8,&again))
    testing.expect(t,strings.has_suffix(rows,string(serial.writer_bytes(&again.rows))),string(serial.writer_bytes(&again.rows)))
    // More rows than a call holds go on from next.
    testing.expect(t,probe_steps(f,300))
    error,text=probe_call(f,"play.history",`{"trace":{"storage":"Probe_Score","fields":["points"]}}`)
    testing.expect_value(t,error.code,0)
    oldest,last,_,_,_:=history_span(r.history)
    next:=oldest+API_TRACE_ROWS
    testing.expect(t,strings.contains(text,fmt.tprintf(`"next": %d`,next)) && strings.count(text,`{"tick":`)==API_TRACE_ROWS,text)
    error,text=probe_call(f,"play.history",fmt.tprintf(`{{"from":%d,"trace":{{"storage":"Probe_Score","fields":["points"]}}}}`,next))
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"next": 0`) && strings.count(text,`{"tick":`)==int(last-next)+1,text)
    // An edit while paused is where the frames after it start, not where the ones before lead.
    core.get(&running.health,f.hero).points=9
    testing.expect(t,probe_steps(f,1))
    error,text=probe_call(f,"play.history",`{"verify":true}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"diverged": false`),text)
    refused:=[?]struct{params,says:string}{
        {`{"from":9,"to":8,"trace":{"storage":"Probe_Score","fields":["points"]}}`,"from 9 is after to 8"},
        {`{"trace":{"storage":"Probe_Score","fields":["lives"]}}`,"it has"},
    }
    for c in refused {
        error,_=probe_call(f,"play.history",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
}

@(test)
the_last_play_keeps_its_history_after_stop_until_the_next_play :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    settings:=PLAY_HISTORY_DEFAULT
    f.s.play_history=&settings
    id:=run_find(&f.s,0).id
    testing.expect(t,probe_steps(f,1))
    run_find(&f.s,0).history.interval=4
    testing.expect(t,probe_steps(f,10))
    error,text:=probe_call(f,"play.stop",`{}`)
    testing.expect(t,error.code==0 && f.s.mode==.Edit && run_find(&f.s,0)==nil)
    // Its past answers without a game playing, and the document does not change.
    error,text=probe_call(f,"play.history",`{"verify":true}`)
    testing.expect_value(t,error.code,0)
    expected:=`"on": true, "stopped": true, "tick": 11, "oldest": 1, "newest": 11`
    testing.expect(t,strings.contains(text,expected),text)
    testing.expect(t,strings.contains(text,`"diverged": false`),text)
    api_result_shape_expect(t,text,Api_Play_History_Result)
    edited:=cast(^Probe_World)f.data
    testing.expect(t,edited.time.tick==0 && !document_dirty(&f.s),"Edit is as it was")
    // play.seek opens it again, paused at that tick.
    error,text=probe_call(f,"play.seek",`{"tick":6}`)
    testing.expect_value(t,error.code,0)
    r:=run_find(&f.s,0)
    reopened:=r!=nil && r.id==id && f.s.mode==.Paused && (cast(^Probe_World)r.world).time.tick==6
    testing.expect(t,reopened,text)
    testing.expect(t,strings.contains(text,`"tick": 6`),text)
    // The next Play discards it.
    error,_=probe_call(f,"play.stop",`{}`)
    testing.expect(t,play_start(&f.s))
    testing.expect(t,run_find(&f.s,0).id!=id && f.s.replay.world==nil)
}

@(test)
verify_says_the_first_tick_and_field_where_playing_the_past_again_differs :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    settings:=PLAY_HISTORY_DEFAULT
    f.s.play_history=&settings
    r:=run_find(&f.s,0)
    running:=cast(^Probe_World)r.world
    // Its seventh tick reads the ticks the application ran and its eleventh moves the hero by
    // them: played again, they are more.
    f.info.loops[.Game][.Fixed]=proc(data,shared,editor,app:rawptr) {
        probe_tick(data,shared,editor,app)
        w:=cast(^Probe_World)data
        ran:=(cast(^host.App)app).stats.ticks
        if w.time.tick==6 {w.score.points+=int(ran)}
        // A change cursor, which reads otherwise in a World restored from a copy, is no difference.
        if w.time.tick==3 {w.score.seen.gone=u64(ran)}
        if w.time.tick==10 {w.transforms.values[0].position.x+=f32(ran)}
    }
    testing.expect(t,probe_steps(f,1))
    r.history.interval=4
    testing.expect(t,probe_steps(f,15))
    newest,points:=running.time.tick,running.score.points
    error,text:=probe_call(f,"play.history",`{"to":5,"verify":true}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"verify": {"frames": 4, "diverged": false`),text)
    // The score differs at the copy of tick 9, where the frames from tick 5 lead.
    error,text=probe_call(f,"play.history",`{"verify":true}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"diverged": true, "tick": 9, "since": 5, "compared": 9`),text)
    testing.expect(t,strings.contains(text,`"storage": "Probe_Score", "field": "points"`),text)
    // The hero, at the first tick its transforms differ.
    error,text=probe_call(f,"play.history",`{"from":10,"verify":true}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"diverged": true, "tick": 11, "since": 9, "compared": 13`),text)
    testing.expect(t,strings.contains(text,fmt.tprintf(`"entity": "0x%016x", "name": "Hero"`,u64(f.hero))),text)
    testing.expect(t,strings.contains(text,`position[0]"`),text)
    api_result_shape_expect(t,text,Api_Play_History_Result)
    testing.expect(t,running.time.tick==newest && running.score.points==points && r.history.at==r.history.serial)
}

// A scenario file plays the game from its first tick through its steps as
// calls of the play methods and stops it: it passes when every step does,
// ends at the first that fails (a check that does not hold, an until that
// runs out of ticks, a call that fails) and refuses a file whose steps its
// methods would not take before the game starts.
@(test)
a_scenario_plays_its_steps_in_order_from_the_first_tick_and_ends_at_the_first_that_fails :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    error,_:=probe_call(f,"play.stop",`{}`)
    testing.expect_value(t,error.code,0)
    folder:=project.path_absolute(fmt.tprintf(".mirai/test-scenarios-%d",os.get_pid()),context.temp_allocator)
    defer os.remove_all(folder)
    testing.expect(t,os.make_directory_all(folder)==nil)
    write :: proc(folder,name,text:string) -> string {
        path:=fmt.tprintf("%s/%s",folder,name)
        _=os.write_entire_file(path,transmute([]u8)text)
        return path
    }
    hero:=fmt.tprintf("%016x",u64(f.hero))
    health :: proc(compare:string,points:int) -> string {
        return strings.concatenate({`{"entity":"Hero","component":"Probe_Health","field":"points","compare":"`,compare,`","number":`,fmt.tprint(points),`}`},context.temp_allocator)
    }
    write(folder,"a_weakens.mirai",strings.concatenate({`{"steps":[`,
        `{"name":"weaken","method":"play.set","params":{"entity":"`,hero,`","components":{"Probe_Health":{"points":1}}}},`,
        `{"method":"play.check","params":{"conditions":[`,health("Equal",1),`]}},`,
        `{"method":"play.step","params":{"ticks":5,"until":[`,health("Below",2),`]}},`,
        `{"method":"play.check","params":{"conditions":[{"storage":"Probe_Score","field":"points","compare":"Equal","number":0}]}}]}`},context.temp_allocator))
    write(folder,"b_misses.mirai",strings.concatenate({`{"steps":[`,
        `{"name":"fresh","method":"play.check","params":{"conditions":[`,health("Equal",3),`]}},`,
        `{"method":"play.check","params":{"conditions":[{"storage":"Probe_Score","field":"points","compare":"Equal","number":5}]}},`,
        `{"method":"play.set","params":{"entity":"`,hero,`","position":[0,0,0]}}]}`},context.temp_allocator))
    write(folder,"notes.txt","not a scenario")
    text:string
    error,text=probe_call(f,"play.scenario.run",strings.concatenate({`{"path":"`,folder,`"}`},context.temp_allocator))
    testing.expectf(t,error.code==0,"%v",error)
    api_result_shape_expect(t,text,Api_Play_Scenario_Result)
    Step :: struct {method,name:string,passed:bool,tick:u64}
    Report :: struct {path:string,passed:bool,failure:string,tick:u64,steps:int,ran:[]Step}
    Result :: struct {passed:bool,total,failed:int,scenarios:[]Report}
    result:Result
    testing.expect(t,json.unmarshal_string(text,&result,allocator=context.temp_allocator)==nil,text)
    testing.expect(t,!result.passed && result.total==2 && result.failed==1 && len(result.scenarios)==2,text)
    if len(result.scenarios)==2 {
        weakens,misses:=result.scenarios[0],result.scenarios[1]
        testing.expect(t,strings.has_suffix(weakens.path,"a_weakens.mirai") && weakens.passed && weakens.failure=="" && len(weakens.ran)==4,text)
        testing.expect(t,len(weakens.ran)==4 && weakens.ran[0].name=="weaken" && weakens.ran[2].passed && weakens.tick==0,text)
        testing.expect(t,!misses.passed && misses.steps==3 && len(misses.ran)==2 && misses.ran[0].passed && !misses.ran[1].passed,text)
        testing.expect(t,strings.contains(misses.failure,"steps[1] play.check: did not hold"),misses.failure)
    }
    testing.expect(t,strings.contains(text,`"result":{"passed":false,"tick":0,"results":[{"passed":false,"value":0}]}`),text)
    testing.expect(t,run_find(&f.s,0)==nil,"the game stops after each scenario")
    // A step that fails, an until that runs out and files the methods would not take.
    cases:=[?]struct{text,says:string}{
        {`{"steps":[{"method":"play.check","params":{"conditions":[{"storage":"Nothing"}]}}]}`,"steps[0] play.check: conditions[0]"},
        {`{"steps":[{"method":"play.step","params":{"ticks":"many"}}]}`,"steps[0].params"},
        {`{"steps":[{"method":"scene.add","params":{}}]}`,"steps are play methods"},
        {`{"steps":[{"method":"play.start"}]}`,"leave it out"},
        {`{"steps":[{"method":"play.nothing"}]}`,"is not a method"},
        {`{"start":{"players":9},"steps":[{"method":"play.step"}]}`,"start:"},
        {`{"steps":[{"method":"play.step","wait":1}]}`,`"wait" is not a key`},
        {`{"steps":[]}`,"steps: give the steps"},
        {`{"scene":"scenes/none.scene","steps":[{"method":"play.step"}]}`,"is not there"},
    }
    for c in cases {
        path:=write(folder,"case.mirai",c.text)
        error,text=probe_call(f,"play.scenario.run",strings.concatenate({`{"path":"`,path,`"}`},context.temp_allocator))
        result={}
        _=json.unmarshal_string(text,&result,allocator=context.temp_allocator)
        failure:=len(result.scenarios)==1?result.scenarios[0].failure:""
        testing.expectf(t,error.code==0 && !result.passed && strings.contains(failure,c.says),"%s: %s",c.text,text)
    }
    error,_=probe_call(f,"play.scenario.run",strings.concatenate({`{"path":"`,folder,`/none"}`},context.temp_allocator))
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,run_find(&f.s,0)==nil)
}

// The hero becomes the body of the seat, in the document and in the game
// that plays, and the ticks of a step run without a window.
@(private="file")
probe_drive :: proc(f:^Probe) {
    worlds:=[2]^Probe_World{cast(^Probe_World)f.data,cast(^Probe_World)run_find(&f.s,0).world}
    for world in worlds {
        core.add(&world.drivables,f.hero,input.Drivable{seat=f.seat})
        core.add(&world.moves,f.hero,input.Move_Input{})
        world.view=core.View{rotation=1,fov=90*math.RAD_PER_DEG,near=0.1,size={800,600}}
        probe_settle(world,nil,nil)
    }
    edits_reset(&f.edits,edited_world(&f.s))
    f.document.saved=edits_state(&f.edits)
    api_state(&f.s).step_frame=probe_frame
}

// Where a repro goes: the project is set only while it is written, as a
// fixture without a project starts its games without a recovery copy.
@(private="file")
probe_root :: proc() -> string {
    return project.path_absolute(fmt.tprintf(".mirai/test-qa-%d",os.get_pid()),context.temp_allocator)
}

@(private="file")
probe_json :: proc(t:^testing.T,text:string) -> json.Object {
    value,error:=json.parse_string(text,allocator=context.temp_allocator)
    testing.expect_value(t,error,json.Error.None)
    object,_:=value.(json.Object)
    return object
}

// One answer has what a decision needs, and it is small: the state of the
// body, the problems new since the last one, and the nearest targets to the
// camera. play.step with observe answers the same after its ticks.
@(test)
play_observe_says_in_one_small_answer_what_a_decision_needs :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    running:=cast(^Probe_World)run_find(&f.s,0).world
    error,text:=probe_call(f,"play.observe",`{"targets":["Foe","Hero"],"nearest":2}`)
    testing.expectf(t,error.code==0,"%v",error)
    api_result_shape_expect(t,text,Api_Play_Observe)
    answer:=probe_json(t,text)
    player,_:=answer["player"].(json.Object)
    position,_:=player["position"].(json.Array)
    testing.expect(t,len(position)==3 && position[0].(json.Float)==1,text)
    testing.expect(t,"grounded" not_in player,"a game without Character_State does not say")
    targets,_:=answer["targets"].(json.Array)
    if testing.expect_value(t,len(targets),1) {
        foe,_:=targets[0].(json.Object)
        testing.expect_value(t,foe["name"].(json.String) or_else "","Foe")
        testing.expect_value(t,foe["distance"].(json.Float) or_else 0,5)
        testing.expect_value(t,foe["bearing"].(json.Float) or_else 0,90)
        testing.expect(t,!(foe["on_screen"].(json.Boolean) or_else true),text)
    }
    core.report(&running.problems,f.hero,"test.broken","The hero is broken: fix it.")
    error,text=probe_call(f,"play.step",`{"ticks":2,"observe":true,"targets":["Foe"]}`)
    testing.expectf(t,error.code==0,"%v",error)
    api_result_shape_expect(t,text,Api_Play_Step_Result)
    step:=probe_json(t,text)
    testing.expect_value(t,step["ran"].(json.Float) or_else 0,2)
    testing.expect(t,"playing" not_in step,"the state of the game is left out")
    seen,_:=step["observe"].(json.Object)
    problems,_:=seen["problems"].(json.Array)
    testing.expect_value(t,len(problems),1)
    error,text=probe_call(f,"play.observe",`{}`)
    testing.expect(t,error.code==0 && "problems" not_in probe_json(t,text),"a problem is said once")
    // Asking to move without moving, past the wall: stuck.
    error,_=probe_call(f,"play.input",`{"actions":[{"name":"move","vector":[1,0]}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    for _ in 0..<3 {
        error,text=probe_call(f,"play.step",`{"ticks":60,"observe":true}`)
        testing.expectf(t,error.code==0,"%v",error)
    }
    testing.expect(t,(probe_json(t,text)["observe"].(json.Object)["stuck"].(json.Boolean) or_else false),text)
}

// The monitors see the ticks of a step: a violation has its tick, the place of
// the body and its severity, and one that goes on counts in its record.
@(test)
the_monitors_report_a_violation_with_its_tick_place_and_severity :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    error,text:=probe_call(f,"play.qa.report",`{}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,run_find(&f.s,0).qa==nil,"nothing is reserved before play.qa.start")
    error,text=probe_call(f,"play.qa.start",`{"fall_below":-2,"stuck_seconds":0.5,"frame_ms":50}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,strings.contains(text,`"repro": true`),text)
    f.app.stats.frame_ms=80
    running:=cast(^Probe_World)run_find(&f.s,0).world
    transforms:=core.get(&running.transforms,f.foe)
    transforms.scale.y=f32(math.inf_f32(1))
    error,_=probe_call(f,"play.step",`{"segments":[{"ticks":2,"keys":["Space"]},{"ticks":3}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    transforms.scale.y=1
    error,_=probe_call(f,"play.input",`{"actions":[{"name":"move","vector":[1,0]}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,_=probe_call(f,"play.step",`{"ticks":90}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,text=probe_call(f,"play.qa.report",`{}`)
    testing.expectf(t,error.code==0,"%v",error)
    api_result_shape_expect(t,text,Api_Play_Qa_Report)
    Violation :: struct {kind,severity:string,tick,count:int,position:[3]f32}
    Report :: struct {passed:bool,violations:[]Violation}
    report:Report
    testing.expect(t,json.unmarshal_string(text,&report,allocator=context.temp_allocator)==nil,text)
    testing.expect(t,!report.passed,text)
    kinds:[Api_Qa_Kind]int
    for v in report.violations {
        kind,named:=fmt.string_to_enum_value(Api_Qa_Kind,v.kind)
        testing.expect(t,named,v.kind)
        kinds[kind]+=1
        if kind==.Fell {
            testing.expect_value(t,v.severity,"Error")
            testing.expect_value(t,v.position.y,f32(-5))
            testing.expect(t,v.tick==1,text)
        }
    }
    testing.expectf(t,kinds[.Fell]==1 && kinds[.Stuck]==1 && kinds[.Frame_Time]==1 && kinds[.Non_Finite]==1,"%v %s",kinds,text)
}

// A repro plays what the run received from its first tick to the violation
// and fails there; fixed, it would pass.
// Whenever the monitors started: the log of the inputs starts with the run, and
// the repro starts them where the run did.
@(test)
a_repro_replays_the_inputs_of_a_run_and_fails_at_the_same_tick :: proc(t:^testing.T) {
    for late in ([]bool{false,true}) {repro_replay_case(t,late)}
}

@(private="file")
repro_replay_case :: proc(t:^testing.T,late:bool) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    root:=probe_root()
    defer os.remove_all(root)
    error:api.Error
    text:string
    if late {
        error,_=probe_call(f,"play.step",`{"ticks":1}`)
        testing.expectf(t,error.code==0,"%v",error)
    }
    error,text=probe_call(f,"play.qa.start",`{"fall_below":-2,"stuck_seconds":0,"non_finite":false,"problems":false}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,strings.contains(text,`"repro": true`),text)
    error,_=probe_call(f,"play.input",`{"actions":[{"name":"move","vector":[1,0],"ticks":3}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,_=probe_call(f,"play.step",`{"ticks":4}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,_=probe_call(f,"play.step",`{"segments":[{"ticks":2},{"ticks":1,"keys":["Space"]},{"ticks":4}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    f.s.project_root=root
    error,text=probe_call(f,"play.qa.report",`{"violation":0,"repro":true}`)
    f.s.project_root=""
    testing.expectf(t,error.code==0,"%v",error)
    Report :: struct {repro:string,violations:[]struct{kind:string,tick:u64}}
    report:Report
    testing.expect(t,json.unmarshal_string(text,&report,allocator=context.temp_allocator)==nil,text)
    if !testing.expect(t,len(report.violations)==1 && report.violations[0].kind=="Fell",text) {return}
    failing:=report.violations[0].tick
    testing.expect_value(t,report.repro,fmt.tprintf("tests/scenarios/bug_%d.mirai",failing))
    written,read_error:=os.read_entire_file(fmt.tprintf("%s/%s",root,report.repro),context.temp_allocator)
    testing.expect(t,read_error==nil,report.repro)
    testing.expect(t,strings.contains(string(written),`"qa":true`) && strings.contains(string(written),`"name":"move"`),string(written))
    first_step,monitors:=strings.index(string(written),`"method":"play.step"`),strings.index(string(written),`"method":"play.qa.start"`)
    testing.expectf(t,late==(first_step>=0 && first_step<monitors),"late %v: %s",late,string(written))
    error,_=probe_call(f,"play.stop",`{}`)
    testing.expect_value(t,error.code,0)
    error,text=probe_call(f,"play.scenario.run",fmt.tprintf(`{{"path":"%s/%s"}}`,root,report.repro))
    testing.expectf(t,error.code==0,"%v",error)
    Step :: struct {method:string,passed:bool,tick:u64}
    Replay :: struct {passed:bool,scenarios:[]struct{passed:bool,failure:string,tick:u64,ran:[]Step}}
    replay:Replay
    testing.expect(t,json.unmarshal_string(text,&replay,allocator=context.temp_allocator)==nil,text)
    if !testing.expect(t,!replay.passed && len(replay.scenarios)==1,text) {return}
    played:=replay.scenarios[0]
    testing.expect(t,strings.contains(played.failure,"play.check"),text)
    testing.expect(t,len(played.ran)>0 && played.ran[len(played.ran)-1].tick==failing,text)
    testing.expectf(t,played.tick==failing,"tick %d of %d: %s",played.tick,failing,text)
    // The monitors on a whole scenario report beside its steps.
    error,text=probe_call(f,"play.scenario.run",fmt.tprintf(`{{"path":"%s/%s","qa":{{"stuck_seconds":0}}}}`,root,report.repro))
    testing.expectf(t,error.code==0,"%v",error)
    api_result_shape_expect(t,text,Api_Play_Scenario_Result)
    testing.expect(t,strings.contains(text,`"qa":{"passed":`),text)
}

// The bot moves over the cells of the world, the same with the same seed,
// and its bugs come with repros; a game that asks to quit does not end it.
@(test)
the_bot_explores_the_same_with_the_same_seed_and_a_quit_does_not_end_it :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    root:=probe_root()
    defer os.remove_all(root)
    params:=`{"seed":7,"ticks":150,"move":"move","jump":"jump","cell":1}`
    play :: proc(t:^testing.T,f:^Probe,root,params:string) -> string {
        error,_:=probe_call(f,"play.stop",`{}`)
        testing.expect_value(t,error.code,0)
        error,_=probe_call(f,"play.start",`{}`)
        testing.expect_value(t,error.code,0)
        (cast(^Probe_World)run_find(&f.s,0).world).quit_at=40
        error,_=probe_call(f,"play.qa.start",`{"fall_below":-2,"stuck_seconds":0,"non_finite":false,"problems":false}`)
        testing.expect_value(t,error.code,0)
        text:string
        f.s.project_root=root
        error,text=probe_call(f,"play.explore",params)
        f.s.project_root=""
        testing.expectf(t,error.code==0,"%v",error)
        return strings.clone(text,context.temp_allocator)
    }
    first:=play(t,f,root,params)
    api_result_shape_expect(t,first,Api_Play_Explore_Result)
    testing.expect(t,run_find(&f.s,0)!=nil,"the run goes on after the game asks to quit")
    testing.expect_value(t,play(t,f,root,params),first)
    answer:=probe_json(t,first)
    testing.expect_value(t,answer["ran"].(json.Float) or_else 0,150)
    testing.expect_value(t,answer["stopped"].(json.String) or_else "","Ticks")
    testing.expect(t,(answer["cells"].(json.Float) or_else 0)>1,first)
    exits,_:=answer["exits"].(json.Array)
    testing.expect_value(t,len(exits),1)
    violations,_:=answer["violations"].(json.Array)
    repros,_:=answer["repros"].(json.Array)
    testing.expect(t,len(violations)>0 && len(repros)==1,first)
    testing.expect(t,!strings.contains(first,`"repro_error"`),first)
    error,_:=probe_call(f,"play.explore",`{"ticks":10,"move":"nothing"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

// The cells toward the least visited, whatever the tie-breaks of the seed;
// a page presses what it never pressed and goes back by what led to others.
@(test)
the_bot_goes_toward_new_cells_and_presses_every_button_of_a_menu_once :: proc(t:^testing.T) {
    keys:[64][2]i32
    visits:[64]u16
    cells:=Explore_Cells{keys=keys[:],visits=visits[:]}
    for x in -3..=3 {
        for z in -3..=0 {explore_cell_enter(&cells,{i32(x),i32(z)})}
    }
    testing.expect_value(t,explore_cell_visits(&cells,{0,0}),u16(1))
    testing.expect_value(t,explore_cell_visits(&cells,{9,9}),u16(0))
    rng:=base.rng_make(1)
    // Forward is -Z in these axes.
    chosen:=explore_direction(&cells,{0.5,0,-0.5},{1,0,0},{0,0,1},1,{},&rng)
    directions:=EXPLORE_DIRECTIONS
    testing.expect(t,directions[chosen].y>0,"toward the cells that were never entered")

    nodes:[16]Explore_Ui_Node
    pages:[8]Explore_Ui_Page
    edges:[8]Explore_Ui_Edge
    u:=Explore_Ui{nodes=nodes[:],pages=pages[:],edges=edges[:]}
    main:=[?]Explore_Ui_Button{{"ui/main.ui|start",true},{"ui/main.ui|options",true},{"ui/main.ui|locked",false}}
    options:=[?]Explore_Ui_Button{{"ui/options.ui|back",true},{"ui/options.ui|sound",true}}
    press :: proc(u:^Explore_Ui,buttons:[]Explore_Ui_Button,choice:Explore_Ui_Choice) -> int {
        node:=explore_ui_node_of(u,buttons[choice.button].key)
        u.nodes[node].activated=true
        return node
    }
    a:=explore_ui_page_of(&u,main[:])
    choice:=explore_ui_choose(&u,a,main[:])
    testing.expect_value(t,choice,Explore_Ui_Choice{kind=.Press,button=0})
    press(&u,main[:],choice)
    choice=explore_ui_choose(&u,a,main[:])
    testing.expect_value(t,choice,Explore_Ui_Choice{kind=.Press,button=1})
    node:=press(&u,main[:],choice)
    b:=explore_ui_page_of(&u,options[:])
    explore_ui_edge_note(&u,a,b,node)
    testing.expect_value(t,explore_ui_page_of(&u,main[:]),a)
    for i in 0..<2 {
        choice=explore_ui_choose(&u,b,options[:])
        testing.expect_value(t,choice,Explore_Ui_Choice{kind=.Press,button=i})
        press(&u,options[:],choice)
    }
    // Every button is pressed and only going back is left, then nothing.
    testing.expect_value(t,explore_ui_choose(&u,b,options[:]).kind,Explore_Ui_Choice_Kind.Back)
    testing.expect_value(t,explore_ui_choose(&u,b,options[:]).kind,Explore_Ui_Choice_Kind.Back)
    testing.expect_value(t,explore_ui_choose(&u,b,options[:]).kind,Explore_Ui_Choice_Kind.Done)
    testing.expect(t,!u.nodes[explore_ui_node_of(&u,"ui/main.ui|locked")].activated)
}

// A key given by a step reaches the UI of the game even if no step placed the pointer.
@(test)
a_step_with_input_reaches_the_ui_without_a_pointer :: proc(t:^testing.T) {
    r:Run
    testing.expect(t,!run_ui_scripted(&r),"the user's Play with no input of a step keeps the window")
    r.has_input=true
    testing.expect(t,run_ui_scripted(&r))
}

// With a game already playing, play.start says how it goes; once none plays
// what reads it answers playing false, empty, and what must change it asks for play.start.
@(test)
play_start_is_idempotent_and_reads_answer_without_a_game :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    world:=run_find(&f.s,0).world
    error,text:=probe_call(f,"play.start",`{}`)
    testing.expect_value(t,error.code,0)
    says :: proc(text,field:string) -> bool {
        tight,_:=strings.remove_all(text," ",context.temp_allocator)
        return strings.contains(tight,field)
    }
    testing.expect(t,says(text,`"playing":true`),text)
    testing.expect(t,run_find(&f.s,0).world==world,"a game already playing is not started again")
    error,_=probe_call(f,"play.stop",`{}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,run_find(&f.s,0)==nil)
    reads:=[?]struct{method,params:string,shape:typeid}{
        {"play.inspect",`{}`,Api_Inspect_Result},
        {"play.player",`{}`,Api_Play_Player_Result},
        {"play.view",`{}`,Api_Play_View},
        {"play.observe",`{}`,Api_Play_Observe},
        {"play.ui",`{}`,Api_Play_Ui},
        {"play.audio",`{}`,Api_Play_Audio},
        {"play.get",`{"entity":"Hero","field":"Transform.position"}`,Api_Play_Get_Result},
        {"play.check",`{"conditions":[{"storage":"Probe_Score","field":"points","compare":"At_Least","number":7}]}`,Api_Play_Check_Result},
        {"play.history",`{"verify":true}`,Api_Play_History_Result},
        {"play.qa.report",`{}`,Api_Play_Qa_Report},
    }
    for c in reads {
        error,text=probe_call(f,c.method,c.params)
        testing.expectf(t,error.code==0 && says(text,`"playing":false`),"%s: %v %s",c.method,error,text)
        api_result_shape_expect(t,text,c.shape)
    }
    changes:=[?]struct{method,params:string}{
        {"play.step",`{"ticks":1}`},
        {"play.pause",`{}`},
        {"play.destroy",`{"entity":"Hero"}`},
    }
    for c in changes {
        error,_=probe_call(f,c.method,c.params)
        testing.expectf(t,error.code!=0 && strings.contains(error.message,"play.start"),"%s: %v",c.method,error)
    }
    // Nothing offered: recovering has nothing to do and is no error.
    error,text=probe_call(f,"editor.recover",`{}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,says(text,`"resolved":false`),text)
}

// A game copies the world: what the API edits is the document, whatever the view shows.
@(test)
the_api_edits_the_document_while_a_game_plays :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    running:=run_ref(&f.s,run_find(&f.s,0))
    document:=edited_world(&f.s)
    error,_:=probe_call(f,"scene.set",`{"entity":"Hero","name":"Renamed","position":[9,0,0]}`)
    testing.expect_value(t,error.code,0)
    hero:=api_entity(document,1)
    testing.expect_value(t,entity_name(document,hero),"Renamed")
    testing.expect_value(t,entity_name(running,f.hero),"Hero")
    testing.expect(t,f.edits.cursor==1 && document_dirty(&f.s),"a step of the document")
}
