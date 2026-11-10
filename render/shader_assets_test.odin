package mirai_render

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:rhi"
import "mirai:std/base"

// The stages the executable embeds, with their code decoded into the temporary allocator.
@(private="file")
embedded :: proc(t:^testing.T) -> (codes:[Shader_Id]rhi.Shader_Code,programs:[len(PROGRAM_SHADERS)]rhi.Shader_Code) {
    _,problem:=embedded_shaders_decode(&codes,&programs,context.temp_allocator)
    testing.expect_value(t,problem,"")
    return
}

@(test)
shader_assets_match_uses_contents_instead_of_generation_storage :: proc(t:^testing.T) {
    codes,_:=embedded(t)
    next:=codes[.Ui_Vert]
    next.name=strings.clone(next.name);defer delete(next.name)
    next.bindings=make([]rhi.Binding_Info,len(next.bindings));defer delete(next.bindings)
    copy(next.bindings,codes[.Ui_Vert].bindings)
    when ODIN_OS==.Darwin {
        next.msl=strings.clone(next.msl);defer delete(next.msl)
        next.msl_entry=strings.clone(next.msl_entry);defer delete(next.msl_entry)
    } else {
        next.spirv=make([]u8,len(next.spirv));defer delete(next.spirv)
        copy(next.spirv,codes[.Ui_Vert].spirv)
    }
    assets:=Shader_Assets{codes=codes,owned=true}
    assets.codes[.Ui_Vert]=next
    testing.expect(t,shader_assets_match_codes(&assets,&codes),"A freshly loaded generation with identical target code and reflection keeps the pipelines")
    testing.expect(t,codes[.Ui_Vert].name==SHADERS[.Ui_Vert].name && codes[.Ui_Vert].bindings[0]==SHADERS[.Ui_Vert].bindings[0],"Comparison preserves the active code storage")
}

@(test)
shader_assets_match_rejects_code_and_pipeline_contract_changes :: proc(t:^testing.T) {
    codes,_:=embedded(t)
    assets:=Shader_Assets{codes=codes}
    original:=codes[.Ui_Vert]
    next:=&assets.codes[.Ui_Vert]
    testing.expect(t,len(original.bindings)>0)
    if len(original.bindings)==0 {return}
    next.name="changed name"
    testing.expect(t,!shader_assets_match_codes(&assets,&codes),"Shader names participate in the pipeline contract")
    next^=original;next.stage=.Compute
    testing.expect(t,!shader_assets_match_codes(&assets,&codes),"A stage change requires new pipelines")
    next^=original;next.threadgroup[0]+=1
    testing.expect(t,!shader_assets_match_codes(&assets,&codes),"Dispatch dimensions require new pipelines")
    next^=original;next.bindings=nil
    testing.expect(t,!shader_assets_match_codes(&assets,&codes),"The binding count must match")
    next^=original
    bindings:=make([]rhi.Binding_Info,len(original.bindings));defer delete(bindings)
    copy(bindings,original.bindings);next.bindings=bindings
    bindings[0].slot+=1
    testing.expect(t,!shader_assets_match_codes(&assets,&codes),"A binding slot change requires new pipelines")
    bindings[0]=original.bindings[0];bindings[0].kind=.Sampler
    testing.expect(t,!shader_assets_match_codes(&assets,&codes),"A binding kind change requires new pipelines")
    bindings[0]=original.bindings[0];bindings[0].stages={.Compute}
    testing.expect(t,!shader_assets_match_codes(&assets,&codes),"Binding stage masks must match")
    next^=original
    when ODIN_OS==.Darwin {
        next.msl_entry="changed entry"
        testing.expect(t,!shader_assets_match_codes(&assets,&codes),"Metal entry points must match")
        next^=original;next.msl=original.msl[:len(original.msl)-1]
        testing.expect(t,!shader_assets_match_codes(&assets,&codes),"Metal source length must match")
        bytes:=make([]u8,len(original.msl));defer delete(bytes)
        copy(bytes,transmute([]u8)original.msl);bytes[0]~=1
        next.msl=string(bytes)
        testing.expect(t,!shader_assets_match_codes(&assets,&codes),"Equal-length Metal sources still compare every byte")
    } else {
        next.spirv=original.spirv[:len(original.spirv)-1]
        testing.expect(t,!shader_assets_match_codes(&assets,&codes),"SPIR-V size must match")
        bytes:=make([]u8,len(original.spirv));defer delete(bytes)
        copy(bytes,original.spirv);bytes[0]~=1
        next.spirv=bytes
        testing.expect(t,!shader_assets_match_codes(&assets,&codes),"Equal-length SPIR-V still compares every byte")
    }
}

@(private)
GENERATION :: #directory+"/../shaders/build"

