package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/build"
import "mirai:cook/shaders"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// material.program.*: the Slang source of a program (Surface, PostProcess,
// Vfx or UI) as the agent works on it, as it is now (unsaved, or its file).
// check compiles it without publishing; create and edit change the source in
// memory as a step of undo (attributed to the turn that asks) once it
// compiles, and publish the programs of the project; inspect gives the
// source with its parameters and the graph derived from it. The domain of a
// program is the one its source declares.

@(private)
PROGRAM_PARAMS_SCHEMA :: `{"type":"object","properties":{"program":{"type":"string","description":"A program by name (Surface, PostProcess, Vfx or UI), or the path of its .slang under the project"},"material":{"type":"string","description":"A material whose program it is: its path under the assets folder, or its id"},"source":{"type":"string","description":"check: the text to check in place of the file; edit: the whole new source"},"edits":{"type":"array","description":"edit: replacements applied in order; each old occurs once in the source","items":{"type":"object","properties":{"old":{"type":"string"},"new":{"type":"string"}},"required":["old","new"],"additionalProperties":false}}},"additionalProperties":false}`

@(private)
PROGRAM_CREATE_SCHEMA :: `{"type":"object","properties":{"program":{"type":"string","description":"The name of the new program: a Slang identifier no program of the project, its plugins or the engine has"},"kind":{"type":"string","enum":["surface","postprocess","vfx","ui"],"description":"Its domain; without it the one source declares, else surface"},"source":{"type":"string","description":"Its whole source, declaring //! mirai <kind> <program>; without it a template of the domain that compiles"}},"required":["program"],"additionalProperties":false}`

@(private)
Program_Params :: struct {
    program,material,source,kind:string,
    has_source:bool,
    edits:[dynamic][2]string,
}

// A source as long as the longest response of the API.
@(private)
PROGRAM_TEXT_BYTES :: 4<<20

@(private)
Api_Program_Result :: struct {
    program:[256]u8 `mirai:"text"`,
    kind:[16]u8 `mirai:"text,label=surface; postprocess; vfx or ui"`,
    file:[API_PATH_BYTES]u8 `mirai:"text,label=The program as its diagnostics name it"`,
    compiled:bool `mirai:"label=Every stage of the check compiled: raster and rays for a Surface program (it also runs on ray hits); the stages of the engine that run the others"`,
    errors:int,
    warnings:int,
    parameters_size:int `mirai:"label=Bytes of its struct Parameters"`,
    diagnostics:[1]Api_Program_Diagnostic `mirai:"list"`,
    publishing:bool `mirai:"optional,label=Of material.program.create and .edit: the renderer does not have the whole generation yet; the stages the previews draw with come first (material.preview.capture waits for them) and then the rest for the viewport"`,
}

@(private)
Api_Program_Diagnostic :: struct {
    severity:[8]u8 `mirai:"text,label=error; warning or info"`,
    code:[64]u8 `mirai:"text,label=Of Slang (E30015) or a rule of the check (mirai.ray_derivatives)"`,
    file:[API_PATH_BYTES]u8 `mirai:"text,label=Under the project or the engine; or as the compiler named it"`,
    line:int `mirai:"label=From 1; 0 for what is not at a place"`,
    column:int `mirai:"label=From 1; 0 for what is not at a place"`,
    end_line:int,
    end_column:int,
    stage:[64]u8 `mirai:"text,label=The compilation that said it: raster or ray for a Surface program and the stage of the engine for the others (postprocess.frag); all when every one said it; empty for the rules of the check"`,
    node:[512]u8 `mirai:"text,label=The id of the node of the graph of material.program.inspect at that line"`,
    message:[4096]u8 `mirai:"text"`,
    fix:[4096]u8 `mirai:"text"`,
}

@(private)
Api_Program_Inspect :: struct {
    program:[256]u8 `mirai:"text"`,
    kind:[16]u8 `mirai:"text,label=surface; postprocess; vfx or ui"`,
    file:[API_PATH_BYTES]u8 `mirai:"text,label=Its .slang: from the folder of the project when it is in it"`,
    source:[PROGRAM_TEXT_BYTES]u8 `mirai:"text"`,
    parameters:[1]Api_Program_Parameter `mirai:"list,label=The fields of its struct Parameters"`,
    graph:Api_Program_Graph `mirai:"label=Derived from the source and read only: the source is what changes"`,
}

