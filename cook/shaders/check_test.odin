package shaders

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file")
OCEAN_LIKE :: `//! mirai surface Waves
//! parameter color {"default":[0.01,0.07,0.1],"min":0,"max":1,"color":true}
//! parameter frequency {"default":1.4,"min":0.001,"max":100}
namespace Waves {
struct Parameters {float3 color;float frequency;};
float2 ripples(float2 x, float t, out float height) {
    float2 slope=float2(0);height=0;
    for (int i=0;i<4;i++) {slope+=float2(cos(x.x*t),sin(x.y));height+=sin(x.x);}
    return slope;
}
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float height;
    float2 slope=ripples(ctx.world_position.xz*p.frequency,ctx.time,height);
    s.normal=normalize(ctx.normal+float3(-slope.x,0,-slope.y));
    s.base_color=p.color;
    if (height>0.5) {s.base_color=float3(0.86,0.92,0.93);}
    s.roughness=0.06;
    switch (int(height)) {case 0: s.metallic=1; break; default: break;}
    return s;
}
}
`

@(private="file")
graph_node :: proc(graph:^Surface_Graph,id:string) -> (Graph_Node,int) {
    for node,i in graph.nodes {if node.id==id {return node,i}}
    return {},-1
}

@(private="file")
graph_edge :: proc(graph:^Surface_Graph,from,to:int) -> bool {
    for e in graph.edges {if e.from==from && e.to==to {return true}}
    return false
}

@(test)
the_graph_of_a_program_names_its_inputs_values_and_outputs_by_stable_ids :: proc(t:^testing.T) {
    src:=surface_parse(OCEAN_LIKE,context.temp_allocator)
    graph:=surface_graph(&src,context.temp_allocator)
    testing.expect_value(t,src.name,"Waves")
    testing.expect_value(t,len(src.parameters),2)
    testing.expect_value(t,len(src.functions),2)
    for id in ([]string{"Waves/evaluate/ctx.world_position","Waves/evaluate/p.frequency","Waves/evaluate/ripples","Waves/evaluate/slope",
        "Waves/evaluate/out.normal","Waves/evaluate/out.base_color","Waves/evaluate/out.base_color#2","Waves/evaluate/if",
        "Waves/evaluate/out.roughness","Waves/evaluate/code","Waves/ripples/for","Waves/ripples/return"}) {
        _,found:=graph_node(&graph,id)
        testing.expectf(t,found>=0,"%s is a node",id)
    }
    // Values flow from what they are made of: the call writes its out argument.
    _,call:=graph_node(&graph,"Waves/evaluate/ripples")
    _,slope:=graph_node(&graph,"Waves/evaluate/slope")
    _,normal:=graph_node(&graph,"Waves/evaluate/out.normal")
    _,frequency:=graph_node(&graph,"Waves/evaluate/p.frequency")
    _,branch:=graph_node(&graph,"Waves/evaluate/if")
    second,second_index:=graph_node(&graph,"Waves/evaluate/out.base_color#2")
    testing.expect(t,graph_edge(&graph,frequency,call))
    testing.expect(t,graph_edge(&graph,call,slope))
    testing.expect(t,graph_edge(&graph,slope,normal))
    testing.expect(t,graph_edge(&graph,branch,second_index))
    // The out argument is a write of its own, and who reads it reads that.
    _,height:=graph_node(&graph,"Waves/evaluate/height#2")
    testing.expect(t,height>=0 && graph_edge(&graph,call,height) && graph_edge(&graph,height,branch) && !graph_edge(&graph,call,branch))
    testing.expect_value(t,second.first_line,i32(17))
    testing.expect(t,graph.nodes[normal].facts.normalized)
    parameter,_:=graph_node(&graph,"Waves/evaluate/p.frequency")
    testing.expect_value(t,parameter.first_line,i32(5))
    // What the reader does not understand stays as code over its lines.
    code,_:=graph_node(&graph,"Waves/evaluate/code")
    testing.expect(t,strings.has_prefix(code.text,"switch"))
    testing.expect_value(t,surface_node_at(&graph,15),normal)

    // Types: those declared, those of the parameters and of the contract, and
    // what a constant shows. A struct with a method keeps its fields.
    contract:=surface_parse(`struct Mirai_Surface_Context {float3 world_position; float3 normal; float time; float2 uv(int i) {return float2(0);}};
struct Mirai_Surface {float3 base_color; float3 normal; float metallic; float roughness;};`,context.temp_allocator)
    testing.expect_value(t,len(contract.structs["Mirai_Surface_Context"]),3)
    typed:=surface_graph(&src,context.temp_allocator,&contract)
    for pair in ([][2]string{
        {"Waves/evaluate/p.frequency","float"},{"Waves/evaluate/ctx.world_position","float3"},{"Waves/evaluate/slope","float2"},
        {"Waves/evaluate/ripples","float2"},{"Waves/evaluate/out.normal","float3"},{"Waves/evaluate/out.roughness","float"},
        {"Waves/evaluate/out","Mirai_Surface"},{"Waves/evaluate/height","float"},{"Waves/evaluate/height#2","float"},{"Waves/ripples/x","float2"},
    }) {
        node,found:=graph_node(&typed,pair[0])
        testing.expectf(t,found>=0 && node.type==pair[1],"%s is %s, not %q",pair[0],pair[1],node.type)
    }
    constant,_:=graph_node(&typed,"Waves/evaluate/const:0.06")
    testing.expect_value(t,constant.type,"float")

    // Another line before them moves their lines, not their ids.
    moved:=strings.concatenate({"// a comment\n",OCEAN_LIKE},context.temp_allocator)
    moved_src:=surface_parse(moved,context.temp_allocator)
    moved_graph:=surface_graph(&moved_src,context.temp_allocator)
    again,found:=graph_node(&moved_graph,"Waves/evaluate/out.base_color#2")
    testing.expect(t,found>=0)
    testing.expect_value(t,again.first_line,i32(18))
}

