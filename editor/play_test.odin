package editor

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:platform"

Play_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    time:core.Time,
    frame:core.Frame_Time,
    input:core.Input,
    ticks:int,
}

play_test_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Play_Test_World)data
    w^={}
    core.entities_init(&w.entities,allocator)
    core.table_init(&w.ids,"Id",allocator)
    core.table_init(&w.transforms,"Transform",allocator)
    core.table_init(&w.parents,"Parent",allocator)
    return len(w.entities.generation)>0
}

play_test_free :: proc(data:rawptr) {
    w:=cast(^Play_Test_World)data
    core.table_destroy(&w.ids)
    core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents)
    core.entities_destroy(&w.entities)
}

play_test_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Play_Test_World)dst,cast(^Play_Test_World)src
    if !core.entities_copy(&d.entities,&s.entities) || !core.table_copy(&d.ids,&s.ids) || !core.table_copy(&d.transforms,&s.transforms) || !core.table_copy(&d.parents,&s.parents) {return false}
    d.time,d.input,d.ticks=s.time,s.input,s.ticks
    return true
}

play_test_swap :: proc(a,b:rawptr) {
    a,b:=(^Play_Test_World)(a),(^Play_Test_World)(b)
    a.entities,b.entities=b.entities,a.entities
    core.table_swap(&a.ids,&b.ids);core.table_swap(&a.transforms,&b.transforms);core.table_swap(&a.parents,&b.parents)
    a.time,b.time=b.time,a.time;a.input,b.input=b.input,a.input;a.ticks,b.ticks=b.ticks,a.ticks
}

play_test_settle :: proc(data,shared,editor:rawptr) {
    w:=cast(^Play_Test_World)data
    core.table_settle(&w.ids,&w.entities)
    core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.parents,&w.entities)
    core.entities_settle(&w.entities)
}

play_test_clear :: proc(data:rawptr) -> bool {
    w:=cast(^Play_Test_World)data
    core.table_clear(&w.ids)
    core.table_clear(&w.transforms)
    core.table_clear(&w.parents)
    return core.entities_clear(&w.entities)
}

play_test_tick :: proc(data,shared,editor,app:rawptr) {(cast(^Play_Test_World)data).ticks+=1}

// An editor without a window or a renderer over a world of three tables, with
// one entity, and a game loop that counts its ticks.
Play_Test :: struct {
    p:^platform.Platform,
    tables:[3]core.Table_Info,
    storages:[3]core.Storage_Info,
    info:core.World_Info,
    app:host.App,
    data:rawptr,
    original:core.Entity,
    edits:history.Edits,
    selection:history.Selection,
    viewport:Viewport,
    gui:Editor_Ui,
    document:Document,
    s:Session,
}

play_test_open :: proc(t:^testing.T,f:^Play_Test) -> bool {
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=0.1,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if f.p==nil {return false}
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Play_Test_World,ids)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Play_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Play_Test_World,parents)},
    }
    f.storages={
        {name="Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Play_Test_World,time)},
        {name="Input",type=core.Input,info=type_info_of(core.Input),offset=offset_of(Play_Test_World,input)},
        {name="Frame_Time",type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Play_Test_World,frame)},
    }
    f.info={tables=f.tables[:],storages=f.storages[:],copy=play_test_copy,swap=play_test_swap,clear=play_test_clear}
    f.info.sizes[.World],f.info.aligns[.World]=size_of(Play_Test_World),align_of(Play_Test_World)
    f.info.init[.World],f.info.destroy[.World]=play_test_init,play_test_free
    f.info.loops[.Game][.Fixed]=play_test_tick
    f.app={info=&f.info,platform=f.p,allocator=context.allocator,tick_dt=1.0/60,max_ticks=8}
    f.data=host.app_world_create(&f.app)
    world:=cast(^Play_Test_World)f.data
    f.original=core.create(&world.entities)
    core.add(&world.ids,f.original,core.Id{1})
    core.add(&world.transforms,f.original,core.Transform{{1,0,0},1,{1,1,1}})
    play_test_settle(f.data,nil,nil)
    f.viewport={orbit=ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    f.s={app=&f.app,info=&f.info,edit_world=f.data,edits=&f.edits,selection=&f.selection,viewport=&f.viewport,gui=&f.gui,document=&f.document}
    history.edits_reset(&f.edits,edited_world(&f.s))
    f.document.saved=history.edits_state(&f.edits)
    return true
}

play_test_close :: proc(f:^Play_Test) {
    runs_stop(&f.s)
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    delete(f.s.edit_selection.entities)
    host.app_world_scratch_free(&f.app)
    host.app_world_free(&f.app,f.data)
    delete(f.app.worlds)
    platform.destroy(f.p)
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
        testing.expect_value(t,running.ticks,1)
        testing.expect_value(t,running.time.tick,u64(1))
        testing.expect_value(t,app.stats.ticks_dropped,u64(0))
        testing.expect_value(t,.W in running.input.keys_down,!simulate)
        testing.expect_value(t,world.ticks,0)
        game_frame(s)
        testing.expect_value(t,running.ticks,1)
        core.get(&running.transforms,original).position.x=5
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
        testing.expect_value(t,world.ticks,0)
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
    testing.expect_value(t,a.ticks,1)
    testing.expect(t,.W in a.input.keys_down)
    testing.expect_value(t,b.ticks,0)
    testing.expect(t,u.ticks>0 && .W not_in u.input.keys_down,"the input of a turn does not reach the game of the user")
    played:=u.ticks
    second.step=true
    platform.frame_begin(f.p)
    game_frame(s)
    testing.expect(t,a.ticks==1 && b.ticks==1 && .W not_in b.input.keys_down && u.ticks>played)
    testing.expect_value(t,world.ticks,0)
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
    Detail_World :: struct {entities:core.Entities,view:core.View}
    world:Detail_World
    storages:=[1]core.Storage_Info{{type=core.View,info=type_info_of(core.View),offset=offset_of(Detail_World,view)}}
    info:=core.World_Info{entities=offset_of(Detail_World,entities),storages=storages[:]}
    ref:=core.world_ref(&world,&info)
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
