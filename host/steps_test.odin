package host

import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:std/jobs"

@(private="file") RANGES :: 96

@(private="file")
Phase_World :: struct {
    app:^App,
    ran:[3]int,        // by step: its turn in the phase
    turn:int,
    done:[RANGES]u64,  // by range of the work the second step spreads
    whole:bool,        // the third step found every range done
}

@(private="file")
phase_turn :: proc(w:^Phase_World,step:int) {
    w.ran[step]=w.turn
    w.turn+=1
}

@(private="file") phase_first :: proc(world,shared,editor,app:rawptr) {phase_turn(cast(^Phase_World)world,0)}

// Spreads its work over the workers of the application, from the thread of the loop.
@(private="file")
phase_spread :: proc(world,shared,editor,app:rawptr) {
    w:=cast(^Phase_World)world
    phase_turn(w,1)
    jobs.parallel_for(&w.app.jobs,jobs.OWNER,RANGES,1,proc(w:^Phase_World,first,last:int,worker:int) {
        for at in first..<last {
            value:=u64(at+1)
            for _ in 0..<256 {value~=value<<13;value~=value>>7;value~=value<<17}
            w.done[at]=value
        }
    },w)
}

@(private="file")
phase_last :: proc(world,shared,editor,app:rawptr) {
    w:=cast(^Phase_World)world
    phase_turn(w,2)
    w.whole=true
    for value in w.done {w.whole&&=value!=0}
}

// As the generator writes the phase of a loop: its functions, in their order.
@(private="file")
phase_fixed :: proc(world,shared,editor,app:rawptr) {
    phase_first(world,shared,editor,app)
    phase_spread(world,shared,editor,app)
    phase_last(world,shared,editor,app)
}

// A phase runs its steps one after another on the thread of the loop,
// whatever the workers of the application; a step spreads its work inside
// with std/jobs, and what it spread is done when the next one runs.
@(test)
a_phase_runs_its_steps_in_order_and_a_step_spreads_its_work_inside :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    steps:=[3]core.Step_Info{
        {name="first",library="test",phases={.Fixed},loops={.Game},call=phase_first},
        {name="spread",library="test",phases={.Fixed},loops={.Game},call=phase_spread},
        {name="last",library="test",phases={.Fixed},loops={.Game},call=phase_last},
    }
    order:=[3]i32{0,1,2}
    info:core.World_Info
    info.steps=steps[:]
    info.order[.Game][.Fixed]=order[:]
    info.loops[.Game][.Fixed]=phase_fixed
    for threads in ([3]int{0,1,3}) {
        app:=App{info=&info,allocator=context.allocator}
        if !testing.expect(t,jobs.system_init(&app.jobs,{threads=threads})) {return}
        for tick in 0..<16 {
            w:=Phase_World{app=&app}
            run_phase(&app,.Game,.Fixed,{.Fixed},&w,nil)
            testing.expectf(t,w.ran==[3]int{0,1,2} && w.turn==3,"%d threads, tick %d: the steps ran in the turns %v",threads,tick,w.ran)
            testing.expectf(t,w.whole,"%d threads, tick %d: the step after the one that spread its work ran before it was done",threads,tick)
        }
        // A phase the caller does not ask for does not run.
        idle:=Phase_World{app=&app}
        run_phase(&app,.Game,.Fixed,{.Frame},&idle,nil)
        testing.expect_value(t,idle.turn,0)
        jobs.system_destroy(&app.jobs)
    }
}
