package main

import "core:os"
import "core:fmt"
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

// A content tool runs with the collections it may import, and its own arguments after --.
@(test)
a_content_tool_runs_with_its_collections_and_its_arguments :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    command:=content_command("C:/engine","C:/game","C:/game/tools/content","",{"--fast"})
    for wanted in ([]string{"-collection:mirai=C:/engine",fmt.tprintf("-collection:plugins=%s",join("C:/engine","plugins")),"-collection:project=C:/game","-ignore-unknown-attributes","--","--fast"}) {
        testing.expectf(t,slice.contains(command[:],wanted),"%s in %v",wanted,command)
    }
    alone:=content_command("C:/engine","C:/game","C:/game/tools/content","",nil)
    testing.expect(t,!slice.contains(alone[:],"--"),"nothing after it")
    testing.expect_value(t,alone[2],"C:/game/tools/content")
}
