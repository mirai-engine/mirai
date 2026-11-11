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
// Vfx or UI) as the agent works on it, as its file holds it.
// check compiles it without publishing; create and edit write the source as
// a step of undo (attributed to the turn that asks) once it
// compiles, and publish the programs of the project; inspect gives the
// source with its parameters and the graph derived from it. The domain of a
// program is the one its source declares.

@(private)
Api_Program_Result :: struct {
    program:string,
    kind:string `mirai:"label=surface; postprocess; vfx or ui"`,
    file:string `mirai:"label=The program as its diagnostics name it"`,
    compiled:bool `mirai:"label=Every stage of the check compiled: raster and rays for a Surface program (it also runs on ray hits); the stages of the engine that run the others"`,
    errors:int,
    warnings:int,
    parameters_size:int `mirai:"label=Bytes of its struct Parameters"`,
    diagnostics:[]shaders.Diagnostic `mirai:"label=file is under the project or the engine; line and column from 1, 0 for what is not at a place; stage: the compilation that said it, empty for the rules of the check; node: of the graph of material.program.inspect at that line"`,
    publishing:bool `mirai:"optional,label=Of material.program.create and .edit: the renderer does not have the whole generation yet; the stages the previews draw with come first (material.preview.capture waits for them) and then the rest for the viewport"`,
}

@(private)
Api_Program_Inspect :: struct {
    program:string,
    kind:string `mirai:"label=surface; postprocess; vfx or ui"`,
    file:string `mirai:"label=Its .slang: from the folder of the project when it is in it"`,
    source:string,
    parameters:[]Api_Program_Parameter `mirai:"label=The fields of its struct Parameters"`,
    graph:Api_Program_Graph `mirai:"label=Derived from the source and read only: the source is what changes"`,
}

@(private)
Api_Program_Parameter :: struct {
    name,type:string,
    line:int,
    metadata:serial.Json `mirai:"label=The JSON of its //! parameter line; null without one"`,
    metadata_line:int `mirai:"optional"`,
}

@(private)
Api_Program_Graph :: struct {
    nodes:[]Api_Program_Node,
    edges:[]Api_Program_Edge,
}

@(private)
Api_Program_Node :: struct {
    id:string `mirai:"label=Stable across edits of the source: Program/function/variable; the n-th write with #n"`,
    kind:string `mirai:"label=input; parameter; texture; constant; local; call; if; loop; output; surface; return or code"`,
    label,function:string,
    lines:[2]int `mirai:"label=The first and the last"`,
    text:string,
}

@(private)
Api_Program_Edge :: struct {
    from,to:string,
    control:bool `mirai:"label=to is inside the branch or loop from; otherwise to takes the value of from"`,
}

Api_Program_Params_Edits :: struct {
    old,new:string,
}
Api_Program_Params :: struct {
    program:string `mirai:"optional,label=A program by name (Surface, PostProcess, Vfx or UI), or the path of its .slang under the project"`,
    material:string `mirai:"optional,label=A material whose program it is: its path under the assets folder, or its id"`,
    source:string `mirai:"optional,label=check: the text to check in place of the file; edit: the whole new source"`,
    edits:[]Api_Program_Params_Edits `mirai:"optional,label=edit: replacements applied in order; each old occurs once in the source"`,
}

Api_Material_Program_Create_Params_Kind :: enum u8 {surface,postprocess,vfx,ui}
Api_Material_Program_Create_Params :: struct {
    program:string `mirai:"label=The name of the new program: a Slang identifier no program of the project, its plugins or the engine has"`,
    kind:Api_Material_Program_Create_Params_Kind `mirai:"optional,label=Its domain; without it the one source declares, else surface"`,
    source:string `mirai:"optional,label=Its whole source, declaring //! mirai <kind> <program>; without it a template of the domain that compiles"`,
}

