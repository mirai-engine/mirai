package main

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/subprocess"

TEST_USAGE :: "test <package> [test|file.odin...] [<package>...] [--no-gpu] [--failed] [--quiet] [--timeout S] [--release] [-flag...]"
TEST_LIST_USAGE :: "test <package> [file.odin...] --list [--no-gpu]"

// How long a test may run while no other one starts or ends (test_hung).
TEST_TIMEOUT :: 120*time.Second

// A package of a call to mirai test and what is asked of it: tests by their
// names and by the files that declare them; neither is all of it. nothing:
// none of what was asked is left to run.
@(private="file")
Test_Package :: struct {path,folder:string,names,files:[dynamic]string,nothing:bool}

// What compiling and running the tests took. turn: waiting for other compilations.
@(private="file")
Test_Times :: struct {build,turn,run:time.Duration}

// The build of the test executable of a package.
@(private="file")
Test_Build :: struct {
    executable:string,
    command:[dynamic]string, // of the compiler; none when the executable there stands
    key:string,              // what it is built from besides its sources
    staging,log:string,      // what the compiler writes, and what it says
    process:os.Process,
    running,failed:bool,
    code:int,                // of a compiler that failed
    said:string,             // by the compiler, shown in the turn of the package
}

// mirai test: the tests of one package or of several. Their executables are
// compiled first, several at once (test_builds_run), each only when its
// sources, its flags or the compiler changed since the one there was built;
// then they run one after another in the order asked, without the implicit
// layers of Vulkan (layers_isolate), and one that was not built does not stop
// the others. The names
// of tests go to the runner (-tests:), so asking for others compiles nothing;
// a name the sources do not declare stops the command before it compiles.
// An argument that is a folder of the engine, or a path to one, is a package;
// the others are tests of the package before them, or files of it whose tests
// are asked; --no-gpu leaves out the tests of the files that reach the device
// of the GPU tests; --release and the flags are for all of them. The
// collections plugins and project a package reaches are passed unless a flag
// already names them. What the runner says goes through Test_Output, which
// kills an executable that hangs (test_hung).
cmd_test :: proc(root:string,args:[]string) -> int {
    packages:=make([dynamic]Test_Package)
    flags:=make([dynamic]string)
    optimization:="minimal"
    list,failed_only,quiet,no_gpu:=false,false,false,false
    timeout:=TEST_TIMEOUT
    timeout_given:=false
    for i:=0;i<len(args);i+=1 {
        arg:=args[i]
        switch {
        case arg=="--release":  optimization="speed"
        case arg=="--list":   list=true
        case arg=="--failed": failed_only=true
        case arg=="--quiet":  quiet=true
        case arg=="--no-gpu": no_gpu=true
        case arg=="--timeout":
            seconds,parsed:=strconv.parse_f64(i+1<len(args)?args[i+1]:"")
            if !parsed || !(seconds>=0) {
                fmt.eprintln("mirai test: --timeout is followed by the seconds a test may run while no other one starts or ends (0: no limit)")
                return 2
            }
            timeout=time.Duration(seconds*f64(time.Second))
            timeout_given=true
            i+=1
        case strings.has_prefix(arg,"-"): append(&flags,arg)
        case strings.has_suffix(arg,".odin"):
            if !test_file_take(root,arg,&packages) {return 2}
        case package_folder(root,arg)!="": append(&packages,Test_Package{path=arg,folder=package_folder(root,arg)})
        case len(packages)>0: append(&packages[len(packages)-1].names,arg)
        case:
            fmt.eprintfln("mirai test: %s is not a folder with Odin sources; the first argument is a package, relative to the working folder (%s) or to the engine (%s), or absolute",arg,project.path_absolute(".",context.temp_allocator),root)
            fmt.eprintfln("Usage: mirai %s\n       mirai %s",TEST_USAGE,TEST_LIST_USAGE)
            return 2
        }
    }
    if len(packages)==0 {
        // Inside a project with no package named: its game, as build.test does.
        game:=project_game_folder(root)
        if game=="" {fmt.eprintfln("Usage: mirai %s\n       mirai %s",TEST_USAGE,TEST_LIST_USAGE);return 2}
        append(&packages,Test_Package{path=game,folder=game})
    }
    if list {return test_list(packages[:],no_gpu)}
    // The tests that build something (cook/image, asset, the importer) run the
    // compiler this run builds the suites with: MIRAI_ODIN names it, as
    // MIRAI_ROOT names the engine, so Odin needs no place in PATH.
    _=os.set_env("MIRAI_ODIN",odin_executable(root))
    if !test_names_check(root,packages[:],failed_only,no_gpu) {return 2}
    benchmark:=benchmark_asked(flags[:])
    // A benchmark may take long: only --timeout bounds it.
    if benchmark && !timeout_given {timeout=0}
    states_added,states_seen:=test_states_asked(flags[:])
    if !states_seen {timeout=0}
    build_flags:=make([dynamic]string)
    append(&build_flags,..flags[:])
    if states_added {append(&build_flags,"-define:ODIN_TEST_LOG_STATE_CHANGES=true")}

    pending:=0
    for p in packages {
        if !p.nothing {pending+=1}
    }
    if pending==0 {return 0}
    times:Test_Times
    tests:=join(root,"bin","tests")
    if os.make_directory_all(tests)!=nil && !os.is_dir(tests) {return 1}
    prepared:=time.tick_now()
    // ui links the FreeType library, the importer that of ufbx and the editor that of SQLite.
    if !engine_shaders(root) || !ensure_runtime_dependencies(root) {return 1}
    ensure_sdl(root,tests)
    builds:=make([]Test_Build,len(packages))
    for p,i in packages {
        if p.nothing {continue}
        if !test_imports_check(root,p.folder) || !plugin_test_shaders(root,p.folder) {
            builds[i].failed=true
            continue
        }
        builds[i]=test_build_plan(root,p.folder,optimization,build_flags[:])
    }
    test_builds_run(root,packages[:],builds,&times)
    times.build+=time.tick_since(prepared)
    layers_isolate(root)
    failed:=make([dynamic]string)
    for &p,i in packages {
        if p.nothing {continue}
        if len(packages)>1 {fmt.printfln("== %s",p.path)}
        executable:=builds[i].executable
        if !test_build_say(p.path,builds[i]) {
            append(&failed,p.path)
            continue
        }
        command:=make([dynamic]string)
        append(&command,executable)
        if len(p.names)>0 {append(&command,fmt.aprintf("-tests:%s",strings.join(p.names[:],",")))}
        out:=Test_Output{quiet=quiet,states_hidden=states_added}
        ran:=time.tick_now()
        ok:=test_run(root,p.path,command[:],benchmark,&out,timeout)
        times.run+=time.tick_since(ran)
        // A run that ended badly without naming a failed test leaves the list of before.
        if ok || len(out.failed)>0 {test_failed_save(executable,p.names[:],out.failed[:])}
        if len(out.failed)>0 {fmt.eprintfln("mirai test: to run only the ones that failed: mirai test %s --failed",p.path)}
        if !ok {append(&failed,p.path)}
    }
    if len(packages)>1 {
        if len(failed)==0 {fmt.printfln("mirai test: %d packages, all pass",len(packages))}
        else {fmt.eprintfln("mirai test: %d of %d packages fail: %s",len(failed),len(packages),strings.join(failed[:],", "))}
    }
    turn:=""
    if times.turn>=100*time.Millisecond {turn=fmt.tprintf(" (%.1f s waiting for the turn)",time.duration_seconds(times.turn))}
    fmt.eprintfln("mirai test: build %.1f s%s, run %.1f s",time.duration_seconds(times.build),turn,time.duration_seconds(times.run))
    return len(failed)>0?1:0
}

