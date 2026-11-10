package shaders


import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

@(private="file")
FILL :: `#include "native.slang"
//! variant double MIRAI_DOUBLE=1
//! constant half MIRAI_HALF
struct Fill_Params { uint count; float scale; float offset; uint pad; };
[[vk::binding(0, 0)]] ConstantBuffer<Fill_Params> params : register(b0, space0);
[[vk::binding(1, 0)]] StructuredBuffer<float> input_data : register(t1, space0);
[[vk::binding(2, 0)]] RWStructuredBuffer<float> output_data : register(u2, space0);
[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.x;
    if (i >= params.count) return;
#ifdef MIRAI_DOUBLE
    output_data[i] = 2.0 * input_data[i] * params.scale + params.offset;
#else
    output_data[i] = input_data[i] * params.scale + params.offset;
#endif
    if (MIRAI_HALF) output_data[i] *= 0.5;
}
`

@(private="file")
COLOR :: `#include "native.slang"
#include "tint.slang"
struct Stage_Input { [[vk::location(0)]] float4 in_color : TEXCOORD0; };
struct Stage_Output { [[vk::location(0)]] float4 out_color : SV_Target0; };
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
    output.out_color = input.in_color * TINT;
    return output;
}
`

@(private="file")
POINT :: `#include "native.slang"
struct Corner { float4 position; float4 color; };
[[vk::binding(0, 0)]] StructuredBuffer<Corner> corners : register(t0, space0);
struct Stage_Output { float4 position : SV_Position; [[vk::location(0)]] float4 out_color : TEXCOORD0; };
[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID) {
    Stage_Output output;
    output.out_color = corners[vertex_id].color;
    output.position = corners[vertex_id].position;
    return output;
}
`

// The Surface programs the mini engine is built with, in its shaders/materials:
// the engine has none of its own. Two move no vertices and one does.
@(private="file")
MINI_SURFACES :: [3][2]string{
    {"grid.slang","//! mirai surface Grid\n//! parameter amount {\"default\":0.5,\"min\":0,\"max\":1}\nnamespace Grid {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {Mirai_Surface s=mirai_surface_default(ctx);s.roughness=p.amount;return s;}}\n"},
    {"ocean.slang","//! mirai surface Ocean\n//! parameter amount {\"default\":0.5,\"min\":0,\"max\":1}\nnamespace Ocean {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {Mirai_Surface s=mirai_surface_default(ctx);s.metallic=p.amount;return s;}}\n"},
    {"pieces.slang","//! mirai surface Pieces\n//! vertex reach 0.5\n//! parameter amount {\"default\":0.5,\"min\":0,\"max\":1}\nnamespace Pieces {struct Parameters {float amount;}; Mirai_Vertex vertex(Mirai_Vertex_Context ctx,Parameters p) {Mirai_Vertex v=mirai_vertex_default(ctx);v.position.y+=clamp(p.amount,0.0,0.5);return v;} Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n"},
}

// The programs of the mini engine: those of the engine and its own Surface ones.
@(private="file")
mini_programs :: proc() -> int {return builtin_programs()+len(MINI_SURFACES)}

// The marks a constant of id 0 leaves in the code of a stage: a
// specialization constant in SPIR-V, a function constant in Metal.
@(private="file")
code_has_constant :: proc(code:string) -> bool {
    when ODIN_OS==.Darwin {
        return strings.contains(code,"[[function_constant(0)]]")
    } else {
        OP_DECORATE,SPEC_ID :: 71,1
        bytes:=transmute([]u8)code
        word :: proc(bytes:[]u8,at:int) -> u32 {return u32(bytes[4*at]) | u32(bytes[4*at+1])<<8 | u32(bytes[4*at+2])<<16 | u32(bytes[4*at+3])<<24}
        for at:=5;at<len(bytes)/4; {
            count:=int(word(bytes,at)>>16)
            if count==0 || at+count>len(bytes)/4 {return false}
            if word(bytes,at)&0xffff==OP_DECORATE && count==4 && word(bytes,at+2)==SPEC_ID && word(bytes,at+3)==0 {return true}
            at+=count
        }
        return false
    }
}

// A small engine of its own: three stages (one with a variant and a constant), a test stage
// and the shared includes and built-in programs of the real engine.
@(private="file")
Mini :: struct {root,output:string,options:Options}

@(private="file")
mini_make :: proc(t:^testing.T,mini:^Mini) -> bool {
    engine:=path_clean(ENGINE_ROOT,context.temp_allocator)
    options:Options
    for &path,tool in options.tools {
        found:bool
        path,found=tool_find(engine,tool,context.temp_allocator)
        if !found {log.warnf("%v is not installed: the generation is not tested",tool);return false}
    }
    mini.root=base.test_folder(t,"shaders")
    if mini.root=="" {return false}
    for folder in ([]string{"shaders/include","shaders/materials"}) {
        for path in listing_read(path_join(engine,folder,allocator=context.temp_allocator),true,context.temp_allocator).files {
            data,_:=os.read_entire_file(path,context.temp_allocator)
            relative,_:=path_relative(path,engine)
            fixture_write(t,mini.root,relative,string(data))
        }
    }
    for surface in MINI_SURFACES {fixture_write(t,mini.root,strings.concatenate({"shaders/materials/",surface[0]},context.temp_allocator),surface[1])}
    fixture_write(t,mini.root,"shaders/fill.comp.slang",FILL)
    fixture_write(t,mini.root,"shaders/color.frag.slang",COLOR)
    fixture_write(t,mini.root,"shaders/point.vert.slang",POINT)
    fixture_write(t,mini.root,"shaders/include/tint.slang","#define TINT float4(1,1,1,1)\n")
    fixture_write(t,mini.root,"shaders/notes.slang","// not a stage: no .vert, .frag or .comp before .slang\n")
    fixture_write(t,mini.root,"shaders/tests/probe.comp.slang",FILL)
    os.make_directory_all(path_join(mini.root,"render",allocator=context.temp_allocator))
    os.make_directory_all(path_join(mini.root,"rhi",allocator=context.temp_allocator))
    mini.output=path_join(mini.root,"shaders/build",allocator=context.temp_allocator)
    options.root,options.odin,options.workers=mini.root,true,2
    mini.options=options
    return true
}

@(private="file")
mini_read :: proc(mini:^Mini,relative:string) -> string {
    data,_:=os.read_entire_file(path_join(mini.root,relative,allocator=context.temp_allocator),context.temp_allocator)
    return string(data)
}

@(private="file")
mini_generate :: proc(t:^testing.T,mini:^Mini,options:Options) -> Result {
    result:=generate(options,context.temp_allocator)
    return result
}

// The extension of the code of this system's backend, and of the other.
@(private="file")
HOST_CODE :: ".metal" when ODIN_OS==.Darwin else ".spv"
@(private="file")
OTHER_CODE :: ".spv" when ODIN_OS==.Darwin else ".metal"

@(private="file")
files_in :: proc(folder:string) -> []os.File_Info {
    files,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    return files
}

