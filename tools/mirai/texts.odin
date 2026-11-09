package main

import "core:fmt"
import "core:strings"
import "mirai:editor/api"
import "mirai:project"

TEXTS_USAGE :: "texts export|import <file.csv> [--project P|--port N]"

// mirai texts: every localized text of the .ui of a project to a CSV for
// translators and back, through the editor of the project (ui.text.export
// and ui.text.import). An import waits for Save in the editor.
cmd_texts :: proc(root:string,args:[]string) -> int {
    connection,ok:=connection_args(args,agent_environment())
    connection.root=root
    if !ok || len(connection.rest)!=2 || connection.rest[0]!="export" && connection.rest[0]!="import" {
        fmt.eprintfln("Usage: mirai %s",TEXTS_USAGE)
        return 2
    }
    path,_:=strings.replace_all(project.path_absolute(connection.rest[1],context.temp_allocator),"\\","/",context.temp_allocator)
    escaped,_:=strings.replace_all(path,`"`,`\"`,context.temp_allocator)
    params:=fmt.tprintf(`{"path":"%s"}`,escaped)
    result,err,called:=rpc_call_waiting(connection,fmt.tprintf("ui.text.%s",connection.rest[0]),params,1)
    if !called {return rpc_fail(err)}
    fmt.println(api.json_pretty(result,context.allocator))
    return 0
}
