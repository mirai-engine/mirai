package shaders

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "mirai:asset"
import "mirai:render/abi"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// Programs: Slang sources that declare `//! mirai surface Name`,
// `//! mirai postprocess Name`, `//! mirai vfx Name` or `//! mirai ui Name`,
// a namespace Name with Parameters and the functions of its domain (evaluate;
// initialize, update and render for Vfx, which also has Attributes), and optional
// `//! parameter field {json}` metadata. Their parameters travel to the GPU
// as 256 bytes of words, and the Attributes of a Vfx program as at most
// ATTRIBUTE_BYTES of each particle; the loaders read them at the offsets
// Slang reflects, never through a hand-written struct layout. A Vfx program
// names the resources it reads with `//! resource name kind` (RESOURCE_KINDS),
// up to MAX_RESOURCES: in its namespace, name is the index the functions of
// the contract take, in the order they are declared. It names its stages with
// `//! stage name over particles|grid [iterations N] [writes grid,grid]`,
// up to MAX_STAGES: each a function of its namespace that
// runs every step before update, in the order they are declared. `//! moves`:
// the program moves and ages its particles itself. `//! births`: its function
// births gives how many particles its emitter starts each frame. `//! prepare`:
// its function prepare runs once a frame for each emitter, before the rest.
// A Surface program that moves the vertices of what shows it says
// `//! vertex [animated] [reach <metres>|reach <parameter>]` and declares its
// function vertex (Mirai_Vertex_Context, mirai_material.slang): animated, it
// reads the time and runs every frame; reach is how far it moves a vertex
// from its rest, in the space of the mesh, a number or a float parameter.

MAX_PARAMETERS :: 32
PARAMETER_BYTES :: abi.PROGRAM_PARAMETER_BYTES
ATTRIBUTE_BYTES :: abi.PARTICLE_ATTRIBUTE_BYTES
MAX_PARAMETER_RANGE :: 1e30
MAX_RESOURCES :: abi.PROGRAM_RESOURCES
RESOURCE_KINDS :: [?]string{"surface","channel","grid","emitter","data"}
DATA_WORDS :: abi.PROGRAM_DATA_WORDS // of an entry of a data channel
MAX_STAGES :: abi.PROGRAM_STAGES
MAX_ITERATIONS :: 64
PARAMETER_GROUP_BYTES :: 32

// The layers a Surface program gives, by the fields of Mirai_Surface its
// source names: a material shows them only where its program may give them.
@(private)
PROGRAM_LAYERS :: [asset.Material_Layer]string{.Coat="coat_weight",.Fuzz="fuzz_weight",.Anisotropy="specular_anisotropy",.Unlit="unlit",.Diffuse_Transmission="diffuse_transmission_weight"}

Catalog :: struct {
    fingerprint:string, // of the compiler, the shared includes and every program source
    compiler:   string,
    programs:   []abi.Program,
    extensions: Extensions, // what the sources ask of the stages besides programs
    refused:    []string,   // the programs left out and why, one each: the others are published
    vfx:        []string,   // the Vfx programs, each with an include of its own (VFX_FOLDER/<name>/VFX_INCLUDE)
    surface:    []string,   // the Surface programs, each with an include of its own (SURFACE_FOLDER/<name>/SURFACE_INCLUDE)
    vertex:     []string,   // of them, those with a function vertex: a stage marked `//! per vertex program` is compiled for each
}

@(private)
Layout_Field :: struct {name,kind,scalar:string,count,offset:int}
@(private)
Layout :: struct {size:int,fields:[]Layout_Field}
// A layout in the cache, of the program whose sources have fingerprint.
@(private)
Layout_Cache :: struct {
    fingerprint,layout_hash:string,
    using layout:Layout `mirai:"inline"`,
}

// The stages a program reaches and the functions it declares.
Program_Domain :: abi.Program_Domain
PROGRAM_DOMAINS :: [Program_Domain]string{.Surface="surface",.Postprocess="postprocess",.Vfx="vfx",.Ui="ui"}

program_domain :: proc(name:string) -> (domain:Program_Domain,ok:bool) {
    for text,d in PROGRAM_DOMAINS {if text==name {return d,true}}
    return
}

// What the `//!` lines of a source say, read in one pass over it: the name
// and domain of the program it declares (empty for a shared module) and the
// line that declares them, its `//! parameter field {json}` metadata, its
// `//! resource` and `//! stage` lines, as words, whether it says
// `//! moves`, `//! births` and `//! prepare`, and the words of its
// `//! vertex` line (nil without one).
Program_Directives :: struct {
    domain,name:string,
    line:int, // from 1
    metadata:[dynamic][2]string, // field, json
    resources,stages:[dynamic][]string,
    moves,births,prepare:bool,
    vertex:[]string,
}

program_directives :: proc(text:string,allocator:=context.temp_allocator) -> (d:Program_Directives) {
    d.metadata=make([dynamic][2]string,allocator)
    d.resources=make([dynamic][]string,allocator)
    d.stages=make([dynamic][]string,allocator)
    rest:=text
    number:=0
    for line in strings.split_lines_iterator(&rest) {
        number+=1
        trimmed:=strings.trim_space(line)
        if !strings.has_prefix(trimmed,"//!") {continue}
        switch trimmed {
        case "//! moves": d.moves=true;continue
        case "//! births": d.births=true;continue
        case "//! prepare": d.prepare=true;continue
        }
        if !strings.has_prefix(line,"//!") {continue}
        if field,value,found:=parameter_metadata(line);found {
            append(&d.metadata,[2]string{field,value})
            continue
        }
        words:=strings.fields(line,allocator)
        if len(words)<2 || words[0]!="//!" {continue}
        switch words[1] {
        case "resource": append(&d.resources,words)
        case "stage": append(&d.stages,words)
        case "vertex": if d.vertex==nil {d.vertex=words}
        case "mirai":
            if d.name!="" || len(words)!=4 || !identifier_valid(words[3]) {continue}
            if _,known:=program_domain(words[2]);known {d.domain,d.name,d.line=words[2],words[3],number}
        }
    }
    return
}

// The resources of a Vfx program, from the words of its `//! resource name
// kind` lines, or what is wrong with one.
@(private)
program_resources :: proc(program:string,lines:[][]string,allocator:=context.allocator) -> (resources:[]abi.Program_Resource,problem:string) {
    list:=make([dynamic]abi.Program_Resource,allocator)
    for words in lines {
        cleared:=len(words)==5 && words[3]=="grid" && words[4]=="cleared"
        data:=len(words)==5 && words[3]=="data"
        if len(words)!=4 && !cleared && !data || !identifier_valid(words[2]) || len(words)==4 && words[3]=="data" {return nil,fmt.aprintf("%s: declare a resource as `//! resource name kind`, kind %v; a grid may add `cleared`, data adds the words of an entry",program,RESOURCE_KINDS,allocator=allocator)}
        count:=0
        if data {
            n,parsed:=strconv.parse_int(words[4])
            if !parsed || n<1 || n>DATA_WORDS {return nil,fmt.aprintf("%s.%s: an entry of a data channel has 1 to %d words, not %s",program,words[2],DATA_WORDS,words[4],allocator=allocator)}
            count=n
        }
        kind,known:=abi.Program_Resource_Kind(0),false
        for name,i in RESOURCE_KINDS {if name==words[3] {kind,known=abi.Program_Resource_Kind(i),true}}
        if !known {return nil,fmt.aprintf("%s.%s: a resource is of kind %v, not %s",program,words[2],RESOURCE_KINDS,words[3],allocator=allocator)}
        for resource in list {
            if resource.name==words[2] {return nil,fmt.aprintf("%s.%s: the program declares this resource twice",program,words[2],allocator=allocator)}
        }
        if len(list)==MAX_RESOURCES {return nil,fmt.aprintf("%s: a program reads at most %d resources",program,MAX_RESOURCES,allocator=allocator)}
        append(&list,abi.Program_Resource{strings.clone(words[2],allocator),kind,cleared,u32(count)})
    }
    return list[:],""
}

