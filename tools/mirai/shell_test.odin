package main

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// A script is known by its #! line; a plain file or a missing one is not run by the shell.
@(test)
a_script_is_told_by_its_shebang :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-shell-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    cases:=[?]struct{text:string,script:bool}{{"#!/usr/bin/env sh\nset -e\n",true},{"echo no shebang\n",false},{"#",false}}
    for c in cases {
        path:=join(folder,"script")
        testing.expect(t,os.write_entire_file(path,c.text)==nil)
        testing.expect_value(t,shebang(path),c.script)
    }
    testing.expect(t,!shebang(join(folder,"missing")))
}

// The tool is built without naming the attributes of the engine: the list of the tool that runs
// is the one of its own build, and the sources it builds may use attributes it lacks.
@(test)
the_tool_is_built_without_a_list_of_attributes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    command:=tool_command(".","tools/mirai","-o:minimal","out.exe","out.sources.json")
    for argument in command {
        testing.expect(t,!strings.has_prefix(argument,"-custom-attribute"),"no list of attributes")
    }
    testing.expect(t,slice.contains(command[:],"-ignore-unknown-attributes"))
    testing.expect(t,slice.contains(command[:],"-out:out.exe"))
}

// Git for Windows installed outside Program Files is found from the git.exe of PATH, in
// <root>/cmd or <root>/mingw64/bin, as mirai.cmd finds it.
@(test)
git_bash_is_found_where_git_is_installed :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,error:=os.make_directory_temp("","mirai-git-bash-*",context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    defer os.remove_all(folder)
    root:=join(folder,"gitforwindows")
    for sub in ([3]string{"bin","cmd","mingw64/bin"}) {testing.expect(t,os.make_directory_all(join(root,sub))==nil)}
    bash:=join(root,"bin","bash.exe")
    testing.expect(t,os.write_entire_file(bash,[]u8{})==nil)
    elsewhere:=join(folder,"Program Files")
    Case :: struct {git:string,found:bool}
    cases:=[?]Case{{join(root,"cmd","git.exe"),true},{join(root,"mingw64","bin","git.exe"),true},{"",false}}
    for c in cases {
        path,found:=git_bash_find({elsewhere,"",""},"",c.git)
        testing.expectf(t,found==c.found,"git at %q: found %v",c.git,found)
        if c.found {testing.expect_value(t,path,bash)} else {testing.expect_value(t,path,join(elsewhere,"Git","bin","bash.exe"))}
    }
    path,found:=git_bash_find({"","",""},root,"")
    testing.expect(t,found && path==bash,"GIT_INSTALL_ROOT names the root")
}
