package editor

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The editor that opens on a project gives its window to the headless editor
// of a session only when it runs the binaries beside this one: another
// worktree or build mode opens its own. One that does not answer leaves the
// opening editor ending, never a second editor that takes its port file.
@(test)
the_session_of_these_binaries_takes_the_window :: proc(t:^testing.T) {
    root:=base.test_folder(t,"session-show")
    write :: proc(root,engine:string,manual:bool) {
        data,_:=serial.text_encode(api.Port_File{port=1,pid=os.get_pid(),project=root,engine=engine,manual=manual},.Pretty,context.temp_allocator)
        path:=project.path(root,".mirai",api.PORT_FILE,allocator=context.temp_allocator)
        _=os.make_directory_all(path[:strings.last_index_byte(path,'/')])
        _=os.write_entire_file(path,data)
    }
    testing.expect_value(t,session_show(root),Session_Show.None)
    program,_:=os.get_executable_path(context.temp_allocator)
    program,_=strings.replace_all(program,"\\","/",context.temp_allocator)
    here:=program[:strings.last_index_byte(program,'/')]
    cases:=[?]struct {engine:string,manual:bool,want:Session_Show}{
        {project.path(root,"other-worktree",allocator=context.temp_allocator),true,.None},
        {here,false,.None}, // the user's windowed editor: a second one opens as before
        {here,true,.Busy},  // nothing answers on its port
    }
    for c in cases {
        write(root,c.engine,c.manual)
        testing.expectf(t,session_show(root)==c.want,"engine %s manual %v: want %v",c.engine,c.manual,c.want)
    }
}
