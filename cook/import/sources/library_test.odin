package sources

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "mirai:asset"
import "mirai:cook/prefab"
import importer "mirai:cook/import"
import "mirai:std/base"
import "mirai:store"

// The files under folder, by their paths under it, in the temp allocator.
@(private="file")
files_of :: proc(folder:string) -> map[string]bool {
    files:=make(map[string]bool,context.temp_allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,folder)
    for next:=0;next<len(todo);next+=1 {
        entries,_:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
        for entry in entries {
            path:=fmt.tprintf("%s/%s",todo[next],entry.name)
            if entry.type==.Directory {append(&todo,path)} else {files[path[len(folder):]]=true}
        }
    }
    return files
}

// Copies the files under from to the same paths under to.
@(private="file")
folder_copy :: proc(from,to:string) {
    for file in files_of(from) {
        target:=fmt.tprintf("%s%s",to,file)
        os.make_directory_all(filepath.dir(target))
        data,_:=os.read_entire_file(fmt.tprintf("%s%s",from,file),context.temp_allocator)
        _=os.write_entire_file(target,data)
    }
}

// What the project at root lists from the store s, by path.
@(private="file")
listed_of :: proc(t:^testing.T,s:^store.Store,root:string,loc:=#caller_location) -> (listed:map[string]asset.Package_Listed) {
    listed=make(map[string]asset.Package_Listed,context.temp_allocator)
    list,_,error:=asset.packages_load(root,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None,loc=loc) {return}
    resolved,resolve_error:=asset.packages_resolve(s,root,&list,context.temp_allocator)
    if !testing.expect_value(t,resolve_error,asset.Error.None,loc=loc) {return}
    testing.expectf(t,len(resolved.problems)==0,"%v",resolved.problems[:],loc=loc)
    for l in resolved.listed {listed[l.path]=l}
    return
}

// Every ref of the namespaces of builds of s, removed: what an engine whose
// versions changed finds of them.
@(private="file")
builds_forget :: proc(s:^store.Store) {
    for namespace in ([3]string{asset.REF_IMPORTS,asset.REF_IMPORTS_FAST,asset.REF_BUILDS}) {
        refs,_:=store.ref_list(s,namespace,context.temp_allocator)
        for ref in refs {store.ref_remove(s,namespace,ref.name)}
    }
}

@(private="file")
report_clean :: proc(t:^testing.T,report:Library_Report,loc:=#caller_location) -> bool {
    return testing.expectf(t,len(report.failures)==0 && len(report.missing)==0,"failures %v, missing %v",report.failures[:],report.missing[:],loc=loc)
}

@(private="file")
ingested :: proc(t:^testing.T,source:string,options:Library_Options,loc:=#caller_location) -> (report:importer.Import_Report,ok:bool) {
    error:importer.Error
    report,error=ingest(source,options,allocator=context.temp_allocator)
    ok=testing.expectf(t,error.code==.None,"%s: %s",source,error.message,loc=loc)
    return
}