// The stages of a Vfx program, from the words of its `//! stage name over
// target [iterations N] [writes grid,grid]` lines, or what is wrong with one.
@(private)
program_stages :: proc(program:string,lines:[][]string,resources:[]abi.Program_Resource,allocator:=context.allocator) -> (stages:[]abi.Program_Stage,problem:string) {
    grid :: proc(resources:[]abi.Program_Resource,name:string) -> (index:int,found:bool) {
        for resource,i in resources {if resource.name==name && resource.kind==.Grid {return i,true}}
        return
    }
    list:=make([dynamic]abi.Program_Stage,allocator)
    for words in lines {
        if len(words)<5 || words[3]!="over" || !identifier_valid(words[2]) || len(words)%2!=1 {
            return nil,fmt.aprintf("%s: declare a stage as `//! stage name over particles|grid [iterations N] [writes grid,grid]`",program,allocator=allocator)
        }
        name,over:=words[2],words[4]
        if name=="initialize" || name=="update" || name=="render" {return nil,fmt.aprintf("%s.%s: initialize, update and render are not stages; name it otherwise",program,name,allocator=allocator)}
        index,is_grid:=grid(resources,over)
        if over!="particles" && !is_grid {
            return nil,fmt.aprintf("%s.%s: a stage goes over particles or over a grid the program declares as a resource, not %s",program,name,over,allocator=allocator)
        }
        stage:=abi.Program_Stage{name=strings.clone(name,allocator),over=is_grid?u8(index):abi.PROGRAM_STAGE_PARTICLES,iterations=1}
        for at:=5;at<len(words);at+=2 {
            switch words[at] {
            case "iterations":
                count,valid:=strconv.parse_int(words[at+1],10)
                if !valid || count<1 || count>MAX_ITERATIONS {
                    return nil,fmt.aprintf("%s.%s: iterations is a number from 1 to %d",program,name,MAX_ITERATIONS,allocator=allocator)
                }
                stage.iterations=u8(count)
            case "writes":
                for target in strings.split(words[at+1],",",context.temp_allocator) {
                    written,known:=grid(resources,target)
                    if !known {return nil,fmt.aprintf("%s.%s: a stage writes grids the program declares as resources, not %s",program,name,target,allocator=allocator)}
                    stage.writes|=1<<u32(written)
                }
            case:
                return nil,fmt.aprintf("%s.%s: a stage takes iterations or writes, not %s",program,name,words[at],allocator=allocator)
            }
        }
        for other in list {
            if other.name==name {return nil,fmt.aprintf("%s.%s: the program declares this stage twice",program,name,allocator=allocator)}
        }
        if len(list)==MAX_STAGES {return nil,fmt.aprintf("%s: a program has at most %d stages",program,MAX_STAGES,allocator=allocator)}
        append(&list,stage)
    }
    return list[:],""
}

// The function vertex of a Surface program, from the words of its `//! vertex
// [animated] [reach <metres>|reach <parameter>]` line and the reflection of
// its Parameters, or what is wrong with them. Without the line, none.
@(private)
program_vertex :: proc(program:string,words:[]string,parameters:Layout,allocator:=context.allocator) -> (vertex:abi.Program_Vertex,problem:string) {
    if words==nil {return}
    vertex.declared,vertex.reach_offset=true,-1
    usage:=fmt.tprintf("%s: declare a vertex function as `//! vertex [animated] [reach <metres>|reach <float parameter>]`",program)
    for at:=2;at<len(words);at+=1 {
        switch words[at] {
        case "animated":
            if vertex.animated {return {},strings.clone(usage,allocator)}
            vertex.animated=true
        case "reach":
            if at+1>=len(words) || vertex.reach!=0 || vertex.reach_offset>=0 {return {},strings.clone(usage,allocator)}
            at+=1
            if value,number:=strconv.parse_f64(words[at]);number {
                if !(value>=0) || value>MAX_PARAMETER_RANGE {return {},fmt.aprintf("%s: reach is metres from 0 to %v, not %s",program,f64(MAX_PARAMETER_RANGE),words[at],allocator=allocator)}
                vertex.reach=f32(value)
                continue
            }
            for field in parameters.fields {
                if field.name!=words[at] {continue}
                if field.scalar!="float32" || field.count!=1 {return {},fmt.aprintf("%s: the reach %s is a parameter of one float",program,field.name,allocator=allocator)}
                vertex.reach_offset=i32(field.offset)
            }
            if vertex.reach_offset<0 {return {},fmt.aprintf("%s: reach %s is neither a number nor a parameter of the program",program,words[at],allocator=allocator)}
        case:
            return {},strings.clone(usage,allocator)
        }
    }
    return vertex,""
}

// What a new program of a domain starts as: the least that compiles and
// shows its parameters, with $Name where its name goes. A Surface one builds
// on the standard model of its material, so the material keeps its look.
@(private)
PROGRAM_TEMPLATES :: [Program_Domain]string{
    .Surface=`//! mirai surface $Name
//! parameter tint {"default":[1,1,1],"min":0,"max":1,"color":true}
//! parameter glow {"default":0,"min":0}
namespace $Name {
struct Parameters {float3 tint;float glow;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_standard(ctx);
    s.base_color*=p.tint;
    s.emission+=p.tint*p.glow;
    return s;
}
}
`,
    .Postprocess=`//! mirai postprocess $Name
//! parameter tint {"default":[1,1,1],"min":0,"max":1,"color":true}
namespace $Name {
struct Parameters {float3 tint;};
float4 evaluate(Mirai_PostProcess_Context ctx, Parameters p) {
    return float4(ctx.color.rgb*p.tint,ctx.color.a);
}
}
`,
    .Vfx=`//! mirai vfx $Name
//! parameter speed {"default":2,"min":-20,"max":20}
namespace $Name {
struct Parameters {float speed;};
struct Attributes {float phase;};
void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.phase=mirai_vfx_random(particle.seed)*6.2831853;
}
void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.phase+=p.speed*ctx.delta_time;
}
void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    visual.color.rgb*=0.75+0.25*sin(a.phase);
}
}
`,
    .Ui=`//! mirai ui $Name
//! parameter fade {"default":0.5,"min":0,"max":1}
namespace $Name {
struct Parameters {float fade;};
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {
    return float4(ctx.color.rgb,ctx.color.a*(1.0-saturate(p.fade)*ctx.uv.y));
}
}
`,
}

program_template :: proc(domain:Program_Domain,name:string,allocator:=context.allocator) -> string {
    templates:=PROGRAM_TEMPLATES
    text,_:=strings.replace_all(templates[domain],"$Name",name,allocator)
    return text
}

identifier_valid :: proc(text:string) -> bool {
    if text=="" || (text[0]>='0' && text[0]<='9') {return false}
    for c in transmute([]u8)text {if !is_word(c) {return false}}
    return true
}

// The JSON of a `//! parameter field {...}` line, or false.
@(private)
parameter_metadata :: proc(line:string) -> (field,value:string,ok:bool) {
    if !strings.has_prefix(line,"//!") {return}
    text:=line[3:]
    if len(text)==0 || !is_space(text[0]) {return}
    text=skip_spaces(text)
    if !strings.has_prefix(text,"parameter") {return}
    text=text[len("parameter"):]
    if len(text)==0 || !is_space(text[0]) {return}
    text=skip_spaces(text)
    end:=0
    for end<len(text) && is_word(text[end]) {end+=1}
    if end==0 || end>=len(text) || !is_space(text[end]) {return}
    field=text[:end]
    value=strings.trim_right(skip_spaces(text[end:])," \t\r\v\f")
    return field,value,len(value)>=2 && value[0]=='{' && value[len(value)-1]=='}'
}

@(private)
json_truthy :: proc(value:json.Value) -> bool {
    switch v in value {
    case json.Null: return false
    case json.Boolean: return v
    case json.Integer: return v!=0
    case json.Float: return v!=0
    case json.String: return v!=""
    case json.Array: return len(v)>0
    case json.Object: return len(v)>0
    }
    return false
}

// A bound of a parameter: a finite number within the range the loader takes.
@(private)
json_bound :: proc(value:json.Value) -> (bound:f64,ok:bool) {
    #partial switch v in value {
    case json.Integer: bound,ok=f64(v),true
    case json.Float:   bound,ok=v,true
    }
    return bound,ok && !math.is_nan(bound) && !math.is_inf(bound) && abs(bound)<=MAX_PARAMETER_RANGE
}

@(private)
layout_hash :: proc(layout:Layout) -> string {
    hash:Sha256
    sha_begin(&hash)
    sha_text(&hash,fmt.tprintf("%d;",layout.size))
    for field in layout.fields {sha_text(&hash,fmt.tprintf("%s,%s,%s,%d,%d;",field.name,field.kind,field.scalar,field.count,field.offset))}
    return sha_hex(&hash,context.temp_allocator)
}

@(private)
layout_read :: proc(path,wanted_fingerprint:string,allocator:=context.allocator) -> (layout:Layout,ok:bool) {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    cached:Layout_Cache
    if error!=nil || serial.text_decode(string(data),&cached,allocator)!="" || cached.fingerprint!=wanted_fingerprint || layout_hash(cached.layout)!=cached.layout_hash {return}
    cache_touch(path)
    return cached.layout,true
}

@(private)
layout_write :: proc(path,layout_fingerprint:string,layout:Layout) {
    text,_:=serial.text_encode(Layout_Cache{layout_fingerprint,layout_hash(layout),layout},.Pretty,context.temp_allocator)
    write_file_atomic(path,text)
}

