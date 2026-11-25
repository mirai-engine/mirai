package behavior_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"
import "mirai:std/ai"
import "mirai:std/base"
import "mirai:std/serial"
import behavior "plugins:behavior/runtime"

// A guard walks until tick HISTORY_RUN_FROM, when running scores above walking and interrupts it.
@(private) Guard_Action :: enum u16 {Walk,Run}
@(private="file") HISTORY_RUN_FROM :: 10

@(private)
@(test_world,host="History_Test_Shared",editor="History_Test_Editor")
History_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),transforms:core.Table(core.Transform),parents:core.Table(core.Parent),worlds:core.Table(core.World_Transform),
    names:core.Table(core.Name),agents:core.Table(behavior.Mind_Agent),
    hierarchy:core.Hierarchy,propagation:core.Propagation,jumps:core.Jumps,
    time:core.Time,frame:core.Frame_Time,input:core.Input,world_id:core.World_Id,
}
@(private) History_Test_Shared :: struct {minds:behavior.Minds,problems:core.By_World(core.Problems)}
@(private) History_Test_Editor :: struct {api:editor.Api,behavior:Behavior_Api}

@(private="file")
guard_act :: proc(a:^ai.Act(Guard_Action)) -> ai.Status {return .Running}

@(private="file")
guard_think :: proc(t:^ai.Think(Guard_Action)) {
    ai.propose(t,Guard_Action.Walk,1)
    if t.tick>=HISTORY_RUN_FROM {ai.propose(t,Guard_Action.Run,2)}
}

// The step the generator makes of the mind of the guard.
@(private="file")
history_test_tick :: proc(data,shared,editor_data,app_data:rawptr) {
    w:=(^History_Test_World)(data)
    acts:=[Guard_Action]proc(a:^ai.Act(Guard_Action)) -> ai.Status{.Walk=guard_act,.Run=guard_act}
    minds:=Mind_World_Test{minds=&(^History_Test_Shared)(shared).minds,agents=&w.agents,time=w.time}
    behavior.minds_tick(&minds,"guard",&acts,guard_think)
}

@(private="file") Mind_World_Test :: behavior.Mind_World

// An editor without a window over a world with the guard, whose Play keeps its past.
@(private="file")
History_Test :: struct {
    root:string,
    assets:host.Assets,
    app:host.App,
    session:editor.Session,
    out:serial.Writer,
    p:^platform.Platform,
    info:core.World_Info,
    shared:History_Test_Shared,
    data:rawptr,
    tools:History_Test_Editor,
    edits:history.Edits,
    selection:history.Selection,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    document:editor.Document,
    build:editor.Build_State,
    settings:editor.Play_History,
}

@(private="file")
history_test_open :: proc(t:^testing.T,f:^History_Test) -> bool {
    f.root=base.test_folder(t,"behavior-history")
    if f.root=="" {return false}
    if !testing.expect(t,host.assets_init(&f.assets,{root=f.root,capacity=8,error_capacity=8})) {return false}
    serial.writer_init(&f.out,1<<20)
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) || f.p==nil {return false}
    described:bool
    f.info,described=test_info(t,History_Test_World)
    if !described {return false}
    f.info.loops[.Game][.Fixed]=history_test_tick
    if !testing.expect(t,core.world_init(&f.info,.Shared,&f.shared,context.allocator)) {return false}
    testing.expect(t,behavior.mind_register(&f.shared.minds,"guard",Guard_Action))
    app:=&f.app
    app.assets,app.allocator=&f.assets,context.allocator
    app.info,app.shared,app.platform,app.tick_dt,app.max_ticks=&f.info,&f.shared,f.p,1.0/60,8
    f.data=host.app_world_create(app)
    w:=(^History_Test_World)(f.data)
    guard:=core.create(&w.entities)
    core.add(&w.ids,guard,{value=17});core.add(&w.names,guard,core.name_make("Guard"))
    core.add(&w.transforms,guard,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&w.agents,guard,behavior.Mind_Agent{mind=behavior.name_make("guard") or_else {}})
    core.settle(&f.info,f.data,nil)
    f.viewport={orbit=editor.ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    f.settings=editor.PLAY_HISTORY_DEFAULT
    s:=&f.session
    s.app,s.assets_root,s.mode=&f.app,f.root,.Edit
    s.info,s.edit_world,s.editor_world=&f.info,f.data,&f.tools
    s.edits,s.selection,s.viewport,s.gui,s.document,s.build,s.play_history=&f.edits,&f.selection,&f.viewport,&f.gui,&f.document,&f.build,&f.settings
    history.edits_reset(&f.edits,editor.edited_world(s))
    opened,problem:=editor.api_open(s,0,true,listen=false)
    if !testing.expectf(t,opened==.None,"%v: %s",opened,problem) {return false}
    editor.api_state(s).poll_temp=context.temp_allocator
    editor.api_state(s).step_frame=history_test_frame
    return true
}

