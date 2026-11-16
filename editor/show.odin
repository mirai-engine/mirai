package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:editor/api"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/serial"
import "mirai:std/subprocess"

// Opening the editor on a project whose headless editor a session runs, with
// the binaries beside this one (same folder, so same worktree and build mode),
// gives that editor a window instead of starting a second one: the user sees
// what the agent does, and the agent keeps its connection.

// How long the editor that opens waits for the session to take the window: it
// answers between the calls of its agent.
@(private)
SHOW_WAIT_MS :: 60_000

// What open does on a project: open itself (.None), leave it to the session
// that took the window (.Shown) or end because the session did not answer
// (.Busy), since a second editor would take its port file from its agent.
@(private)
Session_Show :: enum u8 {None,Shown,Busy}

@(private)
session_show :: proc(root:string) -> Session_Show {
    data,error:=os.read_entire_file(project.path(root,".mirai",api.PORT_FILE,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return .None}
    file:api.Port_File
    if serial.text_decode(string(data),&file,context.temp_allocator)!="" || !file.manual || file.port<=0 || !subprocess.process_alive(file.pid) {return .None}
    program,_:=os.get_executable_path(context.temp_allocator)
    program,_=strings.replace_all(program,"\\","/",context.temp_allocator)
    if !project.path_same(file.engine,program[:max(strings.last_index_byte(program,'/'),0)]) {return .None}
    platform.window_foreground_allow(file.pid)
    _,call_error,called:=api.rpc_call(file.port,"editor.show","{}",1,SHOW_WAIT_MS,context.temp_allocator)
    if !called {
        fmt.eprintfln("mirai: the project is open in the headless editor of a session (pid %d), which did not take the window: %s. Try again once its agent's call ends, or close it with mirai session stop %s",file.pid,call_error.message,root)
        return .Busy
    }
    fmt.eprintfln("mirai: the project was open in the headless editor of a session (pid %d): it now has the window",file.pid)
    return .Shown
}

Api_Show_Result :: struct {
    shown:bool `mirai:"label=The editor has a window now; false when it already had one"`,
}

// Gives a headless editor the window of the user: real-time frames, the
// preferences of the editor and the arguments a restart takes. Its methods and
// the calls of its agent go on; engine.step and editor.input end with manual
// execution.
@(private)
api_show :: proc(s:^Session,call:^api.Call) {
    if !s.headless {
        api.call_result(call,Api_Show_Result).shown=false
        return
    }
    if s.app.renderer==nil {
        api.call_fail(call,api.SERVER_ERROR,"This headless editor runs without a GPU (--no-gpu), so a window would show nothing; close it with mirai session stop and open the editor")
        return
    }
    if platform.dialog_pending(s.app.platform) {
        api.call_fail(call,api.SERVER_ERROR,"A file dialog of the agent is open; answer it with editor.dialog first")
        return
    }
    window:=platform.Window_Desc{chrome=.Custom,maximized=true}
    if error:=host.app_window_open(s.app,window);error!=.None {
        api.call_fail(call,api.SERVER_ERROR,api_error_text(call,"The window could not open (%v); the editor goes on headless",error))
        return
    }
    s.headless=false
    if st:=api_state(s);st!=nil {st.manual=false}
    restart_args_windowed(s)
    if s.preferences.file=="" {preferences_open(s,{})}
    if s.has_project {projects_remember(s)}
    api_port_file_refresh(s)
    api.call_result(call,Api_Show_Result).shown=true
}

// What a restart passes on drops what made the editor headless.
@(private)
restart_args_windowed :: proc(s:^Session) {
    kept:=0
    for i:=0;i<len(s.args);i+=1 {
        switch s.args[i] {
        case "--headless","--hidden","--preferences","--no-gpu":
            delete(s.args[i])
            continue
        case "--width","--height","--density":
            delete(s.args[i])
            if i+1<len(s.args) {delete(s.args[i+1])}
            i+=1
            continue
        }
        s.args[kept]=s.args[i]
        kept+=1
    }
    resize(&s.args,kept)
}
