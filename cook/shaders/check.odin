package shaders

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"

// Checks one program without publishing it: the rules below read its source
// for the mistakes programs are written with, and Slang compiles it where it
// runs: a Surface program in a raster stage and in a stage of rays of the
// check's own, a program of another domain in the stages of the engine that
// evaluate it, against dispatchers that hold only it. Nothing of a generation
// is written; the compilations go to a folder of their own.

Check_Options :: struct {
    root:   string,   // the engine
    project:string,   // "": a program of the engine
    sources:[]Source, // the shaders/ of the active plugins
    path:   string,   // the .slang of the program
    text:   string,   // checked in place of what the file holds; "": the file
    tools:  [Tool]string,
}

Check_Result :: struct {
    name:string,
    domain:Program_Domain,
    file:string, // the program as its diagnostics name it
    diagnostics:[]Diagnostic,
    errors,warnings:int,
    compiled:bool, // every stage of the check compiled
    parameters_size:int,
    error:string,  // the check could not run
}

check_result_destroy :: proc(r:^Check_Result,allocator:=context.allocator) {
    delete(r.name,allocator);delete(r.file,allocator);delete(r.error,allocator)
    diagnostics_destroy(r.diagnostics,allocator)
    r^={}
}

@(private="file")
DERIVATIVES :: [?]string{"ddx","ddy","ddx_fine","ddy_fine","ddx_coarse","ddy_coarse","fwidth","dFdx","dFdy","dFdxFine","dFdyFine"}
@(private="file")
IMPLICIT_SAMPLES :: [?]string{"Sample","SampleBias","SampleCmp"}
@(private="file")
TEXTURE_METHODS :: [?]string{"SampleLevel","SampleGrad","Load","GetDimensions","SampleCmpLevelZero","Gather"}
@(private="file")
TEXTURE_TYPES :: [?]string{"Texture2D","Texture3D","TextureCube","Texture2DArray","SamplerState","SamplerComparisonState","sampler2D","sampler3D","samplerCube","RWTexture2D"}

// GLSL and other languages programs are not written in: what Slang calls it.
@(private="file")
FOREIGN :: [?][2]string{
    {"vec2","float2"},{"vec3","float3"},{"vec4","float4"},{"ivec2","int2"},{"ivec3","int3"},{"ivec4","int4"},
    {"uvec2","uint2"},{"uvec3","uint3"},{"uvec4","uint4"},{"bvec2","bool2"},{"bvec3","bool3"},{"bvec4","bool4"},
    {"mat2","float2x2"},{"mat3","float3x3"},{"mat4","float4x4"},{"mix","lerp"},{"fract","frac"},{"mod","fmod"},
    {"inversesqrt","rsqrt"},{"texture","mirai_sample_texture(ctx, p.<texture parameter>, uv, 0)"},
    {"texture2D","mirai_sample_texture(ctx, p.<texture parameter>, uv, 0)"},{"textureLod","mirai_sample_texture_level(p.<texture parameter>, uv, level)"},
    {"texelFetch","mirai_sample_texture_level(p.<texture parameter>, uv, level)"},{"tex2D","mirai_sample_texture(ctx, p.<texture parameter>, uv, 0)"},
    {"tex2Dlod","mirai_sample_texture_level(p.<texture parameter>, uv, level)"},
}

// What a program of each domain calls besides its own functions.
@(private="file")
MIRAI_API :: [Program_Domain]string{
    .Surface="Slang intrinsics, the functions of the program and mirai_sample_texture(ctx, index, uv, lod), mirai_sample_texture_level(index, uv, level), mirai_sample_texture_grad(index, uv, dx, dy), mirai_surface_default(ctx) and mirai_surface_mix(a, b, mask)",
    .Postprocess="Slang intrinsics, the functions of the program and mirai_scene_color(ctx, uv), mirai_scene_depth(ctx, uv), mirai_scene_normal(ctx, uv), mirai_outline(ctx, uv), mirai_sample_texture(ctx, index, uv, lod) and mirai_sample_texture_level(index, uv, level)",
    .Vfx="Slang intrinsics, the functions of the program and mirai_vfx_random(seed) and mirai_vfx_texture(index, uv, level)",
    .Ui="Slang intrinsics, the functions of the program and mirai_sample_texture_level(index, uv, level)",
}

// How a program of each domain reads a texture parameter.
@(private="file")
TEXTURE_READ :: [Program_Domain]string{
    .Surface="mirai_sample_texture(ctx, p.<texture parameter>, uv, 0)",
    .Postprocess="mirai_sample_texture(ctx, p.<texture parameter>, uv, 0)",
    .Vfx="mirai_vfx_texture(p.<texture parameter>, uv, level)",
    .Ui="mirai_sample_texture_level(p.<texture parameter>, uv, level)",
}

// The functions a program of each domain declares in its namespace, one per
// line: the check reads their signatures from here and gives the line as fix.
@(private="file")
ENTRIES :: [Program_Domain]string{
    .Surface="Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {Mirai_Surface s=mirai_surface_default(ctx); ... return s;}",
    .Postprocess="float4 evaluate(Mirai_PostProcess_Context ctx, Parameters p) {... return ctx.color;}",
    .Vfx="void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {...}\n"+
        "void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {...}\n"+
        "void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {...}",
    .Ui="float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {... return ctx.color;}",
}

// The function of a Surface program that says `//! vertex`.
@(private="file")
VERTEX_ENTRY :: "Mirai_Vertex vertex(Mirai_Vertex_Context ctx, Parameters p) {Mirai_Vertex v=mirai_vertex_default(ctx); ... return v;}"

