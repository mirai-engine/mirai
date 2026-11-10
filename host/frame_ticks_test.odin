package host

import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:platform"

@(private="file")
Ticks_Test_World :: struct {
    time:core.Time,
    frame_time:core.Frame_Time,
    clock:core.Clock,
    input:core.Input,
    frame:core.Frame_Input,
    ticks,presses:int,
}

@(private="file")
ticks_test_fixed :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Ticks_Test_World)data
    w.ticks+=1
    if .Space in w.input.keys_pressed {w.presses+=1}
}

@(private="file")
ticks_test_frame :: proc(app:^App,w:^Ticks_Test_World,dt:=f64(-1),step:=false,record:^Frame_Record=nil,replay:^Frame_Record=nil) -> int {
    before:=w.ticks
    platform.frame_begin(app.platform)
    app_game_frame(app,w,step=step,dt=dt,record=record,replay=replay)
    return w.ticks-before
}

// The fixed ticks of a frame are those its time completes, at the speed of
// the clock: what is left waits for the next frame, a slow frame runs
// max_ticks and drops the rest, a paused clock runs none and a step runs one.
// A recorded frame runs the same over the world it found, and a steady frame
// allocates nothing.
@(test)
a_frame_runs_the_ticks_its_time_completes_up_to_its_limit_and_a_record_runs_them_again :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    storages:=[5]core.Storage_Info{
        {name="Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Ticks_Test_World,time)},
        {name="Frame_Time",type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Ticks_Test_World,frame_time)},
        {name="Clock",type=core.Clock,info=type_info_of(core.Clock),offset=offset_of(Ticks_Test_World,clock)},
        {name="Input",type=core.Input,info=type_info_of(core.Input),offset=offset_of(Ticks_Test_World,input)},
        {name="Frame_Input",type=core.Frame_Input,info=type_info_of(core.Frame_Input),offset=offset_of(Ticks_Test_World,frame)},
    }
    info:=core.World_Info{storages=storages[:]}
    info.loops[.Game][.Fixed]=ticks_test_fixed
    app:=App{info=&info,platform=p,tick_dt=1.0/60,max_ticks=4}
    defer delete(app.worlds)
    w:=Ticks_Test_World{frame_time=core.FRAME_TIME_DEFAULT,clock=core.CLOCK_DEFAULT}
    tick:=f64(app.tick_dt)

    testing.expect_value(t,ticks_test_frame(&app,&w),1)
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=2.5*tick),2)
    testing.expect_value(t,w.frame_time.alpha,f32(0.5))
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=0.5*tick),1)
    testing.expect_value(t,w.time.tick,u64(4))

    dropped:=app.stats.ticks_dropped
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=1),4)
    testing.expect_value(t,app.stats.ticks_dropped-dropped,u64(int(1/tick)-4))
    testing.expect(t,w.frame_time.accumulator>=0 && w.frame_time.accumulator<tick)
    w.frame_time.accumulator=0

    w.clock.paused=true
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=1),0)
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=1,step=true),1)
    w.clock=core.Clock{scale=2}
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=tick),2)
    w.clock=core.CLOCK_DEFAULT
    w.frame_time.dilation=-1
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=1),0)
    w.frame_time.dilation=0

    found:=w
    record:Frame_Record
    platform.input_inject(p,platform.Key_Event{key=.Space,down=true})
    ran:=ticks_test_frame(&app,&w,dt=3*tick,record=&record)
    played:=w
    testing.expect(t,ran==3 && played.presses==1)
    w=found
    testing.expect_value(t,ticks_test_frame(&app,&w,replay=&record),ran)
    testing.expect(t,w.presses==played.presses && w.time==played.time && w.frame_time.accumulator==played.frame_time.accumulator)

    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    context.allocator=mem.tracking_allocator(&tracking)
    for _ in 0..<8 {ticks_test_frame(&app,&w,dt=tick)}
    testing.expect_value(t,tracking.total_allocation_count,i64(0))
}

@(private="file")
Loops_Test_World :: struct {
    time:core.Time,
    frame_time:core.Frame_Time,
    shared,own:int,
}

// Over a World the game loop already ran in this frame, the editor loop calls only its own
// functions in the phases the game ran: one of both loops runs once. In a frame the game did not
// run (a paused game), the editor loop calls both.
@(test)
the_editor_loop_does_not_call_again_what_the_game_loop_ran_on_a_world_in_the_frame :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    storages:=[2]core.Storage_Info{
        {name="Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Loops_Test_World,time)},
        {name="Frame_Time",type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Loops_Test_World,frame_time)},
    }
    shared_step :: proc(world,_,_,_:rawptr) {(cast(^Loops_Test_World)world).shared+=1}
    own_step :: proc(world,_,_,_:rawptr) {(cast(^Loops_Test_World)world).own+=1}
    steps:=[2]core.Step_Info{{name="both",phases={.Frame},loops={.Game,.Editor},call=shared_step},{name="own",phases={.Frame},loops={.Editor},call=own_step}}
    game_order,editor_order:=[1]i32{0},[2]i32{0,1}
    info:=core.World_Info{storages=storages[:],steps=steps[:]}
    info.order[.Game][.Frame],info.order[.Editor][.Frame]=game_order[:],editor_order[:]
    info.loops[.Game][.Frame]=proc(world,shared,editor,app:rawptr) {shared_step(world,shared,editor,app)}
    info.loops[.Editor][.Frame]=proc(world,shared,editor,app:rawptr) {shared_step(world,shared,editor,app);own_step(world,shared,editor,app)}
    app:=App{info=&info,platform=p,tick_dt=1.0/60,max_ticks=4}
    defer delete(app.worlds)
    w:=Loops_Test_World{frame_time=core.FRAME_TIME_DEFAULT}
    app_frame_begin(&app)
    app_game_frame(&app,&w,ALL_PHASES-{.Render})
    app_editor_frame(&app,&w,nil,played=true)
    testing.expectf(t,w.shared==1 && w.own==1,"a frame the game ran calls each once: %d and %d",w.shared,w.own)
    app_frame_begin(&app)
    app_editor_frame(&app,&w,nil,played=true)
    testing.expectf(t,w.shared==2 && w.own==2,"a frame without the game calls both: %d and %d",w.shared,w.own)
}