// Runs the tests of a package. One that is no benchmark does not wait for a
// measurement: while one runs it runs at low priority. A benchmark is a
// measurement: it runs alone among the checkouts (measure_lock).
@(private="file")
test_run :: proc(root,path:string,command:[]string,benchmark:bool,out:^Test_Output,timeout:time.Duration) -> bool {
    if !benchmark || workspace.measuring() {
        priority:=subprocess.Priority.Normal
        if measured,measurer:=workspace.measurement_running(root,context.temp_allocator);measured {
            fmt.eprintfln("mirai test: a measurement is running (%s); the tests run at low priority",measurer!=""?measurer:"another process")
            priority=.Low
        }
        return test_execute(root,path,command,out,priority,timeout)==0
    }
    lock:=measure_lock(root,fmt.tprintf("test %s",path))
    defer workspace.lock_release(&lock)
    _=os.set_env(workspace.MEASURE_ENV,fmt.tprintf("%d",os.get_pid()))
    defer os.unset_env(workspace.MEASURE_ENV)
    return test_execute(root,path,command,out,.Normal,timeout)==0
}

// Whether the flags let mirai test see when each test starts and ends: added,
// when it asks the runner for it (ODIN_TEST_LOG_STATE_CHANGES) because no flag
// does; seen, unless a flag turns it off or logs less than info.
test_states_asked :: proc(flags:[]string) -> (added,seen:bool) {
    added,seen=true,true
    for flag in flags {
        if !strings.has_prefix(flag,"-define:") {continue}
        name,_,value:=strings.partition(flag[len("-define:"):],"=")
        switch name {
        case "ODIN_TEST_LOG_STATE_CHANGES":
            added=false
            seen=seen && value!="false" && value!="0"
        case "ODIN_TEST_LOG_LEVEL":
            seen=seen && (value=="debug" || value=="info")
        }
    }
    return
}

