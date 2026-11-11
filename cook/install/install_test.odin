package install

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// A repository of a plugin named name in folder, with one commit; returns its address.
@(private="file")
test_repository :: proc(t:^testing.T,folder,name:string,parts:=`["Runtime"]`) -> string {
    write(t,folder,project.PLUGIN_FILE,strings.concatenate({`{"name": "`,name,`", "version": "1.0.0", "parts": `,parts,`}`},context.temp_allocator))
    write(t,folder,"runtime/plugin.odin",strings.concatenate({"package ",name,"\n"},context.temp_allocator))
    for args in ([][]string{{"init","--quiet","-b","main"},{"add","-A"},{"-c","user.name=Test","-c","user.email=test@example.com","commit","--quiet","-m","One"}}) {
        _,failure:=git(folder,..args)
        testing.expect(t,failure=="",failure)
    }
    return strings.concatenate({"file://",folder},context.temp_allocator)
}

@(private="file")
test_commit :: proc(t:^testing.T,folder,file,text:string) -> string {
    write(t,folder,file,text)
    for args in ([][]string{{"add","-A"},{"-c","user.name=Test","-c","user.email=test@example.com","commit","--quiet","-m","More"}}) {
        _,failure:=git(folder,..args)
        testing.expect(t,failure=="",failure)
    }
    commit,_:=git(folder,"rev-parse","HEAD")
    return commit
}

@(private="file")
write :: proc(t:^testing.T,folder,file,text:string) {
    full:=project.path(folder,file,allocator=context.temp_allocator)
    directory:=full[:strings.last_index_byte(full,'/')]
    testing.expect(t,os.make_directory_all(directory)==nil || os.is_dir(directory))
    testing.expect(t,os.write_entire_file(full,text)==nil,full)
}

@(private="file")
test_project :: proc(t:^testing.T,root:string) {
    m:=project.manifest_default("Game")
    write(t,root,project.PROJECT_FILE,project.manifest_text(&m,context.temp_allocator))
}

@(private="file")
manifest_get :: proc(t:^testing.T,root:string) -> project.Manifest {
    m,error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
    testing.expect_value(t,error.code,project.Error_Code.None)
    return m
}

