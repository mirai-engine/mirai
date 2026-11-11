package host

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:std/base"

@(test)
loading_a_library_keeps_the_copies_of_processes_that_still_run :: proc(t:^testing.T) {
    root:=base.test_folder(t,"host-library")
    if root=="" {return}
    path:=fmt.tprintf("%s/libgame.dylib",root)
    running:=fmt.tprintf("%s/libgame-live-%d-0.dylib",root,os.get_ppid())
    ended:=fmt.tprintf("%s/libgame-live-%d-0.dylib",root,2147483646)
    for file in ([3]string{path,running,ended}) {testing.expect_value(t,os.write_entire_file(file,"not a library"),nil)}
    // It is not a library: what matters is what loading it removed first.
    _,error:=project_library_load(path,0)
    testing.expect_value(t,error,Library_Error.Load_Failed)
    testing.expect(t,os.is_file(running),"the copy of a process that runs stays")
    testing.expect(t,!os.is_file(ended),"the copy of a process that ended goes")
}

@(test)
the_player_loads_the_library_its_arguments_name :: proc(t:^testing.T) {
    Case :: struct {args:[]string,name:string,known:bool}
    cases:=[?]Case{
        {[]string{"--project","game"},"play",true},
        {[]string{"--library","editor","--connect","code"},"editor",true},
        {[]string{"--library","game"},"game",false},
        {[]string{"--library"},"",false},
    }
    for c in cases {
        name,known:=library_argument(c.args)
        testing.expect_value(t,name,c.name)
        testing.expect_value(t,known,c.known)
    }
    // The player reads it as its own: no plugin is asked for it.
    options,ok:=player_options({"--library","editor"})
    defer delete(options.arguments)
    testing.expect(t,ok && len(options.arguments)==0)
    // --dedicated is the player's and of the plugin that serves the game: it stays for that one.
    dedicated,read:=player_options({"--dedicated"})
    defer delete(dedicated.arguments)
    testing.expect(t,read && dedicated.dedicated && len(dedicated.arguments)==1 && dedicated.arguments[0]=="--dedicated")
}
