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
import "mirai:store"

// A texture the editor imported Fast ships Final: the refresh of a build that
// cooks builds it again from its source with the id it has, a cook without it
// says so, and the refresh of a build that does not cook takes either as it is.
@(test)
a_cook_ships_a_fast_texture_final_from_its_source :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder,assets:=test_project(t,"cook-fast")
    if folder=="" {return}
    defer free_all(context.temp_allocator)
    os.make_directory_all(fmt.tprintf("%s/final",assets))
    // An uncompressed TGA, top to bottom, of noise that RDO changes.
    SIDE :: 64
    image:=make([]u8,18+SIDE*SIDE*4,context.temp_allocator)
    image[2],image[12],image[14],image[16],image[17]=2,SIDE,SIDE,32,0x28
    state:=u32(9)
    for &value,at in image[18:] {
        state=state*1664525+1013904223
        value=255 if at%4==3 else u8(state>>24)
    }
    source,final:=fmt.tprintf("%s/noise.tga",assets),fmt.tprintf("%s/final/noise.tga",assets)
    testing.expect(t,os.write_entire_file(source,image)==nil && os.write_entire_file(final,image)==nil)
    s:=test_store(t,fmt.tprintf("%s/store",folder))
    if s==nil {return}
    fast:=Library_Options{store=s,root=folder,fast_textures=true}
    final_options:=fast
    final_options.fast_textures=false
    imported :: proc(t:^testing.T,types:^asset.Types,source:string,options:Library_Options) -> (id:base.Asset_Id,flags:asset.Texture_Flags,blocks:[]u8,manifest:store.Hash) {
        report,error:=ingest(source,options)
        defer importer.report_destroy(&report)
        if !testing.expectf(t,error.code==.None && len(report.assets)==1,"%v %s",error.code,error.message) {return}
        id,flags,blocks=level_of(t,types,report.assets[0].path)
        return id,flags,blocks,report.manifest
    }
    level_of :: proc(t:^testing.T,types:^asset.Types,path:string) -> (id:base.Asset_Id,flags:asset.Texture_Flags,blocks:[]u8) {
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path,context.temp_allocator),asset.Error.None) {return}
        view,error:=asset.texture_view(&a,types)
        if !testing.expect_value(t,error,asset.Error.None) {return}
        return a.blob.header.id,view.info.flags,slice.clone(asset.texture_mip(view,0),context.temp_allocator)
    }
    fast_id,fast_flags,fast_blocks,manifest:=imported(t,&types,source,fast)
    _,final_flags,final_blocks,_:=imported(t,&types,final,final_options)
    testing.expect(t,.Fast in fast_flags && .Fast not_in final_flags && !slice.equal(fast_blocks,final_blocks))
    added:=project_add(folder,manifest,"",nil,fast,context.temp_allocator)
    testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added)

    // The refresh of a build that does not cook takes Fast; that of one that cooks builds Final, with the id it has.
    kept:=project_refresh(folder,fast,context.temp_allocator)
    testing.expectf(t,kept.ingested==0 && len(kept.failures)==0 && len(kept.missing)==0,"Fast is current for a build that does not cook: %v",kept)
    cook_manifest:=fmt.tprintf("%s/%s",folder,build.COOK_FILE)
    testing.expect(t,os.write_entire_file(cook_manifest,`{"roots":["noise.tex"]}`)==nil)
    // The cook reads the project as it is: it says who builds the texture Final.
    report:=build.cook_assets({assets=assets,output=fmt.tprintf("%s/program",folder),manifest=cook_manifest,root=folder,store=s,allocator=context.temp_allocator})
    testing.expectf(t,report.error==.Source_Failed && strings.contains(report.detail,"noise") && strings.contains(report.detail,"mirai build game"),"%v %s",report.error,report.detail)
    refreshed:=project_refresh(folder,final_options,context.temp_allocator)
    testing.expectf(t,refreshed.ingested==1 && len(refreshed.failures)==0 && len(refreshed.missing)==0,"%v",refreshed)
    kept=project_refresh(folder,fast,context.temp_allocator)
    testing.expectf(t,kept.ingested==0 && len(kept.failures)==0,"Final is current for a build that does not cook: %v",kept)
    report=build.cook_assets({assets=assets,output=fmt.tprintf("%s/game",folder),manifest=cook_manifest,root=folder,store=s,allocator=context.temp_allocator})
    testing.expectf(t,report.error==.None,"%v %s",report.error,report.detail)
    shipped_id,shipped_flags,shipped_blocks:=level_of(t,&types,fmt.tprintf("%s/game/noise.tex",folder))
    testing.expect(t,shipped_id==fast_id && .Fast not_in shipped_flags && slice.equal(shipped_blocks,final_blocks),"Final, with the id it had")
}
