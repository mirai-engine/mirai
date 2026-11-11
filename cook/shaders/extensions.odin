package shaders

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:std/base"

// What the shaders of a project and of its plugins ask of the stages of the
// engine besides material programs. A source says it with lines of its own:
//
//   //! mirai frame <Struct> <name>          it declares <Struct>, which the constants of every view hold as <name>
//   //! mirai needs nested_views             the stages are compiled with nested views
//   //! mirai needs instance_ids             the G-buffer keeps the instance that drew each pixel
//   //! mirai hook ray <function>            it defines the ray hook; one source of a generation may
//   //! mirai hook lights <count> <light>    it defines lights of its own; those of every source add up
//   //! mirai hook probes <function>         it defines the probe hook; one source of a generation may
//   //! mirai hook vertex <function>         it defines the vertex hook of batches; one source of a generation may
//   //! mirai constant <NAME> <int|uint|float> <file.odin>
//                                            it shares <NAME> with the Odin code next to it (owned_constants)
//
// A source with a frame line is included before the constants of the frame
// are declared and can use no declaration of the engine. One with ray or light
// hooks is included after the lighting includes, by the stages that trace.
// The probe hook goes in a source of its own, which every stage that reads
// the probe volume includes before it: it can use the frame constants and the
// helpers of common.slang. So does the vertex hook, which the G-buffer
// includes after the scene declarations: float3 f(float3 world, float3 pivot,
// float4 color, float4 params, float time) gives where a vertex of an
// instance of a batch is at `time` (frame.time), from where it is at rest,
// the place of its instance, its vertex color and the four numbers of its
// batch (render.Batch_Desc.vertex). A source named as a stage (name.comp.slang,
// name.vert.slang, name.frag.slang) is compiled as one more stage of the
// generation, which the renderer hands to the extension by its name.
EXTENSIONS_INCLUDE :: "extensions.slang"
HOOKS_INCLUDE :: "extension_hooks.slang"
PROBES_INCLUDE :: "extension_probes.slang"
VERTEX_INCLUDE :: "extension_vertex.slang"

Frame_Field :: struct {
    name,type:string,
    include:string, // of its source, below the include folder of the generation
    offset,size:int,
}

Light_Hook :: struct {count,light:string}

Extensions :: struct {
    nested:bool,
    instance_ids:bool,
    fields:[]Frame_Field,
    frame_size:int, // of Frame_Data with what the generation adds; 0 without anything: render.Gpu_Frame alone
    ray:string,
    lights:[]Light_Hook,
    hooks:[]string, // includes of the sources with ray or light hooks
    probes:string,
    probes_include:string, // of the source of the probe hook
    vertex:string,
    vertex_include:string, // of the source of the vertex hook
}

@(private)
Extension_Folder :: struct {label,folder:string}

// The folders programs and extensions come from besides the engine: the
// project first, then each plugin. A folder that does not exist is left out.
@(private)
extension_folders :: proc(files:^Sources,project:string,sources:[]Source,allocator:=context.allocator) -> []Extension_Folder {
    folders:=make([dynamic]Extension_Folder,allocator)
    exists :: proc(files:^Sources,folder:string) -> bool {return sources_listing(files,folder,true).hash!=""}
    if project!="" {
        folder:=path_join(project,"shaders",allocator=allocator)
        if exists(files,folder) {append(&folders,Extension_Folder{"project",folder})}
    }
    for source in sources {
        folder:=path_clean(source.folder,allocator)
        if !exists(files,folder) {continue}
        append(&folders,Extension_Folder{strings.concatenate({"plugins/",source.name},allocator),folder})
    }
    return folders[:]
}

// The folder, under the include folder of a generation, of the includes with
// the constants the shaders of the project and of each plugin share with their
// own Odin code: constants/project.slang, constants/plugins/<name>.slang.
OWNED_CONSTANTS_FOLDER :: "constants"

// A line of an Odin source that declares a constant of its package, and what
// it declares it as: `NAME :: 8` or `NAME :u32: 8`, without the comment after it.
@(private)
odin_declaration :: proc(line:string) -> (name,value:string,ok:bool) {
    end:=0
    for end<len(line) && is_word(line[end]) {end+=1}
    after:=skip_spaces(line[end:])
    if end==0 || !strings.has_prefix(after,":") {return}
    typed:=strings.index_any(after[1:],":=")
    if typed<0 || after[1+typed]!=':' {return}
    value=after[typed+2:]
    if comment:=strings.index(value,"//");comment>=0 {value=value[:comment]}
    return line[:end],strings.trim_space(value),true
}

