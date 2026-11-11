package shaders

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"

// The programs of shaders/materials: a source that declares one in its first
// line (//! mirai <domain> <name>) gives one.
@(private)
builtin_programs :: proc() -> int {
    count:=0
    folder:=path_join(path_clean(ENGINE_ROOT,context.temp_allocator),"shaders/materials",allocator=context.temp_allocator)
    for path in listing_read(folder,true,context.temp_allocator).files {
        data,_:=os.read_entire_file(path,context.temp_allocator)
        if strings.has_prefix(string(data),"//! mirai ") {count+=1}
    }
    return count
}

// The Surface programs of shaders/materials, by name.
@(private)
builtin_surface_programs :: proc() -> []string {
    names:=make([dynamic]string,context.temp_allocator)
    folder:=path_join(path_clean(ENGINE_ROOT,context.temp_allocator),"shaders/materials",allocator=context.temp_allocator)
    for path in listing_read(folder,true,context.temp_allocator).files {
        data,_:=os.read_entire_file(path,context.temp_allocator)
        if said:=program_directives(string(data));said.domain=="surface" && said.name!="" {append(&names,said.name)}
    }
    return names[:]
}

// A project folder with shaders/, and what generating its catalog needs.
@(private="file")
Programs_Fixture :: struct {
    project,output,cache,slangc,version:string,
    runner:Runner,
}

@(private="file")
programs_fixture :: proc(t:^testing.T,f:^Programs_Fixture) -> bool {
    root:=path_clean(ENGINE_ROOT,context.temp_allocator)
    slangc,found:=tool_find(root,.Slangc,context.temp_allocator)
    if !found {log.warn("slangc is not installed: run `mirai setup slang`");return false}
    f.slangc=slangc
    version,ran:=tool_run(&f.runner,{slangc,"-version"},context.temp_allocator)
    testing.expect(t,ran,version)
    f.version=strings.trim_space(version)
    f.project=base.test_folder(t,"shaders")
    if f.project=="" {return false}
    f.output=path_join(f.project,"out",allocator=context.temp_allocator)
    f.cache=path_join(f.project,".mirai/shader-cache/reflection",allocator=context.temp_allocator)
    os.make_directory_all(path_join(f.project,"shaders",allocator=context.temp_allocator))
    f.runner.runs=0
    return true
}

@(private="file")
programs_of :: proc(f:^Programs_Fixture) -> (catalog:Catalog,problem:string) {
    catalog,problem=programs_generate(&f.runner,path_clean(ENGINE_ROOT,context.temp_allocator),f.project,f.output,f.slangc,f.version,f.cache,allocator=context.temp_allocator)
    // A program left out is the problem of these tests; the others are published.
    if problem=="" && len(catalog.refused)>0 {problem=strings.join(catalog.refused," | ",context.temp_allocator)}
    return
}

@(private="file")
program_named :: proc(catalog:Catalog,name:string) -> (Program,bool) {
    for program in catalog.programs {if program.name==name {return program,true}}
    return {},false
}