@(test)
a_plugin_from_git_is_added_updated_synced_and_removed :: proc(t:^testing.T) {
    if _,failure:=git("","--version");failure!="" {return} // no git on this machine
    folder:=base.test_folder(t,"install")
    repository:=project.path(folder,"hello",allocator=context.temp_allocator)
    url:=test_repository(t,repository,"hello")
    first,_:=git(repository,"rev-parse","HEAD")
    root:=project.path(folder,"game",allocator=context.temp_allocator)
    test_project(t,root)

    added:=add(root,"",url,"",context.temp_allocator)
    testing.expect(t,added.ok,added.message)
    m:=manifest_get(t,root)
    source:=project.source_find(&m,"hello")
    testing.expect(t,source!=nil && base.text_get(source.commit[:])==first && base.text_get(source.url[:])==url)
    testing.expect_value(t,base.text_get(m.plugins[0][:]),"hello")
    ignore,_:=os.read_entire_file(project.path(root,".gitignore",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(ignore),"/plugins/hello/\n")
    testing.expect(t,!sync_needed(root))
    again:=add(root,"",url,"",context.temp_allocator)
    testing.expect(t,!again.ok)

    second:=test_commit(t,repository,"runtime/more.odin","package hello\n")
    updated:=update(root,"","hello","",context.temp_allocator)
    testing.expect(t,updated.ok,updated.message)
    testing.expect(t,strings.contains(updated.message,"runtime/more.odin"),updated.message)
    m=manifest_get(t,root)
    testing.expect_value(t,base.text_get(project.source_find(&m,"hello").commit[:]),second)
    back:=update(root,"","hello",first,context.temp_allocator)
    testing.expect(t,back.ok,back.message)
    testing.expect(t,!os.exists(project.path(root,"plugins/hello/runtime/more.odin",allocator=context.temp_allocator)))

    // A clone of the project has the manifest and not the checkout.
    testing.expect(t,os.remove_all(project.path(root,"plugins/hello",allocator=context.temp_allocator))==nil)
    testing.expect(t,sync_needed(root))
    changed,message:=sync(root,context.temp_allocator)
    testing.expect_value(t,changed,1)
    testing.expect_value(t,message,"")
    head,_:=git(project.path(root,"plugins/hello",allocator=context.temp_allocator),"rev-parse","HEAD")
    testing.expect_value(t,head,first)
    testing.expect(t,!sync_needed(root))

    // Changes of its own keep it.
    write(t,root,"plugins/hello/runtime/plugin.odin","package hello\n// mine\n")
    kept:=remove(root,"","hello",context.temp_allocator)
    testing.expect(t,!kept.ok)
    _,_=git(project.path(root,"plugins/hello",allocator=context.temp_allocator),"checkout","--quiet",".")
    removed:=remove(root,"","hello",context.temp_allocator)
    testing.expect(t,removed.ok,removed.message)
    m=manifest_get(t,root)
    testing.expect(t,project.source_find(&m,"hello")==nil && base.text_len(m.plugins[0][:])==0)
    testing.expect(t,!os.exists(project.path(root,"plugins/hello",allocator=context.temp_allocator)))
    ignore,_=os.read_entire_file(project.path(root,".gitignore",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(ignore),"")
}

@(test)
what_is_not_a_plugin_is_not_added :: proc(t:^testing.T) {
    if _,failure:=git("","--version");failure!="" {return}
    folder:=base.test_folder(t,"install")
    root:=project.path(folder,"game",allocator=context.temp_allocator)
    test_project(t,root)
    // A part declared and not there.
    broken:=test_repository(t,project.path(folder,"broken",allocator=context.temp_allocator),"broken",`["Runtime", "Editor"]`)
    result:=add(root,"",broken,"",context.temp_allocator)
    testing.expect(t,!result.ok && strings.contains(result.message,"editor"),result.message)
    // A name the project's own plugins already have.
    write(t,root,"plugins/mine/plugin.mirai",`{"name": "mine", "version": "1.0.0", "parts": []}`)
    taken:=test_repository(t,project.path(folder,"mine",allocator=context.temp_allocator),"mine")
    result=add(root,"",taken,"",context.temp_allocator)
    testing.expect(t,!result.ok,result.message)
    m:=manifest_get(t,root)
    testing.expect(t,base.text_len(m.sources[0].name[:])==0)
    testing.expect(t,!os.exists(project.path(root,"plugins/broken",allocator=context.temp_allocator)))
    // Nothing is left of the clones.
    entries,_:=os.read_all_directory_by_path(project.path(root,".mirai/install",allocator=context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,len(entries),0)
}

@(test)
a_plugin_of_the_catalog_updates_only_to_what_the_catalog_lists :: proc(t:^testing.T) {
    if _,failure:=git("","--version");failure!="" {return}
    folder:=base.test_folder(t,"install")
    repository:=project.path(folder,"hello",allocator=context.temp_allocator)
    url:=test_repository(t,repository,"hello")
    first,_:=git(repository,"rev-parse","HEAD")
    second:=test_commit(t,repository,"runtime/two.odin","package hello\n")
    root:=project.path(folder,"game",allocator=context.temp_allocator)
    test_project(t,root)
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    catalog_at :: proc(t:^testing.T,engine,url,commit:string) {
        write(t,catalog_folder(engine,context.temp_allocator),"plugins/hello.json",strings.concatenate({`{"url": "`,url,`", "commit": "`,commit,`"}`},context.temp_allocator))
    }
    catalog_at(t,engine,url,first)
    commit_of :: proc(t:^testing.T,root:string) -> string {
        m:=manifest_get(t,root)
        return strings.clone(base.text_get(project.source_find(&m,"hello").commit[:]),context.temp_allocator)
    }

    // At the reviewed commit, not at the head of its repository.
    added:=add_from_catalog(root,engine,"hello",context.temp_allocator)
    testing.expect(t,added.ok,added.message)
    testing.expect_value(t,commit_of(t,root),first)
    m:=manifest_get(t,root)
    testing.expect(t,project.source_find(&m,"hello").catalog)
    same:=update(root,engine,"hello","",context.temp_allocator)
    testing.expect(t,same.ok && strings.contains(same.message,"already"),same.message)
    testing.expect_value(t,commit_of(t,root),first)

    // A review moves it.
    testing.expect(t,!has_commit(root,"hello",second))
    catalog_at(t,engine,url,second)
    moved:=update(root,engine,"hello","",context.temp_allocator)
    testing.expect(t,moved.ok,moved.message)
    testing.expect_value(t,commit_of(t,root),second)

    // Past the catalog by a ref asked for, an update does not take it back.
    third:=test_commit(t,repository,"runtime/three.odin","package hello\n")
    asked:=update(root,engine,"hello","main",context.temp_allocator)
    testing.expect(t,asked.ok,asked.message)
    testing.expect_value(t,commit_of(t,root),third)
    kept:=update(root,engine,"hello","",context.temp_allocator)
    testing.expect(t,kept.ok && strings.contains(kept.message,"stays"),kept.message)
    testing.expect(t,has_commit(root,"hello",second)) // the editor offers no update
    testing.expect_value(t,commit_of(t,root),third)

    // Without the catalog it does not update.
    testing.expect(t,os.remove_all(catalog_folder(engine,context.temp_allocator))==nil)
    unread:=update(root,engine,"hello","",context.temp_allocator)
    testing.expect(t,!unread.ok,unread.message)
    testing.expect_value(t,commit_of(t,root),third)
}

@(test)
a_plugin_from_git_brings_its_companions_and_takes_them_away :: proc(t:^testing.T) {
    if _,failure:=git("","--version");failure!="" {return}
    folder:=base.test_folder(t,"install")
    root:=project.path(folder,"game",allocator=context.temp_allocator)
    test_project(t,root)
    repository:=project.path(folder,"hello",allocator=context.temp_allocator)
    write(t,repository,"plugins/hello_bridge/plugin.mirai",`{"name": "hello_bridge", "version": "1.0.0", "dependencies": ["hello"], "parts": [], "automatic": true}`)
    url:=test_repository(t,repository,"hello")

    added:=add(root,"",url,"",context.temp_allocator)
    testing.expect(t,added.ok,added.message)
    p,error:=project.open(root,"",context.temp_allocator)
    testing.expect_value(t,error.code,project.Error_Code.None)
    index,found:=project.plugin_find(p.plugins,"hello_bridge")
    testing.expect(t,found && slice.contains(p.active,index))
    project.close(&p)
    m:=manifest_get(t,root)
    testing.expect_value(t,base.text_get(m.plugins[1][:]),"")

    // The bridge that depends on it goes with it.
    removed:=remove(root,"","hello",context.temp_allocator)
    testing.expect(t,removed.ok,removed.message)
    testing.expect(t,!os.exists(project.path(root,"plugins/hello",allocator=context.temp_allocator)))

    // A companion that is not a plugin keeps the whole repository out.
    test_commit(t,repository,"plugins/hello_bridge/plugin.mirai",`{"name": "other", "version": "1.0.0", "dependencies": ["hello"], "parts": [], "automatic": true}`)
    broken:=add(root,"",url,"",context.temp_allocator)
    testing.expect(t,!broken.ok && strings.contains(broken.message,"hello_bridge"),broken.message)
    testing.expect(t,!os.exists(project.path(root,"plugins/hello",allocator=context.temp_allocator)))
}