// What an Odin source declares the constant `name` as.
@(private)
odin_constant :: proc(text,name:string) -> (value:string,found:bool) {
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if declared,as,ok:=odin_declaration(line);ok && declared==name {return as,true}
    }
    return
}

// The include with the constants the sources of a folder share with the Odin
// code next to them. A `//! mirai constant` line names the constant, the type
// of its Slang literal and the Odin source that declares it, from the folder
// of the line's own source: Odin holds the only declaration, and the shaders
// of the folder include the generated file (<constants/plugins/<name>.slang>)
// instead of writing the value. text is "" for a folder that shares none.
// The Odin sources are read through `files`: the stamp of a generation
// follows them. Both results are in the temporary allocator.
@(private)
owned_constants :: proc(files:^Sources,entry:Extension_Folder) -> (text,problem:string) {
    USAGE :: "`//! mirai constant <NAME> <int|uint|float> <file.odin>`"
    b:=strings.builder_make(context.temp_allocator)
    names:=make([dynamic]string,context.temp_allocator)
    for path in sources_below(files,entry.folder) {
        if !strings.has_suffix(path,".slang") {continue}
        rest:=string(sources_file(files,path).data)
        for line in strings.split_lines_iterator(&rest) {
            if !strings.has_prefix(line,"//!") {continue}
            words:=strings.fields(line,context.temp_allocator)
            if len(words)<3 || words[0]!="//!" || words[1]!="mirai" || words[2]!="constant" {continue}
            if len(words)!=6 || !identifier_valid(words[3]) || !strings.has_suffix(words[5],".odin") {return "",fmt.tprintf("%s: %s",path,USAGE)}
            name:=words[3]
            for other in names {
                if other==name {return "",fmt.tprintf("%s: the shaders of %s already share %s",path,entry.label,name)}
            }
            append(&names,name)
            declared:=path_clean(path_join(path_parent(path),words[5],allocator=context.temp_allocator),context.temp_allocator)
            odin:=sources_file(files,declared)
            if !odin.found {return "",fmt.tprintf("%s: could not read %s, which should declare %s",path,declared,name)}
            literal,found:=odin_constant(string(odin.data),name)
            if !found {return "",fmt.tprintf("%s: %s does not declare the constant %s (`%s :: 8`)",path,declared,name,name)}
            written:=false
            switch words[4] {
            case "int":
                if value,ok:=strconv.parse_i64(literal);ok {fmt.sbprintf(&b,"#define %s %d\n",name,value);written=true}
            case "uint":
                if value,ok:=strconv.parse_u64(literal);ok {fmt.sbprintf(&b,"#define %s %du\n",name,value);written=true}
            case "float":
                if value,ok:=strconv.parse_f64(literal);ok {fmt.sbprintf(&b,"#define %s %s\n",name,number(f32(value)));written=true}
            case:
                return "",fmt.tprintf("%s: %s",path,USAGE)
            }
            if !written {return "",fmt.tprintf("%s: %s declares %s as `%s`, which is not the literal of a %s; a shared constant is declared with its number",path,declared,name,literal,words[4])}
        }
    }
    if len(names)==0 {return "",""}
    guard,_:=strings.replace_all(strings.to_upper(entry.label,context.temp_allocator),"/","_",context.temp_allocator)
    return fmt.tprintf("// Generated by mirai shaders from the Odin code of %s. DO NOT EDIT.\n#ifndef MIRAI_CONSTANTS_%s_SLANG\n#define MIRAI_CONSTANTS_%s_SLANG\n%s#endif\n",entry.label,guard,guard,strings.to_string(b)),""
}

// Writes the include of the shared constants of each folder that has them
// into the include folder of a generation or of a check. shared: the text of
// them all, in the temporary allocator; problem, in `allocator`.
@(private)
owned_constants_write :: proc(files:^Sources,include,project:string,sources:[]Source,allocator:=context.allocator) -> (shared,problem:string) {
    every:=strings.builder_make(context.temp_allocator)
    if folder:=path_join(include,OWNED_CONSTANTS_FOLDER,allocator=context.temp_allocator);os.exists(folder) {base.remove_all(folder)}
    for entry in extension_folders(files,project,sources,context.temp_allocator) {
        text,invalid:=owned_constants(files,entry)
        if invalid!="" {return "",strings.clone(invalid,allocator)}
        if text=="" {continue}
        target:=path_join(include,OWNED_CONSTANTS_FOLDER,strings.concatenate({entry.label,".slang"},context.temp_allocator),allocator=context.temp_allocator)
        os.make_directory_all(path_parent(target))
        if !write_file(target,transmute([]u8)text) {return "",fmt.aprintf("could not write %s",target,allocator=allocator)}
        strings.write_string(&every,text)
    }
    return strings.to_string(every),""
}

