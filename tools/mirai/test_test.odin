package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:cook/shaders"
import "mirai:project"

// A benchmark is a define of a name with BENCH that is not off; it runs alone.
@(test)
a_benchmark_is_a_define_with_bench_that_is_on :: proc(t:^testing.T) {
    testing.expect(t,benchmark_asked({"-define:GI_BENCHMARK=true"}))
    testing.expect(t,benchmark_asked({"--release","-define:ANIM_BUDGET_BENCH_REPEATS=10"}))
    testing.expect(t,!benchmark_asked({"-define:API_BENCH=false"}))
    testing.expect(t,!benchmark_asked({"-define:COOK_BENCH=0"}))
    testing.expect(t,!benchmark_asked({"-define:ODIN_TEST_THREADS=1","-collection:bench=x"}))
}

// A check for another system generates that system's shaders too.
@(test)
a_check_for_another_system_generates_its_backend_with_the_host_one :: proc(t:^testing.T) {
    testing.expect_value(t,target_backends({"-vet"}),shaders.Backends{shaders.HOST_BACKEND})
    testing.expect_value(t,target_backends({"-target:darwin_arm64"}),shaders.Backends{shaders.HOST_BACKEND,.Metal})
    testing.expect_value(t,target_backends({"-target:linux_amd64"}),shaders.Backends{shaders.HOST_BACKEND,.Vulkan})
}

// The tests of a source are the procedures marked test, in any of the
// forms of an attribute, on their line or above it; not what a string or a
// comment holds.
@(test)
the_tests_of_a_source_are_its_procedures_marked_test :: proc(t:^testing.T) {
    text:=`package x

@(test)
first :: proc(t:^testing.T) {}

@test second :: proc(t:^testing.T) {}

@(private="file", test)
// a comment between
third :: proc(t:^testing.T) {}

@(private)
helper :: proc() {}

@(test)
Not_A_Proc :: struct {}

fourth :: proc() {}

quoted :: "@(test) in_a_string :: proc() {}"
/* @(test)
in_a_comment :: proc() {} */
`
    names:=test_procedures(text,context.temp_allocator)
    testing.expect_value(t,len(names),3)
    if len(names)==3 {
        testing.expect_value(t,names[0],"first")
        testing.expect_value(t,names[1],"second")
        testing.expect_value(t,names[2],"third")
    }
}

// A source builds for the system its name or its #+build lines say.
@(test)
a_source_builds_for_the_system_its_name_and_build_lines_say :: proc(t:^testing.T) {
    testing.expect(t,source_for_system("x_windows_test.odin","package x",.Windows))
    testing.expect(t,!source_for_system("x_windows_test.odin","package x",.Linux))
    testing.expect(t,!source_for_system("x_darwin.odin","package x",.Windows))
    testing.expect(t,source_for_system("x_render.odin","package x",.Linux))
    testing.expect(t,!source_for_system("x.odin","#+build !windows\npackage x",.Windows))
    testing.expect(t,source_for_system("x.odin","#+build !windows\npackage x",.Darwin))
    testing.expect(t,source_for_system("x.odin","#+build linux, darwin\n#+private\npackage x",.Darwin))
    testing.expect(t,!source_for_system("x.odin","#+build linux, darwin\npackage x",.Windows))
    testing.expect(t,source_for_system("x.odin","#+build windows amd64\npackage x",.Windows))
}

