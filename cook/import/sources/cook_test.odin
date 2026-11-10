package sources

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/build"
import "mirai:std/base"
import "mirai:std/jobs"

@(private="file")
reimport :: proc(source,folder:string,desc:^build.Cook_Desc,worker:jobs.Worker_Ref) -> (ok:bool,message:string) {
    report,error:=import_source(source,folder,{texture_cache=desc.texture_cache,mesh_cache=desc.mesh_cache,no_save=true,worker=worker},nil,context.temp_allocator)
    importer.report_destroy(&report)
    return error.code==.None,error.message
}

// A texture the editor imported Fast ships Final, encoded again from its
// source with the id it has; without its source or the import program the cook
// says how to fix it. The import runs here in-process, as the editor's cook can.
@(test)
a_cook_encodes_a_fast_texture_again_as_final_from_its_source :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=base.test_folder(t,"cook-fast")
    if folder=="" {return}
    defer free_all(context.temp_allocator)
    os.make_directory_all(fmt.tprintf("%s/source",folder))
    // An uncompressed TGA, top to bottom, of noise that RDO changes.
    SIDE :: 64
    image:=make([]u8,18+SIDE*SIDE*4,context.temp_allocator)
    image[2],image[12],image[14],image[16],image[17]=2,SIDE,SIDE,32,0x28
    state:=u32(9)
    for &value,at in image[18:] {
        state=state*1664525+1013904223
        value=255 if at%4==3 else u8(state>>24)
    }
    source:=fmt.tprintf("%s/source/noise.tga",folder)
    testing.expect(t,os.write_entire_file(source,image)==nil)
    imported :: proc(t:^testing.T,types:^asset.Types,source,out:string,options:importer.Import_Options) -> (id:base.Asset_Id,flags:asset.Texture_Flags,blocks:[]u8) {
        report,error:=import_source(source,out,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None && len(report.assets)==1,"%v %s",error.code,error.message) {return}
        return level_of(t,types,report.assets[0].path)
    }
    level_of :: proc(t:^testing.T,types:^asset.Types,path:string) -> (id:base.Asset_Id,flags:asset.Texture_Flags,blocks:[]u8) {
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path,context.temp_allocator),asset.Error.None) {return}
        view,error:=asset.texture_view(&a,types)
        if !testing.expect_value(t,error,asset.Error.None) {return}
        return a.blob.header.id,view.info.flags,slice.clone(asset.texture_mip(view,0),context.temp_allocator)
    }
    assets:=fmt.tprintf("%s/assets",folder)
    fast_id,fast_flags,fast_blocks:=imported(t,&types,source,fmt.tprintf("%s/textures",assets),{root=folder,fast_textures=true,no_save=true})
    _,final_flags,final_blocks:=imported(t,&types,source,fmt.tprintf("%s/final",folder),{no_save=true})
    testing.expect(t,.Fast in fast_flags && .Fast not_in final_flags && !slice.equal(fast_blocks,final_blocks))
    manifest:=fmt.tprintf("%s/%s",folder,build.COOK_FILE)
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["textures/"]}`)==nil)

    report:=build.cook_assets({assets=assets,output=fmt.tprintf("%s/game",folder),manifest=manifest,root=folder,import_source=reimport,allocator=context.temp_allocator})
    testing.expectf(t,report.error==.None && report.textures_finalized==1,"%v %s",report.error,report.detail)
    shipped_id,shipped_flags,shipped_blocks:=level_of(t,&types,fmt.tprintf("%s/game/textures/noise.tex",folder))
    testing.expect(t,shipped_id==fast_id && .Fast not_in shipped_flags && slice.equal(shipped_blocks,final_blocks),"Final, with the id it had")

    // Without the engine's import program the cook says how to get it.
    report=build.cook_assets({assets=assets,output=fmt.tprintf("%s/program",folder),manifest=manifest,root=folder,allocator=context.temp_allocator})
    testing.expectf(t,report.error==.Source_Failed && strings.contains(report.detail,"mirai build editor"),"%v %s",report.error,report.detail)
    testing.expect(t,os.remove(source)==nil)
    report=build.cook_assets({assets=assets,output=fmt.tprintf("%s/again",folder),manifest=manifest,root=folder,import_source=reimport,allocator=context.temp_allocator})
    testing.expectf(t,report.error==.Source_Failed && strings.contains(report.detail,"source/noise.tga") && strings.contains(report.detail,"mirai import"),"%v %s",report.error,report.detail)
}
