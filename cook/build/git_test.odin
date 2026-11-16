package build

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

// The attributes the line of a kind gives its files; "" without a line of its own, or with two.
@(private="file")
attributes_of :: proc(text,extension:string) -> string {
    found,count:="",0
    rest:=text
    for line in strings.split_lines_iterator(&rest) {
        if strings.has_prefix(line,strings.concatenate({"*",extension," "},context.temp_allocator)) {found=line[len(extension)+2:];count+=1}
    }
    return count==1?found:""
}

@(test)
git_attributes_follow_the_kinds_and_keep_the_other_lines :: proc(t:^testing.T) {
    plugins:=[]Git_Kind{{".particle",true,false},{".grid",false,false},{".mesh",true,false},{"",true,false},{".umap",false,true}}
    existing:="* text=auto eol=lf\n*.scene binary\n# kept\n\n*.cmd text eol=crlf\n"
    text,changed:=git_attributes(plugins,false,existing,context.temp_allocator)
    testing.expect(t,changed)
    merges :: proc(attributes:string) -> bool {return strings.contains(attributes,"merge="+GIT_DRIVER) && strings.contains(attributes,"diff="+GIT_DRIVER) && strings.contains(attributes,"-text")}
    for info in asset.KINDS {
        attributes:=attributes_of(text,info.extension)
        testing.expectf(t,info.merged?merges(attributes):attributes=="binary","%s: %q",info.extension,attributes)
    }
    testing.expect(t,merges(attributes_of(text,".particle")),"a document of a plugin merges and diffs")
    testing.expect_value(t,attributes_of(text,".grid"),"binary")
    testing.expect_value(t,attributes_of(text,".umap"),"")
    testing.expect(t,strings.has_prefix(text,"* text=auto eol=lf\n# kept\n\n*.cmd text eol=crlf\n*"),"the lines of other files stay, before those of the kinds")
    again:string
    again,changed=git_attributes(plugins,false,text,context.temp_allocator)
    testing.expect(t,again==text && !changed,"made again from its own text it comes out the same")
    crlf,_:=strings.replace_all(text,"\n","\r\n",context.temp_allocator)
    again,changed=git_attributes(plugins,false,crlf,context.temp_allocator)
    testing.expect(t,again==text && !changed,"line ends are no change")

    large,_:=git_attributes(plugins,true,existing,context.temp_allocator)
    for info in asset.KINDS {
        attributes:=attributes_of(large,info.extension)
        testing.expectf(t,info.merged?merges(attributes):strings.contains(attributes,"filter=lfs"),"%s with LFS: %q",info.extension,attributes)
    }
    testing.expect(t,strings.contains(attributes_of(large,".grid"),"filter=lfs") && strings.contains(attributes_of(large,".png"),"filter=lfs"))
    testing.expect(t,strings.contains(attributes_of(large,".umap"),"filter=lfs"),"the sources a plugin imports go to LFS with the others")
    again,changed=git_attributes(plugins,false,large,context.temp_allocator)
    testing.expect(t,again==large && !changed,"a file that keeps files in LFS keeps them there")
    free_all(context.temp_allocator)
}

@(test)
the_git_attributes_of_the_engine_follow_its_kinds :: proc(t:^testing.T) {
    root:=project.path_absolute(#directory+"../..",context.temp_allocator)
    file:=project.path(root,".gitattributes",allocator=context.temp_allocator)
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if !testing.expectf(t,error==nil,"%s does not read",file) {return}
    plugins,read:=git_plugin_kinds("",{root},context.temp_allocator)
    testing.expect(t,read && len(plugins)>0,"the manifests of the plugins of the engine say the kinds of asset they add")
    _,changed:=git_attributes(plugins,false,string(data),context.temp_allocator)
    testing.expect(t,!changed,"the .gitattributes of the engine does not have the lines of asset.KINDS and of the asset_kinds of its plugins: `./mirai setup git` writes them")
    free_all(context.temp_allocator)
}

@(private="file")
git :: proc(folder:string,arguments:..string) -> (out:string,ok:bool) {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,"git","-C",folder)
    append(&command,..arguments)
    state,printed,_,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    return strings.trim_space(string(printed)),error==nil && state.exit_code==0
}