// The layouts of the structs of a program, Name::Parameters and, with
// attributes, Name::Attributes, as Slang reflects them in uniform buffers of
// one compilation. vfx: the program is of the Vfx domain, which has its own
// contract. An empty struct (Parameters of a material with none, Attributes)
// has no fields. said: what Slang said of the program when it does not
// compile; compile_error: that is why it failed (another compilation of the
// same sources fails the same). plugins: the folders of the shaders of the
// plugins, where it finds what it includes of theirs as the stages do.
// copied: the programs as the generation copies them, below the include
// folder that holds the constants they share with the CPU.
@(private)
layout_reflect :: proc(runner:^Runner,slangc,root,copied,source_folder,compiled_path,name,temporary:string,allocator:=context.allocator,attributes:=false,vfx:=false,prelude:="",said:^[]Diagnostic=nil,plugins:[]string=nil) -> (layouts:[2]Layout,error:string,compile_error:bool) {
    TYPES :: [2]string{"Parameters","Attributes"}
    types:=TYPES
    count:=2 if attributes else 1
    wrapper:=path_join(temporary,fmt.tprintf("%s.slang",name),allocator=context.temp_allocator)
    reflected:=path_join(temporary,fmt.tprintf("%s.json",name),allocator=context.temp_allocator)
    text:=strings.builder_make(context.temp_allocator)
    strings.write_string(&text,"#define MIRAI_VFX_REFLECTION 1\n#include \"mirai_vfx.slang\"\n" if vfx else "#define MIRAI_MATERIAL_REFLECTION 1\n#include \"mirai_material.slang\"\n")
    fmt.sbprintf(&text,"%s#include \"%s\"\n",prelude,compiled_path)
    for i in 0..<count {fmt.sbprintf(&text,"[[vk::binding(%d,0)]] ConstantBuffer<%s::%s> mirai_reflect_%d;\n",i,name,types[i],i)}
    fmt.sbprintf(&text,"[[vk::binding(%d,0)]] RWStructuredBuffer<uint> mirai_result;\n",count)
    strings.write_string(&text,"[shader(\"compute\")][numthreads(1,1,1)] void reflect_main(uint3 id:SV_DispatchThreadID) {mirai_result[id.x]=id.x;}\n")
    if !write_file(wrapper,text.buf[:]) {return {},strings.clone("could not write the reflection program",allocator),false}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,slangc,wrapper)
    for folder in ENGINE_INCLUDES {append(&command,"-I",path_join(root,folder,allocator=context.temp_allocator))}
    append(&command,
        "-I",path_parent(copied),"-I",path_join(copied,"builtin",allocator=context.temp_allocator),
        "-I",path_join(copied,"project",allocator=context.temp_allocator),"-I",source_folder,"-entry","reflect_main","-target","spirv","-profile","spirv_1_5",
        "-reflection-json",reflected,"-o",path_join(temporary,fmt.tprintf("%s.spv",name),allocator=context.temp_allocator),SLANG_DIAGNOSTICS_FLAG,
    )
    for folder in plugins {append(&command,"-I",folder)}
    output,ran:=tool_run(runner,command[:],context.temp_allocator)
    if !ran {
        diagnostics:=slang_diagnostics(output,allocator)
        if said!=nil {said^=diagnostics}
        // A compiler that was stopped or did not start says nothing of the program: that is no layout.
        if len(diagnostics)==0 {return {},fmt.aprintf("%s: %s",name,strings.trim_space(output) if output!="" else "slangc failed",allocator=allocator),false}
        return {},diagnostics_text(diagnostics,allocator),!runner_cancelled(runner)
    }
    data,readable:=read_json(reflected,context.temp_allocator)
    parameters,_:=data["parameters"].(json.Array)
    if !readable {return {},fmt.aprintf("%s: Slang did not write its reflection",name,allocator=allocator),false}
    types_loop: for i in 0..<count {
        for value in parameters {
            parameter,_:=value.(json.Object)
            if json_text(parameter["name"])!=fmt.tprintf("mirai_reflect_%d",i) {continue}
            type,_:=parameter["type"].(json.Object)
            element,_:=type["elementType"].(json.Object)
            sizes,_:=element["sizes"].(json.Array)
            found_size:=false
            layout:=&layouts[i]
            for entry in sizes {
                size,_:=entry.(json.Object)
                if json_text(size["kind"])=="uniform" {layout.size,found_size=json_int(size["value"])}
            }
            fields,_:=element["fields"].(json.Array)
            layout.fields=make([]Layout_Field,len(fields),allocator)
            for entry,j in fields {
                field,_:=entry.(json.Object)
                field_type,_:=field["type"].(json.Object)
                binding,_:=field["binding"].(json.Object)
                element_count:=1
                if _,has_count:=field_type["elementCount"];has_count {element_count,_=json_int(field_type["elementCount"])}
                scalar_type:=field_type
                if element_type,is_vector:=field_type["elementType"].(json.Object);is_vector {scalar_type=element_type}
                offset,_:=json_int(binding["offset"])
                layout.fields[j]={strings.clone(json_text(field["name"]),allocator),strings.clone(json_text(field_type["kind"]),allocator),strings.clone(json_text(scalar_type["scalarType"]),allocator),element_count,offset}
            }
            if !found_size && len(fields)>0 {break}
            continue types_loop
        }
        return {},fmt.aprintf("%s: the reflection has no %s; check that %s is the Slang %s or later the engine pins (`mirai setup slang`)",name,types[i],slangc,SLANG_VERSION,allocator=allocator),false
    }
    return layouts,"",false
}

// A parameter of a program from the field Slang reflected and its metadata;
// problem says what is wrong with them.
@(private)
program_parameter :: proc(field:Layout_Field,meta:json.Object,allocator:=context.allocator) -> (parameter:abi.Program_Parameter,problem:string) {
    count:=field.count
    switch field.scalar {
    case "float32": parameter.kind=.Float
    case "int32":   parameter.kind=.Int
    case "uint32":  parameter.kind=.Uint
    case "bool":    parameter.kind=.Bool
    case: count=0
    }
    if (field.kind!="scalar" && field.kind!="vector") || count<1 || count>4 {return {},"only float/int/uint/bool scalars and vectors1..4 are supported"}
    if field.offset%4!=0 || field.offset+count*4>PARAMETER_BYTES {return {},"unaligned parameter"}
    parameter.name,parameter.components,parameter.offset=strings.clone(field.name,allocator),u8(count),u16(field.offset)
    if json_text(meta["kind"])=="texture" {
        if parameter.kind!=.Uint || count!=1 {return {},"texture parameters must be uint"}
        parameter.kind=.Texture
    }
    parameter.min,parameter.max=-1e20,1e20
    valid_range:=true
    if value,has:=meta["min"];has {parameter.min,valid_range=json_bound(value)}
    if value,has:=meta["max"];has && valid_range {parameter.max,valid_range=json_bound(value)}
    if !valid_range || parameter.min>parameter.max {return {},"invalid parameter range"}
    given,has_default:=meta["default"]
    defaults:=[]json.Value{given}
    if list,is_list:=given.(json.Array);is_list {defaults=list[:]}
    if has_default && len(defaults)!=count {return {},fmt.aprintf("default must have %d components",count,allocator=allocator)}
    // Without a default, a texture is none, a bool false and a number 0.
    for i in 0..<count {
        n:f64
        number:=!has_default && parameter.kind!=.Texture && parameter.kind!=.Bool
        valid:=!has_default
        if has_default {
            #partial switch v in defaults[i] {
            case json.String:  valid=parameter.kind==.Texture
            case json.Boolean: valid,n=parameter.kind==.Bool,f64(u8(v))
            case json.Integer: number,n=true,f64(v)
            case json.Float:   number,n=true,v
            }
        }
        if number {
            valid=parameter.kind!=.Texture && parameter.kind!=.Bool && !math.is_nan(n) && !math.is_inf(n) && parameter.min<=n && n<=parameter.max
            if parameter.kind==.Uint {valid&&=math.trunc(n)==n && n>=0 && n<=4294967295}
            if parameter.kind==.Int {valid&&=math.trunc(n)==n && n>=-2147483648 && n<=2147483647}
        }
        if !valid {return {},"invalid typed default"}
        parameter.defaults[i]=n
    }
    parameter.srgb,parameter.normal,parameter.color=json_truthy(meta["srgb"]),json_truthy(meta["normal"]),json_truthy(meta["color"])
    if parameter.color && (parameter.kind!=.Float || count!=3) {return {},"a color is three floats"}
    if group,has:=meta["group"];has {
        text,is_text:=group.(json.String)
        if !is_text || text=="" || len(text)>PARAMETER_GROUP_BYTES {return {},fmt.aprintf("group must be a name of 1 to %d bytes",PARAMETER_GROUP_BYTES,allocator=allocator)}
        parameter.group=strings.clone(text,allocator)
    }
    return parameter,""
}

// The first parameter the metadata declares that the layout lacks; "" when it has them all.
@(private)
layout_missing :: proc(layout:Layout,metadata:map[string]json.Object) -> string {
    for name in metadata {
        found:=false
        for field in layout.fields {found||=field.name==name}
        if !found {return name}
    }
    return ""
}