// The stages of the engine that evaluate a program of each domain; a Surface
// program reaches many, and the check compiles it in two of its own; a Vfx
// program, in the stages of plugins marked `//! per vfx program`.
@(private="file")
CHECK_STAGES :: [Program_Domain][]string{
    .Surface={},
    .Postprocess={"postprocess.frag.slang"},
    .Vfx={},
    .Ui={"ui.frag.slang"},
}

// A ui program receives the four floats of its node.
@(private="file")
UI_PARAMETER_BYTES :: 16

@(private="file")
Checker :: struct {
    domain:Program_Domain,
    src:^Surface_Source,
    graph:^Surface_Graph,
    file:string,
    out:^[dynamic]Diagnostic,
    allocator:runtime.Allocator,
}

@(private="file")
report :: proc(c:^Checker,severity:Severity,code:string,line,column:i32,message,fix:string) {
    append(c.out,Diagnostic{severity=severity,code=code,file=c.file,line=int(line),column=int(column),message=message,fix=fix})
}

@(private="file")
token_at :: proc(c:^Checker,index:int) -> Token {return c.src.tokens[clamp(index,0,len(c.src.tokens)-1)]}

// What a program has to declare: its name, a namespace of that name with
// struct Parameters and the functions of its domain (ENTRIES).
@(private="file")
rules_declaration :: proc(c:^Checker) -> (name:string) {
    src:=c.src
    if src.name=="" {
        report(c,.Error,"mirai.declaration",1,1,"the program does not declare its name","start the file with `//! mirai surface Name` (or postprocess, vfx or ui in place of surface)")
        return src.namespace_name
    }
    if src.name=="pbr" {report(c,.Error,"mirai.declaration",src.declared_line,1,"pbr is the name of the standard model","give the program another name")}
    if src.namespace_name!=src.name {
        line:=src.namespace_line>0?src.namespace_line:src.declared_line
        report(c,.Error,"mirai.declaration",line,1,fmt.aprintf("the code of %s is not in `namespace %s`",src.name,src.name,allocator=c.allocator),fmt.aprintf("put struct Parameters and its functions inside `namespace %s {{ ... }}`",src.name,allocator=c.allocator))
    }
    if !src.has_parameters {report(c,.Error,"mirai.declaration",src.declared_line,1,"the program has no struct Parameters","declare `struct Parameters {float strength;};` inside its namespace, with a field per value it takes")}
    if c.domain==.Vfx && !("Attributes" in src.structs) {
        report(c,.Error,"mirai.declaration",src.declared_line,1,"the program has no struct Attributes",fmt.aprintf("declare `struct Attributes {{float phase;}};` inside its namespace: what it keeps of each particle between steps, up to %d bytes",ATTRIBUTE_BYTES,allocator=c.allocator))
    }
    entries:=ENTRIES
    rules_contract(c,entries[c.domain])
    if c.domain==.Surface && program_directives(src.text).vertex!=nil {rules_contract(c,VERTEX_ENTRY)}
    return src.name
}

// The functions of a contract, one per line, with their signatures.
@(private="file")
rules_contract :: proc(c:^Checker,entries:string) {
    src,domains:=c.src,PROGRAM_DOMAINS
    lines:=strings.split_lines(entries,context.temp_allocator)
    contract:=surface_parse(entries,context.temp_allocator)
    each: for want,i in contract.functions {
        for have in src.functions {
            if have.name!=want.name {continue}
            same:=have.type==want.type && len(have.params)==len(want.params)
            for param,k in have.params {
                if !same {break}
                same=param.type==want.params[k].type && param.out==want.params[k].out && param.inout==want.params[k].inout
            }
            if !same {
                t:=token_at(c,have.first)
                report(c,.Error,"mirai.declaration",t.line,t.column,fmt.aprintf("%s does not have the signature of a %s program",want.name,domains[c.domain],allocator=c.allocator),lines[i])
            }
            continue each
        }
        report(c,.Error,"mirai.declaration",src.declared_line,1,fmt.aprintf("the program has no %s",want.name,allocator=c.allocator),lines[i])
    }
}

// The line of the first function of its domain the program declares, where
// what the compiler says of the code of the check is put.
@(private="file")
entry_line :: proc(c:^Checker) -> int {
    entries:=ENTRIES
    contract:=surface_parse(entries[c.domain],context.temp_allocator)
    for want in contract.functions {
        for f in c.src.functions {if f.name==want.name {return int(token_at(c,f.first).line)}}
    }
    return int(c.src.declared_line)
}

