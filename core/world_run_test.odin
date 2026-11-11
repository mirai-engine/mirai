package core

import "core:testing"

@(private)
@(test_world)
Run_World :: struct {
    using world:Test_World,
    time:Time,
    frame:Frame_Time,
    seen:[4]f32, // the dt each step saw, by step
}

@(private="file")
run_step :: proc(world,shared,editor,app:rawptr,index:int) {
    w:=cast(^Run_World)world
    w.seen[index]=w.time.dt+(w.frame.phase==.Fixed?100:0)
}
@(private="file") run_first :: proc(world,shared,editor,app:rawptr) {run_step(world,shared,editor,app,0)}
@(private="file") run_second :: proc(world,shared,editor,app:rawptr) {run_step(world,shared,editor,app,1)}
@(private="file") run_other :: proc(world,shared,editor,app:rawptr) {run_step(world,shared,editor,app,2)}

// A tool runs the functions of some libraries of a phase as the loop would:
// in its order, with the Time it gives, which the World gets back after, and
// with what waited settled first.
@(test)
world_run_calls_the_functions_of_the_libraries_asked_in_the_order_of_the_loop :: proc(t:^testing.T) {
    w:Run_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    destroy(&w.entities,create(&w.entities))
    w.time={dt=0.5,tick=7}
    steps:=[3]Step_Info{
        {name="first",library="anim",call=run_first},
        {name="second",library="core",call=run_second},
        {name="other",library="physics",call=run_other},
    }
    order:=[3]i32{1,2,0}
    w.frame={accumulator=0.125,phase=.Render}
    info:=test_world_info(&w)
    info.steps=steps[:]
    info.order[.Editor][.Fixed]=order[:]
    app:u8
    testing.expect(t,world_run(world_ref(&w,info),nil,nil,&app,.Editor,.Fixed,{"anim","core"},{dt=0.25}))
    testing.expect_value(t,w.seen,[4]f32{100.25,100.25,0,0})
    testing.expect_value(t,len(w.entities.doomed),0)
    testing.expect(t,w.time.dt==0.5 && w.time.tick==7)
    testing.expect(t,w.frame.phase==.Render && w.frame.accumulator==0.125)
    testing.expect(t,!world_run(world_ref(&w,info),nil,nil,nil,.Editor,.Fixed,{"anim"},{}))
    testing.expect(t,!world_run(world_ref(&w,info,.Shared),nil,nil,&app,.Editor,.Fixed,{"anim"},{}))
}

@(private="file") Run_Seen :: struct {camera:Entity,seen:[dynamic]Entity,pairs:[2]struct {at:Entity,weight:f32},count:i32}
@(private) @(storage,keep) Run_Kept :: distinct Run_Seen
@(private) @(storage) Run_Derived :: distinct Run_Seen

@(private)
@(test_world)
Run_Kept_World :: struct {
    using world:Test_World,
    kept:Run_Kept,
    derived:Run_Derived,
}

// A World made apart takes the state of the run of the one it replaces,
// whose Entity fields named entities of the other World: they name none.
@(test)
the_state_of_the_run_passes_to_another_world_without_its_entities :: proc(t:^testing.T) {
    from,to:Run_Kept_World
    if !test_world_init(t,&from) || !test_world_init(t,&to) {return}
    defer test_world_destroy(&from)
    defer test_world_destroy(&to)
    info:=test_world_info(&from)
    e:=entity_make(3,1)
    from.kept={camera=e,count=7}
    from.kept.pairs[1]={e,0.5}
    append(&from.kept.seen,e,e)
    from.derived.camera=e
    testing.expect(t,world_run_copy(world_ref(&to,info),world_ref(&from,info)))
    testing.expect(t,to.kept.camera==NONE && to.kept.count==7 && to.kept.pairs[1]=={NONE,0.5})
    testing.expect(t,len(to.kept.seen)==2 && to.kept.seen[0]==NONE && to.kept.seen[1]==NONE)
    testing.expect_value(t,from.kept.camera,e)
    testing.expect_value(t,to.derived.camera,NONE)
}
