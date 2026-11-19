package sources

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/cache"
import importer "mirai:cook/import"
import "mirai:cook/build"
import "mirai:cook/prefab"
import "mirai:project"
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
        objects_written(options.store,&report)
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

// A game cooks what its project and its plugins pin from the store, and what a
// package was imported from inside a root stays behind. A peer with the
// project and none of its sources fails the cook by the name of each package
// it has no build of; once it fetched the builds alone, it ships the same
// files, which load as the runtime loads them, from the index of the cook.
@(test)
a_peer_with_only_fetched_builds_cooks_the_game_its_sources_cook :: proc(t:^testing.T) {
    top:=base.test_folder(t,"cook-library")
    if top=="" {return}
    defer free_all(context.temp_allocator)
    context.user_ptr=prefab.import_world(t)
    game:=fmt.tprintf("%s/game",top)
    plugin:=fmt.tprintf("%s/plugins/brushes",game)
    os.make_directory_all(fmt.tprintf("%s/assets/props",game))
    os.make_directory_all(fmt.tprintf("%s/assets",plugin))
    box:=box_source(fmt.tprintf("%s/assets/props",game),"box.gltf","Wood","Paint")
    brush:=fmt.tprintf("%s/assets/soft.png",plugin)
    testing.expect(t,os.write_entire_file(brush,png_bytes(8,8,{200,40,40}))==nil)
    here:=test_store(t,fmt.tprintf("%s/here",top))
    if here==nil {return}
    names:=make([dynamic]string,context.temp_allocator)
    for pinned in ([2][3]string{{game,box,"props"},{plugin,brush,""}}) {
        options:=Library_Options{store=here,root=pinned[0],plugins=test_library}
        report,error:=ingest(pinned[1],options,allocator=context.temp_allocator)
        if !testing.expectf(t,error.code==.None,"%s: %s",pinned[1],error.message) {return}
        p,_:=asset.package_get(here,report.manifest,context.temp_allocator)
        append(&names,p.name)
        added:=project_add(pinned[0],report.manifest,pinned[2],nil,options,context.temp_allocator)
        testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added)
    }
    cook :: proc(root:string,s:^store.Store,output:string) -> build.Cook_Report {
        plugins:=[1]project.Asset_Folder{{path=fmt.tprintf("%s/plugins/brushes/assets",root),prefix="plugins/brushes",root=fmt.tprintf("%s/plugins/brushes",root)}}
        return build.cook_assets({assets=fmt.tprintf("%s/assets",root),output=output,root=root,store=s,plugins=plugins[:],allocator=context.temp_allocator})
    }
    shipped:=cook(game,here,fmt.tprintf("%s/shipped",top))
    if !testing.expectf(t,shipped.error==.None,"%v %s",shipped.error,shipped.detail) {return}
    paths:=make(map[string]bool,context.temp_allocator)
    for file in shipped.files {paths[file.path]=true}
    testing.expectf(t,paths["plugins/brushes/soft.tex"] && paths["props/Box.mesh"] && paths["props/wood.tex"],"the outputs of the packages ship: %v",paths)
    testing.expectf(t,!paths["plugins/brushes/soft.png"] && !paths["props/box.gltf"] && !paths["props/wood.png"],"their sources stay behind: %v",paths)

    // A peer: the project and its plugin without their sources, and a store of its own.
    peer:=fmt.tprintf("%s/peer",top)
    folder_copy(game,peer)
    for source in ([3]string{"assets/props/box.gltf","assets/props/wood.png","plugins/brushes/assets/soft.png"}) {testing.expect(t,os.remove(fmt.tprintf("%s/%s",peer,source))==nil)}
    there:=test_store(t,fmt.tprintf("%s/there",top))
    if there==nil {return}
    lacking:=cook(peer,there,fmt.tprintf("%s/lacking",top))
    testing.expect_value(t,lacking.error,build.Cook_Error.Package_Missing)
    for name in names {testing.expectf(t,strings.contains(lacking.detail,name),"the package %s is named: %s",name,lacking.detail)}
    for root in ([2]string{peer,fmt.tprintf("%s/plugins/brushes",peer)}) {
        fetched:=project_refresh(root,{store=there,root=root,source=cache.store_source(here)},context.temp_allocator)
        testing.expectf(t,fetched.fetched==1 && fetched.ingested==0 && len(fetched.failures)==0 && len(fetched.missing)==0,"%v",fetched)
    }
    output:=fmt.tprintf("%s/again",top)
    again:=cook(peer,there,output)
    if !testing.expectf(t,again.error==.None,"%v %s",again.error,again.detail) {return}
    testing.expect_value(t,len(again.files),len(shipped.files))
    indexed:asset.Registry
    asset.registry_init(&indexed,output);defer asset.registry_destroy(&indexed)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    for file,at in again.files {
        if !testing.expect_value(t,file.path,shipped.files[at].path) {continue}
        first,_:=os.read_entire_file(fmt.tprintf("%s/shipped/%s",top,file.path),context.temp_allocator)
        second,_:=os.read_entire_file(fmt.tprintf("%s/%s",output,file.path),context.temp_allocator)
        testing.expectf(t,len(first)>0 && slice.equal(first,second),"%s ships as the machine with its source ships it",file.path)
        if file.id=={} {continue}
        listed,found:=asset.registry_find(&indexed,file.id)
        testing.expectf(t,found && listed.path==file.path,"the index has %s",file.path)
        a:asset.Asset
        if testing.expectf(t,asset.asset_load(&a,fmt.tprintf("%s/%s",output,file.path),context.temp_allocator)==.None,"%s loads",file.path) {asset.asset_close(&a)}
    }
}