// The loader of a program: its Parameters read from the 256 bytes at the
// offsets Slang reflected. The fields are those program_parameter accepted.
@(private)
program_loader :: proc(b:^strings.Builder,name:string,layout:Layout) {
    fmt.sbprintf(b,"%s::Parameters mirai_load_%s(float4 packed[16]) {{\n    %s::Parameters p;\n",name,name,name)
    for field in layout.fields {
        scalar,count:=field.scalar,field.count
        base:string
        switch scalar {
        case "float32": base="float"
        case "int32": base="int"
        case "uint32": base="uint"
        case "bool": base="bool"
        }
        fmt.sbprintf(b,"    p.%s=",field.name)
        if count>1 {fmt.sbprintf(b,"%s%d(",base,count)}
        for i in 0..<count {
            word:=field.offset/4+i
            names:="xyzw"
            component:=names[word%4:][:1]
            if i>0 {strings.write_byte(b,',')}
            switch scalar {
            case "uint32": fmt.sbprintf(b,"asuint(packed[%d].%s)",word/4,component)
            case "int32": fmt.sbprintf(b,"asint(packed[%d].%s)",word/4,component)
            case "bool": fmt.sbprintf(b,"(asuint(packed[%d].%s)!=0)",word/4,component)
            case: fmt.sbprintf(b,"packed[%d].%s",word/4,component)
            }
        }
        strings.write_string(b,");\n" if count>1 else ";\n")
    }
    strings.write_string(b,"    return p;\n}\n")
}

// Copies program sources with the bytes the repository has: a generation is
// the same on every platform.
@(private)
copy_sources :: proc(files:^Sources,source,target:string) -> (failed:string) {
    for path in sources_below(files,source) {
        relative,_:=path_relative(path,source)
        destination:=path_join(target,relative,allocator=context.temp_allocator)
        os.make_directory_all(path_parent(destination))
        data:=sources_file(files,path).data
        if !strings.has_suffix(path,".slang") {
            err:os.Error
            if data,err=os.read_entire_file(path,context.temp_allocator);err!=nil {return fmt.tprintf("%s could not be read (%v)",path,err)}
        }
        if err:=os.write_entire_file(destination,data);err!=nil {return fmt.tprintf("%s could not be written (%v)",destination,err)}
    }
    return ""
}

// The includes a generation writes for the stages that evaluate programs:
// the sources of the programs of a domain, their typed loaders and the
// dispatcher of the domain. A stage includes the one it calls, so a program
// only reaches the stages of its domain.
// The Surface include of the include folder evaluates no program: only the
// stages of a program (`//! per surface program`) have one, the include of
// SURFACE_FOLDER/<name>. The alpha of the programs that have one of their own
// is in SURFACE_COVERAGE_INCLUDE, for the rays that go through what it leaves out.
SURFACE_INCLUDE :: "surface_programs.slang"
SURFACE_FOLDER :: "surface" // of the include, the folder of the include of each Surface program
SURFACE_COVERAGE_INCLUDE :: "surface_coverage.slang"
POSTPROCESS_INCLUDE :: "postprocess_programs.slang"
VFX_INCLUDE :: "vfx_programs.slang"
VFX_FOLDER :: "vfx" // of the include, the folder of the include of each Vfx program
@(private)
VFX_HEADER :: "// Generated by mirai shaders. DO NOT EDIT. Included by particle_programs.slang of the vfx plugin,\n// which declares particle_data. The stages a source marks `//! per vfx program` are compiled once\n// for each Vfx program, with the include of that program alone.\n#ifndef MIRAI_VFX_PROGRAMS\n#define MIRAI_VFX_PROGRAMS\n#include \"mirai_vfx.slang\"\n"
UI_INCLUDE :: "ui_programs.slang"

// The indices of the resources of a Vfx program in its namespace, before
// its source: its functions name them.
@(private)
vfx_prelude :: proc(name:string,resources:[]abi.Program_Resource) -> string {
    if len(resources)==0 {return ""}
    names:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&names,"namespace %s {{",name)
    for resource,slot in resources {fmt.sbprintf(&names,"static const uint %s=%du;",resource.name,slot)}
    strings.write_string(&names,"}\n")
    return strings.to_string(names)
}

// The include of a Vfx program alone (VFX_FOLDER/<name>/VFX_INCLUDE), with
// which the stages marked `//! per vfx program` are compiled for it; its
// copy is at include/programs/<relative>. A message for Attributes a
// particle does not hold.
@(private)
vfx_program_include :: proc(name,prelude,relative:string,parameters,attributes:Layout,stages:[]abi.Program_Stage,said:Program_Directives) -> (text,problem:string) {
    own:=strings.builder_make(context.temp_allocator)
    strings.write_string(&own,VFX_HEADER)
    fmt.sbprintf(&own,"%s#include \"programs/%s\"\n",prelude,relative)
    program_loader(&own,name,parameters)
    if failure:=vfx_attributes(&own,name,attributes);failure!="" {return "",failure}
    fmt.sbprintf(&own,"#ifdef PARTICLES_WRITABLE\nbool mirai_vfx_initialize(uint id,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,inout Mirai_Vfx_Particle value) {{%s::Attributes a=(%s::Attributes)0;%s::initialize(ctx,mirai_load_%s(packed),value,a);mirai_attributes_store_%s(attributes,a);return true;}}\n",name,name,name,name,name)
    fmt.sbprintf(&own,"bool mirai_vfx_update(uint id,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,inout Mirai_Vfx_Particle value) {{%s::Attributes a=mirai_attributes_load_%s(attributes);%s::update(ctx,mirai_load_%s(packed),value,a);mirai_attributes_store_%s(attributes,a);return true;}}\n",name,name,name,name,name)
    particles,cells:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    for stage,index in stages {
        if stage.over==abi.PROGRAM_STAGE_PARTICLES {
            fmt.sbprintf(&particles,"case %d: {{%s::Attributes a=mirai_attributes_load_%s(attributes);%s::%s(ctx,mirai_load_%s(packed),value,a);mirai_attributes_store_%s(attributes,a);return true;}}",index,name,name,name,stage.name,name,name)
        } else {
            fmt.sbprintf(&cells,"case %d: %s::%s(cell,mirai_load_%s(packed));return true;",index,name,stage.name,name)
        }
    }
    if said.prepare {
        fmt.sbprintf(&own,"void mirai_vfx_prepare(uint id,float4 packed[16],Mirai_Vfx_Context ctx) {{%s::prepare(ctx,mirai_load_%s(packed));}}\n",name,name)
    } else {
        strings.write_string(&own,"void mirai_vfx_prepare(uint id,float4 packed[16],Mirai_Vfx_Context ctx) {}\n")
    }
    if said.births {
        fmt.sbprintf(&own,"uint mirai_vfx_births(uint id,float4 packed[16],Mirai_Vfx_Context ctx) {{return %s::births(ctx,mirai_load_%s(packed));}}\n",name,name)
    } else {
        strings.write_string(&own,"uint mirai_vfx_births(uint id,float4 packed[16],Mirai_Vfx_Context ctx) {return 0u;}\n")
    }
    fmt.sbprintf(&own,"bool mirai_vfx_particle_stage(uint id,uint stage,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,inout Mirai_Vfx_Particle value) {{switch(stage) {{%sdefault:return false;}}}}\n",strings.to_string(particles))
    fmt.sbprintf(&own,"bool mirai_vfx_cell_stage(uint id,uint stage,float4 packed[16],Mirai_Vfx_Cell cell) {{switch(stage) {{%sdefault:return false;}}}}\n#endif\n",strings.to_string(cells))
    fmt.sbprintf(&own,"bool mirai_vfx_render(uint id,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,Mirai_Vfx_Particle value,inout Mirai_Vfx_Visual visual) {{%s::render(ctx,mirai_load_%s(packed),value,mirai_attributes_load_%s(attributes),visual);return true;}}\n#endif\n",name,name,name)
    return strings.to_string(own),""
}

// Ends the line with which the coverage include names the source of a program
// with coverage, before the hash of its alpha compiled alone (alpha_probe):
// the fingerprint of a stage that traces follows that alpha and not the text
// of the program (dependencies), so an edit that keeps the alpha of a program
// compiles only its own stages.
ALPHA_INCLUDE :: "// by its alpha "

// The source and the loader of a Surface program, once in a stage that
// includes both its own include and the coverage include. alpha: in the
// coverage include, the hash of its alpha.
@(private)
surface_program_source :: proc(b:^strings.Builder,name,relative:string,parameters:Layout,alpha:="") {
    fmt.sbprintf(b,"#ifndef MIRAI_PROGRAM_%s\n#define MIRAI_PROGRAM_%s\n#include \"programs/%s\"",name,name,relative)
    if alpha!="" {fmt.sbprintf(b," %s%s",ALPHA_INCLUDE,alpha)}
    strings.write_string(b,"\n")
    program_loader(b,name,parameters)
    strings.write_string(b,"#endif\n")
}

// The include of a Surface program alone (SURFACE_FOLDER/<name>/SURFACE_INCLUDE),
// with which the stages marked `//! per surface program` are compiled for it:
// they evaluate it for every material they are given, which are its own.
// vertex: it has a function vertex, which mirai_vertex_program calls in the
// stages marked `//! per vertex program`.
@(private)
surface_program_include :: proc(name,relative:string,parameters:Layout,vertex:=false) -> string {
    own:=strings.builder_make(context.temp_allocator)
    strings.write_string(&own,"// Generated by mirai shaders. DO NOT EDIT. The stages a source marks `//! per surface program`\n// are compiled once for each Surface program, with the include of that program alone.\n")
    strings.write_string(&own,"#ifndef MIRAI_SURFACE_PROGRAMS\n#define MIRAI_SURFACE_PROGRAMS\n#include \"mirai_material.slang\"\n")
    surface_program_source(&own,name,relative,parameters)
    fmt.sbprintf(&own,"bool mirai_evaluate_program(uint id,float4 packed[16],Mirai_Surface_Context ctx,inout Mirai_Surface value) {{value=%s::evaluate(ctx,mirai_load_%s(packed));return true;}}\n",name,name)
    if vertex {
        fmt.sbprintf(&own,"bool mirai_vertex_program(uint id,float4 packed[16],Mirai_Vertex_Context ctx,inout Mirai_Vertex value) {{value=%s::vertex(ctx,mirai_load_%s(packed));return true;}}\n",name,name)
    } else {
        strings.write_string(&own,NO_VERTEX_PROGRAM)
    }
    strings.write_string(&own,"#endif\n")
    return strings.to_string(own)
}

