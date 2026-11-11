package host

import "core:testing"
import "mirai:core"

@(private) Replay_World :: struct {using world:core.Test_World,time:core.Time,frame:core.Frame_Time,id:core.World_Id,corrected:bool}
@(private) Replay_Shared :: struct {problems:core.By_World(core.Problems)}

@(private)
replay_world_fixed :: proc(world,shared,editor,app_data:rawptr) {
    w:=cast(^Replay_World)world
    problems:=core.by_world_get(&(cast(^Replay_Shared)shared).problems,w.id)
    core.report(problems,core.NONE,"test.always","every tick fails")
    if w.corrected {core.report(problems,core.NONE,"test.corrected","only the corrected ticks fail")}
}

@(test)
a_resimulated_tick_counts_a_known_problem_once_and_keeps_a_new_one :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Replay_World,Replay_Shared,core.Test_None)
    if !described {return}
    defer core.test_info_destroy(&info)
    info.loops[.Game][.Fixed]=replay_world_fixed
    shared:Replay_Shared
    if !testing.expect(t,core.world_init(&info,.Shared,&shared,context.allocator)) {return}
    defer core.world_destroy(&info,.Shared,&shared)
    app:=App{info=&info,allocator=context.allocator,shared=&shared}
    defer delete(app.worlds)
    world:=cast(^Replay_World)app_world_create(&app)
    if !testing.expect(t,world!=nil) {return}
    defer app_world_free(&app,world)
    problems:=app_world_storage(&app,world,core.Problems)
    for _ in 0..<3 {app_tick_replay(&app,world,0)}
    always:=core.problem_find(problems,core.NONE,"test.always")
    if !testing.expect(t,always!=nil) {return}
    testing.expect_value(t,always.count,u64(3))
    serial:=problems.serial
    // A correction runs ticks 1 and 2 again, and the corrected state fails in a new way.
    world.time.tick,world.time.resimulating,world.corrected=1,true,true
    for _ in 0..<2 {app_tick_replay(&app,world,0)}
    testing.expect_value(t,always.count,u64(3))
    testing.expect_value(t,always.last,serial)
    corrected:=core.problem_find(problems,core.NONE,"test.corrected")
    testing.expect(t,corrected!=nil && corrected.count==1,"a problem only the corrected ticks have is new")
    testing.expect(t,!problems.resimulating && world.time.tick==3)
    world.time.resimulating=false
    app_tick_replay(&app,world,0)
    testing.expect_value(t,always.count,u64(4))
    testing.expect_value(t,corrected.count,u64(2))
}
