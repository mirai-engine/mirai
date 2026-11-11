package playtest_editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") Probe_Health :: struct {points:f32,target:core.Entity}
@(private="file") Probe_State :: enum u8 {Waiting,Playing,Won}
@(private="file") Probe_Score :: struct {points:int,state:Probe_State,seen:core.Seen}
@(private="file") Probe_Ping :: struct {entity:core.Entity,amount:int}
@(private="file") Probe_Pings :: struct {queue:core.Queue(Probe_Ping)}
// What a plugin that moves bodies says of the hero.
@(private="file") Probe_Stance :: struct {hero:editor.Stance,routes:int}
@(private="file") PROBE_MOVE :: input.Action(0)
@(private="file") PROBE_JUMP :: input.Action(2)

// A game whose tick adds a point to its score, and what its pings push.
@(private="file")
Probe_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    health:core.Table(Probe_Health) `mirai:"game"`,
    seats:core.Table(input.Seat),
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
    id:core.World_Id,
    view:core.View,
    quit_at:int, // the points at which the game asks to quit; 0: never
    stance:Probe_Stance,
}
@(private="file") Probe_Shared :: struct {problems:core.By_World(core.Problems)}
@(private="file") Probe_Bodies :: struct {provider:editor.Body_Provider}
@(private="file") Probe_Routes :: struct {provider:editor.Route_Provider}
@(private="file") Probe_Editor :: struct {api:editor.Api,playtest:Playtest,provider:Playtest_Api,listener:Playtest_Listener,bodies:Probe_Bodies,routes:Probe_Routes}

// A plugin that knows no way and counts the times a drive asks it for one.
@(private="file")
probe_route :: proc(s:^editor.Session,w:core.World_Ref,body:core.Entity,goal:[3]f32) -> editor.Route {
    (cast(^Probe_World)w.data).stance.routes+=1
    return {}
}

@(private="file")
probe_standing :: proc(w:core.World_Ref,body:core.Entity) -> (standing,known:bool) {
    stance:=(cast(^Probe_World)w.data).stance.hero
    return stance==.Standing,stance!=.Unknown
}

@(private="file")
probe_types :: proc(types:^[dynamic]core.Test_Type) {
    test_types(types)
    append(types,
        core.test_type(Probe_Bodies,default=proc(dst:^Probe_Bodies) {dst^={provider={standing=probe_standing}}}),
        core.test_type(Probe_Routes,default=proc(dst:^Probe_Routes) {dst^={provider={next=probe_route}}}),
    )
}

// The seats take their holds and the devices of the tick, as engine/input runs them.
@(private="file")
probe_tick :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Probe_World)data
    input.input_holds(&w.seats,&w.holds,w.time,nil)
    for row in 0..<core.count(&w.seats) {
        input.seat_feed(core.edit_at(&w.seats,row),&w.input,&w.bindings,false,1.0/60)
    }
    w.score.points+=1
    for ping in core.take(&w.pings.queue) {w.score.points+=ping.amount}
    if w.score.points>=10 {w.score.state=.Won}
    if w.quit_at>0 && w.score.points==w.quit_at {host.app_exit(cast(^host.App)app,0)}
    // A driven body walks by the move action until a wall at x 6, and the jump
    // action drops it 5 meters.
    seat,hero:=core.NONE,core.NONE
    for value,row in w.seats.values {
        if value.body!=core.NONE {seat,hero=w.seats.entities[row],value.body}
    }
    if hero==core.NONE {return}
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
    edits:history.Edits,
    selection:history.Selection,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    document:editor.Document,
    build:editor.Build_State,
    tools:Probe_Editor,
    s:editor.Session,
    out:serial.Writer,
}

