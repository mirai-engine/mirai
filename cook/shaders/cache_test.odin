package shaders

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"

@(private)
ENGINE_ROOT :: #directory+"/../.."

@(private)
fixture_write :: proc(t:^testing.T,root,relative,text:string) {
    path:=path_join(root,relative,allocator=context.temp_allocator)
    os.make_directory_all(path_parent(path))
    testing.expectf(t,write_file(path,transmute([]u8)text),"%s can be written",path)
}

// a.comp includes include/shared.slang, which includes include/nested.slang; b.comp includes nothing.
@(private="file")
sources_make :: proc(t:^testing.T) -> string {
    root:=base.test_folder(t,"shaders")
    if root=="" {return ""}
    fixture_write(t,root,"a.comp.slang","#include \"shared.slang\"\nvoid main() {}\n")
    fixture_write(t,root,"b.comp.slang","void main() {}\n")
    fixture_write(t,root,"include/shared.slang","#include \"nested.slang\"\n")
    fixture_write(t,root,"include/nested.slang","float value = 1;\n")
    return root
}

@(private="file")
fingerprint_of :: proc(root,name:string) -> string {
    configuration:="flags;compiler;ABI"
    return fingerprint(path_join(root,name,allocator=context.temp_allocator),{path_join(root,"include",allocator=context.temp_allocator)},{{"fixture",root}},transmute([]u8)configuration,context.temp_allocator)
}

@(test)
change_invalidates_only_the_stages_that_depend_on_it :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    a,b:=fingerprint_of(root,"a.comp.slang"),fingerprint_of(root,"b.comp.slang")
    testing.expect(t,len(a)==64 && a!=b)
    fixture_write(t,root,"include/nested.slang","float value = 2;\n")
    testing.expect(t,a!=fingerprint_of(root,"a.comp.slang"),"a nested include is part of the stage")
    testing.expect_value(t,fingerprint_of(root,"b.comp.slang"),b)
    stable:=fingerprint_of(root,"a.comp.slang")
    fixture_write(t,root,"b.comp.slang","void main() {int unrelated=2;}\n")
    testing.expect_value(t,fingerprint_of(root,"a.comp.slang"),stable)
}

@(test)
parameter_metadata_changes_authoring_identity_without_invalidating_compilation :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    original:="//! mirai surface Fixture\n//! parameter amount {\"default\":1,\"min\":0,\"max\":2}\n//! variant hw MIRAI_HW_RT=1\nfloat value=__LINE__;\n"
    fixture_write(t,root,"include/nested.slang",original)
    before:=fingerprint_of(root,"a.comp.slang")
    changed,_:=strings.replace_all(original,"\"default\":1","\"default\":2",context.temp_allocator)
    fixture_write(t,root,"include/nested.slang",changed)
    testing.expect_value(t,fingerprint_of(root,"a.comp.slang"),before)
    testing.expect(t,sha_of(transmute([]u8)original,context.temp_allocator)!=sha_of(transmute([]u8)changed,context.temp_allocator),"the full authoring source changes")
    compiled:=compilation_source_bytes("fixture.slang",transmute([]u8)changed,context.temp_allocator)
    testing.expect_value(t,strings.count(string(compiled),"\n"),strings.count(original,"\n"))
    for pair in ([][2]string{{"surface Fixture","postprocess Fixture"},{"MIRAI_HW_RT=1","MIRAI_HW_RT=0"},{"__LINE__","1"}}) {
        changed,_=strings.replace_all(original,pair[0],pair[1],context.temp_allocator)
        fixture_write(t,root,"include/nested.slang",changed)
        testing.expectf(t,fingerprint_of(root,"a.comp.slang")!=before,"%s changes compilation",pair[1])
    }
}