// The tests of a package that failed the last time it ran, next to its
// executable, for --failed.
@(private="file")
test_failed_file :: proc(executable:string) -> string {
    return fmt.tprintf("%s.failed",executable)
}

@(private="file")
test_failed_save :: proc(executable:string,asked,failed:[]string) {
    bare:=make([dynamic]string,context.temp_allocator)
    for name in asked {append(&bare,test_bare(name))}
    names:=test_failed_merge(test_failed_load(executable)[:],bare[:],failed,context.temp_allocator)
    b:=strings.builder_make(context.temp_allocator)
    for name in names {fmt.sbprintln(&b,name)}
    _=os.write_entire_file(test_failed_file(executable),transmute([]u8)strings.to_string(b))
}

@(private="file")
test_failed_load :: proc(executable:string) -> [dynamic]string {
    names:=make([dynamic]string,context.temp_allocator)
    data,error:=os.read_entire_file(test_failed_file(executable),context.temp_allocator)
    if error!=nil {return names}
    text:=string(data)
    for line in strings.split_lines_iterator(&text) {
        if name:=strings.trim_space(line);name!="" {append(&names,name)}
    }
    return names
}

// The tests that failed the last time: those of before that did not run now,
// and those that failed now. asked: the tests that ran now; none is all.
test_failed_merge :: proc(before,asked,failed:[]string,allocator:=context.allocator) -> [dynamic]string {
    names:=make([dynamic]string,allocator)
    if len(asked)>0 {
        for name in before {
            if !slice.contains(asked,name) {append(&names,name)}
        }
    }
    for name in failed {
        if !slice.contains(names[:],name) {append(&names,name)}
    }
    return names
}

// Whether the flags ask for a benchmark: a -define whose name has BENCH and
// whose value is not false or 0.
benchmark_asked :: proc(flags:[]string) -> bool {
    for flag in flags {
        if !strings.has_prefix(flag,"-define:") {continue}
        name,_,value:=strings.partition(flag[len("-define:"):],"=")
        if strings.contains(strings.to_upper(name,context.temp_allocator),"BENCH") && value!="false" && value!="0" {return true}
    }
    return false
}