@(test)
git_setup_wires_a_clone_once_and_again_for_another_engine_or_plugin :: proc(t:^testing.T) {
    if _,_,_,missing:=subprocess.exec({command={"git","--version"}},context.temp_allocator);missing!=nil {log.warn("git is not installed: the setup of a clone is not tested");return}
    root:=base.test_folder(t,"git")
    if root=="" {return}
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    write :: proc(t:^testing.T,file,text:string,loc:=#caller_location) {
        folder:=file[:strings.last_index_byte(file,'/')]
        testing.expect(t,os.make_directory_all(folder)==nil || os.is_dir(folder),loc=loc)
        testing.expect(t,os.write_entire_file(file,text)==nil,loc=loc)
    }
    attributes :: proc(folder:string) -> string {
        text,_:=os.read_entire_file(project.path(folder,".gitattributes",allocator=context.temp_allocator),context.temp_allocator)
        return string(text)
    }
    // Two copies of an engine with a plugin the project uses and one it does not, and a clone with the project in a folder.
    engine,other,clone:=join(root,"engine"),join(root,"other engine"),join(root,"clone")
    game:=join(clone,"game")
    for copy in ([]string{engine,other}) {
        write(t,join(copy,"plugins/fx",project.PLUGIN_FILE),`{"name": "fx", "version": "1.0.0", "asset_kinds": [{"extension": ".spark", "kind": "SPAR", "version": 1, "merged": true}, {"extension": ".bake", "kind": "BAKE", "version": 1}]}`)
        write(t,join(copy,"plugins/unused",project.PLUGIN_FILE),`{"name": "unused", "version": "1.0.0", "asset_kinds": [{"extension": ".never", "kind": "NEVE", "version": 1, "merged": true}]}`)
    }
    write(t,join(game,project.PROJECT_FILE),`{"name": "G", "plugins": ["fx"]}`)

    _,error:=git_setup(engine,game,context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.No_Repository)
    _,initialized:=git(clone,"init","-q")
    if !testing.expect(t,initialized) {return}
    state,_,_:=git_wiring(engine,game,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.None)

    done:Git_Setup
    done,error=git_setup(engine,game,context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.None)
    testing.expect_value(t,done.settings,GIT_SETTINGS)
    testing.expect(t,done.attributes!="","the .gitattributes goes to the top of the clone")
    text:=attributes(clone)
    testing.expect(t,strings.contains(text,"*.scene merge="+GIT_DRIVER) && strings.contains(text,"*.spark merge="+GIT_DRIVER) && strings.contains(text,"*.bake binary"),"the kinds of the engine and those the manifest of a plugin the project uses declares")
    testing.expect(t,!strings.contains(text,".never"),"a plugin the project does not use adds nothing")
    driver,_:=git(clone,"config","--local","merge."+GIT_DRIVER+".driver")
    testing.expectf(t,strings.contains(driver,engine) && strings.has_suffix(driver,"asset merge %O %A %B"),"%q",driver)
    textconv,_:=git(clone,"config","--local","diff."+GIT_DRIVER+".textconv")
    testing.expectf(t,strings.contains(textconv,engine) && strings.has_suffix(textconv,"asset dump --textconv"),"%q",textconv)
    stale:bool
    state,_,stale=git_wiring(engine,game,context.temp_allocator)
    testing.expect(t,state==.Wired && !stale)

    done,error=git_setup(engine,game,context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.None)
    testing.expect(t,done.settings==0 && done.attributes=="","a second run writes nothing")

    state,_,_=git_wiring(other,game,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.Other)
    done,error=git_setup(other,game,context.temp_allocator)
    testing.expect(t,error==.None && done.settings>0 && done.settings<GIT_SETTINGS && done.attributes=="","an engine that moved writes the settings that name it")
    state,_,_=git_wiring(other,game,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.Wired)

    // A plugin the project starts to use brings its kinds.
    write(t,join(game,"plugins/own",project.PLUGIN_FILE),`{"name": "own", "version": "1.0.0", "asset_kinds": [{"extension": ".quest", "kind": "QUES", "version": 1, "merged": true}]}`)
    write(t,join(game,project.PROJECT_FILE),`{"name": "G", "plugins": ["fx", "own"]}`)
    _,_,stale=git_wiring(other,game,context.temp_allocator)
    testing.expect(t,stale,"the .gitattributes lacks the kind of the new plugin")
    done,error=git_setup(other,game,context.temp_allocator)
    testing.expect(t,error==.None && done.settings==0 && strings.contains(attributes(clone),"*.quest merge="+GIT_DRIVER))
    _,_,stale=git_wiring(other,game,context.temp_allocator)
    testing.expect(t,!stale)

    // A clone that brings the .gitattributes and has no drivers yet.
    _,unset:=git(clone,"config","--local","--remove-section","merge."+GIT_DRIVER)
    testing.expect(t,unset)
    state,_,_=git_wiring(other,game,context.temp_allocator)
    testing.expect_value(t,state,Git_Wiring.Unset)

    // A project that does not read says so instead of leaving the kinds of its plugins out.
    write(t,join(game,project.PROJECT_FILE),`{"name": "G", "plugins": ["missing"]}`)
    _,error=git_setup(other,game,context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.Plugins_Failed)

    // A checkout of the engine names its own launcher, wherever it is, and holds every plugin under plugins/.
    testing.expect(t,os.make_directory_all(join(clone,"tools/mirai"))==nil)
    for file in ([]string{"AGENTS.md","mirai"}) {testing.expect(t,os.write_entire_file(join(clone,file),"")==nil)}
    for setting in git_settings(other,clone,context.temp_allocator) {
        testing.expectf(t,!strings.contains(setting.value,root),"%s = %s names a folder of this machine",setting.key,setting.value)
    }
    write(t,join(clone,"plugins/held",project.PLUGIN_FILE),`{"name": "held", "version": "1.0.0", "asset_kinds": [{"extension": ".held", "kind": "HELD", "version": 1}]}`)
    held,read:=git_plugin_kinds(other,{clone,game},context.temp_allocator)
    testing.expect(t,read && len(held)==1 && held[0]==Git_Kind{".held",false,false})
    free_all(context.temp_allocator)
}