@(test)
metadata_hash_preserves_strings_comments_continuations_and_binary_modules :: proc(t:^testing.T) {
    cases:=[]string{
        "static const string value=R\"(\n//! parameter amount {\"default\":1}\n)\";\n",
        "/*\n//! parameter amount {\"default\":1,\"label\":\"*/ code\"}\n",
        "static const string value=\"escaped \\\" text\n//! parameter amount {\"default\":1}\n\";\n",
        "#define VALUE \\\n//! parameter amount {\"default\":1}\n",
        "//! parameter amount {\"default\":1} code\n",
        "//! parameter amount {\"default\":1}\xff\n",
    }
    for original in cases {
        compiled:=compilation_source_bytes("fixture.slang",transmute([]u8)original,context.temp_allocator)
        testing.expect_value(t,string(compiled),original)
    }
    module:="//! parameter amount {\"default\":1}\n"
    testing.expect_value(t,string(compilation_source_bytes("fixture.slang-module",transmute([]u8)module,context.temp_allocator)),module)
    mixed:="/* an earlier block */\n//! parameter amount {\"default\":1}\nfloat value=__LINE__;\n"
    testing.expect_value(t,string(compilation_source_bytes("fixture.slang",transmute([]u8)mixed,context.temp_allocator)),"/* an earlier block */\n\nfloat value=__LINE__;\n")
}

@(test)
configuration_is_part_of_a_fingerprint :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    source:=path_join(root,"a.comp.slang",allocator=context.temp_allocator)
    includes:=[]string{path_join(root,"include",allocator=context.temp_allocator)}
    one,two:="compiler 1","compiler 2"
    first:=fingerprint(source,includes,{{"fixture",root}},transmute([]u8)one,context.temp_allocator)
    testing.expect(t,first!=fingerprint(source,includes,{{"fixture",root}},transmute([]u8)two,context.temp_allocator))
    testing.expect_value(t,fingerprint(source,includes,{{"fixture",root}},transmute([]u8)one,context.temp_allocator),first)
}

@(test)
shadowing_an_include_invalidates_and_identity_does_not_depend_on_the_checkout :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    first:=fingerprint_of(root,"a.comp.slang")
    // The folder of the including file is searched before the include folders.
    fixture_write(t,root,"shared.slang","float value = 4;\n")
    shadowed:=fingerprint_of(root,"a.comp.slang")
    testing.expect(t,first!=shadowed)
    // The same sources elsewhere, checked out with CRLF line endings.
    relocated:=path_join(root,"relocated",allocator=context.temp_allocator)
    os.make_directory_all(path_join(relocated,"include",allocator=context.temp_allocator))
    for name in ([]string{"a.comp.slang","shared.slang"}) {
        data,_:=os.read_entire_file(path_join(root,name,allocator=context.temp_allocator),context.temp_allocator)
        converted,_:=strings.replace_all(string(data),"\n","\r\n",context.temp_allocator)
        fixture_write(t,relocated,name,converted)
    }
    testing.expect_value(t,fingerprint_of(relocated,"a.comp.slang"),shadowed)
}

@(test)
textual_inc_and_header_dependencies_are_transitive :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    fixture_write(t,root,"a.comp.slang","#include \"helper.inc\"\nvoid main() {}\n")
    fixture_write(t,root,"include/helper.inc","  #  include <parameters.h>\n")
    fixture_write(t,root,"include/parameters.h","#include \"nested.slang\"\n")
    before:=fingerprint_of(root,"a.comp.slang")
    fixture_write(t,root,"include/nested.slang","float value = 3;\n")
    testing.expect(t,before!=fingerprint_of(root,"a.comp.slang"))
}