// Reads what the sources of the folders ask for and writes the two includes
// of the generation into `output`/include. The layout of the constants is
// reflected with the flags the stages are compiled with. Everything returned
// is in `allocator`.
extensions_generate :: proc(runner:^Runner,root,project,output,slangc:string,sources:[]Source,files:^Sources,allocator:=context.allocator) -> (extensions:Extensions,error:string) {
    include:=path_join(output,"include",allocator=context.temp_allocator)
    fields:=make([dynamic]Frame_Field,allocator)
    lights:=make([dynamic]Light_Hook,allocator)
    hooks:=make([dynamic]string,allocator)
    for entry in extension_folders(files,project,sources,context.temp_allocator) {
        for path in sources_below(files,entry.folder) {
            if !strings.has_suffix(path,".slang") {continue}
            source:=sources_file(files,path)
            if !source.found {return {},fmt.aprintf("could not read %s",path,allocator=allocator)}
            relative,_:=path_relative(path,entry.folder)
            included:=strings.concatenate({"programs/",entry.label,"/",relative},allocator)
            frame,hooked,probed,vertexed:=false,false,false,false
            rest:=string(source.data)
            for line in strings.split_lines_iterator(&rest) {
                if !strings.has_prefix(line,"//!") {continue}
                words:=strings.fields(line,context.temp_allocator)
                if len(words)<3 || words[0]!="//!" || words[1]!="mirai" {continue}
                switch words[2] {
                case "frame":
                    if len(words)!=5 || !identifier_valid(words[3]) || !identifier_valid(words[4]) {return {},fmt.aprintf("%s: `//! mirai frame <Struct> <name>`",path,allocator=allocator)}
                    for field in fields {if field.name==words[4] {return {},fmt.aprintf("%s: two sources name the frame constants %s",path,words[4],allocator=allocator)}}
                    append(&fields,Frame_Field{name=strings.clone(words[4],allocator),type=strings.clone(words[3],allocator),include=included})
                    frame=true
                case "needs":
                    switch {
                    case len(words)==4 && words[3]=="nested_views": extensions.nested=true
                    case len(words)==4 && words[3]=="instance_ids": extensions.instance_ids=true
                    case: return {},fmt.aprintf("%s: `//! mirai needs nested_views` or `//! mirai needs instance_ids`",path,allocator=allocator)
                    }
                case "hook":
                    switch {
                    case len(words)==5 && words[3]=="ray" && identifier_valid(words[4]):
                        if extensions.ray!="" {return {},fmt.aprintf("%s: the generation already has a ray hook (%s)",path,extensions.ray,allocator=allocator)}
                        extensions.ray=strings.clone(words[4],allocator)
                    case len(words)==6 && words[3]=="lights" && identifier_valid(words[4]) && identifier_valid(words[5]):
                        append(&lights,Light_Hook{strings.clone(words[4],allocator),strings.clone(words[5],allocator)})
                    case len(words)==5 && words[3]=="probes" && identifier_valid(words[4]):
                        if extensions.probes!="" {return {},fmt.aprintf("%s: the generation already has a probe hook (%s)",path,extensions.probes,allocator=allocator)}
                        extensions.probes=strings.clone(words[4],allocator)
                        extensions.probes_include=included
                        probed=true
                        continue
                    case len(words)==5 && words[3]=="vertex" && identifier_valid(words[4]):
                        if extensions.vertex!="" {return {},fmt.aprintf("%s: the generation already has a vertex hook (%s)",path,extensions.vertex,allocator=allocator)}
                        extensions.vertex=strings.clone(words[4],allocator)
                        extensions.vertex_include=included
                        vertexed=true
                        continue
                    case:
                        return {},fmt.aprintf("%s: `//! mirai hook ray <function>`, `//! mirai hook lights <count> <light>`, `//! mirai hook probes <function>` or `//! mirai hook vertex <function>`",path,allocator=allocator)
                    }
                    hooked=true
                }
            }
            if frame && (hooked || probed || vertexed) {return {},fmt.aprintf("%s: frame constants and hooks go in separate sources",path,allocator=allocator)}
            if hooked && probed {return {},fmt.aprintf("%s: the probe hook goes in a source of its own: the stages read the probes before the lighting the other hooks use",path,allocator=allocator)}
            if vertexed && (hooked || probed) {return {},fmt.aprintf("%s: the vertex hook goes in a source of its own: the G-buffer includes it, without the lighting or the probes",path,allocator=allocator)}
            if hooked {append(&hooks,included)}
        }
    }
    extensions.fields,extensions.lights,extensions.hooks=fields[:],lights[:],hooks[:]

    os.make_directory_all(include)
    if !write_file(path_join(include,EXTENSIONS_INCLUDE,allocator=context.temp_allocator),extensions_text(extensions,extensions_features(extensions),context.temp_allocator)) {return {},fmt.aprintf("could not write %s",EXTENSIONS_INCLUDE,allocator=allocator)}

    text:=strings.builder_make(context.temp_allocator)
    strings.write_string(&text,"// Generated by mirai shaders. DO NOT EDIT.\n#ifndef MIRAI_EXTENSION_HOOKS_SLANG\n#define MIRAI_EXTENSION_HOOKS_SLANG\n")
    for hook in hooks {fmt.sbprintf(&text,"#include \"%s\"\n",hook)}
    if extensions.ray!="" {
        fmt.sbprintf(&text,"bool mirai_ray_gate(float3 origin,float3 direction,float t_max,out float t,out float3 next_origin,out float3 next_direction) {{return %s(origin,direction,t_max,t,next_origin,next_direction);}}\n",extensions.ray)
    }
    if len(lights)>0 {
        strings.write_string(&text,"uint mirai_extension_light_count() {return ")
        for hook,i in lights {fmt.sbprintf(&text,"%s%s()","+" if i>0 else "",hook.count)}
        strings.write_string(&text,";}\nbool mirai_extension_light(uint index,float3 position,float3 normal,float2 point,out Extension_Light light) {\n    uint count;\n")
        for hook in lights {fmt.sbprintf(&text,"    count=%s();if (index<count) return %s(index,position,normal,point,light);index-=count;\n",hook.count,hook.light)}
        strings.write_string(&text,"    light=(Extension_Light)0;\n    return false;\n}\n")
    }
    strings.write_string(&text,"#endif\n")
    if !write_file(path_join(include,HOOKS_INCLUDE,allocator=context.temp_allocator),text.buf[:]) {return {},fmt.aprintf("could not write %s",HOOKS_INCLUDE,allocator=allocator)}

    text=strings.builder_make(context.temp_allocator)
    strings.write_string(&text,"// Generated by mirai shaders. DO NOT EDIT.\n#ifndef MIRAI_EXTENSION_PROBES_SLANG\n#define MIRAI_EXTENSION_PROBES_SLANG\n")
    if extensions.probes!="" {
        fmt.sbprintf(&text,"#include \"%s\"\n",extensions.probes_include)
        fmt.sbprintf(&text,"float mirai_probe_gate(float3 position,float3 direction,out float3 beyond,out float3 front,out float4 through[3]) {{return %s(position,direction,beyond,front,through);}}\n",extensions.probes)
    }
    strings.write_string(&text,"#endif\n")
    if !write_file(path_join(include,PROBES_INCLUDE,allocator=context.temp_allocator),text.buf[:]) {return {},fmt.aprintf("could not write %s",PROBES_INCLUDE,allocator=allocator)}

    text=strings.builder_make(context.temp_allocator)
    strings.write_string(&text,"// Generated by mirai shaders. DO NOT EDIT.\n#ifndef MIRAI_EXTENSION_VERTEX_SLANG\n#define MIRAI_EXTENSION_VERTEX_SLANG\n")
    if extensions.vertex!="" {
        fmt.sbprintf(&text,"#include \"%s\"\n",extensions.vertex_include)
        fmt.sbprintf(&text,"float3 mirai_batch_vertex(float3 world,float3 pivot,float4 color,float4 params,float time) {{return %s(world,pivot,color,params,time);}}\n",extensions.vertex)
    }
    strings.write_string(&text,"#endif\n")
    if !write_file(path_join(include,VERTEX_INCLUDE,allocator=context.temp_allocator),text.buf[:]) {return {},fmt.aprintf("could not write %s",VERTEX_INCLUDE,allocator=allocator)}

    if !extensions.nested && len(fields)==0 {return extensions,""}
    // Where Slang puts what the generation adds to the constants.
    temporary,temporary_error:=os.make_directory_temp("","mirai-frame-reflection-*",context.temp_allocator)
    if temporary_error!=nil {return {},strings.clone("could not create the temporary reflection folder",allocator)}
    temporary=path_clean(temporary,context.temp_allocator)
    defer base.remove_all(temporary)
    wrapper:=path_join(temporary,"frame.comp.slang",allocator=context.temp_allocator)
    reflected:=path_join(temporary,"frame.json",allocator=context.temp_allocator)
    source:="#include \"native.slang\"\n#include \"common.slang\"\n"+
        "[[vk::binding(0,0)]] ConstantBuffer<Frame_Data> mirai_frame;\n"+
        "[[vk::binding(1,0)]] RWStructuredBuffer<uint> mirai_result;\n"+
        "[shader(\"compute\")][numthreads(1,1,1)] void main(uint3 id:SV_DispatchThreadID) {mirai_result[id.x]=mirai_frame.frame_index;}\n"
    if !write_file(wrapper,transmute([]u8)source) {return {},strings.clone("could not write the reflection program of the frame",allocator)}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,slangc,wrapper)
    append(&command,..SLANG_FLAGS)
    append(&command,"-stage","compute","-I",include)
    for folder in ENGINE_INCLUDES {append(&command,"-I",path_join(root,folder,allocator=context.temp_allocator))}
    append(&command,..SPIRV_FLAGS)
    append(&command,"-o",path_join(temporary,"frame.spv",allocator=context.temp_allocator),"-reflection-json",reflected)
    if result,ran:=tool_run(runner,command[:],context.temp_allocator);!ran {return {},fmt.aprintf("the frame constants of the extensions do not compile:\n%s",result,allocator=allocator)}
    data,readable:=read_json(reflected,context.temp_allocator)
    if !readable {return {},strings.clone("Slang did not write the reflection of the frame",allocator)}
    if problem:=extensions_frame_read(&extensions,data);problem!="" {return {},strings.clone(problem,allocator)}
    return extensions,""
}