@(test)
programs_reflect_typed_parameters_defaults_and_portable_includes :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    fixture_write(t,f.project,"shaders/helpers.slang","float3 sample_color(float x) {return float3(x,x,x);}\n")
    fixture_write(t,f.project,"shaders/typed.slang",`//! mirai surface Fixture
//! parameter tint {"default":[1,0.5,0.25],"min":0,"max":10,"color":true,"group":"Look"}
//! parameter index {"default":-2,"min":-10,"max":10}
//! parameter map {"kind":"texture","srgb":true}
#include "helpers.slang"
namespace Fixture {
 struct Parameters {float3 tint;int index;bool enabled;uint map;}
 Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {
  Mirai_Surface s=mirai_surface_default(ctx);s.base_color=p.tint*sample_color(float(p.index));return s;
 }
}
`)
    catalog,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    fixture,found:=program_named(catalog,"Fixture")
    testing.expect(t,found,"the program of the project is in the catalog")
    if !found {return}
    testing.expect_value(t,fixture.domain,"surface")
    testing.expect_value(t,fixture.source,"project/typed.slang")
    testing.expect_value(t,len(fixture.parameters),4)
    tint,index,enabled,texture:=fixture.parameters[0],fixture.parameters[1],fixture.parameters[2],fixture.parameters[3]
    testing.expect(t,tint.name=="tint" && tint.kind=="float32" && tint.components==3 && tint.offset==0 && tint.color && tint.default_list)
    testing.expect(t,tint.group=="Look" && index.group=="","a parameter keeps the group it names")
    testing.expect_value(t,tint.defaults[1],Default(Number{is_float=true,float=0.5}))
    testing.expect_value(t,tint.defaults[0],Default(Number{integer=1}))
    testing.expect_value(t,index.offset,12)
    testing.expect_value(t,index.kind,"int32")
    testing.expect_value(t,index.defaults[0],Default(Number{integer=-2}))
    testing.expect_value(t,index.min,Number{integer=-10})
    testing.expect_value(t,enabled.defaults[0],Default(false))
    testing.expect_value(t,enabled.min,Number{is_float=true,float=-1e20})
    testing.expect(t,texture.kind=="texture" && texture.srgb && !texture.normal)
    testing.expect_value(t,texture.defaults[0],Default(""))
    // The built-in programs come first, in the order of their files.
    testing.expect_value(t,catalog.programs[0].name,"ColorGrade")
    testing.expect_value(t,catalog.programs[0].id,1)
    testing.expect_value(t,fixture.id,len(catalog.programs))

    own_bytes,_:=os.read_entire_file(path_join(f.output,"include",SURFACE_FOLDER,"Fixture",SURFACE_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    own:=string(own_bytes)
    testing.expect(t,!strings.contains(own,f.project),"the include of a program does not name the folder of the project")
    testing.expect(t,strings.contains(own,"#include \"programs/project/typed.slang\""))
    testing.expect(t,strings.contains(own,"    p.tint=float3(packed[0].x,packed[0].y,packed[0].z);\n    p.index=asint(packed[0].w);\n    p.enabled=(asuint(packed[1].x)!=0);\n    p.map=asuint(packed[1].y);\n"),own)
    testing.expect(t,strings.contains(own,"value=Fixture::evaluate(ctx,mirai_load_Fixture(packed));return true;"),own)
    testing.expect(t,!strings.contains(own,"screen_blur") && !strings.contains(own,"color_grade"),"the include of a program has that program alone")
    dispatch_bytes,_:=os.read_entire_file(path_join(f.output,"include",SURFACE_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    dispatch:=string(dispatch_bytes)
    testing.expect(t,!strings.contains(dispatch,"Fixture") && strings.contains(dispatch,"{return false;}"),"the include of the generation evaluates no program")
    post_bytes,_:=os.read_entire_file(path_join(f.output,"include",POSTPROCESS_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    post:=string(post_bytes)
    testing.expect(t,strings.contains(post,"programs/builtin/color_grade.slang") && strings.contains(post,"    case 1: return ColorGrade::evaluate(ctx,mirai_load_ColorGrade(packed));"),post)
    testing.expect(t,!strings.contains(post,"Fixture") && !strings.contains(post,"ui_shine.slang") && !strings.contains(post,"mirai_evaluate_program"))
    testing.expect(t,os.is_file(path_join(f.output,"include/programs/project/helpers.slang",allocator=context.temp_allocator)),"the generation carries the sources it includes")
    testing.expect(t,os.is_file(path_join(f.output,"include/programs/builtin/color_grade.slang",allocator=context.temp_allocator)))
    stored,_:=os.read_entire_file(path_join(f.output,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(stored),"\"default\": [\n            1,\n            0.5,\n            0.25\n          ],\n          \"min\": 0,\n          \"max\": 10,"),"the catalog keeps numbers as the source wrote them")
    testing.expect(t,strings.contains(string(stored),"\"min\": -1e+20,\n          \"max\": 1e+20,"))

    first:=catalog.fingerprint
    fixture_write(t,f.project,"shaders/helpers.slang","float3 sample_color(float x) {return float3(2*x,x,x);}\n")
    catalog,problem=programs_of(&f)
    testing.expect_value(t,problem,"")
    testing.expect(t,catalog.fingerprint!=first,"a source a program includes changes the identity of the catalog")
}

@(test)
programs_reject_a_default_of_another_type_or_out_of_range :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    Case :: struct {declaration,metadata,expected:string}
    cases:=[]Case{
        {"bool flag",`{"default":1}`,"invalid typed default"},
        {"uint flag",`{"default":-1}`,"invalid typed default"},
        {"uint flag",`{"default":1.5}`,"invalid typed default"},
        {"float flag",`{"default":2,"min":0,"max":1}`,"invalid typed default"},
        {"float flag",`{"default":"name"}`,"invalid typed default"},
        {"float3 flag",`{"default":[1,2]}`,"default must have 3 components"},
        {"float3 flag",`{"default":1}`,"default must have 3 components"},
        {"float flag",`{"kind":"texture"}`,"texture parameters must be uint"},
        {"float2 flag",`{"color":true}`,"a color is three floats"},
        {"float flag",`{"group":""}`,"group must be a name"},
        {"float flag",`{"group":3}`,"group must be a name"},
        {"float flag",`{"default":}`,"invalid parameter metadata"},
        {"float4x4 flag",`{}`,"only float/int/uint/bool scalars and vectors1..4 are supported"},
    }
    for c in cases {
        fixture_write(t,f.project,"shaders/bad.slang",fmt.tprintf("//! mirai surface Bad\n//! parameter flag %s\nnamespace Bad {{struct Parameters {{%s;}}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {{return mirai_surface_default(ctx);}}}}\n",c.metadata,c.declaration))
        _,problem:=programs_of(&f)
        testing.expectf(t,strings.contains(problem,c.expected),"%s %s: %s",c.declaration,c.metadata,problem)
    }
}

@(test)
programs_reject_a_name_declared_twice_or_reserved :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    text:="//! mirai surface Duplicate\nnamespace Duplicate {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n"
    fixture_write(t,f.project,"shaders/a.slang",text)
    fixture_write(t,f.project,"shaders/b.slang",text)
    _,problem:=programs_of(&f)
    testing.expect(t,strings.contains(problem,"duplicate/reserved program name Duplicate"),problem)
    os.remove(path_join(f.project,"shaders/b.slang",allocator=context.temp_allocator))
    fixture_write(t,f.project,"shaders/a.slang","//! mirai postprocess pbr\nnamespace pbr {struct Parameters {float amount;};}\n")
    _,problem=programs_of(&f)
    testing.expect(t,strings.contains(problem,"duplicate/reserved program name pbr"),problem)
    fixture_write(t,f.project,"shaders/a.slang","//! mirai postprocess ColorGrade\nnamespace ColorGrade {struct Parameters {float amount;};}\n")
    _,problem=programs_of(&f)
    testing.expect(t,strings.contains(problem,"duplicate/reserved program name ColorGrade"),"a project cannot take the name of a built-in program")
}

@(test)
programs_take_parameter_ranges_within_the_bounds_of_the_loader :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    declare :: proc(t:^testing.T,f:^Programs_Fixture,lower,upper:string) {
        fixture_write(t,f.project,"shaders/range.slang",fmt.tprintf("//! mirai surface Range\n//! parameter amount {{\"min\":%s,\"max\":%s}}\nnamespace Range {{struct Parameters {{float amount;}}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {{return mirai_surface_default(ctx);}}}}\n",lower,upper))
    }
    declare(t,&f,"-1e+30","1e+30")
    catalog,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    program,found:=program_named(catalog,"Range")
    testing.expect(t,found)
    if !found {return}
    testing.expect_value(t,program.parameters[0].min,Number{is_float=true,float=-1e30})
    for bounds in ([][2]string{{"-1e+31","1e+30"},{"-1e+30","1e+31"},{"false","1"},{"-1","true"},{"2","1"},{"\"0\"","1"}}) {
        declare(t,&f,bounds[0],bounds[1])
        _,problem=programs_of(&f)
        testing.expectf(t,strings.contains(problem,"invalid parameter range"),"%v: %s",bounds,problem)
    }
}

@(test)
programs_reuse_a_warm_reflection_and_reflect_again_only_what_changed :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    fixture_write(t,f.project,"shaders/helper.slang","float helper() {return 1;}\n")
    fixture_write(t,f.project,"shaders/helper.inc","#include \"parameters.h\"\n")
    fixture_write(t,f.project,"shaders/parameters.h","#include \"helper.slang\"\n")
    fixture_write(t,f.project,"shaders/fixture.slang","//! mirai surface Cached\n#include \"helper.inc\"\nnamespace Cached {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n")
    cold,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,f.runner.runs,reflections(cold))
    f.runner.runs=0
    warm,_:=programs_of(&f)
    testing.expect_value(t,f.runner.runs,0)
    testing.expect_value(t,warm.fingerprint,cold.fingerprint)
    cached,found:=program_named(warm,"Cached")
    testing.expect(t,found && cached.size==16 && len(cached.parameters)==1 && cached.parameters[0].kind=="float32","a cached reflection gives the same parameters")
    // The same program in another project, or another checkout, is the same entry.
    elsewhere:=base.test_folder(t,"shaders")
    if elsewhere=="" {return}
    for path in listing_read(path_join(f.project,"shaders",allocator=context.temp_allocator),true,context.temp_allocator).files {
        relative,_:=path_relative(path,f.project)
        data,_:=os.read_entire_file(path,context.temp_allocator)
        fixture_write(t,elsewhere,relative,string(data))
    }
    _,problem=programs_generate(&f.runner,path_clean(ENGINE_ROOT,context.temp_allocator),elsewhere,path_join(elsewhere,"out",allocator=context.temp_allocator),f.slangc,f.version,f.cache,allocator=context.temp_allocator)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,f.runner.runs,0)
    // A source no program includes changes the catalog but reflects nothing.
    fixture_write(t,f.project,"shaders/unrelated.slang","float unrelated() {return 2;}\n")
    _,problem=programs_of(&f)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,f.runner.runs,0)
    fixture_write(t,f.project,"shaders/helper.slang","float helper() {return 2;}\n")
    _,problem=programs_of(&f)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,f.runner.runs,2)
    // A cache file that is not what its hash says is reflected again.
    f.runner.runs=0
    entries,_:=os.read_all_directory_by_path(f.cache,context.temp_allocator)
    for entry in entries {
        data,_:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        tampered,_:=strings.replace_all(string(data),"\"offset\": 0","\"offset\": 4",context.temp_allocator)
        write_file(entry.fullpath,transmute([]u8)tampered)
    }
    recovered,recover_problem:=programs_of(&f)
    testing.expect_value(t,recover_problem,"")
    testing.expect_value(t,f.runner.runs,reflections(recovered,probes=false))
    again,_:=program_named(recovered,"Cached")
    testing.expect_value(t,again.parameters[0].offset,0)
}