// What a call or a name of the code is: derivatives, textures used as
// objects, functions of another language and conversions to linear color.
@(private="file")
rules_code :: proc(c:^Checker) {
    src:=c.src
    reads:=TEXTURE_READ
    srgb_lines:=make(map[i32]bool,context.temp_allocator)
    for t in src.tokens {
        if t.kind==.Identifier {
            for name in TEXTURE_TYPES {
                if t.text!=name {continue}
                report(c,.Error,"mirai.texture_object",t.line,t.column,fmt.aprintf("a program does not declare %s",name,allocator=c.allocator),fmt.aprintf("read a texture through a parameter `uint name;` with {{\"kind\":\"texture\"}} and %s",reads[c.domain],allocator=c.allocator))
            }
        }
        if t.kind==.Number && !srgb_lines[t.line] && c.domain!=.Ui {
            if value,ok:=literal(t.text);ok && (abs(value-12.92)<1e-6 || abs(value-0.04045)<1e-7 || abs(value-0.0031308)<1e-9) {
                srgb_lines[t.line]=true
                report(c,.Warning,"mirai.srgb_conversion",t.line,t.column,"the code converts between sRGB and linear color","colors arrive linear: color parameters are linear and mirai_sample_texture returns linear values of textures marked srgb; remove the conversion")
            }
        }
    }
    for e in src.exprs {
        if e.kind!=.Call {continue}
        callee:=src.exprs[e.kids[0]]
        args:=e.kids[1:]
        at:=token_at(c,callee.kind==.Member?callee.last:callee.first)
        switch callee.kind {
        case .Name:
            for name in DERIVATIVES {
                if callee.text!=name {continue}
                #partial switch c.domain {
                case .Surface: report(c,.Error,"mirai.ray_derivatives",at.line,at.column,fmt.aprintf("%s needs screen derivatives, and Surface programs also run on ray hits (ctx.ray), which have none",name,allocator=c.allocator),"sample with mirai_sample_texture(ctx, index, uv, lod), which takes the level from ctx, and widen filters with ctx.lod")
                case .Vfx: report(c,.Error,"mirai.derivatives",at.line,at.column,fmt.aprintf("%s needs screen derivatives, and Vfx programs run in compute and vertex stages, which have none",name,allocator=c.allocator),"read textures with mirai_vfx_texture(p.<texture parameter>, uv, level), which takes the level")
                }
            }
            for pair in FOREIGN {
                if callee.text!=pair[0] || function_named(src,callee.text) {continue}
                report(c,.Error,"mirai.unknown_api",at.line,at.column,fmt.aprintf("%s is not a function of Slang programs",callee.text,allocator=c.allocator),fmt.aprintf("use %s",pair[1],allocator=c.allocator))
            }
            if callee.text=="pow" && len(args)==2 && !srgb_lines[at.line] && c.domain!=.Ui {
                exponent,constant:=expr_value(src,args[1])
                if constant && (abs(exponent-2.2)<0.01 || abs(exponent-2.4)<0.01 || abs(exponent-1/2.2)<0.01 || abs(exponent-1/2.4)<0.01) {
                    srgb_lines[at.line]=true
                    report(c,.Warning,"mirai.srgb_conversion",at.line,at.column,"pow with a gamma exponent converts between sRGB and linear color","colors arrive linear: color parameters are linear and mirai_sample_texture returns linear values of textures marked srgb; remove the pow")
                }
            }
        case .Member:
            for name in IMPLICIT_SAMPLES {
                if callee.text!=name {continue}
                #partial switch c.domain {
                case .Surface: report(c,.Error,"mirai.ray_derivatives",at.line,at.column,fmt.aprintf("%s takes its level from screen derivatives, and Surface programs also run on ray hits",name,allocator=c.allocator),"use mirai_sample_texture(ctx, p.<texture parameter>, uv, 0)")
                case .Vfx: report(c,.Error,"mirai.derivatives",at.line,at.column,fmt.aprintf("%s takes its level from screen derivatives, and Vfx programs run in compute and vertex stages",name,allocator=c.allocator),"use mirai_vfx_texture(p.<texture parameter>, uv, level)")
                }
            }
            for name in TEXTURE_METHODS {
                if callee.text!=name {continue}
                report(c,.Error,"mirai.texture_object",at.line,at.column,fmt.aprintf("%s reads a texture object, and programs read textures only through their parameters",name,allocator=c.allocator),fmt.aprintf("use %s",reads[c.domain],allocator=c.allocator))
            }
        case .Number,.Call,.Index,.Unary,.Binary,.Ternary,.List:
        }
    }
}

@(private="file")
function_named :: proc(src:^Surface_Source,name:string) -> bool {
    for f in src.functions {if f.name==name {return true}}
    return false
}

// The value of an expression of literals.
@(private="file")
expr_value :: proc(src:^Surface_Source,e:int) -> (value:f64,ok:bool) {
    expr:=src.exprs[e]
    #partial switch expr.kind {
    case .Number: return literal(expr.text)
    case .Unary:
        v,known:=expr_value(src,expr.kids[0])
        return -v,known && expr.text=="-"
    case .Binary:
        a,known_a:=expr_value(src,expr.kids[0])
        b,known_b:=expr_value(src,expr.kids[1])
        if !known_a || !known_b {return}
        switch expr.text {
        case "/": return a/b,b!=0
        case "*": return a*b,true
        case "+": return a+b,true
        case "-": return a-b,true
        }
    }
    return
}