// Where the reflection of Frame_Data puts what the generation adds to it: its
// size, and the offset and size of each field of the extensions. The nested
// views go right after the part render.Gpu_Frame mirrors (FRAME_MIRROR_LAST,
// which the generated table of render asserts), where the renderer writes
// them. problem says what does not fit, in the temporary allocator.
@(private)
extensions_frame_read :: proc(extensions:^Extensions,data:json.Object) -> (problem:string) {
    parameters,_:=data["parameters"].(json.Array)
    for value in parameters {
        parameter,_:=value.(json.Object)
        if json_text(parameter["name"])!="mirai_frame" {continue}
        type,_:=parameter["type"].(json.Object)
        element,_:=type["elementType"].(json.Object)
        sizes,_:=element["sizes"].(json.Array)
        for entry in sizes {
            size,_:=entry.(json.Object)
            if json_text(size["kind"])=="uniform" {extensions.frame_size,_=json_int(size["value"])}
        }
        members,_:=element["fields"].(json.Array)
        binding_of :: proc(members:json.Array,name:string) -> (offset,size:int,found:bool) {
            for entry in members {
                member,_:=entry.(json.Object)
                if json_text(member["name"])!=name {continue}
                binding,_:=member["binding"].(json.Object)
                offset,found=json_int(binding["offset"])
                size,_=json_int(binding["size"])
                return
            }
            return
        }
        last,last_size,has_last:=binding_of(members,FRAME_MIRROR_LAST)
        if !has_last {return fmt.tprintf("the frame constants have no %s",FRAME_MIRROR_LAST)}
        if nested,_,has:=binding_of(members,"nested");extensions.nested && (!has || nested!=last+last_size) {
            return "the nested views are not where the renderer writes them in the frame constants"
        }
        for &field in extensions.fields {
            found:bool
            if field.offset,_,found=binding_of(members,field.name);!found {return fmt.tprintf("%s is not in the frame constants",field.name)}
        }
        for &field,i in extensions.fields {
            end:=extensions.fields[i+1].offset if i+1<len(extensions.fields) else extensions.frame_size
            field.size=end-field.offset
            if field.size<=0 || field.offset%4!=0 {return fmt.tprintf("%s: the frame constants need a struct of whole words",field.type)}
        }
        return ""
    }
    return "the reflection has no frame constants"
}