@(private="file")
Check_Fixture :: struct {project,root:string}

@(private="file")
check_fixture :: proc(t:^testing.T,f:^Check_Fixture) -> bool {
    f.root=path_clean(ENGINE_ROOT,context.temp_allocator)
    if _,found:=tool_find(f.root,.Slangc,context.temp_allocator);!found {log.warn("slangc is not installed: run `mirai setup slang`");return false}
    f.project=base.test_folder(t,"shaders")
    if f.project=="" {return false}
    os.make_directory_all(path_join(f.project,"shaders",allocator=context.temp_allocator))
    return true
}

@(private="file")
check_text :: proc(t:^testing.T,f:^Check_Fixture,name,text:string,sources:[]Source=nil) -> Check_Result {
    fixture_write(t,f.project,strings.concatenate({"shaders/",name,".slang"},context.temp_allocator),text)
    path:=path_join(f.project,"shaders",strings.concatenate({name,".slang"},context.temp_allocator),allocator=context.temp_allocator)
    result:=program_check({root=f.root,project=f.project,sources=sources,path=path},context.temp_allocator)
    testing.expect_value(t,result.error,"")
    return result
}

@(private="file")
diagnostic_find :: proc(result:Check_Result,code:string) -> (Diagnostic,bool) {
    for d in result.diagnostics {if d.code==code {return d,true}}
    return {},false
}

@(private="file")
expect_rule :: proc(t:^testing.T,result:Check_Result,code:string,line:int,severity:=Severity.Warning,loc:=#caller_location) -> Diagnostic {
    d,found:=diagnostic_find(result,code)
    testing.expectf(t,found,"%s is reported",code,loc=loc)
    if !found {return d}
    testing.expect_value(t,d.line,line,loc=loc)
    testing.expect_value(t,d.severity,severity,loc=loc)
    testing.expectf(t,d.fix!="","%s says how to fix it",code,loc=loc)
    testing.expect_value(t,d.file,"shaders/rules.slang",loc=loc)
    return d
}

