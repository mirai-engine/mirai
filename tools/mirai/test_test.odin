package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "mirai:cook/shaders"
import "mirai:project"
import "mirai:std/base"

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

// The tests of this package are listed from its sources, all of them or those of some files.
@(test)
the_tests_of_a_package_are_listed_without_compiling :: proc(t:^testing.T) {
    declared:=test_declared(#directory,allocator=context.temp_allocator)
    found:=false
    for test in declared {
        if test.name=="a_benchmark_is_a_define_with_bench_that_is_on" {found=test.file=="test_test.odin" && test.here}
        // Declared in a string of a test above.
        testing.expect(t,test.name!="first")
    }
    testing.expect(t,found)
    files:=[]string{"deps_test.odin","shell_test.odin"}
    of_files:=test_declared(#directory,files,allocator=context.temp_allocator)
    seen:[2]bool
    for test in of_files {
        at,among:=slice.linear_search(files,test.file)
        if testing.expectf(t,among,"%s is of %s",test.name,test.file) {seen[at]=true}
    }
    testing.expect(t,seen==[2]bool{true,true})
}

// A test reaches the device of the GPU tests when its procedure names the
// shared device or makes one, itself or through the declarations of the test
// files of its package; what a comment, a string, a member of something else
// or a file that is no test says is no reach.
@(test)
the_tests_that_reach_the_gpu_device_are_told_from_the_sources :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"test-device")
    if folder=="" {return}
    sources:=[?][2]string{
        {"fixture_test.odin",`package x

Fixture :: struct {device:rawptr}

fixture_init :: proc(t:^testing.T,f:^Fixture) -> bool {
    f.device=shared_device.take_or_skip(t)
    return f.device!=nil
}

@(deferred_out=scene_end)
scene_begin :: proc(
    t:^testing.T,
    f:^Fixture,
) -> bool {
    return fixture_init(t,f)
}

CASES :: [?]proc(t:^testing.T,f:^Fixture) -> bool{scene_begin}
`},
        {"gpu_test.odin",`package x

@(test)
through_two_helpers :: proc(t:^testing.T) {
    f:Fixture
    if !scene_begin(t,&f) {return}
}

@(test)
through_a_table :: proc(t:^testing.T) {
    for c in CASES {c(t,nil)}
}

when #config(X_BENCH,false) {
@(test)
inside_a_when :: proc(t:^testing.T) {
    device,_:=rhi.device_create({})
}
}
`},
        {"app.odin",`package x

app_start :: proc(gpu:bool) {
    if gpu {device,_:=rhi.device_create({})}
}
`},
        {"cpu_test.odin",`package x

// shared_device.take_or_skip is not taken here.
@(test)
names_it_in_words_only :: proc(t:^testing.T) {
    text:="rhi.device_create and fixture_init"
    testing.expect(t,table.fixture_init==nil && other.device_create==nil)
}

@(test)
starts_a_program_without_a_device :: proc(t:^testing.T) {
    app_start(false)
}
`},
    }
    for source in sources {testing.expect(t,os.write_entire_file(join(folder,source[0]),source[1])==nil)}
    declared:=test_declared(folder,device=true)
    testing.expect_value(t,len(declared),5)
    for test in declared {
        testing.expectf(t,test.device==(test.file=="gpu_test.odin"),"%s of %s: device %v",test.name,test.file,test.device)
    }
    for test in test_declared(folder) {testing.expectf(t,!test.device,"%s is told without being asked",test.name)}
}

// A package with no test to run is left out before anything is built, and is
// no error: it declares none, or --no-gpu leaves none. A name asked of it is
// still a wrong name.
@(test)
a_package_with_no_test_to_run_is_not_built :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=base.test_folder(t,"test-nothing")
    if root=="" {return}
    sources:=[?][3]string{
        {"empty","empty.odin","package empty\n\nvalue :: proc() -> int {return 1}\n"},
        {"cpu","cpu_test.odin","package cpu\n\n@(test)\nadds :: proc(t:^testing.T) {}\n"},
        {"gpu","gpu_test.odin","package gpu\n\n@(test)\ndraws :: proc(t:^testing.T) {device:=shared_device.take_or_skip(t)}\n"},
    }
    for source in sources {
        testing.expect(t,os.make_directory_all(join(root,source[0]))==nil)
        testing.expect(t,os.write_entire_file(join(root,source[0],source[1]),source[2])==nil)
    }
    cases:=[?]struct{folder,name:string,no_gpu,ok,nothing:bool}{
        {"empty","",false,true,true},
        {"empty","adds",false,false,false},
        {"cpu","",false,true,false},
        {"cpu","",true,true,false},
        {"gpu","",false,true,false},
        {"gpu","",true,true,true},
    }
    for c in cases {
        packages:=[1]Test_Package{{path=c.folder,folder=join(root,c.folder)}}
        if c.name!="" {append(&packages[0].names,c.name)}
        ok:=test_names_check(root,packages[:],false,c.no_gpu)
        testing.expectf(t,ok==c.ok,"%v: ok %v",c,ok)
        if ok {testing.expectf(t,packages[0].nothing==c.nothing,"%v: nothing %v",c,packages[0].nothing)}
    }
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

// --failed keeps what failed before and did not run now, and what failed now.
@(test)
the_failed_tests_are_those_of_before_that_did_not_run_and_those_that_failed_now :: proc(t:^testing.T) {
    merged:=test_failed_merge({"a","b","c"},{"b","c"},{"c","d"},context.temp_allocator)
    testing.expectf(t,slice.equal(merged[:],[]string{"a","c","d"}),"%v",merged[:])
    merged=test_failed_merge({"a","b"},{},{"c"},context.temp_allocator)
    testing.expectf(t,slice.equal(merged[:],[]string{"c"}),"%v",merged[:])
}

// A package is found relative to the working folder before the engine.
@(test)
a_package_is_found_relative_to_the_working_folder :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=project.path_absolute(fmt.tprintf("mirai-package-%d",os.get_pid()),context.temp_allocator)
    testing.expect(t,os.make_directory_all(folder)==nil)
    defer base.remove_all(folder)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/a.odin",folder),`package a`)==nil)
    testing.expect_value(t,package_folder("/nowhere",os.base(folder)),folder)
}