@(test)
imported_modules_are_dependencies :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    fixture_write(t,root,"a.comp.slang","import lighting.brdf;\nexport import shared;\nimport missing_builtin;\nvoid main() {}\n")
    fixture_write(t,root,"include/lighting/brdf.slang","float lobe = 1;\n")
    found:=dependencies(path_join(root,"a.comp.slang",allocator=context.temp_allocator),{path_join(root,"include",allocator=context.temp_allocator)},context.temp_allocator)
    names:=make([dynamic]string,context.temp_allocator)
    for path in found {append(&names,stable_name(path,{{"fixture",root}},context.temp_allocator))}
    for wanted in ([]string{"fixture/a.comp.slang","fixture/include/lighting/brdf.slang","fixture/include/shared.slang","fixture/include/nested.slang"}) {
        present:=false
        for name in names {present||=name==wanted}
        testing.expectf(t,present,"%s is a dependency: %v",wanted,names[:])
    }
    testing.expect_value(t,len(found),4)
}

@(test)
include_named_by_a_macro_depends_on_every_file_of_the_search_folders :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    fixture_write(t,root,"a.comp.slang","#include SELECTED_HEADER\nvoid main() {}\n")
    fixture_write(t,root,"include/data.bin","\xff\xfe\x00binary")
    before:=fingerprint_of(root,"a.comp.slang")
    fixture_write(t,root,"include/nested.slang","float value = 5;\n")
    after:=fingerprint_of(root,"a.comp.slang")
    testing.expect(t,before!=after,"any file of the search folders can be the one the macro names")
    fixture_write(t,root,"include/data.bin","\xff\xfe\x00other")
    testing.expect(t,after!=fingerprint_of(root,"a.comp.slang"),"the bytes of a file that is not text are hashed too")
}

@(test)
missing_optional_include_is_not_a_dependency_until_it_exists :: proc(t:^testing.T) {
    root:=sources_make(t)
    if root=="" {return}
    fixture_write(t,root,"b.comp.slang","#if OPTIONAL\n#include \"optional.slang\"\n#endif\nvoid main() {}\n")
    before:=fingerprint_of(root,"b.comp.slang")
    fixture_write(t,root,"include/optional.slang","float extra = 1;\n")
    testing.expect(t,before!=fingerprint_of(root,"b.comp.slang"))
}

@(test)
source_outside_every_base_is_named_by_its_path :: proc(t:^testing.T) {
    testing.expect_value(t,stable_name("C:/engine/shaders/a.slang",{{"project","C:/game"},{"engine","C:/engine"}},context.temp_allocator),"engine/shaders/a.slang")
    testing.expect_value(t,stable_name("C:/game/shaders/a.slang",{{"project","C:/game"},{"engine","C:/engine"}},context.temp_allocator),"project/shaders/a.slang")
    testing.expect_value(t,stable_name("C:/elsewhere/a.slang",{{"engine","C:/engine"}},context.temp_allocator),"C:/elsewhere/a.slang")
    testing.expect_value(t,stable_name("C:/engine2/a.slang",{{"engine","C:/engine"}},context.temp_allocator),"C:/engine2/a.slang")
}

@(test)
engine_identity_tracks_nested_headers_and_ignores_the_project_generation :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    engine:=path_join(root,"engine-root",allocator=context.temp_allocator)
    project:=path_join(root,"project",allocator=context.temp_allocator)
    generated:=path_join(engine,"shaders/.temporary-generation/include",allocator=context.temp_allocator)
    fixture_write(t,engine,"shaders/a.comp.slang","#include \"nested/engine.h\"\n#include \"surface_programs.slang\"\n")
    fixture_write(t,engine,"shaders/include/nested/engine.h","float value=1;\n")
    fixture_write(t,engine,"shaders/materials/builtin.slang","float builtin=1;\n")
    fixture_write(t,generated,"surface_programs.slang","#include \"project.inc\"\n")
    fixture_write(t,project,"project.inc","float project_value=1;\n")
    includes:=[]string{generated,path_join(engine,"shaders/include",allocator=context.temp_allocator),project}
    before:=engine_fingerprint(engine,"version",includes,context.temp_allocator)
    testing.expect_value(t,len(before),64)
    fixture_write(t,project,"project.inc","float project_value=2;\n")
    testing.expect_value(t,engine_fingerprint(engine,"version",includes,context.temp_allocator),before)
    fixture_write(t,generated,"surface_programs.slang","#include \"project.inc\"\n// another catalog\n")
    testing.expect_value(t,engine_fingerprint(engine,"version",includes,context.temp_allocator),before)
    testing.expect(t,engine_fingerprint(engine,"another version",includes,context.temp_allocator)!=before,"the compiler is part of the identity")
    fixture_write(t,engine,"shaders/include/nested/engine.h","float value=2;\n")
    changed:=engine_fingerprint(engine,"version",includes,context.temp_allocator)
    testing.expect(t,changed!=before)
    fixture_write(t,engine,"shaders/materials/builtin.slang","float builtin=2;\n")
    testing.expect(t,engine_fingerprint(engine,"version",includes,context.temp_allocator)!=changed,"the built-in programs are engine sources")
}