// What the program writes to its surface, by what the graph knows of each value.
@(private="file")
rules_outputs :: proc(c:^Checker) {
    for node in c.graph.nodes {
        if node.kind!=.Output {continue}
        f:=node.facts
        line:=node.first_line
        components:=max(f.components,1)
        switch node.label {
        case "out.base_color":
            above:=f.constant?slice.max(f.value[:min(components,4)]):f.upper
            if above>1 && above<math.INF_F64 {
                report(c,.Warning,"mirai.base_color_range",line,1,fmt.aprintf("base_color can reach %.3g; it is a reflectance from 0 to 1",above,allocator=c.allocator),"keep it under 1 (saturate) and give light with emission")
            }
        case "out.emission":
            zero:=f.constant && slice.max(f.value[:min(components,4)])<=0
            if !zero && f.upper<=1 {
                report(c,.Warning,"mirai.emission_units",line,1,fmt.aprintf("emission is at most %.3g: it is luminance in nits, and 1 nit is close to black next to the studio and daylight",f.upper,allocator=c.allocator),"multiply by an intensity: `//! parameter intensity {\"default\":500,\"min\":0,\"max\":100000}` and `s.emission=p.color*p.intensity;` (a screen is about 200 nits, a lamp thousands)")
            }
        case "out.roughness":
            low:=f.constant?f.value[0]:f.upper
            if low<0.045 {
                report(c,.Warning,"mirai.roughness_minimum",line,1,fmt.aprintf("roughness %.3g is below 0.045, the least the renderer takes (0.08 for point lights)",low,allocator=c.allocator),"use 0.045 or more; a mirror needs no 0")
            }
        case "out.normal","out.coat_normal":
            field:=node.label[len("out."):]
            switch {
            case f.constant:
                report(c,.Warning,"mirai.normal_tangent_space",line,1,fmt.aprintf("%s is a constant: it is a direction in the world, not in tangent space",field,allocator=c.allocator),"start from ctx.normal, or turn a tangent-space normal with ctx.tangent (see the fix of mirai.normal_tangent_space)")
            case f.textured && !f.tangent:
                report(c,.Warning,"mirai.normal_tangent_space",line,1,fmt.aprintf("%s comes from a texture without the tangent frame: it is a direction in the world",field,allocator=c.allocator),"float3 t=mirai_sample_texture(ctx,p.normal_map,ctx.uv0,0).xyz*2-1; float3 b=ctx.tangent.w*cross(ctx.vertex_normal,ctx.tangent.xyz); s.normal=normalize(t.x*ctx.tangent.xyz+t.y*b+t.z*ctx.normal);")
            case !f.normalized:
                report(c,.Warning,"mirai.normal_unnormalized",line,1,fmt.aprintf("%s may not be of length 1",field,allocator=c.allocator),fmt.aprintf("s.%s=normalize(...);",field,allocator=c.allocator))
            }
        case "out.specular_tangent":
            if !f.normalized {report(c,.Warning,"mirai.normal_unnormalized",line,1,"specular_tangent may not be of length 1","s.specular_tangent=normalize(...);")}
        }
    }
}

// Programs run on every ray hit of the light and the reflections too: a loop
// that does not look at ctx.ray costs the same there.
@(private="file")
rules_cost :: proc(c:^Checker) {
    for t,i in c.src.tokens {
        if t.text=="ray" && i>0 && c.src.tokens[i-1].text=="." {return}
    }
    for node in c.graph.nodes {
        if node.kind!=.Loop {continue}
        report(c,.Info,"mirai.ray_cost",node.first_line,1,"this loop runs as long on every ray hit of the light and the reflections","do less of it where ctx.ray is true (Ocean takes 3 octaves there and 6 in raster)")
        return
    }
}

@(private="file")
COMPONENTS :: [?]struct{type:string,count:int}{{"float",1},{"float2",2},{"float3",3},{"float4",4},{"int",1},{"int2",2},{"int3",3},{"int4",4},{"uint",1},{"uint2",2},{"uint3",3},{"uint4",4},{"bool",1}}

@(private="file")
type_components :: proc(type:string) -> int {
    for entry in COMPONENTS {if entry.type==type {return entry.count}}
    return 0
}

// The bytes of struct Parameters in a uniform buffer: a vector does not cross
// 16 bytes, a float3 starts on 16.
@(private="file")
parameters_size :: proc(counts:[]int) -> int {
    offset:=0
    for count in counts {
        size:=count*4
        align:=count==1?4:count==2?8:16
        offset=(offset+align-1)/align*align
        offset+=size
    }
    return (offset+15)/16*16
}

// An order of the fields that packs them: each float3 with a scalar after it.
@(private="file")
packed_order :: proc(fields:[]Surface_Field,allocator:runtime.Allocator) -> (text:string,size:int) {
    order:=make([dynamic]Surface_Field,context.temp_allocator)
    scalars:=make([dynamic]Surface_Field,context.temp_allocator)
    pairs:=make([dynamic]Surface_Field,context.temp_allocator)
    for f in fields {
        switch type_components(f.type) {
        case 4: append(&order,f)
        case 2: append(&pairs,f)
        case 1: append(&scalars,f)
        }
    }
    for f in fields {
        if type_components(f.type)!=3 {continue}
        append(&order,f)
        if len(scalars)>0 {append(&order,pop_front(&scalars))}
    }
    append(&order,..pairs[:])
    append(&order,..scalars[:])
    b:=strings.builder_make(allocator)
    strings.write_string(&b,"struct Parameters {")
    counts:=make([dynamic]int,context.temp_allocator)
    for f in order {
        fmt.sbprintf(&b,"%s %s;",f.type,f.name)
        append(&counts,type_components(f.type))
    }
    strings.write_string(&b,"};")
    return strings.to_string(b),parameters_size(counts[:])
}