// The tests of this package are listed from its sources, all of them or those of a file.
@(test)
the_tests_of_a_package_are_listed_without_compiling :: proc(t:^testing.T) {
    declared:=test_declared(#directory,"",context.temp_allocator)
    found:=false
    for test in declared {
        if test.name=="a_benchmark_is_a_define_with_bench_that_is_on" {found=test.file=="test_test.odin" && test.here}
        // Declared in a string of a test above.
        testing.expect(t,test.name!="first")
    }
    testing.expect(t,found)
    of_file:=test_declared(#directory,"deps_test.odin",context.temp_allocator)
    testing.expect(t,len(of_file)>0)
    for test in of_file {testing.expect_value(t,test.file,"deps_test.odin")}
}

// A name that is not there gets the ones that share its words or most of its letters.
@(test)
a_missing_name_gets_the_similar_ones :: proc(t:^testing.T) {
    names:=[]string{"a_benchmark_is_a_define_with_bench_that_is_on","the_tests_of_a_source_are_its_procedures_marked_test","render_judge_finds_the_regressions"}
    similar:=test_similar("benchmark_define",names,context.temp_allocator)
    testing.expect(t,len(similar)>0 && similar[0]==names[0],"a shared word")
    similar=test_similar("render_judge_finds_the_regresions",names,context.temp_allocator)
    testing.expect(t,len(similar)>0 && similar[0]==names[2],"a typo")
    testing.expect_value(t,len(test_similar("zzz",names,context.temp_allocator)),0)
}

// The output of the runner: which tests run and which failed, the state
// changes mirai test asked for hidden, the info hidden when quiet, and the
// hint to recompile with ODIN_TEST_NAMES left out. The fatal message of a test can
// come before its start.
@(test)
the_output_of_the_runner_says_what_runs_and_what_failed :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    out:=Test_Output{quiet=true,states_hidden=true}
    lines:=[]string{
        "[INFO ] --- [2026-10-28 00:12:48] Starting test runner with 4 threads.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #0 main.fast changed state to Running.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #1 main.slow changed state to Running.",
        "[FATAL] --- [2026-10-28 00:12:48] [x_test.odin:20:broken()] runtime assertion: no",
        "[INFO ] --- [2026-10-28 00:12:48] Test #2 main.broken changed state to Running.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #3 main.crashes changed state to Running.",
        "a line a test printed",
        "[ERROR] --- [2026-10-28 00:12:48] [x_test.odin:9:slow()] expected 1, got 2",
        "[INFO ] --- [2026-10-28 00:12:48] Test #1 main.slow changed state to Failed.",
        "[INFO ] --- [2026-10-28 00:12:48] Test #0 main.fast changed state to Successful.",
        "C:/x/x_test.odin(30:5) Index 3 is out of range 0..<2",
        "[FATAL] --- [2026-10-28 00:12:48] Caught signal to stop test #3 main.crashes for: Illegal_Instruction.",
        "",
        "Finished 4 tests in 1.2s. 3 tests failed.",
        " - main.broken\truntime assertion: no",
        " - main.crashes\tSignal caught: Illegal_Instruction",
        " - main.slow   \texpected 1, got 2",
        "",
        "To run only the failed tests, use:",
        "\t-define:ODIN_TEST_NAMES=main.broken,main.crashes,main.slow,",
        "If your terminal supports OSC 52, you may use -define:ODIN_TEST_CLIPBOARD.",
    }
    shown:=make([dynamic]string)
    start:=time.tick_now()
    for line,i in lines {
        if text,show:=test_output_line(&out,line,start);show {append(&shown,text)}
        if i==5 {testing.expectf(t,len(out.running)==3 && "main.broken" not_in out.running,"running: %v",out.running)}
    }
    testing.expect_value(t,len(out.running),0)
    testing.expectf(t,slice.contains(out.failed[:],"slow") && slice.contains(out.failed[:],"broken") && slice.contains(out.failed[:],"crashes") && len(out.failed)==3,"failed: %v",out.failed[:])
    expected:=[]string{
        "[FATAL] --- [2026-10-28 00:12:48] [x_test.odin:20:broken()] runtime assertion: no",
        "[ERROR] --- [2026-10-28 00:12:48] [x_test.odin:9:slow()] expected 1, got 2",
        "C:/x/x_test.odin(30:5) Index 3 is out of range 0..<2",
        "[FATAL] --- [2026-10-28 00:12:48] Caught signal to stop test #3 main.crashes for: Illegal_Instruction.",
        "Finished 4 tests in 1.2s. 3 tests failed.",
        " - main.broken\truntime assertion: no",
        " - main.crashes\tSignal caught: Illegal_Instruction",
        " - main.slow   \texpected 1, got 2",
    }
    testing.expectf(t,slice.equal(shown[:],expected),"shown:\n%s",strings.join(shown[:],"\n"))

    // Without quiet, what a test prints and the info stay; the state changes asked by a flag too.
    loud:=Test_Output{}
    _,show:=test_output_line(&loud,"[INFO ] --- [2026-10-28 00:12:48] Test #0 main.fast changed state to Running.",start)
    testing.expect(t,show)
    _,show=test_output_line(&loud,"a line a test printed",start)
    testing.expect(t,show)
}

// The executable hangs when no test started or ended for the timeout, also
// before the first one; never without a timeout.
@(test)
an_executable_hangs_when_no_test_starts_or_ends_for_the_timeout :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    out:=Test_Output{states_hidden=true}
    start:=time.tick_now()
    out.changed=start
    later :: proc(tick:time.Tick,seconds:int) -> time.Tick {return {tick._nsec+i64(seconds)*i64(time.Second)}}
    testing.expect(t,!test_hung(out,2*time.Minute,later(start,119)))
    testing.expect(t,test_hung(out,2*time.Minute,later(start,120)))
    test_output_line(&out,"[INFO ] --- [2026-10-28 00:12:48] Test #0 main.waits changed state to Running.",later(start,100))
    testing.expect(t,!test_hung(out,2*time.Minute,later(start,200)))
    testing.expect(t,test_hung(out,2*time.Minute,later(start,220)))
    testing.expect(t,!test_hung(out,0,later(start,10000)))
}