// A project pins its packages by manifest: a peer with the project and none
// of its sources fetches their builds from a store that has them, lists and
// loads them, and imports nothing. Without such a store it says, for each
// package, what gives it, and neither removes a file nor builds anything.
@(test)
a_peer_without_sources_lists_and_loads_and_nothing_is_removed_or_built :: proc(t:^testing.T) {
    top:=base.test_folder(t,"library-peer")
    if top=="" {return}
    context.user_ptr=prefab.import_world(t)
    downloads,game:=fmt.tprintf("%s/downloads",top),fmt.tprintf("%s/game",top)
    os.make_directory_all(downloads)
    os.make_directory_all(fmt.tprintf("%s/assets",game))
    box:=box_source(downloads,"box.gltf","Wood","Paint")
    sign:=fmt.tprintf("%s/sign.png",downloads)
    _=os.write_entire_file(sign,png_bytes(8,8,{200,40,40}))
    here:=test_store(t,fmt.tprintf("%s/here",top))
    if here==nil {return}
    options:=Library_Options{store=here,root=game,plugins=test_library}
    for source in ([2]string{box,sign}) {
        report,ok:=ingested(t,source,options)
        if !ok {return}
        added:=project_add(game,report.manifest,"props",nil,options,context.temp_allocator)
        if !report_clean(t,added) {return}
    }
    listed:=listed_of(t,here,game)
    _,has_mesh:=listed["props/Box.mesh"]
    _,has_sign:=listed["props/sign.tex"]
    testing.expectf(t,has_mesh && has_sign,"the cache of both is listed under their folder: %v",listed)

    // A peer: the project, not its sources, and a store of its own.
    testing.expect(t,os.rename(downloads,fmt.tprintf("%s/moved",top))==nil)
    peer:=fmt.tprintf("%s/peer",top)
    folder_copy(game,peer)
    there:=test_store(t,fmt.tprintf("%s/there",top))
    if there==nil {return}
    alone:=options
    alone.store,alone.root=there,peer
    before:=files_of(peer)
    lacking:=project_refresh(peer,alone,context.temp_allocator)
    testing.expectf(t,len(lacking.missing)==2 && len(lacking.failures)==0 && lacking.ingested==0 && lacking.fetched==0,"%v",lacking)
    list,_,_:=asset.packages_load(peer,context.temp_allocator)
    for &entry in list.packages {
        // The project carries its manifests: each package is named by its name.
        p,_:=asset.package_get(here,entry.manifest,context.temp_allocator)
        named:=false
        for line in lacking.missing {named||=strings.contains(line,fmt.tprintf("package %s:",p.name))}
        testing.expectf(t,named,"the package %s is named: %v",p.name,lacking.missing[:])
    }
    builds,_:=store.ref_list(there,asset.REF_BUILDS,context.temp_allocator)
    testing.expect(t,len(builds)==0,"nothing is built")
    after:=files_of(peer)
    testing.expect_value(t,len(after),len(before))
    for file in before {testing.expectf(t,after[file],"%s stays",file)}

    // With a store that has them, the builds are fetched: listed where the project lists them, loaded.
    fetching:=alone
    fetching.source=copy_source(here)
    fetched:=project_refresh(peer,fetching,context.temp_allocator)
    testing.expectf(t,fetched.fetched==2 && fetched.ingested==0,"%v",fetched)
    if !report_clean(t,fetched) {return}
    seen:=listed_of(t,there,peer)
    testing.expect_value(t,len(seen),len(listed))
    for path,l in listed {
        other,found:=seen[path]
        if !testing.expectf(t,found && other.id==l.id && other.state==.Built,"%s is listed with its id",path) {continue}
        a:asset.Asset
        if testing.expectf(t,asset.asset_load(&a,other.file,context.temp_allocator)==.None,"%s loads",path) {
            testing.expect_value(t,a.blob.header.id,l.id)
            asset.asset_close(&a)
        }
    }
    for file in before {testing.expectf(t,os.exists(fmt.tprintf("%s%s",peer,file)),"%s stays",file)}
    again:=project_refresh(peer,alone,context.temp_allocator)
    testing.expectf(t,again.fetched==0 && again.ingested==0,"then nothing is asked for: %v",again)
    report_clean(t,again)
}