@(private)
Api_Program_Parameter :: struct {
    name:[256]u8 `mirai:"text"`,
    type:[128]u8 `mirai:"text"`,
    line:int,
    metadata:u8 `mirai:"any,label=The JSON of its //! parameter line; null without one"`,
    metadata_line:int `mirai:"optional"`,
}

@(private)
Api_Program_Graph :: struct {
    nodes:[1]Api_Program_Node `mirai:"list"`,
    edges:[1]Api_Program_Edge `mirai:"list"`,
}

@(private)
Api_Program_Node :: struct {
    id:[512]u8 `mirai:"text,label=Stable across edits of the source: Program/function/variable; the n-th write with #n"`,
    kind:[16]u8 `mirai:"text,label=input; parameter; texture; constant; local; call; if; loop; output; surface; return or code"`,
    label:[256]u8 `mirai:"text"`,
    function:[256]u8 `mirai:"text"`,
    lines:[2]int `mirai:"label=The first and the last"`,
    text:[PROGRAM_TEXT_BYTES]u8 `mirai:"text"`,
}

@(private)
Api_Program_Edge :: struct {
    from:[512]u8 `mirai:"text"`,
    to:[512]u8 `mirai:"text"`,
    control:bool `mirai:"label=to is inside the branch or loop from; otherwise to takes the value of from"`,
}

@(private)
programs_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="material.program.check",params_schema=PROGRAM_PARAMS_SCHEMA,summary="Compiles a program without publishing it, where it runs (a Surface program for raster and for ray hits), and reads its source for the usual mistakes.",result=Api_Program_Result,writes_result=true,flags={.Read_Only,.Idempotent},run=api_program_check})
    api_register(s,st,{name="material.program.create",params_schema=PROGRAM_CREATE_SCHEMA,summary="Makes a new program in the shaders folder of the project once it compiles, in memory as one undo step until asset.save writes its .slang, and publishes the programs of the project.",result=Api_Program_Result,writes_result=true,run=api_program_create})
    api_register(s,st,{name="material.program.edit",params_schema=PROGRAM_PARAMS_SCHEMA,summary="Changes the source of a program once it compiles, in memory as one undo step until asset.save writes its .slang, and publishes the programs of the project.",result=Api_Program_Result,writes_result=true,run=api_program_edit})
    api_register(s,st,{name="material.program.inspect",params_schema=PROGRAM_PARAMS_SCHEMA,summary="The source of a program, the fields of its struct Parameters and the graph derived from the source.",result=Api_Program_Inspect,writes_result=true,flags={.Read_Only,.Idempotent},run=api_program_inspect})
}

@(private)
program_params :: proc(call:^api.Call,create:=false) -> (p:Program_Params,ok:bool) {
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    p.edits=make([dynamic][2]string,call.allocator)
    o:Rpc_Object
    if !rpc_object_begin(&a,"params") {return}
    for key in rpc_next(&a,&o) {
        switch key {
        case "program","material","source","kind":
            text,read:=serial.text_string(&a.r)
            if !read {rpc_fail_type(&a,"%s must be a string",key);return}
            text=strings.clone(text,call.allocator)
            switch key {
            case "program":  p.program=text
            case "material": p.material=text
            case "kind":     p.kind=text
            case:            p.source,p.has_source=text,true
            }
        case "edits":
            if !serial.text_accept(&a.r,'[') {rpc_fail(&a,"edits must be an array of {old, new}");return}
            for i:=0;!serial.text_accept(&a.r,']');i+=1 {
                if i>0 && !serial.text_accept(&a.r,',') {rpc_fail(&a,"edits must be an array of {old, new}");return}
                edit:[2]string
                inner:Rpc_Object
                if !rpc_object_begin(&a,"an edit") {return}
                has:[2]bool
                for field in rpc_next(&a,&inner) {
                    at:=field=="old"?0:field=="new"?1:-1
                    if at<0 {rpc_fail(&a,"an edit has old and new, not %s",field);return}
                    text,read:=serial.text_string(&a.r)
                    if !read {rpc_fail(&a,"edits[%d].%s must be a string",i,field);return}
                    edit[at],has[at]=strings.clone(text,call.allocator),true
                }
                if a.failed {return}
                if !has[0] || !has[1] {rpc_fail(&a,"edits[%d] needs old and new",i);return}
                if edit[0]=="" {rpc_fail(&a,"edits[%d].old is empty: give the text to replace",i);return}
                append(&p.edits,edit)
            }
        }
    }
    if a.failed {return}
    if create && p.program=="" {api.call_fail(call,api.INVALID_PARAMS,"program is required: the name of the new program");return}
    if p.program=="" && p.material=="" {api.call_fail(call,api.INVALID_PARAMS,"program or material is required");return}
    return p,true
}

