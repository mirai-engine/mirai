package main

import "core:fmt"
import "core:strings"
import "mirai:cook/build"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:std/subprocess"

// mirai rpc describe without an open editor: the import program of the engine
// registers the methods of the project as its editor would, over the library
// of the project (built first when it is not current), and answers
// engine.describe, or a search by words (editor.describe_command).

// engine.describe of the editor of the project, or of no editor when the
// project has none open.
describe_call :: proc(connection:Connection,params:string) -> (result:string,err:api.Error,called:bool) {
    if connection.project=="" || connection_editor(connection).port!=0 {return rpc_call_waiting(connection,"engine.describe",params,1)}
    return describe_offline(connection,{"--params",params})
}

// What the import program answers of the project of connection, with no
// editor; err says why it could not.
describe_offline :: proc(connection:Connection,args:[]string) -> (result:string,err:api.Error,called:bool) {
    owner:=project_of(connection.project if connection.project!="" else ".")
    if owner=="" {return "",{api.UNREACHABLE,"no project is named (--project) nor holds the current folder: describe reads the methods of a project",""},false}
    mode:=build.engine_mode_resolve(connection.root,.Dev)
    if code,_,_:=build_project(connection.root,.Editor,{owner},mode,library_only=true);code!=0 {
        return "",{api.UNREACHABLE,fmt.tprintf("the library of %s did not build, and describe reads its methods from it: what the build said is above",owner),""},false
    }
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,build.engine_paths(connection.root,mode,context.temp_allocator).import_program,"describe","--project",owner,"--engine",connection.root)
    append(&command,..args)
    state,stdout,stderr,error:=subprocess.exec({command=command[:]},context.allocator)
    if error!=nil || state.exit_code!=0 {
        // What engine.describe refused, as an editor would have answered it.
        refused:struct {error:struct {code:int,message:string}}
        if serial.text_decode(strings.trim_space(string(stderr)),&refused,context.temp_allocator,skip_unknown=true)=="" && refused.error.code!=0 {
            return "",{refused.error.code,refused.error.message,""},false
        }
        return "",{api.SERVER_ERROR,fmt.tprintf("describe with no editor failed: %s",strings.trim_space(string(stderr))),""},false
    }
    return string(stdout),{},true
}

// mirai rpc describe --search <word>...: the methods that do what the words
// say, and the components, record types, named values, actions and presets
// that say them.
describe_search :: proc(connection:Connection,words:[]string) -> int {
    if len(words)==0 {
        fmt.eprintln("mirai rpc describe --search: give words of what you look for, as spawn enemy")
        return 2
    }
    args:=make([dynamic]string,context.temp_allocator)
    append(&args,"--search")
    append(&args,..words)
    text,err,called:=describe_offline(connection,args[:])
    if !called {return rpc_fail(err)}
    fmt.print(text)
    return 0
}