// A .odin argument names a file whose tests are asked: the name of a file of
// the package before it, or a path to one from the working folder or the
// engine, or absolute. false, after saying what it can be, when it is neither.
@(private="file")
test_file_take :: proc(root,arg:string,packages:^[dynamic]Test_Package) -> bool {
    n:=len(packages)
    named:=os.base(arg)==arg
    if n>0 && named && os.is_file(join(packages[n-1].folder,arg)) {
        append(&packages[n-1].files,arg)
        return true
    }
    for candidate in ([2]string{project.path_absolute(arg,context.temp_allocator),join(root,arg)}) {
        if !os.is_file(candidate) {continue}
        folder:=project.path_absolute(os.dir(candidate))
        if n==0 || !path_same(packages[n-1].folder,folder) {
            path:=os.dir(arg)
            append(packages,Test_Package{path=path!=""?path:".",folder=folder})
        }
        append(&packages[len(packages)-1].files,os.base(candidate))
        return true
    }
    if n==0 || !named {
        fmt.eprintfln("mirai test: there is no file %s; a file is given by its path from the working folder (%s) or from the engine (%s), or by its name after its package: mirai test <package> <file>_test.odin",arg,project.path_absolute(".",context.temp_allocator),root)
        return false
    }
    p:=packages[n-1]
    files:=make([dynamic]string,context.temp_allocator)
    for test in test_declared(p.folder,allocator=context.temp_allocator) {
        if !slice.contains(files[:],test.file) {append(&files,test.file)}
    }
    if similar:=test_similar(arg,files[:],context.temp_allocator);len(similar)>0 {
        fmt.eprintfln("mirai test: %s has no file %s; similar: %s",p.path,arg,strings.join(similar,", ",context.temp_allocator))
    } else {
        fmt.eprintfln("mirai test: %s has no file %s; mirai test %s --list shows its files with tests",p.path,arg,p.path)
    }
    return false
}

// The files with a test that reaches the device of the GPU tests.
@(private="file")
test_device_files :: proc(declared:[]Test_Declared) -> [dynamic]string {
    files:=make([dynamic]string,context.temp_allocator)
    for test in declared {
        if test.device && !slice.contains(files[:],test.file) {append(&files,test.file)}
    }
    return files
}

// mirai test --list: the tests the sources of each package, or of its files
// asked, declare, by file, without compiling; with --no-gpu, without the
// files that reach the device of the GPU tests.
@(private="file")
test_list :: proc(packages:[]Test_Package,no_gpu:bool) -> int {
    for p in packages {
        declared:=test_declared(p.folder,p.files[:],no_gpu)
        device:=test_device_files(declared[:])
        file:=""
        count:=0
        for test in declared {
            if slice.contains(device[:],test.file) {continue}
            if test.file!=file {
                file=test.file
                fmt.printfln("%s/%s%s",strings.trim_right(p.path,"/\\"),file,test.here?"":" (does not build on this system)")
            }
            fmt.printfln("  %s",test.name)
            count+=1
        }
        of:=len(p.files)>0?fmt.tprintf(" (%s)",strings.join(p.files[:],", ",context.temp_allocator)):""
        without:=len(device)>0?fmt.tprintf(", without the %d of files that reach the GPU device",len(declared)-count):""
        fmt.printfln("%d tests in %s%s%s",count,p.path,of,without)
    }
    return 0
}