@(test)
generation_compiles_publishes_and_reuses_what_did_not_change :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    first:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,first.error,"")
    if first.error!="" {return}
    testing.expect_value(t,first.shaders,4)
    testing.expect_value(t,first.tests,2)
    testing.expect_value(t,first.programs,mini_programs())
    testing.expect_value(t,first.compiled,6)
    testing.expect_value(t,first.reused,0)
    testing.expect_value(t,len(first.engine),64)
    for name in ([]string{"color.frag","fill.comp","fill_double.comp","point.vert","tests/probe.comp","tests/probe_double.comp"}) {
        testing.expectf(t,os.is_file(path_join(mini.output,strings.concatenate({name,HOST_CODE},context.temp_allocator),allocator=context.temp_allocator)),"%s%s is published",name,HOST_CODE)
        testing.expectf(t,!os.exists(path_join(mini.output,strings.concatenate({name,OTHER_CODE},context.temp_allocator),allocator=context.temp_allocator)),"%s%s is not made: the engine compiles for this system",name,OTHER_CODE)
    }
    testing.expect(t,os.is_file(path_join(mini.output,"catalog.json",allocator=context.temp_allocator)) && os.is_file(path_join(mini.output,"include",SURFACE_INCLUDE,allocator=context.temp_allocator)) && os.is_file(path_join(mini.output,"include",POSTPROCESS_INCLUDE,allocator=context.temp_allocator)))
    manifest:=mini_read(&mini,"shaders/build/manifest.json")
    testing.expect(t,strings.contains(manifest,first.engine),"the manifest names the engine sources")
    testing.expect(t,strings.contains(manifest,"\"id\": \"Fill_Double_Comp\"") && strings.contains(manifest,"\"tests\": [\n    {\n      \"id\": \"Probe_Comp\""))
    testing.expect(t,strings.contains(manifest,"\"bindings\": [\n        {\n          \"slot\": 0,\n          \"kind\": \"Uniform_Buffer\"\n        },\n        {\n          \"slot\": 1,\n          \"kind\": \"Storage_Buffer\"\n        },\n        {\n          \"slot\": 2,\n          \"kind\": \"Storage_Buffer_RW\"\n        }\n      ],\n      \"group\": [\n        64,\n        1,\n        1\n      ],"),"bindings and threadgroup are the reflected ones")
    table:=mini_read(&mini,"render/shaders_gen.odin")
    testing.expect(t,strings.contains(table,"\npackage mirai_render\n"))
    testing.expect(t,strings.contains(table,"Shader_Id :: enum u8 {\n\tColor_Frag,\n\tFill_Comp,\n\tFill_Double_Comp,\n\tPoint_Vert,\n}"),"stages in the order of their files, a variant after its source")
    testing.expect(t,strings.contains(table,strings.concatenate({"SHADERS_FINGERPRINT :: \"",first.engine,"\""},context.temp_allocator)))
    testing.expect(t,strings.contains(table,"#panic(\"the shaders were generated without"),"the other system is told to ask for its backend")
    testing.expect(t,strings.contains(mini_read(&mini,"rhi/shaders_gen_test.odin"),"\tProbe_Comp,\n\tProbe_Double_Comp,\n"))
    testing.expect(t,mini_read(&mini,strings.concatenate({"shaders/build/fill.comp",HOST_CODE},context.temp_allocator))!=mini_read(&mini,strings.concatenate({"shaders/build/fill_double.comp",HOST_CODE},context.temp_allocator)),"a variant is another compilation")
    // A constant is no compilation: the code of each variant holds it, for the pipeline to set.
    for name in ([]string{"shaders/build/fill.comp","shaders/build/fill_double.comp"}) {
        testing.expectf(t,code_has_constant(mini_read(&mini,strings.concatenate({name,HOST_CODE},context.temp_allocator))),"%s keeps its constant for the pipeline",name)
    }
    testing.expect(t,!code_has_constant(mini_read(&mini,strings.concatenate({"shaders/build/color.frag",HOST_CODE},context.temp_allocator))),"a stage without constants has none")
    testing.expect_value(t,strings.count(manifest,"\"constants\": [\n        \"half\"\n      ]"),4)
    testing.expect_value(t,strings.count(table,"FILL_COMP_HALF :: 0\n"),1)
    testing.expect_value(t,strings.count(table,"constants = []string{\"half\"}"),2)
    leftovers,_:=os.read_all_directory_by_path(path_join(mini.root,"shaders",allocator=context.temp_allocator),context.temp_allocator)
    for entry in leftovers {testing.expectf(t,!strings.has_prefix(entry.name,".mirai-shaders-"),"the staging folder %s is removed",entry.name)}

    // Nothing changed: every stage comes from the output, and the output stays the same.
    second:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,second.error,"")
    testing.expect_value(t,second.compiled,0)
    testing.expect_value(t,second.reused,6)
    testing.expect(t,second.current,"nothing was looked at")
    testing.expect_value(t,second.engine,first.engine)
    testing.expect(t,mini_read(&mini,"shaders/build/manifest.json")==manifest && mini_read(&mini,"render/shaders_gen.odin")==table,"a generation from the same sources is the same, byte for byte")

    // An include of one stage: that stage alone is compiled again.
    fixture_write(t,mini.root,"shaders/include/tint.slang","#define TINT float4(0.5,0.5,0.5,1)\n")
    third:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,third.error,"")
    testing.expect_value(t,third.compiled,1)
    testing.expect_value(t,third.reused,5)
    testing.expect(t,third.engine!=first.engine,"the include is an engine source")

    // The output was lost: the shared cache gives the stages back without compiling.
    os.remove_all(mini.output)
    fourth:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,fourth.error,"")
    testing.expect_value(t,fourth.compiled,0)
    testing.expect_value(t,fourth.reused,6)
    testing.expect(t,os.is_file(path_join(mini.output,strings.concatenate({"point.vert",HOST_CODE},context.temp_allocator),allocator=context.temp_allocator)))
    // The cache of the checkout keeps the stamp alone; the shared one, an
    // entry and its code per digest: the six stages and the first color.frag.
    own:=files_in(path_join(mini.root,".mirai/shader-cache",allocator=context.temp_allocator))
    testing.expect(t,len(own)==1 && own[0].name==STAMP_FILE,"the cache of a checkout holds its stamp")
    stages:=files_in(path_join(mini.root,".mirai/cache",CACHE_NAME,CACHE_STAGES,allocator=context.temp_allocator))
    testing.expectf(t,len(stages)==14,"seven entries, each with the code of this system: %d files",len(stages))
}

@(test)
generation_that_fails_keeps_the_previous_one_whole :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    first:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,first.error,"")
    if first.error!="" {return}
    color_code:=strings.concatenate({"shaders/build/color.frag",HOST_CODE},context.temp_allocator)
    manifest,table,color:=mini_read(&mini,"shaders/build/manifest.json"),mini_read(&mini,"render/shaders_gen.odin"),mini_read(&mini,color_code)
    catalog:=mini_read(&mini,"shaders/build/catalog.json")
    // One stage changes and compiles; another no longer compiles.
    fixture_write(t,mini.root,"shaders/include/tint.slang","#define TINT float4(0.25,0.25,0.25,1)\n")
    fixture_write(t,mini.root,"shaders/point.vert.slang","this is not Slang\n")
    failed:=mini_generate(t,&mini,mini.options)
    testing.expect(t,strings.contains(failed.error,"point.vert.slang"),failed.error)
    testing.expect(t,mini_read(&mini,"shaders/build/manifest.json")==manifest && mini_read(&mini,"render/shaders_gen.odin")==table,"manifest and tables are those of the last whole generation")
    testing.expect(t,mini_read(&mini,color_code)==color,"a stage that compiled is not published without the rest")
    testing.expect(t,mini_read(&mini,"shaders/build/catalog.json")==catalog)
    leftovers,_:=os.read_all_directory_by_path(path_join(mini.root,"shaders",allocator=context.temp_allocator),context.temp_allocator)
    for entry in leftovers {testing.expectf(t,!strings.has_prefix(entry.name,".mirai-shaders-"),"the staging folder %s is removed",entry.name)}
    // Fixed: what compiled during the failed generation comes from the cache.
    fixture_write(t,mini.root,"shaders/point.vert.slang",POINT)
    fixed:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,fixed.error,"")
    testing.expect_value(t,fixed.compiled,0)
    testing.expect(t,mini_read(&mini,color_code)!=color,"the new generation is published")
    // Constants a pipeline cannot set fail the stage that declares them, by name, before any tool runs.
    published:=mini_read(&mini,"shaders/build/manifest.json")
    fixture_write(t,mini.root,"shaders/point.vert.slang",strings.concatenate({"//! constant a SAME\n//! constant b SAME\n",POINT},context.temp_allocator))
    twice:=mini_generate(t,&mini,mini.options)
    testing.expect(t,strings.contains(twice.error,"point.vert") && strings.contains(twice.error,"twice"),twice.error)
    testing.expect(t,mini_read(&mini,"shaders/build/manifest.json")==published,"nothing is published of it")
}

