package editor

import "core:fmt"
import "core:os"
import "mirai:host"
import "mirai:platform"
import "mirai:project"

// mirai-editor --project <folder> [options]: edits the library editor of a
// project built against the binaries of the engine (mirai edit). frame is
// advance as the program names it, through the table of this library: an
// editor a build left since (engine_take) runs from the next frame.
launch :: proc(args:[]string,frame:proc(s:^Session) -> bool) -> int {
    platform.crash_handler_install()
    root:=host.project_argument(args)
    if report,_:=os.lookup_env(platform.CRASH_REPORT_VARIABLE,context.temp_allocator);report=="" {
        folder:=project.folder_path(root,.Generated,context.temp_allocator)
        // A folder that is already there is the usual case after the first run.
        if error:=os.make_directory_all(folder);error==nil || error==os.General_Error.Exist {
            file:=project.path(folder,"editor-crash.txt",allocator=context.temp_allocator)
            if error:=os.set_env(platform.CRASH_REPORT_VARIABLE,file);error!=nil {fmt.eprintfln("mirai: could not set up the crash report: %v",error)}
            // The events before a fault, which the report copies after the stack.
            events:=project.path(folder,EVENTS_FILE,allocator=context.temp_allocator)
            if error:=os.set_env(platform.CRASH_EVENTS_VARIABLE,events);error!=nil {fmt.eprintfln("mirai: could not set up the events of the crash report: %v",error)}
        } else {fmt.eprintfln("mirai: could not create the crash report folder: %v",error)}
    }
    path:=project.project_library(root,"editor")
    library,error:=host.project_library_load(path,0)
    if error!=.None {
        fmt.eprintfln("mirai: %s",host.library_error_text(error,path))
        return 2
    }
    defer host.project_library_unload(&library)
    return run(&library.info,args,frame)
}
