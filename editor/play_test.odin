package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"

Play_Test_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    time:core.Time,
    frame:core.Frame_Time,
    input:core.Input,
    ticks:Play_Test_Ticks,
}

Play_Test_Ticks :: struct {count:int}

// The ticks of a World, to write: its revision moves, as when a function of the loop receives it.
play_test_ticks :: proc(data,app:rawptr) -> ^Play_Test_Ticks {
    return core.world_storage_of(core.world_ref(data,(cast(^host.App)app).info),Play_Test_Ticks)
}

play_test_tick :: proc(data,shared,editor,app:rawptr) {play_test_ticks(data,app).count+=1}

// An editor without a window or a renderer over a world with one entity, and
// a game loop that counts its ticks.
Play_Test :: struct {
    p:^platform.Platform,
    info:core.World_Info,
    app:host.App,
    data:rawptr,
    original:core.Entity,
    using edited:Test_Session,
}

play_test_open :: proc(t:^testing.T,f:^Play_Test) -> bool {
    f.info=core.test_info(t,Play_Test_World) or_return
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=0.1,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if f.p==nil {
        core.test_info_destroy(&f.info)
        return false
    }
    f.info.loops[.Game][.Fixed]=play_test_tick
    f.app={info=&f.info,platform=f.p,allocator=context.allocator,tick_dt=1.0/60,max_ticks=8}
    f.data=host.app_world_create(&f.app)
    world:=cast(^Play_Test_World)f.data
    f.original=core.create(&world.entities)
    core.add(&world.ids,f.original,core.Id{1})
    core.add(&world.transforms,f.original,core.Transform{{1,0,0},1,{1,1,1}})
    core.settle(&f.info,f.data,nil)
    f.viewport={orbit=ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    test_session_open(&f.edited,core.world_ref(f.data,&f.info))
    f.s.app=&f.app
    f.document.saved=history.edits_state(&f.edits)
    return true
}

play_test_close :: proc(f:^Play_Test) {
    runs_stop(&f.s)
    test_session_close(&f.edited)
    delete(f.s.edit_selection.entities)
    host.app_world_scratch_free(&f.app)
    host.app_world_free(&f.app,f.data)
    delete(f.app.worlds)
    platform.destroy(f.p)
    core.test_info_destroy(&f.info)
}

@(test)
play_and_simulation_keep_the_document_and_step_exactly_one_tick :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s,app,gui,viewport,selection,edits,original,p:=&f.s,&f.app,&f.gui,&f.viewport,&f.selection,&f.edits,f.original,f.p
    world:=cast(^Play_Test_World)f.data
    layout:=gui.layout
    history.selection_set(selection,{original})
    for simulate in ([2]bool{false,true}) {
        testing.expect(t,play_start(s,simulate))
        running:=cast(^Play_Test_World)run_find(s,0).world
        testing.expect(t,running!=world && host.app_world_count(app)==2)
        testing.expect_value(t,gui.layout.left_open,simulate)
        play_pause(s,true)
        platform.frame_begin(p)
        play_input_update(s)
        host.app_input_add(app,{keys_down={.W},keys_pressed={.W}})
        run_find(s,0).step=true
        game_frame(s)
        testing.expect_value(t,running.ticks.count,1)
        testing.expect_value(t,running.time.tick,u64(1))
        testing.expect_value(t,app.stats.ticks_dropped,u64(0))
        testing.expect_value(t,.W in running.input.keys_down,!simulate)
        testing.expect_value(t,world.ticks.count,0)
        game_frame(s)
        testing.expect_value(t,running.ticks.count,1)
        core.edit(&running.transforms,original).position.x=5
        viewport.orbit.target={8,9,10}
        history.selection_clear(selection)
        if simulate {
            history.selection_set(selection,{original})
            testing.expect(t,action_run(s,.Apply_Simulation))
            testing.expect(t,run_find(s,0).world==running && .Apply_Simulation in s.requests)
            requests_run(s)
            testing.expect_value(t,entity_local(edited_world(s),original).position.x,f32(5))
            testing.expect_value(t,edits.cursor,1)
            testing.expect(t,history.undo(edits,edited_world(s),selection))
        } else {play_stop(s)}
        testing.expect(t,run_find(s,0)==nil && s.mode==.Edit && host.app_world_count(app)==1)
        testing.expect_value(t,gui.layout,layout)
        testing.expect_value(t,viewport.orbit,ORBIT_DEFAULT)
        testing.expect_value(t,history.selection_active(selection),original)
        testing.expect_value(t,entity_local(edited_world(s),original).position.x,f32(1))
        testing.expect_value(t,world.ticks.count,0)
    }
}