// The function vertex of the stages without a program, or of one that moves no vertices.
@(private)
NO_VERTEX_PROGRAM :: "bool mirai_vertex_program(uint id,float4 packed[16],Mirai_Vertex_Context ctx,inout Mirai_Vertex value) {return false;}\n"

// The value the default material of an alpha probe gives alpha: a program
// whose probe stores it never changes the alpha of the default.
@(private)
PROBE_ALPHA :: f32(0.7568359375)
@(private)
PROBE_BINDING :: 100 // past those of what a program includes

// Whether a Surface program changes the alpha of the default material, by its
// alpha alone compiled and optimized: what reads nothing (a texture, the
// context, a parameter) folds into a constant. Anything else counts as
// coverage, and alpha is the hash of that compiled alpha: the texture reads
// keep every argument, so two sources with the same hash give the same alpha.
// ok: the compiler ran; the reflection says why when it did not.
@(private)
alpha_probe :: proc(runner:^Runner,slangc,root,copied,source_folder,compiled_path,name,temporary:string,plugins:[]string=nil) -> (coverage:bool,alpha:[64]u8,ok:bool) {
    wrapper:=path_join(temporary,fmt.tprintf("%s.alpha.slang",name),allocator=context.temp_allocator)
    compiled:=path_join(temporary,fmt.tprintf("%s.alpha.spv",name),allocator=context.temp_allocator)
    text:=strings.builder_make(context.temp_allocator)
    strings.write_string(&text,"#include \"mirai_material.slang\"\n")
    fmt.sbprintf(&text,"[[vk::binding(%d,0)]] RWStructuredBuffer<float4> mirai_probe_values;\n",PROBE_BINDING)
    fmt.sbprintf(&text,"[[vk::binding(%d,0)]] RWStructuredBuffer<Mirai_Surface_Context> mirai_probe_contexts;\n",PROBE_BINDING+1)
    fmt.sbprintf(&text,"[[vk::binding(%d,0)]] RWStructuredBuffer<float> mirai_probe_alpha;\n",PROBE_BINDING+2)
    // A read of a texture depends on all it is given and on how it reads.
    strings.write_string(&text,"float4 mirai_probe_value(uint kind,uint index,float2 uv,float4 more=float4(0.0)) {return mirai_probe_values[(kind*977u+index+asuint(uv.x)*3u+asuint(uv.y)*5u+asuint(more.x)*7u+asuint(more.y)*11u+asuint(more.z)*13u+asuint(more.w)*17u)&63u];}\n")
    fmt.sbprintf(&text,"Mirai_Surface mirai_surface_default(Mirai_Surface_Context ctx) {{Mirai_Surface s=(Mirai_Surface)0;s.normal=ctx.normal;s.alpha=%.10f;return s;}}\n",PROBE_ALPHA)
    // The standard model of a material reads its opacity and the alpha of its base color map.
    strings.write_string(&text,"Mirai_Surface mirai_surface_standard(Mirai_Surface_Context ctx) {Mirai_Surface s=mirai_surface_default(ctx);s.alpha=mirai_probe_value(8u,ctx.material,ctx.uv0).a;return s;}\n")
    strings.write_string(&text,"float4 mirai_sample_texture(Mirai_Surface_Context ctx,uint index,float2 uv,float lod) {return mirai_probe_value(1u,index,uv,float4(lod,0.0,0.0,0.0));}\n")
    strings.write_string(&text,"float4 mirai_sample_texture(Mirai_PostProcess_Context ctx,uint index,float2 uv,float lod) {return mirai_probe_value(2u,index,uv,float4(lod,0.0,0.0,0.0));}\n")
    strings.write_string(&text,"float4 mirai_sample_texture_level(uint index,float2 uv,float level) {return mirai_probe_value(3u,index,uv,float4(level,0.0,0.0,0.0));}\n")
    strings.write_string(&text,"float4 mirai_sample_texture_grad(uint index,float2 uv,float2 dx,float2 dy) {return mirai_probe_value(4u,index,uv,float4(dx,dy));}\n")
    strings.write_string(&text,"float4 mirai_sample_texture_projected(Mirai_Surface_Context ctx,uint index,float3 u,float3 v,float metres) {return mirai_probe_value(5u,index,float2(dot(ctx.world_position,u),dot(ctx.world_position,v)),float4(metres,0.0,0.0,0.0));}\n")
    strings.write_string(&text,"float2 mirai_texture_size(uint index) {return mirai_probe_value(6u,index,float2(0.0)).xy;}\n")
    strings.write_string(&text,"float4 mirai_scene_color(Mirai_PostProcess_Context ctx,float2 uv) {return mirai_probe_value(7u,1u,uv);}\n")
    strings.write_string(&text,"float mirai_scene_depth(Mirai_PostProcess_Context ctx,float2 uv) {return mirai_probe_value(7u,2u,uv).x;}\n")
    strings.write_string(&text,"float3 mirai_scene_normal(Mirai_PostProcess_Context ctx,float2 uv) {return mirai_probe_value(7u,3u,uv).xyz;}\n")
    strings.write_string(&text,"Mirai_Outline mirai_outline(Mirai_PostProcess_Context ctx,float2 uv) {return (Mirai_Outline)0;}\n")
    fmt.sbprintf(&text,"#include \"%s\"\n",compiled_path)
    fmt.sbprintf(&text,"[[vk::binding(%d,0)]] ConstantBuffer<%s::Parameters> mirai_probe_parameters;\n",PROBE_BINDING+3,name)
    fmt.sbprintf(&text,"[shader(\"compute\")][numthreads(1,1,1)] void probe_main() {{mirai_probe_alpha[0]=%s::evaluate(mirai_probe_contexts[0],mirai_probe_parameters).alpha;}}\n",name)
    if !write_file(wrapper,text.buf[:]) {return}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,slangc,wrapper)
    for folder in ENGINE_INCLUDES {append(&command,"-I",path_join(root,folder,allocator=context.temp_allocator))}
    append(&command,"-I",path_parent(copied),"-I",path_join(copied,"builtin",allocator=context.temp_allocator),"-I",path_join(copied,"project",allocator=context.temp_allocator),"-I",source_folder)
    for folder in plugins {append(&command,"-I",folder)}
    append(&command,"-entry","probe_main","-o",compiled,"-warnings-disable","40100,41035")
    append(&command,..SPIRV_FLAGS)
    append(&command,..SLANG_OPTIMIZATION)
    if _,ran:=tool_run(runner,command[:],context.temp_allocator);!ran {return}
    spirv,read_error:=os.read_entire_file(compiled,context.temp_allocator)
    if read_error!=nil {return}
    coverage=!probe_stores_constant(spirv,transmute(u32)PROBE_ALPHA)
    if coverage {
        hash:Sha256
        sha_begin(&hash)
        sha_bytes(&hash,spirv)
        copy(alpha[:],sha_hex(&hash,context.temp_allocator))
    }
    return coverage,alpha,true
}

// Whether every store of an optimized probe into the buffer at
// PROBE_BINDING+2 stores the constant of those bits. Anything it does not
// follow counts as another value.
@(private)
probe_stores_constant :: proc(spirv:[]u8,bits:u32) -> bool {
    if len(spirv)<20 || len(spirv)%4!=0 {return false}
    word :: proc(spirv:[]u8,at:int) -> u32 {value,_:=endian.get_u32(spirv[at*4:],.Little);return value}
    count:=len(spirv)/4
    output:u32
    constants:=make(map[u32]u32,context.temp_allocator)
    chains:=make(map[u32]bool,context.temp_allocator)
    stored:=make([dynamic]u32,context.temp_allocator)
    // The variable is decorated before the code that names it: two walks.
    for walk in 0..<2 {
        at:=5
        for at<count {
            instruction:=word(spirv,at)
            op,length:=instruction&0xffff,int(instruction>>16)
            if length==0 || at+length>count {return false}
            switch {
            case walk==0 && op==71 && length>=4 && word(spirv,at+2)==33 && word(spirv,at+3)==PROBE_BINDING+2: output=word(spirv,at+1) // OpDecorate Binding
            case walk==0 && op==43 && length==4: constants[word(spirv,at+2)]=word(spirv,at+3) // OpConstant
            case walk==1 && (op==65 || op==66) && length>=4 && word(spirv,at+3)==output: chains[word(spirv,at+2)]=true // OpAccessChain, OpInBoundsAccessChain
            case walk==1 && op==62 && length>=3 && chains[word(spirv,at+1)]: append(&stored,word(spirv,at+2)) // OpStore
            }
            at+=length
        }
    }
    if output==0 || len(stored)==0 {return false}
    for value in stored {
        constant,known:=constants[value]
        if !known || constant!=bits {return false}
    }
    return true
}