// struct Parameters and its //! parameter lines: one for each field, of the
// kind the field is, within the 256 bytes the parameters travel in.
@(private="file")
rules_parameters :: proc(c:^Checker,layout:Layout,reflected:bool) -> (supported:bool) {
    src:=c.src
    supported=true
    fields:=make(map[string]Surface_Field,context.temp_allocator)
    for f in src.parameters {fields[f.name]=f}
    seen:=make(map[string]i32,context.temp_allocator)
    meta:=make(map[string]json.Object,context.temp_allocator)
    for m in src.metadata {
        if line,twice:=seen[m.field];twice {
            report(c,.Error,"mirai.parameter_duplicate",m.line,1,fmt.aprintf("%s has metadata twice (line %d)",m.field,line,allocator=c.allocator),"keep one `//! parameter` line per field")
            continue
        }
        seen[m.field]=m.line
        parsed,error:=json.parse_string(m.value,parse_integers=true,allocator=context.temp_allocator)
        object,is_object:=parsed.(json.Object)
        if error!=.None || !is_object {
            report(c,.Error,"mirai.parameter_metadata",m.line,1,fmt.aprintf("the metadata of %s is not a JSON object",m.field,allocator=c.allocator),fmt.aprintf("//! parameter %s {{\"default\":0.5,\"min\":0,\"max\":1}}",m.field,allocator=c.allocator))
            continue
        }
        meta[m.field]=object
        if _,declared:=fields[m.field];!declared && src.has_parameters {
            guess:="float"
            if list,is_list:=object["default"].(json.Array);is_list && len(list)>=2 && len(list)<=4 {guess=fmt.aprintf("float%d",len(list),allocator=context.temp_allocator)}
            if _,is_bool:=object["default"].(json.Boolean);is_bool {guess="bool"}
            if json_text(object["kind"])=="texture" {guess="uint"}
            report(c,.Error,"mirai.parameter_orphan",m.line,1,fmt.aprintf("struct Parameters has no field %s for this metadata",m.field,allocator=c.allocator),fmt.aprintf("add `%s %s;` to struct Parameters, or remove the line",guess,m.field,allocator=c.allocator))
        }
    }
    for f in src.parameters {
        if _,described:=meta[f.name];!described && seen[f.name]==0 {
            template:="{\"default\":0,\"min\":0,\"max\":1}"
            switch {
            case f.type=="float3": template="{\"default\":[1,1,1],\"min\":0,\"max\":1,\"color\":true}"
            case f.type=="bool": template="{\"default\":false}"
            case type_components(f.type)>1: template=fmt.aprintf("{{\"default\":[%s]}}",strings.trim_right(strings.repeat("0,",type_components(f.type),context.temp_allocator),","),allocator=context.temp_allocator)
            }
            report(c,.Warning,"mirai.parameter_missing",f.line,f.column,fmt.aprintf("%s has no `//! parameter` line: its slider has no range or default",f.name,allocator=c.allocator),fmt.aprintf("//! parameter %s %s",f.name,template,allocator=c.allocator))
        }
        read:=false
        for t,i in src.tokens {
            if t.text==f.name && t.kind==.Identifier && i>0 && src.tokens[i-1].text=="." {read=true;break}
        }
        if !read {report(c,.Warning,"mirai.parameter_unused",f.line,f.column,fmt.aprintf("the program never reads p.%s",f.name,allocator=c.allocator),"read it in evaluate or remove the field and its metadata")}
    }
    if !reflected {return false}
    for field in layout.fields {
        line:=fields[field.name].line
        if m,described:=seen[field.name];described {line=m}
        if _,problem:=program_parameter(field,meta[field.name],context.temp_allocator);problem!="" {
            supported=false
            report(c,.Error,"mirai.parameter_kind",line,1,fmt.aprintf("%s: %s",field.name,problem,allocator=c.allocator),"a color is `float3` with \"color\":true, a texture `uint` with \"kind\":\"texture\", and a default has a value per component within min and max")
        }
    }
    if layout.size>PARAMETER_BYTES || len(layout.fields)>MAX_PARAMETERS {
        supported=false
        order,size:=packed_order(src.parameters,c.allocator)
        fix:=size<=PARAMETER_BYTES && len(layout.fields)<=MAX_PARAMETERS?fmt.aprintf("reorder the fields so that each float3 takes a scalar after it (%d bytes): %s",size,order,allocator=c.allocator):fmt.aprintf("parameters travel in %d bytes and up to %d fields: take some out, or pack two values into one vector",PARAMETER_BYTES,MAX_PARAMETERS,allocator=c.allocator)
        report(c,.Error,"mirai.parameter_packing",src.parameters_line,1,fmt.aprintf("struct Parameters takes %d bytes in %d fields; the limit is %d bytes and %d fields",layout.size,len(layout.fields),PARAMETER_BYTES,MAX_PARAMETERS,allocator=c.allocator),fix)
    } else if c.domain==.Ui && layout.size>UI_PARAMETER_BYTES {
        supported=false
        report(c,.Error,"mirai.parameter_packing",src.parameters_line,1,fmt.aprintf("struct Parameters takes %d bytes; a ui program receives the %d bytes of the four values of its node",layout.size,UI_PARAMETER_BYTES,allocator=c.allocator),"keep up to four floats in struct Parameters, or pack values into one float4")
    }
    return
}

@(private="file")
CHECK_USE :: `float4 mirai_check_use(Mirai_Surface s) {
    float3 v=s.base_color+s.normal+s.emission+s.specular_color+s.specular_tangent+s.coat_color+s.coat_normal+s.fuzz_color+s.diffuse_transmission_color;
    return float4(v,s.alpha+s.metallic+s.roughness+s.occlusion+s.specular_factor+s.specular_ior+s.specular_anisotropy+s.coat_weight+s.coat_roughness+s.coat_ior+s.fuzz_weight+s.fuzz_roughness+s.diffuse_transmission_weight+(s.unlit?1.0:0.0));
}
`

@(private="file")
CHECK_RASTER :: `#include "native.slang"
#include "material_raster.slang"
#include <surface_programs.slang>
` + CHECK_USE + `struct Check_Input {
    [[vk::location(0)]] float3 world : TEXCOORD0;
    [[vk::location(1)]] float3 normal : TEXCOORD1;
    [[vk::location(2)]] float4 tangent : TEXCOORD2;
    [[vk::location(3)]] float2 uv0 : TEXCOORD3;
    [[vk::location(4)]] float2 uv1 : TEXCOORD4;
    [[vk::location(5)]] float4 color : TEXCOORD5;
    [[vk::location(6)]] nointerpolation uint instance : TEXCOORD6;
};
[shader("fragment")]
float4 main(Check_Input input) : SV_Target0 {
    Mirai_Surface_Context ctx = material_context_instance(material_context(input.world, input.normal, input.normal, input.tangent, input.uv0, input.uv1, float2(frame.texturing.x), false), input.instance, input.color);
    Mirai_Surface s = mirai_surface_default(ctx);
    mirai_evaluate_program(1u, materials[0].custom_params, ctx, s);
    return mirai_check_use(s);
}
`