@(test)
generation_for_a_project_adds_its_programs_and_leaves_the_engine_tables :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    engine:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    table:=mini_read(&mini,"render/shaders_gen.odin")
    project:=path_join(mini.root,"game",allocator=context.temp_allocator)
    fixture_write(t,project,"shaders/glow.slang","//! mirai postprocess Glow\n//! parameter amount {\"default\":0.5,\"min\":0,\"max\":4}\nnamespace Glow {struct Parameters {float amount;}; float4 evaluate(Mirai_PostProcess_Context ctx,Parameters p) {return ctx.color*p.amount;}}\n")
    options:=mini.options
    options.project=project
    options.output=path_join(project,".mirai/shaders",allocator=context.temp_allocator)
    options.odin=false
    reload:=mini_generate(t,&mini,options)
    testing.expect_value(t,reload.error,"")
    testing.expect_value(t,reload.programs,mini_programs()+1)
    testing.expect_value(t,reload.shaders,4)
    testing.expect_value(t,reload.tests,0)
    testing.expect_value(t,reload.engine,engine.engine)
    testing.expect(t,mini_read(&mini,"render/shaders_gen.odin")==table,"the tables of the engine are not written for a project")
    catalog,_:=os.read_entire_file(path_join(options.output,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(catalog),"\"name\": \"Glow\"") && strings.contains(string(catalog),"\"source\": \"project/glow.slang\"") && strings.contains(string(catalog),"\"default\": 0.5,"))
    manifest,_:=os.read_entire_file(path_join(options.output,"manifest.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(manifest),"\"tests\": []"))
    testing.expect(t,os.is_file(path_join(project,".mirai/shader-cache",STAMP_FILE,allocator=context.temp_allocator)),"the stamp of a project is in the project")
    testing.expect(t,len(files_in(path_join(mini.root,".mirai/cache",CACHE_NAME,CACHE_REFLECTION,allocator=context.temp_allocator)))>0,"reflections are in the shared cache")
    testing.expect(t,!os.exists(path_join(options.output,"tests",allocator=context.temp_allocator)))
    testing.expect(t,reload.changed && reload.compiled==0 && reload.reused==4,"stages that do not read the catalog have the digest they have in the generation of the engine")

    // A plugin brings its programs from its own folder; the default output of a project is its .mirai/shaders.
    plugin:=path_join(mini.root,"plugins/fx/shaders",allocator=context.temp_allocator)
    fixture_write(t,plugin,"tint.slang","//! mirai surface Tint\n//! parameter tint {\"default\":[1,0.5,0.25],\"min\":0,\"max\":1,\"color\":true}\nnamespace Tint {struct Parameters {float3 tint;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {Mirai_Surface s=mirai_surface_default(ctx);s.base_color=p.tint;return s;}}\n")
    options.output=""
    options.odin=true
    options.sources={{name="fx",folder=plugin},{name="absent",folder=path_join(mini.root,"plugins/absent/shaders",allocator=context.temp_allocator)}}
    with_plugin:=mini_generate(t,&mini,options)
    testing.expect_value(t,with_plugin.error,"")
    testing.expect_value(t,with_plugin.programs,mini_programs()+2)
    testing.expect(t,with_plugin.changed)
    testing.expect(t,mini_read(&mini,"render/shaders_gen.odin")==table,"a generation with sources of plugins writes no engine tables either")
    catalog,_=os.read_entire_file(path_join(project,PROJECT_OUTPUT,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(catalog),"\"source\": \"plugins/fx/tint.slang\"") && strings.contains(string(catalog),"\"source\": \"project/glow.slang\""))
    testing.expect(t,os.exists(path_join(project,PROJECT_OUTPUT,"include/programs/plugins/fx/tint.slang",allocator=context.temp_allocator)))
    again:=mini_generate(t,&mini,options)
    testing.expect_value(t,again.error,"")
    testing.expect(t,!again.changed && again.compiled==0,"a generation equal to the published one does not touch its manifest")
    options.sources={{name="not a name",folder=plugin}}
    testing.expect(t,mini_generate(t,&mini,options).error!="")
}

@(test)
generation_reports_a_tool_that_is_missing :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    options:=Options{root=root}
    for &path in options.tools {path=path_join(root,"no-such-tool",allocator=context.temp_allocator)}
    result:=generate(options,context.temp_allocator)
    testing.expect(t,result.error!="","a compiler that cannot run is an error")
    testing.expect(t,!os.exists(path_join(root,"shaders/build/manifest.json",allocator=context.temp_allocator)))
}

// Stages that evaluate the programs of one domain each, as the real ones do.
@(private="file")
SHADE :: `#include "native.slang"
#include "material_raster.slang"
#include <surface_programs.slang>
struct Stage_Input { [[vk::location(0)]] float2 uv : TEXCOORD0; };
[shader("fragment")]
float4 main(Stage_Input input) : SV_Target0 {
    float3 n = float3(0, 1, 0);
    Material_Sample values = material_sample(material_row(1), material_context(float3(0), n, input.uv, input.uv, float2(0), false), float3(1), float3(0), n);
    return float4(values.base_color, values.alpha);
}
`

@(private="file")
POST :: `#include "native.slang"
#include "material_raster.slang"
#include <postprocess_programs.slang>
float4 mirai_scene_color(Mirai_PostProcess_Context ctx, float2 uv) {return ctx.color;}
float mirai_scene_depth(Mirai_PostProcess_Context ctx, float2 uv) {return ctx.depth;}
float3 mirai_scene_normal(Mirai_PostProcess_Context ctx, float2 uv) {return ctx.normal;}
Mirai_Outline mirai_outline(Mirai_PostProcess_Context ctx, float2 uv) {return (Mirai_Outline)0;}
struct Stage_Input { [[vk::location(0)]] float2 uv : TEXCOORD0; };
[shader("fragment")]
float4 main(Stage_Input input) : SV_Target0 {
    Mirai_PostProcess_Context ctx;
    ctx.uv = input.uv; ctx.resolution = float2(1); ctx.color = float4(1); ctx.depth = 0; ctx.normal = float3(0, 1, 0); ctx.time = frame.time.x;
    float4 packed[16];
    for (int i = 0; i < 16; i++) packed[i] = float4(0);
    return mirai_evaluate_postprocess(uint(input.uv.x), packed, ctx);
}
`