// A source outside any project is ingested where it is: nothing is written
// beside it, two projects that add it list the same blobs, ingesting it again
// imports nothing, and once it changed it is another manifest of the same
// package with the same ids, which a project follows on its refresh.
@(test)
a_source_outside_any_project_ingests_and_two_projects_use_the_same_blobs :: proc(t:^testing.T) {
    top:=base.test_folder(t,"library-outside")
    if top=="" {return}
    context.user_ptr=prefab.import_world(t)
    downloads:=fmt.tprintf("%s/downloads",top)
    os.make_directory_all(downloads)
    box:=box_source(downloads,"box.gltf","Wood","Paint")
    s:=test_store(t,fmt.tprintf("%s/store",top))
    if s==nil {return}
    options:=Library_Options{store=s,plugins=test_library}
    first,ok:=ingested(t,box,options)
    if !ok {return}
    testing.expect(t,len(first.assets)>0 && first.prefab_path=="","its cache and documents are blobs; the prefab is a project's")
    testing.expect_value(t,len(files_of(downloads)),2)
    again,again_ok:=ingested(t,box,options)
    testing.expect(t,again_ok && len(again.assets)==0 && again.manifest==first.manifest && again.package_id==first.package_id,"current: nothing is imported again")

    projects:=[2]string{fmt.tprintf("%s/one",top),fmt.tprintf("%s/two",top)}
    lists:[2]map[string]asset.Package_Listed
    for project,at in projects {
        os.make_directory_all(fmt.tprintf("%s/assets",project))
        o:=options
        o.root=project
        if !report_clean(t,project_add(project,first.manifest,"props",nil,o,context.temp_allocator)) {return}
        lists[at]=listed_of(t,s,project)
        p,_:=asset.package_get(s,first.manifest,context.temp_allocator)
        r:asset.Registry
        asset.registry_init(&r,fmt.tprintf("%s/assets",project),"",context.temp_allocator)
        asset.registry_scan(&r)
        for a in p.assets {
            if asset.import_cached(a.kind) {continue}
            _,found:=asset.registry_find(&r,a.id)
            testing.expectf(t,found,"%s: the document %s, the prefab among them, is a file of the project with its id",project,a.name)
        }
    }
    testing.expect(t,len(lists[0])>0 && len(lists[0])==len(lists[1]))
    for path,l in lists[0] {testing.expectf(t,lists[1][path].file==l.file,"%s is the same blob for both",path)}

    box_source(downloads,"box.gltf","Wood","Paint","0.9")
    changed,changed_ok:=ingested(t,box,options)
    if !changed_ok {return}
    testing.expect(t,changed.manifest!=first.manifest && changed.package_id==first.package_id,"a changed source is another manifest of its package")
    was,_:=asset.package_get(s,first.manifest,context.temp_allocator)
    now,_:=asset.package_get(s,changed.manifest,context.temp_allocator)
    testing.expect_value(t,len(now.assets),len(was.assets))
    for a in was.assets {
        kept:=false
        for b in now.assets {kept||=b.id==a.id && b.kind==a.kind && b.name==a.name}
        testing.expectf(t,kept,"%s keeps its id",a.name)
    }
    o:=options
    o.root=projects[0]
    followed:=project_refresh(projects[0],o,context.temp_allocator)
    report_clean(t,followed)
    list,_,_:=asset.packages_load(projects[0],context.temp_allocator)
    testing.expect(t,len(list.packages)==1 && list.packages[0].manifest==changed.manifest,"the project pins what its source is now")
}

