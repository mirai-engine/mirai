package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/subprocess"

CONTENT_USAGE :: "content [project] [--release] [-- arguments of the tool]"

// The folder of the content tool of a project: its tools/content.
CONTENT_TOOL :: "tools/content"

// mirai content [project] [-- arguments]: builds the content tool of the
// project as its tests build (a Program job: the libraries of the engine and of
// its plugins, its game, the generated world, the attributes and defines of the
// project), unless what it read is as it was, and runs it in the root of the
// project with the arguments after --.
cmd_content :: proc(root:string,args:[]string) -> int {
    given,arguments:=args,[]string{}
    for arg,i in args {
        if arg=="--" {given,arguments=args[:i],args[i+1:];break}
    }
    mode,rest:=build_mode_take(given)
    if code:=positionals_only("content",rest);code!=0 {return code}
    if len(rest)>1 {return argument_unknown("content",rest[1])}
    folder:=len(rest)==1?rest[0]:"."
    owner:=project_of(folder)
    if owner=="" {
        fmt.eprintfln("mirai content: %s is not inside a project (no folder above has %s)",folder,project.PROJECT_FILE)
        return 1
    }
    tool:=join(owner,CONTENT_TOOL)
    if !os.is_dir(tool) {
        fmt.eprintfln("mirai content: %s has no content tool: %s is a package main that writes its assets (mirai docs content-tool)",owner,CONTENT_TOOL)
        return 1
    }
    executable,environment,built:=content_build(root,owner,tool,mode)
    if !built {return 1}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,executable)
    append(&command,..arguments)
    process,error:=subprocess.start({working_dir=owner,command=command[:],env=environment,stdin=os.stdin,stdout=os.stdout,stderr=os.stderr})
    if error!=nil {fmt.eprintfln("mirai content: could not run %s: %v",executable,error);return 127}
    state,wait_error:=subprocess.wait(&process)
    if wait_error!=nil {fmt.eprintfln("mirai content: %s: %v",executable,wait_error);return 127}
    return state.exit_code
}

// Builds the content tool of a project in its turn, after the binaries of the
// engine when they are not current. The turn is let go before the tool runs.
@(private="file")
content_build :: proc(root,owner,tool:string,mode:Build_Mode) -> (executable:string,environment:[]string,ok:bool) {
    opened,error:=project.open(owner,root)
    if error.code!=.None {
        fmt.eprintfln("mirai content: %s",project_error_text(owner,error))
        return
    }
    defer project.close(&opened)
    engine:=build.engine_mode_resolve(root,mode)
    if !project_engine_ready(root,&opened,engine,"content") {return}
    lock:=project_lock(root,fmt.tprintf("content %s",owner),owner,.Editor)
    defer workspace.lock_release(&lock)
    job:=build.job_start({project=&opened,target=.Editor,action=.Program,package_folder=tool,dev=mode==.Dev,engine=engine})
    defer build.job_destroy(job)
    for !build.job_poll(job) {time.sleep(10*time.Millisecond)}
    result:=&job.result
    if compiled:=result.plugins_built-result.plugins_restored-result.plugins_relinked;compiled>0 {fmt.eprintfln("%s: %d plugin libraries built.",build.plugins_libraries_folder(opened.root),compiled)}
    for d in result.diagnostics {fmt.eprintfln("%s(%d:%d) %v: %s",d.file,d.line,d.column,d.severity,d.message)}
    switch result.status {
    case .Built:      fmt.eprintfln("%s ready (%.1f s).",result.output,result.seconds)
    case .Up_To_Date: fmt.eprintfln("%s unchanged.",result.output)
    case .Running:
    case .Failed:
        if result.text!="" {fmt.eprintln(result.text)}
        if result.failure==.Out_Of_Memory {fmt.eprintln(out_of_memory_text("mirai content"))}
        fmt.eprintfln("mirai content: could not build %s (%v)",tool,result.failure)
        return
    }
    return strings.clone(result.output,context.temp_allocator),build.program_environment(job,context.temp_allocator),true
}
