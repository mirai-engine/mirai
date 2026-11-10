package shaders

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private="file")
float_string :: proc(value:f64) -> string {
    builder:=strings.builder_make(context.temp_allocator)
    float_text(&builder,value)
    return strings.to_string(builder)
}

@(test)
float_is_written_as_the_shortest_decimal_that_reads_back :: proc(t:^testing.T) {
    Case :: struct {value:f64,text:string}
    // Added at run time: as constants they would make 0.3 exactly.
    tenth,fifth:f64=0.1,0.2
    cases:=[]Case{
        {0.5,"0.5"},{1,"1.0"},{-1,"-1.0"},{100,"100.0"},{0.01,"0.01"},{0.075,"0.075"},{1.4,"1.4"},{0.045,"0.045"},
        {1e20,"1e+20"},{-1e20,"-1e+20"},{1e30,"1e+30"},{1e16,"1e+16"},{1e15,"1000000000000000.0"},{123456789012345680,"1.2345678901234568e+17"},
        {0.0001,"0.0001"},{0.00001,"1e-05"},{1.5e-7,"1.5e-07"},{2.5e-100,"2.5e-100"},{0,"0.0"},{1234.5678,"1234.5678"},{tenth+fifth,"0.30000000000000004"},
    }
    for c in cases {testing.expect_value(t,float_string(c.value),c.text)}
}

@(test)
json_is_written_one_member_per_line_with_two_spaces :: proc(t:^testing.T) {
    writer:=json_writer(context.temp_allocator)
    json_object_begin(&writer)
    json_key(&writer,"version");json_integer(&writer,1)
    json_key(&writer,"name");json_string(&writer,"a \"quoted\"\\path\n\tñ")
    json_key(&writer,"empty");json_array_begin(&writer);json_array_end(&writer)
    json_key(&writer,"nothing");json_object_begin(&writer);json_object_end(&writer)
    json_key(&writer,"list");json_array_begin(&writer)
    json_integer(&writer,-3)
    json_bool(&writer,true)
    json_number(&writer,{is_float=true,float=0.25})
    json_number(&writer,{integer=7})
    json_object_begin(&writer)
    json_key(&writer,"slot");json_integer(&writer,19)
    json_object_end(&writer)
    json_array_end(&writer)
    json_object_end(&writer)
    expected:="{\n  \"version\": 1,\n  \"name\": \"a \\\"quoted\\\"\\\\path\\n\\t\\u00f1\",\n  \"empty\": [],\n  \"nothing\": {},\n  \"list\": [\n    -3,\n    true,\n    0.25,\n    7,\n    {\n      \"slot\": 19\n    }\n  ]\n}\n"
    text:=string(json_finish(&writer))
    testing.expect_value(t,text,expected)
    _,parse_error:=json.parse_string(text,allocator=context.temp_allocator)
    testing.expect_value(t,parse_error,json.Error.None)
}

@(test)
shader_entry_survives_the_manifest :: proc(t:^testing.T) {
    bindings:=[]Binding{{0,"Uniform_Buffer"},{2,"Sampler"},{34,"Texture_Table"}}
    shader:=Shader{id="Gbuffer_Plain_Frag",name="gbuffer_plain.frag",stage=.Fragment,spv="gbuffer_plain.frag.spv",msl="gbuffer_plain.frag.metal",entry="main0",bindings=bindings,fingerprint="f",spv_hash="s",msl_hash="m",staged=true}
    writer:=json_writer(context.temp_allocator)
    shader_to_json(&writer,shader)
    parsed,_:=json.parse(json_finish(&writer),parse_integers=true,allocator=context.temp_allocator)
    read,ok:=shader_from_json(parsed.(json.Object),context.temp_allocator)
    testing.expect(t,ok)
    testing.expect_value(t,read.id,shader.id)
    testing.expect_value(t,read.name,shader.name)
    testing.expect_value(t,read.stage,Stage.Fragment)
    testing.expect_value(t,read.msl,shader.msl)
    testing.expect_value(t,len(read.bindings),3)
    testing.expect_value(t,read.bindings[2],bindings[2])
    testing.expect(t,!read.staged)
    // An entry that is not a shader is no entry.
    broken,_:=json.parse_string("{\"id\":\"A\",\"name\":\"a\",\"stage\":\"Geometry\",\"bindings\":[],\"group\":[0,0,0]}",parse_integers=true,allocator=context.temp_allocator)
    _,valid:=shader_from_json(broken.(json.Object),context.temp_allocator)
    testing.expect(t,!valid)
}