// When the versions of the engine change, no build of a package is current:
// a machine with its source ingests it again, and one without it says which
// package needs it, by name. A build with Fast textures is not one a cook
// takes: where Final is required and only Fast is here, that is said too.
@(test)
an_engine_change_builds_again_where_the_source_is_and_is_reported_by_name_elsewhere :: proc(t:^testing.T) {
    top:=base.test_folder(t,"library-engine")
    if top=="" {return}
    downloads,game:=fmt.tprintf("%s/downloads",top),fmt.tprintf("%s/game",top)
    os.make_directory_all(downloads)
    os.make_directory_all(fmt.tprintf("%s/assets",game))
    sign:=fmt.tprintf("%s/billboard.png",downloads)
    _=os.write_entire_file(sign,png_bytes(8,8,{200,40,40}))
    here:=test_store(t,fmt.tprintf("%s/here",top))
    if here==nil {return}
    options:=Library_Options{store=here,root=game}
    first,ok:=ingested(t,sign,options)
    if !ok || !report_clean(t,project_add(game,first.manifest,"",nil,options,context.temp_allocator)) {return}
    current:=project_refresh(game,options,context.temp_allocator)
    testing.expectf(t,current.ingested==0 && current.fetched==0,"a current package is left alone: %v",current)

    builds_forget(here)
    rebuilt:=project_refresh(game,options,context.temp_allocator)
    testing.expectf(t,rebuilt.ingested==1,"%v",rebuilt)
    report_clean(t,rebuilt)
    _,has:=listed_of(t,here,game)["billboard.tex"]
    testing.expect(t,has)

    testing.expect(t,os.rename(downloads,fmt.tprintf("%s/moved",top))==nil)
    builds_forget(here)
    lacking:=project_refresh(game,options,context.temp_allocator)
    testing.expectf(t,lacking.ingested==0 && len(lacking.missing)==1 && strings.contains(lacking.missing[0],"package billboard") && strings.contains(lacking.missing[0],"must ingest it"),"%v",lacking.missing[:])
    _,listed:=listed_of(t,here,game)["billboard.tex"]
    testing.expect(t,listed,"what is not built is still listed, and nothing is removed")

    // Fast only, where Final is required: an image no Final of which was ever built.
    poster:=fmt.tprintf("%s/poster.png",top)
    _=os.write_entire_file(poster,png_bytes(8,8,{30,60,220}))
    fast:=options
    fast.fast_textures=true
    quick,quick_ok:=ingested(t,poster,fast)
    if !quick_ok || !report_clean(t,project_add(game,quick.manifest,"",nil,fast,context.temp_allocator)) {return}
    testing.expect(t,!quick.final,"a refresh that takes Fast builds Fast")
    testing.expect(t,os.remove(poster)==nil)
    final:=project_refresh(game,options,context.temp_allocator)
    testing.expectf(t,len(final.missing)==2 && strings.contains(strings.join(final.missing[:],"\n",context.temp_allocator),"package poster: only a build with Fast textures is here, and Final is required"),"%v",final.missing[:])
    testing.expectf(t,len(project_refresh(game,fast,context.temp_allocator).missing)==1,"with Fast taken only the billboard, whose source is gone, is missing")
}