@(private="file")
probe_open :: proc(t:^testing.T,f:^Probe) -> bool {
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=0.1,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) || f.p==nil {return false}
    f.info=core.test_info(t,Probe_World,Probe_Shared,Probe_Editor,probe_types) or_return
    f.names={{type=input.Action,value=i64(PROBE_MOVE),name="move"},{type=input.Action,value=i64(PROBE_JUMP),name="jump"}}
    f.info.names=f.names[:]
    core.test_info_index(&f.info)
    f.info.loops[.Game][.Fixed]=probe_tick
    f.app={info=&f.info,shared=&f.shared,platform=f.p,allocator=context.allocator,tick_dt=1.0/60,max_ticks=8}
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
    core.settle(&f.info,f.data,nil)
    f.viewport={orbit=editor.ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    f.s={app=&f.app,info=&f.info,edit_world=f.data,editor_world=&f.tools,edits=&f.edits,selection=&f.selection,viewport=&f.viewport,gui=&f.gui,document=&f.document,build=&f.build}
    history.edits_reset(&f.edits,editor.edited_world(&f.s))
    f.document.saved=history.edits_state(&f.edits)
    api_opened,api_problem:=editor.api_open(&f.s,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return false}
    editor.api_state(&f.s).poll_temp=context.temp_allocator
    serial.writer_init(&f.out)
    return testing.expect(t,editor.play_start(&f.s))
}

@(private="file")
probe_close :: proc(f:^Probe) {
    serial.writer_destroy(&f.out)
    editor.runs_stop(&f.s)
    editor.api_close(&f.s)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    delete(f.s.edit_selection.entities)
    host.app_world_scratch_free(&f.app)
    host.app_world_free(&f.app,f.data)
    delete(f.app.worlds)
    core.world_destroy(&f.info,.Shared,&f.shared)
    core.test_info_destroy(&f.info)
    platform.destroy(f.p)
}

@(private="file")
probe_call :: proc(f:^Probe,name,params:string) -> (error:api.Error,text:string) {
    st:=editor.api_state(&f.s)
    base.arena_reset(&st.server.scratch);serial.writer_reset(&f.out)
    error,_=api.method_execute(&st.server,api.method_find(&st.server,name),params,&f.out)
    return error,string(serial.writer_bytes(&f.out))
}

// A frame of the editor as a step runs it, without the window.
@(private="file")
probe_frame :: proc(s:^editor.Session) -> bool {
    platform.frame_begin(s.app.platform)
    editor.play_input_update(s)
    editor.game_frame(s)
    return true
}

// The hero becomes the body of the seat, in the document and in the game
// that plays, and the ticks of a step run without a window.
@(private="file")
probe_drive :: proc(f:^Probe) {
    worlds:=[2]^Probe_World{cast(^Probe_World)f.data,cast(^Probe_World)editor.run_find(&f.s,0).world}
    for world in worlds {
        core.edit(&world.seats,f.seat).body=f.hero
        core.add(&world.moves,f.hero,input.Move_Input{})
        world.view=core.View{rotation=1,fov=90*math.RAD_PER_DEG,near=0.1,size={800,600}}
        core.settle(&f.info,world,nil)
    }
    history.edits_reset(&f.edits,editor.edited_world(&f.s))
    f.document.saved=history.edits_state(&f.edits)
    editor.api_state(&f.s).step_frame=probe_frame
}

// Where a repro goes: the project is set only while it is written, as a
// fixture without a project starts its games without a recovery copy.
@(private="file")
probe_json :: proc(t:^testing.T,text:string) -> json.Object {
    value,error:=json.parse_string(text,allocator=context.temp_allocator)
    testing.expect_value(t,error,json.Error.None)
    object,_:=value.(json.Object)
    return object
}