// The dispatchers of the PostProcess and UI programs, and the coverage of the
// Surface ones, as programs are added to them: per domain the includes of the
// sources, their typed loaders and the cases.
@(private)
Dispatchers :: struct {declarations,loaders,cases:[Program_Domain]strings.Builder}

@(private)
dispatchers_make :: proc() -> (d:Dispatchers) {
    for domain in Program_Domain {
        d.declarations[domain]=strings.builder_make(context.temp_allocator)
        d.loaders[domain]=strings.builder_make(context.temp_allocator)
        d.cases[domain]=strings.builder_make(context.temp_allocator)
    }
    return
}

// A program of that id, copied at include/programs/<relative>; one of Vfx
// has an include of its own (vfx_program_include), and one of Surface too
// (surface_program_include), and only its alpha here when it has coverage.
@(private)
dispatchers_add :: proc(d:^Dispatchers,domain:Program_Domain,id:int,name,relative:string,parameters:Layout,coverage:=false,alpha:="") {
    #partial switch domain {
    case .Surface:
        if !coverage {return}
        surface_program_source(&d.declarations[domain],name,relative,parameters,alpha)
        fmt.sbprintf(&d.cases[domain],"    case %d: alpha=%s::evaluate(ctx,mirai_load_%s(packed)).alpha;return true;\n",id,name,name)
    case .Postprocess,.Ui:
        program_loader(&d.loaders[domain],name,parameters)
        fmt.sbprintf(&d.declarations[domain],"#include \"programs/%s\"\n",relative)
        fmt.sbprintf(&d.cases[domain],"    case %d: return %s::evaluate(ctx,mirai_load_%s(packed));\n",id,name,name)
    }
}

// Writes into the folder include the dispatcher of each domain and the
// include of no Vfx program (the stages that run none, and the emitters
// without one); the name of the one that could not be written.
@(private)
dispatchers_write :: proc(d:^Dispatchers,include:string) -> (failed:string) {
    vfx:=strings.builder_make(context.temp_allocator)
    strings.write_string(&vfx,VFX_HEADER)
    strings.write_string(&vfx,"#ifdef PARTICLES_WRITABLE\nbool mirai_vfx_initialize(uint id,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,inout Mirai_Vfx_Particle value) {return false;}\n")
    strings.write_string(&vfx,"bool mirai_vfx_update(uint id,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,inout Mirai_Vfx_Particle value) {return false;}\n")
    strings.write_string(&vfx,"uint mirai_vfx_births(uint id,float4 packed[16],Mirai_Vfx_Context ctx) {return 0u;}\n")
    strings.write_string(&vfx,"void mirai_vfx_prepare(uint id,float4 packed[16],Mirai_Vfx_Context ctx) {}\n")
    strings.write_string(&vfx,"bool mirai_vfx_particle_stage(uint id,uint stage,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,inout Mirai_Vfx_Particle value) {return false;}\n")
    strings.write_string(&vfx,"bool mirai_vfx_cell_stage(uint id,uint stage,float4 packed[16],Mirai_Vfx_Cell cell) {return false;}\n#endif\n")
    strings.write_string(&vfx,"bool mirai_vfx_render(uint id,float4 packed[16],uint attributes,Mirai_Vfx_Context ctx,Mirai_Vfx_Particle value,inout Mirai_Vfx_Visual visual) {return false;}\n#endif\n")
    if !write_file(path_join(include,VFX_INCLUDE,allocator=context.temp_allocator),vfx.buf[:]) {return VFX_INCLUDE}
    // The stages of the materials without a program, and those of no program.
    if !write_file(path_join(include,SURFACE_INCLUDE,allocator=context.temp_allocator),transmute([]u8)string("// Generated by mirai shaders. DO NOT EDIT. The stages of the materials without a program.\n#ifndef MIRAI_SURFACE_PROGRAMS\n#define MIRAI_SURFACE_PROGRAMS\n#include \"mirai_material.slang\"\nbool mirai_evaluate_program(uint id,float4 packed[16],Mirai_Surface_Context ctx,inout Mirai_Surface value) {return false;}\n"+NO_VERTEX_PROGRAM+"#endif\n")) {return SURFACE_INCLUDE}
    Dispatcher :: struct {file,guard,signature,otherwise:string}
    dispatchers:=#partial [Program_Domain]Dispatcher{
        .Surface={SURFACE_COVERAGE_INCLUDE,"MIRAI_SURFACE_COVERAGE","bool mirai_program_alpha(uint id,float4 packed[16],Mirai_Surface_Context ctx,out float alpha)","return false;"},
        .Postprocess={POSTPROCESS_INCLUDE,"MIRAI_POSTPROCESS_PROGRAMS","float4 mirai_evaluate_postprocess(uint id,float4 packed[16],Mirai_PostProcess_Context ctx)","return ctx.color;"},
        .Ui={UI_INCLUDE,"MIRAI_UI_PROGRAMS","float4 mirai_evaluate_ui(uint id,float4 packed[16],Mirai_Ui_Context ctx)","return ctx.color;"},
    }
    for dispatcher,domain in dispatchers {
        if domain==.Vfx {continue}
        text:=strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&text,"// Generated by mirai shaders. DO NOT EDIT.\n#ifndef %s\n#define %s\n#include \"mirai_material.slang\"\n",dispatcher.guard,dispatcher.guard)
        strings.write_string(&text,strings.to_string(d.declarations[domain]))
        strings.write_string(&text,strings.to_string(d.loaders[domain]))
        fmt.sbprintf(&text,"%s {{%sswitch(id) {{\n%sdefault:%s}}}}\n#endif\n",dispatcher.signature,"alpha=0.0;" if domain==.Surface else "",strings.to_string(d.cases[domain]),dispatcher.otherwise)
        if !write_file(path_join(include,dispatcher.file,allocator=context.temp_allocator),text.buf[:]) {return dispatcher.file}
    }
    return ""
}

// A source that declares a program, as the catalog reads it.
@(private)
Program_Entry :: struct {
    path,text,domain,name:string,
    vfx:             bool,
    said:            Program_Directives,
    metadata:        map[string]json.Object,
    metadata_problem:string, // why its metadata leaves it out
    problem:         string, // why its resources or stages leave it out
    resources:       []abi.Program_Resource,
    stages:          []abi.Program_Stage,
    prelude:         string, // the indices of its resources, before it
    relative:        string, // below include/programs
    folder:          string,
    fingerprint:     string, // of its layouts in the cache
    caches:          [4]string, // its files in the cache: the layouts of Parameters and Attributes, why it does not compile, and its coverage
    coverage:        bool, // of a Surface program (alpha_probe)
    alpha:           [64]u8, // with coverage, the hash of its alpha compiled alone (alpha_probe)
    probed:          bool, // its coverage is known
    layouts:         [2]Layout,
    cached:          bool, // the cache has its layouts: it is not reflected
    error:           string, // what its reflection said
    arena:           virtual.Arena, // of what its reflection made
}

@(private)
Program_Reflection :: struct {
    entries:[]Program_Entry,
    runner:^Runner,
    slangc,root,copied,temporary:string,
    plugins:[]string,
}

// Reflects the layouts of the entries the cache lacks, each in a compilation
// of its own, on up to `workers` threads, and keeps them in the cache.
@(private)
programs_reflect :: proc(r:^Program_Reflection,workers:int) {
    pending:=0
    for e in r.entries {if e.metadata_problem=="" && e.problem=="" && !(e.cached && e.probed) {pending+=1}}
    if pending==0 {return}
    work :: proc(r:^Program_Reflection,first,last,worker:int) {
        for at in first..<last {
            e:=&r.entries[at]
            if e.metadata_problem!="" || e.problem!="" || (e.cached && e.probed) {continue}
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            if virtual.arena_init_growing(&e.arena)!=nil {e.error="out of memory for its reflection";continue}
            allocator:=virtual.arena_allocator(&e.arena)
            // A folder of its own: two sources may declare one name.
            temporary:=path_join(r.temporary,fmt.tprintf("%d",at),allocator=context.temp_allocator)
            os.make_directory_all(temporary)
            compiled_path:=path_join(r.copied,e.relative,allocator=context.temp_allocator)
            if !e.probed && e.error=="" {
                if coverage,alpha,ran:=alpha_probe(r.runner,r.slangc,r.root,r.copied,e.folder,compiled_path,e.name,temporary,r.plugins);ran {
                    e.coverage,e.alpha,e.probed=coverage,alpha,true
                    write_file_atomic(e.caches[3],transmute([]u8)(fmt.tprintf("1 %s",string(alpha[:])) if coverage else "0"))
                }
            }
            if e.cached {continue}
            layouts,problem,compile_error:=layout_reflect(r.runner,r.slangc,r.root,r.copied,e.folder,compiled_path,e.name,temporary,allocator,attributes=e.vfx,vfx=e.vfx,prelude=e.prelude,plugins=r.plugins)
            if problem!="" {
                e.error=problem
                // The same sources do not compile the next time either.
                if compile_error {write_file_atomic(e.caches[2],transmute([]u8)problem)}
                continue
            }
            e.layouts=layouts
            layout_write(e.caches[0],e.fingerprint,layouts[0])
            if e.vfx {layout_write(e.caches[1],e.fingerprint,layouts[1])}
        }
    }
    // Each reflection waits on its compilation: up to `workers` at once.
    js:jobs.Job_System
    if !jobs.system_init(&js,{threads=clamp(workers,1,pending)-1}) {
        work(r,0,len(r.entries),jobs.OWNER)
        return
    }
    jobs.parallel_for(&js,jobs.OWNER,len(r.entries),1,work,r)
    jobs.system_destroy(&js)
}