@(private="file")
history_test_close :: proc(f:^History_Test) {
    s:=&f.session
    if f.data!=nil {
        editor.runs_stop(s)
        editor.api_close(s)
        history.edits_free(&f.edits)
        delete(f.selection.entities)
        delete(s.edit_selection.entities)
        host.app_world_scratch_free(&f.app)
        host.app_world_free(&f.app,f.data)
        behavior.minds_free(&f.shared.minds)
        core.world_destroy(&f.info,.Shared,&f.shared)
    }
    delete(f.app.worlds)
    host.app_content_destroy(&f.app)
    serial.writer_destroy(&f.out)
    host.assets_destroy(&f.assets)
    if f.info.sizes[.World]>0 {test_info_destroy(&f.info)}
    if f.p!=nil {platform.destroy(f.p)}
}

@(private="file")
history_test_call :: proc(f:^History_Test,name,params:string) -> (text:string,error:api.Error) {
    st:=editor.api_state(&f.session)
    base.arena_reset(&st.server.scratch);serial.writer_reset(&f.out)
    method:=api.method_find(&st.server,name)
    if method==nil {return "",{api.METHOD_NOT_FOUND,"Missing test method",name}}
    error,_=api.method_execute(&st.server,method,params,&f.out)
    return strings.clone(string(serial.writer_bytes(&f.out)),context.temp_allocator),error
}

// A frame of the editor as a step runs it, without the window.
@(private="file")
history_test_frame :: proc(s:^editor.Session) -> bool {
    platform.frame_begin(s.app.platform)
    editor.play_input_update(s)
    editor.game_frame(s)
    return true
}

// What the mind of the guard ran, proposed and left at each tick, by playing the ticks again:
// the tick running interrupts walking shows the exit once, with its cause and what interrupted it.
// With a keyframe every tick, or one every few ticks of a world too big to
// keep more, which the ticks between are played again from.
@(test)
history_reads_what_a_mind_ran_proposed_and_left_at_each_tick :: proc(t:^testing.T) {
    for interval in ([]u64{1,4}) {history_reads_a_mind(t,interval)}
}

@(private="file")
history_reads_a_mind :: proc(t:^testing.T,interval:u64) {
    f:=new(History_Test);defer free(f)
    defer history_test_close(f)
    if !history_test_open(t,f) {return}
    if !testing.expect(t,editor.play_start(&f.session)) {return}
    _,error:=history_test_call(f,"play.step",`{"for":1}`)
    if !testing.expectf(t,error.code==0,"%s",error.message) {return}
    run:=editor.run_find(&f.session,0)
    if !testing.expect(t,run!=nil && run.history!=nil) {return}
    run.history.interval=interval
    _,error=history_test_call(f,"play.step",`{"for":19}`)
    if !testing.expectf(t,error.code==0,"%s",error.message) {return}
    testing.expectf(t,run.history.count==(interval==1?20:5),"interval %d: %d keyframes",interval,run.history.count)
    Exit :: struct {action,cause,interrupted_by:string,tick:u64}
    Row :: struct {tick:u64,missing,mind:string,running:struct {action:string},proposals:[]Proposal_Result,exits:[]Exit}
    Result :: struct {next:u64,rows:[]Row}
    read :: proc(t:^testing.T,f:^History_Test,params:string) -> (out:Result) {
        text,error:=history_test_call(f,"behavior.history",params)
        if !testing.expectf(t,error.code==0,"%s: %s %s",params,error.message,error.data) {return}
        problem:=serial.text_decode(text,&out,context.temp_allocator,skip_unknown=true)
        testing.expect(t,problem=="",problem)
        return
    }
    whole:=read(t,f,`{"entity":"Guard"}`)
    if !testing.expectf(t,len(whole.rows)>=15,"%v",whole) {return}
    interrupted:=0
    for row in whole.rows {
        testing.expect_value(t,row.mind,"guard")
        // The tick that ran before the time of the row decided what it shows.
        ran:=row.tick-1
        want:="Run" if ran>=HISTORY_RUN_FROM else "Walk"
        testing.expectf(t,row.running.action==want,"interval %d: tick %d runs %s, not %s",interval,row.tick,want,row.running.action)
        if len(row.proposals)>0 {testing.expect_value(t,row.proposals[0].action,want)}
        testing.expectf(t,(len(row.proposals)==2)==(ran>=HISTORY_RUN_FROM),"tick %d: %v",row.tick,row.proposals)
        for exit in row.exits {
            interrupted+=1
            testing.expectf(t,exit.action=="Walk" && exit.cause=="Aborted" && exit.interrupted_by=="Run" && exit.tick==HISTORY_RUN_FROM && row.tick==HISTORY_RUN_FROM+1,"tick %d: %v",row.tick,exit)
        }
    }
    testing.expect_value(t,interrupted,1)
    some:=read(t,f,fmt.tprintf(`{{"entity":"Guard","from":%d,"to":%d}}`,HISTORY_RUN_FROM-1,HISTORY_RUN_FROM+3))
    if testing.expect_value(t,len(some.rows),5) {
        testing.expect(t,some.rows[0].tick==HISTORY_RUN_FROM-1 && some.rows[4].tick==HISTORY_RUN_FROM+3)
        testing.expect(t,len(some.rows[2].exits)==1 && len(some.rows[1].exits)==0 && len(some.rows[3].exits)==0,fmt.tprint(some.rows))
    }
    _,error=history_test_call(f,"behavior.history",`{"entity":"Nobody"}`)
    testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,"Nobody"),"%v",error)
}