@(private)
programs_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="material.program.check",params=type_info_of(Api_Program_Params),summary="Compiles a program without publishing it, where it runs (a Surface program for raster and for ray hits), and reads its source for the usual mistakes.",result=type_info_of(Api_Program_Result),flags={.Read_Only,.Idempotent},run=api_program_check})
    api_register(s,st,{name="material.program.create",params=type_info_of(Api_Material_Program_Create_Params),summary="Makes a new program in the shaders folder of the project once it compiles, writing its .slang as one undo step, and publishes the programs of the project.",result=type_info_of(Api_Program_Result),run=api_program_create})
    api_register(s,st,{name="material.program.edit",params=type_info_of(Api_Program_Params),summary="Changes the source of a program once it compiles, writing its .slang as one undo step, and publishes the programs of the project.",result=type_info_of(Api_Program_Result),run=api_program_edit})
    api_register(s,st,{name="material.program.inspect",params=type_info_of(Api_Program_Params),summary="The source of a program, the fields of its struct Parameters and the graph derived from the source.",result=type_info_of(Api_Program_Inspect),flags={.Read_Only,.Idempotent},run=api_program_inspect})
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
program_file :: proc(s:^Session,call:^api.Call,p:^Api_Program_Params) -> (domain,name,path:string,sources:[]shaders.Source,ok:bool) {
    _,sources=program_folders(s)
    if p.program=="" && p.material=="" {api.call_fail(call,api.INVALID_PARAMS,"program or material is required");return}
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

// The .slang that declares a program of that name, where programs come from.
program_locate :: proc(s:^Session,name:string) -> (path:string,sources:[]shaders.Source,ok:bool) {
    folders:[dynamic]string
    folders,sources=program_folders(s)
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

// The source of a program as its file holds it.
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
program_result :: proc(name:string,result:^shaders.Check_Result) -> Api_Program_Result {
    domains:=shaders.PROGRAM_DOMAINS
    return {program=name,kind=domains[result.domain],file=result.file,compiled=result.compiled,errors=result.errors,warnings=result.warnings,parameters_size=result.parameters_size,diagnostics=result.diagnostics}
}

@(private)
api_program_check :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Program_Params)
    _,name,path,sources,found:=program_file(s,call,p)
    if !found {return}
    text,read:=p.source,true
    if !api.call_given(call,"source") {text,read=program_text(s,path)}
    if !read {api.call_failf(call,api.SERVER_ERROR,"%s could not be read: the file is missing or locked",path);return}
    result:=program_check_run(s,path,text,sources)
    if result.error!="" {api.call_fail(call,api.SERVER_ERROR,result.error);return}
    api.call_result(call,Api_Program_Result)^=program_result(name,&result)
}