// Settles what each package runs before anything compiles. The names asked
// are checked against those its sources declare: a wrong one stops the
// command and says which ones look like it. The tests of the files asked join
// them, and with --failed those that failed the last time, but for one the
// sources no longer declare. With --no-gpu the tests of the files that reach
// the device of the GPU tests leave.
@(private="file")
test_names_check :: proc(root:string,packages:[]Test_Package,failed_only,no_gpu:bool) -> bool {
    ok:=true
    for &p in packages {
        declared:=test_declared(p.folder,device=no_gpu)
        names:=make([dynamic]string,context.temp_allocator)
        for test in declared {
            if test.here {append(&names,test.name)}
        }
        for file in p.files {
            found,here:=false,false
            for test in declared {
                if !path_same(test.file,file) {continue}
                found=true
                here||=test.here
                if test.here && !slice.contains(p.names[:],test.name) {append(&p.names,test.name)}
            }
            if here {continue}
            ok=false
            if found {fmt.eprintfln("mirai test: %s/%s does not build on this system",p.path,file)}
            else {fmt.eprintfln("mirai test: %s/%s declares no test; mirai test %s --list shows the files that do",p.path,file,p.path)}
        }
        if failed_only {
            last:=test_failed_load(test_executable(root,p.folder))
            for name in last {
                if !slice.contains(names[:],name) {
                    fmt.eprintfln("mirai test: %s: %s failed the last time and is no longer in the sources; skipped",p.path,name)
                    continue
                }
                if !slice.contains(p.names[:],name) {append(&p.names,name)}
            }
            p.nothing=len(p.names)==0
            if p.nothing {fmt.printfln("mirai test: %s: no test failed the last time",p.path)}
        }
        for asked in p.names {
            name:=test_bare(asked)
            if slice.contains(names[:],name) {continue}
            ok=false
            elsewhere:=""
            for test in declared {
                if test.name==name {elsewhere=test.file}
            }
            similar:=test_similar(name,names[:],context.temp_allocator)
            switch {
            case elsewhere!="": fmt.eprintfln("mirai test: %s does not build on this system (%s/%s)",name,p.path,elsewhere)
            case len(similar)>0: fmt.eprintfln("mirai test: %s has no test %s; similar: %s",p.path,name,strings.join(similar,", ",context.temp_allocator))
            case: fmt.eprintfln("mirai test: %s has no test %s; mirai test %s --list shows them",p.path,name,p.path)
            }
        }
        device:=test_device_files(declared[:])
        if len(device)==0 || p.nothing {continue}
        asked:=make(map[string]bool,context.temp_allocator)
        for name in p.names {asked[test_bare(name)]=true}
        kept:=make([dynamic]string)
        left:=0
        for test in declared {
            if !test.here || (len(asked)>0 && test.name not_in asked) {continue}
            if slice.contains(device[:],test.file) {left+=1} else {append(&kept,test.name)}
        }
        if left==0 {continue}
        fmt.eprintfln("mirai test: %s: --no-gpu leaves out %d test%s of files that reach the GPU device; mirai test %s --list --no-gpu shows the ones that stay",p.path,left,left==1?"":"s",p.path)
        p.names=kept
        p.nothing=len(kept)==0
        if p.nothing {fmt.printfln("mirai test: %s: every test asked is of a file that reaches the GPU device",p.path)}
    }
    return ok
}

// The executable of the tests of a package: bin/tests/<test_name>.
@(private="file")
test_executable :: proc(root,folder:string) -> string {
    return join(root,"bin","tests",fmt.aprintf("%s%s",test_name(root,folder),EXE))
}

// The flag that gives the threads of a test executable the stack of the system with the most:
// none when the flags of the call already pass the linker flags of their own.
test_link_flag :: proc(flags:[]string) -> string {
    for flag in flags {if strings.has_prefix(flag,"-extra-linker-flags:") {return ""}}
    return TEST_STACK_FLAG
}

// What building the test executable of a package takes: no command when the
// one there was built from the same. failed, after saying why, when the
// collections it reaches cannot be told.
@(private="file")
test_build_plan :: proc(root,folder,optimization:string,flags:[]string) -> (planned:Test_Build) {
    planned.executable=test_executable(root,folder)
    command:=odin_command(root,"build",folder)
    append(&command,"-build-mode:test",fmt.aprintf("-o:%s",optimization))
    collections,collections_ok:=package_collections(root,folder,flags)
    if !collections_ok {
        planned.failed=true
        return
    }
    append(&command,..collections)
    append(&command,..flags)
    if stack:=test_link_flag(flags);stack!="" {append(&command,stack)}
    // What the build is made from besides its sources: the command and the compiler.
    key:=strings.builder_make()
    for argument in command {fmt.sbprintln(&key,argument)}
    if info,error:=os.stat(command[0],context.temp_allocator);error==nil {fmt.sbprintf(&key,"%d %v",info.size,info.modification_time)}
    planned.key=strings.to_string(key)
    if test_current(root,folder,planned.executable,test_sources_file(planned.executable),test_stamp_file(planned.executable),planned.key) {return}
    planned.staging=join(root,"bin","tests",fmt.aprintf(".%s-build-%d%s",test_name(root,folder),os.get_pid(),EXE))
    planned.log=fmt.aprintf("%s.log",planned.staging)
    append(&command,fmt.aprintf("-out:%s",planned.staging),"-export-dependencies:json",fmt.aprintf("-export-dependencies-file:%s",test_sources_file(planned.staging)))
    planned.command=command
    return
}