// A refresh takes the builds its store lacks from a second store, as the
// installed engine does from the store of the builds of its plugins: with
// the source gone, mirai import --refresh --from copies them and imports nothing.
@(test)
a_refresh_takes_the_builds_of_a_second_store_without_their_sources :: proc(t:^testing.T) {
    top:=base.test_folder(t,"refresh-from")
    if top=="" {return}
    defer free_all(context.temp_allocator)
    plugin:=fmt.tprintf("%s/plugin",top)
    os.make_directory_all(fmt.tprintf("%s/assets",plugin))
    brush:=fmt.tprintf("%s/assets/soft.png",plugin)
    testing.expect(t,os.write_entire_file(brush,png_bytes(8,8,{40,200,40}))==nil)
    bundled_folder,machine_folder:=fmt.tprintf("%s/engine/builds",top),fmt.tprintf("%s/machine",top)
    bundled:=test_store(t,bundled_folder)
    if bundled==nil {return}
    options:=Library_Options{store=bundled,root=plugin}
    report,error:=ingest(brush,options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=project_add(plugin,report.manifest,"",nil,options,context.temp_allocator)
    testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added)
    testing.expect(t,os.remove(brush)==nil)

    out,errors:=strings.builder_make(context.temp_allocator),strings.builder_make(context.temp_allocator)
    code:=command({"--refresh",plugin,"--store",machine_folder,"--from",bundled_folder},strings.to_writer(&out),strings.to_writer(&errors))
    testing.expectf(t,code==0 && strings.contains(strings.to_string(out),"1 builds fetched"),"%d\n%s%s",code,strings.to_string(out),strings.to_string(errors))
    machine:=test_store(t,machine_folder)
    if machine==nil {return}
    resolved,resolve_error:=asset.root_packages_in(machine,plugin,context.temp_allocator)
    testing.expectf(t,resolve_error==.None && len(resolved.problems)==0 && len(resolved.listed)==1 && resolved.listed[0].state==.Built,"%v",resolved)
    testing.expect(t,!os.exists(brush),"nothing is written where the source was")
}
