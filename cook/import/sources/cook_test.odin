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

// Dev cooks can use a Fast texture as it is. A release refresh encodes it
// from its cached input with the id it has, and a release cook requires Final.
@(test)
dev_cooks_a_fast_texture_and_release_finalizes_it :: proc(t:^testing.T) {
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

    kept:=project_refresh(folder,fast,context.temp_allocator)
    testing.expectf(t,kept.ingested==0 && len(kept.failures)==0 && len(kept.missing)==0,"Fast is current for dev: %v",kept)
    cook_manifest:=fmt.tprintf("%s/%s",folder,build.COOK_FILE)
    testing.expect(t,os.write_entire_file(cook_manifest,`{"roots":["noise.tex"]}`)==nil)
    dev:=build.cook_assets({assets=assets,output=fmt.tprintf("%s/dev",folder),manifest=cook_manifest,root=folder,store=s,quick=true,allocator=context.temp_allocator})
    if !testing.expectf(t,dev.error==.None,"%v %s",dev.error,dev.detail) {return}
    dev_id,dev_flags,dev_blocks:=level_of(t,&types,fmt.tprintf("%s/dev/noise.tex",folder))
    testing.expect(t,dev_id==fast_id && .Fast in dev_flags && slice.equal(dev_blocks,fast_blocks),"dev preserves Fast blocks")

    report:=build.cook_assets({assets=assets,output=fmt.tprintf("%s/program",folder),manifest=cook_manifest,root=folder,store=s,allocator=context.temp_allocator})
    testing.expectf(t,report.error==.Source_Failed && strings.contains(report.detail,"noise") && strings.contains(report.detail,"mirai build game --release"),"%v %s",report.error,report.detail)
    refreshed:=project_refresh(folder,final_options,context.temp_allocator)
    testing.expectf(t,refreshed.ingested==0 && len(refreshed.failures)==0 && len(refreshed.missing)==0,"%v",refreshed)
    kept=project_refresh(folder,fast,context.temp_allocator)
    testing.expectf(t,kept.ingested==0 && len(kept.failures)==0,"Final is also current for dev: %v",kept)
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
    // Nor the files of their manifests: the source gives each by the hash its pin names.
    for root in ([2]string{peer,fmt.tprintf("%s/plugins/brushes",peer)}) {
        pins,_,_:=asset.packages_load(root,context.temp_allocator)
        for entry in pins.packages {testing.expect(t,os.remove(asset.package_file(root,entry.id))==nil)}
    }
    there:=test_store(t,fmt.tprintf("%s/there",top))
    if there==nil {return}
    lacking:=cook(peer,there,fmt.tprintf("%s/lacking",top))
    testing.expect_value(t,lacking.error,build.Cook_Error.Package_Missing)
    testing.expectf(t,strings.contains(lacking.detail,"neither in the store"),"the package is named: %s",lacking.detail)
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

// A build made under the key of a package by another ingest (one that lacked
// content it reads, such as an engine's) lacks assets of the manifest the
// project pins: no refresh takes it, from the store or from a peer, and a peer
// whose build under the key is that one gives the build it chose for the
// manifest instead.
@(test)
a_refresh_takes_no_build_that_lacks_assets_of_its_manifest :: proc(t:^testing.T) {
    top:=base.test_folder(t,"refresh-degraded")
    if top=="" {return}
    defer free_all(context.temp_allocator)
    context.user_ptr=prefab.import_world(t)
    game:=fmt.tprintf("%s/game",top)
    os.make_directory_all(fmt.tprintf("%s/assets/props",game))
    box:=box_source(fmt.tprintf("%s/assets/props",game),"box.gltf","Wood","Paint")
    host:=test_store(t,fmt.tprintf("%s/host",top))
    if host==nil {return}
    options:=Library_Options{store=host,root=game,plugins=test_library}
    report,error:=ingest(box,options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=project_add(game,report.manifest,"props",nil,options,context.temp_allocator)
    if !testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added) {return}
    if !testing.expect(t,report.final,"the build is Final") {return}

    // The peer keeps, under the key, a build without the texture.
    complete,_:=asset.build_get(host,report.build,context.temp_allocator)
    degraded:=complete
    degraded.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    for o in complete.outputs {
        if o.kind!=asset.KIND_TEXTURE {append(&degraded.outputs,o)}
    }
    if !testing.expect(t,len(degraded.outputs)<len(complete.outputs),"the build has a texture") {return}
    stale,put_error:=asset.build_put(host,&degraded)
    if !testing.expect_value(t,put_error,asset.Error.None) {return}
    digits,key_digits:[64]u8
    key:=store.hex(report.key,&key_digits)
    testing.expect_value(t,store.ref_set(host,asset.REF_IMPORTS,key,stale),store.Error.None)

    peer:=fmt.tprintf("%s/peer",top)
    folder_copy(game,peer)
    for source in ([2]string{"assets/props/box.gltf","assets/props/wood.png"}) {testing.expect(t,os.remove(fmt.tprintf("%s/%s",peer,source))==nil)}
    here:=test_store(t,fmt.tprintf("%s/here",top))
    if here==nil {return}
    from:=cache.store_source(host)
    for namespace in ([2]string{asset.REF_MANIFESTS,asset.REF_IMPORTS}) {
        pins,_,_:=asset.packages_load(peer,context.temp_allocator)
        name:=key if namespace==asset.REF_IMPORTS else store.hex(pins.packages[0].manifest,&digits)
        names:=[1]string{name}
        status:=[1]cache.Fetch_Status{}
        from.fetch(from.user,here,namespace,names[:],status[:])
        testing.expectf(t,status[0]==.Taken,"this machine keeps %s/%s",namespace,name)
    }
    alone:=project_refresh(peer,{store=here,root=peer},context.temp_allocator)
    testing.expectf(t,len(alone.missing)==1 && alone.fetched==0,"the build here lacks the texture: %v",alone)

    taken:=project_refresh(peer,{store=here,root=peer,source=from},context.temp_allocator)
    testing.expectf(t,taken.fetched==1 && len(taken.missing)==0 && len(taken.failures)==0,"%v",taken)
    held,_:=store.ref_get(here,asset.REF_IMPORTS,key)
    testing.expect_value(t,held,report.build)
    pins,_,_:=asset.packages_load(peer,context.temp_allocator)
    p,_:=asset.package_get(here,pins.packages[0].manifest,context.temp_allocator)
    chosen,_:=store.ref_get(here,asset.REF_BUILDS,store.hex(asset.build_select(pins.packages[0].manifest,&p),&digits))
    testing.expect_value(t,chosen,report.build)
    again:=project_refresh(peer,{store=here,root=peer},context.temp_allocator)
    testing.expectf(t,again.fetched==0 && len(again.missing)==0 && len(again.failures)==0,"%v",again)
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

// A source that could not answer for a build (no peer reached, a transfer
// cut) may hold it: the refresh says so, imports nothing from the source here
// and keeps no miss of it, so a later refresh takes the build; a source that
// answered none sends the refresh to the source here.
@(test)
a_build_a_source_could_not_answer_for_is_no_miss :: proc(t:^testing.T) {
    top:=base.test_folder(t,"refresh-failed")
    if top=="" {return}
    defer free_all(context.temp_allocator)
    game:=fmt.tprintf("%s/game",top)
    os.make_directory_all(fmt.tprintf("%s/assets",game))
    brush:=fmt.tprintf("%s/assets/soft.png",game)
    testing.expect(t,os.write_entire_file(brush,png_bytes(8,8,{40,200,40}))==nil)
    host:=test_store(t,fmt.tprintf("%s/host",top))
    if host==nil {return}
    options:=Library_Options{store=host,root=game}
    report,error:=ingest(brush,options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=project_add(game,report.manifest,"",nil,options,context.temp_allocator)
    if !testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added) {return}
    // A second store holds the build; this one only the package and its source.
    peer:=test_store(t,fmt.tprintf("%s/peer",top))
    if peer==nil {return}
    digits,select_digits:[64]u8
    key:=store.hex(report.key,&digits)
    names:=[1]string{key}
    status:=[1]cache.Fetch_Status{}
    cache.store_source(host).fetch(host,peer,asset.REF_IMPORTS,names[:],status[:])
    if !testing.expect_value(t,status[0],cache.Fetch_Status.Taken) {return}
    p,_:=asset.package_get(host,report.manifest,context.temp_allocator)
    testing.expect_value(t,store.ref_remove(host,asset.REF_IMPORTS,key),store.Error.None)
    testing.expect_value(t,store.ref_remove(host,asset.REF_BUILDS,store.hex(asset.build_select(report.manifest,&p),&select_digits)),store.Error.None)
    testing.expect_value(t,store.commit(host),store.Error.None)

    Answer :: struct {status:cache.Fetch_Status,calls:int}
    answering :: proc(answer:^Answer) -> cache.Source {
        return {fetch=proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,status:[]cache.Fetch_Status) {
            a:=(^Answer)(user)
            a.calls+=1
            for &x in status {x=a.status}
        },user=answer}
    }
    failing:=Answer{status=.Failed}
    cut:=project_refresh(game,{store=host,root=game,source=answering(&failing)},context.temp_allocator)
    testing.expectf(t,len(cut.failures)==1 && strings.contains(cut.failures[0],"could not be fetched from the org's peers") && cut.ingested==0 && cut.fetched==0,"%v",cut)
    testing.expectf(t,failing.calls>0,"the source was asked")
    // Nothing kept a miss: a source that answers gives the build.
    taken:=project_refresh(game,{store=host,root=game,source=cache.store_source(peer)},context.temp_allocator)
    testing.expectf(t,taken.fetched==1 && taken.ingested==0 && len(taken.failures)==0 && len(taken.missing)==0,"%v",taken)
    // One that answers none sends the refresh to the source here.
    testing.expect_value(t,store.ref_remove(host,asset.REF_IMPORTS,key),store.Error.None)
    store.ref_remove(host,asset.REF_BUILDS,store.hex(asset.build_select(report.manifest,&p),&select_digits))
    testing.expect_value(t,store.commit(host),store.Error.None)
    missing:=Answer{status=.Missing}
    built:=project_refresh(game,{store=host,root=game,source=answering(&missing)},context.temp_allocator)
    testing.expectf(t,built.ingested==1 && len(built.failures)==0 && len(built.missing)==0,"%v",built)
}

@(test)
reingesting_a_source_keeps_its_package_objects :: proc(t:^testing.T) {
    top:=base.test_folder(t,"refresh-codecs")
    if top=="" {return}
    defer free_all(context.temp_allocator)
    plugin:=fmt.tprintf("%s/plugin",top)
    os.make_directory_all(fmt.tprintf("%s/assets",plugin))
    brush:=fmt.tprintf("%s/assets/soft.png",plugin)
    testing.expect(t,os.write_entire_file(brush,png_bytes(64,64,{40,200,40}))==nil)
    host:=test_store(t,fmt.tprintf("%s/host",top))
    other:=test_store(t,fmt.tprintf("%s/other",top))
    if host==nil || other==nil {return}
    options:=Library_Options{store=host,root=plugin}
    report,error:=ingest(brush,options,allocator=context.temp_allocator)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    added:=project_add(plugin,report.manifest,"",nil,options,context.temp_allocator)
    testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added)
    // Rebuild from source in a separate store.
    again:=project_refresh(plugin,{store=other,root=plugin},context.temp_allocator)
    testing.expectf(t,len(again.missing)==0 && len(again.failures)==0,"%v",again)
    digits:[64]u8
    key:=store.hex(report.key,&digits)
    namespace:=asset.REF_IMPORTS if report.final else asset.REF_IMPORTS_FAST
    mine,_:=asset.build_get(host,report.build,context.temp_allocator)
    theirs_ref,ref_error:=store.ref_get(other,namespace,key)
    if !testing.expect_value(t,ref_error,store.Error.None) {return}
    theirs,_:=asset.build_get(other,theirs_ref,context.temp_allocator)
    testing.expect_value(t,theirs_ref,report.build)
    if testing.expect_value(t,len(theirs.outputs),len(mine.outputs)) {
        for o,at in mine.outputs {testing.expectf(t,theirs.outputs[at].object==o.object,"output %d is the same object",at)}
    }
    // A peer of this build takes the build from the other, whose frames it cannot decode.
    testing.expect(t,os.remove(brush)==nil)
    peer:=test_store(t,fmt.tprintf("%s/peer",top))
    if peer==nil {return}
    fetched:=project_refresh(plugin,{store=peer,root=plugin,source=cache.store_source(other)},context.temp_allocator)
    testing.expectf(t,fetched.fetched==1 && len(fetched.missing)==0 && len(fetched.failures)==0,"%v",fetched)
    for o in mine.outputs {
        a:asset.Asset
        testing.expect_value(t,asset.asset_open_object(&a,peer,o.object,context.temp_allocator),asset.Error.None)
        testing.expect_value(t,asset.asset_object_settle(&a),asset.Error.None)
        asset.asset_close(&a)
    }
}