@(test)
parameter_metadata_publishes_a_new_catalog_without_reflecting_or_changing_dispatch :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    original:="//! mirai surface Metadata\n//! parameter tint {\"default\":[1,0.5,0.25],\"min\":0,\"max\":1,\"color\":false}\n//! parameter map {\"kind\":\"texture\",\"srgb\":false,\"normal\":false}\nnamespace Metadata {struct Parameters {float3 tint;uint map;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n"
    fixture_write(t,f.project,"shaders/metadata.slang",original)
    first,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    if problem!="" {return}
    dispatch:=path_join(f.output,"include",SURFACE_FOLDER,"Metadata",SURFACE_INCLUDE,allocator=context.temp_allocator)
    before,_:=os.read_entire_file(dispatch,context.temp_allocator)
    changed,_:=strings.replace_all(original,"[1,0.5,0.25]","[0.25,0.5,1]",context.temp_allocator)
    for pair in ([][2]string{{"\"max\":1","\"max\":2"},{"\"color\":false","\"color\":true"},{"\"srgb\":false","\"srgb\":true"},{"\"normal\":false","\"normal\":true"}}) {
        changed,_=strings.replace_all(changed,pair[0],pair[1],context.temp_allocator)
    }
    fixture_write(t,f.project,"shaders/metadata.slang",changed)
    f.runner.runs=0
    next,next_problem:=programs_of(&f)
    testing.expect_value(t,next_problem,"")
    testing.expect_value(t,f.runner.runs,0)
    testing.expect(t,first.fingerprint!=next.fingerprint,"metadata is part of catalog identity")
    after,_:=os.read_entire_file(dispatch,context.temp_allocator)
    testing.expect_value(t,string(after),string(before))
    program,found:=program_named(next,"Metadata")
    testing.expect(t,found)
    if found {
        testing.expect(t,program.parameters[0].color && program.parameters[0].max==Number{integer=2})
        testing.expect_value(t,program.parameters[0].defaults[0],Default(Number{is_float=true,float=0.25}))
        testing.expect(t,program.parameters[1].srgb && program.parameters[1].normal,"texture interpretation is refreshed")
    }
    invalid,_:=strings.replace_all(changed,"\"max\":2","\"max\":0",context.temp_allocator)
    fixture_write(t,f.project,"shaders/metadata.slang",invalid)
    f.runner.runs=0
    _,problem=programs_of(&f)
    testing.expect(t,strings.contains(problem,"invalid typed default"),"a reused layout still validates metadata")
    testing.expect_value(t,f.runner.runs,0)
}