// A stage of digest "digest" compiled for both backends, and its code.
@(private="file")
stored_entry :: proc() -> (entry:Shader,files:[Backend][]u8) {
    spv,msl:="spirv-bytes","metal-source"
    bindings:=make([]Binding,2,context.temp_allocator)
    bindings[0],bindings[1]={1,"Uniform_Buffer"},{19,"Sampled_Texture"}
    entry={
        id="A_Comp",name="a.comp",stage=.Compute,spv="a.comp.spv",msl="a.comp.metal",entry="main0",bindings=bindings,group={8,8,1},
        fingerprint="digest",spv_hash=sha_of(transmute([]u8)spv,context.temp_allocator),msl_hash=sha_of(transmute([]u8)msl,context.temp_allocator),
    }
    return entry,{.Vulkan=transmute([]u8)spv,.Metal=transmute([]u8)msl}
}

@(test)
shared_cache_gives_a_stage_by_its_digest_and_rejects_corrupt_files :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    shared:=path_join(root,"shared",allocator=context.temp_allocator)
    entry,files:=stored_entry()
    both:=Backends{.Vulkan,.Metal}
    testing.expect(t,cache_stage_write(shared,entry,files,both))
    restored,code,found:=cache_stage_read(shared,"digest",both,context.temp_allocator)
    testing.expect(t,found)
    testing.expect_value(t,restored.stage,Stage.Compute)
    testing.expect_value(t,restored.group,[3]int{8,8,1})
    testing.expect_value(t,restored.entry,"main0")
    testing.expect_value(t,len(restored.bindings),2)
    testing.expect_value(t,restored.bindings[1],Binding{19,"Sampled_Texture"})
    testing.expect(t,!restored.staged,"the stored entry does not say where its files are")
    testing.expect_value(t,string(code[.Vulkan]),"spirv-bytes")
    testing.expect_value(t,string(code[.Metal]),"metal-source")
    testing.expect_value(t,restored.spv,"digest.spv")
    _,_,other:=cache_stage_read(shared,"another digest",both,context.temp_allocator)
    testing.expect(t,!other,"code of other sources is not reused")
    // What another process left half written, or a disk lost, is a miss.
    fixture_write(t,shared,"stages/digest.metal","corrupt")
    _,_,corrupt:=cache_stage_read(shared,"digest",both,context.temp_allocator)
    testing.expect(t,!corrupt,"a file that is not what its hash says is not reused")
    _,_,vulkan:=cache_stage_read(shared,"digest",{.Vulkan},context.temp_allocator)
    testing.expect(t,vulkan,"the code of the other backend still serves")
    fixture_write(t,shared,"stages/digest.json","{\"id\": \"A_Comp\",")
    _,_,truncated:=cache_stage_read(shared,"digest",{.Vulkan},context.temp_allocator)
    testing.expect(t,!truncated,"an entry that cannot be read is a miss")
}