// A root carries the manifests it pins: a copy of it elsewhere with its
// sources and an empty store refreshes into the same ids, manifests, build
// keys and blobs; a copy without its sources lists them not built and says so
// by package. Unpinning removes the manifest's file.
@(test)
a_copy_of_a_root_with_its_sources_and_an_empty_store_builds_the_same :: proc(t:^testing.T) {
    top:=base.test_folder(t,"library-clone")
    if top=="" {return}
    context.user_ptr=prefab.import_world(t)
    game:=fmt.tprintf("%s/game",top)
    props:=fmt.tprintf("%s/assets/props",game)
    os.make_directory_all(props)
    box:=box_source(props,"box.gltf","Wood","Paint")
    sign:=fmt.tprintf("%s/sign.png",props)
    _=os.write_entire_file(sign,png_bytes(8,8,{200,40,40}))
    here:=test_store(t,fmt.tprintf("%s/here",top))
    if here==nil {return}
    options:=Library_Options{store=here,root=game,plugins=test_library}
    keys:=make([dynamic]store.Hash,context.temp_allocator)
    for source in ([2]string{box,sign}) {
        report,added,error:=project_ingest(game,source,"props",options,allocator=context.temp_allocator)
        if !testing.expectf(t,error.code==.None,"%s",error.message) || !report_clean(t,added) {return}
        append(&keys,report.key)
    }
    pinned,_,_:=asset.packages_load(game,context.temp_allocator)
    testing.expect_value(t,len(pinned.packages),2)
    for &entry in pinned.packages {
        text,read_error:=os.read_entire_file(asset.package_file(game,entry.id),context.temp_allocator)
        testing.expectf(t,read_error==nil && store.address_of_bytes(text)==entry.manifest,"the root keeps the manifest it pins of %v",entry.id)
        p,_:=asset.package_get(here,entry.manifest,context.temp_allocator)
        testing.expectf(t,!strings.has_prefix(p.origin.path,"/") && strings.has_prefix(p.origin.path,"assets/props/"),"a source of the root is named from it: %s",p.origin.path)
    }
    blobs_of :: proc(t:^testing.T,s:^store.Store,root:string) -> map[string]store.Hash {
        out:=make(map[string]store.Hash,context.temp_allocator)
        for path,l in listed_of(t,s,root) {
            hash,_,_:=store.address_of_file(l.file)
            out[path]=hash
        }
        return out
    }
    before:=blobs_of(t,here,game)

    clone:=fmt.tprintf("%s/clone",top)
    folder_copy(game,clone)
    fresh:=test_store(t,fmt.tprintf("%s/fresh",top))
    if fresh==nil {return}
    again:=options
    again.store,again.root=fresh,clone
    refreshed:=project_refresh(clone,again,context.temp_allocator)
    testing.expectf(t,refreshed.ingested==2,"%v",refreshed)
    if !report_clean(t,refreshed) {return}
    cloned,_,_:=asset.packages_load(clone,context.temp_allocator)
    testing.expect_value(t,len(cloned.packages),len(pinned.packages))
    for entry,at in cloned.packages {
        testing.expectf(t,entry.id==pinned.packages[at].id && entry.manifest==pinned.packages[at].manifest,"the same package and manifest: %v",entry)
    }
    for key in keys {
        digits:[64]u8
        _,ref_error:=store.ref_get(fresh,asset.REF_IMPORTS,store.hex(key,&digits))
        testing.expectf(t,ref_error==.None,"the build has the key it had where it was ingested")
    }
    after:=blobs_of(t,fresh,clone)
    testing.expect_value(t,len(after),len(before))
    for path,hash in before {testing.expectf(t,after[path]==hash,"%s is the same blob",path)}

    // Without its sources nor a store that has them: listed, not built, said by package.
    bare:=fmt.tprintf("%s/bare",top)
    folder_copy(game,bare)
    for file in ([]string{"box.gltf","sign.png","wood.png"}) {os.remove(fmt.tprintf("%s/assets/props/%s",bare,file))}
    empty:=test_store(t,fmt.tprintf("%s/empty",top))
    if empty==nil {return}
    alone:=options
    alone.store,alone.root=empty,bare
    lacking:=project_refresh(bare,alone,context.temp_allocator)
    testing.expectf(t,len(lacking.missing)==2 && len(lacking.failures)==0 && lacking.ingested==0,"%v",lacking)
    resolved,_:=asset.root_packages(bare,empty.root,context.temp_allocator)
    testing.expectf(t,len(resolved.listed)==len(before) && len(resolved.problems)==2,"%v",resolved.problems)
    for l in resolved.listed {testing.expectf(t,l.state==.Not_Built,"%s is not built",l.path)}
    for entry in pinned.packages {
        id:[base.ASSET_ID_TEXT]u8
        named:=false
        for line in resolved.problems {named||=strings.contains(line,base.asset_id_format(entry.id,id[:]))}
        testing.expectf(t,named,"%v is named: %v",entry.id,resolved.problems)
    }

    testing.expect_value(t,project_unpin(bare,pinned.packages[0].id),asset.Error.None)
    left,_,_:=asset.packages_load(bare,context.temp_allocator)
    testing.expect(t,len(left.packages)==1 && left.packages[0].id==pinned.packages[1].id,"the other stays pinned")
    testing.expect(t,!os.exists(asset.package_file(bare,pinned.packages[0].id)),"unpinning removes its manifest")
    testing.expect(t,os.exists(asset.package_file(bare,pinned.packages[1].id)))
}