// A worktree of the engine is the engine of its main checkout: opening a
// project from it, or from a session copy under the project, leaves the
// configuration the main checkout wrote as it was, so deleting the worktree
// leaves no driver that names it.
@(test)
a_worktree_or_a_copy_leaves_the_drivers_of_the_main_checkout_as_they_were :: proc(t:^testing.T) {
    if _,_,_,missing:=subprocess.exec({command={"git","--version"}},context.temp_allocator);missing!=nil {log.warn("git is not installed: the drivers of a worktree are not tested");return}
    root:=base.test_folder(t,"git_worktree")
    if root=="" {return}
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    main,side,clone:=join(root,"main"),join(root,"side"),join(root,"clone")
    copy:=join(clone,".mirai/tmp/session-copy-x")
    // Git writes the gitdir of a worktree with forward slashes on every system.
    tree:=join(main,".git/worktrees/side")
    for folder in ([]string{tree,join(main,"plugins"),join(side,"plugins"),copy}) {testing.expect(t,os.make_directory_all(folder)==nil)}
    testing.expect(t,os.write_entire_file(join(tree,"commondir"),"../..\n")==nil)
    testing.expect(t,os.write_entire_file(join(side,".git"),strings.concatenate({"gitdir: ",tree,"\n"},context.temp_allocator))==nil)
    for folder in ([]string{clone,copy}) {testing.expect(t,os.write_entire_file(join(folder,project.PROJECT_FILE),`{"name": "G"}`)==nil)}
    _,initialized:=git(clone,"init","-q")
    if !testing.expect(t,initialized) {return}

    _,error:=git_setup(main,clone,context.temp_allocator)
    testing.expect_value(t,error,Git_Setup_Error.None)
    config:=join(clone,".git/config")
    before,_:=os.read_entire_file(config,context.temp_allocator)
    for folder in ([]string{clone,copy}) {
        state,_,_:=git_wiring(side,folder,context.temp_allocator)
        testing.expectf(t,state==.Wired,"%s from the worktree: %v",folder,state)
        done:Git_Setup
        done,error=git_setup(side,folder,context.temp_allocator)
        testing.expectf(t,error==.None && done.settings==0,"%s from the worktree wrote %d settings",folder,done.settings)
    }
    after,_:=os.read_entire_file(config,context.temp_allocator)
    testing.expect(t,string(after)==string(before),"the configuration stays as the main checkout wrote it")
    for setting in git_settings(side,clone,context.temp_allocator) {
        testing.expectf(t,!strings.contains(setting.value,side),"%s = %s names the worktree",setting.key,setting.value)
    }
    free_all(context.temp_allocator)
}