// Release refresh needs Final and reports the package by name until the peer
// has it: the Fast build the peer chose, which it asks for, is kept and never
// cooked. Dev refresh takes that Fast build without importing.
@(test)
a_release_cook_never_takes_a_fast_build_a_source_holds :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    top:=base.test_folder(t,"cook-fast-source")
    if top=="" {return}
    defer free_all(context.temp_allocator)
    game:=fmt.tprintf("%s/game",top)
    os.make_directory_all(fmt.tprintf("%s/assets",game))
    poster:=fmt.tprintf("%s/assets/poster.png",game)
    testing.expect(t,os.write_entire_file(poster,png_bytes(8,8,{30,60,220}))==nil)
    host:=test_store(t,fmt.tprintf("%s/host",top))
    if host==nil {return}
    fast_options:=Library_Options{store=host,root=game,fast_textures=true}
    quick,quick_error:=ingest(poster,fast_options,allocator=context.temp_allocator)
    if !testing.expectf(t,quick_error.code==.None,"%s",quick_error.message) {return}
    added:=project_add(game,quick.manifest,"",nil,fast_options,context.temp_allocator)
    if !testing.expectf(t,len(added.failures)==0 && len(added.missing)==0,"%v",added) {return}
    testing.expect(t,!quick.final,"the host holds a Fast build alone")
    p,_:=asset.package_get(host,quick.manifest,context.temp_allocator)

    peer:=fmt.tprintf("%s/peer",top)
    folder_copy(game,peer)
    testing.expect(t,os.remove(fmt.tprintf("%s/assets/poster.png",peer))==nil)
    here:=test_store(t,fmt.tprintf("%s/here",top))
    if here==nil {return}
    cook :: proc(root:string,s:^store.Store,output:string) -> build.Cook_Report {
        manifest:=fmt.tprintf("%s/%s",root,build.COOK_FILE)
        _=os.write_entire_file(manifest,`{"roots":["poster.tex"]}`)
        return build.cook_assets({assets=fmt.tprintf("%s/assets",root),output=output,manifest=manifest,root=root,store=s,allocator=context.temp_allocator})
    }
    digits:[64]u8
    key:=store.hex(quick.key,&digits)
    from:=cache.store_source(host)
    final:=project_refresh(peer,{store=here,root=peer,source=from},context.temp_allocator)
    testing.expectf(t,final.fetched==0 && len(final.missing)==1 && strings.contains(final.missing[0],fmt.tprintf("package %s",p.name)),"%v",final)
    _,asked:=store.ref_get(here,asset.REF_IMPORTS_FAST,key)
    testing.expect_value(t,asked,store.Error.Missing)
    lacking:=cook(peer,here,fmt.tprintf("%s/lacking",top))
    testing.expectf(t,lacking.error==.Source_Failed && strings.contains(lacking.detail,p.name),"%v %s",lacking.error,lacking.detail)

    taken:=project_refresh(peer,{store=here,root=peer,source=from,fast_textures=true},context.temp_allocator)
    testing.expectf(t,taken.fetched==0 && taken.ingested==0 && len(taken.missing)==0 && len(taken.failures)==0,"%v",taken)
    _,mirrored:=store.ref_get(here,asset.REF_IMPORTS_FAST,key)
    testing.expect_value(t,mirrored,store.Error.None)
    refused:=cook(peer,here,fmt.tprintf("%s/refused",top))
    testing.expectf(t,refused.error==.Source_Failed && strings.contains(refused.detail,p.name),"a Fast build taken is not shipped: %v %s",refused.error,refused.detail)
    still:=project_refresh(peer,{store=here,root=peer,source=from},context.temp_allocator)
    testing.expectf(t,len(still.missing)==1 && strings.contains(still.missing[0],"only a build with Fast textures is here"),"%v",still)

    shipped_report,shipped_error:=ingest(poster,{store=host,root=game},allocator=context.temp_allocator)
    if !testing.expectf(t,shipped_error.code==.None,"%s",shipped_error.message) {return}
    testing.expect(t,shipped_report.final && shipped_report.key==quick.key,"the host builds the Final of the same key")
    fetched:=project_refresh(peer,{store=here,root=peer,source=from},context.temp_allocator)
    testing.expectf(t,fetched.fetched==1 && fetched.ingested==0 && len(fetched.missing)==0 && len(fetched.failures)==0,"%v",fetched)
    output:=fmt.tprintf("%s/game-out",top)
    shipped:=cook(peer,here,output)
    if !testing.expectf(t,shipped.error==.None,"%v %s",shipped.error,shipped.detail) {return}
    textures_shipped:=0
    for file in shipped.files {
        a:asset.Asset
        if asset.asset_load(&a,fmt.tprintf("%s/%s",output,file.path),context.temp_allocator)!=.None {continue}
        if view,error:=asset.texture_view(&a,&types);error==.None {
            textures_shipped+=1
            testing.expectf(t,.Fast not_in view.info.flags,"%s ships Final",file.path)
        }
    }
    testing.expect(t,textures_shipped>0,"the texture ships")
}

