package editor

import "core:fmt"
import "core:io"
import "core:mem"
import "core:strings"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/serial"

// What mirai rpc describe answers when no editor of the project runs: the
// methods are registered as an editor registers them, over the world of the
// library of the project as it was built last, with no window, GPU or port,
// and engine.describe answers as it would there. A search by words finds the
// methods by what they do and the components, record types, named values,
// actions and presets whose names or descriptions say the words. The import
// program runs it (describe):
//
//   describe --project P --engine E --params <JSON of engine.describe>
//   describe --project P --engine E --search <word>...

describe_command :: proc(args:[]string,output,errors:io.Writer) -> int {
    root,engine,params:string
    words:=make([dynamic]string,context.temp_allocator)
    searching:=false
    for at:=0;at<len(args);at+=1 {
        switch {
        case args[at]=="--project" && at+1<len(args): root=args[at+1];at+=1
        case args[at]=="--engine" && at+1<len(args):  engine=args[at+1];at+=1
        case args[at]=="--params" && at+1<len(args):  params=args[at+1];at+=1
        case args[at]=="--search":                    searching=true
        case searching:                               append(&words,args[at])
        case:
            fmt.wprintln(errors,"Usage: describe --project P --engine E --params <JSON> | --search <word>...")
            return 2
        }
    }
    if root=="" || engine=="" || !searching && params=="" {
        fmt.wprintln(errors,"Usage: describe --project P --engine E --params <JSON> | --search <word>...")
        return 2
    }
    root=project.path_absolute(root,context.temp_allocator)
    path:=project.project_library(root,"editor",context.temp_allocator)
    library,loaded:=host.project_library_load(path)
    if loaded!=.None {
        fmt.wprintfln(errors,"describe: %s; mirai build editor %s builds it",host.library_error_text(loaded,path),root)
        return 1
    }
    defer host.project_library_unload(&library)
    info:=&library.info
    world,allocated:=mem.alloc(info.sizes[.Editor],max(info.aligns[.Editor],1))
    if allocated!=nil {
        fmt.wprintln(errors,"describe: out of memory for the editor world")
        return 1
    }
    defer {core.world_destroy(info,.Editor,world);mem.free(world)}
    if !core.world_init(info,.Editor,world,context.allocator) {
        fmt.wprintln(errors,"describe: out of memory for the editor world")
        return 1
    }
    edits:history.Edits
    s:=Session{info=info,editor_world=world,edits=&edits,project_root=root,engine_root=project.path_absolute(engine,context.temp_allocator),has_project=true}
    opened,problem:=api_open(&s,0,true,listen=false)
    if opened!=.None {
        fmt.wprintfln(errors,"describe: the methods could not be registered: %s",problem)
        return 1
    }
    defer api_close(&s)
    st:=api_state(&s)
    st.poll_temp=context.temp_allocator
    if !searching {
        out:serial.Writer
        serial.writer_init(&out,1<<20,context.temp_allocator)
        err,ok:=api.method_execute(&st.server,api.method_find(&st.server,"engine.describe"),params,&out)
        if !ok {
            fmt.wprintln(errors,api.error_text(err,context.temp_allocator))
            return 1
        }
        fmt.wprintln(output,string(serial.writer_bytes(&out)))
        return 0
    }
    fmt.wprint(output,describe_search(&s,&st.server,strings.join(words[:]," ",context.temp_allocator)))
    return 0
}

// What a search by words finds, a section per kind and a line per thing:
// the methods by what they do, best first; then the components, record
// types, named values, actions and presets whose names or descriptions say a
// word of the query.
@(private)
describe_search :: proc(s:^Session,server:^api.Server,query:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    words:=strings.fields(strings.to_lower(query,context.temp_allocator),context.temp_allocator)
    says :: proc(words:[]string,texts:..string) -> bool {
        for text in texts {
            lower:=strings.to_lower(text,context.temp_allocator)
            for word in words {
                if strings.contains(lower,word) {return true}
            }
        }
        return false
    }
    section :: proc(b:^strings.Builder,title:string,lines:[]string) {
        if len(lines)==0 {return}
        fmt.sbprintfln(b,"%s:",title)
        for line in lines {fmt.sbprintfln(b,"  %s",line)}
    }
    methods:=make([dynamic]string,context.temp_allocator)
    for method in api.methods_doing(server,query,12,context.temp_allocator) {
        summary:=method.summary
        if cut:=strings.index(summary,". ");cut>0 {summary=summary[:cut]}
        append(&methods,fmt.tprintf("%s: %s",method.name,summary))
    }
    section(&b,"methods (mirai rpc describe <method> gives the params and an example)",methods[:])
    info:=s.info
    components:=make([dynamic]string,context.temp_allocator)
    for &t in info.tables {
        if says(words,t.name,t.description) {append(&components,t.description!="" ? fmt.tprintf("%s (%s): %s",t.name,t.library,t.description) : fmt.tprintf("%s (%s)",t.name,t.library))}
    }
    section(&b,"components (component.list gives their fields as scene.write takes them)",components[:])
    records:=make([dynamic]string,context.temp_allocator)
    for &r in info.records {
        if says(words,r.name,r.library) {append(&records,fmt.tprintf("%s (%s): mirai records read, a content tool's records_write",r.name,r.library))}
    }
    section(&b,"record types",records[:])
    names:=make([dynamic]string,context.temp_allocator)
    actions:=make([dynamic]string,context.temp_allocator)
    for &n in info.names {
        named:=core.named_type_of(info,n.type)
        type:=named.name if named!=nil else ""
        if !says(words,n.name,type) {continue}
        if named!=nil && named.actions {append(&actions,fmt.tprintf("%s (%s of %s)",n.name,type,n.library))} else {append(&names,fmt.tprintf("%s (%s of %s)",n.name,type,n.library))}
    }
    section(&b,"named values",names[:])
    section(&b,"input actions",actions[:])
    presets:=make([dynamic]string,context.temp_allocator)
    if opened,error:=project.open(s.project_root,s.engine_root,context.temp_allocator);error.code==.None {
        for recipe in author.recipes_read(project.recipe_folders(&opened,context.temp_allocator),context.temp_allocator) {
            if says(words,recipe.name,recipe.label) {append(&presets,fmt.tprintf("%s: scene.write takes it as preset",recipe.name))}
        }
    }
    section(&b,"presets",presets[:])
    if strings.builder_len(b)==0 {fmt.sbprintfln(&b,"nothing says %s: mirai rpc describe without an argument lists the methods, and mirai docs --search the documentation",query)}
    return strings.to_string(b)
}