@(private="file")
RULES :: `//! mirai surface Rules
//! parameter color {"default":[1,1,1],"min":0,"max":1,"color":true}
//! parameter color {"default":[1,1,1],"min":0,"max":1,"color":true}
//! parameter ghost {"default":1}
//! parameter map {"kind":"texture","srgb":true}
//! parameter broken {not json}
namespace Rules {
struct Parameters {float3 color;uint map;float spare;float broken;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float w=fwidth(ctx.uv0.x);
    float3 tint=pow(p.color,2.2);
    s.base_color=p.color*2.0;
    s.emission=p.color;
    s.roughness=0;
    s.normal=mirai_sample_texture(ctx,p.map,ctx.uv0,0).xyz*2-1;
    s.coat_normal=ctx.normal+float3(0,w,0);
    for (int i=0;i<16;i++) {tint+=float3(0.01*float(i));}
    s.specular_color=tint*float(p.broken);
    return s;
}
}
`

@(test)
the_check_names_the_mistakes_of_a_program_with_their_fix :: proc(t:^testing.T) {
    f:Check_Fixture
    if !check_fixture(t,&f) {return}
    result:=check_text(t,&f,"rules",RULES)
    expect_rule(t,result,"mirai.parameter_duplicate",3,.Error)
    expect_rule(t,result,"mirai.parameter_orphan",4,.Error)
    expect_rule(t,result,"mirai.parameter_metadata",6,.Error)
    expect_rule(t,result,"mirai.parameter_missing",8)
    expect_rule(t,result,"mirai.parameter_unused",8)
    expect_rule(t,result,"mirai.ray_derivatives",11,.Error)
    expect_rule(t,result,"mirai.srgb_conversion",12)
    base:=expect_rule(t,result,"mirai.base_color_range",13)
    testing.expect_value(t,base.node,"Rules/evaluate/out.base_color")
    expect_rule(t,result,"mirai.emission_units",14)
    expect_rule(t,result,"mirai.roughness_minimum",15)
    expect_rule(t,result,"mirai.normal_tangent_space",16)
    expect_rule(t,result,"mirai.normal_unnormalized",17)
    expect_rule(t,result,"mirai.ray_cost",18,.Info)
    testing.expect(t,result.errors>0)
}

@(test)
the_check_names_foreign_functions_texture_objects_packing_and_declarations :: proc(t:^testing.T) {
    f:Check_Fixture
    if !check_fixture(t,&f) {return}
    languages:=check_text(t,&f,"rules",`//! mirai surface Rules
//! parameter a {"default":0.5,"min":0,"max":1}
namespace Rules {
struct Parameters {float a;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    s.metallic=mix(0.0,1.0,p.a);
    s.base_color=material_textures[0].SampleLevel(material_sampler,ctx.uv0,0).rgb;
    return s;
}
}
`)
    unknown:=expect_rule(t,languages,"mirai.unknown_api",7,.Error)
    testing.expect(t,strings.contains(unknown.fix,"lerp"))
    expect_rule(t,languages,"mirai.texture_object",8,.Error)

    packed:=check_text(t,&f,"rules",`//! mirai surface Rules
namespace Rules {
struct Parameters {float4 a0;float4 a1;float4 a2;float4 a3;float4 a4;float4 a5;float4 a6;float4 a7;float4 a8;float4 a9;float4 a10;float4 a11;float4 a12;float4 a13;float4 a14;float4 a15;float4 a16;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {Mirai_Surface s=mirai_surface_default(ctx);s.alpha=p.a0.x;return s;}
}
`)
    expect_rule(t,packed,"mirai.parameter_packing",3,.Error)

    reordered:=check_text(t,&f,"rules",`//! mirai surface Rules
namespace Rules {
struct Parameters {float3 a0;float3 a1;float3 a2;float3 a3;float3 a4;float3 a5;float3 a6;float3 a7;float3 a8;float3 a9;float3 a10;float3 a11;float3 a12;float3 a13;float3 a14;float3 a15;float b0;float b1;float b2;float b3;float b4;float b5;float b6;float b7;float b8;float b9;float b10;float b11;float b12;float b13;float b14;float b15;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {Mirai_Surface s=mirai_surface_default(ctx);return s;}
}
`)
    packing,found:=diagnostic_find(reordered,"mirai.parameter_packing")
    if found {testing.expect(t,strings.contains(packing.fix,"float3 a0;float b0;"),packing.fix)}

    missing:=check_text(t,&f,"rules","//! mirai surface Rules\nnamespace Rules {\nstruct Parameters {float a;};\n}\n")
    expect_rule(t,missing,"mirai.declaration",1,.Error)

    // `//! vertex` asks for the function vertex.
    unmoved:=check_text(t,&f,"rules","//! mirai surface Rules\n//! vertex\nnamespace Rules {\nstruct Parameters {float a;};\nMirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {return mirai_surface_default(ctx);}\n}\n")
    declared:=expect_rule(t,unmoved,"mirai.declaration",1,.Error)
    testing.expect(t,strings.contains(declared.message,"vertex") && strings.contains(declared.fix,"Mirai_Vertex vertex("),declared.fix)
}

