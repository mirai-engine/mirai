package build

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:project"
import "mirai:std/subprocess"

// The tests of a package run from one executable built with -build-mode:test,
// which stays where test_executable says. It is compiled again only when the
// content of what its last build read changed (fingerprint, with the
// _test.odin files of every folder it read: a build of tests reads them), its
// flags or the compiler, so a checkout that restores the text compiles nothing.
// It runs with the names asked (-tests:) and what it says is read a line at a
// time (Test_Output). mirai test builds the packages of the engine through it,
// from their sources; a Test job, a package of a project against the libraries
// its editor links.

// How long a test may run while no other one starts or ends (test_hung).
TEST_TIMEOUT :: 120*time.Second

// The stack each thread of a test executable reserves. Windows gives 1 MB, a tenth of what the
// editor tests that keep a Session, an App and a UI context on the stack can come near; Linux and
// macOS give 8 MB.
TEST_STACK_FLAG :: "-extra-linker-flags:/STACK:8388608" when ODIN_OS==.Windows else ""

// How a test executable runs.
Test_Options :: struct {
    names:[]string,               // the tests, by name; empty: all of them
    timeout:time.Duration,        // test_hung; 0 does not watch
    quiet:bool,                   // only failures, warnings and the summary are shown
    priority:subprocess.Priority,
}

// What the tests of a run did.
Test_Report :: struct {
    compiled:bool,
    total,passed:int,
    failed:[]Test_Failure,
}

Test_Failure :: struct {
    package_name,name:string,
    messages:[]string, // what the test logged at error level and above, with where
}

// The build of the test executable of a package. Everything it points to is of allocator.
Test_Build :: struct {
    allocator:runtime.Allocator,
    root,compiler,executable:string,
    flags:[]string,                // what identifies the build besides its sources and the compiler
    command:[]string,              // of the compiler; none when the executable there stands
    staging,sources_staged,log:string,
    states_added,states_seen:bool, // test_states_asked of the flags
    started:time.Time,
    process:os.Process,
    running,failed:bool,
    code:int,                      // of a compiler that failed; -1 when it did not run
    diagnostics:[]Diagnostic,
    said:string,                   // by the compiler besides its diagnostics, or why it did not build
}

// A run of a test executable. Everything it points to is of allocator.
Test_Run :: struct {
    allocator:runtime.Allocator,
    output:Test_Output,
    path:string,           // the package as the notes of the runner name it
    timeout:time.Duration,
    process:os.Process,
    reader:^os.File,
    pending:[dynamic]u8,
    lines:[dynamic]string, // what it said to show and the notes of the runner, oldest first: the caller may take them
    running,open,exited:bool,
    exit_code:int,         // -1 when it did not start, could not be waited for or was killed
}

// Where the test executable of a package stays: in folder, named after the
// path of the package under root, or after its name and a hash of its path
// when it lies outside.
test_executable :: proc(folder,root,package_folder:string,allocator:=context.allocator) -> string {
    at:=project.path_absolute(package_folder,context.temp_allocator)
    under:=strings.trim_right(project.path_absolute(root,context.temp_allocator),"/")
    name:string
    if len(at)>len(under) && at[len(under)]=='/' && project.path_same(at[:len(under)],under) {
        name,_=strings.replace_all(at[len(under)+1:],"/","_",context.temp_allocator)
    } else {
        name=fmt.tprintf("%s-%x",at[strings.last_index_byte(at,'/')+1:],u32(xxhash.XXH3_64_default(transmute([]u8)at)))
    }
    return project.path(folder,strings.concatenate({name,project.EXECUTABLE_SUFFIX},context.temp_allocator),allocator=allocator)
}

// Where the test executables of the packages of a project stay.
project_tests_folder :: proc(project_root:string,allocator:=context.allocator) -> string {
    return project.path(project.folder_path(project_root,.Generated,context.temp_allocator),"build","tests",allocator=allocator)
}

// The flag that gives the threads of a test executable the stack of the system with the most:
// none when the flags already pass linker flags of their own.
test_link_flag :: proc(flags:[]string) -> string {
    for flag in flags {if strings.has_prefix(flag,"-extra-linker-flags:") {return ""}}
    return TEST_STACK_FLAG
}

// Whether the flags let the runner see when each test starts and ends: added,
// when it asks core:testing for it (ODIN_TEST_LOG_STATE_CHANGES) because no
// flag does; seen, unless a flag turns it off or logs less than info.
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