@(private="file")
TINT_PROGRAM :: "//! mirai surface Tint\n//! parameter tint {\"default\":[1,0.5,0.25],\"min\":0,\"max\":1,\"color\":true}\nnamespace Tint {struct Parameters {float3 tint;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {Mirai_Surface s=mirai_surface_default(ctx);s.base_color=p.tint*SCALE;return s;}}\n"
@(private="file")
tint_program :: proc(scale:string) -> string {
    text,_:=strings.replace_all(TINT_PROGRAM,"SCALE",scale,context.temp_allocator)
    return text
}


@(private="file")
GLOW_PROGRAM :: "//! mirai postprocess Glow\n//! parameter amount {\"default\":0.5,\"min\":0,\"max\":4}\nnamespace Glow {struct Parameters {float amount;}; float4 evaluate(Mirai_PostProcess_Context ctx,Parameters p) {return ctx.color*p.amount;}}\n"

@(test)
program_reaches_only_the_stages_of_its_domain_and_a_project_gets_the_code_of_its_system :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/shade.frag.slang",SHADE_EACH)
    fixture_write(t,mini.root,"shaders/post.frag.slang",POST)
    engine_options:=mini.options
    engine_options.odin=false
    engine:=mini_generate(t,&mini,engine_options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    // shade.frag and one for each Surface program of the engine.
    surfaces:=len(builtin_surface_programs())+len(MINI_SURFACES)
    testing.expect_value(t,engine.compiled,6+surfaces)
    testing.expect(t,os.is_file(path_join(mini.output,strings.concatenate({"shade.frag",HOST_CODE},context.temp_allocator),allocator=context.temp_allocator)) && !os.exists(path_join(mini.output,strings.concatenate({"shade.frag",OTHER_CODE},context.temp_allocator),allocator=context.temp_allocator)),"the engine has the backend of this system")

    project:=path_join(mini.root,"game",allocator=context.temp_allocator)
    output:=path_join(project,PROJECT_OUTPUT,allocator=context.temp_allocator)
    fixture_write(t,project,"shaders/tint.slang",tint_program("1.0"))
    options:=engine_options
    options.project=project
    // The first generation: the stage of the program of the project alone, for this system alone.
    first:=mini_generate(t,&mini,options)
    testing.expect_value(t,first.error,"")
    testing.expect_value(t,first.programs,mini_programs()+1)
    testing.expect_value(t,first.compiled,1)
    testing.expect_value(t,first.reused,6+surfaces)
    host,other:=HOST_CODE,OTHER_CODE
    for stage in ([]string{"shade.frag","post.frag","fill.comp"}) {
        testing.expectf(t,os.is_file(path_join(output,strings.concatenate({stage,host},context.temp_allocator),allocator=context.temp_allocator)),"%s%s is published",stage,host)
        testing.expectf(t,!os.exists(path_join(output,strings.concatenate({stage,other},context.temp_allocator),allocator=context.temp_allocator)),"%s%s is not made for a project",stage,other)
    }
    shade:=mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade__Tint.frag",host},context.temp_allocator))
    testing.expect(t,len(shade)>0,"the program of the project has its stage")
    testing.expect(t,mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade.frag",host},context.temp_allocator))==mini_read(&mini,strings.concatenate({"shaders/build/shade.frag",host},context.temp_allocator)),"the stage without a program is the engine's")
    testing.expect(t,mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/post.frag",host},context.temp_allocator))==mini_read(&mini,strings.concatenate({"shaders/build/post.frag",host},context.temp_allocator)))

    // Nothing changed.
    same:=mini_generate(t,&mini,options)
    testing.expect(t,same.error=="" && same.current && !same.changed && same.compiled==0 && same.reused==7+surfaces,"an unchanged project has nothing to do")
    testing.expect_value(t,same.programs,mini_programs()+1)
    testing.expect_value(t,same.engine,engine.engine)

    metadata,_:=strings.replace_all(tint_program("1.0"),"[1,0.5,0.25]","[0.25,0.5,1]",context.temp_allocator)
    fixture_write(t,project,"shaders/tint.slang",metadata)
    metadata_only:=mini_generate(t,&mini,options)
    testing.expect_value(t,metadata_only.error,"")
    testing.expect(t,!metadata_only.current && metadata_only.changed && metadata_only.compiled==0 && metadata_only.reused==7+surfaces,"metadata publishes the catalog without compiling any stage")
    testing.expect_value(t,mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade__Tint.frag",host},context.temp_allocator)),shade)
    testing.expect(t,strings.contains(mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/catalog.json"},context.temp_allocator)),"0.25"))

    // The program changes: its stage again, and no other.
    fixture_write(t,project,"shaders/tint.slang",tint_program("0.5"))
    edited:=mini_generate(t,&mini,options)
    testing.expect_value(t,edited.error,"")
    testing.expect(t,!edited.current && edited.changed)
    testing.expect_value(t,edited.compiled,1)
    testing.expect_value(t,edited.reused,6+surfaces)
    testing.expect(t,mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade__Tint.frag",host},context.temp_allocator))!=shade)

    // A PostProcess program after it: the stage of that domain alone.
    fixture_write(t,project,"shaders/zglow.slang",GLOW_PROGRAM)
    glow:=mini_generate(t,&mini,options)
    testing.expect_value(t,glow.error,"")
    testing.expect_value(t,glow.programs,mini_programs()+2)
    testing.expect_value(t,glow.compiled,1)
    testing.expect(t,mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/post.frag",host},context.temp_allocator))!=mini_read(&mini,strings.concatenate({"shaders/build/post.frag",host},context.temp_allocator)))

    // Both backends, asked for: every stage is compiled again with the other,
    // and the code of this system is the same bytes.
    shade=mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade.frag",host},context.temp_allocator))
    options.backends={.Vulkan,.Metal}
    both:=mini_generate(t,&mini,options)
    testing.expect_value(t,both.error,"")
    testing.expect_value(t,both.compiled,7+surfaces)
    testing.expect_value(t,both.reused,0)
    testing.expect(t,os.is_file(path_join(output,"shade.frag.metal",allocator=context.temp_allocator)) && os.is_file(path_join(output,"fill.comp.metal",allocator=context.temp_allocator)))
    testing.expect(t,mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade.frag",host},context.temp_allocator))==shade,"a backend compiles the same with or without the other")
    metal:=mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade.frag.metal"},context.temp_allocator))
    testing.expect(t,strings.has_suffix(metal,"}\n") && !strings.has_suffix(metal,"\n\n") && !strings.contains(metal," \n") && !strings.contains(metal,"\r"),"Metal sources are stored trimmed, with line feeds")

    // Metal alone, from nothing: the same source the two together gave.
    options.backends={.Metal}
    options.output=path_join(mini.root,"metal-only",allocator=context.temp_allocator)
    options.cache=path_join(mini.root,"metal-cache",allocator=context.temp_allocator)
    os.remove_all(path_join(mini.root,".mirai/cache",CACHE_NAME,CACHE_STAGES,allocator=context.temp_allocator))
    alone:=mini_generate(t,&mini,options)
    testing.expect_value(t,alone.error,"")
    testing.expect_value(t,alone.compiled,7+surfaces)
    testing.expect(t,mini_read(&mini,"metal-only/shade.frag.metal")==metal && len(metal)>0,"Metal compiles the same without Vulkan")
    testing.expect(t,!os.exists(path_join(options.output,"shade.frag.spv",allocator=context.temp_allocator)))
    manifest:=mini_read(&mini,"metal-only/manifest.json")
    testing.expect(t,strings.contains(manifest,"\"spv\": \"\"") && strings.contains(manifest,"\"msl\": \"shade.frag.metal\"") && !strings.contains(manifest,".spv\""),"a manifest names the code it has")
    testing.expect(t,strings.contains(manifest,"\"kind\": \"Uniform_Buffer\""),"the bindings are reflected from the backend that was compiled")
}

@(private="file")
SHADE_EACH :: "//! per surface program\n" + SHADE

@(private="file")
MOVE_EACH :: `#include "native.slang"
//! per vertex program
#include "scene.slang"
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<float4> moved : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    Mirai_Vertex_Context ctx = (Mirai_Vertex_Context)0;
    ctx.position = moved[id.x].xyz; ctx.normal = float3(0, 1, 0); ctx.uv1 = float2(float(id.x), 0.0);
    Mirai_Vertex v = mirai_vertex_default(ctx);
    mirai_vertex_program(1u, materials[0].custom_params, ctx, v);
    moved[id.x] = float4(v.position, 1.0);
}
`

@(private="file")
SWAY_PROGRAM :: "//! mirai surface Sway\n//! vertex animated reach 0.5\nnamespace Sway {struct Parameters {float strength;}; Mirai_Vertex vertex(Mirai_Vertex_Context ctx,Parameters p) {Mirai_Vertex v=mirai_vertex_default(ctx);v.position.x+=sin(ctx.time)*clamp(p.strength,0.0,0.5);return v;} Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n"

// A stage marked per vertex program is compiled only for the Surface
// programs with a function vertex, and has no stage of its own: one that
// moves no vertices runs nothing.
@(test)
stage_per_vertex_program_is_compiled_only_for_the_programs_that_move_vertices :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/move.comp.slang",MOVE_EACH)
    engine:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    host:=HOST_CODE
    published :: proc(folder,stage,host:string) -> bool {return os.is_file(path_join(folder,strings.concatenate({stage,host},context.temp_allocator),allocator=context.temp_allocator))}
    testing.expect(t,published(mini.output,"move__Pieces.comp",host),"the built-in program that moves vertices has its stage")
    for stage in ([]string{"move.comp","move__Ocean.comp","move__Grid.comp"}) {
        testing.expectf(t,!published(mini.output,stage,host),"%s%s is not compiled",stage,host)
    }
    table:=mini_read(&mini,"render/shaders_gen.odin")
    enum_end:=strings.index(table,"}")
    testing.expect(t,enum_end>0 && !strings.contains(table[:enum_end],"Move_Comp") && strings.contains(table,"name = \"move__Pieces.comp\""),"the stage is found by the name of its program")

    project:=path_join(mini.root,"game",allocator=context.temp_allocator)
    output:=path_join(project,PROJECT_OUTPUT,allocator=context.temp_allocator)
    fixture_write(t,project,"shaders/sway.slang",SWAY_PROGRAM)
    fixture_write(t,project,"shaders/tint.slang",tint_program("1.0"))
    options:=mini.options
    options.odin=false
    options.project=project
    first:=mini_generate(t,&mini,options)
    testing.expect_value(t,first.error,"")
    testing.expect_value(t,first.compiled,1)
    testing.expect(t,published(output,"move__Sway.comp",host) && !published(output,"move__Tint.comp",host),"of the programs of a project, only the one that moves vertices has the stage")
}

// A stage marked per Surface program: the stage of the materials without one,
// then one for each program, which the renderer finds by name outside
// Shader_Id. A program reaches only its own stage.
@(test)
stage_per_surface_program_is_compiled_for_each_program_and_only_that_program_reaches_it :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/shade.frag.slang",SHADE_EACH)
    engine:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    host:=HOST_CODE
    for stage in ([]string{"shade.frag","shade__Grid.frag","shade__Ocean.frag"}) {
        testing.expectf(t,os.is_file(path_join(mini.output,strings.concatenate({stage,host},context.temp_allocator),allocator=context.temp_allocator)),"%s%s is published",stage,host)
    }
    table:=mini_read(&mini,"render/shaders_gen.odin")
    enum_end:=strings.index(table,"}")
    testing.expect(t,enum_end>0 && strings.contains(table[:enum_end],"Shade_Frag") && !strings.contains(table[:enum_end],"Grid"),"Shader_Id has the stage of the materials without a program alone")
    testing.expect(t,strings.contains(table,"PROGRAM_SHADERS") && strings.contains(table,"name = \"shade__Grid.frag\""),"the stages of the programs are embedded by name")
    testing.expect(t,strings.contains(mini_read(&mini,"shaders/build/manifest.json"),"\"program_stages\""))

    project:=path_join(mini.root,"game",allocator=context.temp_allocator)
    output:=path_join(project,PROJECT_OUTPUT,allocator=context.temp_allocator)
    fixture_write(t,project,"shaders/tint.slang",tint_program("1.0"))
    options:=mini.options
    options.odin=false
    options.project=project
    first:=mini_generate(t,&mini,options)
    testing.expect_value(t,first.error,"")
    testing.expect_value(t,first.compiled,1)
    testing.expect(t,os.is_file(path_join(output,strings.concatenate({"shade__Tint.frag",host},context.temp_allocator),allocator=context.temp_allocator)),"the program of the project has its stage")
    testing.expect(t,mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/shade.frag",host},context.temp_allocator))==mini_read(&mini,strings.concatenate({"shaders/build/shade.frag",host},context.temp_allocator)),"the stage without a program is the engine's")

    fixture_write(t,project,"shaders/tint.slang",tint_program("0.5"))
    edited:=mini_generate(t,&mini,options)
    testing.expect_value(t,edited.error,"")
    testing.expect_value(t,edited.compiled,1)
}

@(test)
generation_is_current_until_a_source_a_folder_the_request_or_an_output_changes :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    testing.expect(t,!current(mini.options),"nothing was generated yet")
    first:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,first.error,"")
    if first.error!="" {return}
    testing.expect(t,!first.current)
    stamp:=path_join(mini.root,".mirai/shader-cache",STAMP_FILE,allocator=context.temp_allocator)
    testing.expect(t,os.is_file(stamp),"a published generation leaves its stamp in the cache")
    manifest_time,_:=os.modification_time_by_path(path_join(mini.output,"manifest.json",allocator=context.temp_allocator))
    testing.expect(t,current(mini.options),"current() sees the generation it would not repeat")
    regenerate :: proc(t:^testing.T,mini:^Mini,options:Options) -> Result {
        result:=mini_generate(t,mini,options)
        testing.expect_value(t,result.error,"")
        return result
    }
    again:=regenerate(t,&mini,mini.options)
    testing.expect(t,again.current && again.compiled==0 && again.reused==6 && !again.changed)
    testing.expect(t,again.shaders==4 && again.tests==2 && again.programs==mini_programs() && again.engine==first.engine,"a current generation says what the published one is")
    unchanged,_:=os.modification_time_by_path(path_join(mini.output,"manifest.json",allocator=context.temp_allocator))
    testing.expect_value(t,unchanged,manifest_time)
    // How many compilers run at once is not what is asked for.
    fewer:=mini.options
    fewer.workers=1
    testing.expect(t,current(fewer))
    testing.expect(t,regenerate(t,&mini,fewer).current)
    // Asked to ship, only the code render embeds is encoded again; that serves every request.
    ship:=mini.options
    ship.ship=true
    table:=mini_read(&mini,"render/shaders_gen.odin")
    testing.expect(t,!current(ship),"the embedded code was encoded fast")
    shipped:=regenerate(t,&mini,ship)
    testing.expect(t,!shipped.current && shipped.compiled==0 && shipped.reused==6)
    testing.expect(t,current(ship) && current(mini.options))
    testing.expect(t,regenerate(t,&mini,mini.options).current)
    testing.expect(t,mini_read(&mini,"render/shaders_gen.odin")==table,"the table is the same however its code was encoded")

    // A file that takes the place of an include it was looked for at first.
    fixture_write(t,mini.root,"shaders/tint.slang","#define TINT float4(0,0,0,1)\n")
    testing.expect(t,!current(mini.options),"current() sees the new file")
    shadowed:=regenerate(t,&mini,mini.options)
    testing.expect(t,!shadowed.current && shadowed.compiled==1 && shadowed.reused==5,"a new file that shadows an include is seen")
    testing.expect(t,current(mini.options))
    testing.expect(t,regenerate(t,&mini,mini.options).current)

    // A stage that appears in a folder.
    fixture_write(t,mini.root,"shaders/extra.vert.slang",POINT)
    added:=regenerate(t,&mini,mini.options)
    testing.expect(t,!added.current && added.shaders==5 && added.compiled==1)
    testing.expect(t,regenerate(t,&mini,mini.options).current)

    // A built-in program.
    ocean:=mini_read(&mini,"shaders/materials/ocean.slang")
    fixture_write(t,mini.root,"shaders/materials/ocean.slang",strings.concatenate({ocean,"// edited\n"},context.temp_allocator))
    testing.expect(t,!current(mini.options),"current() sees an edited source")
    program:=regenerate(t,&mini,mini.options)
    testing.expect(t,!program.current && program.compiled==0,"no stage of the fixture evaluates programs")
    testing.expect(t,regenerate(t,&mini,mini.options).current)

    // An output that was lost or replaced.
    point:=path_join(mini.output,strings.concatenate({"point.vert",HOST_CODE},context.temp_allocator),allocator=context.temp_allocator)
    os.remove(point)
    testing.expect(t,!current(mini.options))
    lost:=regenerate(t,&mini,mini.options)
    testing.expect(t,!lost.current && lost.compiled==0 && os.is_file(point),"the cache gives back a stage the output lost")
    testing.expect(t,regenerate(t,&mini,mini.options).current)
    fill:=strings.concatenate({"shaders/build/fill.comp",HOST_CODE},context.temp_allocator)
    published:=mini_read(&mini,fill)
    fixture_write(t,mini.root,fill,"not what was published, and of another size\n")
    replaced:=regenerate(t,&mini,mini.options)
    testing.expect(t,!replaced.current && replaced.compiled==0 && mini_read(&mini,fill)==published)

    // Another request.
    other:=mini.options
    other.odin=false
    testing.expect(t,!current(other))
    testing.expect(t,!regenerate(t,&mini,other).current)
    // A stamp that cannot be read is no stamp.
    testing.expect(t,regenerate(t,&mini,other).current)
    fixture_write(t,mini.root,".mirai/shader-cache/generation.json","{")
    testing.expect(t,!current(other))
    testing.expect(t,!regenerate(t,&mini,other).current)
}

// A worktree is another checkout with other paths: what one compiled, the
// other takes from the cache of the repository, for every output and stamp.
@(test)
a_worktree_reuses_what_another_checkout_compiled :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    first:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,first.error,"")
    if first.error!="" {return}
    worktree:=base.test_folder(t,"shaders")
    if worktree=="" {return}
    for path in listing_read(path_join(mini.root,"shaders",allocator=context.temp_allocator),true,context.temp_allocator).files {
        relative,_:=path_relative(path,mini.root)
        if strings.has_prefix(relative,"shaders/build/") {continue}
        data,_:=os.read_entire_file(path,context.temp_allocator)
        fixture_write(t,worktree,relative,string(data))
    }
    for folder in ([]string{"render","rhi"}) {os.make_directory_all(path_join(worktree,folder,allocator=context.temp_allocator))}
    // As git lays a worktree out: its .git names a folder of the repository's.
    fixture_write(t,mini.root,".git/worktrees/other/commondir","../..\n")
    fixture_write(t,worktree,".git",fmt.tprintf("gitdir: %s/.git/worktrees/other\n",mini.root))
    options:=mini.options
    options.root=worktree
    second:=mini_generate(t,&mini,options)
    testing.expect_value(t,second.error,"")
    testing.expect_value(t,second.compiled,0)
    testing.expect_value(t,second.reused,6)
    testing.expect_value(t,second.engine,first.engine)
    read :: proc(root,relative:string) -> string {
        data,_:=os.read_entire_file(path_join(root,relative,allocator=context.temp_allocator),context.temp_allocator)
        return string(data)
    }
    testing.expect(t,read(worktree,"render/shaders_gen.odin")==read(mini.root,"render/shaders_gen.odin"),"the same sources give the same tables in every checkout")
    testing.expect(t,!os.exists(path_join(worktree,".mirai/cache",allocator=context.temp_allocator)),"a worktree has no cache of its own")
    own:=files_in(path_join(worktree,".mirai/shader-cache",allocator=context.temp_allocator))
    testing.expect(t,len(own)==1 && own[0].name==STAMP_FILE,"the cache of a checkout holds its stamp")

    // Another output and stamp of the first checkout reuse them too.
    elsewhere:=mini.options
    elsewhere.odin=false
    elsewhere.output=path_join(mini.root,"elsewhere/build",allocator=context.temp_allocator)
    elsewhere.cache=path_join(mini.root,"elsewhere/stamp",allocator=context.temp_allocator)
    third:=mini_generate(t,&mini,elsewhere)
    testing.expect_value(t,third.error,"")
    testing.expect_value(t,third.compiled,0)
    testing.expect_value(t,third.reused,4)
}

// Stages that read the frame constants, and one that reads the ray hook too.
@(private="file")
FRAME :: `#include "native.slang"
#include "common.slang"
[[vk::binding(0, 0)]] ConstantBuffer<Frame_Data> frame_data;
[[vk::binding(1, 0)]] RWStructuredBuffer<uint> out_data;
[shader("compute")]
[numthreads(1, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    out_data[id.x] = frame_data.frame_index;
}
`

@(private="file")
GATED :: `#include "native.slang"
#include "common.slang"
[[vk::binding(0, 0)]] ConstantBuffer<Frame_Data> frame_data;
[[vk::binding(1, 0)]] RWStructuredBuffer<uint> out_data;
[shader("compute")]
[numthreads(1, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
#ifdef MIRAI_HOOK_RAY
    out_data[id.x] = frame_data.frame_index + 1;
#else
    out_data[id.x] = frame_data.frame_index;
#endif
}
`

@(private="file")
RAY_HOOK :: "//! mirai hook ray gate_ray\nbool gate_ray(float3 origin,float3 direction,float t_max,out float t,out float3 next_origin,out float3 next_direction) {t=t_max;next_origin=origin;next_direction=direction;return false;}\n"
@(private="file")
PROBE_HOOK :: "//! mirai hook probes gate_probes\nfloat gate_probes(float3 position,float3 direction,out float3 beyond,out float3 front,out float4 through[3]) {beyond=position;front=position;through[0]=0;through[1]=0;through[2]=0;return 0;}\n"

@(test)
stage_is_compiled_against_the_extensions_its_sources_name :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/frame.comp.slang",FRAME)
    fixture_write(t,mini.root,"shaders/gated.comp.slang",GATED)
    engine_options:=mini.options
    engine_options.odin=false
    engine:=mini_generate(t,&mini,engine_options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    testing.expect_value(t,engine.compiled,6)

    // Ray and probe hooks: the stage that names MIRAI_HOOK_RAY is compiled
    // with it alone, and the one that names neither is the engine's.
    game:=path_join(mini.root,"game",allocator=context.temp_allocator)
    fixture_write(t,game,"shaders/gate_ray.slang",RAY_HOOK)
    fixture_write(t,game,"shaders/gate_probes.slang",PROBE_HOOK)
    options:=engine_options
    options.project=game
    hooked:=mini_generate(t,&mini,options)
    testing.expect_value(t,hooked.error,"")
    testing.expect_value(t,hooked.compiled,1)
    testing.expect_value(t,hooked.reused,5)
    code :: proc(folder,stage:string) -> string {
        data,_:=os.read_entire_file(path_join(folder,strings.concatenate({stage,HOST_CODE},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
        return string(data)
    }
    output:=path_join(game,PROJECT_OUTPUT,allocator=context.temp_allocator)
    testing.expect(t,code(output,"frame.comp")==code(mini.output,"frame.comp"))
    testing.expect(t,code(output,"gated.comp")!=code(mini.output,"gated.comp"),"the stage reads the ray hook")
    published,_:=os.read_entire_file(path_join(output,"include",EXTENSIONS_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(published),"#define MIRAI_HOOK_RAY 1\n#define MIRAI_HOOK_PROBES 1\n"),"the generation publishes every feature")

    // Another project with the ray hook alone: its stages are those the first compiled.
    ray:=path_join(mini.root,"ray",allocator=context.temp_allocator)
    fixture_write(t,ray,"shaders/gate_ray.slang",RAY_HOOK)
    options.project=ray
    alone:=mini_generate(t,&mini,options)
    testing.expect_value(t,alone.error,"")
    testing.expect_value(t,alone.compiled,0)
    testing.expect_value(t,alone.reused,6)
    testing.expect(t,code(path_join(ray,PROJECT_OUTPUT,allocator=context.temp_allocator),"gated.comp")==code(output,"gated.comp"))
}

@(private="file")
WIND_FRAME :: "//! mirai frame Wind_Frame wind\n//! mirai needs nested_views\nstruct Wind_Frame {float4 speed;};\n"
@(private="file")
WIND :: `#include "native.slang"
#include "common.slang"
[[vk::binding(0, 0)]] ConstantBuffer<Frame_Data> frame_data;
[[vk::binding(1, 0)]] RWStructuredBuffer<float> out_data;
[shader("compute")]
[numthreads(1, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    out_data[id.x] = frame_data.wind.speed.x + frame_data.nested[0].eye.x;
}
`

// The nested views and the frame fields of an extension: a stage of the
// engine that reads neither is the one of the engine, and a stage of the
// project that reads them is compiled with both.
@(test)
frame_fields_and_nested_views_reach_only_the_stages_that_read_them :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/frame.comp.slang",FRAME)
    engine_options:=mini.options
    engine_options.odin=false
    engine:=mini_generate(t,&mini,engine_options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}

    game:=path_join(mini.root,"game",allocator=context.temp_allocator)
    fixture_write(t,game,"shaders/wind_frame.slang",WIND_FRAME)
    fixture_write(t,game,"shaders/wind.comp.slang",WIND)
    options:=engine_options
    options.project=game
    extended:=mini_generate(t,&mini,options)
    testing.expect_value(t,extended.error,"")
    testing.expect_value(t,extended.compiled,1)
    testing.expect_value(t,extended.reused,engine.compiled+engine.reused)
    code :: proc(folder,stage:string) -> string {
        data,_:=os.read_entire_file(path_join(folder,strings.concatenate({stage,HOST_CODE},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
        return string(data)
    }
    testing.expect(t,code(path_join(game,PROJECT_OUTPUT,allocator=context.temp_allocator),"frame.comp")==code(mini.output,"frame.comp"))
}

@(test)
first_stages_go_out_alone_before_the_others :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/shade.frag.slang",SHADE_EACH)
    fixture_write(t,mini.root,"shaders/tone.frag.slang",SHADE_EACH)
    engine_options:=mini.options
    engine_options.odin=false
    engine:=mini_generate(t,&mini,engine_options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    project:=path_join(mini.root,"game",allocator=context.temp_allocator)
    output:=path_join(project,PROJECT_OUTPUT,allocator=context.temp_allocator)
    first:=path_join(mini.root,"first",allocator=context.temp_allocator)
    fixture_write(t,project,"shaders/tint.slang",tint_program("1.0"))
    options:=engine_options
    options.project=project
    published:=mini_generate(t,&mini,options)
    testing.expect_value(t,published.error,"")
    code :: proc(folder,stage:string) -> string {
        extension:=".metal" when ODIN_OS==.Darwin else ".spv"
        data,_:=os.read_entire_file(path_join(folder,strings.concatenate({stage,extension},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
        return string(data)
    }
    tone:=code(output,"tone__Tint.frag")

    // The program changes: its stage of shade goes out first, with that of tone as the output had it.
    fixture_write(t,project,"shaders/tint.slang",tint_program("0.5"))
    progress:Progress
    options.first={"shade.frag"}
    options.first_output=first
    options.progress=&progress
    edited:=mini_generate(t,&mini,options)
    testing.expect_value(t,edited.error,"")
    testing.expect_value(t,edited.compiled,2)
    testing.expect(t,progress.first,"the first stages were written")
    testing.expect(t,len(code(first,"shade__Tint.frag"))>0 && code(first,"shade__Tint.frag")==code(output,"shade__Tint.frag"),"the first stage is the one the generation published")
    testing.expect(t,code(first,"tone__Tint.frag")==tone && code(output,"tone__Tint.frag")!=tone,"another stage is as the output had it")
    testing.expect(t,code(first,"fill.comp")==code(output,"fill.comp"))
    early,early_read:=read_json(path_join(first,"manifest.json",allocator=context.temp_allocator),context.temp_allocator)
    whole,_:=read_json(path_join(output,"manifest.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,early_read && json_text(early["engine"])==edited.engine && json_text(early["catalog"])==json_text(whole["catalog"]),"it names the engine and the catalog of the generation")
    testing.expect(t,mini_read(&mini,"first/catalog.json")==mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/catalog.json"},context.temp_allocator)))
    shaders,_:=early["shaders"].(json.Array)
    testing.expect_value(t,len(shaders),6)

    // Without changes nothing is compiled and nothing is written there.
    os.remove_all(first)
    again:Progress
    options.progress=&again
    same:=mini_generate(t,&mini,options)
    testing.expect(t,same.error=="" && same.current && !again.first && !os.exists(first))
}

@(test)
stages_in_use_go_out_before_the_idle_ones :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/shade.frag.slang",SHADE_EACH)
    fixture_write(t,mini.root,"shaders/tone.frag.slang",SHADE_EACH)
    engine_options:=mini.options
    engine_options.odin=false
    engine:=mini_generate(t,&mini,engine_options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    project:=path_join(mini.root,"game",allocator=context.temp_allocator)
    output:=path_join(project,PROJECT_OUTPUT,allocator=context.temp_allocator)
    first:=path_join(mini.root,"first",allocator=context.temp_allocator)
    active:=path_join(mini.root,"active",allocator=context.temp_allocator)
    fixture_write(t,project,"shaders/tint.slang",tint_program("1.0"))
    options:=engine_options
    options.project=project
    published:=mini_generate(t,&mini,options)
    testing.expect_value(t,published.error,"")
    code :: proc(folder,stage:string) -> string {
        data,_:=os.read_entire_file(path_join(folder,strings.concatenate({stage,HOST_CODE},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
        return string(data)
    }
    tone:=code(output,"tone__Tint.frag")

    // The program changes and its stage of tone is idle: the stages in use go out with it as the output had it.
    fixture_write(t,project,"shaders/tint.slang",tint_program("0.5"))
    progress:Progress
    options.first={"shade.frag"}
    options.first_output=first
    options.idle={"tone.frag"}
    options.active_output=active
    options.progress=&progress
    edited:=mini_generate(t,&mini,options)
    testing.expect_value(t,edited.error,"")
    testing.expect_value(t,edited.compiled,2)
    testing.expect(t,progress.first && progress.active,"both early generations were written")
    testing.expect(t,len(code(active,"shade__Tint.frag"))>0 && code(active,"shade__Tint.frag")==code(output,"shade__Tint.frag"),"a stage in use is the one the generation published")
    testing.expect(t,code(active,"tone__Tint.frag")==tone && code(output,"tone__Tint.frag")!=tone,"the idle stage is as the output had it")
    testing.expect(t,code(active,"fill.comp")==code(output,"fill.comp"))
    testing.expect(t,mini_read(&mini,"active/catalog.json")==mini_read(&mini,strings.concatenate({"game/",PROJECT_OUTPUT,"/catalog.json"},context.temp_allocator)))

    // Without an idle stage the whole generation is the one in use: nothing is written there.
    os.remove_all(active)
    fixture_write(t,project,"shaders/tint.slang",tint_program("0.25"))
    whole:Progress
    options.idle={}
    options.progress=&whole
    again:=mini_generate(t,&mini,options)
    testing.expect_value(t,again.error,"")
    testing.expect(t,whole.first && !whole.active && !os.exists(active))
}

@(test)
cancelled_generation_publishes_nothing :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    published:=mini_generate(t,&mini,mini.options)
    testing.expect_value(t,published.error,"")
    if published.error!="" {return}
    manifest:=mini_read(&mini,"shaders/build/manifest.json")
    fixture_write(t,mini.root,"shaders/include/tint.slang","#define TINT float4(0.5,0.5,0.5,1)\n")
    progress:Progress
    cancel(&progress)
    options:=mini.options
    options.progress=&progress
    cancelled:=mini_generate(t,&mini,options)
    testing.expect(t,cancelled.cancelled && cancelled.error!="",cancelled.error)
    testing.expect(t,mini_read(&mini,"shaders/build/manifest.json")==manifest,"the published generation stays")
    leftovers,_:=os.read_all_directory_by_path(path_join(mini.root,"shaders",allocator=context.temp_allocator),context.temp_allocator)
    for entry in leftovers {testing.expectf(t,!strings.has_prefix(entry.name,".mirai-shaders-"),"the staging folder %s is removed",entry.name)}
    next:=mini_generate(t,&mini,mini.options)
    testing.expect(t,next.error=="" && !next.cancelled && next.compiled==1,"the next generation runs as usual")
}

@(test)
overlay_compiles_sources_from_memory_and_saving_them_leaves_the_generation_current :: proc(t:^testing.T) {
    mini:Mini
    if !mini_make(t,&mini) {return}
    fixture_write(t,mini.root,"shaders/shade.frag.slang",SHADE_EACH)
    engine_options:=mini.options
    engine_options.odin=false
    engine:=mini_generate(t,&mini,engine_options)
    testing.expect_value(t,engine.error,"")
    if engine.error!="" {return}
    project:=path_join(mini.root,"game",allocator=context.temp_allocator)
    output:=path_join(project,PROJECT_OUTPUT,allocator=context.temp_allocator)
    tint:=path_join(project,"shaders/tint.slang",allocator=context.temp_allocator)
    read :: proc(path:string) -> string {
        data,_:=os.read_entire_file(path,context.temp_allocator)
        return string(data)
    }
    shade_code:=path_join(output,strings.concatenate({"shade__Tint.frag",HOST_CODE},context.temp_allocator),allocator=context.temp_allocator)
    fixture_write(t,project,"shaders/tint.slang",tint_program("1.0"))
    options:=engine_options
    options.project=project
    saved:=mini_generate(t,&mini,options)
    testing.expect_value(t,saved.error,"")
    shade:=read(shade_code)

    // The program changes in memory: it is compiled from its copy and its file keeps what it had.
    unsaved:=tint_program("0.5")
    options.overlay={{path=tint,data=transmute([]u8)unsaved}}
    edited:=mini_generate(t,&mini,options)
    testing.expect_value(t,edited.error,"")
    testing.expect_value(t,edited.compiled,1)
    testing.expect_value(t,read(tint),tint_program("1.0"))
    testing.expect_value(t,read(path_join(output,"include/programs/project/tint.slang",allocator=context.temp_allocator)),unsaved)
    testing.expect(t,read(shade_code)!=shade,"the stage that evaluates it has what memory holds")
    testing.expect(t,current(options),"the same memory is current")
    from_disk:=options
    from_disk.overlay=nil
    testing.expect(t,!current(from_disk),"the file is not what was published")

    // Saved, the file holds what memory held: nothing is left to do.
    fixture_write(t,project,"shaders/tint.slang",unsaved)
    testing.expect(t,current(from_disk),"saving leaves the generation current")

    // Memory can add a source and take one away.
    sand,_:=strings.replace_all(tint_program("0.25"),"Tint","Sand",context.temp_allocator)
    options.overlay={{path=tint,removed=true},{path=path_join(project,"shaders/sand.slang",allocator=context.temp_allocator),data=transmute([]u8)sand}}
    moved:=mini_generate(t,&mini,options)
    testing.expect_value(t,moved.error,"")
    catalog:=read(path_join(output,"catalog.json",allocator=context.temp_allocator))
    testing.expect(t,strings.contains(catalog,"\"name\": \"Sand\"") && !strings.contains(catalog,"\"name\": \"Tint\""))
    testing.expect(t,os.is_file(tint) && !os.exists(path_join(project,"shaders/sand.slang",allocator=context.temp_allocator)))

    // A stage of the project that includes a source of memory by its name would compile its file.
    lit,_:=strings.replace_all(COLOR,"tint.slang","lit_tint.slang",context.temp_allocator)
    fixture_write(t,project,"shaders/lit.frag.slang",lit)
    fixture_write(t,project,"shaders/lit_tint.slang","#define TINT float4(1,1,1,1)\n")
    options.overlay={{path=path_join(project,"shaders/lit_tint.slang",allocator=context.temp_allocator),data=transmute([]u8)string("#define TINT float4(0,0,0,1)\n")}}
    refused:=mini_generate(t,&mini,options)
    testing.expect(t,strings.contains(refused.error,"project/shaders/lit_tint.slang, which has unsaved changes"),refused.error)
}
