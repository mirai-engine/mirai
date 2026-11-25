package main

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:std/base"

// A script is known by its #! line; a plain file or a missing one is not run by the shell.
@(test)
a_script_is_told_by_its_shebang :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=base.test_folder(t,"shell")
    if folder=="" {return}
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

// Git Bash is found from the root git --exec-path names, also through a shim such as Scoop's,
// whose git reports the folder it was installed in.
@(test)
git_bash_is_found_from_the_exec_path_of_git :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    cases:=[?]struct{exec:string,root:string}{
        {"C:/Program Files/Git/mingw64/libexec/git-core","C:/Program Files/Git"},
        {"C:/Users/u/scoop/apps/git/current/mingw64/libexec/git-core","C:/Users/u/scoop/apps/git/current"},
    }
    for c in cases {testing.expect_value(t,git_bash(c.exec),join(c.root,"bin","bash.exe"))}
}