@(test)
the_user_and_agents_play_their_own_runs_at_once :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s,app:=&f.s,&f.app
    world:=cast(^Play_Test_World)f.data
    // Two agents open runs of their own: the editor stays in Edit.
    testing.expect(t,play_start(s,false,7) && play_start(s,false,8))
    testing.expect(t,play_start(s,false,7),"a turn that has its run keeps it")
    testing.expect(t,s.mode==.Edit && shown_world(s).data==f.data && running(s))
    first,second:=run_find(s,7),run_find(s,8)
    testing.expect(t,first!=nil && second!=nil && first.world!=second.world && host.app_world_count(app)==3)
    // The user plays besides them: a run of its own, shown.
    testing.expect(t,play_start(s))
    testing.expect(t,!play_start(s),"the user plays one game at a time")
    user:=run_find(s,0)
    testing.expect(t,s.mode==.Play && shown_world(s).data==user.world && host.app_world_count(app)==4)
    a,b,u:=cast(^Play_Test_World)first.world,cast(^Play_Test_World)second.world,cast(^Play_Test_World)user.world
    // A step advances only the run that asked for it, with only its input;
    // the game of the user goes on with the time of the frame.
    first.input,first.has_input,first.step={keys_down={.W},keys_pressed={.W}},true,true
    platform.frame_begin(f.p)
    play_input_update(s)
    game_frame(s)
    testing.expect_value(t,a.ticks.count,1)
    testing.expect(t,.W in a.input.keys_down)
    testing.expect_value(t,b.ticks.count,0)
    testing.expect(t,u.ticks.count>0 && .W not_in u.input.keys_down,"the input of a turn does not reach the game of the user")
    played:=u.ticks.count
    second.step=true
    platform.frame_begin(f.p)
    game_frame(s)
    testing.expect(t,a.ticks.count==1 && b.ticks.count==1 && .W not_in b.input.keys_down && u.ticks.count>played)
    testing.expect_value(t,world.ticks.count,0)
    // A turn that ends takes its run; the others go on.
    run_stop(s,7)
    testing.expect(t,run_find(s,7)==nil && run_find(s,8)!=nil && run_find(s,0)!=nil && host.app_world_count(app)==3)
    // Stop ends the game of the user and leaves the agent its own.
    play_stop(s)
    testing.expect(t,s.mode==.Edit && run_find(s,0)==nil && run_find(s,8)!=nil)
    // A change of document ends them all.
    runs_stop(s)
    testing.expect(t,!running(s) && host.app_world_count(app)==1)
}

@(test)
a_paused_play_draws_the_detail_its_camera_saw_while_the_editor_looks_elsewhere :: proc(t:^testing.T) {
    Detail_World :: struct {using world:core.Test_World,view:core.View}
    world:Detail_World
    if !core.test_world_init(t,&world) {return}
    defer core.test_world_destroy(&world)
    ref:=core.test_world_ref(&world)
    app:host.App
    v:Viewport;defer viewport_free(&v)
    v.orbit=ORBIT_DEFAULT
    s:=Session{app=&app,viewport=&v,mode=.Paused}
    game:=[3]f32{4,2,9}
    world.view={camera=core.Entity(7),position=game,rotation=1,fov=1,near=0.1}
    cases:=[?]struct{mode:Mode,on,detail:bool}{
        {.Paused,false,false},{.Paused,true,true},{.Paused,true,true},{.Play,true,false},{.Edit,true,false},
    }
    for c,i in cases {
        s.mode,v.game_detail=c.mode,c.on
        if c.mode!=.Paused {world.view.camera=core.Entity(7)}
        view_write(&s,ref)
        testing.expectf(t,app.detail.on==c.detail,"case %d: detail of the game camera %v",i,c.detail)
        if c.detail {testing.expectf(t,app.detail.camera.position==game,"case %d: from where the game camera was",i)}
        if c.mode==.Paused {testing.expect(t,world.view.camera==core.NONE && world.view.position!=game,"The editor looks from its own camera")}
    }
}
