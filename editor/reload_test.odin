package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"

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
// arguments; a record of another editor stays as it is.
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
        record:=fmt.tprintf(`{{"pid": %d, "args": ["--api-port", "0"]}}`,owner)
        testing.expect(t,os.write_entire_file(path,record)==nil)
        session_record_follow(&s,4242)
        followed:=read(path)
        testing.expect_value(t,followed.pid,i==0?4242:owner)
        testing.expect(t,len(followed.args)==2 && followed.args[1]=="0")
    }
}