@(test)
the_check_compiles_a_program_in_raster_and_ray_stages_without_publishing :: proc(t:^testing.T) {
    f:Check_Fixture
    if !check_fixture(t,&f) {return}
    clean:=check_text(t,&f,"pulse",`//! mirai surface Pulse
//! parameter color {"default":[0.9,0.35,0.1],"min":0,"max":1,"color":true}
//! parameter glow {"default":2,"min":0,"max":50}
namespace Pulse {
struct Parameters {float3 color;float glow;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    s.base_color=p.color;
    s.roughness=0.5;
    s.emission=p.color*p.glow*(0.5+0.5*sin(ctx.time*6.2831853));
    return s;
}
}
`)
    testing.expect(t,clean.compiled)
    testing.expect_value(t,clean.errors,0)
    testing.expect_value(t,clean.warnings,0)
    testing.expect_value(t,clean.parameters_size,16)
    testing.expect(t,!os.exists(path_join(f.project,PROJECT_OUTPUT,allocator=context.temp_allocator)),"a check publishes nothing")

    // An error of the compiler is at its line of the program, with the node of that line.
    broken_text:=`//! mirai surface Pulse
//! parameter color {"default":[0.9,0.35,0.1],"min":0,"max":1,"color":true}
namespace Pulse {
struct Parameters {float3 color;};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float3 glow=p.color*brightness;
    s.emission=glow*1000.0;
    return s;
}
}
`
    broken:=check_text(t,&f,"pulse",broken_text)
    testing.expect(t,!broken.compiled)
    d,found:=diagnostic_find(broken,"E30015")
    testing.expect(t,found,diagnostics_text(broken.diagnostics,context.temp_allocator))
    testing.expect_value(t,d.file,"shaders/pulse.slang")
    testing.expect_value(t,d.line,7)
    testing.expect_value(t,d.node,"Pulse/evaluate/glow")
    testing.expect(t,strings.contains(d.fix,"mirai_sample_texture"),d.fix)

    // A text checked in place of the file does not need the file to hold it.
    fixed,_:=strings.replace(broken_text,"*brightness","*2.0",1,context.temp_allocator)
    path:=path_join(f.project,"shaders/pulse.slang",allocator=context.temp_allocator)
    again:=program_check({root=f.root,project=f.project,path=path,text=fixed},context.temp_allocator)
    testing.expect(t,again.compiled,diagnostics_text(again.diagnostics,context.temp_allocator))
    testing.expect_value(t,again.errors,0)
}

@(test)
the_template_of_each_domain_compiles_in_the_stages_that_run_it :: proc(t:^testing.T) {
    f:Check_Fixture
    if !check_fixture(t,&f) {return}
    // Vfx programs run in the stages of the vfx plugin.
    plugins:=[]Source{{"vfx",path_join(f.root,"plugins/vfx/shaders",allocator=context.temp_allocator)}}
    for domain in Program_Domain {
        name:=fmt.tprintf("New_%v",domain)
        result:=check_text(t,&f,strings.to_lower(name,context.temp_allocator),program_template(domain,name,context.temp_allocator),plugins)
        testing.expectf(t,result.compiled && result.errors==0 && result.warnings==0,"%v: %s",domain,diagnostics_text(result.diagnostics,context.temp_allocator))
        testing.expect_value(t,result.domain,domain)
        testing.expect_value(t,result.name,name)
    }
}