@(test)
stage_and_identifier_come_from_the_file_name :: proc(t:^testing.T) {
    stem,stage,ok:=stage_of("ddgi_trace.comp.slang")
    testing.expect(t,ok && stem=="ddgi_trace" && stage==.Compute)
    stem,stage,ok=stage_of("gbuffer.vert.slang")
    testing.expect(t,ok && stem=="gbuffer" && stage==.Vertex)
    _,_,ok=stage_of("brdf.slang")
    testing.expect(t,!ok,"an include is not a stage")
    _,_,ok=stage_of(".frag.slang")
    testing.expect(t,!ok)
    _,_,ok=stage_of("notes.comp.txt")
    testing.expect(t,!ok)
    testing.expect_value(t,identifier("ddgi_trace_color_hw.comp",context.temp_allocator),"Ddgi_Trace_Color_Hw_Comp")
    testing.expect_value(t,identifier("blit.frag",context.temp_allocator),"Blit_Frag")
    testing.expect_value(t,identifier("a--b..9c",context.temp_allocator),"A_B_9c")
}

@(test)
variants_are_the_source_and_its_variant_lines :: proc(t:^testing.T) {
    found:=variants("//! variant hw MIRAI_HARDWARE_RT=1\n#include \"x.slang\"\n//! variant color_hw MIRAI_HARDWARE_RT=1 MIRAI_COLORED=1\r\n//! variant\n// ! variant no A\n//!variant tight B\n",context.temp_allocator)
    testing.expect_value(t,len(found),4)
    testing.expect(t,found[0].name=="" && len(found[0].defines)==0,"the source itself comes first")
    testing.expect(t,found[1].name=="hw" && len(found[1].defines)==1 && found[1].defines[0]=="MIRAI_HARDWARE_RT=1")
    testing.expect(t,found[2].name=="color_hw" && len(found[2].defines)==2 && found[2].defines[1]=="MIRAI_COLORED=1")
    testing.expect(t,found[3].name=="tight" && found[3].defines[0]=="B")
}

@(test)
metal_entry_point_is_the_name_spirv_cross_gave_it :: proc(t:^testing.T) {
    name,ok:=metal_entry("#include <metal_stdlib>\nstatic inline float kernel_weight(float x) {return x;}\nkernel void main0(uint3 id [[thread_position_in_grid]])\n{\n}\n")
    testing.expect(t,ok)
    testing.expect_value(t,name,"main0")
    name,ok=metal_entry("struct main0_out {float4 c;};\nfragment main0_out shade_0(main0_in in)\n{\n}\n")
    testing.expect(t,ok)
    testing.expect_value(t,name,"shade_0")
    name,ok=metal_entry("vertex\n  main0_out   main0(uint id)")
    testing.expect(t,ok && name=="main0")
    _,ok=metal_entry("float4 vertex_color(float4 c) {return c;}\n")
    testing.expect(t,!ok,"a function is not an entry point")
}