// --failed keeps what failed before and did not run now, and what failed now.
@(test)
the_failed_tests_are_those_of_before_that_did_not_run_and_those_that_failed_now :: proc(t:^testing.T) {
    merged:=test_failed_merge({"a","b","c"},{"b","c"},{"c","d"},context.temp_allocator)
    testing.expectf(t,slice.equal(merged[:],[]string{"a","c","d"}),"%v",merged[:])
    merged=test_failed_merge({"a","b"},{},{"c"},context.temp_allocator)
    testing.expectf(t,slice.equal(merged[:],[]string{"c"}),"%v",merged[:])
}

// mirai test asks the runner for the state changes unless a flag does, and
// does not see them when a flag turns them off or logs less.
@(test)
the_state_changes_are_asked_unless_a_flag_decides :: proc(t:^testing.T) {
    added,seen:=test_states_asked({"-define:FOO=1"})
    testing.expect(t,added && seen)
    added,seen=test_states_asked({"-define:ODIN_TEST_LOG_STATE_CHANGES=true"})
    testing.expect(t,!added && seen)
    added,seen=test_states_asked({"-define:ODIN_TEST_LOG_STATE_CHANGES=false"})
    testing.expect(t,!added && !seen)
    added,seen=test_states_asked({"-define:ODIN_TEST_LOG_LEVEL=warning"})
    testing.expect(t,added && !seen)
}

// The threads of a test executable reserve 8 MB of stack on every system, unless the call passes
// linker flags of its own.
@(test)
the_threads_of_a_test_executable_get_the_stack_of_the_system_with_the_most :: proc(t:^testing.T) {
    when ODIN_OS==.Windows {
        testing.expect_value(t,test_link_flag({"-debug"}),"-extra-linker-flags:/STACK:8388608")
    } else {
        testing.expect_value(t,test_link_flag({"-debug"}),"")
    }
    testing.expect_value(t,test_link_flag({"-extra-linker-flags:/DEBUG"}),"")
}

// A package is found relative to the working folder before the engine.
@(test)
a_package_is_found_relative_to_the_working_folder :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=project.path_absolute(fmt.tprintf("mirai-package-%d",os.get_pid()),context.temp_allocator)
    testing.expect(t,os.make_directory_all(folder)==nil)
    defer os.remove_all(folder)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/a.odin",folder),`package a`)==nil)
    testing.expect_value(t,package_folder("/nowhere",os.base(folder)),folder)
}