@(test)
the_check_reads_programs_of_other_domains_by_their_contract :: proc(t:^testing.T) {
    f:Check_Fixture
    if !check_fixture(t,&f) {return}
    // A PostProcess program runs in a fragment stage: derivatives are its own.
    post:=check_text(t,&f,"rules",`//! mirai postprocess Rules
//! parameter strength {"default":1,"min":0,"max":1}
namespace Rules {
struct Parameters {float strength;};
float4 evaluate(Mirai_PostProcess_Context ctx, Parameters p) {
    float edge=fwidth(ctx.depth);
    return ctx.color*p.strength*glow+edge;
}
}
`)
    _,derivatives:=diagnostic_find(post,"mirai.ray_derivatives")
    testing.expect(t,!derivatives)
    d,found:=diagnostic_find(post,"E30015")
    testing.expect(t,found && d.line==7 && strings.contains(d.fix,"mirai_scene_color"),diagnostics_text(post.diagnostics,context.temp_allocator))
    testing.expect(t,!post.compiled)

    signature:=check_text(t,&f,"rules",`//! mirai postprocess Rules
namespace Rules {
struct Parameters {float strength;};
float3 evaluate(Mirai_PostProcess_Context ctx, Parameters p) {return ctx.color.rgb*p.strength;}
}
`)
    declared:=expect_rule(t,signature,"mirai.declaration",4,.Error)
    testing.expect(t,strings.has_prefix(declared.fix,"float4 evaluate(Mirai_PostProcess_Context ctx, Parameters p)"),declared.fix)

    // A Vfx program keeps its Attributes, and its stages have no derivatives.
    vfx:=check_text(t,&f,"rules",`//! mirai vfx Rules
namespace Rules {
struct Parameters {float speed;};
void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle) {}
void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {particle.size=ddx(p.speed);}
}
`)
    expect_rule(t,vfx,"mirai.derivatives",5,.Error)
    missing:=0
    for d in vfx.diagnostics {if d.code=="mirai.declaration" {missing+=1}}
    testing.expectf(t,missing==3,"no Attributes, initialize without it and no render: %s",diagnostics_text(vfx.diagnostics,context.temp_allocator))

    // A ui program receives four floats.
    ui:=check_text(t,&f,"rules",`//! mirai ui Rules
namespace Rules {
struct Parameters {float4 tint;float extra;};
float4 evaluate(Mirai_Ui_Context ctx, Parameters p) {return ctx.color*p.tint*p.extra;}
}
`)
    expect_rule(t,ui,"mirai.parameter_packing",3,.Error)
}

@(test)
slang_diagnostics_are_read_from_its_machine_readable_lines :: proc(t:^testing.T) {
    output:="E30015\terror\tC:/p/shaders/x.slang\t4\t23\t4\t38\tundefined identifier\n"+
        "E30015\tspan\tC:/p/shaders/x.slang\t4\t23\t4\t38\tundefined identifier 'thing'.\n"+
        "E41012\twarning\tC:/p/shaders/x.slang\t7\t6\t7\t10\tprofile implicitly upgraded\n"+
        "E41012\tspan\tC:/p/shaders/x.slang\t7\t6\t7\t10\tentry point uses more\n"+
        "something else\n"
    list:=slang_diagnostics(output,context.temp_allocator)
    testing.expect_value(t,len(list),3)
    testing.expect_value(t,list[0].message,"undefined identifier 'thing'.")
    testing.expect_value(t,list[0].line,4)
    testing.expect_value(t,list[0].column,23)
    testing.expect_value(t,list[1].severity,Severity.Warning)
    testing.expect_value(t,list[1].message,"profile implicitly upgraded: entry point uses more")
    diagnostics_place(list,{{"C:/project/shaders","C:/p/shaders"}},{"C:/project"},context.temp_allocator)
    testing.expect_value(t,list[0].file,"shaders/x.slang")
    testing.expect_value(t,diagnostic_text(list[0],context.temp_allocator),"shaders/x.slang(4:23): error E30015: undefined identifier 'thing'.")
}