// What compiling the tests of the package in folder takes: no command when
// the executable there was built from what is there now. root: the engine,
// what paths count relative to; flags: those after the package, the
// collections among them.
test_build_plan :: proc(root,compiler,folder,executable:string,flags:[]string,allocator:=context.allocator) -> (b:Test_Build) {
    context.allocator=allocator
    b.allocator=allocator
    b.root,b.compiler,b.executable=slashes(root,allocator),slashes(compiler,allocator),slashes(executable,allocator)
    identity:=make([dynamic]string)
    append(&identity,"build",slashes(folder,allocator),"-build-mode:test")
    for flag in flags {append(&identity,strings.clone(flag))}
    if stack:=test_link_flag(flags);stack!="" {append(&identity,stack)}
    b.states_added,b.states_seen=test_states_asked(flags)
    if b.states_added {append(&identity,"-define:ODIN_TEST_LOG_STATE_CHANGES=true")}
    b.flags=identity[:]
    if test_build_current(&b) {return}
    slash:=strings.last_index_byte(b.executable,'/')
    stem:=strings.trim_suffix(b.executable[slash+1:],project.EXECUTABLE_SUFFIX)
    b.staging=fmt.aprintf("%s/.%s-build-%d%s",b.executable[:max(slash,0)],stem,os.get_pid(),project.EXECUTABLE_SUFFIX)
    b.sources_staged=test_sources_file(b.staging)
    b.log=fmt.aprintf("%s.log",b.staging)
    command:=make([dynamic]string)
    append(&command,b.compiler)
    append(&command,..b.flags)
    append(&command,fmt.aprintf("-out:%s",b.staging),"-json-errors","-export-dependencies:json",fmt.aprintf("-export-dependencies-file:%s",b.sources_staged))
    b.command=command[:]
    return
}

// What the compiler read to build a test executable, and the fingerprint of it.
@(private)
test_sources_file :: proc(executable:string) -> string {return fmt.aprintf("%s.sources.json",executable)}

@(private)
test_stamp_file :: proc(executable:string) -> string {return fmt.tprintf("%s.build",executable)}

// Whether the executable there was built from the content there is now.
@(private)
test_build_current :: proc(b:^Test_Build) -> bool {
    if !os.is_file(b.executable) {return false}
    saved,_,stamped:=stamp_read(test_stamp_file(b.executable))
    sources,listed:=dependencies_read(test_sources_file(b.executable),context.temp_allocator)
    if !stamped || !listed {return false}
    hash,_:=fingerprint(b.root,b.compiler,b.flags,sources,tests=true)
    return hash==saved
}

// Starts the compiler of a test executable that needs one, within what it may
// use (compiler_limits), with what it says going to its log. environment: of
// the compiler; nil, the one of this process. false, with why in said, when it
// does not start.
test_build_start :: proc(b:^Test_Build,environment:[]string=nil) -> bool {
    if len(b.command)==0 {return true}
    context.allocator=b.allocator
    folder:=b.executable[:max(strings.last_index_byte(b.executable,'/'),0)]
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {
        b.failed,b.code,b.said=true,-1,fmt.aprintf("could not make %s",folder)
        return false
    }
    log,error:=os.open(b.log,{.Write,.Create,.Trunc})
    if error!=nil {
        b.failed,b.code,b.said=true,-1,fmt.aprintf("could not write %s: %v",b.log,error)
        return false
    }
    b.started=time.now()
    b.process,error=subprocess.start({working_dir=b.root,command=b.command,env=environment,stdout=log,stderr=log},compiler_limits(b.root))
    os.close(log)
    if error!=nil {
        _=os.remove(b.log)
        b.failed,b.code,b.said=true,-1,fmt.aprintf("could not run %s: %v",b.compiler,error)
        return false
    }
    b.running=true
    return true
}

// Waits at most wait for the compiler of a test executable. True once it
// ended, or when there was none: the executable stands, published with its
// fingerprint, unless failed says it was not built.
test_build_poll :: proc(b:^Test_Build,wait:time.Duration=0) -> bool {
    if !b.running {return true}
    state,error:=os.process_wait(b.process,wait)
    if error==os.General_Error.Timeout || (error==nil && !state.exited) {return false}
    b.running=false
    context.allocator=b.allocator
    data,_:=os.read_entire_file(b.log,context.temp_allocator)
    _=os.remove(b.log)
    b.diagnostics,b.said=diagnostics_parse(string(data),b.allocator)
    errors:=false
    for d in b.diagnostics {errors||=d.severity==.Error}
    switch {
    case error!=nil:
        b.failed,b.code,b.said=true,-1,fmt.aprintf("%s: %v",b.compiler,error)
    case state.exit_code!=0 || errors:
        b.failed,b.code=true,state.exit_code
    case !test_build_publish(b):
        b.failed,b.code=true,0
    }
    if b.failed {
        _=os.remove(b.staging)
        _=os.remove(b.sources_staged)
    }
    return true
}