@(test)
metal_texture_table_moves_to_the_buffer_index_of_the_rhi :: proc(t:^testing.T) {
    // What SPIRV-Cross writes for the texture table with --msl-argument-buffers.
    table:=`struct spvDescriptorSetBuffer1
{
    array<texture2d<float>, 1024> table [[id(34)]];
};

kernel void main0(constant spvDescriptorSetBuffer1& spvDescriptorSet1 [[buffer(1)]], device StructuredBuffer& queries [[buffer(1)]], sampler table_sampler [[sampler(2)]])
{
    results._member0[0] = spvDescriptorSet1.table[3].sample(table_sampler, float2(0.0), level(0.0));
}
`
    moved,ok:=metal_table_buffer(table,context.temp_allocator)
    testing.expect(t,ok)
    testing.expect(t,strings.contains(moved,"spvDescriptorSet1 [[buffer(30)]], device StructuredBuffer& queries [[buffer(1)]]"),moved)
    plain:="kernel void main0(device StructuredBuffer& queries [[buffer(1)]]) {}"
    same,plain_ok:=metal_table_buffer(plain,context.temp_allocator)
    testing.expect(t,plain_ok && same==plain,"a stage without the table is left alone")
    other,_:=strings.replace_all(table,"spvDescriptorSetBuffer1","spvDescriptorSetBuffer2",context.temp_allocator)
    _,other_ok:=metal_table_buffer(other,context.temp_allocator)
    testing.expect(t,!other_ok,"an argument buffer of another set is refused")
}

@(test)
metal_source_is_stored_without_trailing_spaces :: proc(t:^testing.T) {
    testing.expect_value(t,string(metal_normalize("a  \n\tb\t \n\n  c\n\n\n",context.temp_allocator)),"a\n\tb\n\n  c\n")
    testing.expect_value(t,string(metal_normalize("one line",context.temp_allocator)),"one line\n")
    testing.expect_value(t,string(metal_normalize("a\r\nb\r\n",context.temp_allocator)),"a\nb\n")
}

@(test)
paths_sort_by_component_and_relate_with_slashes :: proc(t:^testing.T) {
    testing.expect(t,path_less("a/z","a.b/c"),"a folder sorts before a longer name that starts with it")
    testing.expect(t,!path_less("a.b/c","a/z"))
    testing.expect(t,path_less("a/b","a/b/c") && !path_less("a/b/c","a/b"))
    testing.expect(t,!path_less("a/b","a/b"))
    paths:=[]string{"s/include/x.slang","s/b.slang","s/a.slang","s/include/a/b.slang"}
    sort_paths(paths)
    testing.expect_value(t,paths[0],"s/a.slang")
    testing.expect_value(t,paths[1],"s/b.slang")
    testing.expect_value(t,paths[2],"s/include/a/b.slang")
    testing.expect_value(t,paths[3],"s/include/x.slang")
    testing.expect_value(t,path_from("C:/e/shaders/build","C:/e/render",context.temp_allocator),"../shaders/build")
    testing.expect_value(t,path_from("C:/e/shaders/build/tests","C:/e/rhi",context.temp_allocator),"../shaders/build/tests")
    testing.expect_value(t,path_from("C:/e/out","C:/e",context.temp_allocator),"out")
    relative,inside:=path_relative("C:/e/shaders/a.slang","C:/e")
    testing.expect(t,inside && relative=="shaders/a.slang")
    _,inside=path_relative("C:/engine2/a.slang","C:/e")
    testing.expect(t,!inside)
    testing.expect(t,path_inside("C:/e","C:/e") && path_inside("C:/e/x","C:/e") && !path_inside("C:/ex","C:/e"))
    testing.expect_value(t,path_parent("C:/e/shaders/a.slang"),"C:/e/shaders")
    testing.expect_value(t,path_name("C:/e/shaders/a.slang"),"a.slang")
}

@(private="file")
reflection :: proc(t:^testing.T,text:string) -> json.Object {
    value,err:=json.parse_string(text,parse_integers=true,allocator=context.temp_allocator)
    testing.expect_value(t,err,json.Error.None)
    return value.(json.Object)
}

