package workspace

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// A compilation counts from when it takes its turn: while it holds it, and
// after it left it for a measurement that started before it took it.
@(test)
a_compilation_counts_from_when_it_takes_its_turn :: proc(t:^testing.T) {
    root,error:=os.make_directory_temp("","mirai-workspace-*",context.temp_allocator)
    if error!=nil {testing.fail_now(t,fmt.tprintf("no temporary folder: %v",error))}
    defer os.remove_all(root)
    before:=time.now()
    testing.expect(t,!builds_since(root,before))
    // File times can lag the precise clock by a tick of the system.
    time.sleep(50*time.Millisecond)
    lock,ok:=build_acquire(root,fmt.tprintf("pid %d, mirai test",os.get_pid()))
    testing.expect(t,ok)
    testing.expect(t,builds_since(root,before))
    lock_release(&lock)
    testing.expect(t,builds_since(root,before))
    time.sleep(50*time.Millisecond)
    testing.expect(t,!builds_since(root,time.now()))
}

// A compilation takes a turn after the first only with the memory of another
// one free, a generation of shaders waits for none of them, and a measurement
// waits for all of them.
@(test)
the_turns_of_the_compilations_follow_the_memory_and_a_measurement_waits_for_them :: proc(t:^testing.T) {
    if measuring() {return}
    root,error:=os.make_directory_temp("","mirai-workspace-*",context.temp_allocator)
    if error!=nil {testing.fail_now(t,fmt.tprintf("no temporary folder: %v",error))}
    defer os.remove_all(root)
    first,first_taken,_,_:=build_turn_try(root,"first",2,BUILD_TURN_MEMORY)
    testing.expect(t,first_taken)
    _,refused,holder,_:=build_turn_try(root,"short of memory",2,BUILD_TURN_MEMORY-1)
    testing.expect(t,!refused)
    testing.expect_value(t,holder,"first")
    second,second_taken,_,_:=build_turn_try(root,"second",2,BUILD_TURN_MEMORY)
    testing.expect(t,second_taken)
    _,third_taken,_,_:=build_turn_try(root,"third",2,BUILD_TURN_MEMORY)
    testing.expect(t,!third_taken,"there are no more turns than the machine has")
    shaders,shaders_ok:=shaders_acquire(root,"shaders")
    testing.expect(t,shaders_ok,"a generation of shaders waits for no compilation")
    lock_release(&first)
    _,_,_,compiling:=measure_try(root,"measure")
    testing.expect(t,compiling,"a turn after the first keeps a measurement waiting")
    lock_release(&second)
    _,_,_,compiling=measure_try(root,"measure")
    testing.expect(t,compiling,"a generation of shaders keeps it waiting too")
    lock_release(&shaders)
    measure,started,_,_:=measure_try(root,"measure")
    testing.expect(t,started)
    lock_release(&measure)
}

// Two compilations of a checkout do not run at once, and what a compilation
// holds of its checkout goes with its turn.
@(test)
a_compilation_holds_its_checkout_and_the_project_it_builds :: proc(t:^testing.T) {
    root,error:=os.make_directory_temp("","mirai-workspace-*",context.temp_allocator)
    if error!=nil {testing.fail_now(t,fmt.tprintf("no temporary folder: %v",error))}
    defer os.remove_all(root)
    game:=join(root,"game")
    lock,ok:=build_acquire(root,"build",nil,{game})
    testing.expect(t,ok)
    paths:=[2]string{join(root,".mirai","build-turn.lock"),join(game,".mirai","build-turn.lock")}
    for path in paths {
        held,_,_:=lock_holder(path,context.temp_allocator)
        testing.expect(t,held,path)
    }
    lock_release(&lock)
    for path in paths {
        held,_,_:=lock_holder(path,context.temp_allocator)
        testing.expect(t,!held,path)
    }
}

// The holder of a lock is what it wrote when it took it, since then; a free
// lock has none.
@(test)
a_held_lock_says_who_holds_it_and_since_when :: proc(t:^testing.T) {
    root,error:=os.make_directory_temp("","mirai-workspace-*",context.temp_allocator)
    if error!=nil {testing.fail_now(t,fmt.tprintf("no temporary folder: %v",error))}
    defer os.remove_all(root)
    path:=lock_path(root,MEASURE_LOCK,context.temp_allocator)
    held,_,_:=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
    what:=fmt.tprintf("pid %d, mirai measure in %s",os.get_pid(),root)
    lock,ok:=lock_acquire(path,what)
    testing.expect(t,ok)
    holder:string
    since:time.Time
    held,holder,since=lock_holder(path,context.temp_allocator)
    testing.expect(t,held)
    testing.expect_value(t,holder,what)
    testing.expectf(t,abs(time.diff(since,time.now()))<time.Minute,"taken at %v",since)
    // Part of a measurement, a process sees none.
    if !measuring() {
        running,measurer:=measurement_running(root,context.temp_allocator)
        testing.expect(t,running)
        testing.expect_value(t,measurer,what)
    }
    lock_release(&lock)
    held,_,_=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
    // The owner file of a process that ended, whose pid is this one's now, holds nothing.
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s.owner",path),transmute([]u8)what)==nil)
    held,_,_=lock_holder(path,context.temp_allocator)
    testing.expect(t,!held)
}