// Stops the compiler of a test executable; the executable of before stands.
test_build_cancel :: proc(b:^Test_Build) {
    if !b.running {return}
    _=os.process_kill(b.process)
    _,_=os.process_wait(b.process)
    b.running=false
    for file in ([3]string{b.log,b.staging,b.sources_staged}) {_=os.remove(file)}
}

// Puts what the compiler wrote in place of the executable, which a running
// one on Windows is not but may be renamed out of the way, and stamps it with
// the fingerprint of what the compiler read. A source saved while it compiled
// is not what was built: without the stamp the next build compiles again.
@(private)
test_build_publish :: proc(b:^Test_Build) -> bool {
    if !os.is_file(b.staging) {
        b.said=fmt.aprintf("the compiler succeeded and %s is missing%s",b.staging,ODIN_OS==.Windows?"; an antivirus may have quarantined it: exclude its folder from real-time scanning":"")
        return false
    }
    slash:=strings.last_index_byte(b.executable,'/')
    folder,name:=b.executable[:max(slash,0)],b.executable[slash+1:]
    if entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator);error==nil {
        for entry in entries {
            if strings.has_prefix(entry.name,name) && strings.has_suffix(entry.name,".old") {_=os.remove(entry.fullpath)}
        }
    }
    if os.rename(b.staging,b.executable)!=nil {
        retired:=fmt.tprintf("%s.%d.old",b.executable,os.get_pid())
        if os.rename(b.executable,retired)!=nil || os.rename(b.staging,b.executable)!=nil {
            b.said=fmt.aprintf("could not replace %s",b.executable)
            return false
        }
    }
    stamp:=test_stamp_file(b.executable)
    sources_file:=test_sources_file(b.executable)
    sources,listed:=dependencies_read(b.sources_staged,context.temp_allocator)
    hash,latest:=fingerprint(b.root,b.compiler,b.flags,sources,tests=true)
    _=os.remove(sources_file)
    stamped:=listed && time.diff(latest,b.started)>0 && os.rename(b.sources_staged,sources_file)==nil
    if stamped {stamped=os.write_entire_file(stamp,fmt.tprintf("%x",hash))==nil}
    if !stamped {
        _=os.remove(stamp)
        _=os.remove(b.sources_staged)
    }
    return true
}

// Starts the executable b left, with the tests of options and environment (nil:
// that of this process). It runs in the root of the engine b was planned with,
// whatever package it tests, so a relative path in a test is relative to the
// engine. path names the package in the notes of the runner. false, with why
// in lines, when it does not start.
test_run_start :: proc(r:^Test_Run,b:^Test_Build,path:string,options:Test_Options,environment:[]string=nil,allocator:=context.allocator) -> bool {
    r^={allocator=allocator,exit_code=-1}
    context.allocator=allocator
    r.path=strings.clone(path)
    r.output={quiet=options.quiet,states_hidden=b.states_added,finished=-1,running=make(map[string]time.Tick)}
    r.timeout=options.timeout if b.states_seen else 0
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,b.executable)
    if len(options.names)>0 {append(&command,fmt.tprintf("-tests:%s",strings.join(options.names,",",context.temp_allocator)))}
    reader,writer,pipe_error:=os.pipe()
    if pipe_error!=nil {
        append(&r.lines,fmt.aprintf("%s: could not create a pipe: %v",r.path,pipe_error))
        return false
    }
    process,error:=subprocess.start({working_dir=b.root,command=command[:],env=environment,stdout=writer,stderr=writer},{priority=options.priority})
    os.close(writer)
    if error!=nil {
        os.close(reader)
        append(&r.lines,fmt.aprintf("%s: could not run %s: %v",r.path,b.executable,error))
        return false
    }
    r.process,r.reader=process,reader
    r.running,r.open=true,true
    r.output.changed=time.tick_now()
    return true
}