// The macros extensions.slang defines. A stage is compiled against one that
// defines only those its sources name: a macro no source of the stage names
// cannot change its code, and without it the stage is the same compilation
// as in a generation that lacks the feature. Frame_Extensions is no name: only
// sources of the project and its plugins read the fields it adds, so a stage
// has it when one of its sources is theirs (jobs_tailor).
Extension_Feature :: enum u8 {Nested_Views,Instance_Ids,Hook_Ray,Hook_Lights,Hook_Probes,Hook_Vertex,Frame_Extensions}
Extension_Features :: bit_set[Extension_Feature;u8]
@(private)
EXTENSION_MACROS :: [Extension_Feature]string{
    .Nested_Views="MIRAI_NESTED_VIEWS",.Instance_Ids="MIRAI_INSTANCE_IDS",.Hook_Ray="MIRAI_HOOK_RAY",.Hook_Lights="MIRAI_HOOK_LIGHTS",
    .Hook_Probes="MIRAI_HOOK_PROBES",.Hook_Vertex="MIRAI_HOOK_VERTEX",.Frame_Extensions="MIRAI_FRAME_EXTENSIONS",
}

// What the extensions of a generation define.
@(private)
extensions_features :: proc(extensions:Extensions) -> (features:Extension_Features) {
    if extensions.nested {features+={.Nested_Views}}
    if extensions.instance_ids {features+={.Instance_Ids}}
    if extensions.ray!="" {features+={.Hook_Ray}}
    if len(extensions.lights)>0 {features+={.Hook_Lights}}
    if extensions.probes!="" {features+={.Hook_Probes}}
    if extensions.vertex!="" {features+={.Hook_Vertex}}
    if len(extensions.fields)>0 {features+={.Frame_Extensions}}
    return
}