@(test)
programs_without_a_project_are_the_built_in_ones :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    root:=path_clean(ENGINE_ROOT,context.temp_allocator)
    catalog,problem:=programs_generate(&f.runner,root,"",f.output,f.slangc,f.version,f.cache,allocator=context.temp_allocator)
    testing.expect_value(t,problem,"")
    testing.expect_value(t,len(catalog.programs),builtin_programs())
    domains:=make(map[string]string,context.temp_allocator)
    for program in catalog.programs {domains[program.name]=program.domain}
    testing.expect(t,domains["ColorGrade"]=="postprocess" && domains["Ui_Shine"]=="ui","each built-in program keeps the domain its source declares")
    // What the engine has committed is this catalog, byte for byte.
    committed,_:=os.read_entire_file(path_join(root,"shaders/build/catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    generated,_:=os.read_entire_file(path_join(f.output,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    if f.version==SLANG_VERSION {testing.expect(t,string(lf_bytes(committed))==string(generated),"catalog.json of the engine is reproduced")}
    testing.expect(t,!os.exists(path_join(f.output,"include/programs/project",allocator=context.temp_allocator)))
}

@(test)
program_declaration_and_metadata_lines_are_recognized :: proc(t:^testing.T) {
    said:=program_directives("// header\n//!   mirai   postprocess   Bloom_2  \nnamespace Bloom_2 {}\n//! mirai ui Other\n")
    testing.expect(t,said.domain=="postprocess" && said.name=="Bloom_2")
    said=program_directives("//! mirai ui Wipe\n")
    testing.expect(t,said.domain=="ui" && said.name=="Wipe")
    for text in ([]string{"//! mirai volume Fog\n"," //! mirai surface Indented\n","//! mirai surface 9lives\n","//! mirai surface Two Words\n","//!mirai surface Tight\n","// mirai surface Plain\n"}) {
        testing.expectf(t,program_directives(text).name=="","%q declares no program",text)
    }
    // One pass reads every directive: metadata, resources and stages in order, and what it says.
    said=program_directives("//! mirai vfx Swarm\n//! parameter speed {\"default\":1}\n//! resource ground grid\n  //! resource indented surface\n//! stage settle over ground\n  //! moves\n//! births\n")
    testing.expect(t,said.name=="Swarm" && len(said.metadata)==1 && said.metadata[0][0]=="speed" && said.metadata[0][1]=="{\"default\":1}")
    testing.expect(t,len(said.resources)==1 && said.resources[0][2]=="ground" && len(said.stages)==1 && said.stages[0][2]=="settle")
    testing.expect(t,said.moves && said.births && !said.prepare && said.vertex==nil)
    said=program_directives("//! mirai surface Sway\n//! vertex animated reach 0.5\n")
    testing.expect(t,len(said.vertex)==5 && said.vertex[2]=="animated" && said.vertex[4]=="0.5")
    field,value,found:=parameter_metadata("//! parameter tint {\"default\":[1,1,1]}  ")
    testing.expect(t,found && field=="tint" && value=="{\"default\":[1,1,1]}")
    for line in ([]string{"//! parameter tint","//! parameter tint [1]","//!parameter tint {}","// parameter tint {}","//! parameter {}"}) {
        _,_,found=parameter_metadata(line)
        testing.expectf(t,!found,"%q is no metadata",line)
    }
}

// The reflections a cold catalog runs: one for the Parameters of each
// program, and one more for the Attributes of a Vfx one.
@(private="file")
// The compilations of a cold reflection: a Surface program has its alpha
// probed too (alpha_probe), unless the cache has it.
reflections :: proc(catalog:Catalog,probes:=true) -> (runs:int) {
    for program in catalog.programs {runs+=program.domain=="vfx" || probes && program.domain=="surface"?2:1}
    return
}

// A Surface program is in the coverage include when its alpha is not the
// constant of the default material, whatever it reads it from; its alpha
// alone, while its include has the whole program.
@(test)
surface_coverage_holds_the_programs_whose_alpha_is_not_the_default :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    Case :: struct {name,body:string,coverage:bool}
    cases:=[]Case{
        {"Untouched","s.base_color=p.tint*mirai_sample_texture(ctx,p.map,ctx.uv0,ctx.lod).rgb;",false},
        {"Folded","float k=p.tint.x>0.5?1.0:1.0;s.base_color*=k;",false},
        {"Mapped","s.alpha=mirai_sample_texture(ctx,p.map,ctx.uv0,ctx.lod).a;",true},
        {"Mixed","Mirai_Surface hole=s;hole.alpha=0.0;s=mirai_surface_mix(s,hole,p.tint.y);",true},
        {"Constant","s.alpha=0.25;",true},
    }
    for c in cases {
        fixture_write(t,f.project,fmt.tprintf("shaders/%s.slang",c.name),fmt.tprintf("//! mirai surface %s\nnamespace %s {{struct Parameters {{float3 tint;uint map;}}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {{Mirai_Surface s=mirai_surface_default(ctx);%sreturn s;}}}}\n",c.name,c.name,c.body))
    }
    catalog,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    coverage_bytes,_:=os.read_entire_file(path_join(f.output,"include",SURFACE_COVERAGE_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    coverage:=string(coverage_bytes)
    for c in cases {
        program,found:=program_named(catalog,c.name)
        testing.expectf(t,found && program.coverage==c.coverage,"%s: coverage %v",c.name,program.coverage)
        listed:=strings.contains(coverage,fmt.tprintf("alpha=%s::evaluate(",c.name))
        testing.expectf(t,listed==c.coverage,"%s is in the coverage include: %v",c.name,listed)
        own,_:=os.read_entire_file(path_join(f.output,"include",SURFACE_FOLDER,c.name,SURFACE_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
        testing.expectf(t,strings.contains(string(own),fmt.tprintf("#ifndef MIRAI_PROGRAM_%s",c.name)),"%s: one source for both includes of a stage",c.name)
    }
    stored,_:=os.read_entire_file(path_join(f.output,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(stored),"\"coverage\": true"))
    // The cache keeps what the probe found.
    f.runner.runs=0
    warm,_:=programs_of(&f)
    testing.expect_value(t,f.runner.runs,0)
    mapped,_:=program_named(warm,"Mapped")
    testing.expect(t,mapped.coverage)
}

// The stages that trace include a program with coverage for its alpha alone:
// their fingerprint follows that alpha compiled, not the text of the
// program, so an edit that keeps the alpha changes only the fingerprint of
// the stages of the program. Every argument of a texture read is the alpha.
@(test)
the_stages_that_trace_follow_the_alpha_of_a_program_and_not_its_text :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    prints :: proc(t:^testing.T,f:^Programs_Fixture,body:string) -> (tracing,own:string) {
        fixture_write(t,f.project,"shaders/holes.slang",fmt.tprintf("//! mirai surface Holes\nnamespace Holes {{struct Parameters {{float3 tint;uint map;}}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {{Mirai_Surface s=mirai_surface_default(ctx);%sreturn s;}}}}\n",body))
        _,problem:=programs_of(f)
        testing.expect_value(t,problem,"")
        include:=path_join(f.output,"include",allocator=context.temp_allocator)
        tracing=fingerprint(path_join(include,SURFACE_COVERAGE_INCLUDE,allocator=context.temp_allocator),{include},nil,nil,context.temp_allocator)
        own=fingerprint(path_join(include,SURFACE_FOLDER,"Holes",SURFACE_INCLUDE,allocator=context.temp_allocator),{include},nil,nil,context.temp_allocator)
        return
    }
    tracing,own:=prints(t,&f,"s.alpha=mirai_sample_texture(ctx,p.map,ctx.uv0,ctx.lod).a;s.base_color=p.tint;")
    painted,repainted:=prints(t,&f,"s.alpha=mirai_sample_texture(ctx,p.map,ctx.uv0,ctx.lod).a;s.base_color=p.tint*0.5;")
    testing.expect_value(t,painted,tracing)
    testing.expect(t,repainted!=own,"another color is another program for its own stages")
    finer,_:=prints(t,&f,"s.alpha=mirai_sample_texture(ctx,p.map,ctx.uv0,ctx.lod+1.0).a;s.base_color=p.tint*0.5;")
    testing.expect(t,finer!=tracing,"another level of its texture is another alpha")
}

@(test)
vfx_programs_load_their_attributes_and_dispatch_three_entries :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    fixture_write(t,f.project,"shaders/drift.slang","//! mirai vfx Drift\n//! parameter speed {\"default\":2,\"min\":0,\"max\":10}\nnamespace Drift {struct Parameters {float speed;}; struct Attributes {float3 home;uint hits;};\nvoid initialize(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {a.home=particle.position;}\nvoid update(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {a.hits+=1u;}\nvoid render(Mirai_Vfx_Context ctx,Parameters p,Mirai_Vfx_Particle particle,Attributes a,inout Mirai_Vfx_Visual visual) {}}\n")
    catalog,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    drift,found:=program_named(catalog,"Drift")
    testing.expect(t,found && drift.domain=="vfx" && drift.attributes==16 && len(drift.parameters)==1)
    include,_:=os.read_entire_file(path_join(f.output,"include",VFX_FOLDER,"Drift",VFX_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    text:=string(include)
    testing.expect(t,strings.contains(text,"Drift::Attributes mirai_attributes_load_Drift(uint at)"))
    testing.expect(t,strings.contains(text,"particle_data.Store(at+12u,asuint(a.hits));"))
    testing.expect(t,strings.contains(text,"Drift::update(ctx,mirai_load_Drift(packed),value,a)"))
    testing.expect(t,strings.contains(text,"bool mirai_vfx_render(uint id"))
    // Resources it reads: their indices in its namespace, in the order it declares them, and the catalog lists them.
    fixture_write(t,f.project,"shaders/drift.slang","//! mirai vfx Drift\n//! resource body surface\n//! resource hits channel\nnamespace Drift {struct Parameters {float speed;}; struct Attributes {uint hits;};\nvoid initialize(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {a.hits=body+hits;}\nvoid update(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid render(Mirai_Vfx_Context ctx,Parameters p,Mirai_Vfx_Particle particle,Attributes a,inout Mirai_Vfx_Visual visual) {}}\n")
    catalog,problem=programs_of(&f)
    testing.expect_value(t,problem,"")
    drift,found=program_named(catalog,"Drift")
    testing.expect(t,found && len(drift.resources)==2 && drift.resources[0]==Resource{"body","surface",false,0} && drift.resources[1]==Resource{"hits","channel",false,0})
    include,_=os.read_entire_file(path_join(f.output,"include",VFX_FOLDER,"Drift",VFX_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(include),"namespace Drift {static const uint body=0u;static const uint hits=1u;}"))
    written,_:=os.read_entire_file(path_join(f.output,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    listed:=0
    if root,parsed:=json.parse(written,allocator=context.temp_allocator);parsed==.None {
        for entry in root.(json.Object)["programs"].(json.Array) {
            program:=entry.(json.Object)
            if program["name"].(json.String)!="Drift" {continue}
            for resource in program["resources"].(json.Array) {
                listed+=1
                kinds:=[2]string{"surface","channel"}
                testing.expect(t,listed<=2 && resource.(json.Object)["kind"].(json.String)==kinds[min(listed,2)-1])
            }
        }
    }
    testing.expect_value(t,listed,2)
    // A program that moves its particles, reads another emitter and writes a cleared grid in a stage over its particles.
    fixture_write(t,f.project,"shaders/drift.slang","//! mirai vfx Drift\n//! moves\n//! resource leader emitter\n//! resource counts grid cleared\n//! stage count over particles writes counts\nnamespace Drift {struct Parameters {float speed;}; struct Attributes {uint hits;};\nvoid initialize(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid count(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {mirai_vfx_grid_word_add(ctx,counts,int3(0),0u,1u);a.hits=mirai_vfx_emitter_alive(ctx,leader);}\nvoid update(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid render(Mirai_Vfx_Context ctx,Parameters p,Mirai_Vfx_Particle particle,Attributes a,inout Mirai_Vfx_Visual visual) {}}\n")
    catalog,problem=programs_of(&f)
    testing.expect_value(t,problem,"")
    drift,found=program_named(catalog,"Drift")
    testing.expect(t,found && drift.moves && len(drift.resources)==2 && drift.resources[0]==Resource{"leader","emitter",false,0} && drift.resources[1]==Resource{"counts","grid",true,0})
    testing.expect(t,found && len(drift.stages)==1 && len(drift.stages[0].writes)==1 && drift.stages[0].writes[0]=="counts")
    // A stage writes only grids the program declares.
    fixture_write(t,f.project,"shaders/drift.slang","//! mirai vfx Drift\n//! resource leader emitter\n//! stage count over particles writes leader\nnamespace Drift {struct Parameters {float speed;}; struct Attributes {uint hits;};\nvoid initialize(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid count(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid update(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid render(Mirai_Vfx_Context ctx,Parameters p,Mirai_Vfx_Particle particle,Attributes a,inout Mirai_Vfx_Visual visual) {}}\n")
    _,problem=programs_of(&f)
    testing.expectf(t,strings.contains(problem,"writes grids the program declares"),"%s",problem)
    // A kind it does not know is refused, naming those there are.
    fixture_write(t,f.project,"shaders/drift.slang","//! mirai vfx Drift\n//! resource body volume\nnamespace Drift {struct Parameters {float speed;}; struct Attributes {uint hits;};\nvoid initialize(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid update(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid render(Mirai_Vfx_Context ctx,Parameters p,Mirai_Vfx_Particle particle,Attributes a,inout Mirai_Vfx_Visual visual) {}}\n")
    _,problem=programs_of(&f)
    testing.expectf(t,strings.contains(problem,"Drift.body: a resource is of kind") && strings.contains(problem,"surface"),"%s",problem)
    // Its stages, over particles or a grid it reads, go to the catalog and to the dispatchers of their kind.
    stages_source:="//! mirai vfx Drift\n//! resource field grid\n//! stage push over particles iterations 2\n//! stage relax over field iterations 3\nnamespace Drift {struct Parameters {float speed;}; struct Attributes {uint hits;};\nvoid initialize(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid push(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid relax(Mirai_Vfx_Cell cell,Parameters p) {}\nvoid update(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid render(Mirai_Vfx_Context ctx,Parameters p,Mirai_Vfx_Particle particle,Attributes a,inout Mirai_Vfx_Visual visual) {}}\n"
    fixture_write(t,f.project,"shaders/drift.slang",stages_source)
    catalog,problem=programs_of(&f)
    testing.expect_value(t,problem,"")
    drift,found=program_named(catalog,"Drift")
    testing.expect(t,found && len(drift.stages)==2)
    if found && len(drift.stages)==2 {
        testing.expect(t,drift.stages[0].name=="push" && drift.stages[0].over=="particles" && drift.stages[0].iterations==2)
        testing.expect(t,drift.stages[1].name=="relax" && drift.stages[1].over=="field" && drift.stages[1].iterations==3)
    }
    include,_=os.read_entire_file(path_join(f.output,"include",VFX_FOLDER,"Drift",VFX_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(include),"Drift::push(ctx,mirai_load_Drift(packed),value,a)"))
    testing.expect(t,strings.contains(string(include),"case 1: Drift::relax(cell,mirai_load_Drift(packed));return true;"))
    // A stage over what is not a grid, no iterations, neighbors and a name of the contract are refused.
    refused:=[4][2]string{
        {"//! stage relax over hits","a stage goes over particles or over a grid"},
        {"//! stage push over particles iterations 0","iterations is a number"},
        {"//! stage push over particles neighbors 1","declare a grid resource"},
        {"//! stage update over particles","initialize, update and render are not stages"},
    }
    for case_ in refused {
        fixture_write(t,f.project,"shaders/drift.slang",strings.concatenate({"//! mirai vfx Drift\n//! resource field grid\n",case_[0],"\n",stages_source[len("//! mirai vfx Drift\n//! resource field grid\n//! stage push over particles iterations 2\n//! stage relax over field iterations 3\n"):]},context.temp_allocator))
        _,problem=programs_of(&f)
        testing.expectf(t,strings.contains(problem,case_[1]),"%s gives %q",case_[0],problem)
    }
    // Attributes past what a particle holds are refused, saying how much it holds.
    many:=strings.builder_make(context.temp_allocator)
    for i in 0..<ATTRIBUTE_BYTES/16 {fmt.sbprintf(&many,"float4 a%d;",i)}
    fixture_write(t,f.project,"shaders/drift.slang",strings.concatenate({"//! mirai vfx Drift\nnamespace Drift {struct Parameters {float speed;}; struct Attributes {",strings.to_string(many),"float c;};\nvoid initialize(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid update(Mirai_Vfx_Context ctx,Parameters p,inout Mirai_Vfx_Particle particle,inout Attributes a) {}\nvoid render(Mirai_Vfx_Context ctx,Parameters p,Mirai_Vfx_Particle particle,Attributes a,inout Mirai_Vfx_Visual visual) {}}\n"},context.temp_allocator))
    _,problem=programs_of(&f)
    testing.expectf(t,strings.contains(problem,fmt.tprintf("a particle holds %d",ATTRIBUTE_BYTES)),"%s",problem)
}

@(test)
ui_programs_dispatch_in_an_include_of_their_own :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    fixture_write(t,f.project,"shaders/pulse.slang",`//! mirai ui Pulse
//! parameter rate {"default":2,"min":0,"max":10}
namespace Pulse {
struct Parameters {float rate;float strength;float2 center;};
float4 evaluate(Mirai_Ui_Context ctx,Parameters p) {
 float glow=0.5+0.5*sin(ctx.time*p.rate+length(ctx.uv-p.center)*ctx.size.x);
 return float4(ctx.color.rgb*lerp(1.0,glow,p.strength),ctx.color.a);
}
}
`)
    catalog,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    pulse,found:=program_named(catalog,"Pulse")
    testing.expect(t,found && pulse.domain=="ui" && pulse.size==16 && len(pulse.parameters)==3)
    if !found {return}
    testing.expect(t,pulse.parameters[2].name=="center" && pulse.parameters[2].offset==8)
    for name in ([]string{"Ui_Radial_Wipe","Ui_Dissolve","Ui_Shine","Ui_Gradient_Sweep"}) {
        builtin,listed:=program_named(catalog,name)
        testing.expectf(t,listed && builtin.domain=="ui" && builtin.size<=16,"%s is a built-in ui program of at most four floats",name)
    }
    read :: proc(f:^Programs_Fixture,name:string) -> string {
        bytes,_:=os.read_entire_file(path_join(f.output,"include",name,allocator=context.temp_allocator),context.temp_allocator)
        return string(bytes)
    }
    ui:=read(&f,UI_INCLUDE)
    testing.expect(t,strings.contains(ui,"#include \"programs/project/pulse.slang\"") && strings.contains(ui,"#include \"programs/builtin/ui_radial_wipe.slang\""),ui)
    testing.expect(t,strings.contains(ui,"    p.rate=packed[0].x;\n    p.strength=packed[0].y;\n    p.center=float2(packed[0].z,packed[0].w);\n"),ui)
    testing.expect(t,strings.contains(ui,fmt.tprintf("    case %d: return Pulse::evaluate(ctx,mirai_load_Pulse(packed));",pulse.id)))
    testing.expect(t,strings.contains(ui,"float4 mirai_evaluate_ui(uint id,float4 packed[16],Mirai_Ui_Context ctx) {switch(id) {") && strings.contains(ui,"default:return ctx.color;}}"),ui)
    testing.expect(t,!strings.contains(ui,"screen_blur.slang") && !strings.contains(ui,"color_grade.slang") && !strings.contains(ui,"mirai_evaluate_program"),"the ui include has the ui programs alone")
    for other in ([]string{SURFACE_INCLUDE,POSTPROCESS_INCLUDE,VFX_INCLUDE}) {
        text:=read(&f,other)
        testing.expectf(t,!strings.contains(text,"Pulse") && !strings.contains(text,"ui_shine"),"%s has no ui program",other)
    }
    stored,_:=os.read_entire_file(path_join(f.output,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(stored),"\"name\": \"Pulse\",\n      \"domain\": \"ui\","))
}

// A layout that lacks a parameter the program declares is not that program's.
@(test)
a_layout_without_a_declared_parameter_is_refused :: proc(t:^testing.T) {
    metadata:=make(map[string]json.Object,context.temp_allocator)
    metadata["tint"]=json.Object{}
    metadata["glow"]=json.Object{}
    full:=Layout{size=16,fields={{name="tint",kind="vector",scalar="float32",count=3,offset=0},{name="glow",kind="scalar",scalar="float32",count=1,offset=12}}}
    testing.expect_value(t,layout_missing(full,metadata),"")
    testing.expect(t,layout_missing(Layout{},metadata)!="","an empty layout lacks them")
}

@(test)
programs_take_a_material_without_parameters :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    fixture_write(t,f.project,"shaders/plain.slang","//! mirai surface Plain\nnamespace Plain {struct Parameters {}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n")
    catalog,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    plain,found:=program_named(catalog,"Plain")
    testing.expect(t,found,"a program without parameters is in the catalog")
    testing.expect_value(t,len(plain.parameters),0)
}

@(test)
programs_leave_out_one_that_fails_and_publish_the_others :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    fixture_write(t,f.project,"shaders/good.slang","//! mirai surface Good\nnamespace Good {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n")
    fixture_write(t,f.project,"shaders/broken.slang","//! mirai surface Broken\nnamespace Broken {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return not_a_function(ctx);}}\n")
    catalog,problem:=programs_generate(&f.runner,path_clean(ENGINE_ROOT,context.temp_allocator),f.project,f.output,f.slangc,f.version,f.cache,allocator=context.temp_allocator)
    testing.expect_value(t,problem,"")
    _,good:=program_named(catalog,"Good")
    _,broken:=program_named(catalog,"Broken")
    testing.expect(t,good && !broken,"the program that compiles is published and the broken one is left out")
    testing.expect(t,len(catalog.refused)==1 && strings.contains(catalog.refused[0],"Broken"),"the refusal names the program")
    // Nothing does without a program of the engine: one that fails fails the catalog, which names it and what to do.
    engine:=path_join(f.project,"engine",allocator=context.temp_allocator)
    files:Sources
    sources_init(&files,context.temp_allocator)
    testing.expect_value(t,copy_sources(&files,path_join(path_clean(ENGINE_ROOT,context.temp_allocator),"shaders/include",allocator=context.temp_allocator),path_join(engine,"shaders/include",allocator=context.temp_allocator)),"")
    fixture_write(t,engine,"shaders/materials/broken.slang","//! mirai surface Broken\nnamespace Broken {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return not_a_function(ctx);}}\n")
    _,problem=programs_generate(&f.runner,engine,"",path_join(f.project,"engine-out",allocator=context.temp_allocator),f.slangc,f.version,f.cache,allocator=context.temp_allocator)
    testing.expect(t,strings.contains(problem,"Broken") && strings.contains(problem,"shaders/materials") && strings.contains(problem,"mirai shaders"),problem)
}

// A Surface program that says `//! vertex` has its function vertex called in
// its own include, says in the catalog whether it is animated and how far it
// reaches, a number or a float parameter, and is listed for the stages
// compiled per vertex program; a wrong line leaves it out, saying why.
@(test)
programs_that_move_vertices_declare_their_function_and_reach :: proc(t:^testing.T) {
    f:Programs_Fixture
    if !programs_fixture(t,&f) {return}
    program :: proc(name,line,fields:string) -> string {
        return fmt.tprintf("//! mirai surface %s\n%s\nnamespace %s {{struct Parameters {{%s}}; Mirai_Vertex vertex(Mirai_Vertex_Context ctx,Parameters p) {{Mirai_Vertex v=mirai_vertex_default(ctx);v.position.y+=sin(ctx.time);return v;}} Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {{return mirai_surface_default(ctx);}}}}\n",name,line,name,fields)
    }
    fixture_write(t,f.project,"shaders/sway.slang",program("Sway","//! vertex animated reach 0.25","float strength;"))
    fixture_write(t,f.project,"shaders/spread.slang",program("Spread","//! vertex reach distance","float3 color;float distance;"))
    fixture_write(t,f.project,"shaders/still.slang","//! mirai surface Still\nnamespace Still {struct Parameters {float amount;}; Mirai_Surface evaluate(Mirai_Surface_Context ctx,Parameters p) {return mirai_surface_default(ctx);}}\n")
    catalog,problem:=programs_of(&f)
    testing.expect_value(t,problem,"")
    sway,has_sway:=program_named(catalog,"Sway")
    spread,has_spread:=program_named(catalog,"Spread")
    still,has_still:=program_named(catalog,"Still")
    if !testing.expect(t,has_sway && has_spread && has_still) {return}
    testing.expect(t,sway.vertex.declared && sway.vertex.animated && sway.vertex.reach==0.25 && sway.vertex.reach_parameter=="")
    testing.expect(t,spread.vertex.declared && !spread.vertex.animated && spread.vertex.reach_parameter=="distance")
    testing.expect(t,!still.vertex.declared,"a program without the line moves no vertices")
    listed :: proc(names:[]string,name:string) -> bool {
        for n in names {if n==name {return true}}
        return false
    }
    testing.expect(t,listed(catalog.vertex,"Sway") && listed(catalog.vertex,"Spread") && !listed(catalog.vertex,"Still"))
    own,_:=os.read_entire_file(path_join(f.output,"include",SURFACE_FOLDER,"Sway",SURFACE_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(own),"inout Mirai_Vertex value) {value=Sway::vertex(ctx,mirai_load_Sway(packed));return true;}"),string(own))
    unmoved,_:=os.read_entire_file(path_join(f.output,"include",SURFACE_FOLDER,"Still",SURFACE_INCLUDE,allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(unmoved),NO_VERTEX_PROGRAM),"a program that moves no vertices has the function that moves none")
    stored,_:=os.read_entire_file(path_join(f.output,"catalog.json",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect(t,strings.contains(string(stored),"\"reach\": \"distance\"") && strings.contains(string(stored),"\"animated\": true"),string(stored))

    Refused :: struct {line,fields,says:string}
    refused:=[]Refused{
        {"//! vertex reach color","float3 color;","one float"},
        {"//! vertex reach far","float amount;","neither a number nor a parameter"},
        {"//! vertex reach -1","float amount;","reach is metres"},
        {"//! vertex wobbly","float amount;","declare a vertex function"},
    }
    os.remove(path_join(f.project,"shaders/sway.slang",allocator=context.temp_allocator))
    os.remove(path_join(f.project,"shaders/spread.slang",allocator=context.temp_allocator))
    for c in refused {
        fixture_write(t,f.project,"shaders/bad.slang",program("Bad",c.line,c.fields))
        _,said:=programs_of(&f)
        testing.expectf(t,strings.contains(said,"Bad") && strings.contains(said,c.says),"%s: %s",c.line,said)
    }
    fixture_write(t,f.project,"shaders/bad.slang","//! mirai postprocess Bad\n//! vertex\nnamespace Bad {struct Parameters {float amount;}; float4 evaluate(Mirai_PostProcess_Context ctx,Parameters p) {return ctx.color;}}\n")
    _,said:=programs_of(&f)
    testing.expect(t,strings.contains(said,"only a Surface program moves vertices"),said)
}