// Builds the catalog of the built-in programs and those of a project into
// `output`: catalog.json, the includes of the dispatchers, of the schema and
// of the shared constants, and a copy of every program source under
// include/programs, so the generation compiles without the project. The reflection of a program is kept in the folder
// `cache`, named by the digest of what the program is compiled from, and
// reused wherever that digest comes up again; what the cache lacks is
// reflected by up to `workers` compilations at once. files: what the
// generation has read already; nil reads everything here. A program of a
// project or of a plugin that fails is left out and named in the catalog; one
// of the engine that fails is an error. All results are in `allocator`.
programs_generate :: proc(runner:^Runner,root,project,output,slangc,version,cache:string,sources:[]Source={},allocator:=context.allocator,files:^Sources=nil,workers:=1) -> (catalog:Catalog,error:string) {
    local:Sources
    files:=files
    if files==nil {
        sources_init(&local,context.temp_allocator)
        files=&local
    }
    include:=path_join(output,"include",allocator=context.temp_allocator)
    copied:=path_join(include,"programs",allocator=context.temp_allocator)
    materials:=path_join(root,"shaders/materials",allocator=context.temp_allocator)
    shared:=path_join(root,"shaders/include",allocator=context.temp_allocator)
    project_shaders:=path_join(project,"shaders",allocator=context.temp_allocator) if project!="" else ""
    // Where programs come from besides the engine: the project first, then each plugin.
    Folder :: struct {label,folder,base_label,base:string}
    folders:=make([dynamic]Folder,context.temp_allocator)
    // A folder that does not exist is listed too: the generation is another one once it does.
    exists :: proc(files:^Sources,folder:string) -> bool {return sources_listing(files,folder,true).hash!=""}
    if project_shaders!="" && exists(files,project_shaders) {append(&folders,Folder{"project",project_shaders,"project",project})}
    for source in sources {
        if !identifier_valid(source.name) {return {},fmt.aprintf("%s is not a plugin name for its shaders",source.name,allocator=allocator)}
        folder:=path_clean(source.folder,context.temp_allocator)
        if !exists(files,folder) {continue}
        label:=strings.concatenate({"plugins/",source.name},context.temp_allocator)
        append(&folders,Folder{label,folder,label,folder})
    }
    os.make_directory_all(include)
    if !schema_write(include) {return {},fmt.aprintf("could not write %s and %s",SCHEMA_INCLUDE,CONSTANTS_INCLUDE,allocator=allocator)}
    owned,owned_problem:=owned_constants_write(files,include,project,sources,allocator)
    if owned_problem!="" {return {},owned_problem}
    if os.exists(copied) {base.remove_all(copied)}
    if failed:=copy_sources(files,materials,path_join(copied,"builtin",allocator=context.temp_allocator));failed!="" {return {},fmt.aprintf("could not copy the programs of the engine: %s",failed,allocator=allocator)}
    paths:=make([dynamic]string,context.temp_allocator)
    append(&paths,..sources_in(files,materials,".slang",context.temp_allocator))
    hash:Sha256
    sha_begin(&hash)
    sha_text(&hash,version)
    // Every shared source contributes to the identity of the catalog.
    for path in sources_in(files,shared,".slang",context.temp_allocator) {sha_bytes(&hash,sources_file(files,path).data)}
    for entry in folders {
        if failed:=copy_sources(files,entry.folder,path_join(copied,entry.label,allocator=context.temp_allocator));failed!="" {return {},fmt.aprintf("could not copy the programs of %s: %s",entry.folder,failed,allocator=allocator)}
        for path in sources_below(files,entry.folder) {
            if strings.has_suffix(path,".slang") {append(&paths,path)}
            relative,_:=path_relative(path,entry.folder)
            sha_text(&hash,entry.label)
            sha_text(&hash,relative)
            sha_bytes(&hash,sources_file(files,path).data)
        }
    }
    temporary,temporary_error:=os.make_directory_temp("","mirai-material-reflection-*",context.temp_allocator)
    if temporary_error!=nil {return {},strings.clone("could not create the temporary reflection folder",allocator)}
    temporary=path_clean(temporary,context.temp_allocator)
    defer base.remove_all(temporary)

    configuration:=transmute([]u8)strings.concatenate({GENERATOR_CONTRACT,version,shared_constants(),owned},context.temp_allocator)
    bases:=make([dynamic]Base,context.temp_allocator)
    for entry in folders {append(&bases,Base{entry.base_label,entry.base})}
    append(&bases,Base{"engine",root})
    plugin_folders:=make([dynamic]string,context.temp_allocator)
    for entry in folders {
        if entry.label!="project" {append(&plugin_folders,entry.folder)}
    }
    programs:=make([dynamic]abi.Program,allocator)
    dispatchers:=dispatchers_make()
    vfx_names:=make([dynamic]string,allocator)
    surface_names:=make([dynamic]string,allocator)
    vertex_names:=make([dynamic]string,allocator)
    refused:=make([dynamic]string,allocator)
    // What each program declares, then the layouts the cache lacks, reflected at once, then the
    // catalog in the order of the sources.
    entries:=make([dynamic]Program_Entry,context.temp_allocator)
    for path in paths {
        source:=sources_file(files,path)
        if !source.found {return {},fmt.aprintf("could not read %s",path,allocator=allocator)}
        text:=string(source.data)
        said:=program_directives(text)
        // Shared modules and includes have no entry contract of their own.
        if said.name=="" {continue}
        name:=said.name
        e:=Program_Entry{path=path,text=text,domain=said.domain,name=name,vfx=said.domain=="vfx",said=said}
        e.metadata=make(map[string]json.Object,context.temp_allocator)
        for each in said.metadata {
            field,value:=each[0],each[1]
            parsed,parse_error:=json.parse_string(value,parse_integers=true,allocator=context.temp_allocator)
            object,is_object:=parsed.(json.Object)
            if parse_error!=.None || !is_object {e.metadata_problem=fmt.aprintf("%s.%s: invalid parameter metadata",name,field,allocator=allocator);break}
            e.metadata[field]=object
        }
        append(&entries,e)
        if e.metadata_problem!="" {continue}
        entry:=&entries[len(entries)-1]
        // The indices of the resources of a Vfx program in its namespace, also for its reflection.
        if entry.vfx {
            if entry.resources,entry.problem=program_resources(name,said.resources[:],allocator);entry.problem!="" {continue}
            if entry.stages,entry.problem=program_stages(name,said.stages[:],entry.resources,allocator);entry.problem!="" {continue}
            entry.prelude=vfx_prelude(name,entry.resources)
        }
        // Include paths are kept in the staged copy; names are validated identifiers.
        if inside,is_builtin:=path_relative(path,materials);is_builtin {
            entry.relative=strings.concatenate({"builtin/",inside},allocator)
        } else {
            for folder in folders {
                if !path_inside(path,folder.folder) {continue}
                inside,_=path_relative(path,folder.folder)
                entry.relative=strings.concatenate({folder.label,"/",inside},allocator)
                break
            }
        }
        entry.folder=path_parent(path)
        include_dirs:=make([dynamic]string,context.temp_allocator)
        for folder in ENGINE_INCLUDES {append(&include_dirs,path_join(root,folder,allocator=context.temp_allocator))}
        append(&include_dirs,materials)
        for folder in folders {append(&include_dirs,folder.folder)}
        append(&include_dirs,entry.folder)
        dependency:=fingerprint(path,include_dirs[:],bases[:],configuration,context.temp_allocator,files)
        contract:=fingerprint(path_join(shared,"mirai_vfx.slang" if entry.vfx else "mirai_material.slang",allocator=context.temp_allocator),include_dirs[:],bases[:],configuration,context.temp_allocator,files)
        entry.fingerprint=sha_of(transmute([]u8)strings.concatenate({dependency,contract},context.temp_allocator),context.temp_allocator)
        entry.caches[0]=path_join(cache,strings.concatenate({entry.fingerprint,".json"},context.temp_allocator),allocator=context.temp_allocator)
        entry.caches[1]=path_join(cache,strings.concatenate({entry.fingerprint,".attributes.json"},context.temp_allocator),allocator=context.temp_allocator)
        // A layout without a parameter the source declares is not this source's: one cached
        // from a copy being written is reflected again, and a reflection that lacks it fails.
        cached:bool
        entry.layouts[0],cached=layout_read(entry.caches[0],entry.fingerprint,context.temp_allocator)
        entry.cached=cached && layout_missing(entry.layouts[0],entry.metadata)==""
        if entry.cached && entry.vfx {entry.layouts[1],entry.cached=layout_read(entry.caches[1],entry.fingerprint,context.temp_allocator)}
        entry.caches[2]=path_join(cache,strings.concatenate({entry.fingerprint,".refused.txt"},context.temp_allocator),allocator=context.temp_allocator)
        if !entry.cached {
            if said,read_error:=os.read_entire_file(entry.caches[2],allocator);read_error==nil {
                entry.error,entry.cached=string(said),true
                cache_touch(entry.caches[2])
            }
        }
        // Only a Surface program has a coverage, and one that does not compile has none.
        entry.caches[3]=path_join(cache,strings.concatenate({entry.fingerprint,".coverage.txt"},context.temp_allocator),allocator=context.temp_allocator)
        entry.probed=entry.domain!="surface" || entry.error!=""
        if !entry.probed {
            // "0", or "1" and the hash of its alpha.
            if said,read_error:=os.read_entire_file(entry.caches[3],context.temp_allocator);read_error==nil && (string(said)=="0" || len(said)==2+len(entry.alpha) && said[0]=='1') {
                entry.coverage,entry.probed=said[0]=='1',true
                if entry.coverage {copy(entry.alpha[:],said[2:])}
                cache_touch(entry.caches[3])
            }
        }
    }
    reflection:=Program_Reflection{entries=entries[:],runner=runner,slangc=slangc,root=root,copied=copied,temporary=temporary,plugins=plugin_folders[:]}
    programs_reflect(&reflection,workers)
    defer for &e in entries {virtual.arena_destroy(&e.arena)}
    broken:=make([dynamic]string,context.temp_allocator)
    programs_loop: for &e in entries {
        left_out:=len(refused)
        defer if path_inside(e.path,materials) {append(&broken,..refused[left_out:])}
        name,text_bytes:=e.name,transmute([]u8)e.text
        of,_:=program_domain(e.domain)
        taken:=name=="pbr"
        for program in programs {taken||=program.name==name}
        if taken {append(&refused,fmt.aprintf("duplicate/reserved program name %s",name,allocator=allocator));continue}
        if e.metadata_problem!="" {append(&refused,e.metadata_problem);continue}
        metadata:=e.metadata
        sha_bytes(&hash,text_bytes)
        if e.problem!="" {append(&refused,e.problem);continue}
        resources,stages,prelude,relative:=e.resources,e.stages,e.prelude,e.relative
        if e.error!="" {append(&refused,fmt.aprintf("%s: %s",name,e.error,allocator=allocator));continue}
        layout:=e.layouts[0]
        if missing:=layout_missing(layout,metadata);missing!="" {
            append(&refused,fmt.aprintf("%s: the reflection of Parameters has no %s, which the program declares; build the shaders again",name,missing,allocator=allocator))
            continue
        }
        if layout.size>PARAMETER_BYTES || len(layout.fields)>MAX_PARAMETERS {
            append(&refused,fmt.aprintf("%s: Parameters exceeds %d fields/%d bytes",name,MAX_PARAMETERS,PARAMETER_BYTES,allocator=allocator))
            continue
        }
        parameters:=make([]abi.Program_Parameter,len(layout.fields),allocator)
        for field,index in layout.fields {
            parameter,problem:=program_parameter(field,metadata[field.name],allocator)
            if problem!="" {append(&refused,fmt.aprintf("%s.%s: %s",name,field.name,problem,allocator=allocator));continue programs_loop}
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            parameters[index]=parameter
        }
        id:=len(programs)+1
        layers:asset.Material_Layers
        if of==.Surface {
            for field,layer in PROGRAM_LAYERS {
                if word_in(e.text,field) {layers+={layer}}
            }
        }
        attributes:int
        attribute_fields:[]abi.Program_Attribute
        vertex:abi.Program_Vertex
        if of==.Surface {
            problem:string
            if vertex,problem=program_vertex(name,e.said.vertex,layout,allocator);problem!="" {append(&refused,problem);continue}
        } else if e.said.vertex!=nil {
            append(&refused,fmt.aprintf("%s: only a Surface program moves vertices (`//! vertex`)",name,allocator=allocator))
            continue
        }
        if of==.Vfx {
            attributes=e.layouts[1].size
            attribute_fields=make([]abi.Program_Attribute,len(e.layouts[1].fields),allocator)
            for field,i in e.layouts[1].fields {
                kind:=abi.Program_Kind.Float
                switch field.scalar {
                case "int32": kind=.Int
                case "uint32": kind=.Uint
                case "bool": kind=.Bool
                }
                attribute_fields[i]={strings.clone(field.name,allocator),kind,u8(clamp(field.count,1,4)),u16(field.offset)}
            }
            // The include of the program alone: the stages of each program are compiled with it.
            own,failure:=vfx_program_include(name,prelude,relative,layout,e.layouts[1],stages,e.said)
            if failure!="" {append(&refused,strings.clone(failure,allocator));continue}
            folder:=path_join(include,VFX_FOLDER,name,allocator=context.temp_allocator)
            os.make_directory_all(folder)
            if !write_file(path_join(folder,VFX_INCLUDE,allocator=context.temp_allocator),transmute([]u8)own) {
                append(&refused,fmt.aprintf("%s: could not write its %s",name,VFX_INCLUDE,allocator=allocator))
                continue
            }
            append(&vfx_names,strings.clone(name,allocator))
        } else {
            // The include of a Surface program alone: the stages of each program are compiled with it.
            if of==.Surface {
                folder:=path_join(include,SURFACE_FOLDER,name,allocator=context.temp_allocator)
                os.make_directory_all(folder)
                if !write_file(path_join(folder,SURFACE_INCLUDE,allocator=context.temp_allocator),transmute([]u8)surface_program_include(name,relative,layout,vertex.declared)) {
                    append(&refused,fmt.aprintf("%s: could not write its %s",name,SURFACE_INCLUDE,allocator=allocator))
                    continue
                }
                append(&surface_names,strings.clone(name,allocator))
                if vertex.declared {append(&vertex_names,strings.clone(name,allocator))}
            }
            dispatchers_add(&dispatchers,of,id,name,relative,layout,e.coverage,string(e.alpha[:]) if e.coverage else "")
        }
        moves,births,prepare:=of==.Vfx && e.said.moves,of==.Vfx && e.said.births,of==.Vfx && e.said.prepare
        append(&programs,abi.Program{id=u32(id),name=strings.clone(name,allocator),domain=of,source=relative,size=layout.size,parameters=parameters,layers=layers,attributes=attributes,attribute_fields=attribute_fields,resources=resources,stages=stages,moves=moves,births=births,prepare=prepare,coverage=e.coverage,standard=of==.Surface && word_in(e.text,"mirai_surface_standard"),vertex=vertex})
    }
    // A project does without a program of its own that fails; nothing does without one of the engine.
    if len(broken)>0 {
        return {},fmt.aprintf("the programs of the engine in shaders/materials must all compile, and these do not:\n%s\nFix the source each one names, or the include of the engine it takes, and generate the shaders again (`mirai shaders`)",strings.join(broken[:],"\n",context.temp_allocator),allocator=allocator)
    }
    if failed:=dispatchers_write(&dispatchers,include);failed!="" {return {},fmt.aprintf("could not write %s",failed,allocator=allocator)}
    catalog={fingerprint=sha_hex(&hash,allocator),compiler=strings.clone(version,allocator),programs=programs[:],refused=refused[:],vfx=vfx_names[:],surface=surface_names[:],vertex=vertex_names[:]}
    if !write_file(path_join(output,abi.SHADER_CATALOG,allocator=context.temp_allocator),catalog_text(catalog)) {return {},fmt.aprintf("could not write %s",abi.SHADER_CATALOG,allocator=allocator)}
    return catalog,""
}

// The text of SHADER_CATALOG, in temporary memory.
@(private)
catalog_text :: proc(catalog:Catalog) -> []u8 {
    e:=catalog.extensions
    frame:=abi.Frame_Catalog{size=e.frame_size,nested=e.nested,instance_ids=e.instance_ids,extensions=make([]abi.Frame_Extension,len(e.fields),context.temp_allocator)}
    for field,i in e.fields {frame.extensions[i]={field.name,field.offset,field.size}}
    text,_:=serial.text_encode(abi.Shader_Catalog{abi.SHADER_CATALOG_VERSION,catalog.fingerprint,catalog.compiler,catalog.programs,frame},.Pretty,context.temp_allocator)
    return text
}

// Whether text names word as a whole identifier.
@(private)
word_in :: proc(text,word:string) -> bool {
    rest,offset:=text,0
    for {
        at:=strings.index(rest,word)
        if at<0 {return false}
        start,end:=offset+at,offset+at+len(word)
        if (start==0 || !is_word(text[start-1])) && (end==len(text) || !is_word(text[end])) {return true}
        rest=rest[at+len(word):]
        offset=end
    }
}