// What a project's packages.mirai or the store says that is not a record of
// this version is reported, never a crash nor a default.
@(test)
hostile_packages_and_manifests_are_reported_without_a_crash :: proc(t:^testing.T) {
    top:=base.test_folder(t,"library-hostile")
    if top=="" {return}
    game:=fmt.tprintf("%s/game",top)
    os.make_directory_all(fmt.tprintf("%s/assets",game))
    s:=test_store(t,fmt.tprintf("%s/store",top))
    if s==nil {return}
    options:=Library_Options{store=s,root=game}
    garbage,_:=store.put_bytes(s,transmute([]u8)string(`{"version": 1, "id": "nonsense"}`))
    other:=asset.Package{id={9,9},name="other",origin={path="/nowhere/other.png",importer="image"}}
    other_manifest,_:=asset.package_put(s,&other)
    lost:=asset.Package{id={7,7},name="lost",origin={path="/nowhere/lost.png",importer="image"}}
    lost_manifest,_:=asset.package_put(s,&lost)
    list:asset.Packages
    list.packages=make([dynamic]asset.Project_Package,context.temp_allocator)
    append(&list.packages,asset.Project_Package{id={1,1},manifest=garbage},asset.Project_Package{id={2,2},manifest=other_manifest},asset.Project_Package{id={7,7},manifest=lost_manifest,folder="lost"})
    testing.expect_value(t,asset.packages_save(game,&list),asset.Error.None)
    report:=project_refresh(game,options,context.temp_allocator)
    testing.expectf(t,report.packages==3 && len(report.failures)==2 && len(report.missing)==1 && strings.contains(report.missing[0],"package lost"),"%v",report)
    // A file of the root that is not the manifest its pin names.
    os.make_directory_all(fmt.tprintf("%s/%s",game,asset.PACKAGE_FILES))
    _=os.write_entire_file(asset.package_file(game,{1,1}),transmute([]u8)string("not the pinned manifest"))
    mismatched:=project_refresh(game,options,context.temp_allocator)
    testing.expectf(t,len(mismatched.failures)==2 && strings.contains(strings.join(mismatched.failures[:],"\n",context.temp_allocator),"is not the manifest"),"%v",mismatched.failures[:])
    os.remove(asset.package_file(game,{1,1}))

    text,_:=os.read_entire_file(fmt.tprintf("%s/%s",game,asset.PACKAGES_FILE),context.temp_allocator)
    work:=make([]u8,len(text),context.temp_allocator)
    path:=fmt.tprintf("%s/%s",game,asset.PACKAGES_FILE)
    refused:=0
    for length:=0;length<len(text);length+=1+len(text)/200 {
        _=os.write_entire_file(path,text[:length])
        cut:=project_refresh(game,options,context.temp_allocator)
        refused+=int(len(cut.failures)>0)
    }
    marks:="{}[]\":,0-9ef \x00\xff"
    state:=u64(0x9e3779b97f4a7c15)
    for _ in 0..<300 {
        copy(work,text)
        state=state*6364136223846793005+1442695040888963407
        work[int((state>>33)%u64(len(work)))]=marks[int((state>>20)%u64(len(marks)))]
        _=os.write_entire_file(path,work)
        _=project_refresh(game,options,context.temp_allocator)
    }
    testing.expectf(t,refused>0,"cut texts are refused: %d",refused)
    testing.expect(t,!os.exists(fmt.tprintf("%s/assets/lost",game)),"nothing is written for what is not here")
}

// Two that ingest one source at once take turns, and the second finds the
// work done.
@(test)
two_ingests_of_one_source_at_once_import_it_once :: proc(t:^testing.T) {
    top:=base.test_folder(t,"library-lock")
    if top=="" {return}
    sign:=fmt.tprintf("%s/sign.png",top)
    _=os.write_entire_file(sign,png_bytes(64,64,{20,140,40}))
    Run :: struct {root,source:string,assets:int,manifest:store.Hash,failed:bool,ready:^sync.Barrier}
    ready:sync.Barrier
    sync.barrier_init(&ready,2)
    runs:[2]Run
    for &run in runs {run={root=fmt.tprintf("%s/store",top),source=sign,ready=&ready}}
    work :: proc(run:^Run) {
        s,error:=store.open(run.root)
        if error!=.None {run.failed=true;return}
        defer store.close(&s)
        sync.barrier_wait(run.ready)
        report,ingest_error:=ingest(run.source,{store=&s})
        defer importer.report_destroy(&report)
        run.failed=ingest_error.code!=.None
        run.assets,run.manifest=len(report.assets),report.manifest
    }
    threads:[2]^thread.Thread
    for &run,at in runs {threads[at]=thread.create_and_start_with_poly_data(&run,work)}
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }
    testing.expect(t,!runs[0].failed && !runs[1].failed && runs[0].manifest==runs[1].manifest && runs[0].manifest!={})
    testing.expectf(t,(runs[0].assets==0)!=(runs[1].assets==0),"one imports and the other finds it done: %d and %d assets",runs[0].assets,runs[1].assets)
}