// The source an edit leaves: the whole new one, or the replacements in order.
@(private)
program_edited :: proc(call:^api.Call,p:^Api_Program_Params,current:string) -> (text:string,ok:bool) {
    given:=api.call_given(call,"source")
    if given && len(p.edits)>0 {api.call_fail(call,api.INVALID_PARAMS,"give source or edits, not both");return}
    if given {
        text,_=strings.replace_all(p.source,"\r\n","\n",context.temp_allocator)
        return text,true
    }
    if len(p.edits)==0 {api.call_fail(call,api.INVALID_PARAMS,"source or edits is required");return}
    text=current
    for edit,i in p.edits {
        if edit.old=="" {api.call_failf(call,api.INVALID_PARAMS,"edits[%d].old is empty: give the text to replace",i);return}
        old,_:=strings.replace_all(edit.old,"\r\n","\n",context.temp_allocator)
        new,_:=strings.replace_all(edit.new,"\r\n","\n",context.temp_allocator)
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
    p:=api.call_params(call,Api_Program_Params)
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
    p:=api.call_params(call,Api_Material_Program_Create_Params)
    if !s.has_project {api.call_fail(call,api.SERVER_ERROR,"No project is open: a program is made in the shaders folder of a project; open one");return}
    name:=p.program
    if !shaders.identifier_valid(name) {api.call_failf(call,api.INVALID_PARAMS,"program %q is not a Slang identifier: letters, digits and _, not starting with a digit (Rust_Metal)",name);return}
    if name=="pbr" {api.call_fail(call,api.INVALID_PARAMS,"pbr is the name of the standard model: give the program another name");return}
    if path,_,taken:=program_locate(s,name);taken {
        api.call_failf(call,api.INVALID_PARAMS,"a program named %s is in %s: change it with material.program.edit, or give the new one another name",name,file_name(s,path))
        return
    }
    said:=shaders.program_directives(p.source)
    declared_domain,declared,has_declaration:=said.domain,said.name,said.name!=""
    kind:=fmt.tprint(p.kind) if api.call_given(call,"kind") else declared_domain if has_declaration else "surface"
    domain,known:=shaders.program_domain(kind)
    if !known {api.call_failf(call,api.INVALID_PARAMS,"kind %q is not a domain of programs: surface, postprocess, vfx or ui",kind);return}
    text:string
    if api.call_given(call,"source") {
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

// Checks the source of a program and, once it compiles, writes its file
// as a step of undo named label (no step when it is unchanged) and publishes
// the programs of the project. With errors nothing changes and the error data
// is the result of the check.
@(private)
program_write :: proc(s:^Session,call:^api.Call,name,path,text:string,changed:bool,sources:[]shaders.Source,label:string) {
    result:=program_check_run(s,path,text,sources)
    if result.error!="" {api.call_fail(call,api.SERVER_ERROR,result.error);return}
    if result.errors>0 {
        data,_:=serial.text_encode(program_result(name,&result),.Line,call.allocator,sparse=true)
        api.call_failf(call,api.INVALID_PARAMS,"The program does not compile (%d %s); nothing changed. The error data has the diagnostics, each with a fix",result.errors,result.errors==1?"error":"errors")
        call.error.data=string(data)
        return
    }
    if !api_edit_begin(s,call,label) {return}
    written:=!changed || file_write(s,path,transmute([]u8)text,label)
    if !written {api.call_fail(call,api.SERVER_ERROR,api_asset_write_problem(s,path))}
    if !api_edit_end(s,call,written) {return}
    r:=api.call_result(call,Api_Program_Result)
    r^=program_result(name,&result)
    r.publishing=programs_publishing(s)
}


@(private)
api_program_inspect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Program_Params)
    domain,name,path,_,found:=program_file(s,call,p)
    if !found {return}
    text,read:=program_text(s,path)
    if !read {api.call_failf(call,api.SERVER_ERROR,"%s could not be read: the file is missing or locked",path);return}
    src:=shaders.surface_parse(text,context.temp_allocator)
    graph:=shaders.surface_graph(&src,context.temp_allocator)
    r:=api.call_result(call,Api_Program_Inspect)
    r^={program=name,kind=domain,file=history.file_relative(s.project_root,path),source=text}
    r.parameters=make([]Api_Program_Parameter,len(src.parameters),call.allocator)
    for &row,i in r.parameters {
        field:=src.parameters[i]
        row={name=field.name,type=field.type,line=int(field.line),metadata="null"}
        for m in src.metadata {if m.field==field.name {row.metadata,row.metadata_line=serial.Json(m.value),int(m.line);break}}
    }
    kinds:=shaders.GRAPH_NODE_KINDS
    r.graph.nodes=make([]Api_Program_Node,len(graph.nodes),call.allocator)
    for &row,i in r.graph.nodes {
        node:=graph.nodes[i]
        row={id=node.id,kind=kinds[node.kind],label=node.label,function=node.function,lines={int(node.first_line),int(node.last_line)},text=node.text}
    }
    r.graph.edges=make([]Api_Program_Edge,len(graph.edges),call.allocator)
    for &row,i in r.graph.edges {edge:=graph.edges[i];row={from=graph.nodes[edge.from].id,to=graph.nodes[edge.to].id,control=edge.control}}
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