// Reads what the executable said since the last call and waits at most wait
// for it to end. True once it ended, or was killed because it hung
// (test_hung): its tests that ran then count as failed.
test_run_poll :: proc(r:^Test_Run,wait:time.Duration=0) -> bool {
    if !r.running {return true}
    context.allocator=r.allocator
    test_run_read(r)
    if !r.exited {
        state,error:=os.process_wait(r.process,0 if r.open else wait)
        switch {
        case error==nil && state.exited:
            r.exited,r.exit_code=true,state.exit_code
            // What it wrote before it ended; a child of it may keep the pipe open.
            test_run_read(r)
        case error!=nil && error!=os.General_Error.Timeout:
            append(&r.lines,fmt.aprintf("%s: the test executable could not be waited for: %v",r.path,error))
            r.exited=true
        case test_hung(r.output,r.timeout,time.tick_now()):
            _=os.process_kill(r.process)
            _,_=os.process_wait(r.process)
            r.exited=true
            if len(r.pending)>0 {test_run_feed(r,{'\n'})}
            test_hung_say(r)
        case:
            if r.open && wait>0 {time.sleep(min(wait,5*time.Millisecond))}
            return false
        }
    }
    if len(r.pending)>0 {test_run_feed(r,{'\n'})}
    if r.exit_code!=0 && !r.output.summary && !r.output.hung {test_crash_say(r)}
    os.close(r.reader)
    r.running=false
    return true
}

// Kills a run that did not end.
test_run_cancel :: proc(r:^Test_Run) {
    if !r.running {return}
    if !r.exited {
        _=os.process_kill(r.process)
        _,_=os.process_wait(r.process)
    }
    os.close(r.reader)
    r.running=false
}

// What the tests of a run that ended did. ok: they all ran and passed.
test_run_report :: proc(r:^Test_Run,allocator:=context.allocator) -> (report:Test_Report,ok:bool) {
    out:=&r.output
    report.compiled=true
    report.total=out.finished if out.finished>=0 else out.started
    failed:=make([dynamic]Test_Failure,allocator)
    for name in out.failed {
        dot:=strings.last_index_byte(name,'.')
        append(&failed,Test_Failure{strings.clone(name[:max(dot,0)],allocator),strings.clone(test_bare(name),allocator),test_messages(out,name,allocator)})
    }
    report.failed=failed[:]
    report.passed=max(report.total-len(failed),0)
    return report,r.exit_code==0 && len(failed)==0 && !out.hung
}

// What is ready in the pipe, a bounded amount per call.
@(private="file")
test_run_read :: proc(r:^Test_Run) {
    buffer:[16384]u8
    for _ in 0..<64 {
        if !r.open {return}
        ready,ready_error:=os.pipe_has_data(r.reader)
        if ready_error!=nil {r.open=false;return}
        if !ready {return}
        count,read_error:=os.read(r.reader,buffer[:])
        if count>0 {test_run_feed(r,buffer[:count])}
        if read_error!=nil {r.open=false}
    }
}

@(private="file")
test_run_feed :: proc(r:^Test_Run,data:[]u8) {
    append(&r.pending,..data)
    start:=0
    for i in 0..<len(r.pending) {
        if r.pending[i]!='\n' {continue}
        if text,show:=test_output_line(&r.output,string(r.pending[start:i]),time.tick_now());show {append(&r.lines,strings.clone(text))}
        start=i+1
    }
    remove_range(&r.pending,0,start)
}

// Says that the executable ended before its summary, with the tests that ran.
@(private="file")
test_crash_say :: proc(r:^Test_Run) {
    names:=test_running_failed(&r.output)
    if len(names)>0 {
        append(&r.lines,fmt.aprintf("%s: the executable crashed (code 0x%X) while %s %s",r.path,u32(r.exit_code),len(names)==1?"this one ran:":"these ran:",strings.join(names,", ",context.temp_allocator)))
    } else {
        append(&r.lines,fmt.aprintf("%s: the executable crashed (code 0x%X) before saying which test ran",r.path,u32(r.exit_code)))
    }
}

// Says why the executable was killed, and counts the tests that ran as failed.
@(private="file")
test_hung_say :: proc(r:^Test_Run) {
    out:=&r.output
    out.hung=true
    names:=test_running_failed(out)
    seconds:=time.duration_seconds(r.timeout)
    text:string
    switch {
    case len(names)>0:
        text=fmt.aprintf("%s: %s %s more than %.0f s and no other test started or ended in that time; the executable was killed (--timeout S changes the limit)",
            r.path,strings.join(names,", ",context.temp_allocator),len(names)==1?"has run for":"have run for",seconds)
    case out.summary:
        text=fmt.aprintf("%s: the executable kept running %.0f s after its tests ended; it was killed",r.path,seconds)
    case out.started==0:
        text=fmt.aprintf("%s: the executable started no test in %.0f s; it was killed",r.path,seconds)
    case:
        text=fmt.aprintf("%s: no test started or ended in %.0f s; the executable was killed",r.path,seconds)
    }
    append(&r.lines,text)
}