// The name a source declares with `//! mirai surface Name`: of a program a
// material can use.
@(private)
program_declared :: proc(text:string) -> string {
    said:=shaders.program_directives(text)
    return said.domain=="surface"?said.name:""
}

// Where programs come from: the project, its active plugins, the engine.
@(private)
program_folders :: proc(s:^Session) -> (folders:[dynamic]string,sources:[]shaders.Source) {
    folders=make([dynamic]string,context.temp_allocator)
    if s.has_project {
        append(&folders,project.path(s.project_root,"shaders",allocator=context.temp_allocator))
        if s.engine_root!="" {
            if p,error:=project.open(s.project_root,s.engine_root,context.temp_allocator);error.code==.None {
                sources,_=build.shader_sources(&p,context.temp_allocator)
                for source in sources {append(&folders,source.folder)}
            }
        }
    }
    if s.engine_root!="" {append(&folders,project.path(s.engine_root,"shaders/materials",allocator=context.temp_allocator))}
    return
}

// The file of a program by its name or its path, or of the program of a
// material, and the domain its source declares.
@(private)
program_file :: proc(s:^Session,call:^api.Call,p:Program_Params) -> (domain,name,path:string,sources:[]shaders.Source,ok:bool) {
    _,sources=program_folders(s)
    wanted:=p.program
    if p.material!="" {
        id,found:=asset_named(s,call,p.material,asset.KIND_MATERIAL,".mat","a material")
        if !found {return}
        info,read:=material_file(s,id)
        if !read {api.call_fail(call,api.SERVER_ERROR,api_asset_read_problem(s,id,"material"));return}
        wanted=strings.clone(base.text_get(info.program[:]),context.temp_allocator)
        if wanted=="" {api.call_failf(call,api.INVALID_PARAMS,"%s has no program: it uses the standard model (material.set changes its values)",p.material);return}
    }
    if strings.has_suffix(wanted,".slang") {
        full:=filepath.is_abs(wanted)?wanted:project.path(s.project_root,wanted,allocator=context.temp_allocator)
        full,_=strings.replace_all(full,"\\","/",context.temp_allocator)
        data,read:=file_read(s,full)
        if !read {api.call_failf(call,api.INVALID_PARAMS,"%s could not be read",wanted);return}
        said:=shaders.program_directives(string(data))
        if domain,name=said.domain,said.name;name=="" {api.call_failf(call,api.INVALID_PARAMS,"%s declares no program: one of its lines is //! mirai surface Name (or postprocess, vfx or ui)",wanted);return}
        return domain,name,full,sources,true
    }
    located:bool
    if path,sources,located=program_locate(s,wanted);located {
        data,_:=file_read(s,path)
        domain=shaders.program_directives(string(data)).domain
        return domain,wanted,path,sources,true
    }
    api.call_failf(call,api.INVALID_PARAMS,"no program is named %q in the project, its plugins or the engine; material.program.create makes one",wanted)
    return
}

// The .slang that declares a program of that name, where programs come from:
// one made in memory and not saved yet too.
program_locate :: proc(s:^Session,name:string) -> (path:string,sources:[]shaders.Source,ok:bool) {
    folders:[dynamic]string
    folders,sources=program_folders(s)
    for held in assets_unsaved(s) {
        if held.removed || !asset.registry_outside(held.path) || !strings.has_suffix(held.path,".slang") {continue}
        if shaders.program_directives(string(held.data)).name!=name {continue}
        for folder in folders {
            if strings.has_prefix(held.path,folder) && len(held.path)>len(folder) && held.path[len(folder)]=='/' {return strings.clone(held.path,context.temp_allocator),sources,true}
        }
    }
    for folder in folders {
        w:=os.walker_create(folder)
        defer os.walker_destroy(&w)
        for info in os.walker_walk(&w) {
            if info.type!=.Regular || !strings.has_suffix(info.name,".slang") {continue}
            full,_:=strings.replace_all(info.fullpath,"\\","/",context.temp_allocator)
            data,read:=file_read(s,full)
            if !read {continue}
            if shaders.program_directives(string(data)).name!=name {continue}
            return strings.clone(full,context.temp_allocator),sources,true
        }
    }
    return
}

