package main

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"

TEST_USAGE :: "test <package> [test|file.odin...] [<package>...] [--no-gpu] [--failed] [--quiet] [--timeout S] [--release] [-flag...]"
TEST_LIST_USAGE :: "test <package> [file.odin...] --list [--no-gpu]"

// A package of a call to mirai test and what is asked of it: tests by their
// names and by the files that declare them; neither is all of it. nothing:
// there is no test of it to run, so it is not built. owner: the project it
// belongs to; empty for a package of the engine.
Test_Package :: struct {path,folder,owner:string,names,files:[dynamic]string,nothing:bool}

// What compiling and running the tests took. turn: waiting for other
// compilations. built, current: test executables compiled, and found as their
// sources are.
@(private="file")
Test_Times :: struct {build,turn,run:time.Duration,built,current:int}

// mirai test: the tests of one package or of several, each from its test
// executable (build.test_build_plan), compiled only when the content of what
// it was built from changed. Those of the engine compile from their sources,
// several at once (test_builds_run), and then run one after another in the
// order asked, without the implicit layers of Vulkan (layers_isolate); one
// that was not built does not stop the others. A package of a project builds
// and runs in its turn as build.test does: against the libraries its editor
// links (test_project_run). The names of tests go to the runner (-tests:), so
// asking for others compiles nothing; a name the sources do not declare stops
// the command before it compiles. An argument that is a folder of the engine,
// or a path to one, is a package; the others are tests of the package before
// them, or files of it whose tests are asked; --no-gpu leaves out the tests of
// the files that reach the device of the GPU tests; --release and the flags
// are for all of them. The collections plugins and project a package of the
// engine reaches are passed unless a flag already names them.
cmd_test :: proc(root:string,args:[]string) -> int {
    packages:=make([dynamic]Test_Package)
    flags:=make([dynamic]string)
    release,list,failed_only,quiet,no_gpu:=false,false,false,false,false
    timeout:=build.TEST_TIMEOUT
    timeout_given:=false
    for i:=0;i<len(args);i+=1 {
        arg:=args[i]
        switch {
        case arg=="--release":  release=true
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
    for &p in packages {p.owner=project_of(p.folder)}
    if list {return test_list(packages[:],no_gpu)}
    // The tests that build something (cook/image, asset, the importer) run the
    // compiler this run builds the suites with: MIRAI_ODIN names it, as
    // MIRAI_ROOT names the engine, so Odin needs no place in PATH.
    compiler:=odin_executable(root)
    _=os.set_env("MIRAI_ODIN",compiler)
    if !test_names_check(root,packages[:],failed_only,no_gpu) {return 2}
    benchmark:=benchmark_asked(flags[:])
    // A benchmark may take long: only --timeout bounds it.
    if benchmark && !timeout_given {timeout=0}

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
    builds:=make([]build.Test_Build,len(packages))
    for p,i in packages {
        if p.nothing || p.owner!="" {continue}
        files:=package_parse(p.folder)
        package_flags,ok:=test_flags(root,p.folder,files,release,flags[:])
        if !ok || !test_imports_check(root,p.folder,files) || !package_test_shaders(root,p.folder) {
            builds[i].failure=.Generate
            continue
        }
        builds[i]=build.test_build_plan(root,compiler,p.folder,test_executable(root,p),package_flags)
    }
    test_builds_run(root,packages[:],builds,&times)
    times.build+=time.tick_since(prepared)
    layers_isolate(root)
    failed:=make([dynamic]string)
    for &p,i in packages {
        if p.nothing {continue}
        if len(packages)>1 {fmt.printfln("== %s",p.path)}
        options:=build.Test_Options{names=p.names[:],timeout=timeout,quiet=quiet}
        lock,measuring:=test_measure_begin(root,p.path,benchmark,&options)
        ran:=time.tick_now()
        ok:bool
        names:[]string
        if p.owner!="" {
            ok,names=test_project_run(root,p,release,flags[:],options,&times)
        } else if test_build_say(p.path,builds[i]) {
            ok,names=test_execute(root,p.path,&builds[i],options)
        } else {
            test_measure_end(&lock,measuring)
            append(&failed,p.path)
            continue
        }
        times.run+=time.tick_since(ran)
        test_measure_end(&lock,measuring)
        // A run that ended badly without naming a failed test leaves the list of before.
        if ok || len(names)>0 {test_failed_save(test_executable(root,p),p.names[:],names)}
        if len(names)>0 {fmt.eprintfln("mirai test: to run only the ones that failed: mirai test %s --failed",p.path)}
        if !ok {append(&failed,p.path)}
    }
    if pending>1 {
        if len(failed)==0 {fmt.printfln("mirai test: %d packages, all pass",pending)}
        else {fmt.eprintfln("mirai test: %d of %d packages fail: %s",len(failed),pending,strings.join(failed[:],", "))}
    }
    turn:=""
    if times.turn>=100*time.Millisecond {turn=fmt.tprintf(" (%.1f s waiting for the turn)",time.duration_seconds(times.turn))}
    fmt.eprintfln("mirai test: %d test executables built and %d unchanged; build %.1f s%s, run %.1f s",times.built,times.current,time.duration_seconds(times.build),turn,time.duration_seconds(times.run))
    return len(failed)>0?1:0
}

// The flags of the test build of a package of the engine after the package:
// those of every build of the tool, the optimization, the collections it
// reaches and those of the call. ok is false, after saying why, when the
// collections cannot be told.
@(private="file")
test_flags :: proc(root,folder:string,files:[]^ast.File,release:bool,flags:[]string) -> (list:[]string,ok:bool) {
    command:=odin_command(root,"build",folder)
    append(&command,release?"-o:speed":"-o:minimal")
    collections:=package_collections(root,folder,files,flags) or_return
    append(&command,..collections)
    append(&command,..flags)
    return command[3:],true
}

// The executable of the tests of a package: in bin/tests for one of the
// engine, in the build folder of its project for one of a project, where a
// Test job leaves it.
@(private="file")
test_executable :: proc(root:string,p:Test_Package) -> string {
    if p.owner!="" {return build.test_executable(build.project_tests_folder(p.owner,context.temp_allocator),p.owner,p.folder)}
    return build.test_executable(join(root,"bin","tests"),root,p.folder)
}

// A benchmark is a measurement: it runs alone among the checkouts
// (measure_lock), with this process part of it. Tests that are no benchmark
// do not wait for one: while one runs they run at low priority.
@(private="file")
test_measure_begin :: proc(root,path:string,benchmark:bool,options:^build.Test_Options) -> (lock:workspace.Lock,measuring:bool) {
    if !benchmark || workspace.measuring() {
        if measured,measurer:=workspace.measurement_running(root,context.temp_allocator);measured {
            fmt.eprintfln("mirai test: a measurement is running (%s); the tests run at low priority",measurer!=""?measurer:"another process")
            options.priority=.Low
        }
        return
    }
    lock=measure_lock(root,fmt.tprintf("test %s",path))
    _=os.set_env(workspace.MEASURE_ENV,fmt.tprintf("%d",os.get_pid()))
    return lock,true
}

@(private="file")
test_measure_end :: proc(lock:^workspace.Lock,measuring:bool) {
    if !measuring {return}
    os.unset_env(workspace.MEASURE_ENV)
    workspace.lock_release(lock)
}

// Runs a test executable of the engine and shows what it says as it comes.
// failed: the tests that failed, without their package.
@(private="file")
test_execute :: proc(root,path:string,b:^build.Test_Build,options:build.Test_Options) -> (ok:bool,failed:[]string) {
    r:build.Test_Run
    if !build.test_run_start(&r,b,path,options) {
        test_lines_show(&r)
        return
    }
    for !build.test_run_poll(&r,50*time.Millisecond) {test_lines_show(&r)}
    test_lines_show(&r)
    _,ok=build.test_run_report(&r,context.temp_allocator)
    return ok,test_failed_bare(r.output.failed[:])
}

@(private="file")
test_lines_show :: proc(r:^build.Test_Run) {
    for line in r.lines {fmt.eprintln(line)}
    clear(&r.lines)
}

@(private="file")
test_failed_bare :: proc(names:[]string) -> []string {
    bare:=make([dynamic]string,context.temp_allocator)
    for name in names {append(&bare,build.test_bare(name))}
    return bare[:]
}

// Builds and runs the tests of a package of a project as build.test does: a
// Test job of its editor, whose executable compiles against the libraries the
// editor links, after the binaries of the engine when their sources changed.
// The turn of the compilations is held until the executable runs.
@(private="file")
test_project_run :: proc(root:string,p:Test_Package,release:bool,flags:[]string,options:build.Test_Options,times:^Test_Times) -> (ok:bool,failed:[]string) {
    mode:=Build_Mode.Release if release else .Dev
    asked:=time.tick_now()
    lock:=build_lock(root,fmt.tprintf("test %s",p.path),{p.owner})
    locked:=true
    defer if locked {workspace.lock_release(&lock)}
    times.turn+=time.tick_since(asked)
    opened,error:=project.open(p.owner,root)
    if error.code!=.None {
        fmt.eprintfln("mirai test: %s",project_error_text(p.owner,error))
        return
    }
    defer project.close(&opened)
    if engine:=build.project_engine(&opened,mode,context.temp_allocator);!c_libraries_current(root) || !build.engine_current(root,mode,engine.defines) {
        if !ensure_runtime_dependencies(root) {return}
        if engine_report(build.engine_build({engine_root=root,mode=mode,defines=engine.defines}),root,os.stderr)!=0 {return}
    }
    job:=build.job_start({project=&opened,target=.Editor,action=.Test,test_package=p.folder,test=options,flags=flags,dev=!release,engine=mode})
    defer build.job_destroy(job)
    for !build.job_poll(job) {
        test_lines_show(&job.test_run)
        if locked && job.test_run.running {
            workspace.lock_release(&lock)
            locked=false
        }
        time.sleep(10*time.Millisecond)
    }
    test_lines_show(&job.test_run)
    result:=&job.result
    if job.testing {
        if len(job.test_build.command)>0 {times.built+=1} else {times.current+=1}
    }
    if compiled:=result.plugins_built-result.plugins_restored-result.plugins_relinked;compiled>0 {fmt.eprintfln("%s: %d plugin libraries built.",build.plugins_libraries_folder(opened.root),compiled)}
    for d in result.diagnostics {fmt.eprintfln("%s(%d:%d) %v: %s",d.file,d.line,d.column,d.severity,d.message)}
    switch {
    case result.status==.Built:
    case result.failure==.Tests:
    case result.failure==.Compile || result.failure==.Out_Of_Memory:
        if result.text!="" {fmt.eprintln(result.text)}
        if result.failure==.Out_Of_Memory {fmt.eprintln(out_of_memory_text("mirai test"))}
        fmt.eprintfln("mirai test: could not build %s",p.path)
    case:
        if result.text!="" {fmt.eprintln(result.text)}
        fmt.eprintfln("mirai test: could not build %s (%v)",p.path,result.failure)
    }
    return result.status==.Built,test_failed_bare(job.test_run.output.failed[:])
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
    for name in asked {append(&bare,build.test_bare(name))}
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
        if n==0 || !project.path_same(packages[n-1].folder,folder) {
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
// the device of the GPU tests leave. A package left with no test to run is
// named and marked (nothing): the compiler does not link a test executable
// without tests.
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
                if !project.path_same(test.file,file) {continue}
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
            last:=test_failed_load(test_executable(root,p))
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
            name:=build.test_bare(asked)
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
        if len(names)==0 && len(p.names)==0 && !p.nothing {
            p.nothing=true
            fmt.printfln("mirai test: %s declares no test%s; there is nothing to build or run",p.path,len(declared)>0?" that builds on this system":"")
        }
        device:=test_device_files(declared[:])
        if len(device)==0 || p.nothing {continue}
        asked:=make(map[string]bool,context.temp_allocator)
        for name in p.names {asked[build.test_bare(name)]=true}
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

// Compiles the test executables of the engine that have a command, as many
// at once as a build runs compilers (build.compilers_at_once), in the order
// asked and within one turn of the compilations: together they are one build
// of this checkout. One that fails leaves the executable of before in place.
@(private="file")
test_builds_run :: proc(root:string,packages:[]Test_Package,builds:[]build.Test_Build,times:^Test_Times) {
    waiting:=make([dynamic]int,context.temp_allocator)
    paths:=make([dynamic]string,context.temp_allocator)
    for planned,i in builds {
        if packages[i].nothing || packages[i].owner!="" || planned.failure!=.None {continue}
        if len(planned.command)==0 {
            times.current+=1
            continue
        }
        append(&waiting,i)
        append(&paths,packages[i].path)
    }
    if len(waiting)==0 {return}
    times.built+=len(waiting)
    limit:=build.compilers_at_once()
    if len(waiting)>1 {fmt.eprintfln("mirai test: building %d packages, %d at once",len(waiting),min(limit,len(waiting)))}
    asked:=time.tick_now()
    lock:=build_lock(root,fmt.tprintf("test %s",strings.join(paths[:]," ",context.temp_allocator)))
    defer workspace.lock_release(&lock)
    times.turn+=time.tick_since(asked)
    running:=make([dynamic]int,context.temp_allocator)
    for len(waiting)>0 || len(running)>0 {
        for len(waiting)>0 && len(running)<limit {
            if build.test_build_start(&builds[waiting[0]]) {append(&running,waiting[0])}
            ordered_remove(&waiting,0)
        }
        ended:=false
        for i:=0;i<len(running); {
            if !build.test_build_poll(&builds[running[i]]) {
                i+=1
                continue
            }
            ordered_remove(&running,i)
            ended=true
        }
        if !ended {time.sleep(10*time.Millisecond)}
    }
}

// Shows, in the turn of a package, what the compiler of its test executable
// said. false, after saying that it was not built, when there is none to run.
@(private="file")
test_build_say :: proc(path:string,b:build.Test_Build) -> bool {
    for d in b.diagnostics {fmt.eprintfln("%s(%d:%d) %v: %s",d.file,d.line,d.column,d.severity,d.message)}
    if said:=strings.trim_right_space(b.said);said!="" {fmt.eprintln(said)}
    if b.failure==.None {return true}
    if b.failure==.Out_Of_Memory {fmt.eprintln(out_of_memory_text("mirai test"))}
    fmt.eprintfln("mirai test: could not build %s",path)
    return false
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

// The collections a package reaches besides mirai: plugins when it, or a
// package it imports through plugins or project, imports "plugins:"; project,
// the nearest folder above it with a project.mirai, when one imports
// "project:". files: those of folder, parsed. A flag that names one already is left as it is.
package_collections :: proc(root,folder:string,files:[]^ast.File,flags:[]string) -> (collections:[]string,ok:bool) {
    given :: proc(flags:[]string,name:string) -> bool {
        for flag in flags {
            if strings.has_prefix(flag,fmt.tprintf("-collection:%s=",name)) {return true}
        }
        return false
    }
    owner:=project_of(folder)
    plugins,needs_project:=false,false
    seen:=make(map[string]bool,context.temp_allocator)
    seen[folder]=true
    queue:=make([dynamic][]^ast.File,context.temp_allocator)
    append(&queue,files)
    for len(queue)>0 {
        for file in pop(&queue) {
            for decl in file.imports {
                path:=strings.trim(decl.fullpath,"\"`")
                next:string
                switch {
                case strings.has_prefix(path,"plugins:"):
                    plugins=true
                    next=join(root,"plugins",path[len("plugins:"):])
                case strings.has_prefix(path,"project:"):
                    needs_project=true
                    if owner!="" {next=join(owner,path[len("project:"):])}
                }
                if next=="" || seen[next] {continue}
                seen[next]=true
                append(&queue,package_parse(next))
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

// The sources of a package of an engine plugin, its tests among them, import
// only the plugins it depends on or its tests depend on (test_dependencies):
// what a test runs against is part of what the plugin declares. False, after
// saying what to declare, for another one. files: those of folder, parsed.
@(private="file")
test_imports_check :: proc(root,folder:string,files:[]^ast.File) -> bool {
    plugins_folder:=project.path_absolute(join(root,"plugins"),context.temp_allocator)
    if !path_inside(folder,plugins_folder) {return true}
    rest:=folder[len(plugins_folder)+1:]
    name:=rest
    if slash:=strings.index_byte(rest,'/');slash>=0 {name=rest[:slash]}
    plugins:=make([dynamic]project.Plugin,context.temp_allocator)
    if error:=project.plugins_discover(plugins_folder,.Engine,&plugins,context.temp_allocator);error.code!=.None {return true}
    index,found:=project.plugin_find(plugins[:],name)
    if !found {return true}
    errors:=make([dynamic]string,context.temp_allocator)
    build.plugin_imports_check(plugins[:],index,files,&errors)
    for e in errors {fmt.eprintfln("mirai test: %s",e)}
    return len(errors)==0
}