// Every stage and program stage the executable embeds decodes to the code the
// generation wrote, with the same reflection.
@(test)
shader_generation_of_the_engine_is_the_one_embedded :: proc(t:^testing.T) {
    testing.expect(t,shader_generation_current(GENERATION),"shaders/build was generated from the sources this build embeds: run `mirai shaders`")
    assets,problem:=shader_assets_load(GENERATION)
    testing.expect_value(t,problem,"")
    if problem!="" {return}
    defer shader_assets_destroy(&assets)
    testing.expect(t,assets.owned)
    codes,programs:=embedded(t)
    same :: proc(t:^testing.T,code,embedded:rhi.Shader_Code) {
        testing.expect_value(t,code.name,embedded.name)
        testing.expect_value(t,code.stage,embedded.stage)
        testing.expect_value(t,code.threadgroup,embedded.threadgroup)
        testing.expect_value(t,len(code.bindings),len(embedded.bindings))
        for binding,i in embedded.bindings {
            if i<len(code.bindings) {testing.expectf(t,code.bindings[i]==binding,"%s binding %d: %v, embedded %v",code.name,i,code.bindings[i],binding)}
        }
        when ODIN_OS==.Darwin {
            testing.expectf(t,len(code.msl)>0 && code.msl==embedded.msl && code.msl_entry==embedded.msl_entry,"%s: the Metal source on disk is the embedded one",code.name)
        } else {
            testing.expectf(t,len(code.spirv)>0 && string(code.spirv)==string(embedded.spirv),"%s: the SPIR-V on disk is the embedded one",code.name)
        }
    }
    for code,id in assets.codes {same(t,code,codes[id])}
    testing.expect_value(t,len(assets.programs),len(programs))
    for code,i in assets.programs {
        if i<len(programs) {same(t,code,programs[i])}
    }
}

@(private="file")
generation_copy :: proc(t:^testing.T,edit:proc(manifest:string)->string) -> string {
    folder,err:=os.make_directory_temp("","mirai-generation-*",context.temp_allocator)
    testing.expect(t,err==nil)
    entries,_:=os.read_all_directory_by_path(GENERATION,context.temp_allocator)
    for entry in entries {
        if os.is_directory(entry.fullpath) {continue}
        data,_:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if entry.name=="manifest.json" {data=transmute([]u8)edit(string(data))}
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",folder,entry.name),data)==nil)
    }
    return folder
}

@(test)
shader_generation_of_other_engine_sources_is_not_loaded :: proc(t:^testing.T) {
    folder:=generation_copy(t,proc(manifest:string)->string {
        changed,_:=strings.replace_all(manifest,SHADERS_FINGERPRINT,"0000000000000000000000000000000000000000000000000000000000000000",context.temp_allocator)
        return changed
    })
    defer base.remove_all(folder)
    testing.expect(t,!shader_generation_current(folder))
    assets,problem:=shader_assets_load(folder)
    testing.expect(t,problem!="" && !assets.owned,"a generation of other sources is refused")
    testing.expect(t,!shader_generation_current(fmt.tprintf("%s/missing",folder)))
}

@(test)
shader_generation_with_a_broken_manifest_is_not_loaded :: proc(t:^testing.T) {
    Case :: struct {edit:proc(manifest:string)->string,expected:string}
    cases:=[]Case{
        {proc(manifest:string)->string {changed,_:=strings.replace(manifest,"\"id\": \"Blit_Frag\"","\"id\": \"No_Such_Shader\"",1,context.temp_allocator);return changed},"unknown shader"},
        {proc(manifest:string)->string {changed,_:=strings.replace(manifest,"\"id\": \"Composite_Comp\"","\"id\": \"Blit_Frag\"",1,context.temp_allocator);return changed},"duplicate shader id"},
        {proc(manifest:string)->string {changed,_:=strings.replace(manifest,"\"spv\": \"blit.frag.spv\"","\"spv\": \"missing.spv\"",1,context.temp_allocator);changed,_=strings.replace(changed,"\"msl\": \"blit.frag.metal\"","\"msl\": \"missing.metal\"",1,context.temp_allocator);return changed},"cannot read"},
        {proc(manifest:string)->string {changed,_:=strings.replace(manifest,"\"kind\": \"Uniform_Buffer\"","\"kind\": \"Push_Constant\"",1,context.temp_allocator);return changed},"invalid binding kind"},
        {proc(manifest:string)->string {changed,_:=strings.replace(manifest,"\"slot\": 1,","\"slot\": 77,",1,context.temp_allocator);return changed},"invalid binding slot"},
        {proc(manifest:string)->string {return "{not json"},"invalid shader manifest"},
    }
    for c in cases {
        folder:=generation_copy(t,c.edit)
        assets,problem:=shader_assets_load(folder)
        testing.expectf(t,strings.contains(problem,c.expected) && !assets.owned,"%s: %s",c.expected,problem)
        base.remove_all(folder)
    }
}
