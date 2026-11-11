package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"

// Set for the tool a refresh started, which does not look again.
@(private="file") FRESH_VARIABLE :: "MIRAI_TOOL_FRESH"

// The compilation of the tool: the attributes of the engine mean nothing to it, so it names none
// (the list of the running tool is the one of its own build, and a source newer than it may use
// attributes it lacks) and ignores them all, as the launcher does.
tool_command :: proc(root,package_path,optimization,out,sources:string) -> [dynamic]string {
    command:=odin_command(root,"build",package_path,attributes=false)
    append(&command,"-ignore-unknown-attributes",optimization,fmt.aprintf("-out:%s",out),"-export-dependencies:json",fmt.aprintf("-export-dependencies-file:%s",sources))
    return command
}

// When a source the tool was built from changed after it, builds it again
// and runs the new one with the same arguments, so the launchers only build
// a tool that is missing. What the compiler read is in build_sources_file;
// without it nothing is checked. Invocations at once take turns, and the one
// that waited runs what the other built. When the sources do not compile
// (another one is being edited) the tool there runs, and says so. Messages go
// to stderr: the output of the command is left as it is.
self_refresh :: proc(root:string) -> (code:int,refreshed:bool) {
    // An installed engine has the tool built and not its sources.
    if project.engine_installed(root) {return}
    if _,found:=os.lookup_env(FRESH_VARIABLE,context.temp_allocator);found {return}
    exe,error:=os.get_executable_path(context.allocator)
    if error!=nil {return}
    sources:=build_sources_file(root,"mirai")
    newer,known:=build.sources_newer(sources,exe,root)
    if !known || !newer {return}
    final:=join(root,"bin",fmt.aprintf("mirai%s",project.EXECUTABLE_SUFFIX))
    {
        lock,_:=workspace.lock_acquire(join(root,"bin",".refresh.lock"),fmt.tprintf("pid %d",os.get_pid()))
        defer workspace.lock_release(&lock)
        // Another invocation may have built it while this one waited.
        if newer,known=build.sources_newer(sources,final,root);known && newer {
            fmt.eprintln("mirai: its sources changed; building it again")
            staging:=join(root,"bin",fmt.aprintf(".mirai-build-%d%s",os.get_pid(),project.EXECUTABLE_SUFFIX))
            staged_sources:=fmt.aprintf("%s.sources.json",staging)
            command:=tool_command(root,"tools/mirai","-o:minimal",staging,staged_sources)
            log:=strings.builder_make(context.temp_allocator)
            // After a merge the shader tables of render, which git does not keep, may name shaders
            // that changed: this tool generates them again before a second try.
            if run_logged(root,command[:],&log)!=0 && (!engine_shaders(root) || run_logged(root,command[:],&log)!=0) {
                os.remove(staging);os.remove(staged_sources)
                fmt.eprintln("mirai: the sources of the tool do not build now; the existing one runs. `mirai build tools` shows the error.")
                return
            }
            if !executable_publish(root,staging,final,staged_sources,sources) {return}
        }
    }
    if os.set_env(FRESH_VARIABLE,"1")!=nil {return 1,true}
    again:=make([dynamic]string)
    append(&again,final)
    append(&again,..os.args[1:])
    return run(root,again[:]),true
}