@(test)
shared_cache_keeps_an_entry_per_digest_and_completes_one_with_another_backend :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    shared:=path_join(root,"shared",allocator=context.temp_allocator)
    entry,files:=stored_entry()
    both:=Backends{.Vulkan,.Metal}
    for name in ([]string{"one","two","three"}) {
        entry.fingerprint=name
        testing.expect(t,cache_stage_write(shared,entry,files,both))
    }
    stored,_:=os.read_all_directory_by_path(path_join(shared,CACHE_STAGES,allocator=context.temp_allocator),context.temp_allocator)
    testing.expectf(t,len(stored)==9,"branches and projects do not replace each other's entries: %d files",len(stored))
    for name in ([]string{"one","two","three"}) {
        _,_,found:=cache_stage_read(shared,name,both,context.temp_allocator)
        testing.expectf(t,found,"%s is still there",name)
    }
    // A generation for Vulkan stores its code, and one for Metal completes the entry.
    entry.fingerprint="completed"
    testing.expect(t,cache_stage_write(shared,shader_trim(entry,{.Vulkan}),files,{.Vulkan}))
    _,_,metal:=cache_stage_read(shared,"completed",{.Metal},context.temp_allocator)
    testing.expect(t,!metal,"an entry without the code of a backend is a miss for it")
    testing.expect(t,cache_stage_write(shared,shader_trim(entry,{.Metal}),files,{.Metal}))
    completed,code,found:=cache_stage_read(shared,"completed",both,context.temp_allocator)
    testing.expect(t,found && completed.entry=="main0" && string(code[.Vulkan])=="spirv-bytes" && string(code[.Metal])=="metal-source","the entry keeps the Vulkan code")
}

@(test)
previous_output_cannot_name_a_file_outside_its_folder :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    source:=path_join(root,"source",allocator=context.temp_allocator)
    entry,files:=stored_entry()
    fixture_write(t,source,"a.comp.spv",string(files[.Vulkan]))
    _,found:=artifacts_read(entry,"digest",source,{.Vulkan})
    testing.expect(t,found)
    fixture_write(t,root,"outside.spv","spirv-bytes")
    entry.spv="../outside.spv"
    _,found=artifacts_read(entry,"digest",source,{.Vulkan})
    testing.expect(t,!found)
    entry.spv=""
    _,found=artifacts_read(entry,"digest",source,{.Vulkan})
    testing.expect(t,!found)
}

// Processes that store the same stage at once replace its files whole: a
// reader finds one of the versions or none, never a mix.
@(test)
writers_of_one_file_never_show_half_of_it :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    Writer :: struct {path,text:string,done:bool}
    write :: proc(w:^Writer) {
        for _ in 0..<200 {_=write_file_atomic(w.path,transmute([]u8)w.text)}
        sync.atomic_store(&w.done,true)
    }
    path:=path_join(root,"entry.spv",allocator=context.temp_allocator)
    writers:=[2]Writer{{path=path,text=strings.repeat("a",64*1024,context.temp_allocator)},{path=path,text=strings.repeat("b",48*1024,context.temp_allocator)}}
    threads:[2]^thread.Thread
    for &w,i in writers {threads[i]=thread.create_and_start_with_poly_data(&w,write)}
    whole:=true
    for !sync.atomic_load(&writers[0].done) || !sync.atomic_load(&writers[1].done) {
        data,err:=os.read_entire_file(path,context.allocator)
        if err!=nil {continue}
        whole&&=string(data)==writers[0].text || string(data)==writers[1].text
        delete(data)
    }
    for thread_handle in threads {thread.join(thread_handle);thread.destroy(thread_handle)}
    testing.expect(t,whole,"every read is one whole version")
    left,_:=os.read_all_directory_by_path(root,context.temp_allocator)
    testing.expectf(t,len(left)==1,"no temporary file is left: %d files",len(left))
    final,_:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,string(final)==writers[0].text || string(final)==writers[1].text)
}

