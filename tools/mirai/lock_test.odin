package main

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:cook/workspace"
import "mirai:std/base"
import "mirai:std/subprocess"

// The folder the other process of two_projects_build_side_by_side works in.
LOCK_TEST_HELPER :: "MIRAI_LOCK_TEST_HELPER"

// The other process of two_projects_build_side_by_side, which runs this
// executable again with this test alone: it holds the turn of the build of
// project a until the folder has release. Without the variable it does nothing.
@(test)
lock_helper_holds_the_build_of_a_project :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,asked:=os.lookup_env(LOCK_TEST_HELPER,context.temp_allocator)
    if !asked {return}
    lock:=project_lock(join(folder,"engine"),"test helper",join(folder,"a"),.Editor)
    defer workspace.lock_release(&lock)
    _=os.write_entire_file(join(folder,"held"),[]u8{})
    for _ in 0..<3000 {
        if os.is_file(join(folder,"release")) {return}
        time.sleep(10*time.Millisecond)
    }
}

// While another process builds a project against binaries of the engine that
// stand, it holds the folder of that project and a turn, never the folder of
// the engine: the build of another project takes its own turn beside it, and
// one of the same project waits.
@(test)
two_projects_build_side_by_side :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"locks")
    if folder=="" {return}
    engine,a,b:=join(folder,"engine"),join(folder,"a"),join(folder,"b")
    for made in ([3]string{engine,a,b}) {
        if !testing.expect(t,base.make_directory_all(made)==nil) {return}
    }
    inherited,_:=os.environ(context.temp_allocator)
    environment:=make([dynamic]string,context.temp_allocator)
    for entry in inherited {if entry!="" {append(&environment,entry)}}
    append(&environment,strings.concatenate({LOCK_TEST_HELPER,"=",folder},context.temp_allocator))
    process,error:=subprocess.start({command={os.args[0],"-tests:lock_helper_holds_the_build_of_a_project"},env=environment[:]},{},.Merged)
    if !testing.expect_value(t,error,nil) {return}
    defer {
        _=os.write_entire_file(join(folder,"release"),[]u8{})
        _,_=subprocess.wait(&process,30*time.Second)
        subprocess.release(&process)
    }
    for _ in 0..<3000 {
        if os.is_file(join(folder,"held")) {break}
        time.sleep(10*time.Millisecond)
    }
    if !testing.expect(t,os.is_file(join(folder,"held")),"the other process took no turn") {return}
    held :: proc(folder:string) -> bool {
        taken,_,_:=workspace.lock_holder(join(folder,".mirai","build-turn.lock"),context.temp_allocator)
        return taken
    }
    testing.expect(t,held(a),"the other process holds its project")
    testing.expect(t,!held(engine),"the other process holds the folder of the engine")
    if workspace.build_turns_now()<2 {return}
    asked:=time.tick_now()
    lock:=project_lock(engine,"test",b,.Editor)
    waited:=time.tick_since(asked)
    workspace.lock_release(&lock)
    testing.expectf(t,waited<5*time.Second,"the build of another project waited %v",waited)
}
