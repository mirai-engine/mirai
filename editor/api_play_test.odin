package editor

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
import "mirai:editor/history"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

@(private) Probe_Health :: struct {points:f32,target:core.Entity}
@(private) Probe_State :: enum u8 {Waiting,Playing,Won}
@(private) Probe_Score :: struct {points:int,state:Probe_State,seen:core.Seen}
@(private) Probe_Ping :: struct {entity:core.Entity,amount:int}
@(private) Probe_Pings :: struct {queue:core.Queue(Probe_Ping)}
@(private) Probe_Standing :: struct {standing:bool `mirai:"transient"`}
// on: the driven body runs and jumps over probe_level_top as a character would.
@(private) Probe_Climb :: struct {on:bool,velocity,rise:f32,platform:core.Entity}
// What a plugin that moves bodies says of the size of the hero; 0: nothing.
@(private) Probe_Body :: struct {height:f32}
@(private="file") PROBE_MOVE :: input.Action(0)
@(private="file") PROBE_JUMP :: input.Action(2)

// A game whose tick adds a point to its score, and what its pings push.
@(private)
@(test_world,host="Probe_Shared",editor="Probe_Editor")
Probe_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
    health:core.Table(Probe_Health) `mirai:"game"`,
    seats:core.Table(input.Seat),
    moves:core.Table(input.Move_Input),
    standings:core.Table(Probe_Standing),
    players:input.Seats,
    bindings:input.Input_Map,
    holds:input.Hold_Requests,
    time:core.Time,
    input:core.Input,
    frame:core.Frame_Time,
    places:core.Places,
    jumps:core.Jumps,
    score:Probe_Score,
    pings:Probe_Pings,
    view:core.View,
    queries:core.World_Queries,
    climb:Probe_Climb,
    body:Probe_Body,
    id:core.World_Id,
}
@(private) Probe_Shared :: struct {problems:core.By_World(core.Problems)}
@(private) Probe_Editor :: struct {api:Api}

// The ground of a body that climbs over x, the only axis it uses: a floor that
// ends at x 2 and starts again at x 7 with a gap between, and past it a
// platform with its top at y 2.9. The top under from.y or at it; found is false
// over the gap.
@(private="file")
probe_level_top :: proc(w:^Probe_World,x,from:f32) -> (top:f32,entity:core.Entity,found:bool) {
    if x>=12.5 && x<=14.5 && from>=2.9 {return 2.9,w.climb.platform,true}
    if (x<2 || x>=7) && from>=0 {return 0,core.NONE,true}
    return
}

@(private="file")
probe_query_open :: proc(w:core.World_Ref) -> (core.World_Query,bool) {
    return {user=w.data,probe=probe_query_probe},true
}

// Down rays only: over probe_level_top.
@(private="file")
probe_query_probe :: proc(user:rawptr,origin,direction:[3]f32,length,radius:f32,ignore:core.Entity,mask:u32) -> (found:core.World_Hit,ok:bool) {
    world:=cast(^Probe_World)user
    if !world.climb.on || direction.y>=0 {return}
    top,entity,there:=probe_level_top(world,origin.x,origin.y)
    if !there || origin.y-top>length {return}
    return {point={origin.x,top,origin.z},normal={0,1,0},distance=origin.y-top,entity=entity},true
}

// What a plugin that moves bodies says of those of the test (Body_Provider).
@(private="file")
probe_standing :: proc(w:core.World_Ref,body:core.Entity) -> (standing,known:bool) {
    state:=core.get(&(cast(^Probe_World)w.data).standings,body) or_return
    return state.standing,true
}

@(private="file")
probe_measure :: proc(w:core.World_Ref,body:core.Entity) -> (measure:Body_Measure,known:bool) {
    height:=(cast(^Probe_World)w.data).body.height
    return {height=height},height>0
}

// A character of a test: it runs at 5 m/s, a jump held rises at 6 m/s for up to
// 0.6 s and it falls at 30 m/s2, so a jump let go early goes short.
@(private="file")
probe_climb_tick :: proc(w:^Probe_World,hero,seat:core.Entity) {
    dt:=f32(1.0/60)
    climb:=&w.climb
    place:=core.edit(&w.transforms,hero)
    standing:=&core.edit(&w.standings,hero).standing
    jump:=input.seat_action(core.read(&w.seats),seat,PROBE_JUMP)
    if jump.pressed && standing^ {climb.velocity,climb.rise=6,0.6}
    if jump.down && climb.rise>0 {
        climb.velocity=6
        climb.rise-=dt
    } else {
        climb.rise=0
        climb.velocity-=30*dt
    }
    place.position.x+=input.seat_action(core.read(&w.seats),seat,PROBE_MOVE).vector.x*5*dt
    from:=place.position.y
    place.position.y+=climb.velocity*dt
    top,_,there:=probe_level_top(w,place.position.x,from)
    standing^=there && place.position.y<=top && climb.velocity<=0
    if standing^ {place.position.y,climb.velocity=top,0}
}

// The seats take their holds and the devices of the tick, as engine/input runs them.
@(private="file")
probe_tick :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Probe_World)data
    // Its storages are written: their revisions move, as when a function of the loop receives them.
    core.revisions_moved(core.world_revisions(core.world_ref(data,(cast(^host.App)app).info)))
    input.input_holds(&w.seats,&w.holds,w.time,nil)
    for row in 0..<core.count(&w.seats) {
        input.seat_feed(core.edit_at(&w.seats,row),&w.input,&w.bindings,false,w.time.dt)
    }
    w.score.points+=1
    for ping in core.take(&w.pings.queue) {w.score.points+=ping.amount}
    if w.score.points>=10 {w.score.state=.Won}
    // A driven body walks by the move action until a wall at x 6, and the jump
    // action drops it 5 meters.
    seat,hero:=core.NONE,core.NONE
    for value,row in w.seats.values {
        if value.body!=core.NONE {seat,hero=w.seats.entities[row],value.body}
    }
    if hero==core.NONE {return}
    if w.climb.on {
        probe_climb_tick(w,hero,seat)
        return
    }
    move:=input.seat_action(core.read(&w.seats),seat,PROBE_MOVE)
    core.edit(&w.moves,hero).move={move.vector.x,0,-move.vector.y}
    place:=core.edit(&w.transforms,hero)
    place.position.x=clamp(place.position.x+move.vector.x,-100,6)
    if input.seat_action(core.read(&w.seats),seat,PROBE_JUMP).pressed {place.position.y-=5}
}