@(test)
resources_are_the_used_parameters_sorted_by_slot :: proc(t:^testing.T) {
    data:=reflection(t,`{"parameters":[
        {"name":"results","binding":{"kind":"descriptorTableSlot","index":4},"type":{"kind":"resource","baseShape":"structuredBuffer","access":"readWrite"}},
        {"name":"unused","binding":{"kind":"descriptorTableSlot","index":9},"type":{"kind":"resource","baseShape":"texture2D"}},
        {"name":"table","binding":{"kind":"descriptorTableSlot","space":1,"index":34},"type":{"kind":"array","elementCount":0,"elementType":{"kind":"resource","baseShape":"texture2D"}}},
        {"name":"params","binding":{"kind":"descriptorTableSlot","index":1},"type":{"kind":"constantBuffer"}},
        {"name":"image","binding":{"kind":"descriptorTableSlot","index":20},"type":{"kind":"resource","baseShape":"texture2D","access":"readWrite"}},
        {"name":"scene","binding":{"kind":"descriptorTableSlot","index":29},"type":{"kind":"resource","baseShape":"accelerationStructure"}},
        {"name":"filter","binding":{"kind":"descriptorTableSlot","index":2},"type":{"kind":"samplerState"}}],
      "entryPoints":[{"name":"main","bindings":[
        {"name":"results","binding":{"kind":"descriptorTableSlot","index":4,"used":1}},
        {"name":"unused","binding":{"kind":"descriptorTableSlot","index":9,"used":0}},
        {"name":"table","binding":{"kind":"descriptorTableSlot","space":1,"index":34,"used":1}},
        {"name":"params","binding":{"kind":"descriptorTableSlot","index":1,"used":true}},
        {"name":"image","binding":{"kind":"descriptorTableSlot","index":20,"used":1}},
        {"name":"scene","binding":{"kind":"descriptorTableSlot","index":29,"used":1}},
        {"name":"filter","binding":{"kind":"descriptorTableSlot","index":2,"used":1}}]}]}`)
    resources,problem:=reflected_resources(data,context.temp_allocator)
    testing.expect_value(t,problem,"")
    expected:=[]Binding{{1,"Uniform_Buffer"},{2,"Sampler"},{4,"Storage_Buffer_RW"},{20,"Storage_Texture"},{29,"Accel"},{34,"Texture_Table"}}
    testing.expect_value(t,len(resources),len(expected))
    for binding,i in expected {if i<len(resources) {testing.expect_value(t,resources[i],binding)}}
    // A table with a size is not the one of the RHI, which grows.
    sized:=reflection(t,`{"parameters":[
        {"name":"table","binding":{"kind":"descriptorTableSlot","space":1,"index":34},"type":{"kind":"array","elementCount":1024,"elementType":{"kind":"resource","baseShape":"texture2D"}}}],
      "entryPoints":[{"name":"main","bindings":[{"name":"table","binding":{"kind":"descriptorTableSlot","space":1,"index":34,"used":1}}]}]}`)
    _,problem=reflected_resources(sized,context.temp_allocator)
    testing.expect(t,strings.contains(problem,"texture table"),problem)
}

@(test)
resources_outside_the_portable_binding_abi_are_rejected :: proc(t:^testing.T) {
    Case :: struct {parameter,expected:string}
    cases:=[]Case{
        {`"binding":{"kind":"descriptorTableSlot","index":30},"type":{"kind":"constantBuffer"}`,"exceeds the 30 portable slots"},
        {`"binding":{"kind":"descriptorTableSlot","index":16},"type":{"kind":"samplerState"}`,"exceeds 16 Metal indices"},
        {`"binding":{"kind":"descriptorTableSlot","index":34},"type":{"kind":"resource","baseShape":"texture2D"}`,"overlaps the texture table"},
        {`"binding":{"kind":"descriptorTableSlot","index":3},"type":{"kind":"array","elementCount":4,"elementType":{"kind":"resource","baseShape":"texture2D"}}`,"only set 0 scalar resources"},
        {`"binding":{"kind":"descriptorTableSlot","space":2,"index":3},"type":{"kind":"constantBuffer"}`,"only set 0 scalar resources"},
        {`"binding":{"kind":"descriptorTableSlot","space":1,"index":34},"type":{"kind":"array","elementCount":0,"elementType":{"kind":"resource","baseShape":"textureCube"}}`,"must be Texture2D"},
        {`"binding":{"kind":"uniform","offset":0},"type":{"kind":"scalar"}`,"explicit descriptor binding"},
        {`"binding":{"kind":"descriptorTableSlot","index":3},"type":{"kind":"resource","baseShape":"textureCube"}`,"unsupported resource type"},
        {`"binding":{"kind":"descriptorTableSlot","index":3},"type":{"kind":"struct"}`,"unsupported parameter type"},
    }
    for c in cases {
        text:=strings.concatenate({`{"parameters":[{"name":"p",`,c.parameter,`}],"entryPoints":[{"bindings":[{"name":"p","binding":{"used":1}}]}]}`},context.temp_allocator)
        _,problem:=reflected_resources(reflection(t,text),context.temp_allocator)
        testing.expectf(t,strings.contains(problem,c.expected),"%s: %s",c.expected,problem)
    }
    shared:=reflection(t,`{"parameters":[
        {"name":"a","binding":{"kind":"descriptorTableSlot","index":3},"type":{"kind":"constantBuffer"}},
        {"name":"b","binding":{"kind":"descriptorTableSlot","index":3},"type":{"kind":"samplerState"}}],
      "entryPoints":[{"bindings":[{"name":"a","binding":{"used":1}},{"name":"b","binding":{"used":1}}]}]}`)
    _,problem:=reflected_resources(shared,context.temp_allocator)
    testing.expect(t,strings.contains(problem,"share one portable binding slot"),problem)
    _,problem=reflected_resources(reflection(t,`{"parameters":[],"entryPoints":[]}`),context.temp_allocator)
    testing.expect(t,problem!="")
}