// What the compiler read to build a test executable, and what else it was built from.
@(private="file")
test_sources_file :: proc(executable:string) -> string {return fmt.aprintf("%s.sources.json",executable)}

@(private="file")
test_stamp_file :: proc(executable:string) -> string {return fmt.aprintf("%s.build",executable)}

// Compiles the test executables that have a command, as many at once as a
// build runs compilers (build.compilers_at_once), in the order asked and
// within one turn of the compilations: together they are one build of this
// checkout. What each compiler says is kept for the turn of its package
// (test_build_say); one that fails leaves the executable of before in place.
@(private="file")
test_builds_run :: proc(root:string,packages:[]Test_Package,builds:[]Test_Build,times:^Test_Times) {
    waiting:=make([dynamic]int,context.temp_allocator)
    paths:=make([dynamic]string,context.temp_allocator)
    for planned,i in builds {
        if len(planned.command)==0 {continue}
        append(&waiting,i)
        append(&paths,packages[i].path)
    }
    if len(waiting)==0 {return}
    limit:=build.compilers_at_once()
    if len(waiting)>1 {fmt.eprintfln("mirai test: building %d packages, %d at once",len(waiting),min(limit,len(waiting)))}
    asked:=time.tick_now()
    lock:=build_lock(root,fmt.tprintf("test %s",strings.join(paths[:]," ",context.temp_allocator)))
    defer workspace.lock_release(&lock)
    times.turn+=time.tick_since(asked)
    running:=0
    for len(waiting)>0 || running>0 {
        for len(waiting)>0 && running<limit {
            if test_build_start(root,&builds[waiting[0]]) {running+=1}
            ordered_remove(&waiting,0)
        }
        ended:=false
        for &b in builds {
            if !b.running {continue}
            state,error:=os.process_wait(b.process,0)
            if error==os.General_Error.Timeout || (error==nil && !state.exited) {continue}
            b.running=false
            running-=1
            ended=true
            if said,read_error:=os.read_entire_file(b.log,context.allocator);read_error==nil {b.said=string(said)}
            os.remove(b.log)
            staged_sources:=test_sources_file(b.staging)
            switch {
            case error!=nil:
                fmt.eprintfln("mirai test: %s: %v",b.command[0],error)
                b.failed=true
            case state.exit_code!=0:
                b.failed,b.code=true,state.exit_code
            case !executable_publish(root,b.staging,b.executable,staged_sources,test_sources_file(b.executable)):
                b.failed=true
            case:
                _=os.write_entire_file(test_stamp_file(b.executable),b.key)
            }
            if b.failed {os.remove(b.staging);os.remove(staged_sources)}
        }
        if !ended {time.sleep(10*time.Millisecond)}
    }
}

// Starts the compiler of a test executable within what it may use
// (build.compiler_limits), with what it says going to its log. false, after
// saying why, when it does not start.
@(private="file")
test_build_start :: proc(root:string,b:^Test_Build) -> bool {
    log,error:=os.open(b.log,{.Write,.Create,.Trunc})
    if error!=nil {
        fmt.eprintfln("mirai test: could not write %s: %v",b.log,error)
        b.failed=true
        return false
    }
    b.process,error=subprocess.start({working_dir=root,command=b.command[:],stdout=log,stderr=log},build.compiler_limits(root))
    os.close(log)
    if error!=nil {
        fmt.eprintfln("mirai test: could not run %s: %v",b.command[0],error)
        os.remove(b.log)
        b.failed=true
        return false
    }
    b.running=true
    return true
}