@(test)
shared_cache_prunes_entries_unused_for_a_month_at_most_once_a_day :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    shared:=path_join(root,"shared",allocator=context.temp_allocator)
    entry,files:=stored_entry()
    both:=Backends{.Vulkan,.Metal}
    for name in ([]string{"old","used"}) {
        entry.fingerprint=name
        testing.expect(t,cache_stage_write(shared,entry,files,both))
    }
    fixture_write(t,shared,"reflection/old.json","{}")
    fixture_write(t,shared,"reflection/old.attributes.json","{}")
    now:=time.now()
    long_ago:=time.time_add(now,-40*24*time.Hour)
    age :: proc(shared:string,moment:time.Time) {
        for folder in ([]string{CACHE_STAGES,CACHE_REFLECTION}) {
            for path in listing_read(path_join(shared,folder,allocator=context.temp_allocator),false,context.temp_allocator).files {_=os.change_times(path,moment,moment)}
        }
    }
    age(shared,long_ago)
    // A generation reused this one since: it was touched.
    _,_,used:=cache_stage_read(shared,"used",both,context.temp_allocator)
    testing.expect(t,used)
    cache_prune(shared,now)
    exists :: proc(shared,relative:string) -> bool {return os.exists(path_join(shared,relative,allocator=context.temp_allocator))}
    for relative in ([]string{"stages/old.json","stages/old.spv","stages/old.metal","reflection/old.json","reflection/old.attributes.json"}) {
        testing.expectf(t,!exists(shared,relative),"%s was unused for a month",relative)
    }
    for relative in ([]string{"stages/used.json","stages/used.spv","stages/used.metal"}) {
        testing.expectf(t,exists(shared,relative),"%s is kept: its entry was used",relative)
    }
    // Once a day at most.
    entry.fingerprint="later"
    testing.expect(t,cache_stage_write(shared,entry,files,both))
    age(shared,long_ago)
    cache_prune(shared,now)
    testing.expect(t,exists(shared,"stages/later.json"),"the cache was pruned today")
    cache_prune(shared,time.time_add(now,25*time.Hour))
    testing.expect(t,!exists(shared,"stages/later.json") && !exists(shared,"stages/used.json"))
}

@(test)
tool_of_the_checkout_is_found_before_path :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    executable:=strings.concatenate({"spirv-val",EXECUTABLE_SUFFIX},context.temp_allocator)
    fixture_write(t,root,strings.concatenate({".deps/sdk-b/deep/bin/",executable},context.temp_allocator),"tool")
    found,ok:=tool_find(root,.Spirv_Val,context.temp_allocator)
    testing.expect(t,ok)
    testing.expect_value(t,found,path_join(root,".deps/sdk-b/deep/bin",executable,allocator=context.temp_allocator))
    // A shallower folder comes first, and among those of one depth the first by name.
    fixture_write(t,root,strings.concatenate({".deps/sdk-b/Bin/",executable},context.temp_allocator),"tool")
    fixture_write(t,root,strings.concatenate({".deps/sdk-a/Bin/",executable},context.temp_allocator),"tool")
    found,ok=tool_find(root,.Spirv_Val,context.temp_allocator)
    testing.expect_value(t,found,path_join(root,".deps/sdk-a/Bin",executable,allocator=context.temp_allocator))
    // The compiler is only the one installed in .deps/slang.
    fixture_write(t,root,strings.concatenate({".deps/sdk-a/Bin/slangc",EXECUTABLE_SUFFIX},context.temp_allocator),"tool")
    compiler,compiler_found:=tool_find(root,.Slangc,context.temp_allocator)
    testing.expect(t,!compiler_found || !path_inside(compiler,root),"a slangc of an SDK is not the pinned one")
    fixture_write(t,root,strings.concatenate({".deps/slang/bin/slangc",EXECUTABLE_SUFFIX},context.temp_allocator),"tool")
    compiler,compiler_found=tool_find(root,.Slangc,context.temp_allocator)
    if _,configured:=os.lookup_env("MIRAI_SLANGC",context.temp_allocator);configured {log.info("MIRAI_SLANGC is set: the pinned compiler is not looked up");return}
    if _,configured:=os.lookup_env("MIRAI_SLANG",context.temp_allocator);configured {log.info("MIRAI_SLANG is set: the pinned compiler is not looked up");return}
    testing.expect(t,compiler_found)
    testing.expect_value(t,compiler,path_join(root,".deps/slang/bin",strings.concatenate({"slangc",EXECUTABLE_SUFFIX},context.temp_allocator),allocator=context.temp_allocator))
}

