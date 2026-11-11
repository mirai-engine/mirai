package host

import "core:math"
import "core:math/rand"
import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:platform"

@(private="file")
Ticks_Test_World :: struct {
    using world:core.Test_World,
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
    w:Ticks_Test_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    info:=core.test_world_info(&w)
    info.loops[.Game][.Fixed]=ticks_test_fixed
    app:=App{info=info,platform=p,tick_dt=1.0/60,max_ticks=4}
    defer delete(app.worlds)
    tick:=f64(app.tick_dt)

    testing.expect_value(t,ticks_test_frame(&app,&w),1)
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=2.5*tick),2)
    testing.expect_value(t,w.frame_time.accumulator,0.5*tick)
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
    twice:=ticks_test_frame(&app,&w,dt=tick)+ticks_test_frame(&app,&w,dt=tick)
    testing.expect_value(t,f64(twice)*tick+w.frame_time.accumulator,4*tick)
    w.clock=core.CLOCK_DEFAULT
    w.frame_time.dilation=-1
    testing.expect_value(t,ticks_test_frame(&app,&w,dt=1),0)
    w.frame_time.dilation=0

    found:=w
    record:Frame_Record
    platform.input_inject(p,platform.Key_Event{key=.Space,down=true})
    ran:=ticks_test_frame(&app,&w,dt=3*tick,record=&record)
    played:=w
    testing.expect(t,ran>0 && played.presses==1)
    // The editor keeps the World of a frame, not the counts of ticks before it.
    w=found
    w.frame_time.seen,w.frame_time.ran,w.frame_time.typical=0,{},{}
    testing.expect_value(t,ticks_test_frame(&app,&w,replay=&record),ran)
    testing.expect(t,w.presses==played.presses && w.time==played.time && w.frame_time.accumulator==played.frame_time.accumulator && w.frame_time.alpha==played.frame_time.alpha)

    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
    defer mem.tracking_allocator_destroy(&tracking)
    context.allocator=mem.tracking_allocator(&tracking)
    for _ in 0..<8 {ticks_test_frame(&app,&w,dt=tick)}
    testing.expect_value(t,tracking.total_allocation_count,i64(0))
}

// Frames paced at a steady rate, each woken up to 50 us late, run a steady count of ticks: one each
// at the tick rate, the same count in every repeat of the pattern at other rates, with the shown
// time advancing evenly and the ticks keeping up with the clock over 10 minutes. A hitch still runs
// max_ticks and drops the rest.
@(test)
frames_whose_time_jitters_run_a_steady_count_of_ticks_that_keeps_up_with_the_clock :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    testing.expect_value(t,error,platform.Error.None)
    if p==nil {return}
    defer platform.destroy(p)
    state:=rand.create(3)
    random:=rand.default_random_generator(&state)
    // repeat: frames in which the ticks repeat; ticks: how many run in them.
    for c in ([3]struct{fps,repeat,ticks:int}{{60,1,1},{144,12,5},{30,1,2}}) {
        w:Ticks_Test_World
        if !core.test_world_init(t,&w) {return}
        defer core.test_world_destroy(&w)
        info:=core.test_world_info(&w)
        info.loops[.Game][.Fixed]=ticks_test_fixed
        app:=App{info=info,platform=p,tick_dt=1.0/60,max_ticks=4}
        defer delete(app.worlds)
        tick:=f64(app.tick_dt)
        budget:=f64(1_000_000_000/c.fps)*1e-9
        late,clock,shown:=rand.float64(random)*50e-6,f64(0),f64(0)
        ran:[12]int
        uneven,off:=0,0
        for frame in 0..<36_000 {
            next:=rand.float64(random)*50e-6
            dt:=budget+next-late
            late=next
            clock+=dt
            ran[frame%c.repeat]=ticks_test_frame(&app,&w,dt=dt)
            now:=f64(w.time.tick)+f64(w.frame_time.alpha)
            if frame>=120 {
                if math.sum(ran[:c.repeat])!=c.ticks {uneven+=1}
                if abs(now-shown-budget/tick)>0.005 {off+=1}
            }
            shown=now
        }
        testing.expectf(t,uneven==0,"%d fps: %d frames ran a count of ticks off the pattern",c.fps,uneven)
        testing.expectf(t,off==0,"%d fps: the shown time moved unevenly in %d frames",c.fps,off)
        drift:=f64(w.time.tick)*tick+w.frame_time.accumulator-clock
        testing.expectf(t,abs(drift)<1e-9,"%d fps: the ticks are %v s off the clock after 10 minutes",c.fps,drift)

        dropped,due:=app.stats.ticks_dropped,int((w.frame_time.accumulator+0.5)/tick)
        testing.expect_value(t,ticks_test_frame(&app,&w,dt=0.5),4)
        testing.expect_value(t,app.stats.ticks_dropped-dropped,u64(due-4))
        testing.expect_value(t,w.frame_time.alpha,f32(w.frame_time.accumulator/tick))
    }
}

@(private="file")
Loops_Test_World :: struct {
    using world:core.Test_World,
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
    shared_step :: proc(world,_,_,_:rawptr) {(cast(^Loops_Test_World)world).shared+=1}
    own_step :: proc(world,_,_,_:rawptr) {(cast(^Loops_Test_World)world).own+=1}
    steps:=[2]core.Step_Info{{name="both",phases={.Frame},loops={.Game,.Editor},call=shared_step},{name="own",phases={.Frame},loops={.Editor},call=own_step}}
    game_order,editor_order:=[1]i32{0},[2]i32{0,1}
    w:Loops_Test_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    info:=core.test_world_info(&w)
    info.steps=steps[:]
    info.order[.Game][.Frame],info.order[.Editor][.Frame]=game_order[:],editor_order[:]
    info.loops[.Game][.Frame]=proc(world,shared,editor,app:rawptr) {shared_step(world,shared,editor,app)}
    info.loops[.Editor][.Frame]=proc(world,shared,editor,app:rawptr) {shared_step(world,shared,editor,app);own_step(world,shared,editor,app)}
    app:=App{info=info,platform=p,tick_dt=1.0/60,max_ticks=4}
    defer delete(app.worlds)
    app_frame_begin(&app)
    app_game_frame(&app,&w,ALL_PHASES-{.Render})
    app_editor_frame(&app,&w,nil,played=true)
    testing.expectf(t,w.shared==1 && w.own==1,"a frame the game ran calls each once: %d and %d",w.shared,w.own)
    app_frame_begin(&app)
    app_editor_frame(&app,&w,nil,played=true)
    testing.expectf(t,w.shared==2 && w.own==2,"a frame without the game calls both: %d and %d",w.shared,w.own)
}