// Shows, in the turn of a package, what the compiler of its test executable
// said. false, after saying that it was not built, when there is none to run.
@(private="file")
test_build_say :: proc(path:string,b:Test_Build) -> bool {
    if said:=strings.trim_right_space(b.said);said!="" {fmt.eprintln(said)}
    switch {
    case !b.failed:
        return true
    case b.code==0:
        fmt.eprintfln("mirai test: %s was not built; why is said above",path)
    case:
        if build.compiler_out_of_memory(b.said) {
            fmt.eprintln(out_of_memory_text("mirai test"))
        } else if strings.trim_space(b.said)=="" && build.compiler_crashed(b.code) {
            fmt.eprintfln("mirai test: %s",build.compiler_silent_failure(b.code,context.temp_allocator))
        }
        fmt.eprintfln("mirai test: could not build %s (the compiler exited with %d)",path,b.code)
    }
    return false
}

// Whether the executable there was built from this key and from sources that
// did not change since: those of the engine, of the project of the package
// and of the package itself when it lies outside them, with the test files
// of every package it imports.
@(private="file")
test_current :: proc(root,folder,executable,sources,stamp,key:string) -> bool {
    saved,error:=os.read_entire_file(stamp,context.temp_allocator)
    if error!=nil || string(saved)!=key || !os.is_file(executable) {return false}
    roots:=make([dynamic]string,context.temp_allocator)
    append(&roots,root)
    if owner:=project_of(folder);owner!="" && !path_inside(owner,root) {append(&roots,owner)}
    if !path_inside(folder,root) {append(&roots,folder)}
    for top in roots {
        newer,known:=build.sources_newer(sources,executable,top,tests=true)
        if !known || newer {return false}
    }
    return true
}

// The folder of a package given as a path relative to the working folder or
// to the engine, or absolute; "" when it is no folder with Odin sources.
package_folder :: proc(root,path:string) -> string {
    for candidate in ([2]string{project.path_absolute(path,context.temp_allocator),join(root,path)}) {
        if !os.is_dir(candidate) {continue}
        entries,_:=os.read_all_directory_by_path(candidate,context.temp_allocator)
        for entry in entries {
            if entry.type==.Regular && strings.has_suffix(entry.name,".odin") {return project.path_absolute(candidate)}
        }
    }
    return ""
}

// The folder of the game of the project the working folder is in, when it has Odin sources; "" outside one.
project_game_folder :: proc(root:string) -> string {
    owner:=project_of(project.path_absolute(".",context.temp_allocator))
    return "" if owner=="" else package_folder(root,join(owner,project.FOLDER_NAMES[.Game]))
}

// The name of the executable of a package: its path in the engine, or its
// name and a hash of its path when it lies outside.
@(private="file")
test_name :: proc(root,folder:string) -> string {
    if path_inside(folder,root) {
        relative:=folder[len(project.path_absolute(root,context.temp_allocator))+1:]
        name,_:=strings.replace_all(relative,"/","_")
        return name
    }
    return fmt.aprintf("%s-%x",os.base(folder),u32(xxhash.XXH3_64_default(transmute([]u8)folder)))
}