@(test)
shared_layouts_must_match_the_probe_and_assert_the_odin_mirrors :: proc(t:^testing.T) {
    vertex:=`{"parameters":[{"name":"vertices","type":{"kind":"resource","resultType":{"kind":"struct","name":"Vertex","fields":[
        {"name":"position","binding":{"kind":"uniform","offset":0,"size":12}},{"name":"normal","binding":{"kind":"uniform","offset":12,"size":4}},
        {"name":"uv","binding":{"kind":"uniform","offset":16,"size":8}},{"name":"color","binding":{"kind":"uniform","offset":24,"size":4}},
        {"name":"material","binding":{"kind":"uniform","offset":28,"size":4}},{"name":"uv1","binding":{"kind":"uniform","offset":UV1,"size":8}}],
        "sizes":[{"kind":"uniform","value":SIZE}]}}}]}`
    layouts :: proc(t:^testing.T,text,uv1,size:string) -> []Shared_Layout {
        replaced,_:=strings.replace_all(text,"UV1",uv1,context.temp_allocator)
        replaced,_=strings.replace_all(replaced,"SIZE",size,context.temp_allocator)
        return layouts_reflected(reflection(t,replaced),context.temp_allocator)
    }
    probe:=layouts(t,vertex,"32","40")
    testing.expect_value(t,len(probe),1)
    testing.expect_value(t,layouts_compare(layouts(t,vertex,"32","40"),probe,context.temp_allocator),"")
    testing.expect(t,strings.contains(layouts_compare(layouts(t,vertex,"32","48"),probe,context.temp_allocator),"Vertex"),"a struct of another size")
    testing.expect(t,strings.contains(layouts_compare(layouts(t,vertex,"36","40"),probe,context.temp_allocator),"Vertex"),"a field at another offset")
    // A stage may declare the frame without what the generation adds after
    // the part the CPU mirrors, but not without that part.
    frame :: proc(t:^testing.T,fields:string,size:int) -> []Shared_Layout {
        return layouts_reflected(reflection(t,fmt.tprintf(`{{"parameters":[{{"name":"frame","type":{{"kind":"struct","name":"Frame_Data","fields":[%s],"sizes":[{{"kind":"uniform","value":%d}}]}}}}]}}`,fields,size)),context.temp_allocator)
    }
    INDEX :: `{"name":"frame_index","binding":{"kind":"uniform","offset":0,"size":4}}`
    MOVED :: `,{"name":"moved_lights","binding":{"kind":"uniform","offset":4,"size":4}}`
    NESTED :: `,{"name":"nested","binding":{"kind":"uniform","offset":8,"size":8}}`
    whole:=frame(t,INDEX+MOVED+NESTED,16)
    testing.expect_value(t,layouts_compare(frame(t,INDEX+MOVED,8),whole,context.temp_allocator),"")
    testing.expect(t,strings.contains(layouts_compare(frame(t,INDEX,4),whole,context.temp_allocator),"Frame_Data"),"a frame without the part the CPU mirrors")
    other:=`{"parameters":[{"name":"x","type":{"kind":"struct","name":"Private_Params","fields":[],"sizes":[{"kind":"uniform","value":12}]}}]}`
    testing.expect_value(t,len(layouts_reflected(reflection(t,other),context.temp_allocator)),0)
    // The assertions name every field of the mirror; a struct the probe lacks is an error.
    b:=strings.builder_make(context.temp_allocator)
    problem:=layouts_assertions(&b,probe)
    testing.expect(t,strings.contains(problem,"Frame_Data"),problem)
    testing.expect(t,strings.contains(strings.to_string(b),"#assert(offset_of(Gpu_Vertex, uv1) == 32)\n#assert(size_of(Gpu_Vertex) == 40)\n"),strings.to_string(b))
    testing.expect(t,strings.contains(strings.to_string(b),"#assert(PROGRAM_DATA_WORDS == 32)\n"),"the limits of the catalog are pinned in the table of render")
}