// One answer has what a decision needs, and it is small: the state of the
// body, the problems new since the last one, and the nearest targets to the
// camera. With step it answers the same after those ticks.
@(test)
play_observe_says_in_one_small_answer_what_a_decision_needs :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    running:=cast(^Probe_World)editor.run_find(&f.s,0).world
    error,text:=probe_call(f,"play.observe",`{"targets":["Foe","Hero"],"nearest":2}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect_value(t,api.result_mismatch(Api_Play_Observe,text),"")
    answer:=probe_json(t,text)
    player,_:=answer["player"].(json.Object)
    position,_:=player["position"].(json.Array)
    testing.expect(t,len(position)==3 && position[0].(json.Float)==1,text)
    testing.expect(t,"stance" not_in player,"a body no plugin moves does not say")
    targets,_:=answer["targets"].(json.Array)
    if testing.expect_value(t,len(targets),1) {
        foe,_:=targets[0].(json.Object)
        testing.expect_value(t,foe["name"].(json.String) or_else "","Foe")
        testing.expect_value(t,foe["distance"].(json.Float) or_else 0,5)
        testing.expect_value(t,foe["bearing"].(json.Float) or_else 0,90)
        testing.expect(t,!(foe["on_screen"].(json.Boolean) or_else true),text)
    }
    core.report(host.app_world_storage(&f.app,running,core.Problems),f.hero,"test.broken","The hero is broken: fix it.")
    running.stance.hero=.Airborne
    error,text=probe_call(f,"play.observe",`{"step":{"for":2},"targets":["Foe"]}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect_value(t,api.result_mismatch(Api_Play_Observe,text),"")
    seen:=probe_json(t,text)
    stance,said:=seen["player"].(json.Object)["stance"].(json.String)
    testing.expect(t,said && stance!="Standing","in the air, as the plugin that moves it says")
    testing.expect_value(t,seen["ran"].(json.Float) or_else 0,2)
    testing.expect(t,"playing" not_in seen,"the state of the game is left out")
    problems,_:=seen["problems"].(json.Array)
    testing.expect_value(t,len(problems),1)
    error,text=probe_call(f,"play.observe",`{}`)
    testing.expect(t,error.code==0 && "problems" not_in probe_json(t,text),"a problem is said once")
    // Asking to move without moving, past the wall: stuck.
    error,_=probe_call(f,"play.input",`{"actions":[{"name":"move","vector":[1,0]}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    for _ in 0..<3 {
        error,text=probe_call(f,"play.observe",`{"step":{"for":60}}`)
        testing.expectf(t,error.code==0,"%v",error)
    }
    testing.expect(t,(probe_json(t,text)["stuck"].(json.Boolean) or_else false),text)
    error,_=probe_call(f,"play.stop",`{}`)
    testing.expect_value(t,error.code,0)
    error,_=probe_call(f,"play.observe",`{}`)
    testing.expect(t,error.code!=0 && strings.contains(error.message,"play.start"),error.message)
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
    testing.expect(t,qa_of(&f.s,editor.run_find(&f.s,0))==nil,"nothing is reserved before play.qa.start")
    error,text=probe_call(f,"play.qa.start",`{"fall_below":-2,"stuck_seconds":0.5,"frame_ms":50}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,strings.contains(text,`"repro": true`),text)
    f.app.stats.frame_ms=80
    running:=cast(^Probe_World)editor.run_find(&f.s,0).world
    transforms:=core.edit(&running.transforms,f.foe)
    transforms.scale.y=f32(math.inf_f32(1))
    error,_=probe_call(f,"play.step",`{"segments":[{"for":2,"keys":["Space"]},{"for":3}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    transforms.scale.y=1
    error,_=probe_call(f,"play.input",`{"actions":[{"name":"move","vector":[1,0]}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,_=probe_call(f,"play.step",`{"for":90}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,text=probe_call(f,"play.qa.report",`{}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect_value(t,api.result_mismatch(Api_Play_Qa_Report,text),"")
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
    root:=base.test_folder(t,"playtest-qa")
    if root=="" {return}
    error:api.Error
    text:string
    if late {
        error,_=probe_call(f,"play.step",`{"for":1}`)
        testing.expectf(t,error.code==0,"%v",error)
    }
    error,text=probe_call(f,"play.qa.start",`{"fall_below":-2,"stuck_seconds":0,"non_finite":false,"problems":false}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,strings.contains(text,`"repro": true`),text)
    error,_=probe_call(f,"play.input",`{"actions":[{"name":"move","vector":[1,0],"for":3}]}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,_=probe_call(f,"play.step",`{"for":4}`)
    testing.expectf(t,error.code==0,"%v",error)
    error,_=probe_call(f,"play.step",`{"segments":[{"for":2},{"for":1,"keys":["Space"]},{"for":4}]}`)
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
    testing.expect(t,strings.contains(string(written),`"method":"play.qa.report"`) && strings.contains(string(written),`"name":"move"`),string(written))
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
    testing.expect(t,strings.contains(played.failure,"play.qa.report"),text)
    testing.expect(t,len(played.ran)>0 && played.ran[len(played.ran)-1].tick==failing,text)
    testing.expectf(t,played.tick==failing,"tick %d of %d: %s",played.tick,failing,text)
}

// Without fall_below the monitors take a height under the lowest of the
// scene, and falls false turns them off.
@(test)
the_monitors_take_the_height_of_a_fall_from_the_scene :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    error,_:=probe_call(f,"play.qa.start",`{}`)
    testing.expectf(t,error.code==0,"%v",error)
    q:=qa_of(&f.s,editor.run_find(&f.s,0))
    testing.expect(t,q.limits.falls && q.limits.fall_below==-QA_FALL_MARGIN,"under the entities of the scene, at height 0")
    error,_=probe_call(f,"play.qa.start",`{"falls":false}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,!q.limits.falls)
    error,_=probe_call(f,"play.qa.start",`{"fall_below":-2}`)
    testing.expectf(t,error.code==0,"%v",error)
    testing.expect(t,q.limits.falls && q.limits.fall_below==-2)
}

// The bot moves over the cells of the world, the same with the same seed,
// and its bugs come with repros; a game that asks to quit does not end it.
// It goes to each cell as a drive does: by the way a plugin gives.
@(test)
the_bot_explores_the_same_with_the_same_seed_and_a_quit_does_not_end_it :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    probe_drive(f)
    root:=base.test_folder(t,"playtest-qa")
    if root=="" {return}
    params:=`{"seed":7,"for":150,"move":"move","jump":"jump","cell":1}`
    play :: proc(t:^testing.T,f:^Probe,root,params:string) -> string {
        error,_:=probe_call(f,"play.stop",`{}`)
        testing.expect_value(t,error.code,0)
        error,_=probe_call(f,"play.start",`{}`)
        testing.expect_value(t,error.code,0)
        (cast(^Probe_World)editor.run_find(&f.s,0).world).quit_at=40
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
    testing.expect_value(t,api.result_mismatch(Api_Play_Explore_Result,first),"")
    testing.expect(t,editor.run_find(&f.s,0)!=nil,"the run goes on after the game asks to quit")
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
    testing.expect(t,(cast(^Probe_World)editor.run_find(&f.s,0).world).stance.routes>0,"it asks for the way to its cell")
    error,_:=probe_call(f,"play.explore",`{"for":10,"move":"nothing"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

// The nearest cell it was never in, whatever the tie-breaks of the seed, one
// it missed after the others and, turning back, only where it has been; a
// page presses what it never pressed and goes back by what led to others.
@(test)
the_bot_goes_toward_new_cells_and_presses_every_button_of_a_menu_once :: proc(t:^testing.T) {
    keys:[128][2]i32
    visits:[128]u16
    misses:[128]u8
    cells:=Explore_Cells{keys=keys[:],visits=visits[:],misses=misses[:]}
    for x in -3..=3 {
        for z in -3..=0 {explore_cell_enter(&cells,{i32(x),i32(z)})}
    }
    been:=cells.count
    testing.expect_value(t,explore_cell_of({-1,0,-0.5},1),[2]i32{-1,-1})
    testing.expect_value(t,explore_cell_middle({-1,2},2,5),[3]f32{-1,5,5})
    for seed in 1..=4 {
        rng:=base.rng_make(u64(seed))
        testing.expect_value(t,explore_target(&cells,{0,0},false,&rng).y,i32(1))
        for x in -1..=1 {
            for _ in 0..<2 {explore_cell_miss(&cells,{i32(x),1})}
        }
        target:=explore_target(&cells,{0,0},false,&rng)
        testing.expectf(t,target.y>=1 && (target.y>1 || abs(target.x)>1),"a cell it missed twice comes after those it did not: %v",target)
        testing.expectf(t,explore_target(&cells,{0,0},true,&rng).y<=0,"turning back, only where it has been")
        misses={}
    }
    testing.expect_value(t,cells.count,been)

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