// The collections a package reaches besides mirai: plugins when it, or a
// package it imports through plugins or project, imports "plugins:"; project,
// the nearest folder above it with a project.mirai, when one imports
// "project:". A flag that names one already is left as it is.
package_collections :: proc(root,folder:string,flags:[]string) -> (collections:[]string,ok:bool) {
    given :: proc(flags:[]string,name:string) -> bool {
        for flag in flags {
            if strings.has_prefix(flag,fmt.tprintf("-collection:%s=",name)) {return true}
        }
        return false
    }
    owner:=project_of(folder)
    plugins,needs_project:=false,false
    seen:=make(map[string]bool,context.temp_allocator)
    queue:=make([dynamic]string,context.temp_allocator)
    append(&queue,folder)
    for len(queue)>0 {
        at:=pop(&queue)
        if seen[at] {continue}
        seen[at]=true
        entries,_:=os.read_all_directory_by_path(at,context.temp_allocator)
        for entry in entries {
            if entry.type!=.Regular || !strings.has_suffix(entry.name,".odin") {continue}
            data,error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
            if error!=nil {continue}
            text:=string(data)
            for line in strings.split_lines_iterator(&text) {
                line:=strings.trim_space(line)
                if !strings.has_prefix(line,"import ") {continue}
                open:=strings.index_byte(line,'"')
                if open<0 {continue}
                path:=line[open+1:]
                path=path[:max(strings.index_byte(path,'"'),0)]
                switch {
                case strings.has_prefix(path,"plugins:"):
                    plugins=true
                    append(&queue,join(root,"plugins",path[len("plugins:"):]))
                case strings.has_prefix(path,"project:"):
                    needs_project=true
                    if owner!="" {append(&queue,join(owner,path[len("project:"):]))}
                }
            }
        }
    }
    list:=make([dynamic]string)
    if plugins && !given(flags,"plugins") {append(&list,fmt.aprintf("-collection:plugins=%s",project.path(root,"plugins")))}
    if needs_project && !given(flags,"project") {
        if owner=="" {
            fmt.eprintfln("mirai: %s imports project: and is not inside a project (no folder above has %s)",folder,project.PROJECT_FILE)
            return nil,false
        }
        append(&list,fmt.aprintf("-collection:project=%s",owner))
    }
    return list[:],true
}

// The project a folder belongs to: the nearest folder at or above it with a
// project.mirai; "" when there is none.
project_of :: proc(folder:string) -> string {
    at:=project.path_absolute(folder,context.temp_allocator)
    for {
        if os.is_file(project.path(at,project.PROJECT_FILE,allocator=context.temp_allocator)) {return strings.clone(at)}
        parent:=os.dir(at)
        if parent==at || parent=="" {return ""}
        at=parent
    }
}

@(private="file")
path_inside :: proc(path,folder:string) -> bool {
    a:=project.path_absolute(path,context.temp_allocator)
    b:=strings.trim_right(project.path_absolute(folder,context.temp_allocator),"/")
    return len(a)>len(b) && a[len(b)]=='/' && path_same(a[:len(b)],b)
}

// The sources of a package of an engine plugin, its tests among them, import
// only the plugins it depends on or its tests depend on (test_dependencies):
// what a test runs against is part of what the plugin declares. False, after
// saying what to declare, for another one.
@(private="file")
test_imports_check :: proc(root,folder:string) -> bool {
    plugins_folder:=join(root,"plugins")
    if !path_inside(folder,plugins_folder) {return true}
    rest:=folder[len(project.path_absolute(plugins_folder,context.temp_allocator))+1:]
    name:=rest
    if slash:=strings.index_byte(rest,'/');slash>=0 {name=rest[:slash]}
    plugins:=make([dynamic]project.Plugin,context.temp_allocator)
    if error:=project.plugins_discover(plugins_folder,.Engine,&plugins,context.temp_allocator);error.code!=.None {return true}
    index,found:=project.plugin_find(plugins[:],name)
    if !found {return true}
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    ok:=true
    for entry in entries {
        if entry.type!=.Regular || !strings.has_suffix(entry.name,".odin") {continue}
        text,read_error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if read_error!=nil {continue}
        tests:=strings.has_suffix(entry.name,"_test.odin")
        rest:=string(text)
        for line in strings.split_lines_iterator(&rest) {
            trimmed:=strings.trim_space(line)
            if !strings.has_prefix(trimmed,"import ") {continue}
            open:=strings.index_byte(trimmed,'"')
            close:=strings.last_index_byte(trimmed,'"')
            if open<0 || close<=open {continue}
            imported:=trimmed[open+1:close]
            other:=project.import_plugin(imported)
            if other=="" || project.plugin_reaches(plugins[:],index,other,tests) {continue}
            fmt.eprintfln("mirai test: %s imports %s, a plugin %s does not depend on; add %q to the %s of its plugin.mirai, or take the import out",entry.fullpath,imported,name,other,tests?"test_dependencies":"dependencies")
            ok=false
        }
    }
    return ok
}