@(test)
odin_table_embeds_the_backends_compiled_with_the_reflected_bindings :: proc(t:^testing.T) {
    jobs:=[]Job{
        {result={id="Fill_Comp",name="fill.comp",stage=.Compute,spv="fill.comp.spv",msl="fill.comp.metal",entry="main0",group={64,1,1},bindings={{0,"Uniform_Buffer"},{1,"Storage_Buffer"}}}},
        {result={id="Triangle_Vert",name="triangle.vert",stage=.Vertex,spv="triangle.vert.spv",msl="triangle.vert.metal",entry="main0"}},
    }
    table:=string(odin_table(jobs,{.Vulkan,.Metal},"C:/e/shaders/build","C:/e/render","render","mirai:rhi","abc123","","",context.temp_allocator))
    expected:="// Code generated by mirai shaders. DO NOT EDIT.\npackage render\n\nimport \"mirai:rhi\"\n\n"+
        "// Of the engine's shader sources these were compiled from. A shader generation\n// built for a project is loaded only while its manifest names the same one.\n"+
        "SHADERS_FINGERPRINT :: \"abc123\"\n\nShader_Id :: enum u8 {\n\tFill_Comp,\n\tTriangle_Vert,\n}\n\nwhen rhi.SHADER_FORMAT == .Msl {\n\t@(rodata)\n\tSHADERS := [Shader_Id]rhi.Shader_Code{\n"+
        "\t\t.Fill_Comp = {binary = {msl = #load(\"../shaders/build/fill.comp.metal\", string), msl_entry = \"main0\"}, name = \"fill.comp\", stage = .Compute,\n"+
        "\t\t\tthreadgroup = {64, 1, 1}, bindings = []rhi.Binding_Info{{slot = 0, kind = .Uniform_Buffer, stages = {.Compute}}, {slot = 1, kind = .Storage_Buffer, stages = {.Compute}}}},\n"+
        "\t\t.Triangle_Vert = {binary = {msl = #load(\"../shaders/build/triangle.vert.metal\", string), msl_entry = \"main0\"}, name = \"triangle.vert\", stage = .Vertex,\n"+
        "\t\t\tthreadgroup = {0, 0, 0}, bindings = []rhi.Binding_Info{}},\n\t}\n} else {\n\t@(rodata)\n\tSHADERS := [Shader_Id]rhi.Shader_Code{\n"+
        "\t\t.Fill_Comp = {binary = {spirv = #load(\"../shaders/build/fill.comp.spv\")}, name = \"fill.comp\", stage = .Compute,\n"+
        "\t\t\tthreadgroup = {64, 1, 1}, bindings = []rhi.Binding_Info{{slot = 0, kind = .Uniform_Buffer, stages = {.Compute}}, {slot = 1, kind = .Storage_Buffer, stages = {.Compute}}}},\n"+
        "\t\t.Triangle_Vert = {binary = {spirv = #load(\"../shaders/build/triangle.vert.spv\")}, name = \"triangle.vert\", stage = .Vertex,\n"+
        "\t\t\tthreadgroup = {0, 0, 0}, bindings = []rhi.Binding_Info{}},\n\t}\n}\n"
    testing.expect_value(t,table,expected)
    // One backend: the system of the other cannot build without it, and says how to have it.
    vulkan:=string(odin_table(jobs,{.Vulkan},"C:/e/shaders/build","C:/e/render","render","mirai:rhi","abc123","","",context.temp_allocator))
    testing.expect(t,strings.contains(vulkan,"when rhi.SHADER_FORMAT == .Msl {\n\t#panic(\"the shaders were generated without Metal code: run `mirai shaders --backends all`\")\n} else {\n\t@(rodata)\n"),vulkan)
    testing.expect(t,strings.contains(vulkan,"fill.comp.spv") && !strings.contains(vulkan,".metal"))
    metal:=string(odin_table(jobs,{.Metal},"C:/e/shaders/build","C:/e/render","render","mirai:rhi","abc123","","",context.temp_allocator))
    testing.expect(t,strings.has_suffix(metal,"} else {\n\t#panic(\"the shaders were generated without SPIR-V code: run `mirai shaders --backends all`\")\n}\n"),metal)
    testing.expect(t,strings.contains(metal,"fill.comp.metal") && !strings.contains(metal,".spv"))
    local:=string(odin_table(jobs[1:],{.Vulkan,.Metal},"C:/e/shaders/build/tests","C:/e/rhi","rhi","","","TEST_SHADERS","",context.temp_allocator))
    testing.expect(t,strings.has_prefix(local,"// Code generated by mirai shaders. DO NOT EDIT.\npackage rhi\n\nwhen TEST_SHADERS {\n\nShader_Id :: enum u8 {\n\tTriangle_Vert,\n}\n"),"the table of the RHI tests names its own types, behind its guard")
    testing.expect(t,strings.has_suffix(local,"\t}\n}\n}\n"),"the guard closes after the table")
    testing.expect(t,strings.contains(local,"SHADERS := [Shader_Id]Shader_Code{") && strings.contains(local,"bindings = []Binding_Info{}") && strings.contains(local,"#load(\"../shaders/build/tests/triangle.vert.spv\")"))
    testing.expect(t,!strings.contains(local,"SHADERS_FINGERPRINT"))
    // Packed: the code is one stream per backend and each stage, of SHADERS and then of PROGRAM_SHADERS, its size in it.
    packed:=string(odin_table(jobs,{.Vulkan,.Metal},"C:/e/shaders/build","C:/e/render","render","mirai:rhi","abc123","","",context.temp_allocator,jobs[1:],true,{.Vulkan={10,20,30},.Metal={11,21,31}}))
    testing.expect(t,strings.contains(packed,"} else {\n\t@(rodata)\n\tSHADERS_PACKED := #load(\"../shaders/build/shaders.spv.lz\")\n\t@(rodata)\n\tSHADERS := [Shader_Id]Embedded_Shader{\n\t\t.Fill_Comp = {size = 10, code = {name = \"fill.comp\", stage = .Compute,\n"+
        "\t\t\tthreadgroup = {64, 1, 1}, bindings = []rhi.Binding_Info{{slot = 0, kind = .Uniform_Buffer, stages = {.Compute}}, {slot = 1, kind = .Storage_Buffer, stages = {.Compute}}}}},\n"),packed)
    testing.expect(t,strings.contains(packed,"\tPROGRAM_SHADERS := [1]Embedded_Shader{\n\t\t{size = 30, code = {name = \"triangle.vert\", stage = .Vertex,\n\t\t\tthreadgroup = {0, 0, 0}, bindings = []rhi.Binding_Info{}}},\n\t}\n}\n"),packed)
    testing.expect(t,strings.contains(packed,"SHADERS_PACKED := #load(\"../shaders/build/shaders.metal.lz\")") && strings.contains(packed,"{size = 21, code = {binary = {msl_entry = \"main0\"}, name = \"triangle.vert\""),packed)
    testing.expect(t,!strings.contains(packed,".spv\")") && !strings.contains(packed,".metal\", string)"),"no stage loads its own code")
}
