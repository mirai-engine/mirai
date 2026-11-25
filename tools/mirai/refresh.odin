package main

import "core:fmt"
import "core:os"
import "core:slice"
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
            if run_logged(root,command[:],&log)!=0 {
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
    // Where it was called: the paths of its arguments are relative to it.
    here,_:=os.get_working_directory(context.temp_allocator)
    return run(here,again[:]),true
}

// The packages whose files the tool never reads: render holds the shader
// tables it generates (render/shaders_gen.odin), and host, platform, the
// editor and engine/* reach render or hold test worlds a check writes. A new
// checkout lacks them and a merge leaves them stale until a tool writes them
// again, so the tool builds without them. What render and the cook share is
// in render/abi; a component the cook reads from an asset, by name.
TOOL_UNREAD_PACKAGES :: [?]string{"render","host","platform","editor"}
TOOL_UNREAD_UNDER :: "engine/"

// The first file under root of a package of TOOL_UNREAD_PACKAGES or
// TOOL_UNREAD_UNDER that the build of the tool read (sources_file, as the
// compiler exported it), "" when none.
tool_engine_read :: proc(root,sources_file:string) -> string {
    sources,ok:=build.dependencies_read(sources_file,context.temp_allocator)
    if !ok {return ""}
    prefix:=len(strings.trim_right(root,"/\\"))+1
    unread:=TOOL_UNREAD_PACKAGES
    for source in sources {
        if !path_inside(source,root) {continue}
        file:=source[prefix:]
        folder:=file[:max(strings.last_index_byte(file,'/'),0)]
        if slice.contains(unread[:],folder) || strings.has_prefix(folder,TOOL_UNREAD_UNDER) {return file}
    }
    return ""
}
