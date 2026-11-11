package main

import "core:fmt"
import "core:os"
import "mirai:project"

CONTENT_USAGE :: "content [project] [-- arguments of the tool]"

// The content tool of a project and what it is run with: tools/content of the
// project from its folder, or for the demo of this engine tools/demo_content,
// which takes the root of the engine as its first argument. tool is "" when it has none.
content_tool :: proc(root,owner:string) -> (tool,working,first:string) {
    if own:=join(owner,"tools/content");os.is_dir(own) {return own,owner,""}
    if owner==project.path_absolute(join(root,"demo"),context.temp_allocator) {
        return join(root,"tools/demo_content"),root,"."
    }
    return "","",""
}

// The command that runs a content tool: the collections it may import, so that
// neither docs nor templates teach compiler flags.
content_command :: proc(root,owner,tool,first:string,arguments:[]string) -> [dynamic]string {
    command:=odin_command(root,"run",tool,attributes=false)
    append(&command,fmt.aprintf("-collection:plugins=%s",join(root,"plugins")),fmt.aprintf("-collection:project=%s",owner),"-ignore-unknown-attributes")
    if first!="" || len(arguments)>0 {append(&command,"--")}
    if first!="" {append(&command,first)}
    append(&command,..arguments)
    return command
}

// mirai content [project] [-- arguments]: runs the content tool of the project.
cmd_content :: proc(root:string,args:[]string) -> int {
    given,arguments:=args,[]string{}
    for arg,i in args {
        if arg=="--" {given,arguments=args[:i],args[i+1:];break}
    }
    if code:=positionals_only("content",given);code!=0 {return code}
    if len(given)>1 {return argument_unknown("content",given[1])}
    folder:=len(given)==1?given[0]:"."
    owner:=project_of(folder)
    if owner=="" {
        fmt.eprintfln("mirai content: %s is not inside a project (no folder above has %s)",folder,project.PROJECT_FILE)
        return 1
    }
    tool,working,first:=content_tool(root,owner)
    if tool=="" {
        fmt.eprintfln("mirai content: %s has no content tool: its tools/content is a program that writes its assets",owner)
        return 1
    }
    command:=content_command(root,owner,tool,first,arguments)
    return run_with(working,command[:],os.stdout)
}