@(test)
tool_run_returns_the_output_and_whether_it_succeeded :: proc(t:^testing.T) {
    slangc,found:=tool_find(path_clean(ENGINE_ROOT,context.temp_allocator),.Slangc,context.temp_allocator)
    if !found {log.warn("slangc is not installed: run `mirai setup slang`");return}
    runner:Runner
    version,ok:=tool_run(&runner,{slangc,"-version"},context.temp_allocator)
    testing.expect(t,ok)
    testing.expect(t,strings.trim_space(version)!="","the compiler says its version")
    _,failed:=tool_run(&runner,{slangc,"--no-such-option-of-slang"},context.temp_allocator)
    testing.expect(t,!failed,"a tool that exits with an error is a failure")
    message,started:=tool_run(&runner,{path_join(ENGINE_ROOT,"no-such-tool",allocator=context.temp_allocator)},context.temp_allocator)
    testing.expect(t,!started && message!="")
    testing.expect_value(t,runner.runs,3)
}

@(test)
cancel_kills_the_tools_that_run_and_starts_no_other :: proc(t:^testing.T) {
    Run :: struct {runner:^Runner,command:[]string,ok:bool}
    words:[4]string
    command:[]string
    when ODIN_OS==.Windows {
        system,_:=os.lookup_env("SystemRoot",context.temp_allocator)
        words={path_join(system,"System32/PING.EXE",allocator=context.temp_allocator),"-n","60","127.0.0.1"}
        command=words[:]
    } else {
        words[0],words[1]="/bin/sleep","60"
        command=words[:2]
    }
    runner:Runner
    run:=Run{runner=&runner,command=command}
    worker:=thread.create_and_start_with_poly_data(&run,proc(run:^Run) {_,run.ok=tool_run(run.runner,run.command,context.temp_allocator)})
    started:=time.tick_now()
    for time.duration_seconds(time.tick_since(started))<10 {
        sync.lock(&runner.lock)
        running:=runner.running_count
        sync.unlock(&runner.lock)
        if running>0 {break}
        time.sleep(10*time.Millisecond)
    }
    stopping:=time.tick_now()
    runner_cancel(&runner)
    thread.join(worker)
    thread.destroy(worker)
    testing.expect(t,!run.ok,"a tool killed is a failure")
    testing.expect(t,time.duration_seconds(time.tick_since(stopping))<10,"it does not run to its end")
    message,started_again:=tool_run(&runner,command,context.temp_allocator)
    testing.expect(t,!started_again && message!="","a cancelled runner starts nothing")
    testing.expect_value(t,runner.runs,1)
}

@(test)
a_folder_only_the_overlay_has_lists_the_sources_it_adds :: proc(t:^testing.T) {
    root:=base.test_folder(t,"shaders")
    if root=="" {return}
    missing:=path_join(root,"shaders",allocator=context.temp_allocator)
    path:=path_join(missing,"glow.slang",allocator=context.temp_allocator)
    overlay:=make(map[string]Overlay,context.temp_allocator)
    overlay[path]=Overlay{path,transmute([]u8)string("//! mirai ui Glow\n"),false}
    listing:=listing_read(missing,true,context.temp_allocator,overlay)
    testing.expect(t,len(listing.files)==1 && listing.files[0]==path && listing.hash!="","a new program makes the folder of the project")
    nothing:=listing_read(missing,true,context.temp_allocator)
    testing.expect(t,len(nothing.files)==0 && nothing.hash=="","a folder that is not there has no listing")
}