@(private="file")
Probe :: struct {
    p:^platform.Platform,
    names:[2]core.Name_Info,
    info:core.World_Info,
    shared:Probe_Shared,
    app:host.App,
    data:rawptr,
    hero,foe,seat:core.Entity,
    using edited:Test_Session,
    build:Build_State,
    editor:Probe_Editor,
    out:serial.Writer,
}

@(private="file")
probe_open :: proc(t:^testing.T,f:^Probe) -> bool {
    f.info=test_info(t,Probe_World) or_return
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=0.1,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) || f.p==nil {
        test_info_destroy(&f.info)
        return false
    }
    f.names={{type=input.Action,value=i64(PROBE_MOVE),name="move"},{type=input.Action,value=i64(PROBE_JUMP),name="jump"}}
    f.info.names=f.names[:]
    test_info_index(&f.info)
    f.info.loops[.Game][.Fixed]=probe_tick
    f.app={info=&f.info,shared=&f.shared,platform=f.p,allocator=context.allocator,tick_dt=1.0/60,max_ticks=8}
    f.data=host.app_world_create(&f.app)
    world:=cast(^Probe_World)f.data
    world.queries.open=probe_query_open
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
    core.settle(&f.info,f.data,nil)
    f.viewport={orbit=ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    test_session_open(&f.edited,core.world_ref(f.data,&f.info))
    f.s.app,f.s.editor_world,f.s.build=&f.app,&f.editor,&f.build
    f.document.saved=history.edits_state(&f.edits)
    api_opened,api_problem:=api_open(&f.s,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return false}
    api_state(&f.s).poll_temp=context.temp_allocator
    serial.writer_init(&f.out)
    return testing.expect(t,play_start(&f.s))
}

@(private="file")
probe_close :: proc(f:^Probe) {
    serial.writer_destroy(&f.out)
    runs_stop(&f.s)
    api_close(&f.s)
    test_session_close(&f.edited)
    delete(f.s.edit_selection.entities)
    host.app_world_scratch_free(&f.app)
    host.app_world_free(&f.app,f.data)
    delete(f.app.worlds)
    core.world_destroy(&f.info,.Shared,&f.shared)
    platform.destroy(f.p)
    test_info_destroy(&f.info)
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
    testing.expect(t,strings.contains(text,`"storages": {"Probe_Score": {"points": 0, "state": "Waiting", "seen": {"version": 0, "gone": 0}}`),text)
    testing.expect(t,strings.contains(text,`"entities": []`) && strings.contains(text,`"matched": 0`) && strings.contains(text,`"left_out"`),"a storage named answers no entities")
    error,text=probe_call(f,"play.inspect",`{"storage":"Probe_*","name":"Hero"}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"name": "Hero"`) && strings.contains(text,`"storages"`),"entities named too keep them")
    error,_=probe_call(f,"play.inspect",`{"storage":"Score"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    // A component and a teleport, without the document.
    error,text=probe_call(f,"play.set",strings.concatenate({`{"entity":"`,hero,`","position":[4,5,6],"components":{"Probe_Health":{"target":"`,fmt.tprintf("%016x",u64(f.foe)),`"}}}`},context.temp_allocator))
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"teleported": true`),text)
    health,_:=core.get(&running.health,f.hero)
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
    probe_tick(running,nil,nil,&f.app)
    testing.expect_value(t,running.score.points,7)
    // Conditions, as assertions.
    error,text=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"points","compare":"At_Least","number":7},{"entity":"Hero","field":"Probe_Health.points","compare":"Below","number":3},{"entity":"Hero","field":"world_position.1","compare":"Equal","number":5},{"storage":"Probe_Score","field":"state","compare":"Equal","text":"Waiting"},{"entity":"Nobody","compare":"Gone"}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.has_prefix(api.json_compact(text),`{"passed":false`),text)
    testing.expect(t,strings.contains(api.json_compact(text),`"results":[{"passed":true,"value":7},{"passed":false,"value":3},{"passed":true,"value":5},{"passed":true,"value":"Waiting"},{"passed":true,"value":null}]`),text)
    error,_=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"lives","compare":"Equal","number":1}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,"points") && strings.contains(error.message,"state"),error.message)
    error,_=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"state","compare":"Below","text":"Won"}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