@(private="file")
CHECK_RAY :: `#include "native.slang"
#include "scene.slang"
#include <surface_programs.slang>
` + CHECK_USE + `[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<float4> check_result : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[shader("compute")]
[numthreads(32, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    float3 n = normalize(float3(float(id.x), 1.0, 0.0));
    Mirai_Surface_Context ctx = material_context_instance(material_context(float3(id), n, n, float4(1, 0, 0, 1), float2(id.xy), float2(id.yx), float2(0.0), true), id.x, float4(float3(id), 1.0));
    Mirai_Surface s = mirai_surface_default(ctx);
    mirai_evaluate_program(1u, materials[0].custom_params, ctx, s);
    check_result[id.x] = mirai_check_use(s);
}
`

@(private="file")
Check_Compile :: struct {
    runner:^Runner,
    stage:string, // as its diagnostics name it
    command:[]string,
    output:string,
    ok:bool,
}

// On a thread of its own: its output is in the heap and the caller frees it.
@(private="file")
check_compile_run :: proc(job:^Check_Compile) {
    job.output,job.ok=tool_run(job.runner,job.command,runtime.heap_allocator())
}

// Where the program is copied for the compilations: under the label of the
// folder it comes from, as a generation copies it.
@(private="file")
program_label :: proc(options:Check_Options,path:string) -> (label,folder:string) {
    if options.project!="" {
        folder=path_join(options.project,"shaders",allocator=context.temp_allocator)
        if path_inside(path,folder) {return "project",folder}
    }
    for source in options.sources {
        folder=path_clean(source.folder,context.temp_allocator)
        if path_inside(path,folder) {return strings.concatenate({"plugins/",source.name},context.temp_allocator),folder}
    }
    folder=path_join(options.root,"shaders/materials",allocator=context.temp_allocator)
    if path_inside(path,folder) {return "builtin",folder}
    return "project",path_parent(path)
}