// The source of a program as it is now, unsaved or in its file.
@(private)
program_text :: proc(s:^Session,path:string) -> (text:string,ok:bool) {
    data:=file_read(s,path) or_return
    text,_=strings.replace_all(string(data),"\r\n","\n",context.temp_allocator)
    return text,true
}

@(private)
program_check_run :: proc(s:^Session,path,text:string,sources:[]shaders.Source) -> shaders.Check_Result {
    return shaders.program_check({root=s.engine_root,project=s.has_project?s.project_root:"",sources=sources,path=path,text=text},context.temp_allocator)
}

@(private)
diagnostics_write :: proc(w:^serial.Writer,list:[]shaders.Diagnostic) {
    names:=shaders.SEVERITY_NAMES
    serial.write_u8(w,'[')
    for d,i in list {
        if i>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{')
        api.write_text(w,"severity",names[d.severity],true)
        api.write_text(w,"code",d.code)
        api.write_text(w,"file",d.file)
        api.write_int(w,"line",i64(d.line))
        api.write_int(w,"column",i64(d.column))
        api.write_int(w,"end_line",i64(d.end_line))
        api.write_int(w,"end_column",i64(d.end_column))
        api.write_text(w,"stage",d.stage)
        api.write_text(w,"node",d.node)
        api.write_text(w,"message",d.message)
        api.write_text(w,"fix",d.fix)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
}

@(private)
check_fields_write :: proc(w:^serial.Writer,name:string,result:^shaders.Check_Result) {
    domains:=shaders.PROGRAM_DOMAINS
    api.write_text(w,"program",name,true)
    api.write_text(w,"kind",domains[result.domain])
    api.write_text(w,"file",result.file)
    api.write_bool(w,"compiled",result.compiled)
    api.write_int(w,"errors",i64(result.errors))
    api.write_int(w,"warnings",i64(result.warnings))
    api.write_int(w,"parameters_size",i64(result.parameters_size))
    api.write_key(w,"diagnostics");diagnostics_write(w,result.diagnostics)
}

@(private)
api_program_check :: proc(s:^Session,call:^api.Call) {
    p,valid:=program_params(call)
    if !valid {return}
    _,name,path,sources,found:=program_file(s,call,p)
    if !found {return}
    text,read:=p.has_source?p.source:"",true
    if !p.has_source {text,read=program_text(s,path)}
    if !read {api.call_failf(call,api.SERVER_ERROR,"%s could not be read: the file is missing or locked",path);return}
    result:=program_check_run(s,path,text,sources)
    if result.error!="" {api.call_fail(call,api.SERVER_ERROR,result.error);return}
    serial.write_u8(call.out,'{')
    check_fields_write(call.out,name,&result)
    serial.write_u8(call.out,'}')
}

// The source an edit leaves: the whole new one, or the replacements in order.
@(private)
program_edited :: proc(call:^api.Call,p:Program_Params,current:string) -> (text:string,ok:bool) {
    if p.has_source && len(p.edits)>0 {api.call_fail(call,api.INVALID_PARAMS,"give source or edits, not both");return}
    if p.has_source {
        text,_=strings.replace_all(p.source,"\r\n","\n",context.temp_allocator)
        return text,true
    }
    if len(p.edits)==0 {api.call_fail(call,api.INVALID_PARAMS,"source or edits is required");return}
    text=current
    for edit,i in p.edits {
        old,_:=strings.replace_all(edit[0],"\r\n","\n",context.temp_allocator)
        new,_:=strings.replace_all(edit[1],"\r\n","\n",context.temp_allocator)
        count:=strings.count(text,old)
        if count!=1 {
            api.call_failf(call,api.INVALID_PARAMS,"edits[%d].old occurs %d times in the source; it has to occur once: give more of the text around it",i,count)
            return
        }
        text,_=strings.replace(text,old,new,1,context.temp_allocator)
    }
    return text,true
}

@(private)
api_program_edit :: proc(s:^Session,call:^api.Call) {
    p,valid:=program_params(call)
    if !valid {return}
    domain,name,path,sources,found:=program_file(s,call,p)
    if !found {return}
    current,read:=program_text(s,path)
    if !read {api.call_failf(call,api.SERVER_ERROR,"%s could not be read: the file is missing or locked",path);return}
    text,edited:=program_edited(call,p,current)
    if !edited {return}
    if said:=shaders.program_directives(text);said.domain!=domain || said.name!=name {
        api.call_failf(call,api.INVALID_PARAMS,"the source has to keep `//! mirai %s %s`; material.program.create makes a new program",domain,name)
        return
    }
    program_write(s,call,name,path,text,text!=current,sources,"Edit program")
}

// Makes a program in the shaders folder of the project, named after it in
// lower case: from the source given, or the template of its domain.
@(private)
api_program_create :: proc(s:^Session,call:^api.Call) {
    p,valid:=program_params(call,create=true)
    if !valid {return}
    if !s.has_project {api.call_fail(call,api.SERVER_ERROR,"No project is open: a program is made in the shaders folder of a project; open one");return}
    name:=p.program
    if !shaders.identifier_valid(name) {api.call_failf(call,api.INVALID_PARAMS,"program %q is not a Slang identifier: letters, digits and _, not starting with a digit (Rust_Metal)",name);return}
    if name=="pbr" {api.call_fail(call,api.INVALID_PARAMS,"pbr is the name of the standard model: give the program another name");return}
    if path,_,taken:=program_locate(s,name);taken {
        api.call_failf(call,api.INVALID_PARAMS,"a program named %s is in %s: change it with material.program.edit, or give the new one another name",name,unsaved_name(s,path))
        return
    }
    said:=shaders.program_directives(p.source)
    declared_domain,declared,has_declaration:=said.domain,said.name,said.name!=""
    kind:=p.kind!=""?p.kind:has_declaration?declared_domain:"surface"
    domain,known:=shaders.program_domain(kind)
    if !known {api.call_failf(call,api.INVALID_PARAMS,"kind %q is not a domain of programs: surface, postprocess, vfx or ui",kind);return}
    text:string
    if p.has_source {
        text,_=strings.replace_all(p.source,"\r\n","\n",context.temp_allocator)
        if !has_declaration || declared_domain!=kind || declared!=name {
            api.call_failf(call,api.INVALID_PARAMS,"the source has to declare `//! mirai %s %s` on a line of its own",kind,name)
            return
        }
    } else {
        text=shaders.program_template(domain,name,context.temp_allocator)
    }
    path:=project.path(s.project_root,"shaders",strings.concatenate({strings.to_lower(name,context.temp_allocator),".slang"},context.temp_allocator),allocator=context.temp_allocator)
    if file_exists(s,path) {
        api.call_failf(call,api.INVALID_PARAMS,"%s is there already and declares no program %s: give the new one another name",history.file_relative(s.project_root,path),name)
        return
    }
    _,sources:=program_folders(s)
    program_write(s,call,name,path,text,true,sources,"Create program")
}

// Checks the source of a program and, once it compiles, writes it in memory
// as a step of undo named label (no step when it is unchanged) and publishes
// the programs of the project. With errors nothing changes and the error data
// is the result of the check.
@(private)
program_write :: proc(s:^Session,call:^api.Call,name,path,text:string,changed:bool,sources:[]shaders.Source,label:string) {
    result:=program_check_run(s,path,text,sources)
    if result.error!="" {api.call_fail(call,api.SERVER_ERROR,result.error);return}
    if result.errors>0 {
        data:serial.Writer
        serial.writer_init(&data,0,call.allocator)
        serial.write_u8(&data,'{')
        check_fields_write(&data,name,&result)
        serial.write_u8(&data,'}')
        api.call_failf(call,api.INVALID_PARAMS,"The program does not compile (%d %s); nothing changed. The error data has the diagnostics, each with a fix",result.errors,result.errors==1?"error":"errors")
        call.error.data=string(serial.writer_bytes(&data))
        return
    }
    if !api_edit_begin(s,call,label) {return}
    written:=!changed || file_write(s,path,transmute([]u8)text,label)
    if !written {api.call_fail(call,api.SERVER_ERROR,api_asset_write_problem(s,path))}
    if !api_edit_end(s,call,written) {return}
    serial.write_u8(call.out,'{')
    check_fields_write(call.out,name,&result)
    api.write_bool(call.out,"publishing",programs_publishing(s))
    serial.write_u8(call.out,'}')
}

@(private)
graph_write :: proc(w:^serial.Writer,graph:^shaders.Surface_Graph) {
    kinds:=shaders.GRAPH_NODE_KINDS
    api.write_key(w,"nodes",true);serial.write_u8(w,'[')
    for node,i in graph.nodes {
        if i>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{')
        api.write_text(w,"id",node.id,true)
        api.write_text(w,"kind",kinds[node.kind])
        api.write_text(w,"label",node.label)
        api.write_text(w,"function",node.function)
        lines:=[2]f32{f32(node.first_line),f32(node.last_line)}
        api.write_numbers(w,"lines",lines[:])
        api.write_text(w,"text",node.text)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    api.write_key(w,"edges");serial.write_u8(w,'[')
    for edge,i in graph.edges {
        if i>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{')
        api.write_text(w,"from",graph.nodes[edge.from].id,true)
        api.write_text(w,"to",graph.nodes[edge.to].id)
        api.write_bool(w,"control",edge.control)
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
}

@(private)
api_program_inspect :: proc(s:^Session,call:^api.Call) {
    p,valid:=program_params(call)
    if !valid {return}
    domain,name,path,_,found:=program_file(s,call,p)
    if !found {return}
    text,read:=program_text(s,path)
    if !read {api.call_failf(call,api.SERVER_ERROR,"%s could not be read: the file is missing or locked",path);return}
    src:=shaders.surface_parse(text,context.temp_allocator)
    graph:=shaders.surface_graph(&src,context.temp_allocator)
    w:=call.out
    serial.write_u8(w,'{')
    api.write_text(w,"program",name,true)
    api.write_text(w,"kind",domain)
    api.write_text(w,"file",history.file_relative(s.project_root,path))
    api.write_text(w,"source",text)
    api.write_key(w,"parameters");serial.write_u8(w,'[')
    for field,i in src.parameters {
        if i>0 {serial.write_u8(w,',')}
        serial.write_u8(w,'{')
        api.write_text(w,"name",field.name,true)
        api.write_text(w,"type",field.type)
        api.write_int(w,"line",i64(field.line))
        api.write_key(w,"metadata")
        described:=false
        for m in src.metadata {
            if m.field!=field.name {continue}
            serial.text_write_raw(w,m.value)
            api.write_int(w,"metadata_line",i64(m.line))
            described=true
            break
        }
        if !described {serial.text_write_raw(w,"null")}
        serial.write_u8(w,'}')
    }
    serial.write_u8(w,']')
    api.write_key(w,"graph");serial.write_u8(w,'{')
    graph_write(w,&graph)
    serial.write_u8(w,'}')
    serial.write_u8(w,'}')
}

// Waits up to seconds until the previews have the shaders of the last change
// of a program: the stages they draw with, compiled first, or the whole
// generation; with viewport, until the frames have them: the stages the frames
// run, or the whole generation. With a window the editor goes on drawing
// frames meanwhile (agents and the user go on), a manual editor waits without
// advancing. False when they are not there yet or failed: message says why.
programs_wait :: proc(s:^Session,seconds:f64,viewport:=false) -> (ok:bool,message:string) {
    started:=time.tick_now()
    manual:=true
    if st:=api_state(s);st!=nil {manual=st.manual}
    for {
        programs_poll(s)
        if s.app.renderer!=nil {host.app_shaders_poll(s.app)}
        if !(viewport ? programs_drawing(s) : programs_previewing(s)) {break}
        if time.duration_seconds(time.tick_since(started))>seconds {return false,viewport?"the viewport does not have the last change of the shaders yet: the stages the frames run are still being compiled":"the previews do not have the last change of a program yet: the stages they draw with are still being compiled"}
        if !manual && api_frames(s,1,0)>0 {continue}
        time.sleep(20*time.Millisecond)
    }
    pub:=&s.build.programs
    if pub.failed {return false,fmt.tprintf("the programs of the project could not be published: %s",pub.message)}
    load:=pub.preview
    if viewport {
        if s.app.renderer!=nil && pub.refused {
            if s.app.shaders.state==.Stale {return false,"the shaders of the engine bind or lay out otherwise than when this editor was built, and it draws with those it was built with: mirai build editor builds it again and its session takes it"}
            return false,"the renderer refused the shaders; engine.diagnostics has why"
        }
        load=pub.running!=0?pub.running:pub.whole
    }
    if s.app.renderer!=nil && s.app.shaders.published<load {return false,"the renderer refused the shaders of the programs; engine.diagnostics has why"}
    return true,""
}