// The structs of its params and of its result are the only description of a
// method: each method of the editor gives a JSON Schema of both from them, a
// method takes a struct or nothing, and none answers JSON it does not declare.
@(test)
every_method_of_the_editor_is_described_by_its_types :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    server:=&api_state(&f.s).server
    testing.expect(t,server.method_count>100,"the methods of the editor are registered")
    buffer:=make([]u8,256*1024,context.temp_allocator)
    for &method in server.methods[:server.method_count] {
        if method.params!=serial.TYPE_NONE {
            testing.expectf(t,server.schema.types[method.params].kind==.Struct,"%s: its params are a struct",method.name)
        }
        if method.result!=serial.TYPE_NONE {
            testing.expectf(t,server.schema.types[method.result].kind!=.Json,"%s answers JSON whose shape it does not declare: give its result a struct",method.name)
        } else {
            testing.expectf(t,!method.writes_result,"%s writes a result without a type",method.name)
        }
        for result in ([2]bool{false,true}) {
            w:serial.Writer
            serial.writer_init_fixed(&w,buffer)
            api.method_schema_write(&w,server,&method,result)
            text:=string(serial.writer_bytes(&w))
            testing.expectf(t,w.overflow==0 && api.json_valid(context.temp_allocator,text) && api.json_member(text,"type")!="","%s: %s",method.name,text[:min(len(text),200)])
        }
    }
    // A method that has no params type takes none, and one whose handler writes what it does not declare fails.
    error,_:=probe_call(f,"play.status",`{"anything":1}`)
    testing.expect(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,"play.status takes no params"),error.message)
    // What the state of the editor does not allow now has one code, with the method that changes it.
    error,_=probe_call(f,"play.stop",`{}`)
    testing.expect_value(t,error.code,0)
    for method in ([]string{"play.player","play.get"}) {
        error,_=probe_call(f,method,method=="play.get"?`{"entity":"Hero","field":"Transform.position"}`:`{}`)
        testing.expectf(t,error.code==api.NOT_NOW && error.message==API_NO_GAME && error.data==`{"fix":"play.start"}`,"%s: %v",method,error)
    }
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
        {"play.set",`{"position":[0,0,0]}`,"entity is required"},
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
    testing.expect_value(t,result["entity"].(json.String),fmt.tprintf("0x%s",hero))
    testing.expect_value(t,u64(result["tick"].(json.Float)),start+2)
    position,_:=result["value"].(json.Array)
    testing.expect(t,len(position)==3 && position[0].(json.Float)==1 && position[1].(json.Float)==0,text)
    read:=[?]struct{params,value:string}{
        {strings.concatenate({`{"entity":"`,hero,`","field":"Probe_Health.points"}`},context.temp_allocator),`"value":3`},
        {`{"entity":"Hero","field":"world_position[0]"}`,`"value":1`},
        {`{"entity":"Foe","field":"position.0"}`,`"value":5`},
        {`{"entity":"Hero","field":"name"}`,`"value":"Hero"`},
        {`{"entity":"Hero","field":"Transform.position.0"}`,`"value":1`},
        {`{"entity":"Hero","field":"Transform.position[0]"}`,`"value":1`},
    }
    for c in read {
        error,text=probe_call(f,"play.get",c.params)
        testing.expectf(t,error.code==0 && strings.contains(api.json_compact(text),c.value),"%s: %v %s",c.params,error,text)
    }
    error,text=probe_call(f,"play.check",`{"conditions":[{"entity":"Hero","field":"Transform.position.0","compare":"Equal","number":1},{"entity":"Hero","field":"Transform.position[0]","compare":"Equal","number":1},{"entity":"Foe","field":"Probe_Health.points","compare":"Gone"}]}`)
    testing.expectf(t,error.code==0 && strings.contains(api.json_compact(text),`"passed":true`),"%v %s",error,text)
    refused:=[?]struct{params,says:string}{
        {`{"entity":"Hero","field":"components.Probe_Health.points"}`,"named by itself"},
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
    read:=&running.seats
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
    error,text:=probe_call(f,"play.input",`{"actions":[{"name":"jump","for":1},{"name":"move","vector":[0,1]}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,fmt.tprintf(`"0x%016x"`,u64(f.seat))) && strings.contains(text,`"queued": 2`),text)
    testing.expect(t,!input.seat_action(core.read(read),f.seat,PROBE_JUMP).down,"nothing acts before the next tick")
    step(f)
    testing.expect(t,input.seat_action(core.read(read),f.seat,PROBE_JUMP).pressed)
    testing.expect_value(t,input.seat_action(core.read(read),f.seat,PROBE_MOVE).vector,[2]f32{0,1})
    step(f)
    testing.expect(t,input.seat_action(core.read(read),f.seat,PROBE_JUMP).released && input.seat_action(core.read(read),f.seat,PROBE_MOVE).down,"jump for one tick, move until released")
    error,_=probe_call(f,"play.input",`{"release_all":true}`)
    testing.expect_value(t,error.code,0)
    step(f)
    testing.expect(t,input.seat_action(core.read(read),f.seat,PROBE_MOVE).released)
}

// Keys named by consecutive calls are one hold, as a person keeps a key down:
// the first call presses it, the ones after go on with no release between
// them, and the call that omits it lets go.
@(test)
a_key_named_by_consecutive_calls_stays_held_and_a_call_that_omits_it_lets_go :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    api_state(&f.s).step_frame=probe_frame
    running:=cast(^Probe_World)run_find(&f.s,0).world
    read:=&running.seats
    call :: proc(t:^testing.T,f:^Probe,params:string) {
        error,_:=probe_call(f,"play.step",params)
        testing.expect_value(t,error.code,0)
    }
    call(t,f,`{"keys":["Space"]}`)
    jump:=input.seat_action(core.read(read),f.seat,PROBE_JUMP)
    testing.expect(t,jump.pressed && jump.down,"the first call presses it")
    call(t,f,`{"keys":["Space"],"for":3}`)
    jump=input.seat_action(core.read(read),f.seat,PROBE_JUMP)
    testing.expect(t,jump.down && !jump.pressed && !jump.released && running.input.keys_released=={},"the next call goes on holding it")
    call(t,f,`{"keys":["Space"]}`)
    jump=input.seat_action(core.read(read),f.seat,PROBE_JUMP)
    testing.expect(t,jump.down && !jump.pressed && !jump.released,"also over a third call")
    call(t,f,`{"for":1}`)
    jump=input.seat_action(core.read(read),f.seat,PROBE_JUMP)
    testing.expect(t,jump.released && !jump.down && .Space in running.input.keys_released,"a call that omits it lets go")
}

// A frame that also counts the moves asked of the seat for its tick, into the int of the context.
@(private="file")
probe_frame_moves :: proc(s:^Session) -> bool {
    requests:=core.world_storage_of(run_ref(s,run_find(s,0)),input.Hold_Requests)
    for r in requests.queue.items {
        if r.action==PROBE_MOVE {(cast(^int)context.user_ptr)^+=1}
    }
    return probe_frame(s)
}

// A drive steers the focused player by the move action of the game to its
// target, and says where it ended and why: within its distance, at its ticks
// or at its until; blocked it jumps and at last gives up, not spending
// the ticks left. Going straight it asks its move once, not every tick.
@(test)
a_drive_steers_the_focused_player_to_its_target_and_says_where_and_why_it_stopped :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    running:=cast(^Probe_World)run_find(&f.s,0).world
    place:=core.edit(&running.transforms,f.hero)
    moves:=0
    context.user_ptr=&moves
    api_state(&f.s).step_frame=probe_frame_moves
    error,text:=probe_call(f,"play.step",`{"drive":{"entity":"Foe","within":0.5,"move":"move"},"for":300}`)
    api_state(&f.s).step_frame=probe_frame
    testing.expectf(t,error.code==0,"%v",error)
    api_result_shape_expect(t,text,Api_Play_Step_Result)
    testing.expect(t,strings.contains(text,`"drive": {"stopped": "Arrived"`) && strings.contains(text,`"ran": 4`),text)
    testing.expect_value(t,place.position.x,5)
    testing.expect_value(t,moves,1)
    // The limit of the step, and the conditions of the step stop it too.
    place.position={1,0,0}
    error,text=probe_call(f,"play.step",`{"drive":{"position":[5,0,0],"move":"move"},"for":2}`)
    testing.expect(t,error.code==0 && strings.contains(text,`"stopped": "Ticks"`) && strings.contains(text,`"ran": 2`),text)
    place.position={1,0,0}
    points:=running.score.points+2
    error,text=probe_call(f,"play.step",fmt.tprintf(`{{"drive":{{"position":[5,0,0],"move":"move"}},"for":100,"until":[{{"storage":"Probe_Score","field":"points","compare":"At_Least","number":%d}}]}}`,points))
    testing.expect(t,error.code==0 && strings.contains(text,`"stopped": "Until"`) && strings.contains(text,`"met": true`),text)
    // Behind the wall at x 6: it jumps, sidesteps and stops getting closer, its ticks left over.
    place.position={1,0,0}
    error,text=probe_call(f,"play.step",`{"drive":{"position":[9,0,0],"move":"move"}}`)
    testing.expect(t,error.code==0 && strings.contains(text,`"stopped": "Stuck"`) && !strings.contains(text,`"ran": 1800`),text)
    testing.expect(t,place.position.x==6 && place.position.y<0,"it reached the wall and jumped")
    refused:=[?]struct{params,says:string}{
        {`{"drive":{}}`,"name where it goes"},
        {`{"drive":{"entity":"Foe","position":[1,0,0]}}`,"give one"},
        {`{"drive":{"entity":"Nobody"}}`,"Nobody"},
        {`{"drive":{"position":[0,0,0]},"segments":[{"for":1}]}`,"without segments or press"},
        {`{"drive":{"position":[0,0,0],"move":"nothing"}}`,"is not a Axis2 action"},
        {`{"look_at":{}}`,"name what it looks at"},
        {`{"look_at":{"entity":"Foe"},"mouse_delta":[1,0]}`,"leave mouse_delta out"},
        {`{"look_at":{"entity":"Foe"}}`,"Camera_Follow"},
    }
    for c in refused {
        error,_=probe_call(f,"play.step",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
}

// With a way of a plugin it heads for the next point of it, not at the target.
@(test)
a_drive_heads_for_the_next_point_of_the_way_a_plugin_gives :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    way :: proc(s:^Session,w:core.World_Ref,body:core.Entity,goal:[3]f32) -> Route {
        at:=entity_world(w,body).position
        return at.x<2?Route{state=.Found,next={8,0,0},left=9-at.x}:{}
    }
    f.s.providers={library=f.s.library_generation+1,route={next=way},routes=true}
    running:=cast(^Probe_World)run_find(&f.s,0).world
    place:=core.edit(&running.transforms,f.hero)
    place.position={0,0,0}
    error,text:=probe_call(f,"play.step",`{"drive":{"position":[-4,0,0],"move":"move"},"for":2}`)
    testing.expect(t,error.code==0 && strings.contains(text,`"stopped": "Ticks"`),text)
    testing.expectf(t,place.position.x>0,"along the way, away from its target: %v",place.position)
}

// Over a gap a drive takes off at the edge and holds the jump for all it needs,
// and a platform raised over its feet it arrives at standing on it, not under it.
// Whether its body stands is what the plugin that moves it says, and nothing
// without one.
@(test)
a_drive_holds_its_jump_across_a_gap_and_stands_on_a_raised_platform :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    running:=cast(^Probe_World)run_find(&f.s,0).world
    platform:=core.create(&running.entities)
    core.add(&running.names,platform,core.name_make("Platform"))
    core.add(&running.transforms,platform,core.Transform{{13.5,2.9,0},1,{1,1,1}})
    core.add(&running.standings,f.hero,Probe_Standing{standing=true})
    core.settle(&f.info,running,nil)
    w:=run_ref(&f.s,run_find(&f.s,0))
    testing.expect_value(t,play_stance(&f.s,w,f.hero),Stance.Unknown)
    f.s.providers={library=f.s.library_generation+1,bodies={0={standing=probe_standing}},body_count=1}
    testing.expect_value(t,play_stance(&f.s,w,f.hero),Stance.Standing)
    testing.expect_value(t,play_stance(&f.s,w,f.foe),Stance.Unknown)
    running.climb.on,running.climb.platform=true,platform
    place:=core.edit(&running.transforms,f.hero)
    place.position={0,0,0}
    error,text:=probe_call(f,"play.step",`{"drive":{"position":[10,0,0],"within":0.5,"move":"move"},"for":"5s"}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,strings.contains(text,`"stopped": "Arrived"`),text)
    testing.expect(t,place.position.y==0 && abs(place.position.x-10)<=0.6,"over the gap, on the far floor")
    testing.expect_value(t,play_stance(&f.s,run_ref(&f.s,run_find(&f.s,0)),f.hero),Stance.Standing)
    error,text=probe_call(f,"play.step",`{"drive":{"entity":"Platform","move":"move"},"for":"5s"}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,strings.contains(text,`"stopped": "Arrived"`),text)
    testing.expectf(t,place.position.y==2.9 && place.position.x>=12.5 && place.position.x<=14.5,"on its top: %v",place.position)
}

// What is at hand to a drive is measured by the body it steers: a point over
// the head of a small one is not, as it is to a person, which a body that
// does not say its size is taken for.
@(test)
a_drive_measures_what_is_at_hand_by_the_body_it_steers :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    f.s.providers={library=f.s.library_generation+1,bodies={0={measure=probe_measure}},body_count=1}
    running:=cast(^Probe_World)run_find(&f.s,0).world
    place:=core.edit(&running.transforms,f.hero)
    cases:=[?]struct{height:f32,stopped:string}{{0,"Arrived"},{BODY_PERSON.height*0.1,"Ticks"}}
    for c in cases {
        place.position={1,0,0}
        running.body.height=c.height
        error,text:=probe_call(f,"play.step",`{"drive":{"position":[4,1.5,0],"move":"move"},"for":10}`)
        testing.expectf(t,error.code==0 && strings.contains(text,fmt.tprintf(`"stopped": "%s"`,c.stopped)),"a body %v m tall: %s",c.height,text)
    }
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
probe_seen :: proc(seen:^Probe_Seen,w:core.World_Ref) {
    given:=core.world_storage_of(w,core.Input)
    seen.keys[seen.count],seen.deltas[seen.count]=given.keys_down,given.mouse_delta
    seen.pressed[seen.count],seen.released[seen.count]=given.keys_pressed,given.keys_released
    if seats:=core.world_table_of(w,input.Seat);seats!=nil && seen.seat!=core.NONE {seen.jumps[seen.count]=input.seat_action(seats,seen.seat,PROBE_JUMP)}
    seen.ticks[seen.count]=core.world_storage_of(w,core.Time).tick
    seen.count+=1
}

// A frame that also reads what the game took, into the Probe_Seen of the context.
@(private="file")
probe_frame_seen :: proc(s:^Session) -> bool {
    probe_frame(s)
    probe_seen(cast(^Probe_Seen)context.user_ptr,run_ref(s,run_find(s,0)))
    return true
}

@(test)
a_step_holds_each_segment_for_its_ticks_in_order_with_its_edges_at_its_first :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    seen:=new(Probe_Seen,context.temp_allocator)
    seen.seat=f.seat
    timeline:=[]Api_Step_Input{{ticks=2,keys={.Space},mouse_delta={3,0}},{ticks=1},{ticks=1,tap_keys={.Space}},{ticks=1,keys={.Enter}}}
    run:=Api_Step_Run{timeline=timeline}
    context.user_ptr=seen
    ran,_,problem:=api_step_run(&f.s,&run,probe_frame_seen)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,ran,5)
    testing.expect_value(t,seen.count,5)
    testing.expect(t,slice.equal(seen.keys[:5],[]core.Keys{{.Space},{.Space},{},{},{.Enter}}),"each segment for its ticks in order")
    testing.expect(t,seen.deltas[0]==[2]f32{1.5,0} && seen.deltas[1]==[2]f32{1.5,0} && seen.deltas[2]=={},"the motion is spread over the ticks of its segment")
    testing.expect(t,.Space in seen.pressed[3] && .Space in seen.released[3] && .Space not_in seen.keys[3],"a tap is pressed and released inside its tick, never down")
    // The keys reach the action as those of a person: a hold of two ticks, and a tap shorter than a tick.
    j:=seen.jumps
    testing.expect(t,j[0].pressed && j[1].down && !j[1].pressed && j[2].released && abs(j[2].released_held-2.0/60)<1e-5,"held two ticks")
    testing.expect(t,j[3].pressed && j[3].released && j[3].tapped && !j[3].down,"tapped inside one tick")
    testing.expect(t,!j[4].down && !j[4].pressed,"let go")
    // A press is the pointer over the button, the button held, and let go.
    pressed:=api_timeline_presses([]Api_Step_Input{{ticks=0,press="Start"}},context.temp_allocator)
    if testing.expect_value(t,len(pressed),3) {
        testing.expect(t,pressed[0].ticks==1 && pressed[0].press=="Start" && pressed[0].buttons=={},"the pointer first, for hover")
        testing.expect(t,pressed[1].ticks==API_PRESS_HELD && pressed[1].buttons=={.Left},"then held")
        testing.expect(t,pressed[2].ticks==1 && pressed[2].buttons=={},"then let go")
    }
    // A hold given in seconds is the nearest whole ticks, and at least one.
    call:=api.Call{allocator=context.temp_allocator}
    given:[API_STEP_SEGMENTS]Api_Play_Segment
    copy(given[0].duration[:],"0.8s");copy(given[1].duration[:],"0.001s")
    held,read:=api_segments_read(&call,given[:],`[{"for":"0.8s"},{"for":"0.001s"}]`,1.0/60)
    testing.expect(t,read && len(held)==2 && held[0].ticks==48 && held[1].ticks==1,call.error.message)
    error:api.Error
    refused:=[?]struct{params,says:string}{
        {`{"segments":[{"for":1}],"keys":["Space"]}`,"keys goes inside each of segments"},
        {`{"segments":[{"for":3000},{"for":1000}]}`,"segments run 4000 ticks"},
        {`{"segments":[]}`,"segments is empty"},
        {`{"segments":[{"for":1,"text":"a\tb"}]}`,"segments[0].text"},
        {`{"segments":[{"for":"0s"}]}`,"segments[0].for"},
        {`{"segments":[{"keys":["Space"]}]}`,"segments[0].for: give how long"},
        {`{"segments":[{"keys":["Space"]}]}`,"or seconds"},
        {`{"segments":[{"for":1,"keys":["Space"],"tap_keys":["Space"]}]}`,"held or tapped"},
        {`{"segments":[{"for":1,"gamepads":[{"slot":0,"buttons":["South"],"tapped":["South"]}]}]}`,"held or tapped"},
        {`{"for":"100s"}`,"outside 1 to 3600 ticks"},
        {`{"for":"soon"}`,"for takes ticks as a number"},
        {`{"for":1.5}`,"for takes ticks as a number"},
        {`{"press":"Start","keys":["Space"]}`,"press is a whole click"},
        {`{"press":"Start"}`,"no screen"},
    }
    for c in refused {
        error,_=probe_call(f,"play.step",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
}

// The devices of the segments of a step go through the path of real input: a
// tap shorter than a tick, a press of 0.05 s and a hold of 0.8 s reach the
// action as a person's, and nothing is held after them.
@(test)
a_step_plays_the_devices_of_a_person_tick_by_tick :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    seen:=new(Probe_Seen,context.temp_allocator)
    seen.seat=f.seat
    timeline:=[]Api_Step_Input{{ticks=1,tap_keys={.Space}},{ticks=2},{ticks=3,keys={.Space}},{ticks=2},{ticks=48,keys={.Space}},{ticks=2}}
    run:=Api_Step_Run{timeline=timeline}
    context.user_ptr=seen
    ran,_,problem:=api_step_run(&f.s,&run,probe_frame_seen)
    testing.expect_value(t,problem,"")
    if !testing.expect_value(t,ran,58) {return}
    j:=seen.jumps
    testing.expect(t,j[0].pressed && j[0].released && j[0].tapped && !j[0].down,"a tap inside the first tick")
    testing.expect(t,!j[1].down && !j[2].down)
    testing.expect(t,j[3].pressed && j[5].down && abs(j[5].held-3.0/60)<1e-5 && j[6].released && j[6].tapped && abs(j[6].released_held-3.0/60)<1e-5,"0.05 s is three ticks, a tap")
    testing.expect(t,j[8].pressed && !j[36].holding && j[37].hold_started && j[55].holding,"0.8 s holds past the hold threshold")
    testing.expect(t,j[56].released && !j[56].tapped && abs(j[56].released_held-48.0/60)<1e-4,"let go after 48 ticks")
    testing.expect(t,!j[57].down && !j[57].pressed && seen.keys[57]=={},"nothing is held after the segments")
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
    copy(p.fields[1][:],"Probe_Health.points")
    trace:Api_Trace
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&p,`{"entity":"Hero","fields":["",""]}`,5,&trace),"")
    score:=Api_Play_Trace{every=2}
    copy(score.storage[:],"Probe_Score")
    copy(score.fields[0][:],"points")
    scores:Api_Trace
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&score,`{"fields":[""]}`,5,&scores),"")
    run:=Api_Step_Run{timeline=[]Api_Step_Input{{ticks=5}},sampler=&scores,every=2}
    start,points:=running.time.tick,running.score.points
    ran,_,problem:=api_step_run(&f.s,&run,probe_frame)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,ran,5)
    rows:=[4]u64{0,2,4,5}
    expected:=strings.builder_make(context.temp_allocator)
    for at,i in rows {fmt.sbprintf(&expected,`%s{{"tick":%d,"values":[%d]}}`,i>0?",":"",start+at,points+int(at))}
    testing.expect_value(t,trace_rows_text(&scores),strings.to_string(expected))
    testing.expect_value(t,api_trace_take(&f.s,&trace,run_ref(&f.s,r),ran),"")
    testing.expect(t,strings.has_suffix(trace_rows_text(&trace),fmt.tprintf(`{{"tick":%d,"values":[1,3]}}`,start+5)),trace_rows_text(&trace))
    table:=api_trace_table(&f.s,&trace)
    testing.expect(t,len(table.columns)>0 && table.columns[0].entity==f.hero && table.columns[0].name=="Hero" && table.columns[0].field=="world_position[0]")
    refused:=[?]struct{params,says:string}{
        {`{"trace":{"storage":"Probe_Score","fields":["lives"]}}`,"it has"},
        {`{"trace":{"fields":["points"]}}`,"name what it reads"},
        {`{"trace":{"storage":"Probe_Score","fields":[]}}`,"trace.fields is empty"},
        {`{"for":3600,"trace":{"storage":"Probe_Score","fields":["points"]}}`,"give every 15 or more"},
        {`{"trace":{"entity":"Hero","fields":["Nothing.x"]}}`,"Nothing"},
        {`{"trace":{"entity":"Hero","fields":["components.Probe_Health.points"]}}`,"named by itself"},
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
    call:=api.Call{allocator=context.temp_allocator,raw=`{"every":3,"count":4,"segments":[{"for":2,"keys":["Space"]},{"for":7}],"follow":"Hero"}`}
    p:=Api_Capture_Params{dt=HEADLESS_DT,seconds=-1,frames=1,count=4,size={64,32}}
    copy(p.every[:],"3")
    p.segments[0]={keys={.Space}}
    copy(p.segments[0].duration[:],"2");copy(p.segments[1].duration[:],"7")
    copy(p.follow[:],"Hero")
    strip,ok:=api_filmstrip_read(&f.s,&call,r,true,&p)
    testing.expect(t,ok && strip!=nil && strip.follow==f.hero,call.error.message)
    if strip==nil {return}
    testing.expect_value(t,len(strip.run.timeline),2)
    testing.expect(t,strip.run.timeline[0].keys=={.Space} && strip.run.timeline[1].ticks==7 && strip.run.timeline[1].keys=={},"the segments as they are")
    testing.expect(t,slice.equal(strip.ticks,[]int{0,3,6,9}),"a cell before the first tick and every 3")
    // The cells without the GPU: what each one sees.
    seen:Probe_Seen
    strip.run.sampler=nil
    context.user_ptr=&seen
    start:=running.time.tick
    probe_seen(&seen,run_ref(&f.s,r))
    ran,_,problem:=api_step_run(&f.s,&strip.run,probe_frame_seen)
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
    testing.expect(t,answer.cell==[2]int{64,32} && len(answer.cells)==2 && len(answer.cells[0].at)==2 && answer.cells[1].at==nil && answer.textures_pending==1)
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
    evenly:=api.Call{allocator=context.temp_allocator,raw=`{"count":3,"segments":[{"for":5}]}`}
    even:=Api_Capture_Params{dt=HEADLESS_DT,seconds=-1,frames=1,count=3,size={64,32}}
    copy(even.segments[0].duration[:],"5")
    testing.expect(t,api_filmstrip_spread(&evenly,&even),"a count with segments is a filmstrip")
    from_count,given_count:=api_filmstrip_read(&f.s,&evenly,r,true,&even)
    testing.expect(t,given_count && from_count!=nil && slice.equal(from_count.ticks,[]int{0,3,5}),evenly.error.message)
    long:=api.Call{allocator=context.temp_allocator,raw=`{"every":3,"count":2,"segments":[{"for":5}]}`}
    longer:=Api_Capture_Params{dt=HEADLESS_DT,seconds=-1,frames=1,count=2,size={64,32}}
    copy(longer.every[:],"3")
    copy(longer.segments[0].duration[:],"5")
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
    if trace!=nil {run.sampler,run.every=trace,1}
    ran,_,problem:=api_step_run(&f.s,&run,probe_frame)
    return ran==ticks && problem==""
}

@(private="file")
PROBE_HISTORY_TRACE :: `{"entity":"Hero","fields":["world_position[0]","Probe_Health.points"]}`

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
        core.edit_at(&w.transforms,0).position.x=f32(w.score.points)
    }
    testing.expect(t,probe_steps(f,1))
    r.history.interval=4
    call:=api.Call{allocator=context.temp_allocator,out=&f.out}
    p:=Api_Play_Trace{every=1}
    copy(p.entity[:],"Hero")
    copy(p.fields[0][:],"world_position[0]")
    copy(p.fields[1][:],"Probe_Health.points")
    live:Api_Trace
    start:=running.time.tick
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&p,PROBE_HISTORY_TRACE,12,&live),"")
    testing.expect(t,probe_steps(f,12,&live))
    rows:=trace_rows_text(&live)
    newest,points:=running.time.tick,running.score.points
    // The same rows from the past, and the game where it was.
    error,text:=probe_call(f,"play.history",fmt.tprintf(`{{"from":%d,"to":%d,"trace":%s}}`,start,newest,PROBE_HISTORY_TRACE))
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(api.json_compact(text),fmt.tprintf(`"rows":[%s]}}`,rows)),text)
    api_result_shape_expect(t,text,Api_Play_History_Result)
    testing.expect(t,running.time.tick==newest && running.score.points==points && r.history.at==r.history.serial)
    // Every other tick from tick 7 on.
    error,text=probe_call(f,"play.history",`{"from":7,"trace":{"entity":"Hero","fields":["world_position[0]"],"every":2}}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(api.json_compact(text),`"rows":[{"tick":7,"values":[7]},{"tick":9,"values":[9]},{"tick":11,"values":[11]},{"tick":13,"values":[13]}]`),text)
    // Rewound to tick 5, the run steps the same ticks again.
    error,_=probe_call(f,"play.seek",`{"to":5}`)
    testing.expect_value(t,error.code,0)
    again:Api_Trace
    testing.expect_value(t,api_trace_read(&f.s,&call,run_ref(&f.s,r),&p,PROBE_HISTORY_TRACE,8,&again),"")
    testing.expect(t,probe_steps(f,8,&again))
    testing.expect(t,strings.has_suffix(rows,trace_rows_text(&again)),trace_rows_text(&again))
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
    core.edit(&running.health,f.hero).points=9
    testing.expect(t,probe_steps(f,1))
    error,text=probe_call(f,"play.history",`{"verify":true}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"diverged": false`),text)
    refused:=[?]struct{params,says:string}{
        {`{"from":9,"to":8,"trace":{"storage":"Probe_Score","fields":["points"]}}`,"from 9 is after to 8"},
        {`{"from":"soon","trace":{"storage":"Probe_Score","fields":["points"]}}`,"from takes ticks as a number"},
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
    error,text=probe_call(f,"play.seek",`{"to":6}`)
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
        if w.time.tick==10 {core.edit_at(&w.transforms,0).position.x+=f32(ran)}
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
    api_state(&f.s).step_frame=probe_frame
    error,_:=probe_call(f,"play.stop",`{}`)
    testing.expect_value(t,error.code,0)
    folder:=base.test_folder(t,"scenarios")
    if folder=="" {return}
    write :: proc(folder,name,text:string) -> string {
        path:=fmt.tprintf("%s/%s",folder,name)
        _=os.write_entire_file(path,transmute([]u8)text)
        return path
    }
    hero:=fmt.tprintf("%016x",u64(f.hero))
    health :: proc(compare:string,points:int) -> string {
        return strings.concatenate({`{"entity":"Hero","field":"Probe_Health.points","compare":"`,compare,`","number":`,fmt.tprint(points),`}`},context.temp_allocator)
    }
    write(folder,"a_weakens.mirai",strings.concatenate({`{"steps":[`,
        `{"name":"weaken","method":"play.set","params":{"entity":"`,hero,`","components":{"Probe_Health":{"points":1}}}},`,
        `{"method":"play.check","params":{"conditions":[`,health("Equal",1),`]}},`,
        `{"method":"play.step","params":{"for":5,"until":[`,health("Below",2),`]}},`,
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
    testing.expect(t,strings.contains(api.json_compact(text),`"result":{"passed":false,"tick":0,"results":[{"passed":false,"value":0}]}`),text)
    testing.expect(t,run_find(&f.s,0)==nil,"the game stops after each scenario")
    // A step that fails, an until that runs out and files the methods would not take.
    cases:=[?]struct{text,says:string}{
        {`{"steps":[{"method":"play.check","params":{"conditions":[{"storage":"Nothing"}]}}]}`,"steps[0] play.check: conditions[0]"},
        {`{"steps":[{"method":"play.step","params":{"drive":{"position":[100,0,0],"move":"move"},"for":2}}]}`,"the drive did not arrive"},
        {`{"steps":[{"method":"play.step","params":{"ticks":"many"}}]}`,"steps[0].params"},
        {`{"steps":[{"method":"scene.write","params":{}}]}`,"steps are play methods"},
        {`{"steps":[{"method":"play.start"}]}`,"leave it out"},
        {`{"steps":[{"method":"play.nothing"}]}`,"is not a method"},
        {`{"start":{"players":9},"steps":[{"method":"play.step"}]}`,"start:"},
        {`{"steps":[{"method":"play.step","wait":1}]}`,`"wait" is not a field`},
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
        core.edit(&world.seats,f.seat).body=f.hero
        core.add(&world.moves,f.hero,input.Move_Input{})
        world.view=core.View{rotation=1,fov=90*math.RAD_PER_DEG,near=0.1,size={800,600}}
        core.settle(&f.info,world,nil)
    }
    history.edits_reset(&f.edits,edited_world(&f.s))
    f.document.saved=history.edits_state(&f.edits)
    api_state(&f.s).step_frame=probe_frame
}

@(private="file")
probe_json :: proc(t:^testing.T,text:string) -> json.Object {
    value,error:=json.parse_string(text,allocator=context.temp_allocator)
    testing.expect_value(t,error,json.Error.None)
    object,_:=value.(json.Object)
    return object
}

// A key given by a step reaches the UI of the game even if no step placed the pointer.
@(test)
a_step_with_input_reaches_the_ui_without_a_pointer :: proc(t:^testing.T) {
    r:Run
    testing.expect(t,!run_ui_scripted(&r),"the user's Play with no input of a step keeps the window")
    r.has_input=true
    testing.expect(t,run_ui_scripted(&r))
}

// With a game already playing, play.start says how it goes; when the document
// changed since it started, it starts again, and another owner's run stays.
// Once none plays, what needs a game asks for play.start.
@(test)
play_start_restarts_on_a_changed_document_and_without_a_game_calls_say_so :: proc(t:^testing.T) {
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
    testing.expect(t,play_start(&f.s,false,7))
    other:=run_find(&f.s,7).world
    error,_=probe_call(f,"scene.write",`{"root":"Hero","entities":[{"name":"Renamed"}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,run_find(&f.s,0).world==world,"an edit alone does not touch the run")
    f.document.saved=history.edits_state(&f.edits)
    error,_=probe_call(f,"play.start",`{}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,run_find(&f.s,7).world==other,"the run of another owner stays")
    running:=run_ref(&f.s,run_find(&f.s,0))
    testing.expect_value(t,entity_name(running,f.hero),"Renamed")
    restarted:=run_find(&f.s,0).id
    error,_=probe_call(f,"play.start",`{}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,run_find(&f.s,0).id==restarted,"played again unchanged, it goes on")
    error,_=probe_call(f,"play.stop",`{}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,run_find(&f.s,0)==nil)
    changes:=[?]struct{method,params:string}{
        {"play.inspect",`{}`},
        {"play.player",`{}`},
        {"play.view",`{}`},
        {"play.ui",`{}`},
        {"play.audio",`{}`},
        {"play.get",`{"entity":"Hero","field":"Transform.position"}`},
        {"play.check",`{"conditions":[{"storage":"Probe_Score","field":"points","compare":"At_Least","number":7}]}`},
        {"play.step",`{"for":1}`},
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
    error,_:=probe_call(f,"scene.write",`{"root":"Hero","entities":[{"name":"Renamed","position":[9,0,0]}]}`)
    testing.expect_value(t,error.code,0)
    hero:=api_entity(document,1)
    testing.expect_value(t,entity_name(document,hero),"Renamed")
    testing.expect_value(t,entity_name(running,f.hero),"Hero")
    testing.expect(t,f.edits.cursor==1 && document_dirty(&f.s),"a step of the document")
}

// editor.input refuses the events no frame takes before it runs one.
@(test)
editor_input_refuses_what_no_frame_takes :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    cases:=[?]struct{params,says:string}{
        {`{"events":[]}`,"1 to 256"},
        {`{"events":[{"keys":["Nope"]}]}`,"platform.Key"},
        {`{"events":[{"mouse_position":[1,2],"mouse_delta":[1,0]}]}`,"exclude each other"},
        {`{"events":[{"mouse_position":[1]}]}`,"x and y"},
        {`{"events":[{"repeat_keys":["B"]}]}`,"held in keys"},
        {`{"events":[{"text":"\u00e9"}]}`,"printable ASCII"},
    }
    for c in cases {
        error,_:=probe_call(f,"editor.input",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
}

// The rows of a trace as JSON without spaces, separated by commas.
trace_rows_text :: proc(trace:^Api_Trace) -> string {
    text,_:=serial.text_encode(struct{rows:[]Api_Play_Trace_Row}{trace.rows[:]},.Line,context.temp_allocator)
    compact:=api.json_compact(string(text))
    return compact[len(`{"rows":[`):len(compact)-2]
}