// extensions.slang with the macros of these features. The includes of the
// sources of the frame constants go with Frame_Extensions. Without features it
// is the same whatever the extensions are.
@(private)
extensions_text :: proc(extensions:Extensions,features:Extension_Features,allocator:=context.allocator) -> []u8 {
    macros:=EXTENSION_MACROS
    text:=strings.builder_make(allocator)
    strings.write_string(&text,"// Generated by mirai shaders. DO NOT EDIT.\n#ifndef MIRAI_EXTENSIONS_SLANG\n#define MIRAI_EXTENSIONS_SLANG\n")
    for feature in ([]Extension_Feature{.Nested_Views,.Instance_Ids,.Hook_Ray,.Hook_Lights,.Hook_Probes,.Hook_Vertex}) {
        if feature in features {fmt.sbprintf(&text,"#define %s 1\n",macros[feature])}
    }
    // The nested views come before the fields of the extensions in Frame_Data:
    // a stage that reads those declares them too.
    if .Nested_Views in features || (.Frame_Extensions in features && extensions.nested) {strings.write_string(&text,"#define MIRAI_FRAME_NESTED 1\n")}
    if .Frame_Extensions in features {
        // A field may share its source with another one.
        for field,i in extensions.fields {
            repeated:=false
            for earlier in extensions.fields[:i] {repeated||=earlier.include==field.include}
            if !repeated {fmt.sbprintf(&text,"#include \"%s\"\n",field.include)}
        }
        strings.write_string(&text,"#define MIRAI_FRAME_EXTENSIONS")
        for field in extensions.fields {fmt.sbprintf(&text," %s %s;",field.type,field.name)}
        strings.write_string(&text,"\n")
    }
    strings.write_string(&text,"#endif\n")
    return text.buf[:]
}

// The macros of extensions.slang a text names as whole identifiers.
@(private)
extension_macros :: proc(text:string) -> (features:Extension_Features) {
    PREFIX :: "MIRAI_"
    rest,offset:=text,0
    for {
        at:=strings.index(rest,PREFIX)
        if at<0 {return}
        start:=offset+at
        end:=start+len(PREFIX)
        for end<len(text) && is_word(text[end]) {end+=1}
        if start==0 || !is_word(text[start-1]) {
            for macro,feature in EXTENSION_MACROS {
                if feature!=.Frame_Extensions && text[start:end]==macro {features+={feature}}
            }
        }
        rest=text[end:]
        offset=end
    }
}