program_check :: proc(options:Check_Options,allocator:=context.allocator) -> (result:Check_Result) {
    path:=path_clean(options.path,context.temp_allocator)
    text:=options.text
    if text=="" {
        data,error:=os.read_entire_file(path,context.temp_allocator)
        if error!=nil {result.error=fmt.aprintf("%s could not be read",path,allocator=allocator);return}
        text=string(lf_bytes(data))
    }
    roots:=[]string{options.project,options.root}
    file:=path
    for root in roots {
        if root=="" {continue}
        if relative,inside:=path_relative(path,root);inside {file=relative;break}
    }
    diagnostics:=make([dynamic]Diagnostic,context.temp_allocator)
    src:=surface_parse(text,context.temp_allocator)
    graph:=surface_graph(&src,context.temp_allocator)
    c:=Checker{domain=src.domain,src=&src,graph=&graph,file=file,out=&diagnostics,allocator=context.temp_allocator}
    name:=rules_declaration(&c)
    rules_code(&c)
    if c.domain==.Surface {
        rules_outputs(&c)
        rules_cost(&c)
    }
    static_count:=len(diagnostics)

    // The compilations, in a folder of their own.
    slangc:=options.tools[.Slangc]
    if slangc=="" {
        found:bool
        if slangc,found=tool_find(options.root,.Slangc,context.temp_allocator);!found {
            result.error=strings.clone("slangc not found: run `mirai setup slang`",allocator)
            return
        }
    }
    runner:Runner
    if accepted,_,problem:=slang_ensure(options.root,slangc,options.tools,&runner,context.temp_allocator);problem!="" {
        result.error=strings.clone(problem,allocator)
        return
    } else {
        slangc=accepted
    }
    temporary,temporary_error:=os.make_directory_temp("","mirai-program-check-*",context.temp_allocator)
    if temporary_error!=nil {result.error=strings.clone("the folder of the check could not be created",allocator);return}
    temporary=path_clean(temporary,context.temp_allocator)
    defer os.remove_all(temporary)
    include:=path_join(temporary,"include",allocator=context.temp_allocator)
    copied:=path_join(include,"programs",allocator=context.temp_allocator)
    label,folder:=program_label(options,path)
    relative,_:=path_relative(path,folder)
    if relative=="" {relative=path_name(path)}
    copy_path:=path_join(copied,label,relative,allocator=context.temp_allocator)
    // The programs as a generation stages them, with this one as the check has it.
    files:Sources
    sources_init(&files,context.temp_allocator)
    staged:=copy_sources(&files,path_join(options.root,"shaders/materials",allocator=context.temp_allocator),path_join(copied,"builtin",allocator=context.temp_allocator))==""
    if options.project!="" {staged&&=copy_sources(&files,path_join(options.project,"shaders",allocator=context.temp_allocator),path_join(copied,"project",allocator=context.temp_allocator))==""}
    for source in options.sources {staged&&=copy_sources(&files,path_clean(source.folder,context.temp_allocator),path_join(copied,"plugins",source.name,allocator=context.temp_allocator))==""}
    for folder in ([]string{"builtin","project"}) {os.make_directory_all(path_join(copied,folder,allocator=context.temp_allocator))}
    os.make_directory_all(path_parent(copy_path))
    if !staged || !write_file(copy_path,transmute([]u8)text) || !write_file(path_join(include,SCHEMA_INCLUDE,allocator=context.temp_allocator),transmute([]u8)material_schema(context.temp_allocator)) {
        result.error=strings.clone("the program could not be staged for the check",allocator)
        return
    }
    copies:=[]Base{{path_parent(path),path_parent(copy_path)}}
    // What the extensions of the project add to the frame, as its generation has it.
    if _,problem:=extensions_generate(&runner,options.root,options.project,temporary,slangc,options.sources,&files,context.temp_allocator);problem!="" {
        result.error=fmt.aprintf("the extensions of the project could not be read: %s",problem,allocator=allocator)
        return
    }
    compiled:=false
    layout,attributes:Layout
    reflected:=false
    // A Vfx program declares its resources and stages; the indices of its resources go before it.
    directives:=program_directives(text)
    stages_declared:[]Vfx_Stage
    prelude:string
    declared:=true
    if c.domain==.Vfx {
        resources,problem:=program_resources(name,directives.resources[:],context.temp_allocator)
        if problem=="" {stages_declared,problem=program_stages(name,directives.stages[:],resources,context.temp_allocator)}
        if problem!="" {
            declared=false
            report(&c,.Error,"mirai.directives",i32(max(directives.line,1)),1,problem,"declare `//! resource name surface|channel|bones|grid|emitter|data` and `//! stage name over particles|<grid> [iterations N] [neighbors radius] [writes grid,grid]` as mirai_vfx.slang says")
        }
        prelude=vfx_prelude(name,resources)
    }
    plugins:=make([dynamic]string,context.temp_allocator)
    for source in options.sources {append(&plugins,path_clean(source.folder,context.temp_allocator))}
    with_attributes:=c.domain==.Vfx && "Attributes" in src.structs
    if name!="" && src.has_parameters && declared {
        said:[]Diagnostic
        problem:string
        layouts:[2]Layout
        layouts,problem,_=layout_reflect(&runner,slangc,options.root,copied,folder,copy_path,name,temporary,context.temp_allocator,attributes=with_attributes,vfx=c.domain==.Vfx,prelude=prelude,said=&said,plugins=plugins[:])
        layout,attributes=layouts[0],layouts[1]
        reflected=problem==""
        if !reflected {
            diagnostics_place(said,copies,roots,context.temp_allocator)
            for &d in said {
                d.stage="all"
                if !rule_explains(diagnostics[:static_count],d) {append(&diagnostics,d)}
            }
        }
    }
    supported:=rules_parameters(&c,layout,reflected)
    result.parameters_size=layout.size
    if reflected && supported && (c.domain!=.Vfx || with_attributes) {
        // The includes of a generation that holds only this program.
        dispatchers:=dispatchers_make()
        own,failure:string
        program_include:=strings.concatenate({label,"/",relative},context.temp_allocator)
        if c.domain==.Vfx {
            own,failure=vfx_program_include(name,prelude,program_include,layout,attributes,stages_declared,directives)
        } else {
            dispatchers_add(&dispatchers,c.domain,1,name,program_include,layout)
        }
        own_folder:=path_join(include,VFX_FOLDER,name,allocator=context.temp_allocator)
        if failure!="" {
            line:=src.declared_line
            if fields:=src.structs["Attributes"];len(fields)>0 {line=fields[0].line}
            report(&c,.Error,"mirai.attributes",line,1,failure,fmt.aprintf("keep struct Attributes within %d bytes of float, int, uint and bool scalars and vectors: what the program needs again in the next step",ATTRIBUTE_BYTES,allocator=c.allocator))
        } else {
            failed:=dispatchers_write(&dispatchers,include)
            if failed=="" && c.domain==.Vfx {
                os.make_directory_all(own_folder)
                if !write_file(path_join(own_folder,VFX_INCLUDE,allocator=context.temp_allocator),transmute([]u8)own) {failed=VFX_INCLUDE}
            }
            if failed!="" {
                result.error=fmt.aprintf("could not write %s for the check",failed,allocator=allocator)
                return
            }
            // own: the include of the Vfx program, before those of the generation.
            command :: proc(slangc,source,stage,output:string,own,include,root,project,folder:string,sources:[]Source) -> []string {
                out:=make([dynamic]string,context.temp_allocator)
                append(&out,slangc,source,"-entry","main","-matrix-layout-column-major","-O0","-line-directive-mode","none","-warnings-disable","40100,41035",SLANG_DIAGNOSTICS_FLAG,"-stage",stage)
                if own!="" {append(&out,"-I",own)}
                append(&out,"-I",include)
                for engine in ENGINE_INCLUDES {append(&out,"-I",path_join(root,engine,allocator=context.temp_allocator))}
                if project!="" {append(&out,"-I",path_join(project,"shaders",allocator=context.temp_allocator))}
                for source in sources {append(&out,"-I",path_clean(source.folder,context.temp_allocator))}
                append(&out,"-I",folder)
                append(&out,..SPIRV_FLAGS)
                append(&out,"-o",strings.concatenate({output,".spv"},context.temp_allocator))
                return out[:]
            }
            jobs:=make([dynamic]Check_Compile,context.temp_allocator)
            if c.domain==.Surface {
                raster_path:=path_join(temporary,"check_raster.frag.slang",allocator=context.temp_allocator)
                ray_path:=path_join(temporary,"check_ray.comp.slang",allocator=context.temp_allocator)
                if !write_file(raster_path,transmute([]u8)string(CHECK_RASTER)) || !write_file(ray_path,transmute([]u8)string(CHECK_RAY)) {
                    result.error=strings.clone("the stages of the check could not be written",allocator)
                    return
                }
                append(&jobs,Check_Compile{runner=&runner,stage="raster",command=command(slangc,raster_path,"fragment",raster_path,"",include,options.root,options.project,folder,options.sources)})
                append(&jobs,Check_Compile{runner=&runner,stage="ray",command=command(slangc,ray_path,"compute",ray_path,"",include,options.root,options.project,folder,options.sources)})
            }
            stages,kinds:=CHECK_STAGES,SLANG_STAGES
            sources:=make([dynamic]string,context.temp_allocator)
            for stage in stages[c.domain] {append(&sources,path_join(options.root,"shaders",stage,allocator=context.temp_allocator))}
            // A Vfx program runs in the stages of the plugins marked `//! per vfx program`.
            if c.domain==.Vfx {
                for plugin in plugins {
                    for path in sources_in(&files,plugin,".slang",context.temp_allocator) {
                        if _,_,is_stage:=stage_of(path_name(path));is_stage && strings.contains(string(sources_file(&files,path).data),"//! per vfx program") {append(&sources,path)}
                    }
                }
                if len(sources)==0 {report(&c,.Warning,"mirai.stages",i32(max(directives.line,1)),1,"no active plugin runs Vfx programs: the program was reflected, not compiled in stages","activate the vfx plugin in the project")}
            }
            for source in sources {
                stage:=path_name(source)
                _,kind,_:=stage_of(stage)
                output:=path_join(temporary,stage,allocator=context.temp_allocator)
                append(&jobs,Check_Compile{runner=&runner,stage=strings.trim_suffix(stage,".slang"),command=command(slangc,source,kinds[kind],output,own_folder if c.domain==.Vfx else "",include,options.root,options.project,folder,options.sources)})
            }
            threads:=make([]^thread.Thread,len(jobs),context.temp_allocator)
            for &job,i in jobs {threads[i]=thread.create_and_start_with_poly_data(&job,check_compile_run)}
            for t,i in threads {
                if t==nil {check_compile_run(&jobs[i]);continue}
                thread.join(t);thread.destroy(t)
            }
            defer for job in jobs {delete(job.output,runtime.heap_allocator())}
            compiled=len(jobs)>0
            for job in jobs {compiled&&=job.ok}
            entry:=entry_line(&c)
            found:=make([dynamic]Diagnostic,context.temp_allocator)
            for job in jobs {
                said:=slang_diagnostics(job.output,context.temp_allocator)
                diagnostics_place(said,copies,roots,context.temp_allocator)
                each: for &d in said {
                    // What the stages say of their own code is not of the program; of
                    // the code of the check (its stages and dispatchers), of its entry.
                    if d.file!=file && d.severity!=.Error {continue}
                    if strings.has_prefix(d.file,temporary) {d.file,d.line,d.column=file,entry,1}
                    d.stage=job.stage
                    for &known in found {
                        if known.code==d.code && known.file==d.file && known.line==d.line && known.column==d.column && known.message==d.message {
                            known.stage=strings.concatenate({known.stage,",",job.stage},context.temp_allocator)
                            continue each
                        }
                    }
                    append(&found,d)
                }
            }
            for &d in found {
                if len(jobs)>1 && strings.count(d.stage,",")==len(jobs)-1 {d.stage="all"}
                if !rule_explains(diagnostics[:static_count],d) {append(&diagnostics,d)}
            }
        }
    }
    for &d in diagnostics[static_count:] {
        if d.fix=="" {d.fix=compile_fix(c.domain,d.message,c.allocator)}
    }
    for &d in diagnostics {
        if d.file==file && d.line>0 {
            if node:=surface_node_at(&graph,i32(d.line));node>=0 {d.node=graph.nodes[node].id}
        }
    }
    slice.stable_sort_by(diagnostics[:],proc(a,b:Diagnostic) -> bool {
        if a.severity!=b.severity {return a.severity<b.severity}
        if a.file!=b.file {return a.file<b.file}
        return a.line<b.line
    })
    for d in diagnostics {
        #partial switch d.severity {
        case .Error: result.errors+=1
        case .Warning: result.warnings+=1
        }
    }
    result.compiled=compiled
    result.domain=c.domain
    result.name=strings.clone(name,allocator)
    result.file=strings.clone(file,allocator)
    result.diagnostics=diagnostics_clone(diagnostics[:],allocator)
    return
}

// A line a rule already explains keeps the rule, not what the compiler says
// of it; what Slang says inside its own library (hlsl.meta.slang) follows
// from the program, and with an error of a rule the rule explains it.
@(private="file")
rule_explains :: proc(rules:[]Diagnostic,d:Diagnostic) -> bool {
    library:=strings.has_suffix(d.file,".meta.slang")
    for rule in rules {if rule.severity==.Error && (library || rule.file==d.file && rule.line==d.line) {return true}}
    return false
}

// What to do about what Slang said, when the message names it.
@(private="file")
compile_fix :: proc(domain:Program_Domain,message:string,allocator:runtime.Allocator) -> string {
    if at:=strings.index(message,"undefined identifier '");at>=0 {
        domains,api:=PROGRAM_DOMAINS,MIRAI_API
        name:=message[at+len("undefined identifier '"):]
        if end:=strings.index_byte(name,'\'');end>=0 {name=name[:end]}
        for pair in FOREIGN {if pair[0]==name {return fmt.aprintf("use %s",pair[1],allocator=allocator)}}
        return fmt.aprintf("%s is not declared: a %s program calls %s",name,domains[domain],api[domain],allocator=allocator)
    }
    return ""
}
