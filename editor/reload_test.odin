package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Reload_Test_World :: struct {using world:core.Test_World}

// A gesture queued in the frame a build swaps the library, and a call that arrives before the
// methods are registered again, never run the handler of the code the swap replaced; a call of a
// plugin that waits holds the swap, since its own code is of the library it came from.
@(test)
nothing_registered_before_a_swap_runs_after_it :: proc(t:^testing.T) {
    world:Api_Test_Editor
    edits:history.Edits
    types :: proc(types:^[dynamic]core.Test_Type) {
        append(types,core.test_type(Api_Test_Provider,default=proc(dst:^Api_Test_Provider) {api_test_provider_v1(dst)}))
    }
    info,described:=core.test_info(t,Reload_Test_World,core.Test_None,Api_Test_Editor,types)
    if !described {return}
    defer core.test_info_destroy(&info)
    provider:=&info.storages[info.storages_by_type[Api_Test_Provider]]
    session:=Session{info=&info,editor_world=&world,edits=&edits}
    if !testing.expect_value(t,api_open(&session,0,true),Api_Open_Error.None) {return}
    defer api_close(&session)
    st:=api_state(&session)
    st.poll_temp=context.temp_allocator
    method:=api.method_find(&st.server,"test.plugin")
    if !testing.expect(t,method!=nil && (^Api_Entry)(method.user).provided) {return}
    shortcuts_run(&session,{.F9},{})
    testing.expect_value(t,st.commands.asked_count,1)
    // The swap: the new library gives the provider, and library_reload counts a generation.
    provider.default=api_test_provider_v2
    session.library_generation+=1
    commands_run(&session)
    testing.expect_value(t,session.frames,0)
    testing.expect_value(t,st.commands.asked_count,0)
    testing.expect(t,command_state(&session,"test.plugin").disabled)
    shortcuts_run(&session,{.F9},{})
    testing.expect_value(t,st.commands.asked_count,0)
    out:serial.Writer
    serial.writer_init(&out)
    defer serial.writer_destroy(&out)
    _,ok:=api.method_execute(&st.server,method,"{}",&out)
    testing.expect(t,!ok)
    st.in_call,st.waiting,st.provided_calls=1,1,1
    testing.expect(t,library_busy(&session))
    st.in_call,st.waiting,st.provided_calls=0,0,0
}

// The binaries of a build of the engine are where the editor started from, also once the build
// moved the running ones aside, which some systems then name as the executable.
@(test)
the_engine_of_an_editor_is_the_folder_it_started_from :: proc(t:^testing.T) {
    s:=Session{program="C:/mirai/.mirai/engine/dev/mirai-editor.exe"}
    testing.expect_value(t,engine_folder_here(&s),"C:/mirai/.mirai/engine/dev")
    player:=engine_program_here(&s,"mirai-player")
    testing.expect_value(t,player,"C:/mirai/.mirai/engine/dev/mirai-player.exe" when ODIN_OS==.Windows else "C:/mirai/.mirai/engine/dev/mirai-player")
}

// The record of mirai session follows an editor to the one it starts in its place, keeping the
// mode and the arguments; a record of another editor stays as it is.
@(test)
the_session_record_follows_an_editor_that_restarts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"restart")
    if folder=="" {return}
    path:=project.path(folder,".mirai",api.SESSION_FILE)
    testing.expect(t,os.make_directory_all(os.dir(path))==nil)
    read :: proc(path:string) -> (record:api.Session_Record) {
        data,_:=os.read_entire_file(path,context.temp_allocator)
        _=json.unmarshal(data,&record,allocator=context.temp_allocator)
        return
    }
    s:=Session{has_project=true,project_root=folder}
    for owner,i in ([]int{os.get_pid(),os.get_pid()+1}) {
        record:=fmt.tprintf(`{{"pid": %d, "mode": "dev", "args": ["--api-port", "0"]}}`,owner)
        testing.expect(t,os.write_entire_file(path,record)==nil)
        session_record_follow(&s,4242)
        followed:=read(path)
        testing.expect_value(t,followed.pid,i==0?4242:owner)
        testing.expect(t,followed.mode=="dev" && len(followed.args)==2 && followed.args[1]=="0")
    }
}