@(test)
a_final_refresh_keeps_the_outputs_of_a_current_whole_source :: proc(t:^testing.T) {
    for settings in ([2]importer.Import_Settings{{textures=.Uncompressed},{rdo_lambda=12}}) {
        settings:=settings
        root,assets:=test_project(t,"cook-whole")
        if root=="" {return}
        box_source(assets,"crate.gltf","Wood","Paint")
        level:=write_text(assets,"hall.level","LEVEL crate.gltf")
        state:=Level_Importer{kit=2}
        s:=test_store(t,fmt.tprintf("%s/store",root))
        if s==nil {return}
        wholes:=[1]Whole_Source{{name=LEVEL_IMPORTER,claims=level_claims,run=level_run,state=&state}}
        imports:=Library_Imports{wholes=wholes[:]}
        options:=Library_Options{store=s,root=root,imports=&imports,fast_textures=true}
        quick,import_error:=ingest(level,options,&settings,context.temp_allocator)
        if !testing.expectf(t,import_error.code==.None,"%s",import_error.message) {return}
        fast,read_error:=asset.build_get(s,quick.build,context.temp_allocator)
        if !testing.expect_value(t,read_error,asset.Error.None) {return}
        testing.expect_value(t,fast.final,settings.textures==.Uncompressed)
        digits:[64]u8
        key:=store.hex(quick.key,&digits)
        if fast.final {
            // A build classified as Fast even though all its textures are ready to ship.
            fast.final=false
            object,put_error:=asset.build_put(s,&fast)
            if !testing.expect_value(t,put_error,asset.Error.None) {return}
            testing.expect_value(t,store.ref_set(s,asset.REF_IMPORTS_FAST,key,object),store.Error.None)
            testing.expect_value(t,store.ref_remove(s,asset.REF_IMPORTS,key),store.Error.None)
        }
        if !report_clean(t,project_add(root,quick.manifest,"",nil,options,context.temp_allocator)) {return}

        options.fast_textures=false
        refresh:=project_refresh(root,options,context.temp_allocator)
        if !report_clean(t,refresh) {return}
        testing.expect_value(t,refresh.ingested,0)
        testing.expect_value(t,state.runs,1)
        address,ref_error:=store.ref_get(s,asset.REF_IMPORTS,key)
        if !testing.expect_value(t,ref_error,store.Error.None) {return}
        final,error:=asset.build_get(s,address,context.temp_allocator)
        if !testing.expect_value(t,error,asset.Error.None) {return}
        testing.expect(t,final.final)
        if !testing.expect_value(t,len(final.outputs),len(fast.outputs)) {return}
        for output,at in fast.outputs {
            if output.kind==asset.KIND_TEXTURE && settings.textures!=.Uncompressed {
                testing.expect(t,final.outputs[at].object!=output.object)
            } else {
                testing.expect_value(t,final.outputs[at],output)
            }
        }

        options.rebuild=true
        clean,clean_error:=ingest(level,options,nil,context.temp_allocator)
        if !testing.expectf(t,clean_error.code==.None,"%s",clean_error.message) {return}
        testing.expect_value(t,clean.manifest,quick.manifest)
        testing.expect_value(t,clean.build,address)
    }
}
